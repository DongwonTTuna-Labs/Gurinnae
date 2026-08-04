DO $$
DECLARE
  actual bigint;
BEGIN
  SELECT version INTO actual FROM editorial.cases WHERE id='148b09d5-aa28-5351-b471-9ef333a3e410';
  IF actual <> 15 THEN RAISE EXCEPTION 'case canonical version %, expected 15', actual; END IF;
  SELECT version INTO actual FROM core.anomaly_signals WHERE id='641fc905-1d30-5062-b0e6-9fbb468502c4';
  IF actual <> 5 THEN RAISE EXCEPTION 'signal canonical version %, expected 5', actual; END IF;
  SELECT count(*) INTO actual FROM ops.signal_triages
   WHERE signal_id='641fc905-1d30-5062-b0e6-9fbb468502c4'
     AND result='PROMOTE_TO_CASE' AND prior_version >= 1
     AND resulting_version = prior_version + 1
     AND reason_digest ~ '^[0-9a-f]{64}$'
     AND receipt_digest ~ '^[0-9a-f]{64}$';
  IF actual < 1 THEN RAISE EXCEPTION 'typed signal triage receipts %, expected at least 1', actual; END IF;
  SELECT row_version INTO actual FROM core.rule_versions WHERE id='b821788c-164c-5da0-8571-74b7ef417538';
  IF actual <> 1 THEN RAISE EXCEPTION 'evaluation rule canonical version %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM core.rule_versions
   WHERE (id='994e5a60-8991-57e6-a22a-c537c278dea7' AND row_version=2 AND status='ACTIVE')
      OR (id='6da766cf-4b29-53a5-9338-efbb4a2fa8aa' AND row_version=2 AND status='ROLLED_BACK')
      OR (id='b4e969fa-3f37-5fcf-a451-c6eeaaf86e15' AND row_version=1 AND status='ACTIVE')
      OR (id='dff0e5c9-4b75-56f4-a97b-130121906aae' AND row_version=2 AND status='SCHEDULED')
      OR (id='fad05304-6e3d-577c-a474-e19dc8a25ee5' AND row_version=2 AND status='SHADOW');
  IF actual <> 5 THEN RAISE EXCEPTION 'rule lifecycle canonical rows %, expected 5', actual; END IF;
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE job_type='RULE_ACTIVATION' AND queue='scheduler' AND status='QUEUED'
     AND payload->>'ruleVersionId'='dff0e5c9-4b75-56f4-a97b-130121906aae'
     AND payload ? 'actorId' AND payload ? 'requestId'
     AND run_after=(SELECT effective_at FROM core.rule_versions
                    WHERE id='dff0e5c9-4b75-56f4-a97b-130121906aae');
  IF actual <> 1 THEN RAISE EXCEPTION 'scheduled activation jobs %, expected 1', actual; END IF;
  SELECT version INTO actual FROM editorial.corrections WHERE id='6f1ff081-2d57-511c-a79a-5dba9893565c';
  IF actual <> 3 THEN RAISE EXCEPTION 'triage correction canonical version %, expected 3', actual; END IF;
  SELECT version INTO actual FROM editorial.corrections WHERE id='9d27f882-144a-54c2-b088-400f75d60359';
  IF actual <> 2 THEN RAISE EXCEPTION 'resolved correction canonical version %, expected 2', actual; END IF;
  SELECT version INTO actual FROM editorial.corrections WHERE id='435d1f85-8815-5e2a-89ea-7b5dfbbeed50';
  IF actual <> 2 THEN RAISE EXCEPTION 'draft correction canonical version %, expected 2', actual; END IF;
  SELECT version INTO actual FROM editorial.evidence WHERE id='072ba181-0a97-51b1-bf1f-462e1b80981a';
  IF actual <> 5 THEN RAISE EXCEPTION 'evidence canonical version %, expected 5', actual; END IF;
  SELECT version INTO actual FROM ops.jobs WHERE id='3bc978f3-d0e0-5558-a790-978d83c3cd38';
  IF actual <> 2 THEN RAISE EXCEPTION 'cancel job canonical version %, expected 2', actual; END IF;
  SELECT version INTO actual FROM ops.jobs WHERE id='58e7aa4e-c694-5a6b-bdba-98ce4d572f48';
  IF actual <> 2 THEN RAISE EXCEPTION 'quarantine job canonical version %, expected 2', actual; END IF;
  SELECT version INTO actual FROM ops.jobs WHERE id='c200238e-882e-5485-8fc9-a4283a112ccc';
  IF actual <> 2 THEN RAISE EXCEPTION 'retry job canonical version %, expected 2', actual; END IF;
  SELECT version INTO actual FROM ops.kill_switches WHERE id='2cd3a1db-f58f-501c-a08c-02b3760c4dbc';
  IF actual <> 4 THEN RAISE EXCEPTION 'kill switch canonical version %, expected 4', actual; END IF;
  SELECT version INTO actual FROM ops.users WHERE id='75cccee2-bca8-53c5-90d4-0949f63d8e52';
  IF actual <> 2 THEN RAISE EXCEPTION 'disabled user canonical version %, expected 2', actual; END IF;
  SELECT version INTO actual FROM ops.users WHERE id='a2583e82-06ed-558f-86e7-8ed3b439637c';
  IF actual <> 3 THEN RAISE EXCEPTION 'role target user canonical version %, expected 3', actual; END IF;
  SELECT version INTO actual FROM ops.roles WHERE id='f627eed8-b162-59dd-bfd7-7ef7d65cd39b';
  IF actual <> 2 THEN RAISE EXCEPTION 'role canonical version %, expected 2', actual; END IF;
  SELECT count(*) INTO actual FROM ops.saved_views WHERE id='b6f53b1e-6d09-541a-a87a-1c7aee5bb3b0';
  IF actual <> 0 THEN RAISE EXCEPTION 'deleted saved view rows %, expected 0', actual; END IF;
  SELECT version INTO actual FROM ops.saved_views WHERE id='b6f0d74e-9b29-5e44-9738-761e6edfbe6b';
  IF actual <> 2 THEN RAISE EXCEPTION 'path-bound saved view A version %, expected 2', actual; END IF;
  SELECT version INTO actual FROM ops.saved_views WHERE id='eac8ecc9-9dfe-5160-963c-f8ac1af1f4be';
  IF actual <> 1 THEN RAISE EXCEPTION 'path-bound saved view B version %, expected 1', actual; END IF;
  IF (SELECT publication_state FROM editorial.cases WHERE id='148b09d5-aa28-5351-b471-9ef333a3e410') <> 'PUBLISHED_ANOMALY' THEN
    RAISE EXCEPTION 'first publication did not advance the case publication state';
  END IF;
  IF (SELECT state FROM editorial.publication_revisions
      WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410' ORDER BY revision DESC LIMIT 1) <> 'PUBLISHED_ANOMALY' THEN
    RAISE EXCEPTION 'first publication revision did not persist the published state';
  END IF;

  IF (SELECT state FROM ops.kill_switches WHERE id='2cd3a1db-f58f-501c-a08c-02b3760c4dbc') <> 'INACTIVE' THEN
    RAISE EXCEPTION 'kill switch did not complete activation-extension-deactivation lifecycle';
  END IF;
  IF (SELECT expires_at FROM ops.kill_switches WHERE id='2cd3a1db-f58f-501c-a08c-02b3760c4dbc') <>
     '2027-07-12T21:00:00Z'::timestamptz THEN
    RAISE EXCEPTION 'kill switch extension did not add the bounded one-hour window';
  END IF;
  IF (SELECT status FROM ops.jobs WHERE id='3bc978f3-d0e0-5558-a790-978d83c3cd38') <> 'CANCELLED'
     OR (SELECT status FROM ops.jobs WHERE id='58e7aa4e-c694-5a6b-bdba-98ce4d572f48') <> 'QUARANTINED'
     OR (SELECT status FROM ops.jobs WHERE id='c200238e-882e-5485-8fc9-a4283a112ccc') <> 'QUEUED' THEN
    RAISE EXCEPTION 'job lifecycle commands did not reach their canonical states';
  END IF;
  IF (SELECT read_at FROM ops.notifications WHERE id='bcd5bb90-fbee-5d59-bcec-7a08c29c31c6') IS NULL THEN
    RAISE EXCEPTION 'notification was not marked read';
  END IF;
  IF (SELECT revoked_at FROM ops.sessions WHERE id='22222222-2222-4222-8222-222222222222') IS NULL THEN
    RAISE EXCEPTION 'session was not revoked';
  END IF;
  IF (SELECT revoked_at FROM ops.sessions WHERE id='33333333-3333-4333-8333-333333333333') IS NOT NULL THEN
    RAISE EXCEPTION 'revokeOwnSession revoked a different active session for the same actor';
  END IF;
  IF (SELECT version FROM ops.schema_drifts WHERE id='7dc6b03d-d98b-53a8-828b-e0db50d7cfde') <> 1 OR
     (SELECT status FROM ops.schema_drifts WHERE id='7dc6b03d-d98b-53a8-828b-e0db50d7cfde') <> 'OPEN' OR
     (SELECT status FROM ops.schema_mappings
       WHERE schema_drift_id='7dc6b03d-d98b-53a8-828b-e0db50d7cfde'
         AND mapping_version=1 AND mapping_digest=repeat('f',64)) IS DISTINCT FROM 'DRAFT' THEN
    RAISE EXCEPTION 'mismatched schema mapping digest changed canonical state';
  END IF;
  IF (SELECT status FROM ops.source_incidents WHERE source_id='control-fixture-source') <> 'ACKNOWLEDGED' THEN
    RAISE EXCEPTION 'source incident was not acknowledged';
  END IF;
  IF (SELECT enabled FROM ops.provider_configs WHERE id='59e6fe3c-6803-5f19-8ee2-1595abc421a8') THEN
    RAISE EXCEPTION 'provider routing was not disabled';
  END IF;
  IF (SELECT enabled FROM ops.source_registry WHERE source_id='control-pause-source') THEN
    RAISE EXCEPTION 'source scheduling was not paused';
  END IF;
  IF (SELECT state FROM ops.queue_controls WHERE queue_name='control-fixture-queue') <> 'PAUSED_NEW' THEN
    RAISE EXCEPTION 'job queue was not paused for new work';
  END IF;
  IF (SELECT assignee_user_id FROM ops.tasks WHERE id='cf6b0dd7-1267-5de0-a363-c8e3af950b1d') <>
     '75cccee2-bca8-53c5-90d4-0949f63d8e52'::uuid THEN
    RAISE EXCEPTION 'task assignee was not persisted';
  END IF;
  IF (SELECT daily_limit FROM ops.budget_limits WHERE scope='control-fixture-budget') <> 100.00 OR
     (SELECT monthly_limit FROM ops.budget_limits WHERE scope='control-fixture-budget') <> 1000.00 THEN
    RAISE EXCEPTION 'budget limits were not persisted';
  END IF;
  SELECT count(*) INTO actual FROM ops.access_requests
   WHERE requester_user_id='11111111-1111-4111-8111-111111111111' AND status='PENDING';
  -- One row is the catalog-wide command witness and one is the deliberately
  -- expired idempotency claim reclaimed through HTTP.  The intervening exact
  -- replay must not add a third effect.
  IF actual <> 2 THEN RAISE EXCEPTION 'access request rows %, expected 2 (initial plus expired-claim reclaim)', actual; END IF;
  SELECT count(*) INTO actual FROM ops.idempotency_keys
   WHERE scope='control:11111111-1111-4111-8111-111111111111:createAccessRequest'
     AND response_status=201 AND response_body IS NOT NULL;
  IF actual <> 2 THEN RAISE EXCEPTION 'completed access idempotency owners %, expected 2', actual; END IF;
  SELECT count(*) INTO actual FROM ops.idempotency_keys
   WHERE scope='control:11111111-1111-4111-8111-111111111111:createAccessRequest'
     AND response_status IS NULL AND response_body IS NULL AND expires_at>clock_timestamp();
  IF actual <> 1 THEN RAISE EXCEPTION 'active in-flight access idempotency owners %, expected 1', actual; END IF;
  IF (SELECT status FROM ops.users WHERE id='75cccee2-bca8-53c5-90d4-0949f63d8e52') <> 'DISABLED' THEN
    RAISE EXCEPTION 'target user was not disabled';
  END IF;
  SELECT count(*) INTO actual FROM ops.users WHERE status='INVITED' AND email LIKE 'inviteuser%@example.test';
  IF actual <> 1 THEN RAISE EXCEPTION 'invited users %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.user_roles
   WHERE user_id='a2583e82-06ed-558f-86e7-8ed3b439637c' AND role_id='f627eed8-b162-59dd-bfd7-7ef7d65cd39b'
     AND revoked_at IS NOT NULL AND revoked_by='11111111-1111-4111-8111-111111111111';
  IF actual <> 1 THEN RAISE EXCEPTION 'revoked role grants %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.role_change_proposals WHERE role_id='f627eed8-b162-59dd-bfd7-7ef7d65cd39b';
  IF actual <> 1 THEN RAISE EXCEPTION 'role change proposals %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.access_reviews WHERE status='OPEN';
  IF actual <> 1 THEN RAISE EXCEPTION 'access review rows %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM editorial.claims WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410';
  IF actual <> 2 THEN RAISE EXCEPTION 'case claims %, expected 2', actual; END IF;
  SELECT count(*) INTO actual FROM editorial.evidence WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410';
  IF actual <> 4 THEN RAISE EXCEPTION 'case evidence %, expected 4', actual; END IF;
  SELECT count(*) INTO actual FROM editorial.hypotheses WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410';
  IF actual <> 2 THEN RAISE EXCEPTION 'case hypotheses %, expected 2', actual; END IF;
  SELECT count(*) INTO actual FROM editorial.evidence_redactions
   WHERE evidence_id='072ba181-0a97-51b1-bf1f-462e1b80981a' AND status='DRAFT';
  IF actual <> 1 THEN RAISE EXCEPTION 'evidence redactions %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM editorial.evidence_links
   WHERE evidence_id='072ba181-0a97-51b1-bf1f-462e1b80981a';
  IF actual <> 1 THEN RAISE EXCEPTION 'evidence links %, expected 1', actual; END IF;
  IF (SELECT validation_status::text FROM editorial.claims
      WHERE id='e6b7009d-1cb1-5c31-ad2d-819ff78e73e4') <> 'VALID' THEN
    RAISE EXCEPTION 'claim validation status was not persisted';
  END IF;
  IF (SELECT verification_status FROM editorial.evidence
      WHERE id='072ba181-0a97-51b1-bf1f-462e1b80981a') <> 'VERIFIED' THEN
    RAISE EXCEPTION 'evidence verification status was not persisted';
  END IF;
  SELECT count(*) INTO actual FROM editorial.corrections
   WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410';
  IF actual <> 4 THEN RAISE EXCEPTION 'case correction rows %, expected 4', actual; END IF;
  IF (SELECT resolution FROM editorial.corrections
      WHERE id='9d27f882-144a-54c2-b088-400f75d60359') <> 'RESOLVED' THEN
    RAISE EXCEPTION 'correction resolution was not persisted';
  END IF;
  IF (SELECT assigned_user_id FROM editorial.corrections
      WHERE id='6f1ff081-2d57-511c-a79a-5dba9893565c') <>
     '75cccee2-bca8-53c5-90d4-0949f63d8e52'::uuid THEN
    RAISE EXCEPTION 'correction assignee was not persisted';
  END IF;
  SELECT count(*) INTO actual FROM editorial.retraction_drafts
   WHERE publication_revision_id='02568a6a-27f5-5ede-b5d0-21107e22a755' AND status='DRAFT';
  IF actual <> 1 THEN RAISE EXCEPTION 'retraction drafts %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM editorial.publication_access_decisions
   WHERE publication_revision_id='02568a6a-27f5-5ede-b5d0-21107e22a755' AND state='ACTIVE';
  IF actual <> 1 THEN RAISE EXCEPTION 'publication access decisions %, expected 1', actual; END IF;

  IF (SELECT investigation_state FROM editorial.cases
      WHERE id='148b09d5-aa28-5351-b471-9ef333a3e410') <> 'AWAITING_RESPONSE' THEN
    RAISE EXCEPTION 'case transition was not persisted';
  END IF;
  IF (SELECT lead_investigator_id FROM editorial.cases
      WHERE id='148b09d5-aa28-5351-b471-9ef333a3e410') <>
     '75cccee2-bca8-53c5-90d4-0949f63d8e52'::uuid THEN
    RAISE EXCEPTION 'case assignment was not persisted';
  END IF;
  IF (SELECT status FROM core.anomaly_signals
      WHERE id='641fc905-1d30-5062-b0e6-9fbb468502c4') <> 'ASSIGNED' THEN
    RAISE EXCEPTION 'signal lifecycle did not preserve assignment after unlink';
  END IF;
  SELECT count(*) INTO actual FROM editorial.case_signals
   WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410'
     AND signal_id='641fc905-1d30-5062-b0e6-9fbb468502c4';
  IF actual <> 0 THEN RAISE EXCEPTION 'signal unlink left % canonical links', actual; END IF;

  SELECT count(*) INTO actual FROM ops.agent_suggestions
   WHERE (id='30ddda7c-3ee4-52a6-af23-f09f1f8cd9d4' AND status='ACCEPTED' AND decided_by IS NOT NULL)
      OR (id='ae58ffd5-e2a2-5bf2-8a4f-e11facaee532' AND status='REJECTED' AND decided_by IS NOT NULL);
  IF actual <> 2 THEN RAISE EXCEPTION 'agent suggestion decisions %, expected 2', actual; END IF;
  SELECT count(*) INTO actual FROM ops.agent_runs;
  IF actual <> 3 THEN RAISE EXCEPTION 'agent run rows %, expected 3', actual; END IF;
  SELECT count(*) INTO actual FROM core.rule_evaluations;
  IF actual <> 4 THEN RAISE EXCEPTION 'rule evaluation rows %, expected 4', actual; END IF;

  SELECT count(*) INTO actual FROM ops.schema_mappings
   WHERE (schema_drift_id='b085a8f4-6a10-508b-b5af-932cc2e4302a' AND mapping_version=1
          AND mapping_digest='ec5ff780a16c3555796ea902ba229f8702b16b7152d186fb12466c673f2b7684'
          AND status='APPROVED' AND decided_by='11111111-1111-4111-8111-111111111111'
          AND field_mappings='[{"upstreamPath":"approveSchemaMapping-upstreamPath","canonicalField":"approveSchemaMapping-canonicalField","transform":"approveSchemaMapping-transform","required":true}]'::jsonb)
      OR (schema_drift_id='a8dd0f25-7ce3-5ca9-84a4-317e1e0ef474' AND mapping_version=1
          AND mapping_digest='9cd29fd04064fd955a0c98afc80f02676d6072c89e0fa93c6ca4a78a2bb75994'
          AND status='REJECTED' AND decided_by='11111111-1111-4111-8111-111111111111'
          AND field_mappings='[{"upstreamPath":"legacy.supplier","canonicalField":"supplierName","transform":"trim","required":true}]'::jsonb);
  IF actual <> 2 THEN RAISE EXCEPTION 'schema mapping decisions %, expected 2', actual; END IF;
  IF (SELECT status FROM ops.schema_drifts WHERE id='b085a8f4-6a10-508b-b5af-932cc2e4302a') <> 'RESOLVED'
     OR (SELECT version FROM ops.schema_drifts WHERE id='b085a8f4-6a10-508b-b5af-932cc2e4302a') <> 2
     OR (SELECT status FROM ops.schema_drifts WHERE id='a8dd0f25-7ce3-5ca9-84a4-317e1e0ef474') <> 'REJECTED'
     OR (SELECT version FROM ops.schema_drifts WHERE id='a8dd0f25-7ce3-5ca9-84a4-317e1e0ef474') <> 2 THEN
    RAISE EXCEPTION 'schema drift terminal decisions were not persisted';
  END IF;

  SELECT count(*) INTO actual FROM editorial.response_requests
   WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410';
  IF actual <> 3 THEN RAISE EXCEPTION 'response request rows %, expected 3', actual; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM editorial.response_requests
     WHERE id='8f749b51-1351-582e-af83-512696fc93ef'
       AND case_id='148b09d5-aa28-5351-b471-9ef333a3e410'
       AND status='SENT' AND sent_at IS NOT NULL AND due_at>clock_timestamp()
  ) THEN
    RAISE EXCEPTION 'transition guard response request fixture was not preserved';
  END IF;
  SELECT count(*) INTO actual FROM editorial.response_requests
   WHERE substring(recipient_email_encrypted FROM 1 FOR 13)=convert_to('gurine-fe-v1.','UTF8')
     AND octet_length(recipient_email_encrypted) > 40;
  IF actual <> 2 THEN RAISE EXCEPTION 'encrypted response recipient rows %, expected 2', actual; END IF;
  IF (SELECT public_excerpt_sha256 FROM editorial.responses
      WHERE id='6267870b-97d8-51c0-aa38-030abefcc483') <>
     '1a9df3dac325be36a6591593c431fae6abd98358330e9d87615fbd9441820cf7' THEN
    RAISE EXCEPTION 'response excerpt approval hash was not persisted';
  END IF;

  SELECT count(*) INTO actual FROM ops.source_runs;
  IF actual <> 9 THEN RAISE EXCEPTION 'source run rows %, expected 9 after scheduler', actual; END IF;
  SELECT count(*) INTO actual FROM ops.source_runs
   WHERE scheduled_for IS NOT NULL AND schedule_expression='0 * * * *'
     AND mode='INCREMENTAL' AND status='QUEUED'
     AND source_id IN ('control-backfill-source','control-fixture-source','control-run-source');
  IF actual <> 3 THEN RAISE EXCEPTION 'scheduler source run rows %, expected 3', actual; END IF;
  IF EXISTS (
    SELECT source_id FROM ops.source_runs WHERE scheduled_for IS NOT NULL
     GROUP BY source_id,scheduled_for HAVING count(*)<>1
  ) THEN
    RAISE EXCEPTION 'scheduler replay created duplicate source cron slots';
  END IF;
  SELECT count(*) INTO actual FROM ops.jobs j
   JOIN ops.source_runs r ON r.id=(j.payload->>'sourceRunId')::uuid
   WHERE j.job_type='SOURCE_RUN' AND j.queue='ingest-worker'
     AND j.dedupe_key LIKE 'source-run:%' AND r.scheduled_for IS NOT NULL
     AND j.payload->>'scheduledFor' IS NOT NULL;
  IF actual <> 3 THEN RAISE EXCEPTION 'scheduler source jobs %, expected 3', actual; END IF;
  SELECT count(*) INTO actual FROM ops.source_runs WHERE retry_of_source_run_id IS NOT NULL AND status='QUEUED';
  IF actual <> 1 THEN RAISE EXCEPTION 'source retry rows %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.source_runs
   WHERE (source_id='control-backfill-source' AND mode='DRY_RUN' AND status='QUEUED'
          AND scheduled_for IS NULL)
      OR (source_id='control-run-source' AND mode='INCREMENTAL' AND status='QUEUED'
          AND scheduled_for IS NULL)
      OR (id='fcd024f0-de94-5f6d-88b8-25016c38094f' AND status='PAUSED');
  IF actual <> 3 THEN RAISE EXCEPTION 'source lifecycle rows %, expected 3', actual; END IF;
  IF (SELECT status FROM ops.jobs WHERE id='14c72bb6-efea-52a0-8913-1bee07d0a87d') <> 'QUEUED'
     OR (SELECT version FROM ops.jobs WHERE id='14c72bb6-efea-52a0-8913-1bee07d0a87d') <> 2 THEN
    RAISE EXCEPTION 'bulk job retry was not persisted';
  END IF;
  SELECT count(*) INTO actual FROM ops.provider_connection_tests
   WHERE provider_id='7e7875f5-52dd-5375-9e3c-c35521d2f220' AND status='QUEUED';
  IF actual <> 1 THEN RAISE EXCEPTION 'provider connection tests %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.audit_verification_runs WHERE status='QUEUED';
  IF actual <> 1 THEN RAISE EXCEPTION 'audit verification runs %, expected 1', actual; END IF;

  SELECT count(*) INTO actual FROM editorial.review_decisions
   WHERE review_snapshot_id='04935ea9-f702-552c-aedc-425382a2d2b3'
     AND reviewer_id='11111111-1111-4111-8111-111111111111' AND decision='APPROVE';
  IF actual <> 1 THEN RAISE EXCEPTION 'independent review decisions %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM editorial.publication_previews
   WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410'
     AND review_snapshot_id='04935ea9-f702-552c-aedc-425382a2d2b3';
  IF actual <> 2 THEN RAISE EXCEPTION 'publication previews %, expected 2', actual; END IF;
  SELECT count(*) INTO actual FROM editorial.publication_revisions
   WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410';
  IF actual <> 2 THEN RAISE EXCEPTION 'publication revisions %, expected 2', actual; END IF;
  IF (SELECT public_payload->'agencyIds' FROM editorial.publication_revisions
      WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410'
      ORDER BY revision DESC LIMIT 1) <> '["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]'::jsonb
     OR (SELECT public_payload->'supplierIds' FROM editorial.publication_revisions
         WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410'
         ORDER BY revision DESC LIMIT 1) <> '["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]'::jsonb
     OR (SELECT public_payload->'ruleIds' FROM editorial.publication_revisions
         WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410'
         ORDER BY revision DESC LIMIT 1) <> '["control-fixture-rule"]'::jsonb THEN
    RAISE EXCEPTION 'publication relation keys were not derived from the linked contract signal';
  END IF;

  SELECT count(*) INTO actual FROM ops.audit_exports;
  IF actual <> 2 THEN RAISE EXCEPTION 'audit export rows %, expected 2', actual; END IF;
  SELECT count(*) INTO actual FROM ops.jobs WHERE job_type='AUDIT_EXPORT' AND queue='audit-export';
  IF actual <> 1 THEN RAISE EXCEPTION 'audit export jobs %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM editorial.legal_holds WHERE active;
  IF actual <> 1 THEN RAISE EXCEPTION 'active legal hold rows %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.audit_events WHERE action LIKE 'command.%';
  -- Typed domain audit actions such as ACTION_DECISION_WITHDRAWN are
  -- asserted by their owning integration path and intentionally do not use
  -- the generic command.* action namespace.
  IF actual <> 85 THEN RAISE EXCEPTION 'command audit rows %, expected 85', actual; END IF;
  BEGIN
    PERFORM ops.enqueue_outbox('case','schema-negative-missing',1,
      'case.state_transitioned.v1','{}'::jsonb,clock_timestamp());
    RAISE EXCEPTION 'known event admitted a payload missing required fields';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  BEGIN
    PERFORM ops.enqueue_outbox('access','schema-negative-extra',1,
      'access.request_created.v1',jsonb_build_object(
        'actor_id','fixture','occurred_at','2026-07-12T00:00:00Z',
        'operation_id','createAccessRequest','request_id','fixture','extra',true),clock_timestamp());
    RAISE EXCEPTION 'known event admitted an additional payload field';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  BEGIN
    PERFORM ops.enqueue_outbox('access','schema-negative-type',1,
      'access.request_created.v1',jsonb_build_object(
        'actor_id',7,'occurred_at','2026-07-12T00:00:00Z',
        'operation_id','createAccessRequest','request_id','fixture'),clock_timestamp());
    RAISE EXCEPTION 'known event admitted a wrong payload field type';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  INSERT INTO ops.event_types(event_type,category,schema_version,active,payload_schema_uri,payload_schema)
  VALUES('test.inactive_event.v1','DOMAIN',1,false,'payloads/test_inactive_event_v1.schema.json',
    '{"type":"object","additionalProperties":false,"required":[],"properties":{}}'::jsonb)
  ON CONFLICT(event_type) DO UPDATE SET active=false;
  BEGIN
    PERFORM ops.enqueue_outbox('test','inactive-event',1,
      'test.inactive_event.v1','{}'::jsonb,clock_timestamp());
    RAISE EXCEPTION 'inactive event type was admitted';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  IF EXISTS(SELECT 1 FROM ops.outbox WHERE aggregate_id LIKE 'schema-negative-%' OR aggregate_id='inactive-event') THEN
    RAISE EXCEPTION 'rejected event payload left an outbox row';
  END IF;
  SELECT count(*) INTO actual FROM ops.outbox
   WHERE event_type='evidence.segment_created.v1'
     AND aggregate_type='EvidenceSegment'
     AND aggregate_version=1
     AND payload=jsonb_build_object(
       'evidenceSegmentId','1e44d0d1-9826-59fb-bc26-07c443a2134d',
       'sourceAssetId','a9bdbc4c-076b-5d00-93da-c8074941d1c0',
       'sourceAssetRevision',1,
       'locatorDigest','4656013e261fa8c167a4157ef90e11af4fba55d5c9ac9b7d60e1e2ea39fc274d',
       'contentSha256','4951601014f8f3dfce1477715f11e812d5c8a29f00bd88803405fd32d4af07c6'
     );
  IF actual <> 1 THEN RAISE EXCEPTION 'canonical evidence segment event rows %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.outbox;
  -- Final APPROVE now adds the atomic action.execution_authorized.v1 event
  -- that the workflow worker consumes.
  IF actual <> 33 THEN RAISE EXCEPTION 'control outbox rows %, expected 33', actual; END IF;

  BEGIN
    INSERT INTO editorial.publication_revisions(
      case_id,revision,state,review_snapshot_id,public_payload,
      public_payload_sha256,preview_sha256,published_by
    ) VALUES(
      '148b09d5-aa28-5351-b471-9ef333a3e410',99,'PUBLISHED_ANOMALY',
      '04935ea9-f702-552c-aedc-425382a2d2b3','{}',
      '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
      '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
      '11111111-1111-4111-8111-111111111111'
    );
    RAISE EXCEPTION 'database publication guard accepted a stale review snapshot';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
