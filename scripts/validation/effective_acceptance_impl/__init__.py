"""Fail-closed validation for the effective acceptance contract and receipts."""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tomllib
from typing import Any, Iterable

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

# This validator is invoked as a file by the pinned authority image.  In that
# mode Python exposes scripts/validation, not scripts/, on sys.path; make the
# generator imports deterministic without relying on an operator PYTHONPATH.
SCRIPTS_ROOT = Path(__file__).resolve().parents[2]
if str(SCRIPTS_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_ROOT))

from design_bundle_digest import build_manifest as build_design_manifest
from create_source_archive import excluded as source_archive_excluded
from generate_acceptance_design_registry import (
    OUTPUT as ACCEPTANCE_DESIGN_REGISTRY,
    render_registry as render_design_registry,
)
from generate_effective_execution_registry import (
    BASE_MAPPING,
    OBSERVATION_LAYER_DOMAIN,
    ORACLE_LAYER_DOMAIN,
    OUTPUT as EFFECTIVE_REGISTRY,
    RUNTIME_LAYERS,
    SUPPLEMENTAL_MAPPING,
    canonical_sha256,
    render_registry,
)
from git_authority import AUTHORITY_ZIP_SHA256
from generate_supplemental_execution_mapping import render_mapping
from source_provenance import source_tree_digest, worktree_inventory
from validation.supplemental_acceptance_registry import _test_declarations
from validation.acceptance_machine import (
    MachineReportError,
    parse_nextest_discovery,
    parse_nextest_junit,
    parse_playwright_report,
)
from validation.supplemental_acceptance_source import (
    executable_source,
    rust_function_end,
    rust_observation_bindings,
)


EXECUTION_SCHEMA = "specs/acceptance/execution-receipt-v3.schema.json"
LAYER_SCHEMA = "specs/acceptance/runtime-layer-receipt-v1.schema.json"
RUN_INDEX_SCHEMA = "specs/acceptance/run-index-v1.schema.json"
EXTRACTION_SCHEMA = "specs/acceptance/extraction-receipt-v1.schema.json"
RUN_AGGREGATE_DOMAIN = b"GURINNAE-ACCEPTANCE-RUN-INDEX-V1\0"
SEAL_DOMAIN = b"GURINNAE-ACCEPTANCE-SEAL-MEMBERS-V1\0"
ARGV_DOMAIN = b"GURINNAE-ACCEPTANCE-ARGV-V1\0"
PROBE_ARGV_DOMAIN = b"GURINNAE-ACCEPTANCE-PROBE-ARGV-V1\0"
PROBE_FACTS_DOMAIN = b"GURINNAE-ACCEPTANCE-PROBE-FACTS-V1\0"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SKIP_SOURCE_RE = re.compile(
    r"(?im)(?:"
    r"\b(?:test|it|describe)\.(?:skip|fixme|todo|only)\s*\("
    r"|#\s*\[ignore(?:\([^]]*\))?\]"
    r"|pytest\.mark\.(?:skip|skipif)\b"
    r"|@(?:Ignore|Disabled|focus|focused)\b"
    r")"
)
SHOULD_PANIC_RE = re.compile(r"(?m)#\s*\[\s*should_panic(?:\([^]]*\))?\s*\]")
PLACEHOLDER_SOURCE_RE = re.compile(
    r"(?i)(?:\bTODO\b|\bTBD\b|\bFIXME\b|\bunimplemented!\s*\(|"
    r"\btodo!\s*\(|\b501\b|placeholder)"
)
def _mask_typescript_comments(text: str) -> str:
    output = list(text)
    index = 0
    quote: str | None = None
    while index < len(text):
        character = text[index]
        if quote is not None:
            if character == "\\":
                index += 2
                continue
            if character == quote:
                quote = None
            index += 1
            continue
        if character in {"'", '"', "`"}:
            quote = character
            index += 1
            continue
        if text.startswith("//", index):
            end = text.find("\n", index + 2)
            end = len(text) if end < 0 else end
            for position in range(index, end):
                output[position] = " "
            index = end
            continue
        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = len(text) if end < 0 else end + 2
            for position in range(index, end):
                if output[position] not in {"\n", "\r"}:
                    output[position] = " "
            index = end
            continue
        index += 1
    return "".join(output)


def _typescript_test_titles(text: str) -> tuple[list[str], int]:
    code = _mask_typescript_comments(text)
    titles: list[str] = []
    calls = 0
    index = 0
    while index < len(code):
        character = code[index]
        if character in {"'", '"', "`"}:
            quote = character
            index += 1
            while index < len(code):
                if code[index] == "\\":
                    index += 2
                    continue
                if code[index] == quote:
                    index += 1
                    break
                index += 1
            continue
        if character.isalpha() or character in {"_", "$"}:
            start = index
            index += 1
            while index < len(code) and (code[index].isalnum() or code[index] in {"_", "$"}):
                index += 1
            identifier = code[start:index]
            previous = code[start - 1] if start else ""
            if identifier not in {"test", "it"} or previous in {".", "$"} or previous.isalnum() or previous == "_":
                continue
            cursor = index
            while cursor < len(code) and code[cursor].isspace():
                cursor += 1
            if cursor >= len(code) or code[cursor] != "(":
                continue
            calls += 1
            cursor += 1
            while cursor < len(code) and code[cursor].isspace():
                cursor += 1
            if cursor >= len(code) or code[cursor] not in {"'", '"'}:
                continue
            quote = code[cursor]
            cursor += 1
            value: list[str] = []
            valid = False
            while cursor < len(code):
                if code[cursor] == "\\" and cursor + 1 < len(code):
                    escaped = code[cursor + 1]
                    value.append({"n": "\n", "r": "\r", "t": "\t"}.get(escaped, escaped))
                    cursor += 2
                    continue
                if code[cursor] == quote:
                    cursor += 1
                    valid = True
                    break
                value.append(code[cursor])
                cursor += 1
            while cursor < len(code) and code[cursor].isspace():
                cursor += 1
            if valid and cursor < len(code) and code[cursor] == ",":
                titles.append("".join(value))
            continue
        index += 1
    return titles, calls


@dataclass(frozen=True)
class Problem:
    phase: str
    code: str
    source: str
    expected: object
    actual: object


class Checks:
    def __init__(self, phase: str) -> None:
        self.phase = phase
        self.problems: list[Problem] = []

    def need(
        self,
        condition: bool,
        code: str,
        source: str,
        expected: object,
        actual: object,
    ) -> None:
        if not condition:
            self.problems.append(
                Problem(self.phase, code, source, expected, actual)
            )

    def same(
        self,
        expected: set[str],
        actual: set[str],
        code: str,
        source: str,
    ) -> None:
        self.need(
            expected == actual,
            code,
            source,
            sorted(expected),
            sorted(actual),
        )


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _sha256_fd(descriptor: int) -> str:
    digest = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    return digest.hexdigest()


def _safe_relative(value: object) -> bool:
    if not isinstance(value, str) or not value or "\\" in value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and ".." not in path.parts and path.as_posix() == value


def _load_json(path: Path) -> object:
    def reject_duplicate(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    return json.loads(
        path.read_text(encoding="utf-8"),
        object_pairs_hook=reject_duplicate,
    )


def _mapping_rows(value: object, source: str, checks: Checks) -> dict[str, dict[str, Any]]:
    rows = value.get("scenarios") if isinstance(value, dict) else None
    if not isinstance(rows, list):
        checks.need(False, "registry_schema", source, "scenarios list", type(rows).__name__)
        return {}
    mapped: dict[str, dict[str, Any]] = {}
    for index, row in enumerate(rows):
        scenario_id = row.get("scenario_id") if isinstance(row, dict) else None
        if not isinstance(row, dict) or not isinstance(scenario_id, str):
            checks.need(False, "registry_row", f"{source}[{index}]", "scenario mapping", row)
            continue
        if scenario_id in mapped:
            checks.need(False, "duplicate_scenario", source, "unique", scenario_id)
        mapped[scenario_id] = row
    return mapped


def _walk_keys(value: object) -> Iterable[str]:
    if isinstance(value, dict):
        for key, child in value.items():
            yield str(key)
            yield from _walk_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_keys(child)


def _make_targets(text: str) -> dict[str, tuple[list[str], list[str]]]:
    targets: dict[str, tuple[list[str], list[str]]] = {}
    current: str | None = None
    for line_number, line in enumerate(text.splitlines(), start=1):
        if line.startswith("\t"):
            if current is not None:
                targets[current][1].append(line[1:])
            continue
        current = None
        if not line or line.startswith(("#", ".")) or ":=" in line or "?=" in line or "=" in line.split(":", 1)[0]:
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+):(?:\s*(.*))?", line)
        if match is None:
            continue
        name = match.group(1)
        if name in targets:
            raise ValueError(f"duplicate Make target at line {line_number}: {name}")
        dependencies = match.group(2).split() if match.group(2) else []
        targets[name] = (dependencies, [])
        current = name
    return targets


def _make_recipe_commands(recipes: Iterable[str]) -> tuple[str, ...]:
    commands: list[str] = []
    continued: list[str] = []
    for recipe in recipes:
        stripped = recipe.strip()
        if not stripped or stripped.startswith("#"):
            continue
        has_continuation = stripped.endswith("\\")
        continued.append(stripped[:-1].rstrip() if has_continuation else stripped)
        if not has_continuation:
            commands.append(" ".join(continued))
            continued = []
    if continued:
        commands.append(" ".join(continued))
    return tuple(commands)


