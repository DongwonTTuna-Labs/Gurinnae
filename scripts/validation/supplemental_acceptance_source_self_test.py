"""Positive Rust source scanner probe kept outside the canary coordinator."""
from __future__ import annotations

import tempfile
from pathlib import Path

from .supplemental_acceptance_assertions import (
    mutation_command,
    mutation_sentinel,
)
from .supplemental_acceptance_core import digest_bytes, digest_file
from .supplemental_acceptance_release import release


def qualified_assertion_fixture() -> dict[str, object]:
    text = (
        "#[test]\n"
        "fn ac_bad_001() {\n"
        '    let scenario_id = "AC-BAD-001";\n'
        "    if true { drop(1_u8); }\n"
        "    ::gurine_acceptance_testkit::observed_assert_eq!{\"AC-BAD-001\", 1, scenario_id, \"AC-BAD-001\"};\n"
        "}\n"
    )
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        relative = "tests/bad.rs"
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
        codes = [
            problem.code
            for problem in release(root, {"AC-BAD-001": row}, {}).problems
        ]
    return {
        "fixture": "qualified-assertion-after-block",
        "expected_problem": "set_equality only",
        "corruption_rejected": codes == ["set_equality"],
    }


def qualified_release_receipt_fixture() -> dict[str, object]:
    scenario_id = "AC-BAD-001"
    command = "cargo nextest run -- ac_bad_001"
    text = (
        "#[test]\n"
        "fn ac_bad_001() {\n"
        '    let scenario_id = "AC-BAD-001";\n'
        '    ::gurine_acceptance_testkit::observed_assert_eq!{"AC-BAD-001", 1, scenario_id, "AC-BAD-001"};\n'
        "}\n"
    )
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        source_relative = "tests/bad.rs"
        source_path = root / source_relative
        source_path.parent.mkdir(parents=True)
        source_path.write_text(text, encoding="utf-8")

        log_relative = "verification/assertion-001.log"
        log_path = root / log_relative
        log_path.parent.mkdir(parents=True)
        sentinel = mutation_sentinel(scenario_id, 1)
        log_path.write_text(
            sentinel
            + "\ntest result: FAILED. 0 passed; 1 failed; 0 ignored; "
            + "0 measured; 0 filtered out; finished in 0.00s\n",
            encoding="utf-8",
        )
        mutation_value = mutation_command(command, scenario_id, 1)
        mutation = {
            "assertion_ordinal": 1,
            "status": "SENTINEL_REACHED",
            "sentinel": sentinel,
            "command": mutation_value,
            "command_sha256": digest_bytes(mutation_value.encode("utf-8")),
            "exit_code": 101,
            "selected_test_count": 1,
            "pass_count": 0,
            "failed_test_count": 1,
            "skipped_test_count": 0,
            "log_artifact": {
                "path": log_relative,
                "sha256": digest_file(log_path),
            },
        }
        row = {
            "scenario_id": scenario_id,
            "implementation_status": "IMPLEMENTED",
            "implementation_test_path": source_relative,
            "implementation_test_id": "ac_bad_001",
            "command": command,
            "runtime_layers": ["rust"],
            "discovery_receipt_id": f"SAD-{scenario_id}",
            "execution_receipt_id": f"SAE-{scenario_id}",
            "assertion_contract_id": f"SAA-{scenario_id}",
        }
        receipt = {
            "receipt_id": f"SAE-{scenario_id}",
            "scenario_id": scenario_id,
            "discovery_receipt_id": f"SAD-{scenario_id}",
            "assertion_contract_id": f"SAA-{scenario_id}",
            "status": "PASSED",
            "implementation_test_path": source_relative,
            "implementation_test_id": "ac_bad_001",
            "test_source_sha256": digest_file(source_path),
            "command": command,
            "command_sha256": digest_bytes(command.encode("utf-8")),
            "runtime_layers": ["rust"],
            "exit_code": 0,
            "selected_test_count": 1,
            "pass_count": 1,
            "failed_test_count": 0,
            "skipped_test_count": 0,
            "assertion_count": 1,
            "assertion_mutations": [mutation],
            "executed_at": "2026-07-18T00:00:00Z",
            "artifacts": [
                {"path": log_relative, "sha256": digest_file(log_path)}
            ],
        }
        problems = release(root, {scenario_id: row}, {scenario_id: receipt}).problems
        receipt["selected_test_count"] = True
        boolean_problems = release(
            root,
            {scenario_id: row},
            {scenario_id: receipt},
        ).problems
    return {
        "fixture": "qualified-release-receipt",
        "expected_problem": "none; boolean count rejected",
        "corruption_rejected": not problems
        and any(problem.code == "execution_receipt" for problem in boolean_problems),
    }
