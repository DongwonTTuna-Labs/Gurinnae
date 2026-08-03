use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use gurine_auth::{
    assertion::canonical::{canonical_json, sha256_hex},
    envelope::decrypt,
};
use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::Sha256;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;
use zeroize::Zeroize;

use super::{RequestContext, ServiceError};

pub use super::privacy_crypto::encrypt_field_material;

pub(super) const FIELD_PREFIX: &str = "gurine-fe-v1";
pub const RESPONSE_OTP_DERIVATION_VERSION: &str = "response-access-otp-v2";
pub const RESPONSE_OTP_KEY_VERSION: &str = "response-portal-submission-hmac-v1";
pub const RESPONSE_OTP_PREVIOUS_KEY_VERSION: &str = "response-portal-submission-hmac-v0";

pub fn parse(body: &[u8]) -> Result<Value, ServiceError> {
    serde_json::from_slice(body).map_err(|_| ServiceError::InvalidRequest)
}

pub fn string<'a>(value: &'a Value, name: &str) -> Result<&'a str, ServiceError> {
    value
        .get(name)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|field| !field.is_empty())
        .ok_or(ServiceError::InvalidRequest)
}

pub fn optional_string<'a>(value: &'a Value, name: &str) -> Result<Option<&'a str>, ServiceError> {
    match value.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(field) => field
            .as_str()
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(Some)
            .ok_or(ServiceError::InvalidRequest),
    }
}

pub fn i64_field(value: &Value, name: &str) -> Result<i64, ServiceError> {
    value
        .get(name)
        .and_then(Value::as_i64)
        .ok_or(ServiceError::InvalidRequest)
}

pub fn optional_i64(value: &Value, name: &str) -> Result<Option<i64>, ServiceError> {
    match value.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(field) => field.as_i64().map(Some).ok_or(ServiceError::InvalidRequest),
    }
}

pub fn bool_field(value: &Value, name: &str) -> Result<bool, ServiceError> {
    value
        .get(name)
        .and_then(Value::as_bool)
        .ok_or(ServiceError::InvalidRequest)
}

pub fn object_or_array<'a>(value: &'a Value, name: &str) -> Result<&'a Value, ServiceError> {
    value
        .get(name)
        .filter(|field| field.is_object() || field.is_array())
        .ok_or(ServiceError::InvalidRequest)
}

pub fn session<'a>(context: &'a RequestContext<'_>) -> Result<&'a str, ServiceError> {
    context.session_token.ok_or(ServiceError::InvalidSession)
}

pub fn attachment_id(context: &RequestContext<'_>) -> Result<Uuid, ServiceError> {
    context.attachment_id.ok_or(ServiceError::InvalidRequest)
}

pub fn random_token() -> Result<String, ServiceError> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| ServiceError::Cryptography)?;
    let token = URL_SAFE_NO_PAD.encode(bytes);
    bytes.zeroize();
    Ok(token)
}

pub fn token_hmac(key: &[u8], token: &str) -> Result<String, ServiceError> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).map_err(|_| ServiceError::Cryptography)?;
    mac.update(token.as_bytes());
    Ok(mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

pub fn derived_token(key: &[u8], purpose: &str, id: Uuid) -> Result<String, ServiceError> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).map_err(|_| ServiceError::Cryptography)?;
    mac.update(purpose.as_bytes());
    mac.update(b":");
    // Bind the token to the UUID's canonical 16-byte value.  The integration
    // and receipt contracts use the UUID bytes (without textual hyphens), so
    // hashing the display string would produce a token that cannot be
    // re-derived by clients or verified by the delivery worker.
    mac.update(id.as_bytes());
    Ok(URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes()))
}

pub fn uuid_from_hash(hash: &str) -> Result<Uuid, ServiceError> {
    if hash.len() != 64 {
        return Err(ServiceError::Cryptography);
    }
    let bytes = decode_hex(hash).ok_or(ServiceError::Cryptography)?;
    let mut uuid_bytes: [u8; 16] = bytes
        .get(..16)
        .ok_or(ServiceError::Cryptography)?
        .try_into()
        .map_err(|_| ServiceError::Cryptography)?;
    uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40;
    uuid_bytes[8] = (uuid_bytes[8] & 0x0f) | 0x80;
    Ok(Uuid::from_bytes(uuid_bytes))
}

