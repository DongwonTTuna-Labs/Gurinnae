#![forbid(unsafe_code)]

//! Closed, fixture-only payment-provider codecs for the R6e donation runtime.
//!
//! This crate intentionally contains no HTTP client. Provider calls are made
//! only through [`PaymentTransport`], whose live mode is rejected by every
//! adapter in this revision. Webhooks yield hints, never payment truth;
//! [`FetchedPayment`] can be produced only by an authenticated provider fetch.

mod deterministic_fixture;
mod error;
mod fixture;
mod model;
mod provider;
pub mod providers;
mod scenario;
mod secret;
mod transport;
mod vault;

pub use deterministic_fixture::{
    DeterministicFixtureProviderFactory, FixturePaymentOutcome, FixtureProviderPaymentIdDigest,
};
pub use error::{PaymentProviderError, PaymentTransportError, VaultError};
pub use fixture::{FixtureExchange, FixtureTransport};
pub use model::{
    AdapterEnvironment, AttemptId, BillingAuthorization, BillingCredentialKind,
    BillingCredentialUsePolicy, BillingKeyHandle, BillingKeyMaterial, ChargeAcknowledgement,
    ChargeInstrument, ChargeRequest, ExecutionMode, FetchPaymentRequest, FetchedPayment,
    IdempotencyKey, IssueBillingKeyReceipt, IssueBillingKeyRequest, KeyVersion, KrwAmount,
    MerchantOrderId, PaymentLocator, PaymentState, ProviderCapabilities, ProviderEventIdentity,
    ProviderKind, ProviderOperation, ProviderPaymentId, RefundAcknowledgement, RefundRequest,
    ScheduleOwnership, TestFixtureAuthority, TransportReceipt, WebhookAuthentication,
    WebhookEnvelope, WebhookHeaders, WebhookHint, WebhookReplayPolicy, WebhookSignatureSupport,
};
pub use provider::{PaymentProvider, ProviderFuture};
pub use scenario::{FixtureProviderBundle, FixtureWebhook, ProviderFixtureScenario};
pub use secret::{SecretText, WebhookSigningKey};
pub use transport::{
    DisabledLiveTransport, PaymentTransport, TransportFuture, TransportMode, TransportRequest,
    TransportResponse,
};
pub use vault::{BillingKeyVault, DisabledLiveBillingKeyVault, InMemoryTestFixtureBillingKeyVault};
