use super::*;

pub(super) fn validate_command(
    operation: &str,
    payload: &Map<String, Value>,
) -> Result<(), ServiceError> {
    if payload.keys().any(|key| key.trim().is_empty()) {
        return Err(ServiceError::InvalidRequest);
    }
    if gurine_api_contracts::addendum::is_control_operation(operation)
        && !gurine_api_contracts::addendum::validate_control_command(operation, payload)
    {
        return Err(ServiceError::InvalidRequest);
    }
    gurine_api_contracts::control_api::OPERATIONS
        .iter()
        .chain(gurine_api_contracts::addendum::CONTROL_OPERATIONS.iter())
        .any(|candidate| candidate.id == operation && candidate.operation_kind == "COMMAND")
        .then_some(())
        .ok_or(ServiceError::InvalidRequest)
}

pub(super) fn resource_identity(
    operation: &str,
    request: &HttpRequest,
    payload: &Map<String, Value>,
) -> Result<(Uuid, Option<String>), ServiceError> {
    if let Some(value) = request
        .match_info()
        .iter()
        .find_map(|(_, value)| Uuid::parse_str(value).ok())
    {
        return Ok((value, None));
    }
    if creates_resource(operation) {
        let natural = payload
            .get("code")
            .or_else(|| payload.get("sourceId"))
            .or_else(|| payload.get("ruleId"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        return Ok((Uuid::new_v4(), natural));
    }
    let preferred = identity_keys(operation);
    if let Some(value) = uuid_value(payload, preferred) {
        return Ok((value, None));
    }
    if let Some((_, value)) = payload
        .iter()
        .find(|(key, value)| key.ends_with("Id") && value.is_string())
    {
        let text = value.as_str().ok_or(ServiceError::InvalidRequest)?;
        return Ok((Uuid::new_v4(), Some(text.to_owned())));
    }
    let natural = payload
        .get("code")
        .or_else(|| payload.get("sourceId"))
        .or_else(|| payload.get("ruleId"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    Ok((Uuid::new_v4(), natural))
}

pub(super) fn identity_keys(operation: &str) -> &'static [&'static str] {
    match resource_type(operation) {
        "case" => &["caseId"],
        "signal" => &["signalId"],
        "evidence" => &["evidenceId"],
        "claim" => &["claimId"],
        "correction" => &["correctionId", "correctionRequestId"],
        "review" => &["reviewSnapshotId", "reviewId", "caseId"],
        "response" => &["responseId", "responseRequestId", "caseId"],
        "source_run" => &["sourceRunId", "runId"],
        "source" => &["sourceId"],
        "job" => &["jobId"],
        "rule_version" => &["ruleVersionId", "versionId", "ruleId"],
        "user" => &["userId"],
        "provider" => &["providerId"],
        "kill_switch" => &["killSwitchId"],
        "notification" => &["notificationId"],
        "task" => &["taskId"],
        "suggestion" => &["suggestionId"],
        "saved_view" => &["savedViewId"],
        _ => &["id"],
    }
}

pub(super) fn resource_type(operation: &str) -> &'static str {
    if operation.contains("AgentSuggestion") {
        "suggestion"
    } else if operation.contains("Audit") {
        "audit"
    } else if operation.contains("Budget") {
        "budget"
    } else if operation.contains("Claim") {
        "claim"
    } else if operation.contains("Correction") {
        "correction"
    } else if operation.contains("Evidence") {
        "evidence"
    } else if operation.contains("Hypothesis") {
        "hypothesis"
    } else if operation.contains("KillSwitch") {
        "kill_switch"
    } else if operation.contains("Notification") {
        "notification"
    } else if operation.contains("Provider") {
        "provider"
    } else if operation.contains("Response") {
        "response"
    } else if operation.contains("Review") {
        "review"
    } else if operation.contains("Role") {
        "role"
    } else if operation.contains("Rule") {
        "rule_version"
    } else if operation.contains("SavedView") {
        "saved_view"
    } else if operation.contains("Schema") {
        "schema_drift"
    } else if operation.contains("Signal") {
        "signal"
    } else if operation.contains("SourceRun") || operation.contains("Backfill") {
        "source_run"
    } else if operation.contains("Source") {
        "source"
    } else if operation.contains("Job") || operation.contains("Queue") {
        "job"
    } else if operation.contains("Task") {
        "task"
    } else if operation.contains("User")
        || operation.contains("Session")
        || operation.contains("Access")
    {
        "user"
    } else if operation.contains("Publication")
        || operation.contains("Retraction")
        || operation.contains("TemporaryRestriction")
    {
        "publication"
    } else {
        "case"
    }
}

pub(super) fn creates_resource(operation: &str) -> bool {
    operation.starts_with("create")
        || operation.starts_with("add")
        || operation.starts_with("invite")
        || matches!(
            operation,
            "previewPublication"
                | "placeLegalHold"
                | "placeTemporaryRestriction"
                | "proposeRoleDefinitionChange"
                | "startAccessReview"
                | "startAgentRun"
                | "startBackfill"
                | "startSourceRun"
                | "runRuleEvaluation"
                | "verifyAuditIntegrity"
        )
}

pub(super) fn command_status<'a>(operation: &str, payload: &'a Map<String, Value>) -> &'a str {
    if operation.starts_with("accept") || operation.starts_with("approve") {
        "APPROVED"
    } else if operation.starts_with("acknowledge") {
        "ACKNOWLEDGED"
    } else if operation.starts_with("activate") {
        "ACTIVE"
    } else if operation.starts_with("assign") || operation.starts_with("reassign") {
        "ASSIGNED"
    } else if operation.starts_with("cancel") {
        "CANCELLED"
    } else if operation.starts_with("deactivate") {
        "INACTIVE"
    } else if operation.starts_with("disable") {
        "DISABLED"
    } else if operation.starts_with("grant") {
        "GRANTED"
    } else if operation.starts_with("pause") {
        "PAUSED"
    } else if operation.starts_with("publish") {
        "PUBLISHED"
    } else if operation.starts_with("quarantine") {
        "QUARANTINED"
    } else if operation.starts_with("reject") {
        "REJECTED"
    } else if operation.starts_with("resolve") {
        "RESOLVED"
    } else if operation.starts_with("retry")
        || operation.starts_with("run")
        || operation.starts_with("start")
        || operation.starts_with("test")
    {
        "QUEUED"
    } else if operation.starts_with("revoke") {
        "REVOKED"
    } else if operation.starts_with("schedule") {
        "SCHEDULED"
    } else if operation.starts_with("submit") {
        "SUBMITTED"
    } else if operation.starts_with("transition") {
        payload
            .get("targetState")
            .and_then(Value::as_str)
            .unwrap_or("TRANSITIONED")
    } else if operation.starts_with("triage") {
        payload
            .get("decision")
            .and_then(Value::as_str)
            .unwrap_or("TRIAGED")
    } else if operation.starts_with("validate") {
        "VALIDATED"
    } else if operation.starts_with("verify") {
        "VERIFIED"
    } else if operation.starts_with("mark") {
        "READ"
    } else {
        "UPDATED"
    }
}

