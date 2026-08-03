#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-scheduler-runtime-$BASHPID"
database="gurine_scheduler_runtime"

cleanup() {
  status=$?
  trap - EXIT
  docker rm -f "$container" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

cd "$root"
cargo build -p gurine-scheduler -p gurine-analysis-worker -p gurine-projection-worker --bins
docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
for migration in db/migrations/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <"$migration" >/dev/null
done
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  <db/test-fixtures/control-runtime-seed.sql >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
ALTER ROLE gurine_scheduler LOGIN PASSWORD 'scheduler_test';
ALTER ROLE gurine_analysis_worker LOGIN PASSWORD 'analysis_test';
ALTER ROLE gurine_public_projector LOGIN PASSWORD 'projector_test';
SQL

actor="11111111-1111-4111-8111-111111111111"
publication="02568a6a-27f5-5ede-b5d0-21107e22a755"
due_rule="51000000-0000-4000-8000-000000000002"
future_rule="51000000-0000-4000-8000-000000000003"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<SQL >/dev/null
INSERT INTO public.cases(id,slug,title,public_state,latest_revision,summary,published_at,updated_at,source_freshness)
VALUES('148b09d5-aa28-5351-b471-9ef333a3e410','scheduler-fixture-case','Scheduler fixture',
  'TEMPORARILY_RESTRICTED',1,'Scheduler runtime projection fixture',clock_timestamp(),clock_timestamp(),'{}');
INSERT INTO public.case_revisions(case_id,revision,state,payload,payload_sha256,published_at)
VALUES('148b09d5-aa28-5351-b471-9ef333a3e410',1,'PUBLISHED_ANOMALY','{}',
  '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',clock_timestamp());

INSERT INTO editorial.publication_access_decisions(
  id,publication_revision_id,scope,state,reason,expires_at,placed_by)
VALUES
 ('52000000-0000-4000-8000-000000000001','$publication','FULL','ACTIVE','expired fixture',clock_timestamp()-interval '1 minute','$actor'),
 ('52000000-0000-4000-8000-000000000002','$publication','FULL','ACTIVE','future fixture',clock_timestamp()+interval '1 day','$actor'),
 ('52000000-0000-4000-8000-000000000003','$publication','FULL','EXPIRED','already expired fixture',clock_timestamp()-interval '1 day','$actor');

INSERT INTO core.rule_versions(
  id,rule_id,version,name,description,configuration,code_digest,status,effective_at,created_by,row_version)
VALUES
 ('51000000-0000-4000-8000-000000000001','scheduler-rule','1.0.0','Old active','Runtime fixture','{}',repeat('a',64),'ACTIVE',clock_timestamp()-interval '2 days','$actor',1),
 ('$due_rule','scheduler-rule','2.0.0','Due scheduled','Runtime fixture','{}',repeat('b',64),'SCHEDULED',clock_timestamp()-interval '1 minute','$actor',1),
 ('$future_rule','scheduler-future-rule','1.0.0','Future scheduled','Runtime fixture','{}',repeat('c',64),'SCHEDULED',clock_timestamp()+interval '1 day','$actor',1);
INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,run_after)
VALUES
 ('RULE_ACTIVATION','scheduler',jsonb_build_object(
    'ruleVersionId','$due_rule','actorId','$actor','requestId','53000000-0000-4000-8000-000000000001'),
    'scheduler-due-rule',clock_timestamp()),
 ('RULE_ACTIVATION','scheduler',jsonb_build_object(
    'ruleVersionId','$future_rule','actorId','$actor','requestId','53000000-0000-4000-8000-000000000002'),
    'scheduler-future-rule',clock_timestamp()+interval '1 day');

INSERT INTO ops.source_registry(
  source_id,display_name,connector_type,owner_team,enabled,schedule_cron,legal_status,configuration)
SELECT 'sched-'||n,'Scheduled source '||n,'HTTP','RUNTIME',true,'* * * * *','APPROVED','{}'
FROM generate_series(1,6) n;
INSERT INTO ops.source_registry(
  source_id,display_name,connector_type,owner_team,enabled,schedule_cron,legal_status,configuration)
VALUES
 ('sched-future','Future source','HTTP','RUNTIME',true,'* * * * *','APPROVED','{}'),
 ('sched-invalid','Invalid source','HTTP','RUNTIME',true,'not a cron','APPROVED','{}'),
 ('sched-disabled','Disabled source','HTTP','RUNTIME',false,'* * * * *','APPROVED','{}'),
 ('sched-blocked','Blocked source','HTTP','RUNTIME',true,'* * * * *','BLOCKED','{}');