def _validate_make_graph(root: Path, checks: Checks) -> None:
    path = root / "Makefile"
    try:
        targets = _make_targets(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        checks.need(False, "acceptance_make_graph", "Makefile", "parseable", str(error))
        return
    required_edges = {
        "run-acceptance-439": {"verify-specs"},
        "verify-execution-evidence": {"run-acceptance-439"},
        "verify-acceptance": {"verify-execution-evidence"},
        "verify-prearchive": {
            "verify-specs",
            "verify-codegen",
            "test-rust-workspace",
            "test-sqlx-prepare",
            "verify-bun",
            "verify-runtime",
            "verify-containers",
            "test-ui-e2e",
            "test-ui-visual",
        },
        "verify-final": {"verify-acceptance", "verify-prearchive"},
    }
    for target, required in required_edges.items():
        dependencies, recipes = targets.get(target, ([], []))
        checks.need(
            required <= set(dependencies),
            "acceptance_make_dependency",
            f"Makefile#{target}",
            sorted(required),
            dependencies,
        )
        forbidden = [
            recipe
            for recipe in recipes
            if re.match(r"^[ @+]*-", recipe)
            or "|| true" in recipe
            or "; true" in recipe
            or "--no-tests=pass" in recipe
            or re.search(r"(?i)(?:^|\s)(?:skip|xfailed)(?:\s|$)", recipe)
        ]
        checks.need(
            not forbidden,
            "acceptance_make_recipe_bypass",
            f"Makefile#{target}",
            [],
            forbidden,
        )
    run_recipes = targets.get("run-acceptance-439", ([], []))[1]
    evidence_recipes = targets.get("verify-execution-evidence", ([], []))[1]
    required_acceptance_arguments = (
        ("ACCEPTANCE_EVIDENCE_ROOT", "--evidence-root"),
        ("ACCEPTANCE_RUN_ID", "--run-id"),
        ("ACCEPTANCE_SOURCE_COMMIT", "--source-commit"),
        ("ACCEPTANCE_SOURCE_TREE_SHA256", "--source-tree-sha256"),
        ("ACCEPTANCE_ARCHIVE", "--archive"),
        ("ACCEPTANCE_EXTRACTION_RECEIPT", "--extraction-receipt"),
        ("ACCEPTANCE_EXTRACTION_RECEIPT_SHA256", "--extraction-receipt-sha256"),
    )
    run_commands = _make_recipe_commands(run_recipes)
    runner_commands = tuple(
        command for command in run_commands if "scripts/run_acceptance.py" in command
    )
    checks.need(
        bool(runner_commands),
        "acceptance_make_runner",
        "Makefile#run-acceptance-439",
        "scripts/run_acceptance.py",
        run_recipes,
    )
    for variable, argument in required_acceptance_arguments:
        guard = (
            f'@test -n "$({variable})" || {{ printf \'%s\\n\' '
            f"'{variable} is required'; exit 2; }}"
        )
        checks.need(
            guard in run_recipes,
            "acceptance_make_required_guard",
            "Makefile#run-acceptance-439",
            guard,
            run_recipes,
        )
        checks.need(
            any(
                f'{argument} "$({variable})"' in command
                for command in runner_commands
            ),
            "acceptance_make_explicit_argument",
            "Makefile#run-acceptance-439",
            f'{argument} "$({variable})"',
            run_recipes,
        )
    evidence_commands = _make_recipe_commands(evidence_recipes)
    validator_commands = tuple(
        command
        for command in evidence_commands
        if "effective_acceptance.py --mode evidence" in command
    )
    validator_image = "gurine-authority-validator:13.0.0"
    docker_validator_commands = tuple(
        command
        for command in validator_commands
        if command.lstrip("@+").startswith("docker run ")
        and validator_image in command
        and command.partition(validator_image)[2]
        .lstrip()
        .startswith("python -B scripts/validation/effective_acceptance.py --mode evidence")
    )
    checks.need(
        bool(docker_validator_commands),
        "acceptance_make_out_of_process_evidence_validator",
        "Makefile#verify-execution-evidence",
        "authority-validator docker run owns evidence verdict",
        evidence_recipes,
    )
    checks.need(
        bool(validator_commands),
        "acceptance_make_evidence_validator",
        "Makefile#verify-execution-evidence",
        "effective_acceptance.py --mode evidence",
        evidence_recipes,
    )
    checks.need(
        any(
            '--volume "$(CURDIR):/workspace:ro"' in command
            for command in docker_validator_commands
        ),
        "acceptance_make_workspace_read_only",
        "Makefile#verify-execution-evidence",
        '--volume "$(CURDIR):/workspace:ro"',
        evidence_recipes,
    )
    checks.need(
        any(
            '--volume "$(ACCEPTANCE_EVIDENCE_ROOT):/acceptance-evidence:ro"'
            in command
            for command in docker_validator_commands
        ),
        "acceptance_make_evidence_read_only",
        "Makefile#verify-execution-evidence",
        '--volume "$(ACCEPTANCE_EVIDENCE_ROOT):/acceptance-evidence:ro"',
        evidence_recipes,
    )


def validate_static(root: Path) -> tuple[Checks, dict[str, Any]]:
    checks = Checks("structure")
    root = root.resolve()
    _validate_make_graph(root, checks)
    try:
        expected_mapping = render_mapping(root)
        mapping_path = root / SUPPLEMENTAL_MAPPING
        checks.need(
            mapping_path.is_file()
            and not mapping_path.is_symlink()
            and mapping_path.read_bytes() == expected_mapping,
            "generated_supplemental_mapping",
            SUPPLEMENTAL_MAPPING,
            hashlib.sha256(expected_mapping).hexdigest(),
            _sha256(mapping_path) if mapping_path.is_file() else "missing",
        )
    except (OSError, UnicodeError, ValueError) as error:
        checks.need(False, "mapping_generation", SUPPLEMENTAL_MAPPING, "deterministic", str(error))

    registry: dict[str, Any] = {}
    try:
        expected_registry = render_registry(root)
        registry_path = root / EFFECTIVE_REGISTRY
        current = registry_path.read_bytes() if registry_path.is_file() else b""
        checks.need(
            registry_path.is_file()
            and not registry_path.is_symlink()
            and current == expected_registry,
            "generated_effective_registry",
            EFFECTIVE_REGISTRY,
            hashlib.sha256(expected_registry).hexdigest(),
            hashlib.sha256(current).hexdigest() if current else "missing",
        )
        loaded = _load_json(registry_path) if current else {}
        if isinstance(loaded, dict):
            registry = loaded
        else:
            checks.need(False, "registry_schema", EFFECTIVE_REGISTRY, "mapping", type(loaded).__name__)
    except (OSError, UnicodeError, ValueError) as error:
        checks.need(False, "registry_generation", EFFECTIVE_REGISTRY, "deterministic", str(error))

    try:
        expected_design_registry = render_design_registry(root)
        design_registry_path = root / ACCEPTANCE_DESIGN_REGISTRY
        current_design_registry = (
            design_registry_path.read_bytes() if design_registry_path.is_file() else b""
        )
        checks.need(
            design_registry_path.is_file()
            and not design_registry_path.is_symlink()
            and current_design_registry == expected_design_registry,
            "generated_acceptance_design_registry",
            ACCEPTANCE_DESIGN_REGISTRY,
            hashlib.sha256(expected_design_registry).hexdigest(),
            hashlib.sha256(current_design_registry).hexdigest()
            if current_design_registry
            else "missing",
        )
        loaded_design_registry = (
            _load_json(design_registry_path) if current_design_registry else {}
        )
        embedded_design = sorted(
            set(loaded_design_registry.get("forbidden_runtime_keys", []))
            & set(_walk_keys(loaded_design_registry))
        ) if isinstance(loaded_design_registry, dict) else ["invalid registry"]
        checks.need(
            not embedded_design,
            "runtime_state_in_design_registry",
            ACCEPTANCE_DESIGN_REGISTRY,
            [],
            embedded_design,
        )
        if isinstance(loaded_design_registry, dict):
            design_manifest = build_design_manifest(root)
            design_member_paths = {
                str(row.get("path"))
                for row in design_manifest.get("members", [])
                if isinstance(row, dict)
            }
            proof_paths = {
                str(row.get("path"))
                for row in loaded_design_registry.get("proof_semantics_members", [])
                if isinstance(row, dict)
            }
            checks.need(
                proof_paths <= design_member_paths
                and ACCEPTANCE_DESIGN_REGISTRY in design_member_paths,
                "proof_semantics_digest_membership",
                ACCEPTANCE_DESIGN_REGISTRY,
                sorted(proof_paths | {ACCEPTANCE_DESIGN_REGISTRY}),
                sorted((proof_paths | {ACCEPTANCE_DESIGN_REGISTRY}) - design_member_paths),
            )
    except (OSError, UnicodeError, ValueError) as error:
        checks.need(
            False,
            "acceptance_design_registry_generation",
            ACCEPTANCE_DESIGN_REGISTRY,
            "deterministic",
            str(error),
        )
    forbidden = set(registry.get("forbidden_runtime_keys", [])) if registry else set()
    embedded = sorted(forbidden & set(_walk_keys(registry)))
    # The top-level list names the forbidden fields as values, not mapping keys.
    embedded = [key for key in embedded if key != "forbidden_runtime_keys"]
    checks.need(
        not embedded,
        "runtime_state_in_static_registry",
        EFFECTIVE_REGISTRY,
        [],
        embedded,
    )
    counts = registry.get("counts", {}) if registry else {}
    checks.need(
        counts.get("base_features") == 35
        and counts.get("base_scenarios") == 271
        and counts.get("supplemental_features") == 5
        and counts.get("supplemental_scenarios") == 168
        and counts.get("effective_features") == 40
        and counts.get("effective_scenarios") == 439
        and counts.get("gherkin_source_steps") == 1646
        and counts.get("gherkin_outlines") == 11
        and counts.get("gherkin_examples") == 80
        and counts.get("gherkin_clause_instances") == 2466,
        "effective_acceptance_counts",
        EFFECTIVE_REGISTRY,
        {
            "base_features": 35,
            "base_scenarios": 271,
            "supplemental_features": 5,
            "supplemental_scenarios": 168,
            "effective_features": 40,
            "effective_scenarios": 439,
            "gherkin_source_steps": 1646,
            "gherkin_outlines": 11,
            "gherkin_examples": 80,
            "gherkin_clause_instances": 2466,
        },
        counts,
    )
    rows = _mapping_rows(registry, EFFECTIVE_REGISTRY, checks)
    expected_oracle_count = sum(
        len(row.get("oracle_contracts", [])) for row in rows.values()
    )
    checks.need(
        counts.get("gherkin_oracles") == expected_oracle_count,
        "effective_acceptance_oracle_count",
        EFFECTIVE_REGISTRY,
        expected_oracle_count,
        counts.get("gherkin_oracles"),
    )
    runtime = registry.get("runtime_contracts", {})
    profiles = runtime.get("profiles", {}) if isinstance(runtime, dict) else {}
    layers = runtime.get("layers", {}) if isinstance(runtime, dict) else {}
    expected_layer_ids = set(RUNTIME_LAYERS)
    checks.need(
        isinstance(layers, dict) and set(layers) == expected_layer_ids,
        "runtime_probe_layer_set",
        EFFECTIVE_REGISTRY,
        sorted(expected_layer_ids),
        sorted(layers) if isinstance(layers, dict) else layers,
    )
    for layer_id, contract in (layers.items() if isinstance(layers, dict) else []):
        template = contract.get("probe_argv_template") if isinstance(contract, dict) else None
        checks.need(
            isinstance(template, list)
            and bool(template)
            and all(isinstance(value, str) and value for value in template)
            and any("scripts/acceptance_layer_probe.py" in value for value in template),
            "runtime_probe_command",
            f"{EFFECTIVE_REGISTRY}#runtime_contracts/layers/{layer_id}",
            "non-empty fixed argv template invoking acceptance_layer_probe.py",
            template,
        )
    probe_script = SCRIPTS_ROOT / "acceptance_layer_probe.py"
    checks.need(
        probe_script.is_file() and not probe_script.is_symlink(),
        "runtime_probe_script",
        "scripts/acceptance_layer_probe.py",
        "plain probe script",
        str(probe_script),
    )
    observation_edge_count = 0
    oracle_edge_count = 0
    for scenario_id, row in rows.items():
        execution = row.get("execution", {})
        profile_id = execution.get("runtime_profile_id") if isinstance(execution, dict) else None
        profile = profiles.get(profile_id, {}) if isinstance(profiles, dict) else {}
        layer_ids = profile.get("layer_ids", []) if isinstance(profile, dict) else []
        expected_observation_edges: list[dict[str, object]] = []
        expected_oracle_edges: list[dict[str, object]] = []
        for layer_ordinal, layer_id in enumerate(layer_ids, start=1):
            layer = layers.get(layer_id, {}) if isinstance(layers, dict) else {}
            layer_sha256 = layer.get("layer_contract_sha256") if isinstance(layer, dict) else None
            for observation in row.get("observation_contracts", []):
                if not isinstance(observation, dict):
                    continue
                edge_id = f"OLE-{observation.get('instance_id')}-L{layer_ordinal:02d}"
                body = {
                    "edge_id": edge_id,
                    "scenario_id": scenario_id,
                    "instance_id": observation.get("instance_id"),
                    "instance_sha256": observation.get("instance_sha256"),
                    "layer_id": layer_id,
                    "layer_contract_sha256": layer_sha256,
                }
                expected_observation_edges.append(
                    {
                        **body,
                        "edge_sha256": canonical_sha256(
                            OBSERVATION_LAYER_DOMAIN, body
                        ),
                    }
                )
            for oracle in row.get("oracle_contracts", []):
                if not isinstance(oracle, list) or len(oracle) != 2:
                    continue
                edge_id = f"RLE-{oracle[0]}-L{layer_ordinal:02d}"
                body = {
                    "edge_id": edge_id,
                    "scenario_id": scenario_id,
                    "oracle_id": oracle[0],
                    "oracle_sha256": oracle[1],
                    "layer_id": layer_id,
                    "layer_contract_sha256": layer_sha256,
                }
                expected_oracle_edges.append(
                    {
                        **body,
                        "edge_sha256": canonical_sha256(
                            ORACLE_LAYER_DOMAIN, body
                        ),
                    }
                )
        checks.need(
            row.get("observation_layer_contracts") == expected_observation_edges,
            "observation_layer_contracts",
            scenario_id,
            expected_observation_edges,
            row.get("observation_layer_contracts"),
        )
        checks.need(
            row.get("oracle_layer_contracts") == expected_oracle_edges,
            "oracle_layer_contracts",
            scenario_id,
            expected_oracle_edges,
            row.get("oracle_layer_contracts"),
        )
        observation_edge_count += len(expected_observation_edges)
        oracle_edge_count += len(expected_oracle_edges)
    checks.need(
        counts.get("observation_layer_edges") == observation_edge_count
        and counts.get("oracle_layer_edges") == oracle_edge_count,
        "runtime_edge_counts",
        EFFECTIVE_REGISTRY,
        {
            "observation_layer_edges": observation_edge_count,
            "oracle_layer_edges": oracle_edge_count,
        },
        {
            "observation_layer_edges": counts.get("observation_layer_edges"),
            "oracle_layer_edges": counts.get("oracle_layer_edges"),
        },
    )
    checks.need(
        len(rows) == 439,
        "effective_registry_identity",
        EFFECTIVE_REGISTRY,
        439,
        len(rows),
    )
    return checks, registry


def _cargo_test_targets(root: Path, checks: Checks) -> dict[str, str]:
    path = root / "crates/test-support/Cargo.toml"
    try:
        value = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, tomllib.TOMLDecodeError) as error:
        checks.need(False, "cargo_test_targets", str(path.relative_to(root)), "valid TOML", str(error))
        return {}
    rows = value.get("test", [])
    if not isinstance(rows, list):
        checks.need(False, "cargo_test_targets", str(path.relative_to(root)), "[[test]] list", rows)
        return {}
    result: dict[str, str] = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("name"), str) or not isinstance(row.get("path"), str):
            checks.need(False, "cargo_test_target", str(path.relative_to(root)), "name/path", row)
            continue
        if row["name"] in result:
            checks.need(False, "cargo_test_target_duplicate", str(path.relative_to(root)), "unique", row["name"])
        result[row["name"]] = row["path"]
    return result


