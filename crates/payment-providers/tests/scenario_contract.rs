use gurine_payment_providers::{
    AttemptId, BillingCredentialUsePolicy, ChargeInstrument, ChargeRequest, FetchPaymentRequest,
    FixtureProviderBundle, FixtureTransport, IdempotencyKey, KrwAmount, MerchantOrderId,
    PaymentState, PaymentTransport, ProviderEventIdentity, ProviderFixtureScenario, ProviderKind,
    ProviderPaymentId, TestFixtureAuthority, TransportMode,
};
use uuid::Uuid;

const FIXTURE_MARKER: &str = "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY";
const NOW: i64 = 1_700_000_100;

#[test]
fn fixture_transport_reports_test_mode() {
    assert_eq!(
        FixtureTransport::new(Vec::new()).mode(),
        TransportMode::TestFixture
    );
}

#[tokio::test]
async fn high_level_scenarios_need_no_service_wire_fixture() {
    run_high_level_scenario(ProviderKind::TossPayments, 0x50).await;
    run_high_level_scenario(ProviderKind::KakaoPay, 0x60).await;
    run_high_level_scenario(ProviderKind::Stripe, 0x70).await;
}

async fn run_high_level_scenario(provider_kind: ProviderKind, base: u128) {
    let scenario = ProviderFixtureScenario {
        provider: provider_kind,
        binding_id: Uuid::from_u128(base),
        use_policy: BillingCredentialUsePolicy::SingleCharge,
        attempt_id: AttemptId::new(Uuid::from_u128(base + 1)),
        issue_idempotency_key: key(base + 2),
        charge_idempotency_key: key(base + 3),
        refund_idempotency_key: key(base + 4),
        merchant_order_id: MerchantOrderId::try_new(format!("fixture-order-{base}"))
            .expect("scenario order"),
        amount: KrwAmount::try_new(4000).expect("scenario amount"),
        terminal_state: PaymentState::Succeeded,
        event_identity: ProviderEventIdentity::try_new(format!("fixture-event-{base}"))
            .expect("scenario event"),
        provider_payment_id: ProviderPaymentId::try_new(format!("fixture-payment-{base}"))
            .expect("scenario payment"),
        observed_at_unix: NOW,
    };
    let authority = TestFixtureAuthority::try_new(FIXTURE_MARKER).expect("fixture authority");
    let bundle = FixtureProviderBundle::deterministic(authority, scenario)
        .expect("deterministic provider bundle");
    let issue = bundle
        .provider
        .issue_billing_key(&bundle.issue_request)
        .await
        .expect("scenario issue");
    assert_eq!(issue.use_policy, BillingCredentialUsePolicy::SingleCharge);
    let acknowledgement = bundle
        .provider
        .charge(ChargeRequest {
            attempt_id: bundle.scenario.attempt_id,
            idempotency_key: bundle.scenario.charge_idempotency_key,
            merchant_order_id: &bundle.scenario.merchant_order_id,
            amount: bundle.scenario.amount,
            instrument: ChargeInstrument::Stored(&issue.material),
        })
        .await
        .expect("scenario charge");
    let hint = bundle
        .provider
        .verify_webhook(bundle.webhook.envelope())
        .expect("scenario webhook hint");
    assert_eq!(
        hint.authentication().is_verified(),
        provider_kind == ProviderKind::Stripe
    );
    let fetched = bundle
        .provider
        .fetch_payment(&FetchPaymentRequest::from_webhook(
            &hint,
            bundle.scenario.attempt_id,
            bundle.scenario.merchant_order_id.clone(),
            bundle.scenario.amount,
        ))
        .await
        .expect("scenario fetch truth");
    assert_eq!(fetched.state, PaymentState::Succeeded);
    assert_eq!(acknowledgement.attempt_id, fetched.attempt_id);
}

fn key(value: u128) -> IdempotencyKey {
    IdempotencyKey::new(Uuid::from_u128(value))
}
