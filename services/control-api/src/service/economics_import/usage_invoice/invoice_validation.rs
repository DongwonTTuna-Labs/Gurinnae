use super::*;

impl EconomicsInvoiceHeaderImportV1 {
    pub(super) fn validate(&self) -> Result<(), ServiceError> {
        let chain = match self.invoice_effect {
            InvoiceEffect::Original => {
                self.invoice_revision == 1
                    && no_fence(
                        &self.supersedes_invoice_id,
                        &self.predecessor_reconciliation_digest,
                    )
            }
            InvoiceEffect::Restatement => {
                self.invoice_revision > 1
                    && full_fence(
                        &self.supersedes_invoice_id,
                        &self.predecessor_reconciliation_digest,
                    )
            }
        };
        if any_nil(&[
            self.root_invoice_id,
            self.deployment_id,
            self.organization_id,
            self.contract_period_id,
            self.contract_id,
        ]) || !optional_uuid(&self.supersedes_invoice_id)
            || !valid_head(
                &self.expected_head_id,
                &self.expected_head_revision,
                &self.expected_head_reconciliation_digest,
            )
            || !chain
            || self.period_end <= self.period_start
            || self.expected_line_count < 1
            || self.expected_usage_membership_count < 0
            || !valid_trimmed(&self.accounting_timezone, 255)
            || !valid_source_system(&self.source_system_id)
            || !valid_currency(&self.currency)
            || !datetime_not_after(&self.billing_cutoff_at, &self.reconciled_at)
            || self.expected_subtotal < Decimal::ZERO
            || self.expected_discount_total < Decimal::ZERO
            || self.expected_taxable_amount < Decimal::ZERO
            || self.expected_tax_total < Decimal::ZERO
            || self.expected_invoice_total < Decimal::ZERO
            || self.expected_discount_total > self.expected_subtotal
            || self.expected_taxable_amount != self.expected_subtotal - self.expected_discount_total
            || self.expected_invoice_total
                != self.expected_taxable_amount
                    + self.expected_tax_total
                    + self.expected_correction_total
        {
            return Err(ServiceError::InvalidRequest);
        }
        let _evidence = (
            &self.external_invoice_reference_digest,
            &self.expected_line_set_digest,
            &self.expected_usage_membership_set_digest,
            &self.expected_usage_fact_set_digest,
            &self.expected_usage_window_receipt_set_digest,
            &self.expected_tariff_set_digest,
            &self.expected_discount_leaf_set_digest,
            &self.expected_correction_set_digest,
            &self.expected_contract_state_interval_set_digest,
            &self.tax_policy_digest,
            &self.rounding_policy_digest,
            &self.provider_receipt_digest,
            &self.source_record_digest,
            &self.signature_digest,
            &self.import_receipt_digest,
            &self.accounting_policy_digest,
            &self.expected_reconciliation_digest,
        );
        Ok(())
    }
}

impl EconomicsInvoiceLineImportV1 {
    pub(super) fn validate(&self) -> Result<(), ServiceError> {
        let references = same_presence(&[
            self.usage_fact_id.is_some(),
            self.usage_fact_digest.is_some(),
        ]) && same_presence(&[
            self.tariff_version_id.is_some(),
            self.tariff_record_digest.is_some(),
        ]) && same_presence(&[
            self.discount_decision_id.is_some(),
            self.discount_record_digest.is_some(),
        ]);
        if self.line_ordinal < 1
            || self.service_period_end <= self.service_period_start
            || !optional_uuid(&self.usage_fact_id)
            || !optional_uuid(&self.tariff_version_id)
            || !optional_uuid(&self.discount_decision_id)
            || !optional_uuid(&self.corrects_line_id)
            || self
                .discount_source_ordinal
                .as_option()
                .is_some_and(|ordinal| ordinal < 1)
            || !references
            || self.quantity < Decimal::ZERO
            || self.unit_price < Decimal::ZERO
            || self.expected_subtotal < Decimal::ZERO
            || self.expected_discount_amount < Decimal::ZERO
            || self.expected_taxable_amount < Decimal::ZERO
            || self.expected_tax_amount < Decimal::ZERO
            || self.expected_discount_amount > self.expected_subtotal
            || self.expected_taxable_amount
                != self.expected_subtotal - self.expected_discount_amount
            || self.expected_line_total
                != self.expected_taxable_amount
                    + self.expected_tax_amount
                    + self.expected_correction_amount
            || !(0..=10_000).contains(&self.tax_rate_basis_points)
            || !valid_tax_shape(self)
            || !valid_line_shape(self)
            || !valid_currency(&self.currency)
        {
            return Err(ServiceError::InvalidRequest);
        }
        let _evidence = (
            &self.tax_policy_digest,
            &self.correction_set_digest,
            &self.rounding_policy_digest,
            &self.source_line_digest,
            self.sku,
        );
        Ok(())
    }
}

