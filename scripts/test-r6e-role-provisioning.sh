#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
postgres_image="postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818"
container="gurinnae-r6e-role-provisioning-$BASHPID"
database="gurine"
test_password="r6e-test-only-password"
test_tmp="$(mktemp -d -t gurinnae-r6e-role-provisioning-XXXXXX)"

cleanup() {
  docker rm --force --volumes "$container" >/dev/null 2>&1 || true
  rm -rf -- "$test_tmp"
}
trap cleanup EXIT

fail() {
  printf 'r6e-role-provisioning-test: FAIL: %s\n' "$1" >&2
  exit 1
}

psql_in() {
  local target_database="$1"
  shift
  docker exec "$container" \
    psql -U postgres -d "$target_database" -X -qAt -v ON_ERROR_STOP=1 "$@"
}

run_provisioner_for_database() {
  local target_database="$1"
  local actor="${2:-postgres}"
  local actor_password="${3:-$test_password}"
  local expected_actor="${4:-$actor}"
  docker exec \
    --env "ROLE_PROVISIONER_DATABASE_URL=postgresql://${actor}:${actor_password}@127.0.0.1:5432/${target_database}" \
    --env "ROLE_PROVISIONER_EXPECTED_ACTOR=$expected_actor" \
    "$container" \
    /workspace/infra/scripts/provision-r6e-roles.sh
}

run_provisioner() {
  run_provisioner_for_database "$database"
}

expect_provisioner_failure_from() {
  local expected_code="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "provisioner unexpectedly accepted $expected_code"
  fi
  [[ "$output" == *"$expected_code"* ]] ||
    fail "provisioner did not report $expected_code"
  [[ "$output" != *"postgresql://"* && "$output" != *"$test_password"* ]] ||
    fail "redacted failure output exposed a URL or credential"
}

expect_provisioner_failure() {
  local expected_code="$1"
  expect_provisioner_failure_from "$expected_code" run_provisioner
}

run_cross_database_provisioners() {
  local primary_output="$test_tmp/primary.out"
  local secondary_output="$test_tmp/secondary.out"
  local primary_pid secondary_pid
  local primary_status=0
  local secondary_status=0

  run_provisioner_for_database "$database" >"$primary_output" 2>&1 &
  primary_pid=$!
  run_provisioner_for_database r6e_other_database >"$secondary_output" 2>&1 &
  secondary_pid=$!
  wait "$primary_pid" || primary_status=$?
  wait "$secondary_pid" || secondary_status=$?

  if [[ "$primary_status" -ne 0 || "$secondary_status" -ne 0 ]]; then
    if grep -Eq 'postgresql://|r6e-test-only-password' \
      "$primary_output" "$secondary_output"; then
      fail "concurrent provisioning failure exposed a URL or credential"
    fi
    printf 'primary concurrent provisioner: %s\n' \
      "$(<"$primary_output")" >&2
    printf 'secondary concurrent provisioner: %s\n' \
      "$(<"$secondary_output")" >&2
    fail "cross-database concurrent provisioning did not converge"
  fi
  grep -qx 'r6e-role-provisioner: PASS' "$primary_output" ||
    fail "primary concurrent provisioner did not report PASS"
  grep -qx 'r6e-role-provisioner: PASS' "$secondary_output" ||
    fail "secondary concurrent provisioner did not report PASS"
}

drop_target_roles() {
  psql_in "$database" -c '
    DROP ROLE IF EXISTS
      gurine_economics_writer,
      gurine_payment_writer,
      gurine_billing_gateway,
      gurine_economics_importer;
  ' >/dev/null
}

