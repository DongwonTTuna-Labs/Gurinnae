use super::*;

pub(super) fn pointer_uuid(value: &Value, pointer: &str) -> Result<Uuid, Failure> {
    value.pointer(pointer).and_then(Value::as_str).and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("INVALID_JOB_PAYLOAD", pointer.to_owned()))
}

pub(super) fn payload_uuid(value: &Value, key: &str) -> Result<Uuid, Failure> {
    value.get(key).and_then(Value::as_str).and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("INVALID_JOB_PAYLOAD", key.to_owned()))
}

pub(super) fn json_uuids(value: Value) -> Result<Vec<Uuid>, Failure> {
    value.as_array().ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "array".into()))?.iter()
        .map(|value| value.as_str().and_then(|value| Uuid::parse_str(value).ok())
            .ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "uuid".into())))
        .collect()
}

pub(super) fn database(error: sqlx::Error) -> Failure {
    Failure::Retryable("DATABASE_UNAVAILABLE", error.to_string())
}