END
$$;

-- R6d publication hardening is exercised in a rollback-only transaction so
-- these owner/guard probes cannot perturb the canonical Control flow counts
-- asserted above.  The prerequisite retention authority is installed by
-- r6d-approved-policy-authority.sql through the established action graph.
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.r6d_control_publication_sha256(
  p_value text
) RETURNS char(64)
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,extensions,pg_temp
AS $$
  SELECT encode(
    extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex'
  )
$$;
GRANT EXECUTE ON FUNCTION pg_temp.r6d_control_publication_sha256(text)
  TO gurine_control_api;

CREATE OR REPLACE FUNCTION pg_temp.r6d_control_registered_person_set_sha256()
RETURNS char(64)
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path=pg_catalog,core,ops,extensions,pg_temp
AS $$
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
    COALESCE(jsonb_agg(entry ORDER BY canonical),'[]'::jsonb)
  ),'sha256'),'hex')
  FROM (
    SELECT jsonb_build_object(
      'contextId',person.context_id,
      'personNameDigest',btrim(person.person_name_digest),
      'personNodeId',person.person_node_id,
      'topologyDigest',btrim(person.topology_digest)
    ) AS entry,
    ops.canonical_jsonb_v1(jsonb_build_object(
      'contextId',person.context_id,
      'personNameDigest',btrim(person.person_name_digest),
      'personNodeId',person.person_node_id,
      'topologyDigest',btrim(person.topology_digest)
    )) AS canonical
    FROM core.list_publication_person_names_v1() AS person
  ) AS registered
