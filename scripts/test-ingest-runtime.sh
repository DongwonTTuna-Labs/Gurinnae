#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-ingest-runtime-$BASHPID"
database="gurine_ingest_runtime"
work="$(mktemp -d -t gurine-ingest-runtime-XXXXXX)"
source_pid=""
supplier_identifier_hmac_key="ZGV2ZWxvcG1lbnQtb25seS1zdXBwbGllci1pZC1rZXk="

cleanup() {
  status=$?
  trap - EXIT
  if [[ $status -ne 0 ]]; then docker logs "$container" >&2 || true; fi
  [[ -z "$source_pid" ]] || kill "$source_pid" >/dev/null 2>&1 || true
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

cd "$root"
cargo build -p gurine-ingest-worker --bins
docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p 127.0.0.1::5432 postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818 >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
mapfile -t migrations < <(printf '%s\n' db/migrations/*.sql | LC_ALL=C sort)
bash scripts/apply-test-migrations-with-r6e-roles.sh "$container" "$database" "${migrations[@]}"
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "ALTER ROLE gurine_ingest_worker LOGIN PASSWORD 'ingest_test';" >/dev/null

actor="51000000-0000-4000-8000-000000000001"
docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<SQL >/dev/null
INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES('$actor','ingest-runtime','ingest@example.test','Ingest Runtime','ACTIVE');
INSERT INTO ops.source_registry(source_id,display_name,connector_type,owner_team,enabled,
  schedule_cron,base_url,legal_status,configuration) VALUES
 ('koneps-contracts','KONEPS Contracts','OFFICIAL_REST','DATA',true,'0 * * * *',
  'https://apis.data.go.kr/1230000/ao/CntrctInfoService/','APPROVED','{}'),
 ('koneps-notices','KONEPS Notices','OFFICIAL_REST','DATA',true,'0 * * * *',
  'https://apis.data.go.kr/1230000/ad/BidPublicInfoService/','APPROVED','{}'),
 ('koneps-bid-results','KONEPS Bid Results','OFFICIAL_REST','DATA',true,'0 * * * *',
  'https://fixture.invalid/koneps-bid-results/','APPROVED','{"fixtureOnly":true}'),
 ('open-dart','Open DART','OFFICIAL_REST','DATA',true,'0 * * * *',
  'https://opendart.fss.or.kr/api/','APPROVED',
  '{
    "parameters": {
      "dart-company": {"corp_code":"00990001"},
      "dart-financial-statements": {
        "corp_code":"00990001","bsns_year":"2026","reprt_code":"11011","fs_div":"CFS"
      },
      "dart-executive-status": {
        "corp_code":"00990001","bsns_year":"2026","reprt_code":"11011"
      },
      "dart-major-shareholder-status": {
        "corp_code":"00990001","bsns_year":"2026","reprt_code":"11014"
      }
    }
  }'),
 ('local-finance','Local Finance','OFFICIAL_LINK','DATA',true,'0 * * * *',NULL,'APPROVED',
  '{"operationUrls":{"local-finance-disclosures":"https://www.data.go.kr/local/disclosures","local-finance-subsidies":"https://www.data.go.kr/local/subsidies","local-finance-statistics":"https://www.data.go.kr/local/statistics"}}'),
 ('alio','ALIO','OFFICIAL_MANIFEST','DATA',true,'0 * * * *',NULL,'APPROVED',
  '{"manifestUrl":"https://www.alio.go.kr/runtime-manifest.json"}'),
 ('audit-results','Audit Results','OFFICIAL_MANIFEST','DATA',true,'0 * * * *',NULL,'APPROVED',
  '{"manifestUrl":"https://www.data.go.kr/audit-results/runtime-manifest.json"}'),
 -- Production remains disabled. This TEST_FIXTURE_ONLY row exercises only the
 -- closed catalog and synthetic fake-source path; its receipt is not production activation evidence.
 ('pps-sanctions','PPS Sanctions [TEST_FIXTURE_ONLY]','OFFICIAL_MANIFEST','DATA',true,'0 * * * *',NULL,'APPROVED',
  '{"manifestUrl":"https://fixture.invalid/pps-sanctions/manifest.json","fixtureMode":"TEST_FIXTURE_ONLY"}');
SQL

sources=(koneps-contracts koneps-notices koneps-bid-results open-dart local-finance alio audit-results pps-sanctions)
index=0
for source in "${sources[@]}"; do
  index=$((index + 1))
  run_id="$(printf '52000000-0000-4000-8000-%012d' "$index")"
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
    -v run_id="$run_id" -v source="$source" <<'SQL' >/dev/null
INSERT INTO ops.source_runs(id,source_id,mode,status,requested_from,requested_to,request_reason,requested_by)
VALUES(:'run_id',:'source','FULL','QUEUED','2026-07-01','2026-07-12','runtime ingest',
  '51000000-0000-4000-8000-000000000001');
INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,run_after)
VALUES(
  'SOURCE_RUN','ingest-worker',
  jsonb_build_object('sourceRunId',:'run_id') ||
    CASE WHEN :'source'='pps-sanctions'
      THEN jsonb_build_object('sourceId',:'source','fixtureMode','TEST_FIXTURE_ONLY')
      ELSE '{}'::jsonb
    END,
  'source-run:'||:'run_id','2020-01-01T00:00:00Z'::timestamptz
);
SQL
done

source_port="$(free_port)"
: >"$work/source-requests.jsonl"
FAKE_SOURCE_PORT="$source_port" FAKE_SOURCE_OUTPUT="$work/source-requests.jsonl" \
  PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-support/fake-source-egress.py &
source_pid=$!
sleep 0.2
postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
GURINE_ENV=test \
INGEST_DATABASE_URL="postgresql://gurine_ingest_worker:ingest_test@127.0.0.1:${postgres_port}/${database}" \
SUPPLIER_IDENTIFIER_HMAC_KEY="$supplier_identifier_hmac_key" \
OBJECT_STORE_ADAPTER=filesystem OBJECT_STORE_FILESYSTEM_ROOT="$work/objects" \
EGRESS_SOURCE_CHANNEL_URL="http://127.0.0.1:${source_port}/source" \
SOURCE_ALIO_ENABLED=true SOURCE_AUDIT_RESULTS_ENABLED=true \
SOURCE_KONEPS_BID_RESULTS_ENABLED=true SOURCE_KONEPS_CONTRACTS_ENABLED=true \
SOURCE_KONEPS_NOTICES_ENABLED=true SOURCE_LOCAL_FINANCE_ENABLED=true \
SOURCE_OPEN_DART_ENABLED=true SOURCE_PPS_SANCTIONS_ENABLED=true \
SOURCE_SYNTHETIC_ENABLED=false \
INGEST_ONCE=true HOSTNAME="ingest-runtime-test" target/debug/gurine-ingest-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.jobs WHERE queue='ingest-worker' AND status='SUCCEEDED';
  IF actual <> 8 THEN RAISE EXCEPTION 'ingest succeeded jobs %, expected 8',actual; END IF;
  SELECT count(*) INTO actual FROM ops.source_runs
   WHERE status='SUCCEEDED' AND records_seen>0 AND report_object_key IS NOT NULL
     AND checkpoint_before IS NOT NULL AND checkpoint_after IS NOT NULL;
  IF actual <> 8 THEN RAISE EXCEPTION 'source runs %, expected 8',actual; END IF;
  SELECT count(*) INTO actual FROM raw.source_fetches;
  IF actual <> 56 THEN RAISE EXCEPTION 'source fetches %, expected 56',actual; END IF;
  SELECT count(*) INTO actual FROM raw.source_documents WHERE status IN ('FETCHED','PARSED');
  IF actual <> 56 THEN RAISE EXCEPTION 'source documents %, expected 56',actual; END IF;
  SELECT count(*) INTO actual FROM raw.source_documents
   WHERE status='PARSED' AND parser_name='connector-structured-json';
  IF actual <> 52 THEN RAISE EXCEPTION 'structured parsed documents %, expected 52',actual; END IF;
  SELECT count(*) INTO actual FROM raw.parsed_records
   WHERE parser_version='connector-structured-json-v1';
  IF actual <> 49 THEN RAISE EXCEPTION 'structured parsed records %, expected 49',actual; END IF;
  SELECT count(*) INTO actual FROM core.contracts WHERE normalization_version='connector-v1';
  IF actual <> 16 THEN RAISE EXCEPTION 'normalized contracts %, expected 16',actual; END IF;
  SELECT count(*) INTO actual FROM core.field_provenance
   WHERE parser_version='connector-structured-json-v1';
  IF actual <> 16 THEN RAISE EXCEPTION 'contract provenance %, expected 16',actual; END IF;
  SELECT count(*) INTO actual FROM ops.outbox WHERE event_type='source.document_stored.v1';
  IF actual <> 56 THEN RAISE EXCEPTION 'document stored events %, expected 56',actual; END IF;
  SELECT count(*) INTO actual FROM ops.source_checkpoints;
  IF actual <> 56 THEN RAISE EXCEPTION 'source checkpoints %, expected 56',actual; END IF;
  SELECT count(*) INTO actual FROM ops.source_registry
   WHERE configuration->'activationReceipt'->>'sourceRunId' IS NOT NULL;
  IF actual <> 8 THEN RAISE EXCEPTION 'activation receipts %, expected 8',actual; END IF;
  IF NOT EXISTS(
    SELECT 1 FROM ops.source_registry
     WHERE source_id='pps-sanctions'
       AND display_name='PPS Sanctions [TEST_FIXTURE_ONLY]'
       AND configuration->>'fixtureMode'='TEST_FIXTURE_ONLY'
  ) THEN RAISE EXCEPTION 'pps-sanctions runtime row is not fixture-only'; END IF;
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE payload->>'sourceId'='pps-sanctions'
     AND payload->>'fixtureMode'='TEST_FIXTURE_ONLY';
  IF actual <> 1 THEN RAISE EXCEPTION 'fixture-only sanctions jobs %, expected 1',actual; END IF;
  SELECT count(*) INTO actual FROM raw.source_documents
   WHERE source_id='pps-sanctions'
     AND metadata->>'connectorOperationId'='pps-sanctions-csv'
     AND content_type='text/csv' AND status='FETCHED'
     AND parser_name IS NULL AND parser_version IS NULL;
  IF actual <> 1 THEN RAISE EXCEPTION 'fixture-only sanctions CSV documents %, expected 1',actual; END IF;
  IF EXISTS(
    SELECT 1 FROM raw.parsed_records p
    JOIN raw.source_documents d ON d.id=p.source_document_id
    WHERE d.source_id='pps-sanctions'
      AND d.metadata->>'connectorOperationId'='pps-sanctions-csv'
  ) THEN RAISE EXCEPTION 'blocked sanctions CSV produced parsed records'; END IF;
  IF EXISTS(SELECT 1 FROM ops.jobs WHERE queue='ingest-worker' AND status<>'SUCCEEDED') THEN
    RAISE EXCEPTION 'ingest queue contains incomplete jobs';
  END IF;
END $$;
SQL

test "$(wc -l <"$work/source-requests.jsonl")" -eq 56
test "$(grep -c '"operationId": "pps-sanctions-' "$work/source-requests.jsonl")" -eq 2
test "$(grep -c 'https://fixture.invalid/pps-sanctions/' "$work/source-requests.jsonl")" -eq 2
test "$(find "$work/objects/raw" -type f | wc -l)" -eq 56
test "$(find "$work/objects/reports/source-runs" -type f | wc -l)" -eq 8
echo "8-connector/56-operation checkpoint-raw-outbox-object-store ingest runtime: PASS"
