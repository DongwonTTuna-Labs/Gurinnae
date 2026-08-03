from __future__ import annotations

from copy import deepcopy
import sys
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from validation.design_database_economics import (
    UNAVAILABLE_RELATION_ROWS,
    validate_economics_owner_matrix,
)
from validation.models import Validation


SIGNED_TARGETS = {
    "recordCommercialQualification": [
        "ops.acquisition_source_receipts",
        "ops.commercial_qualification_receipts",
    ],
    "importCostAllocationClose": ["ops.fx_rate_facts", "ops.cost_allocations"],
    "createTariffVersion": ["ops.tariff_versions"],
    "recordCommercialContractPeriod": [
        "ops.commercial_contract_periods",
        "ops.offer_profile_capabilities",
    ],
    "recordUsageWindow": ["ops.usage_window_receipts", "ops.usage_facts"],
    "recordInvoice": [
        "ops.discount_decisions",
        "ops.invoice_facts",
        "ops.invoice_line_facts",
        "ops.invoice_usage_memberships",
    ],
    "recordRevenue": ["ops.revenue_facts"],
    "recordAccountingCorrection": ["ops.accounting_corrections"],
}
PRODUCT_RELATIONS = [
    "ops.product_events",
    "ops.outcome_facts",
    "ops.sku_readiness_evaluations",
    "ops.sku_readiness_items",
    "ops.paid_evidence_packets",
    "ops.paid_evidence_packet_members",
]
FUNDING_RELATIONS = [
    "ops.funding_concentration_snapshots",
    "editorial.funding_disclosure_revisions",
    "editorial.funding_disclosure_entries",
]


def valid_global_contract() -> dict[str, object]:
    base_roles = [
        "gurine_public_api",
        "gurine_submission_api",
        "gurine_control_api",
        "gurine_ingest_worker",
        "gurine_analysis_worker",
        "gurine_public_projector",
        "gurine_notification_worker",
        "gurine_workflow_worker",
        "gurine_document_extractor",
        "gurine_scheduler",
        "gurine_auditor",
        "gurine_identity_api",
    ]
    return {
        "privilege_closure": {
            "required_roles": base_roles,
            "schema_usage": {
                "expected_application_schema_snapshot": {
                    role: ["ops"] for role in ["gurine_migrator", *base_roles]
                }
            },
        }
    }


def owner_signature(operation_id: str) -> str:
    snake = "".join(
        f"_{character.lower()}" if character.isupper() else character
        for character in operation_id
    )
    return (
        f"ops.owner_{snake}_v1(p_value ops.economics_input_v1) "
        "RETURNS ops.economics_mutation_receipt_v1"
    )


