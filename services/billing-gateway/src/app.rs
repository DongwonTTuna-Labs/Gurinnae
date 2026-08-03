use std::{future::Future, pin::Pin};

use gurine_payment_providers::{ProviderKind, WebhookHeaders};

use crate::{
    digest::Sha256Digest,
    payment::{
        DonationIntentRequest, DonationQueuedReceipt, FixtureDonationOffer, PaymentEngine,
        PaymentOwnerFunctions, PaymentRuntimeError, WebhookProcessingReceipt,
    },
};

pub type ApplicationFuture<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, PaymentRuntimeError>> + Send + 'a>>;

pub trait BillingApplication: Send + Sync {
    fn fixture_offer(&self) -> Result<FixtureDonationOffer, PaymentRuntimeError>;

    fn queue_donation_intent<'a>(
        &'a self,
        request: DonationIntentRequest,
        request_digest: Sha256Digest,
    ) -> ApplicationFuture<'a, DonationQueuedReceipt>;

    fn process_webhook<'a>(
        &'a self,
        provider: ProviderKind,
        headers: WebhookHeaders,
        body: Vec<u8>,
        now_unix: i64,
    ) -> ApplicationFuture<'a, WebhookProcessingReceipt>;
}

impl<S> BillingApplication for PaymentEngine<S>
where
    S: PaymentOwnerFunctions + 'static,
{
    fn fixture_offer(&self) -> Result<FixtureDonationOffer, PaymentRuntimeError> {
        PaymentEngine::fixture_offer(self).cloned()
    }

    fn queue_donation_intent<'a>(
        &'a self,
        request: DonationIntentRequest,
        request_digest: Sha256Digest,
    ) -> ApplicationFuture<'a, DonationQueuedReceipt> {
        Box::pin(PaymentEngine::queue_donation_intent(
            self,
            request,
            request_digest,
        ))
    }

    fn process_webhook<'a>(
        &'a self,
        provider: ProviderKind,
        headers: WebhookHeaders,
        body: Vec<u8>,
        now_unix: i64,
    ) -> ApplicationFuture<'a, WebhookProcessingReceipt> {
        Box::pin(async move {
            PaymentEngine::process_webhook(self, provider, &headers, &body, now_unix).await
        })
    }
}
