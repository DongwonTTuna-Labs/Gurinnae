fn appeal_summary_from_transition(data: &Value) -> Result<Value, ServiceError> {
    Ok(json!({
        "appealId": data.get("appealId").or_else(|| data.get("aggregateId")).cloned().ok_or(ServiceError::Persistence)?,
        "responseRequestId": data.get("responseRequestId").cloned().ok_or(ServiceError::Persistence)?,
        "caseId": data.get("caseId").cloned().ok_or(ServiceError::Persistence)?,
        "decisionSequence": data.get("decisionSequence").cloned().unwrap_or_else(|| json!(1)),
        "state": data.get("state").cloned().ok_or(ServiceError::Persistence)?,
        "reasonCode": data.get("reasonCode").cloned().unwrap_or_else(|| json!("OTHER")),
        "requestedOutcome": data.get("requestedOutcome").cloned().unwrap_or_else(|| json!("HUMAN_REVIEW")),
        "createdAt": data.get("createdAt").cloned().ok_or(ServiceError::Persistence)?,
        "updatedAt": data.get("updatedAt").cloned().ok_or(ServiceError::Persistence)?,
        "dueAt": data.get("dueAt").cloned().ok_or(ServiceError::Persistence)?
    }))
}

fn appeal_workspace(data: &Value) -> Result<Value, ServiceError> {
    let raw = data.get("appeal").ok_or(ServiceError::Persistence)?;
    let appeal_id = raw.get("id").cloned().ok_or(ServiceError::Persistence)?;
    let created_at = raw
        .get("created_at")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let due_at = raw
        .get("review_due_at")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let appeal = json!({
        "appealId": appeal_id,
        "responseRequestId": raw.get("response_request_id").cloned().ok_or(ServiceError::Persistence)?,
        "caseId": raw.get("case_id").cloned().ok_or(ServiceError::Persistence)?,
        "decisionSequence": raw.get("decision_sequence").cloned().unwrap_or_else(|| json!(0)),
        "state": raw.get("state").or_else(|| raw.get("initial_state")).cloned().unwrap_or_else(|| json!("RECEIVED")),
        "reasonCode": raw.get("reason_code").cloned().ok_or(ServiceError::Persistence)?,
        "requestedOutcome": raw.get("requested_outcome").cloned().ok_or(ServiceError::Persistence)?,
        "createdAt": created_at,
        "updatedAt": raw.get("updated_at").cloned().unwrap_or_else(|| raw.get("created_at").cloned().unwrap_or(Value::Null)),
        "dueAt": due_at
    });
    let decisions = raw_decision_summaries(data.get("decisions").unwrap_or(&Value::Null))?;
    Ok(json!({
        "appeal": appeal,
        "statement": "[REDACTED: encrypted appeal statement]",
        "supportingAttachmentIds": raw.get("supporting_attachment_ids").cloned().unwrap_or_else(|| json!([])),
        "responseRequestVersion": raw.get("response_request_version").cloned().unwrap_or_else(|| json!(1)),
        "priorDecisionId": raw.get("prior_decision_id").cloned().unwrap_or(Value::Null),
        "priorReceiptDigest": raw.get("prior_receipt_digest").cloned().ok_or(ServiceError::Persistence)?,
        "deliveryEvidenceReceiptIds": [],
        "consentEvidenceReceiptIds": [],
        "publicationExcerptEvidenceIds": [],
        "tasks": [],
        "decisionReceipts": decisions,
        "asOf": format_time(OffsetDateTime::now_utc())?,
        "links": [],
        "operationId": "getResponseAppealWorkspace"
    }))
}

fn raw_decision_summaries(value: &Value) -> Result<Value, ServiceError> {
    let Some(rows) = value.as_array() else {
        return Ok(json!([]));
    };
    Ok(Value::Array(rows.iter().map(|row| json!({
        "decisionId": row.get("id").cloned().unwrap_or(Value::Null),
        "decisionSequence": row.get("decision_sequence").cloned().unwrap_or_else(|| json!(1)),
        "transition": row.get("decision_kind").cloned().unwrap_or_else(|| json!("START_REVIEW")),
        "priorState": row.get("prior_state").cloned().unwrap_or_else(|| json!("RECEIVED")),
        "state": row.get("state").cloned().unwrap_or_else(|| json!("REVIEW")),
        "actor": {"actorType": "HUMAN", "actorId": row.get("actor_id").cloned().unwrap_or(Value::Null), "displayName": "검토 담당자"},
        "reasonCode": row.get("reason_code").cloned().unwrap_or_else(|| json!("OTHER")),
        "reason": "[REDACTED: encrypted decision reason]",
        "evidenceSetDigest": row.get("evidence_set_digest").cloned().unwrap_or_else(|| json!("0000000000000000000000000000000000000000000000000000000000000000")),
        "decidedAt": row.get("decided_at").cloned().unwrap_or(Value::Null),
        "receiptDigest": row.get("receipt_digest").cloned().unwrap_or_else(|| json!("0000000000000000000000000000000000000000000000000000000000000000"))
    })).collect()))
}

