use super::{
    owner::{CompletionBehavior, InMemoryOwner},
    *,
};

pub(super) struct RuntimeFixture {
    pub(super) engine: PaymentEngine<InMemoryOwner>,
    pub(super) owner: InMemoryOwner,
    pub(super) factory: DeterministicFixtureProviderFactory,
    pub(super) scenario: ProviderFixtureScenario,
    pub(super) vault: Arc<InMemoryTestFixtureBillingKeyVault>,
}

pub(super) fn runtime_fixture(
    provider: ProviderKind,
    state: PaymentState,
) -> Result<RuntimeFixture, PaymentRuntimeError> {
    runtime_fixture_with_policy(provider, state, BillingCredentialUsePolicy::Recurring)
}

pub(super) fn runtime_fixture_with_policy(
    provider: ProviderKind,
    state: PaymentState,
    use_policy: BillingCredentialUsePolicy,
) -> Result<RuntimeFixture, PaymentRuntimeError> {
    runtime_fixture_with_completion(provider, state, use_policy, CompletionBehavior::Applied)
}

pub(super) fn runtime_fixture_with_completion(
    provider: ProviderKind,
    state: PaymentState,
    use_policy: BillingCredentialUsePolicy,
    completion_behavior: CompletionBehavior,
) -> Result<RuntimeFixture, PaymentRuntimeError> {
    runtime_fixture_configured(
        provider,
        state,
        use_policy,
        completion_behavior,
        AcceptanceBehavior::Applied,
        None,
    )
}

pub(super) fn runtime_fixture_with_acceptance(
    provider: ProviderKind,
    state: PaymentState,
    use_policy: BillingCredentialUsePolicy,
    acceptance_behavior: AcceptanceBehavior,
) -> Result<RuntimeFixture, PaymentRuntimeError> {
    runtime_fixture_configured(
        provider,
        state,
        use_policy,
        CompletionBehavior::Applied,
        acceptance_behavior,
        None,
    )
}

pub(super) fn runtime_fixture_with_charge_provider_override(
    provider: ProviderKind,
    state: PaymentState,
    charge_provider_override: ProviderKind,
) -> Result<RuntimeFixture, PaymentRuntimeError> {
    runtime_fixture_configured(
        provider,
        state,
        BillingCredentialUsePolicy::Recurring,
        CompletionBehavior::Applied,
        AcceptanceBehavior::Applied,
        Some(charge_provider_override),
    )
}

fn runtime_fixture_configured(
    provider: ProviderKind,
    state: PaymentState,
    use_policy: BillingCredentialUsePolicy,
    completion_behavior: CompletionBehavior,
    acceptance_behavior: AcceptanceBehavior,
    charge_provider_override: Option<ProviderKind>,
) -> Result<RuntimeFixture, PaymentRuntimeError> {
    let authority = TestFixtureAuthority::try_new("TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY")?;
    let selected_scenario = scenario(provider, 0x7000, state, use_policy)?;
    let factory = DeterministicFixtureProviderFactory::new(
        authority,
        fixture_outcome(state)?,
        selected_scenario.observed_at_unix,
    )?;
    let providers = ProviderSet::test_fixture(factory.clone())?;
    let expected_provider_payment_id_sha256 = factory
        .expected_provider_payment_id_digest(
            selected_scenario.provider,
            selected_scenario.charge_idempotency_key,
            &selected_scenario.merchant_order_id,
            selected_scenario.amount,
        )?
        .as_str()
        .parse()
        .map_err(|_| PaymentRuntimeError::InvalidRequest)?;
    let mut owner = InMemoryOwner::with_completion_behavior(
        selected_scenario.clone(),
        completion_behavior,
        expected_provider_payment_id_sha256,
    )
    .with_acceptance_behavior(acceptance_behavior);
    if let Some(override_provider) = charge_provider_override {
        owner = owner.with_charge_provider_override(override_provider);
    }
    let vault = Arc::new(InMemoryTestFixtureBillingKeyVault::new(
        authority,
        vec![9_u8; 32],
        KeyVersion::try_new("fixture-v1".to_owned())?,
    )?);
    let engine = PaymentEngine::test_only(
        owner.clone(),
        providers,
        vault.clone(),
        Sha256Digest::of(b"fixture-secret"),
        Sha256Digest::of(b"fixture-outcome-config"),
    );
    Ok(RuntimeFixture {
        engine,
        owner,
        factory,
        scenario: selected_scenario,
        vault,
    })
}

fn fixture_outcome(state: PaymentState) -> Result<FixturePaymentOutcome, PaymentRuntimeError> {
    match state {
        PaymentState::Pending => Ok(FixturePaymentOutcome::Pending),
        PaymentState::Succeeded => Ok(FixturePaymentOutcome::Succeeded),
        PaymentState::Failed => Ok(FixturePaymentOutcome::Failed),
        PaymentState::Canceled => Ok(FixturePaymentOutcome::Canceled),
        PaymentState::PartiallyRefunded | PaymentState::Refunded => {
            Err(PaymentRuntimeError::InvalidRequest)
        }
    }
}

