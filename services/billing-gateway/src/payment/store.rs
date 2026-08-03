use std::{future::Future, pin::Pin};

use gurine_payment_providers::{
    BillingCredentialUsePolicy, BillingKeyHandle, IdempotencyKey, KrwAmount, MerchantOrderId,
    PaymentState, ProviderKind, TransportReceipt, WebhookAuthentication,
};
use uuid::Uuid;

use crate::{
    digest::Sha256Digest,
    payment::model::{
        DonationCadence, DonationQueuedReceipt, PaymentEffectBoundary, PaymentRuntimeError,
        WebhookProcessingReceipt,
    },
};

pub type PaymentOwnerFuture<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, PaymentRuntimeError>> + Send + 'a>>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DonationIntentBinding {
    pub request_id: Uuid,
    pub offer_version_id: Uuid,
    pub offer_digest: Sha256Digest,
    pub tier_id: Uuid,
    pub cadence: DonationCadence,
    pub provider: ProviderKind,
    pub consent_receipt_digest: Sha256Digest,
    pub request_digest: Sha256Digest,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DonationIntentClaim {
    pub donation_intent_id: Uuid,
    pub binding_id: Uuid,
    pub job_id: Uuid,
    pub provider_idempotency_key: IdempotencyKey,
    pub amount: KrwAmount,
    pub claim_digest: Sha256Digest,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DonationIntentClaimDisposition {
    Execute(DonationIntentClaim),
    Replay(DonationQueuedReceipt),
    Conflict,
    InProgress,
}

pub struct PaymentMethodBindingCompletion<'a> {
    pub intent: &'a DonationIntentBinding,
    pub claim: &'a DonationIntentClaim,
    pub handle: &'a BillingKeyHandle,
    pub provider_receipt: &'a TransportReceipt,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PaymentMethodBindingCompletionDisposition {
    Committed(DonationQueuedReceipt),
    RejectedUnreferenced,
}

impl std::fmt::Debug for PaymentMethodBindingCompletion<'_> {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PaymentMethodBindingCompletion")
            .field("request_id", &self.intent.request_id)
            .field("donation_intent_id", &self.claim.donation_intent_id)
            .field("binding_id", &self.claim.binding_id)
            .field("provider", &self.handle.provider)
            .field("provider_receipt", &self.provider_receipt)
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct ChargeClaim {
    pub logical_charge_id: Uuid,
    pub attempt_id: Uuid,
    pub provider: ProviderKind,
    pub provider_idempotency_key: IdempotencyKey,
    pub merchant_order_id: MerchantOrderId,
    pub amount: KrwAmount,
    pub credential_use_policy: BillingCredentialUsePolicy,
    pub billing_key_handle: BillingKeyHandle,
    pub expected_provider_payment_id_sha256: Sha256Digest,
    pub claim_digest: Sha256Digest,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DonationChargeClaimBinding<'a> {
    pub job_id: Uuid,
    pub worker_id: &'a str,
    pub job_lease_token: Uuid,
    pub job_fencing_token: i64,
    pub job_payload_digest: &'a Sha256Digest,
    pub logical_charge_id: Uuid,
    pub charge_idempotency_key_sha256: &'a Sha256Digest,
    pub provider: ProviderKind,
    pub amount: KrwAmount,
}

