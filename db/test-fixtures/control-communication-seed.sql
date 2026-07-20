-- Read-only communication receipt witness used by the control-flow matrix.
-- The delivery is backed by endpoint, preflight and reservation records so
-- the receipt query exercises the same FK-bound evidence path as production.
BEGIN;
DO $$
DECLARE
  d constant char(64) := repeat('b',64);
  delivery constant uuid := '99999999-9999-4999-8999-999999999999';
  endpoint constant uuid := '0f6d16aa-3c47-5e6a-9c5e-c0c33c45d7a8';
  link_event constant uuid := 'b9c4a581-5b9f-5d6e-9953-7a3c979d74a1';
  preflight constant uuid := 'd8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef';
  reservation constant uuid := '7f0f0a74-4a15-5b79-b3ae-0fdac4308a6d';
  rendering constant uuid := 'e1e7f6f7-8c52-5c32-8f1f-2fef5f7c9d71';
  receipt constant uuid := 'e2d2e5d3-3d9f-5c1b-9c58-7d80e28f9f10';
  now_at timestamptz := clock_timestamp();
BEGIN
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
    id,deployment_id,environment,channel,adapter_id,operational_state,version,
    provider_account_hmac,sender_identity_ciphertext,sender_identity_hmac,
    encryption_key_id,credential_secret_reference,webhook_secret_reference,
    callback_path,callback_allowlist_digest,jurisdiction_set,jurisdiction_set_digest,
    dpa_evidence_digest,approved_template_catalog_digest,rate_limit_policy,
    rate_limit_policy_digest,cost_policy,cost_policy_digest,provider_capabilities,
    provider_capabilities_digest,kill_switch_code,configuration_digest,created_by,
    updated_by)
  VALUES('59e6fe3c-6803-5f19-8ee2-1595abc421a8','control','test','SMTP_EMAIL',
    'smtp-email-v1','DISABLED',1,d,convert_to(rpad('sender',32,' '),'UTF8'),d,
    'fixture-key','secret://control-provider/value@v1','secret://control-webhook/value@v1',
    '/private/v1/callbacks/control',d,'{}'::jsonb,d,d,d,'{}'::jsonb,d,'{}'::jsonb,d,
    '{}'::jsonb,d,'CONTROL_FIXTURE',d,'11111111-1111-4111-8111-111111111111',
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
  VALUES(preflight,'59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,d,'{}'::jsonb,d,1,
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
    '59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,d,'control-v1',1,'KRW',d,
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
    '59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,d,preflight,d,'SMTP_EMAIL',d,d,d,d,
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
    '59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,d,preflight,d,reservation,
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
    preflight,'59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,d,d,d,d,d,reservation,now_at,
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
  now_at timestamptz := clock_timestamp();
BEGIN
  INSERT INTO ops.outbound_deliveries(
    id,contract_version,dispatch_eligible,intent_id,intent_digest,rendering_id,endpoint_id,endpoint_version,
    endpoint_snapshot_digest,provider_config_id,provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_id,provider_preflight_receipt_digest,channel,delivery_key,rendered_sha256,
    rendering_digest,authorization_snapshot_digest,activation_receipt_digest,budget_reservation_id,
    provider_idempotency_key_sha256,delivery_digest,state,version,generation,event_sequence,receipt_sequence,
    attempt_count,max_attempts,current_evidence_rank,highest_proof_level,not_before,next_attempt_at,queued_at,
    updated_at,message_type,recipient_hash,template_version)
  VALUES(delivery,'COMMUNICATION_V1',false,intent,d,rendering,endpoint,1,d,
    '59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,d,preflight,d,'SMTP_EMAIL',repeat('d',64),d,d,d,d,
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
  VALUES(attempt,delivery,1,1,1,endpoint,1,d,'59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,d,preflight,d,
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
    preflight,'59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,d,d,d,d,d,reservation,now_at,'AUTHORIZED_SERVICE',NULL,
    gen_random_uuid(),'control-reconcile-fixture',repeat('f',64),gen_random_uuid(),gen_random_uuid())
  ON CONFLICT DO NOTHING;
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
  now_at timestamptz := clock_timestamp();
BEGIN
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
    '59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,repeat('b',64),'d8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef',repeat('b',64),
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
    '59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,repeat('b',64),'d8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef',repeat('b',64),
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
    'd8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef','59e6fe3c-6803-5f19-8ee2-1595abc421a8',1,repeat('b',64),repeat('b',64),d,d,d,
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
