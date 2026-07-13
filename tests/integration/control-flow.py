#!/usr/bin/env python3
import base64
import hashlib
import hmac
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from jsonschema import Draft202012Validator, RefResolver

BASE = os.environ["CONTROL_TEST_BASE_URL"].rstrip("/")
KEY = base64.b64decode(os.environ["CONTROL_ASSERTION_KEY"])
SPEC = json.load(open("specs/generated/control-api.openapi.json", encoding="utf-8"))
CONCURRENCY = {
    item["operationId"]: item
    for item in json.load(open("specs/application/optimistic-concurrency.runtime.json", encoding="utf-8"))["contracts"]
}
ACTOR = "11111111-1111-4111-8111-111111111111"
SESSION = "22222222-2222-4222-8222-222222222222"
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
    schema = resolve(schema)
    if "anyOf" in schema:
        options = [item for item in schema["anyOf"] if resolve(item).get("type") != "null"]
        return example(options[0] if options else schema["anyOf"][0], name, operation, query)
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
    if name == "targetState" and operation == "transitionCase":
        return "AWAITING_RESPONSE"
    if "const" in schema:
        return schema["const"]
    if schema.get("enum"):
        return schema["enum"][0]
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
        return "2026-07-12"
    if schema.get("format") == "email" or "email" in lower:
        return f"{operation.lower()}@example.test"
    if schema.get("format") in ("uri", "uri-reference") or "url" in lower:
        return "/v1/internal"
    if "sha256" in lower or "digest" in lower or "hash" in lower:
        if name == "previewHash" and operation == "publishCase":
            payload = {
                "caseId": FIXTURE_UUIDS["caseId"],
                "claims": [],
                "evidence": [],
                "responses": [],
                "reviewSnapshotId": FIXTURE_UUIDS["reviewSnapshotId"],
                "slug": "control-fixture-case",
                "sourceFreshness": {},
                "summary": "Canonical integration case",
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


def assertion(operation, method, path, raw_query, body, content_type, idempotency_key):
    now = int(time.time())
    capability = operation["x-capability"]
    capabilities = [capability]
    assurance = operation["x-assurance-level"]
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
        "sid": SESSION,
        "stepUpAt": now if assurance == "STEP_UP" else None,
        "stepUpAuthorizationId": str(uuid.uuid4()) if assurance == "STEP_UP" else None,
        "sub": ACTOR,
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
assert len(operations) == 131
operation_order = {
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
            path_values[parameter["name"]] = value
            path = path.replace("{" + parameter["name"] + "}", urllib.parse.quote(str(value), safe=""))
        elif parameter["in"] == "query" and parameter.get("required"):
            value = example(schema, parameter["name"], operation["operationId"], True)
            raw_query_values.append((parameter["name"], str(value).lower() if isinstance(value, bool) else str(value)))
    raw_query = urllib.parse.urlencode(raw_query_values, quote_via=urllib.parse.quote)
    body = b""
    content_type = ""
    request_schema = operation.get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema")
    if request_schema is not None:
        request_value = example(request_schema, "request", operation["operationId"], False)
        if operation["operationId"] == "retryJobs":
            request_value["jobIds"] = [
                str(uuid.uuid5(uuid.NAMESPACE_URL, "gurine:fixture:bulk-job"))
            ]
        if operation["operationId"] == "saveResponseRequestDraft":
            request_value["recipientEmail"] = "updated-response-recipient@example.test"
            request_value["questions"] = ["Updated canonical response question"]
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
        body = json.dumps(request_value, ensure_ascii=False, separators=(",", ":")).encode()
        content_type = "application/json"
    idempotency_key = str(uuid.uuid4()) if method != "GET" else None
    token = assertion(operation, method, path, raw_query, body, content_type, idempotency_key)
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
    "claims": [],
    "evidence": [],
    "responses": [],
    "reviewSnapshotId": FIXTURE_UUIDS["reviewSnapshotId"],
    "slug": "control-fixture-case",
    "sourceFreshness": {},
    "summary": "Canonical integration case",
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
mismatched_body = json.loads(replay_case["body"])
mismatched_body["reason"] = "same idempotency key with different bytes"
expect_command_error(
    replay_case["operation"]["operationId"],
    mismatched_body,
    409,
    idempotency_key=replay_case["idempotency_key"],
)

print("control API 131-operation assertion/idempotency/PostgreSQL/audit/outbox integration: PASS")