impl EconomicsInvoiceMembershipImportV1 {
    pub(super) fn validate(&self) -> Result<(), ServiceError> {
        let chain_presence = same_presence(&[
            self.supersedes_membership_id.is_some(),
            self.predecessor_invoice_id.is_some(),
            self.predecessor_membership_digest.is_some(),
        ]);
        let chain = match self.membership_effect {
            MembershipEffect::Original => {
                self.revision == 1 && chain_presence && self.supersedes_membership_id.is_none()
            }
            MembershipEffect::Restatement => {
                self.revision > 1 && chain_presence && self.supersedes_membership_id.is_some()
            }
        };
        let kind = match self.membership_kind {
            MembershipKind::ZeroUsage => {
                self.billable_quantity == Decimal::ZERO
                    && self.included_quantity == Decimal::ZERO
                    && self.charged_quantity == Decimal::ZERO
                    && self.invoice_line_ordinal.is_none()
            }
            MembershipKind::IncludedAllowance => {
                self.billable_quantity > Decimal::ZERO
                    && self.included_quantity == self.billable_quantity
                    && self.charged_quantity == Decimal::ZERO
                    && self.invoice_line_ordinal.is_none()
            }
            MembershipKind::BilledOverage => {
                self.billable_quantity > Decimal::ZERO
                    && self.charged_quantity > Decimal::ZERO
                    && self.invoice_line_ordinal.is_some()
            }
        };
        if any_nil(&[
            self.root_membership_id,
            self.deployment_id,
            self.organization_id,
            self.contract_period_id,
            self.contract_id,
            self.usage_root_fact_id,
            self.usage_fact_id,
            self.usage_window_receipt_id,
        ]) || !optional_uuid(&self.supersedes_membership_id)
            || !optional_uuid(&self.predecessor_invoice_id)
            || !valid_head(
                &self.expected_head_id,
                &self.expected_head_revision,
                &self.expected_head_digest,
            )
            || !chain
            || self.usage_fact_revision < 1
            || self.usage_window_receipt_version < 1
            || self.period_end <= self.period_start
            || self.measurement_state != MeasurementState::Complete
            || self.billable_quantity < Decimal::ZERO
            || self.included_quantity < Decimal::ZERO
            || self.charged_quantity < Decimal::ZERO
            || self.billable_quantity != self.included_quantity + self.charged_quantity
            || self.invoice_line_ordinal.is_some_and(|ordinal| ordinal < 1)
            || !kind
            || !valid_trimmed(&self.accounting_timezone, 255)
            || !valid_currency(&self.currency)
        {
            return Err(ServiceError::InvalidRequest);
        }
        let _evidence = (
            &self.usage_fact_digest,
            &self.usage_window_receipt_digest,
            &self.measurement_window_digest,
            &self.allocation_policy_digest,
            self.sku,
            self.meter_kind,
            self.billable_unit,
        );
        Ok(())
    }
}
