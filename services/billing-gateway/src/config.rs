use std::{env, time::Duration};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use thiserror::Error;

use crate::digest::Sha256Digest;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeMode {
    Disabled,
    TestOnly,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DonationTestOutcome {
    Pending,
    Succeeded,
    Failed,
    Canceled,
}

impl DonationTestOutcome {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "PENDING",
            Self::Succeeded => "SUCCEEDED",
            Self::Failed => "FAILED",
            Self::Canceled => "CANCELED",
        }
    }
}

pub struct AssertionKeys {
    pub current: Vec<u8>,
    pub previous: Option<Vec<u8>>,
}

impl std::fmt::Debug for AssertionKeys {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AssertionKeys")
            .field("current", &"<redacted>")
            .field("previous", &self.previous.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

pub struct VersionedFixtureKey {
    pub material: Vec<u8>,
    pub version: String,
}

impl std::fmt::Debug for VersionedFixtureKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("VersionedFixtureKey")
            .field("material", &"<redacted>")
            .field("version", &self.version)
            .finish()
    }
}

pub struct FixtureKeyring {
    pub current: VersionedFixtureKey,
    pub previous: Option<VersionedFixtureKey>,
}

impl std::fmt::Debug for FixtureKeyring {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("FixtureKeyring")
            .field("current", &self.current)
            .field("previous", &self.previous)
            .finish()
    }
}

pub struct Config {
    pub bind: String,
    pub database_url: Option<String>,
    pub environment: String,
    pub mode: RuntimeMode,
    pub worker_id: String,
    pub poll_interval: Duration,
    pub lease: Duration,
    pub once: bool,
    pub public_web_keys: Option<AssertionKeys>,
    pub payment_fixture_keys: Option<AssertionKeys>,
    pub payment_identity_keys: Option<FixtureKeyring>,
    pub billing_vault_keys: Option<FixtureKeyring>,
    pub authorization_token_sha256: Option<Sha256Digest>,
    pub test_payment_outcome: Option<DonationTestOutcome>,
    pub test_payment_outcome_config_digest: Option<Sha256Digest>,
}

struct PaymentRuntimeConfig {
    public_web_keys: Option<AssertionKeys>,
    payment_fixture_keys: Option<AssertionKeys>,
    payment_identity_keys: Option<FixtureKeyring>,
    billing_vault_keys: Option<FixtureKeyring>,
    authorization_token_sha256: Option<Sha256Digest>,
    test_payment_outcome: Option<DonationTestOutcome>,
}

impl std::fmt::Debug for Config {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Config")
            .field("bind", &self.bind)
            .field(
                "database_url",
                &self.database_url.as_ref().map(|_| "<redacted>"),
            )
            .field("environment", &self.environment)
            .field("mode", &self.mode)
            .field("worker_id", &self.worker_id)
            .field("poll_interval", &self.poll_interval)
            .field("lease", &self.lease)
            .field("once", &self.once)
            .field("public_web_keys", &self.public_web_keys)
            .field("payment_fixture_keys", &self.payment_fixture_keys)
            .field("payment_identity_keys", &self.payment_identity_keys)
            .field("billing_vault_keys", &self.billing_vault_keys)
            .field(
                "authorization_token_sha256",
                &self
                    .authorization_token_sha256
                    .as_ref()
                    .map(|_| "<redacted>"),
            )
            .field(
                "test_payment_outcome",
                &self.test_payment_outcome.map(|_| "<configured>"),
            )
            .field(
                "test_payment_outcome_config_digest",
                &self
                    .test_payment_outcome_config_digest
                    .as_ref()
                    .map(|_| "<configured>"),
            )
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ConfigError {
    #[error("billing gateway configuration is missing")]
    Missing,
    #[error("billing gateway configuration is invalid")]
    Invalid,
    #[error("billing gateway fixture configuration is forbidden")]
    FixtureForbidden,
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_lookup(|name| env::var(name).ok())
    }

