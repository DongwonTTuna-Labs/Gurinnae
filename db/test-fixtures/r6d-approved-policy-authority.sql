-- TEST_ONLY deterministic D6 retention governance fixtures.
--
-- This file is intended to replace the SQL body currently embedded at
-- scripts/test-event-consumers-runtime.sh:102-789.  It deliberately writes
-- only to a disposable test database.  Every stored digest below has a named
-- canonical preimage, both human quorum slots are backed by real role and
-- capability rows, and the execution graph contains the mandatory queued
-- authorization receipt, attempt, and terminal receipt chain.

BEGIN;

-- Fail closed if this authority fixture is sourced outside one of its three
-- disposable runtime databases.  The policy rows below are deliberately real
-- enough to exercise owner functions, so a TEST_ONLY comment alone is not a
-- sufficient production boundary.
DO $fixture_database_guard$
BEGIN
  IF current_database() NOT IN (
    'gurine_control_test',
    'gurine_submission_test',
    'gurine_event_consumers'
  ) THEN
    RAISE EXCEPTION 'r6d_test_policy_fixture_database_forbidden'
      USING ERRCODE='55000';
  END IF;
END
$fixture_database_guard$;

SET CONSTRAINTS ALL DEFERRED;
SET LOCAL TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.r6d_sha256_json(p_value jsonb)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT encode(
    extensions.digest(ops.canonical_jsonb_v1(p_value),'sha256'),'hex'
  )::char(64)
$$;

CREATE FUNCTION pg_temp.r6d_sha256_text(p_value text)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT encode(
    extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex'
  )::char(64)
$$;

CREATE FUNCTION pg_temp.r6d_fixture_uuid(
  p_record_class text,
  p_label text
) RETURNS uuid
LANGUAGE sql
IMMUTABLE
AS $$
  WITH hashed(value) AS (
    SELECT encode(extensions.digest(convert_to(
      'r6d-approved-policy-authority:'||p_record_class||':'||p_label,
      'UTF8'
    ),'sha256'),'hex')
  )
  SELECT (
    substr(value,1,8)||'-'||substr(value,9,4)||'-4'||substr(value,14,3)
    ||'-a'||substr(value,18,3)||'-'||substr(value,21,12)
  )::uuid
  FROM hashed
$$;

