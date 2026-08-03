use std::{env, path::PathBuf, time::Duration};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use thiserror::Error;
use url::Url;

#[derive(Clone)]
pub struct Config {
    pub database_url: String,
    pub object_store: ObjectStoreConfig,
    pub source_egress_url: Option<Url>,
    pub supplier_identifier_hmac_key: Vec<u8>,
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
    #[error("ingest worker configuration is missing")]
    Missing,
    #[error("ingest worker configuration is invalid")]
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
        let source_egress_url = env::var("EGRESS_SOURCE_CHANNEL_URL")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(|value| value.parse::<Url>().map_err(|_| ConfigError::Invalid))
            .transpose()?;
        let poll_millis = number("INGEST_POLL_MILLIS", 500)?;
        let lease_seconds = number("INGEST_LEASE_SECONDS", 120)?;
        if !(100..=60_000).contains(&poll_millis) || !(30..=600).contains(&lease_seconds) {
            return Err(ConfigError::Invalid);
        }
        let worker_id = env::var("HOSTNAME")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| format!("ingest-worker-{}", std::process::id()));
        if worker_id.len() > 160 {
            return Err(ConfigError::Invalid);
        }
        Ok(Self {
            database_url: required("INGEST_DATABASE_URL")?,
            object_store,
            source_egress_url,
            supplier_identifier_hmac_key: decode_key(&required("SUPPLIER_IDENTIFIER_HMAC_KEY")?)?,
            worker_id,
            poll_interval: Duration::from_millis(poll_millis),
            lease: Duration::from_secs(lease_seconds),
            once: env::var("INGEST_ONCE").as_deref() == Ok("true"),
        })
    }
}

fn decode_key(value: &str) -> Result<Vec<u8>, ConfigError> {
    let bytes = STANDARD.decode(value).map_err(|_| ConfigError::Invalid)?;
    if bytes.len() < 32 {
        return Err(ConfigError::Invalid);
    }
    Ok(bytes)
}

fn required(name: &'static str) -> Result<String, ConfigError> {
    env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or(ConfigError::Missing)
}

fn number(name: &'static str, default: u64) -> Result<u64, ConfigError> {
    env::var(name)
        .ok()
        .map_or(Ok(default), |value| value.parse())
        .map_err(|_| ConfigError::Invalid)
}

#[cfg(test)]
mod tests {
    use super::{ConfigError, decode_key};

    #[test]
    fn supplier_identifier_key_requires_standard_base64_and_32_bytes() {
        assert!(
            decode_key("MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=")
                .is_ok_and(|key| key.len() == 32)
        );
        assert!(matches!(
            decode_key("not-base64"),
            Err(ConfigError::Invalid)
        ));
        assert!(matches!(decode_key("c2hvcnQ="), Err(ConfigError::Invalid)));
    }
}
