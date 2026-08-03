use gurine_auth::assertion::canonical::sha256_hex;
use serde_json::Value;
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use crate::service::{RequestContext, ServiceError, common};

use super::{integer, projection, session_hash, text, uuid};

const OWNER_RECEIPT_FIELDS: [&str; 10] = [
    "submissionId",
    "receiptSessionId",
    "receiptVersion",
    "receiptDigest",
    "submissionOutboxEventId",
    "eventEnvelopeDigest",
    "outboxEventIds",
    "submittedAt",
    "receiptSessionExpiresAt",
    "replayed",
];

struct PreparedSubmission<'a> {
    expected_version: i64,
    submission_id: Uuid,
    submission_sha256: String,
    answers_encrypted: Vec<u8>,
    publication_consent: &'a Value,
    receipt_token: String,
    receipt_session_token: String,
    proposed_receipt_session_expires_at: OffsetDateTime,
    idempotency_key_sha256: &'a str,
    request_digest: &'a str,
}

struct SubmissionRequest<'a> {
    expected_version: i64,
    publication_consent: &'a Value,
    idempotency_key_sha256: &'a str,
    request_digest: &'a str,
}

struct SubmissionOwnerReceipt {
    submission_id: Uuid,
    receipt_version: i64,
    submitted_at: OffsetDateTime,
    receipt_session_expires_at: OffsetDateTime,
    replayed: bool,
}

pub(super) async fn submit(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let request = parse_submission_request(context, &value)?;
    let prepared = prepare_submission(context, &request).await?;
    let receipt = persist_submission(context, &prepared).await?;
    if !receipt.replayed && receipt.submission_id != prepared.submission_id {
        return Err(ServiceError::Persistence);
    }
    submission_response(context, prepared.receipt_session_token, receipt)
}

fn parse_submission_request<'a>(
    context: &'a RequestContext<'_>,
    value: &'a Value,
) -> Result<SubmissionRequest<'a>, ServiceError> {
    let expected_version = common::i64_field(value, "expectedVersion")?;
    if expected_version < 1 || !common::bool_field(value, "attestation")? {
        return Err(ServiceError::InvalidRequest);
    }
    let publication_consent = value
        .get("publicationConsent")
        .filter(|field| field.is_object())
        .ok_or(ServiceError::InvalidRequest)?;
    Ok(SubmissionRequest {
        expected_version,
        publication_consent,
        idempotency_key_sha256: require_sha256(context.idempotency_key_hash)?,
        request_digest: require_sha256(context.request_hash)?,
    })
}

async fn prepare_submission<'a>(
    context: &RequestContext<'_>,
    request: &SubmissionRequest<'a>,
) -> Result<PreparedSubmission<'a>, ServiceError> {
    let draft = projection::private_draft(context).await?;
    if integer(&draft, "version")? != request.expected_version {
        return Err(ServiceError::Conflict);
    }
    let draft_id = uuid(&draft, "id")?;
    let answers = common::decrypt_json(
        context,
        "intake.response_drafts",
        "answers_encrypted",
        draft_id,
        "response-answers",
        text(&draft, "answers_encrypted")?,
    )?;
    let submission_id = Uuid::new_v4();
    let answers_encrypted = common::encrypt_field(
        context,
        "intake.response_submissions",
        "answers_encrypted",
        submission_id,
        "response-answers",
        &serde_json::to_vec(&answers).map_err(|_| ServiceError::InvalidRequest)?,
    )?;
    let submission_sha256 = common::digest(&serde_json::json!({
        "answers": answers,
        "publicationConsent": request.publication_consent,
        "draftVersion": request.expected_version,
    }))?;
    let receipt_token = derive_owner_token(
        &context.state.token_hmac_key,
        "response-receipt",
        context.operation,
        request.idempotency_key_sha256,
        request.request_digest,
    )?;
    let receipt_session_token = derive_owner_token(
        &context.state.token_hmac_key,
        "response-receipt-session",
        context.operation,
        request.idempotency_key_sha256,
        request.request_digest,
    )?;
    Ok(PreparedSubmission {
        expected_version: request.expected_version,
        submission_id,
        submission_sha256,
        answers_encrypted,
        publication_consent: request.publication_consent,
        receipt_token,
        receipt_session_token,
        proposed_receipt_session_expires_at: OffsetDateTime::now_utc() + Duration::minutes(30),
        idempotency_key_sha256: request.idempotency_key_sha256,
        request_digest: request.request_digest,
    })
}

fn submission_response(
    context: &RequestContext<'_>,
    receipt_session_token: String,
    receipt: SubmissionOwnerReceipt,
) -> Result<Value, ServiceError> {
    Ok(serde_json::json!({
        "operationId": context.operation,
        "requestId": context.request_id,
        "status": "accepted",
        "aggregateId": receipt.submission_id,
        "aggregateVersion": receipt.receipt_version,
        "acceptedAt": common::timestamp(receipt.submitted_at)?,
        "links": [],
        "receiptSession": common::descriptor(
            receipt_session_token,
            "RESPONSE_RECEIPT",
            receipt.submission_id,
            receipt.receipt_session_expires_at,
            1,
        )?,
    }))
}

