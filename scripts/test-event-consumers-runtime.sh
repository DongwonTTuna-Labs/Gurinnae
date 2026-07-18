#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-event-consumers-$BASHPID"
database="gurine_event_consumers"
work="$(mktemp -d -t gurine-event-consumers-XXXXXX)"
clamav_pid=""
smtp_pid=""

cleanup() {
  status=$?
  trap - EXIT
  [[ -z "$clamav_pid" ]] || kill "$clamav_pid" >/dev/null 2>&1 || true
  [[ -z "$smtp_pid" ]] || kill "$smtp_pid" >/dev/null 2>&1 || true
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

cd "$root"
cargo build -p gurine-scheduler -p gurine-workflow-worker -p gurine-notification-worker \
  -p gurine-acceptance-tests --bins

docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
for migration in db/migrations/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <"$migration" >/dev/null
done
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "ALTER ROLE gurine_scheduler LOGIN PASSWORD 'scheduler_test'; ALTER ROLE gurine_workflow_worker LOGIN PASSWORD 'workflow_test'; ALTER ROLE gurine_notification_worker LOGIN PASSWORD 'notification_test';" >/dev/null

raw_key="01234567890123456789012345678901"
test_key="$(printf '%s' "$raw_key" | base64 -w0)"
encrypt() {
  FIELD_KEY_BASE64="$test_key" FIELD_TABLE="$1" FIELD_COLUMN="$2" \
    FIELD_RECORD_ID="$3" FIELD_LOGICAL_TYPE="$4" FIELD_PLAINTEXT="$5" \
    target/debug/field-envelope
}

request_id="31000000-0000-4000-8000-000000000010"
subscription_pending="31000000-0000-4000-8000-000000000020"
subscription_active="31000000-0000-4000-8000-000000000021"
correction_id="31000000-0000-4000-8000-000000000030"
request_email="$(encrypt editorial.response_requests recipient_email_encrypted "$request_id" email-address respondent@example.test)"
pending_email="$(encrypt intake.subscriptions email_encrypted "$subscription_pending" email-address pending@example.test)"
active_email="$(encrypt intake.subscriptions email_encrypted "$subscription_active" email-address active@example.test)"
correction_email="$(encrypt intake.correction_requests contact_email_encrypted "$correction_id" email-address correction@example.test)"
agent_output='{"suggestions":[]}'
agent_digest="$(printf '%s' "$agent_output" | sha256sum | cut -d' ' -f1)"

mkdir -p "$work/objects/uploads"
printf 'response attachment clean bytes' >"$work/objects/uploads/response.txt"
printf 'correction attachment clean bytes' >"$work/objects/uploads/correction.txt"
response_sha="$(sha256sum "$work/objects/uploads/response.txt" | cut -d' ' -f1)"
correction_sha="$(sha256sum "$work/objects/uploads/correction.txt" | cut -d' ' -f1)"
response_size="$(stat -c %s "$work/objects/uploads/response.txt")"
correction_size="$(stat -c %s "$work/objects/uploads/correction.txt")"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -v request_email="$request_email" -v pending_email="$pending_email" \
  -v active_email="$active_email" -v correction_email="$correction_email" \
  -v agent_digest="$agent_digest" -v agent_output="$agent_output" \
  -v response_sha="$response_sha" -v correction_sha="$correction_sha" \
  -v response_size="$response_size" -v correction_size="$correction_size" <<'SQL' >/dev/null
INSERT INTO ops.users(id,oidc_subject,email,display_name,status) VALUES
 ('31000000-0000-4000-8000-000000000001','event-publisher','publisher@example.test','Event Publisher','ACTIVE'),
 ('31000000-0000-4000-8000-000000000002','event-reviewer','reviewer@example.test','Event Reviewer','ACTIVE'),
 ('31000000-0000-4000-8000-000000000003','event-invitee','invitee@example.test','Event Invitee','INVITED');
INSERT INTO editorial.cases(id,public_slug,title,investigation_state,publication_state,summary,version)
VALUES('31000000-0000-4000-8000-000000000004','event-case','Event consumer case','READY_TO_PUBLISH','PUBLISHED_ANOMALY','Event consumer integration',1);
INSERT INTO editorial.review_snapshots(id,case_id,case_version,snapshot_sha256,snapshot_payload,automated_gate_results,created_by)
VALUES('31000000-0000-4000-8000-000000000005','31000000-0000-4000-8000-000000000004',1,repeat('1',64),'{}','{}','31000000-0000-4000-8000-000000000001');
UPDATE editorial.cases SET current_review_snapshot_id='31000000-0000-4000-8000-000000000005'
 WHERE id='31000000-0000-4000-8000-000000000004';
INSERT INTO editorial.review_decisions(review_snapshot_id,reviewer_id,decision,reason,criteria,reviewer_independence,reauth_context_hash)
VALUES('31000000-0000-4000-8000-000000000005','31000000-0000-4000-8000-000000000002','APPROVE','Event fixture approval','{}','{"independent":true}',repeat('2',64));
INSERT INTO editorial.publication_previews(case_id,review_snapshot_id,locale,preview_payload,preview_sha256,expires_at,created_by)
VALUES('31000000-0000-4000-8000-000000000004','31000000-0000-4000-8000-000000000005','event','{}','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',clock_timestamp()+interval '1 hour','31000000-0000-4000-8000-000000000001');
INSERT INTO editorial.publication_revisions(id,case_id,revision,state,review_snapshot_id,public_payload,public_payload_sha256,preview_sha256,published_by)
VALUES('31000000-0000-4000-8000-000000000006','31000000-0000-4000-8000-000000000004',1,'PUBLISHED_ANOMALY','31000000-0000-4000-8000-000000000005','{}','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','31000000-0000-4000-8000-000000000001');

INSERT INTO editorial.response_requests(id,case_id,party_type,party_name,recipient_email_hash,recipient_email_encrypted,questions,requested_publication_scope,due_at,status,created_by)
VALUES('31000000-0000-4000-8000-000000000010','31000000-0000-4000-8000-000000000004','OTHER','Event Respondent',repeat('3',64),:'request_email','["Please respond"]','{}',clock_timestamp()+interval '7 days','SENT','31000000-0000-4000-8000-000000000001');
INSERT INTO intake.response_submissions(id,response_request_id,draft_version,submission_sha256,answers_encrypted,publication_consent,status,receipt_token_hash)
VALUES('31000000-0000-4000-8000-000000000011','31000000-0000-4000-8000-000000000010',1,repeat('4',64),decode('00','hex'),'{}','SUBMITTED',repeat('5',64));
INSERT INTO intake.response_attachments(id,response_request_id,original_filename_encrypted,media_type,size_bytes,sha256,object_key,upload_status,scan_status)
VALUES('31000000-0000-4000-8000-000000000012','31000000-0000-4000-8000-000000000010',decode('00','hex'),'text/plain',:'response_size',:'response_sha','uploads/response.txt','FINALIZED','PENDING');
INSERT INTO intake.response_extension_requests(id,response_request_id,requested_due_at,reason,status)
VALUES('31000000-0000-4000-8000-000000000013','31000000-0000-4000-8000-000000000010',clock_timestamp()+interval '10 days','Event extension','SUBMITTED');

INSERT INTO intake.correction_requests(id,requester_type,contact_email_hash,contact_email_encrypted,summary,requested_changes,status,receipt_token_hash)
VALUES('31000000-0000-4000-8000-000000000030','OTHER',repeat('6',64),:'correction_email','Event correction','["Correct this"]','SUBMITTED',repeat('7',64));
INSERT INTO intake.correction_request_drafts(id,token_hash,requested_changes,expires_at)
VALUES('31000000-0000-4000-8000-000000000033',NULL,'[]',clock_timestamp()+interval '1 day');
INSERT INTO intake.correction_draft_attachments(id,draft_id,original_filename_encrypted,media_type,size_bytes,sha256,object_key,upload_status,scan_status)
VALUES('31000000-0000-4000-8000-000000000031','31000000-0000-4000-8000-000000000033',decode('00','hex'),'text/plain',:'correction_size',:'correction_sha','uploads/correction.txt','FINALIZED','PENDING');
INSERT INTO intake.contact_requests(id,category,name_encrypted,email_hash,email_encrypted,subject,message_encrypted,status,receipt_token_hash)
VALUES('31000000-0000-4000-8000-000000000040','GENERAL',decode('00','hex'),repeat('8',64),decode('00','hex'),'<strong>Event & contact</strong>',decode('00','hex'),'RECEIVED',repeat('9',64));
INSERT INTO intake.subscriptions(id,email_hash,email_encrypted,topics,frequency,locale,status,management_token_hash) VALUES
 ('31000000-0000-4000-8000-000000000020',repeat('a',64),:'pending_email','["ALL"]','IMMEDIATE','ko-KR','PENDING',repeat('b',64)),
 ('31000000-0000-4000-8000-000000000021',repeat('c',64),:'active_email','["ALL"]','IMMEDIATE','ko-KR','ACTIVE',repeat('d',64));

INSERT INTO ops.source_registry(source_id,display_name,connector_type,owner_team,enabled,schedule_cron,legal_status,configuration)
VALUES('event-source','Event Source','HTTP','EVENT',true,'0 * * * *','APPROVED','{}');
INSERT INTO ops.schema_drifts(id,source_id,detected_at,fingerprint_after,status,impact)
VALUES('31000000-0000-4000-8000-000000000050','event-source',clock_timestamp(),repeat('e',64),'OPEN','HIGH');
INSERT INTO core.rule_versions(id,rule_id,version,name,description,configuration,code_digest,status)
VALUES('31000000-0000-4000-8000-000000000060','event-rule','1.0.0','Event rule','Event rule','{}',repeat('f',64),'ACTIVE');
INSERT INTO core.rule_runs(id,rule_version_id,run_key,input_snapshot_at,input_digest,started_at,completed_at,status)
VALUES('31000000-0000-4000-8000-000000000061','31000000-0000-4000-8000-000000000060','event-run',clock_timestamp(),repeat('1',64),clock_timestamp(),clock_timestamp(),'SUCCEEDED');
INSERT INTO core.anomaly_signals(id,rule_run_id,rule_version_id,signal_type,target_type,target_id,severity,status,explanation,calculation)
VALUES('31000000-0000-4000-8000-000000000062','31000000-0000-4000-8000-000000000061','31000000-0000-4000-8000-000000000060','EVENT','CASE','31000000-0000-4000-8000-000000000004','HIGH','NEW','{}','{}');
INSERT INTO ops.agent_runs(id,case_id,agent_type,objective,evidence_scope_ids,provider_policy,status,input_snapshot_hash,output_payload,output_schema_version,max_cost,actual_cost,completed_at,created_by)
VALUES('31000000-0000-4000-8000-000000000070','31000000-0000-4000-8000-000000000004','skeptic','Event agent','[]','LOCAL_ONLY','SUCCEEDED',repeat('2',64),:'agent_output','v1',10,1,clock_timestamp(),'31000000-0000-4000-8000-000000000001');
INSERT INTO ops.agent_suggestions(id,agent_run_id,case_id,suggestion_type,payload,evidence_ids,citation_checks,status)
VALUES('31000000-0000-4000-8000-000000000071','31000000-0000-4000-8000-000000000070','31000000-0000-4000-8000-000000000004','EVENT','{}','[]','[]','PENDING');
INSERT INTO ops.audit_events(id,occurred_at,actor_type,actor_id,action,object_type,object_id,outcome,request_id,details,event_hash)
VALUES('31000000-0000-4000-8000-000000000080',clock_timestamp(),'USER','event-user','event.action','case','31000000-0000-4000-8000-000000000004','SUCCESS','31000000-0000-4000-8000-000000000081','{}',repeat('3',64));
INSERT INTO ops.audit_exports(id,requested_by,from_at,to_at,format,scope,reason,watermark_policy,status,expires_at)
VALUES('31000000-0000-4000-8000-000000000082','31000000-0000-4000-8000-000000000001',clock_timestamp()-interval '1 day',clock_timestamp()+interval '1 minute','JSONL','GLOBAL','Event audit export','ACTOR_AND_TIME','QUEUED',clock_timestamp()+interval '1 day');
INSERT INTO public.datasets(id,title,description,format,coverage,license,updated_at)
VALUES('event-dataset','Event Dataset','Event dataset export','PARQUET','{}','CC-BY-4.0',clock_timestamp());
INSERT INTO intake.dataset_export_requests(id,request_token_hash,dataset_id,format,filters,status,expires_at)
VALUES('31000000-0000-4000-8000-000000000090',repeat('4',64),'event-dataset','PARQUET','{}','QUEUED',clock_timestamp()+interval '1 day');

SELECT ops.enqueue_outbox('agent_run','31000000-0000-4000-8000-000000000070',1,'agent.run_completed.v1',jsonb_build_object('agent_run_id','31000000-0000-4000-8000-000000000070','case_id','31000000-0000-4000-8000-000000000004','output_digest',:'agent_digest','status','SUCCEEDED'),clock_timestamp());
SELECT ops.enqueue_outbox('attachment','31000000-0000-4000-8000-000000000031',1,'attachment.correction_scan_requested.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','finalizeCorrectionAttachment','requestId','31000000-0000-4000-8000-0000000000a1','request_id','31000000-0000-4000-8000-0000000000a1'),clock_timestamp());
SELECT ops.enqueue_outbox('attachment','31000000-0000-4000-8000-000000000012',1,'attachment.response_scan_requested.v1',jsonb_build_object('actor_id','anonymous','attachmentId','31000000-0000-4000-8000-000000000012','occurred_at','2026-07-12T00:00:00Z','operation_id','finalizeResponseAttachment','requestToken','redacted','request_id','31000000-0000-4000-8000-0000000000a2'),clock_timestamp());
SELECT ops.enqueue_outbox('audit_export','31000000-0000-4000-8000-000000000082',1,'audit.export_requested.v1',jsonb_build_object('auditExportId','31000000-0000-4000-8000-000000000082','requestedBy','31000000-0000-4000-8000-000000000001','from','2026-07-11T00:00:00Z','to','2026-07-13T00:00:00Z','format','JSONL','scope','GLOBAL','reason','Event audit export','watermarkPolicy','ACTOR_AND_TIME','expiresAt','2026-07-13T00:00:00Z'),clock_timestamp());
SELECT ops.enqueue_outbox('signal','31000000-0000-4000-8000-000000000062',1,'detection.signal_created.v1',jsonb_build_object('rule_version_id','31000000-0000-4000-8000-000000000060','signal_id','31000000-0000-4000-8000-000000000062','target_id','31000000-0000-4000-8000-000000000004'),clock_timestamp());
SELECT ops.enqueue_outbox('dataset_export','31000000-0000-4000-8000-000000000090',1,'export.dataset_requested.v1',jsonb_build_object('actor_id','anonymous','dataset_id','event-dataset','occurred_at','2026-07-12T00:00:00Z','operation_id','createDatasetExport','request_id','31000000-0000-4000-8000-0000000000a3'),clock_timestamp());
SELECT ops.enqueue_outbox('schema_drift','31000000-0000-4000-8000-000000000050',1,'source.schema_drift_detected.v1',jsonb_build_object('fingerprint_after',repeat('e',64),'schema_drift_id','31000000-0000-4000-8000-000000000050','source_id','event-source'),clock_timestamp());
SELECT ops.enqueue_outbox('response_submission','31000000-0000-4000-8000-000000000011',1,'workflow.response_submitted.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','submitResponse','requestToken','redacted','request_id','31000000-0000-4000-8000-0000000000a4'),clock_timestamp());
SQL

postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_INSTANCE_ID="event-test" SCHEDULER_ONCE=true target/debug/gurine-scheduler

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE queue='workflow-worker' AND job_type='EVENT_DELIVERY' AND status='QUEUED';
  IF actual <> 8 THEN RAISE EXCEPTION 'queued workflow event jobs %, expected 8',actual; END IF;
  SELECT count(*) INTO actual FROM ops.inbox WHERE consumer='workflow-worker';
  IF actual <> 8 THEN RAISE EXCEPTION 'dispatched workflow inbox %, expected 8',actual; END IF;
END $$;
SET ROLE gurine_workflow_worker;
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.jobs j
  LEFT JOIN ops.queue_controls q ON q.queue_name=j.queue
  WHERE j.queue='workflow-worker' AND j.status='QUEUED' AND j.run_after<=clock_timestamp()
    AND COALESCE(q.state,'RUNNING')='RUNNING';
  IF actual <> 8 THEN RAISE EXCEPTION 'workflow-role claimable event jobs %, expected 8',actual; END IF;
END $$;
RESET ROLE;
SQL

clamav_port="$(free_port)"
PYTHONDONTWRITEBYTECODE=1 FAKE_CLAMAV_PORT="$clamav_port" python3 scripts/test-support/fake-clamav.py &
clamav_pid=$!
sleep 0.2
GURINE_ENV=development WORKFLOW_DATABASE_URL="postgresql://gurine_workflow_worker:workflow_test@127.0.0.1:${postgres_port}/${database}" \
OBJECT_STORE_ADAPTER=filesystem OBJECT_STORE_FILESYSTEM_ROOT="$work/objects" \
CLAMAV_HOST=127.0.0.1 CLAMAV_PORT="$clamav_port" WORKFLOW_ONCE=true \
HOSTNAME="workflow-event-test" target/debug/gurine-workflow-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE queue='workflow-worker' AND job_type='EVENT_DELIVERY' AND status='SUCCEEDED';
  IF actual <> 8 THEN
    RAISE NOTICE 'workflow job states: %',(
      SELECT jsonb_object_agg(status,count) FROM (
        SELECT status,count(*) FROM ops.jobs WHERE queue='workflow-worker' GROUP BY status
      ) states
    );
    RAISE NOTICE 'workflow incomplete jobs: %',(
      SELECT jsonb_agg(jsonb_build_object(
        'eventType',payload->>'eventType','status',status,'errorCode',last_error_code,
        'errorDetail',last_error_detail,'attempts',attempt_count,'runAfter',run_after
      ) ORDER BY created_at,id)
      FROM ops.jobs WHERE queue='workflow-worker' AND status<>'SUCCEEDED'
    );
    RAISE EXCEPTION 'succeeded workflow event jobs %, expected 8',actual;
  END IF;
