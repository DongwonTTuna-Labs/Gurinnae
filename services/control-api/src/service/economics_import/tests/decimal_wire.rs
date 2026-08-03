use super::super::EconomicsImportOperationV1;
use super::fixtures::{all_operations, cost_allocation_close_with_fx_source};
use serde_json::{Value, json};

#[test]
fn every_operation_branch_accepts_canonical_decimal_strings() {
    for (operation_id, mut operation) in all_operations() {
        canonicalize_decimal_fields(&mut operation);
        assert!(
            serde_json::from_value::<EconomicsImportOperationV1>(operation).is_ok(),
            "{operation_id}"
        );
    }
}

#[test]
fn decimal_wire_rejects_noncanonical_forms_and_keeps_integer_fields_numeric() {
    for bad in [
        json!(100),
        json!("1e2"),
        json!("+1.23"),
        json!("01.23"),
        json!("-0"),
        json!("1.0"),
        json!("1.230"),
    ] {
        let mut operation = canonical_invoice();
        operation["lines"][0]["unitPrice"] = bad;
        assert!(serde_json::from_value::<EconomicsImportOperationV1>(operation).is_err());
    }

    let mut oversized_integer = canonical_invoice();
    oversized_integer["lines"][0]["unitPrice"] = json!("1234567890123456789");
    assert!(serde_json::from_value::<EconomicsImportOperationV1>(oversized_integer).is_err());

    let mut wrong_ratio_scale = canonical_tariff();
    wrong_ratio_scale["costCaptureCoverage"] = json!("1.1234567890123");
    assert!(serde_json::from_value::<EconomicsImportOperationV1>(wrong_ratio_scale).is_err());

    let mut wrong_rate_scale = canonical_cost_close();
    wrong_rate_scale["fxRates"][0]["appendValue"]["rate"] = json!("1.1234567890123");
    assert!(serde_json::from_value::<EconomicsImportOperationV1>(wrong_rate_scale).is_err());

    let mut nullable = canonical_usage();
    nullable["receipt"]["observedQuantity"] = Value::Null;
    assert!(serde_json::from_value::<EconomicsImportOperationV1>(nullable).is_ok());

    let mut nullable_number = canonical_usage();
    nullable_number["receipt"]["observedQuantity"] = json!(1);
    assert!(serde_json::from_value::<EconomicsImportOperationV1>(nullable_number).is_err());

    let operation = canonical_invoice();
    assert!(operation["lines"][0]["taxRateBasisPoints"].is_number());
    assert!(serde_json::from_value::<EconomicsImportOperationV1>(operation).is_ok());
}

fn canonical_invoice() -> Value {
    operation("recordInvoice")
}

fn canonical_tariff() -> Value {
    operation("createTariffVersion")
}

fn canonical_cost_close() -> Value {
    let mut operation = cost_allocation_close_with_fx_source("APPEND");
    canonicalize_decimal_fields(&mut operation);
    operation
}

fn canonical_usage() -> Value {
    operation("recordUsageWindow")
}

fn operation(operation_id: &str) -> Value {
    let mut operation = all_operations()
        .into_iter()
        .find_map(|(name, operation)| (name == operation_id).then_some(operation))
        .expect("known test fixture");
    canonicalize_decimal_fields(&mut operation);
    operation
}

fn canonicalize_decimal_fields(value: &mut Value) {
    match value {
        Value::Object(object) => {
            for (name, value) in object {
                if decimal_scale(name).is_some() {
                    if let Some(number) = value.as_i64() {
                        *value = Value::String(number.to_string());
                    } else if let Some(number) = value.as_f64() {
                        *value = Value::String(number.to_string());
                    } else if let Some(text) = value.as_str() {
                        if text.contains('.') {
                            let trimmed = text.trim_end_matches('0').trim_end_matches('.');
                            *value = Value::String(if trimmed.is_empty() {
                                "0".to_owned()
                            } else {
                                trimmed.to_owned()
                            });
                        }
                    }
                } else {
                    canonicalize_decimal_fields(value);
                }
            }
        }
        Value::Array(values) => values.iter_mut().for_each(canonicalize_decimal_fields),
        _ => {}
    }
}

fn decimal_scale(name: &str) -> Option<usize> {
    match name {
        "rate" => Some(12),
        "slaTargetAvailabilityRatio" => Some(18),
        "costCaptureCoverage"
        | "directCostCoverage"
        | "totalCostCoverage"
        | "expectedCostCaptureCoverage"
        | "expectedDirectCoverage"
        | "expectedTotalCoverage"
        | "allocationRatio" => Some(12),
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
        | "taxAmount" => Some(6),
        _ => None,
    }
}
