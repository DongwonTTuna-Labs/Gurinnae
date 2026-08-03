use gurine_payment_providers::{KrwAmount, PaymentState, ProviderKind};
use serde_json::Value;
use sqlx::FromRow;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::{
    digest::Sha256Digest,
    payment::{
        model::{PaymentEffectBoundary, PaymentRuntimeError},
        store::{
            ChargeCompletionState, ChargeTerminalAuthority, ChargeTerminalReceipt,
            DonationFactEffect, DonationFactEventReceipt, PaymentReviewEventReceipt,
            PaymentReviewSourceKind,
        },
    },
};

#[derive(FromRow)]
pub(super) struct IntentClaimRow {
    pub disposition: String,
    pub request_id: Option<Uuid>,
    pub donation_intent_id: Option<Uuid>,
    pub binding_id: Option<Uuid>,
    pub job_id: Option<Uuid>,
    pub amount_whole_krw: Option<i64>,
    pub provider_idempotency_hmac: Option<String>,
    pub provider_idempotency_version: Option<String>,
    pub claim_digest: Option<String>,
    pub queued_receipt_digest: Option<String>,
}

#[derive(FromRow)]
pub(super) struct BindingReceiptRow {
    pub disposition: String,
    pub request_id: Option<Uuid>,
    pub job_id: Option<Uuid>,
    pub status: Option<String>,
    pub queued_receipt_digest: Option<String>,
}

#[derive(FromRow)]
pub(super) struct TransitionRow {
    pub disposition: String,
    pub state: Option<String>,
}

#[derive(FromRow)]
pub(super) struct JobClaimRow {
    pub disposition: String,
    pub job_id: Option<Uuid>,
    pub job_type: Option<String>,
    pub queue: Option<String>,
    pub payload: Option<Value>,
    pub provider: Option<String>,
    pub amount_whole_krw: Option<i64>,
    pub attempt: Option<i32>,
    pub max_attempts: Option<i32>,
    pub lease_token: Option<Uuid>,
    pub fencing_token: Option<i64>,
    pub lease_expires_at: Option<OffsetDateTime>,
    pub job_binding_digest: Option<String>,
}

#[derive(FromRow)]
pub(super) struct ChargeClaimRow {
    pub disposition: String,
    pub attempt_id: Option<Uuid>,
    pub attempt_state: Option<String>,
    pub provider: Option<String>,
    pub provider_idempotency_hmac: Option<String>,
    pub provider_idempotency_version: Option<String>,
    pub merchant_order_hmac: Option<String>,
    pub merchant_order_version: Option<String>,
    pub merchant_order_digest: Option<String>,
    pub expected_provider_payment_digest: Option<String>,
    pub amount_whole_krw: Option<i64>,
    pub credential_use_policy: Option<String>,
    pub billing_key_secret_reference: Option<String>,
    pub billing_key_hmac: Option<String>,
    pub billing_key_version: Option<String>,
    pub binding_root_id: Option<Uuid>,
    pub logical_charge_id: Option<Uuid>,
    pub job_binding_digest: Option<String>,
    pub claim_digest: Option<String>,
}

#[derive(FromRow)]
pub(super) struct TerminalRow {
    pub disposition: String,
    pub attempt_id: Option<Uuid>,
    pub state: Option<String>,
    pub terminal_authority: Option<String>,
    pub receipt_digest: Option<String>,
    pub fixture_authority: Option<String>,
    pub outcome_config_digest: Option<String>,
    pub effects: Option<String>,
    pub donation_fact_id: Option<Uuid>,
    pub donation_fact_effect: Option<String>,
    pub donation_fact_digest: Option<String>,
    pub charge_attempt_digest: Option<String>,
    pub provider_fetch_digest: Option<String>,
    pub donation_occurred_at: Option<OffsetDateTime>,
    pub donation_outbox_event_id: Option<Uuid>,
    pub review_task_id: Option<Uuid>,
    pub review_task_version: Option<i64>,
    pub review_task_digest: Option<String>,
    pub review_source_kind: Option<String>,
    pub review_source_receipt_id: Option<Uuid>,
    pub review_source_receipt_digest: Option<String>,
    pub review_occurred_at: Option<OffsetDateTime>,
}

#[derive(FromRow)]
pub(super) struct WebhookClaimRow {
    pub disposition: String,
    pub provider: Option<String>,
    pub event_identity_digest: Option<String>,
    pub claim_id: Option<Uuid>,
    pub claim_digest: Option<String>,
    pub attempt_id: Option<Uuid>,
    pub logical_charge_id: Option<Uuid>,
    pub job_binding_digest: Option<String>,
    pub charge_idempotency_digest: Option<String>,
    pub merchant_order_digest: Option<String>,
    pub amount_whole_krw: Option<i64>,
    pub webhook_receipt_digest: Option<String>,
}

