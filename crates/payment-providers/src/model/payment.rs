use std::fmt;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::{
    AttemptId, BillingCredentialUsePolicy, ExecutionMode, IdempotencyKey, KeyVersion, KrwAmount,
    MerchantOrderId, ProviderKind, ProviderOperation, ProviderPaymentId, WebhookHint,
};
use crate::SecretText;

pub enum BillingAuthorization {
    TossPayments {
        auth_key: SecretText,
        customer_key: SecretText,
    },
    KakaoPay {
        transaction_id: SecretText,
        approval_token: SecretText,
        partner_user_id: SecretText,
    },
    Stripe {
        customer_id: SecretText,
        payment_method_id: SecretText,
    },
}

impl fmt::Debug for BillingAuthorization {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("BillingAuthorization(<redacted>)")
    }
}

pub enum BillingKeyMaterial {
    TossPayments {
        billing_key: SecretText,
        customer_key: SecretText,
    },
    KakaoPay {
        subscription_id: SecretText,
        partner_user_id: SecretText,
    },
    Stripe {
        customer_id: SecretText,
        payment_method_id: SecretText,
    },
}

impl BillingKeyMaterial {
    pub const fn provider(&self) -> ProviderKind {
        match self {
            Self::TossPayments { .. } => ProviderKind::TossPayments,
            Self::KakaoPay { .. } => ProviderKind::KakaoPay,
            Self::Stripe { .. } => ProviderKind::Stripe,
        }
    }

    pub(crate) fn first_secret(&self) -> &str {
        match self {
            Self::TossPayments { billing_key, .. } => billing_key.expose_for_provider_codec(),
            Self::KakaoPay {
                subscription_id, ..
            } => subscription_id.expose_for_provider_codec(),
            Self::Stripe { customer_id, .. } => customer_id.expose_for_provider_codec(),
        }
    }

    pub(crate) fn second_secret(&self) -> &str {
        match self {
            Self::TossPayments { customer_key, .. } => customer_key.expose_for_provider_codec(),
            Self::KakaoPay {
                partner_user_id, ..
            } => partner_user_id.expose_for_provider_codec(),
            Self::Stripe {
                payment_method_id, ..
            } => payment_method_id.expose_for_provider_codec(),
        }
    }
}

impl fmt::Debug for BillingKeyMaterial {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BillingKeyMaterial")
            .field("provider", &self.provider())
            .field("material", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct BillingKeyHandle {
    pub binding_id: Uuid,
    pub provider: ProviderKind,
    pub use_policy: BillingCredentialUsePolicy,
    pub secret_reference: String,
    pub material_hmac: String,
    pub hmac_key_version: KeyVersion,
}

impl fmt::Debug for BillingKeyHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BillingKeyHandle")
            .field("binding_id", &self.binding_id)
            .field("provider", &self.provider)
            .field("use_policy", &self.use_policy)
            .field("secret_reference", &"<redacted>")
            .field("material_hmac", &"<redacted>")
            .field("hmac_key_version", &self.hmac_key_version)
            .finish()
    }
}

pub struct IssueBillingKeyRequest {
    pub binding_id: Uuid,
    pub idempotency_key: IdempotencyKey,
    pub use_policy: BillingCredentialUsePolicy,
    pub authorization: BillingAuthorization,
}

impl fmt::Debug for IssueBillingKeyRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("IssueBillingKeyRequest")
            .field("binding_id", &self.binding_id)
            .field("idempotency_key", &self.idempotency_key)
            .field("use_policy", &self.use_policy)
            .field("authorization", &"<redacted>")
            .finish()
    }
}

pub struct IssueBillingKeyReceipt {
    pub binding_id: Uuid,
    pub use_policy: BillingCredentialUsePolicy,
    pub material: BillingKeyMaterial,
    pub transport: TransportReceipt,
}

impl fmt::Debug for IssueBillingKeyReceipt {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("IssueBillingKeyReceipt")
            .field("binding_id", &self.binding_id)
            .field("use_policy", &self.use_policy)
            .field("material", &"<redacted>")
            .field("transport", &self.transport)
            .finish()
    }
}

pub enum ChargeInstrument<'a> {
    Stored(&'a BillingKeyMaterial),
}

pub struct ChargeRequest<'a> {
    pub attempt_id: AttemptId,
    pub idempotency_key: IdempotencyKey,
    pub merchant_order_id: &'a MerchantOrderId,
    pub amount: KrwAmount,
    pub instrument: ChargeInstrument<'a>,
}

impl fmt::Debug for ChargeRequest<'_> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ChargeRequest")
            .field("attempt_id", &self.attempt_id)
            .field("merchant_order_id", &self.merchant_order_id)
            .field("amount", &self.amount)
            .field("instrument", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChargeAcknowledgement {
    pub attempt_id: AttemptId,
    pub merchant_order_id: MerchantOrderId,
    pub locator: PaymentLocator,
    pub transport: TransportReceipt,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RefundRequest {
    pub attempt_id: AttemptId,
    pub idempotency_key: IdempotencyKey,
    pub payment_id: ProviderPaymentId,
    pub amount: KrwAmount,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RefundAcknowledgement {
    pub attempt_id: AttemptId,
    pub locator: PaymentLocator,
    pub transport: TransportReceipt,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PaymentLocator {
    ProviderPaymentId(ProviderPaymentId),
    MerchantOrderId(MerchantOrderId),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FetchPaymentRequest {
    pub provider: ProviderKind,
    pub locator: PaymentLocator,
    pub expected_attempt_id: AttemptId,
    pub expected_merchant_order_id: MerchantOrderId,
    pub expected_amount: KrwAmount,
}

impl FetchPaymentRequest {
    pub fn from_charge(
        provider: ProviderKind,
        acknowledgement: &ChargeAcknowledgement,
        expected_amount: KrwAmount,
    ) -> Self {
        Self {
            provider,
            locator: acknowledgement.locator.clone(),
            expected_attempt_id: acknowledgement.attempt_id,
            expected_merchant_order_id: acknowledgement.merchant_order_id.clone(),
            expected_amount,
        }
    }

    pub fn from_webhook(
        hint: &WebhookHint,
        expected_attempt_id: AttemptId,
        expected_merchant_order_id: MerchantOrderId,
        expected_amount: KrwAmount,
    ) -> Self {
        Self {
            provider: hint.provider(),
            locator: hint.locator().clone(),
            expected_attempt_id,
            expected_merchant_order_id,
            expected_amount,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PaymentState {
    Pending,
    Succeeded,
    Failed,
    Canceled,
    PartiallyRefunded,
    Refunded,
}

/// The only provider type that may drive donation/payment state changes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FetchedPayment {
    pub provider: ProviderKind,
    pub provider_payment_id: ProviderPaymentId,
    pub attempt_id: AttemptId,
    pub merchant_order_id: MerchantOrderId,
    pub amount: KrwAmount,
    pub state: PaymentState,
    pub provider_observed_at_unix: i64,
    pub transport: TransportReceipt,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TransportReceipt {
    pub execution_mode: ExecutionMode,
    pub provider: ProviderKind,
    pub operation: ProviderOperation,
    pub request_sha256: String,
    pub response_sha256: String,
    pub http_status: u16,
}
