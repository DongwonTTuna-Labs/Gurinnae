use gurine_jobs::postgres::ClaimedJob;
use gurine_payment_providers::{
    ChargeAcknowledgement, ExecutionMode, FetchedPayment, PaymentLocator, PaymentProviderError,
    PaymentState, ProviderOperation, ProviderPaymentId, WebhookHint,
};

use crate::digest::Sha256Digest;

use super::{
    model::{
        ChargeTerminalReceiptSummary, DONATION_QUEUED_SCHEMA, DonationChargeJobPayload,
        DonationIntentRequest, DonationQueuedReceipt, PaymentEffectBoundary, PaymentRuntimeError,
    },
    store::{
        AuthoritativePaymentObservation, ChargeAcceptance, ChargeClaim, ChargeCompletionState,
        ChargeTerminalAuthority, ChargeTerminalReceipt, DonationFactEffect, DonationIntentBinding,
        PaymentLocatorKind, PaymentReviewSourceKind, WebhookAuthenticationReceipt,
        WebhookClaimBinding,
    },
};

pub fn consent_receipt_digest(request: &DonationIntentRequest) -> Sha256Digest {
    let preimage = format!(
        "gurine-donation-consent-receipt.v1\n{}\n{}\n{}\n{}\n{}\n{}\nDONATION-INDEPENDENCE-NOTICE-v1\n후원은 접근권이 아니며 조사 대상 면제가 아닙니다\nACCEPTED",
        request.request_id,
        request.offer_version_id,
        request.offer_digest,
        request.tier_id,
        request.cadence.as_str(),
        request.provider.as_str(),
    );
    Sha256Digest::of(preimage.as_bytes())
}

pub(super) fn parse_charge_job(
    job: &ClaimedJob,
) -> Result<DonationChargeJobPayload, PaymentRuntimeError> {
    if job.job_type != "DONATION_CHARGE"
        || job.queue != "billing-gateway"
        || job.fence.fencing_token <= 0
    {
        return Err(PaymentRuntimeError::InvalidRequest);
    }
    let payload = serde_json::from_value::<DonationChargeJobPayload>(job.payload.clone())
        .map_err(|_| PaymentRuntimeError::InvalidRequest)?;
    payload.validate()?;
    Ok(payload)
}

pub(super) fn validate_queued_receipt(
    binding: &DonationIntentBinding,
    expected_job_id: Option<uuid::Uuid>,
    receipt: &DonationQueuedReceipt,
) -> Result<(), PaymentRuntimeError> {
    if receipt.schema_version != DONATION_QUEUED_SCHEMA
        || receipt.request_id != binding.request_id
        || receipt.job_id.is_nil()
        || expected_job_id.is_some_and(|value| receipt.job_id != value)
        || receipt.status != "QUEUED"
    {
        Err(PaymentRuntimeError::OwnerFunction)
    } else {
        Ok(())
    }
}

pub(super) fn validate_terminal_receipt(
    receipt: &ChargeTerminalReceipt,
    observation: Option<&AuthoritativePaymentObservation>,
    expected_outcome_config_digest: &Sha256Digest,
) -> Result<(), PaymentRuntimeError> {
    if receipt.effects != PaymentEffectBoundary::None {
        return Err(PaymentRuntimeError::OwnerFunction);
    }
    if receipt.terminal_authority == Some(ChargeTerminalAuthority::LocalPreDispatchRejection) {
        return validate_local_rejection(receipt, observation);
    }
    if receipt.state == ChargeCompletionState::ReconciliationRequired {
        return validate_partial_refund_reconciliation(
            receipt,
            observation,
            expected_outcome_config_digest,
        );
    }
    let fixture_authority = receipt
        .fixture_authority
        .ok_or(PaymentRuntimeError::OwnerFunction)?;
    let outcome_config_digest = receipt
        .test_payment_outcome_config_digest
        .as_ref()
        .ok_or(PaymentRuntimeError::OwnerFunction)?;
    if receipt.terminal_authority != Some(ChargeTerminalAuthority::ProviderFetchConfirmed)
        || fixture_authority != "TEST_FIXTURE"
        || outcome_config_digest != expected_outcome_config_digest
        || observation.is_some_and(|value| {
            value.fixture_authority != fixture_authority
                || value.test_payment_outcome_config_digest != *outcome_config_digest
                || value.attempt_id != receipt.attempt_id
        })
    {
        return Err(PaymentRuntimeError::OwnerFunction);
    }
    match receipt.state {
        ChargeCompletionState::Succeeded => {
            validate_observed_state(observation, PaymentState::Succeeded)?;
            validate_donation_fact(receipt, observation, DonationFactEffect::Original)
        }
        ChargeCompletionState::Refunded => {
            validate_observed_state(observation, PaymentState::Refunded)?;
            validate_donation_fact(receipt, observation, DonationFactEffect::Reversal)
        }
        ChargeCompletionState::Failed => {
            validate_failed_observed_state(observation)?;
            validate_review_task(receipt)
        }
        ChargeCompletionState::ReconciliationRequired => Err(PaymentRuntimeError::OwnerFunction),
    }
}

