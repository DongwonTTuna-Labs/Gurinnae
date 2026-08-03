#!/usr/bin/env python3
"""Verify the closed runtime migration filename contract."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_BASE_MIGRATIONS = 24
EXPECTED_ADDITIVE_MIGRATIONS = (
    "0025_evidence_snapshots_and_search.sql",
    "0026_agent_action_approval.sql",
    "0027_communication_consent_delivery.sql",
    "0028_governance_operations.sql",
    "0029_product_economics.sql",
    "0030_v13_submission_session_hardening.sql",
    "0031_public_source_registry_view.sql",
    "0032_relay_model_catalog.sql",
    "0033_provider_control_execution.sql",
)
EXPECTED_RUNTIME_MIGRATIONS = EXPECTED_BASE_MIGRATIONS + len(
    EXPECTED_ADDITIVE_MIGRATIONS
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


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--print-runtime-count", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        runtime_names = verify_migrations()
    except MigrationVerificationError as error:
        stream = sys.stderr if args.print_runtime_count else sys.stdout
        print(f"VERIFY_MIGRATIONS: FAIL: {error}", file=stream)
        return 1
    if args.print_runtime_count:
        print(len(runtime_names))
        return 0
    print(
        "VERIFY_MIGRATIONS: PASS "
        f"runtime={len(runtime_names)} "
        f"base={EXPECTED_BASE_MIGRATIONS} "
        f"additive={len(EXPECTED_ADDITIVE_MIGRATIONS)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
