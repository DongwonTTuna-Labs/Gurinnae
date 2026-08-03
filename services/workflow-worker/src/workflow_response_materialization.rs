use gurine_auth::assertion::canonical::{canonical_json, sha256_hex};

const WORKFLOW_RESPONSE_SUBMITTED_V2_FIELDS: [&str; 8] = [
    "responseSubmissionId",
    "responseRequestId",
    "responseRequestVersion",
    "responseRequestBindingDigest",
    "submissionSha256",
    "receiptVersion",
    "receiptDigest",
    "submittedAt",
];

const RESPONSE_MATERIALIZATION_RECEIPT_V2_FIELDS: [&str; 19] = [
    "disposition",
    "source_event_id",
    "response_submission_id",
    "response_request_id",
    "editorial_response_id",
    "party_type",
    "party_entity_id",
    "response_version",
    "response_content_sha256",
    "publication_consent_sha256",
    "identity_status",
    "publication_form",
    "submission_receipt_version",
    "submission_receipt_digest",
    "owned_intake_receipt_digest",
    "audit_event_id",
    "emitted_event_id",
    "materialized_at",
    "result_digest",
];

#[derive(Clone, Debug, Eq, PartialEq)]
struct ResponseSubmissionIntakeMaterializeInput {
    source_event_id: Uuid,
    source_event_envelope_digest: String,
    response_submission_id: Uuid,
    response_request_id: Uuid,
    response_request_version: i64,
    response_request_binding_digest: String,
    submission_sha256: String,
    receipt_version: i64,
    receipt_digest: String,
    submitted_at: time::OffsetDateTime,
}

fn parse_response_submission_intake_materialize_input(
    source_event_id: Uuid,
    source_event_envelope_digest: &str,
    payload: &serde_json::Map<String, Value>,
) -> Result<ResponseSubmissionIntakeMaterializeInput, Failure> {
    if let Some(unexpected) = payload
        .keys()
        .find(|field| !WORKFLOW_RESPONSE_SUBMITTED_V2_FIELDS.contains(&field.as_str()))
    {
        return Err(invalid_response_submission_payload(
            unexpected,
            "unexpected field",
        ));
    }

    Ok(ResponseSubmissionIntakeMaterializeInput {
        source_event_id,
        source_event_envelope_digest: response_submission_digest(
            source_event_envelope_digest,
            "sourceEventEnvelopeDigest",
        )?,
        response_submission_id: response_submission_uuid(payload, "responseSubmissionId")?,
        response_request_id: response_submission_uuid(payload, "responseRequestId")?,
        response_request_version: response_submission_version(payload, "responseRequestVersion")?,
        response_request_binding_digest: response_submission_payload_digest(
            payload,
            "responseRequestBindingDigest",
        )?,
        submission_sha256: response_submission_payload_digest(payload, "submissionSha256")?,
        receipt_version: response_submission_version(payload, "receiptVersion")?,
        receipt_digest: response_submission_payload_digest(payload, "receiptDigest")?,
        submitted_at: response_submission_timestamp(payload, "submittedAt")?,
    })
}

fn response_submission_uuid(
    payload: &serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<Uuid, Failure> {
    payload
        .get(field)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| invalid_response_submission_payload(field, "expected UUID"))
}

fn response_submission_version(
    payload: &serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<i64, Failure> {
    payload
        .get(field)
        .and_then(Value::as_i64)
        .filter(|version| *version > 0)
        .ok_or_else(|| invalid_response_submission_payload(field, "expected positive integer"))
}

fn response_submission_payload_digest(
    payload: &serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<String, Failure> {
    let value = payload
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_response_submission_payload(field, "expected lowercase SHA-256"))?;
    response_submission_digest(value, field)
}

fn response_submission_digest(value: &str, field: &str) -> Result<String, Failure> {
    if is_sha256(value) {
        Ok(value.to_owned())
    } else {
        Err(invalid_response_submission_payload(
            field,
            "expected lowercase SHA-256",
        ))
    }
}

fn response_submission_timestamp(
    payload: &serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<time::OffsetDateTime, Failure> {
    let value = payload
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_response_submission_payload(field, "expected RFC 3339 date-time"))?;
    time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339)
        .map_err(|_| invalid_response_submission_payload(field, "expected RFC 3339 date-time"))
}

fn invalid_response_submission_payload(field: &str, reason: &str) -> Failure {
    Failure::Terminal(
        "INVALID_EVENT_PAYLOAD",
        format!("workflow.response_submitted.v2 {field}: {reason}"),
    )
}

async fn reconcile_response_submission_v2(
    pool: &PgPool,
    source_event_id: Uuid,
    aggregate_id: Uuid,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    let source_event_envelope_digest = response_source_event_digest(pool, source_event_id).await?;
    let input = parse_response_submission_intake_materialize_input(
        source_event_id,
        source_event_envelope_digest.trim(),
        payload,
    )?;
    if aggregate_id != input.response_submission_id {
        return Err(invalid_response_submission_payload(
            "responseSubmissionId",
            "aggregate binding mismatch",
        ));
    }
    let (idempotency_key, request_digest) = response_materialization_digests(&input)?;
    let receipt =
        call_response_materialization_owner(pool, &input, idempotency_key, request_digest).await?;
    validate_response_materialization_receipt(&receipt, &input)
}

