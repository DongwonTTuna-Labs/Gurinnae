fn retention_positive_integer(
    object: &serde_json::Map<String, Value>,
    field: &str,
    code: &'static str,
) -> Result<i64, Failure> {
    object
        .get(field)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| retention_contract_failure(code, field))
}

fn retention_nonnegative_integer(
    object: &serde_json::Map<String, Value>,
    field: &str,
    code: &'static str,
) -> Result<i64, Failure> {
    object
        .get(field)
        .and_then(Value::as_i64)
        .filter(|value| *value >= 0)
        .ok_or_else(|| retention_contract_failure(code, field))
}

fn retention_datetime(
    object: &serde_json::Map<String, Value>,
    field: &str,
    code: &'static str,
) -> Result<time::OffsetDateTime, Failure> {
    time::OffsetDateTime::parse(
        retention_string(object, field, code)?,
        &time::format_description::well_known::Rfc3339,
    )
    .map_err(|_| retention_contract_failure(code, field))
}

fn retention_boolean(
    object: &serde_json::Map<String, Value>,
    field: &str,
    code: &'static str,
) -> Result<bool, Failure> {
    object
        .get(field)
        .and_then(Value::as_bool)
        .ok_or_else(|| retention_contract_failure(code, field))
}

fn retention_json_digest(
    value: &Value,
    code: &'static str,
    field: &str,
) -> Result<String, Failure> {
    gurine_auth::assertion::canonical::canonical_json(value)
        .map(|canonical| sha256(&canonical))
        .map_err(|_| retention_contract_failure(code, field))
}

fn require_retention_binding(matches: bool, field: &str) -> Result<(), Failure> {
    if !matches {
        return Err(Failure::Terminal(
            "R6D_PERSON_RETENTION_BINDING_MISMATCH",
            field.to_owned(),
        ));
    }
    Ok(())
}

fn retention_contract_failure(code: &'static str, field: &str) -> Failure {
    Failure::Terminal(code, field.to_owned())
}

fn retention_owner_database_failure(error: sqlx::Error) -> Failure {
    let sqlstate = match &error {
        sqlx::Error::Database(database) => database.code().map(|value| value.into_owned()),
        _ => None,
    };
    match sqlstate.as_deref() {
        Some("22023") => Failure::Terminal(
            "R6D_PERSON_RETENTION_OWNER_REJECTED",
            "redacted:sqlstate=22023".to_owned(),
        ),
        Some("40001") => Failure::Retryable(
            "R6D_PERSON_RETENTION_OWNER_CONFLICT",
            "redacted:sqlstate=40001".to_owned(),
        ),
        Some("55000") => Failure::Retryable(
            "R6D_PERSON_RETENTION_OWNER_NOT_READY",
            "redacted:sqlstate=55000".to_owned(),
        ),
        _ => Failure::Retryable(
            "R6D_PERSON_RETENTION_OWNER_UNAVAILABLE",
            "redacted:database_error".to_owned(),
        ),
    }
}
