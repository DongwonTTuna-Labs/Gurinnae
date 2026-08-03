use std::sync::Arc;

use gurine_payment_providers::{
    BillingCredentialUsePolicy, BillingKeyVault, IssueBillingKeyRequest, KrwAmount,
    PaymentProvider, ProviderKind, WebhookHeaders,
};

use crate::{
    digest::Sha256Digest,
    payment::{
        charge::{
            ChargeDispatchOutcome, ProviderFetchOutcome, dispatch_charge, fetch_accepted_claim,
            fetch_after_acceptance, local_failure_code,
        },
        fixture_offer::FixtureDonationOffer,
        model::{
            ChargeExecution, ClaimedDonationChargeJob, DonationCadence, DonationIntentRequest,
            DonationQueuedReceipt, PaymentRuntimeError, WEBHOOK_ACCEPTANCE_SCHEMA,
            WebhookDisposition, WebhookProcessingReceipt,
        },
        provider_set::ProviderSet,
        receipt::{
            charge_acceptance, observation, parse_charge_job, provider_error_code,
            terminal_summary, validate_queued_receipt, validate_terminal_receipt,
        },
        store::{
            ChargeClaim, ChargeClaimDisposition, ChargeCompletionState, DonationChargeClaimBinding,
            DonationIntentBinding, DonationIntentClaim, DonationIntentClaimDisposition,
            PaymentMethodBindingCompletion, PaymentMethodBindingCompletionDisposition,
            PaymentOwnerFunctions, ReconciliationReason, WebhookClaimDisposition,
        },
        webhook::{authenticate_webhook, fetch_webhook_payment},
    },
};

pub use super::receipt::consent_receipt_digest;

struct PreparedDonationIntent {
    provider: ProviderKind,
    binding: DonationIntentBinding,
    amount: KrwAmount,
    use_policy: BillingCredentialUsePolicy,
}

pub struct PaymentEngine<S> {
    store: S,
    providers: Option<ProviderSet>,
    vault: Option<Arc<dyn BillingKeyVault>>,
    fixture_offer: Option<FixtureDonationOffer>,
    expected_authorization_sha256: Option<Sha256Digest>,
    test_payment_outcome_config_digest: Option<Sha256Digest>,
}

impl<S: PaymentOwnerFunctions> PaymentEngine<S> {
    pub fn disabled(store: S) -> Self {
        Self {
            store,
            providers: None,
            vault: None,
            fixture_offer: None,
            expected_authorization_sha256: None,
            test_payment_outcome_config_digest: None,
        }
    }

    pub fn test_only(
        store: S,
        providers: ProviderSet,
        vault: Arc<dyn BillingKeyVault>,
        expected_authorization_sha256: Sha256Digest,
        test_payment_outcome_config_digest: Sha256Digest,
    ) -> Self {
        Self {
            store,
            providers: Some(providers),
            vault: Some(vault),
            fixture_offer: Some(FixtureDonationOffer::test_fixture()),
            expected_authorization_sha256: Some(expected_authorization_sha256),
            test_payment_outcome_config_digest: Some(test_payment_outcome_config_digest),
        }
    }

    pub fn fixture_offer(&self) -> Result<&FixtureDonationOffer, PaymentRuntimeError> {
        self.fixture_offer
            .as_ref()
            .ok_or(PaymentRuntimeError::Unavailable)
    }

