use std::fmt;

use super::{KeyVersion, PaymentLocator, ProviderEventIdentity, ProviderKind};
use crate::{PaymentProviderError, SecretText};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WebhookAuthentication {
    VerifiedSignature {
        algorithm: &'static str,
        key_version: KeyVersion,
        signed_at_unix: i64,
        signature_sha256: String,
        signed_payload_sha256: String,
    },
    NotAvailableFetchRequired,
}

impl WebhookAuthentication {
    pub const fn is_verified(&self) -> bool {
        matches!(self, Self::VerifiedSignature { .. })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WebhookReplayPolicy {
    pub now_unix: i64,
    pub tolerance_seconds: i64,
}

impl WebhookReplayPolicy {
    pub fn validate(self) -> Result<Self, PaymentProviderError> {
        if self.tolerance_seconds <= 0 {
            Err(PaymentProviderError::InvalidInput)
        } else {
            Ok(self)
        }
    }
}

pub struct WebhookHeaders {
    stripe_signature: Option<SecretText>,
}

impl WebhookHeaders {
    pub const fn none() -> Self {
        Self {
            stripe_signature: None,
        }
    }

    pub fn stripe(signature: SecretText) -> Self {
        Self {
            stripe_signature: Some(signature),
        }
    }

    pub(crate) fn stripe_signature(&self) -> Option<&str> {
        self.stripe_signature
            .as_ref()
            .map(SecretText::expose_for_provider_codec)
    }
}

impl fmt::Debug for WebhookHeaders {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("WebhookHeaders(<redacted>)")
    }
}

pub struct WebhookEnvelope<'a> {
    pub headers: &'a WebhookHeaders,
    pub body: &'a [u8],
    pub replay_policy: WebhookReplayPolicy,
}

impl fmt::Debug for WebhookEnvelope<'_> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("WebhookEnvelope")
            .field("headers", &"<redacted>")
            .field("body", &"<redacted>")
            .field("body_length", &self.body.len())
            .field("replay_policy", &self.replay_policy)
            .finish()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WebhookHint {
    provider: ProviderKind,
    event_identity: ProviderEventIdentity,
    locator: PaymentLocator,
    authentication: WebhookAuthentication,
    body_sha256: String,
    hint_sha256: String,
}

impl WebhookHint {
    pub(crate) fn new(
        provider: ProviderKind,
        event_identity: ProviderEventIdentity,
        locator: PaymentLocator,
        authentication: WebhookAuthentication,
        body_sha256: String,
        hint_sha256: String,
    ) -> Self {
        Self {
            provider,
            event_identity,
            locator,
            authentication,
            body_sha256,
            hint_sha256,
        }
    }

    pub const fn provider(&self) -> ProviderKind {
        self.provider
    }

    pub fn event_identity(&self) -> &ProviderEventIdentity {
        &self.event_identity
    }

    pub fn locator(&self) -> &PaymentLocator {
        &self.locator
    }

    pub fn authentication(&self) -> &WebhookAuthentication {
        &self.authentication
    }

    pub fn body_sha256(&self) -> &str {
        &self.body_sha256
    }

    pub fn hint_sha256(&self) -> &str {
        &self.hint_sha256
    }
}
