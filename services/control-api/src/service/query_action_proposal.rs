use super::*;

pub(super) fn action_proposal_detail_response(data: Value) -> Value {
    let raw = data.get("proposal").cloned().unwrap_or(Value::Null);
    let as_of = data
        .get("asOf")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| {
            format_time(OffsetDateTime::now_utc())
                .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_owned())
        });
    let proposal_id = raw.get("proposalId").cloned().unwrap_or(Value::Null);
    let proposal_id_text = proposal_id
        .as_str()
        .unwrap_or("00000000-0000-0000-0000-000000000000");
    let content_digest = digest_or_zero(raw.get("contentDigest"));
    let approval_digest = digest_or_zero(raw.get("approvalDigest"));
    let target = json!({
        "targetType": raw.get("targetType").cloned().unwrap_or_else(|| json!("CASE")),
        "targetId": raw.get("targetId").cloned().unwrap_or_else(|| json!("unknown")),
        "expectedVersion": raw.get("targetVersion").cloned().unwrap_or_else(|| json!(1)),
    });
    let proposal = json!({
        "proposalId": proposal_id,
        "version": raw.get("version").cloned().unwrap_or_else(|| json!(1)),
        "actionKind": raw.get("actionKind").cloned().unwrap_or_else(|| json!("TASK")),
        "state": raw.get("state").cloned().unwrap_or_else(|| json!("DRAFT")),
        "contentDigest": content_digest.clone(),
        "approvalDigest": approval_digest,
        "target": target,
        "creator": actor_summary(raw.get("creator"), "SYSTEM"),
        "lastEditor": actor_summary(raw.get("lastEditor"), "SYSTEM"),
        "createdAt": string_or(value_or_null(raw.get("createdAt")), &as_of),
        "updatedAt": string_or(value_or_null(raw.get("updatedAt")), &as_of),
        "expiresAt": string_or(value_or_null(raw.get("expiresAt")), &as_of),
    });
    let origin = normalize_origin(raw.get("origin"), proposal_id_text, &content_digest);
    let rationale = raw
        .get("rationale")
        .and_then(Value::as_str)
        .and_then(|value| serde_json::from_str::<Value>(value).ok())
        .or_else(|| raw.get("rationale").cloned())
        .unwrap_or_else(|| {
            json!({
                "summary": "확인되지 않음",
                "evidenceSegmentIds": [],
                "unknowns": [],
                "alternativesConsidered": [],
                "riskNote": "확인되지 않음"
            })
        });
    let payload = normalize_payload(
        raw.get("payload"),
        &target,
        &rationale,
        raw.get("actionKind"),
    );
    let as_of_value = json!(as_of.clone());
    json!({
        "proposal": proposal,
        "origin": origin,
        "payload": payload,
        "rationale": rationale,
        "latestPreview": raw.get("latestPreview").cloned().unwrap_or(Value::Null),
        "assignmentHistory": normalize_history(data.get("assignmentHistory").cloned().unwrap_or(Value::Null), "slot-ordinal-asc-generation-asc-assignment-id-asc", &as_of_value),
        "decisionHistory": normalize_history(data.get("decisionHistory").cloned().unwrap_or(Value::Null), "decided-at-asc-decision-id-asc", &as_of_value),
        "quorum": normalize_quorum(data.get("quorum").cloned().unwrap_or(Value::Null)),
        "executionAuthorization": data.get("executionAuthorization").cloned().unwrap_or(Value::Null),
        "asOf": as_of,
        "links": data.get("links").cloned().unwrap_or_else(|| json!([])),
        "operationId": "getActionProposal"
    })
}

fn normalize_history(mut value: Value, order: &str, as_of: &Value) -> Value {
    let object = value.as_object_mut().cloned().unwrap_or_default();
    let mut normalized = object;
    normalized.entry("items").or_insert_with(|| json!([]));
    normalized.entry("order").or_insert_with(|| json!(order));
    normalized.entry("asOf").or_insert_with(|| as_of.clone());
    normalized.entry("pageDigest").or_insert_with(|| {
        json!("0000000000000000000000000000000000000000000000000000000000000000")
    });
    normalized.entry("nextCursor").or_insert(Value::Null);
    normalized.entry("complete").or_insert(json!(true));
    Value::Object(normalized)
}

