use super::*;

#[path = "discount_validation.rs"]
mod discount_validation;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub(super) enum EconomicsSourceResolutionV1 {
    Append,
    Existing,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub(super) enum DiscountState {
    Active,
    Withdrawn,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum DiscountReason {
    Contracted,
    Nonprofit,
    Volume,
    ServiceCredit,
    Promotional,
    Correction,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsDiscountAppendV1 {
    pub(super) deployment_id: Uuid,
    pub(super) organization_id: Uuid,
    pub(super) contract_period_id: Uuid,
    pub(super) contract_id: Uuid,
    pub(super) sku: CommercialSku,
    pub(super) tariff_version_id: Uuid,
    pub(super) tariff_record_digest: Sha256Digest,
    pub(super) accounting_timezone: String,
    pub(super) accounting_policy_digest: Sha256Digest,
    root_discount_id: RequiredNullable<Uuid>,
    revision: i64,
    pub(super) state: DiscountState,
    supersedes_discount_id: RequiredNullable<Uuid>,
    applies_workspace_base: bool,
    applies_active_contributor_block: bool,
    applies_processing_credit_overage: bool,
    applies_storage_gb_month_overage: bool,
    applies_api_record_unit_overage: bool,
    applies_sla_add_on: bool,
    basis_points: RequiredNullable<i32>,
    reason_code: DiscountReason,
    pub(super) effective_from: DateText,
    pub(super) effective_until: DateText,
    required_variable_gross_margin_basis_points: i32,
    projected_margin_after_discount_basis_points: i32,
    margin_assumption_digest: Sha256Digest,
    pub(super) expected_resulting_discount_set_digest: Sha256Digest,
    undiscounted_p75_revenue_amount: Decimal,
    discounted_p75_revenue_amount: Decimal,
    p75_variable_cost_amount: Decimal,
    cost_evidence_digest: Sha256Digest,
    margin_formula_digest: Sha256Digest,
    margin_evidence_as_of: DateTimeText,
    oversight_reason: RequiredNullable<String>,
    source_receipt_digest: Sha256Digest,
    pub(super) signature_digest: Sha256Digest,
    pub(super) expected_record_digest: Sha256Digest,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(in super::super) struct EconomicsDiscountSourceImportV1 {
    pub(super) resolution: EconomicsSourceResolutionV1,
    pub(super) existing_discount_id: RequiredNullable<Uuid>,
    existing_discount_revision: RequiredNullable<i64>,
    pub(super) existing_discount_digest: RequiredNullable<Sha256Digest>,
    pub(super) append_value: RequiredNullable<EconomicsDiscountAppendV1>,
    evidence_segment_id: Uuid,
    evidence_segment_digest: Sha256Digest,
    source_signature_digest: Sha256Digest,
    expected_head_id: RequiredNullable<Uuid>,
    expected_head_revision: RequiredNullable<i64>,
    expected_head_digest: RequiredNullable<Sha256Digest>,
}
