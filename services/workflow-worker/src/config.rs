use std::{env, path::PathBuf, time::Duration};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use reqwest::Url;
use thiserror::Error;

#[derive(Clone)]
pub struct Config {
    pub database_url: String,
    pub field_key_current: [u8; 32],
    pub field_key_previous: Option<[u8; 32]>,
    pub object_store: ObjectStoreConfig,
    pub clamav_host: String,
    pub clamav_port: u16,
    pub poll_interval: Duration,
    pub lease_seconds: i32,
    pub worker_id: String,
    pub job_lease: Duration,
    pub once: bool,
}

#[derive(Clone)]
pub enum ObjectStoreConfig {
    Filesystem(PathBuf),
    Gateway(Url),
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("workflow worker configuration is missing")]
    Missing,
    #[error("workflow worker configuration is invalid")]
    Invalid,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let environment = required("GURINE_ENV")?;
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
        let clamav_port = env::var("CLAMAV_PORT")
            .unwrap_or_else(|_| "3310".to_owned())
            .parse()
            .map_err(|_| ConfigError::Invalid)?;
        let poll_millis = env::var("WORKFLOW_POLL_MILLIS")
            .unwrap_or_else(|_| "1000".to_owned())
            .parse::<u64>()
            .map_err(|_| ConfigError::Invalid)?;
        let lease_seconds = env::var("ATTACHMENT_SCAN_LEASE_SECONDS")
            .unwrap_or_else(|_| "120".to_owned())
            .parse::<i32>()
            .map_err(|_| ConfigError::Invalid)?;
        let job_lease_seconds = env::var("WORKFLOW_JOB_LEASE_SECONDS")
            .unwrap_or_else(|_| "120".to_owned())
            .parse::<u64>()
            .map_err(|_| ConfigError::Invalid)?;
        let worker_id = env::var("HOSTNAME")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| format!("workflow-worker-{}", std::process::id()));
        if clamav_port == 0
            || poll_millis == 0
            || !(10..=600).contains(&lease_seconds)
            || !(30..=600).contains(&job_lease_seconds)
            || worker_id.len() > 160
        {
            return Err(ConfigError::Invalid);
        }
        Ok(Self {
            database_url: required("WORKFLOW_DATABASE_URL")?,
            field_key_current: exact_key(&required("FIELD_ENCRYPTION_KEY_CURRENT")?)?,
            field_key_previous: optional("FIELD_ENCRYPTION_KEY_PREVIOUS")
                .as_deref()
                .map(exact_key)
                .transpose()?,
            object_store,
            clamav_host: required("CLAMAV_HOST")?,
            clamav_port,
            poll_interval: Duration::from_millis(poll_millis),
            lease_seconds,
            worker_id,
            job_lease: Duration::from_secs(job_lease_seconds),
            once: env::var("WORKFLOW_ONCE").as_deref() == Ok("true"),
        })
    }
}

fn required(name: &'static str) -> Result<String, ConfigError> {
    optional(name).ok_or(ConfigError::Missing)
}

fn optional(name: &'static str) -> Option<String> {
    env::var(name).ok().filter(|value| !value.trim().is_empty())
}

fn exact_key(value: &str) -> Result<[u8; 32], ConfigError> {
    STANDARD
        .decode(value)
        .map_err(|_| ConfigError::Invalid)?
        .try_into()
        .map_err(|_| ConfigError::Invalid)
}