async fn persist_submission(
    context: &RequestContext<'_>,
    prepared: &PreparedSubmission<'_>,
) -> Result<SubmissionOwnerReceipt, ServiceError> {
    let value: Value = sqlx::query_scalar!(
        "SELECT intake.submit_response_session_v3( \
           $1::char(64),$2::text,$3::bigint,true,$4::char(64),$5::bytea, \
           $6::jsonb,$7::uuid,$8::char(64),$9::char(64),$10::timestamptz, \
           $11::char(64),$12::char(64) \
         ) AS \"value!\"",
        session_hash(context)?,
        context.issuer,
        prepared.expected_version,
        prepared.submission_sha256.as_str(),
        prepared.answers_encrypted.as_slice(),
        prepared.publication_consent,
        prepared.submission_id,
        common::token_hmac(&context.state.token_hmac_key, &prepared.receipt_token)?,
        sha256_hex(prepared.receipt_session_token.as_bytes()),
        prepared.proposed_receipt_session_expires_at,
        prepared.idempotency_key_sha256,
        prepared.request_digest,
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?;
    parse_owner_receipt(&value)
}

fn parse_owner_receipt(value: &Value) -> Result<SubmissionOwnerReceipt, ServiceError> {
    let object = value.as_object().ok_or(ServiceError::Persistence)?;
    if object.len() != OWNER_RECEIPT_FIELDS.len()
        || object
            .keys()
            .any(|field| !OWNER_RECEIPT_FIELDS.contains(&field.as_str()))
    {
        return Err(ServiceError::Persistence);
    }
    let submission_id = owner_uuid(object, "submissionId")?;
    owner_uuid(object, "receiptSessionId")?;
    let receipt_version = object
        .get("receiptVersion")
        .and_then(Value::as_i64)
        .filter(|version| *version > 0)
        .ok_or(ServiceError::Persistence)?;
    owner_digest(object, "receiptDigest")?;
    let submission_outbox_event_id = owner_uuid(object, "submissionOutboxEventId")?;
    owner_digest(object, "eventEnvelopeDigest")?;
    validate_outbox_ids(object, submission_outbox_event_id)?;
    let submitted_at = owner_timestamp(object, "submittedAt")?;
    let receipt_session_expires_at = owner_timestamp(object, "receiptSessionExpiresAt")?;
    if receipt_session_expires_at <= submitted_at {
        return Err(ServiceError::Persistence);
    }
    let replayed = object
        .get("replayed")
        .and_then(Value::as_bool)
        .ok_or(ServiceError::Persistence)?;
    Ok(SubmissionOwnerReceipt {
        submission_id,
        receipt_version,
        submitted_at,
        receipt_session_expires_at,
        replayed,
    })
}

fn validate_outbox_ids(
    object: &serde_json::Map<String, Value>,
    submission_outbox_event_id: Uuid,
) -> Result<(), ServiceError> {
    let outbox = object
        .get("outboxEventIds")
        .and_then(Value::as_array)
        .filter(|events| events.len() == 3)
        .ok_or(ServiceError::Persistence)?;
    let outbox_ids = outbox
        .iter()
        .map(|event| {
            event
                .as_str()
                .and_then(|id| Uuid::parse_str(id).ok())
                .ok_or(ServiceError::Persistence)
        })
        .collect::<Result<Vec<_>, _>>()?;
    if outbox_ids[0] == outbox_ids[1]
        || outbox_ids[0] == outbox_ids[2]
        || outbox_ids[1] == outbox_ids[2]
        || outbox_ids[2] != submission_outbox_event_id
    {
        return Err(ServiceError::Persistence);
    }
    Ok(())
}

fn derive_owner_token(
    key: &[u8],
    purpose: &str,
    operation: &str,
    idempotency_key_sha256: &str,
    owner_request_digest: &str,
) -> Result<String, ServiceError> {
    require_sha256(Some(idempotency_key_sha256))?;
    require_sha256(Some(owner_request_digest))?;
    if purpose.is_empty() || operation.is_empty() {
        return Err(ServiceError::Cryptography);
    }
    common::token_hmac(
        key,
        &format!(
            "gurine-response-owner-token-v1\0{purpose}\0{operation}\0{idempotency_key_sha256}\0{owner_request_digest}"
        ),
    )
}

fn require_sha256(value: Option<&str>) -> Result<&str, ServiceError> {
    value
        .filter(|digest| {
            digest.len() == 64
                && digest
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        })
        .ok_or(ServiceError::InvalidRequest)
}

fn owner_text<'a>(
    object: &'a serde_json::Map<String, Value>,
    field: &str,
) -> Result<&'a str, ServiceError> {
    object
        .get(field)
        .and_then(Value::as_str)
        .ok_or(ServiceError::Persistence)
}

