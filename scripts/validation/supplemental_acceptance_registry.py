"""Evidence registry, structural orchestration, and source segmentation."""
from __future__ import annotations

from pathlib import Path
from typing import Any
import re

from .supplemental_acceptance_core import (
    ASSERTION_CONTRACT,
    BASE_LOCK,
    EXECUTION_CONTRACT,
    RECEIPT_KEYS,
    REGISTRY,
    SUPPLEMENTAL_MAPPING,
    Checks,
    Scenario,
    load,
    ordered_digest,
    row_map,
    set_digest,
)
from .supplemental_acceptance_inventory import (
    _regular_digest,
    base_inventory,
    discover_supplemental,
)
from .supplemental_acceptance_mapping import validate_mapping, validate_overlays
from .supplemental_acceptance_source import executable_source, rust_function_end

def validate_registry(
    root: Path,
    paths: list[str],
    scenarios: list[Scenario],
    mapped: dict[str, dict[str, Any]],
    checks: Checks,
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    registry = load(root, REGISTRY, checks)
    top = {
        "schema_version",
        "specification_version",
        "status",
        "registry_kind",
        "source_derived",
        "mapping_file",
        "discovery_receipt",
        "assertion_contract",
        "execution_receipt_contract",
        "release_gate",
        "execution_receipts",
    }
    checks.need(
        set(registry) == top,
        "registry_schema",
        REGISTRY,
        sorted(top),
        sorted(str(key) for key in registry),
    )
    expected_registry = {
        "schema_version": 1,
        "specification_version": "13.0.0",
        "status": "FINAL",
        "registry_kind": "SUPPLEMENTAL_ACCEPTANCE_EVIDENCE",
        "source_derived": True,
        "mapping_file": SUPPLEMENTAL_MAPPING,
    }
    for key, expected in expected_registry.items():
        checks.need(
            registry.get(key) == expected,
            "registry_contract",
            f"{REGISTRY}#{key}",
            expected,
            registry.get(key),
        )

    discovery = (
        registry.get("discovery_receipt")
        if isinstance(registry.get("discovery_receipt"), dict)
        else {}
    )
    ids = set(mapped)
    expected_discovery = {
        "receipt_version": 1,
        "receipt_kind": "SUPPLEMENTAL_SCENARIO_DISCOVERY",
        "status": "COMPLETE",
        "base_lock_sha256": _regular_digest(root, BASE_LOCK),
        "mapping_sha256": _regular_digest(root, SUPPLEMENTAL_MAPPING),
        "feature_count": len(paths),
        "scenario_count": len(scenarios),
        "ordered_identity_sha256": ordered_digest(scenarios),
        "scenario_set_sha256": set_digest(ids),
    }
    for key, expected in expected_discovery.items():
        checks.need(
            discovery.get(key) == expected,
            "discovery_receipt",
            f"{REGISTRY}.{key}",
            expected,
            discovery.get(key),
        )

    by_feature = {
        path: [row for row in scenarios if row.feature_file == path] for path in paths
    }
    feature_receipts = row_map(
        discovery.get("features"),
        "path",
        "supplemental feature discovery receipts",
        checks,
    )
    checks.same(
        set(by_feature),
        set(feature_receipts),
        "supplemental feature discovery receipts",
        ("source", "registry"),
    )
    for path, rows in by_feature.items():
        expected = {
            "path": path,
            "sha256": _regular_digest(root, path),
            "scenario_count": len(rows),
            "scenario_ids_sha256": set_digest(
                {row.scenario_id for row in rows}
            ),
        }
        checks.need(
            feature_receipts.get(path) == expected,
            "feature_discovery_receipt",
            path,
            expected,
            feature_receipts.get(path),
        )

    checks.need(
        registry.get("assertion_contract") == ASSERTION_CONTRACT,
        "assertion_contract",
        REGISTRY,
        ASSERTION_CONTRACT,
        registry.get("assertion_contract"),
    )
    checks.need(
        registry.get("execution_receipt_contract") == EXECUTION_CONTRACT,
        "execution_receipt_contract",
        REGISTRY,
        EXECUTION_CONTRACT,
        registry.get("execution_receipt_contract"),
    )
    receipts = row_map(
        registry.get("execution_receipts"),
        "scenario_id",
        "supplemental execution receipts",
        checks,
    )
    checks.need(
        set(receipts) <= set(mapped),
        "orphan_execution_receipt",
        REGISTRY,
        "supplemental scenario IDs",
        sorted(set(receipts) - set(mapped)),
    )
    for scenario_id, receipt in receipts.items():
        checks.need(
            set(receipt) == RECEIPT_KEYS,
            "execution_receipt_schema",
            scenario_id,
            sorted(RECEIPT_KEYS),
            sorted(str(key) for key in receipt),
        )

    missing_implementation = sum(
        row.get("implementation_status") != "IMPLEMENTED"
        for row in mapped.values()
    )
    missing_receipts = len(set(mapped) - set(receipts))
    expected_gate = {
        "required_implementation_status": "IMPLEMENTED",
        "required_execution_receipt_status": "PASSED",
        "current_status": (
            "READY"
            if missing_implementation == 0 and missing_receipts == 0
            else "BLOCKED"
        ),
        "missing_implementation_count": missing_implementation,
        "missing_execution_receipt_count": missing_receipts,
    }
    checks.need(
        registry.get("release_gate") == expected_gate,
        "release_gate_receipt",
        REGISTRY,
        expected_gate,
        registry.get("release_gate"),
    )
    return receipts, discovery


def structure(
    root: Path,
) -> tuple[
    Checks,
    BaseInventory,
    list[str],
    list[Scenario],
    dict[str, dict[str, Any]],
    dict[str, dict[str, Any]],
    dict[str, Any],
    int,
]:
    checks = Checks("structure")
    base = base_inventory(root, checks)
    paths, scenarios = discover_supplemental(root, base, checks)
    mapped, _ = validate_mapping(root, paths, scenarios, checks)
    overlay_count = validate_overlays(root, base, set(mapped), checks)
    receipts, discovery = validate_registry(
        root,
        paths,
        scenarios,
        mapped,
        checks,
    )
    return (
        checks,
        base,
        paths,
        scenarios,
        mapped,
        receipts,
        discovery,
        overlay_count,
    )


def _test_declarations(path: Path, text: str, test_id: str) -> list[int]:
    escaped = re.escape(test_id)
    suffixes = path.suffixes
    if path.suffix == ".rs":
        code = executable_source(path, text)
        function = re.compile(
            rf"(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?"
            rf"(?:async\s+)?fn\s+{escaped}\s*\("
        )
        positions: list[int] = []
        for match in function.finditer(code):
            prefix = code[max(0, match.start() - 2048) : match.start()]
            block = re.search(
                r"((?:^[ \t]*#\s*\[[^\]\n]+\][ \t]*\r?\n)+)[ \t]*\Z",
                prefix,
                re.MULTILINE,
            )
            attribute = (
                re.search(
                    r"(?m)^[ \t]*#\s*\[(?:(?:tokio|actix_web)::)?test(?:\([^]]*\))?\][ \t]*$",
                    block.group(1),
                )
                if block is not None
                else None
            )
            if attribute is not None:
                positions.append(match.start())
        return positions
    if suffixes[-2:] in ([".spec", ".ts"], [".test", ".ts"]) or path.suffix in {
        ".ts",
        ".js",
        ".mjs",
    }:
        pattern = re.compile(
            rf"\b(?:test|it)\s*\(\s*['\"][^'\"]*{escaped}[^'\"]*['\"]"
        )
        return [match.start() for match in pattern.finditer(text)]
    if path.suffix == ".py":
        pattern = re.compile(
            rf"(?m)^\s*(?:async\s+)?def\s+{escaped}\s*\("
        )
        return [match.start() for match in pattern.finditer(text)]
    if path.suffix in {".sh", ".bash"}:
        pattern = re.compile(
            rf"(?m)^\s*(?:function\s+)?{escaped}\s*(?:\(\s*\))?\s*\{{"
        )
        return [match.start() for match in pattern.finditer(text)]
    pattern = re.compile(rf"\b{escaped}\b")
    return [match.start() for match in pattern.finditer(text)]


def _source_segments(
    path: Path,
    text: str,
    rows: list[dict[str, Any]],
    checks: Checks,
) -> tuple[dict[str, str], dict[str, int]]:
    positions: list[tuple[int, str]] = []
    declaration_counts: dict[str, int] = {}
    for row in rows:
        scenario_id = str(row.get("scenario_id"))
        test_id = str(row.get("implementation_test_id"))
        declarations = _test_declarations(path, text, test_id)
        declaration_counts[scenario_id] = len(declarations)
        checks.need(
            len(declarations) == 1,
            "zero_test" if not declarations else "duplicate_test",
            scenario_id,
            "exactly one executable test declaration",
            len(declarations),
        )
        if declarations:
            positions.append((declarations[0], scenario_id))
    positions.sort()
    segments: dict[str, str] = {}
    for index, (start, scenario_id) in enumerate(positions):
        rust_end = rust_function_end(path, text, start)
        end = (
            rust_end
            if path.suffix == ".rs" and rust_end is not None
            else positions[index + 1][0]
            if index + 1 < len(positions)
            else len(text)
        )
        checks.need(
            path.suffix != ".rs" or rust_end is not None,
            "invalid_test_body",
            scenario_id,
            "balanced Rust test function body",
            "unbalanced or missing body",
        )
        segments[scenario_id] = text[start:end]
    return segments, declaration_counts


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)

