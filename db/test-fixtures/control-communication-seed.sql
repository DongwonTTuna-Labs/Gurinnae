-- Read-only communication receipt witness used by the control-flow matrix.
-- The delivery is backed by endpoint, preflight and reservation records so
-- the receipt query exercises the same FK-bound evidence path as production.
BEGIN;
DO $$
DECLARE
  d constant char(64) := repeat('b',64);
  integration constant uuid := '73100000-0000-4000-8000-000000000011';
  delivery constant uuid := '99999999-9999-4999-8999-999999999999';
  endpoint constant uuid := '0f6d16aa-3c47-5e6a-9c5e-c0c33c45d7a8';
  link_event constant uuid := 'b9c4a581-5b9f-5d6e-9953-7a3c979d74a1';
  preflight constant uuid := 'd8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef';
  reservation constant uuid := '7f0f0a74-4a15-5b79-b3ae-0fdac4308a6d';
  rendering constant uuid := 'e1e7f6f7-8c52-5c32-8f1f-2fef5f7c9d71';
  receipt constant uuid := 'e2d2e5d3-3d9f-5c1b-9c58-7d80e28f9f10';
  v_provider_revision_snapshot jsonb;
  v_configuration_digest char(64);
  now_at timestamptz := clock_timestamp();
BEGIN
  v_provider_revision_snapshot := jsonb_build_object(
    'id','59e6fe3c-6803-5f19-8ee2-1595abc421a8'::uuid,
    'integrationId',integration,'deploymentId','control','environment','test',
    'channel','SMTP_EMAIL','adapterId','smtp-email-v1','version',1::bigint,
    'providerAccountHmac',btrim(d::text),
    'senderIdentityCiphertextDigest',encode(extensions.digest(
      convert_to(rpad('sender',32,' '),'UTF8'),'sha256'),'hex'),
    'senderIdentityHmac',btrim(d::text),'encryptionKeyId','fixture-key',
    'credentialSecretReference','secret://control-provider/value@v1',
    'webhookSecretReference',to_jsonb('secret://control-webhook/value@v1'::text),
    'callbackPath',to_jsonb('/private/v1/callbacks/control'::text),
    'callbackAllowlistDigest',to_jsonb(btrim(d::text)),
    'jurisdictionSetDigest',btrim(d::text),'dpaEvidenceDigest',btrim(d::text),
    'approvedTemplateCatalogDigest',btrim(d::text),
    'rateLimitPolicyDigest',btrim(d::text),'costPolicyDigest',btrim(d::text),
    'providerCapabilitiesDigest',btrim(d::text),'killSwitchCode','CONTROL_FIXTURE');
  v_configuration_digest := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_provider_revision_snapshot),'sha256'),'hex');

  INSERT INTO intake.communication_subjects(
    id,subject_kind,origin_object_type,origin_object_id,origin_object_version,
    origin_binding_digest,subject_pseudonym_hmac,hmac_key_version,jurisdiction,
    locale,status,profile_version,profile_digest)
  VALUES('11111111-1111-4111-8111-111111111111','INTERNAL_USER','INTERNAL_USER',
    '11111111-1111-4111-8111-111111111111',1,d,d,'fixture-v1','KR','ko-KR',
    'ACTIVE',1,d)
  ON CONFLICT DO NOTHING;

  INSERT INTO intake.communication_endpoints(
    id,subject_id,channel,endpoint_hmac,hmac_key_version,endpoint_ciphertext,
    encryption_key_id,state,version,endpoint_digest,verified_at)
  VALUES(endpoint,'11111111-1111-4111-8111-111111111111','SMTP_EMAIL',d,'fixture-v1',
    convert_to(rpad('fixture-endpoint',32,' '),'UTF8'),'fixture-key','ACTIVE',1,d,now_at)
  ON CONFLICT DO NOTHING;

  INSERT INTO intake.communication_endpoint_link_events(
    id,subject_id,subject_origin_binding_digest,endpoint_id,endpoint_sequence,
    profile_version,endpoint_version,endpoint_hmac,endpoint_digest,channel,state,change_kind,
    proof_digest,reason_code,endpoint_snapshot_digest,
    event_digest,audit_event_id,receipt_digest,occurred_at)
  VALUES(link_event,'11111111-1111-4111-8111-111111111111',d,endpoint,1,1,1,d,d,
    'SMTP_EMAIL','ACTIVE','VERIFIED',d,'CONTROL_FIXTURE',d,d,gen_random_uuid(),d,now_at)
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.communication_provider_configs(
    id,integration_id,deployment_id,environment,channel,adapter_id,operational_state,version,
    provider_account_hmac,sender_identity_ciphertext,sender_identity_hmac,
    encryption_key_id,credential_secret_reference,webhook_secret_reference,
    callback_path,callback_allowlist_digest,jurisdiction_set,jurisdiction_set_digest,
    dpa_evidence_digest,approved_template_catalog_digest,rate_limit_policy,
    rate_limit_policy_digest,cost_policy,cost_policy_digest,provider_capabilities,
    provider_capabilities_digest,kill_switch_code,configuration_digest,created_by,
    updated_by)
  VALUES('59e6fe3c-6803-5f19-8ee2-1595abc421a8',integration,'control','test','SMTP_EMAIL',
    'smtp-email-v1','DISABLED',1,d,convert_to(rpad('sender',32,' '),'UTF8'),d,
    'fixture-key','secret://control-provider/value@v1','secret://control-webhook/value@v1',
    '/private/v1/callbacks/control',d,'{}'::jsonb,d,d,d,'{}'::jsonb,d,'{}'::jsonb,d,
    '{}'::jsonb,d,'CONTROL_FIXTURE',v_configuration_digest,'11111111-1111-4111-8111-111111111111',
    '11111111-1111-4111-8111-111111111111')
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.communication_provider_preflight_receipts(
    id,provider_config_id,provider_config_version,configuration_digest,
    provider_revision_snapshot,provider_revision_snapshot_digest,test_generation,
    test_environment,result,live_sandbox,callback_or_poll_verified,
    sender_identity_verified,template_catalog_verified,idempotency_capability,
    reconciliation_capability,highest_delivery_proof,checklist,checklist_digest,
    blocker_set,blocker_set_digest,provider_evidence_digest,
    contract_test_receipt_digest,receipt_digest,performed_by_service,requested_by,
    started_at,completed_at,expires_at)
  VALUES(preflight,'59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,v_configuration_digest,
    v_provider_revision_snapshot,v_configuration_digest,1,
    'test','PASS',true,true,true,true,'NATIVE_IDEMPOTENCY','AUTHENTICATED_POLL',
    'DELIVERED','{}'::jsonb,d,'[]'::jsonb,d,d,d,d,'control-fixture',
    '11111111-1111-4111-8111-111111111111',now_at,now_at,now_at+interval '1 day')
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.budget_reservations(
    id,reservation_key_digest,reservation_digest,reservation_source_kind,effect_id,
    effect_generation,attempt,deployment_environment,case_id,provider_candidate_id,
    provider_config_id,provider_config_version,provider_configuration_digest,
    pricing_version,reserved_amount,currency,ledger_scope_digest,last_transition_id,
    last_transition_digest,expires_at,created_at,updated_at)
  VALUES(reservation,d,d,'ACTION_EXECUTION',
    'f4e7c4f1-7b4d-5d2e-9d7c-7e53dbdf7c7d',1,1,'TEST',
    '148b09d5-aa28-5351-b471-9ef333a3e410','control-fixture-provider',
    '59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,v_configuration_digest,'control-v1',1,'KRW',d,
    gen_random_uuid(),d,now_at+interval '1 day',now_at,now_at)
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.communication_intents(
    id,deployment_id,logical_intent_digest,source_event_id,source_event_type,
    source_object_type,source_object_id,material_event_version,communication_class,
    purpose,topic_scope,topic_scope_digest,recipient_subject_id,
    audience_policy_version,audience_policy_digest,policy_snapshot_digest,
    effect_safety_class,source_decision_receipt_id,source_decision_digest,state,
    version,intent_digest,creation_receipt_digest,created_at,state_changed_at)
  VALUES('4a1c75f0-a2ec-5bd4-9e85-b8f57fe4f158','control',d,gen_random_uuid(),
    'control.fixture','CASE','148b09d5-aa28-5351-b471-9ef333a3e410',1,
    'SYSTEM_TRANSACTIONAL','SECURITY_TRANSACTIONAL_NOTICE','{}'::jsonb,d,
    '11111111-1111-4111-8111-111111111111','policy-v1',d,d,
    'DUPLICATION_TOLERANT',gen_random_uuid(),d,'CREATED',1,d,d,now_at,now_at)
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.communication_renderings(
    id,intent_id,rendering_revision,endpoint_id,endpoint_version,endpoint_snapshot_digest,
    channel,locale,template_id,template_revision,variable_set,variable_set_digest,
    attachment_manifest,attachment_manifest_digest,disclosure_class,semantic_payload_digest,
    recipient_binding_digest,rendered_envelope_ciphertext,encryption_key_id,rendered_sha256,
    rendered_byte_length,transport_content_type,state,state_version,rendering_digest,
    transition_receipt_digest,expires_at,created_at)
  VALUES(rendering,'4a1c75f0-a2ec-5bd4-9e85-b8f57fe4f158',1,endpoint,1,d,'SMTP_EMAIL','ko-KR',
    'control-fixture','v1','{}'::jsonb,d,'[]'::jsonb,d,'INTERNAL_MINIMAL',d,d,
    convert_to(rpad('fixture-rendered-envelope',32,' '),'UTF8'),'fixture-key',d,32,
    'text/plain','DRAFT',1,d,d,now_at+interval '1 day',now_at)
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.outbound_deliveries(
    id,contract_version,dispatch_eligible,intent_id,intent_digest,rendering_id,endpoint_id,endpoint_version,
    endpoint_snapshot_digest,provider_config_id,provider_config_version,
    provider_configuration_digest,provider_preflight_receipt_id,
    provider_preflight_receipt_digest,channel,delivery_key,rendered_sha256,
    rendering_digest,authorization_snapshot_digest,activation_receipt_digest,
    budget_reservation_id,provider_idempotency_key_sha256,delivery_digest,state,
    version,generation,event_sequence,receipt_sequence,attempt_count,max_attempts,
    current_evidence_rank,highest_proof_level,not_before,next_attempt_at,queued_at,
    updated_at,message_type,recipient_hash,template_version)
  VALUES(delivery,'COMMUNICATION_V1',false,'4a1c75f0-a2ec-5bd4-9e85-b8f57fe4f158',d,rendering,endpoint,1,d,
    '59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,v_configuration_digest,preflight,d,'SMTP_EMAIL',d,d,d,d,
    d,reservation,d,d,'DELIVERED',2,1,2,1,1,3,50,'DELIVERED',now_at,now_at,now_at,
    now_at,'COMMUNICATION',d,'v1')
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.outbound_delivery_attempts(
    id,delivery_id,attempt_ordinal,dispatch_generation,delivery_version_at_claim,
    endpoint_id,endpoint_version,endpoint_snapshot_digest,provider_config_id,
    provider_config_version,configuration_digest,provider_preflight_receipt_id,
    provider_preflight_receipt_digest,budget_reservation_id,worker_id,
    lease_token_hash,fencing_token,provider_idempotency_key_sha256,request_sha256,
    rendered_sha256,authorization_snapshot_digest,suppression_snapshot_digest,
    activation_receipt_digest,policy_fence_digest,transport_policy_version,
    deadline_at,claimed_at,lease_expires_at,attempt_digest,claim_receipt_digest,
    audit_event_id)
  VALUES('c0d5cb1a-e63b-5e23-92ef-8d94ea73bf03',delivery,1,1,1,endpoint,1,d,
    '59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,v_configuration_digest,preflight,d,reservation,
    'control-fixture-worker',d,1,d,d,d,d,d,d,d,'communication-v1',
    now_at+interval '2 hours',now_at,now_at+interval '1 hour',d,d,gen_random_uuid())
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.outbound_delivery_receipts(
    id,delivery_id,receipt_sequence,event_aggregate_version,prior_delivery_version,delivery_version,attempt_id,
    source_kind,observation_key_digest,projection_disposition,evidence_kind,
    evidence_rank,prior_state,asserted_state,resulting_state,prior_proof_level,
    resulting_proof_level,applied,provider_evidence_digest,rendering_digest,
    endpoint_id,endpoint_version,endpoint_snapshot_digest,endpoint_identity_hash,
    provider_preflight_receipt_id,provider_config_id,provider_config_version,
    provider_configuration_digest,provider_preflight_receipt_digest,
    provider_identity_hash,authorization_snapshot_digest,activation_receipt_digest,
    budget_reservation_id,observed_at,actor_type,actor_id,request_id,trace_id,
    receipt_digest,audit_event_id,outbox_event_id)
  VALUES(receipt,delivery,1,2,1,2,'c0d5cb1a-e63b-5e23-92ef-8d94ea73bf03','PROVIDER_RESPONSE',d,'APPLIED','PROVIDER_RESPONSE',50,
    'QUEUED','DELIVERED','DELIVERED','NONE','DELIVERED',true,d,d,endpoint,1,d,d,
    preflight,'59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,v_configuration_digest,d,d,d,d,reservation,now_at,
    'AUTHORIZED_SERVICE',NULL,gen_random_uuid(),'control-fixture',d,
    gen_random_uuid(),gen_random_uuid())
  ON CONFLICT DO NOTHING;
END $$;

-- Separate RECONCILIATION_REQUIRED delivery used by the mutation paths.  Its
-- latest applied receipt is a pre-dispatch fence, proving that no provider
-- request was committed before the NOT_TRANSMITTED decision.
DO $$
DECLARE
  d constant char(64) := repeat('b',64);
  delivery constant uuid := 'df840f91-449c-5f6d-8d5b-b7adcfdaf93f';
  endpoint constant uuid := '0f6d16aa-3c47-5e6a-9c5e-c0c33c45d7a8';
  rendering constant uuid := 'e1e7f6f7-8c52-5c32-8f1f-2fef5f7c9d71';
  intent constant uuid := '4a1c75f0-a2ec-5bd4-9e85-b8f57fe4f158';
  preflight constant uuid := 'd8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef';
  reservation constant uuid := '7f0f0a74-4a15-5b79-b3ae-0fdac4308a6d';
  attempt constant uuid := '2b6d8bf1-3c56-5e4b-9a5d-6d9e4f8c1b20';
  receipt constant uuid := 'f3c6e7d8-4e0a-5d2c-8b69-1e2f3a4c5d60';
  v_config_digest char(64);
  now_at timestamptz := clock_timestamp();
