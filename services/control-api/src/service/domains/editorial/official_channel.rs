use super::*;

const ATTEST_RESULT_KEYS: &[&str] = &[
    "assertionId",
    "assertionVersion",
    "authorityReceiptId",
    "authorityReceiptDigest",
    "registryReceiptDigest",
    "auditEventId",
    "attestedAt",
    "expiresAt",
    "outboxEventIds",
    "replayed",
];

const REVOKE_RESULT_KEYS: &[&str] = &[
    "revocationId",
    "assertionId",
    "revocationReceiptDigest",
    "auditEventId",
    "revokedAt",
    "outboxEventIds",
    "replayed",
];

pub(super) async fn attest(
    payload: &Map<String, Value>,
    actor: Uuid,
    session_id: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    let owner_request = attest_owner_request(payload)?;
    let request_id = server_uuid(payload, "_requestId")?;
    let idempotency_key_sha256 = server_sha256(payload, "_idempotencyKeySha256")?;
    let request_sha256 = server_sha256(payload, "_requestSha256")?;
    let result = sqlx::query_scalar::<_, Value>(
        "SELECT editorial.attest_organization_official_channel_v1($1,$2,$3,$4,$5,$6)",
    )
    .bind(owner_request)
    .bind(actor)
    .bind(session_id)
    .bind(request_id)
    .bind(idempotency_key_sha256)
    .bind(request_sha256)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    parse_attest_result(&result)
}

pub(super) async fn revoke(
    payload: &Map<String, Value>,
    actor: Uuid,
    session_id: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    let owner_request = revoke_owner_request(payload)?;
    let request_id = server_uuid(payload, "_requestId")?;
    let idempotency_key_sha256 = server_sha256(payload, "_idempotencyKeySha256")?;
    let request_sha256 = server_sha256(payload, "_requestSha256")?;
    let result = sqlx::query_scalar::<_, Value>(
        "SELECT editorial.revoke_organization_official_channel_v1($1,$2,$3,$4,$5,$6)",
    )
    .bind(owner_request)
    .bind(actor)
    .bind(session_id)
    .bind(request_id)
    .bind(idempotency_key_sha256)
    .bind(request_sha256)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    parse_revoke_result(&result)
}

fn attest_owner_request(payload: &Map<String, Value>) -> Result<Value, ServiceError> {
    let organization_kind = match string_value(payload, "organizationKind") {
        Some(value @ ("AGENCY" | "SUPPLIER")) => value,
        _ => return Err(ServiceError::InvalidRequest),
    };
    let verification_method = match string_value(payload, "verificationMethod") {
        Some(value @ ("OFFICIAL_DOMAIN_EMAIL" | "OFFICIAL_DOCUMENT")) => value,
        _ => return Err(ServiceError::InvalidRequest),
    };
    let organization_id = public_uuid(payload, "organizationId")?;
    let source_id = public_uuid(payload, "sourceId")?;
    let expires_at = string_value(payload, "expiresAt").ok_or(ServiceError::InvalidRequest)?;
    OffsetDateTime::parse(expires_at, &Rfc3339)
        .ok()
        .filter(|value| *value > OffsetDateTime::now_utc())
        .ok_or(ServiceError::InvalidRequest)?;
    let reason = bounded_text(payload, "reason", 4_000)?;
    if payload
        .get("expectedAuthorityVersion")
        .and_then(Value::as_i64)
        != Some(1)
    {
        return Err(ServiceError::InvalidRequest);
    }
    let authority = actor_authority(payload)?;
    Ok(json!({
        "organizationKind": organization_kind,
        "organizationId": organization_id,
        "verificationMethod": verification_method,
        "sourceId": source_id,
        "expiresAt": expires_at,
        "reason": reason,
        "expectedAuthorityVersion": 1,
        "_actorAssertionJti": authority.assertion_jti,
        "_actorAssertionRequestSha256": authority.assertion_request_digest,
        "_actorAssuranceLevel": "STEP_UP",
        "_actorEffectiveCapability": "responses.review",
        "_actorActionDigest": authority.action_digest,
        "_actorStepUpAuthorizationId": authority.step_up_authorization_id,
        "_actorIdempotencyKeySha256": authority.idempotency_key_sha256,
        "_actorRequestKeySha256": authority.request_key_sha256,
    }))
}

