use std::{collections::VecDeque, sync::Mutex};

use crate::{
    IdempotencyKey, PaymentTransport, PaymentTransportError, ProviderKind, ProviderOperation,
    TransportFuture, TransportMode, TransportRequest, TransportResponse, secret::SecretBytes,
};

/// One exact provider codec exchange. Bodies remain redacted in diagnostics.
pub struct FixtureExchange {
    provider: ProviderKind,
    operation: ProviderOperation,
    idempotency_key: Option<IdempotencyKey>,
    expected_request: SecretBytes,
    response_status: u16,
    response_body: SecretBytes,
}

impl FixtureExchange {
    pub fn new(
        provider: ProviderKind,
        operation: ProviderOperation,
        idempotency_key: Option<IdempotencyKey>,
        expected_request: Vec<u8>,
        response_status: u16,
        response_body: Vec<u8>,
    ) -> Result<Self, PaymentTransportError> {
        if !(100..=599).contains(&response_status) {
            return Err(PaymentTransportError::FixtureMismatch);
        }
        Ok(Self {
            provider,
            operation,
            idempotency_key,
            expected_request: SecretBytes::new(expected_request),
            response_status,
            response_body: SecretBytes::new(response_body),
        })
    }

    fn matches(&self, request: &TransportRequest) -> bool {
        self.provider == request.provider()
            && self.operation == request.operation()
            && self.idempotency_key == request.idempotency_key()
            && self.expected_request.expose() == request.body_for_egress()
    }
}

impl std::fmt::Debug for FixtureExchange {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("FixtureExchange")
            .field("provider", &self.provider)
            .field("operation", &self.operation)
            .field("request", &"<redacted>")
            .field("response", &"<redacted>")
            .finish()
    }
}

pub struct FixtureTransport {
    exchanges: Mutex<VecDeque<FixtureExchange>>,
}

impl FixtureTransport {
    pub fn new(exchanges: Vec<FixtureExchange>) -> Self {
        Self {
            exchanges: Mutex::new(exchanges.into()),
        }
    }

    pub fn remaining(&self) -> Result<usize, PaymentTransportError> {
        self.exchanges
            .lock()
            .map(|items| items.len())
            .map_err(|_| PaymentTransportError::Unavailable)
    }
}

impl PaymentTransport for FixtureTransport {
    fn mode(&self) -> TransportMode {
        TransportMode::TestFixture
    }

    fn execute(&self, request: TransportRequest) -> TransportFuture<'_> {
        Box::pin(async move {
            let exchange = self
                .exchanges
                .lock()
                .map_err(|_| PaymentTransportError::Unavailable)?
                .pop_front()
                .ok_or(PaymentTransportError::FixtureMismatch)?;
            if !exchange.matches(&request) {
                return Err(PaymentTransportError::FixtureMismatch);
            }
            TransportResponse::from_egress(
                exchange.response_status,
                exchange.response_body.expose().to_vec(),
            )
        })
    }
}
