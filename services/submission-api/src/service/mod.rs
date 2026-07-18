use gurine_auth::assertion::canonical::sha256_hex;
use serde_json::Value;
use sqlx::Row;
use thiserror::Error;
use time::{Duration, OffsetDateTime};
use uuid::Uuid;

use crate::state::AppState;

mod addendum;
mod anonymous;
mod common;
mod correction;
mod response;
mod subscription;

pub struct RequestContext<'a> {
    pub operation: &'a str,
    pub body: &'a [u8],
    pub issuer: &'a str,
    pub request_id: &'a str,
    pub session_token: Option<&'a str>,
    pub attachment_id: Option<Uuid>,
    pub state: &'a AppState,
}

#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("submission request is invalid")]
    InvalidRequest,
    #[error("submission token is invalid or already consumed")]
    TokenInvalid,
    #[error("submission session is invalid, expired, revoked, or out of scope")]
    InvalidSession,
    #[error("submission resource was not found")]
    NotFound,
    #[error("submission state or optimistic version conflicts")]
    Conflict,
    #[error("submission target is closed")]
    Closed,
    #[error("anonymous abuse proof is invalid")]
    AbuseProofInvalid,
    #[error("anonymous abuse proof provider is unavailable")]
    AbuseProofUnavailable,
    #[error("submission persistence is unavailable")]
    Persistence,
    #[error("submission cryptography failed")]
    Cryptography,
}

#[rustfmt::skip]
pub async fn execute(context: RequestContext<'_>) -> Result<Value, ServiceError> {
    if gurine_api_contracts::addendum::is_submission_operation(context.operation) {
        return addendum::execute(&context).await;
    }
    match context.operation {
        "createContactRequest" => anonymous::create_contact(&context).await,
        "createDatasetExport" => anonymous::create_dataset_export(&context).await,
        "createCorrectionRequestDraft" => create_correction_session(context.body, context.issuer, context.request_id, context.state).await,
        "getCorrectionRequestDraft" => correction::get_draft(&context).await,
        "saveCorrectionRequestDraft" => correction::save_draft(&context).await,
        "deleteCorrectionRequestDraft" => correction::delete_draft(&context).await,
        "createCorrectionAttachment" => correction::create_attachment(&context).await,
        "finalizeCorrectionAttachment" => correction::finalize_attachment(&context).await,
        "deleteCorrectionAttachment" => correction::delete_attachment(&context).await,
        "getCorrectionRequestDraftPreview" => correction::preview(&context).await,
        "createCorrectionRequest" => correction::submit(&context).await,
        "getCorrectionReceipt" => correction::get_receipt(&context).await,
        "getResponseAccessStatus" => response::access_status(&context).await,
        "verifyResponseAccess" => response::verify(&context).await,
        "getResponseRequest" => response::get_request(&context).await,
        "downloadResponseRequest" => response::download_request(&context).await,
        "getResponseDraft" => response::get_draft(&context).await,
        "saveResponseDraft" => response::save_draft(&context).await,
        "createResponseAttachmentUpload" => response::create_attachment(&context).await,
        "finalizeResponseAttachment" => response::finalize_attachment(&context).await,
        "deleteResponseAttachment" => response::delete_attachment(&context).await,
        "getResponseSubmissionPreview" => response::preview(&context).await,
        "requestResponseExtension" => response::request_extension(&context).await,
        "submitResponse" => response::submit(&context).await,
        "getResponseReceipt" => response::get_receipt(&context).await,
        "createSubscription" => subscription::create(&context).await,
        "verifySubscription" => subscription::verify(&context).await,
        "getSubscription" => subscription::get(&context).await,
        "updateSubscription" => subscription::update(&context).await,
        "unsubscribe" => subscription::unsubscribe(&context).await,
        "exchangeResponseAccessToken" => exchange(context.body, context.issuer, "RESPONSE_PENDING", "intake.exchange_response_magic_token_v2", context.request_id, context.state).await,
        "exchangeResponseReceiptToken" => exchange(context.body, context.issuer, "RESPONSE_RECEIPT", "intake.exchange_response_receipt_token", context.request_id, context.state).await,
        "exchangeCorrectionReceiptToken" => exchange(context.body, context.issuer, "CORRECTION_RECEIPT", "intake.exchange_correction_receipt_token", context.request_id, context.state).await,
        "exchangeSubscriptionManagementToken" => exchange(context.body, context.issuer, "SUBSCRIPTION_MANAGEMENT", "intake.exchange_subscription_management_token", context.request_id, context.state).await,
        _ => Err(ServiceError::InvalidRequest),
    }
}

