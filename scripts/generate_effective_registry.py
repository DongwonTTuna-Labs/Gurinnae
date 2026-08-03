#!/usr/bin/env python3
"""Generate source-derived effective design inventories and set witnesses."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Sequence

import yaml

from design_bundle_digest import ROOT
from generate_effective_execution_registry import (
    OUTPUT as EFFECTIVE_EXECUTION_REGISTRY,
    render_registry as render_effective_execution_registry,
)
from git_authority import (
    GitAuthorityError,
    authority_file,
    authority_paths as git_authority_paths,
)


MIGRATION_RE = re.compile(r"^(\d{4})_[a-z0-9_]+\.sql$")
EVENT_RE = re.compile(r"^[a-z][a-z0-9_.-]*\.v[0-9]+$")
SCENARIO_RE = re.compile(r"^\s*#\s*scenario-id:\s*(\S+)\s*$", re.MULTILINE)
SCENARIO_TITLE_RE = re.compile(r"^\s*Scenario(?: Outline)?:\s*(\S.*)\s*$")
FOCUSED_FEATURE_RE = re.compile(r"(?im)^\s*@[^\n]*(?:@focus|@focused|@only)\b")
SKIPPED_FEATURE_RE = re.compile(
    r"(?im)^\s*@[^\n]*(?:@skip|@skipped|@ignore|@disabled|@pending|@wip|@todo)\b"
)
CHECK_ARGUMENT_RE = re.compile(
    r"add_argument\(\s*['\"]--check['\"](?:\s*,|\s*\))"
)
AI_SEMANTIC_VALIDATOR = "specs/agents/addendum-v2/validate_contracts.py"
GENERATOR_PATTERNS = (
    "scripts/generate_*.py",
    "scripts/finalize_*.py",
    "scripts/normalize_*.py",
)
BASE_ACCEPTANCE_LOCK = "tests/acceptance/base-v13.lock.yaml"


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def _construct_mapping(loader: UniqueKeyLoader, node: yaml.nodes.MappingNode, deep: bool = False) -> dict[Any, Any]:
    mapping: dict[Any, Any] = {}
    explicit: set[Any] = set()
    for key_node, value_node in node.value:
        if key_node.tag == "tag:yaml.org,2002:merge":
            merged = loader.construct_object(value_node, deep=deep)
            merged_values = merged if isinstance(merged, list) else [merged]
            for inherited in merged_values:
                if not isinstance(inherited, dict):
                    raise ValueError("YAML merge value must be a mapping")
                for key, value in inherited.items():
                    mapping.setdefault(key, value)
            continue
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in explicit
        except TypeError as error:
            raise ValueError(f"unhashable YAML key: {key!r}") from error
        if duplicate:
            raise ValueError(f"duplicate YAML key: {key!r}")
        explicit.add(key)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping
)


@dataclass(frozen=True)
class Problem:
    code: str
    source: str
    expected: object
    actual: object


class Checks:
    def __init__(self) -> None:
        self.problems: list[Problem] = []

    def require(self, condition: bool, code: str, source: str, expected: object, actual: object) -> None:
        if not condition:
            self.problems.append(Problem(code, source, expected, actual))

    def unique(self, values: Iterable[str], source: str) -> set[str]:
        rows = list(values)
        valid = [value for value in rows if isinstance(value, str) and bool(value.strip())]
        self.require(len(valid) == len(rows), "invalid_id", source, "nonempty strings", rows)
        duplicates = sorted({value for value in valid if valid.count(value) > 1})
        self.require(not duplicates, "duplicate_id", source, [], duplicates)
        return set(valid)

    def equal(self, left: set[str], right: set[str], source: str, left_name: str, right_name: str) -> None:
        self.require(
            left == right,
            "set_equality",
            source,
            {left_name: sorted(left - right), right_name: sorted(right - left)},
            {"left_count": len(left), "right_count": len(right)},
        )

    def subset(self, subset: set[str], superset: set[str], source: str) -> None:
        self.require(subset <= superset, "unknown_reference", source, [], sorted(subset - superset))

    def count_value(self, declared: object, actual: int, source: str) -> None:
        # A source-derived prose declaration is not a numeric witness and does
        # not replace the exact set checks around it.  It is accepted only in
        # the explicit `derived ...` form; stale numeric literals still fail.
        source_derived = isinstance(declared, str) and declared.startswith("derived ")
        self.require(
            source_derived or declared == actual,
            "declared_count",
            source,
            actual,
            declared,
        )

    def count(self, declared: object, values: set[str] | Sequence[object], source: str) -> None:
        self.count_value(declared, len(values), source)

    def count_mapping(
        self,
        declared: object,
        expected: dict[str, int],
        source: str,
    ) -> None:
        if not isinstance(declared, dict):
            self.require(False, "declared_count", source, expected, declared)
            return
        self.require(
            set(declared) == set(expected),
            "declared_count_keys",
            source,
            sorted(expected),
            sorted(declared),
        )
        for key, actual in expected.items():
            self.count_value(declared.get(key), actual, f"{source}.{key}")


def load_yaml(root: Path, relative: str, checks: Checks) -> dict[str, Any]:
    path = root / relative
    if path.is_symlink() or not path.is_file():
        checks.require(False, "missing_registry", relative, "regular file", "missing")
        return {}
    try:
        value = yaml.load(path.read_text(encoding="utf-8"), Loader=UniqueKeyLoader)
    except (OSError, UnicodeError, yaml.YAMLError, ValueError) as error:
        checks.require(False, "invalid_yaml", relative, "valid unique-key YAML", str(error))
        return {}
    if not isinstance(value, dict):
        checks.require(False, "invalid_document", relative, "mapping", type(value).__name__)
        return {}
    return value


def mapping_keys(value: object, source: str, checks: Checks) -> set[str]:
    if not isinstance(value, dict):
        checks.require(False, "invalid_registry", source, "mapping", type(value).__name__)
        return set()
    return checks.unique(value.keys(), source)


def row_ids(value: object, key: str, source: str, checks: Checks) -> set[str]:
    if not isinstance(value, list):
        checks.require(False, "invalid_registry", source, "list", type(value).__name__)
        return set()
    ids: list[str] = []
    for index, row in enumerate(value):
        if not isinstance(row, dict) or not isinstance(row.get(key), str):
            checks.require(False, "invalid_row", f"{source}[{index}]", key, row)
            continue
        ids.append(row[key])
    return checks.unique(ids, source)


def collect_event_tokens(value: object) -> set[str]:
    if isinstance(value, str):
        return {value} if EVENT_RE.fullmatch(value) else set()
    if isinstance(value, list):
        return set().union(*(collect_event_tokens(item) for item in value), set())
    if isinstance(value, dict):
        return set().union(*(collect_event_tokens(item) for item in value.values()), set())
    return set()


def _safe_relative(value: str) -> bool:
    path = PurePosixPath(value)
    return bool(
        value
        and "\\" not in value
        and not path.is_absolute()
        and ".." not in path.parts
        and value == path.as_posix()
    )


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _string_set_sha256(values: Iterable[str]) -> str:
    payload = "\n".join(sorted(set(values))).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _ordered_scenario_identity_sha256(rows: Sequence[dict[str, str]]) -> str:
    payload = "\n".join(
        "\0".join(
            (row["feature_file"], row["scenario_id"], row["scenario_title"])
        )
        for row in rows
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _validator_environment() -> dict[str, str]:
    environment = dict(os.environ)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return environment


def validate_ai_semantic_payload(
    payload: object,
    returncode: int,
    checks: Checks,
    source: str,
) -> bool:
    valid = (
        returncode == 0
        and isinstance(payload, dict)
        and payload.get("result") == "PASS"
        and payload.get("errors") == []
    )
    checks.require(
        valid,
        "ai_semantic_schema",
        source,
        "PASS/exit 0/errors []",
        {
            "returncode": returncode,
            "result": payload.get("result") if isinstance(payload, dict) else None,
            "errors": payload.get("errors") if isinstance(payload, dict) else None,
        },
    )
    return valid


def validate_ai_semantic_contracts(root: Path, checks: Checks) -> dict[str, object]:
    relative = AI_SEMANTIC_VALIDATOR
    script = root / relative
    receipt: dict[str, object] = {"path": relative, "result": "FAIL"}
    if script.is_symlink() or not script.is_file():
        checks.require(False, "ai_semantic_validator_missing", relative, "regular file", "missing")
        return receipt
    with tempfile.TemporaryDirectory(prefix="gurinnae-ai-schema-") as directory:
        output = Path(directory) / "result.json"
        try:
            process = subprocess.run(
                [sys.executable, "-B", str(script), "--json-output", str(output)],
                cwd=root,
                env=_validator_environment(),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=900,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            checks.require(False, "ai_semantic_validator_execution", relative, "completed", str(error))
            return receipt
        receipt["returncode"] = process.returncode
        if not output.is_file():
            checks.require(
                False,
                "ai_semantic_validator_output",
                relative,
                "JSON output",
                process.stdout[-4000:],
            )
            return receipt
        try:
            payload = json.loads(output.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            checks.require(False, "ai_semantic_validator_output", relative, "valid JSON", str(error))
            return receipt
        valid = validate_ai_semantic_payload(
            payload,
            process.returncode,
            checks,
            relative,
        )
        if isinstance(payload, dict):
            receipt.update(
                {
                    key: payload.get(key)
                    for key in (
                        "schemas",
                        "yaml_documents",
                        "tool_pairs",
                        "positive_examples",
                        "negative_examples",
                        "parser_formats",
                        "embedded_fixtures",
                        "acceptance_scenarios",
                    )
                }
            )
        receipt["result"] = "PASS" if valid else "FAIL"
    return receipt


def discover_check_generators(root: Path, checks: Checks) -> list[Path]:
    discovered: dict[str, Path] = {}
    for pattern in GENERATOR_PATTERNS:
        for path in sorted(root.glob(pattern)):
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                checks.require(False, "generator_file_type", relative, "regular file", "symlink")
                continue
            if not path.is_file():
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeError) as error:
                checks.require(False, "generator_unreadable", relative, "UTF-8", str(error))
                continue
            if CHECK_ARGUMENT_RE.search(text):
                discovered[relative] = path
    checks.require(
        bool(discovered),
        "generator_parity_discovery",
        "check-capable design generators",
        ">=1 dynamically discovered --check generator",
        [],
    )
    return [discovered[key] for key in sorted(discovered)]


def validate_generator_parity(root: Path, checks: Checks) -> list[dict[str, object]]:
    receipts: list[dict[str, object]] = []
    for script in discover_check_generators(root, checks):
        relative = script.relative_to(root).as_posix()
        try:
            process = subprocess.run(
                [sys.executable, "-B", str(script), "--check"],
                cwd=root,
                env=_validator_environment(),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=900,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            checks.require(False, "generator_parity_execution", relative, "completed", str(error))
            receipts.append({"path": relative, "result": "FAIL"})
            continue
        checks.require(
            process.returncode == 0,
            "generator_parity",
            relative,
            "--check exit 0",
            {"returncode": process.returncode, "output": process.stdout[-4000:]},
        )
        receipts.append(
            {
                "path": relative,
                "sha256": _sha256_file(script),
                "returncode": process.returncode,
                "result": "PASS" if process.returncode == 0 else "FAIL",
            }
        )
    return receipts


def physical_table_set(root: Path, checks: Checks) -> tuple[set[str], dict[str, set[str]]]:
    relations: list[str] = []
    by_ordinal: dict[str, set[str]] = {}
    for path in sorted((root / "specs/database/addendum").glob("*.yaml")):
        if path.name == "global.yaml":
            continue
        relative = path.relative_to(root).as_posix()
        document = load_yaml(root, relative, checks)
        raw = document.get("tables", document.get("table_contracts"))
        if raw is None:
            scope = document.get("scope")
            if isinstance(scope, dict):
                raw = scope.get("relations")
        current: list[str] = []
        if isinstance(raw, dict):
            current = [str(value) for value in raw]
        elif isinstance(raw, list):
            for index, row in enumerate(raw):
                if isinstance(row, dict) and isinstance(row.get("relation"), str):
                    current.append(row["relation"])
                else:
                    checks.require(False, "invalid_table_row", f"{relative}[{index}]", "relation", row)
        elif raw is not None:
            checks.require(False, "invalid_table_registry", relative, "mapping or list", type(raw).__name__)
        relations.extend(current)
        match = re.match(r"^(\d{4})", path.name)
        if match and current:
            by_ordinal.setdefault(match.group(1), set()).update(current)
    result = checks.unique(relations, "specs/database/addendum/*#tables")
    return result, by_ordinal


def parse_feature_scenarios(
    path: Path,
    checks: Checks,
    source: str | None = None,
) -> list[dict[str, str]]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        checks.require(False, "feature_unreadable", str(path), "UTF-8", str(error))
        return []
    relative = source or path.as_posix()
    rows: list[dict[str, str]] = []
    pending_id: str | None = None
    for line_number, line in enumerate(text.splitlines(), start=1):
        id_match = re.match(r"^\s*#\s*scenario-id:\s*(\S+)\s*$", line)
        if id_match:
            checks.require(
                pending_id is None,
                "scenario_without_title",
                f"{relative}:{line_number}",
                "Scenario line after prior scenario-id",
                pending_id,
            )
            pending_id = id_match.group(1)
            continue
        title_match = SCENARIO_TITLE_RE.match(line)
        if title_match and pending_id is not None:
            rows.append(
                {
                    "feature_file": relative,
                    "scenario_id": pending_id,
                    "scenario_title": title_match.group(1).strip(),
                }
            )
            pending_id = None
    checks.require(
        pending_id is None,
        "scenario_without_title",
        relative,
        "Scenario line after scenario-id",
        pending_id,
    )
    ids = checks.unique((row["scenario_id"] for row in rows), relative)
    declared_ids = checks.unique(SCENARIO_RE.findall(text), f"{relative}#scenario-id declarations")
    checks.equal(ids, declared_ids, f"{relative} scenario title binding", "titled", "declared")
    checks.require(bool(ids), "zero_test", relative, ">=1 scenario-id", 0)
    checks.require(not FOCUSED_FEATURE_RE.search(text), "focused_test", relative, "absent", "focused tag")
    checks.require(not SKIPPED_FEATURE_RE.search(text), "skipped_test", relative, "absent", "skip tag")
    return rows


def parse_feature_ids(path: Path, checks: Checks, source: str | None = None) -> set[str]:
    return {row["scenario_id"] for row in parse_feature_scenarios(path, checks, source)}


def base_feature_paths(root: Path, checks: Checks) -> set[str]:
    """Load the explicit base feature set; tag membership is not classification."""

    try:
        tag_paths = git_authority_paths(root)
        raw = authority_file(BASE_ACCEPTANCE_LOCK, root).decode("utf-8")
        document = yaml.load(raw, Loader=UniqueKeyLoader)
    except (GitAuthorityError, OSError, UnicodeError, yaml.YAMLError, ValueError) as error:
        checks.require(
            False,
            "authority_tag",
            BASE_ACCEPTANCE_LOCK,
            "readable pinned Git authority",
            str(error),
        )
        return set()
    if not isinstance(document, dict):
        checks.require(
            False,
            "authority_base_lock",
            BASE_ACCEPTANCE_LOCK,
            "mapping from authority tag",
            type(document).__name__,
        )
        return set()
    rows = document.get("features", [])
    names = row_ids(rows, "path", f"{BASE_ACCEPTANCE_LOCK}#features", checks)
    checks.count(document.get("feature_count"), names, f"{BASE_ACCEPTANCE_LOCK}#feature_count")
    relative_paths: set[str] = set()
    for name in names:
        path = PurePosixPath(name)
        valid = (
            _safe_relative(name)
            and path.parent == PurePosixPath(".")
            and path.suffix == ".feature"
        )
        checks.require(
            valid,
            "base_feature_path",
            f"{BASE_ACCEPTANCE_LOCK}#{name}",
            "feature filename without directories",
            name,
        )
        if valid:
            relative_paths.add(f"tests/acceptance/{name}")
    checks.require(
        BASE_ACCEPTANCE_LOCK in tag_paths,
        "authority_base_lock",
        BASE_ACCEPTANCE_LOCK,
        "path present in authority tag",
        "missing" if BASE_ACCEPTANCE_LOCK not in tag_paths else "present",
    )
    checks.require(
        relative_paths <= set(tag_paths),
        "authority_base_features",
        BASE_ACCEPTANCE_LOCK,
        [],
        sorted(relative_paths - set(tag_paths)),
    )
    return relative_paths


def _source_rows(ids: set[str]) -> list[str]:
    return sorted(ids)


def problem_payload(problem: Problem) -> dict[str, object]:
    return json.loads(json.dumps(asdict(problem), ensure_ascii=False, default=str))


def build_registry(root: Path = ROOT) -> tuple[dict[str, object], list[Problem]]:
    root = root.resolve()
    checks = Checks()

    base_operations_doc = load_yaml(root, "specs/api/operation-contracts.yaml", checks)
    base_persistence_doc = load_yaml(root, "specs/api/operation-persistence.yaml", checks)
    base_commands_doc = load_yaml(root, "specs/application/command-semantics.yaml", checks)
    command_catalog_doc = load_yaml(root, "specs/architecture/command-catalog.yaml", checks)
    base_events_doc = load_yaml(root, "specs/events/event-catalog.yaml", checks)
    base_schema_doc = load_yaml(root, "specs/database/schema-catalog.yaml", checks)
    base_sessions_doc = load_yaml(root, "specs/submission/session-boundary.yaml", checks)
    base_screens_doc = load_yaml(root, "specs/ui/screen-catalog.yaml", checks)
    archetypes_doc = load_yaml(root, "specs/ui/page-archetypes.yaml", checks)
    base_trace_doc = load_yaml(root, "specs/traceability/final-traceability.yaml", checks)
    identity_trace_doc = load_yaml(root, "specs/traceability/internal-identity-traceability.yaml", checks)

    owner_doc = load_yaml(root, "specs/product/owner-addendum-2026-07-14.yaml", checks)
    operation_doc = load_yaml(root, "specs/product/addendum-operation-contracts.yaml", checks)
    command_doc = load_yaml(root, "specs/product/addendum-command-semantics.yaml", checks)
    event_doc = load_yaml(root, "specs/product/addendum-event-contracts.yaml", checks)
    persistence_doc = load_yaml(root, "specs/product/addendum-persistence-contracts.yaml", checks)
    state_doc = load_yaml(root, "specs/product/addendum-state-machines.yaml", checks)
    resource_doc = load_yaml(root, "specs/product/addendum-resource-error-contracts.yaml", checks)
    session_doc = load_yaml(root, "specs/submission/addendum-derived-session-boundary.yaml", checks)
    database_doc = load_yaml(root, "specs/database/addendum/global.yaml", checks)
    closure_doc = load_yaml(root, "implementation-evidence/design-screen-closure.yaml", checks)
    domain_doc = load_yaml(root, "implementation-evidence/design-domain-closure.yaml", checks)
    nav_doc = load_yaml(root, "specs/ui/navigation-action-contracts.yaml", checks)
    profile_doc = load_yaml(root, "specs/ui/state-profile-contracts.yaml", checks)
    occurrence_doc = load_yaml(root, "specs/ui/state-occurrence-contracts.yaml", checks)
    action_doc = load_yaml(root, "specs/ui/screen-action-contracts.yaml", checks)
    effective_screen_doc = load_yaml(root, "specs/ui/effective-screen-contracts.yaml", checks)
    accessibility_doc = load_yaml(root, "specs/ui/accessibility-responsive-contracts.yaml", checks)

    base_ops = row_ids(base_operations_doc.get("operations"), "operation_id", "base operations", checks)
    base_persistence = row_ids(base_persistence_doc.get("operations"), "operation_id", "base persistence", checks)
    base_commands = row_ids(base_commands_doc.get("commands"), "operation_id", "base commands", checks)
    command_catalog = row_ids(command_catalog_doc.get("commands"), "operation_id", "command catalog", checks)
    base_operation_rows = {
        row["operation_id"]: row
        for row in base_operations_doc.get("operations", [])
        if isinstance(row, dict) and isinstance(row.get("operation_id"), str)
    }
    base_command_expected = {
        operation_id
        for operation_id, row in base_operation_rows.items()
        if row.get("operation_kind") == "COMMAND"
    }
    checks.equal(base_ops, base_persistence, "base operation persistence", "operations", "persistence")
    checks.equal(base_commands, base_command_expected, "base command kinds", "semantics", "operation kind")
    # The immutable v13 architecture catalog intentionally covers 97 repository
    # commands, while command-semantics also owns protocol/boundary commands.
    # It is a declared subset, not a second 105-row witness.
    checks.subset(command_catalog, base_commands, "base command catalog")
    checks.count(command_catalog_doc.get("command_count"), command_catalog, "architecture command count")
    for key in ("operation_count", "http_operation_count", "api_operation_count"):
        if key in base_operations_doc:
            checks.count(base_operations_doc[key], base_ops, f"base operations.{key}")
    checks.count(base_commands_doc.get("command_count"), base_commands, "base commands.command_count")

    owner_additive = row_ids(owner_doc.get("additive_operations"), "operation_id", "owner additive operations", checks)
    owner_private_control = row_ids(
        owner_doc.get("private_control_service_operations"),
        "operation_id",
        "owner private control operations",
        checks,
    )
    owner_private_application_doc = owner_doc.get("private_application_commands", {})
    owner_private_application = row_ids(
        owner_private_application_doc.get("commands")
        if isinstance(owner_private_application_doc, dict)
        else None,
        "operation_id",
        "owner private application commands",
        checks,
    )
    contract_additive = row_ids(operation_doc.get("operations"), "operation_id", "additive operation contracts", checks)
    contract_private_control = mapping_keys(
        operation_doc.get("private_control_service_operations"),
        "private control operation contracts",
        checks,
    )
    contract_private_application = mapping_keys(
        operation_doc.get("private_application_commands"),
        "private application operation contracts",
        checks,
    )
    screen_binding_ops = mapping_keys(operation_doc.get("operation_screen_bindings"), "operation screen bindings", checks)
    operation_transactions = mapping_keys(persistence_doc.get("operation_transactions"), "operation transactions", checks)
    exact_registry = persistence_doc.get("exact_persistence_registry", {})
    exact_query = mapping_keys(exact_registry.get("query_persistence") if isinstance(exact_registry, dict) else None, "query persistence", checks)
    exact_commands = mapping_keys(exact_registry.get("external_command_persistence") if isinstance(exact_registry, dict) else None, "command persistence", checks)
    exact_callbacks = mapping_keys(exact_registry.get("private_callback_persistence") if isinstance(exact_registry, dict) else None, "callback persistence", checks)
    exact_private_control = mapping_keys(
        exact_registry.get("private_control_service_persistence")
        if isinstance(exact_registry, dict)
        else None,
        "private control persistence",
        checks,
    )
    exact_private_application = mapping_keys(
        exact_registry.get("private_application_command_persistence")
        if isinstance(exact_registry, dict)
        else None,
        "private application persistence",
        checks,
    )
    exact_additive = exact_query | exact_commands
    callback_ops = row_ids(owner_doc.get("private_communication_gateway_operations"), "operation_id", "owner callbacks", checks)
    callback_semantics = mapping_keys(command_doc.get("private_callback_operations"), "callback semantics", checks)
    private_control_semantics = mapping_keys(
        command_doc.get("private_control_service_commands"),
        "private control semantics",
        checks,
    )
    private_application_semantics = mapping_keys(
        command_doc.get("private_application_commands"),
        "private application semantics",
        checks,
    )
    private_control_transactions = mapping_keys(
        persistence_doc.get("private_control_service_transactions"),
        "private control transactions",
        checks,
    )
    private_control_lifecycle_raw = state_doc.get(
        "private_control_lifecycle_bindings", {}
    )
    private_control_lifecycle = mapping_keys(
        private_control_lifecycle_raw.get("current_bindings")
        if isinstance(private_control_lifecycle_raw, dict)
        else None,
        "private control lifecycle bindings",
        checks,
    )
    private_application_lifecycle_raw = state_doc.get(
        "private_application_lifecycle_bindings", {}
    )
    private_application_lifecycle = mapping_keys(
        private_application_lifecycle_raw.get("current_bindings")
        if isinstance(private_application_lifecycle_raw, dict)
        else None,
        "private application lifecycle bindings",
        checks,
    )
    resource_ops = mapping_keys(resource_doc.get("operation_bindings"), "resource operation bindings", checks)
    resource_external = resource_ops - callback_ops - owner_private_control
    resource_private_application = mapping_keys(
        resource_doc.get("private_application_command_bindings"),
        "private application resource bindings",
        checks,
    )
    resource_private_application_requests = mapping_keys(
        resource_doc.get("private_application_request_schemas"),
        "private application request schemas",
        checks,
    )
    resource_private_application_errors = mapping_keys(
        resource_doc.get("private_application_error_sets"),
        "private application error sets",
        checks,
    )
    for witness_name, witness in {
        "contract": contract_additive,
        "screen-binding": screen_binding_ops,
        "operation-transaction": operation_transactions,
        "exact-persistence": exact_additive,
        "resource": resource_external,
    }.items():
        checks.equal(owner_additive, witness, f"additive operations/{witness_name}", "owner", witness_name)
    checks.equal(callback_ops, callback_semantics, "callback semantics", "owner", "semantics")
    checks.equal(callback_ops, exact_callbacks, "callback persistence", "owner", "persistence")
    checks.equal(callback_ops, resource_ops & callback_ops, "callback resources", "owner", "resource")
    for witness_name, witness in {
        "contract": contract_private_control,
        "semantics": private_control_semantics,
        "transaction": private_control_transactions,
        "persistence": exact_private_control,
        "resource": resource_ops & owner_private_control,
        "lifecycle": private_control_lifecycle,
    }.items():
        checks.equal(
            owner_private_control,
            witness,
            f"private control/{witness_name}",
            "owner",
            witness_name,
        )
    for witness_name, witness in {
        "contract": contract_private_application,
        "semantics": private_application_semantics,
        "persistence": exact_private_application,
        "resource-binding": resource_private_application,
        "resource-request": resource_private_application_requests,
        "resource-error": resource_private_application_errors,
        "lifecycle": private_application_lifecycle,
    }.items():
        checks.equal(
            owner_private_application,
            witness,
            f"private application/{witness_name}",
            "owner",
            witness_name,
        )
    checks.equal(
        owner_additive | callback_ops | owner_private_control,
        resource_ops,
        "all additive HTTP resources",
        "owner",
        "resource",
    )
    checks.require(not (base_ops & owner_additive), "operation_collision", "effective operations", [], sorted(base_ops & owner_additive))
    checks.require(not ((base_ops | owner_additive) & callback_ops), "operation_collision", "callback operations", [], sorted((base_ops | owner_additive) & callback_ops))
    checks.require(
        not (owner_private_control & (base_ops | owner_additive | callback_ops)),
        "operation_collision",
        "private control operations",
        [],
        sorted(owner_private_control & (base_ops | owner_additive | callback_ops)),
    )
    checks.require(
        not (
            owner_private_application
            & (base_ops | owner_additive | callback_ops | owner_private_control)
        ),
        "operation_collision",
        "private application commands",
        [],
        sorted(
            owner_private_application
            & (base_ops | owner_additive | callback_ops | owner_private_control)
        ),
    )

    additive_rows = {
        row["operation_id"]: row
        for row in operation_doc.get("operations", [])
        if isinstance(row, dict) and isinstance(row.get("operation_id"), str)
    }
    additive_commands = {key for key, row in additive_rows.items() if row.get("kind") == "COMMAND"}
    additive_queries = {key for key, row in additive_rows.items() if row.get("kind") == "QUERY"}
    command_semantics = mapping_keys(command_doc.get("external_commands"), "external command semantics", checks)
    operation_dispositions = mapping_keys(state_doc.get("operation_dispositions"), "operation dispositions", checks)
    checks.equal(additive_commands, command_semantics, "additive commands", "operation kind", "semantics")
    checks.equal(additive_commands, exact_commands, "additive command persistence", "operation kind", "persistence")
    checks.equal(additive_commands, operation_dispositions, "additive command state disposition", "commands", "dispositions")
    checks.equal(additive_queries, exact_query, "additive query persistence", "operation kind", "persistence")
    callback_rows = {
        row["operation_id"]: row
        for row in owner_doc.get("private_communication_gateway_operations", [])
        if isinstance(row, dict) and isinstance(row.get("operation_id"), str)
    }
    callback_commands = {key for key, row in callback_rows.items() if row.get("kind") == "COMMAND"}
    callback_queries = callback_ops - callback_commands
    private_control_rows = {
        row["operation_id"]: row
        for row in owner_doc.get("private_control_service_operations", [])
        if isinstance(row, dict) and isinstance(row.get("operation_id"), str)
    }
    private_control_commands = {
        key for key, row in private_control_rows.items() if row.get("kind") == "COMMAND"
    }
    private_control_queries = owner_private_control - private_control_commands
    identity_commands = row_ids(
        identity_trace_doc.get("operations"),
        "operation_id",
        "private identity operation count witness",
        checks,
    )
    checks.require(
        not (identity_commands & (base_ops | owner_additive | callback_ops)),
        "operation_collision",
        "private identity operations",
        [],
        sorted(identity_commands & (base_ops | owner_additive | callback_ops)),
    )
    owner_operation_counts = owner_doc.get("operation_counts", {})
    if isinstance(owner_operation_counts, dict):
        base_by_api = {
            "public": sum(row.get("api") == "public-api" for row in base_operation_rows.values()),
            "submission": sum(row.get("api") == "submission-api" for row in base_operation_rows.values()),
            "control": sum(row.get("api") == "control-api" for row in base_operation_rows.values()),
            "browser_identity": sum(row.get("api") == "identity-provider" for row in base_operation_rows.values()),
        }
        additive_by_api = {
            "public": sum(row.get("api") == "public-api" for row in additive_rows.values()),
            "submission": sum(row.get("api") == "submission-api" for row in additive_rows.values()),
            "control": sum(row.get("api") == "control-api" for row in additive_rows.values()),
            "browser_identity": sum(row.get("api") == "identity-provider" for row in additive_rows.values()),
        }
        base_declared = owner_operation_counts.get("base", {})
        additive_declared = owner_operation_counts.get("additive", {})
        final_declared = owner_operation_counts.get("final", {})
        for name, value in base_by_api.items():
            if isinstance(base_declared, dict):
                checks.count_value(base_declared.get(name), value, f"owner operations base.{name}")
        for name, value in additive_by_api.items():
            if isinstance(additive_declared, dict):
                checks.count_value(additive_declared.get(name), value, f"owner operations additive.{name}")
        if isinstance(base_declared, dict):
            checks.count(base_declared.get("external_total"), base_ops, "owner base external operations")
            checks.count(base_declared.get("private_identity"), identity_commands, "owner private identity operations")
        if isinstance(final_declared, dict):
            checks.count(final_declared.get("external_total"), base_ops | owner_additive, "owner final external operations")
            checks.count(final_declared.get("private_identity"), identity_commands, "owner final private identity operations")
            checks.count(final_declared.get("private_communication_gateway"), callback_ops, "owner private callback operations")
            checks.count(
                final_declared.get("private_control_service"),
                owner_private_control,
                "owner private control operations",
            )
            checks.count(
                final_declared.get("private_application_commands"),
                owner_private_application,
                "owner private application commands",
            )
            for name in base_by_api:
                checks.count_value(
                    final_declared.get(name),
                    base_by_api[name] + additive_by_api[name],
                    f"owner operations final.{name}",
                )
        kind_counts = owner_operation_counts.get("kind_counts", {})
        if isinstance(kind_counts, dict):
            kind_witnesses = {
                "base": {"query": len(base_ops - base_commands), "command": len(base_commands)},
                "additive": {"query": len(additive_queries), "command": len(additive_commands)},
                "external_final": {"query": len((base_ops - base_commands) | additive_queries), "command": len(base_commands | additive_commands)},
                "private_identity": {"query": 0, "command": len(identity_commands)},
                "private_communication_gateway": {"query": len(callback_queries), "command": len(callback_commands)},
                "private_control_service": {
                    "query": len(private_control_queries),
                    "command": len(private_control_commands),
                },
                "private_application_commands": {
                    "query": 0,
                    "command": len(owner_private_application),
                },
                "complete_http_catalog": {
                    "query": len(
                        (base_ops - base_commands)
                        | additive_queries
                        | callback_queries
                        | private_control_queries
                    ),
                    "command": len(
                        base_commands
                        | additive_commands
                        | identity_commands
                        | callback_commands
                        | private_control_commands
                    ),
                    "total": len(
                        base_ops
                        | owner_additive
                        | identity_commands
                        | callback_ops
                        | owner_private_control
                    ),
                },
            }
            for group, expected in kind_witnesses.items():
                checks.count_mapping(
                    kind_counts.get(group),
                    expected,
                    f"owner operation kind counts.{group}",
                )

    base_events = row_ids(base_events_doc.get("events"), "event_type", "base events", checks)
    additive_events = mapping_keys(event_doc.get("events"), "additive events", checks)
    owner_event_delta = owner_doc.get("event_delta", {})
    owner_events = checks.unique(owner_event_delta.get("event_types", []) if isinstance(owner_event_delta, dict) else [], "owner event delta")
    checks.equal(additive_events, owner_events, "additive events", "catalog", "owner")
    checks.require(not (base_events & additive_events), "event_collision", "effective events", [], sorted(base_events & additive_events))
    checks.count(base_events_doc.get("event_count"), base_events, "base event count")
    checks.count(event_doc.get("event_count"), additive_events, "additive event count")
    effective_events = base_events | additive_events
    if isinstance(owner_event_delta, dict):
        checks.count(owner_event_delta.get("base_events"), base_events, "owner base event count")
        checks.count(owner_event_delta.get("additive_events"), additive_events, "owner additive event count")
        checks.count(owner_event_delta.get("final_events"), effective_events, "owner final event count")
    event_references = (
        collect_event_tokens(base_commands_doc.get("commands"))
        | collect_event_tokens(command_doc.get("external_commands"))
        | collect_event_tokens(command_doc.get("private_callback_operations"))
        | collect_event_tokens(command_doc.get("private_control_service_commands"))
        | collect_event_tokens(command_doc.get("private_application_commands"))
        | collect_event_tokens(state_doc.get("machines"))
        | collect_event_tokens(domain_doc.get("bindings"))
    )
    checks.subset(event_references, effective_events, "event references")

    base_tables = {
        f"{row.get('schema')}.{row.get('table')}"
        for row in base_schema_doc.get("tables", [])
        if isinstance(row, dict) and isinstance(row.get("schema"), str) and isinstance(row.get("table"), str)
    }
    checks.count(base_schema_doc.get("table_count"), base_tables, "base table count")
    owner_database_delta = owner_doc.get("database_delta", {})
    owner_tables = checks.unique(owner_database_delta.get("additive_tables", []) if isinstance(owner_database_delta, dict) else [], "owner additive tables")
    migration_ownership_raw = persistence_doc.get("migration_ownership", {})
    migration_ownership = {
        str(name): checks.unique(tables if isinstance(tables, list) else [], f"migration ownership {name}")
        for name, tables in migration_ownership_raw.items()
    } if isinstance(migration_ownership_raw, dict) else {}
    persistence_tables = set().union(*migration_ownership.values(), set())
    physical_tables, physical_by_ordinal = physical_table_set(root, checks)
    checks.equal(owner_tables, persistence_tables, "additive tables/persistence", "owner", "migration ownership")
    checks.equal(owner_tables, physical_tables, "additive tables/physical", "owner", "physical contracts")
    inventory_lock = database_doc.get("inventory_lock", {})
    if isinstance(inventory_lock, dict):
        checks.count(inventory_lock.get("additive_tables"), physical_tables, "database inventory additive tables")
        by_migration = inventory_lock.get(
            "relation_delta_by_migration",
            inventory_lock.get("additive_by_migration", {}),
        )
        if isinstance(by_migration, dict):
            for migration, relations in migration_ownership.items():
                checks.count(by_migration.get(migration), relations, f"database inventory {migration}")
            for migration, declared in by_migration.items():
                if migration not in migration_ownership:
                    checks.require(
                        declared == 0,
                        "unowned_migration_relation_count",
                        f"database inventory {migration}",
                        0,
                        declared,
                    )
        sequence = inventory_lock.get("migration_sequence")
        if isinstance(sequence, list):
            sequence_set = checks.unique(sequence, "database migration sequence")
            checks.count(inventory_lock.get("final_migrations"), sequence_set, "database final migration count")
    renames = owner_database_delta.get("renamed_tables", []) if isinstance(owner_database_delta, dict) else []
    rename_from = {row.get("from") for row in renames if isinstance(row, dict) and isinstance(row.get("from"), str)}
    rename_to = {row.get("to") for row in renames if isinstance(row, dict) and isinstance(row.get("to"), str)}
    checks.subset(rename_from, base_tables, "rename sources")
    checks.require(not (rename_to & (base_tables - rename_from)), "rename_collision", "rename targets", [], sorted(rename_to & (base_tables - rename_from)))
    effective_tables = (base_tables - rename_from) | rename_to | physical_tables
    checks.require(
        not (physical_tables & ((base_tables - rename_from) | rename_to)),
        "table_collision",
        "additive physical tables",
        [],
        sorted(physical_tables & ((base_tables - rename_from) | rename_to)),
    )
    if isinstance(inventory_lock, dict):
        checks.count(inventory_lock.get("final_active_tables"), effective_tables, "database final table count")
    if isinstance(owner_database_delta, dict):
        checks.count(owner_database_delta.get("base_active_tables"), base_tables, "owner base table count")
        checks.count(owner_database_delta.get("additive_table_count"), physical_tables, "owner additive table count")
        checks.count(owner_database_delta.get("final_active_tables"), effective_tables, "owner final table count")

    base_migrations = {path.name for path in (root / "specs/database/migrations").glob("*.sql") if MIGRATION_RE.fullmatch(path.name)}
    runtime_migrations = {path.name for path in (root / "db/migrations").glob("*.sql") if MIGRATION_RE.fullmatch(path.name)}
    checks.count(base_schema_doc.get("migration_count"), base_migrations, "base migration count")
    owner_migrations = checks.unique(owner_database_delta.get("migrations", []) if isinstance(owner_database_delta, dict) else [], "owner additive migrations")
    persistence_migrations = set(migration_ownership)
    planned_migrations = mapping_keys(database_doc.get("migration_plan"), "database migration plan", checks)
    checks.equal(owner_migrations, persistence_migrations, "additive migrations/persistence", "owner", "persistence")
    checks.require(
        not (base_migrations & planned_migrations),
        "migration_collision",
        "post-base migration plan",
        [],
        sorted(base_migrations & planned_migrations),
    )
    if isinstance(owner_database_delta, dict):
        checks.count(owner_database_delta.get("base_migrations"), base_migrations, "owner base migration count")
        checks.count(owner_database_delta.get("additive_migrations"), owner_migrations, "owner additive migration count")
        checks.count_value(
            owner_database_delta.get("final_migrations"),
            len(base_migrations | owner_migrations),
            "owner final product migration count",
        )
    relation_deltas = (
        inventory_lock.get(
            "relation_delta_by_migration",
            inventory_lock.get("additive_by_migration", {}),
        )
        if isinstance(inventory_lock, dict)
        else {}
    )
    zero_relation_migrations = (
        {str(name) for name, count in relation_deltas.items() if count == 0}
        if isinstance(relation_deltas, dict)
        else set()
    )
    checks.equal(
        owner_migrations | zero_relation_migrations,
        planned_migrations,
        "post-base migrations/global",
        "product plus zero-relation hardening",
        "global",
    )
    planned_ordinals = {
        name[:4]
        for name in planned_migrations - zero_relation_migrations
        if MIGRATION_RE.fullmatch(name)
    }
    checks.equal(planned_ordinals, set(physical_by_ordinal), "migration fragments", "planned ordinals", "physical ordinals")
    relation_inventory = database_doc.get("relation_inventory", {})
    relation_inventory_by_migration = (
        relation_inventory.get("by_migration", {})
        if isinstance(relation_inventory, dict)
        else {}
    )
    if isinstance(relation_inventory_by_migration, dict):
        inventory_migrations = set(relation_inventory_by_migration)
        checks.require(
            persistence_migrations <= inventory_migrations,
            "relation_inventory_migration_set",
            "database relation inventory",
            sorted(persistence_migrations),
            sorted(inventory_migrations),
        )
        for migration, relations in migration_ownership.items():
            inventory_relations = checks.unique(
                relation_inventory_by_migration.get(migration, []),
                f"relation inventory {migration}",
            )
            checks.equal(
                relations,
                inventory_relations,
                f"relation inventory {migration}",
                "persistence",
                "global",
            )

    base_sessions = mapping_keys(base_sessions_doc.get("session_kinds"), "base sessions", checks)
    derived_sessions = mapping_keys(session_doc.get("session_kinds"), "derived sessions", checks)
    checks.require(not (base_sessions & derived_sessions), "session_collision", "effective sessions", [], sorted(base_sessions & derived_sessions))
    derived_rows = session_doc.get("session_kinds", {}) if isinstance(session_doc.get("session_kinds"), dict) else {}
    derived_session_operations = {
        operation
        for row in derived_rows.values()
        if isinstance(row, dict)
        for operation in row.get("allowed_operations", [])
        if isinstance(operation, str)
    }
    authorization_overlay = mapping_keys(session_doc.get("operation_authorization_overlay"), "session authorization overlay", checks)
    checks.equal(derived_session_operations, authorization_overlay, "derived session operations", "session kinds", "authorization overlay")
    cookie_profiles = session_doc.get("cookie_profiles", {})
    cookie_kinds = {
        kind
        for value in cookie_profiles.values()
        if isinstance(value, dict)
        for kind in value.get("session_kinds", [])
        if isinstance(kind, str)
    } if isinstance(cookie_profiles, dict) else set()
    checks.equal(derived_sessions, cookie_kinds, "derived session cookies", "sessions", "cookie profiles")
    checks.subset(derived_session_operations, owner_additive, "derived session operation references")

    machines = mapping_keys(state_doc.get("machines"), "additive state machines", checks)
    machine_rows = state_doc.get("machines", {}) if isinstance(state_doc.get("machines"), dict) else {}
    machine_states: set[str] = set()
    machine_operations: set[str] = set()
    machine_private_operations: set[str] = set()
    machine_private_commands: set[str] = set()
    private_operation_machine_targets: dict[str, set[str]] = {}
    private_command_machine_targets: dict[str, set[str]] = {}
    machine_edges: list[str] = []
    for machine, row in machine_rows.items():
        if not isinstance(row, dict):
            checks.require(False, "invalid_machine", f"state machine {machine}", "mapping", row)
            continue
        state_dimensions = {
            key: checks.unique(value, f"state machine {machine}.{key}")
            for key, value in row.items()
            if (key == "states" or key.endswith("_states")) and isinstance(value, list)
        }
        checks.require(
            bool(state_dimensions),
            "invalid_machine",
            f"state machine {machine}",
            "states or *_states list",
            sorted(row),
        )
        states = set().union(*state_dimensions.values(), set())
        terminals = checks.unique(row.get("terminal", []), f"state machine {machine}.terminal")
        checks.subset(terminals, states, f"state machine {machine}.terminal")
        for dimension, values in state_dimensions.items():
            machine_states.update(
                (
                    f"{machine}::{state}"
                    if dimension == "states"
                    else f"{machine}::{dimension}::{state}"
                )
                for state in values
            )
        edges = row.get("edges", [])
        if not isinstance(edges, list):
            checks.require(False, "invalid_machine_edges", machine, "list", type(edges).__name__)
            continue
        for index, edge in enumerate(edges):
            if not isinstance(edge, dict):
                checks.require(False, "invalid_machine_edge", f"{machine}[{index}]", "mapping", edge)
                continue
            owner_fields = {
                key: edge.get(key)
                for key in ("operation", "private_operation", "actor")
                if isinstance(edge.get(key), str) and bool(edge.get(key).strip())
            }
            checks.require(
                len(owner_fields) == 1,
                "invalid_machine_edge",
                f"{machine}[{index}]",
                "exactly one operation, private_operation or actor",
                owner_fields,
            )
            canonical = json.dumps(edge, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            edge_digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
            machine_edges.append(f"{machine}::{edge_digest}")
            if isinstance(edge.get("operation"), str):
                machine_operations.add(edge["operation"])
            if isinstance(edge.get("private_operation"), str):
                machine_private_operations.add(edge["private_operation"])
                private_operation_machine_targets.setdefault(
                    edge["private_operation"], set()
                ).add(machine)
            if isinstance(edge.get("private_command"), str):
                machine_private_commands.add(edge["private_command"])
                private_command_machine_targets.setdefault(
                    edge["private_command"], set()
                ).add(machine)
    checks.unique(machine_edges, "state machine semantic edges")
    checks.subset(machine_operations, base_ops | owner_additive, "state-machine operation references")
    checks.equal(
        owner_private_control,
        machine_private_operations,
        "state-machine private operation references",
        "owner",
        "machine edges",
    )
    checks.equal(
        owner_private_application,
        machine_private_commands,
        "state-machine private command references",
        "owner",
        "machine edges",
    )
    private_control_binding_rows = (
        private_control_lifecycle_raw.get("current_bindings", {})
        if isinstance(private_control_lifecycle_raw, dict)
        else {}
    )
    for operation_id in sorted(owner_private_control):
        targets = private_control_binding_rows.get(operation_id, [])
        binding_roots = {
            target.split(".", 1)[0]
            for target in targets
            if isinstance(target, str)
        }
        checks.equal(
            binding_roots,
            private_operation_machine_targets.get(operation_id, set()),
            f"private control lifecycle target {operation_id}",
            "binding",
            "machine edges",
        )
    private_application_binding_rows = (
        private_application_lifecycle_raw.get("current_bindings", {})
        if isinstance(private_application_lifecycle_raw, dict)
        else {}
    )
    for operation_id in sorted(owner_private_application):
        targets = private_application_binding_rows.get(operation_id, [])
        binding_roots = {
            target.split(".", 1)[0]
            for target in targets
            if isinstance(target, str)
        }
        checks.equal(
            binding_roots,
            private_command_machine_targets.get(operation_id, set()),
            f"private application lifecycle target {operation_id}",
            "binding",
            "machine edges",
        )
    base_lifecycle = state_doc.get("base_operation_lifecycle_bindings", {})
    base_lifecycle_bindings = mapping_keys(
        base_lifecycle.get("current_bindings") if isinstance(base_lifecycle, dict) else None,
        "base operation lifecycle bindings",
        checks,
    )
    checks.equal(
        machine_operations & base_ops,
        base_lifecycle_bindings,
        "base operation lifecycle coverage",
        "machine edges",
        "declared bindings",
    )
    for source, bindings in (
        ("operation dispositions", state_doc.get("operation_dispositions", {})),
        (
            "base operation lifecycle bindings",
            base_lifecycle.get("current_bindings", {})
            if isinstance(base_lifecycle, dict)
            else {},
        ),
        (
            "private control lifecycle bindings",
            private_control_lifecycle_raw.get("current_bindings", {})
            if isinstance(private_control_lifecycle_raw, dict)
            else {},
        ),
        (
            "private application lifecycle bindings",
            private_application_lifecycle_raw.get("current_bindings", {})
            if isinstance(private_application_lifecycle_raw, dict)
            else {},
        ),
    ):
        if not isinstance(bindings, dict):
            continue
        for operation_id, targets in bindings.items():
            target_rows = targets if isinstance(targets, list) else []
            checks.require(
                isinstance(targets, list) and bool(targets),
                "invalid_lifecycle_binding",
                f"{source}.{operation_id}",
                "nonempty list",
                targets,
            )
            referenced_machines = {
                target.split(".", 1)[0]
                for target in target_rows
                if isinstance(target, str)
            }
            checks.subset(
                referenced_machines,
                machines,
                f"{source}.{operation_id} machine references",
            )
    immutable_lifecycles = mapping_keys(
        state_doc.get("immutable_fact_lifecycles"),
        "immutable fact lifecycles",
        checks,
    )
    checks.subset(immutable_lifecycles, effective_events, "immutable fact lifecycle events")

    profiles_raw = archetypes_doc.get("state_profiles", {})
    profiles = {
        str(profile): checks.unique(states if isinstance(states, list) else [], f"state profile {profile}")
        for profile, states in profiles_raw.items()
    } if isinstance(profiles_raw, dict) else {}
    expected_templates = {f"{profile}::{state}" for profile, states in profiles.items() for state in states}
    template_ids = row_ids(profile_doc.get("templates"), "profile_state_id", "state profile templates", checks)
    checks.equal(expected_templates, template_ids, "state profile semantics", "archetypes", "templates")
    profile_counts = profile_doc.get("counts", {})
    if isinstance(profile_counts, dict):
        checks.count_value(profile_counts.get("profiles"), len(profiles), "state profile count")
        unique_profile_states = set().union(*profiles.values(), set())
        checks.count_value(
            profile_counts.get("unique_state_semantics"),
            len(unique_profile_states),
            "unique state semantics count",
        )
        checks.count(profile_counts.get("profile_state_templates"), template_ids, "profile state template count")

    screens = row_ids(base_screens_doc.get("screens"), "id", "base screens", checks)
    trace_screens = row_ids(base_trace_doc.get("screens"), "screen_id", "base trace screens", checks)
    closure_screens = row_ids(closure_doc.get("screens"), "screen_id", "design screen closure", checks)
    effective_screens = row_ids(effective_screen_doc.get("screens"), "screen_id", "effective screens", checks)
    accessibility_screens = row_ids(accessibility_doc.get("screens"), "screen_id", "accessibility screens", checks)
    for name, witness in {
        "trace": trace_screens,
        "closure": closure_screens,
        "effective": effective_screens,
        "accessibility": accessibility_screens,
    }.items():
        checks.equal(screens, witness, f"screen registry/{name}", "catalog", name)
    checks.count(base_screens_doc.get("screen_count"), screens, "base screen count")
    checks.count(closure_doc.get("screen_count"), closure_screens, "closure screen count")

    base_screen_rows = {
        row["id"]: row for row in base_screens_doc.get("screens", [])
        if isinstance(row, dict) and isinstance(row.get("id"), str)
    }
    closure_rows = {
        row["screen_id"]: row for row in closure_doc.get("screens", [])
        if isinstance(row, dict) and isinstance(row.get("screen_id"), str)
    }
    base_actions = checks.unique(
        [f"{screen_id}.{action.get('id')}" for screen_id, row in base_screen_rows.items() for action in row.get("actions", []) if isinstance(action, dict) and isinstance(action.get("id"), str)],
        "base screen actions",
    )
    closure_actions = checks.unique(
        [f"{screen_id}.{action.get('action_id')}" for screen_id, row in closure_rows.items() for action in row.get("action_contracts", []) if isinstance(action, dict) and isinstance(action.get("action_id"), str)],
        "closure screen actions",
    )
    checks.equal(base_actions, closure_actions, "base screen action closure", "catalog", "closure")
    nav_actions = mapping_keys(nav_doc.get("navigation_contracts"), "navigation actions", checks)
    closure_nav = checks.unique(
        [f"{screen_id}.{action.get('action_id')}" for screen_id, row in closure_rows.items() for action in row.get("navigation_actions", []) if isinstance(action, dict) and isinstance(action.get("action_id"), str)],
        "closure navigation actions",
    )
    checks.equal(nav_actions, closure_nav, "navigation action closure", "navigation", "closure")
    nav_focus = row_ids(accessibility_doc.get("navigation_focus_contracts"), "navigation_key", "navigation focus", checks)
    checks.equal(nav_actions, nav_focus, "navigation focus closure", "navigation", "focus")

    action_commands = row_ids(action_doc.get("commands"), "operation_id", "screen command actions", checks)
    checks.equal(additive_commands, action_commands, "additive command screen actions", "commands", "screen actions")
    command_placements: list[str] = []
    command_rows = action_doc.get("commands", []) if isinstance(action_doc.get("commands"), list) else []
    for row in command_rows:
        if not isinstance(row, dict) or not isinstance(row.get("operation_id"), str):
            continue
        placements = row.get("placements", [])
        checks.require(bool(placements), "unreachable_command", row["operation_id"], ">=1 screen placement", 0)
        for placement in placements if isinstance(placements, list) else []:
            if isinstance(placement, dict) and isinstance(placement.get("screen_id"), str) and isinstance(placement.get("action_id"), str):
                checks.subset({placement["screen_id"]}, screens, f"{row['operation_id']} placement")
                command_placements.append(f"{placement['screen_id']}.{placement['action_id']}")
            else:
                checks.require(False, "invalid_action_placement", row["operation_id"], "screen_id+action_id", placement)
    placement_actions = checks.unique(command_placements, "additive command placements")
    action_counts = action_doc.get("counts", {})
    if isinstance(action_counts, dict):
        checks.count(action_counts.get("commands"), action_commands, "screen action command count")
        checks.count_value(
            action_counts.get("visible_placements"),
            len(command_placements),
            "screen action placement count",
        )
        for field in ("journey_visible_actions", "legacy_side_door_fences"):
            rows = action_doc.get(field, [])
            if isinstance(rows, list):
                checks.count_value(
                    action_counts.get(field),
                    len(rows),
                    f"screen action {field} count",
                )

    closure_profile_occurrences: set[str] = set()
    closure_special_occurrences: set[str] = set()
    for screen_id, row in closure_rows.items():
        profile = row.get("state_profile", {})
        if not isinstance(profile, dict) or not isinstance(profile.get("name"), str):
            checks.require(False, "invalid_screen_profile", screen_id, "profile mapping", profile)
            continue
        profile_name = profile["name"]
        states = checks.unique(profile.get("states", []), f"{screen_id} profile states")
        checks.equal(states, profiles.get(profile_name, set()), f"{screen_id} effective profile", "screen", "archetype")
        closure_profile_occurrences.update(f"{screen_id}::profile::{state}" for state in states)
        special = checks.unique(profile.get("special_states", []), f"{screen_id} special states")
        closure_special_occurrences.update(f"{screen_id}::special::{state}" for state in special)
    occurrence_profiles = row_ids(occurrence_doc.get("profile_occurrences"), "occurrence_id", "profile state occurrences", checks)
    occurrence_special = row_ids(occurrence_doc.get("special_occurrences"), "occurrence_id", "special state occurrences", checks)
    checks.equal(closure_profile_occurrences, occurrence_profiles, "profile state occurrences", "closure", "occurrence registry")
    checks.equal(closure_special_occurrences, occurrence_special, "special state occurrences", "closure", "occurrence registry")
    occurrence_counts = occurrence_doc.get("counts", {})
    if isinstance(occurrence_counts, dict):
        checks.count(occurrence_counts.get("profile_occurrences"), occurrence_profiles, "profile occurrence count")
        checks.count(occurrence_counts.get("special_occurrences"), occurrence_special, "special occurrence count")
        checks.count_value(
            occurrence_counts.get("total_occurrences"),
            len(occurrence_profiles | occurrence_special),
            "total state occurrence count",
        )

    effective_screen_rows = {
        row["screen_id"]: row for row in effective_screen_doc.get("screens", [])
        if isinstance(row, dict) and isinstance(row.get("screen_id"), str)
    }
    for screen_id in screens:
        closure_ops = {
            item.get("operation_id") for item in closure_rows.get(screen_id, {}).get("operations", [])
            if isinstance(item, dict) and isinstance(item.get("operation_id"), str)
        }
        effective_ops = {
            item.get("operation_id") for item in effective_screen_rows.get(screen_id, {}).get("operation_field_contracts", [])
            if isinstance(item, dict) and isinstance(item.get("operation_id"), str)
        }
        checks.equal(closure_ops, effective_ops, f"{screen_id} operation trace", "closure", "effective screen")
    effective_screen_counts = effective_screen_doc.get("counts", {})
    if isinstance(effective_screen_counts, dict):
        checks.count(effective_screen_counts.get("screens"), effective_screens, "effective screen count")
        operation_occurrences = [
            item
            for row in effective_screen_rows.values()
            for item in row.get("operation_field_contracts", [])
            if isinstance(item, dict)
        ]
        base_occurrences = sum(
            item.get("source") == "specs/ui/screen-data-contracts.yaml"
            for item in operation_occurrences
        )
        additive_occurrences = len(operation_occurrences) - base_occurrences
        checks.count_value(
            effective_screen_counts.get("base_operation_occurrences"),
            base_occurrences,
            "effective base operation occurrences",
        )
        checks.count_value(
            effective_screen_counts.get("additive_operation_section_occurrences"),
            additive_occurrences,
            "effective additive operation occurrences",
        )
    additive_screen_trace = {
        item.get("operation_id")
        for row in closure_rows.values()
        for item in row.get("operations", [])
        if isinstance(item, dict) and item.get("source") != "v13-authority" and isinstance(item.get("operation_id"), str)
    }
    checks.equal(owner_additive, additive_screen_trace, "additive operation screen trace", "operations", "screen trace")
    trace_operations = row_ids(base_trace_doc.get("operations"), "operation_id", "base operation trace", checks)
    checks.equal(base_ops, trace_operations, "base operation trace", "operations", "trace")
    identity_operations = row_ids(identity_trace_doc.get("operations"), "operation_id", "private identity trace", checks)
    checks.count(identity_trace_doc.get("operation_count"), identity_operations, "private identity trace count")
    accessibility_counts = accessibility_doc.get("set_equality", {})
    if isinstance(accessibility_counts, dict):
        checks.count(accessibility_counts.get("screen_contracts"), accessibility_screens, "accessibility screen count")
        checks.count(accessibility_counts.get("navigation_focus_contracts"), nav_focus, "accessibility navigation focus count")
        required_checks = accessibility_counts.get("required_viewport_zoom_checks_per_screen")
        for screen_id, row in {
            item["screen_id"]: item
            for item in accessibility_doc.get("screens", [])
            if isinstance(item, dict) and isinstance(item.get("screen_id"), str)
        }.items():
            transformations = row.get("responsive_transformations", [])
            if isinstance(transformations, list):
                checks.count_value(
                    required_checks,
                    len(transformations),
                    f"{screen_id} viewport/zoom checks",
                )
            else:
                checks.require(
                    False,
                    "invalid_registry",
                    f"{screen_id} viewport/zoom checks",
                    "list",
                    type(transformations).__name__,
                )

    bindings = row_ids(domain_doc.get("bindings"), "noun", "domain bindings", checks)
    aliases = row_ids(domain_doc.get("aggregate_aliases"), "aggregate", "domain aggregate aliases", checks)
    checks.count(domain_doc.get("binding_count"), bindings, "domain binding count")
    checks.count(domain_doc.get("aggregate_alias_count"), aliases, "domain alias count")

    base_mapping_relative = "tests/acceptance/executable-mapping.yaml"
    base_mapping_doc = load_yaml(root, base_mapping_relative, checks)
    overlay_doc = load_yaml(root, "tests/acceptance/conflict-resolution-overlays.yaml", checks)
    base_tests = row_ids(
        base_mapping_doc.get("scenarios"),
        "scenario_id",
        "base executable scenarios",
        checks,
    )
    checks.count(
        base_mapping_doc.get("scenario_count"),
        base_tests,
        "base executable scenario count",
    )
    base_feature_ids: set[str] = set()
    locked_base_feature_paths = base_feature_paths(root, checks)
    discovered_base_feature_paths: set[str] = set()
    supplemental_feature_ids: set[str] = set()
    supplemental_feature_paths: list[str] = []
    supplemental_feature_rows: list[dict[str, str]] = []
    supplemental_feature_ids_by_path: dict[str, set[str]] = {}
    for path in sorted((root / "tests/acceptance").glob("**/*.feature")):
        relative = path.relative_to(root).as_posix()
        scenario_rows = parse_feature_scenarios(path, checks, relative)
        ids = {row["scenario_id"] for row in scenario_rows}
        if relative in locked_base_feature_paths:
            discovered_base_feature_paths.add(relative)
            base_feature_ids.update(ids)
        else:
            supplemental_feature_paths.append(relative)
            overlap = supplemental_feature_ids & ids
            checks.require(not overlap, "duplicate_supplemental_scenario", relative, [], sorted(overlap))
            supplemental_feature_ids.update(ids)
            supplemental_feature_rows.extend(scenario_rows)
            supplemental_feature_ids_by_path[relative] = ids
    checks.equal(
        locked_base_feature_paths,
        discovered_base_feature_paths,
        "base feature inventory",
        "lock",
        "features",
    )
    checks.equal(base_tests, base_feature_ids, "base feature mapping", "mapping", "features")

    mapping_candidates = sorted(
        {
            path
            for pattern in ("**/*executable-mapping.yaml", "**/*executable-mapping.yml")
            for path in (root / "tests/acceptance").glob(pattern)
        }
    )
    supplemental_mapping_documents: list[tuple[str, dict[str, Any]]] = []
    for path in mapping_candidates:
        relative = path.relative_to(root).as_posix()
        if relative == base_mapping_relative:
            continue
        supplemental_mapping_documents.append((relative, load_yaml(root, relative, checks)))
    checks.require(
        not supplemental_feature_ids or bool(supplemental_mapping_documents),
        "missing_registry",
        "supplemental executable mapping discovery",
        ">=1 mapping for discovered supplemental features",
        [],
    )
    supplemental_mapping_rows: list[tuple[str, dict[str, Any]]] = []
    for relative, document in supplemental_mapping_documents:
        scenarios = document.get("scenarios", [])
        ids = row_ids(scenarios, "scenario_id", f"{relative} scenarios", checks)
        checks.count(document.get("scenario_count"), ids, f"{relative} scenario count")
        if isinstance(scenarios, list):
            supplemental_mapping_rows.extend(
                (relative, row) for row in scenarios if isinstance(row, dict)
            )
    supplemental_tests = checks.unique(
        [
            row["scenario_id"]
            for _, row in supplemental_mapping_rows
            if isinstance(row.get("scenario_id"), str)
        ],
        "supplemental executable scenarios",
    )
    checks.equal(supplemental_feature_ids, supplemental_tests, "supplemental feature mapping", "features", "mapping")
    checks.require(not (base_tests & supplemental_tests), "scenario_collision", "effective scenarios", [], sorted(base_tests & supplemental_tests))

    source_scenarios = {
        row["scenario_id"]: row for row in supplemental_feature_rows
    }
    mapping_ids_by_feature: dict[str, list[str]] = {}
    for relative, row in supplemental_mapping_rows:
        scenario_id = row.get("scenario_id")
        source = f"{relative}#{scenario_id}"
        feature_file = row.get("feature_file")
        checks.require(
            isinstance(feature_file, str) and _safe_relative(feature_file),
            "supplemental_feature_reference",
            source,
            "safe feature_file",
            feature_file,
        )
        if isinstance(feature_file, str):
            mapping_ids_by_feature.setdefault(feature_file, []).append(str(scenario_id))
        expected_source = source_scenarios.get(scenario_id) if isinstance(scenario_id, str) else None
        checks.require(
            expected_source is not None,
            "supplemental_scenario_source",
            source,
            "discovered scenario",
            scenario_id,
        )
        if expected_source is not None:
            checks.require(
                row.get("feature_file") == expected_source["feature_file"]
                and row.get("scenario_title") == expected_source["scenario_title"],
                "supplemental_scenario_identity",
                source,
                {
                    "feature_file": expected_source["feature_file"],
                    "scenario_title": expected_source["scenario_title"],
                },
                {
                    "feature_file": row.get("feature_file"),
                    "scenario_title": row.get("scenario_title"),
                },
            )
        checks.require(
            row.get("runner_kind") == "RUST_NEXTEST"
            and row.get("implementation_test_id")
            == str(scenario_id).lower().replace("-", "_")
            and row.get("test_target")
            == Path(str(row.get("implementation_test_path"))).stem
            and isinstance(row.get("runtime_profile_id"), str)
            and isinstance(row.get("scenario_contract_sha256"), str),
            "supplemental_execution_contract",
            source,
            "stable Rust exact selector identity, runtime profile and scenario digest",
            row,
        )
    checks.equal(
        set(supplemental_feature_paths),
        set(mapping_ids_by_feature),
        "supplemental feature-file mapping",
        "features",
        "mapping",
    )
    for feature_file, ids in mapping_ids_by_feature.items():
        mapped = checks.unique(ids, f"{feature_file} mapped scenarios")
        checks.equal(
            supplemental_feature_ids_by_path.get(feature_file, set()),
            mapped,
            f"{feature_file} mapping",
            "feature",
            "mapping",
        )
    for relative, document in supplemental_mapping_documents:
        feature_rows = document.get("features", [])
        feature_paths = row_ids(feature_rows, "path", f"{relative} feature inventory", checks)
        checks.count(document.get("feature_count"), feature_paths, f"{relative} feature count")
        if len(supplemental_mapping_documents) == 1:
            checks.equal(
                set(supplemental_feature_paths),
                feature_paths,
                f"{relative} feature inventory",
                "discovered",
                "mapping",
            )
        for row in feature_rows if isinstance(feature_rows, list) else []:
            if isinstance(row, dict) and isinstance(row.get("path"), str):
                checks.count(
                    row.get("scenario_count"),
                    supplemental_feature_ids_by_path.get(row["path"], set()),
                    f"{relative}#{row['path']}",
                )

    effective_execution_registry: dict[str, Any] = {}
    effective_registry_path = root / EFFECTIVE_EXECUTION_REGISTRY
    try:
        expected_effective_registry = render_effective_execution_registry(root)
        checks.require(
            effective_registry_path.is_file()
            and not effective_registry_path.is_symlink()
            and effective_registry_path.read_bytes() == expected_effective_registry,
            "effective_execution_registry",
            EFFECTIVE_EXECUTION_REGISTRY,
            hashlib.sha256(expected_effective_registry).hexdigest(),
            _sha256_file(effective_registry_path)
            if effective_registry_path.is_file()
            else "missing",
        )
        loaded_registry = load_yaml(root, EFFECTIVE_EXECUTION_REGISTRY, checks)
        if isinstance(loaded_registry, dict):
            effective_execution_registry = loaded_registry
    except (OSError, UnicodeError, ValueError) as error:
        checks.require(
            False,
            "effective_execution_registry",
            EFFECTIVE_EXECUTION_REGISTRY,
            "deterministic static registry",
            str(error),
        )
    effective_execution_rows = row_ids(
        effective_execution_registry.get("scenarios", []),
        "scenario_id",
        "effective execution registry scenarios",
        checks,
    )
    checks.equal(
        base_tests | supplemental_tests,
        effective_execution_rows,
        "effective execution registry scenario set",
        "feature mappings",
        "effective registry",
    )

    overlay_ids = row_ids(overlay_doc.get("overlays"), "scenario_id", "acceptance overlays", checks)
    checks.subset(overlay_ids, base_tests, "acceptance overlay targets")
    effective_tests = base_tests | supplemental_tests
    all_mapping_documents = [("base", base_mapping_doc)] + supplemental_mapping_documents
    for source, document in all_mapping_documents:
        for index, row in enumerate(document.get("scenarios", [])):
            if not isinstance(row, dict):
                continue
            checks.require(row.get("skip_policy") == "FORBIDDEN", "skip_policy", f"{source}[{index}]", "FORBIDDEN", row.get("skip_policy"))
            checks.require(isinstance(row.get("implementation_test_path"), str) and bool(row.get("implementation_test_path", "").strip()), "missing_test_path", f"{source}[{index}]", "nonempty", row.get("implementation_test_path"))
            if source == "base":
                checks.require(isinstance(row.get("command"), str) and bool(row.get("command", "").strip()), "missing_test_command", f"{source}[{index}]", "nonempty", row.get("command"))
            else:
                checks.require(
                    row.get("runner_kind") == "RUST_NEXTEST"
                    and isinstance(row.get("test_target"), str)
                    and isinstance(row.get("runtime_profile_id"), str),
                    "missing_test_selector",
                    f"{source}[{index}]",
                    "static runner target/profile",
                    row,
                )

    ai_semantic_receipt = validate_ai_semantic_contracts(root, checks)
    generator_parity_receipts = validate_generator_parity(root, checks)

    registry = {
        "schema_version": 1,
        "source_derived": True,
        "inventories": {
            "operations": {
                "base_external": _source_rows(base_ops),
                "additive_external": _source_rows(owner_additive),
                "private_identity": _source_rows(identity_operations),
                "private_communication": _source_rows(callback_ops),
                "private_control": _source_rows(owner_private_control),
                "private_application_commands": _source_rows(
                    owner_private_application
                ),
                "effective_http": _source_rows(
                    base_ops
                    | owner_additive
                    | identity_operations
                    | callback_ops
                    | owner_private_control
                ),
            },
            "commands": {
                "base_external": _source_rows(base_commands),
                "additive_external": _source_rows(additive_commands),
                "private_identity": _source_rows(identity_operations),
                "private_callbacks": _source_rows(callback_commands),
                "private_control": _source_rows(private_control_commands),
                "private_application": _source_rows(owner_private_application),
                "effective_http": _source_rows(
                    base_commands
                    | additive_commands
                    | identity_operations
                    | callback_commands
                    | private_control_commands
                ),
                "effective": _source_rows(
                    base_commands
                    | additive_commands
                    | identity_operations
                    | callback_commands
                    | private_control_commands
                    | owner_private_application
                ),
            },
            "events": {"base": _source_rows(base_events), "additive": _source_rows(additive_events), "effective": _source_rows(effective_events)},
            "tables": {"base": _source_rows(base_tables), "additive": _source_rows(physical_tables), "effective": _source_rows(effective_tables)},
            "migrations": {"base_spec": _source_rows(base_migrations), "additive_plan": _source_rows(planned_migrations), "effective_plan": _source_rows(base_migrations | planned_migrations), "runtime": _source_rows(runtime_migrations)},
            "sessions": {"base": _source_rows(base_sessions), "additive": _source_rows(derived_sessions), "effective": _source_rows(base_sessions | derived_sessions)},
            "states": {
                "machines": _source_rows(machines),
                "machine_states": _source_rows(machine_states),
                "machine_edges": sorted(machine_edges),
                "profile_occurrences": _source_rows(occurrence_profiles),
                "special_occurrences": _source_rows(occurrence_special),
                "screen_occurrences": _source_rows(
                    occurrence_profiles | occurrence_special
                ),
            },
            "screen_actions": {"base": _source_rows(base_actions), "additive_command_placements": _source_rows(placement_actions), "effective": _source_rows(base_actions | placement_actions)},
            "trace": {
                "screens": _source_rows(screens),
                "base_operations": _source_rows(trace_operations),
                "additive_operations": _source_rows(additive_screen_trace),
                "private_identity_operations": _source_rows(identity_operations),
                "private_callback_operations": _source_rows(callback_ops),
                "private_control_operations": _source_rows(owner_private_control),
                "effective_operations": _source_rows(
                    trace_operations
                    | additive_screen_trace
                    | identity_operations
                    | callback_ops
                    | owner_private_control
                ),
            },
            "tests": {
                "base": _source_rows(base_tests),
                "supplemental": _source_rows(supplemental_tests),
                "effective": _source_rows(effective_tests),
                "supplemental_features": supplemental_feature_paths,
                "supplemental_mappings": [
                    relative for relative, _ in supplemental_mapping_documents
                ],
                "effective_execution_registry": [EFFECTIVE_EXECUTION_REGISTRY],
            },
        },
        "validation_receipts": {
            "ai_semantic_schema": ai_semantic_receipt,
            "generator_parity": generator_parity_receipts,
            "supplemental_acceptance_discovery": {
                "feature_paths": supplemental_feature_paths,
                "mapping_paths": [
                    relative for relative, _ in supplemental_mapping_documents
                ],
                "scenario_count": len(supplemental_feature_ids),
                "ordered_identity_sha256": _ordered_scenario_identity_sha256(
                    supplemental_feature_rows
                ),
                "scenario_set_sha256": _string_set_sha256(
                    supplemental_feature_ids
                ),
            },
        },
    }
    registry["counts"] = {
        name: {part: len(values) for part, values in inventory.items() if isinstance(values, list)}
        for name, inventory in registry["inventories"].items()
    }
    registry["structure_result"] = "PASS" if not checks.problems else "FAIL"
    registry["problem_count"] = len(checks.problems)
    return registry, checks.problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--max-problems", type=int, default=100)
    args = parser.parse_args()
    registry, problems = build_registry(args.root)
    payload = {**registry, "problems": [problem_payload(problem) for problem in problems]}
    rendered = json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    if args.json_output is not None:
        args.json_output.write_text(rendered, encoding="utf-8")
    display = dict(payload)
    display["problems"] = display["problems"][: max(0, args.max_problems)]
    print(json.dumps(display, ensure_ascii=False, sort_keys=True, indent=2))
    if len(problems) > args.max_problems:
        print(f"... {len(problems) - args.max_problems} additional problems omitted")
    print(f"STRUCTURE_LINT: {registry['structure_result']}")
    return 0 if not problems else 1


if __name__ == "__main__":
    raise SystemExit(main())
