use std::sync::{Arc, Mutex};

use gurine_jobs::{fencing::Fence, postgres::ClaimedJob};
use gurine_payment_providers::{
    AttemptId, BillingCredentialUsePolicy, BillingKeyHandle, BillingKeyVault, ChargeInstrument,
    ChargeRequest, DeterministicFixtureProviderFactory, FetchPaymentRequest, FixturePaymentOutcome,
    IdempotencyKey, InMemoryTestFixtureBillingKeyVault, IssueBillingKeyRequest, KeyVersion,
    KrwAmount, MerchantOrderId, PaymentLocator, PaymentState, ProviderEventIdentity,
    ProviderFixtureScenario, ProviderKind, ProviderPaymentId, RefundRequest, TestFixtureAuthority,
};
use serde_json::json;
use time::OffsetDateTime;
use uuid::Uuid;

use super::{
    engine::consent_receipt_digest,
    model::charge_job_idempotency_digest,
    store::{
        AuthoritativePaymentObservation, DonationFactEffect, DonationFactEventReceipt,
        DonationIntentBinding, PaymentMethodBindingCompletion, PaymentReviewEventReceipt,
        PaymentReviewSourceKind, ReconciliationReason, WebhookClaimBinding,
    },
    *,
};
use crate::digest::Sha256Digest;

#[path = "payment_tests/binding.rs"]
mod binding;
#[path = "payment_tests/fixtures.rs"]
mod fixtures;
#[path = "payment_tests/owner.rs"]
mod owner;
#[path = "payment_tests/webhook.rs"]
mod webhook;

use fixtures::*;
use owner::{AcceptanceBehavior, CompletionBehavior};

#[test]
fn fixture_offer_is_explicitly_non_production() {
    let offer = FixtureDonationOffer::test_fixture();
    assert_eq!(offer.authority, "TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY");
    assert_eq!(offer.production_readiness_effect, "NONE");
    assert_eq!(offer.tiers.len(), 3);
}

#[test]
fn raw_authorization_is_redacted_and_not_serializable() -> Result<(), PaymentRuntimeError> {
    let request = intent_request(ProviderKind::TossPayments)?;
    let diagnostic = format!("{request:?}");
    assert!(!diagnostic.contains("fixture-secret"));
    assert!(diagnostic.contains("<redacted>"));
    Ok(())
}

#[tokio::test]
async fn intent_is_durable_before_provider_and_duplicate_does_not_call_provider_twice()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture(ProviderKind::TossPayments, PaymentState::Succeeded)?;
    let receipt = fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::TossPayments)?, digest(b'6'))
        .await?;
    assert_eq!(receipt.status, "QUEUED");
    assert_eq!(
        fixture.owner.snapshot(|state| state.calls.clone())?,
        vec!["claim_intent", "complete_binding"]
    );

    let replay = fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::TossPayments)?, digest(b'6'))
        .await?;
    assert_eq!(replay, receipt);
    assert_eq!(
        fixture.owner.snapshot(|state| state.calls.clone())?,
        vec!["claim_intent", "complete_binding", "claim_intent"]
    );
    Ok(())
}

#[tokio::test]
async fn charge_fetch_is_truth_and_charge_replay_is_provider_free()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture(ProviderKind::TossPayments, PaymentState::Succeeded)?;
    fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::TossPayments)?, digest(b'6'))
        .await?;
    let result = fixture
        .engine
        .execute_charge_job("billing-fixture", &charge_job(&fixture.scenario))
        .await?;
    assert!(matches!(result, ChargeExecution::Confirmed(_)));
    assert_eq!(
        fixture.owner.snapshot(|state| state.terminal_state)?,
        Some(PaymentState::Succeeded)
    );
    let replay = fixture
        .engine
        .execute_charge_job("billing-fixture", &charge_job(&fixture.scenario))
        .await?;
    assert!(matches!(replay, ChargeExecution::Replay(_)));
    assert_eq!(
        fixture.owner.snapshot(|state| state
            .calls
            .iter()
            .filter(|call| **call == "complete_charge")
            .count())?,
        1
    );
    Ok(())
}

