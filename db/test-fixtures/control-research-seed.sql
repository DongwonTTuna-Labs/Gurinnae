-- Complete upstream lineage for the control-flow promotion witness.
-- This is intentionally a real, clean FETCH_URL artifact: the promotion
-- owner must re-bind the run/turn/tool/fetch/artifact tuple, current GRANT,
-- parser segment and source-use root before it writes evidence.
BEGIN;

-- The fetch fixture is admitted by the same closed capability evidence used
-- in production.  Each right dimension is backed by its own active class;
-- no synthetic all-ALLOW asset-rights row is inserted by the fixture.
DO $$
DECLARE
  v_class text;
  v_slug text;
  v_target text;
  v_target_digest char(64);
  v_legal_snapshot_id uuid;
  v_operational_snapshot_id uuid;
  v_legal_snapshot_sha char(64);
  v_operational_snapshot_sha char(64);
  v_license_digest char(64);
  v_dpa_digest char(64);
  v_digest char(64);
BEGIN
  FOREACH v_class IN ARRAY ARRAY[
    'SOURCE_ACCESS','SOURCE_STORAGE','SOURCE_REDISTRIBUTION',
    'MODEL_EGRESS','PAID_WORKSPACE_PROCESSING','PUBLIC_PUBLICATION'
  ] LOOP
    v_slug := lower(v_class);
    v_target := 'control.fixture.'||v_slug;
    v_target_digest := encode(extensions.digest(convert_to('target:'||v_class,'UTF8'),'sha256'),'hex');
    v_legal_snapshot_id := substring(encode(extensions.digest(convert_to('legal-snapshot-id:'||v_class,'UTF8'),'sha256'),'hex') FROM 1 FOR 32)::uuid;
    v_operational_snapshot_id := substring(encode(extensions.digest(convert_to('operational-snapshot-id:'||v_class,'UTF8'),'sha256'),'hex') FROM 1 FOR 32)::uuid;
    v_legal_snapshot_sha := encode(extensions.digest(convert_to('legal-snapshot:'||v_class,'UTF8'),'sha256'),'hex');
    v_operational_snapshot_sha := encode(extensions.digest(convert_to('operational-snapshot:'||v_class,'UTF8'),'sha256'),'hex');

    INSERT INTO editorial.conflict_snapshots(
      id,subject_actor_id,target_type,target_id,target_version,target_digest,
      operation_id,action_kind,candidate_role,declaration_ids,declaration_set_digest,
      finding_set,finding_set_digest,authorship_digest,party_recipient_digest,
      role_digest,relationship_digest,funding_customer_digest,policy_digest,
      evaluation_state,blocker_codes,nonwaivable_blocker_count,evaluated_at,
      valid_until,evaluated_by_type,evaluated_by_id,snapshot_sha256,receipt_digest)
    VALUES
      (v_legal_snapshot_id,'11111111-1111-4111-8111-111111111111','CAPABILITY',v_target,1,v_target_digest,
       'private.ExecuteApprovedAction','CAPABILITY_ACTIVATION','LEGAL_REVIEWER','{}'::uuid[],
       encode(extensions.digest(convert_to('legal-declarations:'||v_class,'UTF8'),'sha256'),'hex'),'{}'::jsonb,
       encode(extensions.digest(convert_to('legal-findings:'||v_class,'UTF8'),'sha256'),'hex'),
       encode(extensions.digest(convert_to('legal-authorship:'||v_class,'UTF8'),'sha256'),'hex'),
       encode(extensions.digest(convert_to('legal-party:'||v_class,'UTF8'),'sha256'),'hex'),
       encode(extensions.digest(convert_to('legal-role:'||v_class,'UTF8'),'sha256'),'hex'),
       encode(extensions.digest(convert_to('legal-relationship:'||v_class,'UTF8'),'sha256'),'hex'),
       encode(extensions.digest(convert_to('legal-funding:'||v_class,'UTF8'),'sha256'),'hex'),
       encode(extensions.digest(convert_to('legal-policy:'||v_class,'UTF8'),'sha256'),'hex'),
       'CLEAR','{}'::text[],0,'2026-01-01T00:00:00Z','2099-01-01T00:00:00Z',
       'SERVICE','control-capability-fixture',v_legal_snapshot_sha,
       encode(extensions.digest(convert_to('legal-receipt:'||v_class,'UTF8'),'sha256'),'hex')),
      (v_operational_snapshot_id,'22222222-2222-4222-8222-222222222222','CAPABILITY',v_target,1,v_target_digest,
       'private.ExecuteApprovedAction','CAPABILITY_ACTIVATION','EXECUTOR','{}'::uuid[],
       encode(extensions.digest(convert_to('operational-declarations:'||v_class,'UTF8'),'sha256'),'hex'),'{}'::jsonb,
       encode(extensions.digest(convert_to('operational-findings:'||v_class,'UTF8'),'sha256'),'hex'),
       encode(extensions.digest(convert_to('operational-authorship:'||v_class,'UTF8'),'sha256'),'hex'),
       encode(extensions.digest(convert_to('operational-party:'||v_class,'UTF8'),'sha256'),'hex'),
       encode(extensions.digest(convert_to('operational-role:'||v_class,'UTF8'),'sha256'),'hex'),
       encode(extensions.digest(convert_to('operational-relationship:'||v_class,'UTF8'),'sha256'),'hex'),
       encode(extensions.digest(convert_to('operational-funding:'||v_class,'UTF8'),'sha256'),'hex'),
       encode(extensions.digest(convert_to('operational-policy:'||v_class,'UTF8'),'sha256'),'hex'),
       'CLEAR','{}'::text[],0,'2026-01-01T00:00:01Z','2099-01-01T00:00:00Z',
       'SERVICE','control-capability-fixture',v_operational_snapshot_sha,
       encode(extensions.digest(convert_to('operational-receipt:'||v_class,'UTF8'),'sha256'),'hex'))
    ON CONFLICT DO NOTHING;

    v_license_digest := CASE WHEN v_class IN ('SOURCE_ACCESS','SOURCE_STORAGE','SOURCE_REDISTRIBUTION')
      THEN encode(extensions.digest(convert_to('license:'||v_class,'UTF8'),'sha256'),'hex') ELSE NULL END;
    v_dpa_digest := CASE WHEN v_class IN ('MODEL_EGRESS','PAID_WORKSPACE_PROCESSING')
      THEN encode(extensions.digest(convert_to('dpa:'||v_class,'UTF8'),'sha256'),'hex') ELSE NULL END;
    v_digest := encode(extensions.digest(convert_to('capability-decision:'||v_class,'UTF8'),'sha256'),'hex');

    INSERT INTO ops.capability_activation_decisions(
      id,capability_id,capability_class,environment,configuration_digest,
      decision_version,prior_decision_id,legal_state,operational_state,
      legal_entity_id,controller_id,jurisdiction_codes,scope_type,scope_id,
      scope_version,scope_digest,data_class_codes,policy_digest,contract_digest,
      dpa_digest,license_digest,rights_digest,provider_preflight_receipt_digest,
      routing_policy_digest,kill_switch_digest,conditions_encrypted,
      conditions_digest,evidence_set_digest,proposal_id,proposal_version,
      approval_digest,legal_action_decision_id,legal_action_decision_receipt_digest,
      legal_approver_user_id,legal_action_decision_kind,legal_conflict_snapshot_id,
      legal_conflict_snapshot_digest,operational_action_decision_id,
      operational_action_decision_receipt_digest,operational_approver_user_id,
      operational_action_decision_kind,operational_conflict_snapshot_id,
      operational_conflict_snapshot_digest,counted_decision_set_digest,
      execution_id,execution_generation,execution_digest,execution_receipt_id,
      execution_receipt_digest,decided_by_service,reason_code,reason_encrypted,
      reason_digest,effective_at,expires_at,decision_digest)
    VALUES(
      substring(encode(extensions.digest(convert_to('capability-decision-id:'||v_class,'UTF8'),'sha256'),'hex') FROM 1 FOR 32)::uuid,
      v_target,v_class,'TEST',encode(extensions.digest(convert_to('configuration:'||v_class,'UTF8'),'sha256'),'hex'),
      1,NULL,'APPROVED','ACTIVE','gurinnae-fixture','gurinnae-fixture',ARRAY['GLOBAL'],
      'SOURCE','control-fixture-source',1,
      encode(extensions.digest(convert_to('scope:'||v_class,'UTF8'),'sha256'),'hex'),ARRAY['PUBLIC'],
      encode(extensions.digest(convert_to('policy:'||v_class,'UTF8'),'sha256'),'hex'),
      encode(extensions.digest(convert_to('contract:'||v_class,'UTF8'),'sha256'),'hex'),
      v_dpa_digest,v_license_digest,
      encode(extensions.digest(convert_to('rights:'||v_class,'UTF8'),'sha256'),'hex'),
      encode(extensions.digest(convert_to('preflight:'||v_class,'UTF8'),'sha256'),'hex'),
      encode(extensions.digest(convert_to('routing:'||v_class,'UTF8'),'sha256'),'hex'),
      encode(extensions.digest(convert_to('kill-switch:'||v_class,'UTF8'),'sha256'),'hex'),
      NULL,encode(extensions.digest(convert_to('conditions:'||v_class,'UTF8'),'sha256'),'hex'),
      encode(extensions.digest(convert_to('evidence-set:'||v_class,'UTF8'),'sha256'),'hex'),
      substring(encode(extensions.digest(convert_to('proposal:'||v_class,'UTF8'),'sha256'),'hex') FROM 1 FOR 32)::uuid,1,
      encode(extensions.digest(convert_to('approval:'||v_class,'UTF8'),'sha256'),'hex'),
      substring(encode(extensions.digest(convert_to('legal-decision:'||v_class,'UTF8'),'sha256'),'hex') FROM 1 FOR 32)::uuid,
      encode(extensions.digest(convert_to('legal-decision-receipt:'||v_class,'UTF8'),'sha256'),'hex'),
      '11111111-1111-4111-8111-111111111111','APPROVE',v_legal_snapshot_id,v_legal_snapshot_sha,
      substring(encode(extensions.digest(convert_to('operational-decision:'||v_class,'UTF8'),'sha256'),'hex') FROM 1 FOR 32)::uuid,
      encode(extensions.digest(convert_to('operational-decision-receipt:'||v_class,'UTF8'),'sha256'),'hex'),
      '22222222-2222-4222-8222-222222222222','APPROVE',v_operational_snapshot_id,v_operational_snapshot_sha,
      encode(extensions.digest(convert_to('counted-decisions:'||v_class,'UTF8'),'sha256'),'hex'),
      substring(encode(extensions.digest(convert_to('execution:'||v_class,'UTF8'),'sha256'),'hex') FROM 1 FOR 32)::uuid,1,
      encode(extensions.digest(convert_to('execution-digest:'||v_class,'UTF8'),'sha256'),'hex'),
      substring(encode(extensions.digest(convert_to('execution-receipt-id:'||v_class,'UTF8'),'sha256'),'hex') FROM 1 FOR 32)::uuid,
      encode(extensions.digest(convert_to('execution-receipt:'||v_class,'UTF8'),'sha256'),'hex'),
      'workflow-worker','CONTROL_FIXTURE',convert_to('Approved control research capability fixture','UTF8'),
      encode(extensions.digest(convert_to('Approved control research capability fixture','UTF8'),'sha256'),'hex'),
      '2026-01-01T00:00:02Z','2099-01-01T00:00:00Z',v_digest)
    ON CONFLICT DO NOTHING;
  END LOOP;
