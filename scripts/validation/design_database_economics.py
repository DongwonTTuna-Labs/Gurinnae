from __future__ import annotations

import re
from typing import Any

from .design_database_roles import _validate_runtime_role_contract
from .models import Validation


OWNER_MATRIX_KEYS = {
    "relation",
    "owner_routine_signature",
    "execute_roles",
    "logical_producer",
    "operation_id",
}
OWNER_MATRIX_CONTRACT_KEYS = {
    "freeze_status",
    "active_relation_count_exactly",
    "unavailable_relation_count_exactly",
    "row_keys_exactly",
    "unavailable_row_keys_exactly",
    "closure_rule",
}
UNAVAILABLE_ROW_KEYS = {
    "relation",
    "owner_role",
    "owner_routine_signature",
    "execute_roles",
    "runtime_status",
    "authority_gate",
}
UNAVAILABLE_RELATION_ROWS = [
    {
        "relation": "ops.outcome_facts",
        "owner_role": "gurine_migrator",
        "owner_routine_signature": None,
        "execute_roles": [],
        "runtime_status": "UNAVAILABLE_LEGACY_MUTATOR_REVOKED",
        "authority_gate": "paid_terminal_binding_authority_gate",
    },
    {
        "relation": "editorial.funding_disclosure_revisions",
        "owner_role": "gurine_migrator",
        "owner_routine_signature": None,
        "execute_roles": [],
        "runtime_status": "UNAVAILABLE_NO_PUBLISHER_MUTATOR",
        "authority_gate": "funding_disclosure_publisher_gate",
    },
    {
        "relation": "editorial.funding_disclosure_entries",
        "owner_role": "gurine_migrator",
        "owner_routine_signature": None,
        "execute_roles": [],
        "runtime_status": "UNAVAILABLE_NO_PUBLISHER_MUTATOR",
        "authority_gate": "funding_disclosure_publisher_gate",
    },
]
OWNERSHIP_GROUP_KEYS = (
    "signed_economics_import_owner",
    "product_runtime_owner",
    "funding_governance_owner",
)
NESTED_SOURCE_KEYS = {
    "nested_kind",
    "operation_id",
    "relation",
    "composite_type",
    "modes_exactly",
    "cardinality",
}
NESTED_SOURCE_IDENTITIES = {
    (
        "recordCommercialQualification",
        "ops.acquisition_source_receipts",
        "ops.economics_acquisition_source_import_v1",
    ),
    (
        "importCostAllocationClose",
        "ops.fx_rate_facts",
        "ops.economics_fx_rate_source_import_v1",
    ),
    (
        "recordInvoice",
        "ops.discount_decisions",
        "ops.economics_discount_source_import_v1",
    ),
}
FUNDING_DELEGATION_KEYS = {
    "relation",
    "direct_owner_routine_signature",
    "direct_owner_role",
    "direct_owner_execute_roles_exactly",
    "forbidden_cross_owner_execute_roles_exactly",
    "outer_producers_in_order",
    "rule",
}
OUTER_PRODUCER_KEYS = {
    "logical_producer",
    "entry_routine_signature",
    "execute_roles",
    "direct_relation_dml",
    "delegates_to_owner_signature",
}
CANONICAL_OWNER_SIGNATURE = re.compile(
    r"^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*"
    r"\((?:p_[a-z_][a-z0-9_]* [^,()]+(?:\([^()]*\))?"
    r"(?:, p_[a-z_][a-z0-9_]* [^,()]+(?:\([^()]*\))?)*)?\)"
    r" RETURNS .+$"
)
def _closed_string_list(value: Any) -> list[str] | None:
    if (
        not isinstance(value, list)
        or not all(isinstance(item, str) and item for item in value)
        or len(value) != len(set(value))
    ):
        return None
    return value


