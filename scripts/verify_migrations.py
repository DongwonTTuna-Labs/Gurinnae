#!/usr/bin/env python3
"""Verify the closed runtime migration filename and transaction contract."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence

from pglast import parse_sql
from pglast.ast import TransactionStmt
from pglast.enums import TransactionStmtKind
from pglast.parser import ParseError


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
    "0034_public_monitoring_extensions.sql",
    "0035_r6b_agent_runtime_activation.sql",
    "0036_r6b_pipeline_activation.sql",
    "0037_r6c_conflict_investigation.sql",
    "0038_r6d_legal_hardening.sql",
    "0039_r6d_authority_closure.sql",
    "0040_r6d_privacy_authority_closure.sql",
    "0041_f9_natural_person_name_guard_closure.sql",
    "0042_f3_public_source_url_exposure_closure.sql",
    "0043_b1_public_slug_rename_authority.sql",
    "0044_b2_natural_person_detection_digest_closure.sql",
)
EXPECTED_RUNTIME_MIGRATIONS = EXPECTED_BASE_MIGRATIONS + len(
    EXPECTED_ADDITIVE_MIGRATIONS
)
LEGACY_EXPLICIT_TRANSACTION_PROFILES = {
    "0030_v13_submission_session_hardening.sql": 29,
}


class MigrationVerificationError(RuntimeError):
    """A runtime migration violates the closed specification contract."""


def migration_names(directory: Path) -> tuple[str, ...]:
    return tuple(
        path.name for path in sorted(directory.glob("[0-9][0-9][0-9][0-9]_*.sql"))
    )


def verify_transaction_closure(sql: str, migration_name: str) -> None:
    """Reject an explicit migration transaction that is not closed by COMMIT.

    Runner-managed migrations may omit transaction control. Once a migration
    opts into an explicit transaction, only balanced BEGIN/COMMIT pairs are
    accepted so an EOF cannot leave SQLx to commit a partial tail implicitly.
    """

    try:
        statements = parse_sql(sql)
    except ParseError as error:
        raise MigrationVerificationError(
            f"{migration_name}: PostgreSQL parser failed: {error}"
        ) from error

    transaction_open = False
    begin_count = 0
    commit_count = 0
    for statement in statements:
        if not isinstance(statement.stmt, TransactionStmt):
            continue
        kind = statement.stmt.kind
        if kind == TransactionStmtKind.TRANS_STMT_BEGIN:
            if transaction_open:
                raise MigrationVerificationError(
                    f"{migration_name}: nested explicit BEGIN is forbidden"
                )
            transaction_open = True
            begin_count += 1
            continue
        if kind == TransactionStmtKind.TRANS_STMT_COMMIT:
            if not transaction_open:
                raise MigrationVerificationError(
                    f"{migration_name}: explicit COMMIT has no matching BEGIN"
                )
            if statement.stmt.chain:
                raise MigrationVerificationError(
                    f"{migration_name}: COMMIT AND CHAIN leaves an explicit "
                    "transaction open at EOF"
                )
            transaction_open = False
            commit_count += 1
            continue
        raise MigrationVerificationError(
            f"{migration_name}: unsupported explicit transaction control {kind.name}"
        )

    if transaction_open or begin_count != commit_count:
        raise MigrationVerificationError(
            f"{migration_name}: explicit BEGIN lacks terminal COMMIT "
            f"(BEGIN={begin_count}, COMMIT={commit_count})"
        )
    if begin_count == 0:
        return

    legacy_pair_count = LEGACY_EXPLICIT_TRANSACTION_PROFILES.get(migration_name)
    if legacy_pair_count is not None:
        first = statements[0].stmt
        if (
            begin_count != legacy_pair_count
            or not isinstance(first, TransactionStmt)
            or first.kind != TransactionStmtKind.TRANS_STMT_BEGIN
        ):
            raise MigrationVerificationError(
                f"{migration_name}: immutable legacy transaction profile drifted "
                f"(expected {legacy_pair_count} balanced pairs starting at BEGIN)"
            )
        return

    first = statements[0].stmt
    last = statements[-1].stmt
    one_outer_transaction = (
        begin_count == 1
        and commit_count == 1
        and isinstance(first, TransactionStmt)
        and first.kind == TransactionStmtKind.TRANS_STMT_BEGIN
        and isinstance(last, TransactionStmt)
        and last.kind == TransactionStmtKind.TRANS_STMT_COMMIT
        and not last.chain
    )
    if not one_outer_transaction:
        raise MigrationVerificationError(
            f"{migration_name}: explicit transaction must wrap every statement "
            "with the first top-level statement BEGIN and terminal COMMIT"
        )


def _require_transaction_rejection(
    sql: str, canary_name: str, expected_error: str
) -> None:
    try:
        verify_transaction_closure(sql, canary_name)
    except MigrationVerificationError as error:
        if expected_error in str(error):
            return
        raise MigrationVerificationError(
            f"transaction-closure self-test failed with the wrong error: {error}"
        ) from error
    raise MigrationVerificationError(
        f"transaction-closure self-test accepted {canary_name}"
    )


def self_test_transaction_closure() -> None:
    """Prove the verifier rejects both ways an explicit transaction stays open."""

    _require_transaction_rejection(
        "BEGIN;\nSELECT 1;\n",
        "BEGIN-only canary",
        "explicit BEGIN lacks terminal COMMIT",
    )
    _require_transaction_rejection(
        "BEGIN;\nCOMMIT AND CHAIN;\n",
        "COMMIT AND CHAIN canary",
        "COMMIT AND CHAIN leaves an explicit transaction open at EOF",
    )
    _require_transaction_rejection(
        "BEGIN;\nCOMMIT;\nSELECT 1;\n",
        "post-COMMIT tail canary",
        "explicit transaction must wrap every statement",
    )


def verify_migrations(root: Path = ROOT) -> tuple[str, ...]:
    root = root.resolve()
    self_test_transaction_closure()
    runtime_names = migration_names(root / "db/migrations")
    base_names = migration_names(root / "specs/database/migrations")
    for migration_name in runtime_names:
        migration_path = root / "db/migrations" / migration_name
        verify_transaction_closure(
            migration_path.read_text(encoding="utf-8"), migration_name
        )
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