INSERT INTO ops.source_runs(
  source_id,mode,status,scheduled_for,schedule_expression,completed_at)
VALUES('sched-future','INCREMENTAL','CANCELLED',clock_timestamp()+interval '1 hour','* * * * *',clock_timestamp());
SQL

postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
scheduler_url="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}"
analysis_url="postgresql://gurine_analysis_worker:analysis_test@127.0.0.1:${postgres_port}/${database}"
projector_url="postgresql://gurine_public_projector:projector_test@127.0.0.1:${postgres_port}/${database}"

run_scheduler() {
  local instance_id="${1:-scheduler-runtime-test}"
  SCHEDULER_DATABASE_URL="$scheduler_url" SCHEDULER_INSTANCE_ID="$instance_id" \
    SCHEDULER_BATCH_SIZE=100 SCHEDULER_ONCE=true target/debug/gurine-scheduler
}
run_workers() {
  GURINE_ENV=test AI_ENABLED=false ANALYSIS_DATABASE_URL="$analysis_url" \
    ANALYSIS_ONCE=true HOSTNAME="scheduler-analysis-test" target/debug/gurine-analysis-worker
  PROJECTOR_DATABASE_URL="$projector_url" PROJECTOR_ONCE=true \
    HOSTNAME="scheduler-projector-test" target/debug/gurine-projection-worker
}

