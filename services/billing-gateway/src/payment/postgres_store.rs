use std::{sync::Arc, time::Duration};

use gurine_jobs::{fencing::Fence, postgres::ClaimedJob};
use gurine_payment_providers::{
    DeterministicFixtureProviderFactory, ExecutionMode, KrwAmount, ProviderOperation,
};
use serde_json::json;
use sqlx::PgPool;

use crate::digest::Sha256Digest;

use super::{
    identity::{FixtureIdentityKey, FixtureIdentityKeyring},
    model::{
        ClaimedDonationChargeJob, PaymentRuntimeError, WebhookDisposition, WebhookProcessingReceipt,
    },
    postgres_store_rows::{
        BindingReceiptRow, ChargeClaimRow, IntentClaimRow, JobClaimRow, TerminalRow, TransitionRow,
        WebhookClaimRow, amount, digest, provider, required,
    },
    postgres_store_sql::{
        BINDING_COMPLETE_SQL, CHARGE_ACCEPT_SQL, CHARGE_CLAIM_SQL, CHARGE_COMPLETE_SQL,
        CHARGE_FAIL_SQL, CHARGE_RECONCILE_SQL, INTENT_CLAIM_SQL, INTENT_FAIL_SQL, JOB_CLAIM_SQL,
        WEBHOOK_CLAIM_SQL, WEBHOOK_RELEASE_SQL,
    },
    postgres_store_support::{
        ChargeMaterial, IntentMaterial, applied_transition, binding_completion_digest,
        canonical_digest, database, intent_failure_digest, intent_material, map_binding_receipt,
        map_charge_claim, map_intent_claim, map_webhook_receipt, observation_completion_digest,
        opaque_digest, terminal_query, webhook_auth, webhook_claim_digest, webhook_terminal_query,
    },
    store::{
        AuthoritativePaymentObservation, ChargeAcceptance, ChargeClaim, ChargeClaimDisposition,
        DonationChargeClaimBinding, DonationIntentBinding, DonationIntentClaim,
        DonationIntentClaimDisposition, LocalChargeFailureCode, PaymentMethodBindingCompletion,
        PaymentMethodBindingCompletionDisposition, PaymentOwnerFunctions, PaymentOwnerFuture,
        ReconciliationReason, WebhookClaim, WebhookClaimBinding, WebhookClaimDisposition,
    },
};

#[derive(Clone)]
pub struct PostgresPaymentStore {
    pool: PgPool,
    identities: Arc<FixtureIdentityKeyring>,
    factory: DeterministicFixtureProviderFactory,
}

impl PostgresPaymentStore {
    pub fn test_only(
        pool: PgPool,
        factory: DeterministicFixtureProviderFactory,
        current: (Vec<u8>, String),
        previous: Option<(Vec<u8>, String)>,
    ) -> Result<Self, PaymentRuntimeError> {
        let current = FixtureIdentityKey::try_new(current.0, current.1)?;
        let previous = previous
            .map(|(key, version)| FixtureIdentityKey::try_new(key, version))
            .transpose()?;
        Ok(Self {
            pool,
            identities: Arc::new(FixtureIdentityKeyring::try_new(current, previous)?),
            factory,
        })
    }

    pub async fn claim_next_charge_job(
        &self,
        worker_id: &str,
        lease: Duration,
    ) -> Result<Option<ClaimedDonationChargeJob>, PaymentRuntimeError> {
        let lease_seconds =
            i32::try_from(lease.as_secs()).map_err(|_| PaymentRuntimeError::InvalidRequest)?;
        let row = sqlx::query_as::<_, JobClaimRow>(JOB_CLAIM_SQL)
            .bind(worker_id)
            .bind(lease_seconds)
            .fetch_one(&self.pool)
            .await
            .map_err(database)?;
        if row.disposition == "NONE" {
            return Ok(None);
        }
        if row.disposition != "CLAIMED" {
            return Err(PaymentRuntimeError::OwnerFunction);
        }
        let payload = required(row.payload)?;
        let payload_digest = canonical_digest(&payload)?;
        if digest(row.job_binding_digest)? != payload_digest {
            return Err(PaymentRuntimeError::OwnerFunction);
        }
        Ok(Some(ClaimedDonationChargeJob {
            job: ClaimedJob {
                id: required(row.job_id)?,
                job_type: required(row.job_type)?,
                queue: required(row.queue)?,
                payload,
                attempt: required(row.attempt)?,
                max_attempts: required(row.max_attempts)?,
                fence: Fence {
                    lease_token: required(row.lease_token)?,
                    fencing_token: required(row.fencing_token)?,
                },
                lease_expires_at: required(row.lease_expires_at)?,
            },
            provider: provider(&required(row.provider)?)?,
            amount: amount(row.amount_whole_krw)?,
        }))
    }

