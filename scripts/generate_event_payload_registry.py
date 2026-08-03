#!/usr/bin/env python3
"""Generate the migration-embedded closed event payload registry.

The runtime registry is derived from the hash-pinned base event catalog and
the repository's reviewed owner-addendum event contracts.  Keeping generation
mechanical prevents a producer fix from silently weakening a payload schema.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "db/migrations/0030_v13_submission_session_hardening.sql"
BASE_CATALOG = ROOT / "specs/events/event-catalog.yaml"
ADDENDUM_CATALOG = ROOT / "specs/product/addendum-event-contracts.yaml"
START = "-- BEGIN GENERATED EVENT PAYLOAD REGISTRY\n"
END = "-- END GENERATED EVENT PAYLOAD REGISTRY\n"
LEGACY_COMMERCIAL_QUALIFICATION_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": [
        "deploymentId",
        "organizationId",
        "qualificationEpisodeId",
        "receiptId",
        "receiptDigest",
        "sku",
    ],
    "properties": {
        "deploymentId": {"type": "string", "format": "uuid"},
        "organizationId": {"type": "string", "format": "uuid"},
        "qualificationEpisodeId": {"type": "string", "format": "uuid"},
        "receiptId": {"type": "string", "format": "uuid"},
        "receiptDigest": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
        "sku": {"type": "string", "const": "EVIDENCE_WORKSPACE_ORGANIZATION_V1"},
    },
}


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
        merged = {**target, **siblings}
        return resolve_refs(merged, definitions)
    return {
        key: resolve_refs(item, definitions)
        for key, item in value.items()
        if key not in {"$schema", "$id", "$defs", "title"}
    }


def schema_uri(event_type: str) -> str:
    return f"payloads/{event_type.replace('.', '_')}.schema.json"


def rows() -> list[tuple[str, str, int, str, dict[str, Any]]]:
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
    if len(result) != expected or len(seen) != expected:
        raise ValueError("effective event registry cardinality mismatch")
    return sorted(result)


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def render_registry() -> str:
    registry_rows = rows()
    rendered_rows: list[str] = []
    for event_type, category, version, uri, schema in registry_rows:
        payload = json.dumps(schema, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        rendered_rows.append(
            "    ("
            + ",".join(
                [
                    sql_literal(event_type),
                    sql_literal(category),
                    str(version),
                    "true",
                    sql_literal(uri),
                    f"$event_schema${payload}$event_schema$::jsonb",
                ]
            )
            + ")"
        )
    values = ",\n".join(rendered_rows)
    effective_types = ",\n    ".join(sql_literal(row[0]) for row in registry_rows)
    legacy_product_schema = json.dumps(
        LEGACY_COMMERCIAL_QUALIFICATION_SCHEMA,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return (
        START
        + "-- Generated by scripts/generate_event_payload_registry.py.\n"
        + "ALTER TABLE ops.event_types ADD COLUMN IF NOT EXISTS payload_schema jsonb;\n\n"
        + "WITH effective_event_types(\n"
        + "  event_type,category,schema_version,active,payload_schema_uri,payload_schema\n"
        + ") AS (\n  VALUES\n"
        + values
        + "\n)\n"
        + "INSERT INTO ops.event_types(\n"
        + "  event_type,category,schema_version,active,payload_schema_uri,payload_schema\n"
        + ")\n"
        + "SELECT event_type,category,schema_version,active,payload_schema_uri,payload_schema\n"
        + "FROM effective_event_types\n"
        + "ON CONFLICT (event_type) DO UPDATE SET\n"
        + "  category=EXCLUDED.category,\n"
        + "  schema_version=EXCLUDED.schema_version,\n"
        + "  active=EXCLUDED.active,\n"
        + "  payload_schema_uri=EXCLUDED.payload_schema_uri,\n"
        + "  payload_schema=EXCLUDED.payload_schema;\n\n"
        + "UPDATE ops.event_types\n"
        + "SET active=false\n"
        + "WHERE event_type NOT IN (\n    "
        + effective_types
        + "\n);\n\n"
        + "UPDATE ops.event_types\n"
        + "SET payload_schema=$event_schema$"
        + legacy_product_schema
        + "$event_schema$::jsonb,\n"
        + "    payload_schema_uri='legacy/product_commercial_qualification_recorded_v1.compat.schema.json'\n"
        + "WHERE event_type='product.commercial_qualification_recorded.v1'\n"
        + "  AND active=false;\n\n"
        + "DO $$\n"
        + "DECLARE v_missing text;\n"
        + "BEGIN\n"
        + "  SELECT string_agg(event_type,',' ORDER BY event_type) INTO v_missing\n"
        + "  FROM ops.event_types WHERE active AND payload_schema IS NULL;\n"
        + "  IF v_missing IS NOT NULL THEN\n"
        + "    RAISE EXCEPTION 'active event payload schema missing: %',v_missing;\n"
        + "  END IF;\n"
        + "END $$;\n"
        + END
    )


def main() -> None:
    current = MIGRATION.read_text(encoding="utf-8")
    generated = render_registry()
    if START in current:
        before, rest = current.split(START, 1)
        _, after = rest.split(END, 1)
        updated = before + generated + after
    else:
        legacy_start = current.index("-- Every outbox writer, including owner routines")
        legacy_end = current.index(
            "CREATE OR REPLACE FUNCTION ops.json_schema_value_valid_v1", legacy_start
        )
        updated = current[:legacy_start] + generated + "\n" + current[legacy_end:]
    MIGRATION.write_text(updated, encoding="utf-8")
    print(f"generated {len(rows())} event payload registry rows")


if __name__ == "__main__":
    main()