END $$;

INSERT INTO raw.source_fetches(
  id,source_id,external_locator,requested_at,completed_at,http_status,
  content_type,payload_sha256,payload_size_bytes,object_key)
VALUES(
  '86bfb4f9-eefd-533b-83fa-df5dc32e2c2f','control-fixture-source',
  'https://example.test/gurinnae/control-promotion-fixture',
  '2026-01-02T22:02:56Z','2026-01-02T22:02:56Z',200,'text/plain',
  '4951601014f8f3dfce1477715f11e812d5c8a29f00bd88803405fd32d4af07c6',35,
  'research/control-promotion-fixture.txt')
ON CONFLICT DO NOTHING;

INSERT INTO raw.source_documents(
  id,source_id,source_fetch_id,external_id,external_version,canonical_url,
  retrieved_at,content_type,content_sha256,content_size_bytes,object_key,status,
  parser_name,parser_version,schema_version,prompt_injection_flags,metadata,
  asset_id,asset_revision)
VALUES(
  '0ab0b0bc-40db-562a-af3b-cf21cf7a8215','control-fixture-source',
  '86bfb4f9-eefd-533b-83fa-df5dc32e2c2f','control-promotion-fixture','1',
  'https://example.test/gurinnae/control-promotion-fixture',
  '2026-01-02T22:02:56Z','text/plain',
  '4951601014f8f3dfce1477715f11e812d5c8a29f00bd88803405fd32d4af07c6',35,
  'research/control-promotion-fixture.txt','PARSED','control-fixture-parser','v1',
  'control-research-v1','[]','{"fixture":true}',
  'a9bdbc4c-076b-5d00-93da-c8074941d1c0',1)
