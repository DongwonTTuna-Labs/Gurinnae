use gurine_auth::assertion::canonical::canonical_json;
use gurine_payment_providers::{
    BillingCredentialUsePolicy, BillingKeyHandle, KeyVersion, KrwAmount,
};
use serde_json::{Value, json};
use sqlx::PgPool;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

use crate::digest::Sha256Digest;

use super::{
    identity::{ChargeProviderIdentity, FixtureIdentityKey, ProviderIdempotency},
    model::{
        DonationQueuedReceipt, PaymentRuntimeError, WebhookDisposition, WebhookProcessingReceipt,
    },
    postgres_store_rows::{
        BindingReceiptRow, ChargeClaimRow, IntentClaimRow, TerminalRow, TransitionRow,
        WebhookReceiptRow, amount, digest, payment_state, provider, required,
    },
    postgres_store_sql::WEBHOOK_COMPLETE_SQL,
    store::{
        AuthoritativePaymentObservation, ChargeClaim, ChargeClaimDisposition,
        DonationChargeClaimBinding, DonationIntentBinding, DonationIntentClaim,
        DonationIntentClaimDisposition, PaymentMethodBindingCompletion,
        PaymentMethodBindingCompletionDisposition, WebhookAuthenticationReceipt, WebhookClaim,
        WebhookClaimBinding,
    },
};

pub(super) struct IntentMaterial {
    pub(super) idempotency: ProviderIdempotency,
    pub(super) merchant_account_hmac: Sha256Digest,
    pub(super) donor_hmac: Sha256Digest,
    pub(super) donor_group_hmac: Sha256Digest,
    pub(super) key_version: String,
    pub(super) owner_request_digest: Sha256Digest,
}

pub(super) struct ChargeMaterial {
    pub(super) identity: ChargeProviderIdentity,
    pub(super) merchant_order_digest: Sha256Digest,
    pub(super) expected_provider_payment_digest: Sha256Digest,
}

pub(super) fn intent_material(
    key: &FixtureIdentityKey,
    binding: &DonationIntentBinding,
    amount: KrwAmount,
) -> Result<IntentMaterial, PaymentRuntimeError> {
    let identity = key.claim_identity(binding.provider, binding.request_id)?;
    let idempotency = key.intent_idempotency(binding.request_id, &binding.request_digest)?;
    let owner_request_digest = canonical_digest(&json!({
        "schemaVersion":"r6e-donation-intent-claim.v1","requestId":binding.request_id,
        "provider":binding.provider.as_str(),"merchantAccountHmac":identity.merchant_account_hmac,
        "merchantHmacKeyVersion":identity.key_version,"donorHmac":identity.donor_hmac,
        "donorGroupHmac":identity.donor_group_hmac,"donorHmacKeyVersion":identity.key_version,
        "offerVersionId":binding.offer_version_id,"offerDigest":binding.offer_digest,
        "tierId":binding.tier_id,"cadence":binding.cadence.as_str(),
        "consentReceiptDigest":binding.consent_receipt_digest,
        "expectedAmountWholeKrw":amount.whole_krw(),
        "providerIssueIdempotencyKeyHmac":idempotency.hmac,
        "providerIssueIdempotencyHmacKeyVersion":idempotency.key_version,
    }))?;
    Ok(IntentMaterial {
        idempotency,
        merchant_account_hmac: identity.merchant_account_hmac,
        donor_hmac: identity.donor_hmac,
        donor_group_hmac: identity.donor_group_hmac,
        key_version: identity.key_version,
        owner_request_digest,
    })
}

pub(super) fn map_intent_claim(
    row: IntentClaimRow,
    binding: &DonationIntentBinding,
    material: IntentMaterial,
) -> Result<DonationIntentClaimDisposition, PaymentRuntimeError> {
    if row.request_id != Some(binding.request_id)
        || row.provider_idempotency_hmac.as_deref() != Some(material.idempotency.hmac.as_str())
        || row.provider_idempotency_version.as_deref()
            != Some(material.idempotency.key_version.as_str())
    {
        return Err(PaymentRuntimeError::OwnerFunction);
    }
    match row.disposition.as_str() {
        "EXECUTE" => Ok(DonationIntentClaimDisposition::Execute(
            DonationIntentClaim {
                donation_intent_id: required(row.donation_intent_id)?,
                binding_id: required(row.binding_id)?,
                job_id: required(row.job_id)?,
                provider_idempotency_key: material.idempotency.value,
                amount: amount(row.amount_whole_krw)?,
                claim_digest: digest(row.claim_digest)?,
            },
        )),
        "REPLAY" => Ok(DonationIntentClaimDisposition::Replay(
            DonationQueuedReceipt {
                schema_version: "donation-intent-queued.v1",
                request_id: binding.request_id,
                job_id: required(row.job_id)?,
                status: "QUEUED",
                receipt_digest: digest(row.queued_receipt_digest)?,
            },
        )),
        "CONFLICT" => Ok(DonationIntentClaimDisposition::Conflict),
        "IN_PROGRESS" => Ok(DonationIntentClaimDisposition::InProgress),
        _ => Err(PaymentRuntimeError::OwnerFunction),
    }
}

