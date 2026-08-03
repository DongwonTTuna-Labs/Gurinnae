use gurine_payment_providers::{
    AttemptId, BillingCredentialUsePolicy, BillingKeyMaterial, BillingKeyVault,
    ChargeAcknowledgement, ChargeInstrument, ChargeRequest, DeterministicFixtureProviderFactory,
    FetchPaymentRequest, FixturePaymentOutcome, IdempotencyKey, InMemoryTestFixtureBillingKeyVault,
    IssueBillingKeyReceipt, IssueBillingKeyRequest, KeyVersion, KrwAmount, MerchantOrderId,
    PaymentLocator, PaymentProvider, PaymentProviderError, PaymentState, ProviderEventIdentity,
    ProviderKind, TestFixtureAuthority,
};
use sha2::{Digest as _, Sha256};
use uuid::Uuid;

const FIXTURE_MARKER: &str = "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY";
const OBSERVED_AT: i64 = 1_800_000_000;

#[tokio::test]
async fn shared_factory_accepts_multiple_jobs_and_replays_exact_mutations() {
    let factory = factory(FixturePaymentOutcome::Succeeded);
    let provider = factory
        .provider(ProviderKind::TossPayments)
        .expect("dynamic Toss provider");
    let first = issue(
        &factory,
        provider.as_ref(),
        ProviderKind::TossPayments,
        0x1001,
        0x1101,
        BillingCredentialUsePolicy::SingleCharge,
    )
    .await;
    let first_replay = issue(
        &factory,
        provider.as_ref(),
        ProviderKind::TossPayments,
        0x1001,
        0x1101,
        BillingCredentialUsePolicy::SingleCharge,
    )
    .await;
    assert_eq!(first.transport, first_replay.transport);
    let second = issue(
        &factory,
        provider.as_ref(),
        ProviderKind::TossPayments,
        0x1002,
        0x1102,
        BillingCredentialUsePolicy::Recurring,
    )
    .await;
    let vault = fixture_vault();
    let first_handle = vault
        .store(
            first.binding_id,
            first.material,
            BillingCredentialUsePolicy::SingleCharge,
        )
        .expect("single-charge store");
    let second_handle = vault
        .store(
            second.binding_id,
            second.material,
            BillingCredentialUsePolicy::Recurring,
        )
        .expect("recurring store");

    let first_material = vault
        .take_for_charge(&first_handle)
        .expect("one single-charge release");
    let first_charge = charge_fixture(0x1201, 0x1301, 1_000);
    let first_ack = charge(provider.as_ref(), &first_material, &first_charge).await;
    let replay = charge(provider.as_ref(), &first_material, &first_charge).await;
    assert_eq!(first_ack, replay);
    assert!(vault.take_for_charge(&first_handle).is_err());

    let second_material = vault
        .take_for_charge(&second_handle)
        .expect("recurring release");
    let second_charge = charge_fixture(0x1202, 0x1302, 2_000);
    let second_ack = charge(provider.as_ref(), &second_material, &second_charge).await;
    assert_ne!(first_ack.locator, second_ack.locator);
    let fetched = fetch(provider.as_ref(), &second_charge, &second_ack).await;
    assert_eq!(fetched.state, PaymentState::Succeeded);
    assert!(vault.take_for_charge(&second_handle).is_ok());
}

#[tokio::test]
async fn changed_request_conflicts_without_blocking_distinct_idempotency_keys() {
    let factory = factory(FixturePaymentOutcome::Succeeded);
    let provider = factory
        .provider(ProviderKind::KakaoPay)
        .expect("dynamic Kakao provider");
    let issued = issue(
        &factory,
        provider.as_ref(),
        ProviderKind::KakaoPay,
        0x2001,
        0x2101,
        BillingCredentialUsePolicy::Recurring,
    )
    .await;
    let issue_conflict = issue_result(
        &factory,
        provider.as_ref(),
        ProviderKind::KakaoPay,
        0x2002,
        0x2101,
        BillingCredentialUsePolicy::Recurring,
    )
    .await;
    assert!(matches!(
        issue_conflict,
        Err(PaymentProviderError::FixtureMismatch)
    ));

    let charge_claim = charge_fixture(0x2201, 0x2301, 1_000);
    charge(provider.as_ref(), &issued.material, &charge_claim).await;
    let changed_amount = ChargeFixture {
        amount: KrwAmount::try_new(1_001).expect("changed fixture amount"),
        ..charge_claim.clone()
    };
    assert_eq!(
        charge_result(provider.as_ref(), &issued.material, &changed_amount).await,
        Err(PaymentProviderError::FixtureMismatch)
    );
    let changed_key_same_order = ChargeFixture {
        idempotency_key: key(0x2302),
        ..charge_claim
    };
    assert_eq!(
        charge_result(provider.as_ref(), &issued.material, &changed_key_same_order).await,
        Err(PaymentProviderError::FixtureMismatch)
    );
}

