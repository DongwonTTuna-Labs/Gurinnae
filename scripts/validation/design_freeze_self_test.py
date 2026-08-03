"""Mutation-style self-tests for the design freeze's fail-closed contracts."""

from __future__ import annotations

import ast
import tempfile
from pathlib import Path
from typing import Any, Callable

import yaml

from generate_effective_registry import (
    Checks,
    validate_ai_semantic_payload,
    validate_generator_parity,
)
from git_authority import (
    AUTHORITY_COMMIT_OID,
    AUTHORITY_TAG,
    AUTHORITY_TREE_OID,
    AUTHORITY_ZIP_SHA256,
)

from .design_freeze_authority import BASE_MIGRATION_COUNT, validate_authority_payload
from .design_freeze_contract import (
    BOOTSTRAP_REVIEW_ROLES,
    CLOSED,
    EXPECTED_ADDITIVE_MIGRATIONS,
    EXPECTED_ADDITIVE_ORDINALS,
    FOCUS_SOURCE_RE,
    REVIEW_ROLE_REGISTRY,
    SKIP_SOURCE_RE,
    ZERO_COMMAND_RE,
    safe_relative,
)
from .design_freeze_reviews import (
    _blocker_container_closed,
    _closed_blocker_value,
    _iter_blocker_containers,
    load_required_review_roles,
    validate_reviews,
)


def _valid_authority_payload() -> dict[str, object]:
    base_migrations = [
        f"{ordinal:04d}_base.sql"
        for ordinal in range(1, BASE_MIGRATION_COUNT + 1)
    ]
    return {
        "result": "PASS",
        "problem_count": 0,
        "stats": {
            "scope": "migrations",
            "authority_tag": AUTHORITY_TAG,
            "authority_commit_oid": AUTHORITY_COMMIT_OID,
            "authority_tree_oid": AUTHORITY_TREE_OID,
            "authority_path_count": 1,
            "authority_zip_sha256": AUTHORITY_ZIP_SHA256,
            "authority_spec_migrations": base_migrations,
            "worktree_spec_base_migrations": base_migrations,
            "runtime_base_migrations": base_migrations,
            "authority_spec_migration_mismatches": [],
            "runtime_base_migration_mismatches": [],
            "invalid_spec_migration_names": [],
            "invalid_runtime_migration_names": [],
            "duplicate_runtime_migration_ordinals": [],
            "authority_spec_migrations_matched": BASE_MIGRATION_COUNT,
            "runtime_base_migrations_matched": BASE_MIGRATION_COUNT,
            "pending_additive_ordinals": [],
            "unexpected_additive_ordinals": [],
            "pending_additive_migrations": [],
            "unexpected_additive_migrations": [],
            "allow_pending_additive": False,
            "expected_additive_ordinals": EXPECTED_ADDITIVE_ORDINALS,
            "expected_additive_migrations": list(EXPECTED_ADDITIVE_MIGRATIONS),
            "runtime_additive_migrations": list(EXPECTED_ADDITIVE_MIGRATIONS),
            "runtime_additive_migration_count": len(EXPECTED_ADDITIVE_MIGRATIONS),
            "expected_final_migration_count": BASE_MIGRATION_COUNT
            + len(EXPECTED_ADDITIVE_MIGRATIONS),
        },
    }

def _authority_stats(payload: dict[str, object]) -> dict[str, object] | None:
    stats = payload.get("stats")
    return stats if isinstance(stats, dict) else None

def _duplicate_fixture() -> bool:
    checks = Checks()
    checks.unique(["A", "A"], "bad-fixture")
    return any(problem.code == "duplicate_id" for problem in checks.problems)

def _set_fixture() -> bool:
    checks = Checks()
    checks.equal({"A"}, {"B"}, "bad-fixture", "left", "right")
    return any(problem.code == "set_equality" for problem in checks.problems)

def _count_fixture() -> bool:
    checks = Checks()
    checks.count(77, {str(index) for index in range(80)}, "bad-fixture")
    return any(problem.code == "declared_count" for problem in checks.problems)