#[cfg(test)]
fn response_otp(key: &[u8], access_token_hash: &str) -> Result<String, ServiceError> {
    let digest = token_hmac(key, &format!("response-otp:{access_token_hash}"))?;
    let prefix = digest.get(..8).ok_or(ServiceError::Cryptography)?;
    let value = u32::from_str_radix(prefix, 16).map_err(|_| ServiceError::Cryptography)?;
    Ok(format!("{:06}", value % 1_000_000))
}

/// Computes the candidate verifier submitted to PostgreSQL for a response
/// access OTP.  The raw OTP never crosses the persistence boundary: it is
/// bound to the response-access purpose and derivation revision.
pub fn response_otp_verifier(key: &[u8], otp: &str) -> Result<String, ServiceError> {
    token_hmac(
        key,
        &format!("{RESPONSE_OTP_DERIVATION_VERSION}:response-access:{otp}"),
    )
}

pub fn normalized_email(value: &str) -> Result<String, ServiceError> {
    let email = value.trim().to_lowercase();
    let Some((local, domain)) = email.rsplit_once('@') else {
        return Err(ServiceError::InvalidRequest);
    };
    if local.is_empty()
        || domain.is_empty()
        || domain.starts_with('.')
        || domain.ends_with('.')
        || !domain.contains('.')
        || email.len() > 320
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(email)
}

pub fn encrypt_field(
    context: &RequestContext<'_>,
    table: &str,
    column: &str,
    record_id: Uuid,
    logical_type: &str,
    plaintext: &[u8],
) -> Result<Vec<u8>, ServiceError> {
    encrypt_field_material(context, table, column, record_id, logical_type, plaintext)
        .map(|material| material.ciphertext)
}

pub fn decrypt_field(
    context: &RequestContext<'_>,
    table: &str,
    column: &str,
    record_id: Uuid,
    logical_type: &str,
    ciphertext: &str,
) -> Result<Vec<u8>, ServiceError> {
    let record_id = record_id.to_string();
    decrypt(
        FIELD_PREFIX,
        &context.state.field_keys,
        &[table, column, &record_id, logical_type, "1"],
        ciphertext,
    )
    .map_err(|_| ServiceError::Cryptography)
}

pub fn decrypt_json(
    context: &RequestContext<'_>,
    table: &str,
    column: &str,
    record_id: Uuid,
    logical_type: &str,
    ciphertext: &str,
) -> Result<Value, ServiceError> {
    serde_json::from_slice(&decrypt_field(
        context,
        table,
        column,
        record_id,
        logical_type,
        ciphertext,
    )?)
    .map_err(|_| ServiceError::Cryptography)
}

pub fn decrypt_text(
    context: &RequestContext<'_>,
    table: &str,
    column: &str,
    record_id: Uuid,
    logical_type: &str,
    ciphertext: &str,
) -> Result<String, ServiceError> {
    String::from_utf8(decrypt_field(
        context,
        table,
        column,
        record_id,
        logical_type,
        ciphertext,
    )?)
    .map_err(|_| ServiceError::Cryptography)
}

pub fn timestamp(value: OffsetDateTime) -> Result<String, ServiceError> {
    value
        .format(&Rfc3339)
        .map_err(|_| ServiceError::InvalidRequest)
}

pub fn timestamp_now() -> Result<String, ServiceError> {
    timestamp(OffsetDateTime::now_utc())
}

pub fn digest(value: &Value) -> Result<String, ServiceError> {
    canonical_json(value)
        .map(|bytes| sha256_hex(&bytes))
        .map_err(|_| ServiceError::InvalidRequest)
}

pub fn command_receipt(
    operation: &str,
    request_id: &str,
    aggregate_id: Uuid,
    version: Option<i64>,
) -> Result<Value, ServiceError> {
    Ok(serde_json::json!({
        "operationId": operation,
        "requestId": request_id,
        "status": "accepted",
        "aggregateId": aggregate_id,
        "aggregateVersion": version,
        "acceptedAt": timestamp_now()?,
        "links": [],
    }))
}

pub fn mutation_receipt(
    request_id: &str,
    resource_id: Uuid,
    version: i64,
) -> Result<Value, ServiceError> {
    Ok(serde_json::json!({
        "requestId": request_id,
        "status": "accepted",
        "resourceId": resource_id,
        "resourceVersion": version,
        "acceptedAt": timestamp_now()?,
    }))
}

