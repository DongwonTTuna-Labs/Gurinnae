BEGIN;

ALTER TABLE intake.correction_request_drafts
  ADD COLUMN locale text NOT NULL DEFAULT 'ko-KR';

CREATE OR REPLACE FUNCTION intake.lookup_response_request_id(p_token_hash char(64))
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE
  v_request_id uuid;
BEGIN
  SELECT response_request_id INTO v_request_id
  FROM intake.response_access_tokens
  WHERE token_hash = p_token_hash
    AND revoked_at IS NULL
    AND expires_at > clock_timestamp()
    AND use_count < max_uses;
  IF v_request_id IS NULL THEN
    RAISE EXCEPTION 'invalid_or_expired_response_token' USING ERRCODE = '28000';
  END IF;
  RETURN v_request_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.get_response_access_status(p_token_hash char(64))
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE
  v_row intake.response_access_tokens%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM intake.response_access_tokens
  WHERE token_hash = p_token_hash;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status','INVALID','requires_email_proof',true);
  END IF;
  RETURN jsonb_build_object(
    'status', CASE
      WHEN v_row.revoked_at IS NOT NULL THEN 'REVOKED'
      WHEN v_row.expires_at <= clock_timestamp() THEN 'EXPIRED'
      WHEN v_row.verification_locked_until > clock_timestamp() THEN 'LOCKED'
      WHEN v_row.verified_at IS NULL THEN 'VERIFICATION_REQUIRED'
      ELSE 'VERIFIED'
    END,
    'requires_email_proof', v_row.verified_at IS NULL,
    'expires_at', v_row.expires_at,
    'remaining_attempts', GREATEST(0, 5 - v_row.verification_attempt_count)
  );
END
$$;

CREATE OR REPLACE FUNCTION intake.get_response_request(p_token_hash char(64))
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, editorial, extensions, pg_temp
AS $$
DECLARE
  v_request_id uuid;
  v_result jsonb;
BEGIN
  v_request_id := intake.lookup_response_request_id(p_token_hash);
  SELECT jsonb_build_object(
    'request_id', r.id,
    'case_id', r.case_id,
    'party_type', r.party_type,
    'party_name', r.party_name,
    'questions', r.questions,
    'requested_publication_scope', r.requested_publication_scope,
    'due_at', r.due_at,
    'sent_at', r.sent_at,
    'status', r.status,
    'version', r.version
  ) INTO v_result
  FROM editorial.response_requests r WHERE r.id = v_request_id;
  RETURN v_result;
END
$$;

CREATE OR REPLACE FUNCTION intake.get_response_draft(p_token_hash char(64))
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, editorial, extensions, pg_temp
AS $$
DECLARE
  v_request_id uuid;
  v_result jsonb;
BEGIN
  v_request_id := intake.resolve_response_request_id(p_token_hash);
  SELECT jsonb_build_object(
    'draft_id', d.id,
    'request_id', d.response_request_id,
    'version', d.version,
    'answers_encrypted', encode(d.answers_encrypted, 'base64'),
    'publication_consent', d.publication_consent,
    'saved_at', d.saved_at,
    'expires_at', d.expires_at,
    'attachments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', a.id,
        'media_type', a.media_type,
        'size_bytes', a.size_bytes,
        'sha256', a.sha256,
        'upload_status', a.upload_status,
        'scan_status', a.scan_status
      ) ORDER BY a.created_at)
      FROM intake.response_attachments a
      WHERE a.response_request_id = v_request_id AND a.upload_status <> 'DELETED'
    ), '[]'::jsonb)
  ) INTO v_result
  FROM intake.response_drafts d WHERE d.response_request_id = v_request_id;
  RETURN COALESCE(v_result, jsonb_build_object('request_id',v_request_id,'version',0,'attachments','[]'::jsonb));
END
$$;

CREATE OR REPLACE FUNCTION intake.get_response_receipt(p_receipt_token_hash char(64))
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'submission_id', s.id,
    'request_id', s.response_request_id,
    'submission_sha256', s.submission_sha256,
    'status', s.status,
    'submitted_at', s.submitted_at
  ) INTO v_result
  FROM intake.response_submissions s
  WHERE s.receipt_token_hash = p_receipt_token_hash;
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'receipt_not_found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_result;
END
$$;

