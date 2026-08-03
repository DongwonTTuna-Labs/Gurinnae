from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from .acceptance_base_authority import (
    validate_frozen_base_feature,
    validate_frozen_base_lock,
    validate_frozen_base_registry,
)
from .effective_acceptance import validate_sources, validate_static
from .loaders import load_yaml
from .models import Validation


ID_RE = re.compile(r"^# scenario-id: ([A-Z0-9_-]+)$")
SCENARIO_RE = re.compile(r"^\s*Scenario(?: Outline)?:\s*(.+)$")
FORBIDDEN_FEATURE_CONTROL_RE = re.compile(
    r"(?im)^\s*[^\n]*(?:@skip|@skipped|@ignore|@disabled|@pending|@wip|@todo|@focus|@focused|@only)\b"
)
ZERO_TEST_COMMAND_RE = re.compile(
    r"(?:^|\s)(?:--list|--collect-only|--dry-run|--passWithNoTests|--allow-no-tests)(?:\s|$)"
)
BASE_LOCK = "base-v13.lock.yaml"
BASE_CATALOG = "acceptance-catalog.yaml"
BASE_MAPPING = "executable-mapping.yaml"


def _load_mapping(path: Path, label: str, result: Validation) -> dict[str, Any]:
    try:
        value = load_yaml(path)
    except (OSError, UnicodeError, ValueError) as error:
        result.error(f"{label} is not valid unique-key YAML: {error}")
        return {}
    if not isinstance(value, dict):
        result.error(f"{label} must be a YAML mapping")
        return {}
    return value


def _non_negative_count(value: object, label: str, result: Validation) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        result.error(f"{label} must be a non-negative integer")
        return None
    return value


def _base_inventory(
    root: Path, directory: Path, lock: dict[str, Any], result: Validation
) -> tuple[list[str], int | None]:
    declared_features = _non_negative_count(
        lock.get("feature_count"), f"{BASE_LOCK}: feature_count", result
    )
    declared_scenarios = _non_negative_count(
        lock.get("scenario_count"), f"{BASE_LOCK}: scenario_count", result
    )
    raw_features = lock.get("features")
    if not isinstance(raw_features, list):
        result.error(f"{BASE_LOCK}: features must be a list")
        raw_features = []

    names: list[str] = []
    for index, row in enumerate(raw_features):
        if not isinstance(row, dict):
            result.error(f"{BASE_LOCK}: feature entry {index} must be a mapping")
            continue
        name = row.get("path")
        safe_name = (
            isinstance(name, str)
            and bool(name)
            and "\\" not in name
            and Path(name).name == name
            and Path(name).suffix == ".feature"
        )
        result.require(safe_name, f"{BASE_LOCK}: feature entry {index} has an unsafe path")
        if not safe_name:
            continue
        names.append(name)

        path = directory / name
        regular_file = path.is_file() and not path.is_symlink()
        result.require(regular_file, f"{name}: locked base feature is missing or not a regular file")
        if not regular_file:
            continue
        expected_digest = row.get("sha256")
        expected_size = row.get("size")
        validate_frozen_base_feature(
            root, name, expected_digest, expected_size, result
        )

    result.require(len(names) == len(set(names)), f"{BASE_LOCK}: duplicate base feature paths")
    if declared_features is not None:
        result.require(
            len(names) == declared_features,
            f"{BASE_LOCK}: feature inventory count mismatch {len(names)}",
        )

    for key, expected_name in (
        ("catalog", BASE_CATALOG),
        ("executable_mapping", BASE_MAPPING),
    ):
        descriptor = lock.get(key)
        expected_digest = descriptor.get("sha256") if isinstance(descriptor, dict) else None
        path = directory / expected_name
        regular_file = path.is_file() and not path.is_symlink()
        result.require(
            isinstance(descriptor, dict) and descriptor.get("path") == expected_name,
            f"{BASE_LOCK}: {key} descriptor differs",
        )
        result.require(regular_file, f"{expected_name}: locked base registry is missing")
        if regular_file:
            validate_frozen_base_registry(
                root, expected_name, expected_digest, result
            )

    return names, declared_scenarios


def _catalog_inventory(catalog: dict[str, Any], result: Validation) -> set[str]:
    raw_features = catalog.get("features")
    if not isinstance(raw_features, list):
        result.error(f"{BASE_CATALOG}: features must be a list")
        return set()
    names: list[str] = []
    for index, row in enumerate(raw_features):
        name = row.get("file") if isinstance(row, dict) else None
        if not isinstance(name, str) or not name:
            result.error(f"{BASE_CATALOG}: feature entry {index} has no file")
            continue
        names.append(name)
    result.require(len(names) == len(set(names)), f"{BASE_CATALOG}: duplicate feature files")
    return set(names)


