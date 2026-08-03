use std::sync::{Arc, Mutex};

use hmac::{Hmac, Mac};
use serde_json::json;
use sha2::Sha256;
use uuid::Uuid;

use crate::{
    AdapterEnvironment, BillingAuthorization, FixtureWebhook, IdempotencyKey, KeyVersion,
    KrwAmount, MerchantOrderId, PaymentLocator, PaymentProvider, PaymentProviderError,
    PaymentState, PaymentTransport, PaymentTransportError, ProviderEventIdentity, ProviderKind,
    SecretText, TestFixtureAuthority, TransportFuture, TransportMode, TransportRequest,
    TransportResponse, WebhookHeaders, WebhookReplayPolicy, WebhookSigningKey,
    providers::{kakao_pay::KakaoPay, stripe::Stripe, toss_payments::TossPayments},
};

mod ledger;
mod wire;

use ledger::{FixtureExecution, FixtureLedger};
use wire::FixturePayment;

const STRIPE_FIXTURE_SIGNING_KEY: &[u8] =
    b"stripe-dynamic-fixture-signing-key-no-production-authority";

/// Explicit TEST_ONLY result selected by the caller's fixture authority.
/// There is deliberately no default or production conversion.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FixturePaymentOutcome {
    Pending,
    Succeeded,
    Failed,
    Canceled,
}

/// Domain-separated SHA-256 expectation for a TEST_ONLY fixture payment ID.
///
/// The opaque provider ID is never exposed by this type. `Debug` is redacted,
/// and the digest has no `Display` or serialization implementation.
#[derive(Clone, Eq, PartialEq)]
pub struct FixtureProviderPaymentIdDigest(String);

impl FixtureProviderPaymentIdDigest {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for FixtureProviderPaymentIdDigest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("FixtureProviderPaymentIdDigest(<sha256>)")
    }
}

impl FixturePaymentOutcome {
    const fn state(self) -> PaymentState {
        match self {
            Self::Pending => PaymentState::Pending,
            Self::Succeeded => PaymentState::Succeeded,
            Self::Failed => PaymentState::Failed,
            Self::Canceled => PaymentState::Canceled,
        }
    }
}

/// Creates the three closed fixture adapters over one shared deterministic
/// ledger. It cannot construct a live transport or select an outcome implicitly.
#[derive(Clone)]
pub struct DeterministicFixtureProviderFactory {
    authority: TestFixtureAuthority,
    transport: Arc<DeterministicFixtureTransport>,
}

impl DeterministicFixtureProviderFactory {
    pub fn new(
        authority: TestFixtureAuthority,
        outcome: FixturePaymentOutcome,
        observed_at_unix: i64,
    ) -> Result<Self, PaymentProviderError> {
        if observed_at_unix <= 0 {
            return Err(PaymentProviderError::InvalidInput);
        }
        Ok(Self {
            authority,
            transport: Arc::new(DeterministicFixtureTransport {
                outcome,
                observed_at_unix,
                ledger: Mutex::new(FixtureLedger::default()),
            }),
        })
    }

    pub fn provider(
        &self,
        provider: ProviderKind,
    ) -> Result<Arc<dyn PaymentProvider>, PaymentProviderError> {
        let environment = AdapterEnvironment::TestFixture(self.authority);
        let transport: Arc<dyn PaymentTransport> = self.transport.clone();
        match provider {
            ProviderKind::TossPayments => Ok(Arc::new(TossPayments::new(environment, transport)?)),
            ProviderKind::KakaoPay => Ok(Arc::new(KakaoPay::new(environment, transport)?)),
            ProviderKind::Stripe => Ok(Arc::new(Stripe::new(
                environment,
                transport,
                WebhookSigningKey::try_new(STRIPE_FIXTURE_SIGNING_KEY.to_vec())?,
                KeyVersion::try_new("dynamic-fixture-v1".to_owned())?,
            )?)),
        }
    }

    /// Derives short-lived provider authorization from already validated,
    /// non-secret claim identifiers. The raw result is redacted and zeroized by
    /// `BillingAuthorization`/`SecretText`.
    pub fn issue_authorization(
        &self,
        provider: ProviderKind,
        binding_id: Uuid,
        issue_idempotency_key: IdempotencyKey,
    ) -> Result<BillingAuthorization, PaymentProviderError> {
        wire::issue_authorization(provider, binding_id, issue_idempotency_key)
    }

