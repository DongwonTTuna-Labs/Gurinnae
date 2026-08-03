use gurine_auth::assertion::canonical::sha256_hex;
use gurine_persistence_postgres::outbox::{OutboxEvent, append};
use serde_json::Value;
use time::{Duration, OffsetDateTime};
use uuid::Uuid;

use super::{RequestContext, ServiceError, common};

pub async fn create(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    common::require_abuse_proof(context, &value, "createSubscription").await?;
    if !common::bool_field(&value, "consent")? {
        return Err(ServiceError::InvalidRequest);
    }
    let email = common::normalized_email(common::string(&value, "email")?)?;
    let frequency = frequency(common::string(&value, "frequency")?)?;
    let locale = common::string(&value, "locale")?;
    let topics = topics_from_create(&value)?;
    let pending_token = common::random_token()?;
    let pending_token_hash = sha256_hex(pending_token.as_bytes());
    let subscription_id = common::uuid_from_hash(&pending_token_hash)?;
    let verification_token = common::derived_token(
        &context.state.token_hmac_key,
        "subscription-verification",
        subscription_id,
    )?;
    let management_token = common::derived_token(
        &context.state.token_hmac_key,
        "subscription-management",
        subscription_id,
    )?;
    let expires_at = OffsetDateTime::now_utc() + Duration::minutes(30);
    let email_encrypted = common::encrypt_field(
        context,
        "intake.subscriptions",
        "email_encrypted",
        subscription_id,
        "email-address",
        email.as_bytes(),
    )?;

    let persisted = persist_subscription(
        context,
        &email,
        email_encrypted,
        &topics,
        frequency,
        locale,
        &verification_token,
        &management_token,
        pending_token_hash,
        expires_at,
    )
    .await?;

    let mut receipt =
        common::command_receipt(context.operation, context.request_id, persisted, Some(1))?;
    receipt["verificationDispatched"] = Value::Bool(true);
    receipt["pendingSession"] = common::descriptor(
        pending_token,
        "SUBSCRIPTION_PENDING",
        persisted,
        expires_at,
        1,
    )?;
    Ok(receipt)
}

#[expect(
    clippy::too_many_arguments,
    reason = "subscription persistence binds encrypted destination and consent provenance"
)]
async fn persist_subscription(
    context: &RequestContext<'_>,
    email: &str,
    email_encrypted: Vec<u8>,
    topics: &Value,
    frequency: &str,
    locale: &str,
    verification_token: &str,
    management_token: &str,
    pending_token_hash: String,
    expires_at: OffsetDateTime,
) -> Result<Uuid, ServiceError> {
    let mut transaction = context
        .state
        .pool
        .begin()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    let row = sqlx::query!(
        "SELECT subscription_id AS \"subscription_id?\" FROM intake.create_subscription_session($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)",
        common::token_hmac(&context.state.token_hmac_key, email)?,
        email_encrypted,
        topics,
        frequency,
        locale,
        common::token_hmac(&context.state.token_hmac_key, verification_token)?,
        common::token_hmac(&context.state.token_hmac_key, management_token)?,
        pending_token_hash,
        context.issuer,
        expires_at
    )
    .fetch_one(&mut *transaction)
    .await
    .map_err(common::database_error)?;
    let id = row.subscription_id.ok_or(ServiceError::Persistence)?;
    let aggregate_id = id.to_string();
    let occurred_at = OffsetDateTime::now_utc();
    let payload = serde_json::json!({"actor_id":context.issuer,"occurred_at":common::timestamp(occurred_at)?,"operation_id":context.operation,"request_id":context.request_id});
    append(
        &mut transaction,
        &OutboxEvent {
            aggregate_type: "subscription",
            aggregate_id: &aggregate_id,
            aggregate_version: 1,
            event_type: "notification.subscription_verification_requested.v1",
            payload: &payload,
            occurred_at,
        },
    )
    .await
    .map_err(|_| ServiceError::Persistence)?;
    transaction
        .commit()
        .await
        .map_err(|_| ServiceError::Persistence)?;
    Ok(id)
}

