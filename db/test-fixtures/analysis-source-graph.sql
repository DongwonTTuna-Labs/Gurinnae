-- Immutable ingest-side graph used by the analysis runtime acceptance scripts.
-- Callers provide document_id, evidence_id and actor_id as psql variables.
INSERT INTO core.parser_versions(
  parser_name,version,supported_media_types,implementation_digest,sandbox_profile,status)
VALUES(
  'json','runtime-v1','["application/json"]'::jsonb,
  encode(extensions.digest(convert_to(
    'analysis-source-graph-parser-implementation-v1','UTF8'),'sha256'),'hex'),
  'test-fixture-only-no-network-v1','ACTIVE')
ON CONFLICT (parser_name,version) DO NOTHING;
INSERT INTO ops.jobs(
  id,job_type,queue,status,payload,fencing_token,attempt_count,max_attempts,
  completed_at)
VALUES(
  '46000000-0000-4000-8000-000000000008','DATASET_SNAPSHOT_BUILD',
  'analysis-worker','SUCCEEDED',jsonb_build_object(
    'fixtureAuthority','TEST_FIXTURE_ONLY',
    'datasetSnapshotId','46000000-0000-4000-8000-000000000007'),
  1,1,1,'2026-07-12T00:00:02Z')
ON CONFLICT (id) DO NOTHING;
INSERT INTO ops.audit_events(
  id,occurred_at,actor_type,actor_id,action,object_type,object_id,outcome,
  request_id,details,event_hash)
SELECT event.id,event.occurred_at,'SYSTEM','analysis-source-graph-fixture',
  event.action,'DATASET_SNAPSHOT','46000000-0000-4000-8000-000000000007',
  'SUCCESS',event.request_id,event.details,
  encode(extensions.digest(ops.canonical_jsonb_v1(jsonb_build_object(
    'id',event.id,'occurredAt',event.occurred_at,'actorType','SYSTEM',
    'actorId','analysis-source-graph-fixture','action',event.action,
    'objectType','DATASET_SNAPSHOT',
    'objectId','46000000-0000-4000-8000-000000000007',
    'outcome','SUCCESS','requestId',event.request_id,
    'details',event.details)),'sha256'),'hex')
FROM (VALUES
  ('46000000-0000-4000-8000-000000000009'::uuid,
   '2026-07-12T00:00:00Z'::timestamptz,
   'DATASET_SNAPSHOT_BUILD_STARTED',
   '46000000-0000-4000-8000-000000000012'::uuid,
   jsonb_build_object(
     'fixtureAuthority','TEST_FIXTURE_ONLY',
     'producerJobId','46000000-0000-4000-8000-000000000008')),
  ('46000000-0000-4000-8000-00000000000a'::uuid,
   '2026-07-12T00:00:02Z'::timestamptz,
   'DATASET_SNAPSHOT_READY',
   '46000000-0000-4000-8000-000000000013'::uuid,
   jsonb_build_object(
     'fixtureAuthority','TEST_FIXTURE_ONLY',
     'producerJobId','46000000-0000-4000-8000-000000000008'))
) AS event(id,occurred_at,action,request_id,details)
ON CONFLICT (id) DO NOTHING;
INSERT INTO core.parser_runs(
  id,source_document_id,parser_name,parser_version,status,output_record_count,
  output_digest,input_content_sha256,extraction_schema_version,
  implementation_sha256,extraction_receipt_sha256,started_at,completed_at)
SELECT
  '46000000-0000-4000-8000-000000000002',document.id,'json','runtime-v1',
  'SUCCEEDED',1,
  encode(extensions.digest(ops.canonical_jsonb_v1(jsonb_build_object(
    'fixtureAuthority','TEST_FIXTURE_ONLY','recordType','CONTRACT',
    'sourceDocumentId',document.id)),'sha256'),'hex'),
  document.content_sha256,'analysis-source-graph-extraction.v1',
  encode(extensions.digest(convert_to(
    'analysis-source-graph-parser-implementation-v1','UTF8'),'sha256'),'hex'),
  encode(extensions.digest(ops.canonical_jsonb_v1(jsonb_build_object(
    'fixtureAuthority','TEST_FIXTURE_ONLY',
    'parserRunId','46000000-0000-4000-8000-000000000002',
    'sourceDocumentId',document.id,
    'outputDigest',encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'fixtureAuthority','TEST_FIXTURE_ONLY','recordType','CONTRACT',
        'sourceDocumentId',document.id)),'sha256'),'hex'))),'sha256'),'hex'),
  '2026-07-12T00:00:00Z','2026-07-12T00:00:01Z'
