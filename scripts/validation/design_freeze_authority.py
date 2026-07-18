"""Hash-pinned authority and additive-migration checks for design freeze."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from design_bundle_digest import AUTHORITY_ZIP_SHA256
from generate_effective_registry import Checks
from verify_authority_base_lock import (
    AUTHORITY_MANIFEST_COUNT,
    AUTHORITY_MANIFEST_SHA256,
    AUTHORITY_TREE_SHA256,
    BASE_MIGRATION_COUNT,
)

from .design_freeze_contract import (
    EXPECTED_ADDITIVE_MIGRATIONS,
    EXPECTED_ADDITIVE_ORDINALS,
)


def validate_authority_payload(
    payload: object,
    returncode: int,
    checks: Checks,
    source: str,
) -> None:
    if not isinstance(payload, dict):
        checks.require(
            False,
            "authority_gate_output",
            source,
            "mapping",
            type(payload).__name__,
        )
        return
    stats = payload.get("stats", {})
    if not isinstance(stats, dict):
        checks.require(
            False,
            "authority_gate_output",
            source,
            "stats mapping",
            type(stats).__name__,
        )
        return
    checks.require(
        returncode == 0
        and payload.get("result") == "PASS"
        and payload.get("problem_count") == 0,
        "authority_gate",
        source,
        "PASS/exit 0/problem_count 0",
        {
            "exit": returncode,
            "result": payload.get("result"),
            "problems": payload.get("problem_count"),
        },
    )
    checks.require(
        stats.get("scope") == "migrations",
        "authority_gate_scope",
        source,
        "migrations",
        stats.get("scope"),
    )
    checks.require(
        stats.get("authority_zip_sha256") == AUTHORITY_ZIP_SHA256,
        "authority_archive_digest",
        source,
        AUTHORITY_ZIP_SHA256,
        stats.get("authority_zip_sha256"),
    )
    checks.require(
        stats.get("authority_zip_sha256_before") == AUTHORITY_ZIP_SHA256
        and stats.get("authority_zip_sha256_after") == AUTHORITY_ZIP_SHA256,
        "authority_archive_stability",
        source,
        {
            "before": AUTHORITY_ZIP_SHA256,
            "after": AUTHORITY_ZIP_SHA256,
        },
        {
            "before": stats.get("authority_zip_sha256_before"),
            "after": stats.get("authority_zip_sha256_after"),
        },
    )
    checks.require(
        stats.get("authority_manifest_sha256") == AUTHORITY_MANIFEST_SHA256,
        "authority_manifest_digest",
        source,
        AUTHORITY_MANIFEST_SHA256,
        stats.get("authority_manifest_sha256"),
    )
    checks.require(
        stats.get("authority_tree_sha256") == AUTHORITY_TREE_SHA256,
        "authority_tree_digest",
        source,
        AUTHORITY_TREE_SHA256,
        stats.get("authority_tree_sha256"),
    )
    archive_count = stats.get("authority_manifest_entries")
    checks.require(
        archive_count == AUTHORITY_MANIFEST_COUNT,
        "authority_manifest_count",
        source,
        AUTHORITY_MANIFEST_COUNT,
        archive_count,
    )
    checks.require(
        stats.get("authority_archive_members_matched") == archive_count,
        "authority_archive_match",
        source,
        archive_count,
        stats.get("authority_archive_members_matched"),
    )
    checks.require(
        stats.get("authority_spec_migrations_matched") == BASE_MIGRATION_COUNT,
        "authority_spec_migration_lock",
        source,
        BASE_MIGRATION_COUNT,
        stats.get("authority_spec_migrations_matched"),
    )
    checks.require(
        stats.get("runtime_base_migrations_matched") == BASE_MIGRATION_COUNT,
        "runtime_base_migration_lock",
        source,
        BASE_MIGRATION_COUNT,
        stats.get("runtime_base_migrations_matched"),
    )
    for key in (
        "pending_additive_ordinals",
        "unexpected_additive_ordinals",
        "pending_additive_migrations",
        "unexpected_additive_migrations",
    ):
        checks.require(
            stats.get(key) == [],
            "migration_set_incomplete",
            f"{source}#{key}",
            [],
            stats.get(key),
        )
    checks.require(
        stats.get("allow_pending_additive") is False,
        "migration_set_policy",
        source,
        False,
        stats.get("allow_pending_additive"),
    )
    expected_runtime = stats.get("expected_additive_migrations")
    runtime = stats.get("runtime_additive_migrations")
    checks.require(
        isinstance(expected_runtime, list) and isinstance(runtime, list),
        "authority_gate_contract",
        source,
        "expected_additive_migrations and runtime_additive_migrations lists",
        {
            "expected_type": type(expected_runtime).__name__,
            "runtime_type": type(runtime).__name__,
        },
    )
    if isinstance(expected_runtime, list) and isinstance(runtime, list):
        exact = list(EXPECTED_ADDITIVE_MIGRATIONS)
        checks.require(
            expected_runtime == exact
            and runtime == exact
            and len(expected_runtime) == len(set(expected_runtime))
            and len(runtime) == len(set(runtime)),
            "runtime_migration_set",
            source,
            exact,
            {
                "expected_additive_migrations": expected_runtime,
                "runtime_additive_migrations": runtime,
            },
        )
    checks.require(
        stats.get("expected_additive_ordinals") == EXPECTED_ADDITIVE_ORDINALS,
        "runtime_migration_ordinals",
        source,
        EXPECTED_ADDITIVE_ORDINALS,
        stats.get("expected_additive_ordinals"),
    )
    checks.require(
        stats.get("runtime_additive_migration_count")
        == len(EXPECTED_ADDITIVE_MIGRATIONS)
        and stats.get("expected_final_migration_count") == 30,
        "runtime_migration_count_witness",
        source,
        {
            "runtime_additive_migration_count": len(EXPECTED_ADDITIVE_MIGRATIONS),
            "expected_final_migration_count": 30,
        },
        {
            "runtime_additive_migration_count": stats.get(
                "runtime_additive_migration_count"
            ),
            "expected_final_migration_count": stats.get(
                "expected_final_migration_count"
            ),
        },
    )


def validate_authority_gate(
    root: Path,
    authority_zip: Path,
    checks: Checks,
) -> None:
    script = root / "scripts/verify_authority_base_lock.py"
    if script.is_symlink() or not script.is_file():
        checks.require(
            False,
            "authority_gate_missing",
            str(script),
            "regular file",
            "missing",
        )
        return
    with tempfile.TemporaryDirectory(prefix="gurinnae-freeze-") as directory:
        output = Path(directory) / "authority.json"
        environment = dict(os.environ)
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        try:
            process = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    str(script),
                    "--root",
                    str(root),
                    "--authority-zip",
                    str(authority_zip),
                    "--scope",
                    "migrations",
                    "--json-output",
                    str(output),
                    "--max-problems",
                    "20",
                ],
                cwd=root,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=900,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            checks.require(
                False,
                "authority_gate_execution",
                str(script),
                "completed",
                str(error),
            )
            return
        if not output.is_file():
            checks.require(
                False,
                "authority_gate_output",
                str(script),
                "JSON output",
                process.stdout[-4000:],
            )
            return
        try:
            payload = json.loads(output.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            checks.require(
                False,
                "authority_gate_output",
                str(output),
                "valid JSON",
                str(error),
            )
            return
        validate_authority_payload(payload, process.returncode, checks, str(script))
