#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-analysis-egress-$BASHPID"
database="gurine_analysis_egress"
temp="$(mktemp -d -t gurine-analysis-egress-XXXXXX)"
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
      [[ -f "$log" ]] && tail -n 160 "$log" >&2
    done
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$temp"
  exit "$status"
}
trap cleanup EXIT

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

cd "$root"
cargo build -p gurine-analysis-worker -p gurine-egress-gateway --bins
provider_port="$(free_port)"
gateway_port="$(free_port)"
provider_key="runtime-openai-key-never-persist"
selected_content='runtime-selected-source-bytes-v13'
selected_sha256="$(printf '%s' "$selected_content" | sha256sum | cut -d' ' -f1)"
mkdir -p "$temp/objects/raw"
printf '%s' "$selected_content" >"$temp/objects/raw/provider-evidence.json"

AI_PROVIDER_TEST_PORT="$provider_port" AI_PROVIDER_EXPECTED_KEY="$provider_key" \
AI_PROVIDER_EVIDENCE_ID="71000000-0000-4000-8000-000000000004" \
AI_PROVIDER_EVIDENCE_LOCATOR="page:7" \
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

docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p 127.0.0.1::5432 postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818 >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
mapfile -t migrations < <(printf '%s\n' db/migrations/*.sql | LC_ALL=C sort)
bash scripts/apply-test-migrations-with-r6e-roles.sh "$container" "$database" "${migrations[@]}"
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<SQL >/dev/null
ALTER ROLE gurine_analysis_worker LOGIN PASSWORD 'analysis_test';
INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES('71000000-0000-4000-8000-000000000001','production-egress','production-egress@example.test','Production Egress','ACTIVE');
INSERT INTO editorial.cases(id,title,investigation_state,publication_state,summary)
VALUES('71000000-0000-4000-8000-000000000002','Production egress case','INVESTIGATING','NEVER_PUBLISHED','Provider gateway gate');
INSERT INTO raw.source_documents(id,source_id,external_id,retrieved_at,content_type,content_sha256,
  content_size_bytes,object_key,status,parser_name,parser_version,prompt_injection_flags,updated_at,asset_id,asset_revision)
VALUES('71000000-0000-4000-8000-000000000003','production-egress','evidence','2026-07-12T00:00:00Z','application/json',
  repeat('a',64),128,'raw/provider-evidence.json','PARSED','json','runtime-v1','[]','2026-07-12T00:00:00Z',
  '71000000-0000-4000-8000-000000000003',1);
INSERT INTO editorial.evidence(id,case_id,evidence_type,title,source_document_id,source_locator,
  content_sha256,verification_status,verified_by,verified_at,created_by,updated_at)
VALUES('71000000-0000-4000-8000-000000000004','71000000-0000-4000-8000-000000000002','DOCUMENT','Provider evidence',
  '71000000-0000-4000-8000-000000000003','page:7',repeat('a',64),'VERIFIED','71000000-0000-4000-8000-000000000001',
  '2026-07-12T00:00:00Z','71000000-0000-4000-8000-000000000001','2026-07-12T00:00:00Z');
INSERT INTO ops.provider_configs(id,provider_type,name,enabled,routing_policy,secret_reference,data_retention_policy)
VALUES('71000000-0000-4000-8000-000000000005','openai','OpenAI Runtime',true,
  jsonb_build_object('targetUrl','http://localhost:$provider_port/agent','model','approved-runtime-v1',
    'pricing',jsonb_build_object('currency','KRW','pricingVersion','runtime-v1',
      'pricingSha256','b8b195a7f9fc71a2adb5dec8f49be073b75db56365fa6939917b3b626024ea20',
      'inputMicrosKrwPerUnit',8500000,'outputMicrosKrwPerUnit',8500000)),
  'env:OPENAI_API_KEY','NO_RETENTION');
INSERT INTO ops.budget_limits(scope,daily_limit,monthly_limit,currency,updated_by)
VALUES
  ('ENVIRONMENT:PRODUCTION',100000,1000000,'KRW','71000000-0000-4000-8000-000000000001'),
  ('PROVIDER:71000000-0000-4000-8000-000000000005',100000,1000000,'KRW','71000000-0000-4000-8000-000000000001'),
  ('CASE:71000000-0000-4000-8000-000000000002',100000,1000000,'KRW','71000000-0000-4000-8000-000000000001');
SQL

sed -e "s/:'document_id'/'71000000-0000-4000-8000-000000000003'/g" \
    -e "s/:'evidence_id'/'71000000-0000-4000-8000-000000000004'/g" \
    -e "s/:'actor_id'/'71000000-0000-4000-8000-000000000001'/g" db/test-fixtures/analysis-source-graph.sql \
    -e "s/repeat('3',64)/'$selected_sha256'/g" \
  | docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" >/dev/null

snapshot="$(docker exec "$container" psql -At -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "SELECT jsonb_build_object('caseId','71000000-0000-4000-8000-000000000002','evidence',(SELECT jsonb_agg(jsonb_build_object('id',e.id,'contentSha256',btrim(e.content_sha256::text),'locator',e.source_locator,'updatedAt',e.updated_at,'promptInjectionFlags',COALESCE(d.prompt_injection_flags,'[]'::jsonb)) ORDER BY e.id) FROM editorial.evidence e LEFT JOIN raw.source_documents d ON d.id=e.source_document_id WHERE e.id='71000000-0000-4000-8000-000000000004'))")"
snapshot_hash="$(printf '%s' "$snapshot" | jq -cSj . | sha256sum | cut -d' ' -f1)"
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -c "UPDATE core.dataset_snapshots SET snapshot_sha256='$snapshot_hash' WHERE id='46000000-0000-4000-8000-000000000007';" >/dev/null
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -v snapshot_hash="$snapshot_hash" <<'SQL' >/dev/null
INSERT INTO ops.agent_runs(id,case_id,agent_type,objective,evidence_scope_ids,provider_policy,status,
  input_snapshot_hash,max_cost,created_by)
VALUES('71000000-0000-4000-8000-000000000006','71000000-0000-4000-8000-000000000002',
  'investigator','production provider runtime','["71000000-0000-4000-8000-000000000004"]',
  'APPROVED_ONLY','QUEUED',:'snapshot_hash',1000,'71000000-0000-4000-8000-000000000001');
INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key)
VALUES('AGENT_RUN','analysis-worker',jsonb_build_object('agentRunId','71000000-0000-4000-8000-000000000006'),
  'production-egress-agent');
SQL

postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
GURINE_ENV=production AI_ENABLED=true AI_PROVIDER_ORDER=openai \
EGRESS_AI_CHANNEL_URL="http://127.0.0.1:$gateway_port/ai" \
EGRESS_SOURCE_CHANNEL_URL="http://127.0.0.1:$gateway_port/source" \
EGRESS_OBJECT_STORE_CHANNEL_URL="http://127.0.0.1:$gateway_port/object-store" \
ANALYSIS_DATABASE_URL="postgresql://gurine_analysis_worker:analysis_test@127.0.0.1:${postgres_port}/${database}" \
ANALYSIS_ONCE=true HOSTNAME="analysis-production-egress" target/debug/gurine-analysis-worker

docker exec -i "$container" psql -At -U postgres -d "$database" -c \
  "SELECT 'source_uses',use_kind,count(*) FROM ops.agent_source_uses WHERE agent_run_id='71000000-0000-4000-8000-000000000006' GROUP BY use_kind ORDER BY use_kind; SELECT 'tool_calls',source_use_count FROM ops.agent_tool_calls WHERE agent_run_id='71000000-0000-4000-8000-000000000006'; SELECT 'validations',validation_status,schema_status,citation_status,output_status FROM ops.agent_output_validations WHERE agent_run_id='71000000-0000-4000-8000-000000000006'; SELECT 'receipt_mismatch',su.use_kind,su.provider_turn_id,su.provider_receipt_id,t.provider_receipt_id,su.provider_receipt_sha256,t.provider_receipt_sha256 FROM ops.agent_source_uses su JOIN ops.agent_provider_turns t ON t.agent_run_id=su.agent_run_id AND t.provider_turn_id=su.provider_turn_id WHERE su.agent_run_id='71000000-0000-4000-8000-000000000006' AND su.use_kind='MODEL_INPUT' AND su.provider_receipt_sha256 <> encode(extensions.digest(convert_to('pre-dispatch-receipt:'||su.provider_turn_id::text,'UTF8'),'sha256'),'hex') AND (su.provider_receipt_id IS DISTINCT FROM t.provider_receipt_id OR su.provider_receipt_sha256 IS DISTINCT FROM t.provider_receipt_sha256);"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
BEGIN
  IF (SELECT status FROM ops.agent_runs WHERE id='71000000-0000-4000-8000-000000000006')<>'SUCCEEDED'
     OR (SELECT provider FROM ops.agent_runs WHERE id='71000000-0000-4000-8000-000000000006')<>'openai'
     OR (SELECT model FROM ops.agent_runs WHERE id='71000000-0000-4000-8000-000000000006')<>'approved-runtime-v1'
     OR (SELECT actual_cost FROM ops.agent_runs WHERE id='71000000-0000-4000-8000-000000000006')<>34
     OR (SELECT output_payload->>'status' FROM ops.agent_runs WHERE id='71000000-0000-4000-8000-000000000006')<>'COMPLETED' THEN
    RAISE EXCEPTION 'production provider egress run did not complete';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM ops.cost_events WHERE job_id=(
       SELECT id FROM ops.jobs WHERE dedupe_key='production-egress-agent') AND amount=17)
     OR NOT EXISTS(SELECT 1 FROM ops.agent_suggestions s
       WHERE s.agent_run_id='71000000-0000-4000-8000-000000000006'
         AND jsonb_array_length(s.citation_checks)>0
         AND s.citation_checks @> '[{"locator":{"value":"page:7"}}]') THEN
    RAISE EXCEPTION 'provider cost or verified citation was not persisted';
  END IF;
  IF (SELECT count(*) FROM ops.agent_source_uses WHERE agent_run_id='71000000-0000-4000-8000-000000000006' AND use_kind='TOOL_QUERY')<>1
     OR (SELECT count(*) FROM ops.agent_source_uses WHERE agent_run_id='71000000-0000-4000-8000-000000000006' AND use_kind='TOOL_RESULT')<1
     OR (SELECT count(*) FROM ops.agent_source_uses WHERE agent_run_id='71000000-0000-4000-8000-000000000006' AND use_kind='MODEL_INPUT')<2
     OR (SELECT count(*) FROM ops.agent_source_uses WHERE agent_run_id='71000000-0000-4000-8000-000000000006' AND use_kind='MODEL_OUTPUT_DERIVATION')<1
     OR (SELECT count(*) FROM ops.agent_source_uses WHERE agent_run_id='71000000-0000-4000-8000-000000000006' AND use_kind='CITATION')<1
     OR EXISTS(SELECT 1 FROM ops.agent_provider_turns t JOIN ops.agent_source_uses su ON su.agent_run_id=t.agent_run_id AND su.provider_turn_id=t.provider_turn_id WHERE t.agent_run_id='71000000-0000-4000-8000-000000000006' AND su.use_kind='MODEL_INPUT' AND su.provider_receipt_sha256 <> encode(extensions.digest(convert_to('pre-dispatch-receipt:'||su.provider_turn_id::text,'UTF8'),'sha256'),'hex') AND (su.provider_receipt_id IS NULL OR su.provider_receipt_sha256 IS NULL OR su.provider_receipt_id IS DISTINCT FROM t.provider_receipt_id OR su.provider_receipt_sha256 IS DISTINCT FROM t.provider_receipt_sha256)) THEN
    RAISE EXCEPTION 'provider source-use lineage is incomplete';
  END IF;
  IF (SELECT count(*) FROM ops.agent_tool_calls WHERE agent_run_id='71000000-0000-4000-8000-000000000006' AND source_use_count > 0)<1
     OR NOT EXISTS(SELECT 1 FROM ops.agent_output_validations WHERE agent_run_id='71000000-0000-4000-8000-000000000006' AND validation_status='VALID' AND citation_status='PASS' AND schema_status='PASS')
     OR EXISTS(SELECT 1 FROM ops.agent_source_uses su WHERE su.agent_run_id='71000000-0000-4000-8000-000000000006' AND encode(extensions.digest(ops.canonical_jsonb_v1(convert_from(su.source_use_canonical,'UTF8')::jsonb - 'sourceUseSha256'),'sha256'),'hex') <> btrim(su.source_use_sha256::text))
     OR EXISTS(SELECT 1 FROM ops.agent_source_uses su WHERE su.agent_run_id='71000000-0000-4000-8000-000000000006' AND su.use_kind='MODEL_OUTPUT_DERIVATION' AND NOT EXISTS(SELECT 1 FROM ops.agent_provider_turns t WHERE t.agent_run_id=su.agent_run_id AND t.provider_turn_id=su.provider_turn_id AND t.provider_receipt_id=su.provider_receipt_id AND t.provider_receipt_sha256=su.provider_receipt_sha256)) THEN
    RAISE EXCEPTION 'provider output validation or tool lineage is incomplete';
  END IF;
  IF (SELECT count(*) FROM ops.budget_reservation_ledger_entries
      WHERE reservation_id IN (SELECT id FROM ops.budget_reservations
        WHERE job_id=(SELECT id FROM ops.jobs WHERE dedupe_key='production-egress-agent')))<>24
     OR EXISTS(SELECT 1 FROM ops.budget_reservation_ledger_entries
       WHERE reservation_id IN (SELECT id FROM ops.budget_reservations
         WHERE job_id=(SELECT id FROM ops.jobs WHERE dedupe_key='production-egress-agent'))
         AND available_after < 0) THEN
    RAISE EXCEPTION 'budget six-cell reservation ledger is incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM ops.jobs WHERE payload::text LIKE '%runtime-openai-key-never-persist%'
            OR COALESCE(last_error_detail,'') LIKE '%runtime-openai-key-never-persist%')
     OR EXISTS(SELECT 1 FROM ops.outbox WHERE payload::text LIKE '%runtime-openai-key-never-persist%')
     OR EXISTS(SELECT 1 FROM ops.agent_runs WHERE COALESCE(output_payload::text,'') LIKE '%runtime-openai-key-never-persist%') THEN
    RAISE EXCEPTION 'provider credential leaked into durable runtime records';
  END IF;
END $$;
SQL

echo "production analysis to credential-injecting AI egress gateway runtime: PASS"
