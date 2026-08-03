use std::fmt;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::PaymentProviderError;

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ProviderKind {
    TossPayments,
    KakaoPay,
    Stripe,
}

impl ProviderKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::TossPayments => "TOSS_PAYMENTS",
            Self::KakaoPay => "KAKAO_PAY",
            Self::Stripe => "STRIPE",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ProviderOperation {
    IssueBillingKey,
    Charge,
    Refund,
    FetchPayment,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ExecutionMode {
    TestFixtureOnly,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ScheduleOwnership {
    MerchantScheduled,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum BillingCredentialKind {
    TossBillingKey,
    KakaoSubscriptionId,
    StripeOffSessionPaymentMethod,
}

/// How long a merchant-scheduled credential may authorize charge material.
///
/// `SingleCharge` still uses the provider's stored-credential form, but the
/// vault releases that credential exactly once.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum BillingCredentialUsePolicy {
    SingleCharge,
    Recurring,
}

impl BillingCredentialUsePolicy {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::SingleCharge => "SINGLE_CHARGE",
            Self::Recurring => "RECURRING",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum WebhookSignatureSupport {
    StripeV1HmacSha256,
    NotAvailableFetchRequired,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderCapabilities {
    pub provider: ProviderKind,
    pub execution_mode: ExecutionMode,
    pub schedule_ownership: ScheduleOwnership,
    pub credential_kind: BillingCredentialKind,
    pub credential_use_policies: [BillingCredentialUsePolicy; 2],
    pub webhook_signature: WebhookSignatureSupport,
    pub webhook_is_payment_truth: bool,
    pub authenticated_fetch_is_payment_truth: bool,
    pub currency: &'static str,
}

impl ProviderCapabilities {
    pub(crate) const fn fixture(
        provider: ProviderKind,
        credential_kind: BillingCredentialKind,
        webhook_signature: WebhookSignatureSupport,
    ) -> Self {
        Self {
            provider,
            execution_mode: ExecutionMode::TestFixtureOnly,
            schedule_ownership: ScheduleOwnership::MerchantScheduled,
            credential_kind,
            credential_use_policies: [
                BillingCredentialUsePolicy::SingleCharge,
                BillingCredentialUsePolicy::Recurring,
            ],
            webhook_signature,
            webhook_is_payment_truth: false,
            authenticated_fetch_is_payment_truth: true,
            currency: "KRW",
        }
    }

    pub fn supports_credential_use_policy(&self, policy: BillingCredentialUsePolicy) -> bool {
        self.credential_use_policies.contains(&policy)
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct AttemptId(Uuid);

impl AttemptId {
    pub const fn new(value: Uuid) -> Self {
        Self(value)
    }

    pub const fn get(self) -> Uuid {
        self.0
    }
}

#[derive(Clone, Copy, Eq, Hash, PartialEq)]
pub struct IdempotencyKey(Uuid);

impl IdempotencyKey {
    pub const fn new(value: Uuid) -> Self {
        Self(value)
    }

    pub fn as_provider_value(&self) -> String {
        self.0.to_string()
    }
}

impl fmt::Debug for IdempotencyKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("IdempotencyKey(<redacted>)")
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct KrwAmount(i64);

impl KrwAmount {
    pub fn try_new(value: i64) -> Result<Self, PaymentProviderError> {
        if value <= 0 {
            return Err(PaymentProviderError::InvalidInput);
        }
        Ok(Self(value))
    }

    pub fn try_from_currency(value: i64, currency: &str) -> Result<Self, PaymentProviderError> {
        if currency != "KRW" {
            return Err(PaymentProviderError::InvalidInput);
        }
        Self::try_new(value)
    }

    pub const fn whole_krw(self) -> i64 {
        self.0
    }
}

#[derive(Clone, Eq, Hash, PartialEq)]
pub struct MerchantOrderId(String);

impl MerchantOrderId {
    pub fn try_new(value: String) -> Result<Self, PaymentProviderError> {
        validate_opaque_id(&value)?;
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for MerchantOrderId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("MerchantOrderId(<opaque>)")
    }
}

#[derive(Clone, Eq, Hash, PartialEq)]
pub struct ProviderPaymentId(String);

impl ProviderPaymentId {
    pub fn try_new(value: String) -> Result<Self, PaymentProviderError> {
        validate_opaque_id(&value)?;
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ProviderPaymentId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ProviderPaymentId(<opaque>)")
    }
}

#[derive(Clone, Eq, Hash, PartialEq)]
pub struct ProviderEventIdentity(String);

impl ProviderEventIdentity {
    pub fn try_new(value: String) -> Result<Self, PaymentProviderError> {
        validate_opaque_id(&value)?;
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for ProviderEventIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ProviderEventIdentity(<opaque>)")
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KeyVersion(String);

impl KeyVersion {
    pub fn try_new(value: String) -> Result<Self, PaymentProviderError> {
        if value.is_empty()
            || value.len() > 100
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            return Err(PaymentProviderError::InvalidInput);
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

fn validate_opaque_id(value: &str) -> Result<(), PaymentProviderError> {
    if value.is_empty()
        || value.len() > 256
        || value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte.is_ascii_whitespace())
    {
        Err(PaymentProviderError::InvalidInput)
    } else {
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TestFixtureAuthority(());

impl TestFixtureAuthority {
    pub fn try_new(marker: &str) -> Result<Self, PaymentProviderError> {
        if marker == "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY" {
            Ok(Self(()))
        } else {
            Err(PaymentProviderError::InvalidInput)
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdapterEnvironment {
    Production,
    TestFixture(TestFixtureAuthority),
}

mod payment;
mod webhook;

pub use payment::*;
pub use webhook::*;
