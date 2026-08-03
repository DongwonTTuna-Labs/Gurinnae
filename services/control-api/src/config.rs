use std::env;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("required control API variable is missing")]
    MissingVariable,
    #[error("identity assertion key must be base64 with at least 32 decoded bytes")]
    InvalidAssertionKey,
    #[error("field encryption key must be base64 with exactly 32 decoded bytes")]
    InvalidFieldKey,
}

pub struct Config {
    pub bind: String,
    pub database_url: String,
    pub assertion_key_current: Vec<u8>,
    pub assertion_key_previous: Option<Vec<u8>>,
    pub field_key_current: [u8; 32],
    pub field_key_previous: Option<[u8; 32]>,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let bind = env::var("HTTP_BIND").unwrap_or_else(|_| "0.0.0.0:8081".to_owned());
        let database_url = env::var("CONTROL_DATABASE_URL")
            .or_else(|_| env::var("DATABASE_URL"))
            .map_err(|_| ConfigError::MissingVariable)?;
        let current = env::var("IDENTITY_ASSERTION_HMAC_KEY_CURRENT")
            .map_err(|_| ConfigError::MissingVariable)?;
        let previous = optional("IDENTITY_ASSERTION_HMAC_KEY_PREVIOUS");
        let field_current =
            env::var("FIELD_ENCRYPTION_KEY_CURRENT").map_err(|_| ConfigError::MissingVariable)?;
        let field_previous = optional("FIELD_ENCRYPTION_KEY_PREVIOUS");
        Ok(Self {
            bind,
            database_url,
            assertion_key_current: decode_key(&current)?,
            assertion_key_previous: previous.as_deref().map(decode_key).transpose()?,
            field_key_current: decode_field_key(&field_current)?,
            field_key_previous: field_previous
                .as_deref()
                .map(decode_field_key)
                .transpose()?,
        })
    }
}

fn optional(name: &'static str) -> Option<String> {
    non_empty(env::var(name).ok())
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.filter(|value| !value.trim().is_empty())
}

fn decode_field_key(value: &str) -> Result<[u8; 32], ConfigError> {
    STANDARD
        .decode(value)
        .map_err(|_| ConfigError::InvalidFieldKey)?
        .try_into()
        .map_err(|_| ConfigError::InvalidFieldKey)
}

fn decode_key(value: &str) -> Result<Vec<u8>, ConfigError> {
    let decoded = STANDARD
        .decode(value)
        .map_err(|_| ConfigError::InvalidAssertionKey)?;
    if decoded.len() < 32 {
        return Err(ConfigError::InvalidAssertionKey);
    }
    Ok(decoded)
}

#[cfg(test)]
mod tests {
    use super::non_empty;

    #[test]
    fn empty_optional_keys_are_absent() {
        // Compose intentionally forwards rotation keys as empty strings when no
        // previous key is active. The process must treat that as "not set".
        assert!(non_empty(Some("   ".to_owned())).is_none());
        assert!(non_empty(None).is_none());
        assert_eq!(non_empty(Some("key".to_owned())).as_deref(), Some("key"));
    }
}
