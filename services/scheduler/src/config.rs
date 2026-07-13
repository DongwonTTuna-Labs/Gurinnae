use std::{env, time::Duration};

use thiserror::Error;

#[derive(Clone, Debug)]
pub struct Config {
    pub database_url: String,
    pub instance_id: String,
    pub poll_interval: Duration,
    pub batch_size: i64,
    pub once: bool,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("scheduler configuration is missing")]
    Missing,
    #[error("scheduler configuration is invalid")]
    Invalid,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let poll_millis = env::var("SCHEDULER_POLL_MILLIS")
            .unwrap_or_else(|_| "500".to_owned())
            .parse::<u64>()
            .map_err(|_| ConfigError::Invalid)?;
        let batch_size = env::var("SCHEDULER_BATCH_SIZE")
            .unwrap_or_else(|_| "100".to_owned())
            .parse::<i64>()
            .map_err(|_| ConfigError::Invalid)?;
        if !(100..=60_000).contains(&poll_millis) || !(1..=1_000).contains(&batch_size) {
            return Err(ConfigError::Invalid);
        }
        let instance_id = required("SCHEDULER_INSTANCE_ID")?;
        if instance_id.len() > 200 {
            return Err(ConfigError::Invalid);
        }
        Ok(Self {
            database_url: required("SCHEDULER_DATABASE_URL")?,
            instance_id,
            poll_interval: Duration::from_millis(poll_millis),
            batch_size,
            once: env::var("SCHEDULER_ONCE").as_deref() == Ok("true"),
        })
    }
}

fn required(name: &'static str) -> Result<String, ConfigError> {
    env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or(ConfigError::Missing)
}
