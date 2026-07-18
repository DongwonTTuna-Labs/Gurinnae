BEGIN;

INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES('11111111-1111-4111-8111-111111111111','control-integration','control@example.test','Control Integration','ACTIVE')
ON CONFLICT DO NOTHING;

INSERT INTO ops.sessions(id,user_id,session_token_hash,auth_time,step_up_at,expires_at,csrf_token_hash)
VALUES
 ('22222222-2222-4222-8222-222222222222','11111111-1111-4111-8111-111111111111',repeat('a',64),clock_timestamp(),clock_timestamp(),clock_timestamp()+interval '1 hour',repeat('b',64)),
 ('33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111',repeat('c',64),clock_timestamp(),clock_timestamp(),clock_timestamp()+interval '1 hour',repeat('d',64))
ON CONFLICT DO NOTHING;

INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES('75cccee2-bca8-53c5-90d4-0949f63d8e52','control-target','control-target@example.test','Control Target','ACTIVE')
ON CONFLICT DO NOTHING;

INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES('a2583e82-06ed-558f-86e7-8ed3b439637c','control-role-target','control-role-target@example.test','Control Role Target','ACTIVE')
ON CONFLICT DO NOTHING;

INSERT INTO ops.roles(id,code,name,description,risk_level)
VALUES('f627eed8-b162-59dd-bfd7-7ef7d65cd39b','CONTROL_FIXTURE_ROLE','Control Fixture Role','Control integration canonical role','HIGH')
ON CONFLICT DO NOTHING;

INSERT INTO raw.source_documents(
  id,source_id,external_id,retrieved_at,content_type,content_sha256,
  content_size_bytes,object_key,status,asset_id,asset_revision
) VALUES(
  '8af025c4-7ee9-59af-9e5b-8286302be41a','control-fixture-source',
  'control-relation-contract','2026-07-12T00:00:00Z','application/json',
  repeat('3',64),2,'control/relation-contract.json','PARSED','8af025c4-7ee9-59af-9e5b-8286302be41a',1
) ON CONFLICT DO NOTHING;

INSERT INTO core.agencies(id,canonical_name,agency_type,jurisdiction,identity_status)
VALUES('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Control relation agency','CENTRAL','KR','VERIFIED')
ON CONFLICT DO NOTHING;

INSERT INTO core.suppliers(id,canonical_name,business_status,identity_status)
VALUES('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Control relation supplier','ACTIVE','VERIFIED')
ON CONFLICT DO NOTHING;

INSERT INTO core.contracts(
  id,source_id,external_contract_id,contract_number,title,agency_id,supplier_id,
  status,currency,normalization_version,source_document_id,source_record_locator
) VALUES(
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc','control-fixture-source',
  'control-relation-contract','CONTROL-RELATION-1','Control relation contract',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'ACTIVE','KRW','v13','8af025c4-7ee9-59af-9e5b-8286302be41a','record:0'
) ON CONFLICT DO NOTHING;

INSERT INTO editorial.cases(id,public_slug,title,investigation_state,publication_state,summary,priority,version)
VALUES('148b09d5-aa28-5351-b471-9ef333a3e410','control-fixture-case','Control canonical case','INVESTIGATING','PUBLISHED_ANOMALY','Canonical integration case','HIGH',1)
ON CONFLICT DO NOTHING;

INSERT INTO editorial.review_snapshots(id,case_id,case_version,snapshot_sha256,snapshot_payload,automated_gate_results,created_by)
VALUES('04935ea9-f702-552c-aedc-425382a2d2b3','148b09d5-aa28-5351-b471-9ef333a3e410',1,repeat('1',64),'{}','{}','75cccee2-bca8-53c5-90d4-0949f63d8e52')
ON CONFLICT DO NOTHING;

UPDATE editorial.cases SET current_review_snapshot_id='04935ea9-f702-552c-aedc-425382a2d2b3'
WHERE id='148b09d5-aa28-5351-b471-9ef333a3e410';

