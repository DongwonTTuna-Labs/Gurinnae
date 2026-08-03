-- A real non-final APPROVE is the only valid target of
-- withdrawActionDecision.  Final approval already owns an immutable
-- ExecutionAuthorization and cannot be retroactively withdrawn.
BEGIN;
DO $$
DECLARE
  d constant char(64) := repeat('b',64);
  actor constant uuid := '11111111-1111-4111-8111-111111111111';
  owner_actor constant uuid := '44444444-4444-4444-8444-444444444444';
  proposal constant uuid := '6b8f4e8a-2f9f-5ac9-9db7-5d6f3ad5df37';
  assignment constant uuid := '4b37d28b-e2f4-5a3d-9c75-5b6ec8f19a12';
  decision constant uuid := '337d61a4-29e7-5f8f-8dbf-d38f5328965b';
  conflict constant uuid := '72c5cce8-d512-57cc-80d3-8f8238fb49bb';
  now_at timestamptz := clock_timestamp();
  approval_binding jsonb;
  approval_canonical bytea;
  approval char(64);
  detail jsonb := jsonb_build_object('fixture','pending-quorum-approval');
  detail_canonical bytea;
  detail_digest char(64);
  decision_binding jsonb;
  decision_canonical bytea;
  decision_receipt char(64);
  reason constant text := 'pending quorum fixture approval';
  reason_digest char(64);
BEGIN
  approval_binding := jsonb_build_object(
    'schemaVersion','approval-binding.v1','fixture','withdraw-decision');
  approval_canonical := convert_to(approval_binding::text,'UTF8');
  approval := encode(extensions.digest(approval_canonical,'sha256'),'hex');
  detail_canonical := convert_to(jsonb_build_object(
    'actionDetailKind','HYPOTHESIS','actionDetail',detail)::text,'UTF8');
  detail_digest := encode(extensions.digest(detail_canonical,'sha256'),'hex');
  decision_binding := jsonb_build_object(
    'schemaVersion','action-decision-receipt.v1','decisionId',decision,
    'proposalId',proposal,'proposalVersion',1,'assignmentId',assignment,
    'decisionKind','APPROVE','resultingProposalState','PENDING_QUORUM',
    'quorumSatisfied',false,'decidedAt',now_at);
  decision_canonical := convert_to(decision_binding::text,'UTF8');
  decision_receipt := encode(extensions.digest(decision_canonical,'sha256'),'hex');
  reason_digest := encode(extensions.digest(convert_to(reason,'UTF8'),'sha256'),'hex');

  INSERT INTO ops.action_proposals(
    id,action_kind,origin_kind,origin_id,origin_version,origin_digest,
    target_type,target_id,target_version,target_digest,object_scope_digest,
    current_version,aggregate_version,created_by,owner_user_id,last_receipt_digest,
    last_audit_event_id)
  VALUES(proposal,'HYPOTHESIS','HUMAN',owner_actor,1,d,'CASE',
    '148b09d5-aa28-5351-b471-9ef333a3e410',1,d,d,1,3,owner_actor,
    owner_actor,decision_receipt,gen_random_uuid());

  INSERT INTO ops.action_proposal_versions(
    proposal_id,version,state,state_version,payload_encrypted,content_digest,
    rationale_encrypted,rationale_digest,last_editor_id,expires_at,
    preview_id,preview_digest,preview_policy_digest,preview_encrypted,previewed_at,
    previewed_by,preview_receipt_digest,preview_audit_event_id,approval_binding,
    approval_binding_canonical,approval_digest,operation_id,required_capability,
    target_request_digest,evidence_set_digest,contrary_evidence_set_digest,
    uncertainty_set_digest,risk_assessment_digest,policy_snapshot_digest,
    conflict_snapshot_digest,expected_effect_digest,reversible,quorum_plan_digest,
    effect_idempotency_key_sha256,action_detail_kind,action_detail,
    action_detail_canonical,action_detail_digest,quorum_policy_version,not_before,
    due_at,submitted_at,created_at,updated_at)
  VALUES(proposal,1,'PENDING_QUORUM',4,convert_to(rpad('{}',32,' '),'UTF8'),d,
    convert_to(rpad('{}',32,' '),'UTF8'),d,owner_actor,now_at+interval '7 days',
    '6e8d10bb-0b23-556d-a952-7164ff56e804',d,d,
    convert_to(rpad('{}',32,' '),'UTF8'),now_at,owner_actor,d,gen_random_uuid(),
    approval_binding,approval_canonical,approval,'submitActionDecision',
    'actions.review',d,d,d,d,d,d,d,d,true,d,d,'HYPOTHESIS',detail,
    detail_canonical,detail_digest,'approval-policy.v1',now_at,
    now_at+interval '6 days',now_at,now_at,now_at);

  INSERT INTO ops.action_review_assignments(
    id,proposal_id,proposal_version,approval_digest,assignment_generation,slot_id,
    slot_ordinal,required_capability,approve_assurance,allowed_role_codes,
    reviewer_id,reviewer_role_snapshot_digest,eligibility_snapshot_digest,
    conflict_snapshot_id,conflict_snapshot_digest,conflict_target_id,
    conflict_target_version,conflict_target_digest,conflict_evaluation_state,
    conflict_valid_until,excluded_actor_ids,exclusion_set_digest,
    quorum_plan_digest,assignment_digest,state,version,assigned_by,due_at,
    claimed_at,terminal_at,terminal_reason_code,last_receipt_digest,
    last_audit_event_id,created_at,updated_at)
  VALUES(assignment,proposal,1,approval,1,'primary',1,'actions.review',
    'ACTIVE_SESSION',ARRAY['APPROVER'],actor,d,d,conflict,d,proposal,1,approval,
    'CLEAR',now_at+interval '7 days',ARRAY[owner_actor],d,d,d,'COMPLETED',2,
    owner_actor,now_at+interval '6 days',now_at,now_at,'APPROVE',decision_receipt,
    gen_random_uuid(),now_at,now_at);

  INSERT INTO ops.action_decisions(
    id,proposal_id,proposal_version,approval_digest,assignment_id,
    assignment_version,assignment_generation,slot_kind,actor_id,assurance,
    actor_assertion_jti,actor_action_digest,idempotency_key_sha256,decision_kind,
    reason_code,reason,reason_digest,decision_payload,decision_payload_canonical,
    decision_receipt_binding,decision_receipt_binding_canonical,
    conflict_snapshot_id,conflict_snapshot_digest,conflict_target_id,
    conflict_target_version,conflict_target_digest,conflict_evaluation_state,
    conflict_valid_until,quorum_snapshot_digest,counts_toward_quorum,
    quorum_satisfied_after,resulting_proposal_state,receipt_digest,request_id,
    audit_event_id,decided_at,created_at)
  VALUES(decision,proposal,1,approval,assignment,2,1,'primary',actor,
    'ACTIVE_SESSION',gen_random_uuid(),d,d,'APPROVE','OPERATOR_DECISION',reason,
    reason_digest,jsonb_build_object('kind','APPROVE','reason',reason),
    convert_to(jsonb_build_object('kind','APPROVE','reason',reason)::text,'UTF8'),
    decision_binding,decision_canonical,conflict,d,proposal,1,approval,'CLEAR',
    now_at+interval '7 days',d,true,false,'PENDING_QUORUM',decision_receipt,
    gen_random_uuid(),gen_random_uuid(),now_at,now_at);
END $$;
COMMIT;