fn incident_detail(data: &Value) -> Result<Value, ServiceError> {
    let id = data
        .get("incident_id")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let version = data
        .get("version")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let state = data
        .get("state")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let severity = data
        .get("severity")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let owner = data.get("owner_user_id").cloned().unwrap_or(Value::Null);
    let commander = data
        .get("commander_user_id")
        .cloned()
        .unwrap_or(Value::Null);
    let next_update = data.get("next_update_at").cloned().unwrap_or(Value::Null);
    let occurred = data
        .get("occurred_at")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let affected = incident_affected(data);
    let actor_type = data
        .get("actor_type")
        .and_then(Value::as_str)
        .unwrap_or("SERVICE");
    let actor_id = data
        .get("actor_id")
        .and_then(Value::as_str)
        .map(|_| Value::Null)
        .unwrap_or(Value::Null);
    let timeline = incident_timeline(
        data,
        state.clone(),
        actor_type,
        actor_id.clone(),
        occurred.clone(),
    )?;
    Ok(json!({
        "incident": {
            "incidentId": id,
            "version": version,
            "state": state,
            "severity": severity,
            "affectedCapabilities": affected,
            "ownerUserId": owner,
            "commanderUserId": commander,
            "impact": "Control fixture incident",
            "nextUpdateAt": next_update,
            "createdAt": occurred,
            "updatedAt": occurred.clone()
        },
        "evidence": [],
        "containmentActions": [],
        "recoveryPlan": null,
        "rollbackPlan": null,
        "rootCause": null,
        "actionItems": [],
        "timeline": timeline,
        "asOf": occurred,
        "links": [],
        "operationId": "getIncident"
    }))
}

fn incident_affected(data: &Value) -> Vec<Value> {
    data.get("affected_capabilities")
        .and_then(Value::as_array)
        .map(|items| items.iter().map(|_| json!({})).collect())
        .unwrap_or_default()
}

fn incident_timeline(
    data: &Value,
    state: Value,
    actor_type: &str,
    actor_id: Value,
    occurred: Value,
) -> Result<Value, ServiceError> {
    Ok(json!([{
        "eventId": data.get("id").cloned().ok_or(ServiceError::Persistence)?,
        "priorState": data.get("prior_state").cloned().unwrap_or(Value::Null),
        "state": state,
        "reasonCode": data.get("reason_code").cloned().unwrap_or_else(|| json!("INCIDENT")),
        "actor": {"actorType": actor_type, "actorId": actor_id, "displayName": data.get("actor_id").cloned().unwrap_or_else(|| json!("Control service"))},
        "evidenceSetDigest": data.get("evidence_set_digest").cloned().ok_or(ServiceError::Persistence)?,
        "occurredAt": occurred,
        "receiptDigest": data.get("receipt_digest").cloned().ok_or(ServiceError::Persistence)?
    }]))
}

fn incident_summary(data: &Value) -> Result<Value, ServiceError> {
    let affected = data
        .get("affected_capabilities")
        .and_then(Value::as_array)
        .map(|items| items.iter().map(|_| json!({})).collect::<Vec<_>>())
        .unwrap_or_default();
    Ok(json!({
        "incidentId": data.get("incident_id").cloned().ok_or(ServiceError::Persistence)?,
        "version": data.get("version").cloned().ok_or(ServiceError::Persistence)?,
        "state": data.get("state").cloned().ok_or(ServiceError::Persistence)?,
        "severity": data.get("severity").cloned().ok_or(ServiceError::Persistence)?,
        "affectedCapabilities": affected,
        "ownerUserId": data.get("owner_user_id").cloned().unwrap_or(Value::Null),
        "commanderUserId": data.get("commander_user_id").cloned().unwrap_or(Value::Null),
        "impact": "Control incident transition",
        "nextUpdateAt": data.get("next_update_at").cloned().unwrap_or(Value::Null),
        "createdAt": data.get("occurred_at").cloned().ok_or(ServiceError::Persistence)?,
        "updatedAt": data.get("occurred_at").cloned().ok_or(ServiceError::Persistence)?
    }))
}

fn incident_transition(data: &Value) -> Result<Value, ServiceError> {
    let prior = data.get("prior_state").cloned().unwrap_or(Value::Null);
    let actor_type = data
        .get("actor_type")
        .and_then(Value::as_str)
        .unwrap_or("SERVICE");
    Ok(json!({
        "eventId": data.get("id").cloned().ok_or(ServiceError::Persistence)?,
        "priorState": prior,
        "state": data.get("state").cloned().ok_or(ServiceError::Persistence)?,
        "reasonCode": data.get("reason_code").cloned().unwrap_or_else(|| json!("INCIDENT")),
        "actor": {"actorType": actor_type, "actorId": Value::Null, "displayName": data.get("actor_id").cloned().unwrap_or_else(|| json!("Control service"))},
        "evidenceSetDigest": data.get("evidence_set_digest").cloned().ok_or(ServiceError::Persistence)?,
        "occurredAt": data.get("occurred_at").cloned().ok_or(ServiceError::Persistence)?,
        "receiptDigest": data.get("receipt_digest").cloned().ok_or(ServiceError::Persistence)?
    }))
}