#[tokio::test]
async fn webhook_before_runtime_completion_fetches_truth_and_matches_claim_expectation() {
    let factory = factory(FixturePaymentOutcome::Succeeded);
    for (offset, provider_kind) in [
        ProviderKind::TossPayments,
        ProviderKind::KakaoPay,
        ProviderKind::Stripe,
    ]
    .into_iter()
    .enumerate()
    {
        verify_webhook_round_trip(&factory, provider_kind, 0x3000 + offset as u128 * 0x100).await;
    }
}

#[tokio::test]
async fn explicit_outcome_drives_fetch_and_invalid_clock_is_rejected() {
    let authority = authority();
    assert!(matches!(
        DeterministicFixtureProviderFactory::new(authority, FixturePaymentOutcome::Succeeded, 0,),
        Err(PaymentProviderError::InvalidInput)
    ));
    for (offset, outcome, expected) in [
        (
            0_u128,
            FixturePaymentOutcome::Pending,
            PaymentState::Pending,
        ),
        (1, FixturePaymentOutcome::Succeeded, PaymentState::Succeeded),
        (2, FixturePaymentOutcome::Failed, PaymentState::Failed),
        (3, FixturePaymentOutcome::Canceled, PaymentState::Canceled),
    ] {
        let factory = factory(outcome);
        let provider = factory
            .provider(ProviderKind::Stripe)
            .expect("dynamic Stripe provider");
        let issued = issue(
            &factory,
            provider.as_ref(),
            ProviderKind::Stripe,
            0x4001 + offset,
            0x4101 + offset,
            BillingCredentialUsePolicy::Recurring,
        )
        .await;
        let claim = charge_fixture(0x4201 + offset, 0x4301 + offset, 1_000);
        let acknowledgement = charge(provider.as_ref(), &issued.material, &claim).await;
        assert_eq!(
            fetch(provider.as_ref(), &claim, &acknowledgement)
                .await
                .state,
            expected
        );
    }
}

async fn verify_webhook_round_trip(
    factory: &DeterministicFixtureProviderFactory,
    provider_kind: ProviderKind,
    seed: u128,
) {
    let provider = factory.provider(provider_kind).expect("dynamic provider");
    let issued = issue(
        factory,
        provider.as_ref(),
        provider_kind,
        seed + 1,
        seed + 2,
        BillingCredentialUsePolicy::Recurring,
    )
    .await;
    let claim = charge_fixture(seed + 3, seed + 4, 1_000);
    let expected_payment_id_digest = factory
        .expected_provider_payment_id_digest(
            provider_kind,
            claim.idempotency_key,
            &claim.merchant_order_id,
            claim.amount,
        )
        .expect("closed fixture payment-ID expectation");
    assert_eq!(
        format!("{expected_payment_id_digest:?}"),
        "FixtureProviderPaymentIdDigest(<sha256>)"
    );
    charge(provider.as_ref(), &issued.material, &claim).await;
    // No caller-side/DB completion has happened: the provider acknowledgement
    // alone is sufficient for a webhook hint, whose authenticated fetch is truth.
    let webhook = factory
        .webhook_for_payment(
            provider_kind,
            ProviderEventIdentity::try_new(format!("fixture-event-{seed}")).expect("fixture event"),
            &PaymentLocator::MerchantOrderId(claim.merchant_order_id.clone()),
            OBSERVED_AT,
        )
        .expect("closed fixture webhook");
    let hint = provider
        .verify_webhook(webhook.envelope())
        .expect("verified fixture webhook hint");
    assert_eq!(
        hint.authentication().is_verified(),
        provider_kind == ProviderKind::Stripe
    );
    let fetched = provider
        .fetch_payment(&FetchPaymentRequest::from_webhook(
            &hint,
            claim.attempt_id,
            claim.merchant_order_id,
            claim.amount,
        ))
        .await
        .expect("webhook-authoritative fetch");
    assert_eq!(fetched.state, PaymentState::Succeeded);
    assert_eq!(
        expected_payment_id_digest.as_str(),
        provider_payment_id_digest(fetched.provider_payment_id.as_str())
    );
}

