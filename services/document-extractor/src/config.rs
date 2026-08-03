use std::{env, path::PathBuf, time::Duration};

use thiserror::Error;
use url::Url;

#[derive(Clone, Debug)]
pub struct Config {
    pub database_url: String,
    pub object_store: ObjectStoreConfig,
    pub worker_id: String,
    pub poll_interval: Duration,
    pub lease: Duration,
    pub once: bool,
}

#[derive(Clone, Debug)]
pub enum ObjectStoreConfig {
    Filesystem(PathBuf),
    Gateway(Url),
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("document extractor configuration is missing")]
    Missing,
    #[error("document extractor configuration is invalid")]
    Invalid,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let environment = required("GURINE_ENV")?;
        if !matches!(environment.as_str(), "development" | "test" | "production") {
            return Err(ConfigError::Invalid);
        }
        let object_store = match env::var("OBJECT_STORE_ADAPTER")
            .unwrap_or_else(|_| "filesystem".to_owned())
            .as_str()
        {
            "filesystem" if environment != "production" => ObjectStoreConfig::Filesystem(
                PathBuf::from(required("OBJECT_STORE_FILESYSTEM_ROOT")?),
            ),
            "egress" | "s3" => ObjectStoreConfig::Gateway(
                required("EGRESS_OBJECT_STORE_CHANNEL_URL")?
                    .parse()
                    .map_err(|_| ConfigError::Invalid)?,
            ),
            _ => return Err(ConfigError::Invalid),
        };
        let poll_millis = env::var("DOCUMENT_EXTRACTOR_POLL_MILLIS")
            .unwrap_or_else(|_| "500".to_owned())
            .parse::<u64>()
            .map_err(|_| ConfigError::Invalid)?;
        let lease_seconds = env::var("DOCUMENT_EXTRACTOR_LEASE_SECONDS")
            .unwrap_or_else(|_| "180".to_owned())
            .parse::<u64>()
            .map_err(|_| ConfigError::Invalid)?;
        if !(100..=60_000).contains(&poll_millis) || !(30..=600).contains(&lease_seconds) {
            return Err(ConfigError::Invalid);
        }
        let worker_id = env::var("HOSTNAME")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| format!("document-extractor-{}", std::process::id()));
        if worker_id.len() > 160 {
            return Err(ConfigError::Invalid);
        }
        Ok(Self {
            database_url: required("DOCUMENT_EXTRACTOR_DATABASE_URL")?,
            object_store,
            worker_id,
            poll_interval: Duration::from_millis(poll_millis),
            lease: Duration::from_secs(lease_seconds),
            once: env::var("DOCUMENT_EXTRACTOR_ONCE").as_deref() == Ok("true"),
        })
    }
}

fn required(name: &'static str) -> Result<String, ConfigError> {
    env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or(ConfigError::Missing)
}
