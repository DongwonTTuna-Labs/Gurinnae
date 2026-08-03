from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from jsonschema import Draft202012Validator

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

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
                "verify-execution-evidence: verify-specs",
            )
            (root / "Makefile").write_text(makefile, encoding="utf-8")
            checks = Checks("mutation")
            _validate_make_graph(root, checks)
            self.assertIn(
                "acceptance_make_dependency",
                {problem.code for problem in checks.problems},
            )

    def test_make_graph_requires_acceptance_in_final_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
            makefile = makefile.replace(
                "verify-final: verify-acceptance verify-prearchive",
                "verify-final: verify-prearchive",
            )
            (root / "Makefile").write_text(makefile, encoding="utf-8")
            checks = Checks("mutation")
            _validate_make_graph(root, checks)
            self.assertIn(
                "acceptance_make_dependency",
                {problem.code for problem in checks.problems},
            )

    def test_make_graph_requires_all_explicit_acceptance_inputs(self) -> None:
        variables = {
            "ACCEPTANCE_EVIDENCE_ROOT": "--evidence-root",
            "ACCEPTANCE_RUN_ID": "--run-id",
            "ACCEPTANCE_SOURCE_COMMIT": "--source-commit",
            "ACCEPTANCE_SOURCE_TREE_SHA256": "--source-tree-sha256",
            "ACCEPTANCE_ARCHIVE": "--archive",
            "ACCEPTANCE_EXTRACTION_RECEIPT": "--extraction-receipt",
            "ACCEPTANCE_EXTRACTION_RECEIPT_SHA256": "--extraction-receipt-sha256",
        }
        original = (ROOT / "Makefile").read_text(encoding="utf-8")
        for variable, argument in variables.items():
            guard = (
                f'\t@test -n "$({variable})" || {{ printf \'%s\\n\' '
                f"'{variable} is required'; exit 2; }}\n"
            )
            with (
                self.subTest(variable=variable, contract="guard"),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                self.assertIn(guard, original)
                (root / "Makefile").write_text(
                    original.replace(guard, "", 1), encoding="utf-8"
                )
                checks = Checks("mutation")
                _validate_make_graph(root, checks)
                self.assertIn(
                    "acceptance_make_required_guard",
                    {problem.code for problem in checks.problems},
                )
            explicit = f'\t\t{argument} "$({variable})"'
            with (
                self.subTest(variable=variable, contract="argument"),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                self.assertIn(explicit, original)
                (root / "Makefile").write_text(
                    original.replace(explicit, f"\t\t{argument}", 1), encoding="utf-8"
                )
                checks = Checks("mutation")
                _validate_make_graph(root, checks)
                self.assertIn(
                    "acceptance_make_explicit_argument",
                    {problem.code for problem in checks.problems},
                )

    def test_make_graph_binds_explicit_inputs_to_runner_command(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
            argument = '\t\t--run-id "$(ACCEPTANCE_RUN_ID)" \\\n'
            self.assertIn(argument, makefile)
            runner_end = (
                '\t\t--extraction-receipt-sha256 '
                '"$(ACCEPTANCE_EXTRACTION_RECEIPT_SHA256)"\n'
            )
            self.assertIn(runner_end, makefile)
            mutation = makefile.replace(argument, "", 1).replace(
                runner_end,
                runner_end
                + '\t@printf \'%s\\n\' \'--run-id "$(ACCEPTANCE_RUN_ID)"\' '
                ">/dev/null\n",
                1,
            )
            (root / "Makefile").write_text(
                mutation, encoding="utf-8"
            )
            checks = Checks("mutation")
            _validate_make_graph(root, checks)
            self.assertIn(
                "acceptance_make_explicit_argument",
                {problem.code for problem in checks.problems},
            )

    def test_make_graph_requires_external_evidence_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            makefile = (ROOT / "Makefile").read_text(encoding="utf-8").replace(
                "python -B scripts/validation/effective_acceptance.py --mode evidence",
                "printf 'validation removed\\n'",
            )
            (root / "Makefile").write_text(makefile, encoding="utf-8")
            checks = Checks("mutation")
            _validate_make_graph(root, checks)
            self.assertIn(
                "acceptance_make_evidence_validator",
                {problem.code for problem in checks.problems},
            )

    def test_make_graph_requires_evidence_validator_to_run_in_docker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
            source = (
                "verify-execution-evidence: run-acceptance-439\n"
                '\tdocker run --rm --network none --user "$$(id -u):$$(id -g)"'
            )
            self.assertIn(source, makefile)
            (root / "Makefile").write_text(
                makefile.replace(
                    source,
                    "verify-execution-evidence: run-acceptance-439\n"
                    "\tpython -B scripts/validation/effective_acceptance.py "
                    "--mode evidence",
                    1,
                ),
                encoding="utf-8",
            )
            checks = Checks("mutation")
            _validate_make_graph(root, checks)
            self.assertIn(
                "acceptance_make_out_of_process_evidence_validator",
                {problem.code for problem in checks.problems},
            )

    def test_make_graph_binds_evidence_verdict_to_validator_container(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
            target_start = "verify-execution-evidence: run-acceptance-439\n"
            target_end = "\nverify-acceptance: verify-execution-evidence\n"
            before, separator, remainder = makefile.partition(target_start)
            self.assertEqual(separator, target_start)
            _, separator, after = remainder.partition(target_end)
            self.assertEqual(separator, target_end)
            mutation = target_start + (
                '\tdocker run --rm --volume "$(CURDIR):/workspace:ro" '
                '--volume "$(ACCEPTANCE_EVIDENCE_ROOT):/acceptance-evidence:ro" '
                "gurine-authority-validator:13.0.0 true\n"
                "\tpython -B scripts/validation/effective_acceptance.py "
                "--mode evidence --evidence-root /acceptance-evidence "
                '--run-index "$(ACCEPTANCE_RUN_ID)/run-index.json"\n'
            ) + target_end
            (root / "Makefile").write_text(
                before + mutation + after, encoding="utf-8"
            )
            checks = Checks("mutation")
            _validate_make_graph(root, checks)
            self.assertIn(
                "acceptance_make_out_of_process_evidence_validator",
                {problem.code for problem in checks.problems},
            )

    def test_make_graph_requires_read_only_workspace_and_evidence_mounts(self) -> None:
        mutations = {
            '"$(CURDIR):/workspace:ro"': (
                '"$(CURDIR):/workspace"',
                "acceptance_make_workspace_read_only",
            ),
            '"$(ACCEPTANCE_EVIDENCE_ROOT):/acceptance-evidence:ro"': (
                '"$(ACCEPTANCE_EVIDENCE_ROOT):/acceptance-evidence"',
                "acceptance_make_evidence_read_only",
            ),
        }
        for source, (replacement, expected_code) in mutations.items():
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
                self.assertIn(source, makefile)
                (root / "Makefile").write_text(
                    makefile.replace(source, replacement), encoding="utf-8"
                )
                checks = Checks("mutation")
                _validate_make_graph(root, checks)
                self.assertIn(expected_code, {problem.code for problem in checks.problems})


if __name__ == "__main__":
    unittest.main()