-- Deterministic counterpart of ops.append_audit_event for this disposable
-- fixture.  It preserves the production hash-chain preimage and lock order,
-- but receives the otherwise random UUID and clock value as fixed inputs.
CREATE FUNCTION pg_temp.r6d_append_fixed_audit_event(
  p_id uuid,
  p_occurred_at timestamptz,
  p_stream_key text,
  p_actor_type text,
  p_actor_id text,
  p_action text,
  p_object_type text,
  p_object_id text,
  p_capability text,
  p_request_id uuid,
  p_details jsonb
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_previous_hash char(64);
  v_event_hash char(64);
  v_canonical text;
BEGIN
  IF p_stream_key !~ '^[a-z0-9][a-z0-9._:-]{0,199}$' THEN
    RAISE EXCEPTION 'r6d_fixed_audit_stream_key_invalid';
  END IF;

  INSERT INTO ops.audit_chain_heads(
    stream_key,head_event_id,head_hash,version,updated_at
  ) VALUES (p_stream_key,NULL,NULL,0,p_occurred_at)
  ON CONFLICT (stream_key) DO NOTHING;

  SELECT head_hash INTO v_previous_hash
  FROM ops.audit_chain_heads
  WHERE stream_key=p_stream_key
  FOR UPDATE;

  v_canonical := jsonb_build_object(
    'id',p_id,
    'stream_key',p_stream_key,
    'occurred_at',p_occurred_at,
    'actor_type',p_actor_type,
    'actor_id',p_actor_id,
    'session_id',NULL,
    'action',p_action,
    'object_type',p_object_type,
    'object_id',p_object_id,
    'capability',p_capability,
    'outcome','SUCCESS'::ops.audit_outcome,
    'reason',NULL,
    'request_id',p_request_id,
    'details',p_details,
    'previous_event_hash',v_previous_hash
  )::text;
  v_event_hash := pg_temp.r6d_sha256_text(
    COALESCE(v_previous_hash,'')||v_canonical
  );

  INSERT INTO ops.audit_events(
    id,occurred_at,actor_type,actor_id,session_id,action,object_type,
    object_id,capability,outcome,reason,request_id,details,
    previous_event_hash,event_hash
  ) VALUES (
    p_id,p_occurred_at,p_actor_type,p_actor_id,NULL,p_action,p_object_type,
    p_object_id,p_capability,'SUCCESS',NULL,p_request_id,p_details,
    v_previous_hash,v_event_hash
  );

  UPDATE ops.audit_chain_heads
  SET head_event_id=p_id,
      head_hash=v_event_hash,
      version=version+1,
      updated_at=p_occurred_at
  WHERE stream_key=p_stream_key;
END
$$;

-- RETENTION_SCHEDULE is an active authority capability.  The production seed
-- currently omits it, so the disposable fixture installs the spec-declared
-- capability and binds it to the exact two allowed system roles.  Both roles
-- already carry actions.review, the Actor Assertion capability required by
-- submitActionDecision.
INSERT INTO ops.capabilities(code,description,risk_level) VALUES (
  'retention.policy.manage',
  'Manage action-approved record-class retention policy revisions',
  'CRITICAL'
) ON CONFLICT (code) DO UPDATE SET
  description=EXCLUDED.description,
  risk_level=EXCLUDED.risk_level;

INSERT INTO ops.role_capabilities(role_id,capability_code)
SELECT role.id,'retention.policy.manage'
FROM ops.roles AS role
WHERE role.code IN ('LEGAL_REVIEWER','OPERATIONS')
ON CONFLICT DO NOTHING;

INSERT INTO ops.users(
  id,oidc_subject,email,display_name,status,created_at,updated_at
) VALUES
(
  '31400000-0000-4000-8000-000000000001',
  'r6d-retention-owner','r6d-retention-owner@example.test',
  'R6d retention owner','ACTIVE',
  '2025-12-01 00:00:00+00','2025-12-01 00:00:00+00'
),
(
  '31400000-0000-4000-8000-000000000002',
  'r6d-retention-operations','r6d-retention-operations@example.test',
  'R6d operations reviewer','ACTIVE',
  '2025-12-01 00:00:00+00','2025-12-01 00:00:00+00'
),
(
  '31400000-0000-4000-8000-000000000003',
  'r6d-retention-legal','r6d-retention-legal@example.test',
  'R6d legal reviewer','ACTIVE',
  '2025-12-01 00:00:00+00','2025-12-01 00:00:00+00'
);

INSERT INTO ops.user_roles(
  id,user_id,role_id,granted_by,reason,granted_at,
  expires_at,revoked_at,revoked_by
)
SELECT fixture.id,fixture.user_id,role.id,
       '31400000-0000-4000-8000-000000000001',
       'TEST_ONLY deterministic retention approval fixture',
       '2025-12-01 00:01:00+00',NULL,NULL,NULL
FROM (VALUES
  ('31400000-0000-4000-8000-000000000011'::uuid,
   '31400000-0000-4000-8000-000000000001'::uuid,'OPERATIONS'),
  ('31400000-0000-4000-8000-000000000012'::uuid,
   '31400000-0000-4000-8000-000000000002'::uuid,'OPERATIONS'),
  ('31400000-0000-4000-8000-000000000013'::uuid,
   '31400000-0000-4000-8000-000000000003'::uuid,'LEGAL_REVIEWER')
) AS fixture(id,user_id,role_code)
JOIN ops.roles AS role ON role.code=fixture.role_code;

-- Fixed reviewer sessions are the parent records for the four bounded step-up
-- authorizations materialized by the two proposal cycles.
INSERT INTO ops.sessions(
  id,user_id,session_token_hash,oidc_session_id,auth_time,step_up_at,
  expires_at,revoked_at,ip_hash,user_agent_hash,created_at,
  csrf_token_hash,csrf_rotated_at
) VALUES
(
  '31400000-0000-4000-8000-000000000021',
  '31400000-0000-4000-8000-000000000002',
  pg_temp.r6d_sha256_text('r6d-operations-session-token'),
  'r6d-operations-oidc-session','2025-12-01 00:02:00+00',
  '2026-01-01 00:05:59+00','2099-01-01 00:00:00+00',NULL,
  pg_temp.r6d_sha256_text('r6d-operations-ip'),
  pg_temp.r6d_sha256_text('r6d-operations-user-agent'),
  '2025-12-01 00:02:00+00',
  pg_temp.r6d_sha256_text('r6d-operations-csrf'),
  '2025-12-01 00:02:00+00'
),
(
  '31400000-0000-4000-8000-000000000022',
  '31400000-0000-4000-8000-000000000003',
  pg_temp.r6d_sha256_text('r6d-legal-session-token'),
  'r6d-legal-oidc-session','2025-12-01 00:02:00+00',
  '2026-01-01 00:06:59+00','2099-01-01 00:00:00+00',NULL,
  pg_temp.r6d_sha256_text('r6d-legal-ip'),
  pg_temp.r6d_sha256_text('r6d-legal-user-agent'),
  '2025-12-01 00:02:00+00',
  pg_temp.r6d_sha256_text('r6d-legal-csrf'),
  '2025-12-01 00:02:00+00'
);

CREATE FUNCTION pg_temp.install_r6d_retention_fixture(
  p_record_class text,
  p_ordinal integer
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_cycle_start timestamptz :=
    timestamptz '2026-01-01 00:00:00+00'
    + (p_ordinal-1)*interval '1 day';
  v_created_at timestamptz := v_cycle_start;
  v_previewed_at timestamptz := v_cycle_start+interval '1 minute';
  v_submitted_at timestamptz := v_cycle_start+interval '2 minutes';
  v_operations_claimed_at timestamptz :=
    v_cycle_start+interval '3 minutes';
  v_legal_claimed_at timestamptz := v_cycle_start+interval '4 minutes';
  v_operations_decided_at timestamptz :=
    v_cycle_start+interval '6 minutes';
  v_legal_decided_at timestamptz :=
    v_cycle_start+interval '7 minutes';
  v_authorized_at timestamptz := v_legal_decided_at;
  v_succeeded_at timestamptz := v_cycle_start+interval '8 minutes';
  v_effective_at timestamptz := v_cycle_start+interval '10 minutes';
  v_due_at timestamptz := v_cycle_start+interval '1 day';
  v_proposal_expires_at timestamptz := v_cycle_start+interval '7 days';
  v_review_expires_at constant timestamptz :=
    '2099-01-01 00:00:00+00';
  v_creator constant uuid := '31400000-0000-4000-8000-000000000001';
  v_operations_reviewer constant uuid :=
    '31400000-0000-4000-8000-000000000002';
  v_legal_reviewer constant uuid :=
    '31400000-0000-4000-8000-000000000003';
  v_operations_session constant uuid :=
    '31400000-0000-4000-8000-000000000021';
  v_legal_session constant uuid :=
    '31400000-0000-4000-8000-000000000022';
  v_proposal uuid;
  v_operations_assignment uuid;
  v_legal_assignment uuid;
  v_operations_decision uuid;
  v_legal_decision uuid;
  v_effect uuid;
  v_authorization uuid;
  v_queued_receipt uuid;
  v_terminal_receipt uuid;
  v_attempt uuid;
  v_schedule uuid;
  v_operations_conflict uuid;
  v_legal_conflict uuid;
  v_authorized_outbox uuid;
  v_completed_outbox uuid;
  v_schedule_outbox uuid;
  v_request_id uuid;
  v_preview_id uuid;
  v_preview_audit uuid;
  v_operations_audit uuid;
  v_legal_audit uuid;
  v_authorization_audit uuid;
  v_execution_audit uuid;
  v_operations_step_up uuid;
  v_legal_step_up uuid;
  v_operations_assertion_jti uuid;
  v_legal_assertion_jti uuid;
  v_stream_key text;
  v_owner_team constant text := 'trust-ops';
  v_purpose text :=
    'TEST_ONLY approved retention fixture for '||p_record_class;
  v_lawful_basis text;
  v_trigger_kind text;
  v_active_duration_seconds bigint;
  v_backup_duration_seconds bigint;
  v_terminal_action text;
  v_hold_behavior text;
  v_restore_suppression_behavior text;
  v_active_duration text;
  v_backup_duration text;
  v_operations_reason constant text :=
    'TEST_ONLY operations owner approved the exact retention preview';
  v_legal_reason constant text :=
    'TEST_ONLY legal owner approved the exact retention preview';
  v_payload_encrypted bytea;
  v_rationale_encrypted bytea;
  v_origin jsonb;
  v_origin_digest char(64);
  v_target jsonb;
  v_target_digest char(64);
  v_object_scope jsonb;
  v_object_scope_digest char(64);
  v_rationale jsonb;
  v_rationale_digest char(64);
  v_target_request jsonb;
  v_target_request_canonical bytea;
  v_target_request_digest char(64);
  v_current_schedule_binding jsonb;
  v_current_schedule_digest char(64);
  v_purpose_digest char(64);
  v_lawful_basis_digest char(64);
  v_location_set jsonb;
  v_location_set_digest char(64);
  v_current_legal_hold_set jsonb;
  v_current_legal_hold_set_digest char(64);
  v_lawful_basis_review jsonb;
  v_lawful_basis_review_digest char(64);
  v_policy_snapshot jsonb;
  v_policy_digest char(64);
  v_action_detail jsonb;
  v_action_detail_binding jsonb;
  v_action_detail_canonical bytea;
  v_action_detail_digest char(64);
  v_approval_subject jsonb;
  v_approval_subject_digest char(64);
  v_evidence_set_digest char(64);
  v_contrary_evidence_set_digest char(64);
  v_uncertainty_set_digest char(64);
  v_risk_assessment_digest char(64);
  v_conflict_policy_digest char(64);
  v_expected_effect_digest char(64);
  v_quorum_plan jsonb;
  v_quorum_plan_digest char(64);
  v_effect_idempotency_digest char(64);
  v_approval_binding jsonb;
  v_approval_binding_canonical bytea;
  v_approval_digest char(64);
  v_operations_role_snapshot_digest char(64);
  v_legal_role_snapshot_digest char(64);
  v_operations_eligibility_digest char(64);
  v_legal_eligibility_digest char(64);
  v_exclusion_set_digest char(64);
  v_declaration_set_digest char(64);
  v_finding_set_digest char(64);
  v_authorship_digest char(64);
  v_party_recipient_digest char(64);
  v_relationship_digest char(64);
  v_funding_customer_digest char(64);
  v_operations_conflict_digest char(64);
  v_legal_conflict_digest char(64);
  v_operations_conflict_receipt_digest char(64);
  v_legal_conflict_receipt_digest char(64);
  v_operations_assignment_digest char(64);
  v_legal_assignment_digest char(64);
  v_operations_step_up_action jsonb;
  v_legal_step_up_action jsonb;
  v_operations_step_up_action_digest char(64);
  v_legal_step_up_action_digest char(64);
  v_operations_idempotency_digest char(64);
  v_legal_idempotency_digest char(64);
  v_operations_step_up_receipt jsonb;
  v_legal_step_up_receipt jsonb;
  v_operations_step_up_receipt_canonical bytea;
  v_legal_step_up_receipt_canonical bytea;
  v_operations_step_up_receipt_digest char(64);
  v_legal_step_up_receipt_digest char(64);
  v_operations_decision_payload jsonb;
  v_legal_decision_payload jsonb;
  v_operations_decision_payload_canonical bytea;
  v_legal_decision_payload_canonical bytea;
  v_operations_quorum_snapshot_digest char(64);
  v_legal_quorum_snapshot_digest char(64);
  v_operations_decision_receipt jsonb;
  v_legal_decision_receipt jsonb;
  v_operations_decision_receipt_canonical bytea;
  v_legal_decision_receipt_canonical bytea;
  v_operations_decision_receipt_digest char(64);
  v_legal_decision_receipt_digest char(64);
  v_counted_decision_ids uuid[];
  v_counted_receipt_digests text[];
  v_counted_decision_set_digest char(64);
  v_execution_binding jsonb;
  v_execution_binding_canonical bytea;
  v_execution_digest char(64);
  v_execution_conflict_digest char(64);
  v_kill_switch_digest char(64);
  v_rights_digest char(64);
  v_consent_digest char(64);
  v_suppression_digest char(64);
  v_activation_digest char(64);
  v_execution_proof jsonb;
  v_execution_proof_digest char(64);
  v_empty_downstream_set_digest char(64);
  v_queued_receipt_payload jsonb;
  v_terminal_receipt_payload jsonb;
  v_queued_receipt_canonical bytea;
  v_terminal_receipt_canonical bytea;
  v_queued_receipt_digest char(64);
  v_terminal_receipt_digest char(64);
  v_schedule_binding jsonb;
  v_schedule_digest char(64);
  v_database_only_digest constant char(64) :=
    '8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde';
  v_no_provider_key constant char(64) :=
    '36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74';
  v_no_budget_digest constant char(64) :=
    'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde';
BEGIN
  IF (
       NOT EXISTS (
         SELECT 1 FROM ops.r6d_record_class_catalog AS catalog
         WHERE catalog.record_class=p_record_class
       )
       AND p_record_class NOT IN (
         'AGENT_RUNTIME_POLICY','AGENT_RUNTIME_INITIATION_RECEIPT'
       )
     ) OR p_ordinal NOT BETWEEN 1 AND 99 THEN
    RAISE EXCEPTION 'r6d_retention_fixture_input_invalid';
  END IF;

  IF p_record_class IN (
    'AGENT_RUNTIME_POLICY','AGENT_RUNTIME_INITIATION_RECEIPT'
  ) THEN
    v_trigger_kind:='CREATED_AT';
    v_active_duration_seconds:=31536000;
    v_backup_duration_seconds:=2592000;
    v_terminal_action:='DELETE';
    v_lawful_basis:=
      'TEST_ONLY approved governance and audit-integrity verification';
  ELSE
    SELECT
      COALESCE(catalog.required_trigger_kind,'CREATED_AT'),
      CASE WHEN catalog.required_terminal_action LIKE 'PRESERVE_%'
        THEN NULL
        ELSE COALESCE(catalog.required_active_duration_seconds,31536000)
      END,
      CASE WHEN catalog.required_terminal_action LIKE 'PRESERVE_%'
        THEN NULL
        ELSE COALESCE(catalog.required_backup_duration_seconds,2592000)
      END,
      catalog.required_terminal_action,
      COALESCE(
        catalog.required_lawful_basis,
        'TEST_ONLY approved R6d legal-hardening runtime verification'
      )
    INTO STRICT
      v_trigger_kind,v_active_duration_seconds,v_backup_duration_seconds,
      v_terminal_action,v_lawful_basis
    FROM ops.r6d_record_class_catalog AS catalog
    WHERE catalog.record_class=p_record_class;
  END IF;

  v_hold_behavior:=CASE
    WHEN v_terminal_action LIKE 'PRESERVE_%' THEN 'NOT_DESTRUCTIVE'
    ELSE 'BLOCK_ON_RETENTION'
  END;
  v_restore_suppression_behavior:=CASE
    WHEN v_terminal_action LIKE 'PRESERVE_%' THEN 'NOT_APPLICABLE'
    ELSE 'REAPPLY_BEFORE_ACCESS'
  END;
  v_active_duration:=CASE WHEN v_active_duration_seconds IS NULL THEN NULL
    ELSE 'P'||(v_active_duration_seconds/86400)::text||'D' END;
  v_backup_duration:=CASE WHEN v_backup_duration_seconds IS NULL THEN NULL
    ELSE 'P'||(v_backup_duration_seconds/86400)::text||'D' END;

  v_proposal:=pg_temp.r6d_fixture_uuid(p_record_class,'proposal');
  v_operations_assignment:=pg_temp.r6d_fixture_uuid(p_record_class,'operations-assignment');
  v_legal_assignment:=pg_temp.r6d_fixture_uuid(p_record_class,'legal-assignment');
  v_operations_decision:=pg_temp.r6d_fixture_uuid(p_record_class,'operations-decision');
  v_legal_decision:=pg_temp.r6d_fixture_uuid(p_record_class,'legal-decision');
  v_effect:=pg_temp.r6d_fixture_uuid(p_record_class,'effect');
  v_authorization:=pg_temp.r6d_fixture_uuid(p_record_class,'authorization');
  v_queued_receipt:=pg_temp.r6d_fixture_uuid(p_record_class,'queued-receipt');
  v_schedule:=pg_temp.r6d_fixture_uuid(p_record_class,'schedule');
  v_operations_conflict:=pg_temp.r6d_fixture_uuid(p_record_class,'operations-conflict');
  v_legal_conflict:=pg_temp.r6d_fixture_uuid(p_record_class,'legal-conflict');
  v_authorized_outbox:=pg_temp.r6d_fixture_uuid(p_record_class,'authorized-outbox');
  v_completed_outbox:=pg_temp.r6d_fixture_uuid(p_record_class,'completed-outbox');
  v_request_id:=pg_temp.r6d_fixture_uuid(p_record_class,'request');
  v_preview_id:=pg_temp.r6d_fixture_uuid(p_record_class,'preview');
  v_attempt:=pg_temp.r6d_fixture_uuid(p_record_class,'attempt');
  v_terminal_receipt:=pg_temp.r6d_fixture_uuid(p_record_class,'terminal-receipt');
  v_schedule_outbox:=pg_temp.r6d_fixture_uuid(p_record_class,'schedule-outbox');
  v_preview_audit:=pg_temp.r6d_fixture_uuid(p_record_class,'preview-audit');
  v_operations_audit:=pg_temp.r6d_fixture_uuid(p_record_class,'operations-audit');
  v_legal_audit:=pg_temp.r6d_fixture_uuid(p_record_class,'legal-audit');
  v_authorization_audit:=pg_temp.r6d_fixture_uuid(p_record_class,'authorization-audit');
  v_execution_audit:=pg_temp.r6d_fixture_uuid(p_record_class,'execution-audit');
  v_operations_step_up:=pg_temp.r6d_fixture_uuid(p_record_class,'operations-step-up');
  v_legal_step_up:=pg_temp.r6d_fixture_uuid(p_record_class,'legal-step-up');
  v_operations_assertion_jti:=pg_temp.r6d_fixture_uuid(p_record_class,'operations-assertion');
  v_legal_assertion_jti:=pg_temp.r6d_fixture_uuid(p_record_class,'legal-assertion');
  v_payload_encrypted:=extensions.digest(
    convert_to(p_record_class||':payload:TEST_ONLY','UTF8'),'sha256'
  )||extensions.digest(
    convert_to(p_record_class||':payload:TEST_ONLY','UTF8'),'sha256'
  );
  v_rationale_encrypted:=extensions.digest(
    convert_to(p_record_class||':rationale:TEST_ONLY','UTF8'),'sha256'
  )||extensions.digest(
    convert_to(p_record_class||':rationale:TEST_ONLY','UTF8'),'sha256'
  );
  v_stream_key := 'r6d-retention:'||lower(p_record_class);

  v_origin := jsonb_build_object(
    'kind','HUMAN','actorId',v_creator,'screenId','OPS-RETENTION',
    'reason','TEST_ONLY deterministic runtime retention authority'
  );
  v_origin_digest := pg_temp.r6d_sha256_json(v_origin);
  v_target := jsonb_build_object(
    'targetType','RECORD_CLASS','targetId',p_record_class,'expectedVersion',1
  );
  v_target_digest := pg_temp.r6d_sha256_json(v_target);
  v_object_scope := jsonb_build_object(
    'schemaVersion','action-object-scope.v1','targetType','RECORD_CLASS',
    'recordClasses',jsonb_build_array(p_record_class)
  );
  v_object_scope_digest := pg_temp.r6d_sha256_json(v_object_scope);
  v_rationale := jsonb_build_object(
    'summary','TEST_ONLY deterministic runtime retention authority',
    'evidenceSegmentIds','[]'::jsonb,'unknowns','[]'::jsonb,
    'alternativesConsidered',jsonb_build_array(
      'Fail closed without a current retention schedule'
    ),
    'riskNote','Fixture is scoped to the disposable runtime smoke database'
  );
  v_rationale_digest := pg_temp.r6d_sha256_json(v_rationale);

  v_current_schedule_binding := jsonb_build_object(
    'schemaVersion','current-record-class-schedule-head.v1',
    'recordClass',p_record_class,'revision',0,
    'scheduleId',NULL,'scheduleDigest',NULL
  );
  v_current_schedule_digest :=
    pg_temp.r6d_sha256_json(v_current_schedule_binding);
  v_purpose_digest := pg_temp.r6d_sha256_text(v_purpose);
  v_lawful_basis_digest := pg_temp.r6d_sha256_text(v_lawful_basis);
  v_location_set := jsonb_build_object(
    'schemaVersion','retention-location-set.v1',
    'locations',jsonb_build_array('KR')
  );
  v_location_set_digest := pg_temp.r6d_sha256_json(v_location_set);
  v_current_legal_hold_set := jsonb_build_object(
    'schemaVersion','current-legal-hold-set.v1',
    'recordClass',p_record_class,'holdIds','[]'::jsonb
  );
  v_current_legal_hold_set_digest :=
    pg_temp.r6d_sha256_json(v_current_legal_hold_set);
  v_lawful_basis_review := jsonb_build_object(
    'schemaVersion','lawful-basis-review-artifact.v1',
    'recordClass',p_record_class,
    'lawfulBasisDigest',v_lawful_basis_digest,
    'decision','APPROVED_FOR_TEST','reviewerRole','LEGAL_REVIEWER',
    'reviewedAt',v_cycle_start-interval '1 day'
  );
  v_lawful_basis_review_digest :=
    pg_temp.r6d_sha256_json(v_lawful_basis_review);
  v_policy_snapshot := jsonb_build_object(
    'schemaVersion','record-class-retention-policy.v1',
    'recordClass',p_record_class,'ownerTeam',v_owner_team,
    'purpose',v_purpose,'purposeDigest',v_purpose_digest,
    'lawfulBasis',v_lawful_basis,
    'lawfulBasisDigest',v_lawful_basis_digest,
    'lawfulBasisReviewDigest',v_lawful_basis_review_digest,
    'trigger',v_trigger_kind,
    'activeDurationSeconds',v_active_duration_seconds,
    'backupDurationSeconds',v_backup_duration_seconds,
    'locationCodes',jsonb_build_array('KR'),
    'locationSetDigest',v_location_set_digest,
    'derivativeRecordClasses','[]'::jsonb,
    'terminalAction',v_terminal_action,
    'holdBehavior',v_hold_behavior,
    'restoreSuppressionBehavior',v_restore_suppression_behavior,
    'effectiveAt',v_effective_at,'reviewExpiresAt',v_review_expires_at
  );
  v_policy_digest := pg_temp.r6d_sha256_json(v_policy_snapshot);

  v_target_request := jsonb_build_object(
    'schemaVersion','action-payload.v1','kind','RETENTION_SCHEDULE',
    'target',v_target,'rationale',v_rationale,
    'effect',jsonb_build_object(
      'effectClass','POLICY_CHANGE','fromState',NULL,
      'toState',jsonb_build_object('aggregate','POLICY_VERSION','state','CURRENT'),
      'externalSideEffect',false,'reversible',true,
      'expectedOutcome','Install one current finite runtime retention schedule'
    ),
    'recordClass',p_record_class,'expectedScheduleRevision',0,
    'purpose',v_purpose,'lawfulBasis',v_lawful_basis,
    'trigger',v_trigger_kind,'activeDuration',v_active_duration,
    'backupDuration',v_backup_duration,'locations',jsonb_build_array('KR'),
    'terminalAction',v_terminal_action,
    'holdBehavior',CASE WHEN v_terminal_action LIKE 'PRESERVE_%'
      THEN 'PRESERVE' ELSE 'PAUSE' END,
    'restoreSuppressionBehavior',CASE
      WHEN v_terminal_action LIKE 'PRESERVE_%'
      THEN 'BLOCK_RESTORE' ELSE 'REAPPLY' END,
    'effectiveAt',v_effective_at,'reviewExpiresAt',v_review_expires_at
  );
  v_target_request_canonical := ops.canonical_jsonb_v1(v_target_request);
  v_target_request_digest := encode(
    extensions.digest(v_target_request_canonical,'sha256'),'hex'
  );

  -- Exact ActionApprovalDetailV1.RETENTION_SCHEDULE branch.  Every field in
  -- the typed child table below is reconstructed from this same object.
  v_action_detail := jsonb_build_object(
    'kind','RETENTION_SCHEDULE','recordClass',p_record_class,
    'expectedScheduleRevision',0,
    'currentScheduleDigest',v_current_schedule_digest,
    'purposeDigest',v_purpose_digest,
    'lawfulBasisDigest',v_lawful_basis_digest,
    'trigger',v_trigger_kind,
    'activeDurationSeconds',v_active_duration_seconds,
    'backupDurationSeconds',v_backup_duration_seconds,
    'locationSetDigest',v_location_set_digest,
    'terminalAction',v_terminal_action,'holdBehavior',v_hold_behavior,
    'restoreSuppressionBehavior',v_restore_suppression_behavior,
    'currentLegalHoldSetDigest',v_current_legal_hold_set_digest,
    'effectiveAt',v_effective_at,'reviewExpiresAt',v_review_expires_at
  );
  v_action_detail_binding := jsonb_build_object(
    'actionDetailKind','RETENTION_SCHEDULE','actionDetail',v_action_detail
  );
  v_action_detail_canonical :=
    ops.canonical_jsonb_v1(v_action_detail_binding);
  v_action_detail_digest := encode(
    extensions.digest(v_action_detail_canonical,'sha256'),'hex'
  );

  v_approval_subject := jsonb_build_object(
    'schemaVersion','action-approval-subject-view.v1',
    'proposalId',v_proposal,'proposalVersion',1,
    'actionKind','RETENTION_SCHEDULE','target',v_target,
    'contentDigest',v_target_request_digest,
    'rationaleDigest',v_rationale_digest,
    'actionDetail',v_action_detail
  );
  v_approval_subject_digest :=
    pg_temp.r6d_sha256_json(v_approval_subject);
  v_evidence_set_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','approval-evidence-set.v1',
    'members',jsonb_build_array(jsonb_build_object(
      'kind','LAWFUL_BASIS_REVIEW',
      'digest',v_lawful_basis_review_digest
    ))
  ));
  v_contrary_evidence_set_digest :=
    pg_temp.r6d_sha256_json(jsonb_build_object(
      'schemaVersion','approval-contrary-evidence-set.v1','members','[]'::jsonb
    ));
  v_uncertainty_set_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','approval-uncertainty-set.v1','members','[]'::jsonb
  ));
  v_risk_assessment_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','retention-risk-assessment.v1',
    'recordClass',p_record_class,'risk','TEST_ONLY_DISPOSABLE_DATABASE',
    'finiteRetention',v_active_duration_seconds IS NOT NULL,
    'legalHoldFailClosed',true
  ));
  v_conflict_policy_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','action-conflict-policy-snapshot.v1',
    'actionKind','RETENTION_SCHEDULE',
    'requiredEvaluations',jsonb_build_array('OPERATIONS','LEGAL_REVIEWER'),
    'separationOfDuty','DISTINCT_CREATOR_AND_DISTINCT_REVIEWERS'
  ));
  v_expected_effect_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','expected-retention-effect.v1',
    'recordClass',p_record_class,'expectedScheduleRevision',0,
    'currentScheduleDigest',v_current_schedule_digest,
    'targetRequestDigest',v_target_request_digest,
    'policyDigest',v_policy_digest
  ));
  v_quorum_plan := jsonb_build_object(
    'schemaVersion','action-quorum-plan.v1','proposalId',v_proposal,
    'proposalVersion',1,'actionKind','RETENTION_SCHEDULE',
    'policyDigest',v_policy_digest,
    'requiredSlots',jsonb_build_array(
      jsonb_build_object(
        'slotId','operational_owner','slotOrdinal',1,
        'capability','retention.policy.manage','assurance','STEP_UP',
        'allowedRoles',jsonb_build_array('OPERATIONS')
      ),
      jsonb_build_object(
        'slotId','legal_owner','slotOrdinal',2,
        'capability','retention.policy.manage','assurance','STEP_UP',
        'allowedRoles',jsonb_build_array('LEGAL_REVIEWER')
      )
    ),
    'excludedActorIds',jsonb_build_array(v_creator)
  );
  v_quorum_plan_digest := pg_temp.r6d_sha256_json(v_quorum_plan);
  v_effect_idempotency_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','retention-effect-idempotency-key.v1',
      'proposalId',v_proposal,'proposalVersion',1,
      'recordClass',p_record_class,'expectedScheduleRevision',0,
      'targetRequestDigest',v_target_request_digest
    )
  );

  v_approval_binding := jsonb_build_object(
    'schemaVersion','approval-binding.v1','proposalId',v_proposal,
    'proposalVersion',1,'actionKind','RETENTION_SCHEDULE',
    'originDigest',v_origin_digest,'contentDigest',v_target_request_digest,
    'rationaleDigest',v_rationale_digest,'targetType','RECORD_CLASS',
    'targetId',p_record_class,'targetVersion',1,
    'targetDigest',v_target_digest,'objectScopeDigest',v_object_scope_digest,
    'operationId','submitActionDecision',
    'requiredCapability','actions.review',
    'targetRequestDigest',v_target_request_digest,'previewId',v_preview_id,
    'approvalSubjectDigest',v_approval_subject_digest,
    'evidenceSetDigest',v_evidence_set_digest,
    'contraryEvidenceSetDigest',v_contrary_evidence_set_digest,
    'uncertaintySetDigest',v_uncertainty_set_digest,
    'riskAssessmentDigest',v_risk_assessment_digest,
    'policySnapshotDigest',v_policy_digest,
    'conflictSnapshotDigest',v_conflict_policy_digest,
    'expectedEffectDigest',v_expected_effect_digest,'reversible',true,
    'quorumPlanDigest',v_quorum_plan_digest,
    'effectIdempotencyKeySha256',v_effect_idempotency_digest,
    'notBefore',v_submitted_at,'expiresAt',v_proposal_expires_at,
    'actionDetailKind','RETENTION_SCHEDULE',
    'actionDetail',v_action_detail,
    'actionDetailDigest',v_action_detail_digest
  );
  v_approval_binding_canonical :=
    ops.canonical_jsonb_v1(v_approval_binding);
  v_approval_digest := encode(
    extensions.digest(v_approval_binding_canonical,'sha256'),'hex'
  );

  SELECT pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','reviewer-role-snapshot.v1',
    'userId',v_operations_reviewer,'roleCode','OPERATIONS',
    'roleId',role.id,
    'capabilities',(
      SELECT jsonb_agg(capability.capability_code ORDER BY capability.capability_code)
      FROM ops.role_capabilities AS capability
      WHERE capability.role_id=role.id
    )
  )) INTO STRICT v_operations_role_snapshot_digest
  FROM ops.roles AS role
  WHERE role.code='OPERATIONS';
  SELECT pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','reviewer-role-snapshot.v1',
    'userId',v_legal_reviewer,'roleCode','LEGAL_REVIEWER',
    'roleId',role.id,
    'capabilities',(
      SELECT jsonb_agg(capability.capability_code ORDER BY capability.capability_code)
      FROM ops.role_capabilities AS capability
      WHERE capability.role_id=role.id
    )
  )) INTO STRICT v_legal_role_snapshot_digest
  FROM ops.roles AS role
  WHERE role.code='LEGAL_REVIEWER';
  v_operations_eligibility_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','action-review-eligibility-snapshot.v1',
      'proposalId',v_proposal,'proposalVersion',1,
      'reviewerId',v_operations_reviewer,'slotId','operational_owner',
      'allowedRole','OPERATIONS','actorAssertionCapability','actions.review',
      'slotCapability','retention.policy.manage',
      'roleSnapshotDigest',v_operations_role_snapshot_digest,
      'eligible',true,'evaluatedAt',v_submitted_at
    )
  );
  v_legal_eligibility_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','action-review-eligibility-snapshot.v1',
      'proposalId',v_proposal,'proposalVersion',1,
      'reviewerId',v_legal_reviewer,'slotId','legal_owner',
      'allowedRole','LEGAL_REVIEWER',
      'actorAssertionCapability','actions.review',
      'slotCapability','retention.policy.manage',
      'roleSnapshotDigest',v_legal_role_snapshot_digest,
      'eligible',true,'evaluatedAt',v_submitted_at
    )
  );
  v_exclusion_set_digest :=
    pg_temp.r6d_sha256_json(to_jsonb(ARRAY[v_creator]::uuid[]));
  v_declaration_set_digest := pg_temp.r6d_sha256_json('[]'::jsonb);
  v_finding_set_digest := pg_temp.r6d_sha256_json('{}'::jsonb);
  v_authorship_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','conflict-authorship-snapshot.v1',
    'proposalCreatorId',v_creator,'reviewerIsCreator',false
  ));
  v_party_recipient_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','conflict-party-recipient-snapshot.v1',
    'recordClass',p_record_class,'partyRecipientIds','[]'::jsonb
  ));
  v_relationship_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','conflict-relationship-snapshot.v1',
    'recordClass',p_record_class,'relationships','[]'::jsonb
  ));
  v_funding_customer_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','conflict-funding-customer-snapshot.v1',
    'recordClass',p_record_class,'bindings','[]'::jsonb
  ));

  v_operations_conflict_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','conflict-snapshot.v1',
      'conflictSnapshotId',v_operations_conflict,
      'subjectActorId',v_operations_reviewer,
      'targetType','ACTION_PROPOSAL','targetId',v_proposal::text,
      'targetVersion',1,'targetDigest',v_approval_digest,
      'operationId','submitActionDecision','actionKind','RETENTION_SCHEDULE',
      'candidateRole','OPERATIONS','declarationIds','[]'::jsonb,
      'declarationSetDigest',v_declaration_set_digest,
      'findingSet','{}'::jsonb,'findingSetDigest',v_finding_set_digest,
      'authorshipDigest',v_authorship_digest,
      'partyRecipientDigest',v_party_recipient_digest,
      'roleDigest',v_operations_role_snapshot_digest,
      'relationshipDigest',v_relationship_digest,
      'fundingCustomerDigest',v_funding_customer_digest,
      'policyDigest',v_conflict_policy_digest,'evaluationState','CLEAR',
      'blockerCodes','[]'::jsonb,'nonwaivableBlockerCount',0,
      'evaluatedAt',v_submitted_at,'validUntil',v_due_at,
      'evaluatedByType','SERVICE','evaluatedById','action-approval',
      'classification','RESTRICTED_GOVERNANCE'
    )
  );
  v_legal_conflict_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','conflict-snapshot.v1',
      'conflictSnapshotId',v_legal_conflict,
      'subjectActorId',v_legal_reviewer,
      'targetType','ACTION_PROPOSAL','targetId',v_proposal::text,
      'targetVersion',1,'targetDigest',v_approval_digest,
      'operationId','submitActionDecision','actionKind','RETENTION_SCHEDULE',
      'candidateRole','LEGAL_REVIEWER','declarationIds','[]'::jsonb,
      'declarationSetDigest',v_declaration_set_digest,
      'findingSet','{}'::jsonb,'findingSetDigest',v_finding_set_digest,
      'authorshipDigest',v_authorship_digest,
      'partyRecipientDigest',v_party_recipient_digest,
      'roleDigest',v_legal_role_snapshot_digest,
      'relationshipDigest',v_relationship_digest,
      'fundingCustomerDigest',v_funding_customer_digest,
      'policyDigest',v_conflict_policy_digest,'evaluationState','CLEAR',
      'blockerCodes','[]'::jsonb,'nonwaivableBlockerCount',0,
      'evaluatedAt',v_submitted_at,'validUntil',v_due_at,
      'evaluatedByType','SERVICE','evaluatedById','action-approval',
      'classification','RESTRICTED_GOVERNANCE'
    )
  );
  v_operations_conflict_receipt_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','conflict-snapshot-receipt.v1',
      'conflictSnapshotId',v_operations_conflict,
      'snapshotDigest',v_operations_conflict_digest,
      'evaluationState','CLEAR','evaluatedAt',v_submitted_at
    )
  );
  v_legal_conflict_receipt_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','conflict-snapshot-receipt.v1',
      'conflictSnapshotId',v_legal_conflict,
      'snapshotDigest',v_legal_conflict_digest,
      'evaluationState','CLEAR','evaluatedAt',v_submitted_at
    )
  );
  v_operations_assignment_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','action-review-assignment.v1',
      'assignmentId',v_operations_assignment,'proposalId',v_proposal,
      'proposalVersion',1,'approvalDigest',v_approval_digest,
      'assignmentGeneration',1,'slotId','operational_owner','slotOrdinal',1,
      'requiredCapability','retention.policy.manage',
      'approveAssurance','STEP_UP','allowedRoles',jsonb_build_array('OPERATIONS'),
      'reviewerId',v_operations_reviewer,
      'reviewerRoleSnapshotDigest',v_operations_role_snapshot_digest,
      'eligibilitySnapshotDigest',v_operations_eligibility_digest,
      'conflictSnapshotId',v_operations_conflict,
      'conflictSnapshotDigest',v_operations_conflict_digest,
      'excludedActorIds',jsonb_build_array(v_creator),
      'exclusionSetDigest',v_exclusion_set_digest,
      'quorumPlanDigest',v_quorum_plan_digest,'dueAt',v_due_at
    )
  );
  v_legal_assignment_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','action-review-assignment.v1',
      'assignmentId',v_legal_assignment,'proposalId',v_proposal,
      'proposalVersion',1,'approvalDigest',v_approval_digest,
      'assignmentGeneration',1,'slotId','legal_owner','slotOrdinal',2,
      'requiredCapability','retention.policy.manage',
      'approveAssurance','STEP_UP',
      'allowedRoles',jsonb_build_array('LEGAL_REVIEWER'),
      'reviewerId',v_legal_reviewer,
      'reviewerRoleSnapshotDigest',v_legal_role_snapshot_digest,
      'eligibilitySnapshotDigest',v_legal_eligibility_digest,
      'conflictSnapshotId',v_legal_conflict,
      'conflictSnapshotDigest',v_legal_conflict_digest,
      'excludedActorIds',jsonb_build_array(v_creator),
      'exclusionSetDigest',v_exclusion_set_digest,
      'quorumPlanDigest',v_quorum_plan_digest,'dueAt',v_due_at
    )
  );

  v_operations_step_up_action := jsonb_build_object(
    'schemaVersion','action-review-step-up.v1','proposalId',v_proposal,
    'proposalVersion',1,'approvalDigest',v_approval_digest,
    'assignmentId',v_operations_assignment,'assignmentVersion',2,
    'assignmentGeneration',1,'slotKind','operational_owner',
    'decisionKind','APPROVE'
  );
  v_legal_step_up_action := jsonb_build_object(
    'schemaVersion','action-review-step-up.v1','proposalId',v_proposal,
    'proposalVersion',1,'approvalDigest',v_approval_digest,
    'assignmentId',v_legal_assignment,'assignmentVersion',2,
    'assignmentGeneration',1,'slotKind','legal_owner',
    'decisionKind','APPROVE'
  );
  v_operations_step_up_action_digest :=
    pg_temp.r6d_sha256_json(v_operations_step_up_action);
  v_legal_step_up_action_digest :=
    pg_temp.r6d_sha256_json(v_legal_step_up_action);
  v_operations_idempotency_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','action-decision-idempotency-key.v1',
      'requestId',v_request_id,'assignmentId',v_operations_assignment,
      'actorId',v_operations_reviewer,'approvalDigest',v_approval_digest
    )
  );
  v_legal_idempotency_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','action-decision-idempotency-key.v1',
      'requestId',v_request_id,'assignmentId',v_legal_assignment,
      'actorId',v_legal_reviewer,'approvalDigest',v_approval_digest
    )
  );
  v_operations_step_up_receipt := jsonb_build_object(
    'schemaVersion','step-up-authorization-receipt.v1',
    'authorizationId',v_operations_step_up,
    'actionDigest',v_operations_step_up_action_digest,
    'sessionId',v_operations_session,'issueNumber',1,
    'issuedAt',v_operations_decided_at-interval '1 second',
    'expiresAt',v_operations_decided_at+interval '4 minutes'
  );
  v_legal_step_up_receipt := jsonb_build_object(
    'schemaVersion','step-up-authorization-receipt.v1',
    'authorizationId',v_legal_step_up,
    'actionDigest',v_legal_step_up_action_digest,
    'sessionId',v_legal_session,'issueNumber',1,
    'issuedAt',v_legal_decided_at-interval '1 second',
    'expiresAt',v_legal_decided_at+interval '4 minutes'
  );
  v_operations_step_up_receipt_canonical :=
    ops.canonical_jsonb_v1(v_operations_step_up_receipt);
  v_legal_step_up_receipt_canonical :=
    ops.canonical_jsonb_v1(v_legal_step_up_receipt);
  v_operations_step_up_receipt_digest := encode(
    extensions.digest(v_operations_step_up_receipt_canonical,'sha256'),'hex'
  );
  v_legal_step_up_receipt_digest := encode(
    extensions.digest(v_legal_step_up_receipt_canonical,'sha256'),'hex'
  );

  v_operations_decision_payload := jsonb_build_object(
    'kind','APPROVE','reasonCode','TEST_ONLY_RETENTION_APPROVAL',
    'reason',v_operations_reason,'attestExactPreview',true
  );
  v_legal_decision_payload := jsonb_build_object(
    'kind','APPROVE','reasonCode','TEST_ONLY_RETENTION_APPROVAL',
    'reason',v_legal_reason,'attestExactPreview',true
  );
  v_operations_decision_payload_canonical :=
    ops.canonical_jsonb_v1(v_operations_decision_payload);
  v_legal_decision_payload_canonical :=
    ops.canonical_jsonb_v1(v_legal_decision_payload);
  v_operations_quorum_snapshot_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','action-quorum-snapshot.v1',
      'planDigest',v_quorum_plan_digest,'proposalId',v_proposal,
      'proposalVersion',1,'approvalDigest',v_approval_digest,
      'decisionKind','APPROVE',
      'currentAssignmentId',v_operations_assignment,
      'currentSlot','operational_owner',
      'currentConflictSnapshotDigest',v_operations_conflict_digest,
      'priorDecisionId',NULL,'priorSlot',NULL,
      'priorConflictSnapshotDigest',NULL,'complete',false
    )
  );
  v_operations_decision_receipt := jsonb_build_object(
    'schemaVersion','action-decision-receipt-binding.v1',
    'recordKind','DECISION','decisionId',v_operations_decision,
    'proposalId',v_proposal,'proposalVersion',1,
    'approvalDigest',v_approval_digest,
    'assignmentId',v_operations_assignment,'assignmentVersion',3,
    'assignmentGeneration',1,'slotKind','operational_owner',
    'decisionKind','APPROVE','actorId',v_operations_reviewer,
    'assertedRequiredCapability','actions.review','assurance','STEP_UP',
    'actorAssertionJti',v_operations_assertion_jti,
    'actorActionDigest',v_operations_step_up_action_digest,
    'stepUpAuthorizationId',v_operations_step_up,
    'stepUpAuthorizationReceiptDigest',v_operations_step_up_receipt_digest,
    'reasonCode','TEST_ONLY_RETENTION_APPROVAL',
    'reasonDigest',pg_temp.r6d_sha256_text(v_operations_reason),
    'conflictSnapshotDigest',v_operations_conflict_digest,
    'conflictDeclarationId',NULL,
    'quorumSnapshotDigest',v_operations_quorum_snapshot_digest,
    'requestId',v_request_id,
    'idempotencyKeySha256',v_operations_idempotency_digest,
    'auditEventId',v_operations_audit,
    'decidedAt',v_operations_decided_at,
    'withdrawnDecisionId',NULL,'withdrawnDecisionReceiptDigest',NULL
  );
  v_operations_decision_receipt_canonical :=
    ops.canonical_jsonb_v1(v_operations_decision_receipt);
  v_operations_decision_receipt_digest := encode(
    extensions.digest(v_operations_decision_receipt_canonical,'sha256'),'hex'
  );

  v_legal_quorum_snapshot_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','action-quorum-snapshot.v1',
      'planDigest',v_quorum_plan_digest,'proposalId',v_proposal,
      'proposalVersion',1,'approvalDigest',v_approval_digest,
      'decisionKind','APPROVE','currentAssignmentId',v_legal_assignment,
      'currentSlot','legal_owner',
      'currentConflictSnapshotDigest',v_legal_conflict_digest,
      'priorDecisionId',v_operations_decision,
      'priorSlot','operational_owner',
      'priorConflictSnapshotDigest',v_operations_conflict_digest,
      'complete',true
    )
  );
  v_legal_decision_receipt := jsonb_build_object(
    'schemaVersion','action-decision-receipt-binding.v1',
    'recordKind','DECISION','decisionId',v_legal_decision,
    'proposalId',v_proposal,'proposalVersion',1,
    'approvalDigest',v_approval_digest,
    'assignmentId',v_legal_assignment,'assignmentVersion',3,
    'assignmentGeneration',1,'slotKind','legal_owner',
    'decisionKind','APPROVE','actorId',v_legal_reviewer,
    'assertedRequiredCapability','actions.review','assurance','STEP_UP',
    'actorAssertionJti',v_legal_assertion_jti,
    'actorActionDigest',v_legal_step_up_action_digest,
    'stepUpAuthorizationId',v_legal_step_up,
    'stepUpAuthorizationReceiptDigest',v_legal_step_up_receipt_digest,
    'reasonCode','TEST_ONLY_RETENTION_APPROVAL',
    'reasonDigest',pg_temp.r6d_sha256_text(v_legal_reason),
    'conflictSnapshotDigest',v_legal_conflict_digest,
    'conflictDeclarationId',NULL,
    'quorumSnapshotDigest',v_legal_quorum_snapshot_digest,
    'requestId',v_request_id,
    'idempotencyKeySha256',v_legal_idempotency_digest,
    'auditEventId',v_legal_audit,'decidedAt',v_legal_decided_at,
    'withdrawnDecisionId',NULL,'withdrawnDecisionReceiptDigest',NULL
  );
  v_legal_decision_receipt_canonical :=
    ops.canonical_jsonb_v1(v_legal_decision_receipt);
  v_legal_decision_receipt_digest := encode(
    extensions.digest(v_legal_decision_receipt_canonical,'sha256'),'hex'
  );

  v_counted_decision_ids := ARRAY[
    v_operations_decision,v_legal_decision
  ]::uuid[];
  SELECT array_agg(receipt_digest ORDER BY receipt_digest COLLATE "C")
  INTO STRICT v_counted_receipt_digests
  FROM unnest(ARRAY[
    btrim(v_operations_decision_receipt_digest),
    btrim(v_legal_decision_receipt_digest)
  ]) AS receipt(receipt_digest);
  v_counted_decision_set_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'decisionIds',to_jsonb(v_counted_decision_ids),
      'decisionReceiptDigests',to_jsonb(v_counted_receipt_digests)
    )
  );

  v_execution_conflict_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','counted-conflict-snapshot-set.v1',
      'members',jsonb_build_array(
        jsonb_build_object(
          'slot','operational_owner','snapshotDigest',v_operations_conflict_digest
        ),
        jsonb_build_object(
          'slot','legal_owner','snapshotDigest',v_legal_conflict_digest
        )
      )
    )
  );
  v_kill_switch_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','kill-switch-snapshot.v1',
    'scope',p_record_class,'blockingSwitches','[]'::jsonb
  ));
  v_rights_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','rights-snapshot.v1','scope',p_record_class,
    'requiredRights','[]'::jsonb
  ));
  v_consent_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','consent-snapshot.v1','scope',p_record_class,
    'requiredConsents','[]'::jsonb
  ));
  v_suppression_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','suppression-snapshot.v1','scope',p_record_class,
    'suppressions','[]'::jsonb
  ));
  v_activation_digest := pg_temp.r6d_sha256_json(jsonb_build_object(
    'schemaVersion','capability-activation-snapshot.v1',
    'capability','retention.policy.manage','state','ACTIVE_FOR_TEST'
  ));
  v_execution_binding := jsonb_build_object(
    'schemaVersion','execution-binding.v1','executionId',v_effect,
    'generation',1,'proposalId',v_proposal,'proposalVersion',1,
    'actionKind','RETENTION_SCHEDULE','approvalDigest',v_approval_digest,
    'approvalSubjectDigest',v_approval_subject_digest,
    'countedDecisionIds',to_jsonb(v_counted_decision_ids),
    'countedDecisionReceiptDigests',to_jsonb(v_counted_receipt_digests),
    'countedDecisionSetDigest',v_counted_decision_set_digest,
    'terminalDecisionId',v_legal_decision,
    'terminalDecisionReceiptDigest',v_legal_decision_receipt_digest,
    'executorId','private.CreateRecordClassScheduleRevision',
    'transport','PRIVATE_APPLICATION_COMMAND',
    'requiredCapability','retention.policy.manage',
    'requiredAssurance','STEP_UP',
    'targetRequestSchemaVersion','action-payload.v1',
    'targetRequestSha256',v_target_request_digest,
    'exactRenderedBytesDigest',v_target_request_digest,
    'effectIdempotencyKeySha256',v_effect_idempotency_digest,
    'providerConfigId',NULL,'providerConfigVersion',NULL,
    'providerConfigurationDigest',v_database_only_digest,
    'providerIdempotencyKeySha256',v_no_provider_key,
    'budgetReservationId',NULL,'budgetReservationDigest',v_no_budget_digest,
    'policySnapshotDigest',v_policy_digest,
    'killSwitchDigest',v_kill_switch_digest,'rightsDigest',v_rights_digest,
    'consentDigest',v_consent_digest,
    'suppressionDigest',v_suppression_digest,
    'conflictSnapshotDigest',v_execution_conflict_digest,
    'activationDigest',v_activation_digest,
    'quorumPlanDigest',v_quorum_plan_digest,'cancellationGeneration',0,
    'priorExecutionDigest',NULL,'safeRetryProofDigest',NULL,
    'notBefore',v_authorized_at,'authorizedAt',v_authorized_at,
    'expiresAt',v_proposal_expires_at
  );
  v_execution_binding_canonical :=
    ops.canonical_jsonb_v1(v_execution_binding);
  v_execution_digest := encode(
    extensions.digest(v_execution_binding_canonical,'sha256'),'hex'
  );
  v_execution_proof := jsonb_build_object(
    'schemaVersion','database-only-retention-execution-proof.v1',
    'executionId',v_effect,'generation',1,
    'executorId','private.CreateRecordClassScheduleRevision',
    'targetRequestSha256',v_target_request_digest,
    'policyDigest',v_policy_digest,'committedAt',v_succeeded_at
  );
  v_execution_proof_digest :=
    pg_temp.r6d_sha256_json(v_execution_proof);
  v_empty_downstream_set_digest := pg_temp.r6d_sha256_json(
    jsonb_build_object(
      'schemaVersion','downstream-receipt-set.v1','members','[]'::jsonb
    )
  );

  v_queued_receipt_payload := jsonb_build_object(
    'schemaVersion','execution-receipt-payload.v1',
    'receiptKind','AUTHORIZATION_QUEUED','executionId',v_effect,
    'generation',1,'authorizationDigest',v_execution_digest,
    'attemptId',v_attempt,'receiptSequence',1,'priorReceiptDigest',NULL,
    'aggregateTransition',jsonb_build_object('from',NULL,'to','QUEUED'),
    'aggregateStateVersion',1,
    'attemptTransition',jsonb_build_object('from',NULL,'to','QUEUED'),
    'attemptStateVersion',1,'dispatchOrdinal',NULL,'fencingToken',0,
    'cancellationGeneration',0,'targetRequestSha256',v_target_request_digest,
    'exactRenderedBytesDigest',v_target_request_digest,
    'effectIdempotencyKeySha256',v_effect_idempotency_digest,
    'providerConfigId',NULL,'providerConfigVersion',NULL,
    'providerConfigurationDigest',v_database_only_digest,
    'providerIdempotencyKeySha256',v_no_provider_key,
    'providerAcknowledgementDigest',NULL,'providerObservationDigest',NULL,
    'downstreamEffectIds','[]'::jsonb,'downstreamReceiptDigests','[]'::jsonb,
    'downstreamReceiptSetDigest',v_empty_downstream_set_digest,
    'proof',jsonb_build_object(
      'kind','NO_EGRESS','digest',v_target_request_digest,
      'effectCertainty','DEFINITIVE_NOT_ACCEPTED'
    ),
    'cost',jsonb_build_object(
      'costClass','NO_PAID_EGRESS','actualAmount',NULL,
      'actualCurrency',NULL,'costEventIds','[]'::jsonb
    ),
    'budget',jsonb_build_object(
      'reservationId',NULL,'reservationDigest',v_no_budget_digest
    ),
    'requestId',v_request_id,'auditEventId',v_authorization_audit,
    'outboxId',v_authorized_outbox,'observedAt',v_authorized_at
  );
  v_queued_receipt_canonical :=
    ops.canonical_jsonb_v1(v_queued_receipt_payload);
  v_queued_receipt_digest := encode(
    extensions.digest(v_queued_receipt_canonical,'sha256'),'hex'
  );
  v_terminal_receipt_payload := jsonb_build_object(
    'schemaVersion','execution-receipt-payload.v1',
    'receiptKind','EFFECT_SUCCEEDED','executionId',v_effect,
    'generation',1,'authorizationDigest',v_execution_digest,
    'attemptId',v_attempt,'receiptSequence',2,
    'priorReceiptDigest',v_queued_receipt_digest,
    'aggregateTransition',jsonb_build_object('from','QUEUED','to','SUCCEEDED'),
    'aggregateStateVersion',2,
    'attemptTransition',jsonb_build_object('from','QUEUED','to','SUCCEEDED'),
    'attemptStateVersion',2,'dispatchOrdinal',NULL,'fencingToken',0,
    'cancellationGeneration',0,'targetRequestSha256',v_target_request_digest,
    'exactRenderedBytesDigest',v_target_request_digest,
    'effectIdempotencyKeySha256',v_effect_idempotency_digest,
    'providerConfigId',NULL,'providerConfigVersion',NULL,
    'providerConfigurationDigest',v_database_only_digest,
    'providerIdempotencyKeySha256',v_no_provider_key,
    'providerAcknowledgementDigest',NULL,'providerObservationDigest',NULL,
    'downstreamEffectIds','[]'::jsonb,'downstreamReceiptDigests','[]'::jsonb,
    'downstreamReceiptSetDigest',v_empty_downstream_set_digest,
    'proof',jsonb_build_object(
      'kind','NO_EGRESS','digest',v_execution_proof_digest,
      'effectCertainty','DEFINITIVE_SUCCEEDED'
    ),
    'cost',jsonb_build_object(
      'costClass','NO_PAID_EGRESS','actualAmount',NULL,
      'actualCurrency',NULL,'costEventIds','[]'::jsonb
    ),
    'budget',jsonb_build_object(
      'reservationId',NULL,'reservationDigest',v_no_budget_digest
    ),
    'requestId',v_request_id,'auditEventId',v_execution_audit,
    'outboxId',v_completed_outbox,'observedAt',v_succeeded_at
  );
  v_terminal_receipt_canonical :=
    ops.canonical_jsonb_v1(v_terminal_receipt_payload);
  v_terminal_receipt_digest := encode(
    extensions.digest(v_terminal_receipt_canonical,'sha256'),'hex'
  );

  -- The schedule digest binds every persisted policy field, the ordered
  -- locations/derivatives, both independent decisions, the authorization,
  -- terminal receipt, and both absolute policy times.
  v_schedule_binding := jsonb_build_object(
    'schemaVersion','record-class-schedule.v1','scheduleId',v_schedule,
    'recordClass',p_record_class,'revision',1,'supersedesScheduleId',NULL,
    'ownerTeam',v_owner_team,'purpose',v_purpose,
    'lawfulBasis',v_lawful_basis,
    'lawfulBasisReviewDigest',v_lawful_basis_review_digest,
    'triggerKind',v_trigger_kind,
    'activeDurationSeconds',v_active_duration_seconds,
    'backupDurationSeconds',v_backup_duration_seconds,
    'locationCodes',jsonb_build_array('KR'),
    'derivativeRecordClasses','[]'::jsonb,
    'terminalAction',v_terminal_action,
    'holdBehavior',v_hold_behavior,
    'restoreSuppressionBehavior',v_restore_suppression_behavior,
    'policyDigest',v_policy_digest,'actionProposalId',v_proposal,
    'actionProposalVersion',1,'approvalDigest',v_approval_digest,
    'operationalActionDecisionId',v_operations_decision,
    'operationalActionDecisionReceiptDigest',
      v_operations_decision_receipt_digest,
    'legalActionDecisionId',v_legal_decision,
    'legalActionDecisionReceiptDigest',v_legal_decision_receipt_digest,
    'countedDecisionSetDigest',v_counted_decision_set_digest,
    'actionExecutionId',v_effect,'actionExecutionGeneration',1,
    'actionExecutionDigest',v_execution_digest,
    'actionExecutionReceiptId',v_terminal_receipt,
    'actionExecutionReceiptDigest',v_terminal_receipt_digest,
    'effectiveAt',v_effective_at,'reviewExpiresAt',v_review_expires_at
  );
  v_schedule_digest := pg_temp.r6d_sha256_json(v_schedule_binding);

  -- Materialize the same deterministic audit chain shape as
  -- ops.append_audit_event, but retain fixed UUIDs and fixed timestamps.
  PERFORM pg_temp.r6d_append_fixed_audit_event(
    v_preview_audit,v_previewed_at,v_stream_key,'USER',v_creator::text,
    'ACTION_PROPOSAL_PREVIEWED','ActionProposal',v_proposal::text,
    'retention.policy.manage',v_request_id,jsonb_build_object(
      'recordClass',p_record_class,'proposalVersion',1,
      'approvalSubjectDigest',v_approval_subject_digest,'testOnly',true
    )
  );
  PERFORM pg_temp.r6d_append_fixed_audit_event(
    v_operations_audit,v_operations_decided_at,v_stream_key,'USER',
    v_operations_reviewer::text,'ACTION_DECISION_SUBMITTED',
    'ActionProposal',v_proposal::text,'actions.review',v_request_id,
    jsonb_build_object(
      'slot','operational_owner','decisionKind','APPROVE',
      'decisionReceiptDigest',v_operations_decision_receipt_digest,
      'testOnly',true
    )
  );
  PERFORM pg_temp.r6d_append_fixed_audit_event(
    v_legal_audit,v_legal_decided_at,v_stream_key,'USER',
    v_legal_reviewer::text,'ACTION_DECISION_SUBMITTED','ActionProposal',
    v_proposal::text,'actions.review',v_request_id,jsonb_build_object(
      'slot','legal_owner','decisionKind','APPROVE',
      'decisionReceiptDigest',v_legal_decision_receipt_digest,
      'testOnly',true
    )
  );
  PERFORM pg_temp.r6d_append_fixed_audit_event(
    v_authorization_audit,v_authorized_at,v_stream_key,'SERVICE',
    'action-approval','ACTION_EXECUTION_AUTHORIZED','ActionExecution',
    v_effect::text,'retention.policy.manage',v_request_id,
    jsonb_build_object(
      'recordClass',p_record_class,'executionDigest',v_execution_digest,
      'receiptDigest',v_queued_receipt_digest,'testOnly',true
    )
  );
  PERFORM pg_temp.r6d_append_fixed_audit_event(
    v_execution_audit,v_succeeded_at,v_stream_key,'SERVICE',
    'retention-schedule-executor','ACTION_EXECUTION_SUCCEEDED',
    'ActionExecution',v_effect::text,'retention.policy.manage',v_request_id,
    jsonb_build_object(
      'recordClass',p_record_class,'executionDigest',v_execution_digest,
      'receiptDigest',v_terminal_receipt_digest,'scheduleDigest',
      v_schedule_digest,'testOnly',true
    )
  );

  INSERT INTO ops.step_up_authorizations(
    id,session_id,action_digest,idempotency_key_sha256,
    authorization_token_hash,expires_at,closed_at,assertion_issue_count,
    max_assertion_issues,created_at,last_issued_at
  ) VALUES
  (
    v_operations_step_up,v_operations_session,
    v_operations_step_up_action_digest,v_operations_idempotency_digest,
    pg_temp.r6d_sha256_text(v_operations_step_up::text||':token'),
    v_operations_decided_at+interval '4 minutes',NULL,1,3,
    v_operations_decided_at-interval '2 seconds',
    v_operations_decided_at-interval '1 second'
  ),
  (
    v_legal_step_up,v_legal_session,v_legal_step_up_action_digest,
    v_legal_idempotency_digest,
    pg_temp.r6d_sha256_text(v_legal_step_up::text||':token'),
    v_legal_decided_at+interval '4 minutes',NULL,1,3,
    v_legal_decided_at-interval '2 seconds',
    v_legal_decided_at-interval '1 second'
  );

  INSERT INTO ops.action_proposals(
    id,action_kind,origin_kind,origin_id,origin_version,origin_digest,
    target_type,target_id,target_version,target_digest,object_scope_digest,
    current_version,aggregate_version,created_by,owner_user_id,
    last_receipt_digest,last_audit_event_id,created_at,updated_at
  ) VALUES (
    v_proposal,'RETENTION_SCHEDULE','HUMAN',v_creator,1,v_origin_digest,
    'RECORD_CLASS',p_record_class,1,v_target_digest,v_object_scope_digest,
    1,5,v_creator,v_creator,v_legal_decision_receipt_digest,v_legal_audit,
    v_created_at,v_legal_decided_at
  );

  INSERT INTO ops.action_proposal_versions(
    proposal_id,version,state,state_version,payload_schema_version,
    payload_encrypted,content_digest,rationale_encrypted,rationale_digest,
    last_editor_id,expires_at,preview_id,preview_digest,
    preview_policy_digest,preview_encrypted,previewed_at,previewed_by,
    preview_receipt_digest,preview_audit_event_id,approval_binding,
    approval_binding_canonical,approval_digest,operation_id,
    required_capability,target_request_digest,evidence_set_digest,
    contrary_evidence_set_digest,uncertainty_set_digest,
    risk_assessment_digest,policy_snapshot_digest,conflict_snapshot_digest,
    expected_effect_digest,reversible,quorum_plan_digest,
    effect_idempotency_key_sha256,action_detail_kind,action_detail,
    action_detail_canonical,action_detail_digest,quorum_policy_version,
    not_before,due_at,submitted_at,terminal_reason_code,
    terminal_receipt_digest,terminal_at,created_at,updated_at
  ) VALUES (
    v_proposal,1,'APPROVED',5,'action-payload.v1',v_payload_encrypted,
    v_target_request_digest,v_rationale_encrypted,v_rationale_digest,
    v_creator,v_proposal_expires_at,v_preview_id,v_approval_subject_digest,
    v_policy_digest,v_payload_encrypted,v_previewed_at,v_creator,
    pg_temp.r6d_sha256_json(jsonb_build_object(
      'schemaVersion','action-preview-receipt.v1','previewId',v_preview_id,
      'proposalId',v_proposal,'proposalVersion',1,
      'approvalSubjectDigest',v_approval_subject_digest,
      'policyDigest',v_policy_digest,'previewedAt',v_previewed_at
    )),v_preview_audit,v_approval_binding,v_approval_binding_canonical,
    v_approval_digest,'submitActionDecision','actions.review',
    v_target_request_digest,v_evidence_set_digest,
    v_contrary_evidence_set_digest,v_uncertainty_set_digest,
    v_risk_assessment_digest,v_policy_digest,v_conflict_policy_digest,
    v_expected_effect_digest,true,v_quorum_plan_digest,
    v_effect_idempotency_digest,'RETENTION_SCHEDULE',v_action_detail,
    v_action_detail_canonical,v_action_detail_digest,'approval-policy.v1',
    v_submitted_at,v_due_at,v_submitted_at,'APPROVED',
    v_legal_decision_receipt_digest,v_legal_decided_at,v_created_at,
    v_legal_decided_at
  );

  INSERT INTO ops.action_approval_retention_schedule_details(
    proposal_id,proposal_version,detail_kind,detail_binding_canonical,
    action_detail_digest,created_at,record_class,
    expected_schedule_revision,current_schedule_digest,purpose_digest,
    lawful_basis_digest,trigger_kind,active_duration_seconds,
    backup_duration_seconds,location_set_digest,terminal_action,
    hold_behavior,restore_suppression_behavior,
    current_legal_hold_set_digest,effective_at,review_expires_at
  ) VALUES (
    v_proposal,1,'RETENTION_SCHEDULE',v_action_detail_canonical,
    v_action_detail_digest,v_submitted_at,p_record_class,0,
    v_current_schedule_digest,v_purpose_digest,v_lawful_basis_digest,
    v_trigger_kind,v_active_duration_seconds,v_backup_duration_seconds,
    v_location_set_digest,v_terminal_action,
    v_hold_behavior,v_restore_suppression_behavior,
    v_current_legal_hold_set_digest,v_effective_at,v_review_expires_at
  );

  INSERT INTO editorial.conflict_snapshots(
    id,subject_actor_id,target_type,target_id,target_version,target_digest,
    operation_id,action_kind,candidate_role,declaration_ids,
    declaration_set_digest,finding_set,finding_set_digest,authorship_digest,
    party_recipient_digest,role_digest,relationship_digest,
    funding_customer_digest,policy_digest,evaluation_state,blocker_codes,
    nonwaivable_blocker_count,evaluated_at,valid_until,evaluated_by_type,
    evaluated_by_id,snapshot_sha256,receipt_digest,classification,created_at
  ) VALUES
  (
    v_operations_conflict,v_operations_reviewer,'ACTION_PROPOSAL',
    v_proposal::text,1,v_approval_digest,'submitActionDecision',
    'RETENTION_SCHEDULE','OPERATIONS','{}'::uuid[],
    v_declaration_set_digest,'{}'::jsonb,v_finding_set_digest,
    v_authorship_digest,v_party_recipient_digest,
    v_operations_role_snapshot_digest,v_relationship_digest,
    v_funding_customer_digest,v_conflict_policy_digest,'CLEAR',
    '{}'::text[],0,v_submitted_at,v_due_at,'SERVICE','action-approval',
    v_operations_conflict_digest,v_operations_conflict_receipt_digest,
    'RESTRICTED_GOVERNANCE',v_submitted_at
  ),
  (
    v_legal_conflict,v_legal_reviewer,'ACTION_PROPOSAL',v_proposal::text,1,
    v_approval_digest,'submitActionDecision','RETENTION_SCHEDULE',
    'LEGAL_REVIEWER','{}'::uuid[],v_declaration_set_digest,'{}'::jsonb,
    v_finding_set_digest,v_authorship_digest,v_party_recipient_digest,
    v_legal_role_snapshot_digest,v_relationship_digest,
    v_funding_customer_digest,v_conflict_policy_digest,'CLEAR',
    '{}'::text[],0,v_submitted_at,v_due_at,'SERVICE','action-approval',
    v_legal_conflict_digest,v_legal_conflict_receipt_digest,
    'RESTRICTED_GOVERNANCE',v_submitted_at
  );

  INSERT INTO ops.action_review_assignments(
    id,proposal_id,proposal_version,approval_digest,assignment_generation,
    slot_id,slot_ordinal,required_capability,approve_assurance,
    allowed_role_codes,reviewer_id,reviewer_role_snapshot_digest,
    eligibility_snapshot_digest,conflict_snapshot_id,
    conflict_snapshot_digest,conflict_target_type,conflict_target_id,
    conflict_target_version,conflict_target_digest,
    conflict_evaluation_state,conflict_valid_until,excluded_actor_ids,
    exclusion_set_digest,quorum_plan_digest,assignment_digest,state,version,
    blocking_reason_code,next_assignment_scan_at,
    replacement_of_assignment_id,assigned_by,due_at,claimed_at,terminal_at,
    terminal_reason_code,last_receipt_digest,last_audit_event_id,
    created_at,updated_at
  ) VALUES
  (
    v_operations_assignment,v_proposal,1,v_approval_digest,1,
    'operational_owner',1,'retention.policy.manage','STEP_UP',
    ARRAY['OPERATIONS']::text[],v_operations_reviewer,
    v_operations_role_snapshot_digest,v_operations_eligibility_digest,
    v_operations_conflict,v_operations_conflict_digest,'ACTION_PROPOSAL',
    v_proposal,1,v_approval_digest,'CLEAR',v_due_at,
    ARRAY[v_creator]::uuid[],v_exclusion_set_digest,v_quorum_plan_digest,
    v_operations_assignment_digest,'COMPLETED',3,NULL,NULL,NULL,v_creator,
    v_due_at,v_operations_claimed_at,v_operations_decided_at,'APPROVE',
    v_operations_decision_receipt_digest,v_operations_audit,v_submitted_at,
    v_operations_decided_at
  ),
  (
    v_legal_assignment,v_proposal,1,v_approval_digest,1,'legal_owner',2,
    'retention.policy.manage','STEP_UP',ARRAY['LEGAL_REVIEWER']::text[],
    v_legal_reviewer,v_legal_role_snapshot_digest,
    v_legal_eligibility_digest,v_legal_conflict,v_legal_conflict_digest,
    'ACTION_PROPOSAL',v_proposal,1,v_approval_digest,'CLEAR',v_due_at,
    ARRAY[v_creator]::uuid[],v_exclusion_set_digest,v_quorum_plan_digest,
    v_legal_assignment_digest,'COMPLETED',3,NULL,NULL,NULL,v_creator,
    v_due_at,v_legal_claimed_at,v_legal_decided_at,'APPROVE',
    v_legal_decision_receipt_digest,v_legal_audit,v_submitted_at,
    v_legal_decided_at
  );

  INSERT INTO ops.in_flight_effects(
    id,effect_type,effect_key_digest,action_kind,action_proposal_id,
    action_proposal_version,approval_digest,agent_provider_turn_id,
    predecessor_effect_id,predecessor_relationship,current_generation,state,
    state_version,cancellation_generation,dispatch_attempt_count,run_after,
    provider_config_id,provider_config_version,
    provider_configuration_digest,provider_idempotency_key_sha256,
    policy_digest,kill_switch_digest,budget_digest,rights_digest,
    consent_digest,suppression_digest,conflict_digest,activation_digest,
    quorum_plan_digest,rendered_bytes_digest,fence_reason_code,
    cancel_requested_at,cancel_reason_digest,reconciliation_attempt_count,
    next_reconcile_at,incident_id,last_receipt_sequence,last_receipt_digest,
    terminal_at,created_at,updated_at
  ) VALUES (
    v_effect,'ACTION_EXECUTION',v_effect_idempotency_digest,
    'RETENTION_SCHEDULE',v_proposal,1,v_approval_digest,NULL,NULL,'NONE',1,
    'SUCCEEDED',2,0,0,v_authorized_at,NULL,NULL,v_database_only_digest,
    v_no_provider_key,v_policy_digest,v_kill_switch_digest,
    v_no_budget_digest,v_rights_digest,v_consent_digest,
    v_suppression_digest,v_execution_conflict_digest,v_activation_digest,
    v_quorum_plan_digest,v_target_request_digest,NULL,NULL,NULL,0,NULL,NULL,
    2,v_terminal_receipt_digest,v_succeeded_at,v_authorized_at,v_succeeded_at
  );

  INSERT INTO ops.action_decisions(
    id,record_kind,proposal_id,proposal_version,approval_digest,
    assignment_id,assignment_version,assignment_generation,slot_kind,
    actor_id,asserted_required_capability,assurance,
    step_up_authorization_id,step_up_authorization_digest,
    step_up_authorization_receipt_digest,
    step_up_authorization_receipt_canonical,step_up_issue_ordinal,
    step_up_issued_at,step_up_expires_at,actor_assertion_jti,
    actor_action_digest,idempotency_key_sha256,decision_kind,
    withdrawn_decision_id,withdrawn_decision_receipt_digest,
    withdrawn_record_kind,withdrawn_decision_kind,reason_code,reason,
    reason_digest,decision_payload,decision_payload_canonical,
    decision_receipt_binding,decision_receipt_binding_canonical,
    conflict_snapshot_id,conflict_snapshot_digest,conflict_target_type,
    conflict_target_id,conflict_target_version,conflict_target_digest,
    conflict_evaluation_state,conflict_valid_until,conflict_declaration_id,
    quorum_snapshot_digest,counts_toward_quorum,quorum_satisfied_after,
    resulting_proposal_state,change_task_ids,execution_id,receipt_digest,
    request_id,audit_event_id,decided_at,created_at
  ) VALUES
  (
    v_operations_decision,'DECISION',v_proposal,1,v_approval_digest,
    v_operations_assignment,3,1,'operational_owner',v_operations_reviewer,
    'actions.review','STEP_UP',v_operations_step_up,
    v_operations_step_up_action_digest,v_operations_step_up_receipt_digest,
    v_operations_step_up_receipt_canonical,1,
    v_operations_decided_at-interval '1 second',
    v_operations_decided_at+interval '4 minutes',
    v_operations_assertion_jti,v_operations_step_up_action_digest,
    v_operations_idempotency_digest,'APPROVE',NULL,NULL,NULL,NULL,
    'TEST_ONLY_RETENTION_APPROVAL',v_operations_reason,
    pg_temp.r6d_sha256_text(v_operations_reason),
    v_operations_decision_payload,v_operations_decision_payload_canonical,
    v_operations_decision_receipt,v_operations_decision_receipt_canonical,
    v_operations_conflict,v_operations_conflict_digest,'ACTION_PROPOSAL',
    v_proposal,1,v_approval_digest,'CLEAR',v_due_at,NULL,
    v_operations_quorum_snapshot_digest,true,false,'PENDING_QUORUM',
    '{}'::uuid[],NULL,v_operations_decision_receipt_digest,v_request_id,
    v_operations_audit,v_operations_decided_at,v_operations_decided_at
  ),
  (
    v_legal_decision,'DECISION',v_proposal,1,v_approval_digest,
    v_legal_assignment,3,1,'legal_owner',v_legal_reviewer,'actions.review',
    'STEP_UP',v_legal_step_up,v_legal_step_up_action_digest,
    v_legal_step_up_receipt_digest,v_legal_step_up_receipt_canonical,1,
    v_legal_decided_at-interval '1 second',
    v_legal_decided_at+interval '4 minutes',v_legal_assertion_jti,
    v_legal_step_up_action_digest,v_legal_idempotency_digest,'APPROVE',
    NULL,NULL,NULL,NULL,'TEST_ONLY_RETENTION_APPROVAL',v_legal_reason,
    pg_temp.r6d_sha256_text(v_legal_reason),v_legal_decision_payload,
    v_legal_decision_payload_canonical,v_legal_decision_receipt,
    v_legal_decision_receipt_canonical,v_legal_conflict,
    v_legal_conflict_digest,'ACTION_PROPOSAL',v_proposal,1,
    v_approval_digest,'CLEAR',v_due_at,NULL,v_legal_quorum_snapshot_digest,
    true,true,'APPROVED','{}'::uuid[],v_effect,
    v_legal_decision_receipt_digest,v_request_id,v_legal_audit,
    v_legal_decided_at,v_legal_decided_at
  );

  INSERT INTO ops.outbox(
    id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,
    occurred_at,available_at,published_at,attempt_count,last_error
  ) VALUES
  (
    v_authorized_outbox,'action_execution',v_effect::text,1,
    'action.execution_authorized.v1',jsonb_build_object(
      'executionId',v_effect,'generation',1,'actionKind','RETENTION_SCHEDULE',
      'decisionDigest',v_legal_decision_receipt_digest,
      'executionDigest',v_execution_digest,
      'targetCommand','private.CreateRecordClassScheduleRevision',
      'targetRequestSha256',v_target_request_digest,
      'expiresAt',v_proposal_expires_at
    ),v_authorized_at,v_authorized_at,NULL,0,NULL
  ),
  (
    v_completed_outbox,'action_execution',v_effect::text,2,
    'action.execution_completed.v1',jsonb_build_object(
      'executionId',v_effect,'generation',1,'stateVersion',2,
      'terminalOrReconciliationState','SUCCEEDED',
      'executionDigest',v_execution_digest,'receiptSequence',2,
      'receiptDigest',v_terminal_receipt_digest,'costFactIds','[]'::jsonb
    ),v_succeeded_at,v_succeeded_at,NULL,0,NULL
  ),
  (
    v_schedule_outbox,'record_class_schedule',v_schedule::text,1,
    'retention.schedule_revised.v1',jsonb_build_object(
      'recordClass',p_record_class,'revision',1,
      'scheduleDigest',v_schedule_digest,'policyDigest',v_policy_digest,
      'effectiveAt',v_effective_at,'reviewExpiresAt',v_review_expires_at
    ),v_succeeded_at,v_succeeded_at,NULL,0,NULL
  );

  INSERT INTO ops.execution_authorizations(
    id,execution_id,generation,authorization_kind,proposal_id,
    proposal_version,action_kind,approval_digest,counted_decision_ids,
    counted_decision_receipt_digests,counted_decision_set_digest,
    terminal_decision_id,terminal_decision_receipt_digest,executor_id,
    transport,required_capability,target_request_schema_version,
    target_request_encrypted,target_request_sha256,rendered_bytes_digest,
    effect_boundary,provider_config_id,provider_config_version,
    provider_configuration_digest,provider_idempotency_key_sha256,
    cost_class,budget_reservation_id,budget_reservation_digest,
    cancellation_generation,command_idempotency_key_sha256,
    execution_binding,execution_binding_canonical,execution_digest,
    retry_of_generation,safe_retry_proof,safe_retry_proof_canonical,
    safe_retry_proof_digest,retry_reason_code,retry_reason,
    retry_reason_digest,requested_by_actor_id,request_id,audit_event_id,
    outbox_id,authorized_at,expires_at
  ) VALUES (
    v_authorization,v_effect,1,'INITIAL_APPROVAL',v_proposal,1,
    'RETENTION_SCHEDULE',v_approval_digest,v_counted_decision_ids,
    v_counted_receipt_digests,v_counted_decision_set_digest,
    v_legal_decision,v_legal_decision_receipt_digest,
    'private.CreateRecordClassScheduleRevision','PRIVATE_APPLICATION_COMMAND',
    'retention.policy.manage','action-payload.v1',v_payload_encrypted,
    v_target_request_digest,v_target_request_digest,'DATABASE_ONLY',
    NULL,NULL,v_database_only_digest,v_no_provider_key,'NO_PAID_EGRESS',
    NULL,v_no_budget_digest,0,v_effect_idempotency_digest,
    v_execution_binding,v_execution_binding_canonical,v_execution_digest,
    NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,v_request_id,
    v_authorization_audit,v_authorized_outbox,v_authorized_at,
    v_proposal_expires_at
  );

  INSERT INTO ops.execution_attempts(
    id,execution_id,generation,attempt_state,state_version,
    dispatch_ordinal,run_after,lease_owner,lease_token,lease_expires_at,
    fencing_token,target_request_sha256,rendered_bytes_digest,
    provider_config_id,provider_config_version,
    provider_configuration_digest,provider_idempotency_key_sha256,
    budget_reservation_id,budget_reservation_digest,
    provider_acknowledgement_digest,provider_lookup_receipt_digest,
    terminal_proof_digest,last_error_code,last_error_detail_digest,
    cancel_requested_at,cancel_reason_digest,reconciliation_attempt_count,
    next_reconcile_at,incident_id,actual_amount,actual_currency,
    last_receipt_sequence,last_receipt_digest,claimed_at,
    dispatch_started_at,provider_accepted_at,completed_at,created_at,updated_at
  ) VALUES (
    v_attempt,v_effect,1,'SUCCEEDED',2,NULL,v_authorized_at,NULL,NULL,NULL,0,
    v_target_request_digest,v_target_request_digest,NULL,NULL,
    v_database_only_digest,v_no_provider_key,NULL,v_no_budget_digest,NULL,
    NULL,v_execution_proof_digest,NULL,NULL,NULL,NULL,0,NULL,NULL,NULL,NULL,2,
    v_terminal_receipt_digest,NULL,NULL,NULL,v_succeeded_at,v_authorized_at,
    v_succeeded_at
  );

  INSERT INTO ops.execution_receipts(
    id,execution_id,generation,attempt_id,receipt_sequence,receipt_kind,
    mutates_aggregate_state,prior_aggregate_state,aggregate_state,
    aggregate_state_version,prior_attempt_state,attempt_state,fencing_token,
    cancellation_generation,provider_acknowledgement_digest,
    provider_observation_digest,proof_kind,proof_digest,receipt_payload,
    receipt_payload_canonical,actual_amount,actual_currency,cost_event_ids,
    budget_reservation_id,budget_reservation_digest,request_id,
    audit_event_id,outbox_id,observed_at,prior_receipt_digest,
    receipt_digest,created_at
  ) VALUES
  (
    v_queued_receipt,v_effect,1,v_attempt,1,'AUTHORIZATION_QUEUED',true,
    NULL,'QUEUED',1,NULL,'QUEUED',0,0,NULL,NULL,'NO_EGRESS',
    v_target_request_digest,v_queued_receipt_payload,
    v_queued_receipt_canonical,NULL,NULL,'{}'::uuid[],NULL,
    v_no_budget_digest,v_request_id,v_authorization_audit,
    v_authorized_outbox,v_authorized_at,NULL,v_queued_receipt_digest,
    v_authorized_at
  ),
  (
    v_terminal_receipt,v_effect,1,v_attempt,2,'EFFECT_SUCCEEDED',true,
    'QUEUED','SUCCEEDED',2,'QUEUED','SUCCEEDED',0,0,NULL,NULL,'NO_EGRESS',
    v_execution_proof_digest,v_terminal_receipt_payload,
    v_terminal_receipt_canonical,NULL,NULL,'{}'::uuid[],NULL,
    v_no_budget_digest,v_request_id,v_execution_audit,v_completed_outbox,
    v_succeeded_at,v_queued_receipt_digest,v_terminal_receipt_digest,
    v_succeeded_at
  );

  INSERT INTO ops.record_class_schedules(
    id,record_class,revision,supersedes_schedule_id,owner_team,purpose,
    lawful_basis,lawful_basis_review_digest,trigger_kind,
    active_duration_seconds,backup_duration_seconds,location_codes,
    derivative_record_classes,terminal_action,hold_behavior,
    restore_suppression_behavior,policy_digest,action_proposal_id,
    action_proposal_version,approval_digest,operational_action_decision_id,
    operational_action_decision_receipt_digest,legal_action_decision_id,
    legal_action_decision_receipt_digest,counted_decision_set_digest,
    action_execution_id,action_execution_generation,action_execution_digest,
    action_execution_receipt_id,action_execution_receipt_digest,
    effective_at,review_expires_at,schedule_digest,created_at
  ) VALUES (
    v_schedule,p_record_class,1,NULL,v_owner_team,v_purpose,v_lawful_basis,
    v_lawful_basis_review_digest,v_trigger_kind,
    v_active_duration_seconds,v_backup_duration_seconds,
    ARRAY['KR']::text[],'{}'::text[],v_terminal_action,v_hold_behavior,
    v_restore_suppression_behavior,v_policy_digest,v_proposal,1,
    v_approval_digest,
    v_operations_decision,v_operations_decision_receipt_digest,
    v_legal_decision,v_legal_decision_receipt_digest,
    v_counted_decision_set_digest,v_effect,1,v_execution_digest,
    v_terminal_receipt,v_terminal_receipt_digest,v_effective_at,
    v_review_expires_at,v_schedule_digest,v_succeeded_at
  );
