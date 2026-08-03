from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

from pglast import parse_sql
import yaml


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from validation.database import (
    _event_registry_inventory,
    _extract_additive_inventory,
    _resolve_local_schema_refs,
    _validate_event_payload_inventory,
)
from validation.models import Validation
from validation.database_payload_inventory import (
    _canonical_json_sha256,
    _validate_event_payload_forward_overrides,
)


EVENT_INSERT = """
INSERT INTO ops.event_types(
  event_type,category,schema_version,active,payload_schema_uri,payload_schema
) VALUES(
  'entity.personhood_classified.v1','DOMAIN',1,true,
  'payloads/entity_personhood_classified_v1.schema.json',
  '{"type":"object","additionalProperties":false}'::jsonb
)
ON CONFLICT(event_type) DO UPDATE SET
  category=EXCLUDED.category,
  schema_version=EXCLUDED.schema_version,
  active=EXCLUDED.active,
  payload_schema_uri=EXCLUDED.payload_schema_uri,
  payload_schema=EXCLUDED.payload_schema;
"""


class EventRegistryInventoryTests(unittest.TestCase):
    def test_additive_inventory_binds_index_statement_and_digest(self) -> None:
        migration_sql = b"""BEGIN;
CREATE TABLE ops.example_inventory(id uuid PRIMARY KEY, value text NOT NULL);
CREATE INDEX example_inventory_value_idx ON ops.example_inventory(value);
COMMIT;
"""
        with tempfile.TemporaryDirectory() as directory:
            migration = Path(directory) / "0039_example.sql"
            migration.write_bytes(migration_sql)
            result = Validation()

            inventory = _extract_additive_inventory(
                migration,
                result,
                "0039",
                expected_marker_count=0,
            )

        self.assertEqual(result.errors, [])
        self.assertIsNotNone(inventory)
        assert inventory is not None
        self.assertEqual(len(inventory["indexes"]), 1)
        statement, digest = inventory["indexes"][0]
        self.assertEqual(
            statement,
            "CREATE INDEX example_inventory_value_idx ON ops.example_inventory (value)",
        )
        self.assertEqual(digest, hashlib.sha256(statement.encode()).hexdigest())

    def test_local_schema_refs_are_resolved_without_dropping_metadata(self) -> None:
        schema = {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": "https://gurinnae.invalid/events/example.v1.schema.json",
            "$defs": {"uuid": {"type": "string", "format": "uuid"}},
            "type": "object",
            "properties": {"id": {"$ref": "#/$defs/uuid"}},
        }

        resolved = _resolve_local_schema_refs(schema, schema["$defs"])

        self.assertNotIn("$defs", resolved)
        self.assertEqual(resolved["$id"], schema["$id"])
        self.assertEqual(
            resolved["properties"]["id"],
            {"type": "string", "format": "uuid"},
        )

    def test_top_level_closed_upsert_is_inventory_visible(self) -> None:
        source = EVENT_INSERT.encode()
        result = Validation()

        rows, markers = _event_registry_inventory(
            source,
            parse_sql(source.decode()),
            result,
            "0039",
            expected_marker_count=0,
        )

        self.assertEqual(result.errors, [])
        self.assertEqual(markers, set())
        self.assertEqual([row["event_type"] for row in rows], [
            "entity.personhood_classified.v1"
        ])
        self.assertEqual(
            rows[0]["payload_schema"],
            {"type": "object", "additionalProperties": False},
        )

    def test_marked_do_resolves_jsonb_variable_without_hiding_payload(self) -> None:
        source = f"""
DO $decision_event_registry$
DECLARE
  v_schema_text text:=$decision_schema${{
    "type":"object",
    "additionalProperties":false
  }}$decision_schema$;
  v_schema jsonb;
BEGIN
  v_schema:=v_schema_text::jsonb;
  {EVENT_INSERT.replace("'{\"type\":\"object\",\"additionalProperties\":false}'::jsonb", "v_schema")}
END
$decision_event_registry$;
""".encode()
        result = Validation()

        rows, markers = _event_registry_inventory(
            source,
            parse_sql(source.decode()),
            result,
            "0038",
            expected_marker_count=1,
        )

        self.assertEqual(result.errors, [])
        self.assertEqual(markers, {0})
        self.assertEqual(
            rows[0]["payload_schema"],
            {"type": "object", "additionalProperties": False},
        )

    def test_unmarked_do_event_mutation_is_rejected(self) -> None:
        source = f"DO $$ BEGIN {EVENT_INSERT} END $$;".encode()
        result = Validation()

        _event_registry_inventory(
            source,
            parse_sql(source.decode()),
            result,
            "0039",
            expected_marker_count=0,
        )

        self.assertIn(
            "0039 unmarked DO statement changes the event registry",
            result.errors,
        )

    def test_insert_select_cannot_hide_an_open_registry_inventory(self) -> None:
        source = """
INSERT INTO ops.event_types(
  event_type,category,schema_version,active,payload_schema_uri,payload_schema
)
SELECT 'hidden.v1','DOMAIN',1,true,'payloads/hidden.schema.json','{}'::jsonb
ON CONFLICT(event_type) DO UPDATE SET
  category=EXCLUDED.category,
  schema_version=EXCLUDED.schema_version,
  active=EXCLUDED.active,
  payload_schema_uri=EXCLUDED.payload_schema_uri,
  payload_schema=EXCLUDED.payload_schema;
""".encode()
        result = Validation()

        _event_registry_inventory(
            source,
            parse_sql(source.decode()),
            result,
            "0039",
            expected_marker_count=0,
        )

        self.assertIn(
            "0039 top-level event INSERT: event registry upsert must use VALUES rows",
            result.errors,
        )

    def test_payload_inventory_binds_source_schema_and_catalog_tuple(self) -> None:
        schema = b'{"type":"object","additionalProperties":false}\n'
        event_type = "entity.personhood_classified.v1"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schema_path = root / "specs/events/payloads/personhood.schema.json"
            schema_path.parent.mkdir(parents=True)
            schema_path.write_bytes(schema)
            (root / "specs/events/event-catalog.yaml").write_text(
                "events: []\n",
                encoding="utf-8",
            )
            catalog_path = root / "specs/product/addendum-event-contracts.yaml"
            catalog_path.parent.mkdir(parents=True)
            catalog_path.write_text(
                yaml.safe_dump(
                    {
                        "events": {
                            event_type: {
                                "category": "DOMAIN",
                                "schema_version": 1,
                            }
                        }
                    },
                    sort_keys=False,
                ),
                encoding="utf-8",
            )
            declared = [{
                "event_type": event_type,
                "payload_schema_path": "specs/events/payloads/personhood.schema.json",
                "payload_schema_sha256": hashlib.sha256(schema).hexdigest(),
                "embedded_json_equivalent": True,
            }]
            actual = [{
                "event_type": event_type,
                "category": "DOMAIN",
                "schema_version": 1,
                "active": True,
                "payload_schema_uri": "payloads/personhood.schema.json",
                "payload_schema": {
                    "type": "object",
                    "additionalProperties": False,
                },
            }]
            result = Validation()

            _validate_event_payload_inventory(
                root,
                declared,
                actual,
                "0039",
                result,
            )

            self.assertEqual(result.errors, [])
            drifted = [{**actual[0], "schema_version": 2}]
            drift_result = Validation()
            _validate_event_payload_inventory(
                root,
                declared,
                drifted,
                "0039",
                drift_result,
            )
            self.assertIn(
                "0039 entity.personhood_classified.v1 category/schema version "
                "differs from the additive event catalog",
                drift_result.errors,
            )