    pub fn from_lookup<F>(lookup: F) -> Result<Self, ConfigError>
    where
        F: Fn(&str) -> Option<String>,
    {
        let value = |name: &str| lookup(name).filter(|item| !item.trim().is_empty());
        let environment = value("GURINE_ENV").unwrap_or_else(|| "development".to_owned());
        if !matches!(environment.as_str(), "development" | "test" | "production") {
            return Err(ConfigError::Invalid);
        }
        let mode = match value("BILLING_GATEWAY_MODE").as_deref() {
            None | Some("DISABLED") => RuntimeMode::Disabled,
            Some("TEST_ONLY") if environment == "test" => RuntimeMode::TestOnly,
            Some("TEST_ONLY") => return Err(ConfigError::FixtureForbidden),
            Some(_) => return Err(ConfigError::Invalid),
        };
        let payment = payment_runtime_config(&value, mode)?;
        let test_payment_outcome = payment.test_payment_outcome;
        let test_payment_outcome_config_digest = test_payment_outcome.map(outcome_config_digest);
        let poll_millis = number(&value, "BILLING_POLL_MILLIS", 500)?;
        let lease_seconds = number(&value, "BILLING_LEASE_SECONDS", 120)?;
        if !(100..=60_000).contains(&poll_millis) || !(30..=600).contains(&lease_seconds) {
            return Err(ConfigError::Invalid);
        }
        let worker_id = value("BILLING_WORKER_ID")
            .unwrap_or_else(|| format!("billing-gateway-{}", std::process::id()));
        if worker_id.len() > 160 {
            return Err(ConfigError::Invalid);
        }
        let bind = value("BILLING_GATEWAY_BIND_ADDR").unwrap_or_else(|| "0.0.0.0:8092".to_owned());
        if bind.trim().is_empty() {
            return Err(ConfigError::Invalid);
        }
        let database_url = match mode {
            RuntimeMode::Disabled => None,
            RuntimeMode::TestOnly => {
                Some(value("BILLING_DATABASE_URL").ok_or(ConfigError::Missing)?)
            }
        };
        Ok(Self {
            bind,
            database_url,
            environment,
            mode,
            worker_id,
            poll_interval: Duration::from_millis(poll_millis),
            lease: Duration::from_secs(lease_seconds),
            once: value("BILLING_ONCE").as_deref() == Some("true"),
            public_web_keys: payment.public_web_keys,
            payment_fixture_keys: payment.payment_fixture_keys,
            payment_identity_keys: payment.payment_identity_keys,
            billing_vault_keys: payment.billing_vault_keys,
            authorization_token_sha256: payment.authorization_token_sha256,
            test_payment_outcome,
            test_payment_outcome_config_digest,
        })
    }
}

fn payment_runtime_config<F>(
    value: &F,
    mode: RuntimeMode,
) -> Result<PaymentRuntimeConfig, ConfigError>
where
    F: Fn(&str) -> Option<String>,
{
    let fixture_current = value("PAYMENT_FIXTURE_BILLING_HMAC_KEY_CURRENT");
    let fixture_previous = value("PAYMENT_FIXTURE_BILLING_HMAC_KEY_PREVIOUS");
    let authorization_token = value("DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN");
    let test_payment_outcome = value("DONATION_TEST_PAYMENT_OUTCOME");
    if mode != RuntimeMode::TestOnly
        && (fixture_current.is_some()
            || fixture_previous.is_some()
            || authorization_token.is_some()
            || test_payment_outcome.is_some())
    {
        return Err(ConfigError::FixtureForbidden);
    }
    let public_web_keys = match (
        value("PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT"),
        value("PUBLIC_WEB_BILLING_HMAC_KEY_PREVIOUS"),
    ) {
        (Some(current), previous) => Some(assertion_keys(current, previous)?),
        (None, None) if mode == RuntimeMode::Disabled => None,
        _ => return Err(ConfigError::Missing),
    };
    let payment_fixture_keys = match (fixture_current, fixture_previous) {
        (Some(current), previous) => Some(assertion_keys(current, previous)?),
        (None, None) if mode == RuntimeMode::Disabled => None,
        _ => return Err(ConfigError::Missing),
    };
    let payment_identity_keys = fixture_keyring(
        value,
        mode,
        "PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_CURRENT",
        "PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_CURRENT_VERSION",
        "PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_PREVIOUS",
        "PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_PREVIOUS_VERSION",
    )?;
    let billing_vault_keys = fixture_keyring(
        value,
        mode,
        "PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_CURRENT",
        "PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_CURRENT_VERSION",
        "PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_PREVIOUS",
        "PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_PREVIOUS_VERSION",
    )?;
    let authorization_token_sha256 = match authorization_token {
        Some(token) => Some(Sha256Digest::of(token.as_bytes())),
        None if mode == RuntimeMode::Disabled => None,
        None => return Err(ConfigError::Missing),
    };
    let test_payment_outcome = match test_payment_outcome.as_deref() {
        Some("PENDING") => Some(DonationTestOutcome::Pending),
        Some("SUCCEEDED") => Some(DonationTestOutcome::Succeeded),
        Some("FAILED") => Some(DonationTestOutcome::Failed),
        Some("CANCELED") => Some(DonationTestOutcome::Canceled),
        Some(_) => return Err(ConfigError::Invalid),
        None if mode == RuntimeMode::Disabled => None,
        None => return Err(ConfigError::Missing),
    };
    validate_fixture_key_separation(
        public_web_keys.as_ref(),
        payment_fixture_keys.as_ref(),
        payment_identity_keys.as_ref(),
        billing_vault_keys.as_ref(),
    )?;
    Ok(PaymentRuntimeConfig {
        public_web_keys,
        payment_fixture_keys,
        payment_identity_keys,
        billing_vault_keys,
        authorization_token_sha256,
        test_payment_outcome,
    })
}

