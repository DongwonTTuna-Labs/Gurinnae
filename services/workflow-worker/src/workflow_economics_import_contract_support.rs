fn economics_exact_object<'a>(
    value: &'a Value,
    keys: &[&str],
    error: fn(&'static str) -> EconomicsContractError,
) -> Result<&'a serde_json::Map<String, Value>, EconomicsContractError> {
    let object = value.as_object().ok_or(error("object"))?;
    if object.len() != keys.len() || keys.iter().any(|key| !object.contains_key(*key)) {
        return Err(error("keys"));
    }
    Ok(object)
}

fn economics_string<'a>(
    object: &'a serde_json::Map<String, Value>,
    key: &'static str,
    error: fn(&'static str) -> EconomicsContractError,
) -> Result<&'a str, EconomicsContractError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && value.trim() == *value)
        .ok_or(error(key))
}

fn economics_literal(
    object: &serde_json::Map<String, Value>,
    key: &'static str,
    expected: &str,
    error: fn(&'static str) -> EconomicsContractError,
) -> Result<(), EconomicsContractError> {
    if object.get(key).and_then(Value::as_str) == Some(expected) {
        Ok(())
    } else {
        Err(error(key))
    }
}

fn economics_uuid(
    object: &serde_json::Map<String, Value>,
    key: &'static str,
    error: fn(&'static str) -> EconomicsContractError,
) -> Result<Uuid, EconomicsContractError> {
    economics_string(object, key, error)
        .and_then(|value| Uuid::parse_str(value).map_err(|_| error(key)))
        .and_then(|value| {
            if value.is_nil() {
                Err(error(key))
            } else {
                Ok(value)
            }
        })
}

fn economics_optional_uuid(
    object: &serde_json::Map<String, Value>,
    key: &'static str,
    error: fn(&'static str) -> EconomicsContractError,
) -> Result<Option<Uuid>, EconomicsContractError> {
    match object.get(key) {
        Some(Value::Null) => Ok(None),
        Some(_) => economics_uuid(object, key, error).map(Some),
        None => Err(error(key)),
    }
}

fn economics_positive(
    object: &serde_json::Map<String, Value>,
    key: &'static str,
    error: fn(&'static str) -> EconomicsContractError,
) -> Result<i64, EconomicsContractError> {
    object
        .get(key)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or(error(key))
}

fn economics_digest<'a>(
    object: &'a serde_json::Map<String, Value>,
    key: &'static str,
    error: fn(&'static str) -> EconomicsContractError,
) -> Result<&'a str, EconomicsContractError> {
    economics_string(object, key, error).and_then(|value| {
        if is_sha256(value) {
            Ok(value)
        } else {
            Err(error(key))
        }
    })
}

fn economics_optional_digest<'a>(
    object: &'a serde_json::Map<String, Value>,
    key: &'static str,
    error: fn(&'static str) -> EconomicsContractError,
) -> Result<Option<&'a str>, EconomicsContractError> {
    match object.get(key) {
        Some(Value::Null) => Ok(None),
        Some(_) => economics_digest(object, key, error).map(Some),
        None => Err(error(key)),
    }
}

fn economics_optional_string<'a>(
    object: &'a serde_json::Map<String, Value>,
    key: &'static str,
    error: fn(&'static str) -> EconomicsContractError,
) -> Result<Option<&'a str>, EconomicsContractError> {
    match object.get(key) {
        Some(Value::Null) => Ok(None),
        Some(_) => economics_string(object, key, error).map(Some),
        None => Err(error(key)),
    }
}

fn economics_datetime(
    object: &serde_json::Map<String, Value>,
    key: &'static str,
    error: fn(&'static str) -> EconomicsContractError,
) -> Result<time::OffsetDateTime, EconomicsContractError> {
    time::OffsetDateTime::parse(
        economics_string(object, key, error)?,
        &time::format_description::well_known::Rfc3339,
    )
    .map_err(|_| error(key))
}

fn economics_operation(
    object: &serde_json::Map<String, Value>,
    error: fn(&'static str) -> EconomicsContractError,
) -> Result<EconomicsOperation, EconomicsContractError> {
    economics_string(object, "operationId", error)
        .and_then(|value| EconomicsOperation::parse(value).ok_or(error("operationId")))
}
