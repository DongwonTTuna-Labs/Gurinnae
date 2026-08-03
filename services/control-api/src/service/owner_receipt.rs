use super::*;

pub(super) fn parse_owner_command_receipt(
    operation: &str,
    result: &Value,
    aggregate_id: Uuid,
    aggregate_version_key: &str,
    accepted_at_key: &str,
    response_field_mappings: &[(&str, &str)],
) -> Result<OwnerCommandReceipt, ServiceError> {
    let object = result.as_object().ok_or(ServiceError::Persistence)?;
    let aggregate_version = object
        .get(aggregate_version_key)
        .and_then(Value::as_i64)
        .filter(|value| *value >= 1)
        .ok_or(ServiceError::Persistence)?;
    let audit_event_id = required_owner_uuid(object, "auditEventId")?;
    let receipt_digest = object
        .get("receiptDigest")
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)?
        .to_owned();
    let accepted_at = object
        .get(accepted_at_key)
        .and_then(Value::as_str)
        .filter(|value| OffsetDateTime::parse(value, &Rfc3339).is_ok())
        .ok_or(ServiceError::Persistence)?
        .to_owned();
    let expected_outbox_count = owner_outbox_cardinality(operation)?;
    let outbox_event_ids = object
        .get("outboxEventIds")
        .and_then(Value::as_array)
        .filter(|values| values.len() == expected_outbox_count)
        .ok_or(ServiceError::Persistence)?
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .filter(|value| !value.is_nil())
                .ok_or(ServiceError::Persistence)
        })
        .collect::<Result<Vec<_>, _>>()?;
    if outbox_event_ids.iter().collect::<BTreeSet<_>>().len() != outbox_event_ids.len() {
        return Err(ServiceError::Persistence);
    }
    if !object.get("replayed").is_some_and(Value::is_boolean) {
        return Err(ServiceError::Persistence);
    }
    let mut response_fields = Map::new();
    for (owner_key, response_key) in response_field_mappings {
        let value = object
            .get(*owner_key)
            .cloned()
            .ok_or(ServiceError::Persistence)?;
        response_fields.insert((*response_key).to_owned(), value);
    }
    Ok(OwnerCommandReceipt {
        aggregate_id,
        aggregate_version,
        audit_event_id,
        receipt_digest,
        accepted_at,
        outbox_event_ids,
        expected_outbox_count,
        response_fields,
    })
}

pub(super) fn owner_outbox_cardinality(operation: &str) -> Result<usize, ServiceError> {
    match operation {
        "previewPublication" => Ok(0),
        "attestOrganizationOfficialChannel"
        | "attestEntityMaterialUseClosure"
        | "approveResponseExcerpt"
        | "placeLegalHold"
        | "submitReview"
        | "transitionRetentionRequest"
        | "verifyResponseOrganizationIdentity"
        | "revokeOrganizationOfficialChannel"
        | "classifyEntityPersonhood" => Ok(1),
        "resolveCorrectionRequest" => Ok(4),
        "publishCase" => Ok(3),
        _ => Err(ServiceError::Persistence),
    }
}

pub(super) fn owner_result_has_exact_keys(
    result: &Value,
    expected: &[&str],
) -> Result<(), ServiceError> {
    let object = result.as_object().ok_or(ServiceError::Persistence)?;
    if object.len() != expected.len() || expected.iter().any(|key| !object.contains_key(*key)) {
        return Err(ServiceError::Persistence);
    }
    Ok(())
}

pub(super) fn required_owner_uuid(
    object: &Map<String, Value>,
    key: &str,
) -> Result<Uuid, ServiceError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::Persistence)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owner_receipt_parser_rejects_missing_outbox_proof() {
        let result = json!({
            "responseVersion":2,
            "receiptDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "auditEventId":"10000000-0000-4000-8000-000000000001",
            "approvedAt":"2026-08-01T00:00:00Z",
            "outboxEventIds":[],
            "replayed":false
        });
        assert!(matches!(
            parse_owner_command_receipt(
                "approveResponseExcerpt",
                &result,
                Uuid::new_v4(),
                "responseVersion",
                "approvedAt",
                &[],
            ),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn preview_owner_receipt_forbids_fabricated_outbox_events() {
        let result = json!({
            "caseVersion":2,
            "receiptDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "auditEventId":"10000000-0000-4000-8000-000000000001",
            "createdAt":"2026-08-01T00:00:00Z",
            "outboxEventIds":[],
            "replayed":false
        });
        assert!(
            parse_owner_command_receipt(
                "previewPublication",
                &result,
                Uuid::new_v4(),
                "caseVersion",
                "createdAt",
                &[],
            )
            .is_ok()
        );
        let mut fabricated = result;
        fabricated["outboxEventIds"] = json!(["10000000-0000-4000-8000-000000000002"]);
        assert!(matches!(
            parse_owner_command_receipt(
                "previewPublication",
                &fabricated,
                Uuid::new_v4(),
                "caseVersion",
                "createdAt",
                &[],
            ),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn resolved_correction_requires_four_distinct_outbox_receipts() {
        let result = json!({
            "caseVersion":3,
            "receiptDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "auditEventId":"10000000-0000-4000-8000-000000000001",
            "resolvedAt":"2026-08-01T00:00:00Z",
            "outboxEventIds":[
                "10000000-0000-4000-8000-000000000002",
                "10000000-0000-4000-8000-000000000003",
                "10000000-0000-4000-8000-000000000004",
                "10000000-0000-4000-8000-000000000005"
            ],
            "replayed":false
        });
        assert!(
            parse_owner_command_receipt(
                "resolveCorrectionRequest",
                &result,
                Uuid::new_v4(),
                "caseVersion",
                "resolvedAt",
                &[],
            )
            .is_ok()
        );

        let mut duplicate = result;
        duplicate["outboxEventIds"][3] = json!("10000000-0000-4000-8000-000000000004");
        assert!(matches!(
            parse_owner_command_receipt(
                "resolveCorrectionRequest",
                &duplicate,
                Uuid::new_v4(),
                "caseVersion",
                "resolvedAt",
                &[],
            ),
            Err(ServiceError::Persistence)
        ));
    }
}
