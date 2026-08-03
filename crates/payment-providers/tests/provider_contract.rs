use std::sync::Arc;

use gurine_payment_providers::{
    AdapterEnvironment, AttemptId, BillingAuthorization, BillingCredentialUsePolicy,
    ChargeInstrument, ChargeRequest, FetchPaymentRequest, FixtureExchange, FixtureTransport,
    IdempotencyKey, IssueBillingKeyRequest, KeyVersion, KrwAmount, MerchantOrderId,
    PaymentProvider, PaymentProviderError, PaymentState, PaymentTransport, ProviderKind,
    ProviderOperation, RefundRequest, SecretText, TestFixtureAuthority, WebhookAuthentication,
    WebhookEnvelope, WebhookHeaders, WebhookHint, WebhookReplayPolicy, WebhookSigningKey,
    providers::{kakao_pay::KakaoPay, stripe::Stripe, toss_payments::TossPayments},
};
use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::Sha256;
use uuid::Uuid;

const FIXTURE_MARKER: &str = "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY";
const NOW: i64 = 1_700_000_100;

fn fixture_bytes(value: &str) -> Vec<u8> {
    value.trim().as_bytes().to_vec()
}

fn authority() -> TestFixtureAuthority {
    TestFixtureAuthority::try_new(FIXTURE_MARKER).expect("fixture authority")
}

fn secret(value: &str) -> SecretText {
    SecretText::try_new(value.to_owned()).expect("fixture secret")
}

fn key(value: u128) -> IdempotencyKey {
    IdempotencyKey::new(Uuid::from_u128(value))
}

#[test]
fn manifest_declares_fixture_authority_and_fetch_only_truth() {
    let manifest: Value = serde_json::from_str(include_str!("fixtures/manifest.json"))
        .expect("fixture manifest JSON");
    assert_eq!(manifest["authority"], FIXTURE_MARKER);
    assert_eq!(manifest["executionMode"], "TEST_FIXTURE_ONLY");
    assert_eq!(manifest["scheduleOwnership"], "MERCHANT_SCHEDULED");
    assert_eq!(manifest["webhookTruth"], "AUTHENTICATED_FETCH_ONLY");
    assert_eq!(manifest["currency"], "KRW");
    assert_eq!(manifest["providers"].as_array().map(Vec::len), Some(3));
}

#[tokio::test]
async fn toss_fixture_is_merchant_scheduled_and_fetch_is_truth() {
    let issue_key = key(0x12);
    let charge_key = key(0x13);
    let refund_key = key(0x14);
    let transport = toss_transport(issue_key, charge_key, refund_key);
    let provider = TossPayments::new(
        AdapterEnvironment::TestFixture(authority()),
        transport.clone(),
    )
    .expect("fixture Toss adapter");
    assert_fixture_capabilities(&provider, ProviderKind::TossPayments);

    let issue = provider
        .issue_billing_key(&IssueBillingKeyRequest {
            binding_id: Uuid::from_u128(0x10),
            idempotency_key: issue_key,
            use_policy: BillingCredentialUsePolicy::SingleCharge,
            authorization: BillingAuthorization::TossPayments {
                auth_key: secret("toss-auth-test"),
                customer_key: secret("toss-customer-test"),
            },
        })
        .await
        .expect("fixture billing key");
    assert_eq!(issue.use_policy, BillingCredentialUsePolicy::SingleCharge);
    assert_redacted(&format!("{issue:?}"), &toss_secrets());

    let attempt_id = AttemptId::new(Uuid::from_u128(0x11));
    let order = MerchantOrderId::try_new("order-toss-fixture-1".to_owned()).expect("fixture order");
    let amount = KrwAmount::try_new(1000).expect("fixture KRW");
    let acknowledgement = provider
        .charge(ChargeRequest {
            attempt_id,
            idempotency_key: charge_key,
            merchant_order_id: &order,
            amount,
            instrument: ChargeInstrument::Stored(&issue.material),
        })
        .await
        .expect("fixture charge acknowledgement");
    let fetched = provider
        .fetch_payment(&FetchPaymentRequest::from_charge(
            ProviderKind::TossPayments,
            &acknowledgement,
            amount,
        ))
        .await
        .expect("authoritative fixture fetch");
    assert_eq!(fetched.state, PaymentState::Succeeded);

    let headers = WebhookHeaders::none();
    let hint = provider
        .verify_webhook(WebhookEnvelope {
            headers: &headers,
            body: include_str!("fixtures/toss-payments/webhook.json")
                .trim()
                .as_bytes(),
            replay_policy: replay_policy(),
        })
        .expect("unsigned webhook hint");
    assert_eq!(
        hint.authentication(),
        &WebhookAuthentication::NotAvailableFetchRequired
    );
    assert!(!hint.authentication().is_verified());

    provider
        .refund(&RefundRequest {
            attempt_id,
            idempotency_key: refund_key,
            payment_id: fetched.provider_payment_id,
            amount,
        })
        .await
        .expect("fixture refund acknowledgement");
    assert_eq!(transport.remaining(), Ok(0));
}

