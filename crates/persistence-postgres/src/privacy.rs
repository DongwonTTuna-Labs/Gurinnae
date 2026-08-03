use gurine_application::privacy::{
    CreatedPrivacyRequest, ExchangePrivacyReceiptToken, GetPrivacyRequest,
    PRIVACY_REQUEST_RECEIPT_COOKIE_NAME, PrivacyCommandReceipt, PrivacyNextActionCode,
    PrivacyRequestPublicStatus, PrivacyRequestRepository, PrivacyRequestSession,
};
use gurine_domain::privacy::{
    PrivacyDigest, PrivacyIdentityState, PrivacyRequestState, PrivacyRequestSummary,
    PrivacyRequestType,
};
use serde_json::{Map, Value};
use sqlx::PgConnection;
use thiserror::Error;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use crate::privacy_payload::create_owner_payload;

/// PostgreSQL boundary for the privacy request aggregate. All mutations and
/// scoped reads re-enter security-definer owners; this adapter never receives
/// table DML authority or raw identity/receipt secrets.
pub struct PostgresPrivacyRequestRepository<'connection> {
    connection: &'connection mut PgConnection,
}

impl<'connection> PostgresPrivacyRequestRepository<'connection> {
    pub const fn new(connection: &'connection mut PgConnection) -> Self {
        Self { connection }
    }

    async fn create_owner(
        &mut self,
        request: &gurine_application::privacy::CreatePrivacyRequest,
    ) -> Result<CreatedPrivacyRequest, PrivacyRepositoryError> {
        let payload = create_owner_payload(request)?;
        let value = sqlx::query_scalar!(
            "SELECT ops.create_privacy_request_v2($1::jsonb,$2,$3::char(64),$4::char(64))",
            sqlx::types::Json(payload) as _,
            request.transport_request_id,
            request.idempotency_key_sha256.as_str(),
            request.request_sha256.as_str(),
        )
        .fetch_one(&mut *self.connection)
        .await
        .map_err(map_sqlx)?
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)?;
        parse_created(&value)
    }

    async fn exchange_owner(
        &mut self,
        request: &ExchangePrivacyReceiptToken,
    ) -> Result<PrivacyRequestSession, PrivacyRepositoryError> {
        let value = sqlx::query_scalar!(
            "SELECT ops.exchange_privacy_request_receipt_token_v2($1::char(64),$2::char(64),$3,$4,$5::char(64),$6::char(64))",
            request.receipt_token_hmac.as_str(),
            request.next_submission_session_sha256.as_str(),
            &request.bff_issuer,
            request.transport_request_id,
            request.idempotency_key_sha256.as_str(),
            request.request_sha256.as_str(),
        )
        .fetch_one(&mut *self.connection)
        .await
        .map_err(map_sqlx)?
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)?;
        parse_session(&value)
    }

    async fn get_owner(
        &mut self,
        request: &GetPrivacyRequest,
    ) -> Result<PrivacyRequestPublicStatus, PrivacyRepositoryError> {
        let value = sqlx::query_scalar!(
            "SELECT ops.get_privacy_request_v2($1::char(64),$2)",
            request.session_token_sha256.as_str(),
            &request.bff_issuer,
        )
        .fetch_one(&mut *self.connection)
        .await
        .map_err(map_sqlx)?
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)?;
        parse_status(&value)
    }
}

impl PrivacyRequestRepository for PostgresPrivacyRequestRepository<'_> {
    type Error = PrivacyRepositoryError;

    fn create<'a>(
        &'a mut self,
        request: &'a gurine_application::privacy::CreatePrivacyRequest,
    ) -> gurine_application::privacy::PrivacyFuture<'a, CreatedPrivacyRequest, Self::Error> {
        Box::pin(async move { self.create_owner(request).await })
    }

    fn exchange<'a>(
        &'a mut self,
        request: &'a ExchangePrivacyReceiptToken,
    ) -> gurine_application::privacy::PrivacyFuture<'a, PrivacyRequestSession, Self::Error> {
        Box::pin(async move { self.exchange_owner(request).await })
    }

    fn get<'a>(
        &'a mut self,
        request: &'a GetPrivacyRequest,
    ) -> gurine_application::privacy::PrivacyFuture<'a, PrivacyRequestPublicStatus, Self::Error>
    {
        Box::pin(async move { self.get_owner(request).await })
    }
}