fn owner_uuid(object: &serde_json::Map<String, Value>, field: &str) -> Result<Uuid, ServiceError> {
    Uuid::parse_str(owner_text(object, field)?).map_err(|_| ServiceError::Persistence)
}

fn owner_digest<'a>(
    object: &'a serde_json::Map<String, Value>,
    field: &str,
) -> Result<&'a str, ServiceError> {
    require_sha256(Some(owner_text(object, field)?)).map_err(|_| ServiceError::Persistence)
}

fn owner_timestamp(
    object: &serde_json::Map<String, Value>,
    field: &str,
) -> Result<OffsetDateTime, ServiceError> {
    OffsetDateTime::parse(owner_text(object, field)?, &Rfc3339)
        .map_err(|_| ServiceError::Persistence)
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use crate::service::ServiceError;

    use super::{derive_owner_token, parse_owner_receipt};

    const DIGEST_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const DIGEST_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn owner_receipt() -> Value {
        json!({
            "submissionId": "d47262d2-6807-4ed5-9ca1-b960e2222e0f",
            "receiptSessionId": "4952c25f-fca2-41d3-aab9-647a70f66d88",
            "receiptVersion": 1,
            "receiptDigest": DIGEST_A,
            "submissionOutboxEventId": "27f4e9ba-d9a4-4b2f-8969-d7b3f0189111",
            "eventEnvelopeDigest": DIGEST_B,
            "outboxEventIds": [
                "32fbb2da-168b-491d-b54e-46a0bd14426d",
                "769b6ac0-a4bd-4a15-9907-a0ca20ad160b",
                "27f4e9ba-d9a4-4b2f-8969-d7b3f0189111"
            ],
            "submittedAt": "2026-08-01T12:34:56Z",
            "receiptSessionExpiresAt": "2026-08-01T13:04:56Z",
            "replayed": false,
        })
    }

    #[test]
    fn owner_tokens_are_replay_stable_and_domain_separated() {
        let key = b"01234567890123456789012345678901";
        let receipt = derive_owner_token(
            key,
            "response-receipt",
            "submitResponse",
            DIGEST_A,
            DIGEST_B,
        );
        let replay = derive_owner_token(
            key,
            "response-receipt",
            "submitResponse",
            DIGEST_A,
            DIGEST_B,
        );
        let session = derive_owner_token(
            key,
            "response-receipt-session",
            "submitResponse",
            DIGEST_A,
            DIGEST_B,
        );
        assert_eq!(receipt.as_ref().ok(), replay.as_ref().ok());
        assert_ne!(receipt.as_ref().ok(), session.as_ref().ok());
    }

    #[test]
    fn owner_tokens_bind_both_request_digests() {
        let key = b"01234567890123456789012345678901";
        let base = derive_owner_token(
            key,
            "response-receipt",
            "submitResponse",
            DIGEST_A,
            DIGEST_B,
        );
        let changed_key = derive_owner_token(
            key,
            "response-receipt",
            "submitResponse",
            DIGEST_B,
            DIGEST_B,
        );
        let changed_request = derive_owner_token(
            key,
            "response-receipt",
            "submitResponse",
            DIGEST_A,
            DIGEST_A,
        );
        assert_ne!(base.as_ref().ok(), changed_key.as_ref().ok());
        assert_ne!(base.as_ref().ok(), changed_request.as_ref().ok());
    }

    #[test]
    fn owner_receipt_requires_the_closed_replay_shape() {
        let receipt = match parse_owner_receipt(&owner_receipt()) {
            Ok(receipt) => receipt,
            Err(error) => panic!("valid owner receipt rejected: {error}"),
        };
        assert_eq!(receipt.receipt_version, 1);
        assert!(!receipt.replayed);

        let mut expanded = owner_receipt();
        expanded["receiptToken"] = Value::String("forbidden".to_owned());
        assert!(matches!(
            parse_owner_receipt(&expanded),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn owner_receipt_rejects_expiry_or_outbox_binding_drift() {
        let mut expired = owner_receipt();
        let submitted_at = expired["submittedAt"].clone();
        expired["receiptSessionExpiresAt"] = submitted_at;
        assert!(matches!(
            parse_owner_receipt(&expired),
            Err(ServiceError::Persistence)
        ));

        let mut duplicate = owner_receipt();
        let first_event_id = duplicate["outboxEventIds"][0].clone();
        duplicate["outboxEventIds"][1] = first_event_id;
        assert!(matches!(
            parse_owner_receipt(&duplicate),
            Err(ServiceError::Persistence)
        ));
    }
}
