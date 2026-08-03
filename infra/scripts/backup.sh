#!/usr/bin/env bash
set -euo pipefail
umask 077

required() {
  local name="$1"
  [[ -n "${!name:-}" ]] || { printf 'backup: %s is required\n' "$name" >&2; exit 1; }
}

required DATABASE_URL
required OBJECT_STORE_FILESYSTEM_ROOT
required BACKUP_OUTPUT
required BACKUP_ENCRYPTION_KEY
[[ -d "$OBJECT_STORE_FILESYSTEM_ROOT" ]] || { printf 'backup: object root is missing\n' >&2; exit 1; }

work="$(mktemp -d -t gurine-backup-XXXXXX)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

started="$(date +%s)"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
pg_dump --format=custom --no-owner --no-privileges --file="$work/database.dump" "$DATABASE_URL"
tar --create --file="$work/objects.tar" --directory="$OBJECT_STORE_FILESYSTEM_ROOT" .
printf '%s' "$BACKUP_ENCRYPTION_KEY" >"$work/key"
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
  -in "$work/database.dump" -out "$work/database.dump.enc" -pass file:"$work/key"
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
  -in "$work/objects.tar" -out "$work/objects.tar.enc" -pass file:"$work/key"
finished="$(date +%s)"
printf '{"formatVersion":1,"createdAt":"%s","durationSeconds":%d}\n' \
  "$created_at" "$((finished-started))" >"$work/metadata.json"
(cd "$work" && sha256sum database.dump.enc objects.tar.enc metadata.json >MANIFEST.sha256)
hmac_key="$(sha256sum "$work/key" | cut -d' ' -f1)"
openssl dgst -sha256 -mac HMAC -macopt hexkey:"$hmac_key" "$work/MANIFEST.sha256" \
  | awk '{print $NF}' >"$work/MANIFEST.hmac"
mkdir -p "$(dirname "$BACKUP_OUTPUT")"
tar --create --gzip --file="$BACKUP_OUTPUT" --directory="$work" \
  database.dump.enc objects.tar.enc MANIFEST.sha256 MANIFEST.hmac metadata.json
printf 'backup: PASS %s\n' "$BACKUP_OUTPUT"