ON CONFLICT DO NOTHING;

INSERT INTO raw.evidence_segments(
  id,source_document_id,source_asset_id,source_asset_revision,source_content_sha256,
  parser_run_id,parser_name,parser_version,segment_ordinal,locator_kind,locator_value,
  locator_digest,raw_value_sha256,selected_content_sha256,selected_content_object_key,
  selected_content_locator,selected_content_media_type,transformation_version,
  classification,source_authority,retrieved_at,segment_digest)
VALUES(
  '1e44d0d1-9826-59fb-bc26-07c443a2134d',
  '0ab0b0bc-40db-562a-af3b-cf21cf7a8215','a9bdbc4c-076b-5d00-93da-c8074941d1c0',1,
  '4951601014f8f3dfce1477715f11e812d5c8a29f00bd88803405fd32d4af07c6',
  '8f32c1d9-746c-5f89-b575-c688e14b410d','control-fixture-parser','v1',0,
  'HTML_CSS_SELECTOR','https://example.test/gurinnae/control-promotion-fixture',
  '4656013e261fa8c167a4157ef90e11af4fba55d5c9ac9b7d60e1e2ea39fc274d',
  'f3ff44d5adaad2d6aecb8d303d2e0a772b8867ca2cae65a7f9f8788f508d5de4',
  '4951601014f8f3dfce1477715f11e812d5c8a29f00bd88803405fd32d4af07c6',
  'research/control-promotion-fixture.txt','https://example.test/gurinnae/control-promotion-fixture',
  'text/plain','control-research-v1','PUBLIC','control-fixture-source',
  '2026-01-02T22:02:56Z',repeat('4',64))