run_scheduler scheduler-runtime-a &
scheduler_a_pid=$!
run_scheduler scheduler-runtime-b &
scheduler_b_pid=$!
wait "$scheduler_a_pid"
wait "$scheduler_b_pid"
run_workers

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.source_runs
   WHERE source_id ~ '^sched-[1-6]$' AND status='QUEUED' AND scheduled_for IS NOT NULL;
  IF actual<>6 THEN RAISE EXCEPTION 'scheduled source runs %, expected 6',actual; END IF;
  IF EXISTS(SELECT 1 FROM ops.source_runs WHERE source_id ~ '^sched-[1-6]$'
            AND scheduled_for<>date_trunc('second',scheduled_for)) THEN
    RAISE EXCEPTION 'cron slot retained sub-second precision';
  END IF;
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE job_type='SOURCE_RUN' AND queue='ingest-worker' AND payload->>'sourceRunId' IN (
     SELECT id::text FROM ops.source_runs WHERE source_id ~ '^sched-[1-6]$');
  IF actual<>6 THEN RAISE EXCEPTION 'scheduled source jobs %, expected 6',actual; END IF;
  IF EXISTS(SELECT 1 FROM ops.jobs j JOIN ops.source_runs r ON r.id::text=j.payload->>'sourceRunId'
            WHERE r.source_id IN ('sched-future','sched-invalid','sched-disabled','sched-blocked')) THEN
    RAISE EXCEPTION 'non-due or forbidden source was scheduled';
  END IF;

  IF (SELECT status FROM core.rule_versions WHERE id='51000000-0000-4000-8000-000000000001')<>'RETIRED' THEN
    RAISE EXCEPTION 'old active rule was not retired';
  END IF;
  IF (SELECT status FROM core.rule_versions WHERE id='51000000-0000-4000-8000-000000000002')<>'ACTIVE' THEN
    RAISE EXCEPTION 'due scheduled rule was not activated';
  END IF;
  IF (SELECT status FROM core.rule_versions WHERE id='51000000-0000-4000-8000-000000000003')<>'SCHEDULED' THEN
    RAISE EXCEPTION 'future rule was activated early';
  END IF;
  IF (SELECT status FROM ops.jobs WHERE dedupe_key='scheduler-due-rule')<>'SUCCEEDED' OR
     (SELECT status FROM ops.jobs WHERE dedupe_key='scheduler-future-rule')<>'QUEUED' THEN
    RAISE EXCEPTION 'rule activation job states are invalid';
  END IF;
  SELECT count(*) INTO actual FROM ops.outbox
   WHERE event_type='workflow.rule_activation_applied.v1'
     AND payload->>'ruleVersionId'='51000000-0000-4000-8000-000000000002'
     AND (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(payload) key)=ARRAY[
       'actor_id','occurred_at','operation_id','request_id','ruleVersionId','targetVersionId'];
  IF actual<>1 THEN RAISE EXCEPTION 'activation outbox payload count %, expected 1',actual; END IF;
  IF NOT EXISTS(SELECT 1 FROM ops.inbox WHERE consumer='scheduler'
    AND event_id=(SELECT id FROM ops.outbox WHERE event_type='workflow.rule_activation_applied.v1'
      AND payload->>'ruleVersionId'='51000000-0000-4000-8000-000000000002')
    AND processed_at IS NOT NULL) THEN RAISE EXCEPTION 'scheduler activation inbox not processed'; END IF;
  IF NOT EXISTS(SELECT 1 FROM ops.inbox WHERE consumer='analysis-worker'
    AND event_id=(SELECT id FROM ops.outbox WHERE event_type='workflow.rule_activation_applied.v1'
      AND payload->>'ruleVersionId'='51000000-0000-4000-8000-000000000002')
    AND processed_at IS NOT NULL) THEN RAISE EXCEPTION 'analysis activation inbox not processed'; END IF;

  IF (SELECT state FROM editorial.publication_access_decisions
      WHERE id='52000000-0000-4000-8000-000000000001')<>'EXPIRED' THEN
    RAISE EXCEPTION 'due publication restriction not expired';
  END IF;
  IF (SELECT state FROM editorial.publication_access_decisions
      WHERE id='52000000-0000-4000-8000-000000000002')<>'ACTIVE' THEN
    RAISE EXCEPTION 'future publication restriction expired early';
  END IF;
  SELECT count(*) INTO actual FROM ops.outbox
   WHERE event_type='projection.publication_access_changed.v1'
     AND aggregate_id='52000000-0000-4000-8000-000000000001'
     AND payload->>'publication_id'='02568a6a-27f5-5ede-b5d0-21107e22a755'
     AND (SELECT array_agg(key ORDER BY key) FROM jsonb_object_keys(payload) key)=ARRAY[
       'actor_id','occurred_at','operation_id','publication_id','request_id'];
  IF actual<>1 THEN RAISE EXCEPTION 'expiry projection event count %, expected 1',actual; END IF;
  IF NOT EXISTS(SELECT 1 FROM ops.inbox WHERE consumer='projection-worker'
    AND event_id=(SELECT id FROM ops.outbox WHERE aggregate_id='52000000-0000-4000-8000-000000000001'
      AND event_type='projection.publication_access_changed.v1') AND processed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'projection expiry inbox not processed';
  END IF;
  IF (SELECT public_state FROM public.cases WHERE id='148b09d5-aa28-5351-b471-9ef333a3e410')
      <>'TEMPORARILY_RESTRICTED' THEN
    RAISE EXCEPTION 'future active restriction was not preserved in projection';
  END IF;
END $$;
SQL

# A second complete pass proves the persistent source-slot, rule-state, and
# access-decision fences do not create duplicates.
run_scheduler
run_workers
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.source_runs WHERE source_id ~ '^sched-[1-6]$' AND scheduled_for IS NOT NULL;
  IF actual<>6 THEN RAISE EXCEPTION 'source schedule replay created duplicates: %',actual; END IF;
  SELECT count(*) INTO actual FROM ops.outbox WHERE event_type='workflow.rule_activation_applied.v1'
    AND payload->>'ruleVersionId'='51000000-0000-4000-8000-000000000002';
  IF actual<>1 THEN RAISE EXCEPTION 'activation replay created duplicates: %',actual; END IF;
  SELECT count(*) INTO actual FROM ops.outbox WHERE event_type='projection.publication_access_changed.v1'
    AND aggregate_id='52000000-0000-4000-8000-000000000001';
  IF actual<>1 THEN RAISE EXCEPTION 'expiry replay created duplicates: %',actual; END IF;
END $$;
SQL

# Preserve the privilege matrix: the scheduler can invoke bounded functions,
# but cannot directly read editorial data or mutate core rules.
if PGPASSWORD=scheduler_test psql "$scheduler_url" -v ON_ERROR_STOP=1 \
  -c "SELECT count(*) FROM editorial.publication_access_decisions" >/dev/null 2>&1; then
  echo "scheduler unexpectedly read editorial.publication_access_decisions" >&2
  exit 1
fi
if PGPASSWORD=scheduler_test psql "$scheduler_url" -v ON_ERROR_STOP=1 \
  -c "UPDATE core.rule_versions SET status='RETIRED' WHERE id='$future_rule'" >/dev/null 2>&1; then
  echo "scheduler unexpectedly mutated core.rule_versions directly" >&2
  exit 1
fi

echo "source cron/rule activation/restriction expiry fenced PostgreSQL scheduler runtime: PASS"
