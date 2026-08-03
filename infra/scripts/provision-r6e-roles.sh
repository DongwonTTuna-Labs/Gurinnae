#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
control_plane_dir="$root/db/control-plane"
provisioning_sql="$control_plane_dir/r6e-role-provisioning.sql"
provisioning_manifest="$control_plane_dir/r6e-role-provisioning.sha256"
migration_sql="$root/db/migrations/0041_r6e_monetization_runtime.sql"

fail() {
  printf 'r6e-role-provisioner: FAIL: %s\n' "$1" >&2
  exit 1
}

for command in awk mktemp psql rm sha256sum sha384sum; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

[[ -n "${ROLE_PROVISIONER_DATABASE_URL:-}" ]] ||
  fail "ROLE_PROVISIONER_DATABASE_URL is required"
[[ -n "${ROLE_PROVISIONER_EXPECTED_ACTOR:-}" ]] ||
  fail "ROLE_PROVISIONER_EXPECTED_ACTOR is required"
[[ "$ROLE_PROVISIONER_EXPECTED_ACTOR" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] ||
  fail "ROLE_PROVISIONER_EXPECTED_ACTOR must be an unquoted PostgreSQL role name"

[[ -f "$provisioning_sql" && -s "$provisioning_sql" ]] ||
  fail "checksummed provisioning SQL is missing"
[[ -f "$provisioning_manifest" && -s "$provisioning_manifest" ]] ||
  fail "provisioning checksum manifest is missing"
[[ -f "$migration_sql" && -s "$migration_sql" ]] ||
  fail "0041 migration SQL is missing"

if ! (
  cd "$control_plane_dir"
  sha256sum --check --strict --status "${provisioning_manifest##*/}"
); then
  fail "provisioning SQL checksum mismatch"
fi

expected_migration_checksum="$(sha384sum -- "$migration_sql" | awk '{print $1}')" ||
  fail "0041 migration checksum could not be computed"
[[ "$expected_migration_checksum" =~ ^[0-9a-f]{96}$ ]] ||
  fail "0041 migration checksum is invalid"

error_log="$(mktemp)" || fail "redacted error buffer could not be created"
cleanup() {
  rm -f -- "$error_log"
}
trap cleanup EXIT

if ! PGAPPNAME=gurinnae-r6e-role-provisioner \
  psql "$ROLE_PROVISIONER_DATABASE_URL" \
    --no-password \
    --no-psqlrc \
    --quiet \
    --set ON_ERROR_STOP=1 \
    --set "expected_actor=$ROLE_PROVISIONER_EXPECTED_ACTOR" \
    --set "expected_migration_checksum=$expected_migration_checksum" \
    --file "$provisioning_sql" \
    >/dev/null 2>"$error_log"; then
  error_code="$(LC_ALL=C awk '
    match($0,/R6E_[A-Z0-9_]+/) {
      print substr($0,RSTART,RLENGTH)
      exit
    }
  ' "$error_log")"
  if [[ "$error_code" =~ ^R6E_[A-Z0-9_]+$ ]]; then
    fail "$error_code"
  fi
  fail "control-plane role transaction failed; database diagnostics redacted"
fi

cleanup
trap - EXIT
printf 'r6e-role-provisioner: PASS\n'
