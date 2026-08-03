#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-callback-$BASHPID"
database="gurine_callback"
postgres_port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
gateway_port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
work="$(mktemp -d)"
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
    [[ ! -f "$work/gateway.log" ]] || sed -n '1,240p' "$work/gateway.log" >&2
    docker exec "$container" psql -U postgres -d "$database" -c \
      "SELECT id,integration_id,operational_state,latest_preflight_receipt_id FROM ops.communication_provider_configs; SELECT id,provider_config_id FROM ops.communication_provider_preflight_receipts;" >&2 || true
    docker logs "$container" >&2 || true
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

cd "$root"
CARGO_TARGET_DIR="$build_target" cargo build -p gurine-migrator -p gurine-egress-gateway >/dev/null

docker run --detach --rm --name "$container" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB="$database" \
  -p "127.0.0.1:${postgres_port}:5432" \
  postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818 >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$container" psql -At -U postgres -d "$database" -c 'SELECT 1' 2>/dev/null | grep -qx 1; then
    break
  fi
  sleep 0.5
done
docker exec "$container" psql -At -U postgres -d "$database" -c 'SELECT 1' | grep -qx 1

GURINE_ENV=test MIGRATOR_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${postgres_port}/${database}" \
  "$build_target/debug/gurine-migrator" >/dev/null
# The provider activation command is a separate control-plane concern. This
# fixture only makes the immutable revision current so the callback gate can
# exercise the real network, login-role, SQL owner and replay boundaries.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
ALTER ROLE gurine_egress_gateway PASSWORD 'egress_callback_test';
INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES('11111111-1111-4111-8111-111111111111','callback-runtime-user',
  'callback-runtime@gurine.test','Callback Runtime','ACTIVE');
INSERT INTO ops.communication_provider_configs(
  id,integration_id,deployment_id,environment,channel,adapter_id,operational_state,version,
  provider_account_hmac,sender_identity_ciphertext,sender_identity_hmac,encryption_key_id,
  credential_secret_reference,webhook_secret_reference,callback_path,callback_allowlist_digest,
  jurisdiction_set,jurisdiction_set_digest,dpa_evidence_digest,approved_template_catalog_digest,
  rate_limit_policy,rate_limit_policy_digest,cost_policy,cost_policy_digest,provider_capabilities,
  provider_capabilities_digest,kill_switch_code,configuration_digest,created_by,updated_by)
VALUES('59e6fe3c-6803-5f19-8ee2-1595abc421a8','73100000-0000-4000-8000-000000000011',
  'callback-runtime','test','SMTP_EMAIL','smtp-email-v1','DISABLED',1,repeat('b',64),
  convert_to('callback-runtime-sender','UTF8'),repeat('b',64),'callback-runtime-key',
  'secret://callback-runtime-provider/value@v1','secret://control-webhook/value@v1',
  '/private/v1/callbacks/smtp-dsn',repeat('b',64),'{}'::jsonb,repeat('b',64),
  repeat('b',64),repeat('b',64),'{}'::jsonb,repeat('b',64),'{}'::jsonb,repeat('b',64),
  '{}'::jsonb,repeat('b',64),'CALLBACK_RUNTIME',repeat('b',64),
  '11111111-1111-4111-8111-111111111111','11111111-1111-4111-8111-111111111111');
INSERT INTO ops.communication_provider_preflight_receipts(
  id,provider_config_id,provider_config_version,configuration_digest,provider_revision_snapshot,
  provider_revision_snapshot_digest,test_generation,test_environment,result,live_sandbox,
  callback_or_poll_verified,sender_identity_verified,template_catalog_verified,idempotency_capability,
  reconciliation_capability,highest_delivery_proof,checklist,checklist_digest,blocker_set,
  blocker_set_digest,provider_evidence_digest,contract_test_receipt_digest,receipt_digest,
  performed_by_service,requested_by,started_at,completed_at,expires_at)