BEGIN
  SELECT pc.configuration_digest INTO STRICT v_config_digest
    FROM ops.communication_provider_configs pc
   WHERE pc.id='59e6fe3c-6803-5f19-8ee2-1595abc421a8' AND pc.version=1;

  INSERT INTO ops.outbound_deliveries(
    id,contract_version,dispatch_eligible,intent_id,intent_digest,rendering_id,endpoint_id,endpoint_version,
    endpoint_snapshot_digest,provider_config_id,provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_id,provider_preflight_receipt_digest,channel,delivery_key,rendered_sha256,
    rendering_digest,authorization_snapshot_digest,activation_receipt_digest,budget_reservation_id,
    provider_idempotency_key_sha256,delivery_digest,state,version,generation,event_sequence,receipt_sequence,
    attempt_count,max_attempts,current_evidence_rank,highest_proof_level,not_before,next_attempt_at,queued_at,
    updated_at,message_type,recipient_hash,template_version)
  VALUES(delivery,'COMMUNICATION_V1',false,intent,d,rendering,endpoint,1,d,
    '59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,v_config_digest,preflight,d,'SMTP_EMAIL',repeat('d',64),d,d,d,d,
    reservation,repeat('d',64),d,'RECONCILIATION_REQUIRED',2,1,2,1,1,3,50,'NONE',now_at,now_at,now_at,
    now_at,'COMMUNICATION',d,'v1')
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.outbound_delivery_attempts(
    id,delivery_id,attempt_ordinal,dispatch_generation,delivery_version_at_claim,endpoint_id,endpoint_version,
    endpoint_snapshot_digest,provider_config_id,provider_config_version,configuration_digest,
    provider_preflight_receipt_id,provider_preflight_receipt_digest,budget_reservation_id,worker_id,
    lease_token_hash,fencing_token,provider_idempotency_key_sha256,request_sha256,rendered_sha256,
    authorization_snapshot_digest,suppression_snapshot_digest,activation_receipt_digest,policy_fence_digest,
    transport_policy_version,deadline_at,claimed_at,lease_expires_at,attempt_digest,claim_receipt_digest,audit_event_id)
  VALUES(attempt,delivery,1,1,1,endpoint,1,d,'59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,v_config_digest,preflight,d,
    reservation,'control-reconcile-fixture-worker',d,2,d,d,d,d,d,d,d,'communication-v1',now_at+interval '2 hours',
    now_at,now_at+interval '1 hour',repeat('a',64),repeat('9',64),gen_random_uuid())
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.outbound_delivery_receipts(
    id,delivery_id,receipt_sequence,event_aggregate_version,prior_delivery_version,delivery_version,attempt_id,
    source_kind,observation_key_digest,projection_disposition,evidence_kind,evidence_rank,prior_state,
    asserted_state,resulting_state,prior_proof_level,resulting_proof_level,applied,provider_evidence_digest,
    rendering_digest,endpoint_id,endpoint_version,endpoint_snapshot_digest,endpoint_identity_hash,
    provider_preflight_receipt_id,provider_config_id,provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_digest,provider_identity_hash,authorization_snapshot_digest,activation_receipt_digest,
    budget_reservation_id,observed_at,actor_type,actor_id,request_id,trace_id,receipt_digest,audit_event_id,outbox_event_id)
  VALUES(receipt,delivery,1,2,1,2,attempt,'DISPATCH_FENCE',repeat('e',64),'APPLIED','PRE_DISPATCH_FENCE',50,
    'SENDING','RECONCILIATION_REQUIRED','RECONCILIATION_REQUIRED','NONE','NONE',true,d,d,endpoint,1,d,d,
    preflight,'59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,v_config_digest,d,d,d,d,reservation,now_at,'AUTHORIZED_SERVICE',NULL,
    gen_random_uuid(),'control-reconcile-fixture',repeat('f',64),gen_random_uuid(),gen_random_uuid())
  ON CONFLICT DO NOTHING;
END $$;
COMMIT;

-- R6d response-organization identity witness.  This fixture deliberately
-- separates the consumed EMAIL_LINK proof from the organization/domain
-- authority receipt: the raw verification UUID is never an official-channel
-- assertion.  Submission and editorial materialization still cross their
-- production owner functions, so the HTTP identity command receives the same
-- reciprocal receipt graph as a real response.
BEGIN;
DO $$
<<r6d_response_identity_fixture>>
DECLARE
  case_id constant uuid := '148b09d5-aa28-5351-b471-9ef333a3e410';
  organization_id constant uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  identity_actor_id constant uuid := '11111111-1111-4111-8111-111111111111';
  independent_verifier_id constant uuid := '22222222-2222-4222-8222-222222222222';
  request_id constant uuid := 'd61d0000-0000-4000-8000-000000000001';
  subject_id constant uuid := 'd61d0000-0000-4000-8000-000000000002';
  endpoint_id constant uuid := 'd61d0000-0000-4000-8000-000000000003';
  link_event_id constant uuid := 'd61d0000-0000-4000-8000-000000000004';
  verification_id constant uuid := 'd61d0000-0000-4000-8000-000000000005';
  official_assertion_id constant uuid := 'd61d0000-0000-4000-8000-000000000006';
  communication_profile_session_id constant uuid := 'd61d0000-0000-4000-8000-000000000007';
  response_session_id constant uuid := 'd61d0000-0000-4000-8000-000000000008';
  draft_id constant uuid := 'd61d0000-0000-4000-8000-000000000009';
  submission_id constant uuid := 'd61d0000-0000-4000-8000-00000000000a';
  intent_id constant uuid := 'd61d0000-0000-4000-8000-00000000000b';
  rendering_id constant uuid := 'd61d0000-0000-4000-8000-00000000000c';
  delivery_id constant uuid := 'd61d0000-0000-4000-8000-00000000000d';
  attempt_id constant uuid := 'd61d0000-0000-4000-8000-00000000000e';
  delivery_receipt_id constant uuid := 'd61d0000-0000-4000-8000-00000000000f';
  sent_receipt_id constant uuid := 'd61d0000-0000-4000-8000-000000000010';
  authority_session_id constant uuid := '44444444-4444-4444-8444-444444444444';
  authority_step_up_id constant uuid := 'd61d0000-0000-4000-8000-000000000020';
  authority_receipt_id constant uuid := 'd61d0000-0000-4000-8000-000000000021';
  authority_actor_assertion_jti constant uuid := 'd61d0000-0000-4000-8000-000000000022';
  authority_request_id constant uuid := 'd61d0000-0000-4000-8000-000000000023';
  revoked_verification_id constant uuid := 'd61d0000-0000-4000-8000-00000000001c';
  revoked_assertion_id constant uuid := 'd61d0000-0000-4000-8000-00000000001d';
  revocation_id constant uuid := 'd61d0000-0000-4000-8000-00000000001e';
  revoked_request_id constant uuid := 'd61d0000-0000-4000-8000-000000000030';
  revoked_subject_id constant uuid := 'd61d0000-0000-4000-8000-000000000031';
  revoked_endpoint_id constant uuid := 'd61d0000-0000-4000-8000-000000000032';
  revoked_link_event_id constant uuid := 'd61d0000-0000-4000-8000-000000000033';
  revoked_profile_session_id constant uuid := 'd61d0000-0000-4000-8000-000000000034';
  revoked_intent_id constant uuid := 'd61d0000-0000-4000-8000-000000000035';
  revoked_rendering_id constant uuid := 'd61d0000-0000-4000-8000-000000000036';
  revoked_delivery_id constant uuid := 'd61d0000-0000-4000-8000-000000000037';
  revoked_attempt_id constant uuid := 'd61d0000-0000-4000-8000-000000000038';
  revoked_delivery_receipt_id constant uuid := 'd61d0000-0000-4000-8000-000000000039';
  revoked_sent_receipt_id constant uuid := 'd61d0000-0000-4000-8000-00000000003a';
  revoked_authority_step_up_id constant uuid := 'd61d0000-0000-4000-8000-000000000024';
  revoked_authority_receipt_id constant uuid := 'd61d0000-0000-4000-8000-000000000025';
  revoked_authority_actor_assertion_jti constant uuid := 'd61d0000-0000-4000-8000-000000000026';
  revoked_authority_request_id constant uuid := 'd61d0000-0000-4000-8000-000000000027';
  revocation_session_id constant uuid := '22222222-2222-4222-8222-222222222222';
  revocation_step_up_id constant uuid := 'd61d0000-0000-4000-8000-000000000028';
  revocation_actor_assertion_jti constant uuid := 'd61d0000-0000-4000-8000-000000000029';
  revocation_request_id constant uuid := 'd61d0000-0000-4000-8000-00000000002a';
  provider_config_id constant uuid := '59e6fe3c-6803-5f19-8ee2-1595abc421a8';
  provider_preflight_id constant uuid := 'd8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef';
  budget_reservation_id constant uuid := '7f0f0a74-4a15-5b79-b3ae-0fdac4308a6d';
  provider_receipt_digest constant char(64) := repeat('b',64);
  v_base_at timestamptz;
  v_revoked_base_at timestamptz;
  v_answers bytea := convert_to('R6d agency response fixture','UTF8');
  v_consent jsonb;
  v_config_digest char(64);
  v_request_binding char(64);
  v_subject_hmac char(64);
  v_subject_profile char(64);
  v_endpoint_hmac char(64);
  v_endpoint_digest char(64);
  v_link_proof char(64);
  v_link_event_digest char(64);
  v_link_receipt_digest char(64);
  v_verification_binding char(64);
  v_verification_proof char(64);
  v_verification_receipt char(64);
  v_intent_digest char(64);
  v_rendering_digest char(64);
  v_rendered_sha char(64);
  v_delivery_key char(64);
  v_delivery_digest char(64);
  v_attempt_digest char(64);
  v_claim_receipt_digest char(64);
  v_observation_digest char(64);
  v_provider_evidence char(64);
  v_endpoint_identity char(64);
  v_provider_identity char(64);
  v_delivery_receipt_digest char(64);
  v_sent_receipt_digest char(64);
  v_submission_sha char(64);
  v_submit_idempotency char(64);
  v_submit_request_digest char(64);
  v_materialize_idempotency char(64);
  v_materialize_request_digest char(64);
  v_authority_action_digest char(64);
  v_authority_idempotency_digest char(64);
  v_authority_request_digest char(64);
  v_authority_reason_digest char(64);
  v_authority_step_up ops.step_up_authorizations%ROWTYPE;
  v_authority_step_up_payload jsonb;
  v_authority_step_up_receipt_digest char(64);
  v_authority_source jsonb;
  v_authority_source_snapshot jsonb;
  v_authority_source_snapshot_canonical bytea;
  v_authority_source_snapshot_digest char(64);
  v_authority_payload jsonb;
  v_authority_canonical bytea;
  v_authority_receipt_digest char(64);
  v_authority_audit_id uuid;
  v_authority_audit_digest char(64);
  v_authority_outbox_id uuid;
  v_source_binding jsonb;
  v_source_binding_canonical bytea;
  v_source_binding_digest char(64);
  v_assertion jsonb;
  v_assertion_canonical bytea;
  v_assertion_digest char(64);
  v_registry_receipt jsonb;
  v_registry_receipt_canonical bytea;
  v_registry_receipt_digest char(64);
  v_registry_result jsonb;
  v_revoked_verification_binding char(64);
  v_revoked_verification_proof char(64);
  v_revoked_verification_receipt char(64);
  v_revoked_request_binding char(64);
  v_revoked_subject_hmac char(64);
  v_revoked_subject_profile char(64);
  v_revoked_endpoint_hmac char(64);
  v_revoked_endpoint_digest char(64);
  v_revoked_link_proof char(64);
  v_revoked_link_event_digest char(64);
  v_revoked_link_receipt_digest char(64);
  v_revoked_intent_digest char(64);
  v_revoked_rendering_digest char(64);
  v_revoked_rendered_sha char(64);
  v_revoked_delivery_key char(64);
  v_revoked_delivery_digest char(64);
  v_revoked_attempt_digest char(64);
  v_revoked_claim_receipt_digest char(64);
  v_revoked_observation_digest char(64);
  v_revoked_provider_evidence char(64);
  v_revoked_endpoint_identity char(64);
  v_revoked_provider_identity char(64);
  v_revoked_delivery_receipt_digest char(64);
  v_revoked_sent_receipt_digest char(64);
  v_revoked_authority_action_digest char(64);
  v_revoked_authority_idempotency_digest char(64);
  v_revoked_authority_request_digest char(64);
  v_revoked_authority_reason_digest char(64);
  v_revoked_authority_step_up ops.step_up_authorizations%ROWTYPE;
  v_revoked_authority_step_up_payload jsonb;
  v_revoked_authority_step_up_receipt_digest char(64);
  v_revoked_authority_source jsonb;
  v_revoked_authority_source_snapshot jsonb;
  v_revoked_authority_source_snapshot_canonical bytea;
  v_revoked_authority_source_snapshot_digest char(64);
  v_revoked_authority_payload jsonb;
  v_revoked_authority_canonical bytea;
  v_revoked_authority_receipt_digest char(64);
  v_revoked_authority_audit_id uuid;
  v_revoked_authority_audit_digest char(64);
  v_revoked_authority_outbox_id uuid;
  v_revocation_action_digest char(64);
  v_revocation_idempotency_digest char(64);
  v_revocation_request_digest char(64);
  v_revocation_step_up ops.step_up_authorizations%ROWTYPE;
  v_revocation_step_up_payload jsonb;
  v_revocation_step_up_receipt_digest char(64);
  v_revocation_audit_id uuid;
  v_revocation_audit_digest char(64);
  v_revocation_outbox_id uuid;
  v_revoked_source_binding jsonb;
  v_revoked_source_binding_canonical bytea;
  v_revoked_source_binding_digest char(64);
  v_revoked_assertion jsonb;
  v_revoked_assertion_canonical bytea;
  v_revoked_assertion_digest char(64);
  v_revoked_registry_receipt jsonb;
  v_revoked_registry_receipt_canonical bytea;
  v_revoked_registry_receipt_digest char(64);
  v_revocation_reason_digest char(64);
  v_revocation jsonb;
  v_revocation_canonical bytea;
  v_revocation_receipt_digest char(64);
  v_submit_result jsonb;
  v_submit_receipt intake.response_submission_receipts_v3%ROWTYPE;
  v_materialize_input editorial.response_submission_intake_materialize_v1;
  v_materialize_result editorial.response_submission_intake_materialize_receipt_v2;
  v_response editorial.responses%ROWTYPE;
