use super::fixtures::*;
use super::parse_and_validate;

#[test]
fn fixture_digest_is_sha256_of_the_declared_nonproduction_authority_label() {
    assert_eq!(
        digest('1'),
        "8911ea5ea969acac79ac9fe39800f1e7f855e074be1d74794fbddb1adf1f29b8"
    );
}

#[test]
fn all_eleven_row_valued_operations_parse_validate_and_report_exact_wire_name() {
    let operations = all_operations();
    assert_eq!(operations.len(), 11);
    for (expected_wire_name, fixture) in operations {
        let operation = parse_and_validate(fixture)
            .unwrap_or_else(|error| panic!("{expected_wire_name}: {error:?}"));
        assert_eq!(operation.as_str(), expected_wire_name);
    }
}

#[test]
fn cash_import_accepts_both_signed_invoice_fenced_source_kinds() {
    for source_kind in ["BANK_TRANSFER", "PG_SETTLEMENT"] {
        let operation = parse_and_validate(cash_application(source_kind))
            .unwrap_or_else(|error| panic!("{source_kind}: {error:?}"));
        assert_eq!(operation.as_str(), "recordCashApplication");
    }
}

#[test]
fn commercial_qualification_accepts_exact_existing_and_append_acquisition_sources() {
    for resolution in ["EXISTING", "APPEND"] {
        let operation =
            parse_and_validate(commercial_qualification_with_acquisition_source(resolution))
                .unwrap_or_else(|error| panic!("{resolution}: {error:?}"));
        assert_eq!(operation.as_str(), "recordCommercialQualification");
    }
}

#[test]
fn cost_close_accepts_exact_existing_and_append_fx_sources() {
    for resolution in ["EXISTING", "APPEND"] {
        let operation = parse_and_validate(cost_allocation_close_with_fx_source(resolution))
            .unwrap_or_else(|error| panic!("{resolution}: {error:?}"));
        assert_eq!(operation.as_str(), "importCostAllocationClose");
    }
}

#[test]
fn collection_failure_authority_is_closed_and_mutually_exclusive() {
    for authority in ["PROVIDER_FETCH_CONFIRMED", "BANK_RETURN_CONFIRMED"] {
        assert!(parse_and_validate(collection_failure(authority)).is_ok());
    }

    assert!(
        serde_json::from_value::<super::super::EconomicsImportOperationV1>(collection_failure(
            "CASH_ABSENCE_INFERRED"
        ))
        .is_err()
    );

    let mut caller_source_kind = collection_failure("BANK_RETURN_CONFIRMED");
    caller_source_kind["sourceKind"] = serde_json::json!("BANK_TRANSFER");
    assert!(
        serde_json::from_value::<super::super::EconomicsImportOperationV1>(caller_source_kind)
            .is_err()
    );

    let mut mixed = collection_failure("PROVIDER_FETCH_CONFIRMED");
    mixed["invoiceFactId"] = serde_json::json!(uuid(601));
    mixed["invoiceFactDigest"] = serde_json::json!(digest('3'));
    mixed["invoiceReconciliationDigest"] = serde_json::json!(digest('4'));
    mixed["expectedInvoiceRevision"] = serde_json::json!(1);
    mixed["signedEvidenceSegmentId"] = serde_json::json!(uuid(1_002));
    mixed["signedEvidenceSegmentDigest"] = serde_json::json!(digest('5'));
    assert!(parse_and_validate(mixed).is_err());
}

#[test]
fn cost_and_accounting_row_imports_reject_empty_sets() {
    let fixtures = [
        (cost_allocation_close(), "lines"),
        (revenue(), "rows"),
        (accounting_correction(), "rows"),
        (cash_application("BANK_TRANSFER"), "rows"),
        (tax_invoice(), "rows"),
    ];
    for (mut fixture, row_key) in fixtures {
        fixture[row_key] = serde_json::json!([]);
        assert!(
            parse_and_validate(fixture).is_err(),
            "{row_key} unexpectedly accepted an empty TEST_FIXTURE set"
        );
    }
}

#[test]
fn contract_capabilities_are_set_equal_to_the_ordered_twelve_codes() {
    let valid = commercial_contract_period();
    let actual_codes = valid["capabilities"]
        .as_array()
        .expect("TEST_FIXTURE capabilities")
        .iter()
        .filter_map(|value| value["capabilityCode"].as_str())
        .collect::<Vec<_>>();
    assert_eq!(
        actual_codes,
        [
            "PUBLIC_WEB",
            "VERIFIED_EMAIL",
            "API_EXPORT",
            "SIGNED_WEBHOOK",
            "DAILY_DIGEST",
            "WEEKLY_DIGEST",
            "SMS",
            "TELEGRAM",
            "WHATSAPP",
            "LINE",
            "KAKAO",
            "VOICE",
        ]
    );
    assert!(parse_and_validate(valid).is_ok());

    let mut missing = commercial_contract_period();
    missing["capabilities"]
        .as_array_mut()
        .expect("TEST_FIXTURE capabilities")
        .pop();
    assert!(parse_and_validate(missing).is_err());

    let mut reordered = commercial_contract_period();
    reordered["capabilities"]
        .as_array_mut()
        .expect("TEST_FIXTURE capabilities")
        .swap(0, 1);
    assert!(parse_and_validate(reordered).is_err());

    let mut duplicate = commercial_contract_period();
    duplicate["capabilities"][1]["capabilityCode"] = serde_json::json!("PUBLIC_WEB");
    assert!(parse_and_validate(duplicate).is_err());
}