assert_pristine_roles() {
  local result
  result="$(psql_in "$database" -c "
    WITH expected(role_name,can_login,connection_limit) AS (
      VALUES
        ('gurine_economics_writer'::text,false,-1),
        ('gurine_payment_writer'::text,false,-1),
        ('gurine_billing_gateway'::text,true,8),
        ('gurine_economics_importer'::text,true,4)
    ), exact_roles AS (
      SELECT auth.oid
      FROM expected
      JOIN pg_authid AS auth ON auth.rolname=expected.role_name
      JOIN pg_roles AS visible_role ON visible_role.oid=auth.oid
      WHERE visible_role.rolcanlogin=expected.can_login
        AND visible_role.rolconnlimit=expected.connection_limit
        AND NOT visible_role.rolsuper
        AND NOT visible_role.rolcreatedb
        AND NOT visible_role.rolcreaterole
        AND NOT visible_role.rolinherit
        AND NOT visible_role.rolreplication
        AND NOT visible_role.rolbypassrls
        AND auth.rolpassword IS NULL
        AND visible_role.rolvaliduntil IS NULL
        AND visible_role.rolconfig IS NULL
    )
    SELECT (SELECT count(*) FROM exact_roles)=4
      AND NOT EXISTS (
        SELECT 1 FROM pg_auth_members AS membership
        JOIN exact_roles AS role
          ON role.oid=membership.roleid OR role.oid=membership.member
      )
      AND NOT EXISTS (
        SELECT 1 FROM pg_db_role_setting AS setting
        JOIN exact_roles AS role ON role.oid=setting.setrole
      )
      AND NOT EXISTS (
        SELECT 1 FROM pg_shdepend AS dependency
        JOIN exact_roles AS role ON role.oid=dependency.refobjid
        WHERE dependency.refclassid='pg_authid'::regclass
          AND dependency.deptype IN ('a','o')
      );
  ")"
  [[ "$result" == "t" ]] || fail "fresh roles are not cluster-wide pristine"
}

docker run --detach \
  --name "$container" \
  --env "POSTGRES_PASSWORD=$test_password" \
  --env "POSTGRES_DB=$database" \
  --volume "$root:/workspace:ro" \
  "$postgres_image" >/dev/null

for attempt in $(seq 1 60); do
  if psql_in "$database" -c 'SELECT 1' 2>/dev/null | grep -qx 1; then
    break
  fi
  [[ "$attempt" -lt 60 ]] || fail "PostgreSQL 18.4 did not become ready"
  sleep 1
done

[[ "$(psql_in "$database" -c "
  SELECT count(*) FROM pg_roles
  WHERE rolname LIKE 'gurine_economics_%'
    OR rolname IN ('gurine_payment_writer','gurine_billing_gateway');
")" == "0" ]] || fail "fresh cluster unexpectedly contains an R6e role"
psql_in postgres -c 'CREATE DATABASE r6e_other_database' >/dev/null
run_cross_database_provisioners
assert_pristine_roles
run_provisioner >/dev/null
run_provisioner_for_database r6e_other_database >/dev/null

expect_provisioner_failure_from \
  R6E_ROLE_PROVISIONER_ACTOR_INVALID \
  run_provisioner_for_database "$database" postgres "$test_password" r6e_wrong_actor

psql_in "$database" -c "
  CREATE ROLE r6e_createrole_probe
    LOGIN NOSUPERUSER NOCREATEDB CREATEROLE NOINHERIT NOREPLICATION
    NOBYPASSRLS PASSWORD '$test_password';
" >/dev/null
expect_provisioner_failure_from \
  R6E_ROLE_PROVISIONER_ACTOR_INVALID \
  run_provisioner_for_database "$database" r6e_createrole_probe "$test_password"
psql_in "$database" -c 'DROP ROLE r6e_createrole_probe' >/dev/null

psql_in "$database" -c 'CREATE SCHEMA ops' >/dev/null
expect_provisioner_failure R6E_PRE_0041_DATABASE_NOT_PRISTINE
psql_in "$database" -c 'DROP SCHEMA ops' >/dev/null

psql_in "$database" -c 'DROP ROLE gurine_economics_importer' >/dev/null
expect_provisioner_failure R6E_PRE_0041_ROLE_SET_PARTIAL
[[ "$(psql_in "$database" -c "SELECT count(*) FROM pg_roles WHERE rolname='gurine_economics_importer'")" == "0" ]] ||
  fail "partial state was silently repaired"
drop_target_roles
run_provisioner >/dev/null

psql_in "$database" -c 'ALTER ROLE gurine_billing_gateway INHERIT' >/dev/null
expect_provisioner_failure R6E_RUNTIME_ROLE_ATTRIBUTES_INVALID
[[ "$(psql_in "$database" -c "SELECT rolinherit FROM pg_authid WHERE rolname='gurine_billing_gateway'")" == "t" ]] ||
  fail "attribute drift was silently repaired"
drop_target_roles
run_provisioner >/dev/null

psql_in "$database" -c "ALTER ROLE gurine_billing_gateway PASSWORD 'test-only-drift'" >/dev/null
expect_provisioner_failure R6E_RUNTIME_ROLE_ATTRIBUTES_INVALID
[[ "$(psql_in "$database" -c "SELECT rolpassword IS NULL FROM pg_authid WHERE rolname='gurine_billing_gateway'")" == "f" ]] ||
  fail "password drift was silently repaired"
drop_target_roles
run_provisioner >/dev/null

