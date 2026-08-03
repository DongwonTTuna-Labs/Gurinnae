#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-identity-flow-$BASHPID"
log_dir="$(mktemp -d -t gurine-identity-flow-XXXXXX)"
provider_pid=""
gateway_pid=""
identity_pid=""

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

provider_port="$(free_port)"
gateway_port="$(free_port)"
identity_port="$(free_port)"

cleanup() {
  status=$?
  trap - EXIT
  for pid in "$identity_pid" "$gateway_pid" "$provider_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  docker rm -f "$container" >/dev/null 2>&1 || true
  if [[ $status -ne 0 ]]; then
    for log in "$log_dir"/*.log; do
      [[ -f "$log" ]] && tail -n 120 "$log" >&2
    done
  fi
  rm -rf "$log_dir"
  exit "$status"
}
trap cleanup EXIT

cd "$root"
cargo build -p gurine-oidc-test-provider -p gurine-egress-gateway -p gurine-identity-api

docker run --rm -d --name "$container" \
  -e POSTGRES_DB=gurine_identity_test \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p 127.0.0.1::5432 \
  postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818 >/dev/null

bash scripts/wait-postgres-container.sh "$container" gurine_identity_test

mapfile -t migrations < <(printf '%s\n' db/migrations/*.sql | LC_ALL=C sort)
bash scripts/apply-test-migrations-with-r6e-roles.sh "$container" gurine_identity_test "${migrations[@]}"
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d gurine_identity_test \
  < db/test-fixtures/reference-seed.sql >/dev/null
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d gurine_identity_test -c \
  "ALTER ROLE gurine_identity_api LOGIN PASSWORD 'identity_test'; INSERT INTO ops.users(id,oidc_subject,email,display_name,status) VALUES('11111111-1111-4111-8111-111111111111','gurine-test-reviewer','reviewer@gurinnae.test','Test Reviewer','ACTIVE'); INSERT INTO ops.user_roles(user_id,role_id,granted_by,reason) SELECT '11111111-1111-4111-8111-111111111111',id,'11111111-1111-4111-8111-111111111111','identity integration test' FROM ops.roles WHERE code IN ('INVESTIGATOR','SECURITY_ADMIN');" >/dev/null

postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
test_key="MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE="

GURINE_ENV=test \
HTTP_BIND="127.0.0.1:${provider_port}" \
OIDC_TEST_ISSUER="http://localhost:${provider_port}" \
OIDC_TEST_CLIENT_ID=gurine-review \
OIDC_TEST_CLIENT_SECRET=development-only-secret \
  target/debug/gurine-oidc-test-provider >"$log_dir/provider.log" 2>&1 &
provider_pid=$!

GURINE_ENV=test \
HTTP_BIND="127.0.0.1:${gateway_port}" \
OIDC_ISSUER_HOST=localhost \
  target/debug/gurine-egress-gateway >"$log_dir/gateway.log" 2>&1 &
gateway_pid=$!

GURINE_ENV=test \
HTTP_BIND="127.0.0.1:${identity_port}" \
IDENTITY_DATABASE_URL="postgresql://gurine_identity_api:identity_test@127.0.0.1:${postgres_port}/gurine_identity_test" \
IDENTITY_SERVICE_HMAC_KEY_CURRENT="$test_key" \
IDENTITY_ASSERTION_HMAC_KEY_CURRENT="$test_key" \
FIELD_ENCRYPTION_KEY_CURRENT="$test_key" \
OIDC_EGRESS_URL="http://127.0.0.1:${gateway_port}/oidc" \
OIDC_ISSUER_URL="http://localhost:${provider_port}" \
OIDC_CLIENT_ID=gurine-review \
OIDC_CLIENT_SECRET=development-only-secret \
OIDC_REDIRECT_URI=http://localhost:3001/auth/callback \
OIDC_STEP_UP_REDIRECT_URI=http://localhost:3001/auth/step-up/callback \
OIDC_SCOPES="openid profile email" \
OIDC_ACR_VALUES=urn:mace:incommon:iap:silver \
OIDC_STEP_UP_MAX_AGE_SECONDS=600 \
INTERNAL_SESSION_IDLE_TTL_SECONDS=1800 \
INTERNAL_SESSION_ABSOLUTE_TTL_SECONDS=43200 \
  target/debug/gurine-identity-api >"$log_dir/identity.log" 2>&1 &
identity_pid=$!

for endpoint in \
  "http://127.0.0.1:${provider_port}/health/ready" \
  "http://127.0.0.1:${gateway_port}/health/ready" \
  "http://127.0.0.1:${identity_port}/health/ready"; do
  for _ in $(seq 1 60); do
    if curl --fail --silent --show-error "$endpoint" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
  curl --fail --silent --show-error "$endpoint" >/dev/null
done
kill -0 "$provider_pid"
kill -0 "$gateway_pid"
kill -0 "$identity_pid"

IDENTITY_TEST_BASE_URL="http://127.0.0.1:${identity_port}" \
EGRESS_TEST_BASE_URL="http://127.0.0.1:${gateway_port}" \
IDENTITY_SERVICE_HMAC_KEY_CURRENT="$test_key" \
  bun run tests/integration/identity-flow.ts
