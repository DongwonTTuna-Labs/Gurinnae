BEGIN;

ALTER TABLE ops.oidc_transactions
  ADD COLUMN issuer_url text,
  ADD COLUMN redirect_uri text,
  ADD COLUMN requested_acr_values text[] NOT NULL DEFAULT ARRAY[]::text[],
  ADD COLUMN max_age_seconds integer CHECK (max_age_seconds IS NULL OR max_age_seconds >= 0),
  ADD COLUMN request_context_hash char(64);

ALTER TABLE ops.step_up_proofs
  ADD COLUMN used_by_operation text,
  ADD COLUMN used_request_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gurine_identity_api') THEN
    CREATE ROLE gurine_identity_api NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
END
$$;

REVOKE ALL ON SCHEMA raw, core, editorial, intake, public FROM gurine_identity_api;
GRANT USAGE ON SCHEMA ops, extensions TO gurine_identity_api;

REVOKE ALL ON ops.oidc_transactions, ops.step_up_proofs FROM gurine_control_api;
GRANT SELECT, INSERT, UPDATE ON ops.oidc_transactions, ops.step_up_proofs TO gurine_identity_api;
GRANT SELECT, INSERT, UPDATE ON ops.sessions, ops.users, ops.idempotency_keys TO gurine_identity_api;
GRANT SELECT ON ops.roles, ops.capabilities, ops.role_capabilities, ops.user_roles TO gurine_identity_api;
GRANT EXECUTE ON FUNCTION ops.append_audit_event(text,text,text,uuid,text,text,text,text,ops.audit_outcome,text,uuid,jsonb) TO gurine_identity_api;

CREATE OR REPLACE FUNCTION ops.consume_step_up_proof(
  p_proof_token_hash char(64),
  p_session_id uuid,
  p_action_digest char(64),
  p_operation text,
  p_request_id uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  SELECT id INTO v_id
  FROM ops.step_up_proofs
  WHERE proof_token_hash = p_proof_token_hash
    AND session_id = p_session_id
    AND action_digest = p_action_digest
    AND consumed_at IS NULL
    AND expires_at > clock_timestamp()
  FOR UPDATE;

  IF v_id IS NULL THEN
    RETURN false;
  END IF;

  UPDATE ops.step_up_proofs
  SET consumed_at = clock_timestamp(),
      used_by_operation = p_operation,
      used_request_id = p_request_id
  WHERE id = v_id AND consumed_at IS NULL;

  RETURN FOUND;
END
$$;

REVOKE ALL ON FUNCTION ops.consume_step_up_proof(char(64),uuid,char(64),text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.consume_step_up_proof(char(64),uuid,char(64),text,uuid) TO gurine_control_api;

COMMIT;
