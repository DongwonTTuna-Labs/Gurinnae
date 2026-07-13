#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'production-preflight: FAIL: %s\n' "$1" >&2
  exit 1
}

required() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || fail "$name is required"
  if [[ "$value" =~ (REPLACE|LOCAL_ONLY|development-only|gurine_dev_only|changeme|password123) ]]; then
    fail "$name contains a forbidden development or replacement marker"
  fi
}

base64_key() {
  local name="$1"
  required "$name"
  local decoded
  decoded="$(printf '%s' "${!name}" | base64 --decode 2>/dev/null | wc -c)" || fail "$name is not valid base64"
  [[ "$decoded" -ge 32 ]] || fail "$name must decode to at least 32 bytes"
}

bool() {
  local name="$1"
  local value="${!name:-false}"
  [[ "$value" == "true" || "$value" == "false" ]] || fail "$name must be true or false"
}

[[ "${GURINE_ENV:-}" == "production" ]] || fail "GURINE_ENV must be production"

for name in \
  POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD \
  MIGRATOR_DATABASE_URL PUBLIC_DATABASE_URL CONTROL_DATABASE_URL IDENTITY_DATABASE_URL \
  SUBMISSION_DATABASE_URL INGEST_DATABASE_URL ANALYSIS_DATABASE_URL PROJECTOR_DATABASE_URL \
  NOTIFICATION_DATABASE_URL WORKFLOW_DATABASE_URL DOCUMENT_EXTRACTOR_DATABASE_URL \
  SCHEDULER_DATABASE_URL \
  PUBLIC_API_INTERNAL_URL CONTROL_API_INTERNAL_URL IDENTITY_API_INTERNAL_URL \
  SUBMISSION_API_INTERNAL_URL PUBLIC_BASE_URL REVIEW_BASE_URL RESPONSE_BASE_URL \
  OIDC_EGRESS_URL OIDC_ISSUER_URL OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_REDIRECT_URI \
  OIDC_STEP_UP_REDIRECT_URI OIDC_SCOPES EMAIL_ADAPTER OBJECT_STORE_ADAPTER; do
  required "$name"
done

for name in \
  AUDIT_CHAIN_HMAC_KEY FIELD_ENCRYPTION_KEY_CURRENT TOKEN_HMAC_KEY \
  IDENTITY_SERVICE_HMAC_KEY_CURRENT IDENTITY_ASSERTION_HMAC_KEY_CURRENT \
  PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT \
  SESSION_COOKIE_KEY_CURRENT SUBMISSION_COOKIE_KEY_CURRENT BOT_CHALLENGE_SECRET_KEY; do
  base64_key "$name"
done

case "$EMAIL_ADAPTER" in
  smtp)
    required EGRESS_SMTP_CHANNEL_URL
    required SMTP_HOST
    required SMTP_URL
    required EMAIL_FROM
    required EMAIL_REPLY_TO
    ;;
  file)
    required EMAIL_FILE_OUTBOX
    [[ "$EMAIL_FILE_OUTBOX" == /* ]] || fail "EMAIL_FILE_OUTBOX must be absolute"
    ;;
  *) fail "EMAIL_ADAPTER must be smtp or file" ;;
esac

case "$OBJECT_STORE_ADAPTER" in
  s3)
    for name in OBJECT_STORE_ENDPOINT OBJECT_STORE_REGION OBJECT_STORE_ACCESS_KEY_ID \
      OBJECT_STORE_SECRET_ACCESS_KEY OBJECT_STORE_RAW_BUCKET OBJECT_STORE_ATTACHMENT_BUCKET \
      EGRESS_OBJECT_STORE_CHANNEL_URL; do
      required "$name"
    done
    ;;
  filesystem)
    required OBJECT_STORE_FILESYSTEM_ROOT
    [[ "$OBJECT_STORE_FILESYSTEM_ROOT" == /* ]] || fail "OBJECT_STORE_FILESYSTEM_ROOT must be absolute"
    ;;
  *) fail "OBJECT_STORE_ADAPTER must be s3 or filesystem" ;;
esac

bool AI_ENABLED
if [[ "$AI_ENABLED" == "true" ]]; then
  required AI_PROVIDER_ORDER
  required EGRESS_AI_CHANNEL_URL
  required AI_CASE_BUDGET_KRW
  required AI_DAILY_BUDGET_KRW
fi

connector_gate() {
  local flag="$1"
  shift
  bool "$flag"
  if [[ "${!flag}" == "true" ]]; then
    for name in "$@"; do required "$name"; done
    printf 'production-preflight: connector %s enabled\n' "$flag"
  else
    printf 'production-preflight: connector %s disabled by configuration\n' "$flag"
  fi
}

connector_gate SOURCE_KONEPS_CONTRACTS_ENABLED DATA_GO_KR_SERVICE_KEY KONEPS_CONTRACT_API_BASE_URL
connector_gate SOURCE_KONEPS_NOTICES_ENABLED DATA_GO_KR_SERVICE_KEY KONEPS_NOTICE_API_BASE_URL
connector_gate SOURCE_OPEN_DART_ENABLED OPEN_DART_API_KEY OPEN_DART_API_BASE_URL
connector_gate SOURCE_LOCAL_FINANCE_ENABLED LOCAL_FINANCE_OFFICIAL_MANIFEST_URL
connector_gate SOURCE_ALIO_ENABLED ALIO_OFFICIAL_MANIFEST_URL
connector_gate SOURCE_AUDIT_RESULTS_ENABLED AUDIT_RESULTS_OFFICIAL_MANIFEST_URL

printf 'production-preflight: PASS\n'
