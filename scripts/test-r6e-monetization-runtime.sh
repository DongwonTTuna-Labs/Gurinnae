#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-r6e-monetization-${BASHPID}"
database="gurine_r6e_monetization"
postgres_image="postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818"
lease_mode=false
scenario_id="ALL"
failure_stage="arguments"
container_started=false
ephemeral_roles_enabled=false
migration_error_log=""
fixture_error_log=""

restore_ephemeral_roles() {
  docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
    -U postgres -d "$database" >/dev/null 2>/dev/null <<'R6E_RESTORE_SQL'
DO $r6e_ephemeral_role_restore$
DECLARE
  v_names constant text[] := ARRAY[
    'gurine_control_api','gurine_public_api','gurine_public_projector',
    'gurine_workflow_worker'
  ];
  v_role text;
BEGIN
  IF (SELECT count(*) FROM pg_authid WHERE rolname=ANY(v_names))<>4 THEN
    RAISE EXCEPTION 'R6E_EPHEMERAL_ROLE_RESTORE_PRECONDITION';
  END IF;
  FOREACH v_role IN ARRAY v_names LOOP
    EXECUTE format('ALTER ROLE %I NOLOGIN PASSWORD NULL',v_role);
  END LOOP;
  IF EXISTS (
    SELECT 1 FROM pg_authid
    WHERE rolname=ANY(v_names) AND (rolcanlogin OR rolpassword IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'R6E_EPHEMERAL_ROLE_RESTORE_FAILED';
  END IF;
END
$r6e_ephemeral_role_restore$;
R6E_RESTORE_SQL
}

if [[ $# -eq 2 && "$1" == "--lease" ]]; then
  case "$2" in
    AC-BUSINESS_MODEL-04[2-8])
      lease_mode=true
      scenario_id="$2"
      ;;
    *)
      printf 'R6e runtime prerequisite scenario is not allowed\n' >&2
      exit 2
      ;;
  esac
elif [[ $# -ne 0 ]]; then
  printf 'usage: %s [--lease AC-BUSINESS_MODEL-04N]\n' "$0" >&2
  exit 2
fi

cleanup() {
  status=$?
  trap - EXIT
  restore_failed=false
  cleanup_failed=false
  if [[ -n "$migration_error_log" ]]; then
    rm -f -- "$migration_error_log"
  fi
  if [[ -n "$fixture_error_log" ]]; then
    rm -f -- "$fixture_error_log"
  fi
  if [[ "$ephemeral_roles_enabled" == true ]] &&
    ! restore_ephemeral_roles; then
    restore_failed=true
  fi
  if [[ "$container_started" == true ]] &&
    ! docker rm -f "$container" >/dev/null 2>&1; then
    cleanup_failed=true
  fi
  if [[ "$status" -ne 0 ]]; then
    printf 'R6E_RUNTIME_PREREQUISITE: FAIL: %s\n' "$failure_stage" >&2
  elif [[ "$restore_failed" == true || "$cleanup_failed" == true ]]; then
    printf 'R6E_RUNTIME_PREREQUISITE: FAIL: role-restore-or-cleanup\n' >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

cd "$root"

failure_stage="fixture-contract-state"
mapfile -t fixture_contract_states < <(
  awk '$1=="--" && $2=="R6E_OWNER_ABI_STATE:" { print $3 }' \
    db/test-fixtures/r6e-monetization-runtime.sql
)
if [[ "${#fixture_contract_states[@]}" -ne 1 ]] ||
  [[ ! "${fixture_contract_states[0]}" =~ ^(PENDING|FINAL)$ ]]; then
  exit 1
fi
fixture_contract_state="${fixture_contract_states[0]}"
if [[ "$fixture_contract_state" != "FINAL" ]]; then
  failure_stage="owner-abi-not-final"
  exit 1
fi

failure_stage="migration-inventory"
mapfile -t migrations < <(printf '%s\n' db/migrations/*.sql | LC_ALL=C sort)
bash scripts/apply-test-migrations-with-r6e-roles.sh \
  --validate-only invalid-plan-container "$database" "${migrations[@]}"
r6e_migration=""
without_r6e_migration=()
for migration in "${migrations[@]}"; do
  if [[ "${migration##*/}" == "0041_r6e_monetization_runtime.sql" ]]; then
    r6e_migration="$migration"
  else
    without_r6e_migration+=("$migration")
  fi
done
[[ -n "$r6e_migration" ]] || exit 1

expect_plan_failure() {
  local expected_code="$1"
  shift
  local output
  if output="$(
    bash scripts/apply-test-migrations-with-r6e-roles.sh \
      --validate-only invalid-plan-container "$database" "$@" 2>&1
  )"; then
    printf 'migration helper accepted invalid plan: %s\n' "$expected_code" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected_code"* ]]; then
    printf 'migration helper did not report %s\n' "$expected_code" >&2
    exit 1
  fi
}

expect_plan_failure R6E_MIGRATION_0041_MISSING \
  "${without_r6e_migration[@]}"
expect_plan_failure R6E_MIGRATION_DUPLICATE \
  "${migrations[@]}" "$r6e_migration"
gap_plan=("${migrations[0]}" "${migrations[@]:2}")
expect_plan_failure R6E_MIGRATION_ORDINAL_INVALID "${gap_plan[@]}"

failure_stage="postgres-start"
container_started=true
docker run --rm --detach --name "$container" \
  --publish 127.0.0.1::5432 \
  --env POSTGRES_DB="$database" \
  --env POSTGRES_USER=postgres \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  "$postgres_image" >/dev/null
failure_stage="postgres-ready"
bash scripts/wait-postgres-container.sh "$container" "$database" \
  >/dev/null 2>/dev/null

failure_stage="migrations-and-roles"
migration_error_log="$(mktemp)"
if ! bash scripts/apply-test-migrations-with-r6e-roles.sh \
  "$container" "$database" "${migrations[@]}" \
  >/dev/null 2>"$migration_error_log"; then
  migration_error_code="$(
    LC_ALL=C awk 'match($0,/R6E_[A-Z0-9_]+/) {
      print substr($0,RSTART,RLENGTH); exit
    }' "$migration_error_log"
  )"
  rm -f -- "$migration_error_log"
  migration_error_log=""
  if [[ "$migration_error_code" =~ ^R6E_[A-Z0-9_]+$ ]]; then
    failure_stage="migrations-and-roles:${migration_error_code}"
  fi
  exit 1
fi
rm -f -- "$migration_error_log"
migration_error_log=""

failure_stage="ephemeral-role-auth"
ephemeral_roles_enabled=true
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" >/dev/null 2>/dev/null <<'R6E_AUTH_SQL'
DO $r6e_ephemeral_role_auth$
DECLARE
  v_names constant text[] := ARRAY[
    'gurine_control_api','gurine_public_api','gurine_public_projector',
    'gurine_workflow_worker'
  ];
  v_owner_names constant text[] := ARRAY[
    'gurine_billing_gateway','gurine_economics_importer'
  ];
  v_oids oid[];
  v_count bigint;
  v_all_no_login boolean;
  v_auth_before jsonb;
  v_membership_before jsonb;
  v_dependencies_before jsonb;
  v_catalog_before jsonb;
  v_owner_auth_before jsonb;
  v_auth_after jsonb;
  v_membership_after jsonb;
  v_dependencies_after jsonb;
  v_catalog_after jsonb;
  v_owner_auth_after jsonb;
  v_role text;
BEGIN
  SELECT array_agg(oid ORDER BY rolname),count(*),bool_and(NOT rolcanlogin),
    jsonb_agg(to_jsonb(a)-'rolcanlogin' ORDER BY rolname)
  INTO v_oids,v_count,v_all_no_login,v_auth_before
  FROM pg_authid AS a
  WHERE rolname=ANY(v_names);
  IF v_count<>4 OR v_all_no_login IS DISTINCT FROM true OR EXISTS (
    SELECT 1 FROM pg_authid AS a
    WHERE a.rolname=ANY(v_names) AND a.rolpassword IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'R6E_EPHEMERAL_ROLE_PRECONDITION';
  END IF;
  SELECT jsonb_agg(to_jsonb(a) ORDER BY a.rolname)
  INTO v_catalog_before
  FROM pg_authid AS a;
  SELECT jsonb_agg(to_jsonb(a) ORDER BY a.rolname)
  INTO v_owner_auth_before
  FROM pg_authid AS a
  WHERE a.rolname=ANY(v_owner_names);
  IF jsonb_array_length(COALESCE(v_owner_auth_before,'[]'::jsonb))<>2 THEN
    RAISE EXCEPTION 'R6E_CANONICAL_OWNER_ROLE_PRECONDITION';
  END IF;
  SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY roleid,member,grantor),'[]')
  INTO v_membership_before
  FROM pg_auth_members AS m
  WHERE roleid=ANY(v_oids) OR member=ANY(v_oids);
  SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY dbid,classid,objid,objsubid),'[]')
  INTO v_dependencies_before
  FROM pg_shdepend AS d
  WHERE refclassid='pg_authid'::regclass AND refobjid=ANY(v_oids);
  FOREACH v_role IN ARRAY v_names LOOP
    EXECUTE format('ALTER ROLE %I LOGIN PASSWORD NULL',v_role);
  END LOOP;
  SELECT jsonb_agg(to_jsonb(a)-'rolcanlogin' ORDER BY rolname)
  INTO v_auth_after
  FROM pg_authid AS a
  WHERE rolname=ANY(v_names)
    AND rolcanlogin
    AND rolpassword IS NULL;
  SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY roleid,member,grantor),'[]')
  INTO v_membership_after
  FROM pg_auth_members AS m
  WHERE roleid=ANY(v_oids) OR member=ANY(v_oids);
  SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY dbid,classid,objid,objsubid),'[]')
  INTO v_dependencies_after
  FROM pg_shdepend AS d
  WHERE refclassid='pg_authid'::regclass AND refobjid=ANY(v_oids);
  SELECT jsonb_agg(
    CASE WHEN a.rolname=ANY(v_names)
      THEN to_jsonb(a)||jsonb_build_object('rolcanlogin',false)
      ELSE to_jsonb(a)
    END ORDER BY a.rolname
  )
  INTO v_catalog_after
  FROM pg_authid AS a;
  SELECT jsonb_agg(to_jsonb(a) ORDER BY a.rolname)
  INTO v_owner_auth_after
  FROM pg_authid AS a
  WHERE a.rolname=ANY(v_owner_names);
  IF v_auth_after IS DISTINCT FROM v_auth_before
     OR v_membership_after IS DISTINCT FROM v_membership_before
     OR v_dependencies_after IS DISTINCT FROM v_dependencies_before
     OR v_catalog_after IS DISTINCT FROM v_catalog_before
     OR v_owner_auth_after IS DISTINCT FROM v_owner_auth_before THEN
    RAISE EXCEPTION 'R6E_EPHEMERAL_ROLE_AUTH_INVARIANT';
  END IF;
