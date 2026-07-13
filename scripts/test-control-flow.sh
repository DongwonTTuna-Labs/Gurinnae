#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-control-flow-$BASHPID"
database="gurine_control_test"
log_dir="$(mktemp -d -t gurine-control-flow-XXXXXX)"
control_pid=""
control_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"

cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$control_pid" ]] && kill -0 "$control_pid" 2>/dev/null; then kill -TERM "$control_pid" 2>/dev/null || true; wait "$control_pid" 2>/dev/null || true; fi
  if [[ $status -ne 0 ]] && [[ -f "$log_dir/control.log" ]]; then tail -n 200 "$log_dir/control.log" >&2; fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$log_dir"
  exit "$status"
}
trap cleanup EXIT

cd "$root"
cargo build -p gurine-control-api
docker run --rm -d --name "$container" -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -p 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
for migration in db/migrations/*.sql; do docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <"$migration" >/dev/null; done
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <db/test-fixtures/reference-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <db/test-fixtures/control-runtime-seed.sql >/dev/null
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c "ALTER ROLE gurine_control_api LOGIN PASSWORD 'control_test';" >/dev/null
postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
raw_key="01234567890123456789012345678901"
test_key="$(printf '%s' "$raw_key" | base64 -w0)"
HTTP_BIND="127.0.0.1:${control_port}" CONTROL_DATABASE_URL="postgresql://gurine_control_api:control_test@127.0.0.1:${postgres_port}/${database}" IDENTITY_ASSERTION_HMAC_KEY_CURRENT="$test_key" FIELD_ENCRYPTION_KEY_CURRENT="$test_key" target/debug/gurine-control-api >"$log_dir/control.log" 2>&1 &
control_pid=$!
for _ in $(seq 1 60); do if curl --fail --silent --show-error "http://127.0.0.1:${control_port}/health/ready" >/dev/null 2>&1; then break; fi; sleep 0.5; done
curl --fail --silent --show-error "http://127.0.0.1:${control_port}/health/ready" >/dev/null
kill -0 "$control_pid"
CONTROL_TEST_BASE_URL="http://127.0.0.1:${control_port}" CONTROL_ASSERTION_KEY="$test_key" python3 tests/integration/control-flow.py
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <db/test-fixtures/control-runtime-assertions.sql >/dev/null
