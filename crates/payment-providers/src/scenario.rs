use std::{
    collections::BTreeSet,
    sync::{Arc, Mutex},
};

use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::Sha256;
use uuid::Uuid;

use crate::{
    AdapterEnvironment, AttemptId, BillingAuthorization, BillingCredentialUsePolicy,
    IdempotencyKey, IssueBillingKeyRequest, KeyVersion, KrwAmount, MerchantOrderId,
    PaymentProvider, PaymentProviderError, PaymentState, PaymentTransport, PaymentTransportError,
    ProviderEventIdentity, ProviderKind, ProviderOperation, ProviderPaymentId, SecretText,
    TestFixtureAuthority, TransportFuture, TransportMode, TransportRequest, TransportResponse,
    WebhookEnvelope, WebhookHeaders, WebhookReplayPolicy, WebhookSigningKey,
    providers::{kakao_pay::KakaoPay, stripe::Stripe, toss_payments::TossPayments},
};

type HmacSha256 = Hmac<Sha256>;

const STRIPE_FIXTURE_SIGNING_KEY: &[u8] = b"stripe-fixture-signing-key-no-production-authority";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderFixtureScenario {
    pub provider: ProviderKind,
    pub binding_id: Uuid,
    pub use_policy: BillingCredentialUsePolicy,
    pub attempt_id: AttemptId,
    pub issue_idempotency_key: IdempotencyKey,
    pub charge_idempotency_key: IdempotencyKey,
    pub refund_idempotency_key: IdempotencyKey,
    pub merchant_order_id: MerchantOrderId,
    pub amount: KrwAmount,
    pub terminal_state: PaymentState,
    pub event_identity: ProviderEventIdentity,
    pub provider_payment_id: ProviderPaymentId,
    pub observed_at_unix: i64,
}

pub struct FixtureWebhook {
    headers: WebhookHeaders,
    body: Vec<u8>,
    replay_policy: WebhookReplayPolicy,
}

impl FixtureWebhook {
    pub(crate) fn from_fixture_parts(
        headers: WebhookHeaders,
        body: Vec<u8>,
        replay_policy: WebhookReplayPolicy,
    ) -> Self {
        Self {
            headers,
            body,
            replay_policy,
        }
    }

    pub fn envelope(&self) -> WebhookEnvelope<'_> {
        WebhookEnvelope {
            headers: &self.headers,
            body: &self.body,
            replay_policy: self.replay_policy,
        }
    }

    pub fn body_sha256(&self) -> String {
        super::providers::sha256_hex(&self.body)
    }
}

impl std::fmt::Debug for FixtureWebhook {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("FixtureWebhook")
            .field("headers", &"<redacted>")
            .field("body", &"<redacted>")
            .field("body_length", &self.body.len())
            .field("replay_policy", &self.replay_policy)
            .finish()
    }
}

pub struct FixtureProviderBundle {
    pub provider: Arc<dyn PaymentProvider>,
    pub issue_request: IssueBillingKeyRequest,
    pub scenario: ProviderFixtureScenario,
    pub webhook: FixtureWebhook,
}

impl FixtureProviderBundle {
    pub fn deterministic(
        authority: TestFixtureAuthority,
        scenario: ProviderFixtureScenario,
    ) -> Result<Self, PaymentProviderError> {
        validate_scenario(&scenario)?;
        let transport: Arc<dyn PaymentTransport> =
            Arc::new(ScenarioTransport::new(scenario.clone()));
        let environment = AdapterEnvironment::TestFixture(authority);
        let (provider, authorization): (Arc<dyn PaymentProvider>, BillingAuthorization) =
            match scenario.provider {
                ProviderKind::TossPayments => (
                    Arc::new(TossPayments::new(environment, transport)?),
                    BillingAuthorization::TossPayments {
                        auth_key: secret("toss-fixture-auth-key")?,
                        customer_key: secret("toss-fixture-customer-key")?,
                    },
                ),
                ProviderKind::KakaoPay => (
                    Arc::new(KakaoPay::new(environment, transport)?),
                    BillingAuthorization::KakaoPay {
                        transaction_id: secret("kakao-fixture-initial-transaction")?,
                        approval_token: secret("kakao-fixture-approval-token")?,
                        partner_user_id: secret("kakao-fixture-partner-user")?,
                    },
                ),
                ProviderKind::Stripe => (
                    Arc::new(Stripe::new(
                        environment,
                        transport,
                        WebhookSigningKey::try_new(STRIPE_FIXTURE_SIGNING_KEY.to_vec())?,
                        KeyVersion::try_new("stripe-fixture-v1".to_owned())?,
                    )?),
                    BillingAuthorization::Stripe {
                        customer_id: secret("stripe-fixture-customer")?,
                        payment_method_id: secret("stripe-fixture-payment-method")?,
                    },
                ),
            };
        let webhook = fixture_webhook(&scenario)?;
        let issue_request = IssueBillingKeyRequest {
            binding_id: scenario.binding_id,
            idempotency_key: scenario.issue_idempotency_key,
            use_policy: scenario.use_policy,
            authorization,
        };
        Ok(Self {
            provider,
            issue_request,
            scenario,
            webhook,
        })
    }
}