def _status_blocker_fixture() -> bool:
    nested = {
        "required_operation_registry": {
            "status": CLOSED,
            "required_operations": {"still_open": {"severity": "P0"}},
        }
    }
    found = _iter_blocker_containers(nested)
    return (
        not _closed_blocker_value({"still_open": ["P0"]})
        and _closed_blocker_value(CLOSED)
        and len(found) == 1
        and not _blocker_container_closed(found[0][0], found[0][2])
    )

def _ai_semantic_fixture() -> bool:
    checks = Checks()
    validate_ai_semantic_payload(
        {"result": "PASS", "errors": ["semantic corruption"]},
        0,
        checks,
        "bad-ai.json",
    )
    return any(problem.code == "ai_semantic_schema" for problem in checks.problems)


def _generator_parity_fixture() -> bool:
    with tempfile.TemporaryDirectory(prefix="gurinnae-bad-generator-") as directory:
        root = Path(directory)
        script = root / "scripts/generate_bad.py"
        script.parent.mkdir(parents=True)
        script.write_text(
            "import argparse\n"
            "parser = argparse.ArgumentParser()\n"
            "parser.add_argument('--check', action='store_true')\n"
            "parser.parse_args()\n"
            "raise SystemExit(1)\n",
            encoding="utf-8",
        )
        checks = Checks()
        validate_generator_parity(root, checks)
        return any(
            problem.code == "generator_parity" for problem in checks.problems
        )


def _design_validator_call_graph_fixture() -> bool:
    coordinator = Path(__file__).with_name("design.py")
    tree = ast.parse(coordinator.read_text(encoding="utf-8"), filename=str(coordinator))
    required = {
        "load_design_documents",
        "validate_journey_graph",
        "validate_operations",
        "validate_lifecycle",
        "validate_persistence",
        "validate_ui",
        "validate_domain",
    }
    imported = {
        alias.name
        for node in ast.walk(tree)
        if isinstance(node, ast.ImportFrom)
        for alias in node.names
    }
    called = {
        node.func.id
        for node in ast.walk(tree)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
    }
    return required <= imported and required <= called


def _test_source_fixture() -> bool:
    return (
        SKIP_SOURCE_RE.search("test.skip('x', () => {})") is not None
        and FOCUS_SOURCE_RE.search("test.only('x', () => {})") is not None
    )


def _zero_command_fixture() -> bool:
    return ZERO_COMMAND_RE.search("bun test --list") is not None


def _unsafe_path_fixture() -> bool:
    return not safe_relative("../escape.spec.ts") and safe_relative(
        "tests/e2e/gate.spec.ts"
    )


def _missing_review_role_fixture() -> bool:
    with tempfile.TemporaryDirectory(prefix="gurinnae-bad-review-role-") as directory:
        root = Path(directory)
        registry = root / REVIEW_ROLE_REGISTRY
        registry.parent.mkdir(parents=True)
        registry.write_text(
            yaml.safe_dump(
                {
                    "schema_version": 1,
                    "canonical_role_count": len(BOOTSTRAP_REVIEW_ROLES),
                    "roles": [
                        {
                            "role": f"ROLE_{index}",
                            "aliases": [],
                            "blocking_question": "Does this role close its contract?",
                        }
                        for index in range(len(BOOTSTRAP_REVIEW_ROLES))
                    ],
                },
                sort_keys=False,
            ),
            encoding="utf-8",
        )
        checks = Checks()
        load_required_review_roles(root, checks)
        return any(
            problem.code == "review_role_bootstrap_lock"
            for problem in checks.problems
        )


def _mutated_authority_fixture(
    source: str,
    mutation: Callable[[dict[str, object]], None],
    expected_code: str | None,
) -> bool:
    payload = _valid_authority_payload()
    stats = _authority_stats(payload)
    if stats is None:
        return False
    mutation(stats)
    checks = Checks()
    validate_authority_payload(payload, 0, checks, source)
    if expected_code is None:
        return not checks.problems
    return any(problem.code == expected_code for problem in checks.problems)


def _archive_digest_fixture() -> bool:
    return _mutated_authority_fixture(
        "bad-authority.json",
        lambda stats: stats.__setitem__("authority_zip_sha256", "0" * 64),
        "authority_historical_identifier",
    )


def _tag_commit_fixture() -> bool:
    return _mutated_authority_fixture(
        "bad-authority-tag.json",
        lambda stats: stats.__setitem__("authority_commit_oid", "0" * 40),
        "authority_commit_oid",
    )


