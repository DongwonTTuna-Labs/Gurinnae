fn validate_closed_authority_replay_shape(
    operation: &str,
    object: &Map<String, Value>,
) -> Result<(), ServiceError> {
    const COMMON_FIELDS: &[&str] = &[
        "operationId",
        "requestId",
        "status",
        "aggregateId",
        "aggregateVersion",
        "auditEventId",
        "receiptToken",
        "acceptedAt",
        "links",
    ];
    let operation_fields: &[&str] = match operation {
        "attestOrganizationOfficialChannel" => &[
            "assertionId",
            "authorityReceiptId",
            "authorityReceiptDigest",
            "registryReceiptDigest",
            "expiresAt",
        ],
        "revokeOrganizationOfficialChannel" => &["revocationId", "assertionId"],
        "classifyEntityPersonhood" => &["receiptId", "entityKind", "entityId", "classification"],
        "attestEntityMaterialUseClosure" => &[
            "closureReceiptId",
            "entityKind",
            "entityId",
            "personhoodReceiptId",
            "closureAt",
            "lastContractEndAt",
            "linkedPublicationRevisionCount",
        ],
        _ => return Ok(()),
    };
    if object.len() != COMMON_FIELDS.len() + operation_fields.len()
        || object.keys().any(|key| {
            !COMMON_FIELDS.contains(&key.as_str()) && !operation_fields.contains(&key.as_str())
        })
        || object.get("operationId").and_then(Value::as_str) != Some(operation)
        || object.get("status").and_then(Value::as_str) != Some("completed")
    {
        return Err(ServiceError::IdempotencyConflict);
    }
    replay_uuid(object, "requestId")?;
    replay_timestamp(object, "acceptedAt")?;
    validate_replay_links(object)
}

fn validate_replay_links(object: &Map<String, Value>) -> Result<(), ServiceError> {
    let links = object
        .get("links")
        .and_then(Value::as_array)
        .filter(|links| links.len() <= 32)
        .ok_or(ServiceError::IdempotencyConflict)?;
    for link in links {
        let link = link
            .as_object()
            .filter(|link| {
                link.len() == 2
                    && link.contains_key("rel")
                    && link.contains_key("href")
                    && link.values().all(Value::is_string)
            })
            .ok_or(ServiceError::IdempotencyConflict)?;
        if link
            .values()
            .filter_map(Value::as_str)
            .any(|value| value.is_empty() || value.chars().any(char::is_control))
        {
            return Err(ServiceError::IdempotencyConflict);
        }
    }
    Ok(())
}

fn validate_official_channel_replay(
    operation: &str,
    object: &Map<String, Value>,
) -> Result<(), ServiceError> {
    match operation {
        "attestOrganizationOfficialChannel" => {
            replay_created_version(object)?;
            for key in ["assertionId", "authorityReceiptId"] {
                replay_uuid(object, key)?;
            }
            for key in ["authorityReceiptDigest", "registryReceiptDigest"] {
                object
                    .get(key)
                    .and_then(Value::as_str)
                    .filter(|value| is_sha256(value))
                    .ok_or(ServiceError::IdempotencyConflict)?;
            }
            replay_timestamp(object, "expiresAt")?;
            if object.get("aggregateId") != object.get("assertionId")
                || object.get("receiptToken") != object.get("registryReceiptDigest")
            {
                return Err(ServiceError::IdempotencyConflict);
            }
        }
        "revokeOrganizationOfficialChannel" => {
            replay_created_version(object)?;
            for key in ["revocationId", "assertionId"] {
                replay_uuid(object, key)?;
            }
            if object.get("aggregateId") != object.get("assertionId") {
                return Err(ServiceError::IdempotencyConflict);
            }
        }
        _ => {}
    }
    Ok(())
}

fn validate_entity_authority_replay(
    operation: &str,
    object: &Map<String, Value>,
) -> Result<(), ServiceError> {
    match operation {
        "classifyEntityPersonhood" => {
            replay_created_version(object)?;
            for key in ["receiptId", "entityId"] {
                replay_uuid(object, key)?;
            }
            replay_entity_kind(object)?;
            match object.get("classification").and_then(Value::as_str) {
                Some("NATURAL_PERSON" | "NOT_NATURAL_PERSON") => {}
                _ => return Err(ServiceError::IdempotencyConflict),
            }
            if object.get("aggregateId") != object.get("receiptId") {
                return Err(ServiceError::IdempotencyConflict);
            }
        }
        "attestEntityMaterialUseClosure" => {
            replay_created_version(object)?;
            for key in ["closureReceiptId", "entityId", "personhoodReceiptId"] {
                replay_uuid(object, key)?;
            }
            replay_entity_kind(object)?;
            replay_timestamp(object, "closureAt")?;
            match object.get("lastContractEndAt") {
                Some(Value::Null) => {}
                Some(Value::String(value)) if OffsetDateTime::parse(value, &Rfc3339).is_ok() => {}
                _ => return Err(ServiceError::IdempotencyConflict),
            }
            object
                .get("linkedPublicationRevisionCount")
                .and_then(Value::as_i64)
                .filter(|value| *value >= 0)
                .ok_or(ServiceError::IdempotencyConflict)?;
            if object.get("aggregateId") != object.get("closureReceiptId") {
                return Err(ServiceError::IdempotencyConflict);
            }
        }
        _ => {}
    }
    Ok(())
}
