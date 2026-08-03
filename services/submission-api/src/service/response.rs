use base64::{Engine as _, engine::general_purpose::STANDARD};
use gurine_auth::assertion::canonical::sha256_hex;
use serde_json::Value;
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use super::{RequestContext, ServiceError, common};

mod projection;
mod submission;
mod verification;

pub async fn access_status(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value: Value = sqlx::query_scalar!(
        "SELECT intake.get_response_access_status_session_v2($1,$2) AS \"value?\"",
        session_hash(context)?,
        context.issuer
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
    let scope = uuid(&value, "scope_id")?;
    let kind = text(&value, "status")?;
    let requires_email = kind == "RESPONSE_PENDING";
    Ok(serde_json::json!({
        "id": scope,
        "status": if requires_email { "PENDING_VERIFICATION" } else { "ACTIVE" },
        "data": {
            "status": if requires_email { "PENDING_VERIFICATION" } else { "ACTIVE" },
            "requiresEmailProof": requires_email,
            "expiresAt": value.get("expires_at").cloned().unwrap_or(Value::Null),
            "effectiveDueAt": value.get("effective_due_at").cloned().unwrap_or(Value::Null),
            "windowBasis": value.get("window_basis").cloned().unwrap_or(Value::Null),
            "nextAction": if requires_email { "VERIFY_EMAIL_OTP" } else { "COMPLETE_RESPONSE" }
        },
        "links": []
    }))
}

pub async fn verify(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    verification::verify(context).await
}

pub async fn get_request(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = projection::private_request(context).await?;
    let updated_at = value
        .get("updated_at")
        .and_then(Value::as_str)
        .unwrap_or("1970-01-01T00:00:00Z");
    let publication_scope = value
        .get("requested_publication_scope")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({}));
    let publication_scope = publication_model(&publication_scope, updated_at);
    Ok(serde_json::json!({
        "requestId": uuid(&value,"id")?,
        "requestingOrganization": "구린네 편집팀",
        "casePublicTitle": text(&value,"case_title")?,
        "partyName": text(&value,"party_name")?,
        "questions": value.get("questions").cloned().unwrap_or_else(|| serde_json::json!([])),
        "dueAt": value.get("effective_due_at").cloned().unwrap_or(Value::Null),
        "publicationScope": publication_scope,
        "attachmentsPolicy": {
            "maxBytes": 52_428_800,
            "allowedMediaTypes": allowed_media_types(),
            "maxCount": 20,
            "scanRequired": true,
            "retentionDays": 90
        },
        "status": value.get("status").cloned().ok_or(ServiceError::Persistence)?,
        "contact": {
            "email": "editorial@gurine.invalid",
            "officeHours": "평일 09:00-18:00 Asia/Seoul",
            "expectedResponseDays": 3
        }
    }))
}

