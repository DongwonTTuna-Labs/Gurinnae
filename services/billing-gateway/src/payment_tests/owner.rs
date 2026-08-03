use super::*;

#[derive(Clone)]
pub(super) struct InMemoryOwner {
    state: Arc<Mutex<OwnerState>>,
    scenario: ProviderFixtureScenario,
    completion_behavior: CompletionBehavior,
    acceptance_behavior: AcceptanceBehavior,
    charge_provider_override: Option<ProviderKind>,
    expected_provider_payment_id_sha256: Sha256Digest,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) enum CompletionBehavior {
    #[default]
    Applied,
    OutcomeUnknownNoCommit,
    CommitThenOutcomeUnknown,
    CommitMalformedReceipt,
    RejectUnreferenced,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(super) enum AcceptanceBehavior {
    #[default]
    Applied,
    CommitThenOutcomeUnknown,
}

#[derive(Default)]
pub(super) struct OwnerState {
    pub(super) calls: Vec<&'static str>,
    pub(super) intent_binding: Option<DonationIntentBinding>,
    pub(super) intent_receipt: Option<DonationQueuedReceipt>,
    pub(super) intent_failed: bool,
    pub(super) completion_attempts: u32,
    pub(super) handle: Option<BillingKeyHandle>,
    pub(super) charge_receipt: Option<ChargeTerminalReceipt>,
    pub(super) webhook_binding: Option<WebhookClaimBinding>,
    pub(super) webhook_receipt: Option<WebhookProcessingReceipt>,
    pub(super) terminal_state: Option<PaymentState>,
    pub(super) donation_fact_effects: Vec<DonationFactEffect>,
    pub(super) reconciliation_reasons: Vec<ReconciliationReason>,
    pub(super) partial_refund_reconciliations: u32,
    pub(super) review_tasks: u32,
    pub(super) contract_mutations: u32,
    pub(super) public_access_mutations: u32,
    pub(super) charge_job_running: bool,
    pub(super) charge_accepted: bool,
    pub(super) acceptance_attempts: u32,
    pub(super) local_failure_code: Option<LocalChargeFailureCode>,
}

impl InMemoryOwner {
    pub(super) fn with_completion_behavior(
        scenario: ProviderFixtureScenario,
        completion_behavior: CompletionBehavior,
        expected_provider_payment_id_sha256: Sha256Digest,
    ) -> Self {
        Self {
            state: Arc::new(Mutex::new(OwnerState::default())),
            scenario,
            completion_behavior,
            acceptance_behavior: AcceptanceBehavior::Applied,
            charge_provider_override: None,
            expected_provider_payment_id_sha256,
        }
    }

    pub(super) fn with_acceptance_behavior(
        mut self,
        acceptance_behavior: AcceptanceBehavior,
    ) -> Self {
        self.acceptance_behavior = acceptance_behavior;
        self
    }

    pub(super) fn with_charge_provider_override(mut self, provider: ProviderKind) -> Self {
        self.charge_provider_override = Some(provider);
        self
    }

    pub(super) fn snapshot<R>(
        &self,
        read: impl FnOnce(&OwnerState) -> R,
    ) -> Result<R, PaymentRuntimeError> {
        self.state
            .lock()
            .map(|state| read(&state))
            .map_err(|_| PaymentRuntimeError::OwnerFunction)
    }

    fn update<R>(
        &self,
        write: impl FnOnce(&mut OwnerState) -> R,
    ) -> Result<R, PaymentRuntimeError> {
        self.state
            .lock()
            .map(|mut state| write(&mut state))
            .map_err(|_| PaymentRuntimeError::OwnerFunction)
    }
}

impl PaymentOwnerFunctions for InMemoryOwner {
    fn claim_donation_intent<'a>(
        &'a self,
        binding: &'a DonationIntentBinding,
        expected_amount: KrwAmount,
    ) -> PaymentOwnerFuture<'a, DonationIntentClaimDisposition> {
        Box::pin(async move {
            self.update(|state| {
                state.calls.push("claim_intent");
                if state.intent_failed {
                    return DonationIntentClaimDisposition::Conflict;
                }
                if let Some(receipt) = state.intent_receipt.clone() {
                    if state.intent_binding.as_ref() == Some(binding) {
                        return DonationIntentClaimDisposition::Replay(receipt);
                    }
                    return DonationIntentClaimDisposition::Conflict;
                }
                state.intent_binding = Some(binding.clone());
                DonationIntentClaimDisposition::Execute(DonationIntentClaim {
                    donation_intent_id: Uuid::from_u128(0x6001),
                    binding_id: self.scenario.binding_id,
                    job_id: Uuid::from_u128(0x6002),
                    provider_idempotency_key: self.scenario.issue_idempotency_key,
                    amount: expected_amount,
                    claim_digest: digest(b'a'),
                })
            })
        })
    }

    fn complete_payment_method_binding<'a>(
        &'a self,
        completion: PaymentMethodBindingCompletion<'a>,
    ) -> PaymentOwnerFuture<'a, PaymentMethodBindingCompletionDisposition> {
        Box::pin(async move {
            self.update(
                |state| -> Result<PaymentMethodBindingCompletionDisposition, PaymentRuntimeError> {
                    state.calls.push("complete_binding");
                    state.handle = Some(completion.handle.clone());
                    state.completion_attempts += 1;
                    if self.completion_behavior == CompletionBehavior::OutcomeUnknownNoCommit
                        && state.completion_attempts == 1
                    {
                        return Err(PaymentRuntimeError::ReconciliationRequired);
                    }
                    if self.completion_behavior == CompletionBehavior::RejectUnreferenced {
                        return Ok(PaymentMethodBindingCompletionDisposition::RejectedUnreferenced);
                    }
                    let mut receipt = DonationQueuedReceipt {
                        schema_version: "donation-intent-queued.v1",
                        request_id: completion.intent.request_id,
                        job_id: completion.claim.job_id,
                        status: "QUEUED",
                        receipt_digest: digest(b'b'),
                    };
                    state.intent_receipt = Some(receipt.clone());
                    match self.completion_behavior {
                        CompletionBehavior::Applied
                        | CompletionBehavior::OutcomeUnknownNoCommit => Ok(
                            PaymentMethodBindingCompletionDisposition::Committed(receipt),
                        ),
                        CompletionBehavior::CommitThenOutcomeUnknown => {
                            Err(PaymentRuntimeError::ReconciliationRequired)
                        }
                        CompletionBehavior::CommitMalformedReceipt => {
                            receipt.status = "INVALID";
                            state.intent_receipt = Some(receipt.clone());
                            Ok(PaymentMethodBindingCompletionDisposition::Committed(
                                receipt,
                            ))
                        }
                        CompletionBehavior::RejectUnreferenced => {
                            Ok(PaymentMethodBindingCompletionDisposition::RejectedUnreferenced)
                        }
                    }
                },
            )?
        })
    }

    fn fail_donation_intent<'a>(
        &'a self,
        _intent: &'a DonationIntentBinding,
        _claim: &'a DonationIntentClaim,
        _safe_code: &'static str,
    ) -> PaymentOwnerFuture<'a, ()> {
        Box::pin(async move {
            self.update(|state| {
                state.calls.push("fail_intent");
                state.intent_failed = true;
            })
        })
    }

    fn claim_charge<'a>(
        &'a self,
        binding: DonationChargeClaimBinding<'a>,
    ) -> PaymentOwnerFuture<'a, ChargeClaimDisposition> {
        Box::pin(async move {
            self.update(|state| {
                state.calls.push("claim_charge");
                if let Some(receipt) = state.charge_receipt.clone() {
                    return ChargeClaimDisposition::Replay(receipt);
                }
                let Some(handle) = state.handle.clone() else {
                    return ChargeClaimDisposition::InProgress;
                };
                let provider = self
                    .charge_provider_override
                    .unwrap_or(self.scenario.provider);
                if binding.provider != provider || binding.amount != self.scenario.amount {
                    return ChargeClaimDisposition::Conflict;
                }
                state.charge_job_running = true;
                let claim = ChargeClaim {
                    logical_charge_id: Uuid::from_u128(0x6405),
                    attempt_id: self.scenario.attempt_id.get(),
                    provider,
                    provider_idempotency_key: self.scenario.charge_idempotency_key,
                    merchant_order_id: self.scenario.merchant_order_id.clone(),
                    amount: self.scenario.amount,
                    credential_use_policy: self.scenario.use_policy,
                    billing_key_handle: handle,
                    expected_provider_payment_id_sha256: self
                        .expected_provider_payment_id_sha256
                        .clone(),
                    claim_digest: digest(b'c'),
                };
                if state.charge_accepted {
                    ChargeClaimDisposition::ResumeAccepted(claim)
                } else {
                    ChargeClaimDisposition::Execute(claim)
                }
            })
        })
    }

    fn accept_charge<'a>(
        &'a self,
        _claim: &'a ChargeClaim,
        _acceptance: &'a ChargeAcceptance,
    ) -> PaymentOwnerFuture<'a, ()> {
        Box::pin(async move {
            self.update(|state| {
                state.calls.push("accept_charge");
                state.charge_accepted = true;
                state.acceptance_attempts += 1;
                if self.acceptance_behavior == AcceptanceBehavior::CommitThenOutcomeUnknown
                    && state.acceptance_attempts == 1
                {
                    Err(PaymentRuntimeError::ReconciliationRequired)
                } else {
                    Ok(())
                }
            })?
        })
    }

    fn complete_charge<'a>(
        &'a self,
        claim: &'a ChargeClaim,
        observation: &'a AuthoritativePaymentObservation,
    ) -> PaymentOwnerFuture<'a, ChargeTerminalReceipt> {
        Box::pin(async move {
            self.update(
                |state| -> Result<ChargeTerminalReceipt, PaymentRuntimeError> {
                    state.calls.push("complete_charge");
                    state.charge_job_running = false;
                    state.terminal_state = Some(observation.state);
                    let donation_fact_event = donation_event(state, claim, observation);
                    let review_task_event = review_event(state, claim, observation);
                    let (completion_state, terminal_authority) =
                        completion_state(state, observation.state)?;
                    let receipt = ChargeTerminalReceipt {
                        attempt_id: claim.attempt_id,
                        state: completion_state,
                        terminal_authority,
                        receipt_digest: digest(b'3'),
                        fixture_authority: Some(observation.fixture_authority),
                        test_payment_outcome_config_digest: Some(
                            observation.test_payment_outcome_config_digest.clone(),
                        ),
                        effects: PaymentEffectBoundary::None,
                        donation_fact_event,
                        review_task_event,
                    };
                    state.charge_receipt = Some(receipt.clone());
                    Ok(receipt)
                },
            )?
        })
    }

    fn fail_charge<'a>(
        &'a self,
        claim: &'a ChargeClaim,
        safe_code: LocalChargeFailureCode,
        _evidence_digest: &'a Sha256Digest,
    ) -> PaymentOwnerFuture<'a, ChargeTerminalReceipt> {
        Box::pin(async move {
            self.update(|state| {
                state.calls.push("fail_charge");
                state.charge_job_running = false;
                state.terminal_state = Some(PaymentState::Failed);
                state.local_failure_code = Some(safe_code);
                let receipt = ChargeTerminalReceipt {
                    attempt_id: claim.attempt_id,
                    state: ChargeCompletionState::Failed,
                    terminal_authority: Some(ChargeTerminalAuthority::LocalPreDispatchRejection),
                    receipt_digest: digest(b'7'),
                    fixture_authority: None,
                    test_payment_outcome_config_digest: None,
                    effects: PaymentEffectBoundary::None,
                    donation_fact_event: None,
                    review_task_event: None,
                };
                state.charge_receipt = Some(receipt.clone());
                receipt
            })
        })
    }

    fn require_charge_reconciliation<'a>(
        &'a self,
        _claim: &'a ChargeClaim,
        reason: ReconciliationReason,
        _evidence_digest: &'a Sha256Digest,
    ) -> PaymentOwnerFuture<'a, ()> {
        Box::pin(async move {
            self.update(|state| {
                state.calls.push("reconciliation");
                state.charge_job_running = false;
                state.reconciliation_reasons.push(reason);
            })
        })
    }

    fn claim_webhook<'a>(
        &'a self,
        binding: &'a WebhookClaimBinding,
    ) -> PaymentOwnerFuture<'a, WebhookClaimDisposition> {
        Box::pin(async move {
            self.update(|state| {
                state.calls.push("claim_webhook");
                if let Some(receipt) = state.webhook_receipt.clone() {
                    if state.webhook_binding.as_ref() == Some(binding) {
                        return WebhookClaimDisposition::Replay(receipt);
                    }
                    return WebhookClaimDisposition::Conflict;
                }
                state.webhook_binding = Some(binding.clone());
                WebhookClaimDisposition::Execute(WebhookClaim {
                    claim_id: Uuid::from_u128(0x6301),
                    attempt_id: self.scenario.attempt_id.get(),
                    merchant_order_id: self.scenario.merchant_order_id.clone(),
                    amount: self.scenario.amount,
                    claim_digest: digest(b'4'),
                })
            })
        })
    }

    fn complete_webhook<'a>(
        &'a self,
        binding: &'a WebhookClaimBinding,
        _claim: &'a WebhookClaim,
        observation: &'a AuthoritativePaymentObservation,
    ) -> PaymentOwnerFuture<'a, WebhookProcessingReceipt> {
        Box::pin(async move {
            self.update(|state| {
                state.calls.push("complete_webhook");
                match observation.state {
                    PaymentState::Succeeded => {
                        state.terminal_state = Some(PaymentState::Succeeded);
                        if !state
                            .donation_fact_effects
                            .contains(&DonationFactEffect::Original)
                        {
                            state
                                .donation_fact_effects
                                .push(DonationFactEffect::Original);
                        }
                    }
                    PaymentState::Refunded => {
                        state.terminal_state = Some(PaymentState::Refunded);
                        state
                            .donation_fact_effects
                            .push(DonationFactEffect::Reversal);
                    }
                    PaymentState::Failed => {
                        state.terminal_state = Some(PaymentState::Failed);
                        state.review_tasks += 1;
                    }
                    PaymentState::PartiallyRefunded => {
                        state.partial_refund_reconciliations += 1;
                    }
                    PaymentState::Pending => state
                        .reconciliation_reasons
                        .push(ReconciliationReason::ProviderPending),
                    PaymentState::Canceled => {
                        state.terminal_state = Some(PaymentState::Canceled);
                        state.review_tasks += 1;
                    }
                }
                let receipt = WebhookProcessingReceipt {
                    schema_version: "provider-webhook-acceptance.v1",
                    provider: binding.provider,
                    event_identity_sha256: binding.event_identity_sha256.clone(),
                    disposition: WebhookDisposition::Applied,
                    receipt_digest: digest(b'5'),
                };
                state.webhook_receipt = Some(receipt.clone());
                Ok(receipt)
            })?
        })
    }

    fn release_webhook_claim<'a>(
        &'a self,
        _binding: &'a WebhookClaimBinding,
        _claim: &'a WebhookClaim,
        _safe_code: &'static str,
    ) -> PaymentOwnerFuture<'a, ()> {
        Box::pin(async move { self.update(|state| state.calls.push("release_webhook")) })
    }
}

