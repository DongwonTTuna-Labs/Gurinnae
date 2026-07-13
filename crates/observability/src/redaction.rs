use serde_json::Value;

const REDACTED: &str = "[REDACTED]";

pub fn redact(value: &mut Value) {
    match value {
        Value::Object(object) => {
            for (key, value) in object {
                if sensitive_key(key) {
                    *value = Value::String(REDACTED.to_owned());
                } else {
                    redact(value);
                }
            }
        }
        Value::Array(values) => values.iter_mut().for_each(redact),
        Value::String(text) if resembles_secret(text) => *text = REDACTED.to_owned(),
        _ => {}
    }
}

fn sensitive_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    [
        "authorization",
        "cookie",
        "token",
        "secret",
        "password",
        "csrf",
        "assertion",
        "email_encrypted",
    ]
    .iter()
    .any(|candidate| key.contains(candidate))
}

fn resembles_secret(value: &str) -> bool {
    value.starts_with("gurine-")
        || value.starts_with("Bearer ")
        || (value.len() >= 43
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn nested_secrets_are_redacted() {
        let mut value = json!({"request":{"authorization":"Bearer abc","safe":"visible"}});
        redact(&mut value);
        assert_eq!(value["request"]["authorization"], REDACTED);
        assert_eq!(value["request"]["safe"], "visible");
    }
}
