use std::{sync::Arc, thread};

use gurine_payment_providers::{
    BillingCredentialUsePolicy, BillingKeyMaterial, BillingKeyVault, DisabledLiveBillingKeyVault,
    InMemoryTestFixtureBillingKeyVault, KeyVersion, PaymentProviderError, ProviderKind, SecretText,
    TestFixtureAuthority, VaultError,
};
use uuid::Uuid;

const FIXTURE_MARKER: &str = "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY";
const VAULT_HMAC_KEY: &str = "fixture-vault-hmac-key-at-least-32-bytes";

#[test]
fn single_charge_is_atomically_consumed_and_secret_authority_is_destroyed() {
    let vault = Arc::new(vault());
    let binding_id = Uuid::from_u128(0x40);
    let handle = vault
        .store(
            binding_id,
            toss_material("single-billing-secret", "single-customer-secret"),
            BillingCredentialUsePolicy::SingleCharge,
        )
        .expect("single-charge fixture store");
    assert_eq!(handle.secret_reference, expected_reference(binding_id));
    let workers = (0..8)
        .map(|_| {
            let vault = Arc::clone(&vault);
            let handle = handle.clone();
            thread::spawn(move || {
                vault
                    .take_for_charge(&handle)
                    .map(|material| material.provider())
            })
        })
        .collect::<Vec<_>>();
    let outcomes = workers
        .into_iter()
        .map(|worker| worker.join().expect("vault worker"))
        .collect::<Vec<_>>();

    assert_eq!(
        outcomes
            .iter()
            .filter(|outcome| **outcome == Ok(ProviderKind::TossPayments))
            .count(),
        1
    );
    assert_eq!(
        outcomes
            .iter()
            .filter(|outcome| **outcome == Err(VaultError::Missing))
            .count(),
        7
    );
    assert_eq!(vault.destroy(&handle), Err(VaultError::Missing));
}

#[test]
fn recurring_remains_until_destroy_and_cannot_be_coerced_to_single_charge() {
    let vault = vault();
    let binding_id = Uuid::from_u128(0x41);
    let handle = vault
        .store(
            binding_id,
            toss_material("recurring-billing-secret", "recurring-customer-secret"),
            BillingCredentialUsePolicy::Recurring,
        )
        .expect("recurring fixture store");
    assert_eq!(handle.secret_reference, expected_reference(binding_id));
    let replay = vault
        .store(
            binding_id,
            toss_material("recurring-billing-secret", "recurring-customer-secret"),
            BillingCredentialUsePolicy::Recurring,
        )
        .expect("same recurring fixture replay");
    assert_eq!(handle, replay);
    assert_eq!(
        vault
            .take_for_charge(&handle)
            .map(|material| material.provider()),
        Ok(ProviderKind::TossPayments)
    );
    assert_eq!(
        vault
            .take_for_charge(&handle)
            .map(|material| material.provider()),
        Ok(ProviderKind::TossPayments)
    );

    let mut changed_policy = handle.clone();
    changed_policy.use_policy = BillingCredentialUsePolicy::SingleCharge;
    assert_eq!(
        vault.take_for_charge(&changed_policy).map(|_| ()),
        Err(VaultError::UsePolicyMismatch)
    );
    assert_eq!(
        vault.store(
            binding_id,
            toss_material("recurring-billing-secret", "recurring-customer-secret"),
            BillingCredentialUsePolicy::SingleCharge,
        ),
        Err(VaultError::UsePolicyMismatch)
    );
    vault.destroy(&handle).expect("explicit recurring destroy");
    assert_eq!(
        vault.take_for_charge(&handle).map(|_| ()),
        Err(VaultError::Missing)
    );
}

