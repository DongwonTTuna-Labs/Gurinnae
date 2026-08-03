#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
preflight_only=false
case "${1:-}" in
  "") ;;
  --preflight-only) preflight_only=true ;;
  *)
    printf 'usage: %s [--preflight-only]\n' "$0" >&2
    exit 2
    ;;
esac
[[ "$#" -le 1 ]] || {
  printf 'usage: %s [--preflight-only]\n' "$0" >&2
  exit 2
}
project="gurine-verify-$BASHPID"
compose=(docker compose --project-name "$project" --profile test --env-file "$root/.env.example" --file "$root/compose.yaml")
preflight_fixture_root="$(mktemp -d)"

cleanup() {
  status=$?
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    "${compose[@]}" ps --all >&2 || true
    "${compose[@]}" exec -T postgres psql -U gurine_dev -d gurine -c \
      "TABLE ops.jobs; TABLE ops.job_attempts; TABLE ops.inbox; TABLE ops.email_deliveries; SELECT id,event_type,published_at FROM ops.outbox ORDER BY occurred_at DESC LIMIT 20;" >&2 || true
    "${compose[@]}" logs --no-color --tail 200 >&2 || true
  fi
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf -- "$preflight_fixture_root"
  exit "$status"
}
trap cleanup EXIT

cd "$root"

if env -i PATH="$PATH" GURINE_ENV=production bash infra/scripts/production-preflight.sh >/dev/null 2>&1; then
  printf 'production preflight accepted missing inputs\n' >&2
  exit 1
fi

key="MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE="
supplier_identifier_hmac_key="ZGV2ZWxvcG1lbnQtb25seS1zdXBwbGllci1pZC1rZXk="
fixture_dir="$root/scripts/test-fixtures/production-preflight"
install -D -m 0755 "$root/infra/scripts/production-preflight.sh" \
  "$preflight_fixture_root/infra/scripts/production-preflight.sh"
install -D -m 0644 "$fixture_dir/generated-legal-content-published.json" \
  "$preflight_fixture_root/verification/generated-legal-content.json"
install -D -m 0644 "$root/specs/legal/law-enforcement-request-procedure.yaml" \
  "$preflight_fixture_root/specs/legal/law-enforcement-request-procedure.yaml"
install -D -m 0644 "$root/db/migrations/0041_r6e_monetization_runtime.sql" \
  "$preflight_fixture_root/db/migrations/0041_r6e_monetization_runtime.sql"
preflight_script="$preflight_fixture_root/infra/scripts/production-preflight.sh"
draft_legal_content="$fixture_dir/generated-legal-content-draft.json"
published_legal_content="$fixture_dir/generated-legal-content-published.json"
counsel_receipt="$fixture_dir/external-counsel-review.receipt"
workflow_receipt="$fixture_dir/law-enforcement-workflow.receipt"
empty_bindings="$fixture_dir/source-license-bindings-empty.json"
open_dart_bindings="$fixture_dir/source-license-bindings-open-dart.json"
counsel_sha="$(sha256sum "$counsel_receipt" | awk '{print $1}')"
workflow_sha="$(sha256sum "$workflow_receipt" | awk '{print $1}')"
empty_bindings_sha="$(sha256sum "$empty_bindings" | awk '{print $1}')"
open_dart_bindings_sha="$(sha256sum "$open_dart_bindings" | awk '{print $1}')"

