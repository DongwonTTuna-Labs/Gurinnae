use super::*;

#[tokio::test]
async fn webhook_hint_never_overrides_fetch_and_duplicate_is_terminal_replay()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture(ProviderKind::Stripe, PaymentState::Succeeded)?;
    fixture
        .engine
        .queue_donation_intent(intent_request(ProviderKind::Stripe)?, digest(b'6'))
        .await?;
    fixture
        .engine
        .execute_charge_job("billing-fixture", &charge_job(&fixture.scenario))
        .await?;
    let webhook = fixture.factory.webhook_for_payment(
        ProviderKind::Stripe,
        ProviderEventIdentity::try_new("fixture-event-dynamic".to_owned())?,
        &PaymentLocator::MerchantOrderId(fixture.scenario.merchant_order_id.clone()),
        fixture.scenario.observed_at_unix,
    )?;
    let envelope = webhook.envelope();
    let first = fixture
        .engine
        .process_webhook(
            ProviderKind::Stripe,
            envelope.headers,
            envelope.body,
            envelope.replay_policy.now_unix,
        )
        .await?;
    assert_eq!(first.disposition, WebhookDisposition::Applied);
    assert_eq!(
        fixture.owner.snapshot(|state| state.terminal_state)?,
        Some(PaymentState::Succeeded)
    );
    let duplicate = fixture
        .engine
        .process_webhook(
            ProviderKind::Stripe,
            envelope.headers,
            envelope.body,
            envelope.replay_policy.now_unix,
        )
        .await?;
    assert_eq!(duplicate.disposition, WebhookDisposition::Duplicate);
    assert_eq!(
        fixture.owner.snapshot(|state| state
            .calls
            .iter()
            .filter(|call| **call == "complete_webhook")
            .count())?,
        1
    );
    Ok(())
}

#[tokio::test]
async fn authenticated_hint_from_succeeded_ledger_still_persists_failed_fetch_truth()
-> Result<(), PaymentRuntimeError> {
    let fixture = runtime_fixture(ProviderKind::Stripe, PaymentState::Failed)?;
    seed_fixture_payment(&fixture.factory, &fixture.scenario).await?;

    let succeeded_factory = DeterministicFixtureProviderFactory::new(
        TestFixtureAuthority::try_new("TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY")?,
        FixturePaymentOutcome::Succeeded,
        fixture.scenario.observed_at_unix,
    )?;
    seed_fixture_payment(&succeeded_factory, &fixture.scenario).await?;
    let webhook = succeeded_factory.webhook_for_payment(
        ProviderKind::Stripe,
        ProviderEventIdentity::try_new("fixture-event-cross-ledger".to_owned())?,
        &PaymentLocator::MerchantOrderId(fixture.scenario.merchant_order_id.clone()),
        fixture.scenario.observed_at_unix,
    )?;
    let envelope = webhook.envelope();

    let receipt = fixture
        .engine
        .process_webhook(
            ProviderKind::Stripe,
            envelope.headers,
            envelope.body,
            envelope.replay_policy.now_unix,
        )
        .await?;
    assert_eq!(receipt.disposition, WebhookDisposition::Applied);
    let (terminal, effects, review_tasks) = fixture.owner.snapshot(|state| {
        (
            state.terminal_state,
            state.donation_fact_effects.clone(),
            state.review_tasks,
        )
    })?;
    assert_eq!(terminal, Some(PaymentState::Failed));
    assert!(effects.is_empty());
    assert_eq!(review_tasks, 1);
    Ok(())
}