END
$$;

CREATE TEMP TABLE r6d_approved_policy_fixture_classes(
  ordinal integer PRIMARY KEY,
  record_class text NOT NULL UNIQUE
) ON COMMIT DROP;

INSERT INTO r6d_approved_policy_fixture_classes(ordinal,record_class) VALUES
  (1,'AGENT_RUNTIME_POLICY'),
  (2,'AGENT_RUNTIME_INITIATION_RECEIPT'),
  (3,'AGENCY_MASTER'),
  (4,'SUPPLIER_MASTER'),
  (5,'AGENCY_IDENTIFIER'),
  (6,'SUPPLIER_IDENTIFIER'),
  (7,'ENTITY_ALIAS'),
  (8,'RELATIONSHIP_PERSON_CONTEXT'),
  (9,'RELATIONSHIP_PERSON_TOPOLOGY'),
  (10,'ENTITY_RETENTION_SNAPSHOT'),
  (11,'NAMED_PERSON_PUBLICATION_GOVERNANCE'),
  (12,'RESPONSE_IDENTITY_GOVERNANCE'),
  (13,'PERSON_ERASURE_GOVERNANCE'),
  (14,'LEGAL_HOLD_GOVERNANCE'),
  (15,'PRIVACY_REQUEST'),
  (16,'PRIVACY_REQUEST_TOKEN'),
  (17,'PRIVACY_REQUEST_NOTICE'),
  (18,'PRIVACY_REQUEST_EXECUTION'),
  (19,'PRIVACY_REQUEST_SEALED_CONTENT');

