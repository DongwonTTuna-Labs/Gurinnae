from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from generate_effective_ui_contracts import (
    PRODUCT,
    UI,
    build_documents,
    build_external_operation_catalog,
    load_yaml,
    validate_screen_data_requirement,
)


def contract_documents() -> tuple[dict, dict, dict]:
    data = {
        "operations": [
            {
                "operation_id": "baseOperation",
                "status": "READY",
                "api": "control-api",
                "method": "GET",
                "path": "/v1/base",
                "request_schema": "BaseRequestV1",
                "response_schema": "BaseResponseV1",
                "success_status": 200,
            }
        ]
    }
    additive = {
        "operations": [
            {
                "operation_id": "additiveOperation",
                "api": "control-api",
                "method": "POST",
                "path": "/v1/additive",
                "kind": "COMMAND",
                "request": {"required": [], "fields": {}},
                "response": "AdditiveResponseV1",
            }
        ]
    }
    resources = {
        "operation_bindings": {
            "additiveOperation": {
                "scope": "ADDITIVE_EXTERNAL",
                "request_schema": "AdditiveRequestV1",
                "success_status": 201,
                "success_schema": "AdditiveResponseV1",
            }
        },
        "request_schemas_by_operation": {
            "additiveOperation": {"name": "AdditiveRequestV1", "fields": {}}
        },
    }
    return data, additive, resources


class EffectiveUiOperationCatalogTests(unittest.TestCase):
    def test_unions_and_normalizes_additive_external_operations(self) -> None:
        catalog = build_external_operation_catalog(*contract_documents())

        self.assertEqual(set(catalog), {"baseOperation", "additiveOperation"})
        additive = catalog["additiveOperation"]
        self.assertEqual(additive["scope"], "ADDITIVE_EXTERNAL")
        self.assertEqual(additive["request_schema"], "AdditiveRequestV1")
        self.assertEqual(additive["response_schema"], "AdditiveResponseV1")
        self.assertEqual(additive["success_status"], 201)

    def test_duplicate_base_and_additive_operation_id_fails_closed(self) -> None:
        data, additive, resources = contract_documents()
        additive["operations"][0]["operation_id"] = "baseOperation"
        resources["operation_bindings"]["baseOperation"] = resources[
            "operation_bindings"
        ].pop("additiveOperation")
        resources["request_schemas_by_operation"]["baseOperation"] = resources[
            "request_schemas_by_operation"
        ].pop("additiveOperation")

        with self.assertRaisesRegex(
            ValueError, "duplicate external operation IDs across base/additive catalogs"
        ):
            build_external_operation_catalog(data, additive, resources)

    def test_additive_schema_bindings_fail_closed_on_drift(self) -> None:
        for field in ("request", "response"):
            with self.subTest(field=field):
                data, additive, resources = contract_documents()
                if field == "request":
                    resources["request_schemas_by_operation"]["additiveOperation"][
                        "name"
                    ] = "DifferentRequestV1"
                else:
                    resources["operation_bindings"]["additiveOperation"][
                        "success_schema"
                    ] = "DifferentResponseV1"
                with self.assertRaisesRegex(ValueError, f"{field} schema"):
                    build_external_operation_catalog(data, additive, resources)

    def test_requirement_transport_and_schema_drift_fails_closed(self) -> None:
        catalog = build_external_operation_catalog(*contract_documents())
        operation = catalog["additiveOperation"]
        requirement = {
            field: operation[field]
            for field in (
                "operation_id",
                "status",
                "api",
                "method",
                "path",
                "request_schema",
                "response_schema",
                "success_status",
            )
        }
        replacements = {
            "status": "BLOCKED",
            "api": "submission-api",
            "method": "GET",
            "path": "/v1/drift",
            "request_schema": "DifferentRequestV1",
            "response_schema": "DifferentResponseV1",
            "success_status": 202,
        }
        for field, replacement in replacements.items():
            with self.subTest(field=field):
                drifted = copy.deepcopy(requirement)
                drifted[field] = replacement
                with self.assertRaisesRegex(ValueError, f"{field} mismatch"):
                    validate_screen_data_requirement(
                        "OPS-005", drifted, catalog
                    )

    def test_ops_005_create_action_proposal_is_single_normalized_row(self) -> None:
        documents = build_documents()
        ops_005 = next(
            row
            for row in documents["effective"]["screens"]
            if row["screen_id"] == "OPS-005"
        )
        matches = [
            row
            for row in ops_005["operation_field_contracts"]
            if row["operation_id"] == "createActionProposal"
        ]

        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0]["request_schema"], "CreateActionProposalRequestV1")
        self.assertEqual(matches[0]["response_schema"], "ActionProposalReceiptV1")
        self.assertEqual(matches[0]["success_status"], 201)

    def test_repository_additive_external_catalog_is_closed(self) -> None:
        catalog = build_external_operation_catalog(
            load_yaml(UI / "screen-data-contracts.yaml"),
            load_yaml(PRODUCT / "addendum-operation-contracts.yaml"),
            load_yaml(PRODUCT / "addendum-resource-error-contracts.yaml"),
        )

        self.assertIn("listProviders", catalog)
        self.assertEqual(catalog["createActionProposal"]["scope"], "ADDITIVE_EXTERNAL")


if __name__ == "__main__":
    unittest.main()
