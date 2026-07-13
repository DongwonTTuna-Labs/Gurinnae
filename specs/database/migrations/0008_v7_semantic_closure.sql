BEGIN;

-- Canonical state constraints that were previously represented only in documents.
DO $$
BEGIN
  CREATE TYPE core.claim_validation_status AS ENUM ('DRAFT','VALID','BLOCKED','SUPERSEDED');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
  CREATE TYPE editorial.review_status AS ENUM ('UNASSIGNED','ASSIGNED','IN_PROGRESS','COMPLETED','CANCELLED');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

ALTER TABLE editorial.claims
  ALTER COLUMN validation_status DROP DEFAULT,
  ALTER COLUMN validation_status TYPE core.claim_validation_status
    USING validation_status::core.claim_validation_status,
  ALTER COLUMN validation_status SET DEFAULT 'DRAFT';

CREATE TABLE editorial.review_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES editorial.cases(id),
  review_snapshot_id uuid REFERENCES editorial.review_snapshots(id),
  reviewer_id uuid REFERENCES ops.users(id),
  status editorial.review_status NOT NULL DEFAULT 'UNASSIGNED',
  assigned_by uuid REFERENCES ops.users(id),
  assigned_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  due_at timestamptz,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (case_id, review_snapshot_id, reviewer_id)
);
CREATE INDEX review_assignments_queue_idx
  ON editorial.review_assignments(status, due_at, created_at);
CREATE TRIGGER review_assignments_updated_at
  BEFORE UPDATE ON editorial.review_assignments
  FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE editorial.retraction_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  publication_revision_id uuid NOT NULL REFERENCES editorial.publication_revisions(id),
  scope text NOT NULL CHECK (scope IN ('FULL','PARTIAL')),
  affected_claim_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
  reason text NOT NULL,
  status text NOT NULL CHECK (status IN ('DRAFT','REVIEW','APPROVED','REJECTED','PUBLISHED')),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_by uuid NOT NULL REFERENCES ops.users(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TRIGGER retraction_drafts_updated_at
  BEFORE UPDATE ON editorial.retraction_drafts
  FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE TABLE editorial.publication_access_decisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  publication_revision_id uuid NOT NULL REFERENCES editorial.publication_revisions(id),
  scope text NOT NULL CHECK (scope IN ('FULL','CLAIMS','EVIDENCE')),
  affected_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
  state text NOT NULL CHECK (state IN ('ACTIVE','EXPIRED','REVOKED')),
  reason text NOT NULL,
  expires_at timestamptz NOT NULL,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  placed_by uuid NOT NULL REFERENCES ops.users(id),
  placed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  revoked_by uuid REFERENCES ops.users(id),
  revoked_at timestamptz
);
CREATE INDEX publication_access_active_idx
  ON editorial.publication_access_decisions(publication_revision_id, expires_at)
  WHERE state = 'ACTIVE';

CREATE TABLE editorial.evidence_redactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence_id uuid NOT NULL REFERENCES editorial.evidence(id),
  ranges jsonb NOT NULL,
  redaction_type text NOT NULL,
  reason text NOT NULL,
  replacement_text text,
  status text NOT NULL CHECK (status IN ('DRAFT','APPROVED','REJECTED','SUPERSEDED')),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_by uuid NOT NULL REFERENCES ops.users(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  decided_by uuid REFERENCES ops.users(id),
  decided_at timestamptz
);

CREATE TABLE editorial.publication_previews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES editorial.cases(id),
  review_snapshot_id uuid NOT NULL REFERENCES editorial.review_snapshots(id),
  locale text NOT NULL,
  preview_payload jsonb NOT NULL,
  preview_sha256 char(64) NOT NULL,
  expires_at timestamptz NOT NULL,
  created_by uuid NOT NULL REFERENCES ops.users(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (case_id, review_snapshot_id, locale, preview_sha256)
);

CREATE TABLE core.rule_evaluations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_version_id uuid NOT NULL REFERENCES core.rule_versions(id),
  dataset_snapshot_id uuid NOT NULL,
  evaluation_profile text NOT NULL CHECK (evaluation_profile IN ('FULL','REGRESSION','SHADOW')),
  status text NOT NULL CHECK (status IN ('QUEUED','RUNNING','SUCCEEDED','FAILED','CANCELLED')),
  result_payload jsonb,
  result_digest char(64),
  requested_by uuid NOT NULL REFERENCES ops.users(id),
  reason text NOT NULL,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (rule_version_id, dataset_snapshot_id, evaluation_profile)
);

