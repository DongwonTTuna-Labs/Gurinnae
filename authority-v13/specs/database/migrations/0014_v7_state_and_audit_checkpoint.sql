BEGIN;

ALTER TYPE core.contract_status ADD VALUE IF NOT EXISTS 'SUPERSEDED';

ALTER TABLE raw.source_documents
  ADD COLUMN record_status text NOT NULL DEFAULT 'CURRENT'
  CHECK (record_status IN ('CURRENT','SUPERSEDED','DELETED_UPSTREAM'));

CREATE TABLE ops.audit_chain_checkpoints (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stream_key text NOT NULL REFERENCES ops.audit_chain_heads(stream_key),
  head_event_id uuid NOT NULL REFERENCES ops.audit_events(id),
  head_hash char(64) NOT NULL,
  signature_key_id text NOT NULL,
  signature_algorithm text NOT NULL CHECK (signature_algorithm = 'HMAC-SHA256'),
  signature char(64) NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (stream_key, head_event_id),
  UNIQUE (stream_key, head_hash)
);

CREATE TRIGGER audit_chain_checkpoints_immutable
  BEFORE UPDATE OR DELETE ON ops.audit_chain_checkpoints
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE OR REPLACE FUNCTION ops.record_audit_chain_checkpoint(
  p_stream_key text,
  p_head_event_id uuid,
  p_head_hash char(64),
  p_signature_key_id text,
  p_signature char(64)
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  PERFORM 1
  FROM ops.audit_chain_heads
  WHERE stream_key = p_stream_key
    AND head_event_id = p_head_event_id
    AND head_hash = p_head_hash
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'audit_chain_head_mismatch' USING ERRCODE = '40001';
  END IF;
  IF p_signature_key_id IS NULL OR p_signature_key_id = '' OR p_signature !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION 'invalid_audit_checkpoint_signature' USING ERRCODE = '22023';
  END IF;
  INSERT INTO ops.audit_chain_checkpoints(
    stream_key, head_event_id, head_hash, signature_key_id,
    signature_algorithm, signature
  ) VALUES (
    p_stream_key, p_head_event_id, p_head_hash, p_signature_key_id,
    'HMAC-SHA256', p_signature
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

REVOKE ALL ON FUNCTION ops.record_audit_chain_checkpoint(text,uuid,char,text,char) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_audit_chain_checkpoint(text,uuid,char,text,char)
  TO gurine_workflow_worker;
GRANT SELECT ON ops.audit_chain_checkpoints TO gurine_auditor;
REVOKE UPDATE, DELETE ON ops.audit_chain_checkpoints FROM
  gurine_control_api, gurine_submission_api, gurine_ingest_worker,
  gurine_analysis_worker, gurine_public_projector,
  gurine_notification_worker, gurine_workflow_worker,
  gurine_document_extractor, gurine_scheduler, gurine_auditor;

COMMIT;
