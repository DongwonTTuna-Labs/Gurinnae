fn validated_command_payload(operation: &str, body: &[u8]) -> Result<Value, ServiceError> {
    let payload = parse_command_payload(body)?;
    let payload_object = payload.as_object().ok_or(ServiceError::InvalidRequest)?;
    if operation == "createResponseRequest"
        && let Some(email) = payload_object.get("recipientEmail").and_then(Value::as_str)
        && !valid_recipient_email(email)
    {
        return Err(ServiceError::InvalidRequest);
    }
    validate_command(operation, payload_object)?;
    validate_economics_import_command(operation, payload_object)?;
    Ok(payload)
}

fn normalized_command_input<'a>(
    operation: &str,
    mut payload: Value,
    raw_body: &'a [u8],
) -> Result<(Value, std::borrow::Cow<'a, [u8]>), ServiceError> {
    if operation != "placeLegalHold" {
        return Ok((payload, std::borrow::Cow::Borrowed(raw_body)));
    }
    let object = payload
        .as_object_mut()
        .ok_or(ServiceError::InvalidRequest)?;
    object.entry("expiresAt").or_insert(Value::Null);
    normalize_legal_hold_scope_atoms(object)?;
    normalize_legal_hold_affected_ids(object)?;
    let canonical_body = canonical_json(&payload).map_err(|_| ServiceError::InvalidRequest)?;
    Ok((payload, std::borrow::Cow::Owned(canonical_body)))
}

fn normalize_legal_hold_scope_atoms(payload: &mut Map<String, Value>) -> Result<(), ServiceError> {
    let atoms = payload
        .get("scopeAtoms")
        .and_then(Value::as_array)
        .filter(|atoms| (1..=3).contains(&atoms.len()))
        .ok_or(ServiceError::InvalidRequest)?;
    let mut normalized = atoms
        .iter()
        .map(|atom| atom.as_str().ok_or(ServiceError::InvalidRequest))
        .collect::<Result<Vec<_>, _>>()?;
    normalized.sort_unstable();
    if normalized.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(ServiceError::InvalidRequest);
    }
    payload.insert("scopeAtoms".to_owned(), json!(normalized));
    Ok(())
}

fn normalize_legal_hold_affected_ids(payload: &mut Map<String, Value>) -> Result<(), ServiceError> {
    let affected_ids = payload
        .get("affectedIds")
        .and_then(Value::as_array)
        .filter(|values| (1..=10_000).contains(&values.len()))
        .ok_or(ServiceError::InvalidRequest)?;
    let mut normalized = affected_ids
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .filter(|value| !value.is_nil())
                .ok_or(ServiceError::InvalidRequest)
        })
        .collect::<Result<Vec<_>, _>>()?;
    normalized.sort_unstable();
    if normalized.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err(ServiceError::InvalidRequest);
    }
    payload.insert(
        "affectedIds".to_owned(),
        Value::Array(
            normalized
                .into_iter()
                .map(|value| Value::String(value.to_string()))
                .collect(),
        ),
    );
    Ok(())
}

fn valid_recipient_email(value: &str) -> bool {
    let trimmed = value.trim();
    let Some((local, domain)) = trimmed.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && !domain.is_empty()
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !trimmed.chars().any(char::is_whitespace)
}

fn bind_editorial_owner_authority(
    operation: &str,
    claims: &ActorClaims,
    request_id: Uuid,
    key: &CommandKey,
    payload: &mut Map<String, Value>,
) {
    if !owner_authority_operation(operation) {
        return;
    }
    let Some(effective_capability) = owner_effective_capability(operation, payload) else {
        return;
    };
    payload.insert(
        "_actorEffectiveCapability".to_owned(),
        json!(effective_capability),
    );
    payload.insert("_actorAssertionJti".to_owned(), json!(claims.jti));
    payload.insert(
        "_actorAssuranceLevel".to_owned(),
        json!(claims.assurance_level),
    );
    payload.insert("_actorActionDigest".to_owned(), json!(claims.action_digest));
    payload.insert(
        "_actorStepUpAuthorizationId".to_owned(),
        json!(claims.step_up_authorization_id),
    );
    payload.insert(
        "_actorIdempotencyKeySha256".to_owned(),
        json!(claims.idempotency_key_sha256),
    );
    if matches!(
        operation,
        "placeLegalHold"
            | "attestOrganizationOfficialChannel"
            | "revokeOrganizationOfficialChannel"
            | "classifyEntityPersonhood"
            | "attestEntityMaterialUseClosure"
    ) {
        payload.insert(
            "_actorAssertionRequestSha256".to_owned(),
            json!(actor_assertion_request_digest(claims)),
        );
    }
    payload.insert("_actorRequestKeySha256".to_owned(), json!(key.key_hash));
    payload.insert("_requestId".to_owned(), json!(request_id));
    payload.insert("_requestSha256".to_owned(), json!(key.request_hash));
    payload.insert("_idempotencyKeySha256".to_owned(), json!(key.key_hash));
}

