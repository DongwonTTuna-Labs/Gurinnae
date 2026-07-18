"""Conflict overlays and executable mapping validation."""
from __future__ import annotations

from dataclasses import asdict
from pathlib import Path
from typing import Any
import re
import shlex

from .supplemental_acceptance_core import (
    BASE_LOCK,
    CONFLICT_ID_RE,
    MAPPING_KEYS,
    OVERLAYS,
    POLICY,
    ROW_KEYS,
    SUPPLEMENTAL_MAPPING,
    ZERO_COMMAND,
    BaseInventory,
    Checks,
    Scenario,
    load,
    row_map,
    safe_path,
)
from .supplemental_acceptance_profiles import validate_journey_profile

def validate_overlays(
    root: Path,
    base: BaseInventory,
    supplemental_ids: set[str],
    checks: Checks,
) -> int:
    document = load(root, OVERLAYS, checks)
    expected_keys = {
        "schema_version",
        "specification_version",
        "status",
        "base_lock",
        "rules",
        "overlays",
    }
    checks.need(
        set(document) == expected_keys,
        "overlay_schema",
        OVERLAYS,
        sorted(expected_keys),
        sorted(str(key) for key in document),
    )
    checks.need(
        document.get("schema_version") == 1
        and document.get("status") == "FINAL"
        and document.get("base_lock") == BASE_LOCK,
        "overlay_contract",
        OVERLAYS,
        {"schema_version": 1, "status": "FINAL", "base_lock": BASE_LOCK},
        {
            "schema_version": document.get("schema_version"),
            "status": document.get("status"),
            "base_lock": document.get("base_lock"),
        },
    )
    rules = document.get("rules")
    rule_set = checks.unique(rules if isinstance(rules, list) else [], "overlay rules")
    checks.need(
        isinstance(rules, list) and len(rule_set) == len(rules) > 0,
        "overlay_rules",
        OVERLAYS,
        "unique nonempty rules",
        rules,
    )
    rows = document.get("overlays")
    mapped = row_map(rows, "scenario_id", f"{OVERLAYS}#overlays", checks)
    base_ids = {row.scenario_id for row in base.scenarios}
    checks.need(
        set(mapped) <= base_ids,
        "overlay_target",
        OVERLAYS,
        "base scenario IDs only",
        sorted(set(mapped) - base_ids),
    )
    checks.need(
        not (set(mapped) & supplemental_ids),
        "overlay_supplemental_collision",
        OVERLAYS,
        [],
        sorted(set(mapped) & supplemental_ids),
    )
    for scenario_id, row in mapped.items():
        where = f"{OVERLAYS}#{scenario_id}"
        checks.need(
            set(row)
            == {
                "scenario_id",
                "conflict_id",
                "superseded_assertion",
                "effective_oracle",
            },
            "overlay_row_schema",
            where,
            [
                "conflict_id",
                "effective_oracle",
                "scenario_id",
                "superseded_assertion",
            ],
            sorted(str(key) for key in row),
        )
        conflict_id = row.get("conflict_id")
        checks.need(
            isinstance(conflict_id, str)
            and CONFLICT_ID_RE.fullmatch(conflict_id) is not None,
            "overlay_conflict_id",
            where,
            "SPEC-CONFLICT-NNN",
            conflict_id,
        )
        checks.need(
            isinstance(row.get("superseded_assertion"), str)
            and bool(row.get("superseded_assertion", "").strip()),
            "overlay_superseded_assertion",
            where,
            "nonempty string",
            row.get("superseded_assertion"),
        )
        checks.need(
            isinstance(row.get("effective_oracle"), dict)
            and bool(row.get("effective_oracle")),
            "overlay_oracle",
            where,
            "nonempty closed mapping",
            row.get("effective_oracle"),
        )
    return len(mapped)


def command_is_scoped(command: object, test_id: object) -> bool:
    if not isinstance(command, str) or not isinstance(test_id, str):
        return False
    if not command.strip() or test_id not in command or ZERO_COMMAND.search(command):
        return False
    if re.search(r"[\n;&|><\x60$]", command):
        return False
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        return False
    return bool(tokens) and test_id in tokens


