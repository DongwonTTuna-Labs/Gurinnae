BEGIN;

ALTER TABLE intake.correction_request_drafts ALTER COLUMN token_hash DROP NOT NULL;
ALTER TABLE intake.subscriptions ALTER COLUMN management_token_hash DROP NOT NULL;
ALTER TABLE intake.response_access_tokens ADD COLUMN IF NOT EXISTS exchanged_at timestamptz;
ALTER TABLE intake.response_access_tokens ADD COLUMN IF NOT EXISTS exchange_session_id uuid;
ALTER TABLE intake.response_submissions ADD COLUMN IF NOT EXISTS receipt_token_consumed_at timestamptz;
ALTER TABLE intake.correction_requests ADD COLUMN IF NOT EXISTS receipt_token_consumed_at timestamptz;
ALTER TABLE intake.subscriptions ADD COLUMN IF NOT EXISTS management_token_consumed_at timestamptz;

CREATE TABLE intake.submission_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash char(64) NOT NULL UNIQUE,
  session_kind text NOT NULL CHECK (session_kind IN (
    'RESPONSE_PENDING','RESPONSE_ACTIVE','CORRECTION_DRAFT','SUBSCRIPTION_PENDING',
    'SUBSCRIPTION_MANAGEMENT','RESPONSE_RECEIPT','CORRECTION_RECEIPT'
  )),
  scope_type text NOT NULL CHECK (scope_type IN ('RESPONSE_REQUEST','CORRECTION_DRAFT','SUBSCRIPTION','RESPONSE_SUBMISSION','CORRECTION_REQUEST')),
  scope_id uuid NOT NULL,
  bff_issuer text NOT NULL CHECK (bff_issuer IN ('public-web','response-portal')),
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CONSUMED','REVOKED','EXPIRED')),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  issued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_used_at timestamptz,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  revoked_at timestamptz,
  CHECK (expires_at > issued_at)
);
CREATE INDEX submission_sessions_scope_idx ON intake.submission_sessions(session_kind,scope_id,status);
CREATE INDEX submission_sessions_expiry_idx ON intake.submission_sessions(expires_at) WHERE status='ACTIVE';

ALTER TABLE intake.response_access_tokens
  ADD CONSTRAINT response_access_exchange_session_fk
  FOREIGN KEY (exchange_session_id) REFERENCES intake.submission_sessions(id);

CREATE TABLE intake.correction_draft_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  draft_id uuid NOT NULL REFERENCES intake.correction_request_drafts(id) ON DELETE CASCADE,
  original_filename_encrypted bytea NOT NULL,
  media_type text NOT NULL,
  size_bytes bigint NOT NULL CHECK (size_bytes BETWEEN 1 AND 52428800),
  sha256 char(64) NOT NULL,
  object_key text NOT NULL,
  upload_status text NOT NULL CHECK (upload_status IN ('PENDING','UPLOADED','FINALIZED','FAILED','DELETED')),
  scan_status text NOT NULL CHECK (scan_status IN ('PENDING','CLEAN','INFECTED','FAILED')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(draft_id,sha256)
);
CREATE TRIGGER correction_draft_attachments_updated_at BEFORE UPDATE ON intake.correction_draft_attachments FOR EACH ROW EXECUTE FUNCTION ops.set_updated_at();