fn actor_assertion_request_digest(claims: &ActorClaims) -> String {
    // Mirrors `gurine_auth::assertion::canonical_request_digest` using the
    // request hashes already authenticated inside the signed actor assertion.
    // This intentionally remains distinct from a command's semantic
    // idempotency digest when the server canonicalizes set-valued input.
    let preimage = format!(
        "{}\n{}\n{}\n{}\n{}\n{}",
        claims.method,
        claims.path,
        claims.query_sha256,
        claims.body_sha256,
        claims.content_type,
        claims.idempotency_key_sha256.as_deref().unwrap_or("")
    );
    sha256(preimage.as_bytes())
}

fn owner_authority_operation(operation: &str) -> bool {
    matches!(
        operation,
        "attestOrganizationOfficialChannel"
            | "attestEntityMaterialUseClosure"
            | "approveResponseExcerpt"
            | "previewPublication"
            | "publishCase"
            | "placeLegalHold"
            | "resolveCorrectionRequest"
            | "submitReview"
            | "verifyResponseOrganizationIdentity"
            | "revokeOrganizationOfficialChannel"
            | "classifyEntityPersonhood"
    )
}

fn owner_effective_capability<'a>(
    operation: &str,
    payload: &'a Map<String, Value>,
) -> Option<&'a str> {
    match operation {
        "attestOrganizationOfficialChannel"
        | "approveResponseExcerpt"
        | "verifyResponseOrganizationIdentity"
        | "revokeOrganizationOfficialChannel" => Some("responses.review"),
        "attestEntityMaterialUseClosure" | "classifyEntityPersonhood" => Some("users.manage"),
        "previewPublication" => Some("publication.preview"),
        "publishCase" => Some("publication.publish"),
        "placeLegalHold" => Some("review.legal"),
        "resolveCorrectionRequest" => Some("publication.correct"),
        "submitReview"
            if payload
                .get("criteria")
                .and_then(Value::as_object)
                .is_some_and(|criteria| criteria.contains_key("namedIndividualOverride")) =>
        {
            Some("review.legal")
        }
        "submitReview" => Some("review.editorial"),
        _ => None,
    }
}

fn emit_domain_events(
    domain_events: &Mutex<InProcessDomainEventJournal>,
    pending_domain_events: Vec<PendingDomainEvent>,
) -> Result<(), ServiceError> {
    let mut domain_event_sink = domain_events
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    for event in pending_domain_events {
        if DomainEventSink::append(
            &mut *domain_event_sink,
            event.event_type,
            &event.aggregate_id,
            event.version,
            &event.payload,
        )
        .is_err()
        {
            return Err(ServiceError::Persistence);
        }
        tracing::info!(
            event_type = event.event_type,
            aggregate_id = event.aggregate_id,
            version = event.version,
            "committed in-process domain event emitted"
        );
    }
    Ok(())
}

