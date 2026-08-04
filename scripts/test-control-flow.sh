#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-control-flow-$BASHPID"
database="gurine_control_test"
log_dir="$(mktemp -d -t gurine-control-flow-XXXXXX)"
control_pid=""
control_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
build_target="${GURINE_TEST_TARGET_DIR:-/home/dongwonttuna/.cache/gurinnae-codex-target}"

cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$control_pid" ]] && kill -0 "$control_pid" 2>/dev/null; then kill -TERM "$control_pid" 2>/dev/null || true; wait "$control_pid" 2>/dev/null || true; fi
  if [[ $status -ne 0 ]] && [[ -f "$log_dir/control.log" ]]; then tail -n 200 "$log_dir/control.log" >&2; fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$log_dir"
  exit "$status"
}
trap cleanup EXIT

cd "$root"
CARGO_TARGET_DIR="$build_target" cargo build -p gurine-control-api -p gurine-analysis-worker -p gurine-scheduler -p gurine-projection-worker
docker run --rm -d --name "$container" -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -p 127.0.0.1::5432 \
  postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818 >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
r6d_legacy_boundary_migration="db/migrations/0038_r6d_legal_hardening.sql"
r6d_authority_closure_migration="db/migrations/0039_r6d_authority_closure.sql"
r6d_privacy_authority_closure_migration="db/migrations/0040_r6d_privacy_authority_closure.sql"
r6d_f9_name_guard_closure_migration="db/migrations/0041_f9_natural_person_name_guard_closure.sql"
r6d_f3_source_url_closure_migration="db/migrations/0042_f3_public_source_url_exposure_closure.sql"
for migration in db/migrations/*.sql; do
  if [[ "$migration" == "$r6d_legacy_boundary_migration" \
    || "$migration" == "$r6d_authority_closure_migration" \
    || "$migration" == "$r6d_privacy_authority_closure_migration" \
    || "$migration" == "$r6d_f9_name_guard_closure_migration" \
    || "$migration" == "$r6d_f3_source_url_closure_migration" ]]; then
    continue
  fi
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <"$migration" >/dev/null
done
# The control runtime seed contains intentional pre-R6d historical publication
# and response rows.  Exercise the real upgrade boundary: load those rows under
# their original schema, then apply 0038 so its staged-legacy policy is tested
# instead of trying to bypass the new publication owners after migration.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <db/test-fixtures/reference-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <db/test-fixtures/control-runtime-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  <"$r6d_legacy_boundary_migration" >/dev/null
# 0039 owns only forward authority closure. It must observe the complete 0038
# schema and staged-legacy rows, never run in the pre-0038 seed boundary.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  <"$r6d_authority_closure_migration" >/dev/null
# 0040 must observe every 0039 immutable authority before it installs the
# forward-only privacy snapshot and legal-hold bindings.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  <"$r6d_privacy_authority_closure_migration" >/dev/null
# 0041 observes the legacy slug fixture, installs the NOT VALID check, and
# closes the named-person scanner/DB lower-bound gap without rewriting it.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  <"$r6d_f9_name_guard_closure_migration" >/dev/null
# 0042 replaces the archive public-text tail installed by 0038, so it must
# follow 0041 in this staged legacy-fixture migration path.
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  <"$r6d_f3_source_url_closure_migration" >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" < db/test-fixtures/r6d-approved-policy-authority.sql \
  >/dev/null
# Run the F3 PostgreSQL boundary proof before the known control-flow Python
# failure point; the fixture wraps every TEST_ONLY write in one rollback.
docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres \
  -d "$database" <db/test-fixtures/f3-public-source-url-closure.sql
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <db/test-fixtures/control-research-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <db/test-fixtures/control-retry-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <db/test-fixtures/control-withdraw-decision-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <db/test-fixtures/control-retention-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <db/test-fixtures/control-communication-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <db/test-fixtures/control-legal-hold-seed.sql >/dev/null
journey_handoff_fixture="$(docker exec "$container" psql -At -F '|' -U postgres -d "$database" -c "SELECT id,binding_digest,version FROM ops.journey_handoffs WHERE journey_code='J-01' AND edge_id='J-01-E01' AND state='PENDING_ACK' ORDER BY requested_at DESC LIMIT 1")"
IFS='|' read -r journey_handoff_id journey_handoff_binding journey_handoff_version <<<"$journey_handoff_fixture"
if [[ -z "$journey_handoff_id" || -z "$journey_handoff_binding" || -z "$journey_handoff_version" ]]; then
  echo "control-flow handoff fixture missing" >&2
  exit 1
fi
promotion_fixture="$(docker exec "$container" psql -At -F '|' -U postgres -d "$database" -c "SELECT rd.id,rd.decision_sha256,ra.artifact_sha256 FROM raw.research_artifacts ra JOIN raw.asset_rights_decisions rd ON rd.research_artifact_id=ra.id AND rd.asset_id=ra.asset_id AND rd.asset_revision=ra.asset_revision WHERE ra.id='facc134e-f4d3-551d-bb42-55d4495373ae' ORDER BY rd.decision_version DESC LIMIT 1")"
IFS='|' read -r promotion_rights_id promotion_rights_sha256 promotion_artifact_sha256 <<<"$promotion_fixture"
if [[ -z "$promotion_rights_id" || -z "$promotion_rights_sha256" || -z "$promotion_artifact_sha256" ]]; then
  echo "control-flow research promotion fixture missing" >&2
  exit 1
fi
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c "ALTER ROLE gurine_control_api LOGIN PASSWORD 'control_test'; ALTER ROLE gurine_analysis_worker LOGIN PASSWORD 'analysis_test'; ALTER ROLE gurine_scheduler LOGIN PASSWORD 'scheduler_test'; ALTER ROLE gurine_public_projector LOGIN PASSWORD 'projector_test';" >/dev/null
postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
raw_key="01234567890123456789012345678901"
test_key="$(printf '%s' "$raw_key" | base64 -w0)"
HTTP_BIND="127.0.0.1:${control_port}" CONTROL_DATABASE_URL="postgresql://gurine_control_api:control_test@127.0.0.1:${postgres_port}/${database}" IDENTITY_ASSERTION_HMAC_KEY_CURRENT="$test_key" FIELD_ENCRYPTION_KEY_CURRENT="$test_key" "$build_target/debug/gurine-control-api" >"$log_dir/control.log" 2>&1 &
control_pid=$!
for _ in $(seq 1 60); do if curl --fail --silent --show-error "http://127.0.0.1:${control_port}/health/ready" >/dev/null 2>&1; then break; fi; sleep 0.5; done
curl --fail --silent --show-error "http://127.0.0.1:${control_port}/health/ready" >/dev/null
kill -0 "$control_pid"
PYTHONDONTWRITEBYTECODE=1 CONTROL_TEST_BASE_URL="http://127.0.0.1:${control_port}" CONTROL_ASSERTION_KEY="$test_key" CONTROL_TEST_POSTGRES_CONTAINER="$container" CONTROL_TEST_POSTGRES_DATABASE="$database" CONTROL_JOURNEY_HANDOFF_ID="$journey_handoff_id" CONTROL_JOURNEY_HANDOFF_BINDING="$journey_handoff_binding" CONTROL_JOURNEY_HANDOFF_VERSION="$journey_handoff_version" CONTROL_PROMOTION_RIGHTS_ID="$promotion_rights_id" CONTROL_PROMOTION_RIGHTS_SHA256="$promotion_rights_sha256" CONTROL_PROMOTION_ARTIFACT_SHA256="$promotion_artifact_sha256" python3 tests/integration/control-flow.py
if ! grep -q 'committed in-process domain event emitted' "$log_dir/control.log"; then
  echo "control-flow committed IN_PROCESS DomainEventSink evidence missing" >&2
  exit 1
fi
SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_INSTANCE_ID="control-flow-scheduler" SCHEDULER_BATCH_SIZE=1000 SCHEDULER_ONCE=true \
  "$build_target/debug/gurine-scheduler"
# A second unchanged scheduler pass is an idempotency witness: the cron slot
# and every dispatched outbox event must already be durably claimed.
SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_INSTANCE_ID="control-flow-scheduler-replay" SCHEDULER_BATCH_SIZE=1000 SCHEDULER_ONCE=true \
  "$build_target/debug/gurine-scheduler"
PROJECTOR_DATABASE_URL="postgresql://gurine_public_projector:projector_test@127.0.0.1:${postgres_port}/${database}" \
PROJECTOR_ONCE=true HOSTNAME="control-flow-projector" "$build_target/debug/gurine-projection-worker"
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE v_event uuid; v_before text;
BEGIN
  SELECT id INTO STRICT v_event FROM ops.outbox
   WHERE event_type='projection.publication_revision_created.v1'
     AND aggregate_id='148b09d5-aa28-5351-b471-9ef333a3e410';
  IF NOT EXISTS (
    SELECT 1 FROM ops.inbox WHERE consumer='projection-worker'
      AND event_id=v_event AND processed_at IS NOT NULL AND result='SUCCEEDED'
  ) THEN
    RAISE EXCEPTION 'HTTP publication event did not reach durable projection inbox readback';
  END IF;
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object('case',to_jsonb(c),'revision',to_jsonb(r))),'sha256'),'hex')
    INTO v_before FROM public.cases c JOIN public.case_revisions r
      ON r.case_id=c.id AND r.revision=c.latest_revision
   WHERE c.id='148b09d5-aa28-5351-b471-9ef333a3e410';
  IF v_before IS NULL THEN RAISE EXCEPTION 'HTTP publication durable projection readback missing'; END IF;
  INSERT INTO ops.jobs(id,job_type,queue,payload,dedupe_key,max_attempts)
  SELECT gen_random_uuid(),'EVENT_DELIVERY','projection-worker',jsonb_build_object(
      'consumerId','projection-worker','eventId',o.id,'eventType',o.event_type,'aggregateType',o.aggregate_type,
      'aggregateId',o.aggregate_id,'aggregateVersion',o.aggregate_version,
      'occurredAt',o.occurred_at,'payload',o.payload,
      '_projectionDigestBefore',v_before),
    'control-flow-projection-replay:'||o.id::text,2
  FROM ops.outbox o WHERE o.id=v_event;
END $$;
SQL
PROJECTOR_DATABASE_URL="postgresql://gurine_public_projector:projector_test@127.0.0.1:${postgres_port}/${database}" \
PROJECTOR_ONCE=true HOSTNAME="control-flow-projector-replay" "$build_target/debug/gurine-projection-worker"
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE v_expected text; v_after text;
BEGIN
  SELECT payload->>'_projectionDigestBefore' INTO STRICT v_expected FROM ops.jobs
   WHERE dedupe_key LIKE 'control-flow-projection-replay:%' AND status='SUCCEEDED';
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object('case',to_jsonb(c),'revision',to_jsonb(r))),'sha256'),'hex')
    INTO v_after FROM public.cases c JOIN public.case_revisions r
      ON r.case_id=c.id AND r.revision=c.latest_revision
   WHERE c.id='148b09d5-aa28-5351-b471-9ef333a3e410';
  IF v_expected IS DISTINCT FROM v_after THEN
    RAISE EXCEPTION 'exact projection event replay changed durable readback';
  END IF;
END $$;
SQL
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <db/test-fixtures/control-runtime-assertions.sql >/dev/null

# The operation sweep above creates a real startAgentRun aggregate through the
# Control API. Process exactly that job with the production worker binary so
# the cross-service AGENT_CASE snapshot contract cannot regress into a
# control-generated EVIDENCE_SNAPSHOT_STALE result. Other analysis jobs belong
# to their own runtime matrices and are deferred inside this isolated database.
agent_run_id="$(docker exec "$container" psql -At -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "SELECT id FROM ops.agent_runs WHERE status='QUEUED' AND agent_type IN ('market-researcher','investigator','skeptic','claim-drafter','citation-verifier') ORDER BY created_at DESC LIMIT 1")"
if [[ -z "$agent_run_id" ]]; then
  echo "control-flow startAgentRun aggregate missing" >&2
  exit 1
fi
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "UPDATE ops.jobs SET run_after=CASE WHEN job_type='AGENT_RUN' AND payload->>'agentRunId'='$agent_run_id' THEN clock_timestamp()-interval '1 second' ELSE clock_timestamp()+interval '1 hour' END WHERE queue='analysis-worker' AND status='QUEUED';" >/dev/null
ANALYSIS_DATABASE_URL="postgresql://gurine_analysis_worker:analysis_test@127.0.0.1:${postgres_port}/${database}" \
GURINE_ENV=test AI_ENABLED=true ANALYSIS_ONCE=true HOSTNAME="control-flow-analysis" \
  "$build_target/debug/gurine-analysis-worker"
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -v agent_run_id="$agent_run_id" <<'SQL' >/dev/null
SELECT set_config('gurine.test_agent_run_id', :'agent_run_id', false);
DO $$
DECLARE run_id uuid := current_setting('gurine.test_agent_run_id')::uuid;
BEGIN
  IF (SELECT status FROM ops.agent_runs WHERE id=run_id) <> 'SUCCEEDED' THEN
    RAISE EXCEPTION 'Control API startAgentRun did not complete through analysis-worker: %',
      (SELECT jsonb_build_object('status',status,'output',output_payload)
         FROM ops.agent_runs WHERE id=run_id);
  END IF;
  IF EXISTS (
    SELECT 1 FROM ops.agent_runs
     WHERE id=run_id
       AND COALESCE(output_payload->'abstention_reasons','[]'::jsonb) ? 'EVIDENCE_SNAPSHOT_STALE'
  ) THEN
    RAISE EXCEPTION 'Control API and analysis-worker calculated different evidence snapshots';
  END IF;
  IF (SELECT status FROM ops.jobs
       WHERE job_type='AGENT_RUN' AND payload->>'agentRunId'=run_id::text) <> 'SUCCEEDED' THEN
    RAISE EXCEPTION 'Control API AGENT_RUN job did not reach SUCCEEDED';
  END IF;
END $$;
SQL
echo "control startAgentRun -> analysis-worker snapshot parity runtime: PASS"
