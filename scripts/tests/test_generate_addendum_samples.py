from __future__ import annotations

from collections import Counter
import unittest

from scripts.materialize_application import (
    operation_catalog,
    operation_response_samples,
    operation_spec_sources,
)


class AddendumSampleGenerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.samples = operation_response_samples()
        cls.catalog = operation_catalog()

    def test_empty_public_downloads_keep_required_notice_slots(self) -> None:
        for operation_id in (
            "downloadPublicCases",
            "downloadPublicSearchRecords",
        ):
            with self.subTest(operation_id=operation_id):
                _, _, body = self.samples[operation_id]
                self.assertEqual(body["rowCount"], 0)
                self.assertEqual(body["nonConclusionNotices"], [])
                self.assertIsNone(body["interpretationNotice"])

    def test_command_receipts_bind_their_operation_id(self) -> None:
        command_bodies = {
            operation_id: body["command"]
            for operation_id, (_, _, body) in self.samples.items()
            if isinstance(body, dict)
            and isinstance(body.get("command"), dict)
            and "operationId" in body["command"]
        }

        self.assertLessEqual(
            {"createResponseAppeal", "createActionProposal"},
            set(command_bodies),
        )
        for operation_id, command in command_bodies.items():
            with self.subTest(operation_id=operation_id):
                self.assertEqual(command["operationId"], operation_id)

    def test_additive_external_operations_extend_only_external_registries(self) -> None:
        self.assertEqual(
            Counter(operation["api"] for operation in self.catalog),
            {
                "public-api": 44,
                "submission-api": 42,
                "control-api": 176,
                "identity-service-internal": 9,
                "identity-provider": 6,
            },
        )
        catalog_ids = {operation["operation_id"] for operation in self.catalog}
        self.assertTrue(
            {
                "recordSupplierIdentityResolution",
                "recordSupplierRelationshipAssertion",
                "decideSupplierRelationshipAssertion",
                "reconcileAgentRun",
            }.isdisjoint(catalog_ids)
        )

    def test_transparency_report_download_is_a_public_non_idempotent_query(self) -> None:
        operation = next(
            row
            for row in self.catalog
            if row["operation_id"] == "downloadTransparencyReport"
        )
        self.assertEqual(
            operation,
            {
                "operation_id": "downloadTransparencyReport",
                "api": "public-api",
                "method": "GET",
                "path": "/v1/transparency-reports/{reportId}/download",
                "auth": "anonymous",
                "capability": "none",
                "idempotency": "not-applicable",
                "operation_kind": "QUERY",
                "assurance_level": "NONE",
                "step_up_required": False,
            },
        )

    def test_response_samples_and_rust_operation_catalog_are_exactly_equal(self) -> None:
        catalog_ids = {operation["operation_id"] for operation in self.catalog}
        self.assertEqual(set(self.samples), catalog_ids)
        sources = operation_spec_sources(self.catalog, self.samples)
        self.assertEqual(
            set(sources),
            {
                "public_api",
                "submission_api",
                "control_api",
                "identity_service_internal",
                "identity_provider",
            },
        )


if __name__ == "__main__":
    unittest.main()
