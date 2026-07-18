use super::super::{RequestContext, ServiceError, common};
use super::{integer, publication_model, text, uuid};
use gurine_auth::assertion::canonical::sha256_hex;
use serde_json::Value;

pub(super) async fn private_request(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    sqlx::query_scalar("SELECT intake.get_response_request_session_v2($1,$2)")
        .bind(session_hash(context)?)
        .bind(context.issuer)
        .fetch_one(&context.state.pool)
        .await
        .map_err(common::database_error)
}

pub(super) async fn private_draft(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    sqlx::query_scalar("SELECT intake.get_response_draft_session_v2($1,$2)")
        .bind(session_hash(context)?)
        .bind(context.issuer)
        .fetch_one(&context.state.pool)
        .await
        .map_err(common::database_error)
}

pub(super) async fn private_attachments(
    context: &RequestContext<'_>,
) -> Result<Value, ServiceError> {
    let preview: Value = sqlx::query_scalar("SELECT intake.get_response_preview_session_v2($1,$2)")
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

pub(super) async fn project_draft(
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
    Ok(
        serde_json::json!({"requestId": uuid(draft,"response_request_id")?, "version": integer(draft,"version")?, "answers": answers, "attachments": project_attachments(context,&attachments,&consent)?, "publicationConsent": publication_model(&consent,updated_at), "savedAt": draft.get("saved_at").cloned().unwrap_or(Value::Null), "expiresAt": draft.get("expires_at").cloned().ok_or(ServiceError::Persistence)?}),
    )
}

pub(super) fn project_attachments(
    context: &RequestContext<'_>,
    value: &Value,
    consent: &Value,
) -> Result<Vec<Value>, ServiceError> {
    value.as_array().ok_or(ServiceError::Persistence)?.iter().map(|attachment| {
        let id = uuid(attachment, "id")?;
        let filename = common::decrypt_text(context, "intake.response_attachments", "original_filename_encrypted", id, "original-filename", text(attachment, "filename_encrypted")?)?;
        let id_text = id.to_string();
        let may_publish = consent.get("attachmentConsents").and_then(Value::as_array).and_then(|items| items.iter().find(|item| item.get("attachmentId").and_then(Value::as_str) == Some(id_text.as_str()))).and_then(|item| item.get("mayPublish")).and_then(Value::as_bool).unwrap_or(false);
        Ok(serde_json::json!({"id":id,"filename":filename,"mediaType":attachment.get("media_type").cloned().ok_or(ServiceError::Persistence)?,"sizeBytes":attachment.get("size_bytes").cloned().ok_or(ServiceError::Persistence)?,"sha256":attachment.get("sha256").cloned().ok_or(ServiceError::Persistence)?,"uploadStatus":attachment.get("upload_status").cloned().ok_or(ServiceError::Persistence)?,"scanStatus":attachment.get("scan_status").cloned().ok_or(ServiceError::Persistence)?,"publicationConsent":may_publish}))
    }).collect()
}

fn session_hash(context: &RequestContext<'_>) -> Result<String, ServiceError> {
    Ok(sha256_hex(common::session(context)?.as_bytes()))
}

pub(super) async fn scope_id(
    context: &RequestContext<'_>,
    kinds: &[&str],
) -> Result<uuid::Uuid, ServiceError> {
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
