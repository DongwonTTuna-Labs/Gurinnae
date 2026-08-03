use std::fmt;

use gurine_auth::assertion::canonical::canonical_json;
use gurine_jobs::postgres::ClaimedJob;
use gurine_payment_providers::{KrwAmount, ProviderKind};
use serde::{Deserialize, Deserializer, Serialize, de::Error as _};
use thiserror::Error;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;
use zeroize::Zeroize;

use crate::digest::Sha256Digest;

pub const DONATION_INTENT_REQUEST_SCHEMA: &str = "donation-intent-request.v1";
pub const DONATION_QUEUED_SCHEMA: &str = "donation-intent-queued.v1";
pub const WEBHOOK_ACCEPTANCE_SCHEMA: &str = "provider-webhook-acceptance.v1";

#[derive(Clone, Debug)]
pub struct ClaimedDonationChargeJob {
    pub job: ClaimedJob,
    pub provider: ProviderKind,
    pub amount: KrwAmount,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum DonationCadence {
    OneTime,
    Recurring,
}

impl DonationCadence {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::OneTime => "ONE_TIME",
            Self::Recurring => "RECURRING",
        }
    }
}

pub struct PaymentAuthorizationToken(String);

impl PaymentAuthorizationToken {
    pub fn sha256(&self) -> Sha256Digest {
        Sha256Digest::of(self.0.as_bytes())
    }

    pub(crate) fn consume_if_matches(
        mut self,
        expected: &Sha256Digest,
    ) -> Result<(), PaymentRuntimeError> {
        let matches = self.sha256() == *expected;
        self.0.zeroize();
        if matches {
            Ok(())
        } else {
            Err(PaymentRuntimeError::InvalidRequest)
        }
    }
}

impl fmt::Debug for PaymentAuthorizationToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("PaymentAuthorizationToken(<redacted>)")
    }
}