def _ownership_relations(
    contract: dict[str, Any],
    result: Validation,
) -> tuple[set[str], set[str]]:
    ownership = contract.get("economics_relation_ownership_exactly_24", {})
    groups: dict[str, list[str]] = {}
    for key in OWNERSHIP_GROUP_KEYS:
        values = _closed_string_list(ownership.get(key))
        result.require(
            values is not None,
            f"0041 economics ownership group {key} is not a unique string list",
        )
        groups[key] = values or []
    flattened = [relation for key in OWNERSHIP_GROUP_KEYS for relation in groups[key]]
    result.require(
        len(flattened) == len(set(flattened)) == 24,
        "0041 economics ownership groups are not exactly 24 distinct relations",
    )
    return set(flattened), set(groups["signed_economics_import_owner"])


def _variant_targets(
    contract: dict[str, Any],
    signed_relations: set[str],
    result: Validation,
) -> dict[str, set[str]]:
    runtime = contract.get("economics_import_runtime_contract", {})
    variants = runtime.get("variants_in_order")
    result.require(
        isinstance(variants, list),
        "0041 economics import variants must be a list",
    )
    if not isinstance(variants, list):
        return {}
    targets: dict[str, set[str]] = {}
    for ordinal, variant in enumerate(variants, start=1):
        valid = (
            isinstance(variant, dict)
            and isinstance(variant.get("operation_id"), str)
            and _closed_string_list(variant.get("target_relations")) is not None
        )
        result.require(
            valid,
            f"0041 economics import variant {ordinal} has an open target declaration",
        )
        if not valid:
            continue
        operation_id = variant["operation_id"]
        result.require(
            operation_id not in targets,
            f"0041 economics import operation is duplicated: {operation_id}",
        )
        targets[operation_id] = set(variant["target_relations"]) & signed_relations
    covered = set().union(*targets.values()) if targets else set()
    result.require(
        covered == signed_relations
        and sum(len(relations) for relations in targets.values())
        == len(signed_relations),
        "0041 import operation targets do not partition the signed economics relations",
    )
    return targets


def _validate_nested_source_resolution(
    contract: dict[str, Any],
    matrix_by_relation: dict[str, dict[str, Any]],
    result: Validation,
) -> None:
    nested = contract.get("nested_source_resolution_contract")
    result.require(
        isinstance(nested, list) and len(nested) == 3,
        "0041 nested source resolution contract must contain exactly three rows",
    )
    if not isinstance(nested, list):
        return
    identities: set[tuple[str, str, str]] = set()
    nested_kinds: set[str] = set()
    for ordinal, row in enumerate(nested, start=1):
        valid_shape = isinstance(row, dict) and set(row) == NESTED_SOURCE_KEYS
        result.require(
            valid_shape,
            f"0041 nested source resolution row {ordinal} is not closed",
        )
        if not valid_shape:
            continue
        operation_id = row.get("operation_id")
        relation = row.get("relation")
        composite_type = row.get("composite_type")
        nested_kind = row.get("nested_kind")
        identity = (operation_id, relation, composite_type)
        valid = (
            all(isinstance(value, str) and value for value in identity)
            and isinstance(nested_kind, str)
            and bool(nested_kind)
            and isinstance(row.get("cardinality"), str)
            and bool(row.get("cardinality"))
            and row.get("modes_exactly") == ["APPEND", "EXISTING"]
        )
        result.require(
            valid,
            f"0041 nested source resolution row {ordinal} is incomplete",
        )
        if not valid:
            continue
        identities.add(identity)
        result.require(
            nested_kind not in nested_kinds,
            f"0041 nested source kind is duplicated: {nested_kind}",
        )
        nested_kinds.add(nested_kind)
        owner = matrix_by_relation.get(relation)
        result.require(
            owner is not None and owner.get("operation_id") == operation_id,
            f"0041 nested source {nested_kind} is not owned by its declared operation",
        )
    result.require(
        identities == NESTED_SOURCE_IDENTITIES,
        "0041 nested acquisition, FX, and discount source identities differ",
    )