BEGIN
  SELECT configuration_digest INTO STRICT v_config_digest
  FROM ops.communication_provider_configs
  WHERE id=provider_config_id AND version=1;

  v_endpoint_hmac:=encode(extensions.digest(convert_to(
    'r6d-response-identity-endpoint-hmac','UTF8'),'sha256'),'hex');
  v_endpoint_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('subjectId',subject_id,'channel','SMTP_EMAIL',
      'endpointHmac',v_endpoint_hmac,'version',1)
  ),'sha256'),'hex');
  v_request_binding:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('responseRequestId',request_id,'caseId',case_id,
      'partyType','AGENCY','partyEntityId',organization_id,
      'requestVersion',2,'endpointId',endpoint_id,'endpointVersion',1,
      'endpointSnapshotDigest',v_endpoint_digest)
  ),'sha256'),'hex');

  INSERT INTO editorial.response_requests(
    id,case_id,party_type,party_entity_id,party_name,recipient_email_hash,
    recipient_email_encrypted,questions,requested_publication_scope,due_at,
    effective_due_at,sent_at,status,version,created_by)
  VALUES(
    request_id,case_id,'AGENCY',organization_id,'Control identity agency',
    encode(extensions.digest(convert_to(
      'r6d-response-identity-recipient','UTF8'),'sha256'),'hex'),
    convert_to('sealed-r6d-agency-recipient','UTF8'),
    jsonb_build_array('공개 기록에 대한 기관 답변'),
    jsonb_build_object('body',true,'identity','ORGANIZATION_NAME'),
    clock_timestamp()+interval '7 days',clock_timestamp()+interval '7 days',
    clock_timestamp(),'SENT',2,identity_actor_id)
  ON CONFLICT DO NOTHING;
  SELECT created_at INTO STRICT v_base_at
  FROM editorial.response_requests WHERE id=request_id;

  -- Receipt ownership is independently bounded for each assertion.  These
  -- TEST_ONLY step-up rows are inputs to the same canonical receipt ABI used
  -- by the 0039 D2 owner; their hashes are derived here, never accepted from a
  -- caller as the organization-authority digest.
  v_authority_action_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-authority-action','UTF8'),'sha256'),'hex');
  v_authority_idempotency_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-authority-idempotency','UTF8'),'sha256'),'hex');
  v_authority_request_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-authority-request','UTF8'),'sha256'),'hex');
  v_revoked_authority_action_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-authority-action','UTF8'),'sha256'),'hex');
  v_revoked_authority_idempotency_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-authority-idempotency','UTF8'),'sha256'),'hex');
  v_revoked_authority_request_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-authority-request','UTF8'),'sha256'),'hex');
  v_revocation_action_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revocation-action','UTF8'),'sha256'),'hex');
  v_revocation_idempotency_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revocation-idempotency','UTF8'),'sha256'),'hex');
  v_revocation_request_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revocation-request','UTF8'),'sha256'),'hex');
  INSERT INTO ops.step_up_authorizations(
    id,session_id,action_digest,idempotency_key_sha256,
    authorization_token_hash,expires_at,assertion_issue_count,
    max_assertion_issues,created_at,last_issued_at)
  VALUES
    (authority_step_up_id,authority_session_id,v_authority_action_digest,
      v_authority_idempotency_digest,encode(extensions.digest(convert_to(
        'r6d-response-identity-authority-step-up-token','UTF8'),'sha256'),'hex'),
      v_base_at+interval '4 minutes',1,3,v_base_at,v_base_at),
    (revoked_authority_step_up_id,authority_session_id,
      v_revoked_authority_action_digest,v_revoked_authority_idempotency_digest,
      encode(extensions.digest(convert_to(
        'r6d-response-identity-revoked-authority-step-up-token','UTF8'),
        'sha256'),'hex'),v_base_at+interval '4 minutes',1,3,v_base_at,v_base_at),
    (revocation_step_up_id,revocation_session_id,v_revocation_action_digest,
      v_revocation_idempotency_digest,encode(extensions.digest(convert_to(
        'r6d-response-identity-revocation-step-up-token','UTF8'),
        'sha256'),'hex'),v_base_at+interval '4 minutes',1,3,v_base_at,v_base_at)
  ON CONFLICT DO NOTHING;

  v_subject_hmac:=encode(extensions.digest(convert_to(
    'r6d-response-identity-subject-hmac','UTF8'),'sha256'),'hex');
  v_subject_profile:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('subjectId',subject_id,'originType','RESPONSE_REQUEST',
      'originId',request_id,'originVersion',2,'partyType','AGENCY',
      'partyEntityId',organization_id)
  ),'sha256'),'hex');
  INSERT INTO intake.communication_subjects(
    id,subject_kind,origin_object_type,origin_object_id,origin_object_version,
    origin_binding_digest,subject_pseudonym_hmac,hmac_key_version,
    jurisdiction,locale,status,profile_version,profile_digest,created_at,updated_at)
  VALUES(subject_id,'RESPONSE_PARTY','RESPONSE_REQUEST',request_id,2,
    v_request_binding,v_subject_hmac,'r6d-fixture-v1','KR','ko-KR','ACTIVE',1,
    v_subject_profile,v_base_at,v_base_at)
  ON CONFLICT DO NOTHING;

  INSERT INTO intake.communication_endpoints(
    id,subject_id,channel,endpoint_hmac,hmac_key_version,endpoint_ciphertext,
    encryption_key_id,state,version,endpoint_digest,verified_at,created_at,updated_at)
  VALUES(endpoint_id,subject_id,'SMTP_EMAIL',v_endpoint_hmac,'r6d-fixture-v1',
    convert_to('sealed-r6d-agency-endpoint','UTF8'),'fixture-key','ACTIVE',1,
    v_endpoint_digest,v_base_at,v_base_at,v_base_at)
  ON CONFLICT DO NOTHING;

  INSERT INTO intake.submission_sessions(
    id,token_hash,session_kind,scope_type,scope_id,bff_issuer,status,version,
    issued_at,expires_at)
  VALUES(
    communication_profile_session_id,
    encode(extensions.digest(convert_to(
      'r6d-response-identity-profile-session','UTF8'),'sha256'),'hex'),
    'COMMUNICATION_PROFILE','COMMUNICATION_SUBJECT',subject_id,
    'response-portal','ACTIVE',1,v_base_at,v_base_at+interval '23 hours')
  ON CONFLICT DO NOTHING;

  -- The legacy communication schema has reciprocal immediate FKs between the
  -- verification and its link event.  Install this disposable TEST_ONLY root
  -- atomically under replica mode, then restore every production guard before
  -- any authority receipt is resolved or written.
  PERFORM set_config('session_replication_role','replica',true);
  v_verification_binding:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('subjectId',subject_id,'endpointId',endpoint_id,
      'endpointVersion',1,'challengeKind','EMAIL_LINK')
  ),'sha256'),'hex');
  v_verification_proof:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('verificationId',verification_id,
      'verificationBindingDigest',v_verification_binding,
      'verifiedAt',v_base_at,'consumedAt',v_base_at)
  ),'sha256'),'hex');
  v_verification_receipt:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('verificationId',verification_id,
      'proofDigest',v_verification_proof,'state','VERIFIED',
      'endpointSnapshotDigest',v_endpoint_digest)
  ),'sha256'),'hex');
  INSERT INTO intake.communication_endpoint_verifications(
    id,subject_id,subject_origin_binding_digest,endpoint_id,endpoint_version,
    endpoint_snapshot_digest,profile_session_id,challenge_kind,challenge_hash,
    nonce_hash,verification_binding_digest,state,attempt_count,max_attempts,
    version,proof_digest,receipt_digest,issued_at,expires_at,verified_at,consumed_at)
  VALUES(verification_id,subject_id,v_request_binding,endpoint_id,1,
    v_endpoint_digest,communication_profile_session_id,'EMAIL_LINK',
    encode(extensions.digest(convert_to(
      'r6d-response-identity-email-link','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-email-link-nonce','UTF8'),'sha256'),'hex'),
    v_verification_binding,'VERIFIED',1,3,1,v_verification_proof,
    v_verification_receipt,v_base_at-interval '5 minutes',
    v_base_at+interval '23 hours',v_base_at,v_base_at)
  ON CONFLICT DO NOTHING;

  -- The latest endpoint-link event is the immutable bridge from the endpoint
  -- revision to this exact consumed EMAIL_LINK verification.  0039 resolves
  -- that row again when both the authority receipt and assertion are inserted.
  v_link_proof:=encode(extensions.digest(convert_to(
    'r6d-response-identity-link-proof','UTF8'),'sha256'),'hex');
  v_link_event_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('subjectId',subject_id,'endpointId',endpoint_id,
      'endpointSequence',1,'endpointVersion',1,'state','ACTIVE',
      'changeKind','VERIFIED','verificationId',verification_id,
      'proofDigest',v_link_proof)
  ),'sha256'),'hex');
  v_link_receipt_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('eventId',link_event_id,
      'eventDigest',v_link_event_digest,'occurredAt',v_base_at)
  ),'sha256'),'hex');
  INSERT INTO intake.communication_endpoint_link_events(
    id,subject_id,subject_origin_binding_digest,endpoint_id,endpoint_sequence,
    profile_version,endpoint_version,endpoint_hmac,endpoint_digest,channel,
    state,change_kind,profile_session_id,verification_id,proof_digest,reason_code,
    endpoint_snapshot_digest,event_digest,audit_event_id,receipt_digest,occurred_at)
  VALUES(link_event_id,subject_id,v_request_binding,endpoint_id,1,1,1,
    v_endpoint_hmac,v_endpoint_digest,'SMTP_EMAIL','ACTIVE','VERIFIED',
    communication_profile_session_id,verification_id,v_link_proof,
    'R6D_IDENTITY_FIXTURE',v_endpoint_digest,v_link_event_digest,
    'd61d0000-0000-4000-8000-000000000011',v_link_receipt_digest,v_base_at)
  ON CONFLICT DO NOTHING;
  PERFORM set_config('session_replication_role','origin',true);

  v_intent_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-intent','UTF8'),'sha256'),'hex');
  INSERT INTO ops.communication_intents(
    id,deployment_id,logical_intent_digest,source_event_id,source_event_type,
    source_object_type,source_object_id,material_event_version,
    communication_class,purpose,topic_scope,topic_scope_digest,
    recipient_subject_id,audience_policy_version,audience_policy_digest,
    policy_snapshot_digest,effect_safety_class,source_decision_receipt_id,
    source_decision_digest,state,version,intent_digest,creation_receipt_digest,
    created_at,state_changed_at)
  VALUES(intent_id,'control',v_intent_digest,
    'd61d0000-0000-4000-8000-000000000012','r6d.control.fixture',
    'RESPONSE_REQUEST',request_id,2,'SYSTEM_TRANSACTIONAL',
    'RIGHT_OF_REPLY_REQUEST',jsonb_build_object('responseRequestId',request_id),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-topic','UTF8'),'sha256'),'hex'),subject_id,
    'r6d-fixture-v1',encode(extensions.digest(convert_to(
      'r6d-response-identity-audience','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-policy','UTF8'),'sha256'),'hex'),
    'DUPLICATION_TOLERANT','d61d0000-0000-4000-8000-000000000013',
    encode(extensions.digest(convert_to(
      'r6d-response-identity-decision','UTF8'),'sha256'),'hex'),
    'CREATED',1,v_intent_digest,encode(extensions.digest(convert_to(
      'r6d-response-identity-intent-receipt','UTF8'),'sha256'),'hex'),
    v_base_at,v_base_at)
  ON CONFLICT DO NOTHING;

  v_rendering_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-rendering','UTF8'),'sha256'),'hex');
  v_rendered_sha:=encode(extensions.digest(convert_to(
    'r6d-response-identity-rendered-envelope','UTF8'),'sha256'),'hex');
  INSERT INTO ops.communication_renderings(
    id,intent_id,rendering_revision,endpoint_id,endpoint_version,
    endpoint_snapshot_digest,channel,locale,template_id,template_revision,
    variable_set,variable_set_digest,attachment_manifest,
    attachment_manifest_digest,disclosure_class,semantic_payload_digest,
    recipient_binding_digest,rendered_envelope_ciphertext,encryption_key_id,
    rendered_sha256,rendered_byte_length,transport_content_type,state,
    state_version,rendering_digest,transition_receipt_digest,expires_at,created_at)
  VALUES(rendering_id,intent_id,1,endpoint_id,1,v_endpoint_digest,'SMTP_EMAIL',
    'ko-KR','r6d-response-identity','v1',jsonb_build_object(
      'responseRequestId',request_id),encode(extensions.digest(convert_to(
      'r6d-response-identity-variables','UTF8'),'sha256'),'hex'),'[]'::jsonb,
    encode(extensions.digest(convert_to(
      'r6d-response-identity-attachments','UTF8'),'sha256'),'hex'),
    'INTERNAL_MINIMAL',encode(extensions.digest(convert_to(
      'r6d-response-identity-semantic','UTF8'),'sha256'),'hex'),
    v_request_binding,convert_to('sealed-r6d-response-request','UTF8'),
    'fixture-key',v_rendered_sha,27,'text/plain','DRAFT',1,
    v_rendering_digest,encode(extensions.digest(convert_to(
      'r6d-response-identity-render-transition','UTF8'),'sha256'),'hex'),
    v_base_at+interval '23 hours',v_base_at)
  ON CONFLICT DO NOTHING;

  v_delivery_key:=encode(extensions.digest(convert_to(
    'r6d-response-identity-delivery-key','UTF8'),'sha256'),'hex');
  v_delivery_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-delivery','UTF8'),'sha256'),'hex');
  INSERT INTO ops.outbound_deliveries(
    id,contract_version,dispatch_eligible,intent_id,intent_digest,rendering_id,
    endpoint_id,endpoint_version,endpoint_snapshot_digest,provider_config_id,
    provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_id,provider_preflight_receipt_digest,channel,
    delivery_key,rendered_sha256,rendering_digest,authorization_snapshot_digest,
    activation_receipt_digest,budget_reservation_id,
    provider_idempotency_key_sha256,delivery_digest,state,version,generation,
    event_sequence,receipt_sequence,attempt_count,max_attempts,
    current_evidence_rank,highest_proof_level,not_before,next_attempt_at,
    queued_at,updated_at,message_type,recipient_hash,template_version)
  VALUES(delivery_id,'COMMUNICATION_V1',false,intent_id,v_intent_digest,
    rendering_id,endpoint_id,1,v_endpoint_digest,provider_config_id,1,
    v_config_digest,provider_preflight_id,provider_receipt_digest,'SMTP_EMAIL',
    v_delivery_key,v_rendered_sha,v_rendering_digest,
    encode(extensions.digest(convert_to(
      'r6d-response-identity-authorization','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-activation','UTF8'),'sha256'),'hex'),
    budget_reservation_id,v_delivery_key,v_delivery_digest,'DELIVERED',2,1,2,1,
    1,3,50,'DELIVERED',v_base_at,v_base_at,v_base_at,v_base_at,
    'COMMUNICATION',v_subject_hmac,'v1')
  ON CONFLICT DO NOTHING;

  v_attempt_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-attempt','UTF8'),'sha256'),'hex');
  v_claim_receipt_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-attempt-claim','UTF8'),'sha256'),'hex');
  INSERT INTO ops.outbound_delivery_attempts(
    id,delivery_id,attempt_ordinal,dispatch_generation,
    delivery_version_at_claim,endpoint_id,endpoint_version,
    endpoint_snapshot_digest,provider_config_id,provider_config_version,
    configuration_digest,provider_preflight_receipt_id,
    provider_preflight_receipt_digest,budget_reservation_id,worker_id,
    lease_token_hash,fencing_token,provider_idempotency_key_sha256,
    request_sha256,rendered_sha256,authorization_snapshot_digest,
    suppression_snapshot_digest,activation_receipt_digest,policy_fence_digest,
    transport_policy_version,deadline_at,claimed_at,lease_expires_at,
    attempt_digest,claim_receipt_digest,audit_event_id)
  VALUES(attempt_id,delivery_id,1,1,1,endpoint_id,1,v_endpoint_digest,
    provider_config_id,1,v_config_digest,provider_preflight_id,
    provider_receipt_digest,budget_reservation_id,'r6d-response-identity-worker',
    encode(extensions.digest(convert_to(
      'r6d-response-identity-lease','UTF8'),'sha256'),'hex'),6101,v_delivery_key,
    encode(extensions.digest(convert_to(
      'r6d-response-identity-request','UTF8'),'sha256'),'hex'),v_rendered_sha,
    encode(extensions.digest(convert_to(
      'r6d-response-identity-authorization','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-suppression','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-activation','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-policy-fence','UTF8'),'sha256'),'hex'),
    'communication-v1',v_base_at+interval '2 hours',v_base_at,
    v_base_at+interval '1 hour',v_attempt_digest,v_claim_receipt_digest,
    'd61d0000-0000-4000-8000-000000000014')
  ON CONFLICT DO NOTHING;

  v_observation_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-observation','UTF8'),'sha256'),'hex');
  v_provider_evidence:=encode(extensions.digest(convert_to(
    'r6d-response-identity-provider-evidence','UTF8'),'sha256'),'hex');
  v_endpoint_identity:=encode(extensions.digest(convert_to(
    'r6d-response-identity-endpoint-identity','UTF8'),'sha256'),'hex');
  v_provider_identity:=encode(extensions.digest(convert_to(
    'r6d-response-identity-provider-identity','UTF8'),'sha256'),'hex');
  v_delivery_receipt_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-delivery-receipt','UTF8'),'sha256'),'hex');
  INSERT INTO ops.outbound_delivery_receipts(
    id,delivery_id,receipt_sequence,event_aggregate_version,
    prior_delivery_version,delivery_version,attempt_id,source_kind,
    observation_key_digest,projection_disposition,evidence_kind,evidence_rank,
    prior_state,asserted_state,resulting_state,prior_proof_level,
    resulting_proof_level,applied,provider_evidence_digest,rendering_digest,
    endpoint_id,endpoint_version,endpoint_snapshot_digest,
    endpoint_identity_hash,provider_preflight_receipt_id,provider_config_id,
    provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_digest,provider_identity_hash,
    authorization_snapshot_digest,activation_receipt_digest,
    budget_reservation_id,observed_at,actor_type,actor_id,request_id,trace_id,
    receipt_digest,audit_event_id,outbox_event_id)
  VALUES(delivery_receipt_id,delivery_id,1,2,1,2,attempt_id,
    'PROVIDER_RESPONSE',v_observation_digest,'APPLIED','PROVIDER_RESPONSE',50,
    'QUEUED','DELIVERED','DELIVERED','NONE','DELIVERED',true,
    v_provider_evidence,v_rendering_digest,endpoint_id,1,v_endpoint_digest,
    v_endpoint_identity,provider_preflight_id,provider_config_id,1,
    v_config_digest,provider_receipt_digest,v_provider_identity,
    encode(extensions.digest(convert_to(
      'r6d-response-identity-authorization','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-activation','UTF8'),'sha256'),'hex'),
    budget_reservation_id,v_base_at,'AUTHORIZED_SERVICE',NULL,
    'd61d0000-0000-4000-8000-000000000015','r6d-response-identity',
    v_delivery_receipt_digest,'d61d0000-0000-4000-8000-000000000016',
    'd61d0000-0000-4000-8000-000000000017')
  ON CONFLICT DO NOTHING;

  v_sent_receipt_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('responseRequestId',request_id,'requestVersion',2,
      'responseRequestBindingDigest',v_request_binding,
      'endpointId',endpoint_id,'endpointVersion',1,
      'endpointSnapshotDigest',v_endpoint_digest,
      'deliveryReceiptId',delivery_receipt_id,
      'deliveryReceiptDigest',v_delivery_receipt_digest)
  ),'sha256'),'hex');
  INSERT INTO editorial.response_request_sent_receipts(
    id,source_event_id,source_event_envelope_digest,response_request_id,
    prior_request_version,request_version,response_request_binding_digest,
    scope_digest,prior_state,state,communication_intent_id,
    communication_intent_digest,rendering_id,rendering_digest,rendered_sha256,
    response_access_token_id,access_artifact_binding_digest,endpoint_id,
    endpoint_version,endpoint_snapshot_digest,channel,provider_config_id,
    provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_id,provider_preflight_receipt_digest,delivery_id,
    delivery_object_type,delivery_version,delivery_receipt_id,
    delivery_receipt_sequence,delivery_receipt_digest,delivery_resulting_state,
    delivery_receipt_applied,acceptance_evidence_kind,
    provider_evidence_digest,provider_accepted_at,audit_event_id,
    outbox_event_id,receipt_digest,created_at)
  VALUES(sent_receipt_id,'d61d0000-0000-4000-8000-000000000018',
    encode(extensions.digest(convert_to(
      'r6d-response-identity-sent-source-event','UTF8'),'sha256'),'hex'),
    request_id,1,2,v_request_binding,encode(extensions.digest(convert_to(
      'r6d-response-identity-scope','UTF8'),'sha256'),'hex'),'DRAFT','SENT',
    intent_id,v_intent_digest,rendering_id,v_rendering_digest,v_rendered_sha,
    'd61d0000-0000-4000-8000-000000000019',encode(extensions.digest(convert_to(
      'r6d-response-identity-access-artifact','UTF8'),'sha256'),'hex'),
    endpoint_id,1,v_endpoint_digest,'SMTP_EMAIL',provider_config_id,1,
    v_config_digest,provider_preflight_id,provider_receipt_digest,delivery_id,
    'RESPONSE_REQUEST',2,delivery_receipt_id,1,v_delivery_receipt_digest,
    'DELIVERED',true,'PROVIDER_RESPONSE',v_provider_evidence,v_base_at,
    'd61d0000-0000-4000-8000-00000000001a',
    'd61d0000-0000-4000-8000-00000000001b',v_sent_receipt_digest,v_base_at)
  ON CONFLICT DO NOTHING;

  v_authority_source:=editorial.resolve_official_channel_source_v1(
    'OFFICIAL_DOMAIN_EMAIL',verification_id,'AGENCY',organization_id,
    independent_verifier_id,v_base_at+interval '23 hours',clock_timestamp());
  v_authority_source_snapshot:=v_authority_source->'sourceSnapshotPayload';
  v_authority_source_snapshot_canonical:=ops.canonical_jsonb_v1(
    v_authority_source_snapshot);
  v_authority_source_snapshot_digest:=encode(extensions.digest(
    v_authority_source_snapshot_canonical,'sha256'),'hex');
  IF v_authority_source->>'sourceSnapshotDigest'<>
       v_authority_source_snapshot_digest
     OR v_authority_source->>'underlyingSourceProofDigest'<>
       v_verification_receipt THEN
    RAISE EXCEPTION 'r6d response identity authority source fixture invalid';
  END IF;
  SELECT * INTO STRICT v_authority_step_up
  FROM ops.step_up_authorizations WHERE id=authority_step_up_id;
  v_authority_step_up_payload:=jsonb_build_object(
    'schemaVersion','step-up-authorization-receipt.v1',
    'authorizationId',v_authority_step_up.id,
    'actionDigest',btrim(v_authority_step_up.action_digest),
    'sessionId',v_authority_step_up.session_id,
    'issueNumber',v_authority_step_up.assertion_issue_count,
    'issuedAt',v_authority_step_up.last_issued_at,
    'expiresAt',v_authority_step_up.expires_at);
  v_authority_step_up_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_authority_step_up_payload),'sha256'),'hex');
  v_authority_reason_digest:=encode(extensions.digest(convert_to(
    'TEST_ONLY R6d control EMAIL authority','UTF8'),'sha256'),'hex');
  v_authority_payload:=jsonb_build_object(
    'schemaVersion','organization-authority-receipt.v1',
    'authorityReceiptId',authority_receipt_id,'authorityVersion',1,
    'assertionId',official_assertion_id,
    'organizationKind','AGENCY','organizationId',organization_id,
    'verificationMethod','OFFICIAL_DOMAIN_EMAIL','sourceId',verification_id,
    'sourcePurpose',v_authority_source->>'sourcePurpose',
    'authorityReceiptKind',v_authority_source->>'authorityReceiptKind',
    'underlyingSourceProofDigest',
      v_authority_source->>'underlyingSourceProofDigest',
    'sourceSnapshotDigest',v_authority_source_snapshot_digest,
    'attestedByUserId',independent_verifier_id,
    'actorAssertionJti',authority_actor_assertion_jti,
    'actorActionDigest',v_authority_action_digest,
    'stepUpAuthorizationId',authority_step_up_id,
    'stepUpReceiptDigest',v_authority_step_up_receipt_digest,
    'sessionId',authority_session_id,'reasonDigest',v_authority_reason_digest,
    'requestId',authority_request_id,
    'idempotencyKeySha256',v_authority_idempotency_digest,
    'requestDigest',v_authority_request_digest,
    'attestedAt',v_base_at,'expiresAt',v_base_at+interval '23 hours');
  v_authority_canonical:=ops.canonical_jsonb_v1(v_authority_payload);
  v_authority_receipt_digest:=encode(extensions.digest(
    v_authority_canonical,'sha256'),'hex');
  v_source_binding:=jsonb_strip_nulls(jsonb_build_object(
    'schemaVersion','organization-official-channel-source-binding.v1',
    'organizationKind','AGENCY','organizationId',organization_id,
    'verificationMethod','OFFICIAL_DOMAIN_EMAIL',
    'sourcePurpose',v_authority_source->>'sourcePurpose',
    'communicationSubjectId',
      (v_authority_source->>'communicationSubjectId')::uuid,
    'communicationSubjectOriginDigest',
      v_authority_source->>'communicationSubjectOriginDigest',
    'communicationSubjectProfileVersion',
      (v_authority_source->>'communicationSubjectProfileVersion')::bigint,
    'communicationSubjectProfileDigest',
      v_authority_source->>'communicationSubjectProfileDigest',
    'communicationEndpointId',
      (v_authority_source->>'communicationEndpointId')::uuid,
    'communicationEndpointVersion',
      (v_authority_source->>'communicationEndpointVersion')::bigint,
    'communicationEndpointDigest',
      v_authority_source->>'communicationEndpointDigest',
    'communicationVerificationId',
      (v_authority_source->>'communicationVerificationId')::uuid,
    'underlyingSourceProofDigest',
      v_authority_source->>'underlyingSourceProofDigest',
    'organizationAuthorityReceiptKind',
      v_authority_source->>'authorityReceiptKind',
    'organizationAuthorityReceiptDigest',v_authority_receipt_digest));
  v_source_binding_canonical:=ops.canonical_jsonb_v1(v_source_binding);
  v_source_binding_digest:=encode(extensions.digest(
    v_source_binding_canonical,'sha256'),'hex');
  v_assertion:=jsonb_build_object(
    'schemaVersion','organization-official-channel-assertion.v1',
    'assertionId',official_assertion_id,'assertionVersion',1,
    'organizationKind','AGENCY','organizationId',organization_id,
    'verificationMethod','OFFICIAL_DOMAIN_EMAIL',
    'sourcePurpose','OFFICIAL_DOMAIN_CONTROL',
    'organizationSourceBindingDigest',v_source_binding_digest,
    'independentVerifierUserId',independent_verifier_id,
    'verifiedAt',v_base_at,'expiresAt',v_base_at+interval '23 hours');
  v_assertion_canonical:=ops.canonical_jsonb_v1(v_assertion);
  v_assertion_digest:=encode(extensions.digest(
    v_assertion_canonical,'sha256'),'hex');
  v_registry_receipt:=jsonb_build_object(
    'schemaVersion','organization-official-channel-receipt.v1',
    'assertionId',official_assertion_id,'assertionDigest',v_assertion_digest,
    'organizationSourceBindingDigest',v_source_binding_digest,
    'underlyingSourceProofDigest',v_verification_receipt,
    'organizationAuthorityReceiptKind','ORGANIZATION_DOMAIN_CONTROL',
    'organizationAuthorityReceiptDigest',v_authority_receipt_digest,
    'verifiedAt',v_base_at,'expiresAt',v_base_at+interval '23 hours');
  v_registry_receipt_canonical:=ops.canonical_jsonb_v1(v_registry_receipt);
  v_registry_receipt_digest:=encode(extensions.digest(
    v_registry_receipt_canonical,'sha256'),'hex');
  v_authority_audit_id:=ops.append_audit_event(
    'organization-channel:'||official_assertion_id::text,
    'USER',independent_verifier_id::text,authority_session_id,
    'organization.official_channel.attest','OrganizationOfficialChannel',
    official_assertion_id::text,'responses.review','SUCCESS',NULL,
    authority_request_id,jsonb_build_object(
      'organizationKind','AGENCY','organizationId',organization_id,
      'verificationMethod','OFFICIAL_DOMAIN_EMAIL',
      'sourceSnapshotDigest',v_authority_source_snapshot_digest,
      'authorityReceiptDigest',v_authority_receipt_digest,
      'registryReceiptDigest',v_registry_receipt_digest,
      'reasonDigest',v_authority_reason_digest));
  SELECT event_hash INTO STRICT v_authority_audit_digest
  FROM ops.audit_events WHERE id=v_authority_audit_id;
  v_authority_outbox_id:=ops.enqueue_outbox(
    'organization_official_channel',official_assertion_id::text,1,
    'organization.official_channel_attested.v1',jsonb_build_object(
      'assertionId',official_assertion_id,'organizationKind','AGENCY',
      'organizationId',organization_id,
      'verificationMethod','OFFICIAL_DOMAIN_EMAIL',
      'authorityReceiptDigest',v_authority_receipt_digest,
      'registryReceiptDigest',v_registry_receipt_digest,
      'attestedAt',v_base_at,'expiresAt',v_base_at+interval '23 hours'),
    v_base_at);
  INSERT INTO editorial.organization_official_channel_authority_receipts_v1(
    authority_receipt_id,authority_version,assertion_id,organization_kind,
    organization_id,agency_id,verification_method,source_id,
    communication_verification_id,source_purpose,authority_receipt_kind,
    underlying_source_proof_digest,source_snapshot_payload,
    source_snapshot_canonical,source_snapshot_digest,attested_by_user_id,
    actor_assertion_jti,actor_action_digest,step_up_authorization_id,
    step_up_receipt_digest,session_id,reason_digest,request_id,
    idempotency_key_sha256,request_digest,attested_at,expires_at,
    authority_payload,authority_canonical,authority_receipt_digest,
    audit_event_id,audit_receipt_digest,outbox_event_id)
  VALUES(authority_receipt_id,1,official_assertion_id,'AGENCY',organization_id,
    organization_id,'OFFICIAL_DOMAIN_EMAIL',verification_id,verification_id,
    v_authority_source->>'sourcePurpose',
    v_authority_source->>'authorityReceiptKind',
    v_authority_source->>'underlyingSourceProofDigest',
    v_authority_source_snapshot,v_authority_source_snapshot_canonical,
    v_authority_source_snapshot_digest,independent_verifier_id,
    authority_actor_assertion_jti,v_authority_action_digest,
    authority_step_up_id,v_authority_step_up_receipt_digest,
    authority_session_id,v_authority_reason_digest,authority_request_id,
    v_authority_idempotency_digest,v_authority_request_digest,v_base_at,
    v_base_at+interval '23 hours',v_authority_payload,v_authority_canonical,
    v_authority_receipt_digest,v_authority_audit_id,v_authority_audit_digest,
    v_authority_outbox_id)
  ON CONFLICT DO NOTHING;
  INSERT INTO editorial.organization_official_channel_assertions_v1(
    assertion_id,assertion_version,organization_kind,organization_id,agency_id,
    verification_method,source_purpose,communication_subject_id,
    communication_subject_origin_digest,communication_subject_profile_version,
    communication_subject_profile_digest,communication_endpoint_id,
    communication_endpoint_version,communication_endpoint_digest,
    communication_verification_id,underlying_source_proof_digest,
    organization_authority_receipt_kind,organization_authority_receipt_digest,
    authority_receipt_id,authority_source_id,
    organization_source_binding_payload,organization_source_binding_canonical,
    organization_source_binding_digest,independent_verifier_user_id,verified_at,
    expires_at,assertion_payload,assertion_canonical,assertion_digest,
    receipt_payload,receipt_canonical,receipt_digest,created_at)
  VALUES(official_assertion_id,1,'AGENCY',organization_id,organization_id,
    'OFFICIAL_DOMAIN_EMAIL','OFFICIAL_DOMAIN_CONTROL',subject_id,
    v_request_binding,1,v_subject_profile,endpoint_id,1,v_endpoint_digest,
    verification_id,v_verification_receipt,'ORGANIZATION_DOMAIN_CONTROL',
    v_authority_receipt_digest,authority_receipt_id,verification_id,
    v_source_binding,v_source_binding_canonical,
    v_source_binding_digest,independent_verifier_id,v_base_at,
    v_base_at+interval '23 hours',v_assertion,v_assertion_canonical,
    v_assertion_digest,v_registry_receipt,v_registry_receipt_canonical,
    v_registry_receipt_digest,v_base_at)
  ON CONFLICT DO NOTHING;

  v_registry_result:=editorial.require_current_official_channel_v1(
    official_assertion_id,'AGENCY',organization_id,request_id,case_id,
    identity_actor_id,clock_timestamp());
  IF v_registry_result->>'verificationMethod'<>'OFFICIAL_DOMAIN_EMAIL'
     OR (v_registry_result->>'communicationVerificationId')::uuid<>verification_id
     OR v_registry_result->>'registryReceiptDigest'<>v_registry_receipt_digest THEN
    RAISE EXCEPTION 'r6d response identity official-channel fixture invalid';
  END IF;

  -- A second, otherwise valid authority is immutably revoked.  HTTP negative
  -- tests use this assertion ID (not the raw verification ID) to prove that
  -- currentness is re-evaluated for the same request/organization scope.
  -- A different response dispatch owns the revoked verification.  Keeping the
  -- two EMAIL sources disjoint means each resolver sees one current endpoint
  -- revision and one exact latest verification-bound link event.
  v_revoked_endpoint_hmac:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-endpoint-hmac','UTF8'),'sha256'),'hex');
  v_revoked_endpoint_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('subjectId',revoked_subject_id,'channel','SMTP_EMAIL',
      'endpointHmac',v_revoked_endpoint_hmac,'version',1)
  ),'sha256'),'hex');
  v_revoked_request_binding:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('responseRequestId',revoked_request_id,'caseId',case_id,
      'partyType','AGENCY','partyEntityId',organization_id,'requestVersion',2,
      'endpointId',revoked_endpoint_id,'endpointVersion',1,
      'endpointSnapshotDigest',v_revoked_endpoint_digest)
  ),'sha256'),'hex');
  INSERT INTO editorial.response_requests(
    id,case_id,party_type,party_entity_id,party_name,recipient_email_hash,
    recipient_email_encrypted,questions,requested_publication_scope,due_at,
    effective_due_at,sent_at,status,version,created_by)
  VALUES(revoked_request_id,case_id,'AGENCY',organization_id,
    'Control revoked identity agency',encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-recipient','UTF8'),'sha256'),'hex'),
    convert_to('sealed-r6d-revoked-agency-recipient','UTF8'),
    jsonb_build_array('철회된 공식 채널 확인'),jsonb_build_object('body',true),
    clock_timestamp()+interval '7 days',clock_timestamp()+interval '7 days',
    clock_timestamp(),'SENT',2,identity_actor_id)
  ON CONFLICT DO NOTHING;
  SELECT created_at INTO STRICT v_revoked_base_at
  FROM editorial.response_requests WHERE id=revoked_request_id;

  v_revoked_subject_hmac:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-subject-hmac','UTF8'),'sha256'),'hex');
  v_revoked_subject_profile:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('subjectId',revoked_subject_id,
      'originType','RESPONSE_REQUEST','originId',revoked_request_id,
      'originVersion',2,'partyType','AGENCY','partyEntityId',organization_id)
  ),'sha256'),'hex');
  INSERT INTO intake.communication_subjects(
    id,subject_kind,origin_object_type,origin_object_id,origin_object_version,
    origin_binding_digest,subject_pseudonym_hmac,hmac_key_version,jurisdiction,
    locale,status,profile_version,profile_digest,created_at,updated_at)
  VALUES(revoked_subject_id,'RESPONSE_PARTY','RESPONSE_REQUEST',
    revoked_request_id,2,v_revoked_request_binding,v_revoked_subject_hmac,
    'r6d-fixture-v1','KR','ko-KR','ACTIVE',1,v_revoked_subject_profile,
    v_revoked_base_at,v_revoked_base_at)
  ON CONFLICT DO NOTHING;
  INSERT INTO intake.communication_endpoints(
    id,subject_id,channel,endpoint_hmac,hmac_key_version,endpoint_ciphertext,
    encryption_key_id,state,version,endpoint_digest,verified_at,created_at,updated_at)
  VALUES(revoked_endpoint_id,revoked_subject_id,'SMTP_EMAIL',
    v_revoked_endpoint_hmac,'r6d-fixture-v1',
    convert_to('sealed-r6d-revoked-agency-endpoint','UTF8'),'fixture-key',
    'ACTIVE',1,v_revoked_endpoint_digest,v_revoked_base_at,v_revoked_base_at,
    v_revoked_base_at)
  ON CONFLICT DO NOTHING;
  INSERT INTO intake.submission_sessions(
    id,token_hash,session_kind,scope_type,scope_id,bff_issuer,status,version,
    issued_at,expires_at)
  VALUES(revoked_profile_session_id,encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-profile-session','UTF8'),'sha256'),'hex'),
    'COMMUNICATION_PROFILE','COMMUNICATION_SUBJECT',revoked_subject_id,
    'response-portal','ACTIVE',1,v_revoked_base_at,
    v_revoked_base_at+interval '23 hours')
  ON CONFLICT DO NOTHING;

  PERFORM set_config('session_replication_role','replica',true);
  v_revoked_verification_binding:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'subjectId',revoked_subject_id,'endpointId',revoked_endpoint_id,
      'endpointVersion',1,'challengeKind','EMAIL_LINK',
      'verificationId',revoked_verification_id
    )),'sha256'),'hex');
  v_revoked_verification_proof:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'verificationId',revoked_verification_id,
      'verificationBindingDigest',v_revoked_verification_binding,
      'verifiedAt',v_revoked_base_at,'consumedAt',v_revoked_base_at
    )),'sha256'),'hex');
  v_revoked_verification_receipt:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'verificationId',revoked_verification_id,
      'proofDigest',v_revoked_verification_proof,'state','VERIFIED',
      'endpointSnapshotDigest',v_revoked_endpoint_digest
    )),'sha256'),'hex');
  INSERT INTO intake.communication_endpoint_verifications(
    id,subject_id,subject_origin_binding_digest,endpoint_id,endpoint_version,
    endpoint_snapshot_digest,profile_session_id,challenge_kind,challenge_hash,
    nonce_hash,verification_binding_digest,state,attempt_count,max_attempts,
    version,proof_digest,receipt_digest,issued_at,expires_at,verified_at,consumed_at)
  VALUES(revoked_verification_id,revoked_subject_id,v_revoked_request_binding,
    revoked_endpoint_id,1,v_revoked_endpoint_digest,revoked_profile_session_id,
    'EMAIL_LINK',
    encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-email-link','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-email-link-nonce','UTF8'),'sha256'),'hex'),
    v_revoked_verification_binding,'VERIFIED',1,3,1,
    v_revoked_verification_proof,v_revoked_verification_receipt,
    v_revoked_base_at-interval '5 minutes',
    v_revoked_base_at+interval '23 hours',v_revoked_base_at,v_revoked_base_at)
  ON CONFLICT DO NOTHING;

  v_revoked_link_proof:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-link-proof','UTF8'),'sha256'),'hex');
  v_revoked_link_event_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'subjectId',revoked_subject_id,'endpointId',revoked_endpoint_id,
      'endpointSequence',1,'endpointVersion',1,'state','ACTIVE',
      'changeKind','VERIFIED','verificationId',revoked_verification_id,
      'proofDigest',v_revoked_link_proof)),'sha256'),'hex');
  v_revoked_link_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object('eventId',revoked_link_event_id,
      'eventDigest',v_revoked_link_event_digest,
      'occurredAt',v_revoked_base_at)),'sha256'),'hex');
  INSERT INTO intake.communication_endpoint_link_events(
    id,subject_id,subject_origin_binding_digest,endpoint_id,endpoint_sequence,
    profile_version,endpoint_version,endpoint_hmac,endpoint_digest,channel,
    state,change_kind,profile_session_id,verification_id,proof_digest,reason_code,
    endpoint_snapshot_digest,event_digest,audit_event_id,receipt_digest,occurred_at)
  VALUES(revoked_link_event_id,revoked_subject_id,v_revoked_request_binding,
    revoked_endpoint_id,1,1,1,v_revoked_endpoint_hmac,
    v_revoked_endpoint_digest,'SMTP_EMAIL','ACTIVE','VERIFIED',
    revoked_profile_session_id,revoked_verification_id,v_revoked_link_proof,
    'R6D_REVOKED_IDENTITY_FIXTURE',v_revoked_endpoint_digest,
    v_revoked_link_event_digest,'d61d0000-0000-4000-8000-000000000045',
    v_revoked_link_receipt_digest,v_revoked_base_at)
  ON CONFLICT DO NOTHING;
  PERFORM set_config('session_replication_role','origin',true);

  v_revoked_intent_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-intent','UTF8'),'sha256'),'hex');
  INSERT INTO ops.communication_intents(
    id,deployment_id,logical_intent_digest,source_event_id,source_event_type,
    source_object_type,source_object_id,material_event_version,
    communication_class,purpose,topic_scope,topic_scope_digest,
    recipient_subject_id,audience_policy_version,audience_policy_digest,
    policy_snapshot_digest,effect_safety_class,source_decision_receipt_id,
    source_decision_digest,state,version,intent_digest,creation_receipt_digest,
    created_at,state_changed_at)
  VALUES(revoked_intent_id,'control',v_revoked_intent_digest,
    'd61d0000-0000-4000-8000-00000000003b','r6d.control.fixture',
    'RESPONSE_REQUEST',revoked_request_id,2,'SYSTEM_TRANSACTIONAL',
    'RIGHT_OF_REPLY_REQUEST',jsonb_build_object(
      'responseRequestId',revoked_request_id),encode(extensions.digest(
        convert_to('r6d-response-identity-revoked-topic','UTF8'),
        'sha256'),'hex'),revoked_subject_id,'r6d-fixture-v1',
    encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-audience','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-policy','UTF8'),'sha256'),'hex'),
    'DUPLICATION_TOLERANT','d61d0000-0000-4000-8000-00000000003c',
    encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-decision','UTF8'),'sha256'),'hex'),
    'CREATED',1,v_revoked_intent_digest,encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-intent-receipt','UTF8'),
      'sha256'),'hex'),v_revoked_base_at,v_revoked_base_at)
  ON CONFLICT DO NOTHING;

  v_revoked_rendering_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-rendering','UTF8'),'sha256'),'hex');
  v_revoked_rendered_sha:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-rendered-envelope','UTF8'),
    'sha256'),'hex');
  INSERT INTO ops.communication_renderings(
    id,intent_id,rendering_revision,endpoint_id,endpoint_version,
    endpoint_snapshot_digest,channel,locale,template_id,template_revision,
    variable_set,variable_set_digest,attachment_manifest,
    attachment_manifest_digest,disclosure_class,semantic_payload_digest,
    recipient_binding_digest,rendered_envelope_ciphertext,encryption_key_id,
    rendered_sha256,rendered_byte_length,transport_content_type,state,
    state_version,rendering_digest,transition_receipt_digest,expires_at,created_at)
  VALUES(revoked_rendering_id,revoked_intent_id,1,revoked_endpoint_id,1,
    v_revoked_endpoint_digest,'SMTP_EMAIL','ko-KR',
    'r6d-response-identity-revoked','v1',jsonb_build_object(
      'responseRequestId',revoked_request_id),encode(extensions.digest(
        convert_to('r6d-response-identity-revoked-variables','UTF8'),
        'sha256'),'hex'),'[]'::jsonb,encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-attachments','UTF8'),'sha256'),'hex'),
    'INTERNAL_MINIMAL',encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-semantic','UTF8'),'sha256'),'hex'),
    v_revoked_request_binding,convert_to(
      'sealed-r6d-revoked-response-request','UTF8'),'fixture-key',
    v_revoked_rendered_sha,35,'text/plain','DRAFT',1,
    v_revoked_rendering_digest,encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-render-transition','UTF8'),
      'sha256'),'hex'),v_revoked_base_at+interval '23 hours',v_revoked_base_at)
  ON CONFLICT DO NOTHING;

  v_revoked_delivery_key:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-delivery-key','UTF8'),'sha256'),'hex');
  v_revoked_delivery_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-delivery','UTF8'),'sha256'),'hex');
  INSERT INTO ops.outbound_deliveries(
    id,contract_version,dispatch_eligible,intent_id,intent_digest,rendering_id,
    endpoint_id,endpoint_version,endpoint_snapshot_digest,provider_config_id,
    provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_id,provider_preflight_receipt_digest,channel,
    delivery_key,rendered_sha256,rendering_digest,authorization_snapshot_digest,
    activation_receipt_digest,budget_reservation_id,
    provider_idempotency_key_sha256,delivery_digest,state,version,generation,
    event_sequence,receipt_sequence,attempt_count,max_attempts,
    current_evidence_rank,highest_proof_level,not_before,next_attempt_at,
    queued_at,updated_at,message_type,recipient_hash,template_version)
  VALUES(revoked_delivery_id,'COMMUNICATION_V1',false,revoked_intent_id,
    v_revoked_intent_digest,revoked_rendering_id,revoked_endpoint_id,1,
    v_revoked_endpoint_digest,provider_config_id,1,v_config_digest,
    provider_preflight_id,provider_receipt_digest,'SMTP_EMAIL',
    v_revoked_delivery_key,v_revoked_rendered_sha,v_revoked_rendering_digest,
    encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-authorization','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-activation','UTF8'),'sha256'),'hex'),
    budget_reservation_id,v_revoked_delivery_key,v_revoked_delivery_digest,
    'DELIVERED',2,1,2,1,1,3,50,'DELIVERED',v_revoked_base_at,
    v_revoked_base_at,v_revoked_base_at,v_revoked_base_at,'COMMUNICATION',
    v_revoked_subject_hmac,'v1')
  ON CONFLICT DO NOTHING;

  v_revoked_attempt_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-attempt','UTF8'),'sha256'),'hex');
  v_revoked_claim_receipt_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-attempt-claim','UTF8'),'sha256'),'hex');
  INSERT INTO ops.outbound_delivery_attempts(
    id,delivery_id,attempt_ordinal,dispatch_generation,
    delivery_version_at_claim,endpoint_id,endpoint_version,
    endpoint_snapshot_digest,provider_config_id,provider_config_version,
    configuration_digest,provider_preflight_receipt_id,
    provider_preflight_receipt_digest,budget_reservation_id,worker_id,
    lease_token_hash,fencing_token,provider_idempotency_key_sha256,
    request_sha256,rendered_sha256,authorization_snapshot_digest,
    suppression_snapshot_digest,activation_receipt_digest,policy_fence_digest,
    transport_policy_version,deadline_at,claimed_at,lease_expires_at,
    attempt_digest,claim_receipt_digest,audit_event_id)
  VALUES(revoked_attempt_id,revoked_delivery_id,1,1,1,revoked_endpoint_id,1,
    v_revoked_endpoint_digest,provider_config_id,1,v_config_digest,
    provider_preflight_id,provider_receipt_digest,budget_reservation_id,
    'r6d-response-identity-revoked-worker',encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-lease','UTF8'),'sha256'),'hex'),6102,
    v_revoked_delivery_key,encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-request','UTF8'),'sha256'),'hex'),
    v_revoked_rendered_sha,encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-authorization','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-suppression','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-activation','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-policy-fence','UTF8'),'sha256'),'hex'),
    'communication-v1',v_revoked_base_at+interval '2 hours',v_revoked_base_at,
    v_revoked_base_at+interval '1 hour',v_revoked_attempt_digest,
    v_revoked_claim_receipt_digest,
    'd61d0000-0000-4000-8000-00000000003d')
  ON CONFLICT DO NOTHING;

  v_revoked_observation_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-observation','UTF8'),'sha256'),'hex');
  v_revoked_provider_evidence:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-provider-evidence','UTF8'),
    'sha256'),'hex');
  v_revoked_endpoint_identity:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-endpoint-identity','UTF8'),
    'sha256'),'hex');
  v_revoked_provider_identity:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-provider-identity','UTF8'),
    'sha256'),'hex');
  v_revoked_delivery_receipt_digest:=encode(extensions.digest(convert_to(
    'r6d-response-identity-revoked-delivery-receipt','UTF8'),
    'sha256'),'hex');
  INSERT INTO ops.outbound_delivery_receipts(
    id,delivery_id,receipt_sequence,event_aggregate_version,
    prior_delivery_version,delivery_version,attempt_id,source_kind,
    observation_key_digest,projection_disposition,evidence_kind,evidence_rank,
    prior_state,asserted_state,resulting_state,prior_proof_level,
    resulting_proof_level,applied,provider_evidence_digest,rendering_digest,
    endpoint_id,endpoint_version,endpoint_snapshot_digest,
    endpoint_identity_hash,provider_preflight_receipt_id,provider_config_id,
    provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_digest,provider_identity_hash,
    authorization_snapshot_digest,activation_receipt_digest,
    budget_reservation_id,observed_at,actor_type,actor_id,request_id,trace_id,
    receipt_digest,audit_event_id,outbox_event_id)
  VALUES(revoked_delivery_receipt_id,revoked_delivery_id,1,2,1,2,
    revoked_attempt_id,'PROVIDER_RESPONSE',v_revoked_observation_digest,
    'APPLIED','PROVIDER_RESPONSE',50,'QUEUED','DELIVERED','DELIVERED','NONE',
    'DELIVERED',true,v_revoked_provider_evidence,v_revoked_rendering_digest,
    revoked_endpoint_id,1,v_revoked_endpoint_digest,v_revoked_endpoint_identity,
    provider_preflight_id,provider_config_id,1,v_config_digest,
    provider_receipt_digest,v_revoked_provider_identity,encode(extensions.digest(
      convert_to('r6d-response-identity-revoked-authorization','UTF8'),
      'sha256'),'hex'),encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-activation','UTF8'),'sha256'),'hex'),
    budget_reservation_id,v_revoked_base_at,'AUTHORIZED_SERVICE',NULL,
    'd61d0000-0000-4000-8000-00000000003e',
    'r6d-response-identity-revoked',v_revoked_delivery_receipt_digest,
    'd61d0000-0000-4000-8000-00000000003f',
    'd61d0000-0000-4000-8000-000000000040')
  ON CONFLICT DO NOTHING;

  v_revoked_sent_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'responseRequestId',revoked_request_id,'requestVersion',2,
      'responseRequestBindingDigest',v_revoked_request_binding,
      'endpointId',revoked_endpoint_id,'endpointVersion',1,
      'endpointSnapshotDigest',v_revoked_endpoint_digest,
      'deliveryReceiptId',revoked_delivery_receipt_id,
      'deliveryReceiptDigest',v_revoked_delivery_receipt_digest)),
    'sha256'),'hex');
  INSERT INTO editorial.response_request_sent_receipts(
    id,source_event_id,source_event_envelope_digest,response_request_id,
    prior_request_version,request_version,response_request_binding_digest,
    scope_digest,prior_state,state,communication_intent_id,
    communication_intent_digest,rendering_id,rendering_digest,rendered_sha256,
    response_access_token_id,access_artifact_binding_digest,endpoint_id,
    endpoint_version,endpoint_snapshot_digest,channel,provider_config_id,
    provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_id,provider_preflight_receipt_digest,delivery_id,
    delivery_object_type,delivery_version,delivery_receipt_id,
    delivery_receipt_sequence,delivery_receipt_digest,delivery_resulting_state,
    delivery_receipt_applied,acceptance_evidence_kind,
    provider_evidence_digest,provider_accepted_at,audit_event_id,
    outbox_event_id,receipt_digest,created_at)
  VALUES(revoked_sent_receipt_id,
    'd61d0000-0000-4000-8000-000000000041',encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-sent-source-event','UTF8'),
      'sha256'),'hex'),revoked_request_id,1,2,v_revoked_request_binding,
    encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-scope','UTF8'),'sha256'),'hex'),
    'DRAFT','SENT',revoked_intent_id,v_revoked_intent_digest,
    revoked_rendering_id,v_revoked_rendering_digest,v_revoked_rendered_sha,
    'd61d0000-0000-4000-8000-000000000042',encode(extensions.digest(convert_to(
      'r6d-response-identity-revoked-access-artifact','UTF8'),
      'sha256'),'hex'),revoked_endpoint_id,1,v_revoked_endpoint_digest,
    'SMTP_EMAIL',provider_config_id,1,v_config_digest,provider_preflight_id,
    provider_receipt_digest,revoked_delivery_id,'RESPONSE_REQUEST',2,
    revoked_delivery_receipt_id,1,v_revoked_delivery_receipt_digest,'DELIVERED',
    true,'PROVIDER_RESPONSE',v_revoked_provider_evidence,v_revoked_base_at,
    'd61d0000-0000-4000-8000-000000000043',
    'd61d0000-0000-4000-8000-000000000044',
    v_revoked_sent_receipt_digest,v_revoked_base_at)
  ON CONFLICT DO NOTHING;

  v_revoked_authority_source:=editorial.resolve_official_channel_source_v1(
    'OFFICIAL_DOMAIN_EMAIL',revoked_verification_id,'AGENCY',organization_id,
    independent_verifier_id,v_revoked_base_at+interval '23 hours',
    clock_timestamp());
  v_revoked_authority_source_snapshot:=
    v_revoked_authority_source->'sourceSnapshotPayload';
  v_revoked_authority_source_snapshot_canonical:=ops.canonical_jsonb_v1(
    v_revoked_authority_source_snapshot);
  v_revoked_authority_source_snapshot_digest:=encode(extensions.digest(
    v_revoked_authority_source_snapshot_canonical,'sha256'),'hex');
  IF v_revoked_authority_source->>'sourceSnapshotDigest'<>
       v_revoked_authority_source_snapshot_digest
     OR v_revoked_authority_source->>'underlyingSourceProofDigest'<>
       v_revoked_verification_receipt THEN
    RAISE EXCEPTION 'r6d revoked response identity authority source invalid';
  END IF;
  SELECT * INTO STRICT v_revoked_authority_step_up
  FROM ops.step_up_authorizations WHERE id=revoked_authority_step_up_id;
  v_revoked_authority_step_up_payload:=jsonb_build_object(
    'schemaVersion','step-up-authorization-receipt.v1',
    'authorizationId',v_revoked_authority_step_up.id,
    'actionDigest',btrim(v_revoked_authority_step_up.action_digest),
    'sessionId',v_revoked_authority_step_up.session_id,
    'issueNumber',v_revoked_authority_step_up.assertion_issue_count,
    'issuedAt',v_revoked_authority_step_up.last_issued_at,
    'expiresAt',v_revoked_authority_step_up.expires_at);
  v_revoked_authority_step_up_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_revoked_authority_step_up_payload),
    'sha256'),'hex');
  v_revoked_authority_reason_digest:=encode(extensions.digest(convert_to(
    'TEST_ONLY R6d revoked control EMAIL authority','UTF8'),'sha256'),'hex');
  v_revoked_authority_payload:=jsonb_build_object(
    'schemaVersion','organization-authority-receipt.v1',
    'authorityReceiptId',revoked_authority_receipt_id,'authorityVersion',1,
    'assertionId',revoked_assertion_id,
    'organizationKind','AGENCY','organizationId',organization_id,
    'verificationMethod','OFFICIAL_DOMAIN_EMAIL',
    'sourceId',revoked_verification_id,
    'sourcePurpose',v_revoked_authority_source->>'sourcePurpose',
    'authorityReceiptKind',v_revoked_authority_source->>'authorityReceiptKind',
    'underlyingSourceProofDigest',
      v_revoked_authority_source->>'underlyingSourceProofDigest',
    'sourceSnapshotDigest',v_revoked_authority_source_snapshot_digest,
    'attestedByUserId',independent_verifier_id,
    'actorAssertionJti',revoked_authority_actor_assertion_jti,
    'actorActionDigest',v_revoked_authority_action_digest,
    'stepUpAuthorizationId',revoked_authority_step_up_id,
    'stepUpReceiptDigest',v_revoked_authority_step_up_receipt_digest,
    'sessionId',authority_session_id,
    'reasonDigest',v_revoked_authority_reason_digest,
    'requestId',revoked_authority_request_id,
    'idempotencyKeySha256',v_revoked_authority_idempotency_digest,
    'requestDigest',v_revoked_authority_request_digest,
    'attestedAt',v_revoked_base_at,
    'expiresAt',v_revoked_base_at+interval '23 hours');
  v_revoked_authority_canonical:=ops.canonical_jsonb_v1(
    v_revoked_authority_payload);
  v_revoked_authority_receipt_digest:=encode(extensions.digest(
    v_revoked_authority_canonical,'sha256'),'hex');
  v_revoked_source_binding:=jsonb_strip_nulls(jsonb_build_object(
    'schemaVersion','organization-official-channel-source-binding.v1',
    'organizationKind','AGENCY','organizationId',organization_id,
    'verificationMethod','OFFICIAL_DOMAIN_EMAIL',
    'sourcePurpose',v_revoked_authority_source->>'sourcePurpose',
    'communicationSubjectId',
      (v_revoked_authority_source->>'communicationSubjectId')::uuid,
    'communicationSubjectOriginDigest',
      v_revoked_authority_source->>'communicationSubjectOriginDigest',
    'communicationSubjectProfileVersion',
      (v_revoked_authority_source->>'communicationSubjectProfileVersion')::bigint,
    'communicationSubjectProfileDigest',
      v_revoked_authority_source->>'communicationSubjectProfileDigest',
    'communicationEndpointId',
      (v_revoked_authority_source->>'communicationEndpointId')::uuid,
    'communicationEndpointVersion',
      (v_revoked_authority_source->>'communicationEndpointVersion')::bigint,
    'communicationEndpointDigest',
      v_revoked_authority_source->>'communicationEndpointDigest',
    'communicationVerificationId',
      (v_revoked_authority_source->>'communicationVerificationId')::uuid,
    'underlyingSourceProofDigest',
      v_revoked_authority_source->>'underlyingSourceProofDigest',
    'organizationAuthorityReceiptKind',
      v_revoked_authority_source->>'authorityReceiptKind',
    'organizationAuthorityReceiptDigest',v_revoked_authority_receipt_digest));
  v_revoked_source_binding_canonical:=ops.canonical_jsonb_v1(
    v_revoked_source_binding);
  v_revoked_source_binding_digest:=encode(extensions.digest(
    v_revoked_source_binding_canonical,'sha256'),'hex');
  v_revoked_assertion:=jsonb_build_object(
    'schemaVersion','organization-official-channel-assertion.v1',
    'assertionId',revoked_assertion_id,'assertionVersion',1,
    'organizationKind','AGENCY','organizationId',organization_id,
    'verificationMethod','OFFICIAL_DOMAIN_EMAIL',
    'sourcePurpose','OFFICIAL_DOMAIN_CONTROL',
    'organizationSourceBindingDigest',v_revoked_source_binding_digest,
    'independentVerifierUserId',independent_verifier_id,
    'verifiedAt',v_revoked_base_at,
    'expiresAt',v_revoked_base_at+interval '23 hours');
  v_revoked_assertion_canonical:=ops.canonical_jsonb_v1(
    v_revoked_assertion);
  v_revoked_assertion_digest:=encode(extensions.digest(
    v_revoked_assertion_canonical,'sha256'),'hex');
  v_revoked_registry_receipt:=jsonb_build_object(
    'schemaVersion','organization-official-channel-receipt.v1',
    'assertionId',revoked_assertion_id,
    'assertionDigest',v_revoked_assertion_digest,
    'organizationSourceBindingDigest',v_revoked_source_binding_digest,
    'underlyingSourceProofDigest',v_revoked_verification_receipt,
    'organizationAuthorityReceiptKind','ORGANIZATION_DOMAIN_CONTROL',
    'organizationAuthorityReceiptDigest',v_revoked_authority_receipt_digest,
    'verifiedAt',v_revoked_base_at,
    'expiresAt',v_revoked_base_at+interval '23 hours');
  v_revoked_registry_receipt_canonical:=ops.canonical_jsonb_v1(
    v_revoked_registry_receipt);
  v_revoked_registry_receipt_digest:=encode(extensions.digest(
    v_revoked_registry_receipt_canonical,'sha256'),'hex');
  v_revoked_authority_audit_id:=ops.append_audit_event(
    'organization-channel:'||revoked_assertion_id::text,
    'USER',independent_verifier_id::text,authority_session_id,
    'organization.official_channel.attest','OrganizationOfficialChannel',
    revoked_assertion_id::text,'responses.review','SUCCESS',NULL,
    revoked_authority_request_id,jsonb_build_object(
      'organizationKind','AGENCY','organizationId',organization_id,
      'verificationMethod','OFFICIAL_DOMAIN_EMAIL',
      'sourceSnapshotDigest',v_revoked_authority_source_snapshot_digest,
      'authorityReceiptDigest',v_revoked_authority_receipt_digest,
      'registryReceiptDigest',v_revoked_registry_receipt_digest,
      'reasonDigest',v_revoked_authority_reason_digest));
  SELECT event_hash INTO STRICT v_revoked_authority_audit_digest
  FROM ops.audit_events WHERE id=v_revoked_authority_audit_id;
  v_revoked_authority_outbox_id:=ops.enqueue_outbox(
    'organization_official_channel',revoked_assertion_id::text,1,
    'organization.official_channel_attested.v1',jsonb_build_object(
      'assertionId',revoked_assertion_id,'organizationKind','AGENCY',
      'organizationId',organization_id,
      'verificationMethod','OFFICIAL_DOMAIN_EMAIL',
      'authorityReceiptDigest',v_revoked_authority_receipt_digest,
      'registryReceiptDigest',v_revoked_registry_receipt_digest,
      'attestedAt',v_revoked_base_at,
      'expiresAt',v_revoked_base_at+interval '23 hours'),v_revoked_base_at);
  INSERT INTO editorial.organization_official_channel_authority_receipts_v1(
    authority_receipt_id,authority_version,assertion_id,organization_kind,
    organization_id,agency_id,verification_method,source_id,
    communication_verification_id,source_purpose,authority_receipt_kind,
    underlying_source_proof_digest,source_snapshot_payload,
    source_snapshot_canonical,source_snapshot_digest,attested_by_user_id,
    actor_assertion_jti,actor_action_digest,step_up_authorization_id,
    step_up_receipt_digest,session_id,reason_digest,request_id,
    idempotency_key_sha256,request_digest,attested_at,expires_at,
    authority_payload,authority_canonical,authority_receipt_digest,
    audit_event_id,audit_receipt_digest,outbox_event_id)
  VALUES(revoked_authority_receipt_id,1,revoked_assertion_id,'AGENCY',
    organization_id,organization_id,'OFFICIAL_DOMAIN_EMAIL',
    revoked_verification_id,revoked_verification_id,
    v_revoked_authority_source->>'sourcePurpose',
    v_revoked_authority_source->>'authorityReceiptKind',
    v_revoked_authority_source->>'underlyingSourceProofDigest',
    v_revoked_authority_source_snapshot,
    v_revoked_authority_source_snapshot_canonical,
    v_revoked_authority_source_snapshot_digest,independent_verifier_id,
    revoked_authority_actor_assertion_jti,v_revoked_authority_action_digest,
    revoked_authority_step_up_id,v_revoked_authority_step_up_receipt_digest,
    authority_session_id,v_revoked_authority_reason_digest,
    revoked_authority_request_id,v_revoked_authority_idempotency_digest,
    v_revoked_authority_request_digest,v_revoked_base_at,
    v_revoked_base_at+interval '23 hours',v_revoked_authority_payload,
    v_revoked_authority_canonical,v_revoked_authority_receipt_digest,
    v_revoked_authority_audit_id,v_revoked_authority_audit_digest,
    v_revoked_authority_outbox_id)
  ON CONFLICT DO NOTHING;
  INSERT INTO editorial.organization_official_channel_assertions_v1(
    assertion_id,assertion_version,organization_kind,organization_id,agency_id,
    verification_method,source_purpose,communication_subject_id,
    communication_subject_origin_digest,communication_subject_profile_version,
    communication_subject_profile_digest,communication_endpoint_id,
    communication_endpoint_version,communication_endpoint_digest,
    communication_verification_id,underlying_source_proof_digest,
    organization_authority_receipt_kind,organization_authority_receipt_digest,
    authority_receipt_id,authority_source_id,
    organization_source_binding_payload,organization_source_binding_canonical,
    organization_source_binding_digest,independent_verifier_user_id,verified_at,
    expires_at,assertion_payload,assertion_canonical,assertion_digest,
    receipt_payload,receipt_canonical,receipt_digest,created_at)
  VALUES(revoked_assertion_id,1,'AGENCY',organization_id,organization_id,
    'OFFICIAL_DOMAIN_EMAIL','OFFICIAL_DOMAIN_CONTROL',revoked_subject_id,
    v_revoked_request_binding,1,v_revoked_subject_profile,revoked_endpoint_id,1,
    v_revoked_endpoint_digest,
    revoked_verification_id,v_revoked_verification_receipt,
    'ORGANIZATION_DOMAIN_CONTROL',v_revoked_authority_receipt_digest,
    revoked_authority_receipt_id,revoked_verification_id,
    v_revoked_source_binding,v_revoked_source_binding_canonical,
    v_revoked_source_binding_digest,independent_verifier_id,v_revoked_base_at,
    v_revoked_base_at+interval '23 hours',v_revoked_assertion,
    v_revoked_assertion_canonical,v_revoked_assertion_digest,
    v_revoked_registry_receipt,v_revoked_registry_receipt_canonical,
    v_revoked_registry_receipt_digest,v_revoked_base_at)
  ON CONFLICT DO NOTHING;

  v_revocation_reason_digest:=encode(extensions.digest(convert_to(
    'R6D_CONTROL_SMOKE_REVOKED','UTF8'),'sha256'),'hex');
  v_revocation:=jsonb_build_object(
    'schemaVersion','organization-official-channel-revocation.v1',
    'revocationId',revocation_id,'assertionId',revoked_assertion_id,
    'assertionDigest',v_revoked_assertion_digest,
    'organizationSourceBindingDigest',v_revoked_source_binding_digest,
    'assertionReceiptDigest',v_revoked_registry_receipt_digest,
    'reasonCode','SOURCE_REVOKED','reasonDigest',v_revocation_reason_digest,
    'revokedByUserId',identity_actor_id,'revokedAt',v_revoked_base_at);
  v_revocation_canonical:=ops.canonical_jsonb_v1(v_revocation);
  v_revocation_receipt_digest:=encode(extensions.digest(
    v_revocation_canonical,'sha256'),'hex');
  SELECT * INTO STRICT v_revocation_step_up
  FROM ops.step_up_authorizations WHERE id=revocation_step_up_id;
  v_revocation_step_up_payload:=jsonb_build_object(
    'schemaVersion','step-up-authorization-receipt.v1',
    'authorizationId',v_revocation_step_up.id,
    'actionDigest',btrim(v_revocation_step_up.action_digest),
    'sessionId',v_revocation_step_up.session_id,
    'issueNumber',v_revocation_step_up.assertion_issue_count,
    'issuedAt',v_revocation_step_up.last_issued_at,
    'expiresAt',v_revocation_step_up.expires_at);
  v_revocation_step_up_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_revocation_step_up_payload),'sha256'),'hex');
  v_revocation_audit_id:=ops.append_audit_event(
    'organization-channel:'||revoked_assertion_id::text,
    'USER',identity_actor_id::text,revocation_session_id,
    'organization.official_channel.revoke','OrganizationOfficialChannel',
    revoked_assertion_id::text,'responses.review','SUCCESS',NULL,
    revocation_request_id,jsonb_build_object(
      'assertionId',revoked_assertion_id,
      'authorityReceiptDigest',v_revoked_authority_receipt_digest,
      'revocationReceiptDigest',v_revocation_receipt_digest,
      'reasonCode','SOURCE_REVOKED','reasonDigest',v_revocation_reason_digest));
  SELECT event_hash INTO STRICT v_revocation_audit_digest
  FROM ops.audit_events WHERE id=v_revocation_audit_id;
  v_revocation_outbox_id:=ops.enqueue_outbox(
    'organization_official_channel',revoked_assertion_id::text,2,
    'organization.official_channel_revoked.v1',jsonb_build_object(
      'revocationId',revocation_id,'assertionId',revoked_assertion_id,
      'revocationReceiptDigest',v_revocation_receipt_digest,
      'revokedAt',v_revoked_base_at),v_revoked_base_at);
  INSERT INTO editorial.organization_official_channel_revocation_receipts_v1(
    revocation_id,assertion_id,assertion_digest,
    organization_source_binding_digest,assertion_receipt_digest,reason_code,
    reason_digest,revoked_by_user_id,revoked_at,revocation_payload,
    revocation_canonical,revocation_receipt_digest,actor_assertion_jti,
    actor_action_digest,step_up_authorization_id,step_up_receipt_digest,
    session_id,request_id,idempotency_key_sha256,request_digest,audit_event_id,
    audit_receipt_digest,outbox_event_id,created_at)
  VALUES(revocation_id,revoked_assertion_id,v_revoked_assertion_digest,
    v_revoked_source_binding_digest,v_revoked_registry_receipt_digest,
    'SOURCE_REVOKED',v_revocation_reason_digest,identity_actor_id,
    v_revoked_base_at,v_revocation,v_revocation_canonical,
    v_revocation_receipt_digest,revocation_actor_assertion_jti,
    v_revocation_action_digest,revocation_step_up_id,
    v_revocation_step_up_receipt_digest,revocation_session_id,
    revocation_request_id,v_revocation_idempotency_digest,
    v_revocation_request_digest,v_revocation_audit_id,v_revocation_audit_digest,
    v_revocation_outbox_id,v_revoked_base_at)
  ON CONFLICT DO NOTHING;

  BEGIN
    PERFORM editorial.require_current_official_channel_v1(
      revoked_assertion_id,'AGENCY',organization_id,request_id,case_id,
      identity_actor_id,clock_timestamp());
    RAISE EXCEPTION 'revoked official-channel fixture unexpectedly qualified';
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM<>'official_channel_unavailable' THEN
      RAISE;
    END IF;
  END;

  v_consent:=jsonb_build_object(
    'bodyConsent',true,'attachmentConsents','[]'::jsonb,
    'identityDisplay','ORGANIZATION_NAME','redactionAcknowledged',true,
    'excerptReviewRequested',true,'consentedAt',v_base_at);
  INSERT INTO intake.submission_sessions(
    id,token_hash,session_kind,scope_type,scope_id,bff_issuer,status,version,
    issued_at,expires_at)
  VALUES(response_session_id,encode(extensions.digest(convert_to(
      'r6d-response-identity-active-session','UTF8'),'sha256'),'hex'),
    'RESPONSE_ACTIVE','RESPONSE_REQUEST',request_id,'response-portal','ACTIVE',1,
    v_base_at,v_base_at+interval '23 hours')
  ON CONFLICT DO NOTHING;
  INSERT INTO intake.response_drafts(
    id,response_request_id,version,answers_encrypted,publication_consent,
    saved_at,expires_at)
  VALUES(draft_id,request_id,1,v_answers,v_consent,v_base_at,
    v_base_at+interval '23 hours')
  ON CONFLICT DO NOTHING;

  v_submission_sha:=encode(extensions.digest(v_answers,'sha256'),'hex');
  v_submit_idempotency:=encode(extensions.digest(convert_to(
    'r6d-response-identity-submit-idempotency','UTF8'),'sha256'),'hex');
  v_submit_request_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object('responseRequestId',request_id,'draftVersion',1,
      'submissionId',submission_id,'submissionSha256',v_submission_sha,
      'publicationConsent',v_consent,
      'receiptSessionExpiresAt',v_base_at+interval '23 hours')
  ),'sha256'),'hex');
  -- The submission boundary is RLS-scoped to the exact response request.
  PERFORM set_config('gurine.response_request_id',request_id::text,true);
  v_submit_result:=intake.submit_response_session_v3(
    encode(extensions.digest(convert_to(
      'r6d-response-identity-active-session','UTF8'),'sha256'),'hex'),
    'response-portal',1,true,v_submission_sha,v_answers,v_consent,submission_id,
    encode(extensions.digest(convert_to(
      'r6d-response-identity-receipt-token','UTF8'),'sha256'),'hex'),
    encode(extensions.digest(convert_to(
      'r6d-response-identity-receipt-session','UTF8'),'sha256'),'hex'),
    v_base_at+interval '23 hours',v_submit_idempotency,v_submit_request_digest);
  SELECT * INTO STRICT v_submit_receipt
  FROM intake.response_submission_receipts_v3
  WHERE response_submission_id=submission_id;
  IF (v_submit_result->>'submissionId')::uuid<>submission_id
     OR v_submit_receipt.response_request_id<>request_id
     OR v_submit_receipt.response_request_binding_digest<>v_request_binding THEN
    RAISE EXCEPTION 'r6d response identity submission owner fixture invalid';
  END IF;

  v_materialize_input:=ROW(
    v_submit_receipt.workflow_event_id,
    v_submit_receipt.workflow_event_envelope_digest,submission_id,request_id,
    v_submit_receipt.response_request_version,v_request_binding,
    v_submission_sha,v_submit_receipt.receipt_version,
    v_submit_receipt.receipt_digest,v_submit_receipt.submitted_at
  )::editorial.response_submission_intake_materialize_v1;
  v_materialize_idempotency:=encode(extensions.digest(convert_to(
    'r6d-response-identity-materialize-idempotency','UTF8'),'sha256'),'hex');
  v_materialize_request_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(to_jsonb(v_materialize_input)),'sha256'),'hex');
  v_materialize_result:=editorial.materialize_response_submission_v2(
    v_materialize_input,NULL::uuid,v_materialize_idempotency,
    v_materialize_request_digest);
  SELECT * INTO STRICT v_response
  FROM editorial.responses AS response
  WHERE response.submission_id=r6d_response_identity_fixture.submission_id;
  IF (v_materialize_result).editorial_response_id<>v_response.id
     OR v_response.response_request_id<>request_id
     OR v_response.party_type<>'AGENCY'
     OR v_response.party_entity_id<>organization_id
     OR v_response.organization_identity_status<>'UNVERIFIED'
     OR v_response.publication_form<>'INTERNAL_ONLY'
     OR v_response.version<>1
     OR v_response.response_content_sha256<>
       encode(extensions.digest(v_answers,'sha256'),'hex') THEN
    RAISE EXCEPTION 'r6d response identity materialization owner fixture invalid';
  END IF;