fn map_sqlx(error: sqlx::Error) -> PrivacyRepositoryError {
    let classified = error
        .as_database_error()
        .and_then(sqlx::error::DatabaseError::code)
        .as_deref()
        .and_then(repository_error_for_sqlstate);
    match classified {
        Some(PrivacySqlStateError::TokenInvalid) => PrivacyRepositoryError::TokenInvalid,
        Some(PrivacySqlStateError::TokenExpired) => PrivacyRepositoryError::TokenExpired,
        Some(PrivacySqlStateError::TokenReplayed) => PrivacyRepositoryError::TokenReplayed,
        Some(PrivacySqlStateError::ScopedSessionRequired) => {
            PrivacyRepositoryError::ScopedSessionRequired
        }
        Some(PrivacySqlStateError::IdempotencyConflict) => {
            PrivacyRepositoryError::IdempotencyConflict
        }
        Some(PrivacySqlStateError::IdentityProofInvalid) => {
            PrivacyRepositoryError::IdentityProofInvalid
        }
        Some(PrivacySqlStateError::ScopeInvalid) => PrivacyRepositoryError::ScopeInvalid,
        Some(PrivacySqlStateError::NotFound) => PrivacyRepositoryError::NotFound,
        None => PrivacyRepositoryError::Unavailable(error),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PrivacySqlStateError {
    TokenInvalid,
    TokenExpired,
    TokenReplayed,
    ScopedSessionRequired,
    IdempotencyConflict,
    IdentityProofInvalid,
    ScopeInvalid,
    NotFound,
}

fn repository_error_for_sqlstate(code: &str) -> Option<PrivacySqlStateError> {
    match code {
        "PVT01" => Some(PrivacySqlStateError::TokenInvalid),
        "PVT02" => Some(PrivacySqlStateError::TokenExpired),
        "PVT03" => Some(PrivacySqlStateError::TokenReplayed),
        "PVT04" => Some(PrivacySqlStateError::ScopedSessionRequired),
        "PVT05" => Some(PrivacySqlStateError::IdempotencyConflict),
        "PVT06" => Some(PrivacySqlStateError::IdentityProofInvalid),
        "PVT07" => Some(PrivacySqlStateError::ScopeInvalid),
        "P0002" => Some(PrivacySqlStateError::NotFound),
        _ => None,
    }
}

#[derive(Debug, Error)]
pub enum PrivacyRepositoryError {
    #[error("privacy owner returned a value outside the closed contract")]
    InvalidOwnerResult,
    #[error("privacy persistence is unavailable")]
    Unavailable(#[source] sqlx::Error),
    #[error("privacy idempotency key conflicts with another request")]
    IdempotencyConflict,
    #[error("privacy identity proof does not bind the requested subject")]
    IdentityProofInvalid,
    #[error("privacy request scope is invalid")]
    ScopeInvalid,
    #[error("privacy receipt token is invalid")]
    TokenInvalid,
    #[error("privacy receipt token is expired")]
    TokenExpired,
    #[error("privacy receipt token is already consumed")]
    TokenReplayed,
    #[error("privacy scoped session is unavailable")]
    ScopedSessionRequired,
    #[error("privacy request was not found in the authorized scope")]
    NotFound,
}

pub(crate) fn parse_created(
    value: &Value,
) -> Result<CreatedPrivacyRequest, PrivacyRepositoryError> {
    let object = closed_object(value, &["command", "request", "replayed"])?;
    let command = parse_command(required(object, "command")?)?;
    let request = parse_summary(required(object, "request")?)?;
    let replayed = boolean(object, "replayed")?;
    Ok(CreatedPrivacyRequest {
        command,
        request,
        replayed,
    })
}

pub(crate) fn parse_session(
    value: &Value,
) -> Result<PrivacyRequestSession, PrivacyRepositoryError> {
    let object = closed_object(
        value,
        &[
            "sessionId",
            "privacyRequestId",
            "sessionKind",
            "scopeType",
            "scopeId",
            "bffIssuer",
            "issuedAt",
            "expiresAt",
            "auditEventId",
            "emittedEventIds",
            "receiptDigest",
            "replayed",
        ],
    )?;
    let privacy_request_id = uuid(object, "privacyRequestId")?;
    if string(object, "sessionKind")? != "PRIVACY_REQUEST_RECEIPT"
        || string(object, "scopeType")? != "PRIVACY_REQUEST"
        || uuid(object, "scopeId")? != privacy_request_id
        || string(object, "bffIssuer")? != "public-web"
    {
        return Err(PrivacyRepositoryError::InvalidOwnerResult);
    }
    Ok(PrivacyRequestSession {
        request_id: privacy_request_id,
        session_id: uuid(object, "sessionId")?,
        expires_at: timestamp(object, "expiresAt")?,
        cookie_name: PRIVACY_REQUEST_RECEIPT_COOKIE_NAME.to_owned(),
        token_consumed_at: timestamp(object, "issuedAt")?,
        audit_event_id: uuid(object, "auditEventId")?,
        emitted_event_ids: uuid_array(object, "emittedEventIds", 32)?,
        receipt_digest: digest(object, "receiptDigest")?,
        replayed: boolean(object, "replayed")?,
    })
}

pub(crate) fn parse_status(
    value: &Value,
) -> Result<PrivacyRequestPublicStatus, PrivacyRepositoryError> {
    let object = closed_object(
        value,
        &[
            "request",
            "decisionReasonCode",
            "decisionReceiptId",
            "decisionReceiptSha256",
            "refusalNoticeReceiptId",
            "refusalNoticeReceiptSha256",
            "noticeReceiptIds",
            "noticeReceiptSha256s",
            "nextActionCodes",
            "asOf",
            "links",
            "operationId",
        ],
    )?;
    if string(object, "operationId")? != "getPrivacyRequest" {
        return Err(PrivacyRepositoryError::InvalidOwnerResult);
    }
    let links = required(object, "links")?
        .as_array()
        .filter(|links| links.is_empty())
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)?;
    let _ = links;
    let actions = string_array(object, "nextActionCodes", 1)?;
    let next_action_code = actions
        .first()
        .copied()
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)
        .and_then(|value| {
            PrivacyNextActionCode::try_from(value)
                .map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)
        })?;
    Ok(PrivacyRequestPublicStatus {
        request: parse_summary(required(object, "request")?)?,
        decision_reason_code: optional_string(object, "decisionReasonCode")?.map(str::to_owned),
        decision_receipt_id: optional_uuid(object, "decisionReceiptId")?,
        decision_receipt_sha256: optional_digest(object, "decisionReceiptSha256")?,
        refusal_notice_receipt_id: optional_uuid(object, "refusalNoticeReceiptId")?,
        refusal_notice_receipt_sha256: optional_digest(object, "refusalNoticeReceiptSha256")?,
        notice_receipt_ids: uuid_array(object, "noticeReceiptIds", 100)?,
        notice_receipt_sha256s: digest_array(object, "noticeReceiptSha256s", 100)?,
        next_action_code,
        as_of: timestamp(object, "asOf")?,
    })
}

