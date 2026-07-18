"""Negative canaries for supplemental acceptance validation."""
from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Callable

from .supplemental_acceptance_core import (
    Checks,
    ZERO_COMMAND,
    digest_bytes,
    load,
    row_map,
)
from .supplemental_acceptance_assertion_self_test import assertion_mutation_fixtures
from .supplemental_acceptance_features import parse_feature
from .supplemental_acceptance_profile_self_test import profile_fixtures
from .supplemental_acceptance_release import release
from .supplemental_acceptance_source_self_test import (
    qualified_assertion_fixture,
    qualified_release_receipt_fixture,
)

def self_test() -> tuple[bool, list[dict[str, object]]]:
    results: list[dict[str, object]] = []

    def rejected(
        name: str,
        code: str,
        function: Callable[[Checks], None],
    ) -> None:
        checks = Checks("self-test")
        function(checks)
        results.append(
            {
                "fixture": name,
                "expected_problem": code,
                "corruption_rejected": any(
                    problem.code == code for problem in checks.problems
                ),
            }
        )

    def feature(text: str, checks: Checks) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.feature"
            path.write_text(text, encoding="utf-8")
            parse_feature(path, "bad.feature", checks, supplemental=True)

    good_tags = "@hard-gate @final @supplemental\n"
    rejected(
        "missing-final.feature",
        "missing_final_tag",
        lambda checks: feature(
            "@hard-gate @supplemental\n"
            "# scenario-id: AC-BAD-001\nScenario: bad\n",
            checks,
        ),
    )
    rejected(
        "duplicate-id.feature",
        "duplicate_id",
        lambda checks: feature(
            good_tags
            + "# scenario-id: AC-BAD-001\nScenario: one\n"
            + "# scenario-id: AC-BAD-001\nScenario: two\n",
            checks,
        ),
    )
    rejected(
        "orphan-id.feature",
        "orphan_scenario_id",
        lambda checks: feature(
            good_tags + "# scenario-id: AC-BAD-001\n",
            checks,
        ),
    )
    rejected(
        "missing-id.feature",
        "missing_scenario_id",
        lambda checks: feature(good_tags + "Scenario: none\n", checks),
    )
    rejected(
        "skipped.feature",
        "skipped_feature",
        lambda checks: feature(
            "@hard-gate @final @supplemental @skip\n"
            "# scenario-id: AC-BAD-001\nScenario: skip\n",
            checks,
        ),
    )
    rejected(
        "focused.feature",
        "focused_feature",
        lambda checks: feature(
            "@hard-gate @final @supplemental @focus\n"
            "# scenario-id: AC-BAD-001\nScenario: focus\n",
            checks,
        ),
    )
    rejected(
        "scenario-skip-tag.feature",
        "skipped_feature",
        lambda checks: feature(
            good_tags
            + "@skip\n"
            + "# scenario-id: AC-BAD-001\nScenario: skip\n",
            checks,
        ),
    )

    def source(text: str | None, checks: Checks) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative = "tests/bad.rs"
            if text is not None:
                path = root / relative
                path.parent.mkdir(parents=True)
                path.write_text(text, encoding="utf-8")
            row = {
                "scenario_id": "AC-BAD-001",
                "implementation_status": "IMPLEMENTED",
                "implementation_test_path": relative,
                "implementation_test_id": "ac_bad_001",
                "command": "cargo nextest run -- ac_bad_001",
                "runtime_layers": ["rust"],
                "discovery_receipt_id": "SAD-AC-BAD-001",
                "execution_receipt_id": "SAE-AC-BAD-001",
                "assertion_contract_id": "SAA-AC-BAD-001",
            }
            checks.problems.extend(
                release(root, {"AC-BAD-001": row}, {}).problems
            )

    valid_source = (
        "#[test]\n"
        "fn ac_bad_001() {\n"
        '    let scenario_id = "AC-BAD-001";\n'
        '    ::gurine_acceptance_testkit::observed_assert_eq!("AC-BAD-001", 1, scenario_id, "AC-BAD-001");\n'
        "}\n"
    )
    rejected("missing-test", "missing_test", lambda checks: source(None, checks))
    rejected(
        "skip-test",
        "skipped_test",
        lambda checks: source("#[ignore]\n" + valid_source, checks),
    )
    rejected(
        "focus-test",
        "focused_test",
        lambda checks: source(
            "test.only('ac_bad_001', () => {});\n" + valid_source,
            checks,
        ),
    )
    rejected(
        "zero-test",
        "zero_test",
        lambda checks: source(
            "// AC-BAD-001 ac_bad_001\nassert_eq!(1, 1);\n",
            checks,
        ),
    )
    rejected(
        "zero-assertion",
        "zero_assertion",
        lambda checks: source(
            "#[test]\nfn ac_bad_001() { /* AC-BAD-001 */ }\n",
            checks,
        ),
    )
    rejected(
        "commented-test-declaration",
        "zero_test",
        lambda checks: source(
            "// #[test]\n"
            "fn ac_bad_001() {\n"
            '    let scenario_id = "AC-BAD-001";\n'
            "    assert_eq!(scenario_id, scenario_id);\n"
            "}\n",
            checks,
        ),
    )
    rejected(
        "commented-assertion",
        "zero_assertion",
        lambda checks: source(
            "#[test]\n"
            "fn ac_bad_001() {\n"
            '    let scenario_id = "AC-BAD-001";\n'
            "    // assert_eq!(scenario_id, scenario_id);\n"
            "}\n",
            checks,
        ),
    )
    rejected(
        "string-assertion",
        "zero_assertion",
        lambda checks: source(
            "#[test]\n"
            "fn ac_bad_001() {\n"
            '    let scenario_id = "AC-BAD-001";\n'
            '    let claim = "assert_eq!(1, 1)";\n'
            "    drop((scenario_id, claim));\n"
            "}\n",
            checks,
        ),
    )
    rejected(
        "helper-outside-test-body",
        "zero_assertion",
        lambda checks: source(
            "#[test]\n"
            "fn ac_bad_001() {\n"
            '    let scenario_id = "AC-BAD-001";\n'
            "    drop(scenario_id);\n"
            "}\n"
            "fn unused_helper() { assert_eq!(1, 1); }\n",
            checks,
        ),
    )
    rejected(
        "stringify-assertion",
        "zero_assertion",
        lambda checks: source(
            "#[test]\n"
            "fn ac_bad_001() {\n"
            '    let scenario_id = "AC-BAD-001";\n'
            "    let _ = stringify!(assert_eq!(1, 2));\n"
            "    drop(scenario_id);\n"
            "}\n",
            checks,
        ),
    )
    rejected(
        "custom-swallow-macro-assertion",
        "zero_assertion",
        lambda checks: source(
            "macro_rules! swallow { ($($t:tt)*) => { () } }\n"
            "#[test]\n"
            "fn ac_bad_001() {\n"
            '    let scenario_id = "AC-BAD-001";\n'
            "    swallow!(assert_eq!(1, 2));\n"
            "    drop(scenario_id);\n"
            "}\n",
            checks,
        ),
    )
    rejected(
        "aliased-token-macro-assertion",
        "zero_assertion",
        lambda checks: source(
            "#[test]\n"
            "fn ac_bad_001() {\n"
            '    let scenario_id = "AC-BAD-001";\n'
            "    tokens!(assert_eq!(1, 2));\n"
            "    drop(scenario_id);\n"
            "}\n",
            checks,
        ),
    )
    rejected(
        "constant-false-branch-assertion",
        "zero_assertion",
        lambda checks: source(
            "#[test]\n"
            "fn ac_bad_001() {\n"
            '    let scenario_id = "AC-BAD-001";\n'
            "    if false { assert_eq!(1, 2); }\n"
            "    drop(scenario_id);\n"
            "}\n",
            checks,
        ),
    )
    rejected(
        "shadowed-builtin-assertion",
        "zero_assertion",
        lambda checks: source(
            "macro_rules! assert_eq { ($($t:tt)*) => { () } }\n"
            "#[test]\n"
            "fn ac_bad_001() {\n"
            '    let scenario_id = "AC-BAD-001";\n'
            "    assert_eq!(1, 2);\n"
            "    drop(scenario_id);\n"
            "}\n",
            checks,
        ),
    )
    rejected(
        "trivial-assertion",
        "trivial_assertion",
        lambda checks: source(
            "#[test]\n"
            'fn ac_bad_001() { let id = "AC-BAD-001"; ::gurine_acceptance_testkit::observed_assert!("AC-BAD-001", 1, true); drop(id); }\n',
            checks,
        ),
    )
    rejected(
        "missing-receipt",
        "set_equality",
        lambda checks: source(valid_source, checks),
    )
    rejected(
        "zero-command-list",
        "zero_test_command",
        lambda checks: checks.need(
            ZERO_COMMAND.search("cargo test --list") is None,
            "zero_test_command",
            "command",
            "executing",
            "--list",
        ),
    )
    rejected(
        "zero-command-no-run",
        "zero_test_command",
        lambda checks: checks.need(
            ZERO_COMMAND.search("cargo test --no-run") is None,
            "zero_test_command",
            "command",
            "executing",
            "--no-run",
        ),
    )
    rejected(
        "orphan-mapping",
        "set_equality",
        lambda checks: checks.same(
            {"A"}, {"A", "B"}, "mapping", ("features", "mapping")
        ),
    )
    rejected(
        "missing-mapping",
        "set_equality",
        lambda checks: checks.same(
            {"A", "B"}, {"A"}, "mapping", ("features", "mapping")
        ),
    )
    rejected(
        "duplicate-mapping",
        "duplicate_id",
        lambda checks: row_map(
            [{"scenario_id": "A"}, {"scenario_id": "A"}],
            "scenario_id",
            "mapping",
            checks,
        ),
    )
    rejected(
        "stale-discovery",
        "discovery_receipt",
        lambda checks: checks.need(
            "0" * 64 == digest_bytes(b"current"),
            "discovery_receipt",
            "digest",
            digest_bytes(b"current"),
            "0" * 64,
        ),
    )
    rejected(
        "failed-execution",
        "execution_receipt",
        lambda checks: checks.need(
            False,
            "execution_receipt",
            "status",
            "PASSED",
            "FAILED",
        ),
    )
    rejected(
        "duplicate-receipt",
        "duplicate_id",
        lambda checks: row_map(
            [{"scenario_id": "A"}, {"scenario_id": "A"}],
            "scenario_id",
            "receipts",
            checks,
        ),
    )
    def duplicate_yaml(checks: Checks) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "duplicate.yaml").write_text("a: 1\na: 2\n", encoding="utf-8")
            load(root, "duplicate.yaml", checks)

    rejected("duplicate-yaml-key", "invalid_yaml", duplicate_yaml)

    results.append(qualified_assertion_fixture())
    results.append(qualified_release_receipt_fixture())

    results.extend(profile_fixtures())
    results.extend(assertion_mutation_fixtures())
    return all(row["corruption_rejected"] for row in results), results