def validate_sources(root: Path, registry: dict[str, Any]) -> Checks:
    checks = Checks("source")
    rows = _mapping_rows(registry, EFFECTIVE_REGISTRY, checks)
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in rows.values():
        execution = row.get("execution")
        path = execution.get("implementation_test_path") if isinstance(execution, dict) else None
        if isinstance(path, str):
            grouped.setdefault(path, []).append(row)
        else:
            checks.need(False, "implementation_test_path", str(row.get("scenario_id")), "path", path)

    cargo_targets = _cargo_test_targets(root, checks)
    expected_rust_targets: dict[str, str] = {}
    for relative, source_rows in sorted(grouped.items()):
        path = root / relative
        if path.is_symlink() or not path.is_file():
            checks.need(False, "missing_test_source", relative, "regular file", "missing")
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            checks.need(False, "test_source_unreadable", relative, "UTF-8", str(error))
            continue
        checks.need(SKIP_SOURCE_RE.search(text) is None, "skipped_or_focused_test", relative, "absent", "present")
        checks.need(SHOULD_PANIC_RE.search(text) is None, "should_panic_test", relative, "absent", "present")
        checks.need(PLACEHOLDER_SOURCE_RE.search(text) is None, "placeholder_test_source", relative, "absent", "present")
        selectors = [
            row.get("execution", {}).get("selector", {})
            for row in source_rows
            if isinstance(row.get("execution"), dict)
        ]
        runner_kinds = {selector.get("runner_kind") for selector in selectors if isinstance(selector, dict)}
        checks.need(len(runner_kinds) == 1, "mixed_test_runner", relative, "one runner", sorted(str(value) for value in runner_kinds))
        if runner_kinds == {"RUST_NEXTEST"}:
            expected_by_id = {
                str(selector.get("implementation_test_id")): row
                for selector, row in zip(selectors, source_rows, strict=True)
            }
            code = executable_source(path, text)
            candidate_ids = re.findall(
                r"(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+"
                r"(ac_[a-z0-9_]+)\s*\(",
                code,
            )
            declaration_positions: dict[str, int] = {}
            for test_id, scenario in expected_by_id.items():
                positions = _test_declarations(path, text, test_id)
                checks.need(
                    len(positions) == 1,
                    "rust_test_declaration",
                    f"{relative}#{test_id}",
                    1,
                    len(positions),
                )
                if len(positions) != 1:
                    continue
                declaration_positions[test_id] = positions[0]
                end = rust_function_end(path, text, positions[0])
                checks.need(
                    end is not None,
                    "rust_test_body",
                    f"{relative}#{test_id}",
                    "balanced function",
                    "unbalanced",
                )
                if end is None:
                    continue
                segment = text[positions[0] : end]
                scenario_id = str(scenario.get("scenario_id"))
                checks.need(
                    scenario_id in segment,
                    "rust_scenario_literal",
                    f"{relative}#{test_id}",
                    scenario_id,
                    "missing",
                )
                bindings, bare = rust_observation_bindings(path, segment)
                expected_observations = scenario.get("observation_contracts", [])
                actual_observations = [
                    {
                        "instance_id": binding.instance_id,
                        "instance_sha256": binding.instance_sha256,
                        "clause_id": binding.clause_id,
                        "clause_sha256": binding.clause_sha256,
                        "example_id": binding.example_id,
                        "example_sha256": binding.example_sha256,
                        "phase": binding.phase,
                        "oracle_contract": (
                            [binding.oracle_id, binding.oracle_sha256]
                            if binding.phase == "THEN"
                            else None
                        ),
                    }
                    for binding in bindings
                ]
                actual_ordinals = [binding.ordinal for binding in bindings]
                macro_kinds_valid = all(
                    (
                        binding.phase == "GIVEN"
                        and binding.macro_kind == "observed_precondition"
                    )
                    or (
                        binding.phase == "WHEN"
                        and binding.macro_kind == "observed_action"
                    )
                    or (
                        binding.phase == "THEN"
                        and binding.macro_kind
                        in {
                            "observed_assert",
                            "observed_assert_eq",
                            "observed_assert_ne",
                            "observed_assert_matches",
                        }
                    )
                    for binding in bindings
                )
                checks.need(
                    not bare
                    and all(binding.scenario_id == scenario_id for binding in bindings)
                    and macro_kinds_valid
                    and actual_observations == expected_observations
                    and actual_ordinals
                    == list(range(1, len(expected_observations) + 1)),
                    "rust_observation_binding",
                    f"{relative}#{test_id}",
                    {
                        "scenario_id": scenario_id,
                        "observations": expected_observations,
                        "ordinals": list(
                            range(1, len(expected_observations) + 1)
                        ),
                        "phase_specific_macros": True,
                        "bare_assertions": False,
                    },
                    {
                        "scenario_ids": [binding.scenario_id for binding in bindings],
                        "observations": actual_observations,
                        "ordinals": actual_ordinals,
                        "macro_kinds": [binding.macro_kind for binding in bindings],
                        "bare_assertions": bare,
                    },
                )
            checks.need(
                len(candidate_ids) == len(set(candidate_ids)),
                "duplicate_rust_test_declaration",
                relative,
                "unique test function names",
                candidate_ids,
            )
            checks.same(set(expected_by_id), set(candidate_ids), "rust_test_discovery", relative)
            target = str(selectors[0].get("test_target"))
            cargo_relative = Path(relative).relative_to("tests/integration/acceptance")
            expected_rust_targets[target] = f"../../tests/integration/acceptance/{cargo_relative.as_posix()}"
        elif runner_kinds == {"PLAYWRIGHT"}:
            expected_ids = {
                str(selector.get("implementation_test_id")) for selector in selectors
            }
            titles, call_count = _typescript_test_titles(text)
            checks.need(
                call_count == len(titles),
                "dynamic_playwright_test_title",
                relative,
                call_count,
                len(titles),
            )
            checks.need(
                len(titles) == len(set(titles)),
                "duplicate_playwright_test_title",
                relative,
                "unique literal titles",
                titles,
            )
            checks.same(expected_ids, set(titles), "playwright_test_discovery", relative)
        else:
            checks.need(False, "unknown_test_runner", relative, ["PLAYWRIGHT", "RUST_NEXTEST"], sorted(str(value) for value in runner_kinds))
    checks.need(
        cargo_targets == expected_rust_targets,
        "cargo_acceptance_target_set",
        "crates/test-support/Cargo.toml",
        expected_rust_targets,
        cargo_targets,
    )
    return checks