ON CONFLICT DO NOTHING;

-- The completed local provider turn and source.fetch tool call are retained
-- with their canonical bytes/digests so record_research_fetch_v1 can be used
-- exactly as the analysis worker would use it.
INSERT INTO ops.agent_provider_turns(
  provider_turn_id,agent_run_id,input_snapshot_sha256,turn_sequence,attempt_sequence,
  prior_transcript_sha256,provider_mode,provider_candidate_id,model_id,
  model_configuration_sha256,routing_policy_version,routing_decision_sha256,
  prompt_id,prompt_version,prompt_sha256,output_schema_id,output_schema_version,
  output_schema_sha256,classification,model_use_rights_sha256,
  budget_reservation_key_sha256,dispatch_key_sha256,request_sha256,request_redacted,
  request_canonical,status,envelope_kind,envelope_sha256,envelope_payload_sha256,
  envelope_canonical,response_redacted,response_redacted_canonical,provider_receipt_id,provider_receipt,
  provider_receipt_canonical,provider_receipt_sha256,provider_turn_canonical,
  provider_turn_sha256,turn_transcript_sha256,input_units,output_units,latency_ms,
  call_id,tool_id,version,dispatched_at,completed_at)
VALUES(
  'df45a69f-7ddb-5d39-b135-cc6eeacddd96','8eee21b7-75c0-53c9-b079-d897a2c3c711',repeat('9',64),1,1,
  repeat('0',64),'LOCAL_APPROVED','control-fixture','control-fixture-model',repeat('1',64),
  'control-routing-v1',repeat('2',64),'control-prompt','v1',repeat('3',64),
  'source-fetch-response','v2',repeat('4',64),'PUBLIC',repeat('5',64),repeat('6',64),repeat('7',64),
  '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','{}',ops.canonical_jsonb_v1('{}'::jsonb),
  'COMPLETED','TOOL_CALL','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
  ops.canonical_jsonb_v1('{}'::jsonb),'{}',ops.canonical_jsonb_v1('{}'::jsonb),'5c4d3e2f-1a0b-4987-8654-3210fedcba98','{}',
  ops.canonical_jsonb_v1('{}'::jsonb),
  '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',ops.canonical_jsonb_v1('{}'::jsonb),
  '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',repeat('8',64),1,1,1,
  'promote-source-fetch','source.fetch',1,'2026-01-02T22:02:56Z','2026-01-02T22:02:57Z')