preflight_env=(
  GURINE_ENV=production POSTGRES_DB=gurine POSTGRES_USER=gurine POSTGRES_PASSWORD=strong-test-value
  ROLE_PROVISIONER_DATABASE_URL=postgresql://cluster_admin:secret@postgres/gurine
  ROLE_PROVISIONER_EXPECTED_ACTOR=cluster_admin
  MIGRATOR_DATABASE_URL=postgresql://migrator:secret@postgres/gurine
  PUBLIC_DATABASE_URL=postgresql://public:secret@postgres/gurine
  CONTROL_DATABASE_URL=postgresql://control:secret@postgres/gurine
  IDENTITY_DATABASE_URL=postgresql://identity:secret@postgres/gurine
  SUBMISSION_DATABASE_URL=postgresql://submission:secret@postgres/gurine
  INGEST_DATABASE_URL=postgresql://ingest:secret@postgres/gurine
  ANALYSIS_DATABASE_URL=postgresql://analysis:secret@postgres/gurine
  PROJECTOR_DATABASE_URL=postgresql://projector:secret@postgres/gurine
  NOTIFICATION_DATABASE_URL=postgresql://notification:secret@postgres/gurine
  WORKFLOW_DATABASE_URL=postgresql://workflow:secret@postgres/gurine
  DOCUMENT_EXTRACTOR_DATABASE_URL=postgresql://extractor:secret@postgres/gurine
  ECONOMICS_DATABASE_URL=
  SCHEDULER_DATABASE_URL=postgresql://scheduler:secret@postgres/gurine
  EGRESS_DATABASE_URL=postgresql://gurine_egress_gateway:secret@postgres/gurine
  BILLING_DATABASE_URL=postgresql://gurine_billing_gateway:secret@postgres/gurine
  PUBLIC_API_INTERNAL_URL=http://public-api:8080 CONTROL_API_INTERNAL_URL=http://control-api:8081
  IDENTITY_API_INTERNAL_URL=http://identity-api:8083 SUBMISSION_API_INTERNAL_URL=http://submission-api:8082
  BILLING_GATEWAY_INTERNAL_URL=http://billing-gateway:8092 BILLING_GATEWAY_MODE=DISABLED
  DONATION_TEST_PAYMENT_OUTCOME=
  PAYMENT_FIXTURE_BILLING_HMAC_KEY_CURRENT=
  PAYMENT_FIXTURE_BILLING_HMAC_KEY_PREVIOUS=
  PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_CURRENT=
  PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_CURRENT_VERSION=
  PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_PREVIOUS=
  PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_PREVIOUS_VERSION=
  PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_CURRENT=
  PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_CURRENT_VERSION=
  PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_PREVIOUS=
  PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_PREVIOUS_VERSION=
  PUBLIC_BASE_URL=https://public.gurine.test REVIEW_BASE_URL=https://review.gurine.test
  RESPONSE_BASE_URL=https://respond.gurine.test OIDC_EGRESS_URL=http://egress-gateway:8090/oidc
  OIDC_ISSUER_URL=https://identity.gurine.test OIDC_CLIENT_ID=gurine-review
  OIDC_CLIENT_SECRET=strong-client-secret OIDC_REDIRECT_URI=https://review.gurine.test/auth/callback
  OIDC_STEP_UP_REDIRECT_URI=https://review.gurine.test/auth/step-up/callback
  "OIDC_SCOPES=openid profile email"
  EMAIL_ADAPTER=file EMAIL_FILE_OUTBOX=/var/lib/gurine-mail OBJECT_STORE_ADAPTER=filesystem
  OBJECT_STORE_FILESYSTEM_ROOT=/var/lib/gurine-objects AI_ENABLED=false
  SOURCE_KONEPS_CONTRACTS_ENABLED=false SOURCE_KONEPS_NOTICES_ENABLED=false
  SOURCE_KONEPS_BID_RESULTS_ENABLED=false SOURCE_OPEN_DART_ENABLED=false
  SOURCE_LOCAL_FINANCE_ENABLED=false SOURCE_ALIO_ENABLED=false SOURCE_AUDIT_RESULTS_ENABLED=false
  SOURCE_PPS_SANCTIONS_ENABLED=false
  AUDIT_CHAIN_HMAC_KEY="$key" FIELD_ENCRYPTION_KEY_CURRENT="$key" TOKEN_HMAC_KEY="$key"
  SUPPLIER_IDENTIFIER_HMAC_KEY="$supplier_identifier_hmac_key"
  IDENTITY_SERVICE_HMAC_KEY_CURRENT="$key" IDENTITY_ASSERTION_HMAC_KEY_CURRENT="$key"
  PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT="$key"
  PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT="$key" RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT="$key"
  SESSION_COOKIE_KEY_CURRENT="$key" SUBMISSION_COOKIE_KEY_CURRENT="$key"
  BOT_CHALLENGE_SECRET_KEY="$key" BOT_CHALLENGE_SITE_KEY=turnstile-production-test-site-key
  GURINE_OPERATING_LEGAL_ENTITY=fixture-operator-entity
  GURINE_PRIVACY_CONTROLLER=fixture-privacy-controller
  GURINE_PRIVACY_OFFICER_OR_CPO=fixture-privacy-office
  GURINE_PUBLIC_LEGAL_AND_PRIVACY_CONTACT=fixture-privacy-contact
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH="$counsel_receipt"
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_SHA256="$counsel_sha"
  GURINE_LAW_ENFORCEMENT_WORKFLOW_RECEIPT_PATH="$workflow_receipt"
  GURINE_LAW_ENFORCEMENT_WORKFLOW_RECEIPT_SHA256="$workflow_sha"
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_PATH="$empty_bindings"
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_SHA256="$empty_bindings_sha"
)

