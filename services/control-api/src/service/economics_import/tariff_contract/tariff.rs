use rust_decimal::RoundingStrategy;

use super::*;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub(super) enum CommercialSku {
    EvidenceWorkspaceOrganizationV1,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub(super) enum TariffStage {
    Pilot,
    GeneralAvailability,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum SlaOfferState {
    UnconfiguredNotSold,
    ConfiguredForSale,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
// PROVISIONAL_0041_ABI: re-run the composite field-set audit after FINAL READY.
pub(in super::super) struct EconomicsTariffImportV1 {
    deployment_id: Uuid,
    sku: CommercialSku,
    currency: String,
    accounting_timezone: String,
    accounting_policy_digest: Sha256Digest,
    effective_from: DateText,
    effective_until: DateText,
    #[serde(with = "rust_decimal::serde::str")]
    workspace_base_amount: Decimal,
    included_active_contributors: i32,
    active_contributor_block_size: i32,
    #[serde(with = "rust_decimal::serde::str")]
    active_contributor_block_amount: Decimal,
    #[serde(with = "rust_decimal::serde::str")]
    included_processing_credits: Decimal,
    #[serde(with = "rust_decimal::serde::str")]
    processing_credit_overage_amount: Decimal,
    #[serde(with = "rust_decimal::serde::str")]
    included_storage_gb_month: Decimal,
    #[serde(with = "rust_decimal::serde::str")]
    storage_gb_month_overage_amount: Decimal,
    #[serde(with = "rust_decimal::serde::str")]
    included_api_record_units: Decimal,
    #[serde(with = "rust_decimal::serde::str")]
    api_record_unit_overage_amount: Decimal,
    sla_add_on_amount: RequiredNullable<Decimal>,
    sla_offer_state: SlaOfferState,
    sla_policy_version: RequiredNullable<String>,
    sla_policy_digest: RequiredNullable<Sha256Digest>,
    sla_target_availability_ratio: RequiredNullable<Decimal>,
    sla_capability_set_digest: RequiredNullable<Sha256Digest>,
    sla_exclusion_schedule_digest: RequiredNullable<Sha256Digest>,
    sla_service_credit_schedule_digest: RequiredNullable<Sha256Digest>,
    sla_measurement_policy_digest: RequiredNullable<Sha256Digest>,
    sla_policy_source_receipt_digest: RequiredNullable<Sha256Digest>,
    sla_policy_signature_digest: RequiredNullable<Sha256Digest>,
    included_signed_webhook_deliveries: i64,
    included_digest_deliveries: i64,
    expected_required_variable_gross_margin_basis_points: i32,
    expected_projected_p75_variable_gross_margin_basis_points: i32,
    p75_assumption_digest: Sha256Digest,
    cost_allocation_period_id: Uuid,
    cost_allocation_row_kind: String,
    cost_allocation_record_digest: Sha256Digest,
    cost_allocation_set_digest: Sha256Digest,
    cost_allocation_close_receipt_digest: Sha256Digest,
    #[serde(with = "rust_decimal::serde::str")]
    cost_capture_coverage: Decimal,
    #[serde(with = "rust_decimal::serde::str")]
    direct_cost_coverage: Decimal,
    #[serde(with = "rust_decimal::serde::str")]
    total_cost_coverage: Decimal,
    #[serde(with = "rust_decimal::serde::str")]
    p75_revenue_amount: Decimal,
    #[serde(with = "rust_decimal::serde::str")]
    p75_variable_cost_amount: Decimal,
    margin_formula_digest: Sha256Digest,
    margin_evidence_as_of: DateTimeText,
    margin_exception_reason: RequiredNullable<String>,
    component_set_digest: Sha256Digest,
    pricing_policy_digest: Sha256Digest,
    tax_policy_digest: Sha256Digest,
    source_receipt_digest: Sha256Digest,
    signature_digest: Sha256Digest,
    expected_cost_head_id: Uuid,
    expected_cost_head_version: i64,
    expected_cost_head_digest: Sha256Digest,
    expected_current_tariff_id: RequiredNullable<Uuid>,
    expected_current_tariff_digest: RequiredNullable<Sha256Digest>,
}

impl EconomicsTariffImportV1 {
    pub(in super::super) fn validate(&self) -> Result<(), ServiceError> {
        if !self.identity_and_component_shape()
            || !self.sla_shape()
            || !self.margin_shape()
            || !self.head_fence_shape()
        {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(())
    }

    fn identity_and_component_shape(&self) -> bool {
        !self.deployment_id.is_nil()
            && self.currency == "KRW"
            && text_len(&self.accounting_timezone, 1, 63)
            && self.effective_from < self.effective_until
            && self.workspace_base_amount > Decimal::ZERO
            && self.included_active_contributors == 10
            && self.active_contributor_block_size == 10
            && self.active_contributor_block_amount >= Decimal::ZERO
            && self.included_processing_credits >= Decimal::ZERO
            && self.processing_credit_overage_amount >= Decimal::ZERO
            && self.included_storage_gb_month >= Decimal::ZERO
            && self.storage_gb_month_overage_amount >= Decimal::ZERO
            && self.included_api_record_units >= Decimal::ZERO
            && self.api_record_unit_overage_amount >= Decimal::ZERO
            && self.included_signed_webhook_deliveries >= 0
            && self.included_digest_deliveries >= 0
            && matches!(self.sku, CommercialSku::EvidenceWorkspaceOrganizationV1)
            && matches!(
                self.expected_required_variable_gross_margin_basis_points,
                6_000 | 7_000
            )
    }

    fn sla_shape(&self) -> bool {
        let all_absent = self.sla_add_on_amount.as_option().is_none()
            && self.sla_policy_version.as_option().is_none()
            && self.sla_policy_digest.as_option().is_none()
            && self.sla_target_availability_ratio.as_option().is_none()
            && self.sla_capability_set_digest.as_option().is_none()
            && self.sla_exclusion_schedule_digest.as_option().is_none()
            && self
                .sla_service_credit_schedule_digest
                .as_option()
                .is_none()
            && self.sla_measurement_policy_digest.as_option().is_none()
            && self.sla_policy_source_receipt_digest.as_option().is_none()
            && self.sla_policy_signature_digest.as_option().is_none();
        match self.sla_offer_state {
            SlaOfferState::UnconfiguredNotSold => all_absent,
            SlaOfferState::ConfiguredForSale => {
                self.sla_add_on_amount
                    .as_option()
                    .as_ref()
                    .is_some_and(|value| *value > Decimal::ZERO)
                    && self
                        .sla_policy_version
                        .as_option()
                        .as_deref()
                        .is_some_and(|value| text_len(value, 1, 100))
                    && self
                        .sla_target_availability_ratio
                        .as_option()
                        .as_ref()
                        .is_some_and(|value| valid_ratio(*value))
                    && self.sla_policy_digest.as_option().is_some()
                    && self.sla_capability_set_digest.as_option().is_some()
                    && self.sla_exclusion_schedule_digest.as_option().is_some()
                    && self
                        .sla_service_credit_schedule_digest
                        .as_option()
                        .is_some()
                    && self.sla_measurement_policy_digest.as_option().is_some()
                    && self.sla_policy_source_receipt_digest.as_option().is_some()
                    && self.sla_policy_signature_digest.as_option().is_some()
            }
        }
    }

    fn margin_shape(&self) -> bool {
        if !(-100_000..=10_000)
            .contains(&self.expected_projected_p75_variable_gross_margin_basis_points)
            || self.cost_allocation_row_kind != "PERIOD"
            || !(Decimal::new(99, 2)..=Decimal::ONE).contains(&self.cost_capture_coverage)
            || self.direct_cost_coverage != Decimal::ONE
            || !(Decimal::new(95, 2)..=Decimal::ONE).contains(&self.total_cost_coverage)
            || self.p75_revenue_amount <= Decimal::ZERO
            || self.p75_variable_cost_amount < Decimal::ZERO
            || !self.margin_arithmetic_matches()
        {
            return false;
        }
        self.expected_projected_p75_variable_gross_margin_basis_points
            >= self.expected_required_variable_gross_margin_basis_points
            && self.margin_exception_reason.as_option().is_none()
    }

    fn margin_arithmetic_matches(&self) -> bool {
        self.p75_revenue_amount
            .checked_sub(self.p75_variable_cost_amount)
            .and_then(|value| value.checked_div(self.p75_revenue_amount))
            .and_then(|value| value.checked_mul(Decimal::from(10_000)))
            .map(|value| value.round_dp_with_strategy(0, RoundingStrategy::MidpointNearestEven))
            == Some(Decimal::from(
                self.expected_projected_p75_variable_gross_margin_basis_points,
            ))
    }

    fn head_fence_shape(&self) -> bool {
        let current_tariff = match (
            self.expected_current_tariff_id.as_option().as_ref(),
            self.expected_current_tariff_digest.as_option().as_ref(),
        ) {
            (None, None) => true,
            (Some(id), Some(_)) => !id.is_nil(),
            _ => false,
        };
        !self.cost_allocation_period_id.is_nil()
            && !self.expected_cost_head_id.is_nil()
            && self.expected_cost_head_version > 0
            && self.expected_cost_head_id == self.cost_allocation_period_id
            && self.expected_cost_head_digest == self.cost_allocation_record_digest
            && current_tariff
            && self.required_digests_are_bound()
    }

    fn required_digests_are_bound(&self) -> bool {
        let values = [
            &self.accounting_policy_digest,
            &self.p75_assumption_digest,
            &self.cost_allocation_set_digest,
            &self.cost_allocation_close_receipt_digest,
            &self.margin_formula_digest,
            &self.component_set_digest,
            &self.pricing_policy_digest,
            &self.tax_policy_digest,
            &self.source_receipt_digest,
            &self.signature_digest,
        ];
        values.iter().all(|digest| digest.as_str().len() == 64)
            && !self.margin_evidence_as_of.as_str().is_empty()
    }
}

fn text_len(value: &str, minimum: usize, maximum: usize) -> bool {
    (minimum..=maximum).contains(&value.trim().chars().count())
}

fn valid_ratio(value: Decimal) -> bool {
    value > Decimal::ZERO && value <= Decimal::ONE
}