    async fn claim_intent_with(
        &self,
        binding: &DonationIntentBinding,
        amount: KrwAmount,
        key: &FixtureIdentityKey,
    ) -> Result<(IntentClaimRow, IntentMaterial), PaymentRuntimeError> {
        let material = intent_material(key, binding, amount)?;
        let row = sqlx::query_as::<_, IntentClaimRow>(INTENT_CLAIM_SQL)
            .bind(binding.request_id)
            .bind(binding.provider.as_str())
            .bind(material.merchant_account_hmac.as_str())
            .bind(&material.key_version)
            .bind(material.donor_hmac.as_str())
            .bind(material.donor_group_hmac.as_str())
            .bind(&material.key_version)
            .bind(binding.offer_version_id)
            .bind(binding.offer_digest.as_str())
            .bind(binding.tier_id)
            .bind(binding.cadence.as_str())
            .bind(binding.consent_receipt_digest.as_str())
            .bind(material.owner_request_digest.as_str())
            .bind(amount.whole_krw())
            .bind(material.idempotency.hmac.as_str())
            .bind(&material.idempotency.key_version)
            .fetch_one(&self.pool)
            .await
            .map_err(database)?;
        Ok((row, material))
    }

    async fn claim_charge_with(
        &self,
        binding: &DonationChargeClaimBinding<'_>,
        key: &FixtureIdentityKey,
    ) -> Result<(ChargeClaimRow, ChargeMaterial), PaymentRuntimeError> {
        let material = self.charge_material(key, binding)?;
        let row = sqlx::query_as::<_, ChargeClaimRow>(CHARGE_CLAIM_SQL)
            .bind(binding.job_id)
            .bind(binding.worker_id)
            .bind(binding.job_lease_token)
            .bind(binding.job_fencing_token)
            .bind(binding.job_payload_digest.as_str())
            .bind(material.identity.idempotency.hmac.as_str())
            .bind(&material.identity.idempotency.key_version)
            .bind(material.identity.merchant_order_hmac.as_str())
            .bind(&material.identity.idempotency.key_version)
            .bind(material.merchant_order_digest.as_str())
            .bind(material.expected_provider_payment_digest.as_str())
            .fetch_one(&self.pool)
            .await
            .map_err(database)?;
        Ok((row, material))
    }

    fn charge_material(
        &self,
        key: &FixtureIdentityKey,
        binding: &DonationChargeClaimBinding<'_>,
    ) -> Result<ChargeMaterial, PaymentRuntimeError> {
        let identity = key.charge_identity(
            binding.logical_charge_id,
            binding.charge_idempotency_key_sha256,
            binding.job_payload_digest,
        )?;
        let merchant_order_digest = opaque_digest(
            b"gurine-merchant-order-id.v1\0",
            identity.merchant_order_id.as_str(),
        );
        let expected = self.factory.expected_provider_payment_id_digest(
            binding.provider,
            identity.idempotency.value,
            &identity.merchant_order_id,
            binding.amount,
        )?;
        Ok(ChargeMaterial {
            identity,
            merchant_order_digest,
            expected_provider_payment_digest: expected
                .as_str()
                .parse()
                .map_err(|_| PaymentRuntimeError::OwnerFunction)?,
        })
    }
}