#[test]
fn tariff_fixture_cannot_bypass_the_margin_arithmetic_gate() {
    assert!(parse_and_validate(tariff_version()).is_ok());

    let mut missing_exception_reason = tariff_version();
    missing_exception_reason
        .as_object_mut()
        .expect("TEST_FIXTURE tariff operation")
        .remove("marginExceptionReason");
    assert!(parse_and_validate(missing_exception_reason).is_err());

    let mut unnecessary_exception = tariff_version();
    unnecessary_exception["marginExceptionReason"] =
        serde_json::json!("exception without a margin shortfall");
    assert!(parse_and_validate(unnecessary_exception).is_err());

    let mut inconsistent = tariff_version();
    inconsistent["expectedProjectedP75VariableGrossMarginBasisPoints"] = serde_json::json!(5999);
    assert!(parse_and_validate(inconsistent).is_err());

    let mut unsupported_stage_target = tariff_version();
    unsupported_stage_target["expectedRequiredVariableGrossMarginBasisPoints"] =
        serde_json::json!(6500);
    assert!(parse_and_validate(unsupported_stage_target).is_err());

    let mut general_availability = tariff_version();
    general_availability["expectedRequiredVariableGrossMarginBasisPoints"] =
        serde_json::json!(7000);
    general_availability["expectedProjectedP75VariableGrossMarginBasisPoints"] =
        serde_json::json!(7000);
    general_availability["p75VariableCostAmount"] = serde_json::json!("30");
    assert!(parse_and_validate(general_availability).is_ok());

    let mut unreviewed_exception = tariff_version();
    unreviewed_exception["expectedProjectedP75VariableGrossMarginBasisPoints"] =
        serde_json::json!(5000);
    unreviewed_exception["p75VariableCostAmount"] = serde_json::json!("50");
    assert!(parse_and_validate(unreviewed_exception).is_err());

    let mut general_availability_exception = tariff_version();
    general_availability_exception["expectedRequiredVariableGrossMarginBasisPoints"] =
        serde_json::json!(7000);
    general_availability_exception["marginExceptionReason"] =
        serde_json::json!("invalid general availability exception");
    assert!(parse_and_validate(general_availability_exception).is_err());

    let mut caller_stage = tariff_version();
    caller_stage["stage"] = serde_json::json!("PILOT");
    assert!(parse_and_validate(caller_stage).is_err());

    let mut attempted_reviewed_exception = tariff_version();
    attempted_reviewed_exception["expectedProjectedP75VariableGrossMarginBasisPoints"] =
        serde_json::json!(5000);
    attempted_reviewed_exception["p75VariableCostAmount"] = serde_json::json!("50");
    attempted_reviewed_exception["marginExceptionReason"] =
        serde_json::json!("reviewed pilot exception");
    assert!(parse_and_validate(attempted_reviewed_exception).is_err());

    let mut caller_exception_expiry = tariff_version();
    caller_exception_expiry["marginExceptionExpiresAt"] = serde_json::json!("2026-09-01");
    assert!(parse_and_validate(caller_exception_expiry).is_err());
}

#[test]
fn tariff_margin_arithmetic_matches_the_database_half_even_rule() {
    let mut half_even_down = tariff_version();
    half_even_down["p75RevenueAmount"] = serde_json::json!("20000");
    half_even_down["p75VariableCostAmount"] = serde_json::json!("7999");
    assert!(parse_and_validate(half_even_down).is_ok());

    let mut half_even_up = tariff_version();
    half_even_up["p75RevenueAmount"] = serde_json::json!("20000");
    half_even_up["p75VariableCostAmount"] = serde_json::json!("7997");
    half_even_up["expectedProjectedP75VariableGrossMarginBasisPoints"] = serde_json::json!(6002);
    assert!(parse_and_validate(half_even_up).is_ok());

    let mut half_away_from_even = tariff_version();
    half_away_from_even["p75RevenueAmount"] = serde_json::json!("20000");
    half_away_from_even["p75VariableCostAmount"] = serde_json::json!("7999");
    half_away_from_even["expectedProjectedP75VariableGrossMarginBasisPoints"] =
        serde_json::json!(6001);
    assert!(parse_and_validate(half_away_from_even).is_err());
}