CREATE TABLE ops.provider_connection_tests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL REFERENCES ops.provider_configs(id),
  test_model text NOT NULL,
  status text NOT NULL CHECK (status IN ('QUEUED','RUNNING','SUCCEEDED','FAILED','CANCELLED')),
  redacted_result jsonb,
  requested_by uuid NOT NULL REFERENCES ops.users(id),
  reason text,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE ops.audit_verification_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mode text NOT NULL CHECK (mode IN ('FULL','RANGE','TAIL')),
  from_event_id uuid REFERENCES ops.audit_events(id),
  to_event_id uuid REFERENCES ops.audit_events(id),
  expected_chain_head char(64),
  status text NOT NULL CHECK (status IN ('QUEUED','RUNNING','SUCCEEDED','FAILED')),
  verified_count bigint NOT NULL DEFAULT 0,
  actual_chain_head char(64),
  failure_event_id uuid REFERENCES ops.audit_events(id),
  requested_by uuid NOT NULL REFERENCES ops.users(id),
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE intake.response_extension_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  response_request_id uuid NOT NULL REFERENCES editorial.response_requests(id),
  requested_due_at timestamptz NOT NULL,
  reason text NOT NULL,
  status text NOT NULL CHECK (status IN ('SUBMITTED','APPROVED','REJECTED')),
  submitted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  decided_at timestamptz
);

ALTER TABLE intake.response_access_tokens
  ADD COLUMN verified_at timestamptz,
  ADD COLUMN verification_attempt_count integer NOT NULL DEFAULT 0 CHECK (verification_attempt_count >= 0),
  ADD COLUMN verification_locked_until timestamptz;

-- Source document bytes and identity are immutable, but processing lifecycle is not.
DROP TRIGGER IF EXISTS source_documents_immutable ON raw.source_documents;
CREATE OR REPLACE FUNCTION raw.enforce_source_document_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, raw, core, extensions, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'source_document_delete_forbidden' USING ERRCODE = '55000';
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.source_id IS DISTINCT FROM OLD.source_id
     OR NEW.source_fetch_id IS DISTINCT FROM OLD.source_fetch_id
     OR NEW.external_id IS DISTINCT FROM OLD.external_id
     OR NEW.external_version IS DISTINCT FROM OLD.external_version
     OR NEW.canonical_url IS DISTINCT FROM OLD.canonical_url
     OR NEW.retrieved_at IS DISTINCT FROM OLD.retrieved_at
     OR NEW.source_published_at IS DISTINCT FROM OLD.source_published_at
     OR NEW.content_type IS DISTINCT FROM OLD.content_type
     OR NEW.content_sha256 IS DISTINCT FROM OLD.content_sha256
     OR NEW.content_size_bytes IS DISTINCT FROM OLD.content_size_bytes
     OR NEW.object_key IS DISTINCT FROM OLD.object_key
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'source_document_identity_immutable' USING ERRCODE = '55000';
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
       (OLD.status = 'DISCOVERED' AND NEW.status IN ('FETCHED','QUARANTINED','REJECTED'))
    OR (OLD.status = 'FETCHED' AND NEW.status IN ('PARSED','QUARANTINED','REJECTED'))
    OR (OLD.status = 'QUARANTINED' AND NEW.status IN ('FETCHED','REJECTED'))
  ) THEN
    RAISE EXCEPTION 'invalid_source_document_transition: % -> %', OLD.status, NEW.status
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER source_documents_lifecycle_guard
  BEFORE UPDATE OR DELETE ON raw.source_documents
  FOR EACH ROW EXECUTE FUNCTION raw.enforce_source_document_lifecycle();

