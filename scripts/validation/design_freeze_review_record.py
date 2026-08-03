"""Validation of one exact-digest independent design-freeze review record."""

from __future__ import annotations

import re
from datetime import datetime
from typing import Any

from generate_effective_registry import Checks
from git_authority import AUTHORITY_ZIP_SHA256

from .design_freeze_contract import CLOSED, ISO_TIME_RE


def validate_review_record(
    role: str,
    record: dict[str, Any],
    member_digest: object,
    member_count: object,
    reviewer_ids: list[str],
    retested: set[str],
    checks: Checks,
) -> None:
    checks.require(
        record.get("schema_version") == 1,
        "review_schema",
        role,
        1,
        record.get("schema_version"),
    )
    checks.require(
        record.get("verdict") == "LGTM",
        "review_verdict",
        role,
        "LGTM",
        record.get("verdict"),
    )
    checks.require(
        record.get("authority_zip_sha256") == AUTHORITY_ZIP_SHA256,
        "review_authority_digest",
        role,
        AUTHORITY_ZIP_SHA256,
        record.get("authority_zip_sha256"),
    )
    checks.require(
        record.get("member_manifest_sha256") == member_digest,
        "review_member_digest",
        role,
        member_digest,
        record.get("member_manifest_sha256"),
    )
    checks.require(
        record.get("reviewed_member_count") == member_count,
        "review_member_count",
        role,
        member_count,
        record.get("reviewed_member_count"),
    )
    checks.require(
        record.get("independent") is True,
        "review_independence",
        role,
        True,
        record.get("independent"),
    )
    reviewer_id = record.get("reviewer_id")
    checks.require(
        isinstance(reviewer_id, str) and bool(reviewer_id.strip()),
        "reviewer_id",
        role,
        "nonempty",
        reviewer_id,
    )
    if isinstance(reviewer_id, str) and reviewer_id.strip():
        reviewer_ids.append(reviewer_id.strip())
    reviewed_at = record.get("reviewed_at")
    valid_time = (
        isinstance(reviewed_at, str)
        and ISO_TIME_RE.fullmatch(reviewed_at) is not None
    ) or (isinstance(reviewed_at, datetime) and reviewed_at.tzinfo is not None)
    checks.require(
        valid_time,
        "reviewed_at",
        role,
        "ISO-8601 with timezone",
        reviewed_at.isoformat() if isinstance(reviewed_at, datetime) else reviewed_at,
    )
    checks.require(
        record.get("blocking_findings") == [],
        "review_blockers",
        role,
        [],
        record.get("blocking_findings"),
    )
    finding_retests = record.get("finding_retests")
    checks.require(
        isinstance(finding_retests, list),
        "finding_retests",
        role,
        "list",
        type(finding_retests).__name__,
    )
    for row in finding_retests if isinstance(finding_retests, list) else []:
        if not isinstance(row, dict) or not isinstance(row.get("finding_id"), str):
            checks.require(
                False,
                "finding_retest_row",
                role,
                "finding_id mapping",
                row,
            )
            continue
        finding_id = row["finding_id"]
        severity_match = re.search(r"-(P[0-3])-", finding_id)
        allowed = (
            {CLOSED}
            if severity_match and severity_match.group(1) in {"P0", "P1"}
            else {CLOSED, "ACCEPTED_NON_BLOCKING"}
        )
        checks.require(
            row.get("status") in allowed,
            "finding_retest_status",
            finding_id,
            sorted(allowed),
            row.get("status"),
        )
        evidence = row.get("evidence")
        checks.require(
            isinstance(evidence, str) and bool(evidence.strip()),
            "finding_retest_evidence",
            finding_id,
            "nonempty",
            evidence,
        )
        retested.add(finding_id)