def _validate_funding_delegation(
    contract: dict[str, Any],
    matrix_by_relation: dict[str, dict[str, Any]],
    declared_routines: set[str],
    result: Validation,
) -> None:
    delegation = contract.get("funding_snapshot_outer_producer_delegation", {})
    valid_shape = set(delegation) == FUNDING_DELEGATION_KEYS
    result.require(
        valid_shape,
        "0041 funding snapshot outer-producer delegation is not closed",
    )
    if not valid_shape:
        return
    relation = delegation.get("relation")
    direct_signature = delegation.get("direct_owner_routine_signature")
    direct_roles = delegation.get("direct_owner_execute_roles_exactly")
    forbidden_roles = delegation.get("forbidden_cross_owner_execute_roles_exactly")
    producers = delegation.get("outer_producers_in_order")
    valid_producers = (
        isinstance(producers, list)
        and len(producers) == 2
        and all(isinstance(row, dict) and set(row) == OUTER_PRODUCER_KEYS for row in producers)
    )
    result.require(
        relation == "ops.funding_concentration_snapshots"
        and isinstance(direct_signature, str)
        and direct_signature in declared_routines
        and delegation.get("direct_owner_role") == "gurine_migrator"
        and direct_roles == ["gurine_workflow_worker"]
        and forbidden_roles == ["gurine_payment_writer"]
        and valid_producers
        and isinstance(delegation.get("rule"), str)
        and bool(delegation.get("rule")),
        "0041 funding snapshot direct-owner boundary is incomplete",
    )
    if not valid_producers or not isinstance(producers, list):
        return
    matrix_row = matrix_by_relation.get(str(relation))
    result.require(
        matrix_row is not None
        and matrix_row.get("owner_routine_signature") == direct_signature
        and matrix_row.get("execute_roles") == direct_roles,
        "0041 funding snapshot matrix row differs from its sole direct owner",
    )
    signed_import, candidate = producers
    candidate_signature = candidate.get("entry_routine_signature")
    result.require(
        signed_import
        == {
            "logical_producer": "workflow-worker.signed-funding-import",
            "entry_routine_signature": direct_signature,
            "execute_roles": ["gurine_workflow_worker"],
            "direct_relation_dml": True,
            "delegates_to_owner_signature": direct_signature,
        },
        "0041 signed funding import producer differs from its direct owner",
    )
    result.require(
        candidate.get("logical_producer")
        == "public-projection-worker.donation-candidate"
        and isinstance(candidate_signature, str)
        and candidate_signature in declared_routines
        and candidate.get("execute_roles") == ["gurine_public_projector"]
        and candidate.get("direct_relation_dml") is False
        and candidate.get("delegates_to_owner_signature") == direct_signature
        and not (
            set(forbidden_roles or [])
            & (
                set(direct_roles or [])
                | set(candidate.get("execute_roles", []))
            )
        ),
        "0041 donation candidate producer delegation is not fail-closed",
    )


