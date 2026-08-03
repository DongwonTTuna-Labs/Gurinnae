use rust_decimal::RoundingStrategy;

use super::*;

impl EconomicsCostPeriodImportV1 {
    fn validate(&self) -> Result<(), ServiceError> {
        if self.period_revision_id.is_nil()
            || self.deployment_id.is_nil()
            || self.close_receipt_id.is_nil()
            || !valid_optional_uuid(&self.supersedes_period_revision_id)
            || !valid_optional_uuid(&self.expected_head_id)
            || !valid_timezone(&self.accounting_timezone)
            || !valid_currency(&self.currency)
            || self.period_start.as_str() >= self.period_end.as_str()
            || self.period_version < 1
            || self.schedule_revision < 1
            || self.expected_captured_cost_count < 0
            || self
                .expected_cost_count
                .as_option()
                .as_ref()
                .is_some_and(|count| *count < 0)
            || !self.valid_amounts()
            || !self.valid_capture_state()
            || !self.valid_claim_state()
            || !self.valid_revision_fence()
        {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(())
    }

    fn valid_revision_fence(&self) -> bool {
        if self.period_version == 1 {
            self.supersedes_period_revision_id.is_none()
                && head_fence_is_absent(
                    &self.expected_head_id,
                    &self.expected_head_version,
                    &self.expected_head_digest,
                )
        } else {
            matches!(
                (
                    self.supersedes_period_revision_id.as_option().as_ref(),
                    self.expected_head_id.as_option().as_ref(),
                    self.expected_head_version.as_option().as_ref(),
                    self.expected_head_digest.as_option().as_ref(),
                ),
                (Some(supersedes), Some(head_id), Some(head_version), Some(_))
                    if supersedes == head_id
                        && *supersedes != self.period_revision_id
                        && *head_version == self.period_version - 1
            )
        }
    }

    fn valid_amounts(&self) -> bool {
        let amounts = [
            self.expected_direct_eligible_amount,
            self.expected_direct_allocated_amount,
            self.expected_captured_cost_amount,
            self.expected_attributed_cost_amount,
            self.expected_unallocated_amount,
        ];
        amounts
            .iter()
            .all(|value| valid_amount(*value) && *value >= Decimal::ZERO)
            && self.expected_direct_allocated_amount <= self.expected_direct_eligible_amount
            && self
                .expected_attributed_cost_amount
                .checked_add(self.expected_unallocated_amount)
                == Some(self.expected_captured_cost_amount)
            && valid_ratio(self.expected_direct_coverage)
            && valid_ratio(self.expected_total_coverage)
            && coverage_ratio(
                self.expected_direct_allocated_amount,
                self.expected_direct_eligible_amount,
            ) == Some(self.expected_direct_coverage)
            && coverage_ratio(
                self.expected_attributed_cost_amount,
                self.expected_captured_cost_amount,
            ) == Some(self.expected_total_coverage)
    }

    fn valid_capture_state(&self) -> bool {
        match self.expected_cost_capture_state {
            CostCaptureState::Measured => {
                matches!(
                    (
                        self.expected_cost_count.as_option().as_ref(),
                        self.expected_cost_capture_coverage.as_option().as_ref(),
                    ),
                    (Some(expected), Some(coverage))
                        if *expected >= self.expected_captured_cost_count
                            && valid_ratio(*coverage)
                            && count_coverage(self.expected_captured_cost_count, *expected)
                                == Some(*coverage)
                ) && self.unknown_cost_scope_digest.is_none()
            }
            CostCaptureState::Unknown => {
                self.expected_cost_count.is_none()
                    && self.expected_cost_capture_coverage.is_none()
                    && self.unknown_cost_scope_digest.is_some()
            }
        }
    }

    fn valid_claim_state(&self) -> bool {
        let capture = nullable_value(&self.expected_cost_capture_coverage);
        match self.expected_claim_state {
            CostClaimState::NoActivity => {
                self.expected_captured_cost_count == 0
                    && self.expected_cost_count.as_option() == &Some(0)
                    && self.expected_captured_cost_amount == Decimal::ZERO
                    && self.expected_direct_eligible_amount == Decimal::ZERO
                    && self.expected_cost_capture_state == CostCaptureState::Measured
                    && capture == Some(Decimal::ONE)
                    && self.expected_direct_coverage == Decimal::ONE
                    && self.expected_total_coverage == Decimal::ONE
                    && self.incomplete_reason_set_digest.is_none()
                    && self.unknown_cost_scope_digest.is_none()
            }
            CostClaimState::Eligible => {
                self.expected_captured_cost_amount > Decimal::ZERO
                    && self.expected_cost_capture_state == CostCaptureState::Measured
                    && capture.is_some_and(|value| value >= Decimal::new(99, 2))
                    && self.expected_direct_coverage == Decimal::ONE
                    && self.expected_total_coverage >= Decimal::new(95, 2)
                    && self.incomplete_reason_set_digest.is_none()
                    && self.unknown_cost_scope_digest.is_none()
            }
            CostClaimState::Incomplete => {
                self.incomplete_reason_set_digest.is_some()
                    && (self.expected_cost_capture_state == CostCaptureState::Unknown
                        || capture.is_some_and(|value| value < Decimal::new(99, 2))
                        || self.expected_direct_coverage < Decimal::ONE
                        || self.expected_total_coverage < Decimal::new(95, 2))
            }
        }
    }
}

impl EconomicsCostLineImportV1 {
    fn validate(&self) -> Result<(), ServiceError> {
        let optional_ids = [
            nullable_value(&self.fx_rate_fact_id),
            nullable_value(&self.job_id),
            nullable_value(&self.agent_run_id),
            nullable_value(&self.case_id),
            nullable_value(&self.organization_id),
            nullable_value(&self.outcome_fact_id),
            nullable_value(&self.acquisition_source_receipt_id),
        ];
        if self.line_sequence < 1
            || self.source_cost_event_id.is_nil()
            || optional_ids.iter().flatten().any(Uuid::is_nil)
            || !valid_currency(&self.source_currency)
            || self.allocation_rule_version < 1
            || self.schedule_revision < 1
            || !valid_amount(self.source_amount)
            || !valid_amount(self.reporting_source_amount)
            || !valid_amount(self.rounding_adjustment)
            || !valid_amount(self.allocated_amount)
            || self.source_amount < Decimal::ZERO
            || self.reporting_source_amount < Decimal::ZERO
            || self.allocated_amount < Decimal::ZERO
            || self.rounding_adjustment.abs() > Decimal::new(1, 6)
            || !self.valid_target()
            || !self.valid_acquisition()
            || !self.valid_driver()
        {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(())
    }

    fn valid_target(&self) -> bool {
        let count = [
            nullable_value(&self.job_id),
            nullable_value(&self.agent_run_id),
            nullable_value(&self.case_id),
            nullable_value(&self.organization_id),
            nullable_value(&self.outcome_fact_id),
        ]
        .into_iter()
        .filter(Option::is_some)
        .count();
        match self.target_kind {
            CostTargetKind::Job => count == 1 && self.job_id.is_some(),
            CostTargetKind::AgentRun => count == 1 && self.agent_run_id.is_some(),
            CostTargetKind::Case => count == 1 && self.case_id.is_some(),
            CostTargetKind::Organization => count == 1 && self.organization_id.is_some(),
            CostTargetKind::OutcomeFact => count == 1 && self.outcome_fact_id.is_some(),
            CostTargetKind::Unallocated => count == 0,
        }
    }

    fn valid_acquisition(&self) -> bool {
        match (
            self.cost_category,
            nullable_value(&self.acquisition_attribution_state),
        ) {
            (
                CostCategory::SalesCustomerAcquisition,
                Some(AcquisitionAttributionState::Attributed),
            ) => {
                self.target_kind == CostTargetKind::Organization
                    && self.organization_id.is_some()
                    && self.acquisition_campaign_digest.is_some()
                    && self.acquisition_source_receipt_id.is_some()
                    && self.acquisition_source_receipt_digest.is_some()
                    && self.unattributed_acquisition_pool_digest.is_none()
            }
            (
                CostCategory::SalesCustomerAcquisition,
                Some(AcquisitionAttributionState::Unattributed),
            ) => {
                self.allocation_kind == CostAllocationKind::Unallocated
                    && self.target_kind == CostTargetKind::Unallocated
                    && self.organization_id.is_none()
                    && self.acquisition_source_receipt_id.is_none()
                    && self.acquisition_source_receipt_digest.is_none()
                    && self.unattributed_acquisition_pool_digest.is_some()
            }
            (CostCategory::SalesCustomerAcquisition, None) => false,
            (_, state) => {
                self.acquisition_campaign_digest.is_none()
                    && self.acquisition_source_receipt_id.is_none()
                    && self.acquisition_source_receipt_digest.is_none()
                    && state.is_none()
                    && self.unattributed_acquisition_pool_digest.is_none()
            }
        }
    }

    fn valid_driver(&self) -> bool {
        match self.allocation_kind {
            CostAllocationKind::Direct => {
                self.target_kind != CostTargetKind::Unallocated
                    && self.driver_kind == CostDriverKind::DirectIdentity
                    && self.driver_quantity.is_none()
                    && self.driver_total_quantity.is_none()
                    && self.allocation_ratio.is_none()
                    && self.rounding_adjustment == Decimal::ZERO
                    && self.allocated_amount == self.reporting_source_amount
            }
            CostAllocationKind::Shared => {
                let Some((quantity, total, ratio)) = self.driver_values() else {
                    return false;
                };
                self.target_kind != CostTargetKind::Unallocated
                    && !matches!(
                        self.driver_kind,
                        CostDriverKind::DirectIdentity | CostDriverKind::None
                    )
                    && valid_amount(quantity)
                    && valid_amount(total)
                    && quantity > Decimal::ZERO
                    && total >= quantity
                    && valid_ratio(ratio)
                    && ratio > Decimal::ZERO
                    && quantity
                        .checked_div(total)
                        .map(|value| round_even(value, 12))
                        == Some(ratio)
                    && self
                        .reporting_source_amount
                        .checked_mul(ratio)
                        .map(|value| round_even(value, 6))
                        .and_then(|value| value.checked_add(self.rounding_adjustment))
                        == Some(self.allocated_amount)
            }
            CostAllocationKind::Unallocated => {
                self.target_kind == CostTargetKind::Unallocated
                    && self.driver_kind == CostDriverKind::None
                    && self.driver_quantity.is_none()
                    && self.driver_total_quantity.is_none()
                    && self.allocation_ratio.is_none()
                    && self.rounding_adjustment == Decimal::ZERO
                    && self.allocated_amount > Decimal::ZERO
                    && self.allocated_amount <= self.reporting_source_amount
            }
        }
    }

    fn driver_values(&self) -> Option<(Decimal, Decimal, Decimal)> {
        Some((
            nullable_value(&self.driver_quantity)?,
            nullable_value(&self.driver_total_quantity)?,
            nullable_value(&self.allocation_ratio)?,
        ))
    }
}

impl EconomicsCostCloseImportV1 {
    pub(in super::super::super) fn validate(&self) -> Result<(), ServiceError> {
        self.period.validate()?;
        if self.lines.is_empty()
            || self.lines.len() > i64::MAX as usize
            || self.lines.iter().any(|line| line.validate().is_err())
        {
            return Err(ServiceError::InvalidRequest);
        }
        let actual_sequences = self
            .lines
            .iter()
            .map(|line| line.line_sequence)
            .collect::<BTreeSet<_>>();
        let expected_sequences = (1..=self.lines.len() as i64).collect::<BTreeSet<_>>();
        if actual_sequences != expected_sequences
            || self.lines.iter().any(|line| {
                line.schedule_revision != self.period.schedule_revision
                    || line.schedule_digest != self.period.schedule_digest
                    || !super::fx_validation::valid_fx_binding(
                        line,
                        &self.period.currency,
                        &self.fx_rates,
                    )
            })
            || self
                .fx_rates
                .iter()
                .any(|source| source.validate().is_err())
        {
            return Err(ServiceError::InvalidRequest);
        }
        Ok(())
    }
}

fn head_fence_is_absent(
    id: &RequiredNullable<Uuid>,
    version: &RequiredNullable<i64>,
    digest: &RequiredNullable<Sha256Digest>,
) -> bool {
    id.is_none() && version.is_none() && digest.is_none()
}

fn valid_optional_uuid(value: &RequiredNullable<Uuid>) -> bool {
    value.as_option().is_none_or(|id| !id.is_nil())
}

fn nullable_value<T: Copy>(value: &RequiredNullable<T>) -> Option<T> {
    value.as_option().as_ref().copied()
}

fn valid_timezone(value: &str) -> bool {
    if value == "UTC" {
        return true;
    }
    (1..=64).contains(&value.len())
        && value
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphabetic)
        && value.split('/').count() >= 2
        && value.split('/').all(|segment| {
            !segment.is_empty()
                && segment.as_bytes().iter().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-')
                })
        })
}

fn valid_currency(value: &str) -> bool {
    value.len() == 3 && value.as_bytes().iter().all(u8::is_ascii_uppercase)
}

fn valid_amount(value: Decimal) -> bool {
    value.scale() <= 6
}

fn valid_ratio(value: Decimal) -> bool {
    value.scale() <= 12 && (Decimal::ZERO..=Decimal::ONE).contains(&value)
}

fn round_even(value: Decimal, scale: u32) -> Decimal {
    value.round_dp_with_strategy(scale, RoundingStrategy::MidpointNearestEven)
}

fn coverage_ratio(numerator: Decimal, denominator: Decimal) -> Option<Decimal> {
    if denominator == Decimal::ZERO {
        Some(Decimal::ONE)
    } else {
        numerator
            .checked_div(denominator)
            .map(|value| round_even(value, 12))
    }
}

fn count_coverage(captured: i64, expected: i64) -> Option<Decimal> {
    if expected == 0 {
        Some(Decimal::ONE)
    } else {
        Decimal::from(captured)
            .checked_div(Decimal::from(expected))
            .map(|value| round_even(value, 12))
    }
}