    /// Computes the claim-time provider-payment expectation for the closed
    /// TEST_ONLY transport without exposing its opaque provider payment ID.
    pub fn expected_provider_payment_id_digest(
        &self,
        provider: ProviderKind,
        charge_idempotency_key: IdempotencyKey,
        merchant_order_id: &MerchantOrderId,
        amount: KrwAmount,
    ) -> Result<FixtureProviderPaymentIdDigest, PaymentProviderError> {
        let provider_payment_id = wire::expected_provider_payment_id(
            provider,
            charge_idempotency_key,
            merchant_order_id,
            amount,
        )?;
        let domain = b"gurine-provider-payment-id.v1\0";
        let mut preimage = Vec::with_capacity(domain.len() + provider_payment_id.as_str().len());
        preimage.extend_from_slice(domain);
        preimage.extend_from_slice(provider_payment_id.as_str().as_bytes());
        Ok(FixtureProviderPaymentIdDigest(
            crate::providers::sha256_hex(&preimage),
        ))
    }

    /// Produces a canonical TEST_ONLY webhook for an existing shared-ledger
    /// payment without exposing the Stripe signing key.
    pub fn webhook_for_payment(
        &self,
        provider: ProviderKind,
        event_identity: ProviderEventIdentity,
        locator: &PaymentLocator,
        signed_at_unix: i64,
    ) -> Result<FixtureWebhook, PaymentProviderError> {
        if signed_at_unix <= 0 {
            return Err(PaymentProviderError::InvalidInput);
        }
        let body = {
            let ledger = self
                .transport
                .ledger
                .lock()
                .map_err(|_| PaymentProviderError::Unavailable)?;
            let payment = ledger
                .payment_for_locator(provider, locator)
                .map_err(PaymentProviderError::from)?;
            webhook_body(provider, &event_identity, payment)?
        };
        let headers = if provider == ProviderKind::Stripe {
            WebhookHeaders::stripe(SecretText::try_new(stripe_signature(
                signed_at_unix,
                &body,
            )?)?)
        } else {
            WebhookHeaders::none()
        };
        Ok(FixtureWebhook::from_fixture_parts(
            headers,
            body,
            WebhookReplayPolicy {
                now_unix: signed_at_unix,
                tolerance_seconds: 300,
            },
        ))
    }
}

impl std::fmt::Debug for DeterministicFixtureProviderFactory {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DeterministicFixtureProviderFactory")
            .field("authority", &"TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY")
            .field("outcome", &self.transport.outcome)
            .field("observed_at_unix", &self.transport.observed_at_unix)
            .finish_non_exhaustive()
    }
}

struct DeterministicFixtureTransport {
    outcome: FixturePaymentOutcome,
    observed_at_unix: i64,
    ledger: Mutex<FixtureLedger>,
}

impl PaymentTransport for DeterministicFixtureTransport {
    fn mode(&self) -> TransportMode {
        TransportMode::TestFixture
    }

    fn execute(&self, request: TransportRequest) -> TransportFuture<'_> {
        Box::pin(async move {
            let request_sha256 = crate::providers::sha256_hex(request.body_for_egress());
            let command = wire::parse_request(&request)?;
            let response = self
                .ledger
                .lock()
                .map_err(|_| PaymentTransportError::Unavailable)?
                .execute(FixtureExecution::new(
                    request.provider(),
                    request.operation(),
                    request_sha256,
                    command,
                    self.outcome.state(),
                    self.observed_at_unix,
                ))?;
            TransportResponse::from_egress(200, response)
        })
    }
}

fn webhook_body(
    provider: ProviderKind,
    event_identity: &ProviderEventIdentity,
    payment: &FixturePayment,
) -> Result<Vec<u8>, PaymentProviderError> {
    let value = match provider {
        ProviderKind::TossPayments => json!({
            "eventId": event_identity.as_str(),
            "paymentKey": payment.provider_payment_id.as_str(),
        }),
        ProviderKind::KakaoPay => json!({
            "eventId": event_identity.as_str(),
            "transactionId": payment.provider_payment_id.as_str(),
        }),
        ProviderKind::Stripe => json!({
            "id": event_identity.as_str(),
            "type": "payment_intent.updated",
            "data": {"object": {"id": payment.provider_payment_id.as_str()}},
        }),
    };
    serde_json::to_vec(&value).map_err(|_| PaymentProviderError::InvalidInput)
}

fn stripe_signature(timestamp: i64, body: &[u8]) -> Result<String, PaymentProviderError> {
    let mut mac = Hmac::<Sha256>::new_from_slice(STRIPE_FIXTURE_SIGNING_KEY)
        .map_err(|_| PaymentProviderError::InvalidInput)?;
    mac.update(timestamp.to_string().as_bytes());
    mac.update(b".");
    mac.update(body);
    Ok(format!(
        "t={timestamp},v1={}",
        hex_lower(&mac.finalize().into_bytes())
    ))
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