$$;

-- Counts alone miss in-place state/version mutations.  This digest covers
-- every durable relation reachable from the retired publication dispatchers
-- and from the guarded publication owners used below.
CREATE OR REPLACE FUNCTION pg_temp.r6d_control_publication_state_sha256()
RETURNS char(64)
LANGUAGE sql STABLE PARALLEL SAFE
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp
AS $$
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'cases',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.cases AS row_value),
      'snapshots',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.review_snapshots AS row_value),
      'assignments',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.review_assignments AS row_value),
      'decisions',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.review_decisions AS row_value),
      'corrections',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.corrections AS row_value),
      'previews',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.publication_previews AS row_value),
      'revisions',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.publication_revisions AS row_value),
      'assessments',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.named_person_publication_assessments AS row_value),
      'findings',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.named_person_publication_findings AS row_value),
      'overrides',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.named_person_legal_overrides AS row_value),
      'reviewReceipts',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.named_person_review_stage_receipts_v1 AS row_value),
      'previewReceipts',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.publication_preview_owner_receipts_v2 AS row_value),
      'revisionReceipts',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM editorial.publication_revision_owner_receipts_v2 AS row_value),
      'tasks',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM ops.tasks AS row_value),
      'idempotency',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM ops.idempotency_keys AS row_value),
      'audit',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM ops.audit_events AS row_value),
      'outbox',(SELECT COALESCE(jsonb_agg(to_jsonb(row_value)
        ORDER BY ops.canonical_jsonb_v1(to_jsonb(row_value))),'[]'::jsonb)
        FROM ops.outbox AS row_value)
    )
  ),'sha256'),'hex')
