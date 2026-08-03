"""Pinned Git-tag authority and additive-migration checks for design freeze."""

from __future__ import annotations

import re
from dataclasses import asdict
from pathlib import Path, PurePosixPath

from generate_effective_registry import Checks
from git_authority import (
    AUTHORITY_COMMIT_OID,
    AUTHORITY_TAG,
    AUTHORITY_TREE_OID,
    AUTHORITY_ZIP_SHA256,
    AuthorityIdentity,
    GitAuthorityError,
    authority_file,
    authority_paths,
    head_commit_oid,
    resolve_authority,
)

from .design_freeze_contract import (
    EXPECTED_ADDITIVE_MIGRATIONS,
    EXPECTED_ADDITIVE_ORDINALS,
)


BASE_MIGRATION_COUNT = 24
MIGRATION_RE = re.compile(r"^(?P<ordinal>[0-9]{4})_[a-z0-9_]+\.sql$")
TAG_MIGRATION_PREFIX = "specs/database/migrations/"


def _migration_files(directory: Path) -> tuple[dict[str, Path], list[str]]:
    files: dict[str, Path] = {}
    invalid: list[str] = []
    if directory.is_symlink() or not directory.is_dir():
        return files, ["<directory missing or non-regular>"]
    for path in sorted(directory.iterdir()):
        if path.is_symlink() or not path.is_file():
            invalid.append(path.name)
            continue
        if MIGRATION_RE.fullmatch(path.name) is None:
            if path.suffix == ".sql":
                invalid.append(path.name)
            continue
        files[path.name] = path
    return files, invalid


def _duplicate_ordinals(names: list[str]) -> list[int]:
    ordinals = [int(name[:4]) for name in names]
    return sorted({ordinal for ordinal in ordinals if ordinals.count(ordinal) > 1})


def _read_regular(path: Path | None) -> bytes | None:
    if path is None or path.is_symlink() or not path.is_file():
        return None
    return path.read_bytes()


def _tag_migrations(
    root: Path,
) -> tuple[AuthorityIdentity, frozenset[str], dict[str, str]]:
    identity = resolve_authority(root)
    tag_paths = authority_paths(root)
    tag_migrations = {
        PurePosixPath(relative).name: relative
        for relative in tag_paths
        if relative.startswith(TAG_MIGRATION_PREFIX)
        and MIGRATION_RE.fullmatch(PurePosixPath(relative).name)
    }
    return identity, tag_paths, tag_migrations


def _mismatch_names(
    root: Path,
    tag_migrations: dict[str, str],
    files: dict[str, Path],
) -> list[str]:
    mismatches: list[str] = []
    for name, relative in sorted(tag_migrations.items()):
        if _read_regular(files.get(name)) != authority_file(relative, root):
            mismatches.append(name)
    return mismatches


def _additive_stats(runtime_additive_names: list[str]) -> dict[str, object]:
    expected_names = list(EXPECTED_ADDITIVE_MIGRATIONS)
    expected_name_set = set(expected_names)
    actual_name_set = set(runtime_additive_names)
    actual_ordinals = {int(name[:4]) for name in runtime_additive_names}
    expected_ordinals = set(EXPECTED_ADDITIVE_ORDINALS)
    return {
        "expected_additive_ordinals": list(EXPECTED_ADDITIVE_ORDINALS),
        "expected_additive_migrations": expected_names,
        "runtime_additive_migrations": runtime_additive_names,
        "runtime_additive_migration_count": len(runtime_additive_names),
        "pending_additive_ordinals": sorted(expected_ordinals - actual_ordinals),
        "unexpected_additive_ordinals": sorted(actual_ordinals - expected_ordinals),
        "pending_additive_migrations": sorted(expected_name_set - actual_name_set),
        "unexpected_additive_migrations": sorted(actual_name_set - expected_name_set),
        "allow_pending_additive": False,
        "expected_final_migration_count": BASE_MIGRATION_COUNT + len(expected_names),
    }


def _build_authority_stats(root: Path) -> dict[str, object]:
    root = root.resolve()
    identity, tag_paths, tag_migrations = _tag_migrations(root)
    tag_names = sorted(tag_migrations)

    spec_files, spec_invalid = _migration_files(root / "specs/database/migrations")
    runtime_files, runtime_invalid = _migration_files(root / "db/migrations")
    spec_names = sorted(spec_files)
    runtime_names = sorted(runtime_files)
    runtime_base_names = sorted(
        name for name in runtime_names if int(name[:4]) <= BASE_MIGRATION_COUNT
    )
    runtime_additive_names = sorted(
        name for name in runtime_names if int(name[:4]) > BASE_MIGRATION_COUNT
    )
    spec_mismatches = _mismatch_names(root, tag_migrations, spec_files)
    runtime_mismatches = _mismatch_names(root, tag_migrations, runtime_files)
    return {
        "scope": "migrations",
        "authority_tag": identity.tag,
        "authority_commit_oid": identity.commit_oid,
        "authority_tree_oid": identity.tree_oid,
        "authority_path_count": len(tag_paths),
        "head_commit_oid": head_commit_oid(root),
        # Kept only for old review/receipt schema identity. It is not tree proof.
        "authority_zip_sha256": AUTHORITY_ZIP_SHA256,
        "authority_spec_migrations": tag_names,
        "worktree_spec_base_migrations": spec_names,
        "runtime_base_migrations": runtime_base_names,
        "authority_spec_migration_mismatches": spec_mismatches,
        "runtime_base_migration_mismatches": runtime_mismatches,
        "authority_spec_migrations_matched": len(tag_names) - len(spec_mismatches),
        "runtime_base_migrations_matched": len(tag_names) - len(runtime_mismatches),
        "invalid_spec_migration_names": spec_invalid,
        "invalid_runtime_migration_names": runtime_invalid,
        "duplicate_runtime_migration_ordinals": _duplicate_ordinals(runtime_names),
        **_additive_stats(runtime_additive_names),
    }