-- The fixture follows the database authority set instead of preserving a
-- second numeric count.  The two agent-runtime classes predate the R6d
-- catalog; every remaining class must come from that immutable catalog.
DO $fixture_authority_set$
BEGIN
  IF EXISTS (
    WITH required(record_class) AS (
      SELECT record_class
      FROM ops.r6d_record_class_catalog
      WHERE authority_version='supervisor-decision-v1'
      UNION ALL
      VALUES
        ('AGENT_RUNTIME_POLICY'::text),
        ('AGENT_RUNTIME_INITIATION_RECEIPT'::text)
    )
    (
      SELECT record_class FROM r6d_approved_policy_fixture_classes
      EXCEPT
      SELECT record_class FROM required
    )
    UNION ALL
    (
      SELECT record_class FROM required
      EXCEPT
      SELECT record_class FROM r6d_approved_policy_fixture_classes
    )
  ) THEN
    RAISE EXCEPTION 'r6d_test_policy_fixture_authority_set_mismatch'
      USING ERRCODE='55000';
  END IF;
END
$fixture_authority_set$;

SELECT pg_temp.install_r6d_retention_fixture(record_class,ordinal)
FROM r6d_approved_policy_fixture_classes
ORDER BY ordinal;

-- Explicit TEST_ONLY access policy for disposable privacy-request runtime
-- probes.  These TTLs are not an operational default or seed; the production
-- preflight rejects this authority and service sessions cannot select it.
DO $privacy_access_policy$
DECLARE
  v_policy_id constant uuid :=
    pg_temp.r6d_fixture_uuid(
      'PRIVACY_REQUEST_SEALED_CONTENT','privacy-access-policy'
    );
  v_revision constant bigint := 1;
  v_authority constant text := 'TEST_ONLY';
  v_policy_version constant text := 'test-only-r6d-v1';
  v_effective_at constant timestamptz := '2026-01-01 00:00:00+00';
  v_review_expires_at constant timestamptz := '2099-01-01 00:00:00+00';
  v_payload jsonb;
  v_canonical bytea;
  v_policy_digest char(64);
  v_binding jsonb;
  v_binding_digest char(64);
