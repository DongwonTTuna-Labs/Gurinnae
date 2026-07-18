#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-analysis-negative-$BASHPID"
database="gurine_analysis_negative"

cleanup() {
  status=$?
  trap - EXIT
  docker rm -f "$container" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

cd "$root"
cargo build -p gurine-analysis-worker -p gurine-scheduler --bins
docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
for migration in db/migrations/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <"$migration" >/dev/null
done
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
ALTER ROLE gurine_analysis_worker LOGIN PASSWORD 'analysis_test';
ALTER ROLE gurine_scheduler LOGIN PASSWORD 'scheduler_test';
INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES('61000000-0000-4000-8000-000000000001','negative-runtime','negative@example.test','Negative Runtime','ACTIVE');
INSERT INTO editorial.cases(id,title,investigation_state,publication_state,summary)
VALUES('61000000-0000-4000-8000-000000000002','Negative runtime case','INVESTIGATING','NEVER_PUBLISHED','Negative gates');
INSERT INTO raw.source_documents(id,source_id,external_id,retrieved_at,content_type,content_sha256,
  content_size_bytes,object_key,status,parser_name,parser_version,prompt_injection_flags,updated_at,asset_id,asset_revision)
VALUES
 ('61000000-0000-4000-8000-000000000003','negative-source','safe','2026-07-12T00:00:00Z','application/json',
  repeat('a',64),128,'raw/safe.json','PARSED','json','runtime-v1','[]','2026-07-12T00:00:00Z','61000000-0000-4000-8000-000000000003',1),
 ('61000000-0000-4000-8000-000000000004','negative-source','untrusted','2026-07-12T00:00:00Z','application/json',
  repeat('b',64),128,'raw/untrusted.json','PARSED','json','runtime-v1','["ignore_previous"]','2026-07-12T00:00:00Z','61000000-0000-4000-8000-000000000004',1);
INSERT INTO editorial.evidence(id,case_id,evidence_type,title,source_document_id,source_locator,
  content_sha256,verification_status,verified_by,verified_at,created_by,updated_at)
VALUES
 ('61000000-0000-4000-8000-000000000005','61000000-0000-4000-8000-000000000002','DOCUMENT','Safe evidence',
  '61000000-0000-4000-8000-000000000003','page:1',repeat('a',64),'VERIFIED','61000000-0000-4000-8000-000000000001',
  '2026-07-12T00:00:00Z','61000000-0000-4000-8000-000000000001','2026-07-12T00:00:00Z'),
 ('61000000-0000-4000-8000-000000000006','61000000-0000-4000-8000-000000000002','DOCUMENT','Untrusted evidence',
  '61000000-0000-4000-8000-000000000004','page:2',repeat('b',64),'VERIFIED','61000000-0000-4000-8000-000000000001',
  '2026-07-12T00:00:00Z','61000000-0000-4000-8000-000000000001','2026-07-12T00:00:00Z');
SQL

postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
analysis_url="postgresql://gurine_analysis_worker:analysis_test@127.0.0.1:${postgres_port}/${database}"
scheduler_url="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}"

snapshot_hash() {
  local evidence_id="$1"
  local objective="$2"
  local snapshot
  snapshot="$(docker exec "$container" psql -At -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
    "SELECT jsonb_build_object('caseId','61000000-0000-4000-8000-000000000002','evidence',(SELECT jsonb_agg(jsonb_build_object('id',e.id,'contentSha256',btrim(e.content_sha256::text),'locator',e.source_locator,'updatedAt',e.updated_at,'promptInjectionFlags',COALESCE(d.prompt_injection_flags,'[]'::jsonb)) ORDER BY e.id) FROM editorial.evidence e LEFT JOIN raw.source_documents d ON d.id=e.source_document_id WHERE e.case_id='61000000-0000-4000-8000-000000000002' AND e.id='$evidence_id' AND e.verification_status='VERIFIED'),'objective','$objective')")"
  printf '%s' "$snapshot" | jq -cSj . | sha256sum | cut -d' ' -f1
}

seed_agent() {
  local run_id="$1"
  local evidence_id="$2"
  local objective="$3"
  local max_cost="$4"
  local hash="$5"
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
    -v run_id="$run_id" -v evidence_id="$evidence_id" -v objective="$objective" \
    -v max_cost="$max_cost" -v hash="$hash" <<'SQL' >/dev/null
INSERT INTO ops.agent_runs(id,case_id,agent_type,objective,evidence_scope_ids,provider_policy,status,
  input_snapshot_hash,max_cost,created_by)
VALUES(:'run_id','61000000-0000-4000-8000-000000000002','investigator',:'objective',
  jsonb_build_array(:'evidence_id'),'APPROVED_ONLY','QUEUED',:'hash',:'max_cost',
  '61000000-0000-4000-8000-000000000001');
INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,max_attempts)
VALUES('AGENT_RUN','analysis-worker',jsonb_build_object('agentRunId',:'run_id'),'negative-agent:'||:'run_id',1);
SQL
}