pub(super) fn map_binding_receipt(
    row: BindingReceiptRow,
    request_id: uuid::Uuid,
    job_id: uuid::Uuid,
) -> Result<PaymentMethodBindingCompletionDisposition, PaymentRuntimeError> {
    match row.disposition.as_str() {
        "APPLIED" | "REPLAY"
            if row.request_id == Some(request_id)
                && row.job_id == Some(job_id)
                && row.status.as_deref() == Some("QUEUED") =>
        {
            Ok(PaymentMethodBindingCompletionDisposition::Committed(
                DonationQueuedReceipt {
                    schema_version: "donation-intent-queued.v1",
                    request_id,
                    job_id,
                    status: "QUEUED",
                    receipt_digest: digest(row.queued_receipt_digest)?,
                },
            ))
        }
        "CONFLICT" => Ok(PaymentMethodBindingCompletionDisposition::RejectedUnreferenced),
        _ => Err(PaymentRuntimeError::OwnerFunction),
    }
}

pub(super) fn map_charge_claim(
    row: ChargeClaimRow,
    binding: &DonationChargeClaimBinding<'_>,
    material: ChargeMaterial,
) -> Result<ChargeClaimDisposition, PaymentRuntimeError> {
    if row.disposition == "CONFLICT" {
        return Ok(ChargeClaimDisposition::Conflict);
    }
    if row.disposition == "REPLAY" {
        // 0041 does not return the terminal fixture authority or outcome
        // configuration digest. Reconstructing either from current process
        // config would accept an unbound replay, so this branch stays closed.
        return Err(PaymentRuntimeError::OwnerFunction);
    }
    if row.disposition == "IN_PROGRESS" && row.attempt_state.as_deref() != Some("PROVIDER_ACCEPTED")
    {
        return Ok(ChargeClaimDisposition::InProgress);
    }
    if !matches!(row.disposition.as_str(), "EXECUTE" | "IN_PROGRESS")
        || provider(&required(row.provider.clone())?)? != binding.provider
        || amount(row.amount_whole_krw)? != binding.amount
        || row.logical_charge_id != Some(binding.logical_charge_id)
        || digest(row.job_binding_digest.clone())? != *binding.job_payload_digest
        || row.provider_idempotency_hmac.as_deref()
            != Some(material.identity.idempotency.hmac.as_str())
        || row.provider_idempotency_version.as_deref()
            != Some(material.identity.idempotency.key_version.as_str())
        || row.merchant_order_hmac.as_deref()
            != Some(material.identity.merchant_order_hmac.as_str())
        || row.merchant_order_version.as_deref()
            != Some(material.identity.idempotency.key_version.as_str())
        || digest(row.merchant_order_digest.clone())? != material.merchant_order_digest
        || digest(row.expected_provider_payment_digest.clone())?
            != material.expected_provider_payment_digest
    {
        return Err(PaymentRuntimeError::OwnerFunction);
    }
    let policy = match required(row.credential_use_policy)?.as_str() {
        "SINGLE_CHARGE" => BillingCredentialUsePolicy::SingleCharge,
        "RECURRING" => BillingCredentialUsePolicy::Recurring,
        _ => return Err(PaymentRuntimeError::OwnerFunction),
    };
    let claim = ChargeClaim {
        logical_charge_id: binding.logical_charge_id,
        attempt_id: required(row.attempt_id)?,
        provider: binding.provider,
        provider_idempotency_key: material.identity.idempotency.value,
        merchant_order_id: material.identity.merchant_order_id,
        amount: binding.amount,
        credential_use_policy: policy,
        billing_key_handle: BillingKeyHandle {
            binding_id: required(row.binding_root_id)?,
            provider: binding.provider,
            use_policy: policy,
            secret_reference: required(row.billing_key_secret_reference)?,
            material_hmac: required(row.billing_key_hmac)?,
            hmac_key_version: KeyVersion::try_new(required(row.billing_key_version)?)?,
        },
        expected_provider_payment_id_sha256: material.expected_provider_payment_digest,
        claim_digest: digest(row.claim_digest)?,
    };
    Ok(
        if row.attempt_state.as_deref() == Some("PROVIDER_ACCEPTED") {
            ChargeClaimDisposition::ResumeAccepted(claim)
        } else {
            ChargeClaimDisposition::Execute(claim)
        },
    )
}

