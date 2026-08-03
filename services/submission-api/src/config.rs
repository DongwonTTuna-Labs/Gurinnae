use std::{env, path::PathBuf};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use thiserror::Error;

#[derive(Clone)]
pub struct Config {
    pub bind: String,
    pub environment: String,
    pub database_url: String,
    pub public_web_key_current: Vec<u8>,
    pub public_web_key_previous: Option<Vec<u8>>,
    pub response_portal_key_current: Vec<u8>,
    pub response_portal_key_previous: Option<Vec<u8>>,
    pub response_portal_otp_key_current: Vec<u8>,
    pub response_portal_otp_key_previous: Option<Vec<u8>>,
    pub field_key_current: [u8; 32],
    pub field_key_previous: Option<[u8; 32]>,
    pub token_hmac_key: Vec<u8>,
    pub bot_challenge_secret: String,
    pub attachment_store: AttachmentStoreConfig,
    pub max_upload_bytes: usize,
    pub abuse_egress_url: Option<reqwest::Url>,
}

#[derive(Clone)]
pub enum AttachmentStoreConfig {
    Filesystem(PathBuf),
    Egress(reqwest::Url),
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("required submission API variable is missing: {0}")]
    Missing(&'static str),
    #[error("submission API key is invalid")]
    InvalidKey,
    #[error("submission API bind address is invalid")]
    InvalidBind,
    #[error("submission API attachment store is invalid")]
    InvalidAttachmentStore,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let bind = env::var("HTTP_BIND").unwrap_or_else(|_| "0.0.0.0:8082".to_owned());
        if bind.trim().is_empty() {
            return Err(ConfigError::InvalidBind);
        }
        let environment = env::var("GURINE_ENV").unwrap_or_else(|_| "development".to_owned());
        let attachment_store = match env::var("OBJECT_STORE_ADAPTER")
            .unwrap_or_else(|_| "filesystem".to_owned())
            .as_str()
        {
            "filesystem" if environment != "production" => {
                AttachmentStoreConfig::Filesystem(PathBuf::from(
                    env::var("OBJECT_STORE_FILESYSTEM_ROOT")
                        .unwrap_or_else(|_| "/var/lib/gurine-objects".to_owned()),
                ))
            }
            "egress" | "s3" => AttachmentStoreConfig::Egress(
                required("EGRESS_OBJECT_STORE_CHANNEL_URL")?
                    .parse()
                    .map_err(|_| ConfigError::InvalidAttachmentStore)?,
            ),
            _ => return Err(ConfigError::InvalidAttachmentStore),
        };
        let max_upload_bytes = env::var("MAX_UPLOAD_BYTES")
            .unwrap_or_else(|_| "52428800".to_owned())
            .parse::<usize>()
            .map_err(|_| ConfigError::InvalidAttachmentStore)?;
        if !(1..=52_428_800).contains(&max_upload_bytes) {
            return Err(ConfigError::InvalidAttachmentStore);
        }
        let abuse_egress_url = optional("ABUSE_EGRESS_URL")
            .as_deref()
            .map(str::parse)
            .transpose()
            .map_err(|_| ConfigError::InvalidAttachmentStore)?;
        if environment == "production" && abuse_egress_url.is_none() {
            return Err(ConfigError::InvalidAttachmentStore);
        }
        Ok(Self {
            bind,
            environment,
            database_url: required("SUBMISSION_DATABASE_URL")?,
            public_web_key_current: key_at_least_32(&required(
                "PUBLIC_WEB_SUBMISSION_HMAC_KEY_CURRENT",
            )?)?,
            public_web_key_previous: optional_key("PUBLIC_WEB_SUBMISSION_HMAC_KEY_PREVIOUS")?,
            response_portal_key_current: key_at_least_32(&required(
                "RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT",
            )?)?,
            response_portal_key_previous: optional_key(
                "RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_PREVIOUS",
            )?,
            response_portal_otp_key_current: key_at_least_32(&required(
                "RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_CURRENT",
            )?)?,
            response_portal_otp_key_previous: optional_key(
                "RESPONSE_PORTAL_SUBMISSION_HMAC_KEY_PREVIOUS",
            )?,
            field_key_current: key_exact_32(&required("FIELD_ENCRYPTION_KEY_CURRENT")?)?,
            field_key_previous: optional_exact_key("FIELD_ENCRYPTION_KEY_PREVIOUS")?,
            token_hmac_key: key_at_least_32(&required("TOKEN_HMAC_KEY")?)?,
            bot_challenge_secret: required("BOT_CHALLENGE_SECRET_KEY")?,
            attachment_store,
            max_upload_bytes,
            abuse_egress_url,
        })
    }
}

fn required(name: &'static str) -> Result<String, ConfigError> {
    env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or(ConfigError::Missing(name))
}

fn optional(name: &'static str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.trim().is_empty())
}

fn key_at_least_32(value: &str) -> Result<Vec<u8>, ConfigError> {
    let bytes = STANDARD
        .decode(value)
        .map_err(|_| ConfigError::InvalidKey)?;
    if bytes.len() < 32 {
        return Err(ConfigError::InvalidKey);
    }
    Ok(bytes)
}

fn key_exact_32(value: &str) -> Result<[u8; 32], ConfigError> {
    key_at_least_32(value)?
        .try_into()
        .map_err(|_| ConfigError::InvalidKey)
}

fn optional_key(name: &'static str) -> Result<Option<Vec<u8>>, ConfigError> {
    optional(name).as_deref().map(key_at_least_32).transpose()
}

fn optional_exact_key(name: &'static str) -> Result<Option<[u8; 32]>, ConfigError> {
    optional(name).as_deref().map(key_exact_32).transpose()
}
