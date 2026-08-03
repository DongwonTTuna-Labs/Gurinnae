use base64::Engine as _;
use zeroize::Zeroize;

struct SensitivePlaintext(Vec<u8>);

impl SensitivePlaintext {
    fn bytes(&self) -> &[u8] {
        &self.0
    }

    fn text(&self) -> Result<&str, Failure> {
        std::str::from_utf8(&self.0)
            .map_err(|_| party_name_correction_decryption_failure("requestedValueUtf8"))
    }
}

impl Drop for SensitivePlaintext {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

async fn execute_privacy_response_party_name_correction(
    pool: &PgPool,
    field_keys: &EnvelopeKeyRing,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    validate_claimed_party_name_correction_job(job)?;
    let payload = parse_party_name_correction_payload(&job.payload)?;
    let job_payload_digest = retention_json_digest(
        &job.payload,
        INVALID_PARTY_NAME_CORRECTION_JOB,
        "canonicalPayload",
    )?;
    let load_value = load_party_name_correction(pool, job).await?;
    let loaded = parse_loaded_party_name_correction(&load_value)?;
    validate_loaded_party_name_correction(job, &payload, &job_payload_digest, &loaded)?;
    let plaintext = decrypt_requested_party_name(field_keys, &loaded)?;
    let result =
        apply_party_name_correction(pool, job, plaintext.text()?, loaded.requested_value_sha256)
            .await?;
    validate_party_name_correction_completion(job, &payload, &result)?;
    Ok(result)
}

fn validate_claimed_party_name_correction_job(job: &ClaimedJob) -> Result<(), Failure> {
    if job.job_type != "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION" {
        return Err(party_name_correction_contract_failure(
            INVALID_PARTY_NAME_CORRECTION_JOB,
            "jobType",
        ));
    }
    if job.queue != "workflow-worker" {
        return Err(party_name_correction_contract_failure(
            INVALID_PARTY_NAME_CORRECTION_JOB,
            "queue",
        ));
    }
    if job.id.is_nil() || job.fence.lease_token.is_nil() || job.fence.fencing_token < 1 {
        return Err(party_name_correction_contract_failure(
            INVALID_PARTY_NAME_CORRECTION_JOB,
            "claimFence",
        ));
    }
    Ok(())
}

async fn load_party_name_correction(pool: &PgPool, job: &ClaimedJob) -> Result<Value, Failure> {
    sqlx::query_scalar::<_, Value>(PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_LOAD_SQL)
        .bind(job.id)
        .bind(job.fence.lease_token)
        .bind(job.fence.fencing_token)
        .fetch_one(pool)
        .await
        .map_err(party_name_correction_owner_database_failure)
}

async fn apply_party_name_correction(
    pool: &PgPool,
    job: &ClaimedJob,
    plaintext: &str,
    plaintext_sha256: &str,
) -> Result<Value, Failure> {
    sqlx::query_scalar::<_, Value>(PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_APPLY_SQL)
        .bind(job.id)
        .bind(job.fence.lease_token)
        .bind(job.fence.fencing_token)
        .bind(plaintext)
        .bind(plaintext_sha256)
        .fetch_one(pool)
        .await
        .map_err(party_name_correction_owner_database_failure)
}

fn decrypt_requested_party_name(
    field_keys: &EnvelopeKeyRing,
    loaded: &LoadedPartyNameCorrection<'_>,
) -> Result<SensitivePlaintext, Failure> {
    let ciphertext = base64::engine::general_purpose::STANDARD
        .decode(loaded.ciphertext_base64)
        .map_err(|_| party_name_correction_decryption_failure("ciphertextBase64"))?;
    if base64::engine::general_purpose::STANDARD.encode(&ciphertext) != loaded.ciphertext_base64
        || sha256(&ciphertext) != loaded.requested_value_ciphertext_digest
    {
        return Err(party_name_correction_decryption_failure("ciphertextDigest"));
    }
    let token = std::str::from_utf8(&ciphertext)
        .map_err(|_| party_name_correction_decryption_failure("ciphertextEnvelope"))?;
    let token_key_id = party_name_correction_envelope_key_id(token)
        .ok_or_else(|| party_name_correction_decryption_failure("ciphertextEnvelope"))?;
    if token_key_id != loaded.encryption_key_id {
        return Err(party_name_correction_decryption_failure("encryptionKeyId"));
    }
    let plan_id = loaded.correction_plan_id.to_string();
    let aad_parts = [
        "ops.privacy_correction_plans_v1",
        "requested_value_ciphertext",
        plan_id.as_str(),
        "privacy-correction-requested-value",
        "1",
    ];
    if sha256(aad_parts.join("\0").as_bytes()) != loaded.requested_value_aad_digest {
        return Err(party_name_correction_decryption_failure("aadDigest"));
    }
    let plaintext = gurine_auth::envelope::decrypt("gurine-fe-v1", field_keys, &aad_parts, token)
        .map(SensitivePlaintext)
        .map_err(|_| party_name_correction_decryption_failure("authenticatedEnvelope"))?;
    if sha256(plaintext.bytes()) != loaded.requested_value_sha256 {
        return Err(party_name_correction_decryption_failure("plaintextDigest"));
    }
    plaintext.text()?;
    Ok(plaintext)
}

fn parse_party_name_correction_completion(
    value: &Value,
) -> Result<PartyNameCorrectionCompletion<'_>, Failure> {
    let object = retention_closed_object(
        value,
        &PARTY_NAME_CORRECTION_COMPLETION_KEYS,
        INVALID_PARTY_NAME_CORRECTION_COMPLETION,
    )?;
    retention_literal(
        object,
        "schemaVersion",
        "privacy-response-party-name-correction-completion.v1",
        INVALID_PARTY_NAME_CORRECTION_COMPLETION,
    )?;
    retention_literal(
        object,
        "status",
        "COMPLETED",
        INVALID_PARTY_NAME_CORRECTION_COMPLETION,
    )?;
    for field in ["completionReceiptId", "auditEventId"] {
        retention_uuid(object, field, INVALID_PARTY_NAME_CORRECTION_COMPLETION)?;
    }
    retention_digest(
        object,
        "completionReceiptDigest",
        INVALID_PARTY_NAME_CORRECTION_COMPLETION,
    )?;
    party_name_correction_outbox_event(object)?;
    retention_boolean(object, "replayed", INVALID_PARTY_NAME_CORRECTION_COMPLETION)?;
    Ok(PartyNameCorrectionCompletion {
        job_id: retention_uuid(object, "jobId", INVALID_PARTY_NAME_CORRECTION_COMPLETION)?,
        privacy_request_id: retention_uuid(
            object,
            "privacyRequestId",
            INVALID_PARTY_NAME_CORRECTION_COMPLETION,
        )?,
        correction_plan_id: retention_uuid(
            object,
            "correctionPlanId",
            INVALID_PARTY_NAME_CORRECTION_COMPLETION,
        )?,
        response_id: retention_uuid(
            object,
            "responseId",
            INVALID_PARTY_NAME_CORRECTION_COMPLETION,
        )?,
        response_version: retention_positive_integer(
            object,
            "responseVersion",
            INVALID_PARTY_NAME_CORRECTION_COMPLETION,
        )?,
        party_name_digest: retention_digest(
            object,
            "partyNameDigest",
            INVALID_PARTY_NAME_CORRECTION_COMPLETION,
        )?,
        completed_at: retention_datetime(
            object,
            "completedAt",
            INVALID_PARTY_NAME_CORRECTION_COMPLETION,
        )?,
    })
}