VALUES('d8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef','59e6fe3c-6803-5f19-8ee2-1595abc421a8',
  1,repeat('b',64),'{}'::jsonb,repeat('b',64),1,'test','PASS',true,true,true,true,
  'NATIVE_IDEMPOTENCY','AUTHENTICATED_POLL','DELIVERED','{}'::jsonb,repeat('b',64),
  '[]'::jsonb,repeat('b',64),repeat('b',64),repeat('b',64),repeat('b',64),
  'callback-runtime','11111111-1111-4111-8111-111111111111',clock_timestamp(),
  clock_timestamp(),clock_timestamp()+interval '1 day');
ALTER TABLE ops.communication_provider_configs DISABLE TRIGGER ops_communication_provider_configs_immutable_mutation_guard;
UPDATE ops.communication_provider_configs
SET operational_state='ACTIVE',
    latest_preflight_receipt_id='d8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef',
    activation_decision_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    activation_receipt_digest=repeat('a',64),
    activation_effective_at=clock_timestamp()-interval '1 minute',
    activation_expires_at=clock_timestamp()+interval '1 day'
WHERE id='59e6fe3c-6803-5f19-8ee2-1595abc421a8';
ALTER TABLE ops.communication_provider_configs ENABLE TRIGGER ops_communication_provider_configs_immutable_mutation_guard;
SQL

provider_revision="$(
  docker exec "$container" psql -At -F '|' -U postgres -d "$database" -c \
    "SELECT pc.integration_id,pc.configuration_digest,pf.receipt_digest
       FROM ops.communication_provider_configs pc
       JOIN ops.communication_provider_preflight_receipts pf
         ON pf.id=pc.latest_preflight_receipt_id
      WHERE pc.id='59e6fe3c-6803-5f19-8ee2-1595abc421a8'"
)"
IFS='|' read -r integration_id config_digest preflight_digest <<<"$provider_revision"
[[ -n "$integration_id" && -n "$config_digest" && -n "$preflight_digest" ]]

callback_key="MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE="
GURINE_ENV=test HTTP_BIND="127.0.0.1:${gateway_port}" OIDC_ISSUER_HOST=identity.test \
EGRESS_DATABASE_URL="postgresql://gurine_egress_gateway:egress_callback_test@127.0.0.1:${postgres_port}/${database}" \
COMMUNICATION_CALLBACK_ENCRYPTION_KEY="$callback_key" \
COMMUNICATION_CALLBACK_ENCRYPTION_KEY_ID=callback-test-v1 \
COMMUNICATION_SMTP_CALLBACK_SECRET_REFERENCE='secret://control-webhook/value@v1' \
  "$build_target/debug/gurine-egress-gateway" >"$work/gateway.log" 2>&1 &
gateway_pid=$!
for _ in $(seq 1 60); do
  if curl --fail --silent "http://127.0.0.1:${gateway_port}/health/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
curl --fail --silent "http://127.0.0.1:${gateway_port}/health/ready" >/dev/null

invoke_callback() {
  curl --silent --show-error --output "$1" --write-out '%{http_code}' \
    -X POST "http://127.0.0.1:${gateway_port}/private/v1/callbacks/smtp-dsn/${integration_id}" \
    -H 'content-type: multipart/report; report-type=delivery-status' \
    -H 'x-gurine-mta-assertion: callback-runtime-assertion' \
    -H 'x-gurine-callback-replay-key: callback-runtime-replay-v1' \
    -H 'x-gurine-provider-config-id: 59e6fe3c-6803-5f19-8ee2-1595abc421a8' \
    -H 'x-gurine-provider-config-version: 1' \
    -H "x-gurine-provider-configuration-digest: ${config_digest}" \
    -H 'x-gurine-provider-preflight-receipt-id: d8a95eb4-1fb4-5a23-a6e7-0d2dd9ef09ef' \
    -H "x-gurine-provider-preflight-receipt-digest: ${preflight_digest}" \
    --data-binary $'Reporting-MTA: dns; mail.gurine.test\nFinal-Recipient: rfc822; subject@example.test\nAction: delivered\nStatus: 2.0.0\n'
}

