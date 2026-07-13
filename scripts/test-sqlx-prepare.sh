#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="gurine-sqlx-$BASHPID"
network="$project"
postgres_container="$project-postgres"
postgres_image="postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818"

cleanup() {
  status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]] && docker container inspect "$postgres_container" >/dev/null 2>&1; then
    docker logs --tail 200 "$postgres_container" >&2 || true
  fi
  docker rm --force "$postgres_container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

cd "$root"
docker network create "$network" >/dev/null
docker run --detach --name "$postgres_container" \
  --network "$network" --network-alias postgres \
  --publish 127.0.0.1::5432 \
  --env POSTGRES_DB=gurine \
  --env POSTGRES_USER=gurine_dev \
  --env POSTGRES_PASSWORD=gurine_dev_only \
  --env PGDATA=/var/lib/postgresql/18/docker \
  "$postgres_image" >/dev/null

for _ in $(seq 1 60); do
  if docker exec "$postgres_container" psql -U gurine_dev -d gurine -Atc 'SELECT 1' 2>/dev/null | grep -qx '1'; then
    break
  fi
  sleep 1
done
docker exec "$postgres_container" psql -U gurine_dev -d gurine -Atc 'SELECT 1' | grep -qx '1'

docker build --target migrator --file infra/docker/rust-service/Dockerfile \
  --tag gurine-sqlx-migrator:13.0.0 .
docker run --rm --network "$network" \
  --env DATABASE_URL=postgresql://gurine_dev:gurine_dev_only@postgres:5432/gurine \
  --env MIGRATOR_DATABASE_URL=postgresql://gurine_dev:gurine_dev_only@postgres:5432/gurine \
  --env GURINE_ENV=test \
  gurine-sqlx-migrator:13.0.0

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

printf 'SQLx 0.9.0 prepare --workspace --check against migrated PostgreSQL 18.4: PASS\n'
