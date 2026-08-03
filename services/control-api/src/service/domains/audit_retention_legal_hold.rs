use super::*;

#[path = "audit_retention_legal_hold_target.rs"]
mod target;

use target::validate_requested_target;

const RECEIPT_SCHEMA: &str = "legal-hold-placement-receipt.v2";
const PUBLIC_REQUEST_KEYS: &[&str] = &[
    "target",
    "scopeAtoms",
    "affectedIds",
    "authorityReference",
    "reasonCode",
    "reason",
    "expiresAt",
];
const INTERNAL_REQUEST_KEYS: &[&str] = &[
    "_actorEffectiveCapability",
    "_actorAssertionJti",
    "_actorAssuranceLevel",
    "_actorActionDigest",
    "_actorStepUpAuthorizationId",
    "_actorIdempotencyKeySha256",
    "_actorAssertionRequestSha256",
    "_actorRequestKeySha256",
    "_requestId",
    "_requestSha256",
    "_idempotencyKeySha256",
];
const OWNER_RESULT_KEYS: &[&str] = &[
    "schemaVersion",
    "receiptId",
    "legalHoldId",
    "target",
    "scopeAtoms",
    "scopeAtomsDigest",
    "affectedIds",
    "affectedSetDigest",
    "authorityReferenceDigest",
    "reasonDigest",
    "placedByActorId",
    "placedAt",
    "expiresAt",
    "requestId",
    "requestDigest",
    "idempotencyKeySha256",
    "auditEventId",
    "auditReceiptDigest",
    "receiptDigest",
    "holdReceiptDigest",
    "outboxEventIds",
    "replayed",
];

struct LegalHoldOwnerRequest {
    payload: Value,
    target: Value,
    scope_atoms: Value,
    affected_ids: Value,
    authority_reference: String,
    reason: String,
    expires_at: Value,
    request_id: Uuid,
    request_digest: String,
    idempotency_key_sha256: String,
}

impl LegalHoldOwnerRequest {
    fn parse(payload: &Map<String, Value>) -> Result<Self, ServiceError> {
        validate_request_keys(payload)?;
        let (request_id, request_digest, idempotency_key_sha256) = validated_owner_proof(payload)?;
        let target = payload
            .get("target")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?;
        validate_requested_target(&target)?;
        let scope_atoms = validated_scope_atoms(payload.get("scopeAtoms"))?;
        let affected_ids = validated_affected_ids(payload.get("affectedIds"))?;
        let authority_reference = bounded_request_text(payload, "authorityReference", 500)?;
        bounded_request_text(payload, "reasonCode", 100)?;
        let reason = bounded_request_text(payload, "reason", 4_000)?;
        let expires_at = validated_expiration(payload.get("expiresAt"))?;
        let mut owner_payload = payload.clone();
        owner_payload.insert("scopeAtoms".to_owned(), scope_atoms.clone());
        owner_payload.insert("affectedIds".to_owned(), affected_ids.clone());
        owner_payload.insert("expiresAt".to_owned(), expires_at.clone());
        Ok(Self {
            payload: Value::Object(owner_payload),
            target,
            scope_atoms,
            affected_ids,
            authority_reference,
            reason,
            expires_at,
            request_id,
            request_digest,
            idempotency_key_sha256,
        })
    }
}