impl PaymentOwnerFunctions for PostgresPaymentStore {
    fn claim_donation_intent<'a>(
        &'a self,
        binding: &'a DonationIntentBinding,
        expected_amount: KrwAmount,
    ) -> PaymentOwnerFuture<'a, DonationIntentClaimDisposition> {
        Box::pin(async move {
            let (mut row, mut material) = self
                .claim_intent_with(binding, expected_amount, self.identities.current())
                .await?;
            if row.disposition == "CONFLICT" {
                if let Some(key) = row
                    .provider_idempotency_version
                    .as_deref()
                    .and_then(|version| self.identities.previous_for_version(version))
                {
                    (row, material) = self
                        .claim_intent_with(binding, expected_amount, key)
                        .await?;
                }
            }
            map_intent_claim(row, binding, material)
        })
    }

    fn complete_payment_method_binding<'a>(
        &'a self,
        completion: PaymentMethodBindingCompletion<'a>,
    ) -> PaymentOwnerFuture<'a, PaymentMethodBindingCompletionDisposition> {
        Box::pin(async move {
            if completion.provider_receipt.execution_mode != ExecutionMode::TestFixtureOnly
                || completion.provider_receipt.operation != ProviderOperation::IssueBillingKey
                || completion.provider_receipt.provider != completion.handle.provider
            {
                return Err(PaymentRuntimeError::InvalidRequest);
            }
            let material = self.intent_material_for_claim(completion.intent, completion.claim)?;
            let digest = binding_completion_digest(&completion, &material)?;
            let row = sqlx::query_as::<_, BindingReceiptRow>(BINDING_COMPLETE_SQL)
                .bind(completion.intent.request_id)
                .bind(material.owner_request_digest.as_str())
                .bind(completion.claim.donation_intent_id)
                .bind(completion.claim.binding_id)
                .bind(completion.claim.claim_digest.as_str())
                .bind(completion.handle.provider.as_str())
                .bind(material.idempotency.hmac.as_str())
                .bind(&completion.handle.secret_reference)
                .bind(&completion.handle.material_hmac)
                .bind(completion.handle.hmac_key_version.as_str())
                .bind(completion.handle.use_policy.as_str())
                .bind(&completion.provider_receipt.request_sha256)
                .bind(&completion.provider_receipt.response_sha256)
                .bind(i32::from(completion.provider_receipt.http_status))
                .bind(digest.as_str())
                .fetch_one(&self.pool)
                .await
                .map_err(database)?;
            map_binding_receipt(row, completion.intent.request_id, completion.claim.job_id)
        })
    }

    fn fail_donation_intent<'a>(
        &'a self,
        intent: &'a DonationIntentBinding,
        claim: &'a DonationIntentClaim,
        safe_code: &'static str,
    ) -> PaymentOwnerFuture<'a, ()> {
        Box::pin(async move {
            let material = self.intent_material_for_claim(intent, claim)?;
            let evidence = intent_failure_digest(intent, claim, &material, safe_code)?;
            let row = sqlx::query_as::<_, TransitionRow>(INTENT_FAIL_SQL)
                .bind(intent.request_id)
                .bind(material.owner_request_digest.as_str())
                .bind(claim.donation_intent_id)
                .bind(claim.binding_id)
                .bind(claim.claim_digest.as_str())
                .bind(safe_code)
                .bind(evidence.as_str())
                .fetch_one(&self.pool)
                .await
                .map_err(database)?;
            applied_transition(row, "FAILED")
        })
    }

    fn claim_charge<'a>(
        &'a self,
        binding: DonationChargeClaimBinding<'a>,
    ) -> PaymentOwnerFuture<'a, ChargeClaimDisposition> {
        Box::pin(async move {
            let (mut row, mut material) = self
                .claim_charge_with(&binding, self.identities.current())
                .await?;
            if row.disposition == "CONFLICT" {
                if let Some(key) = row
                    .provider_idempotency_version
                    .as_deref()
                    .and_then(|version| self.identities.previous_for_version(version))
                {
                    (row, material) = self.claim_charge_with(&binding, key).await?;
                }
            }
            map_charge_claim(row, &binding, material)
        })
    }

    fn complete_charge<'a>(
        &'a self,
        claim: &'a ChargeClaim,
        observation: &'a AuthoritativePaymentObservation,
    ) -> PaymentOwnerFuture<'a, super::store::ChargeTerminalReceipt> {
        Box::pin(async move {
            let digest = observation_completion_digest(
                claim.attempt_id,
                &claim.claim_digest,
                observation,
                "private.ExecuteDonationCharge",
            )?;
            terminal_query(CHARGE_COMPLETE_SQL, &self.pool, claim, observation, &digest).await
        })
    }

    fn accept_charge<'a>(
        &'a self,
        claim: &'a ChargeClaim,
        acceptance: &'a ChargeAcceptance,
    ) -> PaymentOwnerFuture<'a, ()> {
        Box::pin(async move {
            let digest = canonical_digest(&json!({
                "schemaVersion":"r6e-donation-charge-acceptance.v1",
                "attemptId":claim.attempt_id,"claimDigest":claim.claim_digest,
                "providerPaymentIdDigest":acceptance.provider_payment_id_sha256,
                "transportRequestDigest":acceptance.transport_request_sha256,
                "transportResponseDigest":acceptance.transport_response_sha256,
                "fixtureAuthority":acceptance.fixture_authority,
                "testPaymentOutcomeConfigDigest":acceptance.test_payment_outcome_config_digest,
            }))?;
            let row = sqlx::query_as::<_, TransitionRow>(CHARGE_ACCEPT_SQL)
                .bind(claim.attempt_id)
                .bind(claim.claim_digest.as_str())
                .bind(acceptance.provider_payment_id_sha256.as_str())
                .bind(acceptance.transport_request_sha256.as_str())
                .bind(acceptance.transport_response_sha256.as_str())
                .bind(acceptance.fixture_authority)
                .bind(acceptance.test_payment_outcome_config_digest.as_str())
                .bind(digest.as_str())
                .fetch_one(&self.pool)
                .await
                .map_err(database)?;
            applied_transition(row, "PROVIDER_ACCEPTED")
        })
    }

    fn fail_charge<'a>(
        &'a self,
        claim: &'a ChargeClaim,
        safe_code: LocalChargeFailureCode,
        evidence_digest: &'a Sha256Digest,
    ) -> PaymentOwnerFuture<'a, super::store::ChargeTerminalReceipt> {
        Box::pin(async move {
            let completion = canonical_digest(&json!({
                "schemaVersion":"r6e-donation-charge-local-failure.v1",
                "attemptId":claim.attempt_id,"claimDigest":claim.claim_digest,
                "safeCode":safe_code.as_str(),"failureEvidenceDigest":evidence_digest,
            }))?;
            let row = sqlx::query_as::<_, TerminalRow>(CHARGE_FAIL_SQL)
                .bind(claim.attempt_id)
                .bind(claim.claim_digest.as_str())
                .bind(safe_code.as_str())
                .bind(evidence_digest.as_str())
                .bind(completion.as_str())
                .fetch_one(&self.pool)
                .await
                .map_err(database)?;
            row.into_receipt()
        })
    }

    fn require_charge_reconciliation<'a>(
        &'a self,
        claim: &'a ChargeClaim,
        reason: ReconciliationReason,
        evidence_digest: &'a Sha256Digest,
    ) -> PaymentOwnerFuture<'a, ()> {
        Box::pin(async move {
            let row = sqlx::query_as::<_, TransitionRow>(CHARGE_RECONCILE_SQL)
                .bind(claim.attempt_id)
                .bind(claim.claim_digest.as_str())
                .bind(reason.as_str())
                .bind(evidence_digest.as_str())
                .fetch_one(&self.pool)
                .await
                .map_err(database)?;
            applied_transition(row, "RECONCILIATION_REQUIRED")
        })
    }

    fn claim_webhook<'a>(
        &'a self,
        binding: &'a WebhookClaimBinding,
    ) -> PaymentOwnerFuture<'a, WebhookClaimDisposition> {
        Box::pin(async move {
            let (auth, signature, signed_payload) = webhook_auth(&binding.authentication);
            let request_digest = webhook_claim_digest(binding, auth, signature, signed_payload)?;
            let row = sqlx::query_as::<_, WebhookClaimRow>(WEBHOOK_CLAIM_SQL)
                .bind(binding.provider.as_str())
                .bind(binding.event_identity_sha256.as_str())
                .bind(binding.locator_kind.as_str())
                .bind(binding.locator_sha256.as_str())
                .bind(binding.body_sha256.as_str())
                .bind(binding.hint_sha256.as_str())
                .bind(auth)
                .bind(signature)
                .bind(signed_payload)
                .bind(request_digest.as_str())
                .fetch_one(&self.pool)
                .await
                .map_err(database)?;
            self.map_webhook_claim(row, binding)
        })
    }

    fn complete_webhook<'a>(
        &'a self,
        binding: &'a WebhookClaimBinding,
        claim: &'a WebhookClaim,
        observation: &'a AuthoritativePaymentObservation,
    ) -> PaymentOwnerFuture<'a, WebhookProcessingReceipt> {
        Box::pin(async move {
            let inner = observation_completion_digest(
                observation.attempt_id,
                &claim.claim_digest,
                observation,
                "private.ReceivePaymentWebhook",
            )?;
            let outer = canonical_digest(&json!({
                "schemaVersion":"r6e-provider-webhook-completion.v1",
                "provider":binding.provider.as_str(),
                "eventIdentityDigest":binding.event_identity_sha256,
                "claimId":claim.claim_id,"claimDigest":claim.claim_digest,
                "observationDigest":inner,
            }))?;
            let row =
                webhook_terminal_query(&self.pool, binding, claim, observation, &outer).await?;
            map_webhook_receipt(row, binding)
        })
    }

    fn release_webhook_claim<'a>(
        &'a self,
        binding: &'a WebhookClaimBinding,
        claim: &'a WebhookClaim,
        safe_code: &'static str,
    ) -> PaymentOwnerFuture<'a, ()> {
        Box::pin(async move {
            let evidence = canonical_digest(&json!({
                "schemaVersion":"r6e-provider-webhook-release.v1",
                "provider":binding.provider.as_str(),
                "eventIdentityDigest":binding.event_identity_sha256,
                "claimId":claim.claim_id,"claimDigest":claim.claim_digest,
                "safeCode":safe_code,
            }))?;
            let row = sqlx::query_as::<_, TransitionRow>(WEBHOOK_RELEASE_SQL)
                .bind(binding.provider.as_str())
                .bind(binding.event_identity_sha256.as_str())
                .bind(claim.claim_id)
                .bind(claim.claim_digest.as_str())
                .bind(safe_code)
                .bind(evidence.as_str())
                .fetch_one(&self.pool)
                .await
                .map_err(database)?;
            applied_transition(row, "RELEASED")
        })
    }
}