CREATE OR REPLACE FUNCTION intake.create_correction_draft(
  p_token_hash char(64),
  p_locale text,
  p_case_slug text,
  p_publication_revision integer,
  p_expires_at timestamptz
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO intake.correction_request_drafts(
    token_hash, locale, case_slug, publication_revision, expires_at
  ) VALUES (
    p_token_hash, p_locale, p_case_slug, p_publication_revision, p_expires_at
  ) RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.get_correction_draft(p_token_hash char(64))
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'id', d.id,
    'version', d.version,
    'locale', d.locale,
    'case_slug', d.case_slug,
    'publication_revision', d.publication_revision,
    'requester_type', d.requester_type,
    'summary', d.summary,
    'requested_changes', d.requested_changes,
    'evidence_description', d.evidence_description,
    'expires_at', d.expires_at,
    'saved_at', d.updated_at
  ) INTO v_result
  FROM intake.correction_request_drafts d
  WHERE d.token_hash = p_token_hash AND d.expires_at > clock_timestamp();
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'correction_draft_not_found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_result;
END
$$;

CREATE OR REPLACE FUNCTION intake.save_correction_draft(
  p_token_hash char(64),
  p_expected_version bigint,
  p_requester_type text,
  p_contact_email_hash char(64),
  p_contact_email_encrypted bytea,
  p_summary text,
  p_requested_changes jsonb,
  p_evidence_description text
) RETURNS TABLE(draft_id uuid, version bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
BEGIN
  UPDATE intake.correction_request_drafts
  SET requester_type = p_requester_type,
      contact_email_hash = p_contact_email_hash,
      contact_email_encrypted = p_contact_email_encrypted,
      summary = p_summary,
      requested_changes = p_requested_changes,
      evidence_description = p_evidence_description,
      version = intake.correction_request_drafts.version + 1,
      updated_at = clock_timestamp()
  WHERE token_hash = p_token_hash
    AND expires_at > clock_timestamp()
    AND intake.correction_request_drafts.version = p_expected_version
  RETURNING id, intake.correction_request_drafts.version INTO draft_id, version;
  IF draft_id IS NULL THEN
    RAISE EXCEPTION 'correction_draft_version_conflict' USING ERRCODE = '40001';
  END IF;
  RETURN NEXT;
END
$$;

CREATE OR REPLACE FUNCTION intake.delete_correction_draft(p_token_hash char(64))
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  DELETE FROM intake.correction_request_drafts
  WHERE token_hash = p_token_hash
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'correction_draft_not_found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.create_correction_request(
  p_case_slug text,
  p_publication_revision integer,
  p_requester_type text,
  p_contact_email_hash char(64),
  p_contact_email_encrypted bytea,
  p_summary text,
  p_requested_changes jsonb,
  p_evidence_description text,
  p_receipt_token_hash char(64)
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO intake.correction_requests(
    public_case_slug, publication_revision, requester_type,
    contact_email_hash, contact_email_encrypted, summary,
    requested_changes, evidence_description, receipt_token_hash
  ) VALUES (
    p_case_slug, p_publication_revision, p_requester_type,
    p_contact_email_hash, p_contact_email_encrypted, p_summary,
    p_requested_changes, p_evidence_description, p_receipt_token_hash
  ) RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.get_correction_receipt(p_receipt_token_hash char(64))
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'request_id', r.id,
    'case_slug', r.public_case_slug,
    'publication_revision', r.publication_revision,
    'status', r.status,
    'submitted_at', r.submitted_at,
    'updated_at', r.updated_at
  ) INTO v_result
  FROM intake.correction_requests r
  WHERE r.receipt_token_hash = p_receipt_token_hash;
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'receipt_not_found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_result;
END
$$;

