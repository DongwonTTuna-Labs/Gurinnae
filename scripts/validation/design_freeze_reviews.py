"""Normative-state and independent-review checks for the design freeze."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from generate_effective_registry import Checks

from .design_freeze_contract import (
    BLOCKER_KEYS,
    BOOTSTRAP_REVIEW_ROLES,
    CLOSED,
    CONFLICT_STATUS_RE,
    DESIGN_STATUS_RE,
    FINAL_STATUS,
    FINDING_HEADING_RE,
    NORMATIVE_CATEGORIES,
    REVIEW_ROLE_REGISTRY,
    load_mapping,
)
from .design_freeze_review_record import validate_review_record


def _closed_blocker_value(value: object) -> bool:
    if value is None or value == [] or value == {}:
        return True
    if isinstance(value, str):
        return value == CLOSED
    if isinstance(value, list):
        return all(_closed_blocker_value(item) for item in value)
    if isinstance(value, dict):
        if "status" in value:
            return value.get("status") == CLOSED
        return all(_closed_blocker_value(item) for item in value.values())
    return False


def _normative_category(value: object) -> bool:
    return isinstance(value, str) and (
        value in NORMATIVE_CATEGORIES or value.endswith("_addenda")
    )


def _is_blocker_key(value: object) -> bool:
    if not isinstance(value, str):
        return False
    normalized = value.lower()
    return (
        normalized in BLOCKER_KEYS
        or normalized == "required_operation_registry"
        or normalized.startswith("blockers_")
        or (
            normalized.endswith("_blockers")
            and not normalized.startswith(("closed_", "resolved_"))
        )
    )


def _iter_blocker_containers(
    value: object,
    path: str = "",
) -> list[tuple[str, str, object]]:
    # The release contract governs top-level design-closure registries. A
    # nested schema property or domain field named blockers is data vocabulary.
    found: list[tuple[str, str, object]] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if _is_blocker_key(key):
                found.append((str(key), f"{path}/{key}", child))
    return found


def _blocker_container_closed(key: str, value: object) -> bool:
    if key == "required_operation_registry" and isinstance(value, dict):
        return (
            value.get("status") == CLOSED
            and value.get("required_operations") in ({}, [])
        )
    return _closed_blocker_value(value)


def validate_normative_statuses(
    root: Path,
    manifest: dict[str, object],
    checks: Checks,
) -> None:
    members = manifest.get("members", [])
    for member in members if isinstance(members, list) else []:
        if not isinstance(member, dict) or not _normative_category(
            member.get("category")
        ):
            continue
        relative = member.get("path")
        if not isinstance(relative, str):
            checks.require(
                False,
                "invalid_member",
                "design manifest",
                "path",
                member,
            )
            continue
        path = root / relative
        suffix = path.suffix.lower()
        if suffix == ".md":
            match = DESIGN_STATUS_RE.search(path.read_text(encoding="utf-8"))
            if relative == "DESIGN.md" or member.get("category") in {
                "freeze_contract",
                "business_addenda",
            }:
                checks.require(
                    match is not None and match.group(1) == FINAL_STATUS,
                    "normative_status",
                    relative,
                    FINAL_STATUS,
                    match.group(1) if match else "MISSING",
                )
            continue
        if suffix not in {".yaml", ".yml"}:
            continue
        document = load_mapping(path, checks, relative)
        status = document.get("status")
        allowed_absent = member.get("category") == "authority_base_proof"
        if status is None and allowed_absent:
            continue
        checks.require(
            status == FINAL_STATUS,
            "normative_status",
            relative,
            FINAL_STATUS,
            status if status is not None else "MISSING",
        )
        for key, blocker_path, value in _iter_blocker_containers(document):
            checks.require(
                _blocker_container_closed(key, value),
                "open_blocker",
                f"{relative}#{blocker_path}",
                f"empty or {CLOSED}",
                value,
            )

    conflicts_path = root / "implementation-evidence/spec-conflicts.md"
    try:
        conflicts = conflicts_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        checks.require(
            False,
            "conflict_registry",
            str(conflicts_path),
            "readable",
            str(error),
        )
        return
    statuses = CONFLICT_STATUS_RE.findall(conflicts)
    checks.require(
        bool(statuses),
        "conflict_registry",
        "spec-conflicts.md",
        ">=1 status",
        0,
    )
    checks.require(
        all(status == CLOSED for status in statuses),
        "open_conflict",
        "spec-conflicts.md",
        CLOSED,
        sorted(set(statuses) - {CLOSED}),
    )


def _prior_finding_ids(root: Path, checks: Checks) -> set[str]:
    findings: list[str] = []
    for path in sorted((root / "implementation-evidence/reviews").glob("**/*.md")):
        try:
            findings.extend(
                FINDING_HEADING_RE.findall(path.read_text(encoding="utf-8"))
            )
        except (OSError, UnicodeError) as error:
            checks.require(
                False,
                "review_history",
                str(path),
                "readable UTF-8",
                str(error),
            )
    return checks.unique(findings, "prior review finding IDs")


def load_required_review_roles(root: Path, checks: Checks) -> frozenset[str]:
    path = root / REVIEW_ROLE_REGISTRY
    document = load_mapping(path, checks, REVIEW_ROLE_REGISTRY)
    checks.require(
        document.get("schema_version") == 1,
        "review_role_registry_schema",
        REVIEW_ROLE_REGISTRY,
        1,
        document.get("schema_version"),
    )
    entries = document.get("roles")
    if not isinstance(entries, list):
        checks.require(
            False,
            "review_role_registry",
            REVIEW_ROLE_REGISTRY,
            "roles list",
            type(entries).__name__,
        )
        return frozenset()
    role_rows = [entry for entry in entries if isinstance(entry, dict)]
    checks.require(
        len(role_rows) == len(entries),
        "review_role_registry",
        f"{REVIEW_ROLE_REGISTRY}#roles",
        "mapping rows",
        entries,
    )
    role_ids = checks.unique(
        [entry.get("role") for entry in role_rows],
        "canonical expert review roles",
    )
    checks.require(
        all(re.fullmatch(r"[A-Z][A-Z0-9_]*", role) for role in role_ids),
        "review_role_id",
        REVIEW_ROLE_REGISTRY,
        "uppercase canonical role IDs",
        sorted(role_ids),
    )
    checks.require(
        BOOTSTRAP_REVIEW_ROLES <= role_ids,
        "review_role_bootstrap_lock",
        REVIEW_ROLE_REGISTRY,
        sorted(BOOTSTRAP_REVIEW_ROLES),
        {
            "missing": sorted(BOOTSTRAP_REVIEW_ROLES - role_ids),
            "declared": sorted(role_ids),
        },
    )
    declared_count = document.get("canonical_role_count")
    checks.require(
        type(declared_count) is int,
        "review_role_registry_count_type",
        REVIEW_ROLE_REGISTRY,
        "integer canonical_role_count",
        declared_count,
    )
    checks.count(declared_count, role_ids, "canonical expert review role count")
    checks.require(
        isinstance(declared_count, int)
        and declared_count >= len(BOOTSTRAP_REVIEW_ROLES),
        "review_role_bootstrap_count",
        REVIEW_ROLE_REGISTRY,
        f">={len(BOOTSTRAP_REVIEW_ROLES)}",
        declared_count,
    )
    aliases: list[str] = []
    for entry in role_rows:
        question = entry.get("blocking_question")
        checks.require(
            isinstance(question, str) and bool(question.strip()),
            "review_role_question",
            f"{REVIEW_ROLE_REGISTRY}#{entry.get('role')}",
            "nonempty blocking question",
            question,
        )
        row_aliases = entry.get("aliases", [])
        checks.require(
            isinstance(row_aliases, list),
            "review_role_aliases",
            f"{REVIEW_ROLE_REGISTRY}#{entry.get('role')}",
            "alias list",
            type(row_aliases).__name__,
        )
        if isinstance(row_aliases, list):
            aliases.extend(row_aliases)
    alias_ids = checks.unique(aliases, "expert review role aliases")
    checks.require(
        not (role_ids & alias_ids),
        "review_role_alias_collision",
        REVIEW_ROLE_REGISTRY,
        [],
        sorted(role_ids & alias_ids),
    )
    return frozenset(role_ids)


def validate_reviews(
    root: Path,
    manifest: dict[str, object],
    checks: Checks,
) -> None:
    required_roles = load_required_review_roles(root, checks)
    bundle_digest = manifest.get("bundle_sha256")
    member_digest = manifest.get("member_manifest_sha256")
    member_count = manifest.get("member_count")
    records_by_role: dict[str, list[dict[str, Any]]] = {}
    final_directory = root / "implementation-evidence/reviews/final"
    review_paths = sorted(
        set(final_directory.glob("*.yaml")) | set(final_directory.glob("*.yml"))
    )
    review_records: list[tuple[Path, dict[str, Any]]] = []
    for path in review_paths:
        if path.is_symlink() or not path.is_file():
            checks.require(
                False,
                "review_file_type",
                str(path),
                "regular file",
                "non-regular",
            )
            continue
        relative = path.relative_to(root).as_posix()
        document = load_mapping(path, checks, relative)
        if document.get("review_kind") != "DESIGN_FREEZE":
            checks.require(
                False,
                "review_kind",
                str(path),
                "DESIGN_FREEZE",
                document.get("review_kind"),
            )
            continue
        review_records.append((path, document))
        record_digest = document.get("design_bundle_sha256")
        checks.require(
            record_digest == bundle_digest,
            "stale_final_review",
            relative,
            bundle_digest,
            record_digest,
        )
        role = document.get("role")
        if isinstance(role, str) and role.strip():
            records_by_role.setdefault(role, []).append(document)
        else:
            checks.require(False, "review_role", str(path), "nonempty role", role)

    checks.equal(
        required_roles,
        set(records_by_role),
        "required independent review roles",
        "required",
        "current records",
    )
    _validate_review_records(
        root,
        required_roles,
        records_by_role,
        review_records,
        bundle_digest,
        member_digest,
        member_count,
        checks,
    )


def _validate_review_records(
    root: Path,
    required_roles: frozenset[str],
    records_by_role: dict[str, list[dict[str, Any]]],
    review_records: list[tuple[Path, dict[str, Any]]],
    bundle_digest: object,
    member_digest: object,
    member_count: object,
    checks: Checks,
) -> None:
    retested: set[str] = set()
    reviewer_ids: list[str] = []
    for role, records in records_by_role.items():
        checks.require(len(records) == 1, "duplicate_review", role, 1, len(records))
        for record in records:
            validate_review_record(
                role,
                record,
                member_digest,
                member_count,
                reviewer_ids,
                retested,
                checks,
            )
    prior = _prior_finding_ids(root, checks)
    checks.subset(prior, retested, "prior finding retest coverage")
    checks.require(
        len(reviewer_ids) == len(set(reviewer_ids)) == len(required_roles),
        "reviewer_independence",
        "current reviews",
        "one distinct reviewer_id per required role",
        reviewer_ids,
    )
    current_digests = {
        record.get("design_bundle_sha256") for _, record in review_records
    }
    checks.require(
        current_digests == {bundle_digest},
        "review_digest_split",
        "current reviews",
        [bundle_digest],
        sorted(str(value) for value in current_digests),
    )
