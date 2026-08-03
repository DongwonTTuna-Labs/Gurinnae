use super::*;

pub(super) fn valid_tax_shape(value: &EconomicsInvoiceLineImportV1) -> bool {
    match value.tax_category {
        TaxCategory::Standard => {
            value.tax_rate_basis_points > 0 && value.tax_exemption_digest.is_none()
        }
        TaxCategory::ZeroRated | TaxCategory::Exempt | TaxCategory::OutOfScope => {
            value.tax_rate_basis_points == 0 && value.tax_exemption_digest.is_some()
        }
    }
}

pub(super) fn valid_line_shape(value: &EconomicsInvoiceLineImportV1) -> bool {
    let usage = value.usage_fact_id.is_some();
    let tariff = value.tariff_version_id.is_some();
    let discounted = value.expected_discount_amount > Decimal::ZERO;
    let fixed = matches!(
        value.line_kind,
        InvoiceLineKind::WorkspaceBase | InvoiceLineKind::SlaAddOn
    );
    let metered = matches!(
        value.line_kind,
        InvoiceLineKind::ActiveContributorBlock
            | InvoiceLineKind::ProcessingCreditOverage
            | InvoiceLineKind::StorageGbMonthOverage
            | InvoiceLineKind::ApiRecordUnitOverage
    );
    let source_shape = if fixed {
        !usage && value.meter_kind.is_none() && value.quantity == Decimal::ONE
    } else if metered {
        usage && value.meter_kind.is_some()
    } else {
        !usage
            && !tariff
            && !discounted
            && value.corrects_line_id.is_some()
            && value.meter_kind.is_none()
            && value.quantity == Decimal::ZERO
            && value.unit_price == Decimal::ZERO
            && value.expected_subtotal == Decimal::ZERO
            && value.expected_discount_amount == Decimal::ZERO
            && value.expected_taxable_amount == Decimal::ZERO
            && value.expected_tax_amount == Decimal::ZERO
            && value.expected_correction_amount != Decimal::ZERO
    };
    let ordinary = matches!(value.line_kind, InvoiceLineKind::AccountingAdjustment)
        || tariff
            && value.corrects_line_id.is_none()
            && value.quantity > Decimal::ZERO
            && value.expected_correction_amount == Decimal::ZERO
            && value.expected_line_total >= Decimal::ZERO;
    let discount_shape = if discounted {
        value.discount_source_ordinal.is_some()
    } else {
        value.discount_decision_id.is_none()
            && value.discount_record_digest.is_none()
            && value.discount_source_ordinal.is_none()
    };
    let meter_shape = match value.line_kind {
        InvoiceLineKind::ActiveContributorBlock => {
            value.meter_kind.as_option() == &Some(UsageMeterKind::Seat)
        }
        InvoiceLineKind::ProcessingCreditOverage => matches!(
            value.meter_kind.as_option(),
            Some(
                UsageMeterKind::AgentToken
                    | UsageMeterKind::ModelRequest
                    | UsageMeterKind::SourcePage
            )
        ),
        InvoiceLineKind::StorageGbMonthOverage => {
            value.meter_kind.as_option() == &Some(UsageMeterKind::StorageByteHour)
        }
        InvoiceLineKind::ApiRecordUnitOverage => {
            value.meter_kind.as_option() == &Some(UsageMeterKind::ApiRequest)
        }
        _ => true,
    };
    source_shape && ordinary && discount_shape && meter_shape
}

pub(super) fn line_matches_invoice(
    line: &EconomicsInvoiceLineImportV1,
    invoice: &EconomicsInvoiceHeaderImportV1,
) -> bool {
    line.sku == invoice.sku
        && line.currency == invoice.currency
        && line.service_period_start == invoice.period_start
        && line.service_period_end == invoice.period_end
}

pub(super) fn validate_line_discount_binding(
    line: &EconomicsInvoiceLineImportV1,
    invoice: &EconomicsInvoiceHeaderImportV1,
    discounts: &[EconomicsDiscountSourceImportV1],
) -> Result<Option<usize>, ServiceError> {
    if line.expected_discount_amount == Decimal::ZERO {
        return Ok(None);
    }
    let Some(ordinal) = line.discount_source_ordinal.as_option() else {
        return Err(ServiceError::InvalidRequest);
    };
    let Some(index) = usize::try_from(*ordinal)
        .ok()
        .and_then(|ordinal| ordinal.checked_sub(1))
    else {
        return Err(ServiceError::InvalidRequest);
    };
    let Some(source) = discounts.get(index) else {
        return Err(ServiceError::InvalidRequest);
    };
    let matches = match source.resolution {
        EconomicsSourceResolutionV1::Existing => {
            line.discount_decision_id.as_option() == source.existing_discount_id.as_option()
                && line.discount_record_digest.as_option()
                    == source.existing_discount_digest.as_option()
        }
        EconomicsSourceResolutionV1::Append => {
            line.discount_decision_id.is_none()
                && line.discount_record_digest.is_none()
                && source
                    .append_value
                    .as_option()
                    .as_ref()
                    .is_some_and(|append| append_matches_invoice_line(append, line, invoice))
        }
    };
    if matches {
        Ok(Some(index))
    } else {
        Err(ServiceError::InvalidRequest)
    }
}

fn append_matches_invoice_line(
    append: &EconomicsDiscountAppendV1,
    line: &EconomicsInvoiceLineImportV1,
    invoice: &EconomicsInvoiceHeaderImportV1,
) -> bool {
    append.state == DiscountState::Active
        && append.deployment_id == invoice.deployment_id
        && append.organization_id == invoice.organization_id
        && append.contract_period_id == invoice.contract_period_id
        && append.contract_id == invoice.contract_id
        && append.sku == invoice.sku
        && append.accounting_timezone == invoice.accounting_timezone
        && append.accounting_policy_digest == invoice.accounting_policy_digest
        && append.expected_resulting_discount_set_digest
            == invoice.expected_discount_leaf_set_digest
        && line.tariff_version_id.as_option() == &Some(append.tariff_version_id)
        && line.tariff_record_digest.as_option().as_ref() == Some(&append.tariff_record_digest)
        && append.effective_from <= line.service_period_start
        && append.effective_until >= line.service_period_end
        && append.applies_to(line.line_kind)
}

pub(super) fn membership_matches_invoice(
    value: &EconomicsInvoiceMembershipImportV1,
    invoice: &EconomicsInvoiceHeaderImportV1,
    lines: &[EconomicsInvoiceLineImportV1],
) -> bool {
    let line_matches = value.invoice_line_ordinal.is_none_or(|ordinal| {
        usize::try_from(ordinal)
            .ok()
            .and_then(|ordinal| ordinal.checked_sub(1))
            .and_then(|index| lines.get(index))
            .is_some_and(|line| line.meter_kind.as_option() == &Some(value.meter_kind))
    });
    value.deployment_id == invoice.deployment_id
        && value.organization_id == invoice.organization_id
        && value.contract_period_id == invoice.contract_period_id
        && value.contract_id == invoice.contract_id
        && value.sku == invoice.sku
        && value.accounting_timezone == invoice.accounting_timezone
        && value.currency == invoice.currency
        && value.period_start == invoice.period_start
        && value.period_end == invoice.period_end
        && line_matches
}
