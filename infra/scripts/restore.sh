#!/usr/bin/env bash
set -euo pipefail
umask 077

required() {
  local name="$1"
  [[ -n "${!name:-}" ]] || { printf 'restore: %s is required\n' "$name" >&2; exit 1; }
}

required RESTORE_DATABASE_URL
required RESTORE_OBJECT_STORE_FILESYSTEM_ROOT
required RESTORE_ARCHIVE
required BACKUP_ENCRYPTION_KEY
[[ -f "$RESTORE_ARCHIVE" ]] || { printf 'restore: archive is missing\n' >&2; exit 1; }
mkdir -p "$RESTORE_OBJECT_STORE_FILESYSTEM_ROOT"
if find "$RESTORE_OBJECT_STORE_FILESYSTEM_ROOT" -mindepth 1 -print -quit | grep -q .; then
  printf 'restore: destination object root must be empty\n' >&2
  exit 1
fi

work="$(mktemp -d -t gurine-restore-XXXXXX)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
started="$(date +%s)"

members="$(tar --list --gzip --file="$RESTORE_ARCHIVE" | sort)"
expected="$(printf '%s\n' MANIFEST.hmac MANIFEST.sha256 database.dump.enc metadata.json objects.tar.enc | sort)"
[[ "$members" == "$expected" ]] || { printf 'restore: unexpected archive members\n' >&2; exit 1; }
tar --extract --gzip --file="$RESTORE_ARCHIVE" --directory="$work"
printf '%s' "$BACKUP_ENCRYPTION_KEY" >"$work/key"
hmac_key="$(sha256sum "$work/key" | cut -d' ' -f1)"
actual_hmac="$(openssl dgst -sha256 -mac HMAC -macopt hexkey:"$hmac_key" "$work/MANIFEST.sha256" | awk '{print $NF}')"
[[ "$actual_hmac" == "$(cat "$work/MANIFEST.hmac")" ]] || { printf 'restore: manifest authentication failed\n' >&2; exit 1; }
(cd "$work" && sha256sum --check MANIFEST.sha256)
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in "$work/database.dump.enc" -out "$work/database.dump" -pass file:"$work/key"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in "$work/objects.tar.enc" -out "$work/objects.tar" -pass file:"$work/key"
while IFS= read -r member; do
  case "$member" in
    /*|../*|*/../*|*/..) printf 'restore: unsafe object archive member\n' >&2; exit 1 ;;
  esac
done < <(tar --list --file="$work/objects.tar")
if tar --list --verbose --file="$work/objects.tar" | awk '$1 !~ /^[-d]/ {exit 1}'; then :; else
  printf 'restore: object archive contains a link or special file\n' >&2
  exit 1
fi
pg_restore --clean --if-exists --no-owner --no-privileges \
  --dbname="$RESTORE_DATABASE_URL" "$work/database.dump"
tar --extract --file="$work/objects.tar" --directory="$RESTORE_OBJECT_STORE_FILESYSTEM_ROOT"

finished="$(date +%s)"
created="$(sed -n 's/.*"createdAt":"\([^"]*\)".*/\1/p' "$work/metadata.json")"
created_epoch="$(date -u -d "$created" +%s)"
receipt="${RESTORE_RECEIPT:-$RESTORE_OBJECT_STORE_FILESYSTEM_ROOT/restore-receipt.json}"
printf '{"formatVersion":1,"restoredAt":"%s","rpoSeconds":%d,"rtoSeconds":%d}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((finished-created_epoch))" "$((finished-started))" >"$receipt"
printf 'restore: PASS %s\n' "$receipt"