fn validate_owner_replay_response(operation: &str, response: &Value) -> Result<(), ServiceError> {
    if operation == "placeLegalHold" {
        return validate_legal_hold_replay_response(response);
    }
    if operation == "transitionRetentionRequest" {
        return response::validate_retention_replay_response(response);
    }
    let object = response
        .as_object()
        .ok_or(ServiceError::IdempotencyConflict)?;
    validate_closed_authority_replay_shape(operation, object)?;
    for key in ["aggregateId", "auditEventId"] {
        object
            .get(key)
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .filter(|value| !value.is_nil())
            .ok_or(ServiceError::IdempotencyConflict)?;
    }
    object
        .get("aggregateVersion")
        .and_then(Value::as_i64)
        .filter(|version| *version >= 1)
        .ok_or(ServiceError::IdempotencyConflict)?;
    let digest_key = if operation == "transitionRetentionRequest" {
        "receiptDigest"
    } else {
        "receiptToken"
    };
    object
        .get(digest_key)
        .and_then(Value::as_str)
        .filter(|digest| is_sha256(digest))
        .ok_or(ServiceError::IdempotencyConflict)?;
    if operation == "verifyResponseOrganizationIdentity" {
        object
            .get("identityAssertionId")
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .filter(|value| !value.is_nil())
            .ok_or(ServiceError::IdempotencyConflict)?;
    }
    validate_official_channel_replay(operation, object)?;
    validate_entity_authority_replay(operation, object)?;
    if operation == "createPrivacyCorrectionPlan" {
        validate_privacy_correction_plan_replay(object)?;
    }
    Ok(())
}

fn replay_created_version(object: &Map<String, Value>) -> Result<(), ServiceError> {
    if object.get("aggregateVersion").and_then(Value::as_i64) == Some(1) {
        Ok(())
    } else {
        Err(ServiceError::IdempotencyConflict)
    }
}

fn replay_uuid(object: &Map<String, Value>, key: &str) -> Result<(), ServiceError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .map(|_| ())
        .ok_or(ServiceError::IdempotencyConflict)
}

fn replay_entity_kind(object: &Map<String, Value>) -> Result<(), ServiceError> {
    match object.get("entityKind").and_then(Value::as_str) {
        Some("AGENCY" | "SUPPLIER") => Ok(()),
        _ => Err(ServiceError::IdempotencyConflict),
    }
}

fn replay_timestamp(object: &Map<String, Value>, key: &str) -> Result<(), ServiceError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| OffsetDateTime::parse(value, &Rfc3339).is_ok())
        .map(|_| ())
        .ok_or(ServiceError::IdempotencyConflict)
}

fn validate_legal_hold_replay_response(response: &Value) -> Result<(), ServiceError> {
    const EXPECTED_KEYS: &[&str] = &[
        "operationId",
        "requestId",
        "status",
        "aggregateId",
        "aggregateVersion",
        "auditEventId",
        "acceptedAt",
        "links",
    ];
    let object = response
        .as_object()
        .filter(|object| {
            object.len() == EXPECTED_KEYS.len()
                && EXPECTED_KEYS.iter().all(|key| object.contains_key(*key))
        })
        .ok_or(ServiceError::IdempotencyConflict)?;
    if object.get("operationId").and_then(Value::as_str) != Some("placeLegalHold")
        || object.get("status").and_then(Value::as_str) != Some("completed")
        || object.get("aggregateVersion").and_then(Value::as_i64) != Some(1)
        || !object.get("links").is_some_and(Value::is_array)
    {
        return Err(ServiceError::IdempotencyConflict);
    }
    for key in ["requestId", "aggregateId", "auditEventId"] {
        object
            .get(key)
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .filter(|value| !value.is_nil())
            .ok_or(ServiceError::IdempotencyConflict)?;
    }
    object
        .get("acceptedAt")
        .and_then(Value::as_str)
        .filter(|value| OffsetDateTime::parse(value, &Rfc3339).is_ok())
        .ok_or(ServiceError::IdempotencyConflict)?;
    Ok(())
}