pub(super) fn event_candidates(
    request_payload: &Value,
    context: EventCandidateContext<'_>,
) -> Result<Value, ServiceError> {
    let EventCandidateContext {
        operation,
        actor_id,
        request_id,
        resource_id,
        resource_version,
        occurred_at,
        previous_case_state,
    } = context;
    let mut candidates = request_payload
        .as_object()
        .cloned()
        .ok_or(ServiceError::InvalidRequest)?;
    candidates.insert("actor_id".into(), json!(actor_id));
    candidates.insert("actorId".into(), json!(actor_id));
    candidates.insert("occurred_at".into(), json!(occurred_at));
    candidates.insert("occurredAt".into(), json!(occurred_at));
    candidates.insert("operation_id".into(), json!(operation));
    candidates.insert("operationId".into(), json!(operation));
    candidates.insert("request_id".into(), json!(request_id));
    candidates.insert("requestId".into(), json!(request_id));
    candidates.insert("resourceId".into(), json!(resource_id));
    candidates.insert("resourceVersion".into(), json!(resource_version));
    match operation {
        "createAuditExport" => {
            candidates.insert("auditExportId".into(), json!(resource_id));
            candidates.insert("requestedBy".into(), json!(actor_id));
            let seconds = candidates
                .get("expiresInSeconds")
                .and_then(Value::as_i64)
                .ok_or(ServiceError::InvalidRequest)?;
            let expires_at = OffsetDateTime::now_utc()
                .checked_add(time::Duration::seconds(seconds))
                .ok_or(ServiceError::InvalidRequest)?;
            candidates.insert("expiresAt".into(), json!(format_time(expires_at)?));
        }
        "placeLegalHold" => {
            candidates.insert("legalHoldId".into(), json!(resource_id));
            candidates.insert("placedBy".into(), json!(actor_id));
            candidates.insert("placedAt".into(), json!(occurred_at));
            candidates.insert("caseVersion".into(), json!(resource_version));
        }
        "transitionCase" => {
            let previous = previous_case_state.ok_or(ServiceError::NotFound)?;
            let from = investigation_state(previous).ok_or(ServiceError::Persistence)?;
            let to = candidates
                .get("targetState")
                .and_then(Value::as_str)
                .and_then(investigation_state)
                .ok_or(ServiceError::InvalidRequest)?;
            let transition = CASE_TRANSITIONS
                .iter()
                .find(|candidate| candidate.from.contains(&from) && candidate.to == to)
                .ok_or(ServiceError::InvalidStateTransition)?;
            candidates.insert("transition_id".into(), json!(transition.id));
            candidates.insert("from_state".into(), json!(previous));
            candidates.insert(
                "to_state".into(),
                candidates
                    .get("targetState")
                    .cloned()
                    .ok_or(ServiceError::InvalidRequest)?,
            );
            candidates.insert("case_version".into(), json!(resource_version));
        }
        "activateRuleVersion" => {
            let target = candidates
                .get("ruleVersionId")
                .cloned()
                .ok_or(ServiceError::InvalidRequest)?;
            candidates.insert("targetVersionId".into(), target);
        }
        _ => {}
    }
    Ok(Value::Object(candidates))
}

pub(super) struct EventCandidateContext<'a> {
    pub(super) operation: &'a str,
    pub(super) actor_id: Uuid,
    pub(super) request_id: Uuid,
    pub(super) resource_id: Uuid,
    pub(super) resource_version: i64,
    pub(super) occurred_at: &'a str,
    pub(super) previous_case_state: Option<&'a str>,
}
