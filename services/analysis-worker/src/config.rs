use std::{env, time::Duration};

use reqwest::Url;
use thiserror::Error;

#[derive(Clone, Debug)]
pub struct Config {
    pub database_url: String,
    pub environment: String,
    pub ai_enabled: bool,
    pub egress_ai_url: Option<Url>,
    pub egress_source_url: Option<Url>,
    pub egress_object_store_url: Option<Url>,
    pub provider_order: Vec<String>,
    pub worker_id: String,
    pub poll_interval: Duration,
    pub lease: Duration,
    pub once: bool,
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("analysis worker configuration is missing")]
    Missing,
    #[error("analysis worker configuration is invalid")]
    Invalid,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let environment = required("GURINE_ENV")?;
        if !matches!(environment.as_str(), "development" | "test" | "production") {
            return Err(ConfigError::Invalid);
        }
        let ai_enabled = boolean("AI_ENABLED", false)?;
        let egress_ai_url = env::var("EGRESS_AI_CHANNEL_URL")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(|value| value.parse::<Url>().map_err(|_| ConfigError::Invalid))
            .transpose()?;
        let egress_source_url = env::var("EGRESS_SOURCE_CHANNEL_URL")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(|value| value.parse::<Url>().map_err(|_| ConfigError::Invalid))
            .transpose()?;
        let egress_object_store_url = env::var("EGRESS_OBJECT_STORE_CHANNEL_URL")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(|value| value.parse::<Url>().map_err(|_| ConfigError::Invalid))
            .transpose()?;
        let provider_order = env::var("AI_PROVIDER_ORDER")
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
            .collect::<Vec<_>>();
        if environment == "production"
            && ai_enabled
            && (egress_ai_url.is_none()
                || egress_source_url.is_none()
                || egress_object_store_url.is_none()
                || provider_order.is_empty())
        {
            return Err(ConfigError::Missing);
        }
        let poll_millis = number("ANALYSIS_POLL_MILLIS", 500)?;
        let lease_seconds = number("ANALYSIS_LEASE_SECONDS", 120)?;
        if !(100..=60_000).contains(&poll_millis) || !(30..=600).contains(&lease_seconds) {
            return Err(ConfigError::Invalid);
        }
        let worker_id = env::var("HOSTNAME")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| format!("analysis-worker-{}", std::process::id()));
        if worker_id.len() > 160 {
            return Err(ConfigError::Invalid);
        }
        Ok(Self {
            database_url: required("ANALYSIS_DATABASE_URL")?,
            environment,
            ai_enabled,
            egress_ai_url,
            egress_source_url,
            egress_object_store_url,
            provider_order,
            worker_id,
            poll_interval: Duration::from_millis(poll_millis),
            lease: Duration::from_secs(lease_seconds),
            once: env::var("ANALYSIS_ONCE").as_deref() == Ok("true"),
        })
    }
}

fn boolean(name: &'static str, default: bool) -> Result<bool, ConfigError> {
    match env::var(name).ok().as_deref() {
        None => Ok(default),
        Some("true") => Ok(true),
        Some("false") => Ok(false),
        Some(_) => Err(ConfigError::Invalid),
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
