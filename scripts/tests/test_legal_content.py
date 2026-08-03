from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from generate_legal_content import (  # noqa: E402
    comparable_retention_contract,
    generated_outputs,
    legal_content_envelopes,
    source_license_matrix,
)


class LegalContentGenerationTest(unittest.TestCase):
    def test_source_license_matrix_is_closed_and_non_authorizing(self) -> None:
        matrix = source_license_matrix()
        self.assertEqual(matrix["connector_count"], 8)
        self.assertEqual(matrix["operation_count"], 56)
        catalog = yaml.safe_load(
            (ROOT / "specs/connectors/connector-catalog.yaml").read_text(encoding="utf-8")
        )
        self.assertEqual(
            [row["connector_id"] for row in matrix["connectors"]],
            [row["id"] for row in catalog["connectors"]],
        )
        for row in matrix["connectors"]:
            self.assertFalse(row["publication_authorized"])
            self.assertEqual(set(row["rights_dimensions"].values()), {"UNKNOWN"})
            self.assertEqual(
                row["required_evidence"],
                "SOURCE_LICENSE/PRODUCTION_LEGAL/SATISFIED",
            )
            self.assertTrue(row["official_references"])
            self.assertEqual(
                row["rights_status"],
                "BLOCKED" if row["legal_blocker"] else "REVIEW_REQUIRED",
            )

    def test_generated_outputs_match_worktree(self) -> None:
        for path, expected in generated_outputs().items():
            self.assertTrue(path.is_file(), path)
            self.assertEqual(path.read_text(encoding="utf-8"), expected, path)

    def test_privacy_retention_rows_are_runtime_only(self) -> None:
        privacy = yaml.safe_load(
            (ROOT / "specs/legal/privacy-notice.yaml").read_text(encoding="utf-8")
        )
        retention = privacy["retention_table"]
        self.assertEqual(retention["materialization"], "RUNTIME_ONLY")
        self.assertTrue(retention["static_rows_forbidden"])
        self.assertNotIn("rows", retention)
        self.assertTrue(retention["empty_result"]["launch_blocking"])
        self.assertEqual(retention["empty_result"]["table_state"], "UNAVAILABLE")
        self.assertEqual(retention["empty_result"]["document_state"], "UNPUBLISHED")
        self.assertEqual(retention["empty_result"]["response_behavior"], "FAIL_CLOSED")

    def test_terms_share_the_approved_runtime_retention_contract(self) -> None:
        privacy = yaml.safe_load(
            (ROOT / "specs/legal/privacy-notice.yaml").read_text(encoding="utf-8")
        )
        terms = yaml.safe_load(
            (ROOT / "specs/legal/terms-of-use.yaml").read_text(encoding="utf-8")
        )
        retention = terms["retention_table"]
        self.assertEqual(
            comparable_retention_contract(terms),
            comparable_retention_contract(privacy),
        )
        self.assertEqual(retention["source_relation"], "ops.record_class_schedules")
        self.assertEqual(retention["materialization"], "RUNTIME_ONLY")
        self.assertTrue(retention["static_rows_forbidden"])
        self.assertNotIn("rows", retention)
        self.assertEqual(
            terms["publication_gate"]["required_runtime_evidence"],
            ["ACTIVE_APPROVED_RETENTION_SCHEDULES"],
        )
        self.assertTrue(terms["publication_gate"]["no_partial_publication"])

    def test_generated_terms_exposes_no_static_retention_values(self) -> None:
        terms_path = ROOT / "docs/legal/terms-of-use-draft.md"
        terms = generated_outputs()[terms_path]
        self.assertIn("`ops.record_class_schedules`의 유효하고 승인된 최신 revision", terms)
        self.assertIn("정적 기간·정적 행: 금지", terms)
        self.assertIn("이 문서에는 기간 값을 복제하지 않습니다.", terms)
        self.assertIn("`UNPUBLISHED` / `FAIL_CLOSED`", terms)

    def test_operator_owned_launch_inputs_are_not_invented(self) -> None:
        document = yaml.safe_load(
            (ROOT / "specs/legal/operator-owned-launch-inputs.yaml").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(document["status"], "USER_INPUT_REQUIRED")
        self.assertTrue(
            all(
                item["owner"] == "USER"
                and item["state"] == "USER_INPUT_REQUIRED"
                and item["value"] is None
                for item in document["inputs"]
            )
        )

    def test_law_enforcement_document_does_not_claim_execution(self) -> None:
        document = yaml.safe_load(
            (ROOT / "specs/legal/law-enforcement-request-procedure.yaml").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(document["status"], "DRAFT_PROCEDURE_STUB")
        self.assertEqual(document["hard_rules"]["automatic_disclosure"], "forbidden")
        self.assertTrue(document["implementation_boundary"]["document_only_stub"])
        self.assertTrue(document["implementation_boundary"]["no_runtime_producer_claim"])

    def test_ui_envelopes_have_closed_canonical_sections(self) -> None:
        envelopes = legal_content_envelopes()
        self.assertEqual(set(envelopes), {"privacy", "terms"})
        self.assertEqual(len(envelopes["privacy"]["sections"]), 8)
        self.assertEqual(len(envelopes["terms"]["sections"]), 6)
        for envelope in envelopes.values():
            self.assertEqual(set(envelope), {"status", "sections"})
            ids = [section["id"] for section in envelope["sections"]]
            self.assertEqual(len(ids), len(set(ids)))
            self.assertTrue(
                all(set(section) == {"id", "heading", "body"} for section in envelope["sections"])
            )


if __name__ == "__main__":
    unittest.main()
