from __future__ import annotations

import re
from typing import Any

from .models import Validation


def _rows(document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    raw = document.get("tables", document.get("table_contracts", {}))
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, list):
        return {row["relation"]: row for row in raw}
    return {}


def _column_names(row: dict[str, Any]) -> list[str]:
    columns = row.get("columns")
    if isinstance(columns, dict):
        return list(columns)
    if isinstance(columns, list):
        return [column["name"] for column in columns]
    return []


def _constraint_rows(row: dict[str, Any], *keys: str) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    constraints = row.get("constraints", {})
    for key in keys:
        for source in (row.get(key), constraints.get(key)):
            if isinstance(source, list):
                values.extend(item for item in source if isinstance(item, dict))
    return values


def _key_columns(value: Any) -> tuple[str, ...]:
    if isinstance(value, list):
        return tuple(str(column) for column in value)
    if isinstance(value, dict) and isinstance(value.get("columns"), list):
        return tuple(str(column) for column in value["columns"])
    return ()


def _candidate_keys(row: dict[str, Any]) -> set[tuple[str, ...]]:
    constraints = row.get("constraints", {})
    candidates = {
        key
        for key in (
            _key_columns(row.get("primary_key", constraints.get("primary_key"))),
        )
        if key
    }
    for unique in _constraint_rows(row, "uniques", "unique", "unique_constraints"):
        columns = _key_columns(unique.get("columns"))
        if columns and not unique.get("where") and not unique.get("predicate"):
            candidates.add(columns)
    return candidates


def _added_columns(
    document: dict[str, Any],
    rows: dict[str, dict[str, Any]],
    result: Validation,
) -> dict[str, tuple[str, ...]]:
    changes = document.get("existing_relation_changes")
    result.require(
        isinstance(changes, list),
        "forward existing_relation_changes must be a list",
    )
    if not isinstance(changes, list):
        return {}

    additions: dict[str, tuple[str, ...]] = {}
    for change_index, change in enumerate(changes, 1):
        if not isinstance(change, dict) or "added_columns" not in change:
            continue
        relation = change.get("relation")
        relation_valid = isinstance(relation, str) and relation in rows
        result.require(
            relation_valid,
            f"forward added columns change {change_index} targets an unknown relation {relation!r}",
        )
        raw_columns = change.get("added_columns")
        columns_valid = isinstance(raw_columns, list) and bool(raw_columns)
        result.require(
            columns_valid,
            f"forward added columns for {relation!r} must be a nonempty list",
        )
        if not relation_valid or not columns_valid or not isinstance(relation, str):
            continue
        result.require(
            relation not in additions,
            f"forward added columns relation is declared more than once: {relation}",
        )
        existing_columns = set(_column_names(rows[relation]))
        names: list[str] = []
        for column_index, raw_column in enumerate(raw_columns, 1):
            exact_shape = isinstance(raw_column, dict) and set(raw_column) == {
                "name",
                "type",
                "nullable",
                "default",
            }
            result.require(
                exact_shape,
                f"{relation}: added column {column_index} must contain exactly name, type, nullable and default",
            )
            if not exact_shape or not isinstance(raw_column, dict):
                continue
            name = raw_column.get("name")
            valid_name = (
                isinstance(name, str)
                and re.fullmatch(r"[a-z][a-z0-9_]*", name) is not None
                and name not in existing_columns
                and name not in names
            )
            result.require(
                valid_name,
                f"{relation}: added column {column_index} has an invalid or duplicate name",
            )
            result.require(
                isinstance(raw_column.get("type"), str)
                and bool(raw_column.get("type"))
                and isinstance(raw_column.get("nullable"), bool),
                f"{relation}: added column {name!r} has an invalid physical type or nullability",
            )
            if valid_name and isinstance(name, str):
                names.append(name)
        additions[relation] = tuple(names)
    return additions