CREATE OR REPLACE FUNCTION intake.resolve_submission_session(
  p_token_hash char(64), p_bff_issuer text, p_allowed_kinds text[]
) RETURNS TABLE(session_id uuid, session_kind text, scope_type text, scope_id uuid, session_version bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT s.id,s.session_kind,s.scope_type,s.scope_id,s.version
  FROM intake.submission_sessions s
  WHERE s.token_hash=p_token_hash
    AND s.bff_issuer=p_bff_issuer
    AND s.status='ACTIVE'
    AND s.expires_at>clock_timestamp()
    AND s.session_kind=ANY(p_allowed_kinds);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'submission_session_invalid_expired_or_out_of_scope' USING ERRCODE='28000';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION intake.create_correction_session(
 p_session_token_hash char(64),p_bff_issuer text,p_locale text,p_case_slug text,p_publication_revision integer,p_expires_at timestamptz
) RETURNS TABLE(draft_id uuid,session_id uuid,version bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
BEGIN
 INSERT INTO intake.correction_request_drafts(token_hash,version,case_slug,publication_revision,expires_at)
 VALUES(NULL,1,p_case_slug,p_publication_revision,p_expires_at) RETURNING id,correction_request_drafts.version INTO draft_id,version;
 INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at)
 VALUES(p_session_token_hash,'CORRECTION_DRAFT','CORRECTION_DRAFT',draft_id,p_bff_issuer,p_expires_at) RETURNING id INTO session_id;
 RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.save_correction_draft_session(
 p_session_token_hash char(64),p_bff_issuer text,p_expected_version bigint,p_requester_type text,p_contact_email_hash char(64),p_contact_email_encrypted bytea,p_summary text,p_requested_changes jsonb,p_evidence_description text
) RETURNS TABLE(draft_id uuid,version bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_scope uuid;
BEGIN
 SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['CORRECTION_DRAFT']) r;
 UPDATE intake.correction_request_drafts d SET requester_type=p_requester_type,contact_email_hash=p_contact_email_hash,contact_email_encrypted=p_contact_email_encrypted,summary=p_summary,requested_changes=p_requested_changes,evidence_description=p_evidence_description,version=d.version+1,updated_at=clock_timestamp()
 WHERE d.id=v_scope AND d.version=p_expected_version AND d.expires_at>clock_timestamp() RETURNING d.id,d.version INTO draft_id,version;
 IF draft_id IS NULL THEN RAISE EXCEPTION 'correction_draft_version_conflict' USING ERRCODE='40001'; END IF; RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.delete_correction_draft_session(p_session_token_hash char(64),p_bff_issuer text,p_expected_version bigint) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_session uuid; v_scope uuid; v_id uuid;
BEGIN
 SELECT r.session_id,r.scope_id INTO v_session,v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['CORRECTION_DRAFT']) r;
 DELETE FROM intake.correction_request_drafts WHERE id=v_scope AND version=p_expected_version RETURNING id INTO v_id;
 IF v_id IS NULL THEN RAISE EXCEPTION 'correction_draft_version_conflict' USING ERRCODE='40001'; END IF;
 UPDATE intake.submission_sessions SET status='REVOKED',revoked_at=clock_timestamp(),version=version+1 WHERE id=v_session;
 RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION intake.create_correction_draft_attachment(p_session_token_hash char(64),p_bff_issuer text,p_filename_encrypted bytea,p_media_type text,p_size_bytes bigint,p_sha256 char(64),p_object_key text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_scope uuid; v_id uuid;
BEGIN
 SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['CORRECTION_DRAFT']) r;
 INSERT INTO intake.correction_draft_attachments(draft_id,original_filename_encrypted,media_type,size_bytes,sha256,object_key,upload_status,scan_status)
 VALUES(v_scope,p_filename_encrypted,p_media_type,p_size_bytes,p_sha256,p_object_key,'PENDING','PENDING') RETURNING id INTO v_id; RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION intake.finalize_correction_draft_attachment(p_session_token_hash char(64),p_bff_issuer text,p_attachment_id uuid,p_object_etag text,p_uploaded_size bigint,p_uploaded_sha256 char(64)) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_scope uuid; v_id uuid;
