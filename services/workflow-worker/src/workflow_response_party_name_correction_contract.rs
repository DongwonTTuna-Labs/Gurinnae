const PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_LOAD_SQL: &str =
    "SELECT ops.load_privacy_response_party_name_correction_job_v1($1,$2,$3)";
const PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_APPLY_SQL: &str =
    "SELECT ops.execute_privacy_response_party_name_correction_job_v1($1,$2,$3,$4,$5)";
const INVALID_PARTY_NAME_CORRECTION_JOB: &str =
    "INVALID_PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_JOB";
const INVALID_PARTY_NAME_CORRECTION_LOAD: &str =
    "INVALID_PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_LOAD";
const INVALID_PARTY_NAME_CORRECTION_COMPLETION: &str =
    "INVALID_PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_COMPLETION";

const PARTY_NAME_CORRECTION_JOB_KEYS: [&str; 24] = [
    "schemaVersion",
    "privacyRequestId",
    "requestDecisionVersion",
    "correctionPlanId",
    "planVersion",
    "planDigest",
    "responseId",
    "expectedResponseVersion",
    "expectedCurrentValueDigest",
    "accessProjectionDigest",
    "privacyIdentityProofReceiptId",
    "privacyIdentityProofReceiptDigest",
    "responseSubmissionReceiptId",
    "responseSubmissionReceiptDigest",
    "responseOriginReceiptId",
    "responseOriginReceiptDigest",
    "approvalTransitionReceiptId",
    "approvalTransitionReceiptDigest",
    "requestedValueSha256",
    "requestedValueAadDigest",
    "requestedValueCiphertextDigest",
    "encryptionKeyId",
    "holdCoverageDigest",
    "queuedAt",
];

const PARTY_NAME_CORRECTION_LOAD_KEYS: [&str; 16] = [
    "schemaVersion",
    "jobId",
    "correctionPlanId",
    "privacyRequestId",
    "responseId",
    "expectedResponseVersion",
    "expectedCurrentValueDigest",
    "requestedValueCiphertextBase64",
    "requestedValueSha256",
    "requestedValueAadDigest",
    "requestedValueCiphertextDigest",
    "encryptionKeyId",
    "planDigest",
    "approvalTransitionReceiptId",
    "approvalTransitionReceiptDigest",
    "jobPayloadDigest",
];

const PARTY_NAME_CORRECTION_COMPLETION_KEYS: [&str; 14] = [
    "schemaVersion",
    "status",
    "jobId",
    "privacyRequestId",
    "correctionPlanId",
    "responseId",
    "responseVersion",
    "partyNameDigest",
    "completionReceiptId",
    "completionReceiptDigest",
    "auditEventId",
    "outboxEventIds",
    "completedAt",
    "replayed",
];

struct PartyNameCorrectionPayload<'a> {
    privacy_request_id: Uuid,
    correction_plan_id: Uuid,
    plan_digest: &'a str,
    response_id: Uuid,
    expected_response_version: i64,
    expected_current_value_digest: &'a str,
    approval_transition_receipt_id: Uuid,
    approval_transition_receipt_digest: &'a str,
    requested_value_sha256: &'a str,
    requested_value_aad_digest: &'a str,
    requested_value_ciphertext_digest: &'a str,
    encryption_key_id: &'a str,
    queued_at: time::OffsetDateTime,
}

struct LoadedPartyNameCorrection<'a> {
    job_id: Uuid,
    correction_plan_id: Uuid,
    privacy_request_id: Uuid,
    response_id: Uuid,
    expected_response_version: i64,
    expected_current_value_digest: &'a str,
    ciphertext_base64: &'a str,
    requested_value_sha256: &'a str,
    requested_value_aad_digest: &'a str,
    requested_value_ciphertext_digest: &'a str,
    encryption_key_id: &'a str,
    plan_digest: &'a str,
    approval_transition_receipt_id: Uuid,
    approval_transition_receipt_digest: &'a str,
    job_payload_digest: &'a str,
}

struct PartyNameCorrectionCompletion<'a> {
    job_id: Uuid,
    privacy_request_id: Uuid,
    correction_plan_id: Uuid,
    response_id: Uuid,
    response_version: i64,
    party_name_digest: &'a str,
    completed_at: time::OffsetDateTime,
}

fn parse_party_name_correction_payload(
    value: &Value,
) -> Result<PartyNameCorrectionPayload<'_>, Failure> {
    let object = retention_closed_object(
        value,
        &PARTY_NAME_CORRECTION_JOB_KEYS,
        INVALID_PARTY_NAME_CORRECTION_JOB,
    )?;
    validate_party_name_correction_payload_shape(object)?;
    party_name_correction_payload_from_object(object)
}