run_preflight_mode_with_results() {
  local mode="$1"
  local schedule_result="$2"
  local source_license_result="$3"
  local -a mode_env
  shift 3
  case "$mode" in
    PRODUCTION) mode_env=(GURINE_ENV=production GURINE_PREFLIGHT_MODE=PRODUCTION) ;;
    TEST_HARNESS) mode_env=(GURINE_ENV=preflight-test GURINE_PREFLIGHT_MODE=TEST_HARNESS) ;;
    *) return 2 ;;
  esac
  env -i PATH="$PATH" "${preflight_env[@]}" \
    "${mode_env[@]}" \
    GURINE_TEST_SCHEDULE_RESULT="$schedule_result" \
    GURINE_TEST_SOURCE_LICENSE_RESULT="$source_license_result" \
    GURINE_TEST_PRIVACY_ACCESS_POLICY_RESULT="${GURINE_TEST_PRIVACY_ACCESS_POLICY_RESULT:-t}" \
    GURINE_TEST_R6E_ROLE_RESULT="${GURINE_TEST_R6E_ROLE_RESULT:-t}" \
    GURINE_TEST_PSQL_AVAILABLE=true "$@" \
    bash -c '
      command() {
        if [[ "${GURINE_TEST_PSQL_AVAILABLE:-true}" == "false" \
          && "${1:-}" == "-v" && "${2:-}" == "psql" ]]; then
          return 1
        fi
        builtin command "$@"
      }
      psql() {
        local query
        query="$(command cat)"
        if [[ "$query" == *public.approved_record_class_schedules* ]]; then
          [[ "$query" == *ops.r6d_record_class_catalog* \
            && "$query" == *authority_version=* \
            && "$query" == *supervisor-decision-v1* \
            && "$query" == *AGENT_RUNTIME_POLICY* \
            && "$query" == *AGENT_RUNTIME_INITIATION_RECEIPT* \
            && "$query" == *required_terminal_action* \
            && "$query" == *required_trigger_kind* \
            && "$query" == *required_active_duration_seconds* \
            && "$query" == *required_backup_duration_seconds* \
            && "$query" == *required_lawful_basis* \
            && "$query" == *"FROM required WHERE pii_write"* \
            && "$query" == *"WHERE required.pii_write"* \
            && "$query" == *"schedule.terminal_action<>required.required_terminal_action"* \
            && "$query" == *"schedule.trigger_kind IS DISTINCT FROM required.required_trigger_kind"* \
            && "$query" == *"schedule.lawful_basis IS DISTINCT FROM required.required_lawful_basis"* \
            && "$query" == *"LEFT JOIN required USING (record_class)"* \
            && "$query" == *"WHERE required.record_class IS NULL"* \
            && "$query" == *"HAVING count(*)<>1"* \
            && "$query" == *"review_expires_at<=statement_timestamp()"* \
            && "$query" == *"schedule.schedule_digest IS NULL"* \
            && "$query" == *"schedule.schedule_digest !~"* ]] || return 1
          case "$GURINE_TEST_SCHEDULE_RESULT" in
            t|f) printf "%s\n" "$GURINE_TEST_SCHEDULE_RESULT" ;;
            empty|required_class_gap|pii_class_gap|agent_runtime_gap|unknown_extra|required_value_mismatch|terminal_action_mismatch|duplicate|expired|invalid_digest) printf "f\n" ;;
            query_error) return 1 ;;
            *) return 1 ;;
          esac
        elif [[ "$query" == *ops.capability_activation_evidence* ]]; then
          [[ "$query" == *"decision.expires_at>statement_timestamp()"* \
            && "$query" == *"evidence.expires_at>statement_timestamp()"* \
            && "$query" == *"receipt.receipt_kind="* ]] || return 1
          case "$GURINE_TEST_SOURCE_LICENSE_RESULT" in
            t|f) printf "%s\n" "$GURINE_TEST_SOURCE_LICENSE_RESULT" ;;
            query_error) return 1 ;;
            *) return 1 ;;
          esac
        elif [[ "$query" == *ops.privacy_request_access_policies_v1* ]]; then
          case "$GURINE_TEST_PRIVACY_ACCESS_POLICY_RESULT" in
            t|f) printf "%s\n" "$GURINE_TEST_PRIVACY_ACCESS_POLICY_RESULT" ;;
            missing|duplicate|expired|malformed|test_only) printf "f\n" ;;
            query_error) return 1 ;;
            *) return 1 ;;
          esac
        elif [[ "$query" == *ops.assert_r6e_runtime_role_postconditions_v1* ]]; then
          [[ "$query" == *pg_authid* \
            && "$query" == *pg_auth_members* \
            && "$query" == *pg_db_role_setting* \
            && "$query" == *pg_shdepend* \
            && "$query" == *actor.rolsuper* \
            && "$query" == *public._sqlx_migrations* \
            && "$query" == *expected_migration_checksum* ]] || return 1
          case "$GURINE_TEST_R6E_ROLE_RESULT" in
            t|f) printf "%s\n" "$GURINE_TEST_R6E_ROLE_RESULT" ;;
            query_error) return 1 ;;
            *) return 1 ;;
          esac
        else
          return 1
        fi
      }
      source "$1"
    ' bash "$preflight_script"
}

assert_privacy_access_policy_is_closed() {
  local source="$root/infra/scripts/production-preflight.sh"
  local needle
  for needle in \
    "state='APPROVED'" \
    "allowed_operation='getPrivacyRequest'" \
    "bff_issuer='public-web'" \
    privacy-request-receipt-access-policy-v1 \
    privacy-access-policy-binding.v1 \
    'ops.canonical_jsonb_v1(policy.policy_payload)' \
    "policy.same_site<>'LAX'" \
    "policy.authority='TEST_ONLY'" \
    "policy.authority<>'TEST_ONLY'"; do
    grep -Fq "$needle" "$source" || {
      printf 'production preflight privacy access-policy guard omitted: %s\n' \
        "$needle" >&2
      exit 1
    }
  done
}

