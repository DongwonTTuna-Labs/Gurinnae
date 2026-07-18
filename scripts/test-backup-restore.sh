#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_container="gurine-backup-source-$BASHPID"
restore_container="gurine-backup-restore-$BASHPID"
work="$(mktemp -d -t gurine-backup-restore-XXXXXX)"

cleanup() {
  status=$?
  trap - EXIT
  docker rm -f "$source_container" "$restore_container" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

for container in "$source_container" "$restore_container"; do
  docker run --rm --detach --name "$container" \
    --env POSTGRES_DB=gurine --env POSTGRES_USER=postgres --env POSTGRES_PASSWORD=postgres \
    --publish 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
done
for container in "$source_container" "$restore_container"; do
  ready_streak=0
  for _ in $(seq 1 60); do
    if docker exec "$container" psql -At -U postgres -d gurine -c 'SELECT 1' 2>/dev/null | grep -qx '1'; then
      ready_streak=$((ready_streak + 1))
      [[ "$ready_streak" -ge 3 ]] && break
    else
      ready_streak=0
    fi
    sleep 0.5
  done
  [[ "$ready_streak" -ge 3 ]]
done

cd "$root"
for migration in db/migrations/*.sql; do
  docker exec -i "$source_container" psql -v ON_ERROR_STOP=1 -U postgres -d gurine <"$migration" >/dev/null
done
docker exec -i "$source_container" psql -v ON_ERROR_STOP=1 -U postgres -d gurine \
  <db/test-fixtures/reference-seed.sql >/dev/null

mkdir -p "$work/source-objects/raw/backup"
printf 'durable-object-%s' "$BASHPID" >"$work/source-objects/raw/backup/evidence.bin"
object_sha="$(sha256sum "$work/source-objects/raw/backup/evidence.bin" | cut -d' ' -f1)"
docker exec "$source_container" psql -v ON_ERROR_STOP=1 -U postgres -d gurine -c \
  "INSERT INTO raw.source_documents(id,source_id,external_id,retrieved_at,content_type,content_sha256,content_size_bytes,object_key,status,asset_id,asset_revision) VALUES('90000000-0000-4000-8000-000000000001','backup-source','backup-object',clock_timestamp(),'application/octet-stream','$object_sha',$(stat -c %s "$work/source-objects/raw/backup/evidence.bin"),'raw/backup/evidence.bin','FETCHED','90000000-0000-4000-8000-000000000001',1); INSERT INTO public.cases(id,slug,title,public_state,latest_revision,summary,published_at,updated_at,source_freshness) VALUES('90000000-0000-4000-8000-000000000003','backup-public-record','Backup Public Record','PUBLISHED_CLEAN',1,'Recovery rehearsal public projection',clock_timestamp(),clock_timestamp(),'{}'); SELECT ops.append_audit_event('backup-restore','SYSTEM','backup-test',NULL,'backup.created','source_document','90000000-0000-4000-8000-000000000001','operations.backup','SUCCESS','recovery rehearsal','90000000-0000-4000-8000-000000000002','{}');" >/dev/null

source_port="$(docker port "$source_container" 5432/tcp | sed -n '1s/.*://p')"
restore_port="$(docker port "$restore_container" 5432/tcp | sed -n '1s/.*://p')"
key="$(printf 'backup-rehearsal-key-material-32b' | base64 -w0)"

docker run --rm --network host \
  --volume "$root:/workspace:ro" --volume "$work:/work" \
  --env DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${source_port}/gurine" \
  --env OBJECT_STORE_FILESYSTEM_ROOT=/work/source-objects \
  --env BACKUP_OUTPUT=/work/gurine-backup.tar.gz --env BACKUP_ENCRYPTION_KEY="$key" \
  postgres:18.4-bookworm bash /workspace/infra/scripts/backup.sh >/dev/null

mkdir -p "$work/restored-objects"
docker run --rm --network host \
  --volume "$root:/workspace:ro" --volume "$work:/work" \
  --env RESTORE_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${restore_port}/gurine" \
  --env RESTORE_OBJECT_STORE_FILESYSTEM_ROOT=/work/restored-objects \
  --env RESTORE_ARCHIVE=/work/gurine-backup.tar.gz --env BACKUP_ENCRYPTION_KEY="$key" \
  --env RESTORE_RECEIPT=/work/restore-receipt.json \
  postgres:18.4-bookworm bash /workspace/infra/scripts/restore.sh >/dev/null

restored_sha="$(sha256sum "$work/restored-objects/raw/backup/evidence.bin" | cut -d' ' -f1)"
[[ "$restored_sha" == "$object_sha" ]]
docker exec "$restore_container" psql -At -U postgres -d gurine -c \
  "SELECT count(*) FROM raw.source_documents WHERE id='90000000-0000-4000-8000-000000000001' AND btrim(content_sha256::text)='$object_sha'; SELECT count(*) FROM ops.audit_events e JOIN ops.audit_chain_heads h ON h.head_event_id=e.id AND h.head_hash=e.event_hash WHERE e.object_id='90000000-0000-4000-8000-000000000001'; SELECT count(*) FROM public.cases WHERE id='90000000-0000-4000-8000-000000000003';" \
  | paste -sd, - | grep -qx '1,1,1'
docker run --rm --volume "$work:/work:ro" postgres:18.4-bookworm \
  sh -c "grep -Eq '\"rpoSeconds\":[0-9]+,\"rtoSeconds\":[0-9]+' /work/restore-receipt.json"

printf 'encrypted PostgreSQL/object-store clean backup restore with RPO/RTO receipt: PASS\n'
