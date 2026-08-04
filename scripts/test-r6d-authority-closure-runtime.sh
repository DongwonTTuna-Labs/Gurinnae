#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-r6d-authority-closure-${BASHPID}"
database="gurine_event_consumers"
postgres_image="postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818"
race_dir="$(mktemp -d -p "$root/.fable-sol" gurine-r6d-authority-race-XXXXXX)"
race_ready_timeout_seconds=60
hold_pid=""
closure_pid=""

cleanup() {
  status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    docker logs "$container" >&2 2>/dev/null || true
  fi
  if [[ -n "$hold_pid" ]] && kill -0 "$hold_pid" 2>/dev/null; then
    kill -TERM "$hold_pid" 2>/dev/null || true
    wait "$hold_pid" 2>/dev/null || true
  fi
  if [[ -n "$closure_pid" ]] && kill -0 "$closure_pid" 2>/dev/null; then
    kill -TERM "$closure_pid" 2>/dev/null || true
    wait "$closure_pid" 2>/dev/null || true
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$race_dir"
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

for migration in "${migrations[@]}"; do
  docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
    -U postgres -d "$database" <"$migration" >/dev/null
done

# This is the repository's existing TEST_ONLY schedule/calendar authority.  It
# rejects non-disposable database names and never becomes a production seed.
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  <db/test-fixtures/r6d-approved-policy-authority.sql >/dev/null

docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  <db/test-fixtures/r6d-authority-closure-runtime.sql >/dev/null

# Commit a dedicated TEST_ONLY graph only inside this disposable container.
# The default fixture path above remains rollback-only.  The seed mode exists
# solely so two independent PostgreSQL sessions can observe the same immutable
# entity/snapshot/STEP_UP/conflict authority while racing the actual owners.
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -v r6d39_commit_hold_race_seed=1 -U postgres -d "$database" \
  <db/test-fixtures/r6d-authority-closure-runtime.sql >/dev/null

mkfifo "$race_dir/hold.in" "$race_dir/closure.in"
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  <"$race_dir/hold.in" >"$race_dir/hold.log" 2>&1 &
hold_pid=$!
exec 9>"$race_dir/hold.in"
printf '%s\n' \
  "SET application_name='r6d39_hold_race_a';" \
  'BEGIN;' \
  "SELECT ops.place_legal_hold_v2(payload,actor_id,request_id,idempotency_key,request_digest) FROM public.r6d39_hold_race_inputs WHERE operation='HOLD';" \
  >&9

hold_ready=false
hold_ready_deadline=$((SECONDS + race_ready_timeout_seconds))
while (( SECONDS < hold_ready_deadline )); do
  hold_state="$(docker exec "$container" psql -X -At -F '|' \
    -U postgres -d "$database" -c \
    "SELECT state,wait_event_type,wait_event FROM pg_stat_activity WHERE application_name='r6d39_hold_race_a'")"
  if [[ "$hold_state" == 'idle in transaction|Client|ClientRead' ]]; then
    hold_ready=true
    break
  fi
  if ! kill -0 "$hold_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [[ "$hold_ready" != true ]]; then
  printf 'hold session did not reach an open successful transaction: %s\n' \
    "$hold_state" >&2
  cat "$race_dir/hold.log" >&2
  exit 1
fi

docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  <"$race_dir/closure.in" >"$race_dir/closure.log" 2>&1 9>&- &
closure_pid=$!
exec 8>"$race_dir/closure.in"
printf '%s\n' \
  "SET application_name='r6d39_hold_race_b';" \
  'BEGIN;' \
  "SELECT ops.attest_r6d_entity_material_use_closure_v1(payload,actor_id,session_id,request_id,idempotency_key,request_digest) FROM public.r6d39_hold_race_inputs WHERE operation='CLOSURE';" \
  >&8

closure_waited=false
closure_wait_state=""
closure_wait_deadline=$((SECONDS + race_ready_timeout_seconds))
while (( SECONDS < closure_wait_deadline )); do
  closure_wait_state="$(docker exec "$container" psql -X -At -F '|' \
    -U postgres -d "$database" -c \
    "SELECT state,wait_event_type,wait_event FROM pg_stat_activity WHERE application_name='r6d39_hold_race_b'")"
  if [[ "$closure_wait_state" == 'active|Lock|advisory' ]]; then
    closure_waited=true
    break
  fi
  if ! kill -0 "$closure_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [[ "$closure_waited" != true ]]; then
  printf 'closure session did not wait on the entity advisory lock: %s\n' \
    "$closure_wait_state" >&2
  cat "$race_dir/closure.log" >&2
  exit 1
fi

pre_release_closure_count="$(docker exec "$container" psql -X -At \
  -U postgres -d "$database" -c \
  "SELECT count(*) FROM ops.r6d_entity_material_use_closure_receipts_v1 WHERE entity_kind='AGENCY' AND entity_id='6d390000-0000-4000-8000-000000000003'")"
if [[ "$pre_release_closure_count" != 0 ]]; then
  printf 'closure wrote before the entity lock was released: %s\n' \
    "$pre_release_closure_count" >&2
  exit 1
fi

printf 'COMMIT;\n' >&9
exec 9>&-
exec 8>&-
wait "$hold_pid"
hold_pid=""
if wait "$closure_pid"; then
  printf 'closure unexpectedly succeeded after the legal hold committed\n' >&2
  exit 1
else
  closure_status=$?
fi
closure_pid=""
if [[ "$closure_status" -ne 3 ]] \
  || ! grep -Fq 'ERROR:  r6d_entity_closure_legal_hold_active' \
    "$race_dir/closure.log"; then
  printf 'closure failed with an unexpected result (status=%s)\n' \
    "$closure_status" >&2
  cat "$race_dir/closure.log" >&2
  exit 1
fi

race_result="$(docker exec "$container" psql -X -At -F '|' \
  -U postgres -d "$database" -c \
  "SELECT 'R6D39_HOLD_RACE_FINAL', (SELECT count(*) FROM ops.legal_hold_placement_receipts_v2 AS receipt JOIN ops.legal_hold_target_anchors AS anchor ON anchor.id=receipt.anchor_id JOIN ops.entity_retention_snapshots_v1 AS snapshot ON snapshot.snapshot_id=anchor.entity_retention_snapshot_id WHERE snapshot.subject_kind='AGENCY' AND snapshot.subject_id='6d390000-0000-4000-8000-000000000003'), (SELECT count(*) FROM ops.r6d_entity_material_use_closure_receipts_v1 WHERE entity_kind='AGENCY' AND entity_id='6d390000-0000-4000-8000-000000000003'), (SELECT count(*) FROM ops.audit_events WHERE request_id='6d390000-0000-4000-8000-000000000909'), (SELECT count(*) FROM ops.outbox WHERE event_type='entity.material_use_closed.v1' AND payload->>'entityId'='6d390000-0000-4000-8000-000000000003'), (SELECT r6d_closure_receipt_id IS NULL FROM core.agencies WHERE id='6d390000-0000-4000-8000-000000000003'), (ops.r6d_entity_legal_hold_coverage_v1('AGENCY','6d390000-0000-4000-8000-000000000003',clock_timestamp())->>'active'), (ops.r6d_entity_legal_hold_coverage_v1('AGENCY','6d390000-0000-4000-8000-000000000003',clock_timestamp())->>'activeCellCount')")"
if [[ "$race_result" != 'R6D39_HOLD_RACE_FINAL|1|0|0|0|t|true|1' ]]; then
  printf 'hold-vs-closure final graph mismatch: %s\n' "$race_result" >&2
  exit 1
fi

printf 'R6d entity hold/closure PostgreSQL concurrency: PASS (%s; closure=%s)\n' \
  "$closure_wait_state" "$closure_status"

# D2 source currentness uses a separate advisory namespace.  Hold that exact
# source key in session A and prove the actual fresh attestation in session B
# cannot consume a stale or concurrently changing EMAIL/DOCUMENT source.
mkfifo "$race_dir/d2-source.in" "$race_dir/d2-attest.in"
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  <"$race_dir/d2-source.in" >"$race_dir/d2-source.log" 2>&1 &
hold_pid=$!
exec 9>"$race_dir/d2-source.in"
printf '%s\n' \
  "SET application_name='r6d39_d2_source_lock_a';" \
  'BEGIN;' \
  "SELECT editorial.resolve_official_channel_source_v1(payload->>'verificationMethod',(payload->>'sourceId')::uuid,payload->>'organizationKind',(payload->>'organizationId')::uuid,actor_id,(payload->>'expiresAt')::timestamptz,clock_timestamp()) FROM public.r6d39_hold_race_inputs WHERE operation='D2_ATTEST';" \
  >&9

d2_source_ready=false
d2_source_ready_deadline=$((SECONDS + race_ready_timeout_seconds))
while (( SECONDS < d2_source_ready_deadline )); do
  d2_source_state="$(docker exec "$container" psql -X -At -F '|' \
    -U postgres -d "$database" -c \
    "SELECT state,wait_event_type,wait_event FROM pg_stat_activity WHERE application_name='r6d39_d2_source_lock_a'")"
  if [[ "$d2_source_state" == 'idle in transaction|Client|ClientRead' ]]; then
    d2_source_ready=true
    break
  fi
  if ! kill -0 "$hold_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [[ "$d2_source_ready" != true ]]; then
  printf 'D2 source lock session did not become ready: %s\n' \
    "$d2_source_state" >&2
  cat "$race_dir/d2-source.log" >&2
  exit 1
fi

docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" \
  <"$race_dir/d2-attest.in" >"$race_dir/d2-attest.log" 2>&1 9>&- &
closure_pid=$!
exec 8>"$race_dir/d2-attest.in"
printf '%s\n' \
  "SET application_name='r6d39_d2_attest_b';" \
  'BEGIN;' \
  "SELECT editorial.attest_organization_official_channel_v1(payload,actor_id,session_id,request_id,idempotency_key,request_digest) FROM public.r6d39_hold_race_inputs WHERE operation='D2_ATTEST';" \
  'COMMIT;' \
  >&8

d2_attest_waited=false
d2_attest_wait_state=""
d2_attest_wait_deadline=$((SECONDS + race_ready_timeout_seconds))
while (( SECONDS < d2_attest_wait_deadline )); do
  d2_attest_wait_state="$(docker exec "$container" psql -X -At -F '|' \
    -U postgres -d "$database" -c \
    "SELECT state,wait_event_type,wait_event FROM pg_stat_activity WHERE application_name='r6d39_d2_attest_b'")"
  if [[ "$d2_attest_wait_state" == 'active|Lock|advisory' ]]; then
    d2_attest_waited=true
    break
  fi
  if ! kill -0 "$closure_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [[ "$d2_attest_waited" != true ]]; then
  printf 'D2 attestation did not wait on the source lock: %s\n' \
    "$d2_attest_wait_state" >&2
  cat "$race_dir/d2-attest.log" >&2
  exit 1
fi

d2_pre_release_count="$(docker exec "$container" psql -X -At \
  -U postgres -d "$database" -c \
  "SELECT count(*) FROM editorial.organization_official_channel_authority_receipts_v1 WHERE source_id='6d390000-0000-4000-8000-000000000921'")"
if [[ "$d2_pre_release_count" != 0 ]]; then
  printf 'D2 attestation wrote before source lock release: %s\n' \
    "$d2_pre_release_count" >&2
  exit 1
fi

printf 'COMMIT;\n' >&9
exec 9>&-
exec 8>&-
wait "$hold_pid"
hold_pid=""
wait "$closure_pid"
closure_pid=""

d2_replayed="$(docker exec "$container" psql -X -At \
  -U postgres -d "$database" -c \
  "SELECT (editorial.attest_organization_official_channel_v1(payload,actor_id,session_id,request_id,idempotency_key,request_digest)->>'replayed')::boolean FROM public.r6d39_hold_race_inputs WHERE operation='D2_ATTEST'")"
if [[ "$d2_replayed" != t ]]; then
  printf 'D2 exact owner replay was not reported: %s\n' "$d2_replayed" >&2
  exit 1
fi

docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 \
  -U postgres -d "$database" >/dev/null <<'SQL'
DO $d2_current_and_expiry$
DECLARE
  v_assertion editorial.organization_official_channel_assertions_v1%ROWTYPE;
  v_rejected boolean:=false;
BEGIN
  SELECT * INTO STRICT v_assertion
  FROM editorial.organization_official_channel_assertions_v1
  WHERE official_document_evidence_id=
    '6d390000-0000-4000-8000-000000000921';
  PERFORM editorial.require_current_official_channel_v1(
    v_assertion.assertion_id,'AGENCY',
    '6d390000-0000-4000-8000-000000000001',
    '6d390000-0000-4000-8000-000000000050',
    '6d390000-0000-4000-8000-000000000030',
    '6d390000-0000-4000-8000-000000000021',clock_timestamp()
  );
  BEGIN
    PERFORM editorial.require_current_official_channel_v1(
      v_assertion.assertion_id,'AGENCY',
      '6d390000-0000-4000-8000-000000000001',
      '6d390000-0000-4000-8000-000000000050',
      '6d390000-0000-4000-8000-000000000030',
      '6d390000-0000-4000-8000-000000000021',
      v_assertion.expires_at+interval '1 second'
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected:=SQLERRM='official_channel_unavailable';
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'r6d39_d2_expired_channel_remained_current';
  END IF;
END
$d2_current_and_expiry$;
SQL

d2_result="$(docker exec "$container" psql -X -At -F '|' \
  -U postgres -d "$database" -c \
  "SELECT 'R6D39_D2_SOURCE_RACE_FINAL', (SELECT count(*) FROM editorial.organization_official_channel_authority_receipts_v1 WHERE source_id='6d390000-0000-4000-8000-000000000921'), (SELECT count(*) FROM editorial.organization_official_channel_assertions_v1 WHERE official_document_evidence_id='6d390000-0000-4000-8000-000000000921'), (SELECT count(*) FROM ops.audit_events WHERE request_id='6d390000-0000-4000-8000-000000000924'), (SELECT count(*) FROM editorial.organization_official_channel_revocation_receipts_v1 WHERE request_id='6d390000-0000-4000-8000-000000000043')")"
if [[ "$d2_result" != 'R6D39_D2_SOURCE_RACE_FINAL|1|1|1|1' ]]; then
  printf 'D2 source/replay/revocation final graph mismatch: %s\n' \
    "$d2_result" >&2
  exit 1
fi

printf 'R6d official-channel source PostgreSQL concurrency: PASS (%s)\n' \
  "$d2_attest_wait_state"

printf 'R6d authority closure PostgreSQL runtime: PASS (migrations=44, final=0044)\n'
