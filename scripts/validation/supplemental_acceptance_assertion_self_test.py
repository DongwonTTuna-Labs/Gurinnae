"""Self-tests for runtime assertion reachability receipts."""
from __future__ import annotations

import tempfile
from pathlib import Path

from .supplemental_acceptance_assertions import (
    mutation_command,
    mutation_sentinel,
    validate_assertion_mutations,
)
from .supplemental_acceptance_core import Checks, digest_bytes, digest_file


def _row(root: Path, *, valid_log: bool) -> dict[str, object]:
    scenario_id = "AC-BAD-001"
    ordinal = 1
    sentinel = mutation_sentinel(scenario_id, ordinal)
    command = mutation_command("cargo nextest run -- ac_bad_001", scenario_id, ordinal)
    path = root / "evidence/assertion.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(sentinel if valid_log else "test passed without sentinel", encoding="utf-8")
    return {
        "assertion_ordinal": ordinal,
        "status": "SENTINEL_REACHED",
        "sentinel": sentinel,
        "command": command,
        "command_sha256": digest_bytes(command.encode("utf-8")),
        "exit_code": 100,
        "selected_test_count": 1,
        "pass_count": 0,
        "failed_test_count": 1,
        "skipped_test_count": 0,
        "log_artifact": {
            "path": "evidence/assertion.log",
            "sha256": digest_file(path),
        },
    }


def _validate(root: Path, value: object) -> Checks:
    checks = Checks("self-test")
    validate_assertion_mutations(
        root,
        "AC-BAD-001",
        "cargo nextest run -- ac_bad_001",
        (1,),
        value,
        checks,
    )
    return checks


def assertion_mutation_fixtures() -> list[dict[str, object]]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        valid = _validate(root, [_row(root, valid_log=True)])
        missing = _validate(root, [])
        invalid_log = _validate(root, [_row(root, valid_log=False)])
    return [
        {
            "fixture": "assertion-mutation-valid",
            "expected_problem": "none",
            "corruption_rejected": not valid.problems,
        },
        {
            "fixture": "assertion-mutation-missing",
            "expected_problem": "assertion_mutation_set",
            "corruption_rejected": any(
                row.code == "assertion_mutation_set" for row in missing.problems
            ),
        },
        {
            "fixture": "assertion-mutation-sentinel-unreached",
            "expected_problem": "assertion_mutation_evidence",
            "corruption_rejected": any(
                row.code == "assertion_mutation_evidence"
                for row in invalid_log.problems
            ),
        },
    ]
