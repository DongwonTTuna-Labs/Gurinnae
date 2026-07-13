#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-ingest-runtime-$BASHPID"
database="gurine_ingest_runtime"
work="$(mktemp -d -t gurine-ingest-runtime-XXXXXX)"
source_pid=""

cleanup() {
  status=$?
  trap - EXIT
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
  -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
for migration in db/migrations/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <"$migration" >/dev/null
done
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
 ('open-dart','Open DART','OFFICIAL_REST','DATA',true,'0 * * * *',
  'https://opendart.fss.or.kr/api/','APPROVED','{}'),
 ('local-finance','Local Finance','OFFICIAL_LINK','DATA',true,'0 * * * *',NULL,'APPROVED',
  '{"operationUrls":{"local-finance-disclosures":"https://www.data.go.kr/local/disclosures","local-finance-subsidies":"https://www.data.go.kr/local/subsidies","local-finance-statistics":"https://www.data.go.kr/local/statistics"}}'),
 ('alio','ALIO','OFFICIAL_MANIFEST','DATA',true,'0 * * * *',NULL,'APPROVED',
  '{"manifestUrl":"https://www.alio.go.kr/runtime-manifest.json"}'),
 ('audit-results','Audit Results','OFFICIAL_MANIFEST','DATA',true,'0 * * * *',NULL,'APPROVED',
  '{"manifestUrl":"https://www.data.go.kr/audit-results/runtime-manifest.json"}');
SQL

sources=(koneps-contracts koneps-notices open-dart local-finance alio audit-results)
index=0
for source in "${sources[@]}"; do
  index=$((index + 1))
  run_id="$(printf '52000000-0000-4000-8000-%012d' "$index")"
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
    -v run_id="$run_id" -v source="$source" <<'SQL' >/dev/null
INSERT INTO ops.source_runs(id,source_id,mode,status,requested_from,requested_to,request_reason,requested_by)
VALUES(:'run_id',:'source','FULL','QUEUED','2026-07-01','2026-07-12','runtime ingest',
  '51000000-0000-4000-8000-000000000001');
INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key)
VALUES('SOURCE_RUN','ingest-worker',jsonb_build_object('sourceRunId',:'run_id'),'source-run:'||:'run_id');
SQL
done

source_port="$(free_port)"
: >"$work/source-requests.jsonl"
FAKE_SOURCE_PORT="$source_port" FAKE_SOURCE_OUTPUT="$work/source-requests.jsonl" \
  python3 scripts/test-support/fake-source-egress.py &
source_pid=$!
sleep 0.2
postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
GURINE_ENV=test \
INGEST_DATABASE_URL="postgresql://gurine_ingest_worker:ingest_test@127.0.0.1:${postgres_port}/${database}" \
OBJECT_STORE_ADAPTER=filesystem OBJECT_STORE_FILESYSTEM_ROOT="$work/objects" \
EGRESS_SOURCE_CHANNEL_URL="http://127.0.0.1:${source_port}/source" \
INGEST_ONCE=true HOSTNAME="ingest-runtime-test" target/debug/gurine-ingest-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <<'SQL' >/dev/null
DO $$
DECLARE actual bigint;
BEGIN
  SELECT count(*) INTO actual FROM ops.jobs WHERE queue='ingest-worker' AND status='SUCCEEDED';
  IF actual <> 6 THEN RAISE EXCEPTION 'ingest succeeded jobs %, expected 6',actual; END IF;
  SELECT count(*) INTO actual FROM ops.source_runs
   WHERE status='SUCCEEDED' AND records_seen>0 AND report_object_key IS NOT NULL
     AND checkpoint_before IS NOT NULL AND checkpoint_after IS NOT NULL;
  IF actual <> 6 THEN RAISE EXCEPTION 'source runs %, expected 6',actual; END IF;
  SELECT count(*) INTO actual FROM raw.source_fetches;
  IF actual <> 44 THEN RAISE EXCEPTION 'source fetches %, expected 44',actual; END IF;
  SELECT count(*) INTO actual FROM raw.source_documents WHERE status IN ('FETCHED','PARSED');
  IF actual <> 44 THEN RAISE EXCEPTION 'source documents %, expected 44',actual; END IF;
  SELECT count(*) INTO actual FROM raw.source_documents
   WHERE status='PARSED' AND parser_name='connector-structured-json';
  IF actual <> 41 THEN RAISE EXCEPTION 'structured parsed documents %, expected 41',actual; END IF;
  SELECT count(*) INTO actual FROM raw.parsed_records
   WHERE parser_version='connector-structured-json-v1';
  IF actual <> 38 THEN RAISE EXCEPTION 'structured parsed records %, expected 38',actual; END IF;
  SELECT count(*) INTO actual FROM core.contracts WHERE normalization_version='connector-v1';
  IF actual <> 16 THEN RAISE EXCEPTION 'normalized contracts %, expected 16',actual; END IF;
  SELECT count(*) INTO actual FROM core.field_provenance
   WHERE parser_version='connector-structured-json-v1';
  IF actual <> 16 THEN RAISE EXCEPTION 'contract provenance %, expected 16',actual; END IF;
  SELECT count(*) INTO actual FROM ops.outbox WHERE event_type='source.document_stored.v1';
  IF actual <> 44 THEN RAISE EXCEPTION 'document stored events %, expected 44',actual; END IF;
  SELECT count(*) INTO actual FROM ops.source_checkpoints;
  IF actual <> 44 THEN RAISE EXCEPTION 'source checkpoints %, expected 44',actual; END IF;
  SELECT count(*) INTO actual FROM ops.source_registry
   WHERE configuration->'activationReceipt'->>'sourceRunId' IS NOT NULL;
  IF actual <> 6 THEN RAISE EXCEPTION 'activation receipts %, expected 6',actual; END IF;
  IF EXISTS(SELECT 1 FROM ops.jobs WHERE queue='ingest-worker' AND status<>'SUCCEEDED') THEN
    RAISE EXCEPTION 'ingest queue contains incomplete jobs';
  END IF;
END $$;
SQL

test "$(wc -l <"$work/source-requests.jsonl")" -eq 44
test "$(find "$work/objects/raw" -type f | wc -l)" -eq 44
test "$(find "$work/objects/reports/source-runs" -type f | wc -l)" -eq 6
echo "6-connector/44-operation checkpoint-raw-outbox-object-store ingest runtime: PASS"