#[tokio::test]
async fn kakao_fixture_keeps_unsigned_webhook_as_hint() {
    let issue_key = key(0x22);
    let charge_key = key(0x23);
    let refund_key = key(0x24);
    let transport = kakao_transport(issue_key, charge_key, refund_key);
    let provider = KakaoPay::new(
        AdapterEnvironment::TestFixture(authority()),
        transport.clone(),
    )
    .expect("fixture Kakao adapter");
    assert_fixture_capabilities(&provider, ProviderKind::KakaoPay);
    let issue = provider
        .issue_billing_key(&IssueBillingKeyRequest {
            binding_id: Uuid::from_u128(0x20),
            idempotency_key: issue_key,
            use_policy: BillingCredentialUsePolicy::Recurring,
            authorization: BillingAuthorization::KakaoPay {
                transaction_id: secret("kakao-tid-test"),
                approval_token: secret("kakao-approval-test"),
                partner_user_id: secret("kakao-user-test"),
            },
        })
        .await
        .expect("fixture Kakao SID");
    assert_eq!(issue.use_policy, BillingCredentialUsePolicy::Recurring);
    let attempt_id = AttemptId::new(Uuid::from_u128(0x21));
    let order =
        MerchantOrderId::try_new("order-kakao-fixture-1".to_owned()).expect("fixture order");
    let amount = KrwAmount::try_new(2000).expect("fixture KRW");
    let acknowledgement = provider
        .charge(ChargeRequest {
            attempt_id,
            idempotency_key: charge_key,
            merchant_order_id: &order,
            amount,
            instrument: ChargeInstrument::Stored(&issue.material),
        })
        .await
        .expect("fixture charge acknowledgement");
    let fetched = provider
        .fetch_payment(&FetchPaymentRequest::from_charge(
            ProviderKind::KakaoPay,
            &acknowledgement,
            amount,
        ))
        .await
        .expect("authoritative fixture fetch");
    assert_eq!(fetched.state, PaymentState::Succeeded);

    let headers = WebhookHeaders::none();
    let hint = provider
        .verify_webhook(WebhookEnvelope {
            headers: &headers,
            body: include_str!("fixtures/kakao-pay/webhook.json")
                .trim()
                .as_bytes(),
            replay_policy: replay_policy(),
        })
        .expect("unsigned webhook hint");
    assert!(!hint.authentication().is_verified());

    provider
        .refund(&RefundRequest {
            attempt_id,
            idempotency_key: refund_key,
            payment_id: fetched.provider_payment_id,
            amount,
        })
        .await
        .expect("fixture refund acknowledgement");
    assert_eq!(transport.remaining(), Ok(0));
}