def _schema_registry(root: Path) -> tuple[dict[str, dict[str, Any]], Registry]:
    documents: dict[str, dict[str, Any]] = {}
    resources: list[tuple[str, Resource[Any]]] = []
    for relative in (EXECUTION_SCHEMA, LAYER_SCHEMA, RUN_INDEX_SCHEMA, EXTRACTION_SCHEMA):
        value = _load_json(root / relative)
        if not isinstance(value, dict) or not isinstance(value.get("$id"), str):
            raise ValueError(f"invalid JSON schema: {relative}")
        Draft202012Validator.check_schema(value)
        documents[relative] = value
        resources.append((value["$id"], Resource.from_contents(value)))
    return documents, Registry().with_resources(resources)


def _validate_schema(
    value: object,
    schema: dict[str, Any],
    schema_registry: Registry,
    checks: Checks,
    source: str,
) -> None:
    errors = sorted(
        Draft202012Validator(schema, registry=schema_registry).iter_errors(value),
        key=lambda error: [str(part) for part in error.absolute_path],
    )
    for error in errors[:100]:
        location = "/".join(str(part) for part in error.absolute_path)
        checks.need(
            False,
            "json_schema",
            f"{source}#{location}",
            "schema-valid",
            error.message,
        )
    if len(errors) > 100:
        checks.need(False, "json_schema_overflow", source, "<=100 errors", len(errors))


def _artifact(
    run_directory: Path,
    value: object,
    checks: Checks,
    source: str,
) -> Path | None:
    if not isinstance(value, dict):
        checks.need(False, "artifact_schema", source, "mapping", value)
        return None
    relative = value.get("path")
    if not _safe_relative(relative):
        checks.need(False, "artifact_path", source, "safe relative", relative)
        return None
    path = _plain_file_under(run_directory, relative)
    if path is None:
        checks.need(False, "artifact_missing", source, "plain file under run", relative)
        return None
    descriptor: int | None = None
    stable = False
    actual_size: int | None = None
    actual_sha: str | None = None
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        )
        before = os.fstat(descriptor)
        first_sha = _sha256_fd(descriptor)
        second_sha = _sha256_fd(descriptor)
        after = os.fstat(descriptor)
        stable = (
            stat.S_ISREG(before.st_mode)
            and before.st_dev == after.st_dev
            and before.st_ino == after.st_ino
            and before.st_size == after.st_size
            and before.st_mtime_ns == after.st_mtime_ns
            and first_sha == second_sha
        )
        actual_size = before.st_size
        actual_sha = first_sha
    except OSError as error:
        checks.need(False, "artifact_read", source, "stable regular file", str(error))
    finally:
        if descriptor is not None:
            os.close(descriptor)
    checks.need(
        stable
        and actual_size == value.get("size")
        and actual_sha == value.get("sha256"),
        "artifact_integrity",
        source,
        {"stable": True, "size": actual_size, "sha256": actual_sha},
        value,
    )
    return path if stable else None


def _artifact_map(
    run_directory: Path,
    values: object,
    checks: Checks,
    source: str,
) -> dict[str, Path]:
    result: dict[str, Path] = {}
    if not isinstance(values, list):
        checks.need(False, "artifact_list", source, "list", values)
        return result
    for index, value in enumerate(values):
        relative = value.get("path") if isinstance(value, dict) else None
        path = _artifact(run_directory, value, checks, f"{source}/{index}")
        if path is None or not isinstance(relative, str):
            continue
        checks.need(
            relative not in result,
            "duplicate_artifact_path",
            source,
            "unique artifact paths",
            relative,
        )
        result[relative] = path
    return result


def _machine_report_validation(
    run_directory: Path,
    receipt: dict[str, Any],
    scenario: dict[str, Any],
    checks: Checks,
    source: str,
) -> None:
    scenario_id = str(scenario.get("scenario_id"))
    execution = scenario.get("execution", {})
    selector = execution.get("selector", {}) if isinstance(execution, dict) else {}
    runner_kind = selector.get("runner_kind") if isinstance(selector, dict) else None
    identity = str(selector.get("implementation_test_id"))
    implementation_path = str(execution.get("implementation_test_path"))
    prefix = f"scenarios/{scenario_id}/baseline"
    artifacts = _artifact_map(
        run_directory,
        receipt.get("artifacts"),
        checks,
        f"{source}#artifacts",
    )
    discovery_path = artifacts.get(f"{prefix}/discovery.report.json")
    run_relative = (
        f"{prefix}/run.junit.xml"
        if runner_kind == "RUST_NEXTEST"
        else f"{prefix}/run.report.json"
    )
    run_path = artifacts.get(run_relative)
    mutation_path = artifacts.get(f"scenarios/{scenario_id}/mutations.json")
    checks.need(
        discovery_path is not None and run_path is not None and mutation_path is not None,
        "machine_report_artifact_set",
        source,
        [
            f"{prefix}/discovery.report.json",
            run_relative,
            f"scenarios/{scenario_id}/mutations.json",
        ],
        sorted(artifacts),
    )
    if discovery_path is None or run_path is None:
        return
    try:
        if runner_kind == "RUST_NEXTEST":
            discovery_counts = parse_nextest_discovery(
                discovery_path.read_bytes(), identity
            )
            run_counts = parse_nextest_junit(run_path.read_bytes(), identity)
        elif runner_kind == "PLAYWRIGHT":
            discovery_counts = parse_playwright_report(
                discovery_path.read_bytes(),
                identity,
                implementation_path,
                list_only=True,
            )
            run_counts = parse_playwright_report(
                run_path.read_bytes(),
                identity,
                implementation_path,
                list_only=False,
            )
        else:
            raise MachineReportError(f"unknown runner kind: {runner_kind!r}")
    except MachineReportError as error:
        checks.need(
            False,
            "machine_report",
            source,
            "one exact passing machine report",
            str(error),
        )
        return
    checks.need(
        discovery_counts.discovered == 1 and run_counts.success(),
        "machine_terminal_counts",
        source,
        "discovery 1 and terminal 1/1/1/1/0/0/0",
        {
            "discovery": asdict(discovery_counts),
            "run": asdict(run_counts),
        },
    )
    receipt_counts = receipt.get("counts", {})
    checks.need(
        isinstance(receipt_counts, dict)
        and all(
            receipt_counts.get(key) == value
            for key, value in asdict(run_counts).items()
        ),
        "receipt_machine_count_binding",
        source,
        asdict(run_counts),
        receipt_counts,
    )
    if mutation_path is None:
        return
    try:
        mutation = _load_json(mutation_path)
    except (OSError, UnicodeError, ValueError) as error:
        checks.need(
            False,
            "mutation_summary_json",
            str(mutation_path),
            "closed JSON",
            str(error),
        )
        return
    expected_observations = scenario.get("observation_contracts", [])
    rows = mutation.get("mutations") if isinstance(mutation, dict) else None
    expected_counts = {
        "total": len(expected_observations),
        "killed": len(expected_observations),
        "survivors": 0,
        "skipped": 0,
    }
    checks.need(
        isinstance(mutation, dict)
        and set(mutation) == {
            "schema_version",
            "receipt_kind",
            "scenario_id",
            "counts",
            "mutations",
        }
        and mutation.get("schema_version") == 2
        and mutation.get("receipt_kind") == "ACCEPTANCE_OBSERVATION_MUTATIONS"
        and mutation.get("scenario_id") == scenario_id
        and mutation.get("counts") == expected_counts
        and isinstance(rows, list)
        and len(rows) == len(expected_observations),
        "mutation_summary_contract",
        str(mutation_path),
        expected_counts,
        mutation,
    )
    if not isinstance(rows, list):
        return
    for index, (row, observation) in enumerate(
        zip(rows, expected_observations, strict=False), start=1
    ):
        if not isinstance(row, dict) or not isinstance(observation, dict):
            checks.need(
                False,
                "mutation_row",
                f"{mutation_path}#{index}",
                "mapping",
                row,
            )
            continue
        sentinel = (
            f"GURINE_ASSERTION_REACHED:{scenario_id}:{index}:"
            f"{observation.get('instance_id')}:{observation.get('instance_sha256')}"
        ).encode("utf-8")
        expected_terminal = {
            "discovered": 1,
            "started": 1,
            "terminal": 1,
            "passed": 0,
            "failed": 1,
            "skipped": 0,
            "retried": 0,
        }
        checks.need(
            row.get("observation_ordinal") == index
            and row.get("instance_id") == observation.get("instance_id")
            and row.get("instance_sha256") == observation.get("instance_sha256")
            and row.get("sentinel_sha256") == hashlib.sha256(sentinel).hexdigest()
            and isinstance(row.get("duration_ms"), int)
            and not isinstance(row.get("duration_ms"), bool)
            and row.get("duration_ms") > 0
            and isinstance(row.get("exit_code"), int)
            and not isinstance(row.get("exit_code"), bool)
            and row.get("exit_code") > 0
            and row.get("counts") == expected_terminal,
            "mutation_row_binding",
            f"{mutation_path}#{index}",
            {
                "ordinal": index,
                "instance_id": observation.get("instance_id"),
                "instance_sha256": observation.get("instance_sha256"),
                "counts": expected_terminal,
            },
            row,
        )
        row_artifacts = _artifact_map(
            run_directory,
            row.get("artifacts"),
            checks,
            f"{mutation_path}#{index}/artifacts",
        )
        mutation_prefix = f"scenarios/{scenario_id}/mutations/{index:04d}"
        report_relative = (
            f"{mutation_prefix}/run.junit.xml"
            if runner_kind == "RUST_NEXTEST"
            else f"{mutation_prefix}/run.report.json"
        )
        report_path = row_artifacts.get(report_relative)
        stdout_path = row_artifacts.get(f"{mutation_prefix}/run.stdout")
        stderr_path = row_artifacts.get(f"{mutation_prefix}/run.stderr")
        checks.need(
            report_path is not None
            and stdout_path is not None
            and stderr_path is not None,
            "mutation_machine_artifacts",
            f"{mutation_path}#{index}",
            [
                report_relative,
                f"{mutation_prefix}/run.stdout",
                f"{mutation_prefix}/run.stderr",
            ],
            sorted(row_artifacts),
        )
        if report_path is None or stdout_path is None or stderr_path is None:
            continue
        try:
            if runner_kind == "RUST_NEXTEST":
                terminal = parse_nextest_junit(
                    report_path.read_bytes(), identity, expected_failure=True
                )
            else:
                terminal = parse_playwright_report(
                    report_path.read_bytes(),
                    identity,
                    implementation_path,
                    list_only=False,
                    expected_failure=True,
                )
        except MachineReportError as error:
            checks.need(
                False,
                "mutation_machine_report",
                f"{mutation_path}#{index}",
                "one exact failed sentinel execution",
                str(error),
            )
            continue
        combined = (
            stdout_path.read_bytes()
            + stderr_path.read_bytes()
            + report_path.read_bytes()
        )
        checks.need(
            terminal.sentinel_failure() and sentinel in combined,
            "mutation_sentinel",
            f"{mutation_path}#{index}",
            hashlib.sha256(sentinel).hexdigest(),
            {
                "terminal": asdict(terminal),
                "sentinel_present": sentinel in combined,
            },
        )