fn validate_party_name_correction_payload_shape(
    object: &serde_json::Map<String, Value>,
) -> Result<(), Failure> {
    retention_literal(
        object,
        "schemaVersion",
        "privacy-response-party-name-correction-job.v1",
        INVALID_PARTY_NAME_CORRECTION_JOB,
    )?;
    for field in [
        "requestDecisionVersion",
        "planVersion",
        "expectedResponseVersion",
    ] {
        retention_positive_integer(object, field, INVALID_PARTY_NAME_CORRECTION_JOB)?;
    }
    for field in [
        "privacyIdentityProofReceiptId",
        "responseSubmissionReceiptId",
        "responseOriginReceiptId",
    ] {
        retention_uuid(object, field, INVALID_PARTY_NAME_CORRECTION_JOB)?;
    }
    for field in [
        "accessProjectionDigest",
        "privacyIdentityProofReceiptDigest",
        "responseSubmissionReceiptDigest",
        "responseOriginReceiptDigest",
        "holdCoverageDigest",
    ] {
        retention_digest(object, field, INVALID_PARTY_NAME_CORRECTION_JOB)?;
    }
    Ok(())
}

fn party_name_correction_payload_from_object(
    object: &serde_json::Map<String, Value>,
) -> Result<PartyNameCorrectionPayload<'_>, Failure> {
    Ok(PartyNameCorrectionPayload {
        privacy_request_id: retention_uuid(
            object,
            "privacyRequestId",
            INVALID_PARTY_NAME_CORRECTION_JOB,
        )?,
        correction_plan_id: retention_uuid(
            object,
            "correctionPlanId",
            INVALID_PARTY_NAME_CORRECTION_JOB,
        )?,
        plan_digest: retention_digest(object, "planDigest", INVALID_PARTY_NAME_CORRECTION_JOB)?,
        response_id: retention_uuid(object, "responseId", INVALID_PARTY_NAME_CORRECTION_JOB)?,
        expected_response_version: retention_positive_integer(
            object,
            "expectedResponseVersion",
            INVALID_PARTY_NAME_CORRECTION_JOB,
        )?,
        expected_current_value_digest: retention_digest(
            object,
            "expectedCurrentValueDigest",
            INVALID_PARTY_NAME_CORRECTION_JOB,
        )?,
        approval_transition_receipt_id: retention_uuid(
            object,
            "approvalTransitionReceiptId",
            INVALID_PARTY_NAME_CORRECTION_JOB,
        )?,
        approval_transition_receipt_digest: retention_digest(
            object,
            "approvalTransitionReceiptDigest",
            INVALID_PARTY_NAME_CORRECTION_JOB,
        )?,
        requested_value_sha256: retention_digest(
            object,
            "requestedValueSha256",
            INVALID_PARTY_NAME_CORRECTION_JOB,
        )?,
        requested_value_aad_digest: retention_digest(
            object,
            "requestedValueAadDigest",
            INVALID_PARTY_NAME_CORRECTION_JOB,
        )?,
        requested_value_ciphertext_digest: retention_digest(
            object,
            "requestedValueCiphertextDigest",
            INVALID_PARTY_NAME_CORRECTION_JOB,
        )?,
        encryption_key_id: party_name_correction_key_id(
            object,
            "encryptionKeyId",
            INVALID_PARTY_NAME_CORRECTION_JOB,
        )?,
        queued_at: retention_datetime(object, "queuedAt", INVALID_PARTY_NAME_CORRECTION_JOB)?,
    })
}

fn parse_loaded_party_name_correction(
    value: &Value,
) -> Result<LoadedPartyNameCorrection<'_>, Failure> {
    let object = retention_closed_object(
        value,
        &PARTY_NAME_CORRECTION_LOAD_KEYS,
        INVALID_PARTY_NAME_CORRECTION_LOAD,
    )?;
    retention_literal(
        object,
        "schemaVersion",
        "privacy-response-party-name-correction-job-load.v1",
        INVALID_PARTY_NAME_CORRECTION_LOAD,
    )?;
    let ciphertext_base64 = parse_party_name_correction_ciphertext(object)?;
    loaded_party_name_correction_from_object(object, ciphertext_base64)
}

fn parse_party_name_correction_ciphertext(
    object: &serde_json::Map<String, Value>,
) -> Result<&str, Failure> {
    let field = "requestedValueCiphertextBase64";
    let ciphertext_base64 = retention_string(object, field, INVALID_PARTY_NAME_CORRECTION_LOAD)?;
    if ciphertext_base64.is_empty() || ciphertext_base64.len() > 131_072 {
        return Err(party_name_correction_contract_failure(
            INVALID_PARTY_NAME_CORRECTION_LOAD,
            field,
        ));
    }
    Ok(ciphertext_base64)
}

