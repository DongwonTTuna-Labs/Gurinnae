#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-analysis-runtime-$BASHPID"
database="gurine_analysis_runtime"
temp="$(mktemp -d -t gurine-analysis-runtime-XXXXXX)"
provider_pid=""
gateway_pid=""

cleanup() {
  status=$?
  trap - EXIT
  for pid in "$gateway_pid" "$provider_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ $status -ne 0 ]]; then
    for log in "$temp"/*.log; do
      [[ -f "$log" ]] && tail -n 120 "$log" >&2
    done
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$temp"
  exit "$status"
}
trap cleanup EXIT

cd "$root"
cargo build -p gurine-analysis-worker -p gurine-egress-gateway --bins
free_port() {
  local port
  while true; do
    port="$(shuf -i 30000-45000 -n 1)"
    if ! ss -ltn "sport = :$port" | tail -n +2 | grep -q .; then
      printf '%s' "$port"
      return
    fi
  done
}
provider_port="$(free_port)"
gateway_port="$(free_port)"
provider_key="runtime-openai-key-never-persist"
selected_content='runtime-selected-source-bytes-v13'
selected_sha256="$(printf '%s' "$selected_content" | sha256sum | cut -d' ' -f1)"
mkdir -p "$temp/objects/raw"
printf '%s' "$selected_content" >"$temp/objects/raw/analysis-document.json"
docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
for migration in db/migrations/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <"$migration" >/dev/null
done
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "ALTER ROLE gurine_analysis_worker LOGIN PASSWORD 'analysis_test';" >/dev/null

actor="41000000-0000-4000-8000-000000000001"
case_id="41000000-0000-4000-8000-000000000002"
document_id="41000000-0000-4000-8000-000000000003"
evidence_id="41000000-0000-4000-8000-000000000004"
provider_id="41000000-0000-4000-8000-000000000005"
provider_test_id="41000000-0000-4000-8000-000000000006"

AI_PROVIDER_TEST_PORT="$provider_port" AI_PROVIDER_EXPECTED_KEY="$provider_key" \
AI_PROVIDER_EVIDENCE_ID="$evidence_id" AI_PROVIDER_EVIDENCE_LOCATOR="page:7" \
AI_PROVIDER_EXPECTED_CONTENT_B64="$(printf '%s' "$selected_content" | base64 -w0)" \
AI_PROVIDER_EXPECTED_CONTENT_SHA256="$selected_sha256" \
  bun run tests/integration/ai-provider-upstream.ts >"$temp/provider.log" 2>&1 &
provider_pid=$!
GURINE_ENV=test HTTP_BIND="127.0.0.1:$gateway_port" OIDC_ISSUER_HOST=localhost \
AI_PROVIDER_HOSTS=localhost OPENAI_API_KEY="$provider_key" \
OBJECT_STORE_ADAPTER=filesystem OBJECT_STORE_FILESYSTEM_ROOT="$temp/objects" \
  target/debug/gurine-egress-gateway >"$temp/gateway.log" 2>&1 &
gateway_pid=$!
for endpoint in "http://127.0.0.1:$provider_port/health" "http://127.0.0.1:$gateway_port/health/ready"; do
  for _ in $(seq 1 60); do
    if curl --fail --silent --show-error "$endpoint" >/dev/null 2>&1; then break; fi
    sleep 0.25
  done
  curl --fail --silent --show-error "$endpoint" >/dev/null
done

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<SQL >/dev/null
INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES('$actor','analysis-runtime','analysis@example.test','Analysis Runtime','ACTIVE');
INSERT INTO editorial.cases(id,title,investigation_state,publication_state,summary)
VALUES('$case_id','Analysis runtime case','INVESTIGATING','NEVER_PUBLISHED','Runtime evidence case');
INSERT INTO raw.source_documents(id,source_id,external_id,retrieved_at,content_type,content_sha256,
  content_size_bytes,object_key,status,parser_name,parser_version,prompt_injection_flags,updated_at,asset_id,asset_revision)
VALUES('$document_id','analysis-source','analysis-document','2026-07-12T00:00:00Z','application/json',
  repeat('a',64),128,'raw/analysis-document.json','PARSED','json','runtime-v1','[]','2026-07-12T00:00:00Z','$document_id',1);
INSERT INTO editorial.evidence(id,case_id,evidence_type,title,source_document_id,source_locator,
  content_sha256,verification_status,verified_by,verified_at,created_by,updated_at)
VALUES('$evidence_id','$case_id','DOCUMENT','Verified runtime evidence','$document_id','page:7',
  repeat('a',64),'VERIFIED','$actor','2026-07-12T00:00:00Z','$actor','2026-07-12T00:00:00Z');
INSERT INTO ops.provider_configs(id,provider_type,name,enabled,routing_policy,secret_reference,
  data_retention_policy)
VALUES('$provider_id','openai','Runtime Provider',true,
  jsonb_build_object('targetUrl','http://localhost:$provider_port/agent','model','authority-double-v1',
    'pricing',jsonb_build_object('currency','KRW','pricingVersion','runtime-v1',
      'pricingSha256','b8b195a7f9fc71a2adb5dec8f49be073b75db56365fa6939917b3b626024ea20',
      'inputMicrosKrwPerUnit',8500000,'outputMicrosKrwPerUnit',8500000)),
  'none','NO_RETENTION');
INSERT INTO ops.provider_connection_tests(id,provider_id,test_model,status,requested_by,reason)
VALUES('$provider_test_id','$provider_id','authority-double-v1','QUEUED','$actor','runtime test');
INSERT INTO ops.budget_limits(scope,daily_limit,monthly_limit,currency,updated_by)
VALUES ('ENVIRONMENT:PRODUCTION',100000,1000000,'KRW','$actor'),
       ('PROVIDER:$provider_id',100000,1000000,'KRW','$actor'),
       ('CASE:$case_id',100000,1000000,'KRW','$actor');
INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key)
VALUES('PROVIDER_CONNECTION_TEST','analysis-worker',
  jsonb_build_object('providerConnectionTestId','$provider_test_id'),'provider-test:$provider_test_id');
SQL

sed -e "s/:'document_id'/'$document_id'/g" -e "s/:'evidence_id'/'$evidence_id'/g" \
    -e "s/:'actor_id'/'$actor'/g" -e "s/repeat('3',64)/'$selected_sha256'/g" db/test-fixtures/analysis-source-graph.sql \
  | docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" >/dev/null

rules=(
  contract_amendment_escalation contract_splitting_pattern low_bid_competition
  new_supplier_dependence price_outlier repeated_single_source restrictive_specification
  shared_supplier_identity supplier_concentration year_end_spending_spike
)
index=0
for rule_file in "${rules[@]}"; do
  index=$((index + 1))
  rule_id="$(head -1 "specs/detection/evals/${rule_file}.jsonl" | jq -r '.rule_id')"
  input="$(head -1 "specs/detection/evals/${rule_file}.jsonl" | jq -c '.input')"
  rule_uuid="$(printf '42000000-0000-4000-8000-%012d' "$index")"
  evaluation_uuid="$(printf '43000000-0000-4000-8000-%012d' "$index")"
  dataset_uuid="$(printf '44000000-0000-4000-8000-%012d' "$index")"
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
    -v rule_id="$rule_id" -v input="$input" -v rule_uuid="$rule_uuid" \
    -v evaluation_uuid="$evaluation_uuid" -v dataset_uuid="$dataset_uuid" <<'SQL' >/dev/null
INSERT INTO core.rule_versions(id,rule_id,version,name,description,configuration,code_digest,status,created_by)
VALUES(:'rule_uuid',:'rule_id','1.0.0',:'rule_id','runtime evaluation',
  jsonb_build_object('evaluationInput',:'input'::jsonb,'severity','HIGH'),repeat('b',64),'ACTIVE',
  '41000000-0000-4000-8000-000000000001');
INSERT INTO core.rule_evaluations(id,rule_version_id,dataset_snapshot_id,evaluation_profile,status,requested_by,reason)
VALUES(:'evaluation_uuid',:'rule_uuid',:'dataset_uuid','FULL','QUEUED',
  '41000000-0000-4000-8000-000000000001','runtime evaluation');
INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key)
VALUES('RULE_EVALUATION','analysis-worker',jsonb_build_object('evaluationId',:'evaluation_uuid'),
  'rule-evaluation:'||:'evaluation_uuid');
SQL
done

agents=(market-researcher investigator skeptic claim-drafter citation-verifier)
snapshot="$(docker exec "$container" psql -At -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "SELECT jsonb_build_object('caseId','$case_id','evidence',(SELECT jsonb_agg(jsonb_build_object('id',e.id,'contentSha256',btrim(e.content_sha256::text),'locator',e.source_locator,'updatedAt',e.updated_at,'promptInjectionFlags',COALESCE(d.prompt_injection_flags,'[]'::jsonb)) ORDER BY e.id) FROM editorial.evidence e LEFT JOIN raw.source_documents d ON d.id=e.source_document_id WHERE e.case_id='$case_id' AND e.id='$evidence_id' AND e.verification_status='VERIFIED'))")"
snapshot_hash="$(printf '%s' "$snapshot" | jq -cSj . | sha256sum | cut -d' ' -f1)"
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -c "UPDATE core.dataset_snapshots SET snapshot_sha256='$snapshot_hash' WHERE id='46000000-0000-4000-8000-000000000007';" >/dev/null
index=0
for agent in "${agents[@]}"; do
  index=$((index + 1))
  run_id="$(printf '45000000-0000-4000-8000-%012d' "$index")"
  objective="Runtime objective for $agent"
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
    -v run_id="$run_id" -v agent="$agent" -v objective="$objective" -v document_id="$document_id" \
    -v snapshot_hash="$snapshot_hash" <<'SQL' >/dev/null
INSERT INTO ops.agent_runs(id,case_id,agent_type,objective,evidence_scope_ids,provider_policy,status,
  input_snapshot_hash,max_cost,created_by)
VALUES(:'run_id','41000000-0000-4000-8000-000000000002',:'agent',:'objective',
  '["41000000-0000-4000-8000-000000000004"]','APPROVED_ONLY','QUEUED',:'snapshot_hash',1000,
  '41000000-0000-4000-8000-000000000001');
INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key)
VALUES('AGENT_RUN','analysis-worker',jsonb_build_object('agentRunId',:'run_id'),'agent-run:'||:'run_id');
SQL
done

postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
GURINE_ENV=production AI_ENABLED=true AI_PROVIDER_ORDER=openai \
EGRESS_AI_CHANNEL_URL="http://127.0.0.1:$gateway_port/ai" \
EGRESS_SOURCE_CHANNEL_URL="http://127.0.0.1:$gateway_port/source" \
EGRESS_OBJECT_STORE_CHANNEL_URL="http://127.0.0.1:$gateway_port/object-store" \
ANALYSIS_DATABASE_URL="postgresql://gurine_analysis_worker:analysis_test@127.0.0.1:${postgres_port}/${database}" \
ANALYSIS_ONCE=true HOSTNAME="analysis-runtime-test" target/debug/gurine-analysis-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.jobs WHERE queue='analysis-worker' AND status='SUCCEEDED';
    IF actual <> 16 THEN
      RAISE NOTICE 'analysis job outcomes: %', (SELECT jsonb_agg(jsonb_build_object('type',job_type,'status',status,'detail',last_error_detail) ORDER BY id) FROM ops.jobs WHERE queue='analysis-worker');
      RAISE NOTICE 'agent outcomes: %', (SELECT jsonb_agg(jsonb_build_object('agent',agent_type,'status',status,'output',output_payload) ORDER BY agent_type) FROM ops.agent_runs);
      RAISE EXCEPTION 'analysis succeeded jobs %, expected 16',actual;
  END IF;
  SELECT count(*) INTO actual FROM core.rule_evaluations WHERE status='SUCCEEDED';
  IF actual <> 10 THEN RAISE EXCEPTION 'rule evaluations %, expected 10',actual; END IF;
  SELECT count(*) INTO actual FROM core.rule_runs WHERE status='SUCCEEDED' AND signal_count=1;
  IF actual <> 10 THEN RAISE EXCEPTION 'rule runs %, expected 10',actual; END IF;
  SELECT count(*) INTO actual FROM core.anomaly_signals WHERE status='NEW';
  IF actual <> 10 THEN RAISE EXCEPTION 'signals %, expected 10',actual; END IF;
  SELECT count(*) INTO actual FROM ops.outbox WHERE event_type='detection.signal_created.v1';
  IF actual <> 10 THEN RAISE EXCEPTION 'signal events %, expected 10',actual; END IF;
  SELECT count(*) INTO actual FROM ops.agent_runs
   WHERE status='SUCCEEDED' AND COALESCE(output_payload->>'status', output_payload->>'outcome')='COMPLETED'
     AND jsonb_array_length(output_payload->'citations')=1;
  IF actual <> 5 THEN
    RAISE NOTICE 'agent outcomes: %',(
      SELECT jsonb_agg(jsonb_build_object(
        'agent',agent_type,'status',status,'outputStatus',output_payload->>'status',
        'reasons',COALESCE(output_payload->'abstention_reasons', output_payload->'abstentionReasons'),'snapshot',input_snapshot_hash
      ) ORDER BY agent_type) FROM ops.agent_runs
    );
    RAISE EXCEPTION 'completed agent runs %, expected 5',actual;
  END IF;
  SELECT count(*) INTO actual FROM ops.agent_suggestions WHERE status='PENDING';
  IF actual <> 5 THEN RAISE EXCEPTION 'agent suggestions %, expected 5',actual; END IF;
  SELECT count(*) INTO actual FROM ops.outbox WHERE event_type='agent.run_completed.v1';
  IF actual <> 5 THEN RAISE EXCEPTION 'agent events %, expected 5',actual; END IF;
  IF (SELECT status FROM ops.provider_connection_tests
      WHERE id='41000000-0000-4000-8000-000000000006') <> 'SUCCEEDED' THEN
    RAISE EXCEPTION 'provider connection test did not succeed';
  END IF;
  IF (SELECT last_connection_test_status FROM ops.provider_configs
      WHERE id='41000000-0000-4000-8000-000000000005') <> 'SUCCEEDED' THEN
    RAISE EXCEPTION 'provider status was not reconciled';
  END IF;
  IF EXISTS(SELECT 1 FROM ops.jobs WHERE queue='analysis-worker' AND status<>'SUCCEEDED') THEN
    RAISE EXCEPTION 'analysis queue contains incomplete jobs';
  END IF;
END $$;
SQL

echo "10-rule/5-agent/provider-test budget-tool-citation PostgreSQL analysis runtime: PASS"