pub(super) fn scenario(
    provider: ProviderKind,
    seed: u128,
    state: PaymentState,
    use_policy: BillingCredentialUsePolicy,
) -> Result<ProviderFixtureScenario, PaymentRuntimeError> {
    Ok(ProviderFixtureScenario {
        provider,
        use_policy,
        binding_id: Uuid::from_u128(seed + 1),
        attempt_id: AttemptId::new(Uuid::from_u128(seed + 2)),
        issue_idempotency_key: IdempotencyKey::new(Uuid::from_u128(seed + 3)),
        charge_idempotency_key: IdempotencyKey::new(Uuid::from_u128(seed + 4)),
        refund_idempotency_key: IdempotencyKey::new(Uuid::from_u128(seed + 5)),
        merchant_order_id: MerchantOrderId::try_new(format!("fixture-order-{seed}"))?,
        amount: KrwAmount::try_new(1_000)?,
        terminal_state: state,
        event_identity: ProviderEventIdentity::try_new(format!("fixture-event-{seed}"))?,
        provider_payment_id: ProviderPaymentId::try_new(format!("fixture-payment-{seed}"))?,
        observed_at_unix: 1_800_000_000,
    })
}

pub(super) fn intent_request(
    provider: ProviderKind,
) -> Result<DonationIntentRequest, PaymentRuntimeError> {
    intent_request_with_cadence(provider, DonationCadence::Recurring)
}

pub(super) fn intent_request_with_cadence(
    provider: ProviderKind,
    cadence: DonationCadence,
) -> Result<DonationIntentRequest, PaymentRuntimeError> {
    let offer = FixtureDonationOffer::test_fixture();
    let tier = offer
        .tiers
        .first()
        .ok_or(PaymentRuntimeError::InvalidRequest)?;
    let mut request = serde_json::from_value::<DonationIntentRequest>(json!({
        "schemaVersion":"donation-intent-request.v1",
        "requestId":"00000000-0000-4000-8000-000000006001",
        "offerVersionId":offer.offer_version_id,
        "offerDigest":offer.offer_digest,
        "tierId":tier.tier_id,
        "cadence":cadence,
        "provider":provider,
        "consentReceiptDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "paymentAuthorizationToken":"fixture-secret"
    }))
    .map_err(|_| PaymentRuntimeError::InvalidRequest)?;
    request.consent_receipt_digest = consent_receipt_digest(&request);
    Ok(request)
}

pub(super) fn charge_job(scenario: &ProviderFixtureScenario) -> ClaimedDonationChargeJob {
    charge_job_with_authority(scenario, scenario.provider)
}

pub(super) fn charge_job_with_authority(
    scenario: &ProviderFixtureScenario,
    provider: ProviderKind,
) -> ClaimedDonationChargeJob {
    let binding_digest = digest(b'b');
    let logical_charge_id = Uuid::from_u128(0x6405);
    let scheduled_for = "2027-01-01T00:00:00Z";
    let idempotency_digest =
        charge_job_idempotency_digest(logical_charge_id, &binding_digest, scheduled_for);
    let job = ClaimedJob {
        id: Uuid::from_u128(0x6401),
        job_type: "DONATION_CHARGE".to_owned(),
        queue: "billing-gateway".to_owned(),
        payload: json!({
            "schemaVersion":"donation-charge-job.v1",
            "donationScheduleId":"00000000-0000-4000-8000-000000006401",
            "donationScheduleVersion":1,
            "donationScheduleDigest":digest(b'a'),
            "paymentMethodBindingId":"00000000-0000-4000-8000-000000006402",
            "paymentMethodBindingDigest":binding_digest,
            "offerVersionId":"00000000-0000-4000-8000-000000006403",
            "offerDigest":digest(b'c'),
            "tierId":"00000000-0000-4000-8000-000000006404",
            "consentReceiptDigest":digest(b'd'),
            "logicalChargeId":logical_charge_id,
            "chargeIdempotencyKeySha256":idempotency_digest,
            "scheduledFor":scheduled_for
        }),
        attempt: 1,
        max_attempts: 8,
        fence: Fence {
            lease_token: Uuid::from_u128(0x6406),
            fencing_token: 1,
        },
        lease_expires_at: OffsetDateTime::UNIX_EPOCH,
    };
    ClaimedDonationChargeJob {
        job,
        provider,
        amount: scenario.amount,
    }
}

pub(super) fn digest(byte: u8) -> Sha256Digest {
    let bytes = [byte; 32];
    Sha256Digest::of(&bytes)
}