END
$r6e_ephemeral_role_auth$;
R6E_AUTH_SQL

failure_stage="exact-role-sessions"
postgres_endpoint="$(docker port "$container" 5432/tcp)"
postgres_port="${postgres_endpoint##*:}"
if [[ ! "$postgres_port" =~ ^[0-9]{1,5}$ ]]; then
  exit 1
fi
for runtime_role in gurine_control_api gurine_economics_importer \
  gurine_billing_gateway gurine_public_api gurine_public_projector \
  gurine_workflow_worker; do
  role_session="$({
    PGHOST=127.0.0.1 \
    PGPORT="$postgres_port" \
    PGDATABASE="$database" \
    PGUSER="$runtime_role" \
    PGCONNECT_TIMEOUT=5 \
    docker run --rm --network host \
      --env PGHOST --env PGPORT --env PGDATABASE --env PGUSER \
      --env PGCONNECT_TIMEOUT \
      "$postgres_image" \
      psql -X -Atq --no-password -c 'SELECT session_user'
  } 2>/dev/null)"
  if [[ "$role_session" != "$runtime_role" ]]; then
    exit 1
  fi
done

fixture_failure_code() {
  LC_ALL=C awk 'match($0,/R6E_[A-Z0-9_]+/) {
    print substr($0,RSTART,RLENGTH); exit
  }' "$fixture_error_log"
}

