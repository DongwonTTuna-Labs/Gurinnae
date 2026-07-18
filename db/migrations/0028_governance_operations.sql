BEGIN;
-- Source-derived 0028 physical registry: 19 relations.
-- Existing 0001..0024 migrations are byte-immutable; this migration is additive.
SET LOCAL search_path = pg_catalog, public;
CREATE OR REPLACE FUNCTION ops.is_lower_sha256(text) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 ~ '^[0-9a-f]{64}$' $$;
ALTER FUNCTION ops.is_lower_sha256(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.is_lower_sha256(text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.text_array_is_sorted_unique(text[]) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND cardinality($1) >= 0 AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL) AND $1 = ARRAY(SELECT value FROM unnest($1) AS item(value) ORDER BY value COLLATE "C") $$;
ALTER FUNCTION ops.text_array_is_sorted_unique(text[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.text_array_is_sorted_unique(text[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.uuid_array_is_sorted_unique(uuid[]) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL) $$;
ALTER FUNCTION ops.uuid_array_is_sorted_unique(uuid[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.uuid_array_is_sorted_unique(uuid[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.uuid_array_is_unique(uuid[]) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL) $$;
ALTER FUNCTION ops.uuid_array_is_unique(uuid[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.uuid_array_is_unique(uuid[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.guard_journey_instance_update_v1() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.guard_journey_instance_update_v1() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.guard_journey_handoff_update_v1() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.guard_journey_handoff_update_v1() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.check_journey_decision_idempotency_complete_v1() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.check_journey_decision_idempotency_complete_v1() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.check_journey_instance_head_v1() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.check_journey_instance_head_v1() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.check_journey_instance_transition_v1() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.check_journey_instance_transition_v1() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.check_journey_handoff_binding_v1() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.check_journey_handoff_binding_v1() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.check_journey_handoff_head_v1() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.check_journey_handoff_head_v1() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.check_journey_receipt_chain_v1() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.check_journey_receipt_chain_v1() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.check_journey_receipt_parent_versions_v1() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.check_journey_receipt_parent_versions_v1() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.check_journey_receipt_state_owner_v1() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.check_journey_receipt_state_owner_v1() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION editorial.conflict_blocker_array_is_canonical(text[]) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL $$;
ALTER FUNCTION editorial.conflict_blocker_array_is_canonical(text[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.conflict_blocker_array_is_canonical(text[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.conflict_finding_set_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION editorial.conflict_finding_set_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.conflict_finding_set_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.conflict_evidence_ref_array_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION editorial.conflict_evidence_ref_array_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.conflict_evidence_ref_array_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.incident_evidence_ref_array_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.incident_evidence_ref_array_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.incident_evidence_ref_array_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.incident_transition_detail_is_valid(text,jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $2 IS NOT NULL AND jsonb_typeof($2) = 'object' $$;
ALTER FUNCTION ops.incident_transition_detail_is_valid(text,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.incident_transition_detail_is_valid(text,jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.retention_location_count_array_is_valid(text,jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $2 IS NOT NULL AND jsonb_typeof($2) = 'object' $$;
ALTER FUNCTION ops.retention_location_count_array_is_valid(text,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.retention_location_count_array_is_valid(text,jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.retention_receipt_counts_are_valid(text,jsonb,bigint,bigint,bigint,bigint,bigint,bigint,bigint) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $2 IS NOT NULL AND jsonb_typeof($2) = 'object' $$;
ALTER FUNCTION ops.retention_receipt_counts_are_valid(text,jsonb,bigint,bigint,bigint,bigint,bigint,bigint,bigint) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.retention_receipt_counts_are_valid(text,jsonb,bigint,bigint,bigint,bigint,bigint,bigint,bigint) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.privacy_inventory_set_is_valid(text,jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $2 IS NOT NULL AND jsonb_typeof($2) = 'object' $$;
ALTER FUNCTION ops.privacy_inventory_set_is_valid(text,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.privacy_inventory_set_is_valid(text,jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.sli_evidence_set_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.sli_evidence_set_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.sli_evidence_set_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.sli_exclusion_set_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.sli_exclusion_set_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.sli_exclusion_set_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.sli_telemetry_gap_set_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.sli_telemetry_gap_set_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.sli_telemetry_gap_set_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.publication_snapshot_member_set_is_valid(uuid,bigint,jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $3 IS NOT NULL AND jsonb_typeof($3) = 'object' $$;
ALTER FUNCTION editorial.publication_snapshot_member_set_is_valid(uuid,bigint,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.publication_snapshot_member_set_is_valid(uuid,bigint,jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.privacy_outcome_manifest_is_valid(text,char(64),char(64),jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $4 IS NOT NULL AND jsonb_typeof($4) = 'object' $$;
ALTER FUNCTION ops.privacy_outcome_manifest_is_valid(text,char(64),char(64),jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.privacy_outcome_manifest_is_valid(text,char(64),char(64),jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION intake.appeal_remedy_binding_is_valid(text,jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $2 IS NOT NULL AND jsonb_typeof($2) = 'object' $$;
ALTER FUNCTION intake.appeal_remedy_binding_is_valid(text,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION intake.appeal_remedy_binding_is_valid(text,jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.audit_export_scope_manifest_is_valid(text,timestamptz,timestamptz,jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $4 IS NOT NULL AND jsonb_typeof($4) = 'object' $$;
ALTER FUNCTION ops.audit_export_scope_manifest_is_valid(text,timestamptz,timestamptz,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.audit_export_scope_manifest_is_valid(text,timestamptz,timestamptz,jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.audit_export_field_rule_set_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.audit_export_field_rule_set_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.audit_export_field_rule_set_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.audit_export_object_receipt_is_valid(text,bigint,char(64),char(64),char(64),jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $6 IS NOT NULL AND jsonb_typeof($6) = 'object' $$;
ALTER FUNCTION ops.audit_export_object_receipt_is_valid(text,bigint,char(64),char(64),char(64),jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.audit_export_object_receipt_is_valid(text,bigint,char(64),char(64),char(64),jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.sli_exclusion_count(jsonb) RETURNS bigint LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT COALESCE((SELECT sum((value->>'excludedCount')::bigint) FROM jsonb_array_elements($1->'items') AS item(value)),0)::bigint $$;
ALTER FUNCTION ops.sli_exclusion_count(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.sli_exclusion_count(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION editorial.enforce_legal_hold_release_insert() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION editorial.enforce_legal_hold_release_insert() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION editorial.enforce_legal_hold_placement_insert() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION editorial.enforce_legal_hold_placement_insert() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.enforce_capability_activation_graph() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.enforce_capability_activation_graph() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION editorial.enforce_publication_gate_graph() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION editorial.enforce_publication_gate_graph() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.enforce_retention_decision_insert() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.enforce_retention_decision_insert() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.enforce_retention_execution_graph() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.enforce_retention_execution_graph() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.enforce_incident_event_insert() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.enforce_incident_event_insert() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.enforce_schedule_revision_insert() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.enforce_schedule_revision_insert() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.enforce_sli_reciprocal_pair() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.enforce_sli_reciprocal_pair() OWNER TO gurine_migrator;
CREATE TABLE ops.legal_hold_target_anchors (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  target_kind text NOT NULL,
  target_id uuid NOT NULL,
  target_version bigint NOT NULL,
  target_digest char(64) NOT NULL,
  case_id uuid,
  case_review_snapshot_id uuid,
  publication_revision_id uuid,
  evidence_id uuid,
  response_id uuid,
  source_document_id uuid,
  source_asset_id uuid,
  research_artifact_id uuid,
  research_asset_id uuid,
  privacy_request_id uuid,
  privacy_request_type text,
  communication_subject_id uuid,
  communication_subject_origin_digest char(64),
  anchor_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  classification text NOT NULL DEFAULT 'RESTRICTED_GOVERNANCE',
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_legal_hold_target_anchors_1 PRIMARY KEY (id)
);
ALTER TABLE ops.legal_hold_target_anchors OWNER TO gurine_migrator;
ALTER TABLE ops.legal_hold_target_anchors ADD CONSTRAINT legal_hold_target_anchors_digest_uq UNIQUE (anchor_digest);
ALTER TABLE ops.legal_hold_target_anchors ADD CONSTRAINT legal_hold_target_anchors_id_digest_uq UNIQUE (id, anchor_digest);
ALTER TABLE ops.legal_hold_target_anchors ADD CONSTRAINT legal_hold_target_anchors_target_uq UNIQUE (target_kind, target_id, target_version, target_digest);
ALTER TABLE ops.legal_hold_target_anchors ADD CONSTRAINT legal_hold_target_anchors_kind_ck CHECK (target_kind IN ('CASE','PUBLICATION','EVIDENCE','RESPONSE','SOURCE_ASSET','RESEARCH_ARTIFACT','PRIVACY_REQUEST','COMMUNICATION_SUBJECT'));
ALTER TABLE ops.legal_hold_target_anchors ADD CONSTRAINT legal_hold_target_anchors_version_ck CHECK (target_version > 0);
ALTER TABLE ops.legal_hold_target_anchors ADD CONSTRAINT legal_hold_target_anchors_shape_ck CHECK ((target_kind = 'CASE' AND case_id = target_id AND case_review_snapshot_id IS NOT NULL AND num_nonnulls(publication_revision_id,evidence_id,response_id,source_document_id,source_asset_id,research_artifact_id,research_asset_id,privacy_request_id,privacy_request_type,communication_subject_id,communication_subject_origin_digest) = 0) OR (target_kind = 'PUBLICATION' AND publication_revision_id = target_id AND num_nonnulls(case_id,case_review_snapshot_id,evidence_id,response_id,source_document_id,source_asset_id,research_artifact_id,research_asset_id,privacy_request_id,privacy_request_type,communication_subject_id,communication_subject_origin_digest) = 0) OR (target_kind = 'EVIDENCE' AND evidence_id = target_id AND num_nonnulls(case_id,case_review_snapshot_id,publication_revision_id,response_id,source_document_id,source_asset_id,research_artifact_id,research_asset_id,privacy_request_id,privacy_request_type,communication_subject_id,communication_subject_origin_digest) = 0) OR (target_kind = 'RESPONSE' AND response_id = target_id AND num_nonnulls(case_id,case_review_snapshot_id,publication_revision_id,evidence_id,source_document_id,source_asset_id,research_artifact_id,research_asset_id,privacy_request_id,privacy_request_type,communication_subject_id,communication_subject_origin_digest) = 0) OR (target_kind = 'SOURCE_ASSET' AND source_asset_id = target_id AND source_document_id IS NOT NULL AND num_nonnulls(case_id,case_review_snapshot_id,publication_revision_id,evidence_id,response_id,research_artifact_id,research_asset_id,privacy_request_id,privacy_request_type,communication_subject_id,communication_subject_origin_digest) = 0) OR (target_kind = 'RESEARCH_ARTIFACT' AND research_asset_id = target_id AND research_artifact_id IS NOT NULL AND num_nonnulls(case_id,case_review_snapshot_id,publication_revision_id,evidence_id,response_id,source_document_id,source_asset_id,privacy_request_id,privacy_request_type,communication_subject_id,communication_subject_origin_digest) = 0) OR (target_kind = 'PRIVACY_REQUEST' AND privacy_request_id = target_id AND privacy_request_type IN ('ACCESS','CORRECTION','DELETION','RESTRICTION') AND num_nonnulls(case_id,case_review_snapshot_id,publication_revision_id,evidence_id,response_id,source_document_id,source_asset_id,research_artifact_id,research_asset_id,communication_subject_id,communication_subject_origin_digest) = 0) OR (target_kind = 'COMMUNICATION_SUBJECT' AND communication_subject_id = target_id AND communication_subject_origin_digest IS NOT NULL AND num_nonnulls(case_id,case_review_snapshot_id,publication_revision_id,evidence_id,response_id,source_document_id,source_asset_id,research_artifact_id,research_asset_id,privacy_request_id,privacy_request_type) = 0));
ALTER TABLE ops.legal_hold_target_anchors ADD CONSTRAINT legal_hold_target_anchors_digest_ck CHECK (ops.is_lower_sha256(target_digest) AND (communication_subject_origin_digest IS NULL OR ops.is_lower_sha256(communication_subject_origin_digest)) AND ops.is_lower_sha256(anchor_digest));
ALTER TABLE ops.legal_hold_target_anchors ADD CONSTRAINT legal_hold_target_anchors_classification_ck CHECK (classification = 'RESTRICTED_GOVERNANCE');
REVOKE ALL ON ops.legal_hold_target_anchors FROM PUBLIC;
REVOKE ALL ON ops.legal_hold_target_anchors FROM gurine_workflow_worker;
REVOKE ALL ON ops.legal_hold_target_anchors FROM gurine_control_api;
REVOKE ALL ON ops.legal_hold_target_anchors FROM gurine_analysis_worker;
REVOKE ALL ON ops.legal_hold_target_anchors FROM gurine_public_projector;
REVOKE ALL ON ops.legal_hold_target_anchors FROM gurine_notification_worker;
REVOKE ALL ON ops.legal_hold_target_anchors FROM gurine_submission_api;
REVOKE ALL ON ops.legal_hold_target_anchors FROM gurine_auditor;
GRANT SELECT ON ops.legal_hold_target_anchors TO gurine_control_api;
GRANT SELECT ON ops.legal_hold_target_anchors TO gurine_workflow_worker;
GRANT SELECT ON ops.legal_hold_target_anchors TO gurine_scheduler;
CREATE TRIGGER ops_legal_hold_target_anchors_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.legal_hold_target_anchors FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE editorial.conflict_declarations (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subject_actor_id uuid NOT NULL,
  declared_by_user_id uuid NOT NULL,
  target_type text NOT NULL,
  target_id text NOT NULL,
  target_version bigint NOT NULL,
  target_digest char(64) NOT NULL,
  conflict_type text NOT NULL,
  relation_state text NOT NULL,
  materiality text NOT NULL,
  temporal_state text NOT NULL,
  source_class text NOT NULL,
  source_authority_type text NOT NULL,
  source_authority_id text NOT NULL,
  source_authority_digest char(64) NOT NULL,
  nonwaivable boolean NOT NULL DEFAULT false,
  evidence_refs jsonb NOT NULL DEFAULT '[]'::jsonb,
  evidence_set_digest char(64) NOT NULL,
  policy_digest char(64) NOT NULL,
  declaration_reason_encrypted bytea,
  declaration_reason_digest char(64) NOT NULL,
  declaration_sequence bigint NOT NULL,
  effective_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  supersedes_declaration_id uuid,
  declaration_digest char(64) NOT NULL,
  receipt_digest char(64) NOT NULL,
  classification text NOT NULL DEFAULT 'RESTRICTED_GOVERNANCE',
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_editorial_conflict_declarations_1 PRIMARY KEY (id)
);
ALTER TABLE editorial.conflict_declarations OWNER TO gurine_migrator;
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_digest_uq UNIQUE (declaration_digest);
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_receipt_uq UNIQUE (receipt_digest);
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_series_uq UNIQUE (subject_actor_id, target_type, target_id, conflict_type, source_class, source_authority_type, source_authority_id, declaration_sequence);
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_exact_fact_uq UNIQUE (subject_actor_id, target_type, target_id, conflict_type, source_class, source_authority_type, source_authority_id, effective_at, declaration_digest);
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_target_type_ck CHECK (target_type IN ('CASE','REVIEW_SNAPSHOT','ACTION_PROPOSAL','PUBLICATION','COMMUNICATION_INTENT','RESPONSE_REQUEST','LEGAL_HOLD','CAPABILITY','SOURCE_ASSET','RESEARCH_ARTIFACT','PRIVACY_REQUEST','COMMUNICATION_SUBJECT'));
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_target_id_ck CHECK (length(target_id) BETWEEN 1 AND 512 AND target_version > 0);
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_conflict_type_ck CHECK (conflict_type IN ('AUTHORSHIP','EDITING','CASE_PARTY','RECIPIENT','ROLE','PERSONAL','FAMILY','EMPLOYMENT','ADVISORY','FINANCIAL','POLITICAL','FUNDING','CUSTOMER'));
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_relation_state_ck CHECK (relation_state IN ('PRESENT','ABSENT','UNKNOWN'));
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_materiality_ck CHECK (materiality IN ('MATERIAL','NON_MATERIAL','UNKNOWN','NOT_APPLICABLE') AND temporal_state IN ('CURRENT','PAST','UNKNOWN','NOT_APPLICABLE') AND source_class IN ('SELF_DECLARED','INTERNAL_AUTHORITATIVE','EXTERNAL_AUTHORITATIVE'));
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_authority_ck CHECK (source_authority_type IN ('SELF','INTERNAL_SYSTEM','EXTERNAL_REGISTRY','SIGNED_DOCUMENT') AND length(source_authority_id) BETWEEN 1 AND 512 AND ((source_class = 'SELF_DECLARED' AND source_authority_type = 'SELF' AND source_authority_id = subject_actor_id::text) OR (source_class = 'INTERNAL_AUTHORITATIVE' AND source_authority_type = 'INTERNAL_SYSTEM') OR (source_class = 'EXTERNAL_AUTHORITATIVE' AND source_authority_type IN ('EXTERNAL_REGISTRY','SIGNED_DOCUMENT'))));
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_state_shape_ck CHECK ((relation_state = 'ABSENT' AND materiality = 'NOT_APPLICABLE' AND temporal_state = 'NOT_APPLICABLE') OR (relation_state = 'UNKNOWN' AND materiality = 'UNKNOWN' AND temporal_state = 'UNKNOWN') OR (relation_state = 'PRESENT' AND materiality IN ('MATERIAL','NON_MATERIAL','UNKNOWN') AND temporal_state IN ('CURRENT','PAST','UNKNOWN')));
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_nonwaivable_ck CHECK (nonwaivable = (relation_state = 'PRESENT' AND materiality = 'MATERIAL' AND temporal_state = 'CURRENT' AND conflict_type IN ('AUTHORSHIP','CASE_PARTY','RECIPIENT','EMPLOYMENT','FINANCIAL','FUNDING','CUSTOMER')));
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_sequence_ck CHECK (declaration_sequence > 0 AND ((declaration_sequence = 1 AND supersedes_declaration_id IS NULL) OR (declaration_sequence > 1 AND supersedes_declaration_id IS NOT NULL)));
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_time_ck CHECK (expires_at > effective_at);
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_classification_ck CHECK (classification = 'RESTRICTED_GOVERNANCE');
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_evidence_json_ck CHECK (editorial.conflict_evidence_ref_array_is_valid(evidence_refs));
ALTER TABLE editorial.conflict_declarations ADD CONSTRAINT conflict_declarations_digest_ck CHECK (ops.is_lower_sha256(target_digest) AND ops.is_lower_sha256(source_authority_digest) AND ops.is_lower_sha256(evidence_set_digest) AND ops.is_lower_sha256(policy_digest) AND ops.is_lower_sha256(declaration_reason_digest) AND ops.is_lower_sha256(declaration_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON editorial.conflict_declarations FROM PUBLIC;
REVOKE ALL ON editorial.conflict_declarations FROM gurine_workflow_worker;
REVOKE ALL ON editorial.conflict_declarations FROM gurine_control_api;
REVOKE ALL ON editorial.conflict_declarations FROM gurine_analysis_worker;
REVOKE ALL ON editorial.conflict_declarations FROM gurine_public_projector;
REVOKE ALL ON editorial.conflict_declarations FROM gurine_notification_worker;
REVOKE ALL ON editorial.conflict_declarations FROM gurine_submission_api;
REVOKE ALL ON editorial.conflict_declarations FROM gurine_auditor;
GRANT SELECT ON editorial.conflict_declarations TO gurine_control_api;
GRANT SELECT ON editorial.conflict_declarations TO gurine_workflow_worker;
CREATE TRIGGER editorial_conflict_declarations_immutable_mutation_guard BEFORE UPDATE OR DELETE ON editorial.conflict_declarations FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE editorial.conflict_snapshots (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subject_actor_id uuid NOT NULL,
  target_type text NOT NULL,
  target_id text NOT NULL,
  target_version bigint NOT NULL,
  target_digest char(64) NOT NULL,
  operation_id text NOT NULL,
  action_kind text,
  candidate_role text NOT NULL,
  declaration_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  declaration_set_digest char(64) NOT NULL,
  finding_set jsonb NOT NULL,
  finding_set_digest char(64) NOT NULL,
  authorship_digest char(64) NOT NULL,
  party_recipient_digest char(64) NOT NULL,
  role_digest char(64) NOT NULL,
  relationship_digest char(64) NOT NULL,
  funding_customer_digest char(64) NOT NULL,
  policy_digest char(64) NOT NULL,
  evaluation_state text NOT NULL,
  blocker_codes text[] NOT NULL DEFAULT '{}'::text[],
  nonwaivable_blocker_count smallint NOT NULL DEFAULT 0,
  evaluated_at timestamptz NOT NULL,
  valid_until timestamptz NOT NULL,
  evaluated_by_type text NOT NULL,
  evaluated_by_id text NOT NULL,
  snapshot_sha256 char(64) NOT NULL,
  receipt_digest char(64) NOT NULL,
  classification text NOT NULL DEFAULT 'RESTRICTED_GOVERNANCE',
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_editorial_conflict_snapshots_1 PRIMARY KEY (id)
);
ALTER TABLE editorial.conflict_snapshots OWNER TO gurine_migrator;
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_sha_uq UNIQUE (snapshot_sha256);
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_receipt_uq UNIQUE (receipt_digest);
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_exact_eval_uq UNIQUE (subject_actor_id, target_type, target_id, target_version, candidate_role, policy_digest, declaration_set_digest, evaluated_at);
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_actor_digest_uq UNIQUE (id, subject_actor_id, snapshot_sha256);
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_exact_binding_uq UNIQUE (id, subject_actor_id, target_type, target_id, target_version, target_digest, snapshot_sha256, evaluation_state, valid_until);
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_target_type_ck CHECK (target_type IN ('CASE','REVIEW_SNAPSHOT','ACTION_PROPOSAL','PUBLICATION','COMMUNICATION_INTENT','RESPONSE_REQUEST','LEGAL_HOLD','CAPABILITY','SOURCE_ASSET','RESEARCH_ARTIFACT','PRIVACY_REQUEST','COMMUNICATION_SUBJECT') AND target_version > 0);
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_operation_ck CHECK (operation_id IN ('submitReview','submitActionDecision','placeLegalHold','publishCase','releaseLegalHold','private.ExecuteApprovedAction'));
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_action_kind_ck CHECK (action_kind IS NULL OR action_kind IN ('HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION','RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH','COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE','FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR'));
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_candidate_role_ck CHECK (candidate_role IN ('AUTHOR','EDITOR','LEGAL_REVIEWER','PUBLISHER','APPROVER','EXECUTOR'));
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_state_ck CHECK (evaluation_state IN ('CLEAR','DISCLOSURE_REQUIRED','INDEPENDENT_REVIEW_REQUIRED','RECUSE_REQUIRED','BLOCKED_UNKNOWN'));
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_actor_ck CHECK (evaluated_by_type IN ('HUMAN','SERVICE') AND length(evaluated_by_id) BETWEEN 1 AND 512);
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_arrays_ck CHECK (cardinality(declaration_ids) <= 1300 AND ops.uuid_array_is_sorted_unique(declaration_ids) AND editorial.conflict_blocker_array_is_canonical(blocker_codes) AND cardinality(blocker_codes) <= 11);
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_finding_set_ck CHECK (editorial.conflict_finding_set_is_valid(finding_set));
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_result_ck CHECK ((evaluation_state = 'CLEAR' AND cardinality(blocker_codes) = 0 AND nonwaivable_blocker_count = 0) OR (evaluation_state <> 'CLEAR' AND cardinality(blocker_codes) > 0));
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_nonwaivable_ck CHECK (nonwaivable_blocker_count BETWEEN 0 AND cardinality(blocker_codes));
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_time_ck CHECK (valid_until > evaluated_at);
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_classification_ck CHECK (classification = 'RESTRICTED_GOVERNANCE');
ALTER TABLE editorial.conflict_snapshots ADD CONSTRAINT conflict_snapshots_digest_ck CHECK (ops.is_lower_sha256(target_digest) AND ops.is_lower_sha256(declaration_set_digest) AND ops.is_lower_sha256(finding_set_digest) AND ops.is_lower_sha256(authorship_digest) AND ops.is_lower_sha256(party_recipient_digest) AND ops.is_lower_sha256(role_digest) AND ops.is_lower_sha256(relationship_digest) AND ops.is_lower_sha256(funding_customer_digest) AND ops.is_lower_sha256(policy_digest) AND ops.is_lower_sha256(snapshot_sha256) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON editorial.conflict_snapshots FROM PUBLIC;
REVOKE ALL ON editorial.conflict_snapshots FROM gurine_workflow_worker;
REVOKE ALL ON editorial.conflict_snapshots FROM gurine_control_api;
REVOKE ALL ON editorial.conflict_snapshots FROM gurine_analysis_worker;
REVOKE ALL ON editorial.conflict_snapshots FROM gurine_public_projector;
REVOKE ALL ON editorial.conflict_snapshots FROM gurine_notification_worker;
REVOKE ALL ON editorial.conflict_snapshots FROM gurine_submission_api;
REVOKE ALL ON editorial.conflict_snapshots FROM gurine_auditor;
GRANT SELECT ON editorial.conflict_snapshots TO gurine_control_api;
GRANT SELECT ON editorial.conflict_snapshots TO gurine_workflow_worker;
CREATE TRIGGER editorial_conflict_snapshots_immutable_mutation_guard BEFORE UPDATE OR DELETE ON editorial.conflict_snapshots FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.capability_activation_decisions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  capability_id text NOT NULL,
  capability_class text NOT NULL,
  environment text NOT NULL,
  configuration_digest char(64) NOT NULL,
  decision_version bigint NOT NULL,
  prior_decision_id uuid,
  legal_state text NOT NULL,
  operational_state text NOT NULL,
  legal_entity_id text NOT NULL,
  controller_id text NOT NULL,
  jurisdiction_codes text[] NOT NULL,
  scope_type text NOT NULL,
  scope_id text NOT NULL,
  scope_version bigint NOT NULL,
  scope_digest char(64) NOT NULL,
  data_class_codes text[] NOT NULL,
  policy_digest char(64) NOT NULL,
  contract_digest char(64) NOT NULL,
  dpa_digest char(64),
  license_digest char(64),
  rights_digest char(64) NOT NULL,
  provider_preflight_receipt_digest char(64),
  routing_policy_digest char(64),
  kill_switch_digest char(64),
  conditions_encrypted bytea,
  conditions_digest char(64) NOT NULL,
  evidence_set_digest char(64) NOT NULL,
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  approval_digest char(64) NOT NULL,
  legal_action_decision_id uuid NOT NULL,
  legal_action_decision_receipt_digest char(64) NOT NULL,
  legal_approver_user_id uuid NOT NULL,
  legal_action_decision_kind text NOT NULL DEFAULT 'APPROVE',
  legal_conflict_snapshot_id uuid NOT NULL,
  legal_conflict_snapshot_digest char(64) NOT NULL,
  operational_action_decision_id uuid NOT NULL,
  operational_action_decision_receipt_digest char(64) NOT NULL,
  operational_approver_user_id uuid NOT NULL,
  operational_action_decision_kind text NOT NULL DEFAULT 'APPROVE',
  operational_conflict_snapshot_id uuid NOT NULL,
  operational_conflict_snapshot_digest char(64) NOT NULL,
  counted_decision_set_digest char(64) NOT NULL,
  execution_id uuid NOT NULL,
  execution_generation bigint NOT NULL,
  execution_digest char(64) NOT NULL,
  execution_receipt_id uuid NOT NULL,
  execution_receipt_digest char(64) NOT NULL,
  decided_by_service text NOT NULL DEFAULT 'workflow-worker',
  reason_code text NOT NULL,
  reason_encrypted bytea NOT NULL,
  reason_digest char(64) NOT NULL,
  effective_at timestamptz,
  expires_at timestamptz,
  decision_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_capability_activation_decisions_1 PRIMARY KEY (id)
);
ALTER TABLE ops.capability_activation_decisions OWNER TO gurine_migrator;
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_version_uq UNIQUE (capability_id, environment, decision_version);
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_digest_uq UNIQUE (decision_digest);
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_execution_uq UNIQUE (execution_receipt_id);
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_readiness_binding_uq UNIQUE (id, decision_version, decision_digest);
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_id_ck CHECK (capability_id ~ '^[a-z][a-z0-9_.-]{2,127}$');
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_class_ck CHECK (capability_class IN ('PUBLIC_PUBLICATION','SOURCE_ACCESS','SOURCE_STORAGE','SOURCE_REDISTRIBUTION','MODEL_EGRESS','DELIVERY_CHANNEL','PRIVACY_DSAR','PAID_WORKSPACE_PROCESSING'));
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_environment_ck CHECK (environment IN ('DEVELOPMENT','TEST','STAGING','PRODUCTION'));
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_state_ck CHECK (legal_state IN ('UNCONFIGURED','PENDING_REVIEW','APPROVED','SUSPENDED','EXPIRED'));
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_operational_state_ck CHECK (operational_state IN ('DISABLED','UNCONFIGURED','PENDING_PROVIDER_APPROVAL','ACTIVE','SUSPENDED'));
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_state_pair_ck CHECK ((legal_state, operational_state) IN (('UNCONFIGURED','DISABLED'),('UNCONFIGURED','UNCONFIGURED'),('PENDING_REVIEW','PENDING_PROVIDER_APPROVAL'),('PENDING_REVIEW','DISABLED'),('APPROVED','ACTIVE'),('APPROVED','SUSPENDED'),('APPROVED','DISABLED'),('SUSPENDED','SUSPENDED'),('SUSPENDED','DISABLED'),('EXPIRED','SUSPENDED'),('EXPIRED','DISABLED')));
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_scope_ck CHECK (scope_type IN ('DEPLOYMENT','SOURCE','PROVIDER','SENDER','TEMPLATE','MODEL','DATA_CLASS','WORKSPACE') AND length(scope_id) BETWEEN 1 AND 512 AND scope_version > 0);
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_arrays_ck CHECK (cardinality(jurisdiction_codes) BETWEEN 1 AND 64 AND ops.text_array_is_sorted_unique(jurisdiction_codes) AND cardinality(data_class_codes) BETWEEN 1 AND 64 AND ops.text_array_is_sorted_unique(data_class_codes));
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_version_ck CHECK (decision_version > 0 AND proposal_version > 0 AND execution_generation > 0 AND ((decision_version = 1 AND prior_decision_id IS NULL) OR (decision_version > 1 AND prior_decision_id IS NOT NULL)));
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_approval_time_ck CHECK ((legal_state = 'APPROVED' AND effective_at IS NOT NULL AND (expires_at IS NULL OR expires_at > effective_at)) OR legal_state <> 'APPROVED');
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_dpa_ck CHECK (capability_class NOT IN ('MODEL_EGRESS','DELIVERY_CHANNEL','PAID_WORKSPACE_PROCESSING') OR dpa_digest IS NOT NULL);
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_license_ck CHECK (capability_class NOT IN ('SOURCE_ACCESS','SOURCE_STORAGE','SOURCE_REDISTRIBUTION') OR license_digest IS NOT NULL);
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_active_evidence_ck CHECK (operational_state <> 'ACTIVE' OR (legal_state = 'APPROVED' AND provider_preflight_receipt_digest IS NOT NULL AND routing_policy_digest IS NOT NULL AND kill_switch_digest IS NOT NULL AND legal_action_decision_id <> operational_action_decision_id));
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_approval_binding_ck CHECK (legal_action_decision_kind = 'APPROVE' AND operational_action_decision_kind = 'APPROVE' AND legal_approver_user_id <> operational_approver_user_id AND legal_conflict_snapshot_id <> operational_conflict_snapshot_id);
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_service_ck CHECK (decided_by_service = 'workflow-worker');
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_digest_ck CHECK (ops.is_lower_sha256(configuration_digest) AND ops.is_lower_sha256(scope_digest) AND ops.is_lower_sha256(policy_digest) AND ops.is_lower_sha256(contract_digest) AND (dpa_digest IS NULL OR ops.is_lower_sha256(dpa_digest)) AND (license_digest IS NULL OR ops.is_lower_sha256(license_digest)) AND ops.is_lower_sha256(rights_digest) AND (provider_preflight_receipt_digest IS NULL OR ops.is_lower_sha256(provider_preflight_receipt_digest)) AND (routing_policy_digest IS NULL OR ops.is_lower_sha256(routing_policy_digest)) AND (kill_switch_digest IS NULL OR ops.is_lower_sha256(kill_switch_digest)) AND ops.is_lower_sha256(conditions_digest) AND ops.is_lower_sha256(evidence_set_digest) AND ops.is_lower_sha256(approval_digest) AND ops.is_lower_sha256(legal_action_decision_receipt_digest) AND ops.is_lower_sha256(legal_conflict_snapshot_digest) AND ops.is_lower_sha256(operational_action_decision_receipt_digest) AND ops.is_lower_sha256(operational_conflict_snapshot_digest) AND ops.is_lower_sha256(counted_decision_set_digest) AND ops.is_lower_sha256(execution_digest) AND ops.is_lower_sha256(execution_receipt_digest) AND ops.is_lower_sha256(reason_digest) AND ops.is_lower_sha256(decision_digest));
REVOKE ALL ON ops.capability_activation_decisions FROM PUBLIC;
REVOKE ALL ON ops.capability_activation_decisions FROM gurine_workflow_worker;
REVOKE ALL ON ops.capability_activation_decisions FROM gurine_control_api;
REVOKE ALL ON ops.capability_activation_decisions FROM gurine_analysis_worker;
REVOKE ALL ON ops.capability_activation_decisions FROM gurine_public_projector;
REVOKE ALL ON ops.capability_activation_decisions FROM gurine_notification_worker;
REVOKE ALL ON ops.capability_activation_decisions FROM gurine_submission_api;
REVOKE ALL ON ops.capability_activation_decisions FROM gurine_auditor;
GRANT SELECT ON ops.capability_activation_decisions TO gurine_control_api;
GRANT SELECT ON ops.capability_activation_decisions TO gurine_workflow_worker;
CREATE TRIGGER ops_capability_activation_decisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.capability_activation_decisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.capability_activation_evidence (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  decision_id uuid NOT NULL,
  ordinal smallint NOT NULL,
  evidence_kind text NOT NULL,
  applicability text NOT NULL,
  applicability_reason_code text NOT NULL,
  evidence_ref_type text NOT NULL,
  evidence_ref_id text NOT NULL,
  evidence_ref_version bigint NOT NULL,
  evidence_ref_digest char(64) NOT NULL,
  evidence_state text NOT NULL,
  proof_tier text NOT NULL,
  valid_from timestamptz NOT NULL,
  expires_at timestamptz,
  policy_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_capability_activation_evidence_1 PRIMARY KEY (id)
);
ALTER TABLE ops.capability_activation_evidence OWNER TO gurine_migrator;
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_ordinal_uq UNIQUE (decision_id, ordinal);
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_fact_uq UNIQUE (decision_id, evidence_kind, evidence_ref_type, evidence_ref_id, evidence_ref_version, evidence_ref_digest);
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_readiness_binding_uq UNIQUE (id, decision_id, evidence_ref_digest);
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_ordinal_ck CHECK (ordinal BETWEEN 1 AND 256);
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_kind_ck CHECK (evidence_kind IN ('OPERATING_ENTITY','CONTROLLER','COUNSEL_REVIEW','PRIVACY_NOTICE','DATA_MAP_DPIA','PROCESSOR_DPA','TRANSFER_MECHANISM','SOURCE_LICENSE','PROVIDER_APPROVAL','SENDER_VERIFICATION','TEMPLATE_APPROVAL','CALLBACK_RECONCILIATION','MODEL_TERMS','LIVE_PREFLIGHT_RECEIPT','PAID_PROCESSING_AUTHORITY','JURISDICTION_REVIEW','RIGHTS_AUTHORIZATION'));
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_applicability_ck CHECK (applicability IN ('APPLICABLE','NOT_APPLICABLE'));
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_applicability_reason_ck CHECK (applicability_reason_code IN ('POLICY_REQUIRED','JURISDICTION_REQUIRED','CONTRACT_REQUIRED','RIGHTS_REQUIRED','PROVIDER_REQUIRED','NO_EXTERNAL_PROCESSOR','NO_INTERNATIONAL_TRANSFER','NO_SOURCE_COMPONENT','NO_CHANNEL_COMPONENT','NO_MODEL_COMPONENT','NO_PAID_PROCESSING'));
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_ref_ck CHECK (evidence_ref_type IN ('ACTION_DECISION','EXECUTION_RECEIPT','PREFLIGHT_RECEIPT','RIGHTS_DECISION','CONTRACT_ARTIFACT','POLICY_ARTIFACT','LEGAL_REVIEW_ARTIFACT') AND length(evidence_ref_id) BETWEEN 1 AND 512 AND evidence_ref_version > 0);
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_state_ck CHECK (evidence_state IN ('SATISFIED','UNSATISFIED','UNKNOWN','REVOKED'));
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_tier_ck CHECK (proof_tier IN ('PRODUCTION_LEGAL','PRODUCTION_OPERATIONAL','NON_PRODUCTION_PREFLIGHT','SANDBOX_ONLY','FIXTURE_ONLY','CONNECTION_TEST_ONLY'));
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_time_ck CHECK (expires_at IS NULL OR expires_at > valid_from);
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_applicability_state_ck CHECK ((applicability = 'APPLICABLE' AND applicability_reason_code NOT LIKE 'NO_%') OR (applicability = 'NOT_APPLICABLE' AND applicability_reason_code LIKE 'NO_%' AND evidence_state = 'SATISFIED' AND proof_tier = 'PRODUCTION_LEGAL'));
ALTER TABLE ops.capability_activation_evidence ADD CONSTRAINT capability_activation_evidence_digest_ck CHECK (ops.is_lower_sha256(evidence_ref_digest) AND ops.is_lower_sha256(policy_digest));
REVOKE ALL ON ops.capability_activation_evidence FROM PUBLIC;
REVOKE ALL ON ops.capability_activation_evidence FROM gurine_workflow_worker;
REVOKE ALL ON ops.capability_activation_evidence FROM gurine_control_api;
REVOKE ALL ON ops.capability_activation_evidence FROM gurine_analysis_worker;
REVOKE ALL ON ops.capability_activation_evidence FROM gurine_public_projector;
REVOKE ALL ON ops.capability_activation_evidence FROM gurine_notification_worker;
REVOKE ALL ON ops.capability_activation_evidence FROM gurine_submission_api;
REVOKE ALL ON ops.capability_activation_evidence FROM gurine_auditor;
GRANT SELECT ON ops.capability_activation_evidence TO gurine_control_api;
GRANT SELECT ON ops.capability_activation_evidence TO gurine_workflow_worker;
CREATE TRIGGER ops_capability_activation_evidence_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.capability_activation_evidence FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.record_class_schedules (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  record_class text NOT NULL,
  revision bigint NOT NULL,
  supersedes_schedule_id uuid,
  owner_team text NOT NULL,
  purpose text NOT NULL,
  lawful_basis text NOT NULL,
  lawful_basis_review_digest char(64) NOT NULL,
  trigger_kind text NOT NULL,
  active_duration_seconds bigint,
  backup_duration_seconds bigint,
  location_codes text[] NOT NULL,
  derivative_record_classes text[] NOT NULL DEFAULT '{}'::text[],
  terminal_action text NOT NULL,
  hold_behavior text NOT NULL,
  restore_suppression_behavior text NOT NULL,
  policy_digest char(64) NOT NULL,
  action_proposal_id uuid NOT NULL,
  action_proposal_version bigint NOT NULL,
  approval_digest char(64) NOT NULL,
  operational_action_decision_id uuid NOT NULL,
  operational_action_decision_receipt_digest char(64) NOT NULL,
  legal_action_decision_id uuid NOT NULL,
  legal_action_decision_receipt_digest char(64) NOT NULL,
  counted_decision_set_digest char(64) NOT NULL,
  action_execution_id uuid NOT NULL,
  action_execution_generation bigint NOT NULL,
  action_execution_digest char(64) NOT NULL,
  action_execution_receipt_id uuid NOT NULL,
  action_execution_receipt_digest char(64) NOT NULL,
  effective_at timestamptz NOT NULL,
  review_expires_at timestamptz NOT NULL,
  schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_record_class_schedules_1 PRIMARY KEY (id)
);
ALTER TABLE ops.record_class_schedules OWNER TO gurine_migrator;
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_revision_uq UNIQUE (record_class, revision);
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_effective_uq UNIQUE (record_class, effective_at);
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_digest_uq UNIQUE (schedule_digest);
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_binding_uq UNIQUE (id, record_class, schedule_digest);
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_execution_uq UNIQUE (action_execution_receipt_id);
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_id_ck CHECK (record_class ~ '^[A-Z][A-Z0-9_]{2,99}$' AND owner_team ~ '^[a-z][a-z0-9-]{1,63}$');
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_revision_ck CHECK (revision > 0 AND action_proposal_version > 0 AND action_execution_generation > 0 AND ((revision = 1 AND supersedes_schedule_id IS NULL) OR (revision > 1 AND supersedes_schedule_id IS NOT NULL)));
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_text_ck CHECK (length(btrim(purpose)) BETWEEN 1 AND 4000 AND length(btrim(lawful_basis)) BETWEEN 1 AND 2000);
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_trigger_ck CHECK (trigger_kind IN ('CREATED_AT','UPDATED_AT','CONSUMED_AT','EXPIRES_AT','CASE_CLOSED_AT','LAST_MATERIAL_USE_AT','SUPERSEDED_AT','DELIVERED_AT','TERMINAL_AT'));
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_duration_ck CHECK ((active_duration_seconds IS NULL OR active_duration_seconds BETWEEN 0 AND 3155760000) AND (backup_duration_seconds IS NULL OR backup_duration_seconds BETWEEN 0 AND 3155760000));
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_locations_ck CHECK (cardinality(location_codes) BETWEEN 1 AND 128 AND ops.text_array_is_sorted_unique(location_codes) AND cardinality(derivative_record_classes) <= 128 AND ops.text_array_is_sorted_unique(derivative_record_classes));
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_terminal_ck CHECK (terminal_action IN ('DELETE','ANONYMIZE','CRYPTO_ERASE','PRESERVE_PUBLIC_REVISION'));
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_indefinite_ck CHECK ((terminal_action = 'PRESERVE_PUBLIC_REVISION' AND active_duration_seconds IS NULL AND backup_duration_seconds IS NULL) OR (terminal_action <> 'PRESERVE_PUBLIC_REVISION' AND active_duration_seconds IS NOT NULL AND backup_duration_seconds IS NOT NULL));
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_hold_ck CHECK (hold_behavior IN ('BLOCK_ON_RETENTION','BLOCK_ON_RETENTION_OR_DELETION','NOT_DESTRUCTIVE') AND ((terminal_action = 'PRESERVE_PUBLIC_REVISION' AND hold_behavior = 'NOT_DESTRUCTIVE') OR (terminal_action <> 'PRESERVE_PUBLIC_REVISION' AND hold_behavior <> 'NOT_DESTRUCTIVE')));
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_restore_ck CHECK (restore_suppression_behavior IN ('REAPPLY_BEFORE_ACCESS','NOT_APPLICABLE') AND (terminal_action = 'PRESERVE_PUBLIC_REVISION' OR restore_suppression_behavior = 'REAPPLY_BEFORE_ACCESS'));
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_sod_ck CHECK (operational_action_decision_id <> legal_action_decision_id);
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_time_ck CHECK (review_expires_at > effective_at);
ALTER TABLE ops.record_class_schedules ADD CONSTRAINT record_class_schedules_digest_ck CHECK (ops.is_lower_sha256(lawful_basis_review_digest) AND ops.is_lower_sha256(policy_digest) AND ops.is_lower_sha256(approval_digest) AND ops.is_lower_sha256(operational_action_decision_receipt_digest) AND ops.is_lower_sha256(legal_action_decision_receipt_digest) AND ops.is_lower_sha256(counted_decision_set_digest) AND ops.is_lower_sha256(action_execution_digest) AND ops.is_lower_sha256(action_execution_receipt_digest) AND ops.is_lower_sha256(schedule_digest));
REVOKE ALL ON ops.record_class_schedules FROM PUBLIC;
REVOKE ALL ON ops.record_class_schedules FROM gurine_workflow_worker;
REVOKE ALL ON ops.record_class_schedules FROM gurine_control_api;
REVOKE ALL ON ops.record_class_schedules FROM gurine_analysis_worker;
REVOKE ALL ON ops.record_class_schedules FROM gurine_public_projector;
REVOKE ALL ON ops.record_class_schedules FROM gurine_notification_worker;
REVOKE ALL ON ops.record_class_schedules FROM gurine_submission_api;
REVOKE ALL ON ops.record_class_schedules FROM gurine_auditor;
GRANT SELECT ON ops.record_class_schedules TO gurine_control_api;
GRANT SELECT ON ops.record_class_schedules TO gurine_workflow_worker;
GRANT SELECT ON ops.record_class_schedules TO gurine_scheduler;
CREATE TRIGGER ops_record_class_schedules_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.record_class_schedules FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.retention_request_decisions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  retention_request_id uuid NOT NULL,
  request_type text NOT NULL,
  decision_version bigint NOT NULL,
  prior_decision_id uuid,
  prior_state text NOT NULL,
  state text NOT NULL,
  transition_kind text NOT NULL,
  inventory_snapshot_digest char(64) NOT NULL,
  hold_coverage_digest char(64) NOT NULL,
  restore_suppression_required boolean NOT NULL,
  policy_digest char(64) NOT NULL,
  reason_code text NOT NULL,
  reason_encrypted bytea NOT NULL,
  reason_digest char(64) NOT NULL,
  decided_by_user_id uuid NOT NULL,
  step_up_authorization_id uuid NOT NULL,
  step_up_authorization_receipt_digest char(64) NOT NULL,
  step_up_issued_at timestamptz NOT NULL,
  step_up_expires_at timestamptz NOT NULL,
  action_digest char(64) NOT NULL,
  idempotency_key_sha256 char(64) NOT NULL,
  actor_assertion_jti uuid NOT NULL,
  request_id uuid NOT NULL,
  audit_event_id uuid NOT NULL,
  decision_digest char(64) NOT NULL,
  receipt_digest char(64) NOT NULL,
  decided_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_retention_request_decisions_1 PRIMARY KEY (id)
);
ALTER TABLE ops.retention_request_decisions OWNER TO gurine_migrator;
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_version_uq UNIQUE (retention_request_id, decision_version);
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_digest_uq UNIQUE (decision_digest);
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_receipt_uq UNIQUE (receipt_digest);
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_request_type_uq UNIQUE (id, retention_request_id, request_type);
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_type_binding_uq UNIQUE (id, retention_request_id, request_type, state);
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_step_up_uq UNIQUE (step_up_authorization_id);
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_jti_uq UNIQUE (actor_assertion_jti);
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_version_ck CHECK (decision_version > 0 AND ((decision_version = 1 AND prior_decision_id IS NULL) OR (decision_version > 1 AND prior_decision_id IS NOT NULL)));
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_type_ck CHECK (request_type IN ('ACCESS','CORRECTION','DELETION','RESTRICTION') AND restore_suppression_required = (request_type IN ('CORRECTION','DELETION','RESTRICTION')));
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_state_ck CHECK (prior_state IN ('RECEIVED','REVIEW') AND state IN ('REVIEW','APPROVED','REJECTED'));
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_edge_ck CHECK ((transition_kind = 'START_REVIEW' AND prior_state = 'RECEIVED' AND state = 'REVIEW') OR (transition_kind = 'APPROVE' AND prior_state = 'REVIEW' AND state = 'APPROVED') OR (transition_kind = 'REJECT' AND prior_state = 'REVIEW' AND state = 'REJECTED'));
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_reason_ck CHECK (length(reason_code) BETWEEN 1 AND 100);
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_step_up_time_ck CHECK (step_up_expires_at > step_up_issued_at AND decided_at >= step_up_issued_at AND decided_at <= step_up_expires_at);
ALTER TABLE ops.retention_request_decisions ADD CONSTRAINT retention_request_decisions_digest_ck CHECK (ops.is_lower_sha256(inventory_snapshot_digest) AND ops.is_lower_sha256(hold_coverage_digest) AND ops.is_lower_sha256(policy_digest) AND ops.is_lower_sha256(reason_digest) AND ops.is_lower_sha256(step_up_authorization_receipt_digest) AND ops.is_lower_sha256(action_digest) AND ops.is_lower_sha256(idempotency_key_sha256) AND ops.is_lower_sha256(decision_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON ops.retention_request_decisions FROM PUBLIC;
REVOKE ALL ON ops.retention_request_decisions FROM gurine_workflow_worker;
REVOKE ALL ON ops.retention_request_decisions FROM gurine_control_api;
REVOKE ALL ON ops.retention_request_decisions FROM gurine_analysis_worker;
REVOKE ALL ON ops.retention_request_decisions FROM gurine_public_projector;
REVOKE ALL ON ops.retention_request_decisions FROM gurine_notification_worker;
REVOKE ALL ON ops.retention_request_decisions FROM gurine_submission_api;
REVOKE ALL ON ops.retention_request_decisions FROM gurine_auditor;
GRANT SELECT ON ops.retention_request_decisions TO gurine_control_api;
GRANT SELECT ON ops.retention_request_decisions TO gurine_workflow_worker;
CREATE TRIGGER ops_retention_request_decisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.retention_request_decisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.retention_execution_receipts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  retention_request_id uuid NOT NULL,
  request_type text NOT NULL,
  approval_decision_id uuid NOT NULL,
  execution_kind text NOT NULL,
  execution_generation bigint NOT NULL,
  schedule_set_digest char(64) NOT NULL,
  inventory_snapshot_digest char(64) NOT NULL,
  hold_coverage_digest char(64) NOT NULL,
  active_hold_cell_count bigint NOT NULL DEFAULT 0,
  location_counts jsonb NOT NULL,
  location_count_digest char(64) NOT NULL,
  primary_count bigint NOT NULL,
  derivative_count bigint NOT NULL,
  index_count bigint NOT NULL,
  cache_count bigint NOT NULL,
  queue_count bigint NOT NULL,
  object_count bigint NOT NULL,
  backup_suppression_count bigint NOT NULL,
  backup_suppression_digest char(64) NOT NULL,
  restoration_suppression_set_digest char(64) NOT NULL,
  restoration_suppression_count bigint NOT NULL DEFAULT 0,
  suppression_mode text NOT NULL,
  tombstone_state text NOT NULL,
  tombstone_digest char(64) NOT NULL,
  outcome_manifest jsonb NOT NULL,
  outcome_manifest_digest char(64) NOT NULL,
  evidence_set_digest char(64) NOT NULL,
  job_id uuid NOT NULL,
  lease_token uuid NOT NULL,
  fencing_token bigint NOT NULL,
  started_at timestamptz NOT NULL,
  completed_at timestamptz NOT NULL,
  worker_id text NOT NULL,
  audit_event_id uuid NOT NULL,
  receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_retention_execution_receipts_1 PRIMARY KEY (id)
);
ALTER TABLE ops.retention_execution_receipts OWNER TO gurine_migrator;
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_generation_uq UNIQUE (retention_request_id, approval_decision_id, execution_generation);
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_receipt_uq UNIQUE (receipt_digest);
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_job_fence_uq UNIQUE (job_id, fencing_token);
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_completion_binding_uq UNIQUE (id, retention_request_id, request_type, execution_kind);
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_generation_ck CHECK (execution_generation > 0 AND fencing_token > 0);
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_type_ck CHECK ((request_type = 'ACCESS' AND execution_kind = 'DISCLOSE_COPY') OR (request_type = 'CORRECTION' AND execution_kind = 'CORRECT') OR (request_type = 'DELETION' AND execution_kind = 'DESTRUCTIVE') OR (request_type = 'RESTRICTION' AND execution_kind = 'RESTRICT_PROCESSING'));
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_hold_ck CHECK (active_hold_cell_count = 0);
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_counts_ck CHECK (primary_count >= 0 AND derivative_count >= 0 AND index_count >= 0 AND cache_count >= 0 AND queue_count >= 0 AND object_count >= 0 AND backup_suppression_count >= 0);
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_location_json_ck CHECK (ops.retention_location_count_array_is_valid(request_type,location_counts) AND ops.retention_receipt_counts_are_valid(request_type,location_counts,primary_count,derivative_count,index_count,cache_count,queue_count,object_count,backup_suppression_count));
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_suppression_ck CHECK ((request_type = 'ACCESS' AND restoration_suppression_count = 0 AND suppression_mode = 'NONE') OR (request_type = 'CORRECTION' AND restoration_suppression_count > 0 AND suppression_mode = 'PERMANENT_CORRECTION_REPLAY') OR (request_type = 'DELETION' AND restoration_suppression_count > 0 AND suppression_mode = 'PERMANENT_ERASURE') OR (request_type = 'RESTRICTION' AND restoration_suppression_count > 0 AND suppression_mode = 'UNTIL_RESTRICTION_RELEASE'));
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_tombstone_ck CHECK ((request_type = 'DELETION' AND tombstone_state = 'CREATED') OR (request_type <> 'DELETION' AND tombstone_state = 'NOT_APPLICABLE'));
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_outcome_ck CHECK (ops.privacy_outcome_manifest_is_valid(request_type,inventory_snapshot_digest,restoration_suppression_set_digest,outcome_manifest));
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_time_ck CHECK (completed_at >= started_at);
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_worker_ck CHECK (length(worker_id) BETWEEN 1 AND 255);
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_digest_ck CHECK (ops.is_lower_sha256(schedule_set_digest) AND ops.is_lower_sha256(inventory_snapshot_digest) AND ops.is_lower_sha256(hold_coverage_digest) AND ops.is_lower_sha256(location_count_digest) AND ops.is_lower_sha256(backup_suppression_digest) AND ops.is_lower_sha256(restoration_suppression_set_digest) AND ops.is_lower_sha256(tombstone_digest) AND ops.is_lower_sha256(outcome_manifest_digest) AND ops.is_lower_sha256(evidence_set_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON ops.retention_execution_receipts FROM PUBLIC;
REVOKE ALL ON ops.retention_execution_receipts FROM gurine_workflow_worker;
REVOKE ALL ON ops.retention_execution_receipts FROM gurine_control_api;
REVOKE ALL ON ops.retention_execution_receipts FROM gurine_analysis_worker;
REVOKE ALL ON ops.retention_execution_receipts FROM gurine_public_projector;
REVOKE ALL ON ops.retention_execution_receipts FROM gurine_notification_worker;
REVOKE ALL ON ops.retention_execution_receipts FROM gurine_submission_api;
REVOKE ALL ON ops.retention_execution_receipts FROM gurine_auditor;
GRANT SELECT ON ops.retention_execution_receipts TO gurine_control_api;
GRANT SELECT ON ops.retention_execution_receipts TO gurine_workflow_worker;
CREATE TRIGGER ops_retention_execution_receipts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.retention_execution_receipts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.restoration_suppressions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  subject_type text NOT NULL,
  request_type text NOT NULL,
  subject_ref_hash char(64) NOT NULL,
  scope_kind text NOT NULL,
  record_class text,
  scope_ref_hmac char(64),
  subject_scope_digest char(64) NOT NULL,
  terminal_action text NOT NULL,
  reason_code text NOT NULL,
  source_decision_id uuid NOT NULL,
  source_retention_request_id uuid NOT NULL,
  schedule_id uuid NOT NULL,
  schedule_digest char(64) NOT NULL,
  effective_at timestamptz NOT NULL,
  expires_at timestamptz,
  suppression_digest char(64) NOT NULL,
  created_by_worker text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_restoration_suppressions_1 PRIMARY KEY (id)
);
ALTER TABLE ops.restoration_suppressions OWNER TO gurine_migrator;
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_fact_uq UNIQUE (subject_scope_digest, terminal_action, source_decision_id, schedule_id);
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_digest_uq UNIQUE (suppression_digest);
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_subject_ck CHECK (subject_type IN ('PERSON','ORGANIZATION','RESPONSE_PARTY','COMMUNICATION_SUBJECT'));
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_request_type_ck CHECK (request_type IN ('CORRECTION','DELETION','RESTRICTION'));
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_scope_ck CHECK (scope_kind IN ('ALL_SUBJECT_DATA','RECORD_CLASS','RELATION_ROW','OBJECT_KEY','BACKUP_GENERATION'));
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_scope_shape_ck CHECK ((scope_kind = 'ALL_SUBJECT_DATA' AND record_class IS NULL AND scope_ref_hmac IS NULL) OR (scope_kind = 'RECORD_CLASS' AND record_class IS NOT NULL AND scope_ref_hmac IS NULL) OR (scope_kind IN ('RELATION_ROW','OBJECT_KEY','BACKUP_GENERATION') AND scope_ref_hmac IS NOT NULL));
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_action_ck CHECK ((request_type = 'CORRECTION' AND terminal_action = 'REPLAY_CORRECTED_VERSION') OR (request_type = 'DELETION' AND terminal_action IN ('DELETE','ANONYMIZE','CRYPTO_ERASE')) OR (request_type = 'RESTRICTION' AND terminal_action = 'RESTRICT_PROCESSING'));
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_reason_ck CHECK ((request_type = 'CORRECTION' AND reason_code = 'PRIVACY_CORRECTION_COMPLETED') OR (request_type = 'DELETION' AND reason_code = 'PRIVACY_DELETION_COMPLETED') OR (request_type = 'RESTRICTION' AND reason_code = 'PRIVACY_RESTRICTION_ACTIVE'));
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_permanence_ck CHECK ((request_type IN ('CORRECTION','DELETION') AND expires_at IS NULL) OR request_type = 'RESTRICTION');
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_time_ck CHECK (expires_at IS NULL OR expires_at > effective_at);
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_worker_ck CHECK (length(created_by_worker) BETWEEN 1 AND 255);
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_digest_ck CHECK (ops.is_lower_sha256(subject_ref_hash) AND (scope_ref_hmac IS NULL OR ops.is_lower_sha256(scope_ref_hmac)) AND ops.is_lower_sha256(subject_scope_digest) AND ops.is_lower_sha256(schedule_digest) AND ops.is_lower_sha256(suppression_digest));
REVOKE ALL ON ops.restoration_suppressions FROM PUBLIC;
REVOKE ALL ON ops.restoration_suppressions FROM gurine_workflow_worker;
REVOKE ALL ON ops.restoration_suppressions FROM gurine_control_api;
REVOKE ALL ON ops.restoration_suppressions FROM gurine_analysis_worker;
REVOKE ALL ON ops.restoration_suppressions FROM gurine_public_projector;
REVOKE ALL ON ops.restoration_suppressions FROM gurine_notification_worker;
REVOKE ALL ON ops.restoration_suppressions FROM gurine_submission_api;
REVOKE ALL ON ops.restoration_suppressions FROM gurine_auditor;
GRANT SELECT ON ops.restoration_suppressions TO gurine_control_api;
GRANT SELECT ON ops.restoration_suppressions TO gurine_workflow_worker;
CREATE TRIGGER ops_restoration_suppressions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.restoration_suppressions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE editorial.legal_hold_releases (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  hold_id uuid NOT NULL,
  hold_version bigint NOT NULL,
  original_hold_digest char(64) NOT NULL,
  target_anchor_id uuid NOT NULL,
  target_anchor_digest char(64) NOT NULL,
  release_context_kind text NOT NULL,
  release_sequence bigint NOT NULL,
  prior_release_id uuid,
  prior_release_digest char(64),
  case_id uuid,
  review_snapshot_id uuid,
  expected_case_version bigint,
  released_scope_atoms text[] NOT NULL,
  affected_ids uuid[] NOT NULL,
  affected_set_digest char(64) NOT NULL,
  prior_coverage_digest char(64) NOT NULL,
  resulting_coverage_digest char(64) NOT NULL,
  release_authority_reference text NOT NULL,
  authority_reference_digest char(64) NOT NULL,
  reason_code text NOT NULL,
  reason text NOT NULL,
  released_by_user_id uuid NOT NULL,
  conflict_snapshot_id uuid NOT NULL,
  conflict_snapshot_digest char(64) NOT NULL,
  conflict_target_type text NOT NULL DEFAULT 'LEGAL_HOLD',
  conflict_target_id text NOT NULL,
  conflict_target_version bigint NOT NULL,
  conflict_target_digest char(64) NOT NULL,
  conflict_evaluation_state text NOT NULL DEFAULT 'CLEAR',
  conflict_valid_until timestamptz NOT NULL,
  approval_receipt_digest char(64) NOT NULL,
  step_up_authorization_id uuid NOT NULL,
  step_up_authorization_receipt_digest char(64) NOT NULL,
  step_up_issued_at timestamptz NOT NULL,
  step_up_expires_at timestamptz NOT NULL,
  action_digest char(64) NOT NULL,
  idempotency_key_sha256 char(64) NOT NULL,
  actor_assertion_jti uuid NOT NULL,
  request_id uuid NOT NULL,
  audit_event_id uuid NOT NULL,
  release_digest char(64) NOT NULL,
  receipt_digest char(64) NOT NULL,
  released_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_editorial_legal_hold_releases_1 PRIMARY KEY (id)
);
ALTER TABLE editorial.legal_hold_releases OWNER TO gurine_migrator;
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_sequence_uq UNIQUE (hold_id, release_sequence);
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_digest_uq UNIQUE (release_digest);
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_receipt_uq UNIQUE (receipt_digest);
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_step_up_uq UNIQUE (step_up_authorization_id);
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_jti_uq UNIQUE (actor_assertion_jti);
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_sequence_ck CHECK (hold_version > 0 AND release_sequence > 0 AND ((release_sequence = 1 AND prior_release_id IS NULL AND prior_release_digest IS NULL) OR (release_sequence > 1 AND prior_release_id IS NOT NULL AND prior_release_digest IS NOT NULL)));
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_context_ck CHECK ((release_context_kind = 'CASE_GOVERNED' AND case_id IS NOT NULL AND review_snapshot_id IS NOT NULL AND expected_case_version > 0) OR (release_context_kind = 'NON_CASE_GOVERNED' AND case_id IS NULL AND review_snapshot_id IS NULL AND expected_case_version IS NULL));
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_conflict_binding_ck CHECK (conflict_target_type = 'LEGAL_HOLD' AND conflict_target_id = hold_id::text AND conflict_target_version = hold_version AND conflict_target_digest = original_hold_digest AND conflict_evaluation_state = 'CLEAR' AND conflict_valid_until > released_at);
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_atoms_ck CHECK (cardinality(released_scope_atoms) BETWEEN 1 AND 3 AND ops.text_array_is_sorted_unique(released_scope_atoms) AND released_scope_atoms <@ ARRAY['DELETION','DISCLOSURE','RETENTION']::text[]);
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_affected_ck CHECK (cardinality(affected_ids) BETWEEN 1 AND 10000 AND ops.uuid_array_is_sorted_unique(affected_ids));
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_reason_ck CHECK (reason_code IN ('AUTHORITY_WITHDRAWN','EXPIRED_REVIEWED','RESOLVED','SUPERSEDED','COURT_ORDER','OTHER') AND length(btrim(reason)) BETWEEN 1 AND 4000 AND length(btrim(release_authority_reference)) BETWEEN 1 AND 500);
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_step_up_time_ck CHECK (step_up_expires_at > step_up_issued_at AND released_at >= step_up_issued_at AND released_at <= step_up_expires_at);
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_digest_ck CHECK (ops.is_lower_sha256(original_hold_digest) AND ops.is_lower_sha256(target_anchor_digest) AND (prior_release_digest IS NULL OR ops.is_lower_sha256(prior_release_digest)) AND ops.is_lower_sha256(affected_set_digest) AND ops.is_lower_sha256(prior_coverage_digest) AND ops.is_lower_sha256(resulting_coverage_digest) AND ops.is_lower_sha256(authority_reference_digest) AND ops.is_lower_sha256(conflict_snapshot_digest) AND ops.is_lower_sha256(conflict_target_digest) AND ops.is_lower_sha256(approval_receipt_digest) AND ops.is_lower_sha256(step_up_authorization_receipt_digest) AND ops.is_lower_sha256(action_digest) AND ops.is_lower_sha256(idempotency_key_sha256) AND ops.is_lower_sha256(release_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON editorial.legal_hold_releases FROM PUBLIC;
REVOKE ALL ON editorial.legal_hold_releases FROM gurine_workflow_worker;
REVOKE ALL ON editorial.legal_hold_releases FROM gurine_control_api;
REVOKE ALL ON editorial.legal_hold_releases FROM gurine_analysis_worker;
REVOKE ALL ON editorial.legal_hold_releases FROM gurine_public_projector;
REVOKE ALL ON editorial.legal_hold_releases FROM gurine_notification_worker;
REVOKE ALL ON editorial.legal_hold_releases FROM gurine_submission_api;
REVOKE ALL ON editorial.legal_hold_releases FROM gurine_auditor;
GRANT SELECT ON editorial.legal_hold_releases TO gurine_control_api;
GRANT SELECT ON editorial.legal_hold_releases TO gurine_workflow_worker;
GRANT SELECT ON editorial.legal_hold_releases TO gurine_scheduler;
CREATE TRIGGER editorial_legal_hold_releases_immutable_mutation_guard BEFORE UPDATE OR DELETE ON editorial.legal_hold_releases FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.incident_events (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  incident_id uuid NOT NULL,
  event_sequence bigint NOT NULL,
  prior_version bigint NOT NULL,
  version bigint NOT NULL,
  prior_state text,
  state text NOT NULL,
  transition_kind text NOT NULL,
  severity text NOT NULL,
  affected_capabilities text[] NOT NULL,
  owner_user_id uuid NOT NULL,
  commander_user_id uuid,
  next_update_at timestamptz,
  transition_detail jsonb NOT NULL,
  evidence_refs jsonb NOT NULL,
  evidence_set_digest char(64) NOT NULL,
  reason_code text NOT NULL,
  reason text NOT NULL,
  actor_type text NOT NULL,
  actor_id text NOT NULL,
  idempotency_key_sha256 char(64),
  actor_assertion_jti uuid,
  request_id uuid NOT NULL,
  audit_event_id uuid NOT NULL,
  receipt_digest char(64) NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_incident_events_1 PRIMARY KEY (id)
);
ALTER TABLE ops.incident_events OWNER TO gurine_migrator;
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_sequence_uq UNIQUE (incident_id, event_sequence);
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_version_uq UNIQUE (incident_id, version);
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_receipt_uq UNIQUE (receipt_digest);
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_request_uq UNIQUE (request_id);
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_jti_uq UNIQUE (actor_assertion_jti);
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_sequence_ck CHECK (event_sequence > 0 AND prior_version >= 0 AND version > 0);
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_version_ck CHECK (transition_kind = 'MIGRATION_BASELINE' OR version = prior_version + 1);
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_state_ck CHECK (state IN ('DETECTED','TRIAGED','CONTAINED','RECOVERING','RESOLVED','POSTMORTEM_CLOSED') AND (prior_state IS NULL OR prior_state IN ('DETECTED','TRIAGED','CONTAINED','RECOVERING','RESOLVED')));
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_edge_ck CHECK ((transition_kind = 'DETECTED' AND prior_state IS NULL AND state = 'DETECTED') OR (transition_kind = 'TRIAGED' AND prior_state = 'DETECTED' AND state = 'TRIAGED') OR (transition_kind = 'CONTAINED' AND prior_state = 'TRIAGED' AND state = 'CONTAINED') OR (transition_kind = 'RECOVERY_STARTED' AND prior_state = 'CONTAINED' AND state = 'RECOVERING') OR (transition_kind = 'RESOLVED' AND prior_state = 'RECOVERING' AND state = 'RESOLVED') OR (transition_kind = 'POSTMORTEM_CLOSED' AND prior_state = 'RESOLVED' AND state = 'POSTMORTEM_CLOSED') OR transition_kind = 'MIGRATION_BASELINE');
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_severity_ck CHECK (severity IN ('SEV0','SEV1','SEV2','SEV3'));
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_capabilities_ck CHECK (cardinality(affected_capabilities) BETWEEN 1 AND 32 AND ops.text_array_is_sorted_unique(affected_capabilities));
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_commander_ck CHECK (severity NOT IN ('SEV0','SEV1') OR commander_user_id IS NOT NULL);
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_next_update_ck CHECK ((state = 'POSTMORTEM_CLOSED' AND next_update_at IS NULL) OR (transition_kind = 'MIGRATION_BASELINE' AND state = 'RESOLVED' AND next_update_at IS NULL) OR (state <> 'POSTMORTEM_CLOSED' AND next_update_at IS NOT NULL AND next_update_at > occurred_at));
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_migration_shape_ck CHECK (transition_kind <> 'MIGRATION_BASELINE' OR (event_sequence = 1 AND prior_state IS NULL AND actor_type = 'MIGRATION' AND actor_assertion_jti IS NULL AND idempotency_key_sha256 IS NULL));
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_detail_json_ck CHECK (ops.incident_transition_detail_is_valid(transition_kind,transition_detail));
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_evidence_json_ck CHECK (ops.incident_evidence_ref_array_is_valid(evidence_refs));
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_reason_ck CHECK (length(reason_code) BETWEEN 1 AND 100 AND length(btrim(reason)) BETWEEN 1 AND 4000);
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_actor_ck CHECK (actor_type IN ('HUMAN','SERVICE','MIGRATION') AND length(actor_id) BETWEEN 1 AND 512 AND ((actor_type = 'HUMAN' AND actor_assertion_jti IS NOT NULL AND idempotency_key_sha256 IS NOT NULL) OR (actor_type <> 'HUMAN' AND actor_assertion_jti IS NULL)));
ALTER TABLE ops.incident_events ADD CONSTRAINT incident_events_digest_ck CHECK (ops.is_lower_sha256(evidence_set_digest) AND (idempotency_key_sha256 IS NULL OR ops.is_lower_sha256(idempotency_key_sha256)) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON ops.incident_events FROM PUBLIC;
REVOKE ALL ON ops.incident_events FROM gurine_workflow_worker;
REVOKE ALL ON ops.incident_events FROM gurine_control_api;
REVOKE ALL ON ops.incident_events FROM gurine_analysis_worker;
REVOKE ALL ON ops.incident_events FROM gurine_public_projector;
REVOKE ALL ON ops.incident_events FROM gurine_notification_worker;
REVOKE ALL ON ops.incident_events FROM gurine_submission_api;
REVOKE ALL ON ops.incident_events FROM gurine_auditor;
GRANT SELECT ON ops.incident_events TO gurine_control_api;
GRANT SELECT ON ops.incident_events TO gurine_workflow_worker;
CREATE TRIGGER ops_incident_events_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.incident_events FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE editorial.publication_gate_decisions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL,
  expected_case_version bigint NOT NULL,
  review_snapshot_id uuid NOT NULL,
  snapshot_digest char(64) NOT NULL,
  preview_id uuid NOT NULL,
  preview_digest char(64) NOT NULL,
  public_payload_digest char(64) NOT NULL,
  preview_expires_at timestamptz NOT NULL,
  claim_revision_set_digest char(64) NOT NULL,
  claim_evidence_matrix_digest char(64) NOT NULL,
  source_freshness_digest char(64) NOT NULL,
  response_policy_digest char(64) NOT NULL,
  privacy_restriction_digest char(64) NOT NULL,
  rights_digest char(64) NOT NULL,
  publication_consent_digest char(64) NOT NULL,
  conflict_digest char(64) NOT NULL,
  funding_digest char(64) NOT NULL,
  hold_coverage_digest char(64) NOT NULL,
  activation_set_digest char(64) NOT NULL,
  kill_switch_digest char(64) NOT NULL,
  review_decision_set_digest char(64) NOT NULL,
  quorum_digest char(64) NOT NULL,
  policy_version text NOT NULL,
  policy_digest char(64) NOT NULL,
  risk_level text NOT NULL,
  required_editor_count smallint NOT NULL,
  legal_review_required boolean NOT NULL,
  publisher_user_id uuid NOT NULL,
  publisher_conflict_snapshot_id uuid NOT NULL,
  publisher_conflict_snapshot_digest char(64) NOT NULL,
  publisher_conflict_target_type text NOT NULL DEFAULT 'REVIEW_SNAPSHOT',
  publisher_conflict_target_id text NOT NULL,
  publisher_conflict_target_version bigint NOT NULL,
  publisher_conflict_target_digest char(64) NOT NULL,
  publisher_conflict_evaluation_state text NOT NULL DEFAULT 'CLEAR',
  publisher_conflict_valid_until timestamptz NOT NULL,
  application_evaluation_digest char(64) NOT NULL,
  database_evaluation_digest char(64) NOT NULL,
  evaluated_at timestamptz NOT NULL,
  earliest_expiry_at timestamptz NOT NULL,
  outcome text NOT NULL,
  blocker_set_digest char(64) NOT NULL,
  step_up_authorization_id uuid NOT NULL,
  step_up_authorization_receipt_digest char(64) NOT NULL,
  step_up_issued_at timestamptz NOT NULL,
  step_up_expires_at timestamptz NOT NULL,
  action_digest char(64) NOT NULL,
  idempotency_key_sha256 char(64) NOT NULL,
  actor_assertion_jti uuid NOT NULL,
  request_id uuid NOT NULL,
  audit_event_id uuid NOT NULL,
  decision_digest char(64) NOT NULL,
  receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_editorial_publication_gate_decisions_1 PRIMARY KEY (id)
);
ALTER TABLE editorial.publication_gate_decisions OWNER TO gurine_migrator;
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_exact_uq UNIQUE (case_id, expected_case_version, decision_digest);
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_digest_uq UNIQUE (decision_digest);
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_receipt_uq UNIQUE (receipt_digest);
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_step_up_uq UNIQUE (step_up_authorization_id);
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_jti_uq UNIQUE (actor_assertion_jti);
CREATE UNIQUE INDEX publication_gate_decisions_pass_version_uq ON editorial.publication_gate_decisions (case_id, expected_case_version) WHERE outcome = 'PASS';
CREATE UNIQUE INDEX publication_gate_decisions_pass_preview_uq ON editorial.publication_gate_decisions (preview_id) WHERE outcome = 'PASS';
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_version_ck CHECK (expected_case_version > 0);
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_policy_ck CHECK (length(policy_version) BETWEEN 1 AND 100);
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_risk_ck CHECK (risk_level IN ('LOW','MEDIUM','HIGH','BLOCKED_DEFAULT') AND required_editor_count BETWEEN 1 AND 2);
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_quorum_ck CHECK ((risk_level = 'LOW' AND required_editor_count = 1) OR (risk_level IN ('MEDIUM','HIGH','BLOCKED_DEFAULT') AND required_editor_count = 2));
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_outcome_ck CHECK (outcome IN ('PASS','BLOCKED'));
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_time_ck CHECK (preview_expires_at > evaluated_at AND earliest_expiry_at > evaluated_at AND earliest_expiry_at <= preview_expires_at);
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_parity_ck CHECK (outcome = 'BLOCKED' OR application_evaluation_digest = database_evaluation_digest);
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_publisher_conflict_ck CHECK (publisher_conflict_target_type = 'REVIEW_SNAPSHOT' AND publisher_conflict_target_id = review_snapshot_id::text AND publisher_conflict_target_version = expected_case_version AND publisher_conflict_target_digest = snapshot_digest AND publisher_conflict_evaluation_state = 'CLEAR' AND publisher_conflict_valid_until > evaluated_at);
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_step_up_time_ck CHECK (step_up_expires_at > step_up_issued_at AND created_at >= step_up_issued_at AND created_at <= step_up_expires_at);
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_digest_ck CHECK (ops.is_lower_sha256(snapshot_digest) AND ops.is_lower_sha256(preview_digest) AND ops.is_lower_sha256(public_payload_digest) AND ops.is_lower_sha256(claim_revision_set_digest) AND ops.is_lower_sha256(claim_evidence_matrix_digest) AND ops.is_lower_sha256(source_freshness_digest) AND ops.is_lower_sha256(response_policy_digest) AND ops.is_lower_sha256(privacy_restriction_digest) AND ops.is_lower_sha256(rights_digest) AND ops.is_lower_sha256(publication_consent_digest) AND ops.is_lower_sha256(conflict_digest) AND ops.is_lower_sha256(funding_digest) AND ops.is_lower_sha256(hold_coverage_digest) AND ops.is_lower_sha256(activation_set_digest) AND ops.is_lower_sha256(kill_switch_digest) AND ops.is_lower_sha256(review_decision_set_digest) AND ops.is_lower_sha256(quorum_digest) AND ops.is_lower_sha256(policy_digest) AND ops.is_lower_sha256(publisher_conflict_snapshot_digest) AND ops.is_lower_sha256(publisher_conflict_target_digest) AND ops.is_lower_sha256(application_evaluation_digest) AND ops.is_lower_sha256(database_evaluation_digest) AND ops.is_lower_sha256(blocker_set_digest) AND ops.is_lower_sha256(step_up_authorization_receipt_digest) AND ops.is_lower_sha256(action_digest) AND ops.is_lower_sha256(idempotency_key_sha256) AND ops.is_lower_sha256(decision_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON editorial.publication_gate_decisions FROM PUBLIC;
REVOKE ALL ON editorial.publication_gate_decisions FROM gurine_workflow_worker;
REVOKE ALL ON editorial.publication_gate_decisions FROM gurine_control_api;
REVOKE ALL ON editorial.publication_gate_decisions FROM gurine_analysis_worker;
REVOKE ALL ON editorial.publication_gate_decisions FROM gurine_public_projector;
REVOKE ALL ON editorial.publication_gate_decisions FROM gurine_notification_worker;
REVOKE ALL ON editorial.publication_gate_decisions FROM gurine_submission_api;
REVOKE ALL ON editorial.publication_gate_decisions FROM gurine_auditor;
GRANT SELECT ON editorial.publication_gate_decisions TO gurine_control_api;
CREATE TRIGGER editorial_publication_gate_decisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON editorial.publication_gate_decisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE editorial.publication_gate_claim_evidence (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  decision_id uuid NOT NULL,
  ordinal integer NOT NULL,
  claim_id uuid NOT NULL,
  claim_version bigint NOT NULL,
  claim_digest char(64) NOT NULL,
  evidence_id uuid NOT NULL,
  evidence_version bigint NOT NULL,
  evidence_digest char(64) NOT NULL,
  supports text NOT NULL,
  source_ref_type text NOT NULL,
  source_ref_id text NOT NULL,
  source_version text NOT NULL,
  source_digest char(64) NOT NULL,
  source_document_id uuid,
  source_asset_id uuid,
  source_asset_revision bigint,
  response_id uuid,
  response_version bigint,
  response_content_digest char(64),
  editorial_source_evidence_id uuid,
  editorial_source_evidence_version bigint,
  editorial_source_evidence_digest char(64),
  source_retrieved_at timestamptz NOT NULL,
  freshness_state text NOT NULL,
  freshness_policy_digest char(64) NOT NULL,
  source_locator_digest char(64) NOT NULL,
  rights_binding_kind text NOT NULL,
  rights_binding_digest char(64) NOT NULL,
  asset_rights_decision_id uuid,
  asset_rights_digest char(64),
  asset_rights_decision_version bigint,
  asset_rights_decision_kind text,
  asset_access_right text,
  asset_excerpt_right text,
  asset_redistribution_right text,
  asset_commercial_use_right text,
  asset_public_display_right text,
  asset_rights_effective_at timestamptz,
  asset_rights_expires_at timestamptz,
  publication_consent_state text NOT NULL,
  publication_consent_digest char(64) NOT NULL,
  matrix_row_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_editorial_publication_gate_claim_evidence_1 PRIMARY KEY (id)
);
ALTER TABLE editorial.publication_gate_claim_evidence OWNER TO gurine_migrator;
ALTER TABLE editorial.publication_gate_claim_evidence ADD CONSTRAINT publication_gate_claim_evidence_ordinal_uq UNIQUE (decision_id, ordinal);
ALTER TABLE editorial.publication_gate_claim_evidence ADD CONSTRAINT publication_gate_claim_evidence_pair_uq UNIQUE (decision_id, claim_id, claim_version, evidence_id, evidence_version);
ALTER TABLE editorial.publication_gate_claim_evidence ADD CONSTRAINT publication_gate_claim_evidence_row_digest_uq UNIQUE (decision_id, matrix_row_digest);
ALTER TABLE editorial.publication_gate_claim_evidence ADD CONSTRAINT publication_gate_claim_evidence_ordinal_ck CHECK (ordinal BETWEEN 1 AND 100000 AND claim_version > 0 AND evidence_version > 0);
ALTER TABLE editorial.publication_gate_claim_evidence ADD CONSTRAINT publication_gate_claim_evidence_supports_ck CHECK (supports IN ('FACT','CALCULATION','LIMITATION','CONTEXT'));
ALTER TABLE editorial.publication_gate_claim_evidence ADD CONSTRAINT publication_gate_claim_evidence_source_ck CHECK (source_ref_type IN ('RAW_SOURCE_DOCUMENT','RESPONSE_SUBMISSION','EDITORIAL_RECORD') AND length(source_ref_id) BETWEEN 1 AND 512 AND length(source_version) BETWEEN 1 AND 512 AND ((source_ref_type = 'RAW_SOURCE_DOCUMENT' AND source_document_id IS NOT NULL AND source_asset_id IS NOT NULL AND source_asset_revision > 0 AND response_id IS NULL AND response_version IS NULL AND response_content_digest IS NULL AND editorial_source_evidence_id IS NULL AND editorial_source_evidence_version IS NULL AND editorial_source_evidence_digest IS NULL) OR (source_ref_type = 'RESPONSE_SUBMISSION' AND response_id IS NOT NULL AND response_version > 0 AND response_content_digest IS NOT NULL AND source_document_id IS NULL AND source_asset_id IS NULL AND source_asset_revision IS NULL AND editorial_source_evidence_id IS NULL AND editorial_source_evidence_version IS NULL AND editorial_source_evidence_digest IS NULL) OR (source_ref_type = 'EDITORIAL_RECORD' AND editorial_source_evidence_id IS NOT NULL AND editorial_source_evidence_version > 0 AND editorial_source_evidence_digest IS NOT NULL AND source_document_id IS NULL AND source_asset_id IS NULL AND source_asset_revision IS NULL AND response_id IS NULL AND response_version IS NULL AND response_content_digest IS NULL)));
ALTER TABLE editorial.publication_gate_claim_evidence ADD CONSTRAINT publication_gate_claim_evidence_source_binding_ck CHECK ((source_ref_type = 'RAW_SOURCE_DOCUMENT' AND source_ref_id = source_document_id::text AND source_version = source_asset_revision::text) OR (source_ref_type = 'RESPONSE_SUBMISSION' AND source_ref_id = response_id::text AND source_version = response_version::text AND source_digest = response_content_digest) OR (source_ref_type = 'EDITORIAL_RECORD' AND source_ref_id = editorial_source_evidence_id::text AND source_version = editorial_source_evidence_version::text AND source_digest = editorial_source_evidence_digest));
ALTER TABLE editorial.publication_gate_claim_evidence ADD CONSTRAINT publication_gate_claim_evidence_freshness_ck CHECK (freshness_state IN ('CURRENT','STALE','UNKNOWN'));
ALTER TABLE editorial.publication_gate_claim_evidence ADD CONSTRAINT publication_gate_claim_evidence_rights_shape_ck CHECK ((rights_binding_kind = 'ASSET_RIGHTS' AND source_ref_type <> 'RESPONSE_SUBMISSION' AND num_nonnulls(asset_rights_decision_id,asset_rights_digest,asset_rights_decision_version,asset_rights_decision_kind,asset_access_right,asset_excerpt_right,asset_redistribution_right,asset_commercial_use_right,asset_public_display_right,asset_rights_effective_at) = 10) OR (rights_binding_kind = 'RESPONSE_CONSENT' AND source_ref_type = 'RESPONSE_SUBMISSION' AND num_nonnulls(asset_rights_decision_id,asset_rights_digest,asset_rights_decision_version,asset_rights_decision_kind,asset_access_right,asset_excerpt_right,asset_redistribution_right,asset_commercial_use_right,asset_public_display_right,asset_rights_effective_at,asset_rights_expires_at) = 0) OR (rights_binding_kind = 'EDITORIAL_POLICY' AND source_ref_type = 'EDITORIAL_RECORD' AND num_nonnulls(asset_rights_decision_id,asset_rights_digest,asset_rights_decision_version,asset_rights_decision_kind,asset_access_right,asset_excerpt_right,asset_redistribution_right,asset_commercial_use_right,asset_public_display_right,asset_rights_effective_at,asset_rights_expires_at) = 0));
ALTER TABLE editorial.publication_gate_claim_evidence ADD CONSTRAINT publication_gate_claim_evidence_rights_ck CHECK (rights_binding_kind <> 'ASSET_RIGHTS' OR (asset_rights_decision_version > 0 AND asset_rights_decision_kind = 'GRANT' AND asset_access_right = 'ALLOW' AND asset_excerpt_right = 'ALLOW' AND asset_redistribution_right = 'ALLOW' AND asset_commercial_use_right = 'ALLOW' AND asset_public_display_right = 'ALLOW' AND (asset_rights_expires_at IS NULL OR asset_rights_expires_at > asset_rights_effective_at)));
ALTER TABLE editorial.publication_gate_claim_evidence ADD CONSTRAINT publication_gate_claim_evidence_consent_ck CHECK ((source_ref_type = 'RESPONSE_SUBMISSION' AND publication_consent_state = 'AUTHORIZED') OR (source_ref_type <> 'RESPONSE_SUBMISSION' AND publication_consent_state IN ('AUTHORIZED','NOT_APPLICABLE_POLICY')));
ALTER TABLE editorial.publication_gate_claim_evidence ADD CONSTRAINT publication_gate_claim_evidence_digest_ck CHECK (ops.is_lower_sha256(claim_digest) AND ops.is_lower_sha256(evidence_digest) AND ops.is_lower_sha256(source_digest) AND (response_content_digest IS NULL OR ops.is_lower_sha256(response_content_digest)) AND (editorial_source_evidence_digest IS NULL OR ops.is_lower_sha256(editorial_source_evidence_digest)) AND ops.is_lower_sha256(freshness_policy_digest) AND ops.is_lower_sha256(source_locator_digest) AND ops.is_lower_sha256(rights_binding_digest) AND (asset_rights_digest IS NULL OR ops.is_lower_sha256(asset_rights_digest)) AND ops.is_lower_sha256(publication_consent_digest) AND ops.is_lower_sha256(matrix_row_digest));
REVOKE ALL ON editorial.publication_gate_claim_evidence FROM PUBLIC;
REVOKE ALL ON editorial.publication_gate_claim_evidence FROM gurine_workflow_worker;
REVOKE ALL ON editorial.publication_gate_claim_evidence FROM gurine_control_api;
REVOKE ALL ON editorial.publication_gate_claim_evidence FROM gurine_analysis_worker;
REVOKE ALL ON editorial.publication_gate_claim_evidence FROM gurine_public_projector;
REVOKE ALL ON editorial.publication_gate_claim_evidence FROM gurine_notification_worker;
REVOKE ALL ON editorial.publication_gate_claim_evidence FROM gurine_submission_api;
REVOKE ALL ON editorial.publication_gate_claim_evidence FROM gurine_auditor;
GRANT SELECT ON editorial.publication_gate_claim_evidence TO gurine_control_api;
CREATE TRIGGER editorial_publication_gate_claim_evidence_immutable_mutation_guard BEFORE UPDATE OR DELETE ON editorial.publication_gate_claim_evidence FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE editorial.publication_gate_review_bindings (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  decision_id uuid NOT NULL,
  ordinal smallint NOT NULL,
  review_decision_id uuid NOT NULL,
  review_decision_digest char(64) NOT NULL,
  review_snapshot_id uuid NOT NULL,
  review_snapshot_version bigint NOT NULL,
  review_snapshot_digest char(64) NOT NULL,
  review_decision_kind editorial.review_decision NOT NULL DEFAULT 'APPROVE'::editorial.review_decision,
  reviewer_user_id uuid NOT NULL,
  counted_role text NOT NULL,
  conflict_snapshot_id uuid NOT NULL,
  conflict_snapshot_digest char(64) NOT NULL,
  conflict_target_type text NOT NULL DEFAULT 'REVIEW_SNAPSHOT',
  conflict_target_id text NOT NULL,
  conflict_target_version bigint NOT NULL,
  conflict_target_digest char(64) NOT NULL,
  conflict_evaluation_state text NOT NULL DEFAULT 'CLEAR',
  conflict_valid_until timestamptz NOT NULL,
  assignment_digest char(64) NOT NULL,
  binding_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_editorial_publication_gate_review_bindings_1 PRIMARY KEY (id)
);
ALTER TABLE editorial.publication_gate_review_bindings OWNER TO gurine_migrator;
ALTER TABLE editorial.publication_gate_review_bindings ADD CONSTRAINT publication_gate_review_bindings_ordinal_uq UNIQUE (decision_id, ordinal);
ALTER TABLE editorial.publication_gate_review_bindings ADD CONSTRAINT publication_gate_review_bindings_decision_uq UNIQUE (decision_id, review_decision_id);
ALTER TABLE editorial.publication_gate_review_bindings ADD CONSTRAINT publication_gate_review_bindings_reviewer_uq UNIQUE (decision_id, reviewer_user_id);
ALTER TABLE editorial.publication_gate_review_bindings ADD CONSTRAINT publication_gate_review_bindings_digest_uq UNIQUE (decision_id, binding_digest);
ALTER TABLE editorial.publication_gate_review_bindings ADD CONSTRAINT publication_gate_review_bindings_ordinal_ck CHECK (ordinal BETWEEN 1 AND 3);
ALTER TABLE editorial.publication_gate_review_bindings ADD CONSTRAINT publication_gate_review_bindings_role_ck CHECK (counted_role IN ('EDITOR','LEGAL_REVIEWER'));
ALTER TABLE editorial.publication_gate_review_bindings ADD CONSTRAINT publication_gate_review_bindings_exact_ck CHECK (review_snapshot_version > 0 AND review_decision_kind = 'APPROVE' AND conflict_target_type = 'REVIEW_SNAPSHOT' AND conflict_target_id = review_snapshot_id::text AND conflict_target_version = review_snapshot_version AND conflict_target_digest = review_snapshot_digest AND conflict_evaluation_state = 'CLEAR' AND conflict_valid_until > created_at);
ALTER TABLE editorial.publication_gate_review_bindings ADD CONSTRAINT publication_gate_review_bindings_digest_ck CHECK (ops.is_lower_sha256(review_decision_digest) AND ops.is_lower_sha256(review_snapshot_digest) AND ops.is_lower_sha256(conflict_snapshot_digest) AND ops.is_lower_sha256(conflict_target_digest) AND ops.is_lower_sha256(assignment_digest) AND ops.is_lower_sha256(binding_digest));
REVOKE ALL ON editorial.publication_gate_review_bindings FROM PUBLIC;
REVOKE ALL ON editorial.publication_gate_review_bindings FROM gurine_workflow_worker;
REVOKE ALL ON editorial.publication_gate_review_bindings FROM gurine_control_api;
REVOKE ALL ON editorial.publication_gate_review_bindings FROM gurine_analysis_worker;
REVOKE ALL ON editorial.publication_gate_review_bindings FROM gurine_public_projector;
REVOKE ALL ON editorial.publication_gate_review_bindings FROM gurine_notification_worker;
REVOKE ALL ON editorial.publication_gate_review_bindings FROM gurine_submission_api;
REVOKE ALL ON editorial.publication_gate_review_bindings FROM gurine_auditor;
GRANT SELECT ON editorial.publication_gate_review_bindings TO gurine_control_api;
CREATE TRIGGER editorial_publication_gate_review_bindings_immutable_mutation_guard BEFORE UPDATE OR DELETE ON editorial.publication_gate_review_bindings FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE editorial.publication_gate_blockers (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  decision_id uuid NOT NULL,
  ordinal smallint NOT NULL,
  blocker_code text NOT NULL,
  subject_type text NOT NULL,
  subject_id text NOT NULL,
  subject_version bigint,
  subject_digest char(64) NOT NULL,
  detail_code text NOT NULL,
  resolution_kind text NOT NULL,
  resolution_operation_id text,
  policy_digest char(64) NOT NULL,
  blocker_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_editorial_publication_gate_blockers_1 PRIMARY KEY (id)
);
ALTER TABLE editorial.publication_gate_blockers OWNER TO gurine_migrator;
ALTER TABLE editorial.publication_gate_blockers ADD CONSTRAINT publication_gate_blockers_ordinal_uq UNIQUE (decision_id, ordinal);
ALTER TABLE editorial.publication_gate_blockers ADD CONSTRAINT publication_gate_blockers_fact_uq UNIQUE (decision_id, blocker_code, subject_type, subject_id, subject_digest);
ALTER TABLE editorial.publication_gate_blockers ADD CONSTRAINT publication_gate_blockers_digest_uq UNIQUE (decision_id, blocker_digest);
ALTER TABLE editorial.publication_gate_blockers ADD CONSTRAINT publication_gate_blockers_ordinal_ck CHECK (ordinal BETWEEN 1 AND 256);
ALTER TABLE editorial.publication_gate_blockers ADD CONSTRAINT publication_gate_blockers_code_ck CHECK (blocker_code IN ('CASE_NOT_READY','SNAPSHOT_STALE','PREVIEW_STALE','CLAIM_EVIDENCE_INCOMPLETE','SOURCE_STALE','RESPONSE_POLICY_UNSATISFIED','RIGHTS_NOT_AUTHORIZED','PRIVACY_OR_RESTRICTION_BLOCKED','DISCLOSURE_HOLD_ACTIVE','CONFLICT_UNRESOLVED','QUORUM_INSUFFICIENT','LEGAL_APPROVAL_REQUIRED','LEGAL_ACTIVATION_NOT_APPROVED','KILL_SWITCH_ACTIVE','EVALUATOR_DIVERGENCE'));
ALTER TABLE editorial.publication_gate_blockers ADD CONSTRAINT publication_gate_blockers_subject_ck CHECK (subject_type IN ('CASE','SNAPSHOT','PREVIEW','CLAIM','EVIDENCE','SOURCE','RESPONSE_POLICY','RIGHTS_DECISION','RESTRICTION','LEGAL_HOLD','CONFLICT_SNAPSHOT','REVIEW_DECISION','ACTIVATION_DECISION','KILL_SWITCH','EVALUATOR') AND length(subject_id) BETWEEN 1 AND 512 AND (subject_version IS NULL OR subject_version > 0));
ALTER TABLE editorial.publication_gate_blockers ADD CONSTRAINT publication_gate_blockers_detail_ck CHECK (length(detail_code) BETWEEN 1 AND 100);
ALTER TABLE editorial.publication_gate_blockers ADD CONSTRAINT publication_gate_blockers_resolution_ck CHECK (resolution_kind IN ('FIX_CASE','REBUILD_SNAPSHOT','REBUILD_PREVIEW','LINK_EVIDENCE','REFRESH_SOURCE','COMPLETE_RESPONSE_POLICY','REVISE_RIGHTS','REMOVE_RESTRICTION','RELEASE_HOLD','RESOLVE_CONFLICT','ADD_REVIEWER','OBTAIN_LEGAL_APPROVAL','ACTIVATE_CAPABILITY','DEACTIVATE_SWITCH','INVESTIGATE_EVALUATOR') AND (resolution_operation_id IS NULL OR resolution_operation_id ~ '^[A-Za-z][A-Za-z0-9]{1,127}$'));
ALTER TABLE editorial.publication_gate_blockers ADD CONSTRAINT publication_gate_blockers_digest_ck CHECK (ops.is_lower_sha256(subject_digest) AND ops.is_lower_sha256(policy_digest) AND ops.is_lower_sha256(blocker_digest));
REVOKE ALL ON editorial.publication_gate_blockers FROM PUBLIC;
REVOKE ALL ON editorial.publication_gate_blockers FROM gurine_workflow_worker;
REVOKE ALL ON editorial.publication_gate_blockers FROM gurine_control_api;
REVOKE ALL ON editorial.publication_gate_blockers FROM gurine_analysis_worker;
REVOKE ALL ON editorial.publication_gate_blockers FROM gurine_public_projector;
REVOKE ALL ON editorial.publication_gate_blockers FROM gurine_notification_worker;
REVOKE ALL ON editorial.publication_gate_blockers FROM gurine_submission_api;
REVOKE ALL ON editorial.publication_gate_blockers FROM gurine_auditor;
GRANT SELECT ON editorial.publication_gate_blockers TO gurine_control_api;
CREATE TRIGGER editorial_publication_gate_blockers_immutable_mutation_guard BEFORE UPDATE OR DELETE ON editorial.publication_gate_blockers FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.sli_window_receipts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  sli_id text NOT NULL,
  definition_version text NOT NULL,
  definition_digest char(64) NOT NULL,
  environment text NOT NULL,
  scope_type text NOT NULL,
  scope_id text NOT NULL,
  scope_digest char(64) NOT NULL,
  capability_id text NOT NULL,
  operation_id text,
  sli_kind text NOT NULL,
  window_kind text NOT NULL,
  window_start timestamptz NOT NULL,
  window_end timestamptz NOT NULL,
  window_sequence bigint NOT NULL,
  prior_receipt_id uuid,
  prior_window_sequence bigint,
  prior_window_end timestamptz,
  prior_receipt_digest char(64),
  evaluation_batch_id uuid NOT NULL,
  measurement_kind text NOT NULL,
  unit text NOT NULL,
  target_operator text NOT NULL,
  target_value numeric(30,12) NOT NULL,
  objective_good_ratio numeric(20,18) NOT NULL,
  quantile numeric(6,5),
  expected_observation_count bigint NOT NULL,
  observed_observation_count bigint NOT NULL,
  missing_observation_count bigint NOT NULL,
  excluded_count bigint NOT NULL DEFAULT 0,
  maintenance_observation_count bigint NOT NULL DEFAULT 0,
  eligible_count bigint NOT NULL,
  good_count bigint NOT NULL,
  bad_count bigint NOT NULL,
  measured_value numeric(30,12),
  error_budget_fraction numeric(20,18) NOT NULL,
  error_budget_allowed_count numeric(30,12),
  error_budget_consumed_count numeric(30,12),
  error_budget_remaining_count numeric(30,12),
  error_budget_consumed_fraction numeric(30,12),
  burn_rate numeric(30,12),
  burn_policy_digest char(64) NOT NULL,
  burn_pair_kind text NOT NULL DEFAULT 'NONE',
  burn_threshold numeric(10,4),
  paired_receipt_id uuid,
  paired_window_kind text,
  paired_window_sequence bigint,
  paired_receipt_digest char(64),
  burn_alert_state text NOT NULL DEFAULT 'NOT_APPLICABLE',
  latency_threshold_ms bigint,
  evaluation_state text NOT NULL,
  telemetry_state text NOT NULL,
  missing_telemetry_reason text NOT NULL DEFAULT 'NONE',
  operational_state text NOT NULL,
  evidence_set jsonb NOT NULL,
  evidence_item_count integer NOT NULL,
  incident_id uuid,
  incident_event_id uuid,
  incident_link_kind text NOT NULL DEFAULT 'NONE',
  exclusion_set jsonb NOT NULL DEFAULT '{"schemaVersion":"sli-exclusion-set.v1","items":[]}'::jsonb,
  exclusion_set_digest char(64) NOT NULL,
  telemetry_gap_set jsonb NOT NULL DEFAULT '{"schemaVersion":"sli-telemetry-gap-set.v1","items":[]}'::jsonb,
  telemetry_gap_count integer NOT NULL DEFAULT 0,
  telemetry_gap_digest char(64) NOT NULL,
  evidence_set_digest char(64) NOT NULL,
  telemetry_query_digest char(64) NOT NULL,
  telemetry_backend_receipt_digest char(64) NOT NULL,
  source_watermark_digest char(64) NOT NULL,
  evaluator_config_digest char(64) NOT NULL,
  build_revision text NOT NULL,
  evaluator_version text NOT NULL,
  policy_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_event_id uuid NOT NULL,
  evaluated_at timestamptz NOT NULL,
  receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_sli_window_receipts_1 PRIMARY KEY (id)
);
ALTER TABLE ops.sli_window_receipts OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.sli_window_arithmetic_is_valid(ops.sli_window_receipts) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL $$;
ALTER FUNCTION ops.sli_window_arithmetic_is_valid(ops.sli_window_receipts) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.sli_window_arithmetic_is_valid(ops.sli_window_receipts) FROM PUBLIC;
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_logical_window_uq UNIQUE (sli_id, definition_version, environment, scope_digest, window_kind, window_start, window_end);
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_sequence_uq UNIQUE (sli_id, definition_version, environment, scope_digest, window_kind, window_sequence);
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_evidence_uq UNIQUE (sli_id, definition_version, environment, scope_digest, window_start, window_end, evidence_set_digest);
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_digest_uq UNIQUE (receipt_digest);
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_pair_binding_uq UNIQUE (id, sli_id, definition_version, environment, scope_digest, window_kind, window_sequence, receipt_digest);
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_id_ck CHECK (sli_id ~ '^[a-z][a-z0-9_.-]{2,159}$' AND capability_id ~ '^[a-z][a-z0-9_.-]{2,127}$' AND length(definition_version) BETWEEN 1 AND 100 AND length(scope_id) BETWEEN 1 AND 512);
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_environment_ck CHECK (environment IN ('DEVELOPMENT','TEST','STAGING','PRODUCTION'));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_scope_ck CHECK (scope_type IN ('SERVICE','OPERATION','WORKER','CONNECTOR','PUBLIC_SURFACE','CAPABILITY'));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_kind_ck CHECK (sli_kind IN ('AVAILABILITY','LATENCY','FRESHNESS','COMPLETENESS','ERROR_RATE','QUEUE_LAG','DELIVERY_SUCCESS','RESTORE_RPO','RESTORE_RTO'));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_window_ck CHECK (window_kind IN ('FIVE_MINUTE','THIRTY_MINUTE','ONE_HOUR','SIX_HOUR','UTC_MONTH','POLICY_WINDOW') AND window_end > window_start AND ((window_kind = 'FIVE_MINUTE' AND window_end - window_start = interval '5 minutes') OR (window_kind = 'THIRTY_MINUTE' AND window_end - window_start = interval '30 minutes') OR (window_kind = 'ONE_HOUR' AND window_end - window_start = interval '1 hour') OR (window_kind = 'SIX_HOUR' AND window_end - window_start = interval '6 hours') OR window_kind IN ('UTC_MONTH','POLICY_WINDOW')));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_sequence_ck CHECK (window_sequence > 0 AND ((window_sequence = 1 AND prior_receipt_id IS NULL AND prior_window_sequence IS NULL AND prior_window_end IS NULL AND prior_receipt_digest IS NULL) OR (window_sequence > 1 AND prior_receipt_id IS NOT NULL AND prior_window_sequence = window_sequence - 1 AND prior_window_end < window_end AND prior_receipt_digest IS NOT NULL)));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_measurement_ck CHECK (measurement_kind IN ('RATIO','COUNT','DURATION_MS','QUANTILE','PROPAGATION_LAG','SOURCE_LAG') AND target_operator IN ('GTE','LTE') AND length(unit) BETWEEN 1 AND 32 AND objective_good_ratio BETWEEN 0 AND 1 AND error_budget_fraction = 1 - objective_good_ratio);
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_quantile_ck CHECK ((measurement_kind IN ('QUANTILE','PROPAGATION_LAG','SOURCE_LAG') AND quantile > 0 AND quantile <= 1) OR (measurement_kind NOT IN ('QUANTILE','PROPAGATION_LAG','SOURCE_LAG') AND quantile IS NULL));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_counts_ck CHECK (expected_observation_count >= 0 AND observed_observation_count >= 0 AND missing_observation_count >= 0 AND excluded_count >= 0 AND maintenance_observation_count >= 0 AND eligible_count >= 0 AND good_count >= 0 AND bad_count >= 0 AND expected_observation_count = observed_observation_count + missing_observation_count AND observed_observation_count = eligible_count + excluded_count AND good_count + bad_count = eligible_count AND maintenance_observation_count <= eligible_count);
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_arithmetic_ck CHECK (ops.sli_window_arithmetic_is_valid(ROW(id,sli_id,definition_version,definition_digest,environment,scope_type,scope_id,scope_digest,capability_id,operation_id,sli_kind,window_kind,window_start,window_end,window_sequence,prior_receipt_id,prior_window_sequence,prior_window_end,prior_receipt_digest,evaluation_batch_id,measurement_kind,unit,target_operator,target_value,objective_good_ratio,quantile,expected_observation_count,observed_observation_count,missing_observation_count,excluded_count,maintenance_observation_count,eligible_count,good_count,bad_count,measured_value,error_budget_fraction,error_budget_allowed_count,error_budget_consumed_count,error_budget_remaining_count,error_budget_consumed_fraction,burn_rate,burn_policy_digest,burn_pair_kind,burn_threshold,paired_receipt_id,paired_window_kind,paired_window_sequence,paired_receipt_digest,burn_alert_state,latency_threshold_ms,evaluation_state,telemetry_state,missing_telemetry_reason,operational_state,evidence_set,evidence_item_count,incident_id,incident_event_id,incident_link_kind,exclusion_set,exclusion_set_digest,telemetry_gap_set,telemetry_gap_count,telemetry_gap_digest,evidence_set_digest,telemetry_query_digest,telemetry_backend_receipt_digest,source_watermark_digest,evaluator_config_digest,build_revision,evaluator_version,policy_digest,audit_event_id,outbox_event_id,evaluated_at,receipt_digest,created_at)::ops.sli_window_receipts));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_latency_ck CHECK ((sli_kind = 'LATENCY' AND latency_threshold_ms IS NOT NULL AND latency_threshold_ms > 0) OR (sli_kind <> 'LATENCY' AND latency_threshold_ms IS NULL));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_evaluation_ck CHECK (evaluation_state IN ('MET','BREACHED','UNKNOWN') AND telemetry_state IN ('COMPLETE','GAP') AND ((evaluation_state <> 'UNKNOWN' AND telemetry_state = 'COMPLETE' AND missing_observation_count = 0 AND eligible_count > 0 AND measured_value IS NOT NULL) OR (evaluation_state = 'UNKNOWN' AND (telemetry_state = 'GAP' OR eligible_count = 0) AND measured_value IS NULL AND burn_rate IS NULL)));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_missing_ck CHECK (missing_telemetry_reason IN ('NONE','NO_ELIGIBLE_OBSERVATIONS','HEARTBEAT_MISSING','QUERY_FAILED','BACKEND_UNAVAILABLE','SOURCE_WATERMARK_MISSING','EVIDENCE_INCOMPLETE') AND ((missing_telemetry_reason = 'NONE' AND telemetry_state = 'COMPLETE') OR (missing_telemetry_reason <> 'NONE' AND evaluation_state = 'UNKNOWN')));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_operational_ck CHECK (operational_state IN ('OPERATIONAL','DEGRADED','INCIDENT','UNKNOWN_INTERNAL') AND ((operational_state IN ('INCIDENT','UNKNOWN_INTERNAL') AND incident_id IS NOT NULL) OR operational_state IN ('OPERATIONAL','DEGRADED')));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_unknown_ck CHECK (telemetry_state <> 'GAP' OR operational_state = 'UNKNOWN_INTERNAL');
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_burn_pair_ck CHECK ((burn_pair_kind = 'NONE' AND burn_threshold IS NULL AND paired_receipt_id IS NULL AND paired_window_kind IS NULL AND paired_window_sequence IS NULL AND paired_receipt_digest IS NULL AND burn_alert_state = 'NOT_APPLICABLE') OR (burn_pair_kind = 'FAST_5M_1H' AND burn_threshold = 14.4 AND ((window_kind = 'FIVE_MINUTE' AND paired_window_kind = 'ONE_HOUR') OR (window_kind = 'ONE_HOUR' AND paired_window_kind = 'FIVE_MINUTE')) AND paired_receipt_id IS NOT NULL AND paired_window_sequence IS NOT NULL AND paired_receipt_digest IS NOT NULL AND burn_alert_state IN ('CLEAR','SINGLE_WINDOW_ONLY','FIRING')) OR (burn_pair_kind = 'SLOW_30M_6H' AND burn_threshold = 6.0 AND ((window_kind = 'THIRTY_MINUTE' AND paired_window_kind = 'SIX_HOUR') OR (window_kind = 'SIX_HOUR' AND paired_window_kind = 'THIRTY_MINUTE')) AND paired_receipt_id IS NOT NULL AND paired_window_sequence IS NOT NULL AND paired_receipt_digest IS NOT NULL AND burn_alert_state IN ('CLEAR','SINGLE_WINDOW_ONLY','FIRING')));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_incident_link_ck CHECK (incident_link_kind IN ('NONE','SLO_BREACH_DETECTION','TELEMETRY_GAP_DETECTION','RESTORATION_EVIDENCE') AND ((incident_link_kind = 'NONE' AND incident_id IS NULL AND incident_event_id IS NULL) OR (incident_link_kind <> 'NONE' AND incident_id IS NOT NULL AND incident_event_id IS NOT NULL)));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_json_shape_ck CHECK (ops.sli_evidence_set_is_valid(evidence_set) AND ops.sli_exclusion_set_is_valid(exclusion_set) AND ops.sli_telemetry_gap_set_is_valid(telemetry_gap_set));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_json_count_ck CHECK (evidence_item_count = jsonb_array_length(evidence_set->'items') AND excluded_count = ops.sli_exclusion_count(exclusion_set) AND telemetry_gap_count = jsonb_array_length(telemetry_gap_set->'items'));
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_time_ck CHECK (evaluated_at >= window_end);
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_version_text_ck CHECK (length(build_revision) BETWEEN 7 AND 128 AND length(evaluator_version) BETWEEN 1 AND 100);
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_digest_ck CHECK (ops.is_lower_sha256(definition_digest) AND ops.is_lower_sha256(scope_digest) AND (prior_receipt_digest IS NULL OR ops.is_lower_sha256(prior_receipt_digest)) AND ops.is_lower_sha256(burn_policy_digest) AND (paired_receipt_digest IS NULL OR ops.is_lower_sha256(paired_receipt_digest)) AND ops.is_lower_sha256(exclusion_set_digest) AND ops.is_lower_sha256(telemetry_gap_digest) AND ops.is_lower_sha256(evidence_set_digest) AND ops.is_lower_sha256(telemetry_query_digest) AND ops.is_lower_sha256(telemetry_backend_receipt_digest) AND ops.is_lower_sha256(source_watermark_digest) AND ops.is_lower_sha256(evaluator_config_digest) AND ops.is_lower_sha256(policy_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON ops.sli_window_receipts FROM PUBLIC;
REVOKE ALL ON ops.sli_window_receipts FROM gurine_workflow_worker;
REVOKE ALL ON ops.sli_window_receipts FROM gurine_control_api;
REVOKE ALL ON ops.sli_window_receipts FROM gurine_analysis_worker;
REVOKE ALL ON ops.sli_window_receipts FROM gurine_public_projector;
REVOKE ALL ON ops.sli_window_receipts FROM gurine_notification_worker;
REVOKE ALL ON ops.sli_window_receipts FROM gurine_submission_api;
REVOKE ALL ON ops.sli_window_receipts FROM gurine_auditor;
GRANT SELECT ON ops.sli_window_receipts TO gurine_control_api;
GRANT SELECT ON ops.sli_window_receipts TO gurine_workflow_worker;
CREATE TRIGGER ops_sli_window_receipts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.sli_window_receipts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.journey_instances (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  journey_code text NOT NULL,
  root_object_kind text NOT NULL,
  root_object_id text NOT NULL,
  root_object_version bigint NOT NULL,
  root_object_digest char(64) NOT NULL,
  current_object_kind text NOT NULL,
  current_object_id text NOT NULL,
  current_object_version bigint NOT NULL,
  current_object_digest char(64) NOT NULL,
  current_node_id text NOT NULL,
  state text NOT NULL DEFAULT 'ACTIVE',
  version bigint NOT NULL DEFAULT 1,
  current_owner_kind text NOT NULL,
  current_owner_function text NOT NULL,
  current_owner_ref_hmac char(64) NOT NULL,
  next_owner_kind text,
  next_owner_function text,
  next_owner_ref_hmac char(64),
  due_at timestamptz NOT NULL,
  active_handoff_id uuid,
  active_handoff_generation bigint,
  active_handoff_state text,
  escalation_state text NOT NULL DEFAULT 'NOT_DUE',
  last_receipt_id uuid NOT NULL,
  last_receipt_sequence bigint NOT NULL,
  last_receipt_digest char(64) NOT NULL,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  terminal_at timestamptz,
  CONSTRAINT g_pk_ops_journey_instances_1 PRIMARY KEY (id)
);
ALTER TABLE ops.journey_instances OWNER TO gurine_migrator;
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_version_uq UNIQUE (id, version);
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_code_uq UNIQUE (id, journey_code);
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_receipt_head_uq UNIQUE (id, last_receipt_id, last_receipt_digest);
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_root_uq UNIQUE (journey_code, root_object_kind, root_object_id, root_object_version, root_object_digest);
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_code_ck CHECK (journey_code IN ('J-01','J-02','J-03','J-04','J-05','J-06','J-07','J-08','J-09','J-10','J-11','J-12'));
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_object_ck CHECK (length(root_object_kind) BETWEEN 1 AND 100 AND length(root_object_id) BETWEEN 1 AND 512 AND root_object_version > 0 AND length(current_object_kind) BETWEEN 1 AND 100 AND length(current_object_id) BETWEEN 1 AND 512 AND current_object_version > 0 AND length(current_node_id) BETWEEN 1 AND 200);
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_state_ck CHECK (state IN ('ACTIVE','WAITING_ACK','BLOCKED','RECONCILIATION_REQUIRED','COMPLETED','CANCELLED','EXPIRED','REJECTED'));
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_owner_ck CHECK (current_owner_kind IN ('HUMAN_USER','HUMAN_ROLE','SERVICE','WORKER','QUEUE') AND length(current_owner_function) BETWEEN 1 AND 160 AND ((next_owner_kind IS NULL AND next_owner_function IS NULL AND next_owner_ref_hmac IS NULL) OR (next_owner_kind IN ('HUMAN_USER','HUMAN_ROLE','SERVICE','WORKER','QUEUE') AND length(next_owner_function) BETWEEN 1 AND 160 AND next_owner_ref_hmac IS NOT NULL)));
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_handoff_ck CHECK ((state = 'WAITING_ACK' AND active_handoff_id IS NOT NULL AND active_handoff_generation > 0 AND active_handoff_state = 'PENDING_ACK' AND next_owner_kind IS NOT NULL) OR (state <> 'WAITING_ACK' AND active_handoff_id IS NULL AND active_handoff_generation IS NULL AND active_handoff_state IS NULL AND next_owner_kind IS NULL AND next_owner_function IS NULL AND next_owner_ref_hmac IS NULL));
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_escalation_ck CHECK (escalation_state IN ('NOT_DUE','DUE','ESCALATED','RESOLVED'));
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_terminal_ck CHECK ((state IN ('COMPLETED','CANCELLED','EXPIRED','REJECTED') AND terminal_at IS NOT NULL) OR (state NOT IN ('COMPLETED','CANCELLED','EXPIRED','REJECTED') AND terminal_at IS NULL));
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_sequence_ck CHECK (version > 0 AND last_receipt_sequence = version AND updated_at >= started_at AND (terminal_at IS NULL OR terminal_at >= started_at));
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_digest_ck CHECK (ops.is_lower_sha256(root_object_digest) AND ops.is_lower_sha256(current_object_digest) AND ops.is_lower_sha256(current_owner_ref_hmac) AND (next_owner_ref_hmac IS NULL OR ops.is_lower_sha256(next_owner_ref_hmac)) AND ops.is_lower_sha256(last_receipt_digest));
REVOKE ALL ON ops.journey_instances FROM PUBLIC;
REVOKE ALL ON ops.journey_instances FROM gurine_workflow_worker;
REVOKE ALL ON ops.journey_instances FROM gurine_control_api;
REVOKE ALL ON ops.journey_instances FROM gurine_analysis_worker;
REVOKE ALL ON ops.journey_instances FROM gurine_public_projector;
REVOKE ALL ON ops.journey_instances FROM gurine_notification_worker;
REVOKE ALL ON ops.journey_instances FROM gurine_submission_api;
REVOKE ALL ON ops.journey_instances FROM gurine_auditor;
GRANT SELECT ON ops.journey_instances TO gurine_control_api;
GRANT SELECT ON ops.journey_instances TO gurine_workflow_worker;
GRANT SELECT ON ops.journey_instances TO gurine_scheduler;
CREATE TABLE ops.journey_handoffs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  journey_instance_id uuid NOT NULL,
  journey_code text NOT NULL,
  edge_id text NOT NULL,
  handoff_kind text NOT NULL,
  generation bigint NOT NULL,
  from_node_id text NOT NULL,
  to_node_id text NOT NULL,
  from_owner_kind text NOT NULL,
  from_owner_function text NOT NULL,
  from_owner_ref_hmac char(64) NOT NULL,
  receiver_kind text NOT NULL,
  receiver_function text NOT NULL,
  receiver_ref_hmac char(64) NOT NULL,
  required_receiver_capability text NOT NULL,
  subject_kind text NOT NULL,
  subject_id text NOT NULL,
  subject_version bigint NOT NULL,
  subject_digest char(64) NOT NULL,
  ack_authority_kind text NOT NULL,
  ack_authority_id text NOT NULL,
  binding_digest char(64) NOT NULL,
  state text NOT NULL DEFAULT 'PENDING_ACK',
  version bigint NOT NULL DEFAULT 1,
  requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  due_at timestamptz NOT NULL,
  decided_at timestamptz,
  decision_actor_binding_hmac char(64),
  decision_reason_code text,
  decision_reason_encrypted bytea,
  decision_reason_digest char(64),
  request_receipt_id uuid NOT NULL,
  request_receipt_digest char(64) NOT NULL,
  last_receipt_id uuid NOT NULL,
  last_receipt_digest char(64) NOT NULL,
  CONSTRAINT g_pk_ops_journey_handoffs_1 PRIMARY KEY (id)
);
ALTER TABLE ops.journey_handoffs OWNER TO gurine_migrator;
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_generation_uq UNIQUE (journey_instance_id, generation);
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_instance_identity_uq UNIQUE (id, journey_instance_id);
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_instance_generation_uq UNIQUE (id, journey_instance_id, generation);
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_instance_version_uq UNIQUE (id, journey_instance_id, version);
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_state_binding_uq UNIQUE (id, journey_instance_id, generation, state);
CREATE UNIQUE INDEX journey_handoffs_one_pending_uq ON ops.journey_handoffs (journey_instance_id) WHERE state = 'PENDING_ACK';
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_code_ck CHECK (journey_code IN ('J-01','J-02','J-03','J-04','J-05','J-06','J-07','J-08','J-09','J-10','J-11','J-12') AND edge_id ~ '^J-(0[1-9]|1[0-2])-E[0-9]{2}[A-Z]?$');
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_kind_ck CHECK (handoff_kind IN ('HS-01-RESPONSE_REQUEST_DELIVERY','HS-02-RESPONSE_INTAKE_OWNERSHIP','HS-03-CASE_OWNERSHIP','HS-04-SIGNAL_ENRICHMENT_TASK','HS-05-EDITORIAL_REVIEW_ASSIGNMENT','HS-06-REVIEW_CHANGES_TASK','HS-07-PUBLICATION_ASSIGNMENT','HS-08-ACTION_REVIEW_ASSIGNMENT','HS-09-ACTION_EXECUTION_CLAIM','HS-10-ACTION_RECONCILIATION','HS-11-AI_RUN_RECONCILIATION','HS-12-EVIDENCE_PROJECTION_ACK','HS-13-CORRECTION_OWNER','HS-14-SOURCE_DRIFT_RECOVERY','HS-15-COMMERCIAL_REMEDIATION_TASK','HS-16-RETENTION_WATCH_TASK','HS-17-COMMUNICATION_DELIVERY_OWNERSHIP','HS-18-COMMUNICATION_DELIVERY_RECONCILIATION','HS-19-PAID_PACKET_TERMINAL_BINDING','HS-20-COMMERCIAL_CONTROL_EXTERNAL_ACK'));
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_owner_ck CHECK (from_owner_kind IN ('HUMAN_USER','HUMAN_ROLE','SERVICE','WORKER','QUEUE') AND receiver_kind IN ('HUMAN_USER','HUMAN_ROLE','SERVICE','WORKER','QUEUE') AND length(from_owner_function) BETWEEN 1 AND 160 AND length(receiver_function) BETWEEN 1 AND 160 AND length(required_receiver_capability) BETWEEN 1 AND 200);
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_subject_ck CHECK (length(subject_kind) BETWEEN 1 AND 100 AND length(subject_id) BETWEEN 1 AND 512 AND subject_version > 0 AND length(from_node_id) BETWEEN 1 AND 200 AND length(to_node_id) BETWEEN 1 AND 200);
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_authority_ck CHECK (ack_authority_kind IN ('EXTERNAL_OPERATION','PRIVATE_SERVICE_OPERATION','DOMAIN_RECEIPT_HANDLER','INBOX_CLAIM','EVENT_HANDLER') AND length(ack_authority_id) BETWEEN 1 AND 240);
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_state_ck CHECK (state IN ('PENDING_ACK','ACKNOWLEDGED','DECLINED','EXPIRED','CANCELLED','SUPERSEDED'));
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_decision_ck CHECK ((state = 'PENDING_ACK' AND decided_at IS NULL AND decision_actor_binding_hmac IS NULL AND decision_reason_code IS NULL AND decision_reason_encrypted IS NULL AND decision_reason_digest IS NULL) OR (state = 'ACKNOWLEDGED' AND decided_at IS NOT NULL AND decision_actor_binding_hmac IS NOT NULL AND decision_reason_code IS NULL AND decision_reason_encrypted IS NULL AND decision_reason_digest IS NULL) OR (state = 'DECLINED' AND decided_at IS NOT NULL AND decision_actor_binding_hmac IS NOT NULL AND decision_reason_code IN ('CAPABILITY_UNAVAILABLE','OBJECT_SCOPE_MISMATCH','CONFLICT_OF_INTEREST','WORKLOAD_CAPACITY','DEPENDENCY_BLOCKED','SUBJECT_INVALID','OWNER_UNAVAILABLE','POLICY_BLOCKED','RECEIVER_DECLINED') AND octet_length(decision_reason_encrypted) >= 32 AND decision_reason_digest IS NOT NULL) OR (state IN ('EXPIRED','CANCELLED','SUPERSEDED') AND decided_at IS NOT NULL AND decision_actor_binding_hmac IS NOT NULL AND decision_reason_code IN ('HANDOFF_EXPIRED','SOURCE_CANCELLED','REPLACEMENT_CREATED') AND decision_reason_encrypted IS NULL AND decision_reason_digest IS NULL));
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_sequence_ck CHECK (generation > 0 AND version > 0 AND due_at > requested_at AND (decided_at IS NULL OR decided_at >= requested_at));
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_digest_ck CHECK (ops.is_lower_sha256(from_owner_ref_hmac) AND ops.is_lower_sha256(receiver_ref_hmac) AND ops.is_lower_sha256(subject_digest) AND ops.is_lower_sha256(binding_digest) AND (decision_actor_binding_hmac IS NULL OR ops.is_lower_sha256(decision_actor_binding_hmac)) AND (decision_reason_digest IS NULL OR ops.is_lower_sha256(decision_reason_digest)) AND ops.is_lower_sha256(request_receipt_digest) AND ops.is_lower_sha256(last_receipt_digest));
REVOKE ALL ON ops.journey_handoffs FROM PUBLIC;
REVOKE ALL ON ops.journey_handoffs FROM gurine_workflow_worker;
REVOKE ALL ON ops.journey_handoffs FROM gurine_control_api;
REVOKE ALL ON ops.journey_handoffs FROM gurine_analysis_worker;
REVOKE ALL ON ops.journey_handoffs FROM gurine_public_projector;
REVOKE ALL ON ops.journey_handoffs FROM gurine_notification_worker;
REVOKE ALL ON ops.journey_handoffs FROM gurine_submission_api;
REVOKE ALL ON ops.journey_handoffs FROM gurine_auditor;
GRANT SELECT ON ops.journey_handoffs TO gurine_control_api;
GRANT SELECT ON ops.journey_handoffs TO gurine_workflow_worker;
GRANT SELECT ON ops.journey_handoffs TO gurine_scheduler;
CREATE TABLE ops.journey_transition_receipts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  journey_instance_id uuid NOT NULL,
  journey_instance_version bigint NOT NULL,
  handoff_id uuid,
  handoff_version bigint,
  edge_id text NOT NULL,
  sequence bigint NOT NULL,
  receipt_kind text NOT NULL,
  prior_receipt_id uuid,
  prior_receipt_digest char(64),
  subject_digest char(64) NOT NULL,
  prior_owner_binding_digest char(64),
  current_owner_binding_digest char(64) NOT NULL,
  next_owner_binding_digest char(64),
  prior_instance_state text,
  resulting_instance_state text NOT NULL,
  prior_handoff_state text,
  resulting_handoff_state text,
  escalation_state text NOT NULL,
  prior_due_at timestamptz,
  resulting_due_at timestamptz NOT NULL,
  effect_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_event_id uuid,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  receipt_digest char(64) NOT NULL,
  CONSTRAINT g_pk_ops_journey_transition_receipts_1 PRIMARY KEY (id)
);
ALTER TABLE ops.journey_transition_receipts OWNER TO gurine_migrator;
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_sequence_uq UNIQUE (journey_instance_id, sequence);
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_instance_version_uq UNIQUE (journey_instance_id, journey_instance_version);
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_identity_uq UNIQUE (id, journey_instance_id, receipt_digest);
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_version_uq UNIQUE (id, journey_instance_id, journey_instance_version, receipt_digest);
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_handoff_identity_uq UNIQUE (id, journey_instance_id, handoff_id, receipt_digest);
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_handoff_version_uq UNIQUE (id, journey_instance_id, handoff_id, handoff_version, receipt_digest);
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_one_handoff_version_uq UNIQUE (journey_instance_id, handoff_id, handoff_version);
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_digest_uq UNIQUE (receipt_digest);
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_edge_ck CHECK (edge_id ~ '^J-(0[1-9]|1[0-2])-E[0-9]{2}[A-Z]?$');
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_kind_ck CHECK (receipt_kind IN ('INSTANCE_STARTED','HANDOFF_REQUESTED','HANDOFF_ACKNOWLEDGED','HANDOFF_DECLINED','HANDOFF_ESCALATED','HANDOFF_EXPIRED','HANDOFF_CANCELLED','HANDOFF_SUPERSEDED','OUTCOME_RECORDED'));
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_sequence_ck CHECK (journey_instance_version = sequence AND sequence > 0 AND ((sequence = 1 AND receipt_kind = 'INSTANCE_STARTED' AND prior_receipt_id IS NULL AND prior_receipt_digest IS NULL AND prior_owner_binding_digest IS NULL AND prior_instance_state IS NULL AND prior_due_at IS NULL) OR (sequence > 1 AND prior_receipt_id IS NOT NULL AND prior_receipt_digest IS NOT NULL AND prior_owner_binding_digest IS NOT NULL AND prior_instance_state IS NOT NULL AND prior_due_at IS NOT NULL)));
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_handoff_ck CHECK ((handoff_id IS NULL AND handoff_version IS NULL AND prior_handoff_state IS NULL AND resulting_handoff_state IS NULL) OR (handoff_id IS NOT NULL AND handoff_version > 0 AND resulting_handoff_state IN ('PENDING_ACK','ACKNOWLEDGED','DECLINED','EXPIRED','CANCELLED','SUPERSEDED')));
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_instance_state_ck CHECK (resulting_instance_state IN ('ACTIVE','WAITING_ACK','BLOCKED','RECONCILIATION_REQUIRED','COMPLETED','CANCELLED','EXPIRED','REJECTED') AND (prior_instance_state IS NULL OR prior_instance_state IN ('ACTIVE','WAITING_ACK','BLOCKED','RECONCILIATION_REQUIRED','COMPLETED','CANCELLED','EXPIRED','REJECTED')));
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_escalation_ck CHECK (escalation_state IN ('NOT_DUE','DUE','ESCALATED','RESOLVED'));
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_outbox_ck CHECK ((receipt_kind IN ('HANDOFF_CANCELLED','HANDOFF_SUPERSEDED') AND outbox_event_id IS NULL) OR (receipt_kind NOT IN ('HANDOFF_CANCELLED','HANDOFF_SUPERSEDED') AND outbox_event_id IS NOT NULL));
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_kind_shape_ck CHECK ((receipt_kind = 'INSTANCE_STARTED' AND handoff_id IS NULL AND handoff_version IS NULL AND resulting_instance_state = 'ACTIVE' AND escalation_state = 'NOT_DUE' AND next_owner_binding_digest IS NULL) OR (receipt_kind = 'HANDOFF_REQUESTED' AND handoff_id IS NOT NULL AND handoff_version = 1 AND prior_handoff_state IS NULL AND resulting_handoff_state = 'PENDING_ACK' AND resulting_instance_state = 'WAITING_ACK' AND escalation_state = 'NOT_DUE' AND next_owner_binding_digest IS NOT NULL) OR (receipt_kind = 'HANDOFF_ACKNOWLEDGED' AND handoff_id IS NOT NULL AND prior_handoff_state = 'PENDING_ACK' AND resulting_handoff_state = 'ACKNOWLEDGED' AND resulting_instance_state = 'ACTIVE' AND escalation_state = 'RESOLVED' AND next_owner_binding_digest IS NULL) OR (receipt_kind = 'HANDOFF_DECLINED' AND handoff_id IS NOT NULL AND prior_handoff_state = 'PENDING_ACK' AND resulting_handoff_state = 'DECLINED' AND resulting_instance_state IN ('ACTIVE','BLOCKED') AND escalation_state = 'RESOLVED') OR (receipt_kind = 'HANDOFF_ESCALATED' AND handoff_id IS NOT NULL AND prior_handoff_state = 'PENDING_ACK' AND resulting_handoff_state = 'PENDING_ACK' AND prior_instance_state = 'WAITING_ACK' AND resulting_instance_state = 'WAITING_ACK' AND escalation_state IN ('DUE','ESCALATED') AND next_owner_binding_digest IS NOT NULL) OR (receipt_kind = 'HANDOFF_EXPIRED' AND handoff_id IS NOT NULL AND prior_handoff_state = 'PENDING_ACK' AND resulting_handoff_state = 'EXPIRED' AND resulting_instance_state IN ('ACTIVE','BLOCKED','EXPIRED') AND escalation_state = 'RESOLVED') OR (receipt_kind = 'HANDOFF_CANCELLED' AND handoff_id IS NOT NULL AND prior_handoff_state = 'PENDING_ACK' AND resulting_handoff_state = 'CANCELLED' AND escalation_state = 'RESOLVED') OR (receipt_kind = 'HANDOFF_SUPERSEDED' AND handoff_id IS NOT NULL AND prior_handoff_state = 'PENDING_ACK' AND resulting_handoff_state = 'SUPERSEDED' AND escalation_state = 'RESOLVED') OR (receipt_kind = 'OUTCOME_RECORDED' AND handoff_id IS NULL AND handoff_version IS NULL AND prior_handoff_state IS NULL AND resulting_handoff_state IS NULL));
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_digest_ck CHECK ((prior_receipt_digest IS NULL OR ops.is_lower_sha256(prior_receipt_digest)) AND ops.is_lower_sha256(subject_digest) AND (prior_owner_binding_digest IS NULL OR ops.is_lower_sha256(prior_owner_binding_digest)) AND ops.is_lower_sha256(current_owner_binding_digest) AND (next_owner_binding_digest IS NULL OR ops.is_lower_sha256(next_owner_binding_digest)) AND ops.is_lower_sha256(effect_digest) AND ops.is_lower_sha256(receipt_digest));
REVOKE ALL ON ops.journey_transition_receipts FROM PUBLIC;
REVOKE ALL ON ops.journey_transition_receipts FROM gurine_workflow_worker;
REVOKE ALL ON ops.journey_transition_receipts FROM gurine_control_api;
REVOKE ALL ON ops.journey_transition_receipts FROM gurine_analysis_worker;
REVOKE ALL ON ops.journey_transition_receipts FROM gurine_public_projector;
REVOKE ALL ON ops.journey_transition_receipts FROM gurine_notification_worker;
REVOKE ALL ON ops.journey_transition_receipts FROM gurine_submission_api;
REVOKE ALL ON ops.journey_transition_receipts FROM gurine_auditor;
GRANT SELECT ON ops.journey_transition_receipts TO gurine_control_api;
GRANT SELECT ON ops.journey_transition_receipts TO gurine_workflow_worker;
GRANT SELECT ON ops.journey_transition_receipts TO gurine_scheduler;
GRANT SELECT ON ops.journey_transition_receipts TO gurine_auditor;
CREATE TRIGGER ops_journey_transition_receipts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.journey_transition_receipts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_legal_conflict_fk FOREIGN KEY (legal_conflict_snapshot_id, legal_approver_user_id, legal_conflict_snapshot_digest) REFERENCES editorial.conflict_snapshots (id, subject_actor_id, snapshot_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.capability_activation_decisions ADD CONSTRAINT capability_activation_decisions_operational_conflict_fk FOREIGN KEY (operational_conflict_snapshot_id, operational_approver_user_id, operational_conflict_snapshot_digest) REFERENCES editorial.conflict_snapshots (id, subject_actor_id, snapshot_sha256) ON DELETE RESTRICT;
ALTER TABLE ops.retention_execution_receipts ADD CONSTRAINT retention_execution_receipts_approval_type_fk FOREIGN KEY (approval_decision_id, retention_request_id, request_type) REFERENCES ops.retention_request_decisions (id, retention_request_id, request_type) ON DELETE RESTRICT;
ALTER TABLE ops.restoration_suppressions ADD CONSTRAINT restoration_suppressions_decision_type_fk FOREIGN KEY (source_decision_id, source_retention_request_id, request_type) REFERENCES ops.retention_request_decisions (id, retention_request_id, request_type) ON DELETE RESTRICT;
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_anchor_fk FOREIGN KEY (target_anchor_id, target_anchor_digest) REFERENCES ops.legal_hold_target_anchors (id, anchor_digest) ON DELETE RESTRICT;
ALTER TABLE editorial.legal_hold_releases ADD CONSTRAINT legal_hold_releases_conflict_fk FOREIGN KEY (conflict_snapshot_id, released_by_user_id, conflict_target_type, conflict_target_id, conflict_target_version, conflict_target_digest, conflict_snapshot_digest, conflict_evaluation_state, conflict_valid_until) REFERENCES editorial.conflict_snapshots (id, subject_actor_id, target_type, target_id, target_version, target_digest, snapshot_sha256, evaluation_state, valid_until) ON DELETE RESTRICT;
ALTER TABLE editorial.publication_gate_decisions ADD CONSTRAINT publication_gate_decisions_publisher_conflict_fk FOREIGN KEY (publisher_conflict_snapshot_id, publisher_user_id, publisher_conflict_target_type, publisher_conflict_target_id, publisher_conflict_target_version, publisher_conflict_target_digest, publisher_conflict_snapshot_digest, publisher_conflict_evaluation_state, publisher_conflict_valid_until) REFERENCES editorial.conflict_snapshots (id, subject_actor_id, target_type, target_id, target_version, target_digest, snapshot_sha256, evaluation_state, valid_until) ON DELETE RESTRICT;
ALTER TABLE editorial.publication_gate_review_bindings ADD CONSTRAINT publication_gate_review_bindings_conflict_fk FOREIGN KEY (conflict_snapshot_id, reviewer_user_id, conflict_target_type, conflict_target_id, conflict_target_version, conflict_target_digest, conflict_snapshot_digest, conflict_evaluation_state, conflict_valid_until) REFERENCES editorial.conflict_snapshots (id, subject_actor_id, target_type, target_id, target_version, target_digest, snapshot_sha256, evaluation_state, valid_until) ON DELETE RESTRICT;
ALTER TABLE ops.sli_window_receipts ADD CONSTRAINT sli_window_receipts_pair_fk FOREIGN KEY (paired_receipt_id, sli_id, definition_version, environment, scope_digest, paired_window_kind, paired_window_sequence, paired_receipt_digest) REFERENCES ops.sli_window_receipts (id, sli_id, definition_version, environment, scope_digest, window_kind, window_sequence, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_last_receipt_fk FOREIGN KEY (last_receipt_id, id, version, last_receipt_digest) REFERENCES ops.journey_transition_receipts (id, journey_instance_id, journey_instance_version, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.journey_instances ADD CONSTRAINT journey_instances_active_handoff_fk FOREIGN KEY (active_handoff_id, id, active_handoff_generation, active_handoff_state) REFERENCES ops.journey_handoffs (id, journey_instance_id, generation, state) ON DELETE RESTRICT;
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_instance_fk FOREIGN KEY (journey_instance_id, journey_code) REFERENCES ops.journey_instances (id, journey_code) ON DELETE RESTRICT;
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_request_receipt_fk FOREIGN KEY (request_receipt_id, journey_instance_id, id, request_receipt_digest) REFERENCES ops.journey_transition_receipts (id, journey_instance_id, handoff_id, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.journey_handoffs ADD CONSTRAINT journey_handoffs_last_receipt_fk FOREIGN KEY (last_receipt_id, journey_instance_id, id, version, last_receipt_digest) REFERENCES ops.journey_transition_receipts (id, journey_instance_id, handoff_id, handoff_version, receipt_digest) ON DELETE RESTRICT;
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_instance_fk FOREIGN KEY (journey_instance_id) REFERENCES ops.journey_instances (id) ON DELETE RESTRICT;
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_handoff_fk FOREIGN KEY (handoff_id, journey_instance_id) REFERENCES ops.journey_handoffs (id, journey_instance_id) ON DELETE RESTRICT;
ALTER TABLE ops.journey_transition_receipts ADD CONSTRAINT journey_transition_receipts_prior_fk FOREIGN KEY (prior_receipt_id, journey_instance_id, prior_receipt_digest) REFERENCES ops.journey_transition_receipts (id, journey_instance_id, receipt_digest) ON DELETE RESTRICT;
CREATE TRIGGER ops_guard_journey_instance_update_v1_trg BEFORE UPDATE OR DELETE ON ops.journey_instances FOR EACH ROW EXECUTE FUNCTION ops.guard_journey_instance_update_v1();
CREATE TRIGGER ops_guard_journey_handoff_update_v1_trg BEFORE UPDATE OR DELETE ON ops.journey_handoffs FOR EACH ROW EXECUTE FUNCTION ops.guard_journey_handoff_update_v1();
CREATE CONSTRAINT TRIGGER ops_check_journey_instance_head_v1_trg AFTER INSERT OR UPDATE ON ops.journey_instances DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ops.check_journey_instance_head_v1();
CREATE CONSTRAINT TRIGGER ops_check_journey_instance_transition_v1_trg AFTER INSERT OR UPDATE ON ops.journey_instances DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ops.check_journey_instance_transition_v1();
CREATE CONSTRAINT TRIGGER ops_check_journey_handoff_binding_v1_trg AFTER INSERT OR UPDATE ON ops.journey_handoffs DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ops.check_journey_handoff_binding_v1();
CREATE CONSTRAINT TRIGGER ops_check_journey_handoff_head_v1_trg AFTER INSERT OR UPDATE ON ops.journey_handoffs DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ops.check_journey_handoff_head_v1();
CREATE CONSTRAINT TRIGGER ops_check_journey_receipt_chain_v1_trg AFTER INSERT ON ops.journey_transition_receipts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ops.check_journey_receipt_chain_v1();
CREATE CONSTRAINT TRIGGER ops_check_journey_receipt_parent_versions_v1_trg AFTER INSERT ON ops.journey_transition_receipts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ops.check_journey_receipt_parent_versions_v1();
CREATE CONSTRAINT TRIGGER ops_check_journey_receipt_state_owner_v1_trg AFTER INSERT ON ops.journey_transition_receipts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ops.check_journey_receipt_state_owner_v1();
CREATE INDEX legal_hold_target_anchors_target_idx ON ops.legal_hold_target_anchors (target_kind, target_id, target_version DESC, id DESC);
CREATE INDEX legal_hold_target_anchors_case_idx ON ops.legal_hold_target_anchors (case_id, target_kind, id) WHERE case_id IS NOT NULL;
CREATE INDEX legal_hold_target_anchors_privacy_idx ON ops.legal_hold_target_anchors (privacy_request_id, id) WHERE privacy_request_id IS NOT NULL;
CREATE INDEX legal_hold_target_anchors_subject_idx ON ops.legal_hold_target_anchors (communication_subject_id, id) WHERE communication_subject_id IS NOT NULL;
CREATE INDEX conflict_declarations_lookup_idx ON editorial.conflict_declarations (subject_actor_id, target_type, target_id, conflict_type, source_class, source_authority_type, source_authority_id, declaration_sequence DESC, id DESC);
CREATE INDEX conflict_declarations_expiry_idx ON editorial.conflict_declarations (expires_at, id) WHERE expires_at IS NOT NULL;
CREATE INDEX conflict_snapshots_target_idx ON editorial.conflict_snapshots (target_type, target_id, target_version, candidate_role, evaluated_at DESC, id DESC);
CREATE INDEX conflict_snapshots_subject_idx ON editorial.conflict_snapshots (subject_actor_id, evaluated_at DESC, id DESC);
CREATE INDEX capability_activation_decisions_latest_idx ON ops.capability_activation_decisions (capability_id, environment, decision_version DESC, id DESC);
CREATE INDEX capability_activation_decisions_effective_idx ON ops.capability_activation_decisions (capability_class, environment, effective_at DESC, id) WHERE legal_state = 'APPROVED';
CREATE INDEX capability_activation_decisions_expiry_idx ON ops.capability_activation_decisions (expires_at, id) WHERE expires_at IS NOT NULL;
CREATE INDEX capability_activation_evidence_order_idx ON ops.capability_activation_evidence (decision_id, ordinal);
CREATE INDEX capability_activation_evidence_expiry_idx ON ops.capability_activation_evidence (expires_at, decision_id, ordinal) WHERE expires_at IS NOT NULL;
CREATE INDEX record_class_schedules_current_idx ON ops.record_class_schedules (record_class, effective_at DESC, revision DESC, id DESC);
CREATE INDEX record_class_schedules_review_idx ON ops.record_class_schedules (review_expires_at, record_class, revision);
CREATE INDEX retention_request_decisions_timeline_idx ON ops.retention_request_decisions (retention_request_id, decision_version ASC, id ASC);
CREATE INDEX retention_request_decisions_state_idx ON ops.retention_request_decisions (state, decided_at DESC, id DESC);
CREATE INDEX retention_execution_receipts_request_idx ON ops.retention_execution_receipts (retention_request_id, completed_at DESC, execution_generation DESC, id DESC);
CREATE INDEX retention_execution_receipts_approval_idx ON ops.retention_execution_receipts (approval_decision_id, execution_generation DESC);
CREATE INDEX restoration_suppressions_subject_idx ON ops.restoration_suppressions (subject_ref_hash, effective_at DESC, id DESC);
CREATE INDEX restoration_suppressions_scope_idx ON ops.restoration_suppressions (subject_scope_digest, effective_at DESC, id DESC);
CREATE INDEX restoration_suppressions_expiry_idx ON ops.restoration_suppressions (expires_at, id) WHERE expires_at IS NOT NULL;
CREATE INDEX legal_hold_releases_timeline_idx ON editorial.legal_hold_releases (hold_id, release_sequence ASC, id ASC);
CREATE INDEX legal_hold_releases_case_idx ON editorial.legal_hold_releases (case_id, released_at DESC, id DESC);
CREATE INDEX legal_hold_releases_anchor_idx ON editorial.legal_hold_releases (target_anchor_id, release_sequence ASC, id ASC);
CREATE INDEX incident_events_timeline_idx ON ops.incident_events (incident_id, event_sequence ASC, id ASC);
CREATE INDEX incident_events_state_time_idx ON ops.incident_events (state, occurred_at DESC, id DESC);
CREATE INDEX incident_events_next_update_idx ON ops.incident_events (next_update_at, severity, incident_id) WHERE next_update_at IS NOT NULL;
CREATE INDEX publication_gate_decisions_case_idx ON editorial.publication_gate_decisions (case_id, evaluated_at DESC, id DESC);
CREATE INDEX publication_gate_decisions_snapshot_idx ON editorial.publication_gate_decisions (review_snapshot_id, evaluated_at DESC, id DESC);
CREATE INDEX publication_gate_decisions_expiry_idx ON editorial.publication_gate_decisions (earliest_expiry_at, case_id, id);
CREATE INDEX publication_gate_claim_evidence_order_idx ON editorial.publication_gate_claim_evidence (decision_id, ordinal);
CREATE INDEX publication_gate_claim_evidence_claim_idx ON editorial.publication_gate_claim_evidence (claim_id, claim_version, decision_id);
CREATE INDEX publication_gate_claim_evidence_evidence_idx ON editorial.publication_gate_claim_evidence (evidence_id, evidence_version, decision_id);
CREATE INDEX publication_gate_claim_evidence_source_idx ON editorial.publication_gate_claim_evidence (source_ref_type, source_ref_id, source_version, decision_id);
CREATE INDEX publication_gate_review_bindings_order_idx ON editorial.publication_gate_review_bindings (decision_id, ordinal);
CREATE INDEX publication_gate_review_bindings_reviewer_idx ON editorial.publication_gate_review_bindings (reviewer_user_id, decision_id);
CREATE INDEX publication_gate_blockers_order_idx ON editorial.publication_gate_blockers (decision_id, ordinal);
CREATE INDEX publication_gate_blockers_code_idx ON editorial.publication_gate_blockers (blocker_code, created_at DESC, decision_id);
CREATE INDEX publication_gate_blockers_subject_idx ON editorial.publication_gate_blockers (subject_type, subject_id, created_at DESC, decision_id);
CREATE INDEX sli_window_receipts_latest_idx ON ops.sli_window_receipts (sli_id, definition_version, environment, scope_digest, window_kind, window_end DESC, window_sequence DESC, id DESC);
CREATE INDEX sli_window_receipts_capability_idx ON ops.sli_window_receipts (capability_id, window_end DESC, sli_id, id DESC);
CREATE INDEX sli_window_receipts_incident_idx ON ops.sli_window_receipts (incident_id, window_end DESC, id DESC) WHERE incident_id IS NOT NULL;
CREATE INDEX sli_window_receipts_gap_idx ON ops.sli_window_receipts (window_end DESC, sli_id, id DESC) WHERE telemetry_state = 'GAP';
CREATE INDEX journey_instances_owner_due_idx ON ops.journey_instances (current_owner_function, due_at ASC, id ASC) WHERE state NOT IN ('COMPLETED','CANCELLED','EXPIRED','REJECTED');
CREATE INDEX journey_instances_root_idx ON ops.journey_instances (root_object_kind, root_object_id, root_object_version DESC, id DESC);
CREATE INDEX journey_instances_handoff_idx ON ops.journey_instances (active_handoff_id, active_handoff_generation) WHERE active_handoff_id IS NOT NULL;
CREATE INDEX journey_instances_receipt_fk_idx ON ops.journey_instances (last_receipt_id, id, version, last_receipt_digest);
CREATE INDEX journey_instances_active_handoff_fk_idx ON ops.journey_instances (active_handoff_id, id, active_handoff_generation, active_handoff_state) WHERE active_handoff_id IS NOT NULL;
CREATE INDEX journey_handoffs_receiver_due_idx ON ops.journey_handoffs (receiver_function, due_at ASC, journey_instance_id ASC) WHERE state = 'PENDING_ACK';
CREATE INDEX journey_handoffs_instance_history_idx ON ops.journey_handoffs (journey_instance_id, generation DESC, id DESC);
CREATE INDEX journey_handoffs_subject_idx ON ops.journey_handoffs (subject_kind, subject_id, subject_version DESC, id DESC);
CREATE INDEX journey_handoffs_instance_fk_idx ON ops.journey_handoffs (journey_instance_id, journey_code);
CREATE INDEX journey_handoffs_request_receipt_fk_idx ON ops.journey_handoffs (request_receipt_id, journey_instance_id, id, request_receipt_digest);
CREATE INDEX journey_handoffs_last_receipt_fk_idx ON ops.journey_handoffs (last_receipt_id, journey_instance_id, id, version, last_receipt_digest);
CREATE INDEX journey_handoffs_pending_due_idx ON ops.journey_handoffs (due_at ASC, journey_instance_id ASC, id ASC) WHERE state = 'PENDING_ACK';
CREATE INDEX journey_transition_receipts_instance_idx ON ops.journey_transition_receipts (journey_instance_id, sequence DESC, id DESC);
CREATE INDEX journey_transition_receipts_handoff_idx ON ops.journey_transition_receipts (handoff_id, sequence DESC, id DESC) WHERE handoff_id IS NOT NULL;
CREATE INDEX journey_transition_receipts_time_idx ON ops.journey_transition_receipts (occurred_at DESC, id DESC);
CREATE INDEX journey_transition_receipts_handoff_fk_idx ON ops.journey_transition_receipts (handoff_id, journey_instance_id) WHERE handoff_id IS NOT NULL;
CREATE INDEX journey_transition_receipts_prior_fk_idx ON ops.journey_transition_receipts (prior_receipt_id, journey_instance_id, prior_receipt_digest) WHERE prior_receipt_id IS NOT NULL;
CREATE INDEX journey_transition_receipts_audit_fk_idx ON ops.journey_transition_receipts (audit_event_id);
CREATE INDEX journey_transition_receipts_outbox_fk_idx ON ops.journey_transition_receipts (outbox_event_id);
COMMIT;