ON CONFLICT DO NOTHING;

INSERT INTO ops.agent_tool_calls(
  tool_call_id,agent_run_id,provider_turn_id,call_id,input_snapshot_sha256,prior_transcript_sha256,
  tool_id,tool_catalog_version,tool_catalog_sha256,request_schema_id,request_schema_version,
  request_schema_sha256,response_schema_id,response_schema_version,response_schema_sha256,
  timeout_ms,max_results,request_sha256,request_redacted,request_canonical,allowlist_decision_sha256,
  scope_decision_sha256,rights_decision_sha256,classification,status,result_kind,result_sha256,
  result_redacted,result_canonical,response_validation_sha256,result_transcript_sha256,source_use_count,
  source_use_set_sha256,latency_ms,terminal_at,claim_generation,lease_token_sha256,lease_expires_at,version,started_at)
VALUES(
  '043eb9f6-e47e-56de-a587-82969b7bc1b6','8eee21b7-75c0-53c9-b079-d897a2c3c711',
  'df45a69f-7ddb-5d39-b135-cc6eeacddd96','promote-source-fetch',repeat('9',64),repeat('0',64),
  'source.fetch','control-tools-v1',repeat('1',64),'source-fetch.request','v2',
  '8a6083ee948e416f71d7ee7e34ddb6ca41e84a8e3a2d1be53c4900605dc80c67',
  'source-fetch.response','v2','42e59f2ddbe8bf2c58e61451cd698e388463f42bcdc13394bb6bf5140ca5912e',
  1000,1,'44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','{}',ops.canonical_jsonb_v1('{}'::jsonb),
  repeat('2',64),repeat('3',64),repeat('4',64),'PUBLIC','SUCCEEDED','TOOL_RESULT',
  '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','{}',ops.canonical_jsonb_v1('{}'::jsonb),
  repeat('5',64),repeat('6',64),0,'4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',1,
  '2026-01-02T22:02:57Z',1,repeat('7',64),'2026-01-02T23:02:57Z',1,'2026-01-02T22:02:56Z')
ON CONFLICT DO NOTHING;