END $$;
COMMIT;

-- Extension-decision witness: a response-request-scoped communication intent
-- and delivery chain supplies the exact clock/receipt bindings required by
-- the policy extension owner routine.
BEGIN;
DO $$
DECLARE
  d constant char(64) := repeat('c',64);
  intent constant uuid := '5f8e6a7b-4c3d-5e2f-9a1b-7c6d5e4f3a21';
  rendering constant uuid := '6a9b8c7d-5e4f-6a3b-8c2d-1e0f9a8b7c6d';
  delivery constant uuid := '7b8c9d0e-6f5a-4b3c-9d2e-1f0a8b7c6d5e';
  attempt constant uuid := '8c9d0e1f-7a6b-5c4d-8e3f-2a1b9c8d7e6f';
  receipt constant uuid := '9d0e1f2a-8b7c-6d5e-4f3a-2b1c0d9e8f7a';
  calendar constant uuid := '34c9c2b6-a0a8-517c-afc0-1bf96c7829e6';
  v_config_digest char(64);
  now_at timestamptz := clock_timestamp();
BEGIN
  SELECT pc.configuration_digest INTO STRICT v_config_digest
    FROM ops.communication_provider_configs pc
   WHERE pc.id='59e6fe3c-6803-5f19-8ee2-1595abc421a8' AND pc.version=1;

  INSERT INTO intake.communication_endpoint_link_events(
    id,subject_id,subject_origin_binding_digest,endpoint_id,endpoint_sequence,
    profile_version,prior_endpoint_version,endpoint_version,endpoint_hmac,endpoint_digest,channel,
    prior_state,state,change_kind,proof_digest,reason_code,endpoint_snapshot_digest,
    event_digest,audit_event_id,receipt_digest,occurred_at)
  VALUES('4e5f6a7b-8c9d-4e0f-9a1b-2c3d4e5f6a7b','11111111-1111-4111-8111-111111111111',repeat('b',64),
    '0f6d16aa-3c47-5e6a-9c5e-c0c33c45d7a8',2,2,1,2,d,d,'SMTP_EMAIL','ACTIVE','ACTIVE','VERIFIED',d,
    'CONTROL_EXTENSION',d,d,gen_random_uuid(),d,now_at)
  ON CONFLICT DO NOTHING;
  INSERT INTO ops.communication_intents(
    id,deployment_id,logical_intent_digest,source_event_id,source_event_type,
    source_object_type,source_object_id,material_event_version,communication_class,
    purpose,topic_scope,topic_scope_digest,recipient_subject_id,audience_policy_version,
    audience_policy_digest,policy_snapshot_digest,effect_safety_class,
    source_decision_receipt_id,source_decision_digest,state,version,intent_digest,
    creation_receipt_digest,created_at,state_changed_at)
  VALUES(intent,'control',d,gen_random_uuid(),'control.fixture','RESPONSE_REQUEST',
    'a3493bbe-83cc-5a9b-b251-de7cc46c62d8',1,'SYSTEM_TRANSACTIONAL','RIGHT_OF_REPLY_REQUEST',
    '{}'::jsonb,d,'11111111-1111-4111-8111-111111111111','policy-v1',d,d,
    'DUPLICATION_TOLERANT',gen_random_uuid(),d,'CREATED',1,d,d,now_at,now_at)
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.communication_renderings(
    id,intent_id,rendering_revision,endpoint_id,endpoint_version,endpoint_snapshot_digest,
    channel,locale,template_id,template_revision,variable_set,variable_set_digest,
    attachment_manifest,attachment_manifest_digest,disclosure_class,semantic_payload_digest,
    recipient_binding_digest,rendered_envelope_ciphertext,encryption_key_id,rendered_sha256,
    rendered_byte_length,transport_content_type,state,state_version,rendering_digest,
    transition_receipt_digest,expires_at,created_at)
  VALUES(rendering,intent,1,'0f6d16aa-3c47-5e6a-9c5e-c0c33c45d7a8',2,d,'SMTP_EMAIL','ko-KR',
    'control-extension','v1','{}'::jsonb,d,'[]'::jsonb,d,'INTERNAL_MINIMAL',d,d,
    convert_to(rpad('fixture-extension-envelope',32,' '),'UTF8'),'fixture-key',d,32,'text/plain',
    'DRAFT',1,d,d,now_at+interval '1 day',now_at)
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.outbound_deliveries(
    id,contract_version,dispatch_eligible,intent_id,intent_digest,rendering_id,endpoint_id,
    endpoint_version,endpoint_snapshot_digest,provider_config_id,provider_config_version,
    provider_configuration_digest,provider_preflight_receipt_id,provider_preflight_receipt_digest,
    channel,delivery_key,rendered_sha256,rendering_digest,authorization_snapshot_digest,
    activation_receipt_digest,budget_reservation_id,provider_idempotency_key_sha256,delivery_digest,
    state,version,generation,event_sequence,receipt_sequence,attempt_count,max_attempts,
    current_evidence_rank,highest_proof_level,not_before,next_attempt_at,queued_at,updated_at,
    message_type,recipient_hash,template_version)
  VALUES(delivery,'COMMUNICATION_V1',false,intent,d,rendering,'0f6d16aa-3c47-5e6a-9c5e-c0c33c45d7a8',2,d,
    '59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,v_config_digest,'d8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef',repeat('b',64),
    'SMTP_EMAIL',d,d,d,d,d,'7f0f0a74-4a15-5b79-b3ae-0fdac4308a6d',d,d,'DELIVERED',2,1,2,1,1,3,50,'DELIVERED',
    now_at,now_at,now_at,now_at,'COMMUNICATION',d,'v1')
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.outbound_delivery_attempts(
    id,delivery_id,attempt_ordinal,dispatch_generation,delivery_version_at_claim,endpoint_id,
    endpoint_version,endpoint_snapshot_digest,provider_config_id,provider_config_version,
    configuration_digest,provider_preflight_receipt_id,provider_preflight_receipt_digest,
    budget_reservation_id,worker_id,lease_token_hash,fencing_token,provider_idempotency_key_sha256,
    request_sha256,rendered_sha256,authorization_snapshot_digest,suppression_snapshot_digest,
    activation_receipt_digest,policy_fence_digest,transport_policy_version,deadline_at,claimed_at,
    lease_expires_at,attempt_digest,claim_receipt_digest,audit_event_id)
  VALUES(attempt,delivery,1,1,1,'0f6d16aa-3c47-5e6a-9c5e-c0c33c45d7a8',2,d,
    '59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,v_config_digest,'d8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef',repeat('b',64),
    '7f0f0a74-4a15-5b79-b3ae-0fdac4308a6d','control-extension-worker',d,1,d,d,d,d,d,d,d,'communication-v1',
    now_at+interval '2 hours',now_at,now_at+interval '1 hour',d,d,gen_random_uuid())
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.outbound_delivery_receipts(
    id,delivery_id,receipt_sequence,event_aggregate_version,prior_delivery_version,delivery_version,
    attempt_id,source_kind,observation_key_digest,projection_disposition,evidence_kind,evidence_rank,
    prior_state,asserted_state,resulting_state,prior_proof_level,resulting_proof_level,applied,
    provider_evidence_digest,rendering_digest,endpoint_id,endpoint_version,endpoint_snapshot_digest,
    endpoint_identity_hash,provider_preflight_receipt_id,provider_config_id,provider_config_version,
    provider_configuration_digest,provider_preflight_receipt_digest,provider_identity_hash,
    authorization_snapshot_digest,activation_receipt_digest,budget_reservation_id,observed_at,
    actor_type,actor_id,request_id,trace_id,receipt_digest,audit_event_id,outbox_event_id)
  VALUES(receipt,delivery,1,2,1,2,'c0d5cb1a-e63b-5e23-92ef-8d94ea73bf03','PROVIDER_RESPONSE',d,'APPLIED','PROVIDER_RESPONSE',50,
    'QUEUED','DELIVERED','DELIVERED','NONE','DELIVERED',true,d,d,'0f6d16aa-3c47-5e6a-9c5e-c0c33c45d7a8',2,d,d,
    'd8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef','59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,v_config_digest,repeat('b',64),d,d,d,
    '7f0f0a74-4a15-5b79-b3ae-0fdac4308a6d',now_at,'AUTHORIZED_SERVICE',NULL,gen_random_uuid(),'control-extension',d,gen_random_uuid(),gen_random_uuid())
  ON CONFLICT DO NOTHING;

  INSERT INTO ops.business_calendar_versions(
    id,calendar_id,version,timezone,weekend_days,holiday_dates,holiday_set_digest,policy_digest,
    calendar_digest,approval_proposal_id,approval_proposal_version,approval_digest,execution_receipt_id,
    execution_receipt_digest,effective_at,review_expires_at,created_by)
  VALUES(calendar,'45e6f7a8-b9c0-4d1e-8f2a-3b4c5d6e7f80',1,'UTC',ARRAY[0,6]::smallint[],ARRAY[]::date[],d,d,d,
    gen_random_uuid(),1,d,gen_random_uuid(),d,now_at-interval '1 day',now_at+interval '30 days',
    '11111111-1111-4111-8111-111111111111')
  ON CONFLICT DO NOTHING;

  INSERT INTO editorial.response_delivery_clock_decisions(
    id,response_request_id,response_request_version,response_request_binding_digest,clock_revision,
    communication_intent_id,intent_source_decision_digest,delivery_source_object_type,outbound_delivery_id,
    delivery_receipt_id,delivery_receipt_sequence,delivery_receipt_digest,delivery_resulting_state,
    delivery_receipt_applied,evidence_kind,rendering_digest,endpoint_identity_hash,provider_identity_hash,
    evidence_digest,verified_delivery_at,calendar_version_id,calendar_digest,policy_digest,
    window_business_days,timezone,due_at,decision_digest,audit_event_id,outbox_event_id)
  VALUES(gen_random_uuid(),'a3493bbe-83cc-5a9b-b251-de7cc46c62d8',1,d,1,intent,d,'RESPONSE_REQUEST',delivery,receipt,1,d,
    'DELIVERED',true,'AUTHENTICATED_PROVIDER_POLL',d,d,d,d,now_at-interval '1 hour',calendar,d,d,5,'UTC',
    now_at+interval '1 day',d,gen_random_uuid(),gen_random_uuid())
  ON CONFLICT DO NOTHING;

  INSERT INTO intake.response_extension_requests(id,response_request_id,requested_due_at,reason,status,submitted_at,version,updated_at)
  VALUES('a897f24b-d4a5-519e-b6f9-80c7635f6d40','a3493bbe-83cc-5a9b-b251-de7cc46c62d8',now_at+interval '2 days','Control fixture extension','SUBMITTED',now_at,1,now_at)
  ON CONFLICT DO NOTHING;
