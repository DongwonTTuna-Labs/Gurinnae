use std::{env, time::Duration};

use thiserror::Error;

#[derive(Clone, Debug)]
pub struct Config {
    pub database_url: String,
    pub worker_id: String,
    pub poll_interval: Duration,
    pub lease: Duration,
    pub once: bool,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("projection worker configuration is missing")]
    Missing,
    #[error("projection worker configuration is invalid")]
    Invalid,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let poll_millis = number("PROJECTOR_POLL_MILLIS", 500)?;
        let lease_seconds = number("PROJECTOR_LEASE_SECONDS", 120)?;
        if !(100..=60_000).contains(&poll_millis) || !(30..=600).contains(&lease_seconds) {
            return Err(ConfigError::Invalid);
        }
        let worker_id = env::var("HOSTNAME")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| format!("projection-worker-{}", std::process::id()));
        if worker_id.len() > 160 {
            return Err(ConfigError::Invalid);
        }
        Ok(Self {
            database_url: required("PROJECTOR_DATABASE_URL")?,
            worker_id,
            poll_interval: Duration::from_millis(poll_millis),
            lease: Duration::from_secs(lease_seconds),
            once: env::var("PROJECTOR_ONCE").as_deref() == Ok("true"),
        })
    }
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
