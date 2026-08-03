use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use zeroize::Zeroize;

use super::{
    canonical::{BoundRequest, canonical_json, key_id, parse_token, request_hashes},
    errors::AssertionError,
    replay::ReplayGuard,
};

const PREFIX: &str = "gurine-sa-v1";
const MAX_TTL_SECONDS: i64 = 30;
const CLOCK_SKEW_SECONDS: i64 = 5;

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceClaims {
    pub aud: String,
    #[serde(rename = "bodySha256")]
    pub body_sha256: String,
    #[serde(rename = "contentType")]
    pub content_type: String,
    pub exp: i64,
    pub iat: i64,
    pub iss: String,
    pub jti: String,
    pub method: String,
    pub path: String,
    #[serde(rename = "querySha256")]
    pub query_sha256: String,
    pub typ: String,
    pub v: u8,
}

pub struct AssertionKey {
    bytes: Vec<u8>,
    kid: String,
}

impl AssertionKey {
    pub fn new(bytes: [u8; 32]) -> Self {
        let kid = key_id(&bytes);
        Self {
            bytes: bytes.to_vec(),
            kid,
        }
    }

    pub fn from_bytes(bytes: Vec<u8>) -> Result<Self, AssertionError> {
        if bytes.len() < 32 {
            return Err(AssertionError::SchemaInvalid);
        }
        let kid = key_id(&bytes);
        Ok(Self { bytes, kid })
    }

    pub(super) fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn id(&self) -> &str {
        &self.kid
    }
}

impl Drop for AssertionKey {
    fn drop(&mut self) {
        self.bytes.zeroize();
    }
}

pub struct KeyRing {
    pub current: AssertionKey,
    pub previous: Option<AssertionKey>,
}

#[derive(Clone, Copy)]
pub struct ServiceExpectation<'a> {
    pub issuer: &'a str,
    pub audience: &'a str,
    pub now: i64,
}

pub struct ServiceVerification<'a> {
    pub expectation: ServiceExpectation<'a>,
    pub replay_guard: &'a dyn ReplayGuard,
}

impl KeyRing {
    pub(super) fn by_id(&self, kid: &str) -> Result<&AssertionKey, AssertionError> {
        if self.current.kid == kid {
            return Ok(&self.current);
        }
        self.previous
            .as_ref()
            .filter(|key| key.kid == kid)
            .ok_or(AssertionError::UnknownKey)
    }

    pub fn verify_hmac_tag(
        &self,
        kid: &str,
        message: &[u8],
        tag: &[u8],
    ) -> Result<(), AssertionError> {
        let key = self.by_id(kid)?;
        let mut mac = Hmac::<Sha256>::new_from_slice(&key.bytes)
            .map_err(|_| AssertionError::SignatureInvalid)?;
        mac.update(message);
        mac.verify_slice(tag)
            .map_err(|_| AssertionError::SignatureInvalid)
    }
}

pub fn sign(claims: &ServiceClaims, key: &AssertionKey) -> Result<String, AssertionError> {
    validate_schema(claims)?;
    let payload_segment = URL_SAFE_NO_PAD.encode(canonical_json(claims)?);
    let signing_input = format!("{PREFIX}.{}.{payload_segment}", key.kid);
    let mut mac =
        Hmac::<Sha256>::new_from_slice(&key.bytes).map_err(|_| AssertionError::SignatureInvalid)?;
    mac.update(signing_input.as_bytes());
    let signature = URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
    Ok(format!("{signing_input}.{signature}"))
}

pub fn verify(
    token: &str,
    keys: &KeyRing,
    request: &BoundRequest<'_>,
    verification: ServiceVerification<'_>,
) -> Result<ServiceClaims, AssertionError> {
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
    expectation: ServiceExpectation<'_>,
) -> Result<ServiceClaims, AssertionError> {
    let segments = parse_token(token, PREFIX)?;
    let key = keys.by_id(segments.kid)?;
    let signing_input = format!(
        "{PREFIX}.{}.{payload}",
        segments.kid,
        payload = segments.payload_segment
    );
    let mut mac =
        Hmac::<Sha256>::new_from_slice(&key.bytes).map_err(|_| AssertionError::SignatureInvalid)?;
    mac.update(signing_input.as_bytes());
    mac.verify_slice(&segments.signature)
        .map_err(|_| AssertionError::SignatureInvalid)?;
    let value = super::canonical::validate_canonical_payload(&segments.payload_bytes)?;
    let claims: ServiceClaims =
        serde_json::from_value(value).map_err(|_| AssertionError::SchemaInvalid)?;
    validate_schema(&claims)?;
    validate_time(claims.iat, claims.exp, expectation.now)?;
    if claims.iss != expectation.issuer || claims.aud != expectation.audience {
        return Err(AssertionError::AudienceMismatch);
    }
    let hashes = request_hashes(request)?;
    if claims.method != hashes.method
        || claims.path != hashes.path
        || claims.query_sha256 != hashes.query_sha256
        || claims.body_sha256 != hashes.body_sha256
        || claims.content_type != hashes.content_type
    {
        return Err(AssertionError::RequestMismatch);
    }
    Ok(claims)
}

fn validate_schema(claims: &ServiceClaims) -> Result<(), AssertionError> {
    if claims.v != 1
        || claims.typ != "service"
        || claims.jti.len() != 36
        || !is_hash(&claims.query_sha256)
        || !is_hash(&claims.body_sha256)
    {
        return Err(AssertionError::SchemaInvalid);
    }
    Ok(())
}

fn validate_time(iat: i64, exp: i64, now: i64) -> Result<(), AssertionError> {
    if iat > now + CLOCK_SKEW_SECONDS {
        return Err(AssertionError::IssuedInFuture);
    }
    if exp < now - CLOCK_SKEW_SECONDS {
        return Err(AssertionError::Expired);
    }
    if exp <= iat || exp - iat > MAX_TTL_SECONDS {
        return Err(AssertionError::SchemaInvalid);
    }
    Ok(())
}

pub(super) fn is_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
