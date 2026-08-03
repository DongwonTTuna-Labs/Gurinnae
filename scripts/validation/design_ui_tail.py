from __future__ import annotations

import hashlib
from typing import Any

from .design_support import nonempty


def validate_ui_tail(
    result: Any,
    rows: list[dict[str, Any]],
    catalog_by: dict[str, dict[str, Any]],
    operations: Any,
    route_contract: dict[str, Any],
    search: dict[str, Any],
) -> None:
    section_rows = [section for row in rows for section in row["section_mapping"]]
    expected_section_count = sum(len(screen.get("sections", [])) for screen in catalog_by.values())
    result.require(
        len(section_rows) == expected_section_count
        and all(nonempty(section.get("source_fields")) for section in section_rows)
        and all(nonempty(section.get("component_variant")) for section in section_rows),
        f"{expected_section_count}-section source/component/variant closure is incomplete",
    )
    for question in ("state", "matters_now", "evidence", "unknown_or_disputed"):
        result.require(
            len({row["ten_second_contract"][question]["answer_pattern"] for row in rows})
            == len(catalog_by),
            f"ten-second {question} answer is still generic across screens",
        )
    user_copy = "\n".join(
        answer["answer_pattern"]
        for row in rows
        for answer in row["ten_second_contract"].values()
    )
    result.require(
        "executes " not in user_copy
        and "navigates " not in user_copy
        and not any(operation_id in user_copy for operation_id in operations.operation_ids),
        "ten-second user copy exposes internal operation language",
    )
    for screen_id, route in route_contract["canonical_overrides"].items():
        result.require(
            catalog_by[screen_id]["route"] == route,
            f"{screen_id}: canonical token-free route mismatch",
        )
    result.require(
        route_contract["corrected_redirect"]
        == {"from": "/cases/{caseSlug}/history", "to": "/cases/{caseSlug}#revision", "status": 308},
        "case history redirect resolution mismatch",
    )
    typed_slices = search["screen_typed_slices"]
    ten_second_sections = search["screen_ten_second_sections"]
    result.require(
        set(typed_slices) == set(ten_second_sections) == {"PUB-002", "INT-003", "PUB-004", "CAS-004"},
        "search/provenance typed-screen set mismatch",
    )
    for screen_id, slices in typed_slices.items():
        row = next(row for row in rows if row["screen_id"] == screen_id)
        section_by = {section["id"]: section for section in row["section_mapping"]}
        result.require(set(section_by) == set(slices), f"{screen_id}: typed slice section set mismatch")
        result.require(
            row.get("typed_source_contract") == "owner-addendum.search_and_provenance_contract",
            f"{screen_id}: typed source contract marker missing",
        )
        for section_id, fields in slices.items():
            result.require(
                section_by[section_id].get("source_fields") == fields,
                f"{screen_id}.{section_id}: typed source fields mismatch",
            )
        for question, section_id in ten_second_sections[screen_id].items():
            answer = row["ten_second_contract"][question]
            result.require(answer["section"] == section_id, f"{screen_id}.{question}: typed section mismatch")
            if question != "location":
                result.require(
                    answer["sources"] == slices[section_id],
                    f"{screen_id}.{question}: typed question sources mismatch",
                )