BEGIN
  v_payload:=jsonb_build_object(
    'schemaVersion','privacy-request-receipt-access-policy-v1',
    'tokenTtlSeconds',1800,
    'readOnlySessionTtlSeconds',900,
    'cookieProfileId','privacy_request_receipt',
    'cookieName','gurine_privacy_request_receipt_session',
    'cookiePath','/privacy',
    'allowedOperations',jsonb_build_array('getPrivacyRequest')
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_policy_digest:=encode(
    extensions.digest(v_canonical,'sha256'),'hex'
  );
  v_binding:=jsonb_build_object(
    'schemaVersion','privacy-access-policy-binding.v1',
    'policyId',v_policy_id,
    'revision',v_revision,
    'state','APPROVED',
    'authority',v_authority,
    'policyVersion',v_policy_version,
    'policyDigest',btrim(v_policy_digest),
    'bffIssuer','public-web',
    'sameSite','LAX',
    'secure',true,
    'httpOnly',true,
    'effectiveAt',v_effective_at,
    'reviewExpiresAt',v_review_expires_at
  );
  v_binding_digest:=pg_temp.r6d_sha256_json(v_binding);

  INSERT INTO ops.privacy_request_access_policies_v1(
    policy_id,revision,state,authority,policy_version,allowed_operation,
    bff_issuer,cookie_profile_id,cookie_name,cookie_path,same_site,secure,
    http_only,token_ttl_seconds,read_only_session_ttl_seconds,
    policy_payload,policy_canonical,policy_digest,binding_digest,
    effective_at,review_expires_at,created_at
  ) VALUES (
    v_policy_id,v_revision,'APPROVED',v_authority,v_policy_version,
    'getPrivacyRequest','public-web','privacy_request_receipt',
    'gurine_privacy_request_receipt_session','/privacy','LAX',true,true,
    1800,900,v_payload,v_canonical,v_policy_digest,v_binding_digest,
    v_effective_at,v_review_expires_at,v_effective_at
  );

  IF (SELECT count(*) FROM ops.privacy_request_access_policies_v1
      WHERE policy_id=v_policy_id AND revision=v_revision
        AND authority='TEST_ONLY'
        AND token_ttl_seconds=1800
        AND read_only_session_ttl_seconds=900
        AND policy_payload=v_payload
        AND policy_canonical=v_canonical
        AND policy_digest=v_policy_digest
        AND binding_digest=v_binding_digest)<>1 THEN
    RAISE EXCEPTION 'r6d_test_privacy_access_policy_invalid'
      USING ERRCODE='55000';
  END IF;
END
$privacy_access_policy$;

SET CONSTRAINTS ALL IMMEDIATE;

DO $validate$
DECLARE
  v_proposal_ids uuid[];
  v_record_classes text[];
  v_fixture_count bigint;
BEGIN
  SELECT array_agg(record_class ORDER BY ordinal),count(*)
  INTO STRICT v_record_classes,v_fixture_count
  FROM r6d_approved_policy_fixture_classes;
  SELECT array_agg(pg_temp.r6d_fixture_uuid(record_class,'proposal')
                   ORDER BY ordinal)
  INTO STRICT v_proposal_ids
  FROM r6d_approved_policy_fixture_classes;

  IF (SELECT count(*) FROM ops.action_proposals
      WHERE id=ANY(v_proposal_ids)) <> v_fixture_count
     OR (SELECT count(*) FROM ops.action_proposal_versions
         WHERE proposal_id=ANY(v_proposal_ids)) <> v_fixture_count
     OR (SELECT count(*)
         FROM ops.action_approval_retention_schedule_details
         WHERE proposal_id=ANY(v_proposal_ids)) <> v_fixture_count
     OR (SELECT count(*) FROM editorial.conflict_snapshots
         WHERE target_type='ACTION_PROPOSAL'
           AND target_id=ANY(ARRAY(
             SELECT proposal_id::text FROM unnest(v_proposal_ids)
             AS proposal(proposal_id)
           ))) <> 2*v_fixture_count
     OR (SELECT count(*) FROM ops.action_review_assignments
         WHERE proposal_id=ANY(v_proposal_ids)) <> 2*v_fixture_count
     OR (SELECT count(*) FROM ops.action_decisions
         WHERE proposal_id=ANY(v_proposal_ids)) <> 2*v_fixture_count
     OR (SELECT count(*) FROM ops.in_flight_effects
         WHERE action_proposal_id=ANY(v_proposal_ids)) <> v_fixture_count
     OR (SELECT count(*) FROM ops.execution_authorizations
         WHERE proposal_id=ANY(v_proposal_ids)) <> v_fixture_count
     OR (SELECT count(*) FROM ops.execution_attempts AS attempt
         JOIN ops.in_flight_effects AS effect
           ON effect.id=attempt.execution_id
         WHERE effect.action_proposal_id=ANY(v_proposal_ids))
           <> v_fixture_count
     OR (SELECT count(*) FROM ops.execution_receipts AS receipt
         JOIN ops.in_flight_effects AS effect
           ON effect.id=receipt.execution_id
         WHERE effect.action_proposal_id=ANY(v_proposal_ids))
           <> 2*v_fixture_count
     OR (SELECT count(*) FROM ops.record_class_schedules
         WHERE record_class=ANY(v_record_classes)) <> v_fixture_count
     OR (SELECT count(*) FROM ops.step_up_authorizations AS step_up
         JOIN ops.action_decisions AS decision
           ON decision.step_up_authorization_id=step_up.id
         WHERE decision.proposal_id=ANY(v_proposal_ids))
           <> 2*v_fixture_count
     OR (SELECT count(*) FROM ops.outbox AS outbox
         WHERE (
           outbox.aggregate_type='action_execution'
           AND outbox.aggregate_id=ANY(ARRAY(
             SELECT effect.id::text
             FROM ops.in_flight_effects AS effect
             WHERE effect.action_proposal_id=ANY(v_proposal_ids)
           ))
         ) OR (
           outbox.aggregate_type='record_class_schedule'
           AND outbox.aggregate_id=ANY(ARRAY(
             SELECT schedule.id::text
             FROM ops.record_class_schedules AS schedule
             WHERE schedule.record_class=ANY(v_record_classes)
           ))
         )) <> 3*v_fixture_count THEN
    RAISE EXCEPTION 'r6d_retention_fixture_cardinality_invalid';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM ops.action_proposals AS proposal
    JOIN ops.action_proposal_versions AS version
      ON version.proposal_id=proposal.id
     AND version.version=proposal.current_version
    JOIN ops.action_approval_retention_schedule_details AS detail
      ON detail.proposal_id=version.proposal_id
     AND detail.proposal_version=version.version
    WHERE proposal.id=ANY(v_proposal_ids)
      AND (
        proposal.action_kind IS DISTINCT FROM 'RETENTION_SCHEDULE'
        OR proposal.origin_kind IS DISTINCT FROM 'HUMAN'
        OR proposal.target_type IS DISTINCT FROM 'RECORD_CLASS'
        OR proposal.target_id IS DISTINCT FROM detail.record_class
        OR proposal.current_version IS DISTINCT FROM 1
        OR version.state IS DISTINCT FROM 'APPROVED'
        OR version.payload_schema_version IS DISTINCT FROM 'action-payload.v1'
        OR version.content_digest IS DISTINCT FROM version.target_request_digest
        OR version.preview_digest IS DISTINCT FROM
           version.approval_binding->>'approvalSubjectDigest'
        OR (SELECT count(*)
            FROM jsonb_object_keys(version.approval_binding)) <> 32
        OR version.approval_binding IS DISTINCT FROM jsonb_build_object(
          'schemaVersion','approval-binding.v1',
          'proposalId',proposal.id,'proposalVersion',version.version,
          'actionKind',proposal.action_kind,
          'originDigest',proposal.origin_digest,
          'contentDigest',version.content_digest,
          'rationaleDigest',version.rationale_digest,
          'targetType',proposal.target_type,'targetId',proposal.target_id,
          'targetVersion',proposal.target_version,
          'targetDigest',proposal.target_digest,
          'objectScopeDigest',proposal.object_scope_digest,
          'operationId',version.operation_id,
          'requiredCapability',version.required_capability,
          'targetRequestDigest',version.target_request_digest,
          'previewId',version.preview_id,
          'approvalSubjectDigest',version.preview_digest,
          'evidenceSetDigest',version.evidence_set_digest,
          'contraryEvidenceSetDigest',version.contrary_evidence_set_digest,
          'uncertaintySetDigest',version.uncertainty_set_digest,
          'riskAssessmentDigest',version.risk_assessment_digest,
          'policySnapshotDigest',version.policy_snapshot_digest,
          'conflictSnapshotDigest',version.conflict_snapshot_digest,
          'expectedEffectDigest',version.expected_effect_digest,
          'reversible',version.reversible,
          'quorumPlanDigest',version.quorum_plan_digest,
          'effectIdempotencyKeySha256',
            version.effect_idempotency_key_sha256,
          'notBefore',version.not_before,'expiresAt',version.expires_at,
          'actionDetailKind',version.action_detail_kind,
          'actionDetail',version.action_detail,
          'actionDetailDigest',version.action_detail_digest
        )
        OR convert_from(version.approval_binding_canonical,'UTF8')::jsonb
           IS DISTINCT FROM version.approval_binding
        OR version.approval_digest IS DISTINCT FROM encode(
          extensions.digest(version.approval_binding_canonical,'sha256'),'hex'
        )
        OR (SELECT count(*)
            FROM jsonb_object_keys(version.action_detail)) <> 16
        OR version.action_detail IS DISTINCT FROM jsonb_build_object(
          'kind','RETENTION_SCHEDULE','recordClass',detail.record_class,
          'expectedScheduleRevision',detail.expected_schedule_revision,
          'currentScheduleDigest',detail.current_schedule_digest,
          'purposeDigest',detail.purpose_digest,
          'lawfulBasisDigest',detail.lawful_basis_digest,
          'trigger',detail.trigger_kind,
          'activeDurationSeconds',detail.active_duration_seconds,
          'backupDurationSeconds',detail.backup_duration_seconds,
          'locationSetDigest',detail.location_set_digest,
          'terminalAction',detail.terminal_action,
          'holdBehavior',detail.hold_behavior,
          'restoreSuppressionBehavior',detail.restore_suppression_behavior,
          'currentLegalHoldSetDigest',detail.current_legal_hold_set_digest,
          'effectiveAt',detail.effective_at,
          'reviewExpiresAt',detail.review_expires_at
        )
        OR convert_from(version.action_detail_canonical,'UTF8')::jsonb
           IS DISTINCT FROM jsonb_build_object(
             'actionDetailKind','RETENTION_SCHEDULE',
             'actionDetail',version.action_detail
           )
        OR detail.detail_binding_canonical IS DISTINCT FROM
           version.action_detail_canonical
        OR detail.action_detail_digest IS DISTINCT FROM
           version.action_detail_digest
        OR version.action_detail_digest IS DISTINCT FROM encode(
          extensions.digest(version.action_detail_canonical,'sha256'),'hex'
        )
        OR detail.current_schedule_digest IS DISTINCT FROM
           pg_temp.r6d_sha256_json(jsonb_build_object(
             'schemaVersion','current-record-class-schedule-head.v1',
             'recordClass',detail.record_class,'revision',0,
             'scheduleId',NULL,'scheduleDigest',NULL
           ))
      )
  ) THEN
    RAISE EXCEPTION 'r6d_retention_fixture_approval_binding_invalid';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM ops.action_decisions AS decision
    JOIN ops.action_review_assignments AS assignment
      ON assignment.id=decision.assignment_id
    JOIN editorial.conflict_snapshots AS conflict
      ON conflict.id=decision.conflict_snapshot_id
    JOIN ops.step_up_authorizations AS step_up
      ON step_up.id=decision.step_up_authorization_id
    JOIN ops.sessions AS session ON session.id=step_up.session_id
    WHERE decision.proposal_id=ANY(v_proposal_ids)
      AND (
        decision.record_kind IS DISTINCT FROM 'DECISION'
        OR decision.decision_kind IS DISTINCT FROM 'APPROVE'
        OR decision.assurance IS DISTINCT FROM 'STEP_UP'
        OR decision.asserted_required_capability IS DISTINCT FROM
           'actions.review'
        OR decision.counts_toward_quorum IS DISTINCT FROM true
        OR (SELECT count(*)
            FROM jsonb_object_keys(decision.decision_payload)) <> 4
        OR decision.decision_payload IS DISTINCT FROM jsonb_build_object(
          'kind','APPROVE','reasonCode',decision.reason_code,
          'reason',decision.reason,'attestExactPreview',true
        )
        OR convert_from(decision.decision_payload_canonical,'UTF8')::jsonb
           IS DISTINCT FROM decision.decision_payload
        OR (SELECT count(*)
            FROM jsonb_object_keys(decision.decision_receipt_binding)) <> 29
        OR decision.decision_receipt_binding IS DISTINCT FROM
           jsonb_build_object(
             'schemaVersion','action-decision-receipt-binding.v1',
             'recordKind',decision.record_kind,'decisionId',decision.id,
             'proposalId',decision.proposal_id,
             'proposalVersion',decision.proposal_version,
             'approvalDigest',decision.approval_digest,
             'assignmentId',decision.assignment_id,
             'assignmentVersion',decision.assignment_version,
             'assignmentGeneration',decision.assignment_generation,
             'slotKind',decision.slot_kind,
             'decisionKind',decision.decision_kind,
             'actorId',decision.actor_id,
             'assertedRequiredCapability',
               decision.asserted_required_capability,
             'assurance',decision.assurance,
             'actorAssertionJti',decision.actor_assertion_jti,
             'actorActionDigest',decision.actor_action_digest,
             'stepUpAuthorizationId',decision.step_up_authorization_id,
             'stepUpAuthorizationReceiptDigest',
               decision.step_up_authorization_receipt_digest,
             'reasonCode',decision.reason_code,
             'reasonDigest',decision.reason_digest,
             'conflictSnapshotDigest',decision.conflict_snapshot_digest,
             'conflictDeclarationId',decision.conflict_declaration_id,
             'quorumSnapshotDigest',decision.quorum_snapshot_digest,
             'requestId',decision.request_id,
             'idempotencyKeySha256',decision.idempotency_key_sha256,
             'auditEventId',decision.audit_event_id,
             'decidedAt',decision.decided_at,
             'withdrawnDecisionId',decision.withdrawn_decision_id,
             'withdrawnDecisionReceiptDigest',
               decision.withdrawn_decision_receipt_digest
           )
        OR convert_from(
             decision.decision_receipt_binding_canonical,'UTF8'
           )::jsonb IS DISTINCT FROM decision.decision_receipt_binding
        OR decision.receipt_digest IS DISTINCT FROM encode(
          extensions.digest(
            decision.decision_receipt_binding_canonical,'sha256'
          ),'hex'
        )
        OR decision.reason_digest IS DISTINCT FROM
           pg_temp.r6d_sha256_text(decision.reason)
        OR assignment.version IS DISTINCT FROM decision.assignment_version
        OR assignment.assignment_generation IS DISTINCT FROM
           decision.assignment_generation
        OR assignment.slot_id IS DISTINCT FROM decision.slot_kind
        OR assignment.reviewer_id IS DISTINCT FROM decision.actor_id
        OR assignment.required_capability IS DISTINCT FROM
           'retention.policy.manage'
        OR assignment.approve_assurance IS DISTINCT FROM 'STEP_UP'
        OR assignment.state IS DISTINCT FROM 'COMPLETED'
        OR assignment.assignment_digest IS DISTINCT FROM
           pg_temp.r6d_sha256_json(jsonb_build_object(
             'schemaVersion','action-review-assignment.v1',
             'assignmentId',assignment.id,
             'proposalId',assignment.proposal_id,
             'proposalVersion',assignment.proposal_version,
             'approvalDigest',assignment.approval_digest,
             'assignmentGeneration',assignment.assignment_generation,
             'slotId',assignment.slot_id,
             'slotOrdinal',assignment.slot_ordinal,
             'requiredCapability',assignment.required_capability,
             'approveAssurance',assignment.approve_assurance,
             'allowedRoles',to_jsonb(assignment.allowed_role_codes),
             'reviewerId',assignment.reviewer_id,
             'reviewerRoleSnapshotDigest',
               assignment.reviewer_role_snapshot_digest,
             'eligibilitySnapshotDigest',
               assignment.eligibility_snapshot_digest,
             'conflictSnapshotId',assignment.conflict_snapshot_id,
             'conflictSnapshotDigest',assignment.conflict_snapshot_digest,
             'excludedActorIds',to_jsonb(assignment.excluded_actor_ids),
             'exclusionSetDigest',assignment.exclusion_set_digest,
             'quorumPlanDigest',assignment.quorum_plan_digest,
             'dueAt',assignment.due_at
           ))
        OR conflict.snapshot_sha256 IS DISTINCT FROM
           pg_temp.r6d_sha256_json(jsonb_build_object(
             'schemaVersion','conflict-snapshot.v1',
             'conflictSnapshotId',conflict.id,
             'subjectActorId',conflict.subject_actor_id,
             'targetType',conflict.target_type,'targetId',conflict.target_id,
             'targetVersion',conflict.target_version,
             'targetDigest',conflict.target_digest,
             'operationId',conflict.operation_id,
             'actionKind',conflict.action_kind,
             'candidateRole',conflict.candidate_role,
             'declarationIds',to_jsonb(conflict.declaration_ids),
             'declarationSetDigest',conflict.declaration_set_digest,
             'findingSet',conflict.finding_set,
             'findingSetDigest',conflict.finding_set_digest,
             'authorshipDigest',conflict.authorship_digest,
             'partyRecipientDigest',conflict.party_recipient_digest,
             'roleDigest',conflict.role_digest,
             'relationshipDigest',conflict.relationship_digest,
             'fundingCustomerDigest',conflict.funding_customer_digest,
             'policyDigest',conflict.policy_digest,
             'evaluationState',conflict.evaluation_state,
             'blockerCodes',to_jsonb(conflict.blocker_codes),
             'nonwaivableBlockerCount',conflict.nonwaivable_blocker_count,
             'evaluatedAt',conflict.evaluated_at,
             'validUntil',conflict.valid_until,
             'evaluatedByType',conflict.evaluated_by_type,
             'evaluatedById',conflict.evaluated_by_id,
             'classification',conflict.classification
           ))
        OR conflict.receipt_digest IS DISTINCT FROM
           pg_temp.r6d_sha256_json(jsonb_build_object(
             'schemaVersion','conflict-snapshot-receipt.v1',
             'conflictSnapshotId',conflict.id,
             'snapshotDigest',conflict.snapshot_sha256,
             'evaluationState',conflict.evaluation_state,
             'evaluatedAt',conflict.evaluated_at
           ))
        OR step_up.session_id IS DISTINCT FROM
           (convert_from(
             decision.step_up_authorization_receipt_canonical,'UTF8'
           )::jsonb->>'sessionId')::uuid
        OR step_up.action_digest IS DISTINCT FROM
           decision.actor_action_digest
        OR step_up.action_digest IS DISTINCT FROM
           decision.step_up_authorization_digest
        OR step_up.idempotency_key_sha256 IS DISTINCT FROM
           decision.idempotency_key_sha256
        OR step_up.expires_at IS DISTINCT FROM decision.step_up_expires_at
        OR step_up.assertion_issue_count IS DISTINCT FROM 1
        OR step_up.max_assertion_issues IS DISTINCT FROM 3
        OR step_up.last_issued_at IS DISTINCT FROM decision.step_up_issued_at
        OR step_up.created_at IS DISTINCT FROM
           decision.step_up_issued_at-interval '1 second'
        OR session.user_id IS DISTINCT FROM decision.actor_id
        OR session.revoked_at IS NOT NULL
        OR session.expires_at <= decision.decided_at
        OR convert_from(
             decision.step_up_authorization_receipt_canonical,'UTF8'
           )::jsonb IS DISTINCT FROM jsonb_build_object(
             'schemaVersion','step-up-authorization-receipt.v1',
             'authorizationId',step_up.id,
             'actionDigest',step_up.action_digest,
             'sessionId',step_up.session_id,
             'issueNumber',decision.step_up_issue_ordinal,
             'issuedAt',decision.step_up_issued_at,
             'expiresAt',decision.step_up_expires_at
           )
        OR decision.step_up_authorization_receipt_digest IS DISTINCT FROM
           encode(extensions.digest(
             decision.step_up_authorization_receipt_canonical,'sha256'
           ),'hex')
      )
  ) THEN
    RAISE EXCEPTION 'r6d_retention_fixture_decision_graph_invalid';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM ops.record_class_schedules AS schedule
    JOIN ops.action_proposals AS proposal
      ON proposal.id=schedule.action_proposal_id
    JOIN ops.action_proposal_versions AS version
      ON version.proposal_id=schedule.action_proposal_id
     AND version.version=schedule.action_proposal_version
    JOIN ops.action_decisions AS operational
      ON operational.id=schedule.operational_action_decision_id
    JOIN ops.action_decisions AS legal
      ON legal.id=schedule.legal_action_decision_id
    JOIN ops.action_review_assignments AS operational_assignment
      ON operational_assignment.id=operational.assignment_id
    JOIN ops.action_review_assignments AS legal_assignment
      ON legal_assignment.id=legal.assignment_id
    JOIN ops.in_flight_effects AS effect
      ON effect.id=schedule.action_execution_id
    JOIN ops.execution_authorizations AS exec_auth
      ON exec_auth.execution_id=effect.id
     AND exec_auth.generation=schedule.action_execution_generation
    JOIN ops.execution_attempts AS attempt
      ON attempt.execution_id=effect.id
     AND attempt.generation=exec_auth.generation
    JOIN ops.execution_receipts AS queued
      ON queued.execution_id=effect.id AND queued.receipt_sequence=1
    JOIN ops.execution_receipts AS terminal
      ON terminal.execution_id=effect.id AND terminal.receipt_sequence=2
    WHERE schedule.record_class=ANY(v_record_classes)
      AND (
        operational.slot_kind IS DISTINCT FROM 'operational_owner'
        OR legal.slot_kind IS DISTINCT FROM 'legal_owner'
        OR operational.actor_id=legal.actor_id
        OR proposal.created_by=ANY(ARRAY[
          operational.actor_id,legal.actor_id
        ])
        OR operational.quorum_satisfied_after IS DISTINCT FROM false
        OR operational.resulting_proposal_state IS DISTINCT FROM
           'PENDING_QUORUM'
        OR operational.execution_id IS NOT NULL
        OR legal.quorum_satisfied_after IS DISTINCT FROM true
        OR legal.resulting_proposal_state IS DISTINCT FROM 'APPROVED'
        OR legal.execution_id IS DISTINCT FROM effect.id
        OR proposal.last_receipt_digest IS DISTINCT FROM legal.receipt_digest
        OR version.terminal_receipt_digest IS DISTINCT FROM
           legal.receipt_digest
        OR exec_auth.counted_decision_ids IS DISTINCT FROM
           ARRAY[operational.id,legal.id]::uuid[]
        OR exec_auth.counted_decision_receipt_digests IS DISTINCT FROM (
          SELECT array_agg(receipt_digest ORDER BY receipt_digest COLLATE "C")
          FROM unnest(ARRAY[
            btrim(operational.receipt_digest),btrim(legal.receipt_digest)
          ]) AS counted(receipt_digest)
        )
        OR exec_auth.counted_decision_set_digest IS DISTINCT FROM
           pg_temp.r6d_sha256_json(jsonb_build_object(
             'decisionIds',to_jsonb(exec_auth.counted_decision_ids),
             'decisionReceiptDigests',
               to_jsonb(exec_auth.counted_decision_receipt_digests)
           ))
        OR exec_auth.terminal_decision_id IS DISTINCT FROM legal.id
        OR exec_auth.terminal_decision_receipt_digest IS DISTINCT FROM
           legal.receipt_digest
        OR (SELECT count(*)
            FROM jsonb_object_keys(exec_auth.execution_binding)) <> 41
        OR exec_auth.execution_binding IS DISTINCT FROM
           jsonb_build_object(
             'schemaVersion','execution-binding.v1',
             'executionId',exec_auth.execution_id,
             'generation',exec_auth.generation,
             'proposalId',exec_auth.proposal_id,
             'proposalVersion',exec_auth.proposal_version,
             'actionKind',exec_auth.action_kind,
             'approvalDigest',exec_auth.approval_digest,
             'approvalSubjectDigest',version.preview_digest,
             'countedDecisionIds',
               to_jsonb(exec_auth.counted_decision_ids),
             'countedDecisionReceiptDigests',
               to_jsonb(exec_auth.counted_decision_receipt_digests),
             'countedDecisionSetDigest',
               exec_auth.counted_decision_set_digest,
             'terminalDecisionId',exec_auth.terminal_decision_id,
             'terminalDecisionReceiptDigest',
               exec_auth.terminal_decision_receipt_digest,
             'executorId',exec_auth.executor_id,
             'transport',exec_auth.transport,
             'requiredCapability',exec_auth.required_capability,
             'requiredAssurance','STEP_UP',
             'targetRequestSchemaVersion',
               exec_auth.target_request_schema_version,
             'targetRequestSha256',exec_auth.target_request_sha256,
             'exactRenderedBytesDigest',exec_auth.rendered_bytes_digest,
             'effectIdempotencyKeySha256',
               exec_auth.command_idempotency_key_sha256,
             'providerConfigId',exec_auth.provider_config_id,
             'providerConfigVersion',exec_auth.provider_config_version,
             'providerConfigurationDigest',
               exec_auth.provider_configuration_digest,
             'providerIdempotencyKeySha256',
               exec_auth.provider_idempotency_key_sha256,
             'budgetReservationId',exec_auth.budget_reservation_id,
             'budgetReservationDigest',
               exec_auth.budget_reservation_digest,
             'policySnapshotDigest',effect.policy_digest,
             'killSwitchDigest',effect.kill_switch_digest,
             'rightsDigest',effect.rights_digest,
             'consentDigest',effect.consent_digest,
             'suppressionDigest',effect.suppression_digest,
             'conflictSnapshotDigest',effect.conflict_digest,
             'activationDigest',effect.activation_digest,
             'quorumPlanDigest',effect.quorum_plan_digest,
             'cancellationGeneration',exec_auth.cancellation_generation,
             'priorExecutionDigest',NULL,'safeRetryProofDigest',NULL,
             'notBefore',exec_auth.authorized_at,
             'authorizedAt',exec_auth.authorized_at,
             'expiresAt',exec_auth.expires_at
           )
        OR convert_from(exec_auth.execution_binding_canonical,'UTF8')::jsonb
           IS DISTINCT FROM exec_auth.execution_binding
        OR exec_auth.execution_digest IS DISTINCT FROM encode(
          extensions.digest(
            exec_auth.execution_binding_canonical,'sha256'
          ),'hex'
        )
        OR effect.effect_key_digest IS DISTINCT FROM
           exec_auth.command_idempotency_key_sha256
        OR effect.state IS DISTINCT FROM 'SUCCEEDED'
        OR effect.state_version IS DISTINCT FROM 2
        OR effect.last_receipt_sequence IS DISTINCT FROM 2
        OR effect.last_receipt_digest IS DISTINCT FROM terminal.receipt_digest
        OR attempt.attempt_state IS DISTINCT FROM 'SUCCEEDED'
        OR attempt.state_version IS DISTINCT FROM 2
        OR attempt.last_receipt_sequence IS DISTINCT FROM 2
        OR attempt.last_receipt_digest IS DISTINCT FROM terminal.receipt_digest
        OR attempt.terminal_proof_digest IS DISTINCT FROM terminal.proof_digest
        OR queued.receipt_kind IS DISTINCT FROM 'AUTHORIZATION_QUEUED'
        OR queued.prior_receipt_digest IS NOT NULL
        OR queued.aggregate_state IS DISTINCT FROM 'QUEUED'
        OR queued.attempt_state IS DISTINCT FROM 'QUEUED'
        OR terminal.receipt_kind IS DISTINCT FROM 'EFFECT_SUCCEEDED'
        OR terminal.prior_receipt_digest IS DISTINCT FROM
           queued.receipt_digest
        OR terminal.aggregate_state IS DISTINCT FROM 'SUCCEEDED'
        OR terminal.prior_aggregate_state IS DISTINCT FROM 'QUEUED'
        OR terminal.attempt_state IS DISTINCT FROM 'SUCCEEDED'
        OR terminal.prior_attempt_state IS DISTINCT FROM 'QUEUED'
        OR schedule.action_execution_digest IS DISTINCT FROM
           exec_auth.execution_digest
        OR schedule.action_execution_receipt_id IS DISTINCT FROM terminal.id
        OR schedule.action_execution_receipt_digest IS DISTINCT FROM
           terminal.receipt_digest
        OR schedule.operational_action_decision_receipt_digest IS DISTINCT FROM
           operational.receipt_digest
        OR schedule.legal_action_decision_receipt_digest IS DISTINCT FROM
           legal.receipt_digest
        OR schedule.counted_decision_set_digest IS DISTINCT FROM
           exec_auth.counted_decision_set_digest
        OR operational_assignment.allowed_role_codes IS DISTINCT FROM
           ARRAY['OPERATIONS']::text[]
        OR legal_assignment.allowed_role_codes IS DISTINCT FROM
           ARRAY['LEGAL_REVIEWER']::text[]
      )
  ) THEN
    RAISE EXCEPTION 'r6d_retention_fixture_execution_graph_invalid';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM ops.execution_receipts AS receipt
    JOIN ops.execution_authorizations AS exec_auth
      ON exec_auth.execution_id=receipt.execution_id
     AND exec_auth.generation=receipt.generation
    JOIN ops.execution_attempts AS attempt
      ON attempt.id=receipt.attempt_id
    JOIN ops.in_flight_effects AS effect
      ON effect.id=receipt.execution_id
    WHERE effect.action_proposal_id=ANY(v_proposal_ids)
      AND (
        (SELECT count(*)
         FROM jsonb_object_keys(receipt.receipt_payload)) <> 34
        OR receipt.receipt_payload IS DISTINCT FROM jsonb_build_object(
          'schemaVersion','execution-receipt-payload.v1',
          'receiptKind',receipt.receipt_kind,
          'executionId',receipt.execution_id,
          'generation',receipt.generation,
          'authorizationDigest',exec_auth.execution_digest,
          'attemptId',receipt.attempt_id,
          'receiptSequence',receipt.receipt_sequence,
          'priorReceiptDigest',receipt.prior_receipt_digest,
          'aggregateTransition',jsonb_build_object(
            'from',receipt.prior_aggregate_state,
            'to',receipt.aggregate_state
          ),
          'aggregateStateVersion',receipt.aggregate_state_version,
          'attemptTransition',jsonb_build_object(
            'from',receipt.prior_attempt_state,'to',receipt.attempt_state
          ),
          'attemptStateVersion',receipt.aggregate_state_version,
          'dispatchOrdinal',attempt.dispatch_ordinal,
          'fencingToken',receipt.fencing_token,
          'cancellationGeneration',receipt.cancellation_generation,
          'targetRequestSha256',exec_auth.target_request_sha256,
          'exactRenderedBytesDigest',exec_auth.rendered_bytes_digest,
          'effectIdempotencyKeySha256',
            exec_auth.command_idempotency_key_sha256,
          'providerConfigId',exec_auth.provider_config_id,
          'providerConfigVersion',exec_auth.provider_config_version,
          'providerConfigurationDigest',
            exec_auth.provider_configuration_digest,
          'providerIdempotencyKeySha256',
            exec_auth.provider_idempotency_key_sha256,
          'providerAcknowledgementDigest',
            receipt.provider_acknowledgement_digest,
          'providerObservationDigest',receipt.provider_observation_digest,
          'downstreamEffectIds','[]'::jsonb,
          'downstreamReceiptDigests','[]'::jsonb,
          'downstreamReceiptSetDigest',pg_temp.r6d_sha256_json(
            jsonb_build_object(
              'schemaVersion','downstream-receipt-set.v1',
              'members','[]'::jsonb
            )
          ),
          'proof',jsonb_build_object(
            'kind',receipt.proof_kind,'digest',receipt.proof_digest,
            'effectCertainty',CASE receipt.receipt_kind
              WHEN 'AUTHORIZATION_QUEUED' THEN 'DEFINITIVE_NOT_ACCEPTED'
              ELSE 'DEFINITIVE_SUCCEEDED'
            END
          ),
          'cost',jsonb_build_object(
            'costClass',exec_auth.cost_class,
            'actualAmount',receipt.actual_amount,
            'actualCurrency',receipt.actual_currency,
            'costEventIds',to_jsonb(receipt.cost_event_ids)
          ),
          'budget',jsonb_build_object(
            'reservationId',receipt.budget_reservation_id,
            'reservationDigest',receipt.budget_reservation_digest
          ),
          'requestId',receipt.request_id,
          'auditEventId',receipt.audit_event_id,
          'outboxId',receipt.outbox_id,'observedAt',receipt.observed_at
        )
        OR convert_from(receipt.receipt_payload_canonical,'UTF8')::jsonb
           IS DISTINCT FROM receipt.receipt_payload
        OR receipt.receipt_digest IS DISTINCT FROM encode(
          extensions.digest(receipt.receipt_payload_canonical,'sha256'),'hex'
        )
      )
  ) THEN
    RAISE EXCEPTION 'r6d_retention_fixture_receipt_payload_invalid';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM ops.record_class_schedules AS schedule
    JOIN ops.action_proposal_versions AS version
      ON version.proposal_id=schedule.action_proposal_id
     AND version.version=schedule.action_proposal_version
    JOIN ops.action_approval_retention_schedule_details AS detail
      ON detail.proposal_id=version.proposal_id
     AND detail.proposal_version=version.version
    WHERE schedule.record_class=ANY(v_record_classes)
      AND (
        detail.purpose_digest IS DISTINCT FROM
           pg_temp.r6d_sha256_text(schedule.purpose)
        OR detail.lawful_basis_digest IS DISTINCT FROM
           pg_temp.r6d_sha256_text(schedule.lawful_basis)
        OR detail.location_set_digest IS DISTINCT FROM
           pg_temp.r6d_sha256_json(jsonb_build_object(
             'schemaVersion','retention-location-set.v1',
             'locations',to_jsonb(schedule.location_codes)
           ))
        OR schedule.policy_digest IS DISTINCT FROM
           pg_temp.r6d_sha256_json(jsonb_build_object(
             'schemaVersion','record-class-retention-policy.v1',
             'recordClass',schedule.record_class,
             'ownerTeam',schedule.owner_team,'purpose',schedule.purpose,
             'purposeDigest',detail.purpose_digest,
             'lawfulBasis',schedule.lawful_basis,
             'lawfulBasisDigest',detail.lawful_basis_digest,
             'lawfulBasisReviewDigest',
               schedule.lawful_basis_review_digest,
             'trigger',schedule.trigger_kind,
             'activeDurationSeconds',schedule.active_duration_seconds,
             'backupDurationSeconds',schedule.backup_duration_seconds,
             'locationCodes',to_jsonb(schedule.location_codes),
             'locationSetDigest',detail.location_set_digest,
             'derivativeRecordClasses',
               to_jsonb(schedule.derivative_record_classes),
             'terminalAction',schedule.terminal_action,
             'holdBehavior',schedule.hold_behavior,
             'restoreSuppressionBehavior',
               schedule.restore_suppression_behavior,
             'effectiveAt',schedule.effective_at,
             'reviewExpiresAt',schedule.review_expires_at
           ))
        OR schedule.schedule_digest IS DISTINCT FROM
           pg_temp.r6d_sha256_json(jsonb_build_object(
             'schemaVersion','record-class-schedule.v1',
             'scheduleId',schedule.id,
             'recordClass',schedule.record_class,
             'revision',schedule.revision,
             'supersedesScheduleId',schedule.supersedes_schedule_id,
             'ownerTeam',schedule.owner_team,'purpose',schedule.purpose,
             'lawfulBasis',schedule.lawful_basis,
             'lawfulBasisReviewDigest',
               schedule.lawful_basis_review_digest,
             'triggerKind',schedule.trigger_kind,
             'activeDurationSeconds',schedule.active_duration_seconds,
             'backupDurationSeconds',schedule.backup_duration_seconds,
             'locationCodes',to_jsonb(schedule.location_codes),
             'derivativeRecordClasses',
               to_jsonb(schedule.derivative_record_classes),
             'terminalAction',schedule.terminal_action,
             'holdBehavior',schedule.hold_behavior,
             'restoreSuppressionBehavior',
               schedule.restore_suppression_behavior,
             'policyDigest',schedule.policy_digest,
             'actionProposalId',schedule.action_proposal_id,
             'actionProposalVersion',schedule.action_proposal_version,
             'approvalDigest',schedule.approval_digest,
             'operationalActionDecisionId',
               schedule.operational_action_decision_id,
             'operationalActionDecisionReceiptDigest',
               schedule.operational_action_decision_receipt_digest,
             'legalActionDecisionId',schedule.legal_action_decision_id,
             'legalActionDecisionReceiptDigest',
               schedule.legal_action_decision_receipt_digest,
             'countedDecisionSetDigest',
               schedule.counted_decision_set_digest,
             'actionExecutionId',schedule.action_execution_id,
             'actionExecutionGeneration',
               schedule.action_execution_generation,
             'actionExecutionDigest',schedule.action_execution_digest,
             'actionExecutionReceiptId',
               schedule.action_execution_receipt_id,
             'actionExecutionReceiptDigest',
               schedule.action_execution_receipt_digest,
             'effectiveAt',schedule.effective_at,
             'reviewExpiresAt',schedule.review_expires_at
           ))
      )
  ) THEN
    RAISE EXCEPTION 'r6d_retention_fixture_schedule_digest_invalid';
  END IF;

  IF EXISTS (
    WITH expected(proposal_id,record_class,cycle_start) AS (
      SELECT
        pg_temp.r6d_fixture_uuid(record_class,'proposal'),
        record_class,
        timestamptz '2026-01-01 00:00:00+00'
          +(ordinal-1)*interval '1 day'
      FROM r6d_approved_policy_fixture_classes
    )
    SELECT 1
    FROM expected
    JOIN ops.action_proposals AS proposal ON proposal.id=expected.proposal_id
    JOIN ops.action_proposal_versions AS version
      ON version.proposal_id=proposal.id AND version.version=1
    JOIN ops.action_approval_retention_schedule_details AS detail
      ON detail.proposal_id=proposal.id AND detail.proposal_version=1
    JOIN ops.action_decisions AS operational
      ON operational.proposal_id=proposal.id
     AND operational.slot_kind='operational_owner'
    JOIN ops.action_decisions AS legal
      ON legal.proposal_id=proposal.id AND legal.slot_kind='legal_owner'
    JOIN ops.action_review_assignments AS operational_assignment
      ON operational_assignment.id=operational.assignment_id
    JOIN ops.action_review_assignments AS legal_assignment
      ON legal_assignment.id=legal.assignment_id
    JOIN ops.in_flight_effects AS effect
      ON effect.action_proposal_id=proposal.id
    JOIN ops.execution_authorizations AS exec_auth
      ON exec_auth.execution_id=effect.id
    JOIN ops.execution_attempts AS attempt
      ON attempt.execution_id=effect.id
    JOIN ops.execution_receipts AS queued
      ON queued.execution_id=effect.id AND queued.receipt_sequence=1
    JOIN ops.execution_receipts AS terminal
      ON terminal.execution_id=effect.id AND terminal.receipt_sequence=2
    JOIN ops.record_class_schedules AS schedule
      ON schedule.action_proposal_id=proposal.id
    JOIN ops.step_up_authorizations AS operational_step_up
      ON operational_step_up.id=operational.step_up_authorization_id
    JOIN ops.step_up_authorizations AS legal_step_up
      ON legal_step_up.id=legal.step_up_authorization_id
    JOIN ops.outbox AS authorized_outbox
      ON authorized_outbox.id=exec_auth.outbox_id
    JOIN ops.outbox AS completed_outbox
      ON completed_outbox.id=terminal.outbox_id
    JOIN ops.outbox AS schedule_outbox
      ON schedule_outbox.aggregate_type='record_class_schedule'
     AND schedule_outbox.aggregate_id=schedule.id::text
     AND schedule_outbox.event_type='retention.schedule_revised.v1'
    WHERE proposal.created_at IS DISTINCT FROM expected.cycle_start
       OR proposal.updated_at IS DISTINCT FROM
          expected.cycle_start+interval '7 minutes'
       OR version.created_at IS DISTINCT FROM expected.cycle_start
       OR version.previewed_at IS DISTINCT FROM
          expected.cycle_start+interval '1 minute'
       OR version.submitted_at IS DISTINCT FROM
          expected.cycle_start+interval '2 minutes'
       OR version.due_at IS DISTINCT FROM
          expected.cycle_start+interval '1 day'
       OR version.terminal_at IS DISTINCT FROM
          expected.cycle_start+interval '7 minutes'
       OR version.updated_at IS DISTINCT FROM
          expected.cycle_start+interval '7 minutes'
       OR version.expires_at IS DISTINCT FROM
          expected.cycle_start+interval '7 days'
       OR detail.created_at IS DISTINCT FROM
          expected.cycle_start+interval '2 minutes'
       OR operational_assignment.created_at IS DISTINCT FROM
          expected.cycle_start+interval '2 minutes'
       OR operational_assignment.claimed_at IS DISTINCT FROM
          expected.cycle_start+interval '3 minutes'
       OR operational_assignment.terminal_at IS DISTINCT FROM
          expected.cycle_start+interval '6 minutes'
       OR legal_assignment.claimed_at IS DISTINCT FROM
          expected.cycle_start+interval '4 minutes'
       OR legal_assignment.terminal_at IS DISTINCT FROM
          expected.cycle_start+interval '7 minutes'
       OR operational.decided_at IS DISTINCT FROM
          expected.cycle_start+interval '6 minutes'
       OR legal.decided_at IS DISTINCT FROM
          expected.cycle_start+interval '7 minutes'
       OR effect.created_at IS DISTINCT FROM
          expected.cycle_start+interval '7 minutes'
       OR effect.run_after IS DISTINCT FROM
          expected.cycle_start+interval '7 minutes'
       OR effect.updated_at IS DISTINCT FROM
          expected.cycle_start+interval '8 minutes'
       OR effect.terminal_at IS DISTINCT FROM
          expected.cycle_start+interval '8 minutes'
       OR exec_auth.authorized_at IS DISTINCT FROM
          expected.cycle_start+interval '7 minutes'
       OR exec_auth.expires_at IS DISTINCT FROM
          expected.cycle_start+interval '7 days'
       OR attempt.created_at IS DISTINCT FROM
          expected.cycle_start+interval '7 minutes'
       OR attempt.completed_at IS DISTINCT FROM
          expected.cycle_start+interval '8 minutes'
       OR attempt.updated_at IS DISTINCT FROM
          expected.cycle_start+interval '8 minutes'
       OR queued.observed_at IS DISTINCT FROM
          expected.cycle_start+interval '7 minutes'
       OR queued.created_at IS DISTINCT FROM
          expected.cycle_start+interval '7 minutes'
       OR terminal.observed_at IS DISTINCT FROM
          expected.cycle_start+interval '8 minutes'
       OR terminal.created_at IS DISTINCT FROM
          expected.cycle_start+interval '8 minutes'
       OR schedule.record_class IS DISTINCT FROM expected.record_class
       OR schedule.created_at IS DISTINCT FROM
          expected.cycle_start+interval '8 minutes'
       OR schedule.effective_at IS DISTINCT FROM
          expected.cycle_start+interval '10 minutes'
       OR schedule.review_expires_at IS DISTINCT FROM
          timestamptz '2099-01-01 00:00:00+00'
       OR operational_step_up.created_at IS DISTINCT FROM
          expected.cycle_start+interval '5 minutes 58 seconds'
       OR legal_step_up.created_at IS DISTINCT FROM
          expected.cycle_start+interval '6 minutes 58 seconds'
       OR authorized_outbox.occurred_at IS DISTINCT FROM
          expected.cycle_start+interval '7 minutes'
       OR authorized_outbox.available_at IS DISTINCT FROM
          authorized_outbox.occurred_at
       OR completed_outbox.occurred_at IS DISTINCT FROM
          expected.cycle_start+interval '8 minutes'
       OR completed_outbox.available_at IS DISTINCT FROM
          completed_outbox.occurred_at
       OR schedule_outbox.occurred_at IS DISTINCT FROM
          expected.cycle_start+interval '8 minutes'
       OR schedule_outbox.available_at IS DISTINCT FROM
          schedule_outbox.occurred_at
       OR schedule.lawful_basis_review_digest IS DISTINCT FROM
          pg_temp.r6d_sha256_json(jsonb_build_object(
            'schemaVersion','lawful-basis-review-artifact.v1',
            'recordClass',schedule.record_class,
            'lawfulBasisDigest',detail.lawful_basis_digest,
            'decision','APPROVED_FOR_TEST',
            'reviewerRole','LEGAL_REVIEWER',
            'reviewedAt',expected.cycle_start-interval '1 day'
          ))
  ) THEN
    RAISE EXCEPTION 'r6d_retention_fixture_fixed_time_invalid';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM ops.action_decisions AS decision
    JOIN ops.action_review_assignments AS assignment
      ON assignment.id=decision.assignment_id
    WHERE decision.proposal_id=ANY(v_proposal_ids)
      AND (
        NOT EXISTS (
          SELECT 1
          FROM ops.user_roles AS user_role
          JOIN ops.roles AS role ON role.id=user_role.role_id
          JOIN ops.role_capabilities AS retention_capability
            ON retention_capability.role_id=role.id
           AND retention_capability.capability_code='retention.policy.manage'
          JOIN ops.role_capabilities AS review_capability
            ON review_capability.role_id=role.id
           AND review_capability.capability_code='actions.review'
          WHERE user_role.user_id=decision.actor_id
            AND user_role.revoked_at IS NULL
            AND role.code=CASE decision.slot_kind
              WHEN 'operational_owner' THEN 'OPERATIONS'
              WHEN 'legal_owner' THEN 'LEGAL_REVIEWER'
            END
        )
        OR assignment.reviewer_role_snapshot_digest IS DISTINCT FROM (
          SELECT pg_temp.r6d_sha256_json(jsonb_build_object(
            'schemaVersion','reviewer-role-snapshot.v1',
            'userId',decision.actor_id,'roleCode',role.code,
            'roleId',role.id,'capabilities',(
              SELECT jsonb_agg(
                capability.capability_code
                ORDER BY capability.capability_code
              )
              FROM ops.role_capabilities AS capability
              WHERE capability.role_id=role.id
            )
          ))
          FROM ops.roles AS role
          WHERE role.code=CASE decision.slot_kind
            WHEN 'operational_owner' THEN 'OPERATIONS'
            WHEN 'legal_owner' THEN 'LEGAL_REVIEWER'
          END
        )
      )
  ) THEN
    RAISE EXCEPTION 'r6d_retention_fixture_role_capability_invalid';
  END IF;

  IF EXISTS (
    WITH chain_members AS (
      SELECT schedule.record_class,
             'r6d-retention:'||lower(schedule.record_class) AS stream_key,
             1 AS ordinal,version.preview_audit_event_id AS event_id
      FROM ops.record_class_schedules AS schedule
      JOIN ops.action_proposal_versions AS version
        ON version.proposal_id=schedule.action_proposal_id
       AND version.version=schedule.action_proposal_version
      WHERE schedule.record_class=ANY(v_record_classes)
      UNION ALL
      SELECT schedule.record_class,
             'r6d-retention:'||lower(schedule.record_class),2,
             operational.audit_event_id
      FROM ops.record_class_schedules AS schedule
      JOIN ops.action_decisions AS operational
        ON operational.id=schedule.operational_action_decision_id
      WHERE schedule.record_class=ANY(v_record_classes)
      UNION ALL
      SELECT schedule.record_class,
             'r6d-retention:'||lower(schedule.record_class),3,
             legal.audit_event_id
      FROM ops.record_class_schedules AS schedule
      JOIN ops.action_decisions AS legal
        ON legal.id=schedule.legal_action_decision_id
      WHERE schedule.record_class=ANY(v_record_classes)
      UNION ALL
      SELECT schedule.record_class,
             'r6d-retention:'||lower(schedule.record_class),4,
             exec_auth.audit_event_id
      FROM ops.record_class_schedules AS schedule
      JOIN ops.execution_authorizations AS exec_auth
        ON exec_auth.execution_id=schedule.action_execution_id
       AND exec_auth.generation=schedule.action_execution_generation
      WHERE schedule.record_class=ANY(v_record_classes)
      UNION ALL
      SELECT schedule.record_class,
             'r6d-retention:'||lower(schedule.record_class),5,
             receipt.audit_event_id
      FROM ops.record_class_schedules AS schedule
      JOIN ops.execution_receipts AS receipt
        ON receipt.id=schedule.action_execution_receipt_id
      WHERE schedule.record_class=ANY(v_record_classes)
    ), ordered AS (
      SELECT member.*,event.*,
             lag(event.event_hash) OVER (
               PARTITION BY member.stream_key ORDER BY member.ordinal
             ) AS expected_previous_hash
      FROM chain_members AS member
      JOIN ops.audit_events AS event ON event.id=member.event_id
    )
    SELECT 1
    FROM ordered
    WHERE previous_event_hash IS DISTINCT FROM expected_previous_hash
       OR event_hash IS DISTINCT FROM pg_temp.r6d_sha256_text(
         COALESCE(expected_previous_hash,'')||jsonb_build_object(
           'id',id,'stream_key',stream_key,'occurred_at',occurred_at,
           'actor_type',actor_type,'actor_id',actor_id,
           'session_id',session_id,'action',action,
           'object_type',object_type,'object_id',object_id,
           'capability',capability,'outcome',outcome,'reason',reason,
           'request_id',request_id,'details',details,
           'previous_event_hash',expected_previous_hash
         )::text
       )
  ) OR EXISTS (
    SELECT 1
    FROM ops.record_class_schedules AS schedule
    LEFT JOIN ops.audit_chain_heads AS head
      ON head.stream_key='r6d-retention:'||lower(schedule.record_class)
    JOIN ops.execution_receipts AS terminal
      ON terminal.id=schedule.action_execution_receipt_id
    WHERE schedule.record_class=ANY(v_record_classes)
      AND (
        head.version IS DISTINCT FROM 5
        OR head.head_event_id IS DISTINCT FROM terminal.audit_event_id
      )
  ) THEN
    RAISE EXCEPTION 'r6d_retention_fixture_audit_chain_invalid';
  END IF;
