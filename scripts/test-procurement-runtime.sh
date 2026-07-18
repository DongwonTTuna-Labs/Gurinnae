#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="gurine-procurement-runtime-${BASHPID}"
cleanup() { docker rm --force "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run --detach --name "$name" \
  --env POSTGRES_DB=gurine --env POSTGRES_USER=postgres --env POSTGRES_PASSWORD=postgres \
  postgres:18.4-bookworm >/dev/null
for _ in $(seq 1 120); do
  docker exec "$name" psql -U postgres -d gurine -Atc 'SELECT 1' 2>/dev/null | grep -qx 1 && break
  sleep 1
done
docker exec "$name" psql -U postgres -d gurine -Atc 'SELECT 1' | grep -qx 1
for migration in "$root"/db/migrations/*.sql; do
  docker exec -i "$name" psql -v ON_ERROR_STOP=1 -U postgres -d gurine <"$migration" >/dev/null
done
docker exec -i "$name" psql -v ON_ERROR_STOP=1 -U postgres -d gurine <"$root"/db/test-fixtures/procurement-runtime.sql >/dev/null
printf 'procurement owner-function runtime: PASS\n'
