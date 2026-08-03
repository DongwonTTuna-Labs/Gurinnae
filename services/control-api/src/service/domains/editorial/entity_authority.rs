use super::*;

const ENTITY_GOVERNANCE_CAPABILITY: &str = "users.manage";

const CLASSIFICATION_RESULT_KEYS: &[&str] = &[
    "receiptId",
    "entityKind",
    "entityId",
    "classification",
    "receiptDigest",
    "auditEventId",
    "classifiedAt",
    "outboxEventIds",
    "replayed",
];

const CLOSURE_RESULT_KEYS: &[&str] = &[
    "closureReceiptId",
    "entityKind",
    "entityId",
    "personhoodReceiptId",
    "receiptDigest",
    "closureAt",
    "lastContractEndAt",
    "linkedPublicationRevisionCount",
    "auditEventId",
    "attestedAt",
    "outboxEventIds",
    "replayed",
];

pub(super) async fn classify(
    payload: &Map<String, Value>,
    actor: Uuid,
    session_id: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    let owner_request = classification_owner_request(payload)?;
    let request_id = server_uuid(payload, "_requestId")?;
    let idempotency_key_sha256 = server_sha256(payload, "_idempotencyKeySha256")?;
    let request_sha256 = server_sha256(payload, "_requestSha256")?;
    let result = sqlx::query_scalar::<_, Value>(
        "SELECT ops.classify_r6d_entity_personhood_v1($1,$2,$3,$4,$5,$6)",
    )
    .bind(&owner_request)
    .bind(actor)
    .bind(session_id)
    .bind(request_id)
    .bind(idempotency_key_sha256)
    .bind(request_sha256)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    parse_classification_result(&result, &owner_request)
}

pub(super) async fn attest_closure(
    payload: &Map<String, Value>,
    actor: Uuid,
    session_id: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    let owner_request = closure_owner_request(payload)?;
    let request_id = server_uuid(payload, "_requestId")?;
    let idempotency_key_sha256 = server_sha256(payload, "_idempotencyKeySha256")?;
    let request_sha256 = server_sha256(payload, "_requestSha256")?;
    let result = sqlx::query_scalar::<_, Value>(
        "SELECT ops.attest_r6d_entity_material_use_closure_v1($1,$2,$3,$4,$5,$6)",
    )
    .bind(&owner_request)
    .bind(actor)
    .bind(session_id)
    .bind(request_id)
    .bind(idempotency_key_sha256)
    .bind(request_sha256)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    parse_closure_result(&result, &owner_request)
}

fn classification_owner_request(payload: &Map<String, Value>) -> Result<Value, ServiceError> {
    let entity_kind = entity_kind(payload)?;
    let entity_id = public_uuid(payload, "entityId")?;
    let classification = match string_value(payload, "classification") {
        Some(value @ ("NATURAL_PERSON" | "NOT_NATURAL_PERSON")) => value,
        _ => return Err(ServiceError::InvalidRequest),
    };
    let evidence_source_locator = bounded_text(payload, "evidenceSourceLocator", 2_000)?;
    let expected_entity_updated_at = public_timestamp(payload, "expectedEntityUpdatedAt")?;
    let reason = bounded_text(payload, "reason", 4_000)?;
    let authority = actor_authority(payload)?;
    Ok(json!({
        "entityKind": entity_kind,
        "entityId": entity_id,
        "classification": classification,
        "evidenceSourceLocator": evidence_source_locator,
        "expectedEntityUpdatedAt": expected_entity_updated_at,
        "reason": reason,
        "_actorAssertionJti": authority.assertion_jti,
        "_actorAssertionRequestSha256": authority.assertion_request_digest,
        "_actorAssuranceLevel": "STEP_UP",
        "_actorEffectiveCapability": ENTITY_GOVERNANCE_CAPABILITY,
        "_actorActionDigest": authority.action_digest,
        "_actorStepUpAuthorizationId": authority.step_up_authorization_id,
        "_actorIdempotencyKeySha256": authority.idempotency_key_sha256,
        "_actorRequestKeySha256": authority.request_key_sha256,
    }))
}