#[tokio::test]
async fn changed_body_for_same_event_conflicts_before_any_payment_effect()
-> Result<(), PaymentRuntimeError> {
    for provider in [ProviderKind::TossPayments, ProviderKind::KakaoPay] {
        let fixture = runtime_fixture(provider, PaymentState::Succeeded)?;
        seed_fixture_payment(&fixture.factory, &fixture.scenario).await?;
        let event_identity = "fixture-event-conflicting-body";
        let first = fixture.factory.webhook_for_payment(
            provider,
            ProviderEventIdentity::try_new(event_identity.to_owned())?,
            &PaymentLocator::MerchantOrderId(fixture.scenario.merchant_order_id.clone()),
            fixture.scenario.observed_at_unix,
        )?;
        let first_envelope = first.envelope();
        fixture
            .engine
            .process_webhook(
                provider,
                first_envelope.headers,
                first_envelope.body,
                first_envelope.replay_policy.now_unix,
            )
            .await?;

        let other = scenario(
            provider,
            0x7_100,
            PaymentState::Succeeded,
            BillingCredentialUsePolicy::Recurring,
        )?;
        seed_fixture_payment(&fixture.factory, &other).await?;
        let conflicting = fixture.factory.webhook_for_payment(
            provider,
            ProviderEventIdentity::try_new(event_identity.to_owned())?,
            &PaymentLocator::MerchantOrderId(other.merchant_order_id.clone()),
            other.observed_at_unix,
        )?;
        assert_ne!(first.body_sha256(), conflicting.body_sha256());
        let before = fixture.owner.snapshot(payment_effect_snapshot)?;
        let conflicting_envelope = conflicting.envelope();
        let result = fixture
            .engine
            .process_webhook(
                provider,
                conflicting_envelope.headers,
                conflicting_envelope.body,
                conflicting_envelope.replay_policy.now_unix,
            )
            .await;
        assert_eq!(result, Err(PaymentRuntimeError::Conflict));
        assert_eq!(fixture.owner.snapshot(payment_effect_snapshot)?, before);
        assert_eq!(
            fixture.owner.snapshot(|state| state
                .calls
                .iter()
                .filter(|call| **call == "complete_webhook")
                .count())?,
            1
        );
    }
    Ok(())
}

#[tokio::test]
async fn partial_refund_requires_reconciliation_without_any_effect_mutation()
-> Result<(), PaymentRuntimeError> {
    let fixture = charged_fixture(ProviderKind::Stripe).await?;
    refund_fixture_payment(&fixture, 500).await?;
    let first = process_fixture_webhook(&fixture, "fixture-event-partial-refund").await?;
    assert_eq!(first.disposition, WebhookDisposition::Applied);
    let (
        effects,
        reasons,
        partial_refunds,
        review_tasks,
        contract_mutations,
        public_access_mutations,
    ) = fixture.owner.snapshot(|state| {
        (
            state.donation_fact_effects.clone(),
            state.reconciliation_reasons.clone(),
            state.partial_refund_reconciliations,
            state.review_tasks,
            state.contract_mutations,
            state.public_access_mutations,
        )
    })?;
    assert_eq!(effects, vec![DonationFactEffect::Original]);
    assert!(reasons.is_empty());
    assert_eq!(partial_refunds, 1);
    assert_eq!(review_tasks, 0);
    assert_eq!(contract_mutations, 0);
    assert_eq!(public_access_mutations, 0);
    let before_replay = fixture.owner.snapshot(payment_effect_snapshot)?;
    let replay = process_fixture_webhook(&fixture, "fixture-event-partial-refund").await?;
    assert_eq!(replay.disposition, WebhookDisposition::Duplicate);
    assert_eq!(
        fixture.owner.snapshot(payment_effect_snapshot)?,
        before_replay
    );
    assert_eq!(
        fixture.owner.snapshot(|state| state
            .calls
            .iter()
            .filter(|call| **call == "complete_webhook")
            .count())?,
        1
    );
    Ok(())
}

#[tokio::test]
async fn full_refund_appends_a_reversal_and_changes_no_access_or_contract()
-> Result<(), PaymentRuntimeError> {
    let fixture = charged_fixture(ProviderKind::Stripe).await?;
    refund_fixture_payment(&fixture, 1_000).await?;
    process_fixture_webhook(&fixture, "fixture-event-full-refund").await?;
    let (terminal, effects, reasons, contract_mutations, public_access_mutations) =
        fixture.owner.snapshot(|state| {
            (
                state.terminal_state,
                state.donation_fact_effects.clone(),
                state.reconciliation_reasons.clone(),
                state.contract_mutations,
                state.public_access_mutations,
            )
        })?;
    assert_eq!(terminal, Some(PaymentState::Refunded));
    assert_eq!(
        effects,
        vec![DonationFactEffect::Original, DonationFactEffect::Reversal]
    );
    assert!(reasons.is_empty());
    assert_eq!(contract_mutations, 0);
    assert_eq!(public_access_mutations, 0);
    Ok(())
}