    pub async fn queue_donation_intent(
        &self,
        request: DonationIntentRequest,
        request_digest: Sha256Digest,
    ) -> Result<DonationQueuedReceipt, PaymentRuntimeError> {
        let providers = self
            .providers
            .as_ref()
            .ok_or(PaymentRuntimeError::Unavailable)?;
        let vault = self
            .vault
            .as_ref()
            .ok_or(PaymentRuntimeError::Unavailable)?;
        let prepared = self.prepare_donation_intent(request, request_digest)?;
        let claim = match self
            .store
            .claim_donation_intent(&prepared.binding, prepared.amount)
            .await?
        {
            DonationIntentClaimDisposition::Execute(claim) => claim,
            DonationIntentClaimDisposition::Replay(receipt) => {
                validate_queued_receipt(&prepared.binding, None, &receipt)?;
                return Ok(receipt);
            }
            DonationIntentClaimDisposition::Conflict => return Err(PaymentRuntimeError::Conflict),
            DonationIntentClaimDisposition::InProgress => {
                return Err(PaymentRuntimeError::InProgress);
            }
        };
        if claim.amount != prepared.amount {
            self.fail_intent(&prepared.binding, &claim, "FIXTURE_AMOUNT_BINDING_MISMATCH")
                .await?;
            return Err(PaymentRuntimeError::OwnerFunction);
        }
        let provider = providers.get(prepared.provider)?;
        self.issue_and_complete_intent(
            prepared,
            claim,
            providers,
            provider.as_ref(),
            vault.as_ref(),
        )
        .await
    }

    fn prepare_donation_intent(
        &self,
        request: DonationIntentRequest,
        request_digest: Sha256Digest,
    ) -> Result<PreparedDonationIntent, PaymentRuntimeError> {
        let amount = self.fixture_offer()?.resolve(&request)?;
        if consent_receipt_digest(&request) != request.consent_receipt_digest {
            return Err(PaymentRuntimeError::InvalidRequest);
        }
        request.payment_authorization_token.consume_if_matches(
            self.expected_authorization_sha256
                .as_ref()
                .ok_or(PaymentRuntimeError::Unavailable)?,
        )?;
        let use_policy = use_policy(request.cadence);
        let provider = request.provider;
        let binding = DonationIntentBinding {
            request_id: request.request_id,
            offer_version_id: request.offer_version_id,
            offer_digest: request.offer_digest.clone(),
            tier_id: request.tier_id,
            cadence: request.cadence,
            provider: request.provider,
            consent_receipt_digest: request.consent_receipt_digest.clone(),
            request_digest,
        };
        Ok(PreparedDonationIntent {
            provider,
            binding,
            amount,
            use_policy,
        })
    }

    async fn issue_and_complete_intent(
        &self,
        prepared: PreparedDonationIntent,
        claim: DonationIntentClaim,
        providers: &ProviderSet,
        provider: &dyn PaymentProvider,
        vault: &dyn BillingKeyVault,
    ) -> Result<DonationQueuedReceipt, PaymentRuntimeError> {
        let authorization = providers.issue_authorization(
            prepared.provider,
            claim.binding_id,
            claim.provider_idempotency_key,
        )?;
        let issue_request = IssueBillingKeyRequest {
            binding_id: claim.binding_id,
            idempotency_key: claim.provider_idempotency_key,
            use_policy: prepared.use_policy,
            authorization,
        };
        let issue = match provider.issue_billing_key(&issue_request).await {
            Ok(receipt) => receipt,
            Err(error) => {
                self.fail_intent(&prepared.binding, &claim, provider_error_code(error))
                    .await?;
                return Err(error.into());
            }
        };
        if issue.use_policy != prepared.use_policy || issue.binding_id != claim.binding_id {
            self.fail_intent(
                &prepared.binding,
                &claim,
                "PAYMENT_CREDENTIAL_POLICY_MISMATCH",
            )
            .await?;
            return Err(PaymentRuntimeError::InvalidRequest);
        }
        let handle = match vault.store(claim.binding_id, issue.material, prepared.use_policy) {
            Ok(handle) => handle,
            Err(error) => {
                self.fail_intent(&prepared.binding, &claim, "PAYMENT_VAULT_UNAVAILABLE")
                    .await?;
                return Err(error.into());
            }
        };
        let completion = self
            .store
            .complete_payment_method_binding(PaymentMethodBindingCompletion {
                intent: &prepared.binding,
                claim: &claim,
                handle: &handle,
                provider_receipt: &issue.transport,
            })
            .await?;
        let receipt = match completion {
            PaymentMethodBindingCompletionDisposition::Committed(receipt) => receipt,
            PaymentMethodBindingCompletionDisposition::RejectedUnreferenced => {
                vault.destroy(&handle)?;
                self.fail_intent(
                    &prepared.binding,
                    &claim,
                    "PAYMENT_BINDING_COMPLETION_INVALID",
                )
                .await?;
                return Err(PaymentRuntimeError::InvalidRequest);
            }
        };
        // A failed or malformed completion can have committed. Retain the
        // credential until an authoritative receipt proves it is unreferenced.
        validate_queued_receipt(&prepared.binding, Some(claim.job_id), &receipt)?;
        Ok(receipt)
    }