-- Rule run identity is immutable; only a bounded RUNNING -> terminal transition is valid.
DROP TRIGGER IF EXISTS rule_runs_immutable ON core.rule_runs;
CREATE OR REPLACE FUNCTION core.enforce_rule_run_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, core, extensions, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'rule_run_delete_forbidden' USING ERRCODE = '55000';
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.rule_version_id IS DISTINCT FROM OLD.rule_version_id
     OR NEW.run_key IS DISTINCT FROM OLD.run_key
     OR NEW.input_snapshot_at IS DISTINCT FROM OLD.input_snapshot_at
     OR NEW.input_digest IS DISTINCT FROM OLD.input_digest
     OR NEW.started_at IS DISTINCT FROM OLD.started_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'rule_run_identity_immutable' USING ERRCODE = '55000';
  END IF;

  IF OLD.status <> 'RUNNING' THEN
    RAISE EXCEPTION 'terminal_rule_run_immutable' USING ERRCODE = '55000';
  END IF;
  IF NEW.status NOT IN ('RUNNING','SUCCEEDED','FAILED','CANCELLED') THEN
    RAISE EXCEPTION 'invalid_rule_run_status' USING ERRCODE = '23514';
  END IF;
  IF NEW.status IN ('SUCCEEDED','FAILED','CANCELLED') AND NEW.completed_at IS NULL THEN
    RAISE EXCEPTION 'terminal_rule_run_requires_completed_at' USING ERRCODE = '23514';
  END IF;
  IF NEW.record_count < 0 OR NEW.signal_count < 0 THEN
    RAISE EXCEPTION 'negative_rule_run_count' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER rule_runs_lifecycle_guard
  BEFORE UPDATE OR DELETE ON core.rule_runs
  FOR EACH ROW EXECUTE FUNCTION core.enforce_rule_run_lifecycle();