END
$validate$;

-- These governance events prove the immutable approval and execution graph;
-- they are not scenario input for any runtime harness.  Defer only this
-- TEST_ONLY fixture's outbox rows so existing consumer count assertions stay
-- scoped to their own scenarios.
DO $isolate$
DECLARE
  v_expected bigint;
  v_updated bigint;
BEGIN
  SELECT count(*)*3 INTO STRICT v_expected
  FROM r6d_approved_policy_fixture_classes;
  UPDATE ops.outbox AS event
  SET available_at='2099-01-01 00:00:00+00'
  WHERE event.id IN (
    SELECT receipt.outbox_id
    FROM ops.record_class_schedules AS schedule
    JOIN ops.execution_receipts AS receipt
      ON receipt.execution_id=schedule.action_execution_id
    WHERE schedule.record_class IN (
      SELECT record_class FROM r6d_approved_policy_fixture_classes
    )
    UNION ALL
    SELECT event.id
    FROM ops.record_class_schedules AS schedule
    JOIN ops.outbox AS event
      ON event.aggregate_type='record_class_schedule'
     AND event.aggregate_id=schedule.id::text
    WHERE schedule.record_class IN (
      SELECT record_class FROM r6d_approved_policy_fixture_classes
    )
  );
  GET DIAGNOSTICS v_updated=ROW_COUNT;
  IF v_updated<>v_expected THEN
    RAISE EXCEPTION 'r6d_retention_fixture_outbox_isolation_invalid:%/%',
      v_updated,v_expected;
  END IF;
