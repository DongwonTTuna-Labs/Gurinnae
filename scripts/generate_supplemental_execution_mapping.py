#!/usr/bin/env python3
"""Generate the status-free supplemental acceptance execution mapping."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import yaml

from validation.acceptance_gherkin import compile_features, ordered_pair_set_sha256


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = "tests/acceptance/supplemental-executable-mapping.yaml"
BASE_LOCK = "tests/acceptance/base-v13.lock.yaml"

FEATURE_EXECUTION = {
    "tests/acceptance/ai-multimodal-addendum.feature": (
        "ai_multimodal_addendum",
        "AI_MULTIMODAL_V1",
    ),
    "tests/acceptance/business-model-addendum.feature": (
        "business_model_addendum",
        "BUSINESS_LEDGER_V1",
    ),
    "tests/acceptance/procurement-domain-addendum.feature": (
        "procurement_domain_addendum",
        "PROCUREMENT_SOURCE_V1",
    ),
    "tests/acceptance/journey-handoff-addendum.feature": (
        "journey_handoff_addendum",
        "FULL_STACK_RUST_V1",
    ),
    "tests/acceptance/journey-graph-addendum.feature": (
        "journey_graph_addendum",
        "FULL_STACK_BROWSER_V1",
    ),
}


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _base_feature_paths(root: Path) -> set[str]:
    value = yaml.safe_load((root / BASE_LOCK).read_text(encoding="utf-8"))
    rows = value.get("features") if isinstance(value, dict) else None
    if not isinstance(rows, list):
        raise ValueError("base lock feature inventory is invalid")
    return {
        f"tests/acceptance/{row['path']}"
        for row in rows
        if isinstance(row, dict) and isinstance(row.get("path"), str)
    }


def build_mapping(root: Path = ROOT) -> dict[str, object]:
    root = root.resolve()
    base_paths = _base_feature_paths(root)
    all_paths = {
        path.relative_to(root).as_posix()
        for path in (root / "tests/acceptance").glob("*.feature")
    }
    supplemental_paths = sorted(all_paths - base_paths)
    if set(supplemental_paths) != set(FEATURE_EXECUTION):
        raise ValueError(
            "supplemental feature execution profile is incomplete: "
            f"expected={sorted(supplemental_paths)!r} configured={sorted(FEATURE_EXECUTION)!r}"
        )
    contracts = compile_features(root, supplemental_paths)
    for relative in supplemental_paths:
        first = next(
            (
                line.strip()
                for line in (root / relative).read_text(encoding="utf-8").splitlines()
                if line.strip()
            ),
            "",
        )
        if "@supplemental" not in first.split():
            raise ValueError(f"supplemental feature is missing @supplemental: {relative}")
    rows: list[dict[str, object]] = []
    for contract in contracts:
        target, profile_id = FEATURE_EXECUTION[contract.feature_file]
        test_id = contract.scenario_id.lower().replace("-", "_")
        rows.append(
            {
                "scenario_id": contract.scenario_id,
                "feature_file": contract.feature_file,
                "scenario_title": contract.scenario_title,
                "scenario_contract_sha256": contract.scenario_contract_sha256,
                "skip_policy": "FORBIDDEN",
                "runner_kind": "RUST_NEXTEST",
                "implementation_test_path": f"tests/integration/acceptance/{target}.rs",
                "implementation_test_id": test_id,
                "test_target": target,
                "runtime_profile_id": profile_id,
            }
        )
    features = []
    for relative in supplemental_paths:
        feature_contracts = [row for row in contracts if row.feature_file == relative]
        features.append(
            {
                "path": relative,
                "sha256": _sha256(root / relative),
                "scenario_count": len(feature_contracts),
                "scenario_set_sha256": ordered_pair_set_sha256(
                    (row.scenario_id, row.scenario_contract_sha256)
                    for row in feature_contracts
                ),
            }
        )
    return {
        "schema_version": 2,
        "specification_version": "13.0.0",
        "status": "FINAL",
        "registry_kind": "SUPPLEMENTAL_EXECUTABLE_MAPPING",
        "source_derived": True,
        "runtime_state_embedded": False,
        "base_acceptance_lock": BASE_LOCK,
        "feature_count": len(features),
        "scenario_count": len(rows),
        "features": features,
        "release_policy": {
            "all_scenarios_required": True,
            "exact_selector_required": True,
            "external_execution_evidence_required": True,
            "fixture_effect_write_forbidden": True,
            "gherkin_instance_set_equality": True,
            "placeholder_forbidden": True,
            "runtime_layer_set_equality": True,
            "skip_focus_forbidden": True,
            "zero_retry_required": True,
        },
        "scenarios": rows,
    }


def render_mapping(root: Path = ROOT) -> bytes:
    return (
        json.dumps(
            build_mapping(root),
            ensure_ascii=False,
            sort_keys=True,
            indent=2,
        )
        + "\n"
    ).encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", default=OUTPUT)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        rendered = render_mapping(root)
    except (OSError, UnicodeError, ValueError, yaml.YAMLError) as error:
        print(f"SUPPLEMENTAL_EXECUTION_MAPPING: FAIL: {error}")
        return 1
    output = root / args.output
    if args.write:
        output.write_bytes(rendered)
        print(
            "SUPPLEMENTAL_EXECUTION_MAPPING: WROTE "
            f"{args.output} sha256={hashlib.sha256(rendered).hexdigest()}"
        )
        return 0
    if output.is_symlink() or not output.is_file() or output.read_bytes() != rendered:
        print("SUPPLEMENTAL_EXECUTION_MAPPING: FAIL: generated bytes differ")
        return 1
    print(
        "SUPPLEMENTAL_EXECUTION_MAPPING: PASS "
        f"sha256={hashlib.sha256(rendered).hexdigest()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