BEGIN
 SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['CORRECTION_DRAFT']) r;
 UPDATE intake.correction_draft_attachments SET upload_status='FINALIZED',scan_status='PENDING',updated_at=clock_timestamp()
 WHERE id=p_attachment_id AND draft_id=v_scope AND upload_status IN ('PENDING','UPLOADED') AND size_bytes=p_uploaded_size AND sha256=p_uploaded_sha256 RETURNING id INTO v_id;
 IF v_id IS NULL THEN RAISE EXCEPTION 'correction_attachment_finalize_failed' USING ERRCODE='22023'; END IF; RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION intake.delete_correction_draft_attachment(p_session_token_hash char(64),p_bff_issuer text,p_attachment_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_scope uuid; v_id uuid;
BEGIN
 SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['CORRECTION_DRAFT']) r;
 UPDATE intake.correction_draft_attachments SET upload_status='DELETED',updated_at=clock_timestamp() WHERE id=p_attachment_id AND draft_id=v_scope AND upload_status<>'DELETED' RETURNING id INTO v_id;
 IF v_id IS NULL THEN RAISE EXCEPTION 'correction_attachment_not_found' USING ERRCODE='P0002'; END IF; RETURN v_id;
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
 INSERT INTO intake.correction_requests(public_case_slug,publication_revision,requester_type,contact_email_hash,contact_email_encrypted,summary,requested_changes,evidence_description,receipt_token_hash)
 VALUES(d.case_slug,d.publication_revision,d.requester_type,d.contact_email_hash,d.contact_email_encrypted,d.summary,d.requested_changes,d.evidence_description,p_receipt_token_hash) RETURNING id INTO request_id;
 INSERT INTO intake.correction_attachments(correction_request_id,original_filename_encrypted,media_type,size_bytes,sha256,object_key,scan_status)
 SELECT request_id,original_filename_encrypted,media_type,size_bytes,sha256,object_key,scan_status FROM intake.correction_draft_attachments WHERE draft_id=v_draft AND upload_status='FINALIZED';
 UPDATE intake.submission_sessions SET status='CONSUMED',consumed_at=clock_timestamp(),version=version+1 WHERE id=v_session;
 INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at)
 VALUES(p_receipt_session_token_hash,'CORRECTION_RECEIPT','CORRECTION_REQUEST',request_id,p_bff_issuer,p_receipt_session_expires_at) RETURNING id INTO receipt_session_id;
 DELETE FROM intake.correction_request_drafts WHERE id=v_draft;
 RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.exchange_response_magic_token(p_magic_token_hash char(64),p_new_session_token_hash char(64),p_bff_issuer text,p_expires_at timestamptz)
RETURNS TABLE(request_id uuid,session_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,editorial,extensions,pg_temp AS $$
DECLARE t intake.response_access_tokens%ROWTYPE; r editorial.response_requests%ROWTYPE;
BEGIN
 SELECT * INTO t FROM intake.response_access_tokens WHERE token_hash=p_magic_token_hash AND revoked_at IS NULL AND exchanged_at IS NULL AND expires_at>clock_timestamp() FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'response_magic_token_invalid' USING ERRCODE='28000'; END IF;
 SELECT * INTO r FROM editorial.response_requests WHERE id=t.response_request_id AND status IN ('SENT','VIEWED') AND due_at>clock_timestamp() FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
 request_id=t.response_request_id;
 INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at)
 VALUES(p_new_session_token_hash,'RESPONSE_PENDING','RESPONSE_REQUEST',request_id,p_bff_issuer,p_expires_at) RETURNING id INTO session_id;
 UPDATE intake.response_access_tokens SET exchanged_at=clock_timestamp(),exchange_session_id=session_id,revoked_at=clock_timestamp(),last_used_at=clock_timestamp() WHERE id=t.id;
 RETURN NEXT;
END $$;

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
  WHERE response_request_id=s.scope_id
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

CREATE OR REPLACE FUNCTION intake.save_response_draft_session(
  p_session_token_hash char(64),p_bff_issuer text,p_expected_version bigint,
  p_answers_encrypted bytea,p_publication_consent jsonb,p_expires_at timestamptz
) RETURNS TABLE(draft_id uuid,version bigint)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,extensions,pg_temp AS $$
DECLARE v_request uuid;v_id uuid;v_version bigint;
BEGIN
  SELECT r.scope_id INTO v_request FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;
  PERFORM 1 FROM editorial.response_requests
    WHERE id=v_request AND status IN ('SENT','VIEWED') AND due_at>clock_timestamp() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  SELECT id,response_drafts.version INTO v_id,v_version FROM intake.response_drafts WHERE response_request_id=v_request FOR UPDATE;
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

