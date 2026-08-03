use thiserror::Error;

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PaymentProviderError {
    #[error("payment provider input is invalid")]
    InvalidInput,
    #[error("payment provider and credential kinds do not match")]
    ProviderMismatch,
    #[error("payment provider operation is unsupported")]
    UnsupportedOperation,
    #[error("live payment provider execution is disabled")]
    LiveExecutionDisabled,
    #[error("payment transport failed before dispatch")]
    NotDispatched,
    #[error("payment mutation outcome is unknown and requires an authoritative fetch")]
    OutcomeUnknown,
    #[error("payment provider rejected the request")]
    ProviderRejected,
    #[error("payment provider authentication failed")]
    AuthenticationFailed,
    #[error("payment provider is rate limited")]
    RateLimited,
    #[error("payment provider is unavailable")]
    Unavailable,
    #[error("payment provider response is invalid")]
    InvalidResponse,
    #[error("payment webhook authentication failed")]
    WebhookAuthenticationFailed,
    #[error("payment webhook replay policy failed")]
    WebhookReplayPolicyFailed,
    #[error("payment webhook hint cannot be bound to the expected attempt")]
    WebhookBindingMismatch,
    #[error("payment fixture does not match the adapter request")]
    FixtureMismatch,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PaymentTransportError {
    #[error("live payment transport is disabled")]
    LiveExecutionDisabled,
    #[error("payment request was not dispatched")]
    NotDispatched,
    #[error("payment request dispatch outcome is unknown")]
    OutcomeUnknown,
    #[error("payment transport fixture does not match")]
    FixtureMismatch,
    #[error("payment transport response is unavailable")]
    Unavailable,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum VaultError {
    #[error("billing-key vault input is invalid")]
    InvalidInput,
    #[error("billing-key vault entry is missing")]
    Missing,
    #[error("billing-key vault credential use policy does not match")]
    UsePolicyMismatch,
    #[error("billing-key vault integrity check failed")]
    Integrity,
    #[error("live billing-key vault is not configured")]
    LiveVaultDisabled,
    #[error("billing-key vault is unavailable")]
    Unavailable,
}

impl From<PaymentTransportError> for PaymentProviderError {
    fn from(error: PaymentTransportError) -> Self {
        match error {
            PaymentTransportError::LiveExecutionDisabled => Self::LiveExecutionDisabled,
            PaymentTransportError::NotDispatched => Self::NotDispatched,
            PaymentTransportError::OutcomeUnknown => Self::OutcomeUnknown,
            PaymentTransportError::FixtureMismatch => Self::FixtureMismatch,
            PaymentTransportError::Unavailable => Self::Unavailable,
        }
    }
}