fn validate_party_name_correction_completion(
    job: &ClaimedJob,
    payload: &PartyNameCorrectionPayload<'_>,
    value: &Value,
) -> Result<(), Failure> {
    let completion = parse_party_name_correction_completion(value)?;
    let expected_version = payload
        .expected_response_version
        .checked_add(1)
        .ok_or_else(|| {
            party_name_correction_contract_failure(
                INVALID_PARTY_NAME_CORRECTION_COMPLETION,
                "responseVersion",
            )
        })?;
    for (matches, field) in [
        (completion.job_id == job.id, "jobId"),
        (
            completion.privacy_request_id == payload.privacy_request_id,
            "privacyRequestId",
        ),
        (
            completion.correction_plan_id == payload.correction_plan_id,
            "correctionPlanId",
        ),
        (completion.response_id == payload.response_id, "responseId"),
        (
            completion.response_version == expected_version,
            "responseVersion",
        ),
        (
            completion.party_name_digest == payload.requested_value_sha256,
            "partyNameDigest",
        ),
        (completion.completed_at >= payload.queued_at, "completedAt"),
    ] {
        require_party_name_correction_binding(matches, field)?;
    }
    Ok(())
}

fn party_name_correction_outbox_event(
    object: &serde_json::Map<String, Value>,
) -> Result<Uuid, Failure> {
    object
        .get("outboxEventIds")
        .and_then(Value::as_array)
        .filter(|values| values.len() == 1)
        .and_then(|values| values.first())
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or_else(|| {
            party_name_correction_contract_failure(
                INVALID_PARTY_NAME_CORRECTION_COMPLETION,
                "outboxEventIds",
            )
        })
}