END $$;
SQL

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
SELECT ops.enqueue_outbox('contact_request','31000000-0000-4000-8000-000000000040',1,'intake.contact_received.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','createContactRequest','request_id','31000000-0000-4000-8000-0000000000b1'),clock_timestamp());
SELECT ops.enqueue_outbox('correction_request','31000000-0000-4000-8000-000000000030',1,'notification.correction_received.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','createCorrectionRequest','request_id','31000000-0000-4000-8000-0000000000b2'),clock_timestamp());
SELECT ops.enqueue_outbox('correction','31000000-0000-4000-8000-000000000032',1,'notification.correction_resolved.v1',jsonb_build_object('actor_id','31000000-0000-4000-8000-000000000001','correction_id','31000000-0000-4000-8000-000000000032','occurred_at','2026-07-12T00:00:00Z','operation_id','resolveCorrectionRequest','request_id','31000000-0000-4000-8000-0000000000b3'),clock_timestamp());
SELECT ops.enqueue_outbox('case','31000000-0000-4000-8000-000000000004',1,'notification.publication_created.v1',jsonb_build_object('actor_id','31000000-0000-4000-8000-000000000001','caseId','31000000-0000-4000-8000-000000000004','occurred_at','2026-07-12T00:00:00Z','operation_id','publishCase','request_id','31000000-0000-4000-8000-0000000000b4','reviewSnapshotId','31000000-0000-4000-8000-000000000005'),clock_timestamp());
SELECT ops.enqueue_outbox('response_extension','31000000-0000-4000-8000-000000000013',1,'notification.response_extension_requested.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','requestResponseExtension','requestToken','redacted','request_id','31000000-0000-4000-8000-0000000000b5'),clock_timestamp());
SELECT ops.enqueue_outbox('response_request','31000000-0000-4000-8000-000000000010',1,'notification.response_request_delivery_requested.v1',jsonb_build_object('actor_id','31000000-0000-4000-8000-000000000001','caseId','31000000-0000-4000-8000-000000000004','occurred_at','2026-07-12T00:00:00Z','operation_id','createResponseRequest','request_id','31000000-0000-4000-8000-0000000000b6'),clock_timestamp());
SELECT ops.enqueue_outbox('response_submission','31000000-0000-4000-8000-000000000011',1,'notification.response_submitted.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','submitResponse','requestToken','redacted','request_id','31000000-0000-4000-8000-0000000000b7'),clock_timestamp());
SELECT ops.enqueue_outbox('subscription','31000000-0000-4000-8000-000000000020',1,'notification.subscription_verification_requested.v1',jsonb_build_object('actor_id','anonymous','occurred_at','2026-07-12T00:00:00Z','operation_id','createSubscription','request_id','31000000-0000-4000-8000-0000000000b8'),clock_timestamp());
SELECT ops.enqueue_outbox('user','31000000-0000-4000-8000-000000000003',1,'notification.user_invitation_requested.v1',jsonb_build_object('actor_id','31000000-0000-4000-8000-000000000001','occurred_at','2026-07-12T00:00:00Z','operation_id','inviteUser','request_id','31000000-0000-4000-8000-0000000000b9'),clock_timestamp());
SELECT ops.enqueue_outbox('publication_revision','31000000-0000-4000-8000-000000000006',1,'projection.publication_applied.v1',jsonb_build_object('public_payload_sha256','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a','publication_revision_id','31000000-0000-4000-8000-000000000006'),clock_timestamp());
SQL

SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_INSTANCE_ID="event-test" SCHEDULER_ONCE=true target/debug/gurine-scheduler

smtp_port="$(free_port)"
: >"$work/smtp.jsonl"
FAKE_SMTP_PORT="$smtp_port" FAKE_SMTP_OUTPUT="$work/smtp.jsonl" \
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-support/fake-smtp-gateway.py &
smtp_pid=$!
sleep 0.2
NOTIFICATION_DATABASE_URL="postgresql://gurine_notification_worker:notification_test@127.0.0.1:${postgres_port}/${database}" \
FIELD_ENCRYPTION_KEY_CURRENT="$test_key" TOKEN_HMAC_KEY="$test_key" \
EGRESS_SMTP_CHANNEL_URL="http://127.0.0.1:${smtp_port}/smtp" \
EMAIL_FROM="gurine@example.test" EMAIL_REPLY_TO="ops@example.test" \
PUBLIC_BASE_URL="https://public.example.test" RESPONSE_BASE_URL="https://response.example.test" \
EMAIL_ADAPTER=smtp NOTIFICATION_ONCE=true HOSTNAME="notification-event-test" target/debug/gurine-notification-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.inbox WHERE consumer='workflow-worker' AND processed_at IS NOT NULL;
  IF actual <> 8 THEN RAISE EXCEPTION 'workflow inbox %, expected 8',actual; END IF;
  SELECT count(*) INTO actual FROM ops.inbox WHERE consumer='notification-worker' AND processed_at IS NOT NULL;
  IF actual <> 12 THEN RAISE EXCEPTION 'notification inbox %, expected 12',actual; END IF;
  IF (SELECT status FROM ops.audit_exports WHERE id='31000000-0000-4000-8000-000000000082') <> 'READY' THEN
    RAISE EXCEPTION 'audit export not ready'; END IF;
  IF (SELECT status FROM intake.dataset_export_requests WHERE id='31000000-0000-4000-8000-000000000090') <> 'READY' THEN
    RAISE EXCEPTION 'dataset export not ready'; END IF;
  IF (SELECT enabled FROM ops.source_registry WHERE source_id='event-source') THEN
    RAISE EXCEPTION 'schema drift did not pause source'; END IF;
  IF (SELECT editorial_response_id FROM intake.response_submissions WHERE id='31000000-0000-4000-8000-000000000011') IS NULL THEN
    RAISE EXCEPTION 'response submission was not materialized'; END IF;
  SELECT count(*) INTO actual FROM ops.tasks WHERE task_type IN ('AGENT_REVIEW','SIGNAL_TRIAGE','SCHEMA_DRIFT');
  IF actual <> 3 THEN RAISE EXCEPTION 'workflow tasks %, expected 3',actual; END IF;
  IF (SELECT scan_status FROM intake.response_attachments WHERE id='31000000-0000-4000-8000-000000000012') <> 'CLEAN'
     OR (SELECT scan_status FROM intake.correction_draft_attachments WHERE id='31000000-0000-4000-8000-000000000031') <> 'CLEAN' THEN
    RAISE EXCEPTION 'attachment scans did not complete'; END IF;
  SELECT count(*) INTO actual FROM ops.email_deliveries WHERE status='DELIVERED';
  IF actual <> 11 THEN RAISE EXCEPTION 'delivered emails %, expected 11',actual; END IF;
  SELECT count(*) INTO actual FROM intake.response_access_tokens WHERE response_request_id='31000000-0000-4000-8000-000000000010';
  IF actual <> 1 THEN RAISE EXCEPTION 'response access tokens %, expected 1',actual; END IF;
