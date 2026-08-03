#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-poll-$BASHPID"
database="gurine_poll"
work="$(mktemp -d -t gurine-poll-XXXXXX)"
gateway_pid=""
build_target="${GURINE_TEST_TARGET_DIR:-/home/dongwonttuna/.cache/gurinnae-codex-target}"

cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$gateway_pid" ]]; then
    kill "$gateway_pid" >/dev/null 2>&1 || true
    wait "$gateway_pid" >/dev/null 2>&1 || true
  fi
  if [[ "$status" -ne 0 ]]; then
    docker exec "$container" psql -U postgres -d "$database" -c \
      "SELECT id,status,attempt_count,max_attempts,last_error_code FROM ops.jobs ORDER BY created_at,id; SELECT job_id,attempt,outcome,metrics FROM ops.job_attempts WHERE job_id::text LIKE '78000000-0000-4000-8000-%' ORDER BY job_id,attempt; SELECT id,state,version,receipt_sequence FROM ops.outbound_deliveries WHERE id='78000000-0000-4000-8000-000000000001'; SELECT id,receipt_sequence,source_kind,applied,outbox_event_id FROM ops.outbound_delivery_receipts WHERE delivery_id='78000000-0000-4000-8000-000000000001' ORDER BY receipt_sequence;" >&2 || true
    docker logs "$container" >&2 || true
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

run_notification() {
  local port="$1"
  NOTIFICATION_DATABASE_URL="postgresql://gurine_notification_worker:notification_poll_test@127.0.0.1:${postgres_port}/${database}" \
  FIELD_ENCRYPTION_KEY_CURRENT="$test_key" TOKEN_HMAC_KEY="$test_key" \
  EMAIL_ADAPTER=smtp EGRESS_SMTP_CHANNEL_URL="http://127.0.0.1:${port}/smtp" \
  EMAIL_FROM="gurine@example.test" EMAIL_REPLY_TO="ops@example.test" \
  PUBLIC_BASE_URL="https://public.example.test" RESPONSE_BASE_URL="https://response.example.test" \
  NOTIFICATION_ONCE=true HOSTNAME="notification-poll-runtime" \
    "$build_target/debug/gurine-notification-worker"
}

cd "$root"
CARGO_TARGET_DIR="$build_target" \
  cargo build -p gurine-migrator -p gurine-notification-worker --bins >/dev/null

docker run --detach --rm --name "$container" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB="$database" \
  -p 127.0.0.1::5432 \
  postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818 >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
GURINE_ENV=test MIGRATOR_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${postgres_port}/${database}" \
  "$build_target/debug/gurine-migrator" >/dev/null
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "ALTER ROLE gurine_notification_worker LOGIN PASSWORD 'notification_poll_test';" >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  <db/test-fixtures/reference-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  <db/test-fixtures/control-runtime-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  <db/test-fixtures/control-research-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  <db/test-fixtures/control-retry-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  <db/test-fixtures/control-communication-seed.sql >/dev/null

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.outbound_deliveries
SELECT (jsonb_populate_record(NULL::ops.outbound_deliveries,
  to_jsonb(d) || jsonb_build_object(
    'id','78000000-0000-4000-8000-000000000001',
    'dispatch_eligible',true,
    'delivery_key',repeat('1',64),
    'provider_idempotency_key_sha256',repeat('2',64),
    'delivery_digest',repeat('3',64),
    'state','PROVIDER_ACCEPTED',
    'version',2,
    'event_sequence',2,
    'receipt_sequence',0,
    'current_evidence_rank',10,
    'highest_proof_level','PROVIDER_ACCEPTED',
    'provider_message_id','poll-message-001',
    'provider_accepted_at',clock_timestamp(),
    'delivered_at',NULL,
    'read_at',NULL,
    'terminal_at',NULL,
    'next_attempt_at',clock_timestamp(),
    'updated_at',clock_timestamp()
  ))).* FROM ops.outbound_deliveries d
WHERE d.id='99999999-9999-4999-8999-999999999999';

INSERT INTO ops.jobs(id,job_type,queue,payload,dedupe_key,max_attempts) VALUES(
  '78000000-0000-4000-8000-000000000101','COMMUNICATION_PROVIDER_POLL','notification-worker',
  jsonb_build_object(
    'deliveryId','78000000-0000-4000-8000-000000000001',
    'expectedDeliveryVersion',2,
    'channel','SOLAPI_SMS',
    'providerMessageId','poll-message-001',
    'providerConfigId','59e6fe3c-6803-5f19-8ee2-1595abc421a8',
    'providerConfigVersion',1,
    'providerConfigurationDigest',repeat('b',64),
    'providerPreflightReceiptId','d8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef',
    'providerPreflightReceiptDigest',repeat('b',64)),
  'poll-runtime-first',2);
SQL

poll_port="$(free_port)"
FAKE_POLL_PORT="$poll_port" PYTHONDONTWRITEBYTECODE=1 \
  python3 scripts/test-support/fake-communication-poll-gateway.py >"$work/gateway.log" 2>&1 &
gateway_pid=$!
for _ in $(seq 1 40); do
  if curl --silent --output /dev/null --max-time 0.1 "http://127.0.0.1:${poll_port}/"; then
    break
  fi
  sleep 0.05
