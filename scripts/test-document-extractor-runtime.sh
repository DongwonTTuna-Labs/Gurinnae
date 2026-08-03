#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-document-runtime-$BASHPID"
database="gurine_document_runtime"
work="$(mktemp -d -t gurine-document-runtime-XXXXXX)"
supplier_identifier_hmac_key="ZGV2ZWxvcG1lbnQtb25seS1zdXBwbGllci1pZC1rZXk="

cleanup() {
  status=$?
  trap - EXIT
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

cd "$root"
cargo build -p gurine-scheduler -p gurine-document-extractor -p gurine-ingest-worker -p gurine-analysis-worker -p gurine-projection-worker -p gurine-notification-worker
docker run --rm -d --name "$container" \
  -e POSTGRES_DB="$database" -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
bash scripts/wait-postgres-container.sh "$container" "$database"
for migration in db/migrations/*.sql; do
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" <"$migration" >/dev/null
done
docker exec "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" -c \
  "ALTER ROLE gurine_scheduler LOGIN PASSWORD 'scheduler_test'; ALTER ROLE gurine_document_extractor LOGIN PASSWORD 'extractor_test'; ALTER ROLE gurine_ingest_worker LOGIN PASSWORD 'ingest_test'; ALTER ROLE gurine_analysis_worker LOGIN PASSWORD 'analysis_test'; ALTER ROLE gurine_public_projector LOGIN PASSWORD 'projector_test'; ALTER ROLE gurine_notification_worker LOGIN PASSWORD 'notification_test';" >/dev/null

mkdir -p "$work/objects/raw/runtime"
cp specs/parsers/fixtures/valid-contract.csv "$work/objects/raw/runtime/valid-contract.csv"
cp specs/parsers/fixtures/legacy-binary.hwp "$work/objects/raw/runtime/legacy-binary.hwp"
csv_sha="$(sha256sum "$work/objects/raw/runtime/valid-contract.csv" | cut -d' ' -f1)"
hwp_sha="$(sha256sum "$work/objects/raw/runtime/legacy-binary.hwp" | cut -d' ' -f1)"
csv_size="$(stat -c %s "$work/objects/raw/runtime/valid-contract.csv")"
hwp_size="$(stat -c %s "$work/objects/raw/runtime/legacy-binary.hwp")"
csv_id="10000000-0000-4000-8000-000000000001"
hwp_id="10000000-0000-4000-8000-000000000002"

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -v csv_id="$csv_id" -v hwp_id="$hwp_id" -v csv_sha="$csv_sha" -v hwp_sha="$hwp_sha" \
  -v csv_size="$csv_size" -v hwp_size="$hwp_size" <<'SQL' >/dev/null
INSERT INTO raw.source_documents(
  id,source_id,external_id,retrieved_at,content_type,content_sha256,
  content_size_bytes,object_key,status,asset_id,asset_revision
) VALUES
 (:'csv_id','runtime-source','csv-1',clock_timestamp(),'text/csv',:'csv_sha',
  :'csv_size','raw/runtime/valid-contract.csv','FETCHED',:'csv_id',1),
 (:'hwp_id','runtime-source','hwp-1',clock_timestamp(),'application/x-hwp',:'hwp_sha',
  :'hwp_size','raw/runtime/legacy-binary.hwp','FETCHED',:'hwp_id',1);
INSERT INTO core.rule_versions(
  id,rule_id,version,name,description,configuration,code_digest,status,row_version
) VALUES(
  '10000000-0000-4000-8000-000000000003','runtime-rule','1.0.0','Runtime rule',
  'Scheduler activation consumer fixture','{}',repeat('a',64),'ACTIVE',1
);
INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
VALUES
 ('11111111-1111-4111-8111-111111111111','runtime-publisher','runtime-publisher@example.test','Runtime Publisher','ACTIVE'),
 ('22222222-2222-4222-8222-222222222222','runtime-reviewer','runtime-reviewer@example.test','Runtime Reviewer','ACTIVE');
INSERT INTO editorial.cases(
  id,public_slug,title,investigation_state,publication_state,summary,version
) VALUES(
  '10000000-0000-4000-8000-000000000007','runtime-publication','Runtime Publication',
  'READY_TO_PUBLISH','PUBLISHED_ANOMALY','Projected summary',1
);
INSERT INTO editorial.review_snapshots(
  id,case_id,case_version,snapshot_sha256,snapshot_payload,automated_gate_results,created_by
) VALUES(
  '10000000-0000-4000-8000-000000000008','10000000-0000-4000-8000-000000000007',1,
  repeat('b',64),'{}','{}','11111111-1111-4111-8111-111111111111'
);
UPDATE editorial.cases
SET current_review_snapshot_id='10000000-0000-4000-8000-000000000008'
WHERE id='10000000-0000-4000-8000-000000000007';
INSERT INTO editorial.review_decisions(
  review_snapshot_id,reviewer_id,decision,reason,criteria,reviewer_independence,reauth_context_hash
) VALUES(
  '10000000-0000-4000-8000-000000000008','22222222-2222-4222-8222-222222222222',
  'APPROVE','Independent runtime projection approval','{}','{"independent":true}',repeat('d',64)
);
INSERT INTO editorial.publication_previews(
  case_id,review_snapshot_id,locale,preview_payload,preview_sha256,expires_at,created_by
) VALUES(
  '10000000-0000-4000-8000-000000000007','10000000-0000-4000-8000-000000000008',
  'runtime','{}','44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
  clock_timestamp()+interval '1 hour','11111111-1111-4111-8111-111111111111'
);
INSERT INTO editorial.publication_revisions(
  id,case_id,revision,state,review_snapshot_id,public_payload,public_payload_sha256,
  preview_sha256,published_by
) VALUES(
  '10000000-0000-4000-8000-000000000009','10000000-0000-4000-8000-000000000007',1,
  'PUBLISHED_ANOMALY','10000000-0000-4000-8000-000000000008','{}',
  '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
  '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
  '11111111-1111-4111-8111-111111111111'
);
INSERT INTO ops.jobs(
  id,job_type,queue,status,payload,lease_owner,lease_token,lease_expires_at,
  fencing_token,attempt_count,max_attempts,version
) VALUES(
  '10000000-0000-4000-8000-000000000004','EXPIRED_FIXTURE','expired-test','RUNNING','{}',
  'crashed-worker','10000000-0000-4000-8000-000000000005',clock_timestamp()-interval '1 minute',
  1,1,1,1
);
INSERT INTO ops.job_attempts(job_id,attempt,worker_id,fencing_token,started_at)
VALUES(
  '10000000-0000-4000-8000-000000000004',1,'crashed-worker',1,
  clock_timestamp()-interval '2 minutes'
);
SELECT ops.enqueue_outbox(
  'source_document',:'csv_id',1,'source.document_stored.v1',
  jsonb_build_object('content_sha256',:'csv_sha','source_document_id',:'csv_id','source_id','runtime-source'),
  clock_timestamp()
);
SELECT ops.enqueue_outbox(
  'source_document',:'hwp_id',1,'source.document_stored.v1',
  jsonb_build_object('content_sha256',:'hwp_sha','source_document_id',:'hwp_id','source_id','runtime-source'),
  clock_timestamp()
);
SELECT ops.enqueue_outbox(
  'rule_version','10000000-0000-4000-8000-000000000003',1,
  'workflow.rule_activation_applied.v1',
  jsonb_build_object(
    'actor_id','11111111-1111-4111-8111-111111111111',
    'occurred_at',to_char(clock_timestamp(),'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'operation_id','activateRuleVersion',
    'request_id','10000000-0000-4000-8000-000000000006',
    'ruleVersionId','10000000-0000-4000-8000-000000000003',
    'targetVersionId','10000000-0000-4000-8000-000000000003'
  ),clock_timestamp()
);
SELECT ops.enqueue_outbox(
  'publication_revision','10000000-0000-4000-8000-000000000009',1,
  'projection.publication_revision_created.v1',
  jsonb_build_object(
    'actor_id','11111111-1111-4111-8111-111111111111',
    'caseId','10000000-0000-4000-8000-000000000007',
    'occurred_at',to_char(clock_timestamp(),'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'operation_id','publishCase',
    'request_id','10000000-0000-4000-8000-00000000000a',
    'reviewSnapshotId','10000000-0000-4000-8000-000000000008'
  ),clock_timestamp()
);
SQL

postgres_port="$(docker port "$container" 5432/tcp | sed -n '1s/.*://p')"
SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_INSTANCE_ID="runtime-test" SCHEDULER_ONCE=true \
  target/debug/gurine-scheduler

GURINE_ENV=test AI_ENABLED=false \
ANALYSIS_DATABASE_URL="postgresql://gurine_analysis_worker:analysis_test@127.0.0.1:${postgres_port}/${database}" \
ANALYSIS_ONCE=true HOSTNAME="analysis-runtime-test" \
  target/debug/gurine-analysis-worker

PROJECTOR_DATABASE_URL="postgresql://gurine_public_projector:projector_test@127.0.0.1:${postgres_port}/${database}" \
PROJECTOR_ONCE=true HOSTNAME="projection-runtime-test" \
  target/debug/gurine-projection-worker

GURINE_ENV=test OBJECT_STORE_ADAPTER=filesystem \
OBJECT_STORE_FILESYSTEM_ROOT="$work/objects" \
DOCUMENT_EXTRACTOR_DATABASE_URL="postgresql://gurine_document_extractor:extractor_test@127.0.0.1:${postgres_port}/${database}" \
DOCUMENT_EXTRACTOR_ONCE=true HOSTNAME="document-runtime-test" \
  target/debug/gurine-document-extractor

# Dispatch the successful parse event to ingest-worker.  Its durable QUEUED
# job is the hand-off evidence; the ingest runtime has a separate hard gate.
SCHEDULER_DATABASE_URL="postgresql://gurine_scheduler:scheduler_test@127.0.0.1:${postgres_port}/${database}" \
SCHEDULER_INSTANCE_ID="runtime-test" SCHEDULER_ONCE=true \
  target/debug/gurine-scheduler

GURINE_ENV=test OBJECT_STORE_ADAPTER=filesystem \
OBJECT_STORE_FILESYSTEM_ROOT="$work/objects" \
INGEST_DATABASE_URL="postgresql://gurine_ingest_worker:ingest_test@127.0.0.1:${postgres_port}/${database}" \
SUPPLIER_IDENTIFIER_HMAC_KEY="$supplier_identifier_hmac_key" \
INGEST_ONCE=true HOSTNAME="ingest-runtime-test" \
  target/debug/gurine-ingest-worker

test_key="$(printf '01234567890123456789012345678901' | base64 -w0)"
NOTIFICATION_DATABASE_URL="postgresql://gurine_notification_worker:notification_test@127.0.0.1:${postgres_port}/${database}" \
FIELD_ENCRYPTION_KEY_CURRENT="$test_key" TOKEN_HMAC_KEY="$test_key" \
EMAIL_ADAPTER=smtp \
EGRESS_SMTP_CHANNEL_URL="http://127.0.0.1:9/smtp" EMAIL_FROM="gurine@example.test" \
EMAIL_REPLY_TO="ops@example.test" \
PUBLIC_BASE_URL="http://public.example.test" RESPONSE_BASE_URL="http://response.example.test" \
NOTIFICATION_ONCE=true HOSTNAME="notification-runtime-test" \
  target/debug/gurine-notification-worker

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d "$database" \
  -v csv_id="$csv_id" -v hwp_id="$hwp_id" <<'SQL' >/dev/null
DO $$
DECLARE
  actual bigint;
  digest text;
BEGIN
  IF (SELECT status::text FROM raw.source_documents WHERE id='10000000-0000-4000-8000-000000000001') <> 'PARSED' THEN
    RAISE EXCEPTION 'CSV source document did not reach PARSED';
  END IF;
  IF (SELECT status::text FROM raw.source_documents WHERE id='10000000-0000-4000-8000-000000000002') <> 'QUARANTINED' THEN
    RAISE EXCEPTION 'binary HWP source document did not reach QUARANTINED';
  END IF;
  IF (SELECT quarantine_reason FROM raw.source_documents WHERE id='10000000-0000-4000-8000-000000000002') <>
     'BINARY_HWP_UNSUPPORTED_REQUIRES_TRUSTED_CONVERSION' THEN
    RAISE EXCEPTION 'binary HWP quarantine reason is not canonical';
  END IF;
  SELECT count(*) INTO actual FROM core.parser_runs WHERE source_document_id='10000000-0000-4000-8000-000000000001' AND status='SUCCEEDED';
  IF actual <> 1 THEN RAISE EXCEPTION 'successful parser runs %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM core.parser_runs WHERE source_document_id='10000000-0000-4000-8000-000000000002' AND status='QUARANTINED';
  IF actual <> 1 THEN RAISE EXCEPTION 'quarantined parser runs %, expected 1', actual; END IF;
  SELECT btrim(output_digest) INTO digest FROM core.parser_runs WHERE source_document_id='10000000-0000-4000-8000-000000000001';
  IF digest IS NULL OR length(digest) <> 64 THEN RAISE EXCEPTION 'parsed output digest missing'; END IF;
  SELECT count(*) INTO actual FROM ops.inbox
   WHERE consumer='document-extractor' AND processed_at IS NOT NULL AND result IN ('SUCCEEDED','QUARANTINED');
  IF actual <> 2 THEN RAISE EXCEPTION 'processed extractor inbox rows %, expected 2', actual; END IF;
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE queue='document-extractor' AND job_type='EVENT_DELIVERY' AND status='SUCCEEDED';
  IF actual <> 2 THEN RAISE EXCEPTION 'successful extractor jobs %, expected 2', actual; END IF;
  SELECT count(*) INTO actual FROM ops.outbox
   WHERE event_type='source.document_parsed.v1' AND aggregate_id='10000000-0000-4000-8000-000000000001' AND published_at IS NOT NULL;
  IF actual <> 1 THEN RAISE EXCEPTION 'parsed event rows %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE queue='ingest-worker' AND job_type='EVENT_DELIVERY' AND status='SUCCEEDED';
  IF actual <> 1 THEN RAISE EXCEPTION 'ingest jobs %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.inbox
   WHERE consumer='ingest-worker' AND processed_at IS NOT NULL AND result='SUCCEEDED';
  IF actual <> 1 THEN RAISE EXCEPTION 'ingest inbox rows %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM raw.parsed_records
   WHERE source_document_id='10000000-0000-4000-8000-000000000001';
  IF actual <> 2 THEN RAISE EXCEPTION 'raw parsed records %, expected 2', actual; END IF;
  IF length((SELECT metadata->>'parsedSchemaFingerprint' FROM raw.source_documents
             WHERE id='10000000-0000-4000-8000-000000000001')) <> 64 THEN
    RAISE EXCEPTION 'parsed schema fingerprint missing';
  END IF;
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE queue='scheduler' AND job_type='EVENT_DELIVERY' AND status='SUCCEEDED';
  IF actual <> 1 THEN RAISE EXCEPTION 'scheduler consumer jobs %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.inbox
   WHERE consumer='scheduler' AND processed_at IS NOT NULL AND result='SUCCEEDED';
  IF actual <> 1 THEN RAISE EXCEPTION 'scheduler inbox rows %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE queue='analysis-worker' AND job_type='EVENT_DELIVERY' AND status='SUCCEEDED';
  IF actual <> 1 THEN RAISE EXCEPTION 'analysis jobs %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.inbox
   WHERE consumer='analysis-worker' AND processed_at IS NOT NULL AND result='SUCCEEDED';
  IF actual <> 1 THEN RAISE EXCEPTION 'analysis inbox rows %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE queue='projection-worker' AND job_type='EVENT_DELIVERY' AND status='SUCCEEDED';
  IF actual <> 1 THEN RAISE EXCEPTION 'projection jobs %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.inbox
   WHERE consumer='projection-worker' AND processed_at IS NOT NULL AND result='SUCCEEDED';
  IF actual <> 1 THEN RAISE EXCEPTION 'projection inbox rows %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM public.cases
   WHERE id='10000000-0000-4000-8000-000000000007' AND slug='runtime-publication'
     AND latest_revision=1 AND public_state='PUBLISHED_ANOMALY';
  IF actual <> 1 THEN RAISE EXCEPTION 'public projected cases %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM public.case_revisions
   WHERE case_id='10000000-0000-4000-8000-000000000007' AND revision=1
     AND btrim(payload_sha256)='44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a';
  IF actual <> 1 THEN RAISE EXCEPTION 'public projected revisions %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE queue='notification-worker' AND job_type='EVENT_DELIVERY' AND status='SUCCEEDED';
  IF actual <> 1 THEN RAISE EXCEPTION 'notification jobs %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.inbox
   WHERE consumer='notification-worker' AND processed_at IS NOT NULL AND result='SUCCEEDED';
  IF actual <> 1 THEN RAISE EXCEPTION 'notification inbox rows %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.jobs
   WHERE id='10000000-0000-4000-8000-000000000004' AND status='DEAD_LETTER'
     AND last_error_code='LEASE_EXPIRED';
  IF actual <> 1 THEN RAISE EXCEPTION 'expired lease dead-letter jobs %, expected 1', actual; END IF;
  SELECT count(*) INTO actual FROM ops.outbox
   WHERE event_type='job.dead_lettered.v1' AND aggregate_id='10000000-0000-4000-8000-000000000004'
     AND published_at IS NOT NULL;
  IF actual <> 1 THEN RAISE EXCEPTION 'dead-letter observability events %, expected 1', actual; END IF;
END
$$;
SQL

output_digest="$(docker exec "$container" psql -At -U postgres -d "$database" -c \
  "SELECT btrim(output_digest) FROM core.parser_runs WHERE source_document_id='$csv_id'")"
output_path="$work/objects/parsed/$csv_id/$output_digest.json"
test -f "$output_path"
test "$(sha256sum "$output_path" | cut -d' ' -f1)" = "$output_digest"

echo "scheduler/document-extractor/ingest/analysis/projection/notification outbox-job-fencing-object-store-PostgreSQL runtime: PASS"