fn parse_command(value: &Value) -> Result<PrivacyCommandReceipt, PrivacyRepositoryError> {
    let object = closed_object(
        value,
        &[
            "transportRequestId",
            "aggregateId",
            "aggregateVersion",
            "auditEventId",
            "acceptedAt",
            "receiptDigest",
            "emittedEventIds",
        ],
    )?;
    Ok(PrivacyCommandReceipt {
        transport_request_id: uuid(object, "transportRequestId")?,
        aggregate_id: uuid(object, "aggregateId")?,
        aggregate_version: positive_i64(object, "aggregateVersion")?,
        audit_event_id: uuid(object, "auditEventId")?,
        accepted_at: timestamp(object, "acceptedAt")?,
        receipt_digest: digest(object, "receiptDigest")?,
        emitted_event_ids: uuid_array(object, "emittedEventIds", 32)?,
    })
}

fn parse_summary(value: &Value) -> Result<PrivacyRequestSummary, PrivacyRepositoryError> {
    let object = closed_object(
        value,
        &[
            "privacyRequestId",
            "requestType",
            "state",
            "jurisdiction",
            "scopeDigest",
            "identityState",
            "identityVerifiedAt",
            "dueAt",
            "createdAt",
            "updatedAt",
        ],
    )?;
    PrivacyRequestSummary::try_new(
        uuid(object, "privacyRequestId")?,
        PrivacyRequestType::try_from(string(object, "requestType")?)
            .map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)?,
        PrivacyRequestState::try_from(string(object, "state")?)
            .map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)?,
        string(object, "jurisdiction")?,
        digest(object, "scopeDigest")?,
        PrivacyIdentityState::try_from(string(object, "identityState")?)
            .map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)?,
        optional_timestamp(object, "identityVerifiedAt")?,
        optional_timestamp(object, "dueAt")?,
        timestamp(object, "createdAt")?,
        timestamp(object, "updatedAt")?,
    )
    .map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)
}