fn command_receipt_data(
    operation: &OperationSpec,
    request_id: Uuid,
    audit_event_id: Uuid,
    prepared: &PreparedCommand,
) -> Result<Value, ServiceError> {
    let mut receipt_data = json!({"id":prepared.persisted_id,"resourceId":prepared.persisted_id,"resourceVersion":prepared.version,"version":prepared.version,"status":"completed","operationId":operation.id,"requestId":request_id,"aggregateId":prepared.persisted_id.to_string(),"aggregateVersion":prepared.version,"auditEventId":audit_event_id,"acceptedAt":prepared.occurred_text,"data":prepared.payload,"links":[]});
    let Some(receipt) = prepared.owner_receipt.as_ref() else {
        return Ok(receipt_data);
    };
    let object = receipt_data
        .as_object_mut()
        .ok_or(ServiceError::Persistence)?;
    object.insert("receiptToken".to_owned(), json!(receipt.receipt_digest));
    object.insert("receiptDigest".to_owned(), json!(receipt.receipt_digest));
    object.insert(
        "emittedEventIds".to_owned(),
        json!(receipt.outbox_event_ids),
    );
    for (key, value) in &receipt.response_fields {
        match object.get(key) {
            None => {
                object.insert(key.clone(), value.clone());
            }
            Some(existing) if existing == value => {}
            Some(_) => return Err(ServiceError::Persistence),
        }
    }
    Ok(receipt_data)
}

#[expect(
    clippy::too_many_arguments,
    reason = "audit resolution preserves the transaction-bound command context"
)]
async fn command_audit_event_id(
    owner_managed: bool,
    operation: &OperationSpec,
    actor_id: Uuid,
    session_id: Uuid,
    request_id: Uuid,
    key: &CommandKey,
    prepared: &PreparedCommand,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<Uuid, ServiceError> {
    match (owner_managed, prepared.owner_receipt.as_ref()) {
        (true, Some(receipt)) => Ok(receipt.audit_event_id),
        (true, None) | (false, Some(_)) => Err(ServiceError::Persistence),
        (false, None) => {
            append_audit_event(
                operation,
                actor_id,
                session_id,
                request_id,
                key,
                prepared,
                transaction,
            )
            .await
        }
    }
}

#[expect(
    clippy::too_many_arguments,
    reason = "event projection preserves the transaction-bound command context"
)]
async fn collect_pending_domain_events(
    owner_managed: bool,
    operation: &OperationSpec,
    payload: &Value,
    actor_id: Uuid,
    request_id: Uuid,
    previous_case_state: Option<&str>,
    prepared: &PreparedCommand,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<Vec<PendingDomainEvent>, ServiceError> {
    if owner_managed {
        return Ok(Vec::new());
    }
    let candidates = event_candidates(
        payload,
        EventCandidateContext {
            operation: operation.id,
            actor_id,
            request_id,
            resource_id: prepared.persisted_id,
            resource_version: prepared.version,
            occurred_at: &prepared.occurred_text,
            previous_case_state,
        },
    )?;
    enqueue_command_events(operation, &candidates, prepared, transaction).await
}

fn always_owner_managed_operation(operation: &str) -> bool {
    matches!(
        operation,
        "attestOrganizationOfficialChannel"
            | "attestEntityMaterialUseClosure"
            | "approveResponseExcerpt"
            | "createPrivacyCorrectionPlan"
            | "previewPublication"
            | "publishCase"
            | "placeLegalHold"
            | "submitReview"
            | "transitionRetentionRequest"
            | "verifyResponseOrganizationIdentity"
            | "revokeOrganizationOfficialChannel"
            | "classifyEntityPersonhood"
    )
}

pub(super) fn owner_managed_request(
    operation: &str,
    payload: &Value,
) -> Result<bool, ServiceError> {
    if always_owner_managed_operation(operation) {
        return Ok(true);
    }
    if operation != "resolveCorrectionRequest" {
        return Ok(false);
    }
    let resolution = payload
        .as_object()
        .and_then(|payload| string_value(payload, "resolution"))
        .ok_or(ServiceError::InvalidRequest)?;
    Ok(resolution == "RESOLVED")
}

pub(super) fn validate_owner_replay_if_required(
    operation: &str,
    response: &Value,
) -> Result<(), ServiceError> {
    let requires_validation = if always_owner_managed_operation(operation) {
        true
    } else if operation == "resolveCorrectionRequest" {
        response
            .as_object()
            .is_some_and(|response| response.contains_key("receiptToken"))
    } else {
        false
    };
    if requires_validation {
        validate_owner_replay_response(operation, response)?;
    }
    Ok(())
}

#[cfg(test)]
#[path = "command_runtime_tests.rs"]
mod tests;
