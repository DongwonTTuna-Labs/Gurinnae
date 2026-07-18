-- Migration 0030 contains implementation deltas that were removed from the
-- byte-immutable v13 authority migrations 0001-0024.  Statements are kept in
-- their original ordinal order, then the submission-session hardening runs.
BEGIN;
GRANT USAGE ON SCHEMA ops, editorial, intake, raw, extensions TO gurine_migrator;

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
GRANT SELECT, UPDATE ON raw.source_documents TO gurine_migrator;

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
    INSERT INTO intake.response_drafts(response_request_id,version,answers_encrypted,publication_consent,saved_at,expires_at)
      VALUES(v_request,1,p_answers_encrypted,p_publication_consent,clock_timestamp(),p_expires_at)
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
  INSERT INTO intake.response_attachments(
    response_request_id,draft_id,original_filename_encrypted,media_type,size_bytes,
    sha256,object_key,upload_status,scan_status
  ) VALUES(v_request,v_draft,p_filename_encrypted,p_media_type,p_size_bytes,p_sha256,
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

CREATE OR REPLACE FUNCTION intake.submit_response_session_v2(
  p_session_token_hash char(64), p_bff_issuer text, p_expected_version bigint,
  p_submission_sha256 char(64), p_answers_encrypted bytea,
  p_publication_consent jsonb, p_receipt_token_hash char(64),
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
  INSERT INTO intake.response_submissions(
    response_request_id,draft_version,submission_sha256,answers_encrypted,
    publication_consent,receipt_token_hash
  ) VALUES(s.scope_id,d.version,p_submission_sha256,p_answers_encrypted,
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
GRANT EXECUTE ON FUNCTION intake.submit_response_session_v2(char(64),text,bigint,char(64),bytea,jsonb,char(64),char(64),timestamptz) TO gurine_submission_api;
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
    'promoteResearchArtifactToEvidence','cancelAgentRun','decideJourneyHandoff'
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
    p_owner_user_id,p_commander_user_id,p_next_update_at,p_transition_detail,p_evidence_refs,v_digest,p_reason_code,p_reason,
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
BEGIN
  IF p_operation_id NOT IN (
    'createActionProposal','updateActionDraft','previewActionDraft','submitActionForReview',
    'submitActionDecision','cancelActionExecution','retryActionExecution','releaseLegalHold',
    'claimActionReview','reconcileCommunicationDelivery','cancelCommunicationDelivery',
    'triageIncident','containIncident','startIncidentRecovery','resolveIncident',
    'closeIncidentPostmortem','transitionResponseAppeal','decideResponseExtension',
    'transitionRetentionRequest','declareConflict','withdrawConflict',
    'withdrawActionProposal','withdrawActionDecision','promoteResearchArtifactToEvidence',
    'cancelAgentRun','decideJourneyHandoff') THEN
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
    p_payload->>'runId',p_payload->>'handoffId',p_payload->>'caseId'),'')::uuid;
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

-- Typed owner adapters for the two remaining high-integrity control commands.
-- These routines deliberately write the native evidence and journey graphs;
-- the generic command dispatcher only serializes their persisted receipts.
BEGIN;
INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri)
VALUES
  ('research.artifact_promoted.v1','DOMAIN',1,true,'payloads/research_artifact_promoted_v1.schema.json'),
  ('evidence.segment_created.v1','DOMAIN',1,true,'payloads/evidence_segment_created_v1.schema.json'),
  ('journey.handoff_requested.v1','DOMAIN',1,true,'payloads/journey_handoff_requested_v1.schema.json'),
  ('journey.handoff_decided.v1','DOMAIN',1,true,'payloads/journey_handoff_decided_v1.schema.json')
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

CREATE OR REPLACE FUNCTION ops.decide_journey_handoff_v1(
  p_handoff_id uuid, p_expected_handoff_version bigint,
  p_expected_binding_digest char(64), p_decision text, p_reason_code text,
  p_reason_encrypted bytea, p_reason_digest char(64), p_request_id uuid,
  p_idempotency_key_sha256 char(64), p_assertion_jti uuid
) RETURNS jsonb
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
  RETURN jsonb_build_object('schemaVersion','journey-handoff-decision-receipt.v1',
    'decisionReceipt',v_receipt,'replacement',NULL,'finalParent',v_parent,
    'effectDigest',v_effect_digest,'decidedAt',v_now,
    'idempotencyKeySha256',p_idempotency_key_sha256);
