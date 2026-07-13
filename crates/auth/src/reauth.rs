use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};
use subtle::ConstantTimeEq;
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroize;

use crate::{
    assertion::canonical::{canonical_json, sha256_hex},
    envelope::{EnvelopeError, EnvelopeKey, EnvelopeKeyRing, decrypt, encrypt},
};

const TRANSACTION_PREFIX: &str = "gurine-st-v1";
const AUTHORIZATION_PREFIX: &str = "gurine-su-v1";
const TRANSACTION_COOKIE: &str = "gurine_step_up_transaction";
const AUTHORIZATION_COOKIE: &str = "gurine_step_up_authorization";
const MAX_ASSERTION_ISSUES: u8 = 3;
const AUTHORIZATION_TTL_SECONDS: i64 = 300;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct StepUpTransactionPayload {
    pub action_digest: String,
    pub expires_at: i64,
    pub idempotency_key: String,
    pub issued_at: i64,
    pub transaction_cookie_value: String,
    pub typ: String,
    pub v: u8,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct StepUpAuthorizationPayload {
    pub action_digest: String,
    pub authorization_id: Uuid,
    pub authorization_token: String,
    pub expires_at: i64,
    pub idempotency_key: String,
    pub idempotency_key_sha256: String,
    pub issued_at: i64,
    pub max_assertion_issues: u8,
    pub typ: String,
    pub v: u8,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StepUpAuthorization {
    pub id: Uuid,
    pub session_id: Uuid,
    pub action_digest: String,
    pub idempotency_key_sha256: String,
    pub authorization_token_hash: String,
    pub expires_at: i64,
    pub assertion_issue_count: u8,
    pub closed: bool,
}

pub struct IssuedStepUpAuthorization {
    pub record: StepUpAuthorization,
    pub authorization_token: SecretToken,
}

pub struct SecretToken(String);

impl SecretToken {
    pub fn expose_for_cookie_sealing(&self) -> &str {
        &self.0
    }

    pub fn sha256(&self) -> String {
        sha256_hex(self.0.as_bytes())
    }
}

impl Drop for SecretToken {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum StepUpError {
    #[error("step-up payload is invalid")]
    InvalidPayload,
    #[error("step-up authorization is expired, closed, exhausted, or incorrectly bound")]
    InvalidOrExhausted,
    #[error("operating system randomness is unavailable")]
    RandomnessUnavailable,
    #[error("step-up envelope is invalid")]
    InvalidEnvelope,
}

impl StepUpAuthorization {
    pub fn issue(
        session_id: Uuid,
        action_digest: String,
        idempotency_key_sha256: String,
        now: i64,
    ) -> Result<IssuedStepUpAuthorization, StepUpError> {
        if !is_hash(&action_digest) || !is_hash(&idempotency_key_sha256) {
            return Err(StepUpError::InvalidPayload);
        }
        let authorization_token = random_secret(32)?;
        let record = Self {
            id: Uuid::new_v4(),
            session_id,
            action_digest,
            idempotency_key_sha256,
            authorization_token_hash: authorization_token.sha256(),
            expires_at: now + AUTHORIZATION_TTL_SECONDS,
            assertion_issue_count: 0,
            closed: false,
        };
        Ok(IssuedStepUpAuthorization {
            record,
            authorization_token,
        })
    }

    pub fn claim(
        &mut self,
        authorization_token: &str,
        session_id: Uuid,
        action_digest: &str,
        idempotency_key_sha256: &str,
        now: i64,
    ) -> Result<u8, StepUpError> {
        let token_hash = sha256_hex(authorization_token.as_bytes());
        if self.closed
            || now >= self.expires_at
            || self.assertion_issue_count >= MAX_ASSERTION_ISSUES
            || self.session_id != session_id
            || !constant_time_equal(&token_hash, &self.authorization_token_hash)
            || !constant_time_equal(action_digest, &self.action_digest)
            || !constant_time_equal(idempotency_key_sha256, &self.idempotency_key_sha256)
        {
            return Err(StepUpError::InvalidOrExhausted);
        }
        self.assertion_issue_count += 1;
        Ok(self.assertion_issue_count)
    }

    pub fn close(
        &mut self,
        authorization_token: &str,
        session_id: Uuid,
        action_digest: &str,
        idempotency_key_sha256: &str,
    ) -> Result<(), StepUpError> {
        let token_hash = sha256_hex(authorization_token.as_bytes());
        if self.session_id != session_id
            || !constant_time_equal(&token_hash, &self.authorization_token_hash)
            || !constant_time_equal(action_digest, &self.action_digest)
            || !constant_time_equal(idempotency_key_sha256, &self.idempotency_key_sha256)
        {
            return Err(StepUpError::InvalidOrExhausted);
        }
        self.closed = true;
        Ok(())
    }
}

pub fn generate_idempotency_key() -> Result<SecretToken, StepUpError> {
    random_secret(32)
}

pub fn seal_transaction(
    key: &EnvelopeKey,
    origin: &str,
    payload: &StepUpTransactionPayload,
) -> Result<String, StepUpError> {
    validate_transaction(payload, payload.issued_at)?;
    seal(
        TRANSACTION_PREFIX,
        key,
        &[
            TRANSACTION_PREFIX,
            TRANSACTION_COOKIE,
            origin,
            "/auth/step-up/callback",
            "Lax",
        ],
        payload,
    )
}

pub fn open_transaction(
    keys: &EnvelopeKeyRing,
    origin: &str,
    token: &str,
    now: i64,
) -> Result<StepUpTransactionPayload, StepUpError> {
    let payload = open(
        TRANSACTION_PREFIX,
        keys,
        &[
            TRANSACTION_PREFIX,
            TRANSACTION_COOKIE,
            origin,
            "/auth/step-up/callback",
            "Lax",
        ],
        token,
    )?;
    validate_transaction(&payload, now)?;
    Ok(payload)
}

pub fn seal_authorization(
    key: &EnvelopeKey,
    origin: &str,
    payload: &StepUpAuthorizationPayload,
) -> Result<String, StepUpError> {
    validate_authorization(payload, payload.issued_at)?;
    seal(
        AUTHORIZATION_PREFIX,
        key,
        &[
            AUTHORIZATION_PREFIX,
            AUTHORIZATION_COOKIE,
            origin,
            "/internal",
            "Strict",
        ],
        payload,
    )
}

pub fn open_authorization(
    keys: &EnvelopeKeyRing,
    origin: &str,
    token: &str,
    now: i64,
) -> Result<StepUpAuthorizationPayload, StepUpError> {
    let payload = open(
        AUTHORIZATION_PREFIX,
        keys,
        &[
            AUTHORIZATION_PREFIX,
            AUTHORIZATION_COOKIE,
            origin,
            "/internal",
            "Strict",
        ],
        token,
    )?;
    validate_authorization(&payload, now)?;
    Ok(payload)
}

fn seal<T: Serialize>(
    prefix: &str,
    key: &EnvelopeKey,
    aad: &[&str],
    payload: &T,
) -> Result<String, StepUpError> {
    let plaintext = canonical_json(payload).map_err(|_| StepUpError::InvalidPayload)?;
    encrypt(prefix, key, aad, &plaintext).map_err(map_envelope)
}

fn open<T: for<'de> Deserialize<'de> + Serialize>(
    prefix: &str,
    keys: &EnvelopeKeyRing,
    aad: &[&str],
    token: &str,
) -> Result<T, StepUpError> {
    let plaintext = decrypt(prefix, keys, aad, token).map_err(map_envelope)?;
    let payload = serde_json::from_slice(&plaintext).map_err(|_| StepUpError::InvalidPayload)?;
    if canonical_json(&payload).map_err(|_| StepUpError::InvalidPayload)? != plaintext {
        return Err(StepUpError::InvalidPayload);
    }
    Ok(payload)
}

fn validate_transaction(payload: &StepUpTransactionPayload, now: i64) -> Result<(), StepUpError> {
    if payload.v != 1
        || payload.typ != "step-up-transaction"
        || payload.transaction_cookie_value.len() < 43
        || !(16..=200).contains(&payload.idempotency_key.len())
        || !is_hash(&payload.action_digest)
        || payload.expires_at <= payload.issued_at
        || payload.expires_at - payload.issued_at > 600
        || now >= payload.expires_at
    {
        return Err(StepUpError::InvalidPayload);
    }
    Ok(())
}

fn validate_authorization(
    payload: &StepUpAuthorizationPayload,
    now: i64,
) -> Result<(), StepUpError> {
    if payload.v != 1
        || payload.typ != "step-up-authorization"
        || payload.authorization_token.len() < 43
        || !(16..=200).contains(&payload.idempotency_key.len())
        || !is_hash(&payload.action_digest)
        || !is_hash(&payload.idempotency_key_sha256)
        || payload.max_assertion_issues != MAX_ASSERTION_ISSUES
        || payload.expires_at <= payload.issued_at
        || payload.expires_at - payload.issued_at > AUTHORIZATION_TTL_SECONDS
        || now >= payload.expires_at
        || sha256_hex(payload.idempotency_key.as_bytes()) != payload.idempotency_key_sha256
    {
        return Err(StepUpError::InvalidPayload);
    }
    Ok(())
}

fn random_secret(bytes: usize) -> Result<SecretToken, StepUpError> {
    let mut value = vec![0_u8; bytes];
    getrandom::fill(&mut value).map_err(|_| StepUpError::RandomnessUnavailable)?;
    let token = URL_SAFE_NO_PAD.encode(&value);
    value.zeroize();
    Ok(SecretToken(token))
}

fn constant_time_equal(left: &str, right: &str) -> bool {
    left.len() == right.len() && bool::from(left.as_bytes().ct_eq(right.as_bytes()))
}

fn is_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn map_envelope(_error: EnvelopeError) -> StepUpError {
    StepUpError::InvalidEnvelope
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn authorization_allows_exactly_three_bound_claims() -> Result<(), StepUpError> {
        let session = Uuid::new_v4();
        let issued = StepUpAuthorization::issue(session, "a".repeat(64), "b".repeat(64), 100)?;
        let token = issued
            .authorization_token
            .expose_for_cookie_sealing()
            .to_owned();
        let mut record = issued.record;
        for expected in 1..=3 {
            assert_eq!(
                record.claim(&token, session, &"a".repeat(64), &"b".repeat(64), 101)?,
                expected
            );
        }
        assert_eq!(
            record.claim(&token, session, &"a".repeat(64), &"b".repeat(64), 101),
            Err(StepUpError::InvalidOrExhausted)
        );
        Ok(())
    }
}