fn revoke_owner_request(payload: &Map<String, Value>) -> Result<Value, ServiceError> {
    let assertion_id = public_uuid(payload, "assertionId")?;
    let reason_code = reason_code(payload)?;
    let reason = bounded_text(payload, "reason", 4_000)?;
    let authority = actor_authority(payload)?;
    Ok(json!({
        "assertionId": assertion_id,
        "reasonCode": reason_code,
        "reason": reason,
        "_actorAssertionJti": authority.assertion_jti,
        "_actorAssertionRequestSha256": authority.assertion_request_digest,
        "_actorAssuranceLevel": "STEP_UP",
        "_actorEffectiveCapability": "responses.review",
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
        || string_value(payload, "_actorEffectiveCapability") != Some("responses.review")
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

fn parse_attest_result(result: &Value) -> Result<OwnerCommandReceipt, ServiceError> {
    owner_result_has_exact_keys(result, ATTEST_RESULT_KEYS)?;
    let object = result.as_object().ok_or(ServiceError::Persistence)?;
    let assertion_id = required_owner_uuid(object, "assertionId")?;
    if object.get("assertionVersion").and_then(Value::as_i64) != Some(1) {
        return Err(ServiceError::Persistence);
    }
    let authority_receipt_id = required_owner_uuid(object, "authorityReceiptId")?;
    let authority_receipt_digest = result_sha256(object, "authorityReceiptDigest")?;
    let registry_receipt_digest = result_sha256(object, "registryReceiptDigest")?;
    let expires_at = result_timestamp(object, "expiresAt")?;
    let mut response_fields = Map::new();
    response_fields.insert("assertionId".to_owned(), json!(assertion_id));
    response_fields.insert("authorityReceiptId".to_owned(), json!(authority_receipt_id));
    response_fields.insert(
        "authorityReceiptDigest".to_owned(),
        json!(authority_receipt_digest),
    );
    response_fields.insert(
        "registryReceiptDigest".to_owned(),
        json!(registry_receipt_digest),
    );
    response_fields.insert("expiresAt".to_owned(), json!(expires_at));
    owner_receipt(
        object,
        assertion_id,
        registry_receipt_digest,
        "attestedAt",
        response_fields,
    )
}

fn parse_revoke_result(result: &Value) -> Result<OwnerCommandReceipt, ServiceError> {
    owner_result_has_exact_keys(result, REVOKE_RESULT_KEYS)?;
    let object = result.as_object().ok_or(ServiceError::Persistence)?;
    let revocation_id = required_owner_uuid(object, "revocationId")?;
    let assertion_id = required_owner_uuid(object, "assertionId")?;
    let receipt_digest = result_sha256(object, "revocationReceiptDigest")?;
    let mut response_fields = Map::new();
    response_fields.insert("revocationId".to_owned(), json!(revocation_id));
    response_fields.insert("assertionId".to_owned(), json!(assertion_id));
    owner_receipt(
        object,
        assertion_id,
        receipt_digest,
        "revokedAt",
        response_fields,
    )
}

fn owner_receipt(
    object: &Map<String, Value>,
    aggregate_id: Uuid,
    receipt_digest: &str,
    accepted_at_key: &str,
    response_fields: Map<String, Value>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    let audit_event_id = required_owner_uuid(object, "auditEventId")?;
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

fn reason_code(payload: &Map<String, Value>) -> Result<&str, ServiceError> {
    bounded_text(payload, "reasonCode", 100)
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
    let values = object
        .get("outboxEventIds")
        .and_then(Value::as_array)
        .filter(|values| values.len() == 1)
        .ok_or(ServiceError::Persistence)?;
    values
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
#[path = "official_channel_tests.rs"]
mod tests;
