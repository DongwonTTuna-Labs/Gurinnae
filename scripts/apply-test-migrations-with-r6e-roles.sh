#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

r6e_migration_helper_root="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
)"
r6e_migration_helper_postgres_image="postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818"
r6e_migration_helper_exact_0041="0041_r6e_monetization_runtime.sql"
r6e_migration_helper_state="IDLE"
r6e_migration_helper_container=""
r6e_migration_helper_database=""
r6e_migration_helper_next_index=0
declare -a r6e_migration_helper_plan=()

r6e_migration_fail() {
  printf 'r6e-test-migration-helper: FAIL: %s\n' "$1" >&2
  exit 1
}

r6e_migration_canonical_path() {
  local migration="$1"
  local migration_name="${migration##*/}"
  local relative_path="db/migrations/$migration_name"
  local absolute_path="$r6e_migration_helper_root/$relative_path"

  [[ "$migration" == "$relative_path" || "$migration" == "$absolute_path" ]] ||
    r6e_migration_fail "R6E_MIGRATION_PATH_INVALID"
  printf '%s\n' "$absolute_path"
}

r6e_migration_validate_plan() {
  local migrations=("$@")
  local migration
  local migration_name
  local canonical_path
  local expected_prefix
  local exact_0041_count=0
  local index
  local -A seen_migrations=()
  local -a canonical_migrations=()
  local -a repository_plan=()

  [[ "${#migrations[@]}" -gt 0 ]] ||
    r6e_migration_fail "R6E_MIGRATION_PLAN_EMPTY"

  for index in "${!migrations[@]}"; do
    migration="${migrations[$index]}"
    migration_name="${migration##*/}"
    canonical_path="$(r6e_migration_canonical_path "$migration")"
    [[ -f "$canonical_path" && -s "$canonical_path" ]] ||
      r6e_migration_fail "R6E_MIGRATION_FILE_MISSING"
    [[ "$migration_name" =~ ^[0-9]{4}_[a-z0-9_]+\.sql$ ]] ||
      r6e_migration_fail "R6E_MIGRATION_BASENAME_INVALID"
    [[ -z "${seen_migrations[$migration_name]:-}" ]] ||
      r6e_migration_fail "R6E_MIGRATION_DUPLICATE"

    if [[ "$migration_name" == 0041_* \
      && "$migration_name" != "$r6e_migration_helper_exact_0041" ]]; then
      r6e_migration_fail "R6E_MIGRATION_0041_BASENAME_INVALID"
    fi

    seen_migrations["$migration_name"]=1
    canonical_migrations+=("$canonical_path")
    if [[ "$migration_name" == "$r6e_migration_helper_exact_0041" ]]; then
      exact_0041_count=$((exact_0041_count + 1))
    fi
  done

  [[ "$exact_0041_count" -eq 1 ]] ||
    r6e_migration_fail "R6E_MIGRATION_0041_MISSING"

  for index in "${!canonical_migrations[@]}"; do
    migration_name="${canonical_migrations[$index]##*/}"
    printf -v expected_prefix '%04d_' "$((index + 1))"
    [[ "$migration_name" == "$expected_prefix"* ]] ||
      r6e_migration_fail "R6E_MIGRATION_ORDINAL_INVALID"
  done

  mapfile -t repository_plan < <(
    printf '%s\n' "$r6e_migration_helper_root"/db/migrations/*.sql |
      LC_ALL=C sort
  )
  [[ "${#migrations[@]}" -eq "${#repository_plan[@]}" ]] ||
    r6e_migration_fail "R6E_MIGRATION_PLAN_COUNT_INVALID"
  for index in "${!repository_plan[@]}"; do
    [[ "${canonical_migrations[$index]}" == "${repository_plan[$index]}" ]] ||
      r6e_migration_fail "R6E_MIGRATION_PLAN_INVENTORY_INVALID"
  done
}

r6e_test_migrations_prepare() {
  [[ "$#" -ge 3 ]] ||
    r6e_migration_fail "R6E_MIGRATION_ARGUMENTS_INVALID"
  [[ "$r6e_migration_helper_state" == "IDLE" ]] ||
    r6e_migration_fail "R6E_MIGRATION_STATE_INVALID"

  local container="$1"
  local database="$2"
  shift 2
  local migrations=("$@")
  local target_identity

  [[ "$container" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] ||
    r6e_migration_fail "R6E_TARGET_CONTAINER_INVALID"
  [[ "$database" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] ||
    r6e_migration_fail "R6E_TARGET_DATABASE_INVALID"
  r6e_migration_validate_plan "${migrations[@]}"

  target_identity="$({
    docker exec "$container" psql \
      --no-password --no-psqlrc --quiet --tuples-only --no-align \
      --field-separator '|' --set ON_ERROR_STOP=1 \
      -U postgres -d "$database" \
      --command "SELECT current_database(),session_user,current_user,(rolsuper OR rolcreaterole) FROM pg_catalog.pg_roles WHERE rolname=session_user"
  } 2>/dev/null)" || r6e_migration_fail "R6E_TARGET_DATABASE_UNAVAILABLE"
  [[ "$target_identity" == "$database|postgres|postgres|t" ]] ||
    r6e_migration_fail "R6E_TARGET_DATABASE_ACTOR_INVALID"

  r6e_migration_helper_container="$container"
  r6e_migration_helper_database="$database"
  r6e_migration_helper_plan=()
  local migration
  for migration in "${migrations[@]}"; do
    r6e_migration_helper_plan+=(
      "$(r6e_migration_canonical_path "$migration")"
    )
  done
  r6e_migration_helper_next_index=0
  r6e_migration_helper_state="PREPARED"
}

r6e_test_migrations_provision() {
  [[ "$r6e_migration_helper_state" == "PREPARED" \
    && "$r6e_migration_helper_next_index" -eq 0 ]] ||
    r6e_migration_fail "R6E_ROLE_PROVISIONING_ORDER_INVALID"

  local database_url
  local provisioner_output
  database_url="postgresql://postgres@127.0.0.1:5432/${r6e_migration_helper_database}"
  if ! provisioner_output="$(
    docker run --rm \
      --network "container:$r6e_migration_helper_container" \
      --volume "$r6e_migration_helper_root:$r6e_migration_helper_root:ro" \
      --workdir "$r6e_migration_helper_root" \
      --env "ROLE_PROVISIONER_DATABASE_URL=$database_url" \
      --env ROLE_PROVISIONER_EXPECTED_ACTOR=postgres \
      "$r6e_migration_helper_postgres_image" \
      bash infra/scripts/provision-r6e-roles.sh 2>&1
  )"; then
    if [[ "$provisioner_output" =~ R6E_[A-Z0-9_]+ ]]; then
      r6e_migration_fail "${BASH_REMATCH[0]}"
    fi
    r6e_migration_fail "R6E_ROLE_PROVISIONING_FAILED"
  fi
  r6e_migration_helper_state="PROVISIONED"
}

r6e_test_migrations_apply_next() {
  [[ "$r6e_migration_helper_state" == "PROVISIONED" ]] ||
    r6e_migration_fail "R6E_MIGRATION_STATE_INVALID"
  [[ "$r6e_migration_helper_next_index" \
    -lt "${#r6e_migration_helper_plan[@]}" ]] ||
    r6e_migration_fail "R6E_MIGRATION_PLAN_ALREADY_COMPLETE"

  local migration
  local expected_migration
  local migration_name
  local migration_ordinal
  local migration_output
  migration="$(r6e_migration_canonical_path "$1")"
  expected_migration="${r6e_migration_helper_plan[$r6e_migration_helper_next_index]}"
  [[ "$migration" == "$expected_migration" ]] ||
    r6e_migration_fail "R6E_MIGRATION_SEQUENCE_INVALID"

  migration_name="${migration##*/}"
  migration_ordinal="${migration_name%%_*}"
  if ! migration_output="$(
    docker exec -i "$r6e_migration_helper_container" psql \
      --no-password --no-psqlrc --quiet --set ON_ERROR_STOP=1 \
      --set VERBOSITY=sqlstate \
      -U postgres -d "$r6e_migration_helper_database" \
      <"$migration" 2>&1 >/dev/null
  )"; then
    if [[ "$migration_output" =~ R6E_[A-Z0-9_]+ ]]; then
      r6e_migration_fail "${BASH_REMATCH[0]}"
    fi
    if [[ "$migration_output" =~ ERROR:[[:space:]]+([0-9A-Z]{5}) ]]; then
      r6e_migration_fail \
        "R6E_MIGRATION_SQLSTATE_${BASH_REMATCH[1]}_AT_$migration_ordinal"
    fi
    r6e_migration_fail "R6E_MIGRATION_APPLY_FAILED_$migration_ordinal"
  fi
  r6e_migration_helper_next_index=$((r6e_migration_helper_next_index + 1))
}

