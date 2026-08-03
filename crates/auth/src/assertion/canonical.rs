use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::errors::AssertionError;

#[derive(Clone, Copy)]
pub struct BoundRequest<'a> {
    pub method: &'a str,
    pub path: &'a str,
    pub raw_query: &'a str,
    pub body: &'a [u8],
    pub content_type: Option<&'a str>,
    pub idempotency_key: Option<&'a str>,
    /// Opaque continuation secret carried only long enough to bind its digest.
    ///
    /// `Debug` is intentionally not implemented for `BoundRequest`, so a raw
    /// submission-session token cannot be emitted by ordinary diagnostics.
    pub next_submission_session: Option<&'a str>,
}

#[derive(Debug)]
pub struct TokenSegments<'a> {
    pub kid: &'a str,
    pub payload_segment: &'a str,
    pub payload_bytes: Vec<u8>,
    pub signature: Vec<u8>,
}

pub fn parse_token<'a>(token: &'a str, prefix: &str) -> Result<TokenSegments<'a>, AssertionError> {
    let mut segments = token.split('.');
    let token_prefix = segments.next().ok_or(AssertionError::FormatInvalid)?;
    let kid = segments.next().ok_or(AssertionError::FormatInvalid)?;
    let payload_segment = segments.next().ok_or(AssertionError::FormatInvalid)?;
    let signature_segment = segments.next().ok_or(AssertionError::FormatInvalid)?;
    if segments.next().is_some()
        || token_prefix != prefix
        || kid.len() != 16
        || !kid
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        || payload_segment.contains('=')
        || signature_segment.contains('=')
    {
        return Err(AssertionError::FormatInvalid);
    }
    let payload_bytes = URL_SAFE_NO_PAD
        .decode(payload_segment)
        .map_err(|_| AssertionError::FormatInvalid)?;
    let signature = URL_SAFE_NO_PAD
        .decode(signature_segment)
        .map_err(|_| AssertionError::FormatInvalid)?;
    if signature.len() != 32 || !payload_bytes.is_ascii() {
        return Err(AssertionError::FormatInvalid);
    }
    Ok(TokenSegments {
        kid,
        payload_segment,
        payload_bytes,
        signature,
    })
}

pub fn canonical_json<T: Serialize>(value: &T) -> Result<Vec<u8>, AssertionError> {
    let json = serde_json::to_value(value).map_err(|_| AssertionError::SchemaInvalid)?;
    let mut output = String::new();
    write_jcs(&json, &mut output)?;
    Ok(output.into_bytes())
}

fn write_jcs(value: &Value, output: &mut String) -> Result<(), AssertionError> {
    match value {
        Value::Null => output.push_str("null"),
        Value::Bool(value) => output.push_str(if *value { "true" } else { "false" }),
        Value::String(value) => output
            .push_str(&serde_json::to_string(value).map_err(|_| AssertionError::SchemaInvalid)?),
        Value::Number(value) if value.is_i64() || value.is_u64() => {
            output.push_str(&value.to_string())
        }
        Value::Number(_) => return Err(AssertionError::SchemaInvalid),
        Value::Array(values) => {
            output.push('[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    output.push(',');
                }
                write_jcs(value, output)?;
            }
            output.push(']');
        }
        Value::Object(values) => {
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort_by(|left, right| left.encode_utf16().cmp(right.encode_utf16()));
            output.push('{');
            for (index, key) in keys.iter().enumerate() {
                if index > 0 {
                    output.push(',');
                }
                output.push_str(
                    &serde_json::to_string(key).map_err(|_| AssertionError::SchemaInvalid)?,
                );
                output.push(':');
                write_jcs(
                    values.get(*key).ok_or(AssertionError::SchemaInvalid)?,
                    output,
                )?;
            }
            output.push('}');
        }
    }
    Ok(())
}

pub fn validate_canonical_payload(bytes: &[u8]) -> Result<Value, AssertionError> {
    if !bytes.is_ascii() {
        return Err(AssertionError::NoncanonicalPayload);
    }
    let value: Value = serde_json::from_slice(bytes).map_err(|_| AssertionError::SchemaInvalid)?;
    validate_json_shape(&value)?;
    if canonical_json(&value)? != bytes {
        return Err(AssertionError::NoncanonicalPayload);
    }
    Ok(value)
}

fn validate_json_shape(value: &Value) -> Result<(), AssertionError> {
    match value {
        Value::Null | Value::Bool(_) | Value::String(_) => Ok(()),
        Value::Number(number) if number.is_i64() || number.is_u64() => Ok(()),
        Value::Number(_) => Err(AssertionError::SchemaInvalid),
        Value::Array(values) => values.iter().try_for_each(validate_json_shape),
        Value::Object(object) => object.values().try_for_each(validate_json_shape),
    }
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex_lower(&Sha256::digest(bytes))
}

pub fn key_id(key: &[u8]) -> String {
    sha256_hex(key)[..16].to_owned()
}

pub fn request_hashes(request: &BoundRequest<'_>) -> Result<RequestHashes, AssertionError> {
    let method = request.method.to_ascii_uppercase();
    if method != request.method
        || !matches!(method.as_str(), "GET" | "POST" | "PUT" | "PATCH" | "DELETE")
    {
        return Err(AssertionError::RequestMismatch);
    }
    validate_path(request.path)?;
    let canonical_query = canonical_query(request.raw_query)?;
    let content_type = canonical_content_type(request.content_type, request.body)?;
    let next_submission_session_sha256 = request
        .next_submission_session
        .map(|value| {
            if value.is_empty() {
                Err(AssertionError::RequestMismatch)
            } else {
                Ok(sha256_hex(value.as_bytes()))
            }
        })
        .transpose()?;
    Ok(RequestHashes {
        method,
        path: request.path.to_owned(),
        query_sha256: sha256_hex(canonical_query.as_bytes()),
        body_sha256: sha256_hex(request.body),
        content_type,
        idempotency_key_sha256: request
            .idempotency_key
            .map(|value| sha256_hex(value.as_bytes())),
        next_submission_session_sha256,
    })
}