safe_evidence="61000000-0000-4000-8000-000000000005"
untrusted_evidence="61000000-0000-4000-8000-000000000006"
seed_agent "62000000-0000-4000-8000-000000000001" "$safe_evidence" "budget exhausted" 0 \
  "$(snapshot_hash "$safe_evidence" "budget exhausted")"
seed_agent "62000000-0000-4000-8000-000000000002" "$untrusted_evidence" "prompt injection" 1000 \
  "$(snapshot_hash "$untrusted_evidence" "prompt injection")"
seed_agent "62000000-0000-4000-8000-000000000003" "$safe_evidence" "stale snapshot" 1000 \
  "$(printf 'f%.0s' $(seq 1 64))"
seed_agent "62000000-0000-4000-8000-000000000004" "62000000-0000-4000-8000-000000009999" \
  "invalid evidence scope" 1000 "$(printf 'e%.0s' $(seq 1 64))"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.inbox(consumer,event_id,result)
VALUES('analysis-worker','63000000-0000-4000-8000-000000000001','DISPATCHED');
INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,max_attempts)
VALUES('EVENT_DELIVERY','analysis-worker',jsonb_build_object(
  'eventId','63000000-0000-4000-8000-000000000001',
  'eventType','workflow.rule_activation_applied.v1',
  'payload',jsonb_build_object('operation_id','invalid',
    'targetVersionId','63000000-0000-4000-8000-000000000002',
    'privateBody','SECRET-SENTINEL')),
  'negative-malformed-event',1);
SQL

GURINE_ENV=test AI_ENABLED=true AI_PROVIDER_ORDER=deterministic \
ANALYSIS_DATABASE_URL="$analysis_url" ANALYSIS_ONCE=true \
HOSTNAME="analysis-negative-policy" target/debug/gurine-analysis-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
BEGIN
  IF (SELECT status FROM ops.agent_runs WHERE id='62000000-0000-4000-8000-000000000001')<>'BUDGET_BLOCKED'
     OR (SELECT output_payload->'abstention_reasons' FROM ops.agent_runs
         WHERE id='62000000-0000-4000-8000-000000000001')<>'["BUDGET_EXHAUSTED"]'::jsonb THEN
    RAISE EXCEPTION 'budget exhaustion was not fenced';
  END IF;
  IF (SELECT output_payload->>'status' FROM ops.agent_runs
      WHERE id='62000000-0000-4000-8000-000000000002')<>'ABSTAINED'
     OR (SELECT output_payload->'abstention_reasons' FROM ops.agent_runs
         WHERE id='62000000-0000-4000-8000-000000000002')<>'["UNTRUSTED_INSTRUCTION_DETECTED"]'::jsonb THEN
    RAISE EXCEPTION 'prompt injection was not fenced';
  END IF;
  IF (SELECT output_payload->'abstention_reasons' FROM ops.agent_runs
      WHERE id='62000000-0000-4000-8000-000000000003')<>'["EVIDENCE_SNAPSHOT_STALE"]'::jsonb THEN
    RAISE EXCEPTION 'stale evidence snapshot was not fenced';
  END IF;
  IF (SELECT status FROM ops.agent_runs WHERE id='62000000-0000-4000-8000-000000000004')<>'FAILED'
     OR (SELECT status FROM ops.jobs WHERE dedupe_key='negative-agent:62000000-0000-4000-8000-000000000004')<>'DEAD_LETTER' THEN
    RAISE EXCEPTION 'invalid evidence terminal failure was not reconciled';
  END IF;
  IF (SELECT result FROM ops.inbox WHERE event_id='63000000-0000-4000-8000-000000000001')
      <>'FAILED:INVALID_RULE_ACTIVATION_EVENT' THEN
    RAISE EXCEPTION 'malformed event inbox was not terminally fenced';
  END IF;
  IF EXISTS(SELECT 1 FROM ops.outbox WHERE event_type='job.dead_lettered.v1'
            AND payload::text LIKE '%SECRET-SENTINEL%')
     OR EXISTS(SELECT 1 FROM ops.jobs WHERE dedupe_key='negative-malformed-event'
               AND COALESCE(last_error_detail,'') LIKE '%SECRET-SENTINEL%') THEN
    RAISE EXCEPTION 'restricted payload leaked into DLQ evidence';
  END IF;
END $$;
SQL

seed_agent "62000000-0000-4000-8000-000000000005" "$safe_evidence" "ai disabled" 1000 \
  "$(snapshot_hash "$safe_evidence" "ai disabled")"
