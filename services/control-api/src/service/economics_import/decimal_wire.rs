use serde_json::Value;

#[derive(Clone, Copy)]
struct DecimalShape {
    precision: usize,
    scale: usize,
}

const MONEY: DecimalShape = DecimalShape {
    precision: 24,
    scale: 6,
};
const RATE: DecimalShape = DecimalShape {
    precision: 30,
    scale: 12,
};
const RATIO: DecimalShape = DecimalShape {
    precision: 18,
    scale: 12,
};
const SLA_RATIO: DecimalShape = DecimalShape {
    precision: 20,
    scale: 18,
};

/// Validates the economics-import decimal lexical ABI before Serde turns the
/// values into `Decimal`. The DTOs deliberately retain `Decimal` so the
/// existing domain validation and arithmetic stay typed after this boundary.
pub(super) fn validate_canonical_decimal_wire(value: &Value) -> Result<(), &'static str> {
    validate_value(value)
}

fn validate_value(value: &Value) -> Result<(), &'static str> {
    match value {
        Value::Object(object) => {
            object
                .iter()
                .try_for_each(|(name, value)| match decimal_shape(name) {
                    Some(shape) => validate_decimal(value, shape),
                    None => validate_value(value),
                })
        }
        Value::Array(values) => values.iter().try_for_each(validate_value),
        _ => Ok(()),
    }
}

fn decimal_shape(name: &str) -> Option<DecimalShape> {
    match name {
        "rate" => Some(RATE),
        "slaTargetAvailabilityRatio" => Some(SLA_RATIO),
        "costCaptureCoverage"
        | "directCostCoverage"
        | "totalCostCoverage"
        | "expectedCostCaptureCoverage"
        | "expectedDirectCoverage"
        | "expectedTotalCoverage"
        | "allocationRatio" => Some(RATIO),
        "workspaceBaseAmount"
        | "activeContributorBlockAmount"
        | "includedProcessingCredits"
        | "processingCreditOverageAmount"
        | "includedStorageGbMonth"
        | "storageGbMonthOverageAmount"
        | "includedApiRecordUnits"
        | "apiRecordUnitOverageAmount"
        | "slaAddOnAmount"
        | "includedQuantity"
        | "overageUnitPrice"
        | "bindingCommittedAmount"
        | "observedQuantity"
        | "normalizationInputQuantity"
        | "quantity"
        | "billableQuantity"
        | "expectedSubtotal"
        | "expectedDiscountTotal"
        | "expectedTaxableAmount"
        | "expectedTaxTotal"
        | "expectedCorrectionTotal"
        | "expectedInvoiceTotal"
        | "unitPrice"
        | "expectedDiscountAmount"
        | "expectedTaxAmount"
        | "expectedCorrectionAmount"
        | "expectedLineTotal"
        | "chargedQuantity"
        | "undiscountedP75RevenueAmount"
        | "discountedP75RevenueAmount"
        | "p75VariableCostAmount"
        | "p75RevenueAmount"
        | "expectedDirectEligibleAmount"
        | "expectedDirectAllocatedAmount"
        | "expectedCapturedCostAmount"
        | "expectedAttributedCostAmount"
        | "expectedUnallocatedAmount"
        | "sourceAmount"
        | "reportingSourceAmount"
        | "driverQuantity"
        | "driverTotalQuantity"
        | "roundingAdjustment"
        | "allocatedAmount"
        | "amount"
        | "effectiveDelta"
        | "expectedResultingEffectiveAmount"
        | "sourceSettlementAmount"
        | "appliedAmount"
        | "taxableAmount"
        | "taxAmount" => Some(MONEY),
        _ => None,
    }
}

fn validate_decimal(value: &Value, shape: DecimalShape) -> Result<(), &'static str> {
    match value {
        // The typed RequiredNullable wrapper determines whether null is legal
        // for this particular field; accepting it here keeps this lexical pass
        // independent of each composite's nullability map.
        Value::Null => Ok(()),
        Value::String(value) => validate_decimal_text(value, shape),
        _ => Err("economics decimal must be a canonical string"),
    }
}

fn validate_decimal_text(value: &str, shape: DecimalShape) -> Result<(), &'static str> {
    let unsigned = value.strip_prefix('-').unwrap_or(value);
    if unsigned.is_empty() || value.starts_with('+') {
        return Err("economics decimal has an invalid sign");
    }
    let (integer, fraction) = match unsigned.split_once('.') {
        Some((integer, fraction)) => (integer, Some(fraction)),
        None => (unsigned, None),
    };
    if unsigned.matches('.').count() > 1
        || integer.is_empty()
        || !integer.bytes().all(|byte| byte.is_ascii_digit())
        || fraction.is_some_and(|fraction| {
            fraction.is_empty()
                || fraction.len() > shape.scale
                || fraction.ends_with('0')
                || !fraction.bytes().all(|byte| byte.is_ascii_digit())
        })
    {
        return Err("economics decimal has an invalid canonical form");
    }
    if (integer.len() > 1 && integer.starts_with('0'))
        || integer.len() > shape.precision - shape.scale
    {
        return Err("economics decimal exceeds canonical precision");
    }
    if value.starts_with('-') && unsigned.bytes().all(|byte| byte == b'0' || byte == b'.') {
        return Err("economics decimal must not be negative zero");
    }
    Ok(())
}