FROM raw.source_documents document WHERE document.id=:'document_id'
ON CONFLICT (id) DO NOTHING;
INSERT INTO raw.parsed_records(
  id,source_document_id,record_type,record_index,parser_version,payload,
  payload_sha256,parser_run_id)
SELECT
  '46000000-0000-4000-8000-000000000003',:'document_id','CONTRACT',0,
  'runtime-v1',payload.value,
  encode(extensions.digest(ops.canonical_jsonb_v1(payload.value),'sha256'),'hex'),
  '46000000-0000-4000-8000-000000000002'
FROM (SELECT jsonb_build_object(
  'fixtureAuthority','TEST_FIXTURE_ONLY','recordType','CONTRACT',
  'sourceDocumentId',:'document_id') AS value) payload
ON CONFLICT (id) DO NOTHING;
INSERT INTO raw.evidence_segments(
  id,source_document_id,source_asset_id,source_asset_revision,source_content_sha256,parser_run_id,
  parser_name,parser_version,segment_ordinal,locator_kind,locator_value,locator_digest,raw_value_sha256,
  selected_content_sha256,selected_content_object_key,selected_content_locator,selected_content_media_type,
  transformation_version,classification,source_authority,retrieved_at,segment_digest)
VALUES(:'evidence_id',:'document_id',:'document_id',1,repeat('a',64),'46000000-0000-4000-8000-000000000002',
  'json','runtime-v1',0,'TEXT_RANGE','page:7',repeat('1',64),repeat('2',64),repeat('3',64),
  'raw/analysis-document.json','page:7','application/json','runtime-v1','INTERNAL','analysis-runtime',
  '2026-07-12T00:00:00Z',repeat('4',64));
INSERT INTO raw.asset_rights_decisions(
  id,asset_id,asset_sha256,asset_revision,decision_version,asset_kind,source_document_id,decision_kind,
  access_right,private_storage_right,model_egress_right,model_use_right,derivative_creation_right,
  excerpt_right,redistribution_right,commercial_use_right,public_display_right,dimensions_sha256,
  legal_basis_code,legal_basis_reference,legal_basis_sha256,license_evidence_digests,license_evidence_set_sha256,
  jurisdiction,attribution_required,attribution_sha256,policy_version,policy_sha256,approval_sha256,execution_sha256,
  evidence_receipt_id,evidence_receipt_sha256,reviewer_user_id,effective_at,decision_sha256)
VALUES('46000000-0000-4000-8000-000000000005',:'document_id',repeat('a',64),1,1,'SOURCE_DOCUMENT',:'document_id','GRANT',
  'ALLOW','ALLOW','ALLOW','ALLOW','ALLOW','ALLOW','ALLOW','ALLOW','ALLOW',repeat('5',64),
  'RUNTIME','runtime fixture',repeat('6',64),ARRAY[repeat('0',64)]::text[],repeat('7',64),'KR',false,repeat('8',64),
  'runtime-rights-v1',repeat('9',64),repeat('a',64),repeat('b',64),'46000000-0000-4000-8000-000000000006',
  repeat('c',64),:'actor_id','2026-07-12T00:00:00Z',repeat('d',64));
INSERT INTO core.dataset_snapshots(
  id,snapshot_kind,producer_component,producer_job_id,producer_key,producer_digest,producer_generation,
  state,schema_version,selection_spec,selection_canonical,selection_sha256,source_watermarks,
  source_watermarks_canonical,source_watermark_sha256,normalization_versions,normalization_versions_canonical,
  normalization_set_sha256,member_count,member_set_sha256,snapshot_manifest,snapshot_manifest_canonical,
  snapshot_sha256,build_request_sha256,build_started_audit_event_id,terminal_receipt_sha256,terminal_audit_event_id,
  version,ready_at)
