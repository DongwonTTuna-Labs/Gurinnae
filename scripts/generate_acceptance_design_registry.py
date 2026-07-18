#!/usr/bin/env python3
"""Generate the static acceptance design registry.

The registry contains only contracts and source hashes. Runtime receipts,
status, counts derived from an execution, and release attestations are stored
outside the source tree so that a review digest cannot depend on evidence that
is produced only after that review.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from generate_effective_execution_registry import (
    AUTHORITY_ZIP_SHA256,
    BASE_LOCK,
    BASE_MAPPING,
    OUTPUT as EFFECTIVE_REGISTRY,
    SUPPLEMENTAL_MAPPING,
)


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = "implementation-evidence/supplemental-acceptance-registry.yaml"

SCHEMAS = (
    "specs/acceptance/execution-receipt-v3.schema.json",
    "specs/acceptance/extraction-receipt-v1.schema.json",
    "specs/acceptance/run-index-v1.schema.json",
    "specs/acceptance/runtime-layer-receipt-v1.schema.json",
)

PROOF_SEMANTICS = (
    ".config/nextest.toml",
    "Makefile",
    "crates/test-support/Cargo.toml",
    "crates/test-support/src/acceptance_observation.rs",
    "crates/test-support/src/lib.rs",
    "infra/docker/dev/Dockerfile",
    "infra/docker/rust-service/Dockerfile",
    "infra/images.lock",
    "scripts/create_source_archive.py",
    "scripts/design_bundle_digest.py",
    "scripts/generate_acceptance_design_registry.py",
    "scripts/generate_effective_execution_registry.py",
    "scripts/generate_supplemental_execution_mapping.py",
    "scripts/run_acceptance_assertion_mutations.py",
    "scripts/source_provenance.py",
    "scripts/validation/acceptance_gherkin.py",
    "scripts/validation/effective_acceptance.py",
    "scripts/verify_source_archive.py",
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _member(root: Path, relative: str) -> dict[str, object]:
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"required regular contract member is missing: {relative}")
    return {
        "path": relative,
        "size": path.stat().st_size,
        "sha256": _sha256(path),
    }


def build_registry(root: Path = ROOT) -> dict[str, object]:
    root = root.resolve()
    effective = json.loads((root / EFFECTIVE_REGISTRY).read_text(encoding="utf-8"))
    counts = effective.get("counts", {})
    if not isinstance(counts, dict) or counts.get("effective_scenarios") != 439:
        raise ValueError("effective execution registry is not the closed 439-scenario set")
    runtime_contracts = effective.get("runtime_contracts")
    if not isinstance(runtime_contracts, dict):
        raise ValueError("effective execution registry has no runtime contracts")
    return {
        "schema_version": 2,
        "specification_version": "13.0.0",
        "status": "FINAL",
        "registry_kind": "SUPPLEMENTAL_ACCEPTANCE_DESIGN_REGISTRY",
        "runtime_state_embedded": False,
        "authority_zip_sha256": AUTHORITY_ZIP_SHA256,
        "contract_inputs": [
            _member(root, relative)
            for relative in (
                BASE_LOCK,
                BASE_MAPPING,
                SUPPLEMENTAL_MAPPING,
                EFFECTIVE_REGISTRY,
            )
        ],
        "scenario_contract": {
            "effective_feature_count": counts.get("effective_features"),
            "effective_scenario_count": counts.get("effective_scenarios"),
            "gherkin_source_step_count": counts.get("gherkin_source_steps"),
            "gherkin_scenario_bound_clause_count": counts.get(
                "gherkin_scenario_bound_clauses"
            ),
            "gherkin_outline_count": counts.get("gherkin_outlines"),
            "gherkin_example_count": counts.get("gherkin_examples"),
            "gherkin_instance_count": counts.get("gherkin_clause_instances"),
            "scenario_set_sha256": effective.get("scenario_sets", {}).get(
                "effective_sha256"
            ),
            "exact_scenario_identity_required": True,
            "background_clause_inheritance_required": True,
            "example_row_and_expansion_digest_required": True,
        },
        "assertion_contract": {
            "contract_version": 3,
            "all_clause_instances_observed": True,
            "all_example_rows_observed": True,
            "assertion_after_success_sentinel_required": True,
            "assertion_ordinal_set_equality": True,
            "bare_or_trivial_assertion_forbidden": True,
            "fixture_only_effect_forbidden": True,
            "runtime_layer_observation_required": True,
        },
        "execution_contract": {
            "contract_version": 3,
            "external_evidence_required": True,
            "source_tree_evidence_forbidden": True,
            "attempt_count": 1,
            "retry_count": 0,
            "exact_discovery_and_selector_required": True,
            "zero_or_multiple_selection_is_failure": True,
            "run_index_schema": "specs/acceptance/run-index-v1.schema.json",
            "scenario_receipt_schema": "specs/acceptance/execution-receipt-v3.schema.json",
            "layer_receipt_schema": "specs/acceptance/runtime-layer-receipt-v1.schema.json",
            "extraction_receipt_schema": "specs/acceptance/extraction-receipt-v1.schema.json",
        },
        "runtime_contracts_sha256": hashlib.sha256(
            json.dumps(
                runtime_contracts,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest(),
        "schemas": [_member(root, relative) for relative in SCHEMAS],
        "proof_semantics_members": [
            _member(root, relative) for relative in PROOF_SEMANTICS
        ],
        "release_policy": {
            "all_439_scenarios_required": True,
            "all_runtime_layers_required": True,
            "failed_count": 0,
            "skipped_count": 0,
            "retried_count": 0,
            "assertion_mutation_survivor_count": 0,
            "source_unchanged_during_evidence_run": True,
            "archive_and_clean_extraction_binding_required": True,
        },
        "forbidden_runtime_keys": [
            "current_status",
            "execution_receipts",
            "implementation_status",
            "implementation_status_counts",
            "missing_execution_receipt_count",
            "missing_implementation_count",
            "release_gate",
        ],
    }


def render_registry(root: Path = ROOT) -> bytes:
    return (
        json.dumps(
            build_registry(root),
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
        rendered = render_registry(root)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        print(f"ACCEPTANCE_DESIGN_REGISTRY: FAIL: {error}")
        return 1
    output = root / args.output
    if args.write:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(rendered)
        print(
            "ACCEPTANCE_DESIGN_REGISTRY: WROTE "
            f"{args.output} sha256={hashlib.sha256(rendered).hexdigest()}"
        )
        return 0
    if output.is_symlink() or not output.is_file() or output.read_bytes() != rendered:
        print("ACCEPTANCE_DESIGN_REGISTRY: FAIL: generated bytes differ")
        return 1
    print(
        "ACCEPTANCE_DESIGN_REGISTRY: PASS "
        f"sha256={hashlib.sha256(rendered).hexdigest()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