async fn charged_fixture(provider: ProviderKind) -> Result<RuntimeFixture, PaymentRuntimeError> {
    let fixture = runtime_fixture(provider, PaymentState::Succeeded)?;
    fixture
        .engine
        .queue_donation_intent(intent_request(provider)?, digest(b'6'))
        .await?;
    fixture
        .engine
        .execute_charge_job("billing-fixture", &charge_job(&fixture.scenario))
        .await?;
    Ok(fixture)
}

async fn refund_fixture_payment(
    fixture: &RuntimeFixture,
    refund_amount: i64,
) -> Result<(), PaymentRuntimeError> {
    let provider = fixture.factory.provider(fixture.scenario.provider)?;
    let fetched = provider
        .fetch_payment(&FetchPaymentRequest {
            provider: fixture.scenario.provider,
            locator: PaymentLocator::MerchantOrderId(fixture.scenario.merchant_order_id.clone()),
            expected_attempt_id: fixture.scenario.attempt_id,
            expected_merchant_order_id: fixture.scenario.merchant_order_id.clone(),
            expected_amount: fixture.scenario.amount,
        })
        .await?;
    provider
        .refund(&RefundRequest {
            attempt_id: fixture.scenario.attempt_id,
            idempotency_key: fixture.scenario.refund_idempotency_key,
            payment_id: fetched.provider_payment_id,
            amount: KrwAmount::try_new(refund_amount)?,
        })
        .await?;
    Ok(())
}

async fn seed_fixture_payment(
    factory: &DeterministicFixtureProviderFactory,
    scenario: &ProviderFixtureScenario,
) -> Result<(), PaymentRuntimeError> {
    let provider = factory.provider(scenario.provider)?;
    let authorization = factory.issue_authorization(
        scenario.provider,
        scenario.binding_id,
        scenario.issue_idempotency_key,
    )?;
    let issued = provider
        .issue_billing_key(&IssueBillingKeyRequest {
            binding_id: scenario.binding_id,
            idempotency_key: scenario.issue_idempotency_key,
            use_policy: scenario.use_policy,
            authorization,
        })
        .await?;
    provider
        .charge(ChargeRequest {
            attempt_id: scenario.attempt_id,
            idempotency_key: scenario.charge_idempotency_key,
            merchant_order_id: &scenario.merchant_order_id,
            amount: scenario.amount,
            instrument: ChargeInstrument::Stored(&issued.material),
        })
        .await?;
    Ok(())
}

fn payment_effect_snapshot(
    state: &owner::OwnerState,
) -> (
    Option<PaymentState>,
    Vec<DonationFactEffect>,
    Vec<ReconciliationReason>,
    u32,
    u32,
    u32,
    u32,
) {
    (
        state.terminal_state,
        state.donation_fact_effects.clone(),
        state.reconciliation_reasons.clone(),
        state.partial_refund_reconciliations,
        state.review_tasks,
        state.contract_mutations,
        state.public_access_mutations,
    )
}

async fn process_fixture_webhook(
    fixture: &RuntimeFixture,
    event_identity: &str,
) -> Result<WebhookProcessingReceipt, PaymentRuntimeError> {
    let webhook = fixture.factory.webhook_for_payment(
        fixture.scenario.provider,
        ProviderEventIdentity::try_new(event_identity.to_owned())?,
        &PaymentLocator::MerchantOrderId(fixture.scenario.merchant_order_id.clone()),
        fixture.scenario.observed_at_unix,
    )?;
    let envelope = webhook.envelope();
    fixture
        .engine
        .process_webhook(
            fixture.scenario.provider,
            envelope.headers,
            envelope.body,
            envelope.replay_policy.now_unix,
        )
        .await
}
