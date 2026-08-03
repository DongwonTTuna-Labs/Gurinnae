use gurine_payment_providers::{
    AttemptId, BillingKeyMaterial, ChargeAcknowledgement, ChargeInstrument, ChargeRequest,
    FetchPaymentRequest, FetchedPayment, PaymentLocator, PaymentProvider, PaymentProviderError,
    PaymentState,
};

use crate::digest::Sha256Digest;

use super::{
    receipt::{provider_error_code, provider_fetch_evidence_digest},
    store::{ChargeClaim, LocalChargeFailureCode, ReconciliationReason},
};

pub(super) enum ProviderFetchOutcome {
    Fetched(FetchedPayment),
    Reconciliation(ReconciliationReason, Sha256Digest),
}

pub(super) enum ChargeDispatchOutcome {
    Accepted(ChargeAcknowledgement),
    FetchAuthoritativeState,
    LocalReject(PaymentProviderError),
    Reconciliation(ReconciliationReason, Sha256Digest),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ChargeErrorDisposition {
    LocalReject,
    FetchAuthoritativeState,
    ReconciliationRequired,
}

pub(super) async fn dispatch_charge(
    provider: &dyn PaymentProvider,
    claim: &ChargeClaim,
    material: &BillingKeyMaterial,
) -> ChargeDispatchOutcome {
    let charge = provider
        .charge(ChargeRequest {
            attempt_id: AttemptId::new(claim.attempt_id),
            idempotency_key: claim.provider_idempotency_key,
            merchant_order_id: &claim.merchant_order_id,
            amount: claim.amount,
            instrument: ChargeInstrument::Stored(material),
        })
        .await;
    match charge {
        Ok(acknowledgement) => ChargeDispatchOutcome::Accepted(acknowledgement),
        Err(error) if charge_error_disposition(error) == ChargeErrorDisposition::LocalReject => {
            ChargeDispatchOutcome::LocalReject(error)
        }
        Err(error)
            if charge_error_disposition(error)
                == ChargeErrorDisposition::ReconciliationRequired =>
        {
            ChargeDispatchOutcome::Reconciliation(
                ReconciliationReason::ChargeOutcomeUnknown,
                error_evidence_digest(error),
            )
        }
        Err(_) => ChargeDispatchOutcome::FetchAuthoritativeState,
    }
}

pub(super) async fn fetch_after_acceptance(
    provider: &dyn PaymentProvider,
    claim: &ChargeClaim,
    acknowledgement: &ChargeAcknowledgement,
) -> ProviderFetchOutcome {
    fetch_authoritative(
        provider,
        FetchPaymentRequest::from_charge(claim.provider, acknowledgement, claim.amount),
    )
    .await
}

pub(super) async fn fetch_accepted_claim(
    provider: &dyn PaymentProvider,
    claim: &ChargeClaim,
) -> ProviderFetchOutcome {
    fetch_authoritative(provider, merchant_order_fetch_request(claim)).await
}

fn merchant_order_fetch_request(claim: &ChargeClaim) -> FetchPaymentRequest {
    FetchPaymentRequest {
        provider: claim.provider,
        locator: PaymentLocator::MerchantOrderId(claim.merchant_order_id.clone()),
        expected_attempt_id: AttemptId::new(claim.attempt_id),
        expected_merchant_order_id: claim.merchant_order_id.clone(),
        expected_amount: claim.amount,
    }
}

async fn fetch_authoritative(
    provider: &dyn PaymentProvider,
    request: FetchPaymentRequest,
) -> ProviderFetchOutcome {
    match provider.fetch_payment(&request).await {
        Ok(fetched) => match generic_reconciliation_reason(fetched.state) {
            Some(reason) => ProviderFetchOutcome::Reconciliation(
                reason,
                provider_fetch_evidence_digest(&fetched),
            ),
            None => ProviderFetchOutcome::Fetched(fetched),
        },
        Err(error) => ProviderFetchOutcome::Reconciliation(
            ReconciliationReason::FetchUnavailable,
            error_evidence_digest(error),
        ),
    }
}

const fn generic_reconciliation_reason(state: PaymentState) -> Option<ReconciliationReason> {
    match state {
        PaymentState::Pending => Some(ReconciliationReason::ProviderPending),
        PaymentState::Succeeded
        | PaymentState::Failed
        | PaymentState::Canceled
        | PaymentState::PartiallyRefunded
        | PaymentState::Refunded => None,
    }
}

fn error_evidence_digest(error: PaymentProviderError) -> Sha256Digest {
    Sha256Digest::of(provider_error_code(error).as_bytes())
}

pub(super) const fn local_failure_code(error: PaymentProviderError) -> LocalChargeFailureCode {
    match error {
        PaymentProviderError::LiveExecutionDisabled | PaymentProviderError::NotDispatched => {
            LocalChargeFailureCode::PaymentRuntimeUnavailable
        }
        PaymentProviderError::InvalidInput
        | PaymentProviderError::ProviderMismatch
        | PaymentProviderError::UnsupportedOperation
        | PaymentProviderError::FixtureMismatch => LocalChargeFailureCode::InvalidRequest,
        _ => LocalChargeFailureCode::InternalError,
    }
}

const fn charge_error_disposition(error: PaymentProviderError) -> ChargeErrorDisposition {
    match error {
        PaymentProviderError::InvalidInput
        | PaymentProviderError::ProviderMismatch
        | PaymentProviderError::UnsupportedOperation
        | PaymentProviderError::LiveExecutionDisabled
        | PaymentProviderError::NotDispatched
        | PaymentProviderError::FixtureMismatch => ChargeErrorDisposition::LocalReject,
        PaymentProviderError::OutcomeUnknown => ChargeErrorDisposition::ReconciliationRequired,
        PaymentProviderError::ProviderRejected
        | PaymentProviderError::AuthenticationFailed
        | PaymentProviderError::RateLimited
        | PaymentProviderError::Unavailable
        | PaymentProviderError::InvalidResponse
        | PaymentProviderError::WebhookAuthenticationFailed
        | PaymentProviderError::WebhookReplayPolicyFailed
        | PaymentProviderError::WebhookBindingMismatch => {
            ChargeErrorDisposition::FetchAuthoritativeState
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ChargeErrorDisposition, PaymentProviderError, PaymentState, ReconciliationReason,
        charge_error_disposition, generic_reconciliation_reason,
    };

    #[test]
    fn errors_before_dispatch_are_permanent_local_rejects() {
        for error in [
            PaymentProviderError::InvalidInput,
            PaymentProviderError::ProviderMismatch,
            PaymentProviderError::UnsupportedOperation,
            PaymentProviderError::LiveExecutionDisabled,
            PaymentProviderError::NotDispatched,
            PaymentProviderError::FixtureMismatch,
        ] {
            assert_eq!(
                charge_error_disposition(error),
                ChargeErrorDisposition::LocalReject
            );
        }
    }

    #[test]
    fn only_an_ambiguous_dispatch_skips_direct_authoritative_fetch() {
        assert_eq!(
            charge_error_disposition(PaymentProviderError::OutcomeUnknown),
            ChargeErrorDisposition::ReconciliationRequired
        );
        for error in [
            PaymentProviderError::ProviderRejected,
            PaymentProviderError::AuthenticationFailed,
            PaymentProviderError::RateLimited,
            PaymentProviderError::Unavailable,
            PaymentProviderError::InvalidResponse,
            PaymentProviderError::WebhookAuthenticationFailed,
            PaymentProviderError::WebhookReplayPolicyFailed,
            PaymentProviderError::WebhookBindingMismatch,
        ] {
            assert_eq!(
                charge_error_disposition(error),
                ChargeErrorDisposition::FetchAuthoritativeState
            );
        }
    }

    #[test]
    fn partial_refund_uses_full_observation_completion() {
        assert_eq!(
            generic_reconciliation_reason(PaymentState::Pending),
            Some(ReconciliationReason::ProviderPending)
        );
        assert_eq!(
            generic_reconciliation_reason(PaymentState::PartiallyRefunded),
            None
        );
    }
}
