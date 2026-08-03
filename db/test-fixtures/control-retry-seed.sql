-- Independent runtime witness for retryActionExecution.  This is a real
-- RETRYABLE_FAILED action execution with a no-provider-attempt proof shape;
-- it is intentionally separate from the approval flow's freshly QUEUED
-- execution so the control-flow matrix does not mutate one aggregate through
-- incompatible command paths.
BEGIN;
DO $$
DECLARE
  d constant char(64) := repeat('a', 64);
  actor constant uuid := '11111111-1111-4111-8111-111111111111';
  proposal constant uuid := '88888888-8888-4888-8888-888888888888';
  execution constant uuid := 'f4e7c4f1-7b4d-5d2e-9d7c-7e53dbdf7c7d';
  assignment constant uuid := 'e0f4ce38-4f0a-5b83-bf24-1cb5cc2f46e9';
  decision constant uuid := '9d8b6e76-26c6-5d37-a8e5-31f3cd81e9bc';
  proposal_binding jsonb;
  proposal_binding_canonical bytea;
  approval char(64);
  action_detail jsonb := '{}'::jsonb;
  action_detail_canonical bytea;
  action_detail_digest char(64);
  decision_binding jsonb := '{}'::jsonb;
  decision_binding_canonical bytea;
  decision_receipt char(64);
  execution_binding jsonb := jsonb_build_object('schemaVersion','approval-binding.v1','fixture',true);
  execution_binding_canonical bytea;
  execution_digest char(64);
  reason_digest char(64);
  now_at timestamptz := clock_timestamp();
