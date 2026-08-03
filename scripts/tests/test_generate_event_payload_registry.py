from __future__ import annotations

from copy import deepcopy
import sys
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import generate_event_payload_registry as generator


UUID = "123e4567-e89b-42d3-a456-426614174000"
SHA256 = "a" * 64


def agent_run_payload() -> dict[str, object]:
    return {
        "runId": UUID,
        "aggregateVersion": 1,
        "priorStatus": None,
        "priorControlState": None,
        "nextStatus": "RUNNING",
        "nextControlState": "ACTIVE",
        "affectedProviderTurnId": None,
        "affectedToolCallId": None,
        "reconciliationEvidenceId": None,
        "reconciliationEvidenceSha256": None,
        "proofKind": "COMMAND_INPUT",
        "proofSha256": SHA256,
        "budgetDisposition": "RESERVED",
        "budgetResolutionSetSha256": SHA256,
        "actorKind": "CONTROL_API",
        "actorId": UUID,
        "reasonCode": "RUN_STARTED",
        "reasonSha256": SHA256,
        "occurredAt": "2026-07-31T00:00:00Z",
        "receiptSha256": SHA256,
    }


class EventPayloadForwardOverrideTests(unittest.TestCase):
    def assert_schema_valid(
        self,
        schema: dict[str, object],
        payload: dict[str, object],
    ) -> None:
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        errors = sorted(validator.iter_errors(payload), key=lambda error: list(error.path))
        self.assertEqual(errors, [], [error.message for error in errors])

    def assert_schema_invalid(
        self,
        schema: dict[str, object],
        payload: dict[str, object],
    ) -> None:
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        self.assertFalse(validator.is_valid(payload))

    def override_schemas(self) -> dict[str, dict[str, object]]:
        return {event_type: schema for event_type, _, schema in generator.forward_override_rows()}

    def test_attachment_kind_is_required_and_closed(self) -> None:
        rows = generator.forward_override_rows()

        self.assertEqual(
            [event_type for event_type, _, _ in rows],
            list(generator.FORWARD_OVERRIDE_EVENT_TYPES),
        )
        event_type, uri, schema = rows[0]
        self.assertEqual(event_type, "attachment.scan_completed.v1")
        self.assertEqual(uri, "payloads/attachment_scan_completed_v1.schema.json")
        self.assertEqual(
            schema["required"],
            ["attachment_id", "attachment_kind", "scan_status", "sha256"],
        )
        self.assertEqual(
            schema["properties"]["attachment_kind"],
            {"type": "string", "enum": ["CORRECTION", "RESPONSE"]},
        )

    def test_attachment_schema_accepts_only_the_closed_payload(self) -> None:
        schema = self.override_schemas()[generator.ATTACHMENT_SCAN_EVENT_TYPE]
        payload = {
            "attachment_id": "attachment-1",
            "attachment_kind": "CORRECTION",
            "scan_status": "CLEAN",
            "sha256": SHA256,
        }

        Draft202012Validator.check_schema(schema)
        self.assert_schema_valid(schema, payload)
        with_extra = {**payload, "unreviewed": True}
        self.assert_schema_invalid(schema, with_extra)
        missing_kind = {key: value for key, value in payload.items() if key != "attachment_kind"}
        self.assert_schema_invalid(schema, missing_kind)

    def test_agent_actor_schema_accepts_legacy_and_typed_service_variants(self) -> None:
        schema = self.override_schemas()[generator.AGENT_RUN_CONTROL_EVENT_TYPE]
        legacy_uuid = agent_run_payload()
        legacy_null = {**legacy_uuid, "actorKind": "ANALYSIS_WORKER", "actorId": None}
        typed_service = {
            **legacy_uuid,
            "actorType": "SERVICE",
            "actorKind": "ANALYSIS_WORKER",
            "actorId": "analysis-worker",
        }

        Draft202012Validator.check_schema(schema)
        for payload in (legacy_uuid, legacy_null, typed_service):
            with self.subTest(payload=payload):
                self.assert_schema_valid(schema, payload)

    def test_agent_actor_schema_rejects_crossed_variants_and_extra_fields(self) -> None:
        schema = self.override_schemas()[generator.AGENT_RUN_CONTROL_EVENT_TYPE]
        base = agent_run_payload()
        malformed_actor_shapes = [
            {
                "actorType": "SERVICE",
                "actorKind": "ANALYSIS_WORKER",
                "actorId": UUID,
            },
            {
                "actorType": "SERVICE",
                "actorKind": "CONTROL_API",
                "actorId": "analysis-worker",
            },
            {"actorKind": "ANALYSIS_WORKER", "actorId": "analysis-worker"},
            {
                "actorType": "SERVICE",
                "actorKind": "ANALYSIS_WORKER",
                "actorId": None,
            },
            {
                "actorType": "LEGACY_ACTOR_TYPE_MUST_BE_ABSENT",
                "actorKind": "CONTROL_API",
                "actorId": UUID,
            },
        ]

        for actor_shape in malformed_actor_shapes:
            payload = {**base, **actor_shape}
            with self.subTest(actor_shape=actor_shape):
                self.assert_schema_invalid(schema, payload)
        with_extra = {**base, "unreviewed": True}
        self.assert_schema_invalid(schema, with_extra)

    def test_agent_actor_override_rejects_unsupported_db_combinators(self) -> None:
        schema = self.override_schemas()[generator.AGENT_RUN_CONTROL_EVENT_TYPE]

        for keyword in ("not", "if", "allOf"):
            drifted = deepcopy(schema)
            drifted[keyword] = {} if keyword != "allOf" else []
            with self.subTest(keyword=keyword):
                with self.assertRaisesRegex(ValueError, "unsupported keyword"):
                    generator.validate_agent_run_control_schema(drifted)

    def test_normalization_event_is_catalogued_but_not_forward_overridden(self) -> None:
        registry = {event_type: schema for event_type, _, _, _, schema in generator.registry_rows()}
        schema = registry["normalization.run_completed.v1"]

        self.assertEqual(len(schema["required"]), 14)
        self.assertEqual(set(schema["required"]), set(schema["properties"]))
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(
            schema["properties"]["errorCode"],
            {
                "type": ["string", "null"],
                "pattern": "^[A-Z][A-Z0-9_]{0,127}$",
            },
        )
        failed_payload = {
            "normalizationRunId": UUID,
            "state": "FAILED",
            "aggregateVersion": 2,
            "outputObjectType": None,
            "outputObjectId": None,
            "outputObjectVersion": None,
            "outputPayloadSha256": None,
            "fieldProvenanceCount": 0,
            "fieldProvenanceSetSha256": None,
            "errorCode": "PARSER_OUTPUT_INVALID",
            "errorSha256": SHA256,
            "terminalReceiptSha256": SHA256,
            "auditEventId": UUID,
            "occurredAt": "2026-07-31T00:00:00Z",
        }
        self.assert_schema_valid(schema, failed_payload)
        invalid_error = {**failed_payload, "errorCode": "raw provider error"}
        self.assert_schema_invalid(schema, invalid_error)
        self.assertNotIn(
            "normalization.run_completed.v1",
            generator.FORWARD_OVERRIDE_EVENT_TYPES,
        )

    def test_render_is_deterministic_and_forward_only(self) -> None:
        first = generator.render_forward_overrides()
        second = generator.render_forward_overrides()

        self.assertEqual(first, second)
        self.assertEqual(first.count(generator.START), 1)
        self.assertEqual(first.count(generator.END), 1)
        self.assertIn("UPDATE ops.event_types AS registered", first)
        self.assertIn('"enum":["CORRECTION","RESPONSE"]', first)
        self.assertIn(
            '"required":["attachment_id","attachment_kind","scan_status","sha256"]',
            first,
        )
        self.assertIn("'agent.run_control_changed.v2'", first)
        self.assertIn('"actorType":{"enum":["SERVICE"],"type":"string"}', first)
        self.assertIn('"actorId":{"const":"analysis-worker"}', first)
        self.assertIn("IF v_updated <> 2", first)
        self.assertNotIn("normalization.run_completed.v1", first)
        self.assertNotIn("INSERT INTO ops.event_types", first)
        self.assertNotIn("SET active=false", first)

    def test_region_replacement_preserves_unrelated_migration_text(self) -> None:
        current = "BEGIN;\n" + generator.START + "stale\n" + generator.END + "COMMIT;\n"
        generated = generator.render_forward_overrides()

        updated = generator.replace_generated_region(current, generated)

        self.assertTrue(updated.startswith("BEGIN;\n"))
        self.assertTrue(updated.endswith("COMMIT;\n"))
        self.assertEqual(updated.count(generator.START), 1)
        self.assertEqual(updated.count(generator.END), 1)

    def test_region_replacement_fails_closed_without_exact_markers(self) -> None:
        with self.assertRaisesRegex(ValueError, "start marker"):
            generator.replace_generated_region("BEGIN;\nCOMMIT;\n", "generated")

    def test_generator_targets_current_additive_migration(self) -> None:
        self.assertEqual(
            generator.TARGET_MIGRATION.name,
            "0037_r6c_conflict_investigation.sql",
        )
        source = Path(generator.__file__).read_text(encoding="utf-8")
        self.assertNotIn('db/migrations/0030_', source)


if __name__ == "__main__":
    unittest.main()
