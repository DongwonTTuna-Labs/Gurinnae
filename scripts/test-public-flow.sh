#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-public-flow-$BASHPID"
database="gurine_public_test"
log_dir="$(mktemp -d -t gurine-public-flow-XXXXXX)"
public_pid=""
public_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"

cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$public_pid" ]] && kill -0 "$public_pid" 2>/dev/null; then
    kill -TERM "$public_pid" 2>/dev/null || true
    wait "$public_pid" 2>/dev/null || true
  fi
  if [[ $status -ne 0 ]] && [[ -f "$log_dir/public.log" ]]; then
    tail -n 160 "$log_dir/public.log" >&2
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$log_dir"
  exit "$status"
}
trap cleanup EXIT

cd "$root"
cargo build -p gurine-public-api

docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 \
  postgres:18.4-bookworm >/dev/null

bash scripts/wait-postgres-container.sh "$container" "$database"

for migration in db/migrations/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <"$migration" >/dev/null
done
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  <db/test-fixtures/public-projection-seed.sql >/dev/null
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "ALTER ROLE gurine_public_api LOGIN PASSWORD 'public_test';" >/dev/null
postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"

HTTP_BIND="127.0.0.1:${public_port}" \
PUBLIC_DATABASE_URL="postgresql://gurine_public_api:public_test@127.0.0.1:${postgres_port}/${database}" \
  target/debug/gurine-public-api >"$log_dir/public.log" 2>&1 &
public_pid=$!

for _ in $(seq 1 60); do
  if curl --fail --silent --show-error "http://127.0.0.1:${public_port}/health/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
curl --fail --silent --show-error "http://127.0.0.1:${public_port}/health/ready" >/dev/null
kill -0 "$public_pid"

PYTHONDONTWRITEBYTECODE=1 PUBLIC_TEST_BASE_URL="http://127.0.0.1:${public_port}" python3 tests/integration/public-flow.py

docker stop -t 0 "$container" >/dev/null
ready_status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
  "http://127.0.0.1:${public_port}/health/ready")"
if [[ "$ready_status" != "503" ]]; then
  echo "public-api readiness returned $ready_status after PostgreSQL shutdown; expected 503" >&2
  exit 1
fi