fn validate_scenario(scenario: &ProviderFixtureScenario) -> Result<(), PaymentProviderError> {
    if scenario.observed_at_unix <= 0 {
        return Err(PaymentProviderError::InvalidInput);
    }
    if scenario.terminal_state == PaymentState::PartiallyRefunded
        && scenario.amount.whole_krw() <= 1
    {
        return Err(PaymentProviderError::InvalidInput);
    }
    let supported = match scenario.provider {
        ProviderKind::TossPayments => matches!(
            scenario.terminal_state,
            PaymentState::Pending
                | PaymentState::Succeeded
                | PaymentState::Failed
                | PaymentState::Canceled
                | PaymentState::PartiallyRefunded
        ),
        ProviderKind::KakaoPay => matches!(
            scenario.terminal_state,
            PaymentState::Pending
                | PaymentState::Succeeded
                | PaymentState::Failed
                | PaymentState::Canceled
                | PaymentState::PartiallyRefunded
        ),
        ProviderKind::Stripe => true,
    };
    if supported {
        Ok(())
    } else {
        Err(PaymentProviderError::InvalidInput)
    }
}

struct ScenarioTransport {
    scenario: ProviderFixtureScenario,
    mutation_calls: Mutex<BTreeSet<ProviderOperation>>,
}

impl ScenarioTransport {
    fn new(scenario: ProviderFixtureScenario) -> Self {
        Self {
            scenario,
            mutation_calls: Mutex::new(BTreeSet::new()),
        }
    }

    fn respond(&self, request: &TransportRequest) -> Result<Vec<u8>, PaymentTransportError> {
        if request.provider() != self.scenario.provider {
            return Err(PaymentTransportError::FixtureMismatch);
        }
        let body: Value = serde_json::from_slice(request.body_for_egress())
            .map_err(|_| PaymentTransportError::FixtureMismatch)?;
        match request.operation() {
            ProviderOperation::IssueBillingKey => self.issue(request, &body),
            ProviderOperation::Charge => self.charge(request, &body),
            ProviderOperation::Refund => self.refund(request, &body),
            ProviderOperation::FetchPayment => self.fetch(&body),
        }
    }

    fn claim_mutation(&self, operation: ProviderOperation) -> Result<(), PaymentTransportError> {
        let mut calls = self
            .mutation_calls
            .lock()
            .map_err(|_| PaymentTransportError::Unavailable)?;
        if calls.insert(operation) {
            Ok(())
        } else {
            Err(PaymentTransportError::FixtureMismatch)
        }
    }

    fn issue(
        &self,
        request: &TransportRequest,
        body: &Value,
    ) -> Result<Vec<u8>, PaymentTransportError> {
        self.claim_mutation(ProviderOperation::IssueBillingKey)?;
        if request.idempotency_key() != Some(self.scenario.issue_idempotency_key) {
            return Err(PaymentTransportError::FixtureMismatch);
        }
        let response = match self.scenario.provider {
            ProviderKind::TossPayments
                if fields_equal(
                    body,
                    &[
                        ("authKey", "toss-fixture-auth-key"),
                        ("customerKey", "toss-fixture-customer-key"),
                    ],
                ) =>
            {
                json!({
                    "billingKey":"toss-fixture-billing-key",
                    "customerKey":"toss-fixture-customer-key"
                })
            }
            ProviderKind::KakaoPay
                if fields_equal(
                    body,
                    &[
                        ("transactionId", "kakao-fixture-initial-transaction"),
                        ("approvalToken", "kakao-fixture-approval-token"),
                        ("partnerUserId", "kakao-fixture-partner-user"),
                    ],
                ) =>
            {
                json!({
                    "subscriptionId":"kakao-fixture-subscription-id",
                    "partnerUserId":"kakao-fixture-partner-user"
                })
            }
            ProviderKind::Stripe
                if fields_equal(
                    body,
                    &[
                        ("customerId", "stripe-fixture-customer"),
                        ("paymentMethodId", "stripe-fixture-payment-method"),
                        ("usage", "off_session"),
                    ],
                ) =>
            {
                json!({
                    "customerId":"stripe-fixture-customer",
                    "paymentMethodId":"stripe-fixture-payment-method"
                })
            }
            _ => return Err(PaymentTransportError::FixtureMismatch),
        };
        encode(response)
    }