$$;

DO $r6d_publication_preflight$
DECLARE
  v_schedule_count bigint;
BEGIN
  IF current_database() NOT IN (
    'gurine_control_test','gurine_submission_test','gurine_event_consumers'
  ) THEN
    RAISE EXCEPTION 'r6d_control_publication_probe_database_forbidden'
      USING ERRCODE='55000';
  END IF;
  IF to_regprocedure('editorial.preview_publication_guarded_v2(jsonb)')
       IS NULL
     OR to_regprocedure(
       'editorial.record_named_person_review_stage_v1(jsonb)'
     ) IS NULL
     OR to_regprocedure(
       'editorial.record_named_person_legal_override_v1(jsonb)'
     ) IS NULL
     OR to_regprocedure('editorial.publish_guarded_revision_v2(jsonb)')
       IS NULL THEN
    RAISE EXCEPTION 'r6d_control_publication_owner_missing'
      USING ERRCODE='55000';
  END IF;
  SELECT count(*) INTO v_schedule_count
  FROM ops.record_class_schedules AS schedule
  JOIN ops.r6d_record_class_catalog AS catalog
    ON catalog.record_class=schedule.record_class
  WHERE schedule.record_class='NAMED_PERSON_PUBLICATION_GOVERNANCE'
    AND schedule.effective_at<=clock_timestamp()
    AND schedule.review_expires_at>clock_timestamp()
    AND schedule.terminal_action=catalog.required_terminal_action;
  IF v_schedule_count<>1 THEN
    RAISE EXCEPTION
      'r6d_control_publication_schedule_count %, expected 1',
      v_schedule_count USING ERRCODE='55000';
  END IF;
END
$r6d_publication_preflight$;

-- Transaction-local principals model request-bound authenticated sessions and
-- already-issued Step-up assertions.  They are authority inputs, never owner
-- output receipts.
INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES
  ('d6e00000-0000-4000-8000-000000000001','r6d-control-publisher',
   'r6d-control-publisher@example.invalid','R6d control publisher','ACTIVE'),
  ('d6e00000-0000-4000-8000-000000000002','r6d-control-editor',
   'r6d-control-editor@example.invalid','R6d control editor','ACTIVE'),
  ('d6e00000-0000-4000-8000-000000000003','r6d-control-legal',
   'r6d-control-legal@example.invalid','R6d control legal','ACTIVE');

INSERT INTO ops.user_roles(id,user_id,role_id,granted_by,reason,granted_at)
SELECT fixture.id,fixture.user_id,role.id,
  'd6e00000-0000-4000-8000-000000000001'::uuid,
  'R6d publication runtime assertion',clock_timestamp()
FROM (VALUES
  ('d6e00000-0000-4000-8000-000000000011'::uuid,
   'd6e00000-0000-4000-8000-000000000001'::uuid,'PUBLISHER'),
  ('d6e00000-0000-4000-8000-000000000012'::uuid,
   'd6e00000-0000-4000-8000-000000000002'::uuid,'EDITOR'),
  ('d6e00000-0000-4000-8000-000000000013'::uuid,
   'd6e00000-0000-4000-8000-000000000003'::uuid,'LEGAL_REVIEWER')
) AS fixture(id,user_id,role_code)
JOIN ops.roles AS role ON role.code=fixture.role_code;

INSERT INTO ops.sessions(
  id,user_id,session_token_hash,auth_time,step_up_at,expires_at,csrf_token_hash
)
VALUES
  ('d6e00000-0000-4000-8000-000000000021',
   'd6e00000-0000-4000-8000-000000000001',
   pg_temp.r6d_control_publication_sha256('publisher-session'),
   clock_timestamp()-interval '1 minute',clock_timestamp(),
   clock_timestamp()+interval '30 minutes',repeat('a',64)),
  ('d6e00000-0000-4000-8000-000000000022',
   'd6e00000-0000-4000-8000-000000000002',
   pg_temp.r6d_control_publication_sha256('editor-session'),
   clock_timestamp()-interval '1 minute',clock_timestamp(),
   clock_timestamp()+interval '30 minutes',repeat('b',64)),
  ('d6e00000-0000-4000-8000-000000000023',
   'd6e00000-0000-4000-8000-000000000003',
   pg_temp.r6d_control_publication_sha256('legal-session'),
   clock_timestamp()-interval '1 minute',clock_timestamp(),
   clock_timestamp()+interval '30 minutes',repeat('c',64));

INSERT INTO editorial.cases(
  id,public_slug,title,investigation_state,publication_state,
  legal_review_required,version
)
VALUES(
  'd6e00000-0000-4000-8000-000000000101','r6d-control-publication',
  'R6d control publication','READY_TO_PUBLISH','NEVER_PUBLISHED',true,1
);

INSERT INTO editorial.review_snapshots(
  id,case_id,case_version,snapshot_sha256,snapshot_payload,
  automated_gate_results,unresolved_blockers,created_by
)
VALUES(
  'd6e00000-0000-4000-8000-000000000102',
  'd6e00000-0000-4000-8000-000000000101',1,repeat('a',64),
  '{"fixture":"R6D_CONTROL_PUBLICATION"}',
  '{"namedPersonGate":"PENDING"}','[]',
  'd6e00000-0000-4000-8000-000000000001'
);

UPDATE editorial.cases
SET current_review_snapshot_id='d6e00000-0000-4000-8000-000000000102'
WHERE id='d6e00000-0000-4000-8000-000000000101';

INSERT INTO editorial.review_assignments(
  id,case_id,review_snapshot_id,reviewer_id,status,assigned_by,
  assigned_at,started_at,due_at,version
)
VALUES
  ('d6e00000-0000-4000-8000-000000000111',
   'd6e00000-0000-4000-8000-000000000101',
   'd6e00000-0000-4000-8000-000000000102',
   'd6e00000-0000-4000-8000-000000000002','IN_PROGRESS',
   'd6e00000-0000-4000-8000-000000000001',clock_timestamp(),
   clock_timestamp(),clock_timestamp()+interval '1 hour',1),
  ('d6e00000-0000-4000-8000-000000000112',
   'd6e00000-0000-4000-8000-000000000101',
   'd6e00000-0000-4000-8000-000000000102',
   'd6e00000-0000-4000-8000-000000000003','IN_PROGRESS',
   'd6e00000-0000-4000-8000-000000000001',clock_timestamp(),
   clock_timestamp(),clock_timestamp()+interval '1 hour',1);

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,last_issued_at
)
VALUES
  ('d6e00000-0000-4000-8000-000000000121',
   'd6e00000-0000-4000-8000-000000000022',repeat('1',64),repeat('2',64),
   pg_temp.r6d_control_publication_sha256('editor-step-up-token'),
   transaction_timestamp()+interval '4 minutes',1,
   transaction_timestamp()-interval '1 second'),
  ('d6e00000-0000-4000-8000-000000000122',
   'd6e00000-0000-4000-8000-000000000023',repeat('3',64),repeat('4',64),
   pg_temp.r6d_control_publication_sha256('legal-step-up-token'),
   transaction_timestamp()+interval '4 minutes',1,
   transaction_timestamp()-interval '1 second'),
  ('d6e00000-0000-4000-8000-000000000123',
   'd6e00000-0000-4000-8000-000000000021',repeat('c',64),repeat('b',64),
   pg_temp.r6d_control_publication_sha256('publish-step-up-token'),
   transaction_timestamp()+interval '4 minutes',1,
   transaction_timestamp()-interval '1 second');

DO $f9_slug_negative_assertions$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM editorial.list_r6d_invalid_public_slugs_v1()
    WHERE case_id='f9000000-0000-4000-8000-000000000001'
      AND 'CHARACTER_SET_OR_SHAPE_INVALID'=ANY(violation_codes)
  ) THEN
    RAISE EXCEPTION 'f9_legacy_invalid_slug_not_reported';
  END IF;
  BEGIN
    INSERT INTO editorial.cases(
      id,public_slug,title,investigation_state,publication_state,priority,version
    ) VALUES(
      'f9000000-0000-4000-8000-000000000011','테스트-가공인',
      'TEST_ONLY Korean slug rejection','INVESTIGATING','NEVER_PUBLISHED','LOW',1
    );
    RAISE EXCEPTION 'f9_korean_slug_check_not_enforced';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO editorial.cases(
      id,public_slug,title,investigation_state,publication_state,priority,version
    ) VALUES(
      'f9000000-0000-4000-8000-000000000012','TEST-ONLY-UPPERCASE',
      'TEST_ONLY uppercase slug rejection','INVESTIGATING','NEVER_PUBLISHED','LOW',1
    );
    RAISE EXCEPTION 'f9_uppercase_slug_check_not_enforced';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO editorial.cases(
      id,public_slug,title,investigation_state,publication_state,priority,version
    ) VALUES(
      'f9000000-0000-4000-8000-000000000013',repeat('a',121),
      'TEST_ONLY overlength slug rejection','INVESTIGATING','NEVER_PUBLISHED','LOW',1
    );
    RAISE EXCEPTION 'f9_overlength_slug_check_not_enforced';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE editorial.cases SET public_slug='slug-only-update-must-be-owned'
    WHERE id='d6e00000-0000-4000-8000-000000000101';
    RAISE EXCEPTION 'f9_slug_only_update_guard_not_enforced';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  BEGIN
    UPDATE editorial.cases
    SET publication_state='PUBLISHED_ANOMALY',
        current_publication_revision=1,version=version+1
    WHERE id='f9000000-0000-4000-8000-000000000001';
    RAISE EXCEPTION 'f9_legacy_invalid_slug_publication_not_blocked';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'F9_SLUG_NEGATIVE_ASSERTIONS_PASS';
END
$f9_slug_negative_assertions$;

