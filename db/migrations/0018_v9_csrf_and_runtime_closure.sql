BEGIN;

ALTER TABLE ops.sessions
  ADD COLUMN csrf_token_hash char(64),
  ADD COLUMN csrf_rotated_at timestamptz;

UPDATE ops.sessions
SET csrf_token_hash = repeat('0', 64),
    csrf_rotated_at = clock_timestamp(),
    revoked_at = COALESCE(revoked_at, clock_timestamp())
WHERE csrf_token_hash IS NULL;

ALTER TABLE ops.sessions
  ALTER COLUMN csrf_token_hash SET NOT NULL,
  ALTER COLUMN csrf_rotated_at SET NOT NULL,
  ALTER COLUMN csrf_rotated_at SET DEFAULT clock_timestamp(),
  ADD CONSTRAINT sessions_csrf_token_hash_format
    CHECK (csrf_token_hash ~ '^[a-f0-9]{64}$');

CREATE OR REPLACE FUNCTION ops.rotate_session_csrf(
  p_session_token_hash char(64),
  p_current_csrf_hash char(64),
  p_new_csrf_hash char(64)
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
BEGIN
  IF p_new_csrf_hash !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION 'invalid_csrf_hash' USING ERRCODE = '22023';
  END IF;

  UPDATE ops.sessions
  SET csrf_token_hash = p_new_csrf_hash,
      csrf_rotated_at = clock_timestamp()
  WHERE session_token_hash = p_session_token_hash
    AND csrf_token_hash = p_current_csrf_hash
    AND revoked_at IS NULL
    AND expires_at > clock_timestamp();

  RETURN FOUND;
END
$$;

REVOKE ALL ON FUNCTION ops.rotate_session_csrf(char(64),char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.rotate_session_csrf(char(64),char(64),char(64)) TO gurine_identity_api;

COMMIT;
