use gurine_payment_providers::{
    AttemptId, FetchPaymentRequest, FetchedPayment, PaymentProvider, PaymentProviderError,
    ProviderKind, WebhookEnvelope, WebhookHeaders, WebhookHint, WebhookReplayPolicy,
};

use super::{
    model::PaymentRuntimeError,
    receipt::webhook_binding,
    store::{WebhookClaim, WebhookClaimBinding},
};

pub(super) fn authenticate_webhook(
    provider_kind: ProviderKind,
    verifier: &dyn PaymentProvider,
    headers: &WebhookHeaders,
    body: &[u8],
    now_unix: i64,
) -> Result<(WebhookHint, WebhookClaimBinding), PaymentRuntimeError> {
    let hint = verifier.verify_webhook(WebhookEnvelope {
        headers,
        body,
        replay_policy: WebhookReplayPolicy {
            now_unix,
            tolerance_seconds: 300,
        },
    })?;
    if hint.provider() != provider_kind {
        return Err(PaymentRuntimeError::InvalidRequest);
    }
    let binding = webhook_binding(&hint)?;
    Ok((hint, binding))
}

pub(super) async fn fetch_webhook_payment(
    provider: &dyn PaymentProvider,
    hint: &WebhookHint,
    claim: &WebhookClaim,
) -> Result<FetchedPayment, PaymentProviderError> {
    let fetch = FetchPaymentRequest::from_webhook(
        hint,
        AttemptId::new(claim.attempt_id),
        claim.merchant_order_id.clone(),
        claim.amount,
    );
    provider.fetch_payment(&fetch).await
}