def validate_mapping(
    root: Path,
    paths: list[str],
    scenarios: list[Scenario],
    checks: Checks,
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    mapping = load(root, SUPPLEMENTAL_MAPPING, checks)
    checks.need(
        set(mapping) == MAPPING_KEYS,
        "mapping_schema",
        SUPPLEMENTAL_MAPPING,
        sorted(MAPPING_KEYS),
        sorted(str(key) for key in mapping),
    )
    expected_head = {
        "schema_version": 1,
        "specification_version": "13.0.0",
        "status": "FINAL",
        "registry_kind": "SUPPLEMENTAL_EXECUTABLE_MAPPING",
        "source_derived": True,
        "base_acceptance_lock": BASE_LOCK,
    }
    for key, expected in expected_head.items():
        checks.need(
            mapping.get(key) == expected,
            "mapping_contract",
            f"{SUPPLEMENTAL_MAPPING}#{key}",
            expected,
            mapping.get(key),
        )

    source = {row.scenario_id: row for row in scenarios}
    mapped = row_map(
        mapping.get("scenarios"),
        "scenario_id",
        f"{SUPPLEMENTAL_MAPPING}#scenarios",
        checks,
    )
    checks.same(
        set(source),
        set(mapped),
        "supplemental feature/mapping identity",
        ("features", "mapping"),
    )
    checks.need(
        mapping.get("feature_count") == len(paths),
        "declared_count",
        f"{SUPPLEMENTAL_MAPPING}#feature_count",
        len(paths),
        mapping.get("feature_count"),
    )
    checks.need(
        mapping.get("scenario_count") == len(scenarios),
        "declared_count",
        f"{SUPPLEMENTAL_MAPPING}#scenario_count",
        len(scenarios),
        mapping.get("scenario_count"),
    )

    feature_counts = {
        path: sum(row.feature_file == path for row in scenarios) for path in paths
    }
    mapped_features = row_map(
        mapping.get("features"),
        "path",
        f"{SUPPLEMENTAL_MAPPING}#features",
        checks,
    )
    checks.same(
        set(feature_counts),
        set(mapped_features),
        "supplemental feature inventory",
        ("source", "mapping"),
    )
    for path, count in feature_counts.items():
        row = mapped_features.get(path)
        checks.need(
            isinstance(row, dict)
            and set(row) == {"path", "scenario_count"}
            and row.get("scenario_count") == count,
            "feature_catalog_identity",
            path,
            {"path": path, "scenario_count": count},
            row,
        )

    statuses = {"MISSING": 0, "IMPLEMENTED": 0}
    receipt_ids: list[object] = []
    assertion_ids: list[object] = []
    for scenario_id, row in mapped.items():
        where = f"{SUPPLEMENTAL_MAPPING}#{scenario_id}"
        expected = source.get(scenario_id)
        checks.need(
            set(row) == ROW_KEYS,
            "mapping_row_schema",
            where,
            sorted(ROW_KEYS),
            sorted(str(key) for key in row),
        )
        if expected is not None:
            checks.need(
                (
                    row.get("feature_file"),
                    row.get("scenario_title"),
                )
                == (expected.feature_file, expected.scenario_title),
                "mapping_identity",
                where,
                asdict(expected),
                {
                    "feature_file": row.get("feature_file"),
                    "scenario_title": row.get("scenario_title"),
                },
            )
        checks.need(
            row.get("skip_policy") == "FORBIDDEN",
            "skip_policy",
            where,
            "FORBIDDEN",
            row.get("skip_policy"),
        )
        status = row.get("implementation_status")
        checks.need(
            status in statuses,
            "implementation_status",
            where,
            sorted(statuses),
            status,
        )
        if isinstance(status, str) and status in statuses:
            statuses[status] += 1

        test_path = row.get("implementation_test_path")
        test_id = row.get("implementation_test_id")
        stable_test_id = scenario_id.lower().replace("-", "_")
        checks.need(
            safe_path(test_path) and str(test_path).startswith("tests/"),
            "unsafe_test_path",
            where,
            "safe tests/ path",
            test_path,
        )
        checks.need(
            test_id == stable_test_id,
            "unstable_test_id",
            where,
            stable_test_id,
            test_id,
        )
        checks.need(
            command_is_scoped(row.get("command"), test_id),
            "test_command",
            where,
            "single scoped executing command without zero-test flags",
            row.get("command"),
        )

        layers = row.get("runtime_layers")
        layer_set = checks.unique(
            layers if isinstance(layers, list) else [],
            f"{where} runtime layers",
        )
        checks.need(
            isinstance(layers, list) and len(layer_set) == len(layers) > 0,
            "runtime_layers",
            where,
            "unique nonempty list",
            layers,
        )
        for key, prefix in (
            ("discovery_receipt_id", "SAD-"),
            ("execution_receipt_id", "SAE-"),
            ("assertion_contract_id", "SAA-"),
        ):
            checks.need(
                row.get(key) == prefix + scenario_id,
                "stable_contract_id",
                f"{where}.{key}",
                prefix + scenario_id,
                row.get(key),
            )
        receipt_ids.extend(
            [row.get("discovery_receipt_id"), row.get("execution_receipt_id")]
        )
        assertion_ids.append(row.get("assertion_contract_id"))

    checks.unique(receipt_ids, "mapping receipt IDs")
    checks.unique(assertion_ids, "mapping assertion IDs")
    checks.need(
        mapping.get("implementation_status_counts") == statuses,
        "declared_count",
        "supplemental implementation statuses",
        statuses,
        mapping.get("implementation_status_counts"),
    )
    checks.need(
        mapping.get("release_policy") == POLICY,
        "release_policy",
        SUPPLEMENTAL_MAPPING,
        POLICY,
        mapping.get("release_policy"),
    )
    validate_journey_profile(scenarios, mapped, checks)
    return mapped, mapping


