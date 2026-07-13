#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-submission-flow-$BASHPID"
clam_container="${container}-clamav"
database="gurine_submission_test"
log_dir="$(mktemp -d -t gurine-submission-flow-XXXXXX)"
submission_pid=""
smtp_capture_pid=""
egress_pid=""

readarray -t reserved_ports < <(python3 - <<'PY'
import socket

sockets = []
for _ in range(4):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    sockets.append(listener)

for listener in sockets:
    print(listener.getsockname()[1])
PY
)
if [[ ${#reserved_ports[@]} -ne 4 ]]; then
  printf 'failed to reserve four distinct submission-flow ports\n' >&2
  exit 1
fi
smtp_port="${reserved_ports[0]}"
smtp_http_port="${reserved_ports[1]}"
egress_port="${reserved_ports[2]}"
submission_port="${reserved_ports[3]}"

dump_log() {
  local label="$1"
  local path="$2"
  if [[ -f "$path" ]]; then
    printf '\n--- %s (%s) ---\n' "$label" "$path" >&2
    tail -n 160 "$path" >&2
  fi
}

wait_http() {
  local label="$1"
  local pid="$2"
  local endpoint="$3"
  local log_path="$4"
  local attempts="$5"
  local delay="$6"

  for _ in $(seq 1 "$attempts"); do
    if curl --fail --silent --show-error "$endpoint" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      printf '%s exited before becoming ready at %s\n' "$label" "$endpoint" >&2
      dump_log "$label" "$log_path"
      return 1
    fi
    sleep "$delay"
  done

  printf '%s did not become ready at %s after %s attempts\n' \
    "$label" "$endpoint" "$attempts" >&2
  dump_log "$label" "$log_path"
  return 1
}

cleanup() {
  status=$?
  trap - EXIT
  for pid in "$submission_pid" "$egress_pid" "$smtp_capture_pid"; do
    if [[ -n "$pid" ]]; then
      if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
      fi
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ $status -ne 0 ]]; then
    docker logs --tail 120 "$container" >&2 || true
    docker logs --tail 120 "$clam_container" >&2 || true
    printf 'submission-flow ports: smtp=%s smtp-http=%s egress=%s submission=%s\n' \
      "$smtp_port" "$smtp_http_port" "$egress_port" "$submission_port" >&2
    dump_log "SMTP capture" "$log_dir/smtp-capture.log"
    dump_log "egress gateway" "$log_dir/egress.log"
    dump_log "submission API" "$log_dir/submission.log"
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker rm -f "$clam_container" >/dev/null 2>&1 || true
  rm -rf "$log_dir"
  exit "$status"
}
trap cleanup EXIT

cd "$root"
cargo build -p gurine-submission-api -p gurine-workflow-worker \
  -p gurine-notification-worker -p gurine-scheduler -p gurine-egress-gateway \
  -p gurine-test-support --bins

docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 \
  postgres:18.4-bookworm >/dev/null

bash scripts/wait-postgres-container.sh "$container" "$database"

docker run --rm -d --name "$clam_container" \
  -p 127.0.0.1::3310 \
  clamav/clamav:1.4.3 >/dev/null
clamav_port="$(docker port "$clam_container" 3310/tcp | sed -n '1s/.*://p')"
for _ in $(seq 1 180); do
  clam_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$clam_container" 2>/dev/null || true)"
  if [[ "$clam_health" == "healthy" ]] && timeout 1 bash -c "</dev/tcp/127.0.0.1/${clamav_port}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
[[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$clam_container")" == "healthy" ]]
timeout 1 bash -c "</dev/tcp/127.0.0.1/${clamav_port}" >/dev/null 2>&1

for migration in db/migrations/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
    < "$migration" >/dev/null
done
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  < db/test-fixtures/reference-seed.sql >/dev/null

raw_key="01234567890123456789012345678901"
test_key="$(printf '%s' "$raw_key" | base64 -w0)"
bot_secret="submission-integration-bot-secret"
magic_token="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n')"
hmac_hex() {
  printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" | awk '{print $2}'
}
magic_hash="$(hmac_hex "$raw_key" "$magic_token")"
otp_digest="$(hmac_hex "$raw_key" "response-otp:$magic_hash")"
printf -v response_otp '%06d' "$((16#${otp_digest:0:8} % 1000000))"

docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "ALTER ROLE gurine_submission_api LOGIN PASSWORD 'submission_test';
   ALTER ROLE gurine_workflow_worker LOGIN PASSWORD 'workflow_test';
   ALTER ROLE gurine_notification_worker LOGIN PASSWORD 'notification_test';
   ALTER ROLE gurine_scheduler LOGIN PASSWORD 'scheduler_test';
   INSERT INTO editorial.cases(id,public_slug,title)
   VALUES('22222222-2222-4222-8222-222222222222','integration-case','Integration Case');
   INSERT INTO editorial.response_requests(
     id,case_id,party_type,party_name,recipient_email_hash,recipient_email_encrypted,
     questions,requested_publication_scope,due_at,sent_at,status,created_by
   ) VALUES (
     '33333333-3333-4333-8333-333333333333',
     '22222222-2222-4222-8222-222222222222','OTHER','Integration Respondent',
     repeat('e',64),decode('00','hex'),
     '[{\"id\":\"q1\",\"order\":1,\"text\":\"Please explain the discrepancy.\",\"required\":true,\"maxLength\":2000}]'::jsonb,
     '{\"bodyConsent\":false,\"attachmentConsents\":[],\"identityDisplay\":\"ROLE_ONLY\",\"redactionAcknowledged\":false,\"excerptReviewRequested\":false,\"consentedAt\":\"2026-07-12T00:00:00Z\"}'::jsonb,
     clock_timestamp()+interval '1 day',clock_timestamp(),'SENT',
     '11111111-1111-4111-8111-111111111111'
   );
   INSERT INTO intake.response_access_tokens(
     response_request_id,token_hash,expires_at,max_uses
   ) VALUES (
     '33333333-3333-4333-8333-333333333333','$magic_hash',
     clock_timestamp()+interval '1 hour',20
   );" >/dev/null

postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"

SMTP_CAPTURE_PORT="$smtp_port" SMTP_CAPTURE_HTTP_PORT="$smtp_http_port" \
  bun run tests/integration/smtp-capture.ts >"$log_dir/smtp-capture.log" 2>&1 &
smtp_capture_pid=$!

GURINE_ENV=test \
HTTP_BIND="127.0.0.1:${egress_port}" \
OIDC_ISSUER_HOST=localhost \
SMTP_HOST=localhost \
SMTP_URL="smtp://localhost:${smtp_port}" \
  target/debug/gurine-egress-gateway >"$log_dir/egress.log" 2>&1 &
egress_pid=$!

wait_http \
  "SMTP capture" "$smtp_capture_pid" "http://127.0.0.1:${smtp_http_port}" \
  "$log_dir/smtp-capture.log" 60 0.25
wait_http \
  "egress gateway" "$egress_pid" "http://127.0.0.1:${egress_port}/health/ready" \
  "$log_dir/egress.log" 60 0.25

GURINE_ENV=test \
HTTP_BIND="127.0.0.1:${submission_port}" \
SUBMISSION_DATABASE_URL="postgresql://gurine_submission_api:submission_test@127.0.0.1:${postgres_port}/${database}" \
PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT="$test_key" \
RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT="$test_key" \
FIELD_ENCRYPTION_KEY_CURRENT="$test_key" \
TOKEN_HMAC_KEY="$test_key" \
BOT_CHALLENGE_SECRET_KEY="$bot_secret" \
OBJECT_STORE_ADAPTER=filesystem \
OBJECT_STORE_FILESYSTEM_ROOT="$log_dir/objects" \
MAX_UPLOAD_BYTES=52428800 \
  target/debug/gurine-submission-api >"$log_dir/submission.log" 2>&1 &
submission_pid=$!

wait_http \
  "submission API" "$submission_pid" "http://127.0.0.1:${submission_port}/health/ready" \
  "$log_dir/submission.log" 60 0.5

SUBMISSION_TEST_BASE_URL="http://127.0.0.1:${submission_port}" \
SUBMISSION_TEST_DB_CONTAINER="$container" \
SUBMISSION_TEST_DATABASE="$database" \
SUBMISSION_SERVICE_HMAC_KEY="$test_key" \
SUBMISSION_BOT_CHALLENGE_SECRET="$bot_secret" \
SUBMISSION_FIELD_KEY="$test_key" \
SUBMISSION_RESPONSE_MAGIC_TOKEN="$magic_token" \
SUBMISSION_RESPONSE_OTP="$response_otp" \
SMTP_CAPTURE_HTTP_URL="http://127.0.0.1:${smtp_http_port}" \
GURINE_ENV=test \
WORKFLOW_DATABASE_URL="postgresql://gurine_workflow_worker:workflow_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_INSTANCE_ID=submission-integration-scheduler \
SCHEDULER_ONCE=true \
SCHEDULER_POLL_MILLIS=100 \
OBJECT_STORE_ADAPTER=filesystem \
OBJECT_STORE_FILESYSTEM_ROOT="$log_dir/objects" \
CLAMAV_HOST=127.0.0.1 \
CLAMAV_PORT="$clamav_port" \
WORKFLOW_ONCE=true \
WORKFLOW_POLL_MILLIS=50 \
NOTIFICATION_DATABASE_URL="postgresql://gurine_notification_worker:notification_test@127.0.0.1:${postgres_port}/${database}" \
EGRESS_SMTP_CHANNEL_URL="http://127.0.0.1:${egress_port}/smtp" \
EMAIL_ADAPTER=smtp \
EMAIL_FROM=no-reply@gurine.test \
EMAIL_REPLY_TO=reply@gurine.test \
PUBLIC_BASE_URL=http://public.gurine.test \
RESPONSE_BASE_URL=http://respond.gurine.test \
TOKEN_HMAC_KEY="$test_key" \
FIELD_ENCRYPTION_KEY_CURRENT="$test_key" \
NOTIFICATION_ONCE=true \
NOTIFICATION_POLL_MILLIS=50 \
  bun run tests/integration/submission-flow.ts
