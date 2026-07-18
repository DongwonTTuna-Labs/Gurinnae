use super::*;

pub(super) fn response_for(operation: &OperationSpec, data: &Value) -> Result<Value, ServiceError> {
    if operation.success_status == 204 {
        return Ok(Value::Null);
    }
    // OPS-004 was extended by the product contract to expose the closed
    // BusinessHealthResponse envelope.  The historical OpenAPI operation is
    // still named getBudgetOverview, so feeding this value through the legacy
    // BudgetOverview materializer would silently drop funnel/metric evidence
    // and manufacture empty defaults.  Preserve the owner-function envelope
    // exactly; its schema and digests have already been validated at the SQL
    // boundary.
    if operation.id == "getBudgetOverview" {
        if business_health_envelope_is_closed(data) {
            return Ok(data.clone());
        }
        return Err(ServiceError::Persistence);
    }
    // Addendum responses are closed operation-specific envelopes.  They are
    // handled before the legacy OpenAPI materializer because the generated
    // v13.0 document intentionally does not contain v13.1 paths.
    if gurine_api_contracts::addendum::is_control_operation(operation.id) {
        return addendum_response(operation, data);
    }
    let schema = response_schema(operation.id, operation.success_status)?;
    materialize(schema, data, "response")
}

fn business_health_envelope_is_closed(value: &Value) -> bool {
    let Some(body) = value.get("data").and_then(Value::as_object) else {
        return false;
    };
    let Some(metrics) = body.get("metrics").and_then(Value::as_array) else {
        return false;
    };
    if metrics.len() != 25 {
        return false;
    }
    let mut unknown_count = 0_u64;
    for metric in metrics {
        let Some(metric) = metric.as_object() else {
            return false;
        };
        let Some(status) = metric.get("status").and_then(Value::as_str) else {
            return false;
        };
        if !matches!(status, "KNOWN" | "UNKNOWN" | "NOT_APPLICABLE") {
            return false;
        }
        let reason = metric
            .get("reasonCode")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let unknown_reasons = metric
            .get("unknownReasons")
            .and_then(Value::as_array)
            .map_or(0, Vec::len);
        match status {
            "KNOWN" if reason == "NONE" && unknown_reasons == 0 => {}
            "NOT_APPLICABLE" if !reason.is_empty() && reason != "NONE" && unknown_reasons == 0 => {}
            "UNKNOWN" if !reason.is_empty() && reason != "NONE" && unknown_reasons > 0 => {
                unknown_count += 1;
            }
            _ => return false,
        }
    }
    if body.get("unknownSourceCount").and_then(Value::as_u64) != Some(unknown_count) {
        return false;
    }
    let readiness = body
        .get("readinessState")
        .and_then(Value::as_str)
        .unwrap_or_default();
    matches!(readiness, "UNKNOWN" | "BLOCKED" | "READY")
        && (readiness != "READY" || unknown_count == 0)
        && body
            .get("funnel")
            .and_then(Value::as_array)
            .is_some_and(|stages| stages.len() == 8)
}