CREATE OR REPLACE FUNCTION intake.create_response_attachment_session(
  p_session_token_hash char(64),p_bff_issuer text,p_filename_encrypted bytea,p_media_type text,
  p_size_bytes bigint,p_sha256 char(64),p_object_key text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,editorial,extensions,pg_temp AS $$
DECLARE v_request uuid;v_draft uuid;v_id uuid;
BEGIN
  SELECT r.scope_id INTO v_request FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;
  PERFORM 1 FROM editorial.response_requests WHERE id=v_request AND status IN ('SENT','VIEWED') AND due_at>clock_timestamp() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  SELECT id INTO v_draft FROM intake.response_drafts WHERE response_request_id=v_request;
  INSERT INTO intake.response_attachments(response_request_id,draft_id,original_filename_encrypted,media_type,size_bytes,sha256,object_key,upload_status,scan_status)
  VALUES(v_request,v_draft,p_filename_encrypted,p_media_type,p_size_bytes,p_sha256,p_object_key,'PENDING','PENDING')
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION intake.finalize_response_attachment_session(
  p_session_token_hash char(64),p_bff_issuer text,p_attachment_id uuid,p_uploaded_size bigint,p_uploaded_sha256 char(64)
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,editorial,extensions,pg_temp AS $$
DECLARE v_request uuid;v_id uuid;
BEGIN
  SELECT r.scope_id INTO v_request FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;
  PERFORM 1 FROM editorial.response_requests WHERE id=v_request AND status IN ('SENT','VIEWED') AND due_at>clock_timestamp() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  UPDATE intake.response_attachments SET upload_status='FINALIZED',scan_status='PENDING'
  WHERE id=p_attachment_id AND response_request_id=v_request AND size_bytes=p_uploaded_size AND sha256=p_uploaded_sha256 AND upload_status IN ('PENDING','UPLOADED')
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'response_attachment_finalize_failed' USING ERRCODE='22023';END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION intake.delete_response_attachment_session(
  p_session_token_hash char(64),p_bff_issuer text,p_attachment_id uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,editorial,extensions,pg_temp AS $$
DECLARE v_request uuid;v_id uuid;
BEGIN
  SELECT r.scope_id INTO v_request FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;
  PERFORM 1 FROM editorial.response_requests WHERE id=v_request AND status IN ('SENT','VIEWED') AND due_at>clock_timestamp() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000'; END IF;
  UPDATE intake.response_attachments SET upload_status='DELETED'
  WHERE id=p_attachment_id AND response_request_id=v_request AND upload_status<>'DELETED'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'response_attachment_not_found' USING ERRCODE='P0002';END IF;
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
  VALUES(v_request,p_requested_due_at,p_reason,'PENDING') RETURNING id INTO v_id;
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
 INSERT INTO intake.response_submissions(response_request_id,draft_version,submission_sha256,answers_encrypted,publication_consent,receipt_token_hash) VALUES(s.scope_id,d.version,p_submission_sha256,p_answers_encrypted,p_publication_consent,p_receipt_token_hash) RETURNING id INTO submission_id;
 UPDATE editorial.response_requests SET status='SUBMITTED',version=version+1,updated_at=clock_timestamp() WHERE id=s.scope_id AND status IN ('SENT','VIEWED');
 UPDATE intake.submission_sessions SET status='CONSUMED',consumed_at=clock_timestamp(),version=version+1 WHERE id=s.id;
 INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at) VALUES(p_receipt_session_token_hash,'RESPONSE_RECEIPT','RESPONSE_SUBMISSION',submission_id,p_bff_issuer,p_receipt_session_expires_at) RETURNING id INTO receipt_session_id; RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.exchange_response_receipt_token(p_receipt_token_hash char(64),p_session_token_hash char(64),p_bff_issuer text,p_expires_at timestamptz) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_submission uuid;v_id uuid;BEGIN UPDATE intake.response_submissions SET receipt_token_consumed_at=clock_timestamp() WHERE receipt_token_hash=p_receipt_token_hash AND receipt_token_consumed_at IS NULL RETURNING id INTO v_submission;IF v_submission IS NULL THEN RAISE EXCEPTION 'response_receipt_token_invalid' USING ERRCODE='28000';END IF;INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at) VALUES(p_session_token_hash,'RESPONSE_RECEIPT','RESPONSE_SUBMISSION',v_submission,p_bff_issuer,p_expires_at) RETURNING id INTO v_id;RETURN v_id;END $$;
CREATE OR REPLACE FUNCTION intake.exchange_correction_receipt_token(p_receipt_token_hash char(64),p_session_token_hash char(64),p_bff_issuer text,p_expires_at timestamptz) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_request uuid;v_id uuid;BEGIN UPDATE intake.correction_requests SET receipt_token_consumed_at=clock_timestamp() WHERE receipt_token_hash=p_receipt_token_hash AND receipt_token_consumed_at IS NULL RETURNING id INTO v_request;IF v_request IS NULL THEN RAISE EXCEPTION 'correction_receipt_token_invalid' USING ERRCODE='28000';END IF;INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at) VALUES(p_session_token_hash,'CORRECTION_RECEIPT','CORRECTION_REQUEST',v_request,p_bff_issuer,p_expires_at) RETURNING id INTO v_id;RETURN v_id;END $$;