run_preflight_with_results() {
  run_preflight_mode_with_results TEST_HARNESS "$@"
}

run_production_preflight_with_results() {
  run_preflight_mode_with_results PRODUCTION "$@"
}

expect_preflight_failure_with_results() {
  local expected="$1"
  local schedule_result="$2"
  local source_license_result="$3"
  shift 3
  local output
  if output="$(run_preflight_with_results \
    "$schedule_result" "$source_license_result" "$@" 2>&1)"; then
    printf 'production preflight unexpectedly passed: %s\n' "$expected" >&2
    exit 1
  fi
  [[ "$output" == *"$expected"* ]] || {
    printf 'production preflight failed for the wrong reason: %s\n' "$expected" >&2
    exit 1
  }
}

expect_preflight_failure() {
  local expected="$1"
  shift
  expect_preflight_failure_with_results "$expected" t t "$@"
}

expect_preflight_success() {
  local output
  if ! output="$(run_preflight_with_results t t "$@" 2>&1)"; then
    printf 'production preflight unexpectedly failed\n' >&2
    exit 1
  fi
  [[ "$output" == *"production-preflight: PASS"* ]] || {
    printf 'production preflight omitted PASS result\n' >&2
    exit 1
  }
  [[ "$output" == *"TEST_HARNESS; not production evidence"* ]] || {
    printf 'test harness preflight result could be mistaken for production evidence\n' >&2
    exit 1
  }
}

expect_production_preflight_failure_with_results() {
  local expected="$1"
  local schedule_result="$2"
  local source_license_result="$3"
  shift 3
  local output
  if output="$(run_production_preflight_with_results \
    "$schedule_result" "$source_license_result" "$@" 2>&1)"; then
    printf 'production evidence mode unexpectedly passed: %s\n' "$expected" >&2
    exit 1
  fi
  [[ "$output" == *"$expected"* ]] || {
    printf 'production evidence mode failed for the wrong reason: %s\n' "$expected" >&2
    printf '%s\n' "$output" >&2
    exit 1
  }
}

assert_schedule_catalog_is_runtime_derived() {
  if grep -q 'required_schedule_classes' "$root/infra/scripts/production-preflight.sh"; then
    printf 'production preflight must not duplicate the R6d record-class catalog\n' >&2
    exit 1
  fi
  grep -q 'FROM ops.r6d_record_class_catalog' "$root/infra/scripts/production-preflight.sh" || {
    printf 'production preflight does not derive required schedules from the R6d catalog\n' >&2
    exit 1
  }
  if grep -Eq 'count\(\*\)[[:space:]]*=[[:space:]]*18|count\(\*\)[[:space:]]*<>[[:space:]]*18' \
    "$root/infra/scripts/production-preflight.sh" \
    "$root/db/test-fixtures/r6d-approved-policy-authority.sql"; then
    printf 'R6d schedule authority must not duplicate a numeric class count\n' >&2
    exit 1
  fi
  for record_class in AGENT_RUNTIME_POLICY AGENT_RUNTIME_INITIATION_RECEIPT; do
    grep -q "$record_class" "$root/infra/scripts/production-preflight.sh" || {
      printf 'production preflight omitted agent-runtime schedule authority: %s\n' \
        "$record_class" >&2
      exit 1
    }
  done
}

expect_compose_database_to_block_unready_legal_state() {
  local output
  if output="$(
    (
      local setting
      for setting in "${preflight_env[@]}"; do
        export "$setting"
      done
      export GURINE_ENV=preflight-test
      export GURINE_PREFLIGHT_MODE=TEST_HARNESS
      psql() {
        [[ "$#" -ge 1 ]] || return 2
        shift
        "${compose[@]}" exec -T postgres \
          psql -U gurine_dev -d gurine "$@"
      }
      source "$preflight_script"
    ) 2>&1
  )"; then
    printf 'production preflight accepted an unready Compose legal state\n' >&2
    exit 1
  fi
  [[ "$output" == *"approved record-class schedules are missing, duplicate, expired, or invalid"* ]] || {
    printf 'production preflight Compose database check failed for the wrong reason\n' >&2
    exit 1
  }
}

assert_schedule_catalog_is_runtime_derived
assert_privacy_access_policy_is_closed

expect_production_preflight_failure_with_results \
  "test-only generated legal content is forbidden in production" t t

nested_test_only_legal_content="$preflight_fixture_root/verification/generated-legal-content-nested-test-only.json"
jq 'del(.fixtureAuthority)' "$published_legal_content" > "$nested_test_only_legal_content"
install -m 0644 "$nested_test_only_legal_content" \
  "$preflight_fixture_root/verification/generated-legal-content.json"
expect_production_preflight_failure_with_results \
  "test-only generated legal content is forbidden in production" t t
install -m 0644 "$published_legal_content" \
  "$preflight_fixture_root/verification/generated-legal-content.json"

install -m 0644 "$draft_legal_content" \
  "$preflight_fixture_root/verification/generated-legal-content.json"
