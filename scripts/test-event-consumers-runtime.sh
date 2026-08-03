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
  -p gurine-notification-worker -p gurine-acceptance-tests --bins

docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
for migration in db/migrations/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <"$migration" >/dev/null
done
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "ALTER ROLE gurine_scheduler LOGIN PASSWORD 'scheduler_test'; ALTER ROLE gurine_analysis_worker LOGIN PASSWORD 'analysis_test'; ALTER ROLE gurine_workflow_worker LOGIN PASSWORD 'workflow_test'; ALTER ROLE gurine_notification_worker LOGIN PASSWORD 'notification_test';" >/dev/null

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

# TEST_ONLY governance fixtures for the two finite operational-audit retention
# classes introduced by 0036.  The disposable database is removed on exit.
# Each class has its own typed proposal, two-human approval, execution
# authorization, immutable terminal receipt, and schedule; no product policy
# value or production seed is inferred from these mechanics-only rows.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
-- TEST_ONLY deterministic D6 retention governance fixtures.
--
-- This file is intended to replace the SQL body currently embedded at
-- scripts/test-event-consumers-runtime.sh:102-789.  It deliberately writes
-- only to a disposable test database.  Every stored digest below has a named
-- canonical preimage, both human quorum slots are backed by real role and
-- capability rows, and the execution graph contains the mandatory queued
-- authorization receipt, attempt, and terminal receipt chain.

BEGIN;
SET CONSTRAINTS ALL DEFERRED;
SET LOCAL TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.r6b2_sha256_json(p_value jsonb)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT encode(
    extensions.digest(ops.canonical_jsonb_v1(p_value),'sha256'),'hex'
  )::char(64)
$$;

CREATE FUNCTION pg_temp.r6b2_sha256_text(p_value text)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT encode(
    extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex'
  )::char(64)
$$;

