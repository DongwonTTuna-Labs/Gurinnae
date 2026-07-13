use std::env;

use thiserror::Error;
use url::Url;

#[derive(Clone)]
pub struct Config {
    pub bind: String,
    pub issuer: Url,
    pub client_id: String,
    pub client_secret: String,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("OIDC test provider is only available in development or test")]
    ProductionForbidden,
    #[error("OIDC test provider configuration is missing or invalid")]
    Invalid,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let environment = env::var("GURINE_ENV").map_err(|_| ConfigError::Invalid)?;
        if !matches!(environment.as_str(), "development" | "test") {
            return Err(ConfigError::ProductionForbidden);
        }
        let issuer = Url::parse(&env::var("OIDC_TEST_ISSUER").map_err(|_| ConfigError::Invalid)?)
            .map_err(|_| ConfigError::Invalid)?;
        let client_id = env::var("OIDC_TEST_CLIENT_ID").map_err(|_| ConfigError::Invalid)?;
        let client_secret =
            env::var("OIDC_TEST_CLIENT_SECRET").map_err(|_| ConfigError::Invalid)?;
        let bind = env::var("HTTP_BIND").unwrap_or_else(|_| "0.0.0.0:8085".to_owned());
        if issuer.scheme() != "http"
            || issuer.host_str().is_none()
            || client_id.is_empty()
            || client_secret.len() < 16
            || bind.trim().is_empty()
        {
            return Err(ConfigError::Invalid);
        }
        Ok(Self {
            bind,
            issuer,
            client_id,
            client_secret,
        })
    }
}