fn closed_object<'a>(
    value: &'a Value,
    fields: &[&str],
) -> Result<&'a Map<String, Value>, PrivacyRepositoryError> {
    value
        .as_object()
        .filter(|object| {
            object.len() == fields.len()
                && object.keys().all(|field| fields.contains(&field.as_str()))
        })
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)
}

fn required<'a>(
    object: &'a Map<String, Value>,
    field: &str,
) -> Result<&'a Value, PrivacyRepositoryError> {
    object
        .get(field)
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)
}

fn string<'a>(
    object: &'a Map<String, Value>,
    field: &str,
) -> Result<&'a str, PrivacyRepositoryError> {
    required(object, field)?
        .as_str()
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)
}

fn optional_string<'a>(
    object: &'a Map<String, Value>,
    field: &str,
) -> Result<Option<&'a str>, PrivacyRepositoryError> {
    match required(object, field)? {
        Value::Null => Ok(None),
        Value::String(value) => Ok(Some(value)),
        _ => Err(PrivacyRepositoryError::InvalidOwnerResult),
    }
}

fn uuid(object: &Map<String, Value>, field: &str) -> Result<Uuid, PrivacyRepositoryError> {
    Uuid::parse_str(string(object, field)?).map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)
}

fn optional_uuid(
    object: &Map<String, Value>,
    field: &str,
) -> Result<Option<Uuid>, PrivacyRepositoryError> {
    optional_string(object, field)?
        .map(Uuid::parse_str)
        .transpose()
        .map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)
}

fn digest(
    object: &Map<String, Value>,
    field: &str,
) -> Result<PrivacyDigest, PrivacyRepositoryError> {
    PrivacyDigest::try_new(string(object, field)?)
        .map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)
}

fn optional_digest(
    object: &Map<String, Value>,
    field: &str,
) -> Result<Option<PrivacyDigest>, PrivacyRepositoryError> {
    optional_string(object, field)?
        .map(PrivacyDigest::try_new)
        .transpose()
        .map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)
}

fn timestamp(
    object: &Map<String, Value>,
    field: &str,
) -> Result<OffsetDateTime, PrivacyRepositoryError> {
    OffsetDateTime::parse(string(object, field)?, &Rfc3339)
        .map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)
}

fn optional_timestamp(
    object: &Map<String, Value>,
    field: &str,
) -> Result<Option<OffsetDateTime>, PrivacyRepositoryError> {
    optional_string(object, field)?
        .map(|value| OffsetDateTime::parse(value, &Rfc3339))
        .transpose()
        .map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)
}

fn positive_i64(object: &Map<String, Value>, field: &str) -> Result<i64, PrivacyRepositoryError> {
    required(object, field)?
        .as_i64()
        .filter(|value| *value > 0)
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)
}

fn boolean(object: &Map<String, Value>, field: &str) -> Result<bool, PrivacyRepositoryError> {
    required(object, field)?
        .as_bool()
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)
}

fn uuid_array(
    object: &Map<String, Value>,
    field: &str,
    maximum: usize,
) -> Result<Vec<Uuid>, PrivacyRepositoryError> {
    required(object, field)?
        .as_array()
        .filter(|items| items.len() <= maximum)
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)?
        .iter()
        .map(|item| {
            item.as_str()
                .ok_or(PrivacyRepositoryError::InvalidOwnerResult)
                .and_then(|value| {
                    Uuid::parse_str(value).map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)
                })
        })
        .collect()
}

fn digest_array(
    object: &Map<String, Value>,
    field: &str,
    maximum: usize,
) -> Result<Vec<PrivacyDigest>, PrivacyRepositoryError> {
    required(object, field)?
        .as_array()
        .filter(|items| items.len() <= maximum)
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)?
        .iter()
        .map(|item| {
            item.as_str()
                .ok_or(PrivacyRepositoryError::InvalidOwnerResult)
                .and_then(|value| {
                    PrivacyDigest::try_new(value)
                        .map_err(|_| PrivacyRepositoryError::InvalidOwnerResult)
                })
        })
        .collect()
}

fn string_array<'a>(
    object: &'a Map<String, Value>,
    field: &str,
    exact_length: usize,
) -> Result<Vec<&'a str>, PrivacyRepositoryError> {
    required(object, field)?
        .as_array()
        .filter(|items| items.len() == exact_length)
        .ok_or(PrivacyRepositoryError::InvalidOwnerResult)?
        .iter()
        .map(|item| {
            item.as_str()
                .ok_or(PrivacyRepositoryError::InvalidOwnerResult)
        })
        .collect()
}

#[cfg(test)]
#[path = "privacy_tests.rs"]
mod tests;