-- TEST_ONLY: `테스트인` is a deliberately synthetic natural-person name.
DO $f9_public_text_tree_parity$
DECLARE
  v_payload jsonb:=jsonb_build_object(
    'publicationState','PUBLISHED_ANOMALY','slug','test-only-case',
    'title','가상 계약 점검','summary','계약 자료 비교',
    'nonConclusion','현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다.',
    'agencyName','가상시청','contractName','정보화 사업',
    'claims',jsonb_build_array(jsonb_build_object(
      'text','테스트인 대표 관련 자료',
      'limitations',jsonb_build_array('재직 기간 미확인')
    )),'evidence',jsonb_build_array(jsonb_build_object(
      'title','계약서','documentTitle','계약 원문','publisher','가상시청',
      'sourceUrl','https://official.example/contracts/test-only-person',
      'pageAnchor','3쪽',
      'sourceLocator','https://official.example/contracts/1',
      'publicExcerpt','테스트인 대표 서명'
    )),'responses',jsonb_build_array(jsonb_build_object(
      'partyName','가상 주식회사','excerpt','추가 확인 중'
    ))
  );
  v_archive_payload jsonb:=jsonb_build_object(
    'schema_version','1.0.0','slug','test-only-archive',
    'title','계약 검토','summary','가상 자료','non_conclusion','확정 판단 아님',
    'sections',jsonb_build_array(jsonb_build_object(
      'heading','확인 내용','blocks',jsonb_build_array(jsonb_build_object(
        'type','TABLE','text',NULL,'data',jsonb_build_object('담당','테스트인 전 장관')
      ))
    )),'claims',jsonb_build_array(jsonb_build_object('text_ko','계약 사실')),
    'evidence',jsonb_build_array(jsonb_build_object(
      'summary','공식 문서','public_excerpt','테스트인 서명',
      'source',jsonb_build_object(
        'source_url','https://official.example/contracts/:대표이사-테스트인',
        'locator',jsonb_build_object('value','3쪽')
      )
    )),'subjects',jsonb_build_array(jsonb_build_object('display_name','가상 기관')),
    'methodology',jsonb_build_object(
      'limitations',jsonb_build_array('기간 한계'),
      'calculation',jsonb_build_object('설명','자료 비교')
    ),'responses',jsonb_build_array(jsonb_build_object(
      'party','가상 기관','display_text','추가 확인 중'
    )),'corrections',jsonb_build_array(jsonb_build_object('summary','금액 정정')),
    'review_summary',jsonb_build_object('legal_reviewed',false)
  );
BEGIN
  IF btrim(editorial.r6d_public_text_sha256_v1(v_payload))<>
       'dc337255b4957ee87689575b67c32abc983cf2cbdd7891746abc248b1caf8eec'
     OR editorial.r6d_json_pointer_text_v1(v_payload,'/slug')<>
       'test-only-case'
     OR editorial.r6d_json_pointer_text_v1(
       v_payload,'/evidence/0/sourceUrl'
     )<>'https://official.example/contracts/test-only-person'
     OR btrim(editorial.r6d_public_text_sha256_v1(v_archive_payload))<>
       '568451e18206560b96ad3bd078ea2eb80c9f653f1ee7eec23b3dd4562034e4df'
     OR editorial.r6d_json_pointer_text_v1(v_archive_payload,'/slug')<>
       'test-only-archive'
     OR editorial.r6d_json_pointer_text_v1(
       v_archive_payload,'/evidence/0/source/source_url'
     )<>'https://official.example/contracts/:대표이사-테스트인'
     OR btrim(editorial.r6d_public_text_sha256_v1(
       v_archive_payload#-'{evidence,0,source,source_url}'
     ))<>'cc27a6ec726d867c3fff7b026cd821bcda6fe9aacd8a64e93af6f8d7e15e7ef9'
     OR btrim(editorial.r6d_public_text_sha256_v1(jsonb_set(
       v_archive_payload,'{evidence,0,source,source_url}',
       to_jsonb('https://official.example/contracts/revised'::text)
     )))=btrim(editorial.r6d_public_text_sha256_v1(v_archive_payload)) THEN
    RAISE EXCEPTION 'f9_public_text_tree_rust_db_parity_invalid';
  END IF;
  RAISE NOTICE 'F9_PUBLIC_TEXT_TREE_RUST_DB_PARITY_PASS';
  RAISE NOTICE
    'F3_ARCHIVE_SOURCE_URL_RUST_DB_PARITY_PASS present_digest=% absent_digest=%',
    btrim(editorial.r6d_public_text_sha256_v1(v_archive_payload)),
    btrim(editorial.r6d_public_text_sha256_v1(
      v_archive_payload#-'{evidence,0,source,source_url}'
    ));
END
$f9_public_text_tree_parity$;

DO $r6d_publication_owner_flow$
DECLARE
  v_payload jsonb:=jsonb_build_object(
    'caseId','d6e00000-0000-4000-8000-000000000101',
    'reviewSnapshotId','d6e00000-0000-4000-8000-000000000102',
    'publicationState','PUBLISHED_ANOMALY',
    'slug','r6d-control-publication',
    'title','R6d 자연인 검토 표면',
    'summary','대표 가나다라는 자연인 실명 검토 표면',
    'nonConclusion','이 기록은 위법 또는 부패의 확정이 아닙니다.',
    'claims',jsonb_build_array(jsonb_build_object(
      'id','d6e00000-0000-4000-8000-000000000201',
      'text','계약 자료 비교','limitations',jsonb_build_array('초기 자료'),
      'evidenceIds',jsonb_build_array(
        'd6e00000-0000-4000-8000-000000000202'
      ),'responseIds','[]'::jsonb
    )),
    'evidence',jsonb_build_array(jsonb_build_object(
      'id','d6e00000-0000-4000-8000-000000000202',
      'title','공식 계약서',
      'sourceUrl','https://example.invalid/test-only-contract-source',
      'publicExcerpt','계약 범위 확인'
    )),'responses','[]'::jsonb
  );
  v_scan jsonb;
  v_lower_payload jsonb;
  v_lower_scan jsonb;
  v_lower_request jsonb;
  v_lower_result jsonb;
  v_preview_request jsonb;
  v_preview_result jsonb;
  v_replay jsonb;
  v_editorial_request jsonb;
  v_editorial_result jsonb;
  v_override jsonb;
  v_override_request jsonb;
  v_override_result jsonb;
  v_legal_request jsonb;
  v_legal_result jsonb;
  v_publish_request jsonb;
  v_publish_result jsonb;
  v_state_before char(64);
  v_outbox_before bigint;
  v_source_sha char(64):=
    pg_temp.r6d_control_publication_sha256('official-source');
  v_locator constant text:='https://example.invalid/official-disposition';
