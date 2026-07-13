use base64::{Engine as _, engine::general_purpose::STANDARD};
use gurine_auth::assertion::canonical::sha256_hex;
use gurine_persistence_postgres::outbox::{OutboxEvent, append};
use serde_json::Value;
use sqlx::Row;
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use super::{RequestContext, ServiceError, common};

pub async fn access_status(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value: Value =
        sqlx::query_scalar("SELECT intake.get_response_access_status_session($1,$2)")
            .bind(session_hash(context)?)
            .bind(context.issuer)
            .fetch_one(&context.state.pool)
            .await
            .map_err(common::database_error)?;
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
            "nextAction": if requires_email { "VERIFY_EMAIL_OTP" } else { "COMPLETE_RESPONSE" }
        },
        "links": []
    }))
}

pub async fn verify(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let otp = common::string(&value, "emailOtp")?;
    if otp.len() < 4 || otp.len() > 12 || !otp.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(ServiceError::InvalidRequest);
    }
    let new_token = common::random_token()?;
    let expires_at = OffsetDateTime::now_utc() + Duration::hours(12);
    let status: Value =
        sqlx::query_scalar("SELECT intake.get_response_access_status_session($1,$2)")
            .bind(session_hash(context)?)
            .bind(context.issuer)
            .fetch_one(&context.state.pool)
            .await
            .map_err(common::database_error)?;
    let scoped_request = uuid(&status, "scope_id")?;
    let access_token_hash: String = sqlx::query_scalar(
        "SELECT token_hash::text FROM intake.response_access_tokens WHERE response_request_id=$1",
    )
    .bind(scoped_request)
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?;
    let expected = common::response_otp(&context.state.token_hmac_key, access_token_hash.trim())?;
    let verified = common::constant_time_eq(otp.as_bytes(), expected.as_bytes());
    let row = sqlx::query(
        "SELECT request_id,session_id,remaining_attempts FROM intake.verify_response_session($1,$2,$3,$4,$5)",
    )
    .bind(session_hash(context)?)
    .bind(context.issuer)
    .bind(verified)
    .bind(sha256_hex(new_token.as_bytes()))
    .bind(expires_at)
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?;
    let request_id: Uuid = row
        .try_get("request_id")
        .map_err(|_| ServiceError::Persistence)?;
    let remaining: i32 = row
        .try_get("remaining_attempts")
        .map_err(|_| ServiceError::Persistence)?;
    if verified {
        Ok(serde_json::json!({
            "requestId": request_id,
            "status": "VERIFIED",
            "remainingAttempts": remaining,
            "session": common::descriptor(new_token,"RESPONSE_ACTIVE",request_id,expires_at,1)?,
        }))
    } else {
        Ok(serde_json::json!({
            "requestId": request_id,
            "status": "VERIFICATION_FAILED",
            "remainingAttempts": remaining,
            "session": common::descriptor(
                common::session(context)?.to_owned(),
                "RESPONSE_PENDING",
                request_id,
                OffsetDateTime::now_utc()+Duration::minutes(15),
                1
            )?,
        }))
    }
}

pub async fn get_request(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = private_request(context).await?;
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
        "dueAt": value.get("due_at").cloned().ok_or(ServiceError::Persistence)?,
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
    let request = get_request(context).await?;
    let bytes = serde_json::to_vec_pretty(&request).map_err(|_| ServiceError::Persistence)?;
    Ok(serde_json::json!({"binary": STANDARD.encode(bytes)}))
}

pub async fn get_draft(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let draft = private_draft(context).await?;
    let request_id = scope_id(context, &["RESPONSE_ACTIVE"]).await?;
    if draft.as_object().is_none_or(serde_json::Map::is_empty) {
        return Ok(serde_json::json!({
            "requestId": request_id,
            "version": 0,
            "answers": [],
            "attachments": project_attachments(context,&private_attachments(context).await?,&serde_json::json!({}))?,
            "publicationConsent": publication_model(&serde_json::json!({}),"1970-01-01T00:00:00Z"),
            "expiresAt": common::timestamp(OffsetDateTime::now_utc()+Duration::days(7))?
        }));
    }
    project_draft(context, &draft, private_attachments(context).await?).await
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
    let existing = private_draft(context).await?;
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
    let row = sqlx::query(
        "SELECT draft_id,version FROM intake.save_response_draft_session($1,$2,$3,$4,$5,$6)",
    )
    .bind(session_hash(context)?)
    .bind(context.issuer)
    .bind(expected_version)
    .bind(encrypted)
    .bind(consent)
    .bind(expires_at)
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?;
    let id: Uuid = row
        .try_get("draft_id")
        .map_err(|_| ServiceError::Persistence)?;
    let version: i64 = row
        .try_get("version")
        .map_err(|_| ServiceError::Persistence)?;
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
    let persisted: Uuid = sqlx::query_scalar(
        "SELECT intake.create_response_attachment_session($1,$2,$3,$4,$5,$6,$7)",
    )
    .bind(session_hash(context)?)
    .bind(context.issuer)
    .bind(encrypted)
    .bind(media_type)
    .bind(size)
    .bind(digest)
    .bind(&object_key)
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?;
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
    let _etag = common::string(&value, "objectEtag")?;
    let size = common::i64_field(&value, "uploadedSizeBytes")?;
    let digest = hash(common::string(&value, "uploadedSha256")?)?;
    let persisted: Uuid =
        sqlx::query_scalar("SELECT intake.finalize_response_attachment_session($1,$2,$3,$4,$5)")
            .bind(session_hash(context)?)
            .bind(context.issuer)
            .bind(id)
            .bind(size)
            .bind(digest)
            .fetch_one(&context.state.pool)
            .await
            .map_err(common::database_error)?;
    common::command_receipt(context.operation, context.request_id, persisted, None)
}