END $$;
SQL

test "$(find "$work/objects/exports" -type f | wc -l)" -eq 2
parquet_file="$(find "$work/objects/exports/datasets" -type f -name '*.parquet' -print -quit)"
test -n "$parquet_file"
test "$(head -c 4 "$parquet_file")" = "PAR1"
test "$(tail -c 4 "$parquet_file")" = "PAR1"
test "$(wc -l <"$work/smtp.jsonl")" -eq 11
SMTP_CAPTURE="$work/smtp.jsonl" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import json
import os

with open(os.environ["SMTP_CAPTURE"], encoding="utf-8") as stream:
    messages = [json.loads(line) for line in stream]
contact = next(message for message in messages if message["subject"] == "구린네 새 문의 접수")
expected_subject = "<strong>Event & contact</strong>"
assert contact["text_body"].endswith(f"제목: {expected_subject}"), contact["text_body"]
assert contact["html_body"] == (
    "<p>새 문의가 접수되었습니다.</p>"
    "<p>ID: 31000000-0000-4000-8000-000000000040</p>"
    "<p>제목: &lt;strong&gt;Event &amp; contact&lt;/strong&gt;</p>"
), contact["html_body"]
assert expected_subject not in contact["html_body"], contact["html_body"]

subscription = next(message for message in messages if message["subject"] == "구린네 구독 확인")
assert "https://public.example.test/subscribe?token=" in subscription["text_body"], subscription["text_body"]
assert "https://public.example.test/subscribe?token=" in subscription["html_body"], subscription["html_body"]
assert "/subscription/verify" not in subscription["text_body"], subscription["text_body"]
assert "/subscription/verify" not in subscription["html_body"], subscription["html_body"]

response_request = next(message for message in messages if message["subject"] == "구린네 소명 요청")
assert "https://response.example.test/respond/access?token=" in response_request["text_body"], response_request["text_body"]
assert "https://response.example.test/respond/access?token=" in response_request["html_body"], response_request["html_body"]
assert "https://response.example.test/respond?token=" not in response_request["text_body"], response_request["text_body"]
assert "https://response.example.test/respond?token=" not in response_request["html_body"], response_request["html_body"]
PY
echo "workflow 8-event and notification 11-type fenced PostgreSQL/object-store/ClamAV/SMTP runtime: PASS"
