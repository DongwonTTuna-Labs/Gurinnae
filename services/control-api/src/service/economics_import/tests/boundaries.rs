use super::super::{EconomicsImportOperationV1, ServiceError, validate_economics_import_command};
use super::fixtures::*;
use super::parse_and_validate;
use serde_json::{Value, json};

#[test]
fn operation_discriminator_and_selected_row_are_closed() {
    for operation_id in [
        "replaceCommercialContractPeriod",
        "futureEconomicsImport",
        "RecordInvoice",
    ] {
        assert!(
            serde_json::from_value::<EconomicsImportOperationV1>(json!({
                "operationId": operation_id
            }))
            .is_err()
        );
    }

    let mut unknown = invoice();
    unknown["rowDigest"] = json!(digest('f'));
    assert!(parse_and_validate(unknown).is_err());

    let mut sibling = invoice();
    sibling["rows"] = json!([]);
    assert!(parse_and_validate(sibling).is_err());
}

#[test]
fn required_and_required_nullable_wire_keys_cannot_be_omitted() {
    let mut missing_required = invoice();
    missing_required
        .as_object_mut()
        .expect("TEST_FIXTURE invoice operation")
        .remove("invoice");
    assert!(parse_and_validate(missing_required).is_err());

    let mut missing_nullable = invoice();
    missing_nullable["invoice"]
        .as_object_mut()
        .expect("TEST_FIXTURE invoice header")
        .remove("supersedesInvoiceId");
    assert!(parse_and_validate(missing_nullable).is_err());

    let mut missing_discounts = invoice();
    missing_discounts
        .as_object_mut()
        .expect("TEST_FIXTURE invoice operation")
        .remove("discounts");
    assert!(parse_and_validate(missing_discounts).is_err());

    let mut missing_discount_ordinal = invoice();
    missing_discount_ordinal["lines"][0]
        .as_object_mut()
        .expect("TEST_FIXTURE invoice line")
        .remove("discountSourceOrdinal");
    assert!(parse_and_validate(missing_discount_ordinal).is_err());

    let mut missing_acquisition_source = commercial_qualification();
    missing_acquisition_source
        .as_object_mut()
        .expect("TEST_FIXTURE commercial qualification")
        .remove("acquisitionSource");
    assert!(parse_and_validate(missing_acquisition_source).is_err());

    let mut missing_fx_rates = cost_allocation_close();
    missing_fx_rates
        .as_object_mut()
        .expect("TEST_FIXTURE cost allocation close")
        .remove("fxRates");
    assert!(parse_and_validate(missing_fx_rates).is_err());

    let mut missing_fx_source_ordinal = cost_allocation_close();
    missing_fx_source_ordinal["lines"][0]
        .as_object_mut()
        .expect("TEST_FIXTURE cost allocation line")
        .remove("fxSourceOrdinal");
    assert!(parse_and_validate(missing_fx_source_ordinal).is_err());
}

#[test]
fn qualification_acquisition_source_links_are_exact() {
    let mut mismatched_existing_head = commercial_qualification_with_acquisition_source("EXISTING");
    mismatched_existing_head["acquisitionSource"]["expectedHeadDigest"] = json!(digest('9'));
    assert!(parse_and_validate(mismatched_existing_head).is_err());

    let mut mismatched_qualification_link =
        commercial_qualification_with_acquisition_source("EXISTING");
    mismatched_qualification_link["acquisitionSourceReceiptId"] = json!(uuid(151));
    assert!(parse_and_validate(mismatched_qualification_link).is_err());
}

#[test]
fn cost_fx_source_ordinals_and_resolution_links_are_exact() {
    let mut out_of_range = cost_allocation_close_with_fx_source("APPEND");
    out_of_range["lines"][0]["fxSourceOrdinal"] = json!(2);
    assert!(parse_and_validate(out_of_range).is_err());

    let mut append_with_existing_id = cost_allocation_close_with_fx_source("APPEND");
    append_with_existing_id["lines"][0]["fxRateFactId"] = json!(uuid(250));
    assert!(parse_and_validate(append_with_existing_id).is_err());

    let mut mismatched_existing_id = cost_allocation_close_with_fx_source("EXISTING");
    mismatched_existing_id["lines"][0]["fxRateFactId"] = json!(uuid(251));
    assert!(parse_and_validate(mismatched_existing_id).is_err());
}