CREATE OR REPLACE FUNCTION intake.create_subscription_session(p_email_hash char(64),p_email_encrypted bytea,p_topics jsonb,p_frequency text,p_locale text,p_verification_token_hash char(64),p_management_token_hash char(64),p_pending_session_token_hash char(64),p_bff_issuer text,p_expires_at timestamptz)
RETURNS TABLE(subscription_id uuid,session_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
BEGIN INSERT INTO intake.subscriptions(email_hash,email_encrypted,topics,frequency,locale,status,verification_token_hash,management_token_hash) VALUES(p_email_hash,p_email_encrypted,p_topics,p_frequency,p_locale,'PENDING',p_verification_token_hash,p_management_token_hash) RETURNING id INTO subscription_id;INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at) VALUES(p_pending_session_token_hash,'SUBSCRIPTION_PENDING','SUBSCRIPTION',subscription_id,p_bff_issuer,p_expires_at) RETURNING id INTO session_id;RETURN NEXT;END $$;
CREATE OR REPLACE FUNCTION intake.verify_subscription_session(
  p_verification_token_hash char(64),p_session_token_hash char(64),p_bff_issuer text,p_expires_at timestamptz
) RETURNS TABLE(subscription_id uuid,session_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
BEGIN
  UPDATE intake.subscriptions
  SET status='ACTIVE',verified_at=clock_timestamp(),verification_token_hash=NULL,updated_at=clock_timestamp()
  WHERE verification_token_hash=p_verification_token_hash AND status='PENDING'
  RETURNING id INTO subscription_id;
  IF subscription_id IS NULL THEN RAISE EXCEPTION 'subscription_verification_invalid' USING ERRCODE='28000'; END IF;
  UPDATE intake.submission_sessions
  SET status='CONSUMED',consumed_at=clock_timestamp(),version=version+1
  WHERE session_kind='SUBSCRIPTION_PENDING' AND scope_id=subscription_id AND status='ACTIVE';
  INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at)
  VALUES(p_session_token_hash,'SUBSCRIPTION_MANAGEMENT','SUBSCRIPTION',subscription_id,p_bff_issuer,p_expires_at)
  RETURNING id INTO session_id;
  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION intake.exchange_subscription_management_token(p_management_token_hash char(64),p_session_token_hash char(64),p_bff_issuer text,p_expires_at timestamptz) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_subscription uuid;v_id uuid;BEGIN UPDATE intake.subscriptions SET management_token_consumed_at=clock_timestamp(),management_token_hash=NULL,updated_at=clock_timestamp() WHERE management_token_hash=p_management_token_hash AND management_token_consumed_at IS NULL AND status IN ('ACTIVE','PAUSED') RETURNING id INTO v_subscription;IF v_subscription IS NULL THEN RAISE EXCEPTION 'subscription_management_token_invalid' USING ERRCODE='28000';END IF;INSERT INTO intake.submission_sessions(token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at) VALUES(p_session_token_hash,'SUBSCRIPTION_MANAGEMENT','SUBSCRIPTION',v_subscription,p_bff_issuer,p_expires_at) RETURNING id INTO v_id;RETURN v_id;END $$;