pub fn descriptor(
    token: String,
    kind: &str,
    scope_id: Uuid,
    expires_at: OffsetDateTime,
    version: i64,
) -> Result<Value, ServiceError> {
    Ok(serde_json::json!({
        "opaqueSessionToken":token,
        "sessionKind":kind,
        "scopeId":scope_id,
        "expiresAt":timestamp(expires_at)?,
        "version":version,
    }))
}

pub async fn require_abuse_proof(
    context: &RequestContext<'_>,
    value: &Value,
    expected_action: &str,
) -> Result<(), ServiceError> {
    let proof = value
        .get("abuseProof")
        .filter(|field| field.is_object())
        .ok_or(ServiceError::AbuseProofInvalid)?;
    verify_abuse_proof(context, proof, expected_action, "issuedAt").await
}

/// Validates the closed addendum proof shape. Addendum requests use the
/// `issuedAtEpochSeconds` field; the older submission routes retain
/// `issuedAt`. Keeping the field choice explicit prevents accepting a proof
/// under a different wire contract.
pub async fn require_abuse_proof_v1(
    context: &RequestContext<'_>,
    proof: &Value,
    expected_action: &str,
) -> Result<(), ServiceError> {
    verify_abuse_proof(context, proof, expected_action, "issuedAtEpochSeconds").await
}

async fn verify_abuse_proof(
    context: &RequestContext<'_>,
    proof: &Value,
    expected_action: &str,
    issued_at_field: &str,
) -> Result<(), ServiceError> {
    let provider = string(proof, "provider")?;
    let token = string(proof, "token")?;
    let action = string(proof, "action")?;
    if action != expected_action || token.len() > 4096 {
        return Err(ServiceError::AbuseProofInvalid);
    }
    match provider {
        "SYNTHETIC_TEST" => verify_synthetic(context, proof, token, action, issued_at_field),
        "TURNSTILE" => {
            verify_remote(
                context,
                "https://challenges.cloudflare.com/turnstile/v0/siteverify",
                token,
                action,
                true,
            )
            .await
        }
        "HCAPTCHA" => {
            verify_remote(
                context,
                "https://api.hcaptcha.com/siteverify",
                token,
                action,
                false,
            )
            .await
        }
        _ => Err(ServiceError::AbuseProofInvalid),
    }
}

fn verify_synthetic(
    context: &RequestContext<'_>,
    proof: &Value,
    token: &str,
    action: &str,
    issued_at_field: &str,
) -> Result<(), ServiceError> {
    if context.state.environment == "production" {
        return Err(ServiceError::AbuseProofInvalid);
    }
    let issued_at = proof
        .get(issued_at_field)
        .and_then(Value::as_i64)
        .ok_or(ServiceError::AbuseProofInvalid)?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    if issued_at > now + 5 || now - issued_at > 300 {
        return Err(ServiceError::AbuseProofInvalid);
    }
    if let Some(signature) = decode_hex(token) {
        let mut mac = Hmac::<Sha256>::new_from_slice(context.state.bot_challenge_secret.as_bytes())
            .map_err(|_| ServiceError::Cryptography)?;
        mac.update(format!("{action}:{issued_at}").as_bytes());
        return mac
            .verify_slice(&signature)
            .map_err(|_| ServiceError::AbuseProofInvalid);
    }
    verify_bff_synthetic(context, token, action, issued_at)
}

fn verify_bff_synthetic(
    context: &RequestContext<'_>,
    token: &str,
    action: &str,
    issued_at: i64,
) -> Result<(), ServiceError> {
    let mut parts = token.split('.');
    let (Some(prefix), Some(kid), Some(nonce), Some(encoded_signature), None) = (
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
        parts.next(),
    ) else {
        return Err(ServiceError::AbuseProofInvalid);
    };
    if prefix != "gurine-synth-v1"
        || kid.len() != 16
        || !kid
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        || !(16..=128).contains(&nonce.len())
        || !nonce
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err(ServiceError::AbuseProofInvalid);
    }
    let signature = decode_hex(encoded_signature).ok_or(ServiceError::AbuseProofInvalid)?;
    let keys = match context.issuer {
        "public-web" => &context.state.public_web_keys,
        "response-portal" => &context.state.response_portal_keys,
        _ => return Err(ServiceError::AbuseProofInvalid),
    };
    let message = format!("gurine-synthetic-proof-v1\0{action}\0{issued_at}\0{nonce}");
    keys.verify_hmac_tag(kid, message.as_bytes(), &signature)
        .map_err(|_| ServiceError::AbuseProofInvalid)
}