#[test]
fn invoice_discount_source_ordinal_and_resolution_linkage_are_exact() {
    let mut out_of_range = invoice_with_discount_source("EXISTING");
    out_of_range["lines"][0]["discountSourceOrdinal"] = json!(2);
    assert!(parse_and_validate(out_of_range).is_err());

    let mut mismatched_existing = invoice_with_discount_source("EXISTING");
    mismatched_existing["lines"][0]["discountRecordDigest"] = json!(digest('9'));
    assert!(parse_and_validate(mismatched_existing).is_err());

    let mut mixed_append = invoice_with_discount_source("APPEND");
    mixed_append["lines"][0]["discountDecisionId"] = json!(uuid(610));
    mixed_append["lines"][0]["discountRecordDigest"] = json!(digest('7'));
    assert!(parse_and_validate(mixed_append).is_err());
}

#[test]
fn nullable_head_fences_are_all_or_none_and_match_the_revision_chain() {
    let mut partial_cash_head = cash_application("BANK_TRANSFER");
    partial_cash_head["rows"][0]["expectedHeadId"] = json!(uuid(801));
    assert!(parse_and_validate(partial_cash_head).is_err());

    let mut partial_tariff_head = tariff_version();
    partial_tariff_head["expectedCurrentTariffId"] = json!(uuid(301));
    assert!(parse_and_validate(partial_tariff_head).is_err());
}

#[test]
fn valid_draft_is_forwarded_unchanged_to_the_generic_proposal_lifecycle() {
    let payload = create_payload(action_draft(collection_failure("PROVIDER_FETCH_CONFIRMED")));
    for command in ["createActionProposal", "updateActionDraft"] {
        let original = payload.clone();
        assert!(validate_economics_import_command(command, &payload).is_ok());
        assert_eq!(payload, original);
    }
}

#[test]
fn evidence_ids_and_distinct_digest_set_must_be_nonempty_sorted_and_unique() {
    let mut cases = Vec::new();

    let mut empty = valid_draft();
    empty["rationale"]["evidenceSegmentIds"] = json!([]);
    empty["sourceEvidenceDigests"] = json!([]);
    cases.push(empty);

    let mut empty_digest_set = valid_draft();
    empty_digest_set["sourceEvidenceDigests"] = json!([]);
    cases.push(empty_digest_set);

    let mut more_digests_than_ids = valid_draft();
    more_digests_than_ids["sourceEvidenceDigests"] = json!([digest('1'), digest('2'), digest('3')]);
    cases.push(more_digests_than_ids);

    let mut unsorted_ids = valid_draft();
    unsorted_ids["rationale"]["evidenceSegmentIds"] = json!([uuid(10_002), uuid(10_001)]);
    cases.push(unsorted_ids);

    let mut duplicate_ids = valid_draft();
    duplicate_ids["rationale"]["evidenceSegmentIds"] = json!([uuid(10_001), uuid(10_001)]);
    cases.push(duplicate_ids);

    let mut unsorted_digests = valid_draft();
    unsorted_digests["sourceEvidenceDigests"] = json!([digest('2'), digest('1')]);
    cases.push(unsorted_digests);

    let mut duplicate_digests = valid_draft();
    duplicate_digests["sourceEvidenceDigests"] = json!([digest('1'), digest('1')]);
    cases.push(duplicate_digests);

    for draft in cases {
        assert_invalid_draft(draft);
    }
}

