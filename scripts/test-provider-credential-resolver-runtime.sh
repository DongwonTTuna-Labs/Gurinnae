#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="gurine-credential-resolver-$BASHPID"
work="$(mktemp -d -t gurine-credential-resolver-XXXXXX)"

cleanup() {
  status=$?
  trap - EXIT
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

cd "$root"
cargo build -p gurine-egress-gateway --bin credential-resolver-probe --locked >/dev/null

docker run --rm -d --name "$container" \
  -e POSTGRES_DB=gurine_credential_resolver \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -p 127.0.0.1::5432 postgres:18.4-bookworm >/dev/null
bash scripts/wait-postgres-container.sh "$container" gurine_credential_resolver
for migration in db/migrations/*.sql; do
  # 0030 intentionally has a second transaction that creates the outbound
  # aggregate after legacy grants; this resolver probe only needs the stable
  # provider registry from 0027 and the pinning function from 0031.
  [[ "$(basename "$migration")" == 0030_* ]] && continue
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d gurine_credential_resolver <"$migration" >/dev/null
done

docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -d gurine_credential_resolver <<'SQL' >/dev/null
INSERT INTO ops.users(id, oidc_subject, email, display_name, status)
VALUES ('73100000-0000-4000-8000-000000000001', 'credential-probe',
        'credential-probe@example.test', 'Credential Probe', 'ACTIVE');
INSERT INTO ops.kill_switches(id, code, scope, state)
VALUES ('73100000-0000-4000-8000-000000000002', 'COMMUNICATION_PROBE', '{}', 'INACTIVE');
INSERT INTO ops.communication_provider_configs(
  id, integration_id, deployment_id, environment, channel, adapter_id,
  operational_state, version, provider_account_hmac, sender_identity_ciphertext,
  sender_identity_hmac, encryption_key_id, credential_secret_reference,
  webhook_secret_reference, callback_path, callback_allowlist_digest,
  jurisdiction_set, jurisdiction_set_digest, dpa_evidence_digest,
  approved_template_catalog_digest, rate_limit_policy, rate_limit_policy_digest,
  cost_policy, cost_policy_digest, provider_capabilities,
  provider_capabilities_digest, kill_switch_code, configuration_digest,
  created_by, updated_by
) VALUES (
  '73100000-0000-4000-8000-000000000010',
  '73100000-0000-4000-8000-000000000011', 'credential-probe', 'test',
  'TELEGRAM_BOT_API', 'telegram-bot-api-v1', 'UNCONFIGURED', 1,
  repeat('a', 64), decode('00', 'hex'), repeat('b', 64), 'probe-key-v1',
  'vault://test/telegram-token@v20260719',
  'vault://test/telegram-webhook@v20260719',
  '/private/v1/callbacks/telegram/73100000-0000-4000-8000-000000000011',
  repeat('c', 64), '{}', repeat('d', 64), repeat('e', 64), repeat('f', 64),
  '{}', repeat('1', 64), '{}', repeat('2', 64), '{}', repeat('3', 64),
  'COMMUNICATION_PROBE', repeat('4', 64),
  '73100000-0000-4000-8000-000000000001',
  '73100000-0000-4000-8000-000000000001'
);
SQL

reference="vault://test/telegram-token@v20260719"
source="vault://test/telegram-token@v20260719"
token="resolver-probe-token-never-written-to-evidence"
positive_json="$work/positive.json"
negative_json="$work/negative.json"
COMMUNICATION_TELEGRAM_TOKEN_SECRET_REFERENCE="$reference" \
COMMUNICATION_TELEGRAM_TOKEN_SOURCE="$source" \
COMMUNICATION_TELEGRAM_TOKEN="$token" \
  target/debug/credential-resolver-probe TELEGRAM >"$positive_json"

if COMMUNICATION_TELEGRAM_TOKEN_SECRET_REFERENCE="$reference" \
  COMMUNICATION_TELEGRAM_TOKEN_SOURCE="vault://test/telegram-token@v20260718" \
  COMMUNICATION_TELEGRAM_TOKEN="$token" \
  target/debug/credential-resolver-probe TELEGRAM >"$negative_json"; then
  echo "credential source mismatch was accepted" >&2
  exit 1
fi

db_row="$(docker exec "$container" psql -At -v ON_ERROR_STOP=1 -U postgres -d gurine_credential_resolver \
  -c "SELECT channel || '|' || version || '|' || credential_secret_reference || '|' || ops.secret_reference_is_version_pinned(credential_secret_reference) FROM ops.communication_provider_configs WHERE id='73100000-0000-4000-8000-000000000010'")"
db_negative="$(docker exec "$container" psql -At -v ON_ERROR_STOP=1 -U postgres -d gurine_credential_resolver \
  -c "SELECT ops.secret_reference_is_version_pinned('vault://test/telegram-token@latest') || '|' || ops.secret_reference_is_version_pinned('plaintext-token')")"

DB_ROW="$db_row" DB_NEGATIVE="$db_negative" POSITIVE_JSON="$positive_json" NEGATIVE_JSON="$negative_json" \
  python3 - "$root/implementation-evidence/credential-resolver-runtime.json" <<'PY'
import json, os, pathlib

positive = json.loads(pathlib.Path(os.environ['POSITIVE_JSON']).read_text())
negative = json.loads(pathlib.Path(os.environ['NEGATIVE_JSON']).read_text())
channel, version, reference, pinned = os.environ['DB_ROW'].split('|', 3)
latest, plaintext = os.environ['DB_NEGATIVE'].split('|', 1)
if positive.get('status') != 'PASS' or negative.get('status') != 'REJECTED':
    raise SystemExit('resolver probe verdict mismatch')
if pinned.lower() != 'true' or latest.lower() != 'false' or plaintext.lower() != 'false':
    raise SystemExit(f'database pinning verdict mismatch: row={os.environ["DB_ROW"]!r} negative={os.environ["DB_NEGATIVE"]!r}')
if len(positive.get('referenceDigest', '')) != 64:
    raise SystemExit('missing reference digest')
output = {
    'schemaVersion': 'credential-resolver-runtime.v1',
    'status': 'PASS',
    'databaseReadback': {
        'channel': channel,
        'providerConfigVersion': int(version),
        'credentialReference': reference,
        'referenceIsVersionPinned': True,
        'mutableAliasRejected': latest.lower() == 'false',
        'plaintextRejected': plaintext.lower() == 'false',
    },
    'resolverReadback': {
        'matchingReference': positive,
        'mismatchedSourceRejected': negative,
        'rawTokenPersisted': False,
        'rawTokenLogged': False,
    },
}
pathlib.Path(os.sys.argv[1]).write_text(json.dumps(output, indent=2) + '\n')
PY

echo "credential resolver runtime: PASS"
