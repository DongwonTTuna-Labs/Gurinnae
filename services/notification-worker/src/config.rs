use std::{env, path::PathBuf, time::Duration};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use thiserror::Error;
use url::Url;

#[derive(Clone)]
pub struct Config {
    pub database_url: String,
    pub field_key_current: [u8; 32],
    pub field_key_previous: Option<[u8; 32]>,
    pub token_hmac_key: Vec<u8>,
    pub email_adapter: EmailAdapter,
    pub email_file_outbox: Option<PathBuf>,
    pub smtp_egress_url: Url,
    pub from_email: String,
    pub reply_to: String,
    pub public_base_url: String,
    pub response_base_url: String,
    pub poll_interval: Duration,
    pub lease_seconds: i32,
    pub once: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EmailAdapter {
    File,
    Smtp,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("notification worker configuration is missing")]
    Missing,
    #[error("notification worker configuration is invalid")]
    Invalid,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let poll_millis = env::var("NOTIFICATION_POLL_MILLIS")
            .unwrap_or_else(|_| "1000".to_owned())
            .parse::<u64>()
            .map_err(|_| ConfigError::Invalid)?;
        let lease_seconds = env::var("NOTIFICATION_LEASE_SECONDS")
            .unwrap_or_else(|_| "120".to_owned())
            .parse::<i32>()
            .map_err(|_| ConfigError::Invalid)?;
        if poll_millis == 0 || !(10..=600).contains(&lease_seconds) {
            return Err(ConfigError::Invalid);
        }
        let email_adapter = match required("EMAIL_ADAPTER")?.as_str() {
            "file" => EmailAdapter::File,
            "smtp" => EmailAdapter::Smtp,
            _ => return Err(ConfigError::Invalid),
        };
        let email_file_outbox = match email_adapter {
            EmailAdapter::File => {
                let path = PathBuf::from(required("EMAIL_FILE_OUTBOX")?);
                if !path.is_absolute() {
                    return Err(ConfigError::Invalid);
                }
                Some(path)
            }
            EmailAdapter::Smtp => None,
        };
        Ok(Self {
            database_url: required("NOTIFICATION_DATABASE_URL")?,
            field_key_current: exact_key(&required("FIELD_ENCRYPTION_KEY_CURRENT")?)?,
            field_key_previous: optional("FIELD_ENCRYPTION_KEY_PREVIOUS")
                .as_deref()
                .map(exact_key)
                .transpose()?,
            token_hmac_key: key(&required("TOKEN_HMAC_KEY")?)?,
            email_adapter,
            email_file_outbox,
            smtp_egress_url: required("EGRESS_SMTP_CHANNEL_URL")?
                .parse()
                .map_err(|_| ConfigError::Invalid)?,
            from_email: required("EMAIL_FROM")?,
            reply_to: required("EMAIL_REPLY_TO")?,
            public_base_url: base_url("PUBLIC_BASE_URL")?,
            response_base_url: base_url("RESPONSE_BASE_URL")?,
            poll_interval: Duration::from_millis(poll_millis),
            lease_seconds,
            once: env::var("NOTIFICATION_ONCE").as_deref() == Ok("true"),
        })
    }
}

fn required(name: &'static str) -> Result<String, ConfigError> {
    optional(name).ok_or(ConfigError::Missing)
}

fn optional(name: &'static str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.trim().is_empty())
}

fn key(value: &str) -> Result<Vec<u8>, ConfigError> {
    let bytes = STANDARD.decode(value).map_err(|_| ConfigError::Invalid)?;
    if bytes.len() < 32 {
        return Err(ConfigError::Invalid);
    }
    Ok(bytes)
}

fn exact_key(value: &str) -> Result<[u8; 32], ConfigError> {
    key(value)?.try_into().map_err(|_| ConfigError::Invalid)
}

fn base_url(name: &'static str) -> Result<String, ConfigError> {
    let value = required(name)?;
    let parsed = Url::parse(&value).map_err(|_| ConfigError::Invalid)?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.cannot_be_a_base() {
        return Err(ConfigError::Invalid);
    }
    Ok(value.trim_end_matches('/').to_owned())
}
