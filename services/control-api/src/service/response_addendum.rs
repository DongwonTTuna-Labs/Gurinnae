fn addendum_response(operation: &OperationSpec, data: &Value) -> Result<Value, ServiceError> {
    if operation.operation_kind == "QUERY" {
        return query_addendum_response(operation.id, data);
    }
    let command = command_envelope(operation, data)?;
    command_addendum_response(operation.id, data, command)
}

fn query_addendum_response(operation: &str, data: &Value) -> Result<Value, ServiceError> {
    let response = match operation {
        "getIncident" => incident_detail(data)?,
        "getResponseAppealWorkspace" => appeal_workspace(data)?,
        "getRetentionRequest" => retention_workspace(data)?,
        _ => data.clone(),
    };
    Ok(response)
}

fn command_envelope(operation: &OperationSpec, data: &Value) -> Result<Value, ServiceError> {
    let completed = operation.id == "releaseLegalHold"
        && data.get("status").and_then(Value::as_str) == Some("RELEASED")
        || matches!(
            operation.id,
            "triageIncident"
                | "containIncident"
                | "startIncidentRecovery"
                | "resolveIncident"
                | "closeIncidentPostmortem"
                | "transitionResponseAppeal"
                | "decideResponseExtension"
                | "transitionRetentionRequest"
                | "declareConflict"
                | "withdrawConflict"
        );
    Ok(json!({
        "operationId": operation.id,
        "requestId": data.get("requestId").cloned().ok_or(ServiceError::Persistence)?,
        "status": if completed { json!("COMPLETED") } else { data.get("status").cloned().ok_or(ServiceError::Persistence)? },
        "aggregateId": data.get("aggregateId").cloned().ok_or(ServiceError::Persistence)?,
        "aggregateVersion": data.get("aggregateVersion").cloned().ok_or(ServiceError::Persistence)?,
        "auditEventId": data.get("auditEventId").cloned().ok_or(ServiceError::Persistence)?,
        "acceptedAt": data.get("acceptedAt").cloned().ok_or(ServiceError::Persistence)?,
        "receiptDigest": data.get("receiptDigest").cloned().ok_or(ServiceError::Persistence)?,
        "emittedEventIds": data.get("emittedEventIds").cloned().ok_or(ServiceError::Persistence)?,
        "idempotencyReplay": false,
        "links": data.get("links").cloned().ok_or(ServiceError::Persistence)?,
    }))
}

