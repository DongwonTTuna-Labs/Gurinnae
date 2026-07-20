-- Complete upstream lineage for the control-flow promotion witness.
-- This is intentionally a real, clean FETCH_URL artifact: the promotion
-- owner must re-bind the run/turn/tool/fetch/artifact tuple, current GRANT,
-- parser segment and source-use root before it writes evidence.
BEGIN;

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
  v_rights_id uuid := substring(encode(extensions.digest(convert_to('source-rights:'||v_artifact_id::text||':'||v_content_sha,'UTF8'),'sha256'),'hex') FROM 1 FOR 32)::uuid;
  v_locator text := 'https://example.test/gurinnae/control-promotion-fixture';
  v_locator_sha char(64) := encode(extensions.digest(convert_to(v_locator,'UTF8'),'sha256'),'hex');
  v_now timestamptz := timestamptz '2026-01-01 00:00:00+00' + (('x'||substring(v_content_sha FROM 1 FOR 8))::bit(32)::bigint % 31536000) * interval '1 second';
  v_policy text := 'research-policy-v1';
  v_policy_sha char(64) := encode(extensions.digest(convert_to(v_policy,'UTF8'),'sha256'),'hex');
  v_rights_sha char(64) := encode(extensions.digest(convert_to(v_rights_id::text||':'||v_content_sha,'UTF8'),'sha256'),'hex');
  v_receipt char(64) := encode(extensions.digest(convert_to('content-safety-v2:'||v_content_sha||':CLEAN','UTF8'),'sha256'),'hex');
  v_artifact_canonical bytea;
  v_artifact_sha char(64);
  v_source_use_canonical bytea;
  v_source_use_sha char(64);
BEGIN
  v_artifact_canonical := ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion','research-artifact.v2','researchArtifactId',v_artifact_id,'assetId',v_asset_id,
    'assetRevision',1,'sourceFetchId',v_fetch_id,'artifactOrdinal',0,'fetchOutcome','STORED',
    'sourceAuthority','control-fixture-source','finalOrigin',v_locator,'httpStatus',200,
    'contentMediaType','text/plain','contentSizeBytes',octet_length(v_content),
    'contentSha256',v_content_sha,'responseHeadersSha256',encode(extensions.digest(ops.canonical_jsonb_v1('[]'::jsonb),'sha256'),'hex'),
    'contentSafetyState','CLEAN','contentSafetyReceiptSha256',v_receipt));
  v_artifact_sha := encode(extensions.digest(v_artifact_canonical,'sha256'),'hex');
  v_source_use_canonical := ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion','source-use.v2','sourceUseId',v_source_use_id,'agentRunId',v_run_id,
    'providerTurnId',v_turn_id,'toolCallId',v_tool_id,'parentSourceUseId',NULL,'parentSourceUseSha256',NULL,
    'useKind','TOOL_QUERY','sourceKind','RESEARCH_ARTIFACT',
    'sourceIdentity',jsonb_build_object('kind','RESEARCH_ARTIFACT','researchArtifactId',v_artifact_id,'assetId',v_asset_id,'assetRevision',1,'artifactSha256',v_artifact_sha,'contentSha256',v_content_sha,'sourceFetchId',v_fetch_id),
    'locator',jsonb_build_object('kind','HTML_CSS_SELECTOR','value',v_locator,'locatorSha256',v_locator_sha),
    'selectedContentSha256',v_content_sha,'classification','PUBLIC',
    'rightsDecision',jsonb_build_object('decisionId',v_rights_id,'decisionVersion',1,'decisionSha256',v_rights_sha,'effectiveAt',v_now,'expiresAt',NULL,
      'accessRight','ALLOW','privateStorageRight','ALLOW','modelEgressRight','ALLOW','modelUseRight','ALLOW','derivativeCreationRight','ALLOW','excerptRight','ALLOW','redistributionRight','ALLOW','commercialUseRight','ALLOW','publicDisplayRight','ALLOW'),
    'providerReceiptId',NULL,'occurredAt',v_now));
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
