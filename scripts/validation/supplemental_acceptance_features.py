"""Feature parsing for supplemental acceptance authority."""
from __future__ import annotations

from pathlib import Path

from .supplemental_acceptance_core import (
    Checks,
    ID_LINE,
    ID_RE,
    SCENARIO_LINE,
    Scenario,
)

def feature_tags(text: str) -> set[str]:
    first = next((line.strip() for line in text.splitlines() if line.strip()), "")
    return {token for token in first.split() if token.startswith("@")}


def all_tag_lines(text: str) -> set[str]:
    return {
        token
        for line in text.splitlines()
        if line.strip().startswith("@")
        for token in line.strip().split()
        if token.startswith("@")
    }


def parse_feature(
    path: Path,
    relative: str,
    checks: Checks,
    *,
    supplemental: bool,
) -> list[Scenario]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        checks.need(False, "feature_unreadable", relative, "UTF-8", str(error))
        return []

    tags = feature_tags(text)
    all_tags = all_tag_lines(text)
    required_tags = {"@hard-gate", "@final"}
    if supplemental:
        required_tags.add("@supplemental")
    checks.need(
        required_tags <= tags,
        "missing_final_tag",
        relative,
        sorted(required_tags),
        sorted(tags),
    )
    forbidden_skip = {
        "@skip",
        "@skipped",
        "@ignore",
        "@disabled",
        "@pending",
        "@wip",
        "@todo",
    }
    forbidden_focus = {"@focus", "@focused", "@only"}
    checks.need(
        not (all_tags & forbidden_skip),
        "skipped_feature",
        relative,
        "no skip/pending tag",
        sorted(all_tags & forbidden_skip),
    )
    checks.need(
        not (all_tags & forbidden_focus),
        "focused_feature",
        relative,
        "no focus/only tag",
        sorted(all_tags & forbidden_focus),
    )

    rows: list[Scenario] = []
    pending: tuple[str, int] | None = None
    headings = 0
    for line_number, line in enumerate(text.splitlines(), 1):
        id_match = ID_LINE.match(line)
        if id_match:
            checks.need(
                pending is None,
                "orphan_scenario_id",
                f"{relative}:{line_number}",
                "prior ID consumed",
                pending[0] if pending else None,
            )
            pending = (id_match.group(1), line_number)
            continue
        scenario_match = SCENARIO_LINE.match(line)
        if not scenario_match:
            continue
        headings += 1
        checks.need(
            pending is not None,
            "missing_scenario_id",
            f"{relative}:{line_number}",
            "stable ID",
            scenario_match.group(1),
        )
        if pending is not None:
            scenario_id, id_line = pending
            checks.need(
                ID_RE.fullmatch(scenario_id) is not None,
                "unstable_scenario_id",
                f"{relative}:{id_line}",
                "AC-<DOMAIN>-NNN",
                scenario_id,
            )
            rows.append(
                Scenario(
                    scenario_id=scenario_id,
                    feature_file=relative,
                    scenario_title=scenario_match.group(1).strip(),
                )
            )
        pending = None
    checks.need(
        pending is None,
        "orphan_scenario_id",
        relative,
        "ID consumed",
        pending[0] if pending else None,
    )
    checks.need(
        headings > 0,
        "zero_scenario_feature",
        relative,
        ">=1 Scenario",
        headings,
    )
    checks.unique((row.scenario_id for row in rows), relative)
    return rows


