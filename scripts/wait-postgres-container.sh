#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'usage: %s CONTAINER DATABASE\n' "$0" >&2
  exit 2
fi

container="$1"
database="$2"
attempts="${GURINE_POSTGRES_READY_ATTEMPTS:-60}"

for _ in $(seq 1 "$attempts"); do
  result="$(
    docker exec -e PGPASSWORD=postgres "$container" \
      psql -h 127.0.0.1 -v ON_ERROR_STOP=1 -U postgres -d "$database" \
      -Atqc 'SELECT 1' 2>/dev/null || true
  )"
  if [[ "$result" == "1" ]]; then
    exit 0
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]]; then
    printf 'PostgreSQL container %s exited before database %s became ready\n' \
      "$container" "$database" >&2
    docker logs --tail 120 "$container" >&2 || true
    exit 1
  fi
  sleep 0.5
done

printf 'PostgreSQL database %s in %s did not accept TCP queries after %s attempts\n' \
  "$database" "$container" "$attempts" >&2
docker logs --tail 120 "$container" >&2 || true
exit 1
