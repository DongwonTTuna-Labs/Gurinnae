from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

from jsonschema import Draft202012Validator

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from validation.effective_acceptance import (
    Checks,
    EXECUTION_SCHEMA,
    RUN_INDEX_SCHEMA,
    _validate_make_graph,
    _plain_file_under,
    _typescript_test_titles,
    validate_static,
)
from validation.supplemental_acceptance_source import rust_observation_bindings


ROOT = Path(__file__).resolve().parents[2]


class EffectiveAcceptanceContractTests(unittest.TestCase):
    def test_current_static_contract_is_generated_and_closed(self) -> None:
        checks, registry = validate_static(ROOT)
        self.assertEqual(checks.problems, [])
        self.assertEqual(registry["counts"]["effective_scenarios"], 439)

    def test_typescript_comments_and_strings_cannot_create_a_test(self) -> None:
        titles, calls = _typescript_test_titles(
            '// test("fake", () => {});\nconst value = "test(\\\"also fake\\\")";\n'
        )
        self.assertEqual(titles, [])
        self.assertEqual(calls, 0)

    def test_typescript_dynamic_title_is_counted_but_not_accepted(self) -> None:
        titles, calls = _typescript_test_titles("test(name, async () => {});")
        self.assertEqual(titles, [])
        self.assertEqual(calls, 1)

    def test_typescript_literal_title_is_exact(self) -> None:
        title = "[AC-CONTRACT-001] exact title"
        titles, calls = _typescript_test_titles(
            f'test("{title}", async () => {{}});'
        )
        self.assertEqual(titles, [title])
        self.assertEqual(calls, 1)

    def test_rust_observation_binding_includes_oracle_digest(self) -> None:
        sha = "a" * 64
        source = (
            "fn test_body() {\n"
            "::gurine_acceptance_testkit::observed_assert!("
            f'"AC-CONTRACT-001", 1, "GI-CONTRACT-001", "{sha}", '
            f'"GH-CONTRACT-001", "{sha}", "NONE", "NONE", '
            f'"OR-GI-CONTRACT-001", "{sha}", "{sha}", value);\n'
            "}\n"
        )
        bindings, bare = rust_observation_bindings(Path("test.rs"), source)
        self.assertFalse(bare)
        self.assertEqual(len(bindings), 1)
        self.assertEqual(bindings[0].scenario_id, "AC-CONTRACT-001")
        self.assertEqual(bindings[0].instance_id, "GI-CONTRACT-001")
        self.assertEqual(bindings[0].clause_id, "GH-CONTRACT-001")
        self.assertEqual(bindings[0].phase, "THEN")
        self.assertEqual(bindings[0].oracle_id, "OR-GI-CONTRACT-001")
        self.assertEqual(bindings[0].oracle_sha256, sha)

    def test_bare_rust_assertion_is_detected(self) -> None:
        bindings, bare = rust_observation_bindings(
            Path("test.rs"),
            "fn test_body() {\n::std::assert!(value);\n}\n",
        )
        self.assertEqual(bindings, ())
        self.assertTrue(bare)

    def test_external_plain_file_rejects_traversal_and_symlink_parent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            receipt = run / "receipt.json"
            receipt.write_text("{}\n", encoding="utf-8")
            self.assertEqual(_plain_file_under(root, "run/receipt.json"), receipt)
            self.assertIsNone(_plain_file_under(root, "../receipt.json"))
            target = root / "target"
            target.mkdir()
            (target / "receipt.json").write_text("{}\n", encoding="utf-8")
            (root / "linked").symlink_to(target, target_is_directory=True)
            self.assertIsNone(_plain_file_under(root, "linked/receipt.json"))

    def test_boolean_execution_count_is_not_an_integer(self) -> None:
        schema = json.loads((ROOT / EXECUTION_SCHEMA).read_text(encoding="utf-8"))
        counts_schema = schema["properties"]["counts"]
        value = {
            "discovered": 1,
            "started": 1,
            "terminal": 1,
            "passed": 1,
            "failed": 0,
            "skipped": 0,
            "retried": 0,
            "assertions": True,
        }
        errors = list(Draft202012Validator(counts_schema).iter_errors(value))
        self.assertTrue(errors)

    def test_run_index_cannot_claim_fewer_than_426_receipts(self) -> None:
        schema = json.loads((ROOT / RUN_INDEX_SCHEMA).read_text(encoding="utf-8"))
        receipts_schema = schema["properties"]["receipts"]
        errors = list(Draft202012Validator(receipts_schema).iter_errors([]))
        self.assertTrue(errors)

    def test_make_graph_mutation_removing_runner_dependency_is_killed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
            makefile = makefile.replace(
                "verify-execution-evidence: run-acceptance-439",
                "verify-execution-evidence: verify-acceptance-source",
            )
            (root / "Makefile").write_text(makefile, encoding="utf-8")
            checks = Checks("mutation")
            _validate_make_graph(root, checks)
            self.assertIn(
                "acceptance_make_dependency",
                {problem.code for problem in checks.problems},
            )


if __name__ == "__main__":
    unittest.main()