r6e_test_migrations_apply_remaining() {
  local migration
  while [[ "$r6e_migration_helper_next_index" \
    -lt "${#r6e_migration_helper_plan[@]}" ]]; do
    migration="${r6e_migration_helper_plan[$r6e_migration_helper_next_index]}"
    r6e_test_migrations_apply_next "$migration"
  done
}

r6e_test_migrations_assert_complete() {
  [[ "$r6e_migration_helper_state" == "PROVISIONED" \
    && "$r6e_migration_helper_next_index" \
      -eq "${#r6e_migration_helper_plan[@]}" ]] ||
    r6e_migration_fail "R6E_MIGRATION_PLAN_INCOMPLETE"
  r6e_migration_helper_state="COMPLETE"
}

r6e_migration_helper_main() {
  if [[ "${1:-}" == "--validate-only" ]]; then
    shift
    [[ "$#" -ge 3 ]] ||
      r6e_migration_fail "R6E_MIGRATION_ARGUMENTS_INVALID"
    local container="$1"
    local database="$2"
    shift 2
    [[ "$container" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] ||
      r6e_migration_fail "R6E_TARGET_CONTAINER_INVALID"
    [[ "$database" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] ||
      r6e_migration_fail "R6E_TARGET_DATABASE_INVALID"
    r6e_migration_validate_plan "$@"
    return
  fi
  [[ "${1:-}" != --* ]] ||
    r6e_migration_fail "R6E_MIGRATION_OPTION_INVALID"

  r6e_test_migrations_prepare "$@"
  r6e_test_migrations_provision
  r6e_test_migrations_apply_remaining
  r6e_test_migrations_assert_complete
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  r6e_migration_helper_main "$@"
fi