    pub async fn execute_charge_job(
        &self,
        worker_id: &str,
        claimed_job: &ClaimedDonationChargeJob,
    ) -> Result<ChargeExecution, PaymentRuntimeError> {
        let job = &claimed_job.job;
        let binding = parse_charge_job(job)?;
        let binding_digest = binding.digest()?;
        let disposition = self
            .store
            .claim_charge(DonationChargeClaimBinding {
                job_id: job.id,
                worker_id,
                job_lease_token: job.fence.lease_token,
                job_fencing_token: job.fence.fencing_token,
                job_payload_digest: &binding_digest,
                logical_charge_id: binding.logical_charge_id,
                charge_idempotency_key_sha256: &binding.charge_idempotency_key_sha256,
                provider: claimed_job.provider,
                amount: claimed_job.amount,
            })
            .await?;
        match disposition {
            ChargeClaimDisposition::Execute(claim) => {
                validate_claim_binding(&claim, &binding, claimed_job)?;
                self.dispatch_claimed_charge(&claim).await
            }
            ChargeClaimDisposition::ResumeAccepted(claim) => {
                validate_claim_binding(&claim, &binding, claimed_job)?;
                self.resume_accepted_charge(&claim).await
            }
            ChargeClaimDisposition::Replay(receipt) => self.replay_charge(receipt),
            ChargeClaimDisposition::Conflict => Err(PaymentRuntimeError::Conflict),
            ChargeClaimDisposition::InProgress => Err(PaymentRuntimeError::InProgress),
        }
    }

    async fn dispatch_claimed_charge(
        &self,
        claim: &ChargeClaim,
    ) -> Result<ChargeExecution, PaymentRuntimeError> {
        let providers = self
            .providers
            .as_ref()
            .ok_or(PaymentRuntimeError::Unavailable)?;
        let vault = self
            .vault
            .as_ref()
            .ok_or(PaymentRuntimeError::Unavailable)?;
        let provider = providers.get(claim.provider)?;
        if claim.credential_use_policy != claim.billing_key_handle.use_policy {
            return self
                .reconcile(
                    claim,
                    ReconciliationReason::FetchUnavailable,
                    Sha256Digest::of(b"credential-policy-mismatch"),
                )
                .await;
        }
        let material = match vault.take_for_charge(&claim.billing_key_handle) {
            Ok(material) => material,
            Err(_) => {
                return self
                    .reconcile(
                        claim,
                        ReconciliationReason::FetchUnavailable,
                        Sha256Digest::of(b"vault-missing"),
                    )
                    .await;
            }
        };
        match dispatch_charge(provider.as_ref(), claim, &material).await {
            ChargeDispatchOutcome::Accepted(acknowledgement) => {
                self.accept_then_fetch(claim, provider.as_ref(), &acknowledgement)
                    .await
            }
            ChargeDispatchOutcome::FetchAuthoritativeState => {
                let fetched = fetch_accepted_claim(provider.as_ref(), claim).await;
                self.finish_provider_fetch(claim, fetched).await
            }
            ChargeDispatchOutcome::LocalReject(error) => self.reject_charge(claim, error).await,
            ChargeDispatchOutcome::Reconciliation(reason, evidence_digest) => {
                self.reconcile(claim, reason, evidence_digest).await
            }
        }
    }

