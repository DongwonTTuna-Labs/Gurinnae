from __future__ import annotations

import hashlib
import json
from copy import deepcopy
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from pglast import parse_sql
import yaml


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from validation.database_additive_inventory import (
    _LATE_ADDITIVE_INVENTORY_CONTRACTS,
    _R6E_EVENT_TYPES,
    _declared_event_inventory,
    _extract_additive_inventory,
    _legacy_effective_event_rows,
    _validate_historical_event_forward_overrides,
)
from validation.database_event_inventory import _event_registry_inventory
from validation.database_r6e_event_provenance import (
    validate_r6e_product_event_provenance,
)
from validation.models import Validation
from validation.database_payload_inventory import (
    _canonical_json_sha256,
    _resolve_local_schema_refs,
    _validate_event_payload_forward_overrides,
    _validate_event_payload_inventory,
)
from validation.design_database_relations import (
    _added_candidate_keys,
    _added_columns,
)
from validation.design_database import validate_derivation_hashes
from validation.design_database_support import APPROVAL_DETAIL_RELATIONS
from verify_migrations import (
    EXPECTED_ADDITIVE_MIGRATIONS,
    EXPECTED_RUNTIME_MIGRATIONS,
    MigrationVerificationError,
    verify_role_ddl_closure,
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


class R6eProductEventProvenanceTests(unittest.TestCase):
    @staticmethod
    def _contract() -> dict[str, object]:
        funding_signature = (
            "ops.import_funding_snapshot_v1(p_import "
            "ops.funding_snapshot_import_v1, p_entries "
            "ops.funding_snapshot_entry_input_v1[]) RETURNS "
            "ops.funding_snapshot_import_receipt_v1"
        )
        candidate_signature = (
            "ops.project_donation_fact_candidate_v1(p_input "
            "ops.donation_funding_candidate_projection_v1) RETURNS "
            "ops.donation_funding_candidate_receipt_v1"
        )
        return {
            "event_registry_contract": {
                "owned_events_in_order": [
                    {
                        "event_type": "donation.fact_recorded.v1",
                        "category": "DOMAIN",
                        "schema_version": 1,
                        "payload_schema_uri": "payloads/donation.schema.json",
                        "payload_schema_path": (
                            "specs/events/payloads/donation.schema.json"
                        ),
                        "payload_schema_sha256": "a" * 64,
                        "embedded_json_equivalent": True,
                        "fields_exactly": [
                            "donationFactId",
                            "donationFactDigest",
                            "chargeAttemptId",
                            "chargeAttemptDigest",
                            "providerFetchDigest",
                            "occurredAt",
                        ],
                    },
                    {
                        "event_type": "notification.payment_review_requested.v1",
                        "category": "DOMAIN",
                        "schema_version": 1,
                        "payload_schema_uri": "payloads/review.schema.json",
                        "payload_schema_path": (
                            "specs/events/payloads/review.schema.json"
                        ),
                        "payload_schema_sha256": "b" * 64,
                        "embedded_json_equivalent": True,
                        "fields_exactly": [
                            "reviewTaskId",
                            "reviewTaskVersion",
                            "reviewTaskDigest",
                            "sourceKind",
                            "sourceReceiptId",
                            "sourceReceiptDigest",
                            "occurredAt",
                        ],
                        "source_kind_values": [
                            "DONATION_PAYMENT_FAILURE",
                            "SIGNED_COLLECTION_FAILURE",
                        ],
                    },
                ]
            },
            "funding_snapshot_outer_producer_delegation": {
                "outer_producers_in_order": [
                    {
                        "logical_producer": "workflow-worker.signed-funding-import",
                        "entry_routine_signature": funding_signature,
                    },
                    {
                        "logical_producer": (
                            "public-projection-worker.donation-candidate"
                        ),
                        "entry_routine_signature": candidate_signature,
                    },
                ]
            }
        }

    @staticmethod
    def _events() -> dict[str, object]:
        return {
            "donation.fact_recorded.v1": {
                "producer": "billing-gateway",
                "producer_operations": [
                    "private.ExecuteDonationCharge",
                    "private.ReceivePaymentWebhook",
                ],
                "producer_bindings": [
                    {
                        "producer_operation": "private.ExecuteDonationCharge",
                        "source_authority": "PROVIDER_FETCH_CONFIRMED",
                        "owner_result_branch": "SUCCEEDED",
                    },
                    {
                        "producer_operation": "private.ReceivePaymentWebhook",
                        "source_authority": "PROVIDER_FETCH_CONFIRMED",
                        "owner_result_branch": "SUCCEEDED",
                    },
                ],
                "payload_required": [
                    "donationFactId",
                    "donationFactDigest",
                    "chargeAttemptId",
                    "chargeAttemptDigest",
                    "providerFetchDigest",
                    "occurredAt",
                ],
            },
            "notification.payment_review_requested.v1": {
                "producer": (
                    "billing-gateway|workflow-worker.economics-import-executor"
                ),
                "producer_operations": [
                    "private.ReceivePaymentWebhook",
                    "private.ExecuteEconomicsImport",
                ],
                "producer_bindings": [
                    {
                        "producer": "billing-gateway",
                        "producer_operation": "private.ReceivePaymentWebhook",
                        "source_authority": "PROVIDER_FETCH_CONFIRMED",
                        "sourceKind": "DONATION_PAYMENT_FAILURE",
                    },
                    {
                        "producer": "workflow-worker.economics-import-executor",
                        "producer_operation": "private.ExecuteEconomicsImport",
                        "source_authority": "BANK_RETURN_CONFIRMED",
                        "sourceKind": "SIGNED_COLLECTION_FAILURE",
                    },
                ],
                "payload_required": [
                    "reviewTaskId",
                    "reviewTaskVersion",
                    "reviewTaskDigest",
                    "sourceKind",
                    "sourceReceiptId",
                    "sourceReceiptDigest",
                    "occurredAt",
                ],
                "payload_schema": {
                    "properties": {
                        "sourceKind": {
                            "enum": [
                                "DONATION_PAYMENT_FAILURE",
                                "SIGNED_COLLECTION_FAILURE",
                            ]
                        }
                    }
                },
            },
            "governance.funding_snapshot_created.v1": {
                "producer": "funding-importer|funding-projector",
                "producer_operations": [],
                "producer_bindings": [
                    {
                        "producer": "funding-importer",
                        "logical_producer": "workflow-worker.signed-funding-import",
                        "source_authority": "SIGNED_FUNDING_SOURCES",
                        "owner_function": (
                            "ops.import_funding_snapshot_v1("
                            "ops.funding_snapshot_import_v1,"
                            "ops.funding_snapshot_entry_input_v1[])"
                        ),
                        "audit_action": "IMPORT_FUNDING_SNAPSHOT",
                    },
                    {
                        "producer": "funding-projector",
                        "logical_producer": (
                            "public-projection-worker.donation-candidate"
                        ),
                        "source_authority": "AUTHENTICATED_DONATION_FACT",
                        "owner_function": (
                            "ops.project_donation_fact_candidate_v1("
                            "ops.donation_funding_candidate_projection_v1)"
                        ),
                        "audit_action": "DONATION_FUNDING_CANDIDATE_PROJECTED",
                    },
                ],
            },
        }

    def _validate(
        self,
        events: dict[str, object],
        contract: dict[str, object] | None = None,
    ) -> Validation:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "specs/product/addendum-event-contracts.yaml"
            path.parent.mkdir(parents=True)
            path.write_text(
                yaml.safe_dump({"events": events}, sort_keys=False),
                encoding="utf-8",
            )
            result = Validation()
            validate_r6e_product_event_provenance(
                root,
                contract or self._contract(),
                result,
            )
        return result

    def test_exact_cross_file_provenance_passes(self) -> None:
        result = self._validate(self._events())

        self.assertEqual(result.errors, [])

    def test_donation_producer_operation_drift_is_rejected(self) -> None:
        events = self._events()
        donation = events["donation.fact_recorded.v1"]
        assert isinstance(donation, dict)
        donation["producer_operations"] = ["private.ReceivePaymentWebhook"]

        result = self._validate(events)

        self.assertIn(
            "0041 donation event producer provenance differs from the exact "
            "payment-owner pair",
            result.errors,
        )

    def test_funding_logical_producer_drift_is_rejected(self) -> None:
        events = self._events()
        funding = events["governance.funding_snapshot_created.v1"]
        assert isinstance(funding, dict)
        bindings = funding["producer_bindings"]
        assert isinstance(bindings, list)
        bindings[1]["logical_producer"] = "funding-projector.unbound"

        result = self._validate(events)

        self.assertIn(
            "0041 funding snapshot product provenance differs from DB outer producers",
            result.errors,
        )

    def test_payment_review_source_kind_drift_is_rejected(self) -> None:
        events = self._events()
        review = events["notification.payment_review_requested.v1"]
        assert isinstance(review, dict)
        review["payload_schema"]["properties"]["sourceKind"]["enum"].append(
            "INFERRED_FAILURE"
        )

        result = self._validate(events)

        self.assertIn(
            "0041 payment-review source-kind mirror differs",
            result.errors,
        )


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
        self.assertEqual(inventory["migration_line_count"], 4)
        self.assertEqual(inventory["pglast_statement_count"], 4)
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

    def test_conflict_update_cannot_override_the_declared_event_tuple(self) -> None:
        source = EVENT_INSERT.replace(
            "category=EXCLUDED.category",
            "category='OVERRIDDEN'",
        ).encode()
        result = Validation()

        _event_registry_inventory(
            source,
            parse_sql(source.decode()),
            result,
            "0039",
            expected_marker_count=0,
        )

        self.assertIn(
            "0039 top-level event INSERT: event registry conflict update values differ",
            result.errors,
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


class HistoricalEventOverrideTests(unittest.TestCase):
    FUNDING_EVENT = "governance.funding_disclosure_published.v1"
    ACTION_EVENT = "action.proposal_created.v1"
    SNAPSHOT_EVENT = "governance.funding_snapshot_created.v1"
    SKU_EVENT = "commercial.sku_readiness_evaluated.v1"
    FUNDING_DIGEST = "c9cf1fb62dde577bfde32a44a15ef025554041811290e24eb01c6012abba98c2"
    ACTION_DIGEST = "b507da8c2d569991b0a20be81048807cc421b790b46fe1b3ff41cf098a1afbe3"
    SNAPSHOT_DIGEST = "8f51ba77238989d867b92ee7b491ade1cd36c29e04f25a4b38e3b096e7d95229"
    SKU_DIGEST = "4fd006606a95490f1dfccfb667f7db8261ff90d83413579d46afbb68e4a05d3c"

    def _legacy_rows(self) -> dict[str, dict[str, object]]:
        result = Validation()
        rows = _legacy_effective_event_rows(
            SCRIPTS.parent
            / "db/migrations/0030_v13_submission_session_hardening.sql",
            result,
            "0030_v13_submission_session_hardening.sql",
        )
        self.assertEqual(result.errors, [])
        return rows

    def _valid_override_inventory(
        self,
    ) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
        legacy = self._legacy_rows()
        funding_fields = [
            "disclosureId",
            "revisionId",
            "revision",
            "revisionDigest",
            "snapshotBatchId",
            "snapshotDigest",
            "concentrationBand",
            "entrySetDigest",
            "priorRevision",
            "effectiveAt",
            "receiptDigest",
        ]
        funding_schema = {
            "type": "object",
            "additionalProperties": False,
            "required": funding_fields,
            "properties": {field: {"type": "string"} for field in funding_fields},
        }
        action_schema = deepcopy(legacy[self.ACTION_EVENT]["payload_schema"])
        action_schema["properties"]["actionKind"]["enum"].append(
            "ECONOMICS_IMPORT"
        )
        snapshot_fields = [
            "snapshotBatchId",
            "fiscalYear",
            "asOf",
            "reportingCurrency",
            "fxSnapshotDigest",
            "denominatorState",
            "denominatorUnknownReason",
            "denominator",
            "denominatorApprovalDigest",
            "entrySetDigest",
            "snapshotDigest",
            "receiptDigest",
        ]
        snapshot_schema = {
            "type": "object",
            "additionalProperties": False,
            "required": snapshot_fields,
            "properties": {field: {"type": "string"} for field in snapshot_fields},
        }
        sku_fields = [
            "evaluationId",
            "deploymentId",
            "organizationId",
            "sku",
            "environment",
            "readinessStage",
            "configurationDigest",
            "catalogVersion",
            "catalogDigest",
            "policyDigest",
            "offeredCapabilitySetDigest",
            "itemIdentitySetDigest",
            "evaluationIdentityDigest",
            "evaluatedAt",
            "evidenceCutoffAt",
            "itemCount",
            "requiredItemCount",
            "satisfiedRequiredItemCount",
            "blockedRequiredItemCount",
            "unknownRequiredItemCount",
            "itemSetDigest",
            "state",
            "blockerSetDigest",
            "evaluationDigest",
            "receiptDigest",
        ]
        sku_schema = {
            "type": "object",
            "additionalProperties": False,
            "required": sku_fields,
            "properties": {field: {"type": "string"} for field in sku_fields},
        }
        declarations = [
            {
                "event_type": self.FUNDING_EVENT,
                "ordered_current_upsert_position": 1,
                "prior_source_identity": {
                    "migration": "0030_v13_submission_session_hardening.sql",
                    "event_ordinal": 81,
                    "event_type": self.FUNDING_EVENT,
                    "payload_schema_uri": "payloads/governance_funding_disclosure_published_v1.schema.json",
                    "embedded_payload_schema_canonical_sha256": self.FUNDING_DIGEST,
                },
                "current_payload_schema_path": "specs/events/payloads/governance_funding_disclosure_published_v1.schema.json",
                "current_payload_schema_sha256": "1" * 64,
                "current_fields_exactly": funding_fields,
                "reason": "test forward closure",
            },
            {
                "event_type": self.ACTION_EVENT,
                "ordered_current_upsert_position": 2,
                "prior_source_identity": {
                    "migration": "0030_v13_submission_session_hardening.sql",
                    "event_ordinal": 13,
                    "event_type": self.ACTION_EVENT,
                    "payload_schema_uri": "payloads/action_proposal_created_v1.schema.json",
                    "embedded_payload_schema_canonical_sha256": self.ACTION_DIGEST,
                },
                "current_payload_schema_path": "specs/events/payloads/action_proposal_created_v1.schema.json",
                "current_payload_schema_sha256": "2" * 64,
                "current_change": "add ECONOMICS_IMPORT to the closed actionKind enum",
                "reason": "test forward closure",
            },
            {
                "event_type": self.SNAPSHOT_EVENT,
                "ordered_current_upsert_position": 3,
                "prior_source_identity": {
                    "migration": "0030_v13_submission_session_hardening.sql",
                    "event_ordinal": 82,
                    "event_type": self.SNAPSHOT_EVENT,
                    "payload_schema_uri": (
                        "payloads/governance_funding_snapshot_created_v1.schema.json"
                    ),
                    "embedded_payload_schema_canonical_sha256": (
                        self.SNAPSHOT_DIGEST
                    ),
                },
                "current_payload_schema_path": (
                    "specs/events/payloads/"
                    "governance_funding_snapshot_created_v1.schema.json"
                ),
                "current_payload_schema_sha256": "3" * 64,
                "current_fields_exactly": snapshot_fields,
                "reason": "test forward closure",
            },
            {
                "event_type": self.SKU_EVENT,
                "ordered_current_upsert_position": 4,
                "prior_source_identity": {
                    "migration": "0030_v13_submission_session_hardening.sql",
                    "event_ordinal": 49,
                    "event_type": self.SKU_EVENT,
                    "payload_schema_uri": (
                        "payloads/commercial_sku_readiness_evaluated_v1.schema.json"
                    ),
                    "embedded_payload_schema_canonical_sha256": self.SKU_DIGEST,
                },
                "current_payload_schema_path": (
                    "specs/events/payloads/"
                    "commercial_sku_readiness_evaluated_v1.schema.json"
                ),
                "current_payload_schema_sha256": "4" * 64,
                "current_fields_exactly": sku_fields,
                "reason": "test forward closure",
            },
        ]
        actual = [
            {
                **{
                    key: legacy[self.FUNDING_EVENT][key]
                    for key in (
                        "event_type",
                        "category",
                        "schema_version",
                        "active",
                        "payload_schema_uri",
                    )
                },
                "payload_schema": funding_schema,
            },
            {
                **{
                    key: legacy[self.ACTION_EVENT][key]
                    for key in (
                        "event_type",
                        "category",
                        "schema_version",
                        "active",
                        "payload_schema_uri",
                    )
                },
                "payload_schema": action_schema,
            },
            {
                **{
                    key: legacy[self.SNAPSHOT_EVENT][key]
                    for key in (
                        "event_type",
                        "category",
                        "schema_version",
                        "active",
                        "payload_schema_uri",
                    )
                },
                "payload_schema": snapshot_schema,
            },
            {
                **{
                    key: legacy[self.SKU_EVENT][key]
                    for key in (
                        "event_type",
                        "category",
                        "schema_version",
                        "active",
                        "payload_schema_uri",
                    )
                },
                "payload_schema": sku_schema,
            },
        ]
        return declarations, actual

    def test_legacy_override_sources_are_byte_pinned(self) -> None:
        rows = self._legacy_rows()

        self.assertEqual(rows[self.ACTION_EVENT]["event_ordinal"], 13)
        self.assertEqual(rows[self.FUNDING_EVENT]["event_ordinal"], 81)
        self.assertEqual(rows[self.SNAPSHOT_EVENT]["event_ordinal"], 82)
        self.assertEqual(rows[self.SKU_EVENT]["event_ordinal"], 49)
        self.assertEqual(
            _canonical_json_sha256(rows[self.ACTION_EVENT]["payload_schema"]),
            self.ACTION_DIGEST,
        )
        self.assertEqual(
            _canonical_json_sha256(rows[self.FUNDING_EVENT]["payload_schema"]),
            self.FUNDING_DIGEST,
        )
        self.assertEqual(
            _canonical_json_sha256(rows[self.SNAPSHOT_EVENT]["payload_schema"]),
            self.SNAPSHOT_DIGEST,
        )
        self.assertEqual(
            _canonical_json_sha256(rows[self.SKU_EVENT]["payload_schema"]),
            self.SKU_DIGEST,
        )

    def test_historical_override_requires_exact_prior_digest_and_change(self) -> None:
        declarations, actual = self._valid_override_inventory()
        result = Validation()

        _validate_historical_event_forward_overrides(
            SCRIPTS.parent,
            result,
            migration_label="0041",
            overrides=declarations,
            actual_overrides=actual,
        )

        self.assertEqual(result.errors, [])
        declarations[0]["prior_source_identity"][
            "embedded_payload_schema_canonical_sha256"
        ] = "0" * 64
        drifted = Validation()
        _validate_historical_event_forward_overrides(
            SCRIPTS.parent,
            drifted,
            migration_label="0041",
            overrides=declarations,
            actual_overrides=actual,
        )
        self.assertIn(
            f"0041 historical embedded payload schema digest differs for {self.FUNDING_EVENT}",
            drifted.errors,
        )

    def test_split_event_declaration_keeps_owned_then_override_order(self) -> None:
        contract = {
            "event_registry_contract": {
                "owned_events_in_order": [
                    {
                        "event_type": "owned.v1",
                        "payload_schema_path": "specs/events/payloads/owned.schema.json",
                    }
                ],
                "historical_event_forward_overrides": [
                    {
                        "event_type": "overridden.v1",
                        "current_payload_schema_path": "specs/events/payloads/overridden.schema.json",
                        "current_payload_schema_sha256": "3" * 64,
                    }
                ],
            }
        }
        result = Validation()

        owned, overrides, combined = _declared_event_inventory(
            contract,
            result,
            "0041",
        )

        self.assertEqual(result.errors, [])
        self.assertEqual([row["event_type"] for row in owned], ["owned.v1"])
        self.assertEqual(
            [row["event_type"] for row in overrides],
            ["overridden.v1"],
        )
        self.assertEqual(
            [row["event_type"] for row in combined],
            ["owned.v1", "overridden.v1"],
        )


class ForwardRelationExtensionTests(unittest.TestCase):
    def test_added_candidate_key_can_bind_an_exact_forward_column(self) -> None:
        rows = {
            "ops.invoice_facts": {
                "columns": {
                    "id": {"type": "uuid", "nullable": False},
                },
                "primary_key": ["id"],
            }
        }
        document = {
            "existing_relation_changes": [
                {
                    "relation": "ops.invoice_facts",
                    "added_columns": [
                        {
                            "name": "record_digest",
                            "type": "char(64)",
                            "nullable": False,
                            "default": None,
                        }
                    ],
                    "added_candidate_keys": [
                        {
                            "name": "invoice_facts_record_reference_uq",
                            "columns": ["id", "record_digest"],
                        }
                    ],
                }
            ]
        }
        result = Validation()

        columns = _added_columns(document, rows, result)
        keys = _added_candidate_keys(document, rows, result, columns)

        self.assertEqual(result.errors, [])
        self.assertEqual(columns, {"ops.invoice_facts": ("record_digest",)})
        self.assertEqual(
            keys,
            {
                "ops.invoice_facts": (
                    (
                        "invoice_facts_record_reference_uq",
                        ("id", "record_digest"),
                    ),
                )
            },
        )

        missing_column_result = Validation()
        _added_candidate_keys(document, rows, missing_column_result, {})
        self.assertTrue(
            any(
                "references unknown columns" in error
                for error in missing_column_result.errors
            ),
            missing_column_result.errors,
        )

    def test_economics_approval_detail_is_an_additive_nineteenth_branch(self) -> None:
        root = SCRIPTS.parent
        base = yaml.safe_load(
            (
                root
                / "specs/database/addendum/0026-agent-action-approval.yaml"
            ).read_text(encoding="utf-8")
        )
        extension = yaml.safe_load(
            (
                root
                / "specs/database/addendum/0041-r6e-monetization-runtime.yaml"
            ).read_text(encoding="utf-8")
        )
        base_kinds = set(
            base["closed_json_types"]["ApprovalBindingV1"][
                "action_detail_kinds"
            ]
        )
        extension_contract = extension["economics_import_runtime_contract"]

        self.assertEqual(len(base_kinds), 18)
        self.assertNotIn("ECONOMICS_IMPORT", base_kinds)
        self.assertEqual(
            {
                extension_contract["action_kind"]: extension_contract[
                    "typed_detail_relation"
                ]
            },
            {
                "ECONOMICS_IMPORT": (
                    "ops.action_approval_economics_import_details"
                )
            },
        )
        self.assertEqual(
            base_kinds | {extension_contract["action_kind"]},
            set(APPROVAL_DETAIL_RELATIONS),
        )
        self.assertEqual(len(APPROVAL_DETAIL_RELATIONS), 19)


class StableDerivationSnapshotTests(unittest.TestCase):
    def test_complete_hash_map_cannot_make_a_pending_snapshot_final(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fragment = root / "fragment.yaml"
            payload = b"status: FINAL\n"
            fragment.write_bytes(payload)
            contract = {
                "relation_inventory": {
                    "stable_derivation_snapshot": {
                        "snapshot_status": "PENDING_STABLE_0041_DERIVATION",
                        "input_sha256": {
                            "fragment.yaml": hashlib.sha256(payload).hexdigest(),
                        },
                    }
                }
            }
            result = Validation()

            with patch(
                "validation.design_database_derivation.PHYSICAL_TABLE_PATHS",
                ("fragment.yaml",),
            ):
                validate_derivation_hashes(root, contract, result)

        self.assertEqual(
            result.errors,
            ["database stable derivation snapshot is not final"],
        )


class MigrationOrderingScriptTests(unittest.TestCase):
    def test_additive_role_ddl_is_rejected_at_top_level(self) -> None:
        with self.assertRaisesRegex(
            MigrationVerificationError,
            r"role DDL is forbidden \(CreateRoleStmt\)",
        ):
            verify_role_ddl_closure(
                "CREATE ROLE gurine_runtime NOLOGIN;",
                "0041_r6e_monetization_runtime.sql",
            )

    def test_additive_role_ddl_is_rejected_inside_do_block(self) -> None:
        sql = """
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='gurine_runtime') THEN
    CREATE ROLE gurine_runtime NOLOGIN;
  END IF;
  ALTER ROLE gurine_runtime NOINHERIT;
END
$$;
"""

        with self.assertRaisesRegex(
            MigrationVerificationError,
            r"role DDL is forbidden \(CreateRoleStmt\)",
        ):
            verify_role_ddl_closure(
                sql,
                "0041_r6e_monetization_runtime.sql",
            )

    def test_additive_role_membership_change_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            MigrationVerificationError,
            r"role DDL is forbidden \(GrantRoleStmt\)",
        ):
            verify_role_ddl_closure(
                "GRANT gurine_owner TO gurine_runtime WITH SET TRUE;",
                "0041_r6e_monetization_runtime.sql",
            )

    def test_additive_dynamic_role_ddl_is_rejected_inside_do(self) -> None:
        sql = """
DO $$
BEGIN
  EXECUTE 'CREATE ' || 'ROLE gurine_runtime NOLOGIN';
END
$$;
"""

        with self.assertRaisesRegex(
            MigrationVerificationError,
            r"dynamic SQL in DO is forbidden while checking role DDL",
        ):
            verify_role_ddl_closure(
                sql,
                "0041_r6e_monetization_runtime.sql",
            )

    def test_object_acl_is_not_misclassified_as_role_ddl(self) -> None:
        verify_role_ddl_closure(
            "GRANT USAGE ON SCHEMA ops TO gurine_runtime;",
            "0041_r6e_monetization_runtime.sql",
        )

    def test_immutable_0030_role_profile_is_the_only_exception(self) -> None:
        verify_role_ddl_closure(
            "CREATE ROLE gurine_historical NOLOGIN;",
            "0030_v13_submission_session_hardening.sql",
        )

    def test_control_fixture_crosses_0038_then_0039_then_0040_boundary(self) -> None:
        script = (SCRIPTS / "test-control-flow.sh").read_text(encoding="utf-8")
        provision_roles = script.index("r6e_test_migrations_provision")
        pre_r6d_loop = script.index('for migration in "${migrations[@]}"')
        seed = script.index("<db/test-fixtures/control-runtime-seed.sql")
        apply_0038 = script.index(
            'r6e_test_migrations_apply_next "$r6d_legacy_boundary_migration"'
        )
        apply_0039 = script.index(
            'r6e_test_migrations_apply_next "$r6d_authority_closure_migration"'
        )
        apply_0040 = script.index(
            'r6e_test_migrations_apply_next '
            '"$r6d_privacy_authority_closure_migration"'
        )
        apply_r6e_tail = script.index("r6e_test_migrations_apply_remaining")
        policy_fixture = script.index("< db/test-fixtures/r6d-approved-policy-authority.sql")

        self.assertLess(provision_roles, pre_r6d_loop)
        self.assertLess(pre_r6d_loop, seed)
        self.assertLess(seed, apply_0038)
        self.assertLess(apply_0038, apply_0039)
        self.assertLess(apply_0039, apply_0040)
        self.assertLess(apply_0040, apply_r6e_tail)
        self.assertLess(apply_r6e_tail, policy_fixture)
        self.assertIn(
            'if [[ "$migration" == "$r6d_legacy_boundary_migration" ]]',
            script,
        )
        self.assertIn(
            "source scripts/apply-test-migrations-with-r6e-roles.sh",
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

        self.assertEqual(declared_count, EXPECTED_RUNTIME_MIGRATIONS)
        self.assertEqual(declared_count, len(migrations))
        self.assertEqual(
            migrations[-1].name,
            EXPECTED_ADDITIVE_MIGRATIONS[-1],
        )

    def test_late_additive_validator_tracks_runtime_migration_suffix(self) -> None:
        validated_migrations = tuple(
            migration_name
            for migration_name, _contract_name, _label, _marker_count in (
                _LATE_ADDITIVE_INVENTORY_CONTRACTS
            )
        )

        self.assertEqual(
            validated_migrations,
            EXPECTED_ADDITIVE_MIGRATIONS[-len(validated_migrations):],
        )

    def test_r6e_event_registry_is_exactly_two_events(self) -> None:
        self.assertEqual(
            _R6E_EVENT_TYPES,
            (
                "donation.fact_recorded.v1",
                "notification.payment_review_requested.v1",
            ),
        )


if __name__ == "__main__":
    unittest.main()