#[derive(FromRow)]
pub(super) struct WebhookReceiptRow {
    pub disposition: String,
    pub provider: Option<String>,
    pub event_identity_digest: Option<String>,
    pub receipt_digest: Option<String>,
}

pub(super) fn provider(value: &str) -> Result<ProviderKind, PaymentRuntimeError> {
    match value {
        "TOSS_PAYMENTS" => Ok(ProviderKind::TossPayments),
        "KAKAO_PAY" => Ok(ProviderKind::KakaoPay),
        "STRIPE" => Ok(ProviderKind::Stripe),
        _ => Err(PaymentRuntimeError::OwnerFunction),
    }
}

pub(super) fn payment_state(value: PaymentState) -> &'static str {
    match value {
        PaymentState::Pending => "PENDING",
        PaymentState::Succeeded => "SUCCEEDED",
        PaymentState::Failed => "FAILED",
        PaymentState::Canceled => "CANCELED",
        PaymentState::PartiallyRefunded => "PARTIALLY_REFUNDED",
        PaymentState::Refunded => "REFUNDED",
    }
}

impl TerminalRow {
    pub(super) fn into_receipt(self) -> Result<ChargeTerminalReceipt, PaymentRuntimeError> {
        if !matches!(self.disposition.as_str(), "APPLIED" | "REPLAY") {
            return Err(if self.disposition == "CONFLICT" {
                PaymentRuntimeError::Conflict
            } else {
                PaymentRuntimeError::OwnerFunction
            });
        }
        terminal_receipt(TerminalFields {
            attempt_id: self.attempt_id,
            state: self.state,
            terminal_authority: self.terminal_authority,
            receipt_digest: self.receipt_digest,
            fixture_authority: self.fixture_authority,
            outcome_config_digest: self.outcome_config_digest,
            effects: self.effects,
            donation_fact_id: self.donation_fact_id,
            donation_fact_effect: self.donation_fact_effect,
            donation_fact_digest: self.donation_fact_digest,
            charge_attempt_digest: self.charge_attempt_digest,
            provider_fetch_digest: self.provider_fetch_digest,
            donation_occurred_at: self.donation_occurred_at,
            donation_outbox_event_id: self.donation_outbox_event_id,
            review_task_id: self.review_task_id,
            review_task_version: self.review_task_version,
            review_task_digest: self.review_task_digest,
            review_source_kind: self.review_source_kind,
            review_source_receipt_id: self.review_source_receipt_id,
            review_source_receipt_digest: self.review_source_receipt_digest,
            review_occurred_at: self.review_occurred_at,
        })
    }
}

struct TerminalFields {
    attempt_id: Option<Uuid>,
    state: Option<String>,
    terminal_authority: Option<String>,
    receipt_digest: Option<String>,
    fixture_authority: Option<String>,
    outcome_config_digest: Option<String>,
    effects: Option<String>,
    donation_fact_id: Option<Uuid>,
    donation_fact_effect: Option<String>,
    donation_fact_digest: Option<String>,
    charge_attempt_digest: Option<String>,
    provider_fetch_digest: Option<String>,
    donation_occurred_at: Option<OffsetDateTime>,
    donation_outbox_event_id: Option<Uuid>,
    review_task_id: Option<Uuid>,
    review_task_version: Option<i64>,
    review_task_digest: Option<String>,
    review_source_kind: Option<String>,
    review_source_receipt_id: Option<Uuid>,
    review_source_receipt_digest: Option<String>,
    review_occurred_at: Option<OffsetDateTime>,
}

fn terminal_receipt(fields: TerminalFields) -> Result<ChargeTerminalReceipt, PaymentRuntimeError> {
    let attempt_id = fields
        .attempt_id
        .ok_or(PaymentRuntimeError::OwnerFunction)?;
    let donation_fact_event = donation_event(attempt_id, &fields)?;
    let review_task_event = review_event(&fields)?;
    let test_payment_outcome_config_digest = optional_digest(fields.outcome_config_digest.clone())?;
    Ok(ChargeTerminalReceipt {
        attempt_id,
        state: completion_state(required(fields.state)?)?,
        terminal_authority: authority(fields.terminal_authority.as_deref())?,
        receipt_digest: digest(fields.receipt_digest)?,
        fixture_authority: fixture_authority(fields.fixture_authority.as_deref())?,
        test_payment_outcome_config_digest,
        effects: match fields.effects.as_deref() {
            Some("NONE") => PaymentEffectBoundary::None,
            _ => return Err(PaymentRuntimeError::OwnerFunction),
        },
        donation_fact_event,
        review_task_event,
    })
}

