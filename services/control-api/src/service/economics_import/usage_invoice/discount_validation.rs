use rust_decimal::RoundingStrategy;

use super::*;

impl EconomicsDiscountAppendV1 {
    fn validate(&self) -> Result<(), ServiceError> {
        if any_nil(&[
            self.deployment_id,
            self.organization_id,
            self.contract_period_id,
            self.contract_id,
            self.tariff_version_id,
        ]) || !optional_uuid(&self.root_discount_id)
            || !optional_uuid(&self.supersedes_discount_id)
            || self.revision < 1
            || !valid_discount_text(&self.accounting_timezone, 63)
            || self.effective_until <= self.effective_from
            || !self.scope_is_nonempty()
            || !self.state_shape()
            || !(-100_000..=10_000).contains(&self.projected_margin_after_discount_basis_points)
            || self.undiscounted_p75_revenue_amount <= Decimal::ZERO
            || self.discounted_p75_revenue_amount <= Decimal::ZERO
            || self.discounted_p75_revenue_amount > self.undiscounted_p75_revenue_amount
            || self.p75_variable_cost_amount < Decimal::ZERO
            || !self.margin_arithmetic_matches()
            || !self.oversight_shape()
        {
            return Err(ServiceError::InvalidRequest);
        }
        let _evidence = (
            self.sku,
            self.reason_code,
            &self.tariff_record_digest,
            &self.accounting_policy_digest,
            &self.margin_assumption_digest,
            &self.expected_resulting_discount_set_digest,
            &self.cost_evidence_digest,
            &self.margin_formula_digest,
            &self.margin_evidence_as_of,
            &self.source_receipt_digest,
            &self.expected_record_digest,
        );
        Ok(())
    }

    fn scope_is_nonempty(&self) -> bool {
        self.applies_workspace_base
            || self.applies_active_contributor_block
            || self.applies_processing_credit_overage
            || self.applies_storage_gb_month_overage
            || self.applies_api_record_unit_overage
            || self.applies_sla_add_on
    }

    fn state_shape(&self) -> bool {
        match (self.state, self.basis_points.as_option()) {
            (DiscountState::Active, Some(value)) => (1..=10_000).contains(value),
            (DiscountState::Withdrawn, None) => true,
            _ => false,
        }
    }

    fn margin_arithmetic_matches(&self) -> bool {
        self.discounted_p75_revenue_amount
            .checked_sub(self.p75_variable_cost_amount)
            .and_then(|value| value.checked_div(self.discounted_p75_revenue_amount))
            .and_then(|value| value.checked_mul(Decimal::from(10_000)))
            .map(|value| value.round_dp_with_strategy(0, RoundingStrategy::MidpointNearestEven))
            == Some(Decimal::from(
                self.projected_margin_after_discount_basis_points,
            ))
    }

    fn oversight_shape(&self) -> bool {
        if self.projected_margin_after_discount_basis_points
            >= self.required_variable_gross_margin_basis_points
        {
            return self.oversight_reason.is_none();
        }
        self.oversight_reason
            .as_option()
            .as_deref()
            .is_some_and(|value| valid_discount_text(value, 1_000))
    }

    fn chain_matches(&self, source: &EconomicsDiscountSourceImportV1) -> bool {
        if self.revision == 1 {
            return self.root_discount_id.is_none()
                && self.supersedes_discount_id.is_none()
                && no_source_head(source);
        }
        let (Some(supersedes_id), Some(head_id), Some(head_revision), Some(_)) = (
            self.supersedes_discount_id.as_option(),
            source.expected_head_id.as_option(),
            source.expected_head_revision.as_option(),
            source.expected_head_digest.as_option(),
        ) else {
            return false;
        };
        self.root_discount_id.is_some()
            && supersedes_id == head_id
            && self.revision.checked_sub(1) == Some(*head_revision)
    }

    pub(in super::super) fn applies_to(&self, line_kind: InvoiceLineKind) -> bool {
        match line_kind {
            InvoiceLineKind::WorkspaceBase => self.applies_workspace_base,
            InvoiceLineKind::ActiveContributorBlock => self.applies_active_contributor_block,
            InvoiceLineKind::ProcessingCreditOverage => self.applies_processing_credit_overage,
            InvoiceLineKind::StorageGbMonthOverage => self.applies_storage_gb_month_overage,
            InvoiceLineKind::ApiRecordUnitOverage => self.applies_api_record_unit_overage,
            InvoiceLineKind::SlaAddOn => self.applies_sla_add_on,
            InvoiceLineKind::AccountingAdjustment => false,
        }
    }
}

impl EconomicsDiscountSourceImportV1 {
    pub(in super::super) fn validate(&self) -> Result<(), ServiceError> {
        if self.evidence_segment_id.is_nil() {
            return Err(ServiceError::InvalidRequest);
        }
        let valid = match self.resolution {
            EconomicsSourceResolutionV1::Existing => self.existing_shape(),
            EconomicsSourceResolutionV1::Append => self.append_shape(),
        };
        if !valid {
            return Err(ServiceError::InvalidRequest);
        }
        let _evidence = (&self.evidence_segment_digest, &self.source_signature_digest);
        Ok(())
    }

    fn existing_shape(&self) -> bool {
        let (Some(id), Some(revision), Some(digest)) = (
            self.existing_discount_id.as_option(),
            self.existing_discount_revision.as_option(),
            self.existing_discount_digest.as_option(),
        ) else {
            return false;
        };
        self.append_value.is_none()
            && !id.is_nil()
            && *revision > 0
            && self.expected_head_id.as_option().as_ref() == Some(id)
            && self.expected_head_revision.as_option().as_ref() == Some(revision)
            && self.expected_head_digest.as_option().as_ref() == Some(digest)
    }

    fn append_shape(&self) -> bool {
        if self.existing_discount_id.is_some()
            || self.existing_discount_revision.is_some()
            || self.existing_discount_digest.is_some()
        {
            return false;
        }
        let Some(append) = self.append_value.as_option().as_ref() else {
            return false;
        };
        append.validate().is_ok()
            && append.signature_digest == self.source_signature_digest
            && append.chain_matches(self)
    }

    pub(in super::super) fn identity_digest(&self) -> Option<&Sha256Digest> {
        match self.resolution {
            EconomicsSourceResolutionV1::Existing => {
                self.existing_discount_digest.as_option().as_ref()
            }
            EconomicsSourceResolutionV1::Append => self
                .append_value
                .as_option()
                .as_ref()
                .map(|append| &append.expected_record_digest),
        }
    }
}

fn no_source_head(source: &EconomicsDiscountSourceImportV1) -> bool {
    source.expected_head_id.is_none()
        && source.expected_head_revision.is_none()
        && source.expected_head_digest.is_none()
}

fn valid_discount_text(value: &str, maximum: usize) -> bool {
    value.trim_matches(' ') == value && (1..=maximum).contains(&value.chars().count())
}
