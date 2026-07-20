use base64::{Engine as _, engine::general_purpose::STANDARD};
use gurine_auth::assertion::canonical::sha256_hex;
use gurine_persistence_postgres::outbox::{OutboxEvent, append};
use serde_json::Value;
use sqlx::Row;
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use super::{RequestContext, ServiceError, common};

mod projection;

pub async fn access_status(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value: Value =
        sqlx::query_scalar("SELECT intake.get_response_access_status_session_v2($1,$2)")
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
            "effectiveDueAt": value.get("effective_due_at").cloned().unwrap_or(Value::Null),
            "windowBasis": value.get("window_basis").cloned().unwrap_or(Value::Null),
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
        sqlx::query_scalar("SELECT intake.get_response_access_status_session_v2($1,$2)")
            .bind(session_hash(context)?)
            .bind(context.issuer)
            .fetch_one(&context.state.pool)
            .await
            .map_err(common::database_error)?;
    let pending_expires_at =
        OffsetDateTime::parse(common::string(&status, "expires_at")?, &Rfc3339)
            .map_err(|_| ServiceError::Persistence)?;
    let key_version = common::string(&status, "otp_key_version")?;
    let key = match key_version {
        common::RESPONSE_OTP_KEY_VERSION => &context.state.response_portal_otp_key_current,
        common::RESPONSE_OTP_PREVIOUS_KEY_VERSION => context
            .state
            .response_portal_otp_key_previous
            .as_ref()
            .ok_or(ServiceError::InvalidSession)?,
        _ => return Err(ServiceError::InvalidSession),
    };
    let candidate = common::response_otp_verifier(key, otp)?;
    let receipt: Value = sqlx::query_scalar(
        "SELECT to_jsonb(intake.verify_response_session_v2(ROW($1,$2,$3,$4,$5,$6)::intake.response_otp_verify_v2))",
    )
    .bind(session_hash(context)?)
    .bind(context.issuer)
    .bind(candidate)
    .bind(key_version)
    .bind(sha256_hex(new_token.as_bytes()))
    .bind(expires_at)
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?;
    let request_id = uuid(&receipt, "request_id")?;
    let session_id = receipt
        .get("session_id")
        .and_then(Value::as_str)
        .map(Uuid::parse_str)
        .transpose()
        .map_err(|_| ServiceError::Persistence)?;
    let disposition = text(&receipt, "disposition")?.to_owned();
    let remaining = integer(&receipt, "remaining_attempts")? as i32;
    if disposition == "VERIFIED" {
        Ok(serde_json::json!({
            "requestId": request_id,
            "status": "VERIFIED",
            "remainingAttempts": remaining,
            "session": common::descriptor(new_token,"RESPONSE_ACTIVE",request_id,expires_at,1)?,
            "sessionId": session_id,
        }))
    } else {
        Ok(serde_json::json!({
            "requestId": request_id,
            "status": disposition,
            "remainingAttempts": remaining,
            "session": common::descriptor(
                common::session(context)?.to_owned(),
                "RESPONSE_PENDING",
                request_id,
                pending_expires_at,
                1
            )?,
        }))
    }
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
    let bytes: Vec<u8> =
        sqlx::query_scalar("SELECT intake.download_response_request_session_v2($1,$2)")
            .bind(session_hash(context)?)
            .bind(context.issuer)
            .fetch_one(&context.state.pool)
            .await
            .map_err(common::database_error)?;
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
    let row = sqlx::query(
        "SELECT draft_id,version FROM intake.save_response_draft_session_v2($1,$2,$3,$4,$5,$6)",
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
        "SELECT intake.create_response_attachment_session_v2($1,$2,$3,$4,$5,$6,$7)",
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
    let etag = common::string(&value, "objectEtag")?;
    let size = common::i64_field(&value, "uploadedSizeBytes")?;
    let digest = hash(common::string(&value, "uploadedSha256")?)?;
    let persisted: Uuid = sqlx::query_scalar(
        "SELECT intake.finalize_response_attachment_session_v2($1,$2,$3,$4,$5,$6)",
    )
    .bind(session_hash(context)?)
    .bind(context.issuer)
    .bind(id)
    .bind(etag)
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
        sqlx::query_scalar("SELECT intake.delete_response_attachment_session_v2($1,$2,$3)")
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
        sqlx::query_scalar("SELECT intake.request_response_extension_session_v2($1,$2,$3,$4)")
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
    let draft = projection::private_draft(context).await?;
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
    let submission_id = Uuid::new_v4();
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
    let id = persist_submission(
        context,
        submission_id,
        version,
        &digest,
        encrypted,
        consent,
        &receipt_token,
        &receipt_session,
        expires_at,
    )
    .await?;
    let mut receipt = common::command_receipt(context.operation, context.request_id, id, None)?;
    receipt["receiptSession"] =
        common::descriptor(receipt_session, "RESPONSE_RECEIPT", id, expires_at, 1)?;
    Ok(receipt)
}

#[expect(
    clippy::too_many_arguments,
    reason = "submission persistence binds receipt, evidence, and idempotency provenance"
)]
async fn persist_submission(
    context: &RequestContext<'_>,
    submission_id: Uuid,
    version: i64,
    digest: &str,
    encrypted: Vec<u8>,
    consent: &Value,
    receipt_token: &str,
    receipt_session: &str,
    expires_at: OffsetDateTime,
) -> Result<Uuid, ServiceError> {
    let mut transaction = context
        .state
        .pool
        .begin()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    let row = sqlx::query(
        "SELECT submission_id FROM intake.submit_response_session_v2($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)",
    )
    .bind(session_hash(context)?)
    .bind(context.issuer)
    .bind(version)
    .bind(digest)
    .bind(encrypted)
    .bind(consent)
    .bind(submission_id)
    .bind(common::token_hmac(
        &context.state.token_hmac_key,
        receipt_token,
    )?)
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
    let payload = serde_json::json!({"actor_id":context.issuer,"occurred_at":common::timestamp(occurred_at)?,"operation_id":context.operation,"requestToken":aggregate_id,"request_id":context.request_id});
    for event_type in [
        "response.submitted.v1",
        "notification.response_submitted.v1",
    ] {
        append(
            &mut transaction,
            &OutboxEvent {
                aggregate_type: "responseSubmission",
                aggregate_id: &id.to_string(),
                aggregate_version: 1,
                event_type,
                payload: &payload,
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
    Ok(id)
}

pub async fn get_receipt(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value: Value = sqlx::query_scalar("SELECT intake.get_response_receipt_session_v2($1,$2)")
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