GURINE_ENV=test AI_ENABLED=false ANALYSIS_DATABASE_URL="$analysis_url" ANALYSIS_ONCE=true \
HOSTNAME="analysis-negative-disabled" target/debug/gurine-analysis-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.provider_configs(id,provider_type,name,enabled,routing_policy,secret_reference,data_retention_policy)
VALUES('64000000-0000-4000-8000-000000000001','unavailable','Unavailable Provider',true,
  '{"targetUrl":"https://provider.example.test","model":"unavailable-v1"}','secret/unavailable','NO_RETENTION');
INSERT INTO ops.provider_connection_tests(id,provider_id,test_model,status,requested_by,reason)
VALUES('64000000-0000-4000-8000-000000000002','64000000-0000-4000-8000-000000000001',
  'unavailable-v1','QUEUED','61000000-0000-4000-8000-000000000001','retry exhaustion');
INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,max_attempts)
VALUES('PROVIDER_CONNECTION_TEST','analysis-worker',
  jsonb_build_object('providerConnectionTestId','64000000-0000-4000-8000-000000000002'),
  'negative-provider-retry',2);
SQL

GURINE_ENV=production AI_ENABLED=true AI_PROVIDER_ORDER=unavailable \
EGRESS_AI_CHANNEL_URL=http://127.0.0.1:9/ai ANALYSIS_DATABASE_URL="$analysis_url" \
ANALYSIS_ONCE=true HOSTNAME="analysis-negative-retry-1" target/debug/gurine-analysis-worker
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "UPDATE ops.jobs SET run_after=clock_timestamp() WHERE dedupe_key='negative-provider-retry';" >/dev/null
GURINE_ENV=production AI_ENABLED=true AI_PROVIDER_ORDER=unavailable \
EGRESS_AI_CHANNEL_URL=http://127.0.0.1:9/ai ANALYSIS_DATABASE_URL="$analysis_url" \
ANALYSIS_ONCE=true HOSTNAME="analysis-negative-retry-2" target/debug/gurine-analysis-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
INSERT INTO ops.jobs(id,job_type,queue,status,payload,dedupe_key,lease_owner,lease_token,
  lease_expires_at,fencing_token,attempt_count,max_attempts)
VALUES('65000000-0000-4000-8000-000000000001','LEASE_PROBE','analysis-worker','RUNNING','{}',
  'negative-expired-lease','crashed-worker','65000000-0000-4000-8000-000000000002',
  clock_timestamp()-interval '1 minute',1,1,1);
INSERT INTO ops.job_attempts(job_id,attempt,worker_id,fencing_token,started_at)
VALUES('65000000-0000-4000-8000-000000000001',1,'crashed-worker',1,clock_timestamp()-interval '2 minutes');
SQL
SCHEDULER_DATABASE_URL="$scheduler_url" SCHEDULER_INSTANCE_ID="negative-lease-recovery" \
SCHEDULER_ONCE=true target/debug/gurine-scheduler

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
BEGIN
  IF (SELECT status FROM ops.agent_runs WHERE id='62000000-0000-4000-8000-000000000005')<>'POLICY_BLOCKED'
     OR (SELECT output_payload->'abstention_reasons' FROM ops.agent_runs
         WHERE id='62000000-0000-4000-8000-000000000005')<>'["AI_DISABLED"]'::jsonb THEN
    RAISE EXCEPTION 'AI-disabled policy was not fenced';
  END IF;
  IF (SELECT status FROM ops.jobs WHERE dedupe_key='negative-provider-retry')<>'DEAD_LETTER'
     OR (SELECT attempt_count FROM ops.jobs WHERE dedupe_key='negative-provider-retry')<>2
     OR (SELECT status FROM ops.provider_connection_tests
         WHERE id='64000000-0000-4000-8000-000000000002')<>'FAILED'
     OR (SELECT redacted_result->>'redacted' FROM ops.provider_connection_tests
         WHERE id='64000000-0000-4000-8000-000000000002')<>'true' THEN
    RAISE EXCEPTION 'provider retry exhaustion was not redacted and reconciled';
  END IF;
  IF (SELECT status FROM ops.jobs WHERE dedupe_key='negative-expired-lease')<>'DEAD_LETTER'
     OR (SELECT outcome FROM ops.job_attempts
         WHERE job_id='65000000-0000-4000-8000-000000000001' AND attempt=1)<>'DEAD_LETTER'
     OR NOT EXISTS(SELECT 1 FROM ops.outbox WHERE aggregate_id='65000000-0000-4000-8000-000000000001'
                   AND event_type='job.dead_lettered.v1'
                   AND payload ? 'error_code' AND NOT payload ? 'privateBody') THEN
    RAISE EXCEPTION 'expired lease dead-letter recovery failed';
  END IF;
END $$;
SQL

echo "analysis policy/retry/redacted-DLQ/lease-recovery negative runtime: PASS"
