#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-worker-failure-$BASHPID"
database="gurine_worker_failure"
work="$(mktemp -d -t gurine-worker-failure-XXXXXX)"
smtp_pid=""

cleanup() {
  status=$?
  trap - EXIT
  [[ -z "$smtp_pid" ]] || kill "$smtp_pid" >/dev/null 2>&1 || true
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

run_ingest() {
  GURINE_ENV=test \
  INGEST_DATABASE_URL="postgresql://gurine_ingest_worker:ingest_test@127.0.0.1:${postgres_port}/${database}" \
  OBJECT_STORE_ADAPTER=filesystem OBJECT_STORE_FILESYSTEM_ROOT="$work/ingest-objects" \
  EGRESS_SOURCE_CHANNEL_URL="http://127.0.0.1:${dead_source_port}/source" \
  INGEST_ONCE=true HOSTNAME="ingest-failure-test" target/debug/gurine-ingest-worker
}

run_workflow() {
  GURINE_ENV=test \
  WORKFLOW_DATABASE_URL="postgresql://gurine_workflow_worker:workflow_test@127.0.0.1:${postgres_port}/${database}" \
  OBJECT_STORE_ADAPTER=filesystem OBJECT_STORE_FILESYSTEM_ROOT="$work/workflow-objects" \
  CLAMAV_HOST=127.0.0.1 CLAMAV_PORT=9 \
  WORKFLOW_ONCE=true HOSTNAME="workflow-failure-test" target/debug/gurine-workflow-worker
}

run_projector() {
  PROJECTOR_DATABASE_URL="postgresql://gurine_public_projector:projector_test@127.0.0.1:${postgres_port}/${database}" \
  PROJECTOR_ONCE=true HOSTNAME="projector-failure-test" target/debug/gurine-projection-worker
}

run_notification() {
  local smtp_port="$1"
  NOTIFICATION_DATABASE_URL="postgresql://gurine_notification_worker:notification_test@127.0.0.1:${postgres_port}/${database}" \
  FIELD_ENCRYPTION_KEY_CURRENT="$test_key" TOKEN_HMAC_KEY="$test_key" \
  EMAIL_ADAPTER=smtp \
  EGRESS_SMTP_CHANNEL_URL="http://127.0.0.1:${smtp_port}/smtp" \
  EMAIL_FROM="gurine@example.test" EMAIL_REPLY_TO="ops@example.test" \
  PUBLIC_BASE_URL="https://public.example.test" RESPONSE_BASE_URL="https://response.example.test" \
  NOTIFICATION_ONCE=true HOSTNAME="notification-failure-test" target/debug/gurine-notification-worker
}

cd "$root"
cargo build -p gurine-ingest-worker -p gurine-workflow-worker \
  -p gurine-projection-worker -p gurine-notification-worker --bins

docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
for migration in db/migrations/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <"$migration" >/dev/null
done
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "ALTER ROLE gurine_ingest_worker LOGIN PASSWORD 'ingest_test';
   ALTER ROLE gurine_workflow_worker LOGIN PASSWORD 'workflow_test';
   ALTER ROLE gurine_public_projector LOGIN PASSWORD 'projector_test';
   ALTER ROLE gurine_notification_worker LOGIN PASSWORD 'notification_test';" >/dev/null

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES('70000000-0000-4000-8000-000000000001','failure-invitee','invitee@example.test','Failure Invitee','INVITED');

INSERT INTO ops.source_registry(source_id,display_name,connector_type,owner_team,enabled,
  schedule_cron,base_url,legal_status,configuration)
VALUES('koneps-contracts','KONEPS Contracts','OFFICIAL_REST','DATA',true,'0 * * * *',
  'https://apis.data.go.kr/1230000/ao/CntrctInfoService/','APPROVED','{}');
INSERT INTO ops.source_runs(id,source_id,mode,status,requested_from,requested_to,request_reason)
VALUES('70000000-0000-4000-8000-000000000103','koneps-contracts','FULL','QUEUED',
  '2026-07-01','2026-07-12','failure runtime');

INSERT INTO ops.jobs(id,job_type,queue,payload,max_attempts,created_at) VALUES
 ('70000000-0000-4000-8000-000000000101','UNSUPPORTED','ingest-worker','{}',3,clock_timestamp()-interval '4 seconds'),
 ('70000000-0000-4000-8000-000000000102','SOURCE_RUN','ingest-worker',
   '{"sourceRunId":"70000000-0000-4000-8000-000000000103"}',2,clock_timestamp()-interval '3 seconds'),
 ('70000000-0000-4000-8000-000000000201','UNSUPPORTED','workflow-worker','{}',3,clock_timestamp()-interval '4 seconds'),
 ('70000000-0000-4000-8000-000000000202','EVENT_DELIVERY','workflow-worker',
   '{"eventId":"70000000-0000-4000-8000-000000000203","eventType":"failure.unsupported.v1","aggregateId":"70000000-0000-4000-8000-000000000204","payload":{}}',3,clock_timestamp()-interval '3 seconds'),
 ('70000000-0000-4000-8000-000000000301','UNSUPPORTED','projection-worker','{}',3,clock_timestamp()-interval '4 seconds'),
 ('70000000-0000-4000-8000-000000000302','EVENT_DELIVERY','projection-worker',
   '{"eventId":"70000000-0000-4000-8000-000000000303","eventType":"failure.unsupported.v1","aggregateId":"70000000-0000-4000-8000-000000000304","payload":{}}',3,clock_timestamp()-interval '3 seconds'),
 ('70000000-0000-4000-8000-000000000401','UNSUPPORTED','notification-worker','{}',3,clock_timestamp()-interval '4 seconds'),
 ('70000000-0000-4000-8000-000000000402','EVENT_DELIVERY','notification-worker',
   '{"eventId":"70000000-0000-4000-8000-000000000403","eventType":"notification.user_invitation_requested.v1","aggregateId":"70000000-0000-4000-8000-000000000001","payload":{}}',3,clock_timestamp()-interval '3 seconds');

INSERT INTO ops.inbox(consumer,event_id) VALUES
 ('workflow-worker','70000000-0000-4000-8000-000000000203'),
 ('projection-worker','70000000-0000-4000-8000-000000000303'),
 ('notification-worker','70000000-0000-4000-8000-000000000403');

REVOKE SELECT ON ops.inbox FROM gurine_workflow_worker;
REVOKE SELECT ON ops.inbox FROM gurine_public_projector;
SQL

postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
dead_source_port="$(free_port)"
dead_smtp_port="$(free_port)"
test_key="$(printf '%s' '01234567890123456789012345678901' | base64 -w0)"

run_ingest
run_workflow
run_projector
run_notification "$dead_smtp_port"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
BEGIN
  IF EXISTS(
    SELECT 1 FROM ops.jobs WHERE id IN(
      '70000000-0000-4000-8000-000000000102',
      '70000000-0000-4000-8000-000000000202',
      '70000000-0000-4000-8000-000000000302',
      '70000000-0000-4000-8000-000000000402'
    ) AND (status<>'QUEUED' OR attempt_count<>1 OR run_after<=created_at)
  ) THEN RAISE EXCEPTION 'first retry state or delay is invalid'; END IF;
END $$;

GRANT SELECT ON ops.inbox TO gurine_workflow_worker;
GRANT SELECT ON ops.inbox TO gurine_public_projector;
UPDATE ops.jobs SET run_after=clock_timestamp() WHERE id IN(
 '70000000-0000-4000-8000-000000000102',
 '70000000-0000-4000-8000-000000000202',
 '70000000-0000-4000-8000-000000000302',
 '70000000-0000-4000-8000-000000000402');
SQL

smtp_port="$(free_port)"
: >"$work/smtp.jsonl"
FAKE_SMTP_PORT="$smtp_port" FAKE_SMTP_OUTPUT="$work/smtp.jsonl" \
  python3 scripts/test-support/fake-smtp-gateway.py &
smtp_pid=$!
sleep 0.2

run_ingest
run_workflow
run_projector
run_notification "$smtp_port"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE id IN(
     '70000000-0000-4000-8000-000000000101',
     '70000000-0000-4000-8000-000000000102',
     '70000000-0000-4000-8000-000000000201',
     '70000000-0000-4000-8000-000000000202',
     '70000000-0000-4000-8000-000000000301',
     '70000000-0000-4000-8000-000000000302',
     '70000000-0000-4000-8000-000000000401'
   ) AND status='DEAD_LETTER';
  IF actual<>7 THEN RAISE EXCEPTION 'dead-letter jobs %, expected 7',actual; END IF;

  IF EXISTS(
    SELECT 1 FROM ops.jobs WHERE id IN(
      '70000000-0000-4000-8000-000000000102',
      '70000000-0000-4000-8000-000000000202',
      '70000000-0000-4000-8000-000000000302'
    ) AND attempt_count<>2
  ) THEN RAISE EXCEPTION 'retry-to-dead-letter attempt count invalid'; END IF;

  IF (SELECT status FROM ops.jobs WHERE id='70000000-0000-4000-8000-000000000402')<>'SUCCEEDED'
     OR (SELECT attempt_count FROM ops.jobs WHERE id='70000000-0000-4000-8000-000000000402')<>2
  THEN RAISE EXCEPTION 'notification retry did not recover'; END IF;

  SELECT count(*) INTO actual FROM ops.job_attempts
   WHERE job_id IN(
     '70000000-0000-4000-8000-000000000102',
     '70000000-0000-4000-8000-000000000202',
     '70000000-0000-4000-8000-000000000302'
   ) AND attempt=1 AND outcome='RETRY';
  IF actual<>3 THEN RAISE EXCEPTION 'retry attempt records %, expected 3',actual; END IF;

  SELECT count(*) INTO actual FROM ops.job_attempts
   WHERE job_id='70000000-0000-4000-8000-000000000402'
     AND ((attempt=1 AND outcome='RETRY' AND error_code='SMTP_DELIVERY_FAILED')
       OR (attempt=2 AND outcome='SUCCEEDED'));
  IF actual<>2 THEN RAISE EXCEPTION 'notification recovery attempts %, expected 2',actual; END IF;

  SELECT count(*) INTO actual FROM ops.outbox WHERE event_type='job.dead_lettered.v1'
    AND aggregate_id LIKE '70000000-0000-4000-8000-%';
  IF actual<>7 THEN RAISE EXCEPTION 'dead-letter observability events %, expected 7',actual; END IF;

  IF EXISTS(
    SELECT 1 FROM ops.outbox WHERE event_type='job.dead_lettered.v1'
      AND aggregate_id LIKE '70000000-0000-4000-8000-%'
      AND (payload - 'error_code' - 'job_id' - 'job_type') <> '{}'::jsonb
  ) THEN RAISE EXCEPTION 'dead-letter payload contains prohibited detail'; END IF;

  IF NOT EXISTS(
    SELECT 1 FROM ops.inbox WHERE consumer='notification-worker'
      AND event_id='70000000-0000-4000-8000-000000000403'
      AND processed_at IS NOT NULL AND result='SUCCEEDED'
  ) THEN RAISE EXCEPTION 'notification inbox not completed'; END IF;

  IF NOT EXISTS(
    SELECT 1 FROM ops.email_deliveries WHERE object_id='70000000-0000-4000-8000-000000000001'
      AND status='DELIVERED' AND attempt_count=2
  ) THEN RAISE EXCEPTION 'notification delivery recovery record invalid'; END IF;
END $$;
SQL

test "$(wc -l <"$work/smtp.jsonl")" -eq 1
echo "ingest/workflow/projection/notification terminal-retry-DLQ-redaction runtime: PASS"
