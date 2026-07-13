BEGIN;

CREATE TABLE editorial.evidence_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence_id uuid NOT NULL REFERENCES editorial.evidence(id),
  target_type text NOT NULL CHECK (target_type IN ('HYPOTHESIS','CLAIM','RESPONSE','CASE')),
  target_id uuid NOT NULL,
  relation text NOT NULL CHECK (relation IN ('SUPPORTS','CONTRADICTS','CONTEXT','RESPONDS')),
  reason text NOT NULL,
  created_by uuid NOT NULL REFERENCES ops.users(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (evidence_id, target_type, target_id, relation)
);
CREATE INDEX evidence_links_target_idx ON editorial.evidence_links(target_type, target_id);

ALTER TABLE editorial.corrections
  ADD COLUMN replacement_content jsonb,
  ADD COLUMN priority text NOT NULL DEFAULT 'NORMAL'
    CHECK (priority IN ('LOW','NORMAL','HIGH','URGENT')),
  ADD COLUMN triage_decision text
    CHECK (triage_decision IS NULL OR triage_decision IN ('ACCEPT','REJECT','NEEDS_INFORMATION','DUPLICATE')),
  ADD COLUMN triage_reason text;

ALTER TABLE ops.tasks
  ADD COLUMN assignment_reason text,
  ADD COLUMN assigned_by uuid REFERENCES ops.users(id);

ALTER TABLE ops.source_runs
  ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK (version > 0);

ALTER TABLE ops.provider_configs
  ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK (version > 0);

-- Uploaded files are moved to CLEAN/INFECTED/FAILED only by the scanning worker.
CREATE OR REPLACE FUNCTION intake.record_response_attachment_scan(
  p_attachment_id uuid,
  p_scan_status text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  IF p_scan_status NOT IN ('CLEAN','INFECTED','FAILED') THEN
    RAISE EXCEPTION 'invalid_scan_status' USING ERRCODE = '22023';
  END IF;
  UPDATE intake.response_attachments
  SET scan_status = p_scan_status,
      upload_status = CASE WHEN p_scan_status = 'CLEAN' THEN 'FINALIZED' ELSE 'FAILED' END
  WHERE id = p_attachment_id
    AND upload_status = 'UPLOADED'
    AND scan_status = 'PENDING'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'attachment_not_found_or_invalid_state' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_id;
END
$$;
REVOKE ALL ON FUNCTION intake.record_response_attachment_scan(uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION intake.record_response_attachment_scan(uuid,text)
  TO gurine_workflow_worker;

-- Direct access to high-impact immutable or scoped records remains forbidden.
REVOKE INSERT, UPDATE, DELETE ON editorial.review_snapshots,
  editorial.review_decisions, editorial.publication_revisions
  FROM gurine_control_api, gurine_workflow_worker, gurine_analysis_worker,
       gurine_public_projector, gurine_notification_worker;
REVOKE INSERT, UPDATE, DELETE ON ops.audit_events, ops.audit_chain_heads
  FROM gurine_control_api, gurine_submission_api, gurine_ingest_worker,
       gurine_analysis_worker, gurine_public_projector, gurine_notification_worker,
       gurine_workflow_worker, gurine_document_extractor, gurine_scheduler;

COMMIT;
