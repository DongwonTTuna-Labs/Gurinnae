use super::*;

pub(super) fn command_parameters(
    request: &HttpRequest,
    payload: &Map<String, Value>,
) -> Map<String, Value> {
    let mut parameters = payload.clone();
    for (name, value) in request.match_info().iter() {
        parameters.insert(name.to_owned(), Value::String(value.to_owned()));
    }
    parameters
}

pub(super) fn query_parameters(request: &HttpRequest) -> BTreeMap<String, String> {
    let mut parameters: BTreeMap<String, String> =
        url::form_urlencoded::parse(request.query_string().as_bytes())
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();
    for (name, value) in request.match_info().iter() {
        parameters.insert(name.to_owned(), value.to_owned());
    }
    parameters
}

pub(super) fn uuid_value(payload: &Map<String, Value>, keys: &[&str]) -> Option<Uuid> {
    keys.iter().find_map(|key| {
        payload
            .get(*key)
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
    })
}

pub(super) fn uuid_array(
    payload: &Map<String, Value>,
    key: &str,
) -> Result<Vec<Uuid>, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_array)
        .ok_or(ServiceError::InvalidRequest)?
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or(ServiceError::InvalidRequest)
        })
        .collect()
}

pub(super) fn string_value<'a>(payload: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    payload.get(key).and_then(Value::as_str)
}

pub(super) fn timestamp_value(
    payload: &Map<String, Value>,
    key: &str,
) -> Result<Option<OffsetDateTime>, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(|value| {
            OffsetDateTime::parse(value, &Rfc3339).map_err(|_| ServiceError::InvalidRequest)
        })
        .transpose()
}

pub(super) fn decimal_string(
    payload: &Map<String, Value>,
    key: &str,
) -> Result<rust_decimal::Decimal, ServiceError> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .ok_or(ServiceError::InvalidRequest)?
        .parse()
        .map_err(|_| ServiceError::InvalidRequest)
}

pub(super) fn date_value(payload: &Map<String, Value>, key: &str) -> Result<Date, ServiceError> {
    let format = time::format_description::parse("[year]-[month]-[day]")
        .map_err(|_| ServiceError::Persistence)?;
    payload
        .get(key)
        .and_then(Value::as_str)
        .ok_or(ServiceError::InvalidRequest)
        .and_then(|value| Date::parse(value, &format).map_err(|_| ServiceError::InvalidRequest))
}

pub(super) fn normalized_email(value: &str) -> Result<String, ServiceError> {
    let email = value.trim().to_ascii_lowercase();
    let Some((local, domain)) = email.split_once('@') else {
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

pub(super) fn encrypt_control_field(
    keys: &EnvelopeKeyRing,
    table: &str,
    column: &str,
    record_id: Uuid,
    logical_type: &str,
    plaintext: &[u8],
) -> Result<Vec<u8>, ServiceError> {
    let record_id = record_id.to_string();
    encrypt(
        "gurine-fe-v1",
        &keys.current,
        &[table, column, &record_id, logical_type, "1"],
        plaintext,
    )
    .map(String::into_bytes)
    .map_err(|_| ServiceError::Persistence)
}

pub(super) fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

pub(super) fn valid_case_transition(current: &str, target: &str) -> bool {
    matches!(
        (current, target),
        ("SIGNAL_DETECTED", "TRIAGE")
            | ("TRIAGE", "INVESTIGATING" | "CLOSED")
            | (
                "INVESTIGATING",
                "AWAITING_RESPONSE" | "EDITORIAL_REVIEW" | "CLOSED"
            )
            | (
                "AWAITING_RESPONSE",
                "INVESTIGATING" | "EDITORIAL_REVIEW" | "CLOSED"
            )
            | (
                "EDITORIAL_REVIEW",
                "INVESTIGATING" | "LEGAL_REVIEW" | "READY_TO_PUBLISH"
            )
            | ("LEGAL_REVIEW", "EDITORIAL_REVIEW" | "READY_TO_PUBLISH")
            | ("READY_TO_PUBLISH", "EDITORIAL_REVIEW" | "CLOSED")
    )
}

pub(super) fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// RFC 8785-compatible JSON bytes for immutable cross-service digests.  The
/// agent snapshot contains only strings, UUIDs, arrays, objects and booleans;
/// rejecting non-integral numbers keeps this implementation lossless and
/// prevents a provider hash from depending on a language's float formatter.
pub(super) fn canonical_json_bytes(value: &Value) -> Result<Vec<u8>, ServiceError> {
    fn write_value(value: &Value, out: &mut String) -> Result<(), ServiceError> {
        match value {
            Value::Null => out.push_str("null"),
            Value::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
            Value::Number(value) => {
                if !value.is_i64() && !value.is_u64() {
                    return Err(ServiceError::InvalidRequest);
                }
                out.push_str(&value.to_string());
            }
            Value::String(value) => {
                let encoded =
                    serde_json::to_string(value).map_err(|_| ServiceError::Persistence)?;
                out.push_str(&encoded);
            }
            Value::Array(values) => {
                out.push('[');
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    write_value(value, out)?;
                }
                out.push(']');
            }
            Value::Object(values) => {
                let mut keys = values.keys().collect::<Vec<_>>();
                keys.sort_by(|left, right| left.encode_utf16().cmp(right.encode_utf16()));
                out.push('{');
                for (index, key) in keys.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    let encoded =
                        serde_json::to_string(key).map_err(|_| ServiceError::Persistence)?;
                    out.push_str(&encoded);
                    out.push(':');
                    write_value(values.get(*key).ok_or(ServiceError::Persistence)?, out)?;
                }
                out.push('}');
            }
        }
        Ok(())
    }

    let mut out = String::new();
    write_value(value, &mut out)?;
    Ok(out.into_bytes())
}

pub(super) fn canonical_json_digest(value: &Value) -> Result<String, ServiceError> {
    Ok(sha256(&canonical_json_bytes(value)?))
}

pub(super) fn mapping_digest_matches(value: &Value, expected: &str) -> Result<bool, ServiceError> {
    let canonical = serde_json::to_vec(value).map_err(|_| ServiceError::InvalidRequest)?;
    Ok(sha256(&canonical) == expected)
}

pub(super) fn format_time(value: OffsetDateTime) -> Result<String, ServiceError> {
    value
        .format(&Rfc3339)
        .map_err(|_| ServiceError::Persistence)
}

pub(super) fn db(error: sqlx::Error) -> ServiceError {
    tracing::error!(error = %error, "control persistence operation failed");
    ServiceError::Persistence
}
