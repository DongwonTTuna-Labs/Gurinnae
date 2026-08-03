#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="gurinnae-devdb"
container="gurinnae-devdb-postgres"
host_port="15432"
database="gurine"
database_user="gurine_dev"
database_password="gurine_dev_only"
compose_override="$(printf '%s\n' \
  'services:' \
  '  postgres:' \
  "    container_name: $container" \
  '    ports:' \
  "    - 127.0.0.1:${host_port}:5432" \
  'networks:' \
  '  data:' \
  '    internal: false')"

dev_compose() {
  docker compose \
    --project-name "$project" \
    --file "$root/compose.yaml" \
    --file <(printf '%s\n' "$compose_override") \
    "$@"
}

fail() {
  printf 'dev-db: %s\n' "$*" >&2
  exit 1
}

container_exists() {
  docker container inspect "$container" >/dev/null 2>&1
}

validate_container_owner() {
  local owner service
  owner="$(docker container inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$container")"
  service="$(docker container inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$container")"
  [[ "$owner" == "$project" && "$service" == "postgres" ]] ||
    fail "refusing to manage $container owned by project=${owner:-<none>} service=${service:-<none>}"
}

container_running() {
  [[ "$(docker container inspect --format '{{.State.Running}}' "$container")" == "true" ]]
}

wait_ready() {
  local attempt
  for attempt in $(seq 1 60); do
    if docker exec --env "PGPASSWORD=$database_password" "$container" \
      psql -h 127.0.0.1 -U "$database_user" -d "$database" -Atc 'SELECT 1' 2>/dev/null |
      grep -qx '1'; then
      return 0
    fi
    sleep 1
  done
  docker logs --tail 100 "$container" >&2 || true
  fail "PostgreSQL did not become ready within 60 seconds"
}

require_running() {
  container_exists || fail "database is not running; run scripts/dev-db.sh up first"
  validate_container_owner
  container_running || fail "database container exists but is stopped; run scripts/dev-db.sh up"
}

up() {
  if container_exists; then
    validate_container_owner
  fi
  dev_compose up --detach --no-deps postgres
  wait_ready
  docker port "$container" 5432/tcp | grep -qx "127.0.0.1:${host_port}"
  printf 'dev-db: PostgreSQL 18.4 ready on 127.0.0.1:%s\n' "$host_port"
}

migrate() {
  local expected_versions actual_migrations internal_url
  require_running
  wait_ready
  internal_url="postgresql://${database_user}:${database_password}@postgres:5432/${database}"
  DATABASE_URL="$internal_url" \
    MIGRATOR_DATABASE_URL="$internal_url" \
    GURINE_ENV=test \
    dev_compose run --rm --no-deps --build migrator

  expected_versions="$(seq -s, 1 30)"
  actual_migrations="$(docker exec "$container" psql -U "$database_user" -d "$database" -Atc \
    "SELECT count(*) || '|' || coalesce(string_agg(version::text, ',' ORDER BY version), '') FROM _sqlx_migrations WHERE success;")"
  [[ "$actual_migrations" == "30|$expected_versions" ]] ||
    fail "migration canary expected 30|$expected_versions, found $actual_migrations"
  printf 'dev-db: migrations 1..30 applied\n'
}

url() {
  require_running
  printf 'postgresql://%s:%s@127.0.0.1:%s/%s\n' \
    "$database_user" "$database_password" "$host_port" "$database"
}

down() {
  if container_exists; then
    validate_container_owner
  fi
  dev_compose down --volumes
  printf 'dev-db: project %s removed\n' "$project"
}

usage() {
  printf 'usage: %s {up|migrate|url|down}\n' "${0##*/}" >&2
  exit 2
}

case "${1:-}" in
  up) up ;;
  migrate) migrate ;;
  url) url ;;
  down) down ;;
  *) usage ;;
esac