def validate_economics_owner_matrix(
    contract: dict[str, Any],
    global_contract: dict[str, Any],
    result: Validation,
) -> None:
    _validate_runtime_role_contract(contract, global_contract, result)
    expected_relations, signed_relations = _ownership_relations(contract, result)
    target_relations = _variant_targets(contract, signed_relations, result)
    matrix_contract = contract.get("economics_relation_owner_matrix_contract", {})
    unavailable_rows = contract.get("economics_unavailable_relation_rows")
    unavailable_valid = (
        isinstance(unavailable_rows, list)
        and unavailable_rows == UNAVAILABLE_RELATION_ROWS
        and all(
            isinstance(row, dict) and set(row) == UNAVAILABLE_ROW_KEYS
            for row in unavailable_rows
        )
    )
    result.require(
        set(matrix_contract) == OWNER_MATRIX_CONTRACT_KEYS
        and matrix_contract.get("freeze_status") == "FINAL"
        and matrix_contract.get("active_relation_count_exactly") == 21
        and matrix_contract.get("unavailable_relation_count_exactly") == 3
        and matrix_contract.get("row_keys_exactly")
        == sorted(OWNER_MATRIX_KEYS)
        and matrix_contract.get("unavailable_row_keys_exactly")
        == sorted(UNAVAILABLE_ROW_KEYS)
        and isinstance(matrix_contract.get("closure_rule"), str)
        and bool(matrix_contract.get("closure_rule")),
        "0041 economics owner matrix contract is not FINAL and closed",
    )
    result.require(
        unavailable_valid,
        "0041 economics unavailable relation registry differs",
    )
    unavailable_relations = {
        row["relation"] for row in UNAVAILABLE_RELATION_ROWS
    }
    matrix = contract.get("economics_relation_owner_matrix")
    result.require(
        isinstance(matrix, list) and len(matrix) == 21,
        "0041 economics relation owner matrix must contain exactly 21 active rows",
    )
    if not isinstance(matrix, list):
        _validate_nested_source_resolution(contract, {}, result)
        return

    declared_routines = {
        row.get("signature")
        for row in contract.get("owner_routines", [])
        if isinstance(row, dict) and isinstance(row.get("signature"), str)
    }
    matrix_by_relation: dict[str, dict[str, Any]] = {}
    for ordinal, row in enumerate(matrix, start=1):
        valid_shape = isinstance(row, dict) and set(row) == OWNER_MATRIX_KEYS
        result.require(
            valid_shape,
            f"0041 economics owner matrix row {ordinal} is not closed",
        )
        if not valid_shape:
            continue
        relation = row.get("relation")
        signature = row.get("owner_routine_signature")
        execute_roles = _closed_string_list(row.get("execute_roles"))
        valid = (
            isinstance(relation, str)
            and bool(relation)
            and isinstance(signature, str)
            and CANONICAL_OWNER_SIGNATURE.fullmatch(signature) is not None
            and execute_roles is not None
            and isinstance(row.get("logical_producer"), str)
            and bool(row.get("logical_producer"))
            and isinstance(row.get("operation_id"), str)
            and bool(row.get("operation_id"))
        )
        result.require(
            valid,
            f"0041 economics owner matrix row {ordinal} is incomplete",
        )
        if not valid or not isinstance(relation, str):
            continue
        result.require(
            relation not in matrix_by_relation,
            f"0041 economics owner matrix duplicates {relation}",
        )
        matrix_by_relation[relation] = row
        result.require(
            signature in declared_routines,
            f"{relation}: owner routine signature is absent from 0041 inventory",
        )
        if relation in signed_relations:
            result.require(
                execute_roles == [],
                f"{relation}: signed import direct mutator must be internal-only",
            )

    result.require(
        set(matrix_by_relation) == expected_relations - unavailable_relations
        and unavailable_relations <= expected_relations,
        "0041 economics active and unavailable relation sets do not partition 24 relations",
    )
    actual_targets: dict[str, set[str]] = {}
    for relation in signed_relations & set(matrix_by_relation):
        operation_id = matrix_by_relation[relation].get("operation_id")
        if isinstance(operation_id, str):
            actual_targets.setdefault(operation_id, set()).add(relation)
    result.require(
        actual_targets == {key: value for key, value in target_relations.items() if value},
        "0041 signed economics operation ownership differs from variant targets",
    )
    _validate_nested_source_resolution(contract, matrix_by_relation, result)
    _validate_funding_delegation(
        contract,
        matrix_by_relation,
        declared_routines,
        result,
    )
    result.stats["economics_relation_owner_rows"] = len(matrix_by_relation)
    result.stats["economics_unavailable_relation_rows"] = len(
        unavailable_relations
    )
    result.stats["economics_nested_source_rows"] = 3