impl PostgresPaymentStore {
    fn intent_material_for_claim(
        &self,
        binding: &DonationIntentBinding,
        claim: &DonationIntentClaim,
    ) -> Result<IntentMaterial, PaymentRuntimeError> {
        self.identities
            .candidates()
            .filter_map(|key| intent_material(key, binding, claim.amount).ok())
            .find(|material| material.idempotency.value == claim.provider_idempotency_key)
            .ok_or(PaymentRuntimeError::OwnerFunction)
    }

    fn map_webhook_claim(
        &self,
        row: WebhookClaimRow,
        binding: &WebhookClaimBinding,
    ) -> Result<WebhookClaimDisposition, PaymentRuntimeError> {
        if row.disposition == "REPLAY" {
            let replay_provider = provider(&required(row.provider)?)?;
            let replay_event_identity = digest(row.event_identity_digest)?;
            if replay_provider != binding.provider
                || replay_event_identity != binding.event_identity_sha256
            {
                return Err(PaymentRuntimeError::OwnerFunction);
            }
            return Ok(WebhookClaimDisposition::Replay(WebhookProcessingReceipt {
                schema_version: "provider-webhook-acceptance.v1",
                provider: replay_provider,
                event_identity_sha256: replay_event_identity,
                disposition: WebhookDisposition::Applied,
                receipt_digest: digest(row.webhook_receipt_digest)?,
            }));
        }
        if row.disposition == "CONFLICT" {
            return Ok(WebhookClaimDisposition::Conflict);
        }
        if row.disposition == "IN_PROGRESS" {
            return Ok(WebhookClaimDisposition::InProgress);
        }
        if row.disposition != "EXECUTE" {
            return Err(PaymentRuntimeError::OwnerFunction);
        }
        let logical = required(row.logical_charge_id)?;
        let job_digest = digest(row.job_binding_digest)?;
        let charge_digest = digest(row.charge_idempotency_digest)?;
        let merchant_digest = digest(row.merchant_order_digest)?;
        let identity = self
            .identities
            .candidates()
            .find_map(|key| {
                key.charge_identity(logical, &charge_digest, &job_digest)
                    .ok()
                    .filter(|value| {
                        opaque_digest(
                            b"gurine-merchant-order-id.v1\0",
                            value.merchant_order_id.as_str(),
                        ) == merchant_digest
                    })
            })
            .ok_or(PaymentRuntimeError::OwnerFunction)?;
        Ok(WebhookClaimDisposition::Execute(WebhookClaim {
            claim_id: required(row.claim_id)?,
            attempt_id: required(row.attempt_id)?,
            merchant_order_id: identity.merchant_order_id,
            amount: amount(row.amount_whole_krw)?,
            claim_digest: digest(row.claim_digest)?,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::payment::postgres_store_sql::OWNER_SQL;
    use crate::payment::postgres_store_support::postgres_timestamp;

    #[test]
    fn sql_surface_contains_only_closed_owner_calls() {
        let sql = OWNER_SQL.join("\n");
        assert!(!sql.contains("INSERT "));
        assert!(!sql.contains("UPDATE "));
        assert!(!sql.contains("DELETE "));
        assert!(!sql.contains("ops.payment_"));
        assert_eq!(OWNER_SQL.len(), 12);
        assert_eq!(sql.matches("WITH r AS (SELECT ops.").count(), 12);
    }

    #[test]
    fn postgres_timestamp_matches_jsonb_utc_shape() -> Result<(), PaymentRuntimeError> {
        assert_eq!(
            postgres_timestamp(1_800_000_000)?,
            "2027-01-15T08:00:00+00:00"
        );
        Ok(())
    }
}