fn donation_event(
    attempt_id: Uuid,
    fields: &TerminalFields,
) -> Result<Option<DonationFactEventReceipt>, PaymentRuntimeError> {
    let Some(id) = fields.donation_fact_id else {
        return Ok(None);
    };
    Ok(Some(DonationFactEventReceipt {
        donation_fact_id: id,
        fact_effect: match required(fields.donation_fact_effect.clone())?.as_str() {
            "ORIGINAL" => DonationFactEffect::Original,
            "REVERSAL" => DonationFactEffect::Reversal,
            _ => return Err(PaymentRuntimeError::OwnerFunction),
        },
        donation_fact_digest: digest(fields.donation_fact_digest.clone())?,
        charge_attempt_id: attempt_id,
        charge_attempt_digest: digest(fields.charge_attempt_digest.clone())?,
        provider_fetch_digest: digest(fields.provider_fetch_digest.clone())?,
        outbox_event_id: required(fields.donation_outbox_event_id)?,
        occurred_at_unix: required(fields.donation_occurred_at)?.unix_timestamp(),
    }))
}

fn review_event(
    fields: &TerminalFields,
) -> Result<Option<PaymentReviewEventReceipt>, PaymentRuntimeError> {
    let Some(id) = fields.review_task_id else {
        return Ok(None);
    };
    Ok(Some(PaymentReviewEventReceipt {
        review_task_id: id,
        review_task_version: required(fields.review_task_version)?,
        review_task_digest: digest(fields.review_task_digest.clone())?,
        source_kind: match required(fields.review_source_kind.clone())?.as_str() {
            "DONATION_PAYMENT_FAILURE" => PaymentReviewSourceKind::DonationPaymentFailure,
            "SIGNED_COLLECTION_FAILURE" => PaymentReviewSourceKind::SignedCollectionFailure,
            _ => return Err(PaymentRuntimeError::OwnerFunction),
        },
        source_receipt_id: required(fields.review_source_receipt_id)?,
        source_receipt_digest: digest(fields.review_source_receipt_digest.clone())?,
        occurred_at_unix: required(fields.review_occurred_at)?.unix_timestamp(),
    }))
}

fn completion_state(value: String) -> Result<ChargeCompletionState, PaymentRuntimeError> {
    match value.as_str() {
        "SUCCEEDED" => Ok(ChargeCompletionState::Succeeded),
        "FAILED" => Ok(ChargeCompletionState::Failed),
        "REFUNDED" => Ok(ChargeCompletionState::Refunded),
        "RECONCILIATION_REQUIRED" => Ok(ChargeCompletionState::ReconciliationRequired),
        _ => Err(PaymentRuntimeError::OwnerFunction),
    }
}

fn authority(value: Option<&str>) -> Result<Option<ChargeTerminalAuthority>, PaymentRuntimeError> {
    match value {
        None => Ok(None),
        Some("PROVIDER_FETCH_CONFIRMED") => {
            Ok(Some(ChargeTerminalAuthority::ProviderFetchConfirmed))
        }
        Some("LOCAL_PRE_DISPATCH_REJECTION") => {
            Ok(Some(ChargeTerminalAuthority::LocalPreDispatchRejection))
        }
        _ => Err(PaymentRuntimeError::OwnerFunction),
    }
}

fn fixture_authority(value: Option<&str>) -> Result<Option<&'static str>, PaymentRuntimeError> {
    match value {
        None => Ok(None),
        Some("TEST_FIXTURE") => Ok(Some("TEST_FIXTURE")),
        _ => Err(PaymentRuntimeError::OwnerFunction),
    }
}

pub(super) fn digest(value: Option<String>) -> Result<Sha256Digest, PaymentRuntimeError> {
    required(value)?
        .parse()
        .map_err(|_| PaymentRuntimeError::OwnerFunction)
}

fn optional_digest(value: Option<String>) -> Result<Option<Sha256Digest>, PaymentRuntimeError> {
    value
        .map(|item| item.parse().map_err(|_| PaymentRuntimeError::OwnerFunction))
        .transpose()
}

pub(super) fn amount(value: Option<i64>) -> Result<KrwAmount, PaymentRuntimeError> {
    KrwAmount::try_new(required(value)?).map_err(Into::into)
}

pub(super) fn required<T>(value: Option<T>) -> Result<T, PaymentRuntimeError> {
    value.ok_or(PaymentRuntimeError::OwnerFunction)
}