#[tokio::test]
async fn stripe_fixture_verifies_signature_then_requires_fetch() {
    let issue_key = key(0x32);
    let charge_key = key(0x33);
    let refund_key = key(0x34);
    let transport = stripe_transport(issue_key, charge_key, refund_key);
    let signing_key = b"stripe-test-webhook-key-32-bytes-minimum";
    let provider = Stripe::new(
        AdapterEnvironment::TestFixture(authority()),
        transport.clone(),
        WebhookSigningKey::try_new(signing_key.to_vec()).expect("fixture signing key"),
        KeyVersion::try_new("fixture-v1".to_owned()).expect("fixture key version"),
    )
    .expect("fixture Stripe adapter");
    assert_fixture_capabilities(&provider, ProviderKind::Stripe);
    let issue = provider
        .issue_billing_key(&IssueBillingKeyRequest {
            binding_id: Uuid::from_u128(0x30),
            idempotency_key: issue_key,
            use_policy: BillingCredentialUsePolicy::SingleCharge,
            authorization: BillingAuthorization::Stripe {
                customer_id: secret("stripe-customer-test"),
                payment_method_id: secret("stripe-payment-method-test"),
            },
        })
        .await
        .expect("fixture Stripe payment method");
    assert_eq!(issue.use_policy, BillingCredentialUsePolicy::SingleCharge);
    let attempt_id = AttemptId::new(Uuid::from_u128(0x31));
    let order =
        MerchantOrderId::try_new("order-stripe-fixture-1".to_owned()).expect("fixture order");
    let amount = KrwAmount::try_new(3000).expect("fixture KRW");
    let _acknowledgement = provider
        .charge(ChargeRequest {
            attempt_id,
            idempotency_key: charge_key,
            merchant_order_id: &order,
            amount,
            instrument: ChargeInstrument::Stored(&issue.material),
        })
        .await
        .expect("fixture charge acknowledgement");

    let hint = verified_stripe_hint(&provider, signing_key);

    let fetched = provider
        .fetch_payment(&FetchPaymentRequest::from_webhook(
            &hint, attempt_id, order, amount,
        ))
        .await
        .expect("authoritative fixture fetch");
    assert_eq!(fetched.state, PaymentState::Succeeded);
    provider
        .refund(&RefundRequest {
            attempt_id,
            idempotency_key: refund_key,
            payment_id: fetched.provider_payment_id,
            amount,
        })
        .await
        .expect("fixture refund acknowledgement");
    assert_eq!(transport.remaining(), Ok(0));
}

fn verified_stripe_hint(provider: &Stripe, signing_key: &[u8]) -> WebhookHint {
    let body = include_str!("fixtures/stripe/webhook.json")
        .trim()
        .as_bytes();
    let signature = stripe_signature(signing_key, NOW, body);
    let headers = WebhookHeaders::stripe(secret(&signature));
    let hint = provider
        .verify_webhook(WebhookEnvelope {
            headers: &headers,
            body,
            replay_policy: replay_policy(),
        })
        .expect("verified Stripe hint");
    assert!(hint.authentication().is_verified());
    assert_redacted(
        &format!("{hint:?}"),
        &[signature.as_str(), "stripe-event-test"],
    );
    hint
}

