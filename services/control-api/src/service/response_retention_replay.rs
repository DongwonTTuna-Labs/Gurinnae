pub(super) fn validate_retention_replay_response(
    response: &Value,
) -> Result<(), ServiceError> {
    let mut receipt_fields = response
        .as_object()
        .cloned()
        .ok_or(ServiceError::IdempotencyConflict)?;
    let command = receipt_fields
        .remove("command")
        .and_then(|value| value.as_object().cloned())
        .ok_or(ServiceError::IdempotencyConflict)?;
    if !retention_receipt_has_exact_keys(&receipt_fields) {
        return Err(ServiceError::IdempotencyConflict);
    }
    let receipt: RetentionTransitionReceiptV2 =
        serde_json::from_value(Value::Object(receipt_fields))
            .map_err(|_| ServiceError::IdempotencyConflict)?;
    receipt
        .validate()
        .map_err(|_| ServiceError::IdempotencyConflict)?;
    validate_retention_replay_command(&command, &receipt)
}

fn validate_retention_replay_command(
    command: &Map<String, Value>,
    receipt: &RetentionTransitionReceiptV2,
) -> Result<(), ServiceError> {
    const EXPECTED_KEYS: &[&str] = &[
        "operationId",
        "requestId",
        "status",
        "aggregateId",
        "aggregateVersion",
        "auditEventId",
        "acceptedAt",
        "receiptDigest",
        "emittedEventIds",
        "idempotencyReplay",
        "links",
    ];
    if command.len() != EXPECTED_KEYS.len()
        || EXPECTED_KEYS.iter().any(|key| !command.contains_key(*key))
        || command.get("operationId").and_then(Value::as_str)
            != Some("transitionRetentionRequest")
        || command.get("status").and_then(Value::as_str) != Some("COMPLETED")
        || command.get("idempotencyReplay") != Some(&Value::Bool(false))
        || command.get("aggregateId") != Some(&json!(receipt.retention_request_id))
        || command.get("aggregateVersion") != Some(&json!(receipt.decision_version))
        || command.get("receiptDigest") != Some(&json!(receipt.transition_receipt_digest))
        || !valid_retention_replay_links(command.get("links"))
    {
        return Err(ServiceError::IdempotencyConflict);
    }
    for key in ["requestId", "auditEventId"] {
        command
            .get(key)
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .filter(|value| !value.is_nil())
            .ok_or(ServiceError::IdempotencyConflict)?;
    }
    let accepted_at = command
        .get("acceptedAt")
        .and_then(Value::as_str)
        .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
        .ok_or(ServiceError::IdempotencyConflict)?;
    let updated_at = OffsetDateTime::parse(&receipt.updated_at, &Rfc3339)
        .map_err(|_| ServiceError::IdempotencyConflict)?;
    if accepted_at != updated_at
        || !retention_replay_events_are_valid(command.get("emittedEventIds"), receipt.transition)
    {
        return Err(ServiceError::IdempotencyConflict);
    }
    Ok(())
}

fn retention_replay_events_are_valid(
    value: Option<&Value>,
    transition: RetentionTransitionV2,
) -> bool {
    let Some(values) = value.and_then(Value::as_array) else {
        return false;
    };
    let expected_count = if transition == RetentionTransitionV2::Reject {
        2
    } else {
        1
    };
    let event_ids = values
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .filter(|value| !value.is_nil())
        })
        .collect::<Option<Vec<_>>>();
    let Some(event_ids) = event_ids else {
        return false;
    };
    event_ids.len() == expected_count
        && event_ids.windows(2).all(|pair| pair[0] < pair[1])
}

fn valid_retention_replay_links(value: Option<&Value>) -> bool {
    value.and_then(Value::as_array).is_some_and(|links| {
        links.len() <= 32
            && links.iter().all(|link| {
                link.as_object().is_some_and(|link| {
                    link.len() == 2
                        && ["rel", "href"].iter().all(|key| {
                            link.get(*key).and_then(Value::as_str).is_some_and(|value| {
                                !value.is_empty() && !value.chars().any(char::is_control)
                            })
                        })
                })
            })
    })
}