fn addendum_response(operation: &OperationSpec, data: &Value) -> Result<Value, ServiceError> {
    if operation.operation_kind == "QUERY" {
        return Ok(data.clone());
    }
    let command = json!({
        "operationId": operation.id,
        "requestId": data.get("requestId").cloned().ok_or(ServiceError::Persistence)?,
        "status": data.get("status").cloned().ok_or(ServiceError::Persistence)?,
        "aggregateId": data.get("aggregateId").cloned().ok_or(ServiceError::Persistence)?,
        "aggregateVersion": data.get("aggregateVersion").cloned().ok_or(ServiceError::Persistence)?,
        "auditEventId": data.get("auditEventId").cloned().ok_or(ServiceError::Persistence)?,
        "acceptedAt": data.get("acceptedAt").cloned().ok_or(ServiceError::Persistence)?,
        "receiptDigest": data.get("receiptDigest").cloned().ok_or(ServiceError::Persistence)?,
        "emittedEventIds": data.get("emittedEventIds").cloned().ok_or(ServiceError::Persistence)?,
        "idempotencyReplay": false,
        "links": data.get("links").cloned().ok_or(ServiceError::Persistence)?,
    });
    let response = match operation.id {
        "createActionProposal" | "updateActionDraft" | "withdrawActionProposal" => {
            json!({"command": command, "proposal": data})
        }
        "previewActionDraft" => json!({"command": command, "preview": data}),
        "submitActionForReview" => {
            json!({"command": command, "proposal": data, "assignments": data.get("assignments").cloned().ok_or(ServiceError::Persistence)?, "quorum": data.get("quorum").cloned().ok_or(ServiceError::Persistence)?})
        }
        "claimActionReview" => {
            json!({"command": command, "proposalId": data.get("proposalId").cloned().ok_or(ServiceError::Persistence)?, "proposalVersion": data.get("version").cloned().ok_or(ServiceError::Persistence)?, "assignment": data})
        }
        "submitActionDecision" | "withdrawActionDecision" => {
            json!({
                "command": command,
                "proposal": data,
                "decision": data,
                // The owner procedure must persist both fields, including an
                // explicit null authorization when no execution is allowed.
                // A missing field is a closed-contract failure, never a
                // synthetic pending/quorum default.
                "quorum": data
                    .get("quorum")
                    .cloned()
                    .ok_or(ServiceError::Persistence)?,
                "executionAuthorization": data
                    .get("executionAuthorization")
                    .cloned()
                    .ok_or(ServiceError::Persistence)?,
            })
        }
        "getActionExecutionReceipt" | "cancelActionExecution" | "retryActionExecution" => {
            json!({"command": command, "execution": data, "receipts": data.get("receipts").cloned().ok_or(ServiceError::Persistence)?})
        }
        "getCommunicationDeliveryReceipt"
        | "reconcileCommunicationDelivery"
        | "cancelCommunicationDelivery" => {
            json!({"command": command, "delivery": data, "priorState": data.get("priorState").cloned().ok_or(ServiceError::Persistence)?, "receiptDigest": command.get("receiptDigest").cloned().ok_or(ServiceError::Persistence)?})
        }
        "getIncident"
        | "triageIncident"
        | "containIncident"
        | "startIncidentRecovery"
        | "resolveIncident"
        | "closeIncidentPostmortem" => {
            json!({"command": command, "incident": data, "transition": data.get("transition").cloned().ok_or(ServiceError::Persistence)?})
        }
        "transitionResponseAppeal" => {
            json!({"command": command, "appeal": data, "transition": data.get("transition").cloned().ok_or(ServiceError::Persistence)?, "evidenceSetDigest": data.get("evidenceSetDigest").cloned().ok_or(ServiceError::Persistence)?, "task": data.get("task").cloned().ok_or(ServiceError::Persistence)?})
        }
        "decideResponseExtension" => json!({"command": command, "extension": data}),
        "transitionRetentionRequest" => {
            json!({"command": command, "request": data, "transition": data.get("transition").cloned().ok_or(ServiceError::Persistence)?})
        }
        "releaseLegalHold" => json!({"command": command, "release": data}),
        "declareConflict" | "withdrawConflict" => json!({"command": command, "declaration": data}),
        "promoteResearchArtifactToEvidence" => json!({"command": command, "promotion": data}),
        "cancelAgentRun" => json!({"command": command, "run": data}),
        "decideJourneyHandoff" => {
            json!({"schemaVersion":"journey-handoff-decision-receipt.v1", "command": command, "decisionReceipt": data.get("decisionReceipt").cloned().ok_or(ServiceError::Persistence)?, "replacement": data.get("replacement").cloned().ok_or(ServiceError::Persistence)?, "finalParent": data.get("finalParent").cloned().ok_or(ServiceError::Persistence)?, "effectDigest": data.get("effectDigest").cloned().ok_or(ServiceError::Persistence)?, "decidedAt": data.get("decidedAt").cloned().ok_or(ServiceError::Persistence)?})
        }
        _ => return Err(ServiceError::InvalidRequest),
    };
    Ok(response)
}

pub(super) fn response_schema(
    operation: &str,
    status: u16,
) -> Result<&'static Value, ServiceError> {
    let spec = SPEC
        .get_or_init(|| serde_json::from_str(CONTROL_OPENAPI).map_err(|_| ()))
        .as_ref()
        .map_err(|_| ServiceError::Persistence)?;
    for item in spec
        .get("paths")
        .and_then(Value::as_object)
        .ok_or(ServiceError::Persistence)?
        .values()
    {
        for candidate in item.as_object().ok_or(ServiceError::Persistence)?.values() {
            if candidate.get("operationId").and_then(Value::as_str) == Some(operation) {
                return candidate
                    .pointer(&format!(
                        "/responses/{status}/content/application~1json/schema"
                    ))
                    .ok_or(ServiceError::Persistence);
            }
        }
    }
    Err(ServiceError::Persistence)
}

pub(super) fn resolve(reference: &str) -> Result<&'static Value, ServiceError> {
    let spec = SPEC
        .get()
        .ok_or(ServiceError::Persistence)?
        .as_ref()
        .map_err(|_| ServiceError::Persistence)?;
    spec.pointer(
        reference
            .strip_prefix('#')
            .ok_or(ServiceError::Persistence)?,
    )
    .ok_or(ServiceError::Persistence)
}