END
$isolate$;

COMMIT;

-- TEST_ONLY deterministic privacy response-calendar authority fixture.
--
-- This is not a production seed and deliberately does not materialize an
-- action proposal, reviewer decisions, or an execution graph.  It exercises
-- only the separately installed TEST_ONLY authority branch, using the minimal
-- two immutable relations that branch validates.  Every stored digest has a
-- named canonical preimage below.

BEGIN;
SET LOCAL TIME ZONE 'UTC';

DO $fixture_guard$
DECLARE
  v_authority regprocedure:=to_regprocedure(
    'ops.privacy_response_policy_calendar_authority_v1_is_valid(uuid,bigint)'
  );
  v_selector regprocedure:=to_regprocedure(
    'ops.current_privacy_response_policy_calendar_v1(timestamp with time zone)'
  );
  v_authority_definition text;
  v_selector_definition text;
BEGIN
  IF current_database() NOT IN (
    'gurine_control_test',
    'gurine_submission_test',
    'gurine_event_consumers'
  ) THEN
    RAISE EXCEPTION 'r6d_test_calendar_fixture_database_forbidden'
      USING ERRCODE='55000';
  END IF;

  IF NOT pg_has_role(session_user,'gurine_migrator','MEMBER') THEN
    RAISE EXCEPTION 'r6d_test_calendar_fixture_session_forbidden'
      USING ERRCODE='42501';
  END IF;

  IF v_authority IS NULL OR v_selector IS NULL THEN
    RAISE EXCEPTION 'r6d_test_calendar_authority_overlay_missing'
      USING ERRCODE='55000';
  END IF;

  v_authority_definition:=lower(pg_get_functiondef(v_authority));
  v_selector_definition:=lower(pg_get_functiondef(v_selector));
  IF position(
       'test-only-privacy-business-calendar.v1'
       IN v_authority_definition
     )=0
     OR position('test-only-r6d-v1' IN v_selector_definition)=0
     OR position(
       'pg_has_role(session_user'
       IN regexp_replace(v_selector_definition,'[[:space:]]+','','g')
     )=0 THEN
    RAISE EXCEPTION 'r6d_test_calendar_authority_overlay_invalid'
      USING ERRCODE='55000';
  END IF;