async fn response_source_event_digest(
    pool: &PgPool,
    source_event_id: Uuid,
) -> Result<String, Failure> {
    sqlx::query_scalar!(
        "SELECT ops.r6d_outbox_envelope_digest_v1($1) AS \"digest?\"",
        source_event_id,
    )
    .fetch_one(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| {
        Failure::Terminal(
            "RESPONSE_SUBMISSION_EVENT_NOT_FOUND",
            source_event_id.to_string(),
        )
    })
}

fn response_materialization_digests(
    input: &ResponseSubmissionIntakeMaterializeInput,
) -> Result<(String, String), Failure> {
    let idempotency_key = sha256_hex(
        format!("response-submission-materializer:{}", input.source_event_id).as_bytes(),
    );
    let request = json!({
        "sourceEventId": input.source_event_id,
        "sourceEventEnvelopeDigest": input.source_event_envelope_digest,
        "responseSubmissionId": input.response_submission_id,
        "responseRequestId": input.response_request_id,
        "responseRequestVersion": input.response_request_version,
        "responseRequestBindingDigest": input.response_request_binding_digest,
        "submissionSha256": input.submission_sha256,
        "receiptVersion": input.receipt_version,
        "receiptDigest": input.receipt_digest,
        "submittedAt": input.submitted_at,
    });
    let request_digest = canonical_json(&request)
        .map(|canonical| sha256_hex(&canonical))
        .map_err(|_| {
            Failure::Terminal(
                "RESPONSE_SUBMISSION_REQUEST_DIGEST_INVALID",
                input.source_event_id.to_string(),
            )
        })?;
    Ok((idempotency_key, request_digest))
}

async fn call_response_materialization_owner(
    pool: &PgPool,
    input: &ResponseSubmissionIntakeMaterializeInput,
    idempotency_key: String,
    request_digest: String,
) -> Result<Value, Failure> {
    sqlx::query_scalar!(
        "SELECT to_jsonb(editorial.materialize_response_submission_v2( \
           ROW($1::uuid,$2::char(64),$3::uuid,$4::uuid,$5::bigint, \
             $6::char(64),$7::char(64),$8::bigint,$9::char(64),$10::timestamptz \
           )::editorial.response_submission_intake_materialize_v1, \
           NULL::uuid,$11::char(64),$12::char(64) \
         )) AS \"receipt!\"",
        input.source_event_id,
        input.source_event_envelope_digest.as_str(),
        input.response_submission_id,
        input.response_request_id,
        input.response_request_version,
        input.response_request_binding_digest.as_str(),
        input.submission_sha256.as_str(),
        input.receipt_version,
        input.receipt_digest.as_str(),
        input.submitted_at,
        idempotency_key,
        request_digest,
    )
    .fetch_one(pool)
    .await
    .map_err(database)
}

fn validate_response_materialization_receipt(
    receipt: &Value,
    input: &ResponseSubmissionIntakeMaterializeInput,
) -> Result<Value, Failure> {
    let object = receipt
        .as_object()
        .ok_or_else(|| invalid_response_materialization_receipt("receipt", "expected object"))?;
    if object.len() != RESPONSE_MATERIALIZATION_RECEIPT_V2_FIELDS.len()
        || object
            .keys()
            .any(|field| !RESPONSE_MATERIALIZATION_RECEIPT_V2_FIELDS.contains(&field.as_str()))
    {
        return Err(invalid_response_materialization_receipt(
            "receipt",
            "unexpected field set",
        ));
    }
    let disposition = receipt_text(object, "disposition")?;
    if !matches!(disposition, "APPLIED" | "NO_OP_ALREADY_MATERIALIZED") {
        return Err(invalid_response_materialization_receipt(
            "disposition",
            "unsupported value",
        ));
    }
    validate_response_materialization_bindings(object, input)?;
    validate_response_materialization_policy(object)?;
    let editorial_response_id = receipt_uuid(object, "editorial_response_id")?;
    let audit_event_id = receipt_uuid(object, "audit_event_id")?;
    let emitted_event_id = receipt_uuid(object, "emitted_event_id")?;
    Ok(json!({
        "disposition": disposition,
        "sourceEventId": input.source_event_id,
        "responseSubmissionId": input.response_submission_id,
        "responseRequestId": input.response_request_id,
        "editorialResponseId": editorial_response_id,
        "auditEventId": audit_event_id,
        "emittedEventId": emitted_event_id,
        "identityStatus": "UNVERIFIED",
        "publicationForm": "INTERNAL_ONLY",
        "resultDigest": receipt_text(object, "result_digest")?,
    }))
}