CREATE OR REPLACE FUNCTION intake.update_subscription_session(p_session_token_hash char(64),p_bff_issuer text,p_topics jsonb,p_frequency text,p_status text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_scope uuid;v_id uuid;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['SUBSCRIPTION_MANAGEMENT']) r;UPDATE intake.subscriptions SET topics=COALESCE(p_topics,topics),frequency=COALESCE(p_frequency,frequency),status=COALESCE(p_status,status),updated_at=clock_timestamp() WHERE id=v_scope RETURNING id INTO v_id;RETURN v_id;END $$;
CREATE OR REPLACE FUNCTION intake.unsubscribe_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$
DECLARE v_session uuid;v_scope uuid;BEGIN SELECT r.session_id,r.scope_id INTO v_session,v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['SUBSCRIPTION_MANAGEMENT']) r;UPDATE intake.subscriptions SET status='UNSUBSCRIBED',updated_at=clock_timestamp() WHERE id=v_scope;UPDATE intake.submission_sessions SET status='CONSUMED',consumed_at=clock_timestamp(),version=version+1 WHERE id=v_session;RETURN v_scope;END $$;

-- Read projections resolve only the scoped session and never accept raw URL tokens.
CREATE OR REPLACE FUNCTION intake.get_correction_draft_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['CORRECTION_DRAFT']) r;SELECT to_jsonb(d) INTO v FROM intake.correction_request_drafts d WHERE id=v_scope;RETURN v;END $$;
CREATE OR REPLACE FUNCTION intake.get_correction_draft_preview_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['CORRECTION_DRAFT']) r;SELECT jsonb_build_object('draft',to_jsonb(d),'attachments',COALESCE((SELECT jsonb_agg(to_jsonb(a)) FROM intake.correction_draft_attachments a WHERE a.draft_id=v_scope AND a.upload_status<>'DELETED'),'[]'::jsonb)) INTO v FROM intake.correction_request_drafts d WHERE id=v_scope;RETURN v;END $$;
CREATE OR REPLACE FUNCTION intake.get_response_access_status_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE s intake.submission_sessions%ROWTYPE;BEGIN SELECT * INTO s FROM intake.submission_sessions WHERE token_hash=p_session_token_hash AND bff_issuer=p_bff_issuer AND session_kind IN ('RESPONSE_PENDING','RESPONSE_ACTIVE') AND status='ACTIVE' AND expires_at>clock_timestamp();IF NOT FOUND THEN RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000';END IF;RETURN jsonb_build_object('status',s.session_kind,'expires_at',s.expires_at,'scope_id',s.scope_id);END $$;
CREATE OR REPLACE FUNCTION intake.get_response_request_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,editorial,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;SELECT to_jsonb(q)-'recipient_email_encrypted'-'recipient_email_hash' INTO v FROM editorial.response_requests q WHERE id=v_scope;RETURN v;END $$;
CREATE OR REPLACE FUNCTION intake.get_response_draft_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;SELECT to_jsonb(d) INTO v FROM intake.response_drafts d WHERE response_request_id=v_scope;RETURN COALESCE(v,'{}'::jsonb);END $$;
CREATE OR REPLACE FUNCTION intake.get_response_preview_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_ACTIVE']) r;SELECT jsonb_build_object('draft',COALESCE((SELECT to_jsonb(d) FROM intake.response_drafts d WHERE d.response_request_id=v_scope),'{}'::jsonb),'attachments',COALESCE((SELECT jsonb_agg(to_jsonb(a)) FROM intake.response_attachments a WHERE a.response_request_id=v_scope AND a.upload_status<>'DELETED'),'[]'::jsonb)) INTO v;RETURN v;END $$;
CREATE OR REPLACE FUNCTION intake.get_response_receipt_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['RESPONSE_RECEIPT']) r;SELECT to_jsonb(s)-'answers_encrypted'-'receipt_token_hash' INTO v FROM intake.response_submissions s WHERE id=v_scope;RETURN v;END $$;
CREATE OR REPLACE FUNCTION intake.get_correction_receipt_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['CORRECTION_RECEIPT']) r;SELECT to_jsonb(c)-'contact_email_encrypted'-'contact_email_hash'-'receipt_token_hash' INTO v FROM intake.correction_requests c WHERE id=v_scope;RETURN v;END $$;
CREATE OR REPLACE FUNCTION intake.get_subscription_session(p_session_token_hash char(64),p_bff_issuer text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,intake,extensions,pg_temp AS $$ DECLARE v_scope uuid;v jsonb;BEGIN SELECT r.scope_id INTO v_scope FROM intake.resolve_submission_session(p_session_token_hash,p_bff_issuer,ARRAY['SUBSCRIPTION_MANAGEMENT']) r;SELECT to_jsonb(s)-'email_encrypted'-'email_hash'-'management_token_hash'-'verification_token_hash' INTO v FROM intake.subscriptions s WHERE id=v_scope;RETURN v;END $$;

REVOKE ALL ON TABLE intake.submission_sessions,intake.correction_draft_attachments FROM PUBLIC, gurine_submission_api;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA intake FROM PUBLIC;
GRANT EXECUTE ON FUNCTION intake.resolve_submission_session(char(64),text,text[]) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.create_correction_session(char(64),text,text,text,integer,timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.save_correction_draft_session(char(64),text,bigint,text,char(64),bytea,text,jsonb,text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.delete_correction_draft_session(char(64),text,bigint) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.create_correction_draft_attachment(char(64),text,bytea,text,bigint,char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.finalize_correction_draft_attachment(char(64),text,uuid,text,bigint,char(64)) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.delete_correction_draft_attachment(char(64),text,uuid) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.submit_correction_draft_session(char(64),text,bigint,boolean,boolean,char(64),char(64),timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.exchange_response_magic_token(char(64),char(64),text,timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.verify_response_session(char(64),text,boolean,char(64),timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.save_response_draft_session(char(64),text,bigint,bytea,jsonb,timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.create_response_attachment_session(char(64),text,bytea,text,bigint,char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.finalize_response_attachment_session(char(64),text,uuid,bigint,char(64)) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.delete_response_attachment_session(char(64),text,uuid) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.request_response_extension_session(char(64),text,timestamptz,text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.submit_response_session(char(64),text,bigint,char(64),bytea,jsonb,char(64),char(64),timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.exchange_response_receipt_token(char(64),char(64),text,timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.exchange_correction_receipt_token(char(64),char(64),text,timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.create_subscription_session(char(64),bytea,jsonb,text,text,char(64),char(64),char(64),text,timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.verify_subscription_session(char(64),char(64),text,timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.exchange_subscription_management_token(char(64),char(64),text,timestamptz) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.update_subscription_session(char(64),text,jsonb,text,text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.unsubscribe_session(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_correction_draft_session(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_correction_draft_preview_session(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_response_access_status_session(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_response_request_session(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_response_draft_session(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_response_preview_session(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_response_receipt_session(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_correction_receipt_session(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION intake.get_subscription_session(char(64),text) TO gurine_submission_api;
GRANT EXECUTE ON FUNCTION ops.consume_assertion_jti(text,uuid,text,text,timestamptz,char(64)) TO gurine_submission_api;

COMMIT;