#[test]
fn handles_and_vault_debug_never_disclose_secret_material() {
    let vault = vault();
    let handle = vault
        .store(
            Uuid::from_u128(0x42),
            toss_material("redacted-billing-secret", "redacted-customer-secret"),
            BillingCredentialUsePolicy::Recurring,
        )
        .expect("redaction fixture store");
    assert_eq!(
        handle.secret_reference,
        "fixture://billing-key/00000000-0000-0000-0000-000000000042@v2"
    );
    let observed = format!("{vault:?} {handle:?}");
    for secret in [
        VAULT_HMAC_KEY,
        "redacted-billing-secret",
        "redacted-customer-secret",
        &handle.secret_reference,
        &handle.material_hmac,
    ] {
        assert!(!observed.contains(secret), "secret leaked through Debug");
    }
}

#[test]
fn tampered_handle_fields_are_rejected_without_destroying_the_valid_entry() {
    let vault = vault();
    let handle = vault
        .store(
            Uuid::from_u128(0x45),
            toss_material("tamper-billing-secret", "tamper-customer-secret"),
            BillingCredentialUsePolicy::Recurring,
        )
        .expect("tamper fixture store");
    let mut wrong_provider = handle.clone();
    wrong_provider.provider = ProviderKind::KakaoPay;
    let mut wrong_hmac = handle.clone();
    wrong_hmac.material_hmac.push('0');
    let mut wrong_binding_reference = handle.clone();
    wrong_binding_reference.secret_reference = expected_reference(Uuid::from_u128(0x46));
    let mut legacy_reference = handle.clone();
    legacy_reference.secret_reference =
        format!("fixture-vault://payment-method/{}@v2", handle.binding_id);
    let mut wrong_locator_version = handle.clone();
    wrong_locator_version.secret_reference =
        format!("fixture://billing-key/{}@v3", handle.binding_id);
    let mut wrong_version = handle.clone();
    wrong_version.hmac_key_version =
        KeyVersion::try_new("fixture-v3".to_owned()).expect("different fixture key version");

    for tampered in [
        wrong_provider,
        wrong_hmac,
        wrong_binding_reference,
        legacy_reference,
        wrong_locator_version,
        wrong_version,
    ] {
        assert_eq!(
            vault.take_for_charge(&tampered).map(|_| ()),
            Err(VaultError::Integrity)
        );
    }
    assert_eq!(
        vault
            .take_for_charge(&handle)
            .map(|material| material.provider()),
        Ok(ProviderKind::TossPayments)
    );
}

#[test]
fn live_vault_lifecycle_is_fail_closed() {
    let fixture_vault = vault();
    let handle = fixture_vault
        .store(
            Uuid::from_u128(0x43),
            toss_material("disabled-billing-secret", "disabled-customer-secret"),
            BillingCredentialUsePolicy::SingleCharge,
        )
        .expect("handle fixture");
    let live = DisabledLiveBillingKeyVault;
    assert_eq!(
        live.store(
            Uuid::from_u128(0x44),
            toss_material("live-billing-secret", "live-customer-secret"),
            BillingCredentialUsePolicy::Recurring,
        ),
        Err(VaultError::LiveVaultDisabled)
    );
    assert_eq!(
        live.take_for_charge(&handle).map(|_| ()),
        Err(VaultError::LiveVaultDisabled)
    );
    assert_eq!(live.destroy(&handle), Err(VaultError::LiveVaultDisabled));
}

fn vault() -> InMemoryTestFixtureBillingKeyVault {
    InMemoryTestFixtureBillingKeyVault::new(
        TestFixtureAuthority::try_new(FIXTURE_MARKER).expect("fixture authority"),
        VAULT_HMAC_KEY.as_bytes().to_vec(),
        KeyVersion::try_new("fixture-v2".to_owned()).expect("fixture key version"),
    )
    .expect("fixture vault")
}

fn expected_reference(binding_id: Uuid) -> String {
    format!("fixture://billing-key/{binding_id}@v2")
}

fn toss_material(billing_key: &str, customer_key: &str) -> BillingKeyMaterial {
    BillingKeyMaterial::TossPayments {
        billing_key: secret(billing_key),
        customer_key: secret(customer_key),
    }
}

fn secret(value: &str) -> SecretText {
    SecretText::try_new(value.to_owned())
        .unwrap_or_else(|error: PaymentProviderError| panic!("valid test fixture secret: {error}"))
}