class EventPayloadForwardOverrideTests(unittest.TestCase):
    EVENT_TYPE = "legal_hold.placed.v2"
    URI = "payloads/legal_hold_placed_v2.schema.json"
    OLD_MIGRATION = "0038_r6d_legal_hardening.sql"
    NEW_MIGRATION = "0040_r6d_privacy_authority_closure.sql"

    @staticmethod
    def _schema(branches: int) -> dict[str, object]:
        return {
            "type": "object",
            "additionalProperties": False,
            "properties": {"target": {"oneOf": [{"const": n} for n in range(branches)]}},
        }

    def _row(
        self,
        schema: dict[str, object],
        **metadata: object,
    ) -> tuple[dict[str, object], dict[str, object]]:
        declared = {
            "event_type": self.EVENT_TYPE,
            "category": "DOMAIN",
            "schema_version": 2,
            "payload_schema_uri": self.URI,
            **metadata,
        }
        actual = {
            "event_type": self.EVENT_TYPE,
            "category": "DOMAIN",
            "schema_version": 2,
            "active": True,
            "payload_schema_uri": self.URI,
            "payload_schema": schema,
        }
        return declared, actual

    def _valid_pair(self) -> list[dict[str, object]]:
        old_schema = self._schema(10)
        old_declared, old_actual = self._row(
            old_schema,
            embedded_payload_schema_canonical_sha256=_canonical_json_sha256(
                old_schema
            ),
            forward_superseded_by={
                "migration": self.NEW_MIGRATION,
                "event_ordinal": 1,
            },
        )
        new_declared, new_actual = self._row(
            self._schema(13),
            forward_supersedes={
                "migration": self.OLD_MIGRATION,
                "event_ordinal": 1,
            },
        )
        return [
            {
                "migration_name": self.OLD_MIGRATION,
                "declared_events": [old_declared],
                "actual_events": [old_actual],
            },
            {
                "migration_name": self.NEW_MIGRATION,
                "declared_events": [new_declared],
                "actual_events": [new_actual],
            },
        ]

    def test_reciprocal_forward_override_proves_only_historical_owner(self) -> None:
        result = Validation()

        proven = _validate_event_payload_forward_overrides(
            self._valid_pair(),
            result,
        )

        self.assertEqual(result.errors, [])
        self.assertEqual(proven, {(self.OLD_MIGRATION, 1)})

    def test_forward_override_rejects_missing_target(self) -> None:
        inventories = self._valid_pair()[:1]
        result = Validation()

        proven = _validate_event_payload_forward_overrides(inventories, result)

        self.assertEqual(proven, set())
        self.assertTrue(
            any("forward target is missing" in error for error in result.errors),
            result.errors,
        )

    def test_forward_override_rejects_nonreciprocal_link(self) -> None:
        inventories = self._valid_pair()
        inventories[1]["declared_events"][0].pop("forward_supersedes")
        result = Validation()

        proven = _validate_event_payload_forward_overrides(inventories, result)

        self.assertEqual(proven, set())
        self.assertTrue(
            any("forward link is not reciprocal" in error for error in result.errors),
            result.errors,
        )

    def test_forward_override_rejects_backward_migration(self) -> None:
        inventories = self._valid_pair()
        inventories[0]["migration_name"] = self.NEW_MIGRATION
        inventories[0]["declared_events"][0]["forward_superseded_by"] = {
            "migration": self.OLD_MIGRATION,
            "event_ordinal": 1,
        }
        inventories[1]["migration_name"] = self.OLD_MIGRATION
        inventories[1]["declared_events"][0]["forward_supersedes"] = {
            "migration": self.NEW_MIGRATION,
            "event_ordinal": 1,
        }
        result = Validation()

        proven = _validate_event_payload_forward_overrides(inventories, result)

        self.assertEqual(proven, set())
        self.assertTrue(
            any("forward target is not later" in error for error in result.errors),
            result.errors,
        )

    def test_forward_override_rejects_wrong_event_tuple(self) -> None:
        inventories = self._valid_pair()
        inventories[1]["declared_events"][0]["category"] = "INTEGRATION"
        inventories[1]["actual_events"][0]["category"] = "INTEGRATION"
        result = Validation()

        proven = _validate_event_payload_forward_overrides(inventories, result)

        self.assertEqual(proven, set())
        self.assertTrue(
            any(
                "event/category/version/URI tuple differs" in error
                for error in result.errors
            ),
            result.errors,
        )

    def test_forward_override_rejects_historical_embedded_digest_drift(self) -> None:
        inventories = self._valid_pair()
        inventories[0]["declared_events"][0][
            "embedded_payload_schema_canonical_sha256"
        ] = "0" * 64
        result = Validation()

        proven = _validate_event_payload_forward_overrides(inventories, result)

        self.assertEqual(proven, set())
        self.assertTrue(
            any(
                "historical embedded payload schema canonical SHA-256 differs" in error
                for error in result.errors
            ),
            result.errors,
        )

    def test_forward_override_rejects_linkless_duplicate_owner(self) -> None:
        inventories = self._valid_pair()
        inventories[0]["declared_events"][0].pop("forward_superseded_by")
        inventories[1]["declared_events"][0].pop("forward_supersedes")
        result = Validation()

        proven = _validate_event_payload_forward_overrides(inventories, result)

        self.assertEqual(proven, set())
        self.assertIn(
            f"{self.EVENT_TYPE} duplicate event owners are linkless",
            result.errors,
        )

    def test_final_owner_remains_strict_when_current_schema_drifts(self) -> None:
        current_schema = self._schema(13)
        current_bytes = json.dumps(current_schema, separators=(",", ":")).encode()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            schema_path = root / "specs/events/payloads/legal_hold.schema.json"
            schema_path.parent.mkdir(parents=True)
            schema_path.write_bytes(current_bytes)
            (root / "specs/events/event-catalog.yaml").write_text(
                "events: []\n",
                encoding="utf-8",
            )
            catalog_path = root / "specs/product/addendum-event-contracts.yaml"
            catalog_path.parent.mkdir(parents=True)
            catalog_path.write_text(
                yaml.safe_dump(
                    {
                        "events": {
                            self.EVENT_TYPE: {
                                "category": "DOMAIN",
                                "schema_version": 2,
                            }
                        }
                    },
                    sort_keys=False,
                ),
                encoding="utf-8",
            )
            declared = [{
                "event_type": self.EVENT_TYPE,
                "payload_schema_path": "specs/events/payloads/legal_hold.schema.json",
                "payload_schema_sha256": hashlib.sha256(current_bytes).hexdigest(),
                "embedded_json_equivalent": True,
            }]
            actual = [{
                "event_type": self.EVENT_TYPE,
                "category": "DOMAIN",
                "schema_version": 2,
                "active": True,
                "payload_schema_uri": "payloads/legal_hold.schema.json",
                "payload_schema": self._schema(12),
            }]
            result = Validation()

            _validate_event_payload_inventory(
                root,
                declared,
                actual,
                "0040",
                result,
                historical_event_ordinals=set(),
            )

        self.assertIn(
            "0040 legal_hold.placed.v2 embedded payload schema differs from source JSON",
            result.errors,
        )