    fn charge(
        &self,
        request: &TransportRequest,
        body: &Value,
    ) -> Result<Vec<u8>, PaymentTransportError> {
        self.claim_mutation(ProviderOperation::Charge)?;
        if request.idempotency_key() != Some(self.scenario.charge_idempotency_key)
            || body.get("currency").and_then(Value::as_str)
                != Some(match self.scenario.provider {
                    ProviderKind::Stripe => "krw",
                    ProviderKind::TossPayments | ProviderKind::KakaoPay => "KRW",
                })
            || amount(body) != Some(self.scenario.amount.whole_krw())
            || order(body) != Some(self.scenario.merchant_order_id.as_str())
            || !stored_credential_matches(self.scenario.provider, body)
        {
            return Err(PaymentTransportError::FixtureMismatch);
        }
        let response = match self.scenario.provider {
            ProviderKind::TossPayments => json!({
                "paymentKey":self.scenario.provider_payment_id.as_str(),
                "orderId":self.scenario.merchant_order_id.as_str()
            }),
            ProviderKind::KakaoPay => json!({
                "transactionId":self.scenario.provider_payment_id.as_str(),
                "partnerOrderId":self.scenario.merchant_order_id.as_str()
            }),
            ProviderKind::Stripe => json!({
                "paymentIntentId":self.scenario.provider_payment_id.as_str(),
                "merchantOrderId":self.scenario.merchant_order_id.as_str()
            }),
        };
        encode(response)
    }

    fn refund(
        &self,
        request: &TransportRequest,
        body: &Value,
    ) -> Result<Vec<u8>, PaymentTransportError> {
        self.claim_mutation(ProviderOperation::Refund)?;
        if request.idempotency_key() != Some(self.scenario.refund_idempotency_key)
            || amount(body) != Some(self.scenario.amount.whole_krw())
        {
            return Err(PaymentTransportError::FixtureMismatch);
        }
        let response = match self.scenario.provider {
            ProviderKind::TossPayments => json!({
                "paymentKey":self.scenario.provider_payment_id.as_str()
            }),
            ProviderKind::KakaoPay => json!({
                "transactionId":self.scenario.provider_payment_id.as_str()
            }),
            ProviderKind::Stripe => json!({
                "paymentIntentId":self.scenario.provider_payment_id.as_str()
            }),
        };
        encode(response)
    }

    fn fetch(&self, body: &Value) -> Result<Vec<u8>, PaymentTransportError> {
        if body.get("locator").and_then(Value::as_str)
            != Some(self.scenario.provider_payment_id.as_str())
        {
            return Err(PaymentTransportError::FixtureMismatch);
        }
        let response = match self.scenario.provider {
            ProviderKind::TossPayments => json!({
                "paymentKey":self.scenario.provider_payment_id.as_str(),
                "orderId":self.scenario.merchant_order_id.as_str(),
                "amount":self.scenario.amount.whole_krw(),
                "status":toss_status(self.scenario.terminal_state),
                "observedAtUnix":self.scenario.observed_at_unix
            }),
            ProviderKind::KakaoPay => json!({
                "transactionId":self.scenario.provider_payment_id.as_str(),
                "partnerOrderId":self.scenario.merchant_order_id.as_str(),
                "totalAmount":self.scenario.amount.whole_krw(),
                "status":kakao_status(self.scenario.terminal_state),
                "observedAtUnix":self.scenario.observed_at_unix
            }),
            ProviderKind::Stripe => json!({
                "paymentIntentId":self.scenario.provider_payment_id.as_str(),
                "merchantOrderId":self.scenario.merchant_order_id.as_str(),
                "amount":self.scenario.amount.whole_krw(),
                "currency":"KRW",
                "status":stripe_status(self.scenario.terminal_state),
                "refundedAmount":stripe_refunded_amount(&self.scenario),
                "observedAtUnix":self.scenario.observed_at_unix
            }),
        };
        encode(response)
    }
}

impl PaymentTransport for ScenarioTransport {
    fn mode(&self) -> TransportMode {
        TransportMode::TestFixture
    }

    fn execute(&self, request: TransportRequest) -> TransportFuture<'_> {
        Box::pin(async move {
            let response = self.respond(&request)?;
            TransportResponse::from_egress(200, response)
        })
    }
}

