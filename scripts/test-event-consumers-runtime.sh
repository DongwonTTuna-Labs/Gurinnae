#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-event-consumers-$BASHPID"
database="gurine_event_consumers"
work="$(mktemp -d -t gurine-event-consumers-XXXXXX)"
clamav_pid=""
smtp_pid=""

cleanup() {
  status=$?
  trap - EXIT
  [[ -z "$clamav_pid" ]] || kill "$clamav_pid" >/dev/null 2>&1 || true
  [[ -z "$smtp_pid" ]] || kill "$smtp_pid" >/dev/null 2>&1 || true
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

cd "$root"
cargo build -p gurine-scheduler -p gurine-analysis-worker -p gurine-workflow-worker \
  -p gurine-projection-worker -p gurine-notification-worker \
  -p gurine-acceptance-tests --bins

docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
for migration in db/migrations/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <"$migration" >/dev/null
done
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "ALTER ROLE gurine_scheduler LOGIN PASSWORD 'scheduler_test'; ALTER ROLE gurine_analysis_worker LOGIN PASSWORD 'analysis_test'; ALTER ROLE gurine_workflow_worker LOGIN PASSWORD 'workflow_test'; ALTER ROLE gurine_public_projector LOGIN PASSWORD 'projector_test'; ALTER ROLE gurine_notification_worker LOGIN PASSWORD 'notification_test';" >/dev/null

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  attachment_id constant text := '31200000-0000-4000-8000-000000000901';
  missing_kind_denied boolean := false;
  invalid_kind_denied boolean := false;
BEGIN
  PERFORM ops.event_payload_admissible_v1(
    'attachment.scan_completed.v1',
    jsonb_build_object(
      'attachment_id',attachment_id,
      'attachment_kind','CORRECTION',
      'scan_status','CLEAN',
      'sha256',repeat('a',64)
    )
  );
  PERFORM ops.event_payload_admissible_v1(
    'attachment.scan_completed.v1',
    jsonb_build_object(
      'attachment_id',attachment_id,
      'attachment_kind','RESPONSE',
      'scan_status','CLEAN',
      'sha256',repeat('b',64)
    )
  );

  BEGIN
    PERFORM ops.event_payload_admissible_v1(
      'attachment.scan_completed.v1',
      jsonb_build_object(
        'attachment_id',attachment_id,
        'scan_status','CLEAN',
        'sha256',repeat('c',64)
      )
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    missing_kind_denied := SQLERRM LIKE
      'EVENT_PAYLOAD_SCHEMA_INVALID:attachment.scan_completed.v1:%';
  END;
  BEGIN
    PERFORM ops.event_payload_admissible_v1(
      'attachment.scan_completed.v1',
      jsonb_build_object(
        'attachment_id',attachment_id,
        'attachment_kind','DOCUMENT',
        'scan_status','CLEAN',
        'sha256',repeat('d',64)
      )
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    invalid_kind_denied := SQLERRM LIKE
      'EVENT_PAYLOAD_SCHEMA_INVALID:attachment.scan_completed.v1:%';
  END;

  IF NOT missing_kind_denied OR NOT invalid_kind_denied THEN
    RAISE EXCEPTION
      'attachment kind admission closure invalid: missing %, invalid %',
      missing_kind_denied,invalid_kind_denied;
  END IF;
END $$;
SQL

# D2 proof objects are closed.  JSON null must never pass the definitive
# failure or ambiguity boundaries through SQL three-valued logic.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
SET ROLE gurine_analysis_worker;
DO $$
DECLARE
  v_run_id constant uuid := '31200000-0000-4000-8000-000000000901';
  v_prior_receipt_id constant uuid :=
    '31200000-0000-4000-8000-000000000902';
  v_job_id constant uuid := '31200000-0000-4000-8000-000000000903';
  v_lease_token constant uuid := '31200000-0000-4000-8000-000000000904';
  v_failure_proof jsonb;
  v_failure_proof_sha256 char(64);
  v_ambiguity_proof jsonb;
  v_ambiguity_proof_sha256 char(64);
  v_failure_denied boolean := false;
  v_ambiguity_denied boolean := false;
BEGIN
  v_failure_proof := jsonb_build_object(
    'schemaVersion','agent-run-definitive-failure-proof.v1',
    'runId',v_run_id,'failureCode',NULL,
    'detailSha256',repeat('2',64),'redacted',true
  );
  v_failure_proof_sha256 := encode(
    extensions.digest(
      ops.canonical_jsonb_v1(v_failure_proof),'sha256'
    ),'hex'
  );
  BEGIN
    PERFORM * FROM ops.complete_agent_run_worker_v2(
      v_run_id,2,v_prior_receipt_id,repeat('1',64),v_job_id,
      v_lease_token,1,'FAILED',NULL,NULL,NULL,NULL,
      'INTERNAL_EXECUTION_FAILED',v_failure_proof,
      v_failure_proof_sha256,0
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_failure_denied := SQLERRM='agent_run_failure_proof_invalid';
  END;

  v_ambiguity_proof := jsonb_build_object(
    'schemaVersion','agent-run-ambiguity-proof.v1',
    'runId',v_run_id,'reasonCode','PROVIDER_OUTCOME_UNKNOWN',
    'detailSha256',NULL,'redacted',true
  );
  v_ambiguity_proof_sha256 := encode(
    extensions.digest(
      ops.canonical_jsonb_v1(v_ambiguity_proof),'sha256'
    ),'hex'
  );
  BEGIN
    PERFORM * FROM ops.mark_agent_run_reconciliation_required_worker_v2(
      v_run_id,2,v_prior_receipt_id,repeat('1',64),v_job_id,
      v_lease_token,1,v_ambiguity_proof,v_ambiguity_proof_sha256
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_ambiguity_denied := SQLERRM='agent_run_ambiguity_proof_invalid';
  END;

  IF NOT v_failure_denied OR NOT v_ambiguity_denied THEN
    RAISE EXCEPTION
      'agent run proof null closure invalid: failure %, ambiguity %',
      v_failure_denied,v_ambiguity_denied;
  END IF;
END $$;
RESET ROLE;
SQL

# TEST_ONLY retention-policy authority is shared with the Control and
# Submission runtime harnesses.  It creates real two-reviewer approval and
# execution receipt graphs, then defers only its own outbox events.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" < db/test-fixtures/r6d-approved-policy-authority.sql \
  >/dev/null

# R6d privacy uses only TEST_ONLY approved policy/calendar authority in this
# disposable database.  Every probe is rolled back before legacy queue counts.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
\set ON_ERROR_STOP on

-- R6d privacy transition success and fail-closed probe.
--
-- Prerequisites (same psql session, disposable PostgreSQL 18 database):
--   1. migrations 0001..0038 plus the candidate privacy overlays;
--   2. db/test-fixtures/r6d-approved-policy-authority.sql;
--   3. /tmp/r6d-test-calendar-authority-fixture.sql.
--
-- The final probe is rollback-only.  It exercises the service ACL with SET
-- LOCAL ROLE while retaining a gurine_migrator-member session_user so the
-- deliberately TEST_ONLY calendar authority can be selected.  A separate
-- negative block uses an actual service session_user and proves that the same
-- TEST_ONLY rows fail closed without durable writes.

BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SET CONSTRAINTS ALL DEFERRED;
SET LOCAL TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.r6d_transition_sha256_text_v1(p_value text)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,extensions,pg_temp
AS $digest$
  SELECT encode(
    extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex'
  )::char(64)
$digest$;

CREATE FUNCTION pg_temp.r6d_transition_sha256_json_v1(p_value jsonb)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $digest$
  SELECT encode(
    extensions.digest(ops.canonical_jsonb_v1(p_value),'sha256'),'hex'
  )::char(64)
$digest$;

CREATE FUNCTION pg_temp.r6d_transition_uuid_v1(
  p_label text
) RETURNS uuid
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,extensions,pg_temp
AS $uuid$
  WITH hashed(value) AS (
    SELECT encode(extensions.digest(convert_to(
      'r6d-transition-success-probe:'||p_label,'UTF8'
    ),'sha256'),'hex')
  )
  SELECT (
    substr(value,1,8)||'-'||substr(value,9,4)||'-4'||substr(value,14,3)
    ||'-a'||substr(value,18,3)||'-'||substr(value,21,12)
  )::uuid
  FROM hashed
$uuid$;

CREATE FUNCTION pg_temp.r6d_transition_envelope_v1(
  p_label text
) RETURNS bytea
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,pg_temp
AS $envelope$
  SELECT convert_to(
    'gurine-fe-v1.key-v1.'||p_label||'.cipher','UTF8'
  )
$envelope$;

CREATE FUNCTION pg_temp.r6d_transition_base64_v1(
  p_value bytea
) RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,pg_temp
AS $base64$
  SELECT replace(encode(p_value,'base64'),E'\n','')
$base64$;

CREATE FUNCTION pg_temp.r6d_transition_payload_v1(
  p_privacy_request_id uuid,
  p_transition text,
  p_expected_decision_version bigint,
  p_transition_receipt_id uuid,
  p_actor_assertion_jti uuid,
  p_actor_assertion_request_sha256 char(64),
  p_step_up_authorization_id uuid,
  p_idempotency_key_sha256 char(64),
  p_action_digest char(64),
  p_reason_label text,
  p_variant jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $payload$
DECLARE
  v_reason bytea:=pg_temp.r6d_transition_envelope_v1(p_reason_label);
  v_payload jsonb;
BEGIN
  IF jsonb_typeof(p_variant)<>'object' THEN
    RAISE EXCEPTION 'r6d_transition_probe_variant_invalid'
      USING ERRCODE='22023';
  END IF;
  v_payload:=jsonb_build_object(
    'retentionRequestId',p_privacy_request_id,
    'expectedDecisionVersion',p_expected_decision_version,
    'transition',p_transition,
    'reasonCode','TEST_ONLY_'||p_transition,
    'reasonCiphertextBase64',
      pg_temp.r6d_transition_base64_v1(v_reason),
    'reasonSha256',pg_temp.r6d_transition_sha256_text_v1(
      'plaintext-digest-preimage:'||p_reason_label
    ),
    'transitionReceiptId',p_transition_receipt_id,
    '_actorAssertionJti',p_actor_assertion_jti,
    '_actorAssertionRequestSha256',
      btrim(p_actor_assertion_request_sha256),
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','privacy.requests.manage',
    '_actorActionDigest',btrim(p_action_digest),
    '_actorStepUpAuthorizationId',p_step_up_authorization_id,
    '_actorIdempotencyKeySha256',btrim(p_idempotency_key_sha256),
    '_actorRequestKeySha256',btrim(p_idempotency_key_sha256)
  )||p_variant;
  RETURN v_payload;
END
$payload$;

CREATE FUNCTION pg_temp.r6d_transition_write_fingerprint_v1()
RETURNS char(64)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $fingerprint$
  SELECT pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
    'idempotency',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY scope,key_hash)
      FROM ops.idempotency_keys AS row_value
    ),'[]'::jsonb),
    'audit',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY occurred_at,id)
      FROM ops.audit_events AS row_value
    ),'[]'::jsonb),
    'outbox',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY occurred_at,id)
      FROM ops.outbox AS row_value
    ),'[]'::jsonb),
    'stepUp',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY id)
      FROM ops.step_up_authorizations AS row_value
    ),'[]'::jsonb),
    'subjects',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY id)
      FROM intake.communication_subjects AS row_value
    ),'[]'::jsonb),
    'endpoints',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY id)
      FROM intake.communication_endpoints AS row_value
    ),'[]'::jsonb),
    'requests',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY id)
      FROM ops.privacy_requests_v2 AS row_value
    ),'[]'::jsonb),
    'receiptTokens',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY token_id)
      FROM ops.privacy_request_receipt_tokens_v2 AS row_value
    ),'[]'::jsonb),
    'submissionSessions',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY id)
      FROM intake.submission_sessions AS row_value
    ),'[]'::jsonb),
    'identityReceipts',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY identity_receipt_id)
      FROM ops.privacy_request_identity_receipts_v2 AS row_value
    ),'[]'::jsonb),
    'extensionReceipts',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY extension_receipt_id)
      FROM ops.privacy_request_extension_receipts_v2 AS row_value
    ),'[]'::jsonb),
    'refusalReceipts',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY refusal_receipt_id)
      FROM ops.privacy_request_refusal_receipts_v2 AS row_value
    ),'[]'::jsonb),
    'noticeReceipts',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY notice_receipt_id)
      FROM ops.privacy_request_notice_receipts_v2 AS row_value
    ),'[]'::jsonb),
    'transitionReceipts',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value) ORDER BY transition_receipt_id)
      FROM ops.privacy_request_transition_receipts_v2 AS row_value
    ),'[]'::jsonb),
    'sealedContent',COALESCE((
      SELECT jsonb_agg(to_jsonb(row_value)
        ORDER BY transition_receipt_id,field_kind)
      FROM ops.privacy_request_sealed_content_v2 AS row_value
    ),'[]'::jsonb)
  ))
$fingerprint$;

GRANT EXECUTE ON FUNCTION
  pg_temp.r6d_transition_sha256_text_v1(text),
  pg_temp.r6d_transition_sha256_json_v1(jsonb),
  pg_temp.r6d_transition_uuid_v1(text),
  pg_temp.r6d_transition_envelope_v1(text),
  pg_temp.r6d_transition_base64_v1(bytea),
  pg_temp.r6d_transition_payload_v1(
    uuid,text,bigint,uuid,uuid,char(64),uuid,char(64),char(64),text,jsonb
  ),
  pg_temp.r6d_transition_write_fingerprint_v1()
TO gurine_control_api;

GRANT EXECUTE ON FUNCTION
  pg_temp.r6d_transition_base64_v1(bytea)
TO gurine_notification_worker;

DO $prerequisites$
DECLARE
  v_missing text[];
  v_selected_policy jsonb;
BEGIN
  IF current_database() NOT IN (
    'gurine_control_test',
    'gurine_submission_test',
    'gurine_event_consumers'
  ) THEN
    RAISE EXCEPTION 'r6d_transition_probe_database_forbidden'
      USING ERRCODE='55000';
  END IF;
  IF NOT pg_has_role(session_user,'gurine_migrator','MEMBER') THEN
    RAISE EXCEPTION 'r6d_transition_probe_session_forbidden'
      USING ERRCODE='42501';
  END IF;

  SELECT array_agg(signature ORDER BY signature) INTO v_missing
  FROM (VALUES
    ('ops.transition_privacy_request_v2(jsonb,uuid,uuid,uuid,character,character)'),
    ('ops.read_privacy_request_notification_delivery_v1(uuid)'),
    ('ops.current_privacy_response_policy_calendar_v1(timestamp with time zone)'),
    ('ops.add_privacy_business_days_v1(timestamp with time zone,integer,uuid,character)')
  ) AS expected(signature)
  WHERE to_regprocedure(signature) IS NULL;
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'r6d_transition_probe_owner_abi_missing: %',v_missing
      USING ERRCODE='55000';
  END IF;

  IF to_regclass('ops.privacy_request_sealed_content_v2') IS NULL THEN
    RAISE EXCEPTION 'r6d_transition_probe_sealed_content_missing'
      USING ERRCODE='55000';
  END IF;
  v_selected_policy:=ops.current_privacy_response_policy_calendar_v1(
    clock_timestamp()
  );
  IF (v_selected_policy->>'policyId')::uuid<>
       'a6d00000-0000-4000-8000-000000000001'::uuid
     OR (v_selected_policy->>'revision')::bigint<>2
     OR v_selected_policy->>'policyVersion'<>'test-only-r6d-v1'
     OR (v_selected_policy->>'calendarVersionId')::uuid<>
       'a6d40000-0000-4000-8000-000000000001'::uuid
     OR (v_selected_policy->>'maximumExtensionBusinessDays')::integer<>10
     OR (v_selected_policy->>'maximumExtensionCount')::integer<>1
     OR (v_selected_policy->>'refusalNoticeBusinessDays')::integer<>10 THEN
    RAISE EXCEPTION 'r6d_transition_probe_calendar_fixture_invalid'
      USING ERRCODE='55000';
  END IF;
END
$prerequisites$;

CREATE FUNCTION pg_temp.r6d_transition_install_root_v1(
  p_label text,
  p_state text,
  p_identity_state text,
  p_decision_version bigint,
  p_due_at timestamptz
) RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,extensions,pg_temp
AS $fixture$
DECLARE
  v_request_id uuid:=pg_temp.r6d_transition_uuid_v1(p_label||'-request');
  v_subject_id uuid:=pg_temp.r6d_transition_uuid_v1(p_label||'-subject');
  v_endpoint_id uuid:=pg_temp.r6d_transition_uuid_v1(p_label||'-endpoint');
  v_identity_receipt_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-identity-receipt');
  v_source_response_receipt_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-identity-proof');
  v_identity_proof_authority_receipt_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-identity-proof-authority');
  v_source_response_request_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-source-response-request');
  v_source_subject_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-source-subject');
  v_source_endpoint_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-source-endpoint');
  v_source_link_event_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-source-link-event');
  v_source_response_submission_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-source-response-submission');
  v_source_sent_receipt_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-source-sent-receipt');
  v_create_request_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-create-request');
  v_identity_verified_at timestamptz:=CASE
    WHEN p_due_at IS NOT NULL AND p_due_at<=clock_timestamp()
      THEN p_due_at-interval '10 days'
    ELSE clock_timestamp()
  END;
  v_created_at timestamptz:=LEAST(
    '2026-07-23 00:00:00+00'::timestamptz,
    v_identity_verified_at-interval '1 day'
  );
  v_source_at timestamptz:=v_created_at;
  v_effective_due_at timestamptz;
  v_policy jsonb;
  v_subject_origin_digest char(64);
  v_subject_profile_digest char(64);
  v_endpoint_hmac char(64);
  v_endpoint_digest char(64);
  v_endpoint_aad_digest char(64);
  v_source_subject_origin_digest char(64);
  v_source_subject_profile_digest char(64);
  v_source_endpoint_digest char(64);
  v_source_endpoint_aad_digest char(64);
  v_source_possession_hmac char(64);
  v_source_submission_digest char(64);
  v_source_response_request_binding_digest char(64);
  v_source_publication_consent jsonb;
  v_source_publication_consent_digest char(64);
  v_source_response_receipt_payload jsonb;
  v_source_response_receipt_digest char(64);
  v_source_current_binding_payload jsonb;
  v_source_current_binding_digest char(64);
  v_identity_proof_binding_digest char(64);
  v_subject_proof_hash char(64);
  v_scope_sha256 char(64);
  v_subject_scope_digest char(64);
  v_identity_proof_authority_payload jsonb;
  v_identity_proof_authority_canonical bytea;
  v_identity_proof_authority_digest char(64);
  v_identity_payload jsonb;
  v_identity_canonical bytea;
  v_identity_digest char(64);
  v_install_identity_transition boolean:=p_label='main';
  v_identity_transition_receipt_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-identity-transition-receipt');
  v_identity_notice_receipt_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-identity-notice-receipt');
  v_identity_actor_assertion_jti uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-identity-assertion-jti');
  v_identity_step_up_authorization_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-identity-step-up');
  v_identity_transition_request_id uuid:=
    pg_temp.r6d_transition_uuid_v1(p_label||'-identity-owner-request');
  v_identity_reason_ciphertext bytea:=
    pg_temp.r6d_transition_envelope_v1(p_label||'_identity_reason');
  v_identity_reason_sha256 char(64):=
    pg_temp.r6d_transition_sha256_text_v1(
      'identity-reason-plaintext:'||p_label
    );
  v_identity_reason_aad_digest char(64);
  v_identity_action_digest char(64):=
    pg_temp.r6d_transition_sha256_text_v1('identity-action:'||p_label);
  v_identity_idempotency_sha256 char(64):=
    pg_temp.r6d_transition_sha256_text_v1('identity-idempotency:'||p_label);
  v_identity_request_sha256 char(64):=
    pg_temp.r6d_transition_sha256_text_v1('identity-request:'||p_label);
  v_identity_notice_template jsonb;
  v_identity_notice_template_digest char(64);
  v_identity_notice_aad_digest char(64);
  v_identity_notice_payload jsonb;
  v_identity_notice_canonical bytea;
  v_identity_notice_digest char(64);
  v_identity_transition_payload jsonb;
  v_identity_transition_canonical bytea;
  v_identity_transition_digest char(64);
  v_identity_event_payload jsonb;
  v_identity_event_id uuid;
  v_identity_event_digest char(64);
  v_identity_audit_event_id uuid;
  v_create_audit_event_id uuid;
  v_create_outbox_event_id uuid;
  v_create_receipt_digest char(64);
  v_envelope bytea:=
    pg_temp.r6d_transition_envelope_v1(p_label||'_root');
BEGIN
  IF p_state NOT IN ('RECEIVED','REVIEW')
     OR p_identity_state NOT IN ('PENDING_VERIFICATION','VERIFIED')
     OR p_decision_version<0
     OR (p_identity_state='PENDING_VERIFICATION' AND (
       p_decision_version<>0 OR p_due_at IS NOT NULL
     ))
     OR (p_identity_state='VERIFIED' AND p_decision_version<1) THEN
    RAISE EXCEPTION 'r6d_transition_root_fixture_input_invalid'
      USING ERRCODE='22023';
  END IF;

  v_policy:=ops.current_privacy_response_policy_calendar_v1(
    clock_timestamp()
  );
  IF p_identity_state='VERIFIED' THEN
    v_effective_due_at:=COALESCE(
      p_due_at,
      ops.add_privacy_business_days_v1(
        v_identity_verified_at,10,
        (v_policy->>'calendarVersionId')::uuid,
        (v_policy->>'calendarDigest')::char(64)
      )
    );
    IF v_effective_due_at<=v_identity_verified_at THEN
      RAISE EXCEPTION 'r6d_transition_root_fixture_due_invalid'
        USING ERRCODE='22023';
    END IF;
  END IF;
  v_subject_origin_digest:=pg_temp.r6d_transition_sha256_json_v1(
    jsonb_build_object(
      'schemaVersion','privacy-request-subject-origin.v1',
      'privacyRequestId',v_request_id,
      'subjectId',v_subject_id
    )
  );
  v_subject_profile_digest:=pg_temp.r6d_transition_sha256_json_v1(
    jsonb_build_object(
      'schemaVersion','privacy-request-subject-profile.v1',
      'subjectId',v_subject_id,'locale','ko-KR',
      'jurisdiction','KR','status','ACTIVE'
    )
  );
  v_endpoint_hmac:=pg_temp.r6d_transition_sha256_text_v1(
    'endpoint-hmac:'||p_label
  );
  v_endpoint_aad_digest:=ops.r6d_nul5_sha256_v1(
    'intake.communication_endpoints','endpoint_ciphertext',
    v_endpoint_id::text,'email-address','1'
  );
  v_endpoint_digest:=pg_temp.r6d_transition_sha256_json_v1(
    jsonb_build_object(
      'schemaVersion','privacy-request-endpoint-snapshot.v1',
      'endpointId',v_endpoint_id,'subjectId',v_subject_id,
      'channel','SMTP_EMAIL','endpointHmac',btrim(v_endpoint_hmac),
      'hmacKeyVersion','hmac-v1','encryptionKeyId','key-v1',
      'endpointAadDigest',btrim(v_endpoint_aad_digest),
      'state','ACTIVE','version',1
    )
  );
  v_source_subject_origin_digest:=
    pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
      'schemaVersion','test-only-response-subject-origin.v1',
      'responseRequestId',v_source_response_request_id,
      'subjectId',v_source_subject_id
    ));
  v_source_subject_profile_digest:=
    pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
      'schemaVersion','test-only-response-subject-profile.v1',
      'subjectId',v_source_subject_id,'locale','ko-KR',
      'jurisdiction','KR','status','ACTIVE'
    ));
  v_source_endpoint_aad_digest:=ops.r6d_nul5_sha256_v1(
    'intake.communication_endpoints','endpoint_ciphertext',
    v_source_endpoint_id::text,'email-address','1'
  );
  v_source_endpoint_digest:=
    pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
      'schemaVersion','test-only-response-endpoint-snapshot.v1',
      'endpointId',v_source_endpoint_id,'subjectId',v_source_subject_id,
      'channel','SMTP_EMAIL','endpointHmac',btrim(v_endpoint_hmac),
      'hmacKeyVersion','hmac-v1','encryptionKeyId','key-v1',
      'endpointAadDigest',btrim(v_source_endpoint_aad_digest),
      'state','ACTIVE','version',1
    ));
  v_source_possession_hmac:=pg_temp.r6d_transition_sha256_text_v1(
    'possession:'||p_label
  );
  v_source_submission_digest:=
    pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
      'schemaVersion','test-only-response-submission.v1',
      'responseSubmissionId',v_source_response_submission_id,
      'responseRequestId',v_source_response_request_id,
      'draftVersion',1,'submittedAt',v_source_at
    ));
  v_source_response_request_binding_digest:=
    pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
      'schemaVersion','test-only-response-request-binding.v1',
      'responseRequestId',v_source_response_request_id,
      'responseRequestVersion',2,'endpointId',v_source_endpoint_id,
      'endpointVersion',1,'endpointDigest',btrim(v_source_endpoint_digest)
    ));
  v_source_publication_consent:=jsonb_build_object(
    'bodyConsent',true,'attachmentConsents','[]'::jsonb,
    'identityDisplay','ANONYMOUS','redactionAcknowledged',true,
    'excerptReviewRequested',false,'consentedAt',v_source_at
  );
  v_source_publication_consent_digest:=
    pg_temp.r6d_transition_sha256_json_v1(v_source_publication_consent);
  v_source_response_receipt_payload:=jsonb_build_object(
    'schemaVersion','response-submission-receipt.v3',
    'responseSubmissionId',v_source_response_submission_id,
    'responseRequestId',v_source_response_request_id,
    'responseRequestVersion',2,
    'responseRequestBindingDigest',
      btrim(v_source_response_request_binding_digest),
    'draftVersion',1,'submissionSha256',btrim(v_source_submission_digest),
    'publicationConsentSha256',btrim(v_source_publication_consent_digest),
    'receiptVersion',1,'submittedAt',v_source_at
  );
  v_source_response_receipt_digest:=
    pg_temp.r6d_transition_sha256_json_v1(
      v_source_response_receipt_payload
    );
  v_source_current_binding_payload:=jsonb_build_object(
    'schemaVersion','privacy-response-receipt-source-binding.v1',
    'receiptId',v_source_response_receipt_id,
    'responseSubmissionId',v_source_response_submission_id,
    'responseRequestId',v_source_response_request_id,
    'responseRequestVersion',2,
    'responseRequestBindingDigest',
      btrim(v_source_response_request_binding_digest),
    'submissionSha256',btrim(v_source_submission_digest),
    'receiptVersion',1,
    'receiptDigest',btrim(v_source_response_receipt_digest),
    'possessionTokenHmac',btrim(v_source_possession_hmac),
    'subjectId',v_source_subject_id,
    'subjectOriginDigest',btrim(v_source_subject_origin_digest),
    'subjectProfileVersion',1,
    'subjectProfileDigest',btrim(v_source_subject_profile_digest),
    'endpointId',v_source_endpoint_id,'endpointVersion',1,
    'endpointDigest',btrim(v_source_endpoint_digest),
    'channel','SMTP_EMAIL'
  );
  v_source_current_binding_digest:=
    pg_temp.r6d_transition_sha256_json_v1(
      v_source_current_binding_payload
    );
  v_identity_proof_binding_digest:=
    pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
      'kind','RESPONSE_RECEIPT','receiptId',v_source_response_receipt_id,
      'possessionTokenHmac',btrim(v_source_possession_hmac)
    ));
  v_subject_proof_hash:=pg_temp.r6d_transition_sha256_json_v1(
    jsonb_build_object(
      'schemaVersion','privacy-subject-proof.v1',
      'identityProofKind','RESPONSE_RECEIPT',
      'identityProofRefId',v_source_response_receipt_id,
      'identityProofBindingDigest',btrim(v_identity_proof_binding_digest)
    )
  );
  v_scope_sha256:=pg_temp.r6d_transition_sha256_json_v1(
    jsonb_build_object(
      'scopeKind','ALL_VERIFIED_SUBJECT_DATA','objectRefs','[]'::jsonb,
      'dateFrom',NULL,'dateTo',NULL,
      'includeDerivatives',true,'includeBackups',false
    )
  );
  v_subject_scope_digest:=pg_temp.r6d_transition_sha256_json_v1(
    jsonb_build_object(
      'schemaVersion','privacy-subject-scope-v1',
      'subjectProofHash',btrim(v_subject_proof_hash),
      'scopeSha256',btrim(v_scope_sha256)
    )
  );
  v_create_receipt_digest:=pg_temp.r6d_transition_sha256_json_v1(
    jsonb_build_object(
      'schemaVersion','test-only-privacy-request-create-receipt.v1',
      'privacyRequestId',v_request_id,'label',p_label
    )
  );
  IF p_identity_state='VERIFIED' THEN
    v_identity_proof_authority_payload:=jsonb_build_object(
      'schemaVersion','privacy-identity-proof-authority-receipt.v1',
      'identityProofReceiptId',v_identity_proof_authority_receipt_id,
      'privacyRequestId',v_request_id,'proofKind','RESPONSE_RECEIPT',
      'sourceProofId',v_source_response_receipt_id,
      'sourceProofDigest',btrim(v_source_response_receipt_digest),
      'sourceCurrentBindingDigest',btrim(v_source_current_binding_digest),
      'subjectProofHash',btrim(v_subject_proof_hash),
      'subjectBindingDigest',btrim(v_identity_proof_binding_digest),
      'exactScopeDigest',btrim(v_scope_sha256),
      'requestCreateReceiptDigest',btrim(v_create_receipt_digest),
      'createdAt',v_created_at
    );
    v_identity_proof_authority_canonical:=
      ops.canonical_jsonb_v1(v_identity_proof_authority_payload);
    v_identity_proof_authority_digest:=encode(extensions.digest(
      v_identity_proof_authority_canonical,'sha256'
    ),'hex');
  END IF;

  INSERT INTO intake.communication_subjects(
    id,subject_kind,origin_object_type,origin_object_id,
    origin_object_version,origin_binding_digest,subject_pseudonym_hmac,
    hmac_key_version,jurisdiction,locale,status,profile_version,
    profile_digest,created_at,updated_at
  ) VALUES(
    v_subject_id,'PRIVACY_REQUESTER','PRIVACY_REQUEST',v_request_id,
    1,v_subject_origin_digest,
    pg_temp.r6d_transition_sha256_text_v1('subject-hmac:'||p_label),
    'hmac-v1','KR','ko-KR','ACTIVE',1,v_subject_profile_digest,
    v_created_at,v_created_at
  );
  INSERT INTO intake.communication_endpoints(
    id,subject_id,channel,endpoint_hmac,hmac_key_version,
    endpoint_ciphertext,encryption_key_id,state,version,endpoint_digest,
    endpoint_aad_digest,verified_at,created_at,updated_at
  ) VALUES(
    v_endpoint_id,v_subject_id,'SMTP_EMAIL',v_endpoint_hmac,'hmac-v1',
    pg_temp.r6d_transition_envelope_v1(p_label||'_endpoint'),
    'key-v1','ACTIVE',1,v_endpoint_digest,v_endpoint_aad_digest,
    v_identity_verified_at,v_created_at,v_identity_verified_at
  );

  -- TEST_ONLY: verified roots need the same immutable RESPONSE_RECEIPT source
  -- graph consumed by the 0039 D3 currentness helper.  Only FK parents outside
  -- that read set are bypassed while installing these disposable source roots.
  IF p_identity_state='VERIFIED' THEN
    IF current_setting('session_replication_role')<>'origin' THEN
      RAISE EXCEPTION 'r6d_transition_source_fixture_role_invalid'
        USING ERRCODE='55000';
    END IF;
    PERFORM set_config('session_replication_role','replica',true);
    BEGIN
      INSERT INTO intake.communication_subjects(
        id,subject_kind,origin_object_type,origin_object_id,
        origin_object_version,origin_binding_digest,subject_pseudonym_hmac,
        hmac_key_version,jurisdiction,locale,status,profile_version,
        profile_digest,created_at,updated_at
      ) VALUES(
        v_source_subject_id,'RESPONSE_PARTY','RESPONSE_REQUEST',
        v_source_response_request_id,1,v_source_subject_origin_digest,
        pg_temp.r6d_transition_sha256_text_v1(
          'source-subject-hmac:'||p_label
        ),'hmac-v1','KR','ko-KR','ACTIVE',1,
        v_source_subject_profile_digest,v_source_at,v_source_at
      );
      INSERT INTO intake.communication_endpoints(
        id,subject_id,channel,endpoint_hmac,hmac_key_version,
        endpoint_ciphertext,encryption_key_id,state,version,endpoint_digest,
        endpoint_aad_digest,verified_at,created_at,updated_at
      ) VALUES(
        v_source_endpoint_id,v_source_subject_id,'SMTP_EMAIL',
        v_endpoint_hmac,'hmac-v1',
        pg_temp.r6d_transition_envelope_v1(
          p_label||'_source_endpoint'
        ),'key-v1','ACTIVE',1,v_source_endpoint_digest,
        v_source_endpoint_aad_digest,v_source_at,v_source_at,v_source_at
      );
      INSERT INTO intake.communication_endpoint_link_events(
        id,subject_id,subject_origin_binding_digest,endpoint_id,
        endpoint_sequence,profile_version,endpoint_version,endpoint_hmac,
        endpoint_digest,channel,state,change_kind,proof_digest,reason_code,
        endpoint_snapshot_digest,event_digest,audit_event_id,receipt_digest,
        occurred_at
      ) VALUES(
        v_source_link_event_id,v_source_subject_id,
        v_source_subject_origin_digest,v_source_endpoint_id,1,1,1,
        v_endpoint_hmac,v_source_endpoint_digest,'SMTP_EMAIL','ACTIVE',
        'VERIFIED',pg_temp.r6d_transition_sha256_json_v1(
          jsonb_build_object(
            'schemaVersion','test-only-response-source-link-proof.v1',
            'endpointId',v_source_endpoint_id,'endpointVersion',1
          )
        ),'TEST_ONLY_RESPONSE_RECEIPT_SOURCE',v_source_endpoint_digest,
        pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-link-event.v1',
          'eventId',v_source_link_event_id,'state','ACTIVE'
        )),pg_temp.r6d_transition_uuid_v1(
          p_label||'-source-link-audit-event'
        ),pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-link-receipt.v1',
          'eventId',v_source_link_event_id,
          'endpointDigest',btrim(v_source_endpoint_digest)
        )),v_source_at
      );
      INSERT INTO intake.response_submissions(
        id,response_request_id,draft_version,submission_sha256,
        answers_encrypted,publication_consent,status,submitted_at,
        receipt_token_hash,receipt_version,receipt_digest,receipt_updated_at
      ) VALUES(
        v_source_response_submission_id,v_source_response_request_id,1,
        v_source_submission_digest,
        pg_temp.r6d_transition_envelope_v1(
          p_label||'_source_response'
        ),v_source_publication_consent,'SUBMITTED',v_source_at,
        v_source_possession_hmac,1,v_source_response_receipt_digest,
        v_source_at
      );
      INSERT INTO intake.response_submission_receipts_v3(
        receipt_id,response_submission_id,response_request_id,
        response_request_version,response_request_binding_digest,draft_version,
        submission_sha256,publication_consent_sha256,receipt_version,
        receipt_digest,receipt_session_id,receipt_session_expires_at,
        domain_event_id,notification_event_id,workflow_event_id,
        workflow_event_envelope_digest,actor_type,actor_id,audit_event_id,
        idempotency_key_sha256,request_digest,submitted_at,created_at,
        retention_schedule_id,retention_record_class,retention_schedule_digest
      ) VALUES(
        v_source_response_receipt_id,v_source_response_submission_id,
        v_source_response_request_id,2,
        v_source_response_request_binding_digest,1,
        v_source_submission_digest,v_source_publication_consent_digest,1,
        v_source_response_receipt_digest,
        pg_temp.r6d_transition_uuid_v1(
          p_label||'-source-receipt-session'
        ),v_source_at+interval '1 day',
        pg_temp.r6d_transition_uuid_v1(
          p_label||'-source-domain-event'
        ),pg_temp.r6d_transition_uuid_v1(
          p_label||'-source-notification-event'
        ),pg_temp.r6d_transition_uuid_v1(
          p_label||'-source-workflow-event'
        ),pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-workflow-envelope.v1',
          'responseSubmissionId',v_source_response_submission_id
        )),'SERVICE','submission-api',
        pg_temp.r6d_transition_uuid_v1(
          p_label||'-source-submission-audit-event'
        ),pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-idempotency.v1',
          'responseSubmissionId',v_source_response_submission_id
        )),pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-request.v1',
          'responseSubmissionId',v_source_response_submission_id
        )),v_source_at,v_source_at,
        pg_temp.r6d_transition_uuid_v1(
          p_label||'-source-retention-schedule'
        ),'RESPONSE_IDENTITY_GOVERNANCE',
        pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-retention.v1',
          'recordClass','RESPONSE_IDENTITY_GOVERNANCE',
          'responseSubmissionId',v_source_response_submission_id
        ))
      );
      INSERT INTO editorial.response_request_sent_receipts(
        id,source_event_id,source_event_envelope_digest,response_request_id,
        prior_request_version,request_version,response_request_binding_digest,
        scope_digest,prior_state,state,communication_intent_id,
        communication_intent_digest,rendering_id,rendering_digest,
        rendered_sha256,response_access_token_id,
        access_artifact_binding_digest,endpoint_id,endpoint_version,
        endpoint_snapshot_digest,channel,provider_config_id,
        provider_config_version,provider_configuration_digest,
        provider_preflight_receipt_id,provider_preflight_receipt_digest,
        delivery_id,delivery_object_type,delivery_version,delivery_receipt_id,
        delivery_receipt_sequence,delivery_receipt_digest,
        delivery_resulting_state,delivery_receipt_applied,
        acceptance_evidence_kind,provider_evidence_digest,
        provider_accepted_at,audit_event_id,outbox_event_id,receipt_digest,
        created_at
      ) VALUES(
        v_source_sent_receipt_id,
        pg_temp.r6d_transition_uuid_v1(p_label||'-source-sent-event'),
        pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-sent-envelope.v1',
          'responseRequestId',v_source_response_request_id
        )),v_source_response_request_id,1,2,
        v_source_response_request_binding_digest,
        pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-scope.v1',
          'responseRequestId',v_source_response_request_id
        )),'DRAFT','SENT',
        pg_temp.r6d_transition_uuid_v1(p_label||'-source-intent'),
        pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-intent.v1',
          'responseRequestId',v_source_response_request_id
        )),pg_temp.r6d_transition_uuid_v1(p_label||'-source-rendering'),
        pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-rendering.v1',
          'responseRequestId',v_source_response_request_id
        )),pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-rendered.v1',
          'responseRequestId',v_source_response_request_id
        )),pg_temp.r6d_transition_uuid_v1(p_label||'-source-access-token'),
        pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-access.v1',
          'responseRequestId',v_source_response_request_id
        )),v_source_endpoint_id,1,v_source_endpoint_digest,'SMTP_EMAIL',
        pg_temp.r6d_transition_uuid_v1(p_label||'-source-provider-config'),1,
        pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-provider-config.v1',
          'responseRequestId',v_source_response_request_id
        )),pg_temp.r6d_transition_uuid_v1(p_label||'-source-preflight'),
        pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-preflight.v1',
          'responseRequestId',v_source_response_request_id
        )),pg_temp.r6d_transition_uuid_v1(p_label||'-source-delivery'),
        'RESPONSE_REQUEST',2,
        pg_temp.r6d_transition_uuid_v1(p_label||'-source-delivery-receipt'),1,
        pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-delivery.v1',
          'responseRequestId',v_source_response_request_id
        )),'DELIVERED',true,'PROVIDER_RESPONSE',
        pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-provider-evidence.v1',
          'responseRequestId',v_source_response_request_id
        )),v_source_at,
        pg_temp.r6d_transition_uuid_v1(p_label||'-source-sent-audit-event'),
        pg_temp.r6d_transition_uuid_v1(p_label||'-source-sent-outbox-event'),
        pg_temp.r6d_transition_sha256_json_v1(jsonb_build_object(
          'schemaVersion','test-only-response-source-sent-receipt.v1',
          'responseRequestId',v_source_response_request_id,
          'requestVersion',2,
          'endpointId',v_source_endpoint_id,
          'endpointVersion',1,
          'endpointDigest',btrim(v_source_endpoint_digest),
          'createdAt',v_source_at
        )),v_source_at
      );
      PERFORM set_config('session_replication_role','origin',true);
    EXCEPTION WHEN OTHERS THEN
      PERFORM set_config('session_replication_role','origin',true);
      RAISE;
    END;
  END IF;

  v_create_audit_event_id:=ops.append_audit_event(
    'privacy-probe-create:'||v_request_id::text,
    'ANONYMOUS',NULL,NULL,'command.createPrivacyRequest',
    'PRIVACY_REQUEST',v_request_id::text,NULL,'SUCCESS',NULL,
    v_create_request_id,jsonb_build_object(
      'fixture','r6d-transition-success-probe',
      'receiptDigest',btrim(v_create_receipt_digest)
    )
  );
  v_create_outbox_event_id:=ops.enqueue_outbox(
    'privacy_request',v_request_id::text,1,
    'privacy.request_created.v2',jsonb_build_object(
      'retentionRequestId',v_request_id,'requestType','ACCESS',
      'subjectProofHash',btrim(v_subject_proof_hash),
      'jurisdiction','KR','scopeDigest',btrim(v_scope_sha256),
      'identityState','PENDING_VERIFICATION',
      'identityVerifiedAt',NULL,'dueAt',NULL,
      'receiptDigest',btrim(v_create_receipt_digest),
      'commandReceiptDigest',pg_temp.r6d_transition_sha256_text_v1(
        'command-receipt:'||p_label
      )
    ),v_created_at
  );

  IF p_identity_state='VERIFIED' THEN
    v_identity_payload:=jsonb_build_object(
      'schemaVersion','privacy-request-identity-receipt.v2',
      'identityReceiptId',v_identity_receipt_id,
      'retentionRequestId',v_request_id,'decisionVersion',1,
      'identityProofReceiptId',v_identity_proof_authority_receipt_id,
      'identityProofReceiptDigest',
        btrim(v_identity_proof_authority_digest),
      'priorIdentityState','PENDING_VERIFICATION',
      'identityState','VERIFIED',
      'identityVerifiedAt',v_identity_verified_at,
      'dueAt',v_effective_due_at,
      'responsePolicyId',(v_policy->>'policyId')::uuid,
      'responsePolicyRevision',(v_policy->>'revision')::bigint,
      'responsePolicyVersion',v_policy->>'policyVersion',
      'responsePolicyDigest',v_policy->>'policyDigest',
      'calendarVersionId',(v_policy->>'calendarVersionId')::uuid,
      'calendarDigest',v_policy->>'calendarDigest'
    );
    v_identity_canonical:=ops.canonical_jsonb_v1(v_identity_payload);
    v_identity_digest:=encode(
      extensions.digest(v_identity_canonical,'sha256'),'hex'
    );

    IF v_install_identity_transition THEN
      v_identity_reason_aad_digest:=ops.r6d_nul5_sha256_v1(
        'ops.privacy_request_sealed_content_v2','sealed_ciphertext',
        v_identity_transition_receipt_id::text,'REASON','1'
      );
      v_identity_notice_template:=jsonb_build_object(
        'schemaVersion','privacy-request-notice-template.v1',
        'kind','IDENTITY_VERIFIED','retentionRequestId',v_request_id,
        'requestType','ACCESS','decisionVersion',1,
        'branchReceiptId',v_identity_receipt_id,
        'branchReceiptDigest',btrim(v_identity_digest),
        'dueAt',v_effective_due_at,
        'reasonCode','TEST_ONLY_VERIFY_IDENTITY',
        'reasonDigest',btrim(v_identity_reason_sha256)
      );
      v_identity_notice_template_digest:=
        pg_temp.r6d_transition_sha256_json_v1(
          v_identity_notice_template
        );
      v_identity_notice_aad_digest:=ops.r6d_nul5_sha256_v1(
        'ops.privacy_request_notice_receipts_v2',
        'notice_template_payload',v_identity_notice_receipt_id::text,
        'IDENTITY_VERIFIED','1'
      );
      v_identity_notice_payload:=jsonb_build_object(
        'schemaVersion','privacy-request-notice-receipt.v2',
        'noticeReceiptId',v_identity_notice_receipt_id,
        'retentionRequestId',v_request_id,'noticeSequence',1,
        'noticeKind','IDENTITY_VERIFIED',
        'transitionReceiptId',v_identity_transition_receipt_id,
        'endpointId',v_endpoint_id,'endpointVersion',1,
        'endpointDigest',btrim(v_endpoint_digest),
        'endpointAadDigest',btrim(v_endpoint_aad_digest),
        'encryptionKeyId','key-v1',
        'noticeSha256',btrim(v_identity_notice_template_digest),
        'noticeAadDigest',btrim(v_identity_notice_aad_digest),
        'noticeTemplate',v_identity_notice_template,
        'noticeTemplateDigest',btrim(v_identity_notice_template_digest),
        'branchReceiptId',v_identity_receipt_id,
        'branchReceiptDigest',btrim(v_identity_digest),
        'createdAt',v_identity_verified_at
      );
      v_identity_notice_canonical:=
        ops.canonical_jsonb_v1(v_identity_notice_payload);
      v_identity_notice_digest:=encode(extensions.digest(
        v_identity_notice_canonical,'sha256'
      ),'hex');
      v_identity_transition_payload:=jsonb_build_object(
        'schemaVersion','privacy-request-transition-receipt.v2',
        'transitionReceiptId',v_identity_transition_receipt_id,
        'retentionRequestId',v_request_id,'decisionVersion',1,
        'transition','VERIFY_IDENTITY','priorState','RECEIVED',
        'state','RECEIVED','reasonCode','TEST_ONLY_VERIFY_IDENTITY',
        'reasonDigest',btrim(v_identity_reason_sha256),
        'reasonAadDigest',btrim(v_identity_reason_aad_digest),
        'encryptionKeyId','key-v1',
        'actorId','a6d50000-0000-4000-8000-000000000001'::uuid,
        'actorAssertionJti',v_identity_actor_assertion_jti,
        'actorActionDigest',btrim(v_identity_action_digest),
        'stepUpAuthorizationId',v_identity_step_up_authorization_id,
        'idempotencyKeySha256',btrim(v_identity_idempotency_sha256),
        'requestSha256',btrim(v_identity_request_sha256),
        'identityReceiptId',v_identity_receipt_id,
        'identityReceiptDigest',btrim(v_identity_digest),
        'noticeReceiptId',v_identity_notice_receipt_id,
        'noticeReceiptDigest',btrim(v_identity_notice_digest),
        'decidedAt',v_identity_verified_at
      );
      v_identity_transition_canonical:=
        ops.canonical_jsonb_v1(v_identity_transition_payload);
      v_identity_transition_digest:=encode(extensions.digest(
        v_identity_transition_canonical,'sha256'
      ),'hex');
      v_identity_event_payload:=jsonb_build_object(
        'retentionRequestId',v_request_id,'requestType','ACCESS',
        'priorIdentityState','PENDING_VERIFICATION',
        'identityState','VERIFIED',
        'identityProofReceiptDigest',
          btrim(v_identity_proof_authority_digest),
        'identityVerifiedAt',v_identity_verified_at,
        'responsePolicyVersion',v_policy->>'policyVersion',
        'responsePolicyDigest',v_policy->>'policyDigest',
        'calendarVersionId',(v_policy->>'calendarVersionId')::uuid,
        'calendarDigest',v_policy->>'calendarDigest',
        'dueAt',v_effective_due_at,
        'verificationReceiptDigest',btrim(v_identity_digest)
      );
      v_identity_event_id:=ops.enqueue_outbox(
        'privacy_request',v_request_id::text,1,
        'privacy.request_identity_verified.v1',
        v_identity_event_payload,v_identity_verified_at
      );
      v_identity_event_digest:=
        ops.r6d_outbox_envelope_digest_v1(v_identity_event_id);
      v_identity_audit_event_id:=ops.append_audit_event(
        'privacy-probe-identity:'||v_request_id::text,
        'USER','a6d50000-0000-4000-8000-000000000001',
        'a6d50000-0000-4000-8000-000000000002',
        'test-only.transitionPrivacyIdentityFixture',
        'PRIVACY_REQUEST',v_request_id::text,'privacy.requests.manage',
        'SUCCESS','TEST_ONLY_VERIFY_IDENTITY',
        v_identity_transition_request_id,jsonb_build_object(
          'fixture','r6d-transition-success-probe',
          'identityReceiptDigest',btrim(v_identity_digest),
          'transitionReceiptDigest',btrim(v_identity_transition_digest)
        )
      );
    END IF;
  END IF;

  INSERT INTO ops.privacy_requests_v2(
    id,request_type,state,identity_state,jurisdiction,
    subject_proof_hash,identity_proof_kind,identity_proof_ref_id,
    identity_proof_binding_digest,subject_scope_digest,scope_ciphertext,
    scope_sha256,scope_aad_digest,statement_ciphertext,statement_sha256,
    statement_aad_digest,encryption_key_id,communication_subject_id,
    communication_subject_origin_digest,communication_endpoint_id,
    communication_endpoint_version,communication_endpoint_digest,
    decision_version,identity_verified_at,due_at,response_policy_id,
    response_policy_revision,response_policy_digest,calendar_version_id,
    calendar_digest,current_identity_receipt_id,
    current_identity_receipt_digest,current_notice_receipt_id,
    current_notice_receipt_digest,create_request_id,
    create_idempotency_key_sha256,create_request_sha256,
    create_audit_event_id,create_outbox_event_id,create_receipt_digest,
    created_at,updated_at
  ) VALUES(
    v_request_id,'ACCESS',p_state,p_identity_state,'KR',
    v_subject_proof_hash,'RESPONSE_RECEIPT',v_source_response_receipt_id,
    v_identity_proof_binding_digest,v_subject_scope_digest,v_envelope,
    v_scope_sha256,ops.r6d_nul5_sha256_v1(
      'ops.privacy_requests_v2','scope_ciphertext',v_request_id::text,
      'privacy-request-scope','1'
    ),v_envelope,pg_temp.r6d_transition_sha256_text_v1(
      'statement-plaintext:'||p_label
    ),ops.r6d_nul5_sha256_v1(
      'ops.privacy_requests_v2','statement_ciphertext',v_request_id::text,
      'privacy-request-statement','1'
    ),'key-v1',v_subject_id,v_subject_origin_digest,v_endpoint_id,1,
    v_endpoint_digest,p_decision_version,
    CASE WHEN p_identity_state='VERIFIED'
      THEN v_identity_verified_at ELSE NULL END,
    v_effective_due_at,
    CASE WHEN p_identity_state='VERIFIED'
      THEN (v_policy->>'policyId')::uuid ELSE NULL END,
    CASE WHEN p_identity_state='VERIFIED'
      THEN (v_policy->>'revision')::bigint ELSE NULL END,
    CASE WHEN p_identity_state='VERIFIED'
      THEN (v_policy->>'policyDigest')::char(64) ELSE NULL END,
    CASE WHEN p_identity_state='VERIFIED'
      THEN (v_policy->>'calendarVersionId')::uuid ELSE NULL END,
    CASE WHEN p_identity_state='VERIFIED'
      THEN (v_policy->>'calendarDigest')::char(64) ELSE NULL END,
    CASE WHEN p_identity_state='VERIFIED'
      THEN v_identity_receipt_id ELSE NULL END,
    CASE WHEN p_identity_state='VERIFIED'
      THEN v_identity_digest ELSE NULL END,
    CASE WHEN v_install_identity_transition
      THEN v_identity_notice_receipt_id ELSE NULL END,
    CASE WHEN v_install_identity_transition
      THEN v_identity_notice_digest ELSE NULL END,
    v_create_request_id,
    pg_temp.r6d_transition_sha256_text_v1('create-idempotency:'||p_label),
    pg_temp.r6d_transition_sha256_text_v1('create-request:'||p_label),
    v_create_audit_event_id,v_create_outbox_event_id,
    v_create_receipt_digest,v_created_at,
    CASE WHEN p_identity_state='VERIFIED'
      THEN v_identity_verified_at ELSE v_created_at END
  );

  IF p_identity_state='VERIFIED' THEN
    INSERT INTO ops.privacy_identity_proof_authority_receipts_v1(
      identity_proof_receipt_id,privacy_request_id,proof_kind,
      source_proof_id,source_subject_id,source_subject_origin_digest,
      source_endpoint_id,source_endpoint_version,source_endpoint_digest,
      source_response_receipt_id,source_endpoint_verification_id,
      source_proof_digest,source_current_binding_digest,subject_proof_hash,
      subject_binding_digest,exact_scope_digest,request_create_receipt_digest,
      receipt_payload,receipt_canonical,receipt_digest,created_at
    ) VALUES(
      v_identity_proof_authority_receipt_id,v_request_id,
      'RESPONSE_RECEIPT',v_source_response_receipt_id,v_source_subject_id,
      v_source_subject_origin_digest,v_source_endpoint_id,1,
      v_source_endpoint_digest,v_source_response_receipt_id,NULL,
      v_source_response_receipt_digest,v_source_current_binding_digest,
      v_subject_proof_hash,v_identity_proof_binding_digest,v_scope_sha256,
      v_create_receipt_digest,v_identity_proof_authority_payload,
      v_identity_proof_authority_canonical,
      v_identity_proof_authority_digest,v_created_at
    );

    INSERT INTO ops.privacy_request_identity_receipts_v2(
      identity_receipt_id,privacy_request_id,decision_version,
      identity_proof_receipt_id,identity_proof_receipt_digest,
      prior_identity_state,identity_state,identity_verified_at,due_at,
      response_policy_id,response_policy_revision,response_policy_version,
      response_policy_digest,calendar_version_id,calendar_digest,
      notice_receipt_id,notice_receipt_digest,event_receipt_id,
      event_receipt_digest,
      receipt_payload,receipt_canonical,receipt_digest,verified_at
    ) VALUES(
      v_identity_receipt_id,v_request_id,1,
      v_identity_proof_authority_receipt_id,
      v_identity_proof_authority_digest,
      'PENDING_VERIFICATION','VERIFIED',
      v_identity_verified_at,v_effective_due_at,
      (v_policy->>'policyId')::uuid,
      (v_policy->>'revision')::bigint,v_policy->>'policyVersion',
      (v_policy->>'policyDigest')::char(64),
      (v_policy->>'calendarVersionId')::uuid,
      (v_policy->>'calendarDigest')::char(64),
      CASE WHEN v_install_identity_transition
        THEN v_identity_notice_receipt_id ELSE NULL END,
      CASE WHEN v_install_identity_transition
        THEN v_identity_notice_digest ELSE NULL END,
      CASE WHEN v_install_identity_transition
        THEN v_identity_event_id ELSE NULL END,
      CASE WHEN v_install_identity_transition
        THEN v_identity_event_digest ELSE NULL END,
      v_identity_payload,
      v_identity_canonical,v_identity_digest,v_identity_verified_at
    );

    IF v_install_identity_transition THEN
      INSERT INTO ops.privacy_request_notice_receipts_v2(
        notice_receipt_id,privacy_request_id,notice_sequence,notice_kind,
        transition_receipt_id,endpoint_id,endpoint_version,endpoint_digest,
        endpoint_aad_digest,encryption_key_id,notice_sha256,
        notice_aad_digest,notice_template_payload,notice_template_digest,
        branch_receipt_id,branch_receipt_digest,event_receipt_id,
        event_receipt_digest,receipt_payload,receipt_canonical,
        receipt_digest,created_at
      ) VALUES(
        v_identity_notice_receipt_id,v_request_id,1,'IDENTITY_VERIFIED',
        v_identity_transition_receipt_id,v_endpoint_id,1,v_endpoint_digest,
        v_endpoint_aad_digest,'key-v1',v_identity_notice_template_digest,
        v_identity_notice_aad_digest,v_identity_notice_template,
        v_identity_notice_template_digest,v_identity_receipt_id,
        v_identity_digest,v_identity_event_id,v_identity_event_digest,
        v_identity_notice_payload,v_identity_notice_canonical,
        v_identity_notice_digest,v_identity_verified_at
      );

      INSERT INTO ops.privacy_request_transition_receipts_v2(
        transition_receipt_id,privacy_request_id,decision_version,
        transition,prior_state,state,reason_code,reason_sha256,
        reason_aad_digest,encryption_key_id,actor_id,actor_assertion_jti,
        actor_action_digest,step_up_authorization_id,
        idempotency_key_sha256,request_sha256,identity_receipt_id,
        identity_receipt_digest,notice_receipt_id,notice_receipt_digest,
        event_receipt_id,event_receipt_digest,audit_event_id,
        outbox_event_ids,receipt_payload,receipt_canonical,receipt_digest,
        decided_at
      ) VALUES(
        v_identity_transition_receipt_id,v_request_id,1,
        'VERIFY_IDENTITY','RECEIVED','RECEIVED',
        'TEST_ONLY_VERIFY_IDENTITY',v_identity_reason_sha256,
        v_identity_reason_aad_digest,'key-v1',
        'a6d50000-0000-4000-8000-000000000001',
        v_identity_actor_assertion_jti,v_identity_action_digest,
        v_identity_step_up_authorization_id,v_identity_idempotency_sha256,
        v_identity_request_sha256,v_identity_receipt_id,v_identity_digest,
        v_identity_notice_receipt_id,v_identity_notice_digest,
        v_identity_event_id,v_identity_event_digest,
        v_identity_audit_event_id,ARRAY[v_identity_event_id]::uuid[],
        v_identity_transition_payload,v_identity_transition_canonical,
        v_identity_transition_digest,v_identity_verified_at
      );

      INSERT INTO ops.privacy_request_sealed_content_v2(
        privacy_request_id,transition_receipt_id,field_kind,
        sealed_ciphertext,sealed_sha256,sealed_aad_digest,encryption_key_id
      ) VALUES(
        v_request_id,v_identity_transition_receipt_id,'REASON',
        v_identity_reason_ciphertext,v_identity_reason_sha256,
        v_identity_reason_aad_digest,'key-v1'
      );
    END IF;
  END IF;
  RETURN v_request_id;
END
$fixture$;

CREATE TEMP TABLE r6d_transition_probe_commands(
  label text PRIMARY KEY,
  privacy_request_id uuid NOT NULL,
  transition text NOT NULL,
  expected_decision_version bigint NOT NULL,
  transition_receipt_id uuid NOT NULL,
  actor_assertion_jti uuid NOT NULL,
  actor_assertion_request_sha256 char(64) NOT NULL,
  step_up_authorization_id uuid NOT NULL,
  idempotency_key_sha256 char(64) NOT NULL,
  request_sha256 char(64) NOT NULL,
  action_digest char(64) NOT NULL,
  request_id uuid NOT NULL,
  reason_label text NOT NULL,
  variant jsonb NOT NULL
) ON COMMIT DROP;

CREATE TEMP TABLE r6d_transition_probe_results(
  label text PRIMARY KEY,
  result jsonb NOT NULL
) ON COMMIT DROP;

CREATE FUNCTION pg_temp.r6d_transition_call_v1(p_label text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
STRICT
SET search_path=pg_catalog,ops,pg_temp
AS $call$
DECLARE
  v_command r6d_transition_probe_commands%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_command
  FROM r6d_transition_probe_commands WHERE label=p_label;
  RETURN ops.transition_privacy_request_v2(
    pg_temp.r6d_transition_payload_v1(
      v_command.privacy_request_id,v_command.transition,
      v_command.expected_decision_version,
      v_command.transition_receipt_id,v_command.actor_assertion_jti,
      v_command.actor_assertion_request_sha256,
      v_command.step_up_authorization_id,
      v_command.idempotency_key_sha256,v_command.action_digest,
      v_command.reason_label,v_command.variant
    ),
    'a6d50000-0000-4000-8000-000000000001',
    'a6d50000-0000-4000-8000-000000000002',
    v_command.request_id,v_command.idempotency_key_sha256,
    v_command.request_sha256
  );
END
$call$;

CREATE FUNCTION pg_temp.r6d_transition_create_payload_v1(
  p_label text,
  p_identity_proof jsonb,
  p_scope jsonb
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $create_payload$
DECLARE
  v_request_id uuid:=
    pg_temp.r6d_transition_uuid_v1('create-'||p_label||'-request');
  v_subject_id uuid:=
    pg_temp.r6d_transition_uuid_v1('create-'||p_label||'-subject');
  v_endpoint_id uuid:=
    pg_temp.r6d_transition_uuid_v1('create-'||p_label||'-endpoint');
  v_envelope bytea:=
    pg_temp.r6d_transition_envelope_v1('create_'||p_label);
BEGIN
  RETURN jsonb_build_object(
    'privacyRequestId',v_request_id,'requestType','ACCESS',
    'jurisdiction','KR','identityProof',p_identity_proof,'scope',p_scope,
    'scopeCiphertextBase64',
      pg_temp.r6d_transition_base64_v1(v_envelope),
    'scopeAadDigest',ops.r6d_nul5_sha256_v1(
      'ops.privacy_requests_v2','scope_ciphertext',v_request_id::text,
      'privacy-request-scope','1'
    ),
    'statementCiphertextBase64',
      pg_temp.r6d_transition_base64_v1(v_envelope),
    'statementSha256',pg_temp.r6d_transition_sha256_text_v1(
      'create-statement:'||p_label
    ),
    'statementAadDigest',ops.r6d_nul5_sha256_v1(
      'ops.privacy_requests_v2','statement_ciphertext',v_request_id::text,
      'privacy-request-statement','1'
    ),
    'encryptionKeyId','key-v1','communicationSubjectId',v_subject_id,
    'communicationSubjectHmacKeyVersion','hmac-v1',
    'communicationSubjectLocale','ko-KR',
    'communicationEndpointId',v_endpoint_id,
    'communicationEndpointChannel','SMTP_EMAIL',
    'communicationEndpointHmac',
      pg_temp.r6d_transition_sha256_text_v1('create-endpoint:'||p_label),
    'communicationEndpointHmacKeyVersion','hmac-v1',
    'communicationEndpointCiphertextBase64',
      pg_temp.r6d_transition_base64_v1(v_envelope),
    'communicationEndpointEncryptionKeyId','key-v1',
    'communicationEndpointAadDigest',ops.r6d_nul5_sha256_v1(
      'intake.communication_endpoints','endpoint_ciphertext',
      v_endpoint_id::text,'email-address','1'
    ),
    'explicitVoiceConsentReceiptId',NULL,
    'receiptTokenHmac',
      pg_temp.r6d_transition_sha256_text_v1('create-token-hmac:'||p_label),
    'receiptTokenSha256',
      pg_temp.r6d_transition_sha256_text_v1('create-token-sha:'||p_label),
    'receiptTokenKeyVersion','receipt-key-v1'
  );
END
$create_payload$;

GRANT EXECUTE ON FUNCTION
  pg_temp.r6d_transition_install_root_v1(
    text,text,text,bigint,timestamp with time zone
  ),
  pg_temp.r6d_transition_call_v1(text)
TO gurine_control_api;
GRANT SELECT ON r6d_transition_probe_commands TO gurine_control_api;
GRANT SELECT,INSERT,UPDATE ON r6d_transition_probe_results
TO gurine_control_api;
GRANT EXECUTE ON FUNCTION
  pg_temp.r6d_transition_create_payload_v1(text,jsonb,jsonb),
  pg_temp.r6d_transition_uuid_v1(text),
  pg_temp.r6d_transition_sha256_text_v1(text),
  pg_temp.r6d_transition_write_fingerprint_v1()
TO gurine_submission_api;

INSERT INTO ops.users(
  id,oidc_subject,email,display_name,status,created_at,updated_at
) VALUES(
  'a6d50000-0000-4000-8000-000000000001',
  'r6d-transition-probe-actor','r6d-transition-probe@example.invalid',
  'R6D_TRANSITION_PROBE_ACTOR','ACTIVE',clock_timestamp(),clock_timestamp()
);
INSERT INTO ops.sessions(
  id,user_id,session_token_hash,auth_time,step_up_at,expires_at,
  csrf_token_hash,created_at
) VALUES(
  'a6d50000-0000-4000-8000-000000000002',
  'a6d50000-0000-4000-8000-000000000001',
  pg_temp.r6d_transition_sha256_text_v1('transition-probe-session'),
  clock_timestamp()-interval '1 minute',clock_timestamp(),
  clock_timestamp()+interval '1 hour',
  pg_temp.r6d_transition_sha256_text_v1('transition-probe-csrf'),
  clock_timestamp()-interval '1 minute'
);

-- Verified TEST_ONLY roots carry a current D3 RESPONSE_RECEIPT source graph and
-- immutable proof authority.  The pending root deliberately carries neither,
-- so the missing-authority VERIFY_IDENTITY negative remains fail-closed.
DO $fixture_roots$
DECLARE
  v_main uuid;
  v_pending uuid;
  v_expired uuid;
  v_verified_authority_count bigint;
  v_calendar jsonb;
  v_policy ops.privacy_response_calendar_policies_v1%ROWTYPE;
  v_calendar_row ops.business_calendar_versions%ROWTYPE;
BEGIN
  IF ops.add_privacy_business_days_v1(
       '2026-07-24 00:00:00+00',10,
       'a6d40000-0000-4000-8000-000000000001',
       (SELECT calendar_digest FROM ops.business_calendar_versions
        WHERE id='a6d40000-0000-4000-8000-000000000001')
     )<>'2026-08-07 00:00:00+00'::timestamptz THEN
    RAISE EXCEPTION 'r6d_transition_initial_due_fixture_invalid';
  END IF;
  IF ops.add_privacy_business_days_v1(
       '2026-08-07 00:00:00+00',10,
       'a6d40000-0000-4000-8000-000000000001',
       (SELECT calendar_digest FROM ops.business_calendar_versions
        WHERE id='a6d40000-0000-4000-8000-000000000001')
     )<>'2026-08-24 00:00:00+00'::timestamptz THEN
    RAISE EXCEPTION 'r6d_transition_extended_due_fixture_invalid';
  END IF;

  v_main:=pg_temp.r6d_transition_install_root_v1(
    'main','RECEIVED','VERIFIED',1,NULL
  );
  v_pending:=pg_temp.r6d_transition_install_root_v1(
    'pending','RECEIVED','PENDING_VERIFICATION',0,NULL
  );
  v_expired:=pg_temp.r6d_transition_install_root_v1(
    'expired','REVIEW','VERIFIED',1,clock_timestamp()-interval '1 day'
  );
  IF v_main<>pg_temp.r6d_transition_uuid_v1('main-request')
     OR v_pending<>pg_temp.r6d_transition_uuid_v1('pending-request')
     OR v_expired<>pg_temp.r6d_transition_uuid_v1('expired-request') THEN
    RAISE EXCEPTION 'r6d_transition_root_fixture_id_invalid';
  END IF;
  IF NOT EXISTS(
    SELECT 1
    FROM ops.privacy_requests_v2 AS request
    JOIN ops.privacy_request_identity_receipts_v2 AS identity
      ON identity.identity_receipt_id=request.current_identity_receipt_id
     AND identity.receipt_digest=request.current_identity_receipt_digest
    WHERE request.id=v_main
      AND request.due_at=ops.add_privacy_business_days_v1(
        identity.identity_verified_at,10,request.calendar_version_id,
        request.calendar_digest
      )
      AND request.due_at>clock_timestamp()
  ) THEN
    RAISE EXCEPTION 'r6d_transition_active_root_due_invalid';
  END IF;
  IF current_setting('session_replication_role')<>'origin' THEN
    RAISE EXCEPTION 'r6d_transition_source_fixture_role_not_restored';
  END IF;

  WITH expected(label,request_id) AS (
    VALUES ('main'::text,v_main),('expired'::text,v_expired)
  ), source_graph AS (
    SELECT expected.label,request.id AS request_id,
      request.identity_proof_kind AS request_identity_proof_kind,
      request.identity_proof_ref_id AS request_identity_proof_ref_id,
      request.identity_proof_binding_digest AS request_binding_digest,
      request.subject_proof_hash AS request_subject_proof_hash,
      request.scope_sha256 AS request_scope_sha256,
      request.create_receipt_digest AS request_create_digest,
      request.created_at AS request_created_at,
      authority.identity_proof_receipt_id,
      authority.privacy_request_id,authority.proof_kind,
      authority.source_proof_id,authority.source_subject_id,
      authority.source_subject_origin_digest,authority.source_endpoint_id,
      authority.source_endpoint_version,authority.source_endpoint_digest,
      authority.source_response_receipt_id,
      authority.source_endpoint_verification_id,
      authority.source_proof_digest,
      authority.source_current_binding_digest,
      authority.subject_proof_hash AS authority_subject_proof_hash,
      authority.subject_binding_digest,authority.exact_scope_digest,
      authority.request_create_receipt_digest,authority.receipt_payload,
      authority.receipt_canonical,authority.receipt_digest,
      authority.created_at,
      identity.identity_receipt_id,
      identity.identity_proof_receipt_id AS identity_authority_id,
      identity.identity_proof_receipt_digest AS identity_authority_digest,
      identity.receipt_payload AS identity_payload,
      identity.receipt_canonical AS identity_canonical,
      identity.receipt_digest AS identity_digest,
      source_receipt.response_submission_id,
      source_receipt.response_request_id,
      source_receipt.response_request_version,
      source_receipt.response_request_binding_digest,
      source_receipt.draft_version AS source_draft_version,
      source_receipt.submission_sha256 AS source_submission_sha256,
      source_receipt.publication_consent_sha256,
      source_receipt.receipt_version AS source_receipt_version,
      source_receipt.receipt_digest AS source_receipt_digest,
      source_receipt.submitted_at AS source_submitted_at,
      submission.receipt_token_hash AS source_possession_hmac,
      submission.publication_consent AS source_publication_consent,
      submission.status AS source_submission_status,
      sent.channel AS source_channel,
      subject.profile_version AS source_subject_profile_version,
      subject.profile_digest AS source_subject_profile_digest,
      endpoint.state AS source_endpoint_state,
      endpoint.revoked_at AS source_endpoint_revoked_at,
      endpoint.verified_at AS source_endpoint_verified_at,
      endpoint.updated_at AS source_endpoint_updated_at
    FROM expected
    JOIN ops.privacy_requests_v2 AS request ON request.id=expected.request_id
    JOIN ops.privacy_identity_proof_authority_receipts_v1 AS authority
      ON authority.privacy_request_id=request.id
    JOIN ops.privacy_request_identity_receipts_v2 AS identity
      ON identity.identity_receipt_id=request.current_identity_receipt_id
     AND identity.receipt_digest=request.current_identity_receipt_digest
     AND identity.privacy_request_id=request.id
    JOIN intake.response_submission_receipts_v3 AS source_receipt
      ON source_receipt.receipt_id=authority.source_response_receipt_id
    JOIN intake.response_submissions AS submission
      ON submission.id=source_receipt.response_submission_id
    JOIN editorial.response_request_sent_receipts AS sent
      ON sent.response_request_id=source_receipt.response_request_id
     AND sent.endpoint_id=authority.source_endpoint_id
     AND sent.endpoint_version=authority.source_endpoint_version
     AND sent.endpoint_snapshot_digest=authority.source_endpoint_digest
    JOIN intake.communication_endpoints AS endpoint
      ON endpoint.id=authority.source_endpoint_id
     AND endpoint.version=authority.source_endpoint_version
     AND endpoint.endpoint_digest=authority.source_endpoint_digest
    JOIN intake.communication_endpoint_link_events AS link
      ON link.endpoint_id=endpoint.id
     AND link.subject_id=authority.source_subject_id
     AND link.endpoint_version=endpoint.version
     AND link.endpoint_snapshot_digest=endpoint.endpoint_digest
     AND link.channel=sent.channel AND link.state='ACTIVE'
     AND NOT EXISTS(
       SELECT 1
       FROM intake.communication_endpoint_link_events AS later
       WHERE later.endpoint_id=link.endpoint_id
         AND later.endpoint_sequence>link.endpoint_sequence
     )
    JOIN intake.communication_subjects AS subject
      ON subject.id=link.subject_id
     AND subject.origin_binding_digest=link.subject_origin_binding_digest
     AND subject.origin_binding_digest=authority.source_subject_origin_digest
  ), exact_source AS (
    SELECT source_graph.*,source_payload.source_receipt_payload,
      source_payload.source_binding_payload
    FROM source_graph
    CROSS JOIN LATERAL (SELECT
      jsonb_build_object(
        'schemaVersion','response-submission-receipt.v3',
        'responseSubmissionId',source_graph.response_submission_id,
        'responseRequestId',source_graph.response_request_id,
        'responseRequestVersion',source_graph.response_request_version,
        'responseRequestBindingDigest',
          btrim(source_graph.response_request_binding_digest),
        'draftVersion',source_graph.source_draft_version,
        'submissionSha256',btrim(source_graph.source_submission_sha256),
        'publicationConsentSha256',
          btrim(source_graph.publication_consent_sha256),
        'receiptVersion',source_graph.source_receipt_version,
        'submittedAt',source_graph.source_submitted_at
      ) AS source_receipt_payload,
      jsonb_build_object(
        'schemaVersion','privacy-response-receipt-source-binding.v1',
        'receiptId',source_graph.source_response_receipt_id,
        'responseSubmissionId',source_graph.response_submission_id,
        'responseRequestId',source_graph.response_request_id,
        'responseRequestVersion',source_graph.response_request_version,
        'responseRequestBindingDigest',
          btrim(source_graph.response_request_binding_digest),
        'submissionSha256',btrim(source_graph.source_submission_sha256),
        'receiptVersion',source_graph.source_receipt_version,
        'receiptDigest',btrim(source_graph.source_receipt_digest),
        'possessionTokenHmac',btrim(source_graph.source_possession_hmac),
        'subjectId',source_graph.source_subject_id,
        'subjectOriginDigest',
          btrim(source_graph.source_subject_origin_digest),
        'subjectProfileVersion',source_graph.source_subject_profile_version,
        'subjectProfileDigest',
          btrim(source_graph.source_subject_profile_digest),
        'endpointId',source_graph.source_endpoint_id,
        'endpointVersion',source_graph.source_endpoint_version,
        'endpointDigest',btrim(source_graph.source_endpoint_digest),
        'channel',source_graph.source_channel
      ) AS source_binding_payload
    ) AS source_payload
  ), exact_authority AS (
    SELECT exact_source.*,jsonb_build_object(
      'schemaVersion','privacy-identity-proof-authority-receipt.v1',
      'identityProofReceiptId',exact_source.identity_proof_receipt_id,
      'privacyRequestId',exact_source.privacy_request_id,
      'proofKind',exact_source.proof_kind,
      'sourceProofId',exact_source.source_proof_id,
      'sourceProofDigest',btrim(exact_source.source_proof_digest),
      'sourceCurrentBindingDigest',encode(extensions.digest(
        ops.canonical_jsonb_v1(exact_source.source_binding_payload),
        'sha256'
      ),'hex'),
      'subjectProofHash',btrim(exact_source.authority_subject_proof_hash),
      'subjectBindingDigest',btrim(exact_source.subject_binding_digest),
      'exactScopeDigest',btrim(exact_source.exact_scope_digest),
      'requestCreateReceiptDigest',
        btrim(exact_source.request_create_receipt_digest),
      'createdAt',exact_source.created_at
    ) AS exact_authority_payload
    FROM exact_source
  )
  SELECT count(*) INTO v_verified_authority_count
  FROM exact_authority
  WHERE identity_proof_receipt_id=
      pg_temp.r6d_transition_uuid_v1(label||'-identity-proof-authority')
    AND identity_proof_receipt_id<>source_proof_id
    AND source_proof_id=
      pg_temp.r6d_transition_uuid_v1(label||'-identity-proof')
    AND source_response_receipt_id=source_proof_id
    AND source_endpoint_verification_id IS NULL
    AND proof_kind='RESPONSE_RECEIPT'
    AND request_identity_proof_kind='RESPONSE_RECEIPT'
    AND request_identity_proof_ref_id=source_proof_id
    AND request_binding_digest=encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_object(
        'kind','RESPONSE_RECEIPT','receiptId',source_proof_id,
        'possessionTokenHmac',btrim(source_possession_hmac)
      )),'sha256'
    ),'hex')
    AND source_proof_digest=source_receipt_digest
    AND source_receipt_digest=encode(extensions.digest(
      ops.canonical_jsonb_v1(source_receipt_payload),'sha256'
    ),'hex')
    AND publication_consent_sha256=encode(extensions.digest(
      ops.canonical_jsonb_v1(source_publication_consent),'sha256'
    ),'hex')
    AND source_submission_status='SUBMITTED'
    AND source_endpoint_state='ACTIVE'
    AND source_endpoint_revoked_at IS NULL
    AND source_endpoint_verified_at IS NOT NULL
    AND source_endpoint_updated_at<=clock_timestamp()
    AND source_current_binding_digest=encode(extensions.digest(
      ops.canonical_jsonb_v1(source_binding_payload),'sha256'
    ),'hex')
    AND receipt_payload=exact_authority_payload
    AND receipt_canonical=ops.canonical_jsonb_v1(exact_authority_payload)
    AND receipt_digest=encode(extensions.digest(
      receipt_canonical,'sha256'
    ),'hex')
    AND authority_subject_proof_hash=request_subject_proof_hash
    AND subject_binding_digest=request_binding_digest
    AND exact_scope_digest=request_scope_sha256
    AND request_create_receipt_digest=request_create_digest
    AND created_at=request_created_at
    AND identity_authority_id=identity_proof_receipt_id
    AND identity_authority_digest=receipt_digest
    AND identity_payload->>'schemaVersion'=
      'privacy-request-identity-receipt.v2'
    AND (identity_payload->>'identityProofReceiptId')::uuid=
      identity_proof_receipt_id
    AND identity_payload->>'identityProofReceiptDigest'=btrim(receipt_digest)
    AND identity_canonical=ops.canonical_jsonb_v1(identity_payload)
    AND identity_digest=encode(extensions.digest(
      identity_canonical,'sha256'
    ),'hex')
    AND ops.privacy_identity_proof_authority_current_v1(
      identity_proof_receipt_id,clock_timestamp()
    );
  IF v_verified_authority_count<>2 THEN
    RAISE EXCEPTION
      'r6d_transition_verified_source_authority_fixture_invalid: %',
      v_verified_authority_count;
  END IF;

  IF NOT EXISTS(
       SELECT 1 FROM ops.privacy_requests_v2 AS request
       WHERE request.id=v_pending
         AND request.identity_state='PENDING_VERIFICATION'
         AND request.decision_version=0
         AND request.identity_proof_kind='RESPONSE_RECEIPT'
         AND request.identity_proof_ref_id=
           pg_temp.r6d_transition_uuid_v1('pending-identity-proof')
         AND request.identity_proof_binding_digest=encode(extensions.digest(
           ops.canonical_jsonb_v1(jsonb_build_object(
             'kind','RESPONSE_RECEIPT',
             'receiptId',pg_temp.r6d_transition_uuid_v1(
               'pending-identity-proof'
             ),'possessionTokenHmac',
             pg_temp.r6d_transition_sha256_text_v1('possession:pending')
           )),'sha256'
         ),'hex')
         AND request.current_identity_receipt_id IS NULL
         AND request.current_identity_receipt_digest IS NULL
     ) OR EXISTS(
       SELECT 1
       FROM ops.privacy_identity_proof_authority_receipts_v1
       WHERE privacy_request_id=v_pending
     ) OR EXISTS(
       SELECT 1 FROM ops.privacy_request_identity_receipts_v2
       WHERE privacy_request_id=v_pending
     ) OR EXISTS(
       SELECT 1 FROM intake.response_submission_receipts_v3
       WHERE receipt_id=
         pg_temp.r6d_transition_uuid_v1('pending-identity-proof')
     ) OR EXISTS(
       SELECT 1 FROM intake.communication_subjects
       WHERE id=pg_temp.r6d_transition_uuid_v1('pending-source-subject')
     ) OR ops.privacy_identity_proof_authority_current_v1(
       pg_temp.r6d_transition_uuid_v1('pending-identity-proof-authority'),
       clock_timestamp()
     ) THEN
    RAISE EXCEPTION 'r6d_transition_pending_authority_fixture_invalid';
  END IF;

  SELECT * INTO STRICT v_policy
  FROM ops.privacy_response_calendar_policies_v1
  WHERE policy_id='a6d00000-0000-4000-8000-000000000001'
    AND revision=2;
  SELECT * INTO STRICT v_calendar_row
  FROM ops.business_calendar_versions
  WHERE id='a6d40000-0000-4000-8000-000000000001';
  v_calendar:=ops.current_privacy_response_policy_calendar_v1(
    clock_timestamp()
  );
  IF v_policy.policy_payload<>jsonb_build_object(
       'policyVersion','test-only-r6d-v1','authoritySource','TEST_ONLY',
       'timezone','Asia/Seoul','daySystem','BUSINESS_DAY',
       'accessBusinessDays',10,'correctionBusinessDays',10,
       'deletionBusinessDays',10,'restrictionBusinessDays',10,
       'maximumExtensionBusinessDays',10,'maximumExtensionCount',1,
       'extensionNoticeTiming','BEFORE_CURRENT_DUE_AT',
       'refusalNoticeBusinessDays',10,
       'calendarVersionId',v_calendar_row.id,
       'calendarDigest',btrim(v_calendar_row.calendar_digest)
     )
     OR v_policy.policy_canonical<>
       ops.canonical_jsonb_v1(v_policy.policy_payload)
     OR v_policy.policy_digest<>encode(extensions.digest(
       v_policy.policy_canonical,'sha256'
     ),'hex')
     OR v_calendar_row.timezone<>'Asia/Seoul'
     OR v_calendar_row.weekend_days<>ARRAY[0,6]::smallint[]
     OR v_calendar_row.holiday_dates<>ARRAY[date '2026-08-10']
     OR v_calendar->>'policyDigest'<>btrim(v_policy.policy_digest)
     OR v_calendar->>'calendarDigest'<>
       btrim(v_calendar_row.calendar_digest) THEN
    RAISE EXCEPTION 'r6d_transition_test_only_authority_invalid';
  END IF;

  IF (SELECT count(*) FROM ops.record_class_schedules
      WHERE record_class IN (
        'PRIVACY_REQUEST','PRIVACY_REQUEST_EXECUTION',
        'PRIVACY_REQUEST_NOTICE','PRIVACY_REQUEST_SEALED_CONTENT'
      ))<>4 THEN
    RAISE EXCEPTION 'r6d_transition_schedule_fixture_invalid';
  END IF;
END
$fixture_roots$;

WITH command_spec(
  label,request_label,transition,expected_version,
  receipt_label,jti_label,step_up_label,reason_label,variant_kind,
  extension_days
) AS (VALUES
  ('start','main','START_REVIEW',1,'start','start','start','start_reason','NONE',NULL::integer),
  ('service_test_only','main','EXTEND',2,'service_test_only','service_test_only','service_test_only','service_reason','EXTEND',10),
  ('extension_11','main','EXTEND',2,'extension_11','extension_11','extension_11','extension_11_reason','EXTEND',11),
  ('extend','main','EXTEND',2,'extend','extend','extend','extend_reason','EXTEND',10),
  ('second_extension','main','EXTEND',3,'second_extension','second_extension','second_extension','second_extension_reason','EXTEND',1),
  ('expired_extension','expired','EXTEND',1,'expired_extension','expired_extension','expired_extension','expired_reason','EXTEND',1),
  ('wrong_version','main','START_REVIEW',999,'wrong_version','wrong_version','wrong_version','wrong_version_reason','NONE',NULL),
  ('duplicate_receipt','main','START_REVIEW',2,'start','duplicate_receipt','duplicate_receipt','duplicate_receipt_reason','NONE',NULL),
  ('duplicate_jti','main','START_REVIEW',2,'duplicate_jti','start','duplicate_jti','duplicate_jti_reason','NONE',NULL),
  ('duplicate_step_up','main','START_REVIEW',2,'duplicate_step_up','duplicate_step_up','start','duplicate_step_up_reason','NONE',NULL),
  ('verify_missing','pending','VERIFY_IDENTITY',0,'verify_missing','verify_missing','verify_missing','verify_reason','VERIFY',NULL),
  ('complete_invalid','main','COMPLETE',2,'complete_invalid','complete_invalid','complete_invalid','complete_reason','NONE',NULL),
  ('reject','main','REJECT',3,'reject','reject','reject','reject_reason','REJECT',NULL)
)
INSERT INTO r6d_transition_probe_commands(
  label,privacy_request_id,transition,expected_decision_version,
  transition_receipt_id,actor_assertion_jti,
  actor_assertion_request_sha256,step_up_authorization_id,
  idempotency_key_sha256,request_sha256,action_digest,request_id,reason_label,
  variant
)
SELECT
  spec.label,
  pg_temp.r6d_transition_uuid_v1(spec.request_label||'-request'),
  spec.transition,spec.expected_version,
  pg_temp.r6d_transition_uuid_v1(spec.receipt_label||'-transition-receipt'),
  pg_temp.r6d_transition_uuid_v1(spec.jti_label||'-assertion-jti'),
  pg_temp.r6d_transition_sha256_text_v1(
    'actor-wire-request:'||spec.jti_label
  ),
  pg_temp.r6d_transition_uuid_v1(spec.step_up_label||'-step-up'),
  pg_temp.r6d_transition_sha256_text_v1('idempotency:'||CASE
    WHEN spec.label='duplicate_step_up' THEN 'start' ELSE spec.label END),
  pg_temp.r6d_transition_sha256_text_v1('request:'||CASE
    WHEN spec.label='duplicate_step_up' THEN 'start' ELSE spec.label END),
  pg_temp.r6d_transition_sha256_text_v1('action:'||CASE
    WHEN spec.label='duplicate_step_up' THEN 'start' ELSE spec.label END),
  pg_temp.r6d_transition_uuid_v1(spec.label||'-owner-request'),
  spec.reason_label,
  CASE spec.variant_kind
    WHEN 'EXTEND' THEN jsonb_build_object(
      'extensionReasonCode','TEST_ONLY_EXTENSION',
      'extensionReasonCiphertextBase64',
        pg_temp.r6d_transition_base64_v1(
          pg_temp.r6d_transition_envelope_v1(
            spec.label||'_extension_reason'
          )
        ),
      'extensionReasonSha256',
        pg_temp.r6d_transition_sha256_text_v1(
          'extension-plaintext:'||spec.label
        ),
      'extensionBusinessDays',spec.extension_days
    )
    WHEN 'REJECT' THEN jsonb_build_object(
      'rejectionReasonCode','TEST_ONLY_REJECTION',
      'rejectionReasonCiphertextBase64',
        pg_temp.r6d_transition_base64_v1(
          pg_temp.r6d_transition_envelope_v1('reject_rejection_reason')
        ),
      'rejectionReasonSha256',
        pg_temp.r6d_transition_sha256_text_v1(
          'rejection-plaintext:reject'
        ),
      'appealInstructionsCiphertextBase64',
        pg_temp.r6d_transition_base64_v1(
          pg_temp.r6d_transition_envelope_v1('reject_appeal_instructions')
        ),
      'appealInstructionsSha256',
        pg_temp.r6d_transition_sha256_text_v1(
          'appeal-plaintext:reject'
        )
    )
    WHEN 'VERIFY' THEN jsonb_build_object(
      'identityProofReceiptId',
        pg_temp.r6d_transition_uuid_v1('missing-identity-proof')
    )
    ELSE '{}'::jsonb
  END
FROM command_spec AS spec;

-- TEST_ONLY boundary evidence: these append-only rows model Actor Assertions
-- whose HTTP signed-wire digest was already verified and consumed by Identity
-- API.  The replay case deliberately reuses start's JTI and wire digest.
INSERT INTO ops.assertion_replay_guard(
  assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
)
SELECT DISTINCT ON (command.actor_assertion_jti)
  'ACTOR',command.actor_assertion_jti,'identity-api','control-api',
  command.actor_assertion_request_sha256,
  statement_timestamp()+interval '10 minutes',
  statement_timestamp()-interval '1 minute'
FROM r6d_transition_probe_commands AS command
ORDER BY command.actor_assertion_jti,command.label;

INSERT INTO ops.idempotency_keys(
  scope,key_hash,request_hash,expires_at
)
SELECT DISTINCT ON (command.idempotency_key_sha256)
  'control:a6d50000-0000-4000-8000-000000000001:transitionRetentionRequest',
  command.idempotency_key_sha256,command.request_sha256,
  clock_timestamp()+interval '30 minutes'
FROM r6d_transition_probe_commands AS command
ORDER BY command.idempotency_key_sha256,command.label;

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,closed_at,assertion_issue_count,
  max_assertion_issues,created_at,last_issued_at
)
SELECT
  command.step_up_authorization_id,
  'a6d50000-0000-4000-8000-000000000002',
  command.action_digest,command.idempotency_key_sha256,
  pg_temp.r6d_transition_sha256_text_v1(
    'authorization-token:'||command.label
  ),
  clock_timestamp()+interval '4 minutes',NULL,1,3,
  clock_timestamp()-interval '1 minute',clock_timestamp()
FROM r6d_transition_probe_commands AS command
WHERE command.label<>'duplicate_step_up';

DO $command_fixture$
BEGIN
  IF (SELECT count(*) FROM r6d_transition_probe_commands)<>13
     OR (SELECT count(DISTINCT actor_assertion_jti)
         FROM r6d_transition_probe_commands)<>12
     OR (SELECT count(*) FROM ops.idempotency_keys
         WHERE scope=
           'control:a6d50000-0000-4000-8000-000000000001:transitionRetentionRequest'
        )<>12
     OR (SELECT count(*) FROM ops.step_up_authorizations
         WHERE session_id='a6d50000-0000-4000-8000-000000000002')<>12
     OR (SELECT count(*)
         FROM ops.assertion_replay_guard AS assertion
         WHERE assertion.assertion_type='ACTOR'
           AND EXISTS(
             SELECT 1 FROM r6d_transition_probe_commands AS command
             WHERE command.actor_assertion_jti=assertion.jti
           ))<>12
     OR EXISTS(
       SELECT 1
       FROM r6d_transition_probe_commands AS command
       LEFT JOIN ops.assertion_replay_guard AS assertion
         ON assertion.assertion_type='ACTOR'
        AND assertion.jti=command.actor_assertion_jti
       WHERE assertion.jti IS NULL
          OR assertion.issuer<>'identity-api'
          OR assertion.audience<>'control-api'
          OR assertion.request_digest<>
            command.actor_assertion_request_sha256
          OR assertion.consumed_at>clock_timestamp()
          OR assertion.expires_at<=clock_timestamp()
          OR command.actor_assertion_request_sha256=command.request_sha256
     ) OR NOT EXISTS(
       SELECT 1
       FROM r6d_transition_probe_commands AS start_command
       JOIN r6d_transition_probe_commands AS replay_command
         ON replay_command.label='duplicate_jti'
       JOIN r6d_transition_probe_commands AS step_up_command
         ON step_up_command.label='duplicate_step_up'
       WHERE start_command.label='start'
         AND replay_command.actor_assertion_jti=
           start_command.actor_assertion_jti
         AND replay_command.actor_assertion_request_sha256=
           start_command.actor_assertion_request_sha256
         AND replay_command.request_sha256<>start_command.request_sha256
         AND step_up_command.actor_assertion_jti<>
           start_command.actor_assertion_jti
         AND step_up_command.actor_assertion_request_sha256<>
           start_command.actor_assertion_request_sha256
         AND step_up_command.step_up_authorization_id=
           start_command.step_up_authorization_id
         AND step_up_command.action_digest=start_command.action_digest
         AND step_up_command.idempotency_key_sha256=
           start_command.idempotency_key_sha256
         AND step_up_command.request_sha256=start_command.request_sha256
     ) OR EXISTS(
       SELECT 1
       FROM r6d_transition_probe_commands AS command
       CROSS JOIN LATERAL (SELECT
         pg_temp.r6d_transition_payload_v1(
           command.privacy_request_id,command.transition,
           command.expected_decision_version,command.transition_receipt_id,
           command.actor_assertion_jti,
           command.actor_assertion_request_sha256,
           command.step_up_authorization_id,
           command.idempotency_key_sha256,command.action_digest,
           command.reason_label,command.variant
         ) AS value
       ) AS payload
       WHERE payload.value->>'_actorAssertionRequestSha256'<>
           btrim(command.actor_assertion_request_sha256)
          OR (SELECT count(*) FROM jsonb_object_keys(payload.value))<>
            CASE command.transition
              WHEN 'EXTEND' THEN 19
              WHEN 'REJECT' THEN 20
              WHEN 'VERIFY_IDENTITY' THEN 16
              ELSE 15
            END
          OR command.transition<>'VERIFY_IDENTITY' AND (
            SELECT count(*) FROM jsonb_object_keys(
              payload.value-'_actorAssertionRequestSha256'
            )
          )<>CASE command.transition
            WHEN 'EXTEND' THEN 18
            WHEN 'REJECT' THEN 19
            ELSE 14
          END
          OR command.transition='VERIFY_IDENTITY' AND (
            SELECT count(*) FROM jsonb_object_keys(
              payload.value-'transition'
            )
          )<>15
     ) THEN
    RAISE EXCEPTION 'r6d_transition_command_fixture_invalid';
  END IF;
END
$command_fixture$;

CREATE FUNCTION pg_temp.r6d_transition_expect_failure_v1(
  p_label text,
  p_expected_sqlstate text,
  p_expected_message text
) RETURNS void
LANGUAGE plpgsql
VOLATILE
STRICT
SET search_path=pg_catalog,ops,pg_temp
AS $expect_failure$
DECLARE
  v_before char(64):=pg_temp.r6d_transition_write_fingerprint_v1();
  v_after char(64);
  v_sqlstate text;
  v_message text;
BEGIN
  BEGIN
    PERFORM pg_temp.r6d_transition_call_v1(p_label);
    RAISE EXCEPTION 'r6d_transition_expected_failure_missing:%',p_label
      USING ERRCODE='P9000';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
      v_sqlstate=RETURNED_SQLSTATE,
      v_message=MESSAGE_TEXT;
    IF v_sqlstate<>p_expected_sqlstate
       OR v_message<>p_expected_message THEN
      RAISE EXCEPTION
        'r6d transition failure mismatch label=% expected=%/% actual=%/%',
        p_label,p_expected_sqlstate,p_expected_message,v_sqlstate,v_message;
    END IF;
  END;
  v_after:=pg_temp.r6d_transition_write_fingerprint_v1();
  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'r6d transition failure wrote durable state: %',p_label;
  END IF;
END
$expect_failure$;
GRANT EXECUTE ON FUNCTION
  pg_temp.r6d_transition_expect_failure_v1(text,text,text)
TO gurine_control_api;

SET LOCAL ROLE gurine_submission_api;
DO $create_negative$
DECLARE
  v_valid_scope jsonb:=jsonb_build_object(
    'scopeKind','ALL_VERIFIED_SUBJECT_DATA','objectRefs','[]'::jsonb,
    'dateFrom',NULL,'dateTo',NULL,
    'includeDerivatives',true,'includeBackups',false
  );
  v_invalid_scope jsonb:=jsonb_build_object(
    'scopeKind','OBJECT_SET','objectRefs','[]'::jsonb,
    'dateFrom',NULL,'dateTo',NULL,
    'includeDerivatives',true,'includeBackups',false
  );
  v_valid_identity jsonb:=jsonb_build_object(
    'kind','RESPONSE_RECEIPT',
    'receiptId',pg_temp.r6d_transition_uuid_v1(
      'main-identity-proof'
    ),
    'possessionTokenHmac',pg_temp.r6d_transition_sha256_text_v1(
      'possession:main'
    )
  );
  v_before char(64):=pg_temp.r6d_transition_write_fingerprint_v1();
  v_sqlstate text;
  v_message text;
BEGIN
  BEGIN
    PERFORM ops.create_privacy_request_v2(
      pg_temp.r6d_transition_create_payload_v1(
        'identity-invalid',jsonb_build_object('kind','UNKNOWN'),v_valid_scope
      ),
      pg_temp.r6d_transition_uuid_v1('create-identity-invalid-owner'),
      pg_temp.r6d_transition_sha256_text_v1(
        'create-identity-invalid-idempotency'
      ),
      pg_temp.r6d_transition_sha256_text_v1(
        'create-identity-invalid-request'
      )
    );
    RAISE EXCEPTION 'invalid create identity succeeded' USING ERRCODE='P9000';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
      v_sqlstate=RETURNED_SQLSTATE,v_message=MESSAGE_TEXT;
    IF v_sqlstate<>'PVT06'
       OR v_message<>'privacy_request_identity_proof_invalid' THEN
      RAISE EXCEPTION 'invalid create identity mismatch: %/%',
        v_sqlstate,v_message;
    END IF;
  END;
  IF pg_temp.r6d_transition_write_fingerprint_v1()
       IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'invalid create identity left durable writes';
  END IF;

  BEGIN
    PERFORM ops.create_privacy_request_v2(
      pg_temp.r6d_transition_create_payload_v1(
        'scope-invalid',v_valid_identity,v_invalid_scope
      )||jsonb_build_object(
        'communicationEndpointHmac',btrim(
          pg_temp.r6d_transition_sha256_text_v1('endpoint-hmac:main')
        )
      ),
      pg_temp.r6d_transition_uuid_v1('create-scope-invalid-owner'),
      pg_temp.r6d_transition_sha256_text_v1(
        'create-scope-invalid-idempotency'
      ),
      pg_temp.r6d_transition_sha256_text_v1(
        'create-scope-invalid-request'
      )
    );
    RAISE EXCEPTION 'invalid create scope succeeded' USING ERRCODE='P9000';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
      v_sqlstate=RETURNED_SQLSTATE,v_message=MESSAGE_TEXT;
    IF v_sqlstate<>'PVT07'
       OR v_message<>'privacy_request_scope_invalid' THEN
      RAISE EXCEPTION 'invalid create scope mismatch: %/%',
        v_sqlstate,v_message;
    END IF;
  END;
  IF pg_temp.r6d_transition_write_fingerprint_v1()
       IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'invalid create scope left durable writes';
  END IF;
END
$create_negative$;
RESET ROLE;

SET LOCAL ROLE gurine_control_api;
INSERT INTO r6d_transition_probe_results(label,result)
VALUES('start',pg_temp.r6d_transition_call_v1('start'));
RESET ROLE;

DO $start_review_positive$
DECLARE
  v_command r6d_transition_probe_commands%ROWTYPE;
  v_result jsonb;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_identity ops.privacy_request_identity_receipts_v2%ROWTYPE;
  v_receipt ops.privacy_request_transition_receipts_v2%ROWTYPE;
  v_event ops.outbox%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_command
  FROM r6d_transition_probe_commands WHERE label='start';
  SELECT result INTO STRICT v_result
  FROM r6d_transition_probe_results WHERE label='start';
  SELECT * INTO STRICT v_request FROM ops.privacy_requests_v2
  WHERE id=v_command.privacy_request_id;
  SELECT * INTO STRICT v_identity
  FROM ops.privacy_request_identity_receipts_v2
  WHERE identity_receipt_id=v_request.current_identity_receipt_id;
  SELECT * INTO STRICT v_receipt
  FROM ops.privacy_request_transition_receipts_v2
  WHERE transition_receipt_id=v_command.transition_receipt_id;
  SELECT * INTO STRICT v_event FROM ops.outbox
  WHERE id=v_receipt.event_receipt_id;

  IF (SELECT count(*) FROM jsonb_object_keys(v_result))<>11
     OR (SELECT count(*) FROM jsonb_object_keys(v_result->'transition'))<>24
     OR v_result->>'status'<>'COMPLETED'
     OR (v_result->>'aggregateId')::uuid<>v_request.id
     OR (v_result->>'aggregateVersion')::bigint<>2
     OR v_result->'outboxEventIds'<>v_result->'emittedEventIds'
     OR jsonb_array_length(v_result->'outboxEventIds')<>1
     OR v_result#>>'{transition,transition}'<>'START_REVIEW'
     OR v_result#>>'{transition,state}'<>'REVIEW'
     OR (v_result#>>'{transition,replayed}')::boolean
     OR v_result#>'{transition,extensionReceiptId}'<>'null'::jsonb
     OR v_result#>'{transition,refusalReceiptId}'<>'null'::jsonb
     OR v_result#>'{transition,noticeReceiptId}'<>'null'::jsonb THEN
    RAISE EXCEPTION 'START_REVIEW result ABI invalid';
  END IF;
  IF v_request.state<>'REVIEW' OR v_request.decision_version<>2
     OR v_request.identity_state<>'VERIFIED'
     OR v_request.due_at IS NULL
     OR v_request.current_identity_receipt_id IS NULL
     OR num_nonnulls(
       v_request.current_extension_receipt_id,
       v_request.current_extension_receipt_digest,
       v_request.current_refusal_receipt_id,
       v_request.current_refusal_receipt_digest
     )<>0
     OR v_request.current_notice_receipt_id<>
       v_identity.notice_receipt_id
     OR v_request.current_notice_receipt_digest<>
       v_identity.notice_receipt_digest THEN
    RAISE EXCEPTION 'START_REVIEW request root invalid';
  END IF;
  IF v_receipt.privacy_request_id<>v_request.id
     OR v_receipt.decision_version<>2
     OR v_receipt.transition<>'START_REVIEW'
     OR v_receipt.prior_state<>'RECEIVED'
     OR v_receipt.state<>'REVIEW'
     OR v_receipt.receipt_canonical<>
       ops.canonical_jsonb_v1(v_receipt.receipt_payload)
     OR v_receipt.receipt_digest<>encode(extensions.digest(
       v_receipt.receipt_canonical,'sha256'
     ),'hex')
     OR v_receipt.outbox_event_ids<>ARRAY[v_event.id]::uuid[]
     OR NOT ops.uuid_array_is_sorted_unique(v_receipt.outbox_event_ids)
     OR v_receipt.event_receipt_digest<>
       ops.r6d_outbox_envelope_digest_v1(v_event.id) THEN
    RAISE EXCEPTION 'START_REVIEW transition receipt invalid';
  END IF;
  IF v_event.event_type<>'privacy.request_decision_recorded.v1'
     OR v_event.aggregate_type<>'privacy_request'
     OR v_event.aggregate_id<>v_request.id::text
     OR v_event.aggregate_version<>2
     OR (SELECT count(*) FROM jsonb_object_keys(v_event.payload))<>9
     OR v_event.payload->>'transition'<>'START_REVIEW'
     OR v_event.payload->>'priorState'<>'RECEIVED'
     OR v_event.payload->>'state'<>'REVIEW'
     OR v_event.payload->'inventorySnapshotDigest'<>'null'::jsonb
     OR v_event.payload->'holdCoverageDigest'<>'null'::jsonb
     OR v_event.payload->>'receiptDigest'<>btrim(v_receipt.receipt_digest)
     OR v_event.payload->>'decisionDigest'<>
       v_receipt.receipt_payload->>'decisionDigest' THEN
    RAISE EXCEPTION 'START_REVIEW event payload invalid';
  END IF;
  IF (SELECT count(*) FROM ops.audit_events
      WHERE request_id=v_command.request_id
        AND action='command.transitionRetentionRequest'
        AND object_id=v_request.id::text
        AND outcome='SUCCESS')<>1
     OR (SELECT count(*) FROM ops.privacy_request_sealed_content_v2
         WHERE transition_receipt_id=v_receipt.transition_receipt_id)<>1
     OR NOT EXISTS(
       SELECT 1 FROM ops.privacy_request_sealed_content_v2 AS content
       WHERE content.transition_receipt_id=v_receipt.transition_receipt_id
         AND content.field_kind='REASON'
         AND content.sealed_ciphertext=
           pg_temp.r6d_transition_envelope_v1(v_command.reason_label)
         AND content.sealed_sha256=v_receipt.reason_sha256
         AND content.sealed_aad_digest=v_receipt.reason_aad_digest
         AND content.content_state='ACTIVE'
         AND content.expires_at>clock_timestamp()
     ) THEN
    RAISE EXCEPTION 'START_REVIEW audit/sealed cardinality invalid';
  END IF;
END
$start_review_positive$;

-- Reuse the successful command's exact STEP_UP authorization, action digest,
-- idempotency key, and request hash while its claim is still incomplete.  The
-- owner must detect the already-bound STEP_UP/idempotency identity without
-- mutating either the authorization or the successful receipt graph.
SET LOCAL ROLE gurine_control_api;
SELECT pg_temp.r6d_transition_expect_failure_v1(
  'duplicate_step_up','40001',
  'privacy_transition_receipt_identity_conflict'
);
RESET ROLE;

-- The surrounding HTTP/dispatcher owner completes idempotency storage after
-- the direct SQL owner returns.  Once completed, the SQL owner must reject a
-- direct call rather than manufacture a replay response.
UPDATE ops.idempotency_keys AS key
SET response_status=200,
    response_body=result.result,
    resource_type='PrivacyRequest',
    resource_id=result.result->>'aggregateId'
FROM r6d_transition_probe_commands AS command,
     r6d_transition_probe_results AS result
WHERE command.label='start' AND result.label='start'
  AND key.scope=
    'control:a6d50000-0000-4000-8000-000000000001:transitionRetentionRequest'
  AND key.key_hash=command.idempotency_key_sha256;

SET LOCAL ROLE gurine_control_api;
SELECT pg_temp.r6d_transition_expect_failure_v1(
  'start','40001','privacy_transition_idempotency_conflict'
);
RESET ROLE;

-- TEST_ONLY calendar rows are visible only to a migrator-member
-- session_user.  Prove that changing only current_role is not the basis of
-- this gate: the real service session_user must fail closed without writes.
SET SESSION AUTHORIZATION gurine_control_api;
SELECT pg_temp.r6d_transition_expect_failure_v1(
  'service_test_only','55000',
  'privacy_response_policy_calendar_current_missing'
);
RESET SESSION AUTHORIZATION;

SET LOCAL ROLE gurine_control_api;
SELECT pg_temp.r6d_transition_expect_failure_v1(
  'wrong_version','PVT08','privacy_transition_version_conflict'
);
SELECT pg_temp.r6d_transition_expect_failure_v1(
  'extension_11','23514','privacy_extension_business_days_exceeded'
);
SELECT pg_temp.r6d_transition_expect_failure_v1(
  'duplicate_receipt','40001',
  'privacy_transition_receipt_identity_conflict'
);
SELECT pg_temp.r6d_transition_expect_failure_v1(
  'duplicate_jti','40001',
  'privacy_transition_receipt_identity_conflict'
);
RESET ROLE;

SET LOCAL ROLE gurine_control_api;
SELECT pg_temp.r6d_transition_expect_failure_v1(
  'expired_extension','23514','privacy_extension_notice_expired'
);
SELECT pg_temp.r6d_transition_expect_failure_v1(
  'verify_missing','PVT06','privacy_identity_verification_proof_invalid'
);
SELECT pg_temp.r6d_transition_expect_failure_v1(
  'complete_invalid','22023','privacy_transition_input_invalid'
);
RESET ROLE;

SET LOCAL ROLE gurine_control_api;
INSERT INTO r6d_transition_probe_results(label,result)
VALUES('extend',pg_temp.r6d_transition_call_v1('extend'));
RESET ROLE;

DO $extend_positive$
DECLARE
  v_command r6d_transition_probe_commands%ROWTYPE;
  v_result jsonb;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_receipt ops.privacy_request_transition_receipts_v2%ROWTYPE;
  v_extension ops.privacy_request_extension_receipts_v2%ROWTYPE;
  v_notice ops.privacy_request_notice_receipts_v2%ROWTYPE;
  v_event ops.outbox%ROWTYPE;
  v_expected_due_at timestamptz;
BEGIN
  SELECT * INTO STRICT v_command
  FROM r6d_transition_probe_commands WHERE label='extend';
  SELECT result INTO STRICT v_result
  FROM r6d_transition_probe_results WHERE label='extend';
  SELECT * INTO STRICT v_request
  FROM ops.privacy_requests_v2 WHERE id=v_command.privacy_request_id;
  SELECT * INTO STRICT v_receipt
  FROM ops.privacy_request_transition_receipts_v2
  WHERE transition_receipt_id=v_command.transition_receipt_id;
  SELECT * INTO STRICT v_extension
  FROM ops.privacy_request_extension_receipts_v2
  WHERE extension_receipt_id=v_receipt.extension_receipt_id;
  SELECT * INTO STRICT v_notice
  FROM ops.privacy_request_notice_receipts_v2
  WHERE notice_receipt_id=v_receipt.notice_receipt_id;
  SELECT * INTO STRICT v_event
  FROM ops.outbox WHERE id=v_receipt.event_receipt_id;

  v_expected_due_at:=ops.add_privacy_business_days_v1(
    v_extension.prior_due_at,v_extension.extension_business_days,
    v_extension.calendar_version_id,v_extension.calendar_digest
  );
  IF (SELECT count(*) FROM jsonb_object_keys(v_result))<>11
     OR (SELECT count(*) FROM jsonb_object_keys(
          v_result->'transition'))<>24
     OR v_result->>'status'<>'COMPLETED'
     OR (v_result->>'aggregateId')::uuid<>v_request.id
     OR (v_result->>'aggregateVersion')::bigint<>3
     OR v_result->'outboxEventIds'<>v_result->'emittedEventIds'
     OR jsonb_array_length(v_result->'outboxEventIds')<>1
     OR v_result#>>'{transition,transition}'<>'EXTEND'
     OR v_result#>>'{transition,state}'<>'REVIEW'
     OR (v_result#>>'{transition,replayed}')::boolean
     OR (v_result#>>'{transition,extensionReceiptId}')::uuid<>
       v_extension.extension_receipt_id
     OR v_result#>>'{transition,extensionReceiptDigest}'<>
       btrim(v_extension.receipt_digest)
     OR (v_result#>>'{transition,noticeReceiptId}')::uuid<>
       v_notice.notice_receipt_id
     OR v_result#>>'{transition,noticeReceiptDigest}'<>
       btrim(v_notice.receipt_digest)
     OR v_result#>'{transition,refusalReceiptId}'<>'null'::jsonb
     OR (v_result#>>'{transition,dueAt}')::timestamptz<>
       v_expected_due_at THEN
    RAISE EXCEPTION 'EXTEND result ABI invalid';
  END IF;

  IF v_request.state<>'REVIEW' OR v_request.decision_version<>3
     OR v_request.identity_state<>'VERIFIED'
     OR v_request.due_at<>v_expected_due_at
     OR v_request.current_extension_receipt_id<>
       v_extension.extension_receipt_id
     OR v_request.current_extension_receipt_digest<>
       v_extension.receipt_digest
     OR v_request.current_notice_receipt_id<>v_notice.notice_receipt_id
     OR v_request.current_notice_receipt_digest<>v_notice.receipt_digest
     OR num_nonnulls(
       v_request.current_refusal_receipt_id,
       v_request.current_refusal_receipt_digest
     )<>0 THEN
    RAISE EXCEPTION 'EXTEND request root invalid';
  END IF;

  IF v_receipt.privacy_request_id<>v_request.id
     OR v_receipt.decision_version<>3
     OR v_receipt.transition<>'EXTEND'
     OR v_receipt.prior_state<>'REVIEW'
     OR v_receipt.state<>'REVIEW'
     OR v_receipt.extension_receipt_id<>v_extension.extension_receipt_id
     OR v_receipt.extension_receipt_digest<>v_extension.receipt_digest
     OR v_receipt.notice_receipt_id<>v_notice.notice_receipt_id
     OR v_receipt.notice_receipt_digest<>v_notice.receipt_digest
     OR num_nonnulls(
       v_receipt.refusal_receipt_id,v_receipt.refusal_receipt_digest,
       v_receipt.rejection_reason_code,v_receipt.rejection_reason_sha256,
       v_receipt.rejection_reason_aad_digest,
       v_receipt.appeal_instructions_sha256,
       v_receipt.appeal_instructions_aad_digest
     )<>0
     OR v_receipt.receipt_canonical<>
       ops.canonical_jsonb_v1(v_receipt.receipt_payload)
     OR v_receipt.receipt_digest<>encode(extensions.digest(
       v_receipt.receipt_canonical,'sha256'
     ),'hex')
     OR v_receipt.event_receipt_id<>v_event.id
     OR v_receipt.event_receipt_digest<>
       ops.r6d_outbox_envelope_digest_v1(v_event.id)
     OR v_receipt.outbox_event_ids<>ARRAY[v_event.id]::uuid[]
     OR NOT ops.uuid_array_is_sorted_unique(v_receipt.outbox_event_ids) THEN
    RAISE EXCEPTION 'EXTEND transition receipt invalid';
  END IF;

  IF v_extension.privacy_request_id<>v_request.id
     OR v_extension.decision_version<>3
     OR v_extension.extension_sequence<>1
     OR v_extension.extension_business_days<>10
     OR v_extension.prior_due_at>=v_extension.due_at
     OR v_extension.due_at<>v_expected_due_at
     OR v_extension.extension_reason_code<>'TEST_ONLY_EXTENSION'
     OR v_extension.extension_reason_sha256<>
       v_receipt.extension_reason_sha256
     OR v_extension.notice_receipt_id<>v_notice.notice_receipt_id
     OR v_extension.notice_receipt_digest<>v_notice.receipt_digest
     OR v_extension.event_receipt_id<>v_event.id
     OR v_extension.event_receipt_digest<>
       v_receipt.event_receipt_digest
     OR v_extension.receipt_canonical<>
       ops.canonical_jsonb_v1(v_extension.receipt_payload)
     OR v_extension.receipt_digest<>encode(extensions.digest(
       v_extension.receipt_canonical,'sha256'
     ),'hex') THEN
    RAISE EXCEPTION 'EXTEND branch receipt invalid';
  END IF;

  IF v_notice.privacy_request_id<>v_request.id
     OR v_notice.notice_sequence<>2
     OR v_notice.notice_kind<>'EXTENSION'
     OR v_notice.transition_receipt_id<>v_receipt.transition_receipt_id
     OR v_notice.branch_receipt_id<>v_extension.extension_receipt_id
     OR v_notice.branch_receipt_digest<>v_extension.receipt_digest
     OR v_notice.event_receipt_id<>v_event.id
     OR v_notice.event_receipt_digest<>v_receipt.event_receipt_digest
     OR v_notice.notice_template_digest<>encode(extensions.digest(
       ops.canonical_jsonb_v1(v_notice.notice_template_payload),'sha256'
     ),'hex')
     OR v_notice.notice_sha256<>v_notice.notice_template_digest
     OR v_notice.receipt_canonical<>
       ops.canonical_jsonb_v1(v_notice.receipt_payload)
     OR v_notice.receipt_digest<>encode(extensions.digest(
       v_notice.receipt_canonical,'sha256'
     ),'hex') THEN
    RAISE EXCEPTION 'EXTEND notice receipt invalid';
  END IF;

  IF v_event.event_type<>'privacy.request_extension_notified.v1'
     OR v_event.aggregate_type<>'privacy_request'
     OR v_event.aggregate_id<>v_request.id::text
     OR v_event.aggregate_version<>3
     OR (SELECT count(*) FROM jsonb_object_keys(v_event.payload))<>13
     OR v_event.payload->>'requestType'<>'ACCESS'
     OR (v_event.payload->>'priorDueAt')::timestamptz<>
       v_extension.prior_due_at
     OR (v_event.payload->>'dueAt')::timestamptz<>v_extension.due_at
     OR (v_event.payload->>'extensionBusinessDays')::integer<>10
     OR (v_event.payload->>'extensionSequence')::integer<>1
     OR v_event.payload->>'reasonDigest'<>
       btrim(v_extension.extension_reason_sha256)
     OR v_event.payload->>'responsePolicyDigest'<>
       btrim(v_extension.response_policy_digest)
     OR (v_event.payload->>'calendarVersionId')::uuid<>
       v_extension.calendar_version_id
     OR v_event.payload->>'calendarDigest'<>
       btrim(v_extension.calendar_digest)
     OR (v_event.payload->>'notifiedAt')::timestamptz<>v_notice.created_at
     OR v_event.payload->>'notificationReceiptDigest'<>
       btrim(v_notice.receipt_digest)
     OR (SELECT count(*) FROM ops.outbox AS event
         WHERE event.aggregate_type='privacy_request'
           AND event.aggregate_id=v_request.id::text
           AND event.aggregate_version=3)<>1 THEN
    RAISE EXCEPTION 'EXTEND event payload invalid';
  END IF;

  IF (SELECT count(*) FROM ops.audit_events
      WHERE request_id=v_command.request_id
        AND action='command.transitionRetentionRequest'
        AND object_id=v_request.id::text
        AND outcome='SUCCESS')<>1
     OR (SELECT array_agg(content.field_kind ORDER BY content.field_kind)
         FROM ops.privacy_request_sealed_content_v2 AS content
         WHERE content.transition_receipt_id=v_receipt.transition_receipt_id)
       <>ARRAY['EXTENSION_REASON','REASON']::text[]
     OR NOT EXISTS(
       SELECT 1 FROM ops.privacy_request_sealed_content_v2 AS content
       WHERE content.transition_receipt_id=v_receipt.transition_receipt_id
         AND content.field_kind='REASON'
         AND content.sealed_ciphertext=
           pg_temp.r6d_transition_envelope_v1(v_command.reason_label)
         AND content.sealed_sha256=v_receipt.reason_sha256
         AND content.sealed_aad_digest=v_receipt.reason_aad_digest
     )
     OR NOT EXISTS(
       SELECT 1 FROM ops.privacy_request_sealed_content_v2 AS content
       WHERE content.transition_receipt_id=v_receipt.transition_receipt_id
         AND content.field_kind='EXTENSION_REASON'
         AND content.sealed_ciphertext=
           pg_temp.r6d_transition_envelope_v1('extend_extension_reason')
         AND content.sealed_sha256=v_receipt.extension_reason_sha256
         AND content.sealed_aad_digest=
           v_receipt.extension_reason_aad_digest
     ) THEN
    RAISE EXCEPTION 'EXTEND audit/sealed graph invalid';
  END IF;
END
$extend_positive$;

UPDATE ops.idempotency_keys AS key
SET response_status=200,
    response_body=result.result,
    resource_type='PrivacyRequest',
    resource_id=result.result->>'aggregateId'
FROM r6d_transition_probe_commands AS command,
     r6d_transition_probe_results AS result
WHERE command.label='extend' AND result.label='extend'
  AND key.scope=
    'control:a6d50000-0000-4000-8000-000000000001:transitionRetentionRequest'
  AND key.key_hash=command.idempotency_key_sha256;

SET LOCAL ROLE gurine_control_api;
SELECT pg_temp.r6d_transition_expect_failure_v1(
  'extend','40001','privacy_transition_idempotency_conflict'
);
RESET ROLE;

SET LOCAL ROLE gurine_control_api;
SELECT pg_temp.r6d_transition_expect_failure_v1(
  'second_extension','23514','privacy_extension_count_exceeded'
);
RESET ROLE;

-- Exercise the public generic Control dispatcher on the final positive edge,
-- not only the underlying privacy owner.  Preserve its complete 8-column row
-- contract and the nested 11/24-key response for graph assertions below.
SET LOCAL ROLE gurine_control_api;
DO $reject_dispatcher_positive$
DECLARE
  v_command r6d_transition_probe_commands%ROWTYPE;
  v_dispatcher record;
  v_dispatcher_json jsonb;
BEGIN
  SELECT * INTO STRICT v_command
  FROM r6d_transition_probe_commands WHERE label='reject';
  SELECT dispatcher.* INTO STRICT v_dispatcher
  FROM ops.apply_control_addendum_command(
    'transitionRetentionRequest',
    pg_temp.r6d_transition_payload_v1(
      v_command.privacy_request_id,v_command.transition,
      v_command.expected_decision_version,
      v_command.transition_receipt_id,v_command.actor_assertion_jti,
      v_command.actor_assertion_request_sha256,
      v_command.step_up_authorization_id,
      v_command.idempotency_key_sha256,v_command.action_digest,
      v_command.reason_label,v_command.variant
    ),
    'a6d50000-0000-4000-8000-000000000001',
    'a6d50000-0000-4000-8000-000000000002',
    v_command.request_id,v_command.idempotency_key_sha256,
    v_command.request_sha256
  ) AS dispatcher;
  v_dispatcher_json:=to_jsonb(v_dispatcher);
  IF (SELECT count(*) FROM jsonb_object_keys(v_dispatcher_json))<>8
     OR v_dispatcher.status<>'COMPLETED'
     OR v_dispatcher.aggregate_id<>v_command.privacy_request_id
     OR v_dispatcher.aggregate_version<>4
     OR (SELECT count(*) FROM jsonb_object_keys(
          v_dispatcher.response_body))<>11
     OR (SELECT count(*) FROM jsonb_object_keys(
          v_dispatcher.response_body->'transition'))<>24
     OR v_dispatcher.response_body->>'status'<>v_dispatcher.status
     OR (v_dispatcher.response_body->>'aggregateId')::uuid<>
       v_dispatcher.aggregate_id
     OR (v_dispatcher.response_body->>'aggregateVersion')::bigint<>
       v_dispatcher.aggregate_version
     OR (v_dispatcher.response_body->>'acceptedAt')::timestamptz<>
       v_dispatcher.accepted_at
     OR v_dispatcher.response_body->>'receiptDigest'<>
       btrim(v_dispatcher.receipt_digest)
     OR (v_dispatcher.response_body->>'auditEventId')::uuid<>
       v_dispatcher.audit_event_id
     OR NOT (v_dispatcher.response_body->'outboxEventIds') ?
       v_dispatcher.outbox_event_id::text THEN
    RAISE EXCEPTION 'REJECT dispatcher row ABI invalid';
  END IF;
  INSERT INTO r6d_transition_probe_results(label,result)
  VALUES('reject',v_dispatcher.response_body);
END
$reject_dispatcher_positive$;
RESET ROLE;

DO $reject_positive$
DECLARE
  v_command r6d_transition_probe_commands%ROWTYPE;
  v_result jsonb;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_receipt ops.privacy_request_transition_receipts_v2%ROWTYPE;
  v_extension ops.privacy_request_extension_receipts_v2%ROWTYPE;
  v_refusal ops.privacy_request_refusal_receipts_v2%ROWTYPE;
  v_notice ops.privacy_request_notice_receipts_v2%ROWTYPE;
  v_decision_event ops.outbox%ROWTYPE;
  v_notification_event ops.outbox%ROWTYPE;
  v_expected_notice_due_at timestamptz;
BEGIN
  SELECT * INTO STRICT v_command
  FROM r6d_transition_probe_commands WHERE label='reject';
  SELECT result INTO STRICT v_result
  FROM r6d_transition_probe_results WHERE label='reject';
  SELECT * INTO STRICT v_request
  FROM ops.privacy_requests_v2 WHERE id=v_command.privacy_request_id;
  SELECT * INTO STRICT v_receipt
  FROM ops.privacy_request_transition_receipts_v2
  WHERE transition_receipt_id=v_command.transition_receipt_id;
  SELECT * INTO STRICT v_extension
  FROM ops.privacy_request_extension_receipts_v2
  WHERE extension_receipt_id=v_request.current_extension_receipt_id;
  SELECT * INTO STRICT v_refusal
  FROM ops.privacy_request_refusal_receipts_v2
  WHERE refusal_receipt_id=v_receipt.refusal_receipt_id;
  SELECT * INTO STRICT v_notice
  FROM ops.privacy_request_notice_receipts_v2
  WHERE notice_receipt_id=v_receipt.notice_receipt_id;
  SELECT * INTO STRICT v_notification_event
  FROM ops.outbox WHERE id=v_receipt.event_receipt_id;
  SELECT * INTO STRICT v_decision_event
  FROM ops.outbox AS event
  WHERE event.id=ANY(v_receipt.outbox_event_ids)
    AND event.event_type='privacy.request_decision_recorded.v1';

  v_expected_notice_due_at:=ops.add_privacy_business_days_v1(
    v_refusal.decision_at,10,v_refusal.calendar_version_id,
    v_refusal.calendar_digest
  );
  IF (SELECT count(*) FROM jsonb_object_keys(v_result))<>11
     OR (SELECT count(*) FROM jsonb_object_keys(
          v_result->'transition'))<>24
     OR v_result->>'status'<>'COMPLETED'
     OR (v_result->>'aggregateId')::uuid<>v_request.id
     OR (v_result->>'aggregateVersion')::bigint<>4
     OR v_result->'outboxEventIds'<>v_result->'emittedEventIds'
     OR jsonb_array_length(v_result->'outboxEventIds')<>2
     OR v_result#>>'{transition,transition}'<>'REJECT'
     OR v_result#>>'{transition,state}'<>'REJECTED'
     OR (v_result#>>'{transition,replayed}')::boolean
     OR v_result#>'{transition,extensionReceiptId}'<>'null'::jsonb
     OR (v_result#>>'{transition,refusalReceiptId}')::uuid<>
       v_refusal.refusal_receipt_id
     OR v_result#>>'{transition,refusalReceiptDigest}'<>
       btrim(v_refusal.receipt_digest)
     OR (v_result#>>'{transition,noticeReceiptId}')::uuid<>
       v_notice.notice_receipt_id
     OR v_result#>>'{transition,noticeReceiptDigest}'<>
       btrim(v_notice.receipt_digest)
     OR v_result#>>'{transition,appealInstructionsDigest}'<>
       btrim(v_refusal.appeal_instructions_sha256) THEN
    RAISE EXCEPTION 'REJECT result ABI invalid';
  END IF;

  IF v_request.state<>'REJECTED' OR v_request.decision_version<>4
     OR v_request.identity_state<>'VERIFIED'
     OR v_request.due_at<>v_extension.due_at
     OR v_request.current_extension_receipt_id<>
       v_extension.extension_receipt_id
     OR v_request.current_extension_receipt_digest<>
       v_extension.receipt_digest
     OR v_request.current_refusal_receipt_id<>v_refusal.refusal_receipt_id
     OR v_request.current_refusal_receipt_digest<>v_refusal.receipt_digest
     OR v_request.current_notice_receipt_id<>v_notice.notice_receipt_id
     OR v_request.current_notice_receipt_digest<>v_notice.receipt_digest THEN
    RAISE EXCEPTION 'REJECT request root invalid';
  END IF;

  IF v_receipt.privacy_request_id<>v_request.id
     OR v_receipt.decision_version<>4
     OR v_receipt.transition<>'REJECT'
     OR v_receipt.prior_state<>'REVIEW'
     OR v_receipt.state<>'REJECTED'
     OR v_receipt.refusal_receipt_id<>v_refusal.refusal_receipt_id
     OR v_receipt.refusal_receipt_digest<>v_refusal.receipt_digest
     OR v_receipt.notice_receipt_id<>v_notice.notice_receipt_id
     OR v_receipt.notice_receipt_digest<>v_notice.receipt_digest
     OR num_nonnulls(
       v_receipt.extension_receipt_id,v_receipt.extension_receipt_digest,
       v_receipt.extension_reason_code,v_receipt.extension_reason_sha256,
       v_receipt.extension_reason_aad_digest
     )<>0
     OR v_receipt.receipt_canonical<>
       ops.canonical_jsonb_v1(v_receipt.receipt_payload)
     OR v_receipt.receipt_digest<>encode(extensions.digest(
       v_receipt.receipt_canonical,'sha256'
     ),'hex')
     OR v_receipt.event_receipt_id<>v_notification_event.id
     OR v_receipt.event_receipt_digest<>
       ops.r6d_outbox_envelope_digest_v1(v_notification_event.id)
     OR cardinality(v_receipt.outbox_event_ids)<>2
     OR NOT ops.uuid_array_is_sorted_unique(v_receipt.outbox_event_ids)
     OR NOT v_decision_event.id=ANY(v_receipt.outbox_event_ids)
     OR NOT v_notification_event.id=ANY(v_receipt.outbox_event_ids) THEN
    RAISE EXCEPTION 'REJECT transition receipt invalid';
  END IF;

  IF v_refusal.privacy_request_id<>v_request.id
     OR v_refusal.decision_version<>4
     OR v_refusal.rejection_reason_code<>'TEST_ONLY_REJECTION'
     OR v_refusal.rejection_reason_sha256<>
       v_receipt.rejection_reason_sha256
     OR v_refusal.appeal_instructions_sha256<>
       v_receipt.appeal_instructions_sha256
     OR v_refusal.decision_digest<>
       v_receipt.receipt_payload->>'decisionDigest'
     OR v_refusal.decision_at<>v_receipt.decided_at
     OR v_refusal.notice_due_at<>v_expected_notice_due_at
     OR v_refusal.notice_due_at<=v_refusal.decision_at
     OR v_refusal.notice_receipt_id<>v_notice.notice_receipt_id
     OR v_refusal.notice_receipt_digest<>v_notice.receipt_digest
     OR v_refusal.event_receipt_id<>v_notification_event.id
     OR v_refusal.event_receipt_digest<>v_receipt.event_receipt_digest
     OR v_refusal.receipt_canonical<>
       ops.canonical_jsonb_v1(v_refusal.receipt_payload)
     OR v_refusal.receipt_digest<>encode(extensions.digest(
       v_refusal.receipt_canonical,'sha256'
     ),'hex') THEN
    RAISE EXCEPTION 'REJECT refusal receipt invalid';
  END IF;

  IF v_notice.privacy_request_id<>v_request.id
     OR v_notice.notice_sequence<>3
     OR v_notice.notice_kind<>'REFUSAL'
     OR v_notice.transition_receipt_id<>v_receipt.transition_receipt_id
     OR v_notice.branch_receipt_id<>v_refusal.refusal_receipt_id
     OR v_notice.branch_receipt_digest<>v_refusal.receipt_digest
     OR v_notice.event_receipt_id<>v_notification_event.id
     OR v_notice.event_receipt_digest<>v_receipt.event_receipt_digest
     OR v_notice.notice_template_digest<>encode(extensions.digest(
       ops.canonical_jsonb_v1(v_notice.notice_template_payload),'sha256'
     ),'hex')
     OR v_notice.notice_sha256<>v_notice.notice_template_digest
     OR v_notice.receipt_canonical<>
       ops.canonical_jsonb_v1(v_notice.receipt_payload)
     OR v_notice.receipt_digest<>encode(extensions.digest(
       v_notice.receipt_canonical,'sha256'
     ),'hex') THEN
    RAISE EXCEPTION 'REJECT notice receipt invalid';
  END IF;

  IF v_decision_event.aggregate_version<>4
     OR v_decision_event.aggregate_id<>v_request.id::text
     OR (SELECT count(*) FROM jsonb_object_keys(
          v_decision_event.payload))<>9
     OR v_decision_event.payload->>'transition'<>'REJECT'
     OR v_decision_event.payload->>'priorState'<>'REVIEW'
     OR v_decision_event.payload->>'state'<>'REJECTED'
     OR v_decision_event.payload->'inventorySnapshotDigest'<>'null'::jsonb
     OR v_decision_event.payload->'holdCoverageDigest'<>'null'::jsonb
     OR v_decision_event.payload->>'decisionDigest'<>
       btrim(v_refusal.decision_digest)
     OR v_decision_event.payload->>'receiptDigest'<>
       btrim(v_receipt.receipt_digest) THEN
    RAISE EXCEPTION 'REJECT decision event invalid';
  END IF;

  IF v_notification_event.event_type<>
       'privacy.request_refusal_notified.v1'
     OR v_notification_event.aggregate_version<>4
     OR v_notification_event.aggregate_id<>v_request.id::text
     OR (SELECT count(*) FROM jsonb_object_keys(
          v_notification_event.payload))<>13
     OR v_notification_event.payload->>'requestType'<>'ACCESS'
     OR v_notification_event.payload->>'decisionDigest'<>
       btrim(v_refusal.decision_digest)
     OR v_notification_event.payload->>'reasonDigest'<>
       btrim(v_refusal.rejection_reason_sha256)
     OR v_notification_event.payload->>'appealInstructionsDigest'<>
       btrim(v_refusal.appeal_instructions_sha256)
     OR (v_notification_event.payload->>'decisionAt')::timestamptz<>
       v_refusal.decision_at
     OR (v_notification_event.payload->>'noticeDueAt')::timestamptz<>
       v_refusal.notice_due_at
     OR (v_notification_event.payload->>'notifiedAt')::timestamptz<>
       v_notice.created_at
     OR v_notification_event.payload->>'notificationReceiptDigest'<>
       btrim(v_notice.receipt_digest)
     OR (SELECT count(*) FROM ops.outbox AS event
         WHERE event.aggregate_type='privacy_request'
           AND event.aggregate_id=v_request.id::text
           AND event.aggregate_version=4)<>2 THEN
    RAISE EXCEPTION 'REJECT notification event invalid';
  END IF;

  IF (SELECT count(*) FROM ops.audit_events
      WHERE request_id=v_command.request_id
        AND action='command.transitionRetentionRequest'
        AND object_id=v_request.id::text
        AND outcome='SUCCESS')<>1
     OR (SELECT array_agg(content.field_kind ORDER BY content.field_kind)
         FROM ops.privacy_request_sealed_content_v2 AS content
         WHERE content.transition_receipt_id=v_receipt.transition_receipt_id)
       <>ARRAY['APPEAL_INSTRUCTIONS','REASON','REJECTION_REASON']::text[]
     OR NOT EXISTS(
       SELECT 1 FROM ops.privacy_request_sealed_content_v2 AS content
       WHERE content.transition_receipt_id=v_receipt.transition_receipt_id
         AND content.field_kind='REASON'
         AND content.sealed_ciphertext=
           pg_temp.r6d_transition_envelope_v1(v_command.reason_label)
         AND content.sealed_sha256=v_receipt.reason_sha256
         AND content.sealed_aad_digest=v_receipt.reason_aad_digest
     )
     OR NOT EXISTS(
       SELECT 1 FROM ops.privacy_request_sealed_content_v2 AS content
       WHERE content.transition_receipt_id=v_receipt.transition_receipt_id
         AND content.field_kind='REJECTION_REASON'
         AND content.sealed_ciphertext=
           pg_temp.r6d_transition_envelope_v1('reject_rejection_reason')
         AND content.sealed_sha256=v_receipt.rejection_reason_sha256
         AND content.sealed_aad_digest=
           v_receipt.rejection_reason_aad_digest
     )
     OR NOT EXISTS(
       SELECT 1 FROM ops.privacy_request_sealed_content_v2 AS content
       WHERE content.transition_receipt_id=v_receipt.transition_receipt_id
         AND content.field_kind='APPEAL_INSTRUCTIONS'
         AND content.sealed_ciphertext=
           pg_temp.r6d_transition_envelope_v1('reject_appeal_instructions')
         AND content.sealed_sha256=v_receipt.appeal_instructions_sha256
         AND content.sealed_aad_digest=
           v_receipt.appeal_instructions_aad_digest
     ) THEN
    RAISE EXCEPTION 'REJECT audit/sealed graph invalid';
  END IF;
END
$reject_positive$;

CREATE TEMP TABLE r6d_transition_probe_notification_events(
  label text PRIMARY KEY,
  event_id uuid NOT NULL UNIQUE
) ON COMMIT DROP;

INSERT INTO r6d_transition_probe_notification_events(label,event_id)
SELECT transition_label.label,receipt.event_receipt_id
FROM (VALUES
  ('identity','VERIFY_IDENTITY'),
  ('extend','EXTEND'),
  ('reject','REJECT')
) AS transition_label(label,transition)
JOIN ops.privacy_request_transition_receipts_v2 AS receipt
  ON receipt.privacy_request_id=
       pg_temp.r6d_transition_uuid_v1('main-request')
 AND receipt.transition=transition_label.transition;

DO $notification_event_fixture$
BEGIN
  IF (SELECT count(*)
      FROM r6d_transition_probe_notification_events)<>3 THEN
    RAISE EXCEPTION 'notification event fixture invalid';
  END IF;
END
$notification_event_fixture$;

GRANT SELECT ON r6d_transition_probe_notification_events
TO gurine_notification_worker;
GRANT EXECUTE ON FUNCTION
  pg_temp.r6d_transition_envelope_v1(text),
  pg_temp.r6d_transition_uuid_v1(text),
  pg_temp.r6d_transition_base64_v1(bytea)
TO gurine_notification_worker;

SET LOCAL ROLE gurine_notification_worker;
DO $notification_reader_positive$
DECLARE
  v_event record;
  v_binding jsonb;
  v_encoded text;
BEGIN
  FOR v_event IN
    SELECT * FROM r6d_transition_probe_notification_events ORDER BY label
  LOOP
    v_binding:=ops.read_privacy_request_notification_delivery_v1(
      v_event.event_id
    );
    IF v_binding IS NULL OR jsonb_typeof(v_binding)<>'object'
       OR (SELECT count(*) FROM jsonb_object_keys(v_binding))<>7
       OR (v_binding#>>'{event,eventId}')::uuid<>v_event.event_id
       OR (v_binding#>>'{request,retentionRequestId}')::uuid<>
         pg_temp.r6d_transition_uuid_v1('main-request')
       OR v_binding#>>'{endpoint,channel}'<>'SMTP_EMAIL'
       OR v_binding#>>'{endpoint,state}'<>'ACTIVE' THEN
      RAISE EXCEPTION 'notification reader base graph invalid: %',
        v_event.label;
    END IF;

    v_encoded:=v_binding#>>'{endpoint,endpointCiphertextBase64}';
    IF pg_temp.r6d_transition_base64_v1(decode(v_encoded,'base64'))<>
         v_encoded
       OR decode(v_encoded,'base64')<>
         pg_temp.r6d_transition_envelope_v1('main_endpoint') THEN
      RAISE EXCEPTION 'notification endpoint base64 invalid: %',
        v_event.label;
    END IF;

    CASE v_event.label
      WHEN 'identity' THEN
        IF v_binding->>'noticeType'<>'IDENTITY_VERIFIED'
           OR v_binding#>>'{event,eventType}'<>
             'privacy.request_identity_verified.v1'
           OR v_binding#>>'{template,kind}'<>'IDENTITY_VERIFIED'
           OR (SELECT count(*) FROM jsonb_object_keys(
                v_binding->'template'))<>6 THEN
          RAISE EXCEPTION 'identity notification ABI invalid';
        END IF;
        v_encoded:=v_binding#>>'{template,reasonCiphertextBase64}';
        IF pg_temp.r6d_transition_base64_v1(
             decode(v_encoded,'base64'))<>v_encoded
           OR decode(v_encoded,'base64')<>
             pg_temp.r6d_transition_envelope_v1('main_identity_reason') THEN
          RAISE EXCEPTION 'identity reason base64 invalid';
        END IF;

      WHEN 'extend' THEN
        IF v_binding->>'noticeType'<>'EXTENSION'
           OR v_binding#>>'{event,eventType}'<>
             'privacy.request_extension_notified.v1'
           OR v_binding#>>'{template,kind}'<>'EXTENSION'
           OR (SELECT count(*) FROM jsonb_object_keys(
                v_binding->'template'))<>13 THEN
          RAISE EXCEPTION 'extension notification ABI invalid';
        END IF;
        v_encoded:=v_binding#>>'{template,reasonCiphertextBase64}';
        IF pg_temp.r6d_transition_base64_v1(
             decode(v_encoded,'base64'))<>v_encoded
           OR decode(v_encoded,'base64')<>
             pg_temp.r6d_transition_envelope_v1('extend_reason') THEN
          RAISE EXCEPTION 'extension reason base64 invalid';
        END IF;
        v_encoded:=
          v_binding#>>'{template,extensionReasonCiphertextBase64}';
        IF pg_temp.r6d_transition_base64_v1(
             decode(v_encoded,'base64'))<>v_encoded
           OR decode(v_encoded,'base64')<>
             pg_temp.r6d_transition_envelope_v1(
               'extend_extension_reason'
             ) THEN
          RAISE EXCEPTION 'extension branch reason base64 invalid';
        END IF;

      WHEN 'reject' THEN
        IF v_binding->>'noticeType'<>'REFUSAL'
           OR v_binding#>>'{event,eventType}'<>
             'privacy.request_refusal_notified.v1'
           OR v_binding#>>'{template,kind}'<>'REFUSAL'
           OR (SELECT count(*) FROM jsonb_object_keys(
                v_binding->'template'))<>16 THEN
          RAISE EXCEPTION 'refusal notification ABI invalid';
        END IF;
        v_encoded:=v_binding#>>'{template,reasonCiphertextBase64}';
        IF pg_temp.r6d_transition_base64_v1(
             decode(v_encoded,'base64'))<>v_encoded
           OR decode(v_encoded,'base64')<>
             pg_temp.r6d_transition_envelope_v1('reject_reason') THEN
          RAISE EXCEPTION 'refusal reason base64 invalid';
        END IF;
        v_encoded:=
          v_binding#>>'{template,rejectionReasonCiphertextBase64}';
        IF pg_temp.r6d_transition_base64_v1(
             decode(v_encoded,'base64'))<>v_encoded
           OR decode(v_encoded,'base64')<>
             pg_temp.r6d_transition_envelope_v1(
               'reject_rejection_reason'
             ) THEN
          RAISE EXCEPTION 'rejection reason base64 invalid';
        END IF;
        v_encoded:=
          v_binding#>>'{template,appealInstructionsCiphertextBase64}';
        IF pg_temp.r6d_transition_base64_v1(
             decode(v_encoded,'base64'))<>v_encoded
           OR decode(v_encoded,'base64')<>
             pg_temp.r6d_transition_envelope_v1(
               'reject_appeal_instructions'
             ) THEN
          RAISE EXCEPTION 'appeal instructions base64 invalid';
        END IF;
      ELSE
        RAISE EXCEPTION 'unexpected notification fixture label';
    END CASE;
  END LOOP;
END
$notification_reader_positive$;
RESET ROLE;

SET LOCAL ROLE gurine_control_api;
DO $control_workspace_missing_inventory$
DECLARE
  v_before char(64):=pg_temp.r6d_transition_write_fingerprint_v1();
  v_sqlstate text;
  v_message text;
BEGIN
  BEGIN
    PERFORM ops.read_privacy_retention_request_workspace_v2(
      pg_temp.r6d_transition_uuid_v1('main-request')
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
      v_sqlstate=RETURNED_SQLSTATE,
      v_message=MESSAGE_TEXT;
  END;
  IF v_sqlstate IS DISTINCT FROM '55000'
     OR v_message IS DISTINCT FROM
       'r6d_privacy_hold_inventory_missing_or_ambiguous' THEN
    RAISE EXCEPTION 'Control workspace missing-inventory guard invalid: %/%',
      v_sqlstate,v_message;
  END IF;
  IF pg_temp.r6d_transition_write_fingerprint_v1()
       IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'Control workspace missing-inventory guard wrote state';
  END IF;
END
$control_workspace_missing_inventory$;
RESET ROLE;

DO $final_transition_graph$
DECLARE
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_identity ops.privacy_request_identity_receipts_v2%ROWTYPE;
  v_extension ops.privacy_request_extension_receipts_v2%ROWTYPE;
  v_refusal ops.privacy_request_refusal_receipts_v2%ROWTYPE;
  v_notice ops.privacy_request_notice_receipts_v2%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_request
  FROM ops.privacy_requests_v2
  WHERE id=pg_temp.r6d_transition_uuid_v1('main-request');
  SELECT * INTO STRICT v_identity
  FROM ops.privacy_request_identity_receipts_v2
  WHERE identity_receipt_id=v_request.current_identity_receipt_id;
  SELECT * INTO STRICT v_extension
  FROM ops.privacy_request_extension_receipts_v2
  WHERE extension_receipt_id=v_request.current_extension_receipt_id;
  SELECT * INTO STRICT v_refusal
  FROM ops.privacy_request_refusal_receipts_v2
  WHERE refusal_receipt_id=v_request.current_refusal_receipt_id;
  SELECT * INTO STRICT v_notice
  FROM ops.privacy_request_notice_receipts_v2
  WHERE notice_receipt_id=v_request.current_notice_receipt_id;

  IF v_request.decision_version<>4 OR v_request.state<>'REJECTED'
     OR v_request.due_at<>v_extension.due_at
     OR v_request.current_identity_receipt_digest<>v_identity.receipt_digest
     OR v_request.current_extension_receipt_digest<>v_extension.receipt_digest
     OR v_request.current_refusal_receipt_digest<>v_refusal.receipt_digest
     OR v_request.current_notice_receipt_digest<>v_notice.receipt_digest
     OR v_notice.notice_kind<>'REFUSAL' OR v_notice.notice_sequence<>3 THEN
    RAISE EXCEPTION 'final privacy root heads invalid';
  END IF;

  IF (SELECT count(*)
      FROM ops.privacy_request_transition_receipts_v2 AS receipt
      WHERE receipt.privacy_request_id=v_request.id)<>4
     OR (SELECT jsonb_agg(receipt.transition ORDER BY receipt.decision_version)
         FROM ops.privacy_request_transition_receipts_v2 AS receipt
         WHERE receipt.privacy_request_id=v_request.id)<>
       '["VERIFY_IDENTITY","START_REVIEW","EXTEND","REJECT"]'::jsonb
     OR EXISTS(
       SELECT 1
       FROM ops.privacy_request_transition_receipts_v2 AS receipt
       WHERE receipt.privacy_request_id=v_request.id
         AND (
           receipt.receipt_canonical<>
             ops.canonical_jsonb_v1(receipt.receipt_payload)
           OR receipt.receipt_digest<>encode(extensions.digest(
             receipt.receipt_canonical,'sha256'
           ),'hex')
           OR NOT ops.uuid_array_is_sorted_unique(receipt.outbox_event_ids)
           OR receipt.event_receipt_id<>ALL(receipt.outbox_event_ids)
           OR receipt.event_receipt_digest<>
             ops.r6d_outbox_envelope_digest_v1(receipt.event_receipt_id)
         )
     ) THEN
    RAISE EXCEPTION 'final transition receipt chain invalid';
  END IF;

  IF (SELECT count(*)
      FROM ops.privacy_request_notice_receipts_v2 AS receipt
      WHERE receipt.privacy_request_id=v_request.id)<>3
     OR (SELECT array_agg(receipt.notice_sequence
          ORDER BY receipt.notice_sequence)
         FROM ops.privacy_request_notice_receipts_v2 AS receipt
         WHERE receipt.privacy_request_id=v_request.id)<>
       ARRAY[1,2,3]::bigint[]
     OR (SELECT count(*)
         FROM ops.privacy_request_sealed_content_v2 AS content
         WHERE content.privacy_request_id=v_request.id)<>7
     OR (SELECT count(*)
         FROM (
           SELECT event_id
           FROM ops.privacy_request_transition_receipts_v2 AS receipt
           CROSS JOIN LATERAL unnest(receipt.outbox_event_ids)
             AS event_id
           WHERE receipt.privacy_request_id=v_request.id
         ) AS event_ids)<>5
     OR (SELECT count(DISTINCT event_id)
         FROM (
           SELECT event_id
           FROM ops.privacy_request_transition_receipts_v2 AS receipt
           CROSS JOIN LATERAL unnest(receipt.outbox_event_ids)
             AS event_id
           WHERE receipt.privacy_request_id=v_request.id
         ) AS event_ids)<>5 THEN
    RAISE EXCEPTION 'final child receipt/event cardinality invalid';
  END IF;

  IF (SELECT count(*)
      FROM ops.audit_events AS audit
      JOIN r6d_transition_probe_commands AS command
        ON command.request_id=audit.request_id
       AND command.label IN ('start','extend','reject')
      WHERE audit.action='command.transitionRetentionRequest'
        AND audit.object_id=v_request.id::text
        AND audit.outcome='SUCCESS')<>3 THEN
    RAISE EXCEPTION 'final transition success audit cardinality invalid';
  END IF;
END
$final_transition_graph$;

-- The frozen transition probe uses verified TEST_ONLY roots.  This separate
-- positive path proves the public receipt lifecycle without manufacturing a
-- VERIFY_IDENTITY success: create remains PENDING_VERIFICATION, exchange
-- creates a scoped read-only session, and get returns the honest next action.
CREATE TEMP TABLE r6d_privacy_positive_probe_result(
  request_id uuid PRIMARY KEY,
  created_event_id uuid NOT NULL,
  session_sha256 char(64) NOT NULL
) ON COMMIT DROP;
GRANT INSERT,SELECT ON r6d_privacy_positive_probe_result
  TO gurine_submission_api;
GRANT SELECT ON r6d_privacy_positive_probe_result
  TO gurine_notification_worker;

SET LOCAL ROLE gurine_submission_api;
DO $create_exchange_get_positive$
DECLARE
  v_label constant text:='runtime-positive';
  v_request_id uuid:=pg_temp.r6d_transition_uuid_v1(
    'create-'||v_label||'-request'
  );
  v_identity jsonb:=jsonb_build_object(
    'kind','RESPONSE_RECEIPT',
    'receiptId',pg_temp.r6d_transition_uuid_v1(
      'main-identity-proof'
    ),
    'possessionTokenHmac',pg_temp.r6d_transition_sha256_text_v1(
      'possession:main'
    )
  );
  v_scope jsonb:=jsonb_build_object(
    'scopeKind','ALL_VERIFIED_SUBJECT_DATA','objectRefs','[]'::jsonb,
    'dateFrom',NULL,'dateTo',NULL,
    'includeDerivatives',true,'includeBackups',false
  );
  v_session_sha256 char(64):=pg_temp.r6d_transition_sha256_text_v1(
    'create-session:'||v_label
  );
  v_create jsonb;
  v_exchange jsonb;
  v_read jsonb;
  v_created_event_id uuid;
BEGIN
  v_create:=ops.create_privacy_request_v2(
    pg_temp.r6d_transition_create_payload_v1(
      v_label,v_identity,v_scope
    )||jsonb_build_object(
      'communicationEndpointHmac',btrim(
        pg_temp.r6d_transition_sha256_text_v1('endpoint-hmac:main')
      )
    ),
    pg_temp.r6d_transition_uuid_v1('create-'||v_label||'-owner'),
    pg_temp.r6d_transition_sha256_text_v1(
      'create-'||v_label||'-idempotency'
    ),
    pg_temp.r6d_transition_sha256_text_v1(
      'create-'||v_label||'-request-digest'
    )
  );
  v_created_event_id:=(
    v_create#>>'{command,emittedEventIds,0}'
  )::uuid;
  IF (v_create->>'replayed')::boolean IS DISTINCT FROM false
     OR (v_create#>>'{request,privacyRequestId}')::uuid<>v_request_id
     OR v_create#>>'{request,state}'<>'RECEIVED'
     OR v_create#>>'{request,identityState}'<>'PENDING_VERIFICATION'
     OR v_create#>'{request,identityVerifiedAt}'<>'null'::jsonb
     OR v_create#>'{request,dueAt}'<>'null'::jsonb
     OR jsonb_array_length(v_create#>'{command,emittedEventIds}')
          IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'r6d privacy create positive result invalid';
  END IF;

  v_exchange:=ops.exchange_privacy_request_receipt_token_v2(
    pg_temp.r6d_transition_sha256_text_v1(
      'create-token-hmac:'||v_label
    ),
    v_session_sha256,'public-web',
    pg_temp.r6d_transition_uuid_v1('exchange-'||v_label||'-owner'),
    pg_temp.r6d_transition_sha256_text_v1(
      'exchange-'||v_label||'-idempotency'
    ),
    pg_temp.r6d_transition_sha256_text_v1(
      'exchange-'||v_label||'-request-digest'
    )
  );
  IF (v_exchange->>'replayed')::boolean IS DISTINCT FROM false
     OR (v_exchange->>'requestId')::uuid<>v_request_id
     OR v_exchange->>'cookieName'<>
       'gurine_privacy_request_receipt_session'
     OR jsonb_array_length(v_exchange->'emittedEventIds')
          IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'r6d privacy exchange positive result invalid';
  END IF;

  v_read:=ops.get_privacy_request_v2(v_session_sha256,'public-web');
  IF v_read->>'operationId'<>'getPrivacyRequest'
     OR (v_read#>>'{request,privacyRequestId}')::uuid<>v_request_id
     OR v_read#>>'{request,state}'<>'RECEIVED'
     OR v_read#>>'{request,identityState}'<>'PENDING_VERIFICATION'
     OR v_read->'nextActionCodes'<>
       jsonb_build_array('VERIFY_IDENTITY')
     OR v_read ? 'scope' OR v_read ? 'identityProof'
     OR v_read ? 'receiptToken'
     OR v_read#>'{request,scope}' IS NOT NULL
     OR v_read#>'{request,identityProof}' IS NOT NULL THEN
    RAISE EXCEPTION 'r6d privacy scoped get result invalid';
  END IF;

  INSERT INTO r6d_privacy_positive_probe_result(
    request_id,created_event_id,session_sha256
  ) VALUES(v_request_id,v_created_event_id,v_session_sha256);
END
$create_exchange_get_positive$;
RESET ROLE;

SET LOCAL ROLE gurine_notification_worker;
DO $created_notification_safe_reader$
DECLARE
  v_positive r6d_privacy_positive_probe_result%ROWTYPE;
  v_binding jsonb;
  v_ciphertext text;
  v_decoded bytea;
BEGIN
  SELECT * INTO STRICT v_positive
  FROM r6d_privacy_positive_probe_result;
  v_binding:=ops.read_privacy_request_notification_delivery_v1(
    v_positive.created_event_id
  );
  v_ciphertext:=v_binding#>>'{endpoint,endpointCiphertextBase64}';
  IF v_binding IS NULL
     OR v_binding->>'schemaVersion'<>
       'privacy-request-notification-delivery.v1'
     OR v_binding->>'noticeType'<>'IDENTITY_VERIFICATION_REQUIRED'
     OR (v_binding#>>'{event,eventId}')::uuid<>
       v_positive.created_event_id
     OR (v_binding#>>'{request,retentionRequestId}')::uuid<>
       v_positive.request_id
     OR v_binding#>>'{template,kind}'<>
       'IDENTITY_VERIFICATION_REQUIRED'
     OR v_ciphertext IS NULL
     OR v_ciphertext !~ '^[A-Za-z0-9+/]+={0,2}$'
     OR length(v_ciphertext)%4<>0 THEN
    RAISE EXCEPTION 'r6d privacy created notification binding invalid';
  END IF;
  BEGIN
    v_decoded:=decode(v_ciphertext,'base64');
  EXCEPTION WHEN invalid_parameter_value THEN
    RAISE EXCEPTION 'r6d privacy created notification base64 invalid';
  END;
  IF replace(encode(v_decoded,'base64'),E'\n','')<>v_ciphertext
     OR position('gurine-fe-v1.' IN convert_from(v_decoded,'UTF8'))<>1 THEN
    RAISE EXCEPTION 'r6d privacy created notification envelope invalid';
  END IF;
END
$created_notification_safe_reader$;
RESET ROLE;

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
\echo R6D_TRANSITION_SUCCESS_PROBE_PASS
SQL


# R6d PERSON retention stays rollback-only so the legacy R6b/R6c queue
# cardinality assertions below continue to measure only their own fixtures.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
BEGIN;
SET LOCAL session_replication_role=replica;

DO $retention_runtime_probe$
DECLARE
  v_person_schedule ops.record_class_schedules%ROWTYPE;
  v_topology_schedule ops.record_class_schedules%ROWTYPE;
  v_context_id uuid:=gen_random_uuid();
  v_node_id uuid:=gen_random_uuid();
  v_topology jsonb:=jsonb_build_object('schemaVersion','r6d-retention-probe.v1');
  v_topology_canonical bytea;
  v_topology_digest char(64);
  v_name_digest char(64):=repeat('a',64);
  v_cipher_digest char(64):=repeat('b',64);
  v_role_digest char(64):=repeat('c',64);
  v_source_digest char(64):=repeat('d',64);
  v_identifier_digest char(64):=repeat('e',64);
  v_first jsonb;
  v_second jsonb;
  v_job ops.jobs%ROWTYPE;
  v_lease uuid:=gen_random_uuid();
  v_result jsonb;
  v_receipt ops.r6d_person_retention_execution_receipts_v1%ROWTYPE;
  v_stale_rejected boolean:=false;
  v_immutable_rejected boolean:=false;
  v_entity_executor_count integer;
BEGIN
  SELECT * INTO STRICT v_person_schedule
  FROM ops.record_class_schedules
  WHERE record_class='RELATIONSHIP_PERSON_CONTEXT';
  SELECT * INTO STRICT v_topology_schedule
  FROM ops.record_class_schedules
  WHERE record_class='RELATIONSHIP_PERSON_TOPOLOGY';

  v_topology_canonical:=ops.canonical_jsonb_v1(v_topology);
  v_topology_digest:=encode(extensions.digest(v_topology_canonical,'sha256'),'hex');
  INSERT INTO core.relationship_graph_person_nodes_v3(
    person_node_id,source_locator,source_locator_digest,identifier_digest,
    topology_payload,topology_canonical,topology_digest,created_actor_type,
    created_actor_id,created_by,retention_schedule_id,retention_record_class,
    retention_schedule_digest,created_at
  ) VALUES (
    v_node_id,'test-only://retention-probe',v_source_digest,v_identifier_digest,
    v_topology,v_topology_canonical,v_topology_digest,'SERVICE','ingest-worker',NULL,
    v_topology_schedule.id,'RELATIONSHIP_PERSON_TOPOLOGY',
    v_topology_schedule.schedule_digest,clock_timestamp()-interval '2 days'
  );
  INSERT INTO core.relationship_graph_person_context_v3(
    context_id,person_node_id,topology_digest,contextual_name_ciphertext,
    contextual_name_sha256,contextual_name_aad_digest,role_title_ciphertext,
    role_title_sha256,role_title_aad_digest,encryption_key_id,person_name_digest,
    verification_status,public_use_status,erase_state,retention_schedule_id,
    retention_record_class,retention_schedule_digest,created_at
  ) VALUES (
    v_context_id,v_node_id,v_topology_digest,'x'::bytea,v_cipher_digest,
    encode(extensions.digest(convert_to(
      'core.relationship_graph_person_context_v3/'||v_context_id::text||
      '/contextual_name/v1','UTF8'),'sha256'),'hex'),
    'y'::bytea,v_role_digest,
    encode(extensions.digest(convert_to(
      'core.relationship_graph_person_context_v3/'||v_context_id::text||
      '/role_title/v1','UTF8'),'sha256'),'hex'),
    'test-key',v_name_digest,'PENDING_HUMAN','NOT_REVIEWED','ACTIVE',
    v_person_schedule.id,'RELATIONSHIP_PERSON_CONTEXT',
    v_person_schedule.schedule_digest,
    clock_timestamp()-make_interval(secs=>v_person_schedule.active_duration_seconds+1)
  );

  -- Only the disposable parent seed bypasses FK/insert binding.  All owner
  -- calls, update guards, and immutable-receipt checks below run normally.
  PERFORM set_config('session_replication_role','origin',true);

  v_first:=ops.enqueue_due_r6d_person_retention_jobs_v1(10);
  v_second:=ops.enqueue_due_r6d_person_retention_jobs_v1(10);
  IF (v_first->>'enqueuedCount')::integer<>1
     OR (v_second->>'enqueuedCount')::integer<>0 THEN
    RAISE EXCEPTION 'r6d_retention_probe_enqueue_dedupe_invalid:%/%',v_first,v_second;
  END IF;
  SELECT * INTO STRICT v_job FROM ops.jobs
  WHERE job_type='R6D_PERSON_RETENTION'
    AND payload->>'contextId'=v_context_id::text;

  -- Expired/reclaimed fence: the old lease must be rejected before any erasure.
  UPDATE ops.jobs SET status='RUNNING',lease_owner='retention-worker',
    lease_token=v_lease,lease_expires_at=clock_timestamp()-interval '1 second',
    fencing_token=1
  WHERE id=v_job.id;
  BEGIN
    PERFORM ops.execute_due_r6d_person_retention_job_v1(v_job.id,v_lease,1);
  EXCEPTION WHEN sqlstate '40001' THEN v_stale_rejected:=true;
  END;
  IF NOT v_stale_rejected OR EXISTS (
    SELECT 1 FROM core.relationship_graph_person_erasure_receipts_v3
    WHERE context_id=v_context_id
  ) THEN
    RAISE EXCEPTION 'r6d_retention_probe_stale_lease_not_fail_closed';
  END IF;

  -- Reclaim with a higher fence, execute once, and require exact replay.
  v_lease:=gen_random_uuid();
  UPDATE ops.jobs SET status='RUNNING',lease_owner='retention-worker',
    lease_token=v_lease,lease_expires_at=clock_timestamp()+interval '5 minutes',
    fencing_token=2
  WHERE id=v_job.id;
  v_result:=ops.execute_due_r6d_person_retention_job_v1(v_job.id,v_lease,2);
  IF (v_result->>'replayed')::boolean THEN
    RAISE EXCEPTION 'r6d_retention_probe_first_execute_replayed';
  END IF;
  SELECT * INTO STRICT v_receipt
  FROM ops.r6d_person_retention_execution_receipts_v1 WHERE job_id=v_job.id;
  SELECT * INTO STRICT v_job FROM ops.jobs WHERE id=v_job.id;
  IF NOT EXISTS (
    SELECT 1
    FROM core.relationship_graph_person_context_v3 AS context
    JOIN core.relationship_graph_person_erasure_receipts_v3 AS erasure
      ON erasure.context_id=context.context_id
    WHERE context.context_id=v_context_id
      AND context.person_node_id=v_node_id
      AND context.topology_digest=v_topology_digest
      AND context.person_name_digest=v_name_digest
      AND context.erase_state='ANONYMIZED'
      AND context.contextual_name_ciphertext IS NULL
      AND context.contextual_name_sha256 IS NULL
      AND context.contextual_name_aad_digest IS NULL
      AND context.role_title_ciphertext IS NULL
      AND context.role_title_sha256 IS NULL
      AND context.role_title_aad_digest IS NULL
      AND context.encryption_key_id IS NULL
      AND context.erased_at IS NOT NULL
      AND context.erasure_receipt_digest=erasure.receipt_digest
      AND erasure.erasure_kind='ANONYMIZE'
      AND erasure.actor_type='SERVICE'
      AND erasure.actor_id='retention-worker'
      AND (v_result->>'erasureReceiptId')::uuid=erasure.receipt_id
      AND v_result->>'erasureReceiptDigest'=btrim(erasure.receipt_digest)
  ) THEN
    RAISE EXCEPTION 'r6d_retention_probe_person_anonymization_invalid';
  END IF;
  IF v_job.status<>'RUNNING' OR v_job.completed_at IS NOT NULL
     OR v_job.lease_owner IS DISTINCT FROM 'retention-worker'
     OR v_job.lease_token IS DISTINCT FROM v_lease
     OR v_job.lease_expires_at IS NULL
     OR v_job.lease_expires_at<=clock_timestamp() OR v_job.fencing_token<>2
     OR v_receipt.job_fencing_token<>2 THEN
    RAISE EXCEPTION 'r6d_retention_probe_live_claim_fence_invalid';
  END IF;
  IF NOT (ops.execute_due_r6d_person_retention_job_v1(v_job.id,v_lease,2)->>'replayed')::boolean THEN
    RAISE EXCEPTION 'r6d_retention_probe_exact_replay_missing';
  END IF;
  BEGIN
    UPDATE ops.r6d_person_retention_execution_receipts_v1
    SET completed_at=completed_at+interval '1 second' WHERE receipt_id=v_receipt.receipt_id;
  EXCEPTION WHEN sqlstate '55000' THEN v_immutable_rejected:=true;
  END;
  IF NOT v_immutable_rejected THEN
    RAISE EXCEPTION 'r6d_retention_probe_receipt_not_immutable';
  END IF;

  -- PERSON and classified entity masters have distinct exact owners.  The
  -- scheduler may enqueue each kind, while only the workflow worker may
  -- execute either terminal mutation.
  SELECT count(*) INTO v_entity_executor_count
  FROM pg_proc AS proc JOIN pg_namespace AS ns ON ns.oid=proc.pronamespace
  WHERE ns.nspname='ops' AND proc.proname ~ '^execute_due_r6d_(agency|supplier|entity)_retention';
  IF v_entity_executor_count<>1
     OR has_function_privilege('gurine_workflow_worker',
       'ops.enqueue_due_r6d_person_retention_jobs_v1(integer)','EXECUTE')
     OR NOT has_function_privilege('gurine_scheduler',
       'ops.enqueue_due_r6d_person_retention_jobs_v1(integer)','EXECUTE')
     OR NOT has_function_privilege('gurine_workflow_worker',
       'ops.execute_due_r6d_person_retention_job_v1(uuid,uuid,bigint)','EXECUTE')
     OR has_function_privilege('gurine_scheduler',
       'ops.execute_due_r6d_person_retention_job_v1(uuid,uuid,bigint)','EXECUTE')
     OR has_function_privilege('gurine_workflow_worker',
       'ops.enqueue_due_r6d_entity_retention_jobs_v1(integer)','EXECUTE')
     OR NOT has_function_privilege('gurine_scheduler',
       'ops.enqueue_due_r6d_entity_retention_jobs_v1(integer)','EXECUTE')
     OR NOT has_function_privilege('gurine_workflow_worker',
       'ops.execute_due_r6d_entity_retention_job_v1(uuid,uuid,bigint)',
       'EXECUTE')
     OR has_function_privilege('gurine_scheduler',
       'ops.execute_due_r6d_entity_retention_job_v1(uuid,uuid,bigint)',
       'EXECUTE')
     OR has_function_privilege('gurine_public_projector',
       'ops.enqueue_due_r6d_entity_retention_jobs_v1(integer)','EXECUTE')
     OR has_function_privilege('gurine_public_projector',
       'ops.execute_due_r6d_entity_retention_job_v1(uuid,uuid,bigint)',
       'EXECUTE') THEN
    RAISE EXCEPTION 'r6d_retention_probe_executor_boundary_or_grant_invalid';
  END IF;
END
$retention_runtime_probe$;
ROLLBACK;
SQL

# TEST_FIXTURE_ONLY classified entity authority.  This is a committed runtime
# path because the three production binaries below must observe the same rows:
# scheduler -> workflow terminal owner -> public projection consumer.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" < db/test-fixtures/r6d-entity-projection-runtime-seed.sql \
  >/dev/null

postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
r6d_entity_test_key="$(printf '%s' '01234567890123456789012345678901' | base64 -w0)"

r6d_entity_domain_fingerprint() {
  docker exec "$container" psql -At -v ON_ERROR_STOP=1 -U postgres \
    -d "$database" -c "
      SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
        jsonb_build_object(
          'agency',(SELECT to_jsonb(row_value) FROM core.agencies AS row_value
            WHERE id='31600000-0000-4000-8000-000000000001'),
          'supplier',(SELECT to_jsonb(row_value) FROM core.suppliers AS row_value
            WHERE id='31600000-0000-4000-8000-000000000002'),
          'agencyIdentifiers',COALESCE((SELECT jsonb_agg(to_jsonb(row_value)
            ORDER BY id) FROM core.agency_identifiers AS row_value
            WHERE agency_id='31600000-0000-4000-8000-000000000001'),'[]'),
          'supplierIdentifiers',COALESCE((SELECT jsonb_agg(to_jsonb(row_value)
            ORDER BY id) FROM core.supplier_identifiers AS row_value
            WHERE supplier_id='31600000-0000-4000-8000-000000000002'),'[]'),
          'aliases',COALESCE((SELECT jsonb_agg(to_jsonb(row_value) ORDER BY id)
            FROM core.entity_aliases AS row_value
            WHERE (entity_type,entity_id) IN (
              ('AGENCY','31600000-0000-4000-8000-000000000001'::uuid),
              ('SUPPLIER','31600000-0000-4000-8000-000000000002'::uuid)
            )),'[]'),
          'publicAgency',(SELECT to_jsonb(row_value) FROM public.agencies AS row_value
            WHERE id='31600000-0000-4000-8000-000000000001'),
          'publicSupplier',(SELECT to_jsonb(row_value) FROM public.suppliers AS row_value
            WHERE id='31600000-0000-4000-8000-000000000002'),
          'executionReceipts',COALESCE((SELECT jsonb_agg(to_jsonb(row_value)
            ORDER BY execution_receipt_id)
            FROM ops.r6d_entity_retention_execution_receipts_v1 AS row_value
            WHERE entity_id IN (
              '31600000-0000-4000-8000-000000000001',
              '31600000-0000-4000-8000-000000000002'
            )),'[]')
        )),'sha256'),'hex')"
}

r6d_projection_result_fingerprint() {
  docker exec "$container" psql -At -v ON_ERROR_STOP=1 -U postgres \
    -d "$database" -c "
      SELECT encode(extensions.digest(convert_to(string_agg(
        inbox.event_id::text||':'||inbox.result,E'\\n'
        ORDER BY inbox.event_id),'UTF8'),'sha256'),'hex')
      FROM ops.inbox AS inbox
      JOIN ops.outbox AS event ON event.id=inbox.event_id
      WHERE inbox.consumer='public-projection-worker'
        AND event.event_type='entity.retention_anonymized.v1'"
}

SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_INSTANCE_ID="r6d-entity-retention-test" SCHEDULER_ONCE=true \
  target/debug/gurine-scheduler

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $r6d_entity_queued$
BEGIN
  IF (SELECT count(*) FROM ops.jobs
      WHERE job_type='R6D_ENTITY_RETENTION' AND queue='workflow-worker'
        AND status='QUEUED')<>2
     OR (SELECT count(DISTINCT payload->>'entityKind') FROM ops.jobs
         WHERE job_type='R6D_ENTITY_RETENTION')<>2
     OR NOT has_function_privilege('gurine_scheduler',
       'ops.enqueue_due_r6d_entity_retention_jobs_v1(integer)','EXECUTE')
     OR has_function_privilege('gurine_workflow_worker',
       'ops.enqueue_due_r6d_entity_retention_jobs_v1(integer)','EXECUTE')
     OR NOT has_function_privilege('gurine_workflow_worker',
       'ops.execute_due_r6d_entity_retention_job_v1(uuid,uuid,bigint)',
       'EXECUTE')
     OR has_function_privilege('gurine_scheduler',
       'ops.execute_due_r6d_entity_retention_job_v1(uuid,uuid,bigint)',
       'EXECUTE')
     OR has_function_privilege('gurine_public_projector',
       'ops.execute_due_r6d_entity_retention_job_v1(uuid,uuid,bigint)',
       'EXECUTE')
     OR NOT has_column_privilege('gurine_public_projector',
       'ops.r6d_entity_retention_execution_receipts_v1',
       'execution_receipt_digest','SELECT')
     OR has_column_privilege('gurine_public_projector',
       'ops.r6d_entity_retention_execution_receipts_v1',
       'receipt_payload','SELECT') THEN
    RAISE EXCEPTION 'r6d_entity_retention_queue_or_acl_invalid';
  END IF;
END
$r6d_entity_queued$;
SQL

GURINE_ENV=test \
WORKFLOW_DATABASE_URL="postgresql://gurine_workflow_worker:workflow_test@127.0.0.1:${postgres_port}/${database}" \
FIELD_ENCRYPTION_KEY_CURRENT="$r6d_entity_test_key" \
OBJECT_STORE_ADAPTER=filesystem OBJECT_STORE_FILESYSTEM_ROOT="$work" \
CLAMAV_HOST=127.0.0.1 CLAMAV_PORT=3310 WORKFLOW_ONCE=true \
HOSTNAME="r6d-entity-retention-workflow-test" target/debug/gurine-workflow-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $r6d_entity_executed$
BEGIN
  IF (SELECT count(*) FROM ops.jobs
      WHERE job_type='R6D_ENTITY_RETENTION' AND status='SUCCEEDED')<>2
     OR (SELECT count(*)
         FROM ops.r6d_entity_retention_execution_receipts_v1
         WHERE entity_id IN (
           '31600000-0000-4000-8000-000000000001',
           '31600000-0000-4000-8000-000000000002'
         ))<>2
     OR NOT EXISTS(
       SELECT 1 FROM core.agencies
       WHERE id='31600000-0000-4000-8000-000000000001'
         AND canonical_name IS NULL AND jurisdiction IS NULL
         AND r6d_anonymization_state='ANONYMIZED'
         AND r6d_canonical_name_digest IS NOT NULL
         AND r6d_jurisdiction_digest IS NOT NULL
     )
     OR NOT EXISTS(
       SELECT 1 FROM core.suppliers
       WHERE id='31600000-0000-4000-8000-000000000002'
         AND canonical_name IS NULL
         AND r6d_anonymization_state='ANONYMIZED'
         AND r6d_canonical_name_digest IS NOT NULL
     )
     OR NOT EXISTS(
       SELECT 1 FROM core.agency_identifiers
       WHERE agency_id='31600000-0000-4000-8000-000000000001'
         AND value IS NULL AND r6d_value_digest IS NOT NULL
         AND r6d_anonymization_state='ANONYMIZED'
     )
     OR NOT EXISTS(
       SELECT 1 FROM core.supplier_identifiers
       WHERE supplier_id='31600000-0000-4000-8000-000000000002'
         AND display_value IS NULL AND value_hash IS NOT NULL
         AND r6d_display_value_digest IS NOT NULL
         AND r6d_anonymization_state='ANONYMIZED'
     )
     OR (SELECT count(*) FROM core.entity_aliases
         WHERE alias IS NULL AND normalized_alias IS NULL
           AND r6d_alias_digest IS NOT NULL
           AND r6d_normalized_alias_digest IS NOT NULL
           AND r6d_anonymization_state='ANONYMIZED'
           AND (entity_type,entity_id) IN (
             ('AGENCY','31600000-0000-4000-8000-000000000001'::uuid),
             ('SUPPLIER','31600000-0000-4000-8000-000000000002'::uuid)
           ))<>2
     OR EXISTS(
       SELECT 1 FROM public.agencies
       WHERE id='31600000-0000-4000-8000-000000000001'
         AND (name IS NOT NULL OR jurisdiction IS NOT NULL)
     )
     OR EXISTS(
       SELECT 1 FROM public.suppliers
       WHERE id='31600000-0000-4000-8000-000000000002'
         AND name IS NOT NULL
     ) THEN
    RAISE EXCEPTION 'r6d_entity_retention_execution_invalid';
  END IF;
END
$r6d_entity_executed$;
SQL

r6d_projection_domain_before="$(r6d_entity_domain_fingerprint)"
SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_INSTANCE_ID="r6d-entity-projection-dispatch-test" SCHEDULER_ONCE=true \
  target/debug/gurine-scheduler

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $r6d_projection_queued$
BEGIN
  IF (SELECT count(*) FROM ops.jobs AS job
      WHERE job.queue='projection-worker' AND job.job_type='EVENT_DELIVERY'
        AND job.status='QUEUED'
        AND job.payload->>'consumerId'='public-projection-worker'
        AND job.payload->>'eventType'='entity.retention_anonymized.v1')<>2
     OR (SELECT count(*) FROM ops.inbox AS inbox
         JOIN ops.outbox AS event ON event.id=inbox.event_id
         WHERE inbox.consumer='public-projection-worker'
           AND inbox.processed_at IS NULL
           AND event.event_type='entity.retention_anonymized.v1')<>2 THEN
    RAISE EXCEPTION 'r6d_entity_projection_delivery_invalid';
  END IF;
END
$r6d_projection_queued$;
SQL

PROJECTOR_DATABASE_URL="postgresql://gurine_public_projector:projector_test@127.0.0.1:${postgres_port}/${database}" \
PROJECTOR_ONCE=true HOSTNAME="r6d-entity-projection-test" \
  target/debug/gurine-projection-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $r6d_projection_fresh$
BEGIN
  IF (SELECT count(*) FROM ops.inbox AS inbox
      JOIN ops.outbox AS event ON event.id=inbox.event_id
      WHERE inbox.consumer='public-projection-worker'
        AND event.event_type='entity.retention_anonymized.v1'
        AND inbox.processed_at IS NOT NULL
        AND inbox.result IS NOT NULL
        AND (SELECT count(*) FROM jsonb_object_keys(inbox.result::jsonb))=8
        AND inbox.result::jsonb->>'consumerId'='public-projection-worker'
        AND inbox.result::jsonb->>'eventId'=inbox.event_id::text
        AND inbox.result::jsonb->>'eventType'=
          'entity.retention_anonymized.v1'
        AND inbox.result::jsonb->>'outcome'=
          'PUBLIC_PLAINTEXT_ANONYMIZED'
        AND (inbox.result::jsonb->>'projectionRowChanged')::boolean=false
      )<>2
     OR (SELECT count(*) FROM ops.jobs AS job
         JOIN ops.job_attempts AS attempt ON attempt.job_id=job.id
         JOIN ops.inbox AS inbox
           ON inbox.event_id=(job.payload->>'eventId')::uuid
          AND inbox.consumer='public-projection-worker'
         WHERE job.queue='projection-worker' AND job.status='SUCCEEDED'
           AND job.payload->>'eventType'='entity.retention_anonymized.v1'
           AND attempt.outcome='SUCCEEDED'
           AND attempt.metrics=inbox.result::jsonb)<>2 THEN
    RAISE EXCEPTION 'r6d_entity_projection_fresh_result_invalid';
  END IF;
END
$r6d_projection_fresh$;
SQL

r6d_projection_domain_after="$(r6d_entity_domain_fingerprint)"
if [[ "$r6d_projection_domain_before" != "$r6d_projection_domain_after" ]]; then
  echo "R6d fresh entity projection changed already-anonymized domain rows" >&2
  exit 1
fi
r6d_projection_result_before="$(r6d_projection_result_fingerprint)"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.jobs(
  id,job_type,queue,priority,payload,dedupe_key,max_attempts
)
SELECT CASE job.payload#>>'{payload,entityKind}'
         WHEN 'AGENCY' THEN '31600000-0000-4000-8000-000000000201'::uuid
         ELSE '31600000-0000-4000-8000-000000000202'::uuid
       END,
       'EVENT_DELIVERY','projection-worker',1,job.payload,
       'r6d-entity-projection-exact-replay:'||(job.payload->>'eventId'),1
FROM ops.jobs AS job
WHERE job.queue='projection-worker' AND job.status='SUCCEEDED'
  AND job.payload->>'consumerId'='public-projection-worker'
  AND job.payload->>'eventType'='entity.retention_anonymized.v1';
SQL

PROJECTOR_DATABASE_URL="postgresql://gurine_public_projector:projector_test@127.0.0.1:${postgres_port}/${database}" \
PROJECTOR_ONCE=true HOSTNAME="r6d-entity-projection-replay-test" \
  target/debug/gurine-projection-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $r6d_projection_replay$
BEGIN
  IF (SELECT count(*) FROM ops.jobs AS job
      JOIN ops.job_attempts AS attempt ON attempt.job_id=job.id
      JOIN ops.inbox AS inbox
        ON inbox.event_id=(job.payload->>'eventId')::uuid
       AND inbox.consumer='public-projection-worker'
      WHERE job.id IN (
        '31600000-0000-4000-8000-000000000201',
        '31600000-0000-4000-8000-000000000202'
      ) AND job.status='SUCCEEDED' AND attempt.outcome='SUCCEEDED'
        AND attempt.metrics=inbox.result::jsonb)<>2 THEN
    RAISE EXCEPTION 'r6d_entity_projection_exact_replay_invalid';
  END IF;
END
$r6d_projection_replay$;
SQL

r6d_projection_result_after="$(r6d_projection_result_fingerprint)"
r6d_projection_domain_replay="$(r6d_entity_domain_fingerprint)"
if [[ "$r6d_projection_result_before" != "$r6d_projection_result_after" \
   || "$r6d_projection_domain_after" != "$r6d_projection_domain_replay" ]]; then
  echo "R6d exact entity projection replay changed durable result/domain rows" >&2
  exit 1
fi

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.jobs(
  id,job_type,queue,priority,payload,dedupe_key,max_attempts
)
SELECT CASE job.payload#>>'{payload,entityKind}'
         WHEN 'AGENCY' THEN '31600000-0000-4000-8000-000000000211'::uuid
         ELSE '31600000-0000-4000-8000-000000000212'::uuid
       END,
       'EVENT_DELIVERY','projection-worker',1,
       CASE job.payload#>>'{payload,entityKind}'
         WHEN 'AGENCY' THEN jsonb_set(
           job.payload,'{occurredAt}',to_jsonb('2099-01-01T00:00:00Z'::text)
         )
         ELSE jsonb_set(
           job.payload,'{payload,executionReceiptDigest}',
           to_jsonb(repeat('0',64))
         )
       END,
       'r6d-entity-projection-tamper:'||(job.payload->>'eventId'),1
FROM ops.jobs AS job
WHERE job.id IN (
  '31600000-0000-4000-8000-000000000201',
  '31600000-0000-4000-8000-000000000202'
);
SQL

PROJECTOR_DATABASE_URL="postgresql://gurine_public_projector:projector_test@127.0.0.1:${postgres_port}/${database}" \
PROJECTOR_ONCE=true HOSTNAME="r6d-entity-projection-tamper-test" \
  target/debug/gurine-projection-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $r6d_projection_tamper$
DECLARE
  v_agency_restore boolean:=false;
  v_agency_delete boolean:=false;
  v_agency_identity boolean:=false;
  v_supplier_restore boolean:=false;
  v_supplier_delete boolean:=false;
  v_supplier_identity boolean:=false;
  v_receipt_update boolean:=false;
  v_receipt_delete boolean:=false;
BEGIN
  IF (SELECT count(*) FROM ops.jobs AS job
      JOIN ops.job_attempts AS attempt ON attempt.job_id=job.id
      WHERE job.id IN (
        '31600000-0000-4000-8000-000000000211',
        '31600000-0000-4000-8000-000000000212'
      ) AND job.status='DEAD_LETTER'
        AND job.last_error_code='EVENT_REPLAY_CONFLICT'
        AND attempt.outcome='DEAD_LETTER'
        AND attempt.error_code='EVENT_REPLAY_CONFLICT')<>2 THEN
    RAISE EXCEPTION 'r6d_entity_projection_tamper_not_fail_closed';
  END IF;

  BEGIN
    UPDATE public.agencies SET name='restore',jurisdiction='restore'
    WHERE id='31600000-0000-4000-8000-000000000001';
  EXCEPTION WHEN sqlstate '42501' THEN
    v_agency_restore:=SQLERRM='r6d_public_entity_plaintext_restore_forbidden';
  END;
  BEGIN
    DELETE FROM public.agencies
    WHERE id='31600000-0000-4000-8000-000000000001';
  EXCEPTION WHEN sqlstate '42501' THEN
    v_agency_delete:=SQLERRM='r6d_public_entity_delete_forbidden';
  END;
  BEGIN
    UPDATE public.agencies
    SET id='31600000-0000-4000-8000-000000000099'
    WHERE id='31600000-0000-4000-8000-000000000001';
  EXCEPTION WHEN sqlstate '42501' THEN
    v_agency_identity:=
      SQLERRM='r6d_public_entity_identity_mutation_forbidden';
  END;
  BEGIN
    UPDATE public.suppliers SET name='restore'
    WHERE id='31600000-0000-4000-8000-000000000002';
  EXCEPTION WHEN sqlstate '42501' THEN
    v_supplier_restore:=SQLERRM='r6d_public_entity_plaintext_restore_forbidden';
  END;
  BEGIN
    DELETE FROM public.suppliers
    WHERE id='31600000-0000-4000-8000-000000000002';
  EXCEPTION WHEN sqlstate '42501' THEN
    v_supplier_delete:=SQLERRM='r6d_public_entity_delete_forbidden';
  END;
  BEGIN
    UPDATE public.suppliers
    SET id='31600000-0000-4000-8000-000000000098'
    WHERE id='31600000-0000-4000-8000-000000000002';
  EXCEPTION WHEN sqlstate '42501' THEN
    v_supplier_identity:=
      SQLERRM='r6d_public_entity_identity_mutation_forbidden';
  END;
  BEGIN
    UPDATE ops.r6d_entity_retention_execution_receipts_v1
    SET created_at=created_at+interval '1 second'
    WHERE entity_kind='AGENCY'
      AND entity_id='31600000-0000-4000-8000-000000000001';
  EXCEPTION WHEN sqlstate '55000' THEN
    v_receipt_update:=SQLERRM='immutable_record';
  END;
  BEGIN
    DELETE FROM ops.r6d_entity_retention_execution_receipts_v1
    WHERE entity_kind='SUPPLIER'
      AND entity_id='31600000-0000-4000-8000-000000000002';
  EXCEPTION WHEN sqlstate '55000' THEN
    v_receipt_delete:=SQLERRM='immutable_record';
  END;
  IF NOT (v_agency_restore AND v_agency_delete AND v_agency_identity
          AND v_supplier_restore AND v_supplier_delete
          AND v_supplier_identity AND v_receipt_update
          AND v_receipt_delete)
     OR EXISTS(
       SELECT 1 FROM public.agencies
       WHERE id='31600000-0000-4000-8000-000000000001'
         AND (name IS NOT NULL OR jurisdiction IS NOT NULL)
     )
     OR EXISTS(
       SELECT 1 FROM public.suppliers
       WHERE id='31600000-0000-4000-8000-000000000002'
         AND name IS NOT NULL
     )
     OR (SELECT count(*)
         FROM ops.r6d_entity_retention_execution_receipts_v1
         WHERE entity_id IN (
           '31600000-0000-4000-8000-000000000001',
           '31600000-0000-4000-8000-000000000002'
         ))<>2 THEN
    RAISE EXCEPTION 'r6d_entity_projection_immutability_invalid';
  END IF;
END
$r6d_projection_tamper$;
SQL

r6d_projection_result_tampered="$(r6d_projection_result_fingerprint)"
r6d_projection_domain_tampered="$(r6d_entity_domain_fingerprint)"
if [[ "$r6d_projection_result_before" != "$r6d_projection_result_tampered" \
   || "$r6d_projection_domain_after" != "$r6d_projection_domain_tampered" ]]; then
  echo "R6d tampered entity projection changed durable result/domain rows" >&2
  exit 1
fi
echo "R6D_ENTITY_PROJECTION_RUNTIME_PASS"


docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
BEGIN;
CREATE TEMP TABLE r6b_identity_counts_before AS
SELECT
  (SELECT count(*) FROM core.supplier_identity_candidates) AS candidates,
  (SELECT count(*) FROM core.supplier_identity_resolution_decisions) AS decisions,
  (SELECT count(*) FROM core.supplier_identity_resolution_decision_members)
    AS decision_members,
  (SELECT count(*) FROM core.supplier_identifiers) AS identifiers,
  (SELECT count(*) FROM core.suppliers) AS suppliers;

SET LOCAL ROLE gurine_ingest_worker;
DO $$
DECLARE request_denied boolean := false;
BEGIN
  BEGIN
    PERFORM * FROM core.record_supplier_identity_candidate_v1(
      jsonb_build_object('testCase','malformed proposal request')
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    request_denied := SQLERRM='supplier_candidate_request_invalid';
  END;
  IF NOT request_denied THEN
    RAISE EXCEPTION
      'identity candidate malformed request did not fail closed';
  END IF;
END $$;
RESET ROLE;

DO $$
DECLARE before_counts record;
BEGIN
  SELECT * INTO before_counts FROM r6b_identity_counts_before;
  IF (SELECT count(*) FROM core.supplier_identity_candidates)
       <> before_counts.candidates
     OR (SELECT count(*) FROM core.supplier_identity_resolution_decisions)
       <> before_counts.decisions
     OR (SELECT count(*) FROM core.supplier_identity_resolution_decision_members)
       <> before_counts.decision_members
     OR (SELECT count(*) FROM core.supplier_identifiers)
       <> before_counts.identifiers
     OR (SELECT count(*) FROM core.suppliers) <> before_counts.suppliers THEN
    RAISE EXCEPTION 'mapping-authority denial created identity side effects';
  END IF;
END $$;
ROLLBACK;
SQL

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
BEGIN;
CREATE TEMP TABLE r6b_policy_results (
  scenario text NOT NULL,
  call_order integer NOT NULL,
  disposition text NOT NULL,
  case_id uuid,
  dataset_snapshot_id uuid,
  agent_run_id uuid,
  job_id uuid,
  receipt_id uuid NOT NULL,
  actor_type text NOT NULL,
  actor_id text NOT NULL,
  replayed boolean NOT NULL
);
GRANT INSERT, SELECT ON r6b_policy_results TO gurine_workflow_worker;
GRANT SELECT ON r6b_policy_results TO gurine_analysis_worker;

CREATE TEMP TABLE r6b_forbidden_counts_before AS
SELECT
  (SELECT count(*) FROM public.cases) AS public_cases,
  (SELECT count(*) FROM editorial.publication_revisions) AS publications,
  (SELECT count(*) FROM ops.agent_suggestions) AS suggestions,
  (SELECT count(*) FROM core.supplier_identity_candidates) AS candidates,
  (SELECT count(*) FROM core.supplier_identity_resolution_decisions) AS decisions,
  (SELECT count(*) FROM core.supplier_identity_resolution_decision_members)
    AS decision_members,
  (SELECT count(*) FROM core.supplier_identifiers) AS identifiers,
  (SELECT count(*) FROM core.suppliers) AS suppliers;

INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES(
  '31200000-0000-4000-8000-000000000001',
  'r6b-policy-runtime',
  'r6b-policy-runtime@example.test',
  'R6b Policy Runtime',
  'ACTIVE'
);
INSERT INTO ops.jobs(id,job_type,queue,payload,dedupe_key)
VALUES(
  '31200000-0000-4000-8000-000000000002',
  'EVENT_DELIVERY',
  'workflow-worker',
  '{}',
  'r6b-policy-runtime-producer'
);

DO $$
DECLARE
  snapshot_id constant uuid := '31200000-0000-4000-8000-000000000010';
  member_id constant uuid := '31200000-0000-4000-8000-000000000011';
  object_id constant uuid := '31200000-0000-4000-8000-000000000012';
  producer_job_id constant uuid := '31200000-0000-4000-8000-000000000002';
  selection jsonb := '{}'::jsonb;
  source_watermarks jsonb := '{}'::jsonb;
  normalization_versions jsonb := '{}'::jsonb;
  member_payload jsonb := jsonb_build_object('responseId', object_id);
  member_binding jsonb := jsonb_build_object(
    'snapshotId', snapshot_id,
    'memberOrdinal', 0,
    'objectType', 'RESPONSE',
    'objectId', object_id
  );
  source_binding jsonb := jsonb_build_object(
    'snapshotId', snapshot_id,
    'memberOrdinal', 0,
    'sourceOrdinal', 0,
    'responseId', object_id,
    'responseVersion', 1
  );
  selection_canonical bytea;
  source_watermarks_canonical bytea;
  normalization_versions_canonical bytea;
  member_payload_canonical bytea;
  member_binding_canonical bytea;
  source_digest char(64);
  source_set_sha256 char(64);
  member_digest char(64);
  member_set_sha256 char(64);
  snapshot_manifest jsonb;
  snapshot_manifest_canonical bytea;
  snapshot_sha256 char(64);
  terminal_receipt_sha256 char(64);
  build_audit_id uuid;
  terminal_audit_id uuid;
BEGIN
  selection_canonical := ops.canonical_jsonb_v1(selection);
  source_watermarks_canonical := ops.canonical_jsonb_v1(source_watermarks);
  normalization_versions_canonical := ops.canonical_jsonb_v1(
    normalization_versions
  );
  member_payload_canonical := ops.canonical_jsonb_v1(member_payload);
  member_binding_canonical := ops.canonical_jsonb_v1(member_binding);
  source_digest := encode(
    extensions.digest(ops.canonical_jsonb_v1(source_binding), 'sha256'),
    'hex'
  );
  source_set_sha256 := encode(
    extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_array(btrim(source_digest))),
      'sha256'
    ),
    'hex'
  );
  member_digest := encode(
    extensions.digest(member_binding_canonical, 'sha256'),
    'hex'
  );
  member_set_sha256 := encode(
    extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_array(btrim(member_digest))),
      'sha256'
    ),
    'hex'
  );
  snapshot_manifest := jsonb_build_object(
    'schemaVersion', 'dataset-snapshot-manifest.v1',
    'snapshotId', snapshot_id,
    'snapshotKind', 'DETECTION_DATASET',
    'memberCount', 1,
    'memberSetSha256', member_set_sha256
  );
  snapshot_manifest_canonical := ops.canonical_jsonb_v1(snapshot_manifest);
  snapshot_sha256 := encode(
    extensions.digest(snapshot_manifest_canonical, 'sha256'),
    'hex'
  );
  terminal_receipt_sha256 := encode(
    extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_object(
        'snapshotId', snapshot_id,
        'state', 'READY',
        'snapshotSha256', snapshot_sha256,
        'memberCount', 1,
        'memberSetSha256', member_set_sha256
      )),
      'sha256'
    ),
    'hex'
  );
  build_audit_id := ops.append_audit_event(
    'snapshot:' || snapshot_id::text,
    'SERVICE',
    'analysis-worker',
    NULL,
    'DATASET_SNAPSHOT_BUILD_STARTED',
    'DatasetSnapshot',
    snapshot_id::text,
    'jobs.operate',
    'SUCCESS',
    NULL,
    producer_job_id,
    jsonb_build_object(
      'snapshotId', snapshot_id,
      'snapshotKind', 'DETECTION_DATASET',
      'producerJobId', producer_job_id,
      'buildRequestSha256', repeat('1',64)
    )
  );
  terminal_audit_id := ops.append_audit_event(
    'snapshot:' || snapshot_id::text,
    'SERVICE',
    'analysis-worker',
    NULL,
    'DATASET_SNAPSHOT_READY',
    'DatasetSnapshot',
    snapshot_id::text,
    'jobs.operate',
    'SUCCESS',
    NULL,
    producer_job_id,
    jsonb_build_object(
      'snapshotId', snapshot_id,
      'state', 'READY',
      'terminalReceiptDigest', terminal_receipt_sha256
    )
  );

  INSERT INTO core.dataset_snapshots(
    id,snapshot_kind,producer_component,producer_job_id,producer_key,
    producer_digest,producer_generation,state,schema_version,selection_spec,
    selection_canonical,selection_sha256,source_watermarks,
    source_watermarks_canonical,source_watermark_sha256,
    normalization_versions,normalization_versions_canonical,
    normalization_set_sha256,member_count,member_set_sha256,
    snapshot_manifest,snapshot_manifest_canonical,snapshot_sha256,
    build_request_sha256,build_started_audit_event_id,
    terminal_receipt_sha256,terminal_audit_event_id,version,ready_at
  ) VALUES (
    snapshot_id,'DETECTION_DATASET','snapshot-producer',producer_job_id,
    'r6b-policy-runtime-detection',repeat('2',64),1,'READY',
    'dataset-snapshot.v1',selection,selection_canonical,
    encode(extensions.digest(selection_canonical,'sha256'),'hex'),
    source_watermarks,source_watermarks_canonical,
    encode(extensions.digest(source_watermarks_canonical,'sha256'),'hex'),
    normalization_versions,normalization_versions_canonical,
    encode(
      extensions.digest(normalization_versions_canonical,'sha256'),
      'hex'
    ),
    1,member_set_sha256,snapshot_manifest,snapshot_manifest_canonical,
    snapshot_sha256,repeat('1',64),build_audit_id,
    terminal_receipt_sha256,terminal_audit_id,2,clock_timestamp()
  );
  INSERT INTO core.dataset_snapshot_members(
    id,dataset_snapshot_id,snapshot_kind,producer_generation,
    snapshot_contract_version,member_ordinal,object_type,object_id,
    object_version,object_schema_version,object_content_sha256,
    canonical_payload,canonical_payload_bytes,payload_sha256,response_id,
    source_count,source_set_sha256,member_binding_canonical,member_digest
  ) VALUES (
    member_id,snapshot_id,'DETECTION_DATASET',1,1,0,'RESPONSE',object_id,
    1,'response.v1',repeat('3',64),member_payload,
    member_payload_canonical,
    encode(extensions.digest(member_payload_canonical,'sha256'),'hex'),
    object_id,1,source_set_sha256,member_binding_canonical,member_digest
  );
  INSERT INTO core.dataset_snapshot_member_sources(
    id,dataset_snapshot_id,snapshot_member_id,member_ordinal,
    snapshot_member_digest,source_ordinal,lineage_kind,source_kind,
    response_id,response_version,response_content_sha256,source_digest
  ) VALUES (
    '31200000-0000-4000-8000-000000000013',snapshot_id,member_id,0,
    member_digest,0,'RESPONSE','RESPONSE',object_id,1,repeat('3',64),
    source_digest
  );
END $$;

INSERT INTO core.rule_versions(
  id,rule_id,version,name,description,configuration,code_digest,status,
  created_by
) VALUES
  ('31200000-0000-4000-8000-000000000020','r6b-runtime-a','1.0.0',
   'R6b runtime A','R6b runtime policy fixture','{}',repeat('4',64),
   'ACTIVE','31200000-0000-4000-8000-000000000001'),
  ('31200000-0000-4000-8000-000000000021','r6b-runtime-b','1.0.0',
   'R6b runtime B','R6b runtime policy fixture','{}',repeat('5',64),
   'ACTIVE','31200000-0000-4000-8000-000000000001');
INSERT INTO core.rule_runs(
  id,rule_version_id,run_key,input_snapshot_at,input_digest,started_at,
  completed_at,status,dataset_snapshot_id,dataset_snapshot_sha256,
  rule_configuration_sha256,rule_code_sha256
)
SELECT
  fixture.id,fixture.rule_version_id,fixture.run_key,clock_timestamp(),
  repeat('6',64),clock_timestamp(),clock_timestamp(),'SUCCEEDED',snapshot.id,
  snapshot.snapshot_sha256,repeat('7',64),repeat('8',64)
FROM core.dataset_snapshots AS snapshot
CROSS JOIN (VALUES
  ('31200000-0000-4000-8000-000000000030'::uuid,
   '31200000-0000-4000-8000-000000000020'::uuid,'r6b-runtime-run-a'),
  ('31200000-0000-4000-8000-000000000031'::uuid,
   '31200000-0000-4000-8000-000000000021'::uuid,'r6b-runtime-run-b')
) AS fixture(id,rule_version_id,run_key)
WHERE snapshot.id='31200000-0000-4000-8000-000000000010';

INSERT INTO core.anomaly_signals(
  id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity,
  status,explanation,calculation
) VALUES
  ('31200000-0000-4000-8000-000000000101','31200000-0000-4000-8000-000000000030','31200000-0000-4000-8000-000000000020','R6B_ABSENT','CASE','31200000-0000-4000-8000-000000000201','HIGH','NEW','{}','{}'),
  ('31200000-0000-4000-8000-000000000102','31200000-0000-4000-8000-000000000030','31200000-0000-4000-8000-000000000020','R6B_DISABLED','CASE','31200000-0000-4000-8000-000000000202','HIGH','NEW','{}','{}'),
  ('31200000-0000-4000-8000-000000000103','31200000-0000-4000-8000-000000000030','31200000-0000-4000-8000-000000000020','R6B_PROVIDER','CASE','31200000-0000-4000-8000-000000000203','HIGH','NEW','{}','{}'),
  ('31200000-0000-4000-8000-000000000104','31200000-0000-4000-8000-000000000030','31200000-0000-4000-8000-000000000020','R6B_KILL','CASE','31200000-0000-4000-8000-000000000204','LOW','NEW','{}','{}'),
  ('31200000-0000-4000-8000-000000000105','31200000-0000-4000-8000-000000000030','31200000-0000-4000-8000-000000000020','R6B_SEVERITY','CASE','31200000-0000-4000-8000-000000000205','LOW','NEW','{}','{}'),
  ('31200000-0000-4000-8000-000000000106','31200000-0000-4000-8000-000000000030','31200000-0000-4000-8000-000000000020','R6B_SCOPE','CASE','31200000-0000-4000-8000-000000000206','HIGH','NEW',jsonb_build_object('includedIds','[]'::jsonb),'{}'),
  ('31200000-0000-4000-8000-000000000107','31200000-0000-4000-8000-000000000030','31200000-0000-4000-8000-000000000020','R6B_START','CASE','31200000-0000-4000-8000-000000000207','HIGH','NEW',jsonb_build_object('includedIds',jsonb_build_array('31200000-0000-4000-8000-000000000012')),'{}'),
  ('31200000-0000-4000-8000-000000000108','31200000-0000-4000-8000-000000000030','31200000-0000-4000-8000-000000000020','R6B_DEDUPE','CASE','31200000-0000-4000-8000-000000000207','HIGH','NEW',jsonb_build_object('includedIds',jsonb_build_array('31200000-0000-4000-8000-000000000012')),'{}'),
  ('31200000-0000-4000-8000-000000000109','31200000-0000-4000-8000-000000000031','31200000-0000-4000-8000-000000000021','R6B_CASE_LIMIT','CASE','31200000-0000-4000-8000-000000000207','HIGH','NEW',jsonb_build_object('includedIds',jsonb_build_array('31200000-0000-4000-8000-000000000012')),'{}'),
  ('31200000-0000-4000-8000-00000000010a','31200000-0000-4000-8000-000000000030','31200000-0000-4000-8000-000000000020','R6B_DAILY_START','CASE','31200000-0000-4000-8000-00000000020a','HIGH','NEW',jsonb_build_object('includedIds',jsonb_build_array('31200000-0000-4000-8000-000000000012')),'{}'),
  ('31200000-0000-4000-8000-00000000010b','31200000-0000-4000-8000-000000000030','31200000-0000-4000-8000-000000000020','R6B_DAILY_LIMIT','CASE','31200000-0000-4000-8000-00000000020b','HIGH','NEW',jsonb_build_object('includedIds',jsonb_build_array('31200000-0000-4000-8000-000000000012')),'{}'),
  ('31200000-0000-4000-8000-00000000010c','31200000-0000-4000-8000-000000000030','31200000-0000-4000-8000-000000000020','R6B_BUDGET','CASE','31200000-0000-4000-8000-00000000020c','HIGH','NEW',jsonb_build_object('includedIds',jsonb_build_array('31200000-0000-4000-8000-000000000012')),'{}');

SET LOCAL ROLE gurine_workflow_worker;
INSERT INTO r6b_policy_results
SELECT 'policy_absent',1,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-000000000101',
  '31200000-0000-4000-8000-000000000002'
) AS result;
RESET ROLE;

INSERT INTO ops.signal_investigation_policies(
  policy_id,version,enabled,policy_digest
) VALUES (
  '31200000-0000-4000-8000-000000000300',1,false,repeat('9',64)
);
SET LOCAL ROLE gurine_workflow_worker;
INSERT INTO r6b_policy_results
SELECT 'policy_disabled',1,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-000000000102',
  '31200000-0000-4000-8000-000000000002'
) AS result;
RESET ROLE;

INSERT INTO ops.signal_investigation_policies(
  policy_id,version,enabled,minimum_severity,dedupe_window,
  daily_run_limit,case_daily_run_limit,daily_budget_micros_krw,
  max_run_micros_krw,kill_switch_code,agent_type,prompt_id,prompt_version,
  prompt_sha256,output_schema_id,output_schema_version,
  output_schema_sha256,provider_policy_version,provider_policy_sha256,
  provider_classification,provider_candidate_ids,budget_policy_version,
  budget_policy_sha256,max_provider_turns,max_tool_calls,deadline_interval,
  created_by,policy_digest
) VALUES (
  '31200000-0000-4000-8000-000000000301',2,true,'HIGH',interval '1 hour',
  2,1,1000,10,'r6b-runtime-kill','investigator','r6b-runtime-prompt','1',
  repeat('a',64),'r6b-runtime-output','1',repeat('b',64),
  'r6b-runtime-provider-policy',repeat('c',64),'PUBLIC',
  ARRAY['runtime-test-provider'],'r6b-runtime-budget',repeat('d',64),
  1,0,interval '5 minutes','31200000-0000-4000-8000-000000000001',
  repeat('e',64)
);

SET LOCAL ROLE gurine_workflow_worker;
INSERT INTO r6b_policy_results
SELECT 'provider_unavailable',1,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-000000000103',
  '31200000-0000-4000-8000-000000000002'
) AS result;
RESET ROLE;

INSERT INTO ops.provider_configs(
  id,provider_type,name,enabled,routing_policy,secret_reference,
  data_retention_policy
) VALUES (
  '31200000-0000-4000-8000-000000000310','runtime-test-provider',
  'R6b Runtime Provider',true,
  '{"model":"runtime-model","dataPolicy":{"state":"CONFIGURED"}}',
  'env:R6B_RUNTIME_TEST','LOCAL_ONLY'
);
INSERT INTO ops.kill_switches(
  id,code,scope,state,reason,activated_by,activated_at
) VALUES (
  '31200000-0000-4000-8000-000000000311','r6b-runtime-kill','{}',
  'ACTIVE','R6b runtime policy test',
  '31200000-0000-4000-8000-000000000001',clock_timestamp()
);
SET LOCAL ROLE gurine_workflow_worker;
INSERT INTO r6b_policy_results
SELECT 'kill_switch',1,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-000000000104',
  '31200000-0000-4000-8000-000000000002'
) AS result;
RESET ROLE;
UPDATE ops.kill_switches
SET state='INACTIVE',version=version+1,deactivated_at=clock_timestamp()
WHERE id='31200000-0000-4000-8000-000000000311';

SET LOCAL ROLE gurine_workflow_worker;
INSERT INTO r6b_policy_results
SELECT 'severity',1,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-000000000105',
  '31200000-0000-4000-8000-000000000002'
) AS result;
INSERT INTO r6b_policy_results
SELECT 'evidence_scope',1,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-000000000106',
  '31200000-0000-4000-8000-000000000002'
) AS result;
INSERT INTO r6b_policy_results
SELECT 'started_replay',1,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-000000000107',
  '31200000-0000-4000-8000-000000000002'
) AS result;
INSERT INTO r6b_policy_results
SELECT 'started_replay',2,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-000000000107',
  '31200000-0000-4000-8000-000000000002'
) AS result;
INSERT INTO r6b_policy_results
SELECT 'same_target_dedupe',1,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-000000000108',
  '31200000-0000-4000-8000-000000000002'
) AS result;
INSERT INTO r6b_policy_results
SELECT 'case_limit',1,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-000000000109',
  '31200000-0000-4000-8000-000000000002'
) AS result;
INSERT INTO r6b_policy_results
SELECT 'daily_started',1,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-00000000010a',
  '31200000-0000-4000-8000-000000000002'
) AS result;
INSERT INTO r6b_policy_results
SELECT 'daily_limit',1,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-00000000010b',
  '31200000-0000-4000-8000-000000000002'
) AS result;
RESET ROLE;

INSERT INTO ops.signal_investigation_policies(
  policy_id,policy_key,version,enabled,minimum_severity,dedupe_window,
  daily_run_limit,case_daily_run_limit,daily_budget_micros_krw,
  max_run_micros_krw,kill_switch_code,agent_type,prompt_id,prompt_version,
  prompt_sha256,output_schema_id,output_schema_version,
  output_schema_sha256,provider_policy_version,provider_policy_sha256,
  provider_classification,provider_candidate_ids,budget_policy_version,
  budget_policy_sha256,max_provider_turns,max_tool_calls,deadline_interval,
  created_by,policy_digest
)
SELECT
  '31200000-0000-4000-8000-000000000302',policy_key,3,enabled,
  minimum_severity,dedupe_window,10,10,25,10,kill_switch_code,agent_type,
  prompt_id,prompt_version,prompt_sha256,output_schema_id,
  output_schema_version,output_schema_sha256,provider_policy_version,
  provider_policy_sha256,provider_classification,provider_candidate_ids,
  budget_policy_version,budget_policy_sha256,max_provider_turns,
  max_tool_calls,deadline_interval,created_by,repeat('f',64)
FROM ops.signal_investigation_policies
WHERE policy_id='31200000-0000-4000-8000-000000000301';
SET LOCAL ROLE gurine_workflow_worker;
INSERT INTO r6b_policy_results
SELECT 'budget',1,result.*
FROM ops.process_signal_investigation_v1(
  '31200000-0000-4000-8000-00000000010c',
  '31200000-0000-4000-8000-000000000002'
) AS result;
RESET ROLE;

SET LOCAL ROLE gurine_analysis_worker;
DO $$
DECLARE
  run_id uuid;
  before_status text;
  before_version bigint;
  before_control_state text;
  after_status text;
  after_version bigint;
  after_control_state text;
  claim_denied boolean := false;
  transition_denied boolean := false;
BEGIN
  SELECT agent_run_id INTO STRICT run_id
  FROM r6b_policy_results
  WHERE scenario='started_replay' AND call_order=1;
  SELECT status::text,version,control_state
  INTO STRICT before_status,before_version,before_control_state
  FROM ops.agent_runs WHERE id=run_id;

  BEGIN
    PERFORM 1 FROM ops.claim_agent_run_worker_v1(run_id);
  EXCEPTION WHEN SQLSTATE '55000' THEN
    claim_denied := SQLERRM = 'agent_run_v2_transition_authority_missing';
  END;
  BEGIN
    PERFORM ops.transition_agent_run_worker_v1(
      run_id,1,'RUNNING',NULL,NULL,NULL,NULL,NULL,false
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    transition_denied := SQLERRM =
      'agent_run_v2_transition_authority_missing';
  END;

  SELECT status::text,version,control_state
  INTO STRICT after_status,after_version,after_control_state
  FROM ops.agent_runs WHERE id=run_id;
  IF NOT claim_denied OR NOT transition_denied
     OR before_status IS DISTINCT FROM 'QUEUED'
     OR before_version IS DISTINCT FROM 1
     OR before_control_state IS DISTINCT FROM 'NONE'
     OR after_status IS DISTINCT FROM before_status
     OR after_version IS DISTINCT FROM before_version
     OR after_control_state IS DISTINCT FROM before_control_state THEN
    RAISE EXCEPTION 'R6b v2 legacy transition boundary did not fail closed';
  END IF;
END $$;
RESET ROLE;

DO $$
DECLARE
  start_result r6b_policy_results%ROWTYPE;
  replay_result r6b_policy_results%ROWTYPE;
  before_counts r6b_forbidden_counts_before%ROWTYPE;
BEGIN
  IF (SELECT count(*) FROM r6b_policy_results) <> 13
     OR (SELECT count(DISTINCT disposition) FROM r6b_policy_results) <> 11
     OR EXISTS (
       SELECT expected.scenario,expected.call_order,expected.disposition,
              expected.replayed
       FROM (VALUES
         ('policy_absent',1,'POLICY_ABSENT',false),
         ('policy_disabled',1,'POLICY_DISABLED',false),
         ('provider_unavailable',1,'PROVIDER_UNAVAILABLE',false),
         ('kill_switch',1,'KILL_SWITCH_ACTIVE',false),
         ('severity',1,'BELOW_MIN_SEVERITY',false),
         ('evidence_scope',1,'EVIDENCE_SCOPE_DENIED',false),
         ('started_replay',1,'STARTED',false),
         ('started_replay',2,'STARTED',true),
         ('same_target_dedupe',1,'DUPLICATE_SUPPRESSED',false),
         ('case_limit',1,'CASE_DAILY_LIMIT_REACHED',false),
         ('daily_started',1,'STARTED',false),
         ('daily_limit',1,'DAILY_LIMIT_REACHED',false),
         ('budget',1,'BUDGET_BLOCKED',false)
       ) AS expected(scenario,call_order,disposition,replayed)
       EXCEPT
       SELECT scenario,call_order,disposition,replayed
       FROM r6b_policy_results
     ) THEN
    RAISE EXCEPTION 'R6b policy disposition matrix invalid: %',(
      SELECT jsonb_agg(to_jsonb(result) ORDER BY scenario,call_order)
      FROM r6b_policy_results AS result
    );
  END IF;
  IF EXISTS (
    SELECT 1
    FROM r6b_policy_results AS result
    LEFT JOIN ops.signal_investigation_initiation_receipts AS receipt
      ON receipt.receipt_id=result.receipt_id
    LEFT JOIN ops.audit_events AS audit
      ON audit.id=receipt.audit_event_id
    WHERE result.actor_type <> 'SERVICE'
       OR result.actor_id <> 'workflow-worker'
       OR receipt.receipt_id IS NULL
       OR receipt.actor_type <> 'SERVICE'
       OR receipt.actor_id <> 'workflow-worker'
       OR receipt.disposition IS DISTINCT FROM result.disposition
       OR receipt.case_id IS DISTINCT FROM result.case_id
       OR receipt.dataset_snapshot_id IS DISTINCT FROM result.dataset_snapshot_id
       OR receipt.agent_run_id IS DISTINCT FROM result.agent_run_id
       OR receipt.job_id IS DISTINCT FROM result.job_id
       OR receipt.receipt_payload->>'receiptId'
         IS DISTINCT FROM result.receipt_id::text
       OR receipt.receipt_payload->>'disposition'
         IS DISTINCT FROM result.disposition
       OR receipt.receipt_payload->>'actorType' IS DISTINCT FROM 'SERVICE'
       OR receipt.receipt_payload->>'actorId'
         IS DISTINCT FROM 'workflow-worker'
       OR audit.actor_type <> 'SERVICE'
       OR audit.actor_id <> 'workflow-worker'
       OR audit.action <> CASE result.disposition
         WHEN 'STARTED' THEN 'SIGNAL_INVESTIGATION_STARTED'
         ELSE 'SIGNAL_INVESTIGATION_NOT_STARTED'
       END
       OR audit.object_type <> 'Signal'
       OR audit.object_id <> receipt.signal_id::text
       OR audit.capability <> 'jobs.operate'
       OR audit.outcome <> 'SUCCESS'
       OR (
         result.disposition <> 'STARTED'
         AND audit.details->>'disposition' IS DISTINCT FROM result.disposition
       )
  ) THEN
    RAISE EXCEPTION 'R6b policy result lost typed SERVICE actor/audit binding';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM r6b_policy_results AS result
    JOIN ops.signal_investigation_initiation_receipts AS receipt
      ON receipt.receipt_id=result.receipt_id
    WHERE result.disposition <> 'STARTED'
      AND (
        num_nonnulls(
          result.case_id,result.dataset_snapshot_id,result.agent_run_id,
          result.job_id,receipt.case_id,receipt.dataset_snapshot_id,
          receipt.agent_run_id,receipt.job_id
        ) <> 0
        OR receipt.reserved_micros_krw <> 0
      )
  ) THEN
    RAISE EXCEPTION 'R6b policy denial was not a successful no-op';
  END IF;
  IF NOT EXISTS (
       SELECT 1 FROM ops.signal_investigation_initiation_receipts
       WHERE signal_id='31200000-0000-4000-8000-000000000101'
         AND disposition='POLICY_ABSENT'
         AND policy_id IS NULL AND policy_version IS NULL
     )
     OR NOT EXISTS (
       SELECT 1 FROM ops.signal_investigation_initiation_receipts
       WHERE signal_id='31200000-0000-4000-8000-000000000102'
         AND disposition='POLICY_DISABLED' AND policy_version=1
     ) THEN
    RAISE EXCEPTION 'R6b absent/disabled policy receipt binding invalid';
  END IF;

  SELECT * INTO STRICT start_result
  FROM r6b_policy_results
  WHERE scenario='started_replay' AND call_order=1;
  SELECT * INTO STRICT replay_result
  FROM r6b_policy_results
  WHERE scenario='started_replay' AND call_order=2;
  IF start_result.receipt_id <> replay_result.receipt_id
     OR start_result.case_id <> replay_result.case_id
     OR start_result.dataset_snapshot_id <> replay_result.dataset_snapshot_id
     OR start_result.agent_run_id <> replay_result.agent_run_id
     OR start_result.job_id <> replay_result.job_id
     OR (SELECT count(*) FROM ops.signal_investigation_initiation_receipts
         WHERE signal_id='31200000-0000-4000-8000-000000000107') <> 1 THEN
    RAISE EXCEPTION 'R6b STARTED replay was not identity-stable/exactly-once';
  END IF;
  IF (SELECT count(*) FROM ops.signal_investigation_initiation_receipts
      WHERE receipt_id IN (SELECT receipt_id FROM r6b_policy_results)
        AND disposition='STARTED') <> 2
     OR (SELECT count(*) FROM editorial.cases
         WHERE id IN (
           SELECT case_id FROM ops.signal_investigation_initiation_receipts
           WHERE receipt_id IN (SELECT receipt_id FROM r6b_policy_results)
             AND disposition='STARTED'
         )
         AND investigation_state='SIGNAL_DETECTED'
         AND publication_state='NEVER_PUBLISHED') <> 2
     OR (SELECT count(*) FROM core.dataset_snapshots
         WHERE id IN (
           SELECT dataset_snapshot_id
           FROM ops.signal_investigation_initiation_receipts
           WHERE receipt_id IN (SELECT receipt_id FROM r6b_policy_results)
             AND disposition='STARTED'
         ) AND snapshot_kind='AGENT_CASE' AND state='READY') <> 2
     OR (SELECT count(*) FROM ops.agent_runs
         WHERE id IN (
           SELECT agent_run_id
           FROM ops.signal_investigation_initiation_receipts
           WHERE receipt_id IN (SELECT receipt_id FROM r6b_policy_results)
             AND disposition='STARTED'
         ) AND run_contract_version=2 AND status='QUEUED'
           AND created_actor_type='SERVICE'
           AND created_service='workflow-worker') <> 2
     OR (SELECT count(*) FROM ops.jobs
         WHERE id IN (
           SELECT job_id FROM ops.signal_investigation_initiation_receipts
           WHERE receipt_id IN (SELECT receipt_id FROM r6b_policy_results)
             AND disposition='STARTED'
         ) AND job_type='AGENT_RUN' AND queue='analysis-worker'
           AND status='QUEUED') <> 2 THEN
    RAISE EXCEPTION 'R6b STARTED graph/state binding invalid';
  END IF;
  IF (SELECT count(*)
      FROM ops.signal_investigation_initiation_receipts
      WHERE rule_version_id='31200000-0000-4000-8000-000000000020'
        AND target_id='31200000-0000-4000-8000-000000000207'
        AND disposition='STARTED') <> 1
     OR (SELECT count(*)
         FROM ops.signal_investigation_initiation_receipts
         WHERE rule_version_id='31200000-0000-4000-8000-000000000020'
           AND target_id='31200000-0000-4000-8000-000000000207'
           AND disposition='DUPLICATE_SUPPRESSED') <> 1 THEN
    RAISE EXCEPTION 'R6b same-target calls did not preserve one STARTED/dedupe pair';
  END IF;
  IF (SELECT count(*) FROM core.anomaly_signals
      WHERE id IN (
        SELECT receipt.signal_id
        FROM ops.signal_investigation_initiation_receipts AS receipt
        JOIN r6b_policy_results AS result
          ON result.receipt_id=receipt.receipt_id
      )
        AND (status <> 'NEW' OR version <> 1)) <> 0 THEN
    RAISE EXCEPTION 'R6b automatic investigation mutated signal state';
  END IF;

  SELECT * INTO STRICT before_counts FROM r6b_forbidden_counts_before;
  IF (SELECT count(*) FROM public.cases) <> before_counts.public_cases
     OR (SELECT count(*) FROM editorial.publication_revisions)
       <> before_counts.publications
     OR (SELECT count(*) FROM ops.agent_suggestions)
       <> before_counts.suggestions
     OR (SELECT count(*) FROM core.supplier_identity_candidates)
       <> before_counts.candidates
     OR (SELECT count(*) FROM core.supplier_identity_resolution_decisions)
       <> before_counts.decisions
     OR (SELECT count(*)
         FROM core.supplier_identity_resolution_decision_members)
       <> before_counts.decision_members
     OR (SELECT count(*) FROM core.supplier_identifiers)
       <> before_counts.identifiers
     OR (SELECT count(*) FROM core.suppliers) <> before_counts.suppliers THEN
    RAISE EXCEPTION 'R6b automatic investigation published/accepted/merged';
  END IF;
END $$;
ROLLBACK;
SQL

raw_key="01234567890123456789012345678901"
test_key="$(printf '%s' "$raw_key" | base64 -w0)"
encrypt() {
  FIELD_KEY_BASE64="$test_key" FIELD_TABLE="$1" FIELD_COLUMN="$2" \
    FIELD_RECORD_ID="$3" FIELD_LOGICAL_TYPE="$4" FIELD_PLAINTEXT="$5" \
    target/debug/field-envelope
}

request_id="31000000-0000-4000-8000-000000000010"
subscription_pending="31000000-0000-4000-8000-000000000020"
subscription_active="31000000-0000-4000-8000-000000000021"
correction_id="31000000-0000-4000-8000-000000000030"
request_email="$(encrypt editorial.response_requests recipient_email_encrypted "$request_id" email-address respondent@example.test)"
pending_email="$(encrypt intake.subscriptions email_encrypted "$subscription_pending" email-address pending@example.test)"
active_email="$(encrypt intake.subscriptions email_encrypted "$subscription_active" email-address active@example.test)"
correction_email="$(encrypt intake.correction_requests contact_email_encrypted "$correction_id" email-address correction@example.test)"
agent_output='{"suggestions":[]}'
agent_digest="$(printf '%s' "$agent_output" | sha256sum | cut -d' ' -f1)"

mkdir -p "$work/objects/uploads"
printf 'response attachment clean bytes' >"$work/objects/uploads/response.txt"
printf 'correction attachment clean bytes' >"$work/objects/uploads/correction.txt"
response_sha="$(sha256sum "$work/objects/uploads/response.txt" | cut -d' ' -f1)"
correction_sha="$(sha256sum "$work/objects/uploads/correction.txt" | cut -d' ' -f1)"
response_size="$(stat -c %s "$work/objects/uploads/response.txt")"
correction_size="$(stat -c %s "$work/objects/uploads/correction.txt")"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -v request_email="$request_email" -v pending_email="$pending_email" \
  -v active_email="$active_email" -v correction_email="$correction_email" \
  -v agent_digest="$agent_digest" -v agent_output="$agent_output" \
  -v response_sha="$response_sha" -v correction_sha="$correction_sha" \
  -v response_size="$response_size" -v correction_size="$correction_size" <<'SQL' >/dev/null
INSERT INTO ops.users(id,oidc_subject,email,display_name,status) VALUES
 ('31000000-0000-4000-8000-000000000001','event-publisher','publisher@example.test','Event Publisher','ACTIVE'),
 ('31000000-0000-4000-8000-000000000002','event-reviewer','event-reviewer@example.test','Event Reviewer','ACTIVE'),
 ('31000000-0000-4000-8000-000000000003','event-invitee','invitee@example.test','Event Invitee','INVITED');
INSERT INTO editorial.cases(id,public_slug,title,investigation_state,publication_state,summary,version)
VALUES('31000000-0000-4000-8000-000000000004','event-case','Event consumer case','READY_TO_PUBLISH','PUBLISHED_ANOMALY','Event consumer integration',1);
INSERT INTO editorial.review_snapshots(id,case_id,case_version,snapshot_sha256,snapshot_payload,automated_gate_results,created_by)
VALUES(
  '31000000-0000-4000-8000-000000000005',
  '31000000-0000-4000-8000-000000000004',1,
  encode(extensions.digest(
    convert_to('event-consumer-review-snapshot','UTF8'),'sha256'
  ),'hex'),'{}','{}','31000000-0000-4000-8000-000000000001'
);
UPDATE editorial.cases SET current_review_snapshot_id='31000000-0000-4000-8000-000000000005'
 WHERE id='31000000-0000-4000-8000-000000000004';
INSERT INTO editorial.review_decisions(review_snapshot_id,reviewer_id,decision,reason,criteria,reviewer_independence,reauth_context_hash)
VALUES('31000000-0000-4000-8000-000000000005','31000000-0000-4000-8000-000000000002','APPROVE','Event fixture approval','{}','{"independent":true}',repeat('2',64));

-- TEST_ONLY: these two immutable rows are a legacy historical root for
-- downstream event consumers.  This transaction-local bypass does not prove
-- R6d publication authority, named-person assessment, owner receipts, STEP_UP,
-- or entity material-use closure; those belong to the dedicated R6d fixture.
-- Do not compose this seed with retention/material-use closure probes.
BEGIN;
SET LOCAL session_replication_role=replica;
INSERT INTO editorial.publication_previews(case_id,review_snapshot_id,locale,preview_payload,preview_sha256,expires_at,created_by)
VALUES('31000000-0000-4000-8000-000000000004','31000000-0000-4000-8000-000000000005','event','{}','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',clock_timestamp()+interval '1 hour','31000000-0000-4000-8000-000000000001');
INSERT INTO editorial.publication_revisions(id,case_id,revision,state,review_snapshot_id,public_payload,public_payload_sha256,preview_sha256,published_by)
VALUES('31000000-0000-4000-8000-000000000006','31000000-0000-4000-8000-000000000004',1,'PUBLISHED_ANOMALY','31000000-0000-4000-8000-000000000005','{}','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','31000000-0000-4000-8000-000000000001');
COMMIT;

DO $legacy_publication_root_scope$
BEGIN
  IF current_setting('session_replication_role')<>'origin' THEN
    RAISE EXCEPTION 'legacy publication root replica scope leaked';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM editorial.publication_previews preview
    JOIN editorial.cases current_case
      ON current_case.id=preview.case_id
    JOIN editorial.review_snapshots snapshot
      ON snapshot.id=preview.review_snapshot_id
     AND snapshot.case_id=current_case.id
    WHERE current_case.id='31000000-0000-4000-8000-000000000004'
      AND snapshot.id='31000000-0000-4000-8000-000000000005'
  ) OR NOT EXISTS (
    SELECT 1
    FROM editorial.publication_revisions revision
    JOIN editorial.cases current_case
      ON current_case.id=revision.case_id
    JOIN editorial.review_snapshots snapshot
      ON snapshot.id=revision.review_snapshot_id
     AND snapshot.case_id=current_case.id
    WHERE revision.id='31000000-0000-4000-8000-000000000006'
  ) THEN
    RAISE EXCEPTION 'legacy publication root parent binding invalid';
  END IF;
END
$legacy_publication_root_scope$;

INSERT INTO editorial.response_requests(
  id,case_id,party_type,party_name,recipient_email_hash,
  recipient_email_encrypted,questions,requested_publication_scope,due_at,
  status,version,created_by
)
VALUES(
  '31000000-0000-4000-8000-000000000010',
  '31000000-0000-4000-8000-000000000004','OTHER','Event Respondent',
  repeat('3',64),:'request_email','["Please respond"]','{}',
  clock_timestamp()+interval '7 days','SENT',2,
  '31000000-0000-4000-8000-000000000001'
);

-- TEST_ONLY: install only the immutable direct parents needed to validate an
-- exact response-request sent receipt.  These disposable provenance roots do
-- not stand in for a producer.  The sent receipt, response submission, v2
-- events, reciprocal pair, and materializer all remain on origin.
BEGIN;
SET LOCAL session_replication_role=replica;
DO $response_sent_parent_roots$
DECLARE
  v_at timestamptz:=clock_timestamp();
  v_snapshot jsonb;
  v_configuration_digest char(64);
BEGIN
  v_snapshot:=jsonb_build_object(
    'id','31000000-0000-4000-8000-000000000024'::uuid,
    'integrationId','31000000-0000-4000-8000-00000000002a'::uuid,
    'deploymentId','event-consumer','environment','test',
    'channel','SMTP_EMAIL','adapterId','smtp-email-v1','version',1,
    'providerAccountHmac',repeat('b',64),
    'senderIdentityCiphertextDigest',repeat('b',64),
    'senderIdentityHmac',repeat('b',64),'encryptionKeyId','fixture-key',
    'credentialSecretReference',
      'secret://event-consumer-provider/value@v1',
    'webhookSecretReference',
      to_jsonb('secret://event-consumer-webhook/value@v1'::text),
    'callbackPath',to_jsonb('/private/v1/callbacks/event-consumer'::text),
    'callbackAllowlistDigest',to_jsonb(repeat('b',64)),
    'jurisdictionSetDigest',repeat('b',64),
    'dpaEvidenceDigest',repeat('b',64),
    'approvedTemplateCatalogDigest',repeat('b',64),
    'rateLimitPolicyDigest',repeat('b',64),
    'costPolicyDigest',repeat('b',64),
    'providerCapabilitiesDigest',repeat('b',64),
    'killSwitchCode','EVENT_CONSUMER_TEST_ONLY'
  );
  v_configuration_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_snapshot),'sha256'
  ),'hex');

  -- TEST_FIXTURE_ONLY: complete the concrete RESPONSE_RECEIPT source graph
  -- consumed by the privacy authority owner.  The surrounding replica scope
  -- bypasses only producer-side parents that this disposable event fixture
  -- does not own; every Q4 read/plan/approval/worker call below runs at origin.
  INSERT INTO intake.communication_subjects(
    id,subject_kind,origin_object_type,origin_object_id,origin_object_version,
    origin_binding_digest,subject_pseudonym_hmac,hmac_key_version,jurisdiction,
    locale,status,profile_version,profile_digest,created_at,updated_at
  ) VALUES(
    '31000000-0000-4000-8000-000000000025','RESPONSE_PARTY',
    'RESPONSE_REQUEST','31000000-0000-4000-8000-000000000010',2,
    repeat('d',64),repeat('d',64),'hmac-v1','KR','ko-KR','ACTIVE',1,
    repeat('d',64),v_at,v_at
  );
  INSERT INTO intake.communication_endpoints(
    id,subject_id,channel,endpoint_hmac,hmac_key_version,endpoint_ciphertext,
    encryption_key_id,state,version,endpoint_digest,endpoint_aad_digest,
    verified_at,created_at,updated_at
  ) VALUES(
    '31000000-0000-4000-8000-000000000017',
    '31000000-0000-4000-8000-000000000025','SMTP_EMAIL',repeat('d',64),
    'hmac-v1',convert_to(rpad('event-consumer-endpoint',32,'x'),'UTF8'),
    'fixture-key','ACTIVE',1,repeat('d',64),
    ops.r6d_nul5_sha256_v1(
      'intake.communication_endpoints','endpoint_ciphertext',
      '31000000-0000-4000-8000-000000000017',
      'email-address','1'
    ),v_at,v_at,v_at
  );
  INSERT INTO intake.communication_endpoint_link_events(
    id,subject_id,subject_origin_binding_digest,endpoint_id,
    endpoint_sequence,profile_version,endpoint_version,endpoint_hmac,
    endpoint_digest,channel,state,change_kind,proof_digest,reason_code,
    endpoint_snapshot_digest,event_digest,audit_event_id,receipt_digest,
    occurred_at
  ) VALUES(
    '31000000-0000-4000-8000-000000000018',
    '31000000-0000-4000-8000-000000000025',repeat('d',64),
    '31000000-0000-4000-8000-000000000017',1,1,1,repeat('d',64),
    repeat('d',64),'SMTP_EMAIL','ACTIVE','VERIFIED',repeat('d',64),
    'EVENT_CONSUMER_TEST_ONLY',repeat('d',64),repeat('d',64),
    '31000000-0000-4000-8000-00000000002b',repeat('d',64),v_at
  );
  INSERT INTO ops.communication_intents(
    id,deployment_id,logical_intent_digest,source_event_id,source_event_type,
    source_object_type,source_object_id,material_event_version,
    communication_class,purpose,topic_scope,topic_scope_digest,
    recipient_subject_id,audience_policy_version,audience_policy_digest,
    policy_snapshot_digest,effect_safety_class,source_decision_receipt_id,
    source_decision_digest,state,version,intent_digest,
    creation_receipt_digest,created_at,state_changed_at
  ) VALUES(
    '31000000-0000-4000-8000-000000000015','event-consumer',
    repeat('e',64),'31000000-0000-4000-8000-000000000028',
    'response.request_sent.v1','RESPONSE_REQUEST',
    '31000000-0000-4000-8000-000000000010',1,
    'SYSTEM_TRANSACTIONAL','RIGHT_OF_REPLY_REQUEST','{}',repeat('e',64),
    '31000000-0000-4000-8000-000000000025','test-only-v1',repeat('e',64),
    repeat('e',64),'DUPLICATION_SENSITIVE',
    '31000000-0000-4000-8000-00000000002c',repeat('e',64),
    'CREATED',1,repeat('e',64),repeat('e',64),v_at,v_at
  );
  INSERT INTO ops.communication_renderings(
    id,intent_id,rendering_revision,endpoint_id,endpoint_version,
    endpoint_snapshot_digest,channel,locale,template_id,template_revision,
    variable_set,variable_set_digest,attachment_manifest,
    attachment_manifest_digest,disclosure_class,semantic_payload_digest,
    recipient_binding_digest,rendered_envelope_ciphertext,encryption_key_id,
    rendered_sha256,rendered_byte_length,transport_content_type,state,
    state_version,rendering_digest,transition_receipt_digest,expires_at,
    created_at
  ) VALUES(
    '31000000-0000-4000-8000-000000000016',
    '31000000-0000-4000-8000-000000000015',1,
    '31000000-0000-4000-8000-000000000017',1,repeat('d',64),
    'SMTP_EMAIL','ko-KR','event-consumer-test-only','v1','{}',repeat('f',64),
    '[]',repeat('f',64),'INTERNAL_MINIMAL',repeat('f',64),repeat('f',64),
    convert_to(rpad('event-consumer-rendering',32,'x'),'UTF8'),'fixture-key',
    repeat('a',64),32,'text/plain','DRAFT',1,repeat('f',64),repeat('f',64),
    v_at+interval '1 day',v_at
  );
  INSERT INTO ops.communication_provider_preflight_receipts(
    id,provider_config_id,provider_config_version,configuration_digest,
    provider_revision_snapshot,provider_revision_snapshot_digest,
    test_generation,test_environment,result,live_sandbox,
    callback_or_poll_verified,sender_identity_verified,
    template_catalog_verified,idempotency_capability,
    reconciliation_capability,highest_delivery_proof,checklist,
    checklist_digest,blocker_set,blocker_set_digest,
    provider_evidence_digest,contract_test_receipt_digest,receipt_digest,
    performed_by_service,requested_by,started_at,completed_at,expires_at
  ) VALUES(
    '31000000-0000-4000-8000-000000000019',
    '31000000-0000-4000-8000-000000000024',1,v_configuration_digest,
    v_snapshot,v_configuration_digest,1,'test','PASS',true,true,true,true,
    'NATIVE_IDEMPOTENCY','AUTHENTICATED_POLL','DELIVERED','{}',repeat('c',64),
    '[]',repeat('c',64),repeat('c',64),repeat('c',64),repeat('c',64),
    'event-consumer-test-only','31000000-0000-4000-8000-000000000001',
    v_at,v_at,v_at+interval '1 day'
  );
  INSERT INTO ops.outbound_delivery_receipts(
    id,delivery_id,receipt_sequence,event_aggregate_version,
    prior_delivery_version,delivery_version,source_kind,
    observation_key_digest,projection_disposition,evidence_kind,
    evidence_rank,prior_state,asserted_state,resulting_state,
    prior_proof_level,resulting_proof_level,applied,provider_evidence_digest,
    rendering_digest,endpoint_id,endpoint_version,endpoint_snapshot_digest,
    endpoint_identity_hash,provider_preflight_receipt_id,provider_config_id,
    provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_digest,provider_identity_hash,
    authorization_snapshot_digest,activation_receipt_digest,
    budget_reservation_id,observed_at,recorded_at,actor_type,request_id,
    trace_id,receipt_digest,audit_event_id,outbox_event_id
  ) VALUES(
    '31000000-0000-4000-8000-000000000023',
    '31000000-0000-4000-8000-000000000022',1,2,1,2,'PROVIDER_POLL',
    repeat('9',64),'APPLIED','AUTHENTICATED_PROVIDER_POLL',50,
    'PROVIDER_ACCEPTED','DELIVERED','DELIVERED','PROVIDER_ACCEPTED',
    'DELIVERED',true,repeat('4',64),repeat('f',64),
    '31000000-0000-4000-8000-000000000017',1,repeat('d',64),repeat('4',64),
    '31000000-0000-4000-8000-000000000019',
    '31000000-0000-4000-8000-000000000024',1,v_configuration_digest,
    repeat('c',64),repeat('4',64),repeat('4',64),repeat('4',64),
    '31000000-0000-4000-8000-000000000026',v_at,v_at,
    'AUTHORIZED_SERVICE','31000000-0000-4000-8000-00000000002d',
    'event-consumer-test-only',repeat('9',64),
    '31000000-0000-4000-8000-00000000002e',
    '31000000-0000-4000-8000-00000000002f'
  );
END
$response_sent_parent_roots$;
COMMIT;

DO $response_sent_authority$
DECLARE
  v_at timestamptz:=clock_timestamp();
  v_configuration_digest char(64);
  v_request_binding_digest char(64);
  v_receipt_digest char(64);
BEGIN
  IF current_setting('session_replication_role')<>'origin' THEN
    RAISE EXCEPTION 'response sent parent fixture replica scope leaked';
  END IF;
  SELECT configuration_digest INTO STRICT v_configuration_digest
  FROM ops.communication_provider_preflight_receipts
  WHERE id='31000000-0000-4000-8000-000000000019';
  v_request_binding_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','test-only-response-request-sent-binding.v1',
      'responseRequestId','31000000-0000-4000-8000-000000000010'::uuid,
      'responseRequestVersion',2,
      'sentReceiptId','31000000-0000-4000-8000-000000000014'::uuid,
      'sourceEventId','31000000-0000-4000-8000-000000000028'::uuid
    )),'sha256'
  ),'hex');
  v_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','test-only-response-request-sent-receipt.v1',
      'sentReceiptId','31000000-0000-4000-8000-000000000014'::uuid,
      'responseRequestId','31000000-0000-4000-8000-000000000010'::uuid,
      'responseRequestBindingDigest',btrim(v_request_binding_digest),
      'createdAt',v_at
    )),'sha256'
  ),'hex');
  INSERT INTO editorial.response_request_sent_receipts(
    id,source_event_id,source_event_envelope_digest,response_request_id,
    prior_request_version,request_version,response_request_binding_digest,
    scope_digest,prior_state,state,communication_intent_id,
    communication_intent_digest,rendering_id,rendering_digest,
    rendered_sha256,response_access_token_id,access_artifact_binding_digest,
    endpoint_id,endpoint_version,endpoint_snapshot_digest,channel,
    provider_config_id,provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_id,provider_preflight_receipt_digest,
    delivery_id,delivery_object_type,delivery_version,delivery_receipt_id,
    delivery_receipt_sequence,delivery_receipt_digest,
    delivery_resulting_state,delivery_receipt_applied,
    acceptance_evidence_kind,provider_evidence_digest,provider_accepted_at,
    audit_event_id,outbox_event_id,receipt_digest,created_at
  ) VALUES(
    '31000000-0000-4000-8000-000000000014',
    '31000000-0000-4000-8000-000000000028',repeat('1',64),
    '31000000-0000-4000-8000-000000000010',1,2,
    v_request_binding_digest,repeat('2',64),'DRAFT','SENT',
    '31000000-0000-4000-8000-000000000015',repeat('e',64),
    '31000000-0000-4000-8000-000000000016',repeat('f',64),repeat('a',64),
    '31000000-0000-4000-8000-000000000029',repeat('3',64),
    '31000000-0000-4000-8000-000000000017',1,repeat('d',64),'SMTP_EMAIL',
    '31000000-0000-4000-8000-000000000024',1,v_configuration_digest,
    '31000000-0000-4000-8000-000000000019',repeat('c',64),
    '31000000-0000-4000-8000-000000000022','RESPONSE_REQUEST',2,
    '31000000-0000-4000-8000-000000000023',1,repeat('9',64),
    'DELIVERED',true,'AUTHENTICATED_PROVIDER_POLL',repeat('4',64),v_at,
    '31000000-0000-4000-8000-00000000002b',
    '31000000-0000-4000-8000-00000000002c',v_receipt_digest,v_at
  );
END
$response_sent_authority$;

DO $response_sent_parent_binding$
BEGIN
  IF current_setting('session_replication_role')<>'origin' OR NOT EXISTS(
    SELECT 1
    FROM editorial.response_request_sent_receipts AS sent
    JOIN editorial.response_requests AS request
      ON request.id=sent.response_request_id
     AND request.version=sent.request_version
    JOIN ops.communication_intents AS intent
      ON intent.id=sent.communication_intent_id
     AND intent.intent_digest=sent.communication_intent_digest
    JOIN ops.communication_renderings AS rendering
      ON rendering.id=sent.rendering_id
     AND rendering.rendering_digest=sent.rendering_digest
     AND rendering.rendered_sha256=sent.rendered_sha256
    JOIN intake.communication_endpoint_link_events AS endpoint
      ON endpoint.endpoint_id=sent.endpoint_id
     AND endpoint.endpoint_version=sent.endpoint_version
     AND endpoint.endpoint_snapshot_digest=sent.endpoint_snapshot_digest
     AND endpoint.channel=sent.channel
    JOIN ops.communication_provider_preflight_receipts AS preflight
      ON preflight.id=sent.provider_preflight_receipt_id
     AND preflight.provider_config_id=sent.provider_config_id
     AND preflight.provider_config_version=sent.provider_config_version
     AND preflight.configuration_digest=sent.provider_configuration_digest
     AND preflight.receipt_digest=sent.provider_preflight_receipt_digest
    JOIN ops.outbound_delivery_receipts AS delivery
      ON delivery.id=sent.delivery_receipt_id
     AND delivery.delivery_id=sent.delivery_id
     AND delivery.receipt_sequence=sent.delivery_receipt_sequence
     AND delivery.receipt_digest=sent.delivery_receipt_digest
     AND delivery.resulting_state=sent.delivery_resulting_state
     AND delivery.applied=sent.delivery_receipt_applied
    WHERE sent.id='31000000-0000-4000-8000-000000000014'
      AND sent.response_request_id='31000000-0000-4000-8000-000000000010'
      AND sent.request_version=2
      AND ops.r6d_lower_sha256(sent.response_request_binding_digest)
  ) THEN
    RAISE EXCEPTION 'response sent receipt parent binding invalid';
  END IF;
END
$response_sent_parent_binding$;
INSERT INTO intake.response_attachments(id,response_request_id,original_filename_encrypted,media_type,size_bytes,sha256,object_key,upload_status,scan_status)
VALUES('31000000-0000-4000-8000-000000000012','31000000-0000-4000-8000-000000000010',decode('00','hex'),'text/plain',:'response_size',:'response_sha','uploads/response.txt','FINALIZED','PENDING');
INSERT INTO intake.response_extension_requests(id,response_request_id,requested_due_at,reason,status)
VALUES('31000000-0000-4000-8000-000000000013','31000000-0000-4000-8000-000000000010',clock_timestamp()+interval '10 days','Event extension','SUBMITTED');

INSERT INTO intake.correction_requests(id,requester_type,contact_email_hash,contact_email_encrypted,summary,requested_changes,status,receipt_token_hash)
VALUES('31000000-0000-4000-8000-000000000030','OTHER',repeat('6',64),:'correction_email','Event correction','["Correct this"]','SUBMITTED',repeat('7',64));
INSERT INTO intake.correction_request_drafts(id,token_hash,requested_changes,expires_at)
VALUES('31000000-0000-4000-8000-000000000033',NULL,'[]',clock_timestamp()+interval '1 day');
INSERT INTO intake.correction_draft_attachments(id,draft_id,original_filename_encrypted,media_type,size_bytes,sha256,object_key,upload_status,scan_status)
VALUES('31000000-0000-4000-8000-000000000031','31000000-0000-4000-8000-000000000033',decode('00','hex'),'text/plain',:'correction_size',:'correction_sha','uploads/correction.txt','FINALIZED','PENDING');
INSERT INTO intake.contact_requests(id,category,name_encrypted,email_hash,email_encrypted,subject,message_encrypted,status,receipt_token_hash)
VALUES('31000000-0000-4000-8000-000000000040','GENERAL',decode('00','hex'),repeat('8',64),decode('00','hex'),'<strong>Event & contact</strong>',decode('00','hex'),'RECEIVED',repeat('9',64));
INSERT INTO intake.subscriptions(id,email_hash,email_encrypted,topics,frequency,locale,status,management_token_hash) VALUES
 ('31000000-0000-4000-8000-000000000020',repeat('a',64),:'pending_email','[{"scopeType":"GLOBAL"}]','IMMEDIATE','ko-KR','PENDING',repeat('b',64)),
 ('31000000-0000-4000-8000-000000000021',repeat('c',64),:'active_email','[{"scopeType":"GLOBAL"}]','IMMEDIATE','ko-KR','ACTIVE',repeat('d',64));

INSERT INTO ops.source_registry(source_id,display_name,connector_type,owner_team,enabled,schedule_cron,legal_status,configuration)
VALUES('event-source','Event Source','HTTP','EVENT',true,'0 * * * *','APPROVED','{}');
INSERT INTO ops.schema_drifts(id,source_id,detected_at,fingerprint_after,status,impact)
VALUES('31000000-0000-4000-8000-000000000050','event-source',clock_timestamp(),repeat('e',64),'OPEN','HIGH');
INSERT INTO core.rule_versions(id,rule_id,version,name,description,configuration,code_digest,status)
VALUES('31000000-0000-4000-8000-000000000060','event-rule','1.0.0','Event rule','Event rule','{}',repeat('f',64),'DRAFT');
INSERT INTO core.rule_runs(id,rule_version_id,run_key,input_snapshot_at,input_digest,started_at,completed_at,status)
VALUES('31000000-0000-4000-8000-000000000061','31000000-0000-4000-8000-000000000060','event-run',clock_timestamp(),repeat('1',64),clock_timestamp(),clock_timestamp(),'SUCCEEDED');
INSERT INTO core.anomaly_signals(id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity,status,explanation,calculation)
VALUES('31000000-0000-4000-8000-000000000062','31000000-0000-4000-8000-000000000061','31000000-0000-4000-8000-000000000060','EVENT','CASE','31000000-0000-4000-8000-000000000004','HIGH','NEW','{}','{}');
INSERT INTO ops.agent_runs(id,case_id,agent_type,objective,evidence_scope_ids,provider_policy,status,input_snapshot_hash,output_payload,output_schema_version,max_cost,actual_cost,completed_at,created_by)
VALUES('31000000-0000-4000-8000-000000000070','31000000-0000-4000-8000-000000000004','skeptic','Event agent','[]','LOCAL_ONLY','SUCCEEDED',repeat('2',64),:'agent_output','v1',10,1,clock_timestamp(),'31000000-0000-4000-8000-000000000001');
INSERT INTO ops.agent_suggestions(id,agent_run_id,case_id,suggestion_type,payload,evidence_ids,citation_checks,status)
VALUES('31000000-0000-4000-8000-000000000071','31000000-0000-4000-8000-000000000070','31000000-0000-4000-8000-000000000004','EVENT','{}','[]','[]','PENDING');
INSERT INTO ops.audit_events(id,occurred_at,actor_type,actor_id,action,object_type,object_id,outcome,request_id,details,event_hash)
VALUES('31000000-0000-4000-8000-000000000080',clock_timestamp(),'USER','event-user','event.action','case','31000000-0000-4000-8000-000000000004','SUCCESS','31000000-0000-4000-8000-000000000081','{}',repeat('3',64));
INSERT INTO ops.audit_exports(id,requested_by,from_at,to_at,format,scope,reason,watermark_policy,status,expires_at)
VALUES('31000000-0000-4000-8000-000000000082','31000000-0000-4000-8000-000000000001',clock_timestamp()-interval '1 day',clock_timestamp()+interval '1 minute','JSONL','GLOBAL','Event audit export','ACTOR_AND_TIME','QUEUED',clock_timestamp()+interval '1 day');
INSERT INTO public.datasets(id,title,description,format,coverage,license,updated_at)
VALUES('event-dataset','Event Dataset','Event dataset export','PARQUET','{}','CC-BY-4.0',clock_timestamp());
INSERT INTO intake.dataset_export_requests(id,request_token_hash,dataset_id,format,filters,status,expires_at)
VALUES('31000000-0000-4000-8000-000000000090',repeat('4',64),'event-dataset','PARQUET','{}','QUEUED',clock_timestamp()+interval '1 day');

SELECT ops.enqueue_outbox('agent_run','31000000-0000-4000-8000-000000000070',1,'agent.run_completed.v1',jsonb_build_object('agent_run_id','31000000-0000-4000-8000-000000000070','case_id','31000000-0000-4000-8000-000000000004','output_digest',:'agent_digest','status','SUCCEEDED'),clock_timestamp());
SELECT ops.enqueue_outbox('attachment','31000000-0000-4000-8000-000000000031',1,'attachment.correction_scan_requested.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','finalizeCorrectionAttachment','requestId','31000000-0000-4000-8000-0000000000a1','request_id','31000000-0000-4000-8000-0000000000a1'),clock_timestamp());
SELECT ops.enqueue_outbox('attachment','31000000-0000-4000-8000-000000000012',1,'attachment.response_scan_requested.v1',jsonb_build_object('actor_id','anonymous','attachmentId','31000000-0000-4000-8000-000000000012','occurred_at','2026-07-12T00:00:00Z','operation_id','finalizeResponseAttachment','requestToken','redacted','request_id','31000000-0000-4000-8000-0000000000a2'),clock_timestamp());
SELECT ops.enqueue_outbox('audit_export','31000000-0000-4000-8000-000000000082',1,'audit.export_requested.v1',jsonb_build_object('auditExportId','31000000-0000-4000-8000-000000000082','requestedBy','31000000-0000-4000-8000-000000000001','from','2026-07-11T00:00:00Z','to','2026-07-13T00:00:00Z','format','JSONL','scope','GLOBAL','reason','Event audit export','watermarkPolicy','ACTOR_AND_TIME','expiresAt','2026-07-13T00:00:00Z'),clock_timestamp());
SELECT ops.enqueue_outbox('signal','31000000-0000-4000-8000-000000000062',1,'detection.signal_created.v1',jsonb_build_object('rule_version_id','31000000-0000-4000-8000-000000000060','signal_id','31000000-0000-4000-8000-000000000062','target_id','31000000-0000-4000-8000-000000000004'),clock_timestamp());
SELECT ops.enqueue_outbox('dataset_export','31000000-0000-4000-8000-000000000090',1,'export.dataset_requested.v1',jsonb_build_object('actor_id','anonymous','dataset_id','event-dataset','occurred_at','2026-07-12T00:00:00Z','operation_id','createDatasetExport','request_id','31000000-0000-4000-8000-0000000000a3'),clock_timestamp());
SELECT ops.enqueue_outbox('schema_drift','31000000-0000-4000-8000-000000000050',1,'source.schema_drift_detected.v1',jsonb_build_object('fingerprint_after',repeat('e',64),'schema_drift_id','31000000-0000-4000-8000-000000000050','source_id','event-source'),clock_timestamp());
SQL

# Commit the submission authority before the workflow consumer runs.  The
# entirely absent reciprocal ownership tuple must commit at origin; migration
# 0039 MATCH SIMPLE is what permits this pre-materialization state.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
BEGIN;
SET LOCAL TIME ZONE 'UTC';
DO $response_submission_v2$
DECLARE
  v_submission_id constant uuid :=
    '31000000-0000-4000-8000-000000000011';
  v_request_id constant uuid :=
    '31000000-0000-4000-8000-000000000010';
  v_receipt_session_id constant uuid :=
    '31000000-0000-4000-8000-000000000027';
  v_receipt_id constant uuid :=
    '31000000-0000-4000-8000-000000000034';
  v_submitted_at timestamptz:=clock_timestamp();
  v_request_binding_digest char(64);
  v_consent jsonb:='{}'::jsonb;
  v_consent_digest char(64);
  v_receipt_payload jsonb;
  v_receipt_digest char(64);
  v_event_payload jsonb;
  v_domain_event_id uuid;
  v_notification_event_id uuid;
  v_workflow_event_id uuid;
  v_workflow_envelope_digest char(64);
  v_audit_event_id uuid;
  v_idempotency_digest char(64):=repeat('6',64);
  v_request_digest char(64):=repeat('7',64);
BEGIN
  IF current_setting('session_replication_role')<>'origin' THEN
    RAISE EXCEPTION 'response submission fixture must run at origin';
  END IF;
  SELECT response_request_binding_digest
  INTO STRICT v_request_binding_digest
  FROM editorial.response_request_sent_receipts
  WHERE id='31000000-0000-4000-8000-000000000014'
    AND response_request_id=v_request_id
    AND request_version=2;
  v_consent_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_consent),'sha256'
  ),'hex');
  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','response-submission-receipt.v3',
    'responseSubmissionId',v_submission_id,
    'responseRequestId',v_request_id,'responseRequestVersion',2,
    'responseRequestBindingDigest',btrim(v_request_binding_digest),
    'draftVersion',1,'submissionSha256',repeat('4',64),
    'publicationConsentSha256',btrim(v_consent_digest),
    'receiptVersion',1,'submittedAt',v_submitted_at
  );
  v_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_receipt_payload),'sha256'
  ),'hex');

  INSERT INTO intake.response_submissions(
    id,response_request_id,draft_version,submission_sha256,answers_encrypted,
    publication_consent,status,submitted_at,receipt_token_hash,
    receipt_version,receipt_digest,receipt_updated_at
  ) VALUES(
    v_submission_id,v_request_id,1,repeat('4',64),decode('00','hex'),
    v_consent,'SUBMITTED',v_submitted_at,repeat('5',64),1,
    v_receipt_digest,v_submitted_at
  );
  INSERT INTO intake.submission_sessions(
    id,token_hash,session_kind,scope_type,scope_id,bff_issuer,status,
    issued_at,expires_at
  ) VALUES(
    v_receipt_session_id,repeat('0',64),'RESPONSE_RECEIPT',
    'RESPONSE_SUBMISSION',v_submission_id,'response-portal','ACTIVE',
    v_submitted_at,v_submitted_at+interval '1 day'
  );

  v_event_payload:=jsonb_build_object(
    'responseSubmissionId',v_submission_id,
    'responseRequestId',v_request_id,'responseRequestVersion',2,
    'responseRequestBindingDigest',btrim(v_request_binding_digest),
    'submissionSha256',repeat('4',64),'receiptVersion',1,
    'receiptDigest',btrim(v_receipt_digest),'submittedAt',v_submitted_at
  );
  v_domain_event_id:=ops.enqueue_outbox(
    'response_submission',v_submission_id::text,1,
    'response.submitted.v2',v_event_payload,v_submitted_at
  );
  v_notification_event_id:=ops.enqueue_outbox(
    'response_submission',v_submission_id::text,1,
    'notification.response_submitted.v2',v_event_payload,v_submitted_at
  );
  v_workflow_event_id:=ops.enqueue_outbox(
    'response_submission',v_submission_id::text,1,
    'workflow.response_submitted.v2',v_event_payload,v_submitted_at
  );
  v_workflow_envelope_digest:=
    ops.r6d_outbox_envelope_digest_v1(v_workflow_event_id);
  v_audit_event_id:=ops.append_audit_event(
    'response-submission:'||v_submission_id::text,
    'SERVICE','submission-api',v_receipt_session_id,
    'response.submit','ResponseSubmission',v_submission_id::text,
    'responses.submit','SUCCESS',NULL,
    '31000000-0000-4000-8000-000000000035',
    jsonb_build_object(
      'fixture','event-consumer-test-only',
      'receiptDigest',btrim(v_receipt_digest),
      'workflowEventId',v_workflow_event_id,
      'workflowEventEnvelopeDigest',btrim(v_workflow_envelope_digest)
    )
  );
  UPDATE intake.response_submissions
  SET submission_outbox_event_id=v_workflow_event_id,
      submission_event_envelope_digest=v_workflow_envelope_digest,
      submission_idempotency_key_sha256=v_idempotency_digest,
      submission_request_digest=v_request_digest,
      receipt_session_id=v_receipt_session_id
  WHERE id=v_submission_id;
  INSERT INTO intake.response_submission_receipts_v3(
    receipt_id,response_submission_id,response_request_id,
    response_request_version,response_request_binding_digest,draft_version,
    submission_sha256,publication_consent_sha256,receipt_version,
    receipt_digest,receipt_session_id,receipt_session_expires_at,
    domain_event_id,notification_event_id,workflow_event_id,
    workflow_event_envelope_digest,audit_event_id,idempotency_key_sha256,
    request_digest,submitted_at
  ) VALUES(
    v_receipt_id,v_submission_id,v_request_id,2,v_request_binding_digest,1,
    repeat('4',64),v_consent_digest,1,v_receipt_digest,v_receipt_session_id,
    v_submitted_at+interval '1 day',v_domain_event_id,
    v_notification_event_id,v_workflow_event_id,v_workflow_envelope_digest,
    v_audit_event_id,v_idempotency_digest,v_request_digest,v_submitted_at
  );

  IF num_nonnulls(
       (SELECT editorial_response_id FROM intake.response_submissions
        WHERE id=v_submission_id),
       (SELECT owned_intake_event_id FROM intake.response_submissions
        WHERE id=v_submission_id),
       (SELECT owned_intake_event_envelope_digest FROM intake.response_submissions
        WHERE id=v_submission_id),
       (SELECT owned_intake_receipt_digest FROM intake.response_submissions
        WHERE id=v_submission_id)
     )<>0 THEN
    RAISE EXCEPTION 'response submission pre-materialization tuple not empty';
  END IF;
END
$response_submission_v2$;
COMMIT;

DO $response_submission_v2_committed$
BEGIN
  IF current_setting('session_replication_role')<>'origin' OR NOT EXISTS(
    SELECT 1
    FROM intake.response_submissions AS submission
    JOIN editorial.response_requests AS request
      ON request.id=submission.response_request_id
    JOIN editorial.response_request_sent_receipts AS sent
      ON sent.response_request_id=request.id
    JOIN intake.response_submission_receipts_v3 AS receipt
      ON receipt.response_submission_id=submission.id
     AND receipt.response_request_id=request.id
     AND receipt.response_request_version=request.version
     AND receipt.response_request_binding_digest=
       sent.response_request_binding_digest
     AND receipt.submission_sha256=submission.submission_sha256
     AND receipt.receipt_version=submission.receipt_version
     AND receipt.receipt_digest=submission.receipt_digest
     AND receipt.submitted_at=submission.submitted_at
    JOIN ops.outbox AS domain_event
      ON domain_event.id=receipt.domain_event_id
     AND domain_event.event_type='response.submitted.v2'
    JOIN ops.outbox AS notification_event
      ON notification_event.id=receipt.notification_event_id
     AND notification_event.event_type='notification.response_submitted.v2'
    JOIN ops.outbox AS workflow_event
      ON workflow_event.id=receipt.workflow_event_id
     AND workflow_event.event_type='workflow.response_submitted.v2'
    WHERE submission.id='31000000-0000-4000-8000-000000000011'
      AND request.id='31000000-0000-4000-8000-000000000010'
      AND request.version=2
      AND submission.status='SUBMITTED'
      AND num_nonnulls(
        submission.editorial_response_id,submission.owned_intake_event_id,
        submission.owned_intake_event_envelope_digest,
        submission.owned_intake_receipt_digest
      )=0
      AND submission.submission_outbox_event_id=workflow_event.id
      AND submission.submission_event_envelope_digest=
        receipt.workflow_event_envelope_digest
      AND receipt.workflow_event_envelope_digest=
        ops.r6d_outbox_envelope_digest_v1(workflow_event.id)
      AND domain_event.aggregate_type='response_submission'
      AND notification_event.aggregate_type='response_submission'
      AND workflow_event.aggregate_type='response_submission'
      AND domain_event.aggregate_id=submission.id::text
      AND notification_event.aggregate_id=submission.id::text
      AND workflow_event.aggregate_id=submission.id::text
      AND domain_event.aggregate_version=submission.receipt_version
      AND notification_event.aggregate_version=submission.receipt_version
      AND workflow_event.aggregate_version=submission.receipt_version
      AND domain_event.payload=notification_event.payload
      AND notification_event.payload=workflow_event.payload
      AND (SELECT count(*) FROM jsonb_object_keys(workflow_event.payload))=8
      AND workflow_event.payload=jsonb_build_object(
        'responseSubmissionId',submission.id,
        'responseRequestId',request.id,
        'responseRequestVersion',request.version,
        'responseRequestBindingDigest',btrim(sent.response_request_binding_digest),
        'submissionSha256',btrim(submission.submission_sha256),
        'receiptVersion',submission.receipt_version,
        'receiptDigest',btrim(submission.receipt_digest),
        'submittedAt',submission.submitted_at
      )
  ) THEN
    RAISE EXCEPTION 'committed response submission v2 authority invalid';
  END IF;
END
$response_submission_v2_committed$;
SQL

# SPEC-CONFLICT-030 runtime oracle.  Start every materializer transaction with
# immediate constraints so only the public 0039 wrapper can defer the two
# reciprocal FKs.  The focused negative transactions stay at origin and roll
# back; no replication-role bypass is used anywhere in this oracle.
response_materialization_graph_fingerprint() {
  docker exec -i "$container" psql -qAt -v ON_ERROR_STOP=1 -U postgres \
    -d "$database" <<'SQL'
WITH target AS (
  SELECT * FROM intake.response_submissions
  WHERE id='31000000-0000-4000-8000-000000000011'
), graph AS (
  SELECT jsonb_build_object(
    'submission',to_jsonb(target),
    'responses',COALESCE((
      SELECT jsonb_agg(to_jsonb(response) ORDER BY response.id)
      FROM editorial.responses AS response
      WHERE response.submission_id=target.id
         OR response.id=target.editorial_response_id
    ),'[]'::jsonb),
    'originReceipts',COALESCE((
      SELECT jsonb_agg(to_jsonb(receipt) ORDER BY receipt.receipt_id)
      FROM editorial.response_submission_origin_receipts_v2 AS receipt
      WHERE receipt.response_submission_id=target.id
    ),'[]'::jsonb),
    'submissionReceipts',COALESCE((
      SELECT jsonb_agg(to_jsonb(receipt) ORDER BY receipt.receipt_id)
      FROM intake.response_submission_receipts_v3 AS receipt
      WHERE receipt.response_submission_id=target.id
    ),'[]'::jsonb),
    'audit',COALESCE((
      SELECT jsonb_agg(to_jsonb(event) ORDER BY event.occurred_at,event.id)
      FROM ops.audit_events AS event
      WHERE event.object_id=target.id::text
        AND event.action IN ('response.submit','response.materialize')
    ),'[]'::jsonb),
    'outbox',COALESCE((
      SELECT jsonb_agg(to_jsonb(event) ORDER BY event.occurred_at,event.id)
      FROM ops.outbox AS event
      WHERE event.aggregate_type='response_submission'
        AND event.aggregate_id=target.id::text
    ),'[]'::jsonb)
  ) AS value
  FROM target
)
SELECT encode(
  extensions.digest(ops.canonical_jsonb_v1(graph.value),'sha256'),'hex'
)
FROM graph;
SQL
}

pre_materialization_fingerprint="$(response_materialization_graph_fingerprint)"
if [[ ! "$pre_materialization_fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
  echo "response materialization preflight fingerprint invalid" >&2
  exit 1
fi

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $reciprocal_catalog$
DECLARE
  v_fk_count integer;
  v_check_count integer;
BEGIN
  WITH expected(
    constraint_name,source_schema,source_table,target_schema,target_table
  ) AS (VALUES
    (
      'response_submissions_editorial_response_reciprocal_fk',
      'intake','response_submissions','editorial','responses'
    ),(
      'editorial_responses_submission_reciprocal_fk',
      'editorial','responses','intake','response_submissions'
    )
  )
  SELECT count(*) INTO v_fk_count
  FROM expected
  JOIN pg_constraint AS catalog
    ON catalog.conname=expected.constraint_name
   AND catalog.contype='f'
   AND catalog.confmatchtype='s'
   AND catalog.confdeltype='r'
   AND catalog.condeferrable
   AND catalog.condeferred
   AND NOT catalog.convalidated
  JOIN pg_class AS source_relation
    ON source_relation.oid=catalog.conrelid
   AND source_relation.relname=expected.source_table
  JOIN pg_namespace AS source_namespace
    ON source_namespace.oid=source_relation.relnamespace
   AND source_namespace.nspname=expected.source_schema
  JOIN pg_class AS target_relation
    ON target_relation.oid=catalog.confrelid
   AND target_relation.relname=expected.target_table
  JOIN pg_namespace AS target_namespace
    ON target_namespace.oid=target_relation.relnamespace
   AND target_namespace.nspname=expected.target_schema;
  IF v_fk_count<>2 THEN
    RAISE EXCEPTION 'SPEC-CONFLICT-030 reciprocal FK catalog invalid: %',
      v_fk_count;
  END IF;

  WITH expected(constraint_name,source_schema,source_table) AS (VALUES
    (
      'response_submissions_reciprocal_nullness_ck',
      'intake','response_submissions'
    ),(
      'editorial_responses_reciprocal_nullness_ck',
      'editorial','responses'
    )
  )
  SELECT count(*) INTO v_check_count
  FROM expected
  JOIN pg_constraint AS catalog
    ON catalog.conname=expected.constraint_name
   AND catalog.contype='c'
   AND catalog.convalidated
   AND NOT catalog.condeferrable
  JOIN pg_class AS source_relation
    ON source_relation.oid=catalog.conrelid
   AND source_relation.relname=expected.source_table
  JOIN pg_namespace AS source_namespace
    ON source_namespace.oid=source_relation.relnamespace
   AND source_namespace.nspname=expected.source_schema;
  IF v_check_count<>2 THEN
    RAISE EXCEPTION
      'SPEC-CONFLICT-030 reciprocal nullness CHECK catalog invalid: %',
      v_check_count;
  END IF;
END
$reciprocal_catalog$;

BEGIN;
SET CONSTRAINTS ALL IMMEDIATE;
DO $partial_null_negative$
DECLARE
  v_constraint text;
BEGIN
  BEGIN
    INSERT INTO editorial.responses(
      id,case_id,response_request_id,submission_id,party_name,submitted_at,
      full_text_encrypted,publication_consent,editorial_status,version
    )
    SELECT
      '31000000-0000-4000-8000-000000000036',request.case_id,request.id,
      submission.id,request.party_name,submission.submitted_at,
      submission.answers_encrypted,submission.publication_consent,'PENDING',1
    FROM intake.response_submissions AS submission
    JOIN editorial.response_requests AS request
      ON request.id=submission.response_request_id
    WHERE submission.id='31000000-0000-4000-8000-000000000011';
    RAISE EXCEPTION 'partial-null reciprocal insert unexpectedly succeeded';
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS v_constraint=CONSTRAINT_NAME;
    IF SQLSTATE<>'23514' OR v_constraint NOT IN (
      'editorial_responses_owned_intake_shape_ck',
      'editorial_responses_reciprocal_nullness_ck'
    ) THEN
      RAISE;
    END IF;
  END;
  IF EXISTS(
    SELECT 1 FROM editorial.responses
    WHERE id='31000000-0000-4000-8000-000000000036'
  ) THEN
    RAISE EXCEPTION 'partial-null reciprocal insert leaked mutation';
  END IF;
END
$partial_null_negative$;
ROLLBACK;

BEGIN;
SET CONSTRAINTS ALL IMMEDIATE;
DO $one_sided_negative$
DECLARE
  v_constraint text;
BEGIN
  BEGIN
    INSERT INTO editorial.responses(
      id,case_id,response_request_id,submission_id,party_name,submitted_at,
      full_text_encrypted,publication_consent,editorial_status,version,
      submission_receipt_version,submission_receipt_digest,
      owned_intake_event_id,owned_intake_event_envelope_digest,
      owned_intake_receipt_digest,party_type,party_entity_id,
      response_content_sha256,publication_consent_sha256,
      organization_identity_status,publication_form
    )
    SELECT
      '31000000-0000-4000-8000-000000000037',request.case_id,request.id,
      submission.id,request.party_name,submission.submitted_at,
      submission.answers_encrypted,submission.publication_consent,'PENDING',1,
      submission.receipt_version,submission.receipt_digest,
      receipt.workflow_event_id,receipt.workflow_event_envelope_digest,
      repeat('e',64),request.party_type,request.party_entity_id,
      encode(extensions.digest(submission.answers_encrypted,'sha256'),'hex'),
      encode(extensions.digest(
        ops.canonical_jsonb_v1(submission.publication_consent),'sha256'
      ),'hex'),'UNVERIFIED','INTERNAL_ONLY'
    FROM intake.response_submissions AS submission
    JOIN editorial.response_requests AS request
      ON request.id=submission.response_request_id
    JOIN intake.response_submission_receipts_v3 AS receipt
      ON receipt.response_submission_id=submission.id
    WHERE submission.id='31000000-0000-4000-8000-000000000011';
    RAISE EXCEPTION 'one-sided reciprocal insert unexpectedly succeeded';
  EXCEPTION WHEN foreign_key_violation THEN
    GET STACKED DIAGNOSTICS v_constraint=CONSTRAINT_NAME;
    IF SQLSTATE<>'23503'
       OR v_constraint<>'editorial_responses_submission_reciprocal_fk' THEN
      RAISE;
    END IF;
  END;
  IF EXISTS(
    SELECT 1 FROM editorial.responses
    WHERE id='31000000-0000-4000-8000-000000000037'
  ) THEN
    RAISE EXCEPTION 'one-sided reciprocal insert leaked mutation';
  END IF;
END
$one_sided_negative$;
ROLLBACK;
SQL

if [[ "$(response_materialization_graph_fingerprint)" \
      != "$pre_materialization_fingerprint" ]]; then
  echo "pre-materialization reciprocal negative probe mutated graph" >&2
  exit 1
fi

# Rust time 0.3 is built without serde-human-readable, so OffsetDateTime in
# workflow_response_materialization.rs canonicalizes as its exact nine-number
# serde tuple.  The submission transaction is pinned to UTC above; the normal
# worker replay later is an independent sensor for this request digest.
materializer_input="$(
  docker exec -i "$container" psql -qAt -F '|' -v ON_ERROR_STOP=1 \
    -U postgres -d "$database" <<'SQL'
WITH truth AS (
  SELECT
    event.id AS source_event_id,
    btrim(ops.r6d_outbox_envelope_digest_v1(event.id))
      AS source_event_envelope_digest,
    (event.payload->>'responseSubmissionId')::uuid
      AS response_submission_id,
    (event.payload->>'responseRequestId')::uuid AS response_request_id,
    (event.payload->>'responseRequestVersion')::bigint
      AS response_request_version,
    event.payload->>'responseRequestBindingDigest'
      AS response_request_binding_digest,
    event.payload->>'submissionSha256' AS submission_sha256,
    (event.payload->>'receiptVersion')::bigint AS receipt_version,
    event.payload->>'receiptDigest' AS receipt_digest,
    event.payload->>'submittedAt' AS submitted_at_text,
    (event.payload->>'submittedAt')::timestamptz AS submitted_at
  FROM ops.outbox AS event
  JOIN intake.response_submission_receipts_v3 AS receipt
    ON receipt.workflow_event_id=event.id
   AND receipt.response_submission_id=
     (event.payload->>'responseSubmissionId')::uuid
  WHERE event.event_type='workflow.response_submitted.v2'
    AND event.aggregate_type='response_submission'
    AND event.aggregate_id='31000000-0000-4000-8000-000000000011'
    AND event.payload->>'submittedAt' ~ '(Z|[+]00(:00(:00)?)?)$'
), wire AS (
  SELECT truth.*,
    truth.submitted_at AT TIME ZONE 'UTC' AS submitted_at_utc,
    encode(extensions.digest(convert_to(
      'response-submission-materializer:'||truth.source_event_id::text,
      'UTF8'
    ),'sha256'),'hex') AS idempotency_key_sha256
  FROM truth
), bound AS (
  SELECT wire.*,
    encode(extensions.digest(ops.canonical_jsonb_v1(jsonb_build_object(
      'sourceEventId',wire.source_event_id,
      'sourceEventEnvelopeDigest',wire.source_event_envelope_digest,
      'responseSubmissionId',wire.response_submission_id,
      'responseRequestId',wire.response_request_id,
      'responseRequestVersion',wire.response_request_version,
      'responseRequestBindingDigest',wire.response_request_binding_digest,
      'submissionSha256',wire.submission_sha256,
      'receiptVersion',wire.receipt_version,
      'receiptDigest',wire.receipt_digest,
      'submittedAt',jsonb_build_array(
        extract(year FROM wire.submitted_at_utc)::integer,
        extract(doy FROM wire.submitted_at_utc)::integer,
        extract(hour FROM wire.submitted_at_utc)::integer,
        extract(minute FROM wire.submitted_at_utc)::integer,
        floor(extract(second FROM wire.submitted_at_utc))::integer,
        mod(
          extract(microseconds FROM wire.submitted_at_utc)::bigint,1000000
        )*1000,
        0,0,0
      )
    )),'sha256'),'hex') AS request_digest
  FROM wire
)
SELECT
  source_event_id,source_event_envelope_digest,response_submission_id,
  response_request_id,response_request_version,response_request_binding_digest,
  submission_sha256,receipt_version,receipt_digest,submitted_at_text,
  idempotency_key_sha256,request_digest
FROM bound;
SQL
)"

IFS='|' read -r \
  materializer_source_event_id materializer_source_event_envelope_digest \
  materializer_submission_id materializer_request_id \
  materializer_request_version materializer_request_binding_digest \
  materializer_submission_sha256 materializer_receipt_version \
  materializer_receipt_digest materializer_submitted_at \
  materializer_idempotency_key materializer_request_digest \
  <<<"$materializer_input"

if [[ ! "$materializer_source_event_id" =~ ^[0-9a-f-]{36}$ ]] \
  || [[ ! "$materializer_submission_id" =~ ^[0-9a-f-]{36}$ ]] \
  || [[ ! "$materializer_request_id" =~ ^[0-9a-f-]{36}$ ]] \
  || [[ ! "$materializer_source_event_envelope_digest" =~ ^[0-9a-f]{64}$ ]] \
  || [[ ! "$materializer_request_binding_digest" =~ ^[0-9a-f]{64}$ ]] \
  || [[ ! "$materializer_submission_sha256" =~ ^[0-9a-f]{64}$ ]] \
  || [[ ! "$materializer_receipt_digest" =~ ^[0-9a-f]{64}$ ]] \
  || [[ ! "$materializer_idempotency_key" =~ ^[0-9a-f]{64}$ ]] \
  || [[ ! "$materializer_request_digest" =~ ^[0-9a-f]{64}$ ]] \
  || [[ ! "$materializer_request_version" =~ ^[1-9][0-9]*$ ]] \
  || [[ ! "$materializer_receipt_version" =~ ^[1-9][0-9]*$ ]] \
  || [[ -z "$materializer_submitted_at" ]]; then
  echo "response materializer DB-truth input invalid" >&2
  exit 1
fi

run_response_materializer_call() {
  local result_name="$1"
  local request_digest="$2"
  timeout 60s docker exec -i "$container" psql -qAt \
    -v ON_ERROR_STOP=1 -U postgres -d "$database" \
    -v "source_event_id=$materializer_source_event_id" \
    -v "source_event_envelope_digest=$materializer_source_event_envelope_digest" \
    -v "submission_id=$materializer_submission_id" \
    -v "request_id=$materializer_request_id" \
    -v "request_version=$materializer_request_version" \
    -v "request_binding_digest=$materializer_request_binding_digest" \
    -v "submission_sha256=$materializer_submission_sha256" \
    -v "receipt_version=$materializer_receipt_version" \
    -v "receipt_digest=$materializer_receipt_digest" \
    -v "submitted_at=$materializer_submitted_at" \
    -v "idempotency_key=$materializer_idempotency_key" \
    -v "request_digest=$request_digest" \
    >"$work/${result_name}.out" 2>"$work/${result_name}.err" <<'SQL'
BEGIN;
SET CONSTRAINTS ALL IMMEDIATE;
SET ROLE gurine_workflow_worker;
SET LOCAL statement_timeout='45s';
SET LOCAL lock_timeout='45s';
WITH called AS MATERIALIZED (
  SELECT editorial.materialize_response_submission_v2(
    ROW(
      :'source_event_id'::uuid,:'source_event_envelope_digest'::char(64),
      :'submission_id'::uuid,:'request_id'::uuid,:'request_version'::bigint,
      :'request_binding_digest'::char(64),:'submission_sha256'::char(64),
      :'receipt_version'::bigint,:'receipt_digest'::char(64),
      :'submitted_at'::timestamptz
    )::editorial.response_submission_intake_materialize_v1,
    NULL::uuid,:'idempotency_key'::char(64),:'request_digest'::char(64)
  ) AS receipt
)
SELECT CASE (called.receipt).disposition
  WHEN 'APPLIED' THEN 'MATERIALIZED'
  WHEN 'NO_OP_ALREADY_MATERIALIZED' THEN 'NO_OP'
  ELSE 'INVALID_DISPOSITION:'||(called.receipt).disposition
END
FROM called;
COMMIT;
SQL
}

materializer_pids=()
for ordinal in $(seq -w 1 64); do
  run_response_materializer_call \
    "response-materializer-concurrent-${ordinal}" \
    "$materializer_request_digest" &
  materializer_pids+=("$!")
done

materializer_failures=0
for materializer_pid in "${materializer_pids[@]}"; do
  if ! wait "$materializer_pid"; then
    materializer_failures=$((materializer_failures + 1))
  fi
done
if [[ "$materializer_failures" -ne 0 ]]; then
  echo "response materializer concurrent calls failed: $materializer_failures" >&2
  for error_file in "$work"/response-materializer-concurrent-*.err; do
    [[ ! -s "$error_file" ]] || sed -n '1,12p' "$error_file" >&2
  done
  exit 1
fi

materialized_count=0
no_op_count=0
unexpected_count=0
for result_file in "$work"/response-materializer-concurrent-*.out; do
  materializer_result="$(<"$result_file")"
  case "$materializer_result" in
    MATERIALIZED) materialized_count=$((materialized_count + 1)) ;;
    NO_OP) no_op_count=$((no_op_count + 1)) ;;
    *) unexpected_count=$((unexpected_count + 1)) ;;
  esac
done
if [[ "$materialized_count" -ne 1 || "$no_op_count" -ne 63 \
   || "$unexpected_count" -ne 0 ]]; then
  echo "response materializer race invalid: materialized=$materialized_count no_op=$no_op_count unexpected=$unexpected_count" >&2
  exit 1
fi

run_response_materializer_call \
  response-materializer-exact-replay "$materializer_request_digest"
materializer_replay="$(<"$work/response-materializer-exact-replay.out")"
if [[ "$materializer_replay" != 'NO_OP' ]]; then
  echo "response materializer exact replay was not NO_OP" >&2
  exit 1
fi

materialized_fingerprint="$(response_materialization_graph_fingerprint)"
if [[ ! "$materialized_fingerprint" =~ ^[0-9a-f]{64}$ \
   || "$materialized_fingerprint" == "$pre_materialization_fingerprint" ]]; then
  echo "response materializer race did not install exact graph" >&2
  exit 1
fi

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
BEGIN;
SET CONSTRAINTS ALL IMMEDIATE;
SET ROLE gurine_workflow_worker;
DO $changed_digest_conflict$
DECLARE
  v_input editorial.response_submission_intake_materialize_v1;
  v_idempotency_key char(64);
  v_changed_request_digest char(64);
  v_bound record;
BEGIN
  SELECT ROW(
    event.id,ops.r6d_outbox_envelope_digest_v1(event.id),
    (event.payload->>'responseSubmissionId')::uuid,
    (event.payload->>'responseRequestId')::uuid,
    (event.payload->>'responseRequestVersion')::bigint,
    (event.payload->>'responseRequestBindingDigest')::char(64),
    (event.payload->>'submissionSha256')::char(64),
    (event.payload->>'receiptVersion')::bigint,
    (event.payload->>'receiptDigest')::char(64),
    (event.payload->>'submittedAt')::timestamptz
  )::editorial.response_submission_intake_materialize_v1 AS input_receipt,
  origin.idempotency_key_sha256 AS idempotency_key_sha256,
  CASE WHEN origin.request_digest=repeat('f',64)::char(64)
    THEN repeat('e',64)::char(64) ELSE repeat('f',64)::char(64)
  END AS changed_request_digest
  INTO STRICT v_bound
  FROM ops.outbox AS event
  JOIN editorial.response_submission_origin_receipts_v2 AS origin
    ON origin.source_event_id=event.id
  WHERE origin.response_submission_id=
    '31000000-0000-4000-8000-000000000011';
  v_input:=v_bound.input_receipt;
  v_idempotency_key:=v_bound.idempotency_key_sha256;
  v_changed_request_digest:=v_bound.changed_request_digest;

  BEGIN
    PERFORM editorial.materialize_response_submission_v2(
      v_input,NULL::uuid,v_idempotency_key,v_changed_request_digest
    );
    RAISE EXCEPTION 'changed request digest unexpectedly succeeded';
  EXCEPTION WHEN serialization_failure THEN
    IF SQLSTATE<>'40001'
       OR SQLERRM<>'response_materialization_v2_idempotency_conflict' THEN
      RAISE;
    END IF;
  END;
END
$changed_digest_conflict$;
ROLLBACK;

BEGIN;
SET CONSTRAINTS ALL IMMEDIATE;
DO $full_tuple_mismatch$
DECLARE
  v_constraint text;
  v_response_id uuid;
BEGIN
  SELECT editorial_response_id INTO STRICT v_response_id
  FROM intake.response_submissions
  WHERE id='31000000-0000-4000-8000-000000000011';
  BEGIN
    UPDATE editorial.responses
    SET submission_receipt_digest=CASE
      WHEN submission_receipt_digest=repeat('e',64)::char(64)
        THEN repeat('d',64)::char(64)
      ELSE repeat('e',64)::char(64)
    END
    WHERE id=v_response_id;
    RAISE EXCEPTION 'reciprocal full-tuple mismatch unexpectedly succeeded';
  EXCEPTION WHEN foreign_key_violation THEN
    GET STACKED DIAGNOSTICS v_constraint=CONSTRAINT_NAME;
    IF SQLSTATE<>'23503' OR v_constraint NOT IN (
      'editorial_responses_submission_reciprocal_fk',
      'response_submissions_editorial_response_reciprocal_fk'
    ) THEN
      RAISE;
    END IF;
  END;
END
$full_tuple_mismatch$;
ROLLBACK;

BEGIN;
SET CONSTRAINTS ALL IMMEDIATE;
DO $delete_restriction$
DECLARE
  v_constraint text;
  v_response_id uuid;
BEGIN
  SELECT editorial_response_id INTO STRICT v_response_id
  FROM intake.response_submissions
  WHERE id='31000000-0000-4000-8000-000000000011';
  BEGIN
    DELETE FROM editorial.responses WHERE id=v_response_id;
    RAISE EXCEPTION 'reciprocal referenced response delete unexpectedly succeeded';
  EXCEPTION WHEN foreign_key_violation THEN
    GET STACKED DIAGNOSTICS v_constraint=CONSTRAINT_NAME;
    IF SQLSTATE<>'23503' OR v_constraint NOT IN (
      'response_submissions_editorial_response_id_fkey',
      'response_submissions_editorial_response_reciprocal_fk'
    ) THEN
      RAISE;
    END IF;
  END;
END
$delete_restriction$;
ROLLBACK;
SQL

if [[ "$(response_materialization_graph_fingerprint)" \
      != "$materialized_fingerprint" ]]; then
  echo "response materializer conflict/negative probe mutated graph" >&2
  exit 1
fi

postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_INSTANCE_ID="event-test" SCHEDULER_ONCE=true target/debug/gurine-scheduler

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE queue='workflow-worker' AND job_type='EVENT_DELIVERY' AND status='QUEUED';
  IF actual <> 8 THEN RAISE EXCEPTION 'queued workflow event jobs %, expected 8',actual; END IF;
  SELECT count(*) INTO actual FROM ops.inbox WHERE consumer='workflow-worker';
  IF actual <> 7 THEN RAISE EXCEPTION 'dispatched workflow inbox %, expected 7',actual; END IF;
  SELECT count(*) INTO actual
  FROM ops.inbox AS inbox
  JOIN ops.outbox AS event ON event.id=inbox.event_id
  WHERE inbox.consumer='response-submission-materializer'
    AND event.event_type='workflow.response_submitted.v2';
  IF actual <> 1 THEN
    RAISE EXCEPTION 'dispatched response materializer inbox %, expected 1',actual;
  END IF;
  SELECT count(*) INTO actual
  FROM ops.inbox AS inbox
  JOIN ops.outbox AS event ON event.id=inbox.event_id
  WHERE inbox.consumer IN ('submission-projector','audit-indexer')
    AND event.event_type='editorial.response_materialized.v2';
  IF actual <> 2 THEN
    RAISE EXCEPTION 'dispatched response projection inboxes %, expected 2',actual;
  END IF;
END $$;
SET ROLE gurine_workflow_worker;
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.jobs j
  LEFT JOIN ops.queue_controls q ON q.queue_name=j.queue
  WHERE j.queue='workflow-worker' AND j.status='QUEUED' AND j.run_after<=clock_timestamp()
    AND COALESCE(q.state,'RUNNING')='RUNNING';
  IF actual <> 8 THEN RAISE EXCEPTION 'workflow-role claimable event jobs %, expected 8',actual; END IF;
END $$;
RESET ROLE;
SQL

response_projection_graph_before="$(response_materialization_graph_fingerprint)"
PROJECTOR_DATABASE_URL="postgresql://gurine_public_projector:projector_test@127.0.0.1:${postgres_port}/${database}" \
PROJECTOR_ONCE=true HOSTNAME="response-materialized-projection-test" \
  target/debug/gurine-projection-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $response_projection_fresh$
BEGIN
  IF (SELECT count(*)
      FROM ops.jobs AS job
      JOIN ops.job_attempts AS attempt ON attempt.job_id=job.id
      JOIN ops.inbox AS inbox
        ON inbox.consumer=job.payload->>'consumerId'
       AND inbox.event_id=(job.payload->>'eventId')::uuid
      JOIN ops.outbox AS event ON event.id=inbox.event_id
      WHERE job.queue='projection-worker'
        AND job.job_type='EVENT_DELIVERY'
        AND job.status='SUCCEEDED'
        AND job.payload->>'consumerId' IN ('submission-projector','audit-indexer')
        AND event.event_type='editorial.response_materialized.v2'
        AND inbox.processed_at IS NOT NULL
        AND inbox.result IS NOT NULL
        AND attempt.outcome='SUCCEEDED'
        AND attempt.metrics=CASE
          WHEN left(inbox.result,1)='{' THEN inbox.result::jsonb
          ELSE NULL::jsonb
        END)<>2 THEN
    RAISE EXCEPTION 'response materialized projection result invalid';
  END IF;
END
$response_projection_fresh$;

INSERT INTO ops.jobs(
  id,job_type,queue,priority,payload,dedupe_key,max_attempts
)
SELECT CASE job.payload->>'consumerId'
         WHEN 'audit-indexer'
           THEN '31800000-0000-4000-8000-000000000401'::uuid
         ELSE '31800000-0000-4000-8000-000000000402'::uuid
       END,
       'EVENT_DELIVERY','projection-worker',1,job.payload,
       'response-materialized-projection-replay:'||(job.payload->>'consumerId'),1
FROM ops.jobs AS job
WHERE job.queue='projection-worker' AND job.status='SUCCEEDED'
  AND job.payload->>'eventType'='editorial.response_materialized.v2'
  AND job.payload->>'consumerId' IN ('submission-projector','audit-indexer');
SQL

PROJECTOR_DATABASE_URL="postgresql://gurine_public_projector:projector_test@127.0.0.1:${postgres_port}/${database}" \
PROJECTOR_ONCE=true HOSTNAME="response-materialized-projection-replay-test" \
  target/debug/gurine-projection-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $response_projection_replay$
BEGIN
  IF (SELECT count(*)
      FROM ops.jobs AS job
      JOIN ops.job_attempts AS attempt ON attempt.job_id=job.id
      JOIN ops.inbox AS inbox
        ON inbox.consumer=job.payload->>'consumerId'
       AND inbox.event_id=(job.payload->>'eventId')::uuid
      WHERE job.id IN (
          '31800000-0000-4000-8000-000000000401',
          '31800000-0000-4000-8000-000000000402'
        )
        AND job.status='SUCCEEDED'
        AND attempt.outcome='SUCCEEDED'
        AND attempt.metrics=CASE
          WHEN left(inbox.result,1)='{' THEN inbox.result::jsonb
          ELSE NULL::jsonb
        END)<>2 THEN
    RAISE EXCEPTION 'response materialized projection replay invalid';
  END IF;
END
$response_projection_replay$;
SQL

response_projection_graph_after="$(response_materialization_graph_fingerprint)"
if [[ "$response_projection_graph_before" != "$response_projection_graph_after" ]]; then
  echo "response materialized projection consumers mutated owner graph" >&2
  exit 1
fi

clamav_port="$(free_port)"
PYTHONDONTWRITEBYTECODE=1 FAKE_CLAMAV_PORT="$clamav_port" python3 scripts/test-support/fake-clamav.py &
clamav_pid=$!
sleep 0.2
if ! GURINE_ENV=development WORKFLOW_DATABASE_URL="postgresql://gurine_workflow_worker:workflow_test@127.0.0.1:${postgres_port}/${database}" \
  FIELD_ENCRYPTION_KEY_CURRENT="$test_key" \
  OBJECT_STORE_ADAPTER=filesystem OBJECT_STORE_FILESYSTEM_ROOT="$work/objects" \
  CLAMAV_HOST=127.0.0.1 CLAMAV_PORT="$clamav_port" WORKFLOW_ONCE=true \
  HOSTNAME="workflow-event-test" target/debug/gurine-workflow-worker; then
  docker exec "$container" psql -U postgres -d "$database" -x -c \
    "SELECT id,payload->>'eventType' AS event_type,status,last_error_code,attempt_count FROM ops.jobs WHERE queue='workflow-worker' ORDER BY created_at,id" >&2
  exit 1
fi

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE queue='workflow-worker' AND job_type='EVENT_DELIVERY' AND status='SUCCEEDED';
  IF actual <> 8 THEN
    RAISE NOTICE 'workflow job states: %',(
      SELECT jsonb_object_agg(status,count) FROM (
        SELECT status,count(*) FROM ops.jobs WHERE queue='workflow-worker' GROUP BY status
      ) states
    );
    RAISE NOTICE 'workflow incomplete jobs: %',(
      SELECT jsonb_agg(jsonb_build_object(
        'eventType',payload->>'eventType','status',status,'errorCode',last_error_code,
        'attempts',attempt_count,'runAfter',run_after
      ) ORDER BY created_at,id)
      FROM ops.jobs WHERE queue='workflow-worker' AND status<>'SUCCEEDED'
    );
    RAISE EXCEPTION 'succeeded workflow event jobs %, expected 8',actual;
  END IF;
END $$;
SQL

# TEST_FIXTURE_ONLY: Q4 uses the response materialized by the real first
# workflow-worker pass.  The request, identity transitions, ACCESS read, and
# correction plan below all use their production owners; only the missing
# endpoint-verification producer pre-state is installed under a bounded
# replica scope, matching the existing D3 consumer fixture contract.
q4_privacy_request_id="31700000-0000-4000-8000-000000000001"
q4_contact_endpoint_id="31700000-0000-4000-8000-000000000003"
q4_correction_plan_id="31700000-0000-4000-8000-000000000021"
q4_response_id="$(
  docker exec "$container" psql -At -v ON_ERROR_STOP=1 -U postgres \
    -d "$database" -c \
    "SELECT editorial_response_id FROM intake.response_submissions WHERE id='31000000-0000-4000-8000-000000000011'"
)"
if [[ ! "$q4_response_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "Q4 materialized response id is invalid" >&2
  exit 1
fi
q4_scope_token="$(
  encrypt ops.privacy_requests_v2 scope_ciphertext \
    "$q4_privacy_request_id" privacy-request-scope \
    'TEST_FIXTURE_ONLY RESPONSE scope'
)"
q4_statement_token="$(
  encrypt ops.privacy_requests_v2 statement_ciphertext \
    "$q4_privacy_request_id" privacy-request-statement \
    'TEST_FIXTURE_ONLY party name correction statement'
)"
q4_contact_token="$(
  encrypt intake.communication_endpoints endpoint_ciphertext \
    "$q4_contact_endpoint_id" email-address q4-privacy@example.test
)"
q4_verify_reason_token="$(
  encrypt ops.privacy_request_sealed_content_v2 sealed_ciphertext \
    '31700000-0000-4000-8000-000000000012' REASON \
    'TEST_FIXTURE_ONLY Q4 identity verified'
)"
q4_start_reason_token="$(
  encrypt ops.privacy_request_sealed_content_v2 sealed_ciphertext \
    '31700000-0000-4000-8000-000000000016' REASON \
    'TEST_FIXTURE_ONLY Q4 review started'
)"
q4_approve_reason_token="$(
  encrypt ops.privacy_request_sealed_content_v2 sealed_ciphertext \
    '31700000-0000-4000-8000-000000000042' REASON \
    'TEST_FIXTURE_ONLY Q4 approved'
)"
q4_requested_party_name='Corrected Event Respondent'
q4_requested_value_token="$(
  encrypt ops.privacy_correction_plans_v1 requested_value_ciphertext \
    "$q4_correction_plan_id" privacy-correction-requested-value \
    "$q4_requested_party_name"
)"
q4_encryption_key_id="$(printf '%s' "$q4_scope_token" | cut -d. -f2)"
for q4_envelope in \
  "$q4_scope_token" "$q4_statement_token" "$q4_contact_token" \
  "$q4_verify_reason_token" "$q4_start_reason_token" \
  "$q4_approve_reason_token" "$q4_requested_value_token"; do
  q4_envelope_key_id="$(printf '%s' "$q4_envelope" | cut -d. -f2)"
  if [[ ! "$q4_encryption_key_id" =~ ^[A-Za-z0-9_-]+$ ]] ||
     [[ "$q4_envelope_key_id" != "$q4_encryption_key_id" ]]; then
    echo "Q4 fixture envelope key revision is invalid or inconsistent" >&2
    exit 1
  fi
done
q4_scope_ciphertext="$(printf '%s' "$q4_scope_token" | base64 -w0)"
q4_statement_ciphertext="$(printf '%s' "$q4_statement_token" | base64 -w0)"
q4_contact_ciphertext="$(printf '%s' "$q4_contact_token" | base64 -w0)"
q4_verify_reason_ciphertext="$(
  printf '%s' "$q4_verify_reason_token" | base64 -w0
)"
q4_start_reason_ciphertext="$(
  printf '%s' "$q4_start_reason_token" | base64 -w0
)"
q4_approve_reason_ciphertext="$(
  printf '%s' "$q4_approve_reason_token" | base64 -w0
)"
q4_requested_value_ciphertext="$(
  printf '%s' "$q4_requested_value_token" | base64 -w0
)"
q4_requested_value_sha256="$(
  printf '%s' "$q4_requested_party_name" | sha256sum | cut -d' ' -f1
)"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" -v q4_response_id="$q4_response_id" \
  -v q4_scope_ciphertext="$q4_scope_ciphertext" \
  -v q4_statement_ciphertext="$q4_statement_ciphertext" \
  -v q4_contact_ciphertext="$q4_contact_ciphertext" \
  -v q4_verify_reason_ciphertext="$q4_verify_reason_ciphertext" \
  -v q4_start_reason_ciphertext="$q4_start_reason_ciphertext" \
  -v q4_requested_value_ciphertext="$q4_requested_value_ciphertext" \
  -v q4_requested_value_sha256="$q4_requested_value_sha256" \
  -v q4_encryption_key_id="$q4_encryption_key_id" \
  <<'SQL' >/dev/null
BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SET CONSTRAINTS ALL DEFERRED;
SET LOCAL TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.q4_sha256(p_value text)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,extensions,pg_temp
AS $digest$
  SELECT encode(
    extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex'
  )::char(64)
$digest$;

CREATE FUNCTION pg_temp.q4_nul5_sha256(
  p_one text,p_two text,p_three text,p_four text,p_five text
) RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,extensions,pg_temp
AS $digest$
  SELECT encode(extensions.digest(
    convert_to(p_one,'UTF8')||decode('00','hex')||
    convert_to(p_two,'UTF8')||decode('00','hex')||
    convert_to(p_three,'UTF8')||decode('00','hex')||
    convert_to(p_four,'UTF8')||decode('00','hex')||
    convert_to(p_five,'UTF8'),'sha256'
  ),'hex')::char(64)
$digest$;

CREATE FUNCTION pg_temp.q4_reason_base64(p_label text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,pg_temp
AS $envelope$
  SELECT replace(encode(convert_to(
    'gurine-fe-v1.key-v1.'||p_label||'.cipher','UTF8'
  ),'base64'),E'\n','')
$envelope$;

-- Migration 0013 revokes PUBLIC's default function EXECUTE privilege.  Keep
-- these TEST_ONLY helpers scoped to the two service roles that call them.
GRANT EXECUTE ON FUNCTION pg_temp.q4_sha256(text)
  TO gurine_submission_api,gurine_control_api;
GRANT EXECUTE ON FUNCTION pg_temp.q4_nul5_sha256(text,text,text,text,text)
  TO gurine_submission_api;

CREATE TEMP TABLE q4_parameters(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  response_id uuid NOT NULL,
  scope_ciphertext_base64 text NOT NULL,
  statement_ciphertext_base64 text NOT NULL,
  contact_ciphertext_base64 text NOT NULL,
  verify_reason_ciphertext_base64 text NOT NULL,
  start_reason_ciphertext_base64 text NOT NULL,
  requested_value_ciphertext_base64 text NOT NULL,
  requested_value_sha256 char(64) NOT NULL
) ON COMMIT DROP;
INSERT INTO q4_parameters(
  response_id,scope_ciphertext_base64,statement_ciphertext_base64,
  contact_ciphertext_base64,verify_reason_ciphertext_base64,
  start_reason_ciphertext_base64,requested_value_ciphertext_base64,
  requested_value_sha256
) VALUES(
  :'q4_response_id'::uuid,:'q4_scope_ciphertext',
  :'q4_statement_ciphertext',:'q4_contact_ciphertext',
  :'q4_verify_reason_ciphertext',:'q4_start_reason_ciphertext',
  :'q4_requested_value_ciphertext',:'q4_requested_value_sha256'::char(64)
);

CREATE TEMP TABLE q4_results(
  label text PRIMARY KEY,
  result jsonb NOT NULL
) ON COMMIT DROP;
GRANT SELECT ON q4_parameters TO gurine_submission_api,gurine_control_api;
GRANT SELECT,INSERT ON q4_results TO gurine_submission_api,gurine_control_api;

SET LOCAL ROLE gurine_submission_api;
INSERT INTO q4_results(label,result)
SELECT 'create',ops.create_privacy_request_v2(
  jsonb_build_object(
    'privacyRequestId','31700000-0000-4000-8000-000000000001',
    'requestType','CORRECTION','jurisdiction','KR',
    'identityProof',jsonb_build_object(
      'kind','RESPONSE_RECEIPT',
      'receiptId','31000000-0000-4000-8000-000000000034',
      'possessionTokenHmac',repeat('5',64)
    ),
    'scope',jsonb_build_object(
      'scopeKind','OBJECT_SET','objectRefs',jsonb_build_array(
        jsonb_build_object('objectType','RESPONSE','objectId',response_id)
      ),'dateFrom',NULL,'dateTo',NULL,
      'includeDerivatives',false,'includeBackups',false
    ),
    'scopeCiphertextBase64',scope_ciphertext_base64,
    'scopeAadDigest',pg_temp.q4_nul5_sha256(
      'ops.privacy_requests_v2','scope_ciphertext',
      '31700000-0000-4000-8000-000000000001',
      'privacy-request-scope','1'
    ),
    'statementCiphertextBase64',statement_ciphertext_base64,
    'statementSha256',pg_temp.q4_sha256(
      'TEST_FIXTURE_ONLY party name correction statement'
    ),
    'statementAadDigest',pg_temp.q4_nul5_sha256(
      'ops.privacy_requests_v2','statement_ciphertext',
      '31700000-0000-4000-8000-000000000001',
      'privacy-request-statement','1'
    ),'encryptionKeyId',:'q4_encryption_key_id',
    'communicationSubjectId','31700000-0000-4000-8000-000000000002',
    'communicationSubjectHmacKeyVersion','hmac-v1',
    'communicationSubjectLocale','ko-KR',
    'communicationEndpointId','31700000-0000-4000-8000-000000000003',
    'communicationEndpointChannel','SMTP_EMAIL',
    'communicationEndpointHmac',repeat('d',64),
    'communicationEndpointHmacKeyVersion','hmac-v1',
    'communicationEndpointCiphertextBase64',contact_ciphertext_base64,
    'communicationEndpointEncryptionKeyId',:'q4_encryption_key_id',
    'communicationEndpointAadDigest',pg_temp.q4_nul5_sha256(
      'intake.communication_endpoints','endpoint_ciphertext',
      '31700000-0000-4000-8000-000000000003','email-address','1'
    ),'explicitVoiceConsentReceiptId',NULL,
    'receiptTokenHmac',pg_temp.q4_sha256('q4-receipt-token-hmac'),
    'receiptTokenSha256',pg_temp.q4_sha256('q4-receipt-token-sha'),
    'receiptTokenKeyVersion','TEST_ONLY'
  ),'31700000-0000-4000-8000-000000000004',
  pg_temp.q4_sha256('q4-create-idempotency'),
  pg_temp.q4_sha256('q4-create-request')
)
FROM q4_parameters;
RESET ROLE;

DO $q4_create_result$
BEGIN
  IF NOT EXISTS(
       SELECT 1 FROM q4_results
       WHERE label='create'
         AND result#>>'{request,privacyRequestId}'=
           '31700000-0000-4000-8000-000000000001'
         AND result#>>'{request,identityState}'='PENDING_VERIFICATION'
     ) OR NOT EXISTS(
       SELECT 1
       FROM ops.privacy_identity_proof_authority_receipts_v1 AS authority
       JOIN ops.privacy_request_scope_inventories_v1 AS inventory
         ON inventory.privacy_request_id=authority.privacy_request_id
       JOIN ops.privacy_request_scope_inventory_items_v1 AS item
         ON item.scope_inventory_id=inventory.scope_inventory_id
        AND item.privacy_request_id=inventory.privacy_request_id
       CROSS JOIN q4_parameters AS parameter
       WHERE authority.privacy_request_id=
           '31700000-0000-4000-8000-000000000001'
         AND authority.proof_kind='RESPONSE_RECEIPT'
         AND authority.source_response_receipt_id=
           '31000000-0000-4000-8000-000000000034'
         AND inventory.scope_kind='OBJECT_SET'
         AND NOT inventory.include_derivatives
         AND NOT inventory.include_backups
         AND inventory.object_item_count=1
         AND item.object_kind='RESPONSE'
         AND item.object_id=parameter.response_id
     ) THEN
    RAISE EXCEPTION 'Q4 RESPONSE_RECEIPT create/scope authority invalid';
  END IF;
END
$q4_create_result$;

-- TEST_FIXTURE_ONLY verified-contact producer bridge.  The real Q4 identity
-- consumer and every later owner run after replication_role returns to origin.
DO $q4_contact_verified_fixture$
DECLARE
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_at timestamptz:=clock_timestamp();
  v_proof_digest char(64):=pg_temp.q4_sha256('q4-contact-proof');
  v_receipt_digest char(64):=
    pg_temp.q4_sha256('q4-contact-verification-receipt');
BEGIN
  SELECT * INTO STRICT v_request
  FROM ops.privacy_requests_v2
  WHERE id='31700000-0000-4000-8000-000000000001';
  PERFORM set_config('session_replication_role','replica',true);
  UPDATE intake.communication_endpoints
  SET state='ACTIVE',verified_at=v_at,updated_at=v_at
  WHERE id=v_request.communication_endpoint_id;
  INSERT INTO intake.communication_endpoint_verifications(
    id,subject_id,subject_origin_binding_digest,endpoint_id,
    endpoint_version,endpoint_snapshot_digest,profile_session_id,
    challenge_kind,challenge_hash,nonce_hash,verification_binding_digest,
    state,attempt_count,max_attempts,version,proof_digest,receipt_digest,
    issued_at,expires_at,verified_at,consumed_at
  ) VALUES(
    '31700000-0000-4000-8000-000000000005',
    v_request.communication_subject_id,
    v_request.communication_subject_origin_digest,
    v_request.communication_endpoint_id,
    v_request.communication_endpoint_version,
    v_request.communication_endpoint_digest,
    '31700000-0000-4000-8000-000000000006','EMAIL_LINK',
    pg_temp.q4_sha256('q4-contact-challenge'),
    pg_temp.q4_sha256('q4-contact-nonce'),
    pg_temp.q4_sha256('q4-contact-binding'),'VERIFIED',1,3,1,
    v_proof_digest,v_receipt_digest,v_request.created_at,
    v_at+interval '1 day',v_at,v_at
  );
  INSERT INTO intake.communication_endpoint_link_events(
    id,subject_id,subject_origin_binding_digest,endpoint_id,
    endpoint_sequence,profile_version,endpoint_version,endpoint_hmac,
    endpoint_digest,channel,state,change_kind,profile_session_id,
    verification_id,proof_digest,reason_code,endpoint_snapshot_digest,
    event_digest,audit_event_id,receipt_digest,occurred_at
  ) SELECT
    '31700000-0000-4000-8000-000000000007',subject.id,
    subject.origin_binding_digest,endpoint.id,1,subject.profile_version,
    endpoint.version,endpoint.endpoint_hmac,endpoint.endpoint_digest,
    endpoint.channel,'ACTIVE','VERIFIED',
    '31700000-0000-4000-8000-000000000006',
    '31700000-0000-4000-8000-000000000005',v_proof_digest,
    'TEST_ONLY_Q4_PRIVACY_CONTACT_VERIFIED',endpoint.endpoint_digest,
    pg_temp.q4_sha256('q4-contact-link-event'),
    '31700000-0000-4000-8000-000000000008',v_receipt_digest,v_at
  FROM intake.communication_subjects AS subject
  JOIN intake.communication_endpoints AS endpoint
    ON endpoint.subject_id=subject.id
  WHERE subject.id=v_request.communication_subject_id
    AND endpoint.id=v_request.communication_endpoint_id;
  PERFORM set_config('session_replication_role','origin',true);
END
$q4_contact_verified_fixture$;

CREATE TEMP TABLE q4_control_commands(
  label text PRIMARY KEY,
  operation_id text NOT NULL,
  step_up_id uuid NOT NULL,
  assertion_jti uuid NOT NULL,
  owner_request_id uuid NOT NULL,
  transition_receipt_id uuid,
  idempotency_key_sha256 char(64) NOT NULL,
  request_sha256 char(64) NOT NULL,
  action_digest char(64) NOT NULL,
  assertion_request_digest char(64) NOT NULL
) ON COMMIT DROP;
INSERT INTO q4_control_commands VALUES
  ('verify','transitionRetentionRequest',
   '31700000-0000-4000-8000-000000000010',
   '31700000-0000-4000-8000-000000000011',
   '31700000-0000-4000-8000-000000000013',
   '31700000-0000-4000-8000-000000000012',
   pg_temp.q4_sha256('q4-verify-idempotency'),
   pg_temp.q4_sha256('q4-verify-request'),
   pg_temp.q4_sha256('q4-verify-action'),
   pg_temp.q4_sha256('q4-verify-assertion-request')),
  ('start','transitionRetentionRequest',
   '31700000-0000-4000-8000-000000000014',
   '31700000-0000-4000-8000-000000000015',
   '31700000-0000-4000-8000-000000000017',
   '31700000-0000-4000-8000-000000000016',
   pg_temp.q4_sha256('q4-start-idempotency'),
   pg_temp.q4_sha256('q4-start-request'),
   pg_temp.q4_sha256('q4-start-action'),
   pg_temp.q4_sha256('q4-start-assertion-request')),
  ('plan','createPrivacyCorrectionPlan',
   '31700000-0000-4000-8000-000000000022',
   '31700000-0000-4000-8000-000000000023',
   '31700000-0000-4000-8000-000000000024',NULL,
   pg_temp.q4_sha256('q4-plan-idempotency'),
   pg_temp.q4_sha256('q4-plan-request'),
   pg_temp.q4_sha256('q4-plan-action'),
   pg_temp.q4_sha256('q4-plan-assertion-request'));
GRANT SELECT ON q4_control_commands TO gurine_control_api;

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
)
SELECT step_up_id,'31400000-0000-4000-8000-000000000022',
  action_digest,idempotency_key_sha256,
  pg_temp.q4_sha256('q4-step-up-token:'||label),
  clock_timestamp()+interval '4 minutes',1,3,
  clock_timestamp()-interval '1 minute'
FROM q4_control_commands;
INSERT INTO ops.assertion_replay_guard(
  assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
)
SELECT 'ACTOR',assertion_jti,'identity-api','control-api',
  assertion_request_digest,clock_timestamp()+interval '10 minutes',
  clock_timestamp()-interval '1 minute'
FROM q4_control_commands;
INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
SELECT
  'control:31400000-0000-4000-8000-000000000003:'||operation_id,
  idempotency_key_sha256,request_sha256,
  clock_timestamp()+interval '1 hour'
FROM q4_control_commands;

SET LOCAL ROLE gurine_control_api;
INSERT INTO q4_results(label,result)
SELECT 'verify',ops.transition_privacy_request_v2(
  jsonb_build_object(
    'retentionRequestId','31700000-0000-4000-8000-000000000001',
    'expectedDecisionVersion',0,'transition','VERIFY_IDENTITY',
    'reasonCode','TEST_ONLY_Q4_IDENTITY_VERIFIED',
    'reasonCiphertextBase64',parameter.verify_reason_ciphertext_base64,
    'reasonSha256',pg_temp.q4_sha256(
      'TEST_FIXTURE_ONLY Q4 identity verified'
    ),
    'transitionReceiptId',command.transition_receipt_id,
    'identityProofReceiptId',(
      SELECT identity_proof_receipt_id
      FROM ops.privacy_identity_proof_authority_receipts_v1
      WHERE privacy_request_id=
        '31700000-0000-4000-8000-000000000001'
    ),'_actorAssertionJti',command.assertion_jti,
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','privacy.requests.manage',
    '_actorAssertionRequestSha256',
      btrim(command.assertion_request_digest),
    '_actorActionDigest',btrim(command.action_digest),
    '_actorStepUpAuthorizationId',command.step_up_id,
    '_actorIdempotencyKeySha256',btrim(command.idempotency_key_sha256),
    '_actorRequestKeySha256',btrim(command.idempotency_key_sha256)
  ),'31400000-0000-4000-8000-000000000003',
  '31400000-0000-4000-8000-000000000022',command.owner_request_id,
  command.idempotency_key_sha256,command.request_sha256
)
FROM q4_control_commands AS command
CROSS JOIN q4_parameters AS parameter
WHERE command.label='verify';
RESET ROLE;

DO $q4_verify_result$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM q4_results
    WHERE label='verify' AND result->>'status'='COMPLETED'
      AND result#>>'{transition,transition}'='VERIFY_IDENTITY'
      AND (result#>>'{transition,decisionVersion}')::bigint=1
  ) OR NOT EXISTS(
    SELECT 1 FROM ops.privacy_requests_v2
    WHERE id='31700000-0000-4000-8000-000000000001'
      AND identity_state='VERIFIED' AND state='RECEIVED'
      AND decision_version=1
  ) THEN
    RAISE EXCEPTION 'Q4 identity verification result invalid';
  END IF;
END
$q4_verify_result$;

SET LOCAL ROLE gurine_control_api;
INSERT INTO q4_results(label,result)
SELECT 'start',ops.transition_privacy_request_v2(
  jsonb_build_object(
    'retentionRequestId','31700000-0000-4000-8000-000000000001',
    'expectedDecisionVersion',1,'transition','START_REVIEW',
    'reasonCode','TEST_ONLY_Q4_REVIEW_STARTED',
    'reasonCiphertextBase64',parameter.start_reason_ciphertext_base64,
    'reasonSha256',pg_temp.q4_sha256(
      'TEST_FIXTURE_ONLY Q4 review started'
    ),
    'transitionReceiptId',command.transition_receipt_id,
    '_actorAssertionJti',command.assertion_jti,
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','privacy.requests.manage',
    '_actorAssertionRequestSha256',
      btrim(command.assertion_request_digest),
    '_actorActionDigest',btrim(command.action_digest),
    '_actorStepUpAuthorizationId',command.step_up_id,
    '_actorIdempotencyKeySha256',btrim(command.idempotency_key_sha256),
    '_actorRequestKeySha256',btrim(command.idempotency_key_sha256)
  ),'31400000-0000-4000-8000-000000000003',
  '31400000-0000-4000-8000-000000000022',command.owner_request_id,
  command.idempotency_key_sha256,command.request_sha256
)
FROM q4_control_commands AS command
CROSS JOIN q4_parameters AS parameter
WHERE command.label='start';
RESET ROLE;

DO $q4_start_result$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM q4_results
    WHERE label='start' AND result->>'status'='COMPLETED'
      AND result#>>'{transition,transition}'='START_REVIEW'
      AND result#>>'{transition,state}'='REVIEW'
      AND (result#>>'{transition,decisionVersion}')::bigint=2
  ) OR NOT EXISTS(
    SELECT 1 FROM ops.privacy_requests_v2
    WHERE id='31700000-0000-4000-8000-000000000001'
      AND request_type='CORRECTION' AND identity_state='VERIFIED'
      AND state='REVIEW' AND decision_version=2
  ) THEN
    RAISE EXCEPTION 'Q4 START_REVIEW result invalid';
  END IF;
END
$q4_start_result$;

SET LOCAL ROLE gurine_control_api;
INSERT INTO q4_results(label,result)
SELECT 'access',ops.read_privacy_response_party_name_access_v1(
  '31700000-0000-4000-8000-000000000001',response_id
)
FROM q4_parameters;
RESET ROLE;

DO $q4_access_result$
DECLARE
  v_access jsonb;
  v_response editorial.responses%ROWTYPE;
BEGIN
  SELECT result INTO STRICT v_access FROM q4_results WHERE label='access';
  SELECT response.* INTO STRICT v_response
  FROM editorial.responses AS response
  CROSS JOIN q4_parameters AS parameter
  WHERE response.id=parameter.response_id;
  IF v_access->>'schemaVersion'<>
       'privacy-response-party-name-access.v1'
     OR (v_access->>'targetObjectId')::uuid<>v_response.id
     OR v_access->>'targetObjectType'<>'RESPONSE'
     OR v_access->>'fieldPath'<>'/partyName'
     OR v_access->>'partyName'<>v_response.party_name
     OR v_access->>'currentValueDigest'<>
       btrim(pg_temp.q4_sha256(v_response.party_name))
     OR (v_access->>'responseVersion')::bigint<>v_response.version
     OR (v_access->>'responseSubmissionReceiptId')::uuid<>
       '31000000-0000-4000-8000-000000000034'
     OR (v_access->>'sourceResponseRequestId')::uuid<>
       '31000000-0000-4000-8000-000000000010'
     OR COALESCE(
       current_setting('gurine.response_request_id',true),''
     )<>'' THEN
    RAISE EXCEPTION 'Q4 ACCESS projection/source binding invalid';
  END IF;
END
$q4_access_result$;

CREATE TEMP TABLE q4_pre_plan_negative(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  unsupported boolean NOT NULL DEFAULT false,
  stale boolean NOT NULL DEFAULT false,
  plan_count bigint NOT NULL,
  audit_count bigint NOT NULL,
  outbox_count bigint NOT NULL
) ON COMMIT DROP;
INSERT INTO q4_pre_plan_negative(plan_count,audit_count,outbox_count)
SELECT
  (SELECT count(*) FROM ops.privacy_correction_plans_v1),
  (SELECT count(*) FROM ops.audit_events),
  (SELECT count(*) FROM ops.outbox);
GRANT UPDATE(unsupported,stale) ON q4_pre_plan_negative
  TO gurine_control_api;

SET LOCAL ROLE gurine_control_api;
DO $q4_pre_plan_negatives$
DECLARE
  v_response_id uuid:=(SELECT response_id FROM q4_parameters);
  v_unsupported boolean:=false;
  v_stale boolean:=false;
BEGIN
  BEGIN
    PERFORM ops.create_privacy_correction_plan_v1(
      jsonb_build_object(
        'targetObjectType','EVIDENCE','fieldPath','/title'
      ),'31400000-0000-4000-8000-000000000003',
      '31400000-0000-4000-8000-000000000022',
      '31700000-0000-4000-8000-000000000025',repeat('8',64),
      repeat('9',64)
    );
  EXCEPTION WHEN SQLSTATE '0A000' THEN
    v_unsupported:=SQLERRM='PRIVACY_CORRECTION_TARGET_UNSUPPORTED';
  END;
  BEGIN
    PERFORM ops.create_privacy_correction_plan_v1(
      jsonb_build_object(
        'retentionRequestId','31700000-0000-4000-8000-000000000001',
        'targetObjectType','RESPONSE','targetObjectId',v_response_id,
        'fieldPath','/partyName','currentValueDigest',repeat('0',64)
      ),'31400000-0000-4000-8000-000000000003',
      '31400000-0000-4000-8000-000000000022',
      '31700000-0000-4000-8000-000000000026',repeat('a',64),
      repeat('b',64)
    );
  EXCEPTION WHEN SQLSTATE 'PVT08' THEN
    v_stale:=SQLERRM='PRIVACY_CORRECTION_CURRENT_VALUE_STALE';
  END;
  UPDATE q4_pre_plan_negative
  SET unsupported=v_unsupported,stale=v_stale;
END
$q4_pre_plan_negatives$;
RESET ROLE;

DO $q4_pre_plan_negative_result$
DECLARE
  v_probe q4_pre_plan_negative%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_probe FROM q4_pre_plan_negative;
  IF NOT v_probe.unsupported OR NOT v_probe.stale
     OR (SELECT count(*) FROM ops.privacy_correction_plans_v1)<>
        v_probe.plan_count
     OR (SELECT count(*) FROM ops.audit_events)<>v_probe.audit_count
     OR (SELECT count(*) FROM ops.outbox)<>v_probe.outbox_count THEN
    RAISE EXCEPTION
      'Q4 pre-plan negative/zero-write invalid: unsupported %, stale %',
      v_probe.unsupported,v_probe.stale;
  END IF;
END
$q4_pre_plan_negative_result$;

-- A temporary proof-authority/source-subject mismatch must fail the ACCESS
-- chain.  The exception subtransaction restores the immutable authority row.
DO $q4_subject_mismatch$
DECLARE
  v_response_id uuid:=(SELECT response_id FROM q4_parameters);
  v_denied boolean:=false;
BEGIN
  BEGIN
    PERFORM set_config('session_replication_role','replica',true);
    UPDATE ops.privacy_identity_proof_authority_receipts_v1
    SET source_subject_id='31700000-0000-4000-8000-000000000002'
    WHERE privacy_request_id=
      '31700000-0000-4000-8000-000000000001';
    PERFORM set_config('session_replication_role','origin',true);
    PERFORM ops.read_privacy_response_party_name_access_v1(
      '31700000-0000-4000-8000-000000000001',v_response_id
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_denied:=SQLERRM='privacy_response_party_name_access_chain_invalid';
  END;
  IF NOT v_denied OR NOT EXISTS(
    SELECT 1
    FROM ops.privacy_identity_proof_authority_receipts_v1 AS authority
    WHERE authority.privacy_request_id=
        '31700000-0000-4000-8000-000000000001'
      AND authority.source_subject_id=
        '31000000-0000-4000-8000-000000000025'
  ) THEN
    RAISE EXCEPTION 'Q4 proof subject mismatch did not fail closed';
  END IF;
END
$q4_subject_mismatch$;

INSERT INTO editorial.evidence(
  id,case_id,evidence_type,title,description,source_locator,content_sha256,
  classification,verification_status,verified_by,verified_at,version,
  created_by
) VALUES(
  '31700000-0000-4000-8000-000000000020',
  '31000000-0000-4000-8000-000000000004','DOCUMENT',
  'TEST_FIXTURE_ONLY Q4 correction evidence',
  'TEST_FIXTURE_ONLY verified reason for the exact party-name correction',
  'test-only/q4-response-party-name',pg_temp.q4_sha256('q4 evidence'),
  'RESTRICTED','VERIFIED','31400000-0000-4000-8000-000000000003',
  clock_timestamp(),1,'31400000-0000-4000-8000-000000000003'
);

SET LOCAL ROLE gurine_control_api;
INSERT INTO q4_results(label,result)
SELECT 'plan',ops.create_privacy_correction_plan_v1(
  jsonb_build_object(
    'retentionRequestId','31700000-0000-4000-8000-000000000001',
    'expectedDecisionVersion',2,'targetObjectType','RESPONSE',
    'targetObjectId',parameter.response_id,'fieldPath','/partyName',
    'currentValueDigest',access.result->>'currentValueDigest',
    'evidenceIds',jsonb_build_array(
      '31700000-0000-4000-8000-000000000020'::uuid
    ),'reason','TEST_FIXTURE_ONLY verified party-name correction',
    '_correctionPlanId','31700000-0000-4000-8000-000000000021',
    'requestedValueCiphertextBase64',
      parameter.requested_value_ciphertext_base64,
    'requestedValueSha256',btrim(parameter.requested_value_sha256),
    '_actorAssertionJti',command.assertion_jti,
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','privacy.requests.manage',
    '_actorAssertionRequestSha256',
      btrim(command.assertion_request_digest),
    '_actorActionDigest',btrim(command.action_digest),
    '_actorStepUpAuthorizationId',command.step_up_id,
    '_actorIdempotencyKeySha256',btrim(command.idempotency_key_sha256),
    '_actorRequestKeySha256',btrim(command.idempotency_key_sha256)
  ),'31400000-0000-4000-8000-000000000003',
  '31400000-0000-4000-8000-000000000022',command.owner_request_id,
  command.idempotency_key_sha256,command.request_sha256
)
FROM q4_control_commands AS command
CROSS JOIN q4_parameters AS parameter
CROSS JOIN q4_results AS access
WHERE command.label='plan' AND access.label='access';
RESET ROLE;

DO $q4_plan_result$
DECLARE
  v_access jsonb:=(SELECT result FROM q4_results WHERE label='access');
  v_plan jsonb:=(SELECT result FROM q4_results WHERE label='plan');
BEGIN
  IF (v_plan->>'correctionPlanId')::uuid<>
       '31700000-0000-4000-8000-000000000021'
     OR (v_plan->>'privacyRequestId')::uuid<>
       '31700000-0000-4000-8000-000000000001'
     OR (v_plan->>'planVersion')::bigint<>1
     OR COALESCE((v_plan->>'replayed')::boolean,true)
     OR NOT EXISTS(
       SELECT 1
       FROM ops.privacy_correction_plans_v1 AS plan
       JOIN ops.privacy_response_party_name_correction_plan_bindings_v1
         AS binding ON binding.correction_plan_id=plan.correction_plan_id
       CROSS JOIN q4_parameters AS parameter
       WHERE plan.correction_plan_id=
           '31700000-0000-4000-8000-000000000021'
         AND plan.privacy_request_id=
           '31700000-0000-4000-8000-000000000001'
         AND plan.target_object_type='RESPONSE'
         AND plan.target_object_id=parameter.response_id
         AND plan.field_path='/partyName'
         AND plan.plan_digest=(v_plan->>'planDigest')::char(64)
         AND binding.expected_response_version=
           (v_access->>'responseVersion')::bigint
         AND binding.expected_current_value_digest=
           (v_access->>'currentValueDigest')::char(64)
         AND binding.access_projection_digest=
           (v_access->>'projectionDigest')::char(64)
         AND binding.response_submission_receipt_id=
           (v_access->>'responseSubmissionReceiptId')::uuid
         AND binding.response_origin_receipt_id=
           (v_access->>'responseOriginReceiptId')::uuid
     ) THEN
    RAISE EXCEPTION 'Q4 correction plan/source binding invalid';
  END IF;
END
$q4_plan_result$;
COMMIT;
SQL

# A real RESPONSE legal-hold placement whose affected cell is the Q4 privacy
# request must block APPROVE before STEP_UP consumption or durable transition
# writes.  Roll the complete hold transaction back, then approve with fresh
# authority in the next transaction.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SET CONSTRAINTS ALL DEFERRED;
SET LOCAL TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.q4h_sha256(p_value text)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,extensions,pg_temp
AS $digest$
  SELECT encode(
    extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex'
  )::char(64)
$digest$;

CREATE FUNCTION pg_temp.q4h_reason_base64(p_label text,p_key_id text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,pg_temp
AS $envelope$
  SELECT replace(encode(convert_to(
    'gurine-fe-v1.'||p_key_id||'.'||p_label||'.cipher','UTF8'
  ),'base64'),E'\n','')
$envelope$;

GRANT EXECUTE ON FUNCTION pg_temp.q4h_sha256(text),
  pg_temp.q4h_reason_base64(text,text) TO gurine_control_api;

CREATE TEMP TABLE q4_hold_target AS
SELECT response.id,response.version,response.response_content_sha256
FROM editorial.responses AS response
JOIN ops.privacy_response_party_name_correction_plan_bindings_v1 AS binding
  ON binding.response_id=response.id
WHERE binding.privacy_request_id=
  '31700000-0000-4000-8000-000000000001';
ALTER TABLE q4_hold_target ALTER COLUMN id SET NOT NULL;
GRANT SELECT ON q4_hold_target TO gurine_control_api;

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
) VALUES(
  '31700000-0000-4000-8000-000000000030',
  '31400000-0000-4000-8000-000000000022',
  pg_temp.q4h_sha256('q4-hold-action'),
  pg_temp.q4h_sha256('q4-hold-idempotency'),
  pg_temp.q4h_sha256('q4-hold-step-up-token'),
  clock_timestamp()+interval '4 minutes',1,3,
  clock_timestamp()-interval '1 minute'
);
INSERT INTO ops.assertion_replay_guard(
  assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
) VALUES(
  'ACTOR','31700000-0000-4000-8000-000000000031',
  'identity-api','control-api',
  pg_temp.q4h_sha256('q4-hold-assertion-request'),
  clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
);
INSERT INTO editorial.conflict_snapshots(
  id,subject_actor_id,target_type,target_id,target_version,target_digest,
  operation_id,action_kind,candidate_role,declaration_ids,
  declaration_set_digest,finding_set,finding_set_digest,
  authorship_digest,party_recipient_digest,role_digest,
  relationship_digest,funding_customer_digest,policy_digest,
  evaluation_state,blocker_codes,nonwaivable_blocker_count,
  evaluated_at,valid_until,evaluated_by_type,evaluated_by_id,
  snapshot_sha256,receipt_digest
)
SELECT
  '31700000-0000-4000-8000-000000000033',
  '31400000-0000-4000-8000-000000000003','RESPONSE',id::text,
  version,response_content_sha256,'placeLegalHold',NULL,'LEGAL_REVIEWER',
  '{}'::uuid[],pg_temp.q4h_sha256('q4-hold-declarations'),
  '{}'::jsonb,pg_temp.q4h_sha256('q4-hold-findings'),
  pg_temp.q4h_sha256('q4-hold-authorship'),
  pg_temp.q4h_sha256('q4-hold-party'),
  pg_temp.q4h_sha256('q4-hold-role'),
  pg_temp.q4h_sha256('q4-hold-relationship'),
  pg_temp.q4h_sha256('q4-hold-funding'),
  pg_temp.q4h_sha256('q4-hold-policy'),'CLEAR','{}'::text[],0,
  clock_timestamp()-interval '1 second',
  clock_timestamp()+interval '10 minutes','SERVICE',
  'q4-event-runtime',pg_temp.q4h_sha256('q4-hold-snapshot'),
  pg_temp.q4h_sha256('q4-hold-receipt')
FROM q4_hold_target;

CREATE TEMP TABLE q4_hold_result(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  result jsonb NOT NULL
) ON COMMIT DROP;
GRANT INSERT,SELECT ON q4_hold_result TO gurine_control_api;
SET LOCAL ROLE gurine_control_api;
INSERT INTO q4_hold_result(result)
SELECT ops.place_legal_hold_v2(
  jsonb_build_object(
    'target',jsonb_build_object(
      'targetKind','RESPONSE','targetId',id,'targetVersion',version,
      'targetDigest',btrim(response_content_sha256),'responseId',id
    ),'scopeAtoms',jsonb_build_array('RETENTION'),
    'affectedIds',jsonb_build_array(
      '31700000-0000-4000-8000-000000000001'::uuid
    ),'authorityReference','TEST_FIXTURE_ONLY Q4 hold authority',
    'reasonCode','LEGAL_PRESERVATION_REQUIRED',
    'reason','TEST_FIXTURE_ONLY block Q4 correction approval',
    'expiresAt',NULL,
    '_actorAssertionJti','31700000-0000-4000-8000-000000000031',
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','review.legal',
    '_actorAssertionRequestSha256',
      pg_temp.q4h_sha256('q4-hold-assertion-request'),
    '_actorActionDigest',pg_temp.q4h_sha256('q4-hold-action'),
    '_actorStepUpAuthorizationId',
      '31700000-0000-4000-8000-000000000030',
    '_actorIdempotencyKeySha256',
      pg_temp.q4h_sha256('q4-hold-idempotency'),
    '_actorRequestKeySha256',
      pg_temp.q4h_sha256('q4-hold-idempotency'),
    '_requestId','31700000-0000-4000-8000-000000000032',
    '_requestSha256',pg_temp.q4h_sha256('q4-hold-request'),
    '_idempotencyKeySha256',pg_temp.q4h_sha256('q4-hold-idempotency')
  ),'31400000-0000-4000-8000-000000000003',
  '31700000-0000-4000-8000-000000000032',
  pg_temp.q4h_sha256('q4-hold-idempotency'),
  pg_temp.q4h_sha256('q4-hold-request')
)
FROM q4_hold_target;
RESET ROLE;

DO $q4_hold_active$
DECLARE
  v_coverage jsonb:=ops.r6d_privacy_request_legal_hold_coverage_v1(
    '31700000-0000-4000-8000-000000000001',clock_timestamp()
  );
BEGIN
  IF NOT EXISTS(
       SELECT 1 FROM q4_hold_result
       WHERE COALESCE((result->>'replayed')::boolean,true)=false
     ) OR COALESCE((v_coverage->>'active')::boolean,false)=false
     OR (v_coverage->>'activeCellCount')::bigint<>1 THEN
    RAISE EXCEPTION 'Q4 legal-hold coverage fixture invalid';
  END IF;
END
$q4_hold_active$;

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
) VALUES(
  '31700000-0000-4000-8000-000000000034',
  '31400000-0000-4000-8000-000000000022',
  pg_temp.q4h_sha256('q4-held-approve-action'),
  pg_temp.q4h_sha256('q4-held-approve-idempotency'),
  pg_temp.q4h_sha256('q4-held-approve-step-up-token'),
  clock_timestamp()+interval '4 minutes',1,3,
  clock_timestamp()-interval '1 minute'
);
INSERT INTO ops.assertion_replay_guard(
  assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
) VALUES(
  'ACTOR','31700000-0000-4000-8000-000000000035',
  'identity-api','control-api',
  pg_temp.q4h_sha256('q4-held-approve-assertion-request'),
  clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
);
INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
VALUES(
  'control:31400000-0000-4000-8000-000000000003:transitionRetentionRequest',
  pg_temp.q4h_sha256('q4-held-approve-idempotency'),
  pg_temp.q4h_sha256('q4-held-approve-request'),
  clock_timestamp()+interval '1 hour'
);
CREATE TEMP TABLE q4_hold_negative(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  denied boolean NOT NULL DEFAULT false,
  job_count bigint NOT NULL,
  binding_count bigint NOT NULL,
  transition_count bigint NOT NULL,
  audit_count bigint NOT NULL,
  outbox_count bigint NOT NULL
) ON COMMIT DROP;
INSERT INTO q4_hold_negative(
  job_count,binding_count,transition_count,audit_count,outbox_count
) SELECT
  (SELECT count(*) FROM ops.jobs),
  (SELECT count(*)
   FROM ops.privacy_response_party_name_correction_approval_bindings_v1),
  (SELECT count(*) FROM ops.privacy_request_transition_receipts_v2),
  (SELECT count(*) FROM ops.audit_events),
  (SELECT count(*) FROM ops.outbox);
GRANT SELECT,UPDATE ON q4_hold_negative TO gurine_control_api;

SET LOCAL ROLE gurine_control_api;
DO $q4_held_approve$
BEGIN
  BEGIN
    PERFORM ops.transition_privacy_request_v2(
      jsonb_build_object(
        'retentionRequestId','31700000-0000-4000-8000-000000000001',
        'expectedDecisionVersion',2,'transition','APPROVE',
        'reasonCode','TEST_ONLY_Q4_APPROVED',
        'reasonCiphertextBase64',
          pg_temp.q4h_reason_base64(
            'q4_held_approve',(
              SELECT encryption_key_id
              FROM ops.privacy_requests_v2
              WHERE id='31700000-0000-4000-8000-000000000001'
            )
          ),
        'reasonSha256',pg_temp.q4h_sha256('q4 held approve reason'),
        'transitionReceiptId','31700000-0000-4000-8000-000000000037',
        '_actorAssertionJti','31700000-0000-4000-8000-000000000035',
        '_actorAssuranceLevel','STEP_UP',
        '_actorEffectiveCapability','privacy.requests.manage',
        '_actorAssertionRequestSha256',
          pg_temp.q4h_sha256('q4-held-approve-assertion-request'),
        '_actorActionDigest',pg_temp.q4h_sha256('q4-held-approve-action'),
        '_actorStepUpAuthorizationId',
          '31700000-0000-4000-8000-000000000034',
        '_actorIdempotencyKeySha256',
          pg_temp.q4h_sha256('q4-held-approve-idempotency'),
        '_actorRequestKeySha256',
          pg_temp.q4h_sha256('q4-held-approve-idempotency')
      ),'31400000-0000-4000-8000-000000000003',
      '31400000-0000-4000-8000-000000000022',
      '31700000-0000-4000-8000-000000000036',
      pg_temp.q4h_sha256('q4-held-approve-idempotency'),
      pg_temp.q4h_sha256('q4-held-approve-request')
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    IF SQLERRM='privacy_correction_legal_hold_active' THEN
      UPDATE q4_hold_negative SET denied=true;
    END IF;
  END;
END
$q4_held_approve$;
RESET ROLE;

DO $q4_held_approve_result$
DECLARE
  v_before q4_hold_negative%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_before FROM q4_hold_negative;
  IF NOT v_before.denied
     OR (SELECT count(*) FROM ops.jobs)<>v_before.job_count
     OR (SELECT count(*)
         FROM ops.privacy_response_party_name_correction_approval_bindings_v1)
        <>v_before.binding_count
     OR (SELECT count(*) FROM ops.privacy_request_transition_receipts_v2)
        <>v_before.transition_count
     OR (SELECT count(*) FROM ops.audit_events)<>v_before.audit_count
     OR (SELECT count(*) FROM ops.outbox)<>v_before.outbox_count
     OR NOT EXISTS(
       SELECT 1 FROM ops.privacy_requests_v2
       WHERE id='31700000-0000-4000-8000-000000000001'
         AND state='REVIEW' AND decision_version=2
     ) OR NOT EXISTS(
       SELECT 1 FROM ops.idempotency_keys
       WHERE scope=
         'control:31400000-0000-4000-8000-000000000003:transitionRetentionRequest'
         AND key_hash=pg_temp.q4h_sha256('q4-held-approve-idempotency')
         AND num_nonnulls(
           response_status,response_body,resource_type,resource_id
         )=0
     ) OR NOT EXISTS(
       SELECT 1 FROM ops.step_up_authorizations
       WHERE id='31700000-0000-4000-8000-000000000034'
         AND closed_at IS NULL
     ) THEN
    RAISE EXCEPTION 'Q4 held APPROVE zero-write boundary invalid';
  END IF;
END
$q4_held_approve_result$;
ROLLBACK;
SQL

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" \
  -v q4_approve_reason_ciphertext="$q4_approve_reason_ciphertext" \
  <<'SQL' >/dev/null
BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SET CONSTRAINTS ALL DEFERRED;
SET LOCAL TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.q4a_sha256(p_value text)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,extensions,pg_temp
AS $digest$
  SELECT encode(
    extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex'
  )::char(64)
$digest$;

GRANT EXECUTE ON FUNCTION pg_temp.q4a_sha256(text)
  TO gurine_control_api;

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
) VALUES(
  '31700000-0000-4000-8000-000000000040',
  '31400000-0000-4000-8000-000000000022',
  pg_temp.q4a_sha256('q4-approve-action'),
  pg_temp.q4a_sha256('q4-approve-idempotency'),
  pg_temp.q4a_sha256('q4-approve-step-up-token'),
  clock_timestamp()+interval '4 minutes',1,3,
  clock_timestamp()-interval '1 minute'
);
INSERT INTO ops.assertion_replay_guard(
  assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
) VALUES(
  'ACTOR','31700000-0000-4000-8000-000000000041',
  'identity-api','control-api',
  pg_temp.q4a_sha256('q4-approve-assertion-request'),
  clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
);
INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
VALUES(
  'control:31400000-0000-4000-8000-000000000003:transitionRetentionRequest',
  pg_temp.q4a_sha256('q4-approve-idempotency'),
  pg_temp.q4a_sha256('q4-approve-request'),
  clock_timestamp()+interval '1 hour'
);
CREATE TEMP TABLE q4_approve_result(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  result jsonb NOT NULL
) ON COMMIT DROP;
GRANT INSERT,SELECT ON q4_approve_result TO gurine_control_api;

SET LOCAL ROLE gurine_control_api;
INSERT INTO q4_approve_result(result)
VALUES(ops.transition_privacy_request_v2(
  jsonb_build_object(
    'retentionRequestId','31700000-0000-4000-8000-000000000001',
    'expectedDecisionVersion',2,'transition','APPROVE',
    'reasonCode','TEST_ONLY_Q4_APPROVED',
    'reasonCiphertextBase64',:'q4_approve_reason_ciphertext',
    'reasonSha256',pg_temp.q4a_sha256('TEST_FIXTURE_ONLY Q4 approved'),
    'transitionReceiptId','31700000-0000-4000-8000-000000000042',
    '_actorAssertionJti','31700000-0000-4000-8000-000000000041',
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','privacy.requests.manage',
    '_actorAssertionRequestSha256',
      pg_temp.q4a_sha256('q4-approve-assertion-request'),
    '_actorActionDigest',pg_temp.q4a_sha256('q4-approve-action'),
    '_actorStepUpAuthorizationId',
      '31700000-0000-4000-8000-000000000040',
    '_actorIdempotencyKeySha256',
      pg_temp.q4a_sha256('q4-approve-idempotency'),
    '_actorRequestKeySha256',
      pg_temp.q4a_sha256('q4-approve-idempotency')
  ),'31400000-0000-4000-8000-000000000003',
  '31400000-0000-4000-8000-000000000022',
  '31700000-0000-4000-8000-000000000043',
  pg_temp.q4a_sha256('q4-approve-idempotency'),
  pg_temp.q4a_sha256('q4-approve-request')
));
RESET ROLE;

DO $q4_approve_result$
DECLARE
  v_result jsonb:=(SELECT result FROM q4_approve_result);
  v_job ops.jobs%ROWTYPE;
  v_binding
    ops.privacy_response_party_name_correction_approval_bindings_v1%ROWTYPE;
BEGIN
  SELECT job.* INTO STRICT v_job
  FROM ops.jobs AS job
  WHERE job.job_type='PRIVACY_RESPONSE_PARTY_NAME_CORRECTION'
    AND job.queue='workflow-worker'
    AND job.dedupe_key=
      'privacy-response-party-name-correction:'||
      '31700000-0000-4000-8000-000000000021';
  SELECT binding.* INTO STRICT v_binding
  FROM ops.privacy_response_party_name_correction_approval_bindings_v1
    AS binding
  WHERE binding.privacy_request_id=
      '31700000-0000-4000-8000-000000000001'
    AND binding.request_decision_version=3;
  IF v_result->>'status'<>'COMPLETED'
     OR v_result#>>'{transition,transition}'<>'APPROVE'
     OR v_result#>>'{transition,state}'<>'APPROVED'
     OR (v_result#>>'{transition,decisionVersion}')::bigint<>3
     OR NOT EXISTS(
       SELECT 1 FROM ops.privacy_requests_v2
       WHERE id='31700000-0000-4000-8000-000000000001'
         AND state='APPROVED' AND decision_version=3
     ) OR v_job.status<>'QUEUED' OR v_job.max_attempts<>8
     OR jsonb_typeof(v_job.payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_job.payload))<>24
     OR v_job.payload->>'schemaVersion'<>
       'privacy-response-party-name-correction-job.v1'
     OR v_job.payload->>'privacyRequestId'<>
       '31700000-0000-4000-8000-000000000001'
     OR v_job.payload->>'correctionPlanId'<>
       '31700000-0000-4000-8000-000000000021'
     OR v_job.payload->>'requestDecisionVersion'<>'3'
     OR v_job.payload ?| ARRAY[
       'partyName','requestedValue','plaintext',
       'requestedValueCiphertextBase64'
     ] OR v_binding.job_id<>v_job.id
     OR v_binding.job_payload_digest<>encode(extensions.digest(
       ops.canonical_jsonb_v1(v_job.payload),'sha256'
     ),'hex')
     OR v_binding.transition_receipt_id<>
       '31700000-0000-4000-8000-000000000042'
     OR NOT EXISTS(
       SELECT 1
       FROM ops.privacy_request_transition_receipts_v2 AS receipt
       JOIN ops.outbox AS event ON event.id=receipt.event_receipt_id
       WHERE receipt.transition_receipt_id=
           '31700000-0000-4000-8000-000000000042'
         AND receipt.privacy_request_id=
           '31700000-0000-4000-8000-000000000001'
         AND receipt.decision_version=3
         AND receipt.transition='APPROVE'
         AND receipt.receipt_digest=v_binding.transition_receipt_digest
         AND event.event_type='privacy.request_decision_recorded.v1'
         AND event.aggregate_version=3
         AND event.payload->>'transition'='APPROVE'
         AND event.payload->>'receiptDigest'=
           btrim(receipt.receipt_digest)
     ) THEN
    RAISE EXCEPTION 'Q4 APPROVE/job/outbox binding invalid';
  END IF;
END
$q4_approve_result$;
COMMIT;
SQL

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
SELECT ops.enqueue_outbox('contact_request','31000000-0000-4000-8000-000000000040',1,'intake.contact_received.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','createContactRequest','request_id','31000000-0000-4000-8000-0000000000b1'),clock_timestamp());
SELECT ops.enqueue_outbox('correction_request','31000000-0000-4000-8000-000000000030',1,'notification.correction_received.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','createCorrectionRequest','request_id','31000000-0000-4000-8000-0000000000b2'),clock_timestamp());
SELECT ops.enqueue_outbox('correction','31000000-0000-4000-8000-000000000032',1,'notification.correction_resolved.v1',jsonb_build_object('actor_id','31000000-0000-4000-8000-000000000001','correction_id','31000000-0000-4000-8000-000000000032','occurred_at','2026-07-12T00:00:00Z','operation_id','resolveCorrectionRequest','request_id','31000000-0000-4000-8000-0000000000b3'),clock_timestamp());
SELECT ops.enqueue_outbox('case','31000000-0000-4000-8000-000000000004',1,'notification.publication_created.v1',jsonb_build_object('actor_id','31000000-0000-4000-8000-000000000001','caseId','31000000-0000-4000-8000-000000000004','occurred_at','2026-07-12T00:00:00Z','operation_id','publishCase','request_id','31000000-0000-4000-8000-0000000000b4','reviewSnapshotId','31000000-0000-4000-8000-000000000005'),clock_timestamp());
SELECT ops.enqueue_outbox('response_extension','31000000-0000-4000-8000-000000000013',1,'notification.response_extension_requested.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','requestResponseExtension','requestToken','redacted','request_id','31000000-0000-4000-8000-0000000000b5'),clock_timestamp());
SELECT ops.enqueue_outbox('response_request','31000000-0000-4000-8000-000000000010',1,'notification.response_request_delivery_requested.v1',jsonb_build_object('actor_id','31000000-0000-4000-8000-000000000001','caseId','31000000-0000-4000-8000-000000000004','occurred_at','2026-07-12T00:00:00Z','operation_id','createResponseRequest','request_id','31000000-0000-4000-8000-0000000000b6'),clock_timestamp());
SELECT ops.enqueue_outbox('subscription','31000000-0000-4000-8000-000000000020',1,'notification.subscription_verification_requested.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','createSubscription','request_id','31000000-0000-4000-8000-0000000000b8'),clock_timestamp());
SELECT ops.enqueue_outbox('user','31000000-0000-4000-8000-000000000003',1,'notification.user_invitation_requested.v1',jsonb_build_object('actor_id','31000000-0000-4000-8000-000000000001','occurred_at','2026-07-12T00:00:00Z','operation_id','inviteUser','request_id','31000000-0000-4000-8000-0000000000b9'),clock_timestamp());
SELECT ops.enqueue_outbox('publication_revision','31000000-0000-4000-8000-000000000006',1,'projection.publication_applied.v1',jsonb_build_object('public_payload_sha256','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','publication_revision_id','31000000-0000-4000-8000-000000000006'),clock_timestamp());
SQL

SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_INSTANCE_ID="event-test" SCHEDULER_ONCE=true target/debug/gurine-scheduler

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $q4_workflow_dispatch$
DECLARE
  v_child_count bigint;
  v_delivery_count bigint;
BEGIN
  SELECT count(*) INTO v_child_count
  FROM ops.jobs AS job
  WHERE job.job_type='PRIVACY_RESPONSE_PARTY_NAME_CORRECTION'
    AND job.queue='workflow-worker' AND job.status='QUEUED'
    AND job.payload->>'privacyRequestId'=
      '31700000-0000-4000-8000-000000000001';
  SELECT count(*) INTO v_delivery_count
  FROM ops.inbox AS inbox
  JOIN ops.outbox AS event ON event.id=inbox.event_id
  JOIN ops.jobs AS job
    ON inbox.result='DISPATCHED:'||job.id::text
   AND job.job_type='EVENT_DELIVERY'
   AND job.queue='workflow-worker' AND job.status='QUEUED'
  WHERE inbox.consumer='retention-worker'
    AND inbox.processed_at IS NULL
    AND event.aggregate_type='privacy_request'
    AND event.aggregate_id='31700000-0000-4000-8000-000000000001'
    AND event.aggregate_version=3
    AND event.event_type='privacy.request_decision_recorded.v1'
    AND event.payload->>'transition'='APPROVE';
  IF v_child_count<>1 OR v_delivery_count<>1 THEN
    RAISE EXCEPTION
      'Q4 workflow dispatch invalid: child %, delivery %',
      v_child_count,v_delivery_count;
  END IF;
END
$q4_workflow_dispatch$;
SQL

# Exercise the claimed-job loader, stale-fence rejection, and the completion
# owner's final legal-hold recheck without consuming the durable happy-path
# job.  The actual hold and every temporary claim mutation are rolled back.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SET CONSTRAINTS ALL DEFERRED;
SET LOCAL TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.q4w_sha256(p_value text)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,extensions,pg_temp
AS $digest$
  SELECT encode(
    extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex'
  )::char(64)
$digest$;

GRANT EXECUTE ON FUNCTION pg_temp.q4w_sha256(text)
  TO gurine_workflow_worker,gurine_control_api;

CREATE TEMP TABLE q4_worker_probe(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  job_id uuid NOT NULL,
  lease_token uuid NOT NULL,
  fencing_token bigint NOT NULL,
  job_payload jsonb NOT NULL,
  job_payload_digest char(64) NOT NULL,
  job_attempt_count integer NOT NULL,
  delivery_job_id uuid NOT NULL,
  delivery_lease_token uuid NOT NULL,
  delivery_fencing_token bigint NOT NULL,
  delivery_payload jsonb NOT NULL,
  delivery_attempt_count integer NOT NULL,
  approval_event_id uuid NOT NULL,
  transition_receipt_digest char(64) NOT NULL,
  response_id uuid NOT NULL,
  response_version bigint NOT NULL,
  response_content_sha256 char(64) NOT NULL,
  party_name text NOT NULL,
  request_state text NOT NULL,
  request_decision_version bigint NOT NULL,
  completion_count bigint NOT NULL,
  audit_count bigint NOT NULL,
  outbox_count bigint NOT NULL,
  placement_count bigint NOT NULL,
  legal_hold_count bigint NOT NULL,
  inbox_result text NOT NULL,
  inbox_processed_at timestamptz,
  post_hold_audit_count bigint,
  post_hold_outbox_count bigint,
  post_hold_placement_count bigint,
  post_hold_legal_hold_count bigint,
  loader_valid boolean NOT NULL DEFAULT false,
  load_fence_denied boolean NOT NULL DEFAULT false,
  execute_fence_denied boolean NOT NULL DEFAULT false,
  delegation_fence_denied boolean NOT NULL DEFAULT false,
  hold_execute_denied boolean NOT NULL DEFAULT false
) ON COMMIT DROP;

INSERT INTO q4_worker_probe(
  job_id,lease_token,fencing_token,job_payload,job_payload_digest,
  job_attempt_count,
  delivery_job_id,delivery_lease_token,delivery_fencing_token,
  delivery_payload,delivery_attempt_count,approval_event_id,
  transition_receipt_digest,
  response_id,response_version,response_content_sha256,party_name,
  request_state,request_decision_version,completion_count,audit_count,
  outbox_count,placement_count,legal_hold_count,
  inbox_result,inbox_processed_at
)
SELECT
  job.id,'31700000-0000-4000-8000-000000000050',
  job.fencing_token+1,job.payload,binding.job_payload_digest,
  job.attempt_count,
  delivery.id,'31700000-0000-4000-8000-000000000056',
  delivery.fencing_token+1,delivery.payload,delivery.attempt_count,
  transition.event_receipt_id,binding.transition_receipt_digest,
  response.id,response.version,response.response_content_sha256,
  response.party_name,request.state::text,request.decision_version,
  (SELECT count(*)
   FROM ops.privacy_response_party_name_correction_completion_receipts_v1),
  (SELECT count(*) FROM ops.audit_events),
  (SELECT count(*) FROM ops.outbox),
  (SELECT count(*) FROM ops.legal_hold_placement_receipts_v2),
  (SELECT count(*) FROM editorial.legal_holds),
  inbox.result,inbox.processed_at
FROM ops.jobs AS job
JOIN ops.privacy_response_party_name_correction_approval_bindings_v1
  AS binding ON binding.job_id=job.id
JOIN editorial.responses AS response ON response.id=binding.response_id
JOIN ops.privacy_requests_v2 AS request
  ON request.id=binding.privacy_request_id
JOIN ops.privacy_request_transition_receipts_v2 AS transition
  ON transition.transition_receipt_id=binding.transition_receipt_id
JOIN ops.inbox AS inbox
  ON inbox.consumer='retention-worker'
 AND inbox.event_id=transition.event_receipt_id
JOIN ops.jobs AS delivery
  ON inbox.result='DISPATCHED:'||delivery.id::text
 AND delivery.job_type='EVENT_DELIVERY'
 AND delivery.queue='workflow-worker'
 AND delivery.status='QUEUED'
WHERE job.job_type='PRIVACY_RESPONSE_PARTY_NAME_CORRECTION'
  AND job.queue='workflow-worker' AND job.status='QUEUED'
  AND binding.privacy_request_id=
    '31700000-0000-4000-8000-000000000001';

UPDATE ops.jobs AS job
SET status='RUNNING',lease_owner='q4-worker-boundary-probe',
    lease_token=probe.lease_token,
    lease_expires_at=clock_timestamp()+interval '5 minutes',
    fencing_token=probe.fencing_token,version=job.version+1
FROM q4_worker_probe AS probe
WHERE job.id=probe.job_id AND job.status='QUEUED';
UPDATE ops.jobs AS delivery
SET status='RUNNING',lease_owner='q4-delivery-fence-probe',
    lease_token=probe.delivery_lease_token,
    lease_expires_at=clock_timestamp()+interval '5 minutes',
    fencing_token=probe.delivery_fencing_token,
    version=delivery.version+1
FROM q4_worker_probe AS probe
WHERE delivery.id=probe.delivery_job_id AND delivery.status='QUEUED';
GRANT SELECT,UPDATE ON q4_worker_probe TO gurine_workflow_worker;

SET LOCAL ROLE gurine_workflow_worker;
DO $q4_worker_fence$
DECLARE
  v_probe q4_worker_probe%ROWTYPE;
  v_load jsonb;
  v_load_fence_denied boolean:=false;
  v_execute_fence_denied boolean:=false;
  v_delegation_fence_denied boolean:=false;
BEGIN
  SELECT * INTO STRICT v_probe FROM q4_worker_probe;
  v_load:=ops.load_privacy_response_party_name_correction_job_v1(
    v_probe.job_id,v_probe.lease_token,v_probe.fencing_token
  );
  IF jsonb_typeof(v_load)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_load))<>16
     OR v_load->>'schemaVersion'<>
        'privacy-response-party-name-correction-job-load.v1'
     OR v_load->>'jobId'<>v_probe.job_id::text
     OR v_load->>'correctionPlanId'<>
        v_probe.job_payload->>'correctionPlanId'
     OR v_load->>'privacyRequestId'<>
        v_probe.job_payload->>'privacyRequestId'
     OR v_load->>'responseId'<>v_probe.response_id::text
     OR v_load->>'expectedResponseVersion'<>
        v_probe.job_payload->>'expectedResponseVersion'
     OR v_load->>'expectedCurrentValueDigest'<>
        v_probe.job_payload->>'expectedCurrentValueDigest'
     OR NULLIF(v_load->>'requestedValueCiphertextBase64','') IS NULL
     OR v_load->>'requestedValueSha256'<>
        v_probe.job_payload->>'requestedValueSha256'
     OR v_load->>'requestedValueAadDigest'<>
        v_probe.job_payload->>'requestedValueAadDigest'
     OR v_load->>'requestedValueCiphertextDigest'<>
        v_probe.job_payload->>'requestedValueCiphertextDigest'
     OR v_load->>'encryptionKeyId'<>
        v_probe.job_payload->>'encryptionKeyId'
     OR v_load->>'planDigest'<>v_probe.job_payload->>'planDigest'
     OR v_load->>'approvalTransitionReceiptId'<>
        v_probe.job_payload->>'approvalTransitionReceiptId'
     OR v_load->>'approvalTransitionReceiptDigest'<>
        v_probe.job_payload->>'approvalTransitionReceiptDigest'
     OR v_load->>'jobPayloadDigest'<>btrim(v_probe.job_payload_digest)
     OR strpos(v_load::text,'Corrected Event Respondent')>0 THEN
    RAISE EXCEPTION 'Q4 correction loader closed binding invalid';
  END IF;

  -- Prove the owner happy path under the exact claimed fence, then force a
  -- subtransaction rollback so the durable worker remains the sole producer.
  BEGIN
    PERFORM ops.execute_privacy_response_party_name_correction_job_v1(
      v_probe.job_id,v_probe.lease_token,v_probe.fencing_token,
      'Corrected Event Respondent',
      pg_temp.q4w_sha256('Corrected Event Respondent')
    );
    RAISE EXCEPTION 'q4_worker_execute_probe_rollback'
      USING ERRCODE='PVT98';
  EXCEPTION WHEN SQLSTATE 'PVT98' THEN
    IF SQLERRM<>'q4_worker_execute_probe_rollback' THEN
      RAISE;
    END IF;
  END;

  BEGIN
    PERFORM ops.load_privacy_response_party_name_correction_job_v1(
      v_probe.job_id,'31700000-0000-4000-8000-000000000051',
      v_probe.fencing_token
    );
  EXCEPTION WHEN SQLSTATE '40001' THEN
    v_load_fence_denied:=SQLERRM=
      'privacy_response_party_name_job_fence_stale';
  END;
  BEGIN
    PERFORM ops.execute_privacy_response_party_name_correction_job_v1(
      v_probe.job_id,v_probe.lease_token,v_probe.fencing_token+1,
      'Corrected Event Respondent',
      pg_temp.q4w_sha256('Corrected Event Respondent')
    );
  EXCEPTION WHEN SQLSTATE '40001' THEN
    v_execute_fence_denied:=SQLERRM=
      'privacy_response_party_name_job_fence_stale';
  END;
  BEGIN
    PERFORM ops.ack_privacy_response_party_name_correction_delegation_v1(
      v_probe.approval_event_id,
      '31700000-0000-4000-8000-000000000001',
      v_probe.request_decision_version,
      v_probe.transition_receipt_digest,
      v_probe.delivery_job_id,
      '31700000-0000-4000-8000-000000000057',
      v_probe.delivery_fencing_token
    );
  EXCEPTION WHEN SQLSTATE '40001' THEN
    v_delegation_fence_denied:=SQLERRM=
      'privacy_response_party_name_correction_delivery_fence_stale';
  END;
  UPDATE q4_worker_probe
  SET loader_valid=true,
      load_fence_denied=v_load_fence_denied,
      execute_fence_denied=v_execute_fence_denied,
      delegation_fence_denied=v_delegation_fence_denied;
END
$q4_worker_fence$;
RESET ROLE;

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
) VALUES(
  '31700000-0000-4000-8000-000000000052',
  '31400000-0000-4000-8000-000000000022',
  pg_temp.q4w_sha256('q4-worker-hold-action'),
  pg_temp.q4w_sha256('q4-worker-hold-idempotency'),
  pg_temp.q4w_sha256('q4-worker-hold-step-up-token'),
  clock_timestamp()+interval '4 minutes',1,3,
  clock_timestamp()-interval '1 minute'
);
INSERT INTO ops.assertion_replay_guard(
  assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
) VALUES(
  'ACTOR','31700000-0000-4000-8000-000000000053',
  'identity-api','control-api',
  pg_temp.q4w_sha256('q4-worker-hold-assertion-request'),
  clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
);
INSERT INTO editorial.conflict_snapshots(
  id,subject_actor_id,target_type,target_id,target_version,target_digest,
  operation_id,action_kind,candidate_role,declaration_ids,
  declaration_set_digest,finding_set,finding_set_digest,
  authorship_digest,party_recipient_digest,role_digest,
  relationship_digest,funding_customer_digest,policy_digest,
  evaluation_state,blocker_codes,nonwaivable_blocker_count,
  evaluated_at,valid_until,evaluated_by_type,evaluated_by_id,
  snapshot_sha256,receipt_digest
)
SELECT
  '31700000-0000-4000-8000-000000000055',
  '31400000-0000-4000-8000-000000000003','RESPONSE',
  response_id::text,response_version,response_content_sha256,
  'placeLegalHold',NULL,'LEGAL_REVIEWER','{}'::uuid[],
  pg_temp.q4w_sha256('q4-worker-hold-declarations'),'{}'::jsonb,
  pg_temp.q4w_sha256('q4-worker-hold-findings'),
  pg_temp.q4w_sha256('q4-worker-hold-authorship'),
  pg_temp.q4w_sha256('q4-worker-hold-party'),
  pg_temp.q4w_sha256('q4-worker-hold-role'),
  pg_temp.q4w_sha256('q4-worker-hold-relationship'),
  pg_temp.q4w_sha256('q4-worker-hold-funding'),
  pg_temp.q4w_sha256('q4-worker-hold-policy'),'CLEAR','{}'::text[],0,
  clock_timestamp()-interval '1 second',
  clock_timestamp()+interval '10 minutes','SERVICE',
  'q4-event-runtime',pg_temp.q4w_sha256('q4-worker-hold-snapshot'),
  pg_temp.q4w_sha256('q4-worker-hold-receipt')
FROM q4_worker_probe;

CREATE TEMP TABLE q4_worker_hold_result(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  result jsonb NOT NULL
) ON COMMIT DROP;
GRANT SELECT,INSERT ON q4_worker_hold_result TO gurine_control_api;
GRANT SELECT ON q4_worker_probe TO gurine_control_api;
SET LOCAL ROLE gurine_control_api;
INSERT INTO q4_worker_hold_result(result)
SELECT ops.place_legal_hold_v2(
  jsonb_build_object(
    'target',jsonb_build_object(
      'targetKind','RESPONSE','targetId',response_id,
      'targetVersion',response_version,
      'targetDigest',btrim(response_content_sha256),
      'responseId',response_id
    ),'scopeAtoms',jsonb_build_array('RETENTION'),
    'affectedIds',jsonb_build_array(
      '31700000-0000-4000-8000-000000000001'::uuid
    ),'authorityReference','TEST_FIXTURE_ONLY Q4 worker-time hold authority',
    'reasonCode','LEGAL_PRESERVATION_REQUIRED',
    'reason','TEST_FIXTURE_ONLY block Q4 worker correction',
    'expiresAt',NULL,
    '_actorAssertionJti','31700000-0000-4000-8000-000000000053',
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','review.legal',
    '_actorAssertionRequestSha256',
      pg_temp.q4w_sha256('q4-worker-hold-assertion-request'),
    '_actorActionDigest',pg_temp.q4w_sha256('q4-worker-hold-action'),
    '_actorStepUpAuthorizationId',
      '31700000-0000-4000-8000-000000000052',
    '_actorIdempotencyKeySha256',
      pg_temp.q4w_sha256('q4-worker-hold-idempotency'),
    '_actorRequestKeySha256',
      pg_temp.q4w_sha256('q4-worker-hold-idempotency'),
    '_requestId','31700000-0000-4000-8000-000000000054',
    '_requestSha256',pg_temp.q4w_sha256('q4-worker-hold-request'),
    '_idempotencyKeySha256',
      pg_temp.q4w_sha256('q4-worker-hold-idempotency')
  ),'31400000-0000-4000-8000-000000000003',
  '31700000-0000-4000-8000-000000000054',
  pg_temp.q4w_sha256('q4-worker-hold-idempotency'),
  pg_temp.q4w_sha256('q4-worker-hold-request')
)
FROM q4_worker_probe;
RESET ROLE;

DO $q4_worker_hold_active$
DECLARE
  v_coverage jsonb:=ops.r6d_privacy_request_legal_hold_coverage_v1(
    '31700000-0000-4000-8000-000000000001',clock_timestamp()
  );
BEGIN
  IF NOT EXISTS(
       SELECT 1 FROM q4_worker_hold_result
       WHERE COALESCE((result->>'replayed')::boolean,true)=false
     ) OR COALESCE((v_coverage->>'active')::boolean,false)=false
     OR (v_coverage->>'activeCellCount')::bigint<>1 THEN
    RAISE EXCEPTION 'Q4 worker-time hold fixture invalid';
  END IF;
  UPDATE q4_worker_probe
  SET post_hold_audit_count=(SELECT count(*) FROM ops.audit_events),
      post_hold_outbox_count=(SELECT count(*) FROM ops.outbox),
      post_hold_placement_count=(
        SELECT count(*) FROM ops.legal_hold_placement_receipts_v2
      ),
      post_hold_legal_hold_count=(SELECT count(*) FROM editorial.legal_holds);
END
$q4_worker_hold_active$;

SET LOCAL ROLE gurine_workflow_worker;
DO $q4_worker_hold_execute$
DECLARE
  v_probe q4_worker_probe%ROWTYPE;
  v_denied boolean:=false;
BEGIN
  SELECT * INTO STRICT v_probe FROM q4_worker_probe;
  BEGIN
    PERFORM ops.execute_privacy_response_party_name_correction_job_v1(
      v_probe.job_id,v_probe.lease_token,v_probe.fencing_token,
      'Corrected Event Respondent',
      pg_temp.q4w_sha256('Corrected Event Respondent')
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_denied:=SQLERRM='privacy_correction_legal_hold_active';
  END;
  UPDATE q4_worker_probe SET hold_execute_denied=v_denied;
END
$q4_worker_hold_execute$;
RESET ROLE;

DO $q4_worker_zero_write$
DECLARE
  v_probe q4_worker_probe%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_probe FROM q4_worker_probe;
  IF NOT v_probe.loader_valid OR NOT v_probe.load_fence_denied
     OR NOT v_probe.execute_fence_denied
     OR NOT v_probe.delegation_fence_denied
     OR NOT v_probe.hold_execute_denied
     OR (SELECT count(*)
         FROM ops.privacy_response_party_name_correction_completion_receipts_v1)
        <>v_probe.completion_count
     OR (SELECT count(*) FROM ops.audit_events)<>
        v_probe.post_hold_audit_count
     OR (SELECT count(*) FROM ops.outbox)<>
        v_probe.post_hold_outbox_count
     OR (SELECT count(*) FROM ops.legal_hold_placement_receipts_v2)<>
        v_probe.post_hold_placement_count
     OR (SELECT count(*) FROM editorial.legal_holds)<>
        v_probe.post_hold_legal_hold_count
     OR NOT EXISTS(
       SELECT 1 FROM editorial.responses
       WHERE id=v_probe.response_id AND version=v_probe.response_version
         AND party_name=v_probe.party_name
         AND response_content_sha256=v_probe.response_content_sha256
     ) OR NOT EXISTS(
       SELECT 1 FROM ops.privacy_requests_v2
       WHERE id='31700000-0000-4000-8000-000000000001'
         AND state::text=v_probe.request_state
         AND decision_version=v_probe.request_decision_version
     ) OR NOT EXISTS(
       SELECT 1 FROM ops.jobs
       WHERE id=v_probe.job_id AND status='RUNNING'
         AND lease_token=v_probe.lease_token
         AND fencing_token=v_probe.fencing_token
         AND payload=v_probe.job_payload
         AND attempt_count=v_probe.job_attempt_count
         AND last_error_code IS NULL AND last_error_detail IS NULL
     ) OR NOT EXISTS(
       SELECT 1 FROM ops.jobs
       WHERE id=v_probe.delivery_job_id AND status='RUNNING'
         AND lease_token=v_probe.delivery_lease_token
         AND fencing_token=v_probe.delivery_fencing_token
         AND payload=v_probe.delivery_payload
         AND attempt_count=v_probe.delivery_attempt_count
         AND last_error_code IS NULL AND last_error_detail IS NULL
     ) OR (SELECT count(*) FROM ops.job_attempts
           WHERE job_id=v_probe.job_id)<>v_probe.job_attempt_count
     OR (SELECT count(*) FROM ops.job_attempts
         WHERE job_id=v_probe.delivery_job_id)<>
        v_probe.delivery_attempt_count
     OR NOT EXISTS(
       SELECT 1 FROM ops.inbox AS inbox
       JOIN ops.privacy_request_transition_receipts_v2 AS transition
         ON transition.event_receipt_id=inbox.event_id
       WHERE inbox.consumer='retention-worker'
         AND transition.privacy_request_id=
           '31700000-0000-4000-8000-000000000001'
         AND transition.transition='APPROVE'
         AND inbox.result=v_probe.inbox_result
         AND inbox.processed_at IS NOT DISTINCT FROM v_probe.inbox_processed_at
     ) THEN
    RAISE EXCEPTION 'Q4 worker fence/hold zero-write boundary invalid';
  END IF;
END
$q4_worker_zero_write$;
ROLLBACK;
SQL

if ! GURINE_ENV=development \
  WORKFLOW_DATABASE_URL="postgresql://gurine_workflow_worker:workflow_test@127.0.0.1:${postgres_port}/${database}" \
  FIELD_ENCRYPTION_KEY_CURRENT="$test_key" \
  OBJECT_STORE_ADAPTER=filesystem \
  OBJECT_STORE_FILESYSTEM_ROOT="$work/objects" \
  CLAMAV_HOST=127.0.0.1 CLAMAV_PORT="$clamav_port" WORKFLOW_ONCE=true \
  HOSTNAME="workflow-q4-correction-test" target/debug/gurine-workflow-worker; then
  docker exec "$container" psql -U postgres -d "$database" -x -c \
    "SELECT job_type,status,last_error_code,attempt_count FROM ops.jobs WHERE queue='workflow-worker' AND (job_type='PRIVACY_RESPONSE_PARTY_NAME_CORRECTION' OR payload->>'consumerId'='retention-worker') ORDER BY created_at,id" >&2
  exit 1
fi

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $q4_completion$
DECLARE
  v_party_name constant text := 'Corrected Event Respondent';
  v_party_name_digest char(64):=encode(extensions.digest(
    convert_to(v_party_name,'UTF8'),'sha256'
  ),'hex');
  v_job ops.jobs%ROWTYPE;
  v_attempt ops.job_attempts%ROWTYPE;
  v_delivery ops.jobs%ROWTYPE;
  v_delivery_attempt ops.job_attempts%ROWTYPE;
  v_inbox ops.inbox%ROWTYPE;
  v_binding
    ops.privacy_response_party_name_correction_approval_bindings_v1%ROWTYPE;
  v_receipt
    ops.privacy_response_party_name_correction_completion_receipts_v1%ROWTYPE;
  v_response editorial.responses%ROWTYPE;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_event ops.outbox%ROWTYPE;
  v_approval_event ops.outbox%ROWTYPE;
  v_audit ops.audit_events%ROWTYPE;
  v_expected_completion jsonb;
  v_expected_delegation jsonb;
  v_expected_event jsonb;
  v_expected_receipt jsonb;
  v_expected_audit_details jsonb;
  v_update_denied boolean:=false;
  v_delete_denied boolean:=false;
BEGIN
  SELECT job.* INTO STRICT v_job
  FROM ops.jobs AS job
  WHERE job.job_type='PRIVACY_RESPONSE_PARTY_NAME_CORRECTION'
    AND job.queue='workflow-worker'
    AND job.payload->>'privacyRequestId'=
      '31700000-0000-4000-8000-000000000001';
  SELECT binding.* INTO STRICT v_binding
  FROM ops.privacy_response_party_name_correction_approval_bindings_v1
    AS binding
  WHERE binding.job_id=v_job.id;
  SELECT attempt.* INTO STRICT v_attempt
  FROM ops.job_attempts AS attempt
  WHERE attempt.job_id=v_job.id
    AND attempt.attempt=v_job.attempt_count;
  IF v_job.status<>'SUCCEEDED' OR v_attempt.outcome<>'SUCCEEDED' THEN
    RAISE EXCEPTION
      'Q4 correction worker did not complete: status %, job error %, attempt outcome %, attempt error %',
      v_job.status,v_job.last_error_code,v_attempt.outcome,v_attempt.error_code;
  END IF;
  SELECT receipt.* INTO STRICT v_receipt
  FROM ops.privacy_response_party_name_correction_completion_receipts_v1
    AS receipt
  WHERE receipt.job_id=v_job.id;
  SELECT response.* INTO STRICT v_response
  FROM editorial.responses AS response
  WHERE response.id=v_receipt.response_id;
  SELECT request.* INTO STRICT v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=v_receipt.privacy_request_id;
  SELECT event.* INTO STRICT v_event
  FROM ops.outbox AS event
  WHERE event.id=v_receipt.outbox_event_id;
  SELECT audit.* INTO STRICT v_audit
  FROM ops.audit_events AS audit
  WHERE audit.id=v_receipt.audit_event_id;
  SELECT event.* INTO STRICT v_approval_event
  FROM ops.outbox AS event
  JOIN ops.privacy_request_transition_receipts_v2 AS transition
    ON transition.event_receipt_id=event.id
  WHERE transition.transition_receipt_id=v_binding.transition_receipt_id;
  SELECT inbox.* INTO STRICT v_inbox
  FROM ops.inbox AS inbox
  WHERE inbox.consumer='retention-worker'
    AND inbox.event_id=v_approval_event.id;
  SELECT delivery.* INTO STRICT v_delivery
  FROM ops.jobs AS delivery
  WHERE delivery.job_type='EVENT_DELIVERY'
    AND delivery.queue='workflow-worker'
    AND delivery.payload->>'consumerId'='retention-worker'
    AND delivery.payload->>'eventId'=v_approval_event.id::text;
  SELECT attempt.* INTO STRICT v_delivery_attempt
  FROM ops.job_attempts AS attempt
  WHERE attempt.job_id=v_delivery.id
    AND attempt.attempt=v_delivery.attempt_count;

  v_expected_completion:=jsonb_build_object(
    'schemaVersion',
      'privacy-response-party-name-correction-completion.v1',
    'status','COMPLETED','jobId',v_job.id,
    'privacyRequestId',v_receipt.privacy_request_id,
    'correctionPlanId',v_receipt.correction_plan_id,
    'responseId',v_receipt.response_id,
    'responseVersion',v_receipt.response_version,
    'partyNameDigest',btrim(v_receipt.party_name_digest),
    'completionReceiptId',v_receipt.completion_receipt_id,
    'completionReceiptDigest',btrim(v_receipt.receipt_digest),
    'auditEventId',v_receipt.audit_event_id,
    'outboxEventIds',jsonb_build_array(v_receipt.outbox_event_id),
    'completedAt',v_receipt.completed_at,'replayed',false
  );
  v_expected_delegation:=jsonb_build_object(
    'schemaVersion',
      'privacy-response-party-name-correction-delegation.v1',
    'eventId',v_approval_event.id,
    'privacyRequestId',v_receipt.privacy_request_id,
    'decisionVersion',v_binding.request_decision_version,
    'transitionReceiptDigest',btrim(v_binding.transition_receipt_digest),
    'jobId',v_job.id,
    'jobPayloadDigest',btrim(v_binding.job_payload_digest),
    'delegated',true
  );
  v_expected_event:=jsonb_build_object(
    'privacyRequestId',v_receipt.privacy_request_id,
    'correctionPlanId',v_receipt.correction_plan_id,
    'responseId',v_receipt.response_id,
    'responseVersion',v_receipt.response_version,
    'partyNameDigest',btrim(v_receipt.party_name_digest),
    'completionReceiptId',v_receipt.completion_receipt_id,
    'completionReceiptDigest',btrim(v_receipt.receipt_digest),
    'auditEventId',v_receipt.audit_event_id,
    'completedAt',v_receipt.completed_at
  );
  v_expected_receipt:=jsonb_build_object(
    'schemaVersion',
      'privacy-response-party-name-correction-completion-receipt.v1',
    'completionReceiptId',v_receipt.completion_receipt_id,
    'jobId',v_job.id,'jobPayloadDigest',btrim(v_receipt.job_payload_digest),
    'privacyRequestId',v_receipt.privacy_request_id,
    'approvalDecisionVersion',v_receipt.approval_decision_version,
    'completionDecisionVersion',v_receipt.completion_decision_version,
    'correctionPlanId',v_receipt.correction_plan_id,
    'planVersion',v_receipt.plan_version,
    'planDigest',btrim(v_receipt.plan_digest),
    'approvalBindingId',v_receipt.approval_binding_id,
    'approvalBindingDigest',btrim(v_receipt.approval_binding_digest),
    'responseId',v_receipt.response_id,
    'priorResponseVersion',v_receipt.prior_response_version,
    'responseVersion',v_receipt.response_version,
    'priorPartyNameDigest',btrim(v_receipt.prior_party_name_digest),
    'partyNameDigest',btrim(v_receipt.party_name_digest),
    'holdCoverageDigest',btrim(v_receipt.hold_coverage_digest),
    'approvalTransitionReceiptId',v_receipt.approval_transition_receipt_id,
    'approvalTransitionReceiptDigest',
      btrim(v_receipt.approval_transition_receipt_digest),
    'auditEventId',v_receipt.audit_event_id,
    'completedAt',v_receipt.completed_at
  );
  v_expected_audit_details:=jsonb_build_object(
    'jobId',v_job.id,
    'jobPayloadDigest',btrim(v_receipt.job_payload_digest),
    'completionReceiptId',v_receipt.completion_receipt_id,
    'privacyRequestId',v_receipt.privacy_request_id,
    'approvalDecisionVersion',v_receipt.approval_decision_version,
    'completionDecisionVersion',v_receipt.completion_decision_version,
    'correctionPlanId',v_receipt.correction_plan_id,
    'planDigest',btrim(v_receipt.plan_digest),
    'approvalBindingDigest',btrim(v_receipt.approval_binding_digest),
    'priorResponseVersion',v_receipt.prior_response_version,
    'responseVersion',v_receipt.response_version,
    'priorPartyNameDigest',btrim(v_receipt.prior_party_name_digest),
    'partyNameDigest',btrim(v_receipt.party_name_digest),
    'holdCoverageDigest',btrim(v_receipt.hold_coverage_digest),
    'approvalTransitionReceiptDigest',
      btrim(v_receipt.approval_transition_receipt_digest)
  );

  IF v_job.status<>'SUCCEEDED' OR v_job.completed_at IS NULL
     OR v_job.last_error_code IS NOT NULL
     OR v_job.last_error_detail IS NOT NULL
     OR v_job.attempt_count<>1
     OR v_attempt.finished_at IS NULL OR v_attempt.outcome<>'SUCCEEDED'
     OR v_attempt.error_code IS NOT NULL OR v_attempt.error_detail IS NOT NULL
     OR jsonb_typeof(v_attempt.metrics)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_attempt.metrics))<>14
     OR v_attempt.metrics IS DISTINCT FROM v_expected_completion
     OR v_receipt.job_payload_digest<>v_binding.job_payload_digest
     OR v_receipt.approval_binding_id<>v_binding.approval_binding_id
     OR v_receipt.approval_binding_digest<>v_binding.binding_digest
     OR v_receipt.approval_decision_version<>
        v_binding.request_decision_version
     OR v_receipt.completion_decision_version<>
        v_binding.request_decision_version+1
     OR v_receipt.correction_plan_id<>v_binding.correction_plan_id
     OR v_receipt.response_id<>v_binding.response_id
     OR v_receipt.prior_response_version<>
        v_binding.expected_response_version
     OR v_receipt.response_version<>
        v_binding.expected_response_version+1
     OR v_receipt.prior_party_name_digest<>
        v_binding.expected_current_value_digest
     OR v_receipt.party_name_digest<>v_party_name_digest
     OR v_receipt.receipt_payload IS DISTINCT FROM v_expected_receipt
     OR v_receipt.receipt_canonical<>
        ops.canonical_jsonb_v1(v_expected_receipt)
     OR v_receipt.receipt_digest<>encode(extensions.digest(
          v_receipt.receipt_canonical,'sha256'
        ),'hex')
     OR v_response.party_name<>v_party_name
     OR v_response.version<>v_receipt.response_version
     OR encode(extensions.digest(
          convert_to(v_response.party_name,'UTF8'),'sha256'
        ),'hex')<>v_party_name_digest
     OR v_request.state<>'COMPLETED'
     OR v_request.decision_version<>v_receipt.completion_decision_version
     OR v_event.aggregate_type<>'editorial_response'
     OR v_event.aggregate_id<>v_receipt.response_id::text
     OR v_event.aggregate_version<>v_receipt.response_version
     OR v_event.event_type<>'privacy.response_party_name_corrected.v1'
     OR v_event.occurred_at<>v_receipt.completed_at
     OR v_event.payload IS DISTINCT FROM v_expected_event
     OR ops.r6d_outbox_envelope_digest_v1(v_event.id)<>
        v_receipt.outbox_event_digest
     OR v_audit.actor_type<>'SERVICE'
     OR v_audit.actor_id<>'workflow-worker'
     OR v_audit.action<>
        'privacy.response_party_name.correction.complete'
     OR v_audit.object_type<>'RESPONSE'
     OR v_audit.object_id<>v_receipt.response_id::text
     OR v_audit.outcome<>'SUCCESS'
     OR v_audit.request_id<>v_job.id
     OR v_audit.details IS DISTINCT FROM v_expected_audit_details
     OR (SELECT count(*)
         FROM ops.privacy_response_party_name_correction_completion_receipts_v1
         WHERE privacy_request_id=v_receipt.privacy_request_id)<>1 THEN
    RAISE EXCEPTION 'Q4 correction completion authority invalid';
  END IF;

  IF v_delivery.status<>'SUCCEEDED' OR v_delivery.completed_at IS NULL
     OR v_delivery.last_error_code IS NOT NULL
     OR v_delivery.last_error_detail IS NOT NULL
     OR v_delivery.attempt_count<>1
     OR v_delivery_attempt.finished_at IS NULL
     OR v_delivery_attempt.outcome<>'SUCCEEDED'
     OR v_delivery_attempt.error_code IS NOT NULL
     OR v_delivery_attempt.error_detail IS NOT NULL
     OR jsonb_typeof(v_delivery_attempt.metrics)<>'object'
     OR (SELECT count(*)
         FROM jsonb_object_keys(v_delivery_attempt.metrics))<>8
     OR v_delivery_attempt.metrics IS DISTINCT FROM v_expected_delegation
     OR v_inbox.processed_at IS NULL OR v_inbox.result<>'SUCCEEDED' THEN
    RAISE EXCEPTION
      'Q4 correction delegation ACK invalid: status %, completed %, job error %, attempts %, attempt outcome %, attempt error %, metric type %, metric keys %, metric exact %, inbox processed %, inbox result %',
      v_delivery.status,v_delivery.completed_at IS NOT NULL,
      v_delivery.last_error_code,v_delivery.attempt_count,
      v_delivery_attempt.outcome,v_delivery_attempt.error_code,
      jsonb_typeof(v_delivery_attempt.metrics),
      CASE WHEN jsonb_typeof(v_delivery_attempt.metrics)='object'
        THEN (SELECT count(*) FROM jsonb_object_keys(v_delivery_attempt.metrics))
        ELSE NULL END,
      v_delivery_attempt.metrics IS NOT DISTINCT FROM v_expected_delegation,
      v_inbox.processed_at IS NOT NULL,v_inbox.result;
  END IF;

  IF EXISTS(
       SELECT 1
       FROM unnest(ARRAY[
         v_job.payload::text,
         v_attempt.metrics::text,
         v_delivery_attempt.metrics::text,
         v_audit.details::text,
         v_event.payload::text,
         v_receipt.receipt_payload::text,
         to_jsonb(v_receipt)::text,
         v_job.last_error_code,v_job.last_error_detail,
         v_attempt.error_code,v_attempt.error_detail,
         v_delivery.last_error_code,v_delivery.last_error_detail,
         v_delivery_attempt.error_code,v_delivery_attempt.error_detail,
         v_event.last_error
       ]) AS redacted(value)
       WHERE strpos(COALESCE(value,''),v_party_name)>0
     ) THEN
    RAISE EXCEPTION 'Q4 correction plaintext escaped redacted artifacts';
  END IF;

  BEGIN
    UPDATE ops.privacy_response_party_name_correction_completion_receipts_v1
    SET completed_at=completed_at
    WHERE completion_receipt_id=v_receipt.completion_receipt_id;
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_update_denied:=SQLERRM='immutable_record';
  END;
  BEGIN
    DELETE FROM
      ops.privacy_response_party_name_correction_completion_receipts_v1
    WHERE completion_receipt_id=v_receipt.completion_receipt_id;
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_delete_denied:=SQLERRM='immutable_record';
  END;
  IF NOT v_update_denied OR NOT v_delete_denied
     OR NOT EXISTS(
       SELECT 1
       FROM ops.privacy_response_party_name_correction_completion_receipts_v1
       WHERE completion_receipt_id=v_receipt.completion_receipt_id
         AND receipt_digest=v_receipt.receipt_digest
     ) THEN
    RAISE EXCEPTION 'Q4 correction completion receipt is mutable';
  END IF;
END
$q4_completion$;
SQL

# The control workspace must close the COMPLETED correction graph through the
# immutable receipt while the public receipt-session reader remains digest-only.
# Roll the exchange back so this reader probe cannot add durable audit/outbox
# effects or perturb the later exact-replay and notification cardinalities.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" -v q4_response_id="$q4_response_id" \
  <<'SQL' >/dev/null
BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SET LOCAL TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.q4pc_sha256(p_value text)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,extensions,pg_temp
AS $digest$
  SELECT encode(
    extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex'
  )::char(64)
$digest$;

GRANT EXECUTE ON FUNCTION pg_temp.q4pc_sha256(text)
  TO gurine_submission_api;

CREATE TEMP TABLE q4_post_completion_expected ON COMMIT DROP AS
SELECT
  receipt.privacy_request_id AS request_id,
  receipt.response_id,
  receipt.approval_decision_version,
  receipt.completion_decision_version,
  receipt.approval_transition_receipt_id,
  receipt.approval_transition_receipt_digest,
  transition.reason_code AS decision_reason_code,
  receipt.completion_receipt_id,
  receipt.receipt_digest AS completion_receipt_digest,
  receipt.response_version,
  receipt.party_name_digest,
  receipt.completed_at
FROM ops.privacy_response_party_name_correction_completion_receipts_v1
  AS receipt
JOIN ops.privacy_request_transition_receipts_v2 AS transition
  ON transition.transition_receipt_id=
     receipt.approval_transition_receipt_id
 AND transition.privacy_request_id=receipt.privacy_request_id
 AND transition.decision_version=receipt.approval_decision_version
 AND transition.transition='APPROVE'
 AND transition.state='APPROVED'
 AND transition.receipt_digest=
     receipt.approval_transition_receipt_digest
WHERE receipt.privacy_request_id=
      '31700000-0000-4000-8000-000000000001'
  AND receipt.response_id=:'q4_response_id'::uuid;

DO $q4_post_completion_fixture$
BEGIN
  IF (SELECT count(*) FROM q4_post_completion_expected)<>1 THEN
    RAISE EXCEPTION 'Q4 post-completion reader fixture is not singular';
  END IF;
END
$q4_post_completion_fixture$;
GRANT SELECT ON q4_post_completion_expected
  TO gurine_control_api,gurine_submission_api;

SET LOCAL ROLE gurine_control_api;
DO $q4_completed_workspace$
DECLARE
  v_expected record;
  v_workspace jsonb;
  v_projection jsonb;
BEGIN
  SELECT * INTO STRICT v_expected FROM q4_post_completion_expected;
  v_workspace:=ops.read_privacy_retention_request_workspace_v2(
    v_expected.request_id
  );
  v_projection:=v_workspace->'accessProjection';

  IF v_workspace IS NULL OR jsonb_typeof(v_workspace)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_workspace))<>20
     OR NOT v_workspace ?& ARRAY[
       'request','identityVerificationReceiptId',
       'identityVerificationReceiptDigest','policyVersion','policyDigest',
       'calendarVersionId','calendarDigest','inventorySnapshotDigest',
       'holdCoverageDigest','activeHoldIds','affectedRecordClasses',
       'locationReceipts','decisionReceipts','completionReceiptId',
       'completionReceiptDigest','completedResponseVersion',
       'completedValueDigest','accessProjection','asOf','links'
     ]
     OR jsonb_typeof(v_workspace->'request')<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(
          v_workspace->'request'))<>12
     OR NOT (v_workspace->'request') ?& ARRAY[
       'retentionRequestId','requestType','decisionVersion','state',
       'jurisdiction','scopeDigest','identityState','identityVerifiedAt',
       'dueAt','legalHoldBlocked','createdAt','updatedAt'
     ]
     OR (v_workspace#>>'{request,retentionRequestId}')::uuid<>
        v_expected.request_id
     OR v_workspace#>>'{request,requestType}'<>'CORRECTION'
     OR v_workspace#>>'{request,state}'<>'COMPLETED'
     OR (v_workspace#>>'{request,decisionVersion}')::bigint<>
        v_expected.completion_decision_version
     OR v_workspace#>>'{request,identityState}'<>'VERIFIED'
     OR (v_workspace#>>'{request,legalHoldBlocked}')::boolean
     OR v_workspace#>>'{request,updatedAt}'<>
        to_jsonb(v_expected.completed_at)#>>'{}'
     OR jsonb_array_length(v_workspace->'decisionReceipts')<>3
     OR (SELECT jsonb_agg(decision.value->>'transition'
          ORDER BY decision.ordinality)
         FROM jsonb_array_elements(v_workspace->'decisionReceipts')
           WITH ORDINALITY AS decision(value,ordinality))<>
       '["VERIFY_IDENTITY","START_REVIEW","APPROVE"]'::jsonb
     OR (v_workspace->>'completionReceiptId')::uuid<>
        v_expected.completion_receipt_id
     OR v_workspace->>'completionReceiptDigest'<>
        btrim(v_expected.completion_receipt_digest)
     OR (v_workspace->>'completedResponseVersion')::bigint<>
        v_expected.response_version
     OR v_workspace->>'completedValueDigest'<>
        btrim(v_expected.party_name_digest)
     OR jsonb_typeof(v_projection)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_projection))<>17
     OR NOT v_projection ?& ARRAY[
       'schemaVersion','retentionRequestId','targetObjectType',
       'targetObjectId','fieldPath','partyName','currentValueDigest',
       'projectionDigest','responseVersion',
       'privacyIdentityProofReceiptId',
       'privacyIdentityProofReceiptDigest','responseSubmissionReceiptId',
       'responseSubmissionReceiptDigest','responseOriginReceiptId',
       'responseOriginReceiptDigest','sourceResponseRequestId','asOf'
     ]
     OR v_projection->>'schemaVersion'<>
        'privacy-response-party-name-access.v1'
     OR (v_projection->>'retentionRequestId')::uuid<>
        v_expected.request_id
     OR v_projection->>'targetObjectType'<>'RESPONSE'
     OR (v_projection->>'targetObjectId')::uuid<>v_expected.response_id
     OR v_projection->>'fieldPath'<>'/partyName'
     OR v_projection->>'partyName'<>'Corrected Event Respondent'
     OR v_projection->>'currentValueDigest'<>
        btrim(v_expected.party_name_digest)
     OR (v_projection->>'responseVersion')::bigint<>
        v_expected.response_version
     OR v_projection->>'asOf'<>v_workspace->>'asOf'
     OR v_workspace->'inventorySnapshotDigest'<>'null'::jsonb
     OR v_workspace->'holdCoverageDigest'<>'null'::jsonb
     OR v_workspace->'activeHoldIds'<>'[]'::jsonb
     OR v_workspace->'affectedRecordClasses'<>'[]'::jsonb
     OR v_workspace->'locationReceipts'<>'[]'::jsonb
     OR v_workspace->'links'<>'[]'::jsonb
     OR lower(v_workspace::text) LIKE '%ciphertext%'
     OR lower(v_workspace::text) LIKE '%encryptionkeyid%' THEN
    RAISE EXCEPTION 'Q4 completed workspace 20/17-key ABI invalid';
  END IF;
END
$q4_completed_workspace$;
RESET ROLE;

SET LOCAL ROLE gurine_submission_api;
DO $q4_completed_public_getter$
DECLARE
  v_expected record;
  v_session_sha256 char(64):=
    pg_temp.q4pc_sha256('q4-post-completion-public-session');
  v_exchange jsonb;
  v_public jsonb;
BEGIN
  SELECT * INTO STRICT v_expected FROM q4_post_completion_expected;
  v_exchange:=ops.exchange_privacy_request_receipt_token_v2(
    pg_temp.q4pc_sha256('q4-receipt-token-hmac'),
    v_session_sha256,'public-web',
    '31700000-0000-4000-8000-000000000051'::uuid,
    pg_temp.q4pc_sha256('q4-post-completion-exchange-idempotency'),
    pg_temp.q4pc_sha256('q4-post-completion-exchange-request')
  );
  v_public:=ops.get_privacy_request_v2(v_session_sha256,'public-web');

  IF jsonb_typeof(v_exchange)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_exchange))<>12
     OR NOT v_exchange ?& ARRAY[
       'sessionId','privacyRequestId','sessionKind','scopeType','scopeId',
       'bffIssuer','issuedAt','expiresAt','auditEventId','emittedEventIds',
       'receiptDigest','replayed'
     ]
     OR COALESCE((v_exchange->>'replayed')::boolean,true)
     OR (v_exchange->>'privacyRequestId')::uuid<>v_expected.request_id
     OR (v_exchange->>'scopeId')::uuid<>v_expected.request_id
     OR v_exchange->>'sessionKind'<>'PRIVACY_REQUEST_RECEIPT'
     OR v_exchange->>'scopeType'<>'PRIVACY_REQUEST'
     OR v_exchange->>'bffIssuer'<>'public-web'
     OR jsonb_array_length(v_exchange->'emittedEventIds')<>1
     OR jsonb_typeof(v_public)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_public))<>12
     OR NOT v_public ?& ARRAY[
       'request','decisionReasonCode','decisionReceiptId',
       'decisionReceiptSha256','refusalNoticeReceiptId',
       'refusalNoticeReceiptSha256','noticeReceiptIds',
       'noticeReceiptSha256s','nextActionCodes','asOf','links','operationId'
     ]
     OR jsonb_typeof(v_public->'request')<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_public->'request'))<>10
     OR NOT (v_public->'request') ?& ARRAY[
       'privacyRequestId','requestType','state','jurisdiction','scopeDigest',
       'identityState','identityVerifiedAt','dueAt','createdAt','updatedAt'
     ]
     OR (v_public#>>'{request,privacyRequestId}')::uuid<>
        v_expected.request_id
     OR v_public#>>'{request,requestType}'<>'CORRECTION'
     OR v_public#>>'{request,state}'<>'COMPLETED'
     OR v_public#>>'{request,identityState}'<>'VERIFIED'
     OR v_public#>>'{request,updatedAt}'<>
        to_jsonb(v_expected.completed_at)#>>'{}'
     OR v_public->>'decisionReasonCode'<>
        v_expected.decision_reason_code
     OR (v_public->>'decisionReceiptId')::uuid<>
        v_expected.approval_transition_receipt_id
     OR v_public->>'decisionReceiptSha256'<>
        btrim(v_expected.approval_transition_receipt_digest)
     OR v_public->'refusalNoticeReceiptId'<>'null'::jsonb
     OR v_public->'refusalNoticeReceiptSha256'<>'null'::jsonb
     OR jsonb_typeof(v_public->'noticeReceiptIds')<>'array'
     OR jsonb_typeof(v_public->'noticeReceiptSha256s')<>'array'
     OR jsonb_array_length(v_public->'noticeReceiptIds')<>
        jsonb_array_length(v_public->'noticeReceiptSha256s')
     OR v_public->'nextActionCodes'<>'["COMPLETE"]'::jsonb
     OR v_public->'links'<>'[]'::jsonb
     OR v_public->>'operationId'<>'getPrivacyRequest'
     OR strpos(v_public::text,'Corrected Event Respondent')>0
     OR strpos(v_public::text,v_expected.response_id::text)>0
     OR lower(v_public::text) LIKE '%partyname%'
     OR lower(v_public::text) LIKE '%accessprojection%'
     OR lower(v_public::text) LIKE '%cipher%'
     OR lower(v_public::text) LIKE '%encryptionkey%'
     OR lower(v_public::text) LIKE '%keyversion%' THEN
    RAISE EXCEPTION 'Q4 completed public getter 12-key secretless ABI invalid';
  END IF;
END
$q4_completed_public_getter$;
RESET ROLE;
ROLLBACK;
SQL

# Requeue the exact completed correction job and its original approval-event
# delivery identity.  Reset only the matching inbox marker; no new event, job,
# plan, or receipt is synthesized.  The second worker pass must replay both
# owners while preserving every domain effect at cardinality one.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $q4_prepare_exact_replay$
DECLARE
  v_job ops.jobs%ROWTYPE;
  v_delivery ops.jobs%ROWTYPE;
  v_binding
    ops.privacy_response_party_name_correction_approval_bindings_v1%ROWTYPE;
  v_event ops.outbox%ROWTYPE;
  v_changed integer;
BEGIN
  SELECT job.* INTO STRICT v_job
  FROM ops.jobs AS job
  WHERE job.job_type='PRIVACY_RESPONSE_PARTY_NAME_CORRECTION'
    AND job.queue='workflow-worker'
    AND job.payload->>'privacyRequestId'=
      '31700000-0000-4000-8000-000000000001';
  SELECT binding.* INTO STRICT v_binding
  FROM ops.privacy_response_party_name_correction_approval_bindings_v1
    AS binding
  WHERE binding.job_id=v_job.id;
  SELECT event.* INTO STRICT v_event
  FROM ops.outbox AS event
  JOIN ops.privacy_request_transition_receipts_v2 AS transition
    ON transition.event_receipt_id=event.id
  WHERE transition.transition_receipt_id=v_binding.transition_receipt_id;
  SELECT delivery.* INTO STRICT v_delivery
  FROM ops.jobs AS delivery
  WHERE delivery.job_type='EVENT_DELIVERY'
    AND delivery.queue='workflow-worker'
    AND delivery.payload->>'consumerId'='retention-worker'
    AND delivery.payload->>'eventId'=v_event.id::text;
  IF v_job.status<>'SUCCEEDED' OR v_job.attempt_count<>1
     OR v_delivery.status<>'SUCCEEDED' OR v_delivery.attempt_count<>1
     OR NOT EXISTS(
       SELECT 1 FROM ops.inbox
       WHERE consumer='retention-worker' AND event_id=v_event.id
         AND processed_at IS NOT NULL AND result='SUCCEEDED'
     ) THEN
    RAISE EXCEPTION 'Q4 exact replay precondition invalid';
  END IF;

  UPDATE ops.jobs
  SET status='QUEUED',run_after=clock_timestamp(),
      lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,
      completed_at=NULL,last_error_code=NULL,last_error_detail=NULL,
      version=version+1
  WHERE id IN (v_job.id,v_delivery.id) AND status='SUCCEEDED';
  GET DIAGNOSTICS v_changed=ROW_COUNT;
  IF v_changed<>2 THEN
    RAISE EXCEPTION 'Q4 exact replay job reset lost: %',v_changed;
  END IF;
  UPDATE ops.inbox
  SET processed_at=NULL,result='DISPATCHED:'||v_delivery.id::text
  WHERE consumer='retention-worker' AND event_id=v_event.id
    AND processed_at IS NOT NULL AND result='SUCCEEDED';
  GET DIAGNOSTICS v_changed=ROW_COUNT;
  IF v_changed<>1 THEN
    RAISE EXCEPTION 'Q4 exact replay inbox reset lost: %',v_changed;
  END IF;
END
$q4_prepare_exact_replay$;
SQL

if ! GURINE_ENV=development \
  WORKFLOW_DATABASE_URL="postgresql://gurine_workflow_worker:workflow_test@127.0.0.1:${postgres_port}/${database}" \
  FIELD_ENCRYPTION_KEY_CURRENT="$test_key" \
  OBJECT_STORE_ADAPTER=filesystem \
  OBJECT_STORE_FILESYSTEM_ROOT="$work/objects" \
  CLAMAV_HOST=127.0.0.1 CLAMAV_PORT="$clamav_port" WORKFLOW_ONCE=true \
  HOSTNAME="workflow-q4-correction-replay-test" \
  target/debug/gurine-workflow-worker; then
  docker exec "$container" psql -U postgres -d "$database" -x -c \
    "SELECT job_type,status,last_error_code,attempt_count FROM ops.jobs WHERE queue='workflow-worker' AND (job_type='PRIVACY_RESPONSE_PARTY_NAME_CORRECTION' OR payload->>'consumerId'='retention-worker') ORDER BY created_at,id" >&2
  exit 1
fi

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $q4_exact_replay$
DECLARE
  v_party_name constant text := 'Corrected Event Respondent';
  v_job ops.jobs%ROWTYPE;
  v_delivery ops.jobs%ROWTYPE;
  v_first_attempt ops.job_attempts%ROWTYPE;
  v_replay_attempt ops.job_attempts%ROWTYPE;
  v_first_delivery_attempt ops.job_attempts%ROWTYPE;
  v_replay_delivery_attempt ops.job_attempts%ROWTYPE;
  v_binding
    ops.privacy_response_party_name_correction_approval_bindings_v1%ROWTYPE;
  v_receipt
    ops.privacy_response_party_name_correction_completion_receipts_v1%ROWTYPE;
  v_response editorial.responses%ROWTYPE;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_event ops.outbox%ROWTYPE;
  v_approval_event ops.outbox%ROWTYPE;
  v_expected_completion jsonb;
  v_expected_first_completion jsonb;
  v_expected_delegation jsonb;
BEGIN
  SELECT job.* INTO STRICT v_job
  FROM ops.jobs AS job
  WHERE job.job_type='PRIVACY_RESPONSE_PARTY_NAME_CORRECTION'
    AND job.queue='workflow-worker'
    AND job.payload->>'privacyRequestId'=
      '31700000-0000-4000-8000-000000000001';
  SELECT binding.* INTO STRICT v_binding
  FROM ops.privacy_response_party_name_correction_approval_bindings_v1
    AS binding
  WHERE binding.job_id=v_job.id;
  SELECT receipt.* INTO STRICT v_receipt
  FROM ops.privacy_response_party_name_correction_completion_receipts_v1
    AS receipt
  WHERE receipt.job_id=v_job.id;
  SELECT response.* INTO STRICT v_response
  FROM editorial.responses AS response
  WHERE response.id=v_receipt.response_id;
  SELECT request.* INTO STRICT v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=v_receipt.privacy_request_id;
  SELECT event.* INTO STRICT v_event
  FROM ops.outbox AS event
  WHERE event.id=v_receipt.outbox_event_id;
  SELECT event.* INTO STRICT v_approval_event
  FROM ops.outbox AS event
  JOIN ops.privacy_request_transition_receipts_v2 AS transition
    ON transition.event_receipt_id=event.id
  WHERE transition.transition_receipt_id=v_binding.transition_receipt_id;
  SELECT delivery.* INTO STRICT v_delivery
  FROM ops.jobs AS delivery
  WHERE delivery.job_type='EVENT_DELIVERY'
    AND delivery.queue='workflow-worker'
    AND delivery.payload->>'consumerId'='retention-worker'
    AND delivery.payload->>'eventId'=v_approval_event.id::text;
  SELECT attempt.* INTO STRICT v_first_attempt
  FROM ops.job_attempts AS attempt
  WHERE attempt.job_id=v_job.id AND attempt.attempt=1;
  SELECT attempt.* INTO STRICT v_replay_attempt
  FROM ops.job_attempts AS attempt
  WHERE attempt.job_id=v_job.id AND attempt.attempt=2;
  SELECT attempt.* INTO STRICT v_first_delivery_attempt
  FROM ops.job_attempts AS attempt
  WHERE attempt.job_id=v_delivery.id AND attempt.attempt=1;
  SELECT attempt.* INTO STRICT v_replay_delivery_attempt
  FROM ops.job_attempts AS attempt
  WHERE attempt.job_id=v_delivery.id AND attempt.attempt=2;

  v_expected_completion:=jsonb_build_object(
    'schemaVersion',
      'privacy-response-party-name-correction-completion.v1',
    'status','COMPLETED','jobId',v_job.id,
    'privacyRequestId',v_receipt.privacy_request_id,
    'correctionPlanId',v_receipt.correction_plan_id,
    'responseId',v_receipt.response_id,
    'responseVersion',v_receipt.response_version,
    'partyNameDigest',btrim(v_receipt.party_name_digest),
    'completionReceiptId',v_receipt.completion_receipt_id,
    'completionReceiptDigest',btrim(v_receipt.receipt_digest),
    'auditEventId',v_receipt.audit_event_id,
    'outboxEventIds',jsonb_build_array(v_receipt.outbox_event_id),
    'completedAt',v_receipt.completed_at,'replayed',true
  );
  v_expected_first_completion:=jsonb_set(
    v_expected_completion,'{replayed}','false'::jsonb
  );
  v_expected_delegation:=jsonb_build_object(
    'schemaVersion',
      'privacy-response-party-name-correction-delegation.v1',
    'eventId',v_approval_event.id,
    'privacyRequestId',v_receipt.privacy_request_id,
    'decisionVersion',v_binding.request_decision_version,
    'transitionReceiptDigest',btrim(v_binding.transition_receipt_digest),
    'jobId',v_job.id,
    'jobPayloadDigest',btrim(v_binding.job_payload_digest),
    'delegated',true
  );

  IF v_job.status<>'SUCCEEDED' OR v_job.attempt_count<>2
     OR v_job.last_error_code IS NOT NULL
     OR v_job.last_error_detail IS NOT NULL
     OR (SELECT count(*) FROM ops.job_attempts WHERE job_id=v_job.id)<>2
     OR v_first_attempt.outcome<>'SUCCEEDED'
     OR v_first_attempt.metrics IS DISTINCT FROM v_expected_first_completion
     OR v_replay_attempt.outcome<>'SUCCEEDED'
     OR v_replay_attempt.error_code IS NOT NULL
     OR v_replay_attempt.error_detail IS NOT NULL
     OR jsonb_typeof(v_replay_attempt.metrics)<>'object'
     OR (SELECT count(*)
         FROM jsonb_object_keys(v_replay_attempt.metrics))<>14
     OR v_replay_attempt.metrics IS DISTINCT FROM v_expected_completion
     OR v_delivery.status<>'SUCCEEDED' OR v_delivery.attempt_count<>2
     OR v_delivery.last_error_code IS NOT NULL
     OR v_delivery.last_error_detail IS NOT NULL
     OR (SELECT count(*) FROM ops.job_attempts
         WHERE job_id=v_delivery.id)<>2
     OR v_first_delivery_attempt.outcome<>'SUCCEEDED'
     OR v_first_delivery_attempt.metrics IS DISTINCT FROM v_expected_delegation
     OR v_replay_delivery_attempt.outcome<>'SUCCEEDED'
     OR v_replay_delivery_attempt.error_code IS NOT NULL
     OR v_replay_delivery_attempt.error_detail IS NOT NULL
     OR jsonb_typeof(v_replay_delivery_attempt.metrics)<>'object'
     OR (SELECT count(*)
         FROM jsonb_object_keys(v_replay_delivery_attempt.metrics))<>8
     OR v_replay_delivery_attempt.metrics IS DISTINCT FROM v_expected_delegation
     OR NOT EXISTS(
       SELECT 1 FROM ops.inbox
       WHERE consumer='retention-worker' AND event_id=v_approval_event.id
         AND processed_at IS NOT NULL AND result='SUCCEEDED'
     ) OR (SELECT count(*)
           FROM ops.privacy_response_party_name_correction_completion_receipts_v1
           WHERE privacy_request_id=v_receipt.privacy_request_id)<>1
     OR v_response.party_name<>v_party_name
     OR v_response.version<>v_receipt.response_version
     OR encode(extensions.digest(
          convert_to(v_response.party_name,'UTF8'),'sha256'
        ),'hex')<>v_receipt.party_name_digest
     OR v_request.state<>'COMPLETED'
     OR v_request.decision_version<>v_receipt.completion_decision_version
     OR (SELECT count(*) FROM ops.audit_events
         WHERE id=v_receipt.audit_event_id
           AND action='privacy.response_party_name.correction.complete'
           AND object_id=v_receipt.response_id::text)<>1
     OR (SELECT count(*) FROM ops.audit_events
         WHERE action='privacy.response_party_name.correction.complete'
           AND object_id=v_receipt.response_id::text)<>1
     OR (SELECT count(*) FROM ops.outbox
         WHERE id=v_receipt.outbox_event_id
           AND event_type='privacy.response_party_name_corrected.v1'
           AND aggregate_id=v_receipt.response_id::text)<>1
     OR (SELECT count(*) FROM ops.outbox
         WHERE event_type='privacy.response_party_name_corrected.v1'
           AND aggregate_id=v_receipt.response_id::text)<>1
     OR v_event.payload->>'completionReceiptDigest'<>
        btrim(v_receipt.receipt_digest)
     OR v_receipt.job_payload_digest<>v_binding.job_payload_digest THEN
    RAISE EXCEPTION 'Q4 exact replay changed a completion effect';
  END IF;

  IF EXISTS(
       SELECT 1
       FROM unnest(ARRAY[
         v_job.payload::text,
         v_replay_attempt.metrics::text,
         v_replay_delivery_attempt.metrics::text,
         v_job.last_error_code,v_job.last_error_detail,
         v_replay_attempt.error_code,v_replay_attempt.error_detail,
         v_delivery.last_error_code,v_delivery.last_error_detail,
         v_replay_delivery_attempt.error_code,
         v_replay_delivery_attempt.error_detail
       ]) AS redacted(value)
       WHERE strpos(COALESCE(value,''),v_party_name)>0
     ) THEN
    RAISE EXCEPTION 'Q4 exact replay leaked corrected plaintext';
  END IF;
END
$q4_exact_replay$;
SQL

smtp_port="$(free_port)"
: >"$work/smtp.jsonl"
FAKE_SMTP_PORT="$smtp_port" FAKE_SMTP_OUTPUT="$work/smtp.jsonl" \
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-support/fake-smtp-gateway.py &
smtp_pid=$!
sleep 0.2
NOTIFICATION_DATABASE_URL="postgresql://gurine_notification_worker:notification_test@127.0.0.1:${postgres_port}/${database}" \
FIELD_ENCRYPTION_KEY_CURRENT="$test_key" TOKEN_HMAC_KEY="$test_key" \
EGRESS_SMTP_CHANNEL_URL="http://127.0.0.1:${smtp_port}/smtp" \
EMAIL_FROM="gurine@example.test" EMAIL_REPLY_TO="ops@example.test" \
PUBLIC_BASE_URL="https://public.example.test" RESPONSE_BASE_URL="https://response.example.test" \
EMAIL_ADAPTER=smtp NOTIFICATION_ONCE=true HOSTNAME="notification-event-test" target/debug/gurine-notification-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.inbox WHERE consumer='workflow-worker' AND processed_at IS NOT NULL;
  IF actual <> 7 THEN RAISE EXCEPTION 'workflow inbox %, expected 7',actual; END IF;
  SELECT count(*) INTO actual
  FROM ops.inbox AS inbox
  JOIN ops.outbox AS event ON event.id=inbox.event_id
  WHERE inbox.consumer='response-submission-materializer'
    AND event.event_type='workflow.response_submitted.v2'
    AND inbox.processed_at IS NOT NULL;
  IF actual <> 1 THEN RAISE EXCEPTION 'response materializer inbox %, expected 1',actual; END IF;
  SELECT count(*) INTO actual FROM ops.inbox WHERE consumer='notification-worker' AND processed_at IS NOT NULL;
  IF actual <> 14 THEN
    RAISE NOTICE 'privacy notification job diagnostics: %',(
      SELECT jsonb_agg(jsonb_build_object(
        'eventType',event.event_type,
        'jobStatus',job.status,
        'errorCode',job.last_error_code,
        'attemptCount',job.attempt_count,
        'inboxProcessed',inbox.processed_at IS NOT NULL,
        'bindingAvailable',
          ops.read_privacy_request_notification_delivery_v1(event.id)
            IS NOT NULL
      ) ORDER BY event.occurred_at,event.id)
      FROM ops.inbox AS inbox
      JOIN ops.outbox AS event ON event.id=inbox.event_id
      JOIN ops.jobs AS job
        ON inbox.result='DISPATCHED:'||job.id::text
          OR job.payload->>'eventId'=event.id::text
      WHERE inbox.consumer='notification-worker'
        AND event.event_type IN (
          'privacy.request_created.v2',
          'privacy.request_identity_verified.v1'
        )
    );
    RAISE EXCEPTION 'notification inbox %, expected 14',actual;
  END IF;
  IF (SELECT status FROM ops.audit_exports WHERE id='31000000-0000-4000-8000-000000000082') <> 'READY' THEN
    RAISE EXCEPTION 'audit export not ready'; END IF;
  IF (SELECT status FROM intake.dataset_export_requests WHERE id='31000000-0000-4000-8000-000000000090') <> 'READY' THEN
    RAISE EXCEPTION 'dataset export not ready'; END IF;
  IF (SELECT enabled FROM ops.source_registry WHERE source_id='event-source') THEN
    RAISE EXCEPTION 'schema drift did not pause source'; END IF;
  IF NOT EXISTS(
    SELECT 1
    FROM intake.response_submissions AS submission
    JOIN editorial.responses AS response
      ON response.id=submission.editorial_response_id
     AND response.response_request_id=submission.response_request_id
     AND response.submission_id=submission.id
     AND response.submission_receipt_version=submission.receipt_version
     AND response.submission_receipt_digest=submission.receipt_digest
     AND response.owned_intake_event_id=submission.owned_intake_event_id
     AND response.owned_intake_event_envelope_digest=
       submission.owned_intake_event_envelope_digest
     AND response.owned_intake_receipt_digest=
       submission.owned_intake_receipt_digest
    JOIN editorial.response_submission_origin_receipts_v2 AS origin
      ON origin.response_submission_id=submission.id
     AND origin.response_request_id=submission.response_request_id
     AND origin.editorial_response_id=response.id
     AND origin.submission_receipt_version=submission.receipt_version
     AND origin.submission_receipt_digest=submission.receipt_digest
     AND origin.source_event_id=submission.owned_intake_event_id
     AND origin.source_event_envelope_digest=
       submission.owned_intake_event_envelope_digest
     AND origin.owned_intake_receipt_digest=
       submission.owned_intake_receipt_digest
    JOIN intake.response_submission_receipts_v3 AS receipt
      ON receipt.response_submission_id=submission.id
     AND receipt.response_request_id=submission.response_request_id
     AND receipt.receipt_version=submission.receipt_version
     AND receipt.receipt_digest=submission.receipt_digest
     AND receipt.workflow_event_id=origin.source_event_id
     AND receipt.workflow_event_envelope_digest=
       origin.source_event_envelope_digest
    WHERE submission.id='31000000-0000-4000-8000-000000000011'
      AND num_nonnulls(
        submission.editorial_response_id,submission.owned_intake_event_id,
        submission.owned_intake_event_envelope_digest,
        submission.owned_intake_receipt_digest
      )=4
      AND num_nonnulls(
        response.submission_id,response.submission_receipt_version,
        response.submission_receipt_digest,response.owned_intake_event_id,
        response.owned_intake_event_envelope_digest,
        response.owned_intake_receipt_digest
      )=6
  ) THEN
    RAISE EXCEPTION 'response submission reciprocal materialization invalid';
  END IF;
  SELECT count(*) INTO actual FROM ops.tasks WHERE task_type IN ('AGENT_REVIEW','SIGNAL_TRIAGE','SCHEMA_DRIFT');
  IF actual <> 3 THEN RAISE EXCEPTION 'workflow tasks %, expected 3',actual; END IF;
  IF (SELECT scan_status FROM intake.response_attachments WHERE id='31000000-0000-4000-8000-000000000012') <> 'CLEAN'
     OR (SELECT scan_status FROM intake.correction_draft_attachments WHERE id='31000000-0000-4000-8000-000000000031') <> 'CLEAN' THEN
    RAISE EXCEPTION 'attachment scans did not complete'; END IF;
  SELECT count(*) INTO actual FROM ops.outbox
   WHERE event_type='attachment.scan_completed.v1'
     AND aggregate_id IN (
       '31000000-0000-4000-8000-000000000012',
       '31000000-0000-4000-8000-000000000031'
     );
  IF actual <> 2
     OR NOT EXISTS (
       SELECT 1 FROM ops.outbox
       WHERE event_type='attachment.scan_completed.v1'
         AND aggregate_id='31000000-0000-4000-8000-000000000012'
         AND payload->>'attachment_id'=aggregate_id
         AND payload->>'attachment_kind'='RESPONSE'
         AND payload->>'scan_status'='CLEAN'
     )
     OR NOT EXISTS (
       SELECT 1 FROM ops.outbox
       WHERE event_type='attachment.scan_completed.v1'
         AND aggregate_id='31000000-0000-4000-8000-000000000031'
         AND payload->>'attachment_id'=aggregate_id
         AND payload->>'attachment_kind'='CORRECTION'
         AND payload->>'scan_status'='CLEAN'
     ) THEN
    RAISE EXCEPTION
      'attachment scan-completed outbox kind binding invalid: count %',actual;
  END IF;
  SELECT count(*) INTO actual FROM ops.email_deliveries WHERE status='DELIVERED';
  IF actual <> 13 THEN RAISE EXCEPTION 'delivered emails %, expected 13',actual; END IF;
  SELECT count(*) INTO actual FROM intake.response_access_tokens WHERE response_request_id='31000000-0000-4000-8000-000000000010';
  IF actual <> 1 THEN RAISE EXCEPTION 'response access tokens %, expected 1',actual; END IF;
END $$;
SQL

test "$(find "$work/objects/exports" -type f | wc -l)" -eq 2
parquet_file="$(find "$work/objects/exports/datasets" -type f -name '*.parquet' -print -quit)"
test -n "$parquet_file"
test "$(head -c 4 "$parquet_file")" = "PAR1"
test "$(tail -c 4 "$parquet_file")" = "PAR1"
test "$(wc -l <"$work/smtp.jsonl")" -eq 13
SMTP_CAPTURE="$work/smtp.jsonl" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import json
import os

with open(os.environ["SMTP_CAPTURE"], encoding="utf-8") as stream:
    messages = [json.loads(line) for line in stream]
contact = next(message for message in messages if message["subject"] == "구린네 새 문의 접수")
expected_subject = "<strong>Event & contact</strong>"
assert contact["text_body"].endswith(f"제목: {expected_subject}"), contact["text_body"]
assert contact["html_body"] == (
    "<p>새 문의가 접수되었습니다.</p>"
    "<p>ID: 31000000-0000-4000-8000-000000000040</p>"
    "<p>제목: &lt;strong&gt;Event &amp; contact&lt;/strong&gt;</p>"
), contact["html_body"]
assert expected_subject not in contact["html_body"], contact["html_body"]

subscription = next(message for message in messages if message["subject"] == "구린네 구독 확인")
assert "https://public.example.test/subscribe?token=" in subscription["text_body"], subscription["text_body"]
assert "https://public.example.test/subscribe?token=" in subscription["html_body"], subscription["html_body"]
assert "/subscription/verify" not in subscription["text_body"], subscription["text_body"]
assert "/subscription/verify" not in subscription["html_body"], subscription["html_body"]

response_request = next(message for message in messages if message["subject"] == "구린네 소명 요청")
assert "https://response.example.test/respond/access?token=" in response_request["text_body"], response_request["text_body"]
assert "https://response.example.test/respond/access?token=" in response_request["html_body"], response_request["html_body"]
assert "https://response.example.test/respond?token=" not in response_request["text_body"], response_request["text_body"]
assert "https://response.example.test/respond?token=" not in response_request["html_body"], response_request["html_body"]
PY

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
INSERT INTO raw.source_documents(
  id,source_id,external_id,retrieved_at,content_type,content_sha256,
  content_size_bytes,object_key,status,parser_name,parser_version,updated_at,
  asset_id,asset_revision
) VALUES (
  '31300000-0000-4000-8000-000000000001','event-source',
  'r6b2-pipeline-contracts','2026-07-31T20:00:00Z','application/json',
  repeat('1',64),512,'raw/r6b2-pipeline-contracts.json','PARSED','json',
  'r6b2-v1','2026-07-31T20:00:00.000001Z',
  '31300000-0000-4000-8000-000000000001',1
);

-- D5: exercise the owner completion boundary with a real parser/record/run and
-- a worker-shaped claimed job.  Exact replay must be identity-stable; changing
-- one terminal fact must fail with the optimistic-concurrency SQLSTATE.
DO $$
DECLARE
  v_source_document_id constant uuid :=
    '31300000-0000-4000-8000-000000000001';
  v_job_id constant uuid := '31300000-0000-4000-8000-000000000901';
  v_lease_token constant uuid := '31300000-0000-4000-8000-000000000902';
  v_parser_run_id constant uuid :=
    '31300000-0000-4000-8000-000000000903';
  v_parsed_record_id constant uuid :=
    '31300000-0000-4000-8000-000000000904';
  v_future_fact_record_id constant uuid :=
    '31300000-0000-4000-8000-000000000907';
  v_normalization_run_id constant uuid :=
    '31300000-0000-4000-8000-000000000905';
  v_output_object_id constant uuid :=
    '31300000-0000-4000-8000-000000000906';
  v_first record;
  v_replay record;
  v_stale_fence_denied boolean := false;
  v_changed_replay_denied boolean := false;
BEGIN
  INSERT INTO ops.jobs(id,job_type,queue,status,payload)
  VALUES (
    v_job_id,'NORMALIZATION_RUN','ingest-worker','QUEUED','{}'::jsonb
  );
  UPDATE ops.jobs
  SET status='RUNNING',lease_owner='r6b2-normalization-smoke',
      lease_token=v_lease_token,
      lease_expires_at=clock_timestamp()+interval '5 minutes',
      fencing_token=fencing_token+1,attempt_count=attempt_count+1,
      version=version+1
  WHERE id=v_job_id AND status='QUEUED';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'normalization smoke claim lost';
  END IF;
  INSERT INTO ops.job_attempts(
    job_id,attempt,worker_id,fencing_token,started_at
  ) VALUES (
    v_job_id,1,'r6b2-normalization-smoke',1,clock_timestamp()
  );
  INSERT INTO core.parser_runs(
    id,source_document_id,parser_name,parser_version,status,
    output_record_count,output_digest,input_content_sha256,
    extraction_schema_version,implementation_sha256,
    extraction_receipt_sha256,started_at,completed_at
  ) VALUES (
    v_parser_run_id,v_source_document_id,'connector-structured-json',
    'connector-structured-json-v1','SUCCEEDED',2,repeat('2',64),
    repeat('1',64),'extraction-result.v1',repeat('3',64),repeat('4',64),
    clock_timestamp()-interval '1 second',clock_timestamp()
  );
  INSERT INTO raw.parsed_records(
    id,source_document_id,record_type,record_index,parser_version,payload,
    payload_sha256,parser_run_id
  ) VALUES (
    v_parsed_record_id,v_source_document_id,'CONTRACT',0,
    'connector-structured-json-v1',
    '{"contractNumber":"R6B2-NORMALIZATION"}'::jsonb,
    repeat('5',64),v_parser_run_id
  ),(
    v_future_fact_record_id,v_source_document_id,'SUPPLIER',1,
    'connector-structured-json-v1',
    '{"supplierName":"R6B2-FUTURE-FACT"}'::jsonb,
    repeat('a',64),v_parser_run_id
  );
  INSERT INTO core.normalization_runs(
    id,source_document_id,parser_run_id,parsed_record_id,parser_version,
    input_payload_sha256,normalization_id,normalization_version,
    normalization_contract_sha256,implementation_sha256,
    producer_generation,job_id,job_fencing_token
  ) VALUES (
    v_normalization_run_id,v_source_document_id,v_parser_run_id,
    v_parsed_record_id,'connector-structured-json-v1',repeat('5',64),
    'contract-normalizer','contract-normalizer-v1',repeat('6',64),
    repeat('7',64),1,v_job_id,1
  );

  BEGIN
    PERFORM core.complete_normalization_run(
      v_normalization_run_id,1,v_job_id,v_lease_token,2,'SUCCEEDED',
      'CONTRACT',v_output_object_id,1,repeat('8',64),1,repeat('9',64),
      NULL,NULL
    );
  EXCEPTION WHEN SQLSTATE '40001' THEN
    v_stale_fence_denied := true;
  END;
  IF NOT v_stale_fence_denied
     OR NOT EXISTS (
       SELECT 1 FROM core.normalization_runs AS normalization
       WHERE normalization.id=v_normalization_run_id
         AND normalization.state='RUNNING'
         AND normalization.version=1
         AND normalization.terminal_receipt_sha256 IS NULL
         AND normalization.terminal_audit_event_id IS NULL
     )
     OR EXISTS (
       SELECT 1 FROM ops.audit_events AS audit
       WHERE audit.object_type='NormalizationRun'
         AND audit.object_id=v_normalization_run_id::text
         AND audit.action IN (
           'NORMALIZATION_RUN_SUCCEEDED','NORMALIZATION_RUN_FAILED'
         )
     )
     OR EXISTS (
       SELECT 1 FROM ops.outbox AS event
       WHERE event.aggregate_type='NormalizationRun'
         AND event.aggregate_id=v_normalization_run_id::text
         AND event.event_type='normalization.run_completed.v1'
     ) THEN
    RAISE EXCEPTION
      'normalization stale fence did not fail closed: run %, denied %',
      v_normalization_run_id,v_stale_fence_denied;
  END IF;

  SELECT * INTO v_first FROM core.complete_normalization_run(
    v_normalization_run_id,1,v_job_id,v_lease_token,1,'SUCCEEDED',
    'CONTRACT',v_output_object_id,1,repeat('8',64),1,repeat('9',64),
    NULL,NULL
  );
  IF v_first.normalization_run_id <> v_normalization_run_id
     OR v_first.state <> 'SUCCEEDED'
     OR v_first.version <> 2
     OR v_first.replayed
     OR v_first.terminal_receipt_sha256 IS NULL
     OR v_first.audit_event_id IS NULL
     OR v_first.outbox_event_id IS NULL THEN
    RAISE EXCEPTION
      'normalization terminal return invalid: run %, state %, version %, replayed %, receipt %, audit %, outbox %',
      v_first.normalization_run_id,v_first.state,v_first.version,
      v_first.replayed,btrim(v_first.terminal_receipt_sha256),
      v_first.audit_event_id,v_first.outbox_event_id;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM core.normalization_runs AS normalization
    JOIN ops.audit_events AS audit
      ON audit.id=normalization.terminal_audit_event_id
    JOIN ops.outbox AS event ON event.id=v_first.outbox_event_id
    WHERE normalization.id=v_normalization_run_id
      AND normalization.state='SUCCEEDED'
      AND normalization.version=2
      AND normalization.terminal_receipt_sha256
        =v_first.terminal_receipt_sha256
      AND normalization.terminal_audit_event_id=v_first.audit_event_id
      AND audit.actor_type='SERVICE'
      AND audit.actor_id='ingest-worker'
      AND audit.action='NORMALIZATION_RUN_SUCCEEDED'
      AND audit.object_type='NormalizationRun'
      AND audit.object_id=v_normalization_run_id::text
      AND audit.capability='jobs.operate'
      AND audit.request_id=v_job_id
      AND event.aggregate_type='NormalizationRun'
      AND event.aggregate_id=v_normalization_run_id::text
      AND event.aggregate_version=2
      AND event.event_type='normalization.run_completed.v1'
      AND event.payload->>'terminalReceiptSha256'
        =btrim(v_first.terminal_receipt_sha256)
      AND event.payload->>'auditEventId'=v_first.audit_event_id::text
  ) THEN
    RAISE EXCEPTION 'normalization terminal evidence invalid';
  END IF;

  SELECT * INTO v_replay FROM core.complete_normalization_run(
    v_normalization_run_id,1,v_job_id,v_lease_token,1,'SUCCEEDED',
    'CONTRACT',v_output_object_id,1,repeat('8',64),1,repeat('9',64),
    NULL,NULL
  );
  IF NOT v_replay.replayed OR ROW(
       v_replay.normalization_run_id,v_replay.state,v_replay.version,
       v_replay.terminal_receipt_sha256,v_replay.audit_event_id,
       v_replay.outbox_event_id
     ) IS DISTINCT FROM ROW(
       v_first.normalization_run_id,v_first.state,v_first.version,
       v_first.terminal_receipt_sha256,v_first.audit_event_id,
       v_first.outbox_event_id
     ) THEN
    RAISE EXCEPTION
      'normalization exact replay invalid: run %, first state/version/replayed %/%/%, replay state/version/replayed %/%/%',
      v_normalization_run_id,v_first.state,v_first.version,v_first.replayed,
      v_replay.state,v_replay.version,v_replay.replayed;
  END IF;

  BEGIN
    PERFORM core.complete_normalization_run(
      v_normalization_run_id,1,v_job_id,v_lease_token,1,'SUCCEEDED',
      'CONTRACT',v_output_object_id,1,repeat('8',64),2,repeat('9',64),
      NULL,NULL
    );
  EXCEPTION WHEN SQLSTATE '40001' THEN
    v_changed_replay_denied := true;
  END;
  IF NOT v_changed_replay_denied
     OR (SELECT count(*) FROM ops.audit_events AS audit
         WHERE audit.object_type='NormalizationRun'
           AND audit.object_id=v_normalization_run_id::text
           AND audit.action='NORMALIZATION_RUN_SUCCEEDED') <> 1
     OR (SELECT count(*) FROM ops.outbox AS event
         WHERE event.aggregate_type='NormalizationRun'
           AND event.aggregate_id=v_normalization_run_id::text
           AND event.event_type='normalization.run_completed.v1') <> 1
     OR NOT EXISTS (
       SELECT 1 FROM core.normalization_runs AS normalization
       WHERE normalization.id=v_normalization_run_id
         AND normalization.state='SUCCEEDED'
         AND normalization.version=2
         AND normalization.field_provenance_count=1
         AND normalization.terminal_receipt_sha256
           =v_first.terminal_receipt_sha256
     ) THEN
    RAISE EXCEPTION
      'normalization changed replay did not fail closed: run %, denied %',
      v_normalization_run_id,v_changed_replay_denied;
  END IF;
END $$;

INSERT INTO raw.asset_rights_decisions(
  id,asset_id,asset_sha256,asset_revision,decision_version,asset_kind,
  source_document_id,decision_kind,access_right,private_storage_right,
  model_egress_right,model_use_right,derivative_creation_right,excerpt_right,
  redistribution_right,commercial_use_right,public_display_right,
  dimensions_sha256,legal_basis_code,legal_basis_reference,legal_basis_sha256,
  license_evidence_digests,license_evidence_set_sha256,jurisdiction,
  attribution_required,attribution_sha256,policy_version,policy_sha256,
  approval_sha256,execution_sha256,evidence_receipt_id,
  evidence_receipt_sha256,reviewer_user_id,effective_at,decision_sha256
) VALUES (
  '31300000-0000-4000-8000-000000000002',
  '31300000-0000-4000-8000-000000000001',repeat('1',64),1,1,
  'SOURCE_DOCUMENT','31300000-0000-4000-8000-000000000001','GRANT',
  'ALLOW','ALLOW','ALLOW','ALLOW','ALLOW','ALLOW','ALLOW','ALLOW','ALLOW',
  repeat('2',64),'RUNTIME','R6b2 pipeline smoke',repeat('3',64),
  ARRAY[repeat('4',64)]::text[],repeat('5',64),'KR',false,repeat('6',64),
  'r6b2-runtime-v1',repeat('7',64),repeat('8',64),repeat('9',64),
  '31300000-0000-4000-8000-000000000003',repeat('a',64),
  '31000000-0000-4000-8000-000000000001','2026-07-31T20:00:00Z',
  repeat('b',64)
);
INSERT INTO core.agencies(
  id,canonical_name,agency_type,jurisdiction,identity_status
) VALUES (
  '31300000-0000-4000-8000-000000000010','R6b2 runtime agency',
  'CENTRAL','KR','VERIFIED'
);
INSERT INTO core.suppliers(
  id,canonical_name,business_status,identity_status
) VALUES (
  '31300000-0000-4000-8000-000000000011','R6b2 runtime supplier',
  'ACTIVE','UNVERIFIED'
);
DO $$
DECLARE
  candidate_id constant uuid := '31300000-0000-4000-8000-000000000911';
  identifier_id constant uuid := '31300000-0000-4000-8000-000000000912';
  supplier_id constant uuid := '31300000-0000-4000-8000-000000000011';
  source_id constant uuid := '31300000-0000-4000-8000-000000000001';
  parsed_record_id constant uuid :=
    '31300000-0000-4000-8000-000000000904';
  value_hash char(64) := repeat('b',64);
  source_locator_digest char(64);
  verification_evidence_digest char(64);
  identifier_fact_digest char(64);
  candidate_payload jsonb;
  candidate_canonical bytea;
  candidate_digest char(64);
BEGIN
  source_locator_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'sourceDocumentId',source_id,'parsedRecordId',parsed_record_id,
      'recordIndex',0,'field','businessNumber'
    )),'sha256'
  ),'hex');
  verification_evidence_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'kind','SOURCE_VERIFIED','sourceDocumentId',source_id,
      'sourceContentSha256',repeat('1',64)
    )),'sha256'
  ),'hex');
  candidate_payload := jsonb_build_object(
    'schemaVersion','supplier-identity-candidate.v1',
    'candidateId',candidate_id,'candidateRevision',1,
    'sourceDocumentId',source_id,'parsedRecordId',parsed_record_id,
    'recordIndex',0,'mappingVersion','connector-structured-json-v1',
    'normalizedName','r6b2 runtime supplier',
    'identifierCount',1,'identityStatus','CANDIDATE'
  );
  candidate_canonical := ops.canonical_jsonb_v1(candidate_payload);
  candidate_digest := encode(extensions.digest(
    candidate_canonical,'sha256'
  ),'hex');
  INSERT INTO core.supplier_identity_candidates(
    candidate_id,candidate_revision,candidate_digest,
    source_document_id,source_asset_id,source_asset_revision,
    source_content_sha256,parsed_record_id,source_record_digest,record_index,
    mapping_version,normalized_name,name_source_locator_digest,
    identifier_count,identifier_set_digest,identity_status,
    candidate_payload,candidate_canonical,candidate_digest_preimage_canonical
  ) VALUES (
    candidate_id,1,candidate_digest,source_id,source_id,1,repeat('1',64),
    parsed_record_id,repeat('5',64),0,'connector-structured-json-v1',
    'r6b2 runtime supplier',source_locator_digest,1,
    encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_array(value_hash)),'sha256'
    ),'hex'),'CANDIDATE',candidate_payload,candidate_canonical,
    candidate_canonical
  );
  identifier_fact_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','supplier-identifier-fact.v1',
      'supplierId',supplier_id,'scheme','KOREAN_BUSINESS_NUMBER',
      'valueHash',btrim(value_hash),'candidateId',candidate_id,
      'candidateRevision',1,'candidateDigest',btrim(candidate_digest),
      'sourceLocatorDigest',btrim(source_locator_digest),
      'verificationEvidenceDigest',btrim(verification_evidence_digest),
      'verificationStatus','VERIFIED','proofState','PROVEN_V1'
    )),'sha256'
  ),'hex');
  INSERT INTO core.supplier_identifiers(
    id,supplier_id,scheme,value_hash,source_document_id,
    verification_status,candidate_id,candidate_revision,candidate_digest,
    source_locator_digest,verification_evidence_digest,
    identifier_fact_digest,proof_state
  ) VALUES (
    identifier_id,supplier_id,'KOREAN_BUSINESS_NUMBER',value_hash,source_id,
    'VERIFIED',candidate_id,1,candidate_digest,source_locator_digest,
    verification_evidence_digest,identifier_fact_digest,'PROVEN_V1'
  );
  INSERT INTO core.supplier_identifiers(
    id,supplier_id,scheme,value_hash,source_document_id,
    verification_status,proof_state
  ) VALUES (
    '31300000-0000-4000-8000-000000000910',supplier_id,
    'BUSINESS_NUMBER',repeat('9',64),source_id,'VERIFIED','LEGACY_UNPROVEN'
  );
END $$;

-- D7: even a legacy row whose old verification flag says VERIFIED is not a
-- strong fact and cannot cross the public read boundary.  The public API role
-- cannot read the core identifier relation, and public projections expose
-- neither the fact digest nor the proof-state discriminator.
DO $$
BEGIN
  IF NOT EXISTS (
       SELECT 1 FROM core.supplier_identifiers AS identifier
       WHERE identifier.id='31300000-0000-4000-8000-000000000910'
         AND identifier.verification_status='VERIFIED'
         AND identifier.proof_state='LEGACY_UNPROVEN'
     )
     OR has_table_privilege(
       'gurine_public_api','core.supplier_identifiers','SELECT'
     )
     OR EXISTS (
       SELECT 1 FROM information_schema.columns AS column_contract
       WHERE column_contract.table_schema='public'
         AND column_contract.column_name IN (
           'identifier_fact_digest','proof_state'
         )
     )
     OR EXISTS (
       SELECT 1 FROM pg_views AS view_contract
       WHERE view_contract.schemaname='public'
         AND view_contract.definition ~
           'supplier_identifiers|identifier_fact_digest|proof_state'
     ) THEN
    RAISE EXCEPTION 'legacy supplier identifier public boundary invalid';
  END IF;
END $$;

BEGIN;
SET LOCAL ROLE gurine_public_api;
DO $$
DECLARE v_denied boolean := false;
BEGIN
  BEGIN
    PERFORM identifier.id
    FROM core.supplier_identifiers AS identifier
    WHERE identifier.id='31300000-0000-4000-8000-000000000910';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'legacy supplier identifier core read was not denied';
  END IF;
END $$;
ROLLBACK;

-- D3: an authoritative structured parse plus an exact VERIFIED/PROVEN_V1
-- identifier may create only an immutable PENDING_HUMAN proposal.  The role
-- call, exact replay, and all forbidden merge surfaces are proved in a rollback
-- so this mechanics-only fixture cannot change the later detection cardinality.
BEGIN;
INSERT INTO core.parser_runs(
  id,source_document_id,parser_name,parser_version,status,
  output_record_count,output_digest,input_content_sha256,
  extraction_schema_version,implementation_sha256,
  extraction_receipt_sha256,started_at,completed_at
) VALUES (
  '31300000-0000-4000-8000-000000000915',
  '31300000-0000-4000-8000-000000000001',
  'connector-structured-json','connector-structured-json-v1','SUCCEEDED',
  1,repeat('d',64),repeat('1',64),'extraction-result.v1',repeat('3',64),
  repeat('4',64),clock_timestamp()-interval '1 second',clock_timestamp()
);
INSERT INTO raw.parsed_records(
  id,source_document_id,record_type,record_index,parser_version,payload,
  payload_sha256,parser_run_id
) VALUES (
  '31300000-0000-4000-8000-000000000916',
  '31300000-0000-4000-8000-000000000001','SUPPLIER',0,
  'connector-structured-json-v1',
  '{"supplierName":"R6b2 human-review proposal"}'::jsonb,repeat('e',64),
  '31300000-0000-4000-8000-000000000915'
);
CREATE TEMP TABLE r6b_d3_request(request jsonb NOT NULL);
INSERT INTO r6b_d3_request(request)
SELECT jsonb_build_object(
  'schemaVersion','supplier-identity-candidate-proposal.request.v1',
  'sourceDocumentId','31300000-0000-4000-8000-000000000001',
  'parsedRecordId','31300000-0000-4000-8000-000000000916',
  'recordIndex',0,
  'normalizedName','r6b2 human-review proposal',
  'observedScheme','KOREAN_BUSINESS_NUMBER',
  'observedValueHmac',btrim(identifier.value_hash),
  'targetSupplierId',identifier.supplier_id,
  'identifierFactDigest',btrim(identifier.identifier_fact_digest),
  'scoreBasisPoints',10000
)
FROM core.supplier_identifiers AS identifier
WHERE identifier.id='31300000-0000-4000-8000-000000000912'
  AND identifier.verification_status='VERIFIED'
  AND identifier.proof_state='PROVEN_V1';
CREATE TEMP TABLE r6b_d3_counts_before AS
SELECT
  (SELECT count(*) FROM core.supplier_identity_candidates) AS candidates,
  (SELECT count(*) FROM core.supplier_identity_resolution_decisions)
    AS decisions,
  (SELECT count(*) FROM core.supplier_identity_resolution_decision_members)
    AS decision_members,
  (SELECT count(*) FROM core.supplier_identifiers) AS identifiers,
  (SELECT count(*) FROM core.suppliers) AS suppliers,
  (SELECT count(*) FROM core.contracts) AS contracts;
CREATE TEMP TABLE r6b_d3_results(
  call_order integer NOT NULL,
  candidate_id uuid,
  merge_decision_id uuid,
  disposition text,
  recorded boolean
);
GRANT SELECT ON r6b_d3_request TO gurine_ingest_worker;
GRANT INSERT, SELECT ON r6b_d3_results TO gurine_ingest_worker;
SET LOCAL ROLE gurine_ingest_worker;
INSERT INTO r6b_d3_results
SELECT 1,result.*
FROM core.record_supplier_identity_candidate_v1(
  (SELECT request FROM r6b_d3_request)
) AS result;
INSERT INTO r6b_d3_results
SELECT 2,result.*
FROM core.record_supplier_identity_candidate_v1(
  (SELECT request FROM r6b_d3_request)
) AS result;
RESET ROLE;
DO $$
DECLARE
  v_request jsonb;
  v_candidate_id uuid;
  v_before r6b_d3_counts_before%ROWTYPE;
BEGIN
  SELECT request INTO STRICT v_request FROM r6b_d3_request;
  SELECT candidate_id INTO STRICT v_candidate_id
  FROM r6b_d3_results ORDER BY call_order LIMIT 1;
  SELECT * INTO STRICT v_before FROM r6b_d3_counts_before;
  IF (SELECT count(*) FROM r6b_d3_results) <> 2
     OR (SELECT count(DISTINCT candidate_id) FROM r6b_d3_results) <> 1
     OR EXISTS (
       SELECT 1 FROM r6b_d3_results AS result
       WHERE result.candidate_id IS NULL
          OR result.merge_decision_id IS NOT NULL
          OR result.disposition IS DISTINCT FROM 'PENDING_HUMAN'
          OR result.recorded IS DISTINCT FROM true
     )
     OR NOT EXISTS (
       SELECT 1
       FROM core.supplier_identity_candidates AS candidate
       JOIN raw.parsed_records AS record
         ON record.id=candidate.parsed_record_id
       JOIN core.supplier_identifiers AS identifier
         ON identifier.id=candidate.matched_identifier_id
       WHERE candidate.candidate_id=v_candidate_id
         AND candidate.candidate_revision=1
         AND candidate.proposal_state='PENDING_HUMAN'
         AND candidate.identity_status='CANDIDATE'
         AND candidate.canonical_supplier_id IS NULL
         AND candidate.resolution_decision_id IS NULL
         AND candidate.resolution_decision_digest IS NULL
         AND candidate.source_document_id
           ='31300000-0000-4000-8000-000000000001'
         AND candidate.parsed_record_id
           ='31300000-0000-4000-8000-000000000916'
         AND candidate.record_index=0
         AND candidate.mapping_version=record.parser_version
         AND candidate.proposed_supplier_id=identifier.supplier_id
         AND candidate.matched_identifier_fact_digest
           =identifier.identifier_fact_digest
         AND candidate.match_score_basis_points=10000
         AND candidate.proposal_request_sha256=encode(
           extensions.digest(ops.canonical_jsonb_v1(v_request),'sha256'),
           'hex'
         )
         AND candidate.candidate_digest=encode(
           extensions.digest(candidate.candidate_canonical,'sha256'),'hex'
         )
         AND candidate.candidate_payload->>'proposalState'
           ='PENDING_HUMAN'
         AND candidate.candidate_payload->>'suggestedAt'=to_char(
           candidate.suggested_at AT TIME ZONE 'UTC',
           'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
         )
         AND identifier.id='31300000-0000-4000-8000-000000000912'
         AND identifier.verification_status='VERIFIED'
         AND identifier.proof_state='PROVEN_V1'
     )
     OR (SELECT count(*) FROM core.supplier_identity_candidates)
       <> v_before.candidates + 1
     OR (SELECT count(*) FROM core.supplier_identity_resolution_decisions)
       <> v_before.decisions
     OR (SELECT count(*)
         FROM core.supplier_identity_resolution_decision_members)
       <> v_before.decision_members
     OR (SELECT count(*) FROM core.supplier_identifiers)
       <> v_before.identifiers
     OR (SELECT count(*) FROM core.suppliers) <> v_before.suppliers
     OR (SELECT count(*) FROM core.contracts) <> v_before.contracts THEN
    RAISE EXCEPTION
      'supplier identity human-review proposal proof invalid: candidate %',
      v_candidate_id;
  END IF;
END $$;
ROLLBACK;
INSERT INTO core.contracts(
  id,source_id,external_contract_id,contract_number,title,agency_id,
  supplier_id,status,procurement_method,signed_at,currency,original_amount,
  current_amount,normalization_version,source_document_id,
  source_record_locator,version,created_at,updated_at
) VALUES (
  '31300000-0000-4000-8000-000000000012','event-source',
  'r6b2-amendment-contract','R6B2-001','R6b2 amended contract',
  '31300000-0000-4000-8000-000000000010',
  '31300000-0000-4000-8000-000000000011','ACTIVE','OPEN_COMPETITION',
  '2026-01-15','KRW',20000000,32000000,'r6b2-v1',
  '31300000-0000-4000-8000-000000000001','contracts[0]',3,
  '2026-07-31T20:00:00Z','2026-07-31T20:00:00.000003Z'
);
INSERT INTO core.contract_changes(
  id,contract_id,external_change_id,change_sequence,changed_at,
  previous_amount,new_amount,reason,source_document_id
) VALUES
  ('31300000-0000-4000-8000-000000000013',
   '31300000-0000-4000-8000-000000000012','r6b2-change-1',1,
   '2026-03-01',20000000,26000000,'사업 범위 확대',
   '31300000-0000-4000-8000-000000000001'),
  ('31300000-0000-4000-8000-000000000014',
   '31300000-0000-4000-8000-000000000012','r6b2-change-2',2,
   '2026-05-01',26000000,32000000,NULL,
   '31300000-0000-4000-8000-000000000001');
INSERT INTO core.rule_versions(
  id,rule_id,version,name,description,configuration,code_digest,status,
  created_by
) VALUES (
  '31300000-0000-4000-8000-000000000020',
  'CONTRACT_AMENDMENT_ESCALATION','1.0.0','R6b2 amendment escalation',
  'R6b2 pipeline runtime fixture',jsonb_build_object('severity','HIGH'),
  repeat('c',64),'ACTIVE','31000000-0000-4000-8000-000000000001'
);
INSERT INTO ops.provider_configs(
  id,provider_type,name,enabled,routing_policy,secret_reference,
  data_retention_policy
) VALUES (
  '31300000-0000-4000-8000-000000000021','r6b2-runtime-provider',
  'R6b2 Runtime Provider',true,
  '{"model":"runtime-model","dataPolicy":{"state":"CONFIGURED"}}',
  'env:R6B2_RUNTIME_TEST','LOCAL_ONLY'
);
SQL

run_r6b2_scheduler() {
  SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
  SCHEDULER_INSTANCE_ID="r6b2-pipeline-test" SCHEDULER_ONCE=true \
    target/debug/gurine-scheduler
}

run_r6b2_analysis() {
  GURINE_ENV=test AI_ENABLED=false \
  ANALYSIS_DATABASE_URL="postgresql://gurine_analysis_worker:analysis_test@127.0.0.1:${postgres_port}/${database}" \
  ANALYSIS_ONCE=true HOSTNAME="r6b2-analysis-test" \
    target/debug/gurine-analysis-worker
}

run_r6b2_workflow() {
  GURINE_ENV=development \
  WORKFLOW_DATABASE_URL="postgresql://gurine_workflow_worker:workflow_test@127.0.0.1:${postgres_port}/${database}" \
  FIELD_ENCRYPTION_KEY_CURRENT="$test_key" \
  OBJECT_STORE_ADAPTER=filesystem OBJECT_STORE_FILESYSTEM_ROOT="$work/objects" \
  CLAMAV_HOST=127.0.0.1 CLAMAV_PORT="$clamav_port" WORKFLOW_ONCE=true \
  HOSTNAME="r6b2-workflow-test" target/debug/gurine-workflow-worker
}

# A scheduler retry before the producer claims the build must be exactly
# idempotent: one logical rule/snapshot authority tuple yields one build job.
run_r6b2_scheduler
run_r6b2_scheduler

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  build_job ops.jobs%ROWTYPE;
  build_job_count bigint;
  expected_identity_sha256 text;
BEGIN
  SELECT count(*) INTO build_job_count
  FROM ops.jobs AS job
  WHERE job.job_type='DETECTION_SNAPSHOT_BUILD'
    AND job.payload->>'ruleVersionId'
      ='31300000-0000-4000-8000-000000000020';
  SELECT * INTO STRICT build_job
  FROM ops.jobs
  WHERE job_type='DETECTION_SNAPSHOT_BUILD'
    AND payload->>'ruleVersionId'='31300000-0000-4000-8000-000000000020';
  SELECT encode(
    extensions.digest(
      ops.canonical_jsonb_v1(jsonb_agg(
        jsonb_build_object(
          'id',contract.id,
          'version',contract.version,
          'updatedAt',to_char(
            contract.updated_at AT TIME ZONE 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
          )
        ) ORDER BY contract.id::text,contract.version,contract.updated_at
      )),
      'sha256'
    ),
    'hex'
  ) INTO STRICT expected_identity_sha256
  FROM core.contracts AS contract;
  IF build_job_count <> 1
     OR build_job.queue <> 'analysis-worker'
     OR build_job.status <> 'QUEUED'
     OR build_job.payload->>'schemaVersion'
       IS DISTINCT FROM 'detection-snapshot-build-job.v1'
     OR build_job.payload->>'ruleId'
       IS DISTINCT FROM 'CONTRACT_AMENDMENT_ESCALATION'
     OR (build_job.payload->>'contractCount')::bigint <> 1
     OR build_job.payload->>'contractIdentitySetSha256'
       IS DISTINCT FROM expected_identity_sha256 THEN
    RAISE EXCEPTION
      'R6b2 snapshot build job authority invalid: count %, job %, queue %, status %, identity digest %',
      build_job_count,build_job.id,build_job.queue,build_job.status,
      build_job.payload->>'contractIdentitySetSha256';
  END IF;
END $$;
SQL

# Exercise the D1 owner boundary once inside a rollback before the real worker
# claims it.  This preserves the queued job while surfacing an exact SQLSTATE
# if the producer's physical contract and the fixture diverge.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
BEGIN;
UPDATE ops.jobs AS job
SET status='RUNNING',lease_owner='r6b2-d1-owner-preflight',
    lease_token='31300000-0000-4000-8000-000000000917',
    lease_expires_at=clock_timestamp()+interval '5 minutes',
    fencing_token=job.fencing_token+1,
    attempt_count=job.attempt_count+1,version=job.version+1
WHERE job.job_type='DETECTION_SNAPSHOT_BUILD'
  AND job.payload->>'ruleVersionId'
    ='31300000-0000-4000-8000-000000000020'
  AND job.status='QUEUED';
INSERT INTO ops.job_attempts(
  job_id,attempt,worker_id,fencing_token,started_at
)
SELECT job.id,job.attempt_count,'r6b2-d1-owner-preflight',
       job.fencing_token,clock_timestamp()
FROM ops.jobs AS job
WHERE job.job_type='DETECTION_SNAPSHOT_BUILD'
  AND job.payload->>'ruleVersionId'
    ='31300000-0000-4000-8000-000000000020'
  AND job.status='RUNNING';
SET LOCAL ROLE gurine_analysis_worker;
DO $$
DECLARE
  v_job ops.jobs%ROWTYPE;
  v_result record;
BEGIN
  SELECT job.* INTO STRICT v_job
  FROM ops.jobs AS job
  WHERE job.job_type='DETECTION_SNAPSHOT_BUILD'
    AND job.payload->>'ruleVersionId'
      ='31300000-0000-4000-8000-000000000020'
    AND job.status='RUNNING';
  SELECT * INTO STRICT v_result
  FROM core.build_detection_dataset_snapshot_v1(
    v_job.id,v_job.lease_token,v_job.fencing_token
  );
  IF v_result.snapshot_id IS NULL
     OR v_result.snapshot_sha256 IS NULL
     OR v_result.member_count <> 1
     OR v_result.strong_identifier_fact_count <> 1
     OR v_result.strong_identifier_fact_set_sha256 IS NULL
     OR v_result.replayed THEN
    RAISE EXCEPTION
      'D1 owner preflight return invalid: snapshot %, members %, facts %, replayed %',
      v_result.snapshot_id,v_result.member_count,
      v_result.strong_identifier_fact_count,v_result.replayed;
  END IF;
END $$;
RESET ROLE;
ROLLBACK;
SQL

# Exercise fail-closed policy outcomes through the real scheduler transport and
# workflow-worker consumer, not only through the owner-procedure matrix above.
run_r6b2_no_start_delivery() {
  local signal_id="$1"
  local expected_disposition="$2"
  local expected_policy_id="$3"
  local expected_policy_version="$4"

  run_r6b2_scheduler
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 \
    -v signal_id="$signal_id" -U postgres -d "$database" <<'SQL' >/dev/null
SELECT set_config('r6b2.signal_id', :'signal_id', false);
DO $$
DECLARE
  v_signal_id uuid := current_setting('r6b2.signal_id')::uuid;
  delivery_job ops.jobs%ROWTYPE;
  inbox_row ops.inbox%ROWTYPE;
BEGIN
  SELECT job.* INTO STRICT delivery_job
  FROM ops.jobs AS job
  WHERE job.job_type='EVENT_DELIVERY'
    AND job.queue='workflow-worker'
    AND job.payload->'payload'->>'signal_id'=v_signal_id::text;
  SELECT inbox.* INTO STRICT inbox_row
  FROM ops.inbox AS inbox
  WHERE inbox.consumer='workflow-worker'
    AND inbox.event_id=(delivery_job.payload->>'eventId')::uuid;
  IF delivery_job.status <> 'QUEUED'
     OR inbox_row.processed_at IS NOT NULL
     OR inbox_row.result NOT LIKE 'DISPATCHED:%' THEN
    RAISE EXCEPTION
      'R6b2 negative event queue invalid: jobId %, status %, errorCode %, inboxResult %',
      delivery_job.id,delivery_job.status,delivery_job.last_error_code,
      inbox_row.result;
  END IF;
END $$;
SQL

  run_r6b2_workflow
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 \
    -v signal_id="$signal_id" \
    -v expected_disposition="$expected_disposition" \
    -v expected_policy_id="$expected_policy_id" \
    -v expected_policy_version="$expected_policy_version" \
    -U postgres -d "$database" <<'SQL' >/dev/null
SELECT set_config('r6b2.signal_id', :'signal_id', false);
SELECT set_config(
  'r6b2.expected_disposition', :'expected_disposition', false
);
SELECT set_config('r6b2.expected_policy_id', :'expected_policy_id', false);
SELECT set_config(
  'r6b2.expected_policy_version', :'expected_policy_version', false
);
DO $$
DECLARE
  v_signal_id uuid := current_setting('r6b2.signal_id')::uuid;
  expected_disposition text := current_setting('r6b2.expected_disposition');
  expected_policy_id uuid := current_setting('r6b2.expected_policy_id')::uuid;
  expected_policy_version bigint :=
    current_setting('r6b2.expected_policy_version')::bigint;
  delivery_job ops.jobs%ROWTYPE;
  inbox_row ops.inbox%ROWTYPE;
  attempt ops.job_attempts%ROWTYPE;
  initiation ops.signal_investigation_initiation_receipts%ROWTYPE;
BEGIN
  SELECT job.* INTO STRICT delivery_job
  FROM ops.jobs AS job
  WHERE job.job_type='EVENT_DELIVERY'
    AND job.queue='workflow-worker'
    AND job.payload->'payload'->>'signal_id'=v_signal_id::text;
  SELECT inbox.* INTO STRICT inbox_row
  FROM ops.inbox AS inbox
  WHERE inbox.consumer='workflow-worker'
    AND inbox.event_id=(delivery_job.payload->>'eventId')::uuid;
  SELECT job_attempt.* INTO STRICT attempt
  FROM ops.job_attempts AS job_attempt
  WHERE job_attempt.job_id=delivery_job.id;
  SELECT receipt.* INTO STRICT initiation
  FROM ops.signal_investigation_initiation_receipts AS receipt
  WHERE receipt.signal_id=v_signal_id;
  IF delivery_job.status <> 'SUCCEEDED'
     OR inbox_row.processed_at IS NULL OR inbox_row.result <> 'SUCCEEDED'
     OR attempt.outcome <> 'SUCCEEDED'
     OR attempt.metrics->>'signalId' IS DISTINCT FROM v_signal_id::text
     OR (attempt.metrics->>'taskCreated')::boolean IS DISTINCT FROM true
     OR attempt.metrics->'automaticInvestigation'->>'disposition'
       IS DISTINCT FROM expected_disposition
     OR attempt.metrics->'automaticInvestigation'->>'receiptId'
       IS DISTINCT FROM initiation.receipt_id::text
     OR attempt.metrics->'automaticInvestigation'->>'actorType'
       IS DISTINCT FROM 'SERVICE'
     OR attempt.metrics->'automaticInvestigation'->>'actorId'
       IS DISTINCT FROM 'workflow-worker'
     OR (attempt.metrics->'automaticInvestigation'->>'replayed')::boolean
       IS DISTINCT FROM false
     OR initiation.disposition <> expected_disposition
     OR initiation.policy_id <> expected_policy_id
     OR initiation.policy_version <> expected_policy_version
     OR initiation.actor_type <> 'SERVICE'
     OR initiation.actor_id <> 'workflow-worker'
     OR initiation.reserved_micros_krw <> 0
     OR num_nonnulls(
       initiation.case_id,initiation.dataset_snapshot_id,
       initiation.agent_run_id,initiation.job_id
     ) <> 0
     OR initiation.receipt_digest <> encode(
       extensions.digest(initiation.receipt_canonical,'sha256'),'hex'
     )
     OR (SELECT status FROM core.anomaly_signals WHERE id=v_signal_id) <> 'NEW'
     OR (SELECT version FROM core.anomaly_signals WHERE id=v_signal_id) <> 1
     OR (SELECT count(*) FROM ops.tasks
         WHERE task_type='SIGNAL_TRIAGE' AND object_id=v_signal_id) <> 1
     OR EXISTS (
       SELECT 1
       FROM ops.signal_investigation_initiation_receipts AS started
       WHERE started.signal_id=v_signal_id AND started.disposition='STARTED'
     ) THEN
    RAISE EXCEPTION
      'R6b2 negative worker no-start invalid: signal %, disposition %, jobStatus %, errorCode %',
      v_signal_id,initiation.disposition,delivery_job.status,
      delivery_job.last_error_code;
  END IF;
END $$;
SQL
}

run_r6b2_extended_negative_dispatch_cases() {
# Same target with the smallest positive dedupe window reaches the per-case cap
# rather than the earlier duplicate gate.  The original v1 STARTED case is the
# bound case-count authority, and the worker round trip is older than 1 us.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.signal_investigation_policies(
  policy_id,policy_key,version,enabled,minimum_severity,dedupe_window,
  daily_run_limit,case_daily_run_limit,daily_budget_micros_krw,
  max_run_micros_krw,kill_switch_code,agent_type,prompt_id,prompt_version,
  prompt_sha256,output_schema_id,output_schema_version,
  output_schema_sha256,provider_policy_version,provider_policy_sha256,
  provider_classification,provider_candidate_ids,budget_policy_version,
  budget_policy_sha256,max_provider_turns,max_tool_calls,deadline_interval,
  created_by,policy_digest
)
SELECT
  '31300000-0000-4000-8000-000000000040',policy_key,4,true,
  minimum_severity,interval '1 microsecond',10,1,daily_budget_micros_krw,
  max_run_micros_krw,kill_switch_code,agent_type,prompt_id,prompt_version,
  prompt_sha256,output_schema_id,output_schema_version,
  output_schema_sha256,provider_policy_version,provider_policy_sha256,
  provider_classification,provider_candidate_ids,budget_policy_version,
  budget_policy_sha256,max_provider_turns,max_tool_calls,deadline_interval,
  created_by,repeat('4',64)
FROM ops.signal_investigation_policies
WHERE policy_id='31300000-0000-4000-8000-000000000022' AND version=1;
INSERT INTO core.anomaly_signals(
  id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity,
  status,explanation,calculation
)
SELECT
  '31300000-0000-4000-8000-000000000041',run.id,run.rule_version_id,
  'R6B2_CASE_CAP','CONTRACT',
  '31300000-0000-4000-8000-000000000012','HIGH','NEW','{}','{}'
FROM core.rule_runs AS run
WHERE run.rule_version_id='31300000-0000-4000-8000-000000000020';
SELECT ops.enqueue_outbox(
  'signal','31300000-0000-4000-8000-000000000041',1,
  'detection.signal_created.v1',
  jsonb_build_object(
    'rule_version_id','31300000-0000-4000-8000-000000000020',
    'signal_id','31300000-0000-4000-8000-000000000041',
    'target_id','31300000-0000-4000-8000-000000000012'
  ),clock_timestamp()
);
SQL
run_r6b2_no_start_delivery \
  '31300000-0000-4000-8000-000000000041' \
  'CASE_DAILY_LIMIT_REACHED' \
  '31300000-0000-4000-8000-000000000040' 4

# Restore a real dedupe window and prove the same rule/target pair is rejected
# by the duplicate gate through the worker event consumer.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.signal_investigation_policies(
  policy_id,policy_key,version,enabled,minimum_severity,dedupe_window,
  daily_run_limit,case_daily_run_limit,daily_budget_micros_krw,
  max_run_micros_krw,kill_switch_code,agent_type,prompt_id,prompt_version,
  prompt_sha256,output_schema_id,output_schema_version,
  output_schema_sha256,provider_policy_version,provider_policy_sha256,
  provider_classification,provider_candidate_ids,budget_policy_version,
  budget_policy_sha256,max_provider_turns,max_tool_calls,deadline_interval,
  created_by,policy_digest
)
SELECT
  '31300000-0000-4000-8000-000000000042',policy_key,5,true,
  minimum_severity,interval '1 hour',10,10,daily_budget_micros_krw,
  max_run_micros_krw,kill_switch_code,agent_type,prompt_id,prompt_version,
  prompt_sha256,output_schema_id,output_schema_version,
  output_schema_sha256,provider_policy_version,provider_policy_sha256,
  provider_classification,provider_candidate_ids,budget_policy_version,
  budget_policy_sha256,max_provider_turns,max_tool_calls,deadline_interval,
  created_by,repeat('5',64)
FROM ops.signal_investigation_policies
WHERE policy_id='31300000-0000-4000-8000-000000000022' AND version=1;
INSERT INTO core.anomaly_signals(
  id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity,
  status,explanation,calculation
)
SELECT
  '31300000-0000-4000-8000-000000000043',run.id,run.rule_version_id,
  'R6B2_DUPLICATE','CONTRACT',
  '31300000-0000-4000-8000-000000000012','HIGH','NEW','{}','{}'
FROM core.rule_runs AS run
WHERE run.rule_version_id='31300000-0000-4000-8000-000000000020';
SELECT ops.enqueue_outbox(
  'signal','31300000-0000-4000-8000-000000000043',1,
  'detection.signal_created.v1',
  jsonb_build_object(
    'rule_version_id','31300000-0000-4000-8000-000000000020',
    'signal_id','31300000-0000-4000-8000-000000000043',
    'target_id','31300000-0000-4000-8000-000000000012'
  ),clock_timestamp()
);
SQL
run_r6b2_no_start_delivery \
  '31300000-0000-4000-8000-000000000043' \
  'DUPLICATE_SUPPRESSED' \
  '31300000-0000-4000-8000-000000000042' 5

# Create one legitimate nonzero reservation through the same worker path, then
# lower the current daily budget so the following event is run-cost blocked.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.signal_investigation_policies(
  policy_id,policy_key,version,enabled,minimum_severity,dedupe_window,
  daily_run_limit,case_daily_run_limit,daily_budget_micros_krw,
  max_run_micros_krw,kill_switch_code,agent_type,prompt_id,prompt_version,
  prompt_sha256,output_schema_id,output_schema_version,
  output_schema_sha256,provider_policy_version,provider_policy_sha256,
  provider_classification,provider_candidate_ids,budget_policy_version,
  budget_policy_sha256,max_provider_turns,max_tool_calls,deadline_interval,
  created_by,policy_digest
)
SELECT
  '31300000-0000-4000-8000-000000000044',policy_key,6,true,
  minimum_severity,interval '1 microsecond',10,10,100,1,kill_switch_code,
  agent_type,prompt_id,prompt_version,prompt_sha256,output_schema_id,
  output_schema_version,output_schema_sha256,provider_policy_version,
  provider_policy_sha256,provider_classification,provider_candidate_ids,
  budget_policy_version,budget_policy_sha256,max_provider_turns,
  max_tool_calls,deadline_interval,created_by,repeat('6',64)
FROM ops.signal_investigation_policies
WHERE policy_id='31300000-0000-4000-8000-000000000022' AND version=1;
INSERT INTO core.anomaly_signals(
  id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity,
  status,explanation,calculation
)
SELECT
  '31300000-0000-4000-8000-000000000045',run.id,run.rule_version_id,
  'R6B2_BUDGET_SEED','CONTRACT',
  '31300000-0000-4000-8000-000000000046','HIGH','NEW',
  jsonb_build_object(
    'includedIds',jsonb_build_array(
      '31300000-0000-4000-8000-000000000012'
    )
  ),'{}'
FROM core.rule_runs AS run
WHERE run.rule_version_id='31300000-0000-4000-8000-000000000020';
SELECT ops.enqueue_outbox(
  'signal','31300000-0000-4000-8000-000000000045',1,
  'detection.signal_created.v1',
  jsonb_build_object(
    'rule_version_id','31300000-0000-4000-8000-000000000020',
    'signal_id','31300000-0000-4000-8000-000000000045',
    'target_id','31300000-0000-4000-8000-000000000046'
  ),clock_timestamp()
);
SQL
run_r6b2_scheduler
run_r6b2_workflow
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  v_signal_id constant uuid := '31300000-0000-4000-8000-000000000045';
  delivery_job ops.jobs%ROWTYPE;
  attempt ops.job_attempts%ROWTYPE;
  initiation ops.signal_investigation_initiation_receipts%ROWTYPE;
BEGIN
  SELECT job.* INTO STRICT delivery_job
  FROM ops.jobs AS job
  WHERE job.job_type='EVENT_DELIVERY'
    AND job.payload->'payload'->>'signal_id'=v_signal_id::text;
  SELECT job_attempt.* INTO STRICT attempt
  FROM ops.job_attempts AS job_attempt WHERE job_attempt.job_id=delivery_job.id;
  SELECT receipt.* INTO STRICT initiation
  FROM ops.signal_investigation_initiation_receipts AS receipt
  WHERE receipt.signal_id=v_signal_id;
  IF delivery_job.status <> 'SUCCEEDED' OR attempt.outcome <> 'SUCCEEDED'
     OR attempt.metrics->'automaticInvestigation'->>'disposition'
       IS DISTINCT FROM 'STARTED'
     OR initiation.disposition <> 'STARTED'
     OR initiation.policy_id <> '31300000-0000-4000-8000-000000000044'
     OR initiation.policy_version <> 6
     OR initiation.reserved_micros_krw <> 1
     OR num_nonnulls(
       initiation.case_id,initiation.dataset_snapshot_id,
       initiation.agent_run_id,initiation.job_id
     ) <> 4
     OR NOT EXISTS (
       SELECT 1 FROM ops.agent_runs AS run
       WHERE run.id=initiation.agent_run_id
         AND run.run_contract_version=2 AND run.status='QUEUED'
         AND run.reserved_micros_krw=1
         AND run.created_actor_type='SERVICE'
         AND run.created_service='workflow-worker'
     ) THEN
    RAISE EXCEPTION
      'R6b2 budget seed start invalid: signal %, disposition %, jobStatus %, errorCode %',
      v_signal_id,initiation.disposition,delivery_job.status,
      delivery_job.last_error_code;
  END IF;
END $$;
SQL

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.signal_investigation_policies(
  policy_id,policy_key,version,enabled,minimum_severity,dedupe_window,
  daily_run_limit,case_daily_run_limit,daily_budget_micros_krw,
  max_run_micros_krw,kill_switch_code,agent_type,prompt_id,prompt_version,
  prompt_sha256,output_schema_id,output_schema_version,
  output_schema_sha256,provider_policy_version,provider_policy_sha256,
  provider_classification,provider_candidate_ids,budget_policy_version,
  budget_policy_sha256,max_provider_turns,max_tool_calls,deadline_interval,
  created_by,policy_digest
)
SELECT
  '31300000-0000-4000-8000-000000000047',policy_key,7,true,
  minimum_severity,interval '1 microsecond',10,10,1,1,kill_switch_code,
  agent_type,prompt_id,prompt_version,prompt_sha256,output_schema_id,
  output_schema_version,output_schema_sha256,provider_policy_version,
  provider_policy_sha256,provider_classification,provider_candidate_ids,
  budget_policy_version,budget_policy_sha256,max_provider_turns,
  max_tool_calls,deadline_interval,created_by,repeat('7',64)
FROM ops.signal_investigation_policies
WHERE policy_id='31300000-0000-4000-8000-000000000044' AND version=6;
INSERT INTO core.anomaly_signals(
  id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity,
  status,explanation,calculation
)
SELECT
  '31300000-0000-4000-8000-000000000048',run.id,run.rule_version_id,
  'R6B2_BUDGET_BLOCKED','CONTRACT',
  '31300000-0000-4000-8000-000000000049','HIGH','NEW','{}','{}'
FROM core.rule_runs AS run
WHERE run.rule_version_id='31300000-0000-4000-8000-000000000020';
SELECT ops.enqueue_outbox(
  'signal','31300000-0000-4000-8000-000000000048',1,
  'detection.signal_created.v1',
  jsonb_build_object(
    'rule_version_id','31300000-0000-4000-8000-000000000020',
    'signal_id','31300000-0000-4000-8000-000000000048',
    'target_id','31300000-0000-4000-8000-000000000049'
  ),clock_timestamp()
);
SQL
run_r6b2_no_start_delivery \
  '31300000-0000-4000-8000-000000000048' \
  'BUDGET_BLOCKED' \
  '31300000-0000-4000-8000-000000000047' 7
}

# First prove the missing-policy branch while the generated positive signal is
# held unpublished; then install the v1 authority and release that signal.
run_r6b2_missing_dispatch_case() {
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
BEGIN
  UPDATE ops.outbox AS event
  SET available_at=clock_timestamp()+interval '1 hour'
  WHERE event.event_type='detection.signal_created.v1'
    AND event.aggregate_id=(
      SELECT signal.id::text FROM core.anomaly_signals AS signal
      WHERE signal.rule_version_id='31300000-0000-4000-8000-000000000020'
        AND signal.signal_type='CONTRACT_AMENDMENT_ESCALATION'
    );
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6b2 generated positive signal outbox hold failed';
  END IF;
END $$;
INSERT INTO core.anomaly_signals(
  id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity,
  status,explanation,calculation
)
SELECT
  '31300000-0000-4000-8000-000000000029',run.id,run.rule_version_id,
  'R6B2_POLICY_ABSENT','CONTRACT',
  '31300000-0000-4000-8000-00000000002a','HIGH','NEW','{}','{}'
FROM core.rule_runs AS run
WHERE run.rule_version_id='31300000-0000-4000-8000-000000000020';
SELECT ops.enqueue_outbox(
  'signal','31300000-0000-4000-8000-000000000029',1,
  'detection.signal_created.v1',
  jsonb_build_object(
    'rule_version_id','31300000-0000-4000-8000-000000000020',
    'signal_id','31300000-0000-4000-8000-000000000029',
    'target_id','31300000-0000-4000-8000-00000000002a'
  ),clock_timestamp()
);
SQL

run_r6b2_scheduler
run_r6b2_workflow

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  v_signal_id constant uuid := '31300000-0000-4000-8000-000000000029';
  delivery_job ops.jobs%ROWTYPE;
  inbox_row ops.inbox%ROWTYPE;
  attempt ops.job_attempts%ROWTYPE;
  initiation ops.signal_investigation_initiation_receipts%ROWTYPE;
BEGIN
  SELECT job.* INTO STRICT delivery_job
  FROM ops.jobs AS job
  WHERE job.job_type='EVENT_DELIVERY'
    AND job.queue='workflow-worker'
    AND job.payload->'payload'->>'signal_id'=v_signal_id::text;
  SELECT inbox.* INTO STRICT inbox_row
  FROM ops.inbox AS inbox
  WHERE inbox.consumer='workflow-worker'
    AND inbox.event_id=(delivery_job.payload->>'eventId')::uuid;
  SELECT job_attempt.* INTO STRICT attempt
  FROM ops.job_attempts AS job_attempt
  WHERE job_attempt.job_id=delivery_job.id;
  SELECT receipt.* INTO STRICT initiation
  FROM ops.signal_investigation_initiation_receipts AS receipt
  WHERE receipt.signal_id=v_signal_id;
  IF delivery_job.status <> 'SUCCEEDED'
     OR inbox_row.processed_at IS NULL OR inbox_row.result <> 'SUCCEEDED'
     OR attempt.outcome <> 'SUCCEEDED'
     OR attempt.metrics->>'signalId' IS DISTINCT FROM v_signal_id::text
     OR (attempt.metrics->>'taskCreated')::boolean IS DISTINCT FROM true
     OR attempt.metrics->'automaticInvestigation'->>'disposition'
       IS DISTINCT FROM 'POLICY_ABSENT'
     OR attempt.metrics->'automaticInvestigation'->>'receiptId'
       IS DISTINCT FROM initiation.receipt_id::text
     OR initiation.disposition <> 'POLICY_ABSENT'
     OR initiation.policy_id IS NOT NULL OR initiation.policy_version IS NOT NULL
     OR initiation.reserved_micros_krw <> 0
     OR num_nonnulls(
       initiation.case_id,initiation.dataset_snapshot_id,
       initiation.agent_run_id,initiation.job_id
     ) <> 0
     OR initiation.actor_type <> 'SERVICE'
     OR initiation.actor_id <> 'workflow-worker'
     OR initiation.receipt_digest <> encode(
       extensions.digest(initiation.receipt_canonical,'sha256'),'hex'
     )
     OR EXISTS (
       SELECT 1
       FROM ops.signal_investigation_initiation_receipts AS started
       WHERE started.signal_id=v_signal_id AND started.disposition='STARTED'
     ) THEN
    RAISE EXCEPTION
      'R6b2 missing policy worker no-initiation proof invalid: job %, receipt %',
      jsonb_build_object(
        'id',delivery_job.id,'status',delivery_job.status,
        'errorCode',delivery_job.last_error_code
      ),jsonb_build_object(
        'id',initiation.receipt_id,'disposition',initiation.disposition
      );
  END IF;
END $$;

INSERT INTO ops.signal_investigation_policies(
  policy_id,version,enabled,minimum_severity,dedupe_window,
  daily_run_limit,case_daily_run_limit,daily_budget_micros_krw,
  max_run_micros_krw,kill_switch_code,agent_type,prompt_id,prompt_version,
  prompt_sha256,output_schema_id,output_schema_version,
  output_schema_sha256,provider_policy_version,provider_policy_sha256,
  provider_classification,provider_candidate_ids,budget_policy_version,
  budget_policy_sha256,max_provider_turns,max_tool_calls,deadline_interval,
  created_by,policy_digest
) VALUES (
  '31300000-0000-4000-8000-000000000022',1,true,'HIGH',interval '1 hour',
  10,10,1000,0,'r6b2-runtime-kill','investigator','r6b2-runtime-prompt',
  '1',repeat('d',64),'r6b2-runtime-output','1',repeat('e',64),
  'r6b2-runtime-provider-policy',repeat('f',64),'PUBLIC',
  ARRAY['r6b2-runtime-provider'],'r6b2-runtime-budget',repeat('0',64),
  1,0,interval '5 minutes','31000000-0000-4000-8000-000000000001',
  repeat('1',64)
);
DO $$
BEGIN
  UPDATE ops.outbox AS event
  SET available_at=clock_timestamp()
  WHERE event.event_type='detection.signal_created.v1'
    AND event.aggregate_id=(
      SELECT signal.id::text FROM core.anomaly_signals AS signal
      WHERE signal.rule_version_id='31300000-0000-4000-8000-000000000020'
        AND signal.signal_type='CONTRACT_AMENDMENT_ESCALATION'
    );
  IF NOT FOUND THEN
    RAISE EXCEPTION 'R6b2 generated positive signal outbox release failed';
  END IF;
END $$;
SQL
}

# The disabled policy must be current when its event is processed.
run_r6b2_negative_dispatch_cases() {
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.signal_investigation_policies(
  policy_id,policy_key,version,enabled,policy_digest
) VALUES (
  '31300000-0000-4000-8000-000000000023',
  'AUTO_SIGNAL_INVESTIGATION',2,false,repeat('2',64)
);
INSERT INTO core.anomaly_signals(
  id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity,
  status,explanation,calculation
)
SELECT
  '31300000-0000-4000-8000-000000000024',run.id,run.rule_version_id,
  'R6B2_POLICY_DISABLED','CONTRACT',
  '31300000-0000-4000-8000-000000000025','HIGH','NEW','{}','{}'
FROM core.rule_runs AS run
WHERE run.rule_version_id='31300000-0000-4000-8000-000000000020';
SELECT ops.enqueue_outbox(
  'signal','31300000-0000-4000-8000-000000000024',1,
  'detection.signal_created.v1',
  jsonb_build_object(
    'rule_version_id','31300000-0000-4000-8000-000000000020',
    'signal_id','31300000-0000-4000-8000-000000000024',
    'target_id','31300000-0000-4000-8000-000000000025'
  ),clock_timestamp()
);
SQL

run_r6b2_scheduler

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  delivery_job ops.jobs%ROWTYPE;
  inbox_row ops.inbox%ROWTYPE;
BEGIN
  SELECT job.* INTO STRICT delivery_job
  FROM ops.jobs AS job
  WHERE job.job_type='EVENT_DELIVERY'
    AND job.queue='workflow-worker'
    AND job.payload->'payload'->>'signal_id'
      ='31300000-0000-4000-8000-000000000024';
  SELECT inbox.* INTO STRICT inbox_row
  FROM ops.inbox AS inbox
  WHERE inbox.consumer='workflow-worker'
    AND inbox.event_id=(delivery_job.payload->>'eventId')::uuid;
  IF delivery_job.status <> 'QUEUED'
     OR inbox_row.processed_at IS NOT NULL
     OR inbox_row.result NOT LIKE 'DISPATCHED:%' THEN
    RAISE EXCEPTION
      'R6b2 disabled policy event was not queued through scheduler: job % status %, inbox % processed %, result %',
      delivery_job.id,delivery_job.status,inbox_row.id,
      inbox_row.processed_at IS NOT NULL,inbox_row.result;
  END IF;
END $$;
SQL

run_r6b2_workflow

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  v_signal_id constant uuid := '31300000-0000-4000-8000-000000000024';
  delivery_job ops.jobs%ROWTYPE;
  inbox_row ops.inbox%ROWTYPE;
  attempt ops.job_attempts%ROWTYPE;
  initiation ops.signal_investigation_initiation_receipts%ROWTYPE;
BEGIN
  SELECT job.* INTO STRICT delivery_job
  FROM ops.jobs AS job
  WHERE job.job_type='EVENT_DELIVERY'
    AND job.queue='workflow-worker'
    AND job.payload->'payload'->>'signal_id'=v_signal_id::text;
  SELECT inbox.* INTO STRICT inbox_row
  FROM ops.inbox AS inbox
  WHERE inbox.consumer='workflow-worker'
    AND inbox.event_id=(delivery_job.payload->>'eventId')::uuid;
  SELECT job_attempt.* INTO STRICT attempt
  FROM ops.job_attempts AS job_attempt
  WHERE job_attempt.job_id=delivery_job.id;
  SELECT receipt.* INTO STRICT initiation
  FROM ops.signal_investigation_initiation_receipts AS receipt
  WHERE receipt.signal_id=v_signal_id;

  IF delivery_job.status <> 'SUCCEEDED'
     OR inbox_row.processed_at IS NULL
     OR inbox_row.result <> 'SUCCEEDED'
     OR attempt.outcome <> 'SUCCEEDED'
     OR attempt.metrics->>'signalId' IS DISTINCT FROM v_signal_id::text
     OR (attempt.metrics->>'taskCreated')::boolean IS DISTINCT FROM true
     OR attempt.metrics->'automaticInvestigation'->>'disposition'
       IS DISTINCT FROM 'POLICY_DISABLED'
     OR attempt.metrics->'automaticInvestigation'->>'receiptId'
       IS DISTINCT FROM initiation.receipt_id::text
     OR attempt.metrics->'automaticInvestigation'->>'actorType'
       IS DISTINCT FROM 'SERVICE'
     OR attempt.metrics->'automaticInvestigation'->>'actorId'
       IS DISTINCT FROM 'workflow-worker'
     OR (attempt.metrics->'automaticInvestigation'->>'replayed')::boolean
       IS DISTINCT FROM false
     OR initiation.disposition <> 'POLICY_DISABLED'
     OR initiation.policy_id <> '31300000-0000-4000-8000-000000000023'
     OR initiation.policy_version <> 2
     OR initiation.actor_type <> 'SERVICE'
     OR initiation.actor_id <> 'workflow-worker'
     OR initiation.reserved_micros_krw <> 0
     OR num_nonnulls(
       initiation.case_id,initiation.dataset_snapshot_id,
       initiation.agent_run_id,initiation.job_id
     ) <> 0
     OR initiation.receipt_digest <> encode(
       extensions.digest(initiation.receipt_canonical,'sha256'),'hex'
     )
     OR (SELECT status FROM core.anomaly_signals WHERE id=v_signal_id) <> 'NEW'
     OR (SELECT version FROM core.anomaly_signals WHERE id=v_signal_id) <> 1
     OR (SELECT count(*) FROM ops.tasks
         WHERE task_type='SIGNAL_TRIAGE' AND object_id=v_signal_id) <> 1
     OR EXISTS (
       SELECT 1
       FROM ops.signal_investigation_initiation_receipts AS started
       WHERE started.signal_id=v_signal_id AND started.disposition='STARTED'
     ) THEN
    RAISE EXCEPTION
      'R6b2 disabled policy worker no-initiation proof invalid: job % status %, inbox % result %, attempt % outcome %, receipt % disposition %',
      delivery_job.id,delivery_job.status,inbox_row.id,inbox_row.result,
      attempt.attempt,attempt.outcome,initiation.receipt_id,
      initiation.disposition;
  END IF;
END $$;
SQL

# The already committed v1 STARTED receipt is the daily-cap baseline.  Install
# an enabled v3 with a one-run daily limit, then prove a second real delivery
# is a successful no-initiation result rather than a hidden worker failure.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.signal_investigation_policies(
  policy_id,policy_key,version,enabled,minimum_severity,dedupe_window,
  daily_run_limit,case_daily_run_limit,daily_budget_micros_krw,
  max_run_micros_krw,kill_switch_code,agent_type,prompt_id,prompt_version,
  prompt_sha256,output_schema_id,output_schema_version,
  output_schema_sha256,provider_policy_version,provider_policy_sha256,
  provider_classification,provider_candidate_ids,budget_policy_version,
  budget_policy_sha256,max_provider_turns,max_tool_calls,deadline_interval,
  created_by,policy_digest
)
SELECT
  '31300000-0000-4000-8000-000000000026',policy_key,3,true,
  minimum_severity,dedupe_window,1,case_daily_run_limit,
  daily_budget_micros_krw,max_run_micros_krw,kill_switch_code,agent_type,
  prompt_id,prompt_version,prompt_sha256,output_schema_id,
  output_schema_version,output_schema_sha256,provider_policy_version,
  provider_policy_sha256,provider_classification,provider_candidate_ids,
  budget_policy_version,budget_policy_sha256,max_provider_turns,
  max_tool_calls,deadline_interval,created_by,repeat('3',64)
FROM ops.signal_investigation_policies
WHERE policy_id='31300000-0000-4000-8000-000000000022' AND version=1;
INSERT INTO core.anomaly_signals(
  id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity,
  status,explanation,calculation
)
SELECT
  '31300000-0000-4000-8000-000000000027',run.id,run.rule_version_id,
  'R6B2_DAILY_CAP','CONTRACT',
  '31300000-0000-4000-8000-000000000028','HIGH','NEW','{}','{}'
FROM core.rule_runs AS run
WHERE run.rule_version_id='31300000-0000-4000-8000-000000000020';
SELECT ops.enqueue_outbox(
  'signal','31300000-0000-4000-8000-000000000027',1,
  'detection.signal_created.v1',
  jsonb_build_object(
    'rule_version_id','31300000-0000-4000-8000-000000000020',
    'signal_id','31300000-0000-4000-8000-000000000027',
    'target_id','31300000-0000-4000-8000-000000000028'
  ),clock_timestamp()
);
SQL

run_r6b2_scheduler

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  delivery_job ops.jobs%ROWTYPE;
  inbox_row ops.inbox%ROWTYPE;
BEGIN
  SELECT job.* INTO STRICT delivery_job
  FROM ops.jobs AS job
  WHERE job.job_type='EVENT_DELIVERY'
    AND job.queue='workflow-worker'
    AND job.payload->'payload'->>'signal_id'
      ='31300000-0000-4000-8000-000000000027';
  SELECT inbox.* INTO STRICT inbox_row
  FROM ops.inbox AS inbox
  WHERE inbox.consumer='workflow-worker'
    AND inbox.event_id=(delivery_job.payload->>'eventId')::uuid;
  IF delivery_job.status <> 'QUEUED'
     OR inbox_row.processed_at IS NOT NULL
     OR inbox_row.result NOT LIKE 'DISPATCHED:%' THEN
    RAISE EXCEPTION
      'R6b2 daily-cap event was not queued through scheduler: job % status %, inbox % processed %, result %',
      delivery_job.id,delivery_job.status,inbox_row.id,
      inbox_row.processed_at IS NOT NULL,inbox_row.result;
  END IF;
END $$;
SQL

run_r6b2_workflow

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  v_signal_id constant uuid := '31300000-0000-4000-8000-000000000027';
  delivery_job ops.jobs%ROWTYPE;
  inbox_row ops.inbox%ROWTYPE;
  attempt ops.job_attempts%ROWTYPE;
  initiation ops.signal_investigation_initiation_receipts%ROWTYPE;
BEGIN
  SELECT job.* INTO STRICT delivery_job
  FROM ops.jobs AS job
  WHERE job.job_type='EVENT_DELIVERY'
    AND job.queue='workflow-worker'
    AND job.payload->'payload'->>'signal_id'=v_signal_id::text;
  SELECT inbox.* INTO STRICT inbox_row
  FROM ops.inbox AS inbox
  WHERE inbox.consumer='workflow-worker'
    AND inbox.event_id=(delivery_job.payload->>'eventId')::uuid;
  SELECT job_attempt.* INTO STRICT attempt
  FROM ops.job_attempts AS job_attempt
  WHERE job_attempt.job_id=delivery_job.id;
  SELECT receipt.* INTO STRICT initiation
  FROM ops.signal_investigation_initiation_receipts AS receipt
  WHERE receipt.signal_id=v_signal_id;

  IF delivery_job.status <> 'SUCCEEDED'
     OR inbox_row.processed_at IS NULL
     OR inbox_row.result <> 'SUCCEEDED'
     OR attempt.outcome <> 'SUCCEEDED'
     OR attempt.metrics->>'signalId' IS DISTINCT FROM v_signal_id::text
     OR (attempt.metrics->>'taskCreated')::boolean IS DISTINCT FROM true
     OR attempt.metrics->'automaticInvestigation'->>'disposition'
       IS DISTINCT FROM 'DAILY_LIMIT_REACHED'
     OR attempt.metrics->'automaticInvestigation'->>'receiptId'
       IS DISTINCT FROM initiation.receipt_id::text
     OR attempt.metrics->'automaticInvestigation'->>'actorType'
       IS DISTINCT FROM 'SERVICE'
     OR attempt.metrics->'automaticInvestigation'->>'actorId'
       IS DISTINCT FROM 'workflow-worker'
     OR (attempt.metrics->'automaticInvestigation'->>'replayed')::boolean
       IS DISTINCT FROM false
     OR initiation.disposition <> 'DAILY_LIMIT_REACHED'
     OR initiation.policy_id <> '31300000-0000-4000-8000-000000000026'
     OR initiation.policy_version <> 3
     OR initiation.actor_type <> 'SERVICE'
     OR initiation.actor_id <> 'workflow-worker'
     OR initiation.reserved_micros_krw <> 0
     OR num_nonnulls(
       initiation.case_id,initiation.dataset_snapshot_id,
       initiation.agent_run_id,initiation.job_id
     ) <> 0
     OR initiation.receipt_digest <> encode(
       extensions.digest(initiation.receipt_canonical,'sha256'),'hex'
     )
     OR (SELECT status FROM core.anomaly_signals WHERE id=v_signal_id) <> 'NEW'
     OR (SELECT version FROM core.anomaly_signals WHERE id=v_signal_id) <> 1
     OR (SELECT count(*) FROM ops.tasks
         WHERE task_type='SIGNAL_TRIAGE' AND object_id=v_signal_id) <> 1
     OR EXISTS (
       SELECT 1
       FROM ops.signal_investigation_initiation_receipts AS started
       WHERE started.signal_id=v_signal_id AND started.disposition='STARTED'
     )
     OR (SELECT count(*)
         FROM ops.signal_investigation_initiation_receipts
         WHERE disposition='STARTED'
           AND created_at >= date_trunc('day',clock_timestamp())) <> 1 THEN
    RAISE EXCEPTION
      'R6b2 daily-cap worker no-initiation proof invalid: job % status %, inbox % result %, attempt % outcome %, receipt % disposition %',
      delivery_job.id,delivery_job.status,inbox_row.id,inbox_row.result,
      attempt.attempt,attempt.outcome,initiation.receipt_id,
      initiation.disposition;
  END IF;
END $$;
SQL
run_r6b2_extended_negative_dispatch_cases
}

run_r6b2_analysis

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  snapshot core.dataset_snapshots%ROWTYPE;
  member core.dataset_snapshot_members%ROWTYPE;
  frozen_fact core.dataset_snapshot_strong_identifier_facts%ROWTYPE;
  build_job_id uuid;
  expected_fact_set_sha256 char(64);
BEGIN
  SELECT id INTO STRICT build_job_id
  FROM ops.jobs
  WHERE job_type='DETECTION_SNAPSHOT_BUILD'
    AND payload->>'ruleVersionId'='31300000-0000-4000-8000-000000000020'
    AND status='SUCCEEDED';
  SELECT * INTO STRICT snapshot
  FROM core.dataset_snapshots
  WHERE producer_job_id=build_job_id AND snapshot_kind='DETECTION_DATASET';
  SELECT * INTO STRICT member
  FROM core.dataset_snapshot_members
  WHERE dataset_snapshot_id=snapshot.id;
  SELECT * INTO STRICT frozen_fact
  FROM core.dataset_snapshot_strong_identifier_facts
  WHERE dataset_snapshot_id=snapshot.id;
  SELECT encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_agg(
      btrim(fact.fact_digest) ORDER BY fact.fact_ordinal
    )),'sha256'
  ),'hex') INTO STRICT expected_fact_set_sha256
  FROM core.dataset_snapshot_strong_identifier_facts AS fact
  WHERE fact.dataset_snapshot_id=snapshot.id;
  IF snapshot.state <> 'READY'
     OR snapshot.member_count <> 1
     OR snapshot.snapshot_sha256 IS NULL
     OR snapshot.terminal_receipt_sha256 IS NULL
     OR snapshot.strong_identifier_fact_count <> 1
     OR snapshot.strong_identifier_fact_set_sha256
       <> expected_fact_set_sha256
     OR snapshot.selection_spec->>'ruleVersionId'
       IS DISTINCT FROM '31300000-0000-4000-8000-000000000020'
     OR member.object_type <> 'CONTRACT'
     OR member.object_id <> '31300000-0000-4000-8000-000000000012'
     OR member.object_version <> 3
     OR member.canonical_payload->>'schemaVersion'
       IS DISTINCT FROM 'contract-snapshot.v1'
     OR (member.canonical_payload->>'amendmentCount')::bigint <> 2
     OR (member.canonical_payload->>'scopeChangeExplained')::boolean
     OR member.canonical_payload->>'originalAmount' IS DISTINCT FROM '20000000.0000'
     OR member.canonical_payload->>'currentAmount' IS DISTINCT FROM '32000000.0000'
     OR frozen_fact.fact_ordinal <> 0
     OR frozen_fact.snapshot_member_id <> member.id
     OR frozen_fact.snapshot_member_digest <> member.member_digest
     OR frozen_fact.contract_id <> member.object_id
     OR frozen_fact.supplier_id <> '31300000-0000-4000-8000-000000000011'
     OR frozen_fact.identifier_id <> '31300000-0000-4000-8000-000000000912'
     OR frozen_fact.scheme <> 'KOREAN_BUSINESS_NUMBER'
     OR frozen_fact.verification_status <> 'VERIFIED'
     OR frozen_fact.proof_state <> 'PROVEN_V1'
     OR frozen_fact.fact_digest <> encode(
       extensions.digest(frozen_fact.fact_canonical,'sha256'),'hex'
     )
     OR convert_from(frozen_fact.fact_canonical,'UTF8')::jsonb
       ->>'identifierFactDigest'
       IS DISTINCT FROM btrim(frozen_fact.identifier_fact_digest)
     OR NOT EXISTS (
       SELECT 1 FROM ops.outbox
       WHERE aggregate_id=snapshot.id::text
         AND event_type='dataset.snapshot_created.v1'
         AND payload->>'state'='READY'
         AND payload->>'snapshotSha256'=btrim(snapshot.snapshot_sha256::text)
         AND payload->>'terminalReceiptDigest'
           =btrim(snapshot.terminal_receipt_sha256::text)
     ) THEN
    RAISE EXCEPTION
      'R6b2 detection snapshot authority invalid: snapshotId %, state %, memberId %, factId %',
      snapshot.id,snapshot.state,member.id,frozen_fact.id;
  END IF;
END $$;
SQL

# Append a second live PROVEN_V1 fact after READY.  The already sealed snapshot
# must retain its exact one-fact set, and downstream evaluation must consume
# that frozen relation rather than re-reading the live identifier table.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  v_candidate_id constant uuid := '31300000-0000-4000-8000-000000000913';
  v_identifier_id constant uuid := '31300000-0000-4000-8000-000000000914';
  v_supplier_id constant uuid := '31300000-0000-4000-8000-000000000011';
  source_id constant uuid := '31300000-0000-4000-8000-000000000001';
  parsed_record_id constant uuid :=
    '31300000-0000-4000-8000-000000000907';
  value_hash char(64) := repeat('c',64);
  source_locator_digest char(64);
  verification_evidence_digest char(64);
  identifier_fact_digest char(64);
  candidate_payload jsonb;
  candidate_canonical bytea;
  candidate_digest char(64);
  sealed_snapshot core.dataset_snapshots%ROWTYPE;
BEGIN
  SELECT snapshot.* INTO STRICT sealed_snapshot
  FROM core.dataset_snapshots AS snapshot
  WHERE snapshot.snapshot_kind='DETECTION_DATASET'
    AND snapshot.state='READY';
  source_locator_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'sourceDocumentId',source_id,'parsedRecordId',parsed_record_id,
      'recordIndex',1,'field','dartCorpCode'
    )),'sha256'
  ),'hex');
  verification_evidence_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'kind','SOURCE_VERIFIED','sourceDocumentId',source_id,
      'sourceContentSha256',repeat('1',64),'recordIndex',1
    )),'sha256'
  ),'hex');
  candidate_payload := jsonb_build_object(
    'schemaVersion','supplier-identity-candidate.v1',
    'candidateId',v_candidate_id,'candidateRevision',1,
    'sourceDocumentId',source_id,'parsedRecordId',parsed_record_id,
    'recordIndex',1,'mappingVersion','connector-structured-json-v1',
    'normalizedName','r6b2 runtime supplier future fact',
    'identifierCount',1,'identityStatus','CANDIDATE'
  );
  candidate_canonical := ops.canonical_jsonb_v1(candidate_payload);
  candidate_digest := encode(extensions.digest(
    candidate_canonical,'sha256'
  ),'hex');
  INSERT INTO core.supplier_identity_candidates(
    candidate_id,candidate_revision,candidate_digest,
    source_document_id,source_asset_id,source_asset_revision,
    source_content_sha256,parsed_record_id,source_record_digest,record_index,
    mapping_version,normalized_name,name_source_locator_digest,
    identifier_count,identifier_set_digest,identity_status,
    candidate_payload,candidate_canonical,candidate_digest_preimage_canonical
  ) VALUES (
    v_candidate_id,1,candidate_digest,source_id,source_id,1,repeat('1',64),
    parsed_record_id,repeat('a',64),1,'connector-structured-json-v1',
    'r6b2 runtime supplier future fact',source_locator_digest,1,
    encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_array(value_hash)),'sha256'
    ),'hex'),'CANDIDATE',candidate_payload,candidate_canonical,
    candidate_canonical
  );
  identifier_fact_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','supplier-identifier-fact.v1',
      'supplierId',v_supplier_id,'scheme','OPEN_DART_CORP_CODE',
      'valueHash',btrim(value_hash),'candidateId',v_candidate_id,
      'candidateRevision',1,'candidateDigest',btrim(candidate_digest),
      'sourceLocatorDigest',btrim(source_locator_digest),
      'verificationEvidenceDigest',btrim(verification_evidence_digest),
      'verificationStatus','VERIFIED','proofState','PROVEN_V1'
    )),'sha256'
  ),'hex');
  INSERT INTO core.supplier_identifiers(
    id,supplier_id,scheme,value_hash,source_document_id,
    verification_status,candidate_id,candidate_revision,candidate_digest,
    source_locator_digest,verification_evidence_digest,
    identifier_fact_digest,proof_state
  ) VALUES (
    v_identifier_id,v_supplier_id,'OPEN_DART_CORP_CODE',value_hash,source_id,
    'VERIFIED',v_candidate_id,1,candidate_digest,source_locator_digest,
    verification_evidence_digest,identifier_fact_digest,'PROVEN_V1'
  );

  IF (SELECT count(*) FROM core.supplier_identifiers AS identifier
      WHERE identifier.supplier_id=v_supplier_id
        AND identifier.proof_state='PROVEN_V1') <> 2
     OR (SELECT strong_identifier_fact_count
         FROM core.dataset_snapshots WHERE id=sealed_snapshot.id) <> 1
     OR (SELECT strong_identifier_fact_set_sha256
         FROM core.dataset_snapshots WHERE id=sealed_snapshot.id)
       <> sealed_snapshot.strong_identifier_fact_set_sha256
     OR (SELECT snapshot_sha256 FROM core.dataset_snapshots
         WHERE id=sealed_snapshot.id) <> sealed_snapshot.snapshot_sha256
     OR (SELECT count(*)
         FROM core.dataset_snapshot_strong_identifier_facts
         WHERE dataset_snapshot_id=sealed_snapshot.id) <> 1
     OR EXISTS (
       SELECT 1
       FROM core.dataset_snapshot_strong_identifier_facts AS frozen_fact
       WHERE frozen_fact.dataset_snapshot_id=sealed_snapshot.id
         AND frozen_fact.identifier_id=v_identifier_id
     ) THEN
    RAISE EXCEPTION
      'R6b2 frozen strong fact set changed after live append: snapshotId %, identifierId %',
      sealed_snapshot.id,v_identifier_id;
  END IF;
END $$;
SQL

run_r6b2_scheduler
run_r6b2_analysis

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  snapshot_id uuid;
  run_id uuid;
  signal_id uuid;
BEGIN
  SELECT snapshot.id INTO STRICT snapshot_id
  FROM core.dataset_snapshots AS snapshot
  JOIN ops.jobs AS build_job ON build_job.id=snapshot.producer_job_id
  WHERE build_job.job_type='DETECTION_SNAPSHOT_BUILD'
    AND build_job.payload->>'ruleVersionId'
      ='31300000-0000-4000-8000-000000000020';
  SELECT run.id INTO STRICT run_id
  FROM core.rule_runs AS run
  WHERE run.rule_version_id='31300000-0000-4000-8000-000000000020';
  SELECT signal.id INTO STRICT signal_id
  FROM core.anomaly_signals AS signal
  WHERE signal.rule_run_id=run_id;
  IF NOT EXISTS (
       SELECT 1 FROM core.rule_evaluations
       WHERE rule_version_id='31300000-0000-4000-8000-000000000020'
         AND dataset_snapshot_id=snapshot_id
         AND requester_type='SERVICE'
         AND requester_service='snapshot-producer'
         AND status='SUCCEEDED'
     )
     OR NOT EXISTS (
       SELECT 1 FROM core.rule_runs
       WHERE id=run_id AND status='SUCCEEDED' AND signal_count=1
         AND dataset_snapshot_id=snapshot_id
         AND dataset_snapshot_sha256=(
           SELECT snapshot_sha256 FROM core.dataset_snapshots
           WHERE id=snapshot_id
         )
     )
     OR NOT EXISTS (
       SELECT 1 FROM core.anomaly_signals
       WHERE id=signal_id
         AND rule_version_id='31300000-0000-4000-8000-000000000020'
         AND signal_type='CONTRACT_AMENDMENT_ESCALATION'
         AND target_type='CONTRACT'
         AND target_id='31300000-0000-4000-8000-000000000012'
         AND severity='HIGH' AND status='NEW'
     )
     OR NOT EXISTS (
       SELECT 1 FROM ops.outbox
       WHERE aggregate_id=signal_id::text
         AND event_type='detection.signal_created.v1'
     )
     OR EXISTS (
       SELECT 1 FROM ops.jobs AS job
       WHERE job.job_type='DETECTION_SNAPSHOT_BUILD'
         AND job.payload->>'ruleVersionId'
           ='31300000-0000-4000-8000-000000000020'
         AND job.status<>'SUCCEEDED'
     )
     OR EXISTS (
       SELECT 1
       FROM ops.jobs AS job
       JOIN core.rule_evaluations AS evaluation
         ON job.payload->>'evaluationId'=evaluation.id::text
       WHERE job.job_type='RULE_EVALUATION'
         AND evaluation.rule_version_id
           ='31300000-0000-4000-8000-000000000020'
         AND job.status<>'SUCCEEDED'
     ) THEN
    RAISE EXCEPTION 'R6b2 snapshot sweep did not create one bound signal';
  END IF;
END $$;
SQL

run_r6b2_missing_dispatch_case
run_r6b2_scheduler

# Exercise the active-policy owner boundary inside a rollback with the exact
# signal and EVENT_DELIVERY job that the real worker will consume.  The fixture
# contains no secrets, so a failure reports PostgreSQL structural diagnostics
# while the worker's durable error path remains redacted and unchanged.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
BEGIN;
SELECT set_config(
  'r6b2.started_signal_id',
  (
    SELECT signal.id::text
    FROM core.anomaly_signals AS signal
    WHERE signal.rule_version_id='31300000-0000-4000-8000-000000000020'
      AND signal.signal_type='CONTRACT_AMENDMENT_ESCALATION'
  ),false
);
SELECT set_config(
  'r6b2.started_delivery_job_id',
  (
    SELECT job.id::text
    FROM ops.jobs AS job
    WHERE job.job_type='EVENT_DELIVERY'
      AND job.queue='workflow-worker'
      AND job.payload->'payload'->>'signal_id'
        =current_setting('r6b2.started_signal_id')
  ),false
);
SET SESSION AUTHORIZATION gurine_workflow_worker;
DO $$
DECLARE
  v_state text;
  v_message text;
  v_schema text;
  v_table text;
  v_constraint text;
BEGIN
  BEGIN
    PERFORM * FROM ops.process_signal_investigation_v1(
      current_setting('r6b2.started_signal_id')::uuid,
      current_setting('r6b2.started_delivery_job_id')::uuid
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS
      v_state=RETURNED_SQLSTATE,
      v_message=MESSAGE_TEXT,
      v_schema=SCHEMA_NAME,
      v_table=TABLE_NAME,
      v_constraint=CONSTRAINT_NAME;
    RAISE EXCEPTION
      'R6b2 started owner preflight failed: state %, message %, schema %, table %, constraint %',
      v_state,v_message,v_schema,v_table,v_constraint;
  END;
END $$;
ROLLBACK;
SQL

run_r6b2_workflow

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  pipeline_signal_id uuid;
  delivery_job ops.jobs%ROWTYPE;
  delivery_attempt ops.job_attempts%ROWTYPE;
  initiation ops.signal_investigation_initiation_receipts%ROWTYPE;
  initiation_count bigint;
BEGIN
  SELECT signal.id INTO STRICT pipeline_signal_id
  FROM core.anomaly_signals AS signal
  WHERE signal.rule_version_id='31300000-0000-4000-8000-000000000020'
    AND signal.signal_type='CONTRACT_AMENDMENT_ESCALATION';
  SELECT job.* INTO STRICT delivery_job
  FROM ops.jobs AS job
  WHERE job.job_type='EVENT_DELIVERY'
    AND job.queue='workflow-worker'
    AND job.payload->'payload'->>'signal_id'=pipeline_signal_id::text;
  SELECT attempt.* INTO STRICT delivery_attempt
  FROM ops.job_attempts AS attempt
  WHERE attempt.job_id=delivery_job.id;
  SELECT count(*) INTO initiation_count
  FROM ops.signal_investigation_initiation_receipts AS receipt
  WHERE receipt.signal_id=pipeline_signal_id;
  IF initiation_count <> 1 THEN
    RAISE EXCEPTION
      'R6b2 signal investigation receipt missing: signal %, job % status % errorCode % errorDetailSha256 %, attempt % outcome % errorCode % errorDetailSha256 %',
      pipeline_signal_id,delivery_job.id,delivery_job.status,
      delivery_job.last_error_code,
      encode(extensions.digest(
        COALESCE(delivery_job.last_error_detail,'')::bytea,'sha256'
      ),'hex'),
      delivery_attempt.attempt,delivery_attempt.outcome,
      delivery_attempt.error_code,
      encode(extensions.digest(
        COALESCE(delivery_attempt.error_detail,'')::bytea,'sha256'
      ),'hex');
  END IF;
  SELECT receipt.* INTO STRICT initiation
  FROM ops.signal_investigation_initiation_receipts AS receipt
  WHERE receipt.signal_id=pipeline_signal_id;
  IF initiation.disposition <> 'STARTED'
     OR initiation.actor_type <> 'SERVICE'
     OR initiation.actor_id <> 'workflow-worker'
     OR initiation.policy_id <> '31300000-0000-4000-8000-000000000022'
     OR initiation.policy_version <> 1
     OR initiation.reserved_micros_krw <> 0
     OR initiation.receipt_digest <> encode(
       extensions.digest(initiation.receipt_canonical,'sha256'),'hex'
     )
     OR NOT EXISTS (
       SELECT 1 FROM editorial.cases
       WHERE id=initiation.case_id
         AND investigation_state='SIGNAL_DETECTED'
         AND publication_state='NEVER_PUBLISHED'
     )
     OR NOT EXISTS (
       SELECT 1 FROM core.dataset_snapshots
       WHERE id=initiation.dataset_snapshot_id
         AND snapshot_kind='AGENT_CASE' AND state='READY'
     )
     OR NOT EXISTS (
       SELECT 1 FROM ops.agent_runs
       WHERE id=initiation.agent_run_id AND run_contract_version=2
         AND dataset_snapshot_id=initiation.dataset_snapshot_id
         AND status='QUEUED' AND control_state='NONE' AND version=1
         AND created_actor_type='SERVICE'
         AND created_service='workflow-worker'
     )
     OR NOT EXISTS (
       SELECT 1 FROM ops.jobs
       WHERE id=initiation.job_id AND job_type='AGENT_RUN'
         AND queue='analysis-worker' AND status='QUEUED'
     ) THEN
    RAISE EXCEPTION
      'R6b2 signal investigation initiation invalid: receipt % disposition %, policy % version %, run %, job %',
      initiation.receipt_id,initiation.disposition,initiation.policy_id,
      initiation.policy_version,initiation.agent_run_id,initiation.job_id;
  END IF;
END $$;
SQL

run_r6b2_negative_dispatch_cases
run_r6b2_analysis

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  initiation ops.signal_investigation_initiation_receipts%ROWTYPE;
  run ops.agent_runs%ROWTYPE;
  claim_receipt ops.agent_run_control_receipts%ROWTYPE;
  terminal_receipt ops.agent_run_control_receipts%ROWTYPE;
BEGIN
  SELECT receipt.* INTO STRICT initiation
  FROM ops.signal_investigation_initiation_receipts AS receipt
  JOIN core.anomaly_signals AS signal ON signal.id=receipt.signal_id
  WHERE signal.rule_version_id='31300000-0000-4000-8000-000000000020'
    AND signal.signal_type='CONTRACT_AMENDMENT_ESCALATION';
  SELECT * INTO STRICT run
  FROM ops.agent_runs WHERE id=initiation.agent_run_id;
  SELECT * INTO STRICT claim_receipt
  FROM ops.agent_run_control_receipts
  WHERE agent_run_id=run.id AND aggregate_version=1;
  SELECT * INTO STRICT terminal_receipt
  FROM ops.agent_run_control_receipts
  WHERE agent_run_id=run.id AND aggregate_version=2;

  IF run.status <> 'BUDGET_BLOCKED'
     OR run.control_state <> 'SETTLED'
     OR run.version <> 3
     OR run.completed_at IS NULL
     OR btrim(run.terminal_receipt_sha256::text)
       <> btrim(terminal_receipt.receipt_sha256::text)
     OR (SELECT status FROM ops.jobs WHERE id=initiation.job_id) <> 'SUCCEEDED'
     OR (SELECT count(*) FROM ops.agent_run_control_receipts
         WHERE agent_run_id=run.id) <> 2
     OR claim_receipt.prior_receipt_id IS NOT NULL
     OR claim_receipt.prior_receipt_sha256 IS NOT NULL
     OR claim_receipt.prior_status IS NOT NULL
     OR claim_receipt.prior_control_state IS NOT NULL
     OR claim_receipt.next_status <> 'RUNNING'
     OR claim_receipt.next_control_state <> 'ACTIVE'
     OR claim_receipt.proof_kind <> 'LEASE_CLAIM'
     OR claim_receipt.reason_code <> 'RUN_STARTED'
     OR claim_receipt.actor_type <> 'SERVICE'
     OR claim_receipt.actor_kind <> 'ANALYSIS_WORKER'
     OR claim_receipt.actor_id_text <> 'analysis-worker'
     OR terminal_receipt.prior_receipt_id <> claim_receipt.receipt_id
     OR terminal_receipt.prior_receipt_sha256 <> claim_receipt.receipt_sha256
     OR terminal_receipt.prior_status <> 'RUNNING'
     OR terminal_receipt.prior_control_state <> 'ACTIVE'
     OR terminal_receipt.next_status <> 'BUDGET_BLOCKED'
     OR terminal_receipt.next_control_state <> 'SETTLED'
     OR terminal_receipt.proof_kind <> 'DEFINITIVE_NO_DISPATCH'
     OR terminal_receipt.reason_code <> 'BUDGET_DENIED'
     OR terminal_receipt.actor_type <> 'SERVICE'
     OR terminal_receipt.actor_kind <> 'ANALYSIS_WORKER'
     OR terminal_receipt.actor_id_text <> 'analysis-worker'
     OR claim_receipt.receipt_sha256 <> encode(
       extensions.digest(claim_receipt.receipt_canonical,'sha256'),'hex'
     )
     OR terminal_receipt.receipt_sha256 <> encode(
       extensions.digest(terminal_receipt.receipt_canonical,'sha256'),'hex'
     )
     OR (SELECT count(*) FROM ops.audit_events AS audit
         WHERE audit.id IN (
           claim_receipt.audit_event_id,terminal_receipt.audit_event_id
         ) AND audit.actor_type='SERVICE'
           AND audit.actor_id='analysis-worker') <> 2
     OR EXISTS (
       SELECT 1 FROM ops.jobs AS job
       WHERE job.job_type='EVENT_DELIVERY'
         AND job.queue='analysis-worker'
         AND job.payload->>'consumerId'='analysis-worker'
         AND job.payload->>'eventType'='dataset.snapshot_created.v1'
         AND job.payload#>>'{payload,snapshotKind}'='AGENT_CASE'
     ) THEN
    RAISE EXCEPTION
      'R6b2 v2 agent transition chain invalid: run % status/control/version %/%/%, claim % reason %, terminal % reason %',
      run.id,run.status,run.control_state,run.version,
      claim_receipt.receipt_id,claim_receipt.reason_code,
      terminal_receipt.receipt_id,terminal_receipt.reason_code;
  END IF;
END $$;
SQL

# D1 sensitivity proof is defined here but invoked after the R6c rule jobs.
# Altering only the declared contract-row identity basis must produce a
# different canonical digest and exactly one new deduped build job.  Invoking
# it last keeps that job QUEUED and intentionally out of analysis-worker.
r6b2_d1_sensitivity_proof() {
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
CREATE TEMP TABLE r6b_d1_identity_change(
  before_digest text NOT NULL,
  after_digest text,
  before_job_count bigint NOT NULL
);
INSERT INTO r6b_d1_identity_change(before_digest,before_job_count)
SELECT btrim(identity.contract_identity_set_sha256),(
  SELECT count(*) FROM ops.jobs AS job
  WHERE job.job_type='DETECTION_SNAPSHOT_BUILD'
    AND job.payload->>'ruleVersionId'
      ='31300000-0000-4000-8000-000000000020'
)
FROM core.current_detection_contract_identity_v1() AS identity;
UPDATE core.contracts AS contract
SET updated_at=contract.updated_at+interval '1 microsecond'
WHERE contract.id='31300000-0000-4000-8000-000000000012';
UPDATE r6b_d1_identity_change AS state
SET after_digest=btrim(identity.contract_identity_set_sha256)
FROM core.current_detection_contract_identity_v1() AS identity;
CREATE TEMP TABLE r6b_d1_enqueue_result(enqueued bigint NOT NULL);
GRANT INSERT,SELECT ON r6b_d1_enqueue_result TO gurine_scheduler;
SET ROLE gurine_scheduler;
INSERT INTO r6b_d1_enqueue_result
SELECT ops.enqueue_due_detection_snapshot_builds_v1(100);
RESET ROLE;
DO $$
DECLARE
  v_state r6b_d1_identity_change%ROWTYPE;
  v_enqueued bigint;
  v_new_job ops.jobs%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_state FROM r6b_d1_identity_change;
  SELECT enqueued INTO STRICT v_enqueued FROM r6b_d1_enqueue_result;
  SELECT job.* INTO STRICT v_new_job
  FROM ops.jobs AS job
  WHERE job.job_type='DETECTION_SNAPSHOT_BUILD'
    AND job.payload->>'ruleVersionId'
      ='31300000-0000-4000-8000-000000000020'
    AND job.payload->>'contractIdentitySetSha256'=v_state.after_digest;
  IF v_state.before_digest=v_state.after_digest
     OR v_enqueued <> 1
     OR (SELECT count(*) FROM ops.jobs AS job
         WHERE job.job_type='DETECTION_SNAPSHOT_BUILD'
           AND job.payload->>'ruleVersionId'
             ='31300000-0000-4000-8000-000000000020')
       <> v_state.before_job_count + 1
     OR v_new_job.status <> 'QUEUED'
     OR v_new_job.queue <> 'analysis-worker'
     OR v_new_job.payload->>'schemaVersion'
       IS DISTINCT FROM 'detection-snapshot-build-job.v1'
     OR (v_new_job.payload->>'contractCount')::bigint <> 1
     OR v_new_job.dedupe_key IS DISTINCT FROM
       'detection-snapshot-build:' ||
       '31300000-0000-4000-8000-000000000020' || ':' ||
       v_state.after_digest
     OR EXISTS (
       SELECT 1 FROM core.dataset_snapshots AS snapshot
       WHERE snapshot.producer_job_id=v_new_job.id
     ) THEN
    RAISE EXCEPTION
      'detection contract identity sensitivity invalid: before %, after %, enqueued %, job %, status %',
      v_state.before_digest,v_state.after_digest,v_enqueued,
      v_new_job.id,v_new_job.status;
  END IF;
END $$;
SQL
}

docker exec -i "$container" psql -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  < db/test-fixtures/r6c-typed-graph-runtime.sql

r6c_recursion_phase() {
  local phase="$1"
  shift
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 \
    -U postgres -d "$database" -v "r6c_recursion_phase=$phase" "$@" \
    < db/test-fixtures/r6c-hypothesis-recursion-runtime.sql >/dev/null
}

r6c_hypothesis_proposal_id() {
  case "$1" in
    approve_absent) echo "31610000-0000-4000-8000-000000000001" ;;
    approve_disabled) echo "31610000-0000-4000-8000-000000000002" ;;
    approve_case_budget) echo "31610000-0000-4000-8000-000000000003" ;;
    approve_max_depth) echo "31610000-0000-4000-8000-000000000004" ;;
    approve_happy) echo "31610000-0000-4000-8000-000000000005" ;;
    approve_stale_case) echo "31610000-0000-4000-8000-000000000006" ;;
    *)
      echo "unknown R6c approval phase: $1" >&2
      return 1
      ;;
  esac
}

r6c_approve_hypothesis() {
  local phase="$1"
  local suggestion_id
  local proposal_id
  case "$phase" in
    approve_absent)
      suggestion_id="31600000-0000-4000-8000-000000000030"
      ;;
    approve_disabled)
      suggestion_id="31600000-0000-4000-8000-000000000040"
      ;;
    approve_case_budget)
      suggestion_id="31600000-0000-4000-8000-000000000050"
      ;;
    approve_max_depth)
      suggestion_id="31600000-0000-4000-8000-000000000060"
      ;;
    approve_happy)
      suggestion_id="31600000-0000-4000-8000-000000000070"
      ;;
    approve_stale_case)
      suggestion_id="31600000-0000-4000-8000-000000000080"
      ;;
    *)
      echo "unknown R6c approval phase: $phase" >&2
      return 1
      ;;
  esac
  proposal_id="$(r6c_hypothesis_proposal_id "$phase")"

  local reason="TEST_FIXTURE_ONLY ${phase} acceptance"
  local draft
  draft="$(
    docker exec "$container" psql -At -v ON_ERROR_STOP=1 \
      -U postgres -d "$database" -c "
        SELECT jsonb_build_object(
          'kind','HYPOTHESIS',
          'target',jsonb_build_object(
            'type','CASE','id',current_case.id,
            'version',current_case.version,
            'digest',btrim(suggestion.input_snapshot_sha256)
          ),
          'objectScopeDigest',encode(extensions.digest(
            convert_to(current_case.id::text,'UTF8'),'sha256'
          ),'hex'),
          'contentDigest',btrim(suggestion.payload_sha256),
          'proposal',suggestion.payload
        )::text
        FROM ops.agent_suggestions AS suggestion
        JOIN editorial.cases AS current_case
          ON current_case.id=suggestion.case_id
        WHERE suggestion.id='${suggestion_id}'::uuid
          AND suggestion.status='PENDING'
          AND suggestion.version=1"
  )"
  if [[ -z "$draft" ]]; then
    echo "R6c approval draft authority missing: $phase" >&2
    return 1
  fi

  local rationale_json
  local payload_encrypted
  local rationale_encrypted
  local payload_encrypted_base64
  local rationale_encrypted_base64
  rationale_json="$(jq -cn --arg reason "$reason" '$reason')"
  payload_encrypted="$(
    encrypt ops.action_proposal_versions payload_encrypted \
      "$proposal_id" json "$draft"
  )"
  rationale_encrypted="$(
    encrypt ops.action_proposal_versions rationale_encrypted \
      "$proposal_id" json "$rationale_json"
  )"
  payload_encrypted_base64="$(printf '%s' "$payload_encrypted" | base64 -w0)"
  rationale_encrypted_base64="$(printf '%s' "$rationale_encrypted" | base64 -w0)"
  r6c_recursion_phase "$phase" \
    -v "r6c_payload_encrypted_base64=$payload_encrypted_base64" \
    -v "r6c_rationale_encrypted_base64=$rationale_encrypted_base64"
}

r6c_recursion_receipt_exists() {
  local proposal_id="$1"
  docker exec "$container" psql -At -v ON_ERROR_STOP=1 \
    -U postgres -d "$database" -c "
      SELECT CASE WHEN EXISTS (
        SELECT 1
        FROM ops.execution_authorizations AS execution_authorization
        JOIN ops.hypothesis_recursion_receipts AS receipt
          ON receipt.trigger_kind='ACTION_EXECUTION'
         AND receipt.trigger_id=execution_authorization.execution_id
         AND receipt.trigger_generation=execution_authorization.generation
        WHERE execution_authorization.proposal_id='${proposal_id}'::uuid
          AND execution_authorization.proposal_version=1
          AND execution_authorization.generation=1
      ) THEN 1 ELSE 0 END"
}

r6c_recursion_drain_diagnostics() {
  local proposal_id="$1"
  docker exec "$container" psql -v ON_ERROR_STOP=1 \
    -U postgres -d "$database" -c "
      SELECT execution_authorization.proposal_id,
             execution_authorization.execution_id,
             execution_authorization.generation,
             effect.state AS effect_state,
             effect.current_generation,
             receipt.disposition AS recursion_disposition
      FROM ops.execution_authorizations AS execution_authorization
      LEFT JOIN ops.in_flight_effects AS effect
        ON effect.id=execution_authorization.execution_id
      LEFT JOIN ops.hypothesis_recursion_receipts AS receipt
        ON receipt.trigger_kind='ACTION_EXECUTION'
       AND receipt.trigger_id=execution_authorization.execution_id
       AND receipt.trigger_generation=execution_authorization.generation
      WHERE execution_authorization.proposal_id='${proposal_id}'::uuid;
      SELECT job.id,job.priority,job.created_at,job.status,
             job.payload->>'eventType' AS event_type,
             job.payload->>'aggregateId' AS aggregate_id,
             job.attempt_count,job.last_error_code,job.last_error_detail,
             attempt.outcome AS attempt_outcome,
             attempt.error_code AS attempt_error_code,
             attempt.error_detail AS attempt_error_detail
      FROM ops.jobs AS job
      LEFT JOIN ops.job_attempts AS attempt
        ON attempt.job_id=job.id
       AND attempt.attempt=job.attempt_count
      WHERE job.queue='workflow-worker'
        AND job.status<>'SUCCEEDED'
      ORDER BY job.priority,job.created_at,job.id;" >&2
}

r6c_drain_hypothesis_root() {
  local approval_phase="$1"
  local proposal_id
  local queue_state
  local queued
  local target_position
  local max_attempts
  local attempt
  proposal_id="$(r6c_hypothesis_proposal_id "$approval_phase")"

  # One scheduler pass dispatches every currently undispatched event.  Earlier
  # agent completion events legitimately precede the new authorization in the
  # workflow queue, so a fixed number of WORKFLOW_ONCE calls is not a valid
  # completion oracle.  Measure that closed queue and drain only until the
  # exact authorization's immutable recursion receipt exists.
  run_r6b2_scheduler
  queue_state="$(
    docker exec "$container" psql -At -F '|' -v ON_ERROR_STOP=1 \
      -U postgres -d "$database" -c "
        WITH target AS (
          SELECT execution_id
          FROM ops.execution_authorizations
          WHERE proposal_id='${proposal_id}'::uuid
            AND proposal_version=1
            AND generation=1
        ), ordered AS (
          SELECT job.payload,
                 row_number() OVER (
                   ORDER BY job.priority,job.created_at,job.id
                 ) AS position
          FROM ops.jobs AS job
          WHERE job.queue='workflow-worker'
            AND job.status='QUEUED'
            AND job.run_after<=clock_timestamp()
        )
        SELECT count(*),coalesce(min(ordered.position) FILTER (
          WHERE ordered.payload->>'eventType'='action.execution_authorized.v1'
            AND ordered.payload->>'aggregateId'=(
              SELECT target.execution_id::text FROM target
            )
        ),0)
        FROM ordered"
  )"
  IFS='|' read -r queued target_position <<<"$queue_state"
  if [[ "$target_position" -eq 0 ]]; then
    echo "R6c authorization delivery missing: phase=$approval_phase queued=$queued" >&2
    r6c_recursion_drain_diagnostics "$proposal_id"
    return 1
  fi
  echo "R6c recursion queue: phase=$approval_phase queued=$queued target_position=$target_position"

  # The measured queue includes the authorization delivery.  Its executor can
  # add one completion delivery; three extra iterations cover scheduler
  # dispatch and the exact receipt check without an unbounded poll or sleep.
  max_attempts=$((queued + 3))
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if [[ "$(r6c_recursion_receipt_exists "$proposal_id")" == "1" ]]; then
      return 0
    fi
    run_r6b2_workflow
    run_r6b2_scheduler
  done

  if [[ "$(r6c_recursion_receipt_exists "$proposal_id")" == "1" ]]; then
    return 0
  fi
  echo "R6c recursion receipt not produced within measured bound: phase=$approval_phase attempts=$max_attempts" >&2
  r6c_recursion_drain_diagnostics "$proposal_id"
  return 1
}

r6c_run_approved_hypothesis_to_root() {
  local approval_phase="$1"
  local verify_phase="$2"

  r6c_approve_hypothesis "$approval_phase"
  r6c_drain_hypothesis_root "$approval_phase"
  r6c_recursion_phase "$verify_phase"
}

r6c_complete_stage_and_reconcile() {
  local completion_phase="$1"
  local verify_phase="$2"

  r6c_recursion_phase "$completion_phase"
  run_r6b2_scheduler
  run_r6b2_workflow
  r6c_recursion_phase "$verify_phase"
}

r6c_recursion_phase setup

r6c_run_approved_hypothesis_to_root approve_absent verify_absent

r6c_recursion_phase policy_disabled
r6c_run_approved_hypothesis_to_root approve_disabled verify_disabled

r6c_recursion_phase policy_case_budget
r6c_run_approved_hypothesis_to_root \
  approve_case_budget verify_case_budget

r6c_recursion_phase policy_max_depth
r6c_run_approved_hypothesis_to_root \
  approve_max_depth verify_max_depth_root
r6c_complete_stage_and_reconcile \
  complete_market_max_depth verify_max_depth

r6c_recursion_phase policy_happy
r6c_run_approved_hypothesis_to_root approve_happy verify_happy_root

# Requeue the original workflow EVENT_DELIVERY job with the same producer job
# identity and reset only its inbox processing marker.  This is a real exact
# redelivery, not a second synthetic event or a duplicate plan seed.
r6c_recursion_phase prepare_exact_redelivery
run_r6b2_workflow
r6c_recursion_phase verify_exact_redelivery

r6c_recursion_phase complete_market_happy
run_r6b2_scheduler
run_r6b2_workflow
r6c_complete_stage_and_reconcile \
  complete_skeptic_happy verify_happy
r6c_approve_hypothesis approve_stale_case
r6c_recursion_phase verify_stale_case_version
r6c_recursion_phase final_verify

# R6c test-only rule oracle transport.  Each positive input comes verbatim
# from the independently pinned JSONL oracle.  The paired production-shaped
# input changes only the source-availability bit that keeps the rule inactive
# until its declared connector authority exists.  These DRAFT versions are
# confined to the disposable database; there is no migration or operational
# activation seed.
r6c_enqueue_rule_case() {
  local case_ordinal="$1"
  local rule_id="$2"
  local case_kind="$3"
  local input_json="$4"
  local expected_json="$5"
  local rule_version_id="31400000-0000-4000-8000-0000000001${case_ordinal}"
  local evaluation_id="31400000-0000-4000-8000-0000000002${case_ordinal}"
  local dataset_snapshot_id="31400000-0000-4000-8000-0000000003${case_ordinal}"
  local job_id="31400000-0000-4000-8000-0000000004${case_ordinal}"
  local input_sha256
  local result_preimage
  local result_preimage_sha256
  local result_digest

  input_sha256="$(printf '%s' "$input_json" | sha256sum | cut -d' ' -f1)"
  result_preimage="$(jq -cS 'del(.result_hash)' <<<"$expected_json")"
  result_preimage_sha256="$(
    printf '%s' "$result_preimage" | sha256sum | cut -d' ' -f1
  )"
  result_digest="$(printf '%s' "$expected_json" | sha256sum | cut -d' ' -f1)"
  if [[ "$(jq -r '.input_hash' <<<"$expected_json")" != "$input_sha256" ]] \
    || [[ "$(jq -r '.result_hash' <<<"$expected_json")" != "$result_preimage_sha256" ]]; then
    echo "R6c rule oracle canonical digest mismatch: $rule_id/$case_kind" >&2
    return 1
  fi

  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
    -d "$database" -v rule_version_id="$rule_version_id" \
    -v evaluation_id="$evaluation_id" \
    -v dataset_snapshot_id="$dataset_snapshot_id" -v job_id="$job_id" \
    -v rule_id="$rule_id" -v case_kind="$case_kind" \
    -v input_json="$input_json" -v expected_json="$expected_json" \
    -v result_digest="$result_digest" <<'SQL' >/dev/null
INSERT INTO core.rule_versions(
  id,rule_id,version,name,description,configuration,code_digest,status,
  created_by
) VALUES (
  :'rule_version_id',:'rule_id','r6c-runtime-' || :'case_kind',
  'R6c runtime ' || :'rule_id' || ' ' || :'case_kind',
  'TEST_FIXTURE_ONLY: no operational activation seed',
  jsonb_build_object(
    'evaluationInput',:'input_json'::jsonb,
    'runtimeExpected',:'expected_json'::jsonb,
    'runtimeResultDigest',:'result_digest',
    'fixtureAuthority','TEST_FIXTURE_ONLY','severity','HIGH'
  ),repeat('c',64),'DRAFT','31000000-0000-4000-8000-000000000001'
);
INSERT INTO core.rule_evaluations(
  id,rule_version_id,dataset_snapshot_id,evaluation_profile,status,
  requested_by,reason,requester_type,requester_service
) VALUES (
  :'evaluation_id',:'rule_version_id',:'dataset_snapshot_id','REGRESSION',
  'QUEUED','31000000-0000-4000-8000-000000000001',
  'TEST_FIXTURE_ONLY R6c ' || :'case_kind','USER',NULL
);
INSERT INTO ops.jobs(
  id,job_type,queue,status,priority,payload,dedupe_key,max_attempts
) VALUES (
  :'job_id','RULE_EVALUATION','analysis-worker','QUEUED',1,
  jsonb_build_object('evaluationId',:'evaluation_id'),
  'r6c-rule-runtime:' || :'evaluation_id',1
);
SQL
}

r6c_blocked_result() {
  local input_json="$1"
  local blocker="$2"
  local input_sha256
  local result_without_digest
  local result_sha256
  input_sha256="$(printf '%s' "$input_json" | sha256sum | cut -d' ' -f1)"
  result_without_digest="$(
    jq -cnS --arg blocker "$blocker" --arg input_sha256 "$input_sha256" \
      '{blockers:[$blocker],excluded_ids:[],included_ids:[],input_hash:$input_sha256,metrics:{},outcome:"BLOCKED"}'
  )"
  result_sha256="$(
    printf '%s' "$result_without_digest" | sha256sum | cut -d' ' -f1
  )"
  jq -cS --arg result_sha256 "$result_sha256" \
    '. + {result_hash:$result_sha256}' <<<"$result_without_digest"
}

r6c_rule_case_ordinal=01
for r6c_rule_id in \
  OFFICER_OVERLAP_AWARD OWNERSHIP_LINKED_COMPETITORS BID_ROTATION \
  REVOLVING_DOOR_CONTRACT SANCTIONED_SUCCESSOR; do
  r6c_rule_slug="$(tr '[:upper:]' '[:lower:]' <<<"$r6c_rule_id")"
  r6c_oracle_file="specs/detection/evals/${r6c_rule_slug}.jsonl"
  r6c_positive="$(jq -sc 'map(select(.kind=="positive"))[0]' "$r6c_oracle_file")"
  r6c_positive_input="$(jq -cS '.input' <<<"$r6c_positive")"
  r6c_positive_expected="$(jq -cS '.expected' <<<"$r6c_positive")"
  r6c_enqueue_rule_case \
    "$r6c_rule_case_ordinal" "$r6c_rule_id" positive \
    "$r6c_positive_input" "$r6c_positive_expected"
  r6c_rule_case_ordinal="$(printf '%02d' "$((10#$r6c_rule_case_ordinal + 1))")"

  case "$r6c_rule_id" in
    OFFICER_OVERLAP_AWARD)
      r6c_blocker='SOURCE_COVERAGE_INCOMPLETE'
      r6c_blocked_input="$(
        jq -cS '.input.source_coverage.dart_officer_assignments_complete=false | .input' \
          <<<"$r6c_positive"
      )"
      ;;
    OWNERSHIP_LINKED_COMPETITORS)
      r6c_blocker='STRUCTURED_BIDDER_SOURCE_UNAVAILABLE'
      r6c_blocked_input="$(
        jq -cS '.input.procurement.structured_participant_source.status="UNAVAILABLE" | .input' \
          <<<"$r6c_positive"
      )"
      ;;
    BID_ROTATION)
      r6c_blocker='STRUCTURED_PARTICIPANT_SOURCE_UNAVAILABLE'
      r6c_blocked_input="$(
        jq -cS '.input.participant_source.status="UNAVAILABLE" | .input' \
          <<<"$r6c_positive"
      )"
      ;;
    REVOLVING_DOOR_CONTRACT)
      r6c_blocker='OFFICIAL_REEMPLOYMENT_SOURCE_UNAVAILABLE'
      r6c_blocked_input="$(
        jq -cS '.input.source_coverage.official_reemployment_source_available=false | .input' \
          <<<"$r6c_positive"
      )"
      ;;
    SANCTIONED_SUCCESSOR)
      r6c_blocker='SANCTION_SOURCE_NOT_READY'
      r6c_blocked_input="$(
        jq -cS '.input.sanction_source_status="DISABLED" | .input' \
          <<<"$r6c_positive"
      )"
      ;;
  esac
  r6c_blocked_expected="$(
    r6c_blocked_result "$r6c_blocked_input" "$r6c_blocker"
  )"
  r6c_enqueue_rule_case \
    "$r6c_rule_case_ordinal" "$r6c_rule_id" production-blocked \
    "$r6c_blocked_input" "$r6c_blocked_expected"
  r6c_rule_case_ordinal="$(printf '%02d' "$((10#$r6c_rule_case_ordinal + 1))")"
done

# ANALYSIS_ONCE drains the currently runnable queue.  The D1 sensitivity job is
# deliberately created only after this loop, so this invocation has exactly
# the ten priority-1 R6c oracle jobs available to claim.
for _ in $(seq 1 12); do
  r6c_rule_jobs_remaining="$(
    docker exec "$container" psql -At -v ON_ERROR_STOP=1 -U postgres \
      -d "$database" -c \
      "SELECT count(*) FROM ops.jobs WHERE dedupe_key LIKE 'r6c-rule-runtime:%' AND status IN ('QUEUED','LEASED','RUNNING')"
  )"
  [[ "$r6c_rule_jobs_remaining" == 0 ]] && break
  run_r6b2_analysis
done
if [[ "$r6c_rule_jobs_remaining" != 0 ]]; then
  echo "R6c rule runtime jobs did not drain: $r6c_rule_jobs_remaining" >&2
  exit 1
fi

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE
  v_evaluation_count bigint;
BEGIN
  SELECT count(*) INTO v_evaluation_count
  FROM core.rule_evaluations AS evaluation
  JOIN core.rule_versions AS rule ON rule.id=evaluation.rule_version_id
  JOIN ops.jobs AS job
    ON job.payload->>'evaluationId'=evaluation.id::text
   AND job.dedupe_key='r6c-rule-runtime:' || evaluation.id::text
  JOIN ops.job_attempts AS attempt ON attempt.job_id=job.id
  JOIN core.rule_runs AS run
    ON run.run_key='evaluation:' || evaluation.id::text
  WHERE rule.description='TEST_FIXTURE_ONLY: no operational activation seed'
    AND rule.status='DRAFT'
    AND rule.configuration->>'fixtureAuthority'='TEST_FIXTURE_ONLY'
    AND evaluation.status='SUCCEEDED'
    AND evaluation.result_payload=rule.configuration->'runtimeExpected'
    AND btrim(evaluation.result_digest::text)
      =rule.configuration->>'runtimeResultDigest'
    AND btrim(run.input_digest::text)
      =rule.configuration#>>'{runtimeExpected,input_hash}'
    AND run.status='SUCCEEDED' AND run.record_count=1
    AND job.status='SUCCEEDED' AND job.last_error_code IS NULL
    AND attempt.outcome='SUCCEEDED'
    AND attempt.metrics->>'resultDigest'
      =rule.configuration->>'runtimeResultDigest';
  IF v_evaluation_count <> 10
     OR (SELECT count(*) FROM core.rule_evaluations AS evaluation
         JOIN core.rule_versions AS rule ON rule.id=evaluation.rule_version_id
         WHERE rule.description='TEST_FIXTURE_ONLY: no operational activation seed') <> 10
     OR (SELECT count(*) FROM core.rule_evaluations AS evaluation
         JOIN core.rule_versions AS rule ON rule.id=evaluation.rule_version_id
         WHERE rule.description='TEST_FIXTURE_ONLY: no operational activation seed'
           AND evaluation.result_payload->>'outcome'='SIGNAL') <> 5
     OR (SELECT count(*) FROM core.rule_evaluations AS evaluation
         JOIN core.rule_versions AS rule ON rule.id=evaluation.rule_version_id
         WHERE rule.description='TEST_FIXTURE_ONLY: no operational activation seed'
           AND evaluation.result_payload->>'outcome'='BLOCKED') <> 5
     OR EXISTS (
       SELECT 1 FROM core.rule_versions AS rule
       WHERE rule.description='TEST_FIXTURE_ONLY: no operational activation seed'
         AND rule.status='ACTIVE'
     ) THEN
    RAISE EXCEPTION
      'R6c rule runtime oracle/blocked proof invalid: valid %',
      v_evaluation_count;
  END IF;
END $$;
SQL

r6b2_d1_sensitivity_proof

# The source.fetch review-tier proof depends on the canonical Control runtime
# and research fixtures.  Load those only after every broad queue/drain count
# above has completed: these seeds intentionally add durable control rows, but
# this disposable database is removed on exit and the R6c proof itself rolls
# its promotion transaction back.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" < db/test-fixtures/reference-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" < db/test-fixtures/control-runtime-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" < db/test-fixtures/control-research-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" < db/test-fixtures/r6c-source-fetch-tier-runtime.sql \
  >/dev/null

echo "workflow/notification runtime, R6b2 pipeline, R6c typed graph v3, hypothesis recursion, source.fetch review tier, rule oracle/blocked paths, R6d privacy receipt/transition/notification, PERSON/entity retention, and public entity anonymization: PASS"