VALUES('46000000-0000-4000-8000-000000000007','AGENT_CASE','snapshot-producer','46000000-0000-4000-8000-000000000008',
  'analysis-runtime-case',repeat('e',64),1,'READY','agent-case-v1','{}','{}',repeat('f',64),'{}','{}',repeat('1',64),
  '{}','{}',repeat('2',64),2,repeat('3',64),'{"memberCount":2}','{"memberCount":2}',repeat('4',64),repeat('5',64),
  '46000000-0000-4000-8000-000000000009',repeat('6',64),'46000000-0000-4000-8000-00000000000a',2,'2026-07-12T00:00:00Z');
INSERT INTO core.dataset_snapshot_members(
  id,dataset_snapshot_id,snapshot_kind,producer_generation,snapshot_contract_version,member_ordinal,object_type,
  object_id,object_version,object_schema_version,object_content_sha256,canonical_payload,canonical_payload_bytes,
  payload_sha256,source_count,source_set_sha256,member_binding_canonical,member_digest)
VALUES('46000000-0000-4000-8000-00000000000b','46000000-0000-4000-8000-000000000007','AGENT_CASE',1,1,0,'CONTRACT',
  '46000000-0000-4000-8000-00000000000c',1,'contract-v1',repeat('7',64),'{"objectType":"CONTRACT"}',
  convert_to('{"objectType":"CONTRACT"}','UTF8'),repeat('8',64),1,
  repeat('a',64),convert_to('{"memberOrdinal":0}','UTF8'),repeat('b',64));
INSERT INTO core.dataset_snapshot_members(
  id,dataset_snapshot_id,snapshot_kind,producer_generation,snapshot_contract_version,member_ordinal,object_type,
  object_id,object_version,object_schema_version,object_content_sha256,canonical_payload,canonical_payload_bytes,
  payload_sha256,evidence_segment_id,source_count,source_set_sha256,member_binding_canonical,member_digest)
VALUES('46000000-0000-4000-8000-00000000000d','46000000-0000-4000-8000-000000000007','AGENT_CASE',1,1,1,'EVIDENCE_SEGMENT',
  :'evidence_id',1,'evidence-segment-v1',repeat('3',64),'{"objectType":"EVIDENCE_SEGMENT"}',
  convert_to('{"objectType":"EVIDENCE_SEGMENT"}','UTF8'),repeat('c',64),:'evidence_id',1,repeat('d',64),
  convert_to('{"memberOrdinal":1}','UTF8'),repeat('e',64));
INSERT INTO core.dataset_snapshot_member_sources(
  id,dataset_snapshot_id,snapshot_member_id,member_ordinal,snapshot_member_digest,source_ordinal,lineage_kind,
  source_kind,source_document_id,source_asset_id,source_asset_revision,source_content_sha256,source_digest)
VALUES('46000000-0000-4000-8000-00000000000f','46000000-0000-4000-8000-000000000007','46000000-0000-4000-8000-00000000000b',0,repeat('b',64),0,'DIRECT_SOURCE','SOURCE_DOCUMENT',
  :'document_id',:'document_id',1,repeat('a',64),repeat('1',64));
INSERT INTO core.dataset_snapshot_member_sources(
  id,dataset_snapshot_id,snapshot_member_id,member_ordinal,snapshot_member_digest,source_ordinal,lineage_kind,
  source_kind,source_document_id,source_asset_id,source_asset_revision,source_content_sha256,parser_run_id,evidence_segment_id,locator_digest,source_digest)
VALUES('46000000-0000-4000-8000-000000000010','46000000-0000-4000-8000-000000000007','46000000-0000-4000-8000-00000000000d',1,repeat('e',64),0,'EVIDENCE_SEGMENT','SOURCE_DOCUMENT',
  :'document_id',:'document_id',1,repeat('a',64),'46000000-0000-4000-8000-000000000002',:'evidence_id',repeat('1',64),repeat('2',64));