async fn verify_remote(
    context: &RequestContext<'_>,
    endpoint: &str,
    token: &str,
    action: &str,
    action_required: bool,
) -> Result<(), ServiceError> {
    let target = match context.state.abuse_egress_url.clone() {
        Some(value) => value,
        None => endpoint
            .parse()
            .map_err(|_| ServiceError::AbuseProofUnavailable)?,
    };
    let mut request = context.state.abuse_http.post(target).form(&[
        ("secret", context.state.bot_challenge_secret.as_str()),
        ("response", token),
    ]);
    if context.state.abuse_egress_url.is_some() {
        request = request
            .header("x-gurine-egress-target", endpoint)
            .header("x-gurine-egress-caller", "submission-api");
    }
    let response = request
        .send()
        .await
        .map_err(|_| ServiceError::AbuseProofUnavailable)?;
    if !response.status().is_success() {
        return Err(ServiceError::AbuseProofUnavailable);
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|_| ServiceError::AbuseProofUnavailable)?;
    if bytes.len() > 65_536 {
        return Err(ServiceError::AbuseProofUnavailable);
    }
    let result: Value =
        serde_json::from_slice(&bytes).map_err(|_| ServiceError::AbuseProofUnavailable)?;
    if result.get("success").and_then(Value::as_bool) != Some(true) {
        return Err(ServiceError::AbuseProofInvalid);
    }
    if !provider_action_matches(&result, action, action_required) {
        return Err(ServiceError::AbuseProofInvalid);
    }
    Ok(())
}

fn provider_action_matches(result: &Value, expected: &str, required: bool) -> bool {
    match result.get("action").and_then(Value::as_str) {
        Some(action) => action == expected,
        None => !required,
    }
}

fn decode_hex(value: &str) -> Option<Vec<u8>> {
    if !value.len().is_multiple_of(2) {
        return None;
    }
    value
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let high = hex_nibble(pair[0])?;
            let low = hex_nibble(pair[1])?;
            Some((high << 4) | low)
        })
        .collect()
}

fn hex_nibble(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        _ => None,
    }
}

pub fn database_error(error: sqlx::Error) -> ServiceError {
    let Some(database) = error.as_database_error() else {
        return ServiceError::Persistence;
    };
    match database.code().as_deref() {
        Some("40001" | "23505") => ServiceError::Conflict,
        Some("P0002") => ServiceError::NotFound,
        Some("22023" | "23514") => ServiceError::InvalidRequest,
        Some("28000") => ServiceError::InvalidSession,
        Some("55000") => ServiceError::Closed,
        _ => ServiceError::Persistence,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{provider_action_matches, response_otp, response_otp_verifier};

    #[test]
    fn turnstile_action_is_required_and_request_bound() {
        assert!(provider_action_matches(
            &json!({"action":"createSubscription"}),
            "createSubscription",
            true,
        ));
        assert!(!provider_action_matches(
            &json!({"action":"createContactRequest"}),
            "createSubscription",
            true,
        ));
        assert!(!provider_action_matches(
            &json!({}),
            "createSubscription",
            true,
        ));
    }

    #[test]
    fn adapters_without_action_support_still_reject_a_conflicting_action() {
        assert!(provider_action_matches(
            &json!({}),
            "createSubscription",
            false,
        ));
        assert!(!provider_action_matches(
            &json!({"action":"other"}),
            "createSubscription",
            false,
        ));
    }

    #[test]
    fn response_otp_verifier_is_bound_to_artifact_and_user_code() {
        let key = b"01234567890123456789012345678901";
        let artifact = "a".repeat(64);
        let otp = response_otp(key, &artifact).expect("deterministic test OTP");
        let verifier = response_otp_verifier(key, &otp).expect("verifier");
        assert_eq!(verifier.len(), 64);
        assert_eq!(
            verifier,
            response_otp_verifier(key, &otp).expect("same OTP")
        );
        assert_ne!(
            verifier,
            response_otp_verifier(key, "000000").expect("different OTP")
        );
    }
}