BEGIN
  SELECT jsonb_build_object(
    'rulesetVersion',policy_payload->>'scannerRulesetVersion',
    'rulesetSha256',policy_payload->>'scannerRulesetSha256',
    'publicTextSha256',btrim(
      editorial.r6d_public_text_sha256_v1(v_payload)
    ),
    'registeredNameSetSha256',
      btrim(pg_temp.r6d_control_registered_person_set_sha256()),
    'findings',jsonb_build_array(jsonb_build_object(
      'ordinal',0,'detectorKind','TITLE_ADJACENT_KOREAN_NAME',
      'jsonPointer','/summary','startUtf16',3,'endUtf16',7,
      'matchedTextSha256',encode(extensions.digest(convert_to(
        editorial.r6d_utf16_slice_v1(
          editorial.r6d_json_pointer_text_v1(v_payload,'/summary'),3,7
        ),'UTF8'
      ),'sha256'),'hex'),
      'personNodeId',NULL,'topologyDigest',NULL,
      'contextId',NULL,'personNameDigest',NULL
    ))
  ) INTO STRICT v_scan
  FROM editorial.named_person_publication_policies
  WHERE policy_version='r6d-named-person-publication-v2' AND active;

  v_preview_request:=jsonb_build_object(
    'previewId','d6e00000-0000-4000-8000-000000000103',
    'caseId','d6e00000-0000-4000-8000-000000000101',
    'reviewSnapshotId','d6e00000-0000-4000-8000-000000000102',
    'expectedVersion',1,'publicationState','PUBLISHED_ANOMALY',
    'locale','ko-KR','publicPayload',v_payload,
    'publicPayloadSha256',encode(extensions.digest(
      ops.canonical_jsonb_v1(v_payload),'sha256'),'hex'),
    'scan',v_scan,'legalOverride',NULL,
    '_actorId','d6e00000-0000-4000-8000-000000000001',
    '_actorAssertionJti','d6e00000-0000-4000-8000-000000000131',
    '_actorAssuranceLevel','ACTIVE_SESSION',
    '_actorEffectiveCapability','publication.preview',
    '_actorActionDigest',repeat('9',64),
    '_actorStepUpAuthorizationId',NULL,
    '_actorIdempotencyKeySha256',repeat('a',64),
    '_actorRequestKeySha256',repeat('a',64),
    '_requestId','d6e00000-0000-4000-8000-000000000132',
    '_idempotencyKeySha256',repeat('a',64),
    '_requestSha256',repeat('b',64)
  );
  v_state_before:=pg_temp.r6d_control_publication_state_sha256();
  BEGIN
    PERFORM editorial.preview_publication_guarded_v2(
      v_preview_request||jsonb_build_object(
        'scan',jsonb_set(
          v_scan,'{findings,0,jsonPointer}',to_jsonb('/title'::text)
        )
      )
    );
    RAISE EXCEPTION 'r6d_named_person_finding_location_tamper_accepted';
  EXCEPTION WHEN SQLSTATE '23514' THEN NULL;
  END;
  BEGIN
    PERFORM editorial.preview_publication_guarded_v2(
      v_preview_request||jsonb_build_object(
        'scan',jsonb_set(
          v_scan,'{findings,0,detectorKind}',
          to_jsonb('REGISTERED_PERSON_EXACT'::text)
        )
      )
    );
    RAISE EXCEPTION 'r6d_named_person_finding_basis_tamper_accepted';
  EXCEPTION WHEN SQLSTATE '23514' THEN NULL;
  END;
  BEGIN
    PERFORM editorial.preview_publication_guarded_v2(
      v_preview_request||jsonb_build_object(
        'scan',jsonb_set(
          v_scan,'{rulesetVersion}',to_jsonb('unknown-ruleset'::text)
        )
      )
    );
    RAISE EXCEPTION 'r6d_named_person_ruleset_tamper_accepted';
  EXCEPTION WHEN SQLSTATE '23514' THEN NULL;
  END;
  IF pg_temp.r6d_control_publication_state_sha256()<>v_state_before THEN
    RAISE EXCEPTION 'r6d_named_person_scan_tamper_not_zero_write';
  END IF;
  v_lower_payload:=jsonb_set(
    v_payload,'{summary}',
    to_jsonb('😀 「대표이사」 "테스​트인"은 TEST_ONLY 가공 이름입니다.'::text)
  );
  v_lower_scan:=jsonb_set(jsonb_set(
    v_scan,'{publicTextSha256}',to_jsonb(btrim(
      editorial.r6d_public_text_sha256_v1(v_lower_payload)
    ))),'{findings}','[]'::jsonb);
  v_lower_request:=jsonb_build_object(
    'caseId','d6e00000-0000-4000-8000-000000000101',
    'reviewSnapshotId','d6e00000-0000-4000-8000-000000000102',
    'publicationState','PUBLISHED_ANOMALY','guardContext','PREVIEW',
    'publicPayload',v_lower_payload,
    'publicPayloadSha256',encode(extensions.digest(
      ops.canonical_jsonb_v1(v_lower_payload),'sha256'),'hex'),
    'scan',v_lower_scan,'legalOverride',NULL,
    '_actorId','d6e00000-0000-4000-8000-000000000001',
    '_actorAssertionJti','f9000000-0000-4000-8000-000000000021',
    '_actorAssuranceLevel','ACTIVE_SESSION',
    '_actorEffectiveCapability','publication.preview',
    '_actorActionDigest',
      pg_temp.r6d_control_publication_sha256('f9-lower-bound-action'),
    '_actorStepUpAuthorizationId',NULL,
    '_actorIdempotencyKeySha256',
      pg_temp.r6d_control_publication_sha256('f9-lower-bound-idempotency'),
    '_actorRequestKeySha256',
      pg_temp.r6d_control_publication_sha256('f9-lower-bound-idempotency'),
    '_requestId','f9000000-0000-4000-8000-000000000022',
    '_idempotencyKeySha256',
      pg_temp.r6d_control_publication_sha256('f9-lower-bound-idempotency'),
    '_requestSha256',repeat('0',64)
  );
  v_lower_request:=jsonb_set(v_lower_request,'{_requestSha256}',to_jsonb(
    encode(extensions.digest(ops.canonical_jsonb_v1(
      v_lower_request-'_requestSha256'
    ),'sha256'),'hex')
  ));
  v_lower_result:=editorial.record_named_person_publication_assessment_v1(
    v_lower_request
  );
  IF v_lower_scan->'findings'<>'[]'::jsonb
     OR v_lower_result->>'assessmentOutcome'<>'BLOCKED'
     OR v_lower_result->>'legalReviewRequired'<>'true'
     OR NOT EXISTS(
       SELECT 1 FROM editorial.named_person_publication_findings AS finding
       WHERE finding.assessment_id=(v_lower_result->>'assessmentId')::uuid
         AND finding.detector_kind='TITLE_ADJACENT_KOREAN_NAME'
         AND finding.json_pointer='/summary'
         AND finding.start_utf16=11 AND finding.end_utf16=16
         AND finding.matched_text_sha256=encode(extensions.digest(convert_to(
           editorial.r6d_utf16_slice_v1(
             editorial.r6d_json_pointer_text_v1(v_lower_payload,'/summary'),
             finding.start_utf16,finding.end_utf16
           ),'UTF8'
         ),'sha256'),'hex')
     ) THEN
    RAISE EXCEPTION 'f9_empty_findings_title_lower_bound_not_blocked';
  END IF;
  RAISE NOTICE 'F9_EMPTY_FINDINGS_TITLE_LOWER_BOUND_PASS';
  SELECT count(*) INTO v_outbox_before FROM ops.outbox;
  v_preview_result:=editorial.preview_publication_guarded_v2(
    v_preview_request
  );
  IF v_preview_result->>'status'<>'BLOCKED'
     OR v_preview_result->>'legalReviewRequired'<>'true'
     OR v_preview_result->'outboxEventIds'<>'[]'::jsonb
     OR (SELECT count(*) FROM ops.outbox)<>v_outbox_before
     OR NOT EXISTS(
       SELECT 1
       FROM editorial.named_person_publication_assessments AS assessment
       WHERE assessment.assessment_id=
         (v_preview_result->>'assessmentId')::uuid
         AND assessment.outcome='BLOCKED' AND assessment.finding_count=1
     )
     OR NOT EXISTS(
       SELECT 1
       FROM editorial.publication_preview_owner_receipts_v2 AS receipt
       WHERE receipt.preview_id=(v_preview_result->>'previewId')::uuid
         AND btrim(receipt.receipt_digest)=
           v_preview_result->>'receiptDigest'
         AND receipt.receipt_digest=encode(
           extensions.digest(receipt.receipt_canonical,'sha256'),'hex'
         )
     ) THEN
    RAISE EXCEPTION 'r6d_named_person_preview_hard_block_invalid';
  END IF;
  v_state_before:=pg_temp.r6d_control_publication_state_sha256();
  v_replay:=editorial.preview_publication_guarded_v2(v_preview_request);
  IF v_replay->>'replayed'<>'true'
     OR v_replay->>'receiptDigest'<>v_preview_result->>'receiptDigest'
     OR pg_temp.r6d_control_publication_state_sha256()<>v_state_before THEN
    RAISE EXCEPTION 'r6d_preview_exact_replay_not_zero_write';
  END IF;
  BEGIN
    PERFORM editorial.preview_publication_guarded_v2(
      v_preview_request||jsonb_build_object('_requestSha256',repeat('c',64))
    );
    RAISE EXCEPTION 'r6d_preview_divergent_replay_accepted';
  EXCEPTION WHEN SQLSTATE '40001' THEN NULL;
  END;
  IF pg_temp.r6d_control_publication_state_sha256()<>v_state_before THEN
    RAISE EXCEPTION 'r6d_preview_divergent_replay_not_zero_write';
  END IF;

  v_editorial_request:=jsonb_build_object(
    'decisionId','d6e00000-0000-4000-8000-000000000141',
    'reviewSnapshotId','d6e00000-0000-4000-8000-000000000102',
    'stage','EDITORIAL','decision','APPROVE','reason','fixture approve',
    'criteria','{}'::jsonb,
    'reviewerIndependence',jsonb_build_object(
      'independent',true,
      'snapshotCreatedBy','d6e00000-0000-4000-8000-000000000001',
      'reviewer','d6e00000-0000-4000-8000-000000000002'
    ),
    'reauthContextHash',repeat('5',64),
    'referencedEditorialDecisionId',NULL,
    '_actorId','d6e00000-0000-4000-8000-000000000002',
    '_actorAssertionJti','d6e00000-0000-4000-8000-000000000142',
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','review.editorial',
    '_actorActionDigest',repeat('1',64),
    '_actorStepUpAuthorizationId','d6e00000-0000-4000-8000-000000000121',
    '_actorIdempotencyKeySha256',repeat('2',64),
    '_actorRequestKeySha256',repeat('2',64),
    '_requestId','d6e00000-0000-4000-8000-000000000143',
    '_idempotencyKeySha256',repeat('2',64),
    '_requestSha256',repeat('6',64)
  );
  v_editorial_result:=editorial.record_named_person_review_stage_v1(
    v_editorial_request
  );
  IF v_editorial_result->>'replayed'<>'false'
     OR NOT EXISTS(
       SELECT 1 FROM editorial.named_person_review_stage_receipts_v1
       WHERE decision_id='d6e00000-0000-4000-8000-000000000141'
         AND review_stage='EDITORIAL' AND decision='APPROVE'
         AND assurance_level='STEP_UP'
         AND effective_capability='review.editorial'
     ) THEN
    RAISE EXCEPTION 'r6d_editorial_stage_owner_invalid';
  END IF;

  v_override:=jsonb_build_object(
    'receiptVersion','named-individual-legal-override-v1',
    'publicTextSha256',v_scan->>'publicTextSha256',
    'rulesetVersion',v_scan->>'rulesetVersion',
    'reasonCode','OFFICIAL_DISPOSITION_QUOTE',
    'officialSourceLocator',v_locator,
    'officialSourceSha256',btrim(v_source_sha),
    'legalReviewerId','d6e00000-0000-4000-8000-000000000003',
    'receiptSha256',editorial.named_person_legal_override_digest_v1(
      v_scan->>'publicTextSha256',v_scan->>'rulesetVersion',
      'OFFICIAL_DISPOSITION_QUOTE',v_locator,btrim(v_source_sha),
      'd6e00000-0000-4000-8000-000000000003'
    ),
    'editorialReviewDecisionId',
      'd6e00000-0000-4000-8000-000000000141'
  );
  v_override_request:=jsonb_build_object(
    'assessmentId',v_preview_result->>'assessmentId',
    'legalOverride',v_override,
    '_actorId','d6e00000-0000-4000-8000-000000000003',
    '_actorAssertionJti','d6e00000-0000-4000-8000-000000000145',
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','review.legal',
    '_actorActionDigest',repeat('3',64),
    '_actorStepUpAuthorizationId','d6e00000-0000-4000-8000-000000000122',
    '_actorIdempotencyKeySha256',repeat('4',64),
    '_actorRequestKeySha256',repeat('4',64),
    '_requestId','d6e00000-0000-4000-8000-000000000146',
    '_idempotencyKeySha256',repeat('4',64),
    '_requestSha256',repeat('8',64)
  );
  v_override_result:=editorial.record_named_person_legal_override_v1(
    v_override_request
  );
  IF v_override_result->>'replayed'<>'false'
     OR v_override_result->>'overrideId' IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM editorial.named_person_legal_overrides AS legal_override
       WHERE legal_override.override_id=
         (v_override_result->>'overrideId')::uuid
         AND legal_override.receipt_digest=
           (v_override_result->>'overrideReceiptDigest')::char(64)
         AND legal_override.override_digest=encode(
           extensions.digest(legal_override.override_canonical,'sha256'),'hex'
         )
     ) THEN
    RAISE EXCEPTION 'r6d_exact_legal_override_invalid';
  END IF;
  v_state_before:=pg_temp.r6d_control_publication_state_sha256();
  v_replay:=editorial.record_named_person_legal_override_v1(
    v_override_request
  );
  IF v_replay->>'replayed'<>'true'
     OR v_replay->>'overrideReceiptDigest'<>
       v_override_result->>'overrideReceiptDigest'
     OR pg_temp.r6d_control_publication_state_sha256()<>v_state_before THEN
    RAISE EXCEPTION 'r6d_override_exact_replay_not_zero_write';
  END IF;
  BEGIN
    PERFORM editorial.record_named_person_legal_override_v1(
      v_override_request||jsonb_build_object(
        '_requestSha256',repeat('9',64)
      )
    );
    RAISE EXCEPTION 'r6d_override_divergent_replay_accepted';
  EXCEPTION WHEN SQLSTATE '40001' THEN NULL;
  END;
  IF pg_temp.r6d_control_publication_state_sha256()<>v_state_before THEN
    RAISE EXCEPTION 'r6d_override_divergent_replay_not_zero_write';
  END IF;

  v_legal_request:=jsonb_build_object(
    'decisionId','d6e00000-0000-4000-8000-000000000147',
    'reviewSnapshotId','d6e00000-0000-4000-8000-000000000102',
    'stage','LEGAL','decision','APPROVE','reason','fixture legal approve',
    'criteria',jsonb_build_object('namedIndividualOverride',
      jsonb_build_object(
        'publicTextSha256',v_override->>'publicTextSha256',
        'reasonCode',v_override->>'reasonCode',
        'officialSourceLocator',v_override->>'officialSourceLocator',
        'officialSourceSha256',v_override->>'officialSourceSha256',
        'editorialReviewDecisionId',v_override->>'editorialReviewDecisionId'
      )),
    'reviewerIndependence',jsonb_build_object(
      'independent',true,
      'snapshotCreatedBy','d6e00000-0000-4000-8000-000000000001',
      'reviewer','d6e00000-0000-4000-8000-000000000003'
    ),
    'reauthContextHash',repeat('e',64),
    'referencedEditorialDecisionId',
      'd6e00000-0000-4000-8000-000000000141',
    '_actorId','d6e00000-0000-4000-8000-000000000003',
    '_actorAssertionJti','d6e00000-0000-4000-8000-000000000145',
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','review.legal',
    '_actorActionDigest',repeat('3',64),
    '_actorStepUpAuthorizationId','d6e00000-0000-4000-8000-000000000122',
    '_actorIdempotencyKeySha256',repeat('4',64),
    '_actorRequestKeySha256',repeat('4',64),
    '_requestId','d6e00000-0000-4000-8000-000000000146',
    '_idempotencyKeySha256',repeat('4',64),
    '_requestSha256',repeat('8',64)
  );
  v_legal_result:=editorial.record_named_person_review_stage_v1(
    v_legal_request
  );
  IF v_legal_result->>'replayed'<>'false'
     OR NOT EXISTS(
       SELECT 1 FROM editorial.named_person_review_stage_receipts_v1
       WHERE decision_id='d6e00000-0000-4000-8000-000000000147'
         AND review_stage='LEGAL' AND decision='APPROVE'
         AND referenced_editorial_decision_id=
           'd6e00000-0000-4000-8000-000000000141'
         AND named_person_override_id=
           (v_override_result->>'overrideId')::uuid
     ) THEN
    RAISE EXCEPTION 'r6d_legal_stage_owner_invalid';
  END IF;

  v_publish_request:=jsonb_build_object(
    'mode','PUBLISH',
    'caseId','d6e00000-0000-4000-8000-000000000101',
    'reviewSnapshotId','d6e00000-0000-4000-8000-000000000102',
    'expectedVersion',1,
    'previewHash',v_preview_result->>'previewSha256',
    'reason','R6d guarded publication runtime assertion',
    'publicPayloadSha256',v_preview_result->>'previewSha256',
    'scan',v_scan,
    '_actorId','d6e00000-0000-4000-8000-000000000001',
    '_actorAssertionJti','d6e00000-0000-4000-8000-000000000161',
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','publication.publish',
    '_actorActionDigest',repeat('c',64),
    '_actorStepUpAuthorizationId','d6e00000-0000-4000-8000-000000000123',
    '_actorIdempotencyKeySha256',repeat('b',64),
    '_actorRequestKeySha256',repeat('b',64),
    '_requestId','d6e00000-0000-4000-8000-000000000162',
    '_idempotencyKeySha256',repeat('b',64),
    '_requestSha256',
      pg_temp.r6d_control_publication_sha256('publish-request')
  );
  v_publish_result:=editorial.publish_guarded_revision_v2(
    v_publish_request
  );
  IF v_publish_result->>'replayed'<>'false'
     OR v_publish_result->>'publicationState'<>'PUBLISHED_ANOMALY'
     OR jsonb_array_length(v_publish_result->'outboxEventIds')<>3
     OR NOT EXISTS(
       SELECT 1 FROM editorial.cases
       WHERE id='d6e00000-0000-4000-8000-000000000101'
         AND version=2 AND publication_state='PUBLISHED_ANOMALY'
         AND current_publication_revision=1
     )
     OR NOT EXISTS(
       SELECT 1
       FROM editorial.publication_revision_owner_receipts_v2 AS receipt
       WHERE receipt.receipt_digest=
         (v_publish_result->>'receiptDigest')::char(64)
         AND receipt.mode='PUBLISH'
         AND receipt.receipt_digest=encode(
           extensions.digest(receipt.receipt_canonical,'sha256'),'hex'
         )
     ) THEN
    RAISE EXCEPTION 'r6d_named_person_override_publish_invalid';
  END IF;
  v_state_before:=pg_temp.r6d_control_publication_state_sha256();
  v_replay:=editorial.publish_guarded_revision_v2(v_publish_request);
  IF v_replay->>'replayed'<>'true'
     OR v_replay->>'receiptDigest'<>v_publish_result->>'receiptDigest'
     OR v_replay->'outboxEventIds'<>v_publish_result->'outboxEventIds'
     OR pg_temp.r6d_control_publication_state_sha256()<>v_state_before THEN
    RAISE EXCEPTION 'r6d_publish_exact_replay_not_zero_write';
  END IF;
  BEGIN
    PERFORM editorial.publish_guarded_revision_v2(
      v_publish_request||jsonb_build_object(
        '_requestSha256',
          pg_temp.r6d_control_publication_sha256('publish-divergent')
      )
    );
    RAISE EXCEPTION 'r6d_publish_divergent_replay_accepted';
  EXCEPTION WHEN SQLSTATE '40001' THEN NULL;
  END;
  IF pg_temp.r6d_control_publication_state_sha256()<>v_state_before THEN
    RAISE EXCEPTION 'r6d_publish_divergent_replay_not_zero_write';
  END IF;