pub(super) fn applied_transition(
    row: TransitionRow,
    expected: &str,
) -> Result<(), PaymentRuntimeError> {
    match row.disposition.as_str() {
        "APPLIED" | "REPLAY" if row.state.as_deref() == Some(expected) => Ok(()),
        "CONFLICT" => Err(PaymentRuntimeError::Conflict),
        _ => Err(PaymentRuntimeError::OwnerFunction),
    }
}

pub(super) fn binding_completion_digest(
    value: &PaymentMethodBindingCompletion<'_>,
    material: &IntentMaterial,
) -> Result<Sha256Digest, PaymentRuntimeError> {
    canonical_digest(&json!({
        "schemaVersion":"r6e-payment-binding-completion.v1","requestId":value.intent.request_id,
        "requestDigest":material.owner_request_digest,"donationIntentId":value.claim.donation_intent_id,
        "bindingId":value.claim.binding_id,"claimDigest":value.claim.claim_digest,
        "provider":value.handle.provider.as_str(),"providerIssueIdempotencyKeyHmac":material.idempotency.hmac,
        "billingKeySecretReference":value.handle.secret_reference,"billingKeyHmac":value.handle.material_hmac,
        "billingKeyHmacKeyVersion":value.handle.hmac_key_version.as_str(),
        "credentialUsePolicy":value.handle.use_policy.as_str(),
        "providerRequestDigest":value.provider_receipt.request_sha256,
        "providerResponseDigest":value.provider_receipt.response_sha256,
        "providerHttpStatus":value.provider_receipt.http_status,
    }))
}

pub(super) fn intent_failure_digest(
    intent: &DonationIntentBinding,
    claim: &DonationIntentClaim,
    material: &IntentMaterial,
    safe_code: &str,
) -> Result<Sha256Digest, PaymentRuntimeError> {
    canonical_digest(&json!({
        "schemaVersion":"r6e-donation-intent-failure.v1","requestId":intent.request_id,
        "requestDigest":material.owner_request_digest,"donationIntentId":claim.donation_intent_id,
        "bindingId":claim.binding_id,"claimDigest":claim.claim_digest,"safeCode":safe_code,
    }))
}

pub(super) fn observation_completion_digest(
    attempt_id: uuid::Uuid,
    claim_digest: &Sha256Digest,
    observation: &AuthoritativePaymentObservation,
    producer: &str,
) -> Result<Sha256Digest, PaymentRuntimeError> {
    canonical_digest(&json!({
        "schemaVersion":"r6e-payment-observation-completion.v1","attemptId":attempt_id,
        "claimDigest":claim_digest,"producerOperationId":producer,"provider":observation.provider.as_str(),
        "providerPaymentIdDigest":observation.provider_payment_id_sha256,
        "merchantOrderIdDigest":observation.merchant_order_id_sha256,
        "amountWholeKrw":observation.amount.whole_krw(),"paymentState":payment_state(observation.state),
        "providerObservedAt":postgres_timestamp(observation.provider_observed_at_unix)?,
        "transportRequestDigest":observation.transport_request_sha256,
        "transportResponseDigest":observation.transport_response_sha256,
        "providerFetchDigest":observation.provider_fetch_digest,"fixtureAuthority":observation.fixture_authority,
        "testPaymentOutcomeConfigDigest":observation.test_payment_outcome_config_digest,
    }))
}

pub(super) async fn terminal_query(
    sql: &'static str,
    pool: &PgPool,
    claim: &ChargeClaim,
    observation: &AuthoritativePaymentObservation,
    completion: &Sha256Digest,
) -> Result<super::store::ChargeTerminalReceipt, PaymentRuntimeError> {
    let observed_at = OffsetDateTime::from_unix_timestamp(observation.provider_observed_at_unix)
        .map_err(|_| PaymentRuntimeError::InvalidRequest)?;
    let row = sqlx::query_as::<_, TerminalRow>(sql)
        .bind(claim.attempt_id)
        .bind(claim.claim_digest.as_str())
        .bind(observation.provider.as_str())
        .bind(observation.provider_payment_id_sha256.as_str())
        .bind(observation.merchant_order_id_sha256.as_str())
        .bind(observation.amount.whole_krw())
        .bind(payment_state(observation.state))
        .bind(observed_at)
        .bind(observation.transport_request_sha256.as_str())
        .bind(observation.transport_response_sha256.as_str())
        .bind(observation.provider_fetch_digest.as_str())
        .bind(observation.fixture_authority)
        .bind(observation.test_payment_outcome_config_digest.as_str())
        .bind(completion.as_str())
        .fetch_one(pool)
        .await
        .map_err(database)?;
    row.into_receipt()
}