expect_preflight_failure \
  "canonical generated legal content is incomplete, malformed, not PUBLISHED, or not bound to required operator fields"
install -m 0644 "$published_legal_content" \
  "$preflight_fixture_root/verification/generated-legal-content.json"

malformed_legal_content="$preflight_fixture_root/verification/generated-legal-content-malformed.json"
jq '.privacy.sections |= .[0:7]' "$published_legal_content" > "$malformed_legal_content"
install -m 0644 "$malformed_legal_content" \
  "$preflight_fixture_root/verification/generated-legal-content.json"
expect_preflight_failure \
  "canonical generated legal content is incomplete, malformed, not PUBLISHED, or not bound to required operator fields"
jq '.privacy.sections[0].unexpected = true' "$published_legal_content" > "$malformed_legal_content"
install -m 0644 "$malformed_legal_content" \
  "$preflight_fixture_root/verification/generated-legal-content.json"
expect_preflight_failure \
  "canonical generated legal content is incomplete, malformed, not PUBLISHED, or not bound to required operator fields"
jq '.terms.sections[0].unexpected = true' "$published_legal_content" > "$malformed_legal_content"
install -m 0644 "$malformed_legal_content" \
  "$preflight_fixture_root/verification/generated-legal-content.json"
expect_preflight_failure \
  "canonical generated legal content is incomplete, malformed, not PUBLISHED, or not bound to required operator fields"
jq '.unexpected = true' "$published_legal_content" > "$malformed_legal_content"
install -m 0644 "$malformed_legal_content" \
  "$preflight_fixture_root/verification/generated-legal-content.json"
expect_preflight_failure \
  "canonical generated legal content is incomplete, malformed, not PUBLISHED, or not bound to required operator fields"
jq '.privacy.sections[0].body |= gsub("fixture-privacy-controller"; "missing-controller-binding")' \
  "$published_legal_content" > "$malformed_legal_content"
install -m 0644 "$malformed_legal_content" \
  "$preflight_fixture_root/verification/generated-legal-content.json"
expect_preflight_failure \
  "canonical generated legal content is incomplete, malformed, not PUBLISHED, or not bound to required operator fields"
install -m 0644 "$published_legal_content" \
  "$preflight_fixture_root/verification/generated-legal-content.json"

for operator_input in \
  GURINE_OPERATING_LEGAL_ENTITY GURINE_PRIVACY_CONTROLLER \
  GURINE_PRIVACY_OFFICER_OR_CPO GURINE_PUBLIC_LEGAL_AND_PRIVACY_CONTACT; do
  expect_preflight_failure "$operator_input is required" "$operator_input="
done
expect_preflight_failure \
  "GURINE_PRIVACY_CONTROLLER must be a non-blank value between 2 and 512 characters" \
  "GURINE_PRIVACY_CONTROLLER=   "
expect_preflight_failure \
  "ROLE_PROVISIONER_DATABASE_URL must authenticate as ROLE_PROVISIONER_EXPECTED_ACTOR" \
  ROLE_PROVISIONER_DATABASE_URL=postgresql://wrong_actor:secret@postgres/gurine
expect_preflight_failure \
  "ROLE_PROVISIONER_DATABASE_URL must be separate from runtime and migrator URLs" \
  ROLE_PROVISIONER_DATABASE_URL=postgresql://cluster_admin:secret@postgres/gurine \
  MIGRATOR_DATABASE_URL=postgresql://cluster_admin:secret@postgres/gurine
expect_preflight_failure \
  "ROLE_PROVISIONER_EXPECTED_ACTOR is forbidden in runtime and migrator URLs" \
  MIGRATOR_DATABASE_URL=postgresql://cluster_admin:different@postgres/gurine
expect_preflight_failure \
  "BILLING_DATABASE_URL must authenticate as gurine_billing_gateway" \
  BILLING_DATABASE_URL=postgresql://control:secret@postgres/gurine
expect_preflight_failure \
  "ECONOMICS_DATABASE_URL must authenticate as gurine_economics_importer when configured" \
  ECONOMICS_DATABASE_URL=postgresql://workflow:secret@postgres/gurine
expect_preflight_failure \
  "BILLING_GATEWAY_MODE must be DISABLED for production preflight" \
  BILLING_GATEWAY_MODE=TEST_ONLY
expect_preflight_failure \
  "DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN is forbidden outside test mode" \
  DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN=fixture-payment-token
expect_preflight_failure \
  "DONATION_TEST_PAYMENT_OUTCOME is forbidden outside test mode" \
  DONATION_TEST_PAYMENT_OUTCOME=SUCCEEDED
for fixture_name in \
  PAYMENT_FIXTURE_BILLING_HMAC_KEY_CURRENT \
  PAYMENT_FIXTURE_BILLING_HMAC_KEY_PREVIOUS \
  PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_CURRENT \
  PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_CURRENT_VERSION \
  PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_PREVIOUS \
  PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_PREVIOUS_VERSION \
  PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_CURRENT \
  PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_CURRENT_VERSION \
  PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_PREVIOUS \
  PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_PREVIOUS_VERSION; do
  expect_preflight_failure \
    "$fixture_name is forbidden outside test mode" \
    "$fixture_name=fixture-value"
