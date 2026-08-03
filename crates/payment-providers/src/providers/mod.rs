use std::sync::Arc;

use serde::{Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};

use crate::{
    AdapterEnvironment, ExecutionMode, IdempotencyKey, PaymentProviderError, PaymentTransport,
    ProviderEventIdentity, ProviderKind, ProviderOperation, TransportMode, TransportReceipt,
    TransportRequest,
};

pub mod kakao_pay;
pub mod stripe;
pub mod toss_payments;

struct FixtureRuntime {
    transport: Arc<dyn PaymentTransport>,
}

struct ExchangeOutput {
    body: Vec<u8>,
    receipt: TransportReceipt,
}

impl FixtureRuntime {
    fn new(
        environment: AdapterEnvironment,
        transport: Arc<dyn PaymentTransport>,
    ) -> Result<Self, PaymentProviderError> {
        if !matches!(environment, AdapterEnvironment::TestFixture(_))
            || transport.mode() != TransportMode::TestFixture
        {
            return Err(PaymentProviderError::LiveExecutionDisabled);
        }
        Ok(Self { transport })
    }

    async fn exchange<T: Serialize>(
        &self,
        provider: ProviderKind,
        operation: ProviderOperation,
        idempotency_key: Option<IdempotencyKey>,
        request: &T,
    ) -> Result<ExchangeOutput, PaymentProviderError> {
        let request_body =
            serde_json::to_vec(request).map_err(|_| PaymentProviderError::InvalidInput)?;
        let request_sha256 = sha256_hex(&request_body);
        let response = self
            .transport
            .execute(TransportRequest::new(
                provider,
                operation,
                idempotency_key,
                request_body,
            ))
            .await?;
        let status = response.status();
        let response_sha256 = sha256_hex(response.body_for_codec());
        match status {
            200..=299 => {}
            401 | 403 => return Err(PaymentProviderError::AuthenticationFailed),
            429 => return Err(PaymentProviderError::RateLimited),
            500..=599 => return Err(PaymentProviderError::Unavailable),
            _ => return Err(PaymentProviderError::ProviderRejected),
        }
        Ok(ExchangeOutput {
            body: response.into_body(),
            receipt: TransportReceipt {
                execution_mode: ExecutionMode::TestFixtureOnly,
                provider,
                operation,
                request_sha256,
                response_sha256,
                http_status: status,
            },
        })
    }
}

fn fixture_runtime(
    environment: AdapterEnvironment,
    transport: Arc<dyn PaymentTransport>,
) -> Result<FixtureRuntime, PaymentProviderError> {
    FixtureRuntime::new(environment, transport)
}

fn decode<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, PaymentProviderError> {
    serde_json::from_slice(bytes).map_err(|_| PaymentProviderError::InvalidResponse)
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    hex_lower(&Sha256::digest(bytes))
}

fn hint_digest(
    provider: ProviderKind,
    event_identity: &ProviderEventIdentity,
    locator: &str,
    body_sha256: &str,
) -> String {
    let value = format!(
        "gurine-payment-webhook-hint.v1\n{}\n{}\n{}\n{}",
        provider.as_str(),
        event_identity.as_str(),
        locator,
        body_sha256
    );
    sha256_hex(value.as_bytes())
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(char::from(HEX[usize::from(byte >> 4)]));
        output.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    output
}