fn validate_failed_observed_state(
    observation: Option<&AuthoritativePaymentObservation>,
) -> Result<(), PaymentRuntimeError> {
    if observation
        .is_some_and(|value| !matches!(value.state, PaymentState::Failed | PaymentState::Canceled))
    {
        Err(PaymentRuntimeError::OwnerFunction)
    } else {
        Ok(())
    }
}

fn validate_partial_refund_reconciliation(
    receipt: &ChargeTerminalReceipt,
    observation: Option<&AuthoritativePaymentObservation>,
    expected_outcome_config_digest: &Sha256Digest,
) -> Result<(), PaymentRuntimeError> {
    if receipt.terminal_authority.is_some()
        || receipt.fixture_authority != Some("TEST_FIXTURE")
        || receipt.test_payment_outcome_config_digest.as_ref()
            != Some(expected_outcome_config_digest)
        || receipt.donation_fact_event.is_some()
        || receipt.review_task_event.is_some()
        || observation.is_some_and(|value| {
            value.state != PaymentState::PartiallyRefunded
                || value.fixture_authority != "TEST_FIXTURE"
                || value.test_payment_outcome_config_digest != *expected_outcome_config_digest
                || value.attempt_id != receipt.attempt_id
        })
    {
        Err(PaymentRuntimeError::OwnerFunction)
    } else {
        Ok(())
    }
}

fn validate_observed_state(
    observation: Option<&AuthoritativePaymentObservation>,
    expected: PaymentState,
) -> Result<(), PaymentRuntimeError> {
    if observation.is_some_and(|value| value.state != expected) {
        Err(PaymentRuntimeError::OwnerFunction)
    } else {
        Ok(())
    }
}

fn validate_local_rejection(
    receipt: &ChargeTerminalReceipt,
    observation: Option<&AuthoritativePaymentObservation>,
) -> Result<(), PaymentRuntimeError> {
    if receipt.state != ChargeCompletionState::Failed
        || observation.is_some()
        || receipt.fixture_authority.is_some()
        || receipt.test_payment_outcome_config_digest.is_some()
        || receipt.donation_fact_event.is_some()
        || receipt.review_task_event.is_some()
    {
        Err(PaymentRuntimeError::OwnerFunction)
    } else {
        Ok(())
    }
}

fn validate_donation_fact(
    receipt: &ChargeTerminalReceipt,
    observation: Option<&AuthoritativePaymentObservation>,
    expected_effect: DonationFactEffect,
) -> Result<(), PaymentRuntimeError> {
    let Some(donation) = receipt.donation_fact_event.as_ref() else {
        return Err(PaymentRuntimeError::OwnerFunction);
    };
    if receipt.review_task_event.is_some()
        || donation.fact_effect != expected_effect
        || donation.charge_attempt_id != receipt.attempt_id
        || donation.outbox_event_id.is_nil()
        || observation.is_some_and(|value| {
            donation.provider_fetch_digest != value.provider_fetch_digest
                || donation.charge_attempt_id != value.attempt_id
        })
    {
        Err(PaymentRuntimeError::OwnerFunction)
    } else {
        Ok(())
    }
}

fn validate_review_task(receipt: &ChargeTerminalReceipt) -> Result<(), PaymentRuntimeError> {
    let Some(review) = receipt.review_task_event.as_ref() else {
        return Err(PaymentRuntimeError::OwnerFunction);
    };
    if review.source_kind != PaymentReviewSourceKind::DonationPaymentFailure
        || review.source_receipt_id != receipt.attempt_id
        || receipt.donation_fact_event.is_some()
    {
        Err(PaymentRuntimeError::OwnerFunction)
    } else {
        Ok(())
    }
}