done
test_key="$(printf '%s' '01234567890123456789012345678901' | base64 -w0)"
run_notification "$poll_port"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE source_id uuid; event_id uuid;
BEGIN
  IF (SELECT state FROM ops.outbound_deliveries WHERE id='78000000-0000-4000-8000-000000000001') <> 'DELIVERED'
     OR (SELECT version FROM ops.outbound_deliveries WHERE id='78000000-0000-4000-8000-000000000001') <> 3
     OR (SELECT receipt_sequence FROM ops.outbound_deliveries WHERE id='78000000-0000-4000-8000-000000000001') <> 2 THEN
    RAISE EXCEPTION 'first provider poll was not applied exactly once';
  END IF;
  IF (SELECT count(*) FROM ops.outbound_delivery_receipts WHERE delivery_id='78000000-0000-4000-8000-000000000001') <> 2
     OR (SELECT count(*) FROM ops.outbox WHERE aggregate_id='78000000-0000-4000-8000-000000000001' AND event_type='communication.delivery_receipt_recorded.v1') <> 1 THEN
    RAISE EXCEPTION 'first provider poll receipt or outbox count invalid';
  END IF;
  SELECT id INTO source_id FROM ops.outbound_delivery_receipts
   WHERE delivery_id='78000000-0000-4000-8000-000000000001' AND applied=false;
  SELECT outbox_event_id INTO event_id FROM ops.outbound_delivery_receipts
   WHERE delivery_id='78000000-0000-4000-8000-000000000001' AND applied=true;
  IF source_id IS NULL OR event_id IS NULL THEN RAISE EXCEPTION 'poll evidence chain is incomplete'; END IF;
END $$;

INSERT INTO ops.jobs(id,job_type,queue,payload,dedupe_key,max_attempts)
SELECT '78000000-0000-4000-8000-000000000102',job_type,queue,payload,'poll-runtime-replay',2
FROM ops.jobs WHERE id='78000000-0000-4000-8000-000000000101';
SQL

run_notification "$poll_port"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE first_source text; replay_source text; first_event text; replay_event text;
BEGIN
  IF (SELECT version FROM ops.outbound_deliveries WHERE id='78000000-0000-4000-8000-000000000001') <> 3
     OR (SELECT receipt_sequence FROM ops.outbound_deliveries WHERE id='78000000-0000-4000-8000-000000000001') <> 2
     OR (SELECT count(*) FROM ops.outbound_delivery_receipts WHERE delivery_id='78000000-0000-4000-8000-000000000001') <> 2
     OR (SELECT count(*) FROM ops.outbox WHERE aggregate_id='78000000-0000-4000-8000-000000000001' AND event_type='communication.delivery_receipt_recorded.v1') <> 1 THEN
    RAISE EXCEPTION 'identical poll replay mutated delivery evidence';
  END IF;
  SELECT metrics->>'sourceReceiptId',metrics->>'emittedEventId' INTO first_source,first_event
    FROM ops.job_attempts WHERE job_id='78000000-0000-4000-8000-000000000101';
  SELECT metrics->>'sourceReceiptId',metrics->>'emittedEventId' INTO replay_source,replay_event
    FROM ops.job_attempts WHERE job_id='78000000-0000-4000-8000-000000000102';
  IF first_source IS NULL OR first_source <> replay_source OR first_event IS NULL OR first_event <> replay_event THEN
    RAISE EXCEPTION 'poll replay did not return the original immutable receipt chain';
  END IF;
END $$;

INSERT INTO ops.jobs(id,job_type,queue,payload,dedupe_key,max_attempts)
SELECT '78000000-0000-4000-8000-000000000103',job_type,queue,payload,'poll-runtime-failure',2
FROM ops.jobs WHERE id='78000000-0000-4000-8000-000000000101';
SQL

dead_port="$(free_port)"
run_notification "$dead_port"
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "UPDATE ops.jobs SET run_after=clock_timestamp() WHERE id='78000000-0000-4000-8000-000000000103';" >/dev/null
run_notification "$dead_port"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM ops.jobs
     WHERE id='78000000-0000-4000-8000-000000000103'
       AND status='DEAD_LETTER' AND attempt_count=2
       AND last_error_code='COMMUNICATION_PROVIDER_POLL_FAILED'
  ) THEN RAISE EXCEPTION 'provider poll failure did not reach bounded DLQ'; END IF;
  IF (SELECT count(*) FROM ops.job_attempts
       WHERE job_id='78000000-0000-4000-8000-000000000103'
         AND ((attempt=1 AND outcome='RETRY') OR (attempt=2 AND outcome='DEAD_LETTER'))) <> 2 THEN
    RAISE EXCEPTION 'provider poll retry attempt ledger invalid';
  END IF;
  IF (SELECT count(*) FROM ops.outbox
       WHERE aggregate_id='78000000-0000-4000-8000-000000000103'
         AND event_type='job.dead_lettered.v1') <> 1 THEN
    RAISE EXCEPTION 'provider poll DLQ observability event invalid';
  END IF;
END $$;
SQL

printf 'communication poll duplicate-state/version/outbox and bounded retry/DLQ runtime: PASS\n'
