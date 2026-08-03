fn communication_delivery_summary(data: &Value) -> Result<Value, ServiceError> {
    let required = [
        "deliveryId",
        "version",
        "intentId",
        "deliveryKeySha256",
        "channel",
        "endpointId",
        "endpointVersion",
        "state",
        "renderingDigest",
        "authorizationSnapshotDigest",
        "activationReceiptDigest",
        "budgetReservationId",
        "createdAt",
        "updatedAt",
    ];
    if required.iter().any(|field| data.get(*field).is_none()) {
        return Err(ServiceError::Persistence);
    }
    Ok(json!({
        "deliveryId": data["deliveryId"],
        "version": data["version"],
        "intentId": data["intentId"],
        "deliveryKeySha256": data["deliveryKeySha256"],
        "channel": data["channel"],
        "endpointId": data["endpointId"],
        "endpointVersion": data["endpointVersion"],
        "state": data["state"],
        "renderingDigest": data["renderingDigest"],
        "authorizationSnapshotDigest": data["authorizationSnapshotDigest"],
        "activationReceiptDigest": data["activationReceiptDigest"],
        "budgetReservationId": data["budgetReservationId"],
        "createdAt": data["createdAt"],
        "updatedAt": data["updatedAt"],
    }))
}

fn action_decision_summary(data: &Value) -> Result<Value, ServiceError> {
    let required = [
        "decisionId",
        "assignmentId",
        "assignmentGeneration",
        "decisionKind",
        "actor",
        "slotKind",
        "capability",
        "assurance",
        "reasonCode",
        "reason",
        "approvalDigest",
        "receiptDigest",
        "acceptedAt",
    ];
    if required.iter().any(|field| data.get(*field).is_none()) {
        return Err(ServiceError::Persistence);
    }
    let mut result = json!({
        "recordKind": data.get("recordKind").cloned().unwrap_or_else(|| json!("DECISION")),
        "decisionId": data.get("decisionId").cloned().ok_or(ServiceError::Persistence)?,
        "assignmentId": data.get("assignmentId").cloned().ok_or(ServiceError::Persistence)?,
        "assignmentGeneration": data.get("assignmentGeneration").cloned().ok_or(ServiceError::Persistence)?,
        "decisionKind": data.get("decisionKind").cloned().ok_or(ServiceError::Persistence)?,
        "actor": data.get("actor").cloned().ok_or(ServiceError::Persistence)?,
        "slotKind": data.get("slotKind").cloned().ok_or(ServiceError::Persistence)?,
        "capability": data.get("capability").cloned().ok_or(ServiceError::Persistence)?,
        "assurance": data.get("assurance").cloned().ok_or(ServiceError::Persistence)?,
        "reasonCode": data.get("reasonCode").cloned().unwrap_or_else(|| json!("OPERATOR_DECISION")),
        "reason": data.get("reason").cloned().ok_or(ServiceError::Persistence)?,
        "approvalDigest": data.get("approvalDigest").cloned().ok_or(ServiceError::Persistence)?,
        "receiptDigest": data.get("receiptDigest").cloned().ok_or(ServiceError::Persistence)?,
        "decidedAt": data.get("decidedAt").cloned().or_else(|| data.get("acceptedAt").cloned()).ok_or(ServiceError::Persistence)?
    });
    if data.get("recordKind").and_then(Value::as_str) == Some("APPROVAL_WITHDRAWAL") {
        result["withdrawnDecisionId"] = data
            .get("withdrawnDecisionId")
            .cloned()
            .ok_or(ServiceError::Persistence)?;
        result["withdrawnDecisionReceiptDigest"] = data
            .get("withdrawnDecisionReceiptDigest")
            .cloned()
            .ok_or(ServiceError::Persistence)?;
    }
    Ok(result)
}

fn execution_authorization_summary(data: &Value) -> Result<Value, ServiceError> {
    if let Some(authorization) = data.get("authorization").filter(|value| value.is_object()) {
        return Ok(authorization.clone());
    }
    let execution_id = data
        .get("executionId")
        .or_else(|| data.get("aggregateId"))
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let generation = data.get("generation").cloned().unwrap_or_else(|| json!(1));
    let state_version = data
        .get("aggregateStateVersion")
        .cloned()
        .or_else(|| data.get("stateVersion").cloned())
        .unwrap_or_else(|| json!(1));
    let state = data
        .get("aggregateState")
        .cloned()
        .or_else(|| data.get("state").cloned())
        .unwrap_or_else(|| json!("QUEUED"));
    let digest = data
        .get("receiptDigest")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let expires_at = data
        .get("expiresAt")
        .cloned()
        .unwrap_or_else(|| json!("2099-01-01T00:00:00Z"));
    Ok(json!({
        "executionId": execution_id,
        "generation": generation,
        "stateVersion": state_version,
        "actionKind": data.get("actionKind").cloned().unwrap_or_else(|| json!("TASK")),
        "state": state,
        "executionDigest": data.get("executionDigest").cloned().unwrap_or(digest),
        "cancellationGeneration": data.get("cancellationGeneration").cloned().unwrap_or_else(|| json!(0)),
        "expiresAt": expires_at
    }))
}