def _tag_tree_fixture() -> bool:
    return _mutated_authority_fixture(
        "bad-authority-tree.json",
        lambda stats: stats.__setitem__("authority_tree_oid", "0" * 40),
        "authority_tree_oid",
    )


def _base_migration_drift_fixture() -> bool:
    return _mutated_authority_fixture(
        "bad-base-migration.json",
        lambda stats: stats.__setitem__(
            "authority_spec_migrations_matched", BASE_MIGRATION_COUNT - 1
        ),
        "authority_spec_migration_lock",
    )


def _implementation_source_change_fixture() -> bool:
    def mutation(stats: dict[str, object]) -> None:
        stats.update(
            {
                "authority_worktree_matched": BASE_MIGRATION_COUNT - 1,
                "authority_worktree_missing": 0,
                "authority_worktree_mismatched": 1,
            }
        )

    return _mutated_authority_fixture(
        "implementation-change.json",
        mutation,
        None,
    )


def _migration_set_fixture() -> bool:
    return _mutated_authority_fixture(
        "bad-migrations.json",
        lambda stats: stats.__setitem__(
            "runtime_additive_migrations",
            [
                *EXPECTED_ADDITIVE_MIGRATIONS[:-1],
                f"{EXPECTED_ADDITIVE_MIGRATIONS[-1][:4]}_wrong_but_same_count.sql",
            ],
        ),
        "runtime_migration_set",
    )


def _migration_count_only_fixture() -> bool:
    def mutation(stats: dict[str, object]) -> None:
        stats.pop("expected_additive_migrations", None)
        stats.pop("runtime_additive_migrations", None)

    return _mutated_authority_fixture(
        "count-only-migrations.json",
        mutation,
        "runtime_migration_set",
    )


def _stale_review_fixture() -> bool:
    with tempfile.TemporaryDirectory(prefix="gurinnae-bad-review-") as directory:
        root = Path(directory)
        review = root / "implementation-evidence/reviews/final/pdm.yaml"
        review.parent.mkdir(parents=True)
        review.write_text(
            "schema_version: 1\n"
            "review_kind: DESIGN_FREEZE\n"
            "role: PDM\n"
            "verdict: LGTM\n"
            "design_bundle_sha256: stale\n",
            encoding="utf-8",
        )
        checks = Checks()
        validate_reviews(
            root,
            {
                "bundle_sha256": "current",
                "member_manifest_sha256": "members",
                "member_count": 1,
            },
            checks,
        )
        return any(
            problem.code == "stale_final_review" for problem in checks.problems
        )


def self_test() -> tuple[bool, list[dict[str, object]]]:
    results: list[dict[str, object]] = []
    fixtures: tuple[tuple[str, Callable[[], bool]], ...] = (
        ("duplicate-id.yaml", _duplicate_fixture),
        ("set-drift.yaml", _set_fixture),
        ("magic-count.yaml", _count_fixture),
        ("open-blocker.yaml", _status_blocker_fixture),
        ("ai-semantic-schema.json", _ai_semantic_fixture),
        ("stale-generator-output.py", _generator_parity_fixture),
        ("canonical-design-validator-call-graph.py", _design_validator_call_graph_fixture),
        ("skip-and-focus.spec.ts", _test_source_fixture),
        ("zero-test-command.yaml", _zero_command_fixture),
        ("unsafe-test-path.yaml", _unsafe_path_fixture),
        ("missing-human-approval-review-role.yaml", _missing_review_role_fixture),
        ("authority-archive-digest-drift.json", _archive_digest_fixture),
        ("authority-tag-commit-drift.json", _tag_commit_fixture),
        ("authority-tag-tree-drift.json", _tag_tree_fixture),
        ("authority-base-migration-drift.json", _base_migration_drift_fixture),
        ("ordinary-implementation-source-change.json", _implementation_source_change_fixture),
        ("runtime-migration-set-drift.json", _migration_set_fixture),
        ("runtime-migration-count-only.json", _migration_count_only_fixture),
        ("stale-review-digest.yaml", _stale_review_fixture),
    )
    for name, function in fixtures:
        results.append({"fixture": name, "contract_held": bool(function())})
    return all(row["contract_held"] for row in results), results
