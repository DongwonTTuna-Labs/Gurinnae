#!/usr/bin/env python3
"""Validate the byte-locked v13 acceptance base and additive acceptance gates."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shlex
import sys
import tempfile
from collections import Counter
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable

import yaml

ROOT = Path(__file__).resolve().parents[2]
BASE_LOCK = "tests/acceptance/base-v13.lock.yaml"
BASE_CATALOG = "tests/acceptance/acceptance-catalog.yaml"
BASE_MAPPING = "tests/acceptance/executable-mapping.yaml"
SUPPLEMENTAL_MAPPING = "tests/acceptance/supplemental-executable-mapping.yaml"
OVERLAYS = "tests/acceptance/conflict-resolution-overlays.yaml"
REGISTRY = "implementation-evidence/supplemental-acceptance-registry.yaml"

AUTHORITY_BASE_FEATURE_COUNT = 35
AUTHORITY_BASE_SCENARIO_COUNT = 271

ID_RE = re.compile(r"^AC-[A-Z0-9_]+(?:-[A-Z0-9_]+)*-[0-9]{3}$")
ID_LINE = re.compile(r"^\s*#\s*scenario-id:\s*(\S+)\s*$")
SCENARIO_LINE = re.compile(r"^\s*Scenario(?: Outline)?:\s*(.+?)\s*$")
CONFLICT_ID_RE = re.compile(r"^SPEC-CONFLICT-[0-9]{3}$")
SOURCE_SKIP = re.compile(
    r"(?im)(?:"
    r"\b(?:test|it|describe)\.(?:skip|fixme|todo)\s*\("
    r"|#\s*\[ignore(?:\([^]]*\))?\]"
    r"|pytest\.mark\.(?:skip|skipif)\b"
    r"|unittest\.(?:skip|skipIf|skipUnless)\s*\("
    r"|@(?:Ignore|Disabled)\b"
    r")"
)
SOURCE_FOCUS = re.compile(
    r"(?im)(?:\b(?:test|it|describe)\.only\s*\(|@focus\b|@focused\b)"
)
ZERO_COMMAND = re.compile(
    r"(?:^|\s)(?:"
    r"--list|--collect-only|--dry-run|--no-run|"
    r"--passwithnotests|--allow-no-tests"
    r")(?:\s|$)",
    re.IGNORECASE,
)
ASSERTION = re.compile(
    r"(?m)(?:"
    r"\bassert(?:_eq|_ne|_matches)?!\s*\("
    r"|\bdebug_assert(?:_eq|_ne)?!\s*\("
    r"|\bexpect\s*\("
    r"|\bassert\.(?:equal|deepEqual|strictEqual|ok|match|throws)\s*\("
    r"|\b(?:assert|expect)\s+[^\n]+"
    r"|\bassert_[a-z_]+\s*\("
    r")"
)
TRIVIAL_ASSERTION = re.compile(
    r"(?i)(?:assert!\s*\(\s*true\s*\)|expect\s*\(\s*true\s*\))"
)
ISO_TIME = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:[0-9:.]+(?:Z|[+-]\d{2}:\d{2})$"
)
SHA256 = re.compile(r"^[0-9a-f]{64}$")

MAPPING_KEYS = frozenset(
    {
        "schema_version",
        "specification_version",
        "status",
        "registry_kind",
        "source_derived",
        "base_acceptance_lock",
        "feature_count",
        "scenario_count",
        "implementation_status_counts",
        "features",
        "release_policy",
        "scenarios",
    }
)
ROW_KEYS = frozenset(
    {
        "scenario_id",
        "feature_file",
        "scenario_title",
        "skip_policy",
        "implementation_status",
        "implementation_test_path",
        "implementation_test_id",
        "command",
        "runtime_layers",
        "discovery_receipt_id",
        "execution_receipt_id",
        "assertion_contract_id",
    }
)
RECEIPT_KEYS = frozenset(
    {
        "receipt_id",
        "scenario_id",
        "discovery_receipt_id",
        "assertion_contract_id",
        "status",
        "implementation_test_path",
        "implementation_test_id",
        "test_source_sha256",
        "command",
        "command_sha256",
        "runtime_layers",
        "exit_code",
        "selected_test_count",
        "pass_count",
        "failed_test_count",
        "skipped_test_count",
        "assertion_count",
        "assertion_mutations",
        "executed_at",
        "artifacts",
    }
)
POLICY = {
    "all_scenarios_required": True,
    "fixture_only_forbidden": True,
    "placeholder_forbidden": True,
    "skip_only_fixme_forbidden": True,
    "missing_implementation_is_release_failure": True,
    "missing_execution_receipt_is_release_failure": True,
}
ASSERTION_CONTRACT = {
    "contract_version": 2,
    "id_template": "SAA-{scenario_id}",
    "source_scope": "ALL_GIVEN_WHEN_THEN_AND_BUT_AND_EXAMPLES",
    "minimum_assertion_count": 1,
    "scenario_literal_required": True,
    "test_id_literal_required": True,
    "documentation_only_forbidden": True,
    "fixture_only_forbidden": True,
    "trivial_assertion_forbidden": True,
    "zero_assertion_forbidden": True,
    "runtime_reachability_mutation_required": True,
    "observed_macro_prefix": "::gurine_acceptance_testkit::observed_assert",
    "assertion_ordinal_set_equality": True,
}
EXECUTION_CONTRACT = {
    "contract_version": 2,
    "required_fields": sorted(RECEIPT_KEYS),
    "required_status": "PASSED",
    "required_exit_code": 0,
    "required_selected_test_count": 1,
    "required_pass_count": 1,
    "required_failed_test_count": 0,
    "required_skipped_test_count": 0,
    "minimum_assertion_count": 1,
    "runtime_layer_set_equality": True,
    "artifact_sha256_required": True,
    "skip_only_fixme_forbidden": True,
    "test_source_sha256_required": True,
    "command_sha256_required": True,
    "assertion_mutation_status": "SENTINEL_REACHED",
    "assertion_mutation_nonzero_exit_required": True,
    "assertion_mutation_set_equality": True,
    "assertion_mutation_log_sha256_required": True,
}


class UniqueLoader(yaml.SafeLoader):
    """YAML loader that rejects duplicate and unhashable mapping keys."""


def _mapping(
    loader: UniqueLoader,
    node: yaml.nodes.MappingNode,
    deep: bool = False,
) -> dict[Any, Any]:
    result: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in result
        except TypeError as error:
            raise ValueError(f"unhashable YAML key: {key!r}") from error
        if duplicate:
            raise ValueError(f"duplicate YAML key: {key!r}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)


@dataclass(frozen=True)
class Problem:
    phase: str
    code: str
    source: str
    expected: object
    actual: object


@dataclass(frozen=True)
class Scenario:
    scenario_id: str
    feature_file: str
    scenario_title: str


@dataclass(frozen=True)
class BaseInventory:
    feature_names: tuple[str, ...]
    scenarios: tuple[Scenario, ...]


class Checks:
    def __init__(self, phase: str) -> None:
        self.phase = phase
        self.problems: list[Problem] = []

    def need(
        self,
        ok: bool,
        code: str,
        source: str,
        expected: object,
        actual: object,
    ) -> None:
        if not ok:
            self.problems.append(Problem(self.phase, code, source, expected, actual))

    def unique(self, values: Iterable[object], source: str) -> set[str]:
        rows = list(values)
        valid = [
            value for value in rows if isinstance(value, str) and bool(value.strip())
        ]
        self.need(
            len(valid) == len(rows),
            "invalid_id",
            source,
            "nonempty strings",
            rows,
        )
        counts = Counter(valid)
        duplicates = sorted(value for value, count in counts.items() if count > 1)
        self.need(not duplicates, "duplicate_id", source, [], duplicates)
        return set(valid)

    def same(
        self,
        left: set[str],
        right: set[str],
        source: str,
        names: tuple[str, str],
    ) -> None:
        expected = {
            f"missing_from_{names[1]}": sorted(left - right),
            f"orphan_in_{names[1]}": sorted(right - left),
        }
        actual = {names[0]: len(left), names[1]: len(right)}
        self.need(left == right, "set_equality", source, expected, actual)


def load(root: Path, relative: str, checks: Checks) -> dict[str, Any]:
    path = root / relative
    if path.is_symlink() or not path.is_file():
        checks.need(False, "missing_registry", relative, "regular file", "missing")
        return {}
    try:
        value = yaml.load(path.read_text(encoding="utf-8"), Loader=UniqueLoader)
    except (OSError, UnicodeError, yaml.YAMLError, ValueError) as error:
        checks.need(
            False,
            "invalid_yaml",
            relative,
            "unique-key UTF-8 YAML",
            str(error),
        )
        return {}
    if not isinstance(value, dict):
        checks.need(
            False,
            "invalid_document",
            relative,
            "mapping",
            type(value).__name__,
        )
        return {}
    return value


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest_file(path: Path) -> str:
    return digest_bytes(path.read_bytes())


def canonical(value: object) -> str:
    encoded = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return digest_bytes(encoded)


def set_digest(values: set[str]) -> str:
    return digest_bytes("\n".join(sorted(values)).encode("utf-8"))


def ordered_digest(rows: Iterable[Scenario]) -> str:
    encoded = "\n".join(
        "\0".join((row.feature_file, row.scenario_id, row.scenario_title))
        for row in rows
    ).encode("utf-8")
    return digest_bytes(encoded)


def safe_path(value: object) -> bool:
    if not isinstance(value, str) or not value or "\\" in value:
        return False
    path = PurePosixPath(value)
    return (
        not path.is_absolute()
        and ".." not in path.parts
        and value == path.as_posix()
    )


def row_map(
    value: object,
    key: str,
    source: str,
    checks: Checks,
) -> dict[str, dict[str, Any]]:
    if not isinstance(value, list):
        checks.need(False, "invalid_rows", source, "list", type(value).__name__)
        return {}
    ids = checks.unique(
        (row.get(key) if isinstance(row, dict) else None for row in value),
        source,
    )
    result: dict[str, dict[str, Any]] = {}
    for row in value:
        if not isinstance(row, dict):
            continue
        value_id = row.get(key)
        if isinstance(value_id, str) and value_id in ids:
            result.setdefault(value_id, row)
    return result