#[test]
fn stripe_rejects_bad_signature_and_stale_timestamp() {
    let transport = Arc::new(FixtureTransport::new(Vec::new()));
    let signing_key = b"stripe-test-webhook-key-32-bytes-minimum";
    let provider = Stripe::new(
        AdapterEnvironment::TestFixture(authority()),
        transport,
        WebhookSigningKey::try_new(signing_key.to_vec()).expect("fixture signing key"),
        KeyVersion::try_new("fixture-v1".to_owned()).expect("fixture key version"),
    )
    .expect("fixture Stripe adapter");
    let body = include_str!("fixtures/stripe/webhook.json")
        .trim()
        .as_bytes();
    let invalid_headers =
        WebhookHeaders::stripe(secret(&format!("t={NOW},v1={}", "00".repeat(32))));
    assert_eq!(
        provider.verify_webhook(WebhookEnvelope {
            headers: &invalid_headers,
            body,
            replay_policy: replay_policy(),
        }),
        Err(PaymentProviderError::WebhookAuthenticationFailed)
    );

    let stale_time = NOW - 301;
    let stale_headers =
        WebhookHeaders::stripe(secret(&stripe_signature(signing_key, stale_time, body)));
    assert_eq!(
        provider.verify_webhook(WebhookEnvelope {
            headers: &stale_headers,
            body,
            replay_policy: replay_policy(),
        }),
        Err(PaymentProviderError::WebhookReplayPolicyFailed)
    );
}

#[test]
fn production_and_live_transport_are_fail_closed() {
    let fixture: Arc<dyn PaymentTransport> = Arc::new(FixtureTransport::new(Vec::new()));
    assert!(matches!(
        TossPayments::new(AdapterEnvironment::Production, fixture),
        Err(PaymentProviderError::LiveExecutionDisabled)
    ));
    let live: Arc<dyn PaymentTransport> = Arc::new(gurine_payment_providers::DisabledLiveTransport);
    assert!(matches!(
        KakaoPay::new(AdapterEnvironment::TestFixture(authority()), live),
        Err(PaymentProviderError::LiveExecutionDisabled)
    ));
    assert_eq!(
        TestFixtureAuthority::try_new("TEST_FIXTURE_ONLY"),
        Err(PaymentProviderError::InvalidInput)
    );
}

#[test]
fn amount_type_rejects_non_krw_and_non_positive_values() {
    assert_eq!(
        KrwAmount::try_from_currency(1000, "USD"),
        Err(PaymentProviderError::InvalidInput)
    );
    assert_eq!(
        KrwAmount::try_new(0),
        Err(PaymentProviderError::InvalidInput)
    );
}

fn exchange(
    provider: ProviderKind,
    operation: ProviderOperation,
    idempotency_key: Option<IdempotencyKey>,
    request: &str,
    response: &str,
) -> FixtureExchange {
    FixtureExchange::new(
        provider,
        operation,
        idempotency_key,
        fixture_bytes(request),
        200,
        fixture_bytes(response),
    )
    .expect("fixture exchange")
}

fn toss_transport(
    issue_key: IdempotencyKey,
    charge_key: IdempotencyKey,
    refund_key: IdempotencyKey,
) -> Arc<FixtureTransport> {
    Arc::new(FixtureTransport::new(vec![
        exchange(
            ProviderKind::TossPayments,
            ProviderOperation::IssueBillingKey,
            Some(issue_key),
            include_str!("fixtures/toss-payments/issue-request.json"),
            include_str!("fixtures/toss-payments/issue-response.json"),
        ),
        exchange(
            ProviderKind::TossPayments,
            ProviderOperation::Charge,
            Some(charge_key),
            include_str!("fixtures/toss-payments/charge-request.json"),
            include_str!("fixtures/toss-payments/charge-response.json"),
        ),
        exchange(
            ProviderKind::TossPayments,
            ProviderOperation::FetchPayment,
            None,
            include_str!("fixtures/toss-payments/fetch-request.json"),
            include_str!("fixtures/toss-payments/fetch-response.json"),
        ),
        exchange(
            ProviderKind::TossPayments,
            ProviderOperation::Refund,
            Some(refund_key),
            include_str!("fixtures/toss-payments/refund-request.json"),
            include_str!("fixtures/toss-payments/refund-response.json"),
        ),
    ]))
}

