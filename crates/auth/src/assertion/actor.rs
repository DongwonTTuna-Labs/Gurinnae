use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use super::{
    canonical::{BoundRequest, canonical_json, parse_token, request_hashes, sha256_hex},
    errors::AssertionError,
    replay::ReplayGuard,
    service::{AssertionKey, KeyRing, is_hash},
};

const PREFIX: &str = "gurine-aa-v1";
const MAX_TTL_SECONDS: i64 = 20;
const CLOCK_SKEW_SECONDS: i64 = 5;

#[derive(Clone, Copy)]
pub struct ActorExpectation<'a> {
    pub operation: &'a str,
    pub capability: &'a str,
    pub assurance: &'a str,
    pub now: i64,
}

pub struct ActorVerification<'a> {
    pub expectation: ActorExpectation<'a>,
    pub replay_guard: &'a dyn ReplayGuard,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ActorClaims {
    #[serde(rename = "actionDigest")]
    pub action_digest: Option<String>,
    #[serde(rename = "assuranceLevel")]
    pub assurance_level: String,
    pub aud: String,
    #[serde(rename = "authTime")]
    pub auth_time: i64,
    #[serde(rename = "bodySha256")]
    pub body_sha256: String,
    pub capabilities: Vec<String>,
    #[serde(rename = "capabilityHash")]
    pub capability_hash: String,
    #[serde(rename = "contentType")]
    pub content_type: String,
    pub exp: i64,
    pub iat: i64,
    #[serde(rename = "idempotencyKeySha256")]
    pub idempotency_key_sha256: Option<String>,
    pub iss: String,
    pub jti: String,
    pub method: String,
    #[serde(rename = "operationId")]
    pub operation_id: String,
    pub path: String,
    #[serde(rename = "querySha256")]
    pub query_sha256: String,
    #[serde(rename = "requiredCapability")]
    pub required_capability: String,
    #[serde(rename = "rolesVersion")]
    pub roles_version: i64,
    pub sid: String,
    #[serde(rename = "stepUpAt")]
    pub step_up_at: Option<i64>,
    #[serde(rename = "stepUpAuthorizationId")]
    pub step_up_authorization_id: Option<String>,
    pub sub: String,
    pub typ: String,
    pub v: u8,
}

pub fn sign(claims: &ActorClaims, key: &AssertionKey) -> Result<String, AssertionError> {
    validate_schema(claims)?;
    let payload_segment = URL_SAFE_NO_PAD.encode(canonical_json(claims)?);
    let signing_input = format!("{PREFIX}.{}.{payload_segment}", key.id());
    let mut mac = Hmac::<Sha256>::new_from_slice(key.bytes())
        .map_err(|_| AssertionError::SignatureInvalid)?;
    mac.update(signing_input.as_bytes());
    let signature = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
    Ok(format!("{signing_input}.{signature}"))
}

pub fn verify(
    token: &str,
    keys: &KeyRing,
    request: &BoundRequest<'_>,
    verification: ActorVerification<'_>,
) -> Result<ActorClaims, AssertionError> {
    let claims = verify_claims(token, keys, request, verification.expectation)?;
    verification
        .replay_guard
        .consume(&claims.iss, &claims.jti, claims.exp)?;
    Ok(claims)
}

pub fn verify_claims(
    token: &str,
    keys: &KeyRing,
    request: &BoundRequest<'_>,
    expectation: ActorExpectation<'_>,
) -> Result<ActorClaims, AssertionError> {
    let segments = parse_token(token, PREFIX)?;
    let key = keys.by_id(segments.kid)?;
    let signing_input = format!(
        "{PREFIX}.{}.{payload}",
        segments.kid,
        payload = segments.payload_segment
    );
    let mut mac = Hmac::<Sha256>::new_from_slice(key.bytes())
        .map_err(|_| AssertionError::SignatureInvalid)?;
    mac.update(signing_input.as_bytes());
    mac.verify_slice(&segments.signature)
        .map_err(|_| AssertionError::SignatureInvalid)?;
    let value = super::canonical::validate_canonical_payload(&segments.payload_bytes)?;
    let claims: ActorClaims =
        serde_json::from_value(value).map_err(|_| AssertionError::SchemaInvalid)?;
    validate_schema(&claims)?;
    validate_time(&claims, expectation.now)?;
    if claims.iss != "identity-api" || claims.aud != "control-api" {
        return Err(AssertionError::AudienceMismatch);
    }
    let hashes = request_hashes(request)?;
    if claims.method != hashes.method
        || claims.path != hashes.path
        || claims.query_sha256 != hashes.query_sha256
        || claims.body_sha256 != hashes.body_sha256
        || claims.content_type != hashes.content_type
        || claims.idempotency_key_sha256 != hashes.idempotency_key_sha256
        || claims.operation_id != expectation.operation
        || claims.required_capability != expectation.capability
        || claims.assurance_level != expectation.assurance
    {
        return Err(AssertionError::RequestMismatch);
    }
    if !claims
        .capabilities
        .iter()
        .any(|value| value == expectation.capability)
    {
        return Err(AssertionError::CapabilityDenied);
    }
    Ok(claims)
}

fn validate_schema(claims: &ActorClaims) -> Result<(), AssertionError> {
    let mut capabilities = claims.capabilities.clone();
    capabilities.sort_unstable();
    capabilities.dedup();
    let capability_hash = sha256_hex(capabilities.join("\n").as_bytes());
    if claims.v != 1
        || claims.typ != "actor"
        || capabilities != claims.capabilities
        || capability_hash != claims.capability_hash
        || !is_hash(&claims.query_sha256)
        || !is_hash(&claims.body_sha256)
        || !is_hash(&claims.capability_hash)
    {
        return Err(AssertionError::SchemaInvalid);
    }
    let step_up_fields_present = claims.action_digest.is_some()
        && claims.step_up_authorization_id.is_some()
        && claims.idempotency_key_sha256.is_some();
    if (claims.assurance_level == "STEP_UP") != step_up_fields_present {
        return Err(AssertionError::SchemaInvalid);
    }
    Ok(())
}

fn validate_time(claims: &ActorClaims, now: i64) -> Result<(), AssertionError> {
    if claims.iat > now + CLOCK_SKEW_SECONDS {
        return Err(AssertionError::IssuedInFuture);
    }
    if claims.exp < now - CLOCK_SKEW_SECONDS {
        return Err(AssertionError::Expired);
    }
    if claims.exp <= claims.iat || claims.exp - claims.iat > MAX_TTL_SECONDS {
        return Err(AssertionError::SchemaInvalid);
    }
    Ok(())
}

pub fn action_digest(canonical_context: &[u8]) -> String {
    sha256_hex(canonical_context)
}
