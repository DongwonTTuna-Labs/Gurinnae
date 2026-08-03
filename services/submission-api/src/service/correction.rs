use gurine_auth::assertion::canonical::sha256_hex;
use gurine_persistence_postgres::outbox::{OutboxEvent, append};
use serde_json::Value;
use time::{Duration, OffsetDateTime};
use uuid::Uuid;

use super::{RequestContext, ServiceError, common};

pub async fn get_draft(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let draft = private_draft(context).await?;
    project_draft(&draft)
}

pub async fn save_draft(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let draft = private_draft(context).await?;
    let draft_id = uuid(&draft, "id")?;
    let expected_version = common::i64_field(&value, "expectedVersion")?;
    let requester_type = common::string(&value, "requesterType")?;
    let email = common::normalized_email(common::string(&value, "contactEmail")?)?;
    let summary = common::string(&value, "summary")?;
    let requested_changes = common::object_or_array(&value, "requestedChanges")?;
    if !requested_changes.is_array() || requested_changes.as_array().is_none_or(Vec::is_empty) {
        return Err(ServiceError::InvalidRequest);
    }
    let evidence = common::optional_string(&value, "evidenceDescription")?;
    let email_encrypted = common::encrypt_field(
        context,
        "intake.correction_requests",
        "contact_email_encrypted",
        draft_id,
        "email-address",
        email.as_bytes(),
    )?;
    let row = sqlx::query!(
        "SELECT draft_id AS \"draft_id?\", version AS \"version?\" FROM intake.save_correction_draft_session($1,$2,$3,$4,$5,$6,$7,$8,$9)",
        sha256_hex(common::session(context)?.as_bytes()),
        context.issuer,
        expected_version,
        requester_type,
        common::token_hmac(&context.state.token_hmac_key, &email)?,
        email_encrypted,
        summary,
        requested_changes,
        evidence
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?;
    let resource_id = row.draft_id.ok_or(ServiceError::Persistence)?;
    let version = row.version.ok_or(ServiceError::Persistence)?;
    common::mutation_receipt(context.request_id, resource_id, version)
}

pub async fn delete_draft(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let expected_version = common::i64_field(&value, "expectedVersion")?;
    let id: Uuid = sqlx::query_scalar!(
        "SELECT intake.delete_correction_draft_session($1,$2,$3) AS \"value?\"",
        sha256_hex(common::session(context)?.as_bytes()),
        context.issuer,
        expected_version
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
    common::mutation_receipt(context.request_id, id, expected_version + 1)
}

pub async fn create_attachment(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let filename = common::string(&value, "filename")?;
    let media_type = allowed_media_type(common::string(&value, "mediaType")?)?;
    let size = common::i64_field(&value, "sizeBytes")?;
    if !(1..=52_428_800).contains(&size) {
        return Err(ServiceError::InvalidRequest);
    }
    let sha256 = hash(common::string(&value, "sha256")?)?;
    let id = Uuid::new_v4();
    let filename_encrypted = common::encrypt_field(
        context,
        "intake.correction_attachments",
        "original_filename_encrypted",
        id,
        "original-filename",
        filename.as_bytes(),
    )?;
    let object_key = format!("quarantine/corrections/{id}/{sha256}");
    let persisted: Uuid = sqlx::query_scalar!(
        "SELECT intake.create_correction_draft_attachment($1,$2,$3,$4,$5,$6,$7) AS \"value?\"",
        sha256_hex(common::session(context)?.as_bytes()),
        context.issuer,
        filename_encrypted,
        media_type,
        size,
        sha256,
        &object_key
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
    let mut receipt =
        common::command_receipt(context.operation, context.request_id, persisted, None)?;
    receipt["links"] = serde_json::json!([{
        "rel":"upload",
        "href":format!("/internal/submission-uploads/{persisted}"),
        "label":"PUT attachment bytes"
    }]);
    Ok(receipt)
}

pub async fn finalize_attachment(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let id = common::attachment_id(context)?;
    let etag = common::string(&value, "objectEtag")?;
    let size = common::i64_field(&value, "uploadedSizeBytes")?;
    let digest = hash(common::string(&value, "uploadedSha256")?)?;
    let persisted: Uuid = sqlx::query_scalar!(
        "SELECT intake.finalize_correction_draft_attachment($1,$2,$3,$4,$5,$6) AS \"value?\"",
        sha256_hex(common::session(context)?.as_bytes()),
        context.issuer,
        id,
        etag,
        size,
        digest
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
    common::command_receipt(context.operation, context.request_id, persisted, None)
}

pub async fn delete_attachment(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let id = common::attachment_id(context)?;
    let persisted: Uuid = sqlx::query_scalar!(
        "SELECT intake.delete_correction_draft_attachment($1,$2,$3) AS \"value?\"",
        sha256_hex(common::session(context)?.as_bytes()),
        context.issuer,
        id
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
    common::command_receipt(context.operation, context.request_id, persisted, None)
}

pub async fn preview(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let draft = project_draft(&private_draft(context).await?)?;
    let attachments = project_attachments(context, &private_attachments(context).await?)?;
    let digest = common::digest(&serde_json::json!({
        "draft":draft,
        "attachments":attachments,
    }))?;
    Ok(serde_json::json!({
        "draft": draft,
        "attachments": attachments,
        "warnings": [],
        "submissionDigest": digest,
    }))
}

pub async fn submit(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let expected_version = common::i64_field(&value, "expectedVersion")?;
    let attestation = common::bool_field(&value, "attestation")?;
    let privacy = common::bool_field(&value, "privacyConsent")?;
    if !attestation || !privacy {
        return Err(ServiceError::InvalidRequest);
    }
    let draft = private_draft(context).await?;
    let draft_id = uuid(&draft, "id")?;
    if integer(&draft, "version")? != expected_version {
        return Err(ServiceError::Conflict);
    }
    let request_id = draft_id;
    let receipt_token = common::derived_token(
        &context.state.token_hmac_key,
        "correction-receipt",
        request_id,
    )?;
    let session_token = common::random_token()?;
    let expires_at = OffsetDateTime::now_utc() + Duration::minutes(30);
    let persisted = persist_submission(
        context,
        expected_version,
        attestation,
        privacy,
        &receipt_token,
        &session_token,
        expires_at,
    )
    .await?;
    let mut receipt =
        common::command_receipt(context.operation, context.request_id, persisted, None)?;
    receipt["receiptSession"] = common::descriptor(
        session_token,
        "CORRECTION_RECEIPT",
        persisted,
        expires_at,
        1,
    )?;
    Ok(receipt)
}

async fn persist_submission(
    context: &RequestContext<'_>,
    expected_version: i64,
    attestation: bool,
    privacy: bool,
    receipt_token: &str,
    session_token: &str,
    expires_at: OffsetDateTime,
) -> Result<Uuid, ServiceError> {
    let mut transaction = context
        .state
        .pool
        .begin()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    let row = sqlx::query!(
        "SELECT request_id AS \"request_id?\" FROM intake.submit_correction_draft_session($1,$2,$3,$4,$5,$6,$7,$8)",
        sha256_hex(common::session(context)?.as_bytes()),
        context.issuer,
        expected_version,
        attestation,
        privacy,
        common::token_hmac(&context.state.token_hmac_key, receipt_token)?,
        sha256_hex(session_token.as_bytes()),
        expires_at
    )
    .fetch_one(&mut *transaction)
    .await
    .map_err(common::database_error)?;
    let id = row.request_id.ok_or(ServiceError::Persistence)?;
    append_submission_events(context, &mut transaction, id).await?;
    transaction
        .commit()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    Ok(id)
}

async fn append_submission_events(
    context: &RequestContext<'_>,
    transaction: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    id: Uuid,
) -> Result<(), ServiceError> {
    let aggregate_id = id.to_string();
    let occurred_at = OffsetDateTime::now_utc();
    let occurred_text = common::timestamp(occurred_at)?;
    for event_type in [
        "correction.request_submitted.v1",
        "notification.correction_received.v1",
    ] {
        let payload = serde_json::json!({"actor_id":context.issuer,"occurred_at":occurred_text,"operation_id":context.operation,"request_id":context.request_id});
        append(
            transaction,
            &OutboxEvent {
                aggregate_type: "correctionRequest",
                aggregate_id: &aggregate_id,
                aggregate_version: 1,
                event_type,
                payload: &payload,
                occurred_at,
            },
        )
        .await
        .map_err(|_| ServiceError::Persistence)?;
    }
    Ok(())
}

pub async fn get_receipt(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let token_hash = sha256_hex(common::session(context)?.as_bytes());
    let value: Value = sqlx::query_scalar!(
        "SELECT intake.get_correction_receipt_session($1,$2) AS \"value?\"",
        &token_hash,
        context.issuer
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
    let id = uuid(&value, "id")?;
    let submitted_at = value
        .get("submitted_at")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    let status = value
        .get("status")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    Ok(serde_json::json!({
        "id": id,
        "status": status,
        "data": {
            "receiptToken": id,
            "requestId": id,
            "submittedAt": submitted_at,
            "status": status,
            "nextUpdateExpectation": "Status updates are sent through the verified contact channel."
        },
        "links": []
    }))
}

async fn private_draft(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    sqlx::query_scalar!(
        "SELECT intake.get_correction_draft_session($1,$2) AS \"value?\"",
        sha256_hex(common::session(context)?.as_bytes()),
        context.issuer
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)
}

async fn private_attachments(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let preview: Value = sqlx::query_scalar!(
        "SELECT intake.get_correction_draft_preview_session($1,$2) AS \"value?\"",
        sha256_hex(common::session(context)?.as_bytes()),
        context.issuer
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
    preview
        .get("attachments")
        .cloned()
        .ok_or(ServiceError::Persistence)
}

fn project_draft(value: &Value) -> Result<Value, ServiceError> {
    Ok(serde_json::json!({
        "draftToken": text(value,"id")?,
        "version": integer(value,"version")?,
        "requesterType": value.get("requester_type").cloned().unwrap_or(Value::Null),
        "contactEmail": Value::Null,
        "summary": value.get("summary").cloned().unwrap_or(Value::Null),
        "requestedChanges": value.get("requested_changes").cloned().unwrap_or_else(|| serde_json::json!([])),
        "evidenceDescription": value.get("evidence_description").cloned().unwrap_or(Value::Null),
        "caseSlug": value.get("case_slug").cloned().unwrap_or(Value::Null),
        "publicationRevision": value.get("publication_revision").cloned().unwrap_or(Value::Null),
        "expiresAt": value.get("expires_at").cloned().ok_or(ServiceError::Persistence)?,
        "createdAt": value.get("created_at").cloned().unwrap_or(Value::Null),
        "updatedAt": value.get("updated_at").cloned().unwrap_or(Value::Null),
    }))
}

fn project_attachments(
    context: &RequestContext<'_>,
    value: &Value,
) -> Result<Vec<Value>, ServiceError> {
    value
        .as_array()
        .ok_or(ServiceError::Persistence)?
        .iter()
        .map(|attachment| {
            let id = uuid(attachment, "id")?;
            let filename = common::decrypt_text(
                context,
                "intake.correction_attachments",
                "original_filename_encrypted",
                id,
                "original-filename",
                text(attachment, "original_filename_encrypted")?,
            )?;
            Ok(serde_json::json!({
                "id": id,
                "filename": filename,
                "mediaType": attachment.get("media_type").cloned().ok_or(ServiceError::Persistence)?,
                "sizeBytes": attachment.get("size_bytes").cloned().ok_or(ServiceError::Persistence)?,
                "sha256": attachment.get("sha256").cloned().ok_or(ServiceError::Persistence)?,
                "uploadStatus": attachment.get("upload_status").cloned().ok_or(ServiceError::Persistence)?,
                "scanStatus": attachment.get("scan_status").cloned().ok_or(ServiceError::Persistence)?,
                "publicationConsent": false,
            }))
        })
        .collect()
}

fn text<'a>(value: &'a Value, name: &str) -> Result<&'a str, ServiceError> {
    value
        .get(name)
        .and_then(Value::as_str)
        .ok_or(ServiceError::Persistence)
}

fn integer(value: &Value, name: &str) -> Result<i64, ServiceError> {
    value
        .get(name)
        .and_then(Value::as_i64)
        .ok_or(ServiceError::Persistence)
}

fn uuid(value: &Value, name: &str) -> Result<Uuid, ServiceError> {
    Uuid::parse_str(text(value, name)?).map_err(|_| ServiceError::Persistence)
}

fn hash(value: &str) -> Result<&str, ServiceError> {
    if value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(value)
    } else {
        Err(ServiceError::InvalidRequest)
    }
}

fn allowed_media_type(value: &str) -> Result<&str, ServiceError> {
    match value {
        "application/pdf"
        | "image/jpeg"
        | "image/png"
        | "text/plain"
        | "text/csv"
        | "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        | "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => Ok(value),
        _ => Err(ServiceError::InvalidRequest),
    }
}