fn validate_response_materialization_bindings(
    object: &serde_json::Map<String, Value>,
    input: &ResponseSubmissionIntakeMaterializeInput,
) -> Result<(), Failure> {
    receipt_uuid_matches(object, "source_event_id", input.source_event_id)?;
    receipt_uuid_matches(
        object,
        "response_submission_id",
        input.response_submission_id,
    )?;
    receipt_uuid_matches(object, "response_request_id", input.response_request_id)?;
    receipt_uuid(object, "editorial_response_id")?;
    receipt_uuid(object, "audit_event_id")?;
    receipt_uuid(object, "emitted_event_id")?;
    receipt_positive_integer_matches(object, "response_version", 1)?;
    receipt_positive_integer_matches(object, "submission_receipt_version", input.receipt_version)?;
    receipt_digest_matches(object, "submission_receipt_digest", &input.receipt_digest)?;
    for field in [
        "response_content_sha256",
        "publication_consent_sha256",
        "owned_intake_receipt_digest",
        "result_digest",
    ] {
        receipt_digest(object, field)?;
    }
    Ok(())
}

fn validate_response_materialization_policy(
    object: &serde_json::Map<String, Value>,
) -> Result<(), Failure> {
    let party_type = receipt_text(object, "party_type")?;
    let party_entity_id = optional_receipt_uuid(object, "party_entity_id")?;
    if !matches!(
        (party_type, party_entity_id),
        ("AGENCY" | "SUPPLIER", Some(_)) | ("OTHER", None)
    ) {
        return Err(invalid_response_materialization_receipt(
            "party_entity_id",
            "party binding mismatch",
        ));
    }
    if receipt_text(object, "identity_status")? != "UNVERIFIED"
        || receipt_text(object, "publication_form")? != "INTERNAL_ONLY"
    {
        return Err(invalid_response_materialization_receipt(
            "identity_status",
            "new materialization must remain internal and unverified",
        ));
    }
    let materialized_at = receipt_text(object, "materialized_at")?;
    time::OffsetDateTime::parse(
        materialized_at,
        &time::format_description::well_known::Rfc3339,
    )
    .map_err(|_| {
        invalid_response_materialization_receipt("materialized_at", "invalid timestamp")
    })?;
    Ok(())
}

fn receipt_text<'a>(
    object: &'a serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<&'a str, Failure> {
    object
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_response_materialization_receipt(field, "expected string"))
}

fn receipt_uuid(
    object: &serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<Uuid, Failure> {
    receipt_text(object, field)?
        .parse()
        .map_err(|_| invalid_response_materialization_receipt(field, "expected UUID"))
}

fn optional_receipt_uuid(
    object: &serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<Option<Uuid>, Failure> {
    match object.get(field) {
        Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => value
            .parse()
            .map(Some)
            .map_err(|_| invalid_response_materialization_receipt(field, "expected UUID or null")),
        _ => Err(invalid_response_materialization_receipt(
            field,
            "expected UUID or null",
        )),
    }
}

fn receipt_uuid_matches(
    object: &serde_json::Map<String, Value>,
    field: &'static str,
    expected: Uuid,
) -> Result<(), Failure> {
    if receipt_uuid(object, field)? == expected {
        Ok(())
    } else {
        Err(invalid_response_materialization_receipt(
            field,
            "binding mismatch",
        ))
    }
}

fn receipt_positive_integer_matches(
    object: &serde_json::Map<String, Value>,
    field: &'static str,
    expected: i64,
) -> Result<(), Failure> {
    match object.get(field).and_then(Value::as_i64) {
        Some(value) if value > 0 && value == expected => Ok(()),
        _ => Err(invalid_response_materialization_receipt(
            field,
            "version mismatch",
        )),
    }
}

fn receipt_digest<'a>(
    object: &'a serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<&'a str, Failure> {
    let digest = receipt_text(object, field)?;
    if is_sha256(digest) {
        Ok(digest)
    } else {
        Err(invalid_response_materialization_receipt(
            field,
            "expected lowercase SHA-256",
        ))
    }
}

fn receipt_digest_matches(
    object: &serde_json::Map<String, Value>,
    field: &'static str,
    expected: &str,
) -> Result<(), Failure> {
    if receipt_digest(object, field)? == expected {
        Ok(())
    } else {
        Err(invalid_response_materialization_receipt(
            field,
            "binding mismatch",
        ))
    }
}

fn invalid_response_materialization_receipt(field: &str, reason: &str) -> Failure {
    Failure::Terminal(
        "INVALID_RESPONSE_MATERIALIZATION_RECEIPT",
        format!("editorial.materialize_response_submission_v2 {field}: {reason}"),
    )
}

#[cfg(test)]
#[path = "workflow_response_materialization_payload_tests.rs"]
mod response_submission_payload_tests;

#[cfg(test)]
#[path = "workflow_response_materialization_receipt_tests.rs"]
mod response_materialization_receipt_tests;
