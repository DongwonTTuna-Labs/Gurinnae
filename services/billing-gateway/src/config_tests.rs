use std::collections::BTreeMap;

use base64::{Engine as _, engine::general_purpose::STANDARD};

use super::*;

const IDENTITY_CURRENT_KEY: &str = "PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_CURRENT";
const IDENTITY_CURRENT_VERSION: &str = "PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_CURRENT_VERSION";
const IDENTITY_PREVIOUS_KEY: &str = "PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_PREVIOUS";
const IDENTITY_PREVIOUS_VERSION: &str = "PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_PREVIOUS_VERSION";
const VAULT_CURRENT_KEY: &str = "PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_CURRENT";
const VAULT_CURRENT_VERSION: &str = "PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_CURRENT_VERSION";
const VAULT_PREVIOUS_KEY: &str = "PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_PREVIOUS";
const VAULT_PREVIOUS_VERSION: &str = "PAYMENT_FIXTURE_BILLING_KEY_VAULT_HMAC_KEY_PREVIOUS_VERSION";

fn lookup(values: BTreeMap<&str, String>) -> impl Fn(&str) -> Option<String> {
    move |name| values.get(name).cloned()
}

fn key(seed: u8) -> String {
    STANDARD.encode([seed; 32])
}

fn test_only_values() -> BTreeMap<&'static str, String> {
    BTreeMap::from([
        ("GURINE_ENV", "test".to_owned()),
        ("BILLING_GATEWAY_MODE", "TEST_ONLY".to_owned()),
        ("BILLING_DATABASE_URL", "postgres://redacted".to_owned()),
        ("PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT", key(1)),
        ("PAYMENT_FIXTURE_BILLING_HMAC_KEY_CURRENT", key(2)),
        (IDENTITY_CURRENT_KEY, key(3)),
        (
            IDENTITY_CURRENT_VERSION,
            "test-fixture-identity-v1".to_owned(),
        ),
        (VAULT_CURRENT_KEY, key(4)),
        (
            VAULT_CURRENT_VERSION,
            "test-fixture-billing-vault-v1".to_owned(),
        ),
        (
            "DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN",
            "fixture-secret".to_owned(),
        ),
        ("DONATION_TEST_PAYMENT_OUTCOME", "SUCCEEDED".to_owned()),
    ])
}

fn expect_error(values: BTreeMap<&str, String>, expected: ConfigError) {
    assert_eq!(Config::from_lookup(lookup(values)).err(), Some(expected));
}

#[test]
fn default_development_and_production_are_disabled() -> Result<(), ConfigError> {
    for values in [
        BTreeMap::new(),
        BTreeMap::from([("BILLING_GATEWAY_MODE", "DISABLED".to_owned())]),
        BTreeMap::from([("GURINE_ENV", "production".to_owned())]),
    ] {
        let config = Config::from_lookup(lookup(values))?;
        assert_eq!(config.mode, RuntimeMode::Disabled);
        assert!(config.database_url.is_none());
    }
    Ok(())
}

#[test]
fn test_only_mode_is_forbidden_outside_test_environment() {
    for environment in ["development", "production"] {
        let values = BTreeMap::from([
            ("GURINE_ENV", environment.to_owned()),
            ("BILLING_GATEWAY_MODE", "TEST_ONLY".to_owned()),
        ]);
        expect_error(values, ConfigError::FixtureForbidden);
    }
}

#[test]
fn disabled_runtime_rejects_every_fixture_configuration_family() {
    let fixture_values = [
        ("PAYMENT_FIXTURE_BILLING_HMAC_KEY_CURRENT", key(10)),
        ("PAYMENT_FIXTURE_BILLING_HMAC_KEY_PREVIOUS", key(11)),
        (IDENTITY_CURRENT_KEY, key(12)),
        (IDENTITY_CURRENT_VERSION, "identity-current-v1".to_owned()),
        (IDENTITY_PREVIOUS_KEY, key(13)),
        (IDENTITY_PREVIOUS_VERSION, "identity-previous-v1".to_owned()),
        (VAULT_CURRENT_KEY, key(14)),
        (VAULT_CURRENT_VERSION, "vault-current-v1".to_owned()),
        (VAULT_PREVIOUS_KEY, key(15)),
        (VAULT_PREVIOUS_VERSION, "vault-previous-v1".to_owned()),
        (
            "DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN",
            "test-only-token".to_owned(),
        ),
        ("DONATION_TEST_PAYMENT_OUTCOME", "FAILED".to_owned()),
    ];
    for (name, value) in fixture_values {
        let values = BTreeMap::from([("GURINE_ENV", "production".to_owned()), (name, value)]);
        expect_error(values, ConfigError::FixtureForbidden);
    }
}

#[test]
fn test_only_requires_all_bound_callers_and_ephemeral_token() {
    let config = Config::from_lookup(lookup(test_only_values()));
    assert!(matches!(
        config,
        Ok(Config {
            mode: RuntimeMode::TestOnly,
            database_url: Some(_),
            ..
        })
    ));
}

