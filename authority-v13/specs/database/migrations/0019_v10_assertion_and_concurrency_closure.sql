BEGIN;

CREATE TABLE ops.assertion_replay_guard (
  assertion_type text NOT NULL CHECK (assertion_type IN ('SERVICE','ACTOR')),
  jti uuid NOT NULL,
  issuer text NOT NULL,
  audience text NOT NULL,
  request_digest char(64) NOT NULL,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (assertion_type, jti)
);
CREATE INDEX assertion_replay_guard_expiry_idx ON ops.assertion_replay_guard (expires_at);
REVOKE ALL ON ops.assertion_replay_guard FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.consume_assertion_jti(
  p_assertion_type text,
  p_jti uuid,
  p_issuer text,
  p_audience text,
  p_expires_at timestamptz,
  p_request_digest char(64)
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
BEGIN
  IF p_assertion_type NOT IN ('SERVICE','ACTOR') THEN
    RETURN false;
  END IF;
  IF p_expires_at <= clock_timestamp() - interval '5 seconds' THEN
    RETURN false;
  END IF;
  INSERT INTO ops.assertion_replay_guard(
    assertion_type,jti,issuer,audience,request_digest,expires_at
  ) VALUES(
    p_assertion_type,p_jti,p_issuer,p_audience,p_request_digest,p_expires_at
  ) ON CONFLICT DO NOTHING;
  RETURN FOUND;
END
$$;
REVOKE ALL ON FUNCTION ops.consume_assertion_jti(text,uuid,text,text,timestamptz,char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.consume_assertion_jti(text,uuid,text,text,timestamptz,char(64)) TO gurine_identity_api, gurine_control_api;

CREATE UNIQUE INDEX schema_mappings_one_approved_per_drift_idx
ON ops.schema_mappings(schema_drift_id)
WHERE status = 'APPROVED';

COMMIT;
