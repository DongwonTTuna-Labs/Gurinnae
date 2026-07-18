from __future__ import annotations

from pathlib import Path
import tempfile
import textwrap
import unittest

from validation.acceptance_gherkin import GherkinContractError, compile_feature


class AcceptanceGherkinContractTests(unittest.TestCase):
    def compile(self, body: str):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "contract.feature"
            path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
            return compile_feature(path, "tests/acceptance/contract.feature")

    def test_background_outline_and_conjunctions_are_compiled_exactly(self) -> None:
        (row,) = self.compile(
            """
            @hard-gate @final
            Feature: exact contract
              Background:
                Given 공통 전제다
                And 공통 상세다

              # scenario-id: AC-CONTRACT-001
              Scenario Outline: 행마다 실행한다
                Given 값은 <value>다
                When 실행한다
                But 재시도하지 않는다
                Then 결과는 <result>다

                Examples:
                  | value | result |
                  | 하나  | 성공   |
                  | 둘    | 거부   |
            """
        )
        self.assertEqual(row.scenario_kind, "OUTLINE")
        self.assertEqual(len(row.clauses), 6)
        self.assertEqual(len(row.examples), 2)
        self.assertEqual(len(row.instances), 12)
        self.assertEqual(
            [clause.effective_phase for clause in row.clauses],
            ["GIVEN", "GIVEN", "GIVEN", "WHEN", "WHEN", "THEN"],
        )
        self.assertEqual(row.examples[0].example_id, "EX-AC-CONTRACT-001-001")
        result_instances = [
            item for item in row.instances if item.clause_id.endswith("S-004")
        ]
        self.assertEqual(
            [item.substituted_text for item in result_instances],
            ["결과는 성공다", "결과는 거부다"],
        )

    def test_clause_text_order_and_example_order_change_contract_digest(self) -> None:
        base = """
            Feature: digest
              # scenario-id: AC-CONTRACT-001
              Scenario Outline: exact
                Given <value>가 있다
                When 실행한다
                Then 완료된다
                Examples:
                  | value |
                  | 하나  |
                  | 둘    |
        """
        changed_text = base.replace("완료된다", "거부된다")
        changed_order = base.replace("| 하나  |\n                  | 둘    |", "| 둘    |\n                  | 하나  |")
        first = self.compile(base)[0]
        self.assertNotEqual(
            first.scenario_contract_sha256,
            self.compile(changed_text)[0].scenario_contract_sha256,
        )
        self.assertNotEqual(
            first.scenario_contract_sha256,
            self.compile(changed_order)[0].scenario_contract_sha256,
        )

    def test_nfc_equivalent_text_has_the_same_digest(self) -> None:
        composed = """
            Feature: nfc
              # scenario-id: AC-CONTRACT-001
              Scenario: exact
                Given café가 있다
                Then 완료된다
        """
        decomposed = composed.replace("café", "cafe\u0301")
        self.assertEqual(
            self.compile(composed)[0].scenario_contract_sha256,
            self.compile(decomposed)[0].scenario_contract_sha256,
        )

    def test_outline_without_rows_is_rejected(self) -> None:
        with self.assertRaisesRegex(GherkinContractError, "outline_without_examples"):
            self.compile(
                """
                Feature: missing
                  # scenario-id: AC-CONTRACT-001
                  Scenario Outline: exact
                    Given <value>가 있다
                    Then 완료된다
                """
            )

    def test_unknown_placeholder_is_rejected(self) -> None:
        with self.assertRaisesRegex(GherkinContractError, "unknown_example_placeholder"):
            self.compile(
                """
                Feature: missing
                  # scenario-id: AC-CONTRACT-001
                  Scenario Outline: exact
                    Given <missing>이 있다
                    Then 완료된다
                    Examples:
                      | value |
                      | 하나  |
                """
            )

    def test_orphan_conjunction_is_rejected(self) -> None:
        with self.assertRaisesRegex(GherkinContractError, "orphan_conjunction"):
            self.compile(
                """
                Feature: orphan
                  # scenario-id: AC-CONTRACT-001
                  Scenario: exact
                    And 전제가 없다
                """
            )

    def test_examples_on_plain_scenario_are_rejected(self) -> None:
        with self.assertRaisesRegex(GherkinContractError, "examples_on_non_outline"):
            self.compile(
                """
                Feature: invalid
                  # scenario-id: AC-CONTRACT-001
                  Scenario: exact
                    Given 값이 있다
                    Then 완료된다
                    Examples:
                      | value |
                      | 하나  |
                """
            )

    def test_duplicate_background_is_rejected(self) -> None:
        with self.assertRaisesRegex(GherkinContractError, "duplicate_background"):
            self.compile(
                """
                Feature: invalid
                  Background:
                    Given 공통 전제다
                  Background:
                    Given 중복 전제다
                  # scenario-id: AC-CONTRACT-001
                  Scenario: exact
                    Then 완료된다
                """
            )

    def test_scenario_without_then_oracle_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            GherkinContractError,
            "scenario_without_result_oracle",
        ):
            self.compile(
                """
                Feature: invalid
                  # scenario-id: AC-CONTRACT-001
                  Scenario: exact
                    Given 값이 있다
                    When 실행한다
                """
            )

    def test_duplicate_examples_row_is_rejected(self) -> None:
        with self.assertRaisesRegex(GherkinContractError, "duplicate_examples_row"):
            self.compile(
                """
                Feature: invalid
                  # scenario-id: AC-CONTRACT-001
                  Scenario Outline: exact
                    Given <value>가 있다
                    Then 완료된다
                    Examples:
                      | value |
                      | 하나  |
                      | 하나  |
                """
            )

    def test_empty_examples_cell_is_rejected(self) -> None:
        with self.assertRaisesRegex(GherkinContractError, "empty_examples_cell"):
            self.compile(
                """
                Feature: invalid
                  # scenario-id: AC-CONTRACT-001
                  Scenario Outline: exact
                    Given <value>가 있다
                    Then 완료된다
                    Examples:
                      | value |
                      |       |
                """
            )

    def test_examples_width_mismatch_is_rejected(self) -> None:
        with self.assertRaisesRegex(GherkinContractError, "examples_width_mismatch"):
            self.compile(
                """
                Feature: invalid
                  # scenario-id: AC-CONTRACT-001
                  Scenario Outline: exact
                    Given <value>와 <result>가 있다
                    Then 완료된다
                    Examples:
                      | value | result |
                      | 하나  |
                """
            )


if __name__ == "__main__":
    unittest.main()