DO $$
DECLARE
  v_content bytea := convert_to('gurinnae control promotion fixture' || chr(10), 'UTF8');
  v_content_sha char(64) := encode(extensions.digest(v_content,'sha256'),'hex');
  v_artifact_id uuid := 'facc134e-f4d3-551d-bb42-55d4495373ae';
  v_asset_id uuid := 'd3f33b34-05e9-5d0f-bdf0-95742b10d590';
  v_fetch_id uuid := '86bfb4f9-eefd-533b-83fa-df5dc32e2c2f';
  v_turn_id uuid := 'df45a69f-7ddb-5d39-b135-cc6eeacddd96';
  v_tool_id uuid := '043eb9f6-e47e-56de-a587-82969b7bc1b6';
  v_run_id uuid := '8eee21b7-75c0-53c9-b079-d897a2c3c711';
  v_source_use_id uuid := 'e3b5ed44-ec8b-5fb3-ad5c-924ca07afa9d';
  v_rights_id uuid := v_asset_id;
  v_locator text := 'https://example.test/gurinnae/control-promotion-fixture';
  v_locator_sha char(64) := encode(extensions.digest(convert_to(v_locator,'UTF8'),'sha256'),'hex');
  v_policy text := 'research-policy-v1';
  v_policy_sha char(64) := encode(extensions.digest(convert_to(v_policy,'UTF8'),'sha256'),'hex');
  v_rights_sha char(64);
  v_receipt char(64) := encode(extensions.digest(convert_to('content-safety-v2:'||v_content_sha||':CLEAN','UTF8'),'sha256'),'hex');
  v_artifact_canonical bytea;
  v_artifact_sha char(64);
  v_asset_rights_canonical bytea;
  v_source_use_canonical bytea;
  v_source_use_sha char(64);
  v_snapshot jsonb;
  v_capability_id uuid;
  v_capability_version bigint;
  v_capability_sha char(64);
  v_capability_set_sha char(64);
  v_execution_set_sha char(64);
  v_effective_at timestamptz;
  v_expires_at timestamptz;
  v_dimensions jsonb;
