use std::{env, time::Duration};

use thiserror::Error;

const DONATION_CHARGE_SCHEDULING_MODE: &str = "SCHEDULER_DONATION_CHARGE_MODE";

/// Recurring donation charges have no scheduling authority in R6e.
///
/// This enum intentionally has no enabled variant. A future positive mode
/// requires a higher-contract decision before the scheduler can represent it.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum DonationChargeSchedulingMode {
    #[default]
    Disabled,
}

impl DonationChargeSchedulingMode {
    fn from_value(value: Option<&str>) -> Result<Self, ConfigError> {
        match value {
            None | Some("DISABLED") => Ok(Self::Disabled),
            Some(_) => Err(ConfigError::Invalid),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Config {
    pub database_url: String,
    pub instance_id: String,
    pub poll_interval: Duration,
    pub batch_size: i64,
    pub once: bool,
    pub donation_charge_scheduling_mode: DonationChargeSchedulingMode,
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
        Self::from_lookup(|name| env::var(name).ok())
    }

    fn from_lookup<F>(lookup: F) -> Result<Self, ConfigError>
    where
        F: Fn(&str) -> Option<String>,
    {
        let donation_charge_scheduling_mode = DonationChargeSchedulingMode::from_value(
            lookup(DONATION_CHARGE_SCHEDULING_MODE).as_deref(),
        )?;
        let value = |name: &str| lookup(name).filter(|item| !item.trim().is_empty());
        let poll_millis = value("SCHEDULER_POLL_MILLIS")
            .unwrap_or_else(|| "500".to_owned())
            .parse::<u64>()
            .map_err(|_| ConfigError::Invalid)?;
        let batch_size = value("SCHEDULER_BATCH_SIZE")
            .unwrap_or_else(|| "100".to_owned())
            .parse::<i64>()
            .map_err(|_| ConfigError::Invalid)?;
        if !(100..=60_000).contains(&poll_millis) || !(1..=1_000).contains(&batch_size) {
            return Err(ConfigError::Invalid);
        }
        let instance_id = required(&value, "SCHEDULER_INSTANCE_ID")?;
        if instance_id.len() > 200 {
            return Err(ConfigError::Invalid);
        }
        Ok(Self {
            database_url: required(&value, "SCHEDULER_DATABASE_URL")?,
            instance_id,
            poll_interval: Duration::from_millis(poll_millis),
            batch_size,
            once: value("SCHEDULER_ONCE").as_deref() == Some("true"),
            donation_charge_scheduling_mode,
        })
    }
}

fn required<F>(value: &F, name: &'static str) -> Result<String, ConfigError>
where
    F: Fn(&str) -> Option<String>,
{
    value(name).ok_or(ConfigError::Missing)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;

    fn lookup(values: BTreeMap<&'static str, String>) -> impl Fn(&str) -> Option<String> {
        move |name| values.get(name).cloned()
    }

    fn required_values() -> BTreeMap<&'static str, String> {
        BTreeMap::from([
            (
                "SCHEDULER_DATABASE_URL",
                "postgres://scheduler:redacted@localhost/gurine".to_owned(),
            ),
            ("SCHEDULER_INSTANCE_ID", "scheduler-test".to_owned()),
        ])
    }

    #[test]
    fn donation_charge_scheduling_defaults_to_disabled() -> Result<(), ConfigError> {
        let config = Config::from_lookup(lookup(required_values()))?;

        assert_eq!(
            config.donation_charge_scheduling_mode,
            DonationChargeSchedulingMode::Disabled
        );
        Ok(())
    }

    #[test]
    fn donation_charge_scheduling_rejects_attempted_enablement_and_unknown_values() {
        for attempted_mode in ["TEST_ONLY", "ENABLED", "UNKNOWN", "disabled", ""] {
            let mut values = required_values();
            values.insert(DONATION_CHARGE_SCHEDULING_MODE, attempted_mode.to_owned());

            assert!(matches!(
                Config::from_lookup(lookup(values)),
                Err(ConfigError::Invalid)
            ));
        }
    }
}