def _parse_base_features(
    directory: Path, base_names: list[str], result: Validation
) -> tuple[list[Path], list[tuple[str, str, str]]]:
    paths = [directory / name for name in base_names if (directory / name).is_file()]
    result.require(
        {path.name for path in paths} == set(base_names),
        "base feature files do not exactly match the locked inventory",
    )
    scenarios: list[tuple[str, str, str]] = []
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            result.error(f"{path.name}: cannot read locked feature: {error}")
            continue
        lines = text.splitlines()
        first = next((line for line in lines if line.strip()), "")
        result.require("@final" in first, f"{path.name}: missing @final")
        result.require(
            FORBIDDEN_FEATURE_CONTROL_RE.search(text) is None,
            f"{path.name}: skipped/focused acceptance feature is forbidden",
        )
        pending: str | None = None
        for line in lines:
            if match := ID_RE.match(line.strip()):
                result.require(pending is None, f"{path.name}: orphan scenario ID {pending}")
                pending = match.group(1)
                continue
            if match := SCENARIO_RE.match(line):
                title = match.group(1).strip()
                result.require(
                    pending is not None,
                    f"{path.name}:{title} missing stable scenario ID",
                )
                if pending is not None:
                    scenarios.append((pending, path.name, title))
                pending = None
        result.require(pending is None, f"{path.name}: orphan scenario ID {pending}")

    scenario_ids = [row[0] for row in scenarios]
    result.require(
        len(scenario_ids) == len(set(scenario_ids)),
        "duplicate base acceptance scenario IDs",
    )
    return paths, scenarios


def _base_mapping(
    mapping: dict[str, Any],
    scenarios: list[tuple[str, str, str]],
    base_names: set[str],
    declared_scenarios: int | None,
    result: Validation,
) -> dict[str, dict[str, Any]]:
    raw_rows = mapping.get("scenarios")
    if not isinstance(raw_rows, list):
        result.error(f"{BASE_MAPPING}: scenarios must be a list")
        raw_rows = []
    mapped: dict[str, dict[str, Any]] = {}
    for index, row in enumerate(raw_rows):
        if not isinstance(row, dict):
            result.error(f"{BASE_MAPPING}: scenario entry {index} must be a mapping")
            continue
        scenario_id = row.get("scenario_id")
        if not isinstance(scenario_id, str) or not scenario_id:
            result.error(f"{BASE_MAPPING}: scenario entry {index} has no scenario_id")
            continue
        if scenario_id in mapped:
            result.error(f"{BASE_MAPPING}: duplicate scenario ID {scenario_id}")
            continue
        mapped[scenario_id] = row

    source_ids = {row[0] for row in scenarios}
    result.require(set(mapped) == source_ids, "base executable mapping does not match base scenarios")
    mapped_features = {
        feature_file
        for row in mapped.values()
        if isinstance((feature_file := row.get("feature_file")), str)
    }
    expected_features = {f"tests/acceptance/{name}" for name in base_names}
    result.require(
        mapped_features == expected_features,
        "base executable mapping feature inventory differs from the base lock",
    )

    source_count = len(scenarios)
    catalog_count = mapping.get("scenario_count")
    result.require(
        catalog_count == source_count,
        f"{BASE_MAPPING}: scenario_count differs from source {source_count}",
    )
    result.require(
        len(raw_rows) == source_count and len(mapped) == source_count,
        f"{BASE_MAPPING}: scenario row count differs from source {source_count}",
    )
    if declared_scenarios is not None:
        result.require(
            source_count == declared_scenarios,
            f"base scenario inventory differs from {BASE_LOCK}: {source_count}",
        )

    for scenario_id, file_name, title in scenarios:
        item = mapped.get(scenario_id)
        if item is None:
            continue
        result.require(
            item.get("feature_file") == f"tests/acceptance/{file_name}"
            and item.get("scenario_title") == title,
            f"{scenario_id}: mapping identity mismatch",
        )
        result.require(
            item.get("skip_policy") == "FORBIDDEN",
            f"{scenario_id}: skip must be forbidden",
        )
        for key in (
            "implementation_test_path",
            "command",
            "environment",
            "required_evidence",
        ):
            result.require(bool(item.get(key)), f"{scenario_id}: missing {key}")
        command = item.get("command")
        result.require(
            isinstance(command, str) and ZERO_TEST_COMMAND_RE.search(command) is None,
            f"{scenario_id}: zero-test command is forbidden",
        )
    return mapped