pub(super) async fn place(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<OwnerCommandReceipt, ServiceError> {
    let request = LegalHoldOwnerRequest::parse(payload)?;
    let result = sqlx::query_scalar::<_, Value>(
        "SELECT ops.place_legal_hold_v2($1::jsonb,$2::uuid,$3::uuid,$4::char(64),$5::char(64))",
    )
    .bind(&request.payload)
    .bind(actor)
    .bind(request.request_id)
    .bind(&request.idempotency_key_sha256)
    .bind(&request.request_digest)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    parse_owner_result(&result, &request, actor)
}

fn validate_request_keys(payload: &Map<String, Value>) -> Result<(), ServiceError> {
    const REQUIRED: &[&str] = &[
        "target",
        "scopeAtoms",
        "affectedIds",
        "authorityReference",
        "reasonCode",
        "reason",
    ];
    if REQUIRED.iter().any(|key| !payload.contains_key(*key))
        || INTERNAL_REQUEST_KEYS
            .iter()
            .any(|key| !payload.contains_key(*key))
        || payload.keys().any(|key| {
            !PUBLIC_REQUEST_KEYS.contains(&key.as_str())
                && !INTERNAL_REQUEST_KEYS.contains(&key.as_str())
        })
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

fn validated_owner_proof(
    payload: &Map<String, Value>,
) -> Result<(Uuid, String, String), ServiceError> {
    if payload
        .get("_actorEffectiveCapability")
        .and_then(Value::as_str)
        != Some("review.legal")
        || payload.get("_actorAssuranceLevel").and_then(Value::as_str) != Some("STEP_UP")
    {
        return Err(ServiceError::Persistence);
    }
    internal_uuid(payload, "_actorAssertionJti")?;
    internal_uuid(payload, "_actorStepUpAuthorizationId")?;
    internal_digest(payload, "_actorActionDigest")?;
    let actor_idempotency = internal_digest(payload, "_actorIdempotencyKeySha256")?;
    internal_digest(payload, "_actorAssertionRequestSha256")?;
    let actor_request_key = internal_digest(payload, "_actorRequestKeySha256")?;
    let request_id = internal_uuid(payload, "_requestId")?;
    let request_digest = internal_digest(payload, "_requestSha256")?.to_owned();
    let idempotency_key_sha256 = internal_digest(payload, "_idempotencyKeySha256")?.to_owned();
    if actor_idempotency != idempotency_key_sha256.as_str()
        || actor_request_key != idempotency_key_sha256.as_str()
    {
        return Err(ServiceError::Persistence);
    }
    Ok((request_id, request_digest, idempotency_key_sha256))
}

fn bounded_request_text(
    payload: &Map<String, Value>,
    key: &str,
    maximum_chars: usize,
) -> Result<String, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| {
            let length = value.chars().count();
            value.trim() == *value && (1..=maximum_chars).contains(&length)
        })
        .map(str::to_owned)
        .ok_or(ServiceError::InvalidRequest)
}

fn validated_expiration(value: Option<&Value>) -> Result<Value, ServiceError> {
    match value {
        None | Some(Value::Null) => Ok(Value::Null),
        Some(Value::String(value)) if OffsetDateTime::parse(value, &Rfc3339).is_ok() => {
            Ok(Value::String(value.clone()))
        }
        _ => Err(ServiceError::InvalidRequest),
    }
}

fn validated_scope_atoms(value: Option<&Value>) -> Result<Value, ServiceError> {
    let atoms = value
        .and_then(Value::as_array)
        .filter(|atoms| (1..=3).contains(&atoms.len()))
        .ok_or(ServiceError::InvalidRequest)?;
    let mut unique = BTreeSet::new();
    for atom in atoms {
        let atom = atom.as_str().ok_or(ServiceError::InvalidRequest)?;
        if !matches!(atom, "RETENTION" | "DELETION" | "DISCLOSURE") || !unique.insert(atom) {
            return Err(ServiceError::InvalidRequest);
        }
    }
    Ok(Value::Array(
        unique
            .into_iter()
            .map(|atom| Value::String(atom.to_owned()))
            .collect(),
    ))
}

fn validated_affected_ids(value: Option<&Value>) -> Result<Value, ServiceError> {
    let affected_ids = value
        .and_then(Value::as_array)
        .filter(|values| (1..=10_000).contains(&values.len()))
        .ok_or(ServiceError::InvalidRequest)?;
    let mut unique = BTreeSet::new();
    for value in affected_ids {
        let id = value
            .as_str()
            .and_then(|value| Uuid::parse_str(value).ok())
            .filter(|value| !value.is_nil())
            .ok_or(ServiceError::InvalidRequest)?;
        if !unique.insert(id) {
            return Err(ServiceError::InvalidRequest);
        }
    }
    Ok(Value::Array(
        unique
            .into_iter()
            .map(|id| Value::String(id.to_string()))
            .collect(),
    ))
}

fn internal_uuid(payload: &Map<String, Value>, key: &str) -> Result<Uuid, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::Persistence)
}

fn internal_digest<'a>(
    payload: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a str, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)
}

