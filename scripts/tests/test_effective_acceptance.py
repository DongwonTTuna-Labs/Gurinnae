from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from jsonschema import Draft202012Validator

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from generate_effective_execution_registry import (
    CURRENT_ACCEPTANCE_RUN_TARGET,
    CURRENT_EFFECTIVE_SCENARIO_COUNT,
    CURRENT_SUPPLEMENTAL_SCENARIO_COUNT,
    FROZEN_BASE_SCENARIO_COUNT,
    RegistryError,
    _execution_contract,
)
from generate_supplemental_execution_mapping import (
    R6E_PREREQUISITE_SCENARIO_IDS,
    build_mapping,
    prerequisite_argv_for_scenario,
)
from validation.effective_acceptance import (
    Checks,
    EXECUTION_SCHEMA,
    RUN_INDEX_SCHEMA,
    _evidence_path_allowed,
    _validate_make_graph,
    _plain_file_under,
    _typescript_test_titles,
    validate_static,
)
from validation.effective_acceptance_impl import _validate_runtime_prerequisites
from validation.supplemental_acceptance_source import rust_observation_bindings


ROOT = Path(__file__).resolve().parents[2]


class EffectiveAcceptanceContractTests(unittest.TestCase):
    def test_r6e_prerequisite_mapping_is_exactly_042_through_048(self) -> None:
        rows = {
            row["scenario_id"]: row for row in build_mapping(ROOT)["scenarios"]
        }
        actual = {
            scenario_id
            for scenario_id, row in rows.items()
            if "prerequisite_argv" in row
        }
        self.assertEqual(actual, set(R6E_PREREQUISITE_SCENARIO_IDS))
        for scenario_id in actual:
            self.assertEqual(
                rows[scenario_id]["prerequisite_argv"],
                prerequisite_argv_for_scenario(scenario_id),
            )
        self.assertNotIn("prerequisite_argv", rows["AC-BUSINESS_MODEL-041"])

    def test_effective_generator_rejects_prerequisite_presence_mutations(self) -> None:
        rows = {
            row["scenario_id"]: row for row in build_mapping(ROOT)["scenarios"]
        }
        missing = dict(rows["AC-BUSINESS_MODEL-042"])
        missing.pop("prerequisite_argv")
        with self.assertRaisesRegex(RegistryError, "presence differs"):
            _execution_contract(missing, missing["scenario_id"], missing["scenario_title"])

        unexpected = dict(rows["AC-BUSINESS_MODEL-041"])
        unexpected["prerequisite_argv"] = ["bash", "unexpected.sh"]
        with self.assertRaisesRegex(RegistryError, "presence differs"):
            _execution_contract(
                unexpected, unexpected["scenario_id"], unexpected["scenario_title"]
            )

    def test_validator_kills_prerequisite_argv_and_scenario_set_mutations(self) -> None:
        rows = {
            scenario_id: {
                "execution": {
                    "prerequisite_argv": prerequisite_argv_for_scenario(scenario_id)
                }
            }
            for scenario_id in R6E_PREREQUISITE_SCENARIO_IDS
        }
        rows["AC-BUSINESS_MODEL-042"]["execution"]["prerequisite_argv"] = [
            "bash",
            "-c",
            "unsafe interpolation",
        ]
        rows["AC-BUSINESS_MODEL-041"] = {
            "execution": {"prerequisite_argv": ["bash", "unexpected.sh"]}
        }
        checks = Checks("mutation")
        _validate_runtime_prerequisites(rows, checks)
        codes = {problem.code for problem in checks.problems}
        self.assertIn("runtime_prerequisite_scenario_set", codes)
        self.assertIn("runtime_prerequisite_argv", codes)

    def test_current_static_contract_is_generated_and_closed(self) -> None:
        checks, registry = validate_static(ROOT)
        self.assertEqual(checks.problems, [])
        self.assertEqual(
            registry["counts"]["effective_scenarios"],
            CURRENT_EFFECTIVE_SCENARIO_COUNT,
        )

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

    def test_validator_allows_only_git_ignored_internal_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            (root / ".gitignore").write_text("artifacts/\n", encoding="utf-8")
            ignored = root / "artifacts" / "acceptance"
            ignored.mkdir(parents=True)
            allowed, resolved = _evidence_path_allowed(root, ignored)
            self.assertTrue(allowed)
            self.assertEqual(resolved, ignored)

            not_ignored = root / "evidence"
            not_ignored.mkdir()
            allowed, resolved = _evidence_path_allowed(root, not_ignored)
            self.assertFalse(allowed)
            self.assertEqual(resolved, not_ignored)

    def test_validator_rejects_internal_symlink_ancestor(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "source"
            root.mkdir()
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            (root / ".gitignore").write_text("artifacts/\n", encoding="utf-8")
            target = base / "target"
            (target / "acceptance").mkdir(parents=True)
            (root / "artifacts").symlink_to(target, target_is_directory=True)
            allowed, _ = _evidence_path_allowed(
                root, root / "artifacts" / "acceptance"
            )
            self.assertFalse(allowed)

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

    def test_run_index_schema_requires_current_exact_counts(self) -> None:
        schema = json.loads((ROOT / RUN_INDEX_SCHEMA).read_text(encoding="utf-8"))
        count_properties = schema["properties"]["counts"]["properties"]
        self.assertEqual(
            count_properties["base_scenarios"]["const"],
            FROZEN_BASE_SCENARIO_COUNT,
        )
        self.assertEqual(
            count_properties["supplemental_scenarios"]["const"],
            CURRENT_SUPPLEMENTAL_SCENARIO_COUNT,
        )
        self.assertEqual(
            count_properties["effective_scenarios"]["const"],
            CURRENT_EFFECTIVE_SCENARIO_COUNT,
        )
        self.assertEqual(
            count_properties["passed"]["const"],
            CURRENT_EFFECTIVE_SCENARIO_COUNT,
        )
        receipts_schema = schema["properties"]["receipts"]
        self.assertEqual(
            receipts_schema["minItems"], CURRENT_EFFECTIVE_SCENARIO_COUNT
        )
        self.assertEqual(
            receipts_schema["maxItems"], CURRENT_EFFECTIVE_SCENARIO_COUNT
        )
        errors = list(Draft202012Validator(receipts_schema).iter_errors([]))
        self.assertTrue(errors)

    def test_make_graph_mutation_removing_runner_dependency_is_killed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
            makefile = makefile.replace(
                f"verify-execution-evidence: {CURRENT_ACCEPTANCE_RUN_TARGET}",
                "verify-execution-evidence: verify-specs",
            )
            (root / "Makefile").write_text(makefile, encoding="utf-8")
            checks = Checks("mutation")
            _validate_make_graph(root, checks)
            self.assertIn(
                "acceptance_make_dependency",
                {problem.code for problem in checks.problems},
            )

    def test_make_graph_rejects_duplicate_external_evidence_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Makefile").write_text(
                "verify-specs:\n"
                f"{CURRENT_ACCEPTANCE_RUN_TARGET}: verify-specs\n"
                "\tpython3 -B scripts/run_acceptance.py\n"
                f"verify-execution-evidence: {CURRENT_ACCEPTANCE_RUN_TARGET}\n"
                "\tpython3 -B scripts/validation/effective_acceptance.py --mode evidence\n"
                "verify-acceptance: verify-execution-evidence\n",
                encoding="utf-8",
            )
            checks = Checks("mutation")
            _validate_make_graph(root, checks)
            self.assertIn(
                "acceptance_make_duplicate_evidence_validation",
                {problem.code for problem in checks.problems},
            )


if __name__ == "__main__":
    unittest.main()