def valid_contract() -> dict[str, object]:
    funding_owner_signature = (
        "ops.import_funding_snapshot_v1(p_import ops.funding_snapshot_import_v1, "
        "p_entries ops.funding_snapshot_entry_input_v1[]) RETURNS "
        "ops.funding_snapshot_import_receipt_v1"
    )
    funding_candidate_signature = (
        "ops.project_donation_fact_candidate_v1(p_input "
        "ops.donation_funding_candidate_projection_v1) RETURNS "
        "ops.donation_funding_candidate_receipt_v1"
    )
    signed_relations = [
        relation for relations in SIGNED_TARGETS.values() for relation in relations
    ]
    operation_by_relation = {
        relation: operation_id
        for operation_id, relations in SIGNED_TARGETS.items()
        for relation in relations
    }
    operation_by_relation.update(
        {
            "ops.product_events": "recordProductEvent",
            "ops.sku_readiness_evaluations": "recordSkuReadinessEvaluation",
            "ops.sku_readiness_items": "recordSkuReadinessEvaluation",
            "ops.paid_evidence_packets": "materializePaidEvidencePacketSubject",
            "ops.paid_evidence_packet_members": (
                "materializePaidEvidencePacketSubject"
            ),
            "ops.funding_concentration_snapshots": "importFundingSnapshot",
        }
    )
    unavailable_relations = {
        row["relation"] for row in UNAVAILABLE_RELATION_ROWS
    }
    matrix = []
    for relation in [*signed_relations, *PRODUCT_RELATIONS, *FUNDING_RELATIONS]:
        if relation in unavailable_relations:
            continue
        operation_id = operation_by_relation[relation]
        signature = owner_signature(operation_id)
        execute_roles = (
            ["gurine_workflow_worker"]
            if relation
            in {
                "ops.product_events",
                "ops.sku_readiness_evaluations",
                "ops.sku_readiness_items",
                "ops.funding_concentration_snapshots",
            }
            else []
        )
        if relation == "ops.funding_concentration_snapshots":
            operation_id = "importFundingSnapshot"
            signature = funding_owner_signature
        matrix.append(
            {
                "relation": relation,
                "owner_routine_signature": signature,
                "execute_roles": execute_roles,
                "logical_producer": f"fixture.{operation_id}",
                "operation_id": operation_id,
            }
        )
    signatures = {
        row["owner_routine_signature"] for row in matrix
    }
    signatures.add(funding_candidate_signature)
    return {
        "owner_routines": [
            {"signature": signature} for signature in sorted(signatures)
        ],
        "runtime_role_preflight_contract": {
            "provisioning_authority": "checksummed fixture provisioning",
            "migration_role_ddl": "forbidden",
            "preflight_do_canonical_sha256": "a" * 64,
            "roles": [
                {
                    "role": role,
                    "can_login": can_login,
                    "inherit": False,
                    "superuser": False,
                    "createdb": False,
                    "createrole": False,
                    "replication": False,
                    "bypassrls": False,
                    "connection_limit": connection_limit,
                    "memberships_exactly": [],
                }
                for role, can_login, connection_limit in (
                    ("gurine_economics_writer", False, -1),
                    ("gurine_payment_writer", False, -1),
                    ("gurine_billing_gateway", True, 8),
                    ("gurine_economics_importer", True, 4),
                )
            ],
            "prior_authority_rule": "roles must be unprivileged before migration",
        },
        "acl_contract": {
            "role_provisioning_precondition": "runtime_role_preflight_contract",
            "owner_roles": {
                "economics": "gurine_migrator",
                "payment": "gurine_migrator",
            },
            "service_roles": {
                "economics": "gurine_economics_importer",
                "payment": "gurine_billing_gateway",
            },
        },
        "additive_role_registry": {
            "base_registry": (
                "specs/database/addendum/global.yaml"
                "#privilege_closure.required_roles"
            ),
            "roles_in_order": [
                {
                    "role": "gurine_economics_writer",
                    "schema_usage_exactly": [],
                },
                {
                    "role": "gurine_payment_writer",
                    "schema_usage_exactly": [],
                },
                {
                    "role": "gurine_billing_gateway",
                    "schema_usage_exactly": ["ops"],
                },
                {
                    "role": "gurine_economics_importer",
                    "schema_usage_exactly": ["ops"],
                }
            ],
            "count_exactly": 4,
            "merge_rule": "disjoint ordered additive role extension",
        },
        "economics_import_runtime_contract": {
            "database_principal": "gurine_economics_importer",
            "variants_in_order": [
                {
                    "operation_id": operation_id,
                    "target_relations": relations,
                }
                for operation_id, relations in SIGNED_TARGETS.items()
            ],
        },
        "economics_relation_ownership_exactly_24": {
            "signed_economics_import_owner": signed_relations,
            "product_runtime_owner": PRODUCT_RELATIONS,
            "funding_governance_owner": FUNDING_RELATIONS,
        },
        "economics_relation_owner_matrix_contract": {
            "freeze_status": "FINAL",
            "active_relation_count_exactly": 21,
            "unavailable_relation_count_exactly": 3,
            "row_keys_exactly": sorted(
                [
                    "relation",
                    "owner_routine_signature",
                    "execute_roles",
                    "logical_producer",
                    "operation_id",
                ]
            ),
            "unavailable_row_keys_exactly": sorted(
                UNAVAILABLE_RELATION_ROWS[0]
            ),
            "closure_rule": "fixture active and unavailable set partition",
        },
        "economics_relation_owner_matrix": matrix,
        "economics_unavailable_relation_rows": deepcopy(
            UNAVAILABLE_RELATION_ROWS
        ),
        "nested_source_resolution_contract": [
            {
                "nested_kind": "ACQUISITION",
                "operation_id": "recordCommercialQualification",
                "relation": "ops.acquisition_source_receipts",
                "composite_type": "ops.economics_acquisition_source_import_v1",
                "modes_exactly": ["APPEND", "EXISTING"],
                "cardinality": "exactly one source resolution",
            },
            {
                "nested_kind": "FX",
                "operation_id": "importCostAllocationClose",
                "relation": "ops.fx_rate_facts",
                "composite_type": "ops.economics_fx_rate_source_import_v1",
                "modes_exactly": ["APPEND", "EXISTING"],
                "cardinality": "zero or more source resolutions",
            },
            {
                "nested_kind": "DISCOUNT",
                "operation_id": "recordInvoice",
                "relation": "ops.discount_decisions",
                "composite_type": "ops.economics_discount_source_import_v1",
                "modes_exactly": ["APPEND", "EXISTING"],
                "cardinality": "zero or more source resolutions",
            },
        ],
        "funding_snapshot_outer_producer_delegation": {
            "relation": "ops.funding_concentration_snapshots",
            "direct_owner_routine_signature": funding_owner_signature,
            "direct_owner_role": "gurine_migrator",
            "direct_owner_execute_roles_exactly": ["gurine_workflow_worker"],
            "forbidden_cross_owner_execute_roles_exactly": [
                "gurine_payment_writer"
            ],
            "outer_producers_in_order": [
                {
                    "logical_producer": "workflow-worker.signed-funding-import",
                    "entry_routine_signature": funding_owner_signature,
                    "execute_roles": ["gurine_workflow_worker"],
                    "direct_relation_dml": True,
                    "delegates_to_owner_signature": funding_owner_signature,
                },
                {
                    "logical_producer": (
                        "public-projection-worker.donation-candidate"
                    ),
                    "entry_routine_signature": funding_candidate_signature,
                    "execute_roles": ["gurine_public_projector"],
                    "direct_relation_dml": False,
                    "delegates_to_owner_signature": funding_owner_signature,
                },
            ],
            "rule": "candidate delegates to the sole direct owner",
        },
    }


