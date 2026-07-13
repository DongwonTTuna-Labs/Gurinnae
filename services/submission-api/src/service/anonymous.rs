use serde_json::Value;
use time::{Duration, OffsetDateTime};
use uuid::Uuid;

use super::{RequestContext, ServiceError, common};

pub async fn create_contact(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    common::require_abuse_proof(context, &value, "createContactRequest").await?;
    if !common::bool_field(&value, "privacyConsent")? {
        return Err(ServiceError::InvalidRequest);
    }
    let category = bounded(common::string(&value, "category")?, 80)?;
    let name = bounded(common::string(&value, "name")?, 200)?;
    let email = common::normalized_email(common::string(&value, "email")?)?;
    let subject = bounded(common::string(&value, "subject")?, 300)?;
    let message = bounded(common::string(&value, "message")?, 20_000)?;
    let receipt_token = common::random_token()?;
    let receipt_hash = common::token_hmac(&context.state.token_hmac_key, &receipt_token)?;
    let id = common::uuid_from_hash(&receipt_hash)?;
    let name_encrypted = common::encrypt_field(
        context,
        "intake.contact_requests",
        "name_encrypted",
        id,
        "contact-name",
        name.as_bytes(),
    )?;
    let email_encrypted = common::encrypt_field(
        context,
        "intake.contact_requests",
        "email_encrypted",
        id,
        "email-address",
        email.as_bytes(),
    )?;
    let message_encrypted = common::encrypt_field(
        context,
        "intake.contact_requests",
        "message_encrypted",
        id,
        "contact-message",
        message.as_bytes(),
    )?;
    let persisted: Uuid =
        sqlx::query_scalar("SELECT intake.create_contact_request($1,$2,$3,$4,$5,$6,$7)")
            .bind(category)
            .bind(name_encrypted)
            .bind(common::token_hmac(&context.state.token_hmac_key, &email)?)
            .bind(email_encrypted)
            .bind(subject)
            .bind(message_encrypted)
            .bind(receipt_hash)
            .fetch_one(&context.state.pool)
            .await
            .map_err(common::database_error)?;
    let mut receipt =
        common::command_receipt(context.operation, context.request_id, persisted, None)?;
    receipt["receiptToken"] = Value::String(receipt_token);
    Ok(receipt)
}

pub async fn create_dataset_export(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    common::require_abuse_proof(context, &value, "createDatasetExport").await?;
    let dataset_id = bounded(common::string(&value, "datasetId")?, 200)?;
    let format = common::string(&value, "format")?;
    if !matches!(format, "CSV" | "JSONL" | "PARQUET") {
        return Err(ServiceError::InvalidRequest);
    }
    let filters = common::object_or_array(&value, "filters")?;
    if !filters.is_object() {
        return Err(ServiceError::InvalidRequest);
    }
    let expires_seconds = common::i64_field(&value, "expiresInSeconds")?;
    if !(300..=604_800).contains(&expires_seconds) {
        return Err(ServiceError::InvalidRequest);
    }
    let email_hash = match common::optional_string(&value, "email")? {
        Some(email) => Some(common::token_hmac(
            &context.state.token_hmac_key,
            &common::normalized_email(email)?,
        )?),
        None => None,
    };
    let request_token = common::random_token()?;
    let request_token_hash = common::token_hmac(&context.state.token_hmac_key, &request_token)?;
    let persisted: Uuid =
        sqlx::query_scalar("SELECT intake.create_dataset_export($1,$2,$3,$4,$5,$6)")
            .bind(request_token_hash)
            .bind(email_hash)
            .bind(dataset_id)
            .bind(format)
            .bind(filters)
            .bind(OffsetDateTime::now_utc() + Duration::seconds(expires_seconds))
            .fetch_one(&context.state.pool)
            .await
            .map_err(common::database_error)?;
    let mut receipt =
        common::command_receipt(context.operation, context.request_id, persisted, None)?;
    receipt["receiptToken"] = Value::String(request_token);
    Ok(receipt)
}

fn bounded(value: &str, max_chars: usize) -> Result<&str, ServiceError> {
    if value.chars().count() > max_chars {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(value)
}