fn command_addendum_response(
    operation: &str,
    data: &Value,
    command: Value,
) -> Result<Value, ServiceError> {
    let response = match operation {
        "createActionProposal"
        | "updateActionDraft"
        | "withdrawActionProposal"
        | "previewActionDraft"
        | "submitActionForReview"
        | "claimActionReview"
        | "submitActionDecision"
        | "withdrawActionDecision" => action_command_response(operation, data, command)?,
        "getActionExecutionReceipt" | "cancelActionExecution" | "retryActionExecution" => {
            execution_command_response(operation, data, command)?
        }
        "getCommunicationDeliveryReceipt"
        | "reconcileCommunicationDelivery"
        | "cancelCommunicationDelivery" => communication_command_response(data, command)?,
        "getIncident"
        | "triageIncident"
        | "containIncident"
        | "startIncidentRecovery"
        | "resolveIncident"
        | "closeIncidentPostmortem" => incident_command_response(data, command)?,
        "transitionResponseAppeal" => appeal_command_response(data, command)?,
        "decideResponseExtension" => extension_command_response(data, command)?,
        "transitionRetentionRequest" => retention_command_response(data, command)?,
        "releaseLegalHold" => legal_hold_command_response(data, command)?,
        "declareConflict" | "withdrawConflict" => conflict_command_response(data, command)?,
        // The owner contract's response is the immutable promotion receipt;
        // command metadata is not part of PromoteResearchArtifactReceiptV1.
        // The compatibility owner row may expose the receipt under `promotion`
        // and attach command fields, so project only the generated schema.
        "promoteResearchArtifactToEvidence" => {
            let mut receipt = data.get("promotion").cloned().unwrap_or_else(|| data.clone());
            if let Some(object) = receipt.as_object_mut() {
                const ALLOWED: &[&str] = &[
                    "schemaVersion", "promotionId", "caseId", "caseVersion", "agentRunId",
                    "researchArtifactId", "researchArtifactSha256", "sourceDocumentId",
                    "sourceAssetId", "sourceAssetRevision", "sourceContentSha256",
                    "evidenceSegmentBindings", "selectedSegmentCount", "selectedSegmentSetSha256",
                    "evidenceId", "evidenceVersion", "evidenceDigest", "rightsDecisionId",
                    "rightsDecisionDigest", "reviewerUserId", "auditEventId", "outboxEventId",
                    "idempotencyKeySha256", "promotedAt", "receiptSha256", "links",
                ];
                object.retain(|key, _| ALLOWED.contains(&key.as_str()));
            }
            receipt
        }
        "cancelAgentRun" => {
            let mut receipt = data.get("run").cloned().unwrap_or_else(|| data.clone());
            if let Some(object) = receipt.as_object_mut() {
                const ALLOWED: &[&str] = &[
                    "schemaVersion", "receiptId", "runId", "aggregateVersion", "priorStatus",
                    "priorControlState", "nextStatus", "nextControlState", "affectedProviderTurnId",
                    "affectedToolCallId", "reconciliationEvidenceId", "reconciliationEvidenceSha256",
                    "proofKind", "proofSha256", "budgetDisposition", "budgetResolutionSetSha256",
                    "actorKind", "actorId", "reasonCode", "reasonSha256", "priorReceiptId",
                    "priorReceiptSha256", "commandBinding", "auditEventId", "occurredAt",
                    "receiptSha256",
                ];
                object.retain(|key, _| ALLOWED.contains(&key.as_str()));
            }
            receipt
        }
        "decideJourneyHandoff" => handoff_command_response(data, command)?,
        _ => return Err(ServiceError::InvalidRequest),
    };
    Ok(response)
}

fn action_command_response(
    operation: &str,
    data: &Value,
    command: Value,
) -> Result<Value, ServiceError> {
    let response = match operation {
        "createActionProposal" | "updateActionDraft" | "withdrawActionProposal" => {
            json!({"command": command, "proposal": action_proposal_summary(data)})
        }
        "previewActionDraft" => {
            json!({"command": command, "preview": action_preview_summary(data)?})
        }
        "submitActionForReview" => json!({
            "command": command,
            "proposal": action_proposal_summary(data),
            "assignments": required(data, "assignments")?,
            "quorum": required(data, "quorum")?
        }),
        "claimActionReview" => json!({
            "command": command,
            "proposalId": required(data, "proposalId")?,
            "proposalVersion": required(data, "proposalVersion")?,
            "assignment": action_assignment_summary(data)?
        }),
        "submitActionDecision" | "withdrawActionDecision" => json!({
            "command": command,
            "proposal": action_proposal_summary(data),
            "decision": action_decision_summary(data)?,
            "quorum": required(data, "quorum")?,
            "executionAuthorization": required(data, "executionAuthorization")?
        }),
        _ => return Err(ServiceError::InvalidRequest),
    };
    Ok(response)
}

fn execution_command_response(
    operation: &str,
    data: &Value,
    command: Value,
) -> Result<Value, ServiceError> {
    if operation == "getActionExecutionReceipt" {
        return Ok(json!({
            "authorization": required(data, "authorization")?,
            "binding": required(data, "binding")?,
            "attempts": required(data, "attempts")?,
            "receipts": required(data, "receipts")?,
            "terminal": required(data, "terminal")?,
            "reconciliationRequired": required(data, "reconciliationRequired")?,
            "asOf": required(data, "asOf")?,
            "links": required(data, "links")?,
            "operationId": operation
        }));
    }
    let execution = data.get("execution").unwrap_or(data);
    let latest_receipt = execution
        .get("latestReceipt")
        .cloned()
        .or_else(|| {
            execution
                .get("receipts")
                .and_then(Value::as_array)
                .and_then(|items| items.last().cloned())
        })
        .ok_or(ServiceError::Persistence)?;
    Ok(json!({
        "command": command,
        "authorization": execution_authorization_summary(execution)?,
        "latestReceipt": latest_receipt
    }))
}

