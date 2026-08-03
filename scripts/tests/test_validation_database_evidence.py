from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import sys
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from validation.design_database_evidence import (
    validate_economics_evidence_pair_contract,
)
from validation.models import Validation


def valid_contract() -> dict[str, object]:
    return {
        "tables": {
            "ops.action_approval_economics_import_details": {
                "source_binding_contract": (
                    "Persisted ID and digest arrays are parallel ID-sorted locked "
                    "pairs; IDs are unique, while repeated valid digests are allowed."
                ),
                "columns": {
                    "source_evidence_segment_ids": {
                        "type": "uuid[]",
                        "nullable": False,
                    },
                    "source_evidence_digests": {
                        "type": "char(64)[]",
                        "nullable": False,
                    },
                },
                "column_order": [
                    "operation_digest",
                    "source_evidence_segment_ids",
                    "source_evidence_digests",
                    "source_evidence_set_digest",
                ],
                "checks": [
                    {
                        "name": (
                            "action_approval_economics_import_details_evidence_ck"
                        ),
                        "expression": (
                            "cardinality(source_evidence_segment_ids) = "
                            "cardinality(source_evidence_digests) AND "
                            "cardinality(source_evidence_segment_ids) BETWEEN 1 AND 1000 "
                            "AND ops.economics_uuid_array_is_sorted_unique_v1("
                            "source_evidence_segment_ids) AND "
                            "ops.sha256_text_array_is_valid_v1("
                            "source_evidence_digests::text[])"
                        ),
                    }
                ],
                "immutable_binding": (
                    "Each parallel digest is lowercase SHA-256 and may repeat; "
                    "the cardinality-equal ID and digest pairs exactly match locked evidence."
                ),
            }
        }
    }


class EconomicsEvidencePairContractTests(unittest.TestCase):
    def test_id_sorted_parallel_pair_contract_passes(self) -> None:
        result = Validation()

        validate_economics_evidence_pair_contract(valid_contract(), result)

        self.assertEqual(result.errors, [])

    def test_independently_sorted_digest_requirement_is_rejected(self) -> None:
        contract = deepcopy(valid_contract())
        relation = contract["tables"][
            "ops.action_approval_economics_import_details"
        ]
        relation["checks"][0]["expression"] = relation["checks"][0][
            "expression"
        ].replace(
            "ops.sha256_text_array_is_valid_v1",
            "ops.sha256_text_array_is_sorted_unique",
        )
        result = Validation()

        validate_economics_evidence_pair_contract(contract, result)

        self.assertIn(
            "0041 evidence pair check must sort unique IDs while preserving "
            "parallel digest order",
            result.errors,
        )

    def test_expression_line_breaks_do_not_change_the_contract(self) -> None:
        contract = deepcopy(valid_contract())
        relation = contract["tables"][
            "ops.action_approval_economics_import_details"
        ]
        relation["checks"][0]["expression"] = relation["checks"][0][
            "expression"
        ].replace(
            "ops.economics_uuid_array_is_sorted_unique_v1(",
            "ops.economics_uuid_array_is_sorted_unique_v1(\n",
        ).replace(
            "ops.sha256_text_array_is_valid_v1(",
            "ops.sha256_text_array_is_valid_v1(\n",
        )
        result = Validation()

        validate_economics_evidence_pair_contract(contract, result)

        self.assertEqual(result.errors, [])


if __name__ == "__main__":
    unittest.main()
