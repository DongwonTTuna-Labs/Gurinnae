#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="gurine-sqlx-$BASHPID"
network="$project"
postgres_container="$project-postgres"
postgres_image="postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818"
resource_label="io.gurinnae.sqlx-run"
network_created=0
container_created=0

owned_container() {
  [[ "$(docker container inspect --format '{{ index .Config.Labels "io.gurinnae.sqlx-run" }}' "$postgres_container")" == "$project" ]]
}

owned_network() {
  [[ "$(docker network inspect --format '{{ index .Labels "io.gurinnae.sqlx-run" }}' "$network")" == "$project" ]]
}

cleanup() {
  status=$?
  cleanup_error=0
  trap - EXIT
  if [[ "$container_created" -eq 1 ]] && docker container inspect "$postgres_container" >/dev/null 2>&1; then
    if owned_container; then
      if [[ "$status" -ne 0 ]]; then
        docker logs --tail 200 "$postgres_container" >&2 || true
      fi
      docker rm --force --volumes "$postgres_container" >/dev/null 2>&1 || cleanup_error=1
    else
      printf 'refusing to remove unowned container %s\n' "$postgres_container" >&2
      cleanup_error=1
    fi
  fi
  if [[ "$network_created" -eq 1 ]] && docker network inspect "$network" >/dev/null 2>&1; then
    if owned_network; then
      docker network rm "$network" >/dev/null 2>&1 || cleanup_error=1
    else
      printf 'refusing to remove unowned network %s\n' "$network" >&2
      cleanup_error=1
    fi
  fi
  if [[ "$status" -eq 0 && "$cleanup_error" -ne 0 ]]; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

cd "$root"
metadata_count="$(find .sqlx -maxdepth 1 -type f -name 'query-*.json' -print | wc -l)"
[[ "$metadata_count" -gt 0 ]] || {
  printf 'SQLx offline metadata is empty; run scripts/dev-db.sh migrate and cargo sqlx prepare\n' >&2
  exit 1
}
docker network create --label "$resource_label=$project" "$network" >/dev/null
network_created=1
docker run --detach --name "$postgres_container" \
  --label "$resource_label=$project" \
  --network "$network" --network-alias postgres \
  --publish 127.0.0.1::5432 \
  --env POSTGRES_DB=gurine \
  --env POSTGRES_USER=gurine_dev \
  --env POSTGRES_PASSWORD=gurine_dev_only \
  --env PGDATA=/var/lib/postgresql/18/docker \
  "$postgres_image" >/dev/null
container_created=1

ready_streak=0
for _ in $(seq 1 60); do
  if docker exec --env PGPASSWORD=gurine_dev_only "$postgres_container" \
    psql -h 127.0.0.1 -U gurine_dev -d gurine -Atc 'SELECT 1' 2>/dev/null | grep -qx '1'; then
    ready_streak=$((ready_streak + 1))
    if [[ "$ready_streak" -ge 2 ]]; then
      break
    fi
  else
    ready_streak=0
  fi
  sleep 1
done
[[ "$ready_streak" -ge 2 ]] || {
  printf 'PostgreSQL did not remain ready for two consecutive probes\n' >&2
  exit 1
}

docker build --target migrator --file infra/docker/rust-service/Dockerfile \
  --tag gurine-sqlx-migrator:13.0.0 .
docker run --rm --network "$network" \
  --env DATABASE_URL=postgresql://gurine_dev:gurine_dev_only@postgres:5432/gurine \
  --env MIGRATOR_DATABASE_URL=postgresql://gurine_dev:gurine_dev_only@postgres:5432/gurine \
  --env GURINE_ENV=test \
  gurine-sqlx-migrator:13.0.0

# The immutable authority baseline remains 24 migrations, while the runtime
# image must apply the complete thirteen-file post-base set as well. Assert both
# the count and the contiguous version sequence so a missing or out-of-order
# migration cannot be hidden by a successful SQLx run.
expected_migration_count="$(
  python3 "$root/scripts/verify_migrations.py" --print-runtime-count
)"
[[ "$expected_migration_count" =~ ^[0-9]+$ ]] || {
  printf 'invalid expected migration count: %s\n' "$expected_migration_count" >&2
  exit 1
}
expected_versions="$(seq -s, 1 "$expected_migration_count")"
actual_migrations="$(docker exec "$postgres_container" psql -U gurine_dev -d gurine -Atc \
  "SELECT count(*) || '|' || coalesce(string_agg(version::text, ',' ORDER BY version), '') FROM _sqlx_migrations WHERE success;")"
[[ "$actual_migrations" == "$expected_migration_count|$expected_versions" ]] || {
  printf 'runtime migration canary failed: expected %s|%s, found %s\n' "$expected_migration_count" "$expected_versions" "$actual_migrations" >&2
  exit 1
}

host_port="$(docker port "$postgres_container" 5432/tcp | sed -E 's/^.*:([0-9]+)$/\1/')"
[[ "$host_port" =~ ^[0-9]+$ ]]
export DATABASE_URL="postgresql://gurine_dev:gurine_dev_only@127.0.0.1:${host_port}/gurine"
sqlx_prepare_nonce="$(date +%s%N)-$BASHPID"
docker build --network host \
  --build-arg "SQLX_PREPARE_NONCE=$sqlx_prepare_nonce" \
  --secret id=database_url,env=DATABASE_URL \
  --target sqlx-prepare-test \
  --output type=cacheonly \
  --file infra/docker/rust-service/Dockerfile .

printf 'SQLx 0.9.0 prepare --workspace --check -- --all-targets metadata diff against migrated PostgreSQL 18.4: PASS (%s files)\n' "$metadata_count"