fn communication_command_response(data: &Value, command: Value) -> Result<Value, ServiceError> {
    Ok(json!({
        "command": command,
        "delivery": communication_delivery_summary(data)?,
        "priorState": required(data, "priorState")?,
        "receiptDigest": required(&command, "receiptDigest")?
    }))
}

fn incident_command_response(data: &Value, command: Value) -> Result<Value, ServiceError> {
    let event = data.get("incident").ok_or(ServiceError::Persistence)?;
    Ok(json!({
        "command": command,
        "incident": incident_summary(event)?,
        "transition": incident_transition(event)?
    }))
}

fn appeal_command_response(data: &Value, command: Value) -> Result<Value, ServiceError> {
    Ok(json!({
        "command": command,
        "appeal": appeal_summary_from_transition(data)?,
        "transition": data.get("transition").or_else(|| data.get("decisionKind")).cloned().ok_or(ServiceError::Persistence)?,
        "evidenceSetDigest": required(data, "evidenceSetDigest")?,
        "task": required(data, "task")?
    }))
}

fn extension_command_response(data: &Value, command: Value) -> Result<Value, ServiceError> {
    let extension = data.get("extension").ok_or(ServiceError::Persistence)?;
    let extension_view = json!({
        "extensionRequestId": required(extension, "extensionRequestId")?,
        "responseRequestId": required(extension, "responseRequestId")?,
        "version": required(extension, "version")?,
        "state": required(extension, "state")?,
        "priorDueAt": required(extension, "priorDueAt")?,
        "newDueAt": extension.get("newDueAt").cloned().unwrap_or(Value::Null),
        "calendarVersionId": required(extension, "calendarVersionId")?,
        "decisionDigest": required(extension, "decisionDigest")?,
        "decidedAt": extension.get("decidedAt").cloned().unwrap_or(Value::Null)
    });
    Ok(json!({
        "command": command,
        "extension": extension_view,
        "priorDueAt": required(data, "priorDueAt")?,
        "newDueAt": data.get("newDueAt").cloned().unwrap_or(Value::Null),
        "calendarDigest": required(data, "calendarDigest")?
    }))
}

fn retention_command_response(data: &Value, command: Value) -> Result<Value, ServiceError> {
    let raw = data.get("request").ok_or(ServiceError::Persistence)?;
    let request = json!({
        "retentionRequestId": raw.get("retentionRequestId").or_else(|| raw.get("id")).cloned().ok_or(ServiceError::Persistence)?,
        "requestType": required(raw, "requestType")?,
        "decisionVersion": required(raw, "decisionVersion")?,
        "state": raw.get("state").or_else(|| raw.get("status")).cloned().ok_or(ServiceError::Persistence)?,
        "jurisdiction": raw.get("jurisdiction").cloned().unwrap_or_else(|| json!("UNKNOWN")),
        "scopeDigest": required(raw, "scopeDigest")?,
        "legalHoldBlocked": raw.get("legalHoldBlocked").cloned().unwrap_or(Value::Bool(false)),
        "dueAt": required(raw, "dueAt")?,
        "createdAt": required(raw, "createdAt")?,
        "updatedAt": required(raw, "updatedAt")?
    });
    Ok(json!({
        "command": command,
        "request": request,
        "inventorySnapshotDigest": required(data, "inventorySnapshotDigest")?,
        "holdCoverageDigest": required(data, "holdCoverageDigest")?,
        "completionReceiptId": data.get("completionReceiptId").cloned().unwrap_or(Value::Null),
        "locationReceipts": data.get("locationReceipts").cloned().unwrap_or_else(|| json!([]))
    }))
}