def build_authority_payload(root: Path) -> dict[str, object]:
    """Build a migration receipt using only the pinned tag and current files."""

    stats = _build_authority_stats(root)
    internal = Checks()
    _validate_authority_stats(stats, internal, f"git tag {AUTHORITY_TAG}")
    return {
        "result": "PASS" if not internal.problems else "FAIL",
        "problem_count": len(internal.problems),
        "stats": stats,
        "problems": [asdict(problem) for problem in internal.problems],
    }


def _validate_authority_identity(
    stats: dict[str, object],
    checks: Checks,
    source: str,
) -> None:
    checks.require(
        stats.get("scope") == "migrations",
        "authority_gate_scope",
        source,
        "migrations",
        stats.get("scope"),
    )
    for key, expected, code in (
        ("authority_tag", AUTHORITY_TAG, "authority_tag_identity"),
        (
            "authority_commit_oid",
            AUTHORITY_COMMIT_OID,
            "authority_commit_oid",
        ),
        ("authority_tree_oid", AUTHORITY_TREE_OID, "authority_tree_oid"),
        (
            "authority_zip_sha256",
            AUTHORITY_ZIP_SHA256,
            "authority_historical_identifier",
        ),
    ):
        checks.require(
            stats.get(key) == expected,
            code,
            source,
            expected,
            stats.get(key),
        )
    path_count = stats.get("authority_path_count")
    checks.require(
        isinstance(path_count, int) and path_count > 0,
        "authority_path_set",
        source,
        ">0 paths from tag",
        path_count,
    )


def _validate_base_migrations(
    stats: dict[str, object],
    checks: Checks,
    source: str,
) -> None:
    authority_names = stats.get("authority_spec_migrations")
    spec_names = stats.get("worktree_spec_base_migrations")
    runtime_base_names = stats.get("runtime_base_migrations")
    checks.require(
        isinstance(authority_names, list)
        and len(authority_names) == BASE_MIGRATION_COUNT
        and len(authority_names) == len(set(authority_names)),
        "authority_migration_set",
        source,
        f"{BASE_MIGRATION_COUNT} unique tag migrations",
        authority_names,
    )
    if isinstance(authority_names, list):
        checks.require(
            spec_names == authority_names,
            "authority_spec_migration_set",
            source,
            authority_names,
            spec_names,
        )
        checks.require(
            runtime_base_names == authority_names,
            "runtime_base_migration_set",
            source,
            authority_names,
            runtime_base_names,
        )
    for key, code in (
        ("authority_spec_migration_mismatches", "authority_spec_migration_lock"),
        ("runtime_base_migration_mismatches", "runtime_base_migration_lock"),
        ("invalid_spec_migration_names", "spec_migration_name"),
        ("invalid_runtime_migration_names", "runtime_migration_name"),
        ("duplicate_runtime_migration_ordinals", "runtime_migration_ordinal"),
    ):
        checks.require(stats.get(key) == [], code, source, [], stats.get(key))
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


def _validate_additive_migrations(
    stats: dict[str, object],
    checks: Checks,
    source: str,
) -> None:
    expected_additive = list(EXPECTED_ADDITIVE_MIGRATIONS)
    checks.require(
        stats.get("expected_additive_migrations") == expected_additive
        and stats.get("runtime_additive_migrations") == expected_additive,
        "runtime_migration_set",
        source,
        expected_additive,
        {
            "expected": stats.get("expected_additive_migrations"),
            "runtime": stats.get("runtime_additive_migrations"),
        },
    )
    checks.require(
        stats.get("expected_additive_ordinals") == EXPECTED_ADDITIVE_ORDINALS,
        "runtime_migration_ordinals",
        source,
        EXPECTED_ADDITIVE_ORDINALS,
        stats.get("expected_additive_ordinals"),
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
    checks.require(
        stats.get("runtime_additive_migration_count") == len(expected_additive)
        and stats.get("expected_final_migration_count")
        == BASE_MIGRATION_COUNT + len(expected_additive),
        "runtime_migration_count_witness",
        source,
        {
            "runtime_additive_migration_count": len(expected_additive),
            "expected_final_migration_count": BASE_MIGRATION_COUNT
            + len(expected_additive),
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


def _validate_authority_stats(
    stats: dict[str, object],
    checks: Checks,
    source: str,
) -> None:
    _validate_authority_identity(stats, checks, source)
    _validate_base_migrations(stats, checks, source)
    _validate_additive_migrations(stats, checks, source)


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
    stats = payload.get("stats")
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
    _validate_authority_stats(stats, checks, source)


def validate_authority_gate(
    root: Path,
    checks: Checks,
) -> None:
    source = f"git tag {AUTHORITY_TAG}"
    try:
        payload = build_authority_payload(root)
    except (GitAuthorityError, OSError, UnicodeError) as error:
        checks.require(
            False,
            "authority_tag",
            source,
            "readable pinned Git tag and migration paths",
            str(error),
        )
        return
    validate_authority_payload(payload, 0, checks, source)