pub(super) async fn webhook_terminal_query(
    pool: &PgPool,
    binding: &WebhookClaimBinding,
    claim: &WebhookClaim,
    observation: &AuthoritativePaymentObservation,
    completion: &Sha256Digest,
) -> Result<WebhookReceiptRow, PaymentRuntimeError> {
    let observed_at = OffsetDateTime::from_unix_timestamp(observation.provider_observed_at_unix)
        .map_err(|_| PaymentRuntimeError::InvalidRequest)?;
    sqlx::query_as::<_, WebhookReceiptRow>(WEBHOOK_COMPLETE_SQL)
        .bind(binding.provider.as_str())
        .bind(binding.event_identity_sha256.as_str())
        .bind(claim.claim_id)
        .bind(claim.claim_digest.as_str())
        .bind(observation.provider_payment_id_sha256.as_str())
        .bind(observation.merchant_order_id_sha256.as_str())
        .bind(observation.attempt_id)
        .bind(observation.amount.whole_krw())
        .bind(payment_state(observation.state))
        .bind(observed_at)
        .bind(observation.transport_request_sha256.as_str())
        .bind(observation.transport_response_sha256.as_str())
        .bind(observation.provider_fetch_digest.as_str())
        .bind(observation.fixture_authority)
        .bind(observation.test_payment_outcome_config_digest.as_str())
        .bind(completion.as_str())
        .fetch_one(pool)
        .await
        .map_err(database)
}

pub(super) fn map_webhook_receipt(
    row: WebhookReceiptRow,
    binding: &WebhookClaimBinding,
) -> Result<WebhookProcessingReceipt, PaymentRuntimeError> {
    if !matches!(row.disposition.as_str(), "APPLIED" | "REPLAY")
        || provider(&required(row.provider)?)? != binding.provider
        || digest(row.event_identity_digest)? != binding.event_identity_sha256
    {
        return Err(if row.disposition == "CONFLICT" {
            PaymentRuntimeError::Conflict
        } else {
            PaymentRuntimeError::OwnerFunction
        });
    }
    Ok(WebhookProcessingReceipt {
        schema_version: "provider-webhook-acceptance.v1",
        provider: binding.provider,
        event_identity_sha256: binding.event_identity_sha256.clone(),
        disposition: WebhookDisposition::Applied,
        receipt_digest: digest(row.receipt_digest)?,
    })
}

pub(super) fn webhook_auth(
    value: &WebhookAuthenticationReceipt,
) -> (&'static str, Option<&str>, Option<&str>) {
    match value {
        WebhookAuthenticationReceipt::Verified {
            signature_sha256,
            signed_payload_sha256,
        } => (
            "VERIFIED",
            Some(signature_sha256.as_str()),
            Some(signed_payload_sha256.as_str()),
        ),
        WebhookAuthenticationReceipt::NotAvailableFetchRequired => {
            ("NOT_AVAILABLE_FETCH_REQUIRED", None, None)
        }
    }
}

pub(super) fn webhook_claim_digest(
    binding: &WebhookClaimBinding,
    auth: &str,
    signature: Option<&str>,
    signed_payload: Option<&str>,
) -> Result<Sha256Digest, PaymentRuntimeError> {
    canonical_digest(&json!({
        "schemaVersion":"r6e-provider-webhook-claim.v1","provider":binding.provider.as_str(),
        "eventIdentityDigest":binding.event_identity_sha256,"locatorKind":binding.locator_kind.as_str(),
        "locatorDigest":binding.locator_sha256,"bodyDigest":binding.body_sha256,
        "hintDigest":binding.hint_sha256,"authenticationState":auth,
        "signatureDigest":signature,"signedPayloadDigest":signed_payload,
    }))
}

pub(super) fn canonical_digest(value: &Value) -> Result<Sha256Digest, PaymentRuntimeError> {
    canonical_json(value)
        .map(|bytes| Sha256Digest::of(&bytes))
        .map_err(|_| PaymentRuntimeError::InvalidRequest)
}

pub(super) fn opaque_digest(domain: &[u8], value: &str) -> Sha256Digest {
    let mut bytes = Vec::with_capacity(domain.len() + value.len());
    bytes.extend_from_slice(domain);
    bytes.extend_from_slice(value.as_bytes());
    Sha256Digest::of(&bytes)
}

pub(super) fn postgres_timestamp(unix: i64) -> Result<String, PaymentRuntimeError> {
    let value = OffsetDateTime::from_unix_timestamp(unix)
        .map_err(|_| PaymentRuntimeError::InvalidRequest)?
        .format(&Rfc3339)
        .map_err(|_| PaymentRuntimeError::InvalidRequest)?;
    Ok(value
        .strip_suffix('Z')
        .map_or(value.clone(), |prefix| format!("{prefix}+00:00")))
}

pub(super) fn database(_error: sqlx::Error) -> PaymentRuntimeError {
    PaymentRuntimeError::OwnerFunction
}
