use super::*;

pub(super) fn validate_requested_target(target: &Value) -> Result<(), ServiceError> {
    let object = target.as_object().ok_or(ServiceError::InvalidRequest)?;
    let kind = object
        .get("targetKind")
        .and_then(Value::as_str)
        .ok_or(ServiceError::InvalidRequest)?;
    if kind == "AUDIT_SUBJECT_RECORD" {
        return Err(ServiceError::LegalHoldTargetUnsupported);
    }
    let target_id = required_uuid(object, "targetId")?;
    object
        .get("targetVersion")
        .and_then(Value::as_i64)
        .filter(|value| *value >= 1)
        .ok_or(ServiceError::InvalidRequest)?;
    let target_digest = required_digest(object, "targetDigest")?;
    match kind {
        "CASE" => validate_case_target(object, target_id),
        "PUBLICATION" => {
            validate_single_id_target(object, kind, "publicationRevisionId", target_id)
        }
        "EVIDENCE" => validate_single_id_target(object, kind, "evidenceId", target_id),
        "RESPONSE" => validate_single_id_target(object, kind, "responseId", target_id),
        "SOURCE_ASSET" => {
            validate_asset_target(object, kind, "sourceDocumentId", "sourceAssetId", target_id)
        }
        "RESEARCH_ARTIFACT" => validate_asset_target(
            object,
            kind,
            "researchArtifactId",
            "researchAssetId",
            target_id,
        ),
        "PRIVACY_REQUEST" => validate_privacy_target(object, target_id),
        "COMMUNICATION_SUBJECT" => validate_communication_target(object, target_id),
        "SUPPLIER_RETENTION_SNAPSHOT" => {
            validate_entity_target(object, kind, "SUPPLIER", target_id, target_digest)
        }
        "AGENCY_RETENTION_SNAPSHOT" => {
            validate_entity_target(object, kind, "AGENCY", target_id, target_digest)
        }
        "CORRECTION" => validate_correction_target(object, target_id, target_digest),
        "SUBSCRIPTION" => validate_subscription_target(object, target_id, target_digest),
        "COMMUNICATION_ENDPOINT" => validate_communication_endpoint_target(object, target_id),
        _ => Err(ServiceError::InvalidRequest),
    }
}

fn validate_case_target(object: &Map<String, Value>, target_id: Uuid) -> Result<(), ServiceError> {
    exact_keys(
        object,
        &[
            "targetKind",
            "targetId",
            "targetVersion",
            "targetDigest",
            "caseId",
            "reviewSnapshotId",
            "reviewSnapshotDigest",
        ],
    )?;
    if required_uuid(object, "caseId")? != target_id {
        return Err(ServiceError::InvalidRequest);
    }
    required_uuid(object, "reviewSnapshotId")?;
    required_digest(object, "reviewSnapshotDigest")?;
    Ok(())
}

