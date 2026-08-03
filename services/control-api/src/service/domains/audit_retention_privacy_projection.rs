use super::*;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum RequestType {
    Access,
    Correction,
    Deletion,
    Restriction,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum RequestState {
    Received,
    Review,
    Approved,
    Rejected,
    Completed,
}

const ACCESS_PROJECTION_KEYS: &[&str] = &[
    "schemaVersion",
    "retentionRequestId",
    "targetObjectType",
    "targetObjectId",
    "fieldPath",
    "partyName",
    "currentValueDigest",
    "projectionDigest",
    "responseVersion",
    "privacyIdentityProofReceiptId",
    "privacyIdentityProofReceiptDigest",
    "responseSubmissionReceiptId",
    "responseSubmissionReceiptDigest",
    "responseOriginReceiptId",
    "responseOriginReceiptDigest",
    "sourceResponseRequestId",
    "asOf",
];
const ACCESS_PROJECTION_PREIMAGE_KEYS: &[&str] = &[
    "schemaVersion",
    "retentionRequestId",
    "targetObjectType",
    "targetObjectId",
    "fieldPath",
    "partyName",
    "currentValueDigest",
    "responseVersion",
    "privacyIdentityProofReceiptId",
    "privacyIdentityProofReceiptDigest",
    "responseSubmissionReceiptId",
    "responseSubmissionReceiptDigest",
    "responseOriginReceiptId",
    "responseOriginReceiptDigest",
    "sourceResponseRequestId",
];

pub(super) struct AccessProjection {
    response_version: i64,
    current_value_digest: String,
}

pub(super) fn validate_access_projection(
    value: &Value,
    request_id: Uuid,
    request_type: RequestType,
    workspace_as_of: OffsetDateTime,
) -> Result<Option<AccessProjection>, ServiceError> {
    if value.is_null() {
        return Ok(None);
    }
    if !matches!(request_type, RequestType::Access | RequestType::Correction) {
        return Err(ServiceError::Persistence);
    }

    let projection = exact_object(value, ACCESS_PROJECTION_KEYS)?;
    if required(projection, "schemaVersion")?.as_str()
        != Some("privacy-response-party-name-access.v1")
        || uuid(required(projection, "retentionRequestId")?)? != request_id
        || required(projection, "targetObjectType")?.as_str() != Some("RESPONSE")
        || required(projection, "fieldPath")?.as_str() != Some("/partyName")
    {
        return Err(ServiceError::Persistence);
    }

    for key in [
        "targetObjectId",
        "privacyIdentityProofReceiptId",
        "responseSubmissionReceiptId",
        "responseOriginReceiptId",
        "sourceResponseRequestId",
    ] {
        uuid(required(projection, key)?)?;
    }
    for key in [
        "currentValueDigest",
        "projectionDigest",
        "privacyIdentityProofReceiptDigest",
        "responseSubmissionReceiptDigest",
        "responseOriginReceiptDigest",
    ] {
        digest(required(projection, key)?)?;
    }

    let party_name = required(projection, "partyName")?
        .as_str()
        .filter(|value| !value.contains('\0'))
        .ok_or(ServiceError::Persistence)?;
    let current_value_digest = digest(required(projection, "currentValueDigest")?)?;
    if sha256(party_name.as_bytes()) != current_value_digest {
        return Err(ServiceError::Persistence);
    }
    let response_version = positive_integer(required(projection, "responseVersion")?)?;
    let projection_digest = digest(required(projection, "projectionDigest")?)?;
    let projection_preimage = access_projection_preimage(projection)?;
    if canonical_json_digest(&projection_preimage)? != projection_digest {
        return Err(ServiceError::Persistence);
    }
    let projection_as_of = required_timestamp(projection, "asOf")?;
    if projection_as_of != workspace_as_of {
        return Err(ServiceError::Persistence);
    }

    Ok(Some(AccessProjection {
        response_version,
        current_value_digest: current_value_digest.to_owned(),
    }))
}

fn access_projection_preimage(projection: &Map<String, Value>) -> Result<Value, ServiceError> {
    let mut preimage = Map::new();
    for key in ACCESS_PROJECTION_PREIMAGE_KEYS {
        preimage.insert((*key).to_owned(), required(projection, key)?.clone());
    }
    preimage.insert(
        "schemaVersion".to_owned(),
        json!("privacy-response-party-name-access-preimage.v1"),
    );
    Ok(Value::Object(preimage))
}

pub(super) fn validate_completion(
    workspace: &Map<String, Value>,
    summary: &Summary,
    access_projection: Option<&AccessProjection>,
    highest_transition_version: i64,
) -> Result<(), ServiceError> {
    let receipt_id = nullable_uuid(required(workspace, "completionReceiptId")?)?;
    let receipt_digest = nullable_digest(required(workspace, "completionReceiptDigest")?)?;
    let response_version =
        nullable_positive_integer(required(workspace, "completedResponseVersion")?)?;
    let value_digest = nullable_digest(required(workspace, "completedValueDigest")?)?;
    let completion_present = [
        receipt_id.is_some(),
        receipt_digest.is_some(),
        response_version.is_some(),
        value_digest.is_some(),
    ];
    let any_completion = completion_present.iter().any(|present| *present);
    let complete_completion = completion_present.iter().all(|present| *present);

    match summary.state {
        RequestState::Completed => {
            let projection = access_projection.ok_or(ServiceError::Persistence)?;
            if summary.request_type != RequestType::Correction
                || !complete_completion
                || highest_transition_version.checked_add(1) != Some(summary.decision_version)
                || response_version != Some(projection.response_version)
                || value_digest != Some(projection.current_value_digest.as_str())
            {
                return Err(ServiceError::Persistence);
            }
        }
        _ if any_completion || highest_transition_version != summary.decision_version => {
            return Err(ServiceError::Persistence);
        }
        _ => {}
    }
    Ok(())
}

fn nullable_positive_integer(value: &Value) -> Result<Option<i64>, ServiceError> {
    if value.is_null() {
        Ok(None)
    } else {
        positive_integer(value).map(Some)
    }
}