fn provider_payment_id_digest(provider_payment_id: &str) -> String {
    let domain = b"gurine-provider-payment-id.v1\0";
    let mut preimage = Vec::with_capacity(domain.len() + provider_payment_id.len());
    preimage.extend_from_slice(domain);
    preimage.extend_from_slice(provider_payment_id.as_bytes());
    format!("{:x}", Sha256::digest(preimage))
}

async fn issue(
    factory: &DeterministicFixtureProviderFactory,
    provider: &dyn PaymentProvider,
    provider_kind: ProviderKind,
    binding_seed: u128,
    key_seed: u128,
    use_policy: BillingCredentialUsePolicy,
) -> IssueBillingKeyReceipt {
    issue_result(
        factory,
        provider,
        provider_kind,
        binding_seed,
        key_seed,
        use_policy,
    )
    .await
    .expect("dynamic fixture issue")
}

async fn issue_result(
    factory: &DeterministicFixtureProviderFactory,
    provider: &dyn PaymentProvider,
    provider_kind: ProviderKind,
    binding_seed: u128,
    key_seed: u128,
    use_policy: BillingCredentialUsePolicy,
) -> Result<IssueBillingKeyReceipt, PaymentProviderError> {
    let binding_id = Uuid::from_u128(binding_seed);
    let idempotency_key = key(key_seed);
    let request = IssueBillingKeyRequest {
        binding_id,
        idempotency_key,
        use_policy,
        authorization: factory.issue_authorization(provider_kind, binding_id, idempotency_key)?,
    };
    provider.issue_billing_key(&request).await
}

#[derive(Clone)]
struct ChargeFixture {
    attempt_id: AttemptId,
    idempotency_key: IdempotencyKey,
    merchant_order_id: MerchantOrderId,
    amount: KrwAmount,
}

fn charge_fixture(attempt_seed: u128, key_seed: u128, amount: i64) -> ChargeFixture {
    ChargeFixture {
        attempt_id: AttemptId::new(Uuid::from_u128(attempt_seed)),
        idempotency_key: key(key_seed),
        merchant_order_id: MerchantOrderId::try_new(format!("fixture-order-{attempt_seed}"))
            .expect("fixture order"),
        amount: KrwAmount::try_new(amount).expect("fixture amount"),
    }
}

async fn charge(
    provider: &dyn PaymentProvider,
    material: &BillingKeyMaterial,
    fixture: &ChargeFixture,
) -> ChargeAcknowledgement {
    charge_result(provider, material, fixture)
        .await
        .expect("dynamic fixture charge")
}

async fn charge_result(
    provider: &dyn PaymentProvider,
    material: &BillingKeyMaterial,
    fixture: &ChargeFixture,
) -> Result<ChargeAcknowledgement, PaymentProviderError> {
    provider
        .charge(ChargeRequest {
            attempt_id: fixture.attempt_id,
            idempotency_key: fixture.idempotency_key,
            merchant_order_id: &fixture.merchant_order_id,
            amount: fixture.amount,
            instrument: ChargeInstrument::Stored(material),
        })
        .await
}

async fn fetch(
    provider: &dyn PaymentProvider,
    fixture: &ChargeFixture,
    acknowledgement: &ChargeAcknowledgement,
) -> gurine_payment_providers::FetchedPayment {
    provider
        .fetch_payment(&FetchPaymentRequest::from_charge(
            acknowledgement.transport.provider,
            acknowledgement,
            fixture.amount,
        ))
        .await
        .expect("authoritative dynamic fixture fetch")
}

fn factory(outcome: FixturePaymentOutcome) -> DeterministicFixtureProviderFactory {
    DeterministicFixtureProviderFactory::new(authority(), outcome, OBSERVED_AT)
        .expect("dynamic fixture factory")
}

fn fixture_vault() -> InMemoryTestFixtureBillingKeyVault {
    InMemoryTestFixtureBillingKeyVault::new(
        authority(),
        vec![0x42; 32],
        KeyVersion::try_new("dynamic-fixture-v1".to_owned()).expect("fixture key version"),
    )
    .expect("fixture vault")
}

fn authority() -> TestFixtureAuthority {
    TestFixtureAuthority::try_new(FIXTURE_MARKER).expect("fixture authority")
}

fn key(value: u128) -> IdempotencyKey {
    IdempotencyKey::new(Uuid::from_u128(value))
}
