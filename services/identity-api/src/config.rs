use std::env;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use thiserror::Error;
use url::Url;

#[derive(Clone)]
pub struct Config {
    pub bind: String,
    pub database_url: String,
    pub service_key_current: Vec<u8>,
    pub service_key_previous: Option<Vec<u8>>,
    pub actor_key_current: Vec<u8>,
    pub actor_key_previous: Option<Vec<u8>>,
    pub field_key_current: [u8; 32],
    pub field_key_previous: Option<[u8; 32]>,
    pub oidc_egress_url: Url,
    pub oidc_issuer_url: String,
    pub oidc_client_id: String,
    pub oidc_client_secret: String,
    pub oidc_redirect_uri: String,
    pub oidc_step_up_redirect_uri: String,
    pub oidc_scopes: String,
    pub oidc_acr_values: Option<String>,
    pub oidc_step_up_max_age_seconds: i64,
    pub session_idle_ttl_seconds: i64,
    pub session_absolute_ttl_seconds: i64,
    pub allow_insecure_oidc: bool,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("required identity API variable is missing: {0}")]
    Missing(&'static str),
    #[error("identity API key is not valid base64 with the required decoded length")]
    InvalidKey,
    #[error("identity API URL is invalid")]
    InvalidUrl,
    #[error("identity API duration is invalid")]
    InvalidDuration,
    #[error("production OIDC and callback URLs must use HTTPS")]
    InsecureProductionUrl,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let environment = required("GURINE_ENV")?;
        let allow_insecure_oidc = matches!(environment.as_str(), "development" | "test");
        let config = Self {
            bind: env::var("HTTP_BIND").unwrap_or_else(|_| "0.0.0.0:8083".to_owned()),
            database_url: required("IDENTITY_DATABASE_URL")?,
            service_key_current: key_at_least_32(&required("IDENTITY_SERVICE_HMAC_KEY_CURRENT")?)?,
            service_key_previous: optional_key("IDENTITY_SERVICE_HMAC_KEY_PREVIOUS")?,
            actor_key_current: key_at_least_32(&required("IDENTITY_ASSERTION_HMAC_KEY_CURRENT")?)?,
            actor_key_previous: optional_key("IDENTITY_ASSERTION_HMAC_KEY_PREVIOUS")?,
            field_key_current: key_exact_32(&required("FIELD_ENCRYPTION_KEY_CURRENT")?)?,
            field_key_previous: optional_exact_key("FIELD_ENCRYPTION_KEY_PREVIOUS")?,
            oidc_egress_url: parse_url(&required("OIDC_EGRESS_URL")?)?,
            oidc_issuer_url: required("OIDC_ISSUER_URL")?,
            oidc_client_id: required("OIDC_CLIENT_ID")?,
            oidc_client_secret: required("OIDC_CLIENT_SECRET")?,
            oidc_redirect_uri: required("OIDC_REDIRECT_URI")?,
            oidc_step_up_redirect_uri: required("OIDC_STEP_UP_REDIRECT_URI")?,
            oidc_scopes: required("OIDC_SCOPES")?,
            oidc_acr_values: optional("OIDC_ACR_VALUES"),
            oidc_step_up_max_age_seconds: duration("OIDC_STEP_UP_MAX_AGE_SECONDS", 0, 3_600)?,
            session_idle_ttl_seconds: duration("INTERNAL_SESSION_IDLE_TTL_SECONDS", 1, 86_400)?,
            session_absolute_ttl_seconds: duration(
                "INTERNAL_SESSION_ABSOLUTE_TTL_SECONDS",
                60,
                604_800,
            )?,
            allow_insecure_oidc,
        };
        config.validate_urls()?;
        if config.session_idle_ttl_seconds > config.session_absolute_ttl_seconds {
            return Err(ConfigError::InvalidDuration);
        }
        Ok(config)
    }

    fn validate_urls(&self) -> Result<(), ConfigError> {
        let issuer = parse_url(&self.oidc_issuer_url)?;
        let login_callback = parse_url(&self.oidc_redirect_uri)?;
        let step_up_callback = parse_url(&self.oidc_step_up_redirect_uri)?;
        if !self.allow_insecure_oidc
            && [
                &self.oidc_egress_url,
                &issuer,
                &login_callback,
                &step_up_callback,
            ]
            .iter()
            .any(|url| url.scheme() != "https")
        {
            return Err(ConfigError::InsecureProductionUrl);
        }
        if self.bind.trim().is_empty()
            || self.oidc_client_id.trim().is_empty()
            || !self
                .oidc_scopes
                .split_whitespace()
                .any(|scope| scope == "openid")
        {
            return Err(ConfigError::InvalidUrl);
        }
        Ok(())
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

fn parse_url(value: &str) -> Result<Url, ConfigError> {
    Url::parse(value).map_err(|_| ConfigError::InvalidUrl)
}

fn key_at_least_32(value: &str) -> Result<Vec<u8>, ConfigError> {
    let decoded = STANDARD
        .decode(value)
        .map_err(|_| ConfigError::InvalidKey)?;
    if decoded.len() < 32 {
        return Err(ConfigError::InvalidKey);
    }
    Ok(decoded)
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

fn duration(name: &'static str, minimum: i64, maximum: i64) -> Result<i64, ConfigError> {
    let value = required(name)?
        .parse::<i64>()
        .map_err(|_| ConfigError::InvalidDuration)?;
    if !(minimum..=maximum).contains(&value) {
        return Err(ConfigError::InvalidDuration);
    }
    Ok(value)
}
