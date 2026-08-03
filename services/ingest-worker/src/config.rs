use std::{collections::BTreeSet, env, path::PathBuf, time::Duration};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use thiserror::Error;
use url::Url;

#[derive(Clone)]
pub struct Config {
    pub environment: RuntimeEnvironment,
    pub database_url: String,
    pub object_store: ObjectStoreConfig,
    pub source_egress_url: Option<Url>,
    pub source_enablement: SourceEnablement,
    pub supplier_identifier_hmac_key: Vec<u8>,
    pub worker_id: String,
    pub poll_interval: Duration,
    pub lease: Duration,
    pub once: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeEnvironment {
    Development,
    Test,
    Production,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum SourceConnector {
    Alio,
    AuditResults,
    KonepsBidResults,
    KonepsContracts,
    KonepsNotices,
    LocalFinance,
    OpenDart,
    PpsSanctions,
    Synthetic,
}

impl SourceConnector {
    const ALL: [Self; 9] = [
        Self::Alio,
        Self::AuditResults,
        Self::KonepsBidResults,
        Self::KonepsContracts,
        Self::KonepsNotices,
        Self::LocalFinance,
        Self::OpenDart,
        Self::PpsSanctions,
        Self::Synthetic,
    ];

    const fn id(self) -> &'static str {
        match self {
            Self::Alio => "alio",
            Self::AuditResults => "audit-results",
            Self::KonepsBidResults => "koneps-bid-results",
            Self::KonepsContracts => "koneps-contracts",
            Self::KonepsNotices => "koneps-notices",
            Self::LocalFinance => "local-finance",
            Self::OpenDart => "open-dart",
            Self::PpsSanctions => "pps-sanctions",
            Self::Synthetic => "synthetic",
        }
    }

    const fn environment_key(self) -> &'static str {
        match self {
            Self::Alio => "SOURCE_ALIO_ENABLED",
            Self::AuditResults => "SOURCE_AUDIT_RESULTS_ENABLED",
            Self::KonepsBidResults => "SOURCE_KONEPS_BID_RESULTS_ENABLED",
            Self::KonepsContracts => "SOURCE_KONEPS_CONTRACTS_ENABLED",
            Self::KonepsNotices => "SOURCE_KONEPS_NOTICES_ENABLED",
            Self::LocalFinance => "SOURCE_LOCAL_FINANCE_ENABLED",
            Self::OpenDart => "SOURCE_OPEN_DART_ENABLED",
            Self::PpsSanctions => "SOURCE_PPS_SANCTIONS_ENABLED",
            Self::Synthetic => "SOURCE_SYNTHETIC_ENABLED",
        }
    }

    const fn enabled_by_default(self) -> bool {
        matches!(self, Self::Synthetic)
    }
}

#[derive(Clone)]
pub struct SourceEnablement {
    enabled: BTreeSet<SourceConnector>,
}

impl SourceEnablement {
    fn from_environment() -> Result<Self, ConfigError> {
        Self::from_lookup(|name| env::var(name).ok())
    }

    fn from_lookup(
        mut lookup: impl FnMut(&'static str) -> Option<String>,
    ) -> Result<Self, ConfigError> {
        let mut enabled = BTreeSet::new();
        for connector in SourceConnector::ALL {
            let configured = lookup(connector.environment_key());
            if parse_boolean(configured.as_deref(), connector.enabled_by_default())? {
                enabled.insert(connector);
            }
        }
        Ok(Self { enabled })
    }

    pub fn enabled_source_ids(&self) -> Vec<String> {
        self.enabled
            .iter()
            .map(|connector| connector.id().to_owned())
            .collect()
    }

    #[cfg(test)]
    fn allows(&self, source_id: &str) -> bool {
        self.enabled
            .iter()
            .any(|connector| connector.id() == source_id)
    }
}

impl RuntimeEnvironment {
    fn parse(value: &str) -> Result<Self, ConfigError> {
        match value {
            "development" => Ok(Self::Development),
            "test" => Ok(Self::Test),
            "production" => Ok(Self::Production),
            _ => Err(ConfigError::Invalid),
        }
    }
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
        let environment = RuntimeEnvironment::parse(&required("GURINE_ENV")?)?;
        let object_store = match env::var("OBJECT_STORE_ADAPTER")
            .unwrap_or_else(|_| "filesystem".to_owned())
            .as_str()
        {
            "filesystem" if environment != RuntimeEnvironment::Production => {
                ObjectStoreConfig::Filesystem(PathBuf::from(required(
                    "OBJECT_STORE_FILESYSTEM_ROOT",
                )?))
            }
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
        let source_enablement = SourceEnablement::from_environment()?;
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
            environment,
            database_url: required("INGEST_DATABASE_URL")?,
            object_store,
            source_egress_url,
            source_enablement,
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

fn parse_boolean(value: Option<&str>, default: bool) -> Result<bool, ConfigError> {
    match value {
        None => Ok(default),
        Some("true") => Ok(true),
        Some("false") => Ok(false),
        Some(_) => Err(ConfigError::Invalid),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{ConfigError, SourceEnablement, decode_key};

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

    #[test]
    fn source_enablement_is_closed_and_defaults_only_synthetic_on() {
        let defaults = SourceEnablement::from_lookup(|_| None).expect("valid defaults");
        assert!(defaults.allows("synthetic"));
        assert!(!defaults.allows("koneps-bid-results"));
        assert!(!defaults.allows("pps-sanctions"));
        assert!(!defaults.allows("unknown-source"));

        let values = BTreeMap::from([
            ("SOURCE_KONEPS_BID_RESULTS_ENABLED", "true"),
            ("SOURCE_OPEN_DART_ENABLED", "true"),
            ("SOURCE_SYNTHETIC_ENABLED", "false"),
        ]);
        let configured =
            SourceEnablement::from_lookup(|name| values.get(name).map(|value| (*value).to_owned()))
                .expect("valid enablement");
        assert!(configured.allows("koneps-bid-results"));
        assert!(configured.allows("open-dart"));
        assert!(!configured.allows("synthetic"));
        assert_eq!(
            configured.enabled_source_ids(),
            vec!["koneps-bid-results".to_owned(), "open-dart".to_owned()]
        );
    }

    #[test]
    fn source_enablement_rejects_non_boolean_values() {
        assert!(matches!(
            SourceEnablement::from_lookup(|name| {
                (name == "SOURCE_OPEN_DART_ENABLED").then(|| "1".to_owned())
            }),
            Err(ConfigError::Invalid)
        ));
    }
}