done
expect_preflight_failure \
  "PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT is not valid base64" \
  PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT=not-base64

expect_preflight_failure \
  "GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH is required" \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH=
expect_preflight_failure \
  "GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_SHA256 does not match" \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_SHA256="$(printf '0%.0s' {1..64})"
expect_preflight_failure \
  "GURINE_LAW_ENFORCEMENT_WORKFLOW_RECEIPT_PATH is required" \
  GURINE_LAW_ENFORCEMENT_WORKFLOW_RECEIPT_PATH=
expect_preflight_failure \
  "GURINE_LAW_ENFORCEMENT_WORKFLOW_RECEIPT_SHA256 does not match" \
  GURINE_LAW_ENFORCEMENT_WORKFLOW_RECEIPT_SHA256="$(printf '0%.0s' {1..64})"

malformed_receipt="$preflight_fixture_root/external-counsel-review-malformed.receipt"
jq '.unexpected = true' "$counsel_receipt" > "$malformed_receipt"
malformed_receipt_sha="$(sha256sum "$malformed_receipt" | awk '{print $1}')"
expect_preflight_failure \
  "GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH is not a current closed versioned review receipt" \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH="$malformed_receipt" \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_SHA256="$malformed_receipt_sha"
jq '.timestamps.expiresAt = "2000-01-01T00:00:00Z"' \
  "$counsel_receipt" > "$malformed_receipt"
malformed_receipt_sha="$(sha256sum "$malformed_receipt" | awk '{print $1}')"
expect_preflight_failure \
  "GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH is not a current closed versioned review receipt" \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH="$malformed_receipt" \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_SHA256="$malformed_receipt_sha"
jq '.attestation.statement = ""' "$counsel_receipt" > "$malformed_receipt"
malformed_receipt_sha="$(sha256sum "$malformed_receipt" | awk '{print $1}')"
expect_preflight_failure \
  "GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH is not a current closed versioned review receipt" \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH="$malformed_receipt" \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_SHA256="$malformed_receipt_sha"
jq '.scope.subjectSha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$counsel_receipt" > "$malformed_receipt"
malformed_receipt_sha="$(sha256sum "$malformed_receipt" | awk '{print $1}')"
expect_preflight_failure \
  "GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH does not bind the canonical subject digest" \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH="$malformed_receipt" \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_SHA256="$malformed_receipt_sha"

production_like_legal_content="$preflight_fixture_root/verification/generated-legal-content-production-like.json"
jq '
  del(.fixtureAuthority)
  | walk(if type == "string" then
      gsub("TEST_ONLY "; "")
      | gsub("fixture-operator-entity"; "운영법인")
      | gsub("fixture-privacy-controller"; "개인정보처리자")
      | gsub("fixture-privacy-office"; "개인정보보호부서")
      | gsub("fixture-privacy-contact"; "privacy@example.invalid")
    else . end)
' "$published_legal_content" > "$production_like_legal_content"
install -m 0644 "$production_like_legal_content" \
  "$preflight_fixture_root/verification/generated-legal-content.json"
production_legal_sha="$(sha256sum "$production_like_legal_content" | awk '{print $1}')"
production_like_counsel_receipt="$preflight_fixture_root/external-counsel-review-production-like.receipt"
jq \
  --arg subject_sha "$production_legal_sha" '
  del(.fixtureAuthority)
  | .issuer.name = "외부 법률 검토자"
  | .issuer.credentialId = "KR-COUNSEL-CREDENTIAL"
  | .scope.subjectSha256 = $subject_sha
  | .attestation.statement = "대한민국 법률 출시 검토 범위와 산출물을 확인하고 운영 배포를 승인함"
' "$counsel_receipt" > "$production_like_counsel_receipt"
production_like_counsel_sha="$(sha256sum "$production_like_counsel_receipt" | awk '{print $1}')"
production_like_workflow_receipt="$preflight_fixture_root/law-enforcement-workflow-production-like.receipt"
jq '
  del(.fixtureAuthority)
  | .issuer.name = "수사기관 대응 절차 검토자"
  | .issuer.credentialId = "KR-PROCEDURE-CREDENTIAL"
  | .attestation.statement = "대한민국 수사기관 요청 대응 절차와 제한 범위를 확인하고 운영 배포를 승인함"
' "$workflow_receipt" > "$production_like_workflow_receipt"
production_like_workflow_sha="$(sha256sum "$production_like_workflow_receipt" | awk '{print $1}')"
expect_production_preflight_failure_with_results \
  "GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH contains test-only or fixture provenance" t t \
  GURINE_OPERATING_LEGAL_ENTITY=운영법인 \
  GURINE_PRIVACY_CONTROLLER=개인정보처리자 \
  GURINE_PRIVACY_OFFICER_OR_CPO=개인정보보호부서 \
  GURINE_PUBLIC_LEGAL_AND_PRIVACY_CONTACT=privacy@example.invalid
