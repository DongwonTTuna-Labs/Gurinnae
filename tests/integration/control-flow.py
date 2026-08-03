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


def assertion(operation, method, path, raw_query, body, content_type, idempotency_key, actor_id=ACTOR):
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
        "actionDigest": sha256(f"action:{operation['operationId']}".encode()) if assurance == "STEP_UP" else None,
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
        "jti": str(uuid.uuid4()),
        "method": method,
        "operationId": operation["operationId"],
        "path": path,
        "querySha256": sha256(canonical_query(raw_query).encode()),
        "requiredCapability": capability,
        "rolesVersion": 1,
        "sid": REVIEWER if actor_id != ACTOR else SESSION,
        "stepUpAt": now if assurance == "STEP_UP" else None,
        "stepUpAuthorizationId": str(uuid.uuid4()) if assurance == "STEP_UP" else None,
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
    # A withdrawal is actor-bound to the immutable original APPROVE record.
    # The pending-quorum fixture is owned by ACTOR; the reviewer discovered
    # through the separately created proposal must never be substituted here.
    request_actor_id = created_reviewer_id if operation["operationId"] in {
        "claimActionReview", "submitActionDecision"
    } and created_reviewer_id is not None else ACTOR
    token = assertion(operation, method, path, raw_query, body, content_type, idempotency_key, request_actor_id)
    url = BASE + path + ("?" + raw_query if raw_query else "")
    headers = {"X-Gurine-Actor-Assertion": token, "X-Request-ID": str(uuid.uuid4())}
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
    path_values = path_values or {}
    path_template, _, method, operation = next(
        item for item in operations if item[3]["operationId"] == operation_id
    )
    path = path_template
    for name, value in path_values.items():
        path = path.replace("{" + name + "}", urllib.parse.quote(str(value), safe=""))
    body = json.dumps(request_value, ensure_ascii=False, separators=(",", ":")).encode()
    key = idempotency_key or str(uuid.uuid4())
    token = assertion(operation, method, path, "", body, "application/json", key)
    request = urllib.request.Request(
        BASE + path,
        data=body,
        headers={
            "X-Gurine-Actor-Assertion": token,
            "X-Request-ID": str(uuid.uuid4()),
            "Content-Type": "application/json",
            "Idempotency-Key": key,
        },
        method=method,
    )
    try:
        urllib.request.urlopen(request, timeout=20)
    except urllib.error.HTTPError as error:
        assert error.code == expected_status, (operation_id, error.code, expected_status, error.read())
    else:
        raise AssertionError((operation_id, "unexpected success", expected_status))


def execute_command(operation_id, request_value, path_values=None, idempotency_key=None):
    path_values = path_values or {}
    path_template, _, method, operation = next(
        item for item in operations if item[3]["operationId"] == operation_id
    )
    path = path_template
    for name, value in path_values.items():
        path = path.replace("{" + name + "}", urllib.parse.quote(str(value), safe=""))
    body = json.dumps(request_value, ensure_ascii=False, separators=(",", ":")).encode()
    key = idempotency_key or str(uuid.uuid4())
    token = assertion(operation, method, path, "", body, "application/json", key)
    request = urllib.request.Request(
        BASE + path,
        data=body,
        headers={
            "X-Gurine-Actor-Assertion": token,
            "X-Request-ID": str(uuid.uuid4()),
            "Content-Type": "application/json",
            "Idempotency-Key": key,
        },
        method=method,
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.status, response.read()


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