run_admin_fixture_phase() {
  local phase="$1"
  local phase_output
  local failure_code
  fixture_error_log="$(mktemp)"
  if ! phase_output="$(
    docker exec -i "$container" psql -X -Atq -v ON_ERROR_STOP=1 \
      -v phase="$phase" -v scenario_id="$scenario_id" \
      -v expected_session_user=postgres \
      -U postgres -d "$database" \
      <db/test-fixtures/r6e-monetization-runtime.sql \
      2>"$fixture_error_log"
  )"; then
    failure_code="$(fixture_failure_code)"
    rm -f -- "$fixture_error_log"
    fixture_error_log=""
    if [[ "$failure_code" =~ ^R6E_[A-Z0-9_]+$ ]]; then
      failure_stage="fixture-${phase}:${failure_code}"
    else
      failure_stage="fixture-${phase}"
    fi
    return 1
  fi
  rm -f -- "$fixture_error_log"
  fixture_error_log=""
  printf '%s' "$phase_output"
}

run_role_fixture_phase() {
  local phase="$1"
  local runtime_role="$2"
  local phase_output
  local failure_code
  case "$runtime_role" in
    gurine_billing_gateway|gurine_control_api|gurine_economics_importer|\
    gurine_public_api|gurine_public_projector|gurine_workflow_worker) ;;
    *)
      failure_stage="fixture-${phase}:R6E_FIXTURE_ROLE_INVALID"
      return 1
      ;;
  esac
  fixture_error_log="$(mktemp)"
  if ! phase_output="$(
    PGHOST=127.0.0.1 \
    PGPORT="$postgres_port" \
    PGDATABASE="$database" \
    PGUSER="$runtime_role" \
    PGCONNECT_TIMEOUT=5 \
    docker run --rm --network host \
      --env PGHOST --env PGPORT --env PGDATABASE --env PGUSER \
      --env PGCONNECT_TIMEOUT \
      "$postgres_image" \
      psql -X -Atq --no-password -v ON_ERROR_STOP=1 \
        -v phase="$phase" -v scenario_id="$scenario_id" \
        -v expected_session_user="$runtime_role" \
      <db/test-fixtures/r6e-monetization-runtime.sql \
      2>"$fixture_error_log"
  )"; then
    failure_code="$(fixture_failure_code)"
    rm -f -- "$fixture_error_log"
    fixture_error_log=""
    if [[ "$failure_code" =~ ^R6E_[A-Z0-9_]+$ ]]; then
      failure_stage="fixture-${phase}:${failure_code}"
    else
      failure_stage="fixture-${phase}"
    fi
    return 1
  fi
  rm -f -- "$fixture_error_log"
  fixture_error_log=""
  printf '%s' "$phase_output"
}

failure_stage="fixture"
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  <db/test-fixtures/r6e-monetization-runtime.sql >/dev/null 2>/dev/null

failure_stage="lease"
if [[ "$lease_mode" == true ]]; then
  printf '{"container":"%s","database":"%s","host":"127.0.0.1","port":%s,"scenario_id":"%s","schema_version":1,"status":"READY"}\n' \
    "$container" "$database" "$postgres_port" "$scenario_id"
  IFS= read -r _ || true
else
  printf 'R6e monetization PostgreSQL runtime: PASS\n'
fi