expect_production_preflight_failure_with_results \
  "GURINE_LAW_ENFORCEMENT_WORKFLOW_RECEIPT_PATH contains test-only or fixture provenance" t t \
  GURINE_OPERATING_LEGAL_ENTITY=운영법인 \
  GURINE_PRIVACY_CONTROLLER=개인정보처리자 \
  GURINE_PRIVACY_OFFICER_OR_CPO=개인정보보호부서 \
  GURINE_PUBLIC_LEGAL_AND_PRIVACY_CONTACT=privacy@example.invalid \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH="$production_like_counsel_receipt" \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_SHA256="$production_like_counsel_sha"
expect_production_preflight_failure_with_results \
  "current approved privacy request access policy is missing, duplicate, expired, malformed, or test-only" t t \
  GURINE_OPERATING_LEGAL_ENTITY=운영법인 \
  GURINE_PRIVACY_CONTROLLER=개인정보처리자 \
  GURINE_PRIVACY_OFFICER_OR_CPO=개인정보보호부서 \
  GURINE_PUBLIC_LEGAL_AND_PRIVACY_CONTACT=privacy@example.invalid \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH="$production_like_counsel_receipt" \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_SHA256="$production_like_counsel_sha" \
  GURINE_LAW_ENFORCEMENT_WORKFLOW_RECEIPT_PATH="$production_like_workflow_receipt" \
  GURINE_LAW_ENFORCEMENT_WORKFLOW_RECEIPT_SHA256="$production_like_workflow_sha" \
  GURINE_TEST_PRIVACY_ACCESS_POLICY_RESULT=test_only
install -m 0644 "$published_legal_content" \
  "$preflight_fixture_root/verification/generated-legal-content.json"

expect_preflight_failure \
  "GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_PATH is required" \
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_PATH=
expect_preflight_failure \
  "GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_SHA256 does not match" \
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_SHA256="$(printf '0%.0s' {1..64})"
expect_preflight_failure \
  "source-license capability bindings are malformed" \
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_PATH="$counsel_receipt" \
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_SHA256="$counsel_sha"
expect_preflight_failure \
  "source-license capability bindings are malformed or do not exactly match enabled connectors" \
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_PATH="$open_dart_bindings" \
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_SHA256="$open_dart_bindings_sha"

expect_preflight_failure "psql is required" GURINE_TEST_PSQL_AVAILABLE=false
expect_preflight_failure_with_results \
  "R6e runtime-role catalog query failed" t t \
  GURINE_TEST_R6E_ROLE_RESULT=query_error
expect_preflight_failure_with_results \
  "R6e runtime-role contract or migration row 41 is invalid" t t \
  GURINE_TEST_R6E_ROLE_RESULT=f
expect_preflight_failure_with_results \
  "deployment database approved record-class schedule query failed" query_error t
for schedule_failure in \
  empty required_class_gap pii_class_gap agent_runtime_gap unknown_extra \
  required_value_mismatch terminal_action_mismatch duplicate expired invalid_digest; do
  expect_preflight_failure_with_results \
    "approved record-class schedules are missing, duplicate, expired, or invalid" \
    "$schedule_failure" t
done
expect_preflight_failure \
  "deployment database privacy request access-policy query failed" \
  GURINE_TEST_PRIVACY_ACCESS_POLICY_RESULT=query_error
for privacy_policy_failure in missing duplicate expired malformed test_only; do
  expect_preflight_failure \
    "current approved privacy request access policy is missing, duplicate, expired, malformed, or test-only" \
    "GURINE_TEST_PRIVACY_ACCESS_POLICY_RESULT=$privacy_policy_failure"
done

open_dart_env=(
  SOURCE_OPEN_DART_ENABLED=true
  OPEN_DART_API_KEY=fixture-open-dart-key
  OPEN_DART_API_BASE_URL=https://opendart.example.test
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_PATH="$open_dart_bindings"
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_SHA256="$open_dart_bindings_sha"
)
expect_preflight_failure_with_results \
  "deployment database source-license readiness query failed" \
  t query_error "${open_dart_env[@]}"
expect_preflight_failure_with_results \
  "an enabled connector lacks current production source-license evidence" \
  t f "${open_dart_env[@]}"
expect_preflight_success "${open_dart_env[@]}"
expect_preflight_success \
  ECONOMICS_DATABASE_URL=postgresql://gurine_economics_importer:secret@postgres/gurine
expect_preflight_success

printf 'production rejection and TEST_HARNESS structural preflight gates: PASS\n'
if [[ "$preflight_only" == "true" ]]; then
  exit 0
fi

"${compose[@]}" up --detach --wait --wait-timeout 300
[[ "$("${compose[@]}" config --services | wc -l)" -eq 22 ]]
expect_compose_database_to_block_unready_legal_state

application_services=(
  role-provisioner migrator public-api control-api identity-api billing-gateway submission-api ingest-worker analysis-worker
  projection-worker notification-worker workflow-worker document-extractor scheduler egress-gateway
  oidc-test-provider public-web review-console response-portal
)