pub async fn verify(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let token = common::string(&value, "verificationToken")?;
    if token.len() < 32 {
        return Err(ServiceError::InvalidRequest);
    }
    let session_token = common::random_token()?;
    let expires_at = OffsetDateTime::now_utc() + Duration::minutes(30);
    let row = sqlx::query!(
        "SELECT subscription_id AS \"subscription_id?\", session_id AS \"session_id?\" FROM intake.verify_subscription_session($1,$2,$3,$4)",
        common::token_hmac(&context.state.token_hmac_key, token)?,
        sha256_hex(session_token.as_bytes()),
        context.issuer,
        expires_at
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?;
    let id = row.subscription_id.ok_or(ServiceError::Persistence)?;
    Ok(serde_json::json!({
        "status":"VERIFIED",
        "subscriptionId":id,
        "session":common::descriptor(
            session_token,"SUBSCRIPTION_MANAGEMENT",id,expires_at,1
        )?
    }))
}

pub async fn get(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = private(context).await?;
    let id = uuid(&value, "id")?;
    let email = common::decrypt_text(
        context,
        "intake.subscriptions",
        "email_encrypted",
        id,
        "email-address",
        text(&value, "email_encrypted")?,
    )?;
    Ok(serde_json::json!({
        "id": id,
        "status": value.get("status").cloned().ok_or(ServiceError::Persistence)?,
        "data": {
            "managementToken": id,
            "emailMasked": mask_email(&email)?,
            "topics": topic_labels(value.get("topics").ok_or(ServiceError::Persistence)?),
            "frequency": value.get("frequency").cloned().ok_or(ServiceError::Persistence)?,
            "locale": value.get("locale").cloned().ok_or(ServiceError::Persistence)?,
            "status": value.get("status").cloned().ok_or(ServiceError::Persistence)?,
            "verifiedAt": value.get("verified_at").cloned().unwrap_or(Value::Null)
        },
        "links": []
    }))
}

pub async fn update(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let topics = match value.get("scope") {
        Some(scope) if scope.is_object() => Some(topics_from_scope(scope)?),
        Some(Value::Null) | None => None,
        _ => return Err(ServiceError::InvalidRequest),
    };
    let frequency = common::optional_string(&value, "frequency")?
        .map(frequency)
        .transpose()?;
    let status = match value.get("paused") {
        Some(Value::Bool(true)) => Some("PAUSED"),
        Some(Value::Bool(false)) => Some("ACTIVE"),
        Some(Value::Null) | None => None,
        _ => return Err(ServiceError::InvalidRequest),
    };
    if topics.is_none() && frequency.is_none() && status.is_none() {
        return Err(ServiceError::InvalidRequest);
    }
    let id: Uuid = sqlx::query_scalar!(
        "SELECT intake.update_subscription_session($1,$2,$3,$4,$5) AS \"value?\"",
        session_hash(context)?,
        context.issuer,
        topics,
        frequency,
        status
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
    common::command_receipt(context.operation, context.request_id, id, None)
}

pub async fn unsubscribe(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    if !context.body.is_empty() {
        let value = common::parse(context.body)?;
        if value.as_object().is_none_or(serde_json::Map::is_empty) {
            // The OpenAPI request is intentionally empty.
        } else {
            return Err(ServiceError::InvalidRequest);
        }
    }
    let id: Uuid = sqlx::query_scalar!(
        "SELECT intake.unsubscribe_session($1,$2) AS \"value?\"",
        session_hash(context)?,
        context.issuer
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
    common::command_receipt(context.operation, context.request_id, id, None)
}

async fn private(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    sqlx::query_scalar!(
        "SELECT intake.get_subscription_session($1,$2) AS \"value?\"",
        session_hash(context)?,
        context.issuer
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)
}

fn topics_from_create(value: &Value) -> Result<Value, ServiceError> {
    let scope_type = common::string(value, "scopeType")?;
    let mut scope = serde_json::json!({"scopeType":scope_type});
    if let Some(reference) = common::optional_string(value, "scopeRef")? {
        scope["scopeRef"] = Value::String(reference.to_owned());
    }
    if let Some(query) = value.get("query") {
        if !query.is_object() {
            return Err(ServiceError::InvalidRequest);
        }
        scope["query"] = query.clone();
    }
    validate_scope(&scope)?;
    Ok(serde_json::json!([scope]))
}

fn topics_from_scope(scope: &Value) -> Result<Value, ServiceError> {
    validate_scope(scope)?;
    Ok(serde_json::json!([scope]))
}

fn validate_scope(scope: &Value) -> Result<(), ServiceError> {
    let scope_type = common::string(scope, "scopeType")?;
    if !matches!(
        scope_type,
        "GLOBAL" | "QUERY" | "CASE" | "AGENCY" | "SUPPLIER" | "CORRECTIONS"
    ) {
        return Err(ServiceError::InvalidRequest);
    }
    let has_ref = scope.get("scopeRef").and_then(Value::as_str).is_some();
    let has_query = scope.get("query").is_some_and(Value::is_object);
    match scope_type {
        "GLOBAL" | "CORRECTIONS" if !has_ref && !has_query => Ok(()),
        "QUERY" if has_query && !has_ref => Ok(()),
        "CASE" | "AGENCY" | "SUPPLIER" if has_ref && !has_query => Ok(()),
        _ => Err(ServiceError::InvalidRequest),
    }
}

fn topic_labels(value: &Value) -> Vec<String> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| item.get("scopeType").and_then(Value::as_str))
        .map(str::to_owned)
        .collect()
}

fn frequency(value: &str) -> Result<&str, ServiceError> {
    match value {
        "IMMEDIATE" | "DAILY" | "WEEKLY" => Ok(value),
        _ => Err(ServiceError::InvalidRequest),
    }
}

fn mask_email(value: &str) -> Result<String, ServiceError> {
    let (local, domain) = value.split_once('@').ok_or(ServiceError::Cryptography)?;
    let first = local.chars().next().ok_or(ServiceError::Cryptography)?;
    Ok(format!("{first}***@{domain}"))
}

fn session_hash(context: &RequestContext<'_>) -> Result<String, ServiceError> {
    Ok(sha256_hex(common::session(context)?.as_bytes()))
}

fn text<'a>(value: &'a Value, name: &str) -> Result<&'a str, ServiceError> {
    value
        .get(name)
        .and_then(Value::as_str)
        .ok_or(ServiceError::Persistence)
}

fn uuid(value: &Value, name: &str) -> Result<Uuid, ServiceError> {
    Uuid::parse_str(text(value, name)?).map_err(|_| ServiceError::Persistence)
}