impl Drop for PaymentAuthorizationToken {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl<'de> Deserialize<'de> for PaymentAuthorizationToken {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        if value.is_empty()
            || value.len() > 4096
            || value.bytes().any(|byte| byte.is_ascii_control())
        {
            Err(D::Error::custom("payment authorization is invalid"))
        } else {
            Ok(Self(value))
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DonationIntentRequest {
    pub schema_version: String,
    pub request_id: Uuid,
    pub offer_version_id: Uuid,
    pub offer_digest: Sha256Digest,
    pub tier_id: Uuid,
    pub cadence: DonationCadence,
    pub provider: ProviderKind,
    pub consent_receipt_digest: Sha256Digest,
    pub payment_authorization_token: PaymentAuthorizationToken,
}

impl fmt::Debug for DonationIntentRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("DonationIntentRequest")
            .field("schema_version", &self.schema_version)
            .field("request_id", &self.request_id)
            .field("offer_version_id", &self.offer_version_id)
            .field("offer_digest", &self.offer_digest)
            .field("tier_id", &self.tier_id)
            .field("cadence", &self.cadence)
            .field("provider", &self.provider)
            .field("consent_receipt_digest", &self.consent_receipt_digest)
            .field("payment_authorization_token", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DonationQueuedReceipt {
    pub schema_version: &'static str,
    pub request_id: Uuid,
    pub job_id: Uuid,
    pub status: &'static str,
    pub receipt_digest: Sha256Digest,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DonationChargeJobPayload {
    pub schema_version: String,
    pub donation_schedule_id: Uuid,
    pub donation_schedule_version: i64,
    pub donation_schedule_digest: Sha256Digest,
    pub payment_method_binding_id: Uuid,
    pub payment_method_binding_digest: Sha256Digest,
    pub offer_version_id: Uuid,
    pub offer_digest: Sha256Digest,
    pub tier_id: Uuid,
    pub consent_receipt_digest: Sha256Digest,
    pub logical_charge_id: Uuid,
    pub charge_idempotency_key_sha256: Sha256Digest,
    pub scheduled_for: String,
}

impl DonationChargeJobPayload {
    pub fn validate(&self) -> Result<(), PaymentRuntimeError> {
        let scheduled = OffsetDateTime::parse(&self.scheduled_for, &Rfc3339)
            .map_err(|_| PaymentRuntimeError::InvalidRequest)?;
        let canonical_scheduled = scheduled
            .format(&Rfc3339)
            .map_err(|_| PaymentRuntimeError::InvalidRequest)?;
        if self.schema_version != "donation-charge-job.v1"
            || self.donation_schedule_version <= 0
            || canonical_scheduled != self.scheduled_for
            || charge_job_idempotency_digest(
                self.logical_charge_id,
                &self.payment_method_binding_digest,
                &self.scheduled_for,
            ) != self.charge_idempotency_key_sha256
        {
            Err(PaymentRuntimeError::InvalidRequest)
        } else {
            Ok(())
        }
    }

    pub fn digest(&self) -> Result<Sha256Digest, PaymentRuntimeError> {
        self.validate()?;
        let bytes = canonical_json(self).map_err(|_| PaymentRuntimeError::InvalidRequest)?;
        Ok(Sha256Digest::of(&bytes))
    }
}

pub(crate) fn charge_job_idempotency_digest(
    logical_charge_id: Uuid,
    payment_method_binding_digest: &Sha256Digest,
    scheduled_for: &str,
) -> Sha256Digest {
    let domain = b"gurine-donation-charge-job-idempotency.v1\0";
    let mut preimage = Vec::with_capacity(
        domain.len() + 16 + payment_method_binding_digest.as_str().len() + scheduled_for.len(),
    );
    preimage.extend_from_slice(domain);
    preimage.extend_from_slice(logical_charge_id.as_bytes());
    preimage.extend_from_slice(payment_method_binding_digest.as_str().as_bytes());
    preimage.extend_from_slice(scheduled_for.as_bytes());
    Sha256Digest::of(&preimage)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PaymentEffectBoundary {
    None,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ChargeExecution {
    Confirmed(ChargeTerminalReceiptSummary),
    Rejected(ChargeTerminalReceiptSummary),
    ReconciliationRequired { attempt_id: Uuid },
    Replay(ChargeTerminalReceiptSummary),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChargeTerminalReceiptSummary {
    pub attempt_id: Uuid,
    pub receipt_digest: Sha256Digest,
    pub effects: PaymentEffectBoundary,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum WebhookDisposition {
    Applied,
    Duplicate,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebhookProcessingReceipt {
    pub schema_version: &'static str,
    pub provider: ProviderKind,
    pub event_identity_sha256: Sha256Digest,
    pub disposition: WebhookDisposition,
    pub receipt_digest: Sha256Digest,
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PaymentRuntimeError {
    #[error("payment runtime is unavailable")]
    Unavailable,
    #[error("payment request is invalid")]
    InvalidRequest,
    #[error("payment request conflicts with an immutable receipt")]
    Conflict,
    #[error("payment operation is already in progress")]
    InProgress,
    #[error("payment provider authentication failed")]
    AuthenticationFailed,
    #[error("payment provider outcome requires reconciliation")]
    ReconciliationRequired,
    #[error("payment owner function failed")]
    OwnerFunction,
}

impl From<gurine_payment_providers::PaymentProviderError> for PaymentRuntimeError {
    fn from(error: gurine_payment_providers::PaymentProviderError) -> Self {
        use gurine_payment_providers::PaymentProviderError;
        match error {
            PaymentProviderError::WebhookAuthenticationFailed
            | PaymentProviderError::AuthenticationFailed
            | PaymentProviderError::WebhookReplayPolicyFailed => Self::AuthenticationFailed,
            PaymentProviderError::OutcomeUnknown
            | PaymentProviderError::RateLimited
            | PaymentProviderError::Unavailable => Self::ReconciliationRequired,
            PaymentProviderError::InvalidInput
            | PaymentProviderError::ProviderMismatch
            | PaymentProviderError::UnsupportedOperation
            | PaymentProviderError::ProviderRejected
            | PaymentProviderError::InvalidResponse
            | PaymentProviderError::WebhookBindingMismatch
            | PaymentProviderError::FixtureMismatch => Self::InvalidRequest,
            PaymentProviderError::LiveExecutionDisabled | PaymentProviderError::NotDispatched => {
                Self::Unavailable
            }
        }
    }
}

impl From<gurine_payment_providers::VaultError> for PaymentRuntimeError {
    fn from(_error: gurine_payment_providers::VaultError) -> Self {
        Self::Unavailable
    }
}
