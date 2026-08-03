use super::tariff::{CommercialSku, TariffStage};
use super::*;

#[path = "contract_validation.rs"]
mod contract_validation;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum CommercialPeriodFactEffect {
    Original,
    Replacement,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum CommercialContractStatus {
    Active,
    Suspended,
    Ended,
    Cancelled,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum CommercialProvisioningState {
    Unprovisioned,
    Provisioned,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum SlaSelectionState {
    UnavailableNotSold,
    AvailableNotSelected,
    Selected,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum OfferCapabilityCode {
    PublicWeb,
    VerifiedEmail,
    ApiExport,
    SignedWebhook,
    DailyDigest,
    WeeklyDigest,
    Sms,
    Telegram,
    Whatsapp,
    Line,
    Kakao,
    Voice,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum OfferCapabilityState {
    IncludedRequired,
    NotOffered,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum OfferQuotaKind {
    NotMetered,
    ApiRecordUnit,
    DeliveryAttempt,
    DigestDispatch,
    WebhookDispatch,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum OfferOveragePolicy {
    DeclaredTariffOverage,
    HardLimitNoOverage,
    NotApplicable,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct EconomicsOfferCapabilityImportV1 {
    capability_ordinal: i16,
    capability_code: OfferCapabilityCode,
    offer_state: OfferCapabilityState,
    quota_kind: OfferQuotaKind,
    included_quantity: RequiredNullable<Decimal>,
    overage_policy: OfferOveragePolicy,
    overage_unit_price: RequiredNullable<Decimal>,
    activation_policy_digest: RequiredNullable<Sha256Digest>,
    consent_policy_digest: RequiredNullable<Sha256Digest>,
    cost_policy_digest: RequiredNullable<Sha256Digest>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsContractImportV1 {
    deployment_id: Uuid,
    organization_id: Uuid,
    contract_id: Uuid,
    root_contract_period_id: Uuid,
    revision: i64,
    fact_effect: CommercialPeriodFactEffect,
    supersedes_contract_period_id: RequiredNullable<Uuid>,
    predecessor_record_digest: RequiredNullable<Sha256Digest>,
    contract_reference_hmac: Sha256Digest,
    contract_reference_hmac_key_version: String,
    period_start: DateText,
    period_end: DateText,
    sku: CommercialSku,
    tariff_version_id: Uuid,
    tariff_record_digest: Sha256Digest,
    qualification_receipt_id: Uuid,
    qualification_episode_id: Uuid,
    qualification_receipt_digest: Sha256Digest,
    offer_contract_binding_digest: Sha256Digest,
    offer_profile_id: Uuid,
    offer_profile_version: i64,
    offer_profile_digest: Sha256Digest,
    offer_capability_set_digest: Sha256Digest,
    offer_quota_set_digest: Sha256Digest,
    offer_overage_policy_set_digest: Sha256Digest,
    offer_service_credit_policy_digest: Sha256Digest,
    offer_effective_from: DateTimeText,
    offer_effective_until: DateTimeText,
    offer_source_receipt_digest: Sha256Digest,
    offer_signature_digest: Sha256Digest,
    currency: String,
    accounting_timezone: String,
    accounting_policy_digest: Sha256Digest,
    #[serde(with = "rust_decimal::serde::str")]
    binding_committed_amount: Decimal,
    commitment_policy_digest: Sha256Digest,
    status: CommercialContractStatus,
    stage: TariffStage,
    provisioning_state: CommercialProvisioningState,
    sla_add_on_selected: bool,
    sla_selection_state: SlaSelectionState,
    sla_policy_version: RequiredNullable<String>,
    sla_policy_digest: RequiredNullable<Sha256Digest>,
    sla_target_availability_ratio: RequiredNullable<Decimal>,
    sla_capability_set_digest: RequiredNullable<Sha256Digest>,
    sla_exclusion_schedule_digest: RequiredNullable<Sha256Digest>,
    sla_service_credit_schedule_digest: RequiredNullable<Sha256Digest>,
    sla_measurement_policy_digest: RequiredNullable<Sha256Digest>,
    signed_at: DateTimeText,
    provisioned_at: RequiredNullable<DateTimeText>,
    state_effective_at: DateTimeText,
    deployment_configuration_digest: Sha256Digest,
    authority_reference_digest: Sha256Digest,
    source_receipt_digest: Sha256Digest,
    signature_digest: Sha256Digest,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_revision: RequiredNullable<i64>,
    expected_head_digest: RequiredNullable<Sha256Digest>,
    collection_failure_task_id: RequiredNullable<Uuid>,
    collection_failure_task_version: RequiredNullable<i64>,
    collection_failure_task_digest: RequiredNullable<Sha256Digest>,
    capabilities: Vec<EconomicsOfferCapabilityImportV1>,
}