for service in "${application_services[@]}"; do
  container_id="$("${compose[@]}" ps --all --quiet "$service")"
  [[ -n "$container_id" ]] || { printf 'container missing: %s\n' "$service" >&2; exit 1; }
  user="$(docker inspect --format '{{.Config.User}}' "$container_id")"
  [[ "$user" != "" && "$user" != "0" && "$user" != "root" ]] || {
    printf 'root container forbidden: %s\n' "$service" >&2
    exit 1
  }
done

for service in public-api control-api identity-api billing-gateway submission-api ingest-worker analysis-worker \
  projection-worker notification-worker workflow-worker document-extractor scheduler egress-gateway \
  public-web review-console response-portal; do
  container_id="$("${compose[@]}" ps --quiet "$service")"
  [[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$container_id")" == "true" ]]
done

role_provisioner_id="$("${compose[@]}" ps --all --quiet role-provisioner)"
[[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$role_provisioner_id")" == "true" ]]
[[ "$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$role_provisioner_id")" == "no" ]]
[[ -z "$(docker inspect --format '{{range .Mounts}}{{if .RW}}{{.Destination}}{{end}}{{end}}' \
  "$role_provisioner_id")" ]]

for service in "${application_services[@]}"; do
  container_id="$("${compose[@]}" ps --all --quiet "$service")"
  security_opts="$(docker inspect --format '{{join .HostConfig.SecurityOpt ","}}' "$container_id")"
  cap_drop="$(docker inspect --format '{{join .HostConfig.CapDrop ","}}' "$container_id")"
  [[ ",$security_opts," == *,no-new-privileges:true,* ]]
  [[ ",$cap_drop," == *,ALL,* ]]
  [[ "$(docker inspect --format '{{.HostConfig.PidsLimit}}' "$container_id")" == "256" ]]
  [[ "$(docker inspect --format '{{.HostConfig.Init}}' "$container_id")" == "true" ]]
done

data_network="${project}_data"
internal_network="${project}_internal"
[[ "$(docker network inspect --format '{{.Internal}}' "$data_network")" == "true" ]]
[[ "$(docker network inspect --format '{{.Internal}}' "$internal_network")" == "true" ]]

marker="verify-$BASHPID"
"${compose[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U gurine_dev -d gurine -c \
  "INSERT INTO ops.kill_switches(code,scope,state,reason,version) VALUES('$marker',jsonb_build_object('marker','$marker'),'INACTIVE','restart persistence',1);" >/dev/null
"${compose[@]}" exec -T submission-api sh -c "printf '%s' '$marker' > /var/lib/gurine-objects/restart-marker"

invite_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
"${compose[@]}" exec -T postgres psql -v ON_ERROR_STOP=1 -U gurine_dev -d gurine -c \
  "INSERT INTO ops.users(id,oidc_subject,email,display_name,status) VALUES('$invite_id','verify-$invite_id','verify-$invite_id@gurine.test','Runtime Verify','INVITED'); SELECT ops.enqueue_outbox('user','$invite_id',1,'notification.user_invitation_requested.v1',jsonb_build_object('actor_id','$invite_id','occurred_at',clock_timestamp(),'operation_id','inviteUser','request_id',gen_random_uuid()::text),clock_timestamp());" >/dev/null

for _ in $(seq 1 60); do
  if "${compose[@]}" exec -T notification-worker sh -c 'find /var/lib/gurine-mail -type f -name "*.json" -print -quit | grep -q .' >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
mail_file="$("${compose[@]}" exec -T notification-worker sh -c 'find /var/lib/gurine-mail -type f -name "*.json" -print -quit')"
[[ -n "$mail_file" ]]

"${compose[@]}" up --detach --force-recreate --wait --wait-timeout 300 \
  public-api control-api identity-api billing-gateway submission-api ingest-worker analysis-worker projection-worker \
  notification-worker workflow-worker document-extractor scheduler egress-gateway public-web review-console response-portal

"${compose[@]}" exec -T postgres psql -At -U gurine_dev -d gurine -c \
  "SELECT count(*) FROM ops.kill_switches WHERE scope->>'marker'='$marker';" | grep -qx '1'
"${compose[@]}" exec -T submission-api sh -c "test \"\$(cat /var/lib/gurine-objects/restart-marker)\" = '$marker'"
"${compose[@]}" exec -T notification-worker sh -c "test -f '$mail_file'"

for service in public-api control-api identity-api billing-gateway submission-api; do
  container_id="$("${compose[@]}" ps --quiet "$service")"
  "${compose[@]}" kill --signal SIGTERM "$service" >/dev/null
  for _ in $(seq 1 60); do
    if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" == "false" ]]; then
      break
    fi
    sleep 0.5
  done
  [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" == "false" ]]
  "${compose[@]}" up --detach --no-deps --wait --wait-timeout 120 "$service" >/dev/null
done

printf '22-service non-root/read-only/no-new-privileges/cap-drop/network/restart/volume/SIGTERM production stack: PASS\n'