fn parse_owner_result(
    result: &Value,
    request: &LegalHoldOwnerRequest,
    actor: Uuid,
) -> Result<OwnerCommandReceipt, ServiceError> {
    owner_result_has_exact_keys(result, OWNER_RESULT_KEYS)?;
    let object = result.as_object().ok_or(ServiceError::Persistence)?;
    if object.get("schemaVersion").and_then(Value::as_str) != Some(RECEIPT_SCHEMA) {
        return Err(ServiceError::Persistence);
    }
    required_owner_uuid(object, "receiptId")?;
    let legal_hold_id = required_owner_uuid(object, "legalHoldId")?;
    let audit_event_id = required_owner_uuid(object, "auditEventId")?;
    if required_owner_uuid(object, "placedByActorId")? != actor
        || required_owner_uuid(object, "requestId")? != request.request_id
    {
        return Err(ServiceError::Persistence);
    }
    validate_persisted_target(object.get("target"), &request.target)?;
    if object.get("scopeAtoms") != Some(&request.scope_atoms)
        || object.get("affectedIds") != Some(&request.affected_ids)
        || !same_expiration(object.get("expiresAt"), &request.expires_at)
    {
        return Err(ServiceError::Persistence);
    }
    validate_result_digests(object, request)?;
    let placed_at = object
        .get("placedAt")
        .and_then(Value::as_str)
        .filter(|value| OffsetDateTime::parse(value, &Rfc3339).is_ok())
        .ok_or(ServiceError::Persistence)?
        .to_owned();
    let outbox_event_ids = exact_outbox_event_ids(object)?;
    if !object.get("replayed").is_some_and(Value::is_boolean) {
        return Err(ServiceError::Persistence);
    }
    Ok(OwnerCommandReceipt {
        aggregate_id: legal_hold_id,
        aggregate_version: 1,
        audit_event_id,
        receipt_digest: required_result_digest(object, "receiptDigest")?.to_owned(),
        accepted_at: placed_at,
        outbox_event_ids,
        expected_outbox_count: 1,
        response_fields: Map::new(),
    })
}

fn validate_persisted_target(value: Option<&Value>, requested: &Value) -> Result<(), ServiceError> {
    let persisted = value
        .and_then(Value::as_object)
        .ok_or(ServiceError::Persistence)?;
    let requested = requested.as_object().ok_or(ServiceError::Persistence)?;
    if persisted.len() != requested.len() + 1
        || requested
            .iter()
            .any(|(key, value)| persisted.get(key) != Some(value))
    {
        return Err(ServiceError::Persistence);
    }
    required_result_digest(persisted, "targetAnchorDigest")?;
    Ok(())
}

fn validate_result_digests(
    object: &Map<String, Value>,
    request: &LegalHoldOwnerRequest,
) -> Result<(), ServiceError> {
    for key in [
        "scopeAtomsDigest",
        "affectedSetDigest",
        "authorityReferenceDigest",
        "reasonDigest",
        "requestDigest",
        "idempotencyKeySha256",
        "auditReceiptDigest",
        "receiptDigest",
        "holdReceiptDigest",
    ] {
        required_result_digest(object, key)?;
    }
    if required_result_digest(object, "authorityReferenceDigest")?
        != sha256(request.authority_reference.as_bytes())
        || required_result_digest(object, "reasonDigest")? != sha256(request.reason.as_bytes())
        || required_result_digest(object, "scopeAtomsDigest")?
            != canonical_value_digest(&request.scope_atoms)?
        || required_result_digest(object, "affectedSetDigest")?
            != canonical_value_digest(&request.affected_ids)?
        || required_result_digest(object, "requestDigest")? != request.request_digest
        || required_result_digest(object, "idempotencyKeySha256")? != request.idempotency_key_sha256
        || required_result_digest(object, "receiptDigest")?
            != required_result_digest(object, "holdReceiptDigest")?
    {
        return Err(ServiceError::Persistence);
    }
    Ok(())
}

fn canonical_value_digest(value: &Value) -> Result<String, ServiceError> {
    canonical_json(value)
        .map(|canonical| sha256(&canonical))
        .map_err(|_| ServiceError::Persistence)
}

fn required_result_digest<'a>(
    object: &'a Map<String, Value>,
    key: &str,
) -> Result<&'a str, ServiceError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)
}

fn exact_outbox_event_ids(object: &Map<String, Value>) -> Result<Vec<Uuid>, ServiceError> {
    let values = object
        .get("outboxEventIds")
        .and_then(Value::as_array)
        .filter(|values| values.len() == 1)
        .ok_or(ServiceError::Persistence)?;
    let event_id = values
        .first()
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::Persistence)?;
    Ok(vec![event_id])
}

fn same_expiration(actual: Option<&Value>, expected: &Value) -> bool {
    match (actual, expected) {
        (Some(Value::Null), Value::Null) => true,
        (Some(Value::String(actual)), Value::String(expected)) => {
            match (
                OffsetDateTime::parse(actual, &Rfc3339),
                OffsetDateTime::parse(expected, &Rfc3339),
            ) {
                (Ok(actual), Ok(expected)) => actual == expected,
                _ => false,
            }
        }
        _ => false,
    }
}

#[cfg(test)]
#[path = "audit_retention_legal_hold_tests.rs"]
mod tests;
