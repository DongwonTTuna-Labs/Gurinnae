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
    render,
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
        ],
        "private_billing_gateway_operations": {},
    }
    resources = {
        "set_equality": {
            "additive_external_operation_ids": ["additiveOperation"],
            "private_identity_api_operation_ids": [],
        },
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
        "private_billing_gateway_operation_bindings": {},
        "private_billing_gateway_request_schemas": {},
        "schemas": {},
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
            ValueError,
            "duplicate operation IDs across base/additive/private billing catalogs",
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

        pub_035 = next(
            row
            for row in documents["effective"]["screens"]
            if row["screen_id"] == "PUB-035"
        )
        manifest_states = pub_035["state_profile_resolution"][
            "build_manifest_resolution"
        ]["manifest_states"]
        self.assertIn("method-unavailable", manifest_states)
        self.assertIn("receipt", manifest_states)

        int_002 = next(
            row
            for row in documents["effective"]["screens"]
            if row["screen_id"] == "INT-002"
        )
        private_identity_ids = {
            "recordSupplierIdentityResolution",
            "recordSupplierRelationshipAssertion",
            "decideSupplierRelationshipAssertion",
        }
        private_identity_rows = [
            row
            for row in int_002["operation_field_contracts"]
            if row["operation_id"] in private_identity_ids
        ]
        self.assertEqual(
            {row["operation_id"] for row in private_identity_rows},
            private_identity_ids,
        )
        self.assertTrue(
            all(
                row["browser_boundary"]
                == "BFF_PROJECTED_SERVER_ONLY_OPERATION"
                for row in private_identity_rows
            )
        )

    def test_repository_additive_external_catalog_is_closed(self) -> None:
        catalog = build_external_operation_catalog(
            load_yaml(UI / "screen-data-contracts.yaml"),
            load_yaml(PRODUCT / "addendum-operation-contracts.yaml"),
            load_yaml(PRODUCT / "addendum-resource-error-contracts.yaml"),
        )

        self.assertIn("listProviders", catalog)
        self.assertEqual(catalog["createActionProposal"]["scope"], "ADDITIVE_EXTERNAL")


class Pub023RuntimeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.screen = next(
            row
            for row in build_documents()["effective"]["screens"]
            if row["screen_id"] == "PUB-023"
        )

    def test_verified_specialized_mapper_is_final_without_phantom_projections(self) -> None:
        self.assertEqual(self.screen["runtime_implementation_status"], "FINAL")
        self.assertEqual(self.screen["integration_dependencies"], [])
        self.assertEqual(self.screen["projection_schema_definitions"], [])
        self.assertNotIn("$projection", render({"screen": self.screen}))

        mapper = self.screen["specialized_runtime_mapper"]
        self.assertEqual(
            mapper["mapper"],
            "apps/public-web/src/lib/server/public-funding-presentation.ts#publicFundingPresentation",
        )
        self.assertEqual(
            mapper["strict_input_operations"],
            ["getFundingContent", "listTransparencyReports"],
        )
        self.assertEqual(
            mapper["download_bff"]["byte_verifier"],
            "apps/public-web/src/lib/server/transparency-report-download.ts#verifyTransparencyReportDownload",
        )
        self.assertEqual(
            self.screen["semantic_contract"]["next_action"]["copy"][
                "consequence_status"
            ],
            "AUTHORED",
        )

    def test_expense_and_donor_sections_bind_the_strict_funding_content_input(self) -> None:
        sections = {row["section_id"]: row for row in self.screen["sections"]}
        for section_id in ("expenses", "donors"):
            with self.subTest(section_id=section_id):
                fields = sections[section_id]["typed_slice"]["fields"]
                self.assertEqual(len(fields), 1)
                self.assertEqual(fields[0]["name"], "funding_sections")
                self.assertEqual(
                    fields[0]["source"],
                    {
                        "operation_id": "getFundingContent",
                        "field_path": "data",
                        "status": "CURRENT_CLOSED_OPERATION_FIELD",
                    },
                )

    def test_mapper_and_download_verifier_sources_remain_present(self) -> None:
        root = SCRIPTS.parent
        mapper = (root / "apps/public-web/src/lib/server/public-funding-presentation.ts").read_text()
        verifier = (root / "apps/public-web/src/lib/server/transparency-report-download.ts").read_text()

        self.assertIn("export function publicFundingPresentation", mapper)
        self.assertIn("v.strictObject", mapper)
        self.assertIn("export function verifyTransparencyReportDownload", verifier)
        self.assertIn("contentSha256", verifier)


class Pub035ContractCascadeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.documents = build_documents()

    def test_source_registry_is_exact_95_with_private_data_contracts(self) -> None:
        catalog = load_yaml(UI / "screen-catalog.yaml")
        manifest = load_yaml(UI / "screen-build-manifest.yaml")
        catalog_by = {row["id"]: row for row in catalog["screens"]}
        manifest_by = {row["id"]: row for row in manifest["screens"]}

        self.assertEqual(len(catalog_by), 95)
        self.assertEqual(set(catalog_by), set(manifest_by))
        screen = catalog_by["PUB-035"]
        self.assertEqual((screen["surface"], screen["route"]), ("public", "/donate"))
        self.assertEqual(
            [row["operation_id"] for row in screen["data_requirements"]],
            ["private.GetDonationFixtureOffer", "private.QueueDonationIntent"],
        )
        self.assertTrue(
            all(row["server_only"] for row in screen["data_requirements"])
        )
        self.assertEqual(
            screen["donation_authority"]["production_state"], "UNAVAILABLE"
        )
        self.assertFalse(screen["donation_authority"]["production_action_enabled"])

    def test_effective_contract_binds_server_only_test_fixture_operations(self) -> None:
        document = self.documents["effective"]
        self.assertEqual(document["counts"]["screens"], 95)
        self.assertEqual(document["counts"]["sections"], 496)
        screen = next(
            row for row in document["screens"] if row["screen_id"] == "PUB-035"
        )
        self.assertEqual(
            set(screen["semantic_contract"]),
            {"object", "state", "answer", "evidence", "unknown", "next_action"},
        )
        operations = {
            row["operation_id"]: row for row in screen["operation_field_contracts"]
        }
        self.assertEqual(
            set(operations),
            {"private.GetDonationFixtureOffer", "private.QueueDonationIntent"},
        )
        self.assertTrue(
            all(
                row["browser_boundary"]
                == "BFF_PROJECTED_SERVER_ONLY_OPERATION"
                for row in operations.values()
            )
        )
        queued = operations["private.QueueDonationIntent"]
        self.assertEqual(queued["success_status"], 202)
        self.assertIn(
            {"name": "reviewAssigneeUserId", "type": "uuid", "required": True},
            queued["request_field_set"],
        )
        self.assertEqual(
            queued["server_only_request_field_set"],
            [
                {
                    "name": "paymentAuthorizationToken",
                    "type": "secret-string[1..max]",
                    "required": True,
                }
            ],
        )
        self.assertIn(
            {"name": "status", "type": "const<QUEUED>", "required": True},
            queued["response_field_set"],
        )

    def test_state_a11y_action_and_journey_documents_include_pub_035(self) -> None:
        actions = self.documents["actions"]
        refinement = actions["priority_screen_refinements"]["PUB-035"]
        self.assertEqual(
            refinement["exact_notice"],
            "후원은 접근권이 아니며 조사 대상 면제가 아닙니다",
        )
        self.assertEqual(refinement["production_state"], "UNAVAILABLE")
        self.assertFalse(refinement["production_action_enabled"])

        states = self.documents["states"]
        profile_states = {
            row["state"]
            for row in states["profile_occurrences"]
            if row["screen_id"] == "PUB-035"
        }
        special_states = {
            row["state"]
            for row in states["special_occurrences"]
            if row["screen_id"] == "PUB-035"
        }
        self.assertEqual(len(profile_states), 9)
        self.assertEqual(special_states, {"method-unavailable", "receipt"})

        accessibility = self.documents["accessibility"]
        self.assertEqual(accessibility["set_equality"]["screen_contracts"], 95)
        pub_035 = next(
            row for row in accessibility["screens"] if row["screen_id"] == "PUB-035"
        )
        self.assertEqual(
            pub_035["document_section_order"],
            ["mode", "independence", "donation", "receipt"],
        )
        self.assertIn(
            "PUB-035.contact",
            {
                row["navigation_key"]
                for row in accessibility["navigation_focus_contracts"]
            },
        )

        journeys = self.documents["journeys"]
        self.assertEqual(journeys["counts"]["screen_journey_rows"], 95)
        self.assertEqual(journeys["screen_journey_registry"]["PUB-035"], "J-01")

    def test_contract_rendering_is_deterministic_and_rejects_old_notice(self) -> None:
        first = {name: render(document) for name, document in self.documents.items()}
        second = {name: render(document) for name, document in self.documents.items()}

        self.assertEqual(first, second)
        self.assertIn(
            "후원은 접근권이 아니며 조사 대상 면제가 아닙니다", first["actions"]
        )
        self.assertNotIn(
            "후원은 접근권이 아니며 조사 면제가 아닙니다.", first["actions"]
        )


if __name__ == "__main__":
    unittest.main()
