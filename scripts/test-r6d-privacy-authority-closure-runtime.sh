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
if [[ "${#migrations[@]}" -ne 44 ]]; then
  printf 'expected exactly 44 migrations, found %s\n' "${#migrations[@]}" >&2
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

if [[ "$(basename "${migrations[40]}")" != \
  '0041_f9_natural_person_name_guard_closure.sql' ]]; then
  printf 'migration 0041 filename is not the F9 natural-person name guard closure\n' >&2
  exit 1
fi

if [[ "$(basename "${migrations[41]}")" != \
  '0042_f3_public_source_url_exposure_closure.sql' ]]; then
  printf 'migration 0042 filename is not the F3 public source URL exposure closure\n' >&2
  exit 1
fi

if [[ "$(basename "${migrations[42]}")" != \
  '0043_b1_public_slug_rename_authority.sql' ]]; then
  printf 'migration 0043 filename is not the B1 public slug rename authority\n' >&2
  exit 1
fi

if [[ "$(basename "${migrations[43]}")" != \
  '0044_b2_natural_person_detection_digest_closure.sql' ]]; then
  printf 'migration 0044 filename is not the B2 natural-person closure\n' >&2
  exit 1
fi

docker run --rm --detach --name "$container" \
  --env POSTGRES_DB="$database" \
  --env POSTGRES_USER=postgres \
  --env POSTGRES_PASSWORD=postgres \
  "$postgres_image" >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"

for migration in "${migrations[@]:0:39}"; do
  docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
    -U postgres -d "$database" <"$migration" >/dev/null
done

# Commit two TEST_ONLY pre-0040 rows so the migration's staged-legacy behavior
# is measured against actual existing data rather than a post-migration
# simulation.  The disposable database-name guard lives in the fixture.
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -v r6d40_seed_legacy=1 -U postgres -d "$database" \
  <db/test-fixtures/r6d-privacy-authority-closure-runtime.sql >/dev/null

docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" <"${migrations[39]}" >/dev/null

# Apply the F9 forward-only closure after 0040 has classified the committed
# legacy rows.  This preserves the pre-0040 fixture boundary exactly.
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" <"${migrations[40]}" >/dev/null

# Apply the F3 public source URL exposure closure after the archive scanner
# functions and F9 lower-bound contract are present.
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" <"${migrations[41]}" >/dev/null

# Apply the forward-only B1 slug rename authority after the 0041 guard defect
# and the globally ordered 0042 closure.
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" <"${migrations[42]}" >/dev/null

# Apply the B2 immutable scanner policy and SQL lower-bound closure last.
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" <"${migrations[43]}" >/dev/null

# Legal-hold receipts are retention-governance records.  Reuse the repository's
# existing disposable TEST_ONLY authority graph; no operating policy is seeded.
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  <db/test-fixtures/r6d-approved-policy-authority.sql >/dev/null

docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  <db/test-fixtures/r6d-privacy-authority-closure-runtime.sql

printf 'R6d privacy authority closure PostgreSQL runtime: PASS (migrations=44, final=0044)\n'