def _added_candidate_keys(
    document: dict[str, Any],
    rows: dict[str, dict[str, Any]],
    result: Validation,
    added_columns: dict[str, tuple[str, ...]] | None = None,
) -> dict[str, tuple[tuple[str, tuple[str, ...]], ...]]:
    """Parse only explicit forward candidate keys from one additive fragment."""

    changes = document.get("existing_relation_changes")
    result.require(
        isinstance(changes, list),
        "forward existing_relation_changes must be a list",
    )
    if not isinstance(changes, list):
        return {}

    additions: dict[str, list[tuple[str, tuple[str, ...]]]] = {}
    seen_relations: set[str] = set()
    seen_names: set[str] = set()
    seen_keys: set[tuple[str, tuple[str, ...]]] = set()

    for change_index, change in enumerate(changes, 1):
        if not isinstance(change, dict):
            result.require(
                False,
                f"forward existing relation change {change_index} must be a mapping",
            )
            continue
        raw_keys = change.get("added_candidate_keys")
        if raw_keys is None:
            continue
        relation = change.get("relation")
        relation_valid = (
            isinstance(relation, str)
            and re.fullmatch(r"[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*", relation)
            is not None
            and relation in rows
        )
        result.require(
            relation_valid,
            f"forward existing relation change {change_index} targets an unknown relation {relation!r}",
        )
        keys_valid = isinstance(raw_keys, list) and bool(raw_keys)
        result.require(
            keys_valid,
            f"forward added_candidate_keys for {relation!r} must be a nonempty list",
        )
        if not relation_valid or not keys_valid or not isinstance(relation, str):
            continue
        result.require(
            relation not in seen_relations,
            f"forward added candidate-key relation is declared more than once: {relation}",
        )
        seen_relations.add(relation)
        existing_candidates = _candidate_keys(rows[relation])
        relation_columns = set(_column_names(rows[relation])) | set(
            (added_columns or {}).get(relation, ())
        )

        for key_index, raw_key in enumerate(raw_keys, 1):
            exact_shape = isinstance(raw_key, dict) and set(raw_key) == {
                "name",
                "columns",
            }
            result.require(
                exact_shape,
                f"{relation}: added candidate key {key_index} must contain exactly name and columns",
            )
            if not exact_shape or not isinstance(raw_key, dict):
                continue
            name = raw_key.get("name")
            raw_columns = raw_key.get("columns")
            name_valid = (
                isinstance(name, str)
                and len(name.encode()) <= 63
                and re.fullmatch(r"[a-z][a-z0-9_]*", name) is not None
            )
            columns_valid = (
                isinstance(raw_columns, list)
                and bool(raw_columns)
                and all(
                    isinstance(column, str)
                    and re.fullmatch(r"[a-z][a-z0-9_]*", column) is not None
                    for column in raw_columns
                )
                and len(raw_columns) == len(set(raw_columns))
            )
            result.require(
                name_valid,
                f"{relation}: added candidate key {key_index} has an invalid name",
            )
            result.require(
                columns_valid,
                f"{relation}: added candidate key {key_index} has invalid or duplicate columns",
            )
            if not name_valid or not columns_valid or not isinstance(name, str):
                continue
            columns = tuple(str(column) for column in raw_columns)
            columns_exist = set(columns) <= relation_columns
            result.require(
                columns_exist,
                f"{relation}: added candidate key {name} references unknown columns",
            )
            key_identity = (relation, columns)
            key_is_new = columns not in existing_candidates and key_identity not in seen_keys
            result.require(
                key_is_new,
                f"{relation}: added candidate key {name} duplicates an existing or forward key",
            )
            name_is_new = name not in seen_names
            result.require(
                name_is_new,
                f"forward added candidate-key name is duplicated: {name}",
            )
            if not columns_exist or not key_is_new or not name_is_new:
                continue
            seen_names.add(name)
            seen_keys.add(key_identity)
            additions.setdefault(relation, []).append((name, columns))

    return {relation: tuple(keys) for relation, keys in additions.items()}


def _foreign_keys(row: dict[str, Any]) -> list[dict[str, Any]]:
    return _constraint_rows(row, "foreign_keys", "deferred_foreign_keys")
