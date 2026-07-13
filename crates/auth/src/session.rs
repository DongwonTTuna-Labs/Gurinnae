use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    assertion::{AssertionError, canonical::canonical_json},
    envelope::{EnvelopeError, EnvelopeKey, EnvelopeKeyRing, decrypt, encrypt, encrypt_with_nonce},
};

const PREFIX: &str = "gurine-sc-v1";
const COOKIE_NAME: &str = "gurine_internal_session";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InternalSessionCookiePayload {
    #[serde(rename = "absoluteExpiresAt")]
    pub absolute_expires_at: i64,
    #[serde(rename = "csrfRotatedAt")]
    pub csrf_rotated_at: i64,
    #[serde(rename = "csrfToken")]
    pub csrf_token: String,
    #[serde(rename = "issuedAt")]
    pub issued_at: i64,
    #[serde(rename = "opaqueIdentitySessionToken")]
    pub opaque_identity_session_token: String,
    pub typ: String,
    pub v: u8,
}

#[derive(Clone, Copy)]
pub struct CookieContext<'a> {
    pub origin: &'a str,
    pub path: &'a str,
    pub same_site: &'a str,
}

#[derive(Debug, Error)]
pub enum SessionCookieError {
    #[error(transparent)]
    Envelope(#[from] EnvelopeError),
    #[error("session cookie payload is invalid")]
    InvalidPayload,
    #[error("session cookie has expired")]
    Expired,
}

pub fn seal(
    key: &EnvelopeKey,
    context: CookieContext<'_>,
    payload: &InternalSessionCookiePayload,
) -> Result<String, SessionCookieError> {
    validate(payload, payload.issued_at)?;
    let plaintext = canonical_json(payload).map_err(map_canonical_error)?;
    encrypt(PREFIX, key, &aad(context), &plaintext).map_err(Into::into)
}

pub fn seal_with_nonce(
    key: &EnvelopeKey,
    context: CookieContext<'_>,
    payload: &InternalSessionCookiePayload,
    nonce: [u8; 12],
) -> Result<String, SessionCookieError> {
    validate(payload, payload.issued_at)?;
    let plaintext = canonical_json(payload).map_err(map_canonical_error)?;
    encrypt_with_nonce(PREFIX, key, &aad(context), &plaintext, nonce).map_err(Into::into)
}

pub fn open(
    keys: &EnvelopeKeyRing,
    context: CookieContext<'_>,
    token: &str,
    now: i64,
) -> Result<InternalSessionCookiePayload, SessionCookieError> {
    let plaintext = decrypt(PREFIX, keys, &aad(context), token)?;
    let payload: InternalSessionCookiePayload =
        serde_json::from_slice(&plaintext).map_err(|_| SessionCookieError::InvalidPayload)?;
    if canonical_json(&payload).map_err(map_canonical_error)? != plaintext {
        return Err(SessionCookieError::InvalidPayload);
    }
    validate(&payload, now)?;
    Ok(payload)
}

fn aad(context: CookieContext<'_>) -> [&str; 5] {
    [
        PREFIX,
        COOKIE_NAME,
        context.origin,
        context.path,
        context.same_site,
    ]
}

fn validate(payload: &InternalSessionCookiePayload, now: i64) -> Result<(), SessionCookieError> {
    if payload.v != 1
        || payload.typ != "internal-session"
        || payload.csrf_token.len() < 43
        || payload.opaque_identity_session_token.len() < 43
        || payload.issued_at > payload.absolute_expires_at
        || payload.csrf_rotated_at < payload.issued_at
    {
        return Err(SessionCookieError::InvalidPayload);
    }
    if now > payload.absolute_expires_at {
        return Err(SessionCookieError::Expired);
    }
    Ok(())
}

fn map_canonical_error(_error: AssertionError) -> SessionCookieError {
    SessionCookieError::InvalidPayload
}