END
$fixture_guard$;

DO $fixture$
DECLARE
  v_policy_id constant uuid :=
    'a6d00000-0000-4000-8000-000000000001';
  v_revision constant bigint := 2;
  v_calendar_version_id constant uuid :=
    'a6d40000-0000-4000-8000-000000000001';
  v_calendar_id constant uuid :=
    'a6d40000-0000-4000-8000-000000000002';
  v_proposal_id constant uuid :=
    'a6d40000-0000-4000-8000-000000000003';
  v_operational_receipt_id constant uuid :=
    'a6d40000-0000-4000-8000-000000000004';
  v_legal_receipt_id constant uuid :=
    'a6d40000-0000-4000-8000-000000000005';
  v_execution_receipt_id constant uuid :=
    'a6d40000-0000-4000-8000-000000000006';
  v_created_by constant uuid :=
    'a6d40000-0000-4000-8000-000000000007';
  v_effective_at constant timestamptz :=
    '2026-01-01 00:00:00+00';
  v_review_expires_at constant timestamptz :=
    '2099-01-01 00:00:00+00';
  v_holiday_digest char(64);
  v_calendar_digest char(64);
  v_approval_digest char(64);
  v_operational_digest char(64);
  v_legal_digest char(64);
  v_execution_digest char(64);
  v_policy_payload jsonb;
  v_policy_canonical bytea;
  v_policy_digest char(64);
  v_binding jsonb;
  v_binding_digest char(64);
BEGIN
  v_holiday_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','test-only-privacy-holiday-set.v1',
      'holidayDates',jsonb_build_array('2026-08-10')
    )),'sha256'
  ),'hex');

  v_calendar_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','test-only-privacy-business-calendar.v1',
      'calendarVersionId',v_calendar_version_id,
      'calendarId',v_calendar_id,
      'version',1,
      'timezone','Asia/Seoul',
      'weekendDays',to_jsonb(ARRAY[0,6]::smallint[]),
      'holidayDates',to_jsonb(ARRAY[date '2026-08-10']),
      'holidayDateSetDigest',btrim(v_holiday_digest),
      'effectiveAt','2026-01-01T00:00:00Z',
      'reviewExpiresAt','2099-01-01T00:00:00Z'
    )),'sha256'
  ),'hex');

  v_approval_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','test-only-privacy-calendar-approval.v1',
      'proposalId',v_proposal_id,
      'proposalVersion',1
    )),'sha256'
  ),'hex');
  v_operational_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','test-only-privacy-calendar-decision-receipt.v1',
      'receiptId',v_operational_receipt_id,
      'proposalId',v_proposal_id,
      'proposalVersion',1,
      'slot','response_policy_owner',
      'decision','APPROVE'
    )),'sha256'
  ),'hex');
  v_legal_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','test-only-privacy-calendar-decision-receipt.v1',
      'receiptId',v_legal_receipt_id,
      'proposalId',v_proposal_id,
      'proposalVersion',1,
      'slot','calendar_operator',
      'decision','APPROVE'
    )),'sha256'
  ),'hex');
  v_execution_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','test-only-privacy-calendar-execution-receipt.v1',
      'receiptId',v_execution_receipt_id,
      'proposalId',v_proposal_id,
      'proposalVersion',1,
      'approvalDigest',btrim(v_approval_digest),
      'aggregateState','SUCCEEDED'
    )),'sha256'
  ),'hex');

  v_policy_payload:=jsonb_build_object(
    'policyVersion','test-only-r6d-v1',
    'authoritySource','TEST_ONLY',
    'timezone','Asia/Seoul',
    'daySystem','BUSINESS_DAY',
    'accessBusinessDays',10,
    'correctionBusinessDays',10,
    'deletionBusinessDays',10,
    'restrictionBusinessDays',10,
    'maximumExtensionBusinessDays',10,
    'maximumExtensionCount',1,
    'extensionNoticeTiming','BEFORE_CURRENT_DUE_AT',
    'refusalNoticeBusinessDays',10,
    'calendarVersionId',v_calendar_version_id,
    'calendarDigest',btrim(v_calendar_digest)
  );
  v_policy_canonical:=ops.canonical_jsonb_v1(v_policy_payload);
  v_policy_digest:=encode(
    extensions.digest(v_policy_canonical,'sha256'),'hex'
  );

  v_binding:=jsonb_build_object(
    'schemaVersion',
      'test-only-privacy-response-calendar-policy-binding.v1',
    'policyId',v_policy_id,
    'revision',v_revision,
    'state','APPROVED',
    'authoritySource','TEST_ONLY',
    'policyVersion','test-only-r6d-v1',
    'policyDigest',btrim(v_policy_digest),
    'calendarVersionId',v_calendar_version_id,
    'calendarId',v_calendar_id,
    'calendarVersion',1,
    'calendarDigest',btrim(v_calendar_digest),
    'actionProposalId',v_proposal_id,
    'actionProposalVersion',1,
    'approvalDigest',btrim(v_approval_digest),
    'operationalDecisionReceiptId',v_operational_receipt_id,
    'operationalDecisionReceiptDigest',btrim(v_operational_digest),
    'legalDecisionReceiptId',v_legal_receipt_id,
    'legalDecisionReceiptDigest',btrim(v_legal_digest),
    'actionExecutionReceiptId',v_execution_receipt_id,
    'actionExecutionReceiptDigest',btrim(v_execution_digest),
    'effectiveAt','2026-01-01T00:00:00Z',
    'reviewExpiresAt','2099-01-01T00:00:00Z'
  );
  v_binding_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_binding),'sha256'
  ),'hex');

  INSERT INTO ops.business_calendar_versions(
    id,calendar_id,version,timezone,weekend_days,holiday_dates,
    holiday_set_digest,policy_digest,calendar_digest,
    approval_proposal_id,approval_proposal_version,approval_digest,
    execution_receipt_id,execution_receipt_digest,
    effective_at,review_expires_at,created_by,created_at
  ) VALUES (
    v_calendar_version_id,v_calendar_id,1,'Asia/Seoul',
    ARRAY[0,6]::smallint[],ARRAY[date '2026-08-10'],
    v_holiday_digest,v_policy_digest,v_calendar_digest,
    v_proposal_id,1,v_approval_digest,
    v_execution_receipt_id,v_execution_digest,
    v_effective_at,v_review_expires_at,v_created_by,v_effective_at
  ) ON CONFLICT DO NOTHING;

  INSERT INTO ops.privacy_response_calendar_policies_v1(
    policy_id,revision,policy_version,authority_source,state,timezone,
    access_business_days,correction_business_days,deletion_business_days,
    restriction_business_days,maximum_extension_business_days,
    maximum_extension_count,refusal_notice_business_days,
    calendar_id,action_proposal_id,action_proposal_version,
    operational_decision_receipt_id,operational_decision_receipt_digest,
    legal_decision_receipt_id,legal_decision_receipt_digest,
    action_execution_receipt_id,action_execution_receipt_digest,
    policy_payload,policy_canonical,policy_digest,binding_digest,
    effective_at,review_expires_at,created_at
  ) VALUES (
    v_policy_id,v_revision,'test-only-r6d-v1','TEST_ONLY','APPROVED',
    'Asia/Seoul',10,10,10,10,10,1,10,
    v_calendar_version_id,v_proposal_id,1,
    v_operational_receipt_id,v_operational_digest,
    v_legal_receipt_id,v_legal_digest,
    v_execution_receipt_id,v_execution_digest,
    v_policy_payload,v_policy_canonical,v_policy_digest,v_binding_digest,
    v_effective_at,v_review_expires_at,v_effective_at
  ) ON CONFLICT (policy_id,revision) DO NOTHING;

  IF (SELECT count(*)
      FROM ops.business_calendar_versions AS calendar
      WHERE calendar.id=v_calendar_version_id
        AND calendar.calendar_id=v_calendar_id
        AND calendar.version=1
        AND calendar.timezone='Asia/Seoul'
        AND calendar.weekend_days=ARRAY[0,6]::smallint[]
        AND calendar.holiday_dates=ARRAY[date '2026-08-10']
        AND calendar.holiday_set_digest=v_holiday_digest
        AND calendar.policy_digest=v_policy_digest
        AND calendar.calendar_digest=v_calendar_digest
        AND calendar.approval_proposal_id=v_proposal_id
        AND calendar.approval_proposal_version=1
        AND calendar.approval_digest=v_approval_digest
        AND calendar.execution_receipt_id=v_execution_receipt_id
        AND calendar.execution_receipt_digest=v_execution_digest
        AND calendar.effective_at=v_effective_at
        AND calendar.review_expires_at=v_review_expires_at)<>1 THEN
    RAISE EXCEPTION 'r6d_test_calendar_fixture_calendar_invalid'
      USING ERRCODE='55000';
  END IF;

  IF (SELECT count(*)
      FROM ops.privacy_response_calendar_policies_v1 AS policy
      WHERE policy.policy_id=v_policy_id AND policy.revision=v_revision
        AND policy.policy_version='test-only-r6d-v1'
        AND policy.authority_source='TEST_ONLY'
        AND policy.state='APPROVED'
        AND policy.policy_payload=v_policy_payload
        AND policy.policy_canonical=v_policy_canonical
        AND policy.policy_digest=v_policy_digest
        AND policy.binding_digest=v_binding_digest
        AND policy.calendar_id=v_calendar_version_id
        AND policy.action_proposal_id=v_proposal_id
        AND policy.action_proposal_version=1
        AND policy.operational_decision_receipt_id=
            v_operational_receipt_id
        AND policy.operational_decision_receipt_digest=
            v_operational_digest
        AND policy.legal_decision_receipt_id=v_legal_receipt_id
        AND policy.legal_decision_receipt_digest=v_legal_digest
        AND policy.action_execution_receipt_id=v_execution_receipt_id
        AND policy.action_execution_receipt_digest=v_execution_digest
        AND policy.effective_at=v_effective_at
        AND policy.review_expires_at=v_review_expires_at)<>1 THEN
    RAISE EXCEPTION 'r6d_test_calendar_fixture_policy_invalid'
      USING ERRCODE='55000';
  END IF;

  IF EXISTS(
    SELECT 1 FROM ops.action_proposals WHERE id=v_proposal_id
  ) OR EXISTS(
    SELECT 1 FROM ops.action_decisions
    WHERE id IN (v_operational_receipt_id,v_legal_receipt_id)
  ) OR EXISTS(
    SELECT 1 FROM ops.execution_receipts WHERE id=v_execution_receipt_id
  ) THEN
    RAISE EXCEPTION 'r6d_test_calendar_fixture_not_minimal'
      USING ERRCODE='55000';
  END IF;
END
$fixture$;

-- Force the deferred authority guard, if a caller deferred constraints, before
-- reporting success.
SET CONSTRAINTS ALL IMMEDIATE;

DO $validate$
DECLARE
  v_selected jsonb;
BEGIN
  IF NOT ops.privacy_response_policy_calendar_authority_v1_is_valid(
    'a6d00000-0000-4000-8000-000000000001',2
  ) THEN
    RAISE EXCEPTION 'r6d_test_calendar_fixture_authority_invalid'
      USING ERRCODE='55000';
  END IF;

  v_selected:=ops.current_privacy_response_policy_calendar_v1(
    '2026-08-01 00:00:00+00'
  );
  IF v_selected->>'policyVersion'<>'test-only-r6d-v1'
     OR (v_selected->>'revision')::bigint<>2
     OR (v_selected->>'accessBusinessDays')::integer<>10
     OR (v_selected->>'correctionBusinessDays')::integer<>10
     OR (v_selected->>'deletionBusinessDays')::integer<>10
     OR (v_selected->>'restrictionBusinessDays')::integer<>10
     OR (v_selected->>'maximumExtensionBusinessDays')::integer<>10
     OR (v_selected->>'maximumExtensionCount')::integer<>1
     OR (v_selected->>'refusalNoticeBusinessDays')::integer<>10
     OR (v_selected->>'calendarVersion')::bigint<>1
     OR v_selected->>'calendarVersionId'<>
        'a6d40000-0000-4000-8000-000000000001' THEN
    RAISE EXCEPTION 'r6d_test_calendar_fixture_selector_invalid'
      USING ERRCODE='55000';
  END IF;
  RAISE NOTICE 'R6D_TEST_CALENDAR_AUTHORITY_FIXTURE_PASS';
END
$validate$;

COMMIT;
