#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-capability-quorum-$BASHPID"
database="gurine_capability_quorum"
build_target="${GURINE_TEST_TARGET_DIR:-/home/dongwonttuna/.cache/gurinnae-codex-target}"

cleanup() {
  status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    docker logs "$container" >&2 || true
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

cd "$root"
CARGO_TARGET_DIR="$build_target" cargo build --locked -p gurine-migrator >/dev/null
docker run --detach --rm --name "$container" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB="$database" \
  -p 127.0.0.1::5432 \
  postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818 >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
GURINE_ENV=test MIGRATOR_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${postgres_port}/${database}" \
  "$build_target/debug/gurine-migrator" >/dev/null

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL'
INSERT INTO ops.users(id,oidc_subject,email,display_name,status) VALUES
  ('10000000-0000-4000-8000-000000000001','quorum-owner','quorum-owner@gurine.test','Quorum Owner','ACTIVE'),
  ('20000000-0000-4000-8000-000000000001','quorum-legal-1','quorum-legal-1@gurine.test','Legal One','ACTIVE'),
  ('20000000-0000-4000-8000-000000000002','quorum-legal-2','quorum-legal-2@gurine.test','Legal Two','ACTIVE'),
  ('30000000-0000-4000-8000-000000000001','quorum-ops-1','quorum-ops-1@gurine.test','Operations One','ACTIVE'),
  ('30000000-0000-4000-8000-000000000002','quorum-ops-2','quorum-ops-2@gurine.test','Operations Two','ACTIVE'),
  ('40000000-0000-4000-8000-000000000001','quorum-outsider','quorum-outsider@gurine.test','Outsider','ACTIVE');

INSERT INTO ops.user_roles(user_id,role_id,granted_by,reason)
SELECT m.user_id,r.id,'10000000-0000-4000-8000-000000000001','capability quorum runtime'
FROM (VALUES
  ('20000000-0000-4000-8000-000000000001'::uuid,'LEGAL_REVIEWER'),
  ('20000000-0000-4000-8000-000000000002'::uuid,'LEGAL_REVIEWER'),
  ('30000000-0000-4000-8000-000000000001'::uuid,'OPERATIONS'),
  ('30000000-0000-4000-8000-000000000002'::uuid,'OPERATIONS')
) m(user_id,role_code) JOIN ops.roles r ON r.code=m.role_code;

CREATE OR REPLACE FUNCTION pg_temp.assert_true(p_condition boolean,p_message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_condition IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'assertion failed: %',p_message;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.new_activation(p_suffix text,p_lifetime interval DEFAULT interval '1 hour')
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  proposal uuid:=gen_random_uuid();
  owner_id uuid:='10000000-0000-4000-8000-000000000001';
  draft jsonb;
  created jsonb;
  previewed jsonb;
  submitted jsonb;
  envelope text:=encode(convert_to(repeat('sealed-capability-envelope-'||p_suffix,4),'UTF8'),'base64');
BEGIN
  draft:=jsonb_build_object(
    'schemaVersion','action-payload.v1','kind','CAPABILITY_ACTIVATION',
    'capabilityClass','AGENT_MODEL','capabilityId','model-provider-'||p_suffix,
    'environment','TEST','configurationDigest',repeat('1',64),
    'policyDigest',repeat('2',64),'contractDigest',repeat('3',64),
    'rightsDigest',repeat('4',64),'jurisdiction','KR',
    'effectiveAt',clock_timestamp()+interval '1 minute','expiresAt',NULL,
    'evidenceReceiptIds',jsonb_build_array(gen_random_uuid()),
    'target',jsonb_build_object('type','CAPABILITY','id','model-provider-'||p_suffix,
      'version',1,'digest',repeat('5',64)),
    'objectScope',jsonb_build_object('capabilityId','model-provider-'||p_suffix),
    'objectScopeDigest',repeat('6',64));
  created:=ops.execute_action_approval_v1('createActionProposal',jsonb_build_object(
    '_proposalId',proposal,'_payloadEncryptedBase64',envelope,
    '_rationaleEncryptedBase64',envelope,'actionKind','CAPABILITY_ACTIVATION',
    'origin',jsonb_build_object('kind','HUMAN','id',owner_id,'digest',repeat('7',64)),
    'rationale','activate verified model provider','draft',draft,
    'expiresAt',clock_timestamp()+p_lifetime),owner_id);
  previewed:=ops.execute_action_approval_v1('previewActionDraft',jsonb_build_object(
    'proposalId',proposal,'expectedVersion',1,
    'expectedContentDigest',created->>'contentDigest'),owner_id);
  submitted:=ops.execute_action_approval_v1('submitActionForReview',jsonb_build_object(
    'proposalId',proposal,'expectedVersion',1,
    'expectedContentDigest',created->>'contentDigest',
    'previewId',previewed->>'previewId','previewDigest',previewed->>'previewDigest'),owner_id);
  RETURN submitted||jsonb_build_object('proposalId',proposal,'contentDigest',created->>'contentDigest');
END $$;

CREATE OR REPLACE FUNCTION pg_temp.decision_request(
  p_flow jsonb,p_slot text,p_kind text,p_actor uuid,p_tasks jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  a ops.action_review_assignments%ROWTYPE;
  key_digest char(64):=encode(extensions.digest(convert_to(gen_random_uuid()::text,'UTF8'),'sha256'),'hex');
  action_digest char(64):=encode(extensions.digest(convert_to(gen_random_uuid()::text,'UTF8'),'sha256'),'hex');
  session_id uuid:=gen_random_uuid();
  authorization_id uuid;
  assertion_id uuid:=gen_random_uuid();
  assurance text:=CASE WHEN p_kind='APPROVE' THEN 'STEP_UP' ELSE 'ACTIVE_SESSION' END;
  body jsonb;
BEGIN
  SELECT * INTO STRICT a FROM ops.action_review_assignments
   WHERE proposal_id=(p_flow->>'proposalId')::uuid AND slot_id=p_slot
     AND state IN ('ASSIGNED','IN_PROGRESS')
   ORDER BY assignment_generation DESC LIMIT 1;
  IF assurance='STEP_UP' THEN
    INSERT INTO ops.sessions(id,user_id,session_token_hash,csrf_token_hash,auth_time,step_up_at,expires_at)
    VALUES(session_id,p_actor,encode(extensions.digest(convert_to(session_id::text,'UTF8'),'sha256'),'hex'),
      encode(extensions.digest(convert_to(assertion_id::text,'UTF8'),'sha256'),'hex'),
      clock_timestamp()-interval '1 minute',clock_timestamp()-interval '10 seconds',
      clock_timestamp()+interval '1 hour');
    INSERT INTO ops.step_up_authorizations(
      session_id,action_digest,idempotency_key_sha256,authorization_token_hash,
      expires_at,assertion_issue_count,last_issued_at)
    VALUES(session_id,action_digest,key_digest,
      encode(extensions.digest(convert_to(assertion_id::text,'UTF8'),'sha256'),'hex'),
      clock_timestamp()+interval '4 minutes',1,clock_timestamp())
    RETURNING id INTO authorization_id;
  END IF;
  body:=jsonb_build_object(
    'proposalId',a.proposal_id,'expectedProposalVersion',a.proposal_version,
    'assignmentId',a.id,'expectedAssignmentVersion',a.version,
    'expectedApprovalDigest',a.approval_digest,'actionKind','CAPABILITY_ACTIVATION',
    'decision',jsonb_strip_nulls(jsonb_build_object(
      'kind',p_kind,'reason',lower(p_kind)||' runtime decision','tasks',p_tasks)),
    'reason',lower(p_kind)||' runtime decision','assurance',assurance,
    'stepUpAuthorizationId',authorization_id,'assertedActionDigest',
      CASE WHEN assurance='STEP_UP' THEN action_digest ELSE NULL END,
    'requestId',gen_random_uuid(),'_idempotencyKeySha256',key_digest,
    '_actorAssertionJti',assertion_id,'_actorAssuranceLevel',assurance,
    '_actorActionDigest',CASE WHEN assurance='STEP_UP' THEN action_digest ELSE NULL END,
    '_actorStepUpAuthorizationId',authorization_id,
    '_actorIdempotencyKeySha256',CASE WHEN assurance='STEP_UP' THEN key_digest ELSE NULL END,
    '_actorStepUpAtUnix',extract(epoch FROM clock_timestamp())::bigint,
    '_actorRequestKeySha256',key_digest);
  RETURN body;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.submit_decision(
  p_flow jsonb,p_slot text,p_kind text,p_actor uuid,p_tasks jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  RETURN ops.execute_action_approval_v1('submitActionDecision',
    pg_temp.decision_request(p_flow,p_slot,p_kind,p_actor,p_tasks),p_actor);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.expect_decision_failure(
  p_request jsonb,p_actor uuid,p_expected_sqlstate text,p_message text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE observed text;
BEGIN
  BEGIN
    PERFORM ops.execute_action_approval_v1('submitActionDecision',p_request,p_actor);
  EXCEPTION WHEN OTHERS THEN
    observed:=SQLSTATE;
  END;
  IF observed IS NULL THEN
    RAISE EXCEPTION 'expected decision failure but succeeded: %',p_message;
  END IF;
  IF observed<>p_expected_sqlstate THEN
    RAISE EXCEPTION 'wrong SQLSTATE % (expected %) for %',observed,p_expected_sqlstate,p_message;
  END IF;
END $$;

DO $$
DECLARE f jsonb; first_result jsonb; final_result jsonb; execution uuid; auth ops.execution_authorizations%ROWTYPE;
BEGIN
  f:=pg_temp.new_activation('legal-first');
  PERFORM pg_temp.assert_true((SELECT count(*)=2 FROM ops.action_review_assignments
    WHERE proposal_id=(f->>'proposalId')::uuid AND slot_id IN ('legal','operational')),
    'activation must create exact legal and operational assignments');
  PERFORM pg_temp.assert_true((SELECT count(DISTINCT quorum_plan_digest)=1
    FROM ops.action_review_assignments WHERE proposal_id=(f->>'proposalId')::uuid),
    'assignments must share one immutable quorum plan digest');
  first_result:=pg_temp.submit_decision(f,'legal','APPROVE',
    '20000000-0000-4000-8000-000000000001');
  PERFORM pg_temp.assert_true(first_result->>'resultingState'='PENDING_QUORUM',
    'first legal approval must remain pending quorum');
  PERFORM pg_temp.assert_true((SELECT count(*)=0 FROM ops.in_flight_effects
    WHERE action_proposal_id=(f->>'proposalId')::uuid),
    'first approval must create no effect');
  PERFORM pg_temp.assert_true((SELECT count(*)=0 FROM ops.execution_authorizations
    WHERE proposal_id=(f->>'proposalId')::uuid),
    'first approval must create no execution authorization');
  final_result:=pg_temp.submit_decision(f,'operational','APPROVE',
    '30000000-0000-4000-8000-000000000001');
  PERFORM pg_temp.assert_true(final_result->>'resultingState'='APPROVED',
    'second operational approval must approve');
  SELECT id INTO STRICT execution FROM ops.in_flight_effects
    WHERE action_proposal_id=(f->>'proposalId')::uuid;
  SELECT * INTO STRICT auth FROM ops.execution_authorizations WHERE execution_id=execution;
  PERFORM pg_temp.assert_true(cardinality(auth.counted_decision_ids)=2,
    'authorization must bind two counted decisions');
  PERFORM pg_temp.assert_true((SELECT array_agg(d.id ORDER BY d.id)=auth.counted_decision_ids
    FROM ops.action_decisions d WHERE d.id=ANY(auth.counted_decision_ids)),
    'counted decision ids must match immutable legal and operational approvals');
  PERFORM pg_temp.assert_true(auth.execution_digest=encode(extensions.digest(
    auth.execution_binding_canonical,'sha256'),'hex'),
    'execution digest must recompute from canonical binding');

  f:=pg_temp.new_activation('operations-first');
  first_result:=pg_temp.submit_decision(f,'operational','APPROVE',
    '30000000-0000-4000-8000-000000000001');
  PERFORM pg_temp.assert_true(first_result->>'resultingState'='PENDING_QUORUM',
    'first operational approval must remain pending quorum');
  final_result:=pg_temp.submit_decision(f,'legal','APPROVE',
    '20000000-0000-4000-8000-000000000001');
  PERFORM pg_temp.assert_true(final_result->>'resultingState'='APPROVED',
    'second legal approval must approve');
END $$;

DO $$
DECLARE f jsonb; result jsonb; proposal uuid; replacement ops.action_review_assignments%ROWTYPE;
BEGIN
  f:=pg_temp.new_activation('reject'); proposal:=(f->>'proposalId')::uuid;
  result:=pg_temp.submit_decision(f,'legal','REJECT','20000000-0000-4000-8000-000000000001');
  PERFORM pg_temp.assert_true(result->>'resultingState'='REJECTED','reject must terminalize');
  PERFORM pg_temp.assert_true(NOT EXISTS(SELECT 1 FROM ops.execution_authorizations WHERE proposal_id=proposal),
    'reject must not execute');

  f:=pg_temp.new_activation('changes'); proposal:=(f->>'proposalId')::uuid;
  result:=pg_temp.submit_decision(f,'legal','CHANGES_REQUIRED',
    '20000000-0000-4000-8000-000000000001',
    jsonb_build_array(jsonb_build_object('title','Attach current provider rights receipt','priority','HIGH')));
  PERFORM pg_temp.assert_true(result->>'resultingState'='CHANGES_REQUIRED',
    'changes required must terminalize');
  PERFORM pg_temp.assert_true((SELECT cardinality(change_task_ids)=1 FROM ops.action_decisions
    WHERE proposal_id=proposal AND decision_kind='CHANGES_REQUIRED'),
    'changes required must persist real task ids');
  PERFORM pg_temp.assert_true(NOT EXISTS(SELECT 1 FROM ops.execution_authorizations WHERE proposal_id=proposal),
    'changes required must not execute');

  f:=pg_temp.new_activation('recuse'); proposal:=(f->>'proposalId')::uuid;
  result:=pg_temp.submit_decision(f,'legal','RECUSE','20000000-0000-4000-8000-000000000001');
  SELECT * INTO STRICT replacement FROM ops.action_review_assignments
    WHERE proposal_id=proposal AND slot_id='legal' AND assignment_generation=2;
  PERFORM pg_temp.assert_true(replacement.state='ASSIGNED'
    AND replacement.reviewer_id='20000000-0000-4000-8000-000000000002'
    AND replacement.approve_assurance='STEP_UP'
    AND replacement.allowed_role_codes=ARRAY['LEGAL_REVIEWER']::text[],
    'recusal must preserve legal slot contract and choose eligible replacement');
END $$;

DO $$
DECLARE f jsonb; request jsonb; auth_id uuid; session_id uuid;
BEGIN
  f:=pg_temp.new_activation('negative-bindings');
  request:=pg_temp.decision_request(f,'legal','APPROVE',
    '20000000-0000-4000-8000-000000000001');
  PERFORM pg_temp.expect_decision_failure(request,
    '40000000-0000-4000-8000-000000000001','42501','wrong reviewer');
  PERFORM pg_temp.expect_decision_failure(request||jsonb_build_object('expectedProposalVersion',2),
    '20000000-0000-4000-8000-000000000001','40001','stale proposal version');
  PERFORM pg_temp.expect_decision_failure(request||jsonb_build_object('expectedAssignmentVersion',2),
    '20000000-0000-4000-8000-000000000001','40001','stale assignment version');
  PERFORM pg_temp.expect_decision_failure(request||jsonb_build_object('expectedApprovalDigest',repeat('f',64)),
    '20000000-0000-4000-8000-000000000001','40001','wrong approval digest');
  PERFORM pg_temp.expect_decision_failure(request||jsonb_build_object('actionKind','TASK'),
    '20000000-0000-4000-8000-000000000001','40001','wrong action kind');
  PERFORM pg_temp.expect_decision_failure(request||jsonb_build_object('stepUpAuthorizationId',gen_random_uuid()),
    '20000000-0000-4000-8000-000000000001','42501','body authorization id mismatch');
  PERFORM pg_temp.expect_decision_failure(request||jsonb_build_object('assertedActionDigest',repeat('e',64)),
    '20000000-0000-4000-8000-000000000001','42501','asserted action digest mismatch');
  PERFORM pg_temp.expect_decision_failure(request||jsonb_build_object('_actorActionDigest',repeat('d',64)),
    '20000000-0000-4000-8000-000000000001','42501','signed action digest mismatch');
  PERFORM pg_temp.expect_decision_failure(request||jsonb_build_object('_actorIdempotencyKeySha256',repeat('c',64)),
    '20000000-0000-4000-8000-000000000001','42501','signed idempotency mismatch');

  auth_id:=(request->>'_actorStepUpAuthorizationId')::uuid;
  UPDATE ops.step_up_authorizations SET closed_at=clock_timestamp() WHERE id=auth_id;
  PERFORM pg_temp.expect_decision_failure(request,
    '20000000-0000-4000-8000-000000000001','42501','closed authorization');

  request:=pg_temp.decision_request(f,'legal','APPROVE',
    '20000000-0000-4000-8000-000000000001');
  auth_id:=(request->>'_actorStepUpAuthorizationId')::uuid;
  UPDATE ops.step_up_authorizations SET assertion_issue_count=0,last_issued_at=NULL WHERE id=auth_id;
  PERFORM pg_temp.expect_decision_failure(request,
    '20000000-0000-4000-8000-000000000001','42501','unissued authorization');

  request:=pg_temp.decision_request(f,'legal','APPROVE',
    '20000000-0000-4000-8000-000000000001');
  auth_id:=(request->>'_actorStepUpAuthorizationId')::uuid;
  SELECT session_id INTO STRICT session_id FROM ops.step_up_authorizations WHERE id=auth_id;
  UPDATE ops.sessions SET user_id='40000000-0000-4000-8000-000000000001' WHERE id=session_id;
  PERFORM pg_temp.expect_decision_failure(request,
    '20000000-0000-4000-8000-000000000001','42501','authorization session actor mismatch');
END $$;

DO $$
DECLARE f jsonb; request jsonb; proposal uuid; legal_role uuid; state_version bigint;
  first_decision ops.action_decisions%ROWTYPE; first_assignment ops.action_review_assignments%ROWTYPE;
  key_digest char(64); request_digest char(64);
BEGIN
  SELECT id INTO STRICT legal_role FROM ops.roles WHERE code='LEGAL_REVIEWER';

  f:=pg_temp.new_activation('current-role-revoked'); proposal:=(f->>'proposalId')::uuid;
  UPDATE ops.user_roles SET revoked_at=clock_timestamp(),revoked_by='10000000-0000-4000-8000-000000000001'
    WHERE user_id='20000000-0000-4000-8000-000000000001' AND role_id=legal_role AND revoked_at IS NULL;
  request:=pg_temp.decision_request(f,'legal','APPROVE','20000000-0000-4000-8000-000000000001');
  PERFORM pg_temp.expect_decision_failure(request,'20000000-0000-4000-8000-000000000001',
    '42501','current reviewer role revoked');
  INSERT INTO ops.user_roles(user_id,role_id,granted_by,reason) VALUES(
    '20000000-0000-4000-8000-000000000001',legal_role,
    '10000000-0000-4000-8000-000000000001','restore after negative test');

  f:=pg_temp.new_activation('prior-role-revoked'); proposal:=(f->>'proposalId')::uuid;
  PERFORM pg_temp.submit_decision(f,'legal','APPROVE','20000000-0000-4000-8000-000000000001');
  UPDATE ops.user_roles SET revoked_at=clock_timestamp(),revoked_by='10000000-0000-4000-8000-000000000001'
    WHERE user_id='20000000-0000-4000-8000-000000000001' AND role_id=legal_role AND revoked_at IS NULL;
  request:=pg_temp.decision_request(f,'operational','APPROVE','30000000-0000-4000-8000-000000000001');
  PERFORM pg_temp.expect_decision_failure(request,'30000000-0000-4000-8000-000000000001',
    '42501','prior reviewer role revoked');
  PERFORM pg_temp.assert_true(NOT EXISTS(SELECT 1 FROM ops.execution_authorizations WHERE proposal_id=proposal),
    'revoked prior reviewer must leave execution count zero');
  INSERT INTO ops.user_roles(user_id,role_id,granted_by,reason) VALUES(
    '20000000-0000-4000-8000-000000000001',legal_role,
    '10000000-0000-4000-8000-000000000001','restore after prior-role test');

  f:=pg_temp.new_activation('prior-user-disabled'); proposal:=(f->>'proposalId')::uuid;
  PERFORM pg_temp.submit_decision(f,'legal','APPROVE','20000000-0000-4000-8000-000000000001');
  UPDATE ops.users SET status='DISABLED' WHERE id='20000000-0000-4000-8000-000000000001';
  request:=pg_temp.decision_request(f,'operational','APPROVE','30000000-0000-4000-8000-000000000001');
  PERFORM pg_temp.expect_decision_failure(request,'30000000-0000-4000-8000-000000000001',
    '42501','prior reviewer disabled');
  PERFORM pg_temp.assert_true(NOT EXISTS(SELECT 1 FROM ops.execution_authorizations WHERE proposal_id=proposal),
    'disabled prior reviewer must leave execution count zero');
  UPDATE ops.users SET status='ACTIVE' WHERE id='20000000-0000-4000-8000-000000000001';

  f:=pg_temp.new_activation('withdrawal'); proposal:=(f->>'proposalId')::uuid;
  PERFORM pg_temp.submit_decision(f,'legal','APPROVE','20000000-0000-4000-8000-000000000001');
  SELECT * INTO STRICT first_decision FROM ops.action_decisions
    WHERE proposal_id=proposal AND slot_kind='legal' AND decision_kind='APPROVE';
  SELECT * INTO STRICT first_assignment FROM ops.action_review_assignments WHERE id=first_decision.assignment_id;
  SELECT v.state_version INTO STRICT state_version FROM ops.action_proposal_versions v
    WHERE v.proposal_id=proposal AND v.version=1;
  key_digest:=encode(extensions.digest(convert_to(gen_random_uuid()::text,'UTF8'),'sha256'),'hex');
  request_digest:=encode(extensions.digest(convert_to(gen_random_uuid()::text,'UTF8'),'sha256'),'hex');
  PERFORM * FROM ops.apply_control_addendum_command('withdrawActionDecision',jsonb_build_object(
    'proposalId',proposal,'decisionId',first_decision.id,'expectedProposalVersion',1,
    'expectedProposalStateVersion',state_version,'expectedApprovalDigest',first_decision.approval_digest,
    'expectedAssignmentVersion',first_assignment.version,
    'expectedDecisionReceiptDigest',first_decision.receipt_digest,
    'reasonCode','DECISION_ERROR','reason','runtime withdrawal'),
    '20000000-0000-4000-8000-000000000001',NULL,gen_random_uuid(),key_digest,request_digest);
  request:=pg_temp.decision_request(f,'operational','APPROVE','30000000-0000-4000-8000-000000000001');
  PERFORM pg_temp.expect_decision_failure(request,'30000000-0000-4000-8000-000000000001',
    '42501','prior approval withdrawn');
  PERFORM pg_temp.assert_true(NOT EXISTS(SELECT 1 FROM ops.execution_authorizations WHERE proposal_id=proposal),
    'withdrawn prior approval must leave execution count zero');
END $$;

DO $$
DECLARE f jsonb; proposal uuid; replacement ops.action_review_assignments%ROWTYPE; legal_role uuid;
  request jsonb;
BEGIN
  SELECT id INTO STRICT legal_role FROM ops.roles WHERE code='LEGAL_REVIEWER';
  UPDATE ops.user_roles SET revoked_at=clock_timestamp(),revoked_by='10000000-0000-4000-8000-000000000001'
    WHERE user_id='20000000-0000-4000-8000-000000000002' AND role_id=legal_role AND revoked_at IS NULL;
  f:=pg_temp.new_activation('recuse-vacant'); proposal:=(f->>'proposalId')::uuid;
  PERFORM pg_temp.submit_decision(f,'legal','RECUSE','20000000-0000-4000-8000-000000000001');
  SELECT * INTO STRICT replacement FROM ops.action_review_assignments
    WHERE proposal_id=proposal AND slot_id='legal' AND assignment_generation=2;
  PERFORM pg_temp.assert_true(replacement.state='VACANT' AND replacement.reviewer_id IS NULL
    AND replacement.approve_assurance='STEP_UP'
    AND replacement.allowed_role_codes=ARRAY['LEGAL_REVIEWER']::text[],
    'recusal without eligible replacement must preserve slot as VACANT');
  INSERT INTO ops.user_roles(user_id,role_id,granted_by,reason) VALUES(
    '20000000-0000-4000-8000-000000000002',legal_role,
    '10000000-0000-4000-8000-000000000001','restore after vacant test');

  f:=pg_temp.new_activation('conflict-expiry',interval '6 seconds'); proposal:=(f->>'proposalId')::uuid;
  PERFORM pg_temp.submit_decision(f,'legal','APPROVE','20000000-0000-4000-8000-000000000001');
  PERFORM pg_sleep(5.2);
  request:=pg_temp.decision_request(f,'operational','APPROVE','30000000-0000-4000-8000-000000000001');
  PERFORM pg_temp.expect_decision_failure(request,'30000000-0000-4000-8000-000000000001',
    '40001','current conflict snapshot expired');
  PERFORM pg_temp.assert_true(NOT EXISTS(SELECT 1 FROM ops.execution_authorizations WHERE proposal_id=proposal),
    'expired conflict must leave execution count zero');
END $$;

SELECT 'capability activation quorum runtime: PASS' AS result;
SQL
