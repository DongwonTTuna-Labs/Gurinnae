#!/usr/bin/env python3
"""Generate the data-only pre-0041 catalog marker inventory."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
from typing import Any, Sequence

from pglast import parse_sql

from validation.database_event_inventory import (
    _canonical_sql,
    _event_registry_inventory,
    _relation_name,
    _routine_signature,
)
from validation.database_payload_inventory import _validate_event_payload_inventory
from validation.database_r6e_event_inventory import _declared_event_inventory
from validation.database_r6e_security_support import (
    CATALOG_BUILTIN_TYPES as _BUILTIN_TYPES,
    _catalog_type_identity as catalog_type_identity,
)
from validation.loaders import load_yaml
from validation.models import Validation


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = Path("db/migrations/0041_r6e_monetization_runtime.sql")
CONTRACT = Path("specs/database/addendum/0041-r6e-monetization-runtime.yaml")
OUTPUT = Path("db/control-plane/r6e-pre-0041-markers.sql")
MARKER_KINDS = ("RELATION", "TYPE", "ROUTINE", "EVENT_SCHEMA")
_OBJECT_IDENTITY = re.compile(r"^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$")
_EVENT_IDENTITY = re.compile(r"^[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+\.v[1-9][0-9]*$")
_ROUTINE_IDENTITY = re.compile(
    r"^(?P<name>[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*)"
    r"\((?P<arguments>[^()]*)\)$"
)

Marker = tuple[str, str, dict[str, Any] | None]


def _parts(values: Any) -> str:
    parts = [value.sval for value in values or () if isinstance(value.sval, str)]
    if len(parts) != 2:
        raise ValueError(f"marker object name must be schema-qualified: {parts!r}")
    return ".".join(parts)


def routine_catalog_identity(statement: Any) -> str:
    name = _parts(statement.funcname)
    arguments = ",".join(
        catalog_type_identity(parameter.argType)
        for parameter in statement.parameters or ()
        if str(parameter.mode) not in {"o", "t"}
    )
    return f"{name}({arguments})"


def _standalone_type_identity(statement: Any) -> str | None:
    statement_type = type(statement).__name__
    if statement_type == "CompositeTypeStmt":
        return _relation_name(statement.typevar)
    if statement_type in {"CreateEnumStmt", "CreateRangeStmt"}:
        return _parts(statement.typeName)
    if (
        statement_type == "DefineStmt"
        and getattr(getattr(statement, "kind", None), "name", None)
        == "OBJECT_TYPE"
    ):
        return _parts(statement.defnames)
    return None


def _sha256_json(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _event_contract(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "category": row["category"],
        "schemaVersion": row["schema_version"],
        "active": row["active"],
        "payloadSchemaUri": row["payload_schema_uri"],
        "payloadSchema": row["payload_schema"],
    }


def _validate_declared_inventory(
    root: Path,
    contract: dict[str, Any],
    relations: list[str],
    types: list[str],
    routine_signatures: list[str],
    event_rows: list[dict[str, Any]],
) -> None:
    scope = contract.get("scope", {})
    _require(scope.get("exact_relations") == relations, "0041 relation marker inventory differs")
    type_contract = contract.get("standalone_type_inventory", {})
    _require(
        isinstance(type_contract, dict)
        and set(type_contract)
        == {
            "freeze_status",
            "count_exactly",
            "types_in_order",
            "inventory_sha256",
            "extraction_rule",
            "exactness_rule",
        }
        and type_contract.get("freeze_status") == "FINAL"
        and type_contract.get("count_exactly") == len(types)
        and type_contract.get("types_in_order") == types
        and len(types) == len(set(types)) > 0
        and type_contract.get("inventory_sha256") == _sha256_json(types),
        "0041 standalone type marker inventory is not FINAL and exact",
    )
    declared_routines = [
        row.get("signature")
        for row in contract.get("owner_routines", [])
        if isinstance(row, dict)
    ]
    _require(
        declared_routines == routine_signatures
        and len(routine_signatures) == len(set(routine_signatures)) > 0,
        "0041 routine marker inventory differs",
    )
    inventory = contract.get("statement_inventory", {})
    _require(
        inventory.get("owner_routine_count") == len(routine_signatures),
        "0041 routine marker count differs",
    )
    validation = Validation()
    _owned, _overrides, declared_events = _declared_event_inventory(
        contract,
        validation,
        "0041",
    )
    _require(not validation.errors, "; ".join(validation.errors))
    _require(
        [row.get("event_type") for row in declared_events]
        == [row.get("event_type") for row in event_rows],
        "0041 event marker inventory differs",
    )
    _validate_event_payload_inventory(
        root,
        declared_events,
        event_rows,
        "0041",
        validation,
    )
    _require(not validation.errors, "; ".join(validation.errors))


def build_markers(root: Path = ROOT) -> list[Marker]:
    root = root.resolve()
    source = (root / MIGRATION).read_bytes()
    statements = parse_sql(source.decode("utf-8"))
    contract = load_yaml(root / CONTRACT)
    relations: list[str] = []
    types: list[str] = []
    routine_signatures: list[str] = []
    routine_identities: list[str] = []
    for raw_statement in statements:
        statement = raw_statement.stmt
        statement_type = type(statement).__name__
        if statement_type == "CreateStmt":
            relations.append(_relation_name(statement.relation))
        standalone_type = _standalone_type_identity(statement)
        if standalone_type is not None:
            types.append(standalone_type)
        if statement_type == "CreateFunctionStmt":
            routine_signatures.append(_routine_signature(_canonical_sql(statement)))
            routine_identities.append(routine_catalog_identity(statement))
    validation = Validation()
    event_rows, _markers = _event_registry_inventory(
        source,
        statements,
        validation,
        "0041",
        expected_marker_count=0,
    )
    _require(not validation.errors, "; ".join(validation.errors))
    _validate_declared_inventory(
        root,
        contract,
        relations,
        types,
        routine_signatures,
        event_rows,
    )
    markers: list[Marker] = [
        *[("RELATION", identity, None) for identity in relations],
        *[("TYPE", identity, None) for identity in types],
        *[("ROUTINE", identity, None) for identity in routine_identities],
        *[
            ("EVENT_SCHEMA", row["event_type"], _event_contract(row))
            for row in event_rows
        ],
    ]
    validate_markers(markers)
    return markers


def _canonical_routine_marker(identity: str) -> bool:
    match = _ROUTINE_IDENTITY.fullmatch(identity)
    if match is None:
        return False
    arguments = match.group("arguments")
    if not arguments:
        return True
    for argument in arguments.split(","):
        base = argument.removesuffix("[]")
        if not _OBJECT_IDENTITY.fullmatch(base):
            return False
        schema, name = base.split(".", 1)
        if schema == "pg_catalog" and name not in _BUILTIN_TYPES:
            return False
    return True


def validate_markers(markers: Sequence[Marker]) -> None:
    _require(bool(markers), "R6e marker inventory is empty")
    seen: set[tuple[str, str]] = set()
    kind_positions = {kind: index for index, kind in enumerate(MARKER_KINDS)}
    previous_kind = -1
    for marker_kind, identity, marker_contract in markers:
        _require(marker_kind in kind_positions, f"invalid marker kind: {marker_kind}")
        current_kind = kind_positions[marker_kind]
        _require(current_kind >= previous_kind, "R6e marker kinds are out of order")
        previous_kind = current_kind
        key = (marker_kind, identity)
        _require(key not in seen, f"duplicate R6e marker: {key!r}")
        seen.add(key)
        if marker_kind in {"RELATION", "TYPE"}:
            _require(_OBJECT_IDENTITY.fullmatch(identity) is not None, f"invalid object marker: {identity}")
            _require(marker_contract is None, f"catalog object marker carries a contract: {identity}")
        elif marker_kind == "ROUTINE":
            _require(_canonical_routine_marker(identity), f"invalid routine marker: {identity}")
            _require(marker_contract is None, f"routine marker carries a contract: {identity}")
        else:
            _require(_EVENT_IDENTITY.fullmatch(identity) is not None, f"invalid event marker: {identity}")
            _require(
                isinstance(marker_contract, dict)
                and set(marker_contract)
                == {
                    "category",
                    "schemaVersion",
                    "active",
                    "payloadSchemaUri",
                    "payloadSchema",
                },
                f"event marker contract is not closed: {identity}",
            )


def _sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def render_markers(markers: Sequence[Marker]) -> bytes:
    validate_markers(markers)
    rows: list[str] = []
    for marker_kind, identity, marker_contract in markers:
        contract_sql = "NULL"
        if marker_contract is not None:
            canonical = json.dumps(
                marker_contract,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            contract_sql = f"{_sql_literal(canonical)}::jsonb"
        rows.append(
            f"  ({_sql_literal(marker_kind)},{_sql_literal(identity)},{contract_sql})"
        )
    return (
        "INSERT INTO pg_temp.r6e_pre_0041_markers_v1(\n"
        "  marker_kind,marker_identity,marker_contract\n"
        ") VALUES\n"
        + ",\n".join(rows)
        + ";\n"
    ).encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        markers = build_markers(root)
        rendered = render_markers(markers)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"R6E_PRE_0041_MARKERS: FAIL: {error}")
        return 1
    output = root / args.output
    if args.write:
        output.write_bytes(rendered)
        print(
            "R6E_PRE_0041_MARKERS: WROTE "
            f"{args.output} sha256={hashlib.sha256(rendered).hexdigest()}"
        )
        return 0
    if output.is_symlink() or not output.is_file() or output.read_bytes() != rendered:
        print("R6E_PRE_0041_MARKERS: FAIL: generated bytes differ")
        return 1
    print(
        "R6E_PRE_0041_MARKERS: PASS "
        f"sha256={hashlib.sha256(rendered).hexdigest()} markers={len(markers)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