def _plain_file_under(root: Path, relative: object) -> Path | None:
    if not _safe_relative(relative):
        return None
    try:
        root_resolved = root.resolve(strict=True)
        current = root
        for part in PurePosixPath(str(relative)).parts:
            current = current / part
            if current.is_symlink():
                return None
        resolved = current.resolve(strict=True)
    except OSError:
        return None
    if not resolved.is_relative_to(root_resolved) or not current.is_file():
        return None
    return current


def _symlink_free_path(path: Path) -> bool:
    absolute = path if path.is_absolute() else Path.cwd() / path
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        try:
            metadata = current.lstat()
        except OSError:
            return False
        if stat.S_ISLNK(metadata.st_mode):
            return False
    return True


def _git_ignored_path(root: Path, path: Path) -> bool:
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError:
        return False
    if not relative or relative == ".":
        return False
    environment = dict(os.environ)
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    result = subprocess.run(
        ["git", "-C", str(root), "check-ignore", "--quiet", "--", relative],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=environment,
    )
    return result.returncode == 0


def _evidence_path_allowed(root: Path, path: Path) -> tuple[bool, Path | None]:
    try:
        root_resolved = root.resolve(strict=True)
        resolved = path.resolve(strict=True)
    except OSError:
        return False, None
    if not _symlink_free_path(path):
        return False, resolved
    allowed = not resolved.is_relative_to(root_resolved) or _git_ignored_path(
        root_resolved, resolved
    )
    return allowed, resolved


def _source_inventory_without_evidence(
    root: Path, evidence_root: Path
) -> dict[str, tuple[str, int]]:
    inventory = worktree_inventory(root)
    root_resolved = root.resolve()
    evidence_resolved = evidence_root.resolve()
    prefix = (
        evidence_resolved.relative_to(root_resolved).as_posix()
        if evidence_resolved.is_relative_to(root_resolved)
        else None
    )
    return {
        relative: value
        for relative, value in inventory.items()
        if not source_archive_excluded(Path(relative))
        and (
            prefix is None
            or (relative != prefix and not relative.startswith(f"{prefix}/"))
        )
    }


def _expected_common_bindings(
    root: Path,
    registry: dict[str, Any],
    evidence_root: Path,
    checks: Checks,
) -> dict[str, object]:
    required_environment = {
        "source_commit": "GURINNAE_SOURCE_COMMIT",
        "source_tree_sha256": "GURINNAE_SOURCE_TREE_SHA256",
        "archive_sha256": "GURINNAE_ARCHIVE_SHA256",
        "extraction_receipt_sha256": "GURINNAE_EXTRACTION_RECEIPT_SHA256",
    }
    result: dict[str, object] = {
        "authority_zip_sha256": AUTHORITY_ZIP_SHA256,
        "effective_registry_sha256": _sha256(root / EFFECTIVE_REGISTRY),
    }
    try:
        manifest = build_design_manifest(root)
        checks.need(
            manifest.get("authority_zip_sha256") == AUTHORITY_ZIP_SHA256,
            "design_authority_binding",
            "design bundle",
            AUTHORITY_ZIP_SHA256,
            manifest.get("authority_zip_sha256"),
        )
        result["design_bundle_sha256"] = manifest["bundle_sha256"]
        result["member_manifest_sha256"] = manifest["member_manifest_sha256"]
    except Exception as error:
        checks.need(False, "design_bundle_binding", "design bundle", "current manifest", str(error))
    for field, variable in required_environment.items():
        value = os.environ.get(variable)
        checks.need(
            isinstance(value, str) and SHA256_RE.fullmatch(value) is not None
            if field != "source_commit"
            else isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) is not None,
            "missing_release_binding",
            variable,
            "pinned digest",
            value,
        )
        result[field] = value
    try:
        current_tree = source_tree_digest(
            _source_inventory_without_evidence(root, evidence_root)
        )
        checks.need(
            result.get("source_tree_sha256") == current_tree,
            "source_tree_binding",
            "GURINNAE_SOURCE_TREE_SHA256",
            current_tree,
            result.get("source_tree_sha256"),
        )
    except Exception as error:
        checks.need(False, "source_tree_binding", str(root), "current digest", str(error))
    return result