fn loaded_party_name_correction_from_object<'a>(
    object: &'a serde_json::Map<String, Value>,
    ciphertext_base64: &'a str,
) -> Result<LoadedPartyNameCorrection<'a>, Failure> {
    Ok(LoadedPartyNameCorrection {
        job_id: retention_uuid(object, "jobId", INVALID_PARTY_NAME_CORRECTION_LOAD)?,
        correction_plan_id: retention_uuid(
            object,
            "correctionPlanId",
            INVALID_PARTY_NAME_CORRECTION_LOAD,
        )?,
        privacy_request_id: retention_uuid(
            object,
            "privacyRequestId",
            INVALID_PARTY_NAME_CORRECTION_LOAD,
        )?,
        response_id: retention_uuid(object, "responseId", INVALID_PARTY_NAME_CORRECTION_LOAD)?,
        expected_response_version: retention_positive_integer(
            object,
            "expectedResponseVersion",
            INVALID_PARTY_NAME_CORRECTION_LOAD,
        )?,
        expected_current_value_digest: retention_digest(
            object,
            "expectedCurrentValueDigest",
            INVALID_PARTY_NAME_CORRECTION_LOAD,
        )?,
        ciphertext_base64,
        requested_value_sha256: retention_digest(
            object,
            "requestedValueSha256",
            INVALID_PARTY_NAME_CORRECTION_LOAD,
        )?,
        requested_value_aad_digest: retention_digest(
            object,
            "requestedValueAadDigest",
            INVALID_PARTY_NAME_CORRECTION_LOAD,
        )?,
        requested_value_ciphertext_digest: retention_digest(
            object,
            "requestedValueCiphertextDigest",
            INVALID_PARTY_NAME_CORRECTION_LOAD,
        )?,
        encryption_key_id: party_name_correction_key_id(
            object,
            "encryptionKeyId",
            INVALID_PARTY_NAME_CORRECTION_LOAD,
        )?,
        plan_digest: retention_digest(object, "planDigest", INVALID_PARTY_NAME_CORRECTION_LOAD)?,
        approval_transition_receipt_id: retention_uuid(
            object,
            "approvalTransitionReceiptId",
            INVALID_PARTY_NAME_CORRECTION_LOAD,
        )?,
        approval_transition_receipt_digest: retention_digest(
            object,
            "approvalTransitionReceiptDigest",
            INVALID_PARTY_NAME_CORRECTION_LOAD,
        )?,
        job_payload_digest: retention_digest(
            object,
            "jobPayloadDigest",
            INVALID_PARTY_NAME_CORRECTION_LOAD,
        )?,
    })
}

fn validate_loaded_party_name_correction(
    job: &ClaimedJob,
    payload: &PartyNameCorrectionPayload<'_>,
    job_payload_digest: &str,
    loaded: &LoadedPartyNameCorrection<'_>,
) -> Result<(), Failure> {
    for (matches, field) in [
        (loaded.job_id == job.id, "jobId"),
        (
            loaded.correction_plan_id == payload.correction_plan_id,
            "correctionPlanId",
        ),
        (
            loaded.privacy_request_id == payload.privacy_request_id,
            "privacyRequestId",
        ),
        (loaded.response_id == payload.response_id, "responseId"),
        (
            loaded.expected_response_version == payload.expected_response_version,
            "expectedResponseVersion",
        ),
        (
            loaded.expected_current_value_digest == payload.expected_current_value_digest,
            "expectedCurrentValueDigest",
        ),
        (loaded.plan_digest == payload.plan_digest, "planDigest"),
        (
            loaded.approval_transition_receipt_id == payload.approval_transition_receipt_id,
            "approvalTransitionReceiptId",
        ),
        (
            loaded.approval_transition_receipt_digest == payload.approval_transition_receipt_digest,
            "approvalTransitionReceiptDigest",
        ),
        (
            loaded.requested_value_sha256 == payload.requested_value_sha256,
            "requestedValueSha256",
        ),
        (
            loaded.requested_value_aad_digest == payload.requested_value_aad_digest,
            "requestedValueAadDigest",
        ),
        (
            loaded.requested_value_ciphertext_digest == payload.requested_value_ciphertext_digest,
            "requestedValueCiphertextDigest",
        ),
        (
            loaded.encryption_key_id == payload.encryption_key_id,
            "encryptionKeyId",
        ),
        (
            loaded.job_payload_digest == job_payload_digest,
            "jobPayloadDigest",
        ),
    ] {
        require_party_name_correction_binding(matches, field)?;
    }
    Ok(())
}

fn party_name_correction_key_id<'a>(
    object: &'a serde_json::Map<String, Value>,
    field: &str,
    code: &'static str,
) -> Result<&'a str, Failure> {
    let value = retention_string(object, field, code)?;
    if value.is_empty()
        || value.len() > 200
        || value.trim() != value
        || value.chars().any(char::is_control)
    {
        return Err(party_name_correction_contract_failure(code, field));
    }
    Ok(value)
}