async fn create_correction_session(
    body: &[u8],
    issuer: &str,
    request_id: &str,
    state: &AppState,
) -> Result<Value, ServiceError> {
    let value = common::parse(body)?;
    let locale = common::string(&value, "locale")?;
    let case_slug = common::optional_string(&value, "caseSlug")?;
    let revision = common::optional_i64(&value, "publicationRevision")?;
    let proof_context = RequestContext {
        operation: "createCorrectionRequestDraft",
        body,
        issuer,
        request_id,
        session_token: None,
        attachment_id: None,
        state,
    };
    common::require_abuse_proof(&proof_context, &value, "createCorrectionRequestDraft").await?;
    let token = common::random_token()?;
    let token_hash = sha256_hex(token.as_bytes());
    let expires_at = OffsetDateTime::now_utc() + Duration::hours(24);
    let row = sqlx::query(
        "SELECT draft_id,session_id,version FROM intake.create_correction_session($1,$2,$3,$4,$5,$6)",
    )
    .bind(token_hash)
    .bind(issuer)
    .bind(locale)
    .bind(case_slug)
    .bind(revision.map(|value| value as i32))
    .bind(expires_at)
    .fetch_one(&state.pool)
    .await
    .map_err(common::database_error)?;
    let draft_id: Uuid = row
        .try_get("draft_id")
        .map_err(|_| ServiceError::Persistence)?;
    let version: i64 = row
        .try_get("version")
        .map_err(|_| ServiceError::Persistence)?;
    Ok(serde_json::json!({
        "operationId":"createCorrectionRequestDraft",
        "requestId":request_id,
        "status":"accepted",
        "aggregateId":draft_id,
        "aggregateVersion":version,
        "acceptedAt":common::timestamp_now()?,
        "links":[],
        "session":common::descriptor(token,"CORRECTION_DRAFT",draft_id,expires_at,1)?,
    }))
}

async fn exchange(
    body: &[u8],
    issuer: &str,
    kind: &str,
    function: &str,
    _request_id: &str,
    state: &AppState,
) -> Result<Value, ServiceError> {
    let value = common::parse(body)?;
    let one_time_token = common::string(&value, "oneTimeToken")?;
    if one_time_token.len() < 32 {
        return Err(ServiceError::InvalidRequest);
    }
    let session_token = common::random_token()?;
    let expires_at = OffsetDateTime::now_utc()
        + if kind == "RESPONSE_PENDING" {
            Duration::minutes(15)
        } else {
            Duration::minutes(30)
        };
    let sql = match function {
        "intake.exchange_response_magic_token_v2" => {
            "SELECT session_id FROM intake.exchange_response_magic_token_v2($1,$2,$3,$4)"
        }
        "intake.exchange_response_receipt_token" => {
            "SELECT intake.exchange_response_receipt_token($1,$2,$3,$4) AS session_id"
        }
        "intake.exchange_correction_receipt_token" => {
            "SELECT intake.exchange_correction_receipt_token($1,$2,$3,$4) AS session_id"
        }
        "intake.exchange_subscription_management_token" => {
            "SELECT intake.exchange_subscription_management_token($1,$2,$3,$4) AS session_id"
        }
        _ => return Err(ServiceError::InvalidRequest),
    };
    sqlx::query(sql)
        .bind(common::token_hmac(&state.token_hmac_key, one_time_token)?)
        .bind(sha256_hex(session_token.as_bytes()))
        .bind(issuer)
        .bind(expires_at)
        .fetch_one(&state.pool)
        .await
        .map_err(|error| {
            if matches!(error, sqlx::Error::Database(_)) {
                ServiceError::TokenInvalid
            } else {
                ServiceError::Persistence
            }
        })?;
    let scope_id = resolve_scope(&state.pool, &session_token, issuer, kind).await?;
    Ok(serde_json::json!({
        "status":"exchanged",
        "session":common::descriptor(session_token,kind,scope_id,expires_at,1)?,
    }))
}

async fn resolve_scope(
    pool: &sqlx::PgPool,
    token: &str,
    issuer: &str,
    kind: &str,
) -> Result<Uuid, ServiceError> {
    sqlx::query_scalar("SELECT scope_id FROM intake.resolve_submission_session($1,$2,$3)")
        .bind(sha256_hex(token.as_bytes()))
        .bind(issuer)
        .bind(vec![kind.to_owned()])
        .fetch_one(pool)
        .await
        .map_err(common::database_error)
}