pub(super) fn terminal_summary(receipt: &ChargeTerminalReceipt) -> ChargeTerminalReceiptSummary {
    ChargeTerminalReceiptSummary {
        attempt_id: receipt.attempt_id,
        receipt_digest: receipt.receipt_digest.clone(),
        effects: receipt.effects,
    }
}

pub(super) fn observation(
    fetched: &FetchedPayment,
    test_payment_outcome_config_digest: Sha256Digest,
) -> Result<AuthoritativePaymentObservation, PaymentRuntimeError> {
    let provider_payment_id_sha256 = opaque_digest(
        b"gurine-provider-payment-id.v1\0",
        fetched.provider_payment_id.as_str(),
    );
    let merchant_order_id_sha256 = opaque_digest(
        b"gurine-merchant-order-id.v1\0",
        fetched.merchant_order_id.as_str(),
    );
    let transport_request_sha256 = fetched
        .transport
        .request_sha256
        .parse()
        .map_err(|_| PaymentRuntimeError::InvalidRequest)?;
    let transport_response_sha256 = fetched
        .transport
        .response_sha256
        .parse()
        .map_err(|_| PaymentRuntimeError::InvalidRequest)?;
    let provider_fetch_digest = provider_fetch_digest(
        fetched,
        &provider_payment_id_sha256,
        &merchant_order_id_sha256,
    );
    Ok(AuthoritativePaymentObservation {
        provider: fetched.provider,
        provider_payment_id_sha256,
        merchant_order_id_sha256,
        attempt_id: fetched.attempt_id.get(),
        amount: fetched.amount,
        state: fetched.state,
        provider_observed_at_unix: fetched.provider_observed_at_unix,
        transport_request_sha256,
        transport_response_sha256,
        provider_fetch_digest,
        fixture_authority: "TEST_FIXTURE",
        test_payment_outcome_config_digest,
    })
}

pub(super) fn charge_acceptance(
    claim: &ChargeClaim,
    acknowledgement: &ChargeAcknowledgement,
    test_payment_outcome_config_digest: Sha256Digest,
) -> Result<ChargeAcceptance, PaymentRuntimeError> {
    let PaymentLocator::ProviderPaymentId(provider_payment_id) = &acknowledgement.locator else {
        return Err(PaymentRuntimeError::InvalidRequest);
    };
    if acknowledgement.attempt_id.get() != claim.attempt_id
        || acknowledgement.merchant_order_id != claim.merchant_order_id
        || acknowledgement.transport.execution_mode != ExecutionMode::TestFixtureOnly
        || acknowledgement.transport.provider != claim.provider
        || acknowledgement.transport.operation != ProviderOperation::Charge
    {
        return Err(PaymentRuntimeError::InvalidRequest);
    }
    Ok(ChargeAcceptance {
        provider_payment_id_sha256: provider_payment_id_digest(provider_payment_id),
        transport_request_sha256: acknowledgement
            .transport
            .request_sha256
            .parse()
            .map_err(|_| PaymentRuntimeError::InvalidRequest)?,
        transport_response_sha256: acknowledgement
            .transport
            .response_sha256
            .parse()
            .map_err(|_| PaymentRuntimeError::InvalidRequest)?,
        fixture_authority: "TEST_FIXTURE",
        test_payment_outcome_config_digest,
    })
}

pub(super) fn provider_payment_id_digest(value: &ProviderPaymentId) -> Sha256Digest {
    opaque_digest(b"gurine-provider-payment-id.v1\0", value.as_str())
}

pub(super) fn provider_fetch_evidence_digest(fetched: &FetchedPayment) -> Sha256Digest {
    let provider_payment_id_sha256 = opaque_digest(
        b"gurine-provider-payment-id.v1\0",
        fetched.provider_payment_id.as_str(),
    );
    let merchant_order_id_sha256 = opaque_digest(
        b"gurine-merchant-order-id.v1\0",
        fetched.merchant_order_id.as_str(),
    );
    provider_fetch_digest(
        fetched,
        &provider_payment_id_sha256,
        &merchant_order_id_sha256,
    )
}