fn kakao_transport(
    issue_key: IdempotencyKey,
    charge_key: IdempotencyKey,
    refund_key: IdempotencyKey,
) -> Arc<FixtureTransport> {
    Arc::new(FixtureTransport::new(vec![
        exchange(
            ProviderKind::KakaoPay,
            ProviderOperation::IssueBillingKey,
            Some(issue_key),
            include_str!("fixtures/kakao-pay/issue-request.json"),
            include_str!("fixtures/kakao-pay/issue-response.json"),
        ),
        exchange(
            ProviderKind::KakaoPay,
            ProviderOperation::Charge,
            Some(charge_key),
            include_str!("fixtures/kakao-pay/charge-request.json"),
            include_str!("fixtures/kakao-pay/charge-response.json"),
        ),
        exchange(
            ProviderKind::KakaoPay,
            ProviderOperation::FetchPayment,
            None,
            include_str!("fixtures/kakao-pay/fetch-request.json"),
            include_str!("fixtures/kakao-pay/fetch-response.json"),
        ),
        exchange(
            ProviderKind::KakaoPay,
            ProviderOperation::Refund,
            Some(refund_key),
            include_str!("fixtures/kakao-pay/refund-request.json"),
            include_str!("fixtures/kakao-pay/refund-response.json"),
        ),
    ]))
}

fn stripe_transport(
    issue_key: IdempotencyKey,
    charge_key: IdempotencyKey,
    refund_key: IdempotencyKey,
) -> Arc<FixtureTransport> {
    Arc::new(FixtureTransport::new(vec![
        exchange(
            ProviderKind::Stripe,
            ProviderOperation::IssueBillingKey,
            Some(issue_key),
            include_str!("fixtures/stripe/issue-request.json"),
            include_str!("fixtures/stripe/issue-response.json"),
        ),
        exchange(
            ProviderKind::Stripe,
            ProviderOperation::Charge,
            Some(charge_key),
            include_str!("fixtures/stripe/charge-request.json"),
            include_str!("fixtures/stripe/charge-response.json"),
        ),
        exchange(
            ProviderKind::Stripe,
            ProviderOperation::FetchPayment,
            None,
            include_str!("fixtures/stripe/fetch-request.json"),
            include_str!("fixtures/stripe/fetch-response.json"),
        ),
        exchange(
            ProviderKind::Stripe,
            ProviderOperation::Refund,
            Some(refund_key),
            include_str!("fixtures/stripe/refund-request.json"),
            include_str!("fixtures/stripe/refund-response.json"),
        ),
    ]))
}

fn replay_policy() -> WebhookReplayPolicy {
    WebhookReplayPolicy {
        now_unix: NOW,
        tolerance_seconds: 300,
    }
}

fn stripe_signature(key: &[u8], timestamp: i64, body: &[u8]) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("fixture HMAC key");
    mac.update(timestamp.to_string().as_bytes());
    mac.update(b".");
    mac.update(body);
    format!(
        "t={timestamp},v1={}",
        hex_lower(&mac.finalize().into_bytes())
    )
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(char::from(HEX[usize::from(byte >> 4)]));
        output.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    output
}

fn assert_fixture_capabilities(provider: &dyn PaymentProvider, kind: ProviderKind) {
    let capabilities = provider.capabilities();
    assert_eq!(capabilities.provider, kind);
    assert_eq!(capabilities.currency, "KRW");
    assert!(!capabilities.webhook_is_payment_truth);
    assert!(capabilities.authenticated_fetch_is_payment_truth);
    assert!(capabilities.supports_credential_use_policy(BillingCredentialUsePolicy::SingleCharge));
    assert!(capabilities.supports_credential_use_policy(BillingCredentialUsePolicy::Recurring));
}

fn assert_redacted(observed: &str, secrets: &[&str]) {
    for secret in secrets {
        assert!(!observed.contains(secret), "secret leaked through Debug");
    }
}

fn toss_secrets() -> [&'static str; 3] {
    [
        "toss-auth-test",
        "toss-customer-test",
        "toss-billing-key-test",
    ]
}
