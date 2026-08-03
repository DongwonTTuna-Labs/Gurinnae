use std::fmt;

use zeroize::Zeroize;

use crate::PaymentProviderError;

/// Provider material that must never be serialized, displayed, or cloned.
pub struct SecretText(String);

impl SecretText {
    pub fn try_new(value: String) -> Result<Self, PaymentProviderError> {
        if value.is_empty()
            || value.len() > 4096
            || value.bytes().any(|byte| byte.is_ascii_control())
        {
            return Err(PaymentProviderError::InvalidInput);
        }
        Ok(Self(value))
    }

    pub(crate) fn expose_for_provider_codec(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for SecretText {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecretText(<redacted>)")
    }
}

impl Drop for SecretText {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

/// A webhook signing key stays inside the credential-owning egress process.
pub struct WebhookSigningKey(Vec<u8>);

impl WebhookSigningKey {
    pub fn try_new(value: Vec<u8>) -> Result<Self, PaymentProviderError> {
        if value.len() < 32 {
            return Err(PaymentProviderError::InvalidInput);
        }
        Ok(Self(value))
    }

    pub(crate) fn expose_for_verification(&self) -> &[u8] {
        &self.0
    }
}

impl fmt::Debug for WebhookSigningKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("WebhookSigningKey(<redacted>)")
    }
}

impl Drop for WebhookSigningKey {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

pub(crate) struct SecretBytes(Vec<u8>);

impl SecretBytes {
    pub(crate) fn new(value: Vec<u8>) -> Self {
        Self(value)
    }

    pub(crate) fn expose(&self) -> &[u8] {
        &self.0
    }

    pub(crate) fn into_inner(mut self) -> Vec<u8> {
        let value = std::mem::take(&mut self.0);
        self.0.zeroize();
        value
    }

    pub(crate) fn destroy(mut self) {
        self.0.zeroize();
    }
}

impl fmt::Debug for SecretBytes {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SecretBytes")
            .field("bytes", &"<redacted>")
            .field("length", &self.0.len())
            .finish()
    }
}

impl Drop for SecretBytes {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}