fn donation_event(
    state: &mut OwnerState,
    claim: &ChargeClaim,
    observation: &AuthoritativePaymentObservation,
) -> Option<DonationFactEventReceipt> {
    let fact_effect = match observation.state {
        PaymentState::Succeeded => DonationFactEffect::Original,
        PaymentState::Refunded => DonationFactEffect::Reversal,
        _ => return None,
    };
    state.donation_fact_effects.push(fact_effect);
    Some(DonationFactEventReceipt {
        donation_fact_id: Uuid::from_u128(0x6101),
        fact_effect,
        donation_fact_digest: digest(b'd'),
        charge_attempt_id: claim.attempt_id,
        charge_attempt_digest: digest(b'e'),
        provider_fetch_digest: observation.provider_fetch_digest.clone(),
        outbox_event_id: Uuid::from_u128(0x6102),
        occurred_at_unix: observation.provider_observed_at_unix,
    })
}

fn review_event(
    state: &mut OwnerState,
    claim: &ChargeClaim,
    observation: &AuthoritativePaymentObservation,
) -> Option<PaymentReviewEventReceipt> {
    if !matches!(
        observation.state,
        PaymentState::Failed | PaymentState::Canceled
    ) {
        return None;
    }
    state.review_tasks += 1;
    Some(PaymentReviewEventReceipt {
        review_task_id: Uuid::from_u128(0x6201),
        review_task_version: 1,
        review_task_digest: digest(b'1'),
        source_kind: PaymentReviewSourceKind::DonationPaymentFailure,
        source_receipt_id: claim.attempt_id,
        source_receipt_digest: digest(b'2'),
        occurred_at_unix: observation.provider_observed_at_unix,
    })
}

fn completion_state(
    state: &mut OwnerState,
    observed: PaymentState,
) -> Result<(ChargeCompletionState, Option<ChargeTerminalAuthority>), PaymentRuntimeError> {
    let authority = Some(ChargeTerminalAuthority::ProviderFetchConfirmed);
    match observed {
        PaymentState::Succeeded => Ok((ChargeCompletionState::Succeeded, authority)),
        PaymentState::Failed | PaymentState::Canceled => {
            Ok((ChargeCompletionState::Failed, authority))
        }
        PaymentState::Refunded => Ok((ChargeCompletionState::Refunded, authority)),
        PaymentState::PartiallyRefunded => {
            state.partial_refund_reconciliations += 1;
            Ok((ChargeCompletionState::ReconciliationRequired, None))
        }
        PaymentState::Pending => Err(PaymentRuntimeError::OwnerFunction),
    }
}