fn closure_owner_request(payload: &Map<String, Value>) -> Result<Value, ServiceError> {
    let entity_kind = entity_kind(payload)?;
    let entity_id = public_uuid(payload, "entityId")?;
    let personhood_receipt_id = public_uuid(payload, "personhoodReceiptId")?;
    let expected_entity_updated_at = public_timestamp(payload, "expectedEntityUpdatedAt")?;
    let reason = bounded_text(payload, "reason", 4_000)?;
    let authority = actor_authority(payload)?;
    Ok(json!({
        "entityKind": entity_kind,
        "entityId": entity_id,
        "personhoodReceiptId": personhood_receipt_id,
        "expectedEntityUpdatedAt": expected_entity_updated_at,
        "reason": reason,
        "_actorAssertionJti": authority.assertion_jti,
        "_actorAssertionRequestSha256": authority.assertion_request_digest,
        "_actorAssuranceLevel": "STEP_UP",
        "_actorEffectiveCapability": ENTITY_GOVERNANCE_CAPABILITY,
        "_actorActionDigest": authority.action_digest,
        "_actorStepUpAuthorizationId": authority.step_up_authorization_id,
        "_actorIdempotencyKeySha256": authority.idempotency_key_sha256,
        "_actorRequestKeySha256": authority.request_key_sha256,
    }))
}

struct ActorAuthority<'a> {
    assertion_jti: Uuid,
    assertion_request_digest: &'a str,
    action_digest: &'a str,
    step_up_authorization_id: Uuid,
    idempotency_key_sha256: &'a str,
    request_key_sha256: &'a str,
}

fn actor_authority(payload: &Map<String, Value>) -> Result<ActorAuthority<'_>, ServiceError> {
    if string_value(payload, "_actorAssuranceLevel") != Some("STEP_UP")
        || string_value(payload, "_actorEffectiveCapability") != Some(ENTITY_GOVERNANCE_CAPABILITY)
    {
        return Err(ServiceError::PreconditionFailed);
    }
    Ok(ActorAuthority {
        assertion_jti: server_uuid(payload, "_actorAssertionJti")?,
        assertion_request_digest: server_sha256(payload, "_actorAssertionRequestSha256")?,
        action_digest: server_sha256(payload, "_actorActionDigest")?,
        step_up_authorization_id: server_uuid(payload, "_actorStepUpAuthorizationId")?,
        idempotency_key_sha256: server_sha256(payload, "_actorIdempotencyKeySha256")?,
        request_key_sha256: server_sha256(payload, "_actorRequestKeySha256")?,
    })
}

fn parse_classification_result(
    result: &Value,
    request: &Value,
) -> Result<OwnerCommandReceipt, ServiceError> {
    owner_result_has_exact_keys(result, CLASSIFICATION_RESULT_KEYS)?;
    let object = result.as_object().ok_or(ServiceError::Persistence)?;
    let request = request.as_object().ok_or(ServiceError::Persistence)?;
    validate_result_binding(
        object,
        request,
        &["entityKind", "entityId", "classification"],
    )?;
    let receipt_id = required_owner_uuid(object, "receiptId")?;
    let mut response_fields = Map::new();
    for key in ["receiptId", "entityKind", "entityId", "classification"] {
        response_fields.insert(key.to_owned(), required_result(object, key)?.clone());
    }
    parse_receipt(
        object,
        receipt_id,
        "receiptDigest",
        "classifiedAt",
        response_fields,
    )
}

fn parse_closure_result(
    result: &Value,
    request: &Value,
) -> Result<OwnerCommandReceipt, ServiceError> {
    owner_result_has_exact_keys(result, CLOSURE_RESULT_KEYS)?;
    let object = result.as_object().ok_or(ServiceError::Persistence)?;
    let request = request.as_object().ok_or(ServiceError::Persistence)?;
    validate_result_binding(
        object,
        request,
        &["entityKind", "entityId", "personhoodReceiptId"],
    )?;
    let closure_receipt_id = required_owner_uuid(object, "closureReceiptId")?;
    result_timestamp(object, "closureAt")?;
    match object.get("lastContractEndAt") {
        Some(Value::Null) => {}
        Some(Value::String(value)) if OffsetDateTime::parse(value, &Rfc3339).is_ok() => {}
        _ => return Err(ServiceError::Persistence),
    }
    object
        .get("linkedPublicationRevisionCount")
        .and_then(Value::as_i64)
        .filter(|value| *value >= 0)
        .ok_or(ServiceError::Persistence)?;
    let mut response_fields = Map::new();
    for key in [
        "closureReceiptId",
        "entityKind",
        "entityId",
        "personhoodReceiptId",
        "closureAt",
        "lastContractEndAt",
        "linkedPublicationRevisionCount",
    ] {
        response_fields.insert(key.to_owned(), required_result(object, key)?.clone());
    }
    parse_receipt(
        object,
        closure_receipt_id,
        "receiptDigest",
        "attestedAt",
        response_fields,
    )
}

