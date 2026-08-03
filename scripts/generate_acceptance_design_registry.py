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

from git_authority import AUTHORITY_ZIP_SHA256
from generate_effective_execution_registry import (
    BASE_LOCK,
    BASE_MAPPING,
    CURRENT_EFFECTIVE_SCENARIO_COUNT,
    CURRENT_SUPPLEMENTAL_SCENARIO_COUNT,
    FROZEN_BASE_SCENARIO_COUNT,
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
    "scripts/generate_journey_registry.py",
    "scripts/generate_supplemental_execution_mapping.py",
    "scripts/run_acceptance_assertion_mutations.py",
    "scripts/source_provenance.py",
    "scripts/validation/acceptance_gherkin.py",
    "scripts/validation/effective_acceptance.py",
    "scripts/validation/http_operation_inventory.py",
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
    expected_scenario_counts = {
        "base_scenarios": FROZEN_BASE_SCENARIO_COUNT,
        "supplemental_scenarios": CURRENT_SUPPLEMENTAL_SCENARIO_COUNT,
        "effective_scenarios": CURRENT_EFFECTIVE_SCENARIO_COUNT,
    }
    actual_scenario_counts = (
        {key: counts.get(key) for key in expected_scenario_counts}
        if isinstance(counts, dict)
        else {}
    )
    if actual_scenario_counts != expected_scenario_counts:
        raise ValueError(
            "effective execution registry scenario counts differ: "
            f"expected={expected_scenario_counts!r} actual={actual_scenario_counts!r}"
        )
    runtime_contracts = effective.get("runtime_contracts")
    if not isinstance(runtime_contracts, dict):
        raise ValueError("effective execution registry has no runtime contracts")
    final_inventory = effective.get("final_source_inventory")
    if not isinstance(final_inventory, dict):
        raise ValueError("effective execution registry has no final source inventory")
    screen_inventory = final_inventory.get("screens")
    operation_inventory = final_inventory.get("external_operations")
    private_identity_inventory = final_inventory.get(
        "private_identity_api_operations"
    )
    all_scope_inventory = final_inventory.get("all_scope_http_operations")
    operation_partitions = final_inventory.get("operation_partitions")
    runtime_services = final_inventory.get("runtime_services")
    compose_services = final_inventory.get("compose_services")
    external_ids = (
        set(operation_inventory.get("ids", []))
        if isinstance(operation_inventory, dict)
        else set()
    )
    additive_external_ids = (
        set(operation_inventory.get("additive_ids", []))
        if isinstance(operation_inventory, dict)
        else set()
    )
    private_identity_ids = (
        set(private_identity_inventory.get("ids", []))
        if isinstance(private_identity_inventory, dict)
        else set()
    )
    all_scope_ids = (
        set(all_scope_inventory.get("ids", []))
        if isinstance(all_scope_inventory, dict)
        else set()
    )
    if (
        not isinstance(screen_inventory, dict)
        or screen_inventory.get("count") != 95
        or screen_inventory.get("required_additive_ids") != ["PUB-035"]
        or not isinstance(operation_inventory, dict)
        or operation_inventory.get("base_count") != 217
        or operation_inventory.get("additive_count") != 51
        or operation_inventory.get("final_count") != 268
        or operation_inventory.get("by_api")
        != {
            "control-api": 176,
            "identity-provider": 6,
            "public-api": 44,
            "submission-api": 42,
        }
        or operation_inventory.get("by_kind")
        != {"COMMAND": 145, "QUERY": 123}
        or operation_inventory.get("non_get_count") != 142
        or operation_inventory.get("required_additive_ids")
        != ["downloadTransparencyReport"]
        or len(external_ids) != 268
        or len(additive_external_ids) != 51
        or not additive_external_ids <= external_ids
        or not isinstance(private_identity_inventory, dict)
        or private_identity_inventory.get("count") != 3
        or private_identity_inventory.get("by_api") != {"identity-api": 3}
        or private_identity_inventory.get("by_kind") != {"COMMAND": 3}
        or private_identity_inventory.get("non_get_count") != 3
        or len(private_identity_ids) != 3
        or not isinstance(all_scope_inventory, dict)
        or all_scope_inventory.get("count") != 271
        or all_scope_inventory.get("by_kind")
        != {"COMMAND": 148, "QUERY": 123}
        or all_scope_inventory.get("non_get_count") != 145
        or len(all_scope_ids) != 271
        or external_ids | private_identity_ids != all_scope_ids
        or external_ids & private_identity_ids
        or additive_external_ids & private_identity_ids
        or not isinstance(operation_partitions, dict)
        or operation_partitions.get("base_additive_intersection_count") != 0
        or operation_partitions.get(
            "additive_external_private_identity_intersection_count"
        ) != 0
        or operation_partitions.get("additive_partition_complete") is not True
        or not isinstance(runtime_services, dict)
        or runtime_services.get("count") != 18
        or not isinstance(compose_services, dict)
        or compose_services.get("count") != 22
        or not isinstance(final_inventory.get("inventory_sha256"), str)
    ):
        raise ValueError("effective final screen/operation/service inventory differs")
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
        "final_source_inventory_contract": {
            "source_derived": True,
            "inventory_sha256": final_inventory["inventory_sha256"],
            "screen_count": screen_inventory["count"],
            "required_additive_screen_ids": screen_inventory[
                "required_additive_ids"
            ],
            "base_external_operation_count": operation_inventory["base_count"],
            "additive_external_operation_count": operation_inventory[
                "additive_count"
            ],
            "final_external_operation_count": operation_inventory["final_count"],
            "final_external_query_operation_count": operation_inventory[
                "by_kind"
            ]["QUERY"],
            "final_external_command_operation_count": operation_inventory[
                "by_kind"
            ]["COMMAND"],
            "final_external_non_get_operation_count": operation_inventory[
                "non_get_count"
            ],
            "additive_external_operation_ids": operation_inventory["additive_ids"],
            "required_additive_external_operation_ids": operation_inventory[
                "required_additive_ids"
            ],
            "private_identity_api_operation_count": private_identity_inventory[
                "count"
            ],
            "private_identity_api_operation_ids": private_identity_inventory[
                "ids"
            ],
            "all_scope_http_operation_count": all_scope_inventory["count"],
            "all_scope_http_query_operation_count": all_scope_inventory[
                "by_kind"
            ]["QUERY"],
            "all_scope_http_command_operation_count": all_scope_inventory[
                "by_kind"
            ]["COMMAND"],
            "all_scope_http_non_get_operation_count": all_scope_inventory[
                "non_get_count"
            ],
            "base_additive_intersection_count": operation_partitions[
                "base_additive_intersection_count"
            ],
            "additive_external_private_identity_intersection_count": (
                operation_partitions[
                    "additive_external_private_identity_intersection_count"
                ]
            ),
            "runtime_service_count": runtime_services["count"],
            "compose_service_count": compose_services["count"],
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
            "all_effective_scenarios_required": True,
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