#[test]
fn tariff_requires_an_explicit_closed_cost_head_binding_before_proposal_io() {
    assert!(parse_and_validate(tariff_version()).is_ok());

    let mut missing_close_receipt = tariff_version();
    missing_close_receipt
        .as_object_mut()
        .expect("TEST_FIXTURE tariff operation")
        .remove("costAllocationCloseReceiptDigest");
    assert!(parse_and_validate(missing_close_receipt).is_err());

    let mut mismatched_cost_head_id = tariff_version();
    mismatched_cost_head_id["expectedCostHeadId"] = serde_json::json!(uuid(202));
    assert!(parse_and_validate(mismatched_cost_head_id).is_err());

    let mut mismatched_cost_head_digest = tariff_version();
    mismatched_cost_head_digest["expectedCostHeadDigest"] = serde_json::json!(digest('9'));
    assert!(parse_and_validate(mismatched_cost_head_digest).is_err());

    let mut non_period_close = tariff_version();
    non_period_close["costAllocationRowKind"] = serde_json::json!("LINE");
    assert!(parse_and_validate(non_period_close).is_err());
}

#[test]
fn tariff_and_contract_reject_caller_supplied_governance_authority() {
    for (key, value) in [
        ("proposedBy", serde_json::json!(uuid(301))),
        ("approverId", serde_json::json!(uuid(302))),
        ("decisionDigest", serde_json::json!(digest('d'))),
        ("oversightApproverId", serde_json::json!(uuid(303))),
        ("oversightDecisionDigest", serde_json::json!(digest('e'))),
    ] {
        let mut tariff = tariff_version();
        tariff[key] = value;
        assert!(parse_and_validate(tariff).is_err(), "accepted {key}");
    }

    for (key, value) in [
        ("proposedBy", serde_json::json!(uuid(404))),
        ("approverId", serde_json::json!(uuid(405))),
        ("decisionDigest", serde_json::json!(digest('4'))),
        ("oversightApproverId", serde_json::json!(uuid(406))),
        ("oversightDecisionDigest", serde_json::json!(digest('5'))),
    ] {
        let mut contract = commercial_contract_period();
        contract[key] = value;
        assert!(parse_and_validate(contract).is_err(), "accepted {key}");
    }
}

#[test]
fn fx_append_rejects_caller_supplied_governance_authority() {
    for (key, value) in [
        ("proposedBy", serde_json::json!(uuid(251))),
        ("approverId", serde_json::json!(uuid(252))),
        ("decisionDigest", serde_json::json!(digest('4'))),
        ("oversightApproverId", serde_json::json!(uuid(253))),
        ("oversightDecisionDigest", serde_json::json!(digest('5'))),
    ] {
        let mut operation = cost_allocation_close_with_fx_source("APPEND");
        operation["fxRates"][0]["appendValue"][key] = value;
        assert!(
            parse_and_validate(operation).is_err(),
            "accepted FX caller governance key {key}"
        );
    }
}

#[test]
fn discount_append_rejects_caller_supplied_governance_authority() {
    for (key, value) in [
        ("proposedBy", serde_json::json!(uuid(611))),
        ("approverId", serde_json::json!(uuid(612))),
        ("decisionDigest", serde_json::json!(digest('d'))),
        ("oversightApproverId", serde_json::json!(uuid(613))),
        ("oversightDecisionDigest", serde_json::json!(digest('e'))),
        ("oversightExpiresAt", serde_json::json!("2026-09-01")),
    ] {
        let mut operation = invoice_with_discount_source("APPEND");
        operation["discounts"][0]["appendValue"][key] = value;
        assert!(
            parse_and_validate(operation).is_err(),
            "accepted discount caller governance key {key}"
        );
    }
}

#[test]
fn accounting_cash_rows_reject_caller_supplied_governance_authority() {
    for (key, value) in [
        ("proposedBy", serde_json::json!(uuid(701))),
        ("approverId", serde_json::json!(uuid(702))),
        ("decisionDigest", serde_json::json!(digest('d'))),
        ("oversightApproverId", serde_json::json!(uuid(703))),
        ("oversightDecisionDigest", serde_json::json!(digest('e'))),
    ] {
        for mut operation in [
            revenue(),
            accounting_correction(),
            cash_application("BANK_TRANSFER"),
            tax_invoice(),
        ] {
            operation["rows"][0][key] = value.clone();
            assert!(
                parse_and_validate(operation).is_err(),
                "accepted caller governance key {key}"
            );
        }
    }
}

#[test]
fn invoice_discount_sources_accept_exact_existing_and_append_branches() {
    for resolution in ["EXISTING", "APPEND"] {
        let operation = parse_and_validate(invoice_with_discount_source(resolution))
            .unwrap_or_else(|error| panic!("{resolution}: {error:?}"));
        assert_eq!(operation.as_str(), "recordInvoice");
    }
}