INSERT INTO editorial.review_decisions(review_snapshot_id,reviewer_id,decision,reason,criteria,reviewer_independence,reauth_context_hash)
VALUES('04935ea9-f702-552c-aedc-425382a2d2b3','a2583e82-06ed-558f-86e7-8ed3b439637c','APPROVE','Historical independent approval fixture','{}','{"independent":true}',repeat('a',64))
ON CONFLICT DO NOTHING;

INSERT INTO editorial.publication_previews(case_id,review_snapshot_id,locale,preview_payload,preview_sha256,expires_at,created_by)
VALUES('148b09d5-aa28-5351-b471-9ef333a3e410','04935ea9-f702-552c-aedc-425382a2d2b3','fixture-history','{}','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',clock_timestamp()+interval '10 years','11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

INSERT INTO editorial.publication_revisions(id,case_id,revision,state,review_snapshot_id,public_payload,public_payload_sha256,preview_sha256,published_by)
VALUES('02568a6a-27f5-5ede-b5d0-21107e22a755','148b09d5-aa28-5351-b471-9ef333a3e410',1,'PUBLISHED_ANOMALY','04935ea9-f702-552c-aedc-425382a2d2b3','{}','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

INSERT INTO core.rule_versions(id,rule_id,version,name,description,configuration,code_digest,status,created_by,row_version)
VALUES('b821788c-164c-5da0-8571-74b7ef417538','control-fixture-rule','1.0.0','Control fixture rule','Canonical integration rule','{}',repeat('4',64),'DRAFT','11111111-1111-4111-8111-111111111111',1)
ON CONFLICT DO NOTHING;

INSERT INTO core.rule_versions(id,rule_id,version,name,description,configuration,code_digest,status,created_by,row_version)
VALUES
 ('994e5a60-8991-57e6-a22a-c537c278dea7','control-activate-rule','1.0.0','Activation fixture','Evaluated activation fixture','{}',repeat('4',64),'DRAFT','11111111-1111-4111-8111-111111111111',1),
 ('6da766cf-4b29-53a5-9338-efbb4a2fa8aa','control-rollback-rule','2.0.0','Rollback current fixture','Active rollback source','{}',repeat('4',64),'ACTIVE','11111111-1111-4111-8111-111111111111',1),
 ('b4e969fa-3f37-5fcf-a451-c6eeaaf86e15','control-rollback-rule','1.0.0','Rollback target fixture','Retired rollback target','{}',repeat('4',64),'RETIRED','11111111-1111-4111-8111-111111111111',1),
 ('dff0e5c9-4b75-56f4-a97b-130121906aae','control-schedule-rule','1.0.0','Schedule fixture','Evaluated schedule fixture','{}',repeat('4',64),'DRAFT','11111111-1111-4111-8111-111111111111',1),
 ('fad05304-6e3d-577c-a474-e19dc8a25ee5','control-shadow-rule','1.0.0','Shadow fixture','Shadow evaluation fixture','{}',repeat('4',64),'DRAFT','11111111-1111-4111-8111-111111111111',1)
ON CONFLICT DO NOTHING;

INSERT INTO core.rule_evaluations(id,rule_version_id,dataset_snapshot_id,evaluation_profile,status,result_digest,requested_by,reason,started_at,completed_at)
VALUES
 ('fa6ba286-7a60-5f7f-840a-3b962a7191fe','994e5a60-8991-57e6-a22a-c537c278dea7','3ca3cef4-cdbb-5fc5-a90f-b910c2046600','FULL','SUCCEEDED','47d692d098bb261e95d9894f40fe4e7280a872b3a04a5a9db5b12c1a6d5ff8d0','11111111-1111-4111-8111-111111111111','Activation evaluation fixture',clock_timestamp(),clock_timestamp()),
 ('f3077802-be58-5863-a1a5-c9ca25258943','dff0e5c9-4b75-56f4-a97b-130121906aae','b41a8538-e770-5de8-959c-f7c563955677','FULL','SUCCEEDED','053a0d960978e0cba3359dbd6b7ee03c5e06846f1e987ebdd382ef2558e1b31e','11111111-1111-4111-8111-111111111111','Schedule evaluation fixture',clock_timestamp(),clock_timestamp())
ON CONFLICT DO NOTHING;

INSERT INTO core.rule_runs(id,rule_version_id,run_key,input_snapshot_at,input_digest,started_at,completed_at,status)
VALUES('4b777e28-9532-5ad1-8c9b-78c8088538bd','b821788c-164c-5da0-8571-74b7ef417538','control-fixture-run',clock_timestamp(),repeat('5',64),clock_timestamp(),clock_timestamp(),'SUCCEEDED')
ON CONFLICT DO NOTHING;

INSERT INTO core.anomaly_signals(id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity,status,explanation,calculation,version)
VALUES('641fc905-1d30-5062-b0e6-9fbb468502c4','4b777e28-9532-5ad1-8c9b-78c8088538bd','b821788c-164c-5da0-8571-74b7ef417538','CONTROL_FIXTURE','CASE','148b09d5-aa28-5351-b471-9ef333a3e410','HIGH','NEW','{}','{}',1)
ON CONFLICT DO NOTHING;

INSERT INTO core.anomaly_signals(id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity,status,explanation,calculation,version)
VALUES('8d98ac36-3177-5f7b-bfbe-528be006ef51','4b777e28-9532-5ad1-8c9b-78c8088538bd','b821788c-164c-5da0-8571-74b7ef417538','CONTROL_RELATION','CONTRACT','cccccccc-cccc-4ccc-8ccc-cccccccccccc','HIGH','LINKED','{}','{}',1)
ON CONFLICT DO NOTHING;

INSERT INTO editorial.case_signals(case_id,signal_id,link_reason,linked_by)
VALUES('148b09d5-aa28-5351-b471-9ef333a3e410','8d98ac36-3177-5f7b-bfbe-528be006ef51','Publication relation regression','11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

INSERT INTO editorial.claims(id,case_id,claim_type,text,validation_status,version,created_by)
VALUES('e6b7009d-1cb1-5c31-ad2d-819ff78e73e4','148b09d5-aa28-5351-b471-9ef333a3e410','FACT','Control canonical claim','DRAFT',1,'11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

INSERT INTO editorial.evidence(id,case_id,evidence_type,title,source_locator,content_sha256,classification,verification_status,version,created_by)
VALUES('072ba181-0a97-51b1-bf1f-462e1b80981a','148b09d5-aa28-5351-b471-9ef333a3e410','DOCUMENT','Control canonical evidence','control-fixture',repeat('6',64),'PUBLIC','PENDING',1,'11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

INSERT INTO editorial.evidence(id,case_id,evidence_type,title,source_locator,content_sha256,
  classification,verification_status,verified_by,verified_at,version,created_by)
VALUES('7a2d7eba-184c-55b0-8955-86cbca587a6a','148b09d5-aa28-5351-b471-9ef333a3e410',
  'DOCUMENT','Verified agent scope evidence','control-agent-scope',repeat('7',64),'PUBLIC',
  'VERIFIED','11111111-1111-4111-8111-111111111111',clock_timestamp(),1,
  '11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

INSERT INTO editorial.hypotheses(id,case_id,statement,status,version,created_by)
VALUES('02e4e6b0-a40f-59d0-a07a-3f8537262700','148b09d5-aa28-5351-b471-9ef333a3e410','Control canonical hypothesis','OPEN',1,'11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

INSERT INTO editorial.corrections(id,case_id,source_revision,summary,reason,affected_claim_ids,status,version,created_by)
VALUES('6f1ff081-2d57-511c-a79a-5dba9893565c','148b09d5-aa28-5351-b471-9ef333a3e410',1,'Control canonical correction','Integration verification','[]','REVIEW',1,'11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

INSERT INTO editorial.corrections(id,case_id,source_revision,summary,reason,affected_claim_ids,status,version,created_by)
VALUES
 ('9d27f882-144a-54c2-b088-400f75d60359','148b09d5-aa28-5351-b471-9ef333a3e410',1,'Resolve correction','Integration verification','[]','REVIEW',1,'11111111-1111-4111-8111-111111111111'),
 ('435d1f85-8815-5e2a-89ea-7b5dfbbeed50','148b09d5-aa28-5351-b471-9ef333a3e410',1,'Draft correction','Integration verification','[]','DRAFT',1,'11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

INSERT INTO editorial.response_requests(id,case_id,party_type,party_name,recipient_email_hash,recipient_email_encrypted,questions,requested_publication_scope,due_at,status,version,created_by)
VALUES('a3493bbe-83cc-5a9b-b251-de7cc46c62d8','148b09d5-aa28-5351-b471-9ef333a3e410','OTHER','Control fixture party',repeat('7',64),decode('00','hex'),'[]','{}',clock_timestamp()+interval '7 days','DRAFT',1,'11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

INSERT INTO editorial.responses(id,case_id,response_request_id,party_name,submitted_at,full_text_encrypted,public_excerpt,publication_consent,editorial_status,version)
VALUES('6267870b-97d8-51c0-aa38-030abefcc483','148b09d5-aa28-5351-b471-9ef333a3e410','a3493bbe-83cc-5a9b-b251-de7cc46c62d8','Control fixture party',clock_timestamp(),decode('00','hex'),'Control public excerpt','{}','PENDING',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.source_registry(source_id,display_name,connector_type,owner_team,enabled,schedule_cron,credential_reference,base_url,legal_status,configuration,version)
VALUES('control-fixture-source','Control Fixture Source','HTTP','CONTROL',true,'0 * * * *','secret/control-fixture','https://example.test','APPROVED','{}',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.source_registry(source_id,display_name,connector_type,owner_team,enabled,schedule_cron,credential_reference,base_url,legal_status,configuration,version)
VALUES
 ('control-pause-source','Control Pause Source','HTTP','CONTROL',true,'0 * * * *','secret/control-pause','https://example.test','APPROVED','{}',1),
 ('control-backfill-source','Control Backfill Source','HTTP','CONTROL',true,'0 * * * *','secret/control-backfill','https://example.test','APPROVED','{}',1),
 ('control-run-source','Control Run Source','HTTP','CONTROL',true,'0 * * * *','secret/control-run','https://example.test','APPROVED','{}',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.source_runs(id,source_id,mode,status,version)
VALUES
 ('d40a0250-8802-5a81-a689-af8af264003d','control-fixture-source','INCREMENTAL','FAILED',1),
 ('fcd024f0-de94-5f6d-88b8-25016c38094f','control-fixture-source','BACKFILL','RUNNING',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.source_runs(id,source_id,mode,status,records_seen,records_changed,started_at,completed_at,report_object_key,version)
VALUES('9ac757c2-7fd8-5dde-a753-3c967e561fe3','control-fixture-source','RECONCILE','SUCCEEDED',100,4,clock_timestamp()-interval '1 minute',clock_timestamp(),'reports/control-source-run.json',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.source_incidents(source_id,severity,incident_type,summary,impact,status,version)
VALUES('control-fixture-source','MAJOR','CONTROL_FIXTURE','Control canonical incident','{}','OPEN',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.provider_configs(id,provider_type,name,enabled,routing_policy,secret_reference,data_retention_policy,version)
VALUES('59e6fe3c-6803-5f19-8ee2-1595abc421a8','CONTROL_FIXTURE','Control Fixture Provider',true,'{}','secret/control-provider','NO_RETENTION',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.provider_configs(id,provider_type,name,enabled,routing_policy,secret_reference,data_retention_policy,version)
VALUES('7e7875f5-52dd-5375-9e3c-c35521d2f220','CONTROL_TEST','Control Connection Test Provider',true,'{}','secret/control-provider-test','NO_RETENTION',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.schema_drifts(id,source_id,detected_at,fingerprint_after,status,impact,version)
VALUES('e2f1dd8f-abf7-5559-89f7-d216d18205ad','control-fixture-source',clock_timestamp(),repeat('8',64),'OPEN','LOW',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.schema_drifts(id,source_id,detected_at,fingerprint_after,status,impact,version)
VALUES
 ('b085a8f4-6a10-508b-b5af-932cc2e4302a','control-fixture-source',clock_timestamp(),repeat('a',64),'OPEN','LOW',1),
 ('a8dd0f25-7ce3-5ca9-84a4-317e1e0ef474','control-fixture-source',clock_timestamp(),repeat('b',64),'OPEN','LOW',1),
 ('7dc6b03d-d98b-53a8-828b-e0db50d7cfde','control-fixture-source',clock_timestamp(),repeat('c',64),'OPEN','LOW',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.schema_mappings(schema_drift_id,mapping_version,mapping_digest,field_mappings,status)
VALUES
 ('b085a8f4-6a10-508b-b5af-932cc2e4302a',1,'ec5ff780a16c3555796ea902ba229f8702b16b7152d186fb12466c673f2b7684','[{"upstreamPath":"approveSchemaMapping-upstreamPath","canonicalField":"approveSchemaMapping-canonicalField","transform":"approveSchemaMapping-transform","required":true}]','DRAFT'),
 ('a8dd0f25-7ce3-5ca9-84a4-317e1e0ef474',1,'9cd29fd04064fd955a0c98afc80f02676d6072c89e0fa93c6ca4a78a2bb75994','[{"upstreamPath":"legacy.supplier","canonicalField":"supplierName","transform":"trim","required":true}]','DRAFT'),
 ('7dc6b03d-d98b-53a8-828b-e0db50d7cfde',1,repeat('f',64),'[{"upstreamPath":"negative.fixture","canonicalField":"supplierName","transform":"trim","required":true}]','DRAFT')
ON CONFLICT DO NOTHING;

INSERT INTO ops.jobs(id,job_type,queue,status,payload,version)
VALUES('4db87cda-721c-551a-be08-3825a88c949d','CONTROL_FIXTURE','control-fixture-queue','FAILED','{}',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.jobs(id,job_type,queue,status,payload,version)
VALUES('14c72bb6-efea-52a0-8913-1bee07d0a87d','CONTROL_BULK_FIXTURE','control-fixture-queue','FAILED','{}',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.jobs(id,job_type,queue,status,payload,version)
VALUES
 ('3bc978f3-d0e0-5558-a790-978d83c3cd38','CONTROL_CANCEL_FIXTURE','control-fixture-queue','QUEUED','{}',1),
 ('58e7aa4e-c694-5a6b-bdba-98ce4d572f48','CONTROL_QUARANTINE_FIXTURE','control-fixture-queue','FAILED','{}',1),
 ('c200238e-882e-5485-8fc9-a4283a112ccc','CONTROL_RETRY_FIXTURE','control-fixture-queue','FAILED','{}',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.queue_controls(queue_name,state,version)
VALUES('control-fixture-queue','RUNNING',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.budget_limits(scope,daily_limit,monthly_limit,currency,version,updated_by)
VALUES('control-fixture-budget',1000,10000,'KRW',1,'11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

INSERT INTO ops.saved_views(id,user_id,name,surface,query,version)
VALUES('b6f53b1e-6d09-541a-a87a-1c7aee5bb3b0','11111111-1111-4111-8111-111111111111','Control Fixture View','CASES','{}',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.saved_views(id,user_id,name,surface,query,version)
VALUES('a7b751a7-3606-5259-92b7-92347a03d7b7','a2583e82-06ed-558f-86e7-8ed3b439637c','Foreign Fixture View','CASES','{}',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.saved_views(id,user_id,name,surface,query,version)
VALUES
 ('b6f0d74e-9b29-5e44-9738-761e6edfbe6b','11111111-1111-4111-8111-111111111111','Path Binding View A','CASES','{}',1),
 ('eac8ecc9-9dfe-5160-963c-f8ac1af1f4be','11111111-1111-4111-8111-111111111111','Path Binding View B','CASES','{}',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.notifications(id,user_id,notification_type,title,body,version)
VALUES('bcd5bb90-fbee-5d59-bcec-7a08c29c31c6','11111111-1111-4111-8111-111111111111','CONTROL_FIXTURE','Control fixture notification','Canonical integration notification',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.tasks(id,task_type,object_type,object_id,title,status,priority,version)
VALUES('cf6b0dd7-1267-5de0-a363-c8e3af950b1d','CONTROL_FIXTURE','CASE','148b09d5-aa28-5351-b471-9ef333a3e410','Control fixture task','OPEN','NORMAL',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.agent_runs(id,case_id,agent_type,objective,evidence_scope_ids,provider_policy,status,input_snapshot_hash,max_cost,version,created_by)
VALUES('8eee21b7-75c0-53c9-b079-d897a2c3c711','148b09d5-aa28-5351-b471-9ef333a3e410','CONTROL_FIXTURE','Canonical integration agent run','[]','LOCAL_ONLY','SUCCEEDED',repeat('9',64),1,1,'11111111-1111-4111-8111-111111111111')
ON CONFLICT DO NOTHING;

INSERT INTO ops.agent_suggestions(id,agent_run_id,case_id,suggestion_type,payload,evidence_ids,citation_checks,status,version)
VALUES('08af47bb-5a21-5128-b016-8d6a550b099b','8eee21b7-75c0-53c9-b079-d897a2c3c711','148b09d5-aa28-5351-b471-9ef333a3e410','CONTROL_FIXTURE','{}','[]','[]','PENDING',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.audit_exports(id,requested_by,from_at,to_at,format,scope,reason,watermark_policy,status,expires_at,started_at,completed_at,row_count,content_sha256,object_key)
VALUES('c26f54c7-022f-54aa-80d3-dbc9cf339881','11111111-1111-4111-8111-111111111111',clock_timestamp()-interval '1 day',clock_timestamp(),'JSONL','GLOBAL','Canonical audit export query fixture','ACTOR_AND_TIME','READY',clock_timestamp()+interval '1 day',clock_timestamp(),clock_timestamp(),1,repeat('c',64),'audit-exports/control-query.jsonl')
ON CONFLICT DO NOTHING;

INSERT INTO ops.agent_suggestions(id,agent_run_id,case_id,suggestion_type,payload,evidence_ids,citation_checks,status,version)
VALUES
 ('30ddda7c-3ee4-52a6-af23-f09f1f8cd9d4','8eee21b7-75c0-53c9-b079-d897a2c3c711','148b09d5-aa28-5351-b471-9ef333a3e410','CONTROL_ACCEPT','{}','[]','[]','PENDING',1),
 ('ae58ffd5-e2a2-5bf2-8a4f-e11facaee532','8eee21b7-75c0-53c9-b079-d897a2c3c711','148b09d5-aa28-5351-b471-9ef333a3e410','CONTROL_REJECT','{}','[]','[]','PENDING',1)
ON CONFLICT DO NOTHING;

INSERT INTO ops.kill_switches(id,code,scope,state,version)
VALUES('2cd3a1db-f58f-501c-a08c-02b3760c4dbc','CONTROL_FIXTURE','{}','INACTIVE',1)
ON CONFLICT DO NOTHING;

COMMIT;
