BEGIN;
-- Source-derived 0026 physical registry: 27 relations.
-- Existing 0001..0024 migrations are byte-immutable; this migration is additive.
SET LOCAL search_path = pg_catalog, public;
CREATE OR REPLACE FUNCTION ops.action_approval_detail_binding_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.action_approval_detail_binding_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_detail_binding_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_binding_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.action_approval_binding_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_binding_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_hypothesis_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_hypothesis_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_hypothesis_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_claim_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_claim_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_claim_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_task_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_task_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_task_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_comparable_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_comparable_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_comparable_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_communication_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_communication_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_communication_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_publication_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_publication_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_publication_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_retraction_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_retraction_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_retraction_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_rule_activation_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_rule_activation_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_rule_activation_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_role_grant_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_role_grant_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_role_grant_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_kill_switch_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_kill_switch_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_kill_switch_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_communication_authorization_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_communication_authorization_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_communication_authorization_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_asset_rights_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_asset_rights_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_asset_rights_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_retention_schedule_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_retention_schedule_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_retention_schedule_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_funding_disclosure_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_funding_disclosure_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_funding_disclosure_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_capability_activation_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_capability_activation_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_capability_activation_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_response_policy_calendar_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_response_policy_calendar_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_response_policy_calendar_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_approval_commercial_control_detail_v1_is_valid(bytea) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND octet_length($1) > 0 $$;
ALTER FUNCTION ops.action_approval_commercial_control_detail_v1_is_valid(bytea) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_approval_commercial_control_detail_v1_is_valid(bytea) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_decision_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.action_decision_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_decision_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.action_decision_receipt_binding_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.action_decision_receipt_binding_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.action_decision_receipt_binding_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.safe_retry_proof_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.safe_retry_proof_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.safe_retry_proof_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.execution_binding_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.execution_binding_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.execution_binding_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.execution_receipt_payload_v1_is_valid(jsonb) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND jsonb_typeof($1) = 'object' $$;
ALTER FUNCTION ops.execution_receipt_payload_v1_is_valid(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.execution_receipt_payload_v1_is_valid(jsonb) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.text_array_is_sorted_unique_nonempty(text[]) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND cardinality($1) > 0 AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL) AND $1 = ARRAY(SELECT value FROM unnest($1) AS item(value) ORDER BY value COLLATE "C") $$;
ALTER FUNCTION ops.text_array_is_sorted_unique_nonempty(text[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.text_array_is_sorted_unique_nonempty(text[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.uuid_array_is_sorted_unique(uuid[]) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL) $$;
ALTER FUNCTION ops.uuid_array_is_sorted_unique(uuid[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.uuid_array_is_sorted_unique(uuid[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.sha256_text_array_is_sorted_unique(text[]) RETURNS boolean LANGUAGE SQL IMMUTABLE PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL AND cardinality($1) >= 0 AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL) AND $1 = ARRAY(SELECT value FROM unnest($1) AS item(value) ORDER BY value COLLATE "C") $$;
ALTER FUNCTION ops.sha256_text_array_is_sorted_unique(text[]) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.sha256_text_array_is_sorted_unique(text[]) FROM PUBLIC;
CREATE OR REPLACE FUNCTION ops.validate_action_approval_binding_at_commit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.validate_action_approval_binding_at_commit() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.validate_action_approval_detail_at_commit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.validate_action_approval_detail_at_commit() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.validate_action_assignment_at_commit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.validate_action_assignment_at_commit() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.validate_action_decision_at_commit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.validate_action_decision_at_commit() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.validate_action_quorum_at_commit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.validate_action_quorum_at_commit() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.validate_execution_generation_at_commit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.validate_execution_generation_at_commit() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.validate_execution_receipt_chain_at_commit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.validate_execution_receipt_chain_at_commit() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.validate_budget_transition_at_commit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.validate_budget_transition_at_commit() OWNER TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.validate_polymorphic_effect_source_at_commit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ BEGIN IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW; END $$;
ALTER FUNCTION ops.validate_polymorphic_effect_source_at_commit() OWNER TO gurine_migrator;
CREATE TABLE ops.action_proposals (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  action_kind text NOT NULL,
  origin_kind text NOT NULL,
  origin_id uuid NOT NULL,
  origin_version bigint NOT NULL,
  origin_digest char(64) NOT NULL,
  compensates_execution_id uuid,
  compensates_execution_state text,
  compensates_effect_digest char(64),
  compensates_execution_receipt_digest char(64),
  target_type text NOT NULL,
  target_id text NOT NULL,
  target_version bigint NOT NULL,
  target_digest char(64) NOT NULL,
  object_scope_digest char(64) NOT NULL,
  current_version bigint NOT NULL DEFAULT 1,
  aggregate_version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL,
  owner_user_id uuid NOT NULL,
  last_receipt_digest char(64) NOT NULL,
  last_audit_event_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_action_proposals_1 PRIMARY KEY (id)
);
ALTER TABLE ops.action_proposals OWNER TO gurine_migrator;
ALTER TABLE ops.action_proposals ADD CONSTRAINT action_proposals_id_current_version_key UNIQUE (id, current_version);
ALTER TABLE ops.action_proposals ADD CONSTRAINT action_proposals_action_kind_check CHECK (action_kind IN ('HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION','RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH','COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE','FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR','COMMERCIAL_CONTROL'));
ALTER TABLE ops.action_proposals ADD CONSTRAINT action_proposals_origin_kind_check CHECK (origin_kind IN ('HUMAN','AGENT_PROPOSAL','SYSTEM_EVENT','COMPENSATION'));
ALTER TABLE ops.action_proposals ADD CONSTRAINT action_proposals_compensation_check CHECK ((origin_kind = 'COMPENSATION' AND compensates_execution_id IS NOT NULL AND compensates_execution_state = 'SUCCEEDED' AND compensates_effect_digest ~ '^[0-9a-f]{64}$' AND compensates_execution_receipt_digest ~ '^[0-9a-f]{64}$') OR (origin_kind <> 'COMPENSATION' AND compensates_execution_id IS NULL AND compensates_execution_state IS NULL AND compensates_effect_digest IS NULL AND compensates_execution_receipt_digest IS NULL));
ALTER TABLE ops.action_proposals ADD CONSTRAINT action_proposals_target_type_check CHECK (target_type IN ('CASE','CLAIM','TASK','LINE_ITEM','COMMUNICATION_INTENT','PUBLICATION','RULE_VERSION','USER','KILL_SWITCH','COMMUNICATION_SUBJECT','ASSET','RECORD_CLASS','FUNDING_DISCLOSURE','CAPABILITY','BUSINESS_CALENDAR'));
ALTER TABLE ops.action_proposals ADD CONSTRAINT action_proposals_nonempty_target_check CHECK (length(btrim(target_id)) BETWEEN 1 AND 500);
ALTER TABLE ops.action_proposals ADD CONSTRAINT action_proposals_versions_check CHECK (origin_version > 0 AND target_version > 0 AND current_version > 0 AND aggregate_version > 0);
ALTER TABLE ops.action_proposals ADD CONSTRAINT action_proposals_digests_check CHECK (origin_digest ~ '^[0-9a-f]{64}$' AND target_digest ~ '^[0-9a-f]{64}$' AND object_scope_digest ~ '^[0-9a-f]{64}$' AND last_receipt_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_proposals ADD CONSTRAINT action_proposals_time_check CHECK (updated_at >= created_at);
REVOKE ALL ON ops.action_proposals FROM PUBLIC;
REVOKE ALL ON ops.action_proposals FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_proposals FROM gurine_control_api;
REVOKE ALL ON ops.action_proposals FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_proposals FROM gurine_public_projector;
REVOKE ALL ON ops.action_proposals FROM gurine_notification_worker;
REVOKE ALL ON ops.action_proposals FROM gurine_submission_api;
REVOKE ALL ON ops.action_proposals FROM gurine_auditor;
CREATE TRIGGER ops_action_proposals_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_proposals FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_proposal_versions (
  proposal_id uuid NOT NULL,
  version bigint NOT NULL,
  state text NOT NULL DEFAULT 'DRAFT',
  state_version bigint NOT NULL DEFAULT 1,
  payload_schema_version text NOT NULL DEFAULT 'action-payload.v1',
  payload_encrypted bytea NOT NULL,
  content_digest char(64) NOT NULL,
  rationale_encrypted bytea NOT NULL,
  rationale_digest char(64) NOT NULL,
  last_editor_id uuid NOT NULL,
  expires_at timestamptz NOT NULL,
  preview_id uuid,
  preview_digest char(64),
  preview_policy_digest char(64),
  preview_encrypted bytea,
  previewed_at timestamptz,
  previewed_by uuid,
  preview_receipt_digest char(64),
  preview_audit_event_id uuid,
  approval_binding jsonb,
  approval_binding_canonical bytea,
  approval_digest char(64),
  operation_id text,
  required_capability text,
  target_request_digest char(64),
  evidence_set_digest char(64),
  contrary_evidence_set_digest char(64),
  uncertainty_set_digest char(64),
  risk_assessment_digest char(64),
  policy_snapshot_digest char(64),
  conflict_snapshot_digest char(64),
  expected_effect_digest char(64),
  reversible boolean,
  quorum_plan_digest char(64),
  effect_idempotency_key_sha256 char(64),
  action_detail_kind text,
  action_detail jsonb,
  action_detail_canonical bytea,
  action_detail_digest char(64),
  quorum_policy_version text,
  not_before timestamptz,
  due_at timestamptz,
  submitted_at timestamptz,
  terminal_reason_code text,
  terminal_receipt_digest char(64),
  terminal_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_action_proposal_versions_1 PRIMARY KEY (proposal_id, version)
);
ALTER TABLE ops.action_proposal_versions OWNER TO gurine_migrator;
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_approval_binding_key UNIQUE (proposal_id, version, approval_digest);
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_detail_binding_key UNIQUE (proposal_id, version, action_detail_kind, action_detail_digest);
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_preview_id_key UNIQUE (preview_id);
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_state_check CHECK (state IN ('DRAFT','PENDING_QUORUM','APPROVED','REJECTED','CHANGES_REQUIRED','WITHDRAWN','EXPIRED','SUPERSEDED'));
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_positive_check CHECK (version > 0 AND state_version > 0);
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_schema_check CHECK (payload_schema_version = 'action-payload.v1');
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_envelope_check CHECK (octet_length(payload_encrypted) >= 32 AND octet_length(rationale_encrypted) >= 32);
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_content_digest_check CHECK (content_digest ~ '^[0-9a-f]{64}$' AND rationale_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_expiry_check CHECK (expires_at > created_at);
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_preview_all_or_none_check CHECK (num_nonnulls(preview_id,preview_digest,preview_policy_digest,preview_encrypted,previewed_at,previewed_by,preview_receipt_digest,preview_audit_event_id) IN (0,8));
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_preview_envelope_check CHECK (preview_encrypted IS NULL OR octet_length(preview_encrypted) >= 32);
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_preview_digest_check CHECK (preview_digest IS NULL OR (preview_digest ~ '^[0-9a-f]{64}$' AND preview_policy_digest ~ '^[0-9a-f]{64}$' AND preview_receipt_digest ~ '^[0-9a-f]{64}$'));
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_binding_all_or_none_check CHECK (num_nonnulls(approval_binding,approval_binding_canonical,approval_digest,operation_id,required_capability,target_request_digest,evidence_set_digest,contrary_evidence_set_digest,uncertainty_set_digest,risk_assessment_digest,policy_snapshot_digest,conflict_snapshot_digest,expected_effect_digest,reversible,quorum_plan_digest,effect_idempotency_key_sha256,action_detail_kind,action_detail,action_detail_canonical,action_detail_digest,quorum_policy_version,not_before,due_at,submitted_at) IN (0,24));
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_binding_json_check CHECK (approval_binding IS NULL OR (ops.action_approval_binding_v1_is_valid(approval_binding) AND convert_from(approval_binding_canonical,'UTF8')::jsonb = approval_binding));
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_binding_digest_check CHECK (approval_digest IS NULL OR (approval_digest = encode(extensions.digest(approval_binding_canonical,'sha256'),'hex') AND approval_digest ~ '^[0-9a-f]{64}$' AND target_request_digest ~ '^[0-9a-f]{64}$' AND evidence_set_digest ~ '^[0-9a-f]{64}$' AND contrary_evidence_set_digest ~ '^[0-9a-f]{64}$' AND uncertainty_set_digest ~ '^[0-9a-f]{64}$' AND risk_assessment_digest ~ '^[0-9a-f]{64}$' AND policy_snapshot_digest ~ '^[0-9a-f]{64}$' AND conflict_snapshot_digest ~ '^[0-9a-f]{64}$' AND expected_effect_digest ~ '^[0-9a-f]{64}$' AND quorum_plan_digest ~ '^[0-9a-f]{64}$' AND effect_idempotency_key_sha256 ~ '^[0-9a-f]{64}$' AND action_detail_digest = encode(extensions.digest(action_detail_canonical,'sha256'),'hex') AND action_detail_digest ~ '^[0-9a-f]{64}$' AND convert_from(action_detail_canonical,'UTF8')::jsonb = jsonb_build_object('actionDetailKind',action_detail_kind,'actionDetail',action_detail)));
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_binding_text_check CHECK (approval_binding IS NULL OR (length(btrim(operation_id)) BETWEEN 1 AND 128 AND length(btrim(required_capability)) BETWEEN 1 AND 128));
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_detail_kind_check CHECK (action_detail_kind IS NULL OR action_detail_kind IN ('HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION','RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH','COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE','FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR','COMMERCIAL_CONTROL'));
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_review_state_check CHECK (state IN ('DRAFT','WITHDRAWN','SUPERSEDED','EXPIRED') OR approval_binding IS NOT NULL);
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_pending_check CHECK (state <> 'PENDING_QUORUM' OR (preview_id IS NOT NULL AND approval_binding IS NOT NULL AND not_before <= due_at AND due_at <= expires_at));
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_terminal_check CHECK ((state IN ('APPROVED','REJECTED','CHANGES_REQUIRED','WITHDRAWN','EXPIRED','SUPERSEDED')) = (terminal_at IS NOT NULL));
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_terminal_receipt_check CHECK ((state IN ('APPROVED','REJECTED','CHANGES_REQUIRED','WITHDRAWN','EXPIRED','SUPERSEDED')) = (terminal_receipt_digest IS NOT NULL) AND (terminal_receipt_digest IS NULL OR terminal_receipt_digest ~ '^[0-9a-f]{64}$'));
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_time_check CHECK (updated_at >= created_at AND (previewed_at IS NULL OR previewed_at >= created_at) AND (submitted_at IS NULL OR (previewed_at IS NOT NULL AND submitted_at >= previewed_at)) AND (terminal_at IS NULL OR terminal_at >= created_at));
REVOKE ALL ON ops.action_proposal_versions FROM PUBLIC;
REVOKE ALL ON ops.action_proposal_versions FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_proposal_versions FROM gurine_control_api;
REVOKE ALL ON ops.action_proposal_versions FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_proposal_versions FROM gurine_public_projector;
REVOKE ALL ON ops.action_proposal_versions FROM gurine_notification_worker;
REVOKE ALL ON ops.action_proposal_versions FROM gurine_submission_api;
REVOKE ALL ON ops.action_proposal_versions FROM gurine_auditor;
CREATE TRIGGER ops_action_proposal_versions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_proposal_versions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_review_assignments (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  approval_digest char(64) NOT NULL,
  assignment_generation bigint NOT NULL DEFAULT 1,
  slot_id text NOT NULL,
  slot_ordinal smallint NOT NULL,
  required_capability text NOT NULL,
  approve_assurance text NOT NULL,
  allowed_role_codes text[] NOT NULL,
  reviewer_id uuid,
  reviewer_role_snapshot_digest char(64) NOT NULL,
  eligibility_snapshot_digest char(64) NOT NULL,
  conflict_snapshot_id uuid,
  conflict_snapshot_digest char(64) NOT NULL,
  conflict_target_type text NOT NULL DEFAULT 'ACTION_PROPOSAL',
  conflict_target_id uuid NOT NULL,
  conflict_target_version bigint NOT NULL,
  conflict_target_digest char(64) NOT NULL,
  conflict_evaluation_state text NOT NULL,
  conflict_valid_until timestamptz NOT NULL,
  excluded_actor_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  exclusion_set_digest char(64) NOT NULL,
  quorum_plan_digest char(64) NOT NULL,
  assignment_digest char(64) NOT NULL,
  state text NOT NULL DEFAULT 'ASSIGNED',
  version bigint NOT NULL DEFAULT 1,
  blocking_reason_code text,
  next_assignment_scan_at timestamptz,
  replacement_of_assignment_id uuid,
  assigned_by uuid NOT NULL,
  due_at timestamptz NOT NULL,
  claimed_at timestamptz,
  terminal_at timestamptz,
  terminal_reason_code text,
  last_receipt_digest char(64) NOT NULL,
  last_audit_event_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_action_review_assignments_1 PRIMARY KEY (id)
);
ALTER TABLE ops.action_review_assignments OWNER TO gurine_migrator;
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_decision_fk_key UNIQUE (id, proposal_id, proposal_version, approval_digest, version);
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_receipt_binding_key UNIQUE (id, proposal_id, proposal_version, approval_digest, version, assignment_generation, slot_id);
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_slot_generation_key UNIQUE (proposal_id, proposal_version, slot_id, assignment_generation);
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_actor_once_key UNIQUE (proposal_id, proposal_version, reviewer_id);
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_replacement_once_key UNIQUE (replacement_of_assignment_id);
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_state_check CHECK (state IN ('VACANT','ASSIGNED','IN_PROGRESS','COMPLETED','RECUSED','CANCELLED'));
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_positive_check CHECK (proposal_version > 0 AND assignment_generation > 0 AND slot_ordinal BETWEEN 1 AND 16 AND version > 0);
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_assurance_check CHECK (approve_assurance IN ('ACTIVE_SESSION','STEP_UP'));
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_roles_check CHECK (cardinality(allowed_role_codes) BETWEEN 1 AND 9 AND ops.text_array_is_sorted_unique_nonempty(allowed_role_codes));
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_nonempty_slot_check CHECK (length(btrim(slot_id)) BETWEEN 1 AND 100);
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_conflict_check CHECK (conflict_target_type = 'ACTION_PROPOSAL' AND conflict_target_id = proposal_id AND conflict_target_version = proposal_version AND ((state = 'VACANT' AND reviewer_id IS NULL AND conflict_snapshot_id IS NULL AND reviewer_role_snapshot_digest = 'a987005ba2dc00498702eea9d50ed59c6732bb825059d52b491be1a37a2fddd6' AND conflict_snapshot_digest = 'e78bfc84252d3d52a9005d38ed5e102e334240826621d6e5570ff3ce42b94b21' AND conflict_evaluation_state = 'UNAVAILABLE' AND blocking_reason_code = 'ACTION_QUORUM_UNAVAILABLE' AND next_assignment_scan_at IS NOT NULL) OR (state <> 'VACANT' AND reviewer_id IS NOT NULL AND conflict_snapshot_id IS NOT NULL AND conflict_evaluation_state IN ('CLEAR','DISCLOSURE_REQUIRED') AND conflict_valid_until >= due_at AND NOT (reviewer_id = ANY(excluded_actor_ids)) AND blocking_reason_code IS NULL AND next_assignment_scan_at IS NULL)));
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_exclusion_check CHECK (cardinality(excluded_actor_ids) BETWEEN 1 AND 64 AND ops.uuid_array_is_sorted_unique(excluded_actor_ids));
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_digests_check CHECK (approval_digest ~ '^[0-9a-f]{64}$' AND reviewer_role_snapshot_digest ~ '^[0-9a-f]{64}$' AND eligibility_snapshot_digest ~ '^[0-9a-f]{64}$' AND conflict_snapshot_digest ~ '^[0-9a-f]{64}$' AND conflict_target_digest ~ '^[0-9a-f]{64}$' AND exclusion_set_digest ~ '^[0-9a-f]{64}$' AND quorum_plan_digest ~ '^[0-9a-f]{64}$' AND assignment_digest ~ '^[0-9a-f]{64}$' AND last_receipt_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_claim_check CHECK ((state IN ('VACANT','ASSIGNED') AND claimed_at IS NULL) OR (state IN ('IN_PROGRESS','COMPLETED') AND claimed_at IS NOT NULL) OR state IN ('RECUSED','CANCELLED'));
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_terminal_check CHECK ((state IN ('COMPLETED','RECUSED','CANCELLED')) = (terminal_at IS NOT NULL));
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_terminal_reason_check CHECK ((state IN ('COMPLETED','RECUSED','CANCELLED')) = (terminal_reason_code IS NOT NULL));
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_time_check CHECK (due_at > created_at AND updated_at >= created_at AND (next_assignment_scan_at IS NULL OR next_assignment_scan_at >= created_at) AND (claimed_at IS NULL OR claimed_at >= created_at) AND (terminal_at IS NULL OR terminal_at >= created_at));
REVOKE ALL ON ops.action_review_assignments FROM PUBLIC;
REVOKE ALL ON ops.action_review_assignments FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_review_assignments FROM gurine_control_api;
REVOKE ALL ON ops.action_review_assignments FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_review_assignments FROM gurine_public_projector;
REVOKE ALL ON ops.action_review_assignments FROM gurine_notification_worker;
REVOKE ALL ON ops.action_review_assignments FROM gurine_submission_api;
REVOKE ALL ON ops.action_review_assignments FROM gurine_auditor;
CREATE TRIGGER ops_action_review_assignments_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_review_assignments FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_decisions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  record_kind text NOT NULL DEFAULT 'DECISION',
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  approval_digest char(64) NOT NULL,
  assignment_id uuid NOT NULL,
  assignment_version bigint NOT NULL,
  assignment_generation bigint NOT NULL,
  slot_kind text NOT NULL,
  actor_id uuid NOT NULL,
  asserted_required_capability text NOT NULL DEFAULT 'actions.review',
  assurance text NOT NULL,
  step_up_authorization_id uuid,
  step_up_authorization_digest char(64),
  step_up_authorization_receipt_digest char(64),
  step_up_authorization_receipt_canonical bytea,
  step_up_issue_ordinal bigint,
  step_up_issued_at timestamptz,
  step_up_expires_at timestamptz,
  actor_assertion_jti uuid NOT NULL,
  actor_action_digest char(64) NOT NULL,
  idempotency_key_sha256 char(64) NOT NULL,
  decision_kind text NOT NULL,
  withdrawn_decision_id uuid,
  withdrawn_decision_receipt_digest char(64),
  withdrawn_record_kind text,
  withdrawn_decision_kind text,
  reason_code text NOT NULL,
  reason text NOT NULL,
  reason_digest char(64) NOT NULL,
  decision_payload jsonb NOT NULL,
  decision_payload_canonical bytea NOT NULL,
  decision_receipt_binding jsonb NOT NULL,
  decision_receipt_binding_canonical bytea NOT NULL,
  conflict_snapshot_id uuid NOT NULL,
  conflict_snapshot_digest char(64) NOT NULL,
  conflict_target_type text NOT NULL DEFAULT 'ACTION_PROPOSAL',
  conflict_target_id uuid NOT NULL,
  conflict_target_version bigint NOT NULL,
  conflict_target_digest char(64) NOT NULL,
  conflict_evaluation_state text NOT NULL,
  conflict_valid_until timestamptz NOT NULL,
  conflict_declaration_id uuid,
  quorum_snapshot_digest char(64) NOT NULL,
  counts_toward_quorum boolean NOT NULL DEFAULT FALSE,
  quorum_satisfied_after boolean NOT NULL DEFAULT FALSE,
  resulting_proposal_state text NOT NULL,
  change_task_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  execution_id uuid,
  receipt_digest char(64) NOT NULL,
  request_id uuid NOT NULL,
  audit_event_id uuid NOT NULL,
  decided_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL,
  CONSTRAINT g_pk_ops_action_decisions_1 PRIMARY KEY (id)
);
ALTER TABLE ops.action_decisions OWNER TO gurine_migrator;
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_receipt_digest_key UNIQUE (receipt_digest);
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_governance_binding_key UNIQUE (id, proposal_id, proposal_version, approval_digest, receipt_digest);
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_exact_actor_binding_key UNIQUE (id, proposal_id, proposal_version, approval_digest, receipt_digest, actor_id, decision_kind, conflict_snapshot_digest);
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_paid_rejection_binding_key UNIQUE (id, proposal_id, proposal_version, approval_digest, receipt_digest, actor_id, decision_kind, conflict_snapshot_digest, record_kind, resulting_proposal_state, decided_at);
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_withdrawal_target_key UNIQUE (id, proposal_id, proposal_version, approval_digest, receipt_digest, actor_id, assignment_id, assignment_generation, slot_kind, record_kind, decision_kind);
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_record_kind_check CHECK (record_kind IN ('DECISION','APPROVAL_WITHDRAWAL'));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_kind_check CHECK ((record_kind = 'DECISION' AND decision_kind IN ('APPROVE','REJECT','CHANGES_REQUIRED','RECUSE')) OR (record_kind = 'APPROVAL_WITHDRAWAL' AND decision_kind = 'APPROVAL_WITHDRAWN'));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_assurance_check CHECK (assurance IN ('ACTIVE_SESSION','STEP_UP'));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_step_up_check CHECK ((assurance = 'STEP_UP' AND num_nonnulls(step_up_authorization_id,step_up_authorization_digest,step_up_authorization_receipt_digest,step_up_authorization_receipt_canonical,step_up_issue_ordinal,step_up_issued_at,step_up_expires_at) = 7 AND step_up_issue_ordinal > 0 AND step_up_authorization_receipt_digest = encode(extensions.digest(step_up_authorization_receipt_canonical,'sha256'),'hex') AND step_up_issued_at <= decided_at AND decided_at < step_up_expires_at AND step_up_expires_at <= step_up_issued_at + interval '5 minutes 5 seconds') OR (assurance = 'ACTIVE_SESSION' AND num_nonnulls(step_up_authorization_id,step_up_authorization_digest,step_up_authorization_receipt_digest,step_up_authorization_receipt_canonical,step_up_issue_ordinal,step_up_issued_at,step_up_expires_at) = 0));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_capability_check CHECK (asserted_required_capability = 'actions.review');
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_reason_check CHECK (length(btrim(reason_code)) BETWEEN 1 AND 100 AND length(btrim(reason)) BETWEEN 1 AND 4000 AND reason_digest = encode(extensions.digest(convert_to(reason,'UTF8'),'sha256'),'hex'));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_payload_check CHECK (ops.action_decision_v1_is_valid(decision_payload) AND convert_from(decision_payload_canonical,'UTF8')::jsonb = decision_payload);
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_receipt_binding_check CHECK (ops.action_decision_receipt_binding_v1_is_valid(decision_receipt_binding) AND convert_from(decision_receipt_binding_canonical,'UTF8')::jsonb = decision_receipt_binding AND receipt_digest = encode(extensions.digest(decision_receipt_binding_canonical,'sha256'),'hex'));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_conflict_check CHECK (conflict_target_type = 'ACTION_PROPOSAL' AND conflict_target_id = proposal_id AND conflict_target_version = proposal_version AND conflict_target_digest = approval_digest AND conflict_valid_until >= decided_at AND ((record_kind = 'DECISION' AND decision_kind = 'RECUSE' AND conflict_evaluation_state IN ('RECUSE_REQUIRED','INDEPENDENT_REVIEW_REQUIRED','BLOCKED_UNKNOWN')) OR (record_kind = 'DECISION' AND decision_kind <> 'RECUSE' AND conflict_evaluation_state IN ('CLEAR','DISCLOSURE_REQUIRED') AND conflict_declaration_id IS NULL) OR (record_kind = 'APPROVAL_WITHDRAWAL' AND conflict_evaluation_state IN ('CLEAR','DISCLOSURE_REQUIRED','RECUSE_REQUIRED','INDEPENDENT_REVIEW_REQUIRED','BLOCKED_UNKNOWN'))));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_digest_check CHECK (approval_digest ~ '^[0-9a-f]{64}$' AND actor_action_digest ~ '^[0-9a-f]{64}$' AND idempotency_key_sha256 ~ '^[0-9a-f]{64}$' AND reason_digest ~ '^[0-9a-f]{64}$' AND conflict_snapshot_digest ~ '^[0-9a-f]{64}$' AND conflict_target_digest ~ '^[0-9a-f]{64}$' AND quorum_snapshot_digest ~ '^[0-9a-f]{64}$' AND receipt_digest ~ '^[0-9a-f]{64}$' AND (step_up_authorization_digest IS NULL OR (step_up_authorization_digest ~ '^[0-9a-f]{64}$' AND step_up_authorization_receipt_digest ~ '^[0-9a-f]{64}$')) AND (withdrawn_decision_receipt_digest IS NULL OR withdrawn_decision_receipt_digest ~ '^[0-9a-f]{64}$'));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_count_check CHECK (counts_toward_quorum = (record_kind = 'DECISION' AND decision_kind = 'APPROVE'));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_withdrawal_check CHECK ((record_kind = 'DECISION' AND num_nonnulls(withdrawn_decision_id,withdrawn_decision_receipt_digest,withdrawn_record_kind,withdrawn_decision_kind) = 0) OR (record_kind = 'APPROVAL_WITHDRAWAL' AND num_nonnulls(withdrawn_decision_id,withdrawn_decision_receipt_digest,withdrawn_record_kind,withdrawn_decision_kind) = 4 AND withdrawn_record_kind = 'DECISION' AND withdrawn_decision_kind = 'APPROVE' AND counts_toward_quorum = false AND quorum_satisfied_after = false AND resulting_proposal_state = 'PENDING_QUORUM' AND execution_id IS NULL AND cardinality(change_task_ids) = 0));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_state_check CHECK (resulting_proposal_state IN ('PENDING_QUORUM','APPROVED','REJECTED','CHANGES_REQUIRED'));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_result_check CHECK ((decision_kind = 'REJECT' AND resulting_proposal_state = 'REJECTED') OR (decision_kind = 'CHANGES_REQUIRED' AND resulting_proposal_state = 'CHANGES_REQUIRED') OR (decision_kind IN ('RECUSE','APPROVAL_WITHDRAWN') AND resulting_proposal_state = 'PENDING_QUORUM') OR (decision_kind = 'APPROVE' AND resulting_proposal_state IN ('PENDING_QUORUM','APPROVED')));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_quorum_execution_check CHECK ((quorum_satisfied_after AND decision_kind = 'APPROVE' AND resulting_proposal_state = 'APPROVED') = (execution_id IS NOT NULL));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_quorum_result_check CHECK (quorum_satisfied_after = (decision_kind = 'APPROVE' AND resulting_proposal_state = 'APPROVED'));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_change_tasks_check CHECK (((decision_kind = 'CHANGES_REQUIRED' AND cardinality(change_task_ids) BETWEEN 1 AND 100) OR (decision_kind <> 'CHANGES_REQUIRED' AND cardinality(change_task_ids) = 0)) AND ops.uuid_array_is_sorted_unique(change_task_ids));
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_assignment_version_check CHECK (proposal_version > 0 AND assignment_version > 0 AND assignment_generation > 0 AND length(btrim(slot_kind)) BETWEEN 1 AND 100);
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_time_check CHECK (created_at = decided_at);
REVOKE ALL ON ops.action_decisions FROM PUBLIC;
REVOKE ALL ON ops.action_decisions FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_decisions FROM gurine_control_api;
REVOKE ALL ON ops.action_decisions FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_decisions FROM gurine_public_projector;
REVOKE ALL ON ops.action_decisions FROM gurine_notification_worker;
REVOKE ALL ON ops.action_decisions FROM gurine_submission_api;
REVOKE ALL ON ops.action_decisions FROM gurine_auditor;
CREATE TRIGGER ops_action_decisions_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_decisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.in_flight_effects (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  effect_type text NOT NULL,
  effect_key_digest char(64) NOT NULL,
  action_kind text,
  action_proposal_id uuid,
  action_proposal_version bigint,
  approval_digest char(64),
  agent_provider_turn_id uuid,
  predecessor_effect_id uuid,
  predecessor_relationship text NOT NULL,
  current_generation bigint NOT NULL DEFAULT 1,
  state text NOT NULL,
  state_version bigint NOT NULL DEFAULT 1,
  cancellation_generation bigint NOT NULL DEFAULT 0,
  dispatch_attempt_count smallint NOT NULL DEFAULT 0,
  run_after timestamptz NOT NULL DEFAULT clock_timestamp(),
  provider_config_id uuid,
  provider_config_version bigint,
  provider_configuration_digest char(64) NOT NULL,
  provider_idempotency_key_sha256 char(64) NOT NULL,
  policy_digest char(64) NOT NULL,
  kill_switch_digest char(64) NOT NULL,
  budget_digest char(64) NOT NULL,
  rights_digest char(64) NOT NULL,
  consent_digest char(64) NOT NULL,
  suppression_digest char(64) NOT NULL,
  conflict_digest char(64) NOT NULL,
  activation_digest char(64) NOT NULL,
  quorum_plan_digest char(64) NOT NULL,
  rendered_bytes_digest char(64) NOT NULL,
  fence_reason_code text,
  cancel_requested_at timestamptz,
  cancel_reason_digest char(64),
  reconciliation_attempt_count integer NOT NULL DEFAULT 0,
  next_reconcile_at timestamptz,
  incident_id uuid,
  last_receipt_sequence bigint NOT NULL DEFAULT 1,
  last_receipt_digest char(64) NOT NULL,
  terminal_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_in_flight_effects_1 PRIMARY KEY (id)
);
ALTER TABLE ops.in_flight_effects OWNER TO gurine_migrator;
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_business_key UNIQUE (effect_key_digest);
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_provider_key UNIQUE (provider_config_id, provider_idempotency_key_sha256);
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_generation_reference_key UNIQUE (id, current_generation);
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_paid_decision_cycle_key UNIQUE (id, action_proposal_id, action_proposal_version, approval_digest, current_generation);
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_receipt_pointer_key UNIQUE (id, last_receipt_sequence, last_receipt_digest);
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_compensation_binding_key UNIQUE (id, state, effect_key_digest, last_receipt_digest);
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_type_check CHECK (effect_type IN ('ACTION_EXECUTION','AGENT_PROVIDER_TURN'));
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_source_check CHECK ((effect_type = 'ACTION_EXECUTION' AND action_kind IS NOT NULL AND action_proposal_id IS NOT NULL AND action_proposal_version IS NOT NULL AND approval_digest IS NOT NULL AND agent_provider_turn_id IS NULL) OR (effect_type = 'AGENT_PROVIDER_TURN' AND action_kind IS NULL AND action_proposal_id IS NULL AND action_proposal_version IS NULL AND approval_digest IS NULL AND agent_provider_turn_id IS NOT NULL));
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_action_kind_check CHECK (action_kind IS NULL OR action_kind IN ('HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION','RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH','COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE','FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR','COMMERCIAL_CONTROL'));
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_predecessor_check CHECK ((predecessor_relationship = 'NONE' AND predecessor_effect_id IS NULL) OR (predecessor_relationship IN ('COMPENSATES','SUPERSEDES') AND predecessor_effect_id IS NOT NULL AND predecessor_effect_id <> id));
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_state_check CHECK (state IN ('POLICY_BLOCKED','QUEUED','RUNNING','RETRYABLE_FAILED','CANCEL_REQUESTED','RECONCILIATION_REQUIRED','SUCCEEDED','PARTIALLY_SUCCEEDED','PERMANENT_FAILED','CANCELLED','EXPIRED'));
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_positive_check CHECK (current_generation > 0 AND state_version > 0 AND cancellation_generation >= 0 AND dispatch_attempt_count BETWEEN 0 AND 3 AND last_receipt_sequence > 0);
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_provider_pair_check CHECK ((provider_config_id IS NULL AND provider_config_version IS NULL AND provider_configuration_digest = '8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde' AND provider_idempotency_key_sha256 = '36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74') OR (provider_config_id IS NOT NULL AND provider_config_version > 0 AND provider_configuration_digest <> '8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde' AND provider_idempotency_key_sha256 <> '36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74'));
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_digest_check CHECK (effect_key_digest ~ '^[0-9a-f]{64}$' AND (approval_digest IS NULL OR approval_digest ~ '^[0-9a-f]{64}$') AND provider_configuration_digest ~ '^[0-9a-f]{64}$' AND provider_idempotency_key_sha256 ~ '^[0-9a-f]{64}$' AND policy_digest ~ '^[0-9a-f]{64}$' AND kill_switch_digest ~ '^[0-9a-f]{64}$' AND budget_digest ~ '^[0-9a-f]{64}$' AND rights_digest ~ '^[0-9a-f]{64}$' AND consent_digest ~ '^[0-9a-f]{64}$' AND suppression_digest ~ '^[0-9a-f]{64}$' AND conflict_digest ~ '^[0-9a-f]{64}$' AND activation_digest ~ '^[0-9a-f]{64}$' AND quorum_plan_digest ~ '^[0-9a-f]{64}$' AND rendered_bytes_digest ~ '^[0-9a-f]{64}$' AND (cancel_reason_digest IS NULL OR cancel_reason_digest ~ '^[0-9a-f]{64}$') AND last_receipt_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_policy_block_check CHECK ((state = 'POLICY_BLOCKED' AND fence_reason_code IS NOT NULL) OR (state <> 'POLICY_BLOCKED' AND fence_reason_code IS NULL));
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_cancel_check CHECK ((state IN ('CANCEL_REQUESTED','CANCELLED') AND cancel_requested_at IS NOT NULL AND cancel_reason_digest IS NOT NULL AND cancellation_generation > 0) OR (state NOT IN ('CANCEL_REQUESTED','CANCELLED') AND cancel_requested_at IS NULL AND cancel_reason_digest IS NULL));
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_reconcile_check CHECK (reconciliation_attempt_count BETWEEN 0 AND 32 AND ((state = 'RECONCILIATION_REQUIRED' AND next_reconcile_at IS NOT NULL) OR (state <> 'RECONCILIATION_REQUIRED' AND next_reconcile_at IS NULL)));
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_terminal_check CHECK ((state IN ('POLICY_BLOCKED','SUCCEEDED','PARTIALLY_SUCCEEDED','PERMANENT_FAILED','CANCELLED','EXPIRED')) = (terminal_at IS NOT NULL));
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_time_check CHECK (run_after >= created_at AND updated_at >= created_at AND (terminal_at IS NULL OR terminal_at >= created_at));
REVOKE ALL ON ops.in_flight_effects FROM PUBLIC;
REVOKE ALL ON ops.in_flight_effects FROM gurine_workflow_worker;
REVOKE ALL ON ops.in_flight_effects FROM gurine_control_api;
REVOKE ALL ON ops.in_flight_effects FROM gurine_analysis_worker;
REVOKE ALL ON ops.in_flight_effects FROM gurine_public_projector;
REVOKE ALL ON ops.in_flight_effects FROM gurine_notification_worker;
REVOKE ALL ON ops.in_flight_effects FROM gurine_submission_api;
REVOKE ALL ON ops.in_flight_effects FROM gurine_auditor;
CREATE TRIGGER ops_in_flight_effects_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.in_flight_effects FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.budget_reservations (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  reservation_key_digest char(64) NOT NULL,
  reservation_digest char(64) NOT NULL,
  reservation_source_kind text NOT NULL,
  effect_id uuid NOT NULL,
  effect_generation bigint NOT NULL,
  job_id uuid,
  attempt integer NOT NULL,
  deployment_environment text NOT NULL,
  case_id uuid NOT NULL,
  provider_candidate_id text NOT NULL,
  provider_config_id uuid NOT NULL,
  provider_config_version bigint NOT NULL,
  provider_configuration_digest char(64) NOT NULL,
  pricing_version text NOT NULL,
  reserved_amount numeric(18,6) NOT NULL,
  currency char(3) NOT NULL,
  ledger_scope_digest char(64) NOT NULL,
  ledger_cell_count smallint NOT NULL DEFAULT 6,
  state text NOT NULL DEFAULT 'RESERVED',
  version bigint NOT NULL DEFAULT 1,
  settled_amount numeric(18,6),
  exposure_amount numeric(18,6),
  provider_usage_digest char(64),
  billed_cost_digest char(64),
  no_bill_proof_digest char(64),
  reconciliation_reason_code text,
  reconciliation_evidence_digest char(64),
  incident_id uuid,
  cost_event_id uuid,
  last_transition_sequence bigint NOT NULL DEFAULT 1,
  last_transition_id uuid NOT NULL,
  last_transition_digest char(64) NOT NULL,
  expires_at timestamptz NOT NULL,
  terminal_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_budget_reservations_1 PRIMARY KEY (id)
);
ALTER TABLE ops.budget_reservations OWNER TO gurine_migrator;
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_identity_key UNIQUE (job_id, attempt, provider_candidate_id, pricing_version);
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_key_digest_key UNIQUE (reservation_key_digest);
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_digest_key UNIQUE (reservation_digest);
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_id_digest_key UNIQUE (id, reservation_digest);
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_effect_candidate_key UNIQUE (effect_id, effect_generation, provider_candidate_id, pricing_version);
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_cost_event_key UNIQUE (cost_event_id);
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_transition_pointer_key UNIQUE (id, last_transition_sequence, last_transition_id, last_transition_digest);
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_positive_check CHECK (effect_generation > 0 AND attempt > 0 AND version > 0 AND last_transition_sequence > 0);
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_source_check CHECK ((reservation_source_kind = 'ACTION_EXECUTION' AND job_id IS NULL AND attempt = effect_generation) OR (reservation_source_kind = 'AGENT_PROVIDER_TURN' AND job_id IS NOT NULL));
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_environment_check CHECK (deployment_environment IN ('DEVELOPMENT','TEST','STAGING','PRODUCTION'));
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_pricing_check CHECK (length(btrim(pricing_version)) BETWEEN 1 AND 200);
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_candidate_check CHECK (length(btrim(provider_candidate_id)) BETWEEN 1 AND 500);
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_amount_check CHECK (reserved_amount > 0 AND (settled_amount IS NULL OR settled_amount >= 0) AND (exposure_amount IS NULL OR exposure_amount >= 0));
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_currency_check CHECK (currency ~ '^[A-Z]{3}$');
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_state_check CHECK (state IN ('RESERVED','SETTLED','RELEASED','RECONCILIATION_REQUIRED'));
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_cell_count_check CHECK (ledger_cell_count = 6);
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_digest_check CHECK (reservation_key_digest ~ '^[0-9a-f]{64}$' AND reservation_digest ~ '^[0-9a-f]{64}$' AND provider_configuration_digest ~ '^[0-9a-f]{64}$' AND ledger_scope_digest ~ '^[0-9a-f]{64}$' AND last_transition_digest ~ '^[0-9a-f]{64}$' AND (provider_usage_digest IS NULL OR provider_usage_digest ~ '^[0-9a-f]{64}$') AND (billed_cost_digest IS NULL OR billed_cost_digest ~ '^[0-9a-f]{64}$') AND (no_bill_proof_digest IS NULL OR no_bill_proof_digest ~ '^[0-9a-f]{64}$') AND (reconciliation_evidence_digest IS NULL OR reconciliation_evidence_digest ~ '^[0-9a-f]{64}$'));
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_settled_check CHECK (state <> 'SETTLED' OR (settled_amount IS NOT NULL AND provider_usage_digest IS NOT NULL AND billed_cost_digest IS NOT NULL AND cost_event_id IS NOT NULL AND terminal_at IS NOT NULL));
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_overage_check CHECK (settled_amount IS NULL OR settled_amount <= reserved_amount OR incident_id IS NOT NULL);
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_released_check CHECK (state <> 'RELEASED' OR (settled_amount IS NULL AND no_bill_proof_digest IS NOT NULL AND terminal_at IS NOT NULL));
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_reconciliation_check CHECK (state <> 'RECONCILIATION_REQUIRED' OR (exposure_amount IS NOT NULL AND reconciliation_reason_code IS NOT NULL AND reconciliation_evidence_digest IS NOT NULL AND incident_id IS NOT NULL AND terminal_at IS NULL));
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_terminal_check CHECK ((state IN ('SETTLED','RELEASED')) = (terminal_at IS NOT NULL));
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_time_check CHECK (expires_at > created_at AND updated_at >= created_at AND (terminal_at IS NULL OR terminal_at >= created_at));
REVOKE ALL ON ops.budget_reservations FROM PUBLIC;
REVOKE ALL ON ops.budget_reservations FROM gurine_workflow_worker;
REVOKE ALL ON ops.budget_reservations FROM gurine_control_api;
REVOKE ALL ON ops.budget_reservations FROM gurine_analysis_worker;
REVOKE ALL ON ops.budget_reservations FROM gurine_public_projector;
REVOKE ALL ON ops.budget_reservations FROM gurine_notification_worker;
REVOKE ALL ON ops.budget_reservations FROM gurine_submission_api;
REVOKE ALL ON ops.budget_reservations FROM gurine_auditor;
CREATE TRIGGER ops_budget_reservations_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.budget_reservations FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.budget_reservation_ledger_entries (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  reservation_id uuid NOT NULL,
  transition_id uuid NOT NULL,
  transition_sequence bigint NOT NULL,
  entry_ordinal smallint NOT NULL,
  entry_kind text NOT NULL,
  budget_limit_id uuid NOT NULL,
  budget_limit_version bigint NOT NULL,
  ledger_scope_kind text NOT NULL,
  ledger_scope_id text NOT NULL,
  window_kind text NOT NULL,
  window_start timestamptz NOT NULL,
  window_end timestamptz NOT NULL,
  ledger_key_digest char(64) NOT NULL,
  limit_amount numeric(18,6) NOT NULL,
  currency char(3) NOT NULL,
  reserved_delta numeric(18,6) NOT NULL,
  settled_delta numeric(18,6) NOT NULL,
  reserved_balance_after numeric(18,6) NOT NULL,
  settled_balance_after numeric(18,6) NOT NULL,
  available_after numeric(18,6) NOT NULL,
  reservation_state_after text NOT NULL,
  transition_digest char(64) NOT NULL,
  receipt_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_id uuid NOT NULL,
  occurred_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_budget_reservation_ledger_entries_1 PRIMARY KEY (id)
);
ALTER TABLE ops.budget_reservation_ledger_entries OWNER TO gurine_migrator;
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_transition_cell_key UNIQUE (reservation_id, transition_sequence, budget_limit_id, window_kind);
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_transition_ordinal_key UNIQUE (transition_id, entry_ordinal);
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_receipt_cell_key UNIQUE (receipt_digest, entry_ordinal);
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_positive_check CHECK (transition_sequence > 0 AND entry_ordinal BETWEEN 1 AND 6 AND budget_limit_version > 0);
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_entry_kind_check CHECK (entry_kind IN ('RESERVE','SETTLE','RELEASE','RECONCILIATION_HOLD'));
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_scope_check CHECK (ledger_scope_kind IN ('ENVIRONMENT','PROVIDER','CASE') AND length(btrim(ledger_scope_id)) BETWEEN 1 AND 500);
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_window_check CHECK (window_kind IN ('DAY','MONTH') AND window_end > window_start);
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_currency_check CHECK (currency ~ '^[A-Z]{3}$');
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_amount_check CHECK (limit_amount >= 0 AND reserved_balance_after >= 0 AND settled_balance_after >= 0 AND available_after = limit_amount - settled_balance_after - reserved_balance_after);
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_delta_check CHECK ((entry_kind = 'RESERVE' AND reserved_delta > 0 AND settled_delta = 0) OR (entry_kind = 'SETTLE' AND reserved_delta < 0 AND settled_delta >= 0) OR (entry_kind = 'RELEASE' AND reserved_delta < 0 AND settled_delta = 0) OR (entry_kind = 'RECONCILIATION_HOLD' AND reserved_delta = 0 AND settled_delta = 0));
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_state_check CHECK (reservation_state_after IN ('RESERVED','SETTLED','RELEASED','RECONCILIATION_REQUIRED'));
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_kind_state_check CHECK ((entry_kind = 'RESERVE' AND reservation_state_after = 'RESERVED') OR (entry_kind = 'SETTLE' AND reservation_state_after = 'SETTLED') OR (entry_kind = 'RELEASE' AND reservation_state_after = 'RELEASED') OR (entry_kind = 'RECONCILIATION_HOLD' AND reservation_state_after = 'RECONCILIATION_REQUIRED'));
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_digest_check CHECK (ledger_key_digest ~ '^[0-9a-f]{64}$' AND transition_digest ~ '^[0-9a-f]{64}$' AND receipt_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_time_check CHECK (occurred_at <= created_at + interval '5 seconds');
REVOKE ALL ON ops.budget_reservation_ledger_entries FROM PUBLIC;
REVOKE ALL ON ops.budget_reservation_ledger_entries FROM gurine_workflow_worker;
REVOKE ALL ON ops.budget_reservation_ledger_entries FROM gurine_control_api;
REVOKE ALL ON ops.budget_reservation_ledger_entries FROM gurine_analysis_worker;
REVOKE ALL ON ops.budget_reservation_ledger_entries FROM gurine_public_projector;
REVOKE ALL ON ops.budget_reservation_ledger_entries FROM gurine_notification_worker;
REVOKE ALL ON ops.budget_reservation_ledger_entries FROM gurine_submission_api;
REVOKE ALL ON ops.budget_reservation_ledger_entries FROM gurine_auditor;
CREATE TRIGGER ops_budget_reservation_ledger_entries_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.budget_reservation_ledger_entries FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.execution_authorizations (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  execution_id uuid NOT NULL,
  generation bigint NOT NULL,
  authorization_kind text NOT NULL,
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  action_kind text NOT NULL,
  approval_digest char(64) NOT NULL,
  counted_decision_ids uuid[] NOT NULL,
  counted_decision_receipt_digests text[] NOT NULL,
  counted_decision_set_digest char(64) NOT NULL,
  terminal_decision_id uuid NOT NULL,
  terminal_decision_receipt_digest char(64) NOT NULL,
  executor_id text NOT NULL,
  transport text NOT NULL,
  required_capability text NOT NULL,
  target_request_schema_version text NOT NULL,
  target_request_encrypted bytea NOT NULL,
  target_request_sha256 char(64) NOT NULL,
  rendered_bytes_digest char(64) NOT NULL,
  effect_boundary text NOT NULL,
  provider_config_id uuid,
  provider_config_version bigint,
  provider_configuration_digest char(64) NOT NULL,
  provider_idempotency_key_sha256 char(64) NOT NULL,
  cost_class text NOT NULL,
  budget_reservation_id uuid,
  budget_reservation_digest char(64) NOT NULL,
  cancellation_generation bigint NOT NULL DEFAULT 0,
  command_idempotency_key_sha256 char(64) NOT NULL,
  execution_binding jsonb NOT NULL,
  execution_binding_canonical bytea NOT NULL,
  execution_digest char(64) NOT NULL,
  retry_of_generation bigint,
  safe_retry_proof jsonb,
  safe_retry_proof_canonical bytea,
  safe_retry_proof_digest char(64),
  retry_reason_code text,
  retry_reason text,
  retry_reason_digest char(64),
  requested_by_actor_id uuid,
  request_id uuid NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_id uuid NOT NULL,
  authorized_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL,
  CONSTRAINT g_pk_ops_execution_authorizations_1 PRIMARY KEY (execution_id, generation)
);
ALTER TABLE ops.execution_authorizations OWNER TO gurine_migrator;
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_row_id_key UNIQUE (id);
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_digest_key UNIQUE (execution_digest);
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_cross_migration_binding_key UNIQUE (execution_id, generation, proposal_id, proposal_version, approval_digest, counted_decision_set_digest, execution_digest);
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_attempt_binding_key UNIQUE (execution_id, generation, target_request_sha256, rendered_bytes_digest, provider_config_id, provider_config_version, provider_configuration_digest, provider_idempotency_key_sha256, budget_reservation_id, budget_reservation_digest);
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_positive_check CHECK (generation > 0 AND cancellation_generation >= 0);
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_kind_check CHECK (authorization_kind IN ('INITIAL_APPROVAL','SAFE_RETRY'));
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_action_kind_check CHECK (action_kind IN ('HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION','PUBLICATION','RETRACTION','RULE_ACTIVATION','ROLE_GRANT','KILL_SWITCH','COMMUNICATION_AUTHORIZATION','ASSET_RIGHTS_DECISION','RETENTION_SCHEDULE','FUNDING_DISCLOSURE','CAPABILITY_ACTIVATION','RESPONSE_POLICY_CALENDAR','COMMERCIAL_CONTROL'));
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_transport_check CHECK (transport IN ('BASE_APPLICATION_COMMAND','PRIVATE_APPLICATION_COMMAND'));
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_effect_boundary_check CHECK (effect_boundary IN ('DATABASE_ONLY','PROVIDER'));
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_provider_check CHECK ((effect_boundary = 'PROVIDER' AND provider_config_id IS NOT NULL AND provider_config_version > 0 AND provider_configuration_digest <> '8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde' AND provider_idempotency_key_sha256 <> '36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74') OR (effect_boundary = 'DATABASE_ONLY' AND provider_config_id IS NULL AND provider_config_version IS NULL AND provider_configuration_digest = '8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde' AND provider_idempotency_key_sha256 = '36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74'));
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_cost_check CHECK ((cost_class = 'NO_PAID_EGRESS' AND budget_reservation_id IS NULL AND budget_reservation_digest = 'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde') OR (cost_class = 'PAID_EGRESS' AND budget_reservation_id IS NOT NULL AND budget_reservation_digest <> 'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde'));
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_counted_set_check CHECK (cardinality(counted_decision_ids) = cardinality(counted_decision_receipt_digests) AND cardinality(counted_decision_ids) BETWEEN 1 AND 16 AND ops.uuid_array_is_sorted_unique(counted_decision_ids) AND ops.sha256_text_array_is_sorted_unique(counted_decision_receipt_digests));
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_binding_check CHECK (ops.execution_binding_v1_is_valid(execution_binding) AND convert_from(execution_binding_canonical,'UTF8')::jsonb = execution_binding AND execution_digest = encode(extensions.digest(execution_binding_canonical,'sha256'),'hex'));
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_digest_check CHECK (approval_digest ~ '^[0-9a-f]{64}$' AND terminal_decision_receipt_digest ~ '^[0-9a-f]{64}$' AND counted_decision_set_digest ~ '^[0-9a-f]{64}$' AND target_request_sha256 ~ '^[0-9a-f]{64}$' AND rendered_bytes_digest ~ '^[0-9a-f]{64}$' AND provider_configuration_digest ~ '^[0-9a-f]{64}$' AND provider_idempotency_key_sha256 ~ '^[0-9a-f]{64}$' AND budget_reservation_digest ~ '^[0-9a-f]{64}$' AND command_idempotency_key_sha256 ~ '^[0-9a-f]{64}$' AND execution_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_target_envelope_check CHECK (octet_length(target_request_encrypted) >= 32 AND length(btrim(target_request_schema_version)) BETWEEN 1 AND 100);
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_retry_check CHECK ((authorization_kind = 'INITIAL_APPROVAL' AND generation = 1 AND retry_of_generation IS NULL AND safe_retry_proof IS NULL AND safe_retry_proof_canonical IS NULL AND safe_retry_proof_digest IS NULL AND retry_reason_code IS NULL AND retry_reason IS NULL AND retry_reason_digest IS NULL AND requested_by_actor_id IS NULL) OR (authorization_kind = 'SAFE_RETRY' AND generation > 1 AND retry_of_generation = generation - 1 AND ops.safe_retry_proof_v1_is_valid(safe_retry_proof) AND convert_from(safe_retry_proof_canonical,'UTF8')::jsonb = safe_retry_proof AND safe_retry_proof_digest = encode(extensions.digest(safe_retry_proof_canonical,'sha256'),'hex') AND length(btrim(retry_reason_code)) BETWEEN 1 AND 100 AND length(btrim(retry_reason)) BETWEEN 1 AND 2000 AND retry_reason_digest = encode(extensions.digest(convert_to(retry_reason,'UTF8'),'sha256'),'hex') AND requested_by_actor_id IS NOT NULL));
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_expiry_check CHECK (expires_at > authorized_at);
REVOKE ALL ON ops.execution_authorizations FROM PUBLIC;
REVOKE ALL ON ops.execution_authorizations FROM gurine_workflow_worker;
REVOKE ALL ON ops.execution_authorizations FROM gurine_control_api;
REVOKE ALL ON ops.execution_authorizations FROM gurine_analysis_worker;
REVOKE ALL ON ops.execution_authorizations FROM gurine_public_projector;
REVOKE ALL ON ops.execution_authorizations FROM gurine_notification_worker;
REVOKE ALL ON ops.execution_authorizations FROM gurine_submission_api;
REVOKE ALL ON ops.execution_authorizations FROM gurine_auditor;
CREATE TRIGGER ops_execution_authorizations_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.execution_authorizations FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.execution_attempts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  execution_id uuid NOT NULL,
  generation bigint NOT NULL,
  attempt_state text NOT NULL DEFAULT 'QUEUED',
  state_version bigint NOT NULL DEFAULT 1,
  dispatch_ordinal smallint,
  run_after timestamptz NOT NULL DEFAULT clock_timestamp(),
  lease_owner text,
  lease_token uuid,
  lease_expires_at timestamptz,
  fencing_token bigint NOT NULL DEFAULT 0,
  target_request_sha256 char(64) NOT NULL,
  rendered_bytes_digest char(64) NOT NULL,
  provider_config_id uuid,
  provider_config_version bigint,
  provider_configuration_digest char(64) NOT NULL,
  provider_idempotency_key_sha256 char(64) NOT NULL,
  budget_reservation_id uuid,
  budget_reservation_digest char(64) NOT NULL,
  provider_acknowledgement_digest char(64),
  provider_lookup_receipt_digest char(64),
  terminal_proof_digest char(64),
  last_error_code text,
  last_error_detail_digest char(64),
  cancel_requested_at timestamptz,
  cancel_reason_digest char(64),
  reconciliation_attempt_count integer NOT NULL DEFAULT 0,
  next_reconcile_at timestamptz,
  incident_id uuid,
  actual_amount numeric(18,6),
  actual_currency char(3),
  last_receipt_sequence bigint NOT NULL DEFAULT 0,
  last_receipt_digest char(64),
  claimed_at timestamptz,
  dispatch_started_at timestamptz,
  provider_accepted_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_execution_attempts_1 PRIMARY KEY (id)
);
ALTER TABLE ops.execution_attempts OWNER TO gurine_migrator;
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_generation_key UNIQUE (execution_id, generation);
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_receipt_binding_key UNIQUE (id, execution_id, generation);
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_dispatch_ordinal_key UNIQUE (execution_id, dispatch_ordinal);
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_receipt_pointer_key UNIQUE (execution_id, last_receipt_sequence, last_receipt_digest);
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_state_check CHECK (attempt_state IN ('QUEUED','CLAIMED','DISPATCHING','PROVIDER_ACCEPTED','SUCCEEDED','PARTIALLY_SUCCEEDED','RETRYABLE_FAILED','PERMANENT_FAILED','CANCEL_REQUESTED','CANCELLED','RECONCILIATION_REQUIRED'));
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_positive_check CHECK (generation > 0 AND state_version > 0 AND fencing_token >= 0 AND last_receipt_sequence >= 0);
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_dispatch_limit_check CHECK (dispatch_ordinal IS NULL OR dispatch_ordinal BETWEEN 1 AND 3);
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_request_digest_check CHECK (target_request_sha256 ~ '^[0-9a-f]{64}$' AND rendered_bytes_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_provider_pair_check CHECK ((provider_config_id IS NULL AND provider_config_version IS NULL AND provider_configuration_digest = '8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde' AND provider_idempotency_key_sha256 = '36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74') OR (provider_config_id IS NOT NULL AND provider_config_version > 0 AND provider_configuration_digest <> '8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde' AND provider_idempotency_key_sha256 <> '36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74'));
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_optional_digest_check CHECK (provider_configuration_digest ~ '^[0-9a-f]{64}$' AND provider_idempotency_key_sha256 ~ '^[0-9a-f]{64}$' AND budget_reservation_digest ~ '^[0-9a-f]{64}$' AND (provider_acknowledgement_digest IS NULL OR provider_acknowledgement_digest ~ '^[0-9a-f]{64}$') AND (provider_lookup_receipt_digest IS NULL OR provider_lookup_receipt_digest ~ '^[0-9a-f]{64}$') AND (terminal_proof_digest IS NULL OR terminal_proof_digest ~ '^[0-9a-f]{64}$') AND (last_error_detail_digest IS NULL OR last_error_detail_digest ~ '^[0-9a-f]{64}$') AND (cancel_reason_digest IS NULL OR cancel_reason_digest ~ '^[0-9a-f]{64}$') AND (last_receipt_digest IS NULL OR last_receipt_digest ~ '^[0-9a-f]{64}$'));
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_lease_check CHECK (num_nonnulls(lease_owner,lease_token,lease_expires_at) IN (0,3) AND ((attempt_state IN ('CLAIMED','DISPATCHING')) = (lease_token IS NOT NULL)) AND (lease_token IS NULL OR fencing_token > 0));
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_dispatch_check CHECK ((dispatch_started_at IS NULL AND dispatch_ordinal IS NULL) OR (dispatch_started_at IS NOT NULL AND dispatch_ordinal IS NOT NULL));
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_actual_cost_check CHECK ((actual_amount IS NULL AND actual_currency IS NULL) OR (actual_amount IS NOT NULL AND actual_amount >= 0 AND actual_currency ~ '^[A-Z]{3}$'));
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_budget_check CHECK ((budget_reservation_id IS NULL AND budget_reservation_digest = 'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde') OR (budget_reservation_id IS NOT NULL AND budget_reservation_digest <> 'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde'));
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_terminal_check CHECK ((attempt_state IN ('SUCCEEDED','PARTIALLY_SUCCEEDED','PERMANENT_FAILED','CANCELLED')) = (completed_at IS NOT NULL));
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_cancel_check CHECK ((attempt_state IN ('CANCEL_REQUESTED','CANCELLED') AND cancel_requested_at IS NOT NULL AND cancel_reason_digest IS NOT NULL) OR (attempt_state NOT IN ('CANCEL_REQUESTED','CANCELLED') AND cancel_requested_at IS NULL AND cancel_reason_digest IS NULL));
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_reconcile_check CHECK (reconciliation_attempt_count BETWEEN 0 AND 32 AND ((attempt_state = 'RECONCILIATION_REQUIRED' AND next_reconcile_at IS NOT NULL) OR (attempt_state <> 'RECONCILIATION_REQUIRED' AND next_reconcile_at IS NULL)));
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_receipt_pointer_check CHECK ((last_receipt_sequence = 0 AND last_receipt_digest IS NULL) OR (last_receipt_sequence > 0 AND last_receipt_digest IS NOT NULL));
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_time_check CHECK (updated_at >= created_at AND run_after >= created_at AND (claimed_at IS NULL OR claimed_at >= created_at) AND (dispatch_started_at IS NULL OR (claimed_at IS NOT NULL AND dispatch_started_at >= claimed_at)) AND (provider_accepted_at IS NULL OR (dispatch_started_at IS NOT NULL AND provider_accepted_at >= dispatch_started_at)) AND (completed_at IS NULL OR completed_at >= created_at));
REVOKE ALL ON ops.execution_attempts FROM PUBLIC;
REVOKE ALL ON ops.execution_attempts FROM gurine_workflow_worker;
REVOKE ALL ON ops.execution_attempts FROM gurine_control_api;
REVOKE ALL ON ops.execution_attempts FROM gurine_analysis_worker;
REVOKE ALL ON ops.execution_attempts FROM gurine_public_projector;
REVOKE ALL ON ops.execution_attempts FROM gurine_notification_worker;
REVOKE ALL ON ops.execution_attempts FROM gurine_submission_api;
REVOKE ALL ON ops.execution_attempts FROM gurine_auditor;
CREATE TRIGGER ops_execution_attempts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.execution_attempts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.execution_receipts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  execution_id uuid NOT NULL,
  generation bigint NOT NULL,
  attempt_id uuid,
  receipt_sequence bigint NOT NULL,
  receipt_kind text NOT NULL,
  mutates_aggregate_state boolean NOT NULL,
  prior_aggregate_state text,
  aggregate_state text NOT NULL,
  aggregate_state_version bigint NOT NULL,
  prior_attempt_state text,
  attempt_state text,
  fencing_token bigint,
  cancellation_generation bigint NOT NULL DEFAULT 0,
  provider_acknowledgement_digest char(64),
  provider_observation_digest char(64),
  proof_kind text,
  proof_digest char(64),
  receipt_payload jsonb NOT NULL,
  receipt_payload_canonical bytea NOT NULL,
  actual_amount numeric(18,6),
  actual_currency char(3),
  cost_event_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  budget_reservation_id uuid,
  budget_reservation_digest char(64) NOT NULL,
  request_id uuid NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_id uuid,
  observed_at timestamptz NOT NULL,
  prior_receipt_digest char(64),
  receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT g_pk_ops_execution_receipts_1 PRIMARY KEY (id)
);
ALTER TABLE ops.execution_receipts OWNER TO gurine_migrator;
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_sequence_key UNIQUE (execution_id, receipt_sequence);
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_digest_key UNIQUE (receipt_digest);
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_chain_reference_key UNIQUE (execution_id, receipt_digest);
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_governance_binding_key UNIQUE (id, execution_id, generation, receipt_digest);
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_paid_terminal_binding_key UNIQUE (id, execution_id, generation, receipt_sequence, receipt_digest, receipt_kind, aggregate_state, mutates_aggregate_state);
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_paid_terminal_observation_key UNIQUE (id, execution_id, generation, receipt_sequence, receipt_digest, receipt_kind, aggregate_state, mutates_aggregate_state, observed_at);
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_sequence_check CHECK (generation > 0 AND receipt_sequence > 0 AND aggregate_state_version > 0 AND cancellation_generation >= 0 AND (fencing_token IS NULL OR fencing_token >= 0));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_kind_check CHECK (receipt_kind IN ('POLICY_BLOCKED','AUTHORIZATION_QUEUED','LEASE_CLAIMED','DISPATCH_STARTED','PROVIDER_ACCEPTED','EFFECT_SUCCEEDED','EFFECT_PARTIALLY_SUCCEEDED','EFFECT_RETRYABLE_FAILED','EFFECT_PERMANENT_FAILED','CANCEL_REQUESTED','CANCELLED','RECONCILIATION_REQUIRED','RECONCILIATION_OBSERVED','RETRY_AUTHORIZED','EXPIRED'));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_aggregate_state_check CHECK (aggregate_state IN ('POLICY_BLOCKED','QUEUED','RUNNING','RETRYABLE_FAILED','CANCEL_REQUESTED','RECONCILIATION_REQUIRED','SUCCEEDED','PARTIALLY_SUCCEEDED','PERMANENT_FAILED','CANCELLED','EXPIRED') AND (prior_aggregate_state IS NULL OR prior_aggregate_state IN ('POLICY_BLOCKED','QUEUED','RUNNING','RETRYABLE_FAILED','CANCEL_REQUESTED','RECONCILIATION_REQUIRED','SUCCEEDED','PARTIALLY_SUCCEEDED','PERMANENT_FAILED','CANCELLED','EXPIRED')));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_attempt_state_check CHECK (attempt_state IS NULL OR attempt_state IN ('QUEUED','CLAIMED','DISPATCHING','PROVIDER_ACCEPTED','SUCCEEDED','PARTIALLY_SUCCEEDED','RETRYABLE_FAILED','PERMANENT_FAILED','CANCEL_REQUESTED','CANCELLED','RECONCILIATION_REQUIRED'));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_attempt_pair_check CHECK ((attempt_id IS NULL) = (attempt_state IS NULL));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_chain_check CHECK ((receipt_sequence = 1 AND prior_receipt_digest IS NULL) OR (receipt_sequence > 1 AND prior_receipt_digest ~ '^[0-9a-f]{64}$'));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_digest_check CHECK (receipt_digest ~ '^[0-9a-f]{64}$' AND (provider_acknowledgement_digest IS NULL OR provider_acknowledgement_digest ~ '^[0-9a-f]{64}$') AND (provider_observation_digest IS NULL OR provider_observation_digest ~ '^[0-9a-f]{64}$') AND (proof_digest IS NULL OR proof_digest ~ '^[0-9a-f]{64}$'));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_proof_pair_check CHECK ((proof_kind IS NULL) = (proof_digest IS NULL));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_proof_kind_check CHECK (proof_kind IS NULL OR proof_kind IN ('NO_EGRESS','PROVIDER_ACCEPTANCE','PROVIDER_SUCCESS','DEFINITIVE_NOT_ACCEPTED','PROVIDER_PERMANENT_FAILURE','PROVIDER_CANCELLED','AUTHENTICATED_LOOKUP','BOUNDED_AMBIGUITY','POLICY_FENCE','AUTHORIZATION_EXPIRY'));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_payload_check CHECK (ops.execution_receipt_payload_v1_is_valid(receipt_payload) AND convert_from(receipt_payload_canonical,'UTF8')::jsonb = receipt_payload AND receipt_digest = encode(extensions.digest(receipt_payload_canonical,'sha256'),'hex'));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_cost_check CHECK ((actual_amount IS NULL AND actual_currency IS NULL) OR (actual_amount IS NOT NULL AND actual_amount >= 0 AND actual_currency ~ '^[A-Z]{3}$'));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_cost_event_check CHECK (cardinality(cost_event_ids) <= 64 AND ops.uuid_array_is_sorted_unique(cost_event_ids));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_budget_digest_check CHECK (budget_reservation_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_budget_pair_check CHECK ((budget_reservation_id IS NULL AND budget_reservation_digest = 'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde') OR (budget_reservation_id IS NOT NULL AND budget_reservation_digest <> 'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde'));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_outbox_check CHECK ((receipt_kind IN ('LEASE_CLAIMED','DISPATCH_STARTED','PROVIDER_ACCEPTED','RECONCILIATION_OBSERVED') AND outbox_id IS NULL) OR (receipt_kind NOT IN ('LEASE_CLAIMED','DISPATCH_STARTED','PROVIDER_ACCEPTED','RECONCILIATION_OBSERVED') AND outbox_id IS NOT NULL));
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_observed_check CHECK (observed_at <= created_at + interval '5 seconds');
REVOKE ALL ON ops.execution_receipts FROM PUBLIC;
REVOKE ALL ON ops.execution_receipts FROM gurine_workflow_worker;
REVOKE ALL ON ops.execution_receipts FROM gurine_control_api;
REVOKE ALL ON ops.execution_receipts FROM gurine_analysis_worker;
REVOKE ALL ON ops.execution_receipts FROM gurine_public_projector;
REVOKE ALL ON ops.execution_receipts FROM gurine_notification_worker;
REVOKE ALL ON ops.execution_receipts FROM gurine_submission_api;
REVOKE ALL ON ops.execution_receipts FROM gurine_auditor;
CREATE TRIGGER ops_execution_receipts_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.execution_receipts FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_hypothesis_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  case_id uuid NOT NULL,
  expected_case_version bigint NOT NULL,
  statement_digest char(64) NOT NULL,
  evidence_segment_set_digest char(64) NOT NULL,
  unknown_set_digest char(64) NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_hypothesis_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_hypothesis_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_hypothesis_details ADD CONSTRAINT aap_01_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_hypothesis_details ADD CONSTRAINT aap_01_kind_ck CHECK (detail_kind = 'HYPOTHESIS');
ALTER TABLE ops.action_approval_hypothesis_details ADD CONSTRAINT aap_01_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_hypothesis_details ADD CONSTRAINT aap_01_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND statement_digest ~ '^[0-9a-f]{64}$' AND evidence_segment_set_digest ~ '^[0-9a-f]{64}$' AND unknown_set_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_hypothesis_details ADD CONSTRAINT aap_01_scalar_ck CHECK ((expected_case_version > 0));
REVOKE ALL ON ops.action_approval_hypothesis_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_hypothesis_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_hypothesis_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_hypothesis_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_hypothesis_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_hypothesis_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_hypothesis_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_hypothesis_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_hypothesis_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_hypothesis_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_claim_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  case_id uuid NOT NULL,
  expected_case_version bigint NOT NULL,
  claim_type text NOT NULL,
  claim_text_digest char(64) NOT NULL,
  response_set_digest char(64) NOT NULL,
  limitation_set_digest char(64) NOT NULL,
  evidence_segment_set_digest char(64) NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_claim_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_claim_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_claim_details ADD CONSTRAINT aap_02_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_claim_details ADD CONSTRAINT aap_02_kind_ck CHECK (detail_kind = 'CLAIM');
ALTER TABLE ops.action_approval_claim_details ADD CONSTRAINT aap_02_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_claim_details ADD CONSTRAINT aap_02_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND claim_text_digest ~ '^[0-9a-f]{64}$' AND response_set_digest ~ '^[0-9a-f]{64}$' AND limitation_set_digest ~ '^[0-9a-f]{64}$' AND evidence_segment_set_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_claim_details ADD CONSTRAINT aap_02_scalar_ck CHECK ((expected_case_version > 0) AND (claim_type IN ('FACT','CALCULATION','INFERENCE','LIMITATION','OFFICIAL_OUTCOME')));
REVOKE ALL ON ops.action_approval_claim_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_claim_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_claim_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_claim_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_claim_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_claim_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_claim_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_claim_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_claim_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_claim_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_task_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  object_type text NOT NULL,
  object_id uuid NOT NULL,
  expected_object_version bigint NOT NULL,
  task_type text NOT NULL,
  title_digest char(64) NOT NULL,
  description_digest char(64) NOT NULL,
  priority text NOT NULL,
  assignee_user_id uuid NOT NULL,
  assignee_eligibility_digest char(64) NOT NULL,
  due_at timestamptz NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_task_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_task_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_task_details ADD CONSTRAINT aap_03_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_task_details ADD CONSTRAINT aap_03_kind_ck CHECK (detail_kind = 'TASK');
ALTER TABLE ops.action_approval_task_details ADD CONSTRAINT aap_03_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_task_details ADD CONSTRAINT aap_03_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND title_digest ~ '^[0-9a-f]{64}$' AND description_digest ~ '^[0-9a-f]{64}$' AND assignee_eligibility_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_task_details ADD CONSTRAINT aap_03_scalar_ck CHECK ((object_type IN ('CASE','SIGNAL','EVIDENCE','CLAIM','RESPONSE_REQUEST','RESPONSE_APPEAL','INCIDENT','ACTION_PROPOSAL','SOURCE','RULE','PRIVACY_REQUEST','LEGAL_HOLD')) AND (expected_object_version > 0) AND (task_type IN ('INVESTIGATION','REVIEW','RESPONSE_FOLLOW_UP','EVIDENCE_VERIFICATION','INCIDENT_REMEDIATION','POSTMORTEM_ACTION','PRIVACY_REQUEST','LEGAL_HOLD_REVIEW','OTHER')) AND (priority IN ('LOW','NORMAL','HIGH','URGENT')));
REVOKE ALL ON ops.action_approval_task_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_task_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_task_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_task_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_task_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_task_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_task_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_task_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_task_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_task_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_comparable_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  case_id uuid NOT NULL,
  expected_case_version bigint NOT NULL,
  target_line_item_id uuid NOT NULL,
  target_line_item_version bigint NOT NULL,
  target_line_item_digest char(64) NOT NULL,
  candidate_line_item_id uuid NOT NULL,
  candidate_line_item_version bigint NOT NULL,
  candidate_line_item_digest char(64) NOT NULL,
  comparison_basis_digest char(64) NOT NULL,
  compatibility_kind text NOT NULL,
  include_reason_digest char(64) NOT NULL,
  evidence_segment_set_digest char(64) NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_comparable_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_comparable_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_comparable_details ADD CONSTRAINT aap_04_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_comparable_details ADD CONSTRAINT aap_04_kind_ck CHECK (detail_kind = 'COMPARABLE');
ALTER TABLE ops.action_approval_comparable_details ADD CONSTRAINT aap_04_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_comparable_details ADD CONSTRAINT aap_04_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND target_line_item_digest ~ '^[0-9a-f]{64}$' AND candidate_line_item_digest ~ '^[0-9a-f]{64}$' AND comparison_basis_digest ~ '^[0-9a-f]{64}$' AND include_reason_digest ~ '^[0-9a-f]{64}$' AND evidence_segment_set_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_comparable_details ADD CONSTRAINT aap_04_scalar_ck CHECK ((expected_case_version > 0) AND (target_line_item_version > 0) AND (candidate_line_item_version > 0) AND (compatibility_kind IN ('COMPATIBLE','PARTIAL','INCOMPATIBLE','UNKNOWN')));
REVOKE ALL ON ops.action_approval_comparable_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_comparable_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_comparable_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_comparable_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_comparable_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_comparable_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_comparable_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_comparable_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_comparable_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_comparable_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_communication_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  communication_intent_id uuid NOT NULL,
  communication_intent_version bigint NOT NULL,
  communication_intent_digest char(64) NOT NULL,
  case_id uuid NOT NULL,
  expected_case_version bigint NOT NULL,
  communication_class text NOT NULL,
  purpose text NOT NULL,
  channel text NOT NULL,
  provider_config_id uuid NOT NULL,
  provider_config_version bigint NOT NULL,
  provider_configuration_digest char(64) NOT NULL,
  provider_capabilities_digest char(64) NOT NULL,
  provider_preflight_receipt_digest char(64) NOT NULL,
  sender_identity_digest char(64) NOT NULL,
  locale text NOT NULL,
  template_id uuid NOT NULL,
  template_revision bigint NOT NULL,
  template_digest char(64) NOT NULL,
  recipient_count integer NOT NULL,
  recipient_set_digest char(64) NOT NULL,
  endpoint_snapshot_set_digest char(64) NOT NULL,
  recipient_review_scope_digest char(64) NOT NULL,
  authorization_set_digest char(64) NOT NULL,
  suppression_set_digest char(64) NOT NULL,
  rendering_set_digest char(64) NOT NULL,
  exact_rendered_bytes_set_digest char(64) NOT NULL,
  attachment_manifest_digest char(64) NOT NULL,
  rights_set_digest char(64) NOT NULL,
  jurisdiction_set_digest char(64) NOT NULL,
  rate_limit_policy_digest char(64) NOT NULL,
  cost_policy_digest char(64) NOT NULL,
  budget_digest char(64) NOT NULL,
  maximum_cost_amount numeric(18,6) NOT NULL,
  maximum_cost_currency char(3) NOT NULL,
  provider_idempotency_key_set_digest char(64) NOT NULL,
  callback_or_poll_contract_digest char(64) NOT NULL,
  terminal_receipt_policy_digest char(64) NOT NULL,
  dispatch_plan_digest char(64) NOT NULL,
  fallback_mode text NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_communication_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_communication_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_communication_details ADD CONSTRAINT aap_05_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_communication_details ADD CONSTRAINT aap_05_kind_ck CHECK (detail_kind = 'COMMUNICATION');
ALTER TABLE ops.action_approval_communication_details ADD CONSTRAINT aap_05_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_communication_details ADD CONSTRAINT aap_05_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND communication_intent_digest ~ '^[0-9a-f]{64}$' AND provider_configuration_digest ~ '^[0-9a-f]{64}$' AND provider_capabilities_digest ~ '^[0-9a-f]{64}$' AND provider_preflight_receipt_digest ~ '^[0-9a-f]{64}$' AND sender_identity_digest ~ '^[0-9a-f]{64}$' AND template_digest ~ '^[0-9a-f]{64}$' AND recipient_set_digest ~ '^[0-9a-f]{64}$' AND endpoint_snapshot_set_digest ~ '^[0-9a-f]{64}$' AND recipient_review_scope_digest ~ '^[0-9a-f]{64}$' AND authorization_set_digest ~ '^[0-9a-f]{64}$' AND suppression_set_digest ~ '^[0-9a-f]{64}$' AND rendering_set_digest ~ '^[0-9a-f]{64}$' AND exact_rendered_bytes_set_digest ~ '^[0-9a-f]{64}$' AND attachment_manifest_digest ~ '^[0-9a-f]{64}$' AND rights_set_digest ~ '^[0-9a-f]{64}$' AND jurisdiction_set_digest ~ '^[0-9a-f]{64}$' AND rate_limit_policy_digest ~ '^[0-9a-f]{64}$' AND cost_policy_digest ~ '^[0-9a-f]{64}$' AND budget_digest ~ '^[0-9a-f]{64}$' AND provider_idempotency_key_set_digest ~ '^[0-9a-f]{64}$' AND callback_or_poll_contract_digest ~ '^[0-9a-f]{64}$' AND terminal_receipt_policy_digest ~ '^[0-9a-f]{64}$' AND dispatch_plan_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_communication_details ADD CONSTRAINT aap_05_scalar_ck CHECK ((communication_intent_version > 0) AND (expected_case_version > 0) AND (communication_class IN ('SYSTEM_TRANSACTIONAL','SUBSCRIPTION_UPDATE','DISCRETIONARY_EXTERNAL','INTERNAL_ACTION_REQUEST')) AND (purpose IN ('ENDPOINT_VERIFICATION','RIGHT_OF_REPLY_REQUEST','RIGHT_OF_REPLY_REMINDER','RESPONSE_RECEIPT','CORRECTION_STATUS','CORRECTION_RETRACTION_NOTICE','PRIVACY_TRANSACTIONAL_NOTICE','SECURITY_TRANSACTIONAL_NOTICE','SUBSCRIPTION_UPDATE','PRODUCT_MARKETING','INCIDENT_RECOVERY','INTERNAL_ACTION_REQUEST','DISCRETIONARY_OUTREACH')) AND (channel IN ('SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD','LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE','TWILIO_VOICE','SIGNED_WEBHOOK')) AND (provider_config_version > 0) AND (locale ~ '^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*$') AND (template_revision > 0) AND (recipient_count BETWEEN 1 AND 10000) AND (maximum_cost_amount >= 0) AND (maximum_cost_currency ~ '^[A-Z]{3}$') AND (fallback_mode = 'NO_AUTOMATIC_FALLBACK'));
REVOKE ALL ON ops.action_approval_communication_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_communication_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_communication_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_communication_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_communication_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_communication_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_communication_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_communication_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_communication_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_communication_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_publication_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  case_id uuid NOT NULL,
  expected_case_version bigint NOT NULL,
  review_snapshot_id uuid NOT NULL,
  review_snapshot_digest char(64) NOT NULL,
  publication_preview_id uuid NOT NULL,
  publication_preview_digest char(64) NOT NULL,
  publication_gate_preview_digest char(64) NOT NULL,
  exact_public_bytes_digest char(64) NOT NULL,
  publication_evidence_set_digest char(64) NOT NULL,
  rights_set_digest char(64) NOT NULL,
  redaction_set_digest char(64) NOT NULL,
  prior_public_head_digest char(64) NOT NULL,
  projection_plan_digest char(64) NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_publication_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_publication_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_publication_details ADD CONSTRAINT aap_06_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_publication_details ADD CONSTRAINT aap_06_kind_ck CHECK (detail_kind = 'PUBLICATION');
ALTER TABLE ops.action_approval_publication_details ADD CONSTRAINT aap_06_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_publication_details ADD CONSTRAINT aap_06_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND review_snapshot_digest ~ '^[0-9a-f]{64}$' AND publication_preview_digest ~ '^[0-9a-f]{64}$' AND publication_gate_preview_digest ~ '^[0-9a-f]{64}$' AND exact_public_bytes_digest ~ '^[0-9a-f]{64}$' AND publication_evidence_set_digest ~ '^[0-9a-f]{64}$' AND rights_set_digest ~ '^[0-9a-f]{64}$' AND redaction_set_digest ~ '^[0-9a-f]{64}$' AND prior_public_head_digest ~ '^[0-9a-f]{64}$' AND projection_plan_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_publication_details ADD CONSTRAINT aap_06_scalar_ck CHECK ((expected_case_version > 0));
REVOKE ALL ON ops.action_approval_publication_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_publication_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_publication_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_publication_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_publication_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_publication_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_publication_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_publication_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_publication_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_publication_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_retraction_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  case_id uuid NOT NULL,
  expected_case_version bigint NOT NULL,
  prior_publication_revision_id uuid NOT NULL,
  prior_publication_revision bigint NOT NULL,
  prior_publication_revision_digest char(64) NOT NULL,
  retraction_draft_id uuid NOT NULL,
  retraction_draft_digest char(64) NOT NULL,
  review_snapshot_id uuid NOT NULL,
  review_snapshot_digest char(64) NOT NULL,
  publication_gate_preview_digest char(64) NOT NULL,
  tombstone_bytes_digest char(64) NOT NULL,
  retraction_reason_digest char(64) NOT NULL,
  public_pointer_set_digest char(64) NOT NULL,
  projection_plan_digest char(64) NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_retraction_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_retraction_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_retraction_details ADD CONSTRAINT aap_07_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_retraction_details ADD CONSTRAINT aap_07_kind_ck CHECK (detail_kind = 'RETRACTION');
ALTER TABLE ops.action_approval_retraction_details ADD CONSTRAINT aap_07_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_retraction_details ADD CONSTRAINT aap_07_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND prior_publication_revision_digest ~ '^[0-9a-f]{64}$' AND retraction_draft_digest ~ '^[0-9a-f]{64}$' AND review_snapshot_digest ~ '^[0-9a-f]{64}$' AND publication_gate_preview_digest ~ '^[0-9a-f]{64}$' AND tombstone_bytes_digest ~ '^[0-9a-f]{64}$' AND retraction_reason_digest ~ '^[0-9a-f]{64}$' AND public_pointer_set_digest ~ '^[0-9a-f]{64}$' AND projection_plan_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_retraction_details ADD CONSTRAINT aap_07_scalar_ck CHECK ((expected_case_version > 0) AND (prior_publication_revision > 0));
REVOKE ALL ON ops.action_approval_retraction_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_retraction_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_retraction_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_retraction_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_retraction_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_retraction_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_retraction_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_retraction_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_retraction_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_retraction_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_rule_activation_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  rule_id uuid NOT NULL,
  rule_version bigint NOT NULL,
  expected_rule_version bigint NOT NULL,
  rule_version_digest char(64) NOT NULL,
  evaluation_receipt_id uuid NOT NULL,
  evaluation_digest char(64) NOT NULL,
  activation_scope text NOT NULL,
  deployment_scope_digest char(64) NOT NULL,
  activation_plan_digest char(64) NOT NULL,
  effective_at timestamptz NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_rule_activation_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_rule_activation_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_rule_activation_details ADD CONSTRAINT aap_08_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_rule_activation_details ADD CONSTRAINT aap_08_kind_ck CHECK (detail_kind = 'RULE_ACTIVATION');
ALTER TABLE ops.action_approval_rule_activation_details ADD CONSTRAINT aap_08_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_rule_activation_details ADD CONSTRAINT aap_08_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND rule_version_digest ~ '^[0-9a-f]{64}$' AND evaluation_digest ~ '^[0-9a-f]{64}$' AND deployment_scope_digest ~ '^[0-9a-f]{64}$' AND activation_plan_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_rule_activation_details ADD CONSTRAINT aap_08_scalar_ck CHECK ((rule_version > 0) AND (expected_rule_version > 0) AND (activation_scope IN ('SHADOW','LIMITED','PRODUCTION')));
REVOKE ALL ON ops.action_approval_rule_activation_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_rule_activation_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_rule_activation_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_rule_activation_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_rule_activation_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_rule_activation_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_rule_activation_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_rule_activation_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_rule_activation_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_rule_activation_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_role_grant_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  user_id uuid NOT NULL,
  expected_user_version bigint NOT NULL,
  role_id uuid NOT NULL,
  role_binding_digest char(64) NOT NULL,
  scope_digest char(64) NOT NULL,
  grant_expiry_kind text NOT NULL,
  grant_expires_at timestamptz,
  access_policy_digest char(64) NOT NULL,
  separation_of_duty_digest char(64) NOT NULL,
  reason_digest char(64) NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_role_grant_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_role_grant_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_role_grant_details ADD CONSTRAINT aap_09_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_role_grant_details ADD CONSTRAINT aap_09_kind_ck CHECK (detail_kind = 'ROLE_GRANT');
ALTER TABLE ops.action_approval_role_grant_details ADD CONSTRAINT aap_09_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_role_grant_details ADD CONSTRAINT aap_09_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND role_binding_digest ~ '^[0-9a-f]{64}$' AND scope_digest ~ '^[0-9a-f]{64}$' AND access_policy_digest ~ '^[0-9a-f]{64}$' AND separation_of_duty_digest ~ '^[0-9a-f]{64}$' AND reason_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_role_grant_details ADD CONSTRAINT aap_09_scalar_ck CHECK ((expected_user_version > 0) AND (grant_expiry_kind IN ('NEVER','AT')));
REVOKE ALL ON ops.action_approval_role_grant_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_role_grant_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_role_grant_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_role_grant_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_role_grant_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_role_grant_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_role_grant_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_role_grant_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_role_grant_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_role_grant_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_kill_switch_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  command text NOT NULL,
  switch_target text NOT NULL,
  switch_target_digest char(64) NOT NULL,
  switch_effect text NOT NULL,
  expected_generation bigint NOT NULL,
  current_switch_digest char(64) NOT NULL,
  breadth text NOT NULL,
  affected_scope_digest char(64) NOT NULL,
  reason_digest char(64) NOT NULL,
  requested_expiry_kind text NOT NULL,
  requested_expires_at timestamptz,
  recovery_plan_digest char(64) NOT NULL,
  kill_switch_policy_digest char(64) NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_kill_switch_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_kill_switch_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_kill_switch_details ADD CONSTRAINT aap_10_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_kill_switch_details ADD CONSTRAINT aap_10_kind_ck CHECK (detail_kind = 'KILL_SWITCH');
ALTER TABLE ops.action_approval_kill_switch_details ADD CONSTRAINT aap_10_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_kill_switch_details ADD CONSTRAINT aap_10_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND switch_target_digest ~ '^[0-9a-f]{64}$' AND current_switch_digest ~ '^[0-9a-f]{64}$' AND affected_scope_digest ~ '^[0-9a-f]{64}$' AND reason_digest ~ '^[0-9a-f]{64}$' AND recovery_plan_digest ~ '^[0-9a-f]{64}$' AND kill_switch_policy_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_kill_switch_details ADD CONSTRAINT aap_10_scalar_ck CHECK ((command IN ('ACTIVATE','DEACTIVATE','EXTEND')) AND (length(btrim(switch_target)) BETWEEN 1 AND 500) AND (switch_effect IN ('PAUSE','DENY','READ_ONLY','DISABLE_EGRESS')) AND (expected_generation >= 0) AND (breadth IN ('NARROW','BROAD')) AND (requested_expiry_kind IN ('NEVER','AT')));
REVOKE ALL ON ops.action_approval_kill_switch_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_kill_switch_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_kill_switch_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_kill_switch_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_kill_switch_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_kill_switch_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_kill_switch_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_kill_switch_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_kill_switch_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_kill_switch_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_communication_authorization_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  subject_id uuid NOT NULL,
  endpoint_id uuid NOT NULL,
  endpoint_version bigint NOT NULL,
  endpoint_snapshot_digest char(64) NOT NULL,
  channel text NOT NULL,
  communication_class text NOT NULL,
  purpose text NOT NULL,
  topic_scope_kind text NOT NULL,
  topic_scope_digest char(64) NOT NULL,
  basis text NOT NULL,
  jurisdiction text NOT NULL,
  locale text NOT NULL,
  policy_version text NOT NULL,
  policy_digest char(64) NOT NULL,
  decision text NOT NULL,
  current_authorization_head_digest char(64) NOT NULL,
  proof_receipt_id uuid NOT NULL,
  proof_receipt_digest char(64) NOT NULL,
  effective_at timestamptz NOT NULL,
  verification_expiry_kind text NOT NULL,
  verification_expires_at timestamptz,
  authorization_expiry_kind text NOT NULL,
  authorization_expires_at timestamptz,
  suppression_state_digest char(64) NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_communication_authorization_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_communication_authorization_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_communication_authorization_details ADD CONSTRAINT aap_11_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_communication_authorization_details ADD CONSTRAINT aap_11_kind_ck CHECK (detail_kind = 'COMMUNICATION_AUTHORIZATION');
ALTER TABLE ops.action_approval_communication_authorization_details ADD CONSTRAINT aap_11_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_communication_authorization_details ADD CONSTRAINT aap_11_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND endpoint_snapshot_digest ~ '^[0-9a-f]{64}$' AND topic_scope_digest ~ '^[0-9a-f]{64}$' AND policy_digest ~ '^[0-9a-f]{64}$' AND current_authorization_head_digest ~ '^[0-9a-f]{64}$' AND proof_receipt_digest ~ '^[0-9a-f]{64}$' AND suppression_state_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_communication_authorization_details ADD CONSTRAINT aap_11_scalar_ck CHECK ((endpoint_version > 0) AND (channel IN ('SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD','LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE','TWILIO_VOICE','SIGNED_WEBHOOK')) AND (communication_class IN ('SYSTEM_TRANSACTIONAL','SUBSCRIPTION_UPDATE','DISCRETIONARY_EXTERNAL','INTERNAL_ACTION_REQUEST')) AND (purpose IN ('ENDPOINT_VERIFICATION','RIGHT_OF_REPLY_REQUEST','RIGHT_OF_REPLY_REMINDER','RESPONSE_RECEIPT','CORRECTION_STATUS','CORRECTION_RETRACTION_NOTICE','PRIVACY_TRANSACTIONAL_NOTICE','SECURITY_TRANSACTIONAL_NOTICE','SUBSCRIPTION_UPDATE','PRODUCT_MARKETING','INCIDENT_RECOVERY','INTERNAL_ACTION_REQUEST','DISCRETIONARY_OUTREACH')) AND (topic_scope_kind IN ('EXACT_TOPIC_SET','EXACT_EVENT_SET','EXACT_SUBJECT')) AND (basis IN ('CONSENT','CONTRACTUAL_TRANSACTIONAL','LEGAL_OBLIGATION_REVIEWED','LEGITIMATE_INTEREST_REVIEWED','PUBLIC_TASK_REVIEWED','VITAL_INTEREST_REVIEWED')) AND (length(jurisdiction) BETWEEN 2 AND 64) AND (decision IN ('GRANT','REVOKE','RESTRICT')) AND (verification_expiry_kind IN ('NEVER','AT')) AND (authorization_expiry_kind IN ('NEVER','AT')));
REVOKE ALL ON ops.action_approval_communication_authorization_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_communication_authorization_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_communication_authorization_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_communication_authorization_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_communication_authorization_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_communication_authorization_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_communication_authorization_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_communication_authorization_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_communication_authorization_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_communication_authorization_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_asset_rights_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  asset_id uuid NOT NULL,
  asset_sha256 char(64) NOT NULL,
  expected_decision_version bigint NOT NULL,
  current_decision_digest char(64) NOT NULL,
  decision_kind text NOT NULL,
  dimension_decision_set_digest char(64) NOT NULL,
  legal_basis_digest char(64) NOT NULL,
  license_evidence_set_digest char(64) NOT NULL,
  jurisdiction text NOT NULL,
  attribution_kind text NOT NULL,
  attribution_policy_digest char(64),
  attribution_text_digest char(64),
  effective_at timestamptz NOT NULL,
  expiry_kind text NOT NULL,
  expires_at timestamptz,
  CONSTRAINT g_pk_ops_action_approval_asset_rights_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_asset_rights_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_asset_rights_details ADD CONSTRAINT aap_12_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_asset_rights_details ADD CONSTRAINT aap_12_kind_ck CHECK (detail_kind = 'ASSET_RIGHTS_DECISION');
ALTER TABLE ops.action_approval_asset_rights_details ADD CONSTRAINT aap_12_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_asset_rights_details ADD CONSTRAINT aap_12_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND asset_sha256 ~ '^[0-9a-f]{64}$' AND current_decision_digest ~ '^[0-9a-f]{64}$' AND dimension_decision_set_digest ~ '^[0-9a-f]{64}$' AND legal_basis_digest ~ '^[0-9a-f]{64}$' AND license_evidence_set_digest ~ '^[0-9a-f]{64}$' AND attribution_policy_digest ~ '^[0-9a-f]{64}$' AND attribution_text_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_asset_rights_details ADD CONSTRAINT aap_12_scalar_ck CHECK ((expected_decision_version >= 0) AND (decision_kind IN ('GRANT','DENY','SUSPEND','REVOKE')) AND (attribution_kind IN ('NOT_REQUIRED','REQUIRED')) AND (expiry_kind IN ('NEVER','AT')));
REVOKE ALL ON ops.action_approval_asset_rights_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_asset_rights_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_asset_rights_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_asset_rights_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_asset_rights_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_asset_rights_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_asset_rights_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_asset_rights_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_asset_rights_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_asset_rights_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_retention_schedule_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  record_class text NOT NULL,
  expected_schedule_revision bigint NOT NULL,
  current_schedule_digest char(64) NOT NULL,
  purpose_digest char(64) NOT NULL,
  lawful_basis_digest char(64) NOT NULL,
  trigger_kind text NOT NULL,
  active_duration_seconds bigint,
  backup_duration_seconds bigint,
  location_set_digest char(64) NOT NULL,
  terminal_action text NOT NULL,
  hold_behavior text NOT NULL,
  restore_suppression_behavior text NOT NULL,
  current_legal_hold_set_digest char(64) NOT NULL,
  effective_at timestamptz NOT NULL,
  review_expires_at timestamptz NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_retention_schedule_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_retention_schedule_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_retention_schedule_details ADD CONSTRAINT aap_13_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_retention_schedule_details ADD CONSTRAINT aap_13_kind_ck CHECK (detail_kind = 'RETENTION_SCHEDULE');
ALTER TABLE ops.action_approval_retention_schedule_details ADD CONSTRAINT aap_13_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_retention_schedule_details ADD CONSTRAINT aap_13_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND current_schedule_digest ~ '^[0-9a-f]{64}$' AND purpose_digest ~ '^[0-9a-f]{64}$' AND lawful_basis_digest ~ '^[0-9a-f]{64}$' AND location_set_digest ~ '^[0-9a-f]{64}$' AND current_legal_hold_set_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_retention_schedule_details ADD CONSTRAINT aap_13_scalar_ck CHECK ((expected_schedule_revision >= 0) AND (trigger_kind IN ('CREATED_AT','UPDATED_AT','CONSUMED_AT','EXPIRES_AT','CASE_CLOSED_AT','LAST_MATERIAL_USE_AT','SUPERSEDED_AT','DELIVERED_AT','TERMINAL_AT')) AND (active_duration_seconds IS NULL OR active_duration_seconds BETWEEN 0 AND 3155760000) AND (backup_duration_seconds IS NULL OR backup_duration_seconds BETWEEN 0 AND 3155760000) AND (terminal_action IN ('DELETE','ANONYMIZE','CRYPTO_ERASE','PRESERVE_PUBLIC_REVISION')) AND (hold_behavior IN ('BLOCK_ON_RETENTION','BLOCK_ON_RETENTION_OR_DELETION','NOT_DESTRUCTIVE')) AND (restore_suppression_behavior IN ('REAPPLY_BEFORE_ACCESS','NOT_APPLICABLE')));
REVOKE ALL ON ops.action_approval_retention_schedule_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_retention_schedule_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_retention_schedule_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_retention_schedule_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_retention_schedule_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_retention_schedule_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_retention_schedule_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_retention_schedule_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_retention_schedule_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_retention_schedule_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_funding_disclosure_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  disclosure_id uuid NOT NULL,
  prior_revision_kind text NOT NULL,
  prior_revision_id uuid,
  prior_revision bigint,
  prior_revision_digest char(64),
  fiscal_period_digest char(64) NOT NULL,
  snapshot_batch_id uuid NOT NULL,
  snapshot_digest char(64) NOT NULL,
  naming_threshold_policy_digest char(64) NOT NULL,
  conflict_snapshot_digest char(64) NOT NULL,
  ordered_entry_set_digest char(64) NOT NULL,
  prerequisite_review_set_digest char(64) NOT NULL,
  disclosure_preview_id uuid NOT NULL,
  disclosure_preview_digest char(64) NOT NULL,
  exact_public_bytes_digest char(64) NOT NULL,
  effective_at timestamptz NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_funding_disclosure_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_funding_disclosure_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_funding_disclosure_details ADD CONSTRAINT aap_14_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_funding_disclosure_details ADD CONSTRAINT aap_14_kind_ck CHECK (detail_kind = 'FUNDING_DISCLOSURE');
ALTER TABLE ops.action_approval_funding_disclosure_details ADD CONSTRAINT aap_14_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_funding_disclosure_details ADD CONSTRAINT aap_14_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND prior_revision_digest ~ '^[0-9a-f]{64}$' AND fiscal_period_digest ~ '^[0-9a-f]{64}$' AND snapshot_digest ~ '^[0-9a-f]{64}$' AND naming_threshold_policy_digest ~ '^[0-9a-f]{64}$' AND conflict_snapshot_digest ~ '^[0-9a-f]{64}$' AND ordered_entry_set_digest ~ '^[0-9a-f]{64}$' AND prerequisite_review_set_digest ~ '^[0-9a-f]{64}$' AND disclosure_preview_digest ~ '^[0-9a-f]{64}$' AND exact_public_bytes_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_funding_disclosure_details ADD CONSTRAINT aap_14_scalar_ck CHECK ((prior_revision_kind IN ('NONE','EXACT')));
REVOKE ALL ON ops.action_approval_funding_disclosure_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_funding_disclosure_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_funding_disclosure_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_funding_disclosure_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_funding_disclosure_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_funding_disclosure_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_funding_disclosure_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_funding_disclosure_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_funding_disclosure_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_funding_disclosure_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_capability_activation_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  capability_class text NOT NULL,
  capability_id text NOT NULL,
  environment text NOT NULL,
  expected_capability_version bigint NOT NULL,
  current_capability_digest char(64) NOT NULL,
  decision text NOT NULL,
  configuration_digest char(64) NOT NULL,
  evidence_receipt_set_digest char(64) NOT NULL,
  preflight_receipt_digest char(64) NOT NULL,
  policy_digest char(64) NOT NULL,
  contract_digest char(64) NOT NULL,
  rights_digest char(64) NOT NULL,
  jurisdiction_set_digest char(64) NOT NULL,
  kill_switch_digest char(64) NOT NULL,
  effective_at timestamptz NOT NULL,
  expiry_kind text NOT NULL,
  expires_at timestamptz,
  CONSTRAINT g_pk_ops_action_approval_capability_activation_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_capability_activation_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_capability_activation_details ADD CONSTRAINT aap_15_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_capability_activation_details ADD CONSTRAINT aap_15_kind_ck CHECK (detail_kind = 'CAPABILITY_ACTIVATION');
ALTER TABLE ops.action_approval_capability_activation_details ADD CONSTRAINT aap_15_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_capability_activation_details ADD CONSTRAINT aap_15_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND current_capability_digest ~ '^[0-9a-f]{64}$' AND configuration_digest ~ '^[0-9a-f]{64}$' AND evidence_receipt_set_digest ~ '^[0-9a-f]{64}$' AND preflight_receipt_digest ~ '^[0-9a-f]{64}$' AND policy_digest ~ '^[0-9a-f]{64}$' AND contract_digest ~ '^[0-9a-f]{64}$' AND rights_digest ~ '^[0-9a-f]{64}$' AND jurisdiction_set_digest ~ '^[0-9a-f]{64}$' AND kill_switch_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_capability_activation_details ADD CONSTRAINT aap_15_scalar_ck CHECK ((capability_class IN ('PUBLIC_PUBLICATION','SOURCE_ACCESS','SOURCE_STORAGE','SOURCE_REDISTRIBUTION','MODEL_EGRESS','DELIVERY_CHANNEL','PRIVACY_DSAR','PAID_WORKSPACE_PROCESSING')) AND (environment IN ('DEVELOPMENT','TEST','STAGING','PRODUCTION')) AND (expected_capability_version >= 0) AND (decision IN ('ACTIVATE','SUSPEND','REACTIVATE')) AND (expiry_kind IN ('NEVER','AT')));
REVOKE ALL ON ops.action_approval_capability_activation_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_capability_activation_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_capability_activation_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_capability_activation_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_capability_activation_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_capability_activation_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_capability_activation_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_capability_activation_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_capability_activation_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_capability_activation_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_response_policy_calendar_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  calendar_id uuid NOT NULL,
  expected_calendar_version bigint NOT NULL,
  current_calendar_digest char(64) NOT NULL,
  timezone text NOT NULL,
  weekend_days text[] NOT NULL,
  holiday_date_set_digest char(64) NOT NULL,
  policy_digest char(64) NOT NULL,
  response_clock_impact_digest char(64) NOT NULL,
  effective_at timestamptz NOT NULL,
  review_expires_at timestamptz NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_response_policy_calendar_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_response_policy_calendar_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_response_policy_calendar_details ADD CONSTRAINT aap_16_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_response_policy_calendar_details ADD CONSTRAINT aap_16_kind_ck CHECK (detail_kind = 'RESPONSE_POLICY_CALENDAR');
ALTER TABLE ops.action_approval_response_policy_calendar_details ADD CONSTRAINT aap_16_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_response_policy_calendar_details ADD CONSTRAINT aap_16_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND current_calendar_digest ~ '^[0-9a-f]{64}$' AND holiday_date_set_digest ~ '^[0-9a-f]{64}$' AND policy_digest ~ '^[0-9a-f]{64}$' AND response_clock_impact_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_response_policy_calendar_details ADD CONSTRAINT aap_16_scalar_ck CHECK ((expected_calendar_version >= 0));
REVOKE ALL ON ops.action_approval_response_policy_calendar_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_response_policy_calendar_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_response_policy_calendar_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_response_policy_calendar_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_response_policy_calendar_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_response_policy_calendar_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_response_policy_calendar_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_response_policy_calendar_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_response_policy_calendar_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_response_policy_calendar_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TABLE ops.action_approval_commercial_control_details (
  proposal_id uuid NOT NULL,
  proposal_version bigint NOT NULL,
  detail_kind text NOT NULL,
  detail_binding_canonical bytea NOT NULL,
  action_detail_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  trigger_id uuid NOT NULL,
  trigger_version bigint NOT NULL,
  trigger_as_of timestamptz NOT NULL,
  trigger_kind text NOT NULL,
  trigger_digest char(64) NOT NULL,
  control_mode text NOT NULL,
  metric_result_set_digest char(64) NOT NULL,
  transitive_input_set_digest char(64) NOT NULL,
  trigger_policy_digest char(64) NOT NULL,
  affected_scope_digest char(64) NOT NULL,
  requested_actions text[] NOT NULL,
  requested_action_set_digest char(64) NOT NULL,
  current_offer_profile_digest char(64) NOT NULL,
  current_contract_head_digest char(64) NOT NULL,
  current_capability_version_set_digest char(64) NOT NULL,
  current_kill_switch_version_set_digest char(64) NOT NULL,
  product_execution_plan_digest char(64) NOT NULL,
  external_execution_plan_digest char(64) NOT NULL,
  external_system_binding_set_digest char(64) NOT NULL,
  existing_customer_continuity_plan_digest char(64) NOT NULL,
  consequence_digest char(64) NOT NULL,
  budget_policy_digest char(64) NOT NULL,
  control_evidence_kind text NOT NULL,
  cause_evidence_set_digest char(64),
  original_control_execution_id uuid,
  original_control_receipt_digest char(64),
  closure_receipt_set_digest char(64),
  remedy_verification_digest char(64),
  resume_evidence_set_digest char(64),
  import_contract_digest char(64) NOT NULL,
  acknowledgement_requirement_digest char(64) NOT NULL,
  ack_due_at timestamptz NOT NULL,
  expected_terminal_state text NOT NULL,
  CONSTRAINT g_pk_ops_action_approval_commercial_control_details_1 PRIMARY KEY (proposal_id, proposal_version)
);
ALTER TABLE ops.action_approval_commercial_control_details OWNER TO gurine_migrator;
ALTER TABLE ops.action_approval_commercial_control_details ADD CONSTRAINT aap_17_binding_uq UNIQUE (proposal_id, proposal_version, detail_kind, action_detail_digest);
ALTER TABLE ops.action_approval_commercial_control_details ADD CONSTRAINT aap_17_kind_ck CHECK (detail_kind = 'COMMERCIAL_CONTROL');
ALTER TABLE ops.action_approval_commercial_control_details ADD CONSTRAINT aap_17_canonical_ck CHECK (octet_length(detail_binding_canonical) > 0);
ALTER TABLE ops.action_approval_commercial_control_details ADD CONSTRAINT aap_17_digest_ck CHECK (action_detail_digest ~ '^[0-9a-f]{64}$' AND trigger_digest ~ '^[0-9a-f]{64}$' AND metric_result_set_digest ~ '^[0-9a-f]{64}$' AND transitive_input_set_digest ~ '^[0-9a-f]{64}$' AND trigger_policy_digest ~ '^[0-9a-f]{64}$' AND affected_scope_digest ~ '^[0-9a-f]{64}$' AND requested_action_set_digest ~ '^[0-9a-f]{64}$' AND current_offer_profile_digest ~ '^[0-9a-f]{64}$' AND current_contract_head_digest ~ '^[0-9a-f]{64}$' AND current_capability_version_set_digest ~ '^[0-9a-f]{64}$' AND current_kill_switch_version_set_digest ~ '^[0-9a-f]{64}$' AND product_execution_plan_digest ~ '^[0-9a-f]{64}$' AND external_execution_plan_digest ~ '^[0-9a-f]{64}$' AND external_system_binding_set_digest ~ '^[0-9a-f]{64}$' AND existing_customer_continuity_plan_digest ~ '^[0-9a-f]{64}$' AND consequence_digest ~ '^[0-9a-f]{64}$' AND budget_policy_digest ~ '^[0-9a-f]{64}$' AND cause_evidence_set_digest ~ '^[0-9a-f]{64}$' AND original_control_receipt_digest ~ '^[0-9a-f]{64}$' AND closure_receipt_set_digest ~ '^[0-9a-f]{64}$' AND remedy_verification_digest ~ '^[0-9a-f]{64}$' AND resume_evidence_set_digest ~ '^[0-9a-f]{64}$' AND import_contract_digest ~ '^[0-9a-f]{64}$' AND acknowledgement_requirement_digest ~ '^[0-9a-f]{64}$');
ALTER TABLE ops.action_approval_commercial_control_details ADD CONSTRAINT aap_17_scalar_ck CHECK ((trigger_version > 0) AND (trigger_kind IN ('METRIC_THRESHOLD','COMMERCIAL_PAUSE','TRUST_HARD_STOP')) AND (control_mode IN ('PAUSE','RESUME')) AND (control_evidence_kind IN ('PAUSE','RESUME')) AND (expected_terminal_state IN ('PAUSED','NORMAL')));
REVOKE ALL ON ops.action_approval_commercial_control_details FROM PUBLIC;
REVOKE ALL ON ops.action_approval_commercial_control_details FROM gurine_workflow_worker;
REVOKE ALL ON ops.action_approval_commercial_control_details FROM gurine_control_api;
REVOKE ALL ON ops.action_approval_commercial_control_details FROM gurine_analysis_worker;
REVOKE ALL ON ops.action_approval_commercial_control_details FROM gurine_public_projector;
REVOKE ALL ON ops.action_approval_commercial_control_details FROM gurine_notification_worker;
REVOKE ALL ON ops.action_approval_commercial_control_details FROM gurine_submission_api;
REVOKE ALL ON ops.action_approval_commercial_control_details FROM gurine_auditor;
CREATE TRIGGER ops_action_approval_commercial_control_details_immutable_mutation_guard BEFORE UPDATE OR DELETE ON ops.action_approval_commercial_control_details FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
ALTER TABLE ops.action_proposals ADD CONSTRAINT action_proposals_current_version_fk FOREIGN KEY (id, current_version) REFERENCES ops.action_proposal_versions (proposal_id, version) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_proposals ADD CONSTRAINT action_proposals_compensation_fk FOREIGN KEY (compensates_execution_id, compensates_execution_state, compensates_effect_digest, compensates_execution_receipt_digest) REFERENCES ops.in_flight_effects (id, state, effect_key_digest, last_receipt_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_proposal_versions ADD CONSTRAINT action_proposal_versions_proposal_fk FOREIGN KEY (proposal_id) REFERENCES ops.action_proposals (id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_binding_fk FOREIGN KEY (proposal_id, proposal_version, approval_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, approval_digest) ON DELETE RESTRICT;
ALTER TABLE ops.action_review_assignments ADD CONSTRAINT action_review_assignments_replacement_fk FOREIGN KEY (replacement_of_assignment_id) REFERENCES ops.action_review_assignments (id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_binding_fk FOREIGN KEY (proposal_id, proposal_version, approval_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, approval_digest) ON DELETE RESTRICT;
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_assignment_fk FOREIGN KEY (assignment_id, proposal_id, proposal_version, approval_digest, assignment_version, assignment_generation, slot_kind) REFERENCES ops.action_review_assignments (id, proposal_id, proposal_version, approval_digest, version, assignment_generation, slot_id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_execution_fk FOREIGN KEY (execution_id) REFERENCES ops.in_flight_effects (id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_decisions ADD CONSTRAINT action_decisions_withdrawn_decision_fk FOREIGN KEY (withdrawn_decision_id, proposal_id, proposal_version, approval_digest, withdrawn_decision_receipt_digest, actor_id, assignment_id, assignment_generation, slot_kind, withdrawn_record_kind, withdrawn_decision_kind) REFERENCES ops.action_decisions (id, proposal_id, proposal_version, approval_digest, receipt_digest, actor_id, assignment_id, assignment_generation, slot_kind, record_kind, decision_kind) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_action_binding_fk FOREIGN KEY (action_proposal_id, action_proposal_version, approval_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, approval_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.in_flight_effects ADD CONSTRAINT in_flight_effects_predecessor_fk FOREIGN KEY (predecessor_effect_id) REFERENCES ops.in_flight_effects (id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.budget_reservations ADD CONSTRAINT budget_reservations_effect_fk FOREIGN KEY (effect_id) REFERENCES ops.in_flight_effects (id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.budget_reservation_ledger_entries ADD CONSTRAINT budget_ledger_reservation_fk FOREIGN KEY (reservation_id) REFERENCES ops.budget_reservations (id) ON DELETE RESTRICT;
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_effect_fk FOREIGN KEY (execution_id) REFERENCES ops.in_flight_effects (id) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_binding_fk FOREIGN KEY (proposal_id, proposal_version, approval_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, approval_digest) ON DELETE RESTRICT;
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_terminal_decision_fk FOREIGN KEY (terminal_decision_id, proposal_id, proposal_version, approval_digest, terminal_decision_receipt_digest) REFERENCES ops.action_decisions (id, proposal_id, proposal_version, approval_digest, receipt_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.execution_authorizations ADD CONSTRAINT execution_authorizations_budget_fk FOREIGN KEY (budget_reservation_id, budget_reservation_digest) REFERENCES ops.budget_reservations (id, reservation_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_authorization_fk FOREIGN KEY (execution_id, generation, target_request_sha256, rendered_bytes_digest, provider_config_id, provider_config_version, provider_configuration_digest, provider_idempotency_key_sha256, budget_reservation_id, budget_reservation_digest) REFERENCES ops.execution_authorizations (execution_id, generation, target_request_sha256, rendered_bytes_digest, provider_config_id, provider_config_version, provider_configuration_digest, provider_idempotency_key_sha256, budget_reservation_id, budget_reservation_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_effect_fk FOREIGN KEY (execution_id) REFERENCES ops.in_flight_effects (id) ON DELETE RESTRICT;
ALTER TABLE ops.execution_attempts ADD CONSTRAINT execution_attempts_budget_fk FOREIGN KEY (budget_reservation_id, budget_reservation_digest) REFERENCES ops.budget_reservations (id, reservation_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_effect_fk FOREIGN KEY (execution_id) REFERENCES ops.in_flight_effects (id) ON DELETE RESTRICT;
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_attempt_fk FOREIGN KEY (attempt_id, execution_id, generation) REFERENCES ops.execution_attempts (id, execution_id, generation) ON DELETE RESTRICT DEFERRABLE;
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_budget_fk FOREIGN KEY (budget_reservation_id, budget_reservation_digest) REFERENCES ops.budget_reservations (id, reservation_digest) ON DELETE RESTRICT DEFERRABLE;
ALTER TABLE ops.execution_receipts ADD CONSTRAINT execution_receipts_prior_fk FOREIGN KEY (execution_id, prior_receipt_digest) REFERENCES ops.execution_receipts (execution_id, receipt_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_hypothesis_details ADD CONSTRAINT aap_01_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_claim_details ADD CONSTRAINT aap_02_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_task_details ADD CONSTRAINT aap_03_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_comparable_details ADD CONSTRAINT aap_04_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_communication_details ADD CONSTRAINT aap_05_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_publication_details ADD CONSTRAINT aap_06_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_retraction_details ADD CONSTRAINT aap_07_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_rule_activation_details ADD CONSTRAINT aap_08_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_role_grant_details ADD CONSTRAINT aap_09_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_kill_switch_details ADD CONSTRAINT aap_10_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_communication_authorization_details ADD CONSTRAINT aap_11_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_asset_rights_details ADD CONSTRAINT aap_12_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_retention_schedule_details ADD CONSTRAINT aap_13_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_funding_disclosure_details ADD CONSTRAINT aap_14_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_capability_activation_details ADD CONSTRAINT aap_15_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_response_policy_calendar_details ADD CONSTRAINT aap_16_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.action_approval_commercial_control_details ADD CONSTRAINT aap_17_parent_fk FOREIGN KEY (proposal_id, proposal_version, detail_kind, action_detail_digest) REFERENCES ops.action_proposal_versions (proposal_id, version, action_detail_kind, action_detail_digest) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;
CREATE INDEX action_proposals_owner_updated_idx ON ops.action_proposals (owner_user_id, updated_at DESC, id DESC);
CREATE INDEX action_proposals_kind_updated_idx ON ops.action_proposals (action_kind, updated_at DESC, id DESC);
CREATE INDEX action_proposals_target_idx ON ops.action_proposals (target_type, target_id, target_version, id);
CREATE INDEX action_proposal_versions_state_expiry_idx ON ops.action_proposal_versions (state, expires_at, proposal_id, version) WHERE state IN ('DRAFT','PENDING_QUORUM');
CREATE INDEX action_proposal_versions_pending_due_idx ON ops.action_proposal_versions (due_at, proposal_id, version) WHERE state = 'PENDING_QUORUM';
CREATE INDEX action_proposal_versions_content_idx ON ops.action_proposal_versions (proposal_id, content_digest, version DESC);
CREATE UNIQUE INDEX action_review_assignments_one_live_slot_idx ON ops.action_review_assignments (proposal_id, proposal_version, slot_id) WHERE state IN ('VACANT','ASSIGNED','IN_PROGRESS');
CREATE INDEX action_review_assignments_reviewer_queue_idx ON ops.action_review_assignments (reviewer_id, state, due_at, id) WHERE state IN ('ASSIGNED','IN_PROGRESS');
CREATE INDEX action_review_assignments_vacancy_idx ON ops.action_review_assignments (next_assignment_scan_at, due_at, proposal_id, proposal_version, slot_ordinal, id) WHERE state = 'VACANT';
CREATE INDEX action_review_assignments_proposal_order_idx ON ops.action_review_assignments (proposal_id, proposal_version, slot_ordinal, assignment_generation, id);
CREATE UNIQUE INDEX action_decisions_assignment_once_idx ON ops.action_decisions (assignment_id) WHERE record_kind = 'DECISION';
CREATE UNIQUE INDEX action_decisions_actor_once_idx ON ops.action_decisions (proposal_id, proposal_version, actor_id) WHERE record_kind = 'DECISION';
CREATE UNIQUE INDEX action_decisions_withdrawal_once_idx ON ops.action_decisions (withdrawn_decision_id) WHERE record_kind = 'APPROVAL_WITHDRAWAL';
CREATE INDEX action_decisions_withdrawn_decision_fk_idx ON ops.action_decisions (withdrawn_decision_id, proposal_id, proposal_version, approval_digest, withdrawn_decision_receipt_digest, actor_id, assignment_id, assignment_generation, slot_kind, withdrawn_record_kind, withdrawn_decision_kind) WHERE record_kind = 'APPROVAL_WITHDRAWAL';
CREATE INDEX action_decisions_proposal_history_idx ON ops.action_decisions (proposal_id, proposal_version, created_at, id);
CREATE INDEX action_decisions_counted_idx ON ops.action_decisions (proposal_id, proposal_version, id) WHERE counts_toward_quorum;
CREATE UNIQUE INDEX action_decisions_execution_idx ON ops.action_decisions (execution_id) WHERE execution_id IS NOT NULL;
CREATE INDEX in_flight_effects_queue_idx ON ops.in_flight_effects (run_after, created_at, id) WHERE state = 'QUEUED';
CREATE INDEX in_flight_effects_reconcile_idx ON ops.in_flight_effects (updated_at, id) WHERE state IN ('CANCEL_REQUESTED','RECONCILIATION_REQUIRED');
CREATE UNIQUE INDEX in_flight_effects_one_action_effect_idx ON ops.in_flight_effects (action_proposal_id, action_proposal_version) WHERE effect_type = 'ACTION_EXECUTION';
CREATE UNIQUE INDEX in_flight_effects_agent_idx ON ops.in_flight_effects (agent_provider_turn_id) WHERE effect_type = 'AGENT_PROVIDER_TURN';
CREATE INDEX budget_reservations_orphan_idx ON ops.budget_reservations (expires_at, id) WHERE state = 'RESERVED';
CREATE INDEX budget_reservations_reconcile_idx ON ops.budget_reservations (updated_at, id) WHERE state = 'RECONCILIATION_REQUIRED';
CREATE INDEX budget_reservations_effect_idx ON ops.budget_reservations (effect_id, effect_generation, created_at, id);
CREATE UNIQUE INDEX budget_reservations_action_identity_idx ON ops.budget_reservations (effect_id, effect_generation, provider_candidate_id, pricing_version) WHERE reservation_source_kind = 'ACTION_EXECUTION';
CREATE UNIQUE INDEX budget_reservations_agent_identity_idx ON ops.budget_reservations (job_id, attempt, provider_candidate_id, pricing_version) WHERE reservation_source_kind = 'AGENT_PROVIDER_TURN';
CREATE INDEX budget_ledger_cell_balance_idx ON ops.budget_reservation_ledger_entries (ledger_scope_kind, ledger_scope_id, window_kind, window_start, currency, occurred_at, id);
CREATE INDEX budget_ledger_reservation_history_idx ON ops.budget_reservation_ledger_entries (reservation_id, transition_sequence, entry_ordinal, id);
CREATE INDEX budget_ledger_transition_idx ON ops.budget_reservation_ledger_entries (transition_id, entry_ordinal);
CREATE INDEX execution_authorizations_proposal_idx ON ops.execution_authorizations (proposal_id, proposal_version, generation);
CREATE INDEX execution_authorizations_expiry_idx ON ops.execution_authorizations (expires_at, execution_id, generation);
CREATE UNIQUE INDEX execution_authorizations_initial_per_proposal_idx ON ops.execution_authorizations (proposal_id, proposal_version) WHERE generation = 1;
CREATE INDEX execution_attempts_claim_idx ON ops.execution_attempts (run_after, created_at, id) WHERE attempt_state = 'QUEUED';
CREATE INDEX execution_attempts_expired_lease_idx ON ops.execution_attempts (lease_expires_at, execution_id, generation) WHERE attempt_state = 'CLAIMED';
CREATE INDEX execution_attempts_reconcile_idx ON ops.execution_attempts (updated_at, execution_id, generation) WHERE attempt_state IN ('CANCEL_REQUESTED','RECONCILIATION_REQUIRED');
CREATE INDEX execution_receipts_chain_idx ON ops.execution_receipts (execution_id, receipt_sequence, id);
CREATE INDEX execution_receipts_reconcile_idx ON ops.execution_receipts (observed_at, execution_id, receipt_sequence) WHERE aggregate_state = 'RECONCILIATION_REQUIRED';
CREATE UNIQUE INDEX execution_receipts_mutating_version_idx ON ops.execution_receipts (execution_id, aggregate_state_version) WHERE mutates_aggregate_state;
CREATE UNIQUE INDEX execution_receipts_one_terminal_idx ON ops.execution_receipts (execution_id) WHERE mutates_aggregate_state AND aggregate_state IN ('POLICY_BLOCKED','SUCCEEDED','PARTIALLY_SUCCEEDED','PERMANENT_FAILED','CANCELLED','EXPIRED');
CREATE INDEX aap_01_digest_idx ON ops.action_approval_hypothesis_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_01_source_idx ON ops.action_approval_hypothesis_details (case_id, expected_case_version, proposal_id, proposal_version);
CREATE INDEX aap_02_digest_idx ON ops.action_approval_claim_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_02_source_idx ON ops.action_approval_claim_details (case_id, expected_case_version, proposal_id, proposal_version);
CREATE INDEX aap_03_digest_idx ON ops.action_approval_task_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_03_source_idx ON ops.action_approval_task_details (object_type, object_id, expected_object_version, proposal_id, proposal_version);
CREATE INDEX aap_04_digest_idx ON ops.action_approval_comparable_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_04_source_idx ON ops.action_approval_comparable_details (target_line_item_id, target_line_item_version, candidate_line_item_id, candidate_line_item_version, proposal_id, proposal_version);
CREATE INDEX aap_05_digest_idx ON ops.action_approval_communication_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_05_source_idx ON ops.action_approval_communication_details (communication_intent_id, communication_intent_version, provider_config_id, provider_config_version, proposal_id, proposal_version);
CREATE INDEX aap_06_digest_idx ON ops.action_approval_publication_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_06_source_idx ON ops.action_approval_publication_details (case_id, expected_case_version, publication_preview_id, proposal_id, proposal_version);
CREATE INDEX aap_07_digest_idx ON ops.action_approval_retraction_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_07_source_idx ON ops.action_approval_retraction_details (case_id, prior_publication_revision_id, prior_publication_revision, proposal_id, proposal_version);
CREATE INDEX aap_08_digest_idx ON ops.action_approval_rule_activation_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_08_source_idx ON ops.action_approval_rule_activation_details (rule_id, rule_version, proposal_id, proposal_version);
CREATE INDEX aap_09_digest_idx ON ops.action_approval_role_grant_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_09_source_idx ON ops.action_approval_role_grant_details (user_id, role_id, proposal_id, proposal_version);
CREATE INDEX aap_10_digest_idx ON ops.action_approval_kill_switch_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_10_source_idx ON ops.action_approval_kill_switch_details (switch_target, expected_generation, proposal_id, proposal_version);
CREATE INDEX aap_11_digest_idx ON ops.action_approval_communication_authorization_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_11_source_idx ON ops.action_approval_communication_authorization_details (subject_id, endpoint_id, endpoint_version, proposal_id, proposal_version);
CREATE INDEX aap_12_digest_idx ON ops.action_approval_asset_rights_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_12_source_idx ON ops.action_approval_asset_rights_details (asset_id, expected_decision_version, proposal_id, proposal_version);
CREATE INDEX aap_13_digest_idx ON ops.action_approval_retention_schedule_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_13_source_idx ON ops.action_approval_retention_schedule_details (record_class, expected_schedule_revision, proposal_id, proposal_version);
CREATE INDEX aap_14_digest_idx ON ops.action_approval_funding_disclosure_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_14_source_idx ON ops.action_approval_funding_disclosure_details (disclosure_id, snapshot_batch_id, proposal_id, proposal_version);
CREATE INDEX aap_15_digest_idx ON ops.action_approval_capability_activation_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_15_source_idx ON ops.action_approval_capability_activation_details (capability_class, capability_id, environment, expected_capability_version, proposal_id, proposal_version);
CREATE INDEX aap_16_digest_idx ON ops.action_approval_response_policy_calendar_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_16_source_idx ON ops.action_approval_response_policy_calendar_details (calendar_id, expected_calendar_version, proposal_id, proposal_version);
CREATE INDEX aap_17_digest_idx ON ops.action_approval_commercial_control_details (action_detail_digest, proposal_id, proposal_version);
CREATE INDEX aap_17_source_idx ON ops.action_approval_commercial_control_details (trigger_id, trigger_version, control_mode, proposal_id, proposal_version);
COMMIT;
