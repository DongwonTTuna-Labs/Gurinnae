use std::{future::Future, pin::Pin};

use crate::{
    IdempotencyKey, PaymentTransportError, ProviderKind, ProviderOperation, secret::SecretBytes,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransportMode {
    TestFixture,
    Live,
}

/// A closed provider request. The transport maps provider/operation to an
/// allowlisted endpoint and injects credentials; adapters cannot choose a URL.
pub struct TransportRequest {
    provider: ProviderKind,
    operation: ProviderOperation,
    idempotency_key: Option<IdempotencyKey>,
    body: SecretBytes,
}

impl TransportRequest {
    pub(crate) fn new(
        provider: ProviderKind,
        operation: ProviderOperation,
        idempotency_key: Option<IdempotencyKey>,
        body: Vec<u8>,
    ) -> Self {
        Self {
            provider,
            operation,
            idempotency_key,
            body: SecretBytes::new(body),
        }
    }

    pub const fn provider(&self) -> ProviderKind {
        self.provider
    }

    pub const fn operation(&self) -> ProviderOperation {
        self.operation
    }

    pub const fn idempotency_key(&self) -> Option<IdempotencyKey> {
        self.idempotency_key
    }

    /// Explicit secret-consuming boundary for an egress transport.
    pub fn body_for_egress(&self) -> &[u8] {
        self.body.expose()
    }
}

impl std::fmt::Debug for TransportRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("TransportRequest")
            .field("provider", &self.provider)
            .field("operation", &self.operation)
            .field("idempotency_key", &"<redacted>")
            .field("body", &"<redacted>")
            .field("body_length", &self.body.expose().len())
            .finish()
    }
}

pub struct TransportResponse {
    status: u16,
    body: SecretBytes,
}

impl TransportResponse {
    pub fn from_egress(status: u16, body: Vec<u8>) -> Result<Self, PaymentTransportError> {
        if !(100..=599).contains(&status) {
            return Err(PaymentTransportError::Unavailable);
        }
        Ok(Self {
            status,
            body: SecretBytes::new(body),
        })
    }

    pub const fn status(&self) -> u16 {
        self.status
    }

    pub(crate) fn body_for_codec(&self) -> &[u8] {
        self.body.expose()
    }

    pub(crate) fn into_body(self) -> Vec<u8> {
        self.body.into_inner()
    }
}

impl std::fmt::Debug for TransportResponse {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("TransportResponse")
            .field("status", &self.status)
            .field("body", &"<redacted>")
            .field("body_length", &self.body.expose().len())
            .finish()
    }
}

pub type TransportFuture<'a> =
    Pin<Box<dyn Future<Output = Result<TransportResponse, PaymentTransportError>> + Send + 'a>>;

pub trait PaymentTransport: Send + Sync {
    fn mode(&self) -> TransportMode;
    fn execute(&self, request: TransportRequest) -> TransportFuture<'_>;
}

/// Deliberately non-functional until a separately reviewed live egress
/// implementation is supplied outside this crate.
#[derive(Clone, Copy, Debug, Default)]
pub struct DisabledLiveTransport;

impl PaymentTransport for DisabledLiveTransport {
    fn mode(&self) -> TransportMode {
        TransportMode::Live
    }

    fn execute(&self, _request: TransportRequest) -> TransportFuture<'_> {
        Box::pin(async { Err(PaymentTransportError::LiveExecutionDisabled) })
    }
}