#[derive(Debug, Eq, PartialEq)]
pub struct RequestHashes {
    pub method: String,
    pub path: String,
    pub query_sha256: String,
    pub body_sha256: String,
    pub content_type: String,
    pub idempotency_key_sha256: Option<String>,
    pub next_submission_session_sha256: Option<String>,
}

pub fn canonical_request_digest(request: &BoundRequest<'_>) -> Result<String, AssertionError> {
    let hashes = request_hashes(request)?;
    let mut input = format!(
        "{}\n{}\n{}\n{}\n{}\n{}",
        hashes.method,
        hashes.path,
        hashes.query_sha256,
        hashes.body_sha256,
        hashes.content_type,
        hashes.idempotency_key_sha256.as_deref().unwrap_or("")
    );
    if let Some(next_submission_session_sha256) = hashes.next_submission_session_sha256 {
        input.push('\n');
        input.push_str(&next_submission_session_sha256);
    }
    Ok(sha256_hex(input.as_bytes()))
}

fn canonical_content_type(
    content_type: Option<&str>,
    body: &[u8],
) -> Result<String, AssertionError> {
    if body.is_empty() {
        return Ok(String::new());
    }
    let normalized = content_type
        .and_then(|value| value.split(';').next())
        .map(str::trim)
        .map(str::to_ascii_lowercase)
        .ok_or(AssertionError::RequestMismatch)?;
    if !matches!(
        normalized.as_str(),
        "application/json" | "application/octet-stream"
    ) {
        return Err(AssertionError::RequestMismatch);
    }
    Ok(normalized)
}

fn validate_path(path: &str) -> Result<(), AssertionError> {
    let lower = path.to_ascii_lowercase();
    if !path.starts_with('/')
        || path.contains('?')
        || path.contains('#')
        || path
            .split('/')
            .any(|segment| segment == "." || segment == "..")
        || lower.contains("%2f")
        || lower.contains("%5c")
    {
        return Err(AssertionError::RequestMismatch);
    }
    Ok(())
}

fn canonical_query(raw_query: &str) -> Result<String, AssertionError> {
    if raw_query.is_empty() {
        return Ok(String::new());
    }
    let mut pairs = raw_query
        .split('&')
        .map(|part| {
            let (key, value) = part.split_once('=').unwrap_or((part, ""));
            Ok((percent_decode(key)?, percent_decode(value)?))
        })
        .collect::<Result<Vec<_>, AssertionError>>()?;
    pairs.sort_unstable();
    Ok(pairs
        .into_iter()
        .map(|(key, value)| format!("{}={}", percent_encode(&key), percent_encode(&value)))
        .collect::<Vec<_>>()
        .join("&"))
}

fn percent_decode(value: &str) -> Result<Vec<u8>, AssertionError> {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                return Err(AssertionError::RequestMismatch);
            }
            let high = hex_value(bytes[index + 1]).ok_or(AssertionError::RequestMismatch)?;
            let low = hex_value(bytes[index + 2]).ok_or(AssertionError::RequestMismatch)?;
            output.push((high << 4) | low);
            index += 3;
        } else {
            if bytes[index] == b'+' {
                return Err(AssertionError::RequestMismatch);
            }
            output.push(bytes[index]);
            index += 1;
        }
    }
    Ok(output)
}

fn percent_encode(value: &[u8]) -> String {
    let mut output = String::new();
    for byte in value {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            output.push(char::from(*byte));
        } else {
            output.push('%');
            output.push_str(&format!("{byte:02X}"));
        }
    }
    output
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push_str(&format!("{byte:02x}"));
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_request_content_type_is_canonicalized_and_bound() {
        let hashes = request_hashes(&BoundRequest {
            method: "PUT",
            path: "/internal/submission-uploads/11111111-1111-4111-8111-111111111111",
            raw_query: "",
            body: b"binary\0payload",
            content_type: Some("Application/Octet-Stream; charset=binary"),
            idempotency_key: None,
            next_submission_session: None,
        })
        .expect("binary request must be accepted");
        assert_eq!(hashes.content_type, "application/octet-stream");
        assert_eq!(hashes.body_sha256, sha256_hex(b"binary\0payload"));
    }

    #[test]
    fn unapproved_request_content_type_is_rejected() {
        let result = request_hashes(&BoundRequest {
            method: "POST",
            path: "/upload",
            raw_query: "",
            body: b"payload",
            content_type: Some("text/plain"),
            idempotency_key: None,
            next_submission_session: None,
        });
        assert!(matches!(result, Err(AssertionError::RequestMismatch)));
    }

    #[test]
    fn query_spaces_require_rfc3986_encoding() {
        let accepted = request_hashes(&BoundRequest {
            method: "GET",
            path: "/search",
            raw_query: "term=two%20words&literal=a%2Bb",
            body: b"",
            content_type: None,
            idempotency_key: None,
            next_submission_session: None,
        })
        .expect("RFC3986 query must be accepted");
        assert_eq!(
            accepted.query_sha256,
            sha256_hex(b"literal=a%2Bb&term=two%20words")
        );

        let rejected = request_hashes(&BoundRequest {
            method: "GET",
            path: "/search",
            raw_query: "term=two+words",
            body: b"",
            content_type: None,
            idempotency_key: None,
            next_submission_session: None,
        });
        assert!(matches!(rejected, Err(AssertionError::RequestMismatch)));
    }
}
