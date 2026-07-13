DO $$
DECLARE
  actual bigint;
BEGIN
  SELECT version INTO actual FROM editorial.cases WHERE id='148b09d5-aa28-5351-b471-9ef333a3e410';
  IF actual <> 14 THEN RAISE EXCEPTION 'case canonical version %, expected 14', actual; END IF;
  SELECT version INTO actual FROM core.anomaly_signals WHERE id='641fc905-1d30-5062-b0e6-9fbb468502c4';
  IF actual <> 5 THEN RAISE EXCEPTION 'signal canonical version %, expected 5', actual; END IF;
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
  IF actual <> 1 THEN RAISE EXCEPTION 'access request rows %, expected 1', actual; END IF;
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
  IF actual <> 3 THEN RAISE EXCEPTION 'case evidence %, expected 3', actual; END IF;
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
  IF actual <> 2 THEN RAISE EXCEPTION 'agent run rows %, expected 2', actual; END IF;
  SELECT count(*) INTO actual FROM core.rule_evaluations;
  IF actual <> 4 THEN RAISE EXCEPTION 'rule evaluation rows %, expected 4', actual; END IF;

  SELECT count(*) INTO actual FROM ops.schema_mappings
   WHERE (schema_drift_id='b085a8f4-6a10-508b-b5af-932cc2e4302a' AND status='APPROVED')
      OR (schema_drift_id='a8dd0f25-7ce3-5ca9-84a4-317e1e0ef474' AND status='REJECTED');
  IF actual <> 2 THEN RAISE EXCEPTION 'schema mapping decisions %, expected 2', actual; END IF;
  IF (SELECT status FROM ops.schema_drifts WHERE id='b085a8f4-6a10-508b-b5af-932cc2e4302a') <> 'APPROVED'
     OR (SELECT status FROM ops.schema_drifts WHERE id='a8dd0f25-7ce3-5ca9-84a4-317e1e0ef474') <> 'REJECTED' THEN
    RAISE EXCEPTION 'schema drift terminal decisions were not persisted';
  END IF;

  SELECT count(*) INTO actual FROM editorial.response_requests
   WHERE case_id='148b09d5-aa28-5351-b471-9ef333a3e410';
  IF actual <> 2 THEN RAISE EXCEPTION 'response request rows %, expected 2', actual; END IF;
  SELECT count(*) INTO actual FROM editorial.response_requests
   WHERE convert_from(recipient_email_encrypted,'UTF8') LIKE 'gurine-fe-v1.%'
     AND octet_length(recipient_email_encrypted) > 40;
  IF actual <> 2 THEN RAISE EXCEPTION 'encrypted response recipient rows %, expected 2', actual; END IF;
  IF (SELECT public_excerpt_sha256 FROM editorial.responses
      WHERE id='6267870b-97d8-51c0-aa38-030abefcc483') <>
     '1a9df3dac325be36a6591593c431fae6abd98358330e9d87615fbd9441820cf7' THEN
    RAISE EXCEPTION 'response excerpt approval hash was not persisted';
  END IF;

  SELECT count(*) INTO actual FROM ops.source_runs;
  IF actual <> 6 THEN RAISE EXCEPTION 'source run rows %, expected 6', actual; END IF;
  SELECT count(*) INTO actual FROM ops.source_runs WHERE retry_of_source_run_id IS NOT NULL AND status='QUEUED';
  IF actual <> 1 THEN RAISE EXCEPTION 'source retry rows %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.source_runs
   WHERE (source_id='control-backfill-source' AND mode='DRY_RUN' AND status='QUEUED')
      OR (source_id='control-run-source' AND mode='INCREMENTAL' AND status='QUEUED')
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

  SELECT count(*) INTO actual FROM ops.audit_exports;
  IF actual <> 2 THEN RAISE EXCEPTION 'audit export rows %, expected 2', actual; END IF;
  SELECT count(*) INTO actual FROM ops.jobs WHERE job_type='AUDIT_EXPORT' AND queue='audit-export';
  IF actual <> 1 THEN RAISE EXCEPTION 'audit export jobs %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM editorial.legal_holds WHERE active;
  IF actual <> 1 THEN RAISE EXCEPTION 'active legal hold rows %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.audit_events WHERE action LIKE 'command.%';
  IF actual <> 77 THEN RAISE EXCEPTION 'command audit rows %, expected 77', actual; END IF;
  SELECT count(*) INTO actual FROM ops.outbox;
  IF actual <> 9 THEN RAISE EXCEPTION 'control outbox rows %, expected 9', actual; END IF;

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