-- Deterministic counterpart of ops.append_audit_event for this disposable
-- fixture.  It preserves the production hash-chain preimage and lock order,
-- but receives the otherwise random UUID and clock value as fixed inputs.
CREATE FUNCTION pg_temp.r6b2_append_fixed_audit_event(
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
    RAISE EXCEPTION 'r6b2_fixed_audit_stream_key_invalid';
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
  v_event_hash := pg_temp.r6b2_sha256_text(
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
  'r6b2-retention-owner','r6b2-retention-owner@example.test',
  'R6b2 retention owner','ACTIVE',
  '2025-12-01 00:00:00+00','2025-12-01 00:00:00+00'
),
(
  '31400000-0000-4000-8000-000000000002',
  'r6b2-retention-operations','r6b2-retention-operations@example.test',
  'R6b2 operations reviewer','ACTIVE',
  '2025-12-01 00:00:00+00','2025-12-01 00:00:00+00'
),
(
  '31400000-0000-4000-8000-000000000003',
  'r6b2-retention-legal','r6b2-retention-legal@example.test',
  'R6b2 legal reviewer','ACTIVE',
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
  pg_temp.r6b2_sha256_text('r6b2-operations-session-token'),
  'r6b2-operations-oidc-session','2025-12-01 00:02:00+00',
  '2026-01-01 00:05:59+00','2099-01-01 00:00:00+00',NULL,
  pg_temp.r6b2_sha256_text('r6b2-operations-ip'),
  pg_temp.r6b2_sha256_text('r6b2-operations-user-agent'),
  '2025-12-01 00:02:00+00',
  pg_temp.r6b2_sha256_text('r6b2-operations-csrf'),
  '2025-12-01 00:02:00+00'
),
(
  '31400000-0000-4000-8000-000000000022',
  '31400000-0000-4000-8000-000000000003',
  pg_temp.r6b2_sha256_text('r6b2-legal-session-token'),
  'r6b2-legal-oidc-session','2025-12-01 00:02:00+00',
  '2026-01-01 00:06:59+00','2099-01-01 00:00:00+00',NULL,
  pg_temp.r6b2_sha256_text('r6b2-legal-ip'),
  pg_temp.r6b2_sha256_text('r6b2-legal-user-agent'),
  '2025-12-01 00:02:00+00',
  pg_temp.r6b2_sha256_text('r6b2-legal-csrf'),
  '2025-12-01 00:02:00+00'
);

CREATE FUNCTION pg_temp.install_r6b2_retention_fixture(
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
    'TEST_ONLY operational audit retention fixture for '||p_record_class;
  v_lawful_basis constant text :=
    'TEST_ONLY approved governance and audit-integrity verification';
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
  IF p_record_class NOT IN (
       'AGENT_RUNTIME_POLICY','AGENT_RUNTIME_INITIATION_RECEIPT'
     ) OR p_ordinal NOT IN (1,2) THEN
    RAISE EXCEPTION 'r6b2_retention_fixture_input_invalid';
  END IF;

  IF p_ordinal=1 THEN
    v_proposal := '31400000-0000-4000-8000-000000000101';
    v_operations_assignment := '31400000-0000-4000-8000-000000000102';
    v_legal_assignment := '31400000-0000-4000-8000-000000000103';
    v_operations_decision := '31400000-0000-4000-8000-000000000104';
    v_legal_decision := '31400000-0000-4000-8000-000000000105';
    v_effect := '31400000-0000-4000-8000-000000000106';
    v_authorization := '31400000-0000-4000-8000-000000000107';
    v_queued_receipt := '31400000-0000-4000-8000-000000000108';
    v_schedule := '31400000-0000-4000-8000-000000000109';
    v_operations_conflict := '31400000-0000-4000-8000-00000000010a';
    v_legal_conflict := '31400000-0000-4000-8000-00000000010b';
    v_authorized_outbox := '31400000-0000-4000-8000-00000000010c';
    v_completed_outbox := '31400000-0000-4000-8000-00000000010d';
    v_request_id := '31400000-0000-4000-8000-00000000010e';
    v_preview_id := '31400000-0000-4000-8000-00000000010f';
    v_attempt := '31400000-0000-4000-8000-000000000110';
    v_terminal_receipt := '31400000-0000-4000-8000-000000000111';
    v_schedule_outbox := '31400000-0000-4000-8000-000000000112';
    v_preview_audit := '31400000-0000-4000-8000-000000000113';
    v_operations_audit := '31400000-0000-4000-8000-000000000114';
    v_legal_audit := '31400000-0000-4000-8000-000000000115';
    v_authorization_audit := '31400000-0000-4000-8000-000000000116';
    v_execution_audit := '31400000-0000-4000-8000-000000000117';
    v_operations_step_up := '31400000-0000-4000-8000-000000000118';
    v_legal_step_up := '31400000-0000-4000-8000-000000000119';
    v_operations_assertion_jti := '31400000-0000-4000-8000-00000000011a';
    v_legal_assertion_jti := '31400000-0000-4000-8000-00000000011b';
    v_payload_encrypted := decode(repeat('51',64),'hex');
    v_rationale_encrypted := decode(repeat('61',64),'hex');
  ELSE
    v_proposal := '31400000-0000-4000-8000-000000000201';
    v_operations_assignment := '31400000-0000-4000-8000-000000000202';
    v_legal_assignment := '31400000-0000-4000-8000-000000000203';
    v_operations_decision := '31400000-0000-4000-8000-000000000204';
    v_legal_decision := '31400000-0000-4000-8000-000000000205';
    v_effect := '31400000-0000-4000-8000-000000000206';
    v_authorization := '31400000-0000-4000-8000-000000000207';
    v_queued_receipt := '31400000-0000-4000-8000-000000000208';
    v_schedule := '31400000-0000-4000-8000-000000000209';
    v_operations_conflict := '31400000-0000-4000-8000-00000000020a';
    v_legal_conflict := '31400000-0000-4000-8000-00000000020b';
    v_authorized_outbox := '31400000-0000-4000-8000-00000000020c';
    v_completed_outbox := '31400000-0000-4000-8000-00000000020d';
    v_request_id := '31400000-0000-4000-8000-00000000020e';
    v_preview_id := '31400000-0000-4000-8000-00000000020f';
    v_attempt := '31400000-0000-4000-8000-000000000210';
    v_terminal_receipt := '31400000-0000-4000-8000-000000000211';
    v_schedule_outbox := '31400000-0000-4000-8000-000000000212';
    v_preview_audit := '31400000-0000-4000-8000-000000000213';
    v_operations_audit := '31400000-0000-4000-8000-000000000214';
    v_legal_audit := '31400000-0000-4000-8000-000000000215';
    v_authorization_audit := '31400000-0000-4000-8000-000000000216';
    v_execution_audit := '31400000-0000-4000-8000-000000000217';
    v_operations_step_up := '31400000-0000-4000-8000-000000000218';
    v_legal_step_up := '31400000-0000-4000-8000-000000000219';
    v_operations_assertion_jti := '31400000-0000-4000-8000-00000000021a';
    v_legal_assertion_jti := '31400000-0000-4000-8000-00000000021b';
    v_payload_encrypted := decode(repeat('52',64),'hex');
    v_rationale_encrypted := decode(repeat('62',64),'hex');
  END IF;
  v_stream_key := 'r6b2-retention:'||lower(p_record_class);

  v_origin := jsonb_build_object(
    'kind','HUMAN','actorId',v_creator,'screenId','OPS-RETENTION',
    'reason','TEST_ONLY deterministic runtime retention authority'
  );
  v_origin_digest := pg_temp.r6b2_sha256_json(v_origin);
  v_target := jsonb_build_object(
    'targetType','RECORD_CLASS','targetId',p_record_class,'expectedVersion',1
  );
  v_target_digest := pg_temp.r6b2_sha256_json(v_target);
  v_object_scope := jsonb_build_object(
    'schemaVersion','action-object-scope.v1','targetType','RECORD_CLASS',
    'recordClasses',jsonb_build_array(p_record_class)
  );
  v_object_scope_digest := pg_temp.r6b2_sha256_json(v_object_scope);
  v_rationale := jsonb_build_object(
    'summary','TEST_ONLY deterministic runtime retention authority',
    'evidenceSegmentIds','[]'::jsonb,'unknowns','[]'::jsonb,
    'alternativesConsidered',jsonb_build_array(
      'Fail closed without a current retention schedule'
    ),
    'riskNote','Fixture is scoped to the disposable runtime smoke database'
  );
  v_rationale_digest := pg_temp.r6b2_sha256_json(v_rationale);

  v_current_schedule_binding := jsonb_build_object(
    'schemaVersion','current-record-class-schedule-head.v1',
    'recordClass',p_record_class,'revision',0,
    'scheduleId',NULL,'scheduleDigest',NULL
  );
  v_current_schedule_digest :=
    pg_temp.r6b2_sha256_json(v_current_schedule_binding);
  v_purpose_digest := pg_temp.r6b2_sha256_text(v_purpose);
  v_lawful_basis_digest := pg_temp.r6b2_sha256_text(v_lawful_basis);
  v_location_set := jsonb_build_object(
    'schemaVersion','retention-location-set.v1',
    'locations',jsonb_build_array('KR')
  );
  v_location_set_digest := pg_temp.r6b2_sha256_json(v_location_set);
  v_current_legal_hold_set := jsonb_build_object(
    'schemaVersion','current-legal-hold-set.v1',
    'recordClass',p_record_class,'holdIds','[]'::jsonb
  );
  v_current_legal_hold_set_digest :=
    pg_temp.r6b2_sha256_json(v_current_legal_hold_set);
  v_lawful_basis_review := jsonb_build_object(
    'schemaVersion','lawful-basis-review-artifact.v1',
    'recordClass',p_record_class,
    'lawfulBasisDigest',v_lawful_basis_digest,
    'decision','APPROVED_FOR_TEST','reviewerRole','LEGAL_REVIEWER',
    'reviewedAt',v_cycle_start-interval '1 day'
  );
  v_lawful_basis_review_digest :=
    pg_temp.r6b2_sha256_json(v_lawful_basis_review);
  v_policy_snapshot := jsonb_build_object(
    'schemaVersion','record-class-retention-policy.v1',
    'recordClass',p_record_class,'ownerTeam',v_owner_team,
    'purpose',v_purpose,'purposeDigest',v_purpose_digest,
    'lawfulBasis',v_lawful_basis,
    'lawfulBasisDigest',v_lawful_basis_digest,
    'lawfulBasisReviewDigest',v_lawful_basis_review_digest,
    'trigger','CREATED_AT','activeDurationSeconds',31536000,
    'backupDurationSeconds',2592000,'locationCodes',jsonb_build_array('KR'),
    'locationSetDigest',v_location_set_digest,
    'derivativeRecordClasses','[]'::jsonb,'terminalAction','DELETE',
    'holdBehavior','BLOCK_ON_RETENTION',
    'restoreSuppressionBehavior','REAPPLY_BEFORE_ACCESS',
    'effectiveAt',v_effective_at,'reviewExpiresAt',v_review_expires_at
  );
  v_policy_digest := pg_temp.r6b2_sha256_json(v_policy_snapshot);

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
    'trigger','CREATED_AT','activeDuration','P365D',
    'backupDuration','P30D','locations',jsonb_build_array('KR'),
    'terminalAction','DELETE','holdBehavior','PAUSE',
    'restoreSuppressionBehavior','REAPPLY',
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
    'trigger','CREATED_AT','activeDurationSeconds',31536000,
    'backupDurationSeconds',2592000,
    'locationSetDigest',v_location_set_digest,
    'terminalAction','DELETE','holdBehavior','BLOCK_ON_RETENTION',
    'restoreSuppressionBehavior','REAPPLY_BEFORE_ACCESS',
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
    pg_temp.r6b2_sha256_json(v_approval_subject);
  v_evidence_set_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
    'schemaVersion','approval-evidence-set.v1',
    'members',jsonb_build_array(jsonb_build_object(
      'kind','LAWFUL_BASIS_REVIEW',
      'digest',v_lawful_basis_review_digest
    ))
  ));
  v_contrary_evidence_set_digest :=
    pg_temp.r6b2_sha256_json(jsonb_build_object(
      'schemaVersion','approval-contrary-evidence-set.v1','members','[]'::jsonb
    ));
  v_uncertainty_set_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
    'schemaVersion','approval-uncertainty-set.v1','members','[]'::jsonb
  ));
  v_risk_assessment_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
    'schemaVersion','retention-risk-assessment.v1',
    'recordClass',p_record_class,'risk','TEST_ONLY_DISPOSABLE_DATABASE',
    'finiteRetention',true,'legalHoldFailClosed',true
  ));
  v_conflict_policy_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
    'schemaVersion','action-conflict-policy-snapshot.v1',
    'actionKind','RETENTION_SCHEDULE',
    'requiredEvaluations',jsonb_build_array('OPERATIONS','LEGAL_REVIEWER'),
    'separationOfDuty','DISTINCT_CREATOR_AND_DISTINCT_REVIEWERS'
  ));
  v_expected_effect_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
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
  v_quorum_plan_digest := pg_temp.r6b2_sha256_json(v_quorum_plan);
  v_effect_idempotency_digest := pg_temp.r6b2_sha256_json(
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

  SELECT pg_temp.r6b2_sha256_json(jsonb_build_object(
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
  SELECT pg_temp.r6b2_sha256_json(jsonb_build_object(
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
  v_operations_eligibility_digest := pg_temp.r6b2_sha256_json(
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
  v_legal_eligibility_digest := pg_temp.r6b2_sha256_json(
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
    pg_temp.r6b2_sha256_json(to_jsonb(ARRAY[v_creator]::uuid[]));
  v_declaration_set_digest := pg_temp.r6b2_sha256_json('[]'::jsonb);
  v_finding_set_digest := pg_temp.r6b2_sha256_json('{}'::jsonb);
  v_authorship_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
    'schemaVersion','conflict-authorship-snapshot.v1',
    'proposalCreatorId',v_creator,'reviewerIsCreator',false
  ));
  v_party_recipient_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
    'schemaVersion','conflict-party-recipient-snapshot.v1',
    'recordClass',p_record_class,'partyRecipientIds','[]'::jsonb
  ));
  v_relationship_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
    'schemaVersion','conflict-relationship-snapshot.v1',
    'recordClass',p_record_class,'relationships','[]'::jsonb
  ));
  v_funding_customer_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
    'schemaVersion','conflict-funding-customer-snapshot.v1',
    'recordClass',p_record_class,'bindings','[]'::jsonb
  ));

  v_operations_conflict_digest := pg_temp.r6b2_sha256_json(
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
  v_legal_conflict_digest := pg_temp.r6b2_sha256_json(
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
  v_operations_conflict_receipt_digest := pg_temp.r6b2_sha256_json(
    jsonb_build_object(
      'schemaVersion','conflict-snapshot-receipt.v1',
      'conflictSnapshotId',v_operations_conflict,
      'snapshotDigest',v_operations_conflict_digest,
      'evaluationState','CLEAR','evaluatedAt',v_submitted_at
    )
  );
  v_legal_conflict_receipt_digest := pg_temp.r6b2_sha256_json(
    jsonb_build_object(
      'schemaVersion','conflict-snapshot-receipt.v1',
      'conflictSnapshotId',v_legal_conflict,
      'snapshotDigest',v_legal_conflict_digest,
      'evaluationState','CLEAR','evaluatedAt',v_submitted_at
    )
  );
  v_operations_assignment_digest := pg_temp.r6b2_sha256_json(
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
  v_legal_assignment_digest := pg_temp.r6b2_sha256_json(
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
    pg_temp.r6b2_sha256_json(v_operations_step_up_action);
  v_legal_step_up_action_digest :=
    pg_temp.r6b2_sha256_json(v_legal_step_up_action);
  v_operations_idempotency_digest := pg_temp.r6b2_sha256_json(
    jsonb_build_object(
      'schemaVersion','action-decision-idempotency-key.v1',
      'requestId',v_request_id,'assignmentId',v_operations_assignment,
      'actorId',v_operations_reviewer,'approvalDigest',v_approval_digest
    )
  );
  v_legal_idempotency_digest := pg_temp.r6b2_sha256_json(
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
  v_operations_quorum_snapshot_digest := pg_temp.r6b2_sha256_json(
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
    'reasonDigest',pg_temp.r6b2_sha256_text(v_operations_reason),
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

  v_legal_quorum_snapshot_digest := pg_temp.r6b2_sha256_json(
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
    'reasonDigest',pg_temp.r6b2_sha256_text(v_legal_reason),
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
  v_counted_decision_set_digest := pg_temp.r6b2_sha256_json(
    jsonb_build_object(
      'decisionIds',to_jsonb(v_counted_decision_ids),
      'decisionReceiptDigests',to_jsonb(v_counted_receipt_digests)
    )
  );

  v_execution_conflict_digest := pg_temp.r6b2_sha256_json(
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
  v_kill_switch_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
    'schemaVersion','kill-switch-snapshot.v1',
    'scope',p_record_class,'blockingSwitches','[]'::jsonb
  ));
  v_rights_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
    'schemaVersion','rights-snapshot.v1','scope',p_record_class,
    'requiredRights','[]'::jsonb
  ));
  v_consent_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
    'schemaVersion','consent-snapshot.v1','scope',p_record_class,
    'requiredConsents','[]'::jsonb
  ));
  v_suppression_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
    'schemaVersion','suppression-snapshot.v1','scope',p_record_class,
    'suppressions','[]'::jsonb
  ));
  v_activation_digest := pg_temp.r6b2_sha256_json(jsonb_build_object(
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
    pg_temp.r6b2_sha256_json(v_execution_proof);
  v_empty_downstream_set_digest := pg_temp.r6b2_sha256_json(
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
    'triggerKind','CREATED_AT','activeDurationSeconds',31536000,
    'backupDurationSeconds',2592000,'locationCodes',jsonb_build_array('KR'),
    'derivativeRecordClasses','[]'::jsonb,'terminalAction','DELETE',
    'holdBehavior','BLOCK_ON_RETENTION',
    'restoreSuppressionBehavior','REAPPLY_BEFORE_ACCESS',
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
  v_schedule_digest := pg_temp.r6b2_sha256_json(v_schedule_binding);

  -- Materialize the same deterministic audit chain shape as
  -- ops.append_audit_event, but retain fixed UUIDs and fixed timestamps.
  PERFORM pg_temp.r6b2_append_fixed_audit_event(
    v_preview_audit,v_previewed_at,v_stream_key,'USER',v_creator::text,
    'ACTION_PROPOSAL_PREVIEWED','ActionProposal',v_proposal::text,
    'retention.policy.manage',v_request_id,jsonb_build_object(
      'recordClass',p_record_class,'proposalVersion',1,
      'approvalSubjectDigest',v_approval_subject_digest,'testOnly',true
    )
  );
  PERFORM pg_temp.r6b2_append_fixed_audit_event(
    v_operations_audit,v_operations_decided_at,v_stream_key,'USER',
    v_operations_reviewer::text,'ACTION_DECISION_SUBMITTED',
    'ActionProposal',v_proposal::text,'actions.review',v_request_id,
    jsonb_build_object(
      'slot','operational_owner','decisionKind','APPROVE',
      'decisionReceiptDigest',v_operations_decision_receipt_digest,
      'testOnly',true
    )
  );
  PERFORM pg_temp.r6b2_append_fixed_audit_event(
    v_legal_audit,v_legal_decided_at,v_stream_key,'USER',
    v_legal_reviewer::text,'ACTION_DECISION_SUBMITTED','ActionProposal',
    v_proposal::text,'actions.review',v_request_id,jsonb_build_object(
      'slot','legal_owner','decisionKind','APPROVE',
      'decisionReceiptDigest',v_legal_decision_receipt_digest,
      'testOnly',true
    )
  );
  PERFORM pg_temp.r6b2_append_fixed_audit_event(
    v_authorization_audit,v_authorized_at,v_stream_key,'SERVICE',
    'action-approval','ACTION_EXECUTION_AUTHORIZED','ActionExecution',
    v_effect::text,'retention.policy.manage',v_request_id,
    jsonb_build_object(
      'recordClass',p_record_class,'executionDigest',v_execution_digest,
      'receiptDigest',v_queued_receipt_digest,'testOnly',true
    )
  );
  PERFORM pg_temp.r6b2_append_fixed_audit_event(
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
    pg_temp.r6b2_sha256_text(v_operations_step_up::text||':token'),
    v_operations_decided_at+interval '4 minutes',NULL,1,3,
    v_operations_decided_at-interval '2 seconds',
    v_operations_decided_at-interval '1 second'
  ),
  (
    v_legal_step_up,v_legal_session,v_legal_step_up_action_digest,
    v_legal_idempotency_digest,
    pg_temp.r6b2_sha256_text(v_legal_step_up::text||':token'),
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
    pg_temp.r6b2_sha256_json(jsonb_build_object(
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
    'CREATED_AT',31536000,2592000,v_location_set_digest,'DELETE',
    'BLOCK_ON_RETENTION','REAPPLY_BEFORE_ACCESS',
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
    pg_temp.r6b2_sha256_text(v_operations_reason),
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
    pg_temp.r6b2_sha256_text(v_legal_reason),v_legal_decision_payload,
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
    v_lawful_basis_review_digest,'CREATED_AT',31536000,2592000,
    ARRAY['KR']::text[],'{}'::text[],'DELETE','BLOCK_ON_RETENTION',
    'REAPPLY_BEFORE_ACCESS',v_policy_digest,v_proposal,1,v_approval_digest,
    v_operations_decision,v_operations_decision_receipt_digest,
    v_legal_decision,v_legal_decision_receipt_digest,
    v_counted_decision_set_digest,v_effect,1,v_execution_digest,
    v_terminal_receipt,v_terminal_receipt_digest,v_effective_at,
    v_review_expires_at,v_schedule_digest,v_succeeded_at
  );
END
$$;

SELECT pg_temp.install_r6b2_retention_fixture(
  'AGENT_RUNTIME_POLICY',1
);
SELECT pg_temp.install_r6b2_retention_fixture(
  'AGENT_RUNTIME_INITIATION_RECEIPT',2
);

SET CONSTRAINTS ALL IMMEDIATE;

DO $validate$
DECLARE
  v_proposal_ids constant uuid[] := ARRAY[
    '31400000-0000-4000-8000-000000000101'::uuid,
    '31400000-0000-4000-8000-000000000201'::uuid
  ];
  v_record_classes constant text[] := ARRAY[
    'AGENT_RUNTIME_POLICY','AGENT_RUNTIME_INITIATION_RECEIPT'
  ];
BEGIN
  IF (SELECT count(*) FROM ops.action_proposals
      WHERE id=ANY(v_proposal_ids)) <> 2
     OR (SELECT count(*) FROM ops.action_proposal_versions
         WHERE proposal_id=ANY(v_proposal_ids)) <> 2
     OR (SELECT count(*)
         FROM ops.action_approval_retention_schedule_details
         WHERE proposal_id=ANY(v_proposal_ids)) <> 2
     OR (SELECT count(*) FROM editorial.conflict_snapshots
         WHERE target_type='ACTION_PROPOSAL'
           AND target_id=ANY(ARRAY(
             SELECT proposal_id::text FROM unnest(v_proposal_ids)
             AS proposal(proposal_id)
           ))) <> 4
     OR (SELECT count(*) FROM ops.action_review_assignments
         WHERE proposal_id=ANY(v_proposal_ids)) <> 4
     OR (SELECT count(*) FROM ops.action_decisions
         WHERE proposal_id=ANY(v_proposal_ids)) <> 4
     OR (SELECT count(*) FROM ops.in_flight_effects
         WHERE action_proposal_id=ANY(v_proposal_ids)) <> 2
     OR (SELECT count(*) FROM ops.execution_authorizations
         WHERE proposal_id=ANY(v_proposal_ids)) <> 2
     OR (SELECT count(*) FROM ops.execution_attempts AS attempt
         JOIN ops.in_flight_effects AS effect
           ON effect.id=attempt.execution_id
         WHERE effect.action_proposal_id=ANY(v_proposal_ids)) <> 2
     OR (SELECT count(*) FROM ops.execution_receipts AS receipt
         JOIN ops.in_flight_effects AS effect
           ON effect.id=receipt.execution_id
         WHERE effect.action_proposal_id=ANY(v_proposal_ids)) <> 4
     OR (SELECT count(*) FROM ops.record_class_schedules
         WHERE record_class=ANY(v_record_classes)) <> 2
     OR (SELECT count(*) FROM ops.step_up_authorizations AS step_up
         JOIN ops.action_decisions AS decision
           ON decision.step_up_authorization_id=step_up.id
         WHERE decision.proposal_id=ANY(v_proposal_ids)) <> 4
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
         )) <> 6 THEN
    RAISE EXCEPTION 'r6b2_retention_fixture_cardinality_invalid';
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
           pg_temp.r6b2_sha256_json(jsonb_build_object(
             'schemaVersion','current-record-class-schedule-head.v1',
             'recordClass',detail.record_class,'revision',0,
             'scheduleId',NULL,'scheduleDigest',NULL
           ))
      )
  ) THEN
    RAISE EXCEPTION 'r6b2_retention_fixture_approval_binding_invalid';
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
           pg_temp.r6b2_sha256_text(decision.reason)
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
           pg_temp.r6b2_sha256_json(jsonb_build_object(
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
           pg_temp.r6b2_sha256_json(jsonb_build_object(
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
           pg_temp.r6b2_sha256_json(jsonb_build_object(
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
    RAISE EXCEPTION 'r6b2_retention_fixture_decision_graph_invalid';
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
           pg_temp.r6b2_sha256_json(jsonb_build_object(
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
    RAISE EXCEPTION 'r6b2_retention_fixture_execution_graph_invalid';
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
          'downstreamReceiptSetDigest',pg_temp.r6b2_sha256_json(
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
    RAISE EXCEPTION 'r6b2_retention_fixture_receipt_payload_invalid';
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
           pg_temp.r6b2_sha256_text(schedule.purpose)
        OR detail.lawful_basis_digest IS DISTINCT FROM
           pg_temp.r6b2_sha256_text(schedule.lawful_basis)
        OR detail.location_set_digest IS DISTINCT FROM
           pg_temp.r6b2_sha256_json(jsonb_build_object(
             'schemaVersion','retention-location-set.v1',
             'locations',to_jsonb(schedule.location_codes)
           ))
        OR schedule.policy_digest IS DISTINCT FROM
           pg_temp.r6b2_sha256_json(jsonb_build_object(
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
           pg_temp.r6b2_sha256_json(jsonb_build_object(
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
    RAISE EXCEPTION 'r6b2_retention_fixture_schedule_digest_invalid';
  END IF;

  IF EXISTS (
    WITH expected(
      proposal_id,record_class,cycle_start
    ) AS (VALUES
      (
        '31400000-0000-4000-8000-000000000101'::uuid,
        'AGENT_RUNTIME_POLICY'::text,
        timestamptz '2026-01-01 00:00:00+00'
      ),
      (
        '31400000-0000-4000-8000-000000000201'::uuid,
        'AGENT_RUNTIME_INITIATION_RECEIPT'::text,
        timestamptz '2026-01-02 00:00:00+00'
      )
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
          pg_temp.r6b2_sha256_json(jsonb_build_object(
            'schemaVersion','lawful-basis-review-artifact.v1',
            'recordClass',schedule.record_class,
            'lawfulBasisDigest',detail.lawful_basis_digest,
            'decision','APPROVED_FOR_TEST',
            'reviewerRole','LEGAL_REVIEWER',
            'reviewedAt',expected.cycle_start-interval '1 day'
          ))
  ) THEN
    RAISE EXCEPTION 'r6b2_retention_fixture_fixed_time_invalid';
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
          SELECT pg_temp.r6b2_sha256_json(jsonb_build_object(
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
    RAISE EXCEPTION 'r6b2_retention_fixture_role_capability_invalid';
  END IF;

  IF EXISTS (
    WITH chain_members AS (
      SELECT schedule.record_class,
             'r6b2-retention:'||lower(schedule.record_class) AS stream_key,
             1 AS ordinal,version.preview_audit_event_id AS event_id
      FROM ops.record_class_schedules AS schedule
      JOIN ops.action_proposal_versions AS version
        ON version.proposal_id=schedule.action_proposal_id
       AND version.version=schedule.action_proposal_version
      WHERE schedule.record_class=ANY(v_record_classes)
      UNION ALL
      SELECT schedule.record_class,
             'r6b2-retention:'||lower(schedule.record_class),2,
             operational.audit_event_id
      FROM ops.record_class_schedules AS schedule
      JOIN ops.action_decisions AS operational
        ON operational.id=schedule.operational_action_decision_id
      WHERE schedule.record_class=ANY(v_record_classes)
      UNION ALL
      SELECT schedule.record_class,
             'r6b2-retention:'||lower(schedule.record_class),3,
             legal.audit_event_id
      FROM ops.record_class_schedules AS schedule
      JOIN ops.action_decisions AS legal
        ON legal.id=schedule.legal_action_decision_id
      WHERE schedule.record_class=ANY(v_record_classes)
      UNION ALL
      SELECT schedule.record_class,
             'r6b2-retention:'||lower(schedule.record_class),4,
             exec_auth.audit_event_id
      FROM ops.record_class_schedules AS schedule
      JOIN ops.execution_authorizations AS exec_auth
        ON exec_auth.execution_id=schedule.action_execution_id
       AND exec_auth.generation=schedule.action_execution_generation
      WHERE schedule.record_class=ANY(v_record_classes)
      UNION ALL
      SELECT schedule.record_class,
             'r6b2-retention:'||lower(schedule.record_class),5,
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
       OR event_hash IS DISTINCT FROM pg_temp.r6b2_sha256_text(
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
      ON head.stream_key='r6b2-retention:'||lower(schedule.record_class)
    JOIN ops.execution_receipts AS terminal
      ON terminal.id=schedule.action_execution_receipt_id
    WHERE schedule.record_class=ANY(v_record_classes)
      AND (
        head.version IS DISTINCT FROM 5
        OR head.head_event_id IS DISTINCT FROM terminal.audit_event_id
      )
  ) THEN
    RAISE EXCEPTION 'r6b2_retention_fixture_audit_chain_invalid';
  END IF;
END
$validate$;

COMMIT;
SQL

# The retention governance graph is evidence for D6, not input to this
# event-consumer scenario.  Keep its six durable outbox records pending so the
# first scheduler pass below measures only the eight scenario events.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE v_updated bigint;
BEGIN
  UPDATE ops.outbox AS event
  SET available_at=clock_timestamp()+interval '1 day'
  WHERE event.id IN (
    '31400000-0000-4000-8000-00000000010c',
    '31400000-0000-4000-8000-00000000010d',
    '31400000-0000-4000-8000-000000000112',
    '31400000-0000-4000-8000-00000000020c',
    '31400000-0000-4000-8000-00000000020d',
    '31400000-0000-4000-8000-000000000212'
  ) AND event.published_at IS NULL;
  GET DIAGNOSTICS v_updated=ROW_COUNT;
  IF v_updated <> 6 THEN
    RAISE EXCEPTION
      'retention fixture outbox isolation invalid: updated %',v_updated;
  END IF;
END $$;
SQL

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
INSERT INTO editorial.publication_previews(case_id,review_snapshot_id,locale,preview_payload,preview_sha256,expires_at,created_by)
VALUES('31000000-0000-4000-8000-000000000004','31000000-0000-4000-8000-000000000005','event','{}','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',clock_timestamp()+interval '1 hour','31000000-0000-4000-8000-000000000001');
INSERT INTO editorial.publication_revisions(id,case_id,revision,state,review_snapshot_id,public_payload,public_payload_sha256,preview_sha256,published_by)
VALUES('31000000-0000-4000-8000-000000000006','31000000-0000-4000-8000-000000000004',1,'PUBLISHED_ANOMALY','31000000-0000-4000-8000-000000000005','{}','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','31000000-0000-4000-8000-000000000001');

INSERT INTO editorial.response_requests(id,case_id,party_type,party_name,recipient_email_hash,recipient_email_encrypted,questions,requested_publication_scope,due_at,status,created_by)
VALUES('31000000-0000-4000-8000-000000000010','31000000-0000-4000-8000-000000000004','OTHER','Event Respondent',repeat('3',64),:'request_email','["Please respond"]','{}',clock_timestamp()+interval '7 days','SENT','31000000-0000-4000-8000-000000000001');
INSERT INTO intake.response_submissions(id,response_request_id,draft_version,submission_sha256,answers_encrypted,publication_consent,status,receipt_token_hash)
VALUES('31000000-0000-4000-8000-000000000011','31000000-0000-4000-8000-000000000010',1,repeat('4',64),decode('00','hex'),'{}','SUBMITTED',repeat('5',64));
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
SELECT ops.enqueue_outbox('response_submission','31000000-0000-4000-8000-000000000011',1,'workflow.response_submitted.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','submitResponse','requestToken','redacted','request_id','31000000-0000-4000-8000-0000000000a4'),clock_timestamp());
SQL

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
  IF actual <> 8 THEN RAISE EXCEPTION 'dispatched workflow inbox %, expected 8',actual; END IF;
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

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
SELECT ops.enqueue_outbox('contact_request','31000000-0000-4000-8000-000000000040',1,'intake.contact_received.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','createContactRequest','request_id','31000000-0000-4000-8000-0000000000b1'),clock_timestamp());
SELECT ops.enqueue_outbox('correction_request','31000000-0000-4000-8000-000000000030',1,'notification.correction_received.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','createCorrectionRequest','request_id','31000000-0000-4000-8000-0000000000b2'),clock_timestamp());
SELECT ops.enqueue_outbox('correction','31000000-0000-4000-8000-000000000032',1,'notification.correction_resolved.v1',jsonb_build_object('actor_id','31000000-0000-4000-8000-000000000001','correction_id','31000000-0000-4000-8000-000000000032','occurred_at','2026-07-12T00:00:00Z','operation_id','resolveCorrectionRequest','request_id','31000000-0000-4000-8000-0000000000b3'),clock_timestamp());
SELECT ops.enqueue_outbox('case','31000000-0000-4000-8000-000000000004',1,'notification.publication_created.v1',jsonb_build_object('actor_id','31000000-0000-4000-8000-000000000001','caseId','31000000-0000-4000-8000-000000000004','occurred_at','2026-07-12T00:00:00Z','operation_id','publishCase','request_id','31000000-0000-4000-8000-0000000000b4','reviewSnapshotId','31000000-0000-4000-8000-000000000005'),clock_timestamp());
SELECT ops.enqueue_outbox('response_extension','31000000-0000-4000-8000-000000000013',1,'notification.response_extension_requested.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','requestResponseExtension','requestToken','redacted','request_id','31000000-0000-4000-8000-0000000000b5'),clock_timestamp());
SELECT ops.enqueue_outbox('response_request','31000000-0000-4000-8000-000000000010',1,'notification.response_request_delivery_requested.v1',jsonb_build_object('actor_id','31000000-0000-4000-8000-000000000001','caseId','31000000-0000-4000-8000-000000000004','occurred_at','2026-07-12T00:00:00Z','operation_id','createResponseRequest','request_id','31000000-0000-4000-8000-0000000000b6'),clock_timestamp());
SELECT ops.enqueue_outbox('response_submission','31000000-0000-4000-8000-000000000011',1,'notification.response_submitted.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','submitResponse','requestToken','redacted','request_id','31000000-0000-4000-8000-0000000000b7'),clock_timestamp());
SELECT ops.enqueue_outbox('subscription','31000000-0000-4000-8000-000000000020',1,'notification.subscription_verification_requested.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','createSubscription','request_id','31000000-0000-4000-8000-0000000000b8'),clock_timestamp());
SELECT ops.enqueue_outbox('user','31000000-0000-4000-8000-000000000003',1,'notification.user_invitation_requested.v1',jsonb_build_object('actor_id','31000000-0000-4000-8000-000000000001','occurred_at','2026-07-12T00:00:00Z','operation_id','inviteUser','request_id','31000000-0000-4000-8000-0000000000b9'),clock_timestamp());
SELECT ops.enqueue_outbox('publication_revision','31000000-0000-4000-8000-000000000006',1,'projection.publication_applied.v1',jsonb_build_object('public_payload_sha256','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','publication_revision_id','31000000-0000-4000-8000-000000000006'),clock_timestamp());
SQL

SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_INSTANCE_ID="event-test" SCHEDULER_ONCE=true target/debug/gurine-scheduler

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
  IF actual <> 8 THEN RAISE EXCEPTION 'workflow inbox %, expected 8',actual; END IF;
  SELECT count(*) INTO actual FROM ops.inbox WHERE consumer='notification-worker' AND processed_at IS NOT NULL;
  IF actual <> 12 THEN RAISE EXCEPTION 'notification inbox %, expected 12',actual; END IF;
  IF (SELECT status FROM ops.audit_exports WHERE id='31000000-0000-4000-8000-000000000082') <> 'READY' THEN
    RAISE EXCEPTION 'audit export not ready'; END IF;
  IF (SELECT status FROM intake.dataset_export_requests WHERE id='31000000-0000-4000-8000-000000000090') <> 'READY' THEN
    RAISE EXCEPTION 'dataset export not ready'; END IF;
  IF (SELECT enabled FROM ops.source_registry WHERE source_id='event-source') THEN
    RAISE EXCEPTION 'schema drift did not pause source'; END IF;
  IF (SELECT editorial_response_id FROM intake.response_submissions WHERE id='31000000-0000-4000-8000-000000000011') IS NULL THEN
    RAISE EXCEPTION 'response submission was not materialized'; END IF;
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
  IF actual <> 11 THEN RAISE EXCEPTION 'delivered emails %, expected 11',actual; END IF;
  SELECT count(*) INTO actual FROM intake.response_access_tokens WHERE response_request_id='31000000-0000-4000-8000-000000000010';
  IF actual <> 1 THEN RAISE EXCEPTION 'response access tokens %, expected 1',actual; END IF;
END $$;
SQL

test "$(find "$work/objects/exports" -type f | wc -l)" -eq 2
parquet_file="$(find "$work/objects/exports/datasets" -type f -name '*.parquet' -print -quit)"
test -n "$parquet_file"
test "$(head -c 4 "$parquet_file")" = "PAR1"
test "$(tail -c 4 "$parquet_file")" = "PAR1"
test "$(wc -l <"$work/smtp.jsonl")" -eq 11
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

echo "workflow/notification runtime, R6b2 pipeline, R6c typed graph v3, hypothesis recursion, source.fetch review tier, and rule oracle/blocked paths: PASS"