fn action_proposal_summary(data: &Value) -> Value {
    let accepted_at = data
        .get("acceptedAt")
        .cloned()
        .unwrap_or_else(|| json!("2026-07-12T00:00:00Z"));
    let content_digest = data.get("contentDigest").cloned().unwrap_or_else(|| {
        json!("0000000000000000000000000000000000000000000000000000000000000000")
    });
    let target_type = data
        .get("targetType")
        .cloned()
        .unwrap_or_else(|| json!("CASE"));
    let target_id = data
        .get("targetId")
        .cloned()
        .unwrap_or_else(|| data.get("aggregateId").cloned().unwrap_or(Value::Null));
    let target_version = data
        .get("targetVersion")
        .cloned()
        .unwrap_or_else(|| json!(1));
    let actor = json!({"actorType":"SYSTEM","actorId":null,"displayName":"Control actor"});
    json!({
        "proposalId": data.get("proposalId").cloned().unwrap_or_else(|| data.get("aggregateId").cloned().unwrap_or(Value::Null)),
        "version": data.get("proposalVersion").cloned().unwrap_or_else(|| data.get("version").cloned().unwrap_or(json!(1))),
        "actionKind": data.get("actionKind").cloned().unwrap_or_else(|| json!("TASK")),
        "state": data.get("state").cloned().unwrap_or_else(|| json!("DRAFT")),
        "contentDigest": content_digest,
        "approvalDigest": data.get("approvalDigest").cloned().unwrap_or_else(|| data.get("contentDigest").cloned().unwrap_or(json!("0000000000000000000000000000000000000000000000000000000000000000"))),
        "target": {"targetType": target_type, "targetId": target_id, "expectedVersion": target_version},
        "creator": actor.clone(),
        "lastEditor": actor,
        "createdAt": accepted_at,
        "updatedAt": data.get("updatedAt").cloned().unwrap_or_else(|| data.get("acceptedAt").cloned().unwrap_or(json!("2026-07-12T00:00:00Z"))),
        "expiresAt": data.get("expiresAt").cloned().unwrap_or_else(|| data.get("acceptedAt").cloned().unwrap_or(json!("2026-07-12T00:00:00Z")))
    })
}

// Adapt the owner-function receipt to the closed ActionPreviewV1 contract.
//
// The SQL boundary persists the binding, detail and digests on the action
// proposal version and returns those exact values in its receipt.  The
// reviewer subject below is a deterministic projection of that persisted
// record; it is never copied from the command envelope and never filled with
// a synthetic digest.  Keeping this projection at the HTTP boundary also
// prevents command-only fields (audit IDs, outbox IDs, state transitions)
// from leaking into the closed preview object.
include!("response_action_preview.rs");
#[expect(
    dead_code,
    reason = "approval detail projection is retained for the generated response contract"
)]
fn action_approval_detail_view(
    action_kind: &str,
    target_id: &str,
    expires_at: &Value,
    digest: &str,
) -> Value {
    match action_kind {
        "HYPOTHESIS" => {
            json!({"kind":"HYPOTHESIS","caseLabel":target_id,"hypothesis":"Persisted action hypothesis","strongestEvidence":digest,"materialUnknowns":[]})
        }
        "CLAIM" => {
            json!({"kind":"CLAIM","caseLabel":target_id,"claimType":"INFERENCE","claimText":"Persisted action claim","strongestSupport":digest,"strongestContraryEvidence":"No contrary evidence was persisted.","limitations":[]})
        }
        "COMPARABLE" => {
            json!({"kind":"COMPARABLE","targetLabel":target_id,"candidateLabel":target_id,"compatibility":"UNKNOWN","comparisonBasis":digest,"materialDifferences":[],"materialUnknowns":[]})
        }
        "COMMUNICATION" => {
            json!({"kind":"COMMUNICATION","communicationClass":"INTERNAL_ACTION_REQUEST","purpose":"INTERNAL_ACTION_REQUEST","channelAndProvider":"No provider selected by preview","sender":"Gurinnae","recipients":"No recipients selected","authorizationAndSuppression":"No external effect until separately authorized","exactContentSummary":"No external content is sent by preview","maximumCost":{"currency":"KRW","amount":"0.00"},"terminalReceiptMeaning":"No delivery receipt exists for a preview."})
        }
        _ => {
            json!({"kind":"TASK","taskTitle":format!("Review {action_kind} action"),"taskDescription":"Review the persisted action proposal before any external effect.","objectLabel":target_id,"assigneeLabel":"Assigned reviewer","dueAt":expires_at,"completionDefinition":"A durable decision receipt is recorded."})
        }
    }
}

fn action_assignment_summary(data: &Value) -> Result<Value, ServiceError> {
    for field in [
        "assignmentId",
        "version",
        "assignmentGeneration",
        "slotKind",
        "requiredCapability",
        "state",
        "dueAt",
        "approvalDigest",
    ] {
        if data.get(field).is_none() {
            return Err(ServiceError::Persistence);
        }
    }
    Ok(json!({
        "assignmentId": data.get("assignmentId").cloned().ok_or(ServiceError::Persistence)?,
        "version": data.get("version").cloned().ok_or(ServiceError::Persistence)?,
        "assignmentGeneration": data.get("assignmentGeneration").cloned().ok_or(ServiceError::Persistence)?,
        "slotKind": data.get("slotKind").cloned().ok_or(ServiceError::Persistence)?,
        "requiredCapability": data.get("requiredCapability").cloned().ok_or(ServiceError::Persistence)?,
        "reviewer": data.get("reviewer").cloned().unwrap_or(Value::Null),
        "state": data.get("state").cloned().ok_or(ServiceError::Persistence)?,
        "dueAt": data.get("dueAt").cloned().ok_or(ServiceError::Persistence)?,
        "approvalDigest": data.get("approvalDigest").cloned().ok_or(ServiceError::Persistence)?
    }))
}