pub async fn delete_attachment(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let id = common::attachment_id(context)?;
    let persisted: Uuid =
        sqlx::query_scalar("SELECT intake.delete_response_attachment_session($1,$2,$3)")
            .bind(session_hash(context)?)
            .bind(context.issuer)
            .bind(id)
            .fetch_one(&context.state.pool)
            .await
            .map_err(common::database_error)?;
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
    let id: Uuid =
        sqlx::query_scalar("SELECT intake.request_response_extension_session($1,$2,$3,$4)")
            .bind(session_hash(context)?)
            .bind(context.issuer)
            .bind(due_at)
            .bind(reason)
            .fetch_one(&context.state.pool)
            .await
            .map_err(common::database_error)?;
    common::command_receipt(context.operation, context.request_id, id, None)
}

pub async fn submit(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let version = common::i64_field(&value, "expectedVersion")?;
    if !common::bool_field(&value, "attestation")? {
        return Err(ServiceError::InvalidRequest);
    }
    let consent = value
        .get("publicationConsent")
        .filter(|field| field.is_object())
        .ok_or(ServiceError::InvalidRequest)?;
    let draft = private_draft(context).await?;
    if integer(&draft, "version")? != version {
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
    let submission_id = draft_id;
    let encrypted = common::encrypt_field(
        context,
        "intake.response_submissions",
        "answers_encrypted",
        submission_id,
        "response-answers",
        &serde_json::to_vec(&answers).map_err(|_| ServiceError::InvalidRequest)?,
    )?;
    let digest = common::digest(&serde_json::json!({
        "answers":answers,
        "publicationConsent":consent,
        "draftVersion":version
    }))?;
    let receipt_token = common::derived_token(
        &context.state.token_hmac_key,
        "response-receipt",
        submission_id,
    )?;
    let receipt_session = common::random_token()?;
    let expires_at = OffsetDateTime::now_utc() + Duration::minutes(30);
    let mut transaction = context
        .state
        .pool
        .begin()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    let row = sqlx::query(
        "SELECT submission_id,receipt_session_id FROM intake.submit_response_session($1,$2,$3,$4,$5,$6,$7,$8,$9)",
    )
    .bind(session_hash(context)?)
    .bind(context.issuer)
    .bind(version)
    .bind(&digest)
    .bind(encrypted)
    .bind(consent)
    .bind(common::token_hmac(&context.state.token_hmac_key, &receipt_token)?)
    .bind(sha256_hex(receipt_session.as_bytes()))
    .bind(expires_at)
    .fetch_one(&mut *transaction)
    .await
    .map_err(common::database_error)?;
    let id: Uuid = row
        .try_get("submission_id")
        .map_err(|_| ServiceError::Persistence)?;
    let aggregate_id = id.to_string();
    let occurred_at = OffsetDateTime::now_utc();
    let occurred_text = common::timestamp(occurred_at)?;
    let event_payload = serde_json::json!({
        "actor_id":context.issuer,
        "occurred_at":occurred_text,
        "operation_id":context.operation,
        "requestToken":aggregate_id.clone(),
        "request_id":context.request_id
    });
    for event_type in [
        "response.submitted.v1",
        "notification.response_submitted.v1",
    ] {
        append(
            &mut transaction,
            &OutboxEvent {
                aggregate_type: "responseSubmission",
                aggregate_id: &aggregate_id,
                aggregate_version: 1,
                event_type,
                payload: &event_payload,
                occurred_at,
            },
        )
        .await
        .map_err(|_| ServiceError::Persistence)?;
    }
    transaction
        .commit()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    let mut receipt = common::command_receipt(context.operation, context.request_id, id, None)?;
    receipt["receiptSession"] =
        common::descriptor(receipt_session, "RESPONSE_RECEIPT", id, expires_at, 1)?;
    Ok(receipt)
}

pub async fn get_receipt(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value: Value = sqlx::query_scalar("SELECT intake.get_response_receipt_session($1,$2)")
        .bind(session_hash(context)?)
        .bind(context.issuer)
        .fetch_one(&context.state.pool)
        .await
        .map_err(common::database_error)?;
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

async fn private_request(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    sqlx::query_scalar("SELECT intake.get_response_request_session($1,$2)")
        .bind(session_hash(context)?)
        .bind(context.issuer)
        .fetch_one(&context.state.pool)
        .await
        .map_err(common::database_error)
}

async fn private_draft(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    sqlx::query_scalar("SELECT intake.get_response_draft_session($1,$2)")
        .bind(session_hash(context)?)
        .bind(context.issuer)
        .fetch_one(&context.state.pool)
        .await
        .map_err(common::database_error)
}

async fn private_attachments(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let preview: Value = sqlx::query_scalar("SELECT intake.get_response_preview_session($1,$2)")
        .bind(session_hash(context)?)
        .bind(context.issuer)
        .fetch_one(&context.state.pool)
        .await
        .map_err(common::database_error)?;
    preview
        .get("attachments")
        .cloned()
        .ok_or(ServiceError::Persistence)
}

async fn project_draft(
    context: &RequestContext<'_>,
    draft: &Value,
    attachments: Value,
) -> Result<Value, ServiceError> {
    let draft_id = uuid(draft, "id")?;
    let answers = common::decrypt_json(
        context,
        "intake.response_drafts",
        "answers_encrypted",
        draft_id,
        "response-answers",
        text(draft, "answers_encrypted")?,
    )?;
    let consent = draft
        .get("publication_consent")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({}));
    let updated_at = draft
        .get("saved_at")
        .and_then(Value::as_str)
        .unwrap_or("1970-01-01T00:00:00Z");
    Ok(serde_json::json!({
        "requestId": uuid(draft,"response_request_id")?,
        "version": integer(draft,"version")?,
        "answers": answers,
        "attachments": project_attachments(context,&attachments,&consent)?,
        "publicationConsent": publication_model(&consent,updated_at),
        "savedAt": draft.get("saved_at").cloned().unwrap_or(Value::Null),
        "expiresAt": draft.get("expires_at").cloned().ok_or(ServiceError::Persistence)?
    }))
}

fn project_attachments(
    context: &RequestContext<'_>,
    value: &Value,
    consent: &Value,
) -> Result<Vec<Value>, ServiceError> {
    value
        .as_array()
        .ok_or(ServiceError::Persistence)?
        .iter()
        .map(|attachment| {
            let id = uuid(attachment, "id")?;
            let filename = common::decrypt_text(
                context,
                "intake.response_attachments",
                "original_filename_encrypted",
                id,
                "original-filename",
                text(attachment, "filename_encrypted")?,
            )?;
            let may_publish = consent
                .get("attachmentConsents")
                .and_then(Value::as_array)
                .and_then(|items| {
                    items.iter().find(|item| {
                        item.get("attachmentId").and_then(Value::as_str)
                            == Some(id.to_string().as_str())
                    })
                })
                .and_then(|item| item.get("mayPublish"))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            Ok(serde_json::json!({
                "id": id,
                "filename": filename,
                "mediaType": attachment.get("media_type").cloned().ok_or(ServiceError::Persistence)?,
                "sizeBytes": attachment.get("size_bytes").cloned().ok_or(ServiceError::Persistence)?,
                "sha256": attachment.get("sha256").cloned().ok_or(ServiceError::Persistence)?,
                "uploadStatus": attachment.get("upload_status").cloned().ok_or(ServiceError::Persistence)?,
                "scanStatus": attachment.get("scan_status").cloned().ok_or(ServiceError::Persistence)?,
                "publicationConsent": may_publish,
            }))
        })
        .collect()
}

async fn scope_id(context: &RequestContext<'_>, kinds: &[&str]) -> Result<Uuid, ServiceError> {
    sqlx::query_scalar("SELECT scope_id FROM intake.resolve_submission_session($1,$2,$3)")
        .bind(session_hash(context)?)
        .bind(context.issuer)
        .bind(
            kinds
                .iter()
                .map(|value| (*value).to_owned())
                .collect::<Vec<_>>(),
        )
        .fetch_one(&context.state.pool)
        .await
        .map_err(common::database_error)
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