fn validate_single_id_target(
    object: &Map<String, Value>,
    kind: &str,
    concrete_id_key: &str,
    target_id: Uuid,
) -> Result<(), ServiceError> {
    exact_keys(
        object,
        &[
            "targetKind",
            "targetId",
            "targetVersion",
            "targetDigest",
            concrete_id_key,
        ],
    )?;
    if object.get("targetKind").and_then(Value::as_str) != Some(kind)
        || required_uuid(object, concrete_id_key)? != target_id
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

fn validate_asset_target(
    object: &Map<String, Value>,
    kind: &str,
    parent_id_key: &str,
    asset_id_key: &str,
    target_id: Uuid,
) -> Result<(), ServiceError> {
    exact_keys(
        object,
        &[
            "targetKind",
            "targetId",
            "targetVersion",
            "targetDigest",
            parent_id_key,
            asset_id_key,
        ],
    )?;
    required_uuid(object, parent_id_key)?;
    if object.get("targetKind").and_then(Value::as_str) != Some(kind)
        || required_uuid(object, asset_id_key)? != target_id
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

fn validate_privacy_target(
    object: &Map<String, Value>,
    target_id: Uuid,
) -> Result<(), ServiceError> {
    exact_keys(
        object,
        &[
            "targetKind",
            "targetId",
            "targetVersion",
            "targetDigest",
            "privacyRequestId",
            "privacyRequestType",
        ],
    )?;
    object
        .get("privacyRequestType")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "ACCESS" | "CORRECTION" | "DELETION" | "RESTRICTION"))
        .ok_or(ServiceError::InvalidRequest)?;
    if required_uuid(object, "privacyRequestId")? != target_id {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

fn validate_communication_target(
    object: &Map<String, Value>,
    target_id: Uuid,
) -> Result<(), ServiceError> {
    exact_keys(
        object,
        &[
            "targetKind",
            "targetId",
            "targetVersion",
            "targetDigest",
            "communicationSubjectId",
            "communicationSubjectOriginDigest",
        ],
    )?;
    required_digest(object, "communicationSubjectOriginDigest")?;
    if required_uuid(object, "communicationSubjectId")? != target_id {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

fn validate_entity_target(
    object: &Map<String, Value>,
    target_kind: &str,
    entity_kind: &str,
    target_id: Uuid,
    target_digest: &str,
) -> Result<(), ServiceError> {
    exact_keys(
        object,
        &[
            "targetKind",
            "targetId",
            "targetVersion",
            "targetDigest",
            "entityKind",
            "entityRetentionSnapshotId",
            "entityRetentionSnapshotDigest",
        ],
    )?;
    if object.get("targetKind").and_then(Value::as_str) != Some(target_kind)
        || object.get("entityKind").and_then(Value::as_str) != Some(entity_kind)
        || required_uuid(object, "entityRetentionSnapshotId")? != target_id
        || required_digest(object, "entityRetentionSnapshotDigest")? != target_digest
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

fn validate_correction_target(
    object: &Map<String, Value>,
    target_id: Uuid,
    target_digest: &str,
) -> Result<(), ServiceError> {
    exact_keys(
        object,
        &[
            "targetKind",
            "targetId",
            "targetVersion",
            "targetDigest",
            "correctionId",
            "correctionSnapshotId",
            "correctionSnapshotDigest",
        ],
    )?;
    required_uuid(object, "correctionId")?;
    if required_uuid(object, "correctionSnapshotId")? != target_id
        || required_digest(object, "correctionSnapshotDigest")? != target_digest
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

fn validate_subscription_target(
    object: &Map<String, Value>,
    target_id: Uuid,
    target_digest: &str,
) -> Result<(), ServiceError> {
    exact_keys(
        object,
        &[
            "targetKind",
            "targetId",
            "targetVersion",
            "targetDigest",
            "subscriptionId",
            "subscriptionSnapshotId",
            "subscriptionSnapshotDigest",
        ],
    )?;
    required_uuid(object, "subscriptionId")?;
    if required_uuid(object, "subscriptionSnapshotId")? != target_id
        || required_digest(object, "subscriptionSnapshotDigest")? != target_digest
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

fn validate_communication_endpoint_target(
    object: &Map<String, Value>,
    target_id: Uuid,
) -> Result<(), ServiceError> {
    exact_keys(
        object,
        &[
            "targetKind",
            "targetId",
            "targetVersion",
            "targetDigest",
            "communicationEndpointId",
        ],
    )?;
    if required_uuid(object, "communicationEndpointId")? != target_id {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

fn exact_keys(object: &Map<String, Value>, expected: &[&str]) -> Result<(), ServiceError> {
    if object.len() != expected.len() || expected.iter().any(|key| !object.contains_key(*key)) {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(())
}

fn required_uuid(object: &Map<String, Value>, key: &str) -> Result<Uuid, ServiceError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::InvalidRequest)
}

fn required_digest<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a str, ServiceError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::InvalidRequest)
}
