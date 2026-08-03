use std::{future::Future, pin::Pin};

use crate::{
    ChargeAcknowledgement, ChargeRequest, FetchPaymentRequest, FetchedPayment,
    IssueBillingKeyReceipt, IssueBillingKeyRequest, PaymentProviderError, ProviderCapabilities,
    RefundAcknowledgement, RefundRequest, WebhookEnvelope, WebhookHint,
};

pub type ProviderFuture<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, PaymentProviderError>> + Send + 'a>>;

pub trait PaymentProvider: Send + Sync {
    fn capabilities(&self) -> ProviderCapabilities;

    fn issue_billing_key<'a>(
        &'a self,
        request: &'a IssueBillingKeyRequest,
    ) -> ProviderFuture<'a, IssueBillingKeyReceipt>;

    fn charge<'a>(
        &'a self,
        request: ChargeRequest<'a>,
    ) -> ProviderFuture<'a, ChargeAcknowledgement>;

    fn refund<'a>(
        &'a self,
        request: &'a RefundRequest,
    ) -> ProviderFuture<'a, RefundAcknowledgement>;

    /// Produces only a routing/authentication hint. It cannot express a
    /// payment state and therefore cannot authorize a donation fact.
    fn verify_webhook(
        &self,
        webhook: WebhookEnvelope<'_>,
    ) -> Result<WebhookHint, PaymentProviderError>;

    /// The sole provider-authoritative payment-state read.
    fn fetch_payment<'a>(
        &'a self,
        request: &'a FetchPaymentRequest,
    ) -> ProviderFuture<'a, FetchedPayment>;
}