    async fn accept_then_fetch(
        &self,
        claim: &ChargeClaim,
        provider: &dyn PaymentProvider,
        acknowledgement: &gurine_payment_providers::ChargeAcknowledgement,
    ) -> Result<ChargeExecution, PaymentRuntimeError> {
        let acceptance = charge_acceptance(
            claim,
            acknowledgement,
            self.outcome_config_digest()?.clone(),
        )?;
        if acceptance.provider_payment_id_sha256 != claim.expected_provider_payment_id_sha256 {
            return self
                .reconcile(
                    claim,
                    ReconciliationReason::ChargeOutcomeUnknown,
                    acceptance.transport_response_sha256,
                )
                .await;
        }
        self.store.accept_charge(claim, &acceptance).await?;
        let fetched = fetch_after_acceptance(provider, claim, acknowledgement).await;
        self.finish_provider_fetch(claim, fetched).await
    }

    async fn resume_accepted_charge(
        &self,
        claim: &ChargeClaim,
    ) -> Result<ChargeExecution, PaymentRuntimeError> {
        let provider = self
            .providers
            .as_ref()
            .ok_or(PaymentRuntimeError::Unavailable)?
            .get(claim.provider)?;
        let fetched = fetch_accepted_claim(provider.as_ref(), claim).await;
        self.finish_provider_fetch(claim, fetched).await
    }

    async fn finish_provider_fetch(
        &self,
        claim: &ChargeClaim,
        fetched: ProviderFetchOutcome,
    ) -> Result<ChargeExecution, PaymentRuntimeError> {
        let fetched = match fetched {
            ProviderFetchOutcome::Fetched(fetched) => fetched,
            ProviderFetchOutcome::Reconciliation(reason, evidence_digest) => {
                return self.reconcile(claim, reason, evidence_digest).await;
            }
        };
        let observation = observation(&fetched, self.outcome_config_digest()?.clone())?;
        if observation.provider_payment_id_sha256 != claim.expected_provider_payment_id_sha256 {
            return self
                .reconcile(
                    claim,
                    ReconciliationReason::ChargeOutcomeUnknown,
                    observation.provider_fetch_digest,
                )
                .await;
        }
        let receipt = self.store.complete_charge(claim, &observation).await?;
        validate_terminal_receipt(&receipt, Some(&observation), self.outcome_config_digest()?)?;
        if receipt.state == ChargeCompletionState::ReconciliationRequired {
            Ok(ChargeExecution::ReconciliationRequired {
                attempt_id: receipt.attempt_id,
            })
        } else {
            Ok(ChargeExecution::Confirmed(terminal_summary(&receipt)))
        }
    }

    async fn reject_charge(
        &self,
        claim: &ChargeClaim,
        error: gurine_payment_providers::PaymentProviderError,
    ) -> Result<ChargeExecution, PaymentRuntimeError> {
        let evidence_digest = Sha256Digest::of(provider_error_code(error).as_bytes());
        let receipt = self
            .store
            .fail_charge(claim, local_failure_code(error), &evidence_digest)
            .await?;
        validate_terminal_receipt(&receipt, None, self.outcome_config_digest()?)?;
        Ok(ChargeExecution::Rejected(terminal_summary(&receipt)))
    }

    fn replay_charge(
        &self,
        receipt: crate::payment::store::ChargeTerminalReceipt,
    ) -> Result<ChargeExecution, PaymentRuntimeError> {
        validate_terminal_receipt(&receipt, None, self.outcome_config_digest()?)?;
        if receipt.state == ChargeCompletionState::ReconciliationRequired {
            Ok(ChargeExecution::ReconciliationRequired {
                attempt_id: receipt.attempt_id,
            })
        } else {
            Ok(ChargeExecution::Replay(terminal_summary(&receipt)))
        }
    }