#[test]
fn distinct_evidence_digest_set_may_be_smaller_than_the_locked_id_set() {
    let mut draft = valid_draft();
    draft["sourceEvidenceDigests"] = json!([digest('1')]);
    let payload = create_payload(draft);

    assert!(validate_economics_import_command("createActionProposal", &payload).is_ok());
}

#[test]
fn economics_effect_binding_is_closed_to_the_operation_disposition_registry() {
    let mut null_from = valid_draft();
    null_from["effect"]["fromState"] = Value::Null;
    assert_invalid_draft(null_from);

    let mut generic_aggregate = valid_draft();
    generic_aggregate["effect"]["toState"] =
        json!({"aggregate": "POLICY_VERSION", "state": "CURRENT"});
    assert_invalid_draft(generic_aggregate);

    let mut illegal_disposition = valid_draft();
    illegal_disposition["effect"]["toState"] =
        json!({"aggregate": "ECONOMICS_IMPORT", "state": "RECORDED"});
    assert_invalid_draft(illegal_disposition);

    let mut external = valid_draft();
    external["effect"]["externalSideEffect"] = json!(true);
    assert_invalid_draft(external);
}

#[test]
fn all_eleven_operations_accept_only_their_declared_effect_dispositions() {
    const ALL: [&str; 4] = ["RECORDED", "REPLACED", "REVERSED", "REVIEW_TASK_CREATED"];
    for (operation_id, operation) in all_operations() {
        let allowed = allowed_dispositions(operation_id);
        for disposition in allowed {
            let mut draft = action_draft(operation.clone());
            draft["effect"]["toState"]["state"] = json!(disposition);
            let payload = create_payload(draft);
            assert!(validate_economics_import_command("createActionProposal", &payload).is_ok());
        }
        let undeclared = ALL
            .into_iter()
            .find(|candidate| !allowed.contains(candidate))
            .expect("every TEST_FIXTURE operation has an undeclared disposition");
        let mut draft = action_draft(operation);
        draft["effect"]["toState"]["state"] = json!(undeclared);
        assert_invalid_draft(draft);
    }
}

#[test]
fn command_kind_and_draft_shape_cannot_downgrade_the_import_boundary() {
    let mut unknown = valid_draft();
    unknown["opaqueImportPayload"] = json!({});
    assert_invalid_draft(unknown);

    let mut mismatch = create_payload(valid_draft());
    mismatch.insert("actionKind".to_owned(), json!("TASK"));
    assert!(matches!(
        validate_economics_import_command("createActionProposal", &mismatch),
        Err(ServiceError::InvalidRequest)
    ));

    let unrelated = json!({
        "actionKind": "TASK",
        "draft": {"kind": "TASK"}
    })
    .as_object()
    .cloned()
    .expect("TEST_FIXTURE object");
    assert!(validate_economics_import_command("createActionProposal", &unrelated).is_ok());
}

fn valid_draft() -> Value {
    action_draft(collection_failure("PROVIDER_FETCH_CONFIRMED"))
}

fn assert_invalid_draft(draft: Value) {
    let payload = create_payload(draft);
    assert!(matches!(
        validate_economics_import_command("createActionProposal", &payload),
        Err(ServiceError::InvalidRequest)
    ));
}

fn allowed_dispositions(operation_id: &str) -> &'static [&'static str] {
    match operation_id {
        "recordCommercialQualification" => &["RECORDED", "REPLACED", "REVERSED"],
        "importCostAllocationClose" => &["RECORDED", "REPLACED"],
        "createTariffVersion" | "recordRevenue" => &["RECORDED"],
        "recordCommercialContractPeriod" | "recordInvoice" => &["RECORDED", "REPLACED"],
        "recordUsageWindow" => &["RECORDED", "REPLACED", "REVERSED"],
        "recordAccountingCorrection" => &["RECORDED", "REVERSED"],
        "recordCashApplication" | "recordTaxInvoiceIssuance" => {
            &["RECORDED", "REPLACED", "REVERSED"]
        }
        "recordCollectionFailure" => &["REVIEW_TASK_CREATED"],
        _ => &[],
    }
}