fn legal_hold_command_response(data: &Value, command: Value) -> Result<Value, ServiceError> {
    let release = data.get("release").unwrap_or(data);
    Ok(json!({
        "command": command,
        "coverage": required(release, "coverage")?,
        "priorCoverageDigest": required(release, "priorCoverageDigest")?,
        "resultingCoverageDigest": required(release, "resultingCoverageDigest")?,
        "authorityReferenceDigest": required(release, "authorityReferenceDigest")?
    }))
}

fn conflict_command_response(data: &Value, command: Value) -> Result<Value, ServiceError> {
    let target_type = data
        .get("targetType")
        .cloned()
        .unwrap_or_else(|| json!("CASE"));
    let mut target = Map::from_iter([
        ("targetType".to_owned(), target_type.clone()),
        ("targetId".to_owned(), required(data, "targetId")?),
        (
            "targetVersion".to_owned(),
            data.get("targetVersion")
                .cloned()
                .unwrap_or_else(|| json!(1)),
        ),
        (
            "targetDigest".to_owned(),
            data.get("targetDigest")
                .cloned()
                .unwrap_or_else(|| json!(ZERO_DIGEST)),
        ),
    ]);
    if target_type.as_str() == Some("CASE") {
        target.insert(
            "caseId".to_owned(),
            data.get("caseId")
                .cloned()
                .or_else(|| data.get("targetId").cloned())
                .ok_or(ServiceError::Persistence)?,
        );
    }
    let declaration = json!({
        "declarationId": required(data, "declarationId")?,
        "subjectActorId": required(data, "subjectActorId")?,
        "target": Value::Object(target),
        "conflictType": data.get("conflictType").cloned().unwrap_or_else(|| json!("AUTHORSHIP")),
        "relationState": data.get("relationState").cloned().unwrap_or_else(|| json!("UNKNOWN")),
        "materiality": data.get("materiality").cloned().unwrap_or_else(|| json!("UNKNOWN")),
        "temporalState": data.get("temporalState").cloned().unwrap_or_else(|| json!("UNKNOWN")),
        "sourceClass": data.get("sourceClass").cloned().unwrap_or_else(|| json!("SELF_DECLARED")),
        "nonwaivable": data.get("nonwaivable").cloned().unwrap_or(Value::Bool(false)),
        "declarationSequence": data.get("declarationSequence").cloned().unwrap_or_else(|| json!(1)),
        "supersedesDeclarationId": data.get("supersedesDeclarationId").cloned().unwrap_or(Value::Null),
        "evidenceSetDigest": data.get("evidenceSetDigest").cloned().unwrap_or_else(|| json!(ZERO_DIGEST)),
        "policyDigest": data.get("policyDigest").cloned().unwrap_or_else(|| json!(ZERO_DIGEST)),
        "declarationDigest": required(data, "declarationDigest")?,
        "effectiveAt": required(data, "effectiveAt")?,
        "expiresAt": required(data, "expiresAt")?,
        "createdAt": data.get("createdAt").cloned().or_else(|| data.get("acceptedAt").cloned()).ok_or(ServiceError::Persistence)?
    });
    Ok(json!({
        "command": command,
        "declaration": declaration,
        "priorDeclarationDigest": data.get("priorDeclarationDigest").cloned().unwrap_or(Value::Null),
        "receiptDigest": required(data, "receiptDigest")?
    }))
}

fn handoff_command_response(data: &Value, command: Value) -> Result<Value, ServiceError> {
    Ok(json!({
        "schemaVersion": "journey-handoff-decision-receipt.v1",
        "command": command,
        "decisionReceipt": required(data, "decisionReceipt")?,
        "replacement": required(data, "replacement")?,
        "finalParent": required(data, "finalParent")?,
        "effectDigest": required(data, "effectDigest")?,
        "decidedAt": required(data, "decidedAt")?
    }))
}

fn required(data: &Value, field: &str) -> Result<Value, ServiceError> {
    data.get(field).cloned().ok_or(ServiceError::Persistence)
}

const ZERO_DIGEST: &str = "0000000000000000000000000000000000000000000000000000000000000000";