impl std::fmt::Debug for ChargeClaim {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ChargeClaim")
            .field("logical_charge_id", &self.logical_charge_id)
            .field("attempt_id", &self.attempt_id)
            .field("provider", &self.provider)
            .field("amount", &self.amount)
            .field(
                "expected_provider_payment_id_sha256",
                &self.expected_provider_payment_id_sha256,
            )
            .field("claim_digest", &self.claim_digest)
            .field("merchant_order_id", &"<opaque>")
            .field("billing_key_handle", &"<opaque>")
            .finish()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChargeAcceptance {
    pub provider_payment_id_sha256: Sha256Digest,
    pub transport_request_sha256: Sha256Digest,
    pub transport_response_sha256: Sha256Digest,
    pub fixture_authority: &'static str,
    pub test_payment_outcome_config_digest: Sha256Digest,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChargeTerminalReceipt {
    pub attempt_id: Uuid,
    pub state: ChargeCompletionState,
    pub terminal_authority: Option<ChargeTerminalAuthority>,
    pub receipt_digest: Sha256Digest,
    pub fixture_authority: Option<&'static str>,
    pub test_payment_outcome_config_digest: Option<Sha256Digest>,
    pub effects: PaymentEffectBoundary,
    pub donation_fact_event: Option<DonationFactEventReceipt>,
    pub review_task_event: Option<PaymentReviewEventReceipt>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ChargeCompletionState {
    Succeeded,
    Failed,
    Refunded,
    ReconciliationRequired,
}

impl ChargeCompletionState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Succeeded => "SUCCEEDED",
            Self::Failed => "FAILED",
            Self::Refunded => "REFUNDED",
            Self::ReconciliationRequired => "RECONCILIATION_REQUIRED",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ChargeTerminalAuthority {
    ProviderFetchConfirmed,
    LocalPreDispatchRejection,
}

impl ChargeTerminalAuthority {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ProviderFetchConfirmed => "PROVIDER_FETCH_CONFIRMED",
            Self::LocalPreDispatchRejection => "LOCAL_PRE_DISPATCH_REJECTION",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LocalChargeFailureCode {
    InvalidRequest,
    PaymentRuntimeUnavailable,
    InternalError,
}

impl LocalChargeFailureCode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::InvalidRequest => "INVALID_REQUEST",
            Self::PaymentRuntimeUnavailable => "PAYMENT_RUNTIME_UNAVAILABLE",
            Self::InternalError => "INTERNAL_ERROR",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DonationFactEventReceipt {
    pub donation_fact_id: Uuid,
    pub fact_effect: DonationFactEffect,
    pub donation_fact_digest: Sha256Digest,
    pub charge_attempt_id: Uuid,
    pub charge_attempt_digest: Sha256Digest,
    pub provider_fetch_digest: Sha256Digest,
    pub outbox_event_id: Uuid,
    pub occurred_at_unix: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DonationFactEffect {
    Original,
    Reversal,
}

impl DonationFactEffect {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Original => "ORIGINAL",
            Self::Reversal => "REVERSAL",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PaymentReviewSourceKind {
    DonationPaymentFailure,
    SignedCollectionFailure,
}

impl PaymentReviewSourceKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::DonationPaymentFailure => "DONATION_PAYMENT_FAILURE",
            Self::SignedCollectionFailure => "SIGNED_COLLECTION_FAILURE",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PaymentReviewEventReceipt {
    pub review_task_id: Uuid,
    pub review_task_version: i64,
    pub review_task_digest: Sha256Digest,
    pub source_kind: PaymentReviewSourceKind,
    pub source_receipt_id: Uuid,
    pub source_receipt_digest: Sha256Digest,
    pub occurred_at_unix: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ChargeClaimDisposition {
    Execute(ChargeClaim),
    ResumeAccepted(ChargeClaim),
    Replay(ChargeTerminalReceipt),
    Conflict,
    InProgress,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReconciliationReason {
    ChargeOutcomeUnknown,
    FetchUnavailable,
    ProviderPending,
}

impl ReconciliationReason {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ChargeOutcomeUnknown => "CHARGE_OUTCOME_UNKNOWN",
            Self::FetchUnavailable => "FETCH_UNAVAILABLE",
            Self::ProviderPending => "PROVIDER_PENDING",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthoritativePaymentObservation {
    pub provider: ProviderKind,
    pub provider_payment_id_sha256: Sha256Digest,
    pub merchant_order_id_sha256: Sha256Digest,
    pub attempt_id: Uuid,
    pub amount: KrwAmount,
    pub state: PaymentState,
    pub provider_observed_at_unix: i64,
    pub transport_request_sha256: Sha256Digest,
    pub transport_response_sha256: Sha256Digest,
    pub provider_fetch_digest: Sha256Digest,
    pub fixture_authority: &'static str,
    pub test_payment_outcome_config_digest: Sha256Digest,
}

#[derive(Clone, Eq, PartialEq)]
pub struct WebhookClaim {
    pub claim_id: Uuid,
    pub attempt_id: Uuid,
    pub merchant_order_id: MerchantOrderId,
    pub amount: KrwAmount,
    pub claim_digest: Sha256Digest,
}

impl std::fmt::Debug for WebhookClaim {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("WebhookClaim")
            .field("claim_id", &self.claim_id)
            .field("attempt_id", &self.attempt_id)
            .field("amount", &self.amount)
            .field("claim_digest", &self.claim_digest)
            .field("merchant_order_id", &"<opaque>")
            .finish()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WebhookClaimBinding {
    pub provider: ProviderKind,
    pub event_identity_sha256: Sha256Digest,
    pub locator_kind: PaymentLocatorKind,
    pub locator_sha256: Sha256Digest,
    pub body_sha256: Sha256Digest,
    pub hint_sha256: Sha256Digest,
    pub authentication: WebhookAuthenticationReceipt,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PaymentLocatorKind {
    ProviderPaymentId,
    MerchantOrderId,
}

impl PaymentLocatorKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ProviderPaymentId => "PROVIDER_PAYMENT_ID",
            Self::MerchantOrderId => "MERCHANT_ORDER_ID",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WebhookAuthenticationReceipt {
    Verified {
        signature_sha256: Sha256Digest,
        signed_payload_sha256: Sha256Digest,
    },
    NotAvailableFetchRequired,
}

impl WebhookAuthenticationReceipt {
    pub fn from_provider(value: &WebhookAuthentication) -> Result<Self, PaymentRuntimeError> {
        match value {
            WebhookAuthentication::VerifiedSignature {
                signature_sha256,
                signed_payload_sha256,
                ..
            } => Ok(Self::Verified {
                signature_sha256: signature_sha256
                    .parse()
                    .map_err(|_| PaymentRuntimeError::InvalidRequest)?,
                signed_payload_sha256: signed_payload_sha256
                    .parse()
                    .map_err(|_| PaymentRuntimeError::InvalidRequest)?,
            }),
            WebhookAuthentication::NotAvailableFetchRequired => Ok(Self::NotAvailableFetchRequired),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WebhookClaimDisposition {
    Execute(WebhookClaim),
    Replay(WebhookProcessingReceipt),
    Conflict,
    InProgress,
}

/// Closed owner-function surface. No method accepts table names, arbitrary SQL,
/// generic JSON, contract state, entitlement state, or public-access state.
pub trait PaymentOwnerFunctions: Send + Sync {
    fn claim_donation_intent<'a>(
        &'a self,
        binding: &'a DonationIntentBinding,
        expected_amount: KrwAmount,
    ) -> PaymentOwnerFuture<'a, DonationIntentClaimDisposition>;

    fn complete_payment_method_binding<'a>(
        &'a self,
        completion: PaymentMethodBindingCompletion<'a>,
    ) -> PaymentOwnerFuture<'a, PaymentMethodBindingCompletionDisposition>;

    fn fail_donation_intent<'a>(
        &'a self,
        intent: &'a DonationIntentBinding,
        claim: &'a DonationIntentClaim,
        safe_code: &'static str,
    ) -> PaymentOwnerFuture<'a, ()>;

    fn claim_charge<'a>(
        &'a self,
        binding: DonationChargeClaimBinding<'a>,
    ) -> PaymentOwnerFuture<'a, ChargeClaimDisposition>;

    fn complete_charge<'a>(
        &'a self,
        claim: &'a ChargeClaim,
        observation: &'a AuthoritativePaymentObservation,
    ) -> PaymentOwnerFuture<'a, ChargeTerminalReceipt>;

    fn accept_charge<'a>(
        &'a self,
        claim: &'a ChargeClaim,
        acceptance: &'a ChargeAcceptance,
    ) -> PaymentOwnerFuture<'a, ()>;

    fn fail_charge<'a>(
        &'a self,
        claim: &'a ChargeClaim,
        safe_code: LocalChargeFailureCode,
        evidence_digest: &'a Sha256Digest,
    ) -> PaymentOwnerFuture<'a, ChargeTerminalReceipt>;

    fn require_charge_reconciliation<'a>(
        &'a self,
        claim: &'a ChargeClaim,
        reason: ReconciliationReason,
        evidence_digest: &'a Sha256Digest,
    ) -> PaymentOwnerFuture<'a, ()>;

    fn claim_webhook<'a>(
        &'a self,
        binding: &'a WebhookClaimBinding,
    ) -> PaymentOwnerFuture<'a, WebhookClaimDisposition>;

    fn complete_webhook<'a>(
        &'a self,
        binding: &'a WebhookClaimBinding,
        claim: &'a WebhookClaim,
        observation: &'a AuthoritativePaymentObservation,
    ) -> PaymentOwnerFuture<'a, WebhookProcessingReceipt>;

    fn release_webhook_claim<'a>(
        &'a self,
        binding: &'a WebhookClaimBinding,
        claim: &'a WebhookClaim,
        safe_code: &'static str,
    ) -> PaymentOwnerFuture<'a, ()>;
}
