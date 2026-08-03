from __future__ import annotations

from typing import Any

from .models import Validation
from .design_ui_journeys import validate_journey_ui


def design_screen_row(
    result: Validation,
    row_by: dict[str, dict[str, Any]],
    screen_id: str,
) -> dict[str, Any] | None:
    row = row_by.get(screen_id)
    result.require(row is not None, f"{screen_id}: screen is missing from design closure")
    return row


def validate_additive_operation_section_closure(
    result: Validation,
    screen_id: str,
    row_operations: dict[str, dict[str, Any]],
    additive_operations: dict[str, set[str]],
) -> None:
    for operation_id, section_ids in additive_operations.items():
        operation = row_operations.get(operation_id)
        result.require(
            operation is not None,
            f"{screen_id}.{operation_id}: additive operation is missing from design closure",
        )
        if operation is None:
            continue
        result.require(
            operation.get("source") == "owner-addendum"
            and set(operation.get("section_bindings", [])) == section_ids,
            f"{screen_id}.{operation_id}: additive operation section closure mismatch",
        )


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
