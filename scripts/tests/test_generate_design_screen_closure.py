from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from generate_design_screen_closure import evidence_section_for


class DesignScreenClosureEvidenceRoleTests(unittest.TestCase):
    def test_pub_012_evidence_role_is_stable_across_purpose_translation(self) -> None:
        screen = {
            "id": "PUB-012",
            "sections": [
                {
                    "id": "identity",
                    "title": "계약 식별 정보",
                    "purpose": "source ID·기관·업체·상태.",
                    "component": "StatusAndRevisionHeader",
                },
                {
                    "id": "procurement",
                    "title": "입찰·낙찰 연결",
                    "purpose": "가능한 source 연결.",
                    "component": "StructuredContentSection",
                },
            ],
        }
        translated = copy.deepcopy(screen)
        translated["sections"][0]["purpose"] = "계약 원문 식별자·기관·업체·현재 상태."

        self.assertEqual(evidence_section_for(screen), "identity")
        self.assertEqual(evidence_section_for(translated), "identity")

    def test_pub_012_override_fails_closed_when_identity_section_is_missing(self) -> None:
        screen = {
            "id": "PUB-012",
            "sections": [{"id": "procurement", "purpose": "가능한 source 연결."}],
        }

        with self.assertRaisesRegex(ValueError, "published evidence section is missing"):
            evidence_section_for(screen)


if __name__ == "__main__":
    unittest.main()
