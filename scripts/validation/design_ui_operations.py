from __future__ import annotations

from typing import Any

from .models import Validation
from .design_ui_journeys import validate_journey_ui


def validate_section_operations(
    result: Validation,
    screen_id: str,
    row: dict[str, Any],
    operations_by_screen: dict[str, dict[str, set[str]]],
    contracted_operations: list[dict[str, Any]],
) -> None:
    for section in row["section_mapping"]:
        expected_query = {
            operation_id
            for operation_id, section_ids in operations_by_screen.get(
                screen_id, {}
            ).items()
            if section["id"] in section_ids
            and next(
                operation
                for operation in contracted_operations
                if operation["operation_id"] == operation_id
            )["kind"]
            == "QUERY"
        }
        expected_command = {
            operation_id
            for operation_id, section_ids in operations_by_screen.get(
                screen_id, {}
            ).items()
            if section["id"] in section_ids
            and next(
                operation
                for operation in contracted_operations
                if operation["operation_id"] == operation_id
            )["kind"]
            == "COMMAND"
        }
        result.require(
            set(section.get("additive_query_operations", [])) == expected_query
            and set(section.get("additive_command_operations", []))
            == expected_command,
            f"{screen_id}.{section['id']}: additive section operation mismatch",
        )
