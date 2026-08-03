#!/usr/bin/env python3
import base64
import hashlib
import hmac
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

import yaml
from jsonschema import Draft202012Validator, RefResolver

BASE = os.environ["CONTROL_TEST_BASE_URL"].rstrip("/")
KEY = base64.b64decode(os.environ["CONTROL_ASSERTION_KEY"])
POSTGRES_CONTAINER = os.environ["CONTROL_TEST_POSTGRES_CONTAINER"]
POSTGRES_DATABASE = os.environ["CONTROL_TEST_POSTGRES_DATABASE"]
SPEC = json.load(open("specs/generated/control-api.openapi.json", encoding="utf-8"))
BASE_OPERATION_CONTRACTS = yaml.safe_load(
    open("specs/api/operation-contracts.yaml", encoding="utf-8")
)
ADDENDUM_OPERATION_CONTRACTS = yaml.safe_load(
    open("specs/product/addendum-operation-contracts.yaml", encoding="utf-8")
)
CONCURRENCY = {
    item["operationId"]: item
    for item in json.load(open("specs/application/optimistic-concurrency.runtime.json", encoding="utf-8"))["contracts"]
}
ACTOR = "11111111-1111-4111-8111-111111111111"
SESSION = "22222222-2222-4222-8222-222222222222"
REVIEWER = "44444444-4444-4444-8444-444444444444"
QUERY_ID = "99999999-9999-4999-8999-999999999999"
resolver = RefResolver.from_schema(SPEC)
FIXTURE_UUIDS = {
    name: str(uuid.uuid5(uuid.NAMESPACE_URL, f"gurine:fixture:{name}"))
    for name in (
        "agentRunId",
        "backfillRunId",
        "caseId",
        "claimId",
        "correctionId",
        "evidenceId",
        "hypothesisId",
        "jobId",
        "killSwitchId",
        "notificationId",
        "providerId",
        "publicationId",
        "responseId",
        "responseRequestId",
        "retentionRequestId",
        "reviewSnapshotId",
        "roleId",
        "ruleRunId",
        "ruleVersionId",
        "savedViewId",
        "schemaDriftId",
        "signalId",
        "sourceRunId",
        "suggestionId",
        "taskId",
        "userId",
    )
}
# Stable RETRYABLE_FAILED aggregate from control-retry-seed.sql.
RETRY_FIXTURE_EXECUTION_ID = "f4e7c4f1-7b4d-5d2e-9d7c-7e53dbdf7c7d"
COMMUNICATION_RECONCILE_FIXTURE_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:reconcileCommunicationDelivery:deliveryId"))
INCIDENT_TRANSITION_FIXTURE_ID = "8e5a7c0f-2a7c-54c2-998b-b14ac2ee67ff"
RESPONSE_APPEAL_FIXTURE_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:response-appeal"))
RESPONSE_EXTENSION_FIXTURE_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:extensionRequestId"))
RETENTION_REQUEST_FIXTURE_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:retentionRequestId"))
RETENTION_TRANSITION_FIXTURE_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:retentionTransitionRequestId"))
CALENDAR_FIXTURE_ID = str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:calendarVersionId"))
PROMOTION_ARTIFACT_ID = "facc134e-f4d3-551d-bb42-55d4495373ae"
PROMOTION_ASSET_ID = "d3f33b34-05e9-5d0f-bdf0-95742b10d590"
PROMOTION_FETCH_ID = "86bfb4f9-eefd-533b-83fa-df5dc32e2c2f"
PROMOTION_TURN_ID = "df45a69f-7ddb-5d39-b135-cc6eeacddd96"
PROMOTION_TOOL_ID = "043eb9f6-e47e-56de-a587-82969b7bc1b6"
PROMOTION_RIGHTS_ID = os.environ["CONTROL_PROMOTION_RIGHTS_ID"]
PROMOTION_SEGMENT_ID = "1e44d0d1-9826-59fb-bc26-07c443a2134d"
PROMOTION_SELECTED_CONTENT_SHA256 = "4951601014f8f3dfce1477715f11e812d5c8a29f00bd88803405fd32d4af07c6"
PROMOTION_ARTIFACT_SHA256 = os.environ["CONTROL_PROMOTION_ARTIFACT_SHA256"]
PROMOTION_RIGHTS_SHA256 = os.environ["CONTROL_PROMOTION_RIGHTS_SHA256"]
PROMOTION_LOCATOR_SHA256 = "4656013e261fa8c167a4157ef90e11af4fba55d5c9ac9b7d60e1e2ea39fc274d"
PROMOTION_SOURCE_USE_ID = "e3b5ed44-ec8b-5fb3-ad5c-924ca07afa9d"
PROMOTION_AGENT_RUN_ID = "8eee21b7-75c0-53c9-b079-d897a2c3c711"
CANCEL_AGENT_RUN_ID = "77b9da26-766c-5f56-9084-39380003ec20"
JOURNEY_HANDOFF_ID = os.environ.get("CONTROL_JOURNEY_HANDOFF_ID")
JOURNEY_HANDOFF_BINDING = os.environ.get("CONTROL_JOURNEY_HANDOFF_BINDING")
JOURNEY_HANDOFF_VERSION = int(os.environ.get("CONTROL_JOURNEY_HANDOFF_VERSION", "1"))
WITHDRAW_FIXTURE_PROPOSAL_ID = "77777777-7777-4777-8777-777777777777"
WITHDRAW_FIXTURE_CONTENT_DIGEST = "e" * 64
WITHDRAW_DECISION_PROPOSAL_ID = "6b8f4e8a-2f9f-5ac9-9db7-5d6f3ad5df37"
WITHDRAW_DECISION_ID = "337d61a4-29e7-5f8f-8dbf-d38f5328965b"
STEP_UP_AUTHORIZATION_ID = "55555555-5555-4555-8555-555555555555"
STEP_UP_ACTION_DIGEST = "c" * 64
R6D_LEGAL_HOLD_TARGETS = {
    target["targetKind"]: target
    for target in json.loads(os.environ.get("CONTROL_R6D_LEGAL_HOLD_TARGETS", "[]"))
}
R6D_RESPONSE_ID = os.environ.get("CONTROL_R6D_RESPONSE_ID")
R6D_RESPONSE_ORGANIZATION_ID = os.environ.get("CONTROL_R6D_RESPONSE_ORGANIZATION_ID")
R6D_RESPONSE_OFFICIAL_ASSERTION_ID = os.environ.get(
    "CONTROL_R6D_RESPONSE_OFFICIAL_ASSERTION_ID"
)
R6D_RESPONSE_RAW_VERIFICATION_ID = os.environ.get(
    "CONTROL_R6D_RESPONSE_RAW_VERIFICATION_ID"
)
R6D_RESPONSE_REVOKED_ASSERTION_ID = os.environ.get(
    "CONTROL_R6D_RESPONSE_REVOKED_ASSERTION_ID"
)
R6D_RESPONSE_EXCERPT_SHA256 = os.environ.get("CONTROL_R6D_RESPONSE_EXCERPT_SHA256")
R6D_LEGAL_HOLD_KINDS = {
    "CASE",
    "PUBLICATION",
    "EVIDENCE",
    "RESPONSE",
    "SOURCE_ASSET",
    "RESEARCH_ARTIFACT",
    "PRIVACY_REQUEST",
    "COMMUNICATION_SUBJECT",
    "SUPPLIER_RETENTION_SNAPSHOT",
    "AGENCY_RETENTION_SNAPSHOT",
}
assert set(R6D_LEGAL_HOLD_TARGETS) == R6D_LEGAL_HOLD_KINDS
assert all(
    value is not None
    for value in (
        R6D_RESPONSE_ID,
        R6D_RESPONSE_ORGANIZATION_ID,
        R6D_RESPONSE_OFFICIAL_ASSERTION_ID,
        R6D_RESPONSE_RAW_VERIFICATION_ID,
        R6D_RESPONSE_REVOKED_ASSERTION_ID,
        R6D_RESPONSE_EXCERPT_SHA256,
    )
)


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def resolve(schema):
    while "$ref" in schema:
        target = schema["$ref"]
        assert target.startswith("#/")
        current = SPEC
        for segment in target[2:].split("/"):
            current = current[segment.replace("~1", "/").replace("~0", "~")]
        schema = current
    return schema


