#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-r6d-privacy-authority-${BASHPID}"
database="gurine_event_consumers"
postgres_image="postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818"

cleanup() {
  status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    docker logs "$container" >&2 2>/dev/null || true
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

cd "$root"

mapfile -t migrations < <(printf '%s\n' db/migrations/*.sql | LC_ALL=C sort)
source scripts/apply-test-migrations-with-r6e-roles.sh
if [[ "${#migrations[@]}" -lt 41 ]]; then
  printf 'expected at least 41 migrations, found %s\n' "${#migrations[@]}" >&2
  exit 1
fi

for index in "${!migrations[@]}"; do
  ordinal=$((index + 1))
  printf -v expected_prefix '%04d_' "$ordinal"
  migration_name="$(basename "${migrations[$index]}")"
  if [[ "$migration_name" != "$expected_prefix"* ]]; then
    printf 'migration order mismatch at %s: expected %s*, found %s\n' \
      "$ordinal" "$expected_prefix" "$migration_name" >&2
    exit 1
  fi
done

if [[ "$(basename "${migrations[39]}")" != \
  '0040_r6d_privacy_authority_closure.sql' ]]; then
  printf 'migration 0040 filename is not the R6d privacy authority closure\n' >&2
  exit 1
fi

docker run --rm --detach --name "$container" \
  --env POSTGRES_DB="$database" \
  --env POSTGRES_USER=postgres \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  "$postgres_image" >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"

r6e_test_migrations_prepare "$container" "$database" "${migrations[@]}"
r6e_test_migrations_provision

for migration in "${migrations[@]:0:39}"; do
  r6e_test_migrations_apply_next "$migration"
done

# Commit two TEST_ONLY pre-0040 rows so the migration's staged-legacy behavior
# is measured against actual existing data rather than a post-migration
# simulation.  The disposable database-name guard lives in the fixture.
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -v r6d40_seed_legacy=1 -U postgres -d "$database" \
  <db/test-fixtures/r6d-privacy-authority-closure-runtime.sql >/dev/null

r6e_test_migrations_apply_next "${migrations[39]}"
r6e_test_migrations_apply_remaining
r6e_test_migrations_assert_complete

# Legal-hold receipts are retention-governance records.  Reuse the repository's
# existing disposable TEST_ONLY authority graph; no operating policy is seeded.
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  <db/test-fixtures/r6d-approved-policy-authority.sql >/dev/null

docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  <db/test-fixtures/r6d-privacy-authority-closure-runtime.sql

printf 'R6d privacy authority closure PostgreSQL runtime: PASS\n'
