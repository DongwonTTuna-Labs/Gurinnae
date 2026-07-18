"""Runtime reachability evidence for supplemental Rust assertions."""
from __future__ import annotations

from pathlib import Path
from typing import Any

from .supplemental_acceptance_core import (
    SHA256,
    Checks,
    digest_bytes,
    digest_file,
    safe_path,
)


MUTATION_KEYS = {
    "assertion_ordinal",
    "status",
    "sentinel",
    "command",
    "command_sha256",
    "exit_code",
    "selected_test_count",
    "pass_count",
    "failed_test_count",
    "skipped_test_count",
    "log_artifact",
}


def mutation_sentinel(scenario_id: str, ordinal: int) -> str:
    return f"GURINE_ASSERTION_REACHED:{scenario_id}:{ordinal}"


def mutation_command(base_command: str, scenario_id: str, ordinal: int) -> str:
    value = f"{scenario_id}:{ordinal}"
    return f"env GURINE_ASSERTION_SENTINEL={value} {base_command}"


def validate_assertion_mutations(
    root: Path,
    scenario_id: str,
    base_command: str,
    expected_ordinals: tuple[int, ...],
    value: object,
    checks: Checks,
) -> None:
    rows = value if isinstance(value, list) else []
    observed = [
        row.get("assertion_ordinal")
        for row in rows
        if isinstance(row, dict)
    ]
    checks.need(
        isinstance(value, list)
        and observed == list(expected_ordinals)
        and len(observed) == len(set(observed)),
        "assertion_mutation_set",
        scenario_id,
        list(expected_ordinals),
        observed,
    )
    for row in rows:
        if not isinstance(row, dict):
            continue
        ordinal = row.get("assertion_ordinal")
        if not isinstance(ordinal, int) or isinstance(ordinal, bool):
            continue
        expected_command = mutation_command(base_command, scenario_id, ordinal)
        sentinel = mutation_sentinel(scenario_id, ordinal)
        checks.need(
            set(row) == MUTATION_KEYS,
            "assertion_mutation_schema",
            f"{scenario_id}:{ordinal}",
            sorted(MUTATION_KEYS),
            sorted(str(key) for key in row),
        )
        checks.need(
            row.get("status") == "SENTINEL_REACHED"
            and row.get("sentinel") == sentinel
            and row.get("command") == expected_command
            and row.get("command_sha256")
            == digest_bytes(expected_command.encode("utf-8"))
            and isinstance(row.get("exit_code"), int)
            and not isinstance(row.get("exit_code"), bool)
            and row.get("exit_code") != 0
            and row.get("selected_test_count") == 1
            and row.get("pass_count") == 0
            and row.get("failed_test_count") == 1
            and row.get("skipped_test_count") == 0,
            "assertion_mutation_result",
            f"{scenario_id}:{ordinal}",
            "one selected failing test with exact sentinel command",
            row,
        )
        artifact = row.get("log_artifact")
        valid = (
            isinstance(artifact, dict)
            and set(artifact) == {"path", "sha256"}
            and safe_path(artifact.get("path"))
        )
        path = root / str(artifact.get("path")) if valid else root / "__invalid__"
        actual = (
            digest_file(path)
            if path.is_file() and not path.is_symlink()
            else "missing"
        )
        try:
            log = path.read_text(encoding="utf-8") if actual != "missing" else ""
        except (OSError, UnicodeError):
            log = ""
        checks.need(
            valid
            and SHA256.fullmatch(str(artifact.get("sha256"))) is not None
            and artifact.get("sha256") == actual
            and sentinel in log,
            "assertion_mutation_evidence",
            f"{scenario_id}:{ordinal}",
            {"sha256": actual, "contains": sentinel},
            artifact,
        )