    pub async fn process_webhook(
        &self,
        provider_kind: ProviderKind,
        headers: &WebhookHeaders,
        body: &[u8],
        now_unix: i64,
    ) -> Result<WebhookProcessingReceipt, PaymentRuntimeError> {
        let providers = self
            .providers
            .as_ref()
            .ok_or(PaymentRuntimeError::Unavailable)?;
        if body.is_empty() || body.len() > 65_536 {
            return Err(PaymentRuntimeError::InvalidRequest);
        }
        let verifier = providers.webhook_verifier(provider_kind)?;
        let (hint, binding) =
            authenticate_webhook(provider_kind, verifier.as_ref(), headers, body, now_unix)?;
        let claim = match self.store.claim_webhook(&binding).await? {
            WebhookClaimDisposition::Execute(claim) => claim,
            WebhookClaimDisposition::Replay(mut receipt) => {
                if receipt.event_identity_sha256 != binding.event_identity_sha256 {
                    return Err(PaymentRuntimeError::Conflict);
                }
                receipt.disposition = WebhookDisposition::Duplicate;
                return Ok(receipt);
            }
            WebhookClaimDisposition::Conflict => return Err(PaymentRuntimeError::Conflict),
            WebhookClaimDisposition::InProgress => return Err(PaymentRuntimeError::InProgress),
        };
        let provider = providers.get(provider_kind)?;
        let fetched = match fetch_webhook_payment(provider.as_ref(), &hint, &claim).await {
            Ok(fetched) => fetched,
            Err(error) => {
                self.store
                    .release_webhook_claim(&binding, &claim, provider_error_code(error))
                    .await?;
                return Err(error.into());
            }
        };
        let observation = observation(&fetched, self.outcome_config_digest()?.clone())?;
        let receipt = self
            .store
            .complete_webhook(&binding, &claim, &observation)
            .await?;
        if receipt.schema_version != WEBHOOK_ACCEPTANCE_SCHEMA
            || receipt.provider != provider_kind
            || receipt.event_identity_sha256 != binding.event_identity_sha256
            || receipt.disposition != WebhookDisposition::Applied
        {
            return Err(PaymentRuntimeError::OwnerFunction);
        }
        Ok(receipt)
    }

    async fn fail_intent(
        &self,
        intent: &DonationIntentBinding,
        claim: &DonationIntentClaim,
        safe_code: &'static str,
    ) -> Result<(), PaymentRuntimeError> {
        self.store
            .fail_donation_intent(intent, claim, safe_code)
            .await
    }

    fn outcome_config_digest(&self) -> Result<&Sha256Digest, PaymentRuntimeError> {
        self.test_payment_outcome_config_digest
            .as_ref()
            .ok_or(PaymentRuntimeError::Unavailable)
    }

    async fn reconcile(
        &self,
        claim: &ChargeClaim,
        reason: ReconciliationReason,
        evidence_digest: Sha256Digest,
    ) -> Result<ChargeExecution, PaymentRuntimeError> {
        self.store
            .require_charge_reconciliation(claim, reason, &evidence_digest)
            .await?;
        Ok(ChargeExecution::ReconciliationRequired {
            attempt_id: claim.attempt_id,
        })
    }
}

fn validate_claim_binding(
    claim: &ChargeClaim,
    binding: &crate::payment::model::DonationChargeJobPayload,
    claimed_job: &ClaimedDonationChargeJob,
) -> Result<(), PaymentRuntimeError> {
    if claim.logical_charge_id != binding.logical_charge_id
        || claim.provider != claimed_job.provider
        || claim.amount != claimed_job.amount
    {
        Err(PaymentRuntimeError::OwnerFunction)
    } else {
        Ok(())
    }
}

const fn use_policy(cadence: DonationCadence) -> BillingCredentialUsePolicy {
    match cadence {
        DonationCadence::OneTime => BillingCredentialUsePolicy::SingleCharge,
        DonationCadence::Recurring => BillingCredentialUsePolicy::Recurring,
    }
}