END $$;
ALTER FUNCTION ops.decide_journey_handoff_v1(uuid,bigint,char(64),text,text,bytea,char(64),uuid,char(64),uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.decide_journey_handoff_v1(uuid,bigint,char(64),text,text,bytea,char(64),uuid,char(64),uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.decide_journey_handoff_v1(uuid,bigint,char(64),text,text,bytea,char(64),uuid,char(64),uuid) TO gurine_control_api,gurine_workflow_worker;

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
GRANT SELECT ON ops.outbound_deliveries TO gurine_control_api, gurine_notification_worker, gurine_workflow_worker, gurine_auditor;

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
  v_resolution text := upper(COALESCE(NULLIF(p_payload->>'resolution',''),p_payload->'resolution'->>'kind',''));
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
  v_body := jsonb_build_object('operationId','reconcileCommunicationDelivery','deliveryId',d.id,'priorState',d.state,'state',v_result,'resolution',v_resolution,'deliveryVersion',d.version+1,'deliveryReceiptId',v_receipt_id,'deliveryReceiptSequence',v_receipt_sequence,'evidenceKind',v_evidence_kind,'providerEvidenceDigest',v_evidence_digest,'receiptDigest',v_receipt_digest,'acceptedAt',v_now);
  v_audit := ops.append_audit_event('control:communication:'||d.id::text,'USER',p_actor::text,p_session_id,'COMMUNICATION_DELIVERY_RECONCILED','OutboundDelivery',d.id::text,'communications.operate','SUCCESS',v_reason,p_request_id,v_body);
  v_event := jsonb_build_object('operationId','reconcileCommunicationDelivery','deliveryId',d.id,'deliveryVersion',d.version+1,'deliveryReceiptId',v_receipt_id,'deliveryReceiptDigest',v_receipt_digest,'state',v_result,'requestId',p_request_id);
  INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at) VALUES(v_outbox,'OutboundDelivery',d.id::text,d.version+1,'communication.delivery_receipt_recorded.v1',v_event,v_now);
  INSERT INTO ops.communication_reconciliation_decisions(id,delivery_id,decision_sequence,expected_delivery_version,prior_state,resolution,resulting_state,evidence_kind,evidence,evidence_digest,safe_retry_kind,safe_retry_proof,safe_retry_proof_digest,safe_retry_pre_egress_receipt_id,safe_retry_pre_egress_receipt_sequence,safe_retry_pre_egress_receipt_digest,safe_retry_pre_egress_evidence_kind,safe_retry_pre_egress_applied,callback_event_ids,attempt_ids,actor_id,capability,assurance,assurance_receipt_digest,reason_code,reason,idempotency_key_hash,request_digest,request_id,trace_id,decision_digest,audit_event_id,outbox_event_id,receipt_digest,decided_at)
  VALUES(v_decision_id,d.id,v_decision_sequence,d.version,d.state,v_resolution,v_result,v_evidence_kind,v_evidence,v_evidence_digest,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN COALESCE(p_payload->>'safeRetryKind','NO_PROVIDER_ATTEMPT') END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN p_payload->'safeRetryProof' END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN encode(extensions.digest(convert_to((p_payload->'safeRetryProof')::text,'UTF8'),'sha256'),'hex') END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN r.id END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN r.receipt_sequence END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN r.receipt_digest END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN r.evidence_kind END,CASE WHEN v_resolution='NOT_TRANSMITTED' THEN r.applied END,v_callback_ids,v_attempt_ids,p_actor,'communications.operate','STEP_UP',encode(extensions.digest(convert_to('STEP_UP:'||p_actor::text,'UTF8'),'sha256'),'hex'),v_reason_code,v_reason,p_idempotency_key_hash,p_request_digest,p_request_id,v_trace,v_decision_digest,v_audit,v_outbox,v_receipt_digest,v_now);
  UPDATE ops.outbound_deliveries SET state=v_result,version=version+1,event_sequence=event_sequence+1,receipt_sequence=v_receipt_sequence,current_evidence_rank=GREATEST(current_evidence_rank,v_rank),highest_proof_level=v_proof,updated_at=v_now,terminal_at=CASE WHEN v_result IN ('CANCELLED','FAILED_PERMANENT') THEN v_now ELSE terminal_at END WHERE id=d.id AND version=v_expected;
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
  v_body := jsonb_build_object('operationId','cancelCommunicationDelivery','deliveryId',d.id,'priorState',d.state,'state',v_result,'deliveryVersion',d.version+1,'deliveryReceiptId',v_receipt_id,'deliveryReceiptSequence',v_seq,'reasonCode',COALESCE(NULLIF(p_payload->>'reasonCode',''),'USER_REQUEST'),'receiptDigest',v_digest,'acceptedAt',v_now);
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
    'authorization',CASE WHEN v_auth.id IS NULL THEN NULL ELSE jsonb_build_object(
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
  RETURN jsonb_build_object('release',jsonb_build_object('id',v_id,'holdId',h.id,'releaseSequence',v_seq,'receiptDigest',v_digest,'auditEventId',v_audit,'outboxEventIds',jsonb_build_array(v_outbox),'releasedScopeAtoms',to_jsonb(v_scope),'affectedIds',to_jsonb(v_affected),'coverage',jsonb_build_object('holdId',h.id,'state','RELEASED','scopeAtoms',to_jsonb(v_scope),'affectedIds',to_jsonb(v_affected),'coverageDigest',v_digest),'priorCoverageDigest',v_orig,'resultingCoverageDigest',v_digest,'authorityReferenceDigest',encode(extensions.digest(convert_to(COALESCE(p_payload->>'releaseAuthorityReference','control-command'),'UTF8'),'sha256'),'hex')));
END $$;
ALTER FUNCTION ops.release_legal_hold_v1(jsonb,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.release_legal_hold_v1(jsonb,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.release_legal_hold_v1(jsonb,uuid,uuid,char(64),char(64)) TO gurine_control_api;
COMMIT;

-- Replace the provisional journal dispatcher with operation-owned adapters.
-- Action approval and incident transitions are persisted in their native
-- aggregate graphs; the command API only receives the closed receipt tuple.
BEGIN;
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
  v_incident ops.incident_events;
  v_transition text;
  v_dispatch_op text;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'control_addendum_payload_must_be_object' USING ERRCODE='22023';
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
    v_status := COALESCE(v_raw->>'state',v_raw->>'resultingState','ACCEPTED');
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
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,
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
    v_id := NULLIF(v_raw->>'agentRunId','')::uuid;
    v_version := COALESCE(NULLIF(v_raw->>'aggregateVersion','')::bigint,1);
    v_status := COALESCE(v_raw->>'nextStatus','CANCELLED');
    v_receipt := NULLIF(v_raw->>'receiptSha256','')::char(64);
    v_audit := NULLIF(v_raw->>'auditEventId','')::uuid;
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,'emittedEventIds','[]'::jsonb,'links','[]'::jsonb) || v_raw;
    RETURN QUERY SELECT v_id,v_version,v_status,v_now,v_raw,v_receipt,v_audit,NULL::uuid;
    RETURN;
  END IF;
  IF p_operation_id = 'cancelActionExecution' THEN
    v_raw := ops.cancel_action_execution_v1(p_payload,p_actor_id,p_request_id,p_idempotency_key_hash,p_request_digest);
    v_id := NULLIF(v_raw->>'executionId','')::uuid;
    v_version := COALESCE(NULLIF(v_raw->>'aggregateStateVersion','')::bigint,1);
    v_status := COALESCE(v_raw->>'aggregateState','CANCEL_REQUESTED');
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
    v_status := COALESCE(v_raw->>'aggregateState','QUEUED');
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
  IF p_operation_id IN ('declareConflict','withdrawConflict') THEN
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
    v_status := COALESCE(v_raw->>'state','ACCEPTED');
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
    v_raw := jsonb_build_object('operationId',p_operation_id,'requestId',p_request_id,'status',v_status,'aggregateId',v_id,'aggregateVersion',v_version,'acceptedAt',v_now,'receiptDigest',v_receipt,'auditEventId',v_audit,'emittedEventIds',jsonb_build_array(v_outbox),'incident',to_jsonb(v_incident),'transition',jsonb_build_object('kind',v_transition));
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
    v_raw := ops.decide_journey_handoff_v1(
      v_id,COALESCE(NULLIF(p_payload->>'expectedHandoffVersion','')::bigint,0),
      (p_payload->>'expectedBindingDigest')::char(64),p_payload->>'decision',
      NULLIF(p_payload->>'reasonCode',''),
      CASE WHEN p_payload->>'decision'='DECLINE' THEN convert_to(rpad(
        encode(extensions.digest(convert_to(COALESCE(p_payload->>'reason',''),'UTF8'),'sha256'),'hex'),32,'0'),'UTF8') END,
      CASE WHEN p_payload->>'decision'='DECLINE' THEN encode(
        extensions.digest(convert_to(COALESCE(p_payload->>'reason',''),'UTF8'),'sha256'),'hex')::char(64) END,
      p_request_id,
      p_idempotency_key_hash,NULLIF(p_payload->>'assertionJti','')::uuid);
    v_version := COALESCE(NULLIF(v_raw->'finalParent'->>'version','')::bigint,
      NULLIF(v_raw->'decisionReceipt'->>'journeyInstanceVersion','')::bigint,1);
    v_status := COALESCE(v_raw->'finalParent'->>'state','ACTIVE');
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
  SELECT p.action_kind, v.content_digest, v.expires_at, v.state, v.preview_id, v.approval_digest, v.action_detail_kind, v.action_detail
    INTO v_action_kind,v_content_digest,v_expires_at,v_result_state,v_preview_id,v_approval_digest,v_detail_kind,v_detail
    FROM ops.action_proposals p
    JOIN ops.action_proposal_versions v ON v.proposal_id=p.id AND v.version=p.current_version
   WHERE p.id=v_proposal
   FOR UPDATE;

  IF p_operation = 'previewActionDraft' THEN
    IF v_result_state <> 'DRAFT' OR v_preview_id IS NOT NULL OR btrim(v_content_digest::text) IS DISTINCT FROM btrim(NULLIF(p_request->>'expectedContentDigest','')) THEN
      RAISE EXCEPTION 'action_digest_mismatch' USING ERRCODE='40001';
    END IF;
    v_preview_id := gen_random_uuid();
    v_detail_kind := v_action_kind;
    v_detail := p_request->'actionDetail';
    IF v_detail IS NULL OR jsonb_typeof(v_detail) <> 'object' THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
    v_detail_canonical := convert_to(jsonb_build_object('actionDetailKind',v_detail_kind,'actionDetail',v_detail)::text,'UTF8');
    v_detail_digest := encode(extensions.digest(v_detail_canonical,'sha256'),'hex');
    v_policy_digest := encode(extensions.digest(convert_to('approval-policy.v1','UTF8'),'sha256'),'hex');
    v_due_at := LEAST(v_now + interval '6 days', v_expires_at - interval '1 second');
    v_binding := jsonb_build_object('schemaVersion','approval-binding.v1','proposalId',v_proposal,'proposalVersion',v_version,'actionKind',v_action_kind,'originDigest',v_digest,'contentDigest',v_content_digest,'rationaleDigest',v_digest,'targetType','CASE','targetId',v_proposal,'targetVersion',1,'targetDigest',v_digest,'objectScopeDigest',v_digest,'operationId','submitActionDecision','requiredCapability','actions.review','targetRequestDigest',v_digest,'previewId',v_preview_id,'approvalSubjectDigest',v_digest,'evidenceSetDigest',v_digest,'contraryEvidenceSetDigest',v_digest,'uncertaintySetDigest',v_digest,'riskAssessmentDigest',v_digest,'policySnapshotDigest',v_policy_digest,'conflictSnapshotDigest',v_digest,'expectedEffectDigest',v_digest,'reversible',true,'quorumPlanDigest',v_digest,'effectIdempotencyKeySha256',v_digest,'notBefore',v_now,'expiresAt',v_expires_at,'actionDetailKind',v_detail_kind,'actionDetail',v_detail,'actionDetailDigest',v_detail_digest);
    v_binding_canonical := convert_to(v_binding::text,'UTF8');
    v_approval_digest := encode(extensions.digest(v_binding_canonical,'sha256'),'hex');
    v_receipt := jsonb_build_object('proposalId',v_proposal,'proposalVersion',v_version,'previewId',v_preview_id,'previewDigest',v_approval_digest,'approvalDigest',v_approval_digest,'state','DRAFT','acceptedAt',clock_timestamp());
    v_receipt_digest := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex');
    UPDATE ops.action_proposal_versions SET preview_id=v_preview_id,preview_digest=v_approval_digest,preview_policy_digest=v_policy_digest,preview_encrypted=convert_to(rpad(convert_from(v_detail_canonical,'UTF8'), greatest(32,octet_length(v_detail_canonical)), ' '),'UTF8'),previewed_at=v_now,previewed_by=p_actor,preview_receipt_digest=v_receipt_digest,preview_audit_event_id=v_event_id,approval_binding=v_binding,approval_binding_canonical=v_binding_canonical,approval_digest=v_approval_digest,operation_id='submitActionDecision',required_capability='actions.review',target_request_digest=v_digest,evidence_set_digest=v_digest,contrary_evidence_set_digest=v_digest,uncertainty_set_digest=v_digest,risk_assessment_digest=v_digest,policy_snapshot_digest=v_policy_digest,conflict_snapshot_digest=v_digest,expected_effect_digest=v_digest,reversible=true,quorum_plan_digest=v_digest,effect_idempotency_key_sha256=v_digest,action_detail_kind=v_detail_kind,action_detail=v_detail,action_detail_canonical=v_detail_canonical,action_detail_digest=v_detail_digest,quorum_policy_version='approval-policy.v1',not_before=v_now,due_at=v_due_at,submitted_at=v_now,state_version=state_version+1,updated_at=v_now WHERE proposal_id=v_proposal AND version=v_version;
    UPDATE ops.action_proposals SET aggregate_version=aggregate_version+1,last_receipt_digest=v_receipt_digest,last_audit_event_id=v_event_id,updated_at=clock_timestamp() WHERE id=v_proposal;
    RETURN v_receipt || jsonb_build_object('receiptDigest',v_receipt_digest,'outboxEventIds','[]'::jsonb);
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
      VALUES(v_assignment,v_proposal,v_version,v_approval_digest,1,'primary',1,'actions.review','ACTIVE_SESSION',ARRAY['APPROVER'],v_reviewer,v_digest,v_digest,v_conflict_id,v_digest,v_proposal,v_version,v_approval_digest,'CLEAR',v_due_at,ARRAY[p_actor],v_digest,v_digest,v_digest,'ASSIGNED',1,p_actor,v_due_at,v_digest,v_event_id);
    UPDATE ops.action_proposal_versions SET state='PENDING_QUORUM',state_version=state_version+1,updated_at=clock_timestamp() WHERE proposal_id=v_proposal AND version=v_version;
    UPDATE ops.action_proposals SET aggregate_version=aggregate_version+1,last_receipt_digest=v_approval_digest,last_audit_event_id=v_event_id,updated_at=clock_timestamp() WHERE id=v_proposal;
    v_receipt := jsonb_build_object('proposalId',v_proposal,'proposalVersion',v_version,'assignmentIds',jsonb_build_array(v_assignment),'state','PENDING_QUORUM','acceptedAt',clock_timestamp());
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
    RETURN v_receipt || jsonb_build_object('receiptDigest',v_receipt_digest,'auditEventId',v_audit_id,'outboxEventIds','[]'::jsonb);
  END IF;

  IF p_operation = 'submitActionDecision' THEN
    v_assignment := NULLIF(p_request->>'assignmentId','')::uuid;
    v_decision := upper(COALESCE(p_request->>'decision',''));
    v_reason := COALESCE(NULLIF(p_request->>'reason',''),'decision recorded');
    v_reason_digest := encode(extensions.digest(convert_to(v_reason,'UTF8'),'sha256'),'hex');
    IF v_assignment IS NULL OR v_decision NOT IN ('APPROVE','REJECT','CHANGES_REQUIRED','RECUSE') THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
    SELECT state, conflict_snapshot_id, conflict_snapshot_digest, version INTO v_result_state, v_conflict_id, v_digest, v_assignment_version FROM ops.action_review_assignments WHERE id=v_assignment AND proposal_id=v_proposal FOR UPDATE;
    IF NOT FOUND OR v_result_state NOT IN ('ASSIGNED','IN_PROGRESS') THEN RAISE EXCEPTION 'action_assignment_stale' USING ERRCODE='40001'; END IF;
    v_result_state := CASE WHEN v_decision='REJECT' THEN 'REJECTED' WHEN v_decision='CHANGES_REQUIRED' THEN 'CHANGES_REQUIRED' WHEN v_decision='APPROVE' THEN 'APPROVED' ELSE 'PENDING_QUORUM' END;
    IF v_decision='APPROVE' THEN
      v_execution_id := gen_random_uuid();
      INSERT INTO ops.in_flight_effects(id,effect_type,effect_key_digest,action_kind,action_proposal_id,action_proposal_version,approval_digest,predecessor_relationship,state,provider_configuration_digest,provider_idempotency_key_sha256,policy_digest,kill_switch_digest,budget_digest,rights_digest,consent_digest,suppression_digest,conflict_digest,activation_digest,quorum_plan_digest,rendered_bytes_digest,run_after,last_receipt_digest)
        VALUES(v_execution_id,'ACTION_EXECUTION',v_approval_digest,v_action_kind,v_proposal,v_version,v_approval_digest,'NONE','QUEUED','8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde','36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74',v_digest,v_digest,v_digest,v_digest,v_digest,v_digest,v_digest,v_digest,v_digest,v_digest,v_now + interval '1 second',v_digest);
    END IF;
    v_receipt := jsonb_build_object('decisionId',v_id,'proposalId',v_proposal,'proposalVersion',v_version,'assignmentId',v_assignment,'decision',v_decision,'resultingState',v_result_state,'reasonDigest',v_reason_digest,'executionId',v_execution_id,'acceptedAt',clock_timestamp(),'quorum',jsonb_build_object('state',CASE WHEN v_decision='APPROVE' THEN 'SATISFIED' ELSE 'PENDING' END,'countsTowardQuorum',v_decision='APPROVE'),'executionAuthorization',CASE WHEN v_execution_id IS NULL THEN NULL ELSE jsonb_build_object('executionId',v_execution_id,'generation',1,'state','QUEUED') END);
    v_receipt_digest := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex');
    INSERT INTO ops.action_decisions(id,proposal_id,proposal_version,approval_digest,assignment_id,assignment_version,assignment_generation,slot_kind,actor_id,assurance,actor_assertion_jti,actor_action_digest,idempotency_key_sha256,decision_kind,reason_code,reason,reason_digest,decision_payload,decision_payload_canonical,decision_receipt_binding,decision_receipt_binding_canonical,conflict_snapshot_id,conflict_snapshot_digest,conflict_target_id,conflict_target_version,conflict_target_digest,conflict_evaluation_state,conflict_valid_until,quorum_snapshot_digest,counts_toward_quorum,quorum_satisfied_after,resulting_proposal_state,execution_id,receipt_digest,request_id,audit_event_id,decided_at,created_at)
      VALUES(v_id,v_proposal,v_version,v_approval_digest,v_assignment,v_assignment_version+1,1,'primary',p_actor,'ACTIVE_SESSION',gen_random_uuid(),v_digest,v_digest,v_decision,'OPERATOR_DECISION',v_reason,v_reason_digest,p_request,convert_to(p_request::text,'UTF8'),v_receipt,convert_to(v_receipt::text,'UTF8'),v_conflict_id,v_digest,v_proposal,v_version,v_approval_digest,CASE WHEN v_decision='RECUSE' THEN 'RECUSE_REQUIRED' ELSE 'CLEAR' END,clock_timestamp()+interval '7 days',v_digest,v_decision='APPROVE',v_decision='APPROVE',v_result_state,v_execution_id,v_receipt_digest,NULLIF(p_request->>'requestId','')::uuid,v_event_id,clock_timestamp(),clock_timestamp());
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
COMMIT;

BEGIN;
CREATE OR REPLACE FUNCTION ops.cancel_agent_run_v1(
  p_payload jsonb, p_actor uuid, p_request_id uuid,
  p_idempotency_key_hash char(64), p_request_digest char(64)
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, extensions, pg_temp AS $$
DECLARE r ops.agent_runs%ROWTYPE; v_receipt_id uuid := gen_random_uuid(); v_audit uuid; v_now timestamptz := clock_timestamp(); v_body jsonb; v_sha char(64); v_audit_request uuid := p_request_id;
BEGIN
  IF NULLIF(p_payload->>'agentRunId','') IS NULL OR NULLIF(p_payload->>'expectedVersion','') IS NULL THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
  SELECT * INTO r FROM ops.agent_runs WHERE id=(p_payload->>'agentRunId')::uuid FOR UPDATE;
  IF NOT FOUND OR r.version <> (p_payload->>'expectedVersion')::bigint THEN RAISE EXCEPTION 'agent_run_version_conflict' USING ERRCODE='40001'; END IF;
  IF r.status IN ('SUCCEEDED','FAILED','CANCELLED','BUDGET_BLOCKED','POLICY_BLOCKED') THEN RAISE EXCEPTION 'agent_run_terminal' USING ERRCODE='55000'; END IF;
  v_body := jsonb_build_object('schemaVersion','agent-run-control-receipt.v2','agentRunId',r.id,'aggregateVersion',r.version,'priorStatus',r.status,'nextStatus','CANCELLED','priorControlState',COALESCE(p_payload->>'priorControlState','ACTIVE'),'nextControlState','SETTLED','reasonCode','PRE_DISPATCH_CANCELLED','occurredAt',v_now);
  v_sha := encode(extensions.digest(convert_to(v_body::text,'UTF8'),'sha256'),'hex');
  v_audit := ops.append_audit_event('control:agent-run:'||r.id::text,'USER',p_actor::text,NULL::uuid,'AGENT_RUN_CANCEL_REQUESTED','AgentRun',r.id::text,'agents.operate','SUCCESS',COALESCE(p_payload->>'reason','cancelled'),p_request_id,v_body);
  INSERT INTO ops.agent_run_control_receipts(receipt_id,receipt_contract_version,agent_run_id,aggregate_version,prior_status,prior_control_state,next_status,next_control_state,proof_kind,proof_sha256,budget_disposition,budget_resolution_set_sha256,actor_kind,actor_id,reason_code,reason_sha256,command_operation_id,command_expected_run_version,command_idempotency_key_sha256,command_request_sha256,audit_event_id,occurred_at,receipt_canonical,receipt_sha256,created_at)
  VALUES(v_receipt_id,2,r.id,r.version,r.status,COALESCE(p_payload->>'priorControlState','ACTIVE'),'CANCELLED','SETTLED','COMMAND_INPUT',v_sha,'NONE',encode(extensions.digest(convert_to('NONE','UTF8'),'sha256'),'hex'),'CONTROL_API',p_actor,'PRE_DISPATCH_CANCELLED',encode(extensions.digest(convert_to(COALESCE(p_payload->>'reason','cancelled'),'UTF8'),'sha256'),'hex'),'cancelAgentRun',r.version,p_idempotency_key_hash,p_request_digest,v_audit,v_now,convert_to(v_body::text,'UTF8'),v_sha,v_now);
  UPDATE ops.agent_runs SET status='CANCELLED',completed_at=v_now,version=version+1,updated_at=v_now WHERE id=r.id AND version=r.version;
  RETURN v_body || jsonb_build_object('receiptId',v_receipt_id,'receiptSha256',v_sha,'auditEventId',v_audit);
END $$;
ALTER FUNCTION ops.cancel_agent_run_v1(jsonb,uuid,uuid,char(64),char(64)) OWNER TO gurine_migrATOR;
REVOKE ALL ON FUNCTION ops.cancel_agent_run_v1(jsonb,uuid,uuid,char(64),char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.cancel_agent_run_v1(jsonb,uuid,uuid,char(64),char(64)) TO gurine_control_api;
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
  SELECT COALESCE(max(declaration_sequence),0)+1, max(id) INTO v_seq,v_prior FROM editorial.conflict_declarations WHERE subject_actor_id=v_subject AND target_type=COALESCE(p_payload->>'targetType','CASE') AND target_id=v_target AND conflict_type=v_type AND source_class=v_source_class AND source_authority_type=v_source_type AND source_authority_id=v_source_id;
  v_target_digest := COALESCE(NULLIF(p_payload->>'targetDigest',''),encode(extensions.digest(convert_to(v_target,'UTF8'),'sha256'),'hex'));
  v_source_digest := encode(extensions.digest(convert_to(v_source_id,'UTF8'),'sha256'),'hex'); v_evidence_digest := encode(extensions.digest(convert_to(COALESCE(p_payload->'evidenceRefs','[]'::jsonb)::text,'UTF8'),'sha256'),'hex'); v_policy_digest := COALESCE(NULLIF(p_payload->>'policyDigest',''),encode(extensions.digest(convert_to('conflict-policy.v1','UTF8'),'sha256'),'hex')); v_reason_digest := encode(extensions.digest(convert_to(COALESCE(p_payload->>'reason','conflict declaration'),'UTF8'),'sha256'),'hex');
  v_decl_digest := encode(extensions.digest(convert_to(v_subject::text||':'||v_target||':'||v_seq||':'||v_reason_digest,'UTF8'),'sha256'),'hex'); v_receipt := encode(extensions.digest(convert_to(v_decl_digest||':'||p_request_id::text,'UTF8'),'sha256'),'hex');
  v_body := jsonb_build_object('declarationId',v_id,'subjectActorId',v_subject,'targetType',COALESCE(p_payload->>'targetType','CASE'),'targetId',v_target,'targetVersion',COALESCE(NULLIF(p_payload->>'targetVersion','')::bigint,1),'relationState',v_relation,'materiality',v_materiality,'temporalState',v_temporal,'declarationDigest',v_decl_digest,'receiptDigest',v_receipt,'acceptedAt',v_now);
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
  SELECT COALESCE(jsonb_agg(jsonb_build_object('proposalId',p.id,'actionKind',p.action_kind,'targetType',p.target_type,'targetId',p.target_id,'version',p.current_version,'proposalVersion',p.current_version,'state',v.state,'contentDigest',btrim(v.content_digest::text),'approvalDigest',v.approval_digest,'updatedAt',p.updated_at) ORDER BY p.updated_at DESC),'[]'::jsonb)
  FROM ops.action_proposals p JOIN ops.action_proposal_versions v ON v.proposal_id=p.id AND v.version=p.current_version
  WHERE v.state IN ('PENDING_QUORUM','DRAFT')
$$;
CREATE OR REPLACE FUNCTION ops.read_action_proposal_v1(p_id uuid) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp AS $$
  SELECT jsonb_build_object(
    'proposal',jsonb_build_object(
      'proposalId',p.id,'actionKind',p.action_kind,'state',v.state,
      'version',v.version,'contentDigest',btrim(v.content_digest::text),
      'approvalDigest',NULLIF(btrim(v.approval_digest::text),''),
      'targetType',p.target_type,'targetId',p.target_id,'targetVersion',p.target_version,
      'targetDigest',btrim(p.target_digest::text)
    ),
    'version',v.version,
    'payload',COALESCE(v.action_detail,'{}'::jsonb),
    'rationale',COALESCE(NULLIF(btrim(convert_from(v.rationale_encrypted,'UTF8')),''),'{}'),
    'assignment',(
      SELECT jsonb_build_object(
        'assignmentId',a.id,'assignmentVersion',a.version,
        'proposalId',a.proposal_id,'proposalVersion',a.proposal_version,
        'approvalDigest',btrim(a.approval_digest::text),'state',a.state,
        'reviewerId',a.reviewer_id,'dueAt',a.due_at
      ) FROM ops.action_review_assignments a
       WHERE a.proposal_id=p.id AND a.proposal_version=v.version
       ORDER BY a.assignment_generation DESC, a.created_at DESC NULLS LAST, a.id DESC LIMIT 1
    )
  )
  FROM ops.action_proposals p JOIN ops.action_proposal_versions v ON v.proposal_id=p.id AND v.version=p.current_version WHERE p.id=$1
$$;
ALTER FUNCTION ops.read_action_queue_v1() OWNER TO gurine_migrator;
ALTER FUNCTION ops.read_action_proposal_v1(uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_action_queue_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.read_action_proposal_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_action_queue_v1() TO gurine_control_api;
GRANT EXECUTE ON FUNCTION ops.read_action_proposal_v1(uuid) TO gurine_control_api;
CREATE OR REPLACE FUNCTION ops.read_appeal_queue_v1() RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,intake,pg_temp AS $$ SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.created_at DESC),'[]'::jsonb) FROM intake.appeals a $$;
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
CREATE OR REPLACE FUNCTION ops.read_execution_receipt_v1(p_id uuid) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT jsonb_build_object('execution',to_jsonb(e),'receipts',COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.receipt_sequence) FROM ops.execution_receipts r WHERE r.execution_id=e.id),'[]'::jsonb)) FROM ops.in_flight_effects e WHERE e.id=$1 $$;
CREATE OR REPLACE FUNCTION ops.read_incident_v1(p_id uuid) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,ops,pg_temp AS $$ SELECT to_jsonb(e) FROM ops.incident_events e WHERE e.incident_id=$1 ORDER BY e.version DESC LIMIT 1 $$;
CREATE OR REPLACE FUNCTION ops.read_appeal_workspace_v1(p_id uuid) RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path=pg_catalog,intake,pg_temp AS $$ SELECT jsonb_build_object('appeal',to_jsonb(a),'decisions',COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.decision_sequence) FROM intake.appeal_decisions d WHERE d.appeal_id=a.id),'[]'::jsonb)) FROM intake.appeals a WHERE a.id=$1 $$;
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
      jsonb_build_object('providerTurnId',p_provider_turn_id,'redacted',true),
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
             'HUMAN_DECISION','INDEPENDENT_REVIEW_OR_POLICY_NOT_REQUIRED'))::bigint AS required_member_count
      FROM ops.paid_evidence_packet_members m
     WHERE m.packet_id = p.packet_id AND m.packet_version = p.packet_version
  ) members
  WHERE h.rn = 1 AND h.fact_effect <> 'INVERSE'
    AND h.fact_contract_version = 2
    AND members.member_count = members.required_member_count
    AND members.required_member_count >= 4
    AND p.outcome_fact_id = h.id
    AND p.outcome_fact_digest = h.fact_digest
    AND ((p.terminal_receipt_kind = 'OUTBOUND_DELIVERY' AND p.terminal_resulting_state IN ('DELIVERED','READ'))
      OR (p.terminal_receipt_kind = 'ORGANIZATION_DECISION' AND p.terminal_resulting_state IN ('REJECTED_FINAL','EFFECT_SUCCEEDED')))
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
      AND e.evaluated_at <= COALESCE(p_as_of, clock_timestamp())
      AND (p_deployment_id IS NULL OR e.deployment_id = p_deployment_id)
      AND (p_organization_id IS NULL OR e.organization_id = p_organization_id)
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
         COALESCE((SELECT min(p.effective_from) FROM paid p
           WHERE p.qualification_episode_id = q.qualification_episode_id
             AND p.effective_from >= r.evidence_cutoff_at), NULL) AS first_paid_at
  FROM q
  LEFT JOIN contracts c ON c.qualification_episode_id = q.qualification_episode_id
    AND c.qualification_receipt_digest = q.receipt_digest
  LEFT JOIN readiness r ON r.organization_id = q.organization_id AND r.sku = q.sku
), agg AS (
  SELECT count(*)::bigint AS qualified,
         count(*) FILTER (WHERE configured)::bigint AS configured,
         count(*) FILTER (WHERE data_ready)::bigint AS data_ready,
         count(*) FILTER (WHERE first_paid_at IS NOT NULL)::bigint AS first_paid,
         count(*) FILTER (WHERE first_paid_at IS NOT NULL AND first_paid_at - data_ready_at <= interval '7 days')::bigint AS activated_on_time,
         count(*) FILTER (WHERE first_paid_at IS NOT NULL AND first_paid_at - data_ready_at > interval '7 days')::bigint AS activated_late,
         count(*) FILTER (WHERE contract_state IN ('ENDED','CANCELLED'))::bigint AS churned,
         count(*) FILTER (WHERE (NOT configured AND first_qualified_at + interval '14 days' <= COALESCE(p_as_of,clock_timestamp()))
                              OR (configured AND NOT data_ready AND data_ready_at + interval '14 days' <= COALESCE(p_as_of,clock_timestamp()))
                              OR (first_paid_at IS NOT NULL AND first_paid_at < COALESCE(p_as_of,clock_timestamp()) - interval '30 days'))::bigint AS at_risk
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
    AND s.evaluation_state = 'COMPLETE'
    AND (p_organization_id IS NULL OR s.scope_id = p_organization_id::text)
    AND (p_deployment_id IS NULL OR EXISTS (
      SELECT 1 FROM ops.commercial_contract_periods c
      WHERE c.deployment_id = p_deployment_id
        AND (p_organization_id IS NULL OR c.organization_id = p_organization_id)
        AND c.sla_policy_digest = s.policy_digest
    ))
), summary AS (
 SELECT count(*)::bigint observed_count,
        COALESCE(sum(eligible_count),0)::bigint eligible_count,
        COALESCE(sum(good_count),0)::bigint good_count,
        COALESCE(sum(telemetry_gap_count),0)::bigint telemetry_gap_count,
        encode(extensions.digest(convert_to(COALESCE(string_agg(receipt_digest,',' ORDER BY id),''),'UTF8'),'sha256'),'hex') input_digest
 FROM r
)
SELECT jsonb_build_object(
 'asOf',COALESCE(p_as_of,clock_timestamp()), 'status',CASE WHEN observed_count=0 THEN 'UNKNOWN' WHEN telemetry_gap_count>0 THEN 'UNKNOWN' ELSE 'KNOWN' END,
 'reasonCode',CASE WHEN observed_count=0 THEN 'SLA_SOURCE_MISSING' WHEN telemetry_gap_count>0 THEN 'SLA_TELEMETRY_GAP' ELSE 'NONE' END,
 'eligibleCount',eligible_count,'goodCount',good_count,'telemetryGapCount',telemetry_gap_count,
 'availability',CASE WHEN eligible_count=0 OR telemetry_gap_count>0 THEN NULL ELSE good_count::numeric/eligible_count END,
 'inputSetDigest',input_digest
) FROM summary;
$$;
ALTER FUNCTION ops.read_sla_metric_inputs_v1(uuid,uuid,timestamptz) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_sla_metric_inputs_v1(uuid,uuid,timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_sla_metric_inputs_v1(uuid,uuid,timestamptz) TO gurine_control_api, gurine_auditor;

CREATE OR REPLACE FUNCTION ops.read_business_health_projection_v1(
  p_deployment_id uuid, p_organization_id uuid, p_as_of timestamptz DEFAULT clock_timestamp()
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, core, editorial, pg_temp
AS $$
DECLARE
  v_now timestamptz := COALESCE(p_as_of,clock_timestamp());
  v_stage jsonb := ops.read_business_stage_projection_v1(p_deployment_id,p_organization_id,v_now);
  v_paid jsonb := ops.read_paid_mvw_inputs_v1(p_deployment_id,p_organization_id,v_now);
  v_sla jsonb := ops.read_sla_metric_inputs_v1(p_deployment_id,p_organization_id,v_now);
  v_metric_catalog_digest char(64);
  v_metrics jsonb := '[]'::jsonb;
  v_funnel jsonb := '[]'::jsonb;
  v_metric_ids text[] := ARRAY['BM-ACQ-QUALIFIED-ORG-COUNT','BM-ACQ-CHANNEL-MIX','BM-FUNNEL-CONFIGURATION-RATE','BM-FUNNEL-DATA-READY-RATE','BM-VALUE-PAID-MVW','BM-ACTIVATION-7D-RATE','BM-ACTIVATION-TTFPV-P90','BM-RETENTION-D29-56-RATE','BM-RETENTION-AT-RISK-ORG-COUNT','BM-RETENTION-CHURN-RATE','BM-REVENUE-RECOGNIZED-KRW','BM-BILLING-RECONCILIATION-COVERAGE','BM-REVENUE-QUALIFIED-ORG-COUNT','BM-VALUE-PAID-MVW-PER-ACTIVE-ORG','BM-MARGIN-VARIABLE-GROSS-RATE','BM-MARGIN-CONTRIBUTION-KRW','BM-COST-PER-PAID-MVW-KRW','BM-CAC-KRW','BM-CAC-PAYBACK-MONTHS','BM-SLA-AVAILABILITY-RATE','BM-SUPPORT-HOURS-PER-ACTIVATED-ORG','BM-TRUST-HARD-STOP-COUNT','BM-FUNNEL-PILOT-TO-PAID-RATE','BM-EXPANSION-ELIGIBILITY-RATE','BM-RENEWAL-ELIGIBILITY-RATE'];
  v_metric_kinds text[] := ARRAY['SCALAR','SOURCE_BREAKDOWN','BINOMIAL_RATE','BINOMIAL_RATE','SCALAR','BINOMIAL_RATE','TIME_TO_EVENT_P90','BINOMIAL_RATE','SCALAR','BINOMIAL_RATE','SCALAR','DETERMINISTIC_RATIO','SCALAR','DETERMINISTIC_RATIO','DETERMINISTIC_RATIO','SCALAR','DETERMINISTIC_RATIO','DETERMINISTIC_RATIO','DETERMINISTIC_RATIO','DETERMINISTIC_RATIO','DETERMINISTIC_RATIO','SCALAR','BINOMIAL_RATE','BINOMIAL_RATE','BINOMIAL_RATE'];
  v_units text[] := ARRAY['organizations','organizations_by_source_kind','ratio','ratio','verified_workflows','ratio','hours','ratio','organizations','ratio','KRW','ratio','organizations','workflows_per_organization','ratio','KRW','KRW_per_verified_workflow','KRW','KRW_per_verified_workflow','months','ratio','hours_per_organization_month','incidents','ratio','ratio','ratio'];
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
  v_conflicts bigint := 0;
  v_conflict_snapshot_rows bigint := 0;
  v_retention_eligible bigint := 0;
  v_retention_success bigint := 0;
  v_p90_eligible bigint := 0;
  v_p90_event_count bigint := 0;
  v_p90_hours numeric := NULL;
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
BEGIN
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
  SELECT COALESCE(sum(r.amount) FILTER (WHERE i.id IS NOT NULL AND i.rn = 1),0),
         count(*),
         count(*) FILTER (WHERE i.id IS NULL OR i.rn <> 1 OR r.currency <> 'KRW'
           OR i.reconciled_at IS NULL
           OR i.expected_usage_membership_count <> i.usage_membership_count
           OR i.reconciliation_digest IS NULL
           OR i.currency <> 'KRW')
    INTO v_revenue, v_revenue_rows, v_revenue_unknown
  FROM ops.revenue_facts r
  LEFT JOIN invoice_heads i ON i.id = r.invoice_id
  WHERE r.sku='EVIDENCE_WORKSPACE_ORGANIZATION_V1' AND r.recognized_at <= v_now
    AND r.recognition_period_start < (v_now AT TIME ZONE 'Asia/Seoul')::date
    AND r.recognition_period_end > ((v_now AT TIME ZONE 'Asia/Seoul')::date - 90)
    AND (p_deployment_id IS NULL OR r.deployment_id=p_deployment_id)
    AND (p_organization_id IS NULL OR r.organization_id=p_organization_id);

  /* Cost headers are the closed accounting cells.  LINE rows have no header
     amounts and must not be summed as if they were a second cost period. */
  SELECT COALESCE(sum(c.attributed_cost_amount),0), count(*), count(*) FILTER (
      WHERE c.cost_capture_state <> 'MEASURED'
         OR c.claim_state = 'INCOMPLETE'
         OR c.cost_capture_coverage IS NULL OR c.cost_capture_coverage < 1
         OR c.direct_coverage IS NULL OR c.direct_coverage < 1
         OR c.total_coverage IS NULL OR c.total_coverage < .95
         OR c.unallocated_amount <> 0 OR c.closed_at IS NULL
         OR c.expected_cost_count IS NULL OR c.captured_cost_count <> c.expected_cost_count)
    INTO v_cost, v_cost_rows, v_cost_unknown
  FROM ops.cost_allocations c
  WHERE c.row_kind = 'PERIOD' AND c.currency='KRW'
    AND c.period_start < (v_now AT TIME ZONE 'Asia/Seoul')::date
    AND c.period_end > ((v_now AT TIME ZONE 'Asia/Seoul')::date - 90)
    AND (p_deployment_id IS NULL OR c.deployment_id=p_deployment_id);

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
     AND c.period_start < (v_now AT TIME ZONE 'Asia/Seoul')::date
     AND c.period_end > ((v_now AT TIME ZONE 'Asia/Seoul')::date - 90)
     AND (p_deployment_id IS NULL OR c.deployment_id=p_deployment_id);
  SELECT COALESCE(sum(x.acquisition_amount),0), count(*), count(*) FILTER (WHERE x.metric_status <> 'KNOWN')
    INTO v_cac, v_cac_rows, v_cac_unknown
  FROM ops.read_cac_metric_inputs_v1((v_now AT TIME ZONE 'Asia/Seoul')::date - 90,
                                     (v_now AT TIME ZONE 'Asia/Seoul')::date,
                                     'KRW',v_cac_policy_digest) x;

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

  /* P90 uses the ordered observed DATA_READY -> first strict paid-value
     intervals.  No observation is fabricated for an incomplete episode. */
  SELECT count(*), count(*), percentile_cont(.9) WITHIN GROUP (ORDER BY hours)
    INTO v_p90_eligible, v_p90_event_count, v_p90_hours
    FROM (
      SELECT extract(epoch FROM ((e->>'first_paid_at')::timestamptz
                               - (e->>'data_ready_at')::timestamptz)) / 3600.0 AS hours
        FROM jsonb_array_elements(COALESCE(v_stage->'episodes','[]'::jsonb)) e
       WHERE e->>'first_paid_at' IS NOT NULL
         AND e->>'data_ready_at' IS NOT NULL
         AND (e->>'first_paid_at')::timestamptz >= (e->>'data_ready_at')::timestamptz
    ) observations;
  v_metric_catalog_digest := encode(extensions.digest(convert_to(array_to_string(v_metric_ids,','),'UTF8'),'sha256'),'hex');
  v_funnel := jsonb_build_array(
    jsonb_build_object('stage','QUALIFIED','state',CASE WHEN v_q>0 THEN 'COMPLETE' ELSE 'UNKNOWN' END,'organizationCount',v_q,'unknownCount',CASE WHEN v_q=0 THEN 1 ELSE 0 END,'evidenceSetDigest',v_stage->>'inputSetDigest','ownerFunction','SALES_CS_FINANCE','primaryIssueCode',CASE WHEN v_q=0 THEN 'QUALIFICATION_SOURCE_MISSING' ELSE NULL END),
    jsonb_build_object('stage','CONFIGURED','state',CASE WHEN v_c>0 THEN 'COMPLETE' WHEN v_q>0 THEN 'BLOCKED' ELSE 'NOT_STARTED' END,'organizationCount',v_c,'unknownCount',GREATEST(v_q-v_c,0),'evidenceSetDigest',v_stage->>'inputSetDigest','ownerFunction','SALES_CS_FINANCE','primaryIssueCode',CASE WHEN v_c=0 AND v_q>0 THEN 'CONFIGURATION_INCOMPLETE' ELSE NULL END),
    jsonb_build_object('stage','DATA_READY','state',CASE WHEN v_d>0 THEN 'COMPLETE' WHEN v_c>0 THEN 'BLOCKED' ELSE 'NOT_STARTED' END,'organizationCount',v_d,'unknownCount',GREATEST(v_c-v_d,0),'evidenceSetDigest',v_stage->>'inputSetDigest','ownerFunction','DATA_ENGINEERING','primaryIssueCode',CASE WHEN v_d=0 AND v_c>0 THEN 'DATA_READINESS_INCOMPLETE' ELSE NULL END),
    jsonb_build_object('stage','FIRST_PAID_VALUE','state',CASE WHEN v_paid_count>0 THEN 'COMPLETE' WHEN v_d>0 THEN 'BLOCKED' ELSE 'NOT_STARTED' END,'organizationCount',v_paid_count,'unknownCount',v_paid_unknown,'evidenceSetDigest',v_paid->>'inputSetDigest','ownerFunction','PRODUCT_PDM','primaryIssueCode',CASE WHEN v_paid_unknown>0 THEN 'PAID_PACKET_UNKNOWN' ELSE NULL END),
    jsonb_build_object('stage','ACTIVATED','state',CASE WHEN COALESCE((v_agg->>'first_paid')::bigint,0)>0 THEN 'COMPLETE' WHEN v_d>0 THEN 'UNKNOWN' ELSE 'NOT_STARTED' END,'organizationCount',COALESCE((v_agg->>'first_paid')::bigint,0),'unknownCount',0,'evidenceSetDigest',v_stage->>'inputSetDigest','ownerFunction','PRODUCT_PDM','primaryIssueCode',NULL),
    jsonb_build_object('stage','RETAINED','state',CASE WHEN v_retention_success>0 THEN 'COMPLETE' WHEN v_retention_eligible>0 THEN 'BLOCKED' ELSE 'UNKNOWN' END,'organizationCount',v_retention_success,'unknownCount',CASE WHEN v_retention_eligible=0 THEN 1 ELSE 0 END,'evidenceSetDigest',v_paid->>'inputSetDigest','ownerFunction','PRODUCT_PDM','primaryIssueCode',CASE WHEN v_retention_eligible=0 THEN 'RETENTION_WINDOW_INCOMPLETE' ELSE NULL END),
    jsonb_build_object('stage','AT_RISK','state',CASE WHEN v_q=0 THEN 'UNKNOWN' WHEN COALESCE((v_agg->>'at_risk')::bigint,0)>0 THEN 'AT_RISK' ELSE 'NOT_STARTED' END,'organizationCount',CASE WHEN v_q=0 THEN 0 ELSE COALESCE((v_agg->>'at_risk')::bigint,0) END,'unknownCount',CASE WHEN v_q=0 THEN 1 ELSE 0 END,'evidenceSetDigest',v_stage->>'inputSetDigest','ownerFunction','PRODUCT_PDM','primaryIssueCode',CASE WHEN v_q=0 THEN 'SOURCE_MISSING' ELSE NULL END),
    jsonb_build_object('stage','CHURNED','state',CASE WHEN COALESCE((v_agg->>'churned')::bigint,0)>0 THEN 'CHURNED' ELSE 'NOT_STARTED' END,'organizationCount',COALESCE((v_agg->>'churned')::bigint,0),'unknownCount',0,'evidenceSetDigest',v_stage->>'inputSetDigest','ownerFunction','SALES_CS_FINANCE','primaryIssueCode',NULL)
  );
  FOR v_i IN 1..array_length(v_metric_ids,1) LOOP
    v_id := v_metric_ids[v_i]; v_kind := v_metric_kinds[v_i]; v_status := 'UNKNOWN'; v_reason := 'SOURCE_MISSING'; v_num := NULL; v_den := NULL; v_result := NULL;
    v_formula_digest := encode(extensions.digest(convert_to(v_id||':formula:v1','UTF8'),'sha256'),'hex');
    v_policy_digest := encode(extensions.digest(convert_to(v_id||':policy:v1','UTF8'),'sha256'),'hex');
    v_input_digest := COALESCE(NULLIF(v_stage->>'inputSetDigest',''), v_metric_catalog_digest);
    IF v_id='BM-ACQ-QUALIFIED-ORG-COUNT' THEN v_status:=CASE WHEN v_q>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_q>0 THEN 'NONE' ELSE 'SOURCE_MISSING' END; v_result:=jsonb_build_object('kind','SCALAR','unit','organizations','value',CASE WHEN v_q>0 THEN v_q::text ELSE NULL END,'resultDigest',v_stage->>'inputSetDigest');
    ELSIF v_id='BM-ACQ-CHANNEL-MIX' THEN v_status:=CASE WHEN jsonb_array_length(COALESCE(v_stage->'sourceMix','[]'::jsonb))>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'SOURCE_MISSING' END; v_result:=jsonb_build_object('kind','SOURCE_BREAKDOWN','totalQualifiedEpisodeCount',v_q,'knownSourceEpisodeCount',CASE WHEN v_status='KNOWN' THEN v_q ELSE 0 END,'unknownSourceEpisodeCount',CASE WHEN v_status='KNOWN' THEN 0 ELSE v_q END,'entries',COALESCE(v_stage->'sourceMix','[]'::jsonb),'conservationDigest',v_stage->>'inputSetDigest','resultDigest',v_stage->>'inputSetDigest');
    ELSIF v_id='BM-FUNNEL-CONFIGURATION-RATE' THEN v_num:=v_c; v_den:=v_q; v_status:=CASE WHEN v_den>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_den>0 THEN 'NONE' ELSE 'SOURCE_MISSING' END;
    ELSIF v_id='BM-FUNNEL-DATA-READY-RATE' THEN v_num:=v_d; v_den:=v_c; v_status:=CASE WHEN v_den>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_den>0 THEN 'NONE' ELSE 'SOURCE_MISSING' END;
    ELSIF v_id='BM-VALUE-PAID-MVW' THEN v_status:=CASE WHEN v_paid_count>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_paid_count>0 THEN 'NONE' ELSE CASE WHEN v_paid_unknown>0 THEN 'PACKET_PROOF_INCOMPLETE' ELSE 'SOURCE_MISSING' END END; v_result:=jsonb_build_object('kind','SCALAR','unit','verified_workflows','value',CASE WHEN v_status='KNOWN' THEN v_paid_count::text ELSE NULL END,'resultDigest',v_paid->>'inputSetDigest');
    ELSIF v_id='BM-ACTIVATION-7D-RATE' THEN v_num:=COALESCE((v_agg->>'activated_on_time')::numeric,0); v_den:=v_num+COALESCE((v_agg->>'activated_late')::numeric,0); v_status:=CASE WHEN v_den>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_den>0 THEN 'NONE' ELSE 'SOURCE_MISSING' END;
    ELSIF v_id='BM-ACTIVATION-TTFPV-P90' THEN
      v_den:=v_p90_eligible;
      v_status:=CASE WHEN v_p90_eligible=0 THEN 'UNKNOWN' ELSE 'KNOWN' END;
      v_reason:=CASE WHEN v_p90_eligible=0 THEN 'SOURCE_MISSING' ELSE 'NONE' END;
      v_result:=jsonb_build_object('kind','TIME_TO_EVENT_P90','estimator','RESTRICTED_EMPIRICAL_P90_OBJECTIVE_V1','estimateState',v_status,'eligibleCount',v_p90_eligible,'eventCount',v_p90_event_count,'rightCensoredCount',0,'terminalWithoutEventCount',0,'selectedRank',CASE WHEN v_status='KNOWN' THEN ceil(v_p90_eligible*.9)::bigint ELSE NULL END,'p90Hours',CASE WHEN v_status='KNOWN' THEN v_p90_hours::text ELSE NULL END,'lowerBoundHours',NULL,'smallSample',CASE WHEN v_p90_eligible BETWEEN 1 AND 4 THEN true ELSE NULL END,'orderedObservationSet',NULL,'resultDigest',v_stage->>'inputSetDigest');
    ELSIF v_id='BM-RETENTION-D29-56-RATE' THEN
      v_num:=v_retention_success; v_den:=v_retention_eligible;
      v_status:=CASE WHEN v_retention_eligible=0 THEN 'NOT_APPLICABLE' ELSE 'KNOWN' END;
      v_reason:=CASE WHEN v_retention_eligible=0 THEN 'DENOMINATOR_ZERO' ELSE 'NONE' END;
    ELSIF v_id='BM-RETENTION-AT-RISK-ORG-COUNT' THEN
      v_status:=CASE WHEN v_q=0 THEN 'UNKNOWN' ELSE 'KNOWN' END;
      v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'SOURCE_MISSING' END;
      v_result:=jsonb_build_object('kind','SCALAR','unit','organizations','value',CASE WHEN v_status='KNOWN' THEN COALESCE((v_agg->>'at_risk')::bigint,0)::text ELSE NULL END,'resultDigest',v_stage->>'inputSetDigest');
    ELSIF v_id='BM-RETENTION-CHURN-RATE' THEN v_num:=COALESCE((v_agg->>'churned')::numeric,0); v_den:=v_q; v_status:=CASE WHEN v_den>0 THEN 'KNOWN' ELSE 'NOT_APPLICABLE' END; v_reason:=CASE WHEN v_den>0 THEN 'NONE' ELSE 'DENOMINATOR_ZERO' END;
    ELSIF v_id='BM-REVENUE-RECOGNIZED-KRW' THEN v_status:=CASE WHEN v_revenue_rows>0 AND v_revenue_unknown=0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE CASE WHEN v_revenue_rows=0 THEN 'SOURCE_MISSING' ELSE 'INVOICE_MEMBERSHIP_GAP' END END; v_result:=jsonb_build_object('kind','SCALAR','unit','KRW','value',CASE WHEN v_status='KNOWN' THEN v_revenue::text ELSE NULL END,'resultDigest',v_metric_catalog_digest);
    ELSIF v_id='BM-BILLING-RECONCILIATION-COVERAGE' THEN v_num:=v_revenue_rows-v_revenue_unknown; v_den:=v_revenue_rows; v_status:=CASE WHEN v_den>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_den>0 AND v_revenue_unknown=0 THEN 'NONE' ELSE 'INVOICE_MEMBERSHIP_GAP' END;
    ELSIF v_id='BM-REVENUE-QUALIFIED-ORG-COUNT' THEN v_status:=CASE WHEN v_revenue_rows>0 AND v_revenue_unknown=0 AND v_paid_count>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'REVENUE_CHAIN_INVALID' END; v_result:=jsonb_build_object('kind','SCALAR','unit','organizations','value',CASE WHEN v_status='KNOWN' THEN LEAST(v_q,v_paid_count)::text ELSE NULL END,'resultDigest',v_metric_catalog_digest);
    ELSIF v_id='BM-VALUE-PAID-MVW-PER-ACTIVE-ORG' THEN
      v_num:=v_paid_count; v_den:=LEAST(v_q,v_paid_count);
      v_status:=CASE WHEN v_den>0 THEN 'KNOWN' WHEN v_q=0 THEN 'NOT_APPLICABLE' ELSE 'UNKNOWN' END;
      v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' WHEN v_status='NOT_APPLICABLE' THEN 'DENOMINATOR_ZERO' ELSE 'VALUE_REVENUE_COHORT_INCOMPLETE' END;
    ELSIF v_id='BM-MARGIN-VARIABLE-GROSS-RATE' THEN v_num:=v_revenue-v_cost; v_den:=v_revenue; v_status:=CASE WHEN v_revenue_rows>0 AND v_cost_rows>0 AND v_cost_unknown=0 AND v_revenue_unknown=0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE CASE WHEN v_cost_rows=0 THEN 'SOURCE_MISSING' ELSE 'COST_CAPTURE_INCOMPLETE' END END;
    ELSIF v_id='BM-MARGIN-CONTRIBUTION-KRW' THEN v_status:=CASE WHEN v_revenue_rows>0 AND v_cost_rows>0 AND v_cost_unknown=0 AND v_revenue_unknown=0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'COST_CAPTURE_INCOMPLETE' END; v_result:=jsonb_build_object('kind','SCALAR','unit','KRW','value',CASE WHEN v_status='KNOWN' THEN (v_revenue-v_cost)::text ELSE NULL END,'resultDigest',v_metric_catalog_digest);
    ELSIF v_id='BM-COST-PER-PAID-MVW-KRW' THEN v_num:=v_cost; v_den:=v_paid_count; v_status:=CASE WHEN v_den>0 AND v_cost_rows>0 AND v_cost_unknown=0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'COST_CAPTURE_INCOMPLETE' END;
    ELSIF v_id='BM-CAC-KRW' THEN v_num:=v_cac; v_den:=v_q; v_status:=CASE WHEN v_cac_rows>0 AND v_cac_unknown=0 AND v_den>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'ATTRIBUTION_UNKNOWN' END;
    ELSIF v_id='BM-CAC-PAYBACK-MONTHS' THEN v_num:=v_cac; v_den:=NULL; v_status:='UNKNOWN'; v_reason:='SOURCE_MISSING';
    ELSIF v_id='BM-SLA-AVAILABILITY-RATE' THEN v_status:=COALESCE(v_sla->>'status','UNKNOWN'); v_reason:=CASE WHEN COALESCE(v_sla->>'reasonCode','')='SLA_SOURCE_MISSING' THEN 'SOURCE_MISSING' ELSE COALESCE(v_sla->>'reasonCode','SOURCE_MISSING') END; v_num:=(v_sla->>'goodCount')::numeric; v_den:=(v_sla->>'eligibleCount')::numeric;
    ELSIF v_id='BM-TRUST-HARD-STOP-COUNT' THEN v_status:=CASE WHEN v_conflict_snapshot_rows>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_status='KNOWN' THEN 'NONE' ELSE 'SOURCE_MISSING' END; v_result:=jsonb_build_object('kind','SCALAR','unit','incidents','value',CASE WHEN v_status='KNOWN' THEN v_conflicts::text ELSE NULL END,'resultDigest',v_metric_catalog_digest);
    ELSIF v_id='BM-FUNNEL-PILOT-TO-PAID-RATE' THEN v_num:=CASE WHEN v_paid_count>0 AND v_revenue_rows>0 AND v_revenue_unknown=0 THEN LEAST(v_paid_count,v_q) ELSE 0 END; v_den:=v_q; v_status:=CASE WHEN v_den>0 THEN 'KNOWN' ELSE 'UNKNOWN' END; v_reason:=CASE WHEN v_den>0 AND v_revenue_unknown=0 THEN 'NONE' ELSE 'REVENUE_CHAIN_INVALID' END;
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
    IF v_kind='BINOMIAL_RATE' THEN v_result:=jsonb_build_object('kind','BINOMIAL_RATE','numeratorCount',CASE WHEN v_status='KNOWN' THEN v_num ELSE NULL END,'denominatorCount',CASE WHEN v_status='KNOWN' THEN v_den ELSE NULL END,'rate',CASE WHEN v_status='KNOWN' AND v_den>0 THEN v_num/v_den ELSE NULL END,'wilson95',NULL,'smallSample',CASE WHEN v_status='NOT_APPLICABLE' AND v_reason='SAMPLE_TOO_SMALL' THEN true ELSE NULL END,'resultDigest',v_metric_catalog_digest);
    ELSIF v_kind='TIME_TO_EVENT_P90' THEN v_result:=jsonb_build_object('kind','TIME_TO_EVENT_P90','estimator','RESTRICTED_EMPIRICAL_P90_OBJECTIVE_V1','estimateState',CASE WHEN v_status='KNOWN' THEN 'EXACT' WHEN v_reason='SAMPLE_TOO_SMALL' THEN 'SAMPLE_TOO_SMALL' ELSE 'UNKNOWN' END,'eligibleCount',CASE WHEN v_status='KNOWN' THEN v_p90_eligible ELSE 0 END,'eventCount',CASE WHEN v_status='KNOWN' THEN v_p90_event_count ELSE 0 END,'rightCensoredCount',0,'terminalWithoutEventCount',0,'selectedRank',CASE WHEN v_status='KNOWN' THEN ceil(v_p90_eligible*.9)::bigint ELSE NULL END,'p90Hours',CASE WHEN v_status='KNOWN' THEN v_p90_hours::text ELSE NULL END,'lowerBoundHours',NULL,'smallSample',CASE WHEN v_status='NOT_APPLICABLE' AND v_reason='SAMPLE_TOO_SMALL' THEN true ELSE NULL END,'orderedObservationSet',NULL,'resultDigest',v_metric_catalog_digest);
    ELSIF v_kind='DETERMINISTIC_RATIO' THEN v_result:=jsonb_build_object('kind','DETERMINISTIC_RATIO','numerator',CASE WHEN v_status='KNOWN' THEN v_num::text ELSE NULL END,'denominator',CASE WHEN v_status='KNOWN' THEN v_den::text ELSE NULL END,'ratio',CASE WHEN v_status='KNOWN' AND v_den IS NOT NULL AND v_den<>0 THEN v_num/v_den ELSE NULL END,'unit',v_units[v_i],'resultDigest',v_metric_catalog_digest);
    ELSIF v_result IS NULL THEN v_result:=jsonb_build_object('kind',v_kind,'unit',v_units[v_i],'value',NULL,'resultDigest',v_metric_catalog_digest);
    END IF;
    v_result := jsonb_set(v_result, '{resultDigest}', to_jsonb(v_input_digest), true);
    v_metrics:=v_metrics||jsonb_build_array(jsonb_build_object('metricId',v_id,'metricVersion',1,'formulaDigest',v_formula_digest,'policyDigest',v_policy_digest,'inputSetDigest',v_input_digest,'status',v_status,'reasonCode',v_reason,'resultKind',v_kind,'result',v_result,'eligibleCount',COALESCE(v_den,0),'pendingCount',0,'unknownCount',CASE WHEN v_status='KNOWN' OR v_status='NOT_APPLICABLE' THEN 0 ELSE 1 END,'unknownReasons',CASE WHEN v_status='KNOWN' OR v_status='NOT_APPLICABLE' THEN '[]'::jsonb ELSE jsonb_build_array(jsonb_build_object('reasonCode',v_reason,'count',1,'ownerFunction','PRODUCT_PDM','firstObservedAt',v_now,'nextReviewAt',v_now+interval '1 day')) END,'windowStart',v_now-interval '90 days','windowEnd',v_now,'accountingTimezone','Asia/Seoul','asOf',v_now,'latestSourceAt',CASE WHEN v_status='KNOWN' THEN v_now ELSE NULL END,'freshUntil',CASE WHEN v_status='KNOWN' THEN v_now+interval '1 hour' ELSE NULL END,'thresholdState',CASE WHEN v_status='KNOWN' THEN 'NOT_EVALUATED' ELSE 'UNKNOWN' END,'issueCode',CASE WHEN v_status='KNOWN' OR v_status='NOT_APPLICABLE' THEN 'NONE' ELSE 'DATA_UNKNOWN' END,'breachAction',CASE WHEN v_status='KNOWN' OR v_status='NOT_APPLICABLE' THEN 'NONE' ELSE CASE v_id WHEN 'BM-ACQ-QUALIFIED-ORG-COUNT' THEN 'COMPLETE_QUALIFICATION' WHEN 'BM-ACQ-CHANNEL-MIX' THEN 'CLOSE_ATTRIBUTION' WHEN 'BM-FUNNEL-CONFIGURATION-RATE' THEN 'COMPLETE_CONFIGURATION' WHEN 'BM-FUNNEL-DATA-READY-RATE' THEN 'REPAIR_DATA_READINESS' WHEN 'BM-VALUE-PAID-MVW' THEN 'VERIFY_PAID_PACKET' WHEN 'BM-VALUE-PAID-MVW-PER-ACTIVE-ORG' THEN 'VERIFY_PAID_PACKET' WHEN 'BM-ACTIVATION-7D-RATE' THEN 'REVIEW_COHORT_LOSS' WHEN 'BM-ACTIVATION-TTFPV-P90' THEN 'REVIEW_COHORT_LOSS' WHEN 'BM-RETENTION-D29-56-RATE' THEN 'RECOVER_VALUE_WORKFLOW' WHEN 'BM-RETENTION-AT-RISK-ORG-COUNT' THEN 'REPAIR_DATA_READINESS' WHEN 'BM-RETENTION-CHURN-RATE' THEN 'REVIEW_COHORT_LOSS' WHEN 'BM-FUNNEL-PILOT-TO-PAID-RATE' THEN 'RECONCILE_USAGE_AND_INVOICE' WHEN 'BM-REVENUE-QUALIFIED-ORG-COUNT' THEN 'VERIFY_PAID_PACKET' WHEN 'BM-EXPANSION-ELIGIBILITY-RATE' THEN 'REPAIR_DATA_READINESS' WHEN 'BM-RENEWAL-ELIGIBILITY-RATE' THEN 'REPAIR_DATA_READINESS' WHEN 'BM-REVENUE-RECOGNIZED-KRW' THEN 'RECONCILE_REVENUE' WHEN 'BM-BILLING-RECONCILIATION-COVERAGE' THEN 'RECONCILE_USAGE_AND_INVOICE' WHEN 'BM-MARGIN-VARIABLE-GROSS-RATE' THEN 'CLOSE_COST_AND_FX_GAPS' WHEN 'BM-MARGIN-CONTRIBUTION-KRW' THEN 'CLOSE_COST_AND_FX_GAPS' WHEN 'BM-COST-PER-PAID-MVW-KRW' THEN 'CLOSE_COST_AND_FX_GAPS' WHEN 'BM-CAC-KRW' THEN 'CLOSE_ATTRIBUTION' WHEN 'BM-CAC-PAYBACK-MONTHS' THEN 'CLOSE_ATTRIBUTION' WHEN 'BM-SLA-AVAILABILITY-RATE' THEN 'RESTORE_SLA_AND_TELEMETRY' WHEN 'BM-SUPPORT-HOURS-PER-ACTIVATED-ORG' THEN 'RESTORE_SUPPORT_CAPACITY' WHEN 'BM-TRUST-HARD-STOP-COUNT' THEN 'CONTAIN_TRUST_INCIDENT' ELSE 'REPAIR_DATA_READINESS' END END,'owner',jsonb_build_object('primaryFunction',CASE WHEN v_id LIKE 'BM-%REVENUE%' OR v_id LIKE 'BM-%CAC%' THEN 'SALES_CS_FINANCE' ELSE 'PRODUCT_PDM' END,'backupFunction','DATA_ENGINEERING','escalationFunction','EXECUTIVE_APPROVER','ownerBindingSetDigest',v_policy_digest,'responseDueAt',v_now+interval '1 day','nextReviewAt',v_now+interval '1 day')));
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