-- Database-owned audit hash chain. Callers cannot supply either hash.
CREATE TABLE ops.audit_chain_heads (
  stream_key text PRIMARY KEY,
  head_event_id uuid REFERENCES ops.audit_events(id),
  head_hash char(64),
  version bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

DROP FUNCTION IF EXISTS ops.append_audit_event(
  text,text,uuid,text,text,text,text,ops.audit_outcome,text,uuid,jsonb,char,char
);
CREATE OR REPLACE FUNCTION ops.append_audit_event(
  p_stream_key text,
  p_actor_type text,
  p_actor_id text,
  p_session_id uuid,
  p_action text,
  p_object_type text,
  p_object_id text,
  p_capability text,
  p_outcome ops.audit_outcome,
  p_reason text,
  p_request_id uuid,
  p_details jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_id uuid := gen_random_uuid();
  v_occurred_at timestamptz := clock_timestamp();
  v_previous_hash char(64);
  v_event_hash char(64);
  v_canonical text;
BEGIN
  IF p_stream_key IS NULL OR p_stream_key !~ '^[a-z0-9][a-z0-9._:-]{0,199}$' THEN
    RAISE EXCEPTION 'invalid_audit_stream_key' USING ERRCODE = '22023';
  END IF;

  INSERT INTO ops.audit_chain_heads(stream_key)
  VALUES (p_stream_key)
  ON CONFLICT (stream_key) DO NOTHING;

  SELECT head_hash INTO v_previous_hash
  FROM ops.audit_chain_heads
  WHERE stream_key = p_stream_key
  FOR UPDATE;

  v_canonical := jsonb_build_object(
    'id', v_id,
    'stream_key', p_stream_key,
    'occurred_at', v_occurred_at,
    'actor_type', p_actor_type,
    'actor_id', p_actor_id,
    'session_id', p_session_id,
    'action', p_action,
    'object_type', p_object_type,
    'object_id', p_object_id,
    'capability', p_capability,
    'outcome', p_outcome,
    'reason', p_reason,
    'request_id', p_request_id,
    'details', COALESCE(p_details, '{}'::jsonb),
    'previous_event_hash', v_previous_hash
  )::text;

  v_event_hash := encode(
    extensions.digest(convert_to(COALESCE(v_previous_hash, '') || v_canonical, 'UTF8'), 'sha256'),
    'hex'
  );

  INSERT INTO ops.audit_events(
    id, occurred_at, actor_type, actor_id, session_id, action, object_type,
    object_id, capability, outcome, reason, request_id, details,
    previous_event_hash, event_hash
  ) VALUES (
    v_id, v_occurred_at, p_actor_type, p_actor_id, p_session_id, p_action,
    p_object_type, p_object_id, p_capability, p_outcome, p_reason,
    p_request_id, COALESCE(p_details, '{}'::jsonb), v_previous_hash, v_event_hash
  );

  UPDATE ops.audit_chain_heads
  SET head_event_id = v_id,
      head_hash = v_event_hash,
      version = version + 1,
      updated_at = v_occurred_at
  WHERE stream_key = p_stream_key;

  RETURN v_id;
END
$$;

-- Outbox events are accepted only from the canonical active event catalog.
CREATE TABLE ops.event_types (
  event_type text PRIMARY KEY CHECK (event_type ~ '^[a-z][a-z0-9_.]+\.v[1-9][0-9]*$'),
  category text NOT NULL CHECK (category IN ('DOMAIN','INTEGRATION')),
  schema_version integer NOT NULL CHECK (schema_version > 0),
  active boolean NOT NULL DEFAULT true,
  payload_schema_uri text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE OR REPLACE FUNCTION ops.enqueue_outbox(
  p_aggregate_type text,
  p_aggregate_id text,
  p_aggregate_version bigint,
  p_event_type text,
  p_payload jsonb,
  p_occurred_at timestamptz
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM ops.event_types
    WHERE event_type = p_event_type AND active
  ) THEN
    RAISE EXCEPTION 'unknown_or_inactive_event_type: %', p_event_type
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO ops.outbox(
    aggregate_type, aggregate_id, aggregate_version, event_type, payload, occurred_at
  ) VALUES (
    p_aggregate_type, p_aggregate_id, p_aggregate_version, p_event_type,
    COALESCE(p_payload, '{}'::jsonb), p_occurred_at
  ) RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

-- Token-scoped submission helpers. Raw tokens are never stored; callers pass an HMAC hash.
CREATE OR REPLACE FUNCTION intake.resolve_response_request_id(p_token_hash char(64))
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, editorial, extensions, pg_temp
AS $$
DECLARE
  v_request_id uuid;
  v_request_status text;
  v_due_at timestamptz;
BEGIN
  SELECT t.response_request_id INTO v_request_id
  FROM intake.response_access_tokens t
  WHERE t.token_hash = p_token_hash
    AND t.revoked_at IS NULL
    AND t.expires_at > clock_timestamp()
    AND t.verified_at IS NOT NULL
    AND t.use_count < t.max_uses
    AND (t.verification_locked_until IS NULL OR t.verification_locked_until <= clock_timestamp())
  FOR UPDATE;

  IF v_request_id IS NULL THEN
    RAISE EXCEPTION 'invalid_or_unverified_response_token' USING ERRCODE = '28000';
  END IF;

  SELECT r.status, r.due_at INTO v_request_status, v_due_at
  FROM editorial.response_requests r
  WHERE r.id = v_request_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_request_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_request_status NOT IN ('SENT', 'VIEWED') THEN
    RAISE EXCEPTION 'response_request_closed' USING ERRCODE = '55000';
  END IF;
  IF v_due_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'response_request_expired' USING ERRCODE = '22023';
  END IF;

  PERFORM set_config('gurine.response_request_id', v_request_id::text, true);
  RETURN v_request_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.verify_response_access(
  p_token_hash char(64),
  p_verification_succeeded boolean
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, editorial, extensions, pg_temp
AS $$
DECLARE
  v_request_id uuid;
BEGIN
  UPDATE intake.response_access_tokens AS t
  SET verification_attempt_count = t.verification_attempt_count + 1,
      verified_at = CASE WHEN p_verification_succeeded THEN clock_timestamp() ELSE t.verified_at END,
      verification_locked_until = CASE
        WHEN NOT p_verification_succeeded AND t.verification_attempt_count + 1 >= 5
          THEN clock_timestamp() + interval '15 minutes'
        ELSE t.verification_locked_until
      END,
      use_count = t.use_count + 1,
      last_used_at = clock_timestamp()
  FROM editorial.response_requests AS r
  WHERE t.token_hash = p_token_hash
    AND r.id = t.response_request_id
    AND r.status IN ('SENT', 'VIEWED')
    AND r.due_at > clock_timestamp()
    AND t.revoked_at IS NULL
    AND t.expires_at > clock_timestamp()
    AND t.use_count < t.max_uses
  RETURNING t.response_request_id INTO v_request_id;

  IF v_request_id IS NULL THEN
    RAISE EXCEPTION 'invalid_expired_or_closed_response_token' USING ERRCODE = '28000';
  END IF;
  RETURN v_request_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.save_response_draft(
  p_token_hash char(64),
  p_expected_version bigint,
  p_answers_encrypted bytea,
  p_publication_consent jsonb,
  p_expires_at timestamptz
) RETURNS TABLE(draft_id uuid, version bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, editorial, extensions, pg_temp
AS $$
DECLARE
  v_request_id uuid;
  v_current_id uuid;
  v_current_version bigint;
BEGIN
  -- The resolver locks the token and response request, preventing concurrent creation
  -- for the same request and rejecting closed or expired requests.
  v_request_id := intake.resolve_response_request_id(p_token_hash);

  SELECT id, response_drafts.version
  INTO v_current_id, v_current_version
  FROM intake.response_drafts
  WHERE response_request_id = v_request_id
  FOR UPDATE;

  IF v_current_id IS NULL THEN
    IF p_expected_version <> 0 THEN
      RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE = '40001';
    END IF;

    INSERT INTO intake.response_drafts(
      response_request_id, version, answers_encrypted, publication_consent,
      saved_at, expires_at
    ) VALUES (
      v_request_id, 1, p_answers_encrypted, p_publication_consent,
      clock_timestamp(), p_expires_at
    )
    RETURNING id, response_drafts.version INTO draft_id, version;
  ELSE
    IF v_current_version IS DISTINCT FROM p_expected_version THEN
      RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE = '40001';
    END IF;

    UPDATE intake.response_drafts
    SET answers_encrypted = p_answers_encrypted,
        publication_consent = p_publication_consent,
        saved_at = clock_timestamp(),
        expires_at = p_expires_at,
        version = response_drafts.version + 1
    WHERE id = v_current_id
      AND version = p_expected_version
    RETURNING id, response_drafts.version INTO draft_id, version;

    IF draft_id IS NULL THEN
      RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE = '40001';
    END IF;
  END IF;

  RETURN NEXT;
END
$$;

CREATE OR REPLACE FUNCTION intake.create_response_attachment(
  p_token_hash char(64),
  p_filename_encrypted bytea,
  p_media_type text,
  p_size_bytes bigint,
  p_sha256 char(64),
  p_object_key text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, editorial, extensions, pg_temp
AS $$
DECLARE
  v_request_id uuid;
  v_draft_id uuid;
  v_id uuid;
BEGIN
  v_request_id := intake.resolve_response_request_id(p_token_hash);
  SELECT id INTO v_draft_id FROM intake.response_drafts
  WHERE response_request_id = v_request_id;
  INSERT INTO intake.response_attachments(
    response_request_id, draft_id, original_filename_encrypted, media_type,
    size_bytes, sha256, object_key, upload_status, scan_status
  ) VALUES (
    v_request_id, v_draft_id, p_filename_encrypted, p_media_type,
    p_size_bytes, p_sha256, p_object_key, 'PENDING', 'PENDING'
  ) RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.finalize_response_attachment(
  p_token_hash char(64),
  p_attachment_id uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, editorial, extensions, pg_temp
AS $$
DECLARE
  v_request_id uuid;
  v_id uuid;
BEGIN
  v_request_id := intake.resolve_response_request_id(p_token_hash);
  UPDATE intake.response_attachments
  SET upload_status = 'UPLOADED',
      scan_status = 'PENDING'
  WHERE id = p_attachment_id
    AND response_request_id = v_request_id
    AND upload_status = 'PENDING'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'attachment_not_found_or_invalid_state' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.delete_response_attachment(
  p_token_hash char(64),
  p_attachment_id uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, editorial, extensions, pg_temp
AS $$
DECLARE
  v_request_id uuid;
  v_id uuid;
BEGIN
  v_request_id := intake.resolve_response_request_id(p_token_hash);
  UPDATE intake.response_attachments
  SET upload_status = 'DELETED'
  WHERE id = p_attachment_id
    AND response_request_id = v_request_id
    AND upload_status <> 'DELETED'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'attachment_not_found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.submit_response(
  p_token_hash char(64),
  p_expected_version bigint,
  p_submission_sha256 char(64),
  p_answers_encrypted bytea,
  p_publication_consent jsonb,
  p_receipt_token_hash char(64)
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, editorial, extensions, pg_temp
AS $$
DECLARE
  v_request_id uuid;
  v_draft_version bigint;
  v_id uuid;
  v_updated_request_id uuid;
BEGIN
  -- Locks both the token and response request and rejects closed/expired requests.
  v_request_id := intake.resolve_response_request_id(p_token_hash);

  IF EXISTS (
    SELECT 1 FROM intake.response_submissions
    WHERE response_request_id = v_request_id
  ) THEN
    RAISE EXCEPTION 'response_request_already_submitted' USING ERRCODE = '23505';
  END IF;

  SELECT version INTO v_draft_version
  FROM intake.response_drafts
  WHERE response_request_id = v_request_id
  FOR UPDATE;

  IF v_draft_version IS NULL THEN
    RAISE EXCEPTION 'response_draft_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_draft_version IS DISTINCT FROM p_expected_version THEN
    RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE = '40001';
  END IF;
  IF EXISTS (
    SELECT 1 FROM intake.response_attachments
    WHERE response_request_id = v_request_id
      AND upload_status <> 'DELETED'
      AND (upload_status <> 'FINALIZED' OR scan_status <> 'CLEAN')
  ) THEN
    RAISE EXCEPTION 'response_attachment_not_clean' USING ERRCODE = '23514';
  END IF;

  INSERT INTO intake.response_submissions(
    response_request_id, draft_version, submission_sha256, answers_encrypted,
    publication_consent, receipt_token_hash
  ) VALUES (
    v_request_id, v_draft_version, p_submission_sha256, p_answers_encrypted,
    p_publication_consent, p_receipt_token_hash
  ) RETURNING id INTO v_id;

  UPDATE editorial.response_requests
  SET status = 'SUBMITTED',
      version = version + 1,
      updated_at = clock_timestamp()
  WHERE id = v_request_id
    AND status IN ('SENT', 'VIEWED')
    AND due_at > clock_timestamp()
  RETURNING id INTO v_updated_request_id;

  IF v_updated_request_id IS NULL THEN
    RAISE EXCEPTION 'response_request_closed_or_expired' USING ERRCODE = '55000';
  END IF;

  UPDATE intake.response_access_tokens
  SET revoked_at = clock_timestamp(),
      last_used_at = clock_timestamp()
  WHERE token_hash = p_token_hash
    AND response_request_id = v_request_id
    AND revoked_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_token_consumption_failed' USING ERRCODE = '28000';
  END IF;

  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.request_response_extension(
  p_token_hash char(64),
  p_requested_due_at timestamptz,
  p_reason text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, editorial, extensions, pg_temp
AS $$
DECLARE
  v_request_id uuid;
  v_id uuid;
BEGIN
  v_request_id := intake.resolve_response_request_id(p_token_hash);
  INSERT INTO intake.response_extension_requests(response_request_id, requested_due_at, reason)
  VALUES (v_request_id, p_requested_due_at, p_reason)
  RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

-- Direct writes are forbidden for service roles; only fixed-search-path functions are executable.
REVOKE ALL ON TABLE ops.audit_events, ops.audit_chain_heads, ops.outbox FROM
  gurine_control_api, gurine_submission_api, gurine_ingest_worker,
  gurine_analysis_worker, gurine_public_projector, gurine_notification_worker,
  gurine_workflow_worker, gurine_document_extractor, gurine_scheduler;

REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA intake FROM gurine_submission_api;
GRANT SELECT ON intake.response_access_tokens TO gurine_submission_api;

REVOKE ALL ON FUNCTION ops.append_audit_event(
  text,text,text,uuid,text,text,text,text,ops.audit_outcome,text,uuid,jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.enqueue_outbox(text,text,bigint,text,jsonb,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.resolve_response_request_id(char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.verify_response_access(char,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.save_response_draft(char,bigint,bytea,jsonb,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.create_response_attachment(char,bytea,text,bigint,char,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.finalize_response_attachment(char,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.delete_response_attachment(char,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.submit_response(char,bigint,char,bytea,jsonb,char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.request_response_extension(char,timestamptz,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION ops.append_audit_event(
  text,text,text,uuid,text,text,text,text,ops.audit_outcome,text,uuid,jsonb
) TO gurine_control_api, gurine_submission_api, gurine_ingest_worker,
     gurine_analysis_worker, gurine_public_projector, gurine_notification_worker,
     gurine_workflow_worker, gurine_document_extractor, gurine_scheduler;
GRANT EXECUTE ON FUNCTION ops.enqueue_outbox(text,text,bigint,text,jsonb,timestamptz)
  TO gurine_control_api, gurine_submission_api, gurine_ingest_worker,
     gurine_analysis_worker, gurine_public_projector, gurine_notification_worker,
     gurine_workflow_worker, gurine_document_extractor, gurine_scheduler;
GRANT EXECUTE ON FUNCTION intake.verify_response_access(char,boolean),
  intake.save_response_draft(char,bigint,bytea,jsonb,timestamptz),
  intake.create_response_attachment(char,bytea,text,bigint,char,text),
  intake.finalize_response_attachment(char,uuid),
  intake.delete_response_attachment(char,uuid),
  intake.submit_response(char,bigint,char,bytea,jsonb,char),
  intake.request_response_extension(char,timestamptz,text)
  TO gurine_submission_api;

COMMIT;
