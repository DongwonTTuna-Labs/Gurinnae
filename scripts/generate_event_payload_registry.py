#!/usr/bin/env python3
"""Generate and verify reviewed R6c forward overrides for event payload schemas.

Migration 0030 remains immutable historical authority, and the two reviewed
schema corrections below remain pinned to their 0037 forward origin. New event
keys registered by later migrations are validated through their own physical
inventory instead of silently retargeting or rewriting this historical region.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any, Sequence

import yaml


ROOT = Path(__file__).resolve().parents[1]
TARGET_MIGRATION = ROOT / "db/migrations/0037_r6c_conflict_investigation.sql"
BASE_CATALOG = ROOT / "specs/events/event-catalog.yaml"
ADDENDUM_CATALOG = ROOT / "specs/product/addendum-event-contracts.yaml"
START = "-- BEGIN GENERATED EVENT PAYLOAD FORWARD OVERRIDES\n"
END = "-- END GENERATED EVENT PAYLOAD FORWARD OVERRIDES\n"

# Every entry is a separately reviewed forward schema correction.  Keeping this
# list closed prevents an unrelated catalog edit or later registry addition
# from silently changing a runtime admission contract in migration 0037.
ATTACHMENT_SCAN_EVENT_TYPE = "attachment.scan_completed.v1"
AGENT_RUN_CONTROL_EVENT_TYPE = "agent.run_control_changed.v2"
FORWARD_OVERRIDE_EVENT_TYPES = (
    ATTACHMENT_SCAN_EVENT_TYPE,
    AGENT_RUN_CONTROL_EVENT_TYPE,
)

AGENT_RUN_CONTROL_REQUIRED_FIELDS = [
    "runId",
    "aggregateVersion",
    "priorStatus",
    "priorControlState",
    "nextStatus",
    "nextControlState",
    "affectedProviderTurnId",
    "affectedToolCallId",
    "reconciliationEvidenceId",
    "reconciliationEvidenceSha256",
    "proofKind",
    "proofSha256",
    "budgetDisposition",
    "budgetResolutionSetSha256",
    "actorKind",
    "actorId",
    "reasonCode",
    "reasonSha256",
    "occurredAt",
    "receiptSha256",
]
UUID_OR_NULL_SCHEMA = {
    "oneOf": [
        {"type": "string", "format": "uuid"},
        {"type": "null"},
    ]
}
TYPED_ACTOR_ID_SCHEMA = {
    "oneOf": [
        {"type": "string", "format": "uuid"},
        {"type": "null"},
        {"const": "analysis-worker"},
    ]
}
ACTOR_VARIANT_SCHEMA = [
    {
        "properties": {
            "actorType": {"const": "LEGACY_ACTOR_TYPE_MUST_BE_ABSENT"},
            "actorId": UUID_OR_NULL_SCHEMA,
        }
    },
    {
        "required": ["actorType", "actorKind", "actorId"],
        "properties": {
            "actorType": {"const": "SERVICE"},
            "actorKind": {"const": "ANALYSIS_WORKER"},
            "actorId": {"const": "analysis-worker"},
        },
    },
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def load_yaml(path: Path) -> dict[str, Any]:
    value = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected mapping: {path}")
    return value


def resolve_refs(value: Any, definitions: dict[str, Any]) -> Any:
    if isinstance(value, list):
        return [resolve_refs(item, definitions) for item in value]
    if not isinstance(value, dict):
        return value
    reference = value.get("$ref")
    if reference is not None:
        prefix = "#/$defs/"
        if not isinstance(reference, str) or not reference.startswith(prefix):
            raise ValueError(f"unsupported payload schema reference: {reference!r}")
        name = reference.removeprefix(prefix)
        target = definitions.get(name)
        if not isinstance(target, dict):
            raise ValueError(f"missing payload schema definition: {name}")
        siblings = {key: item for key, item in value.items() if key != "$ref"}
        return resolve_refs({**target, **siblings}, definitions)
    return {
        key: resolve_refs(item, definitions)
        for key, item in value.items()
        if key not in {"$schema", "$id", "$defs", "title"}
    }


def schema_uri(event_type: str) -> str:
    return f"payloads/{event_type.replace('.', '_')}.schema.json"


def registry_rows() -> list[tuple[str, str, int, str, dict[str, Any]]]:
    """Return the effective source registry while preserving closure checks."""
    base = load_yaml(BASE_CATALOG)
    addendum = load_yaml(ADDENDUM_CATALOG)
    result: list[tuple[str, str, int, str, dict[str, Any]]] = []
    seen: set[str] = set()

    base_events = base.get("events")
    if not isinstance(base_events, list):
        raise ValueError("base event catalog events must be a list")
    for event in base_events:
        if not isinstance(event, dict):
            raise ValueError("base event entry must be a mapping")
        event_type = str(event["event_type"])
        payload_path = ROOT / "specs/events" / str(event["payload_schema"])
        payload = json.loads(payload_path.read_text(encoding="utf-8"))
        definitions = payload.get("$defs", {}) if isinstance(payload, dict) else {}
        result.append(
            (
                event_type,
                str(event["category"]),
                int(event["schema_version"]),
                str(event["payload_schema"]),
                resolve_refs(payload, definitions),
            )
        )
        seen.add(event_type)

    definitions = addendum.get("$defs")
    addendum_events = addendum.get("events")
    if not isinstance(definitions, dict) or not isinstance(addendum_events, dict):
        raise ValueError("addendum event definitions/events must be mappings")
    for event_type, contract in addendum_events.items():
        if event_type in seen:
            raise ValueError(f"base/addendum event collision: {event_type}")
        if not isinstance(contract, dict):
            raise ValueError(f"invalid addendum event contract: {event_type}")
        payload = contract.get("payload_schema")
        if not isinstance(payload, dict):
            raise ValueError(f"missing payload schema: {event_type}")
        result.append(
            (
                event_type,
                str(contract["category"]),
                int(contract["schema_version"]),
                schema_uri(event_type),
                resolve_refs(payload, definitions),
            )
        )
        seen.add(event_type)

    expected = len(base_events) + len(addendum_events)
    require(
        len(result) == expected and len(seen) == expected,
        "effective event registry cardinality mismatch",
    )
    return sorted(result)


def validate_attachment_scan_schema(schema: dict[str, Any]) -> None:
    expected_required = ["attachment_id", "attachment_kind", "scan_status", "sha256"]
    require(schema.get("type") == "object", "attachment scan payload must be an object")
    require(
        schema.get("additionalProperties") is False,
        "attachment scan payload must remain closed",
    )
    require(
        schema.get("required") == expected_required,
        "attachment scan payload required fields drifted",
    )
    properties = schema.get("properties")
    require(isinstance(properties, dict), "attachment scan payload properties missing")
    require(
        list(properties) == expected_required,
        "attachment scan payload property set or order drifted",
    )
    require(
        properties.get("attachment_kind")
        == {"type": "string", "enum": ["CORRECTION", "RESPONSE"]},
        "attachment_kind must be the closed CORRECTION/RESPONSE discriminator",
    )


def schema_contains_keyword(value: Any, keyword: str) -> bool:
    if isinstance(value, list):
        return any(schema_contains_keyword(item, keyword) for item in value)
    if not isinstance(value, dict):
        return False
    return keyword in value or any(
        schema_contains_keyword(item, keyword) for item in value.values()
    )


def validate_agent_run_control_schema(schema: dict[str, Any]) -> None:
    require(schema.get("type") == "object", "agent run control payload must be an object")
    require(
        schema.get("additionalProperties") is False,
        "agent run control payload must remain closed",
    )
    require(
        schema.get("required") == AGENT_RUN_CONTROL_REQUIRED_FIELDS,
        "agent run control legacy required fields drifted",
    )
    properties = schema.get("properties")
    require(isinstance(properties, dict), "agent run control payload properties missing")
    expected_properties = AGENT_RUN_CONTROL_REQUIRED_FIELDS.copy()
    expected_properties.insert(expected_properties.index("actorKind"), "actorType")
    require(
        list(properties) == expected_properties,
        "agent run control payload property set or order drifted",
    )
    require(
        properties.get("actorType") == {"type": "string", "enum": ["SERVICE"]},
        "actorType must be the optional SERVICE discriminator",
    )
    require(
        properties.get("actorId") == TYPED_ACTOR_ID_SCHEMA,
        "actorId must admit only legacy UUID/null or analysis-worker",
    )
    require(
        schema.get("oneOf") == ACTOR_VARIANT_SCHEMA,
        "agent actor legacy/service variant closure drifted",
    )
    for unsupported in ("not", "if", "then", "else", "allOf"):
        require(
            not schema_contains_keyword(schema, unsupported),
            f"agent actor schema uses unsupported keyword: {unsupported}",
        )


def forward_override_rows() -> list[tuple[str, str, dict[str, Any]]]:
    by_event_type = {row[0]: row for row in registry_rows()}
    result: list[tuple[str, str, dict[str, Any]]] = []
    for event_type in FORWARD_OVERRIDE_EVENT_TYPES:
        row = by_event_type.get(event_type)
        require(row is not None, f"forward override event missing: {event_type}")
        _, _, _, uri, schema = row
        if event_type == ATTACHMENT_SCAN_EVENT_TYPE:
            validate_attachment_scan_schema(schema)
        elif event_type == AGENT_RUN_CONTROL_EVENT_TYPE:
            validate_agent_run_control_schema(schema)
        result.append((event_type, uri, schema))
    require(
        len(result) == len(set(FORWARD_OVERRIDE_EVENT_TYPES)),
        "forward override event types must be unique",
    )
    return result


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def render_forward_overrides() -> str:
    override_rows = forward_override_rows()
    rendered_rows: list[str] = []
    for event_type, uri, schema in override_rows:
        payload = json.dumps(schema, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        rendered_rows.append(
            "      ("
            + ",".join(
                [
                    sql_literal(event_type),
                    sql_literal(uri),
                    f"$event_schema${payload}$event_schema$::jsonb",
                ]
            )
            + ")"
        )
    values = ",\n".join(rendered_rows)
    expected_count = len(override_rows)
    return (
        START
        + "-- Generated by scripts/generate_event_payload_registry.py; do not edit.\n"
        + "DO $event_payload_override$\n"
        + "DECLARE\n"
        + "  v_updated integer;\n"
        + "BEGIN\n"
        + "  WITH schema_overrides(event_type,payload_schema_uri,payload_schema) AS (\n"
        + "    VALUES\n"
        + values
        + "\n  ), updated AS (\n"
        + "    UPDATE ops.event_types AS registered\n"
        + "    SET payload_schema_uri=override.payload_schema_uri,\n"
        + "        payload_schema=override.payload_schema\n"
        + "    FROM schema_overrides AS override\n"
        + "    WHERE registered.event_type=override.event_type\n"
        + "      AND registered.active\n"
        + "    RETURNING registered.event_type\n"
        + "  )\n"
        + "  SELECT count(*)::integer INTO v_updated FROM updated;\n"
        + f"  IF v_updated <> {expected_count} THEN\n"
        + "    RAISE EXCEPTION\n"
        + "      'event payload forward override cardinality mismatch: expected %, updated %',\n"
        + f"      {expected_count},v_updated USING ERRCODE='55000';\n"
        + "  END IF;\n"
        + "END\n"
        + "$event_payload_override$;\n"
        + END
    )


def replace_generated_region(current: str, generated: str) -> str:
    target = TARGET_MIGRATION.name
    require(
        current.count(START) == 1,
        f"{target} forward override start marker missing or duplicated",
    )
    require(
        current.count(END) == 1,
        f"{target} forward override end marker missing or duplicated",
    )
    before, rest = current.split(START, 1)
    _, after = rest.split(END, 1)
    return before + generated + after


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true")
    modes.add_argument("--stdout", action="store_true")
    args = parser.parse_args(argv)

    try:
        generated = render_forward_overrides()
        if args.stdout:
            print(generated, end="")
            return 0
        current = TARGET_MIGRATION.read_text(encoding="utf-8")
        updated = replace_generated_region(current, generated)
        if args.check:
            if current != updated:
                print(
                    f"event payload forward overrides differ: {TARGET_MIGRATION.relative_to(ROOT)}",
                    file=sys.stderr,
                )
                return 1
            print(
                "EVENT_PAYLOAD_FORWARD_OVERRIDES: PASS "
                f"events={len(FORWARD_OVERRIDE_EVENT_TYPES)}"
            )
            return 0
        TARGET_MIGRATION.write_text(updated, encoding="utf-8")
        print(
            "EVENT_PAYLOAD_FORWARD_OVERRIDES: GENERATED "
            f"events={len(FORWARD_OVERRIDE_EVENT_TYPES)} "
            f"target={TARGET_MIGRATION.relative_to(ROOT)}"
        )
        return 0
    except (OSError, ValueError) as error:
        print(f"EVENT_PAYLOAD_FORWARD_OVERRIDES: FAIL {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