psql_in "$database" -c "ALTER ROLE gurine_economics_importer VALID UNTIL '2030-01-01 00:00:00Z'" >/dev/null
expect_provisioner_failure R6E_RUNTIME_ROLE_ATTRIBUTES_INVALID
drop_target_roles
run_provisioner >/dev/null

psql_in "$database" -c "ALTER ROLE gurine_economics_importer SET application_name='r6e-reuse'" >/dev/null
expect_provisioner_failure R6E_RUNTIME_ROLE_ATTRIBUTES_INVALID
drop_target_roles
run_provisioner >/dev/null

psql_in "$database" -c 'CREATE ROLE r6e_membership_probe NOLOGIN' >/dev/null
psql_in "$database" -c 'GRANT r6e_membership_probe TO gurine_billing_gateway' >/dev/null
expect_provisioner_failure R6E_RUNTIME_ROLE_MEMBERSHIP_FORBIDDEN
psql_in "$database" -c 'REVOKE r6e_membership_probe FROM gurine_billing_gateway' >/dev/null
psql_in "$database" -c 'GRANT gurine_billing_gateway TO r6e_membership_probe' >/dev/null
expect_provisioner_failure R6E_RUNTIME_ROLE_MEMBERSHIP_FORBIDDEN
psql_in "$database" -c 'REVOKE gurine_billing_gateway FROM r6e_membership_probe' >/dev/null
psql_in "$database" -c 'DROP ROLE r6e_membership_probe' >/dev/null

psql_in "$database" -c 'GRANT USAGE ON SCHEMA public TO gurine_billing_gateway' >/dev/null
expect_provisioner_failure R6E_PRE_0041_ROLE_AUTHORITY_FORBIDDEN
psql_in "$database" -c 'REVOKE USAGE ON SCHEMA public FROM gurine_billing_gateway' >/dev/null

psql_in "$database" -c 'CREATE TABLE public.r6e_current_acl_probe(id bigint)' >/dev/null
psql_in "$database" -c 'GRANT SELECT ON public.r6e_current_acl_probe TO gurine_billing_gateway' >/dev/null
expect_provisioner_failure R6E_PRE_0041_DATABASE_NOT_PRISTINE
psql_in "$database" -c 'REVOKE SELECT ON public.r6e_current_acl_probe FROM gurine_billing_gateway' >/dev/null
psql_in "$database" -c 'DROP TABLE public.r6e_current_acl_probe' >/dev/null

psql_in postgres -c 'GRANT CONNECT ON DATABASE r6e_other_database TO gurine_billing_gateway' >/dev/null
expect_provisioner_failure R6E_PRE_0041_ROLE_AUTHORITY_FORBIDDEN
psql_in postgres -c 'REVOKE CONNECT ON DATABASE r6e_other_database FROM gurine_billing_gateway' >/dev/null

psql_in r6e_other_database -c 'CREATE TABLE public.r6e_cross_database_probe(id bigint)' >/dev/null
psql_in r6e_other_database -c 'GRANT SELECT ON public.r6e_cross_database_probe TO gurine_billing_gateway' >/dev/null
expect_provisioner_failure R6E_PRE_0041_ROLE_AUTHORITY_FORBIDDEN
psql_in r6e_other_database -c 'REVOKE SELECT ON public.r6e_cross_database_probe FROM gurine_billing_gateway' >/dev/null

psql_in r6e_other_database -c 'ALTER TABLE public.r6e_cross_database_probe OWNER TO gurine_billing_gateway' >/dev/null
expect_provisioner_failure R6E_PRE_0041_ROLE_AUTHORITY_FORBIDDEN
psql_in r6e_other_database -c 'ALTER TABLE public.r6e_cross_database_probe OWNER TO postgres' >/dev/null

psql_in postgres -c "ALTER ROLE gurine_billing_gateway IN DATABASE r6e_other_database SET application_name='r6e-cross-database-reuse'" >/dev/null
expect_provisioner_failure R6E_RUNTIME_ROLE_SETTING_FORBIDDEN
psql_in postgres -c 'ALTER ROLE gurine_billing_gateway IN DATABASE r6e_other_database RESET application_name' >/dev/null
psql_in r6e_other_database -c 'DROP TABLE public.r6e_cross_database_probe' >/dev/null
psql_in postgres -c 'DROP DATABASE r6e_other_database' >/dev/null

assert_pristine_roles
printf 'r6e role provisioning fresh, concurrent, partial, drift, membership, and cross-database reuse: PASS\n'
