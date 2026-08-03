use super::*;

#[tokio::test]
async fn one_time_consent_is_isolated_and_credential_is_consumed_before_charge()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture_with_policy(
        ProviderKind::TossPayments,
        PaymentState::Succeeded,
        BillingCredentialUsePolicy::SingleCharge,
    )?;
    let one_time =
        intent_request_with_cadence(ProviderKind::TossPayments, DonationCadence::OneTime)?;
    let recurring =
        intent_request_with_cadence(ProviderKind::TossPayments, DonationCadence::Recurring)?;
    assert_ne!(
        one_time.consent_receipt_digest,
        recurring.consent_receipt_digest
    );
    fixture
        .engine
        .queue_donation_intent(one_time, digest(b'6'))
        .await?;
    let handle = fixture
        .owner
        .snapshot(|state| state.handle.clone())?
        .ok_or(PaymentRuntimeError::OwnerFunction)?;
    assert_eq!(handle.use_policy, BillingCredentialUsePolicy::SingleCharge);
    fixture
        .engine
        .execute_charge_job("billing-fixture", &charge_job(&fixture.scenario))
        .await?;
    assert!(fixture.vault.take_for_charge(&handle).is_err());
    Ok(())
}

#[tokio::test]
async fn vault_uses_root_binding_identity_while_charge_fence_uses_active_binding()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture(ProviderKind::Stripe, PaymentState::Succeeded)?;
    fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::Stripe)?, digest(b'6'))
        .await?;
    let handle = fixture
        .owner
        .snapshot(|state| state.handle.clone())?
        .ok_or(PaymentRuntimeError::OwnerFunction)?;
    let job = charge_job(&fixture.scenario);
    let active_binding_id = job
        .job
        .payload
        .get("paymentMethodBindingId")
        .and_then(serde_json::Value::as_str)
        .ok_or(PaymentRuntimeError::InvalidRequest)?;
    let active_binding_id =
        Uuid::parse_str(active_binding_id).map_err(|_| PaymentRuntimeError::InvalidRequest)?;
    assert_eq!(handle.binding_id, fixture.scenario.binding_id);
    assert_ne!(handle.binding_id, active_binding_id);
    assert_eq!(
        handle.secret_reference,
        format!("fixture://billing-key/{}@v2", fixture.scenario.binding_id)
    );
    assert!(matches!(
        fixture
            .engine
            .execute_charge_job("billing-fixture", &job)
            .await?,
        ChargeExecution::Confirmed(_)
    ));
    Ok(())
}

#[tokio::test]
async fn ambiguous_binding_completion_retains_credential_and_retry_replays_receipt()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture_with_completion(
        ProviderKind::TossPayments,
        PaymentState::Succeeded,
        BillingCredentialUsePolicy::Recurring,
        CompletionBehavior::CommitThenOutcomeUnknown,
    )?;
    let first = fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::TossPayments)?, digest(b'6'))
        .await;
    assert_eq!(first, Err(PaymentRuntimeError::ReconciliationRequired));
    let handle = fixture
        .owner
        .snapshot(|state| state.handle.clone())?
        .ok_or(PaymentRuntimeError::OwnerFunction)?;
    assert!(fixture.vault.take_for_charge(&handle).is_ok());

    let replay = fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::TossPayments)?, digest(b'6'))
        .await?;
    assert_eq!(replay.status, "QUEUED");
    assert_eq!(
        fixture.owner.snapshot(|state| state.calls.clone())?,
        vec!["claim_intent", "complete_binding", "claim_intent"]
    );
    Ok(())
}

#[tokio::test]
async fn ambiguous_uncommitted_completion_retains_credential_and_retries_same_identity()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture_with_completion(
        ProviderKind::KakaoPay,
        PaymentState::Succeeded,
        BillingCredentialUsePolicy::Recurring,
        CompletionBehavior::OutcomeUnknownNoCommit,
    )?;
    let first = fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::KakaoPay)?, digest(b'6'))
        .await;
    assert_eq!(first, Err(PaymentRuntimeError::ReconciliationRequired));
    let handle = fixture
        .owner
        .snapshot(|state| state.handle.clone())?
        .ok_or(PaymentRuntimeError::OwnerFunction)?;
    assert!(fixture.vault.take_for_charge(&handle).is_ok());

    let receipt = fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::KakaoPay)?, digest(b'6'))
        .await?;
    assert_eq!(receipt.status, "QUEUED");
    assert_eq!(
        fixture.owner.snapshot(|state| state.calls.clone())?,
        vec![
            "claim_intent",
            "complete_binding",
            "claim_intent",
            "complete_binding"
        ]
    );
    Ok(())
}

#[tokio::test]
async fn authoritative_unreferenced_rejection_is_the_only_vault_destroy_path()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture_with_completion(
        ProviderKind::Stripe,
        PaymentState::Succeeded,
        BillingCredentialUsePolicy::Recurring,
        CompletionBehavior::RejectUnreferenced,
    )?;
    let result = fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::Stripe)?, digest(b'6'))
        .await;
    assert_eq!(result, Err(PaymentRuntimeError::InvalidRequest));
    let handle = fixture
        .owner
        .snapshot(|state| state.handle.clone())?
        .ok_or(PaymentRuntimeError::OwnerFunction)?;
    assert!(fixture.vault.take_for_charge(&handle).is_err());
    assert_eq!(
        fixture.owner.snapshot(|state| state.calls.clone())?,
        vec!["claim_intent", "complete_binding", "fail_intent"]
    );
    Ok(())
}

#[tokio::test]
async fn malformed_committed_receipt_retains_credential_and_never_reissues()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture_with_completion(
        ProviderKind::Stripe,
        PaymentState::Succeeded,
        BillingCredentialUsePolicy::Recurring,
        CompletionBehavior::CommitMalformedReceipt,
    )?;
    let first = fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::Stripe)?, digest(b'6'))
        .await;
    assert_eq!(first, Err(PaymentRuntimeError::OwnerFunction));
    let handle = fixture
        .owner
        .snapshot(|state| state.handle.clone())?
        .ok_or(PaymentRuntimeError::OwnerFunction)?;
    assert!(fixture.vault.take_for_charge(&handle).is_ok());

    let replay = fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::Stripe)?, digest(b'6'))
        .await;
    assert_eq!(replay, Err(PaymentRuntimeError::OwnerFunction));
    assert_eq!(
        fixture.owner.snapshot(|state| state.calls.clone())?,
        vec!["claim_intent", "complete_binding", "claim_intent"]
    );
    Ok(())
}