BEGIN
  proposal_binding := jsonb_build_object('schemaVersion','approval-binding.v1','fixture','retry');
  proposal_binding_canonical := convert_to(proposal_binding::text, 'UTF8');
  approval := encode(extensions.digest(proposal_binding_canonical, 'sha256'), 'hex');
  action_detail_canonical := convert_to(jsonb_build_object('actionDetailKind','HYPOTHESIS','actionDetail',action_detail)::text, 'UTF8');
  action_detail_digest := encode(extensions.digest(action_detail_canonical, 'sha256'), 'hex');
  decision_binding_canonical := convert_to(decision_binding::text, 'UTF8');
  decision_receipt := encode(extensions.digest(decision_binding_canonical, 'sha256'), 'hex');
  execution_binding_canonical := convert_to(execution_binding::text, 'UTF8');
  execution_digest := encode(extensions.digest(execution_binding_canonical, 'sha256'), 'hex');
  reason_digest := encode(extensions.digest(convert_to('retry fixture', 'UTF8'), 'sha256'), 'hex');

  INSERT INTO ops.action_proposals(
    id,action_kind,origin_kind,origin_id,origin_version,origin_digest,
    target_type,target_id,target_version,target_digest,object_scope_digest,
    current_version,aggregate_version,created_by,owner_user_id,last_receipt_digest,
    last_audit_event_id)
  VALUES(proposal,'HYPOTHESIS','HUMAN',actor,1,d,'CASE',
    '148b09d5-aa28-5351-b471-9ef333a3e410',1,d,d,1,1,actor,actor,d,gen_random_uuid())
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.action_proposal_versions(
    proposal_id,version,state,state_version,payload_encrypted,content_digest,
    rationale_encrypted,rationale_digest,last_editor_id,expires_at,
    approval_binding,approval_binding_canonical,approval_digest,operation_id,
    required_capability,target_request_digest,evidence_set_digest,
    contrary_evidence_set_digest,uncertainty_set_digest,risk_assessment_digest,
    policy_snapshot_digest,conflict_snapshot_digest,expected_effect_digest,
    reversible,quorum_plan_digest,effect_idempotency_key_sha256,
    action_detail_kind,action_detail,action_detail_canonical,action_detail_digest,
    quorum_policy_version,not_before,due_at,submitted_at,
    preview_id,preview_digest,preview_policy_digest,preview_encrypted,previewed_at,
    previewed_by,preview_receipt_digest,preview_audit_event_id,created_at,updated_at)
  VALUES(proposal,1,'DRAFT',1,convert_to(rpad('{}',32,' '),'UTF8'),d,
    convert_to(rpad('{}',32,' '),'UTF8'),d,actor,now_at+interval '7 days',
    proposal_binding,proposal_binding_canonical,approval,'submitActionDecision',
    'actions.review',d,d,d,d,d,d,d,d,true,d,d,'HYPOTHESIS',action_detail,
    action_detail_canonical,action_detail_digest,'approval-policy.v1',now_at,
    now_at+interval '1 day',now_at,'7f0c0d90-9e95-5b17-8943-5e8ad365c84f',d,d,
    convert_to(rpad('{}',32,' '),'UTF8'),now_at,actor,d,gen_random_uuid(),now_at,now_at)
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.action_review_assignments(
    id,proposal_id,proposal_version,approval_digest,assignment_generation,slot_id,
    slot_ordinal,required_capability,approve_assurance,allowed_role_codes,
    reviewer_id,reviewer_role_snapshot_digest,eligibility_snapshot_digest,
    conflict_snapshot_id,conflict_snapshot_digest,conflict_target_id,
    conflict_target_version,conflict_target_digest,conflict_evaluation_state,
    conflict_valid_until,excluded_actor_ids,exclusion_set_digest,quorum_plan_digest,
    assignment_digest,state,version,assigned_by,due_at,last_receipt_digest,
    last_audit_event_id)
  VALUES(assignment,proposal,1,approval,1,'primary',1,'actions.review',
    'ACTIVE_SESSION',ARRAY['APPROVER'],actor,d,d,gen_random_uuid(),d,proposal,1,
    approval,'CLEAR',now_at+interval '7 days',ARRAY['44444444-4444-4444-8444-444444444444'::uuid],d,d,d,'ASSIGNED',1,
    actor,now_at+interval '7 days',d,gen_random_uuid())
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.action_decisions(
    id,proposal_id,proposal_version,approval_digest,assignment_id,assignment_version,
    assignment_generation,slot_kind,actor_id,assurance,actor_assertion_jti,
    actor_action_digest,idempotency_key_sha256,decision_kind,reason_code,reason,
    reason_digest,decision_payload,decision_payload_canonical,
    decision_receipt_binding,decision_receipt_binding_canonical,conflict_snapshot_id,
    conflict_snapshot_digest,conflict_target_id,conflict_target_version,
    conflict_target_digest,conflict_evaluation_state,conflict_valid_until,
    quorum_snapshot_digest,counts_toward_quorum,quorum_satisfied_after,
    resulting_proposal_state,execution_id,receipt_digest,request_id,audit_event_id,
    decided_at,created_at)
  VALUES(decision,proposal,1,approval,assignment,1,1,'primary',actor,'ACTIVE_SESSION',
    gen_random_uuid(),d,d,'APPROVE','OPERATOR_DECISION','retry fixture',reason_digest,
    '{}'::jsonb,convert_to('{}','UTF8'),decision_binding,decision_binding_canonical,
    gen_random_uuid(),d,proposal,1,approval,'CLEAR',now_at+interval '7 days',d,true,
    true,'APPROVED',execution,decision_receipt,gen_random_uuid(),gen_random_uuid(),
    now_at,now_at)
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.in_flight_effects(
    id,effect_type,effect_key_digest,action_kind,action_proposal_id,
    action_proposal_version,approval_digest,predecessor_relationship,current_generation,
    state,state_version,cancellation_generation,dispatch_attempt_count,run_after,
    provider_configuration_digest,provider_idempotency_key_sha256,policy_digest,
    kill_switch_digest,budget_digest,rights_digest,consent_digest,suppression_digest,
    conflict_digest,activation_digest,quorum_plan_digest,rendered_bytes_digest,
    last_receipt_sequence,last_receipt_digest,created_at,updated_at)
  VALUES(execution,'ACTION_EXECUTION',encode(extensions.digest(convert_to('retry-fixture','UTF8'),'sha256'),'hex'),
    'HYPOTHESIS',proposal,1,approval,'NONE',1,'RETRYABLE_FAILED',1,0,1,now_at,
    '8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde',
    '36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74',d,d,d,d,d,d,d,d,d,d,1,d,now_at,now_at)
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.execution_authorizations(
    execution_id,generation,authorization_kind,proposal_id,proposal_version,action_kind,
    approval_digest,counted_decision_ids,counted_decision_receipt_digests,
    counted_decision_set_digest,terminal_decision_id,terminal_decision_receipt_digest,
    executor_id,transport,required_capability,target_request_schema_version,
    target_request_encrypted,target_request_sha256,rendered_bytes_digest,effect_boundary,
    provider_configuration_digest,provider_idempotency_key_sha256,cost_class,
    budget_reservation_digest,command_idempotency_key_sha256,execution_binding,
    execution_binding_canonical,execution_digest,request_id,audit_event_id,outbox_id,expires_at)
  VALUES(execution,1,'INITIAL_APPROVAL',proposal,1,'HYPOTHESIS',approval,ARRAY[decision],
    ARRAY[decision_receipt],d,decision,decision_receipt,'fixture-executor',
    'BASE_APPLICATION_COMMAND','actions.operate','action-payload.v1',
    convert_to(rpad('{}',32,' '),'UTF8'),d,d,'DATABASE_ONLY',
    '8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde',
    '36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74',
    'NO_PAID_EGRESS','cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde',d,
    execution_binding,execution_binding_canonical,execution_digest,gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),now_at+interval '7 days')
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.execution_attempts(
    execution_id,generation,attempt_state,state_version,run_after,fencing_token,
    target_request_sha256,rendered_bytes_digest,provider_configuration_digest,
    provider_idempotency_key_sha256,budget_reservation_digest,last_receipt_sequence,
    created_at,updated_at)
  VALUES(execution,1,'RETRYABLE_FAILED',1,now_at,0,d,d,
    '8682eb9449f61b9d8c9e36d481638e3ffafcd9e66b490d42afde6fc847560fde',
    '36e6cda205ff7692fef24261d22e17e282ecc3bba7f5d04f41310839d90e3e74',
    'cd12c434cfd58a9f3a3e0222f236dcc3ea4f1f24f78ea74224dd110bebf61bde',0,now_at,now_at)
  ON CONFLICT DO NOTHING;
END $$;
COMMIT;
