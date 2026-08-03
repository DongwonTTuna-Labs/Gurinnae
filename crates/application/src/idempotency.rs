use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IdempotencyRequest {
    pub scope: String,
    pub key_hash: String,
    pub request_hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum IdempotencyDecision<T> {
    Execute(IdempotencyRequest),
    Replay(T),
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum IdempotencyError {
    #[error("idempotency key is missing or invalid")]
    InvalidKey,
    #[error("idempotency key was reused with different request bytes")]
    RequestConflict,
}

pub fn request(
    scope: &str,
    key: &str,
    request_bytes: &[u8],
) -> Result<IdempotencyRequest, IdempotencyError> {
    if scope.is_empty() || !(8..=200).contains(&key.len()) || !key.is_ascii() {
        return Err(IdempotencyError::InvalidKey);
    }
    Ok(IdempotencyRequest {
        scope: scope.to_owned(),
        key_hash: sha256(key.as_bytes()),
        request_hash: sha256(request_bytes),
    })
}

pub fn compare_request(expected_hash: &str, request_bytes: &[u8]) -> Result<(), IdempotencyError> {
    if sha256(request_bytes) != expected_hash {
        return Err(IdempotencyError::RequestConflict);
    }
    Ok(())
}

fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