def _supplemental_structure(root: Path, result: Validation) -> dict[str, int]:
    try:
        structural, registry = validate_static(root)
    except Exception as error:
        result.error(
            "effective acceptance contract validation failed closed: "
            f"{type(error).__name__}: {error}"
        )
        return {}
    for problem in structural.problems:
        result.error(
            "effective acceptance contract failure: "
            + json.dumps(
                {
                    "phase": problem.phase,
                    "code": problem.code,
                    "source": problem.source,
                    "expected": problem.expected,
                    "actual": problem.actual,
                },
                ensure_ascii=False,
                sort_keys=True,
                default=str,
            )
        )
    if structural.problems:
        return {}
    source_checks = validate_sources(root, registry)
    for problem in source_checks.problems:
        result.error(
            "effective acceptance source failure: "
            + json.dumps(
                {
                    "phase": problem.phase,
                    "code": problem.code,
                    "source": problem.source,
                    "expected": problem.expected,
                    "actual": problem.actual,
                },
                ensure_ascii=False,
                sort_keys=True,
                default=str,
            )
        )
    if source_checks.problems:
        return {}
    raw_counts = registry.get("counts")
    if not isinstance(raw_counts, dict):
        result.error("effective acceptance source-derived counts are missing")
        return {}
    aliases = {
        "base_features_locked": "base_features",
        "base_scenarios_locked": "base_scenarios",
        "supplemental_features_discovered": "supplemental_features",
        "supplemental_scenarios_discovered": "supplemental_scenarios",
        "supplemental_scenarios_mapped": "supplemental_scenarios",
        "effective_features": "effective_features",
        "effective_scenarios": "effective_scenarios",
    }
    counts: dict[str, int] = {}
    for key, source_key in aliases.items():
        count = _non_negative_count(
            raw_counts.get(source_key), f"effective acceptance count {source_key}", result
        )
        if count is not None:
            counts[key] = count
    return counts


def validate(root: Path, result: Validation) -> None:
    directory = root / "tests/acceptance"
    lock_path = directory / BASE_LOCK
    lock = _load_mapping(lock_path, BASE_LOCK, result)
    validate_frozen_base_lock(root, lock_path, BASE_LOCK, result)
    catalog = _load_mapping(directory / BASE_CATALOG, BASE_CATALOG, result)
    mapping = _load_mapping(directory / BASE_MAPPING, BASE_MAPPING, result)

    base_names, declared_scenarios = _base_inventory(root, directory, lock, result)
    catalog_names = _catalog_inventory(catalog, result)
    result.require(
        catalog_names == set(base_names),
        "base acceptance catalog differs from the locked feature inventory",
    )
    paths, scenarios = _parse_base_features(directory, base_names, result)
    result.require(
        catalog.get("scenario_count") == len(scenarios),
        f"{BASE_CATALOG}: scenario_count differs from source {len(scenarios)}",
    )
    mapped = _base_mapping(
        mapping, scenarios, set(base_names), declared_scenarios, result
    )

    supplemental = _supplemental_structure(root, result)
    result.require(
        supplemental.get("base_features_locked") == len(paths),
        "supplemental validator base feature count differs from source",
    )
    result.require(
        supplemental.get("base_scenarios_locked") == len(scenarios),
        "supplemental validator base scenario count differs from source",
    )
    supplemental_features = supplemental.get("supplemental_features_discovered", 0)
    supplemental_scenarios = supplemental.get("supplemental_scenarios_discovered", 0)
    supplemental_mapped = supplemental.get("supplemental_scenarios_mapped", 0)
    effective_features = len(paths) + supplemental_features
    effective_scenarios = len(scenarios) + supplemental_scenarios
    result.require(
        supplemental.get("effective_features") == effective_features,
        "supplemental validator effective feature count differs from source",
    )
    result.require(
        supplemental.get("effective_scenarios") == effective_scenarios,
        "supplemental validator effective scenario count differs from source",
    )
    result.stats.update(
        {
            "base_acceptance_features": len(paths),
            "base_acceptance_scenarios": len(scenarios),
            "supplemental_acceptance_features": supplemental_features,
            "supplemental_acceptance_scenarios": supplemental_scenarios,
            "acceptance_features": effective_features,
            "acceptance_scenarios": effective_scenarios,
            "acceptance_executable_mappings": len(mapped) + supplemental_mapped,
        }
    )
