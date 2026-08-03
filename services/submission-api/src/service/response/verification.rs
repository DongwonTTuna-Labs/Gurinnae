use gurine_auth::assertion::canonical::sha256_hex;
use serde_json::Value;
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use super::super::{RequestContext, ServiceError, common};
use super::{integer, session_hash, text, uuid};

pub(super) async fn verify(context: &RequestContext<'_>) -> Result<Value, ServiceError> {
    let value = common::parse(context.body)?;
    let otp = validate_otp(&value)?;
    let new_token = common::random_token()?;
    let expires_at = OffsetDateTime::now_utc() + Duration::hours(12);
    let status: Value = sqlx::query_scalar!(
        "SELECT intake.get_response_access_status_session_v2($1,$2) AS \"value?\"",
        session_hash(context)?,
        context.issuer
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
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
    let receipt: Value = sqlx::query_scalar!(
        "SELECT to_jsonb(intake.verify_response_session_v2(ROW($1,$2,$3,$4,$5,$6)::intake.response_otp_verify_v2)) AS \"value?\"",
        session_hash(context)?,
        context.issuer,
        candidate,
        key_version,
        sha256_hex(new_token.as_bytes()),
        expires_at
    )
    .fetch_one(&context.state.pool)
    .await
    .map_err(common::database_error)?
    .ok_or(ServiceError::Persistence)?;
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

fn validate_otp(value: &Value) -> Result<&str, ServiceError> {
    let otp = common::string(value, "emailOtp")?;
    if otp.len() < 4 || otp.len() > 12 || !otp.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(otp)
}