pub(super) fn materialize(schema: &Value, data: &Value, name: &str) -> Result<Value, ServiceError> {
    if let Some(reference) = schema.get("$ref").and_then(Value::as_str) {
        return materialize(resolve(reference)?, data, name);
    }
    if let Some(options) = schema.get("anyOf").and_then(Value::as_array) {
        let selected = if data.is_null() {
            options
                .iter()
                .find(|v| v.get("type").and_then(Value::as_str) == Some("null"))
                .unwrap_or(&options[0])
        } else {
            options
                .iter()
                .find(|v| v.get("type").and_then(Value::as_str) != Some("null"))
                .unwrap_or(&options[0])
        };
        return materialize(selected, data, name);
    }
    if let Some(parts) = schema.get("allOf").and_then(Value::as_array) {
        let mut out = json!({});
        for part in parts {
            merge(&mut out, &materialize(part, data, name)?);
        }
        return Ok(out);
    }
    let kind = match schema.get("type") {
        Some(Value::String(value)) => value.as_str(),
        Some(Value::Array(values)) if data.is_null() && values.iter().any(|v| v == "null") => {
            "null"
        }
        Some(Value::Array(values)) => values
            .iter()
            .filter_map(Value::as_str)
            .find(|value| *value != "null")
            .unwrap_or("object"),
        _ => "object",
    };
    match kind {
        "object" => {
            let properties = schema
                .get("properties")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            let required = schema
                .get("required")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let mut out = Map::new();
            for (key, property) in properties {
                let source = data.get(&key).unwrap_or(&Value::Null);
                if !source.is_null() || required.iter().any(|v| v.as_str() == Some(&key)) {
                    out.insert(key.clone(), materialize(&property, source, &key)?);
                }
            }
            Ok(Value::Object(out))
        }
        "array" => {
            let item_schema = schema.get("items").ok_or(ServiceError::Persistence)?;
            let values = data.as_array().cloned().unwrap_or_default();
            Ok(Value::Array(
                values
                    .iter()
                    .map(|v| materialize(item_schema, v, name))
                    .collect::<Result<_, _>>()?,
            ))
        }
        "string" => Ok(Value::String(string_default(schema, data, name)?)),
        "integer" | "number" => Ok(if let Some(value) = data.as_i64() {
            json!(value)
        } else if name.to_ascii_lowercase().contains("version") {
            json!(1)
        } else {
            json!(0)
        }),
        "boolean" => Ok(json!(data.as_bool().unwrap_or(false))),
        "null" => Ok(Value::Null),
        _ => Ok(data.clone()),
    }
}

pub(super) fn string_default(
    schema: &Value,
    data: &Value,
    name: &str,
) -> Result<String, ServiceError> {
    if let Some(value) = data.as_str()
        && enum_allows(schema, value)
    {
        return Ok(value.to_owned());
    }
    if let Some(values) = schema.get("enum").and_then(Value::as_array)
        && let Some(value) = values.first().and_then(Value::as_str)
    {
        return Ok(value.to_owned());
    }
    if let Some(pattern) = schema.get("pattern").and_then(Value::as_str) {
        if pattern.contains("\\d") {
            return Ok("0".to_owned());
        }
        if pattern.contains("a-f0-9") && pattern.contains("64") {
            return Ok(sha256(name.as_bytes()));
        }
    }
    let lower = name.to_ascii_lowercase();
    if schema.get("format").and_then(Value::as_str) == Some("uuid") || lower.ends_with("id") {
        return Ok(Uuid::new_v4().to_string());
    }
    if schema.get("format").and_then(Value::as_str) == Some("date-time") || lower.ends_with("at") {
        return format_time(OffsetDateTime::now_utc());
    }
    if schema.get("format").and_then(Value::as_str) == Some("date") {
        return Ok("2026-07-12".to_owned());
    }
    if lower.contains("sha256") || lower.contains("digest") || lower.contains("hash") {
        return Ok(sha256(name.as_bytes()));
    }
    if lower.contains("currency") {
        return Ok("KRW".to_owned());
    }
    if lower.contains("href") || lower.contains("url") {
        return Ok("/v1/internal".to_owned());
    }
    if lower.contains("email") {
        return Ok("redacted@example.invalid".to_owned());
    }
    if lower.contains("status") {
        return Ok("READY".to_owned());
    }
    Ok(name.to_owned())
}

pub(super) fn enum_allows(schema: &Value, value: &str) -> bool {
    schema
        .get("enum")
        .and_then(Value::as_array)
        .is_none_or(|values| {
            values
                .iter()
                .any(|candidate| candidate.as_str() == Some(value))
        })
}

pub(super) fn merge(target: &mut Value, source: &Value) {
    if let (Value::Object(target), Value::Object(source)) = (target, source) {
        for (key, value) in source {
            match target.get_mut(key) {
                Some(existing) if existing.is_object() && value.is_object() => {
                    merge(existing, value)
                }
                _ => {
                    target.insert(key.clone(), value.clone());
                }
            }
        }
    }
}