END $$;
COMMIT;

-- Detail-query witness for the immutable response-appeal workspace.  The
-- request/submission identifiers intentionally point at the canonical
-- response request fixture; the appeal table keeps its own receipt and
-- digest fences so the read path exercises the production-shaped row.
BEGIN;
INSERT INTO intake.appeals(
  id,response_request_id,response_submission_id,expected_receipt_version,
  prior_decision_kind,prior_decision_id,prior_receipt_digest,reason_code,
  requested_outcome,statement_ciphertext,statement_sha256,encryption_key_id,
  supporting_attachment_ids,supporting_attachment_set_digest,attestation,
  privacy_consent,initial_state,appeal_digest,review_due_at,
  appeal_window_expires_at,idempotency_key_hash,request_digest,audit_event_id,
  outbox_event_id,receipt_digest,created_at)
VALUES(
  '19b4b013-ee8e-5a3d-be27-ce273e8bc56c',
  'a3493bbe-83cc-5a9b-b251-de7cc46c62d8',
  '3c4d5e6f-7081-492a-8b9c-0d1e2f3a4b5c',
  1,'DELIVERY_STATUS','4d5e6f70-8192-4a3b-8c0d-1e2f3a4b5c6d',repeat('c',64),
  'DELIVERY_DISPUTE','HUMAN_REVIEW',convert_to('Control fixture appeal statement','UTF8'),
  repeat('d',64),'fixture-key','{}',repeat('e',64),true,true,'RECEIVED',repeat('f',64),
  clock_timestamp()+interval '2 days',clock_timestamp()+interval '7 days',repeat('a',64),
  repeat('b',64),gen_random_uuid(),gen_random_uuid(),repeat('9',64),clock_timestamp())
ON CONFLICT DO NOTHING;
COMMIT;
