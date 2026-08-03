use gurine_payment_providers::KrwAmount;

use crate::digest::Sha256Digest;

use super::{
    model::{PaymentRuntimeError, WebhookProcessingReceipt},
    store::{
        AuthoritativePaymentObservation, ChargeAcceptance, ChargeClaim, ChargeClaimDisposition,
        ChargeTerminalReceipt, DonationChargeClaimBinding, DonationIntentBinding,
        DonationIntentClaim, DonationIntentClaimDisposition, LocalChargeFailureCode,
        PaymentMethodBindingCompletion, PaymentMethodBindingCompletionDisposition,
        PaymentOwnerFunctions, PaymentOwnerFuture, ReconciliationReason, WebhookClaim,
        WebhookClaimBinding, WebhookClaimDisposition,
    },
};

#[derive(Clone, Copy, Debug, Default)]
pub struct DisabledPaymentStore;

impl PaymentOwnerFunctions for DisabledPaymentStore {
    fn claim_donation_intent<'a>(
        &'a self,
        _binding: &'a DonationIntentBinding,
        _expected_amount: KrwAmount,
    ) -> PaymentOwnerFuture<'a, DonationIntentClaimDisposition> {
        unavailable()
    }

    fn complete_payment_method_binding<'a>(
        &'a self,
        _completion: PaymentMethodBindingCompletion<'a>,
    ) -> PaymentOwnerFuture<'a, PaymentMethodBindingCompletionDisposition> {
        unavailable()
    }

    fn fail_donation_intent<'a>(
        &'a self,
        _intent: &'a DonationIntentBinding,
        _claim: &'a DonationIntentClaim,
        _safe_code: &'static str,
    ) -> PaymentOwnerFuture<'a, ()> {
        unavailable()
    }

    fn claim_charge<'a>(
        &'a self,
        _binding: DonationChargeClaimBinding<'a>,
    ) -> PaymentOwnerFuture<'a, ChargeClaimDisposition> {
        unavailable()
    }

    fn complete_charge<'a>(
        &'a self,
        _claim: &'a ChargeClaim,
        _observation: &'a AuthoritativePaymentObservation,
    ) -> PaymentOwnerFuture<'a, ChargeTerminalReceipt> {
        unavailable()
    }

    fn accept_charge<'a>(
        &'a self,
        _claim: &'a ChargeClaim,
        _acceptance: &'a ChargeAcceptance,
    ) -> PaymentOwnerFuture<'a, ()> {
        unavailable()
    }

    fn fail_charge<'a>(
        &'a self,
        _claim: &'a ChargeClaim,
        _safe_code: LocalChargeFailureCode,
        _evidence_digest: &'a Sha256Digest,
    ) -> PaymentOwnerFuture<'a, ChargeTerminalReceipt> {
        unavailable()
    }

    fn require_charge_reconciliation<'a>(
        &'a self,
        _claim: &'a ChargeClaim,
        _reason: ReconciliationReason,
        _evidence_digest: &'a Sha256Digest,
    ) -> PaymentOwnerFuture<'a, ()> {
        unavailable()
    }

    fn claim_webhook<'a>(
        &'a self,
        _binding: &'a WebhookClaimBinding,
    ) -> PaymentOwnerFuture<'a, WebhookClaimDisposition> {
        unavailable()
    }

    fn complete_webhook<'a>(
        &'a self,
        _binding: &'a WebhookClaimBinding,
        _claim: &'a WebhookClaim,
        _observation: &'a AuthoritativePaymentObservation,
    ) -> PaymentOwnerFuture<'a, WebhookProcessingReceipt> {
        unavailable()
    }

    fn release_webhook_claim<'a>(
        &'a self,
        _binding: &'a WebhookClaimBinding,
        _claim: &'a WebhookClaim,
        _safe_code: &'static str,
    ) -> PaymentOwnerFuture<'a, ()> {
        unavailable()
    }
}

fn unavailable<'a, T>() -> PaymentOwnerFuture<'a, T> {
    Box::pin(async { Err(PaymentRuntimeError::Unavailable) })
}