fn parse_receipt(
    object: &Map<String, Value>,
    aggregate_id: Uuid,
    receipt_digest_key: &str,
    accepted_at_key: &str,
    response_fields: Map<String, Value>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    let audit_event_id = required_owner_uuid(object, "auditEventId")?;
    let receipt_digest = result_sha256(object, receipt_digest_key)?;
    let accepted_at = result_timestamp(object, accepted_at_key)?.to_owned();
    let outbox_event_ids = result_outbox_ids(object)?;
    if !object.get("replayed").is_some_and(Value::is_boolean) {
        return Err(ServiceError::Persistence);
    }
    Ok(OwnerCommandReceipt {
        aggregate_id,
        aggregate_version: 1,
        audit_event_id,
        receipt_digest: receipt_digest.to_owned(),
        accepted_at,
        outbox_event_ids,
        expected_outbox_count: 1,
        response_fields,
    })
}

fn validate_result_binding(
    result: &Map<String, Value>,
    request: &Map<String, Value>,
    keys: &[&str],
) -> Result<(), ServiceError> {
    if keys.iter().any(|key| result.get(*key) != request.get(*key)) {
        return Err(ServiceError::Persistence);
    }
    Ok(())
}

fn entity_kind(payload: &Map<String, Value>) -> Result<&str, ServiceError> {
    match string_value(payload, "entityKind") {
        Some(value @ ("AGENCY" | "SUPPLIER")) => Ok(value),
        _ => Err(ServiceError::InvalidRequest),
    }
}

fn public_uuid(payload: &Map<String, Value>, key: &str) -> Result<Uuid, ServiceError> {
    uuid_value(payload, &[key])
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::InvalidRequest)
}

fn server_uuid(payload: &Map<String, Value>, key: &str) -> Result<Uuid, ServiceError> {
    uuid_value(payload, &[key])
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::Persistence)
}

fn server_sha256<'a>(payload: &'a Map<String, Value>, key: &str) -> Result<&'a str, ServiceError> {
    string_value(payload, key)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)
}

fn bounded_text<'a>(
    payload: &'a Map<String, Value>,
    key: &str,
    maximum_chars: usize,
) -> Result<&'a str, ServiceError> {
    string_value(payload, key)
        .filter(|value| {
            value.trim() == *value
                && (1..=maximum_chars).contains(&value.chars().count())
                && !value.chars().any(char::is_control)
        })
        .ok_or(ServiceError::InvalidRequest)
}

fn public_timestamp<'a>(
    payload: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a str, ServiceError> {
    string_value(payload, key)
        .filter(|value| OffsetDateTime::parse(value, &Rfc3339).is_ok())
        .ok_or(ServiceError::InvalidRequest)
}

fn required_result<'a>(
    object: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a Value, ServiceError> {
    object.get(key).ok_or(ServiceError::Persistence)
}

fn result_sha256<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str, ServiceError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)
}

fn result_timestamp<'a>(
    object: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a str, ServiceError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| OffsetDateTime::parse(value, &Rfc3339).is_ok())
        .ok_or(ServiceError::Persistence)
}

fn result_outbox_ids(object: &Map<String, Value>) -> Result<Vec<Uuid>, ServiceError> {
    object
        .get("outboxEventIds")
        .and_then(Value::as_array)
        .filter(|values| values.len() == 1)
        .ok_or(ServiceError::Persistence)?
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .filter(|value| !value.is_nil())
                .ok_or(ServiceError::Persistence)
        })
        .collect()
}

#[cfg(test)]
#[path = "entity_authority_tests.rs"]
mod tests;