class EconomicsOwnerMatrixTests(unittest.TestCase):
    def test_closed_matrix_and_nested_resolution_pass(self) -> None:
        result = Validation()

        validate_economics_owner_matrix(
            valid_contract(),
            valid_global_contract(),
            result,
        )

        self.assertEqual(result.errors, [])
        self.assertEqual(result.stats["economics_relation_owner_rows"], 21)
        self.assertEqual(
            result.stats["economics_unavailable_relation_rows"],
            3,
        )
        self.assertEqual(result.stats["economics_nested_source_rows"], 3)

    def test_duplicate_relation_is_rejected(self) -> None:
        contract = valid_contract()
        matrix = contract["economics_relation_owner_matrix"]
        assert isinstance(matrix, list)
        matrix[-1]["relation"] = matrix[0]["relation"]
        result = Validation()

        validate_economics_owner_matrix(contract, valid_global_contract(), result)

        self.assertTrue(
            any("owner matrix duplicates" in error for error in result.errors),
            result.errors,
        )

    def test_signed_operation_owner_mismatch_is_rejected(self) -> None:
        contract = valid_contract()
        matrix = contract["economics_relation_owner_matrix"]
        assert isinstance(matrix, list)
        row = next(
            value
            for value in matrix
            if value["relation"] == "ops.discount_decisions"
        )
        row["operation_id"] = "recordRevenue"
        result = Validation()

        validate_economics_owner_matrix(contract, valid_global_contract(), result)

        self.assertIn(
            "0041 signed economics operation ownership differs from variant targets",
            result.errors,
        )

    def test_nested_source_mode_widening_is_rejected(self) -> None:
        contract = valid_contract()
        nested = contract["nested_source_resolution_contract"]
        assert isinstance(nested, list)
        nested[0]["modes_exactly"].append("INFER")
        result = Validation()

        validate_economics_owner_matrix(contract, valid_global_contract(), result)

        self.assertIn(
            "0041 nested source resolution row 1 is incomplete",
            result.errors,
        )

    def test_undeclared_owner_routine_is_rejected(self) -> None:
        contract = deepcopy(valid_contract())
        routines = contract["owner_routines"]
        assert isinstance(routines, list)
        routines.clear()
        result = Validation()

        validate_economics_owner_matrix(contract, valid_global_contract(), result)

        self.assertTrue(
            any(
                "owner routine signature is absent" in error
                for error in result.errors
            ),
            result.errors,
        )

    def test_funding_candidate_direct_dml_is_rejected(self) -> None:
        contract = valid_contract()
        delegation = contract["funding_snapshot_outer_producer_delegation"]
        assert isinstance(delegation, dict)
        producers = delegation["outer_producers_in_order"]
        assert isinstance(producers, list)
        producers[1]["direct_relation_dml"] = True
        result = Validation()

        validate_economics_owner_matrix(
            contract,
            valid_global_contract(),
            result,
        )

        self.assertIn(
            "0041 donation candidate producer delegation is not fail-closed",
            result.errors,
        )

    def test_additive_role_cannot_duplicate_global_registry(self) -> None:
        contract = valid_contract()
        registry = contract["additive_role_registry"]
        assert isinstance(registry, dict)
        rows = registry["roles_in_order"]
        assert isinstance(rows, list)
        rows[0]["role"] = "gurine_public_api"
        result = Validation()

        validate_economics_owner_matrix(
            contract,
            valid_global_contract(),
            result,
        )

        self.assertIn(
            "0041 additive role registry is not the exact four-role extension",
            result.errors,
        )
        self.assertIn(
            "effective runtime roles are not the disjoint global-plus-additive union",
            result.errors,
        )


if __name__ == "__main__":
    unittest.main()