fn provider_fetch_digest(
    fetched: &FetchedPayment,
    provider_payment_id_sha256: &Sha256Digest,
    merchant_order_id_sha256: &Sha256Digest,
) -> Sha256Digest {
    let preimage = format!(
        "gurine-provider-fetch-receipt.v1\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
        fetched.provider.as_str(),
        provider_payment_id_sha256,
        merchant_order_id_sha256,
        fetched.attempt_id.get(),
        fetched.amount.whole_krw(),
        provider_state_code(fetched.state),
        fetched.provider_observed_at_unix,
        fetched.transport.request_sha256,
        fetched.transport.response_sha256,
    );
    Sha256Digest::of(preimage.as_bytes())
}

const fn provider_state_code(state: PaymentState) -> &'static str {
    match state {
        PaymentState::Pending => "PENDING",
        PaymentState::Succeeded => "SUCCEEDED",
        PaymentState::Failed => "FAILED",
        PaymentState::Canceled => "CANCELED",
        PaymentState::PartiallyRefunded => "PARTIALLY_REFUNDED",
        PaymentState::Refunded => "REFUNDED",
    }
}

pub(super) fn webhook_binding(
    hint: &WebhookHint,
) -> Result<WebhookClaimBinding, PaymentRuntimeError> {
    let (locator_kind, locator_sha256) = locator_receipt(hint.locator());
    Ok(WebhookClaimBinding {
        provider: hint.provider(),
        event_identity_sha256: opaque_digest(
            b"gurine-provider-event-identity.v1\0",
            hint.event_identity().as_str(),
        ),
        locator_kind,
        locator_sha256,
        body_sha256: hint
            .body_sha256()
            .parse()
            .map_err(|_| PaymentRuntimeError::InvalidRequest)?,
        hint_sha256: hint
            .hint_sha256()
            .parse()
            .map_err(|_| PaymentRuntimeError::InvalidRequest)?,
        authentication: WebhookAuthenticationReceipt::from_provider(hint.authentication())?,
    })
}

fn locator_receipt(locator: &PaymentLocator) -> (PaymentLocatorKind, Sha256Digest) {
    match locator {
        PaymentLocator::ProviderPaymentId(value) => (
            PaymentLocatorKind::ProviderPaymentId,
            opaque_digest(b"gurine-provider-payment-id.v1\0", value.as_str()),
        ),
        PaymentLocator::MerchantOrderId(value) => (
            PaymentLocatorKind::MerchantOrderId,
            opaque_digest(b"gurine-merchant-order-id.v1\0", value.as_str()),
        ),
    }
}

fn opaque_digest(domain: &[u8], value: &str) -> Sha256Digest {
    let mut bytes = Vec::with_capacity(domain.len() + value.len());
    bytes.extend_from_slice(domain);
    bytes.extend_from_slice(value.as_bytes());
    Sha256Digest::of(&bytes)
}

pub(super) const fn provider_error_code(error: PaymentProviderError) -> &'static str {
    match error {
        PaymentProviderError::InvalidInput => "PAYMENT_INVALID_INPUT",
        PaymentProviderError::ProviderMismatch => "PAYMENT_PROVIDER_MISMATCH",
        PaymentProviderError::UnsupportedOperation => "PAYMENT_OPERATION_UNSUPPORTED",
        PaymentProviderError::LiveExecutionDisabled => "PAYMENT_LIVE_DISABLED",
        PaymentProviderError::NotDispatched => "PAYMENT_NOT_DISPATCHED",
        PaymentProviderError::OutcomeUnknown => "PAYMENT_OUTCOME_UNKNOWN",
        PaymentProviderError::ProviderRejected => "PAYMENT_PROVIDER_REJECTED",
        PaymentProviderError::AuthenticationFailed => "PAYMENT_AUTHENTICATION_FAILED",
        PaymentProviderError::RateLimited => "PAYMENT_RATE_LIMITED",
        PaymentProviderError::Unavailable => "PAYMENT_PROVIDER_UNAVAILABLE",
        PaymentProviderError::InvalidResponse => "PAYMENT_RESPONSE_INVALID",
        PaymentProviderError::WebhookAuthenticationFailed => "PAYMENT_WEBHOOK_AUTH_FAILED",
        PaymentProviderError::WebhookReplayPolicyFailed => "PAYMENT_WEBHOOK_REPLAY_REJECTED",
        PaymentProviderError::WebhookBindingMismatch => "PAYMENT_WEBHOOK_BINDING_MISMATCH",
        PaymentProviderError::FixtureMismatch => "PAYMENT_FIXTURE_MISMATCH",
    }
}