BEGIN
  v_snapshot := ops.research_rights_snapshot_v1('control-fixture-source',clock_timestamp());
  IF v_snapshot IS NULL THEN RAISE EXCEPTION 'control research rights snapshot missing'; END IF;
  v_capability_id := (v_snapshot->'primaryDecision'->>'decisionId')::uuid;
  v_capability_version := (v_snapshot->'primaryDecision'->>'decisionVersion')::bigint;
  v_capability_sha := (v_snapshot->'primaryDecision'->>'decisionSha256')::char(64);
  v_capability_set_sha := (v_snapshot->>'capabilityDecisionSetSha256')::char(64);
  v_execution_set_sha := (v_snapshot->>'executionReceiptSetSha256')::char(64);
  v_effective_at := (v_snapshot->>'effectiveAt')::timestamptz;
  v_expires_at := NULLIF(v_snapshot->>'expiresAt','')::timestamptz;
  v_dimensions := v_snapshot->'dimensions';
  v_artifact_canonical := ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion','research-artifact.v2','researchArtifactId',v_artifact_id,'assetId',v_asset_id,
    'assetRevision',1,'sourceFetchId',v_fetch_id,'artifactOrdinal',0,'fetchOutcome','STORED',
    'sourceAuthority','control-fixture-source','finalOrigin',v_locator,'httpStatus',200,
    'contentMediaType','text/plain','contentSizeBytes',octet_length(v_content),
    'contentSha256',v_content_sha,'responseHeadersSha256',encode(extensions.digest(ops.canonical_jsonb_v1('[]'::jsonb),'sha256'),'hex'),
    'contentSafetyState','CLEAN','contentSafetyReceiptSha256',v_receipt));
  v_artifact_sha := encode(extensions.digest(v_artifact_canonical,'sha256'),'hex');
  v_asset_rights_canonical := ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion','asset-rights-decision.v1','decisionId',v_rights_id,
    'assetId',v_asset_id,'assetSha256',v_content_sha,'assetRevision',1,
    'decisionVersion',1,'assetKind','RESEARCH_ARTIFACT','researchArtifactId',v_artifact_id,
    'decisionKind','GRANT','accessRight',v_dimensions->>'accessRight',
    'privateStorageRight',v_dimensions->>'privateStorageRight',
    'modelEgressRight',v_dimensions->>'modelEgressRight','modelUseRight',v_dimensions->>'modelUseRight',
    'derivativeCreationRight',v_dimensions->>'derivativeCreationRight','excerptRight',v_dimensions->>'excerptRight',
    'redistributionRight',v_dimensions->>'redistributionRight','commercialUseRight',v_dimensions->>'commercialUseRight',
    'publicDisplayRight',v_dimensions->>'publicDisplayRight','policyVersion',v_policy,
    'policySha256',v_policy_sha,'legalBasisCode','PUBLIC_RESEARCH','legalBasisReference','control-fixture-source',
    'jurisdiction','GLOBAL','attributionRequired',false,'effectiveAt',v_effective_at,
    'expiresAt',v_expires_at,'capabilityDecisionId',v_capability_id,
    'capabilityDecisionVersion',v_capability_version,'capabilityDecisionSha256',v_capability_sha,
    'capabilityDecisions',v_snapshot->'capabilityDecisions',
    'capabilityDecisionSetSha256',v_capability_set_sha,
    'executionReceiptSetSha256',v_execution_set_sha));
  v_rights_sha := encode(extensions.digest(v_asset_rights_canonical,'sha256'),'hex');
  v_source_use_canonical := ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion','source-use.v2','sourceUseId',v_source_use_id,'agentRunId',v_run_id,
    'providerTurnId',v_turn_id,'toolCallId',v_tool_id,'parentSourceUseId',NULL,'parentSourceUseSha256',NULL,
    'useKind','TOOL_QUERY','sourceKind','RESEARCH_ARTIFACT',
    'sourceIdentity',jsonb_build_object('kind','RESEARCH_ARTIFACT','researchArtifactId',v_artifact_id,'assetId',v_asset_id,'assetRevision',1,'artifactSha256',v_artifact_sha,'contentSha256',v_content_sha,'sourceFetchId',v_fetch_id),
    'locator',jsonb_build_object('kind','HTML_CSS_SELECTOR','value',v_locator,'locatorSha256',v_locator_sha),
    'selectedContentSha256',v_content_sha,'classification','PUBLIC',
    'rightsDecision',jsonb_build_object('decisionId',v_rights_id,'capabilityDecisionId',v_capability_id,
      'decisionVersion',1,'decisionSha256',v_rights_sha,'effectiveAt',v_effective_at,'expiresAt',v_expires_at,
      'capabilityDecisionSetSha256',v_capability_set_sha,
      'accessRight',v_dimensions->>'accessRight','privateStorageRight',v_dimensions->>'privateStorageRight',
      'modelEgressRight',v_dimensions->>'modelEgressRight','modelUseRight',v_dimensions->>'modelUseRight',
      'derivativeCreationRight',v_dimensions->>'derivativeCreationRight','excerptRight',v_dimensions->>'excerptRight',
      'redistributionRight',v_dimensions->>'redistributionRight','commercialUseRight',v_dimensions->>'commercialUseRight',
      'publicDisplayRight',v_dimensions->>'publicDisplayRight'),
    'providerReceiptId',NULL,'occurredAt',v_effective_at));
  v_source_use_sha := encode(extensions.digest(v_source_use_canonical,'sha256'),'hex');
  PERFORM ops.record_research_fetch_v1(
    p_agent_run_id => v_run_id, p_provider_turn_id => v_turn_id, p_tool_call_id => v_tool_id,
    p_call_id => 'promote-source-fetch', p_input_snapshot_sha256 => repeat('9',64),
    p_request_kind => 'FETCH_URL', p_source_id => 'control-fixture-source',
    p_external_locator => v_locator, p_source_url_redacted => v_locator,
    p_final_url_redacted => v_locator, p_http_status => 200, p_content_media_type => 'text/plain',
    p_request_sha256 => '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
    p_content => v_content, p_object_key => 'research/control-promotion-fixture.txt',
    p_policy_version => v_policy, p_result_sha256 => '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
    p_fetch_id => v_fetch_id, p_asset_id => v_asset_id, p_artifact_id => v_artifact_id,
    p_source_use_id => v_source_use_id, p_source_use_sha256 => v_source_use_sha,
    p_receipt_digest => v_receipt, p_safe_headers => '[]'::jsonb, p_redirect_chain => '[]'::jsonb);
END $$;

COMMIT;