END
$r6d_publication_owner_flow$;

-- A correction cannot reach its terminal publication fields without the exact
-- CORRECTION owner receipt.  This is a direct database-guard probe, not a
-- synthetic receipt seed.
INSERT INTO editorial.corrections(
  id,case_id,source_revision,summary,reason,affected_claim_ids,status,
  assigned_user_id,version,created_by,replacement_content,priority
)
VALUES(
  'd6e00000-0000-4000-8000-000000000401',
  'd6e00000-0000-4000-8000-000000000101',1,
  'R6d guarded correction','승인 전 정정',
  jsonb_build_array('d6e00000-0000-4000-8000-000000000201'),'REVIEW',
  'd6e00000-0000-4000-8000-000000000002',1,
  'd6e00000-0000-4000-8000-000000000001',
  jsonb_build_object(
    'summary','정정된 계약 자료',
    'claimReplacements',jsonb_build_array(jsonb_build_object(
      'claimId','d6e00000-0000-4000-8000-000000000201',
      'replacementText','정정된 계약 범위',
      'evidenceIds',jsonb_build_array(
        'd6e00000-0000-4000-8000-000000000202'
      ),'responseIds','[]'::jsonb,
      'limitations',jsonb_build_array('정정 공개 범위')
    )),
    'limitations',jsonb_build_array('정정 공개 범위'),
    'publicEvidenceIds',jsonb_build_array(
      'd6e00000-0000-4000-8000-000000000202'
    ),
    'effectiveReason','공식 자료 대조 결과'
  ),'NORMAL'
);

DO $r6d_correction_guard$
DECLARE
  v_before editorial.corrections%ROWTYPE;
  v_state_before char(64);
BEGIN
  SELECT * INTO STRICT v_before FROM editorial.corrections
  WHERE id='d6e00000-0000-4000-8000-000000000401';
  v_state_before:=pg_temp.r6d_control_publication_state_sha256();
  BEGIN
    UPDATE editorial.corrections
    SET status='PUBLISHED',resolution='RESOLVED',target_revision=2,
        resolution_reason='unauthorized correction publication',
        resolved_at=clock_timestamp(),version=version+1
    WHERE id=v_before.id;
    RAISE EXCEPTION 'r6d_correction_publication_guard_bypassed';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL;
  END;
  IF (SELECT to_jsonb(current_row) FROM editorial.corrections AS current_row
      WHERE current_row.id=v_before.id) IS DISTINCT FROM to_jsonb(v_before)
     OR pg_temp.r6d_control_publication_state_sha256()<>v_state_before THEN
    RAISE EXCEPTION 'r6d_correction_publication_guard_not_zero_write';
  END IF;
END
$r6d_correction_guard$;

-- A successful correction must create its own CORRECTION assessment over the
-- rebuilt public bytes.  PREVIEW/PUBLISH authority is never reusable here.
INSERT INTO editorial.review_snapshots(
  id,case_id,case_version,snapshot_sha256,snapshot_payload,
  automated_gate_results,unresolved_blockers,created_by
)
VALUES(
  'd6e00000-0000-4000-8000-000000000402',
  'd6e00000-0000-4000-8000-000000000101',2,repeat('d',64),
  '{"fixture":"R6D_CONTROL_CORRECTION"}',
  '{"namedPersonGate":"PENDING"}','[]',
  'd6e00000-0000-4000-8000-000000000001'
);
UPDATE editorial.cases
SET current_review_snapshot_id='d6e00000-0000-4000-8000-000000000402'
WHERE id='d6e00000-0000-4000-8000-000000000101' AND version=2;
INSERT INTO editorial.review_assignments(
  id,case_id,review_snapshot_id,reviewer_id,status,assigned_by,
  assigned_at,started_at,due_at,version
)
VALUES(
  'd6e00000-0000-4000-8000-000000000403',
  'd6e00000-0000-4000-8000-000000000101',
  'd6e00000-0000-4000-8000-000000000402',
  'd6e00000-0000-4000-8000-000000000002','IN_PROGRESS',
  'd6e00000-0000-4000-8000-000000000001',clock_timestamp(),
  clock_timestamp(),clock_timestamp()+interval '1 hour',1
);
INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,last_issued_at
)
VALUES(
  'd6e00000-0000-4000-8000-000000000404',
  'd6e00000-0000-4000-8000-000000000022',repeat('6',64),repeat('7',64),
  pg_temp.r6d_control_publication_sha256('correction-review-step-up'),
  transaction_timestamp()+interval '4 minutes',1,
  transaction_timestamp()-interval '1 second'
);

DO $r6d_correction_distinct_assessment$
DECLARE
  v_review_result jsonb;
  v_corrected_payload jsonb;
  v_scan jsonb;
  v_request jsonb;
  v_result jsonb;
  v_publish_assessment uuid;