def example(schema, name, operation, query):
    if name == "reasonCode":
        return "OTHER"
    schema = resolve(schema)
    if "anyOf" in schema:
        options = [item for item in schema["anyOf"] if resolve(item).get("type") != "null"]
        return example(options[0] if options else schema["anyOf"][0], name, operation, query)
    if "oneOf" in schema:
        # Closed discriminated unions expose each authority variant as a
        # branch.  The first branch is a valid, deterministic fixture; the
        # server still validates the complete branch against the same schema.
        return example(schema["oneOf"][0], name, operation, query)
    if "allOf" in schema:
        base = dict(schema)
        branches = base.pop("allOf")
        value = example(base, name, operation, query)
        assert isinstance(value, dict)
        for item in branches:
            condition = item.get("if", {}).get("properties", {})
            if condition and not all(
                key in value
                and ("const" not in expected or value[key] == expected["const"])
                and ("enum" not in expected or value[key] in expected["enum"])
                for key, expected in condition.items()
            ):
                continue
            selected = item.get("then", item)
            part = example(selected, name, operation, query)
            if isinstance(part, dict):
                value.update(part)
        return value
    # Some state transitions intentionally use a later enum member so the
    # seeded fixture can exercise the happy path.
    if name == "targetState" and operation == "transitionCase":
        return "AWAITING_RESPONSE"
    # Literal schemas (const/enum) do not declare a JSON type.  Resolve them
    # before falling back to object; otherwise required literal fields such as
    # promote-research-artifact.request.v1's schemaVersion are generated as
    # `{}` and fail the runtime contract despite validating against OpenAPI.
    if "const" in schema:
        return schema["const"]
    if schema.get("enum"):
        return schema["enum"][0]
    kind = schema.get("type", "object")
    if kind == "object":
        required = schema.get("required", [])
        return {key: example(schema["properties"][key], key, operation, query) for key in required}
    if kind == "array":
        count = max(1, schema.get("minItems", 0))
        return [example(schema["items"], name, operation, query) for _ in range(count)]
    if kind == "boolean":
        return True
    if kind in ("integer", "number"):
        if name == "expectedVersion":
            if operation == "extendKillSwitch":
                return 2
            if operation == "deactivateKillSwitch":
                return 3
            return 1
        return max(schema.get("minimum", 1), 1)
    if kind == "null":
        return None
    lower = name.lower()
    if name == "sourceId":
        source = {
            "pauseSource": "control-pause-source",
            "startBackfill": "control-backfill-source",
            "startSourceRun": "control-run-source",
        }.get(operation)
        if source:
            return source
        return "control-fixture-source"
    if name == "ruleVersionId":
        suffix = {
            "activateRuleVersion": "rule-activate",
            "rollbackRuleVersion": "rule-rollback-current",
            "scheduleRuleActivation": "rule-schedule",
            "startRuleShadow": "rule-shadow",
        }.get(operation)
        if suffix:
            return str(uuid.uuid5(uuid.NAMESPACE_URL, f"gurine:fixture:{suffix}"))
    if name == "targetVersionId" and operation == "rollbackRuleVersion":
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:rule-rollback-target"))
    if name == "suggestionId" and operation in ("acceptAgentSuggestion", "rejectAgentSuggestion"):
        suffix = "suggestion-accept" if operation == "acceptAgentSuggestion" else "suggestion-reject"
        return str(uuid.uuid5(uuid.NAMESPACE_URL, f"gurine:fixture:{suffix}"))
    if name == "schemaDriftId" and operation in ("approveSchemaMapping", "rejectSchemaMapping"):
        suffix = "schema-approve" if operation == "approveSchemaMapping" else "schema-reject"
        return str(uuid.uuid5(uuid.NAMESPACE_URL, f"gurine:fixture:{suffix}"))
    if name == "jobId" and operation in ("cancelJob", "quarantineJob", "retryJob"):
        suffix = {
            "cancelJob": "job-cancel",
            "quarantineJob": "job-quarantine",
            "retryJob": "job-retry",
        }[operation]
        return str(uuid.uuid5(uuid.NAMESPACE_URL, f"gurine:fixture:{suffix}"))
    if name == "providerId" and operation == "testProviderConnection":
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:provider-test"))
    if name == "sourceRunId" and operation == "downloadSourceRunReport":
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:source-run-report"))
    if name == "userId" and operation in ("grantRole", "revokeRole"):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:role-user"))
    if name == "correctionId" and operation == "resolveCorrectionRequest":
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:resolve-correction"))
    if name == "correctionId" and operation == "updateCorrectionDraft":
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:update-correction-draft"))
    if name in ("assigneeUserId", "reviewerUserId"):
        if name == "assigneeUserId" and operation == "assignReview":
            return ACTOR
        return FIXTURE_UUIDS["userId"]
    if name in ("roleIds", "reviewerUserIds"):
        return FIXTURE_UUIDS["roleId"] if name == "roleIds" else ACTOR
    if name in ("evidenceIds", "supportingEvidenceIds", "contradictingEvidenceIds"):
        return FIXTURE_UUIDS["evidenceId"]
    if name == "claimIds":
        return FIXTURE_UUIDS["claimId"]
    if name == "jobIds" and operation == "retryJobs":
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:bulk-job"))
    if name == "responseIds":
        return FIXTURE_UUIDS["responseId"]
    if name == "affectedIds":
        return FIXTURE_UUIDS["caseId"]
    if name == "releaseScopeAtoms":
        return "RETENTION"
    if schema.get("format") == "uuid" or lower.endswith("id"):
        if query:
            query_fixture = {
                "auditExportId": str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:audit-export-query")),
                "evaluationRunId": str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:eval-activate")),
            }.get(name)
            if query_fixture:
                return query_fixture
            if name in FIXTURE_UUIDS:
                return FIXTURE_UUIDS[name]
            return QUERY_ID
        if name in FIXTURE_UUIDS:
            return FIXTURE_UUIDS[name]
        return str(uuid.uuid5(uuid.NAMESPACE_URL, f"gurine:{operation}:{name}"))
    if schema.get("format") == "date-time" or lower.endswith("at"):
        if name == "from":
            return "2026-07-01T00:00:00Z"
        if name == "to":
            return "2026-07-12T00:00:00Z"
        if name in ("expiresAt", "dueAt") or operation == "scheduleRuleActivation":
            return "2027-07-12T20:00:00Z"
        return "2026-07-12T20:00:00Z"
    if schema.get("format") == "date":
        if name == "from":
            return "2026-07-01"
        if name == "to":
            return "2026-07-12"
        return "2026-07-12"
    if schema.get("format") == "email" or "email" in lower:
        return f"{operation.lower()}@example.test"
    if schema.get("format") in ("uri", "uri-reference") or "url" in lower:
        return "/v1/internal"
    if "sha256" in lower or "digest" in lower or "hash" in lower:
        if name == "previewHash" and operation == "publishCase":
            payload = {
                "caseId": FIXTURE_UUIDS["caseId"],
                "agencyIds": ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"],
                "claims": [],
                "evidence": [],
                "responses": [],
                "reviewSnapshotId": FIXTURE_UUIDS["reviewSnapshotId"],
                "ruleIds": ["control-fixture-rule"],
                "slug": "control-fixture-case",
                "sourceFreshness": {},
                "summary": "Canonical integration case",
                "supplierIds": ["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"],
                "title": "Control canonical case",
            }
            return sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode())
        if name == "excerptHash" and operation == "approveResponseExcerpt":
            return sha256(b"Control public excerpt")
        return sha256(f"{operation}:{name}".encode())
    if "currency" in lower:
        return "KRW"
    if name == "dailyLimit":
        return "100.00"
    if name == "monthlyLimit":
        return "1000.00"
    if name == "maxCost":
        return "10.00"
    if "reason" in lower:
        return f"{operation} integration reason"
    if "code" in lower:
        return f"{operation.upper()}_INTEGRATION"
    if name == "queueName":
        return "control-fixture-queue"
    if name == "scope" and operation == "updateBudgetLimit":
        return "control-fixture-budget"
    minimum = schema.get("minLength", 1)
    value = f"{operation}-{name}"
    return value if len(value) >= minimum else value + "x" * (minimum - len(value))


def canonical_query(raw):
    pairs = urllib.parse.parse_qsl(raw, keep_blank_values=True)
    pairs.sort()
    return "&".join(
        f"{urllib.parse.quote(k, safe='-._~')}={urllib.parse.quote(v, safe='-._~')}" for k, v in pairs
    )


def canonical_request_sha256(method, path, raw_query, body, content_type, idempotency_key):
    request_shape = "\n".join(
        [
            method,
            path,
            sha256(canonical_query(raw_query).encode()),
            sha256(body),
            content_type,
            sha256(idempotency_key.encode()),
        ]
    )
    return sha256(request_shape.encode())