pub async fn download_request(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let bytes: Vec<u8> = sqlx::query_scalar!(
        "SELECT intake.download_response_request_session_v2($1,$2) AS \"value?\"",
        session_hash(context)?,
        context.issuer
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
    Ok(serde_json::json!({"binary": STANDARD.encode(bytes)}))
}

pub async fn get_draft(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let draft = projection::private_draft(context).await?;
    let request_id = projection::scope_id(context, &["RESPONSE_ACTIVE"]).await?;
    if draft.as_object().is_none_or(serde_json::Map::is_empty) {
        return Ok(serde_json::json!({
            "requestId": request_id,
            "version": 0,
            "answers": [],
            "attachments": projection::project_attachments(context,&projection::private_attachments(context).await?,&serde_json::json!({}))?,
            "publicationConsent": publication_model(&serde_json::json!({}),"1970-01-01T00:00:00Z"),
            "expiresAt": common::timestamp(OffsetDateTime::now_utc()+Duration::days(7))?
        }));
    }
    projection::project_draft(
        context,
        &draft,
        projection::private_attachments(context).await?,
    )
    .await
}

pub async fn save_draft(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let answers = value
        .get("answers")
        .filter(|field| field.is_array())
        .ok_or(ServiceError::InvalidRequest)?;
    let consent = value
        .get("publicationConsent")
        .filter(|field| field.is_object())
        .ok_or(ServiceError::InvalidRequest)?;
    let expected_version = common::i64_field(&value, "expectedVersion")?;
    let existing = projection::private_draft(context).await?;
    let draft_id = if expected_version == 0 {
        if existing
            .as_object()
            .is_some_and(|object| !object.is_empty())
        {
            return Err(ServiceError::Conflict);
        }
        common::uuid_from_hash(&session_hash(context)?)?
    } else {
        if integer(&existing, "version")? != expected_version {
            return Err(ServiceError::Conflict);
        }
        uuid(&existing, "id")?
    };
    let encrypted = common::encrypt_field(
        context,
        "intake.response_drafts",
        "answers_encrypted",
        draft_id,
        "response-answers",
        &serde_json::to_vec(answers).map_err(|_| ServiceError::InvalidRequest)?,
    )?;
    let expires_at = OffsetDateTime::now_utc() + Duration::days(7);
    let row = sqlx::query!(
        "SELECT draft_id AS \"draft_id?\", version AS \"version?\" FROM intake.save_response_draft_session_v2($1,$2,$3,$4,$5,$6)",
        session_hash(context)?,
        context.issuer,
        expected_version,
        encrypted,
        consent,
        expires_at
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?;
    let id = row.draft_id.ok_or(ServiceError::Persistence)?;
    let version = row.version.ok_or(ServiceError::Persistence)?;
    common::command_receipt(context.operation, context.request_id, id, Some(version))
}

pub async fn create_attachment(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let filename = common::string(&value, "filename")?;
    let media_type = allowed_media_type(common::string(&value, "mediaType")?)?;
    let size = common::i64_field(&value, "sizeBytes")?;
    if !(1..=52_428_800).contains(&size) {
        return Err(ServiceError::InvalidRequest);
    }
    let digest = hash(common::string(&value, "sha256")?)?;
    let id = Uuid::new_v4();
    let encrypted = common::encrypt_field(
        context,
        "intake.response_attachments",
        "original_filename_encrypted",
        id,
        "original-filename",
        filename.as_bytes(),
    )?;
    let object_key = format!("quarantine/responses/{id}/{digest}");
    let persisted: Uuid = sqlx::query_scalar!(
        "SELECT intake.create_response_attachment_session_v2($1,$2,$3,$4,$5,$6,$7) AS \"value?\"",
        session_hash(context)?,
        context.issuer,
        encrypted,
        media_type,
        size,
        digest,
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
        "SELECT intake.finalize_response_attachment_session_v2($1,$2,$3,$4,$5,$6) AS \"value?\"",
        session_hash(context)?,
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
        "SELECT intake.delete_response_attachment_session_v2($1,$2,$3) AS \"value?\"",
        session_hash(context)?,
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
    let request = get_request(context).await?;
    let draft = get_draft(context).await?;
    let summary = serde_json::json!({
        "requestId": request.get("requestId"),
        "casePublicTitle": request.get("casePublicTitle"),
        "partyName": request.get("partyName"),
        "status": request.get("status"),
        "dueAt": request.get("dueAt"),
        "questionCount": request.get("questions").and_then(Value::as_array).map_or(0,Vec::len)
    });
    let digest = common::digest(&serde_json::json!({
        "request":summary,
        "answers":draft.get("answers"),
        "attachments":draft.get("attachments"),
        "publicationConsent":draft.get("publicationConsent")
    }))?;
    Ok(serde_json::json!({
        "request": summary,
        "answers": draft.get("answers").cloned().unwrap_or_else(||serde_json::json!([])),
        "attachments": draft.get("attachments").cloned().unwrap_or_else(||serde_json::json!([])),
        "publicationConsent": draft.get("publicationConsent").cloned().unwrap_or_else(||publication_model(&serde_json::json!({}),"1970-01-01T00:00:00Z")),
        "warnings": [],
        "submissionDigest": digest
    }))
}

pub async fn request_extension(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let due_at = OffsetDateTime::parse(common::string(&value, "requestedDueAt")?, &Rfc3339)
        .map_err(|_| ServiceError::InvalidRequest)?;
    let reason = common::string(&value, "reason")?;
    if reason.chars().count() > 4_000 {
        return Err(ServiceError::InvalidRequest);
    }
    let id: Uuid = sqlx::query_scalar!(
        "SELECT intake.request_response_extension_session_v2($1,$2,$3,$4) AS \"value?\"",
        session_hash(context)?,
        context.issuer,
        due_at,
        reason
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
    common::command_receipt(context.operation, context.request_id, id, None)
}

pub async fn submit(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    submission::submit(context).await
}

pub async fn get_receipt(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value: Value = sqlx::query_scalar!(
        "SELECT intake.get_response_receipt_session_v2($1,$2) AS \"value?\"",
        session_hash(context)?,
        context.issuer
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
    let id = uuid(&value, "id")?;
    let request_id = uuid(&value, "response_request_id")?;
    let digest = text(&value, "submission_sha256")?;
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
            "requestId": request_id,
            "submissionDigest": digest,
            "submittedAt": submitted_at,
            "status": status,
            "retentionNotice": "The private submission is retained under the published retention policy."
        },
        "links": []
    }))
}

fn session_hash(context: &RequestContext<'_>) -> Result<String, ServiceError> {
    Ok(sha256_hex(common::session(context)?.as_bytes()))
}

fn publication_model(value: &Value, updated_at: &str) -> Value {
    let attachments = value
        .get("attachmentConsents")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter(|item| item.get("mayPublish").and_then(Value::as_bool) == Some(true))
                .filter_map(|item| item.get("attachmentId").cloned())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    serde_json::json!({
        "body": value.get("bodyConsent").and_then(Value::as_bool).unwrap_or(false),
        "attachments": attachments,
        "redactionAcknowledged": value.get("redactionAcknowledged").and_then(Value::as_bool).unwrap_or(false),
        "scopeExplanation": value.get("identityDisplay").and_then(Value::as_str).unwrap_or("ANONYMOUS"),
        "updatedAt": value.get("consentedAt").and_then(Value::as_str).unwrap_or(updated_at)
    })
}

fn allowed_media_types() -> Vec<&'static str> {
    vec![
        "application/pdf",
        "image/jpeg",
        "image/png",
        "text/plain",
        "text/csv",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ]
}

fn allowed_media_type(value: &str) -> Result<&str, ServiceError> {
    if allowed_media_types().contains(&value) {
        Ok(value)
    } else {
        Err(ServiceError::InvalidRequest)
    }
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