#[tokio::test]
async fn committed_charge_acceptance_resumes_with_fetch_without_credential_or_redispatch()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture_with_acceptance(
        ProviderKind::Stripe,
        PaymentState::Succeeded,
        BillingCredentialUsePolicy::SingleCharge,
        AcceptanceBehavior::CommitThenOutcomeUnknown,
    )?;
    fixture
        .engine
        .queue_donation_intent(
            intent_request_with_cadence(ProviderKind::Stripe, DonationCadence::OneTime)?,
            digest(b'6'),
        )
        .await?;
    let job = charge_job(&fixture.scenario);
    let first = fixture
        .engine
        .execute_charge_job("billing-fixture", &job)
        .await;
    assert_eq!(
        first.err(),
        Some(PaymentRuntimeError::ReconciliationRequired)
    );
    assert!(fixture.owner.snapshot(|state| state.charge_accepted)?);
    assert_eq!(
        fixture.owner.snapshot(|state| state.acceptance_attempts)?,
        1
    );

    // SINGLE_CHARGE removed the credential before the ambiguous DB response.
    // A successful retry therefore proves the accepted successor used fetch-only recovery.
    let retry = fixture
        .engine
        .execute_charge_job("billing-fixture", &job)
        .await?;
    assert!(matches!(retry, ChargeExecution::Confirmed(_)));
    let (accepts, completions) = fixture.owner.snapshot(|state| {
        (
            state
                .calls
                .iter()
                .filter(|call| **call == "accept_charge")
                .count(),
            state
                .calls
                .iter()
                .filter(|call| **call == "complete_charge")
                .count(),
        )
    })?;
    assert_eq!(accepts, 1);
    assert_eq!(completions, 1);
    Ok(())
}

#[tokio::test]
async fn local_pre_dispatch_reject_terminalizes_job_without_payment_effects()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture_with_charge_provider_override(
        ProviderKind::TossPayments,
        PaymentState::Succeeded,
        ProviderKind::Stripe,
    )?;
    fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::TossPayments)?, digest(b'6'))
        .await?;
    let job = charge_job_with_authority(&fixture.scenario, ProviderKind::Stripe);
    let first = fixture
        .engine
        .execute_charge_job("billing-fixture", &job)
        .await?;
    assert!(matches!(first, ChargeExecution::Rejected(_)));
    let (running, authority, local_code, effects, reviews, contract, public_access) =
        fixture.owner.snapshot(|state| {
            (
                state.charge_job_running,
                state
                    .charge_receipt
                    .as_ref()
                    .and_then(|receipt| receipt.terminal_authority),
                state.local_failure_code,
                state.donation_fact_effects.clone(),
                state.review_tasks,
                state.contract_mutations,
                state.public_access_mutations,
            )
        })?;
    assert!(!running);
    assert_eq!(
        authority,
        Some(ChargeTerminalAuthority::LocalPreDispatchRejection)
    );
    assert_eq!(local_code, Some(LocalChargeFailureCode::InvalidRequest));
    assert!(effects.is_empty());
    assert_eq!(reviews, 0);
    assert_eq!(contract, 0);
    assert_eq!(public_access, 0);

    let replay = fixture
        .engine
        .execute_charge_job("billing-fixture", &job)
        .await?;
    assert!(matches!(replay, ChargeExecution::Replay(_)));
    assert_eq!(
        fixture.owner.snapshot(|state| state
            .calls
            .iter()
            .filter(|call| **call == "fail_charge")
            .count())?,
        1
    );
    Ok(())
}

#[tokio::test]
async fn failed_payment_creates_only_review_and_changes_no_access_or_contract()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture(ProviderKind::KakaoPay, PaymentState::Failed)?;
    fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::KakaoPay)?, digest(b'6'))
        .await?;
    fixture
        .engine
        .execute_charge_job("billing-fixture", &charge_job(&fixture.scenario))
        .await?;
    let (review_tasks, contract_mutations, public_access_mutations) =
        fixture.owner.snapshot(|state| {
            (
                state.review_tasks,
                state.contract_mutations,
                state.public_access_mutations,
            )
        })?;
    assert_eq!(review_tasks, 1);
    assert_eq!(contract_mutations, 0);
    assert_eq!(public_access_mutations, 0);
    Ok(())
}

#[tokio::test]
async fn canceled_provider_state_is_recorded_as_failed_review_only()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture(ProviderKind::TossPayments, PaymentState::Canceled)?;
    fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::TossPayments)?, digest(b'6'))
        .await?;
    fixture
        .engine
        .execute_charge_job("billing-fixture", &charge_job(&fixture.scenario))
        .await?;
    let (observed, effective, effects, review_tasks, public_access_mutations) =
        fixture.owner.snapshot(|state| {
            (
                state.terminal_state,
                state.charge_receipt.as_ref().map(|receipt| receipt.state),
                state.donation_fact_effects.clone(),
                state.review_tasks,
                state.public_access_mutations,
            )
        })?;
    assert_eq!(observed, Some(PaymentState::Canceled));
    assert_eq!(effective, Some(ChargeCompletionState::Failed));
    assert!(effects.is_empty());
    assert_eq!(review_tasks, 1);
    assert_eq!(public_access_mutations, 0);
    Ok(())
}
