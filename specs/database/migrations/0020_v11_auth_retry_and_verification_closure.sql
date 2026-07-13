BEGIN;

ALTER TABLE ops.oidc_transactions
  ADD COLUMN IF NOT EXISTS action_context jsonb,
  ADD COLUMN IF NOT EXISTS idempotency_key_sha256 char(64);

CREATE TABLE ops.step_up_authorizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES ops.sessions(id) ON DELETE CASCADE,
  action_digest char(64) NOT NULL,
  idempotency_key_sha256 char(64) NOT NULL,
  authorization_token_hash char(64) NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  closed_at timestamptz,
  assertion_issue_count integer NOT NULL DEFAULT 0 CHECK (assertion_issue_count BETWEEN 0 AND 3),
  max_assertion_issues integer NOT NULL DEFAULT 3 CHECK (max_assertion_issues = 3),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_issued_at timestamptz,
  CHECK (expires_at > created_at)
);
CREATE INDEX step_up_authorizations_session_idx ON ops.step_up_authorizations(session_id, expires_at DESC);

CREATE OR REPLACE FUNCTION ops.create_step_up_authorization(
  p_session_id uuid,
  p_action_digest char(64),
  p_idempotency_key_sha256 char(64),
  p_authorization_token_hash char(64),
  p_expires_at timestamptz
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  IF p_expires_at <= clock_timestamp() OR p_expires_at > clock_timestamp() + interval '5 minutes 5 seconds' THEN
    RAISE EXCEPTION 'invalid_step_up_authorization_expiry' USING ERRCODE='22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.sessions WHERE id=p_session_id AND revoked_at IS NULL AND expires_at>clock_timestamp()) THEN
    RAISE EXCEPTION 'invalid_or_expired_session' USING ERRCODE='28000';
  END IF;
  INSERT INTO ops.step_up_authorizations(session_id,action_digest,idempotency_key_sha256,authorization_token_hash,expires_at)
  VALUES(p_session_id,p_action_digest,p_idempotency_key_sha256,p_authorization_token_hash,p_expires_at)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION ops.claim_step_up_authorization(
  p_authorization_token_hash char(64),
  p_session_id uuid,
  p_action_digest char(64),
  p_idempotency_key_sha256 char(64),
  p_now timestamptz
) RETURNS TABLE(authorization_id uuid, issue_number integer, remaining_issues integer, authorization_expires_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
DECLARE v ops.step_up_authorizations%ROWTYPE;
BEGIN
  SELECT * INTO v FROM ops.step_up_authorizations WHERE authorization_token_hash=p_authorization_token_hash FOR UPDATE;
  IF NOT FOUND OR v.session_id<>p_session_id OR v.action_digest<>p_action_digest OR v.idempotency_key_sha256<>p_idempotency_key_sha256 OR v.closed_at IS NOT NULL OR v.expires_at<=p_now OR v.assertion_issue_count>=v.max_assertion_issues THEN
    RAISE EXCEPTION 'invalid_or_exhausted_step_up_authorization' USING ERRCODE='28000';
  END IF;
  UPDATE ops.step_up_authorizations
    SET assertion_issue_count=assertion_issue_count+1,last_issued_at=p_now
    WHERE id=v.id;
  RETURN QUERY SELECT v.id,v.assertion_issue_count+1,v.max_assertion_issues-(v.assertion_issue_count+1),v.expires_at;
END $$;

CREATE OR REPLACE FUNCTION ops.close_step_up_authorization(
  p_authorization_token_hash char(64),
  p_session_id uuid,
  p_action_digest char(64),
  p_idempotency_key_sha256 char(64)
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
BEGIN
  UPDATE ops.step_up_authorizations SET closed_at=COALESCE(closed_at,clock_timestamp())
  WHERE authorization_token_hash=p_authorization_token_hash AND session_id=p_session_id
    AND action_digest=p_action_digest AND idempotency_key_sha256=p_idempotency_key_sha256;
  RETURN FOUND;
END $$;

REVOKE ALL ON TABLE ops.step_up_authorizations FROM PUBLIC;
REVOKE ALL ON TABLE ops.step_up_authorizations FROM gurine_control_api, gurine_identity_api;
REVOKE ALL ON FUNCTION ops.create_step_up_authorization(uuid,char(64),char(64),char(64),timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.claim_step_up_authorization(char(64),uuid,char(64),char(64),timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.close_step_up_authorization(char(64),uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.create_step_up_authorization(uuid,char(64),char(64),char(64),timestamptz) TO gurine_identity_api;
GRANT EXECUTE ON FUNCTION ops.claim_step_up_authorization(char(64),uuid,char(64),char(64),timestamptz) TO gurine_identity_api;
GRANT EXECUTE ON FUNCTION ops.close_step_up_authorization(char(64),uuid,char(64),char(64)) TO gurine_identity_api;
REVOKE EXECUTE ON FUNCTION ops.consume_step_up_proof(char(64),uuid,char(64),text,uuid) FROM gurine_control_api, gurine_identity_api;

COMMIT;