fn party_name_correction_envelope_key_id(token: &str) -> Option<&str> {
    let mut segments = token.split('.');
    let prefix = segments.next()?;
    let key_id = segments.next()?;
    segments.next()?;
    segments.next()?;
    (prefix == "gurine-fe-v1" && !key_id.is_empty() && segments.next().is_none()).then_some(key_id)
}

fn require_party_name_correction_binding(matches: bool, field: &str) -> Result<(), Failure> {
    if !matches {
        return Err(Failure::Terminal(
            "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_BINDING_MISMATCH",
            field.to_owned(),
        ));
    }
    Ok(())
}

fn party_name_correction_contract_failure(code: &'static str, field: &str) -> Failure {
    Failure::Terminal(code, field.to_owned())
}

fn party_name_correction_decryption_failure(field: &str) -> Failure {
    Failure::Terminal(
        "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DECRYPTION_FAILED",
        field.to_owned(),
    )
}

fn party_name_correction_owner_database_failure(error: sqlx::Error) -> Failure {
    let sqlstate = match &error {
        sqlx::Error::Database(database) => database.code().map(|value| value.into_owned()),
        _ => None,
    };
    party_name_correction_owner_sqlstate_failure(sqlstate.as_deref())
}

fn party_name_correction_owner_sqlstate_failure(sqlstate: Option<&str>) -> Failure {
    match sqlstate {
        Some("22023") => Failure::Terminal(
            "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_OWNER_REJECTED",
            "redacted:sqlstate=22023".to_owned(),
        ),
        Some("0A000") => Failure::Terminal(
            "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_UNSUPPORTED",
            "redacted:sqlstate=0A000".to_owned(),
        ),
        Some("40001") => Failure::Retryable(
            "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_CONFLICT",
            "redacted:sqlstate=40001".to_owned(),
        ),
        Some("55000") => Failure::Retryable(
            "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_NOT_READY",
            "redacted:sqlstate=55000".to_owned(),
        ),
        Some("PVT09") => Failure::Retryable(
            "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_BLOCKED",
            "redacted:sqlstate=PVT09".to_owned(),
        ),
        _ => Failure::Retryable(
            "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_OWNER_UNAVAILABLE",
            "redacted:database_error".to_owned(),
        ),
    }
}

#[cfg(test)]
include!("workflow_response_party_name_correction_job_tests.rs");