CREATE OR REPLACE FUNCTION intake.create_correction_attachment(
  p_receipt_token_hash char(64),
  p_request_id uuid,
  p_filename_encrypted bytea,
  p_media_type text,
  p_size_bytes bigint,
  p_sha256 char(64),
  p_object_key text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM intake.correction_requests
    WHERE id = p_request_id AND receipt_token_hash = p_receipt_token_hash
  ) THEN
    RAISE EXCEPTION 'correction_request_scope_denied' USING ERRCODE = '42501';
  END IF;
  INSERT INTO intake.correction_attachments(
    correction_request_id, original_filename_encrypted, media_type,
    size_bytes, sha256, object_key, scan_status
  ) VALUES (
    p_request_id, p_filename_encrypted, p_media_type,
    p_size_bytes, p_sha256, p_object_key, 'PENDING'
  ) RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

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
BEGIN
  INSERT INTO intake.contact_requests(
    category, name_encrypted, email_hash, email_encrypted,
    subject, message_encrypted, receipt_token_hash
  ) VALUES (
    p_category, p_name_encrypted, p_email_hash, p_email_encrypted,
    p_subject, p_message_encrypted, p_receipt_token_hash
  ) RETURNING id INTO v_id;
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
BEGIN
  INSERT INTO intake.dataset_export_requests(
    request_token_hash, email_hash, dataset_id, format, filters, expires_at
  ) VALUES (
    p_request_token_hash, p_email_hash, p_dataset_id, p_format, p_filters, p_expires_at
  ) RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.create_subscription(
  p_email_hash char(64),
  p_email_encrypted bytea,
  p_topics jsonb,
  p_frequency text,
  p_locale text,
  p_verification_token_hash char(64),
  p_management_token_hash char(64)
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO intake.subscriptions(
    email_hash, email_encrypted, topics, frequency, locale, status,
    verification_token_hash, management_token_hash
  ) VALUES (
    p_email_hash, p_email_encrypted, p_topics, p_frequency, p_locale,
    'PENDING', p_verification_token_hash, p_management_token_hash
  ) RETURNING id INTO v_id;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.get_subscription(p_management_token_hash char(64))
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'id', s.id,
    'topics', s.topics,
    'frequency', s.frequency,
    'locale', s.locale,
    'status', s.status,
    'verified_at', s.verified_at,
    'updated_at', s.updated_at
  ) INTO v_result
  FROM intake.subscriptions s
  WHERE s.management_token_hash = p_management_token_hash;
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'subscription_not_found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_result;
END
$$;

CREATE OR REPLACE FUNCTION intake.update_subscription(
  p_management_token_hash char(64),
  p_topics jsonb,
  p_frequency text,
  p_status text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  UPDATE intake.subscriptions
  SET topics = COALESCE(p_topics, topics),
      frequency = COALESCE(p_frequency, frequency),
      status = COALESCE(p_status, status),
      updated_at = clock_timestamp()
  WHERE management_token_hash = p_management_token_hash
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'subscription_not_found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.verify_subscription(p_verification_token_hash char(64))
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  UPDATE intake.subscriptions
  SET status = 'ACTIVE', verified_at = clock_timestamp(),
      verification_token_hash = NULL, updated_at = clock_timestamp()
  WHERE verification_token_hash = p_verification_token_hash
    AND status = 'PENDING'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'subscription_verification_not_found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION intake.unsubscribe(p_management_token_hash char(64))
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, intake, extensions, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  UPDATE intake.subscriptions
  SET status = 'UNSUBSCRIBED', updated_at = clock_timestamp()
  WHERE management_token_hash = p_management_token_hash
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'subscription_not_found' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_id;
END
$$;

REVOKE ALL ON FUNCTION intake.lookup_response_request_id(char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.get_response_access_status(char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.get_response_request(char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.get_response_draft(char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.get_response_receipt(char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.create_correction_draft(char,text,text,integer,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.get_correction_draft(char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.save_correction_draft(char,bigint,text,char,bytea,text,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.delete_correction_draft(char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.create_correction_request(text,integer,text,char,bytea,text,jsonb,text,char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.get_correction_receipt(char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.create_correction_attachment(char,uuid,bytea,text,bigint,char,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.create_contact_request(text,bytea,char,bytea,text,bytea,char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.create_dataset_export(char,char,text,text,jsonb,timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.create_subscription(char,bytea,jsonb,text,text,char,char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.get_subscription(char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.update_subscription(char,jsonb,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.verify_subscription(char) FROM PUBLIC;
REVOKE ALL ON FUNCTION intake.unsubscribe(char) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION intake.get_response_access_status(char),
  intake.get_response_request(char),
  intake.get_response_draft(char),
  intake.get_response_receipt(char),
  intake.create_correction_draft(char,text,text,integer,timestamptz),
  intake.get_correction_draft(char),
  intake.save_correction_draft(char,bigint,text,char,bytea,text,jsonb,text),
  intake.delete_correction_draft(char),
  intake.create_correction_request(text,integer,text,char,bytea,text,jsonb,text,char),
  intake.get_correction_receipt(char),
  intake.create_correction_attachment(char,uuid,bytea,text,bigint,char,text),
  intake.create_contact_request(text,bytea,char,bytea,text,bytea,char),
  intake.create_dataset_export(char,char,text,text,jsonb,timestamptz),
  intake.create_subscription(char,bytea,jsonb,text,text,char,char),
  intake.get_subscription(char),
  intake.update_subscription(char,jsonb,text,text),
  intake.verify_subscription(char),
  intake.unsubscribe(char)
  TO gurine_submission_api;

COMMIT;
