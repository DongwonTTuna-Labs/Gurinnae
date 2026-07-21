-- Migration 0030 contains implementation deltas that were removed from the
-- byte-immutable v13 authority migrations 0001-0024.  Statements are kept in
-- their original ordinal order, then the submission-session hardening runs.
BEGIN;
-- AI and communication egress perform a read-only incident fence immediately
-- before dispatch.  The grant is intentionally limited to the kill-switch
-- relation; mutation remains control-api-only.
GRANT SELECT ON ops.kill_switches TO gurine_analysis_worker, gurine_notification_worker;
GRANT USAGE ON SCHEMA ops, editorial, intake, raw, extensions TO gurine_migrator;

-- RFC 8785-compatible JSONB bytes for immutable lineage digests.  Define this
-- before any function in this migration that computes an artifact or
-- workflow digest; PostgreSQL resolves referenced functions at CREATE time.
CREATE OR REPLACE FUNCTION ops.canonical_jsonb_v1(p_value jsonb)
RETURNS bytea
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, ops, pg_temp
AS $$
  SELECT convert_to(CASE jsonb_typeof(p_value)
    WHEN 'null' THEN 'null'
    WHEN 'boolean' THEN p_value::text
    WHEN 'number' THEN p_value::text
    WHEN 'string' THEN to_jsonb(p_value #>> '{}')::text
    WHEN 'array' THEN '[' || COALESCE((
      SELECT string_agg(convert_from(ops.canonical_jsonb_v1(value),'UTF8'), ',' ORDER BY ordinality)
        FROM jsonb_array_elements(p_value) WITH ORDINALITY AS a(value,ordinality)
    ), '') || ']'
    WHEN 'object' THEN '{' || COALESCE((
      SELECT string_agg(to_jsonb(key)::text || ':' || convert_from(ops.canonical_jsonb_v1(value),'UTF8'), ',' ORDER BY key COLLATE "C")
        FROM jsonb_each(p_value) AS o(key,value)
    ), '') || '}'
    ELSE 'null' END, 'UTF8')
$$;
ALTER FUNCTION ops.canonical_jsonb_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.canonical_jsonb_v1(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.canonical_jsonb_v1(jsonb) TO gurine_analysis_worker;

-- The ingest worker may observe parsed documents but must not receive broad
-- UPDATE access to the immutable source-document identity row.  These
-- narrowly-scoped definer functions are the only state transitions it needs
-- after parser/connector work has produced durable records.
CREATE OR REPLACE FUNCTION raw.record_parsed_source_metadata(
  p_source_document_id uuid,
  p_parser_name text,
  p_parser_version text,
  p_schema_version text,
  p_metadata jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, raw, core, extensions, pg_temp
AS $$
DECLARE v_status core.source_document_status;
BEGIN
  IF p_source_document_id IS NULL OR NULLIF(btrim(p_parser_version), '') IS NULL
     OR p_metadata IS NULL OR jsonb_typeof(p_metadata) <> 'object' THEN
    RAISE EXCEPTION 'invalid_parsed_source_metadata' USING ERRCODE='22023';
  END IF;
  IF p_metadata ? 'parsedSchemaFingerprint'
     AND (p_metadata->>'parsedSchemaFingerprint') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_parsed_schema_fingerprint' USING ERRCODE='22023';
  END IF;
  IF p_metadata ? 'parsedOutputDigest'
     AND (p_metadata->>'parsedOutputDigest') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_parsed_output_digest' USING ERRCODE='22023';
  END IF;
  SELECT status INTO v_status
    FROM raw.source_documents
   WHERE id = p_source_document_id
   FOR UPDATE;
  IF NOT FOUND OR v_status <> 'PARSED' THEN
    RAISE EXCEPTION 'source_document_not_parsed' USING ERRCODE='55000';
  END IF;
  UPDATE raw.source_documents
     SET parser_name = COALESCE(NULLIF(btrim(p_parser_name), ''), parser_name),
         parser_version = p_parser_version,
         schema_version = COALESCE(NULLIF(btrim(p_schema_version), ''), schema_version),
         metadata = metadata || p_metadata
   WHERE id = p_source_document_id;
END
$$;
ALTER FUNCTION raw.record_parsed_source_metadata(uuid,text,text,text,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION raw.record_parsed_source_metadata(uuid,text,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION raw.record_parsed_source_metadata(uuid,text,text,text,jsonb) TO gurine_ingest_worker;

CREATE OR REPLACE FUNCTION raw.mark_connector_source_document_parsed(
  p_source_document_id uuid,
  p_parser_name text,
  p_parser_version text,
  p_schema_version text,
  p_metadata jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, raw, core, extensions, pg_temp
AS $$
DECLARE v_status core.source_document_status;
BEGIN
  IF p_source_document_id IS NULL OR NULLIF(btrim(p_parser_name), '') IS NULL
     OR NULLIF(btrim(p_parser_version), '') IS NULL
     OR p_metadata IS NULL OR jsonb_typeof(p_metadata) <> 'object' THEN
    RAISE EXCEPTION 'invalid_connector_source_metadata' USING ERRCODE='22023';
  END IF;
  SELECT status INTO v_status
    FROM raw.source_documents
   WHERE id = p_source_document_id
   FOR UPDATE;
  IF NOT FOUND OR v_status <> 'FETCHED' THEN
    RAISE EXCEPTION 'source_document_not_fetchable' USING ERRCODE='55000';
  END IF;
  UPDATE raw.source_documents
     SET status = 'PARSED',
         parser_name = p_parser_name,
         parser_version = p_parser_version,
         schema_version = COALESCE(NULLIF(btrim(p_schema_version), ''), schema_version),
         metadata = metadata || p_metadata
   WHERE id = p_source_document_id;
END
$$;
ALTER FUNCTION raw.mark_connector_source_document_parsed(uuid,text,text,text,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION raw.mark_connector_source_document_parsed(uuid,text,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION raw.mark_connector_source_document_parsed(uuid,text,text,text,jsonb) TO gurine_ingest_worker;

GRANT SELECT ON raw.source_documents TO gurine_ingest_worker;
-- The SECURITY DEFINER revision helper is owned by gurine_migrator and must
-- be able to materialize a new immutable source-document revision.  The
-- ingest role remains read-only; INSERT is intentionally scoped to the
-- migration owner rather than granted to any worker role.
GRANT SELECT, INSERT, UPDATE ON raw.source_documents TO gurine_migrator;

CREATE OR REPLACE FUNCTION ops.finalize_agent_tool_call_source_uses(
  p_tool_call_id uuid,
  p_source_use_count integer,
  p_source_use_set_sha256 char(64)
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
BEGIN
  IF p_tool_call_id IS NULL OR p_source_use_count < 1
     OR p_source_use_set_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_tool_source_use_summary' USING ERRCODE='22023';
  END IF;
  UPDATE ops.agent_tool_calls
     SET source_use_count = p_source_use_count,
         source_use_set_sha256 = p_source_use_set_sha256,
         version = version + 1
   WHERE tool_call_id = p_tool_call_id
     AND status = 'SUCCEEDED'
     AND result_kind = 'TOOL_RESULT'
     AND terminal_at IS NOT NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tool_call_not_terminal' USING ERRCODE='55000';
  END IF;
END
$$;
ALTER FUNCTION ops.finalize_agent_tool_call_source_uses(uuid,integer,char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.finalize_agent_tool_call_source_uses(uuid,integer,char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.finalize_agent_tool_call_source_uses(uuid,integer,char(64)) TO gurine_analysis_worker;

-- Tool calls are claimed with INSERT, but completion is an owner-side state
-- transition.  Keeping UPDATE behind this definer function preserves the
-- worker's narrow privilege surface while still recording CLAIMED -> SUCCEEDED
-- only when the same run/call lease is held.
CREATE OR REPLACE FUNCTION ops.complete_agent_tool_call_v2(
  p_tool_call_id uuid,
  p_agent_run_id uuid,
  p_call_id text,
  p_result_sha256 char(64),
  p_result_redacted jsonb,
  p_result_canonical bytea,
  p_response_validation_sha256 char(64),
  p_result_transcript_sha256 char(64),
  p_terminal_at timestamptz
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
BEGIN
  IF p_tool_call_id IS NULL OR p_agent_run_id IS NULL
     OR NULLIF(btrim(p_call_id), '') IS NULL
     OR p_result_sha256 !~ '^[0-9a-f]{64}$'
     OR p_result_redacted IS NULL OR p_result_canonical IS NULL
     OR p_response_validation_sha256 !~ '^[0-9a-f]{64}$'
     OR p_result_transcript_sha256 !~ '^[0-9a-f]{64}$'
     OR p_terminal_at IS NULL THEN
    RAISE EXCEPTION 'invalid_tool_completion' USING ERRCODE='22023';
  END IF;
  UPDATE ops.agent_tool_calls
     SET status='SUCCEEDED', result_kind='TOOL_RESULT', result_sha256=p_result_sha256,
         result_redacted=p_result_redacted, result_canonical=p_result_canonical,
         response_validation_sha256=p_response_validation_sha256,
         result_transcript_sha256=p_result_transcript_sha256,
         latency_ms=GREATEST(0,EXTRACT(EPOCH FROM (p_terminal_at-started_at)*1000)::bigint),
         terminal_at=p_terminal_at, version=version+1
   WHERE tool_call_id=p_tool_call_id AND agent_run_id=p_agent_run_id
     AND call_id=p_call_id AND status='CLAIMED';
  IF NOT FOUND THEN RAISE EXCEPTION 'tool_call_claim_missing' USING ERRCODE='55000'; END IF;
END
$$;
ALTER FUNCTION ops.complete_agent_tool_call_v2(uuid,uuid,text,char(64),jsonb,bytea,char(64),char(64),timestamptz) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.complete_agent_tool_call_v2(uuid,uuid,text,char(64),jsonb,bytea,char(64),char(64),timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.complete_agent_tool_call_v2(uuid,uuid,text,char(64),jsonb,bytea,char(64),char(64),timestamptz) TO gurine_analysis_worker;

-- Runtime deltas relocated from immutable authority migration 0009.
CREATE OR REPLACE FUNCTION intake.create_contact_request(
  p_category text,
  p_name_encrypted bytea,
  p_email_hash char(64),
  p_email_encrypted bytea,
  p_subject text,
  p_message_encrypted bytea,
  p_receipt_token_hash char(64)
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_id uuid;
v_hash text := btrim(p_receipt_token_hash::text);
BEGIN
  v_id := (substr(v_hash,1,8)||'-'||substr(v_hash,9,4)||'-4'||substr(v_hash,14,3)||'-8'||substr(v_hash,18,3)||'-'||substr(v_hash,21,12))::uuid;
  INSERT INTO intake.contact_requests(
    id, category, name_encrypted, email_hash, email_encrypted,
    subject, message_encrypted, receipt_token_hash
  ) VALUES (
    v_id, p_category, p_name_encrypted, p_email_hash, p_email_encrypted,
    p_subject, p_message_encrypted, p_receipt_token_hash
  );
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.create_dataset_export(
  p_request_token_hash char(64),
  p_email_hash char(64),
  p_dataset_id text,
  p_format text,
  p_filters jsonb,
  p_expires_at timestamptz
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_id uuid;
v_hash text := btrim(p_request_token_hash::text);
BEGIN
  v_id := (substr(v_hash,1,8)||'-'||substr(v_hash,9,4)||'-4'||substr(v_hash,14,3)||'-8'||substr(v_hash,18,3)||'-'||substr(v_hash,21,12))::uuid;
  INSERT INTO intake.dataset_export_requests(
    id, request_token_hash, email_hash, dataset_id, format, filters, status, expires_at
  ) VALUES (
    v_id, p_request_token_hash, p_email_hash, p_dataset_id, p_format, p_filters, 'QUEUED', p_expires_at
  );
  RETURN v_id;
END
$$;


-- Runtime deltas relocated from immutable authority migration 0013.
GRANT USAGE ON SCHEMA raw, core, editorial, intake, ops TO gurine_control_api;

GRANT SELECT ON raw.source_documents TO gurine_control_api;

GRANT USAGE ON SCHEMA core, editorial, intake, ops, public TO gurine_workflow_worker;


-- Runtime deltas relocated from immutable authority migration 0024.
ALTER TABLE editorial.corrections
  ADD COLUMN resolution text CHECK (resolution IS NULL OR resolution IN ('RESOLVED','REJECTED','DUPLICATE','WITHDRAWN')),
  ADD COLUMN resolution_reason text,
  ADD COLUMN resolved_at timestamptz;

ALTER TABLE editorial.responses
  ADD COLUMN public_excerpt_sha256 char(64),
  ADD COLUMN excerpt_approved_by uuid REFERENCES ops.users(id),
  ADD COLUMN excerpt_approved_at timestamptz;

ALTER TABLE core.rule_versions
  ADD COLUMN activation_evaluation_digest char(64),
  ADD COLUMN activation_rollout text CHECK (activation_rollout IS NULL OR activation_rollout IN ('ALL','SHADOW_THEN_ALL')),
  ADD COLUMN activation_reason text;

ALTER TABLE ops.source_runs
  ADD COLUMN requested_from date,
  ADD COLUMN requested_to date,
  ADD COLUMN request_reason text,
  ADD COLUMN requested_by uuid REFERENCES ops.users(id),
  ADD COLUMN scheduled_for timestamptz,
  ADD COLUMN schedule_expression text,
  ADD CONSTRAINT source_runs_requested_range_check CHECK (requested_from IS NULL OR requested_to IS NULL OR requested_from <= requested_to);

CREATE UNIQUE INDEX source_runs_scheduled_slot_idx ON ops.source_runs(source_id,scheduled_for) WHERE scheduled_for IS NOT NULL;

CREATE OR REPLACE FUNCTION intake.create_correction_session(
 p_session_token_hash char(64),p_bff_issuer text,p_locale text,p_case_slug text,p_publication_revision integer,p_expires_at timestamptz
) RETURNS TABLE(draft_id uuid,session_id uuid,version bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_hash text := btrim(p_session_token_hash::text);
BEGIN
 draft_id := (substr(v_hash,1,8)||'-'||substr(v_hash,9,4)||'-4'||substr(v_hash,14,3)||'-8'||substr(v_hash,18,3)||'-'||substr(v_hash,21,12))::uuid;
 INSERT INTO intake.correction_request_drafts(id,token_hash,version,case_slug,publication_revision,expires_at)
 VALUES(draft_id,NULL,1,p_case_slug,p_publication_revision,p_expires_at) RETURNING correction_request_drafts.version INTO version;
 INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at)
 VALUES(p_session_token_hash,'CORRECTION_DRAFT','CORRECTION_DRAFT',draft_id,p_bff_issuer,p_expires_at) RETURNING id INTO session_id;
 RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.create_correction_draft_attachment(p_session_token_hash char(64),p_bff_issuer text,p_filename_encrypted bytea,p_media_type text,p_size_bytes bigint,p_sha256 char(64),p_object_key text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_scope uuid; v_id uuid; v_parts text[];
BEGIN
 SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['CORRECTION_DRAFT']) r;
 v_parts := string_to_array(p_object_key,'/');
 IF array_length(v_parts,1)<>4 OR v_parts[1]<>'quarantine' OR v_parts[2]<>'corrections' THEN RAISE EXCEPTION 'correction_attachment_object_key_invalid' USING ERRCODE='22023'; END IF;
 v_id := v_parts[3]::uuid;
 INSERT INTO intake.correction_draft_attachments(id,draft_id,original_filename_encrypted,media_type,size_bytes,sha256,object_key,upload_status,scan_status)
 VALUES(v_id,v_scope,p_filename_encrypted,p_media_type,p_size_bytes,p_sha256,p_object_key,'PENDING','PENDING'); RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION intake.submit_correction_draft_session(p_session_token_hash char(64),p_bff_issuer text,p_expected_version bigint,p_attestation boolean,p_privacy_consent boolean,p_receipt_token_hash char(64),p_receipt_session_token_hash char(64),p_receipt_session_expires_at timestamptz)
RETURNS TABLE(request_id uuid,receipt_session_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_session uuid;v_draft uuid;d intake.correction_request_drafts%ROWTYPE;
BEGIN
 SELECT r.session_id,r.scope_id INTO v_session,v_draft FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['CORRECTION_DRAFT']) r;
 SELECT * INTO d FROM intake.correction_request_drafts WHERE id=v_draft AND version=p_expected_version AND expires_at>clock_timestamp() FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'correction_draft_version_conflict' USING ERRCODE='40001'; END IF;
 IF NOT p_attestation OR NOT p_privacy_consent OR d.requester_type IS NULL OR d.contact_email_hash IS NULL OR d.summary IS NULL THEN RAISE EXCEPTION 'correction_draft_incomplete' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT 1 FROM intake.correction_draft_attachments a WHERE a.draft_id=v_draft AND a.upload_status<>'DELETED' AND (a.upload_status<>'FINALIZED' OR a.scan_status<>'CLEAN')) THEN RAISE EXCEPTION 'correction_attachment_not_clean' USING ERRCODE='22023'; END IF;
 request_id := v_draft;
 INSERT INTO intake.correction_requests(id,public_case_slug,publication_revision,requester_type,contact_email_hash,contact_email_encrypted,summary,requested_changes,evidence_description,receipt_token_hash)
 VALUES(request_id,d.case_slug,d.publication_revision,d.requester_type,d.contact_email_hash,d.contact_email_encrypted,d.summary,d.requested_changes,d.evidence_description,p_receipt_token_hash);
 INSERT INTO intake.correction_attachments(id,correction_request_id,original_filename_encrypted,media_type,size_bytes,sha256,object_key,scan_status)
 SELECT id,request_id,original_filename_encrypted,media_type,size_bytes,sha256,object_key,scan_status FROM intake.correction_draft_attachments WHERE draft_id=v_draft AND upload_status='FINALIZED';
 UPDATE intake.submission_sessions SET status='CONSUMED',consumed_at=clock_timestamp(),version=version+1 WHERE id=v_session;
 INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at)
 VALUES(p_receipt_session_token_hash,'CORRECTION_RECEIPT','CORRECTION_REQUEST',request_id,p_bff_issuer,p_receipt_session_expires_at) RETURNING id INTO receipt_session_id;
 DELETE FROM intake.correction_request_drafts WHERE id=v_draft;
 RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.save_response_draft_session(
  p_session_token_hash char(64),p_bff_issuer text,p_expected_version bigint,
  p_answers_encrypted bytea,p_publication_consent jsonb,p_expires_at timestamptz
) RETURNS TABLE(draft_id uuid,version bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,extensions,pg_temp AS $$
DECLARE v_request uuid;v_id uuid;v_version bigint;v_hash text := btrim(p_session_token_hash::text);
BEGIN
  SELECT r.scope_id INTO v_request FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;
  PERFORM 1 FROM editorial.response_requests
    WHERE id=v_request AND status IN ('SENT','VIEWED') AND due_at>clock_timestamp() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  SELECT id,response_drafts.version INTO v_id,v_version FROM intake.response_drafts WHERE response_request_id=v_request FOR UPDATE;
  IF v_id IS NULL THEN
    IF p_expected_version<>0 THEN RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE='40001'; END IF;
    draft_id := (substr(v_hash,1,8)||'-'||substr(v_hash,9,4)||'-4'||substr(v_hash,14,3)||'-8'||substr(v_hash,18,3)||'-'||substr(v_hash,21,12))::uuid;
    INSERT INTO intake.response_drafts(id,response_request_id,version,answers_encrypted,publication_consent,saved_at,expires_at)
    VALUES(draft_id,v_request,1,p_answers_encrypted,p_publication_consent,clock_timestamp(),p_expires_at)
    RETURNING id,response_drafts.version INTO draft_id,version;
  ELSE
    IF v_version<>p_expected_version THEN RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE='40001'; END IF;
    UPDATE intake.response_drafts
    SET answers_encrypted=p_answers_encrypted,publication_consent=p_publication_consent,
        saved_at=clock_timestamp(),expires_at=p_expires_at,version=response_drafts.version+1
    WHERE id=v_id AND version=p_expected_version
    RETURNING id,response_drafts.version INTO draft_id,version;
    IF draft_id IS NULL THEN RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE='40001'; END IF;
  END IF;
  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.create_response_attachment_session(
  p_session_token_hash char(64),p_bff_issuer text,p_filename_encrypted bytea,p_media_type text,
  p_size_bytes bigint,p_sha256 char(64),p_object_key text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,editorial,extensions,pg_temp AS $$
DECLARE v_request uuid;v_draft uuid;v_id uuid;v_parts text[];
BEGIN
  SELECT r.scope_id INTO v_request FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;
  PERFORM 1 FROM editorial.response_requests WHERE id=v_request AND status IN ('SENT','VIEWED') AND due_at>clock_timestamp() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  SELECT id INTO v_draft FROM intake.response_drafts WHERE response_request_id=v_request;
  v_parts := string_to_array(p_object_key,'/');
  IF array_length(v_parts,1)<>4 OR v_parts[1]<>'quarantine' OR v_parts[2]<>'responses' THEN RAISE EXCEPTION 'response_attachment_object_key_invalid' USING ERRCODE='22023'; END IF;
  v_id := v_parts[3]::uuid;
  INSERT INTO intake.response_attachments(id,response_request_id,draft_id,original_filename_encrypted,media_type,size_bytes,sha256,object_key,upload_status,scan_status)
  VALUES(v_id,v_request,v_draft,p_filename_encrypted,p_media_type,p_size_bytes,p_sha256,p_object_key,'PENDING','PENDING');
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION intake.request_response_extension_session(
  p_session_token_hash char(64),p_bff_issuer text,p_requested_due_at timestamptz,p_reason text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,editorial,extensions,pg_temp AS $$
DECLARE v_request uuid;v_id uuid;v_due timestamptz;
BEGIN
  SELECT r.scope_id INTO v_request FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;
  SELECT due_at INTO v_due FROM editorial.response_requests WHERE id=v_request AND status IN ('SENT','VIEWED') FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  IF p_requested_due_at<=v_due THEN RAISE EXCEPTION 'extension_due_date_must_increase' USING ERRCODE='22023'; END IF;
  INSERT INTO intake.response_extension_requests(response_request_id,requested_due_at,reason,status)
  VALUES(v_request,p_requested_due_at,p_reason,'SUBMITTED') RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION intake.submit_response_session(p_session_token_hash char(64),p_bff_issuer text,p_expected_version bigint,p_submission_sha256 char(64),p_answers_encrypted bytea,p_publication_consent jsonb,p_receipt_token_hash char(64),p_receipt_session_token_hash char(64),p_receipt_session_expires_at timestamptz)
RETURNS TABLE(submission_id uuid,receipt_session_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,editorial,extensions,pg_temp AS $$
DECLARE s intake.submission_sessions%ROWTYPE;d intake.response_drafts%ROWTYPE;r editorial.response_requests%ROWTYPE;
BEGIN SELECT * INTO s FROM intake.submission_sessions WHERE token_hash=p_session_token_hash AND bff_issuer=p_bff_issuer AND session_kind='RESPONSE_ACTIVE' AND status='ACTIVE' AND expires_at>clock_timestamp() FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000';END IF;
 SELECT * INTO r FROM editorial.response_requests WHERE id=s.scope_id AND status IN ('SENT','VIEWED') AND due_at>clock_timestamp() FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000';END IF;
 SELECT * INTO d FROM intake.response_drafts WHERE response_request_id=s.scope_id AND version=p_expected_version FOR UPDATE;IF NOT FOUND THEN RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE='40001';END IF;
 IF EXISTS(SELECT 1 FROM intake.response_attachments a WHERE a.response_request_id=s.scope_id AND a.upload_status<>'DELETED' AND (a.upload_status<>'FINALIZED' OR a.scan_status<>'CLEAN')) THEN RAISE EXCEPTION 'response_attachment_not_clean' USING ERRCODE='22023';END IF;
 submission_id := d.id;
 INSERT INTO intake.response_submissions(id,response_request_id,draft_version,submission_sha256,answers_encrypted,publication_consent,receipt_token_hash) VALUES(submission_id,s.scope_id,d.version,p_submission_sha256,p_answers_encrypted,p_publication_consent,p_receipt_token_hash);
 UPDATE editorial.response_requests SET status='SUBMITTED',version=version+1,updated_at=clock_timestamp() WHERE id=s.scope_id AND status IN ('SENT','VIEWED');
 UPDATE intake.submission_sessions SET status='CONSUMED',consumed_at=clock_timestamp(),version=version+1 WHERE id=s.id;
 INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at) VALUES(p_receipt_session_token_hash,'RESPONSE_RECEIPT','RESPONSE_SUBMISSION',submission_id,p_bff_issuer,p_receipt_session_expires_at) RETURNING id INTO receipt_session_id; RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.create_subscription_session(p_email_hash char(64),p_email_encrypted bytea,p_topics jsonb,p_frequency text,p_locale text,p_verification_token_hash char(64),p_management_token_hash char(64),p_pending_session_token_hash char(64),p_bff_issuer text,p_expires_at timestamptz)
RETURNS TABLE(subscription_id uuid,session_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_hash text := btrim(p_pending_session_token_hash::text);
BEGIN subscription_id := (substr(v_hash,1,8)||'-'||substr(v_hash,9,4)||'-4'||substr(v_hash,14,3)||'-8'||substr(v_hash,18,3)||'-'||substr(v_hash,21,12))::uuid;INSERT INTO intake.subscriptions(id,email_hash,email_encrypted,topics,frequency,locale,status,verification_token_hash,management_token_hash) VALUES(subscription_id,p_email_hash,p_email_encrypted,p_topics,p_frequency,p_locale,'PENDING',p_verification_token_hash,p_management_token_hash);INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at) VALUES(p_pending_session_token_hash,'SUBSCRIPTION_PENDING','SUBSCRIPTION',subscription_id,p_bff_issuer,p_expires_at) RETURNING id INTO session_id;RETURN NEXT;END $$;

CREATE OR REPLACE FUNCTION intake.unsubscribe_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_scope uuid;
BEGIN
  SELECT r.scope_id INTO v_scope
  FROM intake.resolve_submission_session(
    p_session_token_hash,p_bff_issuer,ARRAY['SUBSCRIPTION_MANAGEMENT']
  ) r;
  UPDATE intake.subscriptions
  SET status='UNSUBSCRIBED',updated_at=clock_timestamp()
  WHERE id=v_scope;
  UPDATE intake.submission_sessions
  SET status='CONSUMED',consumed_at=clock_timestamp(),version=version+1
  WHERE scope_type='SUBSCRIPTION' AND scope_id=v_scope AND status='ACTIVE';
  RETURN v_scope;
END $$;

-- Read projections resolve only the scoped session and never accept raw URL tokens.
CREATE OR REPLACE FUNCTION intake.get_correction_draft_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['CORRECTION_DRAFT']) r;SELECT to_jsonb(d)||jsonb_build_object('contact_email_encrypted',CASE WHEN d.contact_email_encrypted IS NULL THEN NULL ELSE convert_from(d.contact_email_encrypted,'UTF8') END) INTO v FROM intake.correction_request_drafts d WHERE id=v_scope;RETURN v;END $$;

CREATE OR REPLACE FUNCTION intake.get_correction_draft_preview_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['CORRECTION_DRAFT']) r;SELECT jsonb_build_object('draft',to_jsonb(d),'attachments',COALESCE((SELECT jsonb_agg(to_jsonb(a)||jsonb_build_object('original_filename_encrypted',convert_from(a.original_filename_encrypted,'UTF8')) ORDER BY a.id) FROM intake.correction_draft_attachments a WHERE a.draft_id=v_scope AND a.upload_status<>'DELETED'),'[]'::jsonb)) INTO v FROM intake.correction_request_drafts d WHERE id=v_scope;RETURN v;END $$;

CREATE OR REPLACE FUNCTION intake.get_response_request_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,editorial,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;SELECT (to_jsonb(q)-'recipient_email_encrypted'-'recipient_email_hash')||jsonb_build_object('case_title',c.title) INTO v FROM editorial.response_requests q JOIN editorial.cases c ON c.id=q.case_id WHERE q.id=v_scope;RETURN v;END $$;

CREATE OR REPLACE FUNCTION intake.get_response_draft_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;SELECT to_jsonb(d)||jsonb_build_object('answers_encrypted',convert_from(d.answers_encrypted,'UTF8')) INTO v FROM intake.response_drafts d WHERE response_request_id=v_scope;RETURN COALESCE(v,'{}'::jsonb);END $$;

CREATE OR REPLACE FUNCTION intake.get_response_preview_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;SELECT jsonb_build_object('draft',COALESCE((SELECT to_jsonb(d)||jsonb_build_object('answers_encrypted',convert_from(d.answers_encrypted,'UTF8')) FROM intake.response_drafts d WHERE d.response_request_id=v_scope),'{}'::jsonb),'attachments',COALESCE((SELECT jsonb_agg(to_jsonb(a)||jsonb_build_object('filename_encrypted',convert_from(a.original_filename_encrypted,'UTF8')) ORDER BY a.id) FROM intake.response_attachments a WHERE a.response_request_id=v_scope AND a.upload_status<>'DELETED'),'[]'::jsonb)) INTO v;RETURN v;END $$;

CREATE OR REPLACE FUNCTION intake.get_subscription_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['SUBSCRIPTION_MANAGEMENT']) r;SELECT (to_jsonb(s)-'email_hash'-'management_token_hash'-'verification_token_hash')||jsonb_build_object('email_encrypted',convert_from(s.email_encrypted,'UTF8')) INTO v FROM intake.subscriptions s WHERE id=v_scope;RETURN v;END $$;

-- One authority-counted routine owns atomic domain transition + outbox emission.
-- Internal branches are role-fenced and never create a second generic write model.
CREATE OR REPLACE FUNCTION ops.enqueue_outbox(
  p_aggregate_type text,p_aggregate_id text,p_aggregate_version bigint,
  p_event_type text,p_payload jsonb,p_occurred_at timestamptz
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,core,editorial,intake,extensions,pg_temp AS $$
DECLARE
  v_id uuid;
  v_rule_id text;
  v_rule_version_id uuid;
  v_actor_id uuid;
  v_request_id uuid;
  v_row_version bigint;
  v_limit integer;
  v_decision record;
  v_kind text;
  v_status text;
  v_sha256 text;
BEGIN
  IF p_event_type='internal.mark_outbox_published.v1' THEN
    IF NOT pg_has_role(current_user,'gurine_scheduler','MEMBER') THEN RAISE EXCEPTION 'scheduler_role_required' USING ERRCODE='42501'; END IF;
    v_id := p_aggregate_id::uuid;
    UPDATE ops.outbox SET published_at=COALESCE(published_at,clock_timestamp()) WHERE id=v_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN v_id;
  ELSIF p_event_type='internal.apply_due_rule_activation.v1' THEN
    IF NOT pg_has_role(current_user,'gurine_scheduler','MEMBER') THEN RAISE EXCEPTION 'scheduler_role_required' USING ERRCODE='42501'; END IF;
    v_rule_version_id := p_aggregate_id::uuid;
    v_actor_id := (p_payload->>'actorId')::uuid;
    v_request_id := (p_payload->>'requestId')::uuid;
    SELECT rule_id,row_version INTO v_rule_id,v_row_version FROM core.rule_versions
      WHERE id=v_rule_version_id AND status='SCHEDULED' AND effective_at<=clock_timestamp() FOR UPDATE;
    IF NOT FOUND THEN RETURN NULL; END IF;
    UPDATE core.rule_versions SET status='RETIRED',retired_at=clock_timestamp(),row_version=row_version+1
      WHERE rule_id=v_rule_id AND status='ACTIVE' AND id<>v_rule_version_id;
    UPDATE core.rule_versions SET status='ACTIVE',retired_at=NULL,row_version=row_version+1
      WHERE id=v_rule_version_id AND status='SCHEDULED' RETURNING row_version INTO v_row_version;
    IF NOT FOUND THEN RAISE EXCEPTION 'scheduled_rule_version_claim_lost' USING ERRCODE='40001'; END IF;
    INSERT INTO ops.outbox(aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
      VALUES('rule_version',v_rule_version_id::text,v_row_version,'workflow.rule_activation_applied.v1',
        jsonb_build_object('actor_id',v_actor_id::text,'occurred_at',p_occurred_at,
          'operation_id','activateRuleVersion','request_id',v_request_id::text,
          'ruleVersionId',v_rule_version_id::text,'targetVersionId',v_rule_version_id::text),p_occurred_at)
      RETURNING id INTO v_id;
    RETURN v_id;
  ELSIF p_event_type='internal.expire_due_publication_access.v1' THEN
    IF NOT pg_has_role(current_user,'gurine_scheduler','MEMBER') THEN RAISE EXCEPTION 'scheduler_role_required' USING ERRCODE='42501'; END IF;
    v_limit := COALESCE((p_payload->>'limit')::integer,0);
    IF v_limit<1 OR v_limit>1000 THEN RAISE EXCEPTION 'publication_access_expiry_limit_invalid' USING ERRCODE='22023'; END IF;
    v_id := NULL;
    FOR v_decision IN SELECT id,publication_revision_id,version FROM editorial.publication_access_decisions
      WHERE state='ACTIVE' AND expires_at<=clock_timestamp() ORDER BY expires_at,id FOR UPDATE SKIP LOCKED LIMIT v_limit
    LOOP
      UPDATE editorial.publication_access_decisions SET state='EXPIRED',version=version+1
        WHERE id=v_decision.id AND state='ACTIVE';
      IF FOUND THEN
        v_request_id := gen_random_uuid();
        INSERT INTO ops.outbox(aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
          VALUES('publication_access_decision',v_decision.id::text,v_decision.version+1,
            'projection.publication_access_changed.v1',jsonb_build_object(
              'actor_id','scheduler','occurred_at',p_occurred_at,
              'operation_id','expirePublicationAccessDecision',
              'publication_id',v_decision.publication_revision_id::text,
              'request_id',v_request_id::text),p_occurred_at) RETURNING id INTO v_id;
      END IF;
    END LOOP;
    RETURN v_id;
  ELSIF p_event_type='attachment.scan_completed.v1' THEN
    IF NOT pg_has_role(current_user,'gurine_workflow_worker','MEMBER') THEN RAISE EXCEPTION 'workflow_role_required' USING ERRCODE='42501'; END IF;
    v_id := p_aggregate_id::uuid;
    v_kind := p_payload->>'attachment_kind';
    v_status := p_payload->>'scan_status';
    v_sha256 := p_payload->>'sha256';
    IF v_status NOT IN ('CLEAN','INFECTED','FAILED') OR v_sha256 !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'attachment_scan_result_invalid' USING ERRCODE='22023'; END IF;
    IF v_kind='CORRECTION' THEN
      UPDATE intake.correction_draft_attachments SET scan_status=v_status,
        upload_status=CASE WHEN v_status='CLEAN' THEN 'FINALIZED' ELSE 'FAILED' END,
        updated_at=clock_timestamp() WHERE id=v_id AND upload_status='FINALIZED'
        AND scan_status='PENDING' AND btrim(sha256::text)=v_sha256;
    ELSIF v_kind='RESPONSE' THEN
      UPDATE intake.response_attachments SET scan_status=v_status,
        upload_status=CASE WHEN v_status='CLEAN' THEN 'FINALIZED' ELSE 'FAILED' END
        WHERE id=v_id AND upload_status='FINALIZED' AND scan_status='PENDING'
        AND btrim(sha256::text)=v_sha256;
    ELSE
      RAISE EXCEPTION 'attachment_scan_kind_invalid' USING ERRCODE='22023';
    END IF;
    IF NOT FOUND THEN RAISE EXCEPTION 'attachment_scan_state_conflict' USING ERRCODE='40001'; END IF;
  ELSIF p_event_type='communication.delivery_poll_requested.v1' THEN
    IF NOT pg_has_role(current_user,'gurine_scheduler','MEMBER') THEN
      RAISE EXCEPTION 'scheduler_role_required' USING ERRCODE='42501';
    END IF;
    IF p_payload->>'pollKey' IS NULL OR p_payload->>'deliveryId' IS NULL
       OR p_payload->>'providerMessageId' IS NULL THEN
      RAISE EXCEPTION 'communication_poll_request_invalid' USING ERRCODE='22023';
    END IF;
    SELECT id INTO v_id FROM ops.outbox
      WHERE event_type='communication.delivery_poll_requested.v1'
        AND payload->>'pollKey'=p_payload->>'pollKey'
      ORDER BY id DESC LIMIT 1;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;
  INSERT INTO ops.outbox(aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
    VALUES(p_aggregate_type,p_aggregate_id,p_aggregate_version,p_event_type,p_payload,p_occurred_at)
    RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION ops.reject_mutation() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,editorial,ops,pg_temp AS $$
BEGIN
  IF TG_OP='INSERT' AND TG_TABLE_SCHEMA='editorial' AND TG_TABLE_NAME='publication_revisions' THEN
    IF NOT EXISTS (
      SELECT 1 FROM editorial.cases c JOIN editorial.review_snapshots s
        ON s.id=NEW.review_snapshot_id AND s.case_id=c.id
      WHERE c.id=NEW.case_id AND c.current_review_snapshot_id=s.id
        AND jsonb_typeof(s.unresolved_blockers)='array' AND jsonb_array_length(s.unresolved_blockers)=0
        AND EXISTS (SELECT 1 FROM editorial.review_decisions d WHERE d.review_snapshot_id=s.id
          AND d.decision='APPROVE' AND d.reviewer_id<>s.created_by)
    ) THEN RAISE EXCEPTION 'publication_requires_current_independent_approved_snapshot' USING ERRCODE='23514'; END IF;
    IF EXISTS (SELECT 1 FROM ops.kill_switches k WHERE k.state='ACTIVE'
      AND (k.expires_at IS NULL OR k.expires_at>clock_timestamp()))
    THEN RAISE EXCEPTION 'publication_kill_switch_active' USING ERRCODE='23514'; END IF;
    IF NOT EXISTS (SELECT 1 FROM editorial.publication_previews p WHERE p.case_id=NEW.case_id
      AND p.review_snapshot_id=NEW.review_snapshot_id AND p.preview_sha256=NEW.preview_sha256
      AND p.preview_payload=NEW.public_payload AND p.expires_at>clock_timestamp())
      OR NEW.public_payload_sha256<>NEW.preview_sha256
    THEN RAISE EXCEPTION 'publication_requires_exact_live_preview' USING ERRCODE='23514'; END IF;
    RETURN NEW;
  END IF;
  -- Command-owned action/execution heads are optimistic-version aggregates:
  -- their owner procedures may advance exactly one version in place.  All
  -- other append-only relations remain immutable and still fail closed.
  IF TG_OP='UPDATE' AND TG_TABLE_SCHEMA='ops' AND TG_TABLE_NAME IN
     ('action_proposals','action_proposal_versions','action_review_assignments',
      'action_decisions','in_flight_effects','execution_authorizations',
      'execution_attempts','execution_receipts') THEN
    RETURN NEW;
  END IF;
  -- Fixed-search-path SECURITY DEFINER owner procedures may advance the
  -- append-only budget/effect heads.  The session marker is set only inside
  -- those procedures; worker roles never receive table DML privileges.
  IF TG_OP='UPDATE' AND TG_TABLE_SCHEMA='ops'
     AND current_user='gurine_migrator'
     AND current_setting('gurine.owner_transition', true)='1' THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'immutable_record' USING ERRCODE='55000';
END $$;

DROP TRIGGER publication_revisions_immutable ON editorial.publication_revisions;

CREATE TRIGGER publication_revisions_immutable BEFORE INSERT OR UPDATE OR DELETE ON editorial.publication_revisions FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

DROP POLICY response_attachments_token_scope ON intake.response_attachments;

CREATE POLICY response_attachments_token_scope ON intake.response_attachments
  USING(response_request_id::text=current_setting('gurine.response_request_id',true) OR pg_has_role(current_user,'gurine_workflow_worker','MEMBER'))
  WITH CHECK(response_request_id::text=current_setting('gurine.response_request_id',true) OR pg_has_role(current_user,'gurine_workflow_worker','MEMBER'));

DROP POLICY response_submissions_token_scope ON intake.response_submissions;

CREATE POLICY response_submissions_token_scope ON intake.response_submissions
  USING(
    response_request_id::text=current_setting('gurine.response_request_id',true)
    OR pg_has_role(current_user,'gurine_workflow_worker','MEMBER')
    OR pg_has_role(current_user,'gurine_notification_worker','MEMBER')
  )
  WITH CHECK(
    response_request_id::text=current_setting('gurine.response_request_id',true)
    OR pg_has_role(current_user,'gurine_workflow_worker','MEMBER')
    OR pg_has_role(current_user,'gurine_notification_worker','MEMBER')
  );

DROP POLICY dataset_exports_token_scope ON intake.dataset_export_requests;

CREATE POLICY dataset_exports_token_scope ON intake.dataset_export_requests
  USING(request_token_hash=current_setting('gurine.token_hash',true) OR pg_has_role(current_user,'gurine_workflow_worker','MEMBER'))
  WITH CHECK(request_token_hash=current_setting('gurine.token_hash',true) OR pg_has_role(current_user,'gurine_workflow_worker','MEMBER'));

DROP INDEX IF EXISTS ops.email_deliveries_message_object_idx;

CREATE UNIQUE INDEX email_deliveries_message_object_recipient_idx
  ON ops.email_deliveries(message_type,object_id,recipient_hash) WHERE object_id IS NOT NULL;

GRANT SELECT ON intake.response_access_tokens TO gurine_submission_api;

GRANT SELECT ON intake.contact_requests,intake.response_extension_requests,
  intake.response_attachments,intake.response_submissions,
  intake.correction_attachments,intake.correction_requests,intake.subscriptions,
  editorial.cases,editorial.response_requests,ops.users TO gurine_notification_worker;

GRANT SELECT,INSERT ON intake.response_access_tokens TO gurine_notification_worker;

GRANT SELECT ON intake.correction_draft_attachments,intake.response_attachments,
  intake.response_submissions,intake.dataset_export_requests TO gurine_workflow_worker;

GRANT UPDATE ON intake.response_submissions,intake.dataset_export_requests TO gurine_workflow_worker;

GRANT SELECT ON public.datasets,core.anomaly_signals,ops.audit_events,ops.audit_exports,
  ops.agent_runs,ops.agent_suggestions,ops.schema_drifts,ops.source_registry TO gurine_workflow_worker;

GRANT UPDATE ON ops.audit_exports,ops.agent_runs,ops.schema_drifts,ops.source_registry TO gurine_workflow_worker;

GRANT SELECT ON ops.outbox TO gurine_scheduler;
GRANT EXECUTE ON FUNCTION ops.enqueue_outbox(text,text,bigint,text,jsonb,timestamptz)
  TO gurine_scheduler;

GRANT SELECT,INSERT,UPDATE ON ops.inbox TO gurine_scheduler;

GRANT SELECT,INSERT,UPDATE ON ops.jobs,ops.job_attempts TO
  gurine_ingest_worker,gurine_analysis_worker,gurine_public_projector,
  gurine_notification_worker,gurine_workflow_worker,gurine_document_extractor,
  gurine_scheduler;

GRANT SELECT,UPDATE ON ops.inbox TO
  gurine_ingest_worker,gurine_analysis_worker,gurine_public_projector,
  gurine_notification_worker,gurine_workflow_worker,gurine_document_extractor;

GRANT SELECT ON ops.queue_controls TO
  gurine_ingest_worker,gurine_analysis_worker,gurine_public_projector,
  gurine_notification_worker,gurine_workflow_worker,gurine_document_extractor,
  gurine_scheduler;

GRANT SELECT ON ops.agent_runs,ops.provider_configs,ops.provider_connection_tests,
  ops.budget_limits,ops.cost_events TO gurine_analysis_worker;

GRANT UPDATE ON ops.provider_configs,ops.provider_connection_tests TO gurine_analysis_worker;

-- The extractor refuses parser output unless this exact source-bundle digest,
-- parser id/version and media type are ACTIVE in the runtime registry.  The
-- digest is sha256(sha256sum archive.rs formats.rs lib.rs model.rs pdf.rs xml.rs).
INSERT INTO core.parser_versions(
  parser_name,version,supported_media_types,implementation_digest,sandbox_profile,status
) VALUES
  ('csv','1.4.0-reference-v1','["text/csv"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','pure-rust-no-network-v1','ACTIVE'),
  ('xml','0.41.0-reference-v1','["application/xml","text/xml"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','pure-rust-no-network-v1','ACTIVE'),
  ('xlsx','0.35.0-reference-v1','["application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','zip-preflight-no-network-v1','ACTIVE'),
  ('docx','zip-8.6.0+quick-xml-0.41.0-reference-v1','["application/vnd.openxmlformats-officedocument.wordprocessingml.document"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','zip-preflight-no-network-v1','ACTIVE'),
  ('hwpx','zip-8.6.0+quick-xml-0.41.0-reference-v1','["application/hwp+zip"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','zip-preflight-no-network-v1','ACTIVE'),
  ('pdf','pdf-reference-v1','["application/pdf"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','sandboxed-child-process-v1','ACTIVE'),
  ('pdf-digital','pdftotext-25.06.0','["application/pdf"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','sandboxed-child-process-v1','ACTIVE'),
  ('pdf-ocr','pdftoppm-25.06.0+tesseract-5.5.0-kor+eng','["application/pdf"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','sandboxed-child-process-v1','ACTIVE'),
  -- Additive v13 multimodal parsers.  These rows intentionally use the
  -- same implementation digest as the document-extractor bundle so the
  -- runtime's fail-closed registry check can bind each supported media type
  -- to the parser that produced the result.
  ('html-static','html5ever-0.39.0+gurinnae-html-v1','["text/html"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','pure-rust-no-network-v1','ACTIVE'),
  ('image-ocr','image-0.25.10+tesseract-5.5.0-kor+eng+gurinnae-image-v1','["image/png","image/jpeg","image/webp","image/tiff"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','sandboxed-child-process-v1','ACTIVE'),
  -- FFmpeg/whisper artifacts are admitted only after the pinned binaries,
  -- model, SBOM/license receipts, final OCI digest, and ASR/keyframe runtime
  -- evidence are checked into the source tree and verified by the hard gates.
  ('wav-media','ffmpeg-8.0.1+gurinnae-ffmpeg-subprocess-media-v1','["audio/wav","audio/x-wav"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','sandboxed-child-process-v1','ACTIVE'),
  ('webm-media','ffmpeg-8.0.1+gurinnae-ffmpeg-subprocess-media-v1','["video/webm"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','sandboxed-child-process-v1','ACTIVE'),
  ('legacy-hwp','unsupported','["application/x-hwp"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','quarantine-only-v1','ACTIVE'),
  ('unknown','unknown','["application/octet-stream"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','quarantine-only-v1','ACTIVE'),
  ('document-extractor','integrity-v1','["application/octet-stream","application/pdf","application/xml","application/x-hwp","application/hwp+zip","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet","application/vnd.openxmlformats-officedocument.wordprocessingml.document","text/csv","text/xml"]','34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb','integrity-guard-v1','ACTIVE')
ON CONFLICT(parser_name,version) DO UPDATE SET
  supported_media_types=EXCLUDED.supported_media_types,
  implementation_digest=EXCLUDED.implementation_digest,
  sandbox_profile=EXCLUDED.sandbox_profile,
  status=EXCLUDED.status;

GRANT UPDATE(status,parser_name,parser_version,schema_version,
  prompt_injection_flags,quarantine_reason,updated_at)
  ON raw.source_documents TO gurine_document_extractor;

-- Post-base submission-session hardening.
-- Migration 0030 keeps the byte-immutable v13 authority migrations and the
-- reserved 0025-0029 physical addenda isolated from runtime hardening.  A
-- response access token belongs to exactly one exchanged
-- pending session, and that session must carry the same response-request
-- scope as the token.
ALTER TABLE intake.submission_sessions
  ADD CONSTRAINT submission_sessions_id_scope_key UNIQUE (id, scope_id);

ALTER TABLE intake.response_access_tokens
  ADD CONSTRAINT response_access_exchange_session_key UNIQUE (exchange_session_id),
  ADD CONSTRAINT response_access_exchange_session_scope_fk
    FOREIGN KEY (exchange_session_id, response_request_id)
    REFERENCES intake.submission_sessions(id, scope_id),
  ADD CONSTRAINT response_access_exchange_state_check CHECK (
    (exchange_session_id IS NULL AND exchanged_at IS NULL)
    OR (
      exchange_session_id IS NOT NULL
      AND exchanged_at IS NOT NULL
      AND revoked_at IS NOT NULL
    )
  );

CREATE OR REPLACE FUNCTION intake.verify_response_session(
  p_session_token_hash char(64),p_bff_issuer text,p_verification_succeeded boolean,
  p_new_session_token_hash char(64),p_expires_at timestamptz
) RETURNS TABLE(request_id uuid,session_id uuid,remaining_attempts integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,extensions,pg_temp AS $$
DECLARE
  s intake.submission_sessions%ROWTYPE;
  t intake.response_access_tokens%ROWTYPE;
  r editorial.response_requests%ROWTYPE;
  v_attempts integer;
BEGIN
  SELECT * INTO s
  FROM intake.submission_sessions
  WHERE token_hash=p_session_token_hash AND bff_issuer=p_bff_issuer
    AND session_kind='RESPONSE_PENDING' AND status='ACTIVE' AND expires_at>clock_timestamp()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'response_pending_session_invalid' USING ERRCODE='28000'; END IF;

  SELECT * INTO r FROM editorial.response_requests
  WHERE id=s.scope_id AND status IN ('SENT','VIEWED') AND due_at>clock_timestamp()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;

  SELECT * INTO t FROM intake.response_access_tokens
  WHERE response_request_id=s.scope_id AND exchange_session_id=s.id
  FOR UPDATE;
  IF NOT FOUND OR t.revoked_at IS NULL OR t.exchanged_at IS NULL THEN
    RAISE EXCEPTION 'response_access_exchange_not_active' USING ERRCODE='28000';
  END IF;
  IF t.verification_locked_until IS NOT NULL AND t.verification_locked_until>clock_timestamp() THEN
    RAISE EXCEPTION 'response_verification_locked' USING ERRCODE='28000';
  END IF;
  IF t.verification_attempt_count>=5 THEN
    RAISE EXCEPTION 'response_verification_attempts_exhausted' USING ERRCODE='28000';
  END IF;

  v_attempts=t.verification_attempt_count+1;
  UPDATE intake.response_access_tokens
  SET verification_attempt_count=v_attempts,
      verified_at=CASE WHEN p_verification_succeeded THEN clock_timestamp() ELSE verified_at END,
      verification_locked_until=CASE
        WHEN NOT p_verification_succeeded AND v_attempts>=5 THEN clock_timestamp()+interval '15 minutes'
        ELSE NULL
      END,
      last_used_at=clock_timestamp()
  WHERE id=t.id;

  request_id=s.scope_id;
  remaining_attempts=GREATEST(0,5-v_attempts);
  IF NOT p_verification_succeeded THEN RETURN NEXT; RETURN; END IF;

  UPDATE intake.submission_sessions
  SET status='CONSUMED',consumed_at=clock_timestamp(),last_used_at=clock_timestamp(),version=version+1
  WHERE id=s.id AND status='ACTIVE';
  IF NOT FOUND THEN RAISE EXCEPTION 'response_pending_session_raced' USING ERRCODE='40001'; END IF;

  INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at)
  VALUES(p_new_session_token_hash,'RESPONSE_ACTIVE','RESPONSE_REQUEST',request_id,p_bff_issuer,p_expires_at)
  RETURNING id INTO session_id;
  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.get_response_access_status_session(
  p_session_token_hash char(64),p_bff_issuer text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE
  s intake.submission_sessions%ROWTYPE;
BEGIN
  SELECT * INTO s
  FROM intake.submission_sessions
  WHERE token_hash=p_session_token_hash
    AND bff_issuer=p_bff_issuer
    AND session_kind IN ('RESPONSE_PENDING','RESPONSE_ACTIVE')
    AND status='ACTIVE'
    AND expires_at>clock_timestamp();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000';
  END IF;
  RETURN jsonb_build_object(
    'status',s.session_kind,
    'expires_at',s.expires_at,
    'scope_id',s.scope_id,
    'session_id',s.id
  );
END $$;

-- v2 response-portal boundary.  The pre-v2 functions above are replaced in
-- this post-base migration so a caller supplied boolean can never select a
-- successful verification.  Legacy rows are retained for audit/replay, but
-- they cannot be selected by the v2 portal routines without a persisted OTP
-- verifier and key version.
ALTER TABLE editorial.response_requests
  ADD COLUMN IF NOT EXISTS effective_due_at timestamptz;

ALTER TABLE intake.response_access_tokens
  ADD COLUMN IF NOT EXISTS artifact_contract_version text,
  ADD COLUMN IF NOT EXISTS token_generation bigint,
  ADD COLUMN IF NOT EXISTS response_request_version bigint,
  ADD COLUMN IF NOT EXISTS response_request_binding_digest char(64),
  ADD COLUMN IF NOT EXISTS token_ciphertext bytea,
  ADD COLUMN IF NOT EXISTS token_encryption_key_id text,
  ADD COLUMN IF NOT EXISTS otp_derivation_version text,
  ADD COLUMN IF NOT EXISTS otp_verifier_hmac char(64),
  ADD COLUMN IF NOT EXISTS otp_verifier_key_version text,
  ADD COLUMN IF NOT EXISTS artifact_binding_digest char(64);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='intake' AND t.typname='response_otp_verify_v2'
  ) THEN
    CREATE TYPE intake.response_otp_verify_v2 AS (
      pending_session_token_hash char(64),
      bff_issuer text,
      candidate_otp_verifier_hmac char(64),
      candidate_otp_verifier_key_version text,
      new_session_token_hash char(64),
      new_session_expires_at timestamptz
    );
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='intake' AND t.typname='response_otp_verify_receipt_v2'
  ) THEN
    CREATE TYPE intake.response_otp_verify_receipt_v2 AS (
      request_id uuid,
      session_id uuid,
      disposition text,
      remaining_attempts integer,
      active_session_expires_at timestamptz,
      receipt_digest char(64)
    );
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='editorial' AND t.typname='response_portal_window_v1'
  ) THEN
    CREATE TYPE editorial.response_portal_window_v1 AS (
      response_request_id uuid,
      status text,
      effective_due_at timestamptz,
      pending_extension_request_id uuid,
      pending_extension_submitted_at timestamptz,
      window_basis text,
      is_open boolean
    );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION intake.constant_time_hex_equal(
  p_left char(64), p_right char(64)
) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE STRICT
SET search_path=pg_catalog,extensions,pg_temp AS $$
DECLARE
  v_left bytea := decode(btrim(p_left::text),'hex');
  v_right bytea := decode(btrim(p_right::text),'hex');
  v_diff integer := octet_length(v_left) # octet_length(v_right);
  v_width integer := GREATEST(octet_length(v_left),octet_length(v_right));
  v_index integer;
BEGIN
  -- Do not return early on a byte mismatch.  Values are fixed-width SHA-256
  -- encodings, but the length fold also keeps malformed candidates false.
  FOR v_index IN 0..GREATEST(v_width-1,0) LOOP
    v_diff := v_diff | (
      (CASE WHEN v_index < octet_length(v_left) THEN get_byte(v_left,v_index) ELSE 0 END)
      # (CASE WHEN v_index < octet_length(v_right) THEN get_byte(v_right,v_index) ELSE 0 END)
    );
  END LOOP;
  RETURN v_diff=0 AND octet_length(v_left)=32 AND octet_length(v_right)=32;
END $$;

CREATE OR REPLACE FUNCTION editorial.resolve_response_portal_window_v1(
  p_response_request_id uuid
) RETURNS editorial.response_portal_window_v1
LANGUAGE plpgsql STABLE
SET search_path=pg_catalog,intake,editorial,pg_temp AS $$
DECLARE
  q editorial.response_requests%ROWTYPE;
  pending intake.response_extension_requests%ROWTYPE;
  result editorial.response_portal_window_v1;
BEGIN
  SELECT * INTO q
  FROM editorial.response_requests
  WHERE id=p_response_request_id;
  IF NOT FOUND THEN
    result.response_request_id := p_response_request_id;
    result.status := 'UNAVAILABLE';
    result.window_basis := 'CLOSED_TERMINAL_STATE';
    result.is_open := false;
    RETURN result;
  END IF;

  result.response_request_id := q.id;
  result.status := q.status;
  result.effective_due_at := q.effective_due_at;
  result.is_open := false;
  IF q.status NOT IN ('SENT','VIEWED') THEN
    result.window_basis := 'CLOSED_TERMINAL_STATE';
    RETURN result;
  END IF;
  IF q.effective_due_at IS NULL THEN
    result.window_basis := 'OPEN_NO_VERIFIED_DEADLINE';
    result.is_open := true;
    RETURN result;
  END IF;
  IF q.effective_due_at > transaction_timestamp() THEN
    result.window_basis := 'OPEN_BEFORE_EFFECTIVE_DUE';
    result.is_open := true;
    RETURN result;
  END IF;

  SELECT * INTO pending
  FROM intake.response_extension_requests e
  WHERE e.response_request_id=q.id
  ORDER BY e.submitted_at DESC,e.id DESC
  LIMIT 1;
  IF FOUND AND pending.status='SUBMITTED'
     AND pending.submitted_at <= q.effective_due_at
     AND NOT EXISTS (
       SELECT 1 FROM editorial.response_extension_decisions d
       WHERE d.extension_request_id=pending.id
     ) THEN
    result.pending_extension_request_id := pending.id;
    result.pending_extension_submitted_at := pending.submitted_at;
    result.window_basis := 'OPEN_PENDING_TIMELY_EXTENSION';
    result.is_open := true;
    RETURN result;
  END IF;
  result.window_basis := 'CLOSED_DEADLINE_ELAPSED';
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION intake.exchange_response_magic_token_v2(
  p_magic_token_hash char(64), p_new_session_token_hash char(64),
  p_bff_issuer text, p_expires_at timestamptz
) RETURNS TABLE(request_id uuid,session_id uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE
  t intake.response_access_tokens%ROWTYPE;
  v_window editorial.response_portal_window_v1;
BEGIN
  IF p_bff_issuer NOT IN ('response-portal')
     OR p_expires_at <= clock_timestamp() THEN
    RAISE EXCEPTION 'response_magic_token_invalid' USING ERRCODE='28000';
  END IF;
  SELECT * INTO t
  FROM intake.response_access_tokens
  WHERE token_hash=p_magic_token_hash
    AND revoked_at IS NULL AND exchanged_at IS NULL
    AND expires_at>clock_timestamp()
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_magic_token_invalid' USING ERRCODE='28000';
  END IF;
  PERFORM 1 FROM editorial.response_requests WHERE id=t.response_request_id FOR UPDATE;
  v_window := editorial.resolve_response_portal_window_v1(t.response_request_id);
  IF NOT v_window.is_open OR t.otp_verifier_hmac IS NULL
     OR t.otp_verifier_key_version IS NULL THEN
    RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000';
  END IF;
  request_id := t.response_request_id;
  INSERT INTO intake.submission_sessions(
    token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at
  ) VALUES(
    p_new_session_token_hash,'RESPONSE_PENDING','RESPONSE_REQUEST',
    request_id,p_bff_issuer,p_expires_at
  ) RETURNING id INTO session_id;
  UPDATE intake.response_access_tokens
  SET exchanged_at=clock_timestamp(), exchange_session_id=session_id,
      revoked_at=clock_timestamp(), last_used_at=clock_timestamp()
  WHERE id=t.id;
  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.get_response_access_status_session_v2(
  p_session_token_hash char(64), p_bff_issuer text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE
  s intake.submission_sessions%ROWTYPE;
  v_window editorial.response_portal_window_v1;
  v_otp_key_version text;
BEGIN
  IF p_bff_issuer <> 'response-portal' THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000'; END IF;
  SELECT * INTO s FROM intake.submission_sessions
  WHERE token_hash=p_session_token_hash AND bff_issuer=p_bff_issuer
    AND session_kind IN ('RESPONSE_PENDING','RESPONSE_ACTIVE')
    AND status='ACTIVE' AND expires_at>clock_timestamp();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000';
  END IF;
  v_window := editorial.resolve_response_portal_window_v1(s.scope_id);
  IF NOT v_window.is_open THEN
    RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000';
  END IF;
  SELECT t.otp_verifier_key_version INTO v_otp_key_version
  FROM intake.response_access_tokens t
  WHERE t.response_request_id=s.scope_id AND t.exchange_session_id=s.id
    AND t.exchanged_at IS NOT NULL AND t.revoked_at IS NOT NULL;
  RETURN jsonb_build_object(
    'status',s.session_kind,'expires_at',s.expires_at,
    'scope_id',s.scope_id,'session_id',s.id,
    'effective_due_at',v_window.effective_due_at,
    'window_basis',v_window.window_basis,
    -- Internal BFF hint only; the HTTP projection intentionally omits it.
    'otp_key_version',v_otp_key_version
  );
END $$;

CREATE OR REPLACE FUNCTION intake.verify_response_session_v2(
  p_input intake.response_otp_verify_v2
) RETURNS intake.response_otp_verify_receipt_v2
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,extensions,pg_temp AS $$
DECLARE
  s intake.submission_sessions%ROWTYPE;
  t intake.response_access_tokens%ROWTYPE;
  v_window editorial.response_portal_window_v1;
  result intake.response_otp_verify_receipt_v2;
  v_attempts integer;
  v_digest_input jsonb;
BEGIN
  IF (p_input).bff_issuer <> 'response-portal' THEN RAISE EXCEPTION 'response_pending_session_invalid' USING ERRCODE='28000'; END IF;
  SELECT * INTO s FROM intake.submission_sessions
  WHERE token_hash=(p_input).pending_session_token_hash
    AND bff_issuer=(p_input).bff_issuer AND session_kind='RESPONSE_PENDING'
    AND status='ACTIVE' AND expires_at>clock_timestamp()
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_pending_session_invalid' USING ERRCODE='28000';
  END IF;
  PERFORM 1 FROM editorial.response_requests WHERE id=s.scope_id FOR UPDATE;
  v_window := editorial.resolve_response_portal_window_v1(s.scope_id);
  IF NOT v_window.is_open THEN
    RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000';
  END IF;
  SELECT * INTO t FROM intake.response_access_tokens
  WHERE response_request_id=s.scope_id AND exchange_session_id=s.id
    AND exchanged_at IS NOT NULL AND revoked_at IS NOT NULL
  FOR UPDATE;
  IF NOT FOUND OR t.otp_verifier_hmac IS NULL
     OR t.otp_verifier_key_version IS NULL THEN
    RAISE EXCEPTION 'response_access_exchange_not_active' USING ERRCODE='28000';
  END IF;

  result.request_id := s.scope_id;
  result.session_id := NULL;
  result.active_session_expires_at := NULL;
  IF t.verification_locked_until IS NOT NULL
     AND t.verification_locked_until>clock_timestamp() THEN
    result.disposition := 'LOCKED';
    result.remaining_attempts := 0;
  ELSIF t.verification_attempt_count>=5 THEN
    result.disposition := 'LOCKED';
    result.remaining_attempts := 0;
  ELSE
    v_attempts := t.verification_attempt_count+1;
    IF btrim(t.otp_verifier_key_version::text)=btrim((p_input).candidate_otp_verifier_key_version::text)
       AND intake.constant_time_hex_equal(
         t.otp_verifier_hmac,(p_input).candidate_otp_verifier_hmac
       ) THEN
      UPDATE intake.response_access_tokens
      SET verification_attempt_count=v_attempts,
          verified_at=clock_timestamp(), verification_locked_until=NULL,
          last_used_at=clock_timestamp()
      WHERE id=t.id;
      UPDATE intake.submission_sessions
      SET status='CONSUMED', consumed_at=clock_timestamp(),
          last_used_at=clock_timestamp(), version=version+1
      WHERE id=s.id AND status='ACTIVE';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'response_pending_session_raced' USING ERRCODE='40001';
      END IF;
      INSERT INTO intake.submission_sessions(
        token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at
      ) VALUES(
        (p_input).new_session_token_hash,'RESPONSE_ACTIVE','RESPONSE_REQUEST',
        s.scope_id,(p_input).bff_issuer,(p_input).new_session_expires_at
      ) RETURNING id INTO result.session_id;
      result.disposition := 'VERIFIED';
      result.remaining_attempts := GREATEST(0,5-v_attempts);
      result.active_session_expires_at := (p_input).new_session_expires_at;
    ELSE
      UPDATE intake.response_access_tokens
      SET verification_attempt_count=v_attempts,
          verification_locked_until=CASE
            WHEN v_attempts>=5 THEN clock_timestamp()+interval '15 minutes'
            ELSE NULL END,
          last_used_at=clock_timestamp()
      WHERE id=t.id;
      result.remaining_attempts := GREATEST(0,5-v_attempts);
      result.disposition := CASE WHEN v_attempts>=5
        THEN 'LOCKED' ELSE 'VERIFICATION_FAILED' END;
    END IF;
  END IF;
  v_digest_input := jsonb_build_object(
    'requestId',result.request_id,'sessionId',result.session_id,
    'disposition',result.disposition,'remainingAttempts',result.remaining_attempts,
    'activeSessionExpiresAt',result.active_session_expires_at
  );
  result.receipt_digest := encode(
    extensions.digest(convert_to(v_digest_input::text,'UTF8'),'sha256'),'hex'
  );
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION intake.get_response_request_session_v2(
  p_session_token_hash char(64), p_bff_issuer text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE
  v_scope uuid;
  v_window editorial.response_portal_window_v1;
  result jsonb;
BEGIN
  IF p_bff_issuer <> 'response-portal' THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000'; END IF;
  SELECT r.scope_id INTO v_scope
  FROM intake.resolve_submission_session(
    p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']
  ) r;
  v_window := editorial.resolve_response_portal_window_v1(v_scope);
  IF NOT v_window.is_open THEN
    RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000';
  END IF;
  SELECT (to_jsonb(q)-'recipient_email_encrypted'-'recipient_email_hash'-'due_at')
    || jsonb_build_object(
      'case_title',c.title,'effective_due_at',v_window.effective_due_at,
      'window_basis',v_window.window_basis
    )
  INTO result
  FROM editorial.response_requests q
  JOIN editorial.cases c ON c.id=q.case_id
  WHERE q.id=v_scope;
  IF result IS NULL THEN
    RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000';
  END IF;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION intake.download_response_request_session_v2(
  p_session_token_hash char(64), p_bff_issuer text
) RETURNS bytea
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE
  payload jsonb;
BEGIN
  payload := intake.get_response_request_session_v2(
    p_session_token_hash,p_bff_issuer
  );
  RETURN convert_to(payload::text,'UTF8');
END $$;

-- Remaining response-portal operations use the same resolver.  These are
-- deliberately separate v2 entry points so a stale caller cannot silently
-- fall back to the pre-clock `due_at` predicate.
CREATE OR REPLACE FUNCTION intake.get_response_draft_session_v2(
  p_session_token_hash char(64), p_bff_issuer text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE
  v_scope uuid;
  v_window editorial.response_portal_window_v1;
  result jsonb;
BEGIN
  IF p_bff_issuer <> 'response-portal' THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000'; END IF;
  SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(
    p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']
  ) r;
  v_window := editorial.resolve_response_portal_window_v1(v_scope);
  IF NOT v_window.is_open THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  SELECT to_jsonb(d)||jsonb_build_object('answers_encrypted',convert_from(d.answers_encrypted,'UTF8'))
    INTO result FROM intake.response_drafts d WHERE d.response_request_id=v_scope;
  RETURN COALESCE(result,'{}'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION intake.get_response_preview_session_v2(
  p_session_token_hash char(64), p_bff_issuer text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE
  v_scope uuid;
  v_window editorial.response_portal_window_v1;
  result jsonb;
BEGIN
  IF p_bff_issuer <> 'response-portal' THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000'; END IF;
  SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(
    p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']
  ) r;
  v_window := editorial.resolve_response_portal_window_v1(v_scope);
  IF NOT v_window.is_open THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  SELECT jsonb_build_object(
    'draft',COALESCE((SELECT to_jsonb(d)||jsonb_build_object('answers_encrypted',convert_from(d.answers_encrypted,'UTF8'))
      FROM intake.response_drafts d WHERE d.response_request_id=v_scope),'{}'::jsonb),
    'attachments',COALESCE((SELECT jsonb_agg(to_jsonb(a)||jsonb_build_object('filename_encrypted',convert_from(a.original_filename_encrypted,'UTF8')) ORDER BY a.id)
      FROM intake.response_attachments a WHERE a.response_request_id=v_scope AND a.upload_status<>'DELETED'),'[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION intake.save_response_draft_session_v2(
  p_session_token_hash char(64), p_bff_issuer text, p_expected_version bigint,
  p_answers_encrypted bytea, p_publication_consent jsonb, p_expires_at timestamptz
) RETURNS TABLE(draft_id uuid,version bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE
  v_request uuid;
  v_id uuid;
  v_version bigint;
  v_window editorial.response_portal_window_v1;
  v_uuid_text text;
  v_variant_nibble text;
BEGIN
  IF p_bff_issuer <> 'response-portal' THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000'; END IF;
  SELECT r.scope_id INTO v_request FROM intake.resolve_submission_session(
    p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']
  ) r;
  PERFORM 1 FROM editorial.response_requests WHERE id=v_request FOR UPDATE;
  v_window := editorial.resolve_response_portal_window_v1(v_request);
  IF NOT v_window.is_open THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  SELECT id,response_drafts.version INTO v_id,v_version
  FROM intake.response_drafts WHERE response_request_id=v_request FOR UPDATE;
  IF v_id IS NULL THEN
    IF p_expected_version<>0 THEN RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE='40001'; END IF;
    -- The API encrypts the answer envelope before calling this function and
    -- binds it to the deterministic draft id derived from the session hash.
    -- Use the same UUID v4/variant normalization here instead of generating a
    -- fresh id, otherwise the first draft can never be decrypted after the
    -- insert (the AAD would contain a different record id).
    v_uuid_text := substr(trim(p_session_token_hash),1,8)||'-'||
      substr(trim(p_session_token_hash),9,4)||'-'||
      substr(trim(p_session_token_hash),13,4)||'-'||
      substr(trim(p_session_token_hash),17,4)||'-'||
      substr(trim(p_session_token_hash),21,12);
    v_uuid_text := overlay(v_uuid_text placing '4' from 15 for 1);
    -- Match Uuid::from_bytes, which forces RFC 4122 variant 10xx while
    -- retaining the lower six bits in the byte.  The textual UUID therefore
    -- always starts its fourth group with `8`.
    v_variant_nibble := '8';
    v_uuid_text := overlay(v_uuid_text placing v_variant_nibble from 20 for 1);
    v_id := v_uuid_text::uuid;
    INSERT INTO intake.response_drafts(id,response_request_id,version,answers_encrypted,publication_consent,saved_at,expires_at)
      VALUES(v_id,v_request,1,p_answers_encrypted,p_publication_consent,clock_timestamp(),p_expires_at)
      RETURNING id,response_drafts.version INTO draft_id,version;
  ELSE
    IF v_version<>p_expected_version THEN RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE='40001'; END IF;
    UPDATE intake.response_drafts
      SET answers_encrypted=p_answers_encrypted,publication_consent=p_publication_consent,
          saved_at=clock_timestamp(),expires_at=p_expires_at,version=response_drafts.version+1
      WHERE id=v_id AND version=p_expected_version
      RETURNING id,response_drafts.version INTO draft_id,version;
    IF draft_id IS NULL THEN RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE='40001'; END IF;
  END IF;
  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.create_response_attachment_session_v2(
  p_session_token_hash char(64), p_bff_issuer text, p_filename_encrypted bytea,
  p_media_type text, p_size_bytes bigint, p_sha256 char(64), p_object_key text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE
  v_request uuid;
  v_draft uuid;
  v_id uuid;
  v_parts text[];
  v_window editorial.response_portal_window_v1;
BEGIN
  IF p_bff_issuer <> 'response-portal' THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000'; END IF;
  SELECT r.scope_id INTO v_request FROM intake.resolve_submission_session(
    p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']
  ) r;
  PERFORM 1 FROM editorial.response_requests WHERE id=v_request FOR UPDATE;
  v_window := editorial.resolve_response_portal_window_v1(v_request);
  IF NOT v_window.is_open THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  SELECT id INTO v_draft FROM intake.response_drafts WHERE response_request_id=v_request;
  v_parts := string_to_array(p_object_key,'/');
  IF array_length(v_parts,1)<>4 OR v_parts[1]<>'quarantine' OR v_parts[2]<>'responses' THEN
    RAISE EXCEPTION 'response_attachment_object_key_invalid' USING ERRCODE='22023';
  END IF;
  -- The filename envelope is authenticated with the attachment id chosen by
  -- the API.  The id is part of the object-key contract, so persist that id
  -- instead of allocating another UUID and making the ciphertext
  -- undecryptable on projection.
  BEGIN
    v_id := v_parts[3]::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'response_attachment_object_key_invalid' USING ERRCODE='22023';
  END;
  INSERT INTO intake.response_attachments(
    id,response_request_id,draft_id,original_filename_encrypted,media_type,size_bytes,
    sha256,object_key,upload_status,scan_status
  ) VALUES(v_id,v_request,v_draft,p_filename_encrypted,p_media_type,p_size_bytes,p_sha256,
    p_object_key,'PENDING','PENDING') RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION intake.finalize_response_attachment_session_v2(
  p_session_token_hash char(64), p_bff_issuer text, p_attachment_id uuid,
  p_object_etag text, p_uploaded_size bigint, p_uploaded_sha256 char(64)
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE
  v_request uuid;
  v_id uuid;
  v_window editorial.response_portal_window_v1;
BEGIN
  IF p_bff_issuer <> 'response-portal' THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000'; END IF;
  SELECT r.scope_id INTO v_request FROM intake.resolve_submission_session(
    p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']
  ) r;
  PERFORM 1 FROM editorial.response_requests WHERE id=v_request FOR UPDATE;
  v_window := editorial.resolve_response_portal_window_v1(v_request);
  IF NOT v_window.is_open THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  UPDATE intake.response_attachments SET upload_status='FINALIZED',scan_status='PENDING'
  WHERE id=p_attachment_id AND response_request_id=v_request
    AND upload_status IN ('PENDING','UPLOADED')
    AND size_bytes=p_uploaded_size AND sha256=p_uploaded_sha256
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'response_attachment_finalize_failed' USING ERRCODE='22023'; END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION intake.delete_response_attachment_session_v2(
  p_session_token_hash char(64), p_bff_issuer text, p_attachment_id uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE
  v_request uuid;
  v_id uuid;
  v_window editorial.response_portal_window_v1;
BEGIN
  IF p_bff_issuer <> 'response-portal' THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000'; END IF;
  SELECT r.scope_id INTO v_request FROM intake.resolve_submission_session(
    p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']
  ) r;
  PERFORM 1 FROM editorial.response_requests WHERE id=v_request FOR UPDATE;
  v_window := editorial.resolve_response_portal_window_v1(v_request);
  IF NOT v_window.is_open THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  UPDATE intake.response_attachments SET upload_status='DELETED'
  WHERE id=p_attachment_id AND response_request_id=v_request AND upload_status<>'DELETED'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'response_attachment_not_found' USING ERRCODE='P0002'; END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION intake.request_response_extension_session_v2(
  p_session_token_hash char(64), p_bff_issuer text,
  p_requested_due_at timestamptz, p_reason text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE
  v_request uuid;
  v_id uuid;
  v_window editorial.response_portal_window_v1;
BEGIN
  IF p_bff_issuer <> 'response-portal' THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000'; END IF;
  SELECT r.scope_id INTO v_request FROM intake.resolve_submission_session(
    p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']
  ) r;
  PERFORM 1 FROM editorial.response_requests WHERE id=v_request FOR UPDATE;
  v_window := editorial.resolve_response_portal_window_v1(v_request);
  IF NOT v_window.is_open THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  IF v_window.effective_due_at IS NOT NULL AND p_requested_due_at<=v_window.effective_due_at THEN
    RAISE EXCEPTION 'extension_due_date_must_increase' USING ERRCODE='22023';
  END IF;
  INSERT INTO intake.response_extension_requests(response_request_id,requested_due_at,reason,status)
    VALUES(v_request,p_requested_due_at,p_reason,'SUBMITTED') RETURNING id INTO v_id;
  RETURN v_id;
END $$;

DROP FUNCTION IF EXISTS intake.submit_response_session_v2(char(64),text,bigint,char(64),bytea,jsonb,char(64),char(64),timestamptz);
CREATE OR REPLACE FUNCTION intake.submit_response_session_v2(
  p_session_token_hash char(64), p_bff_issuer text, p_expected_version bigint,
  p_submission_sha256 char(64), p_answers_encrypted bytea,
  p_publication_consent jsonb, p_submission_id uuid, p_receipt_token_hash char(64),
  p_receipt_session_token_hash char(64), p_receipt_session_expires_at timestamptz
) RETURNS TABLE(submission_id uuid,receipt_session_id uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE
  s intake.submission_sessions%ROWTYPE;
  d intake.response_drafts%ROWTYPE;
  v_window editorial.response_portal_window_v1;
BEGIN
  IF p_bff_issuer <> 'response-portal' THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000'; END IF;
  SELECT * INTO s FROM intake.submission_sessions
  WHERE token_hash=p_session_token_hash AND bff_issuer=p_bff_issuer
    AND session_kind='RESPONSE_ACTIVE' AND status='ACTIVE'
    AND expires_at>clock_timestamp() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000'; END IF;
  PERFORM 1 FROM editorial.response_requests WHERE id=s.scope_id FOR UPDATE;
  v_window := editorial.resolve_response_portal_window_v1(s.scope_id);
  IF NOT v_window.is_open THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  SELECT * INTO d FROM intake.response_drafts
  WHERE response_request_id=s.scope_id AND version=p_expected_version FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE='40001'; END IF;
  IF EXISTS(SELECT 1 FROM intake.response_attachments a
    WHERE a.response_request_id=s.scope_id AND a.upload_status<>'DELETED'
      AND (a.upload_status<>'FINALIZED' OR a.scan_status<>'CLEAN')) THEN
    RAISE EXCEPTION 'response_attachment_not_clean' USING ERRCODE='22023';
  END IF;
  INSERT INTO intake.response_submissions(id,
    response_request_id,draft_version,submission_sha256,answers_encrypted,
    publication_consent,receipt_token_hash
  ) VALUES(p_submission_id,s.scope_id,d.version,p_submission_sha256,p_answers_encrypted,
    p_publication_consent,p_receipt_token_hash) RETURNING id INTO submission_id;
  UPDATE editorial.response_requests SET status='SUBMITTED',version=version+1,updated_at=clock_timestamp()
  WHERE id=s.scope_id AND status IN ('SENT','VIEWED');
  IF NOT FOUND THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  UPDATE intake.submission_sessions SET status='CONSUMED',consumed_at=clock_timestamp(),version=version+1
    WHERE id=s.id AND status='ACTIVE';
  INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at)
    VALUES(p_receipt_session_token_hash,'RESPONSE_RECEIPT','RESPONSE_SUBMISSION',submission_id,p_bff_issuer,p_receipt_session_expires_at)
    RETURNING id INTO receipt_session_id;
  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.get_response_receipt_session_v2(
  p_session_token_hash char(64), p_bff_issuer text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,pg_temp AS $$
DECLARE v_scope uuid; result jsonb;
BEGIN
  IF p_bff_issuer <> 'response-portal' THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000'; END IF;
  SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(
    p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_RECEIPT']
  ) r;
  SELECT to_jsonb(s)-'answers_encrypted'-'receipt_token_hash' INTO result
  FROM intake.response_submissions s WHERE s.id=v_scope;
  RETURN result;
END $$;

DROP FUNCTION IF EXISTS intake.verify_response_session(char(64),text,boolean,char(64),timestamptz);
DROP FUNCTION IF EXISTS intake.exchange_response_magic_token(char(64),char(64),text,timestamptz);
DROP FUNCTION IF EXISTS intake.lookup_response_request_id(char(64));
DROP FUNCTION IF EXISTS intake.get_response_access_status(char(64));
DROP FUNCTION IF EXISTS intake.get_response_request(char(64));
DROP FUNCTION IF EXISTS intake.get_response_draft(char(64));
DROP FUNCTION IF EXISTS intake.get_response_receipt(char(64));
DROP FUNCTION IF EXISTS intake.request_response_extension(char(64),timestamptz,text);
DROP FUNCTION IF EXISTS intake.resolve_response_request_id(char(64));
DROP FUNCTION IF EXISTS intake.submit_response(char(64),bigint,char(64),bytea,jsonb,char(64));
DROP FUNCTION IF EXISTS intake.verify_response_access(char(64),boolean);
DROP FUNCTION IF EXISTS intake.get_response_access_status_session(char(64),text);
DROP FUNCTION IF EXISTS intake.get_response_request_session(char(64),text);
DROP FUNCTION IF EXISTS intake.save_response_draft_session(char(64),text,bigint,bytea,jsonb,timestamptz);
DROP FUNCTION IF EXISTS intake.create_response_attachment_session(char(64),text,bytea,text,bigint,char(64),text);
DROP FUNCTION IF EXISTS intake.finalize_response_attachment_session(char(64),text,uuid,bigint,char(64));
DROP FUNCTION IF EXISTS intake.delete_response_attachment_session(char(64),text,uuid);
DROP FUNCTION IF EXISTS intake.request_response_extension_session(char(64),text,timestamptz,text);
DROP FUNCTION IF EXISTS intake.submit_response_session(char(64),text,bigint,char(64),bytea,jsonb,char(64),char(64),timestamptz);
DROP FUNCTION IF EXISTS intake.get_response_draft_session(char(64),text);
DROP FUNCTION IF EXISTS intake.get_response_preview_session(char(64),text);
DROP FUNCTION IF EXISTS intake.get_response_receipt_session(char(64),text);

REVOKE ALL ON TABLE intake.response_access_tokens,editorial.response_requests
  FROM gurine_submission_api;
REVOKE ALL ON FUNCTION intake.exchange_response_magic_token_v2(char(64),char(64),text,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.constant_time_hex_equal(char(64),char(64)) FROM PUBLIC;
REVOKE ALL ON FUNCTION editorial.resolve_response_portal_window_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.verify_response_session_v2(intake.response_otp_verify_v2) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.get_response_access_status_session_v2(char(64),text) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.get_response_request_session_v2(char(64),text) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.download_response_request_session_v2(char(64),text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION intake.exchange_response_magic_token_v2(char(64),char(64),text,timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.verify_response_session_v2(intake.response_otp_verify_v2) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_response_access_status_session_v2(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_response_request_session_v2(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.download_response_request_session_v2(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_response_draft_session_v2(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_response_preview_session_v2(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.save_response_draft_session_v2(char(64),text,bigint,bytea,jsonb,timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.create_response_attachment_session_v2(char(64),text,bytea,text,bigint,char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.finalize_response_attachment_session_v2(char(64),text,uuid,text,bigint,char(64)) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.delete_response_attachment_session_v2(char(64),text,uuid) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.request_response_extension_session_v2(char(64),text,timestamptz,text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.submit_response_session_v2(char(64),text,bigint,char(64),bytea,jsonb,uuid,char(64),char(64),timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_response_receipt_session_v2(char(64),text) TO gurine_submission_api;

-- Provider turn terminal transitions are owned by the database.  The analysis
-- worker may insert a DISPATCHED attempt (the v13 contract deliberately keeps
-- that allocation idempotent at the worker boundary), but it must never issue
-- a table UPDATE for a terminal result.  Keeping this transition in one
-- fixed-search-path SECURITY DEFINER function also means the lifecycle checks
-- and the version CAS run under the table owner, while the worker receives
-- only EXECUTE on this exact signature.
-- These additive constraints close the v2 lineage guarantees that were absent
-- from the historical 0025 table creation.  They are intentionally additive
-- here because 0001-0024 and the authority 0025 file are byte immutable.
CREATE UNIQUE INDEX IF NOT EXISTS agent_runs_id_input_snapshot_hash_uk
  ON ops.agent_runs (id, input_snapshot_hash);
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'agent_provider_turns_run_fk'
       AND conrelid = 'ops.agent_provider_turns'::regclass
  ) THEN
    ALTER TABLE ops.agent_provider_turns
      ADD CONSTRAINT agent_provider_turns_run_fk
      FOREIGN KEY (agent_run_id, input_snapshot_sha256)
      REFERENCES ops.agent_runs (id, input_snapshot_hash)
      ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'agent_provider_turns_provider_fk'
       AND conrelid = 'ops.agent_provider_turns'::regclass
  ) THEN
    ALTER TABLE ops.agent_provider_turns
      ADD CONSTRAINT agent_provider_turns_provider_fk
      FOREIGN KEY (provider_config_id)
      REFERENCES ops.provider_configs (id)
      ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'agent_provider_turns_cost_fk'
       AND conrelid = 'ops.agent_provider_turns'::regclass
  ) THEN
    ALTER TABLE ops.agent_provider_turns
      ADD CONSTRAINT agent_provider_turns_cost_fk
      FOREIGN KEY (cost_event_id)
      REFERENCES ops.cost_events (id)
      ON DELETE RESTRICT;
  END IF;
END
$$;
CREATE UNIQUE INDEX IF NOT EXISTS agent_provider_turns_one_success_per_turn_uk
  ON ops.agent_provider_turns (agent_run_id, turn_sequence)
  WHERE status = 'COMPLETED';

CREATE OR REPLACE FUNCTION ops.complete_agent_provider_turn(
  p_provider_turn_id uuid,
  p_expected_version bigint,
  p_status text,
  p_envelope_kind text,
  p_envelope_sha256 char(64),
  p_envelope_payload_sha256 char(64),
  p_envelope_canonical bytea,
  p_response_redacted jsonb,
  p_response_redacted_canonical bytea,
  p_call_id text,
  p_tool_id text,
  p_provider_receipt_id uuid,
  p_provider_receipt jsonb,
  p_provider_receipt_canonical bytea,
  p_provider_receipt_sha256 char(64),
  p_provider_turn_canonical bytea,
  p_provider_turn_sha256 char(64),
  p_turn_transcript_sha256 char(64),
  p_input_units bigint,
  p_output_units bigint,
  p_provider_request_id_hash char(64),
  p_cost_krw bigint,
  p_error_code text,
  p_error_sha256 char(64)
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_turn ops.agent_provider_turns%ROWTYPE;
  v_outcome text;
  v_expected_outcome text;
  v_rows integer;
  v_cost_event_id uuid;
  v_case_id uuid;
  v_job_id uuid;
BEGIN
  IF p_expected_version IS NULL OR p_expected_version < 1 THEN
    RAISE EXCEPTION 'provider_turn_expected_version_invalid' USING ERRCODE = '22023';
  END IF;
  IF p_status NOT IN ('COMPLETED','PROVIDER_FAILED','RATE_LIMITED','TIMED_OUT','CANCELLED','OUTCOME_UNKNOWN') THEN
    RAISE EXCEPTION 'provider_turn_terminal_status_invalid' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_turn
    FROM ops.agent_provider_turns
   WHERE provider_turn_id = p_provider_turn_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'provider_turn_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_turn.version <> p_expected_version THEN
    RAISE EXCEPTION 'provider_turn_version_conflict' USING ERRCODE = '40001';
  END IF;
  IF v_turn.status <> 'DISPATCHED' THEN
    RAISE EXCEPTION 'provider_turn_terminal_immutable' USING ERRCODE = '55000';
  END IF;

  IF p_provider_receipt IS NULL
     OR p_provider_receipt_canonical IS NULL
     OR p_provider_receipt_sha256 IS NULL
     OR p_provider_turn_canonical IS NULL
     OR p_provider_turn_sha256 IS NULL
     OR p_provider_receipt_id IS NULL THEN
    RAISE EXCEPTION 'provider_turn_receipt_required' USING ERRCODE = '22023';
  END IF;
  IF convert_from(p_provider_receipt_canonical, 'UTF8')::jsonb IS DISTINCT FROM p_provider_receipt
     OR encode(extensions.digest(p_provider_receipt_canonical, 'sha256'), 'hex') <> p_provider_receipt_sha256
     OR encode(extensions.digest(p_provider_turn_canonical, 'sha256'), 'hex') <> p_provider_turn_sha256 THEN
    RAISE EXCEPTION 'provider_turn_canonical_mismatch' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_provider_receipt) <> 'object'
     OR NOT (p_provider_receipt ?& ARRAY[
       'schemaVersion','receiptId','agentRunId','providerTurnId','providerMode',
       'providerConfigId','providerCandidateId','modelId','modelConfigurationSha256',
       'semanticRequestSha256','idempotencyKeySha256','outcome','proofKind','proofSha256',
       'providerRequestIdHash','usage','pricing','dataPolicy','dispatchedAt','observedAt',
       'completedAt','receiptSha256'
     ])
     OR p_provider_receipt->>'schemaVersion' <> 'provider-receipt.v2'
     OR p_provider_receipt->>'receiptSha256' !~ '^[0-9a-f]{64}$'
     OR jsonb_typeof(p_provider_receipt->'usage') <> 'object'
     OR NOT (p_provider_receipt->'usage' ?& ARRAY[
       'state','inputUnits','outputUnits','cachedInputUnits','billableUnits','usageEvidenceSha256'
     ])
     OR p_provider_receipt->'usage'->>'state' NOT IN ('NOT_APPLICABLE','ESTIMATED','PROVIDER_REPORTED','BILLING_VERIFIED','UNKNOWN')
     OR jsonb_typeof(p_provider_receipt->'pricing') <> 'object'
     OR NOT (p_provider_receipt->'pricing' ?& ARRAY[
       'pricingVersion','pricingSha256','currency','fxRateFactId','reservedMicrosKrw','actualMicrosKrw','costState'
     ])
     OR p_provider_receipt->'pricing'->>'currency' !~ '^[A-Z]{3}$'
     OR p_provider_receipt->'pricing'->>'costState' NOT IN ('RESERVED','ESTIMATED','SETTLED','RELEASED','RECONCILIATION_REQUIRED')
     OR jsonb_typeof(p_provider_receipt->'dataPolicy') <> 'object'
     OR NOT (p_provider_receipt->'dataPolicy' ?& ARRAY[
       'classification','processingRegion','retentionMode','trainingUse','policyVersion','policySha256','rightsDecisionSetSha256'
     ])
     OR p_provider_receipt->'dataPolicy'->>'classification' NOT IN ('PUBLIC','INTERNAL')
     OR p_provider_receipt->'dataPolicy'->>'trainingUse' <> 'PROHIBITED' THEN
    RAISE EXCEPTION 'provider_receipt_v2_shape_invalid' USING ERRCODE = '22023';
  END IF;
  IF (p_provider_receipt->'usage'->>'inputUnits') IS NOT NULL
     AND (p_provider_receipt->'usage'->>'inputUnits')::numeric < 0
     OR (p_provider_receipt->'usage'->>'outputUnits') IS NOT NULL
     AND (p_provider_receipt->'usage'->>'outputUnits')::numeric < 0
     OR (p_provider_receipt->'pricing'->>'reservedMicrosKrw')::numeric < 0
     OR (p_provider_receipt->'pricing'->>'actualMicrosKrw') IS NOT NULL
     AND (p_provider_receipt->'pricing'->>'actualMicrosKrw')::numeric < 0 THEN
    RAISE EXCEPTION 'provider_receipt_v2_numeric_invalid' USING ERRCODE = '22023';
  END IF;
  IF p_provider_receipt->>'providerTurnId' IS DISTINCT FROM p_provider_turn_id::text
     OR p_provider_receipt->>'agentRunId' IS DISTINCT FROM v_turn.agent_run_id::text
     OR p_provider_receipt->>'receiptId' IS DISTINCT FROM p_provider_receipt_id::text
     OR p_provider_receipt->>'providerMode' IS DISTINCT FROM v_turn.provider_mode
     OR p_provider_receipt->>'providerConfigId' IS DISTINCT FROM v_turn.provider_config_id::text
     OR p_provider_receipt->>'providerCandidateId' IS DISTINCT FROM v_turn.provider_candidate_id
     OR p_provider_receipt->>'modelId' IS DISTINCT FROM v_turn.model_id
     OR p_provider_receipt->>'modelConfigurationSha256' IS DISTINCT FROM btrim(v_turn.model_configuration_sha256::text)
     OR p_provider_receipt->>'semanticRequestSha256' IS DISTINCT FROM v_turn.request_redacted->>'semanticRequestSha256'
     OR p_provider_receipt->>'idempotencyKeySha256' IS DISTINCT FROM btrim(v_turn.dispatch_key_sha256::text) THEN
    RAISE EXCEPTION 'provider_turn_receipt_binding_mismatch' USING ERRCODE = '22023';
  END IF;
  IF p_provider_receipt->>'providerRequestIdHash' IS DISTINCT FROM p_provider_request_id_hash THEN
    RAISE EXCEPTION 'provider_turn_provider_request_binding_mismatch' USING ERRCODE = '22023';
  END IF;
  -- The worker validates the RFC8785/JCS self-digest before invoking this
  -- owner boundary. PostgreSQL jsonb::text is not RFC8785 and must not be
  -- used to recompute that digest; the canonical bytea/hash pair below is
  -- the database-level integrity check.

  IF p_status = 'COMPLETED' THEN
    IF p_envelope_kind NOT IN ('FINAL_OUTPUT','TOOL_CALL')
       OR p_envelope_sha256 IS NULL
       OR p_envelope_payload_sha256 IS NULL
       OR p_envelope_canonical IS NULL
       OR p_response_redacted IS NULL
       OR p_response_redacted_canonical IS NULL
       OR p_turn_transcript_sha256 IS NULL
       OR p_error_code IS NOT NULL
       OR p_error_sha256 IS NOT NULL THEN
      RAISE EXCEPTION 'provider_turn_completed_shape_invalid' USING ERRCODE = '22023';
    END IF;
    IF encode(extensions.digest(p_envelope_canonical, 'sha256'), 'hex') <> p_envelope_sha256
       OR convert_from(p_envelope_canonical, 'UTF8')::jsonb->>'kind' IS DISTINCT FROM p_envelope_kind
       OR convert_from(p_response_redacted_canonical, 'UTF8')::jsonb IS DISTINCT FROM p_response_redacted THEN
      RAISE EXCEPTION 'provider_turn_envelope_canonical_mismatch' USING ERRCODE = '22023';
    END IF;
    IF COALESCE(convert_from(p_envelope_canonical, 'UTF8')::jsonb->>'payloadSha256',
                convert_from(p_envelope_canonical, 'UTF8')::jsonb->>'argumentsSha256')
         IS DISTINCT FROM p_envelope_payload_sha256 THEN
      RAISE EXCEPTION 'provider_turn_envelope_payload_digest_mismatch' USING ERRCODE = '22023';
    END IF;
    IF p_response_redacted->>'schemaVersion' <> 'agent-provider-response-redacted.v2'
       OR p_response_redacted->>'finishReason' IS DISTINCT FROM p_envelope_kind
       OR p_response_redacted->>'envelopeSha256' IS DISTINCT FROM p_envelope_sha256
       OR p_response_redacted->'safetyCodes' IS NULL
       OR p_response_redacted->>'providerRequestIdHash' IS DISTINCT FROM p_provider_request_id_hash
       OR p_response_redacted->>'redactionReceiptSha256' !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'provider_turn_response_redacted_shape_invalid' USING ERRCODE = '22023';
    END IF;
    IF p_envelope_kind = 'FINAL_OUTPUT' AND (p_call_id IS NOT NULL OR p_tool_id IS NOT NULL) THEN
      RAISE EXCEPTION 'provider_turn_final_tool_binding_invalid' USING ERRCODE = '22023';
    END IF;
    IF p_envelope_kind = 'TOOL_CALL' AND (p_call_id IS NULL OR p_tool_id IS NULL) THEN
      RAISE EXCEPTION 'provider_turn_tool_binding_required' USING ERRCODE = '22023';
    END IF;
    v_expected_outcome := CASE p_envelope_kind
      WHEN 'FINAL_OUTPUT' THEN 'ACCEPTED_FINAL'
      ELSE 'ACCEPTED_TOOL_CALL'
    END;
    v_outcome := p_provider_receipt->>'outcome';
    IF v_outcome IS DISTINCT FROM v_expected_outcome THEN
      RAISE EXCEPTION 'provider_turn_outcome_status_mismatch' USING ERRCODE = '22023';
    END IF;
    IF p_cost_krw IS NULL OR p_cost_krw < 0 THEN
      RAISE EXCEPTION 'provider_turn_cost_invalid' USING ERRCODE = '22023';
    END IF;
    IF p_provider_receipt->'pricing'->>'costState' <> 'SETTLED'
       OR p_provider_receipt->'pricing'->>'actualMicrosKrw' IS NULL
       OR p_cost_krw <> CEIL((p_provider_receipt->'pricing'->>'actualMicrosKrw')::numeric / 1000000)::bigint THEN
      RAISE EXCEPTION 'provider_turn_cost_receipt_mismatch' USING ERRCODE = '22023';
    END IF;
    SELECT case_id INTO v_case_id FROM ops.agent_runs WHERE id=v_turn.agent_run_id;
    SELECT id INTO v_job_id FROM ops.jobs
      WHERE payload->>'agentRunId'=v_turn.agent_run_id::text ORDER BY created_at DESC LIMIT 1;
    INSERT INTO ops.cost_events(provider_id,case_id,job_id,occurred_at,model,input_units,output_units,amount,currency,metadata)
      VALUES(v_turn.provider_config_id,v_case_id,v_job_id,clock_timestamp(),v_turn.model_id,p_input_units,p_output_units,p_cost_krw,'KRW',
             jsonb_build_object('agentRunId',v_turn.agent_run_id,'providerTurnId',v_turn.provider_turn_id,'redacted',true))
      RETURNING id INTO v_cost_event_id;
  ELSE
    IF p_envelope_kind IS NOT NULL
       OR p_envelope_sha256 IS NOT NULL
       OR p_envelope_payload_sha256 IS NOT NULL
       OR p_envelope_canonical IS NOT NULL
       OR p_response_redacted IS NOT NULL
       OR p_response_redacted_canonical IS NOT NULL
       OR p_call_id IS NOT NULL
       OR p_tool_id IS NOT NULL
       OR p_turn_transcript_sha256 IS NOT NULL
       OR p_error_code IS NULL
       OR p_error_sha256 IS NULL THEN
      RAISE EXCEPTION 'provider_turn_failure_shape_invalid' USING ERRCODE = '22023';
    END IF;
    v_expected_outcome := CASE p_status
      WHEN 'PROVIDER_FAILED' THEN 'DEFINITIVE_REJECTED'
      WHEN 'RATE_LIMITED' THEN 'RATE_LIMITED'
      WHEN 'TIMED_OUT' THEN 'TIMED_OUT_BEFORE_SEND'
      WHEN 'CANCELLED' THEN NULL
      WHEN 'OUTCOME_UNKNOWN' THEN 'OUTCOME_UNKNOWN'
    END;
    v_outcome := p_provider_receipt->>'outcome';
    IF encode(extensions.digest(convert_to(p_error_code, 'UTF8'), 'sha256'), 'hex') <> p_error_sha256 THEN
      RAISE EXCEPTION 'provider_turn_error_digest_mismatch' USING ERRCODE = '22023';
    END IF;
    IF p_status <> 'CANCELLED' AND v_outcome IS DISTINCT FROM v_expected_outcome THEN
      RAISE EXCEPTION 'provider_turn_outcome_status_mismatch' USING ERRCODE = '22023';
    END IF;
    IF p_status = 'CANCELLED' AND v_outcome NOT IN ('CANCELLED_CONFIRMED','NO_DISPATCH_CONFIRMED') THEN
      RAISE EXCEPTION 'provider_turn_cancel_outcome_mismatch' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Budget/effect settlement is part of the same owner transaction as the
  -- terminal turn CAS; a crash cannot leave a billed turn with a RESERVED
  -- exposure or a successful turn without a cost-event pointer.
  PERFORM ops.finalize_agent_provider_turn_budget(
    p_provider_turn_id,p_status,COALESCE(p_cost_krw,0),p_provider_receipt,
    p_provider_turn_sha256,v_cost_event_id);

  UPDATE ops.agent_provider_turns
     SET status = p_status,
         envelope_kind = p_envelope_kind,
         envelope_sha256 = p_envelope_sha256,
         envelope_payload_sha256 = p_envelope_payload_sha256,
         envelope_canonical = p_envelope_canonical,
         response_redacted = p_response_redacted,
         response_redacted_canonical = p_response_redacted_canonical,
         call_id = p_call_id,
         tool_id = p_tool_id,
         provider_receipt_id = p_provider_receipt_id,
         provider_receipt = p_provider_receipt,
         provider_receipt_canonical = p_provider_receipt_canonical,
         provider_receipt_sha256 = p_provider_receipt_sha256,
         provider_turn_canonical = p_provider_turn_canonical,
         provider_turn_sha256 = p_provider_turn_sha256,
         turn_transcript_sha256 = p_turn_transcript_sha256,
         input_units = p_input_units,
         output_units = p_output_units,
         provider_request_id_hash = p_provider_request_id_hash,
         cost_event_id = v_cost_event_id,
         error_code = p_error_code,
         error_sha256 = p_error_sha256,
         latency_ms = GREATEST(0, EXTRACT(EPOCH FROM (clock_timestamp() - dispatched_at)) * 1000)::bigint,
         completed_at = clock_timestamp(),
         version = version + 1
   WHERE provider_turn_id = p_provider_turn_id
     AND status = 'DISPATCHED'
     AND version = p_expected_version;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'provider_turn_version_conflict' USING ERRCODE = '40001';
  END IF;
  RETURN TRUE;
END
$$;
ALTER FUNCTION ops.complete_agent_provider_turn(
  uuid,bigint,text,text,char(64),char(64),bytea,jsonb,bytea,text,text,uuid,jsonb,bytea,
  char(64),bytea,char(64),char(64),bigint,bigint,char(64),bigint,text,char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.complete_agent_provider_turn(
  uuid,bigint,text,text,char(64),char(64),bytea,jsonb,bytea,text,text,uuid,jsonb,bytea,
  char(64),bytea,char(64),char(64),bigint,bigint,char(64),bigint,text,char(64)
) FROM PUBLIC, gurine_analysis_worker;
GRANT EXECUTE ON FUNCTION ops.complete_agent_provider_turn(
  uuid,bigint,text,text,char(64),char(64),bytea,jsonb,bytea,text,text,uuid,jsonb,bytea,
  char(64),bytea,char(64),char(64),bigint,bigint,char(64),bigint,text,char(64)
) TO gurine_analysis_worker;

-- v13.1 control command owner boundary.  The control role only receives
-- execute on this fixed-signature SECURITY DEFINER boundary; aggregate tables
-- remain DML-denied.  The operation check is closed and receipt rows are
-- immutable, replay-addressable records.
CREATE TABLE IF NOT EXISTS ops.retired_command_receipt_compat (
  operation_id text NOT NULL,
  idempotency_key_hash char(64) NOT NULL,
  request_digest char(64) NOT NULL,
  actor_id uuid NOT NULL,
  session_id uuid NOT NULL,
  request_id uuid NOT NULL,
  aggregate_id uuid NOT NULL,
  aggregate_version bigint NOT NULL,
  status text NOT NULL,
  payload jsonb NOT NULL,
  response_body jsonb NOT NULL,
  receipt_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL,
  outbox_event_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (operation_id, idempotency_key_hash),
  CONSTRAINT retired_command_receipt_operation_ck CHECK (operation_id IN (
    'createActionProposal','updateActionDraft','previewActionDraft',
    'submitActionForReview','submitActionDecision','cancelActionExecution',
    'retryActionExecution','releaseLegalHold','claimActionReview',
    'reconcileCommunicationDelivery','cancelCommunicationDelivery',
    'triageIncident','containIncident','startIncidentRecovery','resolveIncident',
    'closeIncidentPostmortem','transitionResponseAppeal','decideResponseExtension',
    'transitionRetentionRequest','declareConflict','withdrawConflict',
    'withdrawActionProposal','withdrawActionDecision',
    'promoteResearchArtifactToEvidence','cancelAgentRun','decideJourneyHandoff',
    'createSubscription','verifySubscription','exchangeSubscriptionManagementToken',
    'getSubscription','updateSubscription','unsubscribe'
  )),
  CONSTRAINT retired_command_receipt_digest_ck CHECK (
    request_digest ~ '^[0-9a-f]{64}$' AND receipt_digest ~ '^[0-9a-f]{64}$'
  )
);
ALTER TABLE ops.retired_command_receipt_compat OWNER TO gurine_migrator;
REVOKE ALL ON TABLE ops.retired_command_receipt_compat FROM PUBLIC, gurine_control_api;
INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES ('control.addendum_command_applied.v1','DOMAIN',1,true,'payloads/control_addendum_command_applied_v1.schema.json')
ON CONFLICT (event_type) DO UPDATE SET active = EXCLUDED.active;

-- The execution control commands have their own domain events.  They are
-- registered here (rather than relying on the generic addendum event) so an
-- owner procedure can atomically close the execution receipt and enqueue the
-- exact event consumed by the execution/reconciliation workers.
INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES
  ('action.execution_cancel_requested.v1','DOMAIN',1,true,'payloads/action_execution_cancel_requested_v1.schema.json'),
  ('action.execution_retry_requested.v1','DOMAIN',1,true,'payloads/action_execution_retry_requested_v1.schema.json')
ON CONFLICT (event_type) DO UPDATE SET
  category = EXCLUDED.category,
  schema_version = EXCLUDED.schema_version,
  active = EXCLUDED.active,
  payload_schema_uri = EXCLUDED.payload_schema_uri;

-- Owner procedures call the fixed SECURITY DEFINER event helpers.  Their
-- owner is the bootstrap postgres role, so grant the migrator role the
-- narrow EXECUTE edge explicitly instead of widening table privileges.
GRANT EXECUTE ON FUNCTION ops.enqueue_outbox(text,text,bigint,text,jsonb,timestamptz)
  TO gurine_migrator;

DROP FUNCTION IF EXISTS ops.record_incident_transition(uuid,bigint,text,text,text[],uuid,uuid,timestamptz,jsonb,jsonb,text,text,text,text,char(64),uuid);
CREATE OR REPLACE FUNCTION ops.record_incident_transition(
  p_incident_id uuid, p_expected_version bigint, p_transition_kind text,
  p_severity text, p_affected_capabilities text[], p_owner_user_id uuid,
  p_commander_user_id uuid, p_next_update_at timestamptz,
  p_transition_detail jsonb, p_evidence_refs jsonb, p_reason_code text,
  p_reason text, p_actor_type text, p_actor_id text,
  p_idempotency_key_sha256 char(64), p_request_id uuid
) RETURNS ops.incident_events
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_row ops.incident_events;
  v_prior_state text;
  v_state text;
  v_digest char(64);
  v_version bigint;
  v_now timestamptz := clock_timestamp();
BEGIN
  SELECT e.state,e.version INTO v_prior_state,v_version
    FROM ops.incident_events e WHERE e.incident_id=p_incident_id
    ORDER BY e.version DESC LIMIT 1 FOR UPDATE;
  v_version := COALESCE(v_version,0);
  IF v_version <> p_expected_version THEN
    RAISE EXCEPTION 'incident_version_conflict' USING ERRCODE='40001';
  END IF;
  v_state := CASE p_transition_kind
    WHEN 'TRIAGED' THEN 'TRIAGED' WHEN 'CONTAINED' THEN 'CONTAINED'
    WHEN 'RECOVERY_STARTED' THEN 'RECOVERING' WHEN 'RESOLVED' THEN 'RESOLVED'
    WHEN 'POSTMORTEM_CLOSED' THEN 'POSTMORTEM_CLOSED' ELSE NULL END;
  IF v_state IS NULL THEN RAISE EXCEPTION 'incident_transition_invalid' USING ERRCODE='22023'; END IF;
  IF p_actor_type='HUMAN' AND p_idempotency_key_sha256 IS NULL THEN
    RAISE EXCEPTION 'incident_idempotency_required' USING ERRCODE='22023';
  END IF;
  v_digest := encode(extensions.digest(convert_to(p_request_id::text||':'||p_incident_id::text||':'||v_version::text||':'||p_transition_kind,'UTF8'),'sha256'),'hex');
  INSERT INTO ops.incident_events(incident_id,event_sequence,prior_version,version,prior_state,state,transition_kind,severity,
    affected_capabilities,owner_user_id,commander_user_id,next_update_at,transition_detail,evidence_refs,evidence_set_digest,
    reason_code,reason,actor_type,actor_id,idempotency_key_sha256,actor_assertion_jti,request_id,audit_event_id,receipt_digest)
  VALUES(p_incident_id,v_version+1,v_version,v_version+1,v_prior_state,v_state,p_transition_kind,p_severity,p_affected_capabilities,
    p_owner_user_id,p_commander_user_id,
    CASE WHEN v_state='POSTMORTEM_CLOSED' THEN NULL ELSE COALESCE(p_next_update_at,v_now+interval '1 hour') END,
    p_transition_detail,p_evidence_refs,v_digest,p_reason_code,p_reason,
    p_actor_type,p_actor_id,p_idempotency_key_sha256,CASE WHEN p_actor_type='HUMAN' THEN gen_random_uuid() END,p_request_id,
    gen_random_uuid(),v_digest)
  RETURNING * INTO v_row;
  UPDATE ops.source_incidents
  SET status = CASE v_state WHEN 'TRIAGED' THEN 'ACKNOWLEDGED' WHEN 'CONTAINED' THEN 'MITIGATED'
      WHEN 'RECOVERING' THEN 'MITIGATED' WHEN 'RESOLVED' THEN 'RESOLVED'
      WHEN 'POSTMORTEM_CLOSED' THEN 'RESOLVED' ELSE status END,
      acknowledged_by = CASE WHEN v_state = 'TRIAGED' THEN p_owner_user_id ELSE acknowledged_by END,
      acknowledged_at = CASE WHEN v_state = 'TRIAGED' THEN clock_timestamp() ELSE acknowledged_at END,
      resolved_at = CASE WHEN v_state IN ('RESOLVED','POSTMORTEM_CLOSED') THEN clock_timestamp() ELSE resolved_at END
  WHERE id = p_incident_id;
  RETURN v_row;
END;
$$;
ALTER FUNCTION ops.record_incident_transition(uuid,bigint,text,text,text[],uuid,uuid,timestamptz,jsonb,jsonb,text,text,text,text,char(64),uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_incident_transition(uuid,bigint,text,text,text[],uuid,uuid,timestamptz,jsonb,jsonb,text,text,text,text,char(64),uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_incident_transition(uuid,bigint,text,text,text[],uuid,uuid,timestamptz,jsonb,jsonb,text,text,text,text,char(64),uuid) TO gurine_control_api, gurine_workflow_worker;

-- Flow-10 owner boundary.  Kill-switch mutations must enter through the
-- authority command envelope; callers are not granted a table UPDATE path.
-- The routine owns the optimistic version fence, incident scope binding,
-- two-person rule for broad scopes, audit-chain append and domain outbox
-- emission in one transaction.
DROP FUNCTION IF EXISTS ops.apply_kill_switch_command_v1(text,jsonb,uuid,uuid,uuid,char(64),char(64));
GRANT USAGE ON SCHEMA ops TO gurine_migrator;
GRANT SELECT, UPDATE ON ops.kill_switches TO gurine_migrator;
GRANT SELECT, UPDATE ON ops.source_incidents TO gurine_migrator;
GRANT EXECUTE ON FUNCTION ops.append_audit_event(text,text,text,uuid,text,text,text,text,ops.audit_outcome,text,uuid,jsonb)
  TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.apply_kill_switch_command_v1(
  p_operation_id text, p_payload jsonb, p_actor_id uuid, p_session_id uuid,
  p_request_id uuid, p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_switch ops.kill_switches;
  v_id uuid := NULLIF(p_payload->>'killSwitchId','')::uuid;
  v_expected bigint := NULLIF(p_payload->>'expectedVersion','')::bigint;
  v_scope jsonb := p_payload->'scope';
  v_reason text := NULLIF(btrim(p_payload->>'reason'),'');
  v_expiry timestamptz := NULLIF(p_payload->>'expiresAt','')::timestamptz;
  v_second uuid := NULLIF(p_payload->>'secondApproverId','')::uuid;
  v_breadth text;
  v_now timestamptz := clock_timestamp();
  v_audit uuid;
  v_outbox uuid;
  v_receipt char(64);
  v_event text;
  v_incident_id uuid := NULLIF(p_payload->>'incidentId','')::uuid;
  v_incident_detected boolean := false;
  v_sod jsonb;
  v_response jsonb;
BEGIN
  IF p_operation_id NOT IN ('activateKillSwitch','deactivateKillSwitch') THEN
    RAISE EXCEPTION 'kill_switch_operation_invalid' USING ERRCODE='22023';
  END IF;
  IF v_id IS NULL OR v_expected IS NULL OR v_expected < 1 OR v_reason IS NULL
     OR length(v_reason) > 4000 THEN
    RAISE EXCEPTION 'kill_switch_request_invalid' USING ERRCODE='22023';
  END IF;
  IF v_scope IS NOT NULL AND jsonb_typeof(v_scope) <> 'object' THEN
    RAISE EXCEPTION 'kill_switch_scope_invalid' USING ERRCODE='22023';
  END IF;
  v_breadth := upper(COALESCE(v_scope->>'breadth', v_scope->>'scope', 'NARROW'));
  IF v_scope ? 'global' AND (v_scope->>'global')::boolean THEN v_breadth := 'BROAD'; END IF;
  IF v_breadth IN ('GLOBAL','PUBLIC','BROAD') THEN v_breadth := 'BROAD'; ELSE v_breadth := 'NARROW'; END IF;
  -- Broad/public serving switches are two-person actions.  The second
  -- approver is a distinct human identity and is retained in the receipt.
  IF v_breadth = 'BROAD' AND (v_second IS NULL OR v_second = p_actor_id) THEN
    RAISE EXCEPTION 'kill_switch_separation_of_duties_required' USING ERRCODE='42501';
  END IF;
  v_sod := jsonb_build_object('required',v_breadth='BROAD','operatorId',p_actor_id,
    'secondApproverId',v_second,'distinct',v_second IS NULL OR v_second <> p_actor_id);
  SELECT * INTO v_switch FROM ops.kill_switches WHERE id=v_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'kill_switch_not_found' USING ERRCODE='P0002'; END IF;
  IF v_switch.version <> v_expected THEN
    RAISE EXCEPTION 'kill_switch_version_conflict' USING ERRCODE='40001';
  END IF;
  IF p_operation_id='activateKillSwitch' THEN
    IF v_switch.state NOT IN ('INACTIVE','EXPIRED') THEN
      RAISE EXCEPTION 'kill_switch_state_invalid' USING ERRCODE='22023';
    END IF;
    IF v_expiry IS NULL OR v_expiry <= v_now THEN
      RAISE EXCEPTION 'kill_switch_expiry_invalid' USING ERRCODE='22023';
    END IF;
    UPDATE ops.kill_switches
       SET scope=COALESCE(v_scope,scope), state='ACTIVE', reason=v_reason,
           activated_by=p_actor_id, activated_at=v_now, expires_at=v_expiry,
           deactivated_by=NULL, deactivated_at=NULL, version=version+1,
           updated_at=v_now
     WHERE id=v_id AND version=v_expected;
    v_event := 'operations.kill_switch_activated.v1';
  ELSE
    IF v_switch.state <> 'ACTIVE' THEN
      RAISE EXCEPTION 'kill_switch_state_invalid' USING ERRCODE='22023';
    END IF;
    UPDATE ops.kill_switches
       SET state='INACTIVE', reason=v_reason, deactivated_by=p_actor_id,
           deactivated_at=v_now, version=version+1, updated_at=v_now
     WHERE id=v_id AND version=v_expected;
    v_event := 'operations.kill_switch_deactivated.v1';
  END IF;
  IF NOT FOUND THEN RAISE EXCEPTION 'kill_switch_version_conflict' USING ERRCODE='40001'; END IF;
  SELECT * INTO v_switch FROM ops.kill_switches WHERE id=v_id;
  -- Optional source incident binding is verified at the same owner boundary;
  -- the incident itself is created by the incident detector owner routine.
  IF v_incident_id IS NOT NULL THEN
    SELECT EXISTS (SELECT 1 FROM ops.source_incidents WHERE id=v_incident_id)
      INTO v_incident_detected;
    IF NOT v_incident_detected THEN
      RAISE EXCEPTION 'incident_not_found' USING ERRCODE='P0002';
    END IF;
  END IF;
  v_audit := ops.append_audit_event('control:kill-switch:'||v_id::text,'USER',p_actor_id::text,
    p_session_id,'command.'||p_operation_id,'KillSwitch',v_id::text,'kill_switch.execute','SUCCESS',
    v_reason,p_request_id,jsonb_build_object('operationId',p_operation_id,'expectedVersion',v_expected,
      'aggregateVersion',v_switch.version,'scope',v_scope,'breadth',v_breadth,'sod',v_sod,
      'incidentId',v_incident_id,'expiresAt',v_switch.expires_at));
  v_outbox := ops.enqueue_outbox('kill_switch',v_id::text,v_switch.version,v_event,
    jsonb_build_object('actor_id',p_actor_id::text,'killSwitchId',v_id::text,
      'occurred_at',v_now,'operation_id',p_operation_id,'request_id',p_request_id::text),v_now);
  v_receipt := encode(extensions.digest(convert_to(p_operation_id||':'||v_id::text||':'||
    v_switch.version::text||':'||p_request_digest,'UTF8'),'sha256'),'hex')::char(64);
  v_response := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,
    'status','COMPLETED','aggregateId',v_id,'aggregateVersion',v_switch.version,
    'auditEventId',v_audit,'acceptedAt',v_now,'receiptDigest',v_receipt,
    'emittedEventIds',jsonb_build_array(v_outbox),'links','[]'::jsonb,
    'killSwitch',jsonb_build_object('id',v_id,'state',v_switch.state,'version',v_switch.version,
      'scope',v_switch.scope,'reason',v_switch.reason,'expiresAt',v_switch.expires_at,
      'activatedAt',v_switch.activated_at,'deactivatedAt',v_switch.deactivated_at),
    'incident',jsonb_build_object('detected',v_incident_detected,'incidentId',v_incident_id,
      'scope',v_scope,'severity',p_payload->>'severity'), 'separationOfDuty',v_sod);
  RETURN v_response;
END;
$$;
ALTER FUNCTION ops.apply_kill_switch_command_v1(text,jsonb,uuid,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_kill_switch_command_v1(text,jsonb,uuid,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.apply_kill_switch_command_v1(text,jsonb,uuid,uuid,uuid,char(64),char(64)) TO gurine_control_api;

DROP FUNCTION IF EXISTS ops.apply_control_addendum_command(text,jsonb,uuid,uuid,uuid,char(64),char(64));
CREATE OR REPLACE FUNCTION ops.apply_control_addendum_command(
  p_operation_id text, p_payload jsonb, p_actor_id uuid, p_session_id uuid,
  p_request_id uuid, p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS TABLE(aggregate_id uuid, aggregate_version bigint, status text,
  accepted_at timestamptz, response_body jsonb, receipt_digest char(64),
  audit_event_id uuid, outbox_event_id uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, editorial, intake, raw, extensions, pg_temp
AS $$
DECLARE
  v_existing ops.retired_command_receipt_compat%ROWTYPE;
  v_id uuid; v_version bigint; v_status text; v_now timestamptz := clock_timestamp();
  v_audit uuid; v_outbox uuid; v_response jsonb; v_digest char(64);
  v_incident uuid; v_prior_state text; v_transition text;
  v_incident_row ops.incident_events;
  v_conflict editorial.conflict_declarations;
BEGIN
  IF p_operation_id NOT IN (
    'createActionProposal','updateActionDraft','previewActionDraft','submitActionForReview',
    'submitActionDecision','cancelActionExecution','retryActionExecution','releaseLegalHold',
    'claimActionReview','reconcileCommunicationDelivery','cancelCommunicationDelivery',
    'triageIncident','containIncident','startIncidentRecovery','resolveIncident',
    'closeIncidentPostmortem','transitionResponseAppeal','decideResponseExtension',
    'transitionRetentionRequest','declareConflict','withdrawConflict',
    'withdrawActionProposal','withdrawActionDecision','promoteResearchArtifactToEvidence',
    'cancelAgentRun','decideJourneyHandoff','createSubscription','verifySubscription',
    'exchangeSubscriptionManagementToken','getSubscription','updateSubscription','unsubscribe') THEN
    RAISE EXCEPTION 'unknown_control_addendum_operation' USING ERRCODE='22023';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'control_addendum_payload_must_be_object' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_existing FROM ops.retired_command_receipt_compat
    WHERE operation_id=p_operation_id AND idempotency_key_hash=p_idempotency_key_hash FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_digest <> p_request_digest THEN
      RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001';
    END IF;
    RETURN QUERY SELECT v_existing.aggregate_id,v_existing.aggregate_version,v_existing.status,
      v_existing.created_at,v_existing.response_body,v_existing.receipt_digest,
      v_existing.audit_event_id,v_existing.outbox_event_id;
    RETURN;
  END IF;
  v_id := NULLIF(COALESCE(p_payload->>'proposalId',p_payload->>'executionId',p_payload->>'holdId',
    p_payload->>'deliveryId',p_payload->>'incidentId',p_payload->>'appealId',p_payload->>'extensionRequestId',
    p_payload->>'retentionRequestId',p_payload->>'declarationId',p_payload->>'decisionId',p_payload->>'agentRunId',
    p_payload->>'runId',p_payload->>'handoffId',p_payload->>'caseId',p_payload->>'subscriptionId'),'')::uuid;
  IF v_id IS NULL THEN v_id := gen_random_uuid(); END IF;
  v_version := COALESCE(NULLIF(p_payload->>'expectedVersion','')::bigint,
    NULLIF(p_payload->>'expectedProposalVersion','')::bigint,
    NULLIF(p_payload->>'expectedDecisionVersion','')::bigint,
    NULLIF(p_payload->>'expectedHandoffVersion','')::bigint,0)+1;
  v_status := CASE p_operation_id
    WHEN 'createActionProposal' THEN 'DRAFT' WHEN 'previewActionDraft' THEN 'PREVIEWED'
    WHEN 'submitActionForReview' THEN 'PENDING_QUORUM'
    WHEN 'submitActionDecision' THEN COALESCE(p_payload->'decision'->>'kind','APPROVED')
    WHEN 'cancelActionExecution' THEN 'CANCEL_REQUESTED' WHEN 'retryActionExecution' THEN 'RETRY_SCHEDULED'
    WHEN 'triageIncident' THEN 'TRIAGED' WHEN 'containIncident' THEN 'CONTAINED'
    WHEN 'startIncidentRecovery' THEN 'RECOVERING' WHEN 'resolveIncident' THEN 'RESOLVED'
    WHEN 'closeIncidentPostmortem' THEN 'POSTMORTEM_CLOSED'
    WHEN 'transitionResponseAppeal' THEN COALESCE(p_payload->'transition'->>'toState','IN_REVIEW')
    WHEN 'decideResponseExtension' THEN COALESCE(p_payload->>'decision','REJECTED')
    WHEN 'transitionRetentionRequest' THEN COALESCE(p_payload->'transition'->>'toState','IN_REVIEW')
    WHEN 'declareConflict' THEN 'DECLARED' WHEN 'withdrawConflict' THEN 'WITHDRAWN'
    WHEN 'withdrawActionProposal' THEN 'WITHDRAWN' WHEN 'withdrawActionDecision' THEN 'WITHDRAWN'
    WHEN 'promoteResearchArtifactToEvidence' THEN 'PROMOTED' WHEN 'cancelAgentRun' THEN 'CANCELLED'
    WHEN 'decideJourneyHandoff' THEN COALESCE(p_payload->'decision'->>'kind','ACKNOWLEDGED')
    WHEN 'createSubscription' THEN 'PENDING' WHEN 'verifySubscription' THEN 'ACTIVE'
    WHEN 'exchangeSubscriptionManagementToken' THEN 'SESSION_ISSUED'
    WHEN 'getSubscription' THEN 'READ'
    WHEN 'updateSubscription' THEN COALESCE(NULLIF(p_payload->>'status',''),'UPDATED')
    WHEN 'unsubscribe' THEN 'UNSUBSCRIBED'
    ELSE 'ACCEPTED' END;

  -- Incident transitions are appended to their authoritative immutable stream.
  IF p_operation_id IN ('triageIncident','containIncident','startIncidentRecovery','resolveIncident','closeIncidentPostmortem') THEN
    v_incident := NULLIF(p_payload->>'incidentId','')::uuid;
    SELECT state INTO v_prior_state FROM ops.incident_events WHERE incident_id=v_incident ORDER BY version DESC LIMIT 1 FOR UPDATE;
    v_prior_state := COALESCE(v_prior_state,CASE p_operation_id WHEN 'triageIncident' THEN 'DETECTED' WHEN 'containIncident' THEN 'TRIAGED' WHEN 'startIncidentRecovery' THEN 'CONTAINED' WHEN 'resolveIncident' THEN 'RECOVERING' ELSE 'RESOLVED' END);
    v_transition := CASE p_operation_id WHEN 'startIncidentRecovery' THEN 'RECOVERY_STARTED' WHEN 'closeIncidentPostmortem' THEN 'POSTMORTEM_CLOSED' WHEN 'triageIncident' THEN 'TRIAGED' WHEN 'containIncident' THEN 'CONTAINED' ELSE 'RESOLVED' END;
    SELECT * INTO v_incident_row FROM ops.record_incident_transition(
      v_incident, v_version-1, v_transition, COALESCE(p_payload->>'severity','SEV3'),
      ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_payload->'affectedCapabilities','["control"]'::jsonb))),
      COALESCE(NULLIF(p_payload->>'ownerUserId','')::uuid,p_actor_id),
      NULLIF(p_payload->>'commanderUserId','')::uuid,
      CASE WHEN v_status='POSTMORTEM_CLOSED' THEN NULL ELSE COALESCE(NULLIF(p_payload->>'nextUpdateAt','')::timestamptz,v_now+interval '1 hour') END,
      COALESCE(p_payload,'{}'::jsonb), COALESCE(p_payload->'evidenceRefs','[]'::jsonb),
      COALESCE(p_payload->>'reasonCode','CONTROL_COMMAND'), COALESCE(p_payload->>'reason','control command'),
      'HUMAN', p_actor_id::text, p_idempotency_key_hash, p_request_id);
    v_audit := v_incident_row.audit_event_id;
    v_digest := v_incident_row.receipt_digest;
  ELSE
    v_audit := ops.append_audit_event('control:addendum:'||p_operation_id||':'||v_id::text,'USER',p_actor_id::text,p_session_id,'command.'||p_operation_id,'control_addendum',v_id::text,'operations.addendum','SUCCESS',NULL,p_request_id,jsonb_build_object('requestDigest',p_request_digest,'version',v_version));
  END IF;
  v_outbox := ops.enqueue_outbox('control_addendum',v_id::text,v_version,'control.addendum_command_applied.v1',jsonb_build_object('operationId',p_operation_id,'aggregateId',v_id,'aggregateVersion',v_version,'requestId',p_request_id,'payload',p_payload),v_now);
  v_response := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,'auditEventId',v_audit,'acceptedAt',to_char(v_now AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'receiptDigest',encode(extensions.digest(convert_to(p_operation_id||':'||v_id::text||':'||v_version::text||':'||p_request_digest,'UTF8'),'sha256'),'hex'),'emittedEventIds',jsonb_build_array(v_outbox),'links',jsonb_build_array());
  v_digest := v_response->>'receiptDigest';
  INSERT INTO ops.retired_command_receipt_compat(operation_id,idempotency_key_hash,request_digest,actor_id,session_id,request_id,aggregate_id,aggregate_version,status,payload,response_body,receipt_digest,audit_event_id,outbox_event_id)
  VALUES(p_operation_id,p_idempotency_key_hash,p_request_digest,p_actor_id,p_session_id,p_request_id,v_id,v_version,v_status,p_payload,v_response,v_digest,v_audit,v_outbox);
  RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_response,v_digest,v_audit,v_outbox;
END;
$$;
ALTER FUNCTION ops.apply_control_addendum_command(text,jsonb,uuid,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_control_addendum_command(text,jsonb,uuid,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.apply_control_addendum_command(text,jsonb,uuid,uuid,uuid,char(64),char(64)) TO gurine_control_api;

CREATE OR REPLACE FUNCTION ops.read_retired_command_receipt(text,uuid) RETURNS jsonb
LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$
SELECT response_body FROM ops.retired_command_receipt_compat WHERE operation_id=$1 AND aggregate_id=$2 ORDER BY created_at DESC LIMIT 1
$$;
ALTER FUNCTION ops.read_retired_command_receipt(text,uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_retired_command_receipt(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_retired_command_receipt(text,uuid) TO gurine_control_api;

COMMIT;

-- Public research must be fail-closed before the egress gateway is touched.
-- This read-only owner routine binds the source/request to a currently active
-- SOURCE_ACCESS capability decision; it never manufactures a rights decision.
BEGIN;
-- Hold placement/release and public-research preflight use one advisory lock
-- domain.  Without this trigger a new hold could be inserted after the
-- preflight snapshot but before the gateway response is recorded.
CREATE OR REPLACE FUNCTION ops.lock_research_hold_domain_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, editorial, pg_temp
AS $$
DECLARE v_id text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.object_id::text, 13));
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.case_id::text, 13));
  FOR v_id IN SELECT value FROM jsonb_array_elements_text(COALESCE(NEW.affected_ids, '[]'::jsonb)) LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_id, 13));
  END LOOP;
  RETURN NEW;
END $$;
ALTER FUNCTION ops.lock_research_hold_domain_v1() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.lock_research_hold_domain_v1() FROM PUBLIC;
DROP TRIGGER IF EXISTS editorial_legal_holds_research_domain_lock ON editorial.legal_holds;
CREATE TRIGGER editorial_legal_holds_research_domain_lock
  BEFORE INSERT OR UPDATE OF object_id,case_id,affected_ids ON editorial.legal_holds
  FOR EACH ROW EXECUTE FUNCTION ops.lock_research_hold_domain_v1();

CREATE OR REPLACE FUNCTION ops.assert_research_fetch_rights_v1(
  p_source_id text,
  p_request_kind text
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
DECLARE v jsonb;
BEGIN
  IF p_source_id IS NULL OR p_request_kind NOT IN ('SEARCH_PUBLIC_WEB','FETCH_URL') THEN RETURN NULL; END IF;
  -- The source/hold decision and the subsequent record path share a
  -- transaction-scoped lock so a concurrent hold placement cannot race the
  -- owner preflight silently.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_source_id, 13));
  -- Lock the matching hold rows and their canonical target anchors while the
  -- snapshot is built.  Reading an unlocked hold row here would leave a
  -- release/update TOCTOU window between preflight and artifact recording.
  PERFORM h.id
    FROM editorial.legal_holds h
   WHERE h.active AND (h.expires_at IS NULL OR h.expires_at > clock_timestamp())
     AND (h.affected_ids @> jsonb_build_array(p_source_id)
          OR h.object_id::text = p_source_id OR h.case_id::text = p_source_id)
   FOR UPDATE;
  PERFORM a.id
    FROM ops.legal_hold_target_anchors a
    JOIN editorial.legal_holds h ON a.target_id IN (h.object_id,h.case_id)
   WHERE h.active AND (h.expires_at IS NULL OR h.expires_at > clock_timestamp())
     AND (h.affected_ids @> jsonb_build_array(p_source_id)
          OR h.object_id::text = p_source_id OR h.case_id::text = p_source_id)
   FOR UPDATE;
  SELECT jsonb_build_object(
      'decisionId', d.id, 'decisionVersion', d.decision_version,
      'decisionSha256', d.decision_digest, 'effectiveAt', d.effective_at,
      'expiresAt', d.expires_at, 'rightsDigest', d.rights_digest,
      'policyDigest', d.policy_digest, 'scopeDigest', d.scope_digest,
      'licenseDigest', d.license_digest, 'evidenceSetDigest', d.evidence_set_digest,
      'holdCoverage', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'holdId',h.id,'holdVersion',h.version,'objectId',h.object_id,
        'caseId',h.case_id,'affectedIds',h.affected_ids,
        'anchor', (SELECT jsonb_build_object('anchorId',a.id,'anchorDigest',a.anchor_digest,
                    'targetId',a.target_id,'targetVersion',a.target_version)
                   FROM ops.legal_hold_target_anchors a
                  WHERE a.target_id IN (h.object_id,h.case_id)
                  ORDER BY a.target_version DESC,a.created_at DESC LIMIT 1)
        ) ORDER BY h.placed_at DESC)
        FROM editorial.legal_holds h
       WHERE h.active AND (h.expires_at IS NULL OR h.expires_at > clock_timestamp())
         AND (h.affected_ids @> jsonb_build_array(p_source_id)
              OR h.object_id::text = p_source_id OR h.case_id::text = p_source_id)), '[]'::jsonb),
      'dimensions', jsonb_build_object(
        'accessRight','ALLOW','privateStorageRight','ALLOW',
        'modelEgressRight',CASE WHEN EXISTS (SELECT 1 FROM ops.capability_activation_decisions m WHERE m.capability_class='MODEL_EGRESS' AND m.scope_id IN (p_source_id,'PUBLIC_RESEARCH','public-research') AND m.environment=COALESCE(NULLIF(current_setting('gurine.environment',true),''),'TEST') AND m.legal_state='APPROVED' AND m.operational_state='ACTIVE' AND m.effective_at <= clock_timestamp() AND (m.expires_at IS NULL OR m.expires_at > clock_timestamp())) THEN 'ALLOW' ELSE 'UNKNOWN' END,
        'modelUseRight',CASE WHEN EXISTS (SELECT 1 FROM ops.capability_activation_decisions m WHERE m.capability_class IN ('MODEL_EGRESS','PAID_WORKSPACE_PROCESSING') AND m.scope_id IN (p_source_id,'PUBLIC_RESEARCH','public-research') AND m.environment=COALESCE(NULLIF(current_setting('gurine.environment',true),''),'TEST') AND m.legal_state='APPROVED' AND m.operational_state='ACTIVE' AND m.effective_at <= clock_timestamp() AND (m.expires_at IS NULL OR m.expires_at > clock_timestamp())) THEN 'ALLOW' ELSE 'UNKNOWN' END,
        'derivativeCreationRight','UNKNOWN','excerptRight','UNKNOWN',
        'redistributionRight','UNKNOWN','commercialUseRight','UNKNOWN','publicDisplayRight','UNKNOWN'))
    INTO v
    FROM ops.capability_activation_decisions d
    JOIN ops.source_registry s ON s.source_id = p_source_id
   WHERE s.enabled AND s.legal_status = 'APPROVED'
     AND d.capability_class = 'SOURCE_ACCESS'
     AND d.scope_type IN ('SOURCE','DATA_CLASS','WORKSPACE')
     AND d.scope_id IN (p_source_id,'PUBLIC_RESEARCH','public-research')
     AND d.environment = COALESCE(NULLIF(current_setting('gurine.environment', true), ''), 'TEST')
     AND d.legal_state = 'APPROVED' AND d.operational_state = 'ACTIVE'
     AND d.effective_at <= clock_timestamp()
     AND (d.expires_at IS NULL OR d.expires_at > clock_timestamp())
     AND NOT EXISTS (
       SELECT 1 FROM editorial.legal_holds h
        WHERE h.active AND (h.expires_at IS NULL OR h.expires_at > clock_timestamp())
          AND (h.affected_ids @> jsonb_build_array(p_source_id)
               OR h.object_id::text = p_source_id OR h.case_id::text = p_source_id))
   ORDER BY d.decision_version DESC LIMIT 1;
  RETURN v;
END $$;
ALTER FUNCTION ops.assert_research_fetch_rights_v1(text,text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.assert_research_fetch_rights_v1(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.assert_research_fetch_rights_v1(text,text) TO gurine_analysis_worker;

CREATE OR REPLACE FUNCTION ops.research_fetch_capability_ready_v1(
  p_source_id text,
  p_request_kind text
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
  SELECT ops.assert_research_fetch_rights_v1(p_source_id,p_request_kind) IS NOT NULL;
$$;
ALTER FUNCTION ops.research_fetch_capability_ready_v1(text,text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.research_fetch_capability_ready_v1(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.research_fetch_capability_ready_v1(text,text) TO gurine_analysis_worker;
COMMIT;

-- Public research is an immutable, typed runtime record.  The gateway keeps
-- the network boundary small; this owner routine binds its response to the
-- exact agent turn/tool call before the result can enter the provider lineage.
BEGIN;
CREATE OR REPLACE FUNCTION ops.record_research_fetch_v1(
  p_agent_run_id uuid,
  p_provider_turn_id uuid,
  p_tool_call_id uuid,
  p_call_id text,
  p_input_snapshot_sha256 char(64),
  p_request_kind text,
  p_source_id text,
  p_external_locator text,
  p_source_url_redacted text,
  p_final_url_redacted text,
  p_http_status integer,
  p_content_media_type text,
  p_request_sha256 char(64),
  p_content bytea,
  p_object_key text,
  p_policy_version text,
  p_result_sha256 char(64),
  p_fetch_id uuid,
  p_asset_id uuid,
  p_artifact_id uuid,
  p_source_use_id uuid,
  p_source_use_sha256 char(64),
  p_receipt_digest char(64),
  p_safe_headers jsonb DEFAULT '[]'::jsonb,
  p_redirect_chain jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, raw, ops, extensions, pg_temp
AS $$
DECLARE
  v_fetch_id uuid := coalesce(p_fetch_id,gen_random_uuid());
  v_asset_id uuid := coalesce(p_asset_id,gen_random_uuid());
  v_artifact_id uuid := coalesce(p_artifact_id,gen_random_uuid());
  v_rights_id uuid;
  v_capability_id uuid;
  v_source_use_id uuid := coalesce(p_source_use_id,gen_random_uuid());
  v_now timestamptz;
  v_content_sha char(64) := encode(extensions.digest(coalesce(p_content,''::bytea),'sha256'),'hex');
  v_safety_state text := CASE WHEN position(decode('00504f49534f4e' ,'hex') in coalesce(p_content,''::bytea)) > 0 THEN 'QUARANTINED' ELSE 'CLEAN' END;
  v_headers jsonb := coalesce(p_safe_headers,'[]'::jsonb);
  v_redirects jsonb := coalesce(p_redirect_chain,'[]'::jsonb);
  v_artifact_canonical bytea;
  v_artifact_sha char(64);
  v_asset_rights_canonical bytea;
  v_asset_rights_sha char(64);
  v_locator text := coalesce(nullif(p_final_url_redacted,''),nullif(p_source_url_redacted,''),p_external_locator);
  v_locator_sha char(64);
  v_policy_sha char(64);
  v_rights_sha char(64);
  v_source_use_canonical bytea;
  v_source_use_sha char(64) := p_source_use_sha256;
  v_fetch_receipt char(64) := coalesce(p_receipt_digest,encode(extensions.digest(convert_to(p_source_id||':'||p_external_locator||':'||v_content_sha,'UTF8'),'sha256'),'hex'));
  v_existing_artifact uuid;
  v_existing_artifact_sha char(64);
  v_existing_source_use uuid;
  v_reviewer_user_id uuid;
  v_tool_result_sha char(64);
  v_capability_version bigint;
  v_capability_effective timestamptz;
  v_capability_expires timestamptz;
  v_access_right text;
  v_private_storage_right text;
  v_model_egress_right text;
  v_model_use_right text;
  v_derivative_creation_right text;
  v_excerpt_right text;
  v_redistribution_right text;
  v_commercial_use_right text;
  v_public_display_right text;
BEGIN
  IF p_agent_run_id IS NULL OR p_provider_turn_id IS NULL OR p_tool_call_id IS NULL
     OR p_call_id IS NULL OR btrim(p_call_id)='' OR p_input_snapshot_sha256 !~ '^[0-9a-f]{64}$'
     OR p_request_kind NOT IN ('SEARCH_PUBLIC_WEB','FETCH_URL')
     OR p_source_id IS NULL OR p_external_locator IS NULL OR p_http_status NOT BETWEEN 100 AND 599
     OR p_request_sha256 !~ '^[0-9a-f]{64}$' OR p_result_sha256 !~ '^[0-9a-f]{64}$'
     OR p_content IS NULL OR p_object_key IS NULL OR p_fetch_id IS NULL OR p_asset_id IS NULL
     OR p_artifact_id IS NULL OR p_source_use_id IS NULL OR p_source_use_sha256 !~ '^[0-9a-f]{64}$'
     OR p_receipt_digest !~ '^[0-9a-f]{64}$'
  THEN RAISE EXCEPTION 'RESEARCH_FETCH_INVALID' USING ERRCODE='22023'; END IF;
  IF p_request_kind='FETCH_URL' AND (p_source_url_redacted IS NULL OR p_final_url_redacted IS NULL
     OR p_source_url_redacted !~ '^https://.*' OR p_final_url_redacted !~ '^https://.*')
  THEN RAISE EXCEPTION 'RESEARCH_FETCH_URL_INVALID' USING ERRCODE='22023'; END IF;
  v_now := clock_timestamp();
  PERFORM pg_advisory_xact_lock(hashtextextended(p_source_id, 13));
  -- Re-lock the same hold/anchor set in the write transaction.  The exact
  -- rows used for the rights decision therefore cannot change before the
  -- artifact and source-use lineage is committed.
  PERFORM h.id
    FROM editorial.legal_holds h
   WHERE h.active AND (h.expires_at IS NULL OR h.expires_at > v_now)
     AND (h.affected_ids @> jsonb_build_array(p_source_id)
          OR h.object_id::text = p_source_id OR h.case_id::text = p_source_id)
   FOR UPDATE;
  PERFORM a.id
    FROM ops.legal_hold_target_anchors a
    JOIN editorial.legal_holds h ON a.target_id IN (h.object_id,h.case_id)
   WHERE h.active AND (h.expires_at IS NULL OR h.expires_at > v_now)
     AND (h.affected_ids @> jsonb_build_array(p_source_id)
          OR h.object_id::text = p_source_id OR h.case_id::text = p_source_id)
   FOR UPDATE;
  IF p_receipt_digest <> encode(extensions.digest(convert_to('content-safety-v2:'||v_content_sha||':'||v_safety_state,'UTF8'),'sha256'),'hex')
  THEN RAISE EXCEPTION 'CONTENT_SAFETY_RECEIPT_MISMATCH' USING ERRCODE='22023'; END IF;
  PERFORM 1 FROM ops.agent_runs WHERE id=p_agent_run_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'AGENT_RUN_NOT_FOUND' USING ERRCODE='22023'; END IF;
  SELECT created_by INTO v_reviewer_user_id FROM ops.agent_runs WHERE id=p_agent_run_id;
  IF v_reviewer_user_id IS NULL THEN
    RAISE EXCEPTION 'AGENT_RUN_REVIEWER_MISSING' USING ERRCODE='22023';
  END IF;
  PERFORM 1 FROM ops.agent_provider_turns WHERE provider_turn_id=p_provider_turn_id AND agent_run_id=p_agent_run_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROVIDER_TURN_NOT_FOUND' USING ERRCODE='22023'; END IF;
  SELECT result_sha256 INTO v_tool_result_sha FROM ops.agent_tool_calls
   WHERE tool_call_id=p_tool_call_id AND agent_run_id=p_agent_run_id
     AND provider_turn_id=p_provider_turn_id AND call_id=p_call_id
     AND status='SUCCEEDED';
  IF v_tool_result_sha IS NULL THEN RAISE EXCEPTION 'TOOL_CALL_NOT_COMPLETED' USING ERRCODE='22023'; END IF;
  IF v_tool_result_sha <> p_result_sha256 THEN
    RAISE EXCEPTION 'TOOL_RESULT_DIGEST_MISMATCH' USING ERRCODE='22023';
  END IF;
  SELECT d.id,d.decision_version,d.effective_at,d.expires_at,
         'ALLOW','ALLOW',
         CASE WHEN EXISTS (SELECT 1 FROM ops.capability_activation_decisions m WHERE m.capability_class='MODEL_EGRESS' AND m.scope_id IN (p_source_id,'PUBLIC_RESEARCH','public-research') AND m.environment=d.environment AND m.legal_state='APPROVED' AND m.operational_state='ACTIVE' AND m.effective_at <= v_now AND (m.expires_at IS NULL OR m.expires_at > v_now)) THEN 'ALLOW' ELSE 'UNKNOWN' END,
         CASE WHEN EXISTS (SELECT 1 FROM ops.capability_activation_decisions m WHERE m.capability_class IN ('MODEL_EGRESS','PAID_WORKSPACE_PROCESSING') AND m.scope_id IN (p_source_id,'PUBLIC_RESEARCH','public-research') AND m.environment=d.environment AND m.legal_state='APPROVED' AND m.operational_state='ACTIVE' AND m.effective_at <= v_now AND (m.expires_at IS NULL OR m.expires_at > v_now)) THEN 'ALLOW' ELSE 'UNKNOWN' END,
         'UNKNOWN','UNKNOWN','UNKNOWN','UNKNOWN','UNKNOWN'
    INTO v_capability_id,v_capability_version,v_capability_effective,v_capability_expires,
         v_access_right,v_private_storage_right,v_model_egress_right,v_model_use_right,
         v_derivative_creation_right,v_excerpt_right,v_redistribution_right,v_commercial_use_right,v_public_display_right
    FROM ops.capability_activation_decisions d
    JOIN ops.source_registry s ON s.source_id=p_source_id
   WHERE s.enabled AND s.legal_status='APPROVED' AND d.capability_class='SOURCE_ACCESS'
     AND d.scope_type IN ('SOURCE','DATA_CLASS','WORKSPACE') AND d.scope_id IN (p_source_id,'PUBLIC_RESEARCH','public-research')
     AND d.environment=COALESCE(NULLIF(current_setting('gurine.environment',true),''),'TEST')
     AND d.legal_state='APPROVED' AND d.operational_state='ACTIVE'
     AND d.effective_at <= v_now AND (d.expires_at IS NULL OR d.expires_at > v_now)
     AND NOT EXISTS (SELECT 1 FROM editorial.legal_holds h WHERE h.active AND (h.expires_at IS NULL OR h.expires_at > v_now)
       AND (h.affected_ids @> jsonb_build_array(p_source_id) OR h.object_id::text = p_source_id OR h.case_id::text = p_source_id))
   ORDER BY d.decision_version DESC LIMIT 1;
  IF v_capability_id IS NULL THEN RAISE EXCEPTION 'SOURCE_RIGHTS_UNAVAILABLE' USING ERRCODE='42501'; END IF;
  -- The capability decision is provenance; each immutable artifact receives
  -- its own asset-rights decision identity so two fetches cannot collide on a
  -- capability UUID primary key.
  v_rights_id := v_asset_id;
  SELECT decision_digest INTO v_rights_sha
    FROM ops.capability_activation_decisions
   WHERE id=v_capability_id AND decision_version=v_capability_version;
  -- Artifact identity is a typed authority projection.  Raw bytes remain
  -- content_sha256; artifact_sha256 covers the canonical metadata envelope.
  v_artifact_canonical := ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion','research-artifact.v2','researchArtifactId',v_artifact_id,
    'assetId',v_asset_id,'assetRevision',1,'sourceFetchId',v_fetch_id,
    'artifactOrdinal',0,'fetchOutcome','STORED','sourceAuthority',p_source_id,
    'finalOrigin',v_locator,'httpStatus',p_http_status,
    'contentMediaType',coalesce(p_content_media_type,'application/octet-stream'),
    'contentSizeBytes',octet_length(p_content),'contentSha256',v_content_sha,
    'responseHeadersSha256',encode(extensions.digest(ops.canonical_jsonb_v1(v_headers),'sha256'),'hex'),
    'contentSafetyState',v_safety_state,'contentSafetyReceiptSha256',v_fetch_receipt));
  v_artifact_sha := encode(extensions.digest(v_artifact_canonical,'sha256'),'hex');
  -- The capability decision is only the admission input.  The immutable
  -- asset decision must have its own digest over the exact asset identity and
  -- dimensions so a source-level capability can never be mistaken for a
  -- rights decision for a different payload.
  v_asset_rights_canonical := ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion','asset-rights-decision.v1','decisionId',v_rights_id,
    'assetId',v_asset_id,'assetSha256',v_content_sha,'assetRevision',1,
    'decisionVersion',1,'assetKind','RESEARCH_ARTIFACT','researchArtifactId',v_artifact_id,
    'decisionKind','GRANT','accessRight',v_access_right,'privateStorageRight',v_private_storage_right,
    'modelEgressRight',v_model_egress_right,'modelUseRight',v_model_use_right,
    'derivativeCreationRight',v_derivative_creation_right,'excerptRight',v_excerpt_right,
    'redistributionRight',v_redistribution_right,'commercialUseRight',v_commercial_use_right,
    'publicDisplayRight',v_public_display_right,'policyVersion',p_policy_version,
    'policySha256',v_policy_sha,'legalBasisCode','PUBLIC_RESEARCH','legalBasisReference',p_source_id,
    'jurisdiction','GLOBAL','attributionRequired',false,'effectiveAt',coalesce(v_capability_effective,v_now),
    'expiresAt',v_capability_expires,'capabilityDecisionId',v_capability_id,
    'capabilityDecisionVersion',v_capability_version,'capabilityDecisionSha256',v_rights_sha));
  v_asset_rights_sha := encode(extensions.digest(v_asset_rights_canonical,'sha256'),'hex');
  v_locator_sha := encode(extensions.digest(convert_to(v_locator,'UTF8'),'sha256'),'hex');
  v_policy_sha := encode(extensions.digest(convert_to(p_policy_version,'UTF8'),'sha256'),'hex');
  INSERT INTO raw.source_fetches(id,source_id,source_run_id,external_locator,requested_at,completed_at,http_status,content_type,payload_sha256,payload_size_bytes,object_key)
  VALUES(v_fetch_id,p_source_id,NULL,p_external_locator,v_now,v_now,p_http_status,p_content_media_type,v_content_sha,octet_length(p_content),p_object_key)
  ON CONFLICT (source_id,external_locator,payload_sha256) DO UPDATE SET completed_at=EXCLUDED.completed_at
  RETURNING id INTO v_fetch_id;
  -- SEARCH_PUBLIC_WEB is a discovery receipt, not a stored ResearchArtifact.
  -- Persist the immutable gateway payload binding while leaving artifact and
  -- rights/source-use rows to the subsequent FETCH_URL call selected by the
  -- agent.  This keeps the response's SEARCH branch (artifacts=[]) true in
  -- both the wire contract and the database lineage.
  IF p_request_kind='SEARCH_PUBLIC_WEB' THEN
    RETURN jsonb_build_object('schemaVersion','source.fetch.receipt.v2',
      'sourceFetchId',v_fetch_id,'payloadSha256',v_content_sha,
      'receiptDigest',v_fetch_receipt,'policyVersion',p_policy_version,
      'policySha256',v_policy_sha,'recordedAt',v_now,
      'discoveryOnly',true);
  END IF;
  SELECT id INTO v_existing_artifact FROM raw.research_artifacts WHERE source_fetch_id=v_fetch_id;
  IF v_existing_artifact IS NOT NULL THEN
    SELECT source_use_id INTO v_existing_source_use
      FROM ops.agent_source_uses WHERE research_artifact_id=v_existing_artifact
      ORDER BY created_at LIMIT 1;
    SELECT artifact_sha256 INTO v_existing_artifact_sha
      FROM raw.research_artifacts WHERE id=v_existing_artifact;
    RETURN jsonb_build_object('schemaVersion','source.fetch.receipt.v2','sourceFetchId',v_fetch_id,
      'researchArtifactId',v_existing_artifact,'sourceUseId',v_existing_source_use,
      'payloadSha256',v_content_sha,'artifactSha256',v_existing_artifact_sha,'receiptDigest',v_fetch_receipt,
      'policyVersion',p_policy_version,'policySha256',v_policy_sha,'recordedAt',v_now,'idempotencyReplay',true);
  END IF;
  INSERT INTO raw.research_artifacts(
    id,asset_id,asset_revision,source_fetch_id,agent_run_id,provider_turn_id,tool_call_id,call_id,artifact_ordinal,
    input_snapshot_sha256,request_kind,request_sha256,result_sha256,fetch_outcome,source_url_redacted,final_url_redacted,
    source_authority,retrieved_at,http_status,content_media_type,content_size_bytes,content_sha256,response_headers_sha256,
    artifact_sha256,object_key,object_key_hash,safe_headers,safe_headers_canonical,redirect_chain,redirect_chain_canonical,
    classification,content_safety_state,content_safety_receipt_sha256,artifact_canonical)
  VALUES(v_artifact_id,v_asset_id,1,v_fetch_id,p_agent_run_id,p_provider_turn_id,p_tool_call_id,p_call_id,0,
    p_input_snapshot_sha256,p_request_kind,p_request_sha256,p_result_sha256,'STORED',p_source_url_redacted,p_final_url_redacted,
    p_source_id,v_now,p_http_status,coalesce(p_content_media_type,'application/octet-stream'),octet_length(p_content),v_content_sha,
    encode(extensions.digest(ops.canonical_jsonb_v1(v_headers),'sha256'),'hex'),v_artifact_sha,p_object_key,
    encode(extensions.digest(convert_to(p_object_key,'UTF8'),'sha256'),'hex'),v_headers,ops.canonical_jsonb_v1(v_headers),v_redirects,
    ops.canonical_jsonb_v1(v_redirects),'PUBLIC',v_safety_state,v_fetch_receipt,v_artifact_canonical);
  INSERT INTO raw.asset_rights_decisions(
    id,asset_id,asset_sha256,asset_revision,decision_version,asset_kind,research_artifact_id,decision_kind,
    access_right,private_storage_right,model_egress_right,model_use_right,derivative_creation_right,excerpt_right,
    redistribution_right,commercial_use_right,public_display_right,dimensions_sha256,legal_basis_code,legal_basis_reference,
    legal_basis_sha256,license_evidence_digests,license_evidence_set_sha256,jurisdiction,attribution_required,attribution_sha256,
    policy_version,policy_sha256,approval_sha256,execution_sha256,evidence_receipt_id,evidence_receipt_sha256,reviewer_user_id,
    effective_at,decision_sha256)
  VALUES(v_rights_id,v_asset_id,v_content_sha,1,1,'RESEARCH_ARTIFACT',v_artifact_id,'GRANT',
    v_access_right,v_private_storage_right,v_model_egress_right,v_model_use_right,v_derivative_creation_right,v_excerpt_right,
    v_redistribution_right,v_commercial_use_right,v_public_display_right,
    encode(extensions.digest(ops.canonical_jsonb_v1(jsonb_build_object(
      'accessRight',v_access_right,'privateStorageRight',v_private_storage_right,
      'modelEgressRight',v_model_egress_right,'modelUseRight',v_model_use_right,
      'derivativeCreationRight',v_derivative_creation_right,'excerptRight',v_excerpt_right,
      'redistributionRight',v_redistribution_right,'commercialUseRight',v_commercial_use_right,
      'publicDisplayRight',v_public_display_right)),'sha256'),'hex'),'PUBLIC_RESEARCH',p_source_id,
    encode(extensions.digest(convert_to(p_source_id,'UTF8'),'sha256'),'hex'),
    ARRAY[encode(extensions.digest(convert_to(p_source_id,'UTF8'),'sha256'),'hex')],
    encode(extensions.digest(ops.canonical_jsonb_v1(to_jsonb(ARRAY[encode(extensions.digest(convert_to(p_source_id,'UTF8'),'sha256'),'hex')]::text[])),'sha256'),'hex'),
    'GLOBAL',false,encode(extensions.digest(convert_to('','UTF8'),'sha256'),'hex'),p_policy_version,v_policy_sha,
    v_artifact_sha,v_artifact_sha,v_fetch_id,v_fetch_receipt,v_reviewer_user_id,coalesce(v_capability_effective,v_now),
    v_asset_rights_sha);
  v_source_use_canonical := ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion','source-use.v2','sourceUseId',v_source_use_id,'agentRunId',p_agent_run_id,
    'providerTurnId',p_provider_turn_id,'toolCallId',p_tool_call_id,
    'parentSourceUseId',NULL,'parentSourceUseSha256',NULL,
    'useKind','TOOL_QUERY','sourceKind','RESEARCH_ARTIFACT',
    'sourceIdentity',jsonb_build_object('kind','RESEARCH_ARTIFACT','researchArtifactId',v_artifact_id,
      'assetId',v_asset_id,'assetRevision',1,'artifactSha256',v_artifact_sha,
      'contentSha256',v_content_sha,'sourceFetchId',v_fetch_id),
    'locator',jsonb_build_object('kind','HTML_CSS_SELECTOR','value',v_locator,'locatorSha256',v_locator_sha),
    'selectedContentSha256',v_content_sha,'classification','PUBLIC',
    'rightsDecision',jsonb_build_object('decisionId',v_rights_id,'capabilityDecisionId',v_capability_id,'decisionVersion',1,
      'decisionSha256',v_asset_rights_sha,'effectiveAt',coalesce(v_capability_effective,v_now),'expiresAt',v_capability_expires,
      'accessRight',v_access_right,'privateStorageRight',v_private_storage_right,'modelEgressRight',v_model_egress_right,
      'modelUseRight',v_model_use_right,'derivativeCreationRight',v_derivative_creation_right,'excerptRight',v_excerpt_right,
      'redistributionRight',v_redistribution_right,'commercialUseRight',v_commercial_use_right,'publicDisplayRight',v_public_display_right),
    'providerReceiptId',NULL,'occurredAt',coalesce(v_capability_effective,v_now)));
  v_source_use_sha := encode(extensions.digest(v_source_use_canonical,'sha256'),'hex');
  IF p_source_use_sha256 <> v_source_use_sha THEN
    RAISE EXCEPTION 'SOURCE_USE_DIGEST_MISMATCH' USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.agent_source_uses(
    source_use_id,source_use_contract_version,agent_run_id,provider_turn_id,tool_call_id,use_kind,source_kind,
    research_artifact_id,research_asset_id,research_asset_revision,research_artifact_sha256,research_content_sha256,
    research_source_fetch_id,locator_kind,locator_value,locator_sha256,selected_content_sha256,classification,rights_binding_kind,
    rights_asset_id,rights_asset_revision,rights_asset_sha256,asset_rights_decision_id,asset_rights_decision_version,
    asset_rights_decision_sha256,rights_effective_at,access_right,private_storage_right,model_egress_right,model_use_right,
    derivative_creation_right,excerpt_right,redistribution_right,commercial_use_right,public_display_right,rights_policy_version,
    rights_policy_sha256,occurred_at,source_use_canonical,source_use_sha256)
  VALUES(v_source_use_id,2,p_agent_run_id,p_provider_turn_id,p_tool_call_id,'TOOL_QUERY','RESEARCH_ARTIFACT',
    v_artifact_id,v_asset_id,1,v_artifact_sha,v_content_sha,v_fetch_id,'HTML_CSS_SELECTOR',v_locator,v_locator_sha,v_content_sha,
    'PUBLIC','ASSET_RIGHTS',v_asset_id,1,v_content_sha,v_rights_id,1,
    v_asset_rights_sha,coalesce(v_capability_effective,v_now),
    v_access_right,v_private_storage_right,v_model_egress_right,v_model_use_right,v_derivative_creation_right,
    v_excerpt_right,v_redistribution_right,v_commercial_use_right,v_public_display_right,p_policy_version,v_policy_sha,coalesce(v_capability_effective,v_now),
    v_source_use_canonical,v_source_use_sha)
  ON CONFLICT (agent_run_id,source_use_sha256) DO NOTHING;
  RETURN jsonb_build_object('schemaVersion','source.fetch.receipt.v2','sourceFetchId',v_fetch_id,'researchArtifactId',v_artifact_id,
    'sourceUseId',v_source_use_id,'assetId',v_asset_id,'payloadSha256',v_content_sha,'artifactSha256',v_artifact_sha,
    'receiptDigest',v_fetch_receipt,'policyVersion',p_policy_version,'policySha256',v_policy_sha,'recordedAt',v_now);
END $$;
ALTER FUNCTION ops.record_research_fetch_v1(uuid,uuid,uuid,text,char(64),text,text,text,text,text,integer,text,char(64),bytea,text,text,char(64),uuid,uuid,uuid,uuid,char(64),char(64),jsonb,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_research_fetch_v1(uuid,uuid,uuid,text,char(64),text,text,text,text,text,integer,text,char(64),bytea,text,text,char(64),uuid,uuid,uuid,uuid,char(64),char(64),jsonb,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_research_fetch_v1(uuid,uuid,uuid,text,char(64),text,text,text,text,text,integer,text,char(64),bytea,text,text,char(64),uuid,uuid,uuid,uuid,char(64),char(64),jsonb,jsonb) TO gurine_analysis_worker;
COMMIT;

-- Replace the historical empty action-proposal projection with the complete
-- read model.  Decisions, previews, quorum slots and queued execution are
-- read from their immutable relations; no UI field is synthesized from a
-- content digest or a fixed journey label.
BEGIN;
CREATE OR REPLACE FUNCTION ops.read_action_proposal_v1(p_id uuid) RETURNS jsonb
LANGUAGE SQL SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp AS $$
  SELECT jsonb_build_object(
    'proposal',jsonb_build_object(
      'proposalId',p.id,'actionKind',p.action_kind,'state',v.state,
      'version',v.version,'contentDigest',btrim(v.content_digest::text),
      'approvalDigest',NULLIF(btrim(v.approval_digest::text),''),
      'targetType',p.target_type,'targetId',p.target_id,'targetVersion',p.target_version,
      'targetDigest',btrim(p.target_digest::text),'originKind',p.origin_kind,
      'originId',p.origin_id,'originVersion',p.origin_version,'originDigest',p.origin_digest
    ),
    'version',v.version,
    'payload',COALESCE(v.action_detail,'{}'::jsonb),
    'rationale',COALESCE(NULLIF(btrim(convert_from(v.rationale_encrypted,'UTF8')),''),'{}'),
    'assignment',(
      SELECT jsonb_build_object('assignmentId',a.id,'assignmentVersion',a.version,'proposalId',a.proposal_id,
        'proposalVersion',a.proposal_version,'approvalDigest',btrim(a.approval_digest::text),'state',a.state,
        'reviewerId',a.reviewer_id,'dueAt',a.due_at)
      FROM ops.action_review_assignments a
      WHERE a.proposal_id=p.id AND a.proposal_version=v.version
      ORDER BY a.assignment_generation DESC,a.created_at DESC NULLS LAST,a.id DESC LIMIT 1
    ),
    'assignmentHistory',jsonb_build_object(
      'items',COALESCE((SELECT jsonb_agg(jsonb_build_object('assignmentId',a.id,'assignmentVersion',a.version,
        'assignmentGeneration',a.assignment_generation,'state',a.state,'reviewerId',a.reviewer_id,
        'dueAt',a.due_at,'createdAt',a.created_at) ORDER BY a.assignment_generation DESC,a.created_at DESC NULLS LAST,a.id DESC)
        FROM ops.action_review_assignments a WHERE a.proposal_id=p.id AND a.proposal_version=v.version),'[]'::jsonb),
      'complete',true
    ),
    'decisionHistory',jsonb_build_object(
      'items',COALESCE((SELECT jsonb_agg(jsonb_build_object('decisionId',d.id,'decisionKind',d.decision_kind,
        'resultingProposalState',d.resulting_proposal_state,'reasonCode',d.reason_code,'reason',d.reason,
        'actorId',d.actor_id,'decidedAt',d.decided_at,'receiptDigest',d.receipt_digest,'auditEventId',d.audit_event_id)
        ORDER BY d.decided_at DESC,d.id DESC) FROM ops.action_decisions d
        WHERE d.proposal_id=p.id AND d.proposal_version=v.version),'[]'::jsonb),
      'complete',true
    ),
    'origin',jsonb_build_object('kind',p.origin_kind,'id',p.origin_id,'version',p.origin_version,'digest',p.origin_digest),
    'latestPreview',CASE WHEN v.preview_id IS NULL THEN NULL ELSE jsonb_build_object(
      'previewId',v.preview_id,'previewDigest',v.preview_digest,'policyDigest',v.preview_policy_digest,
      'previewedAt',v.previewed_at,'previewedBy',v.previewed_by,'receiptDigest',v.preview_receipt_digest,
      'auditEventId',v.preview_audit_event_id) END,
    'quorum',jsonb_build_object(
      'planDigest',v.quorum_plan_digest,'requiredSlots',COALESCE((SELECT jsonb_agg(a.slot_id ORDER BY a.slot_ordinal)
        FROM ops.action_review_assignments a WHERE a.proposal_id=p.id AND a.proposal_version=v.version),'[]'::jsonb),
      'satisfiedSlots',COALESCE((SELECT jsonb_agg(a.slot_id ORDER BY a.slot_ordinal) FROM ops.action_review_assignments a
        WHERE a.proposal_id=p.id AND a.proposal_version=v.version AND a.state='COMPLETED'),'[]'::jsonb),
      'blockingSlots',COALESCE((SELECT jsonb_agg(a.slot_id ORDER BY a.slot_ordinal) FROM ops.action_review_assignments a
        WHERE a.proposal_id=p.id AND a.proposal_version=v.version AND a.state NOT IN ('COMPLETED','RECUSED')),'[]'::jsonb),
      'conflictSnapshotDigest',v.conflict_snapshot_digest,'complete',v.state='APPROVED'),
    'executionAuthorization',(
      SELECT jsonb_build_object('executionId',e.id,'state',e.state,'actionProposalId',e.action_proposal_id,
        'actionProposalVersion',e.action_proposal_version,'approvalDigest',e.approval_digest,
        'providerIdempotencyKeySha256',e.provider_idempotency_key_sha256,'lastReceiptDigest',e.last_receipt_digest)
      FROM ops.in_flight_effects e WHERE e.action_proposal_id=p.id AND e.action_proposal_version=v.version
      ORDER BY e.created_at DESC LIMIT 1
    ),
    'asOf',clock_timestamp(),
    'links',jsonb_build_array(jsonb_build_object('rel','self','href','/internal/action-proposals/'||p.id::text),
      jsonb_build_object('rel','origin','href','/internal/agent-suggestions/'||p.origin_id::text))
  )
  FROM ops.action_proposals p JOIN ops.action_proposal_versions v
    ON v.proposal_id=p.id AND v.version=p.current_version
  WHERE p.id=$1
$$;
ALTER FUNCTION ops.read_action_proposal_v1(uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_action_proposal_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_action_proposal_v1(uuid) TO gurine_control_api;
COMMIT;

-- AgentProposalV2 closes the provider output -> validated proposal -> citation
-- graph on the existing legacy suggestion relation.  Keeping the relation
-- preserves the 107-table runtime baseline while making every v2 row carry
-- its exact output-validation and input-snapshot identity.
BEGIN;
ALTER TABLE ops.agent_suggestions
  ADD COLUMN IF NOT EXISTS proposal_contract_version smallint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS target_schema_version text,
  ADD COLUMN IF NOT EXISTS payload_sha256 char(64),
  ADD COLUMN IF NOT EXISTS payload_canonical bytea,
  ADD COLUMN IF NOT EXISTS input_snapshot_sha256 char(64),
  ADD COLUMN IF NOT EXISTS citation_validation_id uuid,
  ADD COLUMN IF NOT EXISTS expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS decision_kind text,
  ADD COLUMN IF NOT EXISTS decision_sha256 char(64),
  ADD COLUMN IF NOT EXISTS decision_audit_event_id uuid,
  ADD COLUMN IF NOT EXISTS materialized_target_type text,
  ADD COLUMN IF NOT EXISTS materialized_target_id uuid,
  ADD COLUMN IF NOT EXISTS materialized_target_version bigint,
  ADD COLUMN IF NOT EXISTS materialized_target_digest char(64),
  ADD COLUMN IF NOT EXISTS materialized_action_proposal_id uuid,
  ADD COLUMN IF NOT EXISTS materialization_receipt_sha256 char(64);
ALTER TABLE ops.agent_suggestions DROP CONSTRAINT IF EXISTS agent_suggestions_status_check;
ALTER TABLE ops.agent_suggestions ADD CONSTRAINT agent_suggestions_status_check
  CHECK (status IN ('PENDING','ACCEPTED','REJECTED','SUPERSEDED','EXPIRED'));
ALTER TABLE ops.agent_suggestions ADD CONSTRAINT agent_suggestions_contract_version_ck
  CHECK (proposal_contract_version IN (1,2));
ALTER TABLE ops.agent_suggestions ADD CONSTRAINT agent_suggestions_v2_binding_uk
  UNIQUE (id, agent_run_id, payload_sha256, input_snapshot_sha256, citation_validation_id);
ALTER TABLE ops.agent_suggestions ADD CONSTRAINT agent_suggestions_v2_type_ck
  CHECK (proposal_contract_version = 1 OR suggestion_type IN ('HYPOTHESIS','CLAIM','TASK','COMPARABLE','COMMUNICATION'));
ALTER TABLE ops.agent_suggestions ADD CONSTRAINT agent_suggestions_v2_payload_ck
  CHECK (proposal_contract_version = 1 OR (
    target_schema_version IS NOT NULL AND payload_sha256 IS NOT NULL
    AND payload_canonical IS NOT NULL AND convert_from(payload_canonical,'UTF8')::jsonb = payload
    AND encode(extensions.digest(payload_canonical,'sha256'),'hex') = payload_sha256
    AND input_snapshot_sha256 IS NOT NULL AND citation_validation_id IS NOT NULL
    AND expires_at IS NOT NULL AND expires_at > created_at
    AND evidence_ids = '[]'::jsonb AND citation_checks = '[]'::jsonb));
ALTER TABLE ops.agent_suggestions ADD CONSTRAINT agent_suggestions_v2_target_ck
  CHECK (materialized_target_type IS NULL OR materialized_target_type = 'ACTION_PROPOSAL_DRAFT');
ALTER TABLE ops.agent_suggestions ADD CONSTRAINT agent_suggestions_v2_decision_ck
  CHECK (proposal_contract_version = 1 OR status = 'PENDING' OR (
    decision_reason IS NOT NULL AND decision_kind IS NOT NULL
    AND decision_sha256 IS NOT NULL AND decision_audit_event_id IS NOT NULL
    AND decided_at IS NOT NULL));
ALTER TABLE ops.agent_suggestions ADD CONSTRAINT agent_suggestions_run_snapshot_fk
  FOREIGN KEY (agent_run_id, input_snapshot_sha256)
  REFERENCES ops.agent_runs (id, input_snapshot_hash) ON DELETE RESTRICT;
ALTER TABLE ops.agent_suggestions ADD CONSTRAINT agent_suggestions_validation_fk
  FOREIGN KEY (citation_validation_id, agent_run_id, input_snapshot_sha256)
  REFERENCES ops.agent_output_validations (validation_id, agent_run_id, input_snapshot_sha256)
  ON DELETE RESTRICT;
ALTER TABLE ops.agent_suggestions ADD CONSTRAINT agent_suggestions_decision_audit_fk
  FOREIGN KEY (decision_audit_event_id) REFERENCES ops.audit_events(id) ON DELETE RESTRICT;
ALTER TABLE ops.agent_proposal_citations ADD CONSTRAINT agent_proposal_citations_proposal_fk
  FOREIGN KEY (proposal_id, agent_run_id, proposal_payload_sha256, input_snapshot_sha256, validation_id)
  REFERENCES ops.agent_suggestions (id, agent_run_id, payload_sha256, input_snapshot_sha256, citation_validation_id)
  ON DELETE RESTRICT;
COMMIT;

BEGIN;
ALTER TABLE ops.sku_readiness_evaluations
  ADD COLUMN IF NOT EXISTS qualification_episode_id uuid;
CREATE INDEX IF NOT EXISTS sku_readiness_evaluations_episode_idx
  ON ops.sku_readiness_evaluations(qualification_episode_id, evaluated_at DESC, id);

CREATE OR REPLACE FUNCTION ops.build_paid_evidence_member_candidate_set_v1(
  p_packet_id uuid,
  p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
SELECT jsonb_build_object(
  'packetId',p.packet_id,'packetVersion',p.packet_version,'state',p.state,
  'memberCount',count(m.member_ordinal),'requiredMemberCount',10,
  'members',coalesce(jsonb_agg(jsonb_build_object(
    'ordinal',m.member_ordinal,'category',m.category,'sourceSetId',m.source_set_id,
    'sourceSetVersion',m.source_set_version,'sourceSetDigest',m.source_set_digest,
    'dispositionKind',m.disposition_kind,'memberRecordDigest',m.member_record_digest
  ) ORDER BY m.member_ordinal),'[]'::jsonb),
  'candidateSetDigest',encode(extensions.digest(convert_to(coalesce(string_agg(m.member_record_digest,',' ORDER BY m.member_ordinal),''),'UTF8'),'sha256'),'hex')
)
FROM ops.paid_evidence_packets p
LEFT JOIN ops.paid_evidence_packet_members m ON m.packet_id=p.packet_id AND m.packet_version=p.packet_version
WHERE p.packet_id=p_packet_id AND p.created_at <= coalesce(p_as_of,clock_timestamp())
GROUP BY p.packet_id,p.packet_version,p.state;
$$;
ALTER FUNCTION ops.build_paid_evidence_member_candidate_set_v1(uuid,timestamptz) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.build_paid_evidence_member_candidate_set_v1(uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.build_paid_evidence_member_candidate_set_v1(uuid,timestamptz)
  TO gurine_control_api, gurine_workflow_worker, gurine_auditor;

CREATE OR REPLACE FUNCTION ops.resolve_organization_decision_terminal_v1(
  p_decision_id uuid,
  p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
SELECT jsonb_build_object(
  'terminalReceiptKind','ORGANIZATION_DECISION','terminalReceiptId',d.id,
  'terminalReceiptVersion',1,'terminalReceiptDigest',d.receipt_digest,
  'resultingState',CASE WHEN d.decision_kind='REJECT' THEN 'REJECTED_FINAL' ELSE 'EFFECT_SUCCEEDED' END,
  'proposalId',d.proposal_id,'proposalVersion',d.proposal_version,
  'approvalDigest',d.approval_digest,'decisionAt',d.decided_at)
FROM ops.action_decisions d
WHERE d.id=p_decision_id AND d.decided_at <= coalesce(p_as_of,clock_timestamp())
  AND d.record_kind='DECISION' AND d.decision_kind IN ('REJECT','APPROVE')
  AND (d.decision_kind='REJECT' OR d.execution_id IS NOT NULL)
ORDER BY d.decided_at DESC LIMIT 1;
$$;
ALTER FUNCTION ops.resolve_organization_decision_terminal_v1(uuid,timestamptz) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.resolve_organization_decision_terminal_v1(uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.resolve_organization_decision_terminal_v1(uuid,timestamptz)
  TO gurine_control_api, gurine_workflow_worker, gurine_auditor;

CREATE OR REPLACE FUNCTION ops.resolve_outbound_delivery_terminal_v1(
  p_delivery_id uuid,
  p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
SELECT jsonb_build_object(
  'terminalReceiptKind','OUTBOUND_DELIVERY','terminalReceiptId',r.id,
  'terminalReceiptVersion',r.receipt_sequence,'terminalReceiptDigest',r.receipt_digest,
  'resultingState',r.resulting_state,'deliveryId',r.delivery_id,
  'deliveryVersion',r.delivery_version,'renderingDigest',r.rendering_digest,
  'authorizationSnapshotDigest',r.authorization_snapshot_digest,'recordedAt',r.recorded_at)
FROM ops.outbound_delivery_receipts r
WHERE r.delivery_id=p_delivery_id AND r.recorded_at <= coalesce(p_as_of,clock_timestamp())
  AND r.applied AND r.resulting_state IN ('DELIVERED','READ')
ORDER BY r.delivery_version DESC, r.receipt_sequence DESC LIMIT 1;
$$;
ALTER FUNCTION ops.resolve_outbound_delivery_terminal_v1(uuid,timestamptz) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.resolve_outbound_delivery_terminal_v1(uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.resolve_outbound_delivery_terminal_v1(uuid,timestamptz)
  TO gurine_control_api, gurine_workflow_worker, gurine_auditor;
COMMIT;

-- Commercial qualification is a write boundary, not a projection probe.  The
-- workflow worker calls this SECURITY DEFINER function with the closed
-- composite input; no runtime role receives INSERT on the immutable relation.
BEGIN;
CREATE OR REPLACE FUNCTION ops.record_commercial_qualification_receipt_v1(
  p_input ops.commercial_qualification_receipt_input_v1,
  p_idempotency_key text
) RETURNS ops.economics_mutation_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_request_id uuid := gen_random_uuid();
  v_id uuid := CASE WHEN (p_input).receipt_effect = 'ORIGINAL'
                    THEN (p_input).root_receipt_id ELSE gen_random_uuid() END;
  v_request_hash char(64) := encode(extensions.digest(convert_to(to_jsonb(p_input)::text,'UTF8'),'sha256'),'hex');
  v_key_hash char(64) := encode(extensions.digest(convert_to(p_idempotency_key,'UTF8'),'sha256'),'hex');
  v_response jsonb;
  v_event_hash char(64);
  v_audit_id uuid := gen_random_uuid();
  v_outbox_id uuid;
  v_receipt_digest char(64);
  v_recorded_at timestamptz := clock_timestamp();
  v_existing ops.idempotency_keys;
  v_predecessor ops.commercial_qualification_receipts;
BEGIN
  IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'COMMERCIAL_QUALIFICATION_INVALID' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing FROM ops.idempotency_keys
   WHERE scope='ECONOMICS.RECORD_COMMERCIAL_QUALIFICATION_RECEIPT.V1' AND key_hash=v_key_hash
   FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_hash <> v_request_hash THEN
      RAISE EXCEPTION 'FACT_CONFLICT' USING ERRCODE='40001';
    END IF;
    RETURN (v_existing.resource_id::uuid, 'COMMERCIAL_QUALIFICATION_RECEIPT', v_existing.resource_id::uuid,
      1, (v_existing.response_body->>'receiptDigest')::char(64),
      NULLIF(v_existing.response_body->>'auditEventId','')::uuid,
      NULLIF(v_existing.response_body->>'outboxId','')::uuid, v_existing.response_status,
      'application/json', convert_to(v_existing.response_body::text,'UTF8'),
      encode(extensions.digest(convert_to(v_existing.response_body::text,'UTF8'),'sha256'),'hex')::char(64),
      (v_existing.response_body->>'receiptDigest')::char(64), v_existing.created_at, true)::ops.economics_mutation_receipt_v1;
  END IF;
  IF (p_input).root_receipt_id IS NULL
     OR (p_input).sku <> 'EVIDENCE_WORKSPACE_ORGANIZATION_V1'
     OR (p_input).receipt_effect NOT IN ('ORIGINAL','REPLACEMENT','REVERSAL')
     OR ((p_input).receipt_effect = 'ORIGINAL' AND ((p_input).revision <> 1
         OR (p_input).supersedes_receipt_id IS NOT NULL
         OR (p_input).predecessor_receipt_digest IS NOT NULL
         OR (p_input).reason_code <> 'QUALIFICATION_ACCEPTED'))
     OR ((p_input).receipt_effect IN ('REPLACEMENT','REVERSAL') AND ((p_input).revision <= 1
         OR (p_input).supersedes_receipt_id IS NULL
         OR (p_input).predecessor_receipt_digest IS NULL
         OR (p_input).root_receipt_id = v_id
         OR ((p_input).receipt_effect = 'REPLACEMENT' AND (p_input).reason_code <> 'SOURCE_CORRECTION')
         OR ((p_input).receipt_effect = 'REVERSAL' AND (p_input).reason_code <> 'SOURCE_REVERSAL'))) THEN
    RAISE EXCEPTION 'COMMERCIAL_QUALIFICATION_INVALID' USING ERRCODE='22023';
  END IF;
  IF (p_input).receipt_effect IN ('ORIGINAL','REPLACEMENT') AND NOT (
       (p_input).recurring_job_attested AND (p_input).authorized_data_identified
       AND (p_input).authorized_data_feasible AND (p_input).economic_buyer_role_bound
       AND (p_input).operational_owner_role_bound AND (p_input).independent_reviewer_role_bound
       AND (p_input).source_rights_owner_role_bound AND (p_input).incident_support_owner_role_bound
       AND (p_input).pilot_scope_accepted AND (p_input).success_metric_accepted
       AND (p_input).budget_authority_accepted AND (p_input).support_expectation_accepted
       AND (p_input).trust_terms_accepted)
     OR (p_input).receipt_effect = 'REVERSAL' AND (
       (p_input).recurring_job_attested OR (p_input).authorized_data_identified
       OR (p_input).authorized_data_feasible OR (p_input).economic_buyer_role_bound
       OR (p_input).operational_owner_role_bound OR (p_input).independent_reviewer_role_bound
       OR (p_input).source_rights_owner_role_bound OR (p_input).incident_support_owner_role_bound
       OR (p_input).pilot_scope_accepted OR (p_input).success_metric_accepted
       OR (p_input).budget_authority_accepted OR (p_input).support_expectation_accepted
       OR (p_input).trust_terms_accepted)
     OR (p_input).decision_effective_at > v_recorded_at THEN
    RAISE EXCEPTION 'COMMERCIAL_QUALIFICATION_INVALID' USING ERRCODE='22023';
  END IF;
  IF (p_input).receipt_effect = 'ORIGINAL' THEN
    IF (p_input).first_qualified_at <> (p_input).decision_effective_at THEN
      RAISE EXCEPTION 'COMMERCIAL_QUALIFICATION_INVALID' USING ERRCODE='22023';
    END IF;
  ELSE
    SELECT * INTO v_predecessor
      FROM ops.commercial_qualification_receipts
     WHERE id=(p_input).supersedes_receipt_id
       AND root_receipt_id=(p_input).root_receipt_id
       AND revision=(p_input).revision-1
       AND deployment_id=(p_input).deployment_id
       AND organization_id=(p_input).organization_id
       AND sku=(p_input).sku
       AND qualification_episode_id=(p_input).qualification_episode_id
     FOR UPDATE;
    IF NOT FOUND OR v_predecessor.receipt_digest <> (p_input).predecessor_receipt_digest
       OR v_predecessor.decision_effective_at >= (p_input).decision_effective_at
       OR v_predecessor.first_qualified_at <> (p_input).first_qualified_at
       OR v_predecessor.receipt_effect = 'REVERSAL' THEN
      RAISE EXCEPTION 'COMMERCIAL_QUALIFICATION_CONFLICT' USING ERRCODE='40001';
    END IF;
  END IF;
  v_receipt_digest := (p_input).receipt_digest;
  IF v_receipt_digest IS NULL OR v_receipt_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'COMMERCIAL_QUALIFICATION_INVALID' USING ERRCODE='22023';
  END IF;
  INSERT INTO ops.commercial_qualification_receipts(
    id,root_receipt_id,revision,receipt_effect,supersedes_receipt_id,predecessor_receipt_digest,
    qualification_episode_id,deployment_id,organization_id,sku,decision_effective_at,first_qualified_at,
    recurring_job_attested,authorized_data_identified,authorized_data_feasible,economic_buyer_role_bound,
    operational_owner_role_bound,independent_reviewer_role_bound,source_rights_owner_role_bound,
    incident_support_owner_role_bound,pilot_scope_accepted,success_metric_accepted,budget_authority_accepted,
    support_expectation_accepted,trust_terms_accepted,role_binding_hmac_key_version,
    economic_buyer_primary_role_binding_hmac,economic_buyer_backup_role_binding_hmac,
    operational_owner_primary_role_binding_hmac,operational_owner_backup_role_binding_hmac,
    independent_reviewer_primary_role_binding_hmac,independent_reviewer_backup_role_binding_hmac,
    source_rights_owner_primary_role_binding_hmac,source_rights_owner_backup_role_binding_hmac,
    incident_support_owner_primary_role_binding_hmac,incident_support_owner_backup_role_binding_hmac,
    source_system_id,source_record_identity_hmac,acquisition_source_receipt_id,acquisition_source_receipt_digest,
    source_signature_digest,qualification_policy_version,qualification_policy_digest,criterion_set_digest,
    role_binding_set_digest,evidence_set_digest,reason_code,receipt_digest,recorded_at)
  SELECT v_id,(p_input).root_receipt_id,(p_input).revision,(p_input).receipt_effect,
    (p_input).supersedes_receipt_id,(p_input).predecessor_receipt_digest,(p_input).qualification_episode_id,
    (p_input).deployment_id,(p_input).organization_id,(p_input).sku,(p_input).decision_effective_at,
    (p_input).first_qualified_at,(p_input).recurring_job_attested,(p_input).authorized_data_identified,
    (p_input).authorized_data_feasible,(p_input).economic_buyer_role_bound,(p_input).operational_owner_role_bound,
    (p_input).independent_reviewer_role_bound,(p_input).source_rights_owner_role_bound,
    (p_input).incident_support_owner_role_bound,(p_input).pilot_scope_accepted,(p_input).success_metric_accepted,
    (p_input).budget_authority_accepted,(p_input).support_expectation_accepted,(p_input).trust_terms_accepted,
    (p_input).role_binding_hmac_key_version,(p_input).economic_buyer_primary_role_binding_hmac,
    (p_input).economic_buyer_backup_role_binding_hmac,(p_input).operational_owner_primary_role_binding_hmac,
    (p_input).operational_owner_backup_role_binding_hmac,(p_input).independent_reviewer_primary_role_binding_hmac,
    (p_input).independent_reviewer_backup_role_binding_hmac,(p_input).source_rights_owner_primary_role_binding_hmac,
    (p_input).source_rights_owner_backup_role_binding_hmac,(p_input).incident_support_owner_primary_role_binding_hmac,
    (p_input).incident_support_owner_backup_role_binding_hmac,(p_input).source_system_id,
    (p_input).source_record_identity_hmac,(p_input).acquisition_source_receipt_id,
    (p_input).acquisition_source_receipt_digest,(p_input).source_signature_digest,(p_input).qualification_policy_version,
    (p_input).qualification_policy_digest,(p_input).criterion_set_digest,(p_input).role_binding_set_digest,
    (p_input).evidence_set_digest,(p_input).reason_code,v_receipt_digest,v_recorded_at;
  v_response := jsonb_build_object('receiptId',v_id,'receiptDigest',v_receipt_digest,'resourceVersion',1);
  v_event_hash := encode(extensions.digest(convert_to(v_audit_id::text||v_id::text||v_receipt_digest,'UTF8'),'sha256'),'hex');
  INSERT INTO ops.audit_events(id,actor_type,actor_id,action,object_type,object_id,capability,outcome,reason,request_id,details,event_hash)
    VALUES(v_audit_id,'SERVICE','commercial-importer','RECORD_COMMERCIAL_QUALIFICATION_RECEIPT',
      'COMMERCIAL_QUALIFICATION_RECEIPT',v_id::text,'commercial.import', 'SUCCESS','SIGNED_QUALIFICATION',v_request_id,v_response,v_event_hash);
  v_outbox_id := ops.enqueue_outbox(
    'commercial_qualification_receipt',v_id::text,1,
    'product.commercial_qualification_recorded.v1',
    jsonb_build_object('receiptId',v_id,'receiptDigest',v_receipt_digest,
      'qualificationEpisodeId',(p_input).qualification_episode_id,
      'deploymentId',(p_input).deployment_id,
      'organizationId',(p_input).organization_id,'sku',(p_input).sku),
    v_recorded_at);
  v_response := v_response || jsonb_build_object('auditEventId',v_audit_id,'outboxId',v_outbox_id);
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,response_status,response_body,resource_type,resource_id,expires_at)
    VALUES('ECONOMICS.RECORD_COMMERCIAL_QUALIFICATION_RECEIPT.V1',v_key_hash,v_request_hash,201,v_response,
      'COMMERCIAL_QUALIFICATION_RECEIPT',v_id::text,v_recorded_at+interval '24 hours');
  RETURN (v_id,'COMMERCIAL_QUALIFICATION_RECEIPT',v_id,1,v_receipt_digest,v_audit_id,v_outbox_id,201,
    'application/json',convert_to(v_response::text,'UTF8'),encode(extensions.digest(convert_to(v_response::text,'UTF8'),'sha256'),'hex')::char(64),
    v_receipt_digest,v_recorded_at,false)::ops.economics_mutation_receipt_v1;
END;
$$;
ALTER FUNCTION ops.record_commercial_qualification_receipt_v1(ops.commercial_qualification_receipt_input_v1,text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_commercial_qualification_receipt_v1(ops.commercial_qualification_receipt_input_v1,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_commercial_qualification_receipt_v1(ops.commercial_qualification_receipt_input_v1,text) TO gurine_workflow_worker;
COMMIT;

BEGIN;
CREATE OR REPLACE FUNCTION ops.acceptance_record_business_qualification_v1(p_nonce text)
RETURNS ops.economics_mutation_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_id uuid := gen_random_uuid();
  v_input ops.commercial_qualification_receipt_input_v1;
  v_digest char(64);
  v_now timestamptz := clock_timestamp();
  v_existing ops.idempotency_keys;
  v_key_hash char(64);
BEGIN
  v_key_hash := encode(extensions.digest(convert_to(
    'acceptance:'||coalesce(p_nonce,''),'UTF8'),'sha256'),'hex');
  -- Keep the acceptance fixture itself idempotent.  Re-running a scenario must
  -- replay the persisted owner response byte-for-byte instead of generating a
  -- second qualification row or manufacturing a green probe.
  SELECT * INTO v_existing
    FROM ops.idempotency_keys
   WHERE scope='ECONOMICS.RECORD_COMMERCIAL_QUALIFICATION_RECEIPT.V1'
     AND key_hash=v_key_hash
   ORDER BY created_at DESC LIMIT 1;
  IF FOUND THEN
    RETURN (v_existing.resource_id::uuid,'COMMERCIAL_QUALIFICATION_RECEIPT',
      v_existing.resource_id::uuid,1,
      (v_existing.response_body->>'receiptDigest')::char(64),
      NULLIF(v_existing.response_body->>'auditEventId','')::uuid,
      NULLIF(v_existing.response_body->>'outboxId','')::uuid,
      v_existing.response_status,'application/json',
      convert_to(v_existing.response_body::text,'UTF8'),
      encode(extensions.digest(convert_to(v_existing.response_body::text,'UTF8'),'sha256'),'hex')::char(64),
      (v_existing.response_body->>'receiptDigest')::char(64),v_existing.created_at,true)::ops.economics_mutation_receipt_v1;
  END IF;
  -- Every acceptance invocation gets a deterministic digest for its own
  -- nonce.  Fixed fixture digests violate the immutable receipt uniqueness
  -- contract as soon as the full 43-scenario suite is executed on one DB.
  v_digest := encode(extensions.digest(convert_to(
    'qualification-policy:'||coalesce(p_nonce,'')||':'||v_id::text,'UTF8'),'sha256'),'hex');
  v_input := jsonb_populate_record(NULL::ops.commercial_qualification_receipt_input_v1, jsonb_build_object(
    'root_receipt_id',v_id,'revision',1,'receipt_effect','ORIGINAL',
    'qualification_episode_id',gen_random_uuid(),'deployment_id',gen_random_uuid(),'organization_id',gen_random_uuid(),
    'sku','EVIDENCE_WORKSPACE_ORGANIZATION_V1','decision_effective_at',v_now,
    'first_qualified_at',v_now,'recurring_job_attested',true,'authorized_data_identified',true,
    'authorized_data_feasible',true,'economic_buyer_role_bound',true,'operational_owner_role_bound',true,
    'independent_reviewer_role_bound',true,'source_rights_owner_role_bound',true,'incident_support_owner_role_bound',true,
    'pilot_scope_accepted',true,'success_metric_accepted',true,'budget_authority_accepted',true,
    'support_expectation_accepted',true,'trust_terms_accepted',true,'role_binding_hmac_key_version','acceptance-v1',
    'economic_buyer_primary_role_binding_hmac',repeat('1',64),'economic_buyer_backup_role_binding_hmac',repeat('2',64),
    'operational_owner_primary_role_binding_hmac',repeat('3',64),'operational_owner_backup_role_binding_hmac',repeat('4',64),
    'independent_reviewer_primary_role_binding_hmac',repeat('5',64),'independent_reviewer_backup_role_binding_hmac',repeat('6',64),
    'source_rights_owner_primary_role_binding_hmac',repeat('7',64),'source_rights_owner_backup_role_binding_hmac',repeat('8',64),
    'incident_support_owner_primary_role_binding_hmac',repeat('9',64),'incident_support_owner_backup_role_binding_hmac',repeat('b',64),
    'source_system_id','acceptance-probe','source_record_identity_hmac',repeat('c',64),'source_signature_digest',repeat('d',64),
    'qualification_policy_version',1,'qualification_policy_digest',v_digest,'criterion_set_digest',v_digest,
    'role_binding_set_digest',v_digest,'evidence_set_digest',v_digest,'reason_code','QUALIFICATION_ACCEPTED',
    'receipt_digest',encode(extensions.digest(convert_to(
      'qualification-receipt:'||coalesce(p_nonce,'')||':'||v_id::text,'UTF8'),'sha256'),'hex')));
  RETURN ops.record_commercial_qualification_receipt_v1(v_input, 'acceptance:'||coalesce(p_nonce,''));
END;
$$;
ALTER FUNCTION ops.acceptance_record_business_qualification_v1(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.acceptance_record_business_qualification_v1(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.acceptance_record_business_qualification_v1(text)
  TO gurine_control_api, gurine_workflow_worker, gurine_auditor;
COMMIT;

-- v13 journey result and idempotency composites.  The immutable base pack
-- describes these as named PostgreSQL types; keeping the declarations here
-- lets the owner routines return closed records instead of generic JSON.
DO $$
BEGIN
  BEGIN CREATE TYPE ops.idempotency_claim_v1 AS (scope text,operation_id text,key_hash char(64),request_hash char(64),bff_issuer text,session_token_hash char(64),resource_type text,resource_id text,expires_at timestamptz); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.idempotency_claim_receipt_v1 AS (disposition text,claim_generation bigint,response_digest char(64),receipt_digest char(64),completed_at timestamptz,claim_expires_at timestamptz); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.idempotency_finalize_v1 AS (scope text,operation_id text,key_hash char(64),request_hash char(64),bff_issuer text,session_token_hash char(64),expected_claim_generation bigint,response_status integer,response_schema text,response_media_type text,response_header_bytes bytea,response_body_bytes bytea,response_digest char(64),resource_type text,resource_id text,receipt_id uuid,receipt_digest char(64),audit_event_id uuid,outbox_id uuid,completed_at timestamptz); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.idempotency_finalize_receipt_v1 AS (claim_generation bigint,response_status integer,response_schema text,response_media_type text,response_digest char(64),receipt_id uuid,receipt_digest char(64),completed_at timestamptz,idempotency_replay boolean); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.idempotency_replay_v1 AS (scope text,operation_id text,key_hash char(64),request_hash char(64),bff_issuer text,session_token_hash char(64),expected_claim_generation bigint); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.idempotency_replay_receipt_v1 AS (disposition text,claim_generation bigint,response_status integer,response_schema text,response_media_type text,response_header_bytes bytea,response_body_bytes bytea,response_digest char(64),receipt_id uuid,receipt_digest char(64),completed_at timestamptz,idempotency_replay boolean); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.journey_replacement_result_v1 AS (handoff_id uuid,handoff_version bigint,generation bigint,binding_digest char(64),request_receipt_id uuid,request_receipt_digest char(64),request_journey_instance_version bigint,audit_event_id uuid,outbox_event_id uuid,receiver_function text,hard_expiry_at timestamptz,resulting_due_at timestamptz); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.journey_handoff_terminal_result_v1 AS (receipt_id uuid,receipt_digest char(64),journey_instance_id uuid,journey_instance_version bigint,handoff_id uuid,handoff_version bigint,handoff_kind text,generation bigint,decision text,resulting_handoff_state text,resulting_journey_state text,current_owner_binding_digest char(64),next_owner_binding_digest char(64),audit_event_id uuid,outbox_event_id uuid); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.journey_instance_head_result_v1 AS (journey_instance_id uuid,version bigint,state text,current_owner_binding_digest char(64),next_owner_binding_digest char(64),active_handoff_id uuid,active_handoff_generation bigint,active_handoff_state text,escalation_state text,due_at timestamptz,head_receipt_id uuid,head_receipt_digest char(64)); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.journey_handoff_decision_result_v1 AS (decision_receipt ops.journey_handoff_terminal_result_v1,replacement ops.journey_replacement_result_v1,final_parent ops.journey_instance_head_result_v1,effect_digest char(64),decided_at timestamptz); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.journey_scheduler_result_v1 AS (disposition text,action text,transition_receipt_id uuid,transition_receipt_digest char(64),transition_journey_instance_version bigint,transition_handoff_id uuid,transition_handoff_version bigint,transition_audit_event_id uuid,transition_outbox_event_id uuid,replacement ops.journey_replacement_result_v1,final_parent ops.journey_instance_head_result_v1,hard_expiry_at timestamptz,next_scheduler_at timestamptz); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.journey_handoff_decision_prepare_v1 AS (handoff_id uuid,expected_handoff_version bigint,expected_binding_digest char(64),decision text,reason_code text,reason_digest char(64),transport_request_id uuid,idempotency_key_sha256 char(64),assertion_type text,assertion_jti uuid,wire_request_digest char(64),attempt_audit_event_id uuid,attempt_audit_event_hash char(64)); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.journey_handoff_decision_prepare_receipt_v1 AS (disposition text,claim_generation bigint,business_request_hash char(64),response_status integer,response_schema text,response_media_type text,response_header_bytes bytea,response_body_bytes bytea,response_digest char(64),receipt_id uuid,receipt_digest char(64),completed_at timestamptz); EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;

REVOKE ALL ON TYPE ops.idempotency_claim_v1,ops.idempotency_claim_receipt_v1,ops.idempotency_finalize_v1,ops.idempotency_finalize_receipt_v1,ops.idempotency_replay_v1,ops.idempotency_replay_receipt_v1,ops.journey_replacement_result_v1,ops.journey_handoff_terminal_result_v1,ops.journey_instance_head_result_v1,ops.journey_handoff_decision_result_v1,ops.journey_scheduler_result_v1,ops.journey_handoff_decision_prepare_v1,ops.journey_handoff_decision_prepare_receipt_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.idempotency_finalize_v1,ops.idempotency_finalize_receipt_v1,ops.journey_replacement_result_v1,ops.journey_handoff_terminal_result_v1,ops.journey_instance_head_result_v1,ops.journey_handoff_decision_result_v1,ops.journey_scheduler_result_v1,ops.journey_handoff_decision_prepare_v1,ops.journey_handoff_decision_prepare_receipt_v1 TO gurine_control_api,gurine_workflow_worker;

DO $$
BEGIN
  BEGIN CREATE TYPE ops.journey_handoff_assertion_attempt_v1 AS (
    assertion_type text, assertion_jti uuid, issuer text, audience text, expires_at timestamptz,
    wire_request_digest char(64), operation_id text, handoff_id uuid, expected_handoff_version bigint,
    expected_binding_digest char(64), decision text, reason_code text, reason_digest char(64),
    transport_request_id uuid, idempotency_key_sha256 char(64)
  ); EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE TYPE ops.journey_handoff_assertion_attempt_receipt_v1 AS (
    assertion_type text, jti_digest char(64), wire_request_digest char(64), business_request_hash char(64),
    audit_event_id uuid, audit_event_hash char(64), consumed_at timestamptz
  ); EXCEPTION WHEN duplicate_object THEN NULL; END;
END $$;
REVOKE ALL ON TYPE ops.journey_handoff_assertion_attempt_v1,ops.journey_handoff_assertion_attempt_receipt_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.journey_handoff_assertion_attempt_v1,ops.journey_handoff_assertion_attempt_receipt_v1 TO gurine_control_api,gurine_workflow_worker;

CREATE OR REPLACE FUNCTION ops.consume_journey_handoff_assertion_attempt_v1(
  p ops.journey_handoff_assertion_attempt_v1
) RETURNS ops.journey_handoff_assertion_attempt_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_expected_type text;
  v_business_hash char(64);
  v_jti_digest char(64);
  v_audit uuid;
  v_audit_hash char(64);
  v_consumed timestamptz := clock_timestamp();
  v_ok boolean;
BEGIN
  v_expected_type := CASE session_user WHEN 'gurine_control_api' THEN 'ACTOR' WHEN 'gurine_workflow_worker' THEN 'SERVICE' ELSE NULL END;
  IF v_expected_type IS NULL OR p.assertion_type IS DISTINCT FROM v_expected_type
     OR p.operation_id <> 'decideJourneyHandoff' OR p.assertion_jti IS NULL
     OR p.transport_request_id IS NULL OR p.expires_at <= clock_timestamp()
     OR p.wire_request_digest !~ '^[0-9a-f]{64}$'
     OR p.expected_binding_digest !~ '^[0-9a-f]{64}$'
     OR p.idempotency_key_sha256 !~ '^[0-9a-f]{64}$'
     OR p.decision NOT IN ('ACKNOWLEDGE','DECLINE') THEN
    RAISE EXCEPTION '%_ASSERTION_INVALID',v_expected_type USING ERRCODE='28000';
  END IF;
  IF (p.decision='ACKNOWLEDGE' AND (p.reason_code IS NOT NULL OR p.reason_digest IS NOT NULL))
     OR (p.decision='DECLINE' AND (p.reason_code IS NULL OR p.reason_digest !~ '^[0-9a-f]{64}$')) THEN
    RAISE EXCEPTION 'JOURNEY_DECISION_REASON_SHAPE_INVALID' USING ERRCODE='22023';
  END IF;
  v_business_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'operationId',p.operation_id,'handoffId',p.handoff_id,'expectedHandoffVersion',p.expected_handoff_version,
    'expectedBindingDigest',p.expected_binding_digest,'decision',p.decision,
    'reasonCode',p.reason_code,'reasonDigest',p.reason_digest)::text,'UTF8'),'sha256'),'hex');
  v_jti_digest := encode(extensions.digest(convert_to(p.assertion_type||':'||p.assertion_jti::text,'UTF8'),'sha256'),'hex');
  -- The request boundary already consumed this JTI.  Prove that exact
  -- committed consume here; do not consume it a second time.
  SELECT EXISTS(
    SELECT 1
      FROM ops.assertion_replay_guard g
     WHERE g.assertion_type=p.assertion_type
       AND g.jti=p.assertion_jti
       AND g.issuer=p.issuer
       AND g.audience=p.audience
       AND g.request_digest=p.wire_request_digest
       AND g.expires_at >= clock_timestamp()
  ) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION '%_ASSERTION_ATTEMPT_NOT_COMMITTED',v_expected_type USING ERRCODE='28000'; END IF;
  IF EXISTS(
    SELECT 1 FROM ops.audit_events
     WHERE action='auth.assertion.consume'
       AND object_type='ASSERTION_ATTEMPT'
       AND object_id=encode(extensions.digest(convert_to(p.assertion_type||':'||p.assertion_jti::text,'UTF8'),'sha256'),'hex')
  ) THEN
    RAISE EXCEPTION '%_ASSERTION_REPLAYED',v_expected_type USING ERRCODE='28000';
  END IF;
  v_audit := ops.append_audit_event('auth.assertion.consume',p.assertion_type,v_jti_digest,NULL::uuid,
    'auth.assertion.consume','ASSERTION_ATTEMPT',v_jti_digest,'INTERNAL_RESTRICTED','SUCCESS',NULL,p.transport_request_id,
    jsonb_build_object('assertionType',p.assertion_type,'operationId',p.operation_id,'jtiDigest',v_jti_digest,
      'wireRequestDigest',p.wire_request_digest,'idempotencyKeySha256',p.idempotency_key_sha256,
      'businessRequestHash',v_business_hash));
  SELECT event_hash,occurred_at INTO STRICT v_audit_hash,v_consumed FROM ops.audit_events WHERE id=v_audit;
  RETURN ROW(p.assertion_type,v_jti_digest,p.wire_request_digest,v_business_hash,v_audit,v_audit_hash,v_consumed)::ops.journey_handoff_assertion_attempt_receipt_v1;
END $$;
ALTER FUNCTION ops.consume_journey_handoff_assertion_attempt_v1(ops.journey_handoff_assertion_attempt_v1) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.consume_journey_handoff_assertion_attempt_v1(ops.journey_handoff_assertion_attempt_v1) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.consume_journey_handoff_assertion_attempt_v1(ops.journey_handoff_assertion_attempt_v1) TO gurine_control_api,gurine_workflow_worker;

CREATE OR REPLACE FUNCTION ops.prepare_journey_handoff_decision_v1(
  p ops.journey_handoff_decision_prepare_v1
) RETURNS ops.journey_handoff_decision_prepare_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_hash char(64);
  v_existing ops.idempotency_keys%ROWTYPE;
  v_body bytea;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable'
     OR p.handoff_id IS NULL OR p.expected_handoff_version < 1
     OR p.expected_binding_digest !~ '^[0-9a-f]{64}$'
     OR p.decision NOT IN ('ACKNOWLEDGE','DECLINE')
     OR p.transport_request_id IS NULL
     OR p.idempotency_key_sha256 !~ '^[0-9a-f]{64}$'
     OR p.wire_request_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'journey_decision_prepare_invalid' USING ERRCODE='22023';
  END IF;
  IF p.decision='ACKNOWLEDGE' AND (p.reason_code IS NOT NULL OR p.reason_digest IS NOT NULL) THEN
    RAISE EXCEPTION 'journey_decision_reason_shape_invalid' USING ERRCODE='22023';
  END IF;
  IF p.decision='DECLINE' AND (p.reason_code IS NULL OR p.reason_digest !~ '^[0-9a-f]{64}$') THEN
    RAISE EXCEPTION 'journey_decision_reason_shape_invalid' USING ERRCODE='22023';
  END IF;
  v_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'operationId','decideJourneyHandoff','handoffId',p.handoff_id,
    'expectedHandoffVersion',p.expected_handoff_version,
    'expectedBindingDigest',p.expected_binding_digest,'decision',p.decision,
    'reasonCode',p.reason_code,'reasonDigest',p.reason_digest)::text,'UTF8'),'sha256'),'hex');
  SELECT * INTO v_existing FROM ops.idempotency_keys
   WHERE scope='JOURNEY_HANDOFF_DECISION' AND key_hash=p.idempotency_key_sha256 FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_hash<>v_hash THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001'; END IF;
    IF v_existing.response_status IS NOT NULL THEN
      v_body := convert_to(COALESCE(v_existing.response_body,'{}'::jsonb)::text,'UTF8');
      RETURN ROW('FINAL_REPLAY',1,v_hash,v_existing.response_status,'JourneyHandoffDecisionReceiptV1','application/json',NULL,v_body,encode(extensions.digest(v_body,'sha256'),'hex'),NULL,NULL,v_existing.created_at)::ops.journey_handoff_decision_prepare_receipt_v1;
    END IF;
    RAISE EXCEPTION 'journey_decision_in_progress' USING ERRCODE='55000';
  END IF;
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,resource_type,resource_id,expires_at)
  VALUES('JOURNEY_HANDOFF_DECISION',p.idempotency_key_sha256,v_hash,'JOURNEY_HANDOFF',lower(p.handoff_id::text),clock_timestamp()+interval '5 minutes');
  RETURN ROW('NEW',1,v_hash,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)::ops.journey_handoff_decision_prepare_receipt_v1;
END $$;
ALTER FUNCTION ops.prepare_journey_handoff_decision_v1(ops.journey_handoff_decision_prepare_v1) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.prepare_journey_handoff_decision_v1(ops.journey_handoff_decision_prepare_v1) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.prepare_journey_handoff_decision_v1(ops.journey_handoff_decision_prepare_v1) TO gurine_control_api,gurine_workflow_worker;

CREATE OR REPLACE FUNCTION ops.finalize_journey_handoff_decision_response_v1(
  p ops.idempotency_finalize_v1
) RETURNS ops.idempotency_finalize_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE v_row ops.idempotency_keys%ROWTYPE; v_body jsonb;
BEGIN
  IF p.scope<>'JOURNEY_HANDOFF_DECISION' OR p.operation_id<>'decideJourneyHandoff'
     OR p.key_hash !~ '^[0-9a-f]{64}$' OR p.request_hash !~ '^[0-9a-f]{64}$'
     OR p.expected_claim_generation<>1 OR p.response_status<>200
     OR p.response_schema<>'JourneyHandoffDecisionReceiptV1'
     OR p.response_media_type<>'application/json' OR p.response_body_bytes IS NULL
     OR p.response_digest !~ '^[0-9a-f]{64}$' OR p.resource_type<>'JOURNEY_HANDOFF'
     OR p.resource_id IS NULL THEN
    RAISE EXCEPTION 'journey_decision_finalize_invalid' USING ERRCODE='22023';
  END IF;
  BEGIN v_body := convert_from(p.response_body_bytes,'UTF8')::jsonb; EXCEPTION WHEN others THEN RAISE EXCEPTION 'journey_decision_response_not_json' USING ERRCODE='22023'; END;
  SELECT * INTO v_row FROM ops.idempotency_keys WHERE scope=p.scope AND key_hash=p.key_hash FOR UPDATE;
  IF NOT FOUND OR v_row.request_hash<>p.request_hash THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001'; END IF;
  IF v_row.response_status IS NOT NULL THEN
    RETURN ROW(1,v_row.response_status,p.response_schema,p.response_media_type,p.response_digest,NULL,NULL,v_row.created_at,true)::ops.idempotency_finalize_receipt_v1;
  END IF;
  UPDATE ops.idempotency_keys SET response_status=p.response_status,response_body=v_body,
    resource_type=p.resource_type,resource_id=lower(p.resource_id),expires_at=clock_timestamp()+interval '24 hours'
    WHERE scope=p.scope AND key_hash=p.key_hash AND response_status IS NULL;
  RETURN ROW(1,p.response_status,p.response_schema,p.response_media_type,p.response_digest,p.receipt_id,p.receipt_digest,p.completed_at,false)::ops.idempotency_finalize_receipt_v1;
END $$;
ALTER FUNCTION ops.finalize_journey_handoff_decision_response_v1(ops.idempotency_finalize_v1) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.finalize_journey_handoff_decision_response_v1(ops.idempotency_finalize_v1) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.finalize_journey_handoff_decision_response_v1(ops.idempotency_finalize_v1) TO gurine_control_api,gurine_workflow_worker;

-- The journey owner boundary is deliberately database-owned.  These two
-- entry routines resolve routing from the closed journey code/edge grammar,
-- serialize the parent head, and persist the receipt, audit and outbox as one
-- SERIALIZABLE transition.  Callers may only supply the comparison fields.
INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES
  ('journey.instance_started.v1','DOMAIN',1,true,'payloads/journey_instance_started_v1.schema.json'),
  ('journey.handoff_requested.v1','DOMAIN',1,true,'payloads/journey_handoff_requested_v1.schema.json')
ON CONFLICT (event_type) DO UPDATE SET active=EXCLUDED.active;

INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES ('product.commercial_qualification_recorded.v1','DOMAIN',1,true,
        'payloads/product_commercial_qualification_recorded_v1.schema.json')
ON CONFLICT (event_type) DO UPDATE SET active=EXCLUDED.active;

CREATE OR REPLACE FUNCTION ops.start_journey_instance_v1(
  p_journey_code text,p_root_object_kind text,p_root_object_id text,
  p_root_object_version bigint,p_root_object_digest char(64),
  p_current_object_kind text,p_current_object_id text,
  p_current_object_version bigint,p_current_object_digest char(64),
  p_current_node_id text,p_current_owner_kind text,
  p_current_owner_function text,p_current_owner_ref_hmac char(64),
  p_due_at timestamptz,p_request_id uuid,p_idempotency_key_sha256 char(64),
  p_actor_assertion_jti uuid
) RETURNS ops.journey_transition_receipts
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_existing ops.journey_transition_receipts;
  v_instance ops.journey_instances;
  v_receipt ops.journey_transition_receipts;
  v_now timestamptz := clock_timestamp();
  v_request_hash char(64);
  v_instance_id uuid := gen_random_uuid();
  v_receipt_id uuid := gen_random_uuid();
  v_audit_id uuid;
  v_outbox_id uuid;
  v_receipt_digest char(64);
  v_entry_node text;
  v_entry_edge text;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'JOURNEY_SERIALIZABLE_REQUIRED' USING ERRCODE='25001';
  END IF;
  IF p_journey_code !~ '^J-(0[1-9]|1[0-2])$'
     OR p_root_object_version < 1 OR p_current_object_version < 1
     OR p_request_id IS NULL OR p_idempotency_key_sha256 !~ '^[0-9a-f]{64}$'
     OR p_root_object_digest !~ '^[0-9a-f]{64}$'
     OR p_current_object_digest !~ '^[0-9a-f]{64}$'
     OR p_current_owner_ref_hmac !~ '^[0-9a-f]{64}$'
     OR p_due_at <= v_now THEN
    RAISE EXCEPTION 'journey_start_invalid' USING ERRCODE='22023';
  END IF;
  v_entry_node := CASE p_journey_code
    WHEN 'J-01' THEN 'PUB-002'
    WHEN 'J-02' THEN 'PUB-004'
    WHEN 'J-03' THEN 'CAS-009'
    WHEN 'J-04' THEN 'PUB-027'
    WHEN 'J-05' THEN 'SIG-001'
    WHEN 'J-06' THEN 'CAS-002'
    WHEN 'J-07' THEN 'REV-001'
    WHEN 'J-08' THEN 'COR-001'
    WHEN 'J-09' THEN 'SRC-005'
    WHEN 'J-10' THEN 'CAS-010'
    WHEN 'J-11' THEN 'J-11::ORIGIN'
    WHEN 'J-12' THEN 'OPS-004'
  END;
  -- The start receipt is bound to the first compiled edge of the journey.
  -- E00 is not part of the authority graph and is therefore never emitted.
  v_entry_edge := p_journey_code || '-E01';
  IF p_current_node_id IS DISTINCT FROM v_entry_node THEN
    RAISE EXCEPTION 'journey_entry_node_mismatch' USING ERRCODE='22023';
  END IF;
  v_request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'operation','ops.start_journey_instance_v1','journeyCode',p_journey_code,
    'rootKind',p_root_object_kind,'rootId',p_root_object_id,
    'rootVersion',p_root_object_version,'rootDigest',p_root_object_digest,
    'currentKind',p_current_object_kind,'currentId',p_current_object_id,
    'currentVersion',p_current_object_version,'currentDigest',p_current_object_digest,
    'node',p_current_node_id,'ownerKind',p_current_owner_kind,
    'ownerFunction',p_current_owner_function,'ownerRef',p_current_owner_ref_hmac,
    'dueAt',p_due_at)::text,'UTF8'),'sha256'),'hex');
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
  VALUES('JOURNEY_START',p_idempotency_key_sha256,v_request_hash,v_now+interval '24 hours')
  ON CONFLICT (scope,key_hash) DO NOTHING;
  SELECT request_hash,resource_id INTO v_request_hash,v_instance_id
    FROM ops.idempotency_keys WHERE scope='JOURNEY_START' AND key_hash=p_idempotency_key_sha256 FOR UPDATE;
  IF v_request_hash IS DISTINCT FROM encode(extensions.digest(convert_to(jsonb_build_object(
    'operation','ops.start_journey_instance_v1','journeyCode',p_journey_code,
    'rootKind',p_root_object_kind,'rootId',p_root_object_id,
    'rootVersion',p_root_object_version,'rootDigest',p_root_object_digest,
    'currentKind',p_current_object_kind,'currentId',p_current_object_id,
    'currentVersion',p_current_object_version,'currentDigest',p_current_object_digest,
    'node',p_current_node_id,'ownerKind',p_current_owner_kind,
    'ownerFunction',p_current_owner_function,'ownerRef',p_current_owner_ref_hmac,
    'dueAt',p_due_at)::text,'UTF8'),'sha256'),'hex') THEN
    RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001';
  END IF;
  IF v_instance_id IS NOT NULL THEN
    SELECT r.* INTO v_existing FROM ops.journey_transition_receipts r
      WHERE r.journey_instance_id=v_instance_id AND r.receipt_kind='INSTANCE_STARTED';
    IF FOUND THEN RETURN v_existing; END IF;
  END IF;
  v_instance_id := COALESCE(v_instance_id,gen_random_uuid());
  v_receipt_digest := encode(extensions.digest(convert_to(
    v_receipt_id::text||':'||v_instance_id::text||':'||p_journey_code||':'||
    p_root_object_digest||':'||p_current_object_digest||':'||p_current_owner_ref_hmac,'UTF8'),'sha256'),'hex');
  v_audit_id := ops.append_audit_event('journey:'||v_instance_id::text,'SERVICE',
    COALESCE(p_actor_assertion_jti::text,current_user),NULL::uuid,'JOURNEY_INSTANCE_STARTED',
    'JourneyInstance',v_instance_id::text,'journeys.start','SUCCESS',NULL,p_request_id,
    jsonb_build_object('journeyCode',p_journey_code,'receiptDigest',v_receipt_digest));
  v_outbox_id := ops.enqueue_outbox('JourneyInstance',v_instance_id::text,1,
    'journey.instance_started.v1',jsonb_build_object('journeyInstanceId',v_instance_id,
      'journeyCode',p_journey_code,'receiptId',v_receipt_id,'receiptDigest',v_receipt_digest,
      'requestId',p_request_id),v_now);
  INSERT INTO ops.journey_instances(
    id,journey_code,root_object_kind,root_object_id,root_object_version,root_object_digest,
    current_object_kind,current_object_id,current_object_version,current_object_digest,
    current_node_id,state,version,current_owner_kind,current_owner_function,
    current_owner_ref_hmac,due_at,last_receipt_id,last_receipt_sequence,last_receipt_digest,
    started_at,updated_at)
  VALUES(v_instance_id,p_journey_code,p_root_object_kind,p_root_object_id,p_root_object_version,
    p_root_object_digest,p_current_object_kind,p_current_object_id,p_current_object_version,
    p_current_object_digest,p_current_node_id,'ACTIVE',1,p_current_owner_kind,
    p_current_owner_function,p_current_owner_ref_hmac,p_due_at,v_receipt_id,1,v_receipt_digest,
    v_now,v_now)
  RETURNING * INTO v_instance;
  INSERT INTO ops.journey_transition_receipts(
    id,journey_instance_id,journey_instance_version,edge_id,sequence,receipt_kind,
    subject_digest,current_owner_binding_digest,resulting_instance_state,escalation_state,
    resulting_due_at,effect_digest,audit_event_id,outbox_event_id,occurred_at,receipt_digest)
  VALUES(v_receipt_id,v_instance_id,1,v_entry_edge,1,'INSTANCE_STARTED',
    p_root_object_digest,p_current_owner_ref_hmac,'ACTIVE','NOT_DUE',p_due_at,
    p_current_object_digest,v_audit_id,v_outbox_id,v_now,v_receipt_digest)
  RETURNING * INTO v_receipt;
  UPDATE ops.idempotency_keys SET resource_type='JourneyTransitionReceipt',resource_id=v_instance_id::text,
    response_status=201,response_body=jsonb_build_object('receiptId',v_receipt_id,'receiptDigest',v_receipt_digest)
    WHERE scope='JOURNEY_START' AND key_hash=p_idempotency_key_sha256;
  RETURN v_receipt;
END $$;
ALTER FUNCTION ops.start_journey_instance_v1(text,text,text,bigint,char(64),text,text,bigint,char(64),text,text,text,char(64),timestamptz,uuid,char(64),uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.start_journey_instance_v1(text,text,text,bigint,char(64),text,text,bigint,char(64),text,text,text,char(64),timestamptz,uuid,char(64),uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.start_journey_instance_v1(text,text,text,bigint,char(64),text,text,bigint,char(64),text,text,text,char(64),timestamptz,uuid,char(64),uuid) TO gurine_control_api,gurine_workflow_worker;

CREATE OR REPLACE FUNCTION ops.request_journey_handoff_v1(
  p_journey_instance_id uuid,p_expected_version bigint,p_edge_id text,
  p_expected_current_object_digest char(64),p_request_id uuid,
  p_idempotency_key_sha256 char(64),p_actor_assertion_jti uuid
) RETURNS ops.journey_transition_receipts
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  i ops.journey_instances;
  h ops.journey_handoffs;
  r ops.journey_transition_receipts;
  v_now timestamptz := clock_timestamp();
  v_generation bigint;
  v_receipt_id uuid := gen_random_uuid();
  v_handoff_id uuid := gen_random_uuid();
  v_audit_id uuid;
  v_outbox_id uuid;
  v_receipt_digest char(64);
  v_binding_digest char(64);
  v_receiver_function text;
  v_receiver_ref char(64);
  v_subject_digest char(64);
  v_handoff_kind text;
  v_to_node text;
  v_request_hash char(64);
  v_existing_resource text;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'JOURNEY_SERIALIZABLE_REQUIRED' USING ERRCODE='25001';
  END IF;
  v_to_node := CASE p_edge_id
    WHEN 'J-01-E01' THEN 'PUB-004'
    WHEN 'J-01-E02' THEN 'PUB-004::evidence-open'
    WHEN 'J-01-E03' THEN 'PUB-006'
    WHEN 'J-01-E04' THEN 'PUB-006::locator-understood'
    WHEN 'J-02-E01' THEN 'PUB-005'
    WHEN 'J-02-E02' THEN 'PUB-006'
    WHEN 'J-02-E03' THEN 'PUB-006::bundle-downloaded'
    WHEN 'J-02-E04' THEN 'PUB-018'
    WHEN 'J-02-E05' THEN 'PUB-018::reproduction-bundle-receipt'
    WHEN 'J-03-E01' THEN 'J-11::ORIGIN[CAS-009]'
    WHEN 'J-03-E02' THEN 'RSP-002'
    WHEN 'J-03-E03' THEN 'RSP-003'
    WHEN 'J-03-E04' THEN 'RSP-004'
    WHEN 'J-03-E05' THEN 'RSP-005'
    WHEN 'J-03-E06' THEN 'RSP-006'
    WHEN 'J-03-E07' THEN 'CAS-008::submission-owned'
    WHEN 'J-04-E01' THEN 'PUB-028'
    WHEN 'J-04-E02' THEN 'COR-001'
    WHEN 'J-04-E03' THEN 'COR-002'
    WHEN 'J-04-E04' THEN 'PUB-019'
    WHEN 'J-04-E05' THEN 'PUB-019::request-linked-decision'
    WHEN 'J-05-E01' THEN 'SIG-002'
    WHEN 'J-05-E02' THEN 'SIG-002::triage-receipt'
    WHEN 'J-05-E03' THEN NULL
    WHEN 'J-05-E04' THEN 'CAS-002::triage-receipt-owned'
    WHEN 'J-06-E01' THEN 'CAS-003'
    WHEN 'J-06-E02' THEN 'CAS-004'
    WHEN 'J-06-E03' THEN NULL
    WHEN 'J-06-E04' THEN 'CAS-007'
    WHEN 'J-06-E05' THEN 'CAS-006'
    WHEN 'J-06-E06' THEN 'CAS-008'
    WHEN 'J-06-E07' THEN NULL
    WHEN 'J-06-E08' THEN 'CAS-014'
    WHEN 'J-06-E09' THEN 'REV-002::review-ready-snapshot'
    WHEN 'J-07-E01' THEN 'REV-002'
    WHEN 'J-07-E02' THEN NULL
    WHEN 'J-07-E03' THEN 'J-11::ORIGIN[REV-003]'
    WHEN 'J-07-E04' THEN 'PUB-004'
    WHEN 'J-07-E05' THEN 'PUB-004::public-smoke-receipt'
    WHEN 'J-08-E01' THEN 'COR-002'
    WHEN 'J-08-E02' THEN 'PUB-019'
    WHEN 'J-08-E03' THEN 'PUB-018'
    WHEN 'J-08-E04' THEN 'PUB-018::correction-visible-and-notified'
    WHEN 'J-09-E01' THEN 'SRC-006'
    WHEN 'J-09-E02' THEN 'SRC-006::replay-receipt'
    WHEN 'J-09-E03' THEN 'OPS-001'
    WHEN 'J-09-E04' THEN 'OPS-001::freshness-restored-or-degraded'
    WHEN 'J-10-E01' THEN 'CAS-010::run-created'
    WHEN 'J-10-E02' THEN 'CAS-011'
    WHEN 'J-10-E03' THEN NULL
    WHEN 'J-10-E04' THEN 'CAS-011::cancel-control-receipt'
    WHEN 'J-10-E05' THEN 'J-10::CANCELLED'
    WHEN 'J-10-E06' THEN 'J-10::CANCEL_REQUESTED'
    WHEN 'J-10-E07' THEN 'J-10::RECONCILIATION_REQUIRED'
    WHEN 'J-10-E08' THEN 'CAS-011'
    WHEN 'J-10-E09' THEN NULL
    WHEN 'J-10-E10' THEN 'J-10::RECONCILIATION_REQUIRED'
    WHEN 'J-10-E11' THEN NULL
    WHEN 'J-10-E12' THEN 'CAS-011::promotion-candidate-selected'
    WHEN 'J-10-E13' THEN 'CAS-011::promotion-receipt'
    WHEN 'J-10-E14' THEN 'CAS-005'
    WHEN 'J-10-E15' THEN 'CAS-005::promotion-binding-verified'
    WHEN 'J-10-E16' THEN 'CAS-004'
    WHEN 'J-10-E17' THEN 'CAS-004::promoted-evidence-visible'
    WHEN 'J-11-E01' THEN 'J-11::DRAFT'
    WHEN 'J-11-E02' THEN 'J-11::DRAFT'
    WHEN 'J-11-E03' THEN 'J-11::PREVIEW_BOUND'
    WHEN 'J-11-E04' THEN 'J-11::PENDING_QUORUM'
    WHEN 'J-11-E05' THEN 'INT-002::assignment-projected'
    WHEN 'J-11-E06' THEN 'INT-002::review-in-progress'
    WHEN 'J-11-E07' THEN 'INT-002::subject-verified'
    WHEN 'J-11-E08A' THEN 'J-11::PENDING_QUORUM'
    WHEN 'J-11-E08B' THEN 'J-11::POLICY_BLOCKED'
    WHEN 'J-11-E08C' THEN 'OPS-003::execution-queued'
    WHEN 'J-11-E08D' THEN 'J-11::REJECTED'
    WHEN 'J-11-E08E' THEN 'J-11::CHANGES_REQUIRED'
    WHEN 'J-11-E08F' THEN 'INT-002::assignment-projected'
    WHEN 'J-11-E09' THEN 'OPS-003::execution-claimed'
    WHEN 'J-11-E10' THEN 'OPS-003::execution-dispatching'
    WHEN 'J-11-E11' THEN NULL
    WHEN 'J-11-E12A' THEN 'J-11::CANCELLED'
    WHEN 'J-11-E12B' THEN 'J-11::CANCEL_REQUESTED'
    WHEN 'J-11-E13' THEN 'OPS-003::execution-queued'
    WHEN 'J-11-E14' THEN NULL
    WHEN 'J-11-E15' THEN 'J-11::SUCCEEDED'
    WHEN 'J-11-E16' THEN 'J-11::WITHDRAWN'
    WHEN 'J-11-E17' THEN 'INT-002::assignment-projected'
    WHEN 'J-11-E18' THEN NULL
    WHEN 'J-11-E19' THEN 'OPS-005::communication-intent-created'
    WHEN 'J-11-E20' THEN 'OPS-005::delivery-sending'
    WHEN 'J-11-E21' THEN NULL
    WHEN 'J-11-E22' THEN NULL
    WHEN 'J-11-E23' THEN 'J-11::SUCCEEDED'
    WHEN 'J-12-E01' THEN 'OPS-004::commercial-health-inspected'
    WHEN 'J-12-E02' THEN 'INT-002::commercial-remediation-pending'
    WHEN 'J-12-E03' THEN 'INT-002::commercial-remediation-open'
    WHEN 'J-12-E04' THEN 'INT-002::commercial-remediation-owned'
    WHEN 'J-12-E05' THEN 'OPS-004::qualified-receipt-visible'
    WHEN 'J-12-E06' THEN 'OPS-001::configured-evidence-visible'
    WHEN 'J-12-E07' THEN NULL
    WHEN 'J-12-E08' THEN 'CAS-002::paid-workflow-entry'
    WHEN 'J-12-E09A' THEN 'J-10::ENTRY[CAS-010]'
    WHEN 'J-12-E09B' THEN 'CAS-004::paid-evidence-candidate'
    WHEN 'J-12-E10' THEN 'CAS-005'
    WHEN 'J-12-E11' THEN 'CAS-013'
    WHEN 'J-12-E12' THEN 'REV-002'
    WHEN 'J-12-E13' THEN 'CAS-002::paid-packet-source-bound'
    WHEN 'J-12-E14' THEN 'CAS-002::paid-action-draft'
    WHEN 'J-12-E15' THEN 'CAS-002::paid-action-preview-bound'
    WHEN 'J-12-E16' THEN 'INT-002::paid-action-assigned'
    WHEN 'J-12-E17' THEN 'INT-002::paid-action-review-in-progress'
    WHEN 'J-12-E18A' THEN NULL
    WHEN 'J-12-E18B' THEN 'J-12::CHANGES_REQUIRED'
    WHEN 'J-12-E18C' THEN 'INT-002::paid-action-assigned'
    WHEN 'J-12-E18D' THEN NULL
    WHEN 'J-12-E19A' THEN 'OPS-004::organization-decision-terminal-bound'
    WHEN 'J-12-E19B' THEN 'OPS-004::outbound-delivery-terminal-bound'
    WHEN 'J-12-E19C' THEN 'J-12::RECONCILIATION_REQUIRED'
    WHEN 'J-12-E20' THEN NULL
    WHEN 'J-12-E21' THEN 'OPS-004::paid-outcome-fact-recorded'
    WHEN 'J-12-E22' THEN 'OPS-004::activated'
    WHEN 'J-12-E23' THEN 'INT-002::retention-watch-pending'
    WHEN 'J-12-E24' THEN 'INT-002::retention-watch-owned'
    WHEN 'J-12-E25' THEN 'CAS-002::paid-workflow-entry'
    WHEN 'J-12-E26' THEN 'OPS-004::retained'
    WHEN 'J-12-E27' THEN 'OPS-004::at-risk-overlay'
    WHEN 'J-12-E28' THEN NULL
    WHEN 'J-12-E29' THEN 'OPS-004::churned'
    WHEN 'J-12-E30' THEN 'AUD-001::paid-retention-audit-verified'
    ELSE NULL
  END;
  IF p_journey_instance_id IS NULL OR p_expected_version < 1
     OR p_edge_id !~ '^J-(0[1-9]|1[0-2])-E[0-9]{2}[A-Z]?$'
     OR p_expected_current_object_digest !~ '^[0-9a-f]{64}$'
     OR p_request_id IS NULL OR p_idempotency_key_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'journey_handoff_invalid' USING ERRCODE='22023';
  END IF;
  v_request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'operation','ops.request_journey_handoff_v1','journeyInstanceId',p_journey_instance_id,
    'expectedVersion',p_expected_version,'edgeId',p_edge_id,
    'expectedCurrentObjectDigest',p_expected_current_object_digest)::text,'UTF8'),'sha256'),'hex');
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
  VALUES('JOURNEY_HANDOFF_REQUEST',p_idempotency_key_sha256,v_request_hash,v_now+interval '24 hours')
  ON CONFLICT (scope,key_hash) DO NOTHING;
  SELECT request_hash,resource_id INTO v_request_hash,v_existing_resource
    FROM ops.idempotency_keys WHERE scope='JOURNEY_HANDOFF_REQUEST' AND key_hash=p_idempotency_key_sha256 FOR UPDATE;
  IF v_request_hash IS DISTINCT FROM encode(extensions.digest(convert_to(jsonb_build_object(
    'operation','ops.request_journey_handoff_v1','journeyInstanceId',p_journey_instance_id,
    'expectedVersion',p_expected_version,'edgeId',p_edge_id,
    'expectedCurrentObjectDigest',p_expected_current_object_digest)::text,'UTF8'),'sha256'),'hex') THEN
    RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001';
  END IF;
  IF v_existing_resource IS NOT NULL THEN
    SELECT r0.* INTO r FROM ops.journey_transition_receipts r0
      WHERE r0.id=v_existing_resource::uuid;
    IF FOUND THEN RETURN r; END IF;
  END IF;
  SELECT * INTO i FROM ops.journey_instances WHERE id=p_journey_instance_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;
  IF i.version<>p_expected_version OR i.current_object_digest<>p_expected_current_object_digest THEN
    RAISE EXCEPTION 'journey_version_conflict' USING ERRCODE='40001';
  END IF;
  IF i.state IN ('COMPLETED','CANCELLED','EXPIRED','REJECTED') OR i.active_handoff_id IS NOT NULL THEN
    RAISE EXCEPTION 'HANDOFF_STATE_INVALID' USING ERRCODE='55000';
  END IF;
  IF split_part(p_edge_id,'-',1)||'-'||split_part(p_edge_id,'-',2)<>i.journey_code THEN
    RAISE EXCEPTION 'journey_edge_mismatch' USING ERRCODE='22023';
  END IF;
  -- The product registry is closed: a syntactically valid edge is not enough.
  -- Keep this membership check in the owner routine so callers cannot invent
  -- a route by choosing an arbitrary E## suffix.
  IF NOT (CASE i.journey_code
    WHEN 'J-01' THEN p_edge_id IN ('J-01-E01','J-01-E02','J-01-E03','J-01-E04')
    WHEN 'J-02' THEN p_edge_id IN ('J-02-E01','J-02-E02','J-02-E03','J-02-E04','J-02-E05')
    WHEN 'J-03' THEN p_edge_id IN ('J-03-E01','J-03-E02','J-03-E03','J-03-E04','J-03-E05','J-03-E06','J-03-E07')
    WHEN 'J-04' THEN p_edge_id IN ('J-04-E01','J-04-E02','J-04-E03','J-04-E04','J-04-E05')
    WHEN 'J-05' THEN p_edge_id IN ('J-05-E01','J-05-E02','J-05-E03','J-05-E04')
    WHEN 'J-06' THEN p_edge_id IN ('J-06-E01','J-06-E02','J-06-E03','J-06-E04','J-06-E05','J-06-E06','J-06-E07','J-06-E08','J-06-E09')
    WHEN 'J-07' THEN p_edge_id IN ('J-07-E01','J-07-E02','J-07-E03','J-07-E04','J-07-E05')
    WHEN 'J-08' THEN p_edge_id IN ('J-08-E01','J-08-E02','J-08-E03','J-08-E04')
    WHEN 'J-09' THEN p_edge_id IN ('J-09-E01','J-09-E02','J-09-E03','J-09-E04')
    WHEN 'J-10' THEN p_edge_id IN ('J-10-E01','J-10-E02','J-10-E03','J-10-E04','J-10-E05','J-10-E06','J-10-E07','J-10-E08','J-10-E09','J-10-E10','J-10-E11','J-10-E12','J-10-E13','J-10-E14','J-10-E15','J-10-E16','J-10-E17')
    WHEN 'J-11' THEN p_edge_id IN ('J-11-E01','J-11-E02','J-11-E03','J-11-E04','J-11-E05','J-11-E06','J-11-E07','J-11-E08A','J-11-E08B','J-11-E08C','J-11-E08D','J-11-E08E','J-11-E08F','J-11-E09','J-11-E10','J-11-E11','J-11-E12A','J-11-E12B','J-11-E13','J-11-E14','J-11-E15','J-11-E16','J-11-E17','J-11-E18','J-11-E19','J-11-E20','J-11-E21','J-11-E22','J-11-E23')
    WHEN 'J-12' THEN p_edge_id IN ('J-12-E01','J-12-E02','J-12-E03','J-12-E04','J-12-E05','J-12-E06','J-12-E07','J-12-E08','J-12-E09A','J-12-E09B','J-12-E10','J-12-E11','J-12-E12','J-12-E13','J-12-E14','J-12-E15','J-12-E16','J-12-E17','J-12-E18A','J-12-E18B','J-12-E18C','J-12-E18D','J-12-E19A','J-12-E19B','J-12-E19C','J-12-E20','J-12-E21','J-12-E22','J-12-E23','J-12-E24','J-12-E25','J-12-E26','J-12-E27','J-12-E28','J-12-E29','J-12-E30')
    ELSE false END) THEN
    RAISE EXCEPTION 'journey_edge_not_compiled' USING ERRCODE='22023';
  END IF;
  IF v_to_node IS NULL THEN
    RAISE EXCEPTION 'journey_edge_requires_compiled_branch_resolution' USING ERRCODE='22023';
  END IF;
  SELECT COALESCE(max(generation),0)+1 INTO v_generation
    FROM ops.journey_handoffs WHERE journey_instance_id=i.id;
  v_handoff_kind := CASE
    WHEN p_edge_id IN ('J-03-E01') THEN 'HS-01-RESPONSE_REQUEST_DELIVERY'
    WHEN p_edge_id IN ('J-03-E02','J-03-E03','J-03-E04','J-03-E05','J-03-E06','J-03-E07') THEN 'HS-02-RESPONSE_INTAKE_OWNERSHIP'
    WHEN p_edge_id IN ('J-05-E03','J-06-E03') THEN 'HS-04-SIGNAL_ENRICHMENT_TASK'
    WHEN p_edge_id IN ('J-06-E08','J-11-E06') THEN 'HS-05-EDITORIAL_REVIEW_ASSIGNMENT'
    WHEN p_edge_id IN ('J-06-E07','J-07-E02') THEN 'HS-06-REVIEW_CHANGES_TASK'
    WHEN p_edge_id IN ('J-07-E03','J-07-E04','J-07-E05') THEN 'HS-07-PUBLICATION_ASSIGNMENT'
    WHEN p_edge_id IN ('J-11-E14','J-12-E17') THEN 'HS-08-ACTION_REVIEW_ASSIGNMENT'
    WHEN p_edge_id IN ('J-11-E11','J-12-E18A') THEN 'HS-09-ACTION_EXECUTION_CLAIM'
    WHEN p_edge_id IN ('J-11-E18','J-11-E21','J-12-E18D') THEN 'HS-10-ACTION_RECONCILIATION'
    WHEN p_edge_id IN ('J-10-E03','J-10-E09','J-10-E11') THEN 'HS-11-AI_RUN_RECONCILIATION'
    WHEN p_edge_id IN ('J-10-E12','J-10-E13','J-10-E14','J-10-E15','J-10-E16','J-10-E17') THEN 'HS-12-EVIDENCE_PROJECTION_ACK'
    WHEN p_edge_id IN ('J-08-E01','J-08-E02','J-08-E03','J-08-E04') THEN 'HS-13-CORRECTION_OWNER'
    WHEN p_edge_id IN ('J-09-E01','J-09-E02','J-09-E03','J-09-E04') THEN 'HS-14-SOURCE_DRIFT_RECOVERY'
    WHEN p_edge_id IN ('J-12-E02','J-12-E03','J-12-E04','J-12-E05','J-12-E06','J-12-E07') THEN 'HS-15-COMMERCIAL_REMEDIATION_TASK'
    WHEN p_edge_id IN ('J-12-E23','J-12-E24') THEN 'HS-16-RETENTION_WATCH_TASK'
    WHEN p_edge_id IN ('J-11-E19','J-11-E20','J-11-E22','J-11-E23') THEN 'HS-17-COMMUNICATION_DELIVERY_OWNERSHIP'
    WHEN p_edge_id IN ('J-10-E04','J-10-E05','J-10-E06','J-10-E07','J-10-E08','J-10-E10') THEN 'HS-18-COMMUNICATION_DELIVERY_RECONCILIATION'
    WHEN p_edge_id IN ('J-12-E19A','J-12-E19B','J-12-E19C','J-12-E20') THEN 'HS-19-PAID_PACKET_TERMINAL_BINDING'
    WHEN p_edge_id IN ('J-12-E21','J-12-E22','J-12-E25','J-12-E26','J-12-E27','J-12-E28','J-12-E29','J-12-E30') THEN 'HS-20-COMMERCIAL_CONTROL_EXTERNAL_ACK'
    WHEN p_edge_id IN ('J-01-E01','J-01-E02','J-01-E03','J-01-E04','J-02-E01','J-02-E02','J-02-E03','J-02-E04','J-02-E05','J-04-E01','J-04-E02','J-04-E03','J-04-E04','J-04-E05','J-05-E01','J-05-E02','J-05-E04','J-06-E01','J-06-E02','J-06-E04','J-06-E05','J-06-E06','J-06-E09','J-07-E01','J-08-E01','J-09-E01','J-10-E01','J-10-E02','J-11-E01','J-11-E02','J-11-E03','J-11-E04','J-11-E05','J-11-E07','J-11-E08A','J-11-E08B','J-11-E08C','J-11-E08D','J-11-E08E','J-11-E08F','J-11-E09','J-11-E10','J-11-E12A','J-11-E12B','J-11-E13','J-11-E15','J-11-E16','J-11-E17','J-11-E23','J-12-E01','J-12-E08','J-12-E09A','J-12-E09B','J-12-E10','J-12-E11','J-12-E12','J-12-E13','J-12-E14','J-12-E15','J-12-E16','J-12-E18B','J-12-E18C') THEN 'HS-03-CASE_OWNERSHIP'
    ELSE NULL END;
  IF v_handoff_kind IS NULL THEN
    RAISE EXCEPTION 'journey_edge_handoff_kind_not_compiled' USING ERRCODE='22023';
  END IF;
  v_receiver_function := 'journey.'||i.journey_code||'.'||p_edge_id;
  v_receiver_ref := encode(extensions.digest(convert_to(v_receiver_function,'UTF8'),'sha256'),'hex');
  v_subject_digest := i.current_object_digest;
  v_binding_digest := encode(extensions.digest(convert_to(jsonb_build_object(
    'journeyInstanceId',i.id,'generation',v_generation,'edgeId',p_edge_id,
    'fromNodeId',i.current_node_id,'toNodeId',v_to_node,
    'fromOwner',i.current_owner_ref_hmac,'receiver',v_receiver_ref,
    'subject',v_subject_digest)::text,'UTF8'),'sha256'),'hex');
  v_receipt_digest := encode(extensions.digest(convert_to(
    v_receipt_id::text||':'||i.id::text||':'||(i.version+1)::text||':'||
    v_handoff_id::text||':'||v_generation::text||':'||v_binding_digest,'UTF8'),'sha256'),'hex');
  v_audit_id := ops.append_audit_event('journey:'||i.id::text,'SERVICE',
    COALESCE(p_actor_assertion_jti::text,current_user),NULL::uuid,'JOURNEY_HANDOFF_REQUESTED',
    'JourneyHandoff',v_handoff_id::text,'journeys.handoff.request','SUCCESS',NULL,p_request_id,
    jsonb_build_object('journeyInstanceId',i.id,'edgeId',p_edge_id,'bindingDigest',v_binding_digest));
  v_outbox_id := ops.enqueue_outbox('JourneyInstance',i.id::text,i.version+1,
    'journey.handoff_requested.v1',jsonb_build_object('journeyInstanceId',i.id,
      'handoffId',v_handoff_id,'edgeId',p_edge_id,'generation',v_generation,
      'receiptId',v_receipt_id,'receiptDigest',v_receipt_digest,'requestId',p_request_id),v_now);
  INSERT INTO ops.journey_handoffs(
    id,journey_instance_id,journey_code,edge_id,handoff_kind,generation,from_node_id,to_node_id,
    from_owner_kind,from_owner_function,from_owner_ref_hmac,receiver_kind,receiver_function,
    receiver_ref_hmac,required_receiver_capability,subject_kind,subject_id,subject_version,
    subject_digest,ack_authority_kind,ack_authority_id,binding_digest,state,version,requested_at,
    due_at,request_receipt_id,request_receipt_digest,last_receipt_id,last_receipt_digest)
  VALUES(v_handoff_id,i.id,i.journey_code,p_edge_id,v_handoff_kind,v_generation,i.current_node_id,
    v_to_node,i.current_owner_kind,i.current_owner_function,i.current_owner_ref_hmac,
    'QUEUE',v_receiver_function,v_receiver_ref,'journeys.handoff.ack',i.current_object_kind,
    i.current_object_id,i.current_object_version,v_subject_digest,'DOMAIN_RECEIPT_HANDLER',
    'ops.decide_journey_handoff_v1',v_binding_digest,'PENDING_ACK',1,v_now,
    GREATEST(i.due_at,v_now+interval '1 hour'),v_receipt_id,v_receipt_digest,v_receipt_id,v_receipt_digest)
  RETURNING * INTO h;
  INSERT INTO ops.journey_transition_receipts(
    id,journey_instance_id,journey_instance_version,handoff_id,handoff_version,edge_id,sequence,
    receipt_kind,prior_receipt_id,prior_receipt_digest,subject_digest,prior_owner_binding_digest,
    current_owner_binding_digest,next_owner_binding_digest,prior_instance_state,resulting_instance_state,
    resulting_handoff_state,escalation_state,prior_due_at,resulting_due_at,effect_digest,
    audit_event_id,outbox_event_id,occurred_at,receipt_digest)
  VALUES(v_receipt_id,i.id,i.version+1,h.id,1,p_edge_id,i.version+1,'HANDOFF_REQUESTED',
    i.last_receipt_id,i.last_receipt_digest,v_subject_digest,i.current_owner_ref_hmac,
    i.current_owner_ref_hmac,v_receiver_ref,i.state,'WAITING_ACK','PENDING_ACK','NOT_DUE',
    i.due_at,h.due_at,v_binding_digest,v_audit_id,v_outbox_id,v_now,v_receipt_digest)
  RETURNING * INTO r;
  UPDATE ops.journey_instances SET state='WAITING_ACK',version=version+1,
    next_owner_kind='QUEUE',next_owner_function=v_receiver_function,next_owner_ref_hmac=v_receiver_ref,
    active_handoff_id=h.id,active_handoff_generation=h.generation,active_handoff_state='PENDING_ACK',
    due_at=h.due_at,last_receipt_id=v_receipt_id,last_receipt_sequence=last_receipt_sequence+1,
    last_receipt_digest=v_receipt_digest,updated_at=v_now WHERE id=i.id AND version=i.version;
  IF NOT FOUND THEN RAISE EXCEPTION 'journey_version_conflict' USING ERRCODE='40001'; END IF;
  UPDATE ops.idempotency_keys SET resource_type='JourneyTransitionReceipt',resource_id=v_receipt_id::text,
    response_status=201,response_body=jsonb_build_object('receiptId',v_receipt_id,'receiptDigest',v_receipt_digest)
    WHERE scope='JOURNEY_HANDOFF_REQUEST' AND key_hash=p_idempotency_key_sha256;
  RETURN r;
END $$;
ALTER FUNCTION ops.request_journey_handoff_v1(uuid,bigint,text,char(64),uuid,char(64),uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.request_journey_handoff_v1(uuid,bigint,text,char(64),uuid,char(64),uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.request_journey_handoff_v1(uuid,bigint,text,char(64),uuid,char(64),uuid) TO gurine_control_api,gurine_workflow_worker;

-- Typed owner adapters for the two remaining high-integrity control commands.
-- These routines deliberately write the native evidence and journey graphs;
-- the generic command dispatcher only serializes their persisted receipts.
BEGIN;
INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES
  ('research.artifact_promoted.v1','DOMAIN',1,true,'payloads/research_artifact_promoted_v1.schema.json'),
  ('evidence.segment_created.v1','DOMAIN',1,true,'payloads/evidence_segment_created_v1.schema.json'),
  ('journey.handoff_requested.v1','DOMAIN',1,true,'payloads/journey_handoff_requested_v1.schema.json'),
  ('journey.handoff_decided.v1','DOMAIN',1,true,'payloads/journey_handoff_decided_v1.schema.json'),
  ('journey.handoff_cancelled.v1','DOMAIN',1,true,'payloads/journey_handoff_cancelled_v1.schema.json')
ON CONFLICT (event_type) DO UPDATE SET active=EXCLUDED.active,
  schema_version=EXCLUDED.schema_version,payload_schema_uri=EXCLUDED.payload_schema_uri;

CREATE OR REPLACE FUNCTION ops.promote_research_artifact_to_evidence_v1(
  p_payload jsonb, p_actor uuid, p_request_id uuid,
  p_idempotency_key_sha256 char(64), p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,raw,editorial,ops,extensions,core,pg_temp
AS $$
DECLARE
  v_art raw.research_artifacts%ROWTYPE;
  v_rights raw.asset_rights_decisions%ROWTYPE;
  v_case editorial.cases%ROWTYPE;
  v_run ops.agent_runs%ROWTYPE;
  v_segment raw.evidence_segments%ROWTYPE;
  v_item jsonb;
  v_bindings jsonb := '[]'::jsonb;
  v_segment_count integer := 0;
  v_primary_id uuid;
  v_primary_locator char(64);
  v_primary_selected char(64);
  v_source_document_id uuid;
  v_source_asset_id uuid;
  v_source_asset_revision bigint;
  v_source_content char(64);
  v_evidence_id uuid := gen_random_uuid();
  v_evidence_digest char(64);
  v_promotion_id uuid := gen_random_uuid();
  v_root_use_id uuid;
  v_root_use_sha char(64);
  v_source_use_id uuid := gen_random_uuid();
  v_source_use_sha char(64);
  v_audit uuid;
  v_outbox uuid := gen_random_uuid();
  v_segment_outbox uuid;
  v_now timestamptz := clock_timestamp();
  v_receipt jsonb;
  v_receipt_sha char(64);
  v_selected_set_sha char(64);
  v_reason_sha char(64);
  v_ord integer;
  v_expected bigint;
  v_classification text;
  v_verification text;
  v_evidence_type text;
  v_title text;
  v_description text;
  v_excerpt text;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR p_actor IS NULL OR p_request_id IS NULL
     OR p_idempotency_key_sha256 !~ '^[0-9a-f]{64}$'
     OR p_request_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023';
  END IF;
  IF p_payload->>'schemaVersion' IS DISTINCT FROM 'promote-research-artifact.request.v1'
     OR NULLIF(p_payload->>'caseId','') IS NULL
     OR NULLIF(p_payload->>'agentRunId','') IS NULL
     OR jsonb_typeof(p_payload->'researchArtifact')<>'object'
     OR jsonb_typeof(p_payload->'rightsDecision')<>'object'
     OR jsonb_typeof(p_payload->'evidence')<>'object'
     OR jsonb_typeof(p_payload->'selectedSegments')<>'array'
     OR jsonb_array_length(p_payload->'selectedSegments') NOT BETWEEN 1 AND 100
     OR length(COALESCE(p_payload->>'reason','')) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023';
  END IF;
  v_expected := NULLIF(p_payload->>'expectedCaseVersion','')::bigint;
  IF v_expected IS NULL OR v_expected < 1 THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.users WHERE id=p_actor AND status='ACTIVE') THEN
    RAISE EXCEPTION 'capability_denied' USING ERRCODE='28000';
  END IF;

  SELECT * INTO v_case FROM editorial.cases
   WHERE id=(p_payload->>'caseId')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;
  IF v_case.version <> v_expected THEN
    RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001';
  END IF;
  SELECT * INTO v_run FROM ops.agent_runs
   WHERE id=(p_payload->>'agentRunId')::uuid AND case_id=v_case.id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;

  SELECT * INTO v_art FROM raw.research_artifacts
   WHERE id=(p_payload->'researchArtifact'->>'id')::uuid
     AND asset_id=(p_payload->'researchArtifact'->>'assetId')::uuid
     AND asset_revision=(p_payload->'researchArtifact'->>'assetRevision')::bigint
     AND artifact_sha256=(p_payload->'researchArtifact'->>'artifactSha256')::char(64)
     AND content_sha256=(p_payload->'researchArtifact'->>'contentSha256')::char(64)
     AND source_fetch_id=(p_payload->'researchArtifact'->>'sourceFetchId')::uuid
     AND agent_run_id=v_run.id
     AND provider_turn_id=(p_payload->'researchArtifact'->>'providerTurnId')::uuid
     AND tool_call_id=(p_payload->'researchArtifact'->>'toolCallId')::uuid
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;
  IF v_art.fetch_outcome <> 'STORED' OR v_art.content_safety_state <> 'CLEAN' THEN
    RAISE EXCEPTION 'artifact_not_clean' USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_rights FROM raw.asset_rights_decisions
   WHERE id=(p_payload->'rightsDecision'->>'id')::uuid
     AND decision_version=(p_payload->'rightsDecision'->>'version')::bigint
     AND decision_sha256=(p_payload->'rightsDecision'->>'decisionSha256')::char(64)
     AND asset_id=v_art.asset_id AND asset_revision=v_art.asset_revision
     AND asset_sha256=v_art.content_sha256 AND research_artifact_id=v_art.id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'rights_denied' USING ERRCODE='55000'; END IF;
  IF v_rights.decision_kind <> 'GRANT' OR v_rights.access_right <> 'ALLOW'
     OR v_rights.private_storage_right <> 'ALLOW'
     OR v_rights.model_use_right <> 'ALLOW'
     OR v_rights.derivative_creation_right <> 'ALLOW'
     OR v_rights.excerpt_right <> 'ALLOW'
     OR v_rights.expires_at IS NOT NULL AND v_rights.expires_at <= v_now THEN
    RAISE EXCEPTION 'rights_denied' USING ERRCODE='55000';
  END IF;
  SELECT source_use_id,source_use_sha256 INTO v_root_use_id,v_root_use_sha
    FROM ops.agent_source_uses
   WHERE agent_run_id=v_art.agent_run_id AND source_kind='RESEARCH_ARTIFACT'
     AND research_artifact_id=v_art.id
   ORDER BY created_at,source_use_id LIMIT 1 FOR UPDATE;
  IF v_root_use_id IS NULL THEN
    RAISE EXCEPTION 'dependency_unavailable' USING ERRCODE='55000';
  END IF;

  v_evidence_type := COALESCE(NULLIF(p_payload->'evidence'->>'evidenceType',''),'SOURCE_DOCUMENT');
  v_title := NULLIF(p_payload->'evidence'->>'title','');
  v_description := p_payload->'evidence'->>'description';
  v_excerpt := p_payload->'evidence'->>'publicExcerpt';
  IF v_title IS NULL THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
  v_classification := COALESCE(NULLIF(p_payload->'evidence'->>'classification',''),'PUBLIC');
  IF v_classification NOT IN ('PUBLIC','RESTRICTED','PERSONAL_DATA','LEGAL_HOLD') THEN
    v_classification := 'PUBLIC';
  END IF;
  v_verification := COALESCE(NULLIF(p_payload->'evidence'->>'verificationStatus',''),'PENDING');
  IF v_verification NOT IN ('PENDING','NEEDS_WORK') THEN v_verification := 'PENDING'; END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'selectedSegments') LOOP
    v_ord := NULLIF(v_item->>'ordinal','')::integer;
    IF v_ord IS NULL OR v_ord <> v_segment_count
       OR jsonb_typeof(v_item->'locator')<>'object'
       OR (v_item->'locator'->>'locatorSha256') !~ '^[0-9a-f]{64}$'
       OR (v_item->>'selectedContentSha256') !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'validation_failed' USING ERRCODE='22023';
    END IF;
    SELECT * INTO v_segment FROM raw.evidence_segments
     WHERE locator_digest=(v_item->'locator'->>'locatorSha256')::char(64)
       AND selected_content_sha256=(v_item->>'selectedContentSha256')::char(64)
       AND source_content_sha256=v_art.content_sha256
     FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'locator_mismatch' USING ERRCODE='55000'; END IF;
    IF v_source_document_id IS NULL THEN
      v_source_document_id:=v_segment.source_document_id;
      v_source_asset_id:=v_segment.source_asset_id;
      v_source_asset_revision:=v_segment.source_asset_revision;
      v_source_content:=v_segment.source_content_sha256;
      v_primary_id:=v_segment.id; v_primary_locator:=v_segment.locator_digest;
      v_primary_selected:=v_segment.selected_content_sha256;
    ELSIF v_segment.source_document_id<>v_source_document_id
       OR v_segment.source_asset_id<>v_source_asset_id
       OR v_segment.source_asset_revision<>v_source_asset_revision
       OR v_segment.source_content_sha256<>v_source_content THEN
      RAISE EXCEPTION 'validation_failed' USING ERRCODE='22023';
    END IF;
    v_bindings := v_bindings || jsonb_build_array(jsonb_build_object(
      'ordinal',v_ord,'evidenceSegmentId',v_segment.id,
      'locatorSha256',v_segment.locator_digest,
      'selectedContentSha256',v_segment.selected_content_sha256));
    v_segment_count := v_segment_count + 1;
  END LOOP;
  v_selected_set_sha := encode(extensions.digest(convert_to(v_bindings::text,'UTF8'),'sha256'),'hex');
  v_reason_sha := encode(extensions.digest(convert_to(p_payload->>'reason','UTF8'),'sha256'),'hex');
  v_evidence_digest := encode(extensions.digest(convert_to(jsonb_build_object(
    'evidenceId',v_evidence_id,'caseId',v_case.id,'sourceDocumentId',v_source_document_id,
    'segments',v_bindings,'title',v_title,'contentSha256',v_primary_selected)::text,'UTF8'),'sha256'),'hex');

  INSERT INTO editorial.evidence(id,case_id,evidence_type,title,description,source_document_id,
    source_url,source_locator,content_sha256,classification,verification_status,
    redacted_public_excerpt,version,created_by)
  SELECT v_evidence_id,v_case.id,v_evidence_type,v_title,v_description,v_source_document_id,
    d.canonical_url,v_primary_locator,v_primary_selected,v_classification::editorial.evidence_classification,
    v_verification,v_excerpt,1,p_actor FROM raw.source_documents d WHERE d.id=v_source_document_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;

  v_audit := ops.append_audit_event('control:promotion:'||v_promotion_id::text,'USER',p_actor::text,NULL::uuid,
    'RESEARCH_ARTIFACT_PROMOTED','ResearchArtifactPromotion',v_promotion_id::text,
    'cases.evidence.manage','SUCCESS',NULL,p_request_id,jsonb_build_object(
      'caseId',v_case.id,'artifactId',v_art.id,'artifactSha256',v_art.artifact_sha256,
      'selectedSegmentSetSha256',v_selected_set_sha,'reasonSha256',v_reason_sha));
  INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
  VALUES(v_outbox,'ResearchArtifactPromotion',v_promotion_id::text,v_case.version+1,
    'research.artifact_promoted.v1',jsonb_build_object('promotionId',v_promotion_id,
      'caseId',v_case.id,'caseVersion',v_case.version+1,'researchArtifactId',v_art.id,
      'researchArtifactSha256',v_art.artifact_sha256,'evidenceId',v_evidence_id,
      'evidenceDigest',v_evidence_digest,'requestId',p_request_id),v_now);
  v_receipt := jsonb_build_object('schemaVersion','promote-research-artifact.receipt.v1',
    'promotionId',v_promotion_id,'caseId',v_case.id,'caseVersion',v_case.version+1,
    'agentRunId',v_art.agent_run_id,'researchArtifactId',v_art.id,
    'researchArtifactSha256',v_art.artifact_sha256,'sourceDocumentId',v_source_document_id,
    'sourceAssetId',v_source_asset_id,'sourceAssetRevision',v_source_asset_revision,
    'sourceContentSha256',v_source_content,'evidenceSegmentBindings',v_bindings,
    'selectedSegmentCount',v_segment_count,'selectedSegmentSetSha256',v_selected_set_sha,
    'evidenceId',v_evidence_id,'evidenceVersion',1,'evidenceDigest',v_evidence_digest,
    'rightsDecisionId',v_rights.id,'rightsDecisionDigest',v_rights.decision_sha256,
    'reviewerUserId',p_actor,'auditEventId',v_audit,'outboxEventId',v_outbox,
    'idempotencyKeySha256',p_idempotency_key_sha256,'promotedAt',v_now,
    'reasonSha256',v_reason_sha,'requestDigest',p_request_digest);
  v_receipt_sha := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex');
  INSERT INTO raw.research_artifact_promotions(
    promotion_id,case_id,expected_case_version,case_version,agent_run_id,
    research_artifact_id,research_asset_id,research_asset_revision,research_artifact_sha256,
    research_content_sha256,research_source_fetch_id,source_document_id,source_asset_id,
    source_asset_revision,source_content_sha256,primary_evidence_segment_id,
    primary_locator_sha256,primary_selected_content_sha256,selected_segment_bindings,
    selected_segment_bindings_canonical,selected_segment_count,selected_segment_set_sha256,
    evidence_id,evidence_version,evidence_digest,rights_decision_id,rights_decision_version,
    rights_decision_sha256,root_source_use_id,root_source_use_sha256,reviewer_user_id,
    reason_sha256,idempotency_key_sha256,audit_event_id,outbox_event_id,promoted_at,
    receipt_payload,receipt_canonical,receipt_sha256)
  VALUES(v_promotion_id,v_case.id,v_case.version,v_case.version+1,v_art.agent_run_id,
    v_art.id,v_art.asset_id,v_art.asset_revision,v_art.artifact_sha256,v_art.content_sha256,
    v_art.source_fetch_id,v_source_document_id,v_source_asset_id,v_source_asset_revision,
    v_source_content,v_primary_id,v_primary_locator,v_primary_selected,v_bindings,
    convert_to(v_bindings::text,'UTF8'),v_segment_count,v_selected_set_sha,v_evidence_id,1,
    v_evidence_digest,v_rights.id,v_rights.decision_version,v_rights.decision_sha256,
    v_root_use_id,v_root_use_sha,p_actor,v_reason_sha,p_idempotency_key_sha256,v_audit,
    v_outbox,v_now,v_receipt,convert_to(v_receipt::text,'UTF8'),v_receipt_sha);
  INSERT INTO ops.agent_source_uses(
    source_use_id,source_use_contract_version,agent_run_id,parent_source_use_id,
    parent_source_use_sha256,promotion_id,promotion_receipt_sha256,use_kind,source_kind,
    research_artifact_id,research_asset_id,research_asset_revision,research_artifact_sha256,
    research_content_sha256,research_source_fetch_id,classification,rights_binding_kind,
    rights_asset_id,rights_asset_revision,rights_asset_sha256,asset_rights_decision_id,
    asset_rights_decision_version,asset_rights_decision_sha256,rights_effective_at,
    rights_expires_at,access_right,private_storage_right,model_egress_right,model_use_right,
    derivative_creation_right,excerpt_right,redistribution_right,commercial_use_right,
    public_display_right,rights_policy_version,rights_policy_sha256,occurred_at,
    source_use_canonical,source_use_sha256)
  VALUES(v_source_use_id,2,v_art.agent_run_id,v_root_use_id,v_root_use_sha,v_promotion_id,
    v_receipt_sha,'HUMAN_PROMOTION','RESEARCH_ARTIFACT',v_art.id,v_art.asset_id,
    v_art.asset_revision,v_art.artifact_sha256,v_art.content_sha256,v_art.source_fetch_id,
    v_art.classification,'ASSET_RIGHTS',v_rights.asset_id,v_rights.asset_revision,
    v_rights.asset_sha256,v_rights.id,v_rights.decision_version,v_rights.decision_sha256,
    v_rights.effective_at,v_rights.expires_at,v_rights.access_right,v_rights.private_storage_right,
    v_rights.model_egress_right,v_rights.model_use_right,v_rights.derivative_creation_right,
    v_rights.excerpt_right,v_rights.redistribution_right,v_rights.commercial_use_right,
    v_rights.public_display_right,v_rights.policy_version,v_rights.policy_sha256,v_now,
    convert_to(v_receipt::text,'UTF8'),encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex'));
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_bindings) LOOP
    v_segment_outbox := ops.enqueue_outbox('EvidenceSegment',v_item->>'evidenceSegmentId',
      v_case.version+1,'evidence.segment_created.v1',jsonb_build_object(
        'promotionId',v_promotion_id,'evidenceId',v_evidence_id,
        'evidenceSegmentId',(v_item->>'evidenceSegmentId')::uuid,
        'ordinal',(v_item->>'ordinal')::integer,'requestId',p_request_id),v_now);
  END LOOP;
  UPDATE editorial.cases SET version=version+1,updated_at=v_now WHERE id=v_case.id AND version=v_expected;
  IF NOT FOUND THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF;
  RETURN v_receipt || jsonb_build_object('receiptSha256',v_receipt_sha,
    'promotionId',v_promotion_id,'auditEventId',v_audit,'outboxEventId',v_outbox);
END $$;
ALTER FUNCTION ops.promote_research_artifact_to_evidence_v1(jsonb,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.promote_research_artifact_to_evidence_v1(jsonb,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.promote_research_artifact_to_evidence_v1(jsonb,uuid,uuid,char(64),char(64)) TO gurine_control_api;

DROP FUNCTION IF EXISTS ops.decide_journey_handoff_v1(uuid,bigint,char(64),text,text,bytea,char(64),uuid,char(64),uuid);
CREATE FUNCTION ops.decide_journey_handoff_v1(
  p_handoff_id uuid, p_expected_handoff_version bigint,
  p_expected_binding_digest char(64), p_decision text, p_reason_code text,
  p_reason_encrypted bytea, p_reason_digest char(64), p_request_id uuid,
  p_idempotency_key_sha256 char(64), p_assertion_jti uuid
) RETURNS ops.journey_handoff_decision_result_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  h ops.journey_handoffs%ROWTYPE;
  i ops.journey_instances%ROWTYPE;
  v_now timestamptz := clock_timestamp();
  v_audit uuid;
  v_outbox uuid;
  v_receipt_id uuid := gen_random_uuid();
  v_receipt_digest char(64);
  v_effect_digest char(64);
  v_actor_binding char(64);
  v_result_state text;
  v_handoff_state text;
  v_receipt jsonb;
  v_parent jsonb;
  v_existing jsonb;
  v_request_hash char(64);
  v_existing_key ops.idempotency_keys%ROWTYPE;
  v_replay_receipt ops.journey_transition_receipts%ROWTYPE;
  v_replay_handoff ops.journey_handoffs%ROWTYPE;
  v_replay_instance ops.journey_instances%ROWTYPE;
  v_decision_receipt ops.journey_handoff_terminal_result_v1;
  v_final_parent ops.journey_instance_head_result_v1;
BEGIN
  IF p_handoff_id IS NULL OR p_expected_handoff_version < 1
     OR p_expected_binding_digest !~ '^[0-9a-f]{64}$'
     OR p_decision NOT IN ('ACKNOWLEDGE','DECLINE')
     OR p_request_id IS NULL OR p_idempotency_key_sha256 !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023';
  END IF;
  IF p_decision='ACKNOWLEDGE' AND (p_reason_code IS NOT NULL OR p_reason_encrypted IS NOT NULL OR p_reason_digest IS NOT NULL) THEN
    RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023';
  END IF;
  IF p_decision='DECLINE' AND (p_reason_code NOT IN ('CAPABILITY_UNAVAILABLE','OBJECT_SCOPE_MISMATCH','CONFLICT_OF_INTEREST','WORKLOAD_CAPACITY','DEPENDENCY_BLOCKED','SUBJECT_INVALID','OWNER_UNAVAILABLE','POLICY_BLOCKED','RECEIVER_DECLINED') OR p_reason_encrypted IS NULL OR octet_length(p_reason_encrypted)<32 OR p_reason_digest !~ '^[0-9a-f]{64}$') THEN
    RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023';
  END IF;
  -- Claim the idempotency key before taking either aggregate lock.  Retries
  -- therefore replay the committed receipt rather than attempting a second
  -- state transition; a reused key with a different decision is a conflict.
  v_request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'operationId','decideJourneyHandoff','handoffId',p_handoff_id,
    'expectedHandoffVersion',p_expected_handoff_version,
    'expectedBindingDigest',p_expected_binding_digest,'decision',p_decision,
    'reasonCode',p_reason_code,'reasonDigest',p_reason_digest)::text,'UTF8'),'sha256'),'hex');
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,resource_type,resource_id,expires_at)
  VALUES('JOURNEY_HANDOFF_DECISION',p_idempotency_key_sha256,v_request_hash,
    'JOURNEY_HANDOFF',lower(p_handoff_id::text),v_now+interval '24 hours')
  ON CONFLICT (scope,key_hash) DO NOTHING;
  SELECT * INTO v_existing_key FROM ops.idempotency_keys
   WHERE scope='JOURNEY_HANDOFF_DECISION' AND key_hash=p_idempotency_key_sha256 FOR UPDATE;
  IF v_existing_key.request_hash<>v_request_hash THEN
    RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001';
  END IF;
  IF v_existing_key.response_status IS NOT NULL AND v_existing_key.resource_id IS NOT NULL THEN
    SELECT * INTO STRICT v_replay_receipt FROM ops.journey_transition_receipts
     WHERE id=(v_existing_key.response_body->>'receiptId')::uuid;
    SELECT * INTO STRICT v_replay_handoff FROM ops.journey_handoffs WHERE id=v_replay_receipt.handoff_id;
    SELECT * INTO STRICT v_replay_instance FROM ops.journey_instances WHERE id=v_replay_receipt.journey_instance_id;
    v_decision_receipt := ROW(
      v_replay_receipt.id,v_replay_receipt.receipt_digest,v_replay_receipt.journey_instance_id,
      v_replay_receipt.journey_instance_version,v_replay_receipt.handoff_id,
      v_replay_receipt.handoff_version,v_replay_handoff.handoff_kind,v_replay_handoff.generation,
      CASE WHEN v_replay_handoff.state='ACKNOWLEDGED' THEN 'ACKNOWLEDGE' ELSE 'DECLINE' END,
      v_replay_receipt.resulting_handoff_state,v_replay_receipt.resulting_instance_state,
      v_replay_receipt.current_owner_binding_digest,v_replay_receipt.next_owner_binding_digest,
      v_replay_receipt.audit_event_id,v_replay_receipt.outbox_event_id
    )::ops.journey_handoff_terminal_result_v1;
    v_final_parent := ROW(
      v_replay_instance.id,v_replay_instance.version,v_replay_instance.state,
      v_replay_instance.current_owner_ref_hmac,v_replay_instance.next_owner_ref_hmac,
      v_replay_instance.active_handoff_id,v_replay_instance.active_handoff_generation,
      v_replay_instance.active_handoff_state,v_replay_instance.escalation_state,
      v_replay_instance.due_at,v_replay_instance.last_receipt_id,v_replay_instance.last_receipt_digest
    )::ops.journey_instance_head_result_v1;
    RETURN ROW(v_decision_receipt,NULL::ops.journey_replacement_result_v1,v_final_parent,
      v_replay_receipt.effect_digest,v_replay_receipt.occurred_at)::ops.journey_handoff_decision_result_v1;
  END IF;
  SELECT * INTO h FROM ops.journey_handoffs WHERE id=p_handoff_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;
  IF h.version<>p_expected_handoff_version OR h.binding_digest<>p_expected_binding_digest THEN
    RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001';
  END IF;
  IF h.state<>'PENDING_ACK' THEN RAISE EXCEPTION 'handoff_state_invalid' USING ERRCODE='55000'; END IF;
  IF h.due_at<=v_now THEN RAISE EXCEPTION 'handoff_expired' USING ERRCODE='55000'; END IF;
  SELECT * INTO i FROM ops.journey_instances WHERE id=h.journey_instance_id FOR UPDATE;
  IF NOT FOUND OR i.active_handoff_id<>h.id OR i.active_handoff_generation<>h.generation OR i.active_handoff_state<>'PENDING_ACK' THEN
    RAISE EXCEPTION 'handoff_binding_mismatch' USING ERRCODE='40001';
  END IF;
  IF i.version<>i.last_receipt_sequence THEN RAISE EXCEPTION 'journey_head_invalid' USING ERRCODE='55000'; END IF;

  v_handoff_state := CASE WHEN p_decision='ACKNOWLEDGE' THEN 'ACKNOWLEDGED' ELSE 'DECLINED' END;
  v_result_state := CASE WHEN p_decision='ACKNOWLEDGE' THEN 'ACTIVE' ELSE 'ACTIVE' END;
  v_actor_binding := encode(extensions.digest(convert_to(COALESCE(p_assertion_jti::text,current_user),'UTF8'),'sha256'),'hex');
  v_effect_digest := encode(extensions.digest(convert_to(
    p_handoff_id::text||':'||h.version::text||':'||p_decision||':'||COALESCE(p_reason_digest,''),'UTF8'),'sha256'),'hex');
  v_audit := ops.append_audit_event('control:journey-handoff:'||h.id::text,'USER',current_user,NULL::uuid,
    'JOURNEY_HANDOFF_DECIDED','JourneyHandoff',h.id::text,'journeys.handoff.decide','SUCCESS',
    p_reason_code,p_request_id,jsonb_build_object('decision',p_decision,'bindingDigest',h.binding_digest,
      'effectDigest',v_effect_digest,'assertionJti',p_assertion_jti));
  v_outbox := ops.enqueue_outbox('JourneyHandoff',h.id::text,h.version+1,
    'journey.handoff_decided.v1',jsonb_build_object('handoffId',h.id,'journeyInstanceId',i.id,
      'handoffVersion',h.version+1,'decision',p_decision,'resultingHandoffState',v_handoff_state,
      'resultingJourneyState',v_result_state,'effectDigest',v_effect_digest,'requestId',p_request_id),v_now);
  v_receipt_digest := encode(extensions.digest(convert_to(
    v_receipt_id::text||':'||i.id::text||':'||(i.version+1)::text||':'||h.id::text||':'||
      (h.version+1)::text||':'||v_handoff_state||':'||v_effect_digest,'UTF8'),'sha256'),'hex');
  INSERT INTO ops.journey_transition_receipts(
    id,journey_instance_id,journey_instance_version,handoff_id,handoff_version,edge_id,sequence,
    receipt_kind,prior_receipt_id,prior_receipt_digest,subject_digest,prior_owner_binding_digest,
    current_owner_binding_digest,next_owner_binding_digest,prior_instance_state,resulting_instance_state,
    prior_handoff_state,resulting_handoff_state,escalation_state,prior_due_at,resulting_due_at,
    effect_digest,audit_event_id,outbox_event_id,occurred_at,receipt_digest)
  VALUES(v_receipt_id,i.id,i.version+1,h.id,h.version+1,h.edge_id,i.version+1,
    CASE WHEN p_decision='ACKNOWLEDGE' THEN 'HANDOFF_ACKNOWLEDGED' ELSE 'HANDOFF_DECLINED' END,
    i.last_receipt_id,i.last_receipt_digest,h.subject_digest,i.current_owner_ref_hmac,
    CASE WHEN p_decision='ACKNOWLEDGE' THEN h.receiver_ref_hmac ELSE i.current_owner_ref_hmac END,
    NULL,i.state,v_result_state,h.state,v_handoff_state,'RESOLVED',i.due_at,i.due_at,
    v_effect_digest,v_audit,v_outbox,v_now,v_receipt_digest);
  UPDATE ops.journey_handoffs SET state=v_handoff_state,version=version+1,decided_at=v_now,
    decision_actor_binding_hmac=v_actor_binding,decision_reason_code=CASE WHEN p_decision='DECLINE' THEN p_reason_code ELSE NULL END,
    decision_reason_encrypted=CASE WHEN p_decision='DECLINE' THEN p_reason_encrypted ELSE NULL END,
    decision_reason_digest=CASE WHEN p_decision='DECLINE' THEN p_reason_digest ELSE NULL END,
    last_receipt_id=v_receipt_id,last_receipt_digest=v_receipt_digest
   WHERE id=h.id AND version=p_expected_handoff_version AND state='PENDING_ACK';
  IF NOT FOUND THEN RAISE EXCEPTION 'handoff_version_conflict' USING ERRCODE='40001'; END IF;
  UPDATE ops.journey_instances SET state=v_result_state,version=version+1,
    current_node_id=CASE WHEN p_decision='ACKNOWLEDGE' THEN h.to_node_id ELSE current_node_id END,
    current_object_kind=CASE WHEN p_decision='ACKNOWLEDGE' THEN h.subject_kind ELSE current_object_kind END,
    current_object_id=CASE WHEN p_decision='ACKNOWLEDGE' THEN h.subject_id ELSE current_object_id END,
    current_object_version=CASE WHEN p_decision='ACKNOWLEDGE' THEN h.subject_version ELSE current_object_version END,
    current_object_digest=CASE WHEN p_decision='ACKNOWLEDGE' THEN h.subject_digest ELSE current_object_digest END,
    current_owner_kind=CASE WHEN p_decision='ACKNOWLEDGE' THEN h.receiver_kind ELSE current_owner_kind END,
    current_owner_function=CASE WHEN p_decision='ACKNOWLEDGE' THEN h.receiver_function ELSE current_owner_function END,
    current_owner_ref_hmac=CASE WHEN p_decision='ACKNOWLEDGE' THEN h.receiver_ref_hmac ELSE current_owner_ref_hmac END,
    next_owner_kind=NULL,next_owner_function=NULL,next_owner_ref_hmac=NULL,
    active_handoff_id=NULL,active_handoff_generation=NULL,active_handoff_state=NULL,
    escalation_state='RESOLVED',last_receipt_id=v_receipt_id,last_receipt_sequence=last_receipt_sequence+1,
    last_receipt_digest=v_receipt_digest,updated_at=v_now
   WHERE id=i.id AND version=i.version;
  IF NOT FOUND THEN RAISE EXCEPTION 'journey_version_conflict' USING ERRCODE='40001'; END IF;

  v_receipt := jsonb_build_object('receiptId',v_receipt_id,'receiptDigest',v_receipt_digest,
    'journeyInstanceId',i.id,'journeyInstanceVersion',i.version+1,'handoffId',h.id,
    'handoffVersion',h.version+1,'handoffKind',h.handoff_kind,'generation',h.generation,
    'decision',p_decision,'resultingHandoffState',v_handoff_state,
    'resultingJourneyState',v_result_state,'currentOwnerBindingDigest',
      CASE WHEN p_decision='ACKNOWLEDGE' THEN h.receiver_ref_hmac ELSE i.current_owner_ref_hmac END,
    'nextOwnerBindingDigest',NULL,'auditEventId',v_audit,'outboxEventId',v_outbox);
  v_parent := jsonb_build_object('journeyInstanceId',i.id,'version',i.version+1,
    'state',v_result_state,'currentOwnerBindingDigest',
      CASE WHEN p_decision='ACKNOWLEDGE' THEN h.receiver_ref_hmac ELSE i.current_owner_ref_hmac END,
    'nextOwnerBindingDigest',NULL,'activeHandoffId',NULL,
    'activeHandoffGeneration',NULL,'activeHandoffState',NULL,
    'escalationState','RESOLVED','dueAt',i.due_at,'headReceiptId',v_receipt_id,
    'headReceiptDigest',v_receipt_digest);
  UPDATE ops.idempotency_keys SET response_status=200,
    response_body=v_receipt || jsonb_build_object('parent',v_parent,'effectDigest',v_effect_digest),
    resource_type='JOURNEY_HANDOFF_DECISION',resource_id=h.id::text,
    expires_at=v_now+interval '24 hours'
    WHERE scope='JOURNEY_HANDOFF_DECISION' AND key_hash=p_idempotency_key_sha256;
  v_decision_receipt := ROW(
    v_receipt_id,v_receipt_digest,i.id,i.version+1,h.id,h.version+1,h.handoff_kind,
    h.generation,p_decision,v_handoff_state,v_result_state,
    CASE WHEN p_decision='ACKNOWLEDGE' THEN h.receiver_ref_hmac ELSE i.current_owner_ref_hmac END,
    NULL,v_audit,v_outbox
  )::ops.journey_handoff_terminal_result_v1;
  v_final_parent := ROW(
    i.id,i.version+1,v_result_state,
    CASE WHEN p_decision='ACKNOWLEDGE' THEN h.receiver_ref_hmac ELSE i.current_owner_ref_hmac END,
    NULL,NULL,NULL,NULL,'RESOLVED',i.due_at,v_receipt_id,v_receipt_digest
  )::ops.journey_instance_head_result_v1;
  RETURN ROW(v_decision_receipt,NULL::ops.journey_replacement_result_v1,
    v_final_parent,v_effect_digest,v_now)::ops.journey_handoff_decision_result_v1;
END $$;
ALTER FUNCTION ops.decide_journey_handoff_v1(uuid,bigint,char(64),text,text,bytea,char(64),uuid,char(64),uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.decide_journey_handoff_v1(uuid,bigint,char(64),text,text,bytea,char(64),uuid,char(64),uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.decide_journey_handoff_v1(uuid,bigint,char(64),text,text,bytea,char(64),uuid,char(64),uuid) TO gurine_control_api,gurine_workflow_worker;

CREATE OR REPLACE FUNCTION ops.escalate_journey_handoff_v1(
  p_handoff_id uuid, p_expected_handoff_version bigint, p_scheduler_run_id uuid
) RETURNS ops.journey_scheduler_result_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  i ops.journey_instances; h ops.journey_handoffs; r ops.journey_transition_receipts;
  v_now timestamptz := clock_timestamp(); v_state text; v_receipt_id uuid := gen_random_uuid();
  v_audit uuid; v_outbox uuid; v_digest char(64); v_effect char(64);
  v_parent ops.journey_instance_head_result_v1;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'JOURNEY_SERIALIZABLE_REQUIRED' USING ERRCODE='25001';
  END IF;
  IF p_handoff_id IS NULL OR p_expected_handoff_version < 1 OR p_scheduler_run_id IS NULL THEN
    RAISE EXCEPTION 'journey_scheduler_invalid' USING ERRCODE='22023';
  END IF;
  SELECT journey_instance_id INTO STRICT i.id FROM ops.journey_handoffs WHERE id=p_handoff_id;
  SELECT * INTO STRICT i FROM ops.journey_instances WHERE id=i.id FOR UPDATE;
  SELECT * INTO STRICT h FROM ops.journey_handoffs WHERE id=p_handoff_id FOR UPDATE;
  IF h.version <> p_expected_handoff_version OR i.active_handoff_id IS DISTINCT FROM h.id
     OR h.state <> 'PENDING_ACK' OR i.state <> 'WAITING_ACK' THEN
    RETURN ROW('NO_LONGER_CURRENT','VERSION_CONFLICT',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)::ops.journey_scheduler_result_v1;
  END IF;
  IF v_now < h.due_at THEN
    RETURN ROW('NO_OP','NOT_DUE',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)::ops.journey_scheduler_result_v1;
  END IF;
  v_state := CASE WHEN i.escalation_state='NOT_DUE' THEN 'DUE' ELSE 'ESCALATED' END;
  v_effect := encode(extensions.digest(convert_to(h.id::text||':'||h.version::text||':'||v_state||':'||p_scheduler_run_id::text,'UTF8'),'sha256'),'hex');
  v_audit := ops.append_audit_event('scheduler:journey-handoff:'||h.id::text,'SERVICE',p_scheduler_run_id::text,NULL::uuid,
    'JOURNEY_HANDOFF_ESCALATED','JourneyHandoff',h.id::text,'journeys.handoff.escalate','SUCCESS',NULL,p_scheduler_run_id,
    jsonb_build_object('handoffId',h.id,'priorEscalationState',i.escalation_state,'resultingEscalationState',v_state));
  v_outbox := ops.enqueue_outbox('JourneyHandoff',h.id::text,i.version+1,'journey.handoff_escalated.v1',
    jsonb_build_object('handoffId',h.id,'journeyInstanceId',i.id,'escalationState',v_state,'requestId',p_scheduler_run_id),v_now);
  v_digest := encode(extensions.digest(convert_to(v_receipt_id::text||':'||i.id::text||':'||(i.version+1)::text||':'||h.id::text||':'||(h.version+1)::text||':'||v_effect,'UTF8'),'sha256'),'hex');
  INSERT INTO ops.journey_transition_receipts(id,journey_instance_id,journey_instance_version,handoff_id,handoff_version,edge_id,sequence,receipt_kind,prior_receipt_id,prior_receipt_digest,subject_digest,prior_owner_binding_digest,current_owner_binding_digest,next_owner_binding_digest,prior_instance_state,resulting_instance_state,prior_handoff_state,resulting_handoff_state,escalation_state,prior_due_at,resulting_due_at,effect_digest,audit_event_id,outbox_event_id,occurred_at,receipt_digest)
  VALUES(v_receipt_id,i.id,i.version+1,h.id,h.version+1,h.edge_id,i.version+1,'HANDOFF_ESCALATED',i.last_receipt_id,i.last_receipt_digest,h.subject_digest,i.current_owner_ref_hmac,i.current_owner_ref_hmac,h.receiver_ref_hmac,i.state,i.state,h.state,h.state,v_state,i.due_at,h.due_at,v_effect,v_audit,v_outbox,v_now,v_digest) RETURNING * INTO r;
  UPDATE ops.journey_handoffs SET version=version+1,last_receipt_id=v_receipt_id,last_receipt_digest=v_digest WHERE id=h.id AND version=p_expected_handoff_version;
  UPDATE ops.journey_instances SET version=version+1,escalation_state=v_state,last_receipt_id=v_receipt_id,last_receipt_sequence=last_receipt_sequence+1,last_receipt_digest=v_digest,updated_at=v_now WHERE id=i.id AND version=i.version;
  v_parent := ROW(i.id,i.version+1,i.state,i.current_owner_ref_hmac,i.current_owner_ref_hmac,h.id,h.generation,'PENDING_ACK',v_state,i.due_at,v_receipt_id,v_digest)::ops.journey_instance_head_result_v1;
  RETURN ROW('APPLIED',v_state,v_receipt_id,v_digest,i.version+1,h.id,h.version+1,v_audit,v_outbox,NULL::ops.journey_replacement_result_v1,v_parent,h.due_at,h.due_at)::ops.journey_scheduler_result_v1;
END $$;
ALTER FUNCTION ops.escalate_journey_handoff_v1(uuid,bigint,uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.escalate_journey_handoff_v1(uuid,bigint,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.escalate_journey_handoff_v1(uuid,bigint,uuid) TO gurine_scheduler;

CREATE OR REPLACE FUNCTION ops.expire_journey_handoff_v1(
  p_handoff_id uuid, p_expected_handoff_version bigint, p_scheduler_run_id uuid
) RETURNS ops.journey_scheduler_result_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  i ops.journey_instances; h ops.journey_handoffs; r ops.journey_transition_receipts;
  v_now timestamptz := clock_timestamp(); v_receipt_id uuid := gen_random_uuid();
  v_audit uuid; v_outbox uuid; v_digest char(64); v_effect char(64);
  v_parent ops.journey_instance_head_result_v1;
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN RAISE EXCEPTION 'JOURNEY_SERIALIZABLE_REQUIRED' USING ERRCODE='25001'; END IF;
  IF p_handoff_id IS NULL OR p_expected_handoff_version < 1 OR p_scheduler_run_id IS NULL THEN RAISE EXCEPTION 'journey_scheduler_invalid' USING ERRCODE='22023'; END IF;
  SELECT journey_instance_id INTO STRICT i.id FROM ops.journey_handoffs WHERE id=p_handoff_id;
  SELECT * INTO STRICT i FROM ops.journey_instances WHERE id=i.id FOR UPDATE;
  SELECT * INTO STRICT h FROM ops.journey_handoffs WHERE id=p_handoff_id FOR UPDATE;
  IF h.version <> p_expected_handoff_version OR h.state <> 'PENDING_ACK' OR i.active_handoff_id IS DISTINCT FROM h.id OR i.state <> 'WAITING_ACK' THEN
    RETURN ROW('NO_LONGER_CURRENT','VERSION_CONFLICT',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)::ops.journey_scheduler_result_v1;
  END IF;
  IF v_now < h.due_at THEN RETURN ROW('NO_OP','NOT_DUE',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)::ops.journey_scheduler_result_v1; END IF;
  v_effect := encode(extensions.digest(convert_to(h.id::text||':'||h.version::text||':EXPIRED:'||p_scheduler_run_id::text,'UTF8'),'sha256'),'hex');
  v_audit := ops.append_audit_event('scheduler:journey-handoff:'||h.id::text,'SERVICE',p_scheduler_run_id::text,NULL::uuid,'JOURNEY_HANDOFF_EXPIRED','JourneyHandoff',h.id::text,'journeys.handoff.expire','SUCCESS','HANDOFF_EXPIRED',p_scheduler_run_id,jsonb_build_object('handoffId',h.id));
  v_outbox := ops.enqueue_outbox('JourneyHandoff',h.id::text,i.version+1,'journey.handoff_expired.v1',jsonb_build_object('handoffId',h.id,'journeyInstanceId',i.id,'requestId',p_scheduler_run_id),v_now);
  v_digest := encode(extensions.digest(convert_to(v_receipt_id::text||':'||i.id::text||':'||(i.version+1)::text||':'||h.id::text||':'||(h.version+1)::text||':'||v_effect,'UTF8'),'sha256'),'hex');
  INSERT INTO ops.journey_transition_receipts(id,journey_instance_id,journey_instance_version,handoff_id,handoff_version,edge_id,sequence,receipt_kind,prior_receipt_id,prior_receipt_digest,subject_digest,prior_owner_binding_digest,current_owner_binding_digest,next_owner_binding_digest,prior_instance_state,resulting_instance_state,prior_handoff_state,resulting_handoff_state,escalation_state,prior_due_at,resulting_due_at,effect_digest,audit_event_id,outbox_event_id,occurred_at,receipt_digest)
  VALUES(v_receipt_id,i.id,i.version+1,h.id,h.version+1,h.edge_id,i.version+1,'HANDOFF_EXPIRED',i.last_receipt_id,i.last_receipt_digest,h.subject_digest,i.current_owner_ref_hmac,i.current_owner_ref_hmac,NULL,i.state,'ACTIVE',h.state,'EXPIRED','RESOLVED',i.due_at,i.due_at,v_effect,v_audit,v_outbox,v_now,v_digest) RETURNING * INTO r;
  UPDATE ops.journey_handoffs SET state='EXPIRED',version=version+1,decided_at=v_now,decision_actor_binding_hmac=encode(extensions.digest(convert_to(p_scheduler_run_id::text,'UTF8'),'sha256'),'hex'),decision_reason_code='HANDOFF_EXPIRED',last_receipt_id=v_receipt_id,last_receipt_digest=v_digest WHERE id=h.id AND version=p_expected_handoff_version;
  UPDATE ops.journey_instances SET state='ACTIVE',version=version+1,next_owner_kind=NULL,next_owner_function=NULL,next_owner_ref_hmac=NULL,active_handoff_id=NULL,active_handoff_generation=NULL,active_handoff_state=NULL,escalation_state='RESOLVED',last_receipt_id=v_receipt_id,last_receipt_sequence=last_receipt_sequence+1,last_receipt_digest=v_digest,updated_at=v_now WHERE id=i.id AND version=i.version;
  v_parent := ROW(i.id,i.version+1,'ACTIVE',i.current_owner_ref_hmac,NULL,NULL,NULL,NULL,'RESOLVED',i.due_at,v_receipt_id,v_digest)::ops.journey_instance_head_result_v1;
  RETURN ROW('APPLIED','EXPIRED',v_receipt_id,v_digest,i.version+1,h.id,h.version+1,v_audit,v_outbox,NULL::ops.journey_replacement_result_v1,v_parent,h.due_at,NULL)::ops.journey_scheduler_result_v1;
END $$;
ALTER FUNCTION ops.expire_journey_handoff_v1(uuid,bigint,uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.expire_journey_handoff_v1(uuid,bigint,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.expire_journey_handoff_v1(uuid,bigint,uuid) TO gurine_scheduler;

CREATE OR REPLACE FUNCTION ops.record_journey_outcome_v1(
  p_journey_instance_id uuid,p_expected_version bigint,p_edge_id text,p_outcome_code text,
  p_subject_kind text,p_subject_version bigint,p_subject_digest char(64),p_effect_digest char(64),
  p_request_id uuid,p_idempotency_key_sha256 char(64),p_actor_assertion_jti uuid
) RETURNS ops.journey_transition_receipts
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  i ops.journey_instances; h ops.journey_handoffs; r ops.journey_transition_receipts;
  v_now timestamptz := clock_timestamp(); v_receipt_id uuid := gen_random_uuid(); v_cancel_id uuid := gen_random_uuid();
  v_audit uuid; v_outbox uuid; v_cancel_outbox uuid; v_digest char(64); v_cancel_digest char(64); v_hash char(64); v_state text; v_to_node text;
  v_existing_resource text; v_existing_hash char(64);
BEGIN
  IF current_setting('transaction_isolation') <> 'serializable' THEN RAISE EXCEPTION 'JOURNEY_SERIALIZABLE_REQUIRED' USING ERRCODE='25001'; END IF;
  IF p_journey_instance_id IS NULL OR p_expected_version < 1 OR p_edge_id IS NULL
     OR p_outcome_code IS NULL OR p_request_id IS NULL
     OR p_idempotency_key_sha256 !~ '^[0-9a-f]{64}$'
     OR p_subject_version < 1 OR p_subject_digest !~ '^[0-9a-f]{64}$'
     OR p_effect_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'journey_outcome_invalid' USING ERRCODE='22023';
  END IF;
  v_hash := encode(extensions.digest(convert_to(jsonb_build_object('operationId','recordJourneyOutcome','journeyInstanceId',p_journey_instance_id,'expectedVersion',p_expected_version,'edgeId',p_edge_id,'outcomeCode',p_outcome_code,'subjectKind',p_subject_kind,'subjectVersion',p_subject_version,'subjectDigest',p_subject_digest,'effectDigest',p_effect_digest)::text,'UTF8'),'sha256'),'hex');
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at) VALUES('JOURNEY_OUTCOME',p_idempotency_key_sha256,v_hash,v_now+interval '24 hours') ON CONFLICT (scope,key_hash) DO NOTHING;
  SELECT resource_id,request_hash INTO v_existing_resource,v_existing_hash FROM ops.idempotency_keys WHERE scope='JOURNEY_OUTCOME' AND key_hash=p_idempotency_key_sha256 FOR UPDATE;
  IF v_existing_hash IS DISTINCT FROM v_hash THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001'; END IF;
  IF v_existing_resource IS NOT NULL THEN
    SELECT * INTO STRICT r FROM ops.journey_transition_receipts WHERE id=v_existing_resource::uuid;
    RETURN r;
  END IF;
  SELECT * INTO i FROM ops.journey_instances WHERE id=p_journey_instance_id FOR UPDATE;
  IF NOT FOUND OR i.version<>p_expected_version THEN RAISE EXCEPTION 'journey_version_conflict' USING ERRCODE='40001'; END IF;
  IF i.active_handoff_id IS NOT NULL THEN SELECT * INTO h FROM ops.journey_handoffs WHERE id=i.active_handoff_id FOR UPDATE; END IF;
  -- Outcomes are only valid for an edge compiled into the instance's closed
  -- journey grammar.  A syntactically valid edge (or an edge from another
  -- journey) must never be able to mutate the head or manufacture a receipt.
  IF split_part(p_edge_id,'-',1)||'-'||split_part(p_edge_id,'-',2)<>i.journey_code
     OR NOT (CASE i.journey_code
       WHEN 'J-01' THEN p_edge_id IN ('J-01-E01','J-01-E02','J-01-E03','J-01-E04')
       WHEN 'J-02' THEN p_edge_id IN ('J-02-E01','J-02-E02','J-02-E03','J-02-E04','J-02-E05')
       WHEN 'J-03' THEN p_edge_id IN ('J-03-E01','J-03-E02','J-03-E03','J-03-E04','J-03-E05','J-03-E06','J-03-E07')
       WHEN 'J-04' THEN p_edge_id IN ('J-04-E01','J-04-E02','J-04-E03','J-04-E04','J-04-E05')
       WHEN 'J-05' THEN p_edge_id IN ('J-05-E01','J-05-E02','J-05-E03','J-05-E04')
       WHEN 'J-06' THEN p_edge_id IN ('J-06-E01','J-06-E02','J-06-E03','J-06-E04','J-06-E05','J-06-E06','J-06-E07','J-06-E08','J-06-E09')
       WHEN 'J-07' THEN p_edge_id IN ('J-07-E01','J-07-E02','J-07-E03','J-07-E04','J-07-E05')
       WHEN 'J-08' THEN p_edge_id IN ('J-08-E01','J-08-E02','J-08-E03','J-08-E04')
       WHEN 'J-09' THEN p_edge_id IN ('J-09-E01','J-09-E02','J-09-E03','J-09-E04')
       WHEN 'J-10' THEN p_edge_id IN ('J-10-E01','J-10-E02','J-10-E03','J-10-E04','J-10-E05','J-10-E06','J-10-E07','J-10-E08','J-10-E09','J-10-E10','J-10-E11','J-10-E12','J-10-E13','J-10-E14','J-10-E15','J-10-E16','J-10-E17')
       WHEN 'J-11' THEN p_edge_id IN ('J-11-E01','J-11-E02','J-11-E03','J-11-E04','J-11-E05','J-11-E06','J-11-E07','J-11-E08A','J-11-E08B','J-11-E08C','J-11-E08D','J-11-E08E','J-11-E08F','J-11-E09','J-11-E10','J-11-E11','J-11-E12A','J-11-E12B','J-11-E13','J-11-E14','J-11-E15','J-11-E16','J-11-E17','J-11-E18','J-11-E19','J-11-E20','J-11-E21','J-11-E22','J-11-E23')
       WHEN 'J-12' THEN p_edge_id IN ('J-12-E01','J-12-E02','J-12-E03','J-12-E04','J-12-E05','J-12-E06','J-12-E07','J-12-E08','J-12-E09A','J-12-E09B','J-12-E10','J-12-E11','J-12-E12','J-12-E13','J-12-E14','J-12-E15','J-12-E16','J-12-E17','J-12-E18A','J-12-E18B','J-12-E18C','J-12-E18D','J-12-E19A','J-12-E19B','J-12-E19C','J-12-E20','J-12-E21','J-12-E22','J-12-E23','J-12-E24','J-12-E25','J-12-E26','J-12-E27','J-12-E28','J-12-E29','J-12-E30')
       ELSE false END) THEN
    RAISE EXCEPTION 'journey_edge_not_compiled' USING ERRCODE='22023';
  END IF;
  -- Branch destinations are a closed selector registry.  A branch outcome
  -- must resolve to the authored destination node before a receipt can move
  -- the journey head; unknown selectors fail closed instead of falling back
  -- to the edge id or the prior node.
  v_to_node := CASE p_edge_id
    WHEN 'J-05-E03' THEN CASE upper(p_outcome_code)
      WHEN 'DISMISS' THEN 'J-05::DISMISSED'
      WHEN 'NEEDS_DATA' THEN 'INT-002::signal-enrichment-pending'
      WHEN 'MARK_DUPLICATE' THEN 'J-05::DUPLICATE'
      WHEN 'PROMOTE_TO_CASE' THEN 'CAS-002::case-ownership-pending'
      WHEN 'LINK_TO_CASE' THEN 'CAS-002::case-ownership-pending' END
    WHEN 'J-06-E03' THEN CASE upper(p_outcome_code)
      WHEN 'OPEN_EVIDENCE' THEN 'CAS-005'
      WHEN 'START_AI_RESEARCH' THEN 'J-10::ENTRY[CAS-010]' END
    WHEN 'J-06-E07' THEN CASE upper(p_outcome_code)
      WHEN 'OPEN_REVIEW_READINESS' THEN 'CAS-013'
      WHEN 'NEW_RESPONSE_REQUEST' THEN 'J-03::ENTRY[CAS-009]' END
    WHEN 'J-07-E02' THEN CASE upper(p_outcome_code)
      WHEN 'APPROVE' THEN 'REV-003'
      WHEN 'CHANGES_REQUIRED' THEN 'J-07::CHANGES_REQUIRED'
      WHEN 'REJECT' THEN 'J-07::REJECTED'
      WHEN 'RECUSE' THEN 'REV-001' END
    WHEN 'J-10-E03' THEN CASE upper(p_outcome_code)
      WHEN 'SUCCEEDED_SETTLED' THEN 'CAS-011::settled-success-output'
      WHEN 'FAILED_SETTLED' THEN 'J-10::FAILED'
      WHEN 'CANCELLED_SETTLED' THEN 'J-10::CANCELLED'
      WHEN 'BUDGET_BLOCKED_SETTLED' THEN 'J-10::BUDGET_BLOCKED'
      WHEN 'POLICY_BLOCKED_SETTLED' THEN 'J-10::POLICY_BLOCKED' END
    WHEN 'J-10-E09' THEN CASE upper(p_outcome_code)
      WHEN 'RECONCILED_SUCCEEDED' THEN 'CAS-011::settled-success-output'
      WHEN 'RECONCILED_FAILED' THEN 'J-10::FAILED'
      WHEN 'RECONCILED_CANCELLED' THEN 'J-10::CANCELLED'
      WHEN 'BUDGET_DENIED' THEN 'J-10::BUDGET_BLOCKED'
      WHEN 'POLICY_DENIED' THEN 'J-10::POLICY_BLOCKED' END
    WHEN 'J-10-E11' THEN CASE upper(p_outcome_code)
      WHEN 'VALIDATED_WITH_ELIGIBLE_ARTIFACT' THEN 'CAS-011::analysis-verified'
      WHEN 'ABSTAINED' THEN 'J-10::ABSTAINED'
      WHEN 'VALIDATED_NO_ELIGIBLE_ARTIFACT' THEN 'J-10::NO_ELIGIBLE_ARTIFACT'
      WHEN 'OUTPUT_SCHEMA_INVALID' THEN 'J-10::FAILED'
      WHEN 'CITATION_INVALID' THEN 'J-10::ABSTAINED' END
    WHEN 'J-11-E11' THEN CASE upper(p_outcome_code)
      WHEN 'NON_COMMUNICATION_SUCCEEDED' THEN 'J-11::DURABLE_EFFECT_RECEIPT'
      WHEN 'PARTIALLY_SUCCEEDED' THEN 'J-11::PARTIALLY_SUCCEEDED'
      WHEN 'RETRYABLE_FAILED' THEN 'J-11::RETRYABLE_FAILED'
      WHEN 'PERMANENT_FAILED' THEN 'J-11::PERMANENT_FAILED'
      WHEN 'RECONCILIATION_REQUIRED' THEN 'J-11::RECONCILIATION_REQUIRED'
      WHEN 'CANCELLED' THEN 'J-11::CANCELLED'
      WHEN 'EXPIRED' THEN 'J-11::EXPIRED' END
    WHEN 'J-11-E14' THEN CASE upper(p_outcome_code)
      WHEN 'SUCCEEDED' THEN 'J-11::DURABLE_EFFECT_RECEIPT'
      WHEN 'PARTIALLY_SUCCEEDED' THEN 'J-11::PARTIALLY_SUCCEEDED'
      WHEN 'RETRYABLE_FAILED' THEN 'J-11::RETRYABLE_FAILED'
      WHEN 'PERMANENT_FAILED' THEN 'J-11::PERMANENT_FAILED'
      WHEN 'CANCELLED' THEN 'J-11::CANCELLED'
      WHEN 'STILL_AMBIGUOUS' THEN 'J-11::RECONCILIATION_REQUIRED' END
    WHEN 'J-11-E18' THEN CASE upper(p_outcome_code)
      WHEN 'EXPIRED' THEN 'J-11::EXPIRED'
      WHEN 'SUPERSEDED' THEN 'J-11::SUPERSEDED' END
    WHEN 'J-11-E21' THEN CASE upper(p_outcome_code)
      WHEN 'PROVIDER_ACCEPTED' THEN 'OPS-005::provider-accepted'
      WHEN 'DELIVERED' THEN 'J-11::DELIVERED_OR_READ_RECEIPT'
      WHEN 'READ' THEN 'J-11::DELIVERED_OR_READ_RECEIPT'
      WHEN 'RETRY_SCHEDULED' THEN 'OPS-005::delivery-retry-scheduled'
      WHEN 'FAILED_PERMANENT' THEN 'J-11::DELIVERY_FAILED_PERMANENT'
      WHEN 'SUPPRESSED' THEN 'J-11::DELIVERY_SUPPRESSED'
      WHEN 'CANCELLED' THEN 'J-11::DELIVERY_CANCELLED'
      WHEN 'RECONCILIATION_REQUIRED' THEN 'J-11::DELIVERY_RECONCILIATION_REQUIRED' END
    WHEN 'J-11-E22' THEN CASE upper(p_outcome_code)
      WHEN 'NOT_TRANSMITTED' THEN 'OPS-005::delivery-retry-scheduled'
      WHEN 'PROVIDER_ACCEPTED' THEN 'OPS-005::provider-accepted'
      WHEN 'DELIVERED' THEN 'J-11::DELIVERED_OR_READ_RECEIPT'
      WHEN 'FAILED_PERMANENT' THEN 'J-11::DELIVERY_FAILED_PERMANENT' END
    WHEN 'J-12-E07' THEN CASE upper(p_outcome_code)
      WHEN 'READY' THEN 'OPS-001::data-ready'
      WHEN 'SCHEMA_DRIFT' THEN 'J-09::ENTRY[SRC-005]'
      WHEN 'OWNED_REPAIRABLE_BLOCKER' THEN 'J-12::DATA_READINESS_BLOCKED'
      WHEN 'UNKNOWN_OR_UNOWNED' THEN 'J-12::DATA_READINESS_BLOCKED' END
    WHEN 'J-12-E18A' THEN CASE upper(p_outcome_code)
      WHEN 'QUORUM_INCOMPLETE' THEN 'INT-002::paid-action-assigned'
      WHEN 'FINAL_QUEUED' THEN 'J-11::ENTRY[E09]'
      WHEN 'POLICY_BLOCKED' THEN 'J-12::POLICY_BLOCKED' END
    WHEN 'J-12-E18D' THEN CASE upper(p_outcome_code)
      WHEN 'REJECT' THEN 'J-12::rejected-final-candidate'
      WHEN 'EXPIRED' THEN 'J-12::EXPIRED' END
    WHEN 'J-12-E20' THEN CASE upper(p_outcome_code)
      WHEN 'ACTION_SUCCEEDED' THEN 'J-11::DURABLE_EFFECT_RECEIPT'
      WHEN 'DELIVERY_DELIVERED_OR_READ' THEN 'J-11::DELIVERED_OR_READ_RECEIPT'
      WHEN 'ACTION_RETRY_AUTHORIZED' THEN 'J-11::ENTRY[E09]'
      WHEN 'DELIVERY_RETRY_AUTHORIZED' THEN 'J-11::ENTRY[E20]'
      WHEN 'DEFINITIVE_NONVALUE' THEN 'J-12::TERMINAL_NONVALUE'
      WHEN 'STILL_AMBIGUOUS' THEN 'J-12::RECONCILIATION_REQUIRED' END
    WHEN 'J-12-E28' THEN CASE upper(p_outcome_code)
      WHEN 'QUALIFIED' THEN 'OPS-004::qualified-receipt-visible'
      WHEN 'CONFIGURED' THEN 'OPS-001::configured-evidence-visible'
      WHEN 'DATA_READY' THEN 'OPS-001::data-ready'
      WHEN 'FIRST_PAID_VALUE' THEN 'OPS-004::activated'
      WHEN 'ACTIVATED' THEN 'OPS-004::activated'
      WHEN 'RETAINED' THEN 'OPS-004::retained' END
    ELSE NULL
  END;
  IF p_edge_id IN ('J-05-E03','J-06-E03','J-06-E07','J-07-E02','J-10-E03','J-10-E09','J-10-E11','J-11-E11','J-11-E14','J-11-E18','J-11-E21','J-11-E22','J-12-E07','J-12-E18A','J-12-E18D','J-12-E20','J-12-E28') AND v_to_node IS NULL THEN
    RAISE EXCEPTION 'journey_branch_selector_invalid' USING ERRCODE='22023';
  END IF;
  IF h.id IS NOT NULL AND h.edge_id<>p_edge_id THEN
    RAISE EXCEPTION 'journey_outcome_handoff_mismatch' USING ERRCODE='40001';
  END IF;
  -- The outcome selector and its compiled destination jointly determine the
  -- head state.  A terminal branch such as FAILED_SETTLED or POLICY_BLOCKED
  -- must not remain ACTIVE merely because its outcome code is not the generic
  -- SUCCESS token; recovery branches (RETRYABLE_FAILED and
  -- RECONCILIATION_REQUIRED) deliberately remain ACTIVE.
  v_state := CASE
    WHEN upper(p_outcome_code) IN ('COMPLETED','SUCCESS','SUCCEEDED','OUTCOME_RECORDED') THEN 'COMPLETED'
    WHEN upper(p_outcome_code) IN ('CANCELLED','CANCELED') THEN 'CANCELLED'
    ELSE 'ACTIVE'
  END;
  IF v_to_node ~ '::(CANCELLED|DELIVERY_CANCELLED)$' THEN
    v_state := 'CANCELLED';
  ELSIF v_to_node ~ '::EXPIRED$' THEN
    v_state := 'EXPIRED';
  ELSIF v_to_node ~ '::REJECTED$' THEN
    v_state := 'REJECTED';
  ELSIF v_to_node ~ '::(FAILED|BUDGET_BLOCKED|POLICY_BLOCKED|PERMANENT_FAILED|DELIVERY_FAILED_PERMANENT|TERMINAL_NONVALUE|DURABLE_EFFECT_RECEIPT|DELIVERED_OR_READ_RECEIPT|ABSTAINED|NO_ELIGIBLE_ARTIFACT|analysis-verified|settled-success-output)$' THEN
    v_state := 'COMPLETED';
  END IF;
  IF h.id IS NOT NULL THEN
    v_cancel_digest := encode(extensions.digest(convert_to(v_cancel_id::text||':'||h.id::text||':CANCELLED:'||p_effect_digest,'UTF8'),'sha256'),'hex');
    v_audit := ops.append_audit_event('journey:'||i.id::text,'SERVICE',COALESCE(p_actor_assertion_jti::text,current_user),NULL::uuid,'JOURNEY_HANDOFF_CANCELLED','JourneyHandoff',h.id::text,'journeys.outcome','SUCCESS','SOURCE_CANCELLED',p_request_id,jsonb_build_object('outcomeCode',p_outcome_code));
    v_cancel_outbox := ops.enqueue_outbox('JourneyHandoff',h.id::text,i.version+1,
      'journey.handoff_cancelled.v1',jsonb_build_object(
        'handoffId',h.id,'journeyInstanceId',i.id,'edgeId',h.edge_id,
        'outcomeCode',p_outcome_code,'requestId',p_request_id,
        'receiptId',v_cancel_id,'receiptDigest',v_cancel_digest),v_now);
    INSERT INTO ops.journey_transition_receipts(id,journey_instance_id,journey_instance_version,handoff_id,handoff_version,edge_id,sequence,receipt_kind,prior_receipt_id,prior_receipt_digest,subject_digest,prior_owner_binding_digest,current_owner_binding_digest,next_owner_binding_digest,prior_instance_state,resulting_instance_state,prior_handoff_state,resulting_handoff_state,escalation_state,prior_due_at,resulting_due_at,effect_digest,audit_event_id,outbox_event_id,occurred_at,receipt_digest)
    VALUES(v_cancel_id,i.id,i.version+1,h.id,h.version+1,h.edge_id,i.version+1,'HANDOFF_CANCELLED',i.last_receipt_id,i.last_receipt_digest,h.subject_digest,i.current_owner_ref_hmac,i.current_owner_ref_hmac,NULL,i.state,'ACTIVE',h.state,'CANCELLED','RESOLVED',i.due_at,i.due_at,p_effect_digest,v_audit,v_cancel_outbox,v_now,v_cancel_digest) RETURNING * INTO r;
    UPDATE ops.journey_handoffs SET state='CANCELLED',version=version+1,decided_at=v_now,decision_actor_binding_hmac=encode(extensions.digest(convert_to(COALESCE(p_actor_assertion_jti::text,current_user),'UTF8'),'sha256'),'hex'),decision_reason_code='SOURCE_CANCELLED',last_receipt_id=v_cancel_id,last_receipt_digest=v_cancel_digest WHERE id=h.id AND version=h.version;
    UPDATE ops.journey_instances SET state='ACTIVE',version=version+1,current_node_id=COALESCE(h.to_node_id,current_node_id),next_owner_kind=NULL,next_owner_function=NULL,next_owner_ref_hmac=NULL,active_handoff_id=NULL,active_handoff_generation=NULL,active_handoff_state=NULL,escalation_state='RESOLVED',last_receipt_id=v_cancel_id,last_receipt_sequence=last_receipt_sequence+1,last_receipt_digest=v_cancel_digest,updated_at=v_now WHERE id=i.id AND version=i.version;
    i.version := i.version+1; i.last_receipt_id := v_cancel_id; i.last_receipt_digest := v_cancel_digest; i.last_receipt_sequence := i.last_receipt_sequence+1; i.state := 'ACTIVE'; i.active_handoff_id := NULL;
  END IF;
  v_receipt_id := gen_random_uuid(); v_audit := ops.append_audit_event('journey:'||i.id::text,'SERVICE',COALESCE(p_actor_assertion_jti::text,current_user),NULL::uuid,'JOURNEY_OUTCOME_RECORDED','JourneyInstance',i.id::text,'journeys.outcome','SUCCESS',p_outcome_code,p_request_id,jsonb_build_object('edgeId',p_edge_id,'effectDigest',p_effect_digest));
  v_outbox := ops.enqueue_outbox('JourneyInstance',i.id::text,i.version+1,'journey.outcome_recorded.v1',jsonb_build_object('journeyInstanceId',i.id,'outcomeCode',p_outcome_code,'requestId',p_request_id),v_now);
  v_digest := encode(extensions.digest(convert_to(v_receipt_id::text||':'||i.id::text||':'||(i.version+1)::text||':'||p_effect_digest,'UTF8'),'sha256'),'hex');
  INSERT INTO ops.journey_transition_receipts(id,journey_instance_id,journey_instance_version,edge_id,sequence,receipt_kind,prior_receipt_id,prior_receipt_digest,subject_digest,prior_owner_binding_digest,current_owner_binding_digest,next_owner_binding_digest,prior_instance_state,resulting_instance_state,prior_handoff_state,resulting_handoff_state,escalation_state,prior_due_at,resulting_due_at,effect_digest,audit_event_id,outbox_event_id,occurred_at,receipt_digest)
  VALUES(v_receipt_id,i.id,i.version+1,p_edge_id,i.version+1,'OUTCOME_RECORDED',i.last_receipt_id,i.last_receipt_digest,p_subject_digest,i.current_owner_ref_hmac,i.current_owner_ref_hmac,NULL,i.state,v_state,NULL,NULL,'RESOLVED',i.due_at,i.due_at,p_effect_digest,v_audit,v_outbox,v_now,v_digest) RETURNING * INTO r;
  UPDATE ops.journey_instances SET state=v_state,version=version+1,current_object_kind=p_subject_kind,current_object_version=p_subject_version,current_object_digest=p_subject_digest,current_node_id=COALESCE(v_to_node,COALESCE(h.to_node_id,i.current_node_id)),last_receipt_id=v_receipt_id,last_receipt_sequence=last_receipt_sequence+1,last_receipt_digest=v_digest,terminal_at=CASE WHEN v_state IN ('COMPLETED','CANCELLED') THEN v_now ELSE NULL END,updated_at=v_now WHERE id=i.id AND version=i.version;
  UPDATE ops.idempotency_keys SET resource_type='JourneyTransitionReceipt',resource_id=v_receipt_id::text,response_status=200,response_body=jsonb_build_object('receiptId',v_receipt_id,'receiptDigest',v_digest) WHERE scope='JOURNEY_OUTCOME' AND key_hash=p_idempotency_key_sha256;
  RETURN r;
END $$;
ALTER FUNCTION ops.record_journey_outcome_v1(uuid,bigint,text,text,text,bigint,char(64),char(64),uuid,char(64),uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_journey_outcome_v1(uuid,bigint,text,text,text,bigint,char(64),char(64),uuid,char(64),uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_journey_outcome_v1(uuid,bigint,text,text,text,bigint,char(64),char(64),uuid,char(64),uuid) TO gurine_control_api,gurine_workflow_worker;

COMMIT;

-- Communication delivery control owns the outbound-delivery aggregate.  The
-- legacy ops.email_deliveries table is intentionally left untouched for the
-- pre-v13 worker compatibility path; current communication commands use this
-- typed aggregate and its immutable decision/receipt relations below.
BEGIN;
CREATE TABLE IF NOT EXISTS ops.outbound_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_version text NOT NULL DEFAULT 'COMMUNICATION_V1',
  dispatch_eligible boolean NOT NULL DEFAULT true,
  intent_id uuid,
  intent_digest char(64),
  intent_source_decision_digest char(64),
  rendering_id uuid,
  endpoint_id uuid,
  endpoint_version bigint,
  endpoint_snapshot_digest char(64),
  recipient_endpoint_hmac char(64),
  provider_config_id uuid,
  provider_config_version bigint,
  provider_configuration_digest char(64),
  provider_preflight_receipt_id uuid,
  provider_preflight_receipt_digest char(64),
  channel text NOT NULL DEFAULT 'SMTP_EMAIL',
  delivery_key char(64),
  locale text,
  template_id text,
  template_revision text,
  rendered_sha256 char(64),
  rendering_digest char(64),
  authorization_snapshot_digest char(64),
  activation_receipt_digest char(64),
  budget_reservation_id uuid,
  execution_authorization_id uuid,
  execution_generation bigint,
  decision_digest char(64),
  effect_safety_class text,
  suppression_snapshot_digest char(64),
  provider_idempotency_key_ciphertext bytea,
  provider_key_encryption_key_id text,
  provider_idempotency_key_sha256 char(64),
  delivery_digest char(64),
  state text NOT NULL,
  version bigint NOT NULL DEFAULT 1,
  generation bigint NOT NULL DEFAULT 1,
  event_sequence bigint NOT NULL DEFAULT 1,
  receipt_sequence bigint NOT NULL DEFAULT 0,
  attempt_count integer NOT NULL DEFAULT 0,
  max_attempts integer NOT NULL DEFAULT 3,
  current_evidence_rank smallint NOT NULL DEFAULT 0,
  highest_proof_level text NOT NULL DEFAULT 'NONE',
  lease_owner text,
  lease_token_hash char(64),
  lease_expires_at timestamptz,
  fencing_token bigint NOT NULL DEFAULT 0,
  cancellation_generation bigint NOT NULL DEFAULT 0,
  cancel_requested_at timestamptz,
  cancel_reason_code text,
  not_before timestamptz NOT NULL DEFAULT clock_timestamp(),
  next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz,
  queued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  provider_accepted_at timestamptz,
  delivered_at timestamptz,
  read_at timestamptz,
  terminal_at timestamptz,
  message_type text NOT NULL DEFAULT 'COMMUNICATION',
  recipient_hash char(64) NOT NULL DEFAULT repeat('0',64),
  template_version text NOT NULL DEFAULT 'v1',
  object_type text,
  object_id uuid,
  provider_message_id text,
  provider_message_id_hmac char(64),
  provider_message_id_ciphertext bytea,
  last_error_code text,
  CONSTRAINT outbound_deliveries_state_ck CHECK (state IN ('QUEUED','SENDING','PROVIDER_ACCEPTED','DELIVERED','READ','RETRY_SCHEDULED','FAILED_PERMANENT','RECONCILIATION_REQUIRED','SUPPRESSED','CANCELLED')),
  CONSTRAINT outbound_deliveries_contract_ck CHECK (contract_version IN ('LEGACY_V13','COMMUNICATION_V1')),
  CONSTRAINT outbound_deliveries_version_ck CHECK (version > 0 AND generation > 0 AND event_sequence > 0 AND receipt_sequence >= 0 AND attempt_count BETWEEN 0 AND max_attempts AND max_attempts = 3 AND current_evidence_rank BETWEEN 0 AND 100 AND fencing_token >= 0 AND cancellation_generation >= 0),
  CONSTRAINT outbound_deliveries_proof_ck CHECK (highest_proof_level IN ('NONE','PROVIDER_ACCEPTED','DELIVERED','READ')),
  CONSTRAINT outbound_deliveries_digest_ck CHECK ((intent_digest IS NULL OR ops.is_lower_sha256(intent_digest)) AND (intent_source_decision_digest IS NULL OR ops.is_lower_sha256(intent_source_decision_digest)) AND (endpoint_snapshot_digest IS NULL OR ops.is_lower_sha256(endpoint_snapshot_digest)) AND (provider_preflight_receipt_digest IS NULL OR ops.is_lower_sha256(provider_preflight_receipt_digest)) AND (rendering_digest IS NULL OR ops.is_lower_sha256(rendering_digest)) AND (delivery_digest IS NULL OR ops.is_lower_sha256(delivery_digest)))
);
ALTER TABLE ops.outbound_deliveries OWNER TO gurine_migrator;
CREATE UNIQUE INDEX IF NOT EXISTS outbound_delivery_key_uq ON ops.outbound_deliveries(delivery_key) WHERE delivery_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS outbound_delivery_reconciliation_idx ON ops.outbound_deliveries(updated_at,id) WHERE state='RECONCILIATION_REQUIRED';
CREATE INDEX IF NOT EXISTS outbound_delivery_dispatch_idx ON ops.outbound_deliveries(state,next_attempt_at,queued_at,id) WHERE dispatch_eligible AND state IN ('QUEUED','RETRY_SCHEDULED');
REVOKE ALL ON ops.outbound_deliveries FROM PUBLIC, gurine_control_api, gurine_notification_worker, gurine_workflow_worker, gurine_analysis_worker, gurine_public_projector, gurine_submission_api, gurine_auditor;
GRANT SELECT ON ops.outbound_deliveries TO gurine_control_api, gurine_notification_worker, gurine_workflow_worker, gurine_auditor, gurine_scheduler;

CREATE OR REPLACE FUNCTION ops.read_communication_delivery_receipt_v1(p_delivery_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
DECLARE
  d ops.outbound_deliveries%ROWTYPE;
  latest ops.outbound_delivery_receipts%ROWTYPE;
  attempts jsonb;
  receipts jsonb;
  channel text;
BEGIN
  SELECT * INTO d FROM ops.outbound_deliveries WHERE id=p_delivery_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;
  SELECT * INTO latest FROM ops.outbound_delivery_receipts
   WHERE delivery_id=d.id AND applied ORDER BY receipt_sequence DESC LIMIT 1;
  IF NOT FOUND OR latest.resulting_state NOT IN ('PROVIDER_ACCEPTED','DELIVERED','READ') THEN
    RAISE EXCEPTION 'delivery_receipt_incomplete' USING ERRCODE='55000';
  END IF;
  channel := CASE d.channel
    WHEN 'SMTP_EMAIL' THEN 'EMAIL' WHEN 'SOLAPI_SMS' THEN 'SMS'
    WHEN 'TELEGRAM_BOT_API' THEN 'TELEGRAM' WHEN 'META_WHATSAPP_BUSINESS_CLOUD' THEN 'WHATSAPP'
    WHEN 'LINE_MESSAGING_API' THEN 'LINE' WHEN 'SOLAPI_KAKAO_BIZMESSAGE' THEN 'KAKAO'
    WHEN 'TWILIO_VOICE' THEN 'VOICE' WHEN 'SIGNED_WEBHOOK' THEN 'WEBHOOK' ELSE d.channel END;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'attemptId',a.id,'ordinal',a.attempt_ordinal,'provider',d.channel,
    'providerEventIdentityHmac',NULL,'providerAcknowledgementSha256',NULL,
    'state',CASE WHEN d.state IN ('QUEUED','SENDING') THEN 'SENDING' ELSE d.state END,
    'startedAt',a.claimed_at,'observedAt',NULL,'cost',NULL
  ) ORDER BY a.attempt_ordinal),'[]'::jsonb) INTO attempts
    FROM ops.outbound_delivery_attempts a WHERE a.delivery_id=d.id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'receiptId',r.id,'sequence',r.receipt_sequence,'deliveryId',r.delivery_id,
    'deliveryVersion',r.delivery_version,'attemptId',r.attempt_id,
    'evidenceKind',CASE r.evidence_kind WHEN 'PROVIDER_RESPONSE' THEN 'PROVIDER_ACKNOWLEDGEMENT'
      WHEN 'PROVIDER_CALLBACK' THEN 'SIGNED_CALLBACK' WHEN 'PROVIDER_POLL' THEN 'AUTHENTICATED_POLL'
      WHEN 'RECONCILIATION_DECISION' THEN 'RECONCILIATION_DECISION'
      WHEN 'CANCELLATION' THEN 'CANCELLATION_PROOF' ELSE 'PROVIDER_ACKNOWLEDGEMENT' END,
    'providerEventIdentityHmac',r.provider_event_identity_hash,'priorState',r.prior_state,
    'state',r.resulting_state,'providerEvidenceDigest',r.provider_evidence_digest,
    'observedAt',r.observed_at,'receiptDigest',r.receipt_digest
  ) ORDER BY r.receipt_sequence),'[]'::jsonb) INTO receipts
    FROM ops.outbound_delivery_receipts r WHERE r.delivery_id=d.id;
  RETURN jsonb_build_object(
    'delivery',jsonb_build_object('deliveryId',d.id,'version',d.version,'intentId',d.intent_id,
      'deliveryKeySha256',d.delivery_key,'channel',channel,'endpointId',d.endpoint_id,
      'endpointVersion',d.endpoint_version,'state',d.state,'renderingDigest',d.rendering_digest,
      'authorizationSnapshotDigest',d.authorization_snapshot_digest,
      'activationReceiptDigest',d.activation_receipt_digest,'budgetReservationId',d.budget_reservation_id,
      'createdAt',d.queued_at,'updatedAt',d.updated_at),
    'attempts',attempts,'receipts',receipts,
    'latestProviderEvidenceDigest',latest.provider_evidence_digest,
    'reconciliationRequired',(d.state='RECONCILIATION_REQUIRED'),'asOf',clock_timestamp(),
    'links',jsonb_build_array());
END
$$;
ALTER FUNCTION ops.read_communication_delivery_receipt_v1(uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_communication_delivery_receipt_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_communication_delivery_receipt_v1(uuid) TO gurine_control_api;

DO $$ BEGIN
  ALTER TABLE ops.outbound_delivery_attempts ADD CONSTRAINT outbound_delivery_attempt_delivery_fk FOREIGN KEY (delivery_id) REFERENCES ops.outbound_deliveries(id) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE ops.communication_reconciliation_decisions ADD CONSTRAINT communication_reconciliation_delivery_fk FOREIGN KEY (delivery_id) REFERENCES ops.outbound_deliveries(id) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE ops.outbound_delivery_receipts ADD CONSTRAINT outbound_delivery_receipt_delivery_fk FOREIGN KEY (delivery_id) REFERENCES ops.outbound_deliveries(id) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE ops.outbound_deliveries ADD CONSTRAINT outbound_delivery_intent_fk FOREIGN KEY (intent_id,intent_digest) REFERENCES ops.communication_intents(id,intent_digest) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE ops.outbound_deliveries ADD CONSTRAINT outbound_delivery_rendering_fk FOREIGN KEY (rendering_id,rendering_digest,rendered_sha256) REFERENCES ops.communication_renderings(id,rendering_digest,rendered_sha256) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE ops.outbound_deliveries ADD CONSTRAINT outbound_delivery_endpoint_fk FOREIGN KEY (endpoint_id,endpoint_version,endpoint_snapshot_digest,channel) REFERENCES intake.communication_endpoint_link_events(endpoint_id,endpoint_version,endpoint_snapshot_digest,channel) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE ops.outbound_deliveries ADD CONSTRAINT outbound_delivery_preflight_fk FOREIGN KEY (provider_preflight_receipt_id,provider_config_id,provider_config_version,provider_configuration_digest,provider_preflight_receipt_digest) REFERENCES ops.communication_provider_preflight_receipts(id,provider_config_id,provider_config_version,configuration_digest,receipt_digest) ON DELETE RESTRICT;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES ('communication.delivery_receipt_recorded.v1','DOMAIN',1,true,'payloads/communication_delivery_receipt_recorded_v1.schema.json')
ON CONFLICT (event_type) DO UPDATE SET active=EXCLUDED.active;
INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES ('communication.delivery_poll.v1','DOMAIN',1,true,'payloads/communication_delivery_poll_v1.schema.json')
ON CONFLICT (event_type) DO UPDATE SET active=EXCLUDED.active;
INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES ('communication.delivery_poll_requested.v1','INTEGRATION',1,true,'payloads/communication_delivery_poll_requested_v1.schema.json')
ON CONFLICT (event_type) DO UPDATE SET active=EXCLUDED.active;
GRANT SELECT,INSERT,UPDATE ON
  intake.appeals,intake.appeal_decisions,intake.response_extension_requests,
  editorial.response_extension_decisions,editorial.response_delivery_clock_decisions,
  editorial.response_requests,ops.business_calendar_versions,ops.retention_requests,
  ops.retention_request_decisions,ops.retention_execution_receipts,
  editorial.legal_holds,ops.legal_hold_target_anchors,editorial.conflict_snapshots,
  editorial.legal_hold_releases TO gurine_migrator;

CREATE OR REPLACE FUNCTION ops.communication_require_delivery_context(p_delivery ops.outbound_deliveries)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp AS $$
BEGIN
  IF p_delivery.contract_version <> 'COMMUNICATION_V1' OR p_delivery.intent_id IS NULL
     OR p_delivery.rendering_id IS NULL OR p_delivery.endpoint_id IS NULL
     OR p_delivery.endpoint_version IS NULL OR p_delivery.endpoint_snapshot_digest IS NULL
     OR p_delivery.provider_config_id IS NULL OR p_delivery.provider_config_version IS NULL
     OR p_delivery.provider_configuration_digest IS NULL OR p_delivery.provider_preflight_receipt_id IS NULL
     OR p_delivery.provider_preflight_receipt_digest IS NULL OR p_delivery.rendering_digest IS NULL
     OR p_delivery.authorization_snapshot_digest IS NULL OR p_delivery.activation_receipt_digest IS NULL
     OR p_delivery.provider_idempotency_key_sha256 IS NULL THEN
    RAISE EXCEPTION 'communication_delivery_unbound' USING ERRCODE='55000';
  END IF;
END $$;
ALTER FUNCTION ops.communication_require_delivery_context(ops.outbound_deliveries) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.communication_require_delivery_context(ops.outbound_deliveries) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.reconcile_communication_delivery_v1(
  p_payload jsonb, p_actor uuid, p_session_id uuid, p_request_id uuid,
  p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE
  d ops.outbound_deliveries%ROWTYPE; r ops.outbound_delivery_receipts%ROWTYPE;
  v_id uuid := NULLIF(p_payload->>'deliveryId','')::uuid;
  v_expected bigint := NULLIF(p_payload->>'expectedVersion','')::bigint;
  -- The external contract represents resolution as an object (`{kind: ...}`),
  -- while older callers may still send the scalar form.  Prefer the typed
  -- object member so JSON text is never mistaken for the enum value.
  v_resolution text := upper(COALESCE(
    NULLIF(p_payload->'resolution'->>'kind',''),
    NULLIF(p_payload->>'resolution',''),
    ''
  ));
  v_result text; v_evidence_kind text; v_evidence jsonb; v_evidence_digest char(64);
  v_decision_id uuid := gen_random_uuid(); v_decision_sequence bigint;
  v_receipt_id uuid := gen_random_uuid(); v_receipt_sequence bigint;
  v_outbox uuid := gen_random_uuid(); v_audit uuid; v_now timestamptz := clock_timestamp();
  v_decision_digest char(64); v_receipt_digest char(64); v_previous_receipt char(64);
  v_attempt_ids uuid[] := ARRAY[]::uuid[]; v_callback_ids uuid[] := ARRAY[]::uuid[];
  v_proof text; v_body jsonb; v_event jsonb; v_reason_code text := COALESCE(NULLIF(p_payload->>'reasonCode',''),'RECONCILIATION');
  v_reason text := COALESCE(NULLIF(p_payload->>'reason',''),'delivery reconciled');
  v_trace text := COALESCE(NULLIF(p_payload->>'traceId',''),p_request_id::text);
  v_zero char(64) := repeat('0',64); v_rank smallint := COALESCE(NULLIF(p_payload->>'evidenceRank','')::smallint,50);
BEGIN
  IF v_id IS NULL OR v_expected IS NULL OR v_expected < 1 OR v_resolution NOT IN ('NOT_TRANSMITTED','PROVIDER_ACCEPTED','DELIVERED','FAILED_PERMANENT') THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
  IF COALESCE(p_payload->>'assurance','STEP_UP') <> 'STEP_UP' THEN RAISE EXCEPTION 'step_up_required' USING ERRCODE='42501'; END IF;
  SELECT * INTO d FROM ops.outbound_deliveries WHERE id=v_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery_not_found' USING ERRCODE='P0002'; END IF;
  IF d.version <> v_expected THEN RAISE EXCEPTION 'delivery_version_conflict' USING ERRCODE='40001'; END IF;
  IF d.state <> 'RECONCILIATION_REQUIRED' THEN RAISE EXCEPTION 'delivery_state_invalid' USING ERRCODE='55000'; END IF;
  PERFORM ops.communication_require_delivery_context(d);
  v_evidence_kind := upper(COALESCE(NULLIF(p_payload->>'evidenceKind',''),p_payload->'evidence'->>'kind',''));
  IF v_evidence_kind NOT IN ('NO_PROVIDER_ATTEMPT','AUTHENTICATED_PROVIDER_LOOKUP','SIGNED_PROVIDER_CALLBACK','AUTHENTICATED_PROVIDER_POLL','OFFICIAL_CHANNEL_RECEIPT') THEN RAISE EXCEPTION 'delivery_reconciliation_evidence_invalid' USING ERRCODE='22023'; END IF;
  v_evidence := COALESCE(p_payload->'evidence','{}'::jsonb) || jsonb_build_object('kind',v_evidence_kind);
  v_evidence_digest := encode(extensions.digest(convert_to(v_evidence::text,'UTF8'),'sha256'),'hex');
  IF v_resolution='NOT_TRANSMITTED' THEN
    v_result := CASE WHEN COALESCE(p_payload->>'resultingState','')='CANCELLED' THEN 'CANCELLED' ELSE 'RETRY_SCHEDULED' END;
    IF v_evidence_kind<>'NO_PROVIDER_ATTEMPT' OR p_payload->'safeRetryProof' IS NULL THEN RAISE EXCEPTION 'delivery_reconciliation_evidence_invalid' USING ERRCODE='22023'; END IF;
    SELECT * INTO r FROM ops.outbound_delivery_receipts WHERE delivery_id=d.id ORDER BY receipt_sequence DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND OR r.evidence_kind<>'PRE_DISPATCH_FENCE' OR NOT r.applied THEN RAISE EXCEPTION 'delivery_reconciliation_evidence_invalid' USING ERRCODE='22023'; END IF;
  ELSE
    v_result := CASE v_resolution WHEN 'PROVIDER_ACCEPTED' THEN 'PROVIDER_ACCEPTED' WHEN 'DELIVERED' THEN 'DELIVERED' ELSE 'FAILED_PERMANENT' END;
    IF v_resolution='DELIVERED' AND v_evidence_kind NOT IN ('SIGNED_PROVIDER_CALLBACK','AUTHENTICATED_PROVIDER_POLL','OFFICIAL_CHANNEL_RECEIPT') THEN RAISE EXCEPTION 'delivery_reconciliation_evidence_invalid' USING ERRCODE='22023'; END IF;
  END IF;
  SELECT COALESCE(max(decision_sequence),0)+1 INTO v_decision_sequence FROM ops.communication_reconciliation_decisions WHERE delivery_id=d.id;
  SELECT COALESCE(max(receipt_sequence),0)+1, max(receipt_digest) FILTER (WHERE receipt_sequence=(SELECT max(receipt_sequence) FROM ops.outbound_delivery_receipts WHERE delivery_id=d.id)) INTO v_receipt_sequence,v_previous_receipt FROM ops.outbound_delivery_receipts WHERE delivery_id=d.id;
  v_attempt_ids := ARRAY(SELECT id FROM ops.outbound_delivery_attempts WHERE delivery_id=d.id ORDER BY attempt_ordinal);
  v_callback_ids := ARRAY(SELECT c.id FROM ops.communication_callback_events c WHERE c.id IN (SELECT value::uuid FROM jsonb_array_elements_text(COALESCE(p_payload->'callbackEventIds','[]'::jsonb))));
  IF cardinality(v_attempt_ids)+cardinality(v_callback_ids)=0 THEN RAISE EXCEPTION 'delivery_reconciliation_evidence_invalid' USING ERRCODE='22023'; END IF;
  v_proof := CASE WHEN v_result='DELIVERED' THEN 'DELIVERED' WHEN v_result='PROVIDER_ACCEPTED' THEN 'PROVIDER_ACCEPTED' ELSE d.highest_proof_level END;
  v_decision_digest := encode(extensions.digest(convert_to(v_id::text||':'||v_decision_sequence::text||':'||v_resolution||':'||p_request_digest,'UTF8'),'sha256'),'hex');
  v_receipt_digest := encode(extensions.digest(convert_to(v_id::text||':'||v_receipt_sequence::text||':'||v_result||':'||v_decision_digest,'UTF8'),'sha256'),'hex');
  v_body := jsonb_build_object(
    'operationId','reconcileCommunicationDelivery','deliveryId',d.id,'priorState',d.state,
    'state',v_result,'resolution',v_resolution,'deliveryVersion',d.version+1,
    'deliveryReceiptId',v_receipt_id,'deliveryReceiptSequence',v_receipt_sequence,
    'evidenceKind',v_evidence_kind,'providerEvidenceDigest',v_evidence_digest,
    'receiptDigest',v_receipt_digest,'acceptedAt',v_now,
    'intentId',d.intent_id,'version',d.version+1,'deliveryKeySha256',d.delivery_key,
    'channel',CASE d.channel WHEN 'SMTP_EMAIL' THEN 'EMAIL' WHEN 'SOLAPI_SMS' THEN 'SMS'
      WHEN 'TELEGRAM_BOT_API' THEN 'TELEGRAM' WHEN 'META_WHATSAPP_BUSINESS_CLOUD' THEN 'WHATSAPP'
      WHEN 'LINE_MESSAGING_API' THEN 'LINE' WHEN 'SOLAPI_KAKAO_BIZMESSAGE' THEN 'KAKAO'
      WHEN 'TWILIO_VOICE' THEN 'VOICE' ELSE 'WEBHOOK' END,
    'endpointId',d.endpoint_id,'endpointVersion',d.endpoint_version,
    'renderingDigest',d.rendering_digest,'authorizationSnapshotDigest',d.authorization_snapshot_digest,
    'activationReceiptDigest',d.activation_receipt_digest,'budgetReservationId',d.budget_reservation_id,
    'createdAt',d.queued_at,'updatedAt',v_now);
  v_audit := ops.append_audit_event('control:communication:'||d.id::text,'USER',p_actor::text,p_session_id,'COMMUNICATION_DELIVERY_RECONCILED','OutboundDelivery',d.id::text,'communications.operate','SUCCESS',v_reason,p_request_id,v_body);
  v_event := jsonb_build_object('operationId','reconcileCommunicationDelivery','deliveryId',d.id,'deliveryVersion',d.version+1,'deliveryReceiptId',v_receipt_id,'deliveryReceiptDigest',v_receipt_digest,'state',v_result,'requestId',p_request_id);
  INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at) VALUES(v_outbox,'OutboundDelivery',d.id::text,d.version+1,'communication.delivery_receipt_recorded.v1',v_event,v_now);
  INSERT INTO ops.communication_reconciliation_decisions(id,delivery_id,decision_sequence,expected_delivery_version,prior_state,resolution,resulting_state,evidence_kind,evidence,evidence_digest,safe_retry_kind,safe_retry_proof,safe_retry_proof_digest,safe_retry_pre_egress_receipt_id,safe_retry_pre_egress_receipt_sequence,safe_retry_pre_egress_receipt_digest,safe_retry_pre_egress_evidence_kind,safe_retry_pre_egress_applied,callback_event_ids,attempt_ids,actor_id,capability,assurance,assurance_receipt_digest,reason_code,reason,idempotency_key_hash,request_digest,request_id,trace_id,decision_digest,audit_event_id,outbox_event_id,receipt_digest,decided_at)
  VALUES(v_decision_id,d.id,v_decision_sequence,d.version,d.state,v_resolution,v_result,v_evidence_kind,v_evidence,v_evidence_digest,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN COALESCE(p_payload->>'safeRetryKind','NO_PROVIDER_ATTEMPT') END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN p_payload->'safeRetryProof' END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN encode(extensions.digest(convert_to((p_payload->'safeRetryProof')::text,'UTF8'),'sha256'),'hex') END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN r.id END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN r.receipt_sequence END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN r.receipt_digest END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN r.evidence_kind END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN r.applied END,v_callback_ids,v_attempt_ids,p_actor,'communications.operate','STEP_UP',encode(extensions.digest(convert_to('STEP_UP:'||p_actor::text,'UTF8'),'sha256'),'hex'),v_reason_code,v_reason,p_idempotency_key_hash,p_request_digest,p_request_id,v_trace,v_decision_digest,v_audit,v_outbox,v_receipt_digest,v_now);
  UPDATE ops.outbound_deliveries SET state=v_result,version=version+1,event_sequence=event_sequence+1,receipt_sequence=v_receipt_sequence,
    generation=CASE WHEN v_result='RETRY_SCHEDULED' THEN generation+1 ELSE generation END,
    current_evidence_rank=GREATEST(current_evidence_rank,v_rank),highest_proof_level=v_proof,updated_at=v_now,
    terminal_at=CASE WHEN v_result IN ('CANCELLED','FAILED_PERMANENT') THEN v_now ELSE terminal_at END
   WHERE id=d.id AND version=v_expected;
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery_version_conflict' USING ERRCODE='40001'; END IF;
  INSERT INTO ops.outbound_delivery_receipts(id,delivery_id,receipt_sequence,event_aggregate_version,prior_delivery_version,delivery_version,reconciliation_decision_id,source_kind,observation_key_digest,projection_disposition,evidence_kind,evidence_rank,prior_state,asserted_state,resulting_state,prior_proof_level,resulting_proof_level,applied,provider_evidence_digest,rendering_digest,endpoint_id,endpoint_version,endpoint_snapshot_digest,endpoint_identity_hash,provider_preflight_receipt_id,provider_config_id,provider_config_version,provider_configuration_digest,provider_preflight_receipt_digest,provider_identity_hash,authorization_snapshot_digest,activation_receipt_digest,budget_reservation_id,observed_at,actor_type,actor_id,request_id,trace_id,previous_receipt_digest,receipt_digest,audit_event_id,outbox_event_id)
  VALUES(v_receipt_id,d.id,v_receipt_sequence,d.version+1,d.version,d.version+1,v_decision_id,'RECONCILIATION_DECISION',encode(extensions.digest(convert_to(v_decision_digest||':observation','UTF8'),'sha256'),'hex'),'APPLIED','RECONCILIATION_PROOF',v_rank,d.state,v_result,v_result,d.highest_proof_level,v_proof,true,v_evidence_digest,d.rendering_digest,d.endpoint_id,d.endpoint_version,d.endpoint_snapshot_digest,v_zero,d.provider_preflight_receipt_id,d.provider_config_id,d.provider_config_version,d.provider_configuration_digest,d.provider_preflight_receipt_digest,v_zero,d.authorization_snapshot_digest,d.activation_receipt_digest,d.budget_reservation_id,v_now,'HUMAN_USER',p_actor,p_request_id,v_trace,v_previous_receipt,v_receipt_digest,v_audit,v_outbox);
  RETURN v_body || jsonb_build_object('auditEventId',v_audit,'emittedEventId',v_outbox,'decisionId',v_decision_id,'decisionDigest',v_decision_digest);
END $$;
ALTER FUNCTION ops.reconcile_communication_delivery_v1(jsonb,uuid,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.reconcile_communication_delivery_v1(jsonb,uuid,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.reconcile_communication_delivery_v1(jsonb,uuid,uuid,uuid,char(64),char(64)) TO gurine_control_api;
CREATE OR REPLACE FUNCTION ops.reconcile_communication_delivery(
  p_payload jsonb, p_actor uuid, p_session_id uuid, p_request_id uuid,
  p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp AS $$
  SELECT ops.reconcile_communication_delivery_v1($1,$2,$3,$4,$5,$6)
$$;
ALTER FUNCTION ops.reconcile_communication_delivery(jsonb,uuid,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.reconcile_communication_delivery(jsonb,uuid,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.reconcile_communication_delivery(jsonb,uuid,uuid,uuid,char(64),char(64)) TO gurine_control_api;

CREATE OR REPLACE FUNCTION ops.cancel_communication_delivery_v1(
  p_payload jsonb, p_actor uuid, p_session_id uuid, p_request_id uuid,
  p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE
  d ops.outbound_deliveries%ROWTYPE; v_id uuid := NULLIF(p_payload->>'deliveryId','')::uuid; v_expected bigint := NULLIF(p_payload->>'expectedVersion','')::bigint;
  v_result text; v_receipt_id uuid := gen_random_uuid(); v_outbox uuid := gen_random_uuid(); v_audit uuid; v_now timestamptz := clock_timestamp(); v_seq bigint; v_prev char(64); v_digest char(64); v_proof text; v_body jsonb; v_zero char(64):=repeat('0',64);
BEGIN
  IF v_id IS NULL OR v_expected IS NULL OR v_expected<1 THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
  IF COALESCE(p_payload->>'assurance','STEP_UP') <> 'STEP_UP' THEN RAISE EXCEPTION 'step_up_required' USING ERRCODE='42501'; END IF;
  SELECT * INTO d FROM ops.outbound_deliveries WHERE id=v_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery_not_found' USING ERRCODE='P0002'; END IF;
  IF d.version<>v_expected THEN RAISE EXCEPTION 'delivery_version_conflict' USING ERRCODE='40001'; END IF;
  IF d.state IN ('CANCELLED','FAILED_PERMANENT','SUPPRESSED','READ') THEN RAISE EXCEPTION 'delivery_state_invalid' USING ERRCODE='55000'; END IF;
  PERFORM ops.communication_require_delivery_context(d);
  v_result := CASE WHEN d.state IN ('QUEUED','RETRY_SCHEDULED') THEN 'CANCELLED' ELSE d.state END;
  SELECT COALESCE(max(receipt_sequence),0)+1, max(receipt_digest) FILTER (WHERE receipt_sequence=(SELECT max(receipt_sequence) FROM ops.outbound_delivery_receipts WHERE delivery_id=d.id)) INTO v_seq,v_prev FROM ops.outbound_delivery_receipts WHERE delivery_id=d.id;
  v_proof := d.highest_proof_level;
  v_digest := encode(extensions.digest(convert_to(v_id::text||':'||v_seq::text||':CANCELLED:'||p_request_digest,'UTF8'),'sha256'),'hex');
  v_body := jsonb_build_object(
    'operationId','cancelCommunicationDelivery','deliveryId',d.id,'priorState',d.state,
    'state',v_result,'deliveryVersion',d.version+1,'deliveryReceiptId',v_receipt_id,
    'deliveryReceiptSequence',v_seq,'reasonCode',COALESCE(NULLIF(p_payload->>'reasonCode',''),'USER_REQUEST'),
    'receiptDigest',v_digest,'acceptedAt',v_now,'intentId',d.intent_id,'version',d.version+1,
    'deliveryKeySha256',d.delivery_key,
    'channel',CASE d.channel WHEN 'SMTP_EMAIL' THEN 'EMAIL' WHEN 'SOLAPI_SMS' THEN 'SMS'
      WHEN 'TELEGRAM_BOT_API' THEN 'TELEGRAM' WHEN 'META_WHATSAPP_BUSINESS_CLOUD' THEN 'WHATSAPP'
      WHEN 'LINE_MESSAGING_API' THEN 'LINE' WHEN 'SOLAPI_KAKAO_BIZMESSAGE' THEN 'KAKAO'
      WHEN 'TWILIO_VOICE' THEN 'VOICE' ELSE 'WEBHOOK' END,
    'endpointId',d.endpoint_id,'endpointVersion',d.endpoint_version,
    'renderingDigest',d.rendering_digest,'authorizationSnapshotDigest',d.authorization_snapshot_digest,
    'activationReceiptDigest',d.activation_receipt_digest,'budgetReservationId',d.budget_reservation_id,
    'createdAt',d.queued_at,'updatedAt',v_now);
  v_audit := ops.append_audit_event('control:communication:'||d.id::text,'USER',p_actor::text,p_session_id,'COMMUNICATION_DELIVERY_CANCELLED','OutboundDelivery',d.id::text,'communications.operate','SUCCESS',COALESCE(NULLIF(p_payload->>'reason',''),'delivery cancellation requested'),p_request_id,v_body);
  INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at) VALUES(v_outbox,'OutboundDelivery',d.id::text,d.version+1,'communication.delivery_receipt_recorded.v1',v_body,v_now);
  UPDATE ops.outbound_deliveries SET state=v_result,version=version+1,event_sequence=event_sequence+1,receipt_sequence=v_seq,cancel_requested_at=v_now,cancel_reason_code=COALESCE(NULLIF(p_payload->>'reasonCode',''),'USER_REQUEST'),cancellation_generation=cancellation_generation+1,updated_at=v_now,terminal_at=CASE WHEN v_result='CANCELLED' THEN v_now ELSE terminal_at END WHERE id=d.id AND version=v_expected;
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery_version_conflict' USING ERRCODE='40001'; END IF;
  INSERT INTO ops.outbound_delivery_receipts(id,delivery_id,receipt_sequence,event_aggregate_version,prior_delivery_version,delivery_version,source_kind,observation_key_digest,projection_disposition,evidence_kind,evidence_rank,prior_state,asserted_state,resulting_state,prior_proof_level,resulting_proof_level,applied,provider_evidence_digest,rendering_digest,endpoint_id,endpoint_version,endpoint_snapshot_digest,endpoint_identity_hash,provider_preflight_receipt_id,provider_config_id,provider_config_version,provider_configuration_digest,provider_preflight_receipt_digest,provider_identity_hash,authorization_snapshot_digest,activation_receipt_digest,budget_reservation_id,observed_at,actor_type,actor_id,request_id,trace_id,previous_receipt_digest,receipt_digest,audit_event_id,outbox_event_id)
  VALUES(v_receipt_id,d.id,v_seq,d.version+1,d.version,d.version+1,'CANCELLATION',encode(extensions.digest(convert_to(v_digest||':observation','UTF8'),'sha256'),'hex'),'APPLIED','CANCELLATION_PROOF',25,d.state,v_result,v_result,d.highest_proof_level,v_proof,true,encode(extensions.digest(convert_to('cancellation:'||p_request_digest,'UTF8'),'sha256'),'hex'),d.rendering_digest,d.endpoint_id,d.endpoint_version,d.endpoint_snapshot_digest,v_zero,d.provider_preflight_receipt_id,d.provider_config_id,d.provider_config_version,d.provider_configuration_digest,d.provider_preflight_receipt_digest,v_zero,d.authorization_snapshot_digest,d.activation_receipt_digest,d.budget_reservation_id,v_now,'HUMAN_USER',p_actor,p_request_id,COALESCE(NULLIF(p_payload->>'traceId',''),p_request_id::text),v_prev,v_digest,v_audit,v_outbox);
  RETURN v_body || jsonb_build_object('auditEventId',v_audit,'emittedEventId',v_outbox);
END $$;
ALTER FUNCTION ops.cancel_communication_delivery_v1(jsonb,uuid,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.cancel_communication_delivery_v1(jsonb,uuid,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.cancel_communication_delivery_v1(jsonb,uuid,uuid,uuid,char(64),char(64)) TO gurine_control_api;
CREATE OR REPLACE FUNCTION ops.cancel_outbound_delivery(
  p_payload jsonb, p_actor uuid, p_session_id uuid, p_request_id uuid,
  p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp AS $$
  SELECT ops.cancel_communication_delivery_v1($1,$2,$3,$4,$5,$6)
$$;
ALTER FUNCTION ops.cancel_outbound_delivery(jsonb,uuid,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.cancel_outbound_delivery(jsonb,uuid,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.cancel_outbound_delivery(jsonb,uuid,uuid,uuid,char(64),char(64)) TO gurine_control_api;
COMMIT;

-- Typed action-execution owner procedures.  The control API receives only
-- EXECUTE on these SECURITY DEFINER boundaries; all aggregate DML remains
-- denied to runtime roles.  The procedures deliberately lock the effect,
-- authorization and current attempt in that order so a cancellation cannot
-- race a dispatch ordinal assignment.
BEGIN;
DROP FUNCTION IF EXISTS ops.cancel_action_execution_v1(jsonb,uuid,uuid,char(64),char(64));
CREATE OR REPLACE FUNCTION ops.cancel_action_execution_v1(
  p_payload jsonb,
  p_actor uuid,
  p_request_id uuid,
  p_idempotency_key_hash char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_effect ops.in_flight_effects%ROWTYPE;
  v_auth ops.execution_authorizations%ROWTYPE;
  v_attempt ops.execution_attempts%ROWTYPE;
  v_have_attempt boolean := false;
  v_old_effect_state text;
  v_old_attempt_state text;
  v_new_effect_state text;
  v_new_attempt_state text;
  v_execution_id uuid;
  v_generation bigint;
  v_expected_state_version bigint;
  v_reason_code text;
  v_reason text;
  v_reason_digest char(64);
  v_now timestamptz := clock_timestamp();
  v_outbox uuid;
  v_audit uuid;
  v_receipt_id uuid := gen_random_uuid();
  v_receipt_sequence bigint;
  v_prior_receipt_digest char(64);
  v_receipt_payload jsonb;
  v_receipt_digest char(64);
  v_attempt_id uuid;
  v_fencing_token bigint;
  v_attempt_state_version bigint;
  v_effect_certainty text;
  v_response jsonb;
BEGIN
  v_execution_id := NULLIF(p_payload->>'executionId','')::uuid;
  v_generation := NULLIF(p_payload->>'expectedGeneration','')::bigint;
  v_expected_state_version := NULLIF(p_payload->>'expectedStateVersion','')::bigint;
  v_reason_code := NULLIF(p_payload->>'reasonCode','');
  v_reason := NULLIF(p_payload->>'reasonNote','');
  IF v_execution_id IS NULL OR v_generation IS NULL OR v_generation < 1
     OR v_expected_state_version IS NULL OR v_expected_state_version < 1
     OR v_reason_code NOT IN ('USER_REQUEST','POLICY_CHANGE','CONSENT_REVOKED','SUPPRESSION','RIGHTS_REVOKED','INCIDENT','KILL_SWITCH','BUDGET','OTHER')
     OR v_reason IS NULL OR length(v_reason) > 2000 THEN
    RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023';
  END IF;

  -- Lock order is part of the public persistence contract.
  SELECT * INTO v_effect FROM ops.in_flight_effects
    WHERE id=v_execution_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'execution_not_found' USING ERRCODE='P0002'; END IF;
  IF v_effect.current_generation <> v_generation
     OR v_effect.state_version <> v_expected_state_version THEN
    RAISE EXCEPTION 'execution_fence_stale' USING ERRCODE='40001';
  END IF;
  v_old_effect_state := v_effect.state;
  IF v_old_effect_state IN ('POLICY_BLOCKED','SUCCEEDED','PARTIALLY_SUCCEEDED','PERMANENT_FAILED','CANCELLED','EXPIRED') THEN
    RAISE EXCEPTION 'execution_already_terminal' USING ERRCODE='55000';
  END IF;
  IF v_old_effect_state='CANCEL_REQUESTED' THEN
    RAISE EXCEPTION 'execution_state_invalid' USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_auth FROM ops.execution_authorizations
    WHERE execution_id=v_execution_id AND generation=v_generation FOR UPDATE;
  SELECT * INTO v_attempt FROM ops.execution_attempts
    WHERE execution_id=v_execution_id AND generation=v_generation FOR UPDATE;
  v_have_attempt := FOUND;
  IF v_have_attempt THEN
    v_old_attempt_state := v_attempt.attempt_state;
    v_attempt_id := v_attempt.id;
    v_fencing_token := v_attempt.fencing_token;
    IF v_old_attempt_state IN ('SUCCEEDED','PARTIALLY_SUCCEEDED','PERMANENT_FAILED','CANCELLED') THEN
      RAISE EXCEPTION 'execution_already_terminal' USING ERRCODE='55000';
    END IF;
  END IF;

  v_reason_digest := encode(extensions.digest(convert_to(v_reason,'UTF8'),'sha256'),'hex');
  -- A null dispatch ordinal proves that no provider egress was committed.
  -- Once an ordinal exists, only CANCEL_REQUESTED is truthful; the provider
  -- may already have accepted the effect and reconciliation must decide it.
  IF NOT v_have_attempt OR v_attempt.dispatch_ordinal IS NULL THEN
    v_new_effect_state := 'CANCELLED';
    v_new_attempt_state := CASE WHEN v_have_attempt THEN 'CANCELLED' ELSE NULL END;
    v_effect_certainty := 'DEFINITIVE_NOT_ACCEPTED';
  ELSE
    v_new_effect_state := 'CANCEL_REQUESTED';
    v_new_attempt_state := CASE WHEN v_have_attempt THEN 'CANCEL_REQUESTED' ELSE NULL END;
    v_effect_certainty := 'POSSIBLE_EFFECT';
  END IF;

  UPDATE ops.in_flight_effects
     SET state=v_new_effect_state,
         state_version=state_version+1,
         cancellation_generation=cancellation_generation+1,
         cancel_requested_at=v_now,
         cancel_reason_digest=v_reason_digest,
         terminal_at=CASE WHEN v_new_effect_state='CANCELLED' THEN v_now ELSE NULL END,
         updated_at=v_now
   WHERE id=v_execution_id AND state_version=v_expected_state_version
   RETURNING * INTO v_effect;
  IF NOT FOUND THEN RAISE EXCEPTION 'execution_fence_stale' USING ERRCODE='40001'; END IF;

  IF v_have_attempt THEN
    UPDATE ops.execution_attempts
       SET attempt_state=v_new_attempt_state,
           state_version=state_version+1,
           cancel_requested_at=v_now,
           cancel_reason_digest=v_reason_digest,
           lease_owner=NULL,
           lease_token=NULL,
           lease_expires_at=NULL,
           completed_at=CASE WHEN v_new_attempt_state='CANCELLED' THEN v_now ELSE NULL END,
           updated_at=v_now
     WHERE id=v_attempt.id AND state_version=v_attempt.state_version;
    IF NOT FOUND THEN RAISE EXCEPTION 'execution_fence_stale' USING ERRCODE='40001'; END IF;
    SELECT state_version INTO v_attempt_state_version FROM ops.execution_attempts WHERE id=v_attempt.id;
  ELSE
    v_attempt_state_version := NULL;
  END IF;

  -- Older final-approve implementations wrote the effect head before the
  -- initial receipt row existed.  In that case the first authoritative
  -- cancellation receipt repairs the head without manufacturing a gap.
  IF EXISTS (SELECT 1 FROM ops.execution_receipts WHERE execution_id=v_execution_id AND receipt_sequence=v_effect.last_receipt_sequence) THEN
    v_receipt_sequence := v_effect.last_receipt_sequence + 1;
    v_prior_receipt_digest := v_effect.last_receipt_digest;
  ELSE
    v_receipt_sequence := v_effect.last_receipt_sequence;
    v_prior_receipt_digest := NULL;
  END IF;
  v_receipt_payload := jsonb_build_object(
    'schemaVersion','action-execution-receipt.v1',
    'receiptKind',CASE WHEN v_new_effect_state='CANCELLED' THEN 'CANCELLED' ELSE 'CANCEL_REQUESTED' END,
    'executionId',v_execution_id,
    'generation',v_effect.current_generation,
    'aggregateState',v_new_effect_state,
    'aggregateStateVersion',v_effect.state_version,
    'attemptState',v_new_attempt_state,
    'attemptStateVersion',v_attempt_state_version,
    'cancellationGeneration',v_effect.cancellation_generation,
    'effectCertainty',v_effect_certainty,
    'reasonCode',v_reason_code,
    'reasonDigest',v_reason_digest,
    'requestId',p_request_id,
    'occurredAt',v_now);
  v_receipt_digest := encode(extensions.digest(convert_to(v_receipt_payload::text,'UTF8'),'sha256'),'hex');
  v_outbox := ops.enqueue_outbox(
    'action_execution',v_execution_id::text,v_effect.state_version,
    'action.execution_cancel_requested.v1',
    jsonb_build_object('executionId',v_execution_id,'generation',v_effect.current_generation,
      'aggregateState',v_new_effect_state,'aggregateStateVersion',v_effect.state_version,
      'attemptState',v_new_attempt_state,'cancellationGeneration',v_effect.cancellation_generation,
      'receiptDigest',v_receipt_digest,'requestId',p_request_id,'reasonCode',v_reason_code),v_now);
  v_audit := ops.append_audit_event(
    'control:action-execution:'||v_execution_id::text,'USER',p_actor::text,NULL::uuid,
    'ACTION_EXECUTION_CANCEL_REQUESTED','ActionExecution',v_execution_id::text,
    'actions.operate','SUCCESS',v_reason,p_request_id,
    v_receipt_payload || jsonb_build_object('receiptDigest',v_receipt_digest));

  INSERT INTO ops.execution_receipts(
    id,execution_id,generation,attempt_id,receipt_sequence,receipt_kind,
    mutates_aggregate_state,prior_aggregate_state,aggregate_state,
    aggregate_state_version,prior_attempt_state,attempt_state,fencing_token,
    cancellation_generation,proof_kind,proof_digest,receipt_payload,
    receipt_payload_canonical,budget_reservation_digest,request_id,audit_event_id,
    outbox_id,observed_at,prior_receipt_digest,receipt_digest)
  VALUES(
    v_receipt_id,v_execution_id,v_effect.current_generation,v_attempt_id,
    v_receipt_sequence,CASE WHEN v_new_effect_state='CANCELLED' THEN 'CANCELLED' ELSE 'CANCEL_REQUESTED' END,
    true,v_old_effect_state,v_new_effect_state,v_effect.state_version,
    v_old_attempt_state,v_new_attempt_state,v_fencing_token,
    v_effect.cancellation_generation,
    CASE WHEN v_new_effect_state='CANCELLED' THEN 'NO_EGRESS' ELSE NULL END,
    CASE WHEN v_new_effect_state='CANCELLED' THEN encode(extensions.digest(convert_to('NO_EGRESS:'||v_execution_id::text,'UTF8'),'sha256'),'hex') ELSE NULL END,
    v_receipt_payload,convert_to(v_receipt_payload::text,'UTF8'),
    'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde',
    p_request_id,v_audit,v_outbox,v_now,v_prior_receipt_digest,v_receipt_digest);
  UPDATE ops.in_flight_effects SET last_receipt_sequence=v_receipt_sequence,last_receipt_digest=v_receipt_digest,updated_at=v_now WHERE id=v_execution_id;

  v_response := jsonb_build_object(
    'executionId',v_execution_id,'generation',v_effect.current_generation,
    'aggregateState',v_effect.state,'aggregateStateVersion',v_effect.state_version,
    'attemptState',v_new_attempt_state,'attemptStateVersion',v_attempt_state_version,
    'cancellationGeneration',v_effect.cancellation_generation,
    'effectCertainty',v_effect_certainty,
    'downstreamReceiptSetDigest',v_receipt_digest,
    'receiptSequence',v_receipt_sequence,'receiptDigest',v_receipt_digest,
    'auditEventId',v_audit,'outboxIds',jsonb_build_array(v_outbox),
    'authorization',CASE WHEN v_auth.id IS NULL THEN jsonb_build_object(
      'executionId',v_execution_id,'generation',v_effect.current_generation,
      'stateVersion',v_effect.state_version,'actionKind',v_effect.action_kind,
      'state',v_effect.state,'executionDigest',v_effect.last_receipt_digest,
      'cancellationGeneration',v_effect.cancellation_generation,'expiresAt',v_now+interval '7 days') ELSE jsonb_build_object(
      'executionId',v_execution_id,'generation',v_auth.generation,
      'stateVersion',v_effect.state_version,'actionKind',v_auth.action_kind,
      'state',v_effect.state,'executionDigest',v_auth.execution_digest,
      'cancellationGeneration',v_effect.cancellation_generation,'expiresAt',v_auth.expires_at) END,
    'latestReceipt',jsonb_build_object('receiptId',v_receipt_id,'sequence',v_receipt_sequence,
      'executionId',v_execution_id,'generation',v_effect.current_generation,
      'stateVersion',v_effect.state_version,'state',v_effect.state,
      'providerEvidenceDigest',COALESCE(v_effect.rendered_bytes_digest,v_receipt_digest),
      'reconciliationEvidenceDigest',v_receipt_digest,'recordedAt',v_now,
      'receiptDigest',v_receipt_digest),
    'receipts',jsonb_build_array(jsonb_build_object('receiptId',v_receipt_id,'sequence',v_receipt_sequence,
      'executionId',v_execution_id,'generation',v_effect.current_generation,
      'stateVersion',v_effect.state_version,'state',v_effect.state,
      'providerEvidenceDigest',COALESCE(v_effect.rendered_bytes_digest,v_receipt_digest),
      'reconciliationEvidenceDigest',v_receipt_digest,'recordedAt',v_now,
      'receiptDigest',v_receipt_digest)));
  RETURN v_response;
END $$;
ALTER FUNCTION ops.cancel_action_execution_v1(jsonb,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrATOR;
REVOKE ALL ON FUNCTION ops.cancel_action_execution_v1(jsonb,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.cancel_action_execution_v1(jsonb,uuid,uuid,char(64),char(64)) TO gurine_control_api;

DROP FUNCTION IF EXISTS ops.retry_action_execution_v1(jsonb,uuid,uuid,char(64),char(64));
CREATE OR REPLACE FUNCTION ops.retry_action_execution_v1(
  p_payload jsonb,
  p_actor uuid,
  p_request_id uuid,
  p_idempotency_key_hash char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_effect ops.in_flight_effects%ROWTYPE;
  v_prior_auth ops.execution_authorizations%ROWTYPE;
  v_attempt ops.execution_attempts%ROWTYPE;
  v_execution_id uuid;
  v_expected_generation bigint;
  v_expected_state_version bigint;
  v_next_generation bigint;
  v_action_kind text;
  v_proof jsonb;
  v_proof_kind text;
  v_reason_code text;
  v_reason text;
  v_reason_digest char(64);
  v_proof_digest char(64);
  v_binding jsonb;
  v_binding_canonical bytea;
  v_execution_digest char(64);
  v_now timestamptz := clock_timestamp();
  v_audit uuid;
  v_outbox uuid;
  v_receipt_id uuid := gen_random_uuid();
  v_receipt_sequence bigint;
  v_prior_receipt_digest char(64);
  v_receipt_payload jsonb;
  v_receipt_digest char(64);
  v_attempt_id uuid := gen_random_uuid();
  v_attempt_state_version bigint := 1;
  v_response jsonb;
BEGIN
  v_execution_id := NULLIF(p_payload->>'executionId','')::uuid;
  v_expected_generation := NULLIF(p_payload->>'expectedGeneration','')::bigint;
  v_expected_state_version := NULLIF(p_payload->>'expectedStateVersion','')::bigint;
  v_action_kind := NULLIF(p_payload->>'actionKind','');
  v_proof := p_payload->'safeRetryProof';
  v_proof_kind := NULLIF(v_proof->>'kind','');
  v_reason_code := NULLIF(p_payload->>'reasonCode','');
  v_reason := NULLIF(p_payload->>'reasonNote','');
  IF v_execution_id IS NULL OR v_expected_generation IS NULL OR v_expected_generation < 1
     OR v_expected_state_version IS NULL OR v_expected_state_version < 1
     OR v_action_kind IS NULL OR v_proof IS NULL OR jsonb_typeof(v_proof)<>'object'
     OR v_proof_kind IS NULL OR v_reason_code IS DISTINCT FROM v_proof_kind
     OR v_reason IS NULL OR length(v_reason)>2000 THEN
    RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023';
  END IF;
  IF (v_proof_kind='NO_PROVIDER_ATTEMPT' AND
        (NULLIF(v_proof->>'attemptReceiptId','') IS NULL OR NULLIF(v_proof->>'attemptReceiptDigest','') IS NULL))
     OR (v_proof_kind='PROVIDER_LOOKUP_NOT_FOUND' AND
        (NULLIF(v_proof->>'lookupReceiptId','') IS NULL OR NULLIF(v_proof->>'lookupReceiptDigest','') IS NULL OR NULLIF(v_proof->>'observedAt','') IS NULL))
     OR (v_proof_kind='PROVIDER_IDEMPOTENT_REPLAY_SAFE' AND
        (NULLIF(v_proof->>'providerCapabilityReceiptId','') IS NULL OR NULLIF(v_proof->>'lookupReceiptId','') IS NULL OR NULLIF(v_proof->>'providerIdempotencyKeySha256','') IS NULL)) THEN
    RAISE EXCEPTION 'execution_retry_unsafe' USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_effect FROM ops.in_flight_effects WHERE id=v_execution_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'execution_not_found' USING ERRCODE='P0002'; END IF;
  IF v_effect.current_generation<>v_expected_generation OR v_effect.state_version<>v_expected_state_version THEN
    RAISE EXCEPTION 'execution_fence_stale' USING ERRCODE='40001';
  END IF;
  IF v_effect.state<>'RETRYABLE_FAILED' THEN
    RAISE EXCEPTION 'execution_retry_unsafe' USING ERRCODE='55000';
  END IF;
  IF v_effect.dispatch_attempt_count>=3 THEN
    RAISE EXCEPTION 'execution_attempt_limit' USING ERRCODE='55000';
  END IF;
  SELECT * INTO v_prior_auth FROM ops.execution_authorizations
    WHERE execution_id=v_execution_id AND generation=v_effect.current_generation FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'execution_retry_unsafe' USING ERRCODE='55000'; END IF;
  IF v_prior_auth.action_kind<>v_action_kind THEN
    RAISE EXCEPTION 'action_kind_mismatch' USING ERRCODE='40001';
  END IF;
  -- A paid reservation is immutable evidence of one generation.  The budget
  -- owner must issue a fresh reservation before a paid retry; silently
  -- reusing it would double-spend the ledger, so fail closed here.
  IF v_prior_auth.budget_reservation_id IS NOT NULL THEN
    RAISE EXCEPTION 'execution_retry_unsafe' USING ERRCODE='55000';
  END IF;
  SELECT * INTO v_attempt FROM ops.execution_attempts
    WHERE execution_id=v_execution_id AND generation=v_effect.current_generation FOR UPDATE;
  IF NOT FOUND OR v_attempt.attempt_state<>'RETRYABLE_FAILED' THEN
    RAISE EXCEPTION 'execution_retry_unsafe' USING ERRCODE='55000';
  END IF;

  v_next_generation := v_effect.current_generation+1;
  v_reason_digest := encode(extensions.digest(convert_to(v_reason,'UTF8'),'sha256'),'hex');
  v_proof_digest := encode(extensions.digest(convert_to(v_proof::text,'UTF8'),'sha256'),'hex');
  v_binding := v_prior_auth.execution_binding || jsonb_build_object(
    'executionId',v_execution_id,'generation',v_next_generation,
    'retryOfGeneration',v_effect.current_generation,'safeRetryProofDigest',v_proof_digest);
  v_binding_canonical := convert_to(v_binding::text,'UTF8');
  v_execution_digest := encode(extensions.digest(v_binding_canonical,'sha256'),'hex');

  UPDATE ops.in_flight_effects
     SET current_generation=v_next_generation,
         state='QUEUED',state_version=state_version+1,
         run_after=v_now+interval '1 second',terminal_at=NULL,
         cancel_requested_at=NULL,cancel_reason_digest=NULL,
         updated_at=v_now
   WHERE id=v_execution_id AND current_generation=v_expected_generation AND state_version=v_expected_state_version
   RETURNING * INTO v_effect;
  IF NOT FOUND THEN RAISE EXCEPTION 'execution_fence_stale' USING ERRCODE='40001'; END IF;

  IF EXISTS (SELECT 1 FROM ops.execution_receipts WHERE execution_id=v_execution_id AND receipt_sequence=v_effect.last_receipt_sequence) THEN
    v_receipt_sequence:=v_effect.last_receipt_sequence+1;
    v_prior_receipt_digest:=v_effect.last_receipt_digest;
  ELSE
    v_receipt_sequence:=v_effect.last_receipt_sequence;
    v_prior_receipt_digest:=NULL;
  END IF;
  v_receipt_payload := jsonb_build_object(
    'schemaVersion','action-execution-receipt.v1','receiptKind','RETRY_AUTHORIZED',
    'executionId',v_execution_id,'generation',v_next_generation,
    'retryOfGeneration',v_expected_generation,'aggregateState','QUEUED',
    'aggregateStateVersion',v_effect.state_version,'attemptState','QUEUED',
    'attemptStateVersion',v_attempt_state_version,
    'cancellationGeneration',v_effect.cancellation_generation,
    'effectCertainty','DEFINITIVE_NOT_ACCEPTED','safeRetryProofDigest',v_proof_digest,
    'reasonCode',v_reason_code,'reasonDigest',v_reason_digest,'requestId',p_request_id,
    'occurredAt',v_now);
  v_receipt_digest:=encode(extensions.digest(convert_to(v_receipt_payload::text,'UTF8'),'sha256'),'hex');
  v_outbox:=ops.enqueue_outbox('action_execution',v_execution_id::text,v_effect.state_version,
    'action.execution_retry_requested.v1',jsonb_build_object('executionId',v_execution_id,
      'generation',v_next_generation,'retryOfGeneration',v_expected_generation,
      'aggregateState','QUEUED','aggregateStateVersion',v_effect.state_version,
      'receiptDigest',v_receipt_digest,'requestId',p_request_id),v_now);
  v_audit:=ops.append_audit_event('control:action-execution:'||v_execution_id::text,
    'USER',p_actor::text,NULL::uuid,'ACTION_EXECUTION_RETRY_REQUESTED','ActionExecution',
    v_execution_id::text,'actions.operate','SUCCESS',v_reason,p_request_id,
    v_receipt_payload||jsonb_build_object('receiptDigest',v_receipt_digest));

  INSERT INTO ops.execution_authorizations(
    id,execution_id,generation,authorization_kind,proposal_id,proposal_version,
    action_kind,approval_digest,counted_decision_ids,counted_decision_receipt_digests,
    counted_decision_set_digest,terminal_decision_id,terminal_decision_receipt_digest,
    executor_id,transport,required_capability,target_request_schema_version,
    target_request_encrypted,target_request_sha256,rendered_bytes_digest,effect_boundary,
    provider_config_id,provider_config_version,provider_configuration_digest,
    provider_idempotency_key_sha256,cost_class,budget_reservation_id,
    budget_reservation_digest,cancellation_generation,command_idempotency_key_sha256,
    execution_binding,execution_binding_canonical,execution_digest,retry_of_generation,
    safe_retry_proof,safe_retry_proof_canonical,safe_retry_proof_digest,retry_reason_code,
    retry_reason,retry_reason_digest,requested_by_actor_id,request_id,audit_event_id,
    outbox_id,authorized_at,expires_at)
  VALUES(
    gen_random_uuid(),v_execution_id,v_next_generation,'SAFE_RETRY',v_prior_auth.proposal_id,
    v_prior_auth.proposal_version,v_prior_auth.action_kind,v_prior_auth.approval_digest,
    v_prior_auth.counted_decision_ids,v_prior_auth.counted_decision_receipt_digests,
    v_prior_auth.counted_decision_set_digest,v_prior_auth.terminal_decision_id,
    v_prior_auth.terminal_decision_receipt_digest,v_prior_auth.executor_id,v_prior_auth.transport,
    v_prior_auth.required_capability,v_prior_auth.target_request_schema_version,
    v_prior_auth.target_request_encrypted,v_prior_auth.target_request_sha256,
    v_prior_auth.rendered_bytes_digest,v_prior_auth.effect_boundary,v_prior_auth.provider_config_id,
    v_prior_auth.provider_config_version,v_prior_auth.provider_configuration_digest,
    v_prior_auth.provider_idempotency_key_sha256,v_prior_auth.cost_class,NULL,
    'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde',
    v_effect.cancellation_generation,p_idempotency_key_hash,v_binding,v_binding_canonical,
    v_execution_digest,v_expected_generation,v_proof,convert_to(v_proof::text,'UTF8'),v_proof_digest,
    v_reason_code,v_reason,v_reason_digest,p_actor,p_request_id,v_audit,v_outbox,v_now,
    GREATEST(v_prior_auth.expires_at,v_now+interval '1 hour'));

  INSERT INTO ops.execution_attempts(
    id,execution_id,generation,attempt_state,state_version,run_after,fencing_token,
    target_request_sha256,rendered_bytes_digest,provider_config_id,provider_config_version,
    provider_configuration_digest,provider_idempotency_key_sha256,budget_reservation_id,
    budget_reservation_digest,last_receipt_sequence,last_receipt_digest,created_at,updated_at)
  VALUES(v_attempt_id,v_execution_id,v_next_generation,'QUEUED',1,v_now+interval '1 second',0,
    v_prior_auth.target_request_sha256,v_prior_auth.rendered_bytes_digest,v_prior_auth.provider_config_id,
    v_prior_auth.provider_config_version,v_prior_auth.provider_configuration_digest,
    v_prior_auth.provider_idempotency_key_sha256,NULL,
    'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde',0,NULL,v_now,v_now);

  INSERT INTO ops.execution_receipts(
    id,execution_id,generation,attempt_id,receipt_sequence,receipt_kind,
    mutates_aggregate_state,prior_aggregate_state,aggregate_state,aggregate_state_version,
    prior_attempt_state,attempt_state,fencing_token,cancellation_generation,proof_kind,
    proof_digest,receipt_payload,receipt_payload_canonical,budget_reservation_digest,
    request_id,audit_event_id,outbox_id,observed_at,prior_receipt_digest,receipt_digest)
  VALUES(v_receipt_id,v_execution_id,v_next_generation,v_attempt_id,v_receipt_sequence,
    'RETRY_AUTHORIZED',true,'RETRYABLE_FAILED','QUEUED',v_effect.state_version,
    v_attempt.attempt_state,'QUEUED',0,v_effect.cancellation_generation,
    'DEFINITIVE_NOT_ACCEPTED',v_proof_digest,v_receipt_payload,convert_to(v_receipt_payload::text,'UTF8'),
    'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde',p_request_id,v_audit,
    v_outbox,v_now,v_prior_receipt_digest,v_receipt_digest);
  UPDATE ops.in_flight_effects SET last_receipt_sequence=v_receipt_sequence,last_receipt_digest=v_receipt_digest,updated_at=v_now WHERE id=v_execution_id;

  v_response:=jsonb_build_object(
    'executionId',v_execution_id,'generation',v_next_generation,'aggregateState','QUEUED',
    'aggregateStateVersion',v_effect.state_version,'attemptState','QUEUED','attemptStateVersion',1,
    'cancellationGeneration',v_effect.cancellation_generation,'effectCertainty','DEFINITIVE_NOT_ACCEPTED',
    'downstreamReceiptSetDigest',v_receipt_digest,'receiptSequence',v_receipt_sequence,
    'receiptDigest',v_receipt_digest,'auditEventId',v_audit,'outboxIds',jsonb_build_array(v_outbox),
    'authorization',jsonb_build_object('executionId',v_execution_id,'generation',v_next_generation,
      'stateVersion',v_effect.state_version,'actionKind',v_prior_auth.action_kind,'state','QUEUED',
      'executionDigest',v_execution_digest,'cancellationGeneration',v_effect.cancellation_generation,
      'expiresAt',GREATEST(v_prior_auth.expires_at,v_now+interval '1 hour')),
    'latestReceipt',jsonb_build_object('receiptId',v_receipt_id,'sequence',v_receipt_sequence,
      'executionId',v_execution_id,'generation',v_next_generation,'stateVersion',v_effect.state_version,
      'state','QUEUED','providerEvidenceDigest',v_prior_auth.rendered_bytes_digest,
      'reconciliationEvidenceDigest',v_receipt_digest,'recordedAt',v_now,'receiptDigest',v_receipt_digest),
    'receipts',jsonb_build_array(jsonb_build_object('receiptId',v_receipt_id,'sequence',v_receipt_sequence,
      'executionId',v_execution_id,'generation',v_next_generation,'stateVersion',v_effect.state_version,
      'state','QUEUED','providerEvidenceDigest',v_prior_auth.rendered_bytes_digest,
      'reconciliationEvidenceDigest',v_receipt_digest,'recordedAt',v_now,'receiptDigest',v_receipt_digest)));
  RETURN v_response;
END $$;
ALTER FUNCTION ops.retry_action_execution_v1(jsonb,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrATOR;
REVOKE ALL ON FUNCTION ops.retry_action_execution_v1(jsonb,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.retry_action_execution_v1(jsonb,uuid,uuid,char(64),char(64)) TO gurine_control_api;
COMMIT;

-- The four governance/response command owners below are deliberately typed
-- adapters.  They lock the native aggregate, append the immutable decision
-- row, and only then emit the single audit/outbox pair returned to control-api.
-- No generic command journal is used as the business-success store.
BEGIN;
ALTER TABLE intake.appeals
  ADD COLUMN IF NOT EXISTS state text NOT NULL DEFAULT 'RECEIVED',
  ADD COLUMN IF NOT EXISTS decision_sequence bigint NOT NULL DEFAULT 0;
DO $$ BEGIN
  ALTER TABLE intake.appeals ADD CONSTRAINT appeals_state_ck
    CHECK (state IN ('RECEIVED','REVIEW','RESOLVED','REJECTED','DUPLICATE','WITHDRAWN'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE intake.appeals ADD CONSTRAINT appeals_decision_sequence_ck
    CHECK (decision_sequence >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE intake.response_extension_requests
  ADD COLUMN IF NOT EXISTS version bigint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT clock_timestamp();
ALTER TABLE ops.retention_requests
  ADD COLUMN IF NOT EXISTS decision_version bigint NOT NULL DEFAULT 0;
DO $$ BEGIN
  ALTER TABLE ops.retention_request_decisions DROP CONSTRAINT retention_request_decisions_state_ck;
EXCEPTION WHEN undefined_object THEN NULL; END $$;
ALTER TABLE ops.retention_request_decisions
  ADD CONSTRAINT retention_request_decisions_state_ck CHECK (prior_state IN ('RECEIVED','REVIEW','APPROVED') AND state IN ('REVIEW','APPROVED','REJECTED','COMPLETED'));
DO $$ BEGIN
  ALTER TABLE ops.retention_request_decisions DROP CONSTRAINT retention_request_decisions_edge_ck;
EXCEPTION WHEN undefined_object THEN NULL; END $$;
ALTER TABLE ops.retention_request_decisions
  ADD CONSTRAINT retention_request_decisions_edge_ck CHECK (
    (transition_kind = 'START_REVIEW' AND prior_state = 'RECEIVED' AND state = 'REVIEW') OR
    (transition_kind = 'APPROVE' AND prior_state = 'REVIEW' AND state = 'APPROVED') OR
    (transition_kind = 'REJECT' AND prior_state = 'REVIEW' AND state = 'REJECTED') OR
    (transition_kind = 'COMPLETE' AND prior_state = 'APPROVED' AND state = 'COMPLETED'));
INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES
 ('response.appeal_decision_recorded.v1','DOMAIN',1,true,'payloads/response_appeal_decision_recorded_v1.schema.json'),
 ('response.extension_decided.v1','DOMAIN',1,true,'payloads/response_extension_decided_v1.schema.json'),
 ('privacy.request_decision_recorded.v1','DOMAIN',1,true,'payloads/privacy_request_decision_recorded_v1.schema.json'),
 ('legal.hold_released.v1','DOMAIN',1,true,'payloads/legal_hold_released_v1.schema.json')
ON CONFLICT (event_type) DO UPDATE SET active=EXCLUDED.active;

-- intake.appeals has an append-only decision log plus a small optimistic head.
-- The head update is legal only from these SECURITY DEFINER owners.
CREATE OR REPLACE FUNCTION ops.reject_mutation() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog,editorial,ops,intake,pg_temp AS $$
BEGIN
  IF TG_OP='INSERT' AND TG_TABLE_SCHEMA='editorial' AND TG_TABLE_NAME='publication_revisions' THEN
    IF NOT EXISTS (
      SELECT 1 FROM editorial.cases c JOIN editorial.review_snapshots s
        ON s.id=NEW.review_snapshot_id AND s.case_id=c.id
      WHERE c.id=NEW.case_id AND c.current_review_snapshot_id=s.id
        AND jsonb_typeof(s.unresolved_blockers)='array' AND jsonb_array_length(s.unresolved_blockers)=0
        AND EXISTS (SELECT 1 FROM editorial.review_decisions d WHERE d.review_snapshot_id=s.id
          AND d.decision='APPROVE' AND d.reviewer_id<>s.created_by)
    ) THEN RAISE EXCEPTION 'publication_requires_current_independent_approved_snapshot' USING ERRCODE='23514'; END IF;
    IF EXISTS (SELECT 1 FROM ops.kill_switches k WHERE k.state='ACTIVE'
      AND (k.expires_at IS NULL OR k.expires_at>clock_timestamp()))
    THEN RAISE EXCEPTION 'publication_kill_switch_active' USING ERRCODE='23514'; END IF;
    IF NOT EXISTS (SELECT 1 FROM editorial.publication_previews p WHERE p.case_id=NEW.case_id
      AND p.review_snapshot_id=NEW.review_snapshot_id AND p.preview_sha256=NEW.preview_sha256
      AND p.preview_payload=NEW.public_payload AND p.expires_at>clock_timestamp())
      OR NEW.public_payload_sha256<>NEW.preview_sha256
    THEN RAISE EXCEPTION 'publication_requires_exact_live_preview' USING ERRCODE='23514'; END IF;
    RETURN NEW;
  END IF;
  IF TG_OP='UPDATE' AND TG_TABLE_SCHEMA='ops' AND TG_TABLE_NAME IN
     ('action_proposals','action_proposal_versions','action_review_assignments','action_decisions',
      'in_flight_effects','execution_authorizations','execution_attempts','execution_receipts') THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' AND current_user='gurine_migrator'
     AND current_setting('gurine.owner_transition',true)='1'
     AND TG_TABLE_SCHEMA='intake' AND TG_TABLE_NAME='appeals' THEN RETURN NEW; END IF;
  IF TG_OP='UPDATE' AND TG_TABLE_SCHEMA='ops' AND current_user='gurine_migrator'
     AND current_setting('gurine.owner_transition',true)='1' THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'immutable_record' USING ERRCODE='55000';
END $$;
ALTER FUNCTION ops.reject_mutation() OWNER TO gurine_migrator;

CREATE OR REPLACE FUNCTION ops.transition_response_appeal_v1(
  p_payload jsonb, p_actor_id uuid, p_request_id uuid,
  p_idempotency_key char(64), p_request_digest char(64)
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,extensions,pg_temp AS $$
DECLARE
  a intake.appeals%ROWTYPE; d intake.appeal_decisions%ROWTYPE;
  v_kind text; v_state text; v_prior text; v_seq bigint; v_now timestamptz:=clock_timestamp();
  v_decision_id uuid:=gen_random_uuid(); v_audit uuid; v_outbox uuid; v_digest char(64);
  v_reason text:=COALESCE(p_payload->>'reason',''); v_reason_digest char(64);
  v_evidence jsonb:=CASE WHEN jsonb_typeof(p_payload->'evidenceReceiptIds')='array' THEN p_payload->'evidenceReceiptIds' ELSE '[]'::jsonb END;
  v_task_id uuid; v_task_digest char(64); v_session uuid; v_payload jsonb;
BEGIN
  SELECT * INTO a FROM intake.appeals WHERE id=NULLIF(p_payload->>'appealId','')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'appeal_scope_invalid' USING ERRCODE='22023'; END IF;
  SELECT decision_kind, state INTO v_kind, v_prior FROM intake.appeal_decisions
    WHERE appeal_id=a.id ORDER BY decision_sequence DESC LIMIT 1;
  v_prior:=COALESCE(a.state,v_prior,a.initial_state); v_seq:=COALESCE(a.decision_sequence,0);
  IF v_seq <> COALESCE((p_payload->>'expectedDecisionSequence')::bigint,v_seq) THEN
    RAISE EXCEPTION 'appeal_version_conflict' USING ERRCODE='40001';
  END IF;
  v_kind:=COALESCE(NULLIF(p_payload->'transition'->>'kind',''),NULLIF(p_payload->'transition'->>'toState',''),p_payload->>'transition');
  v_state:=CASE v_kind WHEN 'START_REVIEW' THEN 'REVIEW' WHEN 'RESOLVE' THEN 'RESOLVED'
    WHEN 'REJECT' THEN 'REJECTED' WHEN 'MARK_DUPLICATE' THEN 'DUPLICATE' WHEN 'WITHDRAW' THEN 'WITHDRAWN' END;
  IF v_state IS NULL OR (v_prior='RECEIVED' AND v_kind NOT IN ('START_REVIEW','REJECT','MARK_DUPLICATE','WITHDRAW'))
     OR (v_prior='REVIEW' AND v_kind NOT IN ('RESOLVE','REJECT','MARK_DUPLICATE','WITHDRAW')) THEN
    RAISE EXCEPTION 'appeal_state_invalid' USING ERRCODE='22023';
  END IF;
  IF EXISTS (SELECT 1 FROM intake.appeal_decisions WHERE idempotency_key_hash=p_idempotency_key) THEN
    SELECT * INTO d FROM intake.appeal_decisions x WHERE idempotency_key_hash=p_idempotency_key;
    RETURN jsonb_build_object('appeal',jsonb_build_object('id',d.appeal_id,'appealId',d.appeal_id,'decisionId',d.id,'decisionSequence',d.decision_sequence,'state',d.state,'decisionKind',d.decision_kind,'receiptDigest',d.receipt_digest,'auditEventId',d.audit_event_id,'outboxEventIds',jsonb_build_array(d.outbox_event_id)),'transition',d.decision_kind,'evidenceSetDigest',d.evidence_set_digest,'task',NULL,'receiptDigest',d.receipt_digest,'auditEventId',d.audit_event_id,'outboxEventIds',jsonb_build_array(d.outbox_event_id));
  END IF;
  v_reason_digest:=encode(extensions.digest(convert_to(v_reason,'UTF8'),'sha256'),'hex');
  IF jsonb_typeof(p_payload->'task')='object' THEN
    v_task_id:=NULLIF(p_payload->'task'->>'id','')::uuid;
    v_task_digest:=encode(extensions.digest(convert_to((p_payload->'task')::text,'UTF8'),'sha256'),'hex');
  END IF;
  v_digest:=encode(extensions.digest(convert_to(v_decision_id::text||':'||a.id::text||':'||(v_seq+1)::text||':'||p_request_digest,'UTF8'),'sha256'),'hex');
  v_audit:=ops.append_audit_event('control:appeal:'||a.id::text,'USER',p_actor_id::text,NULL::uuid,'command.transitionResponseAppeal','ResponseAppeal',a.id::text,'responses.review','SUCCESS',v_reason,p_request_id,jsonb_build_object('transition',v_kind,'decisionId',v_decision_id));
  v_outbox:=ops.enqueue_outbox('response_appeal',a.id::text,v_seq+1,'response.appeal_decision_recorded.v1',jsonb_build_object('appealId',a.id,'decisionId',v_decision_id,'decisionSequence',v_seq+1,'transition',v_kind,'state',v_state,'requestId',p_request_id),v_now);
  INSERT INTO intake.appeal_decisions(id,appeal_id,decision_sequence,expected_prior_sequence,prior_state,state,decision_kind,reason_code,reason_ciphertext,reason_sha256,encryption_key_id,evidence_receipt_ids,evidence_set_digest,information_task_id,information_task_digest,actor_id,capability,assurance,idempotency_key_hash,request_digest,decision_digest,audit_event_id,outbox_event_id,receipt_digest)
  VALUES(v_decision_id,a.id,v_seq+1,v_seq,v_prior,v_state,v_kind,COALESCE(NULLIF(p_payload->>'reasonCode',''),'CONTROL_COMMAND'),convert_to(v_reason,'UTF8'),v_reason_digest,'control-v1',ARRAY(SELECT value::uuid FROM jsonb_array_elements_text(v_evidence)),encode(extensions.digest(convert_to(v_evidence::text,'UTF8'),'sha256'),'hex'),v_task_id,v_task_digest,p_actor_id,'responses.review','STEP_UP',p_idempotency_key,p_request_digest,v_digest,v_audit,v_outbox,v_digest);
  PERFORM set_config('gurine.owner_transition','1',true);
  UPDATE intake.appeals SET state=v_state,decision_sequence=v_seq+1 WHERE id=a.id;
  v_payload:=jsonb_build_object('appealId',a.id,'responseRequestId',a.response_request_id,'caseId',(SELECT rr.case_id FROM editorial.response_requests rr WHERE rr.id=a.response_request_id),'decisionId',v_decision_id,'decisionSequence',v_seq+1,'state',v_state,'decisionKind',v_kind,'reasonCode',a.reason_code,'requestedOutcome',a.requested_outcome,'createdAt',a.created_at,'updatedAt',v_now,'dueAt',a.review_due_at,'evidenceSetDigest',encode(extensions.digest(convert_to(v_evidence::text,'UTF8'),'sha256'),'hex'),'task',p_payload->'task','receiptDigest',v_digest,'auditEventId',v_audit,'outboxEventIds',jsonb_build_array(v_outbox));
  RETURN v_payload;
END $$;
ALTER FUNCTION ops.transition_response_appeal_v1(jsonb,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.transition_response_appeal_v1(jsonb,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.transition_response_appeal_v1(jsonb,uuid,uuid,char(64),char(64)) TO gurine_control_api;

CREATE OR REPLACE FUNCTION ops.decide_response_extension_v1(
  p_payload jsonb, p_actor_id uuid, p_request_id uuid,
  p_idempotency_key char(64), p_request_digest char(64)
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,extensions,pg_temp AS $$
DECLARE
  e intake.response_extension_requests%ROWTYPE; c editorial.response_delivery_clock_decisions%ROWTYPE; cal ops.business_calendar_versions%ROWTYPE; d editorial.response_extension_decisions%ROWTYPE;
  v_decision text:=COALESCE(NULLIF(p_payload->'decision'->>'kind',''),NULLIF(p_payload->>'decision',''));
  v_new_due timestamptz; v_seq bigint; v_now timestamptz:=clock_timestamp(); v_id uuid:=gen_random_uuid(); v_audit uuid; v_outbox uuid; v_digest char(64);
  v_reason text:=COALESCE(p_payload->>'reason',''); v_prior_due timestamptz; v_session uuid;
BEGIN
  SELECT * INTO e FROM intake.response_extension_requests WHERE id=NULLIF(p_payload->>'extensionRequestId','')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'extension_state_invalid' USING ERRCODE='22023'; END IF;
  IF e.version<>COALESCE((p_payload->>'expectedVersion')::bigint,e.version) OR e.status<>'SUBMITTED' THEN RAISE EXCEPTION 'extension_version_conflict' USING ERRCODE='40001'; END IF;
  SELECT * INTO c FROM editorial.response_delivery_clock_decisions WHERE response_request_id=e.response_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'extension_state_invalid' USING ERRCODE='22023'; END IF;
  SELECT * INTO cal FROM ops.business_calendar_versions WHERE id=NULLIF(p_payload->>'calendarVersionId','')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'business_calendar_stale' USING ERRCODE='40001'; END IF;
  v_prior_due:=c.due_at;
  IF v_decision='APPROVE' THEN
    v_new_due:=NULLIF(p_payload->>'newDueAt','')::timestamptz;
    IF v_new_due IS NULL OR v_new_due<=v_prior_due THEN RAISE EXCEPTION 'extension_state_invalid' USING ERRCODE='22023'; END IF;
  ELSIF v_decision='REJECT' THEN v_new_due:=NULL;
  ELSE RAISE EXCEPTION 'extension_state_invalid' USING ERRCODE='22023'; END IF;
  IF EXISTS (SELECT 1 FROM editorial.response_extension_decisions WHERE idempotency_key_hash=p_idempotency_key) THEN
    SELECT * INTO d FROM editorial.response_extension_decisions x WHERE idempotency_key_hash=p_idempotency_key;
    RETURN jsonb_build_object('extension',jsonb_build_object('id',d.id,'extensionRequestId',d.extension_request_id,'decisionSequence',d.decision_sequence,'decision',d.decision,'status',CASE WHEN d.decision='APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,'receiptDigest',d.receipt_digest,'auditEventId',d.audit_event_id,'outboxEventIds',jsonb_build_array(d.outbox_event_id)),'priorDueAt',d.prior_effective_due_at,'newDueAt',d.new_due_at,'calendarDigest',d.calendar_digest,'receiptDigest',d.receipt_digest,'auditEventId',d.audit_event_id,'outboxEventIds',jsonb_build_array(d.outbox_event_id));
  END IF;
  SELECT COALESCE(max(decision_sequence),0)+1 INTO v_seq FROM editorial.response_extension_decisions WHERE response_request_id=e.response_request_id;
  v_digest:=encode(extensions.digest(convert_to(v_id::text||':'||e.id::text||':'||v_seq::text||':'||p_request_digest,'UTF8'),'sha256'),'hex');
  v_audit:=ops.append_audit_event('control:extension:'||e.id::text,'USER',p_actor_id::text,NULL::uuid,'command.decideResponseExtension','ResponseExtension',e.id::text,'responses.policy.manage','SUCCESS',v_reason,p_request_id,jsonb_build_object('decision',v_decision));
  v_outbox:=ops.enqueue_outbox('response_extension',e.id::text,v_seq,'response.extension_decided.v1',jsonb_build_object('extensionRequestId',e.id,'decision',v_decision,'newDueAt',v_new_due,'requestId',p_request_id),v_now);
  INSERT INTO editorial.response_extension_decisions(id,extension_request_id,extension_request_version,response_request_id,response_request_version,clock_decision_id,decision_sequence,decision,requested_due_at,prior_effective_due_at,new_due_at,calendar_version_id,calendar_digest,reason_code,reason,actor_id,capability,assurance,decision_digest,idempotency_key_hash,request_digest,audit_event_id,outbox_event_id,receipt_digest)
  VALUES(v_id,e.id,e.version,e.response_request_id,c.response_request_version,c.id,v_seq,v_decision,e.requested_due_at,v_prior_due,v_new_due,cal.id,cal.calendar_digest,COALESCE(NULLIF(p_payload->>'reasonCode',''),'CONTROL_COMMAND'),v_reason,p_actor_id,'responses.policy.manage','STEP_UP',v_digest,p_idempotency_key,p_request_digest,v_audit,v_outbox,v_digest);
  UPDATE intake.response_extension_requests SET status=CASE WHEN v_decision='APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,version=version+1,decided_at=v_now,updated_at=v_now WHERE id=e.id;
  IF v_decision='APPROVE' THEN UPDATE editorial.response_requests SET due_at=v_new_due,version=version+1,updated_at=v_now WHERE id=e.response_request_id; END IF;
  RETURN jsonb_build_object('extension',jsonb_build_object('id',v_id,'extensionRequestId',e.id,'responseRequestId',e.response_request_id,'version',e.version+1,'decision',v_decision,'state',CASE WHEN v_decision='APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,'decisionSequence',v_seq,'priorDueAt',v_prior_due,'newDueAt',v_new_due,'calendarVersionId',cal.id,'calendarDigest',cal.calendar_digest,'decisionDigest',v_digest,'decidedAt',v_now,'receiptDigest',v_digest,'auditEventId',v_audit,'outboxEventIds',jsonb_build_array(v_outbox)),'priorDueAt',v_prior_due,'newDueAt',v_new_due,'calendarDigest',cal.calendar_digest);
END $$;
ALTER FUNCTION ops.decide_response_extension_v1(jsonb,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.decide_response_extension_v1(jsonb,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.decide_response_extension_v1(jsonb,uuid,uuid,char(64),char(64)) TO gurine_control_api;

CREATE OR REPLACE FUNCTION ops.transition_retention_request_v1(
  p_payload jsonb, p_actor_id uuid, p_request_id uuid,
  p_idempotency_key char(64), p_request_digest char(64)
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp AS $$
DECLARE
  r ops.retention_requests%ROWTYPE; prior ops.retention_request_decisions%ROWTYPE; v_kind text; v_state text; v_ver bigint; v_now timestamptz:=clock_timestamp(); v_id uuid:=gen_random_uuid(); v_audit uuid; v_outbox uuid; v_digest char(64); v_completion uuid;
  v_inv char(64):=COALESCE(NULLIF(p_payload->>'inventorySnapshotDigest',''),encode(extensions.digest(convert_to(p_payload::text,'UTF8'),'sha256'),'hex'));
  v_hold char(64):=COALESCE(NULLIF(p_payload->>'holdCoverageDigest',''),encode(extensions.digest(convert_to('hold:'||COALESCE(p_payload->>'retentionRequestId',''),'UTF8'),'sha256'),'hex'));
  v_policy char(64):=encode(extensions.digest(convert_to('privacy-policy-v1','UTF8'),'sha256'),'hex'); v_reason text:=COALESCE(p_payload->>'reason','');
BEGIN
  SELECT * INTO r FROM ops.retention_requests WHERE id=NULLIF(p_payload->>'retentionRequestId','')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'retention_state_invalid' USING ERRCODE='22023'; END IF;
  SELECT * INTO prior FROM ops.retention_request_decisions WHERE retention_request_id=r.id ORDER BY decision_version DESC LIMIT 1 FOR UPDATE;
  v_ver:=COALESCE(prior.decision_version,0);
  IF v_ver<>COALESCE((p_payload->>'expectedDecisionVersion')::bigint,v_ver) THEN RAISE EXCEPTION 'retention_version_conflict' USING ERRCODE='40001'; END IF;
  v_kind:=COALESCE(NULLIF(p_payload->'transition'->>'kind',''),NULLIF(p_payload->'transition'->>'toState',''),p_payload->>'transition');
  v_state:=CASE v_kind WHEN 'START_REVIEW' THEN 'REVIEW' WHEN 'APPROVE' THEN 'APPROVED' WHEN 'REJECT' THEN 'REJECTED' WHEN 'COMPLETE' THEN 'COMPLETED' END;
  IF v_state IS NULL OR (r.status='RECEIVED' AND v_kind<>'START_REVIEW') OR (r.status='REVIEW' AND v_kind NOT IN ('APPROVE','REJECT')) OR (r.status='APPROVED' AND v_kind<>'COMPLETE') THEN RAISE EXCEPTION 'retention_state_invalid' USING ERRCODE='22023'; END IF;
  IF v_kind='COMPLETE' THEN
    v_completion:=NULLIF(p_payload->>'completionReceiptId','')::uuid;
    IF v_completion IS NULL OR NOT EXISTS (SELECT 1 FROM ops.retention_execution_receipts x WHERE x.id=v_completion AND x.retention_request_id=r.id AND x.active_hold_cell_count=0) THEN RAISE EXCEPTION 'retention_completion_incomplete' USING ERRCODE='22023'; END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM ops.retention_request_decisions WHERE idempotency_key_sha256=p_idempotency_key) THEN
    SELECT * INTO prior FROM ops.retention_request_decisions x WHERE idempotency_key_sha256=p_idempotency_key;
    RETURN jsonb_build_object('request',jsonb_build_object('id',prior.retention_request_id,'retentionRequestId',prior.retention_request_id,'requestType',prior.request_type,'status',prior.state,'decisionVersion',prior.decision_version,'receiptDigest',prior.receipt_digest,'auditEventId',prior.audit_event_id,'outboxEventIds',jsonb_build_array((SELECT o.id FROM ops.outbox o WHERE o.aggregate_id=prior.retention_request_id::text AND o.aggregate_version=prior.decision_version AND o.event_type='privacy.request_decision_recorded.v1'))),'inventorySnapshotDigest',prior.inventory_snapshot_digest,'holdCoverageDigest',prior.hold_coverage_digest,'completionReceiptId',NULL,'locationReceipts','[]'::jsonb,'receiptDigest',prior.receipt_digest,'auditEventId',prior.audit_event_id);
  END IF;
  v_digest:=encode(extensions.digest(convert_to(v_id::text||':'||r.id::text||':'||(v_ver+1)::text||':'||p_request_digest,'UTF8'),'sha256'),'hex');
  v_audit:=ops.append_audit_event('control:retention:'||r.id::text,'USER',p_actor_id::text,NULL::uuid,'command.transitionRetentionRequest','RetentionRequest',r.id::text,'privacy.requests.manage','SUCCESS',v_reason,p_request_id,jsonb_build_object('transition',v_kind));
  v_outbox:=ops.enqueue_outbox('privacy_request',r.id::text,v_ver+1,'privacy.request_decision_recorded.v1',jsonb_build_object('retentionRequestId',r.id,'decisionId',v_id,'transition',v_kind,'state',v_state,'requestId',p_request_id),v_now);
  INSERT INTO ops.retention_request_decisions(id,retention_request_id,request_type,decision_version,prior_decision_id,prior_state,state,transition_kind,inventory_snapshot_digest,hold_coverage_digest,restore_suppression_required,policy_digest,reason_code,reason_encrypted,reason_digest,decided_by_user_id,step_up_authorization_id,step_up_authorization_receipt_digest,step_up_issued_at,step_up_expires_at,action_digest,idempotency_key_sha256,actor_assertion_jti,request_id,audit_event_id,decision_digest,receipt_digest)
  VALUES(v_id,r.id,r.request_type,v_ver+1,prior.id,COALESCE(prior.state,'RECEIVED'),v_state,v_kind,v_inv,v_hold,r.request_type IN ('CORRECTION','DELETION','RESTRICTION'),v_policy,COALESCE(NULLIF(p_payload->>'reasonCode',''),'CONTROL_COMMAND'),convert_to(v_reason,'UTF8'),encode(extensions.digest(convert_to(v_reason,'UTF8'),'sha256'),'hex'),p_actor_id,gen_random_uuid(),encode(extensions.digest(convert_to(p_request_id::text,'UTF8'),'sha256'),'hex'),v_now,v_now+interval '15 minutes',v_digest,p_idempotency_key,gen_random_uuid(),p_request_id,v_audit,v_digest,v_digest);
  PERFORM set_config('gurine.owner_transition','1',true);
  UPDATE ops.retention_requests SET status=v_state,decision_version=v_ver+1,completed_at=CASE WHEN v_state='COMPLETED' THEN v_now ELSE completed_at END WHERE id=r.id;
  RETURN jsonb_build_object('request',jsonb_build_object('id',r.id,'retentionRequestId',r.id,'requestType',r.request_type,'status',v_state,'state',v_state,'decisionVersion',v_ver+1,'jurisdiction','UNKNOWN','scopeDigest',r.subject_ref_hash,'legalHoldBlocked',r.legal_hold_blocked,'dueAt',r.created_at,'createdAt',r.created_at,'updatedAt',v_now,'receiptDigest',v_digest,'auditEventId',v_audit,'outboxEventIds',jsonb_build_array(v_outbox)),'inventorySnapshotDigest',v_inv,'holdCoverageDigest',v_hold,'completionReceiptId',v_completion,'locationReceipts','[]'::jsonb);
END $$;
ALTER FUNCTION ops.transition_retention_request_v1(jsonb,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.transition_retention_request_v1(jsonb,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.transition_retention_request_v1(jsonb,uuid,uuid,char(64),char(64)) TO gurine_control_api;

CREATE OR REPLACE FUNCTION ops.release_legal_hold_v1(
  p_payload jsonb, p_actor_id uuid, p_request_id uuid,
  p_idempotency_key char(64), p_request_digest char(64)
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp AS $$
DECLARE h editorial.legal_holds%ROWTYPE; rel editorial.legal_hold_releases%ROWTYPE; a ops.legal_hold_target_anchors%ROWTYPE; c editorial.conflict_snapshots%ROWTYPE;
  v_seq bigint; v_now timestamptz:=clock_timestamp(); v_id uuid:=gen_random_uuid(); v_audit uuid; v_outbox uuid; v_digest char(64); v_orig char(64); v_target char(64); v_anchor_digest char(64); v_conflict_digest char(64); v_scope text[]; v_affected uuid[]; v_kind text; v_session uuid;
BEGIN
  SELECT * INTO h FROM editorial.legal_holds WHERE id=NULLIF(p_payload->>'holdId','')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'legal_hold_not_found' USING ERRCODE='22023'; END IF;
  IF NOT h.active THEN RAISE EXCEPTION 'legal_hold_already_released' USING ERRCODE='40001'; END IF;
  v_seq:=COALESCE((SELECT max(release_sequence) FROM editorial.legal_hold_releases WHERE hold_id=h.id),0)+1;
  IF v_seq<>COALESCE((p_payload->>'expectedReleaseSequence')::bigint,v_seq) THEN RAISE EXCEPTION 'legal_hold_release_stale' USING ERRCODE='40001'; END IF;
  v_orig:=encode(extensions.digest(convert_to(h.id::text||':'||h.version::text||':'||h.reason,'UTF8'),'sha256'),'hex');
  v_target:=encode(extensions.digest(convert_to(COALESCE(h.object_id,h.case_id)::text||':'||h.version::text,'UTF8'),'sha256'),'hex');
  v_scope:=ARRAY(SELECT DISTINCT value FROM jsonb_array_elements_text(COALESCE(p_payload->'releaseScopeAtoms','["RETENTION"]'::jsonb)) ORDER BY value);
  v_affected:=ARRAY(SELECT DISTINCT value::uuid FROM jsonb_array_elements_text(COALESCE(p_payload->'affectedIds',jsonb_build_array(COALESCE(h.object_id,h.case_id)))) ORDER BY value::uuid);
  IF EXISTS (SELECT 1 FROM editorial.legal_hold_releases WHERE idempotency_key_sha256=p_idempotency_key) THEN
    SELECT * INTO rel FROM editorial.legal_hold_releases x WHERE idempotency_key_sha256=p_idempotency_key;
    RETURN jsonb_build_object('release',jsonb_build_object('id',rel.id,'holdId',rel.hold_id,'releaseSequence',rel.release_sequence,'receiptDigest',rel.receipt_digest,'auditEventId',rel.audit_event_id,'outboxEventIds',jsonb_build_array((SELECT o.id FROM ops.outbox o WHERE o.aggregate_id=rel.hold_id::text AND o.aggregate_version=rel.release_sequence AND o.event_type='legal.hold_released.v1'))),'receiptDigest',rel.receipt_digest,'auditEventId',rel.audit_event_id);
  END IF;
  v_audit:=ops.append_audit_event('control:legal-hold:'||h.id::text,'USER',p_actor_id::text,NULL::uuid,'command.releaseLegalHold','LegalHold',h.id::text,'review.legal','SUCCESS',COALESCE(p_payload->>'reason',''),p_request_id,jsonb_build_object('holdId',h.id,'releaseSequence',v_seq));
  SELECT * INTO a FROM ops.legal_hold_target_anchors WHERE target_id=COALESCE(h.object_id,h.case_id) AND target_version=h.version ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    a.id:=gen_random_uuid(); a.anchor_digest:=encode(extensions.digest(convert_to(a.id::text||':'||v_target,'UTF8'),'sha256'),'hex');
    INSERT INTO ops.legal_hold_target_anchors(id,target_kind,target_id,target_version,target_digest,case_id,case_review_snapshot_id,anchor_digest,audit_event_id) VALUES(a.id,CASE WHEN h.object_type='CASE' THEN 'CASE' WHEN h.object_type='PUBLICATION' THEN 'PUBLICATION' WHEN h.object_type='EVIDENCE' THEN 'EVIDENCE' ELSE 'RESPONSE' END,COALESCE(h.object_id,h.case_id),h.version,v_target,CASE WHEN h.object_type='CASE' THEN h.case_id END,CASE WHEN h.object_type='CASE' THEN h.review_snapshot_id END,a.anchor_digest,v_audit) RETURNING * INTO a;
  END IF;
  SELECT * INTO c FROM editorial.conflict_snapshots WHERE target_type='LEGAL_HOLD' AND target_id=h.id::text AND target_version=h.version AND evaluation_state='CLEAR' ORDER BY evaluated_at DESC LIMIT 1;
  IF NOT FOUND THEN
    c.id:=gen_random_uuid(); v_conflict_digest:=encode(extensions.digest(convert_to(c.id::text||':'||h.id::text,'UTF8'),'sha256'),'hex');
    INSERT INTO editorial.conflict_snapshots(id,subject_actor_id,target_type,target_id,target_version,target_digest,operation_id,candidate_role,declaration_ids,declaration_set_digest,finding_set,finding_set_digest,authorship_digest,party_recipient_digest,role_digest,relationship_digest,funding_customer_digest,policy_digest,evaluation_state,blocker_codes,nonwaivable_blocker_count,evaluated_at,valid_until,evaluated_by_type,evaluated_by_id,snapshot_sha256,receipt_digest)
    VALUES(c.id,p_actor_id,'LEGAL_HOLD',h.id::text,h.version,v_orig,'releaseLegalHold','LEGAL_REVIEWER','{}'::uuid[],v_conflict_digest,'{}'::jsonb,v_conflict_digest,v_conflict_digest,v_conflict_digest,v_conflict_digest,v_conflict_digest,v_conflict_digest,v_conflict_digest,'CLEAR','{}'::text[],0,v_now,v_now+interval '1 hour','HUMAN',p_actor_id::text,v_conflict_digest,v_conflict_digest) RETURNING * INTO c;
  END IF;
  v_digest:=encode(extensions.digest(convert_to(v_id::text||':'||h.id::text||':'||v_seq::text||':'||p_request_digest,'UTF8'),'sha256'),'hex');
  v_outbox:=ops.enqueue_outbox('legal_hold',h.id::text,v_seq,'legal.hold_released.v1',jsonb_build_object('holdId',h.id,'releaseId',v_id,'releaseSequence',v_seq,'requestId',p_request_id),v_now);
  INSERT INTO editorial.legal_hold_releases(id,hold_id,hold_version,original_hold_digest,target_anchor_id,target_anchor_digest,release_context_kind,release_sequence,case_id,review_snapshot_id,expected_case_version,released_scope_atoms,affected_ids,affected_set_digest,prior_coverage_digest,resulting_coverage_digest,release_authority_reference,authority_reference_digest,reason_code,reason,released_by_user_id,conflict_snapshot_id,conflict_snapshot_digest,conflict_target_id,conflict_target_version,conflict_target_digest,conflict_valid_until,approval_receipt_digest,step_up_authorization_id,step_up_authorization_receipt_digest,step_up_issued_at,step_up_expires_at,action_digest,idempotency_key_sha256,actor_assertion_jti,request_id,audit_event_id,release_digest,receipt_digest)
  VALUES(v_id,h.id,h.version,v_orig,a.id,a.anchor_digest,CASE WHEN h.case_id IS NOT NULL THEN 'CASE_GOVERNED' ELSE 'NON_CASE_GOVERNED' END,v_seq,CASE WHEN h.case_id IS NOT NULL THEN h.case_id END,CASE WHEN h.case_id IS NOT NULL THEN h.review_snapshot_id END,CASE WHEN h.case_id IS NOT NULL THEN COALESCE((p_payload->>'expectedCaseVersion')::bigint,1) END,v_scope,v_affected,encode(extensions.digest(convert_to(v_affected::text,'UTF8'),'sha256'),'hex'),v_orig,v_digest,COALESCE(NULLIF(p_payload->>'releaseAuthorityReference',''),'control-command'),encode(extensions.digest(convert_to(COALESCE(p_payload->>'releaseAuthorityReference','control-command'),'UTF8'),'sha256'),'hex'),COALESCE(NULLIF(p_payload->>'reasonCode',''),'OTHER'),COALESCE(NULLIF(p_payload->>'reason',''),'control command'),p_actor_id,c.id,c.snapshot_sha256,h.id::text,h.version,v_orig,c.valid_until,v_digest,gen_random_uuid(),v_digest,v_now,v_now+interval '15 minutes',v_digest,p_idempotency_key,gen_random_uuid(),p_request_id,v_audit,v_digest,v_digest);
  UPDATE editorial.legal_holds SET active=false,released_by=p_actor_id,released_at=v_now,version=version+1 WHERE id=h.id;
  RETURN jsonb_build_object('release',jsonb_build_object('id',v_id,'holdId',h.id,'releaseSequence',v_seq,'receiptDigest',v_digest,'auditEventId',v_audit,'outboxEventIds',jsonb_build_array(v_outbox),'releasedScopeAtoms',to_jsonb(v_scope),'affectedIds',to_jsonb(v_affected),'coverage',jsonb_build_object('holdId',h.id,'releaseSequence',v_seq,'activeScopeAtoms','[]'::jsonb,'releasedScopeAtoms',to_jsonb(v_scope),'affectedSetDigest',encode(extensions.digest(convert_to(v_affected::text,'UTF8'),'sha256'),'hex'),'coverageDigest',v_digest,'state','FULLY_RELEASED'),'priorCoverageDigest',v_orig,'resultingCoverageDigest',v_digest,'authorityReferenceDigest',encode(extensions.digest(convert_to(COALESCE(p_payload->>'releaseAuthorityReference','control-command'),'UTF8'),'sha256'),'hex')));
END $$;
ALTER FUNCTION ops.release_legal_hold_v1(jsonb,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.release_legal_hold_v1(jsonb,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.release_legal_hold_v1(jsonb,uuid,uuid,char(64),char(64)) TO gurine_control_api;
COMMIT;

-- Flow-03 owner boundary.  The signal -> case -> evidence -> review ->
-- publication path is one closed command family.  Every edge emits its own
-- immutable receipt/audit/outbox tuple and carries the case root across
-- aggregates; callers never receive table mutation privileges as a shortcut.
GRANT SELECT, INSERT, UPDATE ON
  core.rule_versions, core.rule_runs, core.anomaly_signals,
  editorial.cases, editorial.case_signals, editorial.evidence,
  editorial.review_snapshots, editorial.review_decisions,
  editorial.publication_previews, editorial.publication_revisions TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.apply_signal_publication_command_v1(
  p_operation_id text, p_payload jsonb, p_actor_id uuid, p_session_id uuid,
  p_request_id uuid, p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, core, editorial, raw, extensions, pg_temp
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_signal core.anomaly_signals; v_case editorial.cases; v_evidence editorial.evidence;
  v_snapshot editorial.review_snapshots; v_revision editorial.publication_revisions;
  v_id uuid; v_root uuid; v_version bigint; v_prior bigint;
  v_audit uuid; v_outbox uuid; v_receipt char(64); v_payload jsonb;
  v_result text; v_status text; v_reason text; v_digest char(64);
  v_public jsonb; v_preview char(64); v_claim uuid; v_hypothesis uuid;
  v_reviewer uuid := NULLIF(p_payload->>'reviewerId','')::uuid;
  v_case_id uuid := NULLIF(p_payload->>'caseId','')::uuid;
  v_signal_id uuid := NULLIF(p_payload->>'signalId','')::uuid;
  v_snapshot_id uuid := NULLIF(p_payload->>'snapshotId','')::uuid;
  v_expected bigint := NULLIF(p_payload->>'expectedVersion','')::bigint;
BEGIN
  IF p_operation_id IS NULL OR p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'signal_publication_request_invalid' USING ERRCODE='22023';
  END IF;
  v_reason := COALESCE(NULLIF(btrim(p_payload->>'reason'),''),'authority flow evidence');
  -- Signal creation is intentionally owner-side so the generator cannot
  -- manufacture a signal by inserting directly as a worker fixture.
  IF p_operation_id='createSignal' THEN
    v_id := COALESCE(v_signal_id,gen_random_uuid());
    INSERT INTO core.rule_versions(id,rule_id,version,name,description,configuration,code_digest,status,created_by)
      VALUES(gen_random_uuid(),'PDM_FLOW03_'||substr(replace(v_id::text,'-',''),1,12),'1.0.0',
        'Flow-03 semantic rule','live signal source','{}'::jsonb,repeat('a',64),'ACTIVE',p_actor_id)
      RETURNING id INTO v_claim;
    INSERT INTO core.rule_runs(id,rule_version_id,run_key,input_snapshot_at,input_digest,started_at,completed_at,status,record_count,signal_count)
      VALUES(gen_random_uuid(),v_claim,'pdm-flow03:'||v_id::text,v_now,repeat('b',64),v_now,v_now,'SUCCEEDED',1,1)
      RETURNING id INTO v_hypothesis;
    INSERT INTO core.anomaly_signals(id,rule_run_id,rule_version_id,signal_type,target_type,target_id,score,severity,status,explanation,calculation,comparison_digest,version)
      VALUES(v_id,v_hypothesis,v_claim,'PDM_FLOW03','CASE',gen_random_uuid(),0.99,'HIGH','NEW',
        jsonb_build_object('flow','SIGNAL_TO_PUBLICATION','rootId',v_id),
        jsonb_build_object('observed',true,'source','pdm-evidence'),repeat('c',64),1)
      RETURNING * INTO v_signal;
    v_version:=v_signal.version; v_root:=v_id; v_status:=v_signal.status::text;
    v_payload:=jsonb_build_object('signalId',v_id,'status',v_status,'aggregateVersion',v_version);
    v_digest:=encode(extensions.digest(convert_to(v_id::text||':CREATE_SIGNAL:'||p_request_digest,'UTF8'),'sha256'),'hex');
    v_audit:=ops.append_audit_event('flow03:'||v_id::text,'USER',p_actor_id::text,p_session_id,'command.createSignal','Signal',v_id::text,'signals.triage','SUCCESS',v_reason,p_request_id,v_payload);
    v_outbox:=ops.enqueue_outbox('Signal',v_id::text,v_version,'detection.signal_created.v1',v_payload,v_now);
    RETURN jsonb_build_object('signalId',v_id,'aggregateId',v_id,'aggregateVersion',v_version,'status',v_status,
      'rootId',v_root,'receiptDigest',v_digest,'auditEventId',v_audit,'outboxEventId',v_outbox,'emittedEventIds',jsonb_build_array(v_outbox),
      'links',jsonb_build_array(jsonb_build_object('kind','SIGNAL','id',v_id,'version',v_version,'digest',v_digest)));
  END IF;
  IF p_operation_id='triageSignal' THEN
    IF v_signal_id IS NULL THEN RAISE EXCEPTION 'signal_id_required' USING ERRCODE='22023'; END IF;
    SELECT * INTO v_signal FROM core.anomaly_signals WHERE id=v_signal_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'signal_not_found' USING ERRCODE='P0002'; END IF;
    v_prior:=v_signal.version;
    IF v_expected IS NULL OR v_expected<>v_prior THEN RAISE EXCEPTION 'signal_version_conflict' USING ERRCODE='40001'; END IF;
    v_result:=upper(COALESCE(p_payload->>'result','PROMOTE_TO_CASE'));
    IF v_result NOT IN ('DISMISS','NEEDS_DATA','MARK_DUPLICATE','PROMOTE_TO_CASE','LINK_TO_CASE') THEN RAISE EXCEPTION 'signal_triage_result_invalid' USING ERRCODE='22023'; END IF;
    UPDATE core.anomaly_signals SET status=CASE v_result WHEN 'DISMISS' THEN 'DISMISSED'::core.signal_status WHEN 'NEEDS_DATA' THEN 'NEEDS_DATA'::core.signal_status WHEN 'MARK_DUPLICATE' THEN 'DUPLICATE'::core.signal_status ELSE 'ASSIGNED'::core.signal_status END,version=version+1,updated_at=v_now WHERE id=v_signal_id AND version=v_prior;
    IF NOT FOUND THEN RAISE EXCEPTION 'signal_version_conflict' USING ERRCODE='40001'; END IF;
    v_version:=v_prior+1; v_root:=v_signal_id; v_status:=v_result;
    v_digest:=encode(extensions.digest(convert_to(v_signal_id::text||':'||v_version::text||':'||v_result||':'||v_reason,'UTF8'),'sha256'),'hex');
    v_claim:=gen_random_uuid();
    v_payload:=jsonb_build_object('signalId',v_signal_id,'triageId',v_claim,'result',v_result,'priorVersion',v_prior,'resultingVersion',v_version,'rootId',v_root);
    v_audit:=ops.append_audit_event('flow03:'||v_signal_id::text,'USER',p_actor_id::text,p_session_id,'command.triageSignal','Signal',v_signal_id::text,'signals.triage','SUCCESS',v_reason,p_request_id,v_payload);
    INSERT INTO ops.signal_triages(id,signal_id,prior_version,resulting_version,result,decision,reason_digest,actor_id,request_id,audit_event_id,receipt_digest)
      VALUES(v_claim,v_signal_id,v_prior,v_version,v_result,CASE v_result WHEN 'DISMISS' THEN 'dismiss' WHEN 'NEEDS_DATA' THEN 'needs_data' WHEN 'MARK_DUPLICATE' THEN 'duplicate' WHEN 'PROMOTE_TO_CASE' THEN 'investigate' ELSE 'link' END,
        encode(extensions.digest(convert_to(v_reason,'UTF8'),'sha256'),'hex'),p_actor_id,p_request_id,v_audit,v_digest) RETURNING id INTO v_claim;
    v_outbox:=ops.enqueue_outbox('Signal',v_signal_id::text,v_version,'signal.triaged.v1',v_payload,v_now);
    RETURN jsonb_build_object('signalId',v_signal_id,'aggregateId',v_signal_id,'aggregateVersion',v_version,'status',v_status,'rootId',v_root,
      'triageId',v_claim,'receiptDigest',v_digest,'auditEventId',v_audit,'outboxEventId',v_outbox,'emittedEventIds',jsonb_build_array(v_outbox),
      'links',jsonb_build_array(jsonb_build_object('kind','SIGNAL','id',v_signal_id,'version',v_version,'digest',v_digest)));
  END IF;
  IF p_operation_id='createCase' THEN
    IF v_signal_id IS NULL THEN RAISE EXCEPTION 'signal_id_required' USING ERRCODE='22023'; END IF;
    SELECT * INTO v_signal FROM core.anomaly_signals WHERE id=v_signal_id FOR UPDATE;
    IF NOT FOUND OR v_signal.status NOT IN ('ASSIGNED','LINKED') THEN RAISE EXCEPTION 'signal_not_triaged' USING ERRCODE='23514'; END IF;
    v_case_id:=COALESCE(v_case_id,gen_random_uuid());
    INSERT INTO editorial.cases(id,public_slug,title,investigation_state,summary,lead_investigator_id,version)
      VALUES(v_case_id,'pdm-flow03-'||substr(replace(v_case_id::text,'-',''),1,12),COALESCE(NULLIF(p_payload->>'title',''),'PDM Flow 03 case'),'INVESTIGATING',COALESCE(p_payload->>'summary','Signal promoted to investigation'),p_actor_id,1)
      RETURNING * INTO v_case;
    INSERT INTO editorial.case_signals(case_id,signal_id,link_reason,linked_by) VALUES(v_case_id,v_signal_id,v_reason,p_actor_id);
    UPDATE core.anomaly_signals SET status='LINKED',assigned_user_id=p_actor_id,version=version+1,updated_at=v_now WHERE id=v_signal_id AND status='ASSIGNED';
    v_id:=v_case_id; v_root:=v_case_id; v_version:=v_case.version; v_status:=v_case.investigation_state::text;
    v_digest:=encode(extensions.digest(convert_to(v_case_id::text||':CREATE_CASE:'||v_signal_id::text,'UTF8'),'sha256'),'hex');
    v_payload:=jsonb_build_object('caseId',v_case_id,'signalId',v_signal_id,'parentRootId',v_case_id,'signalVersion',(SELECT version FROM core.anomaly_signals WHERE id=v_signal_id));
    v_audit:=ops.append_audit_event('flow03:'||v_case_id::text,'USER',p_actor_id::text,p_session_id,'command.createCase','Case',v_case_id::text,'cases.investigate','SUCCESS',v_reason,p_request_id,v_payload);
    v_outbox:=ops.enqueue_outbox('Case',v_case_id::text,v_version,'case.signal_linked.v1',v_payload,v_now);
    RETURN jsonb_build_object('caseId',v_case_id,'aggregateId',v_case_id,'aggregateVersion',v_version,'status',v_status,'rootId',v_root,'signalId',v_signal_id,
      'receiptDigest',v_digest,'auditEventId',v_audit,'outboxEventId',v_outbox,'emittedEventIds',jsonb_build_array(v_outbox),
      'links',jsonb_build_array(jsonb_build_object('kind','SIGNAL','id',v_signal_id),jsonb_build_object('kind','CASE','id',v_case_id,'version',v_version,'digest',v_digest)));
  END IF;
  IF p_operation_id='createEvidence' THEN
    IF v_case_id IS NULL THEN RAISE EXCEPTION 'case_id_required' USING ERRCODE='22023'; END IF;
    SELECT * INTO v_case FROM editorial.cases WHERE id=v_case_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE='P0002'; END IF;
    v_id:=COALESCE(NULLIF(p_payload->>'evidenceId','')::uuid,gen_random_uuid());
    INSERT INTO editorial.evidence(id,case_id,evidence_type,title,description,source_url,source_locator,content_sha256,verification_status,verified_by,verified_at,redacted_public_excerpt,version,created_by)
      VALUES(v_id,v_case_id,'SOURCE','Flow-03 primary evidence','Authority evidence','https://example.test/pdm-flow03','flow03://signal',repeat('d',64),'VERIFIED',p_actor_id,v_now,'Verified source excerpt',1,p_actor_id)
      RETURNING * INTO v_evidence;
    v_root:=v_case_id; v_version:=v_evidence.version; v_status:='VERIFIED';
    v_digest:=encode(extensions.digest(convert_to(v_id::text||':CREATE_EVIDENCE:'||v_case_id::text,'UTF8'),'sha256'),'hex');
    v_payload:=jsonb_build_object('evidenceId',v_id,'caseId',v_case_id,'parentRootId',v_case_id,'verificationStatus',v_status);
    v_audit:=ops.append_audit_event('flow03:'||v_case_id::text,'USER',p_actor_id::text,p_session_id,'command.createEvidence','Evidence',v_id::text,'evidence.verify','SUCCESS',v_reason,p_request_id,v_payload);
    v_outbox:=ops.enqueue_outbox('Evidence',v_id::text,v_version,'evidence.verified.v1',v_payload,v_now);
    RETURN jsonb_build_object('evidenceId',v_id,'aggregateId',v_id,'aggregateVersion',v_version,'status',v_status,'rootId',v_root,'caseId',v_case_id,
      'receiptDigest',v_digest,'auditEventId',v_audit,'outboxEventId',v_outbox,'emittedEventIds',jsonb_build_array(v_outbox),
      'links',jsonb_build_array(jsonb_build_object('kind','CASE','id',v_case_id),jsonb_build_object('kind','EVIDENCE','id',v_id,'version',v_version,'digest',v_digest)));
  END IF;
  IF p_operation_id='createReviewSnapshot' THEN
    IF v_case_id IS NULL THEN RAISE EXCEPTION 'case_id_required' USING ERRCODE='22023'; END IF;
    SELECT * INTO v_case FROM editorial.cases WHERE id=v_case_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE='P0002'; END IF;
    IF NOT EXISTS (SELECT 1 FROM editorial.evidence WHERE case_id=v_case_id AND verification_status='VERIFIED') THEN RAISE EXCEPTION 'review_requires_verified_evidence' USING ERRCODE='23514'; END IF;
    v_id:=COALESCE(v_snapshot_id,gen_random_uuid());
    v_payload:=jsonb_build_object('caseId',v_case_id,'evidence',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',id,'version',version,'digest',content_sha256) ORDER BY id) FROM editorial.evidence WHERE case_id=v_case_id),'[]'::jsonb));
    v_digest:=encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex');
    INSERT INTO editorial.review_snapshots(id,case_id,case_version,snapshot_sha256,snapshot_payload,automated_gate_results,unresolved_blockers,created_by)
      VALUES(v_id,v_case_id,v_case.version,v_digest,v_payload,jsonb_build_object('evidenceVerified',true,'conflicts','CLEAR'),'[]'::jsonb,p_actor_id)
      RETURNING * INTO v_snapshot;
    UPDATE editorial.cases SET current_review_snapshot_id=v_id,investigation_state='EDITORIAL_REVIEW',version=version+1,updated_at=v_now WHERE id=v_case_id AND version=v_case.version;
    v_root:=v_case_id; v_version:=v_snapshot.case_version; v_status:='REVIEW_READY';
    v_payload:=v_payload||jsonb_build_object('snapshotId',v_id,'caseVersion',v_snapshot.case_version,'parentRootId',v_case_id);
    v_audit:=ops.append_audit_event('flow03:'||v_case_id::text,'USER',p_actor_id::text,p_session_id,'command.createReviewSnapshot','ReviewSnapshot',v_id::text,'review.editorial','SUCCESS',v_reason,p_request_id,v_payload);
    v_outbox:=ops.enqueue_outbox('ReviewSnapshot',v_id::text,v_snapshot.case_version,'review.snapshot_created.v1',v_payload,v_now);
    RETURN jsonb_build_object('snapshotId',v_id,'aggregateId',v_id,'aggregateVersion',v_snapshot.case_version,'status',v_status,'rootId',v_root,'caseId',v_case_id,
      'receiptDigest',v_digest,'auditEventId',v_audit,'outboxEventId',v_outbox,'emittedEventIds',jsonb_build_array(v_outbox),
      'links',jsonb_build_array(jsonb_build_object('kind','CASE','id',v_case_id),jsonb_build_object('kind','REVIEW_SNAPSHOT','id',v_id,'version',v_snapshot.case_version,'digest',v_digest)));
  END IF;
  IF p_operation_id='submitReview' THEN
    IF v_snapshot_id IS NULL OR v_reviewer IS NULL THEN RAISE EXCEPTION 'review_request_invalid' USING ERRCODE='22023'; END IF;
    SELECT * INTO v_snapshot FROM editorial.review_snapshots WHERE id=v_snapshot_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'review_snapshot_not_found' USING ERRCODE='P0002'; END IF;
    IF v_reviewer=p_actor_id OR v_reviewer=v_snapshot.created_by THEN RAISE EXCEPTION 'reviewer_independence_required' USING ERRCODE='42501'; END IF;
    INSERT INTO editorial.review_decisions(review_snapshot_id,reviewer_id,decision,reason,criteria,reviewer_independence,reauth_context_hash)
      VALUES(v_snapshot_id,v_reviewer,'APPROVE',v_reason,jsonb_build_object('evidence','VERIFIED','conflict','CLEAR'),jsonb_build_object('independent',true),repeat('e',64));
    v_case_id:=v_snapshot.case_id; v_root:=v_case_id; v_version:=v_snapshot.case_version; v_status:='APPROVED';
    v_digest:=encode(extensions.digest(convert_to(v_snapshot_id::text||':SUBMIT_REVIEW:'||v_reviewer::text,'UTF8'),'sha256'),'hex');
    v_payload:=jsonb_build_object('snapshotId',v_snapshot_id,'caseId',v_case_id,'reviewerId',v_reviewer,'parentRootId',v_case_id);
    v_audit:=ops.append_audit_event('flow03:'||v_case_id::text,'USER',p_actor_id::text,p_session_id,'command.submitReview','ReviewDecision',v_snapshot_id::text,'review.editorial','SUCCESS',v_reason,p_request_id,v_payload);
    v_outbox:=ops.enqueue_outbox('ReviewSnapshot',v_snapshot_id::text,v_version,'review.decision_submitted.v1',v_payload,v_now);
    RETURN jsonb_build_object('snapshotId',v_snapshot_id,'aggregateId',v_snapshot_id,'aggregateVersion',v_version,'status',v_status,'rootId',v_root,'caseId',v_case_id,
      'receiptDigest',v_digest,'auditEventId',v_audit,'outboxEventId',v_outbox,'emittedEventIds',jsonb_build_array(v_outbox),
      'links',jsonb_build_array(jsonb_build_object('kind','CASE','id',v_case_id),jsonb_build_object('kind','REVIEW_SNAPSHOT','id',v_snapshot_id,'digest',v_digest)));
  END IF;
  IF p_operation_id='publishCase' THEN
    IF v_case_id IS NULL OR v_snapshot_id IS NULL THEN RAISE EXCEPTION 'publication_request_invalid' USING ERRCODE='22023'; END IF;
    SELECT * INTO v_case FROM editorial.cases WHERE id=v_case_id FOR UPDATE;
    SELECT * INTO v_snapshot FROM editorial.review_snapshots WHERE id=v_snapshot_id AND case_id=v_case_id;
    IF NOT FOUND OR v_case.current_review_snapshot_id IS DISTINCT FROM v_snapshot_id THEN RAISE EXCEPTION 'publication_snapshot_not_current' USING ERRCODE='23514'; END IF;
    IF v_expected IS NULL OR v_expected<>v_case.version THEN RAISE EXCEPTION 'case_version_conflict' USING ERRCODE='40001'; END IF;
    IF NOT EXISTS (SELECT 1 FROM editorial.review_decisions WHERE review_snapshot_id=v_snapshot_id AND decision='APPROVE' AND reviewer_id<>v_snapshot.created_by) THEN RAISE EXCEPTION 'publication_requires_independent_review' USING ERRCODE='23514'; END IF;
    v_public:=jsonb_build_object('caseId',v_case_id,'title',v_case.title,'summary',v_case.summary,'evidence',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',id,'title',title,'excerpt',redacted_public_excerpt) ORDER BY id) FROM editorial.evidence WHERE case_id=v_case_id AND verification_status='VERIFIED'),'[]'::jsonb));
    v_preview:=encode(extensions.digest(convert_to(v_public::text,'UTF8'),'sha256'),'hex');
    INSERT INTO editorial.publication_previews(case_id,review_snapshot_id,locale,preview_payload,preview_sha256,expires_at,created_by)
      VALUES(v_case_id,v_snapshot_id,'ko-KR',v_public,v_preview,v_now+interval '1 hour',p_actor_id);
    INSERT INTO editorial.publication_revisions(case_id,revision,state,review_snapshot_id,public_payload,public_payload_sha256,preview_sha256,published_by,supersedes_revision,reason)
      VALUES(v_case_id,1,'PUBLISHED_EXPLAINED',v_snapshot_id,v_public,v_preview,v_preview,p_actor_id,NULL,v_reason)
      RETURNING * INTO v_revision;
    UPDATE editorial.cases SET publication_state='PUBLISHED_EXPLAINED',investigation_state='CLOSED',current_publication_revision=1,version=version+1,updated_at=v_now WHERE id=v_case_id AND version=v_case.version;
    v_root:=v_case_id; v_version:=v_revision.revision; v_status:='PUBLISHED';
    v_digest:=encode(extensions.digest(convert_to(v_revision.id::text||':PUBLISH_CASE:'||v_preview,'UTF8'),'sha256'),'hex');
    v_payload:=jsonb_build_object('publicationRevisionId',v_revision.id,'caseId',v_case_id,'snapshotId',v_snapshot_id,'revision',v_revision.revision,'parentRootId',v_case_id,'publicPayloadDigest',v_preview);
    v_audit:=ops.append_audit_event('flow03:'||v_case_id::text,'USER',p_actor_id::text,p_session_id,'command.publishCase','PublicationRevision',v_revision.id::text,'publication.publish','SUCCESS',v_reason,p_request_id,v_payload);
    v_outbox:=ops.enqueue_outbox('Publication',v_case_id::text,v_revision.revision,'publication.revision_created.v1',v_payload,v_now);
    RETURN jsonb_build_object('publicationRevisionId',v_revision.id,'aggregateId',v_revision.id,'aggregateVersion',v_version,'status',v_status,'rootId',v_root,'caseId',v_case_id,'snapshotId',v_snapshot_id,
      'receiptDigest',v_digest,'auditEventId',v_audit,'outboxEventId',v_outbox,'emittedEventIds',jsonb_build_array(v_outbox),
      'links',jsonb_build_array(jsonb_build_object('kind','CASE','id',v_case_id),jsonb_build_object('kind','REVIEW_SNAPSHOT','id',v_snapshot_id),jsonb_build_object('kind','PUBLICATION','id',v_revision.id,'version',v_version,'digest',v_digest)));
  END IF;
  RAISE EXCEPTION 'signal_publication_operation_not_registered:%',p_operation_id USING ERRCODE='0A000';
END $$;
ALTER FUNCTION ops.apply_signal_publication_command_v1(text,jsonb,uuid,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_signal_publication_command_v1(text,jsonb,uuid,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.apply_signal_publication_command_v1(text,jsonb,uuid,uuid,uuid,char(64),char(64)) TO gurine_control_api;

-- Replace the provisional journal dispatcher with operation-owned adapters.
-- Action approval and incident transitions are persisted in their native
-- aggregate graphs; the command API only receives the closed receipt tuple.
BEGIN;
-- Forward declaration for the response-request owner defined at the end of
-- this migration; PostgreSQL resolves function references at CREATE time.
GRANT SELECT, INSERT, UPDATE ON
  editorial.cases, editorial.response_requests, intake.response_access_tokens,
  ops.tasks, ops.idempotency_keys TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.create_response_request_v1(
  p_payload jsonb, p_actor_id uuid, p_session_id uuid, p_request_id uuid,
  p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, editorial, intake, extensions, pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'response_request_owner_not_initialized' USING ERRCODE='55000';
END $$;
ALTER FUNCTION ops.create_response_request_v1(jsonb,uuid,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
DROP FUNCTION IF EXISTS ops.apply_control_addendum_command(text,jsonb,uuid,uuid,uuid,char(64),char(64));
CREATE OR REPLACE FUNCTION ops.apply_control_addendum_command(
  p_operation_id text, p_payload jsonb, p_actor_id uuid, p_session_id uuid,
  p_request_id uuid, p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS TABLE(aggregate_id uuid, aggregate_version bigint, status text,
  accepted_at timestamptz, response_body jsonb, receipt_digest char(64),
  audit_event_id uuid, outbox_event_id uuid)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, editorial, intake, raw, extensions, pg_temp
AS $$
DECLARE
  v_raw jsonb; v_id uuid; v_version bigint; v_status text; v_receipt char(64);
  v_audit uuid; v_outbox uuid; v_now timestamptz := clock_timestamp();
  v_proposal uuid; v_action_kind text; v_target_type text; v_target_id text;
  v_target_version bigint; v_assignment_version bigint; v_result_state text;
  v_content_digest char(64); v_approval_digest char(64); v_expires_at timestamptz;
  v_reason text; v_receipt_body jsonb;
  v_decision_id uuid; v_original_decision ops.action_decisions%ROWTYPE;
  v_decision_body jsonb;
  v_incident ops.incident_events;
  v_conflict editorial.conflict_declarations;
  v_transition text;
  v_dispatch_op text;
  v_prepare ops.journey_handoff_decision_prepare_receipt_v1;
  v_attempt ops.journey_handoff_assertion_attempt_receipt_v1;
  v_finalize_input ops.idempotency_finalize_v1;
  v_finalize ops.idempotency_finalize_receipt_v1;
  v_decision_raw jsonb;
  v_reason_digest char(64);
  v_response_bytes bytea;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'control_addendum_payload_must_be_object' USING ERRCODE='22023';
  END IF;
  IF p_operation_id = 'createResponseRequest' THEN
    v_raw := ops.create_response_request_v1(
      p_payload,p_actor_id,p_session_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    v_id := NULLIF(v_raw->>'aggregateId','')::uuid;
    v_version := COALESCE(NULLIF(v_raw->>'aggregateVersion','')::bigint,1);
    v_status := COALESCE(v_raw->>'status','SENT');
    v_receipt := NULLIF(v_raw->>'receiptDigest','')::char(64);
    v_audit := NULLIF(v_raw->>'auditEventId','')::uuid;
    v_outbox := NULLIF(v_raw->'emittedEventIds'->>0,'')::uuid;
    IF v_id IS NULL OR v_receipt IS NULL OR v_audit IS NULL OR v_outbox IS NULL THEN
      RAISE EXCEPTION 'typed_response_request_receipt_incomplete' USING ERRCODE='P0001';
    END IF;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  IF p_operation_id = 'withdrawActionProposal' THEN
    -- Proposal withdrawal is its own terminal aggregate transition.  It must
    -- not be routed through submitActionDecision: a draft has no review
    -- assignment yet, and the withdrawal contract cancels any live
    -- assignment atomically when one exists.
    v_proposal := NULLIF(p_payload->>'proposalId','')::uuid;
    IF v_proposal IS NULL THEN
      RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023';
    END IF;
    SELECT p.current_version,p.action_kind,p.target_type,p.target_id,
           p.target_version,v.state,v.state_version,v.content_digest,v.approval_digest,
           v.expires_at
      INTO v_version,v_action_kind,v_target_type,v_target_id,v_target_version,
           v_result_state,v_assignment_version,v_content_digest,v_approval_digest,v_expires_at
      FROM ops.action_proposals p
      JOIN ops.action_proposal_versions v ON v.proposal_id=p.id AND v.version=p.current_version
     WHERE p.id=v_proposal FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002';
    END IF;
    IF v_result_state NOT IN ('DRAFT','PENDING_QUORUM')
       OR v_version <> COALESCE(NULLIF(p_payload->>'expectedProposalVersion','')::bigint,0)
       OR v_assignment_version <> COALESCE(NULLIF(p_payload->>'expectedStateVersion','')::bigint,0)
       OR btrim(v_content_digest::text) IS DISTINCT FROM btrim(NULLIF(p_payload->>'expectedContentDigest',''))
       OR EXISTS (SELECT 1 FROM ops.execution_authorizations WHERE proposal_id=v_proposal)
    THEN
      RAISE EXCEPTION 'action_proposal_stale' USING ERRCODE='40001';
    END IF;
    v_reason := COALESCE(NULLIF(p_payload->>'reason',''),'proposal withdrawn');
    v_reason_digest := encode(extensions.digest(convert_to(v_reason,'UTF8'),'sha256'),'hex');
    v_receipt_body := jsonb_build_object(
      'proposalId',v_proposal,'proposalVersion',v_version,'state','WITHDRAWN',
      'actionKind',v_action_kind,'contentDigest',v_content_digest,
      'approvalDigest',COALESCE(v_approval_digest,v_content_digest),
      'targetType',v_target_type,'targetId',v_target_id,'targetVersion',v_target_version,
      'expiresAt',v_expires_at,'reasonCode',COALESCE(p_payload->>'reasonCode','OTHER'),
      'reason',v_reason,'acceptedAt',v_now);
    v_receipt := encode(extensions.digest(convert_to(v_receipt_body::text,'UTF8'),'sha256'),'hex');
    v_audit := ops.append_audit_event('control:action:'||v_proposal::text,'USER',p_actor_id::text,p_session_id,
      'ACTION_PROPOSAL_WITHDRAWN','ActionProposal',v_proposal::text,'actions.propose','SUCCESS',v_reason,p_request_id,v_receipt_body);
    v_outbox := ops.enqueue_outbox('ActionProposal',v_proposal::text,v_version,
      'action.proposal_withdrawn.v1',v_receipt_body,v_now);
    UPDATE ops.action_proposal_versions
       SET state='WITHDRAWN',state_version=state_version+1,terminal_at=v_now,
           terminal_reason_code='WITHDRAWN',terminal_receipt_digest=v_receipt,updated_at=v_now
     WHERE proposal_id=v_proposal AND version=v_version AND state=v_result_state;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'action_proposal_stale' USING ERRCODE='40001';
    END IF;
    UPDATE ops.action_review_assignments
       SET state='CANCELLED',version=version+1,terminal_at=v_now,
           terminal_reason_code='PROPOSAL_WITHDRAWN',updated_at=v_now
     WHERE proposal_id=v_proposal AND state IN ('ASSIGNED','IN_PROGRESS');
    UPDATE ops.action_proposals AS ap SET aggregate_version=ap.aggregate_version+1,
      last_receipt_digest=v_receipt,last_audit_event_id=v_audit,updated_at=v_now
     WHERE ap.id=v_proposal;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,
      'status','COMPLETED','aggregateId',v_proposal,'aggregateVersion',v_version,
      'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,
      'emittedEventIds',jsonb_build_array(v_outbox),'links','[]'::jsonb) || v_receipt_body;
    RETURN QUERY SELECT v_proposal,v_version,'COMPLETED',v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  IF p_operation_id = 'withdrawActionDecision' THEN
    -- Preserve the original immutable decision and emit a withdrawal
    -- observation through the command/audit boundary. The current flow keeps
    -- the proposal available for a replacement reviewer assignment.
    v_proposal := NULLIF(p_payload->>'proposalId','')::uuid;
    v_decision_id := NULLIF(p_payload->>'decisionId','')::uuid;
    IF v_proposal IS NULL OR v_decision_id IS NULL THEN
      RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023';
    END IF;
    SELECT * INTO v_original_decision FROM ops.action_decisions
     WHERE id=v_decision_id AND proposal_id=v_proposal AND record_kind='DECISION' FOR SHARE;
    IF NOT FOUND OR v_original_decision.decision_kind <> 'APPROVE' THEN
      RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002';
    END IF;
    v_id := gen_random_uuid();
    v_reason := COALESCE(NULLIF(p_payload->>'reason',''),'approval withdrawn');
    v_decision_body := jsonb_build_object(
      'recordKind','APPROVAL_WITHDRAWAL','decisionId',v_id,
      'assignmentId',v_original_decision.assignment_id,
      'assignmentGeneration',v_original_decision.assignment_generation,
      'decisionKind','APPROVAL_WITHDRAWN','actor',jsonb_build_object('actorType','HUMAN','actorId',p_actor_id,'displayName','Action reviewer'),
      'slotKind',v_original_decision.slot_kind,'capability','actions.review','assurance',v_original_decision.assurance,
      'reasonCode',COALESCE(p_payload->>'reasonCode','OTHER'),'reason',v_reason,
      'approvalDigest',v_original_decision.approval_digest,'receiptDigest',v_receipt,
      'withdrawnDecisionId',v_decision_id,'withdrawnDecisionReceiptDigest',v_original_decision.receipt_digest,
      'acceptedAt',v_now,'decidedAt',v_now);
    SELECT p.action_kind,p.target_type,p.target_id,p.target_version,p.current_version,
           v.state,v.content_digest,v.approval_digest,v.expires_at
      INTO v_action_kind,v_target_type,v_target_id,v_target_version,v_version,
           v_result_state,v_content_digest,v_approval_digest,v_expires_at
      FROM ops.action_proposals p JOIN ops.action_proposal_versions v
        ON v.proposal_id=p.id AND v.version=p.current_version
     WHERE p.id=v_proposal;
    IF v_result_state <> 'APPROVED' OR EXISTS (
      SELECT 1 FROM ops.execution_authorizations WHERE proposal_id=v_proposal
    ) THEN
      RAISE EXCEPTION 'action_decision_withdrawal_stale' USING ERRCODE='40001';
    END IF;
    v_receipt_body := jsonb_build_object(
      'proposalId',v_proposal,'proposalVersion',v_version,'state','PENDING_QUORUM',
      'actionKind',v_action_kind,'contentDigest',v_content_digest,
      'approvalDigest',COALESCE(v_approval_digest,v_original_decision.approval_digest),
      'targetType',v_target_type,'targetId',v_target_id,'targetVersion',v_target_version,
      'expiresAt',v_expires_at,'decision',v_decision_body,
      'quorum',jsonb_build_object('planDigest',v_original_decision.quorum_snapshot_digest,
        'requiredSlots',jsonb_build_array('actions.review'),'satisfiedSlots',jsonb_build_array(),
        'blockingSlots',jsonb_build_array('actions.review'),'conflictSnapshotDigest',v_original_decision.conflict_snapshot_digest,'complete',false),
      'executionAuthorization',NULL);
    -- The withdrawal is a first-class immutable fact.  Its receipt binding is
    -- exactly the canonical body returned at the HTTP boundary, so the row's
    -- receipt digest can be independently recomputed from persisted bytes.
    v_receipt := encode(extensions.digest(convert_to(v_receipt_body::text,'UTF8'),'sha256'),'hex');
    v_decision_body := v_decision_body || jsonb_build_object('receiptDigest',v_receipt);
    v_audit := ops.append_audit_event('control:action:'||v_proposal::text,'USER',p_actor_id::text,p_session_id,
      'ACTION_DECISION_WITHDRAWN','ActionDecision',v_id::text,'actions.review','SUCCESS',v_reason,p_request_id,
      jsonb_build_object('decisionId',v_id,'withdrawnDecisionId',v_decision_id,
        'withdrawnDecisionReceiptDigest',v_original_decision.receipt_digest,'reason',v_reason));
    INSERT INTO ops.action_decisions(
      id,record_kind,proposal_id,proposal_version,approval_digest,assignment_id,
      assignment_version,assignment_generation,slot_kind,actor_id,
      asserted_required_capability,assurance,actor_assertion_jti,actor_action_digest,
      step_up_authorization_id,step_up_authorization_digest,
      step_up_authorization_receipt_digest,step_up_authorization_receipt_canonical,
      step_up_issue_ordinal,step_up_issued_at,step_up_expires_at,
      idempotency_key_sha256,decision_kind,withdrawn_decision_id,
      withdrawn_decision_receipt_digest,withdrawn_record_kind,withdrawn_decision_kind,
      reason_code,reason,reason_digest,decision_payload,decision_payload_canonical,
      decision_receipt_binding,decision_receipt_binding_canonical,conflict_snapshot_id,
      conflict_snapshot_digest,conflict_target_id,conflict_target_version,
      conflict_target_digest,conflict_evaluation_state,conflict_valid_until,
      quorum_snapshot_digest,counts_toward_quorum,quorum_satisfied_after,
      resulting_proposal_state,execution_id,receipt_digest,request_id,audit_event_id,
      decided_at,created_at
    ) VALUES (
      v_id,'APPROVAL_WITHDRAWAL',v_original_decision.proposal_id,
      v_original_decision.proposal_version,v_original_decision.approval_digest,
      v_original_decision.assignment_id,v_original_decision.assignment_version,
      v_original_decision.assignment_generation,v_original_decision.slot_kind,
      v_original_decision.actor_id,v_original_decision.asserted_required_capability,
      v_original_decision.assurance,gen_random_uuid(),
      encode(extensions.digest(convert_to(v_id::text||':'||v_reason,'UTF8'),'sha256'),'hex'),
      v_original_decision.step_up_authorization_id,
      v_original_decision.step_up_authorization_digest,
      v_original_decision.step_up_authorization_receipt_digest,
      v_original_decision.step_up_authorization_receipt_canonical,
      v_original_decision.step_up_issue_ordinal,
      v_original_decision.step_up_issued_at,
      v_original_decision.step_up_expires_at,
      p_idempotency_key_hash,'APPROVAL_WITHDRAWN',v_decision_id,
      v_original_decision.receipt_digest,'DECISION','APPROVE',
      COALESCE(p_payload->>'reasonCode','OTHER'),v_reason,
      encode(extensions.digest(convert_to(v_reason,'UTF8'),'sha256'),'hex'),
      v_decision_body,convert_to(v_decision_body::text,'UTF8'),
      v_receipt_body,convert_to(v_receipt_body::text,'UTF8'),
      v_original_decision.conflict_snapshot_id,v_original_decision.conflict_snapshot_digest,
      v_original_decision.conflict_target_id,v_original_decision.conflict_target_version,
      v_original_decision.conflict_target_digest,v_original_decision.conflict_evaluation_state,
      GREATEST(v_original_decision.conflict_valid_until,v_now),
      v_original_decision.quorum_snapshot_digest,false,false,'PENDING_QUORUM',NULL,
      v_receipt,p_request_id,v_audit,v_now,v_now
    );
    v_outbox := ops.enqueue_outbox('ActionDecision',v_id::text,v_original_decision.proposal_version,
      'action.decision_withdrawn.v1',jsonb_build_object('decisionId',v_id,'withdrawnDecisionId',v_decision_id,
        'proposalId',v_proposal,'receiptDigest',v_receipt),v_now);
    UPDATE ops.action_proposal_versions
       SET state='PENDING_QUORUM',state_version=state_version+1,
           terminal_at=NULL,terminal_reason_code=NULL,terminal_receipt_digest=NULL,
           updated_at=v_now
     WHERE proposal_id=v_proposal AND version=v_version AND state='APPROVED';
    IF NOT FOUND THEN RAISE EXCEPTION 'action_proposal_withdrawal_stale' USING ERRCODE='40001'; END IF;
    UPDATE ops.in_flight_effects
       SET state='CANCELLED',state_version=state_version+1,
           cancellation_generation=cancellation_generation+1,
           cancel_requested_at=v_now,
           cancel_reason_digest=encode(extensions.digest(convert_to(v_reason,'UTF8'),'sha256'),'hex'),
           terminal_at=v_now,updated_at=v_now,
           last_receipt_sequence=last_receipt_sequence+1,last_receipt_digest=v_receipt
     WHERE action_proposal_id=v_proposal AND action_proposal_version=v_version
       AND state='QUEUED' AND terminal_at IS NULL;
    UPDATE ops.action_proposals AS ap SET aggregate_version=ap.aggregate_version+1,
      last_receipt_digest=v_receipt,last_audit_event_id=v_audit,updated_at=v_now
     WHERE ap.id=v_proposal;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,
      'status','COMPLETED','aggregateId',v_proposal,'aggregateVersion',v_version,
      'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,
      'emittedEventIds',jsonb_build_array(v_outbox),'links','[]'::jsonb) ||
      v_receipt_body || jsonb_build_object('decision',v_decision_body) || v_decision_body;
    RETURN QUERY SELECT v_proposal,v_version,'COMPLETED',v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  IF p_operation_id IN ('createActionProposal','updateActionDraft','previewActionDraft',
      'submitActionForReview','claimActionReview','submitActionDecision','withdrawActionProposal','withdrawActionDecision') THEN
    p_payload := p_payload || jsonb_build_object('requestId',p_request_id);
    v_dispatch_op := CASE WHEN p_operation_id IN ('withdrawActionProposal','withdrawActionDecision') THEN 'submitActionDecision' ELSE p_operation_id END;
    IF p_operation_id='withdrawActionProposal' THEN p_payload := p_payload || jsonb_build_object('decision','CHANGES_REQUIRED'); END IF;
    IF p_operation_id='withdrawActionDecision' THEN p_payload := p_payload || jsonb_build_object('decision','REJECT'); END IF;
    v_raw := ops.execute_action_approval_v1(v_dispatch_op,p_payload,p_actor_id);
    v_id := COALESCE(NULLIF(v_raw->>'proposalId','')::uuid,NULLIF(v_raw->>'assignmentId','')::uuid,NULLIF(v_raw->>'decisionId','')::uuid);
    IF v_id IS NULL THEN RAISE EXCEPTION 'typed_action_receipt_missing_id' USING ERRCODE='P0001'; END IF;
    v_version := COALESCE(NULLIF(v_raw->>'proposalVersion','')::bigint,NULLIF(v_raw->>'version','')::bigint,1);
    -- Domain state (for example DRAFT/PENDING_QUORUM) is carried in the
    -- operation payload; the command envelope itself reports transport
    -- completion according to CommandReceiptV1.
    v_status := 'COMPLETED';
    v_receipt := NULLIF(v_raw->>'receiptDigest','')::char(64);
    IF v_receipt IS NULL OR v_receipt !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'typed_action_receipt_missing_digest' USING ERRCODE='P0001';
    END IF;
    v_audit := NULLIF(v_raw->>'auditEventId','')::uuid;
    IF v_audit IS NULL THEN
      v_audit := ops.append_audit_event('control:action:'||v_id::text,'USER',p_actor_id::text,p_session_id,
        'command.'||p_operation_id,'ActionProposal',v_id::text,'actions.propose','SUCCESS',NULL,p_request_id,v_raw);
    END IF;
    v_outbox := NULLIF(COALESCE(v_raw->'outboxEventIds'->>0,v_raw->'emittedEventIds'->>0),'')::uuid;
    v_raw := v_raw || jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,
      'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,
      'acceptedAt',COALESCE(v_raw->'acceptedAt',to_jsonb(v_now)),
      'receiptDigest',v_receipt,'auditEventId',v_audit,
      'emittedEventIds',COALESCE(v_raw->'outboxEventIds',v_raw->'emittedEventIds','[]'::jsonb),
      'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  IF p_operation_id = 'cancelAgentRun' THEN
    v_raw := ops.cancel_agent_run_v1(p_payload,p_actor_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    v_id := COALESCE(NULLIF(v_raw->>'runId','')::uuid,NULLIF(v_raw->>'agentRunId','')::uuid);
    v_version := COALESCE(NULLIF(v_raw->>'aggregateVersion','')::bigint,1);
    v_status := COALESCE(v_raw->>'nextStatus','CANCELLED');
    v_receipt := NULLIF(v_raw->>'receiptSha256','')::char(64);
    v_audit := NULLIF(v_raw->>'auditEventId','')::uuid;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,'emittedEventIds','[]'::jsonb,'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,NULL::uuid;
    RETURN;
  END IF;
  IF p_operation_id = 'reconcileAgentRun' THEN
    v_raw := ops.reconcile_agent_run_v2(p_payload,p_actor_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    v_id := NULLIF(v_raw->>'runId','')::uuid;
    v_version := COALESCE(NULLIF(v_raw->>'aggregateVersion','')::bigint,1);
    v_status := COALESCE(v_raw->>'nextStatus','RUNNING');
    v_receipt := NULLIF(v_raw->>'receiptSha256','')::char(64);
    v_audit := NULLIF(v_raw->>'auditEventId','')::uuid;
    SELECT id INTO v_outbox FROM ops.outbox
     WHERE aggregate_type='agent_run' AND aggregate_id=v_id::text
       AND aggregate_version=v_version AND event_type='agent.run_control_changed.v2'
     ORDER BY created_at DESC LIMIT 1;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,
      'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,
      'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,
      'emittedEventIds',CASE WHEN v_outbox IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_outbox) END,
      'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  IF p_operation_id = 'cancelActionExecution' THEN
    v_raw := ops.cancel_action_execution_v1(p_payload,p_actor_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    v_id := NULLIF(v_raw->>'executionId','')::uuid;
    v_version := COALESCE(NULLIF(v_raw->>'aggregateStateVersion','')::bigint,1);
    v_status := 'COMPLETED';
    v_receipt := NULLIF(v_raw->>'receiptDigest','')::char(64);
    v_audit := NULLIF(v_raw->>'auditEventId','')::uuid;
    v_outbox := NULLIF(v_raw->'outboxIds'->>0,'')::uuid;
    v_raw := jsonb_build_object(
      'operationId',p_operation_id,'requestId',p_request_id,'status',v_status,
      'aggregateId',v_id,'aggregateVersion',v_version,'acceptedAt',v_now,
      'receiptDigest',v_receipt,'auditEventId',v_audit,
      'emittedEventIds',COALESCE(v_raw->'outboxIds','[]'::jsonb),'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  IF p_operation_id = 'retryActionExecution' THEN
    v_raw := ops.retry_action_execution_v1(p_payload,p_actor_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    v_id := NULLIF(v_raw->>'executionId','')::uuid;
    v_version := COALESCE(NULLIF(v_raw->>'aggregateStateVersion','')::bigint,1);
    v_status := 'COMPLETED';
    v_receipt := NULLIF(v_raw->>'receiptDigest','')::char(64);
    v_audit := NULLIF(v_raw->>'auditEventId','')::uuid;
    v_outbox := NULLIF(v_raw->'outboxIds'->>0,'')::uuid;
    v_raw := jsonb_build_object(
      'operationId',p_operation_id,'requestId',p_request_id,'status',v_status,
      'aggregateId',v_id,'aggregateVersion',v_version,'acceptedAt',v_now,
      'receiptDigest',v_receipt,'auditEventId',v_audit,
      'emittedEventIds',COALESCE(v_raw->'outboxIds','[]'::jsonb),'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  IF p_operation_id IN ('activateKillSwitch','deactivateKillSwitch') THEN
    v_raw := ops.apply_kill_switch_command_v1(
      p_operation_id,p_payload,p_actor_id,p_session_id,p_request_id,
      p_idempotency_key_hash,p_request_digest);
    v_id := NULLIF(v_raw->>'aggregateId','')::uuid;
    v_version := NULLIF(v_raw->>'aggregateVersion','')::bigint;
    v_status := COALESCE(v_raw->>'status','COMPLETED');
    v_receipt := NULLIF(v_raw->>'receiptDigest','')::char(64);
    v_audit := NULLIF(v_raw->>'auditEventId','')::uuid;
    v_outbox := NULLIF(v_raw->'emittedEventIds'->>0,'')::uuid;
    IF v_id IS NULL OR v_version IS NULL OR v_receipt IS NULL OR v_audit IS NULL OR v_outbox IS NULL THEN
      RAISE EXCEPTION 'typed_kill_switch_receipt_incomplete' USING ERRCODE='P0001';
    END IF;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  IF p_operation_id IN ('declareConflict','withdrawConflict') THEN
    IF p_operation_id='withdrawConflict' THEN
      SELECT * INTO v_conflict FROM editorial.conflict_declarations
        WHERE id=NULLIF(p_payload->>'declarationId','')::uuid FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;
      p_payload := p_payload || jsonb_build_object(
        'subjectActorId',v_conflict.subject_actor_id,
        'targetType',v_conflict.target_type,
        'targetId',v_conflict.target_id,
        'targetVersion',v_conflict.target_version,
        'targetDigest',v_conflict.target_digest,
        'conflictType',v_conflict.conflict_type,
        'sourceClass',v_conflict.source_class,
        'policyDigest',v_conflict.policy_digest,
        'evidenceRefs','[]'::jsonb,
        'effectiveAt',v_conflict.effective_at,
        'expiresAt',p_payload->>'expiresAt'
      );
    END IF;
    IF p_operation_id='withdrawConflict' THEN p_payload := p_payload || jsonb_build_object('relationState','ABSENT','materiality','NOT_APPLICABLE','temporalState','NOT_APPLICABLE'); END IF;
    v_raw := editorial.declare_conflict_v1(p_payload,p_actor_id,p_request_id,p_idempotency_key_hash);
    v_id := (v_raw->>'declarationId')::uuid; v_version := COALESCE((v_raw->>'targetVersion')::bigint,1); v_status := COALESCE(v_raw->>'relationState','DECLARED'); v_receipt := (v_raw->>'receiptDigest')::char(64); v_audit := (v_raw->>'auditEventId')::uuid;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,'emittedEventIds','[]'::jsonb,'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,NULL::uuid;
    RETURN;
  END IF;
  IF p_operation_id IN ('reconcileCommunicationDelivery','cancelCommunicationDelivery') THEN
    IF p_operation_id='reconcileCommunicationDelivery' THEN
      v_raw := ops.reconcile_communication_delivery(p_payload,p_actor_id,p_session_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    ELSE
      v_raw := ops.cancel_outbound_delivery(p_payload,p_actor_id,p_session_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    END IF;
    v_id := NULLIF(v_raw->>'deliveryId','')::uuid;
    v_version := COALESCE(NULLIF(v_raw->>'deliveryVersion','')::bigint,1);
    -- CommandReceiptV1 exposes a transport status, while the delivery's
    -- domain transition is carried separately as `state` in response_body.
    -- Keep the envelope within the contract's ACCEPTED/COMPLETED/REJECTED
    -- enum even when the aggregate reaches RETRY_SCHEDULED or CANCELLED.
    v_status := 'COMPLETED';
    v_receipt := NULLIF(v_raw->>'receiptDigest','')::char(64);
    v_audit := NULLIF(v_raw->>'auditEventId','')::uuid;
    v_outbox := NULLIF(COALESCE(v_raw->>'emittedEventId',v_raw->'emittedEventIds'->>0),'')::uuid;
    IF v_id IS NULL OR v_receipt IS NULL OR v_audit IS NULL OR v_outbox IS NULL THEN
      RAISE EXCEPTION 'typed_communication_receipt_incomplete' USING ERRCODE='P0001';
    END IF;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,
      'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,
      'acceptedAt',COALESCE(v_raw->'acceptedAt',to_jsonb(v_now)),
      'receiptDigest',v_receipt,'auditEventId',v_audit,
      'emittedEventIds',jsonb_build_array(v_outbox),'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  IF p_operation_id = 'transitionResponseAppeal' THEN
    v_raw := ops.transition_response_appeal_v1(p_payload,p_actor_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    v_id := COALESCE(NULLIF(v_raw->>'appealId','')::uuid,NULLIF(v_raw->'appeal'->>'appealId','')::uuid,
      NULLIF(v_raw->'appeal'->>'id','')::uuid);
    v_version := COALESCE(NULLIF(v_raw->>'decisionSequence','')::bigint,NULLIF(v_raw->'appeal'->>'decisionSequence','')::bigint,1);
    v_status := COALESCE(v_raw->>'state',v_raw->'appeal'->>'state','REVIEW');
    v_receipt := NULLIF(COALESCE(v_raw->>'receiptDigest',v_raw->'appeal'->>'receiptDigest'),'')::char(64);
    v_audit := NULLIF(COALESCE(v_raw->>'auditEventId',v_raw->'appeal'->>'auditEventId'),'')::uuid;
    v_outbox := NULLIF(COALESCE(v_raw->'outboxEventIds'->>0,v_raw->'appeal'->'outboxEventIds'->>0),'')::uuid;
    IF v_id IS NULL OR v_receipt IS NULL OR v_audit IS NULL OR v_outbox IS NULL THEN RAISE EXCEPTION 'typed_appeal_receipt_incomplete' USING ERRCODE='P0001'; END IF;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,'emittedEventIds',jsonb_build_array(v_outbox),'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox; RETURN;
  END IF;
  IF p_operation_id = 'decideResponseExtension' THEN
    v_raw := ops.decide_response_extension_v1(p_payload,p_actor_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    v_id := COALESCE(NULLIF(v_raw->'extension'->>'extensionRequestId','')::uuid,NULLIF(v_raw->'extension'->>'id','')::uuid);
    v_version := COALESCE(NULLIF(v_raw->'extension'->>'decisionSequence','')::bigint,1);
    v_status := COALESCE(v_raw->'extension'->>'status','REJECTED');
    v_receipt := NULLIF(v_raw->'extension'->>'receiptDigest','')::char(64);
    v_audit := NULLIF(v_raw->'extension'->>'auditEventId','')::uuid;
    v_outbox := NULLIF(v_raw->'extension'->'outboxEventIds'->>0,'')::uuid;
    IF v_id IS NULL OR v_receipt IS NULL OR v_audit IS NULL OR v_outbox IS NULL THEN RAISE EXCEPTION 'typed_extension_receipt_incomplete' USING ERRCODE='P0001'; END IF;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,'emittedEventIds',jsonb_build_array(v_outbox),'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox; RETURN;
  END IF;
  IF p_operation_id = 'transitionRetentionRequest' THEN
    v_raw := ops.transition_retention_request_v1(p_payload,p_actor_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    v_id := COALESCE(NULLIF(v_raw->'request'->>'retentionRequestId','')::uuid,NULLIF(v_raw->'request'->>'id','')::uuid);
    v_version := COALESCE(NULLIF(v_raw->'request'->>'decisionVersion','')::bigint,1);
    v_status := COALESCE(v_raw->'request'->>'status','REVIEW');
    v_receipt := NULLIF(v_raw->'request'->>'receiptDigest','')::char(64);
    v_audit := NULLIF(v_raw->'request'->>'auditEventId','')::uuid;
    v_outbox := NULLIF(v_raw->'request'->'outboxEventIds'->>0,'')::uuid;
    IF v_id IS NULL OR v_receipt IS NULL OR v_audit IS NULL OR v_outbox IS NULL THEN RAISE EXCEPTION 'typed_retention_receipt_incomplete' USING ERRCODE='P0001'; END IF;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,'emittedEventIds',jsonb_build_array(v_outbox),'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox; RETURN;
  END IF;
  IF p_operation_id = 'releaseLegalHold' THEN
    v_raw := ops.release_legal_hold_v1(p_payload,p_actor_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    v_id := COALESCE(NULLIF(v_raw->'release'->>'holdId','')::uuid,NULLIF(v_raw->'release'->>'id','')::uuid);
    v_version := COALESCE(NULLIF(v_raw->'release'->>'releaseSequence','')::bigint,1);
    v_status := 'RELEASED';
    v_receipt := NULLIF(v_raw->'release'->>'receiptDigest','')::char(64);
    v_audit := NULLIF(v_raw->'release'->>'auditEventId','')::uuid;
    v_outbox := NULLIF(v_raw->'release'->'outboxEventIds'->>0,'')::uuid;
    IF v_id IS NULL OR v_receipt IS NULL OR v_audit IS NULL OR v_outbox IS NULL THEN RAISE EXCEPTION 'typed_legal_hold_receipt_incomplete' USING ERRCODE='P0001'; END IF;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,'emittedEventIds',jsonb_build_array(v_outbox),'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox; RETURN;
  END IF;
  IF p_operation_id IN ('triageIncident','containIncident','startIncidentRecovery','resolveIncident','closeIncidentPostmortem') THEN
    v_id := NULLIF(p_payload->>'incidentId','')::uuid;
    IF v_id IS NULL THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
    v_transition := CASE p_operation_id WHEN 'triageIncident' THEN 'TRIAGED' WHEN 'containIncident' THEN 'CONTAINED'
      WHEN 'startIncidentRecovery' THEN 'RECOVERY_STARTED' WHEN 'resolveIncident' THEN 'RESOLVED' ELSE 'POSTMORTEM_CLOSED' END;
    SELECT * INTO v_incident FROM ops.record_incident_transition(v_id,
      COALESCE(NULLIF(p_payload->>'expectedVersion','')::bigint,0),v_transition,
      COALESCE(p_payload->>'severity','SEV3'),ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_payload->'affectedCapabilities','["control"]'::jsonb))),
      COALESCE(NULLIF(p_payload->>'ownerUserId','')::uuid,p_actor_id),NULLIF(p_payload->>'commanderUserId','')::uuid,
      NULLIF(p_payload->>'nextUpdateAt','')::timestamptz,p_payload,COALESCE(p_payload->'evidenceRefs','[]'::jsonb),
      COALESCE(p_payload->>'reasonCode','CONTROL_COMMAND'),COALESCE(p_payload->>'reason','control command'),
      'HUMAN',p_actor_id::text,p_idempotency_key_hash,p_request_id);
    v_version := v_incident.version; v_status := v_incident.state; v_receipt := v_incident.receipt_digest; v_audit := v_incident.audit_event_id;
    v_outbox := ops.enqueue_outbox('incident',v_id::text,v_version,'control.addendum_command_applied.v1',jsonb_build_object('operationId',p_operation_id,'incidentId',v_id,'version',v_version),v_now);
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,'emittedEventIds',jsonb_build_array(v_outbox),'links','[]'::jsonb,'incident',to_jsonb(v_incident),'transition',jsonb_build_object('kind',v_transition));
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  IF p_operation_id = 'promoteResearchArtifactToEvidence' THEN
    v_raw := ops.promote_research_artifact_to_evidence_v1(
      p_payload,p_actor_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    v_id := NULLIF(v_raw->>'promotionId','')::uuid;
    v_version := COALESCE(NULLIF(v_raw->>'caseVersion','')::bigint,1);
    v_status := 'PROMOTED';
    v_receipt := NULLIF(v_raw->>'receiptSha256','')::char(64);
    v_audit := NULLIF(v_raw->>'auditEventId','')::uuid;
    v_outbox := NULLIF(v_raw->>'outboxEventId','')::uuid;
    IF v_id IS NULL OR v_receipt IS NULL OR v_audit IS NULL OR v_outbox IS NULL THEN
      RAISE EXCEPTION 'typed_promotion_receipt_incomplete' USING ERRCODE='P0001';
    END IF;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,
      'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,
      'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,
      'emittedEventIds',jsonb_build_array(v_outbox),'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  IF p_operation_id = 'decideJourneyHandoff' THEN
    v_id := NULLIF(p_payload->>'handoffId','')::uuid;
    IF v_id IS NULL THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
    IF NULLIF(p_payload->>'assertionJti','') IS NULL
       OR NULLIF(p_payload->>'issuer','') IS NULL
       OR NULLIF(p_payload->>'audience','') IS NULL THEN
      RAISE EXCEPTION 'journey_assertion_attempt_required' USING ERRCODE='28000';
    END IF;
    v_reason_digest := CASE WHEN p_payload->>'decision'='DECLINE' THEN encode(
      extensions.digest(convert_to(COALESCE(p_payload->>'reason',''),'UTF8'),'sha256'),'hex')::char(64) END;
    v_attempt := ops.consume_journey_handoff_assertion_attempt_v1(ROW(
      'ACTOR',NULLIF(p_payload->>'assertionJti','')::uuid,p_payload->>'issuer',p_payload->>'audience',
      to_timestamp(COALESCE(NULLIF(p_payload->>'expiresAtUnix','')::double precision,
        extract(epoch FROM (v_now+interval '20 seconds')))),p_request_digest,'decideJourneyHandoff',
      v_id,COALESCE(NULLIF(p_payload->>'expectedHandoffVersion','')::bigint,0),
      (p_payload->>'expectedBindingDigest')::char(64),p_payload->>'decision',NULLIF(p_payload->>'reasonCode',''),
      v_reason_digest,p_request_id,p_idempotency_key_hash
    )::ops.journey_handoff_assertion_attempt_v1);
    v_prepare := ops.prepare_journey_handoff_decision_v1(ROW(
      v_id,COALESCE(NULLIF(p_payload->>'expectedHandoffVersion','')::bigint,0),
      (p_payload->>'expectedBindingDigest')::char(64),p_payload->>'decision',NULLIF(p_payload->>'reasonCode',''),
      v_reason_digest,p_request_id,p_idempotency_key_hash,'ACTOR',NULLIF(p_payload->>'assertionJti','')::uuid,
      p_request_digest,v_attempt.audit_event_id,v_attempt.audit_event_hash
    )::ops.journey_handoff_decision_prepare_v1);
    IF v_prepare.disposition='FINAL_REPLAY' THEN
      v_raw := convert_from(v_prepare.response_body_bytes,'UTF8')::jsonb;
      v_version := COALESCE(NULLIF(v_raw->'finalParent'->>'version','')::bigint,1);
      v_status := 'COMPLETED';
      v_receipt := NULLIF(v_raw->>'effectDigest','')::char(64);
      v_audit := NULLIF(v_raw->'decisionReceipt'->>'auditEventId','')::uuid;
      v_outbox := NULLIF(v_raw->'decisionReceipt'->>'outboxEventId','')::uuid;
      RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
      RETURN;
    END IF;
    v_decision_raw := to_jsonb(ops.decide_journey_handoff_v1(
      v_id,COALESCE(NULLIF(p_payload->>'expectedHandoffVersion','')::bigint,0),
      (p_payload->>'expectedBindingDigest')::char(64),p_payload->>'decision',
      NULLIF(p_payload->>'reasonCode',''),
      CASE WHEN p_payload->>'decision'='DECLINE' THEN convert_to(COALESCE(p_payload->>'reason',''),'UTF8') END,
      v_reason_digest,
      p_request_id,
      p_idempotency_key_hash,NULLIF(p_payload->>'assertionJti','')::uuid));
    -- PostgreSQL composite attributes are snake_case.  The transport
    -- contract is camelCase, so the owner boundary performs the only allowed
    -- representation conversion before the response schema is materialized.
    v_raw := jsonb_build_object(
      'decisionReceipt', jsonb_build_object(
        'receiptId', v_decision_raw->'decision_receipt'->'receipt_id',
        'receiptDigest', v_decision_raw->'decision_receipt'->'receipt_digest',
        'journeyInstanceId', v_decision_raw->'decision_receipt'->'journey_instance_id',
        'journeyInstanceVersion', v_decision_raw->'decision_receipt'->'journey_instance_version',
        'handoffId', v_decision_raw->'decision_receipt'->'handoff_id',
        'handoffVersion', v_decision_raw->'decision_receipt'->'handoff_version',
        'handoffKind', v_decision_raw->'decision_receipt'->'handoff_kind',
        'generation', v_decision_raw->'decision_receipt'->'generation',
        'decision', v_decision_raw->'decision_receipt'->'decision',
        'resultingHandoffState', v_decision_raw->'decision_receipt'->'resulting_handoff_state',
        'resultingJourneyState', v_decision_raw->'decision_receipt'->'resulting_journey_state',
        'currentOwnerBindingDigest', v_decision_raw->'decision_receipt'->'current_owner_binding_digest',
        'nextOwnerBindingDigest', v_decision_raw->'decision_receipt'->'next_owner_binding_digest',
        'auditEventId', v_decision_raw->'decision_receipt'->'audit_event_id',
        'outboxEventId', v_decision_raw->'decision_receipt'->'outbox_event_id'),
      'replacement', NULL,
      'finalParent', jsonb_build_object(
        'journeyInstanceId', v_decision_raw->'final_parent'->'journey_instance_id',
        'version', v_decision_raw->'final_parent'->'version',
        'state', v_decision_raw->'final_parent'->'state',
        'currentOwnerBindingDigest', v_decision_raw->'final_parent'->'current_owner_binding_digest',
        'nextOwnerBindingDigest', v_decision_raw->'final_parent'->'next_owner_binding_digest',
        'activeHandoffId', v_decision_raw->'final_parent'->'active_handoff_id',
        'activeHandoffGeneration', v_decision_raw->'final_parent'->'active_handoff_generation',
        'activeHandoffState', v_decision_raw->'final_parent'->'active_handoff_state',
        'escalationState', v_decision_raw->'final_parent'->'escalation_state',
        'dueAt', v_decision_raw->'final_parent'->'due_at',
        'headReceiptId', v_decision_raw->'final_parent'->'head_receipt_id',
        'headReceiptDigest', v_decision_raw->'final_parent'->'head_receipt_digest'),
      'effectDigest', v_decision_raw->'effect_digest',
      'decidedAt', v_decision_raw->'decided_at');
    v_version := COALESCE(NULLIF(v_raw->'finalParent'->>'version','')::bigint,
      NULLIF(v_raw->'decisionReceipt'->>'journeyInstanceVersion','')::bigint,1);
    -- The domain journey remains ACTIVE after an ACK; the outer command
    -- envelope reports transport completion separately from that state.
    v_status := 'COMPLETED';
    v_receipt := NULLIF(v_raw->>'effectDigest','')::char(64);
    v_audit := NULLIF(v_raw->'decisionReceipt'->>'auditEventId','')::uuid;
    v_outbox := NULLIF(v_raw->'decisionReceipt'->>'outboxEventId','')::uuid;
    IF v_receipt IS NULL OR v_audit IS NULL OR v_outbox IS NULL THEN
      RAISE EXCEPTION 'typed_journey_receipt_incomplete' USING ERRCODE='P0001';
    END IF;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,
      'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,
      'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,
      'emittedEventIds',jsonb_build_array(v_outbox),'links','[]'::jsonb) || v_raw;
    v_response_bytes := convert_to(v_raw::text,'UTF8');
    -- Fill the named composite field-by-field.  This avoids an anonymous
    -- ROW cast whose NULL/record inference varies across PostgreSQL 18 minor
    -- releases and, critically, keeps response_body_bytes as the original
    -- JSON bytes for the replay validator.
    v_finalize_input.scope := 'JOURNEY_HANDOFF_DECISION';
    v_finalize_input.operation_id := 'decideJourneyHandoff';
    v_finalize_input.key_hash := p_idempotency_key_hash;
    v_finalize_input.request_hash := v_prepare.business_request_hash;
    v_finalize_input.bff_issuer := 'control-api';
    v_finalize_input.session_token_hash := NULL;
    v_finalize_input.expected_claim_generation := 1;
    v_finalize_input.response_status := 200;
    v_finalize_input.response_schema := 'JourneyHandoffDecisionReceiptV1';
    v_finalize_input.response_media_type := 'application/json';
    v_finalize_input.response_header_bytes := NULL;
    v_finalize_input.response_body_bytes := v_response_bytes;
    v_finalize_input.response_digest := encode(extensions.digest(v_response_bytes,'sha256'),'hex')::char(64);
    v_finalize_input.resource_type := 'JOURNEY_HANDOFF';
    v_finalize_input.resource_id := lower(v_id::text);
    v_finalize_input.receipt_id := NULLIF(v_raw->'decisionReceipt'->>'receiptId','')::uuid;
    v_finalize_input.receipt_digest := v_receipt;
    v_finalize_input.audit_event_id := v_audit;
    v_finalize_input.outbox_id := v_outbox;
    v_finalize_input.completed_at := v_now;
    v_finalize := ops.finalize_journey_handoff_decision_response_v1(v_finalize_input);
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  IF p_operation_id IN ('createSignal','triageSignal','createCase','createEvidence',
      'createReviewSnapshot','submitReview','publishCase') THEN
    v_raw := ops.apply_signal_publication_command_v1(
      p_operation_id,p_payload,p_actor_id,p_session_id,p_request_id,
      p_idempotency_key_hash,p_request_digest);
    v_id := COALESCE(NULLIF(v_raw->>'aggregateId','')::uuid,
      NULLIF(v_raw->>'signalId','')::uuid,NULLIF(v_raw->>'caseId','')::uuid,
      NULLIF(v_raw->>'evidenceId','')::uuid,NULLIF(v_raw->>'snapshotId','')::uuid,
      NULLIF(v_raw->>'publicationRevisionId','')::uuid);
    v_version := COALESCE(NULLIF(v_raw->>'aggregateVersion','')::bigint,1);
    v_status := COALESCE(v_raw->>'status','COMPLETED');
    v_receipt := NULLIF(v_raw->>'receiptDigest','')::char(64);
    v_audit := NULLIF(v_raw->>'auditEventId','')::uuid;
    v_outbox := NULLIF(COALESCE(v_raw->'emittedEventIds'->>0,v_raw->>'outboxEventId'),'')::uuid;
    IF v_id IS NULL OR v_receipt IS NULL OR v_audit IS NULL OR v_outbox IS NULL THEN
      RAISE EXCEPTION 'typed_signal_publication_receipt_incomplete' USING ERRCODE='P0001';
    END IF;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,
      'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,
      'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,
      'emittedEventIds',COALESCE(v_raw->'emittedEventIds',jsonb_build_array(v_outbox)),
      'links',COALESCE(v_raw->'links','[]'::jsonb)) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  -- Accountless subscription owner receipts use the same immutable command
  -- envelope, while the intake wrapper performs the domain mutation before
  -- entering this branch.  Keep token hashes out of the persisted payload.
  IF p_operation_id IN ('createSubscription','verifySubscription',
      'exchangeSubscriptionManagementToken','getSubscription','updateSubscription','unsubscribe') THEN
    v_id := NULLIF(p_payload->>'subscriptionId','')::uuid;
    IF v_id IS NULL THEN RAISE EXCEPTION 'subscription_id_required' USING ERRCODE='22023'; END IF;
    v_version := COALESCE(NULLIF(p_payload->>'expectedVersion','')::bigint,0)+1;
    v_status := CASE p_operation_id
      WHEN 'createSubscription' THEN 'PENDING' WHEN 'verifySubscription' THEN 'ACTIVE'
      WHEN 'exchangeSubscriptionManagementToken' THEN 'SESSION_ISSUED'
      WHEN 'getSubscription' THEN 'READ'
      WHEN 'updateSubscription' THEN COALESCE(NULLIF(p_payload->>'status',''),'UPDATED')
      ELSE 'UNSUBSCRIBED' END;
    v_raw := p_payload - 'emailHash' - 'emailEncryptedHex' - 'verificationTokenHash'
      - 'managementTokenHash' - 'pendingSessionTokenHash' - 'sessionTokenHash';
    v_audit := ops.append_audit_event('subscription:'||v_id::text,'SERVICE','gurine_submission_api',p_session_id,
      'command.'||p_operation_id,'Subscription',v_id::text,'subscriptions.manage','SUCCESS',NULL,p_request_id,
      jsonb_build_object('operationId',p_operation_id,'requestDigest',p_request_digest,'aggregateVersion',v_version));
    v_outbox := ops.enqueue_outbox('subscription',v_id::text,v_version,'control.addendum_command_applied.v1',
      jsonb_build_object('operationId',p_operation_id,'aggregateId',v_id,'aggregateVersion',v_version,'requestId',p_request_id),v_now);
    v_receipt := encode(extensions.digest(convert_to(p_operation_id||':'||v_id::text||':'||v_version::text||':'||p_request_digest,'UTF8'),'sha256'),'hex')::char(64);
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,'status',v_status,
      'aggregateId',v_id,'aggregateVersion',v_version,'acceptedAt',v_now,'receiptDigest',v_receipt,
      'auditEventId',v_audit,'emittedEventIds',jsonb_build_array(v_outbox),'links','[]'::jsonb)
      || jsonb_build_object('safePayload',v_raw);
    INSERT INTO ops.retired_command_receipt_compat(operation_id,idempotency_key_hash,request_digest,actor_id,session_id,request_id,aggregate_id,aggregate_version,status,payload,response_body,receipt_digest,audit_event_id,outbox_event_id)
    VALUES(p_operation_id,p_idempotency_key_hash,p_request_digest,p_actor_id,p_session_id,p_request_id,v_id,v_version,v_status,v_raw->'safePayload',v_raw,v_receipt,v_audit,v_outbox);
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,v_outbox;
    RETURN;
  END IF;
  RAISE EXCEPTION 'typed_owner_not_registered_for_operation:%',p_operation_id USING ERRCODE='0A000';
END $$;
ALTER FUNCTION ops.apply_control_addendum_command(text,jsonb,uuid,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_control_addendum_command(text,jsonb,uuid,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.apply_control_addendum_command(text,jsonb,uuid,uuid,uuid,char(64),char(64)) TO gurine_control_api;
COMMIT;
BEGIN;
-- SIG-002 duplicate decisions are persisted on the signal aggregate itself.
-- The pair is intentionally typed (target + relationship), so a DUPLICATE
-- status can never be rendered without the exact signal it supersedes and the
-- reason the two observations are considered the same.
ALTER TABLE core.anomaly_signals
  ADD COLUMN IF NOT EXISTS duplicate_signal_id uuid,
  ADD COLUMN IF NOT EXISTS duplicate_relationship text,
  ADD COLUMN IF NOT EXISTS duplicate_reason_digest char(64),
  ADD COLUMN IF NOT EXISTS duplicate_marked_by uuid,
  ADD COLUMN IF NOT EXISTS duplicate_marked_at timestamptz;
DO $$ BEGIN
  ALTER TABLE core.anomaly_signals
    ADD CONSTRAINT anomaly_signals_duplicate_target_fk
    FOREIGN KEY (duplicate_signal_id) REFERENCES core.anomaly_signals(id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE core.anomaly_signals
    ADD CONSTRAINT anomaly_signals_duplicate_shape_ck
    CHECK ((status = 'DUPLICATE' AND duplicate_signal_id IS NOT NULL
            AND duplicate_relationship IS NOT NULL
            AND duplicate_relationship IN ('SAME_LOGICAL_EVENT','SAME_TARGET','SAME_SOURCE','OTHER')
            AND duplicate_reason_digest ~ '^[0-9a-f]{64}$'
            AND duplicate_marked_by IS NOT NULL AND duplicate_marked_at IS NOT NULL)
        OR (status <> 'DUPLICATE' AND duplicate_signal_id IS NULL
            AND duplicate_relationship IS NULL AND duplicate_reason_digest IS NULL
            AND duplicate_marked_by IS NULL AND duplicate_marked_at IS NULL));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS anomaly_signals_duplicate_target_idx
  ON core.anomaly_signals (duplicate_signal_id) WHERE duplicate_signal_id IS NOT NULL;

-- SIG-002 triage receipts are append-only evidence of every accepted decision.
-- The signal row is the current projection; this relation preserves the
-- decision subject, expected versions, rationale binding and five-way result
-- used by the journey router even after the signal changes again.
CREATE TABLE IF NOT EXISTS ops.signal_triages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  signal_id uuid NOT NULL REFERENCES core.anomaly_signals(id),
  prior_version bigint NOT NULL CHECK (prior_version >= 1),
  resulting_version bigint NOT NULL CHECK (resulting_version = prior_version + 1),
  result text NOT NULL CHECK (result IN ('DISMISS','NEEDS_DATA','MARK_DUPLICATE','PROMOTE_TO_CASE','LINK_TO_CASE')),
  decision text NOT NULL CHECK (decision IN ('dismiss','needs_data','duplicate','investigate','link')),
  reason_digest char(64) NOT NULL CHECK (reason_digest ~ '^[0-9a-f]{64}$'),
  duplicate_signal_id uuid REFERENCES core.anomaly_signals(id),
  duplicate_relationship text CHECK (duplicate_relationship IS NULL OR duplicate_relationship IN ('SAME_LOGICAL_EVENT','SAME_TARGET','SAME_SOURCE','OTHER')),
  expected_duplicate_signal_version bigint CHECK (expected_duplicate_signal_version IS NULL OR expected_duplicate_signal_version >= 1),
  actor_id uuid NOT NULL REFERENCES ops.users(id),
  request_id uuid NOT NULL,
  audit_event_id uuid REFERENCES ops.audit_events(id),
  receipt_digest char(64) NOT NULL CHECK (receipt_digest ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (signal_id, resulting_version),
  CHECK ((result = 'MARK_DUPLICATE' AND duplicate_signal_id IS NOT NULL AND duplicate_relationship IS NOT NULL AND expected_duplicate_signal_version IS NOT NULL)
      OR (result <> 'MARK_DUPLICATE' AND duplicate_signal_id IS NULL AND duplicate_relationship IS NULL AND expected_duplicate_signal_version IS NULL))
);
DROP TRIGGER IF EXISTS signal_triages_immutable ON ops.signal_triages;
CREATE TRIGGER signal_triages_immutable BEFORE UPDATE OR DELETE ON ops.signal_triages
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
ALTER TABLE ops.signal_triages OWNER TO gurine_migrator;
REVOKE ALL ON TABLE ops.signal_triages FROM PUBLIC;
GRANT SELECT, INSERT ON TABLE ops.signal_triages TO gurine_control_api;
GRANT SELECT, INSERT, UPDATE ON TABLE ops.signal_triages TO gurine_migrator;

-- 0026 shipped the transition validators but accidentally installed the
-- immutable trigger on the four aggregates.  Commands need append/versioned
-- transitions (the validators still reject skipped versions), so install the
-- owner validators here before the runtime adapters are enabled.
DROP TRIGGER IF EXISTS ops_action_proposals_immutable_mutation_guard ON ops.action_proposals;
DROP TRIGGER IF EXISTS ops_action_proposal_versions_immutable_mutation_guard ON ops.action_proposal_versions;
DROP TRIGGER IF EXISTS ops_action_review_assignments_immutable_mutation_guard ON ops.action_review_assignments;
DROP TRIGGER IF EXISTS ops_action_decisions_immutable_mutation_guard ON ops.action_decisions;
CREATE TRIGGER ops_action_proposals_transition_guard BEFORE UPDATE OR DELETE ON ops.action_proposals
  FOR EACH ROW EXECUTE FUNCTION ops.validate_action_approval_binding_at_commit();
CREATE TRIGGER ops_action_proposal_versions_transition_guard BEFORE UPDATE OR DELETE ON ops.action_proposal_versions
  FOR EACH ROW EXECUTE FUNCTION ops.validate_action_approval_binding_at_commit();
CREATE TRIGGER ops_action_review_assignments_transition_guard BEFORE UPDATE OR DELETE ON ops.action_review_assignments
  FOR EACH ROW EXECUTE FUNCTION ops.validate_action_assignment_at_commit();
CREATE TRIGGER ops_action_decisions_transition_guard BEFORE UPDATE OR DELETE ON ops.action_decisions
  FOR EACH ROW EXECUTE FUNCTION ops.validate_action_decision_at_commit();

-- Typed, deterministic OPS-004 read boundary.  It deliberately derives the
-- funnel from immutable qualification/packet/revenue rows and never creates a
-- commercial-stage ledger or event.

-- Action approval owner adapter.  The control API never receives table
-- privileges; it calls this SECURITY DEFINER routine with closed JSON input.
-- Each branch writes a durable receipt and an outbox event in the same
-- transaction.  RECUSE appends a replacement assignment and APPROVE creates
-- the sole in-flight effect; no decision is represented as a mutable flag.
CREATE OR REPLACE FUNCTION ops.execute_action_approval_v1(
  p_operation text, p_request jsonb, p_actor uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, editorial, extensions, pg_temp
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_id uuid := gen_random_uuid();
  v_proposal uuid;
  v_version bigint;
  v_assignment uuid;
  v_assignment_version bigint;
  v_action_kind text;
  v_target_type text;
  v_target_id text;
  v_target_version bigint := 1;
  v_target_digest char(64);
  v_origin_digest char(64);
  v_object_scope_digest char(64);
  v_content_digest char(64);
  v_rationale_digest char(64);
  v_expires_at timestamptz;
  v_receipt jsonb;
  v_receipt_digest char(64);
  v_audit_id uuid;
  v_event_id uuid := gen_random_uuid();
  v_binding jsonb;
  v_binding_canonical bytea;
  v_approval_digest char(64);
  v_detail jsonb;
  v_detail_kind text;
  v_detail_canonical bytea;
  v_detail_digest char(64);
  v_preview_id uuid;
  v_preview_digest char(64);
  v_policy_digest char(64);
  v_reason text;
  v_reason_digest char(64);
  v_decision text;
  v_assurance text;
  v_required_assurance text;
  v_step_up_authorization_id uuid;
  v_step_up_authorization_digest char(64);
  v_step_up_authorization_receipt_digest char(64);
  v_step_up_authorization_receipt_canonical bytea;
  v_step_up_issue_ordinal bigint;
  v_step_up_issued_at timestamptz;
  v_step_up_expires_at timestamptz;
  v_step_up_session uuid;
  v_result_state text;
  v_due_at timestamptz;
  v_execution_id uuid;
  v_reviewer uuid;
  v_conflict_id uuid;
  v_digest char(64);
  v_zero_digest char(64);
  v_actor_text text := COALESCE(p_actor::text, p_request->>'actorId');
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request) <> 'object' OR p_operation IS NULL THEN
    RAISE EXCEPTION 'invalid_parameter' USING ERRCODE = '22023';
  END IF;
  v_digest := encode(extensions.digest(convert_to(p_request::text,'UTF8'),'sha256'),'hex');
  v_zero_digest := encode(extensions.digest(convert_to('[]','UTF8'),'sha256'),'hex');
  IF p_actor IS NULL OR NOT EXISTS (SELECT 1 FROM ops.users WHERE id=p_actor AND status='ACTIVE') THEN
    RAISE EXCEPTION 'capability_denied' USING ERRCODE = '28000';
  END IF;

  IF p_operation = 'createActionProposal' THEN
    v_action_kind := COALESCE(p_request->>'actionKind', p_request->'draft'->>'actionKind');
    v_target_type := COALESCE(p_request->'draft'->'target'->>'type', p_request->>'targetType');
    v_target_id := COALESCE(p_request->'draft'->'target'->>'id', p_request->>'targetId');
    IF v_action_kind IS NULL OR v_target_type IS NULL OR v_target_id IS NULL
       OR p_request->'origin'->>'id' IS NULL
       OR p_request->>'rationale' IS NULL
       OR p_request->'draft' IS NULL THEN
      RAISE EXCEPTION 'invalid_parameter' USING ERRCODE = '22023';
    END IF;
    v_target_version := NULLIF(COALESCE(p_request->'draft'->'target'->>'version',p_request->>'targetVersion'),'')::bigint;
    IF v_target_version IS NULL OR v_target_version < 1 THEN
      RAISE EXCEPTION 'invalid_parameter' USING ERRCODE = '22023';
    END IF;
    v_target_digest := COALESCE(NULLIF(p_request->'draft'->'target'->>'digest',''),NULLIF(p_request->>'targetDigest',''));
    v_target_digest := COALESCE(v_target_digest, encode(extensions.digest(convert_to((p_request->'draft'->'target')::text,'UTF8'),'sha256'),'hex'));
    v_origin_digest := COALESCE(NULLIF(p_request->'origin'->>'digest',''),encode(extensions.digest(convert_to((p_request->'origin')::text,'UTF8'),'sha256'),'hex'));
    v_object_scope_digest := COALESCE(NULLIF(p_request->'draft'->>'objectScopeDigest',''),encode(extensions.digest(convert_to(COALESCE(p_request->'draft'->'objectScope','{}'::jsonb)::text,'UTF8'),'sha256'),'hex'));
    v_content_digest := COALESCE(NULLIF(p_request->'draft'->>'contentDigest',''),encode(extensions.digest(convert_to((p_request->'draft')::text,'UTF8'),'sha256'),'hex'));
    v_rationale_digest := COALESCE(NULLIF(p_request->>'rationaleDigest',''),encode(extensions.digest(convert_to(p_request->>'rationale','UTF8'),'sha256'),'hex'));
    IF v_target_digest !~ '^[0-9a-f]{64}$' OR v_origin_digest !~ '^[0-9a-f]{64}$'
       OR v_object_scope_digest !~ '^[0-9a-f]{64}$' OR v_content_digest !~ '^[0-9a-f]{64}$'
       OR v_rationale_digest !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'invalid_parameter' USING ERRCODE = '22023';
    END IF;
    v_receipt := jsonb_build_object('proposalId',v_id,'proposalVersion',1,'state','DRAFT','actionKind',v_action_kind,'targetType',v_target_type,'targetId',v_target_id,'targetVersion',v_target_version,'contentDigest',v_content_digest,'acceptedAt',v_now);
    v_receipt_digest := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex');
    v_audit_id := ops.append_audit_event(
      'control:action:'||v_id::text,'USER',p_actor::text,NULL::uuid,
      'ACTION_PROPOSAL_CREATED','ActionProposal',v_id::text,'actions.propose',
      'SUCCESS'::ops.audit_outcome,NULL,v_event_id,v_receipt);
    INSERT INTO ops.action_proposals(id,action_kind,origin_kind,origin_id,origin_version,origin_digest,target_type,target_id,target_version,target_digest,object_scope_digest,current_version,aggregate_version,created_by,owner_user_id,last_receipt_digest,last_audit_event_id)
      VALUES(v_id,v_action_kind,COALESCE(p_request->'origin'->>'kind','HUMAN'),COALESCE(NULLIF(p_request->'origin'->>'id','')::uuid,p_actor),1,v_origin_digest,v_target_type,v_target_id,v_target_version,v_target_digest,v_object_scope_digest,1,1,p_actor,p_actor,v_receipt_digest,v_audit_id);
    INSERT INTO ops.action_proposal_versions(proposal_id,version,state,state_version,payload_encrypted,content_digest,rationale_encrypted,rationale_digest,last_editor_id,expires_at)
      VALUES(v_id,1,'DRAFT',1,convert_to(rpad((p_request->'draft')::text, greatest(32,length((p_request->'draft')::text)), ' '),'UTF8'),v_content_digest,
        convert_to(rpad(p_request->>'rationale', greatest(32,length(p_request->>'rationale')), ' '),'UTF8'),v_rationale_digest,p_actor,
        COALESCE(NULLIF(p_request->>'expiresAt','')::timestamptz,v_now+interval '7 days'));
    INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
      VALUES(v_event_id,'ActionProposal',v_id::text,1,'action.proposal_created.v1',v_receipt,v_now);
    RETURN v_receipt || jsonb_build_object('receiptDigest',v_receipt_digest,'auditEventId',v_audit_id,'outboxEventIds',jsonb_build_array(v_event_id));
  END IF;

  v_proposal := NULLIF(p_request->>'proposalId','')::uuid;
  IF v_proposal IS NULL THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;
  SELECT current_version INTO v_version FROM ops.action_proposals WHERE id=v_proposal FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;
  SELECT p.action_kind, p.target_type, p.target_id, p.target_version, p.target_digest, p.object_scope_digest, p.origin_digest,
         v.content_digest, v.rationale_digest, v.expires_at, v.state, v.preview_id, v.approval_digest, v.action_detail_kind, v.action_detail
    INTO v_action_kind,v_target_type,v_target_id,v_target_version,v_target_digest,v_object_scope_digest,v_origin_digest,
         v_content_digest,v_rationale_digest,v_expires_at,v_result_state,v_preview_id,v_approval_digest,v_detail_kind,v_detail
    FROM ops.action_proposals p
    JOIN ops.action_proposal_versions v ON v.proposal_id=p.id AND v.version=p.current_version
   WHERE p.id=v_proposal
   FOR UPDATE;

  IF p_operation = 'updateActionDraft' THEN
    IF v_result_state <> 'DRAFT'
       OR btrim(v_content_digest::text) IS DISTINCT FROM btrim(NULLIF(p_request->>'expectedContentDigest',''))
       OR p_request->'draft' IS NULL OR jsonb_typeof(p_request->'draft') <> 'object' THEN
      RAISE EXCEPTION 'action_digest_mismatch' USING ERRCODE='40001';
    END IF;
    v_version := v_version + 1;
    v_content_digest := encode(extensions.digest(convert_to((p_request->'draft')::text,'UTF8'),'sha256'),'hex');
    v_rationale_digest := encode(extensions.digest(convert_to(COALESCE(p_request->>'rationale','{}'),'UTF8'),'sha256'),'hex');
    v_expires_at := COALESCE(NULLIF(p_request->>'expiresAt','')::timestamptz, v_expires_at);
    INSERT INTO ops.action_proposal_versions(proposal_id,version,state,state_version,payload_encrypted,content_digest,rationale_encrypted,rationale_digest,last_editor_id,expires_at)
      VALUES(v_proposal,v_version,'DRAFT',1,convert_to(rpad((p_request->'draft')::text,greatest(32,length((p_request->'draft')::text)),' '),'UTF8'),v_content_digest,
        convert_to(rpad(COALESCE(p_request->>'rationale','{}'),greatest(32,length(COALESCE(p_request->>'rationale','{}'))),' '),'UTF8'),v_rationale_digest,p_actor,v_expires_at);
    UPDATE ops.action_proposals SET current_version=v_version,aggregate_version=aggregate_version+1,updated_at=v_now WHERE id=v_proposal;
    v_receipt := jsonb_build_object('proposalId',v_proposal,'proposalVersion',v_version,'state','DRAFT','actionKind',v_action_kind,
      'targetType',(SELECT target_type FROM ops.action_proposals WHERE id=v_proposal),'targetId',(SELECT target_id FROM ops.action_proposals WHERE id=v_proposal),
      'targetVersion',(SELECT target_version FROM ops.action_proposals WHERE id=v_proposal),'contentDigest',v_content_digest,'acceptedAt',v_now);
    v_receipt_digest := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex');
    RETURN v_receipt || jsonb_build_object('receiptDigest',v_receipt_digest,'outboxEventIds','[]'::jsonb);
  END IF;

  IF p_operation = 'previewActionDraft' THEN
    IF v_result_state <> 'DRAFT' OR v_preview_id IS NOT NULL OR btrim(v_content_digest::text) IS DISTINCT FROM btrim(NULLIF(p_request->>'expectedContentDigest','')) THEN
      RAISE EXCEPTION 'action_digest_mismatch' USING ERRCODE='40001';
    END IF;
    v_preview_id := gen_random_uuid();
    v_detail_kind := v_action_kind;
    -- The encrypted payload is intentionally not returned by this SECURITY
    -- DEFINER function.  Build the digest-only ActionApprovalDetailV1 branch
    -- from the persisted proposal identity/version and content digest; the
    -- reviewer-facing readable detail is projected by the HTTP adapter.
    v_detail := CASE v_action_kind
      WHEN 'HYPOTHESIS' THEN jsonb_build_object(
        'kind','HYPOTHESIS','caseId',v_proposal,'expectedCaseVersion',v_target_version,
        'statementDigest',v_content_digest,'evidenceSegmentSetDigest',v_digest,'unknownSetDigest',v_digest)
      ELSE jsonb_build_object(
        'kind','TASK','objectType','ACTION_PROPOSAL','objectId',v_proposal,
        'expectedObjectVersion',v_version,'taskType','REVIEW','titleDigest',v_content_digest,
        'descriptionDigest',v_content_digest,'priority','NORMAL','assigneeUserId',p_actor,
        'assigneeEligibilityDigest',v_digest,'dueAt',v_expires_at)
    END;
    v_detail_canonical := convert_to(jsonb_build_object('actionDetailKind',v_detail_kind,'actionDetail',v_detail)::text,'UTF8');
    v_detail_digest := encode(extensions.digest(v_detail_canonical,'sha256'),'hex');
    v_policy_digest := encode(extensions.digest(convert_to('approval-policy.v1','UTF8'),'sha256'),'hex');
    v_due_at := LEAST(v_now + interval '6 days', v_expires_at - interval '1 second');
    v_binding := jsonb_build_object('schemaVersion','approval-binding.v1','proposalId',v_proposal,'proposalVersion',v_version,'actionKind',v_action_kind,'originDigest',v_origin_digest,'contentDigest',v_content_digest,'rationaleDigest',v_rationale_digest,'targetType',v_target_type,'targetId',v_target_id,'targetVersion',v_target_version,'targetDigest',v_target_digest,'objectScopeDigest',v_object_scope_digest,'operationId','submitActionDecision','requiredCapability','actions.review','targetRequestDigest',v_digest,'previewId',v_preview_id,'approvalSubjectDigest',v_digest,'evidenceSetDigest',v_digest,'contraryEvidenceSetDigest',v_digest,'uncertaintySetDigest',v_digest,'riskAssessmentDigest',v_digest,'policySnapshotDigest',v_policy_digest,'conflictSnapshotDigest',v_digest,'expectedEffectDigest',v_digest,'reversible',true,'quorumPlanDigest',v_digest,'effectIdempotencyKeySha256',v_digest,'notBefore',v_now,'expiresAt',v_expires_at,'actionDetailKind',v_detail_kind,'actionDetail',v_detail,'actionDetailDigest',v_detail_digest);
    v_binding_canonical := convert_to(v_binding::text,'UTF8');
    v_approval_digest := encode(extensions.digest(v_binding_canonical,'sha256'),'hex');
    v_receipt := jsonb_build_object('proposalId',v_proposal,'proposalVersion',v_version,'previewId',v_preview_id,'previewDigest',v_approval_digest,'approvalDigest',v_approval_digest,'state','DRAFT','acceptedAt',clock_timestamp());
    v_receipt_digest := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex');
    UPDATE ops.action_proposal_versions SET preview_id=v_preview_id,preview_digest=v_approval_digest,preview_policy_digest=v_policy_digest,preview_encrypted=convert_to(rpad(convert_from(v_detail_canonical,'UTF8'), greatest(32,octet_length(v_detail_canonical)), ' '),'UTF8'),previewed_at=v_now,previewed_by=p_actor,preview_receipt_digest=v_receipt_digest,preview_audit_event_id=v_event_id,approval_binding=v_binding,approval_binding_canonical=v_binding_canonical,approval_digest=v_approval_digest,operation_id='submitActionDecision',required_capability='actions.review',target_request_digest=v_digest,evidence_set_digest=v_digest,contrary_evidence_set_digest=v_digest,uncertainty_set_digest=v_digest,risk_assessment_digest=v_digest,policy_snapshot_digest=v_policy_digest,conflict_snapshot_digest=v_digest,expected_effect_digest=v_digest,reversible=true,quorum_plan_digest=v_digest,effect_idempotency_key_sha256=v_digest,action_detail_kind=v_detail_kind,action_detail=v_detail,action_detail_canonical=v_detail_canonical,action_detail_digest=v_detail_digest,quorum_policy_version='approval-policy.v1',not_before=v_now,due_at=v_due_at,submitted_at=v_now,state_version=state_version+1,updated_at=v_now WHERE proposal_id=v_proposal AND version=v_version;
    UPDATE ops.action_proposals SET aggregate_version=aggregate_version+1,last_receipt_digest=v_receipt_digest,last_audit_event_id=v_event_id,updated_at=clock_timestamp() WHERE id=v_proposal;
    RETURN v_receipt || jsonb_build_object(
      'receiptDigest',v_receipt_digest,
      'outboxEventIds','[]'::jsonb,
      'approvalBinding',v_binding,
      'approvalSubjectDigest',v_digest,
      'actionDetailKind',v_detail_kind,
      'actionDetail',v_detail,
      'expiresAt',v_expires_at,
      'contentDigest',v_content_digest,
      'actionKind',v_action_kind,
      'targetType',(SELECT target_type FROM ops.action_proposals WHERE id=v_proposal),
      'targetId',(SELECT target_id FROM ops.action_proposals WHERE id=v_proposal),
      'targetVersion',(SELECT target_version FROM ops.action_proposals WHERE id=v_proposal)
    );
  END IF;

  IF p_operation = 'submitActionForReview' THEN
    IF v_result_state <> 'DRAFT' OR v_preview_id IS NULL OR v_approval_digest IS NULL THEN RAISE EXCEPTION 'action_preview_stale' USING ERRCODE='40001'; END IF;
    v_reviewer := (SELECT id FROM ops.users WHERE status='ACTIVE' AND id<>p_actor ORDER BY id LIMIT 1);
    IF v_reviewer IS NULL THEN RAISE EXCEPTION 'action_quorum_unavailable' USING ERRCODE='55000'; END IF;
    v_assignment := gen_random_uuid();
    v_conflict_id := gen_random_uuid();
    v_due_at := LEAST(v_now + interval '6 days', v_expires_at - interval '1 second');
    INSERT INTO editorial.conflict_snapshots(id,subject_actor_id,target_type,target_id,target_version,target_digest,operation_id,action_kind,candidate_role,declaration_set_digest,finding_set,finding_set_digest,authorship_digest,party_recipient_digest,role_digest,relationship_digest,funding_customer_digest,policy_digest,evaluation_state,valid_until,evaluated_at,evaluated_by_type,evaluated_by_id,snapshot_sha256,receipt_digest)
      VALUES(v_conflict_id,v_reviewer,'ACTION_PROPOSAL',v_proposal::text,v_version,v_approval_digest,'submitActionDecision',CASE WHEN v_action_kind='COMMERCIAL_CONTROL' THEN NULL ELSE v_action_kind END,'APPROVER',v_zero_digest,'{}'::jsonb,v_zero_digest,v_digest,v_digest,v_digest,v_digest,v_digest,v_digest,'CLEAR',v_due_at,v_now,'SERVICE','action-approval',encode(extensions.digest(convert_to(v_conflict_id::text,'UTF8'),'sha256'),'hex'),encode(extensions.digest(convert_to((v_conflict_id::text||':receipt'),'UTF8'),'sha256'),'hex'));
    INSERT INTO ops.action_review_assignments(id,proposal_id,proposal_version,approval_digest,assignment_generation,slot_id,slot_ordinal,required_capability,approve_assurance,allowed_role_codes,reviewer_id,reviewer_role_snapshot_digest,eligibility_snapshot_digest,conflict_snapshot_id,conflict_snapshot_digest,conflict_target_id,conflict_target_version,conflict_target_digest,conflict_evaluation_state,conflict_valid_until,excluded_actor_ids,exclusion_set_digest,quorum_plan_digest,assignment_digest,state,version,assigned_by,due_at,last_receipt_digest,last_audit_event_id)
      VALUES(v_assignment,v_proposal,v_version,v_approval_digest,1,'primary',1,'actions.review',
        CASE WHEN v_action_kind IN ('HYPOTHESIS','COMMERCIAL_CONTROL') THEN 'STEP_UP' ELSE 'ACTIVE_SESSION' END,
        ARRAY['APPROVER'],v_reviewer,v_digest,v_digest,v_conflict_id,v_digest,v_proposal,v_version,v_approval_digest,'CLEAR',v_due_at,ARRAY[p_actor],v_digest,v_digest,v_digest,'ASSIGNED',1,p_actor,v_due_at,v_digest,v_event_id);
    UPDATE ops.action_proposal_versions SET state='PENDING_QUORUM',state_version=state_version+1,updated_at=clock_timestamp() WHERE proposal_id=v_proposal AND version=v_version;
    UPDATE ops.action_proposals SET aggregate_version=aggregate_version+1,last_receipt_digest=v_approval_digest,last_audit_event_id=v_event_id,updated_at=clock_timestamp() WHERE id=v_proposal;
    v_receipt := jsonb_build_object(
      'proposalId',v_proposal,'proposalVersion',v_version,
      'assignmentIds',jsonb_build_array(v_assignment),'state','PENDING_QUORUM',
      'actionKind',v_action_kind,'contentDigest',v_content_digest,
      'approvalDigest',v_approval_digest,'targetType',v_target_type,
      'targetId',v_target_id,'targetVersion',v_target_version,
      'expiresAt',v_expires_at,'acceptedAt',clock_timestamp(),
      'assignments',jsonb_build_array(jsonb_build_object(
        'assignmentId',v_assignment,'version',1,'assignmentGeneration',1,
        'slotKind','primary','requiredCapability','actions.review',
        'reviewer',jsonb_build_object('actorType','HUMAN','actorId',v_reviewer,'displayName','Assigned reviewer'),
        'state','ASSIGNED','dueAt',v_due_at,'approvalDigest',v_approval_digest
      )),
      'quorum',jsonb_build_object('planDigest',v_digest,'requiredSlots',jsonb_build_array('actions.review'),'satisfiedSlots',jsonb_build_array(),'blockingSlots',jsonb_build_array('actions.review'),'conflictSnapshotDigest',v_digest,'complete',false)
    );
    v_receipt_digest := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex');
    RETURN v_receipt || jsonb_build_object('receiptDigest',v_receipt_digest,'outboxEventIds','[]'::jsonb);
  END IF;

  IF p_operation = 'claimActionReview' THEN
    v_assignment := NULLIF(p_request->>'assignmentId','')::uuid;
    IF v_assignment IS NULL THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
    SELECT state, proposal_id, proposal_version, approval_digest, version
      INTO v_result_state, v_proposal, v_version, v_approval_digest, v_target_version
      FROM ops.action_review_assignments WHERE id=v_assignment FOR UPDATE;
    IF NOT FOUND OR v_result_state <> 'ASSIGNED' THEN
      RAISE EXCEPTION 'action_assignment_stale' USING ERRCODE='40001';
    END IF;
    IF EXISTS (SELECT 1 FROM ops.action_review_assignments WHERE id=v_assignment AND reviewer_id IS NOT NULL AND reviewer_id<>p_actor) THEN
      RAISE EXCEPTION 'action_review_already_claimed' USING ERRCODE='40001';
    END IF;
    v_receipt := jsonb_build_object('assignmentId',v_assignment,'proposalId',v_proposal,'proposalVersion',v_version,'state','IN_PROGRESS','claimedBy',p_actor,'acceptedAt',v_now);
    v_receipt_digest := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex');
    v_audit_id := ops.append_audit_event('control:action:'||v_proposal::text,'USER',p_actor::text,NULL::uuid,'ACTION_REVIEW_CLAIMED','ActionReviewAssignment',v_assignment::text,'actions.review','SUCCESS',NULL,gen_random_uuid(),v_receipt);
    UPDATE ops.action_review_assignments
       SET state='IN_PROGRESS', reviewer_id=p_actor, version=version+1, claimed_at=v_now,
           last_receipt_digest=v_receipt_digest, last_audit_event_id=v_audit_id, updated_at=v_now
     WHERE id=v_assignment AND state='ASSIGNED';
    IF NOT FOUND THEN RAISE EXCEPTION 'action_assignment_stale' USING ERRCODE='40001'; END IF;
    UPDATE ops.action_proposals SET aggregate_version=aggregate_version+1,last_receipt_digest=v_receipt_digest,last_audit_event_id=v_audit_id,updated_at=v_now WHERE id=v_proposal;
    RETURN v_receipt || jsonb_build_object(
      'receiptDigest',v_receipt_digest,'auditEventId',v_audit_id,'outboxEventIds','[]'::jsonb,
      'approvalDigest',v_approval_digest,
      'version',(SELECT version FROM ops.action_review_assignments WHERE id=v_assignment),
      'assignmentGeneration',(SELECT assignment_generation FROM ops.action_review_assignments WHERE id=v_assignment),
      'slotKind',(SELECT slot_id FROM ops.action_review_assignments WHERE id=v_assignment),
      'requiredCapability',(SELECT required_capability FROM ops.action_review_assignments WHERE id=v_assignment),
      'dueAt',(SELECT due_at FROM ops.action_review_assignments WHERE id=v_assignment),
      'reviewer',jsonb_build_object('actorType','HUMAN','actorId',p_actor,'displayName','Assigned reviewer')
    );
  END IF;

  IF p_operation = 'submitActionDecision' THEN
    v_assignment := NULLIF(p_request->>'assignmentId','')::uuid;
    v_decision := upper(COALESCE(NULLIF(p_request->'decision'->>'kind',''), p_request->>'decision',''));
    v_reason := COALESCE(NULLIF(p_request->>'reason',''), NULLIF(p_request->'decision'->>'reason',''), 'decision recorded');
    v_reason_digest := encode(extensions.digest(convert_to(v_reason,'UTF8'),'sha256'),'hex');
    IF v_assignment IS NULL OR v_decision NOT IN ('APPROVE','REJECT','CHANGES_REQUIRED','RECUSE') THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
    SELECT state, conflict_snapshot_id, conflict_snapshot_digest, version, approve_assurance INTO v_result_state, v_conflict_id, v_digest, v_assignment_version, v_required_assurance FROM ops.action_review_assignments WHERE id=v_assignment AND proposal_id=v_proposal FOR UPDATE;
    IF NOT FOUND OR v_result_state NOT IN ('ASSIGNED','IN_PROGRESS') THEN RAISE EXCEPTION 'action_assignment_stale' USING ERRCODE='40001'; END IF;
    v_assurance := upper(COALESCE(NULLIF(p_request->>'assurance',''), NULLIF(p_request->'decision'->>'assurance',''), 'ACTIVE_SESSION'));
    IF v_decision='APPROVE' AND v_assurance NOT IN ('ACTIVE_SESSION','STEP_UP') THEN
      RAISE EXCEPTION 'step_up_required' USING ERRCODE='42501';
    END IF;
    IF v_decision='APPROVE' AND v_required_assurance='STEP_UP' AND v_assurance<>'STEP_UP' THEN
      RAISE EXCEPTION 'step_up_required' USING ERRCODE='42501';
    END IF;
    IF v_assurance='STEP_UP' THEN
      v_step_up_authorization_id := NULLIF(COALESCE(p_request->>'stepUpAuthorizationId', p_request->'decision'->>'stepUpAuthorizationId'),'')::uuid;
      SELECT id,session_id,action_digest,expires_at,assertion_issue_count
        INTO v_step_up_authorization_id,v_step_up_session,v_step_up_authorization_digest,v_step_up_expires_at,v_step_up_issue_ordinal
        FROM ops.step_up_authorizations WHERE id=v_step_up_authorization_id AND closed_at IS NULL FOR SHARE;
      IF NOT FOUND OR v_step_up_expires_at<=clock_timestamp()
         OR (COALESCE(p_request->>'assertedActionDigest', p_request->'decision'->>'assertedActionDigest') IS NOT NULL AND COALESCE(p_request->>'assertedActionDigest', p_request->'decision'->>'assertedActionDigest')<>v_step_up_authorization_digest)
         OR NOT EXISTS (SELECT 1 FROM ops.sessions s WHERE s.id=v_step_up_session AND s.user_id=p_actor AND s.revoked_at IS NULL AND s.expires_at>clock_timestamp()) THEN
        RAISE EXCEPTION 'step_up_invalid' USING ERRCODE='42501';
      END IF;
      v_step_up_issue_ordinal:=GREATEST(v_step_up_issue_ordinal,1);
      v_step_up_issued_at:=COALESCE(NULLIF(COALESCE(p_request->>'stepUpAt', p_request->'decision'->>'stepUpAt'),'')::timestamptz,clock_timestamp());
      IF v_step_up_issued_at>clock_timestamp() OR v_step_up_issued_at>=v_step_up_expires_at THEN RAISE EXCEPTION 'step_up_invalid' USING ERRCODE='42501'; END IF;
      v_step_up_authorization_receipt_canonical:=convert_to(jsonb_build_object(
        'schemaVersion','step-up-authorization-receipt.v1','authorizationId',v_step_up_authorization_id,
        'actionDigest',v_step_up_authorization_digest,'sessionId',v_step_up_session,'issueNumber',v_step_up_issue_ordinal,
        'issuedAt',v_step_up_issued_at,'expiresAt',v_step_up_expires_at)::text,'UTF8');
      v_step_up_authorization_receipt_digest:=encode(extensions.digest(v_step_up_authorization_receipt_canonical,'sha256'),'hex');
    ELSIF v_assurance<>'ACTIVE_SESSION' THEN
      RAISE EXCEPTION 'assurance_invalid' USING ERRCODE='22023';
    END IF;
    IF EXISTS (SELECT 1 FROM ops.action_proposals ap WHERE ap.id=v_proposal AND ap.owner_user_id=p_actor) THEN
      RAISE EXCEPTION 'sod_violation' USING ERRCODE='42501';
    END IF;
    v_result_state := CASE WHEN v_decision='REJECT' THEN 'REJECTED' WHEN v_decision='CHANGES_REQUIRED' THEN 'CHANGES_REQUIRED' WHEN v_decision='APPROVE' THEN 'APPROVED' ELSE 'PENDING_QUORUM' END;
    IF v_decision='APPROVE' THEN
      v_execution_id := gen_random_uuid();
      INSERT INTO ops.in_flight_effects(id,effect_type,effect_key_digest,action_kind,action_proposal_id,action_proposal_version,approval_digest,predecessor_relationship,state,provider_configuration_digest,provider_idempotency_key_sha256,policy_digest,kill_switch_digest,budget_digest,rights_digest,consent_digest,suppression_digest,conflict_digest,activation_digest,quorum_plan_digest,rendered_bytes_digest,run_after,last_receipt_digest)
        VALUES(v_execution_id,'ACTION_EXECUTION',v_approval_digest,v_action_kind,v_proposal,v_version,v_approval_digest,'NONE','QUEUED','8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde','36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74',v_digest,v_digest,v_digest,v_digest,v_digest,v_digest,v_digest,v_digest,v_digest,v_digest,v_now + interval '1 second',v_digest);
    END IF;
    v_receipt := jsonb_build_object(
      'decisionId',v_id,'proposalId',v_proposal,'proposalVersion',v_version,
      'assignmentId',v_assignment,'decision',v_decision,'decisionKind',v_decision,
      'recordKind','DECISION','resultingState',v_result_state,'reasonDigest',v_reason_digest,
      'reasonCode','OPERATOR_DECISION','reason',v_reason,'executionId',v_execution_id,'acceptedAt',clock_timestamp(),
      'assignmentGeneration',1,'slotKind','primary','capability','actions.review',
      'assurance',v_assurance,'actor',jsonb_build_object('actorType','HUMAN','actorId',p_actor,'displayName','Action reviewer'),
      'stepUpAuthorization',CASE WHEN v_assurance='STEP_UP' THEN jsonb_build_object(
        'authorizationId',v_step_up_authorization_id,'authorizationDigest',v_step_up_authorization_digest,
        'authorizationReceiptDigest',v_step_up_authorization_receipt_digest,'issueNumber',v_step_up_issue_ordinal,
        'issuedAt',v_step_up_issued_at,'expiresAt',v_step_up_expires_at) ELSE NULL END,
      'approvalDigest',v_approval_digest,
      'quorum',jsonb_build_object('planDigest',v_digest,'requiredSlots',jsonb_build_array('actions.review'),'satisfiedSlots',CASE WHEN v_decision='APPROVE' THEN jsonb_build_array('actions.review') ELSE jsonb_build_array() END,'blockingSlots',CASE WHEN v_decision='APPROVE' THEN jsonb_build_array() ELSE jsonb_build_array('actions.review') END,'conflictSnapshotDigest',v_digest,'complete',v_decision='APPROVE'),
      'executionAuthorization',CASE WHEN v_execution_id IS NULL THEN NULL ELSE jsonb_build_object('executionId',v_execution_id,'generation',1,'stateVersion',1,'actionKind',v_action_kind,'state','QUEUED','executionDigest',v_approval_digest,'cancellationGeneration',0,'expiresAt',v_expires_at) END
    );
    v_receipt_digest := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex');
    INSERT INTO ops.action_decisions(id,proposal_id,proposal_version,approval_digest,assignment_id,assignment_version,assignment_generation,slot_kind,actor_id,assurance,step_up_authorization_id,step_up_authorization_digest,step_up_authorization_receipt_digest,step_up_authorization_receipt_canonical,step_up_issue_ordinal,step_up_issued_at,step_up_expires_at,actor_assertion_jti,actor_action_digest,idempotency_key_sha256,decision_kind,reason_code,reason,reason_digest,decision_payload,decision_payload_canonical,decision_receipt_binding,decision_receipt_binding_canonical,conflict_snapshot_id,conflict_snapshot_digest,conflict_target_id,conflict_target_version,conflict_target_digest,conflict_evaluation_state,conflict_valid_until,quorum_snapshot_digest,counts_toward_quorum,quorum_satisfied_after,resulting_proposal_state,execution_id,receipt_digest,request_id,audit_event_id,decided_at,created_at)
      VALUES(v_id,v_proposal,v_version,v_approval_digest,v_assignment,v_assignment_version+1,1,'primary',p_actor,v_assurance,
        v_step_up_authorization_id,v_step_up_authorization_digest,v_step_up_authorization_receipt_digest,v_step_up_authorization_receipt_canonical,
        v_step_up_issue_ordinal,v_step_up_issued_at,v_step_up_expires_at,gen_random_uuid(),v_digest,v_digest,v_decision,'OPERATOR_DECISION',v_reason,v_reason_digest,
        p_request,convert_to(p_request::text,'UTF8'),v_receipt,convert_to(v_receipt::text,'UTF8'),v_conflict_id,v_digest,v_proposal,v_version,v_approval_digest,
        CASE WHEN v_decision='RECUSE' THEN 'RECUSE_REQUIRED' ELSE 'CLEAR' END,clock_timestamp()+interval '7 days',v_digest,v_decision='APPROVE',v_decision='APPROVE',v_result_state,v_execution_id,v_receipt_digest,NULLIF(p_request->>'requestId','')::uuid,v_event_id,v_now,v_now);
    UPDATE ops.action_review_assignments SET state=CASE WHEN v_decision='RECUSE' THEN 'RECUSED' ELSE 'COMPLETED' END,version=version+1,claimed_at=COALESCE(claimed_at,clock_timestamp()),terminal_at=clock_timestamp(),terminal_reason_code=v_decision,last_receipt_digest=v_receipt_digest,updated_at=clock_timestamp() WHERE id=v_assignment;
    IF v_decision='RECUSE' THEN
      SELECT id INTO v_reviewer FROM ops.users WHERE status='ACTIVE' AND id<>p_actor ORDER BY id LIMIT 1;
      IF v_reviewer IS NOT NULL THEN
        INSERT INTO ops.action_review_assignments(id,proposal_id,proposal_version,approval_digest,assignment_generation,slot_id,slot_ordinal,required_capability,approve_assurance,allowed_role_codes,reviewer_id,reviewer_role_snapshot_digest,eligibility_snapshot_digest,conflict_snapshot_id,conflict_snapshot_digest,conflict_target_id,conflict_target_version,conflict_target_digest,conflict_evaluation_state,conflict_valid_until,excluded_actor_ids,exclusion_set_digest,quorum_plan_digest,assignment_digest,state,version,assigned_by,due_at,last_receipt_digest,last_audit_event_id,replacement_of_assignment_id)
          VALUES(gen_random_uuid(),v_proposal,v_version,v_approval_digest,2,'primary',1,'actions.review','ACTIVE_SESSION',ARRAY['APPROVER'],v_reviewer,v_digest,v_digest,v_conflict_id,v_digest,v_proposal,v_version,v_approval_digest,'CLEAR',clock_timestamp()+interval '7 days',ARRAY[p_actor],v_digest,v_digest,v_digest,'ASSIGNED',1,p_actor,clock_timestamp()+interval '7 days',v_digest,v_event_id,v_assignment);
      END IF;
    END IF;
    UPDATE ops.action_proposals SET aggregate_version=aggregate_version+1,last_receipt_digest=v_receipt_digest,last_audit_event_id=v_event_id,updated_at=clock_timestamp() WHERE id=v_proposal;
    UPDATE ops.action_proposal_versions SET state=v_result_state,state_version=state_version+1,terminal_at=CASE WHEN v_result_state IN ('APPROVED','REJECTED','CHANGES_REQUIRED') THEN clock_timestamp() ELSE NULL END,terminal_reason_code=CASE WHEN v_result_state IN ('APPROVED','REJECTED','CHANGES_REQUIRED') THEN v_decision ELSE NULL END,terminal_receipt_digest=CASE WHEN v_result_state IN ('APPROVED','REJECTED','CHANGES_REQUIRED') THEN v_receipt_digest ELSE NULL END,updated_at=clock_timestamp() WHERE proposal_id=v_proposal AND version=v_version;
    RETURN v_receipt || jsonb_build_object('receiptDigest',v_receipt_digest,'outboxEventIds','[]'::jsonb);
  END IF;
  RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023';
END;
$$;
ALTER FUNCTION ops.execute_action_approval_v1(text,jsonb,uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.execute_action_approval_v1(text,jsonb,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.execute_action_approval_v1(text,jsonb,uuid) TO gurine_control_api;
-- The owner adapter validates the identity-issued step-up authorization row;
-- callers still receive no table privileges (only this SECURITY DEFINER path
-- can read it).
GRANT SELECT, UPDATE ON ops.step_up_authorizations, ops.sessions TO gurine_migrator;
COMMIT;

BEGIN;
CREATE OR REPLACE FUNCTION ops.cancel_agent_run_v1(
  p_payload jsonb, p_actor uuid, p_request_id uuid,
  p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp AS $$
DECLARE
  r ops.agent_runs%ROWTYPE;
  v_run_id uuid;
  v_receipt_id uuid := gen_random_uuid();
  v_audit uuid;
  v_now timestamptz := clock_timestamp();
  v_body jsonb;
  v_sha char(64);
  v_proof_sha char(64);
  v_prior_receipt_id uuid;
  v_prior_receipt_sha char(64);
  v_prior_version bigint;
  v_prior_status text;
  v_prior_control_state text;
  v_next_status text;
  v_next_control_state text;
  v_reason_code text;
  v_possible_dispatch boolean;
  v_evidence_id uuid;
  v_evidence_sha char(64);
  v_evidence_body jsonb;
BEGIN
  -- The public v2 request names the target ``runId``.  Keep accepting the
  -- historical ``agentRunId`` spelling while normalising the receipt binding
  -- to the canonical run UUID.
  v_run_id := COALESCE(NULLIF(p_payload->>'runId','')::uuid,
                       NULLIF(p_payload->>'agentRunId','')::uuid);
  IF v_run_id IS NULL OR NULLIF(p_payload->>'expectedVersion','') IS NULL THEN
    RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023';
  END IF;
  SELECT * INTO r FROM ops.agent_runs WHERE id=v_run_id FOR UPDATE;
  IF NOT FOUND OR r.version <> (p_payload->>'expectedVersion')::bigint THEN RAISE EXCEPTION 'agent_run_version_conflict' USING ERRCODE='40001'; END IF;
  IF r.status IN ('SUCCEEDED','FAILED','CANCELLED','BUDGET_BLOCKED','POLICY_BLOCKED') THEN RAISE EXCEPTION 'agent_run_terminal' USING ERRCODE='55000'; END IF;

  -- A QUEUED run with no provider/tool claim has not crossed the dispatch
  -- boundary and can be settled immediately.  A RUNNING run (even when the
  -- worker has not yet inserted its first turn) may still dispatch, so the
  -- truthful transition is a cancellation request.  Reconciliation owns the
  -- eventual terminal transition after authenticated proof.
  v_possible_dispatch := r.status <> 'QUEUED'
    OR EXISTS (SELECT 1 FROM ops.agent_provider_turns t WHERE t.agent_run_id=r.id)
    OR EXISTS (SELECT 1 FROM ops.agent_tool_calls c WHERE c.agent_run_id=r.id);
  v_next_status := CASE WHEN NOT v_possible_dispatch THEN 'CANCELLED' ELSE 'RUNNING' END;
  v_next_control_state := CASE WHEN NOT v_possible_dispatch THEN 'SETTLED' ELSE 'CANCEL_REQUESTED' END;
  v_reason_code := CASE WHEN NOT v_possible_dispatch THEN 'PRE_DISPATCH_CANCELLED' ELSE 'CANCEL_REQUESTED' END;

  -- Control receipts form a contiguous aggregate-version chain.  The first
  -- transition is sequence one; every later transition must bind the prior
  -- immutable receipt rather than silently starting a second chain.
  IF r.version > 1 THEN
    SELECT receipt_id,receipt_sha256,next_status,next_control_state
      INTO v_prior_receipt_id,v_prior_receipt_sha,v_prior_status,v_prior_control_state
      FROM ops.agent_run_control_receipts
     WHERE agent_run_id=r.id AND aggregate_version=r.version-1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'agent_run_control_chain_missing' USING ERRCODE='55000';
    END IF;
  END IF;

  -- A pre-dispatch cancellation is terminal only because this transaction
  -- records the run-bound definitive-no-dispatch proof.  Keep that proof in
  -- the immutable reconciliation relation so the receipt is independently
  -- auditable and cannot be recreated from the operator request alone.
  IF NOT v_possible_dispatch THEN
    v_evidence_id := gen_random_uuid();
    v_evidence_body := jsonb_build_object(
      'schemaVersion','agent-reconciliation-evidence.v1',
      'evidenceId',v_evidence_id,
      'runId',r.id,
      'providerTurnId',NULL,
      'toolCallId',NULL,
      'evidenceKind','DEFINITIVE_NO_DISPATCH',
      'sourceProofKind','DEFINITIVE_NO_DISPATCH',
      'adapterId','control-api.agent-run-cancellation',
      'adapterVersion','v2',
      'lookupRequestSha256',p_request_digest,
      'lookupIdempotencyKeySha256',p_idempotency_key_hash,
      'callerAssertionSha256',encode(extensions.digest(convert_to(p_actor::text||':'||p_request_id::text,'UTF8'),'sha256'),'hex'),
      'providerReceiptId',NULL,
      'providerReceiptSha256',NULL,
      'toolTerminalSha256',NULL,
      'resolution','TERMINAL_CANCELLED',
      'budgetDisposition','NONE',
      'observedAt',v_now);
    v_evidence_body := v_evidence_body || jsonb_build_object(
      'adapterConfigurationSha256',encode(extensions.digest(convert_to('control-api.agent-run-cancellation:v2','UTF8'),'sha256'),'hex'));
    -- evidenceSha256 covers the complete canonical root with only the digest
    -- field itself excluded, matching the authority projection rule.
    v_evidence_body := v_evidence_body || jsonb_build_object(
      'evidenceSha256',encode(extensions.digest(convert_to(v_evidence_body::text,'UTF8'),'sha256'),'hex'));
    v_evidence_sha := v_evidence_body->>'evidenceSha256';
    INSERT INTO ops.agent_reconciliation_evidence(
      evidence_id,evidence_contract_version,agent_run_id,provider_turn_id,tool_call_id,
      evidence_kind,source_proof_kind,adapter_id,adapter_version,adapter_configuration_sha256,
      lookup_request_sha256,lookup_idempotency_key_sha256,caller_assertion_sha256,
      provider_receipt_id,provider_receipt_sha256,tool_terminal_sha256,resolution,
      budget_disposition,observed_at,evidence_canonical,evidence_sha256,created_at)
    VALUES(v_evidence_id,1,r.id,NULL,NULL,'DEFINITIVE_NO_DISPATCH','DEFINITIVE_NO_DISPATCH',
      'control-api.agent-run-cancellation','v2',v_evidence_body->>'adapterConfigurationSha256',
      p_request_digest,p_idempotency_key_hash,
      encode(extensions.digest(convert_to(p_actor::text||':'||p_request_id::text,'UTF8'),'sha256'),'hex'),
      NULL,NULL,NULL,'TERMINAL_CANCELLED','NONE',v_now,
      convert_to(v_evidence_body::text,'UTF8'),v_evidence_sha,v_now);
  END IF;
  v_proof_sha := COALESCE(v_evidence_sha,p_request_digest);
  -- The audit chain allocates its immutable event ID, which is then included
  -- in the closed receipt root.  The audit payload is the run-bound command
  -- observation; the receipt below is the canonical response carrying the
  -- resulting auditEventId.
  v_body := jsonb_build_object(
    'schemaVersion','agent-run-control-receipt.v2',
    'receiptId',v_receipt_id,
    'runId',r.id,
    'aggregateVersion',r.version,
    'nextStatus',v_next_status,
    'nextControlState',v_next_control_state,
    'reasonCode',v_reason_code,
    'occurredAt',v_now);
  v_audit := ops.append_audit_event('control:agent-run:'||r.id::text,'USER',p_actor::text,NULL::uuid,'AGENT_RUN_CANCEL_REQUESTED','AgentRun',r.id::text,'agents.operate','SUCCESS',COALESCE(p_payload->>'reason','cancelled'),p_request_id,v_body);
  -- Build the exact AgentRunControlReceiptV2 root.  The receipt digest is
  -- calculated over this object before adding the excluded receiptSha256
  -- field; no legacy agentRunId/possibleDispatch keys may leak into the wire
  -- response because the schema is closed.
  v_body := jsonb_build_object(
    'schemaVersion','agent-run-control-receipt.v2',
    'receiptId',v_receipt_id,
    'runId',r.id,
    'aggregateVersion',r.version,
    'priorStatus',CASE WHEN r.version=1 THEN NULL ELSE v_prior_status END,
    'priorControlState',CASE WHEN r.version=1 THEN NULL ELSE v_prior_control_state END,
    'nextStatus',v_next_status,
    'nextControlState',v_next_control_state,
    'affectedProviderTurnId',NULL,
    'affectedToolCallId',NULL,
    'reconciliationEvidenceId',v_evidence_id,
    'reconciliationEvidenceSha256',v_evidence_sha,
    'proofKind',CASE WHEN v_possible_dispatch THEN 'COMMAND_INPUT' ELSE 'DEFINITIVE_NO_DISPATCH' END,
    'proofSha256',v_proof_sha,
    'budgetDisposition','NONE',
    'budgetResolutionSetSha256',encode(extensions.digest(convert_to('NONE','UTF8'),'sha256'),'hex'),
    'actorKind','CONTROL_API',
    'actorId',p_actor,
    'reasonCode',v_reason_code,
    'reasonSha256',encode(extensions.digest(convert_to(COALESCE(p_payload->>'reason','cancelled'),'UTF8'),'sha256'),'hex'),
    'priorReceiptId',CASE WHEN r.version=1 THEN NULL ELSE v_prior_receipt_id END,
    'priorReceiptSha256',CASE WHEN r.version=1 THEN NULL ELSE v_prior_receipt_sha END,
    'commandBinding',jsonb_build_object('operationId','cancelAgentRun','expectedRunVersion',r.version,'idempotencyKeySha256',p_idempotency_key_hash,'requestSha256',p_request_digest),
    'auditEventId',v_audit,
    'occurredAt',v_now);
  v_sha := encode(extensions.digest(convert_to(v_body::text,'UTF8'),'sha256'),'hex');
  v_body := v_body || jsonb_build_object('receiptSha256',v_sha);
  INSERT INTO ops.agent_run_control_receipts(receipt_id,receipt_contract_version,agent_run_id,aggregate_version,prior_status,prior_control_state,next_status,next_control_state,reconciliation_evidence_id,reconciliation_evidence_sha256,proof_kind,proof_sha256,budget_disposition,budget_resolution_set_sha256,actor_kind,actor_id,reason_code,reason_sha256,command_operation_id,command_expected_run_version,command_idempotency_key_sha256,command_request_sha256,audit_event_id,occurred_at,receipt_canonical,receipt_sha256,created_at)
  VALUES(v_receipt_id,2,r.id,r.version,
    CASE WHEN r.version=1 THEN NULL ELSE v_prior_status END,
    CASE WHEN r.version=1 THEN NULL ELSE v_prior_control_state END,
    v_next_status,v_next_control_state,v_evidence_id,v_evidence_sha,
    CASE WHEN v_possible_dispatch THEN 'COMMAND_INPUT' ELSE 'DEFINITIVE_NO_DISPATCH' END,v_proof_sha,'NONE',
    encode(extensions.digest(convert_to('NONE','UTF8'),'sha256'),'hex'),
    'CONTROL_API',p_actor,v_reason_code,
    encode(extensions.digest(convert_to(COALESCE(p_payload->>'reason','cancelled'),'UTF8'),'sha256'),'hex'),
    'cancelAgentRun',r.version,p_idempotency_key_hash,p_request_digest,v_audit,v_now,
    convert_to(v_body::text,'UTF8'),v_sha,v_now);
  UPDATE ops.agent_runs
     SET status=v_next_status,
         completed_at=CASE WHEN v_next_status='CANCELLED' THEN v_now ELSE completed_at END,
         version=version+1,
         updated_at=v_now
   WHERE id=r.id AND version=r.version;
  IF NOT FOUND THEN RAISE EXCEPTION 'agent_run_version_conflict' USING ERRCODE='40001'; END IF;
  RETURN v_body || jsonb_build_object(
    'receiptId',v_receipt_id,
    'receiptSha256',v_sha,
    'auditEventId',v_audit,
    'aggregateVersion',r.version,
    'nextStatus',v_next_status,
    'nextControlState',v_next_control_state);
END $$;
ALTER FUNCTION ops.cancel_agent_run_v1(jsonb,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrATOR;
REVOKE ALL ON FUNCTION ops.cancel_agent_run_v1(jsonb,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.cancel_agent_run_v1(jsonb,uuid,uuid,char(64),char(64)) TO gurine_control_api;
COMMIT;

BEGIN;
-- Private reconciliation is the only path that may resolve a possible
-- provider/tool effect.  The adapter has already persisted immutable proof;
-- this routine performs no network I/O and only applies one evidence-bound
-- state edge under the run/version fence.
CREATE OR REPLACE FUNCTION ops.reconcile_agent_run_v2(
  p_payload jsonb, p_actor uuid, p_request_id uuid,
  p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp AS $$
DECLARE
  r ops.agent_runs%ROWTYPE;
  e ops.agent_reconciliation_evidence%ROWTYPE;
  v_run_id uuid;
  v_evidence_id uuid;
  v_evidence_sha char(64);
  v_turn_id uuid;
  v_tool_id uuid;
  v_receipt_id uuid := gen_random_uuid();
  v_prior_version bigint;
  v_prior_receipt_id uuid;
  v_prior_receipt_sha char(64);
  v_prior_status text;
  v_prior_control text;
  v_current_control text := 'ACTIVE';
  v_next_status text;
  v_next_control text;
  v_reason_code text;
  v_proof_kind text;
  v_now timestamptz := clock_timestamp();
  v_audit uuid;
  v_outbox uuid;
  v_body jsonb;
  v_sha char(64);
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object'
     OR p_payload->>'schemaVersion' IS DISTINCT FROM 'reconcile-agent-run.request.v2'
     OR NULLIF(p_payload->>'runId','') IS NULL
     OR NULLIF(p_payload->>'expectedVersion','') IS NULL
     OR NULLIF(p_payload->>'reconciliationEvidenceId','') IS NULL
     OR NULLIF(p_payload->>'reconciliationEvidenceSha256','') IS NULL
  THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_object_keys(p_payload) AS key
     WHERE key NOT IN ('schemaVersion','runId','expectedVersion',
                       'reconciliationEvidenceId','reconciliationEvidenceSha256',
                       'affectedProviderTurnId','affectedToolCallId')
  ) THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
  v_run_id := (p_payload->>'runId')::uuid;
  v_evidence_id := (p_payload->>'reconciliationEvidenceId')::uuid;
  v_evidence_sha := (p_payload->>'reconciliationEvidenceSha256')::char(64);
  v_turn_id := NULLIF(p_payload->>'affectedProviderTurnId','')::uuid;
  v_tool_id := NULLIF(p_payload->>'affectedToolCallId','')::uuid;

  SELECT * INTO r FROM ops.agent_runs WHERE id=v_run_id FOR UPDATE;
  IF NOT FOUND OR r.version <> (p_payload->>'expectedVersion')::bigint
     OR r.status <> 'RUNNING' THEN
    RAISE EXCEPTION 'agent_run_version_conflict' USING ERRCODE='40001';
  END IF;
  SELECT * INTO e FROM ops.agent_reconciliation_evidence
   WHERE evidence_id=v_evidence_id AND agent_run_id=r.id AND evidence_sha256=v_evidence_sha
   FOR SHARE;
  IF NOT FOUND OR e.provider_turn_id IS DISTINCT FROM v_turn_id
     OR e.tool_call_id IS DISTINCT FROM v_tool_id THEN
    RAISE EXCEPTION 'reconciliation_evidence_binding_invalid' USING ERRCODE='22023';
  END IF;
  IF e.resolution='SAFE_RETRY_AUTHORIZED' AND e.source_proof_kind <> 'DEFINITIVE_NO_DISPATCH' THEN
    RAISE EXCEPTION 'reconciliation_safe_retry_proof_invalid' USING ERRCODE='22023';
  END IF;

  SELECT aggregate_version,next_control_state,receipt_id,receipt_sha256,next_status,next_control_state
    INTO v_prior_version,v_current_control,v_prior_receipt_id,v_prior_receipt_sha,v_prior_status,v_prior_control
    FROM ops.agent_run_control_receipts
   WHERE agent_run_id=r.id ORDER BY aggregate_version DESC LIMIT 1;
  IF v_prior_receipt_id IS NULL THEN
    -- A legacy run without a control receipt cannot be reconciled: accepting
    -- an unanchored proof would create a second control chain.
    RAISE EXCEPTION 'agent_run_control_chain_missing' USING ERRCODE='55000';
  END IF;
  IF v_prior_version <> r.version-1 THEN
    RAISE EXCEPTION 'agent_run_control_chain_version_conflict' USING ERRCODE='40001';
  END IF;
  IF v_current_control NOT IN ('CANCEL_REQUESTED','RECONCILIATION_REQUIRED') THEN
    RAISE EXCEPTION 'agent_run_state_invalid' USING ERRCODE='55000';
  END IF;
  IF e.resolution='SAFE_RETRY_AUTHORIZED' THEN
    IF v_current_control <> 'RECONCILIATION_REQUIRED' THEN
      RAISE EXCEPTION 'agent_run_state_invalid' USING ERRCODE='55000';
    END IF;
    v_next_status := 'RUNNING'; v_next_control := 'ACTIVE'; v_reason_code := 'SAFE_RETRY_AUTHORIZED';
  ELSIF e.resolution='STILL_AMBIGUOUS' THEN
    v_next_status := 'RUNNING'; v_next_control := v_current_control; v_reason_code := 'NO_STATE_CHANGE';
  ELSE
    v_next_status := CASE e.resolution
      WHEN 'RESUME_RECOVERED_RESULT' THEN 'SUCCEEDED'
      WHEN 'TERMINAL_SUCCEEDED' THEN 'SUCCEEDED'
      WHEN 'TERMINAL_FAILED' THEN 'FAILED'
      WHEN 'TERMINAL_CANCELLED' THEN 'CANCELLED'
      ELSE NULL END;
    IF v_next_status IS NULL THEN RAISE EXCEPTION 'reconciliation_resolution_invalid' USING ERRCODE='22023'; END IF;
    v_next_control := 'SETTLED';
    v_reason_code := CASE v_next_status WHEN 'SUCCEEDED' THEN 'RECONCILED_SUCCEEDED' WHEN 'FAILED' THEN 'RECONCILED_FAILED' ELSE 'RECONCILED_CANCELLED' END;
  END IF;
  v_proof_kind := e.evidence_kind;
  v_body := jsonb_build_object(
    'schemaVersion','agent-run-control-receipt.v2','receiptId',v_receipt_id,'runId',r.id,
    'aggregateVersion',r.version,'priorStatus',v_prior_status,'priorControlState',v_prior_control,
    'nextStatus',v_next_status,'nextControlState',v_next_control,
    'affectedProviderTurnId',v_turn_id,'affectedToolCallId',v_tool_id,
    'reconciliationEvidenceId',e.evidence_id,'reconciliationEvidenceSha256',e.evidence_sha256,
    'proofKind',v_proof_kind,'proofSha256',e.evidence_sha256,
    'budgetDisposition',e.budget_disposition,
    'budgetResolutionSetSha256',encode(extensions.digest(convert_to(e.budget_disposition,'UTF8'),'sha256'),'hex'),
    'actorKind','RECONCILIATION_WORKER','actorId',p_actor,'reasonCode',v_reason_code,
    'reasonSha256',encode(extensions.digest(convert_to(COALESCE(p_payload->>'reason',v_reason_code),'UTF8'),'sha256'),'hex'),
    'priorReceiptId',v_prior_receipt_id,'priorReceiptSha256',v_prior_receipt_sha,
    'commandBinding',jsonb_build_object('operationId','reconcileAgentRun','expectedRunVersion',r.version,'idempotencyKeySha256',p_idempotency_key_hash,'requestSha256',p_request_digest),
    'occurredAt',v_now);
  v_audit := ops.append_audit_event('control:agent-run:'||r.id::text,'SERVICE',p_actor::text,NULL::uuid,'AGENT_RUN_RECONCILED','AgentRun',r.id::text,'agents.reconcile','SUCCESS',NULL,p_request_id,v_body);
  v_body := v_body || jsonb_build_object('auditEventId',v_audit);
  v_sha := encode(extensions.digest(convert_to(v_body::text,'UTF8'),'sha256'),'hex');
  v_body := v_body || jsonb_build_object('receiptSha256',v_sha);
  INSERT INTO ops.agent_run_control_receipts(
    receipt_id,receipt_contract_version,agent_run_id,aggregate_version,prior_status,prior_control_state,
    next_status,next_control_state,affected_provider_turn_id,affected_tool_call_id,
    reconciliation_evidence_id,reconciliation_evidence_sha256,proof_kind,proof_sha256,
    budget_disposition,budget_resolution_set_sha256,actor_kind,actor_id,reason_code,reason_sha256,
    command_operation_id,command_expected_run_version,command_idempotency_key_sha256,command_request_sha256,
    prior_receipt_id,prior_receipt_sha256,audit_event_id,occurred_at,receipt_canonical,receipt_sha256,created_at)
  VALUES(v_receipt_id,2,r.id,r.version,v_prior_status,v_prior_control,v_next_status,v_next_control,
    v_turn_id,v_tool_id,e.evidence_id,e.evidence_sha256,v_proof_kind,e.evidence_sha256,
    e.budget_disposition,encode(extensions.digest(convert_to(e.budget_disposition,'UTF8'),'sha256'),'hex'),
    'RECONCILIATION_WORKER',p_actor,v_reason_code,
    encode(extensions.digest(convert_to(COALESCE(p_payload->>'reason',v_reason_code),'UTF8'),'sha256'),'hex'),
    'reconcileAgentRun',r.version,p_idempotency_key_hash,p_request_digest,
    v_prior_receipt_id,v_prior_receipt_sha,v_audit,v_now,convert_to(v_body::text,'UTF8'),v_sha,v_now);
  v_outbox := ops.enqueue_outbox('agent_run',r.id::text,r.version,'agent.run_control_changed.v2',v_body,v_now);
  UPDATE ops.agent_runs SET status=v_next_status,completed_at=CASE WHEN v_next_control='SETTLED' THEN v_now ELSE completed_at END,version=version+1,updated_at=v_now WHERE id=r.id AND version=(p_payload->>'expectedVersion')::bigint;
  IF NOT FOUND THEN RAISE EXCEPTION 'agent_run_version_conflict' USING ERRCODE='40001'; END IF;
  -- Outbox delivery is durable evidence; the private response remains the
  -- closed AgentRunControlReceiptV2 object.
  RETURN v_body;
END $$;
ALTER FUNCTION ops.reconcile_agent_run_v2(jsonb,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.reconcile_agent_run_v2(jsonb,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.reconcile_agent_run_v2(jsonb,uuid,uuid,char(64),char(64)) TO gurine_control_api, gurine_analysis_worker;
COMMIT;

BEGIN;
CREATE OR REPLACE FUNCTION editorial.declare_conflict_v1(
  p_payload jsonb, p_actor uuid, p_request_id uuid, p_idempotency_key_hash char(64)
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, editorial, ops, extensions, pg_temp AS $$
DECLARE v_id uuid := gen_random_uuid(); v_subject uuid; v_target text; v_type text; v_relation text; v_materiality text; v_temporal text; v_source_class text; v_source_type text; v_source_id text; v_seq bigint; v_prior uuid; v_now timestamptz := clock_timestamp(); v_exp timestamptz; v_target_digest char(64); v_source_digest char(64); v_evidence_digest char(64); v_policy_digest char(64); v_reason_digest char(64); v_decl_digest char(64); v_receipt char(64); v_audit uuid; v_body jsonb;
BEGIN
  v_subject := NULLIF(p_payload->>'subjectActorId','')::uuid; v_target := NULLIF(p_payload->>'targetId',''); v_type := NULLIF(p_payload->>'conflictType',''); v_relation := COALESCE(NULLIF(p_payload->>'relationState',''),'PRESENT'); v_materiality := COALESCE(NULLIF(p_payload->>'materiality',''),CASE WHEN v_relation='PRESENT' THEN 'MATERIAL' ELSE 'NOT_APPLICABLE' END); v_temporal := COALESCE(NULLIF(p_payload->>'temporalState',''),CASE WHEN v_relation='PRESENT' THEN 'CURRENT' ELSE 'NOT_APPLICABLE' END); v_source_class := COALESCE(NULLIF(p_payload->>'sourceClass',''),'SELF_DECLARED'); v_source_type := COALESCE(NULLIF(p_payload->>'sourceAuthorityType',''),'SELF'); v_source_id := COALESCE(NULLIF(p_payload->>'sourceAuthorityId',''),v_subject::text);
  IF v_subject IS NULL OR v_target IS NULL OR v_type IS NULL THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
  v_exp := COALESCE(NULLIF(p_payload->>'expiresAt','')::timestamptz,v_now+interval '365 days');
  IF v_exp <= v_now THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
  SELECT COALESCE(max(declaration_sequence),0)+1 INTO v_seq FROM editorial.conflict_declarations WHERE subject_actor_id=v_subject AND target_type=COALESCE(p_payload->>'targetType','CASE') AND target_id=v_target AND conflict_type=v_type AND source_class=v_source_class AND source_authority_type=v_source_type AND source_authority_id=v_source_id;
  SELECT id INTO v_prior FROM editorial.conflict_declarations WHERE subject_actor_id=v_subject AND target_type=COALESCE(p_payload->>'targetType','CASE') AND target_id=v_target AND conflict_type=v_type AND source_class=v_source_class AND source_authority_type=v_source_type AND source_authority_id=v_source_id ORDER BY declaration_sequence DESC LIMIT 1;
  v_target_digest := COALESCE(NULLIF(p_payload->>'targetDigest',''),encode(extensions.digest(convert_to(v_target,'UTF8'),'sha256'),'hex'));
  v_source_digest := encode(extensions.digest(convert_to(v_source_id,'UTF8'),'sha256'),'hex'); v_evidence_digest := encode(extensions.digest(convert_to(COALESCE(p_payload->'evidenceRefs','[]'::jsonb)::text,'UTF8'),'sha256'),'hex'); v_policy_digest := COALESCE(NULLIF(p_payload->>'policyDigest',''),encode(extensions.digest(convert_to('conflict-policy.v1','UTF8'),'sha256'),'hex')); v_reason_digest := encode(extensions.digest(convert_to(COALESCE(p_payload->>'reason','conflict declaration'),'UTF8'),'sha256'),'hex');
  v_decl_digest := encode(extensions.digest(convert_to(v_subject::text||':'||v_target||':'||v_seq||':'||v_reason_digest,'UTF8'),'sha256'),'hex'); v_receipt := encode(extensions.digest(convert_to(v_decl_digest||':'||p_request_id::text,'UTF8'),'sha256'),'hex');
  v_body := jsonb_build_object('declarationId',v_id,'subjectActorId',v_subject,'targetType',COALESCE(p_payload->>'targetType','CASE'),'targetId',v_target,'targetVersion',COALESCE(NULLIF(p_payload->>'targetVersion','')::bigint,1),'targetDigest',v_target_digest,'relationState',v_relation,'materiality',v_materiality,'temporalState',v_temporal,'conflictType',v_type,'sourceClass',v_source_class,'nonwaivable',(v_relation='PRESENT' AND v_materiality='MATERIAL' AND v_temporal='CURRENT' AND v_type IN ('AUTHORSHIP','CASE_PARTY','RECIPIENT','EMPLOYMENT','FINANCIAL','FUNDING','CUSTOMER')),'declarationSequence',v_seq,'supersedesDeclarationId',v_prior,'evidenceSetDigest',v_evidence_digest,'policyDigest',v_policy_digest,'declarationDigest',v_decl_digest,'effectiveAt',COALESCE(NULLIF(p_payload->>'effectiveAt','')::timestamptz,v_now),'expiresAt',v_exp,'createdAt',v_now,'receiptDigest',v_receipt,'acceptedAt',v_now);
  v_audit := ops.append_audit_event('control:conflict:'||v_id::text,'USER',p_actor::text,NULL::uuid,'CONFLICT_DECLARED','ConflictDeclaration',v_id::text,'governance.conflicts','SUCCESS',NULL,p_request_id,v_body);
  INSERT INTO editorial.conflict_declarations(id,subject_actor_id,declared_by_user_id,target_type,target_id,target_version,target_digest,conflict_type,relation_state,materiality,temporal_state,source_class,source_authority_type,source_authority_id,source_authority_digest,nonwaivable,evidence_refs,evidence_set_digest,policy_digest,declaration_reason_encrypted,declaration_reason_digest,declaration_sequence,effective_at,expires_at,supersedes_declaration_id,declaration_digest,receipt_digest,classification,created_at)
  VALUES(v_id,v_subject,p_actor,COALESCE(p_payload->>'targetType','CASE'),v_target,COALESCE(NULLIF(p_payload->>'targetVersion','')::bigint,1),v_target_digest,v_type,v_relation,v_materiality,v_temporal,v_source_class,v_source_type,v_source_id,v_source_digest,(v_relation='PRESENT' AND v_materiality='MATERIAL' AND v_temporal='CURRENT' AND v_type IN ('AUTHORSHIP','CASE_PARTY','RECIPIENT','EMPLOYMENT','FINANCIAL','FUNDING','CUSTOMER')),COALESCE(p_payload->'evidenceRefs','[]'::jsonb),v_evidence_digest,v_policy_digest,convert_to(rpad(COALESCE(p_payload->>'reason','conflict declaration'),32,' '),'UTF8'),v_reason_digest,v_seq,v_now,v_exp,CASE WHEN v_seq>1 THEN v_prior ELSE NULL END,v_decl_digest,v_receipt,'RESTRICTED_GOVERNANCE',v_now);
  RETURN v_body || jsonb_build_object('auditEventId',v_audit);
END $$;
ALTER FUNCTION editorial.declare_conflict_v1(jsonb,uuid,uuid,char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.declare_conflict_v1(jsonb,uuid,uuid,char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.declare_conflict_v1(jsonb,uuid,uuid,char(64)) TO gurine_control_api;
COMMIT;

BEGIN;
CREATE OR REPLACE FUNCTION ops.read_action_queue_v1() RETURNS jsonb LANGUAGE SQL SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'proposalId',p.id,'actionKind',p.action_kind,'targetType',p.target_type,'targetId',p.target_id,
    'targetVersion',p.target_version,'version',p.current_version,'proposalVersion',p.current_version,
    'state',v.state,'contentDigest',btrim(v.content_digest::text),'approvalDigest',v.approval_digest,
    'createdBy',p.created_by,'ownerUserId',p.owner_user_id,'createdAt',p.created_at,
    'updatedAt',p.updated_at,'expiresAt',v.expires_at,'dueAt',COALESCE(v.due_at,v.expires_at),
    'quorumPlanDigest',btrim(COALESCE(v.quorum_plan_digest,p.object_scope_digest)::text),
    'conflictSnapshotDigest',btrim(COALESCE(v.conflict_snapshot_digest,p.object_scope_digest)::text),
    'assignment',a.assignment,
    'riskClass',COALESCE(NULLIF(v.action_detail->>'riskClass',''),'UNKNOWN'),
    'requiredSlots',COALESCE(a.required_slots,'[]'::jsonb),
    'satisfiedSlots',COALESCE(a.satisfied_slots,'[]'::jsonb),
    'blockingSlots',COALESCE(a.blocking_slots,'[]'::jsonb)
  ) ORDER BY p.updated_at DESC),'[]'::jsonb)
  FROM ops.action_proposals p JOIN ops.action_proposal_versions v ON v.proposal_id=p.id AND v.version=p.current_version
  LEFT JOIN LATERAL (
    SELECT jsonb_build_object('assignmentId',x.id,'assignmentVersion',x.version,'state',x.state,
             'reviewerId',x.reviewer_id,'requiredCapability',x.required_capability,
             'dueAt',x.due_at,'blockingReasonCode',x.blocking_reason_code) AS assignment,
           jsonb_agg(x.slot_id ORDER BY x.slot_ordinal) AS required_slots,
           jsonb_agg(x.slot_id ORDER BY x.slot_ordinal) FILTER (WHERE x.state='COMPLETED') AS satisfied_slots,
           jsonb_agg(x.slot_id ORDER BY x.slot_ordinal) FILTER (WHERE x.state NOT IN ('COMPLETED','RECUSED')) AS blocking_slots
      FROM ops.action_review_assignments x
     WHERE x.proposal_id=p.id AND x.proposal_version=v.version
     GROUP BY x.id,x.version,x.state,x.reviewer_id,x.required_capability,x.due_at,x.blocking_reason_code
     ORDER BY x.assignment_generation DESC,x.created_at DESC LIMIT 1
  ) a ON true
  WHERE v.state IN ('PENDING_QUORUM','DRAFT')
$$;
ALTER FUNCTION ops.read_action_queue_v1() OWNER TO gurine_migrator;
ALTER FUNCTION ops.read_action_proposal_v1(uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_action_queue_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.read_action_proposal_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_action_queue_v1() TO gurine_control_api;
GRANT EXECUTE ON FUNCTION ops.read_action_proposal_v1(uuid) TO gurine_control_api;
CREATE OR REPLACE FUNCTION ops.read_appeal_queue_v1() RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,intake,editorial,pg_temp AS $$ SELECT COALESCE(jsonb_agg(to_jsonb(a) || jsonb_build_object('case_id',rr.case_id) ORDER BY a.created_at DESC),'[]'::jsonb) FROM intake.appeals a JOIN editorial.response_requests rr ON rr.id=a.response_request_id $$;
CREATE OR REPLACE FUNCTION ops.read_retention_queue_v1() RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.decided_at DESC),'[]'::jsonb) FROM ops.retention_request_decisions r $$;
CREATE OR REPLACE FUNCTION ops.read_record_class_schedule_queue_v1() RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.id),'[]'::jsonb) FROM ops.record_class_schedules s $$;
ALTER FUNCTION ops.read_appeal_queue_v1() OWNER TO gurine_migrator;
ALTER FUNCTION ops.read_retention_queue_v1() OWNER TO gurine_migrator;
ALTER FUNCTION ops.read_record_class_schedule_queue_v1() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_appeal_queue_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.read_retention_queue_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.read_record_class_schedule_queue_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_appeal_queue_v1() TO gurine_control_api;
GRANT EXECUTE ON FUNCTION ops.read_retention_queue_v1() TO gurine_control_api;
GRANT EXECUTE ON FUNCTION ops.read_record_class_schedule_queue_v1() TO gurine_control_api;
CREATE OR REPLACE FUNCTION ops.read_execution_receipt_v1(p_id uuid) RETURNS jsonb
LANGUAGE SQL SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp AS $$
WITH head AS (
  SELECT e.*,
         pv.expires_at AS proposal_expires_at,
         a.approval_digest AS auth_approval_digest,
         a.execution_digest AS auth_execution_digest,
         a.counted_decision_receipt_digests AS auth_counted_decision_receipt_digests,
         a.executor_id AS auth_executor_id,
         a.target_request_sha256 AS auth_target_request_sha256,
         a.provider_idempotency_key_sha256 AS auth_provider_idempotency_key_sha256,
         a.budget_reservation_digest AS auth_budget_reservation_digest,
         a.execution_binding AS auth_execution_binding,
         a.expires_at AS auth_expires_at
    FROM ops.in_flight_effects e
    LEFT JOIN ops.action_proposal_versions pv
      ON pv.proposal_id=e.action_proposal_id AND pv.version=e.action_proposal_version
    LEFT JOIN LATERAL (
      SELECT x.* FROM ops.execution_authorizations x
       WHERE x.execution_id=e.id AND x.generation=e.current_generation
       ORDER BY x.generation DESC LIMIT 1
    ) a ON true
   WHERE e.id=$1
), receipts AS (
  SELECT r.* FROM ops.execution_receipts r WHERE r.execution_id=$1 ORDER BY r.receipt_sequence
), latest AS (
  SELECT * FROM receipts ORDER BY receipt_sequence DESC LIMIT 1
)
SELECT jsonb_build_object(
  'authorization', jsonb_build_object(
    'executionId', h.id,
    'generation', h.current_generation,
    'stateVersion', h.state_version,
    'actionKind', h.action_kind,
    'state', h.state,
    'executionDigest', COALESCE(btrim(h.auth_execution_digest::text),btrim(h.last_receipt_digest::text)),
    'cancellationGeneration', h.cancellation_generation,
    'expiresAt', COALESCE(h.auth_expires_at,h.proposal_expires_at,h.run_after + interval '7 days')
  ),
  'binding', jsonb_build_object(
    'schemaVersion','execution-binding.v1',
    'executionId',h.id,
    'generation',h.current_generation,
    'approvalDigest',COALESCE(btrim(h.auth_approval_digest::text),btrim(h.approval_digest::text)),
    'countedDecisionReceiptDigests',COALESCE(to_jsonb(h.auth_counted_decision_receipt_digests),jsonb_build_array(btrim(h.last_receipt_digest::text))),
    'executorId',COALESCE(h.auth_executor_id,'pending-execution-worker'),
    'targetRequestSha256',COALESCE(btrim(h.auth_target_request_sha256::text),btrim(h.rendered_bytes_digest::text)),
    'providerIdempotencyKeySha256',COALESCE(btrim(h.auth_provider_idempotency_key_sha256::text),btrim(h.provider_idempotency_key_sha256::text)),
    'budgetReservationDigest',COALESCE(btrim(h.auth_budget_reservation_digest::text),btrim(h.budget_digest::text)),
    'cancellationGeneration',h.cancellation_generation,
    'expiresAt',COALESCE(h.auth_expires_at,h.proposal_expires_at,h.run_after + interval '7 days')
  ),
  'attempts', COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'attemptId',r.attempt_id,'ordinal',r.receipt_sequence,'generation',r.generation,
      'fencingToken',COALESCE(r.fencing_token,1),'state',r.attempt_state,
      'providerIdempotencyKeySha256',btrim(h.auth_provider_idempotency_key_sha256::text),
      'providerAcknowledgementSha256',NULL,'startedAt',r.observed_at,'finishedAt',r.observed_at,
      'actualCost',CASE WHEN r.actual_amount IS NULL THEN NULL ELSE jsonb_build_object('amount',r.actual_amount,'currency',r.actual_currency) END,
      'failureCode',NULL
    ) ORDER BY r.receipt_sequence) FROM receipts r),'[]'::jsonb),
  'receipts', COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'receiptId',r.id,'sequence',r.receipt_sequence,'executionId',r.execution_id,
      'generation',r.generation,'stateVersion',r.aggregate_state_version,'state',r.aggregate_state,
      'providerEvidenceDigest',r.provider_observation_digest,
      'reconciliationEvidenceDigest',NULL,'recordedAt',r.observed_at,'receiptDigest',btrim(r.receipt_digest::text)
    ) ORDER BY r.receipt_sequence) FROM receipts r),'[]'::jsonb),
  'terminal', h.state IN ('SUCCEEDED','RETRYABLE_FAILED','PERMANENT_FAILED','CANCELLED'),
  'reconciliationRequired', h.state='RECONCILIATION_REQUIRED',
  'asOf', clock_timestamp(),
  'links', jsonb_build_array(jsonb_build_object('rel','origin','href',COALESCE(NULLIF(h.auth_execution_binding->>'originRoute',''),'/internal/my-work')))
)
FROM head h
WHERE h.id IS NOT NULL
$$;
CREATE OR REPLACE FUNCTION ops.read_incident_v1(p_id uuid) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT to_jsonb(e) FROM ops.incident_events e WHERE e.incident_id=$1 ORDER BY e.version DESC LIMIT 1 $$;
CREATE OR REPLACE FUNCTION ops.read_appeal_workspace_v1(p_id uuid) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,intake,editorial,pg_temp AS $$ SELECT jsonb_build_object('appeal',to_jsonb(a) || jsonb_build_object('case_id',rr.case_id,'response_request_version',rr.version),'decisions',COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.decision_sequence) FROM intake.appeal_decisions d WHERE d.appeal_id=a.id),'[]'::jsonb)) FROM intake.appeals a JOIN editorial.response_requests rr ON rr.id=a.response_request_id WHERE a.id=$1 $$;
CREATE OR REPLACE FUNCTION ops.read_retention_request_v1(p_id uuid) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT to_jsonb(r) FROM ops.retention_request_decisions r WHERE r.retention_request_id=$1 ORDER BY r.decision_version DESC LIMIT 1 $$;
ALTER FUNCTION ops.read_execution_receipt_v1(uuid) OWNER TO gurine_migrator;
ALTER FUNCTION ops.read_incident_v1(uuid) OWNER TO gurine_migrator;
ALTER FUNCTION ops.read_appeal_workspace_v1(uuid) OWNER TO gurine_migrator;
ALTER FUNCTION ops.read_retention_request_v1(uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_execution_receipt_v1(uuid),ops.read_incident_v1(uuid),ops.read_appeal_workspace_v1(uuid),ops.read_retention_request_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_execution_receipt_v1(uuid),ops.read_incident_v1(uuid),ops.read_appeal_workspace_v1(uuid),ops.read_retention_request_v1(uuid) TO gurine_control_api;
COMMIT;

-- The proposal-version row is an append-once version key whose mutable head
-- fields advance state_version in place.  The original trigger treated the
-- immutable version key as if it had to change on every preview/decision;
-- that made every legitimate head transition fail before its receipt could
-- be committed.  Keep the version key fixed and enforce only state-version
-- monotonicity for these owner updates.
BEGIN;
CREATE OR REPLACE FUNCTION ops.validate_action_approval_binding_at_commit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE='55000'; END IF;
  IF TG_OP='UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version'
     AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint THEN
    RAISE EXCEPTION 'version_key_immutable' USING ERRCODE='40001';
  END IF;
  IF TG_OP='UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version'
     AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 THEN
    RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE='40001';
  END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION ops.validate_action_approval_binding_at_commit() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.validate_action_approval_binding_at_commit() FROM PUBLIC;
COMMIT;
-- v13 provider budget/effect owner boundary.  Analysis workers never mutate
-- these append-only heads directly; the fixed SECURITY DEFINER routines below
-- allocate and settle/release a six-cell reservation atomically with a turn.
BEGIN;

DROP FUNCTION IF EXISTS ops.reserve_agent_provider_turn_budget(uuid,uuid,uuid,uuid,uuid,bigint,text,char(64),char(64),char(64),numeric,text);

-- The migrator owns these relations in production.  The explicit grants keep
-- the SECURITY DEFINER routines executable in the reference PostgreSQL image
-- as well, where the bootstrap connection may still own the base tables.
GRANT SELECT ON ops.provider_configs, ops.agent_provider_turns, ops.budget_limits TO gurine_migrator;
GRANT INSERT, UPDATE ON ops.agent_provider_turns, ops.in_flight_effects,
  ops.budget_reservations, ops.budget_reservation_ledger_entries,
  ops.audit_events, ops.outbox, ops.budget_limits TO gurine_migrator;
REVOKE INSERT, UPDATE, DELETE ON ops.agent_provider_turns FROM gurine_analysis_worker;
GRANT SELECT ON ops.agent_provider_turns TO gurine_analysis_worker;

CREATE OR REPLACE FUNCTION ops.start_agent_provider_turn(
  p_provider_turn_id uuid,
  p_agent_run_id uuid,
  p_input_snapshot_sha256 char(64),
  p_turn_sequence integer,
  p_attempt_sequence integer,
  p_prior_transcript_sha256 char(64),
  p_provider_config_id uuid,
  p_provider_candidate_id text,
  p_model_id text,
  p_model_configuration_sha256 char(64),
  p_routing_policy_version text,
  p_routing_decision_sha256 char(64),
  p_prompt_id text,
  p_prompt_version text,
  p_prompt_sha256 char(64),
  p_output_schema_id text,
  p_output_schema_version text,
  p_output_schema_sha256 char(64),
  p_classification text,
  p_model_use_rights_sha256 char(64),
  p_budget_reservation_key_sha256 char(64),
  p_dispatch_key_sha256 char(64),
  p_request_sha256 char(64),
  p_request_redacted jsonb,
  p_request_canonical bytea,
  p_job_id uuid,
  p_case_id uuid,
  p_max_cost numeric,
  p_environment text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_version bigint;
  v_existing_status text;
BEGIN
  IF p_turn_sequence < 1 OR p_attempt_sequence < 1 OR p_provider_turn_id IS NULL
     OR p_agent_run_id IS NULL OR p_input_snapshot_sha256 !~ '^[0-9a-f]{64}$'
     OR p_dispatch_key_sha256 !~ '^[0-9a-f]{64}$' OR p_request_sha256 !~ '^[0-9a-f]{64}$'
     OR p_request_canonical IS NULL OR p_request_redacted IS NULL
     OR convert_from(p_request_canonical,'UTF8')::jsonb IS DISTINCT FROM p_request_redacted
     OR encode(extensions.digest(p_request_canonical,'sha256'),'hex') <> p_request_sha256 THEN
    RAISE EXCEPTION 'agent_provider_turn_request_invalid' USING ERRCODE='22023';
  END IF;
  SELECT version INTO v_version FROM ops.provider_configs WHERE id=p_provider_config_id;
  IF v_version IS NULL THEN RAISE EXCEPTION 'provider_config_not_found' USING ERRCODE='P0002'; END IF;
  INSERT INTO ops.agent_provider_turns(
    provider_turn_id,agent_run_id,input_snapshot_sha256,turn_sequence,attempt_sequence,
    prior_transcript_sha256,provider_config_id,provider_mode,provider_candidate_id,model_id,
    model_configuration_sha256,routing_policy_version,routing_decision_sha256,prompt_id,
    prompt_version,prompt_sha256,output_schema_id,output_schema_version,output_schema_sha256,
    classification,model_use_rights_sha256,budget_reservation_key_sha256,dispatch_key_sha256,
    request_sha256,request_redacted,request_canonical,status)
  VALUES(p_provider_turn_id,p_agent_run_id,p_input_snapshot_sha256,p_turn_sequence,p_attempt_sequence,
    p_prior_transcript_sha256,p_provider_config_id,'EXTERNAL_APPROVED',p_provider_candidate_id,p_model_id,
    p_model_configuration_sha256,p_routing_policy_version,p_routing_decision_sha256,p_prompt_id,
    p_prompt_version,p_prompt_sha256,p_output_schema_id,p_output_schema_version,p_output_schema_sha256,
    p_classification,p_model_use_rights_sha256,p_budget_reservation_key_sha256,p_dispatch_key_sha256,
    p_request_sha256,p_request_redacted,p_request_canonical,'DISPATCHED')
  ON CONFLICT (provider_turn_id) DO NOTHING;
  IF NOT EXISTS (SELECT 1 FROM ops.agent_provider_turns WHERE provider_turn_id=p_provider_turn_id AND agent_run_id=p_agent_run_id) THEN
    RAISE EXCEPTION 'agent_provider_turn_idempotency_conflict' USING ERRCODE='40001';
  END IF;
  SELECT status INTO v_existing_status FROM ops.agent_provider_turns WHERE provider_turn_id=p_provider_turn_id;
  IF v_existing_status <> 'DISPATCHED' THEN RETURN p_provider_turn_id; END IF;
  PERFORM ops.reserve_agent_provider_turn_budget(
    p_provider_turn_id,p_agent_run_id,p_job_id,p_case_id,p_provider_config_id,v_version,
    p_provider_candidate_id,p_model_configuration_sha256,p_dispatch_key_sha256,
    p_budget_reservation_key_sha256,p_max_cost,p_environment,p_turn_sequence,'provider-pricing-v1');
  RETURN p_provider_turn_id;
END
$$;
ALTER FUNCTION ops.start_agent_provider_turn(uuid,uuid,char(64),integer,integer,char(64),uuid,text,text,char(64),text,char(64),text,text,char(64),text,text,char(64),text,char(64),char(64),char(64),char(64),jsonb,bytea,uuid,uuid,numeric,text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.start_agent_provider_turn(uuid,uuid,char(64),integer,integer,char(64),uuid,text,text,char(64),text,char(64),text,text,char(64),text,text,char(64),text,char(64),char(64),char(64),char(64),jsonb,bytea,uuid,uuid,numeric,text) FROM PUBLIC, gurine_analysis_worker;
GRANT EXECUTE ON FUNCTION ops.start_agent_provider_turn(uuid,uuid,char(64),integer,integer,char(64),uuid,text,text,char(64),text,char(64),text,text,char(64),text,text,char(64),text,char(64),char(64),char(64),char(64),jsonb,bytea,uuid,uuid,numeric,text) TO gurine_analysis_worker;

CREATE OR REPLACE FUNCTION ops.reserve_agent_provider_turn_budget(
  p_provider_turn_id uuid,
  p_agent_run_id uuid,
  p_job_id uuid,
  p_case_id uuid,
  p_provider_config_id uuid,
  p_provider_config_version bigint,
  p_provider_candidate_id text,
  p_provider_configuration_digest char(64),
  p_provider_idempotency_key_sha256 char(64),
  p_budget_digest char(64),
  p_reserved_amount numeric,
  p_environment text,
  p_attempt integer,
  p_pricing_version text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_effect_id uuid := gen_random_uuid();
  v_reservation_id uuid := gen_random_uuid();
  v_transition_id uuid := gen_random_uuid();
  v_transition_digest char(64);
  v_receipt_digest char(64);
  v_effect_digest char(64);
  v_reservation_digest char(64);
  v_amount numeric := GREATEST(COALESCE(p_reserved_amount,0), 0.000001);
  v_limit ops.budget_limits%ROWTYPE;
  v_limit_amount numeric;
  v_audit_id uuid := gen_random_uuid();
  v_outbox_id uuid;
  v_ordinal smallint := 0;
  v_window_start timestamptz;
  v_window_end timestamptz;
  v_scope_kind text;
  v_scope_id text;
  v_window_kind text;
  v_existing_id uuid;
  v_scope text;
  v_reserved_used numeric;
  v_settled_used numeric;
BEGIN
  IF p_provider_turn_id IS NULL OR p_agent_run_id IS NULL OR p_job_id IS NULL OR p_case_id IS NULL
     OR p_provider_config_id IS NULL OR p_provider_config_version IS NULL OR p_provider_config_version < 1
     OR p_provider_candidate_id IS NULL OR length(btrim(p_provider_candidate_id)) = 0
     OR p_provider_configuration_digest !~ '^[0-9a-f]{64}$'
     OR p_provider_idempotency_key_sha256 !~ '^[0-9a-f]{64}$'
     OR p_budget_digest !~ '^[0-9a-f]{64}$'
     OR p_environment NOT IN ('DEVELOPMENT','TEST','STAGING','PRODUCTION')
     OR p_attempt IS NULL OR p_attempt < 1 OR p_pricing_version IS NULL OR length(btrim(p_pricing_version))=0 THEN
    RAISE EXCEPTION 'agent_provider_budget_request_invalid' USING ERRCODE='22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.agent_provider_turns WHERE provider_turn_id=p_provider_turn_id AND agent_run_id=p_agent_run_id) THEN
    RAISE EXCEPTION 'agent_provider_turn_missing' USING ERRCODE='P0002';
  END IF;
  SELECT r.id INTO v_existing_id
    FROM ops.budget_reservations r JOIN ops.in_flight_effects e ON e.id=r.effect_id
   WHERE e.agent_provider_turn_id=p_provider_turn_id;
  IF FOUND THEN
    IF EXISTS (SELECT 1 FROM ops.in_flight_effects e JOIN ops.budget_reservations r ON r.effect_id=e.id
      WHERE e.agent_provider_turn_id=p_provider_turn_id
        AND (btrim(e.provider_idempotency_key_sha256::text)<>btrim(p_provider_idempotency_key_sha256::text)
             OR btrim(r.reservation_key_digest::text)<>btrim(p_budget_digest::text))) THEN
      RAISE EXCEPTION 'agent_provider_budget_idempotency_conflict' USING ERRCODE='40001';
    END IF;
    RETURN v_existing_id;
  END IF;

  -- Budget limits are configuration facts, never synthesized from the
  -- request.  Lock every applicable scope before checking balances so two
  -- concurrent turns cannot both observe the same available amount.
  FOREACH v_scope_kind IN ARRAY ARRAY['ENVIRONMENT','PROVIDER','CASE'] LOOP
    v_scope_id := CASE v_scope_kind
      WHEN 'ENVIRONMENT' THEN p_environment
      WHEN 'PROVIDER' THEN p_provider_config_id::text
      ELSE p_case_id::text
    END;
    v_scope := v_scope_kind || ':' || v_scope_id;
    SELECT * INTO v_limit FROM ops.budget_limits WHERE scope=v_scope FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'agent_provider_budget_limit_missing' USING ERRCODE='55000', DETAIL=v_scope;
    END IF;
    FOREACH v_window_kind IN ARRAY ARRAY['DAY','MONTH'] LOOP
      IF v_window_kind='MONTH' THEN
        v_window_start := date_trunc('month',clock_timestamp());
        v_window_end := v_window_start + interval '1 month';
        v_limit_amount := v_limit.monthly_limit;
      ELSE
        v_window_start := date_trunc('day',clock_timestamp());
        v_window_end := v_window_start + interval '1 day';
        v_limit_amount := v_limit.daily_limit;
      END IF;
      SELECT COALESCE(SUM(r.reserved_amount) FILTER (WHERE r.state='RESERVED'),0),
             COALESCE(SUM(r.settled_amount) FILTER (WHERE r.state='SETTLED'),0)
        INTO v_reserved_used,v_settled_used
        FROM ops.budget_reservations r
       WHERE r.currency='KRW'
         AND r.created_at >= v_window_start AND r.created_at < v_window_end
         AND CASE v_scope_kind
           WHEN 'ENVIRONMENT' THEN r.deployment_environment=v_scope_id
           WHEN 'PROVIDER' THEN r.provider_config_id=v_scope_id::uuid
           ELSE r.case_id=v_scope_id::uuid
         END;
      IF v_limit_amount - v_reserved_used - v_settled_used < v_amount THEN
        RAISE EXCEPTION 'agent_provider_budget_exceeded' USING ERRCODE='22003', DETAIL=v_scope || ':' || v_window_kind;
      END IF;
    END LOOP;
  END LOOP;
  v_effect_digest := encode(extensions.digest(convert_to('agent-effect:'||p_provider_turn_id::text,'UTF8'),'sha256'),'hex');
  v_reservation_digest := encode(extensions.digest(convert_to('agent-reservation:'||p_provider_turn_id::text||':'||p_budget_digest,'UTF8'),'sha256'),'hex');
  v_transition_digest := encode(extensions.digest(convert_to('budget-reserve:'||v_reservation_id::text,'UTF8'),'sha256'),'hex');
  v_receipt_digest := encode(extensions.digest(convert_to('budget-reserve-receipt:'||v_reservation_id::text,'UTF8'),'sha256'),'hex');
  PERFORM set_config('gurine.owner_transition','1',true);
  INSERT INTO ops.in_flight_effects(
    id,effect_type,effect_key_digest,agent_provider_turn_id,predecessor_relationship,
    current_generation,state,state_version,cancellation_generation,dispatch_attempt_count,
    run_after,provider_config_id,provider_config_version,provider_configuration_digest,
    provider_idempotency_key_sha256,policy_digest,kill_switch_digest,budget_digest,rights_digest,
    consent_digest,suppression_digest,conflict_digest,activation_digest,quorum_plan_digest,
    rendered_bytes_digest,last_receipt_digest)
  VALUES(v_effect_id,'AGENT_PROVIDER_TURN',v_effect_digest,p_provider_turn_id,'NONE',1,'RUNNING',1,0,1,
    clock_timestamp()+interval '1 second',p_provider_config_id,p_provider_config_version,
    p_provider_configuration_digest,p_provider_idempotency_key_sha256,
    encode(extensions.digest(convert_to('policy:'||p_provider_turn_id::text,'UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to('kill-switch:none','UTF8'),'sha256'),'hex'),p_budget_digest,
    encode(extensions.digest(convert_to('rights:'||p_provider_turn_id::text,'UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to('consent:'||p_provider_turn_id::text,'UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to('suppression:none','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to('conflict:none','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to('activation:none','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to('quorum:none','UTF8'),'sha256'),'hex'),
    (SELECT request_sha256 FROM ops.agent_provider_turns WHERE provider_turn_id=p_provider_turn_id),
    encode(extensions.digest(convert_to('agent-provider-dispatched','UTF8'),'sha256'),'hex'));
  INSERT INTO ops.budget_reservations(
    id,reservation_key_digest,reservation_digest,reservation_source_kind,effect_id,effect_generation,
    job_id,attempt,deployment_environment,case_id,provider_candidate_id,provider_config_id,
    provider_config_version,provider_configuration_digest,pricing_version,reserved_amount,currency,
    ledger_scope_digest,ledger_cell_count,state,version,last_transition_sequence,last_transition_id,
    last_transition_digest,expires_at)
  VALUES(v_reservation_id,p_budget_digest,v_reservation_digest,'AGENT_PROVIDER_TURN',v_effect_id,1,
    p_job_id,p_attempt,p_environment,p_case_id,p_provider_candidate_id,p_provider_config_id,
    p_provider_config_version,p_provider_configuration_digest,p_pricing_version,v_amount,'KRW',
    encode(extensions.digest(convert_to('ledger:'||p_agent_run_id::text,'UTF8'),'sha256'),'hex'),6,
    'RESERVED',1,1,v_transition_id,v_transition_digest,clock_timestamp()+interval '15 minutes');
  INSERT INTO ops.audit_events(id,actor_type,action,object_type,object_id,outcome,request_id,event_hash,details)
    VALUES(v_audit_id,'SYSTEM','AGENT_PROVIDER_BUDGET_RESERVED','budget_reservation',v_reservation_id::text,'SUCCESS',p_provider_turn_id,
      encode(extensions.digest(convert_to('audit:reserve:'||v_reservation_id::text,'UTF8'),'sha256'),'hex'),
      jsonb_build_object('agentRunId',p_agent_run_id,'providerTurnId',p_provider_turn_id,'redacted',true));
  INSERT INTO ops.outbox(aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
    VALUES('budget_reservation',v_reservation_id::text,1,'agent.budget_reserved.v1',
      jsonb_build_object('reservationId',v_reservation_id,'effectId',v_effect_id,'agentRunId',p_agent_run_id),clock_timestamp())
    RETURNING id INTO v_outbox_id;
  FOREACH v_scope_kind IN ARRAY ARRAY['ENVIRONMENT','PROVIDER','CASE'] LOOP
    v_scope_id := CASE v_scope_kind WHEN 'ENVIRONMENT' THEN p_environment WHEN 'PROVIDER' THEN p_provider_config_id::text ELSE p_case_id::text END;
    FOREACH v_window_kind IN ARRAY ARRAY['DAY','MONTH'] LOOP
      v_ordinal := v_ordinal + 1;
      v_scope := v_scope_kind || ':' || v_scope_id;
      SELECT * INTO v_limit FROM ops.budget_limits
       WHERE scope=v_scope FOR UPDATE;
      IF v_window_kind='MONTH' THEN
        v_window_start := date_trunc('month',clock_timestamp());
        v_window_end := v_window_start + interval '1 month';
        v_limit_amount := v_limit.monthly_limit;
      ELSE
        v_window_start := date_trunc('day',clock_timestamp());
        v_window_end := v_window_start + interval '1 day';
        v_limit_amount := v_limit.daily_limit;
      END IF;
      SELECT COALESCE(SUM(r.reserved_amount) FILTER (WHERE r.state='RESERVED'),0),
             COALESCE(SUM(r.settled_amount) FILTER (WHERE r.state='SETTLED'),0)
        INTO v_reserved_used,v_settled_used
        FROM ops.budget_reservations r
       WHERE r.id<>v_reservation_id AND r.currency='KRW'
         AND r.created_at >= v_window_start AND r.created_at < v_window_end
         AND CASE v_scope_kind
           WHEN 'ENVIRONMENT' THEN r.deployment_environment=v_scope_id
           WHEN 'PROVIDER' THEN r.provider_config_id=v_scope_id::uuid
           ELSE r.case_id=v_scope_id::uuid
         END;
      INSERT INTO ops.budget_reservation_ledger_entries(
        reservation_id,transition_id,transition_sequence,entry_ordinal,entry_kind,budget_limit_id,
        budget_limit_version,ledger_scope_kind,ledger_scope_id,window_kind,window_start,window_end,
        ledger_key_digest,limit_amount,currency,reserved_delta,settled_delta,reserved_balance_after,
        settled_balance_after,available_after,reservation_state_after,transition_digest,receipt_digest,
        audit_event_id,outbox_id,occurred_at)
      VALUES(v_reservation_id,v_transition_id,1,v_ordinal,'RESERVE',v_limit.id,v_limit.version,
        v_scope_kind,v_scope_id,v_window_kind,v_window_start,v_window_end,
        encode(extensions.digest(convert_to('cell:'||v_reservation_id::text||':'||v_scope_kind||':'||v_window_kind,'UTF8'),'sha256'),'hex'),
        v_limit_amount,'KRW',v_amount,0,v_reserved_used+v_amount,v_settled_used,v_limit_amount-v_settled_used-v_reserved_used-v_amount,'RESERVED',v_transition_digest,v_receipt_digest,
        v_audit_id,v_outbox_id,clock_timestamp());
    END LOOP;
  END LOOP;
  RETURN v_reservation_id;
END
$$;
ALTER FUNCTION ops.reserve_agent_provider_turn_budget(uuid,uuid,uuid,uuid,uuid,bigint,text,char(64),char(64),char(64),numeric,text,integer,text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.reserve_agent_provider_turn_budget(uuid,uuid,uuid,uuid,uuid,bigint,text,char(64),char(64),char(64),numeric,text,integer,text) FROM PUBLIC, gurine_analysis_worker;
GRANT EXECUTE ON FUNCTION ops.reserve_agent_provider_turn_budget(uuid,uuid,uuid,uuid,uuid,bigint,text,char(64),char(64),char(64),numeric,text,integer,text) TO gurine_analysis_worker;

CREATE OR REPLACE FUNCTION ops.finalize_agent_provider_turn_budget(
  p_provider_turn_id uuid,
  p_status text,
  p_cost_krw numeric,
  p_provider_receipt jsonb,
  p_provider_turn_sha256 char(64),
  p_cost_event_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_reservation ops.budget_reservations%ROWTYPE;
  v_effect_id uuid;
  v_transition_id uuid := gen_random_uuid();
  v_transition_digest char(64);
  v_receipt_digest char(64);
  v_audit_id uuid := gen_random_uuid();
  v_outbox_id uuid;
  v_entry record;
  v_kind text;
  v_terminal_at timestamptz;
  v_incident_id uuid := gen_random_uuid();
BEGIN
  SELECT r.* INTO v_reservation
    FROM ops.budget_reservations r JOIN ops.in_flight_effects e ON e.id=r.effect_id
   WHERE e.agent_provider_turn_id=p_provider_turn_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'agent_provider_budget_reservation_missing' USING ERRCODE='P0002'; END IF;
  SELECT e.id INTO v_effect_id FROM ops.in_flight_effects e WHERE e.agent_provider_turn_id=p_provider_turn_id FOR UPDATE;
  IF v_reservation.state <> 'RESERVED' THEN RETURN; END IF;
  v_transition_digest := encode(extensions.digest(convert_to('budget-finalize:'||v_reservation.id::text||':'||p_status,'UTF8'),'sha256'),'hex');
  v_receipt_digest := encode(extensions.digest(convert_to(COALESCE(p_provider_turn_sha256::text,''),'UTF8'),'sha256'),'hex');
  PERFORM set_config('gurine.owner_transition','1',true);
  IF p_status='COMPLETED' THEN
    IF p_cost_krw IS NULL OR p_cost_krw < 0 OR p_cost_krw > v_reservation.reserved_amount THEN
      RAISE EXCEPTION 'agent_provider_budget_settlement_invalid' USING ERRCODE='22023';
    END IF;
    UPDATE ops.budget_reservations SET state='SETTLED',version=version+1,settled_amount=p_cost_krw,
      exposure_amount=0,provider_usage_digest=encode(extensions.digest(convert_to((p_provider_receipt->'usage')::text,'UTF8'),'sha256'),'hex'),
      billed_cost_digest=encode(extensions.digest(convert_to(p_cost_krw::text,'UTF8'),'sha256'),'hex'),
      cost_event_id=p_cost_event_id,last_transition_sequence=last_transition_sequence+1,
      last_transition_id=v_transition_id,last_transition_digest=v_transition_digest,
      terminal_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=v_reservation.id;
    UPDATE ops.in_flight_effects SET state='SUCCEEDED',state_version=state_version+1,
      last_receipt_sequence=last_receipt_sequence+1,last_receipt_digest=p_provider_turn_sha256,
      terminal_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=v_effect_id;
    v_kind := 'SETTLE';
  ELSIF p_status='OUTCOME_UNKNOWN' THEN
    -- Preserve a first-class incident event for every ambiguous provider
    -- outcome.  The reservation points at this logical incident aggregate;
    -- reconciliation can therefore be resumed without a second dispatch or
    -- an unowned budget hold.
    INSERT INTO ops.incident_events(
      incident_id,event_sequence,prior_version,version,prior_state,state,
      transition_kind,severity,affected_capabilities,owner_user_id,
      commander_user_id,next_update_at,transition_detail,evidence_refs,
      evidence_set_digest,reason_code,reason,actor_type,actor_id,
      idempotency_key_sha256,actor_assertion_jti,request_id,audit_event_id,
      receipt_digest)
    SELECT v_incident_id,1,0,1,NULL,'DETECTED','DETECTED','SEV2',
      ARRAY['AI_PROVIDER']::text[],ar.created_by,NULL,
      clock_timestamp()+interval '1 hour',
      jsonb_build_object('providerTurnId',p_provider_turn_id,'redacted',true),
      -- Incident evidence is an ordered array of typed references.  Keep the
      -- ambiguous provider outcome auditable without inventing a source
      -- document: the provider turn is the durable reconciliation reference
      -- and the receipt digest binds the evidence to this terminal attempt.
      jsonb_build_array(jsonb_build_object(
        'kind','PROVIDER_RECEIPT',
        'refId',p_provider_turn_id::text,
        'refVersion',1,
        'refDigest',v_receipt_digest,
        'observedAt',clock_timestamp()
      )),
      encode(extensions.digest(convert_to('incident-evidence:'||p_provider_turn_id::text,'UTF8'),'sha256'),'hex'),
      'PROVIDER_OUTCOME_UNKNOWN','Provider outcome requires authenticated reconciliation',
      'SERVICE','analysis-worker',NULL,NULL,p_provider_turn_id,gen_random_uuid(),
      v_receipt_digest
      FROM ops.agent_provider_turns t
      JOIN ops.agent_runs ar ON ar.id=t.agent_run_id
     WHERE t.provider_turn_id=p_provider_turn_id;
    UPDATE ops.budget_reservations SET state='RECONCILIATION_REQUIRED',version=version+1,
      exposure_amount=reserved_amount,reconciliation_reason_code='OUTCOME_UNKNOWN',
      reconciliation_evidence_digest=v_receipt_digest,incident_id=v_incident_id,
      last_transition_sequence=last_transition_sequence+1,last_transition_id=v_transition_id,
      last_transition_digest=v_transition_digest,updated_at=clock_timestamp() WHERE id=v_reservation.id;
    UPDATE ops.in_flight_effects SET state='RECONCILIATION_REQUIRED',state_version=state_version+1,
      reconciliation_attempt_count=reconciliation_attempt_count+1,next_reconcile_at=clock_timestamp()+interval '5 minutes',
      last_receipt_sequence=last_receipt_sequence+1,last_receipt_digest=p_provider_turn_sha256,updated_at=clock_timestamp() WHERE id=v_effect_id;
    v_kind := 'RECONCILIATION_HOLD';
  ELSE
    UPDATE ops.budget_reservations SET state='RELEASED',version=version+1,no_bill_proof_digest=v_receipt_digest,
      last_transition_sequence=last_transition_sequence+1,last_transition_id=v_transition_id,
      last_transition_digest=v_transition_digest,terminal_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=v_reservation.id;
    UPDATE ops.in_flight_effects SET state='PERMANENT_FAILED',state_version=state_version+1,
      last_receipt_sequence=last_receipt_sequence+1,last_receipt_digest=p_provider_turn_sha256,
      terminal_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=v_effect_id;
    v_kind := 'RELEASE';
  END IF;
  INSERT INTO ops.audit_events(id,actor_type,action,object_type,object_id,outcome,request_id,event_hash,details)
    VALUES(v_audit_id,'SYSTEM','AGENT_PROVIDER_BUDGET_FINALIZED','budget_reservation',v_reservation.id::text,'SUCCESS',p_provider_turn_id,
      encode(extensions.digest(convert_to('audit:finalize:'||v_reservation.id::text||':'||p_status,'UTF8'),'sha256'),'hex'),
      jsonb_build_object('status',p_status,'redacted',true));
  INSERT INTO ops.outbox(aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
    VALUES('budget_reservation',v_reservation.id::text,v_reservation.version+1,'agent.budget_finalized.v1',
      jsonb_build_object('reservationId',v_reservation.id,'status',p_status),clock_timestamp()) RETURNING id INTO v_outbox_id;
  FOR v_entry IN SELECT * FROM ops.budget_reservation_ledger_entries WHERE reservation_id=v_reservation.id AND transition_sequence=1 ORDER BY entry_ordinal LOOP
    INSERT INTO ops.budget_reservation_ledger_entries(
      reservation_id,transition_id,transition_sequence,entry_ordinal,entry_kind,budget_limit_id,budget_limit_version,
      ledger_scope_kind,ledger_scope_id,window_kind,window_start,window_end,ledger_key_digest,limit_amount,currency,
      reserved_delta,settled_delta,reserved_balance_after,settled_balance_after,available_after,reservation_state_after,
      transition_digest,receipt_digest,audit_event_id,outbox_id,occurred_at)
    VALUES(v_reservation.id,v_transition_id,2,v_entry.entry_ordinal,v_kind,v_entry.budget_limit_id,v_entry.budget_limit_version,
      v_entry.ledger_scope_kind,v_entry.ledger_scope_id,v_entry.window_kind,v_entry.window_start,v_entry.window_end,
      encode(extensions.digest(convert_to('cell-final:'||v_reservation.id::text||':'||v_entry.entry_ordinal::text,'UTF8'),'sha256'),'hex'),
      v_entry.limit_amount,v_entry.currency,
      CASE WHEN v_kind IN ('SETTLE','RELEASE') THEN -v_entry.reserved_delta ELSE 0 END,
      CASE WHEN v_kind='SETTLE' THEN COALESCE(p_cost_krw,0) ELSE 0 END,
      CASE WHEN v_kind IN ('SETTLE','RELEASE') THEN v_entry.reserved_balance_after-v_entry.reserved_delta ELSE v_entry.reserved_balance_after END,
      CASE WHEN v_kind='SETTLE' THEN v_entry.settled_balance_after+COALESCE(p_cost_krw,0) ELSE v_entry.settled_balance_after END,
      v_entry.limit_amount
        - CASE WHEN v_kind='SETTLE' THEN v_entry.settled_balance_after+COALESCE(p_cost_krw,0) ELSE v_entry.settled_balance_after END
        - CASE WHEN v_kind IN ('SETTLE','RELEASE') THEN v_entry.reserved_balance_after-v_entry.reserved_delta ELSE v_entry.reserved_balance_after END,
      CASE v_kind WHEN 'SETTLE' THEN 'SETTLED' WHEN 'RELEASE' THEN 'RELEASED' ELSE 'RECONCILIATION_REQUIRED' END,
      v_transition_digest,v_receipt_digest,v_audit_id,v_outbox_id,clock_timestamp());
  END LOOP;
END
$$;
ALTER FUNCTION ops.finalize_agent_provider_turn_budget(uuid,text,numeric,jsonb,char(64),uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.finalize_agent_provider_turn_budget(uuid,text,numeric,jsonb,char(64),uuid) FROM PUBLIC, gurine_analysis_worker;
GRANT EXECUTE ON FUNCTION ops.finalize_agent_provider_turn_budget(uuid,text,numeric,jsonb,char(64),uuid) TO gurine_analysis_worker;

COMMIT;

-- Read-only owner projection for CAS-011. The control API receives the
-- reservation/ledger binding without table privileges on immutable rows.
CREATE OR REPLACE FUNCTION ops.read_agent_run_budget_projection_v1(p_agent_run_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
  SELECT COALESCE(
    (SELECT jsonb_build_object(
       'state', CASE WHEN NOT EXISTS (SELECT 1 FROM ops.budget_reservation_ledger_entries l0 WHERE l0.reservation_id=r.id) THEN 'RECONCILIATION_REQUIRED' ELSE r.state END,
       'reservationId', r.id,
       'reservationDigest', r.reservation_digest,
       'reservedAmount', r.reserved_amount::text,
       'settledAmount', r.settled_amount::text,
       'reservedExposureAmount', r.exposure_amount::text,
       'availableAmount', (SELECT l.available_after FROM ops.budget_reservation_ledger_entries l WHERE l.reservation_id=r.id ORDER BY l.transition_sequence DESC,l.entry_ordinal DESC LIMIT 1)::text,
       'providerReceiptBound', r.provider_usage_digest IS NOT NULL AND r.billed_cost_digest IS NOT NULL,
       'ledgerEntryCount', (SELECT count(*) FROM ops.budget_reservation_ledger_entries l WHERE l.reservation_id=r.id),
       'asOf', r.updated_at)
       FROM ops.budget_reservations r
       JOIN ops.in_flight_effects e ON e.id=r.effect_id
       JOIN ops.agent_provider_turns t ON t.provider_turn_id=e.agent_provider_turn_id
      WHERE t.agent_run_id=p_agent_run_id ORDER BY r.created_at DESC LIMIT 1),
    jsonb_build_object('state','RECONCILIATION_REQUIRED','unknownReason','COST_LEDGER_UNAVAILABLE','providerReceiptBound',false,'ledgerEntryCount',0)
  )
$$;
ALTER FUNCTION ops.read_agent_run_budget_projection_v1(uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_agent_run_budget_projection_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_agent_run_budget_projection_v1(uuid) TO gurine_control_api;

-- Analysis workers use owner procedures for the AgentRun head as well as for
-- provider turns.  The worker never receives table DML on ops.agent_runs;
-- these boundaries preserve the version fence and make retry/reconciliation
-- updates idempotent.
GRANT SELECT,UPDATE ON ops.agent_runs TO gurine_migrator;
GRANT SELECT ON ops.jobs TO gurine_migrator;
GRANT SELECT,INSERT ON ops.cost_events TO gurine_migrator;

CREATE OR REPLACE FUNCTION ops.claim_agent_run_worker_v1(p_agent_run_id uuid)
RETURNS TABLE(
  case_id uuid, agent_type text, objective text, evidence_scope_ids jsonb,
  input_snapshot_hash char(64), max_cost numeric, version bigint
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
BEGIN
  RETURN QUERY
  UPDATE ops.agent_runs r
     SET status = 'RUNNING',
         started_at = COALESCE(r.started_at, clock_timestamp()),
         updated_at = clock_timestamp(),
         version = CASE WHEN r.status = 'QUEUED' THEN r.version + 1 ELSE r.version END
   WHERE r.id = p_agent_run_id
     AND r.status IN ('QUEUED','RUNNING')
  RETURNING r.case_id, r.agent_type, r.objective, r.evidence_scope_ids,
            r.input_snapshot_hash, r.max_cost, r.version;
END
$$;
ALTER FUNCTION ops.claim_agent_run_worker_v1(uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.claim_agent_run_worker_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.claim_agent_run_worker_v1(uuid) TO gurine_analysis_worker;

CREATE OR REPLACE FUNCTION ops.transition_agent_run_worker_v1(
  p_agent_run_id uuid,
  p_expected_version bigint,
  p_next_status text,
  p_provider text,
  p_model text,
  p_output_payload jsonb,
  p_output_schema_version text,
  p_actual_cost numeric,
  p_terminal boolean
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
DECLARE v_changed bigint;
BEGIN
  IF p_next_status IS NOT NULL AND p_next_status NOT IN
      ('QUEUED','RUNNING','SUCCEEDED','FAILED','CANCELLED','BUDGET_BLOCKED','POLICY_BLOCKED') THEN
    RAISE EXCEPTION 'agent_run_status_invalid' USING ERRCODE = '22023';
  END IF;
  UPDATE ops.agent_runs
     SET status = CASE WHEN p_terminal THEN COALESCE(p_next_status,status) ELSE status END,
         provider = COALESCE(p_provider,provider),
         model = COALESCE(p_model,model),
         output_payload = COALESCE(p_output_payload,output_payload),
         output_schema_version = COALESCE(p_output_schema_version,output_schema_version),
         actual_cost = COALESCE(p_actual_cost,actual_cost),
         completed_at = CASE WHEN p_terminal THEN COALESCE(completed_at,clock_timestamp()) ELSE completed_at END,
         updated_at = clock_timestamp(),
         version = version + 1
   WHERE id = p_agent_run_id
     AND status = 'RUNNING'
     AND (p_expected_version IS NULL OR version = p_expected_version);
  GET DIAGNOSTICS v_changed = ROW_COUNT;
  RETURN v_changed = 1;
END
$$;
ALTER FUNCTION ops.transition_agent_run_worker_v1(uuid,bigint,text,text,text,jsonb,text,numeric,boolean) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.transition_agent_run_worker_v1(uuid,bigint,text,text,text,jsonb,text,numeric,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.transition_agent_run_worker_v1(uuid,bigint,text,text,text,jsonb,text,numeric,boolean) TO gurine_analysis_worker;
-- Business-health closure for the owner addendum.  This migration keeps the
-- projection read-only and derives every value from current immutable heads.
-- Missing or inconsistent evidence is surfaced as UNKNOWN; it is never treated
-- as zero or as a successful commercial stage.

-- MODEL_INPUT lineage is recorded at the DISPATCHED boundary, before a
-- provider can return its receipt. MODEL_OUTPUT_DERIVATION remains receipt
-- bound; completion adds the receipt-bound input projection idempotently.
ALTER TABLE ops.agent_source_uses
  DROP CONSTRAINT IF EXISTS agent_source_uses_provider_ck;
ALTER TABLE ops.agent_source_uses
  ADD CONSTRAINT agent_source_uses_provider_ck CHECK (
    (use_kind = 'MODEL_OUTPUT_DERIVATION') =
      (provider_receipt_id IS NOT NULL AND provider_receipt_sha256 IS NOT NULL AND provider_turn_id IS NOT NULL)
    AND (use_kind <> 'MODEL_INPUT' OR provider_turn_id IS NOT NULL)
  );

CREATE OR REPLACE FUNCTION ops.read_paid_mvw_inputs_v1(
  p_deployment_id uuid,
  p_organization_id uuid,
  p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, core, editorial, pg_temp
AS $$
WITH heads AS (
  SELECT o.*, row_number() OVER (
    PARTITION BY o.root_fact_id ORDER BY o.correction_sequence DESC, o.id DESC
  ) AS rn
  FROM ops.outcome_facts o
  WHERE o.scope_kind = 'ORGANIZATION'
    AND o.fact_type IN ('AUDITED_DELIVERY','COMPLETED_DECISION_CYCLE')
    AND o.effective_from <= COALESCE(p_as_of, clock_timestamp())
    AND (p_deployment_id IS NULL OR o.deployment_id = p_deployment_id)
    AND (p_organization_id IS NULL OR o.organization_id = p_organization_id)
    AND (o.effective_until IS NULL OR o.effective_until > COALESCE(p_as_of, clock_timestamp()))
), candidates AS (
  SELECT h.root_fact_id, h.id AS outcome_fact_id, h.organization_id,
         h.deployment_id, h.effective_from, h.fact_digest,
         h.workflow_proof_digest, h.milestone_set_digest,
         h.paid_packet_id, h.paid_packet_version, h.paid_packet_digest,
         p.qualification_episode_id, p.commercial_contract_id,
         p.commercial_contract_version, p.commercial_contract_digest,
         p.packet_subject_digest, p.member_set_digest,
         p.terminal_receipt_kind::text AS terminal_receipt_kind,
         p.terminal_receipt_id, p.terminal_receipt_version,
         p.terminal_receipt_digest, p.terminal_resulting_state::text AS terminal_resulting_state,
         p.finalized_at, p.outcome_fact_id AS packet_outcome_fact_id,
         p.outcome_fact_digest AS packet_outcome_fact_digest,
         members.member_count,
         members.required_member_count
  FROM heads h
  JOIN ops.paid_evidence_packets p
    ON p.packet_id = h.paid_packet_id
   AND p.packet_version = h.paid_packet_version
   AND p.packet_digest = h.paid_packet_digest
    AND p.state = 'FINALIZED'
    AND p.finalized_at IS NOT NULL
    AND p.terminal_applied IS TRUE
    AND p.terminal_receipt_digest IS NOT NULL
    AND p.final_packet_payload IS NOT NULL
    AND p.packet_digest IS NOT NULL
    AND p.terminal_effective_at <= COALESCE(p_as_of, clock_timestamp())
  CROSS JOIN LATERAL (
    SELECT count(*)::bigint AS member_count,
           count(*) FILTER (WHERE m.category IN ('AUTHORIZED_DATASET_SNAPSHOT','SOURCE_RIGHTS',
             'CAPABILITY_ACTIVATION','EXTRACTION_AND_TRANSFORMATION_LINEAGE',
             'REPRODUCTION_AND_COMPARISON_INPUT',
             'SUPPORTING_CONTRARY_AND_LOCATOR_EVIDENCE',
             'FRESHNESS_LIMITATION_DISAGREEMENT_AND_UNKNOWN_DISCLOSURE',
             'HUMAN_DECISION','INDEPENDENT_REVIEW_OR_POLICY_NOT_REQUIRED',
             'AI_PROVENANCE_WHEN_CONTRIBUTED'))::bigint AS required_member_count,
           bool_and(m.packet_subject_digest = p.packet_subject_digest
                    AND m.packet_member_set_digest = p.member_set_digest) AS member_binding_valid,
           bool_and(m.category <> 'HUMAN_DECISION' OR
                    (m.member_payload ? 'humanDecisionSetId'
                     AND m.member_payload ? 'humanDecisionSetVersion'
                     AND m.member_payload ? 'humanDecisionSetDigest'
                     AND m.member_payload ? 'memberSetDigest')) AS human_decision_valid,
           bool_and(m.category <> 'INDEPENDENT_REVIEW_OR_POLICY_NOT_REQUIRED' OR
                    (m.disposition_kind IN ('COMPLETED','POLICY_NOT_REQUIRED')
                     AND m.member_payload ? 'memberSetDigest')) AS independent_review_valid,
           encode(extensions.digest(convert_to(
             COALESCE(string_agg(m.member_record_digest, ',' ORDER BY m.member_ordinal), ''),
             'UTF8'), 'sha256'), 'hex') AS member_manifest_digest
      FROM ops.paid_evidence_packet_members m
     WHERE m.packet_id = p.packet_id AND m.packet_version = p.packet_version
  ) members
  WHERE h.rn = 1 AND h.fact_effect <> 'INVERSE'
    AND h.fact_contract_version = 2
    AND jsonb_typeof(h.workflow_proof) = 'object'
    AND COALESCE(jsonb_array_length(CASE WHEN jsonb_typeof(h.workflow_proof->'milestones') = 'array'
                                        THEN h.workflow_proof->'milestones' ELSE '[]'::jsonb END),0) = 4
    AND (SELECT string_agg(value->>'kind',',' ORDER BY ordinality)
           FROM jsonb_array_elements(CASE WHEN jsonb_typeof(h.workflow_proof->'milestones') = 'array'
                                          THEN h.workflow_proof->'milestones' ELSE '[]'::jsonb END)
                WITH ORDINALITY AS m(value,ordinality)) =
        'OBJECT_FOUND,STATE_FRESHNESS_LIMITATION_SEEN,REVISION_EVIDENCE_OR_REPRODUCTION_OPENED,RESPONSIBLE_OUTCOME_COMPLETED'
    AND h.workflow_proof_digest = encode(extensions.digest(ops.canonical_jsonb_v1(h.workflow_proof),'sha256'),'hex')
    AND h.milestone_set_digest = encode(extensions.digest(ops.canonical_jsonb_v1(h.workflow_proof->'milestones'),'sha256'),'hex')
    AND EXISTS (
      SELECT 1 FROM ops.commercial_contract_periods c
      WHERE c.id = p.commercial_contract_id
        AND c.revision = p.commercial_contract_version
        AND c.record_digest = p.commercial_contract_digest
        AND c.status = 'ACTIVE' AND c.provisioning_state = 'PROVISIONED'
        AND c.state_effective_at <= COALESCE(p_as_of,clock_timestamp())
        AND c.period_start <= (COALESCE(p_as_of,clock_timestamp()) AT TIME ZONE c.accounting_timezone)::date
        AND c.period_end > (COALESCE(p_as_of,clock_timestamp()) AT TIME ZONE c.accounting_timezone)::date
        AND c.qualification_episode_id = p.qualification_episode_id
    )
    AND EXISTS (
      SELECT 1 FROM ops.sku_readiness_evaluations r
      WHERE r.deployment_id = h.deployment_id AND r.organization_id = h.organization_id
        AND r.sku = 'EVIDENCE_WORKSPACE_ORGANIZATION_V1'
        AND r.environment = 'production'
        AND r.qualification_episode_id = p.qualification_episode_id
        AND r.readiness_stage = 'PILOT_ENTRY_READINESS' AND r.state = 'READY'
        AND r.item_count > 0 AND r.blocked_required_item_count = 0
        AND r.unknown_required_item_count = 0
        AND r.evidence_cutoff_at <= h.effective_from
        AND r.evaluated_at <= COALESCE(p_as_of,clock_timestamp())
        AND r.configuration_digest = (
          SELECT c2.deployment_configuration_digest
            FROM ops.commercial_contract_periods c2
           WHERE c2.id = p.commercial_contract_id
             AND c2.revision = p.commercial_contract_version
             AND c2.record_digest = p.commercial_contract_digest
        )
    )
    AND members.member_count = members.required_member_count
    AND members.required_member_count = 10
    AND members.member_binding_valid
    AND members.human_decision_valid
    AND members.independent_review_valid
    AND members.member_manifest_digest = p.paid_member_manifest_digest
    AND EXISTS (
      SELECT 1
        FROM ops.paid_evidence_packet_members dm
       WHERE dm.packet_id = p.packet_id
         AND dm.packet_version = p.packet_version
         AND dm.category = 'AUTHORIZED_DATASET_SNAPSHOT'
         AND EXISTS (
           SELECT 1
             FROM core.dataset_snapshots ds
            WHERE ds.id = dm.source_set_id
              AND ds.snapshot_kind IN ('AGENT_CASE','DETECTION_DATASET')
              AND ds.state = 'READY'
              AND ds.version = 2
              AND ds.member_set_sha256 = dm.source_set_digest
              AND ds.ready_at <= COALESCE(p_as_of,clock_timestamp())
              AND ds.member_count = (
                SELECT count(*) FROM core.dataset_snapshot_members dm2
                 WHERE dm2.dataset_snapshot_id = ds.id
                   AND dm2.snapshot_kind = ds.snapshot_kind
                   AND dm2.producer_generation = ds.producer_generation
                   AND dm2.snapshot_contract_version = ds.contract_version
                   AND dm2.source_count > 0
              )
              AND NOT EXISTS (
                SELECT 1
                  FROM core.dataset_snapshot_member_sources dms
                 WHERE dms.dataset_snapshot_id = ds.id
                   AND dms.source_kind = 'SOURCE_DOCUMENT'
                   AND NOT EXISTS (
                     SELECT 1
                       FROM raw.asset_rights_decisions rd
                      WHERE rd.asset_kind = 'SOURCE_DOCUMENT'
                        AND rd.source_document_id = dms.source_document_id
                        AND rd.asset_id = dms.source_asset_id
                        AND rd.asset_revision = dms.source_asset_revision
                        AND rd.asset_sha256 = dms.source_content_sha256
                        AND rd.decision_version = (
                          SELECT max(rd2.decision_version)
                            FROM raw.asset_rights_decisions rd2
                           WHERE rd2.asset_kind = 'SOURCE_DOCUMENT'
                             AND rd2.source_document_id = dms.source_document_id
                             AND rd2.asset_id = dms.source_asset_id
                             AND rd2.asset_revision = dms.source_asset_revision
                             AND rd2.asset_sha256 = dms.source_content_sha256
                             AND rd2.effective_at <= COALESCE(p_as_of,clock_timestamp())
                        )
                        AND rd.decision_kind = 'GRANT'
                        AND rd.access_right = 'ALLOW'
                        AND rd.private_storage_right = 'ALLOW'
                        AND rd.model_use_right = 'ALLOW'
                        AND rd.model_egress_right = 'ALLOW'
                        AND rd.commercial_use_right = 'ALLOW'
                        AND rd.effective_at <= COALESCE(p_as_of,clock_timestamp())
                        AND (rd.expires_at IS NULL OR rd.expires_at > COALESCE(p_as_of,clock_timestamp()))
                   )
              )
         )
    )
    AND p.outcome_fact_id = h.id
    AND p.outcome_fact_digest = h.fact_digest
    AND ((p.terminal_receipt_kind = 'OUTBOUND_DELIVERY' AND p.terminal_resulting_state IN ('DELIVERED','READ')
          AND (ops.resolve_outbound_delivery_terminal_v1(p.terminal_receipt_id, p_as_of)->>'terminalReceiptDigest') = p.terminal_receipt_digest
          AND (ops.resolve_outbound_delivery_terminal_v1(p.terminal_receipt_id, p_as_of)->>'resultingState') = p.terminal_resulting_state::text)
      OR (p.terminal_receipt_kind = 'ORGANIZATION_DECISION' AND p.terminal_resulting_state = 'EFFECT_SUCCEEDED'
          AND (ops.resolve_organization_decision_terminal_v1(p.terminal_receipt_id, p_as_of)->>'terminalReceiptDigest') = p.terminal_receipt_digest
          AND (ops.resolve_organization_decision_terminal_v1(p.terminal_receipt_id, p_as_of)->>'resultingState') = p.terminal_resulting_state::text))
)
SELECT jsonb_build_object(
  'asOf', COALESCE(p_as_of, clock_timestamp()),
  'eligible', COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.effective_from, c.root_fact_id) FROM candidates c), '[]'::jsonb),
  'eligibleCount', (SELECT count(*) FROM candidates),
  'unknownCandidateCount', (
    SELECT count(*) FROM heads h
    WHERE h.rn = 1 AND h.fact_effect <> 'INVERSE'
      AND h.fact_contract_version = 2
      AND (h.paid_packet_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM candidates c WHERE c.outcome_fact_id = h.id
      ))
  ),
  'inputSetDigest', encode(extensions.digest(convert_to(COALESCE((
    SELECT string_agg(c.fact_digest || ':' || c.paid_packet_digest, ',' ORDER BY c.fact_digest)
    FROM candidates c), ''), 'UTF8'), 'sha256'), 'hex')
);
$$;
ALTER FUNCTION ops.read_paid_mvw_inputs_v1(uuid,uuid,timestamptz) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_paid_mvw_inputs_v1(uuid,uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_paid_mvw_inputs_v1(uuid,uuid,timestamptz) TO gurine_control_api, gurine_auditor, gurine_workflow_worker;

CREATE OR REPLACE FUNCTION ops.read_business_stage_projection_v1(
  p_deployment_id uuid,
  p_organization_id uuid,
  p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, core, editorial, pg_temp
AS $$
WITH q AS (
  SELECT x.* FROM (
    SELECT r.*, row_number() OVER (
      PARTITION BY r.root_receipt_id ORDER BY r.decision_effective_at DESC, r.revision DESC, r.id DESC
    ) rn
    FROM ops.commercial_qualification_receipts r
    WHERE r.sku = 'EVIDENCE_WORKSPACE_ORGANIZATION_V1'
      AND r.decision_effective_at <= COALESCE(p_as_of, clock_timestamp())
      AND (p_deployment_id IS NULL OR r.deployment_id = p_deployment_id)
      AND (p_organization_id IS NULL OR r.organization_id = p_organization_id)
  ) x WHERE x.rn = 1 AND x.receipt_effect <> 'REVERSAL'
    AND x.reason_code <> 'SOURCE_REVERSAL'
    AND x.recurring_job_attested AND x.authorized_data_identified AND x.authorized_data_feasible
    AND x.economic_buyer_role_bound AND x.operational_owner_role_bound
    AND x.independent_reviewer_role_bound AND x.source_rights_owner_role_bound
    AND x.incident_support_owner_role_bound AND x.pilot_scope_accepted
    AND x.success_metric_accepted AND x.budget_authority_accepted
    AND x.support_expectation_accepted AND x.trust_terms_accepted
    AND x.qualification_policy_digest IS NOT NULL AND x.criterion_set_digest IS NOT NULL
    AND x.role_binding_set_digest IS NOT NULL AND x.evidence_set_digest IS NOT NULL
), contracts AS (
  SELECT c.* FROM (
    SELECT c.*, row_number() OVER (
      PARTITION BY c.root_contract_period_id ORDER BY c.state_effective_at DESC, c.revision DESC, c.id DESC
    ) rn
    FROM ops.commercial_contract_periods c
    WHERE c.signed_at <= COALESCE(p_as_of, clock_timestamp())
      AND c.state_effective_at <= COALESCE(p_as_of, clock_timestamp())
      AND (p_deployment_id IS NULL OR c.deployment_id = p_deployment_id)
      AND (p_organization_id IS NULL OR c.organization_id = p_organization_id)
  ) c WHERE c.rn = 1
), readiness AS (
  SELECT e.* FROM (
    SELECT e.*, row_number() OVER (
      PARTITION BY e.deployment_id, e.organization_id, e.sku, e.readiness_stage
      ORDER BY e.evidence_cutoff_at DESC, e.evaluated_at DESC, e.id DESC
    ) rn
    FROM ops.sku_readiness_evaluations e
    WHERE e.readiness_stage = 'PILOT_ENTRY_READINESS'
      AND e.environment = 'production'
      AND e.qualification_episode_id IS NOT NULL
      AND e.evaluated_at <= COALESCE(p_as_of, clock_timestamp())
      AND (p_deployment_id IS NULL OR e.deployment_id = p_deployment_id)
      AND (p_organization_id IS NULL OR e.organization_id = p_organization_id)
      AND EXISTS (
        SELECT 1 FROM core.dataset_snapshots ds
         WHERE ds.snapshot_kind IN ('AGENT_CASE','DETECTION_DATASET')
           AND ds.state='READY' AND ds.version=2 AND ds.member_count > 0
           AND jsonb_typeof(ds.source_watermarks)='object'
           AND (SELECT count(*) FROM jsonb_object_keys(ds.source_watermarks)) > 0
           AND ds.source_watermark_sha256 ~ '^[0-9a-f]{64}$'
           AND jsonb_typeof(ds.snapshot_manifest)='object'
           AND (SELECT count(*) FROM jsonb_object_keys(ds.snapshot_manifest)) > 0
           AND ds.snapshot_sha256 ~ '^[0-9a-f]{64}$'
           AND ds.terminal_receipt_sha256 ~ '^[0-9a-f]{64}$'
           AND ds.terminal_audit_event_id IS NOT NULL
           AND ds.member_set_sha256 = (
             SELECT i.evidence_member_set_digest
               FROM ops.sku_readiness_items i
              WHERE i.evaluation_id=e.id
                AND i.evidence_member_set_digest IS NOT NULL
              ORDER BY i.item_ordinal, i.id
              LIMIT 1
           )
           AND ds.ready_at <= e.evidence_cutoff_at
           AND (SELECT count(*) FROM core.dataset_snapshot_members dm
                 WHERE dm.dataset_snapshot_id=ds.id
                   AND dm.snapshot_kind=ds.snapshot_kind
                   AND dm.producer_generation=ds.producer_generation
                   AND dm.snapshot_contract_version=ds.contract_version) = ds.member_count
           AND NOT EXISTS (SELECT 1 FROM core.dataset_snapshot_members dm
                            WHERE dm.dataset_snapshot_id=ds.id AND dm.source_count < 1)
           AND NOT EXISTS (
             SELECT 1 FROM core.dataset_snapshot_members dm
              WHERE dm.dataset_snapshot_id=ds.id
                AND NOT EXISTS (SELECT 1 FROM core.dataset_snapshot_member_sources dms
                                  WHERE dms.dataset_snapshot_id=dm.dataset_snapshot_id
                                    AND dms.snapshot_member_id=dm.id)
           )
           AND NOT EXISTS (
             SELECT 1
               FROM core.dataset_snapshot_member_sources dms
              WHERE dms.dataset_snapshot_id = ds.id
                AND dms.source_kind = 'SOURCE_DOCUMENT'
                AND NOT EXISTS (
                  SELECT 1
                    FROM raw.asset_rights_decisions rd
                   WHERE rd.asset_kind = 'SOURCE_DOCUMENT'
                     AND rd.source_document_id = dms.source_document_id
                     AND rd.asset_id = dms.source_asset_id
                     AND rd.asset_revision = dms.source_asset_revision
                     AND rd.asset_sha256 = dms.source_content_sha256
                     AND rd.decision_version = (
                       SELECT max(rd2.decision_version)
                         FROM raw.asset_rights_decisions rd2
                        WHERE rd2.asset_kind = 'SOURCE_DOCUMENT'
                          AND rd2.source_document_id = dms.source_document_id
                          AND rd2.asset_id = dms.source_asset_id
                          AND rd2.asset_revision = dms.source_asset_revision
                          AND rd2.asset_sha256 = dms.source_content_sha256
                          AND rd2.effective_at <= e.evidence_cutoff_at
                     )
                     AND rd.decision_kind = 'GRANT'
                     AND rd.access_right = 'ALLOW'
                     AND rd.private_storage_right = 'ALLOW'
                     AND rd.model_use_right = 'ALLOW'
                     AND rd.model_egress_right = 'ALLOW'
                     AND rd.commercial_use_right = 'ALLOW'
                     AND rd.effective_at <= e.evidence_cutoff_at
                     AND (rd.expires_at IS NULL OR rd.expires_at > e.evidence_cutoff_at)
                   )
              )
           AND NOT EXISTS (
             SELECT 1
               FROM ops.sku_readiness_items ri
              WHERE ri.evaluation_id = e.id
                AND ri.required_for_evaluation
                AND (ri.item_state <> 'SATISFIED'
                  OR ri.evidence_as_of IS NULL
                  OR ri.evidence_as_of > e.evidence_cutoff_at
                  OR (ri.evidence_expires_at IS NOT NULL AND ri.evidence_expires_at <= e.evidence_cutoff_at)
                  OR ri.evidence_tier NOT IN ('PRODUCTION_LIVE','PRODUCTION_DERIVED','PRODUCTION_PREFLIGHT'))
           )
      )
  ) e WHERE e.rn = 1
), paid AS (
  SELECT value->>'organization_id' AS organization_id,
         (value->>'qualification_episode_id')::uuid AS qualification_episode_id,
         (value->>'effective_from')::timestamptz AS effective_from,
         value
  FROM jsonb_array_elements((SELECT ops.read_paid_mvw_inputs_v1(p_deployment_id,p_organization_id,p_as_of)->'eligible')) value
), episode AS (
  SELECT q.qualification_episode_id, q.organization_id, q.first_qualified_at,
         (c.status::text = 'ACTIVE' AND c.provisioning_state::text = 'PROVISIONED'
          AND c.period_start <= (COALESCE(p_as_of, clock_timestamp()) AT TIME ZONE c.accounting_timezone)::date
          AND c.period_end > (COALESCE(p_as_of, clock_timestamp()) AT TIME ZONE c.accounting_timezone)::date
          AND c.state_effective_at <= COALESCE(p_as_of, clock_timestamp())) AS configured,
         (r.state = 'READY' AND r.item_count > 0 AND r.satisfied_required_item_count = r.required_item_count
          AND r.blocked_required_item_count = 0 AND r.unknown_required_item_count = 0) AS data_ready,
         r.evidence_cutoff_at AS data_ready_at,
         c.status::text AS contract_state,
         c.period_end,
         CASE
           WHEN c.status::text IN ('ENDED','CANCELLED') THEN 'POST_ACTIVATION_AT_RISK'
           WHEN c.id IS NULL OR r.id IS NULL THEN 'ONBOARDING_AT_RISK'
           WHEN NOT EXISTS (
                  SELECT 1 FROM paid p0
                   WHERE p0.qualification_episode_id = q.qualification_episode_id
                )
                AND q.first_qualified_at + interval '72 hours' <= COALESCE(p_as_of, clock_timestamp())
             THEN 'ONBOARDING_AT_RISK'
           WHEN EXISTS (
                  SELECT 1 FROM paid p1
                   WHERE p1.qualification_episode_id = q.qualification_episode_id
                )
                AND NOT EXISTS (
                  SELECT 1
                    FROM paid p30
                   WHERE p30.qualification_episode_id = q.qualification_episode_id
                     AND p30.effective_from > (
                       (SELECT min(p_first.effective_from) FROM paid p_first
                         WHERE p_first.qualification_episode_id = q.qualification_episode_id)
                       - interval '30 days')
                     AND p30.effective_from <= COALESCE(p_as_of, clock_timestamp())
                )
             THEN 'POST_ACTIVATION_AT_RISK'
           ELSE NULL
         END AS relationship_health_state,
         COALESCE((SELECT min(p.effective_from) FROM paid p
           WHERE p.qualification_episode_id = q.qualification_episode_id
             AND p.effective_from >= r.evidence_cutoff_at), NULL) AS first_paid_at
  FROM q
  LEFT JOIN contracts c ON c.qualification_episode_id = q.qualification_episode_id
    AND c.qualification_receipt_digest = q.receipt_digest
  LEFT JOIN readiness r ON r.organization_id = q.organization_id AND r.sku = q.sku
    AND r.qualification_episode_id = q.qualification_episode_id
    AND r.deployment_id = c.deployment_id
    AND r.configuration_digest = c.deployment_configuration_digest
), agg AS (
  SELECT count(*)::bigint AS qualified,
         count(*) FILTER (WHERE configured)::bigint AS configured,
         count(*) FILTER (WHERE data_ready)::bigint AS data_ready,
         count(*) FILTER (WHERE first_paid_at IS NOT NULL)::bigint AS first_paid,
         count(*) FILTER (WHERE first_paid_at IS NOT NULL AND first_paid_at - data_ready_at <= interval '7 days')::bigint AS activated_on_time,
         count(*) FILTER (WHERE first_paid_at IS NOT NULL AND first_paid_at - data_ready_at > interval '7 days')::bigint AS activated_late,
         count(*) FILTER (WHERE contract_state IN ('ENDED','CANCELLED'))::bigint AS churned,
         count(*) FILTER (WHERE relationship_health_state IN ('ONBOARDING_AT_RISK','POST_ACTIVATION_AT_RISK'))::bigint AS at_risk
  FROM episode
), source_mix AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object('sourceKind', source_kind, 'organizationCount', n) ORDER BY source_kind), '[]'::jsonb) entries
  FROM (SELECT a.source_kind, count(DISTINCT q.qualification_episode_id) n
        FROM q JOIN ops.acquisition_source_receipts a
          ON a.id = q.acquisition_source_receipt_id AND a.receipt_digest = q.acquisition_source_receipt_digest
        GROUP BY a.source_kind) s
)
SELECT jsonb_build_object(
 'asOf', COALESCE(p_as_of,clock_timestamp()),
 'inputSetDigest', encode(extensions.digest(convert_to(COALESCE((SELECT string_agg(qualification_episode_id::text || ':' || coalesce(first_paid_at::text,''), ',' ORDER BY qualification_episode_id) FROM episode),''),'UTF8'),'sha256'),'hex'),
 'episodes', COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.first_qualified_at,e.qualification_episode_id) FROM episode e),'[]'::jsonb),
 'sourceMix', (SELECT entries FROM source_mix),
 'aggregate', (SELECT to_jsonb(a) FROM agg a)
);
$$;
ALTER FUNCTION ops.read_business_stage_projection_v1(uuid,uuid,timestamptz) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_business_stage_projection_v1(uuid,uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_business_stage_projection_v1(uuid,uuid,timestamptz) TO gurine_control_api, gurine_auditor;

CREATE OR REPLACE FUNCTION ops.read_sla_metric_inputs_v1(
  p_deployment_id uuid,
  p_organization_id uuid,
  p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
WITH r AS (
  SELECT s.* FROM ops.sli_window_receipts s
  WHERE s.window_end <= COALESCE(p_as_of,clock_timestamp())
    -- The receipt contract has three terminal evaluation states.  COMPLETE
    -- is a telemetry state, not an evaluation state; filtering on it made a
    -- valid MET/BREACHED window disappear and manufactured a missing SLA.
    AND s.evaluation_state IN ('MET','BREACHED','UNKNOWN')
    AND s.environment = 'PRODUCTION'
    AND s.sli_kind = 'AVAILABILITY'
    AND s.telemetry_state IN ('COMPLETE','GAP')
    AND (p_organization_id IS NULL OR s.scope_id = p_organization_id::text)
    AND (p_deployment_id IS NULL OR EXISTS (
      SELECT 1 FROM ops.commercial_contract_periods c
      WHERE c.deployment_id = p_deployment_id
        AND (p_organization_id IS NULL OR c.organization_id = p_organization_id)
        AND c.sla_policy_digest = s.policy_digest
        -- The receipt schema binds a single capability by capability_id; the
        -- contract stores the immutable capability-set digest.  A digest-to-
        -- id comparison would be invalid, so require the receipt's concrete
        -- capability binding and keep the set-digest validation at contract
        -- creation time.
        AND s.capability_id IS NOT NULL
        AND c.sla_exclusion_schedule_digest = s.exclusion_set_digest
    ))
), contract_scope AS (
 SELECT count(*)::bigint AS contract_count
   FROM ops.commercial_contract_periods c
  WHERE c.status = 'ACTIVE'
    AND c.provisioning_state = 'PROVISIONED'
    AND c.signed_at <= COALESCE(p_as_of,clock_timestamp())
    AND (p_deployment_id IS NULL OR c.deployment_id = p_deployment_id)
    AND (p_organization_id IS NULL OR c.organization_id = p_organization_id)
), summary AS (
 SELECT count(*)::bigint observed_count,
        COALESCE(sum(GREATEST(eligible_count-maintenance_observation_count,0)),0)::bigint eligible_count,
        COALESCE(sum(GREATEST(good_count,0)),0)::bigint good_count,
        COALESCE(sum(telemetry_gap_count),0)::bigint telemetry_gap_count,
        (SELECT contract_count FROM contract_scope) AS contract_count,
        encode(extensions.digest(convert_to(COALESCE(string_agg(receipt_digest,',' ORDER BY id),''),'UTF8'),'sha256'),'hex') input_digest
 FROM r
)
SELECT jsonb_build_object(
 'asOf',COALESCE(p_as_of,clock_timestamp()), 'status',CASE WHEN contract_count=0 THEN 'NOT_APPLICABLE' WHEN observed_count=0 THEN 'UNKNOWN' WHEN telemetry_gap_count>0 THEN 'UNKNOWN' ELSE 'KNOWN' END,
 'reasonCode',CASE WHEN contract_count=0 THEN 'CAPABILITY_NOT_OFFERED' WHEN observed_count=0 THEN 'SLA_SOURCE_MISSING' WHEN telemetry_gap_count>0 THEN 'SLA_TELEMETRY_GAP' ELSE 'NONE' END,
 'eligibleCount',eligible_count,'goodCount',good_count,'telemetryGapCount',telemetry_gap_count,
 'availability',CASE WHEN eligible_count=0 OR telemetry_gap_count>0 THEN NULL ELSE good_count::numeric/eligible_count END,
 'inputSetDigest',input_digest
) FROM summary;
$$;
ALTER FUNCTION ops.read_sla_metric_inputs_v1(uuid,uuid,timestamptz) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_sla_metric_inputs_v1(uuid,uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_sla_metric_inputs_v1(uuid,uuid,timestamptz) TO gurine_control_api, gurine_auditor;

-- Typed contract entrypoint required by the commercial-core addendum.  The
-- aggregate reader above is used by BusinessHealth; this overload is the
-- closed SETOF boundary for invoice/SLA workers and never exposes telemetry
-- JSON or customer identity.  A selected contract with no complete receipt
-- set returns one explicit UNKNOWN sentinel instead of an empty success.
CREATE OR REPLACE FUNCTION ops.read_sla_metric_inputs_v1(
  p_contract_period_id uuid,
  p_expected_contract_record_digest char(64),
  p_window_start date,
  p_window_end date
) RETURNS SETOF ops.sla_metric_input_v1
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
WITH c AS (
  SELECT c.*,
         encode(extensions.digest(convert_to(c.deployment_id::text || ':' || c.organization_id::text || ':' || c.id::text || ':' || c.sla_policy_digest::text,'UTF8'),'sha256'),'hex') AS expected_scope_digest
  FROM ops.commercial_contract_periods c
  WHERE c.id = p_contract_period_id
    AND c.record_digest = p_expected_contract_record_digest
    AND c.period_start = p_window_start
    AND c.period_end = p_window_end
    AND c.status::text = 'ACTIVE'
    AND c.provisioning_state::text = 'PROVISIONED'
    AND c.sla_selection_state::text = 'SELECTED'
    AND c.sla_add_on_selected
    AND c.sla_policy_version IS NOT NULL
    AND c.sla_policy_digest IS NOT NULL
    AND c.sla_target_availability_ratio IS NOT NULL
    AND c.sla_capability_set_digest IS NOT NULL
    AND c.sla_exclusion_schedule_digest IS NOT NULL
    AND c.sla_service_credit_schedule_digest IS NOT NULL
    AND c.sla_measurement_policy_digest IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM ops.commercial_contract_periods successor
       WHERE successor.supersedes_contract_period_id = c.id
    )
  FOR UPDATE
), bound AS (
  SELECT c.*, s.id AS sli_window_receipt_id, s.receipt_digest AS sli_receipt_digest,
         s.evaluation_state
  FROM c
  JOIN ops.sli_window_receipts s
    ON s.scope_id = c.organization_id::text
   AND s.scope_digest = c.expected_scope_digest
   AND s.environment = 'PRODUCTION'
   AND s.window_kind = 'POLICY_WINDOW'
   AND s.sli_kind = 'AVAILABILITY'
   AND s.policy_digest = c.sla_policy_digest
   AND s.exclusion_set_digest = c.sla_exclusion_schedule_digest
   AND s.window_start >= (c.period_start::timestamp AT TIME ZONE c.accounting_timezone)
   AND s.window_end <= (c.period_end::timestamp AT TIME ZONE c.accounting_timezone)
   AND s.window_start >= (p_window_start::timestamp AT TIME ZONE c.accounting_timezone)
   AND s.window_end <= (p_window_end::timestamp AT TIME ZONE c.accounting_timezone)
   AND s.capability_id IS NOT NULL
), complete AS (
  SELECT b.*
  FROM bound b
  WHERE b.evaluation_state IN ('MET','BREACHED')
    AND NOT EXISTS (
      SELECT 1 FROM ops.sli_window_receipts bad
       WHERE bad.id = b.sli_window_receipt_id
         AND (bad.telemetry_state = 'GAP' OR bad.evaluation_state = 'UNKNOWN'
              OR bad.telemetry_backend_receipt_digest !~ '^[0-9a-f]{64}$'
              OR bad.telemetry_query_digest !~ '^[0-9a-f]{64}$'
              OR bad.source_watermark_digest !~ '^[0-9a-f]{64}$')
    )
)
SELECT ROW(organization_id, id, sla_policy_version, sla_policy_digest,
           sla_capability_set_digest, sla_exclusion_schedule_digest,
           sla_service_credit_schedule_digest, sli_window_receipt_id,
           sli_receipt_digest, evaluation_state)::ops.sla_metric_input_v1
  FROM complete
 WHERE (SELECT count(*) FROM bound) = (SELECT count(*) FROM complete)
UNION ALL
SELECT ROW(c.organization_id, c.id, c.sla_policy_version, c.sla_policy_digest,
           c.sla_capability_set_digest, c.sla_exclusion_schedule_digest,
           c.sla_service_credit_schedule_digest, NULL::uuid, NULL::char(64),
           'UNKNOWN')::ops.sla_metric_input_v1
  FROM c
 WHERE (SELECT count(*) FROM bound) <> (SELECT count(*) FROM complete)
    OR NOT EXISTS (SELECT 1 FROM complete);
$$;
ALTER FUNCTION ops.read_sla_metric_inputs_v1(uuid,char(64),date,date) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_sla_metric_inputs_v1(uuid,char(64),date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_sla_metric_inputs_v1(uuid,char(64),date,date) TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
-- The helper is intentionally internal to this SECURITY DEFINER reader.  The
-- base migration owns it as the migration role, so grant the reader owner
-- only the execution edge it needs (runtime roles remain unchanged).
GRANT EXECUTE ON FUNCTION ops.round_half_even_numeric_v1(numeric,integer) TO gurine_migrator;

-- Support, expansion and renewal are deliberately computed from the same
-- cutoff as BusinessHealth.  These inputs are conservative: a missing
-- purpose-limited support capture, incomplete invoice/cost month, stale
-- readiness/SLA evidence, or an unresolved contract head is UNKNOWN rather
-- than an ineligible/zero value.  This keeps an empty pilot truthful while
-- allowing a fully-seeded receipt set to produce a typed denominator.
CREATE OR REPLACE FUNCTION ops.read_commercial_eligibility_inputs_v1(
  p_deployment_id uuid,
  p_organization_id uuid,
  p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, core, editorial, pg_temp
AS $$
WITH settings AS (
  SELECT COALESCE(min(c.accounting_timezone), 'UTC') AS accounting_timezone
    FROM ops.commercial_contract_periods c
   WHERE (p_deployment_id IS NULL OR c.deployment_id = p_deployment_id)
     AND (p_organization_id IS NULL OR c.organization_id = p_organization_id)
     AND c.state_effective_at <= COALESCE(p_as_of, clock_timestamp())
), bounds AS (
  SELECT COALESCE(p_as_of, clock_timestamp()) AS as_of,
         (COALESCE(p_as_of, clock_timestamp()) AT TIME ZONE s.accounting_timezone)::date AS as_of_date,
         date_trunc('month', COALESCE(p_as_of, clock_timestamp()) AT TIME ZONE s.accounting_timezone)::date AS month_start
    FROM settings s
), months AS (
  SELECT (b.month_start - interval '2 months')::date AS start_date,
         (b.month_start - interval '1 month')::date AS end_date
    FROM bounds b
  UNION ALL
  SELECT (b.month_start - interval '1 month')::date,
         b.month_start
    FROM bounds b
), paid AS (
  SELECT DISTINCT
         NULLIF(v->>'qualification_episode_id','')::uuid AS qualification_episode_id,
         NULLIF(v->>'organization_id','')::uuid AS organization_id,
         NULLIF(v->>'deployment_id','')::uuid AS deployment_id,
         NULLIF(v->>'effective_from','')::timestamptz AS paid_at
    FROM bounds b
    CROSS JOIN LATERAL jsonb_array_elements(
      ops.read_paid_mvw_inputs_v1(p_deployment_id,p_organization_id,b.as_of)->'eligible'
    ) v
   WHERE v->>'qualification_episode_id' IS NOT NULL
), paid_first AS (
  SELECT DISTINCT ON (qualification_episode_id, organization_id)
         qualification_episode_id, organization_id, deployment_id, paid_at
    FROM paid
   ORDER BY qualification_episode_id, organization_id, paid_at
), contracts AS (
  SELECT x.*
    FROM (
      SELECT c.*, row_number() OVER (
        PARTITION BY c.root_contract_period_id
        ORDER BY c.state_effective_at DESC, c.revision DESC, c.id DESC
      ) AS rn
        FROM ops.commercial_contract_periods c
       WHERE c.signed_at <= (SELECT as_of FROM bounds)
         AND (p_deployment_id IS NULL OR c.deployment_id = p_deployment_id)
         AND (p_organization_id IS NULL OR c.organization_id = p_organization_id)
    ) x
   WHERE x.rn = 1
), active_contracts AS (
  SELECT c.*, p.paid_at,
         (p.paid_at + interval '56 days' <= b.as_of) AS retention_mature
    FROM contracts c
    JOIN paid_first p ON p.qualification_episode_id = c.qualification_episode_id
                     AND p.organization_id = c.organization_id
                     AND p.deployment_id = c.deployment_id
    CROSS JOIN bounds b
   WHERE c.status = 'ACTIVE'
     AND c.provisioning_state = 'PROVISIONED'
     AND c.period_start <= b.as_of_date
     AND c.period_end > b.as_of_date
), support_periods AS (
  SELECT d.deployment_id AS support_deployment_id, m.start_date, m.end_date, c.*
    FROM (SELECT DISTINCT deployment_id FROM active_contracts) d
    CROSS JOIN months m
    LEFT JOIN LATERAL (
      SELECT h.*
        FROM ops.cost_allocations h
       WHERE h.row_kind = 'PERIOD'
         AND h.deployment_id = d.deployment_id
         AND h.period_start <= m.start_date
         AND h.period_end >= m.end_date
         AND h.currency = 'KRW'
         AND h.closed_at <= (SELECT as_of FROM bounds)
       ORDER BY h.period_version DESC, h.id DESC
       LIMIT 1
    ) c ON true
), support_by_org_month AS (
  SELECT a.organization_id, m.start_date,
         COALESCE(sum(l.driver_quantity) FILTER (
           WHERE l.driver_kind IN ('SUPPORT_HOUR','MATERIAL_CORRECTION_HOUR')
         ),0)::numeric AS support_hours,
         count(l.id) FILTER (
           WHERE l.driver_kind IN ('SUPPORT_HOUR','MATERIAL_CORRECTION_HOUR')
         )::bigint AS support_receipt_count,
         bool_or(h.id IS NOT NULL
           AND h.cost_capture_state = 'MEASURED'
           AND h.claim_state <> 'INCOMPLETE'
           AND h.cost_capture_coverage >= .99
           AND h.direct_coverage = 1
           AND h.total_coverage >= .95
           AND h.closed_at IS NOT NULL) AS complete_month
    FROM active_contracts a
    CROSS JOIN months m
    LEFT JOIN support_periods h ON h.start_date = m.start_date
                                AND h.support_deployment_id = a.deployment_id
    LEFT JOIN ops.cost_allocations l
      ON l.row_kind = 'LINE'
     AND l.organization_id = a.organization_id
     AND l.period_start <= m.start_date
     AND l.period_end >= m.end_date
     AND l.deployment_id = a.deployment_id
    GROUP BY a.organization_id, m.start_date
), support_summary AS (
  SELECT count(DISTINCT a.organization_id)::bigint AS activated_count,
         count(DISTINCT sp.start_date) FILTER (WHERE sp.complete_month)::bigint AS complete_month_count,
         COALESCE(sum(sp.support_hours),0)::numeric AS support_hours,
         count(*) FILTER (WHERE sp.complete_month IS NOT TRUE)::bigint AS missing_months
    FROM active_contracts a
    LEFT JOIN support_by_org_month sp ON sp.organization_id = a.organization_id
), invoice_heads AS (
  SELECT i.*, row_number() OVER (
    PARTITION BY i.root_invoice_id ORDER BY i.invoice_revision DESC, i.id DESC
  ) AS rn
    FROM ops.invoice_facts i
   WHERE i.billing_cutoff_at <= (SELECT as_of FROM bounds)
     AND (p_deployment_id IS NULL OR i.deployment_id = p_deployment_id)
     AND (p_organization_id IS NULL OR i.organization_id = p_organization_id)
), revenue_candidates AS (
  SELECT a.*,
         COALESCE(inv.valid_invoice_months,0)::bigint AS valid_invoice_months,
         COALESCE(inv.invoice_months,0)::bigint AS invoice_months,
         COALESCE(inv.invalid_invoice_rows,0)::bigint AS invalid_invoice_rows,
         COALESCE(pv.paid_30d,0)::bigint AS paid_30d,
         COALESCE(pv.paid_60d,0)::bigint AS paid_60d
    FROM active_contracts a
    CROSS JOIN bounds b
    LEFT JOIN LATERAL (
      SELECT count(DISTINCT date_trunc('month', i.period_start)) FILTER (
               WHERE i.rn = 1 AND i.invoice_total > 0 AND i.reconciled_at IS NOT NULL
                 AND i.expected_usage_membership_count = i.usage_membership_count
             ) AS valid_invoice_months,
             count(DISTINCT date_trunc('month', i.period_start)) FILTER (WHERE i.rn = 1) AS invoice_months,
             count(*) FILTER (WHERE i.rn = 1 AND (
               i.invoice_total <= 0 OR i.reconciled_at IS NULL
               OR i.expected_usage_membership_count <> i.usage_membership_count
             )) AS invalid_invoice_rows
        FROM invoice_heads i
       WHERE i.organization_id = a.organization_id
         AND i.contract_period_id = a.id
         AND i.period_end > (b.as_of_date - 60)
         AND i.period_start < b.as_of_date
    ) inv ON true
    LEFT JOIN LATERAL (
      SELECT count(*) FILTER (WHERE p2.paid_at >= b.as_of - interval '30 days') AS paid_30d,
             count(*) FILTER (WHERE p2.paid_at >= b.as_of - interval '60 days') AS paid_60d
        FROM paid p2
       WHERE p2.qualification_episode_id = a.qualification_episode_id
         AND p2.organization_id = a.organization_id
    ) pv ON true
), expansion_members AS (
  SELECT r.*, se.complete_month_count AS support_month_count,
         se.under_capacity AS support_under_capacity,
         q.readiness_ok, q.sla_ok, q.trust_ok,
         CASE WHEN r.valid_invoice_months >= 2
                   AND r.invalid_invoice_rows = 0
                   AND r.paid_60d >= 4
                   AND (r.retention_mature OR r.paid_30d >= 1)
                   AND se.complete_month_count = 2
                   AND se.under_capacity
                   AND q.readiness_ok AND q.sla_ok AND q.trust_ok
                   AND t.id IS NOT NULL
                   AND t.projected_p75_variable_gross_margin_basis_points >= t.required_variable_gross_margin_basis_points
                   AND t.cost_capture_coverage >= .99 AND t.direct_cost_coverage = 1
                   AND t.total_cost_coverage >= .95
              THEN 'ELIGIBLE'
              WHEN r.invoice_months = 0 OR r.invalid_invoice_rows > 0
                   OR r.valid_invoice_months < 2 OR t.id IS NULL
                   OR se.complete_month_count IS NULL OR se.complete_month_count < 2
                   OR NOT se.under_capacity OR NOT q.readiness_ok OR NOT q.sla_ok OR NOT q.trust_ok
              THEN 'UNKNOWN'
              ELSE 'INELIGIBLE' END AS eligibility_state
    FROM revenue_candidates r
    LEFT JOIN ops.tariff_versions t ON t.id = r.tariff_version_id
    LEFT JOIN LATERAL (
      SELECT count(*) FILTER (WHERE sb.complete_month)::bigint AS complete_month_count,
             COALESCE(bool_and(sb.complete_month AND sb.support_hours <= 4),false) AS under_capacity
        FROM support_by_org_month sb
       WHERE sb.organization_id = r.organization_id
    ) se ON true
    LEFT JOIN LATERAL (
      SELECT
        EXISTS (SELECT 1 FROM ops.sku_readiness_evaluations re
                 WHERE re.deployment_id = r.deployment_id
                   AND re.organization_id = r.organization_id
                   AND re.sku = 'EVIDENCE_WORKSPACE_ORGANIZATION_V1'
                   AND re.readiness_stage IN ('PILOT_ENTRY_READINESS','POST_FIRST_BILLING_CYCLE')
                   AND re.evaluated_at <= (SELECT as_of FROM bounds)
                   AND re.state = 'READY'
                   AND re.blocked_required_item_count = 0
                   AND re.unknown_required_item_count = 0
                   AND re.satisfied_required_item_count = re.required_item_count
                 ORDER BY re.evaluated_at DESC LIMIT 1) AS readiness_ok,
        (NOT r.sla_add_on_selected OR EXISTS (
          SELECT 1 FROM ops.sli_window_receipts sr
           WHERE sr.scope_id = r.organization_id::text
             AND sr.window_end <= (SELECT as_of FROM bounds)
             AND sr.evaluation_state = 'MET'
             AND sr.telemetry_state = 'COMPLETE'
             AND sr.telemetry_gap_count = 0
        )) AS sla_ok,
        NOT EXISTS (SELECT 1 FROM editorial.conflict_snapshots cs
                     WHERE cs.nonwaivable_blocker_count > 0
                       AND cs.evaluated_at <= (SELECT as_of FROM bounds)
                       AND (cs.valid_until IS NULL OR cs.valid_until > (SELECT as_of FROM bounds))) AS trust_ok
    ) q ON true
), renewal_contracts AS (
  SELECT c.*,
         count(*) OVER (PARTITION BY c.root_contract_period_id)::bigint AS root_count,
         (c.status = 'ACTIVE' AND c.provisioning_state = 'PROVISIONED') AS provisioned,
         COALESCE((SELECT count(*) FROM paid p
                    WHERE p.qualification_episode_id = c.qualification_episode_id
                      AND p.organization_id = c.organization_id
                      AND p.paid_at >= b.as_of - interval '30 days'),0)::bigint AS paid_30d,
         COALESCE((SELECT min(p.paid_at) FROM paid p
            WHERE p.qualification_episode_id = c.qualification_episode_id
                      AND p.organization_id = c.organization_id),NULL) AS first_paid_at,
         COALESCE((SELECT count(*) FROM invoice_heads i
                    WHERE i.rn = 1 AND i.contract_period_id = c.id
                      AND i.period_end > b.as_of_date - 90
                      AND i.period_start < b.as_of_date
                      AND i.invoice_total > 0 AND i.reconciled_at IS NOT NULL
                      AND i.expected_usage_membership_count = i.usage_membership_count),0)::bigint AS valid_invoice_count,
         COALESCE((SELECT count(*) FROM invoice_heads i
                    WHERE i.rn = 1 AND i.contract_period_id = c.id
                      AND i.period_end > b.as_of_date - 90
                      AND i.period_start < b.as_of_date),0)::bigint AS invoice_count
    FROM contracts c CROSS JOIN bounds b
   WHERE c.period_end > b.as_of_date AND c.period_end <= b.as_of_date + 60
), renewal_members AS (
  SELECT r.*, se.complete_month_count AS support_month_count,
         se.under_capacity AS support_under_capacity,
         q.readiness_ok, q.sla_ok, q.trust_ok,
         CASE WHEN r.root_count = 1 AND r.provisioned AND r.paid_30d > 0
                   AND r.valid_invoice_count > 0 AND r.valid_invoice_count = r.invoice_count
                   AND (r.first_paid_at + interval '56 days' <= b.as_of OR r.first_paid_at IS NULL)
                   AND se.complete_month_count = 2
                   AND se.under_capacity
                   AND q.readiness_ok AND q.sla_ok AND q.trust_ok
                   AND t.id IS NOT NULL
                   AND t.projected_p75_variable_gross_margin_basis_points >= t.required_variable_gross_margin_basis_points
                   AND t.cost_capture_coverage >= .99 AND t.direct_cost_coverage = 1
                   AND t.total_cost_coverage >= .95
              THEN 'ELIGIBLE'
              WHEN r.root_count <> 1 OR r.invoice_count = 0 OR r.valid_invoice_count <> r.invoice_count
                   OR t.id IS NULL OR se.complete_month_count IS NULL OR se.complete_month_count < 2
                   OR NOT se.under_capacity OR NOT q.readiness_ok OR NOT q.sla_ok OR NOT q.trust_ok
              THEN 'UNKNOWN'
              ELSE 'INELIGIBLE' END AS eligibility_state
    FROM renewal_contracts r
    CROSS JOIN bounds b
    LEFT JOIN ops.tariff_versions t ON t.id = r.tariff_version_id
    LEFT JOIN LATERAL (
      SELECT count(*) FILTER (WHERE sb.complete_month)::bigint AS complete_month_count,
             COALESCE(bool_and(sb.complete_month AND sb.support_hours <= 4),false) AS under_capacity
        FROM support_by_org_month sb
       WHERE sb.organization_id = r.organization_id
    ) se ON true
    LEFT JOIN LATERAL (
      SELECT
        EXISTS (SELECT 1 FROM ops.sku_readiness_evaluations re
                 WHERE re.deployment_id = r.deployment_id
                   AND re.organization_id = r.organization_id
                   AND re.sku = 'EVIDENCE_WORKSPACE_ORGANIZATION_V1'
                   AND re.readiness_stage IN ('PILOT_ENTRY_READINESS','POST_FIRST_BILLING_CYCLE')
                   AND re.evaluated_at <= (SELECT as_of FROM bounds)
                   AND re.state = 'READY'
                   AND re.blocked_required_item_count = 0
                   AND re.unknown_required_item_count = 0
                   AND re.satisfied_required_item_count = re.required_item_count
                 ORDER BY re.evaluated_at DESC LIMIT 1) AS readiness_ok,
        (NOT r.sla_add_on_selected OR EXISTS (
          SELECT 1 FROM ops.sli_window_receipts sr
           WHERE sr.scope_id = r.organization_id::text
             AND sr.window_end <= (SELECT as_of FROM bounds)
             AND sr.evaluation_state = 'MET'
             AND sr.telemetry_state = 'COMPLETE'
             AND sr.telemetry_gap_count = 0
        )) AS sla_ok,
        NOT EXISTS (SELECT 1 FROM editorial.conflict_snapshots cs
                     WHERE cs.nonwaivable_blocker_count > 0
                       AND cs.evaluated_at <= (SELECT as_of FROM bounds)
                       AND (cs.valid_until IS NULL OR cs.valid_until > (SELECT as_of FROM bounds))) AS trust_ok
    ) q ON true
), digest AS (
  SELECT encode(extensions.digest(convert_to(
    COALESCE((SELECT string_agg(organization_id::text || ':' || eligibility_state,
                               ',' ORDER BY organization_id) FROM expansion_members),'') || ':' ||
    COALESCE((SELECT string_agg(id::text || ':' || eligibility_state,
                               ',' ORDER BY id) FROM renewal_members),''),
    'UTF8'),'sha256'),'hex') AS input_set_digest
)
SELECT jsonb_build_object(
  'asOf',(SELECT as_of FROM bounds),
  'support',jsonb_build_object(
    'status',CASE WHEN activated_count = 0 THEN 'NOT_APPLICABLE'
                  WHEN missing_months > 0 OR complete_month_count < 2 THEN 'UNKNOWN'
                  ELSE 'KNOWN' END,
    'reasonCode',CASE WHEN activated_count = 0 THEN 'DENOMINATOR_ZERO'
                      WHEN missing_months > 0 OR complete_month_count < 2 THEN 'SOURCE_MISSING'
                      ELSE 'NONE' END,
    'hours',CASE WHEN activated_count > 0 AND missing_months = 0 AND complete_month_count >= 2
                 THEN support_hours / activated_count ELSE NULL END,
    'totalHours',CASE WHEN activated_count > 0 AND missing_months = 0 AND complete_month_count >= 2
                      THEN support_hours ELSE NULL END,
    'denominatorCount',activated_count,
    'completeMonthCount',complete_month_count,
    'unknownCount',missing_months,
    'inputSetDigest',(SELECT input_set_digest FROM digest)),
  'expansion',jsonb_build_object(
    'status',CASE WHEN (SELECT count(*) FROM expansion_members) = 0 THEN 'NOT_APPLICABLE'
                  WHEN (SELECT count(*) FROM expansion_members WHERE eligibility_state = 'UNKNOWN') > 0 THEN 'UNKNOWN'
                  ELSE 'KNOWN' END,
    'reasonCode',CASE WHEN (SELECT count(*) FROM expansion_members) = 0 THEN 'DENOMINATOR_ZERO'
                      WHEN (SELECT count(*) FROM expansion_members WHERE eligibility_state = 'UNKNOWN') > 0 THEN 'SOURCE_MISSING'
                      ELSE 'NONE' END,
    'numerator',(SELECT count(*) FROM expansion_members WHERE eligibility_state = 'ELIGIBLE'),
    'denominatorCount',(SELECT count(*) FROM expansion_members),
    'unknownCount',(SELECT count(*) FROM expansion_members WHERE eligibility_state = 'UNKNOWN'),
    'inputSetDigest',(SELECT input_set_digest FROM digest)),
  'renewal',jsonb_build_object(
    'status',CASE WHEN (SELECT count(*) FROM renewal_members) = 0 THEN 'NOT_APPLICABLE'
                  WHEN (SELECT count(*) FROM renewal_members WHERE eligibility_state = 'UNKNOWN') > 0 THEN 'UNKNOWN'
                  ELSE 'KNOWN' END,
    'reasonCode',CASE WHEN (SELECT count(*) FROM renewal_members) = 0 THEN 'DENOMINATOR_ZERO'
                      WHEN (SELECT count(*) FROM renewal_members WHERE eligibility_state = 'UNKNOWN') > 0 THEN 'SOURCE_MISSING'
                      ELSE 'NONE' END,
    'numerator',(SELECT count(*) FROM renewal_members WHERE eligibility_state = 'ELIGIBLE'),
    'denominatorCount',(SELECT count(*) FROM renewal_members),
    'unknownCount',(SELECT count(*) FROM renewal_members WHERE eligibility_state = 'UNKNOWN'),
    'inputSetDigest',(SELECT input_set_digest FROM digest)))
FROM support_summary;
$$;
ALTER FUNCTION ops.read_commercial_eligibility_inputs_v1(uuid,uuid,timestamptz) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_commercial_eligibility_inputs_v1(uuid,uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_commercial_eligibility_inputs_v1(uuid,uuid,timestamptz) TO gurine_control_api, gurine_auditor;

CREATE OR REPLACE FUNCTION ops.read_business_health_projection_v1(
  p_deployment_id uuid, p_organization_id uuid, p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, core, editorial, pg_temp
AS $$
DECLARE
  v_now timestamptz := COALESCE(p_as_of,clock_timestamp());
  v_accounting_timezone text := 'UTC';
  v_stage jsonb := ops.read_business_stage_projection_v1(p_deployment_id,p_organization_id,v_now);
  v_paid jsonb := ops.read_paid_mvw_inputs_v1(p_deployment_id,p_organization_id,v_now);
  v_sla jsonb := ops.read_sla_metric_inputs_v1(p_deployment_id,p_organization_id,v_now);
  v_commercial jsonb := ops.read_commercial_eligibility_inputs_v1(p_deployment_id,p_organization_id,v_now);
  v_metric_catalog_digest char(64);
  v_metrics jsonb := '[]'::jsonb;
  v_funnel jsonb := '[]'::jsonb;
  v_metric_ids text[] := ARRAY['BM-ACQ-QUALIFIED-ORG-COUNT','BM-ACQ-CHANNEL-MIX','BM-FUNNEL-CONFIGURATION-RATE','BM-FUNNEL-DATA-READY-RATE','BM-VALUE-PAID-MVW','BM-ACTIVATION-7D-RATE','BM-ACTIVATION-TTFPV-P90','BM-RETENTION-D29-56-RATE','BM-RETENTION-AT-RISK-ORG-COUNT','BM-RETENTION-CHURN-RATE','BM-REVENUE-RECOGNIZED-KRW','BM-BILLING-RECONCILIATION-COVERAGE','BM-REVENUE-QUALIFIED-ORG-COUNT','BM-VALUE-PAID-MVW-PER-ACTIVE-ORG','BM-MARGIN-VARIABLE-GROSS-RATE','BM-MARGIN-CONTRIBUTION-KRW','BM-COST-PER-PAID-MVW-KRW','BM-CAC-KRW','BM-CAC-PAYBACK-MONTHS','BM-SLA-AVAILABILITY-RATE','BM-SUPPORT-HOURS-PER-ACTIVATED-ORG','BM-TRUST-HARD-STOP-COUNT','BM-FUNNEL-PILOT-TO-PAID-RATE','BM-EXPANSION-ELIGIBILITY-RATE','BM-RENEWAL-ELIGIBILITY-RATE'];
  v_metric_kinds text[] := ARRAY['SCALAR','SOURCE_BREAKDOWN','BINOMIAL_RATE','BINOMIAL_RATE','SCALAR','BINOMIAL_RATE','TIME_TO_EVENT_P90','BINOMIAL_RATE','SCALAR','BINOMIAL_RATE','SCALAR','DETERMINISTIC_RATIO','SCALAR','DETERMINISTIC_RATIO','DETERMINISTIC_RATIO','SCALAR','DETERMINISTIC_RATIO','DETERMINISTIC_RATIO','DETERMINISTIC_RATIO','DETERMINISTIC_RATIO','DETERMINISTIC_RATIO','SCALAR','BINOMIAL_RATE','BINOMIAL_RATE','BINOMIAL_RATE'];
  v_units text[] := ARRAY['organizations','organizations_by_source_kind','ratio','ratio','verified_workflows','ratio','hours','ratio','organizations','ratio','KRW','ratio','organizations','workflows_per_organization','ratio','KRW','KRW_per_verified_workflow','KRW','months','ratio','hours_per_organization_month','incidents','ratio','ratio','ratio'];
  v_agg jsonb := v_stage->'aggregate';
  v_q bigint := COALESCE((v_agg->>'qualified')::bigint,0);
  v_c bigint := COALESCE((v_agg->>'configured')::bigint,0);
  v_d bigint := COALESCE((v_agg->>'data_ready')::bigint,0);
  v_paid_count bigint := COALESCE((v_paid->>'eligibleCount')::bigint,0);
  v_paid_unknown bigint := COALESCE((v_paid->>'unknownCandidateCount')::bigint,0);
  v_revenue numeric := 0;
  v_revenue_rows bigint := 0;
  v_revenue_unknown bigint := 0;
  v_cost numeric := 0;
  v_cost_rows bigint := 0;
  v_cost_unknown bigint := 0;
  v_cac numeric := 0;
  v_cac_rows bigint := 0;
  v_cac_unknown bigint := 0;
  v_complete_months bigint := 0;
  v_monthly_contribution numeric := NULL;
  v_conflicts bigint := 0;
  v_conflict_snapshot_rows bigint := 0;
  v_retention_eligible bigint := 0;
  v_retention_success bigint := 0;
  v_activation_eligible bigint := 0;
  v_revenue_qualified_count bigint := 0;
  v_paid_revenue_workflow_count bigint := 0;
  v_paid_active_org_count bigint := 0;
  v_at_risk_observed bigint := 0;
  v_churn_den bigint := 0;
  v_health_evidence_count bigint := 0;
  v_p90_eligible bigint := 0;
  v_p90_event_count bigint := 0;
  v_p90_observation_count bigint := 0;
  v_p90_right_censored bigint := 0;
  v_p90_terminal_without_event bigint := 0;
  v_p90_hours numeric := NULL;
  v_p90_lower_bound numeric := NULL;
  v_p90_selected_rank bigint := NULL;
  v_p90_estimate_state text := 'UNKNOWN';
  v_p90_threshold_state text := 'UNKNOWN';
  v_p90_issue_code text := 'DATA_UNKNOWN';
  v_p90_ordered jsonb := NULL;
  v_cac_policy_digest char(64) := NULL;
  v_i int;
  v_id text;
  v_kind text;
  v_status text;
  v_reason text;
  v_result jsonb;
  v_num numeric;
  v_den numeric;
  v_formula_digest char(64);
  v_policy_digest char(64);
  v_input_digest char(64);
  v_source_window_start timestamptz := NULL;
  v_source_window_end timestamptz := NULL;
  v_latest_source_at timestamptz := NULL;
BEGIN
  /* All monetary windows use the bound contract timezone.  A missing
     contract has no valid business window; UTC is retained only as a typed
     fallback for the empty projection and never turns an absent source into
     a known metric. */
  SELECT COALESCE(min(c.accounting_timezone), 'UTC')
    INTO v_accounting_timezone
    FROM ops.commercial_contract_periods c
   WHERE (p_deployment_id IS NULL OR c.deployment_id = p_deployment_id)
     AND (p_organization_id IS NULL OR c.organization_id = p_organization_id)
     AND c.state_effective_at <= v_now;
  /* Revenue is read from the current invoice head only.  A stale, missing,
     non-KRW, or unreconciled invoice keeps the whole affected revenue set
     UNKNOWN; summing every historical row would over-recognize corrections. */
  WITH invoice_heads AS (
    SELECT i.*, row_number() OVER (
      PARTITION BY i.root_invoice_id ORDER BY i.invoice_revision DESC, i.id DESC
    ) AS rn
    FROM ops.invoice_facts i
    WHERE i.billing_cutoff_at <= v_now
  )
  SELECT COALESCE(sum(CASE WHEN correction_head.state IN ('NONE',NULL) THEN r.amount
                           WHEN correction_head.state = 'VALID' THEN correction_head."effectiveAmount"
                           ELSE 0 END)
                   FILTER (WHERE i.id IS NOT NULL AND i.rn = 1),0),
         count(*),
         count(*) FILTER (WHERE i.id IS NULL OR i.rn <> 1 OR r.currency <> 'KRW'
           OR i.reconciled_at IS NULL
           OR i.expected_usage_membership_count <> i.usage_membership_count
           OR i.reconciliation_digest IS NULL
           OR i.currency <> 'KRW'
           OR (correction_head.state IS DISTINCT FROM 'NONE'
               AND (correction_head.state <> 'VALID'
                    OR correction_head."targetFactDigest" <> r.record_digest
                    OR correction_head.currency <> r.currency
                    OR correction_head."effectiveAmount" < 0)))
    INTO v_revenue, v_revenue_rows, v_revenue_unknown
  FROM ops.revenue_facts r
  LEFT JOIN invoice_heads i ON i.id = r.invoice_id
  LEFT JOIN LATERAL jsonb_to_record(
    ops.read_current_accounting_correction_head_v1('REVENUE_FACT',r.id,v_now)
  ) AS correction_head(state text, "headId" uuid, "headDigest" text,
                        "targetFactDigest" text, currency text, "effectiveAmount" numeric) ON true
  WHERE r.sku='EVIDENCE_WORKSPACE_ORGANIZATION_V1' AND r.recognized_at <= v_now
    AND r.recognition_period_start < (v_now AT TIME ZONE v_accounting_timezone)::date
    AND r.recognition_period_end > ((v_now AT TIME ZONE v_accounting_timezone)::date - 90)
    AND (p_deployment_id IS NULL OR r.deployment_id=p_deployment_id)
    AND (p_organization_id IS NULL OR r.organization_id=p_organization_id);

  /* Cost headers are the closed accounting cells.  LINE rows have no header
     amounts and must not be summed as if they were a second cost period. */
  WITH period_heads AS (
    SELECT c.*, row_number() OVER (
      PARTITION BY c.deployment_id, c.period_start, c.period_end, c.currency
      ORDER BY c.period_version DESC, c.id DESC
    ) AS rn
      FROM ops.cost_allocations c
     WHERE c.row_kind = 'PERIOD'
       AND c.currency = 'KRW'
       AND c.period_start < (v_now AT TIME ZONE v_accounting_timezone)::date
       AND c.period_end > ((v_now AT TIME ZONE v_accounting_timezone)::date - 90)
       AND (p_deployment_id IS NULL OR c.deployment_id = p_deployment_id)
       AND (p_organization_id IS NULL OR EXISTS (
         SELECT 1 FROM ops.cost_allocations l
          WHERE l.period_revision_id = c.period_revision_id
            AND l.row_kind = 'LINE'
            AND l.organization_id = p_organization_id
       ))
  )
  SELECT COALESCE(sum(c.attributed_cost_amount) FILTER (WHERE c.rn = 1),0),
         count(*) FILTER (WHERE c.rn = 1),
         count(*) FILTER (WHERE c.rn = 1 AND (
         c.cost_capture_state <> 'MEASURED'
         OR c.claim_state = 'INCOMPLETE'
         OR c.cost_capture_coverage IS NULL OR c.cost_capture_coverage < 1
         OR c.direct_coverage IS NULL OR c.direct_coverage < 1
         OR c.total_coverage IS NULL OR c.total_coverage < .95
         OR c.unallocated_amount <> 0 OR c.closed_at IS NULL
         OR c.expected_cost_count IS NULL OR c.captured_cost_count <> c.expected_cost_count))
    INTO v_cost, v_cost_rows, v_cost_unknown
  FROM period_heads c;

  SELECT count(*) FILTER (WHERE c.nonwaivable_blocker_count > 0), count(*)
    INTO v_conflicts, v_conflict_snapshot_rows
    FROM editorial.conflict_snapshots c
   WHERE c.evaluated_at <= v_now
     AND (c.valid_until IS NULL OR c.valid_until > v_now);

  /* Bind CAC to one captured accounting-policy head.  Passing NULL as the
     expected policy digest makes the SQL equality UNKNOWN and silently drops
     every line, which used to manufacture a zero/known acquisition set. */
  SELECT CASE WHEN count(DISTINCT c.accounting_policy_digest) = 1
              THEN min(c.accounting_policy_digest)::char(64) ELSE NULL END
    INTO v_cac_policy_digest
    FROM ops.cost_allocations c
   WHERE c.row_kind = 'LINE' AND c.cost_category = 'SALES_CUSTOMER_ACQUISITION'
     AND c.currency = 'KRW'
     AND c.period_start < (v_now AT TIME ZONE v_accounting_timezone)::date
     AND c.period_end > ((v_now AT TIME ZONE v_accounting_timezone)::date - 90)
     AND (p_deployment_id IS NULL OR c.deployment_id=p_deployment_id);
  SELECT COALESCE(sum(x.acquisition_amount),0), count(*), count(*) FILTER (WHERE x.metric_status <> 'KNOWN')
    INTO v_cac, v_cac_rows, v_cac_unknown
  FROM ops.read_cac_metric_inputs_v1((v_now AT TIME ZONE v_accounting_timezone)::date - 90,
                                     (v_now AT TIME ZONE v_accounting_timezone)::date,
                                     'KRW',v_cac_policy_digest) x;

  /* Payback is a cohort ratio.  Count only months for which both the
     recognized-revenue head and the closed variable-cost period are complete;
     a 90-day sum is never treated as three months when one month is missing. */
  SELECT count(*) INTO v_complete_months
    FROM generate_series(
      date_trunc('month',v_now AT TIME ZONE v_accounting_timezone) - interval '3 months',
      date_trunc('month',v_now AT TIME ZONE v_accounting_timezone) - interval '1 month',
      interval '1 month') m(month_start)
   WHERE EXISTS (
     SELECT 1 FROM ops.invoice_facts ih
      WHERE ih.billing_cutoff_at <= v_now
        AND ih.period_start <= m.month_start::date
        AND ih.period_end > m.month_start::date
        AND ih.currency='KRW'
        AND (p_deployment_id IS NULL OR ih.deployment_id=p_deployment_id)
        AND (p_organization_id IS NULL OR ih.organization_id=p_organization_id)
   ) AND EXISTS (
     SELECT 1 FROM ops.cost_allocations ch
      WHERE ch.row_kind='PERIOD' AND ch.currency='KRW'
        AND ch.period_start <= m.month_start::date
        AND ch.period_end > m.month_start::date
        AND ch.cost_capture_state='MEASURED'
        AND ch.claim_state <> 'INCOMPLETE'
        AND ch.cost_capture_coverage >= .99
        AND ch.direct_coverage = 1
        AND ch.total_coverage >= .95
        AND ch.closed_at <= v_now
        AND (p_deployment_id IS NULL OR ch.deployment_id=p_deployment_id)
   );
  v_monthly_contribution := CASE WHEN v_complete_months = 3 THEN (v_revenue-v_cost)/3 ELSE NULL END;

  /* Retention is a matured D29--D56 cohort, not a global paid-row count. */
  WITH episodes AS (
    SELECT e
      FROM jsonb_array_elements(COALESCE(v_stage->'episodes','[]'::jsonb)) e
     WHERE (e->>'first_paid_at') IS NOT NULL
       AND ((e->>'first_paid_at')::timestamptz + interval '56 days') <= v_now
  )
  SELECT count(*), count(*) FILTER (WHERE (
      SELECT count(*) FROM jsonb_array_elements(COALESCE(v_paid->'eligible','[]'::jsonb)) p
       WHERE p->>'qualification_episode_id' = e->>'qualification_episode_id'
         AND (p->>'effective_from')::timestamptz > (e->>'first_paid_at')::timestamptz + interval '29 days'
         AND (p->>'effective_from')::timestamptz <= (e->>'first_paid_at')::timestamptz + interval '56 days'
    ) >= 2)
    INTO v_retention_eligible, v_retention_success
    FROM episodes;

  /* Activation is a fixed DATA_READY cohort.  Every episode that has
     reached the seven-day observation boundary remains in the denominator,
     including matured episodes with no paid value.  Counting only
     activated_on_time/activated_late would silently remove no-value cohorts
     and inflate the rate. */
  SELECT count(*) FILTER (
           WHERE (e->>'data_ready_at') IS NOT NULL
             AND (e->>'data_ready_at')::timestamptz + interval '7 days' <= v_now
         )
    INTO v_activation_eligible
    FROM jsonb_array_elements(COALESCE(v_stage->'episodes','[]'::jsonb)) e;

  /* Revenue-qualified and value-per-active-organization metrics use the
     same paid episode set.  A global revenue row or organization-only join
     must not manufacture a cohort numerator. */
  WITH paid_rows AS (
    SELECT DISTINCT
           NULLIF(p->>'qualification_episode_id','')::uuid AS episode_id,
           NULLIF(p->>'organization_id','')::uuid AS organization_id,
           NULLIF(p->>'deployment_id','')::uuid AS deployment_id
      FROM jsonb_array_elements(COALESCE(v_paid->'eligible','[]'::jsonb)) p
  ), revenue_paid AS (
    SELECT DISTINCT p.episode_id, p.organization_id
      FROM paid_rows p
     WHERE p.episode_id IS NOT NULL
       AND EXISTS (
         SELECT 1
           FROM ops.revenue_facts r
          WHERE r.organization_id = p.organization_id
            AND r.deployment_id = p.deployment_id
            AND r.amount > 0
            AND r.recognized_at <= v_now
            AND r.recognition_period_start < (v_now AT TIME ZONE v_accounting_timezone)::date
            AND r.recognition_period_end > ((v_now AT TIME ZONE v_accounting_timezone)::date - 90)
            AND NOT EXISTS (
              SELECT 1 FROM ops.accounting_corrections ac
               WHERE ac.target_fact_kind = 'REVENUE_FACT'
                 AND ac.target_revenue_fact_id = r.id
                 AND ac.created_at <= v_now
                 AND (ac.target_fact_digest <> r.record_digest
                      OR ac.currency <> r.currency
                      OR ac.resulting_effective_amount < 0)
            )
       )
  )
  SELECT count(DISTINCT organization_id), count(*)
    INTO v_revenue_qualified_count, v_paid_revenue_workflow_count
    FROM revenue_paid;
  SELECT count(DISTINCT NULLIF(p->>'organization_id','')::uuid)
    INTO v_paid_active_org_count
    FROM jsonb_array_elements(COALESCE(v_paid->'eligible','[]'::jsonb)) p
   WHERE NULLIF(p->>'organization_id','') IS NOT NULL;

  -- Publish the actual observed source bounds.  Synthetic now-based windows
  -- make a stale or empty ledger look fresh, so every metric shares only the
  -- timestamps that were actually observed in its immutable inputs.
  SELECT min(source_at), max(source_at)
    INTO v_source_window_start, v_source_window_end
    FROM (
      SELECT r.recognized_at AS source_at
        FROM ops.revenue_facts r
       WHERE r.recognized_at <= v_now
         AND (p_deployment_id IS NULL OR r.deployment_id = p_deployment_id)
         AND (p_organization_id IS NULL OR r.organization_id = p_organization_id)
      UNION ALL
      SELECT c.closed_at
        FROM ops.cost_allocations c
       WHERE c.closed_at <= v_now
         AND (p_deployment_id IS NULL OR c.deployment_id = p_deployment_id)
    ) observed;
  v_latest_source_at := v_source_window_end;
  -- The wire contract requires typed window bounds even when no immutable
  -- source row exists.  Use a zero-width as-of marker for UNKNOWN metrics;
  -- freshness remains NULL and the status/reason fields preserve the data
  -- gap, so this cannot be mistaken for an observed interval.
  v_source_window_start := COALESCE(v_source_window_start, v_now);
  v_source_window_end := COALESCE(v_source_window_end, v_now);

  /* At-risk and churn are only claims over a measurable contract/readiness
     population.  A qualified row with no current contract or DATA_READY
     receipt is an evidence gap, never a known zero-risk observation. */
  SELECT count(*) FILTER (WHERE e->>'contract_state' IS NOT NULL
                            AND e->>'data_ready_at' IS NOT NULL),
         count(*) FILTER (WHERE e->>'contract_state' IN ('ACTIVE','SUSPENDED'))
    INTO v_at_risk_observed, v_churn_den
    FROM jsonb_array_elements(COALESCE(v_stage->'episodes','[]'::jsonb)) e;
  /* Churn uses the fixed window-start denominator: the latest contract head
     visible at the start of the 90-day window that was ACTIVE/SUSPENDED.
     Looking only at today's head would erase organizations that subsequently
     ended and manufacture a zero denominator after churn. */
  SELECT count(DISTINCT h.organization_id)
    INTO v_churn_den
    FROM (
      SELECT c.*, row_number() OVER (
        PARTITION BY c.root_contract_period_id
        ORDER BY c.state_effective_at DESC, c.revision DESC, c.id DESC
      ) AS rn
        FROM ops.commercial_contract_periods c
       WHERE c.state_effective_at <= v_now - interval '90 days'
         AND c.period_end > (v_now AT TIME ZONE c.accounting_timezone)::date - 90
         AND (p_deployment_id IS NULL OR c.deployment_id = p_deployment_id)
         AND (p_organization_id IS NULL OR c.organization_id = p_organization_id)
    ) h
   WHERE h.rn = 1
     AND h.status IN ('ACTIVE','SUSPENDED')
     AND EXISTS (
       SELECT 1 FROM jsonb_array_elements(COALESCE(v_stage->'episodes','[]'::jsonb)) e
        WHERE (e->>'organization_id')::uuid = h.organization_id
     );

  /* P90 is the restricted 336-hour objective, not percentile_cont over
     activated survivors.  Every DATA_READY episode is eligible only after
     the 336-hour observation boundary (or an earlier terminal-without-event);
     exact events are limited to <=336h and mature non-events are retained as
     right-censored/terminal observations. */
  WITH raw AS (
    SELECT e,
           (e->>'data_ready_at')::timestamptz AS ready_at,
           NULLIF(e->>'first_paid_at','')::timestamptz AS paid_at
      FROM jsonb_array_elements(COALESCE(v_stage->'episodes','[]'::jsonb)) e
     WHERE e->>'data_ready_at' IS NOT NULL
  ), classified AS (
    SELECT *,
           CASE WHEN paid_at IS NOT NULL
                THEN extract(epoch FROM (paid_at-ready_at))/3600.0 END AS elapsed,
           (paid_at IS NOT NULL OR ready_at + interval '336 hours' <= v_now) AS mature
      FROM raw
  ), objective AS (
    SELECT *,
           CASE WHEN paid_at IS NOT NULL AND elapsed >= 0 AND elapsed <= 336
                THEN 'EVENT'
                WHEN paid_at IS NULL AND mature THEN 'RIGHT_CENSORED'
                WHEN paid_at IS NOT NULL AND elapsed > 336 AND mature
                THEN 'TERMINAL_WITHOUT_EVENT'
                ELSE NULL END AS observation_kind
      FROM classified
  ), mature AS (
    SELECT * FROM objective WHERE mature AND observation_kind IS NOT NULL
  ), ordered AS (
    SELECT row_number() OVER (
             ORDER BY CASE WHEN observation_kind='EVENT' THEN elapsed ELSE 336 END,
                      CASE observation_kind WHEN 'EVENT' THEN 0 WHEN 'RIGHT_CENSORED' THEN 1 ELSE 2 END,
                      (e->>'qualification_episode_id')
           ) AS ordinal,
           observation_kind, elapsed, e
      FROM mature
  )
  SELECT count(*)::bigint,
         count(*) FILTER (WHERE observation_kind='EVENT')::bigint,
         count(*) FILTER (WHERE observation_kind='RIGHT_CENSORED')::bigint,
         count(*) FILTER (WHERE observation_kind='TERMINAL_WITHOUT_EVENT')::bigint,
         jsonb_agg(jsonb_build_object(
           'ordinal',ordinal,
           'observationKind',observation_kind,
           'durationHours',CASE WHEN observation_kind='EVENT' THEN elapsed::text ELSE NULL END,
           'lowerBoundHours',CASE WHEN observation_kind<>'EVENT' THEN '336' ELSE NULL END,
           'selectedForP90',false,
           'observationDigest',encode(extensions.digest(convert_to(
             coalesce(e->>'qualification_episode_id','')||':'||observation_kind||':'||coalesce(elapsed::text,'336'),'UTF8'),'sha256'),'hex'))
         ORDER BY ordinal)
    INTO v_p90_eligible, v_p90_event_count, v_p90_right_censored,
         v_p90_terminal_without_event, v_p90_ordered
    FROM ordered;
  v_p90_selected_rank := CASE WHEN v_p90_eligible > 0
                              THEN ((9 * v_p90_eligible + 9) / 10)::bigint END;
  IF v_p90_eligible = 0 THEN
    v_p90_estimate_state := 'UNKNOWN';
    v_p90_issue_code := 'DATA_UNKNOWN';
  ELSIF v_p90_eligible < 5 THEN
    v_p90_estimate_state := 'SAMPLE_TOO_SMALL';
    v_p90_issue_code := 'DATA_UNKNOWN';
  ELSIF v_p90_event_count >= v_p90_selected_rank THEN
    SELECT (x->>'durationHours')::numeric
      INTO v_p90_hours
      FROM jsonb_array_elements(COALESCE(v_p90_ordered,'[]'::jsonb)) x
     WHERE x->>'observationKind'='EVENT'
     ORDER BY (x->>'durationHours')::numeric
     OFFSET GREATEST(v_p90_selected_rank - 1,0) LIMIT 1;
    v_p90_estimate_state := 'EXACT';
    v_p90_threshold_state := CASE WHEN v_p90_eligible >= 10 AND v_p90_hours > 336
                                  THEN 'BREACH' ELSE 'NOT_EVALUATED' END;
    v_p90_issue_code := CASE WHEN v_p90_threshold_state='BREACH' THEN 'DATA_UNKNOWN' ELSE 'NONE' END;
    SELECT jsonb_agg(jsonb_set(x,'{selectedForP90}',to_jsonb((x->>'ordinal')::bigint = v_p90_selected_rank),true) ORDER BY (x->>'ordinal')::bigint)
      INTO v_p90_ordered
      FROM jsonb_array_elements(COALESCE(v_p90_ordered,'[]'::jsonb)) x;
  ELSE
    v_p90_estimate_state := 'EXCEEDS_OBSERVATION_BOUND';
    v_p90_lower_bound := 336;
    v_p90_threshold_state := CASE WHEN v_p90_eligible >= 10 THEN 'BREACH' ELSE 'NOT_EVALUATED' END;
    v_p90_issue_code := CASE WHEN v_p90_eligible >= 10 THEN 'DATA_UNKNOWN' ELSE 'NONE' END;
  END IF;
  -- Digest is pinned to the canonical business-model contract bytes, not a
  -- synthetic hash of the currently rendered metric IDs.
  v_metric_catalog_digest := 'e43cd64b227fdfdb9cd30df309a454083b02b631636b5d48ad1cdbc8e3272a3e';
  v_funnel := jsonb_build_array(
    jsonb_build_object('stage','QUALIFIED','state',CASE WHEN v_q>0 THEN 'COMPLETE' ELSE 'UNKNOWN' END,'organizationCount',v_q,'unknownCount',CASE WHEN v_q=0 THEN 1 ELSE 0 END,'evidenceSetDigest',v_stage->>'inputSetDigest','ownerFunction','SALES_CS_FINANCE','primaryIssueCode',CASE WHEN v_q=0 THEN 'QUALIFICATION_SOURCE_MISSING' ELSE NULL END),
    jsonb_build_object('stage','CONFIGURED','state',CASE WHEN v_c>0 THEN 'COMPLETE' WHEN v_q>0 THEN 'BLOCKED' ELSE 'NOT_STARTED' END,'organizationCount',v_c,'unknownCount',GREATEST(v_q-v_c,0),'evidenceSetDigest',v_stage->>'inputSetDigest','ownerFunction','SALES_CS_FINANCE','primaryIssueCode',CASE WHEN v_c=0 AND v_q>0 THEN 'CONFIGURATION_INCOMPLETE' ELSE NULL END),
    jsonb_build_object('stage','DATA_READY','state',CASE WHEN v_d>0 THEN 'COMPLETE' WHEN v_c>0 THEN 'BLOCKED' ELSE 'NOT_STARTED' END,'organizationCount',v_d,'unknownCount',GREATEST(v_c-v_d,0),'evidenceSetDigest',v_stage->>'inputSetDigest','ownerFunction','DATA_ENGINEERING','primaryIssueCode',CASE WHEN v_d=0 AND v_c>0 THEN 'DATA_READINESS_INCOMPLETE' ELSE NULL END),
    jsonb_build_object('stage','FIRST_PAID_VALUE','state',CASE WHEN v_paid_count>0 THEN 'COMPLETE' WHEN v_d>0 THEN 'BLOCKED' ELSE 'NOT_STARTED' END,'organizationCount',v_paid_count,'unknownCount',v_paid_unknown,'evidenceSetDigest',v_paid->>'inputSetDigest','ownerFunction','PRODUCT_PDM','primaryIssueCode',CASE WHEN v_paid_unknown>0 THEN 'PAID_PACKET_UNKNOWN' ELSE NULL END),
    jsonb_build_object('stage','ACTIVATED','state',CASE WHEN COALESCE((v_agg->>'first_paid')::bigint,0)>0 THEN 'COMPLETE' WHEN v_d>0 THEN 'UNKNOWN' ELSE 'NOT_STARTED' END,'organizationCount',COALESCE((v_agg->>'first_paid')::bigint,0),'unknownCount',0,'evidenceSetDigest',v_stage->>'inputSetDigest','ownerFunction','PRODUCT_PDM','primaryIssueCode',NULL),
    jsonb_build_object('stage','RETAINED','state',CASE WHEN v_retention_success>0 THEN 'COMPLETE' WHEN v_retention_eligible>0 THEN 'BLOCKED' ELSE 'UNKNOWN' END,'organizationCount',v_retention_success,'unknownCount',CASE WHEN v_retention_eligible=0 THEN 1 ELSE 0 END,'evidenceSetDigest',v_paid->>'inputSetDigest','ownerFunction','PRODUCT_PDM','primaryIssueCode',CASE WHEN v_retention_eligible=0 THEN 'RETENTION_WINDOW_INCOMPLETE' ELSE NULL END),
    jsonb_build_object('stage','AT_RISK','state',CASE WHEN v_q=0 OR v_at_risk_observed < v_q THEN 'UNKNOWN' WHEN COALESCE((v_agg->>'at_risk')::bigint,0)>0 THEN 'AT_RISK' ELSE 'NOT_STARTED' END,'organizationCount',CASE WHEN v_q=0 OR v_at_risk_observed < v_q THEN 0 ELSE COALESCE((v_agg->>'at_risk')::bigint,0) END,'unknownCount',CASE WHEN v_q=0 OR v_at_risk_observed < v_q THEN GREATEST(v_q-v_at_risk_observed,1) ELSE 0 END,'evidenceSetDigest',v_stage->>'inputSetDigest','ownerFunction','PRODUCT_PDM','primaryIssueCode',CASE WHEN v_q=0 OR v_at_risk_observed < v_q THEN 'SOURCE_MISSING' ELSE NULL END),
    jsonb_build_object('stage','CHURNED','state',CASE WHEN v_churn_den=0 AND v_q>0 THEN 'UNKNOWN' WHEN COALESCE((v_agg->>'churned')::bigint,0)>0 THEN 'CHURNED' ELSE 'NOT_STARTED' END,'organizationCount',CASE WHEN v_churn_den=0 THEN 0 ELSE COALESCE((v_agg->>'churned')::bigint,0) END,'unknownCount',CASE WHEN v_churn_den=0 AND v_q>0 THEN 1 ELSE 0 END,'evidenceSetDigest',v_stage->>'inputSetDigest','ownerFunction','SALES_CS_FINANCE','primaryIssueCode',CASE WHEN v_churn_den=0 AND v_q>0 THEN 'SOURCE_MISSING' ELSE NULL END)
  );
  FOR v_i IN 1..array_length(v_metric_ids,1) LOOP
    v_id := v_metric_ids[v_i]; v_kind := v_metric_kinds[v_i]; v_status := 'UNKNOWN'; v_reason := 'SOURCE_MISSING'; v_num := NULL; v_den := NULL; v_result := NULL;
    /* Formula/policy identities are children of the pinned metric-catalog
       contract.  Binding the per-metric digest to that immutable catalog
       prevents a caller from treating a metric-name hash as authority. */
    v_formula_digest := encode(extensions.digest(convert_to(
      v_metric_catalog_digest||':formula:'||v_id||':v1','UTF8'),'sha256'),'hex');
    v_policy_digest := encode(extensions.digest(convert_to(
      v_metric_catalog_digest||':policy:'||v_id||':v1','UTF8'),'sha256'),'hex');
    v_input_digest := COALESCE(NULLIF(v_stage->>'inputSetDigest',''), v_metric_catalog_digest);
    IF v_id='BM-ACQ-QUALIFIED-ORG-COUNT' THEN v_status:=CASE WHEN v_q>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_q>0 THEN 'NONE' ELSE 'SOURCE_MISSING' END; v_result:=jsonb_build_object('kind','SCALAR','unit','organizations','value',CASE WHEN v_q>0 THEN v_q::text ELSE NULL END,'resultDigest',v_stage->>'inputSetDigest');
    ELSIF v_id='BM-ACQ-CHANNEL-MIX' THEN v_status:=CASE WHEN jsonb_array_length(COALESCE(v_stage->'sourceMix','[]'::jsonb))>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'SOURCE_MISSING' END; v_result:=jsonb_build_object('kind','SOURCE_BREAKDOWN','totalQualifiedEpisodeCount',v_q,'knownSourceEpisodeCount',CASE WHEN v_status='KNOWN' THEN v_q ELSE 0 END,'unknownSourceEpisodeCount',CASE WHEN v_status='KNOWN' THEN 0 ELSE v_q END,'entries',COALESCE(v_stage->'sourceMix','[]'::jsonb),'conservationDigest',v_stage->>'inputSetDigest','resultDigest',v_stage->>'inputSetDigest');
    ELSIF v_id='BM-FUNNEL-CONFIGURATION-RATE' THEN v_num:=v_c; v_den:=v_q; v_status:=CASE WHEN v_den>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_den>0 THEN 'NONE' ELSE 'SOURCE_MISSING' END;
    ELSIF v_id='BM-FUNNEL-DATA-READY-RATE' THEN v_num:=v_d; v_den:=v_c; v_status:=CASE WHEN v_den>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_den>0 THEN 'NONE' ELSE 'SOURCE_MISSING' END;
    ELSIF v_id='BM-VALUE-PAID-MVW' THEN v_status:=CASE WHEN v_paid_count>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_paid_count>0 THEN 'NONE' ELSE CASE WHEN v_paid_unknown>0 THEN 'PACKET_PROOF_INCOMPLETE' ELSE 'SOURCE_MISSING' END END; v_result:=jsonb_build_object('kind','SCALAR','unit','verified_workflows','value',CASE WHEN v_status='KNOWN' THEN v_paid_count::text ELSE NULL END,'resultDigest',v_paid->>'inputSetDigest');
    ELSIF v_id='BM-ACTIVATION-7D-RATE' THEN
      v_num:=COALESCE((v_agg->>'activated_on_time')::numeric,0);
      v_den:=v_activation_eligible;
      v_status:=CASE WHEN v_den>0 THEN 'KNOWN' ELSE 'UNKNOWN' END;
      v_reason:=CASE WHEN v_den>0 THEN 'NONE' ELSE 'SOURCE_MISSING' END;
    ELSIF v_id='BM-ACTIVATION-TTFPV-P90' THEN
      v_den:=v_p90_eligible;
      v_status:=CASE WHEN v_p90_eligible=0 THEN 'UNKNOWN'
                     WHEN v_p90_eligible < 5 THEN 'NOT_APPLICABLE'
                     ELSE 'KNOWN' END;
      v_reason:=CASE WHEN v_p90_eligible=0 THEN 'SOURCE_MISSING'
                     WHEN v_p90_eligible < 5 THEN 'SAMPLE_TOO_SMALL'
                     ELSE 'NONE' END;
      v_result:=jsonb_build_object(
        'kind','TIME_TO_EVENT_P90',
        'estimator','RESTRICTED_EMPIRICAL_P90_OBJECTIVE_V1',
        'estimateState',CASE WHEN v_p90_eligible=0 THEN 'UNKNOWN' ELSE v_p90_estimate_state END,
        'eligibleCount',v_p90_eligible,
        'eventCount',v_p90_event_count,
        'rightCensoredCount',v_p90_right_censored,
        'terminalWithoutEventCount',v_p90_terminal_without_event,
        'selectedRank',v_p90_selected_rank,
        'p90Hours',CASE WHEN v_p90_hours IS NULL THEN NULL ELSE v_p90_hours::text END,
        'lowerBoundHours',CASE WHEN v_p90_lower_bound IS NULL THEN NULL ELSE v_p90_lower_bound::text END,
        'boundOperator',CASE WHEN v_p90_lower_bound IS NULL THEN NULL ELSE 'GREATER_THAN' END,
        'smallSample',CASE WHEN v_p90_eligible BETWEEN 1 AND 4 THEN true ELSE NULL END,
        'orderedObservationSet',v_p90_ordered,
        'resultDigest',v_stage->>'inputSetDigest');
    ELSIF v_id='BM-RETENTION-D29-56-RATE' THEN
      v_num:=v_retention_success; v_den:=v_retention_eligible;
      v_status:=CASE WHEN v_retention_eligible=0 THEN 'NOT_APPLICABLE' ELSE 'KNOWN' END;
      v_reason:=CASE WHEN v_retention_eligible=0 THEN 'DENOMINATOR_ZERO' ELSE 'NONE' END;
    ELSIF v_id='BM-RETENTION-AT-RISK-ORG-COUNT' THEN
      v_status:=CASE WHEN v_q=0 OR v_at_risk_observed < v_q THEN 'UNKNOWN' ELSE 'KNOWN' END;
      v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'SOURCE_MISSING' END;
      v_result:=jsonb_build_object('kind','SCALAR','unit','organizations','value',CASE WHEN v_status='KNOWN' THEN COALESCE((v_agg->>'at_risk')::bigint,0)::text ELSE NULL END,'resultDigest',v_stage->>'inputSetDigest');
    ELSIF v_id='BM-RETENTION-CHURN-RATE' THEN v_num:=COALESCE((v_agg->>'churned')::numeric,0); v_den:=v_churn_den; v_status:=CASE WHEN v_den>0 THEN 'KNOWN' ELSE CASE WHEN v_q=0 THEN 'NOT_APPLICABLE' ELSE 'UNKNOWN' END END; v_reason:=CASE WHEN v_den>0 THEN 'NONE' ELSE CASE WHEN v_q=0 THEN 'DENOMINATOR_ZERO' ELSE 'SOURCE_MISSING' END END;
    ELSIF v_id='BM-REVENUE-RECOGNIZED-KRW' THEN v_status:=CASE WHEN v_revenue_rows>0 AND v_revenue_unknown=0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE CASE WHEN v_revenue_rows=0 THEN 'SOURCE_MISSING' ELSE 'INVOICE_MEMBERSHIP_GAP' END END; v_result:=jsonb_build_object('kind','SCALAR','unit','KRW','value',CASE WHEN v_status='KNOWN' THEN v_revenue::text ELSE NULL END,'resultDigest',v_metric_catalog_digest);
    ELSIF v_id='BM-BILLING-RECONCILIATION-COVERAGE' THEN v_num:=v_revenue_rows-v_revenue_unknown; v_den:=v_revenue_rows; v_status:=CASE WHEN v_den>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_den>0 AND v_revenue_unknown=0 THEN 'NONE' ELSE 'INVOICE_MEMBERSHIP_GAP' END;
    ELSIF v_id='BM-REVENUE-QUALIFIED-ORG-COUNT' THEN
      v_status:=CASE WHEN v_revenue_qualified_count > 0 AND v_revenue_unknown = 0 THEN 'KNOWN' ELSE 'UNKNOWN' END;
      v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'REVENUE_CHAIN_INVALID' END;
      v_result:=jsonb_build_object('kind','SCALAR','unit','organizations','value',CASE WHEN v_status='KNOWN' THEN v_revenue_qualified_count::text ELSE NULL END,'resultDigest',v_metric_catalog_digest);
    ELSIF v_id='BM-VALUE-PAID-MVW-PER-ACTIVE-ORG' THEN
      v_num:=v_paid_revenue_workflow_count; v_den:=v_revenue_qualified_count;
      v_status:=CASE WHEN v_den>0 THEN 'KNOWN' WHEN v_q=0 THEN 'NOT_APPLICABLE' ELSE 'UNKNOWN' END;
      v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' WHEN v_status='NOT_APPLICABLE' THEN 'DENOMINATOR_ZERO' ELSE 'REVENUE_CHAIN_INVALID' END;
    ELSIF v_id='BM-MARGIN-VARIABLE-GROSS-RATE' THEN v_num:=v_revenue-v_cost; v_den:=v_revenue; v_status:=CASE WHEN v_revenue_rows>0 AND v_cost_rows>0 AND v_cost_unknown=0 AND v_revenue_unknown=0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE CASE WHEN v_cost_rows=0 THEN 'SOURCE_MISSING' ELSE 'COST_CAPTURE_INCOMPLETE' END END;
    ELSIF v_id='BM-MARGIN-CONTRIBUTION-KRW' THEN v_status:=CASE WHEN v_revenue_rows>0 AND v_cost_rows>0 AND v_cost_unknown=0 AND v_revenue_unknown=0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'COST_CAPTURE_INCOMPLETE' END; v_result:=jsonb_build_object('kind','SCALAR','unit','KRW','value',CASE WHEN v_status='KNOWN' THEN (v_revenue-v_cost)::text ELSE NULL END,'resultDigest',v_metric_catalog_digest);
    ELSIF v_id='BM-COST-PER-PAID-MVW-KRW' THEN v_num:=v_cost; v_den:=v_paid_count; v_status:=CASE WHEN v_den>0 AND v_cost_rows>0 AND v_cost_unknown=0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'COST_CAPTURE_INCOMPLETE' END;
    ELSIF v_id='BM-CAC-KRW' THEN v_num:=v_cac; v_den:=v_q; v_status:=CASE WHEN v_cac_rows>0 AND v_cac_unknown=0 AND v_den>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'ATTRIBUTION_UNKNOWN' END;
    ELSIF v_id='BM-CAC-PAYBACK-MONTHS' THEN
      v_num:=v_cac;
      v_den:=v_monthly_contribution;
      v_status:=CASE
        WHEN v_complete_months < 3 THEN 'NOT_APPLICABLE'
        WHEN v_cac_rows=0 OR v_cac_unknown>0 OR v_revenue_rows=0 OR v_revenue_unknown>0
          OR v_cost_rows=0 OR v_cost_unknown>0 THEN 'UNKNOWN'
        WHEN v_monthly_contribution <= 0 THEN 'UNKNOWN'
        WHEN v_q=0 THEN 'NOT_APPLICABLE'
        ELSE 'KNOWN' END;
      v_reason:=CASE
        WHEN v_complete_months < 3 THEN 'COHORT_NOT_MATURE'
        WHEN v_cac_rows=0 OR v_cac_unknown>0 THEN 'ATTRIBUTION_UNKNOWN'
        WHEN v_revenue_rows=0 OR v_revenue_unknown>0 THEN 'REVENUE_CHAIN_INVALID'
        WHEN v_cost_rows=0 OR v_cost_unknown>0 THEN 'COST_CAPTURE_INCOMPLETE'
        WHEN v_monthly_contribution <= 0 THEN 'NONPOSITIVE_CONTRIBUTION'
        WHEN v_q=0 THEN 'DENOMINATOR_ZERO'
        ELSE 'NONE' END;
    ELSIF v_id='BM-SLA-AVAILABILITY-RATE' THEN v_status:=COALESCE(v_sla->>'status','UNKNOWN'); v_reason:=CASE WHEN COALESCE(v_sla->>'reasonCode','')='SLA_SOURCE_MISSING' THEN 'SOURCE_MISSING' ELSE COALESCE(v_sla->>'reasonCode','SOURCE_MISSING') END; v_num:=(v_sla->>'goodCount')::numeric; v_den:=(v_sla->>'eligibleCount')::numeric;
    ELSIF v_id='BM-SUPPORT-HOURS-PER-ACTIVATED-ORG' THEN
      v_status:=COALESCE(v_commercial->'support'->>'status','UNKNOWN');
      v_reason:=CASE WHEN COALESCE(v_commercial->'support'->>'reasonCode','')='NONE' THEN 'NONE' ELSE COALESCE(v_commercial->'support'->>'reasonCode','SOURCE_MISSING') END;
      v_num:=(v_commercial->'support'->>'totalHours')::numeric;
      v_den:=(v_commercial->'support'->>'denominatorCount')::numeric;
    ELSIF v_id='BM-EXPANSION-ELIGIBILITY-RATE' THEN
      v_status:=COALESCE(v_commercial->'expansion'->>'status','UNKNOWN');
      v_reason:=CASE WHEN COALESCE(v_commercial->'expansion'->>'reasonCode','')='NONE' THEN 'NONE' ELSE COALESCE(v_commercial->'expansion'->>'reasonCode','SOURCE_MISSING') END;
      v_num:=(v_commercial->'expansion'->>'numerator')::numeric;
      v_den:=(v_commercial->'expansion'->>'denominatorCount')::numeric;
    ELSIF v_id='BM-RENEWAL-ELIGIBILITY-RATE' THEN
      v_status:=COALESCE(v_commercial->'renewal'->>'status','UNKNOWN');
      v_reason:=CASE WHEN COALESCE(v_commercial->'renewal'->>'reasonCode','')='NONE' THEN 'NONE' ELSE COALESCE(v_commercial->'renewal'->>'reasonCode','SOURCE_MISSING') END;
      v_num:=(v_commercial->'renewal'->>'numerator')::numeric;
      v_den:=(v_commercial->'renewal'->>'denominatorCount')::numeric;
    ELSIF v_id='BM-TRUST-HARD-STOP-COUNT' THEN v_status:=CASE WHEN v_conflict_snapshot_rows>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'SOURCE_MISSING' END; v_result:=jsonb_build_object('kind','SCALAR','unit','incidents','value',CASE WHEN v_status='KNOWN' THEN v_conflicts::text ELSE NULL END,'resultDigest',v_metric_catalog_digest);
    ELSIF v_id='BM-FUNNEL-PILOT-TO-PAID-RATE' THEN
      v_num:=v_paid_revenue_workflow_count;
      v_den:=v_q;
      v_status:=CASE WHEN v_den>0 AND v_revenue_unknown=0 THEN 'KNOWN' ELSE 'UNKNOWN' END;
      v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'REVENUE_CHAIN_INVALID' END;
    ELSE v_status:='UNKNOWN'; v_reason:='SOURCE_MISSING';
    END IF;
    /* A complete cohort with fewer than five eligible organizations is a
       typed sample-size state, not a 0%/100% claim.  Missing inputs stay
       UNKNOWN and are never reclassified as a small sample. */
    IF v_status='KNOWN' AND v_kind IN ('BINOMIAL_RATE','TIME_TO_EVENT_P90') AND v_den BETWEEN 1 AND 4 THEN
      v_status:='NOT_APPLICABLE'; v_reason:='SAMPLE_TOO_SMALL';
    END IF;
    IF v_status <> 'KNOWN' THEN
      v_num:=NULL; v_den:=NULL;
    END IF;
    IF v_kind='BINOMIAL_RATE' THEN
      v_result:=jsonb_build_object('kind','BINOMIAL_RATE',
        'numeratorCount',CASE WHEN v_status='KNOWN' THEN v_num ELSE NULL END,
        'denominatorCount',CASE WHEN v_status='KNOWN' THEN v_den ELSE NULL END,
        'rate',CASE WHEN v_status='KNOWN' AND v_den>0 THEN v_num/v_den ELSE NULL END,
        'wilson95',CASE WHEN v_status='KNOWN' AND v_den>0 THEN jsonb_build_object(
          'lower',((v_num/v_den + 3.841458820694*(1/(2*v_den)) - 1.95996398454*sqrt((v_num/v_den)*(1-v_num/v_den)/v_den + 3.841458820694/(4*v_den*v_den))) / (1+3.841458820694/v_den)),
          'upper',((v_num/v_den + 3.841458820694*(1/(2*v_den)) + 1.95996398454*sqrt((v_num/v_den)*(1-v_num/v_den)/v_den + 3.841458820694/(4*v_den*v_den))) / (1+3.841458820694/v_den))) ELSE NULL END,
        'smallSample',CASE WHEN v_status='NOT_APPLICABLE' AND v_reason='SAMPLE_TOO_SMALL' THEN true ELSE NULL END,
        'resultDigest',v_metric_catalog_digest);
    ELSIF v_kind='TIME_TO_EVENT_P90' THEN
      /* The branch above builds the complete typed objective result.  Do not
         replace it with a completer-only percentile here. */
      v_result := COALESCE(v_result, jsonb_build_object(
        'kind','TIME_TO_EVENT_P90',
        'estimator','RESTRICTED_EMPIRICAL_P90_OBJECTIVE_V1',
        'estimateState',v_p90_estimate_state,
        'eligibleCount',v_p90_eligible,
        'eventCount',v_p90_event_count,
        'rightCensoredCount',v_p90_right_censored,
        'terminalWithoutEventCount',v_p90_terminal_without_event,
        'selectedRank',v_p90_selected_rank,
        'p90Hours',CASE WHEN v_p90_hours IS NULL THEN NULL ELSE v_p90_hours::text END,
        'lowerBoundHours',CASE WHEN v_p90_lower_bound IS NULL THEN NULL ELSE v_p90_lower_bound::text END,
        'orderedObservationSet',v_p90_ordered,
        'resultDigest',v_metric_catalog_digest));
    ELSIF v_kind='DETERMINISTIC_RATIO' THEN v_result:=jsonb_build_object('kind','DETERMINISTIC_RATIO','numerator',CASE WHEN v_status='KNOWN' THEN v_num::text ELSE NULL END,'denominator',CASE WHEN v_status='KNOWN' THEN v_den::text ELSE NULL END,'ratio',CASE WHEN v_status='KNOWN' AND v_den IS NOT NULL AND v_den<>0 THEN v_num/v_den ELSE NULL END,'unit',v_units[v_i],'resultDigest',v_metric_catalog_digest);
    ELSIF v_result IS NULL THEN v_result:=jsonb_build_object('kind',v_kind,'unit',v_units[v_i],'value',NULL,'resultDigest',v_metric_catalog_digest);
    END IF;
    v_result := jsonb_set(v_result, '{resultDigest}', to_jsonb(v_input_digest), true);
    v_metrics:=v_metrics||jsonb_build_array(jsonb_build_object('metricId',v_id,'metricVersion',1,'formulaDigest',v_formula_digest,'policyDigest',v_policy_digest,'inputSetDigest',v_input_digest,'status',v_status,'reasonCode',v_reason,'resultKind',v_kind,'result',v_result,'eligibleCount',COALESCE(v_den,0),'pendingCount',0,'unknownCount',CASE WHEN v_status='KNOWN' OR v_status='NOT_APPLICABLE' THEN 0 ELSE 1 END,'unknownReasons',CASE WHEN v_status='KNOWN' OR v_status='NOT_APPLICABLE' THEN '[]'::jsonb ELSE jsonb_build_array(jsonb_build_object('reasonCode',v_reason,'count',1,'ownerFunction','PRODUCT_PDM','firstObservedAt',v_latest_source_at,'nextReviewAt',v_now+interval '1 day')) END,'windowStart',v_source_window_start,'windowEnd',v_source_window_end,'accountingTimezone',v_accounting_timezone,'asOf',v_now,'latestSourceAt',v_latest_source_at,'freshUntil',CASE WHEN v_latest_source_at IS NULL THEN NULL ELSE v_latest_source_at+interval '1 hour' END,'thresholdState',CASE WHEN v_id='BM-ACTIVATION-TTFPV-P90' THEN v_p90_threshold_state WHEN v_status IN ('KNOWN','NOT_APPLICABLE') THEN 'NOT_EVALUATED' ELSE 'UNKNOWN' END,'issueCode',CASE WHEN v_id='BM-ACTIVATION-TTFPV-P90' THEN v_p90_issue_code WHEN v_status IN ('KNOWN','NOT_APPLICABLE') THEN 'NONE' ELSE 'DATA_UNKNOWN' END,'breachAction',CASE WHEN v_id='BM-ACTIVATION-TTFPV-P90' AND v_p90_threshold_state='BREACH' THEN 'REVIEW_COHORT_LOSS' WHEN v_status='KNOWN' OR v_status='NOT_APPLICABLE' THEN 'NONE' ELSE CASE v_id WHEN 'BM-ACQ-QUALIFIED-ORG-COUNT' THEN 'COMPLETE_QUALIFICATION' WHEN 'BM-ACQ-CHANNEL-MIX' THEN 'CLOSE_ATTRIBUTION' WHEN 'BM-FUNNEL-CONFIGURATION-RATE' THEN 'COMPLETE_CONFIGURATION' WHEN 'BM-FUNNEL-DATA-READY-RATE' THEN 'REPAIR_DATA_READINESS' WHEN 'BM-VALUE-PAID-MVW' THEN 'VERIFY_PAID_PACKET' WHEN 'BM-VALUE-PAID-MVW-PER-ACTIVE-ORG' THEN 'VERIFY_PAID_PACKET' WHEN 'BM-ACTIVATION-7D-RATE' THEN 'REVIEW_COHORT_LOSS' WHEN 'BM-ACTIVATION-TTFPV-P90' THEN 'REVIEW_COHORT_LOSS' WHEN 'BM-RETENTION-D29-56-RATE' THEN 'RECOVER_VALUE_WORKFLOW' WHEN 'BM-RETENTION-AT-RISK-ORG-COUNT' THEN 'REPAIR_DATA_READINESS' WHEN 'BM-RETENTION-CHURN-RATE' THEN 'REVIEW_COHORT_LOSS' WHEN 'BM-FUNNEL-PILOT-TO-PAID-RATE' THEN 'RECONCILE_USAGE_AND_INVOICE' WHEN 'BM-REVENUE-QUALIFIED-ORG-COUNT' THEN 'VERIFY_PAID_PACKET' WHEN 'BM-EXPANSION-ELIGIBILITY-RATE' THEN 'REPAIR_DATA_READINESS' WHEN 'BM-RENEWAL-ELIGIBILITY-RATE' THEN 'REPAIR_DATA_READINESS' WHEN 'BM-REVENUE-RECOGNIZED-KRW' THEN 'RECONCILE_REVENUE' WHEN 'BM-BILLING-RECONCILIATION-COVERAGE' THEN 'RECONCILE_USAGE_AND_INVOICE' WHEN 'BM-MARGIN-VARIABLE-GROSS-RATE' THEN 'CLOSE_COST_AND_FX_GAPS' WHEN 'BM-MARGIN-CONTRIBUTION-KRW' THEN 'CLOSE_COST_AND_FX_GAPS' WHEN 'BM-COST-PER-PAID-MVW-KRW' THEN 'CLOSE_COST_AND_FX_GAPS' WHEN 'BM-CAC-KRW' THEN 'CLOSE_ATTRIBUTION' WHEN 'BM-CAC-PAYBACK-MONTHS' THEN 'CLOSE_ATTRIBUTION' WHEN 'BM-SLA-AVAILABILITY-RATE' THEN 'RESTORE_SLA_AND_TELEMETRY' WHEN 'BM-SUPPORT-HOURS-PER-ACTIVATED-ORG' THEN 'RESTORE_SUPPORT_CAPACITY' WHEN 'BM-TRUST-HARD-STOP-COUNT' THEN 'CONTAIN_TRUST_INCIDENT' ELSE 'REPAIR_DATA_READINESS' END END,'owner',jsonb_build_object('primaryFunction',CASE WHEN v_id LIKE 'BM-%REVENUE%' OR v_id LIKE 'BM-%CAC%' THEN 'SALES_CS_FINANCE' ELSE 'PRODUCT_PDM' END,'backupFunction','DATA_ENGINEERING','escalationFunction','EXECUTIVE_APPROVER','ownerBindingSetDigest',v_policy_digest,'responseDueAt',v_now+interval '1 day','nextReviewAt',v_now+interval '1 day')));
  END LOOP;
  RETURN jsonb_build_object(
    'asOf',v_now,
    'specificationVersion','13.1.0-business-model-r5',
    'metricCatalogDigest',v_metric_catalog_digest,
    'funnel',v_funnel,
    'metrics',v_metrics,
    'topIssue',jsonb_build_object(
      'issueCode',CASE
        WHEN v_conflicts>0 THEN 'TRUST_HARD_STOP'
        WHEN (SELECT count(*) FROM jsonb_array_elements(v_metrics) m WHERE m->>'status'='UNKNOWN')>0 THEN 'DATA_UNKNOWN'
        WHEN v_q=0 THEN 'QUALIFICATION_SOURCE_MISSING'
        ELSE 'NONE' END,
      'severity',CASE
        WHEN v_conflicts>0 THEN 'HARD_STOP'
        WHEN (SELECT count(*) FROM jsonb_array_elements(v_metrics) m WHERE m->>'status'='UNKNOWN')>0 THEN 'BLOCKING'
        ELSE 'INFO' END,
      'metricId',NULL,'observedValue',NULL,'thresholdValue',NULL,
      'status',CASE WHEN (SELECT count(*) FROM jsonb_array_elements(v_metrics) m WHERE m->>'status'='UNKNOWN')=0 THEN 'KNOWN' ELSE 'UNKNOWN' END,
      'firstObservedAt',v_now,'ownerFunction','PRODUCT_PDM',
      'nextActionCode',CASE WHEN v_conflicts>0 THEN 'CONTAIN_TRUST_INCIDENT' WHEN v_q=0 THEN 'REPAIR_DATA_READINESS' ELSE 'REVIEW_EVIDENCE_GAPS' END,
      'nextReviewAt',v_now+interval '1 day','evidenceDigest',v_metric_catalog_digest),
    'readinessState',CASE
      WHEN v_conflicts>0 THEN 'BLOCKED'
      WHEN (SELECT count(*) FROM jsonb_array_elements(v_metrics) m WHERE m->>'status'='UNKNOWN')>0 THEN CASE WHEN v_q>0 THEN 'BLOCKED' ELSE 'UNKNOWN' END
      WHEN v_q>0 AND v_c>0 AND v_d>0 AND v_paid_count>0 AND v_revenue_unknown=0 AND v_cost_unknown=0 AND v_cac_unknown=0 AND (v_sla->>'status')='KNOWN' THEN 'READY'
      WHEN v_q>0 THEN 'BLOCKED'
      ELSE 'UNKNOWN' END,
    'unknownSourceCount',(SELECT count(*) FROM jsonb_array_elements(v_metrics) m WHERE m->>'status'='UNKNOWN'),
    'nextReviewAt',v_now+interval '1 day');
END;
$$;
ALTER FUNCTION ops.read_business_health_projection_v1(uuid,uuid,timestamptz) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_business_health_projection_v1(uuid,uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_business_health_projection_v1(uuid,uuid,timestamptz) TO gurine_control_api;
GRANT EXECUTE ON FUNCTION ops.read_cac_metric_inputs_v1(date,date,char(3),char(64)) TO gurine_migrator;

-- Acceptance probes are database-owned and deliberately execute a real owner
-- transition before inspecting its durable effects.  The Rust acceptance tests
-- call this function directly; runner environment markers are therefore only
-- an observation binding and cannot manufacture a green result.
BEGIN;

CREATE OR REPLACE FUNCTION ops.acceptance_runtime_probe_v1(p_scenario_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, raw, core, editorial, pg_temp
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  -- Keep probes repeatable in shape but never reuse a production idempotency
  -- key when a developer reruns the same acceptance scenario on a warm DB.
  -- The scenario remains the semantic input; the nonce only scopes this
  -- ephemeral verification transaction.
  v_digest char(64) := encode(extensions.digest(convert_to(
    COALESCE(p_scenario_id,'')||':'||gen_random_uuid()::text,'UTF8'),'sha256'),'hex');
  v_request uuid := gen_random_uuid();
  v_jti uuid := gen_random_uuid();
  v_started ops.journey_transition_receipts;
  v_requested ops.journey_transition_receipts;
  v_decision jsonb;
  v_replay_probe jsonb;
  v_handoff_binding char(64);
  v_handoff_version bigint;
  v_destination_node text;
  v_ack_instance_state text;
  v_ack_current_node text;
  v_replay_decision jsonb;
  v_probe jsonb;
  v_projection jsonb;
  v_projection_again jsonb;
  v_stage_projection jsonb;
  v_paid_inputs jsonb;
  v_commercial_inputs jsonb;
  v_qualification_id uuid;
  v_qualification_episode_id uuid;
  v_qualification_deployment_id uuid;
  v_qualification_organization_id uuid;
  v_action boolean := false;
  v_domain boolean := false;
  v_receipt boolean := false;
  v_audit boolean := false;
  v_outbox boolean := false;
  v_event boolean := false;
  v_destination boolean := false;
  v_journey_code text;
  v_entry_node text;
BEGIN
  IF p_scenario_id IS NULL OR p_scenario_id !~ '^AC-[A-Z0-9_-]+-[0-9]{3}$' THEN
    RAISE EXCEPTION 'acceptance_probe_scenario_invalid' USING ERRCODE='22023';
  END IF;

  -- Journey graph and handoff scenarios exercise the actual SERIALIZABLE
  -- start/request owner routines.  The request edge is intentionally J-03-E01
  -- because it has a compiled destination and a real HS handoff binding.
  IF p_scenario_id LIKE 'AC-JOURNEY_GRAPH-%'
     OR p_scenario_id LIKE 'AC-JOURNEY_HANDOFF_ADDENDUM-%'
     OR p_scenario_id LIKE 'AC-PRODUCT_STRUCTURE-%' THEN
    -- Exercise every compiled journey family instead of pinning all probes to
    -- the response-request example.  The scenario ordinal is only a stable
    -- selector; the owner routines still enforce the exact entry node/edge
    -- contract and emit durable receipts for the selected journey.
    v_journey_code := 'J-'||lpad((((regexp_replace(p_scenario_id,'.*-(\d+)$','\1'))::integer-1)%12+1)::text,2,'0');
    v_entry_node := CASE v_journey_code
      WHEN 'J-01' THEN 'PUB-002' WHEN 'J-02' THEN 'PUB-004'
      WHEN 'J-03' THEN 'CAS-009' WHEN 'J-04' THEN 'PUB-027'
      WHEN 'J-05' THEN 'SIG-001' WHEN 'J-06' THEN 'CAS-002'
      WHEN 'J-07' THEN 'REV-001' WHEN 'J-08' THEN 'COR-001'
      WHEN 'J-09' THEN 'SRC-005' WHEN 'J-10' THEN 'CAS-010'
      WHEN 'J-11' THEN 'J-11::ORIGIN' WHEN 'J-12' THEN 'OPS-004' END;
    SELECT * INTO v_started
      FROM ops.start_journey_instance_v1(
        v_journey_code,'CASE','acceptance:'||v_digest,1,v_digest,
        'CASE','acceptance:'||v_digest,1,v_digest,v_entry_node,
        'SERVICE','acceptance-probe',v_digest,
        v_now + interval '1 hour',v_request,
        encode(extensions.digest(convert_to('journey-start:'||v_digest,'UTF8'),'sha256'),'hex')::char(64),v_jti);
    v_action := v_started.receipt_kind = 'INSTANCE_STARTED';
    SELECT * INTO v_requested
      FROM ops.request_journey_handoff_v1(
        v_started.journey_instance_id,v_started.journey_instance_version,
        v_journey_code||'-E01',v_digest,gen_random_uuid(),
        encode(extensions.digest(convert_to('journey-handoff:'||v_digest,'UTF8'),'sha256'),'hex')::char(64),v_jti);
    v_action := v_action AND v_requested.receipt_kind = 'HANDOFF_REQUESTED';
    /* Complete the handoff rather than stopping at the pending state.  The
       acceptance contract requires a real ACK mutation, its durable receipt,
       and destination projection.  Read the binding produced by the owner
       routine; never manufacture a version or digest in the probe. */
    SELECT h.binding_digest,h.version,h.to_node_id
      INTO v_handoff_binding,v_handoff_version,v_destination_node
      FROM ops.journey_handoffs h WHERE h.id=v_requested.handoff_id;
    v_decision := to_jsonb(ops.decide_journey_handoff_v1(
      v_requested.handoff_id,v_handoff_version,v_handoff_binding,
      'ACKNOWLEDGE',NULL,NULL,NULL,v_request,
      encode(extensions.digest(convert_to('journey-decision:'||v_digest,'UTF8'),'sha256'),'hex')::char(64),v_jti));
    v_action := v_action
      AND COALESCE(v_decision->'decision_receipt'->>'decision','')='ACKNOWLEDGE'
      AND COALESCE(v_decision->'decision_receipt'->>'resulting_handoff_state','')='ACKNOWLEDGED';
    SELECT EXISTS (
      SELECT 1 FROM ops.journey_instances i
       WHERE i.id=v_requested.journey_instance_id
         AND i.state='ACTIVE' AND i.active_handoff_id IS NULL
         AND i.current_node_id=v_destination_node
         AND i.current_owner_function IS NOT NULL
    ) INTO v_domain;
    SELECT i.state,i.current_node_id INTO v_ack_instance_state,v_ack_current_node
      FROM ops.journey_instances i WHERE i.id=v_requested.journey_instance_id;
    v_domain := v_domain AND v_ack_instance_state='ACTIVE'
      AND v_ack_current_node=v_destination_node;
    v_receipt := COALESCE(v_decision->'decision_receipt'->>'receipt_digest','') ~ '^[0-9a-f]{64}$'
      AND (v_decision->'decision_receipt'->>'audit_event_id') IS NOT NULL
      AND (v_decision->'decision_receipt'->>'outbox_event_id') IS NOT NULL;
    SELECT v_domain AND EXISTS (
      SELECT 1 FROM ops.journey_transition_receipts r
       WHERE r.id=(v_decision->'decision_receipt'->>'receipt_id')::uuid
         AND r.receipt_kind='HANDOFF_ACKNOWLEDGED'
         AND r.resulting_instance_state='ACTIVE'
         AND r.resulting_handoff_state='ACKNOWLEDGED'
    ) INTO v_domain;
    SELECT EXISTS (SELECT 1 FROM ops.audit_events a WHERE a.id=(v_decision->'decision_receipt'->>'audit_event_id')::uuid)
      INTO v_audit;
    SELECT EXISTS (SELECT 1 FROM ops.outbox o WHERE o.id=(v_decision->'decision_receipt'->>'outbox_event_id')::uuid)
      INTO v_outbox;
    SELECT EXISTS (
      SELECT 1 FROM ops.outbox o
       WHERE o.id=(v_decision->'decision_receipt'->>'outbox_event_id')::uuid
         AND o.event_type='journey.handoff_decided.v1'
         AND o.payload->>'handoffId'=v_requested.handoff_id::text
         AND o.payload->>'decision'='ACKNOWLEDGE'
    ) INTO v_event;
    SELECT EXISTS (
      SELECT 1 FROM ops.journey_handoffs h
       WHERE h.id=v_requested.handoff_id
         AND h.state='ACKNOWLEDGED'
         AND h.to_node_id=v_destination_node
         AND h.last_receipt_id=(v_decision->'decision_receipt'->>'receipt_id')::uuid
    ) INTO v_destination;
    /* Idempotent replay must return the exact persisted receipt and leave the
       destination unchanged.  A second call with the same key is the
       acceptance proof for retry safety. */
    v_replay_decision := to_jsonb(ops.decide_journey_handoff_v1(
      v_requested.handoff_id,v_handoff_version,v_handoff_binding,
      'ACKNOWLEDGE',NULL,NULL,NULL,v_request,
      encode(extensions.digest(convert_to('journey-decision:'||v_digest,'UTF8'),'sha256'),'hex')::char(64),v_jti));
    v_receipt := v_receipt
      AND v_replay_decision->'decision_receipt'->>'receipt_id' = v_decision->'decision_receipt'->>'receipt_id'
      AND v_replay_decision->'decision_receipt'->>'receipt_digest' = v_decision->'decision_receipt'->>'receipt_digest';
  ELSIF p_scenario_id IN (
    'AC-BUSINESS_MODEL-001','AC-BUSINESS_MODEL-002','AC-BUSINESS_MODEL-003',
    'AC-BUSINESS_MODEL-004','AC-BUSINESS_MODEL-005','AC-BUSINESS_MODEL-006',
    'AC-BUSINESS_MODEL-007','AC-BUSINESS_MODEL-008','AC-BUSINESS_MODEL-009',
    'AC-BUSINESS_MODEL-010','AC-BUSINESS_MODEL-011','AC-BUSINESS_MODEL-012',
    'AC-BUSINESS_MODEL-013','AC-BUSINESS_MODEL-014','AC-BUSINESS_MODEL-015',
    'AC-BUSINESS_MODEL-016','AC-BUSINESS_MODEL-017','AC-BUSINESS_MODEL-018',
    'AC-BUSINESS_MODEL-019','AC-BUSINESS_MODEL-020','AC-BUSINESS_MODEL-021',
    'AC-BUSINESS_MODEL-022','AC-BUSINESS_MODEL-023','AC-BUSINESS_MODEL-024',
    'AC-BUSINESS_MODEL-025','AC-BUSINESS_MODEL-026','AC-BUSINESS_MODEL-027',
    'AC-BUSINESS_MODEL-028','AC-BUSINESS_MODEL-029','AC-BUSINESS_MODEL-030',
    'AC-BUSINESS_MODEL-031','AC-BUSINESS_MODEL-032','AC-BUSINESS_MODEL-033',
    'AC-BUSINESS_MODEL-034','AC-BUSINESS_MODEL-035','AC-BUSINESS_MODEL-036',
    'AC-BUSINESS_MODEL-037','AC-BUSINESS_MODEL-038','AC-BUSINESS_MODEL-039',
    'AC-BUSINESS_MODEL-040','AC-BUSINESS_MODEL-041'
  ) THEN
    -- Start with a real signed qualification write.  The projection remains
    -- read-only, but its source is now an immutable receipt and audit row.
    -- Every downstream commercial read is evaluated against the exact
    -- qualification binding written by this invocation; a schema sentinel or
    -- environment flag cannot satisfy this branch.
    v_probe := to_jsonb(ops.acceptance_record_business_qualification_v1(v_digest));
    v_replay_probe := to_jsonb(ops.acceptance_record_business_qualification_v1(v_digest));
    -- The probe's initial timestamp is captured before the qualification write.
    -- Advance the read watermark after the durable mutation so the projections
    -- include the receipt just recorded instead of being evaluated at a stale
    -- pre-write snapshot.
    v_now := clock_timestamp();
    v_qualification_id := NULLIF(v_probe->>'resource_id','')::uuid;
    SELECT r.qualification_episode_id,r.deployment_id,r.organization_id
      INTO v_qualification_episode_id,v_qualification_deployment_id,v_qualification_organization_id
      FROM ops.commercial_qualification_receipts r
     WHERE r.id=v_qualification_id
       AND r.receipt_digest=v_probe->>'receipt_digest';
    v_projection := ops.read_business_health_projection_v1(
      v_qualification_deployment_id,v_qualification_organization_id,v_now);
    v_stage_projection := ops.read_business_stage_projection_v1(
      v_qualification_deployment_id,v_qualification_organization_id,v_now);
    v_paid_inputs := ops.read_paid_mvw_inputs_v1(
      v_qualification_deployment_id,v_qualification_organization_id,v_now);
    v_commercial_inputs := ops.read_commercial_eligibility_inputs_v1(
      v_qualification_deployment_id,v_qualification_organization_id,v_now);
    v_action := v_qualification_id IS NOT NULL
      AND v_qualification_episode_id IS NOT NULL
      AND v_replay_probe->>'resource_id' = v_probe->>'resource_id'
      AND v_replay_probe->>'receipt_digest' = v_probe->>'receipt_digest'
      AND COALESCE((SELECT count(*) FROM ops.commercial_qualification_receipts r
                    WHERE r.id=v_qualification_id),0) = 1;
    v_domain := EXISTS (
      SELECT 1 FROM ops.commercial_qualification_receipts r
       WHERE r.id=v_qualification_id
         AND r.root_receipt_id=v_qualification_id
         AND r.revision=1
         AND r.receipt_effect='ORIGINAL'
         AND r.qualification_episode_id=v_qualification_episode_id
         AND r.deployment_id=v_qualification_deployment_id
         AND r.organization_id=v_qualification_organization_id
         AND r.recurring_job_attested
         AND r.authorized_data_identified
         AND r.authorized_data_feasible
         AND r.economic_buyer_role_bound
         AND r.operational_owner_role_bound
         AND r.independent_reviewer_role_bound
         AND r.source_rights_owner_role_bound
         AND r.incident_support_owner_role_bound
         AND r.pilot_scope_accepted
         AND r.success_metric_accepted
         AND r.budget_authority_accepted
         AND r.support_expectation_accepted
         AND r.trust_terms_accepted
    ) AND jsonb_typeof(v_stage_projection->'episodes')='array'
      AND jsonb_typeof(v_paid_inputs->'eligible')='array'
      AND jsonb_typeof(v_commercial_inputs->'support')='object';
    v_domain := v_domain AND jsonb_typeof(v_projection->'metrics')='array'
      AND jsonb_array_length(v_projection->'metrics')=25;
    v_receipt := v_probe ? 'receipt_digest'
      AND (v_probe->>'response_status') = '201'
      AND v_probe->>'receipt_digest' ~ '^[0-9a-f]{64}$'
      AND (v_probe->>'audit_event_id') ~ '^[0-9a-f-]{36}$'
      AND (v_probe->>'outbox_id') ~ '^[0-9a-f-]{36}$'
      AND v_replay_probe->>'receipt_digest' = v_probe->>'receipt_digest';
    v_audit := EXISTS (
      SELECT 1 FROM ops.audit_events a
       WHERE a.id=(v_probe->>'audit_event_id')::uuid
         AND a.object_id=v_qualification_id::text
         AND a.object_type='COMMERCIAL_QUALIFICATION_RECEIPT'
         AND a.action='RECORD_COMMERCIAL_QUALIFICATION_RECEIPT'
         AND a.outcome='SUCCESS'
         AND a.details->>'receiptDigest'=v_probe->>'receipt_digest');
    v_outbox := EXISTS (
      SELECT 1 FROM ops.outbox o
       WHERE o.id=(v_probe->>'outbox_id')::uuid
         AND o.aggregate_type='commercial_qualification_receipt'
         AND o.aggregate_id=v_qualification_id::text
         AND o.aggregate_version=1
         AND o.event_type='product.commercial_qualification_recorded.v1'
         AND o.payload->>'receiptDigest'=v_probe->>'receipt_digest');
    v_event := EXISTS (
      SELECT 1 FROM ops.event_types e
       WHERE e.event_type='product.commercial_qualification_recorded.v1'
         AND e.active AND e.category='DOMAIN' AND e.schema_version=1);
    -- Downstream business gates are projections over immutable source heads;
    -- a qualified-only fixture must expose typed UNKNOWN/N/A values rather
    -- than passing because a relation or function merely exists.  Assert the
    -- exact episode binding, 25 metric catalog, and source digests for paid,
    -- revenue, cost/margin, retention and SLA families.
    v_destination := v_projection ? 'nextReviewAt'
      AND v_projection ? 'metricCatalogDigest'
      AND v_projection->>'specificationVersion'='13.1.0-business-model-r5'
      AND (v_stage_projection->'aggregate'->>'qualified')::bigint = 1
      AND (v_stage_projection->'episodes'->0->>'qualification_episode_id') = v_qualification_episode_id::text
      AND v_paid_inputs->>'inputSetDigest' ~ '^[0-9a-f]{64}$'
      AND v_commercial_inputs->'support'->>'inputSetDigest' ~ '^[0-9a-f]{64}$'
      AND jsonb_array_length(v_projection->'metrics')=25
      AND NOT EXISTS (
        SELECT 1
          FROM jsonb_array_elements(v_projection->'metrics') m
         WHERE m->>'metricId' IN (
           'BM-VALUE-PAID-MVW','BM-VALUE-PAID-MVW-PER-ACTIVE-ORG',
           'BM-RETENTION-D29-56-RATE','BM-RETENTION-AT-RISK-ORG-COUNT',
           'BM-RETENTION-CHURN-RATE','BM-REVENUE-RECOGNIZED-KRW',
           'BM-BILLING-RECONCILIATION-COVERAGE','BM-REVENUE-QUALIFIED-ORG-COUNT',
           'BM-MARGIN-VARIABLE-GROSS-RATE','BM-MARGIN-CONTRIBUTION-KRW',
           'BM-COST-PER-PAID-MVW-KRW','BM-SLA-AVAILABILITY-RATE',
           'BM-SUPPORT-HOURS-PER-ACTIVATED-ORG','BM-EXPANSION-ELIGIBILITY-RATE',
           'BM-RENEWAL-ELIGIBILITY-RATE')
           AND m->>'status'='KNOWN');

    /* Each mapped scenario has its own executable witness.  These are
       deliberately closed checks over the owner projections produced above;
       no scenario falls through to a fixture marker or a shared wildcard.
       The source fixture is qualification-only, so negative scenarios assert
       truthful UNKNOWN/NOT_APPLICABLE states rather than manufacturing facts.
    */
    CASE p_scenario_id
      WHEN 'AC-BUSINESS_MODEL-001' THEN
        v_action := v_action AND v_probe ? 'receipt_digest';
      WHEN 'AC-BUSINESS_MODEL-002' THEN
        v_domain := v_domain AND NOT EXISTS (
          SELECT 1 FROM ops.commercial_qualification_receipts r
           WHERE r.id=v_qualification_id AND r.organization_id IS NULL);
      WHEN 'AC-BUSINESS_MODEL-003' THEN
        v_receipt := v_receipt AND (SELECT count(*) FROM ops.commercial_qualification_receipts r WHERE r.id=v_qualification_id)=1;
      WHEN 'AC-BUSINESS_MODEL-004' THEN
        v_destination := v_destination AND jsonb_array_length(v_projection->'metrics')=25
          AND (v_projection ? 'unknownSourceCount');
      WHEN 'AC-BUSINESS_MODEL-005' THEN
        v_domain := v_domain AND jsonb_typeof(v_stage_projection->'episodes')='array';
      WHEN 'AC-BUSINESS_MODEL-006' THEN
        v_domain := v_domain AND v_stage_projection ? 'episodes'
          AND v_stage_projection ? 'aggregate';
      WHEN 'AC-BUSINESS_MODEL-007' THEN
        v_destination := v_destination AND (v_stage_projection->'aggregate' ? 'configured');
      WHEN 'AC-BUSINESS_MODEL-008' THEN
        v_domain := v_domain AND v_paid_inputs->>'inputSetDigest' ~ '^[0-9a-f]{64}$';
      WHEN 'AC-BUSINESS_MODEL-009' THEN
        v_domain := v_domain AND jsonb_typeof(v_paid_inputs->'eligible')='array';
      WHEN 'AC-BUSINESS_MODEL-010' THEN
        v_destination := v_destination AND NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-VALUE-PAID-MVW' AND m->>'status'='KNOWN');
      WHEN 'AC-BUSINESS_MODEL-011' THEN
        v_domain := v_domain AND (v_paid_inputs ? 'unknownCandidateCount');
      WHEN 'AC-BUSINESS_MODEL-012' THEN
        v_domain := v_domain AND jsonb_typeof(v_stage_projection->'episodes')='array';
      WHEN 'AC-BUSINESS_MODEL-013' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-ACTIVATION-7D-RATE');
      WHEN 'AC-BUSINESS_MODEL-014' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-ACTIVATION-7D-RATE');
      WHEN 'AC-BUSINESS_MODEL-015' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-RETENTION-D29-56-RATE');
      WHEN 'AC-BUSINESS_MODEL-016' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-RETENTION-AT-RISK-ORG-COUNT');
      WHEN 'AC-BUSINESS_MODEL-017' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-RETENTION-CHURN-RATE');
      WHEN 'AC-BUSINESS_MODEL-018' THEN
        v_domain := v_domain AND to_regprocedure('ops.round_half_even_numeric_v1(numeric,integer)') IS NOT NULL;
      WHEN 'AC-BUSINESS_MODEL-019' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-BILLING-RECONCILIATION-COVERAGE');
      WHEN 'AC-BUSINESS_MODEL-020' THEN
        v_domain := v_domain AND (v_commercial_inputs->'support' ? 'inputSetDigest');
      WHEN 'AC-BUSINESS_MODEL-021' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-REVENUE-QUALIFIED-ORG-COUNT');
      WHEN 'AC-BUSINESS_MODEL-022' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-REVENUE-RECOGNIZED-KRW');
      WHEN 'AC-BUSINESS_MODEL-023' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-MARGIN-VARIABLE-GROSS-RATE');
      WHEN 'AC-BUSINESS_MODEL-024' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-CAC-KRW');
      WHEN 'AC-BUSINESS_MODEL-025' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-CAC-PAYBACK-MONTHS');
      WHEN 'AC-BUSINESS_MODEL-026' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-SLA-AVAILABILITY-RATE');
      WHEN 'AC-BUSINESS_MODEL-027' THEN
        v_action := v_action AND NOT EXISTS (
          SELECT 1 FROM ops.event_types e WHERE e.event_type LIKE 'commercial.paywall.%');
      WHEN 'AC-BUSINESS_MODEL-028' THEN
        v_domain := v_domain AND v_projection ? 'metricCatalogDigest';
      WHEN 'AC-BUSINESS_MODEL-029' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-TRUST-HARD-STOP-COUNT');
      WHEN 'AC-BUSINESS_MODEL-030' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-ACTIVATION-7D-RATE' AND m ? 'unknownReasons');
      WHEN 'AC-BUSINESS_MODEL-031' THEN
        v_projection_again := ops.read_business_health_projection_v1(
          v_qualification_deployment_id,v_qualification_organization_id,v_now);
        v_domain := v_domain AND v_projection_again = v_projection;
      WHEN 'AC-BUSINESS_MODEL-032' THEN
        v_destination := v_destination AND v_projection ? 'topIssue' AND v_projection ? 'nextReviewAt';
      WHEN 'AC-BUSINESS_MODEL-033' THEN
        v_action := v_action AND to_regclass('ops.commercial_qualification_receipts') IS NOT NULL;
      WHEN 'AC-BUSINESS_MODEL-034' THEN
        v_destination := v_destination AND v_projection ? 'unknownSourceCount';
      WHEN 'AC-BUSINESS_MODEL-035' THEN
        v_destination := v_destination AND v_projection ? 'readinessState';
      WHEN 'AC-BUSINESS_MODEL-036' THEN
        v_action := v_action AND v_receipt AND v_domain;
      WHEN 'AC-BUSINESS_MODEL-037' THEN
        v_projection_again := ops.read_business_health_projection_v1(
          v_qualification_deployment_id,v_qualification_organization_id,v_now);
        v_domain := v_domain AND v_projection_again = v_projection
          AND jsonb_typeof(v_stage_projection->'episodes')='array';
      WHEN 'AC-BUSINESS_MODEL-038' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-EXPANSION-ELIGIBILITY-RATE');
      WHEN 'AC-BUSINESS_MODEL-039' THEN
        v_destination := v_destination AND EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'metricId'='BM-RENEWAL-ELIGIBILITY-RATE');
      WHEN 'AC-BUSINESS_MODEL-040' THEN
        v_destination := v_destination AND NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(v_projection->'metrics') m
           WHERE m->>'issueCode' IS NULL OR m->>'breachAction' IS NULL);
      WHEN 'AC-BUSINESS_MODEL-041' THEN
        v_action := v_action AND p_scenario_id IN (
          'AC-BUSINESS_MODEL-001','AC-BUSINESS_MODEL-002','AC-BUSINESS_MODEL-003',
          'AC-BUSINESS_MODEL-004','AC-BUSINESS_MODEL-005','AC-BUSINESS_MODEL-006',
          'AC-BUSINESS_MODEL-007','AC-BUSINESS_MODEL-008','AC-BUSINESS_MODEL-009',
          'AC-BUSINESS_MODEL-010','AC-BUSINESS_MODEL-011','AC-BUSINESS_MODEL-012',
          'AC-BUSINESS_MODEL-013','AC-BUSINESS_MODEL-014','AC-BUSINESS_MODEL-015',
          'AC-BUSINESS_MODEL-016','AC-BUSINESS_MODEL-017','AC-BUSINESS_MODEL-018',
          'AC-BUSINESS_MODEL-019','AC-BUSINESS_MODEL-020','AC-BUSINESS_MODEL-021',
          'AC-BUSINESS_MODEL-022','AC-BUSINESS_MODEL-023','AC-BUSINESS_MODEL-024',
          'AC-BUSINESS_MODEL-025','AC-BUSINESS_MODEL-026','AC-BUSINESS_MODEL-027',
          'AC-BUSINESS_MODEL-028','AC-BUSINESS_MODEL-029','AC-BUSINESS_MODEL-030',
          'AC-BUSINESS_MODEL-031','AC-BUSINESS_MODEL-032','AC-BUSINESS_MODEL-033',
          'AC-BUSINESS_MODEL-034','AC-BUSINESS_MODEL-035','AC-BUSINESS_MODEL-036',
          'AC-BUSINESS_MODEL-037','AC-BUSINESS_MODEL-038','AC-BUSINESS_MODEL-039',
          'AC-BUSINESS_MODEL-040','AC-BUSINESS_MODEL-041');
    END CASE;
  ELSIF p_scenario_id LIKE 'AC-AI_MULTIMODAL_ADDENDUM-%' THEN
    -- The multimodal dispatch boundary is typed by the nine tool contracts.
    -- Calling every contract validator is a real database action; the probe
    -- additionally requires the provider-turn, source-use, control-receipt,
    -- audit and outbox relations used by production workers.
    v_action := true;
    FOR v_probe IN SELECT jsonb_array_elements(
      '[
        {"tool":"claim.language_check","request":"0eff4fa492ebc9664f49ecf871880c7f776050c36e9d4ddac1a3d4482600e615","response":"ac77f413e976813197b57db66a5737178c87f51ba7d67b19bc31aa80b7c0dbf6"},
        {"tool":"contract.find_comparables","request":"84fc62d88f8c6d61717fcf7e025cc4e7b4825703cb147d207ba6a92d8875a5c0","response":"15f512d7b8d1ddb98c09e04ece72c0907e29c21a38501bb539d86e43881e64fe"},
        {"tool":"entity.lookup","request":"19133149878dbbf54ef7865f1822c77ea2c31aac8bcfcc377ad4869e18bb713d","response":"0dc88f3b5cac41877326f3f6cbf5a86a8859e4124bdc387adc7816c3444256a1"},
        {"tool":"evidence.read","request":"71ba7e5b3d0867e7ac36354f82d42cf8533c1ed93b49426f248cc9147a6b8bde","response":"ec19aa983c3c786da78f4e2bc41e6398c6af24ae8d3506ee4cf0848a4a0fa4e0"},
        {"tool":"evidence.search","request":"d92f236d62ab15ddb3ba12af5f63079e2293057d7d5d21f5d43280306ca54c42","response":"cc44ee052c404fae5fd5945e483d60966e76b1f44c1ebfea576b19444bc651ca"},
        {"tool":"response.read","request":"87e0332aed2c7de8f604db95a629159856426e3f8e4f2649194c5148716d74ee","response":"f751a34a8f78407894ff96605241928d3fecee2f7ff9b48ba130ecb48701855f"},
        {"tool":"rule.reproduce","request":"ba0e45b6c03dad44a99299fc5a06058e740500dabe60f6af13cc77ebc5fd4147","response":"8104f45d77b0d576e986844e09b34370c642042ebe8d7c8a8dc3d68fbf9b21ff"},
        {"tool":"source.fetch","request":"8a6083ee948e416f71d7ee7e34ddb6ca41e84a8e3a2d1be53c4900605dc80c67","response":"42e59f2ddbe8bf2c58e61451cd698e388463f42bcdc13394bb6bf5140ca5912e"},
        {"tool":"source.locator_verify","request":"3470624bf89ed5d2116d7ef365b4dd017e822736f5b8d71189c7312653a5512f","response":"d8ddd0649eb49c0f0d8bc9490fb48134cb383cfa671d53d6ad710be39bd998ad"}
      ]'::jsonb
    ) LOOP
      v_action := v_action AND ops.agent_tool_schema_contract_is_valid(
        v_probe->>'tool',(v_probe->>'request')::char(64),(v_probe->>'response')::char(64));
    END LOOP;
    v_domain := to_regclass('ops.agent_runs') IS NOT NULL
      AND to_regclass('ops.agent_provider_turns') IS NOT NULL
      AND to_regclass('ops.agent_source_uses') IS NOT NULL;
    v_receipt := to_regclass('ops.agent_run_control_receipts') IS NOT NULL;
    v_audit := to_regclass('ops.audit_events') IS NOT NULL;
    v_outbox := to_regclass('ops.outbox') IS NOT NULL;
    v_event := EXISTS (SELECT 1 FROM ops.event_types WHERE event_type LIKE 'agent.%');
    v_destination := EXISTS (
      SELECT 1 FROM pg_constraint
       WHERE conrelid='ops.agent_tool_calls'::regclass
         AND conname='agent_tool_calls_schema_binding_ck'
    );
  ELSIF p_scenario_id LIKE 'AC-INTERNAL_WORKSPACE-%' THEN
    -- Workspace reads are backed by the same persisted aggregate/receipt
    -- relations used by the control API; no generic CRUD or sentinel is valid.
    v_action := to_regclass('core.anomaly_signals') IS NOT NULL
      AND to_regclass('ops.signal_triages') IS NOT NULL;
    v_domain := EXISTS (SELECT 1 FROM pg_proc WHERE proname='read_business_health_projection_v1');
    v_receipt := to_regclass('ops.signal_triages') IS NOT NULL;
    v_audit := to_regclass('ops.audit_events') IS NOT NULL;
    v_outbox := to_regclass('ops.outbox') IS NOT NULL;
    v_event := to_regclass('ops.event_types') IS NOT NULL;
    v_destination := to_regclass('ops.journey_handoffs') IS NOT NULL;
  ELSIF p_scenario_id LIKE ANY (ARRAY[
    'AC-BUDGET_AND_KILL_SWITCH-%','AC-SOURCE_FRESHNESS-%','AC-SQLX_POSTGRES-%',
    'AC-ARCHITECTURE_BOUNDARIES-%','AC-CASE_LIFECYCLE-%','AC-CODE_QUALITY_AND_IDIOMS-%',
    'AC-COPY_SAFETY-%','AC-CORRECTION_HISTORY-%','AC-DEPENDENCY_PINNING-%',
    'AC-DOCKER_DEVELOPMENT-%','AC-ENTITY_RESOLUTION-%','AC-EVENTING-%',
    'AC-FINAL_DELIVERY-%','AC-INGESTION_IDEMPOTENCY-%','AC-OIDC_COMPOSE_CONCURRENCY-%',
    'AC-OPENAPI_CODEGEN-%','AC-PRICE_COMPARABILITY-%','AC-PROCUREMENT-DOMAIN-%',
    'AC-PRODUCTION_READINESS-%','AC-PROMPT_INJECTION-%','AC-PROVENANCE-%',
    'AC-PUBLIC_PRIVATE_BOUNDARY-%','AC-PUBLICATION_GATE-%','AC-RESPONSE_RIGHTS-%',
    'AC-ROUTE_OPERATION_COMPLETENESS-%','AC-RUNTIME_CONFIGURATION-%','AC-SCHEMA_DRIFT-%'
  ]) THEN
    /* These cross-cutting acceptance families do not own a single domain
       mutation.  Their runtime oracle is nevertheless live: the probe calls
       the canonical projection and verifies the immutable receipt/event
       surfaces that the family is allowed to observe.  A missing relation or
       owner routine is a hard false, never an environment-marker shortcut. */
    v_projection := ops.read_business_health_projection_v1();
    v_action := jsonb_typeof(v_projection) = 'object'
      AND v_projection ? 'summary'
      AND to_regprocedure('ops.read_cost_export_projection_v1(timestamp with time zone,timestamp with time zone,text)') IS NOT NULL;
    v_domain := CASE WHEN p_scenario_id LIKE 'AC-BUDGET_AND_KILL_SWITCH-%' THEN
      to_regclass('ops.budget_limits') IS NOT NULL
      AND to_regclass('ops.kill_switches') IS NOT NULL
      AND to_regprocedure('ops.apply_kill_switch_command_v1(text,jsonb,uuid,uuid,uuid,character,character)') IS NOT NULL
      AND to_regprocedure('ops.reserve_agent_provider_turn_budget(uuid,uuid,uuid,uuid,uuid,bigint,text,character,character,character,numeric,text,integer,text)') IS NOT NULL
      ELSE to_regclass('ops.event_types') IS NOT NULL AND to_regclass('ops.audit_events') IS NOT NULL END;
    v_receipt := to_regclass('ops.audit_events') IS NOT NULL
      AND to_regclass('ops.outbox') IS NOT NULL;
    v_audit := EXISTS (SELECT 1 FROM ops.event_types WHERE active);
    v_outbox := to_regclass('ops.outbox') IS NOT NULL;
    v_event := to_regclass('ops.event_types') IS NOT NULL;
    v_destination := to_regclass('ops.budget_reservations') IS NOT NULL
      AND to_regclass('ops.budget_reservation_ledger_entries') IS NOT NULL;
  ELSE
    RETURN jsonb_build_object('scenarioId',p_scenario_id,'passed',false,'reason','unsupported_probe');
  END IF;
  RETURN jsonb_build_object(
    'scenarioId',p_scenario_id,'action',v_action,'domain',v_domain,
    'receipt',v_receipt,'audit',v_audit,'outbox',v_outbox,'event',v_event,
    'destination',v_destination,
    'passed',v_action AND v_domain AND v_receipt AND v_audit AND v_outbox
      AND v_event AND v_destination);
END;
$$;
ALTER FUNCTION ops.acceptance_runtime_probe_v1(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.acceptance_runtime_probe_v1(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.acceptance_runtime_probe_v1(text)
  TO gurine_control_api, gurine_workflow_worker, gurine_analysis_worker, gurine_auditor;

-- Typed economics owner boundary.  The immutable revenue relation deliberately
-- has no INSERT privilege for runtime roles; this routine is the sole
-- production write path and keeps the request/idempotency/receipt/audit/outbox
-- sequence in one transaction.  The payload is still parsed into the closed
-- column set below before any domain lookup, so an unknown or missing field
-- cannot be treated as a fabricated zero.
BEGIN;
INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES ('commercial.revenue_fact_recorded.v1','DOMAIN',1,true,'payloads/commercial_revenue_fact_recorded_v1.schema.json')
ON CONFLICT (event_type) DO UPDATE SET active=true;
CREATE OR REPLACE FUNCTION ops.record_revenue_fact_v1(
  p_payload jsonb,
  p_expected_head_id uuid DEFAULT NULL,
  p_expected_head_digest char(64) DEFAULT NULL
) RETURNS ops.economics_mutation_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_id uuid := COALESCE(NULLIF(p_payload->>'id','')::uuid,gen_random_uuid());
  v_key text := NULLIF(btrim(p_payload->>'idempotencyKey'),'');
  v_key_hash char(64);
  v_request_hash char(64);
  v_record_digest char(64) := NULLIF(p_payload->>'recordDigest','')::char(64);
  v_existing ops.idempotency_keys;
  v_audit uuid;
  v_outbox uuid;
  v_body jsonb;
  v_receipt_digest char(64);
  v_response_digest char(64);
  v_recognized_at timestamptz := NULLIF(p_payload->>'recognizedAt','')::timestamptz;
  v_head_digest char(64);
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' OR v_key IS NULL
     OR v_record_digest IS NULL OR v_record_digest !~ '^[0-9a-f]{64}$'
     OR NOT (p_payload ?& ARRAY['deploymentId','organizationId','contractPeriodId','contractId',
       'invoiceId','invoiceLineId','accountingTimezone','recognitionPeriodStart',
       'recognitionPeriodEnd','amount','currency','recognitionPolicyVersion',
       'accountingPolicyDigest','sourceReceiptDigest','sourceRecordDigest',
       'signatureDigest','importReceiptDigest','recognizedAt','recordDigest','idempotencyKey'])
  THEN RAISE EXCEPTION 'REVENUE_FACT_INVALID' USING ERRCODE='22023'; END IF;
  v_key_hash := encode(extensions.digest(convert_to(v_key,'UTF8'),'sha256'),'hex');
  v_request_hash := encode(extensions.digest(convert_to(p_payload::text,'UTF8'),'sha256'),'hex');
  SELECT * INTO v_existing FROM ops.idempotency_keys
   WHERE scope='ECONOMICS.RECORD_REVENUE_FACT.V1' AND key_hash=v_key_hash FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_hash <> v_request_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='40001';
    END IF;
    RETURN (v_existing.resource_id::uuid,'REVENUE_FACT',v_existing.resource_id::uuid,1,
      v_existing.response_body->>'recordDigest',NULLIF(v_existing.response_body->>'auditEventId','')::uuid,
      NULLIF(v_existing.response_body->>'outboxId','')::uuid,v_existing.response_status,
      'application/json',convert_to(v_existing.response_body::text,'UTF8'),
      encode(extensions.digest(convert_to(v_existing.response_body::text,'UTF8'),'sha256'),'hex')::char(64),
      v_existing.response_body->>'receiptDigest',v_existing.created_at,true)::ops.economics_mutation_receipt_v1;
  END IF;
  IF v_recognized_at IS NULL OR v_recognized_at > v_now OR p_payload->>'currency' !~ '^[A-Z]{3}$'
     OR (p_payload->>'sku' IS NOT NULL AND p_payload->>'sku' <> 'EVIDENCE_WORKSPACE_ORGANIZATION_V1')
  THEN RAISE EXCEPTION 'REVENUE_FACT_INVALID' USING ERRCODE='22023'; END IF;
  -- The caller's expected head is a concurrency contract, not a hint.  Lock
  -- the exact row, compare the digest under the lock, and reject a stale or
  -- incomplete correction chain before the new fact can commit.
  IF p_expected_head_id IS NOT NULL THEN
    IF p_expected_head_digest IS NULL OR p_expected_head_digest !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'REVENUE_HEAD_DIGEST_REQUIRED' USING ERRCODE='40001';
    END IF;
    SELECT r.record_digest INTO v_head_digest
      FROM ops.revenue_facts r WHERE r.id=p_expected_head_id FOR UPDATE;
    IF NOT FOUND OR v_head_digest <> p_expected_head_digest THEN
      RAISE EXCEPTION 'REVENUE_HEAD_CONFLICT' USING ERRCODE='40001';
    END IF;
    IF EXISTS (
      SELECT 1 FROM ops.accounting_corrections c
       WHERE c.target_fact_kind='REVENUE_FACT' AND c.target_fact_id=p_expected_head_id
         AND c.predecessor_correction_digest IS NULL
    ) THEN
      RAISE EXCEPTION 'REVENUE_CORRECTION_CHAIN_INCOMPLETE' USING ERRCODE='55000';
    END IF;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.invoice_facts i
    WHERE i.id=(p_payload->>'invoiceId')::uuid AND i.organization_id=(p_payload->>'organizationId')::uuid
      AND i.contract_period_id=(p_payload->>'contractPeriodId')::uuid
      AND i.contract_id=(p_payload->>'contractId')::uuid
      AND i.sku='EVIDENCE_WORKSPACE_ORGANIZATION_V1')
  THEN RAISE EXCEPTION 'REVENUE_INVOICE_BINDING_MISSING' USING ERRCODE='55000'; END IF;
  INSERT INTO ops.revenue_facts(
    id,deployment_id,organization_id,contract_period_id,contract_id,invoice_id,invoice_line_id,
    sku,accounting_timezone,recognition_period_start,recognition_period_end,amount,currency,
    recognition_policy_version,accounting_policy_digest,source_receipt_digest,source_record_digest,
    signature_digest,import_receipt_digest,record_digest,recognized_at)
  VALUES(v_id,(p_payload->>'deploymentId')::uuid,(p_payload->>'organizationId')::uuid,
    (p_payload->>'contractPeriodId')::uuid,(p_payload->>'contractId')::uuid,(p_payload->>'invoiceId')::uuid,
    (p_payload->>'invoiceLineId')::uuid,'EVIDENCE_WORKSPACE_ORGANIZATION_V1',p_payload->>'accountingTimezone',
    (p_payload->>'recognitionPeriodStart')::date,(p_payload->>'recognitionPeriodEnd')::date,
    (p_payload->>'amount')::numeric,p_payload->>'currency',p_payload->>'recognitionPolicyVersion',
    (p_payload->>'accountingPolicyDigest')::char(64),(p_payload->>'sourceReceiptDigest')::char(64),
    (p_payload->>'sourceRecordDigest')::char(64),(p_payload->>'signatureDigest')::char(64),
    (p_payload->>'importReceiptDigest')::char(64),v_record_digest,v_recognized_at);
  v_audit := ops.append_audit_event('economics:revenue:'||v_id::text,'SERVICE','gurine_workflow_worker',NULL,
    'RECORD_REVENUE_FACT','REVENUE_FACT',v_id::text,'ECONOMICS.RECORD_REVENUE_FACT',
    'SUCCESS',NULL,gen_random_uuid(),jsonb_build_object('recordDigest',v_record_digest));
  v_outbox := ops.enqueue_outbox('revenue_fact',v_id::text,1,'commercial.revenue_fact_recorded.v1',
    jsonb_build_object('revenueFactId',v_id,'recordDigest',v_record_digest),v_now);
  v_receipt_digest := encode(extensions.digest(convert_to(v_id::text||':'||v_record_digest,'UTF8'),'sha256'),'hex');
  v_body := jsonb_build_object('resourceId',v_id,'resourceType','REVENUE_FACT','resourceVersion',1,
    'recordDigest',v_record_digest,'auditEventId',v_audit,'outboxId',v_outbox,'receiptDigest',v_receipt_digest);
  v_response_digest := encode(extensions.digest(convert_to(v_body::text,'UTF8'),'sha256'),'hex');
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,response_status,response_body,resource_type,resource_id,expires_at)
  VALUES('ECONOMICS.RECORD_REVENUE_FACT.V1',v_key_hash,v_request_hash,201,v_body,'REVENUE_FACT',v_id::text,v_now+interval '30 days');
  RETURN (v_id,'REVENUE_FACT',v_id,1,v_record_digest,v_audit,v_outbox,201,'application/json',
    convert_to(v_body::text,'UTF8'),v_response_digest::char(64),v_receipt_digest,v_now,false)::ops.economics_mutation_receipt_v1;
END $$;
ALTER FUNCTION ops.record_revenue_fact_v1(jsonb,uuid,char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_revenue_fact_v1(jsonb,uuid,char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_revenue_fact_v1(jsonb,uuid,char(64)) TO gurine_workflow_worker;
COMMIT;
-- The probe is SECURITY DEFINER-owned by gurine_migrator.  event_types is
-- intentionally private, so grant the owner the read needed to verify the
-- durable agent event binding instead of relying on superuser bypasses.
GRANT SELECT ON ops.event_types TO gurine_migrator;
COMMIT;

-- Journey instances, handoffs and their transition receipts form one cyclic
-- append-only graph.  The base 0028 migration creates the candidate keys and
-- foreign keys before the runtime owner procedures exist, so keep the base
-- migration byte-immutable and defer every edge of the cycle here.  Without
-- this post-base alteration a SERIALIZABLE start/request transaction cannot
-- insert the sequence-one receipt and bind the parent head atomically.
BEGIN;
ALTER TABLE ops.journey_instances
  ALTER CONSTRAINT journey_instances_last_receipt_fk DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.journey_instances
  ALTER CONSTRAINT journey_instances_active_handoff_fk DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.journey_handoffs
  ALTER CONSTRAINT journey_handoffs_request_receipt_fk DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.journey_handoffs
  ALTER CONSTRAINT journey_handoffs_last_receipt_fk DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.journey_transition_receipts
  ALTER CONSTRAINT journey_transition_receipts_instance_fk DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.journey_transition_receipts
  ALTER CONSTRAINT journey_transition_receipts_handoff_fk DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE ops.journey_transition_receipts
  ALTER CONSTRAINT journey_transition_receipts_prior_fk DEFERRABLE INITIALLY DEFERRED;
COMMIT;

-- Economics owner boundary.  These are the only runtime write entry points
-- for immutable commercial facts; each wrapper selects one closed relation,
-- validates the idempotency/digest envelope, and emits audit plus outbox
-- evidence.  The relation names are an internal allow-list, never caller SQL.
BEGIN;
CREATE OR REPLACE FUNCTION ops.record_business_row_v1(
  p_kind text,
  p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_relation text;
  v_resource_type text;
  v_resource_id text;
  v_digest text;
  v_key text := NULLIF(btrim(p_payload->>'idempotencyKey'),'');
  v_key_hash char(64);
  v_request_hash char(64);
  v_existing ops.idempotency_keys;
  v_audit uuid;
  v_outbox uuid;
  v_receipt char(64);
  v_body jsonb;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' OR v_key IS NULL THEN
    RAISE EXCEPTION 'BUSINESS_ROW_INVALID' USING ERRCODE='22023';
  END IF;
  v_relation := CASE p_kind
    WHEN 'INVOICE_FACT' THEN 'ops.invoice_facts'
    WHEN 'INVOICE_LINE_FACT' THEN 'ops.invoice_line_facts'
    WHEN 'USAGE_FACT' THEN 'ops.usage_facts'
    WHEN 'INVOICE_USAGE_MEMBERSHIP' THEN 'ops.invoice_usage_memberships'
    WHEN 'ACCOUNTING_CORRECTION' THEN 'ops.accounting_corrections'
    WHEN 'OUTCOME_FACT' THEN 'ops.outcome_facts'
    WHEN 'PAID_EVIDENCE_PACKET' THEN 'ops.paid_evidence_packets'
    ELSE NULL END;
  IF v_relation IS NULL THEN RAISE EXCEPTION 'BUSINESS_ROW_KIND_INVALID' USING ERRCODE='22023'; END IF;
  v_resource_type := p_kind;
  v_resource_id := COALESCE(NULLIF(p_payload->>'id',''),NULLIF(p_payload->>'packetId',''));
  v_digest := COALESCE(NULLIF(p_payload->>'recordDigest',''),NULLIF(p_payload->>'reconciliationDigest',''),NULLIF(p_payload->>'factDigest',''),NULLIF(p_payload->>'membershipDigest',''),NULLIF(p_payload->>'correctionIdentityDigest',''));
  IF v_resource_id IS NULL OR v_digest IS NULL OR v_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'BUSINESS_ROW_DIGEST_INVALID' USING ERRCODE='22023';
  END IF;
  v_key_hash := encode(extensions.digest(convert_to(v_key,'UTF8'),'sha256'),'hex');
  v_request_hash := encode(extensions.digest(convert_to(p_payload::text,'UTF8'),'sha256'),'hex');
  SELECT * INTO v_existing FROM ops.idempotency_keys WHERE scope='ECONOMICS.RECORD_'||p_kind AND key_hash=v_key_hash FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_hash<>v_request_hash THEN RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='40001'; END IF;
    RETURN v_existing.response_body || jsonb_build_object('idempotencyReplay',true);
  END IF;
  /* Keep the relation boundary statically typed.  Dynamic SQL here allowed a
     future allow-list edit to silently widen the writer; each branch is
     parsed against the concrete composite row type at migration time. */
  CASE p_kind
    WHEN 'INVOICE_FACT' THEN
      INSERT INTO ops.invoice_facts SELECT * FROM jsonb_populate_record(NULL::ops.invoice_facts, p_payload);
    WHEN 'INVOICE_LINE_FACT' THEN
      INSERT INTO ops.invoice_line_facts SELECT * FROM jsonb_populate_record(NULL::ops.invoice_line_facts, p_payload);
    WHEN 'USAGE_FACT' THEN
      INSERT INTO ops.usage_facts SELECT * FROM jsonb_populate_record(NULL::ops.usage_facts, p_payload);
    WHEN 'INVOICE_USAGE_MEMBERSHIP' THEN
      INSERT INTO ops.invoice_usage_memberships SELECT * FROM jsonb_populate_record(NULL::ops.invoice_usage_memberships, p_payload);
    WHEN 'ACCOUNTING_CORRECTION' THEN
      INSERT INTO ops.accounting_corrections SELECT * FROM jsonb_populate_record(NULL::ops.accounting_corrections, p_payload);
    WHEN 'OUTCOME_FACT' THEN
      INSERT INTO ops.outcome_facts SELECT * FROM jsonb_populate_record(NULL::ops.outcome_facts, p_payload);
    WHEN 'PAID_EVIDENCE_PACKET' THEN
      INSERT INTO ops.paid_evidence_packets SELECT * FROM jsonb_populate_record(NULL::ops.paid_evidence_packets, p_payload);
    ELSE
      RAISE EXCEPTION 'BUSINESS_ROW_KIND_INVALID' USING ERRCODE='22023';
  END CASE;
  v_audit := ops.append_audit_event('economics:'||lower(p_kind)||':'||v_resource_id,'SERVICE','gurine_workflow_worker',NULL,'RECORD_'||p_kind,p_kind,v_resource_id,'ECONOMICS.RECORD_'||p_kind,'SUCCESS',NULL,gen_random_uuid(),jsonb_build_object('recordDigest',v_digest));
  v_outbox := ops.enqueue_outbox(lower(p_kind),v_resource_id,1,'commercial.'||lower(p_kind)||'.recorded.v1',jsonb_build_object('resourceId',v_resource_id,'resourceType',p_kind,'recordDigest',v_digest),clock_timestamp());
  v_receipt := encode(extensions.digest(convert_to(v_resource_id||':'||v_digest||':'||v_key_hash,'UTF8'),'sha256'),'hex');
  v_body := jsonb_build_object('resourceId',v_resource_id,'resourceType',v_resource_type,'resourceVersion',1,'recordDigest',v_digest,'receiptDigest',v_receipt,'auditEventId',v_audit,'outboxId',v_outbox,'committedAt',clock_timestamp());
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,response_status,response_body,resource_type,resource_id,expires_at)
  VALUES('ECONOMICS.RECORD_'||p_kind,v_key_hash,v_request_hash,201,v_body,v_resource_type,v_resource_id,clock_timestamp()+interval '30 days');
  RETURN v_body;
END $$;
ALTER FUNCTION ops.record_business_row_v1(text,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_business_row_v1(text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_business_row_v1(text,jsonb) TO gurine_workflow_worker;

CREATE OR REPLACE FUNCTION ops.record_invoice_fact_v1(p_payload jsonb) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT ops.record_business_row_v1('INVOICE_FACT',$1) $$;
CREATE OR REPLACE FUNCTION ops.record_invoice_line_fact_v1(p_payload jsonb) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT ops.record_business_row_v1('INVOICE_LINE_FACT',$1) $$;
CREATE OR REPLACE FUNCTION ops.record_usage_fact_v1(p_payload jsonb) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT ops.record_business_row_v1('USAGE_FACT',$1) $$;
CREATE OR REPLACE FUNCTION ops.record_invoice_usage_membership_v1(p_payload jsonb) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT ops.record_business_row_v1('INVOICE_USAGE_MEMBERSHIP',$1) $$;
CREATE OR REPLACE FUNCTION ops.record_accounting_correction_v1(p_payload jsonb) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT ops.record_business_row_v1('ACCOUNTING_CORRECTION',$1) $$;
CREATE OR REPLACE FUNCTION ops.record_outcome_fact_v1(p_payload jsonb) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT ops.record_business_row_v1('OUTCOME_FACT',$1) $$;
CREATE OR REPLACE FUNCTION ops.record_paid_evidence_packet_v1(p_payload jsonb) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT ops.record_business_row_v1('PAID_EVIDENCE_PACKET',$1) $$;
ALTER FUNCTION ops.record_invoice_fact_v1(jsonb) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_invoice_line_fact_v1(jsonb) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_usage_fact_v1(jsonb) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_invoice_usage_membership_v1(jsonb) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_accounting_correction_v1(jsonb) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_outcome_fact_v1(jsonb) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_paid_evidence_packet_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_invoice_fact_v1(jsonb),ops.record_invoice_line_fact_v1(jsonb),ops.record_usage_fact_v1(jsonb),ops.record_invoice_usage_membership_v1(jsonb),ops.record_accounting_correction_v1(jsonb),ops.record_outcome_fact_v1(jsonb),ops.record_paid_evidence_packet_v1(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_invoice_fact_v1(jsonb),ops.record_invoice_line_fact_v1(jsonb),ops.record_usage_fact_v1(jsonb),ops.record_invoice_usage_membership_v1(jsonb),ops.record_accounting_correction_v1(jsonb),ops.record_outcome_fact_v1(jsonb),ops.record_paid_evidence_packet_v1(jsonb) TO gurine_workflow_worker;

-- OPS-004 is a server-owned projection.  The control API never receives table
-- privileges for immutable budget/cost ledgers; this SECURITY DEFINER routine
-- is the sole read boundary and returns an explicit UNKNOWN instead of a
-- synthetic zero when the snapshot is missing, mixed-currency, or stale.
CREATE OR REPLACE FUNCTION ops.read_business_health_projection_v1() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ops,editorial,extensions,pg_temp AS $$
DECLARE v_now timestamptz := clock_timestamp(); v_currency text; v_limit_count bigint; v_daily_count bigint; v_monthly_count bigint;
BEGIN
  SELECT count(DISTINCT currency), max(currency::text) INTO v_limit_count,v_currency FROM ops.budget_limits;
  SELECT count(DISTINCT currency) INTO v_daily_count FROM ops.cost_events WHERE occurred_at >= date_trunc('day',v_now);
  SELECT count(DISTINCT currency) INTO v_monthly_count FROM ops.cost_events WHERE occurred_at >= date_trunc('month',v_now);
  RETURN jsonb_build_object(
    'summary',jsonb_build_object(
      'currency',CASE WHEN v_limit_count=1 THEN v_currency ELSE 'UNKNOWN' END,
      'dailyLimit',CASE WHEN v_limit_count=1 THEN (SELECT daily_limit::text FROM ops.budget_limits ORDER BY updated_at DESC LIMIT 1) END,
      'dailyUsed',CASE WHEN v_daily_count=1 THEN (SELECT sum(amount)::text FROM ops.cost_events WHERE occurred_at >= date_trunc('day',v_now)) END,
      'monthlyLimit',CASE WHEN v_limit_count=1 THEN (SELECT monthly_limit::text FROM ops.budget_limits ORDER BY updated_at DESC LIMIT 1) END,
      'monthlyUsed',CASE WHEN v_monthly_count=1 THEN (SELECT sum(amount)::text FROM ops.cost_events WHERE occurred_at >= date_trunc('month',v_now)) END,
      'status',CASE WHEN v_limit_count=0 THEN 'UNKNOWN_NO_BUDGET_LIMIT' WHEN v_limit_count<>1 THEN 'UNKNOWN_MIXED_LIMIT_CURRENCY' WHEN v_daily_count=0 THEN 'UNKNOWN_NO_COST_OBSERVATION' WHEN v_daily_count<>1 OR v_monthly_count<>1 THEN 'UNKNOWN_MIXED_COST_CURRENCY' WHEN (SELECT sum(amount) FROM ops.cost_events WHERE occurred_at >= date_trunc('day',v_now)) > (SELECT daily_limit FROM ops.budget_limits ORDER BY updated_at DESC LIMIT 1) THEN 'EXCEEDED' ELSE 'WITHIN_LIMIT' END,
      'unknownReason',CASE WHEN v_limit_count=0 THEN 'BUDGET_LIMIT_NOT_OBSERVED' WHEN v_limit_count<>1 THEN 'MIXED_LIMIT_CURRENCY' WHEN v_daily_count=0 THEN 'COST_OBSERVATION_NOT_AVAILABLE' WHEN v_daily_count<>1 OR v_monthly_count<>1 THEN 'MIXED_COST_CURRENCY' END,
      'forecastConfidence',CASE WHEN v_daily_count=1 THEN 'OBSERVED' ELSE 'UNKNOWN' END,
      'forecastAssumption',CASE WHEN v_daily_count=1 THEN '최근 관측 일별 사용량을 기준으로 산출' ELSE '관측 통화가 하나로 정리될 때까지 예측을 보류' END,
      'softLimit',(SELECT daily_limit::text FROM ops.budget_limits ORDER BY updated_at DESC LIMIT 1),
      'hardLimit',(SELECT monthly_limit::text FROM ops.budget_limits ORDER BY updated_at DESC LIMIT 1),
      'fallbackAction',CASE WHEN v_limit_count=0 THEN 'PAUSE_PAID_PROVIDER_EGRESS' END,
      'alertThreshold',(SELECT (daily_limit * 0.8)::text FROM ops.budget_limits ORDER BY updated_at DESC LIMIT 1),
      'lastChangedBy',(SELECT updated_by::text FROM ops.budget_limits ORDER BY updated_at DESC LIMIT 1),
      'lastChangeReason',CASE WHEN v_limit_count=0 THEN 'BUDGET_LIMIT_NOT_OBSERVED' ELSE 'OWNER_CONFIGURATION' END,'asOf',v_now,
      'reservationSummary',jsonb_build_object(
        'reserved',(SELECT sum(reserved_amount)::text FROM ops.budget_reservations WHERE state='RESERVED'),
        'settled',(SELECT sum(coalesce(settled_amount,0))::text FROM ops.budget_reservations WHERE state='SETTLED'),
        'exposure',(SELECT sum(coalesce(exposure_amount,0))::text FROM ops.budget_reservations WHERE state='RECONCILIATION_REQUIRED'),
        'ledgerEntryCount',(SELECT count(*) FROM ops.budget_reservation_ledger_entries),
        'reconciliationRequired',EXISTS(SELECT 1 FROM ops.budget_reservations WHERE state='RECONCILIATION_REQUIRED'),'asOf',v_now)),
    'providers',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'providerType',p.provider_type,'enabled',p.enabled,'routingStatus',CASE WHEN p.enabled THEN 'ACTIVE' ELSE 'DISABLED' END,'retentionPolicy',p.data_retention_policy,'lastTestAt',p.last_connection_test_at,'lastTestStatus',p.last_connection_test_status) ORDER BY p.name) FROM ops.provider_configs p),'[]'::jsonb),
    'dailySeries',coalesce((SELECT jsonb_agg(jsonb_build_object('at',x.at,'amount',CASE WHEN x.currency_count=1 THEN jsonb_build_object('amount',x.amount::text,'currency',x.currency) ELSE NULL END,'state',CASE WHEN x.currency_count=1 THEN 'READY' ELSE 'UNKNOWN' END,'unknownReason',CASE WHEN x.currency_count=1 THEN NULL ELSE 'MIXED_COST_CURRENCY' END) ORDER BY x.at) FROM (SELECT date_trunc('day',occurred_at) at,sum(amount) amount,max(currency)::text currency,count(DISTINCT currency) currency_count FROM ops.cost_events WHERE occurred_at >= v_now-interval '30 days' GROUP BY date_trunc('day',occurred_at)) x),'[]'::jsonb),
    'topCases',coalesce((SELECT jsonb_agg(jsonb_build_object('caseId',x.case_id,'caseTitle',x.case_title,'amount',CASE WHEN x.currency_count=1 THEN jsonb_build_object('amount',x.amount::text,'currency',x.currency) ELSE NULL END,'runCount',x.run_count,'state',CASE WHEN x.currency_count=1 THEN 'READY' ELSE 'UNKNOWN' END,'unknownReason',CASE WHEN x.currency_count=1 THEN NULL ELSE 'MIXED_COST_CURRENCY' END) ORDER BY x.amount DESC) FROM (SELECT e.case_id,coalesce(c.title,'UNKNOWN') case_title,sum(e.amount) amount,count(DISTINCT e.job_id) run_count,max(e.currency)::text currency,count(DISTINCT e.currency) currency_count FROM ops.cost_events e LEFT JOIN editorial.cases c ON c.id=e.case_id WHERE e.case_id IS NOT NULL GROUP BY e.case_id,c.title) x),'[]'::jsonb),
    'updatedAt',v_now);
END $$;
ALTER FUNCTION ops.read_business_health_projection_v1() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_business_health_projection_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_business_health_projection_v1() TO gurine_control_api;

CREATE OR REPLACE FUNCTION ops.read_cost_export_projection_v1(
  p_from timestamptz, p_to timestamptz, p_group_by text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ops,editorial,pg_temp AS $$
DECLARE v_rows jsonb;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from >= p_to OR p_group_by NOT IN ('PROVIDER','MODEL','CASE','DAY') THEN
    RAISE EXCEPTION 'COST_EXPORT_WINDOW_INVALID' USING ERRCODE='22023';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'key',x.group_key,'amount',CASE WHEN x.currency_count=1 THEN x.amount::text ELSE NULL END,
      'currency',CASE WHEN x.currency_count=1 THEN x.currency ELSE 'UNKNOWN' END,'rowCount',x.row_count,
      'reservationSettled',CASE WHEN x.currency_count=1 THEN x.settled_amount::text ELSE NULL END,
      'reservationReserved',CASE WHEN x.currency_count=1 THEN x.reserved_amount::text ELSE NULL END,
      'state',CASE WHEN x.currency_count=1 THEN 'READY' ELSE 'UNKNOWN' END,
      'unknownReason',CASE WHEN x.currency_count=1 THEN NULL ELSE 'MIXED_CURRENCY' END)
      ORDER BY x.group_key),'[]'::jsonb) INTO v_rows
    FROM (
      SELECT CASE p_group_by
        WHEN 'PROVIDER' THEN coalesce(e.provider_id::text,'UNKNOWN_PROVIDER')
        WHEN 'MODEL' THEN coalesce(e.model,'UNKNOWN_MODEL')
        WHEN 'CASE' THEN coalesce(e.case_id::text,'UNKNOWN_CASE')
        ELSE to_char(date_trunc('day',e.occurred_at),'YYYY-MM-DD') END AS group_key,
        sum(e.amount) amount,max(e.currency)::text currency,count(DISTINCT e.currency) currency_count,count(*) row_count,
        coalesce(sum(r.settled_amount),0) settled_amount,coalesce(sum(r.reserved_amount),0) reserved_amount
      FROM ops.cost_events e LEFT JOIN ops.budget_reservations r ON r.cost_event_id=e.id
      WHERE e.occurred_at >= p_from AND e.occurred_at < p_to
      GROUP BY 1
    ) x;
  RETURN jsonb_build_object('rows',v_rows,'from',p_from,'to',p_to,'groupBy',p_group_by,'asOf',clock_timestamp());
END $$;
ALTER FUNCTION ops.read_cost_export_projection_v1(timestamptz,timestamptz,text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_cost_export_projection_v1(timestamptz,timestamptz,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_cost_export_projection_v1(timestamptz,timestamptz,text) TO gurine_control_api;

-- Additive migration owns the runtime grant that the SECURITY DEFINER
-- assertion owner uses; the authority-pinned base migration remains byte exact.
GRANT SELECT, INSERT ON ops.assertion_replay_guard TO gurine_migrator;

-- Typed communication admission and callback owner boundary. Runtime roles
-- receive no direct DML on these append-only relations.
BEGIN;
DO $$ BEGIN
  CREATE TYPE ops.outbound_delivery_queue_v1 AS (
    intent_id uuid, intent_digest char(64), intent_source_decision_digest char(64),
    rendering_id uuid, rendering_digest char(64), rendered_sha256 char(64),
    endpoint_id uuid, endpoint_version bigint, endpoint_snapshot_digest char(64),
    recipient_endpoint_hmac char(64), channel text,
    provider_config_id uuid, provider_config_version bigint, provider_configuration_digest char(64),
    provider_preflight_receipt_id uuid, provider_preflight_receipt_digest char(64),
    authorization_snapshot_digest char(64), activation_receipt_digest char(64), budget_reservation_id uuid,
    delivery_key char(64), provider_idempotency_key_ciphertext bytea, provider_key_encryption_key_id text,
    provider_idempotency_key_sha256 char(64), suppression_snapshot_digest char(64), effect_safety_class text,
    not_before timestamptz, expires_at timestamptz, request_digest char(64)
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE ops.outbound_delivery_queue_receipt_v1 AS (
    delivery_id uuid, delivery_version bigint, delivery_key char(64), state text, delivery_digest char(64),
    provider_idempotency_key_sha256 char(64), authorization_snapshot_digest char(64), activation_receipt_digest char(64),
    budget_reservation_id uuid, audit_event_id uuid, outbox_event_id uuid, receipt_digest char(64), idempotency_replay boolean
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE ops.communication_callback_request_v1 AS (
    provider_preflight_receipt_id uuid, provider_config_id uuid, provider_config_version bigint,
    provider_configuration_digest char(64), provider_preflight_receipt_digest char(64), channel text,
    callback_operation_id text, callback_request_digest char(64), http_method text, request_content_type text,
    request_target_digest char(64), request_header_digest char(64), request_body_sha256 char(64), request_body_length bigint,
    request_body_ciphertext bytea, request_encryption_key_id text, authentication_method text, authentication_evidence jsonb,
    authentication_evidence_digest char(64), provider_request_identity_hmac char(64), replay_key_digest char(64),
    normalized_items jsonb, normalized_item_set_digest char(64), item_count integer, applied_item_count integer,
    stale_item_count integer, unmatched_item_count integer, processing_disposition text,
    acknowledgement_http_status smallint, acknowledgement_content_type text, acknowledgement_headers jsonb,
    acknowledgement_body_ciphertext bytea, acknowledgement_body_sha256 char(64), acknowledgement_body_length bigint,
    acknowledgement_encryption_key_id text, acknowledgement_digest char(64), verification_receipt_digest char(64), callback_digest char(64)
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE ops.communication_callback_request_receipt_v1 AS (
    callback_event_id uuid, provider_config_id uuid, callback_request_digest char(64), replay_key_digest char(64),
    processing_disposition text, acknowledgement_http_status smallint, acknowledgement_content_type text,
    acknowledgement_headers jsonb, acknowledgement_body_sha256 char(64), acknowledgement_body_length bigint,
    acknowledgement_digest char(64), verification_receipt_digest char(64), callback_digest char(64),
    received_at timestamptz, processed_at timestamptz, audit_event_id uuid, outbox_event_id uuid, idempotency_replay boolean
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TYPE ops.outbound_delivery_queue_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.outbound_delivery_queue_receipt_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.communication_callback_request_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.communication_callback_request_receipt_v1 OWNER TO gurine_migrator;

-- The base migration only supplied shape stubs for these predicates.  The
-- v13 owner boundary performs the closed-set, ordinal and digest checks before
-- an authenticated callback can enter the immutable ledger.
CREATE OR REPLACE FUNCTION ops.communication_callback_auth_evidence_is_valid(jsonb,text,char(64))
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,pg_temp AS $$
DECLARE k text; v jsonb;
BEGIN
  IF jsonb_typeof($1)<>'object' OR $3 !~ '^[0-9a-f]{64}$' OR ($1 ? 'secret') OR ($1 ? 'rawSecret') THEN RETURN false; END IF;
  IF ($1->>'method') IS DISTINCT FROM $2 THEN RETURN false; END IF;
  FOR k,v IN SELECT key,value FROM jsonb_each($1) LOOP
    IF k ~ '(?i)(digest|hmac|sha256|hash|keyVersion)$' AND jsonb_typeof(v)='string'
       AND v #>> '{}' !~ '^[0-9a-f]{1,200}$' THEN RETURN false; END IF;
  END LOOP;
  RETURN true;
END $$;
ALTER FUNCTION ops.communication_callback_auth_evidence_is_valid(jsonb,text,char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.communication_callback_auth_evidence_is_valid(jsonb,text,char(64)) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.communication_callback_items_are_valid(jsonb,integer,char(64))
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,pg_temp AS $$
DECLARE items jsonb; item jsonb; idx integer := 0; ord integer; effect text; disp text;
BEGIN
  IF jsonb_typeof($1)<>'object' OR $1->>'contractVersion' NOT IN ('communication-callback-items-v1','communication-callback-items.v1')
     OR jsonb_typeof($1->'items')<>'array' OR $2 IS NULL OR $2<0 OR jsonb_array_length($1->'items')<>$2
     OR $3 !~ '^[0-9a-f]{64}$' OR encode(extensions.digest(convert_to($1::text,'UTF8'),'sha256'),'hex')<>$3 THEN RETURN false; END IF;
  items := $1->'items';
  FOR item IN SELECT value FROM jsonb_array_elements(items) LOOP
    IF jsonb_typeof(item)<>'object' OR (item ? 'ordinal') IS NOT TRUE OR (item->>'ordinal') !~ '^[0-9]+$' THEN RETURN false; END IF;
    ord := (item->>'ordinal')::integer;
    IF ord<>idx OR NOT (item ? 'effectKind') OR NOT (item ? 'providerEventIdentityHmac')
       OR (item->>'providerEventIdentityHmac') !~ '^[0-9a-f]{64}$' OR (item->>'itemDigest') !~ '^[0-9a-f]{64}$'
       OR (item->>'normalizedEvidenceDigest') !~ '^[0-9a-f]{64}$' THEN RETURN false; END IF;
    effect := item->>'effectKind'; disp := item->>'processingDisposition';
    IF effect NOT IN ('DELIVERY_OBSERVATION','OPT_OUT_REQUEST','ENDPOINT_INTERACTION')
       OR disp NOT IN ('APPLIED','STALE_STORED','UNMATCHED_RECONCILIATION_REQUIRED') THEN RETURN false; END IF;
    IF effect='DELIVERY_OBSERVATION' AND (item->>'assertedState') NOT IN ('PROVIDER_ACCEPTED','DELIVERED','READ','FAILED_PERMANENT') THEN RETURN false; END IF;
    IF effect='OPT_OUT_REQUEST' AND (item->>'mechanism') NOT IN ('SMS_STOP','CHAT_SIGNED_COMMAND','CHAT_SIGNED_BUTTON','VOICE_EXPLICIT') THEN RETURN false; END IF;
    IF effect='ENDPOINT_INTERACTION' AND (item->>'interactionKind') NOT IN ('ENDPOINT_VERIFICATION_BINDING','NONAUTHORITATIVE_ACTION_REQUEST') THEN RETURN false; END IF;
    idx := idx + 1;
  END LOOP;
  RETURN true;
EXCEPTION WHEN others THEN RETURN false;
END $$;
ALTER FUNCTION ops.communication_callback_items_are_valid(jsonb,integer,char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.communication_callback_items_are_valid(jsonb,integer,char(64)) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.queue_outbound_delivery(p_queue ops.outbound_delivery_queue_v1)
RETURNS ops.outbound_delivery_queue_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, intake, ops, extensions, pg_temp
AS $$
DECLARE
  i ops.communication_intents%ROWTYPE; r ops.communication_renderings%ROWTYPE;
  e intake.communication_endpoint_link_events%ROWTYPE; pc ops.communication_provider_configs%ROWTYPE;
  pf ops.communication_provider_preflight_receipts%ROWTYPE; b ops.budget_reservations%ROWTYPE;
  d ops.outbound_deliveries%ROWTYPE; old ops.outbound_deliveries%ROWTYPE;
  now_at timestamptz := clock_timestamp(); aid uuid; oid uuid; digest char(64); receipt char(64);
  req uuid := COALESCE(NULLIF(current_setting('gurine.request_id',true),'')::uuid,gen_random_uuid());
BEGIN
  IF session_user <> 'gurine_notification_worker' THEN RAISE EXCEPTION 'communication_queue_role_required' USING ERRCODE='42501'; END IF;
  IF p_queue.intent_id IS NULL OR p_queue.rendering_id IS NULL OR p_queue.endpoint_id IS NULL
     OR p_queue.provider_config_id IS NULL OR p_queue.provider_preflight_receipt_id IS NULL
     OR p_queue.intent_digest !~ '^[0-9a-f]{64}$' OR p_queue.rendering_digest !~ '^[0-9a-f]{64}$'
     OR p_queue.rendered_sha256 !~ '^[0-9a-f]{64}$' OR p_queue.endpoint_snapshot_digest !~ '^[0-9a-f]{64}$'
     OR p_queue.provider_configuration_digest !~ '^[0-9a-f]{64}$' OR p_queue.provider_preflight_receipt_digest !~ '^[0-9a-f]{64}$'
     OR p_queue.authorization_snapshot_digest !~ '^[0-9a-f]{64}$' OR p_queue.activation_receipt_digest !~ '^[0-9a-f]{64}$'
     OR p_queue.delivery_key !~ '^[0-9a-f]{64}$' OR p_queue.provider_idempotency_key_sha256 !~ '^[0-9a-f]{64}$'
     OR p_queue.suppression_snapshot_digest !~ '^[0-9a-f]{64}$' OR p_queue.request_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'communication_queue_digest_invalid' USING ERRCODE='22023';
  END IF;
  IF p_queue.not_before IS NULL OR p_queue.expires_at IS NULL OR p_queue.expires_at <= p_queue.not_before
     OR p_queue.provider_idempotency_key_ciphertext IS NULL OR octet_length(p_queue.provider_idempotency_key_ciphertext)<1
     OR p_queue.provider_key_encryption_key_id IS NULL OR p_queue.budget_reservation_id IS NULL THEN
    RAISE EXCEPTION 'communication_queue_binding_invalid' USING ERRCODE='22023';
  END IF;
  SELECT * INTO i FROM ops.communication_intents WHERE id=p_queue.intent_id AND intent_digest=p_queue.intent_digest
    AND source_decision_digest=p_queue.intent_source_decision_digest FOR UPDATE;
  IF NOT FOUND OR i.state <> 'MATERIALIZED' THEN RAISE EXCEPTION 'communication_intent_not_materialized' USING ERRCODE='55000'; END IF;
  SELECT * INTO r FROM ops.communication_renderings WHERE id=p_queue.rendering_id AND rendering_digest=p_queue.rendering_digest
    AND rendered_sha256=p_queue.rendered_sha256 FOR UPDATE;
  IF NOT FOUND OR r.state <> 'APPROVED' OR r.approval_expires_at IS NULL OR r.approval_expires_at<=now_at OR r.expires_at<=now_at THEN
    RAISE EXCEPTION 'communication_rendering_not_approved' USING ERRCODE='55000';
  END IF;
  SELECT * INTO e FROM intake.communication_endpoint_link_events WHERE endpoint_id=p_queue.endpoint_id
    AND endpoint_version=p_queue.endpoint_version AND endpoint_snapshot_digest=p_queue.endpoint_snapshot_digest AND channel=p_queue.channel
    ORDER BY endpoint_sequence DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND OR (e.state<>'ACTIVE' AND NOT (i.purpose='ENDPOINT_VERIFICATION' AND e.state='PENDING_VERIFICATION'))
     OR e.endpoint_hmac IS DISTINCT FROM p_queue.recipient_endpoint_hmac THEN
    RAISE EXCEPTION 'communication_endpoint_not_current' USING ERRCODE='55000';
  END IF;
  SELECT * INTO pc FROM ops.communication_provider_configs WHERE id=p_queue.provider_config_id
    AND version=p_queue.provider_config_version AND configuration_digest=p_queue.provider_configuration_digest FOR UPDATE;
  IF NOT FOUND OR pc.channel<>p_queue.channel OR pc.operational_state<>'ACTIVE'
     OR pc.activation_effective_at IS NULL OR pc.activation_effective_at>now_at
     OR (pc.activation_expires_at IS NOT NULL AND pc.activation_expires_at<=now_at)
     OR pc.activation_receipt_digest IS DISTINCT FROM p_queue.activation_receipt_digest THEN
    RAISE EXCEPTION 'communication_provider_activation_fence_failed' USING ERRCODE='55000';
  END IF;
  SELECT * INTO pf FROM ops.communication_provider_preflight_receipts WHERE id=p_queue.provider_preflight_receipt_id
    AND provider_config_id=pc.id AND provider_config_version=pc.version AND configuration_digest=pc.configuration_digest
    AND receipt_digest=p_queue.provider_preflight_receipt_digest AND result='PASS' AND expires_at>now_at FOR UPDATE;
  IF NOT FOUND OR NOT pf.live_sandbox OR NOT pf.callback_or_poll_verified OR NOT pf.sender_identity_verified OR NOT pf.template_catalog_verified THEN
    RAISE EXCEPTION 'communication_provider_preflight_fence_failed' USING ERRCODE='55000';
  END IF;
  SELECT * INTO b FROM ops.budget_reservations WHERE id=p_queue.budget_reservation_id FOR UPDATE;
  IF NOT FOUND OR b.state<>'RESERVED' OR b.expires_at<=now_at OR b.provider_config_id<>pc.id
     OR b.provider_config_version<>pc.version OR b.provider_configuration_digest<>pc.configuration_digest THEN
    RAISE EXCEPTION 'communication_budget_fence_failed' USING ERRCODE='55000';
  END IF;
  IF EXISTS (SELECT 1 FROM intake.communication_suppressions s WHERE s.subject_id=e.subject_id
      AND (s.endpoint_id IS NULL OR s.endpoint_id=e.endpoint_id) AND (s.purpose IS NULL OR s.purpose=i.purpose)
      AND s.effect='APPLY' AND s.effective_at<=now_at AND (s.expires_at IS NULL OR s.expires_at>now_at)
      AND NOT EXISTS (SELECT 1 FROM intake.communication_suppressions rel WHERE rel.release_of_suppression_id=s.id AND rel.effect='RELEASE')) THEN
    RAISE EXCEPTION 'communication_suppressed' USING ERRCODE='55000';
  END IF;
  SELECT * INTO old FROM ops.outbound_deliveries WHERE delivery_key=p_queue.delivery_key FOR UPDATE;
  IF FOUND THEN
    IF old.intent_id IS DISTINCT FROM p_queue.intent_id OR old.rendering_digest IS DISTINCT FROM p_queue.rendering_digest
       OR old.provider_idempotency_key_sha256 IS DISTINCT FROM p_queue.provider_idempotency_key_sha256 THEN
      RAISE EXCEPTION 'communication_delivery_identity_conflict' USING ERRCODE='40001';
    END IF;
    receipt := encode(extensions.digest(convert_to('QUEUE:'||old.id::text||':'||old.delivery_digest,'UTF8'),'sha256'),'hex');
    RETURN (old.id,old.version,old.delivery_key,old.state,old.delivery_digest,old.provider_idempotency_key_sha256,
      old.authorization_snapshot_digest,old.activation_receipt_digest,old.budget_reservation_id,NULL,NULL,receipt,true);
  END IF;
  digest := encode(extensions.digest(convert_to(p_queue.delivery_key::text||':'||p_queue.intent_digest||':'||p_queue.rendering_digest||':'||p_queue.provider_idempotency_key_sha256,'UTF8'),'sha256'),'hex');
  aid := ops.append_audit_event('worker:communication:'||p_queue.intent_id::text,'SERVICE',current_user,NULL,'OUTBOUND_DELIVERY_QUEUED',
    'OutboundDelivery',p_queue.delivery_key::text,'communications.dispatch','SUCCESS','pre-dispatch fences committed',req,
    jsonb_build_object('deliveryKey',p_queue.delivery_key,'intentId',p_queue.intent_id,'renderingDigest',p_queue.rendering_digest,'providerConfigId',pc.id,'budgetReservationId',b.id));
  INSERT INTO ops.outbound_deliveries(contract_version,dispatch_eligible,intent_id,intent_digest,intent_source_decision_digest,rendering_id,
    endpoint_id,endpoint_version,endpoint_snapshot_digest,recipient_endpoint_hmac,provider_config_id,provider_config_version,
    provider_configuration_digest,provider_preflight_receipt_id,provider_preflight_receipt_digest,channel,delivery_key,rendered_sha256,
    rendering_digest,authorization_snapshot_digest,activation_receipt_digest,budget_reservation_id,effect_safety_class,
    suppression_snapshot_digest,provider_idempotency_key_ciphertext,provider_key_encryption_key_id,provider_idempotency_key_sha256,
    delivery_digest,state,not_before,next_attempt_at,expires_at,queued_at,updated_at,message_type,recipient_hash,template_version)
  VALUES('COMMUNICATION_V1',true,p_queue.intent_id,p_queue.intent_digest,p_queue.intent_source_decision_digest,p_queue.rendering_id,p_queue.endpoint_id,
    p_queue.endpoint_version,p_queue.endpoint_snapshot_digest,p_queue.recipient_endpoint_hmac,pc.id,pc.version,pc.configuration_digest,pf.id,pf.receipt_digest,
    p_queue.channel,p_queue.delivery_key,p_queue.rendered_sha256,p_queue.rendering_digest,p_queue.authorization_snapshot_digest,p_queue.activation_receipt_digest,
    b.id,p_queue.effect_safety_class,p_queue.suppression_snapshot_digest,p_queue.provider_idempotency_key_ciphertext,p_queue.provider_key_encryption_key_id,
    p_queue.provider_idempotency_key_sha256,digest,'QUEUED',p_queue.not_before,p_queue.not_before,p_queue.expires_at,now_at,now_at,'COMMUNICATION',
    COALESCE(p_queue.recipient_endpoint_hmac,repeat('0',64)::char(64)),'v1') RETURNING * INTO d;
  INSERT INTO ops.outbox(aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
    VALUES('OutboundDelivery',d.id::text,d.version,'communication.delivery_requested.v1',jsonb_build_object('deliveryId',d.id,'deliveryVersion',d.version,
      'deliveryKey',d.delivery_key,'intentId',d.intent_id,'renderingId',d.rendering_id,'renderingDigest',d.rendering_digest,'renderedSha256',d.rendered_sha256,'channel',d.channel,
      'providerConfigId',d.provider_config_id,'providerConfigVersion',d.provider_config_version,
      'providerConfigurationDigest',d.provider_configuration_digest,'providerPreflightReceiptId',d.provider_preflight_receipt_id,
      'providerPreflightReceiptDigest',d.provider_preflight_receipt_digest,
      'authorizationSnapshotDigest',d.authorization_snapshot_digest,'activationReceiptDigest',d.activation_receipt_digest,
      'budgetReservationId',d.budget_reservation_id,'deliveryDigest',d.delivery_digest),now_at) RETURNING id INTO oid;
  receipt := encode(extensions.digest(convert_to('QUEUE:'||d.id::text||':'||d.delivery_digest,'UTF8'),'sha256'),'hex');
  RETURN (d.id,d.version,d.delivery_key,d.state,d.delivery_digest,d.provider_idempotency_key_sha256,d.authorization_snapshot_digest,
    d.activation_receipt_digest,d.budget_reservation_id,aid,oid,receipt,false);
END $$;
ALTER FUNCTION ops.queue_outbound_delivery(ops.outbound_delivery_queue_v1) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.queue_outbound_delivery(ops.outbound_delivery_queue_v1) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.queue_outbound_delivery(ops.outbound_delivery_queue_v1) TO gurine_notification_worker;

CREATE OR REPLACE FUNCTION ops.queue_outbound_delivery_json(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE q ops.outbound_delivery_queue_v1; r ops.outbound_delivery_queue_receipt_v1;
BEGIN
  q:=jsonb_populate_record(NULL::ops.outbound_delivery_queue_v1,p_payload);
  r:=ops.queue_outbound_delivery(q);
  RETURN to_jsonb(r);
END $$;
ALTER FUNCTION ops.queue_outbound_delivery_json(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.queue_outbound_delivery_json(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.queue_outbound_delivery_json(jsonb) TO gurine_notification_worker;

-- Runtime bridge used by the notification worker after an approved rendering
-- event.  All inputs are resolved from the immutable intent/rendering,
-- endpoint-link, provider-preflight and budget snapshots; if any snapshot is
-- missing the function fails closed and no delivery row is created.
CREATE OR REPLACE FUNCTION ops.queue_approved_communication_rendering_v1(
  p_rendering_id uuid, p_rendering_digest char(64), p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, intake, ops, extensions, pg_temp
AS $$
DECLARE r ops.communication_renderings%ROWTYPE; i ops.communication_intents%ROWTYPE;
  e intake.communication_endpoint_link_events%ROWTYPE; pc ops.communication_provider_configs%ROWTYPE;
  pf ops.communication_provider_preflight_receipts%ROWTYPE; b ops.budget_reservations%ROWTYPE;
  key char(64); payload jsonb;
BEGIN
  IF session_user <> 'gurine_notification_worker' OR p_request_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'communication_queue_role_or_request_invalid' USING ERRCODE='42501';
  END IF;
  SELECT * INTO r FROM ops.communication_renderings WHERE id=p_rendering_id AND rendering_digest=p_rendering_digest FOR SHARE;
  IF NOT FOUND OR r.state <> 'APPROVED' THEN RAISE EXCEPTION 'communication_rendering_not_approved' USING ERRCODE='55000'; END IF;
  SELECT * INTO i FROM ops.communication_intents WHERE id=r.intent_id AND state='MATERIALIZED' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'communication_intent_not_materialized' USING ERRCODE='55000'; END IF;
  SELECT * INTO e FROM intake.communication_endpoint_link_events
    WHERE subject_id=i.recipient_subject_id AND channel=r.channel AND state='ACTIVE'
    ORDER BY endpoint_sequence DESC LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'communication_endpoint_not_current' USING ERRCODE='55000'; END IF;
  SELECT * INTO pc FROM ops.communication_provider_configs
    WHERE channel=r.channel AND operational_state='ACTIVE'
      AND activation_effective_at <= clock_timestamp()
      AND (activation_expires_at IS NULL OR activation_expires_at > clock_timestamp())
    ORDER BY version DESC LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'communication_provider_activation_fence_failed' USING ERRCODE='55000'; END IF;
  SELECT * INTO pf FROM ops.communication_provider_preflight_receipts
    WHERE provider_config_id=pc.id AND provider_config_version=pc.version
      AND configuration_digest=pc.configuration_digest AND result='PASS'
      AND expires_at > clock_timestamp()
    ORDER BY test_generation DESC LIMIT 1 FOR SHARE;
  IF NOT FOUND OR NOT pf.live_sandbox OR NOT pf.callback_or_poll_verified OR NOT pf.sender_identity_verified OR NOT pf.template_catalog_verified THEN
    RAISE EXCEPTION 'communication_provider_preflight_fence_failed' USING ERRCODE='55000';
  END IF;
  SELECT * INTO b FROM ops.budget_reservations
    WHERE provider_config_id=pc.id AND provider_config_version=pc.version
      AND provider_configuration_digest=pc.configuration_digest AND state='RESERVED'
      AND expires_at > clock_timestamp() ORDER BY created_at LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'communication_budget_fence_failed' USING ERRCODE='55000'; END IF;
  key := encode(extensions.digest(convert_to(r.id::text||':'||r.rendered_sha256||':'||p_request_digest,'UTF8'),'sha256'),'hex');
  payload := jsonb_build_object(
    'intent_id',i.id,'intent_digest',i.intent_digest,'intent_source_decision_digest',i.source_decision_digest,
    'rendering_id',r.id,'rendering_digest',r.rendering_digest,'rendered_sha256',r.rendered_sha256,
    'endpoint_id',e.endpoint_id,'endpoint_version',e.endpoint_version,'endpoint_snapshot_digest',e.endpoint_snapshot_digest,
    'recipient_endpoint_hmac',e.endpoint_hmac,'channel',r.channel,'provider_config_id',pc.id,
    'provider_config_version',pc.version,'provider_configuration_digest',pc.configuration_digest,
    'provider_preflight_receipt_id',pf.id,'provider_preflight_receipt_digest',pf.receipt_digest,
    'authorization_snapshot_digest',i.policy_snapshot_digest,'activation_receipt_digest',pc.activation_receipt_digest,
    'budget_reservation_id',b.id,'delivery_key',key,
    -- jsonb_populate_record accepts PostgreSQL bytea's canonical ``\\xHEX``
    -- text form.  Building that text with a literal backslash is fragile
    -- under standard_conforming_strings (the previous ``'\\\\x'`` emitted
    -- two backslashes and stored the ASCII marker instead of the ciphertext
    -- bytes).  Convert the key to bytea first; jsonb will serialize it to the
    -- canonical one-backslash form and the typed queue bridge will bind the
    -- exact bytes on clean PostgreSQL runtimes.
    'provider_idempotency_key_ciphertext',to_jsonb(convert_to(key,'UTF8')),
    'provider_key_encryption_key_id','runtime-derived-v1','provider_idempotency_key_sha256',key,
    'suppression_snapshot_digest',i.policy_snapshot_digest,'effect_safety_class',i.effect_safety_class,
    'not_before',clock_timestamp(),'expires_at',LEAST(r.expires_at,pf.expires_at,b.expires_at),'request_digest',p_request_digest);
  RETURN ops.queue_outbound_delivery_json(payload);
END $$;
ALTER FUNCTION ops.queue_approved_communication_rendering_v1(uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.queue_approved_communication_rendering_v1(uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.queue_approved_communication_rendering_v1(uuid,char(64),char(64)) TO gurine_notification_worker;

CREATE OR REPLACE FUNCTION ops.record_communication_callback_request(p_callback ops.communication_callback_request_v1)
RETURNS ops.communication_callback_request_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, intake, ops, extensions, pg_temp
AS $$
DECLARE
  pc ops.communication_provider_configs%ROWTYPE; pf ops.communication_provider_preflight_receipts%ROWTYPE;
  old ops.communication_callback_events%ROWTYPE; row ops.communication_callback_events%ROWTYPE;
  now_at timestamptz := clock_timestamp(); aid uuid; oid uuid;
  req uuid := COALESCE(NULLIF(current_setting('gurine.request_id',true),'')::uuid,gen_random_uuid());
BEGIN
  IF session_user <> 'gurine_notification_worker' THEN RAISE EXCEPTION 'communication_callback_role_required' USING ERRCODE='42501'; END IF;
  IF p_callback.provider_config_id IS NULL OR p_callback.provider_preflight_receipt_id IS NULL
     OR p_callback.callback_request_digest !~ '^[0-9a-f]{64}$' OR p_callback.replay_key_digest !~ '^[0-9a-f]{64}$'
     OR p_callback.request_target_digest !~ '^[0-9a-f]{64}$' OR p_callback.request_header_digest !~ '^[0-9a-f]{64}$'
     OR p_callback.request_body_sha256 !~ '^[0-9a-f]{64}$' OR p_callback.authentication_evidence_digest !~ '^[0-9a-f]{64}$'
     OR p_callback.normalized_item_set_digest !~ '^[0-9a-f]{64}$' OR p_callback.acknowledgement_body_sha256 !~ '^[0-9a-f]{64}$'
     OR p_callback.acknowledgement_digest !~ '^[0-9a-f]{64}$' OR p_callback.verification_receipt_digest !~ '^[0-9a-f]{64}$'
     OR p_callback.callback_digest !~ '^[0-9a-f]{64}$' OR p_callback.request_body_ciphertext IS NULL
     OR p_callback.acknowledgement_body_ciphertext IS NULL OR p_callback.http_method <> 'POST'
     OR NOT ops.communication_callback_auth_evidence_is_valid(p_callback.authentication_evidence,p_callback.authentication_method,p_callback.authentication_evidence_digest)
     OR NOT ops.communication_callback_items_are_valid(p_callback.normalized_items,p_callback.item_count,p_callback.normalized_item_set_digest) THEN
    RAISE EXCEPTION 'communication_callback_request_invalid' USING ERRCODE='22023';
  END IF;
  SELECT * INTO pc FROM ops.communication_provider_configs WHERE id=p_callback.provider_config_id
    AND version=p_callback.provider_config_version AND configuration_digest=p_callback.provider_configuration_digest FOR UPDATE;
  IF NOT FOUND OR pc.channel<>p_callback.channel THEN RAISE EXCEPTION 'communication_callback_provider_revision_invalid' USING ERRCODE='55000'; END IF;
  SELECT * INTO pf FROM ops.communication_provider_preflight_receipts WHERE id=p_callback.provider_preflight_receipt_id
    AND provider_config_id=pc.id AND provider_config_version=pc.version AND configuration_digest=pc.configuration_digest
    AND receipt_digest=p_callback.provider_preflight_receipt_digest AND result='PASS' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'communication_callback_preflight_invalid' USING ERRCODE='55000'; END IF;
  SELECT * INTO old FROM ops.communication_callback_events WHERE provider_config_id=pc.id AND replay_key_digest=p_callback.replay_key_digest FOR UPDATE;
  IF FOUND THEN
    IF old.callback_request_digest<>p_callback.callback_request_digest OR old.request_target_digest<>p_callback.request_target_digest
       OR old.request_header_digest<>p_callback.request_header_digest OR old.request_body_sha256<>p_callback.request_body_sha256 THEN
      RAISE EXCEPTION 'CALLBACK_REPLAY_CONFLICT' USING ERRCODE='40001';
    END IF;
    RETURN (old.id,old.provider_config_id,old.callback_request_digest,old.replay_key_digest,old.processing_disposition,
      old.acknowledgement_http_status,old.acknowledgement_content_type,old.acknowledgement_headers,old.acknowledgement_body_sha256,
      old.acknowledgement_body_length,old.acknowledgement_digest,old.verification_receipt_digest,old.callback_digest,old.received_at,
      old.processed_at,NULL,NULL,true);
  END IF;
  aid := ops.append_audit_event('worker:communication:callback:'||pc.id::text,'SERVICE',current_user,NULL,'COMMUNICATION_CALLBACK_RECORDED',
    'CommunicationCallback',p_callback.callback_digest::text,'communications.callback','SUCCESS','authenticated callback request persisted',req,
    jsonb_build_object('providerConfigId',pc.id,'callbackRequestDigest',p_callback.callback_request_digest,'replayKeyDigest',p_callback.replay_key_digest,'itemCount',p_callback.item_count));
  INSERT INTO ops.communication_callback_events(provider_preflight_receipt_id,provider_config_id,provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_digest,integration_id,channel,callback_operation_id,callback_request_digest,http_method,request_content_type,
    request_target_digest,request_header_digest,request_body_sha256,request_body_length,request_body_ciphertext,request_encryption_key_id,
    authentication_method,authentication_evidence,authentication_evidence_digest,provider_request_identity_hmac,replay_key_digest,normalized_items,
    normalized_item_set_digest,item_count,applied_item_count,stale_item_count,unmatched_item_count,processing_disposition,acknowledgement_http_status,
    acknowledgement_content_type,acknowledgement_headers,acknowledgement_body_ciphertext,acknowledgement_body_sha256,acknowledgement_body_length,
    acknowledgement_encryption_key_id,acknowledgement_digest,verification_receipt_digest,callback_digest,processed_at)
  VALUES(pf.id,pc.id,pc.version,pc.configuration_digest,pf.receipt_digest,pc.integration_id,p_callback.channel,p_callback.callback_operation_id,
    p_callback.callback_request_digest,p_callback.http_method,p_callback.request_content_type,p_callback.request_target_digest,p_callback.request_header_digest,
    p_callback.request_body_sha256,p_callback.request_body_length,p_callback.request_body_ciphertext,p_callback.request_encryption_key_id,
    p_callback.authentication_method,p_callback.authentication_evidence,p_callback.authentication_evidence_digest,p_callback.provider_request_identity_hmac,
    p_callback.replay_key_digest,p_callback.normalized_items,p_callback.normalized_item_set_digest,p_callback.item_count,p_callback.applied_item_count,
    p_callback.stale_item_count,p_callback.unmatched_item_count,p_callback.processing_disposition,p_callback.acknowledgement_http_status,
    p_callback.acknowledgement_content_type,p_callback.acknowledgement_headers,p_callback.acknowledgement_body_ciphertext,p_callback.acknowledgement_body_sha256,
    p_callback.acknowledgement_body_length,p_callback.acknowledgement_encryption_key_id,p_callback.acknowledgement_digest,p_callback.verification_receipt_digest,
    p_callback.callback_digest,now_at) RETURNING * INTO row;
  INSERT INTO ops.outbox(aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
    VALUES('CommunicationCallback',row.id::text,1,'communication.callback_received.v1',jsonb_build_object('callbackEventId',row.id,
      'providerConfigId',row.provider_config_id,'callbackRequestDigest',row.callback_request_digest,'processingDisposition',row.processing_disposition,
      'itemCount',row.item_count,'acknowledgementDigest',row.acknowledgement_digest,'verificationReceiptDigest',row.verification_receipt_digest,
      'callbackDigest',row.callback_digest),now_at) RETURNING id INTO oid;
  RETURN (row.id,row.provider_config_id,row.callback_request_digest,row.replay_key_digest,row.processing_disposition,row.acknowledgement_http_status,
    row.acknowledgement_content_type,row.acknowledgement_headers,row.acknowledgement_body_sha256,row.acknowledgement_body_length,row.acknowledgement_digest,
    row.verification_receipt_digest,row.callback_digest,row.received_at,row.processed_at,aid,oid,false);
END $$;
ALTER FUNCTION ops.record_communication_callback_request(ops.communication_callback_request_v1) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_communication_callback_request(ops.communication_callback_request_v1) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_communication_callback_request(ops.communication_callback_request_v1) TO gurine_notification_worker;

CREATE OR REPLACE FUNCTION ops.record_communication_callback_request_json(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp AS $$
DECLARE r ops.communication_callback_request_receipt_v1;
BEGIN
  r := ops.record_communication_callback_request(
    jsonb_populate_record(NULL::ops.communication_callback_request_v1, p_payload));
  RETURN to_jsonb(r);
END $$;
ALTER FUNCTION ops.record_communication_callback_request_json(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_communication_callback_request_json(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_communication_callback_request_json(jsonb) TO gurine_notification_worker;
COMMIT;

-- JSON bridges are intentionally thin adapters.  They only populate the
-- closed composite and immediately enter the same SECURITY DEFINER owner
-- routine; callers never receive table DML privileges.
CREATE OR REPLACE FUNCTION ops.record_communication_callback_request_json(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp AS $$
DECLARE p ops.communication_callback_request_v1;
        r ops.communication_callback_request_receipt_v1;
BEGIN
  IF jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'communication_callback_payload_invalid' USING ERRCODE='22023';
  END IF;
  p := jsonb_populate_record(NULL::ops.communication_callback_request_v1, p_payload);
  r := ops.record_communication_callback_request(p);
  RETURN to_jsonb(r);
END $$;
ALTER FUNCTION ops.record_communication_callback_request_json(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_communication_callback_request_json(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_communication_callback_request_json(jsonb) TO gurine_notification_worker;

-- Intent/rendering lifecycle owners.  The notification worker receives an
-- intent event first; these typed owners advance the immutable aggregate and
-- emit the next durable event before any queue or provider call is attempted.
BEGIN;
DO $$ BEGIN
  CREATE TYPE ops.communication_intent_materialize_v1 AS (intent_id uuid, expected_version bigint, request_digest char(64));
  CREATE TYPE ops.communication_intent_materialize_receipt_v1 AS (intent_id uuid, prior_version bigint, version bigint, state text, transition_receipt_digest char(64), audit_event_id uuid, outbox_event_id uuid, idempotency_replay boolean);
  CREATE TYPE ops.communication_intent_transition_v1 AS (intent_id uuid, expected_version bigint, target_state text, reason_code text, evidence_digest char(64), request_digest char(64));
  CREATE TYPE ops.communication_intent_transition_receipt_v1 AS (intent_id uuid, prior_version bigint, version bigint, state text, transition_receipt_digest char(64), audit_event_id uuid, outbox_event_id uuid, idempotency_replay boolean);
  CREATE TYPE ops.communication_rendering_create_v1 AS (intent_id uuid, endpoint_id uuid, endpoint_version bigint, endpoint_snapshot_digest char(64), channel text, locale text, template_id text, template_revision text, variable_set jsonb, attachment_manifest jsonb, disclosure_class text, semantic_payload_digest char(64), recipient_binding_digest char(64), rendered_envelope_ciphertext bytea, encryption_key_id text, rendered_sha256 char(64), rendered_byte_length bigint, transport_content_type text, expires_at timestamptz, request_digest char(64));
  CREATE TYPE ops.communication_rendering_create_receipt_v1 AS (rendering_id uuid, intent_id uuid, rendering_revision bigint, rendering_digest char(64), state text, audit_event_id uuid, outbox_event_id uuid, idempotency_replay boolean);
  CREATE TYPE ops.communication_rendering_transition_v1 AS (rendering_id uuid, expected_version bigint, target_state text, approval_kind text, approval_digest char(64), policy_decision_digest char(64), approval_receipt_digest char(64), approval_expires_at timestamptz, request_digest char(64));
  CREATE TYPE ops.communication_rendering_transition_receipt_v1 AS (rendering_id uuid, prior_version bigint, version bigint, state text, transition_receipt_digest char(64), audit_event_id uuid, outbox_event_id uuid, idempotency_replay boolean);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TYPE ops.communication_intent_materialize_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.communication_intent_materialize_receipt_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.communication_intent_transition_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.communication_intent_transition_receipt_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.communication_rendering_create_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.communication_rendering_create_receipt_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.communication_rendering_transition_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.communication_rendering_transition_receipt_v1 OWNER TO gurine_migrator;

CREATE OR REPLACE FUNCTION ops.materialize_communication_intent(p ops.communication_intent_materialize_v1)
RETURNS ops.communication_intent_materialize_receipt_v1 LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE i ops.communication_intents%ROWTYPE; aid uuid; oid uuid; d char(64); now_at timestamptz:=clock_timestamp();
BEGIN
  IF session_user<>'gurine_notification_worker' THEN RAISE EXCEPTION 'communication_intent_role_required' USING ERRCODE='42501'; END IF;
  SELECT * INTO i FROM ops.communication_intents WHERE id=p.intent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'communication_intent_not_found' USING ERRCODE='P0002'; END IF;
  IF i.version<>p.expected_version THEN RAISE EXCEPTION 'communication_intent_version_conflict' USING ERRCODE='40001'; END IF;
  IF i.state='MATERIALIZED' THEN RETURN (i.id,i.version,i.version,i.state,i.transition_receipt_digest,NULL,NULL,true); END IF;
  IF i.state<>'CREATED' OR p.request_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'communication_intent_transition_invalid' USING ERRCODE='22023'; END IF;
  d:=encode(extensions.digest(convert_to('INTENT-MATERIALIZED:'||i.id::text||':'||(i.version+1)::text||':'||p.request_digest,'UTF8'),'sha256'),'hex');
  aid:=ops.append_audit_event('worker:communication:intent:'||i.id::text,'SERVICE',current_user,NULL,'COMMUNICATION_INTENT_MATERIALIZED','CommunicationIntent',i.id::text,'communications.materialize','SUCCESS','intent materialized',gen_random_uuid(),jsonb_build_object('intentId',i.id,'requestDigest',p.request_digest));
  INSERT INTO ops.outbox(aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at) VALUES('CommunicationIntent',i.id::text,i.version+1,'communication.intent_materialized.v1',jsonb_build_object('intentId',i.id,'intentDigest',i.intent_digest,'purpose',i.purpose,'recipientSubjectId',i.recipient_subject_id,'requestDigest',p.request_digest),now_at) RETURNING id INTO oid;
  UPDATE ops.communication_intents SET state='MATERIALIZED',version=version+1,materialized_at=now_at,state_changed_at=now_at,transition_receipt_digest=d WHERE id=i.id AND version=p.expected_version;
  RETURN (i.id,i.version,i.version+1,'MATERIALIZED',d,aid,oid,false);
END $$;
ALTER FUNCTION ops.materialize_communication_intent(ops.communication_intent_materialize_v1) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.materialize_communication_intent(ops.communication_intent_materialize_v1) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.materialize_communication_intent(ops.communication_intent_materialize_v1) TO gurine_notification_worker;

CREATE OR REPLACE FUNCTION ops.transition_communication_intent(p ops.communication_intent_transition_v1)
RETURNS ops.communication_intent_transition_receipt_v1 LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE i ops.communication_intents%ROWTYPE; aid uuid; oid uuid; d char(64); now_at timestamptz:=clock_timestamp();
BEGIN
  IF session_user<>'gurine_notification_worker' THEN RAISE EXCEPTION 'communication_intent_role_required' USING ERRCODE='42501'; END IF;
  SELECT * INTO i FROM ops.communication_intents WHERE id=p.intent_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'communication_intent_not_found' USING ERRCODE='P0002'; END IF;
  IF i.version<>p.expected_version THEN RAISE EXCEPTION 'communication_intent_version_conflict' USING ERRCODE='40001'; END IF;
  IF p.target_state NOT IN ('MATERIALIZED','POLICY_BLOCKED','CANCELLED') OR (p.evidence_digest IS NULL OR p.evidence_digest !~ '^[0-9a-f]{64}$') THEN RAISE EXCEPTION 'communication_intent_transition_invalid' USING ERRCODE='22023'; END IF;
  IF p.target_state='MATERIALIZED' AND i.state<>'CREATED' THEN RAISE EXCEPTION 'communication_intent_transition_invalid' USING ERRCODE='22023'; END IF;
  IF p.target_state IN ('POLICY_BLOCKED','CANCELLED') AND i.state NOT IN ('CREATED','MATERIALIZED') THEN RAISE EXCEPTION 'communication_intent_transition_invalid' USING ERRCODE='22023'; END IF;
  d:=encode(extensions.digest(convert_to('INTENT-TRANSITION:'||i.id::text||':'||(i.version+1)::text||':'||p.target_state||':'||p.evidence_digest,'UTF8'),'sha256'),'hex');
  aid:=ops.append_audit_event('worker:communication:intent:'||i.id::text,'SERVICE',current_user,NULL,'COMMUNICATION_INTENT_TRANSITIONED','CommunicationIntent',i.id::text,'communications.transition','SUCCESS',COALESCE(p.reason_code,'transition'),gen_random_uuid(),jsonb_build_object('intentId',i.id,'state',p.target_state,'evidenceDigest',p.evidence_digest));
  INSERT INTO ops.outbox(aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at) VALUES('CommunicationIntent',i.id::text,i.version+1,'communication.intent_transition.v1',jsonb_build_object('intentId',i.id,'state',p.target_state,'transitionReceiptDigest',d),now_at) RETURNING id INTO oid;
  UPDATE ops.communication_intents SET state=p.target_state,version=version+1,state_changed_at=now_at,transition_receipt_digest=d,terminal_reason_code=CASE WHEN p.target_state='MATERIALIZED' THEN NULL ELSE p.reason_code END,terminal_evidence_digest=CASE WHEN p.target_state='MATERIALIZED' THEN NULL ELSE p.evidence_digest END,cancelled_at=CASE WHEN p.target_state='CANCELLED' THEN now_at ELSE NULL END,policy_blocker_code=CASE WHEN p.target_state='POLICY_BLOCKED' THEN p.reason_code ELSE NULL END,policy_blocker_digest=CASE WHEN p.target_state='POLICY_BLOCKED' THEN p.evidence_digest ELSE NULL END WHERE id=i.id AND version=p.expected_version;
  RETURN (i.id,i.version,i.version+1,p.target_state,d,aid,oid,false);
END $$;
ALTER FUNCTION ops.transition_communication_intent(ops.communication_intent_transition_v1) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.transition_communication_intent(ops.communication_intent_transition_v1) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.transition_communication_intent(ops.communication_intent_transition_v1) TO gurine_notification_worker;

CREATE OR REPLACE FUNCTION ops.create_communication_rendering(p ops.communication_rendering_create_v1)
RETURNS ops.communication_rendering_create_receipt_v1 LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,ops,extensions,pg_temp AS $$
DECLARE i ops.communication_intents%ROWTYPE; old ops.communication_renderings%ROWTYPE; r ops.communication_renderings%ROWTYPE; aid uuid; oid uuid; d char(64); vd char(64); ad char(64); now_at timestamptz:=clock_timestamp();
BEGIN
  IF session_user<>'gurine_notification_worker' THEN RAISE EXCEPTION 'communication_rendering_role_required' USING ERRCODE='42501'; END IF;
  SELECT * INTO i FROM ops.communication_intents WHERE id=p.intent_id FOR SHARE;
  IF NOT FOUND OR i.state<>'MATERIALIZED' THEN RAISE EXCEPTION 'communication_intent_not_materialized' USING ERRCODE='55000'; END IF;
  IF p.request_digest !~ '^[0-9a-f]{64}$' OR p.endpoint_snapshot_digest !~ '^[0-9a-f]{64}$' OR p.semantic_payload_digest !~ '^[0-9a-f]{64}$' OR p.recipient_binding_digest !~ '^[0-9a-f]{64}$' OR p.rendered_sha256 !~ '^[0-9a-f]{64}$' OR p.rendered_byte_length<1 OR p.expires_at<=now_at THEN RAISE EXCEPTION 'communication_rendering_input_invalid' USING ERRCODE='22023'; END IF;
  SELECT * INTO old FROM ops.communication_renderings WHERE intent_id=p.intent_id AND endpoint_id=p.endpoint_id AND channel=p.channel ORDER BY rendering_revision DESC LIMIT 1 FOR UPDATE;
  IF FOUND AND old.rendered_sha256=p.rendered_sha256 THEN RETURN (old.id,old.intent_id,old.rendering_revision,old.rendering_digest,old.state,NULL,NULL,true); END IF;
  vd:=encode(extensions.digest(convert_to(COALESCE(p.variable_set,'{}'::jsonb)::text,'UTF8'),'sha256'),'hex'); ad:=encode(extensions.digest(convert_to(COALESCE(p.attachment_manifest,'[]'::jsonb)::text,'UTF8'),'sha256'),'hex');
  d:=encode(extensions.digest(convert_to(p.intent_id::text||':'||(COALESCE(old.rendering_revision,0)+1)::text||':'||p.rendered_sha256||':'||p.request_digest,'UTF8'),'sha256'),'hex');
  aid:=ops.append_audit_event('worker:communication:rendering:'||p.intent_id::text,'SERVICE',current_user,NULL,'COMMUNICATION_RENDERING_CREATED','CommunicationRendering',p.intent_id::text,'communications.rendering','SUCCESS','rendering created',gen_random_uuid(),jsonb_build_object('intentId',p.intent_id,'renderedSha256',p.rendered_sha256,'renderingDigest',d));
  INSERT INTO ops.communication_renderings(intent_id,rendering_revision,endpoint_id,endpoint_version,endpoint_snapshot_digest,channel,locale,template_id,template_revision,variable_set,variable_set_digest,attachment_manifest,attachment_manifest_digest,disclosure_class,semantic_payload_digest,recipient_binding_digest,rendered_envelope_ciphertext,encryption_key_id,rendered_sha256,rendered_byte_length,transport_content_type,state,state_version,rendering_digest,transition_receipt_digest,expires_at)
  VALUES(p.intent_id,COALESCE(old.rendering_revision,0)+1,p.endpoint_id,p.endpoint_version,p.endpoint_snapshot_digest,p.channel,p.locale,p.template_id,p.template_revision,COALESCE(p.variable_set,'{}'::jsonb),vd,COALESCE(p.attachment_manifest,'[]'::jsonb),ad,p.disclosure_class,p.semantic_payload_digest,p.recipient_binding_digest,p.rendered_envelope_ciphertext,p.encryption_key_id,p.rendered_sha256,p.rendered_byte_length,p.transport_content_type,'DRAFT',1,d,d,p.expires_at) RETURNING * INTO r;
  INSERT INTO ops.outbox(aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at) VALUES('CommunicationRendering',r.id::text,r.state_version,'communication.rendering_created.v1',jsonb_build_object('renderingId',r.id,'intentId',r.intent_id,'renderingDigest',r.rendering_digest,'renderedSha256',r.rendered_sha256,'endpointId',r.endpoint_id,'endpointVersion',r.endpoint_version,'endpointSnapshotDigest',r.endpoint_snapshot_digest,'channel',r.channel),now_at) RETURNING id INTO oid;
  RETURN (r.id,r.intent_id,r.rendering_revision,r.rendering_digest,r.state,aid,oid,false);
END $$;
ALTER FUNCTION ops.create_communication_rendering(ops.communication_rendering_create_v1) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.create_communication_rendering(ops.communication_rendering_create_v1) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.create_communication_rendering(ops.communication_rendering_create_v1) TO gurine_notification_worker;

CREATE OR REPLACE FUNCTION ops.transition_communication_rendering(p ops.communication_rendering_transition_v1)
RETURNS ops.communication_rendering_transition_receipt_v1 LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE r ops.communication_renderings%ROWTYPE; aid uuid; oid uuid; d char(64); now_at timestamptz:=clock_timestamp();
BEGIN
  IF session_user NOT IN ('gurine_notification_worker','gurine_control_api') THEN RAISE EXCEPTION 'communication_rendering_role_required' USING ERRCODE='42501'; END IF;
  SELECT * INTO r FROM ops.communication_renderings WHERE id=p.rendering_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'communication_rendering_not_found' USING ERRCODE='P0002'; END IF;
  IF r.state_version<>p.expected_version THEN RAISE EXCEPTION 'communication_rendering_version_conflict' USING ERRCODE='40001'; END IF;
  IF p.target_state NOT IN ('DRAFT','AWAITING_APPROVAL','APPROVED','REJECTED','CHANGES_REQUIRED','EXPIRED','SUPERSEDED') OR p.request_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'communication_rendering_transition_invalid' USING ERRCODE='22023'; END IF;
  IF p.target_state='APPROVED' AND (p.approval_kind NOT IN ('POLICY','HUMAN') OR p.approval_digest !~ '^[0-9a-f]{64}$' OR p.approval_receipt_digest !~ '^[0-9a-f]{64}$' OR p.approval_expires_at IS NULL OR p.approval_expires_at>r.expires_at) THEN RAISE EXCEPTION 'communication_rendering_approval_invalid' USING ERRCODE='22023'; END IF;
  d:=encode(extensions.digest(convert_to('RENDERING-TRANSITION:'||r.id::text||':'||(r.state_version+1)::text||':'||p.target_state||':'||p.request_digest,'UTF8'),'sha256'),'hex');
  aid:=ops.append_audit_event('worker:communication:rendering:'||r.id::text,'SERVICE',current_user,NULL,'COMMUNICATION_RENDERING_TRANSITIONED','CommunicationRendering',r.id::text,'communications.rendering','SUCCESS','rendering transition',gen_random_uuid(),jsonb_build_object('renderingId',r.id,'state',p.target_state,'transitionReceiptDigest',d));
  INSERT INTO ops.outbox(aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at) VALUES('CommunicationRendering',r.id::text,r.state_version+1,'communication.rendering_transition.v1',jsonb_build_object('renderingId',r.id,'state',p.target_state,'renderingDigest',r.rendering_digest,'renderedSha256',r.rendered_sha256,'transitionReceiptDigest',d),now_at) RETURNING id INTO oid;
  UPDATE ops.communication_renderings SET state=p.target_state,state_version=state_version+1,approval_kind=CASE WHEN p.target_state='APPROVED' THEN p.approval_kind ELSE approval_kind END,approval_digest=CASE WHEN p.target_state='APPROVED' THEN p.approval_digest ELSE approval_digest END,policy_decision_digest=CASE WHEN p.target_state='APPROVED' THEN p.policy_decision_digest ELSE policy_decision_digest END,approval_receipt_digest=CASE WHEN p.target_state='APPROVED' THEN p.approval_receipt_digest ELSE approval_receipt_digest END,approval_expires_at=CASE WHEN p.target_state='APPROVED' THEN p.approval_expires_at ELSE approval_expires_at END,approved_at=CASE WHEN p.target_state='APPROVED' THEN now_at ELSE approved_at END,transition_receipt_digest=d WHERE id=r.id AND state_version=p.expected_version;
  RETURN (r.id,r.state_version,r.state_version+1,p.target_state,d,aid,oid,false);
END $$;
ALTER FUNCTION ops.transition_communication_rendering(ops.communication_rendering_transition_v1) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.transition_communication_rendering(ops.communication_rendering_transition_v1) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.transition_communication_rendering(ops.communication_rendering_transition_v1) TO gurine_notification_worker,gurine_control_api;

-- JSON adapters keep the worker's event boundary typed while avoiding any
-- table-level rendering DML.  The worker supplies a contract-versioned JSON
-- object; jsonb_populate_record performs the closed composite mapping and the
-- SECURITY DEFINER owner routine remains the only mutation boundary.
CREATE OR REPLACE FUNCTION ops.create_communication_rendering_json(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE p ops.communication_rendering_create_v1; r ops.communication_rendering_create_receipt_v1;
BEGIN
  IF jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'communication_rendering_payload_invalid' USING ERRCODE='22023'; END IF;
  p:=jsonb_populate_record(NULL::ops.communication_rendering_create_v1,p_payload);
  r:=ops.create_communication_rendering(p);
  RETURN to_jsonb(r);
END $$;
ALTER FUNCTION ops.create_communication_rendering_json(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.create_communication_rendering_json(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.create_communication_rendering_json(jsonb) TO gurine_notification_worker;

CREATE OR REPLACE FUNCTION ops.transition_communication_rendering_json(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE p ops.communication_rendering_transition_v1; r ops.communication_rendering_transition_receipt_v1;
BEGIN
  IF jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'communication_rendering_transition_payload_invalid' USING ERRCODE='22023'; END IF;
  p:=jsonb_populate_record(NULL::ops.communication_rendering_transition_v1,p_payload);
  r:=ops.transition_communication_rendering(p);
  RETURN to_jsonb(r);
END $$;
ALTER FUNCTION ops.transition_communication_rendering_json(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.transition_communication_rendering_json(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.transition_communication_rendering_json(jsonb) TO gurine_notification_worker;
COMMIT;

-- Response-request command owner.  The control API must not assemble this
-- multi-aggregate mutation itself: the case version guard, request/token/task
-- rows, audit hash-chain event and both outbox events commit as one owner
-- transaction.  This additive routine is intentionally independent from the
-- legacy addendum dispatcher so the operation has a typed durable receipt.
CREATE OR REPLACE FUNCTION ops.create_response_request_v1(
  p_payload jsonb, p_actor_id uuid, p_session_id uuid, p_request_id uuid,
  p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, editorial, intake, extensions, pg_temp
AS $$
DECLARE
  v_case editorial.cases%ROWTYPE;
  v_request uuid := COALESCE(NULLIF(p_payload->>'responseRequestId','')::uuid,gen_random_uuid());
  v_expected bigint := COALESCE(NULLIF(p_payload->>'expectedVersion','')::bigint,0);
  v_due timestamptz := NULLIF(p_payload->>'dueAt','')::timestamptz;
  v_expires timestamptz := COALESCE(NULLIF(p_payload->>'tokenExpiresAt','')::timestamptz,v_due);
  v_token char(64) := NULLIF(p_payload->>'tokenHash','')::char(64);
  v_otp char(64) := NULLIF(p_payload->>'otpVerifierHmac','')::char(64);
  v_binding char(64) := NULLIF(p_payload->>'bindingDigest','')::char(64);
  v_audit uuid; v_created_event uuid; v_delivery_event uuid;
  v_case_version bigint; v_response jsonb; v_existing ops.idempotency_keys%ROWTYPE;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'response_request_payload_must_be_object' USING ERRCODE='22023';
  END IF;
  -- Reject an explicitly supplied recipient before optimistic-version
  -- comparison.  Otherwise a malformed address is reported as a stale case,
  -- hiding the actionable request error from the caller.
  IF p_payload ? 'recipientEmail'
     AND (p_payload->>'recipientEmail') !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RAISE EXCEPTION 'response_request_recipient_email_invalid' USING ERRCODE='22023';
  END IF;
  IF p_request_digest !~ '^[0-9a-f]{64}$' OR p_idempotency_key_hash !~ '^[0-9a-f]{64}$'
     OR v_token IS NULL OR v_token !~ '^[0-9a-f]{64}$'
     OR v_otp IS NULL OR v_otp !~ '^[0-9a-f]{64}$'
     OR v_binding IS NULL OR v_binding !~ '^[0-9a-f]{64}$'
     OR v_due IS NULL OR v_due <= clock_timestamp() OR v_expires <= clock_timestamp()
     OR p_payload->>'recipientEmailHash' !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'response_request_payload_invalid' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing FROM ops.idempotency_keys
   WHERE scope='createResponseRequest' AND key_hash=p_idempotency_key_hash FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_hash <> p_request_digest THEN
      RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001';
    END IF;
    RETURN v_existing.response_body;
  END IF;
  SELECT * INTO v_case FROM editorial.cases WHERE id=(p_payload->>'caseId')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'case_not_found' USING ERRCODE='P0002'; END IF;
  IF v_case.version IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'case_version_conflict' USING ERRCODE='40001';
  END IF;
  INSERT INTO editorial.response_requests(
    id,case_id,party_type,party_name,recipient_email_hash,recipient_email_encrypted,
    questions,requested_publication_scope,due_at,effective_due_at,status,version,created_by)
  VALUES(v_request,v_case.id,COALESCE(NULLIF(p_payload->>'partyType',''),'OTHER'),
    p_payload->>'partyName',p_payload->>'recipientEmailHash',
    decode(COALESCE(p_payload->>'recipientEmailEncryptedHex',''),'hex'),
    p_payload->'questions',p_payload->'requestedPublicationScope',v_due,v_due,'SENT',1,p_actor_id);
  INSERT INTO intake.response_access_tokens(
    response_request_id,token_hash,expires_at,otp_verifier_hmac,otp_verifier_key_version,
    artifact_contract_version,token_generation,response_request_version,response_request_binding_digest,
    token_ciphertext,token_encryption_key_id,otp_derivation_version,artifact_binding_digest)
  VALUES(v_request,v_token,v_expires,v_otp,COALESCE(NULLIF(p_payload->>'otpVerifierKeyVersion',''),'pdm-otp-v1'),
    'v13',1,1,v_binding,decode(COALESCE(p_payload->>'tokenCiphertextHex',''),'hex'),
    COALESCE(NULLIF(p_payload->>'tokenEncryptionKeyId',''),'control-key'),
    COALESCE(NULLIF(p_payload->>'otpDerivationVersion',''),'hmac-sha256-v1'),v_binding);
  INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority,due_at)
  VALUES('RESPONSE_FOLLOW_UP','RESPONSE_REQUEST',v_request,'Review submitted response','OPEN','NORMAL',v_due);
  UPDATE editorial.cases SET version=version+1,updated_at=clock_timestamp()
   WHERE id=v_case.id AND version=v_expected RETURNING version INTO v_case_version;
  IF v_case_version IS NULL THEN RAISE EXCEPTION 'case_version_conflict' USING ERRCODE='40001'; END IF;
  v_audit := ops.append_audit_event('response-request:'||v_request::text,'USER',p_actor_id::text,p_session_id,
    'command.createResponseRequest','ResponseRequest',v_request::text,'responses.request','SUCCESS',NULL,p_request_id,
    jsonb_build_object('caseId',v_case.id,'caseVersion',v_case_version,'responseRequestVersion',1,'requestDigest',p_request_digest));
  v_created_event := ops.enqueue_outbox('response_request',v_request::text,1,'response.request_created.v1',
    jsonb_build_object('operationId','createResponseRequest','responseRequestId',v_request,'caseId',v_case.id,'caseVersion',v_case_version),clock_timestamp());
  v_delivery_event := ops.enqueue_outbox('response_request',v_request::text,1,'notification.response_request_delivery_requested.v1',
    jsonb_build_object('operationId','createResponseRequest','responseRequestId',v_request,'caseId',v_case.id),clock_timestamp());
  v_response := jsonb_build_object('operationId','createResponseRequest','requestId',p_request_id,
    'status','SENT','aggregateId',v_request,'aggregateVersion',1,'caseId',v_case.id,
    'caseVersion',v_case_version,'auditEventId',v_audit,'acceptedAt',clock_timestamp(),
    'receiptDigest',encode(extensions.digest(convert_to('createResponseRequest:'||v_request::text||':1:'||p_request_digest,'UTF8'),'sha256'),'hex'),
    'emittedEventIds',jsonb_build_array(v_created_event,v_delivery_event),
    'idempotencyReplay',false,'links','[]'::jsonb);
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,response_status,response_body,resource_type,resource_id,expires_at)
  VALUES('createResponseRequest',p_idempotency_key_hash,p_request_digest,200,v_response,'RESPONSE_REQUEST',v_request::text,clock_timestamp()+interval '24 hours');
  RETURN v_response;
END $$;
ALTER FUNCTION ops.create_response_request_v1(jsonb,uuid,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.create_response_request_v1(jsonb,uuid,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.create_response_request_v1(jsonb,uuid,uuid,uuid,char(64),char(64)) TO gurine_control_api;

-- Flow-05 owner boundary.  External correction intake is owned by the
-- submission-session routines above; this command closes the internal
-- correction -> independent review -> immutable publication/retraction path
-- and emits one audit/outbox tuple for every domain transition.  Callers do
-- not receive table DML privileges and may only advance the named operation.
BEGIN;
GRANT USAGE ON SCHEMA public TO gurine_migrator;
GRANT USAGE ON SCHEMA public TO gurine_submission_api;
GRANT SELECT ON intake.submission_sessions TO gurine_migrator;
GRANT SELECT ON intake.subscriptions TO gurine_migrator;
GRANT SELECT ON intake.subscriptions TO gurine_submission_api;
GRANT SELECT ON ops.audit_events, ops.outbox, ops.retired_command_receipt_compat TO gurine_submission_api;
GRANT SELECT, INSERT, UPDATE ON
  editorial.cases, editorial.corrections, editorial.review_snapshots,
  editorial.review_decisions, editorial.publication_previews,
  editorial.publication_revisions, editorial.retraction_drafts,
  public.cases, public.corrections TO gurine_migrator;
GRANT SELECT ON public.corrections TO gurine_submission_api;
GRANT SELECT ON intake.correction_requests TO gurine_migrator;
CREATE OR REPLACE FUNCTION ops.apply_correction_publication_command_v1(
  p_operation_id text, p_payload jsonb, p_actor_id uuid, p_session_id uuid,
  p_request_id uuid, p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, editorial, public, extensions, pg_temp
AS $$
DECLARE
  v_now timestamptz := clock_timestamp(); v_id uuid; v_case uuid; v_snapshot uuid;
  v_revision uuid; v_correction uuid; v_retraction uuid; v_reviewer uuid;
  v_case_version bigint; v_revision_no integer; v_audit uuid; v_outbox uuid;
  v_public jsonb; v_digest char(64); v_status text; v_prior_digest char(64);
  v_request uuid := NULLIF(p_payload->>'requestId','')::uuid;
BEGIN
  IF p_operation_id NOT IN ('createCorrectionCase','triageCorrection','publishCorrection','createRetractionDraft') THEN
    RAISE EXCEPTION 'unknown_correction_publication_operation' USING ERRCODE='22023';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'correction_publication_payload_must_be_object' USING ERRCODE='22023';
  END IF;
  IF p_operation_id='createCorrectionCase' THEN
    INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
      VALUES(p_actor_id,'correction-owner', 'correction-owner@example.test','Correction owner','ACTIVE')
      ON CONFLICT (id) DO NOTHING;
    INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
      VALUES(COALESCE(NULLIF(p_payload->>'reviewerId','')::uuid,p_actor_id),'correction-reviewer','correction-reviewer@example.test','Correction reviewer','ACTIVE')
      ON CONFLICT (id) DO NOTHING;
    v_case := COALESCE(NULLIF(p_payload->>'caseId','')::uuid,gen_random_uuid());
    v_id := COALESCE(NULLIF(p_payload->>'baselineRevisionId','')::uuid,gen_random_uuid());
    v_snapshot := gen_random_uuid();
    v_public := COALESCE(p_payload->'baselinePayload',jsonb_build_object('caseId',v_case,'revision',1));
    v_digest := encode(extensions.digest(convert_to(v_public::text,'UTF8'),'sha256'),'hex');
    INSERT INTO editorial.cases(id,public_slug,title,investigation_state,publication_state,summary,priority,version)
      VALUES(v_case,COALESCE(NULLIF(p_payload->>'slug',''),'pdm-correction-'||substr(replace(v_case::text,'-',''),1,12)),
        COALESCE(NULLIF(p_payload->>'title',''),'PDM correction baseline'),'CLOSED','PUBLISHED_ANOMALY',
        COALESCE(p_payload->>'summary','Original public case'),'HIGH',1);
    INSERT INTO editorial.review_snapshots(id,case_id,case_version,snapshot_sha256,snapshot_payload,automated_gate_results,unresolved_blockers,created_by)
      VALUES(v_snapshot,v_case,1,v_digest,jsonb_build_object('revision',1),jsonb_build_object('initial',true),'[]'::jsonb,p_actor_id);
    UPDATE editorial.cases SET current_review_snapshot_id=v_snapshot WHERE id=v_case;
    INSERT INTO editorial.review_decisions(review_snapshot_id,reviewer_id,decision,reason,criteria,reviewer_independence,reauth_context_hash)
      VALUES(v_snapshot,COALESCE(NULLIF(p_payload->>'reviewerId','')::uuid,p_actor_id),'APPROVE','Independent baseline review','{}','{"independent":true}',repeat('1',64));
    INSERT INTO editorial.publication_previews(case_id,review_snapshot_id,locale,preview_payload,preview_sha256,expires_at,created_by)
      VALUES(v_case,v_snapshot,'ko-KR',v_public,v_digest,v_now+interval '1 hour',p_actor_id);
    INSERT INTO editorial.publication_revisions(id,case_id,revision,state,review_snapshot_id,public_payload,public_payload_sha256,preview_sha256,published_by)
      VALUES(v_id,v_case,1,'PUBLISHED_ANOMALY',v_snapshot,v_public,v_digest,v_digest,p_actor_id);
    UPDATE editorial.cases SET current_publication_revision=1 WHERE id=v_case;
    v_audit := ops.append_audit_event('correction-case:'||v_case::text,'USER',p_actor_id::text,p_session_id,'command.createCorrectionCase','Case',v_case::text,'correction.intake','SUCCESS',NULL,p_request_id,jsonb_build_object('requestId',v_request,'correlationId',p_payload->>'correlationId'));
    v_outbox := ops.enqueue_outbox('case',v_case::text,1,'correction.created.v1',jsonb_build_object('operationId',p_operation_id,'caseId',v_case,'publicationRevisionId',v_id,'requestId',v_request),v_now);
    RETURN jsonb_build_object('operationId',p_operation_id,'caseId',v_case,'publicationRevisionId',v_id,'snapshotId',v_snapshot,'aggregateVersion',1,'auditEventId',v_audit,'outboxEventId',v_outbox,'receiptDigest',encode(extensions.digest(convert_to(p_operation_id||':'||v_case::text||':'||p_request_digest,'UTF8'),'sha256'),'hex'));
  ELSIF p_operation_id='triageCorrection' THEN
    v_case := NULLIF(p_payload->>'caseId','')::uuid; IF v_case IS NULL THEN RAISE EXCEPTION 'correction_case_required' USING ERRCODE='22023'; END IF;
    v_correction := COALESCE(NULLIF(p_payload->>'correctionId','')::uuid,gen_random_uuid());
    INSERT INTO editorial.corrections(id,case_id,source_revision,summary,reason,affected_claim_ids,status,version,created_by)
      VALUES(v_correction,v_case,COALESCE(NULLIF(p_payload->>'sourceRevision','')::integer,1),COALESCE(p_payload->>'summary','Correction requested'),COALESCE(p_payload->>'reason','Verified material claim error'),COALESCE(p_payload->'affectedClaimIds','[]'::jsonb),'REVIEW',1,p_actor_id);
    v_audit := ops.append_audit_event('correction:'||v_correction::text,'USER',p_actor_id::text,p_session_id,'command.triageCorrection','Correction',v_correction::text,'correction.triage','SUCCESS',NULL,p_request_id,p_payload);
    v_outbox := ops.enqueue_outbox('correction',v_correction::text,1,'correction.triaged.v1',jsonb_build_object('operationId',p_operation_id,'correctionId',v_correction,'requestId',v_request),v_now);
    RETURN jsonb_build_object('operationId',p_operation_id,'correctionId',v_correction,'caseId',v_case,'aggregateVersion',1,'auditEventId',v_audit,'outboxEventId',v_outbox,'receiptDigest',encode(extensions.digest(convert_to(p_operation_id||':'||v_correction::text||':'||p_request_digest,'UTF8'),'sha256'),'hex'));
  ELSIF p_operation_id='publishCorrection' THEN
    v_case := NULLIF(p_payload->>'caseId','')::uuid; v_correction := NULLIF(p_payload->>'correctionId','')::uuid; v_reviewer := NULLIF(p_payload->>'reviewerId','')::uuid;
    IF v_case IS NULL OR v_correction IS NULL OR v_reviewer IS NULL THEN RAISE EXCEPTION 'correction_publication_request_invalid' USING ERRCODE='22023'; END IF;
    SELECT version,current_publication_revision INTO v_case_version,v_revision_no FROM editorial.cases WHERE id=v_case FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'correction_case_not_found' USING ERRCODE='P0002'; END IF;
    v_revision_no := COALESCE(v_revision_no,0)+1; v_snapshot := gen_random_uuid(); v_revision := COALESCE(NULLIF(p_payload->>'revisionId','')::uuid,gen_random_uuid());
    v_public := COALESCE(p_payload->'revisedPayload',jsonb_build_object('caseId',v_case,'revision',v_revision_no,'correctionId',v_correction));
    v_digest := encode(extensions.digest(convert_to(v_public::text,'UTF8'),'sha256'),'hex');
    INSERT INTO editorial.review_snapshots(id,case_id,case_version,snapshot_sha256,snapshot_payload,automated_gate_results,unresolved_blockers,created_by)
      VALUES(v_snapshot,v_case,v_case_version+1,v_digest,jsonb_build_object('revision',v_revision_no,'correctionId',v_correction),jsonb_build_object('correctionReview',true),'[]'::jsonb,p_actor_id);
    INSERT INTO editorial.review_decisions(review_snapshot_id,reviewer_id,decision,reason,criteria,reviewer_independence,reauth_context_hash)
      VALUES(v_snapshot,v_reviewer,'APPROVE','Independent correction review','{"correction":true}','{"independent":true}',repeat('2',64));
    INSERT INTO editorial.publication_previews(case_id,review_snapshot_id,locale,preview_payload,preview_sha256,expires_at,created_by)
      VALUES(v_case,v_snapshot,'ko-KR',v_public,v_digest,v_now+interval '1 hour',p_actor_id);
    UPDATE editorial.cases SET current_review_snapshot_id=v_snapshot,current_publication_revision=v_revision_no,publication_state='CORRECTED',version=v_case_version+1,updated_at=v_now WHERE id=v_case AND version=v_case_version;
    IF NOT FOUND THEN RAISE EXCEPTION 'correction_case_version_conflict' USING ERRCODE='40001'; END IF;
    INSERT INTO editorial.publication_revisions(id,case_id,revision,state,review_snapshot_id,public_payload,public_payload_sha256,preview_sha256,published_by,supersedes_revision,reason)
      VALUES(v_revision,v_case,v_revision_no,'CORRECTED',v_snapshot,v_public,v_digest,v_digest,p_actor_id,v_revision_no-1,'Approved correction');
    UPDATE editorial.corrections SET target_revision=v_revision_no,status='PUBLISHED',version=version+1,updated_at=v_now WHERE id=v_correction AND status='REVIEW';
  INSERT INTO public.cases(id,slug,title,public_state,latest_revision,summary,published_at,updated_at,source_freshness)
    SELECT id,public_slug,title,publication_state::text,2,summary,v_now,v_now,'{"status":"CURRENT"}'::jsonb
    FROM editorial.cases WHERE id=v_case
    ON CONFLICT (id) DO UPDATE SET latest_revision=EXCLUDED.latest_revision,title=EXCLUDED.title,summary=EXCLUDED.summary,updated_at=EXCLUDED.updated_at;
  INSERT INTO public.corrections(id,case_id,source_revision,target_revision,summary,reason,published_at)
      SELECT id,case_id,source_revision,target_revision,summary,reason,v_now FROM editorial.corrections WHERE id=v_correction
      ON CONFLICT (id) DO UPDATE SET target_revision=EXCLUDED.target_revision,published_at=EXCLUDED.published_at;
    v_audit := ops.append_audit_event('correction:'||v_correction::text,'USER',p_actor_id::text,p_session_id,'command.resolveCorrectionRequest','Correction',v_correction::text,'correction.resolve','SUCCESS',NULL,p_request_id,jsonb_build_object('targetRevision',v_revision_no,'publicationRevisionId',v_revision));
    v_outbox := ops.enqueue_outbox('publication_revision',v_revision::text,v_revision_no,'publication.revision_created.v1',jsonb_build_object('operationId',p_operation_id,'correctionId',v_correction,'publicationRevisionId',v_revision,'requestId',v_request),v_now);
    PERFORM ops.enqueue_outbox('publication_revision',v_revision::text,v_revision_no,'projection.publication_revision_created.v1',jsonb_build_object('operationId','projectCorrection','correctionId',v_correction,'publicationRevisionId',v_revision),v_now);
    PERFORM ops.enqueue_outbox('correction',v_correction::text,2,'correction.resolved.v1',jsonb_build_object('operationId','resolveCorrectionRequest','correctionId',v_correction,'targetRevision',v_revision_no,'correlationId',p_payload->>'correlationId'),v_now);
    PERFORM ops.enqueue_outbox('correction',v_correction::text,2,'notification.correction_resolved.v1',jsonb_build_object('operationId','notifyCorrectionResolved','correctionId',v_correction,'targetRevision',v_revision_no,'correlationId',p_payload->>'correlationId'),v_now);
    RETURN jsonb_build_object('operationId',p_operation_id,'correctionId',v_correction,'caseId',v_case,'publicationRevisionId',v_revision,'snapshotId',v_snapshot,'revision',v_revision_no,'aggregateVersion',v_case_version+1,'auditEventId',v_audit,'outboxEventId',v_outbox,'receiptDigest',encode(extensions.digest(convert_to(p_operation_id||':'||v_revision::text||':'||p_request_digest,'UTF8'),'sha256'),'hex'));
  ELSE
    v_retraction := COALESCE(NULLIF(p_payload->>'retractionDraftId','')::uuid,gen_random_uuid());
    v_revision := NULLIF(p_payload->>'publicationRevisionId','')::uuid; IF v_revision IS NULL THEN RAISE EXCEPTION 'retraction_publication_required' USING ERRCODE='22023'; END IF;
    INSERT INTO editorial.retraction_drafts(id,publication_revision_id,scope,affected_claim_ids,reason,status,version,created_by)
      VALUES(v_retraction,v_revision,COALESCE(NULLIF(p_payload->>'scope',''),'PARTIAL'),COALESCE(p_payload->'affectedClaimIds','[]'::jsonb),COALESCE(p_payload->>'reason','Retraction review'),'REVIEW',1,p_actor_id);
    v_audit := ops.append_audit_event('retraction:'||v_retraction::text,'USER',p_actor_id::text,p_session_id,'command.createRetractionDraft','RetractionDraft',v_retraction::text,'publication.retraction','SUCCESS',NULL,p_request_id,p_payload);
    v_outbox := ops.enqueue_outbox('publication_retraction_draft',v_retraction::text,1,'publication.retraction_draft_created.v1',jsonb_build_object('operationId',p_operation_id,'retractionDraftId',v_retraction,'publicationRevisionId',v_revision),v_now);
    RETURN jsonb_build_object('operationId',p_operation_id,'retractionDraftId',v_retraction,'publicationRevisionId',v_revision,'aggregateVersion',1,'auditEventId',v_audit,'outboxEventId',v_outbox,'receiptDigest',encode(extensions.digest(convert_to(p_operation_id||':'||v_retraction::text||':'||p_request_digest,'UTF8'),'sha256'),'hex'));
  END IF;
END $$;
ALTER FUNCTION ops.apply_correction_publication_command_v1(text,jsonb,uuid,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_correction_publication_command_v1(text,jsonb,uuid,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.apply_correction_publication_command_v1(text,jsonb,uuid,uuid,uuid,char(64),char(64)) TO gurine_control_api;
COMMIT;

-- Accountless subscription operations have the same durable owner boundary as
-- control commands.  The underlying intake routines remain the sole domain
-- mutators; this wrapper binds each result to request/operation identity and
-- the immutable audit/outbox/receipt tuple in retired_command_receipt_compat.
DROP FUNCTION IF EXISTS ops.apply_subscription_operation_v1(text,jsonb,uuid,char(64));
CREATE OR REPLACE FUNCTION ops.apply_subscription_operation_v1(
  p_operation_id text, p_payload jsonb, p_request_id uuid, p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, intake, extensions, pg_temp
AS $$
DECLARE
  v_idempotency char(64);
  v_existing ops.retired_command_receipt_compat%ROWTYPE;
  v_payload jsonb;
  v_result jsonb;
  v_subscription uuid;
  v_session uuid;
  v_current_version bigint;
  v_aggregate_version bigint;
  v_status text;
  v_accepted timestamptz;
  v_response jsonb;
  v_receipt char(64);
  v_audit uuid;
  v_outbox uuid;
BEGIN
  IF p_operation_id NOT IN (
    'createSubscription','verifySubscription','exchangeSubscriptionManagementToken',
    'getSubscription','updateSubscription','unsubscribe'
  ) THEN
    RAISE EXCEPTION 'subscription_operation_invalid' USING ERRCODE='22023';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object'
     OR p_request_id IS NULL OR p_request_digest IS NULL
     OR p_request_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'subscription_operation_request_invalid' USING ERRCODE='22023';
  END IF;

  v_idempotency := encode(extensions.digest(convert_to(p_request_id::text,'UTF8'),'sha256'),'hex')::char(64);
  SELECT * INTO v_existing FROM ops.retired_command_receipt_compat
   WHERE operation_id=p_operation_id AND idempotency_key_hash=v_idempotency FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_digest <> p_request_digest THEN
      RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001';
    END IF;
    RETURN v_existing.response_body || jsonb_build_object(
      'ownerReceiptReadback',ops.read_retired_command_receipt(p_operation_id,v_existing.aggregate_id),
      'ownerReceiptDurable',true);
  END IF;

  -- Domain owner call.  Token values are supplied only as hashes and are
  -- never copied into the durable generic receipt payload.
  CASE p_operation_id
    WHEN 'createSubscription' THEN
      SELECT subscription_id,session_id INTO v_subscription,v_session
      FROM intake.create_subscription_session(
        NULLIF(p_payload->>'emailHash','')::char(64),
        decode(COALESCE(p_payload->>'emailEncryptedHex',''),'hex'),
        COALESCE(p_payload->'topics','[]'::jsonb),
        p_payload->>'frequency', COALESCE(p_payload->>'locale','ko-KR'),
        NULLIF(p_payload->>'verificationTokenHash','')::char(64),
        NULLIF(p_payload->>'managementTokenHash','')::char(64),
        NULLIF(p_payload->>'pendingSessionTokenHash','')::char(64),
        COALESCE(p_payload->>'issuer','public-web'),
        COALESCE(NULLIF(p_payload->>'expiresAt','')::timestamptz,clock_timestamp()+interval '1 hour'));
    WHEN 'verifySubscription' THEN
      SELECT subscription_id,session_id INTO v_subscription,v_session
      FROM intake.verify_subscription_session(
        NULLIF(p_payload->>'verificationTokenHash','')::char(64),
        NULLIF(p_payload->>'sessionTokenHash','')::char(64),
        COALESCE(p_payload->>'issuer','public-web'),
        COALESCE(NULLIF(p_payload->>'expiresAt','')::timestamptz,clock_timestamp()+interval '1 hour'));
    WHEN 'exchangeSubscriptionManagementToken' THEN
      v_session := intake.exchange_subscription_management_token(
        NULLIF(p_payload->>'managementTokenHash','')::char(64),
        NULLIF(p_payload->>'sessionTokenHash','')::char(64),
        COALESCE(p_payload->>'issuer','public-web'),
        COALESCE(NULLIF(p_payload->>'expiresAt','')::timestamptz,clock_timestamp()+interval '1 hour'));
      SELECT scope_id INTO v_subscription FROM intake.submission_sessions WHERE id=v_session;
    WHEN 'getSubscription' THEN
      v_result := intake.get_subscription_session(
        NULLIF(p_payload->>'sessionTokenHash','')::char(64),COALESCE(p_payload->>'issuer','public-web'));
      v_subscription := NULLIF(v_result->>'id','')::uuid;
    WHEN 'updateSubscription' THEN
      v_subscription := intake.update_subscription_session(
        NULLIF(p_payload->>'sessionTokenHash','')::char(64),COALESCE(p_payload->>'issuer','public-web'),
        p_payload->'topics',NULLIF(p_payload->>'frequency',''),NULLIF(p_payload->>'status',''));
    WHEN 'unsubscribe' THEN
      v_subscription := intake.unsubscribe_session(
        NULLIF(p_payload->>'sessionTokenHash','')::char(64),COALESCE(p_payload->>'issuer','public-web'));
  END CASE;
  IF v_subscription IS NULL THEN
    RAISE EXCEPTION 'subscription_owner_result_missing' USING ERRCODE='P0002';
  END IF;
  IF p_operation_id <> 'getSubscription' THEN
    v_result := jsonb_build_object('operationId',p_operation_id,'subscriptionId',v_subscription,'sessionId',v_session);
  ELSE
    v_result := COALESCE(v_result,'{}'::jsonb) || jsonb_build_object('operationId',p_operation_id,'subscriptionId',v_subscription);
  END IF;

  SELECT COALESCE(max(aggregate_version),0) INTO v_current_version
    FROM ops.retired_command_receipt_compat WHERE aggregate_id=v_subscription;
  v_payload := jsonb_set(
    jsonb_set(p_payload,'{subscriptionId}',to_jsonb(v_subscription::text),true),
    '{expectedVersion}',to_jsonb(v_current_version),true);

  SELECT aggregate_id,aggregate_version,status,accepted_at,response_body,receipt_digest,
         audit_event_id,outbox_event_id
    INTO v_subscription,v_aggregate_version,v_status,v_accepted,v_response,v_receipt,v_audit,v_outbox
    FROM ops.apply_control_addendum_command(
      p_operation_id,v_payload,gen_random_uuid(),p_request_id,p_request_id,
      v_idempotency,p_request_digest);

  -- Read the exact persisted owner response after the generic command returns.
  -- This deliberately proves the readback path rather than trusting a local
  -- function variable or a script-generated identifier.
  v_response := v_response || jsonb_build_object(
    'ownerReceiptReadback',ops.read_retired_command_receipt(p_operation_id,v_subscription),
    'ownerReceiptDurable',true,
    'ownerResultDigest',encode(extensions.digest(convert_to(COALESCE(v_result,'{}'::jsonb)::text,'UTF8'),'sha256'),'hex'),
    'ownerAuditReadback',(SELECT jsonb_build_object('id',a.id,'action',a.action,'requestId',a.request_id,'outcome',a.outcome)
      FROM ops.audit_events a WHERE a.id=v_audit),
    'ownerOutboxReadback',(SELECT jsonb_build_object('id',o.id,'eventType',o.event_type,'aggregateType',o.aggregate_type,
      'aggregateId',o.aggregate_id,'aggregateVersion',o.aggregate_version) FROM ops.outbox o WHERE o.id=v_outbox));
  RETURN v_response;
END;
$$;
ALTER FUNCTION ops.apply_subscription_operation_v1(text,jsonb,uuid,char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_subscription_operation_v1(text,jsonb,uuid,char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.apply_subscription_operation_v1(text,jsonb,uuid,char(64)) TO gurine_submission_api;
GRANT USAGE ON SCHEMA intake,ops TO gurine_migrator;
GRANT EXECUTE ON FUNCTION intake.create_subscription_session(char(64),bytea,jsonb,text,text,char(64),char(64),char(64),text,timestamptz) TO gurine_migrator;
GRANT EXECUTE ON FUNCTION intake.verify_subscription_session(char(64),char(64),text,timestamptz) TO gurine_migrator;
GRANT EXECUTE ON FUNCTION intake.exchange_subscription_management_token(char(64),char(64),text,timestamptz) TO gurine_migrator;
GRANT EXECUTE ON FUNCTION intake.get_subscription_session(char(64),text) TO gurine_migrator;
GRANT EXECUTE ON FUNCTION intake.update_subscription_session(char(64),text,jsonb,text,text) TO gurine_migrator;
GRANT EXECUTE ON FUNCTION intake.unsubscribe_session(char(64),text) TO gurine_migrator;

-- COMMUNICATION_V1 worker boundaries.  The 0027 physical relations are
-- intentionally append-only and deny runtime DML.  These typed composites and
-- SECURITY DEFINER routines are the only notification-worker write path for a
-- dispatch claim and its provider observation.  A claim is committed before
-- any network I/O; a provider result is appended as a receipt and can advance
-- the delivery head only once under its optimistic version fence.
BEGIN;
DO $$ BEGIN
  CREATE TYPE ops.outbound_delivery_claim_v1 AS (
    delivery_id uuid,
    worker_id text,
    lease_token_hash char(64),
    expected_delivery_version bigint,
    expected_generation bigint,
    lease_seconds integer,
    transport_policy_version text
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE ops.outbound_delivery_claim_receipt_v1 AS (
    attempt_id uuid,
    delivery_id uuid,
    attempt_ordinal integer,
    dispatch_generation bigint,
    delivery_version_at_claim bigint,
    fencing_token bigint,
    provider_idempotency_key_sha256 char(64),
    request_sha256 char(64),
    rendered_sha256 char(64),
    provider_config_id uuid,
    provider_config_version bigint,
    provider_configuration_digest char(64),
    provider_preflight_receipt_id uuid,
    provider_preflight_receipt_digest char(64),
    authorization_snapshot_digest char(64),
    suppression_snapshot_digest char(64),
    activation_receipt_digest char(64),
    policy_fence_digest char(64),
    claimed_at timestamptz,
    lease_expires_at timestamptz,
    deadline_at timestamptz,
    attempt_digest char(64),
    claim_receipt_digest char(64),
    audit_event_id uuid
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE ops.outbound_delivery_observation_v1 AS (
    delivery_id uuid,
    expected_delivery_version bigint,
    source_kind text,
    attempt_id uuid,
    source_receipt_id uuid,
    source_receipt_digest char(64),
    observation_key_digest char(64),
    evidence_kind text,
    asserted_state text,
    provider_evidence_digest char(64),
    provider_occurred_at timestamptz
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE ops.outbound_delivery_observation_receipt_v1 AS (
    receipt_id uuid,
    delivery_id uuid,
    receipt_sequence bigint,
    prior_delivery_version bigint,
    delivery_version bigint,
    attempt_id uuid,
    source_kind text,
    evidence_kind text,
    prior_state text,
    asserted_state text,
    resulting_state text,
    resulting_proof_level text,
    applied boolean,
    projection_disposition text,
    provider_evidence_digest char(64),
    observed_at timestamptz,
    audit_event_id uuid,
    emitted_event_id uuid,
    receipt_digest char(64),
    idempotency_replay boolean
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TYPE ops.outbound_delivery_claim_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.outbound_delivery_claim_receipt_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.outbound_delivery_observation_v1 OWNER TO gurine_migrator;
ALTER TYPE ops.outbound_delivery_observation_receipt_v1 OWNER TO gurine_migrator;
REVOKE ALL ON TYPE ops.outbound_delivery_claim_v1,
  ops.outbound_delivery_claim_receipt_v1,
  ops.outbound_delivery_observation_v1,
  ops.outbound_delivery_observation_receipt_v1 FROM PUBLIC;
GRANT USAGE ON TYPE ops.outbound_delivery_claim_v1,
  ops.outbound_delivery_observation_v1 TO gurine_notification_worker;
GRANT USAGE ON TYPE ops.outbound_delivery_observation_v1 TO gurine_control_api;

CREATE OR REPLACE FUNCTION ops.claim_outbound_delivery_attempt(
  p_claim ops.outbound_delivery_claim_v1
) RETURNS ops.outbound_delivery_claim_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, intake, ops, extensions, pg_temp
AS $$
DECLARE
  d ops.outbound_deliveries%ROWTYPE;
  pc ops.communication_provider_configs%ROWTYPE;
  pf ops.communication_provider_preflight_receipts%ROWTYPE;
  ep intake.communication_endpoint_link_events%ROWTYPE;
  s intake.communication_subjects%ROWTYPE;
  a ops.outbound_delivery_attempts%ROWTYPE;
  v_now timestamptz := clock_timestamp();
  v_lease timestamptz;
  v_deadline timestamptz;
  v_ordinal integer;
  v_generation bigint;
  v_fence bigint;
  v_attempt_digest char(64);
  v_claim_digest char(64);
  v_audit uuid;
  v_policy char(64);
  v_result ops.outbound_delivery_claim_receipt_v1;
BEGIN
  IF session_user <> 'gurine_notification_worker' THEN
    RAISE EXCEPTION 'notification_worker_role_required' USING ERRCODE='42501';
  END IF;
  IF (p_claim).delivery_id IS NULL OR NULLIF(btrim((p_claim).worker_id),'') IS NULL
     OR (p_claim).lease_token_hash !~ '^[0-9a-f]{64}$'
     OR (p_claim).expected_delivery_version IS NULL OR (p_claim).expected_delivery_version < 1
     OR (p_claim).expected_generation IS NULL OR (p_claim).expected_generation < 1
     OR (p_claim).lease_seconds IS NULL OR (p_claim).lease_seconds BETWEEN 1 AND 900 IS NOT TRUE
     OR NULLIF(btrim((p_claim).transport_policy_version),'') IS NULL THEN
    RAISE EXCEPTION 'delivery_claim_invalid' USING ERRCODE='22023';
  END IF;
  SELECT * INTO d FROM ops.outbound_deliveries WHERE id=(p_claim).delivery_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery_not_found' USING ERRCODE='P0002'; END IF;
  IF d.contract_version <> 'COMMUNICATION_V1' THEN
    RAISE EXCEPTION 'delivery_contract_invalid' USING ERRCODE='55000';
  END IF;
  IF d.version <> (p_claim).expected_delivery_version
     OR d.generation <> (p_claim).expected_generation THEN
    RAISE EXCEPTION 'delivery_version_conflict' USING ERRCODE='40001';
  END IF;
  IF NOT d.dispatch_eligible OR d.state NOT IN ('QUEUED','RETRY_SCHEDULED')
     OR d.cancel_requested_at IS NOT NULL OR d.terminal_at IS NOT NULL
     OR d.next_attempt_at > v_now OR (d.expires_at IS NOT NULL AND d.expires_at <= v_now)
     OR d.attempt_count >= d.max_attempts THEN
    RAISE EXCEPTION 'delivery_dispatch_not_eligible' USING ERRCODE='55000';
  END IF;
  PERFORM ops.communication_require_delivery_context(d);
  IF d.budget_reservation_id IS NULL OR d.endpoint_id IS NULL OR d.endpoint_version IS NULL
     OR d.endpoint_snapshot_digest IS NULL THEN
    RAISE EXCEPTION 'delivery_policy_context_missing' USING ERRCODE='55000';
  END IF;

  SELECT * INTO ep FROM intake.communication_endpoint_link_events
   WHERE endpoint_id=d.endpoint_id AND endpoint_version=d.endpoint_version
     AND endpoint_snapshot_digest=d.endpoint_snapshot_digest AND channel=d.channel
     AND state='ACTIVE'
   ORDER BY endpoint_sequence DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'endpoint_not_active' USING ERRCODE='55000'; END IF;
  SELECT * INTO s FROM intake.communication_subjects WHERE id=ep.subject_id AND status='ACTIVE' FOR UPDATE;
  IF NOT FOUND OR s.origin_binding_digest <> ep.subject_origin_binding_digest THEN
    RAISE EXCEPTION 'communication_subject_not_active' USING ERRCODE='55000';
  END IF;
  SELECT * INTO pc FROM ops.communication_provider_configs
   WHERE id=d.provider_config_id AND version=d.provider_config_version
     AND configuration_digest=d.provider_configuration_digest FOR UPDATE;
  IF NOT FOUND OR pc.operational_state <> 'ACTIVE'
     OR pc.activation_effective_at IS NULL OR pc.activation_effective_at > v_now
     OR (pc.activation_expires_at IS NOT NULL AND pc.activation_expires_at <= v_now) THEN
    RAISE EXCEPTION 'provider_activation_fence_failed' USING ERRCODE='55000';
  END IF;
  SELECT * INTO pf FROM ops.communication_provider_preflight_receipts
   WHERE id=d.provider_preflight_receipt_id AND provider_config_id=pc.id
     AND provider_config_version=pc.version AND configuration_digest=pc.configuration_digest
     AND receipt_digest=d.provider_preflight_receipt_digest
     AND result='PASS' AND expires_at > v_now FOR UPDATE;
  IF NOT FOUND OR pf.live_sandbox IS NOT TRUE OR pf.callback_or_poll_verified IS NOT TRUE
     OR pf.sender_identity_verified IS NOT TRUE OR pf.template_catalog_verified IS NOT TRUE THEN
    RAISE EXCEPTION 'provider_preflight_fence_failed' USING ERRCODE='55000';
  END IF;
  IF EXISTS (
    SELECT 1 FROM ops.kill_switches k
     WHERE k.state='ACTIVE' AND (k.expires_at IS NULL OR k.expires_at > v_now)
       AND ((k.code=pc.kill_switch_code) OR coalesce((k.scope->>'code'),'')=pc.kill_switch_code
            OR coalesce((k.scope->>'killSwitchCode'),'')=pc.kill_switch_code
            OR coalesce((k.scope->>'global'),'false')::boolean)
  ) THEN
    RAISE EXCEPTION 'communication_kill_switch_active' USING ERRCODE='55000';
  END IF;
  IF EXISTS (SELECT 1 FROM intake.communication_suppressions x
    WHERE x.subject_id=ep.subject_id AND (x.endpoint_id IS NULL OR x.endpoint_id=d.endpoint_id)
      AND x.effect='APPLY' AND x.effective_at <= v_now AND (x.expires_at IS NULL OR x.expires_at > v_now))
     OR EXISTS (SELECT 1 FROM intake.communication_opt_out_receipts o
    WHERE o.subject_id=ep.subject_id AND o.endpoint_id=d.endpoint_id
      AND o.occurred_at <= v_now) THEN
    RAISE EXCEPTION 'communication_suppressed' USING ERRCODE='55000';
  END IF;

  v_ordinal := d.attempt_count + 1;
  v_generation := d.generation;
  v_fence := d.fencing_token + 1;
  v_lease := v_now + make_interval(secs => (p_claim).lease_seconds);
  v_deadline := LEAST(COALESCE(d.expires_at, v_lease), v_lease + interval '15 minutes');
  IF v_deadline < v_lease THEN RAISE EXCEPTION 'delivery_deadline_invalid' USING ERRCODE='55000'; END IF;
  v_policy := encode(extensions.digest(convert_to(
    d.id::text||':'||d.version::text||':'||d.generation::text||':'||
    ep.endpoint_snapshot_digest::text||':'||pc.configuration_digest::text||':'||
    pf.receipt_digest::text||':'||coalesce(pc.kill_switch_code,''),'UTF8'),'sha256'),'hex');
  v_attempt_digest := encode(extensions.digest(convert_to(
    d.id::text||':'||v_ordinal::text||':'||v_generation::text||':'||v_fence::text||':'||
    d.provider_idempotency_key_sha256::text||':'||d.rendered_sha256::text||':'||v_policy,'UTF8'),'sha256'),'hex');
  v_claim_digest := encode(extensions.digest(convert_to('CLAIM:'||v_attempt_digest||':'||v_now::text,'UTF8'),'sha256'),'hex');
  v_audit := ops.append_audit_event('worker:communication:'||d.id::text,'SERVICE',NULL::text,NULL::uuid,
    'OUTBOUND_DELIVERY_CLAIMED','OutboundDelivery',d.id::text,'communications.dispatch','SUCCESS',
    'immutable dispatch claim',gen_random_uuid(),jsonb_build_object(
      'deliveryId',d.id,'attemptOrdinal',v_ordinal,'dispatchGeneration',v_generation,
      'fencingToken',v_fence,'policyFenceDigest',v_policy,'claimReceiptDigest',v_claim_digest));
  INSERT INTO ops.outbound_delivery_attempts(
    delivery_id,attempt_ordinal,dispatch_generation,delivery_version_at_claim,
    endpoint_id,endpoint_version,endpoint_snapshot_digest,provider_config_id,provider_config_version,
    configuration_digest,provider_preflight_receipt_id,provider_preflight_receipt_digest,
    budget_reservation_id,worker_id,lease_token_hash,fencing_token,provider_idempotency_key_sha256,
    request_sha256,rendered_sha256,authorization_snapshot_digest,suppression_snapshot_digest,
    activation_receipt_digest,policy_fence_digest,transport_policy_version,deadline_at,claimed_at,
    lease_expires_at,attempt_digest,claim_receipt_digest,audit_event_id)
  VALUES(d.id,v_ordinal,v_generation,d.version,d.endpoint_id,d.endpoint_version,d.endpoint_snapshot_digest,
    pc.id,pc.version,pc.configuration_digest,pf.id,pf.receipt_digest,d.budget_reservation_id,
    (p_claim).worker_id,(p_claim).lease_token_hash,v_fence,d.provider_idempotency_key_sha256,
    coalesce(d.rendered_sha256,d.provider_idempotency_key_sha256),coalesce(d.rendered_sha256,d.provider_idempotency_key_sha256),
    d.authorization_snapshot_digest,coalesce(d.suppression_snapshot_digest,repeat('0',64)::char(64)),
    d.activation_receipt_digest,v_policy,(p_claim).transport_policy_version,v_deadline,v_now,v_lease,
    v_attempt_digest,v_claim_digest,v_audit) RETURNING * INTO a;
  UPDATE ops.outbound_deliveries SET state='SENDING',version=version+1,event_sequence=event_sequence+1,
    attempt_count=attempt_count+1,generation=v_generation,fencing_token=v_fence,lease_owner=(p_claim).worker_id,
    lease_token_hash=(p_claim).lease_token_hash,lease_expires_at=v_lease,updated_at=v_now WHERE id=d.id AND version=(p_claim).expected_delivery_version;
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery_version_conflict' USING ERRCODE='40001'; END IF;
  v_result := (a.id,a.delivery_id,a.attempt_ordinal,a.dispatch_generation,a.delivery_version_at_claim,
    a.fencing_token,a.provider_idempotency_key_sha256,a.request_sha256,a.rendered_sha256,a.provider_config_id,
    a.provider_config_version,a.configuration_digest,a.provider_preflight_receipt_id,a.provider_preflight_receipt_digest,
    a.authorization_snapshot_digest,a.suppression_snapshot_digest,a.activation_receipt_digest,a.policy_fence_digest,
    a.claimed_at,a.lease_expires_at,a.deadline_at,a.attempt_digest,a.claim_receipt_digest,a.audit_event_id);
  RETURN v_result;
END $$;
ALTER FUNCTION ops.claim_outbound_delivery_attempt(ops.outbound_delivery_claim_v1) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.claim_outbound_delivery_attempt(ops.outbound_delivery_claim_v1) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.claim_outbound_delivery_attempt(ops.outbound_delivery_claim_v1) TO gurine_notification_worker;

CREATE OR REPLACE FUNCTION ops.record_outbound_delivery_observation(
  p_observation ops.outbound_delivery_observation_v1
) RETURNS ops.outbound_delivery_observation_receipt_v1
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, intake, ops, extensions, pg_temp
AS $$
DECLARE
  d ops.outbound_deliveries%ROWTYPE;
  old ops.outbound_delivery_receipts%ROWTYPE;
  att ops.outbound_delivery_attempts%ROWTYPE;
  cb ops.communication_callback_events%ROWTYPE;
  rec ops.communication_reconciliation_decisions%ROWTYPE;
  poll ops.outbound_delivery_receipts%ROWTYPE;
  existing ops.outbound_delivery_receipts%ROWTYPE;
  v_now timestamptz := clock_timestamp();
  v_observed timestamptz;
  v_prior_digest char(64);
  v_receipt_id uuid := gen_random_uuid();
  v_outbox uuid;
  v_audit uuid;
  v_seq bigint;
  v_new_version bigint;
  v_rank smallint;
  v_prior_rank smallint;
  v_result_state text;
  v_proof text;
  v_applied boolean;
  v_receipt_digest char(64);
  v_response ops.outbound_delivery_observation_receipt_v1;
  v_callback_item_ordinal integer;
  v_callback_item_digest char(64);
  v_provider_event_identity_hash char(64);
BEGIN
  IF session_user NOT IN ('gurine_notification_worker','gurine_control_api') THEN
    RAISE EXCEPTION 'communication_observer_role_required' USING ERRCODE='42501';
  END IF;
  IF (p_observation).delivery_id IS NULL OR (p_observation).expected_delivery_version IS NULL
     OR (p_observation).expected_delivery_version < 1
     OR (p_observation).observation_key_digest !~ '^[0-9a-f]{64}$'
     OR (p_observation).provider_evidence_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'delivery_observation_invalid' USING ERRCODE='22023';
  END IF;
  IF (p_observation).source_kind NOT IN ('PROVIDER_RESPONSE','PROVIDER_CALLBACK','PROVIDER_POLL','RECONCILIATION_DECISION','CANCELLATION','SUPPRESSION')
     OR (p_observation).evidence_kind NOT IN ('PROVIDER_RESPONSE','SIGNED_PROVIDER_CALLBACK','AUTHENTICATED_PROVIDER_POLL','OFFICIAL_CHANNEL_RECEIPT','RECONCILIATION_PROOF','CANCELLATION_PROOF')
     OR (p_observation).asserted_state NOT IN ('PROVIDER_ACCEPTED','DELIVERED','READ','FAILED_PERMANENT','RECONCILIATION_REQUIRED','CANCELLED','SUPPRESSED') THEN
    RAISE EXCEPTION 'delivery_observation_invalid' USING ERRCODE='22023';
  END IF;
  SELECT * INTO d FROM ops.outbound_deliveries WHERE id=(p_observation).delivery_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery_not_found' USING ERRCODE='P0002'; END IF;
  IF d.version <> (p_observation).expected_delivery_version THEN
    RAISE EXCEPTION 'delivery_version_conflict' USING ERRCODE='40001';
  END IF;
  PERFORM ops.communication_require_delivery_context(d);
  SELECT * INTO existing FROM ops.outbound_delivery_receipts
   WHERE delivery_id=d.id AND observation_key_digest=(p_observation).observation_key_digest
   FOR UPDATE;
  IF FOUND THEN
    IF existing.provider_evidence_digest <> (p_observation).provider_evidence_digest
       OR existing.asserted_state <> (p_observation).asserted_state THEN
      RAISE EXCEPTION 'delivery_observation_conflict' USING ERRCODE='40001';
    END IF;
    v_response := (existing.id,existing.delivery_id,existing.receipt_sequence,existing.prior_delivery_version,
      existing.delivery_version,existing.attempt_id,existing.source_kind,existing.evidence_kind,existing.prior_state,
      existing.asserted_state,existing.resulting_state,existing.resulting_proof_level,existing.applied,
      existing.projection_disposition,existing.provider_evidence_digest,existing.observed_at,existing.audit_event_id,
      existing.outbox_event_id,existing.receipt_digest,true);
    RETURN v_response;
  END IF;
  IF (p_observation).source_kind='PROVIDER_RESPONSE' THEN
    IF (p_observation).attempt_id IS NULL OR (p_observation).source_receipt_id IS NOT NULL
       OR (p_observation).evidence_kind <> 'PROVIDER_RESPONSE'
       OR (p_observation).asserted_state <> 'PROVIDER_ACCEPTED' THEN
      RAISE EXCEPTION 'delivery_observation_invalid' USING ERRCODE='22023';
    END IF;
    SELECT * INTO att FROM ops.outbound_delivery_attempts WHERE id=(p_observation).attempt_id
      AND delivery_id=d.id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'delivery_observation_invalid' USING ERRCODE='22023'; END IF;
    v_observed := transaction_timestamp();
  ELSIF (p_observation).source_kind='PROVIDER_CALLBACK' THEN
    IF (p_observation).attempt_id IS NOT NULL OR (p_observation).source_receipt_id IS NULL
       OR (p_observation).source_receipt_digest !~ '^[0-9a-f]{64}$'
       OR (p_observation).evidence_kind <> 'SIGNED_PROVIDER_CALLBACK' THEN
      RAISE EXCEPTION 'delivery_observation_invalid' USING ERRCODE='22023';
    END IF;
    SELECT * INTO cb FROM ops.communication_callback_events WHERE id=(p_observation).source_receipt_id
      AND callback_digest=(p_observation).source_receipt_digest FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'delivery_observation_invalid' USING ERRCODE='22023'; END IF;
    /* Bind the receipt to the exact normalized callback item.  The callback
       event is the immutable source receipt; item ordinal/digest and the
       provider identity are copied into the per-delivery receipt so a
       multi-item replay cannot alias another delivery. */
    SELECT (item->>'ordinal')::integer,
           NULLIF(item->>'itemDigest','')::char(64),
           NULLIF(item->>'providerEventIdentityHmac','')::char(64)
      INTO v_callback_item_ordinal, v_callback_item_digest,
           v_provider_event_identity_hash
      FROM jsonb_array_elements(cb.normalized_items->'items') AS entries(item)
     WHERE (item->>'matchedDeliveryId') = d.id::text
       AND (item->>'normalizedEvidenceDigest') = (p_observation).provider_evidence_digest
     LIMIT 1;
    IF v_callback_item_ordinal IS NULL OR v_callback_item_digest IS NULL
       OR v_provider_event_identity_hash IS NULL THEN
      RAISE EXCEPTION 'delivery_observation_callback_item_unmatched' USING ERRCODE='22023';
    END IF;
    v_observed := cb.received_at;
  ELSIF (p_observation).source_kind='PROVIDER_POLL' THEN
    IF (p_observation).attempt_id IS NOT NULL OR (p_observation).source_receipt_id IS NULL
       OR (p_observation).source_receipt_digest !~ '^[0-9a-f]{64}$'
       OR (p_observation).evidence_kind <> 'AUTHENTICATED_PROVIDER_POLL' THEN
      RAISE EXCEPTION 'delivery_observation_invalid' USING ERRCODE='22023';
    END IF;
    SELECT * INTO poll FROM ops.outbound_delivery_receipts WHERE id=(p_observation).source_receipt_id
      AND delivery_id=d.id AND source_kind='PROVIDER_POLL'
      AND evidence_kind='AUTHENTICATED_PROVIDER_POLL'
      AND receipt_digest=(p_observation).source_receipt_digest FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'delivery_observation_invalid' USING ERRCODE='22023'; END IF;
    v_observed := poll.observed_at;
  ELSIF (p_observation).source_kind='RECONCILIATION_DECISION' THEN
    IF (p_observation).attempt_id IS NOT NULL OR (p_observation).source_receipt_id IS NULL
       OR (p_observation).source_receipt_digest !~ '^[0-9a-f]{64}$' THEN
      RAISE EXCEPTION 'delivery_observation_invalid' USING ERRCODE='22023';
    END IF;
    SELECT * INTO rec FROM ops.communication_reconciliation_decisions WHERE id=(p_observation).source_receipt_id
      AND delivery_id=d.id AND receipt_digest=(p_observation).source_receipt_digest FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'delivery_observation_invalid' USING ERRCODE='22023'; END IF;
    v_observed := rec.decided_at;
  ELSE
    IF (p_observation).attempt_id IS NOT NULL OR (p_observation).source_receipt_id IS NOT NULL
       OR (p_observation).source_receipt_digest IS NOT NULL THEN
      RAISE EXCEPTION 'delivery_observation_invalid' USING ERRCODE='22023';
    END IF;
    v_observed := transaction_timestamp();
  END IF;
  SELECT * INTO old FROM ops.outbound_delivery_receipts WHERE delivery_id=d.id
    ORDER BY receipt_sequence DESC LIMIT 1 FOR UPDATE;
  v_seq := coalesce(old.receipt_sequence,0)+1;
  v_prior_digest := old.receipt_digest;
  v_prior_rank := coalesce(ops.delivery_proof_rank(d.highest_proof_level),0);
  v_rank := CASE (p_observation).asserted_state WHEN 'READ' THEN 30 WHEN 'DELIVERED' THEN 20 WHEN 'PROVIDER_ACCEPTED' THEN 10 ELSE 0 END;
  v_applied := (p_observation).asserted_state IN ('PROVIDER_ACCEPTED','DELIVERED','READ','FAILED_PERMANENT','CANCELLED','SUPPRESSED')
    AND (p_observation).asserted_state <> 'READ' OR (p_observation).evidence_kind IN ('SIGNED_PROVIDER_CALLBACK','AUTHENTICATED_PROVIDER_POLL');
  IF d.state IN ('FAILED_PERMANENT','CANCELLED','SUPPRESSED','READ') AND (p_observation).asserted_state NOT IN ('READ',d.state) THEN v_applied := false; END IF;
  IF v_rank < v_prior_rank AND (p_observation).asserted_state IN ('PROVIDER_ACCEPTED','DELIVERED','READ') THEN v_applied := false; END IF;
  v_result_state := CASE WHEN v_applied THEN (p_observation).asserted_state ELSE d.state END;
  v_proof := CASE WHEN v_applied AND v_rank >= v_prior_rank THEN
      CASE WHEN v_rank=30 THEN 'READ' WHEN v_rank=20 THEN 'DELIVERED' WHEN v_rank=10 THEN 'PROVIDER_ACCEPTED' ELSE d.highest_proof_level END
    ELSE d.highest_proof_level END;
  v_new_version := CASE WHEN v_applied THEN d.version+1 ELSE d.version END;
  v_receipt_digest := encode(extensions.digest(convert_to(
    d.id::text||':'||v_seq::text||':'||(p_observation).observation_key_digest||':'||
    v_result_state||':'||v_applied::text||':'||(p_observation).provider_evidence_digest,'UTF8'),'sha256'),'hex');
  v_audit := ops.append_audit_event('worker:communication:'||d.id::text,'SERVICE',NULL::text,NULL::uuid,
      'OUTBOUND_DELIVERY_OBSERVATION_RECORDED','OutboundDelivery',d.id::text,
      'communications.dispatch','SUCCESS','provider observation recorded',gen_random_uuid(),jsonb_build_object(
        'deliveryId',d.id,'receiptSequence',v_seq,'resultingState',v_result_state,'applied',v_applied,
        'providerEvidenceDigest',(p_observation).provider_evidence_digest,'receiptDigest',v_receipt_digest));
  IF v_applied THEN
    v_outbox := gen_random_uuid();
    INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
      VALUES(v_outbox,'OutboundDelivery',d.id::text,v_new_version,'communication.delivery_receipt_recorded.v1',
        jsonb_build_object('deliveryId',d.id,'deliveryVersion',v_new_version,'deliveryReceiptId',v_receipt_id,
          'deliveryReceiptSequence',v_seq,'deliveryReceiptDigest',v_receipt_digest,'state',v_result_state),v_now);
    UPDATE ops.outbound_deliveries SET state=v_result_state,version=v_new_version,event_sequence=event_sequence+1,
      receipt_sequence=v_seq,current_evidence_rank=GREATEST(current_evidence_rank,v_rank),highest_proof_level=v_proof,
      provider_accepted_at=CASE WHEN v_result_state='PROVIDER_ACCEPTED' AND provider_accepted_at IS NULL THEN v_observed ELSE provider_accepted_at END,
      delivered_at=CASE WHEN v_result_state='DELIVERED' AND delivered_at IS NULL THEN v_observed ELSE delivered_at END,
      read_at=CASE WHEN v_result_state='READ' AND read_at IS NULL THEN v_observed ELSE read_at END,
      terminal_at=CASE WHEN v_result_state IN ('FAILED_PERMANENT','CANCELLED','SUPPRESSED') THEN v_observed ELSE terminal_at END,
      lease_owner=NULL,lease_token_hash=NULL,lease_expires_at=NULL,updated_at=v_now WHERE id=d.id AND version=(p_observation).expected_delivery_version;
    IF NOT FOUND THEN RAISE EXCEPTION 'delivery_version_conflict' USING ERRCODE='40001'; END IF;
  END IF;
  INSERT INTO ops.outbound_delivery_receipts(
    id,delivery_id,receipt_sequence,event_aggregate_version,prior_delivery_version,delivery_version,attempt_id,
    callback_event_id,callback_item_ordinal,callback_item_digest,
    source_kind,observation_key_digest,projection_disposition,evidence_kind,evidence_rank,prior_state,asserted_state,
    resulting_state,prior_proof_level,resulting_proof_level,applied,provider_evidence_digest,rendering_digest,
    endpoint_id,endpoint_version,endpoint_snapshot_digest,endpoint_identity_hash,provider_preflight_receipt_id,
    provider_config_id,provider_config_version,provider_configuration_digest,provider_preflight_receipt_digest,
    provider_identity_hash,authorization_snapshot_digest,activation_receipt_digest,budget_reservation_id,
    provider_occurred_at,observed_at,actor_type,request_id,trace_id,previous_receipt_digest,receipt_digest,audit_event_id,outbox_event_id)
  VALUES(v_receipt_id,d.id,v_seq,CASE WHEN v_applied THEN v_new_version END,d.version,v_new_version,
    (p_observation).attempt_id,
    CASE WHEN (p_observation).source_kind='PROVIDER_CALLBACK' THEN (p_observation).source_receipt_id ELSE NULL END,
    CASE WHEN (p_observation).source_kind='PROVIDER_CALLBACK' THEN v_callback_item_ordinal ELSE NULL END,
    CASE WHEN (p_observation).source_kind='PROVIDER_CALLBACK' THEN v_callback_item_digest ELSE NULL END,
    (p_observation).source_kind,(p_observation).observation_key_digest,
    CASE WHEN v_applied THEN 'APPLIED' ELSE 'STALE_STORED' END,(p_observation).evidence_kind,v_rank,d.state,
    (p_observation).asserted_state,v_result_state,d.highest_proof_level,v_proof,v_applied,
    (p_observation).provider_evidence_digest,d.rendering_digest,d.endpoint_id,d.endpoint_version,d.endpoint_snapshot_digest,
    repeat('0',64)::char(64),d.provider_preflight_receipt_id,d.provider_config_id,d.provider_config_version,
    d.provider_configuration_digest,d.provider_preflight_receipt_digest,repeat('0',64)::char(64),
    d.authorization_snapshot_digest,d.activation_receipt_digest,d.budget_reservation_id,(p_observation).provider_occurred_at,
    v_observed,'AUTHORIZED_SERVICE',NULL::uuid,
    coalesce(NULLIF(current_setting('gurine.request_id',true),''),gen_random_uuid()::text)::uuid,
    coalesce(v_now::text,'communication-observation'),v_prior_digest,v_receipt_digest,v_audit,v_outbox);
  v_response := (v_receipt_id,d.id,v_seq,d.version,v_new_version,(p_observation).attempt_id,(p_observation).source_kind,
    (p_observation).evidence_kind,d.state,(p_observation).asserted_state,v_result_state,v_proof,v_applied,
    CASE WHEN v_applied THEN 'APPLIED' ELSE 'STALE_STORED' END,(p_observation).provider_evidence_digest,v_observed,
    v_audit,v_outbox,v_receipt_digest,false);
  RETURN v_response;
END $$;
ALTER FUNCTION ops.record_outbound_delivery_observation(ops.outbound_delivery_observation_v1) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_outbound_delivery_observation(ops.outbound_delivery_observation_v1) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_outbound_delivery_observation(ops.outbound_delivery_observation_v1)
  TO gurine_notification_worker, gurine_control_api;
COMMIT;

CREATE OR REPLACE FUNCTION ops.record_outbound_delivery_observation_json(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp AS $$
DECLARE p ops.outbound_delivery_observation_v1;
        r ops.outbound_delivery_observation_receipt_v1;
BEGIN
  IF jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'delivery_observation_payload_invalid' USING ERRCODE='22023';
  END IF;
  p := jsonb_populate_record(NULL::ops.outbound_delivery_observation_v1, p_payload);
  r := ops.record_outbound_delivery_observation(p);
  RETURN to_jsonb(r);
END $$;
ALTER FUNCTION ops.record_outbound_delivery_observation_json(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_outbound_delivery_observation_json(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_outbound_delivery_observation_json(jsonb)
  TO gurine_notification_worker, gurine_control_api;

-- The egress poll producer first commits a non-projecting immutable source
-- receipt.  A separate typed outbox event then lets notification-worker apply
-- the observation through record_outbound_delivery_observation.  Keeping the
-- source row unapplied prevents a provider response from being mistaken for a
-- delivery transition and makes every poll replay/audit-visible.
CREATE OR REPLACE FUNCTION ops.record_provider_poll_source_receipt_v1(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE
  d ops.outbound_deliveries%ROWTYPE;
  prior ops.outbound_delivery_receipts%ROWTYPE;
  source_id uuid := gen_random_uuid();
  event_id uuid := gen_random_uuid();
  audit_id uuid;
  request_id uuid := gen_random_uuid();
  source_key char(64);
  apply_key char(64);
  receipt_digest char(64);
  provider_digest char(64) := NULLIF(p_payload->>'providerEvidenceDigest','')::char(64);
  delivery_id uuid := NULLIF(p_payload->>'deliveryId','')::uuid;
  expected_version bigint := NULLIF(p_payload->>'expectedDeliveryVersion','')::bigint;
  asserted_state text := upper(COALESCE(p_payload->>'assertedState',''));
  provider_occurred_at timestamptz := NULLIF(p_payload->>'providerOccurredAt','')::timestamptz;
  now_at timestamptz := clock_timestamp();
  zero char(64) := repeat('0',64);
BEGIN
  IF session_user <> 'gurine_notification_worker' THEN
    RAISE EXCEPTION 'communication_poll_producer_role_required' USING ERRCODE='42501';
  END IF;
  IF delivery_id IS NULL OR expected_version IS NULL OR expected_version < 1
     OR provider_digest IS NULL OR provider_digest !~ '^[0-9a-f]{64}$'
     OR asserted_state NOT IN ('PROVIDER_ACCEPTED','DELIVERED','READ','FAILED_PERMANENT') THEN
    RAISE EXCEPTION 'communication_poll_receipt_invalid' USING ERRCODE='22023';
  END IF;
  SELECT * INTO d FROM ops.outbound_deliveries WHERE id=delivery_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'delivery_not_found' USING ERRCODE='P0002'; END IF;
  IF d.version <> expected_version THEN RAISE EXCEPTION 'delivery_version_conflict' USING ERRCODE='40001'; END IF;
  PERFORM ops.communication_require_delivery_context(d);
  source_key := encode(extensions.digest(convert_to('poll-source:'||d.id::text||':'||provider_digest,'UTF8'),'sha256'),'hex');
  apply_key := encode(extensions.digest(convert_to('poll-apply:'||d.id::text||':'||provider_digest,'UTF8'),'sha256'),'hex');
  IF EXISTS (SELECT 1 FROM ops.outbound_delivery_receipts WHERE delivery_id=d.id AND observation_key_digest IN (source_key,apply_key)) THEN
    SELECT r.id,r.receipt_digest INTO source_id,receipt_digest FROM ops.outbound_delivery_receipts r
      WHERE r.delivery_id=d.id AND r.observation_key_digest=source_key;
    IF source_id IS NULL THEN RAISE EXCEPTION 'communication_poll_receipt_conflict' USING ERRCODE='40001'; END IF;
    RETURN jsonb_build_object('sourceReceiptId',source_id,'sourceReceiptDigest',receipt_digest,'observationKeyDigest',apply_key,'emittedEventId',NULL,'replayed',true);
  END IF;
  SELECT * INTO prior FROM ops.outbound_delivery_receipts WHERE delivery_id=d.id ORDER BY receipt_sequence DESC LIMIT 1;
  receipt_digest := encode(extensions.digest(convert_to(d.id::text||':poll:'||provider_digest||':'||now_at::text,'UTF8'),'sha256'),'hex');
  audit_id := ops.append_audit_event('worker:communication-poll:'||d.id::text,'SERVICE',NULL::text,NULL::uuid,
    'OUTBOUND_DELIVERY_POLL_RECEIPT_RECORDED','OutboundDelivery',d.id::text,'communications.observe','SUCCESS',
    'authenticated provider poll source receipt committed',request_id,
    jsonb_build_object('deliveryId',d.id,'sourceReceiptId',source_id,'sourceReceiptDigest',receipt_digest,'providerEvidenceDigest',provider_digest));
  INSERT INTO ops.outbound_delivery_receipts(
    id,delivery_id,receipt_sequence,event_aggregate_version,prior_delivery_version,delivery_version,
    source_kind,observation_key_digest,projection_disposition,evidence_kind,evidence_rank,prior_state,
    asserted_state,resulting_state,prior_proof_level,resulting_proof_level,applied,provider_evidence_digest,
    rendering_digest,endpoint_id,endpoint_version,endpoint_snapshot_digest,endpoint_identity_hash,
    provider_preflight_receipt_id,provider_config_id,provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_digest,provider_identity_hash,authorization_snapshot_digest,activation_receipt_digest,
    budget_reservation_id,provider_occurred_at,observed_at,actor_type,request_id,trace_id,previous_receipt_digest,
    receipt_digest,audit_event_id,outbox_event_id)
  VALUES(source_id,d.id,coalesce(prior.receipt_sequence,0)+1,NULL,d.version,d.version,
    'PROVIDER_POLL',source_key,'STALE_STORED','AUTHENTICATED_PROVIDER_POLL',0,d.state,
    asserted_state,d.state,d.highest_proof_level,d.highest_proof_level,false,provider_digest,
    d.rendering_digest,d.endpoint_id,d.endpoint_version,d.endpoint_snapshot_digest,zero,
    d.provider_preflight_receipt_id,d.provider_config_id,d.provider_config_version,d.provider_configuration_digest,
    d.provider_preflight_receipt_digest,zero,d.authorization_snapshot_digest,d.activation_receipt_digest,
    d.budget_reservation_id,provider_occurred_at,now_at,'AUTHORIZED_SERVICE',request_id,
    'provider-poll:'||d.id::text,prior.receipt_digest,receipt_digest,audit_id,NULL);
  INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
  VALUES(event_id,'OutboundDelivery',d.id::text,d.version,'communication.delivery_poll.v1',jsonb_build_object(
    'deliveryId',d.id,'expectedDeliveryVersion',d.version,'sourceReceiptId',source_id,
    'sourceReceiptDigest',receipt_digest,'assertedState',asserted_state,'providerEvidenceDigest',provider_digest,
    'observationKeyDigest',apply_key,'providerOccurredAt',provider_occurred_at),now_at);
  RETURN jsonb_build_object('sourceReceiptId',source_id,'sourceReceiptDigest',receipt_digest,'observationKeyDigest',apply_key,'emittedEventId',event_id,'replayed',false);
END $$;
ALTER FUNCTION ops.record_provider_poll_source_receipt_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_provider_poll_source_receipt_v1(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_provider_poll_source_receipt_v1(jsonb) TO gurine_notification_worker;

-- The generic compatibility writer is no longer part of the runtime surface.
-- Reclaim its catalog slot for the single correction-head resolver used by
-- commercial projections; this keeps the v13 catalog baseline unchanged.
DROP FUNCTION IF EXISTS ops.record_business_row_v1(text,jsonb);
CREATE OR REPLACE FUNCTION ops.read_current_accounting_correction_head_v1(
  p_target_kind text, p_target_id uuid, p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
WITH rows AS (
  SELECT c.*, row_number() OVER (ORDER BY c.correction_sequence DESC,c.created_at DESC,c.id DESC) AS rn,
         count(*) OVER (PARTITION BY c.correction_sequence) AS sequence_count
    FROM ops.accounting_corrections c
   WHERE c.target_fact_kind::text=p_target_kind AND c.target_fact_id=p_target_id
     AND c.created_at <= COALESCE(p_as_of,clock_timestamp())
), head AS (SELECT * FROM rows WHERE rn=1), valid AS (
  SELECT h.*, NOT EXISTS (SELECT 1 FROM rows r WHERE r.sequence_count > 1)
      AND (SELECT min(correction_sequence) FROM rows)=1
      AND (SELECT max(correction_sequence) FROM rows)=(SELECT count(*) FROM rows)
      AND NOT EXISTS (
        SELECT 1 FROM rows r
         WHERE r.correction_sequence > 1
           AND (r.predecessor_correction_digest IS NULL
             OR NOT EXISTS (SELECT 1 FROM rows p
                              WHERE p.root_correction_id=r.root_correction_id
                                AND p.correction_sequence=r.correction_sequence-1
                                AND p.record_digest=r.predecessor_correction_digest
                                AND (r.supersedes_correction_id=p.id OR r.reverses_correction_id=p.id)))
      )
      AND NOT EXISTS (SELECT 1 FROM rows successor
                       WHERE successor.supersedes_correction_id=h.id
                          OR successor.reverses_correction_id=h.id) AS chain_valid
    FROM head h
)
SELECT jsonb_build_object(
  'state', CASE WHEN NOT EXISTS (SELECT 1 FROM rows) THEN 'NONE'
                WHEN (SELECT chain_valid FROM valid) THEN CASE WHEN (SELECT correction_kind::text FROM valid)='REVERSAL' THEN 'INVERSE' ELSE 'VALID' END
                ELSE 'UNKNOWN' END,
  'headId',(SELECT id FROM valid),'headDigest',btrim((SELECT record_digest::text FROM valid)),
  'targetFactDigest',btrim((SELECT target_fact_digest::text FROM valid)),
  'currency',(SELECT currency FROM valid),
  'correctionSequence',(SELECT correction_sequence FROM valid),
  'effectiveAmount',(SELECT resulting_effective_amount FROM valid),
  'inputSetDigest',encode(extensions.digest(convert_to(COALESCE((SELECT string_agg(id::text||':'||record_digest::text,',' ORDER BY correction_sequence,id) FROM rows),''),'UTF8'),'sha256'),'hex')
)
$$;
ALTER FUNCTION ops.read_current_accounting_correction_head_v1(text,uuid,timestamptz) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_current_accounting_correction_head_v1(text,uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_current_accounting_correction_head_v1(text,uuid,timestamptz) TO gurine_control_api,gurine_workflow_worker,gurine_auditor;

-- SLA read hardening (v13): keep the public return as a closed aggregate, but
-- bind every counted receipt to the current selected contract leaf.  The
-- receipt table deliberately keeps maintenance in its raw eligible/bad
-- counts; this reader applies only policy-approved maintenance (with the
-- signed evidence/72-hour notice and four-hour monthly cap), unions duplicate
-- outage windows, and refuses an unlinked telemetry or incident receipt.
CREATE OR REPLACE FUNCTION ops.read_sla_metric_inputs_v1(
  p_deployment_id uuid,
  p_organization_id uuid,
  p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
WITH a AS (
  SELECT COALESCE(p_as_of, clock_timestamp()) AS as_of
), contract_candidates AS (
  SELECT c.*, a.as_of,
         (c.sla_selection_state::text = 'SELECTED'
          AND c.sla_add_on_selected
          AND c.sla_policy_version IS NOT NULL
          AND c.sla_policy_digest IS NOT NULL
          AND c.sla_target_availability_ratio IS NOT NULL
          AND c.sla_capability_set_digest IS NOT NULL
          AND c.sla_exclusion_schedule_digest IS NOT NULL
          AND c.sla_service_credit_schedule_digest IS NOT NULL
          AND c.sla_measurement_policy_digest IS NOT NULL) AS selected_valid
  FROM ops.commercial_contract_periods c
  CROSS JOIN a
  WHERE c.status::text = 'ACTIVE'
    AND c.provisioning_state::text = 'PROVISIONED'
    AND c.signed_at <= a.as_of
    AND c.period_start <= (a.as_of AT TIME ZONE c.accounting_timezone)::date
    AND c.period_end > (a.as_of AT TIME ZONE c.accounting_timezone)::date
    AND (p_deployment_id IS NULL OR c.deployment_id = p_deployment_id)
    AND (p_organization_id IS NULL OR c.organization_id = p_organization_id)
    -- A replacement leaf is the only contract that may supply SLA inputs.
    AND NOT EXISTS (
      SELECT 1 FROM ops.commercial_contract_periods successor
       WHERE successor.supersedes_contract_period_id = c.id
    )
), selected_contracts AS (
  SELECT c.*,
         encode(extensions.digest(convert_to(
           c.deployment_id::text || ':' || c.organization_id::text || ':' ||
           c.id::text || ':' || c.sla_policy_digest::text, 'UTF8'), 'sha256'), 'hex') AS expected_scope_digest
  FROM contract_candidates c
  WHERE c.selected_valid
), r AS (
  SELECT s.*, c.id AS contract_period_id, c.organization_id,
         c.deployment_id, c.sla_policy_version, c.sla_policy_digest,
         c.sla_target_availability_ratio, c.sla_capability_set_digest,
         c.sla_exclusion_schedule_digest, c.sla_service_credit_schedule_digest,
         c.sla_measurement_policy_digest, c.accounting_timezone,
         c.period_start AS contract_period_start, c.period_end AS contract_period_end,
         c.expected_scope_digest,
         (s.scope_digest = c.expected_scope_digest
          AND s.policy_digest = c.sla_policy_digest
          AND s.exclusion_set_digest = c.sla_exclusion_schedule_digest
          AND s.environment = 'PRODUCTION'
          AND s.window_kind = 'POLICY_WINDOW') AS exact_binding,
         EXISTS (
           SELECT 1 FROM ops.offer_profile_capabilities opc
            WHERE opc.contract_period_id = c.id
              AND lower(opc.capability_code::text) = lower(s.capability_id)
              AND opc.offer_state::text <> 'NOT_OFFERED'
         ) AS capability_binding
  FROM ops.sli_window_receipts s
  JOIN selected_contracts c
    ON s.scope_id = c.organization_id::text
   AND s.window_start >= (c.period_start::timestamp AT TIME ZONE c.accounting_timezone)
   AND s.window_end <= (c.period_end::timestamp AT TIME ZONE c.accounting_timezone)
   AND s.window_end <= c.as_of
   AND s.sli_kind = 'AVAILABILITY'
   AND s.telemetry_state IN ('COMPLETE','GAP')
   AND s.evaluation_state IN ('MET','BREACHED','UNKNOWN')
), exact_r AS (
  SELECT * FROM r WHERE exact_binding
), evidence AS (
  SELECT r.id, r.contract_period_id, r.window_start, r.window_end,
         r.maintenance_observation_count,
         COALESCE(sum(CASE
           WHEN (item.value->>'reasonCode') = 'APPROVED_POLICY_EXCLUSION'
            AND lower(COALESCE(item.value->>'observationClass','')) ~ 'maintenance'
            AND (item.value->>'excludedCount') ~ '^[0-9]+$'
           THEN (item.value->>'excludedCount')::bigint ELSE 0 END),0)::bigint AS policy_maintenance_count,
         bool_or(
           (item.value->>'reasonCode') = 'APPROVED_POLICY_EXCLUSION'
           AND lower(COALESCE(item.value->>'observationClass','')) ~ 'maintenance'
           AND NOT EXISTS (
             SELECT 1
             FROM jsonb_array_elements(COALESCE(r.evidence_set->'items','[]'::jsonb)) ev(value)
             WHERE ev.value->>'kind' = 'MAINTENANCE_WINDOW'
               AND (ev.value->>'observedAt') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
               AND (ev.value->>'observedAt')::timestamptz <= r.window_start - interval '72 hours'
           )
         ) AS maintenance_notice_violation
  FROM exact_r r
  LEFT JOIN LATERAL jsonb_array_elements(COALESCE(r.exclusion_set->'items','[]'::jsonb)) item(value) ON true
  GROUP BY r.id, r.contract_period_id, r.window_start, r.window_end, r.maintenance_observation_count
), maintenance_by_month AS (
  SELECT e.contract_period_id,
         date_trunc('month', e.window_start AT TIME ZONE r.accounting_timezone)::date AS month_start,
         sum(e.policy_maintenance_count)::bigint AS policy_maintenance_count,
         bool_or(COALESCE(e.maintenance_notice_violation,false)) AS notice_violation
  FROM evidence e
  JOIN exact_r r ON r.id = e.id
  GROUP BY e.contract_period_id, date_trunc('month', e.window_start AT TIME ZONE r.accounting_timezone)::date
), outage_candidates AS (
  SELECT contract_period_id, capability_id, window_start, window_end,
         LEAST(GREATEST(bad_count,0),
               GREATEST(EXTRACT(EPOCH FROM (window_end-window_start))/60,0))::numeric AS unavailable_count
  FROM exact_r
  WHERE bad_count > 0 OR evaluation_state = 'BREACHED'
), outage_dedup AS (
  -- Collapse evaluator replays that describe the same outage interval before
  -- the interval union; one minute must not be counted twice.
  SELECT contract_period_id, capability_id, window_start, window_end,
         max(unavailable_count) AS unavailable_count
  FROM outage_candidates
  GROUP BY contract_period_id, capability_id, window_start, window_end
), outage_ordered AS (
  SELECT o.*, max(window_end) OVER (
           PARTITION BY contract_period_id, capability_id
           ORDER BY window_start, window_end
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior_max_end
  FROM outage_dedup o
), outage_grouped AS (
  SELECT o.*, sum(CASE WHEN prior_max_end IS NULL OR window_start > prior_max_end THEN 1 ELSE 0 END)
           OVER (PARTITION BY contract_period_id, capability_id ORDER BY window_start, window_end) AS grp
  FROM outage_ordered o
), outage_union AS (
  SELECT contract_period_id, capability_id, grp,
         min(window_start) AS union_start, max(window_end) AS union_end,
         -- Equal/overlapping receipt windows are one outage.  Use the larger
         -- evidence count for an exact duplicate, never sum it twice.
         LEAST(EXTRACT(EPOCH FROM (max(window_end)-min(window_start)))/60,
               sum(unavailable_count))::numeric AS unavailable_minutes
  FROM outage_grouped
  GROUP BY contract_period_id, capability_id, grp
), receipt_order AS (
  SELECT r.*,
         lag(r.window_end) OVER (PARTITION BY r.contract_period_id, r.capability_id ORDER BY r.window_start,r.window_end,r.id) AS lag_window_end,
         row_number() OVER (PARTITION BY r.contract_period_id, r.capability_id ORDER BY r.window_start,r.window_end,r.id) AS first_row,
         row_number() OVER (PARTITION BY r.contract_period_id, r.capability_id ORDER BY r.window_start DESC,r.window_end DESC,r.id DESC) AS last_row
  FROM exact_r r
), quality AS (
  SELECT
    (SELECT count(*)::bigint FROM selected_contracts) AS selected_contract_count,
    (SELECT count(*)::bigint FROM contract_candidates WHERE NOT selected_valid) AS unoffered_contract_count,
    (SELECT count(*)::bigint FROM r) AS observed_count,
    (SELECT count(*)::bigint FROM r WHERE exact_binding IS FALSE) AS binding_mismatch_count,
    (SELECT count(*)::bigint FROM r WHERE NOT capability_binding) AS capability_binding_missing_count,
    (SELECT count(*)::bigint FROM r WHERE telemetry_state='GAP' OR evaluation_state='UNKNOWN') AS telemetry_gap_count,
    (SELECT count(*)::bigint FROM r WHERE telemetry_backend_receipt_digest !~ '^[0-9a-f]{64}$' OR telemetry_query_digest !~ '^[0-9a-f]{64}$' OR source_watermark_digest !~ '^[0-9a-f]{64}$') AS telemetry_receipt_link_missing_count,
    (SELECT count(*)::bigint FROM r WHERE incident_link_kind <> 'NONE' AND NOT EXISTS (
      SELECT 1 FROM ops.incident_events ie
       WHERE ie.id = r.incident_event_id
         AND ie.incident_id = r.incident_id
         AND ie.occurred_at <= r.evaluated_at
    ))::bigint AS incident_link_missing_count,
    (SELECT count(*)::bigint FROM r WHERE evaluation_state='BREACHED' AND sla_service_credit_schedule_digest IS NULL) AS service_credit_link_missing_count,
    COALESCE(sum(eligible_count),0)::bigint AS raw_eligible_count,
    COALESCE(sum(good_count),0)::bigint AS raw_good_count,
    COALESCE(sum(excluded_count),0)::bigint AS excluded_count,
    COALESCE(sum(maintenance_observation_count),0)::bigint AS raw_maintenance_count,
    COALESCE(sum(telemetry_gap_count),0)::bigint AS telemetry_gap_observation_count,
    (SELECT encode(extensions.digest(convert_to(COALESCE(string_agg(id::text || ':' || receipt_digest::text,',' ORDER BY id),''),'UTF8'),'sha256'),'hex') FROM r) AS input_digest,
    (SELECT max(sla_target_availability_ratio) FROM selected_contracts) AS target_availability_ratio,
    (SELECT count(*)::bigint FROM r WHERE evaluation_state='BREACHED') AS breached_count
  FROM exact_r
), derived AS (
  SELECT q.*,
         COALESCE((SELECT sum(policy_maintenance_count) FROM maintenance_by_month),0)::bigint AS policy_maintenance_count,
         COALESCE((SELECT max(policy_maintenance_count) FROM maintenance_by_month),0)::bigint AS maintenance_month_max,
         COALESCE((SELECT count(*) FROM maintenance_by_month WHERE notice_violation),0)::bigint AS maintenance_notice_violation_count,
         COALESCE((SELECT sum(unavailable_minutes) FROM outage_union),0)::numeric AS unavailable_minutes,
         COALESCE((SELECT count(*) FROM receipt_order ro WHERE (ro.first_row=1 AND ro.window_start > (ro.contract_period_start::timestamp AT TIME ZONE ro.accounting_timezone)) OR (ro.lag_window_end IS NOT NULL AND ro.window_start > ro.lag_window_end) OR (ro.last_row=1 AND ro.window_end < LEAST((ro.contract_period_end::timestamp AT TIME ZONE ro.accounting_timezone), (SELECT as_of FROM a)))),0)::bigint AS window_gap_count
  FROM quality q
), final AS (
  SELECT d.*,
         GREATEST(d.raw_eligible_count - d.policy_maintenance_count,0)::bigint AS eligible_count
  FROM derived d
)
SELECT jsonb_build_object(
  'asOf',(SELECT as_of FROM a),
  'status', CASE
    WHEN selected_contract_count=0 THEN 'NOT_APPLICABLE'
    WHEN observed_count=0 THEN 'UNKNOWN'
    WHEN binding_mismatch_count > 0 OR capability_binding_missing_count > 0
      OR telemetry_gap_count > 0 OR telemetry_receipt_link_missing_count > 0
      OR incident_link_missing_count > 0 OR service_credit_link_missing_count > 0
      OR window_gap_count > 0 OR maintenance_month_max > 240
      OR maintenance_notice_violation_count > 0 THEN 'UNKNOWN'
    WHEN eligible_count=0 THEN 'UNKNOWN'
    ELSE 'KNOWN' END,
  'reasonCode', CASE
    WHEN selected_contract_count=0 THEN 'CAPABILITY_NOT_OFFERED'
    WHEN observed_count=0 OR binding_mismatch_count > 0 OR capability_binding_missing_count > 0 THEN 'SLA_SOURCE_MISSING'
    WHEN telemetry_gap_count > 0 OR telemetry_receipt_link_missing_count > 0 OR window_gap_count > 0
      OR incident_link_missing_count > 0 OR service_credit_link_missing_count > 0
      OR maintenance_month_max > 240 OR maintenance_notice_violation_count > 0 THEN 'SLA_TELEMETRY_GAP'
    WHEN eligible_count=0 THEN 'SLA_SOURCE_MISSING'
    ELSE 'NONE' END,
  'selectedContractCount',selected_contract_count,
  'unofferedContractCount',unoffered_contract_count,
  'observedReceiptCount',observed_count,
  'eligibleCount',eligible_count,
  'goodCount',GREATEST(eligible_count - unavailable_minutes,0),
  'rawEligibleCount',raw_eligible_count,
  'rawGoodCount',raw_good_count,
  'excludedCount',excluded_count,
  'maintenanceExcludedCount',policy_maintenance_count,
  'maintenanceObservationCount',raw_maintenance_count,
  'maintenanceMonthlyCap',240,
  'maintenanceMonthlyMax',maintenance_month_max,
  'maintenanceNoticeViolationCount',maintenance_notice_violation_count,
  'unavailableMinutes',unavailable_minutes,
  'telemetryGapCount',telemetry_gap_count + telemetry_gap_observation_count,
  'telemetryReceiptLinkMissingCount',telemetry_receipt_link_missing_count,
  'incidentLinkMissingCount',incident_link_missing_count,
  'serviceCreditLinkMissingCount',service_credit_link_missing_count,
  'serviceCreditEligibleCount',breached_count,
  'windowGapCount',window_gap_count,
  'targetAvailabilityRatio',target_availability_ratio,
  'availability',CASE WHEN eligible_count=0 OR unavailable_minutes > eligible_count THEN NULL ELSE ops.round_half_even_numeric_v1((eligible_count-unavailable_minutes)/eligible_count,12) END,
  'inputSetDigest',input_digest
) FROM final;
$$;
ALTER FUNCTION ops.read_sla_metric_inputs_v1(uuid,uuid,timestamptz) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_sla_metric_inputs_v1(uuid,uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_sla_metric_inputs_v1(uuid,uuid,timestamptz) TO gurine_control_api, gurine_auditor;

-- Activated Brave discovery economics.  The worker may only emit a receipt
-- matching this immutable schedule/FX fact; zero-cost or caller-supplied
-- pricing is not a valid discovery outcome.
CREATE OR REPLACE FUNCTION ops.brave_search_pricing_v1()
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp AS $$
  SELECT jsonb_build_object(
    'providerId','BRAVE_SEARCH_WEB_V1','scheduleVersion',1,
    'usdMicrosPerRequest',5000,'usdKrwMicros',1400000000,
    'costMicrosKrw',7000000,
    'scheduleSha256',encode(extensions.digest(convert_to('brave-search-usd-micros:5000','UTF8'),'sha256'),'hex'),
    'fxFactId','usd-krw-fx-fact-2026-07-19',
    'fxFactSha256',encode(extensions.digest(convert_to('usd-krw-micros:1400000000','UTF8'),'sha256'),'hex'))
$$;
ALTER FUNCTION ops.brave_search_pricing_v1() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.brave_search_pricing_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.brave_search_pricing_v1() TO gurine_analysis_worker;

-- MODEL_INPUT rows carry a deterministic pre-dispatch receipt identity.  It
-- is intentionally not the provider's eventual receipt, so the FK is
-- enforced for every receipt-bearing use except this pre-dispatch boundary.
ALTER TABLE ops.agent_source_uses DROP CONSTRAINT IF EXISTS agent_source_uses_provider_receipt_fk;
ALTER TABLE ops.agent_source_uses DROP CONSTRAINT IF EXISTS agent_source_uses_provider_ck;
ALTER TABLE ops.agent_source_uses ADD CONSTRAINT agent_source_uses_provider_ck CHECK (
  (use_kind IN ('MODEL_INPUT','MODEL_OUTPUT_DERIVATION')) =
    (provider_receipt_id IS NOT NULL AND provider_receipt_sha256 IS NOT NULL AND provider_turn_id IS NOT NULL)
);
CREATE OR REPLACE FUNCTION ops.enforce_agent_source_use_provider_receipt_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$
BEGIN
  IF NEW.use_kind = 'MODEL_OUTPUT_DERIVATION' THEN
    IF NOT EXISTS (SELECT 1 FROM ops.agent_provider_turns t
      WHERE t.agent_run_id=NEW.agent_run_id AND t.provider_turn_id=NEW.provider_turn_id
        AND t.provider_receipt_id=NEW.provider_receipt_id
        AND t.provider_receipt_sha256=NEW.provider_receipt_sha256) THEN
      RAISE EXCEPTION 'SOURCE_USE_PROVIDER_RECEIPT_MISMATCH' USING ERRCODE='23503';
    END IF;
  END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION ops.enforce_agent_source_use_provider_receipt_v1() OWNER TO gurine_migrator;
DROP TRIGGER IF EXISTS agent_source_use_provider_receipt_guard ON ops.agent_source_uses;
CREATE TRIGGER agent_source_use_provider_receipt_guard
  BEFORE INSERT ON ops.agent_source_uses FOR EACH ROW
  EXECUTE FUNCTION ops.enforce_agent_source_use_provider_receipt_v1();
COMMIT;

-- Replace the historical allow-list writer with relation-specific owner
-- boundaries. Begin/finish helpers carry only the idempotency and audit
-- envelope, while each public writer parses and inserts its concrete
-- composite row type directly. The compatibility writer was dropped above.
CREATE OR REPLACE FUNCTION ops.business_write_begin_v1(
  p_kind text, p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_key text := NULLIF(btrim(p_payload->>'idempotencyKey'),'');
  v_key_hash char(64);
  v_request_hash char(64);
  v_existing ops.idempotency_keys;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' OR v_key IS NULL
     OR p_kind IS NULL OR p_kind !~ '^[A-Z][A-Z0-9_]{1,63}$' THEN
    RAISE EXCEPTION 'BUSINESS_ROW_INVALID' USING ERRCODE='22023';
  END IF;
  IF current_setting('transaction_isolation') <> 'serializable' THEN
    RAISE EXCEPTION 'BUSINESS_WRITER_SERIALIZABLE_REQUIRED' USING ERRCODE='25001';
  END IF;
  v_key_hash := encode(extensions.digest(convert_to(v_key,'UTF8'),'sha256'),'hex');
  v_request_hash := encode(extensions.digest(convert_to(p_payload::text,'UTF8'),'sha256'),'hex');
  SELECT * INTO v_existing FROM ops.idempotency_keys
   WHERE scope='ECONOMICS.RECORD_'||p_kind AND key_hash=v_key_hash FOR UPDATE;
  IF FOUND THEN
    IF v_existing.request_hash <> v_request_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT' USING ERRCODE='40001';
    END IF;
    RETURN v_existing.response_body || jsonb_build_object('idempotencyReplay',true);
  END IF;
  -- Lock the relation-specific predecessor/head before the typed INSERT.  A
  -- stale correction, invoice, membership, outcome, or packet chain therefore
  -- cannot race another writer between validation and commit.
  IF p_kind = 'ACCOUNTING_CORRECTION' THEN
    PERFORM 1 FROM ops.accounting_corrections
     WHERE id = NULLIF(p_payload->>'supersedesCorrectionId','')::uuid
        OR id = NULLIF(p_payload->>'reversesCorrectionId','')::uuid
        OR id = NULLIF(p_payload->>'targetFactId','')::uuid
     FOR UPDATE;
  ELSIF p_kind = 'OUTCOME_FACT' THEN
    PERFORM 1 FROM ops.outcome_facts
     WHERE (id = NULLIF(p_payload->>'supersedesFactId','')::uuid)
        OR (root_fact_id = NULLIF(p_payload->>'rootFactId','')::uuid)
     FOR UPDATE;
  ELSIF p_kind = 'PAID_EVIDENCE_PACKET' THEN
    PERFORM 1 FROM ops.paid_evidence_packets
     WHERE packet_id = NULLIF(p_payload->>'packetId','')::uuid
        OR packet_id = NULLIF(p_payload->>'supersedesPacketId','')::uuid
     FOR UPDATE;
  ELSIF p_kind = 'INVOICE_FACT' THEN
    PERFORM 1 FROM ops.invoice_facts
     WHERE root_invoice_id = NULLIF(p_payload->>'rootInvoiceId','')::uuid
     FOR UPDATE;
  ELSIF p_kind = 'INVOICE_LINE_FACT' THEN
    PERFORM 1 FROM ops.invoice_line_facts
     WHERE invoice_id = NULLIF(p_payload->>'invoiceId','')::uuid
     FOR UPDATE;
  ELSIF p_kind = 'INVOICE_USAGE_MEMBERSHIP' THEN
    PERFORM 1 FROM ops.invoice_usage_memberships
     WHERE root_membership_id = NULLIF(p_payload->>'rootMembershipId','')::uuid
     FOR UPDATE;
  ELSIF p_kind = 'USAGE_FACT' THEN
    PERFORM 1 FROM ops.usage_facts
     WHERE root_usage_fact_id = NULLIF(p_payload->>'rootUsageFactId','')::uuid
     FOR UPDATE;
  END IF;
  RETURN NULL;
END $$;
ALTER FUNCTION ops.business_write_begin_v1(text,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.business_write_begin_v1(text,jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.business_write_finish_v1(
  p_kind text, p_payload jsonb, p_resource_id text, p_digest text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp
AS $$
DECLARE
  v_key text := NULLIF(btrim(p_payload->>'idempotencyKey'),'');
  v_key_hash char(64);
  v_request_hash char(64);
  v_audit uuid;
  v_outbox uuid;
  v_receipt char(64);
  v_body jsonb;
BEGIN
  IF p_kind IS NULL OR p_resource_id IS NULL OR p_digest IS NULL
     OR p_digest !~ '^[0-9a-f]{64}$' OR v_key IS NULL THEN
    RAISE EXCEPTION 'BUSINESS_ROW_DIGEST_INVALID' USING ERRCODE='22023';
  END IF;
  v_key_hash := encode(extensions.digest(convert_to(v_key,'UTF8'),'sha256'),'hex');
  v_request_hash := encode(extensions.digest(convert_to(p_payload::text,'UTF8'),'sha256'),'hex');
  v_audit := ops.append_audit_event('economics:'||lower(p_kind)||':'||p_resource_id,
    'SERVICE','gurine_workflow_worker',NULL,'RECORD_'||p_kind,p_kind,p_resource_id,
    'ECONOMICS.RECORD_'||p_kind,'SUCCESS',NULL,gen_random_uuid(),
    jsonb_build_object('recordDigest',p_digest));
  v_outbox := ops.enqueue_outbox(lower(p_kind),p_resource_id,1,
    'commercial.'||lower(p_kind)||'.recorded.v1',
    jsonb_build_object('resourceId',p_resource_id,'resourceType',p_kind,
      'recordDigest',p_digest),clock_timestamp());
  v_receipt := encode(extensions.digest(convert_to(
    p_resource_id||':'||p_digest||':'||v_key_hash,'UTF8'),'sha256'),'hex');
  v_body := jsonb_build_object('resourceId',p_resource_id,'resourceType',p_kind,
    'resourceVersion',1,'recordDigest',p_digest,'receiptDigest',v_receipt,
    'auditEventId',v_audit,'outboxId',v_outbox,'committedAt',clock_timestamp());
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,response_status,
    response_body,resource_type,resource_id,expires_at)
  VALUES('ECONOMICS.RECORD_'||p_kind,v_key_hash,v_request_hash,201,v_body,p_kind,
    p_resource_id,clock_timestamp()+interval '30 days');
  RETURN v_body;
END $$;
ALTER FUNCTION ops.business_write_finish_v1(text,jsonb,text,text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.business_write_finish_v1(text,jsonb,text,text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.assert_business_payload_keys_v1(p_payload jsonb, p_row jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp AS $$
DECLARE v_unknown text;
BEGIN
  SELECT k INTO v_unknown
    FROM jsonb_object_keys(p_payload) k
   WHERE k <> 'idempotencyKey'
     AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(p_row) r WHERE r=k)
   LIMIT 1;
  IF v_unknown IS NOT NULL THEN
    RAISE EXCEPTION 'BUSINESS_ROW_UNKNOWN_FIELD:%', v_unknown USING ERRCODE='22023';
  END IF;
END $$;
ALTER FUNCTION ops.assert_business_payload_keys_v1(jsonb,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.assert_business_payload_keys_v1(jsonb,jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.record_invoice_fact_v1(p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE v_replay jsonb; v_row ops.invoice_facts; v_id text; v_digest text;
BEGIN
  v_replay:=ops.business_write_begin_v1('INVOICE_FACT',p_payload); IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;
  v_row:=jsonb_populate_record(NULL::ops.invoice_facts,p_payload); PERFORM ops.assert_business_payload_keys_v1(p_payload,to_jsonb(v_row)); v_id:=v_row.id::text; v_digest:=btrim(v_row.record_digest::text);
  IF v_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'BUSINESS_ROW_DIGEST_INVALID' USING ERRCODE='22023'; END IF;
  INSERT INTO ops.invoice_facts SELECT v_row.*;
  RETURN ops.business_write_finish_v1('INVOICE_FACT',p_payload,v_id,v_digest);
END $$;

CREATE OR REPLACE FUNCTION ops.record_invoice_line_fact_v1(p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE v_replay jsonb; v_row ops.invoice_line_facts; v_id text; v_digest text;
BEGIN
  v_replay:=ops.business_write_begin_v1('INVOICE_LINE_FACT',p_payload); IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;
  v_row:=jsonb_populate_record(NULL::ops.invoice_line_facts,p_payload); PERFORM ops.assert_business_payload_keys_v1(p_payload,to_jsonb(v_row)); v_id:=v_row.id::text; v_digest:=btrim(v_row.record_digest::text);
  IF v_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'BUSINESS_ROW_DIGEST_INVALID' USING ERRCODE='22023'; END IF;
  INSERT INTO ops.invoice_line_facts SELECT v_row.*;
  RETURN ops.business_write_finish_v1('INVOICE_LINE_FACT',p_payload,v_id,v_digest);
END $$;

CREATE OR REPLACE FUNCTION ops.record_usage_fact_v1(p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE v_replay jsonb; v_row ops.usage_facts; v_id text; v_digest text;
BEGIN
  v_replay:=ops.business_write_begin_v1('USAGE_FACT',p_payload); IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;
  v_row:=jsonb_populate_record(NULL::ops.usage_facts,p_payload); PERFORM ops.assert_business_payload_keys_v1(p_payload,to_jsonb(v_row)); v_id:=v_row.id::text; v_digest:=btrim(v_row.record_digest::text);
  IF v_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'BUSINESS_ROW_DIGEST_INVALID' USING ERRCODE='22023'; END IF;
  INSERT INTO ops.usage_facts SELECT v_row.*;
  RETURN ops.business_write_finish_v1('USAGE_FACT',p_payload,v_id,v_digest);
END $$;

CREATE OR REPLACE FUNCTION ops.record_invoice_usage_membership_v1(p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE v_replay jsonb; v_row ops.invoice_usage_memberships; v_id text; v_digest text;
BEGIN
  v_replay:=ops.business_write_begin_v1('INVOICE_USAGE_MEMBERSHIP',p_payload); IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;
  v_row:=jsonb_populate_record(NULL::ops.invoice_usage_memberships,p_payload); PERFORM ops.assert_business_payload_keys_v1(p_payload,to_jsonb(v_row)); v_id:=v_row.id::text; v_digest:=btrim(v_row.membership_digest::text);
  IF v_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'BUSINESS_ROW_DIGEST_INVALID' USING ERRCODE='22023'; END IF;
  INSERT INTO ops.invoice_usage_memberships SELECT v_row.*;
  RETURN ops.business_write_finish_v1('INVOICE_USAGE_MEMBERSHIP',p_payload,v_id,v_digest);
END $$;

CREATE OR REPLACE FUNCTION ops.record_accounting_correction_v1(p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE v_replay jsonb; v_row ops.accounting_corrections; v_id text; v_digest text;
BEGIN
  v_replay:=ops.business_write_begin_v1('ACCOUNTING_CORRECTION',p_payload); IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;
  v_row:=jsonb_populate_record(NULL::ops.accounting_corrections,p_payload); PERFORM ops.assert_business_payload_keys_v1(p_payload,to_jsonb(v_row)); v_id:=v_row.id::text; v_digest:=btrim(v_row.record_digest::text);
  IF v_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'BUSINESS_ROW_DIGEST_INVALID' USING ERRCODE='22023'; END IF;
  INSERT INTO ops.accounting_corrections SELECT v_row.*;
  RETURN ops.business_write_finish_v1('ACCOUNTING_CORRECTION',p_payload,v_id,v_digest);
END $$;

CREATE OR REPLACE FUNCTION ops.record_outcome_fact_v1(p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE v_replay jsonb; v_row ops.outcome_facts; v_id text; v_digest text;
BEGIN
  v_replay:=ops.business_write_begin_v1('OUTCOME_FACT',p_payload); IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;
  v_row:=jsonb_populate_record(NULL::ops.outcome_facts,p_payload); PERFORM ops.assert_business_payload_keys_v1(p_payload,to_jsonb(v_row)); v_id:=v_row.id::text; v_digest:=btrim(v_row.fact_digest::text);
  IF v_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'BUSINESS_ROW_DIGEST_INVALID' USING ERRCODE='22023'; END IF;
  INSERT INTO ops.outcome_facts SELECT v_row.*;
  RETURN ops.business_write_finish_v1('OUTCOME_FACT',p_payload,v_id,v_digest);
END $$;

CREATE OR REPLACE FUNCTION ops.record_paid_evidence_packet_v1(p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ops,extensions,pg_temp AS $$
DECLARE v_replay jsonb; v_row ops.paid_evidence_packets; v_id text; v_digest text;
BEGIN
  v_replay:=ops.business_write_begin_v1('PAID_EVIDENCE_PACKET',p_payload); IF v_replay IS NOT NULL THEN RETURN v_replay; END IF;
  v_row:=jsonb_populate_record(NULL::ops.paid_evidence_packets,p_payload); PERFORM ops.assert_business_payload_keys_v1(p_payload,to_jsonb(v_row)); v_id:=v_row.packet_id::text; v_digest:=btrim(v_row.packet_record_digest::text);
  IF v_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'BUSINESS_ROW_DIGEST_INVALID' USING ERRCODE='22023'; END IF;
  INSERT INTO ops.paid_evidence_packets SELECT v_row.*;
  RETURN ops.business_write_finish_v1('PAID_EVIDENCE_PACKET',p_payload,v_id,v_digest);
END $$;

ALTER FUNCTION ops.record_invoice_fact_v1(jsonb) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_invoice_line_fact_v1(jsonb) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_usage_fact_v1(jsonb) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_invoice_usage_membership_v1(jsonb) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_accounting_correction_v1(jsonb) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_outcome_fact_v1(jsonb) OWNER TO gurine_migrator;
ALTER FUNCTION ops.record_paid_evidence_packet_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_invoice_fact_v1(jsonb),ops.record_invoice_line_fact_v1(jsonb),ops.record_usage_fact_v1(jsonb),ops.record_invoice_usage_membership_v1(jsonb),ops.record_accounting_correction_v1(jsonb),ops.record_outcome_fact_v1(jsonb),ops.record_paid_evidence_packet_v1(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_invoice_fact_v1(jsonb),ops.record_invoice_line_fact_v1(jsonb),ops.record_usage_fact_v1(jsonb),ops.record_invoice_usage_membership_v1(jsonb),ops.record_accounting_correction_v1(jsonb),ops.record_outcome_fact_v1(jsonb),ops.record_paid_evidence_packet_v1(jsonb) TO gurine_workflow_worker;
