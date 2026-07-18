-- Immutable ingest-side graph used by the analysis runtime acceptance scripts.
-- Callers provide document_id, evidence_id and actor_id as psql variables.
INSERT INTO core.normalization_runs(
  id,source_document_id,parser_run_id,parsed_record_id,parser_version,input_payload_sha256,
  normalization_id,normalization_version,normalization_contract_sha256,implementation_sha256,
  producer_generation,state,job_id,job_fencing_token)
VALUES('46000000-0000-4000-8000-000000000001',:'document_id',
  '46000000-0000-4000-8000-000000000002','46000000-0000-4000-8000-000000000003','runtime-v1',repeat('a',64),
  'runtime-normalize','1',repeat('b',64),repeat('c',64),1,'RUNNING','46000000-0000-4000-8000-000000000004',1);
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
  payload_sha256,normalization_run_id,normalization_version,normalization_sha256,source_count,source_set_sha256,
  member_binding_canonical,member_digest)
VALUES('46000000-0000-4000-8000-00000000000b','46000000-0000-4000-8000-000000000007','AGENT_CASE',1,1,0,'CONTRACT',
  '46000000-0000-4000-8000-00000000000c',1,'contract-v1',repeat('7',64),'{"objectType":"CONTRACT"}',
  convert_to('{"objectType":"CONTRACT"}','UTF8'),repeat('8',64),'46000000-0000-4000-8000-000000000001','1',repeat('9',64),1,
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