fn fixture_webhook(
    scenario: &ProviderFixtureScenario,
) -> Result<FixtureWebhook, PaymentProviderError> {
    let body = match scenario.provider {
        ProviderKind::TossPayments => json!({
            "eventId":scenario.event_identity.as_str(),
            "paymentKey":scenario.provider_payment_id.as_str()
        }),
        ProviderKind::KakaoPay => json!({
            "eventId":scenario.event_identity.as_str(),
            "transactionId":scenario.provider_payment_id.as_str()
        }),
        ProviderKind::Stripe => json!({
            "id":scenario.event_identity.as_str(),
            "type":"payment_intent.updated",
            "data":{"object":{"id":scenario.provider_payment_id.as_str()}}
        }),
    };
    let body = serde_json::to_vec(&body).map_err(|_| PaymentProviderError::InvalidInput)?;
    let replay_policy = WebhookReplayPolicy {
        now_unix: scenario.observed_at_unix,
        tolerance_seconds: 300,
    };
    let headers = if scenario.provider == ProviderKind::Stripe {
        let signature = stripe_signature(scenario.observed_at_unix, &body)?;
        WebhookHeaders::stripe(secret(&signature)?)
    } else {
        WebhookHeaders::none()
    };
    Ok(FixtureWebhook {
        headers,
        body,
        replay_policy,
    })
}

fn stripe_signature(timestamp: i64, body: &[u8]) -> Result<String, PaymentProviderError> {
    let mut mac = HmacSha256::new_from_slice(STRIPE_FIXTURE_SIGNING_KEY)
        .map_err(|_| PaymentProviderError::InvalidInput)?;
    mac.update(timestamp.to_string().as_bytes());
    mac.update(b".");
    mac.update(body);
    Ok(format!(
        "t={timestamp},v1={}",
        hex_lower(&mac.finalize().into_bytes())
    ))
}

fn fields_equal(value: &Value, expected: &[(&str, &str)]) -> bool {
    expected
        .iter()
        .all(|(key, expected)| value.get(*key).and_then(Value::as_str) == Some(*expected))
}

fn stored_credential_matches(provider: ProviderKind, value: &Value) -> bool {
    if value.get("merchantScheduled").and_then(Value::as_bool) != Some(true) {
        return false;
    }
    match provider {
        ProviderKind::TossPayments => fields_equal(
            value,
            &[
                ("billingKey", "toss-fixture-billing-key"),
                ("customerKey", "toss-fixture-customer-key"),
            ],
        ),
        ProviderKind::KakaoPay => fields_equal(
            value,
            &[
                ("subscriptionId", "kakao-fixture-subscription-id"),
                ("partnerUserId", "kakao-fixture-partner-user"),
            ],
        ),
        ProviderKind::Stripe => {
            fields_equal(
                value,
                &[
                    ("customerId", "stripe-fixture-customer"),
                    ("paymentMethodId", "stripe-fixture-payment-method"),
                ],
            ) && value.get("offSession").and_then(Value::as_bool) == Some(true)
        }
    }
}

fn amount(value: &Value) -> Option<i64> {
    ["amount", "totalAmount", "cancelAmount"]
        .iter()
        .find_map(|key| value.get(*key).and_then(Value::as_i64))
}

fn order(value: &Value) -> Option<&str> {
    ["orderId", "partnerOrderId", "merchantOrderId"]
        .iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
}

fn toss_status(state: PaymentState) -> &'static str {
    match state {
        PaymentState::Pending => "IN_PROGRESS",
        PaymentState::Succeeded => "DONE",
        PaymentState::Failed => "ABORTED",
        PaymentState::Canceled => "CANCELED",
        PaymentState::PartiallyRefunded => "PARTIAL_CANCELED",
        PaymentState::Refunded => "CANCELED",
    }
}

fn kakao_status(state: PaymentState) -> &'static str {
    match state {
        PaymentState::Pending => "READY",
        PaymentState::Succeeded => "SUCCESS_PAYMENT",
        PaymentState::Failed => "FAIL_PAYMENT",
        PaymentState::Canceled => "CANCEL_PAYMENT",
        PaymentState::PartiallyRefunded => "PART_CANCEL_PAYMENT",
        PaymentState::Refunded => "CANCEL_PAYMENT",
    }
}

fn stripe_status(state: PaymentState) -> &'static str {
    match state {
        PaymentState::Pending => "processing",
        PaymentState::Succeeded | PaymentState::PartiallyRefunded | PaymentState::Refunded => {
            "succeeded"
        }
        PaymentState::Failed => "failed",
        PaymentState::Canceled => "canceled",
    }
}

fn stripe_refunded_amount(scenario: &ProviderFixtureScenario) -> i64 {
    match scenario.terminal_state {
        PaymentState::Refunded => scenario.amount.whole_krw(),
        PaymentState::PartiallyRefunded => scenario.amount.whole_krw().saturating_sub(1),
        _ => 0,
    }
}

fn encode(value: Value) -> Result<Vec<u8>, PaymentTransportError> {
    serde_json::to_vec(&value).map_err(|_| PaymentTransportError::FixtureMismatch)
}

fn secret(value: &str) -> Result<SecretText, PaymentProviderError> {
    SecretText::try_new(value.to_owned())
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
