#!/usr/bin/env python3
"""Verify the closed runtime migration filename contract."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_RUNTIME_MIGRATIONS = 30
EXPECTED_BASE_MIGRATIONS = 24
EXPECTED_ADDITIVE_MIGRATIONS = (
    "0025_evidence_snapshots_and_search.sql",
    "0026_agent_action_approval.sql",
    "0027_communication_consent_delivery.sql",
    "0028_governance_operations.sql",
    "0029_product_economics.sql",
    "0030_v13_submission_session_hardening.sql",
)


class MigrationVerificationError(RuntimeError):
    """Migration filenames do not match the closed specification contract."""


def migration_names(directory: Path) -> tuple[str, ...]:
    return tuple(
        path.name for path in sorted(directory.glob("[0-9][0-9][0-9][0-9]_*.sql"))
    )


def verify_migrations(root: Path = ROOT) -> tuple[str, ...]:
    root = root.resolve()
    runtime_names = migration_names(root / "db/migrations")
    base_names = migration_names(root / "specs/database/migrations")
    if len(runtime_names) != EXPECTED_RUNTIME_MIGRATIONS:
        raise MigrationVerificationError(
            f"runtime migration count must be {EXPECTED_RUNTIME_MIGRATIONS}, "
            f"found {len(runtime_names)}"
        )
    if len(base_names) != EXPECTED_BASE_MIGRATIONS:
        raise MigrationVerificationError(
            f"specification migration count must be {EXPECTED_BASE_MIGRATIONS}, "
            f"found {len(base_names)}"
        )
    if runtime_names[:EXPECTED_BASE_MIGRATIONS] != base_names:
        raise MigrationVerificationError(
            "runtime migration prefix differs from specs/database/migrations"
        )
    if runtime_names[EXPECTED_BASE_MIGRATIONS:] != EXPECTED_ADDITIVE_MIGRATIONS:
        raise MigrationVerificationError(
            "runtime additive migration set differs: "
            f"expected {EXPECTED_ADDITIVE_MIGRATIONS}, "
            f"found {runtime_names[EXPECTED_BASE_MIGRATIONS:]}"
        )
    return runtime_names


def main() -> int:
    try:
        runtime_names = verify_migrations()
    except MigrationVerificationError as error:
        print(f"VERIFY_MIGRATIONS: FAIL: {error}")
        return 1
    print(
        "VERIFY_MIGRATIONS: PASS "
        f"runtime={len(runtime_names)} "
        f"base={EXPECTED_BASE_MIGRATIONS} "
        f"additive={len(EXPECTED_ADDITIVE_MIGRATIONS)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