def _git_clean_binding(root: Path, expected_commit: object, checks: Checks) -> None:
    git_directory = root / ".git"
    if not git_directory.exists():
        # Clean extractions intentionally omit .git; the extraction receipt and
        # source provenance binding remain authoritative there.
        return
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    status = subprocess.run(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"],
        cwd=root,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    checks.need(
        head.returncode == 0 and head.stdout.strip() == expected_commit,
        "source_commit_binding",
        str(root),
        expected_commit,
        head.stdout.strip() if head.returncode == 0 else head.stderr.strip(),
    )
    checks.need(
        status.returncode == 0 and not status.stdout,
        "dirty_source_tree",
        str(root),
        "clean",
        status.stdout.splitlines()[:100] if status.returncode == 0 else status.stderr.strip(),
    )


def _validate_extraction_receipt(
    root: Path,
    schemas: dict[str, dict[str, Any]],
    schema_registry: Registry,
    common: dict[str, object],
    checks: Checks,
) -> None:
    raw_path = os.environ.get("GURINNAE_EXTRACTION_RECEIPT")
    if not raw_path:
        checks.need(
            False,
            "missing_extraction_receipt",
            "GURINNAE_EXTRACTION_RECEIPT",
            "external or Git-ignored JSON path",
            raw_path,
        )
        return
    path = Path(raw_path)
    try:
        resolved = path.resolve(strict=True)
        allowed, _ = _evidence_path_allowed(root, path)
        valid = allowed and path.is_file()
    except OSError as error:
        checks.need(
            False,
            "missing_extraction_receipt",
            raw_path,
            "regular external or Git-ignored file",
            str(error),
        )
        return
    checks.need(
        valid,
        "extraction_receipt_path_policy",
        raw_path,
        "symlink-free and outside repository or Git-ignored",
        str(resolved),
    )
    if not valid:
        return
    checks.need(
        _sha256(path) == common.get("extraction_receipt_sha256"),
        "extraction_receipt_digest",
        raw_path,
        common.get("extraction_receipt_sha256"),
        _sha256(path),
    )
    try:
        value = _load_json(path)
    except (OSError, UnicodeError, ValueError) as error:
        checks.need(False, "extraction_receipt_json", raw_path, "valid JSON", str(error))
        return
    _validate_schema(value, schemas[EXTRACTION_SCHEMA], schema_registry, checks, raw_path)
    if not isinstance(value, dict):
        return
    expected = {
        "archive_sha256": common.get("archive_sha256"),
        "source_tree_sha256": common.get("source_tree_sha256"),
        "design_bundle_sha256": common.get("design_bundle_sha256"),
        "member_manifest_sha256": common.get("member_manifest_sha256"),
    }
    for key, wanted in expected.items():
        checks.need(value.get(key) == wanted, "extraction_binding", f"{raw_path}#{key}", wanted, value.get(key))


def _assertion_events(
    path: Path,
    scenario: dict[str, Any],
    checks: Checks,
) -> tuple[
    set[tuple[str, str]],
    set[tuple[str, str]],
    set[tuple[str, str, str]],
    set[tuple[str, str, str]],
    set[tuple[str, str]],
    set[tuple[str, str]],
    int,
]:
    instances: set[tuple[str, str]] = set()
    oracles: set[tuple[str, str]] = set()
    instance_layers: set[tuple[str, str, str]] = set()
    oracle_layers: set[tuple[str, str, str]] = set()
    observation_edges: set[tuple[str, str]] = set()
    oracle_edges: set[tuple[str, str]] = set()
    observations: set[tuple[str, str]] = set()
    contracts = {
        str(row.get("instance_id")): row
        for row in scenario.get("observation_contracts", [])
        if isinstance(row, dict) and isinstance(row.get("instance_id"), str)
    }
    observation_edge_contracts = {
        (str(row.get("instance_id")), str(row.get("layer_id"))): row
        for row in scenario.get("observation_layer_contracts", [])
        if isinstance(row, dict)
    }
    oracle_edge_contracts = {
        (str(row.get("oracle_id")), str(row.get("layer_id"))): row
        for row in scenario.get("oracle_layer_contracts", [])
        if isinstance(row, dict)
    }
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        checks.need(False, "assertion_event_log", str(path), "UTF-8 JSONL", str(error))
        return (
            instances,
            oracles,
            instance_layers,
            oracle_layers,
            observation_edges,
            oracle_edges,
            0,
        )
    for index, line in enumerate(lines, start=1):
        try:
            def reject_duplicate(
                pairs: list[tuple[str, object]],
            ) -> dict[str, object]:
                value: dict[str, object] = {}
                for key, child in pairs:
                    if key in value:
                        raise ValueError(f"duplicate JSON key: {key}")
                    value[key] = child
                return value

            value = json.loads(line, object_pairs_hook=reject_duplicate)
        except (json.JSONDecodeError, ValueError) as error:
            checks.need(False, "assertion_event_json", f"{path}:{index}", "JSON", str(error))
            continue
        common = {
            "schema_version",
            "event_kind",
            "scenario_id",
            "instance_id",
            "instance_sha256",
            "clause_id",
            "clause_sha256",
            "example_id",
            "example_sha256",
            "phase",
            "observation_ordinal",
            "layer_id",
            "observation_layer_edge_id",
            "observation_layer_edge_sha256",
            "effect_binding_sha256",
            "status",
        }
        phase = value.get("phase") if isinstance(value, dict) else None
        required = common | (
            {
                "oracle_id",
                "oracle_sha256",
                "oracle_layer_edge_id",
                "oracle_layer_edge_sha256",
            }
            if phase == "THEN"
            else set()
        )
        valid = isinstance(value, dict) and phase in {"GIVEN", "WHEN", "THEN"} and set(value) == required
        checks.need(
            valid,
            "assertion_event_schema",
            f"{path}:{index}",
            sorted(required),
            sorted(value) if isinstance(value, dict) else value,
        )
        if not valid:
            continue
        contract = contracts.get(str(value.get("instance_id")))
        expected_oracle = contract.get("oracle_contract") if isinstance(contract, dict) else None
        expected_observation_edge = observation_edge_contracts.get(
            (str(value.get("instance_id")), str(value.get("layer_id")))
        )
        expected_oracle_edge = (
            oracle_edge_contracts.get(
                (str(value.get("oracle_id")), str(value.get("layer_id")))
            )
            if phase == "THEN"
            else None
        )
        checks.need(
            value.get("schema_version") == 1
            and value.get("event_kind") == "ACCEPTANCE_OBSERVATION"
            and value.get("scenario_id") == scenario.get("scenario_id")
            and value.get("status") == "PASSED"
            and value.get("layer_id") in RUNTIME_LAYERS
            and isinstance(value.get("observation_ordinal"), int)
            and not isinstance(value.get("observation_ordinal"), bool)
            and value.get("observation_ordinal") > 0
            and SHA256_RE.fullmatch(str(value.get("effect_binding_sha256"))) is not None,
            "assertion_event_binding",
            f"{path}:{index}",
            "current scenario, known layer, positive observation ordinal, effect digest",
            value,
        )
        checks.need(
            isinstance(contract, dict)
            and value.get("instance_sha256") == contract.get("instance_sha256")
            and value.get("clause_id") == contract.get("clause_id")
            and value.get("clause_sha256") == contract.get("clause_sha256")
            and value.get("example_id") == contract.get("example_id")
            and value.get("example_sha256") == contract.get("example_sha256")
            and value.get("phase") == contract.get("phase")
            and (
                phase != "THEN"
                or (
                    isinstance(expected_oracle, list)
                    and len(expected_oracle) == 2
                    and value.get("oracle_id") == expected_oracle[0]
                    and value.get("oracle_sha256") == expected_oracle[1]
                )
            )
            and isinstance(expected_observation_edge, dict)
            and value.get("observation_layer_edge_id")
            == expected_observation_edge.get("edge_id")
            and value.get("observation_layer_edge_sha256")
            == expected_observation_edge.get("edge_sha256")
            and (
                phase != "THEN"
                or (
                    isinstance(expected_oracle_edge, dict)
                    and value.get("oracle_layer_edge_id")
                    == expected_oracle_edge.get("edge_id")
                    and value.get("oracle_layer_edge_sha256")
                    == expected_oracle_edge.get("edge_sha256")
                )
            ),
            "assertion_event_contract",
            f"{path}:{index}",
            contract,
            value,
        )
        instance_pair = (str(value.get("instance_id")), str(value.get("instance_sha256")))
        layer_id = str(value.get("layer_id"))
        observation_key = (instance_pair[0], layer_id)
        checks.need(
            observation_key not in observations,
            "duplicate_assertion_event",
            f"{path}:{index}",
            "unique instance/layer edge",
            observation_key,
        )
        observations.add(observation_key)
        instances.add(instance_pair)
        instance_layers.add((instance_pair[0], instance_pair[1], layer_id))
        observation_edges.add(
            (
                str(value.get("observation_layer_edge_id")),
                str(value.get("observation_layer_edge_sha256")),
            )
        )
        if phase == "THEN":
            oracle_pair = (str(value.get("oracle_id")), str(value.get("oracle_sha256")))
            oracles.add(oracle_pair)
            oracle_layers.add((oracle_pair[0], oracle_pair[1], layer_id))
            oracle_edges.add(
                (
                    str(value.get("oracle_layer_edge_id")),
                    str(value.get("oracle_layer_edge_sha256")),
                )
            )
    return (
        instances,
        oracles,
        instance_layers,
        oracle_layers,
        observation_edges,
        oracle_edges,
        len(observations),
    )


def _expected_layer_ids(
    scenario: dict[str, Any],
    registry: dict[str, Any],
) -> list[str]:
    runtime_contracts = registry.get("runtime_contracts", {})
    profiles = runtime_contracts.get("profiles", {}) if isinstance(runtime_contracts, dict) else {}
    execution = scenario.get("execution", {})
    profile_id = execution.get("runtime_profile_id") if isinstance(execution, dict) else None
    profile = profiles.get(profile_id, {}) if isinstance(profiles, dict) else {}
    rows = profile.get("layer_ids", []) if isinstance(profile, dict) else []
    return [str(value) for value in rows] if isinstance(rows, list) else []


def _runtime_layers(
    run_directory: Path,
    receipt: dict[str, Any],
    scenario: dict[str, Any],
    registry: dict[str, Any],
    schemas: dict[str, dict[str, Any]],
    schema_registry: Registry,
    checks: Checks,
    source: str,
) -> None:
    runtime_contracts = registry.get("runtime_contracts", {})
    profiles = runtime_contracts.get("profiles", {}) if isinstance(runtime_contracts, dict) else {}
    layers = runtime_contracts.get("layers", {}) if isinstance(runtime_contracts, dict) else {}
    execution = scenario.get("execution", {})
    profile_id = execution.get("runtime_profile_id") if isinstance(execution, dict) else None
    profile = profiles.get(profile_id, {}) if isinstance(profiles, dict) else {}
    expected_ids = _expected_layer_ids(scenario, registry)
    rows = receipt.get("layer_receipts")
    actual: dict[str, dict[str, Any]] = {}
    if not isinstance(rows, list):
        checks.need(False, "runtime_layer_receipts", source, "list", rows)
        return
    for index, row in enumerate(rows):
        _validate_schema(
            row,
            schemas[LAYER_SCHEMA],
            schema_registry,
            checks,
            f"{source}#layer_receipts/{index}",
        )
        layer_id = row.get("layer_id") if isinstance(row, dict) else None
        if not isinstance(row, dict) or not isinstance(layer_id, str):
            continue
        checks.need(
            layer_id not in actual,
            "duplicate_runtime_layer_receipt",
            source,
            "unique layer IDs",
            layer_id,
        )
        actual[layer_id] = row
    checks.same(
        set(str(value) for value in expected_ids),
        set(actual),
        "runtime_layer_receipt_set",
        source,
    )
    for layer_id, row in actual.items():
        contract = layers.get(layer_id, {}) if isinstance(layers, dict) else {}
        checks.need(
            row.get("scenario_id") == scenario.get("scenario_id")
            and row.get("runtime_profile_id") == profile_id
            and row.get("runtime_profile_sha256") == scenario.get("runtime_profile_sha256")
            and row.get("layer_contract_sha256") == contract.get("layer_contract_sha256")
            and row.get("probe_kind") == contract.get("probe_kind")
            and row.get("status") == "PASSED",
            "runtime_layer_contract",
            f"{source}#{layer_id}",
            contract,
            row,
        )
        checks.need(
            row.get("oracle_contracts") == scenario.get("oracle_contracts"),
            "runtime_layer_oracle_contracts",
            f"{source}#{layer_id}",
            scenario.get("oracle_contracts"),
            row.get("oracle_contracts"),
        )
        expected_oracle_layer_contracts = [
            [edge.get("edge_id"), edge.get("edge_sha256")]
            for edge in scenario.get("oracle_layer_contracts", [])
            if isinstance(edge, dict) and edge.get("layer_id") == layer_id
        ]
        checks.need(
            row.get("oracle_layer_contracts")
            == expected_oracle_layer_contracts,
            "runtime_layer_oracle_edges",
            f"{source}#{layer_id}",
            expected_oracle_layer_contracts,
            row.get("oracle_layer_contracts"),
        )
        probe_argv = row.get("probe_argv")
        probe_facts = row.get("probe_facts")
        template = contract.get("probe_argv_template") if isinstance(contract, dict) else None
        selector = execution.get("selector", {}) if isinstance(execution, dict) else {}
        replacements = {
            "{scenario_id}": str(scenario.get("scenario_id")),
            "{implementation_test_path}": str(execution.get("implementation_test_path"))
            if isinstance(execution, dict)
            else "",
            "{implementation_test_id}": str(selector.get("implementation_test_id"))
            if isinstance(selector, dict)
            else "",
        }
        expected_probe_argv = [
            replacements.get(str(value), str(value)) for value in template
        ] if isinstance(template, list) else None
        checks.need(
            probe_argv == expected_probe_argv,
            "runtime_layer_probe_command_binding",
            f"{source}#{layer_id}",
            expected_probe_argv,
            probe_argv,
        )
        checks.need(
            row.get("probe_argv_sha256")
            == canonical_sha256(PROBE_ARGV_DOMAIN, probe_argv),
            "runtime_layer_probe_argv",
            f"{source}#{layer_id}",
            canonical_sha256(PROBE_ARGV_DOMAIN, probe_argv),
            row.get("probe_argv_sha256"),
        )
        checks.need(
            row.get("probe_facts_sha256")
            == canonical_sha256(PROBE_FACTS_DOMAIN, probe_facts)
            and isinstance(probe_facts, dict)
            and probe_facts.get("kind") == row.get("probe_kind"),
            "runtime_layer_probe_facts",
            f"{source}#{layer_id}",
            {
                "sha256": canonical_sha256(PROBE_FACTS_DOMAIN, probe_facts),
                "kind": row.get("probe_kind"),
            },
            {
                "sha256": row.get("probe_facts_sha256"),
                "kind": probe_facts.get("kind") if isinstance(probe_facts, dict) else None,
            },
        )
        stdout_artifact = _artifact(
            run_directory,
            row.get("probe_stdout_artifact"),
            checks,
            f"{source}#{layer_id}/probe_stdout_artifact",
        )
        stderr_artifact = _artifact(
            run_directory,
            row.get("probe_stderr_artifact"),
            checks,
            f"{source}#{layer_id}/probe_stderr_artifact",
        )
        checks.need(
            row.get("probe_exit_code") == 0,
            "runtime_layer_probe_exit",
            f"{source}#{layer_id}",
            0,
            row.get("probe_exit_code"),
        )
        for name, entry, expected_digest in (
            ("stdout", stdout_artifact, row.get("probe_stdout_sha256")),
            ("stderr", stderr_artifact, row.get("probe_stderr_sha256")),
        ):
            checks.need(
                entry is not None
                and isinstance(expected_digest, str)
                and _sha256(entry) == expected_digest,
                f"runtime_layer_probe_{name}_digest",
                f"{source}#{layer_id}",
                expected_digest,
                _sha256(entry) if entry is not None else None,
            )
        raw_probe = row.get("raw_probe_artifact")
        raw_path = _artifact(
            run_directory,
            raw_probe,
            checks,
            f"{source}#{layer_id}/raw_probe_artifact",
        )
        checks.need(
            isinstance(raw_probe, dict) and raw_probe in row.get("artifacts", []),
            "runtime_layer_raw_probe_membership",
            f"{source}#{layer_id}",
            "raw probe artifact included in artifacts",
            raw_probe,
        )
        if raw_path is not None:
            try:
                raw_value = _load_json(raw_path)
            except (OSError, UnicodeError, ValueError) as error:
                checks.need(
                    False,
                    "runtime_layer_raw_probe_json",
                    str(raw_path),
                    "closed JSON",
                    str(error),
                )
            else:
                expected_raw = {
                    "schema_version": 1,
                    "scenario_id": scenario.get("scenario_id"),
                    "layer_id": layer_id,
                    "probe_kind": row.get("probe_kind"),
                    "probe_argv": probe_argv,
                    "probe_facts": probe_facts,
                }
                checks.need(
                    raw_value == expected_raw,
                    "runtime_layer_raw_probe_binding",
                    str(raw_path),
                    expected_raw,
                    raw_value,
                )
        for artifact_index, artifact in enumerate(row.get("artifacts", [])):
            _artifact(
                run_directory,
                artifact,
                checks,
                f"{source}#{layer_id}/artifacts/{artifact_index}",
            )
        checks.need(
            isinstance(row.get("artifacts"), list)
            and all(
                candidate in row.get("artifacts", [])
                for candidate in (
                    row.get("raw_probe_artifact"),
                    row.get("probe_stdout_artifact"),
                    row.get("probe_stderr_artifact"),
                )
            ),
            "runtime_layer_probe_artifact_membership",
            f"{source}#{layer_id}",
            "raw/stdout/stderr probe artifacts included",
            row.get("artifacts"),
        )


def _validate_scenario_receipt(
    root: Path,
    run_directory: Path,
    value: object,
    scenario: dict[str, Any],
    registry: dict[str, Any],
    common: dict[str, object],
    schemas: dict[str, dict[str, Any]],
    schema_registry: Registry,
    checks: Checks,
    source: str,
) -> None:
    _validate_schema(
        value,
        schemas[EXECUTION_SCHEMA],
        schema_registry,
        checks,
        source,
    )
    if not isinstance(value, dict):
        return
    scenario_id = scenario.get("scenario_id")
    checks.need(
        value.get("run_id") == run_directory.name
        and value.get("receipt_id")
        == f"ACR-{run_directory.name}-{scenario_id}",
        "scenario_run_binding",
        source,
        {
            "run_id": run_directory.name,
            "receipt_id": f"ACR-{run_directory.name}-{scenario_id}",
        },
        {
            "run_id": value.get("run_id"),
            "receipt_id": value.get("receipt_id"),
        },
    )
    execution = scenario.get("execution", {})
    selector = execution.get("selector", {}) if isinstance(execution, dict) else {}
    expected_identity = {
        "origin": scenario.get("origin"),
        "scenario_id": scenario_id,
        "feature_file": scenario.get("feature_file"),
        "scenario_title": scenario.get("scenario_title"),
        "runtime_profile_id": execution.get("runtime_profile_id")
        if isinstance(execution, dict)
        else None,
        "runtime_profile_sha256": scenario.get("runtime_profile_sha256"),
    }
    for key, expected in expected_identity.items():
        checks.need(
            value.get(key) == expected,
            "scenario_receipt_identity",
            f"{source}#{key}",
            expected,
            value.get(key),
        )

    invocation = value.get("invocation", {})
    expected_invocation = {
        "runner_kind": selector.get("runner_kind"),
        "implementation_test_path": execution.get("implementation_test_path")
        if isinstance(execution, dict)
        else None,
        "implementation_test_id": selector.get("implementation_test_id"),
        "discovery_argv": selector.get("discovery_argv"),
        "run_argv": selector.get("run_argv"),
        "run_argv_sha256": canonical_sha256(
            ARGV_DOMAIN,
            selector.get("run_argv"),
        ),
    }
    checks.need(
        invocation == expected_invocation,
        "scenario_invocation",
        source,
        expected_invocation,
        invocation,
    )

    bindings = value.get("bindings", {})
    expected_bindings = {
        **common,
        "base_mapping_sha256": _sha256(root / BASE_MAPPING),
        "supplemental_mapping_sha256": _sha256(root / SUPPLEMENTAL_MAPPING),
        "feature_sha256": scenario.get("feature_sha256"),
        "scenario_contract_sha256": scenario.get("scenario_contract_sha256"),
        "test_source_sha256": _sha256(
            root / str(execution.get("implementation_test_path"))
        )
        if isinstance(execution, dict)
        and (root / str(execution.get("implementation_test_path"))).is_file()
        else None,
        "selector_sha256": selector.get("selector_sha256"),
    }
    checks.need(
        bindings == expected_bindings,
        "scenario_receipt_bindings",
        source,
        expected_bindings,
        bindings,
    )

    observations = value.get("observations", {})
    expected_observations = {
        "clause_contracts": scenario.get("clause_contracts"),
        "example_contracts": scenario.get("example_contracts"),
        "instance_contracts": scenario.get("instance_contracts"),
        "oracle_contracts": scenario.get("oracle_contracts"),
        "observation_contracts": scenario.get("observation_contracts"),
    }
    for key, expected in expected_observations.items():
        checks.need(
            observations.get(key) == expected if isinstance(observations, dict) else False,
            "scenario_observation_contract",
            f"{source}#{key}",
            expected,
            observations.get(key) if isinstance(observations, dict) else observations,
        )
    event_artifact = (
        observations.get("assertion_event_artifact")
        if isinstance(observations, dict)
        else None
    )
    event_path = _artifact(
        run_directory,
        event_artifact,
        checks,
        f"{source}#assertion_event_artifact",
    )
    if event_path is not None:
        (
            instances,
            oracles,
            instance_layers,
            oracle_layers,
            observation_edges,
            oracle_edges,
            assertion_count,
        ) = _assertion_events(
            event_path,
            scenario,
            checks,
        )
        expected_layers = _expected_layer_ids(scenario, registry)
        checks.same(
            {tuple(pair) for pair in scenario.get("instance_contracts", [])},
            instances,
            "assertion_instance_set",
            source,
        )
        checks.same(
            {tuple(pair) for pair in scenario.get("oracle_contracts", [])},
            oracles,
            "assertion_oracle_set",
            source,
        )
        checks.need(
            instance_layers
            == {
                (str(pair[0]), str(pair[1]), layer_id)
                for pair in scenario.get("instance_contracts", [])
                for layer_id in expected_layers
            },
            "assertion_instance_layer_set",
            source,
            "exact instance x runtime-layer set",
            sorted(instance_layers),
        )
        checks.need(
            oracle_layers
            == {
                (str(pair[0]), str(pair[1]), layer_id)
                for pair in scenario.get("oracle_contracts", [])
                for layer_id in expected_layers
            },
            "assertion_oracle_layer_set",
            source,
            "exact oracle x runtime-layer set",
            sorted(oracle_layers),
        )
        checks.need(
            observation_edges
            == {
                (str(edge.get("edge_id")), str(edge.get("edge_sha256")))
                for edge in scenario.get("observation_layer_contracts", [])
                if isinstance(edge, dict)
            },
            "assertion_observation_edge_set",
            source,
            "exact static observation-layer edge set",
            sorted(observation_edges),
        )
        checks.need(
            oracle_edges
            == {
                (str(edge.get("edge_id")), str(edge.get("edge_sha256")))
                for edge in scenario.get("oracle_layer_contracts", [])
                if isinstance(edge, dict)
            },
            "assertion_oracle_edge_set",
            source,
            "exact static oracle-layer edge set",
            sorted(oracle_edges),
        )
        counts = value.get("counts", {})
        expected_assertion_count = len(scenario.get("instance_contracts", [])) * len(expected_layers)
        checks.need(
            isinstance(counts, dict)
            and counts.get("assertions") == assertion_count
            and assertion_count == expected_assertion_count,
            "assertion_count",
            source,
            expected_assertion_count,
            counts.get("assertions") if isinstance(counts, dict) else counts,
        )
    _runtime_layers(
        run_directory,
        value,
        scenario,
        registry,
        schemas,
        schema_registry,
        checks,
        source,
    )
    _machine_report_validation(
        run_directory,
        value,
        scenario,
        checks,
        source,
    )
    for artifact_index, artifact in enumerate(value.get("artifacts", [])):
        _artifact(
            run_directory,
            artifact,
            checks,
            f"{source}#artifacts/{artifact_index}",
        )


def _validate_run_seal(
    run_directory: Path,
    index_path: Path,
    checks: Checks,
) -> None:
    seal_path = _plain_file_under(run_directory, "seal.json")
    if seal_path is None:
        checks.need(False, "run_seal", str(run_directory), "seal.json", "missing")
        return
    seal_before = seal_path.read_bytes()
    try:
        seal = _load_json(seal_path)
    except (OSError, UnicodeError, ValueError) as error:
        checks.need(False, "run_seal_json", str(seal_path), "closed JSON", str(error))
        return
    expected_keys = {
        "schema_version",
        "seal_kind",
        "run_id",
        "run_index_sha256",
        "member_count",
        "member_set_sha256",
        "members",
        "sealed_at",
    }
    checks.need(
        isinstance(seal, dict)
        and set(seal) == expected_keys
        and seal.get("schema_version") == 1
        and seal.get("seal_kind") == "ACCEPTANCE_RUN_SEAL"
        and seal.get("run_id") == run_directory.name
        and seal.get("run_index_sha256") == _sha256(index_path),
        "run_seal_contract",
        str(seal_path),
        {
            "keys": sorted(expected_keys),
            "run_id": run_directory.name,
            "run_index_sha256": _sha256(index_path),
        },
        seal,
    )
    actual_members: list[dict[str, object]] = []
    for path in sorted(run_directory.rglob("*")):
        if path == seal_path:
            continue
        relative = path.relative_to(run_directory).as_posix()
        if path.is_symlink():
            checks.need(False, "sealed_symlink", relative, "absent", "present")
            continue
        if path.is_dir():
            continue
        try:
            metadata = path.stat()
        except OSError as error:
            checks.need(False, "sealed_member", relative, "readable", str(error))
            continue
        if not stat.S_ISREG(metadata.st_mode):
            checks.need(False, "sealed_special_file", relative, "regular", metadata.st_mode)
            continue
        checks.need(
            metadata.st_size > 0,
            "sealed_empty_file",
            relative,
            ">0 bytes",
            metadata.st_size,
        )
        actual_members.append(
            {
                "path": relative,
                "size": metadata.st_size,
                "sha256": _sha256(path),
            }
        )
    actual_digest = canonical_sha256(
        SEAL_DOMAIN,
        [[row["path"], row["size"], row["sha256"]] for row in actual_members],
    )
    checks.need(
        isinstance(seal, dict)
        and seal.get("members") == actual_members
        and seal.get("member_count") == len(actual_members)
        and seal.get("member_set_sha256") == actual_digest,
        "run_seal_members",
        str(seal_path),
        {
            "member_count": len(actual_members),
            "member_set_sha256": actual_digest,
            "members": actual_members,
        },
        seal,
    )
    checks.need(
        seal_path.read_bytes() == seal_before,
        "run_seal_changed",
        str(seal_path),
        hashlib.sha256(seal_before).hexdigest(),
        _sha256(seal_path),
    )


def validate_external_evidence(
    root: Path,
    registry: dict[str, Any],
    evidence_root: Path,
    run_index_relative: str,
) -> Checks:
    checks = Checks("evidence")
    root = root.resolve()
    try:
        allowed, evidence_resolved = _evidence_path_allowed(root, evidence_root)
        valid_root = bool(
            allowed
            and evidence_resolved is not None
            and evidence_root.is_dir()
        )
    except OSError as error:
        checks.need(
            False,
            "evidence_root",
            str(evidence_root),
            "external or Git-ignored directory",
            str(error),
        )
        return checks
    checks.need(
        valid_root,
        "evidence_root",
        str(evidence_root),
        "symlink-free directory outside source root or Git-ignored within it",
        str(evidence_resolved),
    )
    if not valid_root or evidence_resolved is None:
        return checks
    source_before = _source_inventory_without_evidence(root, evidence_resolved)
    index_path = _plain_file_under(evidence_resolved, run_index_relative)
    if index_path is None:
        checks.need(False, "run_index_path", run_index_relative, "plain external file", "invalid")
        return checks
    run_directory = index_path.parent
    index_before = index_path.read_bytes()
    sidecar = index_path.with_name(f"{index_path.name}.sha256")
    sidecar_valid = sidecar.is_file() and not sidecar.is_symlink()
    expected_sidecar = f"{hashlib.sha256(index_before).hexdigest()}  {index_path.name}\n"
    checks.need(
        sidecar_valid and sidecar.read_text(encoding="utf-8") == expected_sidecar,
        "run_index_sidecar",
        str(sidecar),
        expected_sidecar,
        sidecar.read_text(encoding="utf-8", errors="replace") if sidecar_valid else "missing",
    )
    try:
        index = _load_json(index_path)
        schemas, schema_registry = _schema_registry(root)
    except (OSError, UnicodeError, ValueError) as error:
        checks.need(False, "run_index_json", str(index_path), "valid closed JSON", str(error))
        return checks
    _validate_schema(index, schemas[RUN_INDEX_SCHEMA], schema_registry, checks, str(index_path))
    if not isinstance(index, dict):
        return checks
    checks.need(
        index.get("run_id") == run_directory.name,
        "run_directory_binding",
        str(index_path),
        run_directory.name,
        index.get("run_id"),
    )
    checks.need(
        index.get("scenario_sets") == registry.get("scenario_sets"),
        "run_index_scenario_sets",
        str(index_path),
        registry.get("scenario_sets"),
        index.get("scenario_sets"),
    )
    common = _expected_common_bindings(root, registry, evidence_resolved, checks)
    _git_clean_binding(root, common.get("source_commit"), checks)
    _validate_extraction_receipt(root, schemas, schema_registry, common, checks)
    checks.need(
        index.get("bindings") == common,
        "run_index_bindings",
        str(index_path),
        common,
        index.get("bindings"),
    )
    scenario_rows = _mapping_rows(registry, EFFECTIVE_REGISTRY, checks)
    entries = index.get("receipts", [])
    entry_map: dict[str, dict[str, Any]] = {}
    if isinstance(entries, list):
        for position, entry in enumerate(entries):
            scenario_id = entry.get("scenario_id") if isinstance(entry, dict) else None
            if not isinstance(entry, dict) or not isinstance(scenario_id, str):
                checks.need(False, "run_index_entry", f"{index_path}#{position}", "mapping", entry)
                continue
            checks.need(scenario_id not in entry_map, "duplicate_run_index_entry", str(index_path), "unique", scenario_id)
            entry_map[scenario_id] = entry
    checks.same(set(scenario_rows), set(entry_map), "run_index_scenario_set", str(index_path))
    aggregate_rows: list[list[object]] = []
    for scenario_id, entry in sorted(entry_map.items()):
        receipt_path = _plain_file_under(run_directory, entry.get("path"))
        actual_size = receipt_path.stat().st_size if receipt_path is not None else None
        actual_sha = _sha256(receipt_path) if receipt_path is not None else None
        checks.need(
            receipt_path is not None
            and entry.get("size") == actual_size
            and entry.get("sha256") == actual_sha
            and entry.get("origin") == scenario_rows.get(scenario_id, {}).get("origin"),
            "scenario_receipt_file",
            scenario_id,
            {"size": actual_size, "sha256": actual_sha},
            entry,
        )
        aggregate_rows.append(
            [scenario_id, entry.get("origin"), entry.get("path"), entry.get("sha256"), entry.get("size")]
        )
        if receipt_path is None:
            continue
        try:
            receipt = _load_json(receipt_path)
        except (OSError, UnicodeError, ValueError) as error:
            checks.need(False, "scenario_receipt_json", str(receipt_path), "valid JSON", str(error))
            continue
        scenario = scenario_rows.get(scenario_id)
        if scenario is not None:
            _validate_scenario_receipt(
                root,
                run_directory,
                receipt,
                scenario,
                registry,
                common,
                schemas,
                schema_registry,
                checks,
                str(receipt_path),
            )
    expected_aggregate = canonical_sha256(RUN_AGGREGATE_DOMAIN, aggregate_rows)
    checks.need(
        index.get("aggregate_sha256") == expected_aggregate,
        "run_index_aggregate",
        str(index_path),
        expected_aggregate,
        index.get("aggregate_sha256"),
    )
    _validate_run_seal(run_directory, index_path, checks)
    checks.need(
        index_path.read_bytes() == index_before,
        "evidence_changed_during_validation",
        str(index_path),
        hashlib.sha256(index_before).hexdigest(),
        _sha256(index_path),
    )
    try:
        source_after = _source_inventory_without_evidence(root, evidence_resolved)
        checks.need(
            source_after == source_before,
            "source_changed_during_validation",
            str(root),
            source_tree_digest(source_before),
            source_tree_digest(source_after),
        )
    except Exception as error:
        checks.need(False, "source_changed_during_validation", str(root), "stable", str(error))
    return checks


def _payload(mode: str, checks: list[Checks]) -> dict[str, object]:
    problems = [asdict(problem) for group in checks for problem in group.problems]
    return {
        "schema_version": 1,
        "mode": mode,
        "result": "PASS" if not problems else "FAIL",
        "problem_count": len(problems),
        "problems": problems,
    }


def validate(root: Path, mode: str) -> dict[str, object]:
    """Compatibility entrypoint used by the authority-lock and Make gates."""
    root = root.resolve()
    structural, registry = validate_static(root)
    source = Checks("source")
    evidence = Checks("evidence")
    if mode == "release" and not structural.problems:
        source = validate_sources(root, registry)
        if not source.problems:
            evidence_root = os.environ.get("GURINNAE_EVIDENCE_ROOT")
            run_index = os.environ.get("GURINNAE_ACCEPTANCE_RUN_INDEX")
            if evidence_root and run_index:
                evidence = validate_external_evidence(
                    root,
                    registry,
                    Path(evidence_root),
                    run_index,
                )
            else:
                evidence.need(
                    False,
                    "missing_evidence_arguments",
                    "GURINNAE_EVIDENCE_ROOT/GURINNAE_ACCEPTANCE_RUN_INDEX",
                    "external evidence root and relative run index",
                    {"evidence_root": evidence_root, "run_index": run_index},
                )
    structure_problems = structural.problems
    release_problems = [*source.problems, *evidence.problems]
    counts = registry.get("counts", {}) if isinstance(registry, dict) else {}
    structure_status = "PASS" if not structure_problems else "FAIL"
    release_status = (
        "NOT_RUN"
        if mode == "structure"
        else "PASS"
        if structure_status == "PASS" and not release_problems
        else "FAIL"
    )
    return {
        "schema_version": 3,
        "mode": mode,
        "structure_mapping": structure_status,
        "release_gate": release_status,
        "counts": {
            "base_features_locked": counts.get("base_features", 0),
            "base_scenarios_locked": counts.get("base_scenarios", 0),
            "supplemental_features_discovered": counts.get("supplemental_features", 0),
            "supplemental_scenarios_discovered": counts.get("supplemental_scenarios", 0),
            "supplemental_scenarios_mapped": counts.get("supplemental_scenarios", 0),
            "effective_features": counts.get("effective_features", 0),
            "effective_scenarios": counts.get("effective_scenarios", 0),
            "gherkin_clauses": counts.get("gherkin_clauses", 0),
            "gherkin_examples": counts.get("gherkin_examples", 0),
            "gherkin_clause_instances": counts.get("gherkin_clause_instances", 0),
        },
        "structure_problem_count": len(structure_problems),
        "release_problem_count": len(release_problems),
        "structure_problems": [asdict(problem) for problem in structure_problems],
        "release_problems": [asdict(problem) for problem in release_problems],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--mode", choices=("contract", "source", "evidence"))
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--evidence-root", type=Path)
    parser.add_argument("--run-index")
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--max-problems", type=int, default=100)
    args = parser.parse_args()
    if args.self_test:
        from validation.effective_acceptance_self_test import self_test

        passed, fixtures = self_test()
        print(
            json.dumps(
                {
                    "schema_version": 1,
                    "result": "PASS" if passed else "FAIL",
                    "fixture_count": len(fixtures),
                    "fixtures": fixtures,
                },
                ensure_ascii=False,
                sort_keys=True,
                indent=2,
            )
        )
        print(f"EFFECTIVE_ACCEPTANCE_SELF_TEST: {'PASS' if passed else 'FAIL'}")
        return 0 if passed else 1
    if args.mode is None:
        parser.error("--mode is required unless --self-test is used")
    root = args.root.resolve()
    structural, registry = validate_static(root)
    groups = [structural]
    if args.mode in {"source", "evidence"} and not structural.problems:
        groups.append(validate_sources(root, registry))
    if args.mode == "evidence" and not any(group.problems for group in groups):
        if args.evidence_root is None or args.run_index is None:
            missing = Checks("evidence")
            missing.need(False, "missing_evidence_arguments", "CLI", "--evidence-root and --run-index", None)
            groups.append(missing)
        else:
            groups.append(
                validate_external_evidence(
                    root,
                    registry,
                    args.evidence_root,
                    args.run_index,
                )
            )
    payload = _payload(args.mode, groups)
    rendered = json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    if args.json_output is not None:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(rendered, encoding="utf-8")
    limited = dict(payload)
    limited["problems"] = payload["problems"][: max(0, args.max_problems)]
    print(json.dumps(limited, ensure_ascii=False, sort_keys=True, indent=2))
    print(f"EFFECTIVE_ACCEPTANCE_{args.mode.upper()}: {payload['result']}")
    return 0 if payload["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