fn normalize_payload(
    value: Option<&Value>,
    target: &Value,
    rationale: &Value,
    action_kind: Option<&Value>,
) -> Value {
    let Some(object) = value.and_then(Value::as_object) else {
        return hypothesis_payload(target, rationale);
    };
    if object.get("kind").and_then(Value::as_str).is_some()
        && object.get("effect").is_some()
        && object.get("rationale").is_some()
    {
        return Value::Object(object.clone());
    }
    let _ = action_kind;
    hypothesis_payload(target, rationale)
}

fn hypothesis_payload(target: &Value, rationale: &Value) -> Value {
    let case_id = target
        .get("targetId")
        .cloned()
        .unwrap_or_else(|| json!("00000000-0000-0000-0000-000000000000"));
    let version = target
        .get("expectedVersion")
        .cloned()
        .unwrap_or_else(|| json!(1));
    json!({
        "schemaVersion": "action-payload.v1",
        "kind": "HYPOTHESIS",
        "target": target,
        "rationale": rationale,
        "effect": {
            "effectClass": "INTERNAL_MATERIALIZATION",
            "fromState": {"aggregate":"CASE", "state":"SIGNAL_DETECTED"},
            "toState": {"aggregate":"CASE", "state":"SIGNAL_DETECTED"},
            "externalSideEffect": true,
            "reversible": true,
            "expectedOutcome": "분석 결과 초안 생성"
        },
        "caseId": case_id,
        "expectedCaseVersion": version,
        "statement": "분석 결과를 검토 가능한 가설로 정리",
        "unknowns": [],
        "evidenceSegmentIds": []
    })
}

fn actor_summary(value: Option<&Value>, default_type: &str) -> Value {
    let object = value
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    json!({
        "actorType": object.get("actorType").and_then(Value::as_str).unwrap_or(default_type),
        "actorId": object.get("actorId").cloned().unwrap_or(Value::Null),
        "displayName": object.get("displayName").and_then(Value::as_str).unwrap_or("확인되지 않음")
    })
}

fn value_or_null(value: Option<&Value>) -> Value {
    value.cloned().unwrap_or(Value::Null)
}

fn string_or(value: Value, fallback: &str) -> Value {
    if value.as_str().is_some() {
        value
    } else {
        json!(fallback)
    }
}

fn digest_or_zero(value: Option<&Value>) -> Value {
    const ZERO: &str = "0000000000000000000000000000000000000000000000000000000000000000";
    if value.and_then(Value::as_str).is_some_and(|digest| {
        digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit())
    }) {
        value.cloned().unwrap_or_else(|| json!(ZERO))
    } else {
        json!(ZERO)
    }
}

fn normalize_origin(value: Option<&Value>, proposal_id: &str, digest: &Value) -> Value {
    let Some(origin) = value.and_then(Value::as_object) else {
        return json!({"kind":"SYSTEM_EVENT", "eventId": proposal_id, "eventType":"ACTION_PROPOSAL_CREATED", "eventPayloadSha256": digest});
    };
    match origin.get("kind").and_then(Value::as_str) {
        Some("HUMAN") | Some("AGENT_PROPOSAL") | Some("SYSTEM_EVENT") | Some("COMPENSATION") => {
            Value::Object(origin.clone())
        }
        _ => {
            json!({"kind":"SYSTEM_EVENT", "eventId": proposal_id, "eventType":"ACTION_PROPOSAL_CREATED", "eventPayloadSha256": digest})
        }
    }
}

fn normalize_quorum(value: Value) -> Value {
    let mut object = value.as_object().cloned().unwrap_or_default();
    let digest = "0000000000000000000000000000000000000000000000000000000000000000";
    if !object
        .get("planDigest")
        .and_then(Value::as_str)
        .is_some_and(|v| v.len() == 64)
    {
        object.insert("planDigest".into(), json!(digest));
    }
    if !object.get("requiredSlots").is_some_and(Value::is_array) {
        object.insert("requiredSlots".into(), json!(["actions.review"]));
    }
    if !object.get("satisfiedSlots").is_some_and(Value::is_array) {
        object.insert("satisfiedSlots".into(), json!([]));
    }
    if !object.get("blockingSlots").is_some_and(Value::is_array) {
        object.insert("blockingSlots".into(), json!(["actions.review"]));
    }
    if !object
        .get("conflictSnapshotDigest")
        .and_then(Value::as_str)
        .is_some_and(|v| v.len() == 64)
    {
        object.insert("conflictSnapshotDigest".into(), json!(digest));
    }
    if !object.get("complete").is_some_and(Value::is_boolean) {
        object.insert("complete".into(), json!(false));
    }
    Value::Object(object)
}