BEGIN
  v_review_result:=editorial.record_named_person_review_stage_v1(
    jsonb_build_object(
      'decisionId','d6e00000-0000-4000-8000-000000000405',
      'reviewSnapshotId','d6e00000-0000-4000-8000-000000000402',
      'stage','EDITORIAL','decision','APPROVE',
      'reason','fixture correction approve','criteria','{}'::jsonb,
      'reviewerIndependence',jsonb_build_object(
        'independent',true,
        'snapshotCreatedBy','d6e00000-0000-4000-8000-000000000001',
        'reviewer','d6e00000-0000-4000-8000-000000000002'
      ),
      'reauthContextHash',repeat('f',64),
      'referencedEditorialDecisionId',NULL,
      '_actorId','d6e00000-0000-4000-8000-000000000002',
      '_actorAssertionJti','d6e00000-0000-4000-8000-000000000406',
      '_actorAssuranceLevel','STEP_UP',
      '_actorEffectiveCapability','review.editorial',
      '_actorActionDigest',repeat('6',64),
      '_actorStepUpAuthorizationId','d6e00000-0000-4000-8000-000000000404',
      '_actorIdempotencyKeySha256',repeat('7',64),
      '_actorRequestKeySha256',repeat('7',64),
      '_requestId','d6e00000-0000-4000-8000-000000000407',
      '_idempotencyKeySha256',repeat('7',64),
      '_requestSha256',repeat('8',64)
    )
  );
  IF v_review_result->>'replayed'<>'false' THEN
    RAISE EXCEPTION 'r6d_correction_editorial_stage_invalid';
  END IF;
  v_corrected_payload:=editorial.build_corrected_publication_payload_v2(
    'd6e00000-0000-4000-8000-000000000401',1,'정정 승인'
  );
  SELECT jsonb_build_object(
    'rulesetVersion',policy_payload->>'scannerRulesetVersion',
    'rulesetSha256',policy_payload->>'scannerRulesetSha256',
    'publicTextSha256',btrim(
      editorial.r6d_public_text_sha256_v1(v_corrected_payload)
    ),
    'registeredNameSetSha256',
      btrim(pg_temp.r6d_control_registered_person_set_sha256()),
    'findings','[]'::jsonb
  ) INTO STRICT v_scan
  FROM editorial.named_person_publication_policies
  WHERE policy_version='r6d-named-person-publication-v2' AND active;
  v_request:=jsonb_build_object(
    'mode','CORRECTION',
    'correctionId','d6e00000-0000-4000-8000-000000000401',
    'resolution','RESOLVED','reason','정정 승인','expectedVersion',1,
    'publicPayloadSha256',encode(extensions.digest(
      ops.canonical_jsonb_v1(v_corrected_payload),'sha256'),'hex'),
    'scan',v_scan,
    '_actorId','d6e00000-0000-4000-8000-000000000001',
    '_actorAssertionJti','d6e00000-0000-4000-8000-000000000408',
    '_actorAssuranceLevel','RECENT_SESSION',
    '_actorEffectiveCapability','publication.correct',
    '_actorActionDigest',repeat('9',64),
    '_actorStepUpAuthorizationId',NULL,
    '_actorIdempotencyKeySha256',repeat('e',64),
    '_actorRequestKeySha256',repeat('e',64),
    '_requestId','d6e00000-0000-4000-8000-000000000409',
    '_idempotencyKeySha256',repeat('e',64),
    '_requestSha256',
      pg_temp.r6d_control_publication_sha256('correction-request')
  );
  SELECT assessment_id INTO STRICT v_publish_assessment
  FROM editorial.publication_revision_owner_receipts_v2
  WHERE mode='PUBLISH'
    AND case_id='d6e00000-0000-4000-8000-000000000101';
  v_result:=editorial.publish_guarded_revision_v2(v_request);
  IF v_result->>'publicationState'<>'CORRECTED'
     OR jsonb_array_length(v_result->'outboxEventIds')<>4
     OR (v_result->>'assessmentId')::uuid=v_publish_assessment
     OR NOT EXISTS(
       SELECT 1
       FROM editorial.named_person_publication_assessments AS assessment
       WHERE assessment.assessment_id=(v_result->>'assessmentId')::uuid
         AND assessment.guard_context='CORRECTION'
         AND assessment.outcome='PASS' AND assessment.finding_count=0
         AND assessment.public_text_sha256=(v_scan->>'publicTextSha256')::char(64)
         AND NOT EXISTS(
           SELECT 1
           FROM editorial.named_person_publication_assessments AS earlier
           WHERE earlier.case_id=assessment.case_id
             AND earlier.guard_context IN ('PREVIEW','PUBLISH')
             AND earlier.public_text_sha256=assessment.public_text_sha256
         )
     )
     OR NOT EXISTS(
       SELECT 1 FROM editorial.publication_revision_owner_receipts_v2
       WHERE mode='CORRECTION'
         AND correction_id='d6e00000-0000-4000-8000-000000000401'
         AND assessment_id=(v_result->>'assessmentId')::uuid
         AND review_snapshot_id='d6e00000-0000-4000-8000-000000000402'
         AND source_review_snapshot_id='d6e00000-0000-4000-8000-000000000102'
     )
     OR NOT EXISTS(
       SELECT 1 FROM editorial.corrections
       WHERE id='d6e00000-0000-4000-8000-000000000401'
         AND status='PUBLISHED' AND resolution='RESOLVED'
         AND target_revision=2 AND version=2
     )
     OR NOT EXISTS(
       SELECT 1 FROM editorial.cases
       WHERE id='d6e00000-0000-4000-8000-000000000101'
         AND publication_state='CORRECTED'
         AND current_publication_revision=2 AND version=3
     ) THEN
    RAISE EXCEPTION 'r6d_correction_distinct_assessment_invalid';
  END IF;
END
$r6d_correction_distinct_assessment$;

CREATE TEMP TABLE r6d_control_publication_probe_state(
  key text PRIMARY KEY,
  value text NOT NULL
) ON COMMIT DROP;
GRANT SELECT ON r6d_control_publication_probe_state TO gurine_control_api;
INSERT INTO r6d_control_publication_probe_state(key,value)
VALUES(
  'legacy-before',btrim(pg_temp.r6d_control_publication_state_sha256())
);

-- Exercise the public OID retained by the pre-R6d dispatcher.  Every retired
-- publication operation must reject before any legacy DML.
SET LOCAL ROLE gurine_control_api;
DO $r6d_legacy_publication_side_doors$
DECLARE
  v_operation text;
  v_message text;
BEGIN
  FOREACH v_operation IN ARRAY ARRAY['submitReview','publishCase'] LOOP
    v_message:='r6d_publication_owner_required:'||v_operation;
    BEGIN
      PERFORM * FROM ops.apply_control_addendum_command(
        v_operation,'{}'::jsonb,
        'd6e00000-0000-4000-8000-000000000001',
        'd6e00000-0000-4000-8000-000000000021',gen_random_uuid(),
        pg_temp.r6d_control_publication_sha256('legacy-key:'||v_operation),
        pg_temp.r6d_control_publication_sha256(
          'legacy-request:'||v_operation
        )
      );
      RAISE EXCEPTION 'r6d_legacy_side_door_accepted:%',v_operation;
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM IS DISTINCT FROM v_message THEN RAISE; END IF;
    END;
  END LOOP;
  FOREACH v_operation IN ARRAY ARRAY[
    'createCorrectionCase','publishCorrection'
  ] LOOP
    v_message:='r6d_correction_publication_owner_required:'||v_operation;
    BEGIN
      PERFORM ops.apply_correction_publication_command_v1(
        v_operation,'{}'::jsonb,
        'd6e00000-0000-4000-8000-000000000001',
        'd6e00000-0000-4000-8000-000000000021',gen_random_uuid(),
        pg_temp.r6d_control_publication_sha256(
          'legacy-correction-key:'||v_operation
        ),
        pg_temp.r6d_control_publication_sha256(
          'legacy-correction-request:'||v_operation
        )
      );
      RAISE EXCEPTION 'r6d_legacy_correction_side_door_accepted:%',v_operation;
    EXCEPTION WHEN insufficient_privilege THEN
      IF SQLERRM IS DISTINCT FROM v_message THEN RAISE; END IF;
    END;
  END LOOP;
END
$r6d_legacy_publication_side_doors$;
RESET ROLE;

DO $r6d_legacy_publication_zero_write$
BEGIN
  IF (SELECT value FROM r6d_control_publication_probe_state
      WHERE key='legacy-before') IS DISTINCT FROM
       btrim(pg_temp.r6d_control_publication_state_sha256()) THEN
    RAISE EXCEPTION 'r6d_legacy_publication_side_door_not_zero_write';
  END IF;
END
$r6d_legacy_publication_zero_write$;

DO $r6d_publication_acl$
DECLARE
  v_relation text;
  v_privilege text;
BEGIN
  FOREACH v_relation IN ARRAY ARRAY[
    'editorial.review_decisions',
    'editorial.named_person_publication_assessments',
    'editorial.named_person_publication_findings',
    'editorial.named_person_legal_overrides',
    'editorial.named_person_review_stage_receipts_v1',
    'editorial.publication_preview_owner_receipts_v2',
    'editorial.publication_revision_owner_receipts_v2',
    'editorial.publication_previews',
    'editorial.publication_revisions'
  ] LOOP
    FOREACH v_privilege IN ARRAY ARRAY[
      'INSERT','UPDATE','DELETE','TRUNCATE'
    ] LOOP
      IF has_table_privilege(
           'gurine_control_api',v_relation,v_privilege
         ) THEN
        RAISE EXCEPTION 'r6d_publication_acl_open:%:%',
          v_relation,v_privilege;
      END IF;
    END LOOP;
  END LOOP;
  IF NOT has_function_privilege(
       'gurine_control_api',
       'editorial.preview_publication_guarded_v2(jsonb)','EXECUTE'
     )
     OR NOT has_function_privilege(
       'gurine_control_api',
       'editorial.record_named_person_review_stage_v1(jsonb)','EXECUTE'
     )
     OR NOT has_function_privilege(
       'gurine_control_api',
       'editorial.record_named_person_legal_override_v1(jsonb)','EXECUTE'
     )
     OR NOT has_function_privilege(
       'gurine_control_api',
       'editorial.publish_guarded_revision_v2(jsonb)','EXECUTE'
     ) THEN
    RAISE EXCEPTION 'r6d_publication_owner_execute_acl_missing';
  END IF;
  IF has_function_privilege(
       'gurine_control_api',
       'ops.apply_signal_publication_command_legacy_v1(text,jsonb,uuid,uuid,uuid,character,character)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'gurine_control_api',
       'ops.apply_correction_publication_command_legacy_v1(text,jsonb,uuid,uuid,uuid,character,character)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'r6d_retired_publication_owner_execute_acl_open';
  END IF;
  IF (SELECT array_agg(trigger.tgname ORDER BY trigger.tgname)
      FROM pg_trigger AS trigger
      WHERE trigger.tgrelid IN (
        'editorial.publication_previews'::regclass,
        'editorial.publication_revisions'::regclass,
        'editorial.cases'::regclass,
        'editorial.corrections'::regclass
      )
        AND NOT trigger.tgisinternal
        AND trigger.tgname LIKE '%r6d%guard') IS DISTINCT FROM
       ARRAY[
         'cases_r6d_publication_guard',
         'corrections_r6d_publication_guard',
         'publication_previews_r6d_guard',
         'publication_revisions_r6d_guard'
       ]::name[] THEN
    RAISE EXCEPTION 'r6d_publication_guard_trigger_inventory_drift';
  END IF;
END
$r6d_publication_acl$;

-- Permission introspection above is backed by real API-role DML attempts on
-- the four immutable archive/receipt boundaries.
SET LOCAL ROLE gurine_control_api;
DO $r6d_publication_direct_dml$
DECLARE
  v_relation text;
BEGIN
  FOREACH v_relation IN ARRAY ARRAY[
    'editorial.named_person_legal_overrides',
    'editorial.named_person_review_stage_receipts_v1',
    'editorial.publication_preview_owner_receipts_v2',
    'editorial.publication_revision_owner_receipts_v2'
  ] LOOP
    BEGIN
      EXECUTE format('INSERT INTO %s DEFAULT VALUES',v_relation);
      RAISE EXCEPTION 'r6d_publication_direct_insert_accepted:%',v_relation;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
END
$r6d_publication_direct_dml$;
RESET ROLE;

SET CONSTRAINTS ALL IMMEDIATE;
DO $$
BEGIN
  RAISE NOTICE
    'R6D_CONTROL_PUBLICATION: PASS scan-tamper+named-block+override+replay+side-door+distinct-correction+ACL';
END
$$;
ROLLBACK;