def postgres(sql):
    subprocess.run(
        ["docker", "exec", "-i", POSTGRES_CONTAINER, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", POSTGRES_DATABASE],
        input=sql.encode(),
        check=True,
        stdout=subprocess.DEVNULL,
    )


def postgres_value(sql):
    return subprocess.check_output(
        ["docker", "exec", "-i", POSTGRES_CONTAINER, "psql", "-At", "-F", "|", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", POSTGRES_DATABASE],
        input=sql.encode(),
        text=False,
    ).decode().strip()


def assertion(
    operation,
    method,
    path,
    raw_query,
    body,
    content_type,
    idempotency_key,
    actor_id=ACTOR,
    *,
    assertion_jti=None,
    step_up_authorization_id=None,
    action_digest=None,
):
    now = int(time.time())
    capability = operation["x-capability"]
    capabilities = [] if capability == "none" else [capability]
    if operation["operationId"] == "transitionCase":
        target = json.loads(body).get("targetState")
        transition_capability = {
            "TRIAGE": "signals.triage",
            "INVESTIGATING": "cases.investigate",
            "AWAITING_RESPONSE": "responses.request",
            "EDITORIAL_REVIEW": "review.editorial",
            "LEGAL_REVIEW": "review.legal",
            "READY_TO_PUBLISH": "review.editorial",
            "CLOSED": "cases.investigate",
        }.get(target)
        if transition_capability and transition_capability not in capabilities:
            capabilities.append(transition_capability)
    # The OpenAPI overlay records conditional policy labels, while the
    # runtime catalog resolves this safe retry fixture to an active session
    # (no provider attempt and no step-up grant).  Assertions must bind to the
    # effective runtime assurance, not the unresolved policy label.
    assurance = operation["x-assurance-level"]
    if operation["operationId"] == "retryActionExecution":
        assurance = "ACTIVE_SESSION"
    if operation["operationId"] in {"withdrawConflict", "withdrawActionDecision"}:
        assurance = "ACTIVE_SESSION"
    # The generated OpenAPI overlay records the persisted-handoff policy
    # label, while the executable control catalog resolves its minimum
    # assurance to ACTIVE_SESSION for this witness.  Bind the assertion to
    # that effective runtime assurance rather than the descriptive overlay.
    if operation["operationId"] == "decideJourneyHandoff":
        assurance = "ACTIVE_SESSION"
    if operation["operationId"] == "submitActionDecision":
        try:
            decision = json.loads(body).get("decision", {})
            assurance = decision.get("assurance", assurance)
        except (TypeError, json.JSONDecodeError):
            pass
    claims = {
        "actionDigest": (
            action_digest or sha256(f"action:{operation['operationId']}".encode())
        )
        if assurance == "STEP_UP"
        else None,
        "assuranceLevel": assurance,
        "aud": "control-api",
        "authTime": now,
        "bodySha256": sha256(body),
        "capabilities": capabilities,
        "capabilityHash": sha256("\n".join(capabilities).encode()),
        "contentType": content_type,
        "exp": now + 20,
        "iat": now,
        "idempotencyKeySha256": sha256(idempotency_key.encode()) if idempotency_key else None,
        "iss": "identity-api",
        "jti": assertion_jti or str(uuid.uuid4()),
        "method": method,
        "operationId": operation["operationId"],
        "path": path,
        "querySha256": sha256(canonical_query(raw_query).encode()),
        "requiredCapability": capability,
        "rolesVersion": 1,
        "sid": REVIEWER if actor_id != ACTOR else SESSION,
        "stepUpAt": now if assurance == "STEP_UP" else None,
        "stepUpAuthorizationId": (
            step_up_authorization_id or str(uuid.uuid4())
        )
        if assurance == "STEP_UP"
        else None,
        "sub": actor_id,
        "typ": "actor",
        "v": 1,
    }
    claims = {key: value for key, value in claims.items() if value is not None}
    encoded = json.dumps(claims, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode()
    payload = base64.urlsafe_b64encode(encoded).decode().rstrip("=")
    signing = f"gurine-aa-v1.{sha256(KEY)[:16]}.{payload}"
    signature = base64.urlsafe_b64encode(hmac.new(KEY, signing.encode(), hashlib.sha256).digest()).decode().rstrip("=")
    return f"{signing}.{signature}"


operations = []
for path_template, path_item in SPEC["paths"].items():
    for method in ["get", "post", "patch", "delete"]:
        if method in path_item:
            operations.append((path_template, path_item, method.upper(), path_item[method]))
# The generated Control document includes the 131 authority operations plus
# the 36 owner-addendum operations.  Derive the witness from the generated
# source rather than silently dropping the additive surface or pinning a stale
# literal count.
expected_control_operations = sum(
    operation.get("api") == "control-api"
    for operation in BASE_OPERATION_CONTRACTS["operations"]
) + sum(
    operation.get("api") == "control-api"
    for operation in ADDENDUM_OPERATION_CONTRACTS["operations"]
)
assert len(operations) == expected_control_operations
operation_order = {
    "listActionApprovalQueue": 0,
    "createActionProposal": 1,
    "getActionProposal": 2,
    "updateActionDraft": 3,
    "previewActionDraft": 4,
    "submitActionForReview": 5,
    "claimActionReview": 6,
    "submitActionDecision": 7,
    # The same response proves the fail-closed pre-identity excerpt gate,
    # organization verification, and the exact post-verification approval.
    # Keep that authority order explicit instead of relying on OpenAPI map
    # insertion order.
    "verifyResponseOrganizationIdentity": 7,
    "approveResponseExcerpt": 8,
    "retryActionExecution": 8,
    "cancelActionExecution": 9,
    "withdrawActionProposal": 8,
    "withdrawActionDecision": 9,
    "assignReview": 0,
    "submitReview": 1,
    "previewPublication": 2,
    "publishCase": 3,
    "activateKillSwitch": 4,
    "extendKillSwitch": 5,
    "deactivateKillSwitch": 6,
}
operations.sort(key=lambda item: operation_order.get(item[3]["operationId"], 7))


def operation_entry(operation_id):
    return next(item for item in operations if item[3]["operationId"] == operation_id)


def invoke_command(
    operation_id,
    request_value,
    *,
    path_values=None,
    idempotency_key=None,
    actor_id=ACTOR,
    assertion_jti=None,
    step_up_authorization_id=None,
    action_digest=None,
    transport_request_id=None,
):
    path_values = path_values or {}
    path_template, _, method, operation = operation_entry(operation_id)
    path = path_template
    for name, value in path_values.items():
        path = path.replace("{" + name + "}", urllib.parse.quote(str(value), safe=""))
    body = json.dumps(request_value, ensure_ascii=False, separators=(",", ":")).encode()
    key = idempotency_key or str(uuid.uuid4())
    token = assertion(
        operation,
        method,
        path,
        "",
        body,
        "application/json",
        key,
        actor_id,
        assertion_jti=assertion_jti,
        step_up_authorization_id=step_up_authorization_id,
        action_digest=action_digest,
    )
    request = urllib.request.Request(
        BASE + path,
        data=body,
        headers={
            "X-Gurine-Actor-Assertion": token,
            "X-Request-ID": transport_request_id or str(uuid.uuid4()),
            "Content-Type": "application/json",
            "Idempotency-Key": key,
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, response.read(), dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read(), dict(error.headers)


def prepare_step_up_authority(operation_id, idempotency_key, authorization_id):
    action_digest = sha256(f"action:{operation_id}".encode())
    idempotency_digest = sha256(idempotency_key.encode())
    authorization_token_digest = sha256(
        f"control-runtime-step-up:{authorization_id}".encode()
    )
    postgres(
        f"""
        INSERT INTO ops.step_up_authorizations(
          id,session_id,action_digest,idempotency_key_sha256,
          authorization_token_hash,expires_at,assertion_issue_count,
          max_assertion_issues,created_at,last_issued_at
        ) VALUES(
          '{authorization_id}'::uuid,'{SESSION}'::uuid,'{action_digest}',
          '{idempotency_digest}','{authorization_token_digest}',
          clock_timestamp()+interval '4 minutes',1,3,
          clock_timestamp()-interval '2 seconds',
          clock_timestamp()-interval '1 second'
        ) ON CONFLICT(id) DO NOTHING;
        DO $step_up_fixture$
        BEGIN
          IF NOT EXISTS(
            SELECT 1 FROM ops.step_up_authorizations
             WHERE id='{authorization_id}'::uuid
               AND session_id='{SESSION}'::uuid
               AND action_digest='{action_digest}'::char(64)
               AND idempotency_key_sha256='{idempotency_digest}'::char(64)
               AND closed_at IS NULL AND expires_at>clock_timestamp()
               AND assertion_issue_count=1 AND last_issued_at IS NOT NULL
          ) THEN
            RAISE EXCEPTION 'control_runtime_step_up_fixture_mismatch';
          END IF;
        END
        $step_up_fixture$;
        """
    )
    return action_digest


def expire_http_idempotency(operation_id, idempotency_key):
    scope = f"control:{ACTOR}:{operation_id}"
    key_digest = sha256(idempotency_key.encode())
    postgres(
        f"""
        UPDATE ops.idempotency_keys
           SET response_status=NULL,response_body=NULL,
               expires_at=clock_timestamp()-interval '1 minute'
         WHERE scope='{scope}' AND key_hash='{key_digest}';
        DO $idempotency_fixture$
        BEGIN
          IF NOT EXISTS(
            SELECT 1 FROM ops.idempotency_keys
             WHERE scope='{scope}' AND key_hash='{key_digest}'
               AND response_status IS NULL AND response_body IS NULL
               AND expires_at<clock_timestamp()
          ) THEN
            RAISE EXCEPTION 'control_runtime_idempotency_expiry_failed';
          END IF;
        END
        $idempotency_fixture$;
        """
    )


def prepare_legal_hold_authority(target, idempotency_key):
    target_kind = target["targetKind"]
    target_id = str(uuid.UUID(target["targetId"]))
    target_version = int(target["targetVersion"])
    target_digest = target["targetDigest"]
    assert target_version >= 1
    assert len(target_digest) == 64 and all(
        character in "0123456789abcdef" for character in target_digest
    )
    authorization_id = str(
        uuid.uuid5(uuid.NAMESPACE_URL, f"gurine:r6d:legal-hold:step-up:{idempotency_key}")
    )
    action_digest = prepare_step_up_authority(
        "placeLegalHold", idempotency_key, authorization_id
    )
    conflict_binding = (
        f"{target_kind}:{target_id}:{target_version}:{target_digest}:placeLegalHold"
    )
    conflict_id = str(
        uuid.uuid5(uuid.NAMESPACE_URL, f"gurine:r6d:legal-hold:conflict:{conflict_binding}")
    )
    digests = {
        name: sha256(f"{name}:{conflict_binding}".encode())
        for name in (
            "declarations",
            "findings",
            "authorship",
            "party",
            "role",
            "relationship",
            "funding",
            "policy",
            "snapshot",
            "receipt",
        )
    }
    postgres(
        f"""
        INSERT INTO editorial.conflict_snapshots(
          id,subject_actor_id,target_type,target_id,target_version,target_digest,
          operation_id,action_kind,candidate_role,declaration_ids,
          declaration_set_digest,finding_set,finding_set_digest,
          authorship_digest,party_recipient_digest,role_digest,
          relationship_digest,funding_customer_digest,policy_digest,
          evaluation_state,blocker_codes,nonwaivable_blocker_count,
          evaluated_at,valid_until,evaluated_by_type,evaluated_by_id,
          snapshot_sha256,receipt_digest
        ) VALUES(
          '{conflict_id}'::uuid,'{ACTOR}'::uuid,'{target_kind}','{target_id}',
          {target_version},'{target_digest}','placeLegalHold',NULL,
          'LEGAL_REVIEWER','{{}}'::uuid[],'{digests["declarations"]}',
          '{{}}'::jsonb,'{digests["findings"]}','{digests["authorship"]}',
          '{digests["party"]}','{digests["role"]}',
          '{digests["relationship"]}','{digests["funding"]}',
          '{digests["policy"]}','CLEAR','{{}}'::text[],0,
          clock_timestamp()-interval '1 second',
          clock_timestamp()+interval '10 minutes','SERVICE',
          'control-runtime-r6d','{digests["snapshot"]}',
          '{digests["receipt"]}'
        ) ON CONFLICT(id) DO NOTHING;
        DO $conflict_fixture$
        DECLARE v_count bigint;
        BEGIN
          SELECT count(*) INTO v_count
          FROM editorial.conflict_snapshots
          WHERE subject_actor_id='{ACTOR}'::uuid
            AND target_type='{target_kind}' AND target_id='{target_id}'
            AND target_version={target_version}
            AND target_digest='{target_digest}'::char(64)
            AND operation_id='placeLegalHold' AND action_kind IS NULL
            AND candidate_role='LEGAL_REVIEWER' AND evaluation_state='CLEAR'
            AND valid_until>clock_timestamp();
          IF v_count<>1 THEN
            RAISE EXCEPTION 'control_runtime_legal_hold_conflict_fixture_ambiguous:%',
              v_count;
          END IF;
        END
        $conflict_fixture$;
        """
    )
    return authorization_id, action_digest


def legal_hold_request(target):
    return {
        "target": target,
        # The service and owner must canonicalize both arrays before hashing.
        "scopeAtoms": ["RETENTION", "DISCLOSURE", "DELETION"],
        "affectedIds": [
            "ffffffff-ffff-4fff-8fff-ffffffffffff",
            "00000000-0000-4000-8000-000000000001",
        ],
        "authorityReference": f"R6d control runtime authority: {target['targetKind']}",
        "reasonCode": "LEGAL_PRESERVATION_REQUIRED",
        "reason": f"Preserve the exact {target['targetKind']} fixture for R6d runtime proof",
        "expiresAt": None,
    }


def response_identity_request(source_id, verification_method="OFFICIAL_DOMAIN_EMAIL"):
    assert R6D_RESPONSE_ID is not None
    assert R6D_RESPONSE_ORGANIZATION_ID is not None
    return {
        "responseId": R6D_RESPONSE_ID,
        "organizationId": R6D_RESPONSE_ORGANIZATION_ID,
        "publicationForm": "FULL",
        "verificationMethod": verification_method,
        "officialChannelSourceId": source_id,
        "reason": "Verify the exact official organization channel before public attribution",
        "expectedVersion": 1,
    }


def response_excerpt_request(expected_version):
    assert R6D_RESPONSE_ID is not None
    assert R6D_RESPONSE_EXCERPT_SHA256 is not None
    return {
        "responseId": R6D_RESPONSE_ID,
        "excerptHash": R6D_RESPONSE_EXCERPT_SHA256,
        "publicationForm": "FULL",
        "reason": "Approve the exact consented excerpt after organization verification",
        "expectedVersion": expected_version,
    }


def response_identity_state_digest():
    return postgres_value(
        f"""
        SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
          jsonb_build_object(
            'response',to_jsonb(response),
            'identityAssertionCount',(
              SELECT count(*) FROM editorial.response_organization_identity_assertions_v1
               WHERE response_id=response.id
            ),
            'publicationIdentityCount',(
              SELECT count(*) FROM editorial.response_publication_identity_receipts_v1
               WHERE response_id=response.id
            ),
            'excerptApprovalCount',(
              SELECT count(*) FROM editorial.response_excerpt_approval_receipts_v2
               WHERE response_id=response.id
            ),
            'identityOutboxCount',(
              SELECT count(*) FROM ops.outbox
               WHERE aggregate_type='editorial_response'
                 AND aggregate_id=response.id::text
                 AND event_type IN (
                   'response.organization_identity_verified.v1',
                   'response.excerpt_approved.v2'
                 )
            ),
            'identityAuditCount',(
              SELECT count(*) FROM ops.audit_events
               WHERE object_type='EditorialResponse'
                 AND object_id=response.id::text
                 AND action IN (
                   'response.organization_identity.verify',
                   'response.excerpt.approve'
                 )
            )
          )
        ),'sha256'),'hex')
        FROM editorial.responses AS response
        WHERE response.id='{R6D_RESPONSE_ID}'::uuid;
        """
    )


def legal_hold_state_digest(idempotency_key):
    idempotency_digest = sha256(idempotency_key.encode())
    return postgres_value(
        f"""
        SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
          jsonb_build_object(
            'receiptId',receipt.receipt_id,
            'receiptDigest',receipt.receipt_digest,
            'legalHoldId',receipt.legal_hold_id,
            'anchorId',receipt.anchor_id,
            'anchorDigest',receipt.anchor_digest,
            'target',receipt.target_payload,
            'scopeAtoms',receipt.scope_atoms,
            'scopeAtomsDigest',receipt.scope_atoms_digest,
            'affectedIds',receipt.affected_ids,
            'affectedSetDigest',receipt.affected_set_digest,
            'auditEventId',receipt.audit_event_id,
            'outboxEventId',receipt.outbox_event_id,
            'holdCount',(
              SELECT count(*) FROM editorial.legal_holds
               WHERE id=receipt.legal_hold_id
            ),
            'anchorCount',(
              SELECT count(*) FROM ops.legal_hold_target_anchors
               WHERE id=receipt.anchor_id
            ),
            'receiptCount',(
              SELECT count(*) FROM ops.legal_hold_placement_receipts_v2
               WHERE idempotency_key_sha256='{idempotency_digest}'::char(64)
            ),
            'auditCount',(
              SELECT count(*) FROM ops.audit_events
               WHERE id=receipt.audit_event_id
            ),
            'outboxCount',(
              SELECT count(*) FROM ops.outbox
               WHERE id=receipt.outbox_event_id
            )
          )
        ),'sha256'),'hex')
        FROM ops.legal_hold_placement_receipts_v2 AS receipt
        WHERE receipt.idempotency_key_sha256='{idempotency_digest}'::char(64);
        """
    )


def legal_hold_global_state_digest():
    return postgres_value(
        """
        SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
          jsonb_build_object(
            'holds',(
              SELECT COALESCE(jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id),'[]'::jsonb)
              FROM editorial.legal_holds AS row_value
            ),
            'anchors',(
              SELECT COALESCE(jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id),'[]'::jsonb)
              FROM ops.legal_hold_target_anchors AS row_value
            ),
            'placements',(
              SELECT COALESCE(jsonb_agg(to_jsonb(row_value) ORDER BY row_value.receipt_id),'[]'::jsonb)
              FROM ops.legal_hold_placement_receipts_v2 AS row_value
            ),
            'audits',(
              SELECT COALESCE(jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id),'[]'::jsonb)
              FROM ops.audit_events AS row_value
              WHERE row_value.action='command.placeLegalHold'
            ),
            'outbox',(
              SELECT COALESCE(jsonb_agg(to_jsonb(row_value) ORDER BY row_value.id),'[]'::jsonb)
              FROM ops.outbox AS row_value
              WHERE row_value.event_type='legal_hold.placed.v2'
            )
          )
        ),'sha256'),'hex');
        """
    )


def current_legal_hold_target(target):
    current = json.loads(json.dumps(target))
    if current["targetKind"] == "RESPONSE":
        version, digest = postgres_value(
            f"""
            SELECT version,btrim(response_content_sha256::text)
            FROM editorial.responses
            WHERE id='{current['targetId']}'::uuid;
            """
        ).split("|")
        current["targetVersion"] = int(version)
        current["targetDigest"] = digest
    return current


def assert_legal_hold_receipt_graph(target, idempotency_key):
    target_json = json.dumps(target, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    key_digest = sha256(idempotency_key.encode())
    expected_scope = sorted(["RETENTION", "DISCLOSURE", "DELETION"])
    expected_affected = sorted(
        [
            "ffffffff-ffff-4fff-8fff-ffffffffffff",
            "00000000-0000-4000-8000-000000000001",
        ]
    )
    scope_sql = ",".join(f"'{value}'" for value in expected_scope)
    affected_sql = ",".join(f"'{value}'::uuid" for value in expected_affected)
    result = json.loads(
        postgres_value(
            f"""
            SELECT jsonb_build_object(
              'receiptCount',(
                SELECT count(*) FROM ops.legal_hold_placement_receipts_v2
                WHERE idempotency_key_sha256='{key_digest}'::char(64)
              ),
              'holdCount',(
                SELECT count(*) FROM editorial.legal_holds
                WHERE id=receipt.legal_hold_id
              ),
              'anchorCount',(
                SELECT count(*) FROM ops.legal_hold_target_anchors
                WHERE id=receipt.anchor_id
              ),
              'auditCount',(
                SELECT count(*) FROM ops.audit_events
                WHERE id=receipt.audit_event_id
              ),
              'outboxCount',(
                SELECT count(*) FROM ops.outbox
                WHERE id=receipt.outbox_event_id
              ),
              'targetMatches',
                receipt.target_kind='{target['targetKind']}'
                AND receipt.target_id='{target['targetId']}'::uuid
                AND receipt.target_version={int(target['targetVersion'])}
                AND btrim(receipt.target_digest::text)='{target['targetDigest']}',
              'targetPayloadMatches',
                receipt.target_payload-'targetAnchorDigest'=
                  $r6d_target${target_json}$r6d_target$::jsonb,
              'canonicalTargetMatches',
                convert_from(receipt.target_canonical,'UTF8')::jsonb=
                  receipt.target_payload
                AND receipt.target_canonical=
                  ops.canonical_jsonb_v1(receipt.target_payload),
              'scopeMatches',receipt.scope_atoms=ARRAY[{scope_sql}]::text[],
              'scopeDigestMatches',receipt.scope_atoms_digest=encode(
                extensions.digest(
                  ops.canonical_jsonb_v1(to_jsonb(receipt.scope_atoms)),
                  'sha256'
                ),'hex'
              ),
              'affectedMatches',receipt.affected_ids=ARRAY[{affected_sql}]::uuid[],
              'affectedDigestMatches',receipt.affected_set_digest=encode(
                extensions.digest(
                  ops.canonical_jsonb_v1(to_jsonb(receipt.affected_ids)),
                  'sha256'
                ),'hex'
              ),
              'anchorMatches',
                anchor.id=receipt.anchor_id
                AND anchor.anchor_digest=receipt.anchor_digest
                AND anchor.target_kind=receipt.target_kind
                AND anchor.target_id=receipt.target_id
                AND anchor.target_version=receipt.target_version
                AND anchor.target_digest=receipt.target_digest,
              'holdMatches',
                hold.id=receipt.legal_hold_id AND hold.active
                AND hold.version=1 AND hold.object_type=receipt.target_kind
                AND hold.object_id=receipt.target_id
                AND hold.affected_ids=to_jsonb(receipt.affected_ids),
              'auditMatches',
                audit.id=receipt.audit_event_id
                AND audit.action='command.placeLegalHold'
                AND audit.object_type='LegalHold'
                AND audit.object_id=receipt.legal_hold_id::text
                AND audit.event_hash=receipt.audit_receipt_digest,
              'outboxMatches',
                event.id=receipt.outbox_event_id
                AND event.aggregate_type='legal_hold'
                AND event.aggregate_id=receipt.legal_hold_id::text
                AND event.aggregate_version=1
                AND event.event_type='legal_hold.placed.v2'
                AND event.payload->>'legalHoldId'=receipt.legal_hold_id::text
                AND event.payload->'target'=receipt.target_payload
                AND event.payload->'scopeAtoms'=to_jsonb(receipt.scope_atoms)
                AND event.payload->>'affectedSetDigest'=
                  btrim(receipt.affected_set_digest::text)
                AND event.payload->>'authorityReferenceDigest'=
                  btrim(receipt.authority_reference_digest::text)
                AND event.payload->>'holdReceiptDigest'=
                  btrim(receipt.receipt_digest::text),
              'receiptMatches',
                receipt.receipt_payload->>'schemaVersion'=
                  'legal-hold-placement-receipt.v2'
                AND receipt.receipt_payload->>'receiptId'=receipt.receipt_id::text
                AND receipt.receipt_payload->>'legalHoldId'=
                  receipt.legal_hold_id::text
                AND receipt.receipt_payload->'target'=receipt.target_payload
                AND receipt.receipt_payload->'scopeAtoms'=
                  to_jsonb(receipt.scope_atoms)
                AND receipt.receipt_payload->'affectedIds'=
                  to_jsonb(receipt.affected_ids)
                AND receipt.receipt_payload->>'requestId'=receipt.request_id::text
                AND receipt.receipt_payload->>'idempotencyKeySha256'=
                  btrim(receipt.idempotency_key_sha256::text)
                AND receipt.receipt_payload->>'auditEventId'=
                  receipt.audit_event_id::text
                AND receipt.receipt_payload ? 'proof'
                AND convert_from(receipt.receipt_canonical,'UTF8')::jsonb=
                  receipt.receipt_payload
                AND receipt.receipt_canonical=
                  ops.canonical_jsonb_v1(receipt.receipt_payload)
                AND receipt.receipt_digest=encode(
                  extensions.digest(receipt.receipt_canonical,'sha256'),'hex'
                ),
              'retentionMatches',
                receipt.retention_record_class='LEGAL_HOLD_GOVERNANCE'
                AND schedule.id=receipt.retention_schedule_id
                AND schedule.record_class=receipt.retention_record_class
                AND schedule.schedule_digest=receipt.retention_schedule_digest
            )
            FROM ops.legal_hold_placement_receipts_v2 AS receipt
            JOIN ops.legal_hold_target_anchors AS anchor
              ON anchor.id=receipt.anchor_id
            JOIN editorial.legal_holds AS hold
              ON hold.id=receipt.legal_hold_id
            JOIN ops.audit_events AS audit
              ON audit.id=receipt.audit_event_id
            JOIN ops.outbox AS event
              ON event.id=receipt.outbox_event_id
            JOIN ops.record_class_schedules AS schedule
              ON schedule.id=receipt.retention_schedule_id
            WHERE receipt.idempotency_key_sha256='{key_digest}'::char(64);
            """
        )
    )
    assert result.pop("receiptCount") == 1, (target["targetKind"], result)
    for count_key in ("holdCount", "anchorCount", "auditCount", "outboxCount"):
        assert result.pop(count_key) == 1, (target["targetKind"], count_key, result)
    assert all(result.values()), (target["targetKind"], result)


def assert_response_identity_receipt_graph():
    assert R6D_RESPONSE_ID is not None
    assert R6D_RESPONSE_EXCERPT_SHA256 is not None
    result = json.loads(
        postgres_value(
            f"""
            SELECT jsonb_build_object(
              'responseVersion',response.version,
              'responseStateMatches',
                response.organization_identity_status='SECOND_FACTOR_VERIFIED'
                AND response.publication_form='FULL'
                AND response.public_excerpt_sha256=
                  '{R6D_RESPONSE_EXCERPT_SHA256}'::char(64)
                AND response.excerpt_approved_at IS NOT NULL,
              'assertionCount',(
                SELECT count(*)
                FROM editorial.response_organization_identity_assertions_v1
                WHERE response_id=response.id
              ),
              'publicationIdentityCount',(
                SELECT count(*)
                FROM editorial.response_publication_identity_receipts_v1
                WHERE response_id=response.id
              ),
              'excerptCount',(
                SELECT count(*)
                FROM editorial.response_excerpt_approval_receipts_v2
                WHERE response_id=response.id
              ),
              'identityChainMatches',
                assertion.assertion_id=response.organization_identity_assertion_id
                AND assertion.response_version=2
                AND assertion.identity_status='SECOND_FACTOR_VERIFIED'
                AND assertion.publication_form='FULL'
                AND assertion.response_content_sha256=
                  response.response_content_sha256
                AND assertion.publication_consent_sha256=
                  response.publication_consent_sha256
                AND assertion.assertion_digest=encode(
                  extensions.digest(assertion.assertion_canonical,'sha256'),'hex'
                )
                AND publication.assertion_id=assertion.assertion_id
                AND publication.response_version=assertion.response_version
                AND publication.active
                AND publication.publication_form='FULL'
                AND publication.receipt_digest=assertion.receipt_digest
                AND publication.receipt_digest=encode(
                  extensions.digest(publication.receipt_canonical,'sha256'),'hex'
                ),
              'excerptChainMatches',
                excerpt.prior_response_version=2
                AND excerpt.response_version=3
                AND excerpt.response_version=response.version
                AND excerpt.publication_form='FULL'
                AND excerpt.excerpt_sha256=
                  '{R6D_RESPONSE_EXCERPT_SHA256}'::char(64)
                AND excerpt.identity_receipt_id=publication.receipt_id
                AND excerpt.identity_receipt_digest=publication.receipt_digest
                AND excerpt.receipt_digest=encode(
                  extensions.digest(excerpt.receipt_canonical,'sha256'),'hex'
                ),
              'identityAuditMatches',
                identity_audit.id=assertion.audit_event_id
                AND identity_audit.action=
                  'response.organization_identity.verify'
                AND identity_audit.event_hash=assertion.audit_receipt_digest,
              'excerptAuditMatches',
                excerpt_audit.id=excerpt.audit_event_id
                AND excerpt_audit.action='response.excerpt.approve',
              'identityOutboxMatches',
                identity_event.id=assertion.outbox_event_id
                AND identity_event.event_type=
                  'response.organization_identity_verified.v1'
                AND identity_event.aggregate_id=response.id::text
                AND identity_event.payload->>'identityAssertionDigest'=
                  btrim(assertion.assertion_digest::text),
              'excerptOutboxMatches',
                excerpt_event.id=excerpt.outbox_event_id
                AND excerpt_event.event_type='response.excerpt_approved.v2'
                AND excerpt_event.aggregate_id=response.id::text
                AND excerpt_event.payload->>'identityReceiptDigest'=
                  btrim(publication.receipt_digest::text)
                AND excerpt_event.payload->>'approvalReceiptDigest'=
                  btrim(excerpt.receipt_digest::text)
            )
            FROM editorial.responses AS response
            JOIN editorial.response_organization_identity_assertions_v1 AS assertion
              ON assertion.assertion_id=response.organization_identity_assertion_id
            JOIN editorial.response_publication_identity_receipts_v1 AS publication
              ON publication.assertion_id=assertion.assertion_id
            JOIN editorial.response_excerpt_approval_receipts_v2 AS excerpt
              ON excerpt.response_id=response.id
            JOIN ops.audit_events AS identity_audit
              ON identity_audit.id=assertion.audit_event_id
            JOIN ops.audit_events AS excerpt_audit
              ON excerpt_audit.id=excerpt.audit_event_id
            JOIN ops.outbox AS identity_event
              ON identity_event.id=assertion.outbox_event_id
            JOIN ops.outbox AS excerpt_event
              ON excerpt_event.id=excerpt.outbox_event_id
            WHERE response.id='{R6D_RESPONSE_ID}'::uuid;
            """
        )
    )
    assert result.pop("responseVersion") == 3, result
    for count_key in ("assertionCount", "publicationIdentityCount", "excerptCount"):
        assert result.pop(count_key) == 1, (count_key, result)
    assert all(result.values()), result


canonical_versions = {}
replay_case = None
created_proposal_id = None
created_proposal_digest = None
created_proposal_version = 1
created_assignment_id = None
created_assignment_version = 1
created_approval_digest = None
created_preview_id = None
created_preview_digest = None
created_reviewer_id = None
created_execution_id = None
created_execution_digest = None
created_decision_id = None
created_conflict_id = None
created_conflict_digest = None
created_conflict_policy_digest = None
r6d_legal_hold_case = None
r6d_response_identity_success = None
r6d_response_excerpt_success = None

for path_template, path_item, method, operation in operations:
    is_query = method == "GET"
    path = path_template
    path_values = {}
    raw_query_values = []
    parameters = path_item.get("parameters", []) + operation.get("parameters", [])
    for parameter in parameters:
        schema = resolve(parameter["schema"])
        if parameter["in"] == "path":
            value = example(schema, parameter["name"], operation["operationId"], is_query)
            if parameter["name"] == "proposalId" and created_proposal_id is not None:
                value = created_proposal_id
            if parameter["name"] == "handoffId" and operation["operationId"] == "decideJourneyHandoff" and JOURNEY_HANDOFF_ID:
                value = JOURNEY_HANDOFF_ID
            if parameter["name"] == "proposalId" and operation["operationId"] == "withdrawActionProposal":
                value = WITHDRAW_FIXTURE_PROPOSAL_ID
            if parameter["name"] == "proposalId" and operation["operationId"] == "withdrawActionDecision":
                value = WITHDRAW_DECISION_PROPOSAL_ID
            if parameter["name"] == "decisionId" and operation["operationId"] == "withdrawActionDecision":
                value = WITHDRAW_DECISION_ID
            if parameter["name"] == "executionId" and operation["operationId"] == "retryActionExecution":
                value = RETRY_FIXTURE_EXECUTION_ID
            if parameter["name"] == "runId" and operation["operationId"] == "cancelAgentRun":
                value = CANCEL_AGENT_RUN_ID
            elif parameter["name"] == "deliveryId" and operation["operationId"] in {"reconcileCommunicationDelivery", "cancelCommunicationDelivery"}:
                value = COMMUNICATION_RECONCILE_FIXTURE_ID
            elif parameter["name"] == "incidentId" and operation["operationId"] in {
                "getIncident", "triageIncident", "containIncident", "startIncidentRecovery",
                "resolveIncident", "closeIncidentPostmortem",
            }:
                value = INCIDENT_TRANSITION_FIXTURE_ID
            elif (
                parameter["name"] == "executionId"
                and operation["operationId"] != "retryActionExecution"
                and created_execution_id is not None
            ):
                value = created_execution_id
            elif parameter["name"] == "declarationId" and operation["operationId"] == "withdrawConflict" and created_conflict_id is not None:
                value = created_conflict_id
            path_values[parameter["name"]] = value
            path = path.replace("{" + parameter["name"] + "}", urllib.parse.quote(str(value), safe=""))
        elif parameter["in"] == "query" and parameter.get("required"):
            value = example(schema, parameter["name"], operation["operationId"], True)
            if parameter["name"] == "appealId" and operation["operationId"] == "getResponseAppealWorkspace":
                value = RESPONSE_APPEAL_FIXTURE_ID
            if parameter["name"] == "retentionRequestId" and operation["operationId"] == "getRetentionRequest":
                value = RETENTION_REQUEST_FIXTURE_ID
            raw_query_values.append((parameter["name"], str(value).lower() if isinstance(value, bool) else str(value)))
    raw_query = urllib.parse.urlencode(raw_query_values, quote_via=urllib.parse.quote)
    body = b""
    content_type = ""
    request_schema = operation.get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema")
    if request_schema is not None:
        request_value = example(request_schema, "request", operation["operationId"], False)
        if operation["operationId"] == "placeLegalHold":
            request_value = legal_hold_request(R6D_LEGAL_HOLD_TARGETS["CASE"])
        elif operation["operationId"] == "verifyResponseOrganizationIdentity":
            request_value = response_identity_request(R6D_RESPONSE_OFFICIAL_ASSERTION_ID)
        elif operation["operationId"] == "approveResponseExcerpt":
            request_value = response_excerpt_request(2)
            canonical_versions[("editorial.responses", R6D_RESPONSE_ID)] = 2
        if created_proposal_id is not None and operation["operationId"] in {
            "updateActionDraft", "previewActionDraft", "submitActionForReview",
            "claimActionReview", "submitActionDecision", "withdrawActionProposal",
            "withdrawActionDecision",
        }:
            if "proposalId" in request_value:
                request_value["proposalId"] = created_proposal_id
            if "expectedContentDigest" in request_value and created_proposal_digest is not None:
                request_value["expectedContentDigest"] = created_proposal_digest
            if "expectedVersion" in request_value and created_proposal_version > 1:
                request_value["expectedVersion"] = created_proposal_version
            if "expectedProposalVersion" in request_value:
                request_value["expectedProposalVersion"] = created_proposal_version
            if "expectedAssignmentVersion" in request_value:
                request_value["expectedAssignmentVersion"] = created_assignment_version
            if "expectedApprovalDigest" in request_value and created_approval_digest is not None:
                request_value["expectedApprovalDigest"] = created_approval_digest
            if "assignmentId" in request_value and created_assignment_id is not None:
                request_value["assignmentId"] = created_assignment_id
            if "previewId" in request_value and created_preview_id is not None:
                request_value["previewId"] = created_preview_id
            if "previewDigest" in request_value and created_preview_digest is not None:
                request_value["previewDigest"] = created_preview_digest
        if "executionId" in request_value and operation["operationId"] == "retryActionExecution":
            request_value["executionId"] = RETRY_FIXTURE_EXECUTION_ID
        elif "executionId" in request_value and created_execution_id is not None:
            request_value["executionId"] = created_execution_id
        if operation["operationId"] == "cancelAgentRun":
            # The control seed owns one durable run; a generic UUID would
            # exercise RESOURCE_NOT_FOUND/VERSION_CONFLICT instead of the
            # cancellation owner receipt contract.
            request_value["runId"] = CANCEL_AGENT_RUN_ID
        if operation["operationId"] == "withdrawActionProposal":
            request_value["proposalId"] = WITHDRAW_FIXTURE_PROPOSAL_ID
            request_value["expectedProposalVersion"] = 1
            request_value["expectedStateVersion"] = 1
            request_value["expectedContentDigest"] = WITHDRAW_FIXTURE_CONTENT_DIGEST
        if operation["operationId"] == "withdrawActionDecision":
            request_value["decisionId"] = WITHDRAW_DECISION_ID
            request_value["proposalId"] = WITHDRAW_DECISION_PROPOSAL_ID
            state_version, assignment_version, approval_digest, decision_receipt = postgres_value(
                f"""
                    SELECT v.state_version,a.version,btrim(v.approval_digest::text),
                           btrim(d.receipt_digest::text)
                      FROM ops.action_proposals p
                      JOIN ops.action_proposal_versions v
                        ON v.proposal_id=p.id AND v.version=p.current_version
                      JOIN ops.action_decisions d
                        ON d.id='{WITHDRAW_DECISION_ID}'::uuid AND d.proposal_id=p.id
                      JOIN ops.action_review_assignments a ON a.id=d.assignment_id
                     WHERE p.id='{WITHDRAW_DECISION_PROPOSAL_ID}'::uuid;
                """
            ).split("|")
            request_value["expectedProposalVersion"] = 1
            request_value["expectedProposalStateVersion"] = int(state_version)
            request_value["expectedAssignmentVersion"] = int(assignment_version)
            request_value["expectedApprovalDigest"] = approval_digest
            request_value["expectedDecisionReceiptDigest"] = decision_receipt
        if operation["operationId"] == "decideJourneyHandoff":
            # ACKNOWLEDGE is intentionally reason-free in the owner contract;
            # only DECLINE carries a typed reason code and reason payload.
            if JOURNEY_HANDOFF_ID:
                request_value["handoffId"] = JOURNEY_HANDOFF_ID
            request_value["expectedHandoffVersion"] = JOURNEY_HANDOFF_VERSION
            request_value["expectedBindingDigest"] = JOURNEY_HANDOFF_BINDING
            request_value["decision"] = "ACKNOWLEDGE"
            request_value["reasonCode"] = None
            request_value["reason"] = None
        if "deliveryId" in request_value and operation["operationId"] in {"reconcileCommunicationDelivery", "cancelCommunicationDelivery"}:
            request_value["deliveryId"] = COMMUNICATION_RECONCILE_FIXTURE_ID
        if operation["operationId"] == "reconcileCommunicationDelivery":
            request_value["expectedVersion"] = 2
            request_value["resolution"] = {"kind": "NOT_TRANSMITTED"}
            request_value["evidence"] = {"kind": "NO_PROVIDER_ATTEMPT"}
        elif operation["operationId"] == "cancelCommunicationDelivery":
            request_value["expectedVersion"] = 3
        elif operation["operationId"] == "transitionResponseAppeal":
            request_value["appealId"] = RESPONSE_APPEAL_FIXTURE_ID
            request_value["expectedDecisionSequence"] = 0
            request_value["transition"] = "START_REVIEW"
            request_value["evidenceReceiptIds"] = []
            request_value["task"] = None
        elif operation["operationId"] == "decideResponseExtension":
            request_value["extensionRequestId"] = RESPONSE_EXTENSION_FIXTURE_ID
            request_value["calendarVersionId"] = CALENDAR_FIXTURE_ID
            request_value["newDueAt"] = "2099-01-01T00:00:00Z"
        elif operation["operationId"] == "transitionRetentionRequest":
            request_value["retentionRequestId"] = RETENTION_TRANSITION_FIXTURE_ID
            request_value["expectedDecisionVersion"] = 0
            request_value["transition"] = "START_REVIEW"
        elif operation["operationId"] == "withdrawConflict" and created_conflict_id is not None:
            request_value["declarationId"] = created_conflict_id
            request_value["expectedDeclarationDigest"] = created_conflict_digest
            request_value["expectedPolicyDigest"] = created_conflict_policy_digest
        if operation["operationId"] == "retryJobs":
            request_value["jobIds"] = [
                str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:bulk-job"))
            ]
        if operation["operationId"] == "retryActionExecution":
            request_value["reasonCode"] = request_value["safeRetryProof"]["kind"]
        if operation["operationId"] == "saveResponseRequestDraft":
            request_value["recipientEmail"] = "updated-response-recipient@example.test"
            request_value["questions"] = ["Updated canonical response question"]
        if operation["operationId"] in {
            "triageIncident", "containIncident", "startIncidentRecovery",
            "resolveIncident", "closeIncidentPostmortem",
        }:
            request_value["incidentId"] = INCIDENT_TRANSITION_FIXTURE_ID
            if operation["operationId"] == "triageIncident":
                request_value["severity"] = "SEV3"
                request_value["affectedCapabilities"] = ["control"]
            if "nextUpdateAt" in request_value:
                request_value["nextUpdateAt"] = "2099-01-01T00:00:00Z"
            request_value["expectedVersion"] = {
                "triageIncident": 1,
                "containIncident": 2,
                "startIncidentRecovery": 3,
                "resolveIncident": 4,
                "closeIncidentPostmortem": 5,
            }[operation["operationId"]]
        if operation["operationId"] == "approveSchemaMapping":
            request_value["mappingDigest"] = sha256(
                json.dumps(
                    request_value["fieldMappings"],
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode()
            )
        if operation["operationId"] == "promoteResearchArtifactToEvidence":
            # This command is intentionally backed by a complete upstream
            # FETCH_URL lineage fixture.  Generic OpenAPI examples cannot
            # invent a run/turn/tool/fetch/artifact tuple whose digests and
            # current GRANT rights are mutually bound.
            request_value["agentRunId"] = PROMOTION_AGENT_RUN_ID
            request_value["researchArtifact"] = {
                "id": PROMOTION_ARTIFACT_ID,
                "assetId": PROMOTION_ASSET_ID,
                "assetRevision": "1",
                "artifactSha256": PROMOTION_ARTIFACT_SHA256,
                "contentSha256": PROMOTION_SELECTED_CONTENT_SHA256,
                "sourceFetchId": PROMOTION_FETCH_ID,
                "providerTurnId": PROMOTION_TURN_ID,
                "toolCallId": PROMOTION_TOOL_ID,
            }
            request_value["rightsDecision"] = {
                "id": PROMOTION_RIGHTS_ID,
                "version": 1,
                "decisionSha256": PROMOTION_RIGHTS_SHA256,
            }
            request_value["evidence"] = {
                "evidenceType": "SOURCE_DOCUMENT",
                "title": "Control promotion evidence",
                "description": "Canonical clean research artifact promotion fixture",
                "classification": "PUBLIC",
                "verificationStatus": "PENDING",
                "publicExcerpt": "gurinnae control promotion fixture",
            }
            request_value["selectedSegments"] = [{
                "ordinal": 0,
                "locator": {
                    "kind": "HTML_CSS_SELECTOR",
                    "value": "https://example.test/gurinnae/control-promotion-fixture",
                    "locatorSha256": PROMOTION_LOCATOR_SHA256,
                },
                "selectedContentSha256": PROMOTION_SELECTED_CONTENT_SHA256,
                "selectionPurpose": "PRIMARY_EVIDENCE",
            }]
            request_value["reason"] = "Promote the verified clean research artifact into case evidence"
        concurrency = CONCURRENCY.get(operation["operationId"])
        if concurrency is not None:
            if concurrency["guardRelation"] == "editorial.cases":
                canonical_identity = FIXTURE_UUIDS["caseId"]
            else:
                identity_name = next(
                    name for name in concurrency["requestPlaceholders"] if name != concurrency["versionField"]
                )
                canonical_identity = request_value.get(identity_name, path_values.get(identity_name))
                assert canonical_identity is not None, (operation["operationId"], identity_name)
            canonical_key = (concurrency["guardRelation"], str(canonical_identity))
            request_value[concurrency["versionField"]] = canonical_versions.get(canonical_key, 1)
        # The promotion owner intentionally is not in the generic optimistic
        # concurrency catalog: its case version is advanced by the earlier
        # evidence/review commands in this witness.  Keep the fixture bound to
        # that authoritative post-review version instead of emitting the
        # schema minimum (1), which would exercise only a stale-version error.
        if operation["operationId"] == "promoteResearchArtifactToEvidence":
            request_value["expectedCaseVersion"] = 14
        if operation["operationId"] == "submitActionDecision":
            request_value["decision"]["assurance"] = "STEP_UP"
            request_value["decision"]["stepUpAuthorizationId"] = STEP_UP_AUTHORIZATION_ID
            request_value["decision"]["assertedActionDigest"] = STEP_UP_ACTION_DIGEST
            request_value["decision"]["stepUpAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        body = json.dumps(request_value, ensure_ascii=False, separators=(",", ":")).encode()
        content_type = "application/json"
    idempotency_key = str(uuid.uuid4()) if method != "GET" else None
    special_step_up_authorization_id = None
    special_action_digest = None
    if operation["operationId"] == "placeLegalHold":
        idempotency_key = str(
            uuid.uuid5(uuid.NAMESPACE_URL, "gurine:r6d:place-legal-hold:CASE")
        )
        special_step_up_authorization_id, special_action_digest = (
            prepare_legal_hold_authority(request_value["target"], idempotency_key)
        )
    elif operation["operationId"] == "verifyResponseOrganizationIdentity":
        idempotency_key = str(
            uuid.uuid5(uuid.NAMESPACE_URL, "gurine:r6d:verify-response-identity:positive")
        )
        special_step_up_authorization_id = str(
            uuid.uuid5(
                uuid.NAMESPACE_URL,
                f"gurine:r6d:verify-response-identity:step-up:{idempotency_key}",
            )
        )
        special_action_digest = prepare_step_up_authority(
            operation["operationId"], idempotency_key, special_step_up_authorization_id
        )
        identity_state_before = response_identity_state_digest()
        status, error_body, _ = invoke_command(
            "approveResponseExcerpt",
            response_excerpt_request(1),
            idempotency_key=str(
                uuid.uuid5(
                    uuid.NAMESPACE_URL,
                    "gurine:r6d:response-excerpt:identity-not-verified",
                )
            ),
        )
        assert status == 422, (
            "approveResponseExcerpt-before-identity",
            status,
            error_body.decode(errors="replace"),
        )
        for negative_name, source_id, verification_method in (
            (
                "raw-verification-id",
                R6D_RESPONSE_RAW_VERIFICATION_ID,
                "OFFICIAL_DOMAIN_EMAIL",
            ),
            (
                "method-mismatch",
                R6D_RESPONSE_OFFICIAL_ASSERTION_ID,
                "OFFICIAL_DOCUMENT",
            ),
            (
                "revoked-official-assertion",
                R6D_RESPONSE_REVOKED_ASSERTION_ID,
                "OFFICIAL_DOMAIN_EMAIL",
            ),
        ):
            negative_key = str(
                uuid.uuid5(
                    uuid.NAMESPACE_URL,
                    f"gurine:r6d:verify-response-identity:{negative_name}",
                )
            )
            negative_step_up_id = str(
                uuid.uuid5(
                    uuid.NAMESPACE_URL,
                    f"gurine:r6d:verify-response-identity:step-up:{negative_key}",
                )
            )
            negative_action_digest = prepare_step_up_authority(
                operation["operationId"], negative_key, negative_step_up_id
            )
            status, error_body, _ = invoke_command(
                operation["operationId"],
                response_identity_request(source_id, verification_method),
                idempotency_key=negative_key,
                step_up_authorization_id=negative_step_up_id,
                action_digest=negative_action_digest,
            )
            assert status == 422, (
                f"verifyResponseOrganizationIdentity-{negative_name}",
                status,
                error_body.decode(errors="replace"),
            )
        assert response_identity_state_digest() == identity_state_before
    # A withdrawal is actor-bound to the immutable original APPROVE record.
    # The pending-quorum fixture is owned by ACTOR; the reviewer discovered
    # through the separately created proposal must never be substituted here.
    request_actor_id = created_reviewer_id if operation["operationId"] in {
        "claimActionReview", "submitActionDecision"
    } and created_reviewer_id is not None else ACTOR
    transport_request_id = str(uuid.uuid4())
    token = assertion(
        operation,
        method,
        path,
        raw_query,
        body,
        content_type,
        idempotency_key,
        request_actor_id,
        step_up_authorization_id=special_step_up_authorization_id,
        action_digest=special_action_digest,
    )
    url = BASE + path + ("?" + raw_query if raw_query else "")
    headers = {
        "X-Gurine-Actor-Assertion": token,
        "X-Request-ID": transport_request_id,
    }
    if content_type:
        headers["Content-Type"] = content_type
    if idempotency_key:
        headers["Idempotency-Key"] = idempotency_key
    request = urllib.request.Request(url, data=body if body else None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            expected = int(next(code for code in operation["responses"] if code.startswith("2")))
            assert response.status == expected, (operation["operationId"], response.status, expected)
            assert response.headers["Cache-Control"] == "no-store"
            response_body = response.read()
    except urllib.error.HTTPError as error:
        raise AssertionError((operation["operationId"], method, path, body.decode(), error.code, error.read().decode())) from error
    if request_schema is not None and concurrency is not None:
        canonical_versions[canonical_key] = request_value[concurrency["versionField"]] + 1
    if response.status == 204:
        assert response_body == b""
        continue
    parsed = json.loads(response_body)
    response_schema = operation["responses"][str(response.status)]["content"]["application/json"]["schema"]
    Draft202012Validator(response_schema, resolver=resolver).validate(parsed)
    if operation["operationId"] == "placeLegalHold":
        r6d_legal_hold_case = {
            "request": request_value,
            "idempotencyKey": idempotency_key,
            "transportRequestId": transport_request_id,
            "stepUpAuthorizationId": special_step_up_authorization_id,
            "actionDigest": special_action_digest,
            "status": response.status,
            "body": response_body,
            "parsed": parsed,
        }
    elif operation["operationId"] == "verifyResponseOrganizationIdentity":
        r6d_response_identity_success = {
            "request": request_value,
            "idempotencyKey": idempotency_key,
            "transportRequestId": transport_request_id,
            "stepUpAuthorizationId": special_step_up_authorization_id,
            "actionDigest": special_action_digest,
            "status": response.status,
            "body": response_body,
            "parsed": parsed,
        }
    elif operation["operationId"] == "approveResponseExcerpt":
        r6d_response_excerpt_success = {
            "request": request_value,
            "idempotencyKey": idempotency_key,
            "transportRequestId": transport_request_id,
            "status": response.status,
            "body": response_body,
            "parsed": parsed,
        }
    if operation["operationId"] == "createActionProposal":
        created_proposal_id = parsed["proposal"]["proposalId"]
        created_proposal_digest = parsed["proposal"]["contentDigest"]
        print(f"CONTROL_FLOW_CREATED_PROPOSAL={created_proposal_id}", flush=True)
    elif operation["operationId"] == "updateActionDraft":
        created_proposal_version = parsed["proposal"]["version"]
        created_proposal_digest = parsed["proposal"]["contentDigest"]
    elif operation["operationId"] == "previewActionDraft":
        created_preview_id = parsed["preview"]["previewId"]
        created_preview_digest = parsed["preview"]["previewDigest"]
        created_approval_digest = parsed["preview"]["approvalDigest"]
    elif operation["operationId"] == "submitActionForReview":
        created_assignment_id = parsed["assignments"][0]["assignmentId"]
        created_assignment_version = parsed["assignments"][0]["version"]
        created_approval_digest = parsed["assignments"][0]["approvalDigest"]
        created_reviewer_id = parsed["assignments"][0]["reviewer"]["actorId"]
    elif operation["operationId"] == "submitActionDecision":
        created_decision_id = parsed.get("decision", {}).get("decisionId")
        authorization = parsed.get("executionAuthorization")
        if authorization is not None:
            created_execution_id = authorization["executionId"]
            created_execution_digest = authorization["executionDigest"]
            # Observe the atomic approval closure before the later
            # cancelActionExecution operation deliberately transitions this
            # same aggregate to CANCELLED.
            approval_execution_closure = postgres_value(
                f"""
                SELECT
                  e.state,
                  e.current_generation,
                  a.executor_id,
                  a.execution_digest,
                  t.attempt_state,
                  r.receipt_kind,
                  r.aggregate_state,
                  o.event_type,
                  (o.payload->>'executionDigest'=a.execution_digest::text)::text,
                  (d.execution_id=e.id AND d.receipt_digest=a.terminal_decision_receipt_digest)::text
                  FROM ops.in_flight_effects e
                  JOIN ops.execution_authorizations a
                    ON a.execution_id=e.id AND a.generation=e.current_generation
                  JOIN ops.execution_attempts t
                    ON t.execution_id=e.id AND t.generation=e.current_generation
                  JOIN ops.execution_receipts r
                    ON r.execution_id=e.id AND r.receipt_sequence=1
                  JOIN ops.outbox o ON o.id=a.outbox_id
                  JOIN ops.action_decisions d ON d.id=a.terminal_decision_id
                 WHERE e.id='{created_execution_id}'::uuid;
                """
            ).split("|")
            assert approval_execution_closure == [
                "QUEUED",
                "1",
                "createHypothesis",
                created_execution_digest,
                "QUEUED",
                "AUTHORIZATION_QUEUED",
                "QUEUED",
                "action.execution_authorized.v1",
                "true",
                "true",
            ], approval_execution_closure
    elif operation["operationId"] == "declareConflict":
        created_conflict_id = parsed["declaration"]["declarationId"]
        created_conflict_digest = parsed["declaration"]["declarationDigest"]
        created_conflict_policy_digest = parsed["declaration"]["policyDigest"]
    if operation["operationId"] == "getAuditExport":
        assert parsed["downloadUrl"] is None, parsed["downloadUrl"]
    if operation["operationId"] == "createAccessRequest":
        replay_case = {
            "operation": operation,
            "method": method,
            "path": path,
            "raw_query": raw_query,
            "body": body,
            "content_type": content_type,
            "idempotency_key": idempotency_key,
            "status": response.status,
            "response_body": response_body,
        }

assert created_proposal_id is not None
assert created_execution_id is not None
execution_closure = postgres_value(
    f"""
    SELECT
      e.state,
      e.current_generation,
      a.executor_id,
      a.execution_digest,
      t.attempt_state,
      r.receipt_kind,
      r.aggregate_state,
      o.event_type,
      (o.payload->>'executionDigest'=a.execution_digest::text)::text,
      (d.execution_id=e.id AND d.receipt_digest=a.terminal_decision_receipt_digest)::text
      FROM ops.in_flight_effects e
      JOIN ops.execution_authorizations a
        ON a.execution_id=e.id AND a.generation=e.current_generation
      JOIN ops.execution_attempts t
        ON t.execution_id=e.id AND t.generation=e.current_generation
      JOIN ops.execution_receipts r
        ON r.execution_id=e.id AND r.receipt_sequence=1
      JOIN ops.outbox o ON o.id=a.outbox_id
      JOIN ops.action_decisions d ON d.id=a.terminal_decision_id
     WHERE e.id='{created_execution_id}'::uuid;
    """
).split("|")
assert execution_closure == [
    "CANCELLED",
    "1",
    "createHypothesis",
    created_execution_digest,
    "CANCELLED",
    "AUTHORIZATION_QUEUED",
    "QUEUED",
    "action.execution_authorized.v1",
    "true",
    "true",
], execution_closure

withdrawal_closure = postgres_value(
    f"""
    SELECT
      v.state,
      v.state_version,
      original.decision_kind,
      withdrawal.record_kind,
      withdrawal.decision_kind,
      withdrawal.resulting_proposal_state,
      withdrawal.counts_toward_quorum::text,
      (replacement.replacement_of_assignment_id=original.assignment_id)::text,
      audit.action,
      outbox.event_type,
      (NOT EXISTS (
        SELECT 1 FROM ops.execution_authorizations authz
         WHERE authz.proposal_id=p.id
      ))::text
      FROM ops.action_proposals p
      JOIN ops.action_proposal_versions v
        ON v.proposal_id=p.id AND v.version=p.current_version
      JOIN ops.action_decisions original
        ON original.id='{WITHDRAW_DECISION_ID}'::uuid
       AND original.proposal_id=p.id
      JOIN ops.action_decisions withdrawal
        ON withdrawal.withdrawn_decision_id=original.id
       AND withdrawal.proposal_id=p.id
      JOIN ops.action_review_assignments replacement
        ON replacement.replacement_of_assignment_id=original.assignment_id
      JOIN ops.audit_events audit ON audit.id=withdrawal.audit_event_id
      JOIN ops.outbox outbox
        ON outbox.aggregate_id=withdrawal.id::text
       AND outbox.event_type='action.decision_withdrawn.v1'
     WHERE p.id='{WITHDRAW_DECISION_PROPOSAL_ID}'::uuid;
    """
).split("|")
assert withdrawal_closure == [
    "PENDING_QUORUM",
    "5",
    "APPROVE",
    "APPROVAL_WITHDRAWAL",
    "APPROVAL_WITHDRAWN",
    "PENDING_QUORUM",
    "false",
    "true",
    "ACTION_DECISION_WITHDRAWN",
    "action.decision_withdrawn.v1",
    "true",
], withdrawal_closure

sealed_rows = postgres_value(
    f"""
    SELECT
      convert_from(substring(v.payload_encrypted FROM 1 FOR 13),'UTF8'),
      convert_from(substring(v.rationale_encrypted FROM 1 FOR 13),'UTF8'),
      position(convert_to('updateActionDraft','UTF8') IN v.payload_encrypted),
      position(convert_to('updateActionDraft','UTF8') IN v.rationale_encrypted)
      FROM ops.action_proposals p
      JOIN ops.action_proposal_versions v
        ON v.proposal_id=p.id AND v.version=p.current_version
     WHERE p.id='{created_proposal_id}'::uuid;
    """
).split("|")
assert sealed_rows == ["gurine-fe-v1.", "gurine-fe-v1.", "0", "0"], sealed_rows

accepted_communication = postgres_value(
    """
    SELECT
      p.action_kind,
      s.payload->>'channel',
      s.payload->>'draftText',
      s.payload->'recipientBinding'->>'endpointId',
      convert_from(substring(v.payload_encrypted FROM 1 FOR 13),'UTF8'),
      position(convert_to('approval-recipient@example.test','UTF8') IN v.payload_encrypted),
      s.materialized_target_id::text,
      s.materialized_action_proposal_id::text,
      p.id::text,
      btrim(s.materialized_target_digest::text),
      btrim(v.content_digest::text)
      FROM ops.agent_suggestions s
      JOIN ops.action_proposals p ON p.id=s.materialized_action_proposal_id
      JOIN ops.action_proposal_versions v
        ON v.proposal_id=p.id AND v.version=p.current_version
     WHERE s.id='30ddda7c-3ee4-52a6-af23-f09f1f8cd9d4'::uuid;
    """
).split("|")
assert accepted_communication[:6] == [
    "COMMUNICATION",
    "SMTP_EMAIL",
    "Please review the cited evidence before the response deadline.",
    "2ca911e8-5871-50f2-b49f-587f5cb7f86f",
    "gurine-fe-v1.",
    "0",
], accepted_communication[:6]
assert accepted_communication[6] == accepted_communication[8], accepted_communication
assert accepted_communication[7] == accepted_communication[8], accepted_communication
assert accepted_communication[9] == accepted_communication[10], accepted_communication

assert replay_case is not None
token = assertion(
    replay_case["operation"],
    replay_case["method"],
    replay_case["path"],
    replay_case["raw_query"],
    replay_case["body"],
    replay_case["content_type"],
    replay_case["idempotency_key"],
)
replay_headers = {
    "X-Gurine-Actor-Assertion": token,
    "X-Request-ID": str(uuid.uuid4()),
    "Content-Type": replay_case["content_type"],
    "Idempotency-Key": replay_case["idempotency_key"],
}
replay_request = urllib.request.Request(
    BASE + replay_case["path"],
    data=replay_case["body"],
    headers=replay_headers,
    method=replay_case["method"],
)
with urllib.request.urlopen(replay_request, timeout=20) as replay_response:
    assert replay_response.status == replay_case["status"]
    assert replay_response.headers["Idempotent-Replay"] == "true"
    assert replay_response.read() == replay_case["response_body"]


def expect_command_error(operation_id, request_value, expected_status, path_values=None, idempotency_key=None):
    status, response_body, _ = invoke_command(
        operation_id,
        request_value,
        path_values=path_values,
        idempotency_key=idempotency_key,
    )
    assert status == expected_status, (
        operation_id,
        status,
        expected_status,
        response_body.decode(errors="replace"),
    )


def execute_command(operation_id, request_value, path_values=None, idempotency_key=None):
    status, body, _ = invoke_command(
        operation_id,
        request_value,
        path_values=path_values,
        idempotency_key=idempotency_key,
    )
    if status >= 400:
        raise AssertionError(
            (operation_id, "unexpected command error", status, body.decode(errors="replace"))
        )
    return status, body


def execute_validated_command(
    operation_id,
    request_value,
    *,
    idempotency_key,
    transport_request_id,
    step_up_authorization_id=None,
    action_digest=None,
):
    status, body, headers = invoke_command(
        operation_id,
        request_value,
        idempotency_key=idempotency_key,
        step_up_authorization_id=step_up_authorization_id,
        action_digest=action_digest,
        transport_request_id=transport_request_id,
    )
    _, _, _, operation = operation_entry(operation_id)
    success_status = int(next(code for code in operation["responses"] if code.startswith("2")))
    assert status == success_status, (
        operation_id,
        status,
        success_status,
        body.decode(errors="replace"),
    )
    parsed = json.loads(body)
    response_schema = operation["responses"][str(status)]["content"]["application/json"][
        "schema"
    ]
    Draft202012Validator(response_schema, resolver=resolver).validate(parsed)
    return status, body, headers, parsed


def response_header(headers, name):
    expected = name.lower()
    return next((value for key, value in headers.items() if key.lower() == expected), None)


# R6d legal-hold and response-identity owners must remain correct beyond the
# generic operation sweep.  Cross the expired HTTP cache to exercise the
# immutable owner receipt, then separately prove the ordinary transport replay.
assert r6d_legal_hold_case is not None
assert r6d_response_identity_success is not None
assert r6d_response_excerpt_success is not None

case_target = current_legal_hold_target(R6D_LEGAL_HOLD_TARGETS["CASE"])
case_key = r6d_legal_hold_case["idempotencyKey"]
assert_legal_hold_receipt_graph(case_target, case_key)
case_state_before_replay = legal_hold_state_digest(case_key)
assert case_state_before_replay
expire_http_idempotency("placeLegalHold", case_key)
_, case_owner_body, case_owner_headers, _ = execute_validated_command(
    "placeLegalHold",
    r6d_legal_hold_case["request"],
    idempotency_key=case_key,
    transport_request_id=r6d_legal_hold_case["transportRequestId"],
    step_up_authorization_id=r6d_legal_hold_case["stepUpAuthorizationId"],
    action_digest=r6d_legal_hold_case["actionDigest"],
)
assert case_owner_body == r6d_legal_hold_case["body"]
assert response_header(case_owner_headers, "Idempotent-Replay") is None
assert legal_hold_state_digest(case_key) == case_state_before_replay
_, case_transport_body, case_transport_headers, _ = execute_validated_command(
    "placeLegalHold",
    r6d_legal_hold_case["request"],
    idempotency_key=case_key,
    transport_request_id=r6d_legal_hold_case["transportRequestId"],
    step_up_authorization_id=r6d_legal_hold_case["stepUpAuthorizationId"],
    action_digest=r6d_legal_hold_case["actionDigest"],
)
assert case_transport_body == case_owner_body
assert response_header(case_transport_headers, "Idempotent-Replay") == "true"

expire_http_idempotency("placeLegalHold", case_key)
divergent_case_request = dict(r6d_legal_hold_case["request"])
divergent_case_request["reason"] = "Divergent body must never reuse a legal-hold owner receipt"
case_state_before_divergence = legal_hold_state_digest(case_key)
status, _, _ = invoke_command(
    "placeLegalHold",
    divergent_case_request,
    idempotency_key=case_key,
    step_up_authorization_id=r6d_legal_hold_case["stepUpAuthorizationId"],
    action_digest=r6d_legal_hold_case["actionDigest"],
    transport_request_id=r6d_legal_hold_case["transportRequestId"],
)
assert status == 409, status
assert legal_hold_state_digest(case_key) == case_state_before_divergence

legal_hold_results = {"CASE": case_key}
for target_kind in sorted(R6D_LEGAL_HOLD_KINDS - {"CASE"}):
    target = current_legal_hold_target(R6D_LEGAL_HOLD_TARGETS[target_kind])
    idempotency_key = str(
        uuid.uuid5(uuid.NAMESPACE_URL, f"gurine:r6d:place-legal-hold:{target_kind}")
    )
    step_up_id, action_digest = prepare_legal_hold_authority(target, idempotency_key)
    execute_validated_command(
        "placeLegalHold",
        legal_hold_request(target),
        idempotency_key=idempotency_key,
        transport_request_id=str(
            uuid.uuid5(
                uuid.NAMESPACE_URL,
                f"gurine:r6d:place-legal-hold:request:{target_kind}",
            )
        ),
        step_up_authorization_id=step_up_id,
        action_digest=action_digest,
    )
    assert_legal_hold_receipt_graph(target, idempotency_key)
    legal_hold_results[target_kind] = idempotency_key
assert set(legal_hold_results) == R6D_LEGAL_HOLD_KINDS

stale_target = current_legal_hold_target(R6D_LEGAL_HOLD_TARGETS["EVIDENCE"])
stale_target["targetVersion"] += 1
stale_key = str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:r6d:place-legal-hold:stale"))
stale_step_up_id, stale_action_digest = prepare_legal_hold_authority(stale_target, stale_key)
legal_hold_before_stale = legal_hold_global_state_digest()
status, _, _ = invoke_command(
    "placeLegalHold",
    legal_hold_request(stale_target),
    idempotency_key=stale_key,
    step_up_authorization_id=stale_step_up_id,
    action_digest=stale_action_digest,
    transport_request_id=str(
        uuid.uuid5(uuid.NAMESPACE_URL, "gurine:r6d:place-legal-hold:stale:request")
    ),
)
assert status == 409, status
assert legal_hold_global_state_digest() == legal_hold_before_stale

# The generic sweep has already performed the positive identity transition and
# the FULL excerpt approval in that order.  Validate their exact receipt graph,
# then cross the HTTP cache for both owners and prove divergent keys fail closed.
assert_response_identity_receipt_graph()
identity_key = r6d_response_identity_success["idempotencyKey"]
identity_state_before_replay = response_identity_state_digest()
expire_http_idempotency("verifyResponseOrganizationIdentity", identity_key)
_, identity_owner_body, identity_owner_headers, _ = execute_validated_command(
    "verifyResponseOrganizationIdentity",
    r6d_response_identity_success["request"],
    idempotency_key=identity_key,
    transport_request_id=r6d_response_identity_success["transportRequestId"],
    step_up_authorization_id=r6d_response_identity_success["stepUpAuthorizationId"],
    action_digest=r6d_response_identity_success["actionDigest"],
)
assert identity_owner_body == r6d_response_identity_success["body"]
assert response_header(identity_owner_headers, "Idempotent-Replay") is None
assert response_identity_state_digest() == identity_state_before_replay
_, identity_transport_body, identity_transport_headers, _ = execute_validated_command(
    "verifyResponseOrganizationIdentity",
    r6d_response_identity_success["request"],
    idempotency_key=identity_key,
    transport_request_id=r6d_response_identity_success["transportRequestId"],
    step_up_authorization_id=r6d_response_identity_success["stepUpAuthorizationId"],
    action_digest=r6d_response_identity_success["actionDigest"],
)
assert identity_transport_body == identity_owner_body
assert response_header(identity_transport_headers, "Idempotent-Replay") == "true"

expire_http_idempotency("verifyResponseOrganizationIdentity", identity_key)
divergent_identity_request = dict(r6d_response_identity_success["request"])
divergent_identity_request["reason"] = "Divergent identity reason must not replay"
identity_state_before_divergence = response_identity_state_digest()
status, _, _ = invoke_command(
    "verifyResponseOrganizationIdentity",
    divergent_identity_request,
    idempotency_key=identity_key,
    step_up_authorization_id=r6d_response_identity_success["stepUpAuthorizationId"],
    action_digest=r6d_response_identity_success["actionDigest"],
    transport_request_id=r6d_response_identity_success["transportRequestId"],
)
assert status == 409, status
assert response_identity_state_digest() == identity_state_before_divergence

excerpt_key = r6d_response_excerpt_success["idempotencyKey"]
excerpt_state_before_replay = response_identity_state_digest()
expire_http_idempotency("approveResponseExcerpt", excerpt_key)
_, excerpt_owner_body, excerpt_owner_headers, _ = execute_validated_command(
    "approveResponseExcerpt",
    r6d_response_excerpt_success["request"],
    idempotency_key=excerpt_key,
    transport_request_id=r6d_response_excerpt_success["transportRequestId"],
)
assert excerpt_owner_body == r6d_response_excerpt_success["body"]
assert response_header(excerpt_owner_headers, "Idempotent-Replay") is None
assert response_identity_state_digest() == excerpt_state_before_replay
_, excerpt_transport_body, excerpt_transport_headers, _ = execute_validated_command(
    "approveResponseExcerpt",
    r6d_response_excerpt_success["request"],
    idempotency_key=excerpt_key,
    transport_request_id=r6d_response_excerpt_success["transportRequestId"],
)
assert excerpt_transport_body == excerpt_owner_body
assert response_header(excerpt_transport_headers, "Idempotent-Replay") == "true"

expire_http_idempotency("approveResponseExcerpt", excerpt_key)
divergent_excerpt_request = dict(r6d_response_excerpt_success["request"])
divergent_excerpt_request["reason"] = "Divergent excerpt reason must not replay"
excerpt_state_before_divergence = response_identity_state_digest()
status, _, _ = invoke_command(
    "approveResponseExcerpt",
    divergent_excerpt_request,
    idempotency_key=excerpt_key,
    transport_request_id=r6d_response_excerpt_success["transportRequestId"],
)
assert status == 409, status
assert response_identity_state_digest() == excerpt_state_before_divergence
assert_response_identity_receipt_graph()
print(
    "R6D_CONTROL_RUNTIME: PASS legal-hold-10-kind+owner-replay+stale-zero-write+"
    "response-identity+full-excerpt",
    flush=True,
)


expect_command_error(
    "assignCase",
    {"caseId": FIXTURE_UUIDS["caseId"], "assigneeUserId": FIXTURE_UUIDS["userId"], "expectedVersion": 1},
    409,
)
expect_command_error(
    "retryJob",
    {"jobId": str(uuid.uuid4()), "reason": "missing aggregate negative test", "expectedVersion": 1},
    404,
)
foreign_view = str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:foreign-saved-view"))
expect_command_error(
    "updateSavedView",
    {"expectedVersion": 1},
    404,
    {"savedViewId": foreign_view},
)
expect_command_error(
    "acceptAgentSuggestion",
    {
        "suggestionId": str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:suggestion-accept")),
        "reason": "terminal suggestion negative test",
        "expectedVersion": 2,
    },
    409,
)
expect_command_error("retryJobs", {"maxCount": 10, "reason": "missing selection negative test"}, 400)
expect_command_error(
    "createResponseRequest",
    {
        "caseId": FIXTURE_UUIDS["caseId"],
        "partyType": "OTHER",
        "partyName": "Invalid recipient fixture",
        "recipientEmail": "not-an-email",
        "questions": ["Will this be rejected?"],
        "dueAt": "2027-07-12T20:00:00Z",
        "requestedPublicationScope": {},
        "expectedVersion": 14,
    },
    400,
)
published_payload = {
    "caseId": FIXTURE_UUIDS["caseId"],
    "agencyIds": ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"],
    "claims": [],
    "evidence": [],
    "responses": [],
    "reviewSnapshotId": FIXTURE_UUIDS["reviewSnapshotId"],
    "ruleIds": ["control-fixture-rule"],
    "slug": "control-fixture-case",
    "sourceFreshness": {},
    "summary": "Canonical integration case",
    "supplierIds": ["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"],
    "title": "Control canonical case",
}
expect_command_error(
    "publishCase",
    {
        "caseId": FIXTURE_UUIDS["caseId"],
        "reviewSnapshotId": FIXTURE_UUIDS["reviewSnapshotId"],
        "previewHash": sha256(json.dumps(published_payload, sort_keys=True, separators=(",", ":")).encode()),
        "reason": "stale snapshot negative test",
        "expectedVersion": 14,
    },
    400,
)
expect_command_error(
    "approveSchemaMapping",
    {
        "schemaDriftId": str(
            uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:schema-digest-negative")
        ),
        "mappingVersion": 1,
        "mappingDigest": "0" * 64,
        "fieldMappings": [
            {
                "upstreamPath": "supplier.name",
                "canonicalField": "supplierName",
                "transform": "trim",
                "required": True,
            }
        ],
        "reason": "mismatched schema mapping digest negative test",
        "expectedVersion": 1,
    },
    400,
)
expect_command_error(
    "rejectSchemaMapping",
    {
        "schemaDriftId": str(
            uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:schema-digest-negative")
        ),
        "mappingVersion": 1,
        "mappingDigest": "0" * 64,
        "reason": "mistyped exact mapping digest negative test",
        "expectedVersion": 1,
    },
    409,
)
approve_mapping = [
    {
        "upstreamPath": "approveSchemaMapping-upstreamPath",
        "canonicalField": "approveSchemaMapping-canonicalField",
        "transform": "approveSchemaMapping-transform",
        "required": True,
    }
]
expect_command_error(
    "approveSchemaMapping",
    {
        "schemaDriftId": str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:schema-approve")),
        "mappingVersion": 1,
        "mappingDigest": sha256(
            json.dumps(approve_mapping, sort_keys=True, separators=(",", ":")).encode()
        ),
        "fieldMappings": approve_mapping,
        "reason": "terminal resolved drift redecision negative test",
        "expectedVersion": 2,
    },
    409,
)
expect_command_error(
    "rejectSchemaMapping",
    {
        "schemaDriftId": str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:schema-reject")),
        "mappingVersion": 1,
        "mappingDigest": sha256(b"rejectSchemaMapping:mappingDigest"),
        "reason": "terminal rejected drift redecision negative test",
        "expectedVersion": 2,
    },
    409,
)
mismatched_body = json.loads(replay_case["body"])
mismatched_body["reason"] = "same idempotency key with different bytes"
expect_command_error(
    replay_case["operation"]["operationId"],
    mismatched_body,
    409,
    idempotency_key=replay_case["idempotency_key"],
)

path_binding_key = str(uuid.uuid4())
path_binding_body = {"name": "Path-bound update", "expectedVersion": 1}
path_view_a = str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:idempotency-path-view-a"))
path_view_b = str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:idempotency-path-view-b"))
status, _ = execute_command(
    "updateSavedView",
    path_binding_body,
    {"savedViewId": path_view_a},
    path_binding_key,
)
assert status == 200, status
expect_command_error(
    "updateSavedView",
    path_binding_body,
    409,
    {"savedViewId": path_view_b},
    path_binding_key,
)

# A case with no future SENT/VIEWED response request must fail the authority
# transition guard even when the assertion carries responses.request.
expect_command_error(
    "transitionCase",
    {
        "caseId": "cf321e0d-61f0-5c81-9d84-2a8087dd3a29",
        "targetState": "AWAITING_RESPONSE",
        "reason": "No validated response request exists for this transition",
        "expectedVersion": 1,
    },
    422,
)

# Exercise the two idempotency boundary states through HTTP after seeding only
# the owner row: an expired key is reclaimable, while an unexpired same-hash
# row without a terminal response is an in-flight conflict and never replays.
idempotency_value = json.loads(replay_case["body"])
idempotency_body = json.dumps(
    idempotency_value, ensure_ascii=False, separators=(",", ":")
).encode()
idempotency_scope = f"control:{ACTOR}:{replay_case['operation']['operationId']}"

expired_key = str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:control:expired-idempotency-reclaim"))
expired_request_sha256 = canonical_request_sha256(
    replay_case["method"],
    replay_case["path"],
    replay_case["raw_query"],
    idempotency_body,
    replay_case["content_type"],
    expired_key,
)
postgres(
    "INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at) "
    f"VALUES('{idempotency_scope}','{sha256(expired_key.encode())}','{'0' * 64}',clock_timestamp()-interval '1 minute') "
    "ON CONFLICT(scope,key_hash) DO UPDATE SET request_hash=EXCLUDED.request_hash,response_status=NULL,response_body=NULL,expires_at=EXCLUDED.expires_at;"
)
status, _ = execute_command(
    replay_case["operation"]["operationId"], idempotency_value, idempotency_key=expired_key
)
assert status == replay_case["status"], (status, expired_request_sha256)

in_flight_key = str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:control:active-in-flight-idempotency"))
in_flight_request_sha256 = canonical_request_sha256(
    replay_case["method"],
    replay_case["path"],
    replay_case["raw_query"],
    idempotency_body,
    replay_case["content_type"],
    in_flight_key,
)
postgres(
    "INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at) "
    f"VALUES('{idempotency_scope}','{sha256(in_flight_key.encode())}','{in_flight_request_sha256}',clock_timestamp()+interval '1 hour') "
    "ON CONFLICT(scope,key_hash) DO UPDATE SET request_hash=EXCLUDED.request_hash,response_status=NULL,response_body=NULL,expires_at=EXCLUDED.expires_at;"
)
expect_command_error(
    replay_case["operation"]["operationId"],
    idempotency_value,
    409,
    idempotency_key=in_flight_key,
)

print(
    f"control API {expected_control_operations}-operation "
    "assertion/idempotency/PostgreSQL/audit/outbox integration: PASS"
)
