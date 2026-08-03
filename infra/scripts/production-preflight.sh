#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  printf 'production-preflight: FAIL: %s\n' "$1" >&2
  exit 1
}

preflight_mode="${GURINE_PREFLIGHT_MODE:-PRODUCTION}"
case "$preflight_mode" in
  PRODUCTION)
    [[ "${GURINE_ENV:-}" == "production" ]] ||
      fail "GURINE_ENV must be production"
    ;;
  TEST_HARNESS)
    [[ "${GURINE_ENV:-}" == "preflight-test" ]] ||
      fail "TEST_HARNESS requires GURINE_ENV=preflight-test"
    ;;
  *) fail "GURINE_PREFLIGHT_MODE must be PRODUCTION or TEST_HARNESS" ;;
esac

required() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || fail "$name is required"
  if [[ "$value" =~ (REPLACE|LOCAL_ONLY|development-only|gurine_dev_only|changeme|password123) ]]; then
    fail "$name contains a forbidden development or replacement marker"
  fi
}

required_operator_input() {
  local name="$1"
  local value
  required "$name"
  value="${!name}"
  [[ "${#value}" -ge 2 && "${#value}" -le 512 && "$value" =~ [^[:space:]] ]] ||
    fail "$name must be a non-blank value between 2 and 512 characters"
  if printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "$name must not contain control characters"
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

required_file_digest() {
  local path_name="$1"
  local digest_name="$2"
  local path
  local expected_digest
  local actual_digest

  required "$path_name"
  required "$digest_name"
  path="${!path_name}"
  expected_digest="${!digest_name}"
  [[ "$path" == /* ]] || fail "$path_name must be an absolute path"
  [[ -f "$path" && -s "$path" ]] || fail "$path_name must name a non-empty regular file"
  [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || fail "$digest_name must be a lowercase SHA-256"
  actual_digest="$(sha256sum -- "$path" | awk '{print $1}')" ||
    fail "$path_name could not be hashed"
  [[ "$actual_digest" == "$expected_digest" ]] || fail "$digest_name does not match $path_name"
}

reject_forbidden_deployment_markers() {
  local path_name="$1"
  local path="${!path_name}"
  if LC_ALL=C grep -Eaqi \
    '(REPLACE|LOCAL_ONLY|development-only|gurine_dev_only|changeme|password123)' "$path"; then
    fail "$path_name contains a forbidden development or replacement marker"
  fi
}

validate_generated_legal_content() {
  local content_path="$root/verification/generated-legal-content.json"
  [[ -f "$content_path" && -s "$content_path" ]] ||
    fail "canonical generated legal content is missing"

  if [[ "$preflight_mode" == "PRODUCTION" ]] &&
    jq -e '
      [.. | strings | select(test(
        "TEST[-_ ]ONLY|FIXTURE|LOCAL_ONLY|development-only|gurine_dev_only|changeme|password123|synthetic-test";
        "i"
      ))] | length > 0
    ' "$content_path" >/dev/null 2>&1; then
    fail "test-only generated legal content is forbidden in production"
  fi

  jq -e \
    --arg mode "$preflight_mode" \
    --arg operating "$GURINE_OPERATING_LEGAL_ENTITY" \
    --arg controller "$GURINE_PRIVACY_CONTROLLER" \
    --arg officer "$GURINE_PRIVACY_OFFICER_OR_CPO" \
    --arg contact "$GURINE_PUBLIC_LEGAL_AND_PRIVACY_CONTACT" '
    def section_shape:
      type == "object"
      and (keys == ["body", "heading", "id"])
      and (.id | type == "string" and length > 0)
      and (.heading | type == "string" and length > 0)
      and (.body | type == "string" and test("[^[:space:]]") and test("^[^[:cntrl:]]+$"));
    def document_shape($ids; $headings):
      type == "object"
      and (keys == ["sections", "status"])
      and .status == "PUBLISHED"
      and (.sections | type == "array" and length == ($ids | length))
      and all(.sections[]; section_shape)
      and ([.sections[].id] == $ids)
      and ([.sections[].heading] == $headings);
    def body_text: [.sections[].body] | join("\n");
    type == "object"
    and (
      if $mode == "TEST_HARNESS" then
        keys == ["fixtureAuthority", "privacy", "terms"]
        and .fixtureAuthority == "TEST_ONLY"
      else
        keys == ["privacy", "terms"]
      end
    )
    and (.privacy | document_shape(
      ["controller", "categories", "purposes", "retention", "processors", "rights", "security", "history"];
      ["처리자", "정보 범주", "목적·법적 근거", "보존", "처리위탁·국외", "권리", "보호", "변경 이력"]
    ))
    and (.terms | document_shape(
      ["service", "content", "data", "prohibited", "liability", "changes"];
      ["서비스 조건", "콘텐츠", "데이터·공개 인터페이스", "금지", "책임·한계", "변경"]
    ))
    and ((.privacy | body_text) as $privacy
      | ($privacy | contains($operating))
      and ($privacy | contains($controller))
      and ($privacy | contains($officer))
      and ($privacy | contains($contact)))
    and ((.terms | body_text) as $terms
      | ($terms | contains($operating))
      and ($terms | contains($contact))
      and ($terms | contains("재배포물에 원 자료의 공개·검토·정정 상태를 유지해야 합니다."))
      and ($terms | contains("재배포물에 \"이상 징후 기록이며 위법·부패의 확정이 아님\" 고지를 유지해야 합니다."))
      and ($terms | contains("정정·철회가 게시되면 재배포물에도 해당 표시를 반영하거나 최신 revision으로 연결해야 합니다.")))
  ' "$content_path" >/dev/null ||
    fail "canonical generated legal content is incomplete, malformed, not PUBLISHED, or not bound to required operator fields"
}

validate_review_receipt() {
  local path_name="$1"
  local digest_name="$2"
  local schema_version="$3"
  local scope_kind="$4"
  local document_version="$5"
  local expected_artifacts_json="$6"
  local expected_decision="$7"
  local subject_path="$8"
  local path="${!path_name}"
  local subject_digest

  required_file_digest "$path_name" "$digest_name"
  [[ -f "$subject_path" && -s "$subject_path" ]] ||
    fail "$path_name canonical subject is missing"
  subject_digest="$(sha256sum -- "$subject_path" | awk '{print $1}')" ||
    fail "$path_name canonical subject could not be hashed"

  if [[ "$preflight_mode" == "PRODUCTION" ]] &&
    jq -e '[.. | strings | select(test("TEST[-_ ]ONLY|FIXTURE|LOCAL_ONLY|development-only|gurine_dev_only|changeme|password123|synthetic-test"; "i"))] | length > 0' \
      "$path" >/dev/null 2>&1; then
    fail "$path_name contains test-only or fixture provenance"
  fi

  jq -e \
    --arg mode "$preflight_mode" \
    --arg schema "$schema_version" \
    --arg scope_kind "$scope_kind" \
    --arg document_version "$document_version" \
    --argjson artifacts "$expected_artifacts_json" \
    --arg decision "$expected_decision" '
    type == "object"
    and (
      if $mode == "TEST_HARNESS" then
        keys == ["attestation", "fixtureAuthority", "issuer", "schemaVersion", "scope", "timestamps"]
        and .fixtureAuthority == "TEST_ONLY"
      else
        keys == ["attestation", "issuer", "schemaVersion", "scope", "timestamps"]
      end
    )
    and .schemaVersion == $schema
    and (.issuer | type == "object"
      and keys == ["credentialId", "jurisdiction", "name"]
      and (.name | type == "string" and length >= 2 and length <= 512
        and test("[^[:space:]]") and test("^[^[:cntrl:]]+$"))
      and (.credentialId | type == "string" and length >= 2 and length <= 512
        and test("[^[:space:]]") and test("^[^[:cntrl:]]+$"))
      and .jurisdiction == "KR")
    and (.scope | type == "object"
      and keys == ["artifactIds", "documentVersion", "environment", "kind", "subjectSha256"]
      and .kind == $scope_kind
      and .documentVersion == $document_version
      and .environment == "PRODUCTION"
      and .artifactIds == $artifacts
      and (.subjectSha256 | type == "string" and test("^[0-9a-f]{64}$")))
    and (.timestamps | type == "object"
      and keys == ["expiresAt", "issuedAt", "validFrom"]
      and all(.[]; type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
      and ((.issuedAt | fromdateiso8601) <= now)
      and ((.issuedAt | fromdateiso8601) <= (.validFrom | fromdateiso8601))
      and ((.validFrom | fromdateiso8601) <= now)
      and ((.expiresAt | fromdateiso8601) > now))
    and (.attestation | type == "object"
      and keys == ["decision", "statement"]
      and .decision == $decision
      and (.statement | type == "string" and length >= 20 and length <= 4096
        and test("[^[:space:]]") and test("^[^[:cntrl:]]+$")))
  ' "$path" >/dev/null ||
    fail "$path_name is not a current closed versioned review receipt"

  [[ "$(jq -r '.scope.subjectSha256' "$path")" == "$subject_digest" ]] ||
    fail "$path_name does not bind the canonical subject digest"
}

validate_approved_record_class_schedules() {
  local result
  if ! result="$(psql "$MIGRATOR_DATABASE_URL" --no-password -X -qAt \
    -v ON_ERROR_STOP=1 2>/dev/null <<'SQL'
WITH r6d_required AS MATERIALIZED (
  SELECT record_class,required_terminal_action,pii_write,
    required_trigger_kind,required_active_duration_seconds,
    required_backup_duration_seconds,required_lawful_basis
  FROM ops.r6d_record_class_catalog
  WHERE authority_version='supervisor-decision-v1'
), agent_runtime_required(
  record_class,required_terminal_action,pii_write,
  required_trigger_kind,required_active_duration_seconds,
  required_backup_duration_seconds,required_lawful_basis
) AS MATERIALIZED (
  VALUES
    ('AGENT_RUNTIME_POLICY'::text,'DELETE'::text,false,
      NULL::text,NULL::bigint,NULL::bigint,NULL::text),
    ('AGENT_RUNTIME_INITIATION_RECEIPT'::text,'DELETE'::text,false,
      NULL::text,NULL::bigint,NULL::bigint,NULL::text)
), required AS MATERIALIZED (
  SELECT * FROM r6d_required
  UNION ALL
  SELECT * FROM agent_runtime_required
), schedules AS MATERIALIZED (
  SELECT record_class,revision,purpose,lawful_basis,trigger_kind,
    active_duration_seconds,backup_duration_seconds,terminal_action,
    effective_at,review_expires_at,schedule_digest::text AS schedule_digest
  FROM public.approved_record_class_schedules
)
SELECT (SELECT count(*) FROM schedules)>0
  AND (SELECT count(*) FROM required)>0
  AND (SELECT count(*) FROM required WHERE pii_write)>0
  AND NOT EXISTS (
    SELECT record_class
    FROM required
    GROUP BY record_class
    HAVING count(*)<>1
  )
  AND NOT EXISTS (
    SELECT schedule.record_class
    FROM schedules AS schedule
    GROUP BY schedule.record_class
    HAVING count(*)<>1
  )
  AND NOT EXISTS (
    SELECT 1
    FROM schedules AS schedule
    WHERE schedule.record_class IS NULL
      OR schedule.revision IS NULL
      OR schedule.revision<=0
      OR schedule.effective_at IS NULL
      OR schedule.effective_at>statement_timestamp()
      OR schedule.review_expires_at IS NULL
      OR schedule.review_expires_at<=statement_timestamp()
      OR schedule.schedule_digest IS NULL
      OR schedule.schedule_digest !~ '^[0-9a-f]{64}$'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM required
    LEFT JOIN schedules AS schedule USING (record_class)
    WHERE schedule.record_class IS NULL
      OR schedule.terminal_action<>required.required_terminal_action
      OR (required.required_trigger_kind IS NOT NULL
        AND schedule.trigger_kind IS DISTINCT FROM required.required_trigger_kind)
      OR (required.required_active_duration_seconds IS NOT NULL
        AND schedule.active_duration_seconds IS DISTINCT FROM
          required.required_active_duration_seconds)
      OR (required.required_backup_duration_seconds IS NOT NULL
        AND schedule.backup_duration_seconds IS DISTINCT FROM
          required.required_backup_duration_seconds)
      OR (required.required_lawful_basis IS NOT NULL
        AND schedule.lawful_basis IS DISTINCT FROM required.required_lawful_basis)
  )
  AND NOT EXISTS (
    SELECT 1
    FROM schedules
    LEFT JOIN required USING (record_class)
    WHERE required.record_class IS NULL
  )
  AND NOT EXISTS (
    SELECT 1
    FROM required
    LEFT JOIN schedules AS schedule USING (record_class)
    WHERE required.pii_write
      AND schedule.record_class IS NULL
  );
SQL
  )"; then
    fail "deployment database approved record-class schedule query failed"
  fi
  [[ "$result" == "t" ]] ||
    fail "approved record-class schedules are missing, duplicate, expired, or invalid"
}

validate_privacy_request_access_policy() {
  local result
  if ! result="$(psql "$MIGRATOR_DATABASE_URL" --no-password -X -qAt \
    -v ON_ERROR_STOP=1 -v preflight_mode="$preflight_mode" 2>/dev/null <<'SQL'
WITH current_policy AS MATERIALIZED (
  SELECT policy_id,revision,state,authority,policy_version,allowed_operation,
    bff_issuer,cookie_profile_id,cookie_name,cookie_path,same_site,secure,
    http_only,token_ttl_seconds,read_only_session_ttl_seconds,
    policy_payload,policy_canonical,policy_digest::text AS policy_digest,
    binding_digest::text AS binding_digest,effective_at,review_expires_at
  FROM ops.privacy_request_access_policies_v1
  WHERE state='APPROVED'
    AND allowed_operation='getPrivacyRequest'
    AND bff_issuer='public-web'
    AND effective_at<=statement_timestamp()
    AND review_expires_at>statement_timestamp()
)
SELECT (SELECT count(*) FROM current_policy)=1
  AND NOT EXISTS (
    SELECT 1
    FROM current_policy AS policy
    WHERE policy.cookie_profile_id<>'privacy_request_receipt'
      OR policy.cookie_name<>'gurine_privacy_request_receipt_session'
      OR policy.cookie_path<>'/privacy'
      OR policy.same_site<>'LAX'
      OR NOT policy.secure
      OR NOT policy.http_only
      OR policy.token_ttl_seconds<=0
      OR policy.read_only_session_ttl_seconds<=0
      OR policy.policy_payload IS DISTINCT FROM jsonb_build_object(
        'schemaVersion','privacy-request-receipt-access-policy-v1',
        'tokenTtlSeconds',policy.token_ttl_seconds,
        'readOnlySessionTtlSeconds',policy.read_only_session_ttl_seconds,
        'cookieProfileId',policy.cookie_profile_id,
        'cookieName',policy.cookie_name,
        'cookiePath',policy.cookie_path,
        'allowedOperations',jsonb_build_array(policy.allowed_operation)
      )
      OR policy.policy_canonical IS DISTINCT FROM
        ops.canonical_jsonb_v1(policy.policy_payload)
      OR policy.policy_digest IS DISTINCT FROM encode(
        extensions.digest(policy.policy_canonical,'sha256'),'hex'
      )
      OR policy.binding_digest IS DISTINCT FROM encode(
        extensions.digest(ops.canonical_jsonb_v1(jsonb_build_object(
          'schemaVersion','privacy-access-policy-binding.v1',
          'policyId',policy.policy_id,
          'revision',policy.revision,
          'state',policy.state,
          'authority',policy.authority,
          'policyVersion',policy.policy_version,
          'policyDigest',policy.policy_digest,
          'bffIssuer',policy.bff_issuer,
          'sameSite',policy.same_site,
          'secure',policy.secure,
          'httpOnly',policy.http_only,
          'effectiveAt',policy.effective_at,
          'reviewExpiresAt',policy.review_expires_at
        )),'sha256'),'hex'
      )
      OR (:'preflight_mode'='PRODUCTION' AND policy.authority='TEST_ONLY')
      OR (:'preflight_mode'='TEST_HARNESS' AND policy.authority<>'TEST_ONLY')
  );
SQL
  )"; then
    fail "deployment database privacy request access-policy query failed"
  fi
  [[ "$result" == "t" ]] ||
    fail "current approved privacy request access policy is missing, duplicate, expired, malformed, or test-only"
}

enabled_connector_json() {
  local lines=""
  local connector
  for connector in "$@"; do
    lines+="$connector"$'\n'
  done
  jq -Rsc 'split("\n") | map(select(length > 0))' <<< "$lines"
}

validate_source_license_bindings() {
  local path="$GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_PATH"
  local enabled_json="$1"
  jq -e --argjson enabled "$enabled_json" '
    type == "object"
    and (keys == ["bindings", "schemaVersion"])
    and .schemaVersion == "source-license-capability-bindings.v1"
    and (.bindings | type == "array")
    and all(.bindings[];
      type == "object"
      and (keys == ["capabilityId", "connectorId", "scopeId"])
      and (.connectorId | type == "string" and test("^[a-z][a-z0-9-]{1,127}$"))
      and (.capabilityId | type == "string" and test("^[a-z][a-z0-9_.-]{2,127}$"))
      and (.scopeId | type == "string" and length >= 1 and length <= 512)
      and (.scopeId | test("^[^[:cntrl:]]+$")))
    and (([.bindings[].connectorId] | length) == ([.bindings[].connectorId] | unique | length))
    and (([.bindings[].connectorId] | sort) == ($enabled | sort))
  ' "$path" >/dev/null ||
    fail "source-license capability bindings are malformed or do not exactly match enabled connectors"
}

validate_source_license_evidence() {
  local bindings_json
  local result
  bindings_json="$(jq -c '.bindings' "$GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_PATH")" ||
    fail "source-license capability bindings could not be encoded"
  if ! result="$(psql "$MIGRATOR_DATABASE_URL" --no-password -X -qAt \
    -v ON_ERROR_STOP=1 -v bindings_json="$bindings_json" 2>/dev/null <<'SQL'
WITH expected AS (
  SELECT binding->>'connectorId' AS connector_id,
    binding->>'capabilityId' AS capability_id,
    binding->>'scopeId' AS scope_id
  FROM jsonb_array_elements(:'bindings_json'::jsonb) AS binding
), current_decisions AS (
  SELECT DISTINCT ON (decision.capability_id,decision.environment) decision.*
  FROM ops.capability_activation_decisions AS decision
  WHERE decision.environment='PRODUCTION'
    AND decision.effective_at<=statement_timestamp()
    AND (decision.expires_at IS NULL OR decision.expires_at>statement_timestamp())
  ORDER BY decision.capability_id,decision.environment,
    decision.decision_version DESC,decision.id DESC
), satisfied AS (
  SELECT expected.connector_id
  FROM expected
  JOIN current_decisions AS decision
    ON decision.capability_id=expected.capability_id
   AND decision.scope_type='SOURCE'
   AND decision.scope_id=expected.scope_id
   AND decision.capability_class IN (
     'SOURCE_ACCESS','SOURCE_STORAGE','SOURCE_REDISTRIBUTION'
   )
   AND decision.legal_state='APPROVED'
   AND decision.operational_state='ACTIVE'
   AND decision.effective_at<=statement_timestamp()
   AND (decision.expires_at IS NULL OR decision.expires_at>statement_timestamp())
  JOIN ops.execution_receipts AS receipt
    ON receipt.id=decision.execution_receipt_id
   AND receipt.execution_id=decision.execution_id
   AND receipt.generation=decision.execution_generation
   AND receipt.receipt_digest=decision.execution_receipt_digest
   AND receipt.receipt_kind='EFFECT_SUCCEEDED'
   AND receipt.aggregate_state='SUCCEEDED'
   AND receipt.mutates_aggregate_state
  WHERE (SELECT count(*)
         FROM ops.capability_activation_evidence AS evidence
         WHERE evidence.decision_id=decision.id
           AND evidence.evidence_kind='SOURCE_LICENSE')=1
    AND EXISTS (
      SELECT 1
      FROM ops.capability_activation_evidence AS evidence
      WHERE evidence.decision_id=decision.id
        AND evidence.evidence_kind='SOURCE_LICENSE'
        AND evidence.applicability='APPLICABLE'
        AND evidence.evidence_state='SATISFIED'
        AND evidence.proof_tier='PRODUCTION_LEGAL'
        AND evidence.valid_from<=statement_timestamp()
        AND (evidence.expires_at IS NULL OR evidence.expires_at>statement_timestamp())
    )
)
SELECT (SELECT count(*) FROM expected)=(SELECT count(*) FROM satisfied);
SQL
  )"; then
    fail "deployment database source-license readiness query failed"
  fi
  [[ "$result" == "t" ]] ||
    fail "an enabled connector lacks current production source-license evidence"
}

database_url_uses_actor() {
  local database_url="$1"
  local actor="$2"
  [[ "$database_url" =~ ^postgres(ql)?://${actor}([:@/?#]) ]]
}

validate_role_provisioner_separation() {
  local database_url_name
  local database_url
  local actor="$ROLE_PROVISIONER_EXPECTED_ACTOR"

  [[ "$actor" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] ||
    fail "ROLE_PROVISIONER_EXPECTED_ACTOR must be an unquoted PostgreSQL role name"
  database_url_uses_actor "$ROLE_PROVISIONER_DATABASE_URL" "$actor" ||
    fail "ROLE_PROVISIONER_DATABASE_URL must authenticate as ROLE_PROVISIONER_EXPECTED_ACTOR"

  for database_url_name in \
    MIGRATOR_DATABASE_URL PUBLIC_DATABASE_URL CONTROL_DATABASE_URL \
    IDENTITY_DATABASE_URL SUBMISSION_DATABASE_URL INGEST_DATABASE_URL \
    ANALYSIS_DATABASE_URL PROJECTOR_DATABASE_URL NOTIFICATION_DATABASE_URL \
    WORKFLOW_DATABASE_URL DOCUMENT_EXTRACTOR_DATABASE_URL \
    SCHEDULER_DATABASE_URL EGRESS_DATABASE_URL BILLING_DATABASE_URL \
    ECONOMICS_DATABASE_URL; do
    database_url="${!database_url_name:-}"
    [[ -z "$database_url" || "$database_url" != "$ROLE_PROVISIONER_DATABASE_URL" ]] ||
      fail "ROLE_PROVISIONER_DATABASE_URL must be separate from runtime and migrator URLs"
    if [[ -n "$database_url" ]] && database_url_uses_actor "$database_url" "$actor"; then
      fail "ROLE_PROVISIONER_EXPECTED_ACTOR is forbidden in runtime and migrator URLs"
    fi
  done
}

validate_r6e_runtime_role_contract() {
  local expected_migration_checksum
  local migration_path="$root/db/migrations/0041_r6e_monetization_runtime.sql"
  local result

  [[ -f "$migration_path" && -s "$migration_path" ]] ||
    fail "0041 migration SQL is missing"
  expected_migration_checksum="$(sha384sum -- "$migration_path" | awk '{print $1}')" ||
    fail "0041 migration checksum could not be computed"
  [[ "$expected_migration_checksum" =~ ^[0-9a-f]{96}$ ]] ||
    fail "0041 migration checksum is invalid"

  if ! result="$(psql "$ROLE_PROVISIONER_DATABASE_URL" --no-password -X -qAt \
    -v ON_ERROR_STOP=1 \
    -v expected_actor="$ROLE_PROVISIONER_EXPECTED_ACTOR" \
    -v expected_migration_checksum="$expected_migration_checksum" \
    2>/dev/null <<'SQL'
SET search_path=pg_catalog,pg_temp;
WITH expected(role_name,can_login,connection_limit) AS MATERIALIZED (
  VALUES
    ('gurine_economics_writer'::text,false,-1),
    ('gurine_payment_writer'::text,false,-1),
    ('gurine_billing_gateway'::text,true,8),
    ('gurine_economics_importer'::text,true,4)
), role_state AS MATERIALIZED (
  SELECT auth.oid,expected.role_name
  FROM expected
  JOIN pg_catalog.pg_authid AS auth ON auth.rolname=expected.role_name
  JOIN pg_catalog.pg_roles AS visible_role ON visible_role.oid=auth.oid
  WHERE visible_role.rolcanlogin=expected.can_login
    AND visible_role.rolconnlimit=expected.connection_limit
    AND NOT visible_role.rolsuper
    AND NOT visible_role.rolcreatedb
    AND NOT visible_role.rolcreaterole
    AND NOT visible_role.rolinherit
    AND NOT visible_role.rolreplication
    AND NOT visible_role.rolbypassrls
    AND auth.rolpassword IS NULL
    AND visible_role.rolvaliduntil IS NULL
    AND visible_role.rolconfig IS NULL
), ledger AS MATERIALIZED (
  SELECT count(*) AS row_count,
    count(*) FILTER (WHERE NOT success) AS failed_count,
    min(version) AS min_version,
    max(version) AS max_version,
    count(*) FILTER (
      WHERE version=41
        AND success
        AND description='r6e monetization runtime'
        AND pg_catalog.encode(checksum,'hex')=:'expected_migration_checksum'
    ) AS exact_row_41_count
  FROM public._sqlx_migrations
)
SELECT session_user=:'expected_actor'
  AND current_user=session_user
  AND EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles AS actor
    WHERE actor.rolname=:'expected_actor'
      AND actor.rolsuper
  )
  AND (SELECT count(*) FROM role_state)=4
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_auth_members AS membership
    JOIN role_state AS target
      ON target.oid=membership.roleid OR target.oid=membership.member
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_db_role_setting AS setting
    JOIN role_state AS target ON target.oid=setting.setrole
  )
  AND NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_shdepend AS dependency
    JOIN role_state AS target ON target.oid=dependency.refobjid
    WHERE dependency.refclassid='pg_authid'::pg_catalog.regclass
      AND dependency.deptype IN ('a','o')
      AND dependency.dbid IS DISTINCT FROM (
        SELECT oid FROM pg_catalog.pg_database
        WHERE datname=pg_catalog.current_database()
      )
  )
  AND (SELECT row_count=41
    AND failed_count=0
    AND min_version=1
    AND max_version=41
    AND exact_row_41_count=1
    FROM ledger)
  AND ops.assert_r6e_runtime_role_postconditions_v1() IS TRUE;
SQL
  )"; then
    fail "R6e runtime-role catalog query failed"
  fi
  [[ "$result" == "t" ]] ||
    fail "R6e runtime-role contract or migration row 41 is invalid"
}

csv_contains() {
  local csv="$1"
  local expected="$2"
  local token
  local -a tokens
  IFS=',' read -r -a tokens <<< "$csv"
  for token in "${tokens[@]}"; do
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    if [[ "${token,,}" == "${expected,,}" ]]; then
      return 0
    fi
  done
  return 1
}

for command in awk jq psql sha256sum sha384sum; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

for name in \
  POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD \
  ROLE_PROVISIONER_DATABASE_URL ROLE_PROVISIONER_EXPECTED_ACTOR \
  MIGRATOR_DATABASE_URL PUBLIC_DATABASE_URL CONTROL_DATABASE_URL IDENTITY_DATABASE_URL \
  SUBMISSION_DATABASE_URL INGEST_DATABASE_URL ANALYSIS_DATABASE_URL PROJECTOR_DATABASE_URL \
  NOTIFICATION_DATABASE_URL WORKFLOW_DATABASE_URL DOCUMENT_EXTRACTOR_DATABASE_URL \
  SCHEDULER_DATABASE_URL EGRESS_DATABASE_URL BILLING_DATABASE_URL \
  PUBLIC_API_INTERNAL_URL CONTROL_API_INTERNAL_URL IDENTITY_API_INTERNAL_URL \
  SUBMISSION_API_INTERNAL_URL BILLING_GATEWAY_INTERNAL_URL \
  PUBLIC_BASE_URL REVIEW_BASE_URL RESPONSE_BASE_URL \
  BILLING_GATEWAY_MODE \
  BOT_CHALLENGE_SECRET_KEY BOT_CHALLENGE_SITE_KEY \
  OIDC_EGRESS_URL OIDC_ISSUER_URL OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_REDIRECT_URI \
  OIDC_STEP_UP_REDIRECT_URI OIDC_SCOPES EMAIL_ADAPTER OBJECT_STORE_ADAPTER; do
  required "$name"
done

validate_role_provisioner_separation

for name in \
  GURINE_OPERATING_LEGAL_ENTITY GURINE_PRIVACY_CONTROLLER \
  GURINE_PRIVACY_OFFICER_OR_CPO GURINE_PUBLIC_LEGAL_AND_PRIVACY_CONTACT; do
  required_operator_input "$name"
done

validate_generated_legal_content
validate_review_receipt \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_PATH \
  GURINE_EXTERNAL_KOREAN_COUNSEL_REVIEW_SHA256 \
  external-korean-counsel-review-receipt.v1 \
  KOREAN_LEGAL_LAUNCH_REVIEW supervisor-decision-v1 \
  '["PRIVACY_NOTICE_KO","TERMS_OF_USE_KO"]' \
  APPROVED_FOR_PRODUCTION \
  "$root/verification/generated-legal-content.json"
validate_review_receipt \
  GURINE_LAW_ENFORCEMENT_WORKFLOW_RECEIPT_PATH \
  GURINE_LAW_ENFORCEMENT_WORKFLOW_RECEIPT_SHA256 \
  law-enforcement-workflow-receipt.v1 \
  LAW_ENFORCEMENT_REQUEST_WORKFLOW_REVIEW supervisor-decision-v1 \
  '["LAW_ENFORCEMENT_REQUEST_PROCEDURE_KO"]' \
  APPROVED_FOR_PRODUCTION \
  "$root/specs/legal/law-enforcement-request-procedure.yaml"
required_file_digest \
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_PATH \
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_SHA256
reject_forbidden_deployment_markers \
  GURINE_SOURCE_LICENSE_CAPABILITY_BINDINGS_PATH

[[ "$EGRESS_DATABASE_URL" =~ ^postgres(ql)?://gurine_egress_gateway([:@/]) ]] ||
  fail "EGRESS_DATABASE_URL must authenticate as gurine_egress_gateway"
if [[ -n "${ECONOMICS_DATABASE_URL:-}" ]]; then
  [[ "$ECONOMICS_DATABASE_URL" =~ ^postgres(ql)?://gurine_economics_importer([:@/]) ]] ||
    fail "ECONOMICS_DATABASE_URL must authenticate as gurine_economics_importer when configured"
fi
[[ "$BILLING_DATABASE_URL" =~ ^postgres(ql)?://gurine_billing_gateway([:@/]) ]] ||
  fail "BILLING_DATABASE_URL must authenticate as gurine_billing_gateway"
[[ "$BILLING_GATEWAY_MODE" == "DISABLED" ]] ||
  fail "BILLING_GATEWAY_MODE must be DISABLED for production preflight"
[[ -z "${DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN:-}" ]] ||
  fail "DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN is forbidden outside test mode"
[[ -z "${DONATION_TEST_PAYMENT_OUTCOME:-}" ]] ||
  fail "DONATION_TEST_PAYMENT_OUTCOME is forbidden outside test mode"
for name in \
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
  [[ -z "${!name:-}" ]] || fail "$name is forbidden outside test mode"
done

for name in \
  AUDIT_CHAIN_HMAC_KEY FIELD_ENCRYPTION_KEY_CURRENT TOKEN_HMAC_KEY \
  SUPPLIER_IDENTIFIER_HMAC_KEY \
  IDENTITY_SERVICE_HMAC_KEY_CURRENT IDENTITY_ASSERTION_HMAC_KEY_CURRENT \
  PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT \
  PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT \
  SESSION_COOKIE_KEY_CURRENT SUBMISSION_COOKIE_KEY_CURRENT; do
  base64_key "$name"
done

if [[ "$BOT_CHALLENGE_SITE_KEY" == synthetic-test* ]]; then
  fail "BOT_CHALLENGE_SITE_KEY cannot use the synthetic provider in production"
fi

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
  required AI_PROVIDER_HOSTS
  required EGRESS_AI_CHANNEL_URL
  required AI_CASE_BUDGET_KRW
  required AI_DAILY_BUDGET_KRW
  if csv_contains "$AI_PROVIDER_ORDER" relay; then
    required AI_RELAY_HOST
    required AI_RELAY_API_KEY
    csv_contains "$AI_PROVIDER_HOSTS" "$AI_RELAY_HOST" ||
      fail "AI_RELAY_HOST must be an exact member of AI_PROVIDER_HOSTS"
  fi
fi

connector_gate() {
  local flag="$1"
  local connector_id="$2"
  shift 2
  bool "$flag"
  if [[ "${!flag}" == "true" ]]; then
    for name in "$@"; do required "$name"; done
    enabled_connectors+=("$connector_id")
    printf 'production-preflight: connector %s enabled\n' "$flag"
  else
    printf 'production-preflight: connector %s disabled by configuration\n' "$flag"
  fi
}

enabled_connectors=()
connector_gate SOURCE_KONEPS_CONTRACTS_ENABLED koneps-contracts \
  DATA_GO_KR_SERVICE_KEY KONEPS_CONTRACT_API_BASE_URL
connector_gate SOURCE_KONEPS_NOTICES_ENABLED koneps-notices \
  DATA_GO_KR_SERVICE_KEY KONEPS_NOTICE_API_BASE_URL
connector_gate SOURCE_KONEPS_BID_RESULTS_ENABLED koneps-bid-results \
  DATA_GO_KR_SERVICE_KEY KONEPS_BID_RESULTS_API_BASE_URL
connector_gate SOURCE_OPEN_DART_ENABLED open-dart OPEN_DART_API_KEY OPEN_DART_API_BASE_URL
connector_gate SOURCE_LOCAL_FINANCE_ENABLED local-finance LOCAL_FINANCE_OFFICIAL_MANIFEST_URL
connector_gate SOURCE_ALIO_ENABLED alio ALIO_OFFICIAL_MANIFEST_URL
connector_gate SOURCE_AUDIT_RESULTS_ENABLED audit-results AUDIT_RESULTS_OFFICIAL_MANIFEST_URL
connector_gate SOURCE_PPS_SANCTIONS_ENABLED pps-sanctions PPS_SANCTIONS_OFFICIAL_MANIFEST_URL
if [[ "${SOURCE_PPS_SANCTIONS_ENABLED:-false}" == "true" ]]; then
  [[ "$PPS_SANCTIONS_OFFICIAL_MANIFEST_URL" == https://* ]] ||
    fail "PPS_SANCTIONS_OFFICIAL_MANIFEST_URL must use https"
  [[ "$PPS_SANCTIONS_OFFICIAL_MANIFEST_URL" != https://fixture.invalid/* ]] ||
    fail "PPS sanctions production activation cannot use a test fixture manifest"
  fail "PPS sanctions remains blocked until reuse-rights approval and exact CSV fingerprint are recorded"
fi

enabled_json="$(enabled_connector_json "${enabled_connectors[@]}")" ||
  fail "enabled connector set could not be encoded"
validate_source_license_bindings "$enabled_json"
validate_source_license_evidence
validate_r6e_runtime_role_contract
validate_approved_record_class_schedules
validate_privacy_request_access_policy

if [[ "$preflight_mode" == "TEST_HARNESS" ]]; then
  printf 'production-preflight: PASS (TEST_HARNESS; not production evidence)\n'
else
  printf 'production-preflight: PASS\n'
fi