fn fixture_keyring<F>(
    value: &F,
    mode: RuntimeMode,
    current_key_name: &str,
    current_version_name: &str,
    previous_key_name: &str,
    previous_version_name: &str,
) -> Result<Option<FixtureKeyring>, ConfigError>
where
    F: Fn(&str) -> Option<String>,
{
    let current_key = value(current_key_name);
    let current_version = value(current_version_name);
    let previous_key = value(previous_key_name);
    let previous_version = value(previous_version_name);
    if mode != RuntimeMode::TestOnly {
        return if current_key.is_none()
            && current_version.is_none()
            && previous_key.is_none()
            && previous_version.is_none()
        {
            Ok(None)
        } else {
            Err(ConfigError::FixtureForbidden)
        };
    }
    let current = VersionedFixtureKey {
        material: decode_key(&current_key.ok_or(ConfigError::Missing)?)?,
        version: validate_key_version(current_version.ok_or(ConfigError::Missing)?)?,
    };
    let previous = match (previous_key, previous_version) {
        (None, None) => None,
        (Some(key), Some(version)) => Some(VersionedFixtureKey {
            material: decode_key(&key)?,
            version: validate_key_version(version)?,
        }),
        _ => return Err(ConfigError::Missing),
    };
    if previous
        .as_ref()
        .is_some_and(|value| value.version == current.version)
    {
        return Err(ConfigError::Invalid);
    }
    Ok(Some(FixtureKeyring { current, previous }))
}

fn validate_key_version(value: String) -> Result<String, ConfigError> {
    if value.len() > 100
        || value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
    {
        Err(ConfigError::Invalid)
    } else {
        Ok(value)
    }
}

fn validate_fixture_key_separation(
    public: Option<&AssertionKeys>,
    fixture_assertion: Option<&AssertionKeys>,
    identity: Option<&FixtureKeyring>,
    vault: Option<&FixtureKeyring>,
) -> Result<(), ConfigError> {
    let mut keys = Vec::new();
    for key in [public, fixture_assertion].into_iter().flatten() {
        keys.push(key.current.as_slice());
        keys.extend(key.previous.as_deref());
    }
    for ring in [identity, vault].into_iter().flatten() {
        keys.push(ring.current.material.as_slice());
        keys.extend(
            ring.previous
                .as_ref()
                .map(|value| value.material.as_slice()),
        );
    }
    for (index, key) in keys.iter().enumerate() {
        if keys[index + 1..].contains(key) {
            return Err(ConfigError::Invalid);
        }
    }
    Ok(())
}

fn outcome_config_digest(outcome: DonationTestOutcome) -> Sha256Digest {
    let domain = b"gurine-donation-test-payment-outcome-config.v1\0";
    let mut preimage = Vec::with_capacity(domain.len() + outcome.as_str().len());
    preimage.extend_from_slice(domain);
    preimage.extend_from_slice(outcome.as_str().as_bytes());
    Sha256Digest::of(&preimage)
}

fn assertion_keys(current: String, previous: Option<String>) -> Result<AssertionKeys, ConfigError> {
    Ok(AssertionKeys {
        current: decode_key(&current)?,
        previous: previous.as_deref().map(decode_key).transpose()?,
    })
}

fn decode_key(value: &str) -> Result<Vec<u8>, ConfigError> {
    let bytes = STANDARD.decode(value).map_err(|_| ConfigError::Invalid)?;
    if bytes.len() < 32 {
        Err(ConfigError::Invalid)
    } else {
        Ok(bytes)
    }
}

fn number<F>(value: &F, name: &str, default: u64) -> Result<u64, ConfigError>
where
    F: Fn(&str) -> Option<String>,
{
    value(name)
        .map_or(Ok(default), |item| item.parse())
        .map_err(|_| ConfigError::Invalid)
}

#[cfg(test)]
#[path = "config_tests.rs"]
mod tests;
