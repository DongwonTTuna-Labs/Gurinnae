BEGIN;

ALTER TABLE ops.oidc_transactions
  ADD COLUMN transaction_kind text NOT NULL DEFAULT 'LOGIN'
    CHECK (transaction_kind IN ('LOGIN','STEP_UP')),
  ADD COLUMN session_id uuid REFERENCES ops.sessions(id),
  ADD CONSTRAINT oidc_transaction_binding_check CHECK (
    (transaction_kind = 'LOGIN' AND session_id IS NULL AND action_digest IS NULL)
    OR
    (transaction_kind = 'STEP_UP' AND session_id IS NOT NULL AND action_digest IS NOT NULL)
  );

CREATE INDEX oidc_transactions_session_kind_expiry_idx
  ON ops.oidc_transactions(session_id, transaction_kind, expires_at)
  WHERE consumed_at IS NULL;

CREATE TABLE ops.step_up_proofs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES ops.sessions(id) ON DELETE CASCADE,
  action_digest char(64) NOT NULL,
  proof_token_hash char(64) NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (expires_at > created_at)
);
CREATE INDEX step_up_proofs_active_idx
  ON ops.step_up_proofs(session_id, action_digest, expires_at)
  WHERE consumed_at IS NULL;

ALTER TABLE ops.users
  ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK (version > 0);
ALTER TABLE ops.roles
  ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  ADD COLUMN updated_at timestamptz NOT NULL DEFAULT clock_timestamp();
CREATE TRIGGER roles_updated_at
  BEFORE UPDATE ON ops.roles
  FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();
ALTER TABLE ops.source_incidents
  ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK (version > 0);

REVOKE ALL ON ops.step_up_proofs FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON ops.oidc_transactions, ops.step_up_proofs TO gurine_control_api;

COMMIT;