#[test]
fn test_only_requires_database_url_while_disabled_discards_it() -> Result<(), ConfigError> {
    let mut test_only_without_database = test_only_values();
    test_only_without_database.remove("BILLING_DATABASE_URL");
    expect_error(test_only_without_database, ConfigError::Missing);

    let disabled_with_database = BTreeMap::from([
        ("GURINE_ENV", "production".to_owned()),
        (
            "BILLING_DATABASE_URL",
            "postgres://must-not-be-used".to_owned(),
        ),
    ]);
    let config = Config::from_lookup(lookup(disabled_with_database))?;
    assert_eq!(config.mode, RuntimeMode::Disabled);
    assert!(config.database_url.is_none());
    Ok(())
}

#[test]
fn test_only_payment_outcome_has_no_default_and_is_digest_bound() -> Result<(), ConfigError> {
    let mut values = test_only_values();
    values.remove("DONATION_TEST_PAYMENT_OUTCOME");
    expect_error(values.clone(), ConfigError::Missing);
    values.insert("DONATION_TEST_PAYMENT_OUTCOME", "SUCCESS".to_owned());
    expect_error(values.clone(), ConfigError::Invalid);
    values.insert("DONATION_TEST_PAYMENT_OUTCOME", "FAILED".to_owned());
    let config = Config::from_lookup(lookup(values))?;
    assert_eq!(
        config.test_payment_outcome,
        Some(DonationTestOutcome::Failed)
    );
    assert!(config.test_payment_outcome_config_digest.is_some());
    Ok(())
}

#[test]
fn previous_assertion_keys_cannot_exist_without_current_key() {
    for (current, previous) in [
        (
            "PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT",
            "PUBLIC_WEB_BILLING_HMAC_KEY_PREVIOUS",
        ),
        (
            "PAYMENT_FIXTURE_BILLING_HMAC_KEY_CURRENT",
            "PAYMENT_FIXTURE_BILLING_HMAC_KEY_PREVIOUS",
        ),
    ] {
        let mut values = test_only_values();
        values.remove(current);
        values.insert(previous, key(20));
        expect_error(values, ConfigError::Missing);
    }
}

#[test]
fn previous_versioned_keys_require_complete_key_version_pairs() {
    for (previous_key, previous_version) in [
        (IDENTITY_PREVIOUS_KEY, IDENTITY_PREVIOUS_VERSION),
        (VAULT_PREVIOUS_KEY, VAULT_PREVIOUS_VERSION),
    ] {
        let mut key_only = test_only_values();
        key_only.insert(previous_key, key(21));
        expect_error(key_only, ConfigError::Missing);

        let mut version_only = test_only_values();
        version_only.insert(previous_version, "previous-v1".to_owned());
        expect_error(version_only, ConfigError::Missing);
    }
}

#[test]
fn key_versions_and_material_cannot_be_reused() {
    let mut same_version = test_only_values();
    same_version.insert(IDENTITY_PREVIOUS_KEY, key(22));
    same_version.insert(
        IDENTITY_PREVIOUS_VERSION,
        "test-fixture-identity-v1".to_owned(),
    );
    expect_error(same_version, ConfigError::Invalid);

    let mut same_material = test_only_values();
    same_material.insert(IDENTITY_PREVIOUS_KEY, key(3));
    same_material.insert(IDENTITY_PREVIOUS_VERSION, "identity-previous-v1".to_owned());
    expect_error(same_material, ConfigError::Invalid);

    let mut cross_ring = test_only_values();
    cross_ring.insert(VAULT_CURRENT_KEY, key(3));
    expect_error(cross_ring, ConfigError::Invalid);

    let mut assertion_to_ring = test_only_values();
    assertion_to_ring.insert("PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT", key(3));
    expect_error(assertion_to_ring, ConfigError::Invalid);
}

#[test]
fn debug_output_redacts_database_tokens_and_key_material() -> Result<(), ConfigError> {
    let values = test_only_values();
    let sensitive = [
        values
            .get("BILLING_DATABASE_URL")
            .cloned()
            .unwrap_or_default(),
        values
            .get("PUBLIC_WEB_BILLING_HMAC_KEY_CURRENT")
            .cloned()
            .unwrap_or_default(),
        values
            .get("PAYMENT_FIXTURE_IDENTITY_HMAC_KEY_CURRENT")
            .cloned()
            .unwrap_or_default(),
        values
            .get("DONATION_TEST_PAYMENT_AUTHORIZATION_TOKEN")
            .cloned()
            .unwrap_or_default(),
    ];
    let rendered = format!("{:?}", Config::from_lookup(lookup(values))?);
    for secret in sensitive {
        assert!(!secret.is_empty());
        assert!(!rendered.contains(&secret));
    }
    assert!(rendered.contains("<redacted>"));
    assert!(rendered.contains("<configured>"));

    let assertion = AssertionKeys {
        current: b"raw-current-secret-material-000000".to_vec(),
        previous: Some(b"raw-previous-secret-material-0000".to_vec()),
    };
    let assertion_debug = format!("{assertion:?}");
    assert!(!assertion_debug.contains("raw-current-secret"));
    assert!(!assertion_debug.contains("raw-previous-secret"));

    let versioned = VersionedFixtureKey {
        material: b"raw-versioned-secret-material-0000".to_vec(),
        version: "fixture-version-v1".to_owned(),
    };
    let versioned_debug = format!("{versioned:?}");
    assert!(!versioned_debug.contains("raw-versioned-secret"));
    assert!(versioned_debug.contains("fixture-version-v1"));
    Ok(())
}