class MigrationOrderingScriptTests(unittest.TestCase):
    def test_control_fixture_crosses_0038_then_0039_then_0040_boundary(self) -> None:
        script = (SCRIPTS / "test-control-flow.sh").read_text(encoding="utf-8")
        seed = script.index("<db/test-fixtures/control-runtime-seed.sql")
        apply_0038 = script.index('<"$r6d_legacy_boundary_migration"')
        apply_0039 = script.index('<"$r6d_authority_closure_migration"')
        apply_0040 = script.index('<"$r6d_privacy_authority_closure_migration"')
        policy_fixture = script.index("< db/test-fixtures/r6d-approved-policy-authority.sql")

        self.assertLess(seed, apply_0038)
        self.assertLess(apply_0038, apply_0039)
        self.assertLess(apply_0039, apply_0040)
        self.assertLess(apply_0040, policy_fixture)
        self.assertIn(
            '|| "$migration" == "$r6d_authority_closure_migration"',
            script,
        )
        self.assertIn(
            '|| "$migration" == "$r6d_privacy_authority_closure_migration"',
            script,
        )

    def test_runtime_receipt_migration_count_matches_exact_runtime_set(self) -> None:
        root = SCRIPTS.parent
        receipt_schema = json.loads(
            (root / "specs/acceptance/runtime-layer-receipt-v1.schema.json")
            .read_text(encoding="utf-8")
        )
        declared_count = receipt_schema["$defs"]["postgresql_probe"]["properties"][
            "migration_count"
        ]["const"]
        migrations = sorted((root / "db/migrations").glob("[0-9][0-9][0-9][0-9]_*.sql"))

        self.assertEqual(declared_count, 40)
        self.assertEqual(declared_count, len(migrations))
        self.assertEqual(
            migrations[-1].name,
            "0040_r6d_privacy_authority_closure.sql",
        )


if __name__ == "__main__":
    unittest.main()
