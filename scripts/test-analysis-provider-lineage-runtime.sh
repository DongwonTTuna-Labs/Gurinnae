#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-analysis-provider-lineage-$BASHPID"
database="gurine_analysis_provider_lineage"
temp="$(mktemp -d -t gurine-analysis-provider-lineage-XXXXXX)"
gateway_pid=""
provider_pid=""

cleanup() {
  status=$?
  trap - EXIT
  for pid in "$provider_pid" "$gateway_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ $status -ne 0 ]]; then
    for log in "$temp"/*.log; do
      [[ -f "$log" ]] && tail -n 200 "$log" >&2
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

stop_provider() {
  if [[ -n "$provider_pid" ]] && kill -0 "$provider_pid" 2>/dev/null; then
    kill -TERM "$provider_pid" 2>/dev/null || true
    wait "$provider_pid" 2>/dev/null || true
  fi
  provider_pid=""
}

start_provider() {
  local mode="$1"
  local port="$2"
  local marker="$3"
  local log="$4"
  T3_PROVIDER_MODE="$mode" T3_PROVIDER_PORT="$port" \
  T3_DATABASE_URL="$admin_database_url" T3_MARKER_PATH="$marker" \
  T3_EXPECTED_SELECTED_SHA256="$selected_sha256" \
    bun run - >"$log" 2>&1 <<'BUN' &
import { SQL } from "bun";

const mode = required("T3_PROVIDER_MODE");
const port = Number(required("T3_PROVIDER_PORT"));
const markerPath = required("T3_MARKER_PATH");
const expectedSelectedSha256 = required("T3_EXPECTED_SELECTED_SHA256");
const sql = new SQL(required("T3_DATABASE_URL"));

Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return Response.json({ status: "ready", mode });
    }
    if (url.pathname !== "/ai" || request.method !== "POST") {
      return new Response("not found", { status: 404 });
    }

    const body = await request.json();
    const runId = requiredHeader(request, "x-gurine-ai-agent-run-id");
    const turnId = requiredHeader(request, "x-gurine-ai-provider-turn-id");
    const inputSnapshotId = requiredHeader(
      request,
      "x-gurine-ai-input-snapshot-id",
    );
    const inputSnapshotSha256 = requiredHeader(
      request,
      "x-gurine-ai-input-snapshot-sha256",
    );
    const providerConfigId = requiredHeader(
      request,
      "x-gurine-ai-provider-config-id",
    );
    const provider = requiredHeader(request, "x-gurine-ai-provider");
    const modelId = requiredHeader(request, "x-gurine-ai-model-id");
    const modelConfigurationSha256 = requiredHeader(
      request,
      "x-gurine-ai-model-configuration-sha256",
    );
    const idempotencyKeySha256 = requiredHeader(
      request,
      "x-gurine-ai-idempotency-key-sha256",
    );
    const selected = Array.isArray(body.selectedContentRefs)
      ? body.selectedContentRefs
      : [];
    if (selected.length !== 1) {
      throw new Error(`expected one selectedContentRef, got ${selected.length}`);
    }
    const reference = selected[0];

    const rows = await sql`
      SELECT source_use.source_use_id::text AS source_use_id,
             btrim(source_use.source_use_sha256::text) AS sentinel_digest,
             source_use.parent_source_use_id::text AS parent_source_use_id,
             btrim(source_use.parent_source_use_sha256::text) AS parent_digest,
             source_use.provider_receipt_id::text AS sentinel_receipt_id,
             btrim(source_use.provider_receipt_sha256::text) AS sentinel_receipt_sha256,
             btrim(source_use.selected_content_sha256::text) AS selected_content_sha256,
             source_use.locator_value,
             btrim(source_use.locator_sha256::text) AS locator_sha256,
             turn.status AS turn_status,
             turn.provider_receipt_id::text AS turn_receipt_id,
             btrim(turn.provider_receipt_sha256::text) AS turn_receipt_sha256,
             btrim(turn.input_snapshot_sha256::text) AS input_snapshot_sha256,
             btrim(turn.model_use_rights_sha256::text) AS rights_decision_set_sha256,
             turn.classification,
             turn.dispatched_at,
             config.routing_policy,
             encode(extensions.digest(source_use.source_use_canonical,'sha256'),'hex')
               AS source_use_canonical_sha256,
             source_use.source_use_canonical = ops.canonical_jsonb_v1(
               convert_from(source_use.source_use_canonical,'UTF8')::jsonb
             )
             AND btrim(source_use.source_use_sha256::text) = encode(
               extensions.digest(ops.canonical_jsonb_v1(
                 convert_from(source_use.source_use_canonical,'UTF8')::jsonb
                   - 'sourceUseSha256'
               ),'sha256'),'hex'
             ) AS canonical_valid
        FROM ops.agent_source_uses source_use
        JOIN ops.agent_provider_turns turn
          ON turn.agent_run_id=source_use.agent_run_id
         AND turn.provider_turn_id=source_use.provider_turn_id
        JOIN ops.provider_configs config ON config.id=turn.provider_config_id
       WHERE source_use.agent_run_id=${runId}::uuid
         AND source_use.provider_turn_id=${turnId}::uuid
         AND source_use.use_kind='MODEL_INPUT'
    `;
    if (rows.length !== 1) {
      throw new Error(`expected one pre-dispatch MODEL_INPUT, got ${rows.length}`);
    }
    const lineage = rows[0];
    const selectedBytes = Uint8Array.from(
      atob(String(reference.selectedContentBytesBase64)),
      (value) => value.charCodeAt(0),
    );
    const selectedBytesSha256 = sha256Bytes(selectedBytes);
    const orderedSourceUseIds = Array.isArray(body.orderedSourceUseIds)
      ? body.orderedSourceUseIds
      : [];
    const orderValid =
      lineage.turn_status === "DISPATCHED" &&
      lineage.turn_receipt_id === null &&
      lineage.turn_receipt_sha256 === null &&
      lineage.sentinel_receipt_id === turnId &&
      lineage.sentinel_receipt_sha256 === inputSnapshotSha256 &&
      lineage.input_snapshot_sha256 === inputSnapshotSha256 &&
      lineage.parent_source_use_id === reference.sourceUseId &&
      lineage.parent_digest === reference.sourceUseSha256 &&
      lineage.selected_content_sha256 === reference.selectedContentSha256 &&
      lineage.selected_content_sha256 === expectedSelectedSha256 &&
      selectedBytesSha256 === expectedSelectedSha256 &&
      selectedBytes.byteLength === reference.selectedContentSizeBytes &&
      lineage.locator_value === reference.selectedContentLocator &&
      lineage.locator_sha256 === reference.locatorSha256 &&
      orderedSourceUseIds.length === 1 &&
      orderedSourceUseIds[0] === reference.sourceUseId &&
      lineage.canonical_valid === true;
    if (!orderValid) {
      throw new Error("pre-dispatch MODEL_INPUT does not bind the wire evidence");
    }

    const marker = {
      assertion: "T3_ORDER_PRE_DISPATCH",
      mode,
      runId,
      turnId,
      inputSnapshotId,
      sourceUseId: lineage.source_use_id,
      sentinelDigest: lineage.sentinel_digest,
      parentSourceUseId: lineage.parent_source_use_id,
      parentDigest: lineage.parent_digest,
      selectedContentSha256: lineage.selected_content_sha256,
      locator: lineage.locator_value,
      locatorSha256: lineage.locator_sha256,
      sourceUseCanonicalSha256: lineage.source_use_canonical_sha256,
      canonicalValid: lineage.canonical_valid,
      agentToolCallsObserved: 0,
    };
    const toolRows = await sql`
      SELECT count(*)::int AS count
        FROM ops.agent_tool_calls
       WHERE agent_run_id=${runId}::uuid
    `;
    if (toolRows[0].count !== 0) {
      throw new Error("agent_tool_calls was populated before provider dispatch");
    }
    await Bun.write(markerPath, `${JSON.stringify(marker)}\n`);

    if (mode.startsWith("failure")) {
      console.log(JSON.stringify(marker));
      await sql.close();
      process.exit(0);
    }

    const pricing = lineage.routing_policy.pricing;
    const inputUnits = 1;
    const outputUnits = 1;
    const actualMicrosKrw =
      inputUnits * pricing.inputMicrosKrwPerUnit +
      outputUnits * pricing.outputMicrosKrwPerUnit;
    const providerRequestIdHash = sha256Hex(
      canonical({
        idempotencyKeySha256,
        inputSnapshotId,
        inputSnapshotSha256,
        providerConfigId,
        runId,
        turnId,
      }),
    );
    const usage = {
      state: "PROVIDER_REPORTED",
      inputUnits,
      outputUnits,
      cachedInputUnits: 0,
      billableUnits: inputUnits + outputUnits,
      usageEvidenceSha256: sha256Hex(
        canonical({ inputUnits, outputUnits, selectedBytesSha256 }),
      ),
    };
    const policyFacts = {
      classification: lineage.classification,
      processingRegion: "US",
      retentionMode: "ZERO_RETENTION",
      trainingUse: "PROHIBITED",
      policyVersion: "t3-fixture-policy-v1",
      rightsDecisionSetSha256: lineage.rights_decision_set_sha256,
    };
    const dataPolicy = {
      ...policyFacts,
      policySha256: sha256Hex(canonical(policyFacts)),
    };
    const observedAt = new Date().toISOString();
    const receipt = {
      schemaVersion: "provider-receipt.v2",
      receiptId: crypto.randomUUID(),
      agentRunId: runId,
      providerTurnId: turnId,
      providerMode: "EXTERNAL_APPROVED",
      providerConfigId,
      providerCandidateId: provider,
      modelId,
      modelConfigurationSha256,
      semanticRequestSha256: body.semanticRequestSha256,
      idempotencyKeySha256,
      outcome: "ACCEPTED_FINAL",
      proofKind: "AUTHENTICATED_RESPONSE_HEADERS",
      proofSha256: sha256Hex(providerRequestIdHash),
      providerRequestIdHash,
      usage,
      pricing: {
        pricingVersion: pricing.pricingVersion,
        pricingSha256: pricing.pricingSha256,
        currency: "KRW",
        fxRateFactId: null,
        reservedMicrosKrw: actualMicrosKrw,
        actualMicrosKrw,
        costState: "SETTLED",
      },
      dataPolicy,
      dispatchedAt: new Date(lineage.dispatched_at).toISOString(),
      observedAt,
      completedAt: observedAt,
    };
    receipt.receiptSha256 = sha256Hex(canonical(receipt));
    const citationSupport = "TEST_FIXTURE_ONLY selected evidence segment";
    return Response.json({
      output: {
        schemaVersion: "investigator-output.v2",
        outcome: "COMPLETED",
        summary: "TEST_FIXTURE_ONLY 고정 근거 1건을 검토했습니다.",
        investigationsPerformed: [],
        citations: [
          {
            sourceUseSha256: reference.sourceUseSha256,
            locator: {
              kind: "TEXT_RANGE",
              value: reference.selectedContentLocator,
              locatorSha256: reference.locatorSha256,
            },
            selectedContentSha256: reference.selectedContentSha256,
            supports: citationSupport,
            supportsSha256: sha256Hex(citationSupport),
          },
        ],
        unknowns: [],
        nextActions: [],
        abstentionReasons: [],
        hypotheses: [],
        counterEvidence: [],
        tasks: [],
      },
      providerReceipt: receipt,
      costKrw: Math.ceil(actualMicrosKrw / 1_000_000),
    });
  },
});

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`missing ${name}`);
  return value;
}

function requiredHeader(request, name) {
  const value = request.headers.get(name);
  if (!value) throw new Error(`missing ${name}`);
  return value;
}

function canonical(value) {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    return Number.isInteger(value) ? String(value) : JSON.stringify(value);
  }
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  return `{${Object.keys(value)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`)
    .join(",")}}`;
}

function sha256Hex(value) {
  const hasher = new Bun.CryptoHasher("sha256");
  hasher.update(value);
  return hasher.digest("hex");
}

function sha256Bytes(value) {
  const hasher = new Bun.CryptoHasher("sha256");
  hasher.update(value);
  return hasher.digest("hex");
}
BUN
  provider_pid=$!
  for _ in $(seq 1 80); do
    if curl --fail --silent --show-error "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      return
    fi
    sleep 0.25
  done
  curl --fail --silent --show-error "http://127.0.0.1:$port/health" >/dev/null
}

run_worker_once() {
  local provider_port="$1"
  local worker_id="$2"
  GURINE_ENV=production AI_ENABLED=true AI_PROVIDER_ORDER=openai \
  EGRESS_AI_CHANNEL_URL="http://127.0.0.1:$provider_port/ai" \
  EGRESS_SOURCE_CHANNEL_URL="http://127.0.0.1:$provider_port/unused-source" \
  EGRESS_OBJECT_STORE_CHANNEL_URL="http://127.0.0.1:$gateway_port/object-store" \
  ANALYSIS_DATABASE_URL="$worker_database_url" ANALYSIS_ONCE=true \
  HOSTNAME="$worker_id" target/debug/gurine-analysis-worker
}

cd "$root"
cargo build -p gurine-analysis-worker -p gurine-egress-gateway --bins

selected_content='TEST_FIXTURE_ONLY provider lineage selected source bytes v1'
selected_sha256="$(printf '%s' "$selected_content" | sha256sum | cut -d' ' -f1)"
locator_sha256="$(printf '%s' 'page:7' | sha256sum | cut -d' ' -f1)"
segment_digest="$(printf '%s' \
  "TEST_FIXTURE_ONLY:EVIDENCE_SEGMENT:$selected_sha256:page:7" \
  | sha256sum | cut -d' ' -f1)"
rights_dimensions_sha256="$(printf '%s' \
  'TEST_FIXTURE_ONLY:RIGHTS_DIMENSIONS:ALLOW_ALL' \
  | sha256sum | cut -d' ' -f1)"
rights_legal_basis_sha256="$(printf '%s' \
  'TEST_FIXTURE_ONLY:LEGAL_BASIS:RUNTIME:runtime fixture' \
  | sha256sum | cut -d' ' -f1)"
rights_license_evidence_sha256="$(printf '%s' \
  'TEST_FIXTURE_ONLY:LICENSE_EVIDENCE:v1' \
  | sha256sum | cut -d' ' -f1)"
rights_license_set_sha256="$(printf '%s' \
  "[\"$rights_license_evidence_sha256\"]" \
  | sha256sum | cut -d' ' -f1)"
rights_attribution_sha256="$(printf '%s' \
  'TEST_FIXTURE_ONLY:ATTRIBUTION_REQUIRED:false' \
  | sha256sum | cut -d' ' -f1)"
rights_policy_sha256="$(printf '%s' 'runtime-rights-v1' \
  | sha256sum | cut -d' ' -f1)"
rights_approval_sha256="$(printf '%s' \
  'TEST_FIXTURE_ONLY:RIGHTS_APPROVAL:72000000-0000-4000-8000-000000000003:v1' \
  | sha256sum | cut -d' ' -f1)"
rights_execution_sha256="$(printf '%s' \
  'TEST_FIXTURE_ONLY:RIGHTS_EXECUTION:72000000-0000-4000-8000-000000000003:v1' \
  | sha256sum | cut -d' ' -f1)"
rights_receipt_sha256="$(printf '%s' \
  'TEST_FIXTURE_ONLY:RIGHTS_EVIDENCE_RECEIPT:46000000-0000-4000-8000-000000000006' \
  | sha256sum | cut -d' ' -f1)"
rights_decision_sha256="$(printf '%s' \
  "TEST_FIXTURE_ONLY:RIGHTS_DECISION:$selected_sha256:$rights_policy_sha256" \
  | sha256sum | cut -d' ' -f1)"
direct_source_digest="$(printf '%s' \
  "TEST_FIXTURE_ONLY:DIRECT_SOURCE:$selected_sha256" \
  | sha256sum | cut -d' ' -f1)"
evidence_source_digest="$(printf '%s' \
  "TEST_FIXTURE_ONLY:EVIDENCE_SOURCE:$selected_sha256:$locator_sha256" \
  | sha256sum | cut -d' ' -f1)"
mkdir -p "$temp/objects/raw"
printf '%s' "$selected_content" >"$temp/objects/raw/analysis-document.json"

docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
for migration in db/migrations/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
    <"$migration" >/dev/null
done
postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
admin_database_url="postgresql://postgres:postgres@127.0.0.1:${postgres_port}/${database}"
worker_database_url="postgresql://gurine_analysis_worker:analysis_test@127.0.0.1:${postgres_port}/${database}"

success_port="$(free_port)"
gateway_port="$(free_port)"
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<SQL >/dev/null
ALTER ROLE gurine_analysis_worker LOGIN PASSWORD 'analysis_test';
INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES('72000000-0000-4000-8000-000000000001','t3-provider-lineage-fixture',
  't3-provider-lineage@example.test','T3 Provider Lineage Fixture','ACTIVE');
INSERT INTO editorial.cases(id,title,investigation_state,publication_state,summary)
VALUES('72000000-0000-4000-8000-000000000002','T3 provider lineage fixture case',
  'INVESTIGATING','NEVER_PUBLISHED','TEST_FIXTURE_ONLY provider lineage');
INSERT INTO raw.source_documents(id,source_id,external_id,retrieved_at,content_type,
  content_sha256,content_size_bytes,object_key,status,parser_name,parser_version,
  prompt_injection_flags,updated_at,asset_id,asset_revision)
VALUES('72000000-0000-4000-8000-000000000003','t3-provider-lineage-fixture',
  'TEST_FIXTURE_ONLY-evidence','2026-07-12T00:00:00Z','application/json',
  '$selected_sha256',${#selected_content},'raw/analysis-document.json','PARSED','json',
  'runtime-v1','[]','2026-07-12T00:00:00Z',
  '72000000-0000-4000-8000-000000000003',1);
INSERT INTO editorial.evidence(id,case_id,evidence_type,title,source_document_id,
  source_locator,content_sha256,verification_status,verified_by,verified_at,
  created_by,updated_at)
VALUES('72000000-0000-4000-8000-000000000004',
  '72000000-0000-4000-8000-000000000002','DOCUMENT',
  'TEST_FIXTURE_ONLY provider evidence','72000000-0000-4000-8000-000000000003',
  'page:7','$selected_sha256','VERIFIED','72000000-0000-4000-8000-000000000001',
  '2026-07-12T00:00:00Z','72000000-0000-4000-8000-000000000001',
  '2026-07-12T00:00:00Z');
INSERT INTO ops.provider_configs(id,provider_type,name,enabled,routing_policy,
  secret_reference,data_retention_policy)
VALUES('72000000-0000-4000-8000-000000000005','openai',
  'T3 local provider double',true,
  jsonb_build_object(
    'targetUrl','http://127.0.0.1:$success_port/upstream-unused',
    'model','approved-runtime-v1',
    'pricing',jsonb_build_object(
      'currency','KRW','pricingVersion','t3-runtime-v1',
      'pricingSha256',encode(extensions.digest(ops.canonical_jsonb_v1(
        jsonb_build_object('currency','KRW','pricingVersion','t3-runtime-v1',
          'inputMicrosKrwPerUnit',8500000,'outputMicrosKrwPerUnit',8500000)),
        'sha256'),'hex'),
      'inputMicrosKrwPerUnit',8500000,'outputMicrosKrwPerUnit',8500000)),
  'env:OPENAI_API_KEY','NO_RETENTION');
INSERT INTO ops.budget_limits(scope,daily_limit,monthly_limit,currency,updated_by)
VALUES
  ('ENVIRONMENT:PRODUCTION',100000,1000000,'KRW','72000000-0000-4000-8000-000000000001'),
  ('PROVIDER:72000000-0000-4000-8000-000000000005',100000,1000000,'KRW',
    '72000000-0000-4000-8000-000000000001'),
  ('CASE:72000000-0000-4000-8000-000000000002',100000,1000000,'KRW',
    '72000000-0000-4000-8000-000000000001');
SQL

sed -e "s/:'document_id'/'72000000-0000-4000-8000-000000000003'/g" \
    -e "s/:'evidence_id'/'72000000-0000-4000-8000-000000000004'/g" \
    -e "s/:'actor_id'/'72000000-0000-4000-8000-000000000001'/g" \
    -e "92s/repeat('a',64)/'$selected_sha256'/" \
    -e "93s/repeat('1',64)/'$locator_sha256'/" \
    -e "93s/repeat('2',64)/'$selected_sha256'/" \
    -e "93s/repeat('3',64)/'$selected_sha256'/" \
    -e "95s/repeat('4',64)/'$segment_digest'/" \
    -e "103s/repeat('a',64)/'$selected_sha256'/" \
    -e "104s/repeat('5',64)/'$rights_dimensions_sha256'/" \
    -e "105s/repeat('6',64)/'$rights_legal_basis_sha256'/" \
    -e "105s/repeat('0',64)/'$rights_license_evidence_sha256'/" \
    -e "105s/repeat('7',64)/'$rights_license_set_sha256'/" \
    -e "105s/repeat('8',64)/'$rights_attribution_sha256'/" \
    -e "106s/repeat('9',64)/'$rights_policy_sha256'/" \
    -e "106s/repeat('a',64)/'$rights_approval_sha256'/" \
    -e "106s/repeat('b',64)/'$rights_execution_sha256'/" \
    -e "107s/repeat('c',64)/'$rights_receipt_sha256'/" \
    -e "107s/repeat('d',64)/'$rights_decision_sha256'/" \
    -e "132s/repeat('3',64)/'$selected_sha256'/" \
    -e "139s/repeat('a',64)/'$selected_sha256'/" \
    -e "139s/repeat('1',64)/'$direct_source_digest'/" \
    -e "144s/repeat('a',64)/'$selected_sha256'/" \
    -e "144s/repeat('1',64)/'$locator_sha256'/" \
    -e "144s/repeat('2',64)/'$evidence_source_digest'/" \
    db/test-fixtures/analysis-source-graph.sql \
  | docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" >/dev/null

snapshot="$(docker exec "$container" psql -At -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "SELECT jsonb_build_object('caseId','72000000-0000-4000-8000-000000000002','evidence',(SELECT jsonb_agg(jsonb_build_object('id',e.id,'contentSha256',btrim(e.content_sha256::text),'locator',e.source_locator,'updatedAt',e.updated_at,'promptInjectionFlags',COALESCE(d.prompt_injection_flags,'[]'::jsonb)) ORDER BY e.id) FROM editorial.evidence e LEFT JOIN raw.source_documents d ON d.id=e.source_document_id WHERE e.id='72000000-0000-4000-8000-000000000004'))")"
snapshot_hash="$(printf '%s' "$snapshot" | jq -cSj . | sha256sum | cut -d' ' -f1)"
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -c "UPDATE core.dataset_snapshots SET snapshot_sha256='$snapshot_hash' WHERE id='46000000-0000-4000-8000-000000000007';" >/dev/null

GURINE_ENV=test HTTP_BIND="127.0.0.1:$gateway_port" OIDC_ISSUER_HOST=localhost \
OBJECT_STORE_ADAPTER=filesystem OBJECT_STORE_FILESYSTEM_ROOT="$temp/objects" \
  target/debug/gurine-egress-gateway >"$temp/gateway.log" 2>&1 &
gateway_pid=$!
for _ in $(seq 1 80); do
  if curl --fail --silent --show-error "http://127.0.0.1:$gateway_port/health/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
curl --fail --silent --show-error "http://127.0.0.1:$gateway_port/health/ready" >/dev/null

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -v snapshot_hash="$snapshot_hash" <<'SQL' >/dev/null
INSERT INTO ops.agent_runs(id,case_id,agent_type,objective,evidence_scope_ids,
  provider_policy,status,input_snapshot_hash,max_cost,created_by)
VALUES('72000000-0000-4000-8000-000000000006',
  '72000000-0000-4000-8000-000000000002','investigator',
  'TEST_FIXTURE_ONLY pre-dispatch success',
  '["72000000-0000-4000-8000-000000000004"]','APPROVED_ONLY','QUEUED',
  :'snapshot_hash',1000,'72000000-0000-4000-8000-000000000001');
INSERT INTO ops.jobs(job_type,queue,status,payload,dedupe_key,max_attempts)
VALUES('AGENT_RUN','analysis-worker','QUEUED',
  jsonb_build_object('agentRunId','72000000-0000-4000-8000-000000000006'),
  't3-provider-lineage-success',1);
SQL

success_marker="$temp/success-marker.json"
start_provider success "$success_port" "$success_marker" "$temp/provider-success.log"
run_worker_once "$success_port" "analysis-t3-lineage-success"
stop_provider
[[ -s "$success_marker" ]]
success_source_use_id="$(jq -er '.sourceUseId' "$success_marker")"
success_sentinel_digest="$(jq -er '.sentinelDigest' "$success_marker")"
printf 'T3_ORDER_PRE_DISPATCH mode=success source_use_id=%s sentinel_digest=%s parent_source_use_id=%s parent_digest=%s selected_sha256=%s locator=%s canonical_valid=%s\n' \
  "$success_source_use_id" "$success_sentinel_digest" \
  "$(jq -er '.parentSourceUseId' "$success_marker")" \
  "$(jq -er '.parentDigest' "$success_marker")" \
  "$(jq -er '.selectedContentSha256' "$success_marker")" \
  "$(jq -er '.locator' "$success_marker")" \
  "$(jq -er '.canonicalValid' "$success_marker")"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -v source_use_id="$success_source_use_id" -v sentinel_digest="$success_sentinel_digest" <<'SQL'
\o /dev/null
SELECT set_config('t3.source_use_id', :'source_use_id', false);
SELECT set_config('t3.sentinel_digest', :'sentinel_digest', false);
\o
DO $$
DECLARE
  v_turn ops.agent_provider_turns%ROWTYPE;
  v_source ops.agent_source_uses%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_turn FROM ops.agent_provider_turns
   WHERE agent_run_id='72000000-0000-4000-8000-000000000006';
  SELECT * INTO STRICT v_source FROM ops.agent_source_uses
   WHERE agent_run_id=v_turn.agent_run_id AND use_kind='MODEL_INPUT';
  IF v_turn.status<>'COMPLETED' OR v_turn.provider_receipt_id IS NULL
     OR v_turn.provider_receipt_sha256 IS NULL
     OR v_source.source_use_id<>current_setting('t3.source_use_id')::uuid
     OR btrim(v_source.source_use_sha256::text)=current_setting('t3.sentinel_digest')
     OR v_source.provider_receipt_id IS DISTINCT FROM v_turn.provider_receipt_id
     OR v_source.provider_receipt_sha256 IS DISTINCT FROM v_turn.provider_receipt_sha256
     OR (SELECT count(*) FROM ops.agent_source_uses
          WHERE agent_run_id=v_turn.agent_run_id AND use_kind='MODEL_INPUT')<>1
     OR (SELECT count(*) FROM ops.agent_tool_calls
          WHERE agent_run_id=v_turn.agent_run_id)<>0
     OR v_source.source_use_canonical IS DISTINCT FROM ops.canonical_jsonb_v1(
          convert_from(v_source.source_use_canonical,'UTF8')::jsonb)
     OR btrim(v_source.source_use_sha256::text) IS DISTINCT FROM encode(
          extensions.digest(ops.canonical_jsonb_v1(
            convert_from(v_source.source_use_canonical,'UTF8')::jsonb
              - 'sourceUseSha256'),'sha256'),'hex') THEN
    RAISE EXCEPTION 'T3 receipt promotion assertion failed';
  END IF;
END $$;
SELECT 'T3_RECEIPT_PROMOTION source_use_id='||source_use.source_use_id||
       ' sentinel_digest='||:'sentinel_digest'||
       ' promoted_digest='||btrim(source_use.source_use_sha256::text)||
       ' same_row=true model_input_count=1 agent_tool_calls=0 canonical_valid=true turn_status='||turn.status
  FROM ops.agent_source_uses source_use
  JOIN ops.agent_provider_turns turn
    ON turn.agent_run_id=source_use.agent_run_id
   AND turn.provider_turn_id=source_use.provider_turn_id
 WHERE source_use.source_use_id=:'source_use_id'::uuid;
SQL

failure_port="$(free_port)"
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -v snapshot_hash="$snapshot_hash" -v failure_port="$failure_port" <<'SQL' >/dev/null
UPDATE ops.provider_configs
   SET routing_policy=jsonb_set(routing_policy,'{targetUrl}',
     to_jsonb('http://127.0.0.1:'||:'failure_port'||'/upstream-unused'))
 WHERE id='72000000-0000-4000-8000-000000000005';
INSERT INTO ops.agent_runs(id,case_id,agent_type,objective,evidence_scope_ids,
  provider_policy,status,input_snapshot_hash,max_cost,created_by)
VALUES('72000000-0000-4000-8000-000000000007',
  '72000000-0000-4000-8000-000000000002','investigator',
  'TEST_FIXTURE_ONLY pre-dispatch transport failure',
  '["72000000-0000-4000-8000-000000000004"]','APPROVED_ONLY','QUEUED',
  :'snapshot_hash',1000,'72000000-0000-4000-8000-000000000001');
INSERT INTO ops.jobs(job_type,queue,status,payload,dedupe_key,max_attempts)
VALUES('AGENT_RUN','analysis-worker','QUEUED',
  jsonb_build_object('agentRunId','72000000-0000-4000-8000-000000000007'),
  't3-provider-lineage-failure',1);
SQL

failure_marker="$temp/failure-marker.json"
start_provider failure "$failure_port" "$failure_marker" "$temp/provider-failure.log"
run_worker_once "$failure_port" "analysis-t3-lineage-failure"
if [[ -n "$provider_pid" ]]; then
  wait "$provider_pid" 2>/dev/null || true
  provider_pid=""
fi
[[ -s "$failure_marker" ]]
failure_source_use_id="$(jq -er '.sourceUseId' "$failure_marker")"
failure_sentinel_digest="$(jq -er '.sentinelDigest' "$failure_marker")"
printf 'T3_ORDER_PRE_DISPATCH mode=failure source_use_id=%s sentinel_digest=%s parent_source_use_id=%s parent_digest=%s selected_sha256=%s locator=%s canonical_valid=%s\n' \
  "$failure_source_use_id" "$failure_sentinel_digest" \
  "$(jq -er '.parentSourceUseId' "$failure_marker")" \
  "$(jq -er '.parentDigest' "$failure_marker")" \
  "$(jq -er '.selectedContentSha256' "$failure_marker")" \
  "$(jq -er '.locator' "$failure_marker")" \
  "$(jq -er '.canonicalValid' "$failure_marker")"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -v source_use_id="$failure_source_use_id" -v sentinel_digest="$failure_sentinel_digest" <<'SQL'
\o /dev/null
SELECT set_config('t3.source_use_id', :'source_use_id', false);
SELECT set_config('t3.sentinel_digest', :'sentinel_digest', false);
\o
DO $$
DECLARE
  v_source ops.agent_source_uses%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_source FROM ops.agent_source_uses
   WHERE source_use_id=current_setting('t3.source_use_id')::uuid;
  IF (SELECT status FROM ops.jobs WHERE dedupe_key='t3-provider-lineage-failure')<>'DEAD_LETTER'
     OR (SELECT last_error_code FROM ops.jobs
          WHERE dedupe_key='t3-provider-lineage-failure')<>'PROVIDER_OUTCOME_UNKNOWN'
     OR (SELECT status FROM ops.agent_provider_turns
          WHERE agent_run_id='72000000-0000-4000-8000-000000000007')<>'DISPATCHED'
     OR EXISTS(SELECT 1 FROM ops.agent_provider_turns
          WHERE agent_run_id='72000000-0000-4000-8000-000000000007'
            AND (provider_receipt_id IS NOT NULL OR provider_receipt_sha256 IS NOT NULL
                 OR completed_at IS NOT NULL))
     OR v_source.agent_run_id<>'72000000-0000-4000-8000-000000000007'
     OR v_source.use_kind<>'MODEL_INPUT'
     OR v_source.source_use_id<>current_setting('t3.source_use_id')::uuid
     OR btrim(v_source.source_use_sha256::text)<>current_setting('t3.sentinel_digest')
     OR v_source.evidence_segment_id IS NULL OR v_source.source_document_id IS NULL
     OR v_source.locator_value IS NULL OR v_source.selected_content_sha256 IS NULL
     OR NOT EXISTS(SELECT 1 FROM raw.evidence_segments segment
          JOIN raw.source_documents document ON document.id=segment.source_document_id
         WHERE segment.id=v_source.evidence_segment_id
           AND document.id=v_source.source_document_id
           AND segment.locator_value=v_source.locator_value
           AND segment.selected_content_sha256=v_source.selected_content_sha256)
     OR (SELECT count(*) FROM ops.agent_tool_calls
          WHERE agent_run_id=v_source.agent_run_id)<>0
     OR v_source.source_use_canonical IS DISTINCT FROM ops.canonical_jsonb_v1(
          convert_from(v_source.source_use_canonical,'UTF8')::jsonb)
     OR btrim(v_source.source_use_sha256::text) IS DISTINCT FROM encode(
          extensions.digest(ops.canonical_jsonb_v1(
            convert_from(v_source.source_use_canonical,'UTF8')::jsonb
              - 'sourceUseSha256'),'sha256'),'hex') THEN
    RAISE EXCEPTION 'T3 failure lineage assertion failed';
  END IF;
END $$;
SELECT 'T3_FAILURE_QUERYABLE job_status='||job.status||
       ' error_code='||job.last_error_code||' turn_status='||turn.status||
       ' receipt_null='||(turn.provider_receipt_id IS NULL AND turn.provider_receipt_sha256 IS NULL)||
       ' completed_at_null='||(turn.completed_at IS NULL)||
       ' source_use_id='||source_use.source_use_id||
       ' evidence_segment_id='||source_use.evidence_segment_id||
       ' source_document_id='||source_use.source_document_id||
       ' locator='||source_use.locator_value||
       ' selected_sha256='||btrim(source_use.selected_content_sha256::text)||
       ' agent_tool_calls=0 canonical_valid=true'
  FROM ops.jobs job
  JOIN ops.agent_provider_turns turn
    ON turn.agent_run_id='72000000-0000-4000-8000-000000000007'
  JOIN ops.agent_source_uses source_use
    ON source_use.agent_run_id=turn.agent_run_id
   AND source_use.provider_turn_id=turn.provider_turn_id
   AND source_use.use_kind='MODEL_INPUT'
 WHERE job.dedupe_key='t3-provider-lineage-failure';
SQL

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -v source_use_id="$failure_source_use_id" <<'SQL'
-- This directly exercises the persisted exact-pair conflict arbiter. It proves
-- the database idempotency contract, not production binder re-entry: a second
-- worker run is blocked earlier by legacy TOOL_QUERY root materialization.
CREATE TEMP TABLE t3_idempotency_before AS
SELECT source_use.agent_run_id,
       source_use.source_use_id,
       source_use.source_use_sha256,
       source_use.source_use_canonical,
       source_use.provider_receipt_id,
       source_use.provider_receipt_sha256,
       (SELECT count(*) FROM ops.agent_source_uses exact_pair
         WHERE exact_pair.agent_run_id=source_use.agent_run_id
           AND exact_pair.source_use_sha256=source_use.source_use_sha256)
         AS exact_pair_count
  FROM ops.agent_source_uses source_use
 WHERE source_use.source_use_id=:'source_use_id'::uuid;

SET ROLE gurine_analysis_worker;
WITH replay AS (
  INSERT INTO ops.agent_source_uses
  SELECT * FROM ops.agent_source_uses
   WHERE source_use_id=:'source_use_id'::uuid
  ON CONFLICT (agent_run_id,source_use_sha256) DO NOTHING
  RETURNING 1
)
SELECT 'T3_IDEMPOTENCY_DB_EXACT_PAIR_REPLAY_1 inserted='||count(*) FROM replay;
WITH replay AS (
  INSERT INTO ops.agent_source_uses
  SELECT * FROM ops.agent_source_uses
   WHERE source_use_id=:'source_use_id'::uuid
  ON CONFLICT (agent_run_id,source_use_sha256) DO NOTHING
  RETURNING 1
)
SELECT 'T3_IDEMPOTENCY_DB_EXACT_PAIR_REPLAY_2 inserted='||count(*) FROM replay;
RESET ROLE;

DO $$
DECLARE
  v_before t3_idempotency_before%ROWTYPE;
  v_current ops.agent_source_uses%ROWTYPE;
  v_exact_pair_count bigint;
BEGIN
  SELECT * INTO STRICT v_before FROM t3_idempotency_before;
  SELECT * INTO STRICT v_current FROM ops.agent_source_uses
   WHERE source_use_id=v_before.source_use_id;
  SELECT count(*) INTO v_exact_pair_count FROM ops.agent_source_uses exact_pair
   WHERE exact_pair.agent_run_id=v_before.agent_run_id
     AND exact_pair.source_use_sha256=v_before.source_use_sha256;
  IF v_before.exact_pair_count<>1 OR v_exact_pair_count<>1
     OR v_current.source_use_id IS DISTINCT FROM v_before.source_use_id
     OR v_current.source_use_sha256 IS DISTINCT FROM v_before.source_use_sha256
     OR v_current.source_use_canonical IS DISTINCT FROM v_before.source_use_canonical
     OR v_current.provider_receipt_id IS DISTINCT FROM v_before.provider_receipt_id
     OR v_current.provider_receipt_sha256 IS DISTINCT FROM v_before.provider_receipt_sha256 THEN
    RAISE EXCEPTION 'T3 exact-pair database replay mutated lineage';
  END IF;
END $$;
SELECT 'T3_IDEMPOTENCY_DB_EXACT_PAIR count='||before.exact_pair_count||
       ' source_use_id_stable='||(current.source_use_id=before.source_use_id)||
       ' digest_stable='||(current.source_use_sha256=before.source_use_sha256)||
       ' payload_stable='||(current.source_use_canonical=before.source_use_canonical)||
       ' receipt_binding_stable='||(
         current.provider_receipt_id IS NOT DISTINCT FROM before.provider_receipt_id
         AND current.provider_receipt_sha256 IS NOT DISTINCT FROM before.provider_receipt_sha256)
  FROM t3_idempotency_before before
  JOIN ops.agent_source_uses current USING (source_use_id);
SQL

echo "analysis provider MODEL_INPUT pre-dispatch/receipt-promotion/failure runtime: PASS"