first_status="$(invoke_callback "$work/first.json")"
if [[ "$first_status" != "200" ]]; then
  printf 'first callback returned HTTP %s: ' "$first_status" >&2
  cat "$work/first.json" >&2
  printf '\n' >&2
  exit 1
fi
replay_status="$(invoke_callback "$work/replay.json")"
if [[ "$replay_status" != "200" ]]; then
  printf 'callback replay returned HTTP %s: ' "$replay_status" >&2
  cat "$work/replay.json" >&2
  printf '\n' >&2
  exit 1
fi
python3 - "$work/first.json" "$work/replay.json" <<'PY'
import json, sys
first = json.load(open(sys.argv[1], encoding='utf-8'))
replay = json.load(open(sys.argv[2], encoding='utf-8'))
assert first['callback_event_id'] == replay['callback_event_id']
assert first['idempotency_replay'] is False
assert replay['idempotency_replay'] is True
PY

docker exec "$container" psql -At -U postgres -d "$database" -c \
  "SELECT count(*) FROM ops.communication_callback_events
    WHERE provider_config_id='59e6fe3c-6803-5f19-8ee2-1595abc421a8'
      AND replay_key_digest=encode(extensions.digest(convert_to('callback-runtime-replay-v1','UTF8'),'sha256'),'hex')" \
  | grep -qx '1'

docker exec -i "$container" psql -At -U postgres -d "$database" <<'SQL' | grep -qx 't|f|f|f|f|f|8|t|t|f|f|f|f|t|t|f'
SELECT r.rolcanlogin,r.rolsuper,r.rolcreaterole,r.rolcreatedb,r.rolbypassrls,
       r.rolinherit,r.rolconnlimit,
       has_schema_privilege('gurine_egress_gateway','ops','USAGE'),
       has_function_privilege('gurine_egress_gateway','ops.record_communication_callback_request_json(jsonb)','EXECUTE'),
       has_function_privilege('gurine_egress_gateway','ops.record_communication_callback_request(ops.communication_callback_request_v1)','EXECUTE'),
       has_function_privilege('gurine_egress_gateway','ops.record_outbound_delivery_observation_json(jsonb)','EXECUTE'),
       has_table_privilege('gurine_egress_gateway','ops.communication_callback_events','INSERT'),
       has_table_privilege('gurine_egress_gateway','ops.communication_provider_configs','SELECT'),
       has_column_privilege('gurine_egress_gateway','ops.communication_provider_configs','webhook_secret_reference','SELECT'),
       has_column_privilege('gurine_egress_gateway','ops.kill_switches','state','SELECT'),
       has_column_privilege('gurine_egress_gateway','ops.communication_provider_configs','sender_identity_ciphertext','SELECT')
FROM pg_roles r WHERE r.rolname='gurine_egress_gateway';
SQL

docker exec -i "$container" psql -At -U postgres -d "$database" <<'SQL' | grep -qx '0|3'
SELECT count(*) FILTER (WHERE c.relrowsecurity OR c.relforcerowsecurity),
       count(*) FILTER (WHERE p.prosecdef AND owner_role.rolname='gurine_migrator')
FROM pg_proc p
JOIN pg_roles owner_role ON owner_role.oid=p.proowner
JOIN pg_namespace n ON n.oid=p.pronamespace AND n.nspname='ops'
CROSS JOIN LATERAL (
  SELECT relrowsecurity,relforcerowsecurity
  FROM pg_class
  WHERE oid='ops.communication_callback_events'::regclass
) c
WHERE p.oid IN (
  'ops.record_communication_callback_request_json(jsonb)'::regprocedure,
  'ops.record_communication_callback_request(ops.communication_callback_request_v1)'::regprocedure,
  'ops.record_outbound_delivery_observation(ops.outbound_delivery_observation_v1)'::regprocedure
);
SQL

printf 'egress callback dedicated-role/ledger/idempotent-replay/least-privilege runtime: PASS\n'
