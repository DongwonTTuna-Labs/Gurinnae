#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="gurine-procurement-runtime-${BASHPID}"
cleanup() { docker rm --force "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run --detach --name "$name" \
  --env POSTGRES_DB=gurine --env POSTGRES_USER=postgres --env POSTGRES_HOST_AUTH_METHOD=trust \
  postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818 >/dev/null
for _ in $(seq 1 120); do
  docker exec "$name" psql -U postgres -d gurine -Atc 'SELECT 1' 2>/dev/null | grep -qx 1 && break
  sleep 1
done
docker exec "$name" psql -U postgres -d gurine -Atc 'SELECT 1' | grep -qx 1
mapfile -t migrations < <(
  printf '%s\n' "$root"/db/migrations/*.sql | LC_ALL=C sort
)
bash "$root/scripts/apply-test-migrations-with-r6e-roles.sh" \
  "$name" gurine "${migrations[@]}"
docker exec -i "$name" psql -v ON_ERROR_STOP=1 -U postgres -d gurine <"$root"/db/test-fixtures/procurement-runtime.sql >/dev/null
printf 'procurement owner-function runtime: PASS\n'
