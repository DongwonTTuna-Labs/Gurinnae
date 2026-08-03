"""Shared fail-closed contracts for the design freeze validators."""

from __future__ import annotations

import re
from pathlib import Path, PurePosixPath
from typing import Any

import yaml

from generate_effective_registry import Checks, UniqueKeyLoader
from verify_migrations import EXPECTED_ADDITIVE_MIGRATIONS


REVIEW_ROLE_REGISTRY = "implementation-evidence/expert-review-roles.yaml"
BOOTSTRAP_REVIEW_ROLES = frozenset(
    {
        "PDM",
        "PRODUCT_DESIGN",
        "ACCESSIBILITY_RESPONSIVE",
        "BUSINESS_MODEL",
        "AI_MULTIMODAL_RESEARCH",
        "DATA_VISUALIZATION",
        "DATABASE",
        "COMMAND_EVENT_LIFECYCLE",
        "HUMAN_APPROVAL",
        "OMNICHANNEL_SESSION",
        "SRE_FINOPS",
        "TRUST_PRIVACY_LEGAL",
        "QA_TRACEABILITY",
        "PROCUREMENT_DOMAIN",
    }
)
NORMATIVE_CATEGORIES = frozenset(
    {
        "product_constitution",
        "design_closure_evidence",
        "freeze_contract",
        "database_addenda",
        "product_addenda",
        "ui_addenda",
        "agent_addenda",
        "parser_addenda",
        "submission_addenda",
        "business_addenda",
        "supplemental_acceptance",
    }
)
BLOCKER_KEYS = frozenset(
    {
        "blockers",
        "known_blockers",
        "remaining_blockers",
        "design_blockers",
        "release_blockers",
        "open_decisions",
    }
)
FINAL_STATUS = "FINAL"
CLOSED = "CLOSED_CURRENT_TRUTH"
EXPECTED_ADDITIVE_ORDINALS = [
    int(migration_name[:4]) for migration_name in EXPECTED_ADDITIVE_MIGRATIONS
]
FINDING_HEADING_RE = re.compile(
    r"^#{2,6}\s+([A-Z][A-Z0-9-]*-[0-9]{3})\b", re.MULTILINE
)
CONFLICT_STATUS_RE = re.compile(
    r"^- Status:\s*`?([A-Z][A-Z0-9_]*)`?\.?\s*$", re.MULTILINE
)
DESIGN_STATUS_RE = re.compile(
    r"^Status:\s*`?([A-Z][A-Z0-9_]*)`?", re.MULTILINE
)
ISO_TIME_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:[0-9:.]+(?:Z|[+-]\d{2}:\d{2})$"
)
SKIP_SOURCE_RE = re.compile(
    r"(?m)(?:\b(?:test|it|describe)\.(?:skip|fixme|todo)\s*\(|"
    r"#\s*\[ignore(?:\([^]]*\))?\]|pytest\.mark\.skip\b|"
    r"unittest\.skip\s*\(|@Ignore\b|@Disabled\b)"
)
FOCUS_SOURCE_RE = re.compile(
    r"(?m)\b(?:test|it|describe)\.only\s*\(|@focus\b|@focused\b"
)
ZERO_COMMAND_RE = re.compile(
    r"(?:^|\s)(?:--list|--collect-only|--dry-run|--passWithNoTests|"
    r"--allow-no-tests)(?:\s|$)"
)


def safe_relative(value: str) -> bool:
    path = PurePosixPath(value)
    return bool(
        value
        and "\\" not in value
        and not path.is_absolute()
        and ".." not in path.parts
    )


def load_mapping(path: Path, checks: Checks, source: str) -> dict[str, Any]:
    try:
        value = yaml.load(path.read_text(encoding="utf-8"), Loader=UniqueKeyLoader)
    except (OSError, UnicodeError, yaml.YAMLError, ValueError) as error:
        checks.require(
            False,
            "invalid_document",
            source,
            "unique-key YAML/JSON",
            str(error),
        )
        return {}
    if not isinstance(value, dict):
        checks.require(
            False,
            "invalid_document",
            source,
            "mapping",
            type(value).__name__,
        )
        return {}
    return value
