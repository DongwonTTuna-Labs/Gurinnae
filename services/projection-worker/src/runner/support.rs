use serde_json::Value;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::Failure;

pub(super) fn parse_uuid(value: &Value, pointer: &str) -> Result<Uuid, Failure> {
    value
        .pointer(pointer)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| {
            Failure::Terminal(
                "INVALID_EVENT_PAYLOAD",
                format!("{pointer} is missing or invalid"),
            )
        })
}

pub(super) fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub(super) fn database(_error: sqlx::Error) -> Failure {
    Failure::Retryable(
        "DATABASE_UNAVAILABLE",
        "projection database operation failed".to_owned(),
    )
}
