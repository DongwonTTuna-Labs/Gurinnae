use serde_json::{Value, json};

use super::{EconomicsCostCloseImportV1, EconomicsQualificationImportV1};
use uuid::Uuid;

const TEST_FIXTURE: &str = "test_fixture";

#[test]
fn acquisition_sources_enforce_closed_shapes_and_chain_linkage() {
    let append = acquisition_append();
    assert!(qualification_is_valid(qualification(append.clone(), None)));

    let mut missing_source = qualification(append.clone(), None);
    remove_key(&mut missing_source, "acquisitionSource");
    assert!(qualification_parse_fails(missing_source));

    let mut missing_nullable = qualification(append.clone(), None);
    remove_key(
        &mut missing_nullable["acquisitionSource"]["appendValue"],
        "rootReceiptId",
    );
    assert!(qualification_parse_fails(missing_nullable));

    let mut unknown = qualification(append.clone(), None);
    unknown["acquisitionSource"]["appendValue"]["unexpected"] = json!(true);
    assert!(qualification_parse_fails(unknown));

    let mut signature_mismatch = qualification(append, None);
    signature_mismatch["acquisitionSource"]["sourceSignatureDigest"] = json!(digest('f'));
    assert!(!qualification_is_valid(signature_mismatch));

    let existing = acquisition_existing();
    assert!(qualification_is_valid(qualification(
        existing.clone(),
        Some((uuid(31), digest('b'))),
    )));
    assert!(!qualification_is_valid(qualification(
        existing,
        Some((uuid(32), digest('b'))),
    )));

    let mut successor = acquisition_append();
    successor["appendValue"]["rootReceiptId"] = json!(uuid(33));
    successor["appendValue"]["revision"] = json!(2);
    successor["appendValue"]["receiptEffect"] = json!("REPLACEMENT");
    successor["appendValue"]["supersedesReceiptId"] = json!(uuid(34));
    successor["appendValue"]["predecessorReceiptDigest"] = json!(digest('c'));
    successor["expectedHeadId"] = json!(uuid(34));
    successor["expectedHeadRevision"] = json!(1);
    successor["expectedHeadDigest"] = json!(digest('c'));
    assert!(qualification_is_valid(qualification(
        successor.clone(),
        None
    )));
    successor["expectedHeadDigest"] = json!(digest('d'));
    assert!(!qualification_is_valid(qualification(successor, None)));
}

#[test]
fn fx_sources_enforce_closed_shapes_and_append_existing_resolution() {
    let append = fx_append();
    assert!(cost_close_is_valid(cost_close(
        cross_currency_line(None, 1),
        vec![append.clone()],
        130_000,
    )));

    let mut missing_nullable =
        cost_close(cross_currency_line(None, 1), vec![append.clone()], 130_000);
    remove_key(&mut missing_nullable["fxRates"][0]["appendValue"], "rate");
    assert!(cost_close_parse_fails(missing_nullable));

    let mut unknown = cost_close(cross_currency_line(None, 1), vec![append.clone()], 130_000);
    unknown["fxRates"][0]["appendValue"]["unexpected"] = json!(true);
    assert!(cost_close_parse_fails(unknown));

    let existing = fx_existing();
    assert!(cost_close_is_valid(cost_close(
        cross_currency_line(Some(uuid(43)), 1),
        vec![existing.clone()],
        130_000,
    )));
    assert!(!cost_close_is_valid(cost_close(
        cross_currency_line(Some(uuid(44)), 1),
        vec![existing],
        130_000,
    )));

    let mut successor = fx_append();
    successor["appendValue"]["rootRateId"] = json!(uuid(47));
    successor["appendValue"]["revision"] = json!(2);
    successor["appendValue"]["factKind"] = json!("REPLACEMENT");
    successor["appendValue"]["supersedesRateId"] = json!(uuid(48));
    successor["appendValue"]["correctionReason"] = json!("SOURCE_RESTATEMENT");
    successor["expectedHeadId"] = json!(uuid(48));
    successor["expectedHeadRevision"] = json!(1);
    successor["expectedHeadDigest"] = json!(digest('6'));
    assert!(cost_close_is_valid(cost_close(
        cross_currency_line(None, 1),
        vec![successor.clone()],
        130_000,
    )));
    successor["appendValue"]["rate"] = Value::Null;
    assert!(!cost_close_is_valid(cost_close(
        cross_currency_line(None, 1),
        vec![successor],
        130_000,
    )));

    let mut forbidden_governance = fx_append();
    forbidden_governance["appendValue"]["approverId"] = json!(uuid(49));
    forbidden_governance["appendValue"]["decisionDigest"] = json!(digest('5'));
    assert!(cost_close_parse_fails(cost_close(
        cross_currency_line(None, 1),
        vec![forbidden_governance],
        130_000,
    )));

    let mut signature_mismatch = append;
    signature_mismatch["sourceSignatureDigest"] = json!(digest('f'));
    assert!(!cost_close_is_valid(cost_close(
        cross_currency_line(None, 1),
        vec![signature_mismatch],
        130_000,
    )));
}

#[test]
fn cost_lines_bind_fx_ordinals_without_requiring_fx_for_reporting_currency() {
    assert!(cost_close_is_valid(cost_close(
        same_currency_line(),
        Vec::new(),
        100,
    )));

    let mut missing_ordinal = same_currency_line();
    remove_key(&mut missing_ordinal, "fxSourceOrdinal");
    assert!(cost_close_parse_fails(cost_close(
        missing_ordinal,
        Vec::new(),
        100,
    )));

    assert!(!cost_close_is_valid(cost_close(
        cross_currency_line(None, 0),
        vec![fx_append()],
        130_000,
    )));
    assert!(!cost_close_is_valid(cost_close(
        cross_currency_line(None, 2),
        vec![fx_append()],
        130_000,
    )));
    assert!(!cost_close_is_valid(cost_close(
        cross_currency_line(Some(uuid(43)), 1),
        vec![fx_append()],
        130_000,
    )));

    let mut same_with_fx = same_currency_line();
    same_with_fx["fxSourceOrdinal"] = json!(1);
    assert!(!cost_close_is_valid(cost_close(
        same_with_fx,
        vec![fx_append()],
        100,
    )));
}

fn qualification(acquisition_source: Value, existing: Option<(String, String)>) -> Value {
    let (acquisition_id, acquisition_digest) = match existing {
        Some((id, digest)) => (json!(id), json!(digest)),
        None => (Value::Null, Value::Null),
    };
    merge_objects([
        json!({
            "rootReceiptId": uuid(1), "revision": 1, "receiptEffect": "ORIGINAL",
            "supersedesReceiptId": null, "predecessorReceiptDigest": null,
            "qualificationEpisodeId": uuid(2), "deploymentId": uuid(3),
            "organizationId": uuid(4), "sku": "EVIDENCE_WORKSPACE_ORGANIZATION_V1",
            "decisionEffectiveAt": "2026-08-02T00:00:00Z",
            "firstQualifiedAt": "2026-08-02T00:00:00Z", "recurringJobAttested": true,
            "authorizedDataIdentified": true, "authorizedDataFeasible": true,
            "economicBuyerRoleBound": true, "operationalOwnerRoleBound": true,
            "independentReviewerRoleBound": true
        }),
        json!({
            "sourceRightsOwnerRoleBound": true, "incidentSupportOwnerRoleBound": true,
            "pilotScopeAccepted": true, "successMetricAccepted": true,
            "budgetAuthorityAccepted": true, "supportExpectationAccepted": true,
            "trustTermsAccepted": true, "roleBindingHmacKeyVersion": "test-fixture-v1",
            "economicBuyerPrimaryRoleBindingHmac": digest('1'),
            "economicBuyerBackupRoleBindingHmac": digest('2'),
            "operationalOwnerPrimaryRoleBindingHmac": digest('1'),
            "operationalOwnerBackupRoleBindingHmac": digest('2'),
            "independentReviewerPrimaryRoleBindingHmac": digest('1'),
            "independentReviewerBackupRoleBindingHmac": digest('2'),
            "sourceRightsOwnerPrimaryRoleBindingHmac": digest('1'),
            "sourceRightsOwnerBackupRoleBindingHmac": digest('2'),
            "incidentSupportOwnerPrimaryRoleBindingHmac": digest('1'),
            "incidentSupportOwnerBackupRoleBindingHmac": digest('2')
        }),
        json!({
            "sourceSystemId": TEST_FIXTURE, "sourceRecordIdentityHmac": digest('3'),
            "acquisitionSourceReceiptId": acquisition_id,
            "acquisitionSourceReceiptDigest": acquisition_digest,
            "sourceSignatureDigest": digest('4'), "qualificationPolicyVersion": 1,
            "qualificationPolicyDigest": digest('5'), "criterionSetDigest": digest('6'),
            "roleBindingSetDigest": digest('7'), "evidenceSetDigest": digest('8'),
            "reasonCode": "QUALIFICATION_ACCEPTED", "expectedHeadId": null,
            "expectedHeadRevision": null, "expectedHeadDigest": null,
            "acquisitionSource": acquisition_source
        }),
    ])
}

fn acquisition_append() -> Value {
    json!({
        "resolution": "APPEND", "existingReceiptId": null,
        "existingReceiptRevision": null, "existingReceiptDigest": null,
        "appendValue": {
            "rootReceiptId": null, "revision": 1, "receiptEffect": "ORIGINAL",
            "supersedesReceiptId": null, "predecessorReceiptDigest": null,
            "deploymentId": uuid(3), "organizationId": uuid(4), "sourceKind": "REFERRAL",
            "sourceSystemId": TEST_FIXTURE, "sourceRecordIdentityHmac": digest('9'),
            "sourceRecordHmacKeyVersion": "test-fixture-v1",
            "acquisitionCampaignDigest": digest('a'), "organizationBindingDigest": digest('b'),
            "attributionModelVersion": "test-fixture-v1", "attributionModelDigest": digest('c'),
            "touchpointSetDigest": digest('d'), "sourceRecordDigest": digest('e'),
            "sourceSignatureDigest": digest('a'), "validFrom": "2026-07-01T00:00:00Z",
            "validUntil": "2026-09-01T00:00:00Z", "attributedAt": "2026-08-01T00:00:00Z",
            "receiptDigest": digest('f')
        },
        "evidenceSegmentId": uuid(30), "evidenceSegmentDigest": digest('1'),
        "sourceSignatureDigest": digest('a'), "expectedHeadId": null,
        "expectedHeadRevision": null, "expectedHeadDigest": null
    })
}

fn acquisition_existing() -> Value {
    json!({
        "resolution": "EXISTING", "existingReceiptId": uuid(31),
        "existingReceiptRevision": 2, "existingReceiptDigest": digest('b'),
        "appendValue": null, "evidenceSegmentId": uuid(32),
        "evidenceSegmentDigest": digest('c'), "sourceSignatureDigest": digest('d'),
        "expectedHeadId": uuid(31), "expectedHeadRevision": 2,
        "expectedHeadDigest": digest('b')
    })
}

fn cost_close(line: Value, fx_rates: Vec<Value>, amount: i64) -> Value {
    json!({ "period": cost_period(amount), "lines": [line], "fxRates": fx_rates })
}

fn cost_period(amount: i64) -> Value {
    json!({
        "periodRevisionId": uuid(40), "supersedesPeriodRevisionId": null,
        "deploymentId": uuid(3), "accountingTimezone": "Asia/Seoul",
        "accountingPolicyDigest": digest('1'), "periodStart": "2026-07-01",
        "periodEnd": "2026-08-01", "currency": "KRW", "periodVersion": 1,
        "sourceSetDigest": digest('2'), "poolSetDigest": digest('3'),
        "driverSetDigest": digest('4'), "correctionSetDigest": digest('5'),
        "expectedAllocationSetDigest": digest('6'), "expectedCapturedCostCount": 1,
        "expectedCostCount": 1, "expectedCostCaptureState": "MEASURED",
        "expectedCostCaptureCoverage": 1, "expectedDirectEligibleAmount": amount,
        "expectedDirectAllocatedAmount": amount, "expectedCapturedCostAmount": amount,
        "expectedAttributedCostAmount": amount, "expectedUnallocatedAmount": 0,
        "expectedDirectCoverage": 1, "expectedTotalCoverage": 1,
        "expectedClaimState": "ELIGIBLE", "incompleteReasonSetDigest": null,
        "unknownCostScopeDigest": null, "closeReceiptId": uuid(41),
        "closeReceiptDigest": digest('7'), "closedAt": "2026-08-02T00:00:00Z",
        "scheduleRevision": 1, "scheduleDigest": digest('8'),
        "expectedHeadId": null, "expectedHeadVersion": null, "expectedHeadDigest": null
    })
}

fn same_currency_line() -> Value {
    cost_line("KRW", 100, 100, None, None)
}

fn cross_currency_line(fact_id: Option<String>, ordinal: i32) -> Value {
    cost_line("USD", 100, 130_000, fact_id, Some(ordinal))
}

fn cost_line(
    source_currency: &str,
    source_amount: i64,
    reporting_amount: i64,
    fact_id: Option<String>,
    ordinal: Option<i32>,
) -> Value {
    json!({
        "lineSequence": 1, "allocationKind": "DIRECT", "costCategory": "COMPUTE",
        "sourceCostEventId": uuid(42), "sourceEffectiveDigest": digest('9'),
        "sourceCurrency": source_currency, "sourceAmount": source_amount,
        "fxRateFactId": fact_id, "fxSourceOrdinal": ordinal,
        "reportingSourceAmount": reporting_amount, "targetKind": "ORGANIZATION",
        "jobId": null, "agentRunId": null, "caseId": null, "organizationId": uuid(4),
        "outcomeFactId": null, "acquisitionCampaignDigest": null,
        "acquisitionSourceReceiptId": null, "acquisitionSourceReceiptDigest": null,
        "acquisitionAttributionState": null, "unattributedAcquisitionPoolDigest": null,
        "driverKind": "DIRECT_IDENTITY", "driverQuantity": null,
        "driverTotalQuantity": null, "allocationRatio": null, "roundingAdjustment": 0,
        "allocatedAmount": reporting_amount, "allocationRuleVersion": 1,
        "allocationRuleDigest": digest('a'), "scheduleRevision": 1,
        "scheduleDigest": digest('8')
    })
}

fn fx_append() -> Value {
    json!({
        "resolution": "APPEND", "existingRateId": null,
        "existingRateRevision": null, "existingRateDigest": null,
        "appendValue": {
            "rootRateId": null, "revision": 1, "factKind": "OBSERVATION",
            "supersedesRateId": null, "sourceCurrency": "USD", "targetCurrency": "KRW",
            "quoteConvention": "TARGET_PER_SOURCE", "rate": 1300,
            "rateKind": "DAILY_CLOSE", "sourceId": "test-fixture-fx",
            "sourceRecordIdentityHmac": digest('b'),
            "sourceRecordHmacKeyVersion": "test-fixture-v1", "sourcePriority": 0,
            "observedAt": "2026-07-31T00:00:00Z", "validUntil": "2026-08-02T00:00:00Z",
            "ratePolicyDigest": digest('c'), "sourceReceiptDigest": digest('d'),
            "signatureDigest": digest('e'), "correctionReason": null,
            "expectedRecordDigest": digest('f')
        },
        "evidenceSegmentId": uuid(45), "evidenceSegmentDigest": digest('1'),
        "sourceSignatureDigest": digest('e'), "expectedHeadId": null,
        "expectedHeadRevision": null, "expectedHeadDigest": null
    })
}

fn fx_existing() -> Value {
    json!({
        "resolution": "EXISTING", "existingRateId": uuid(43),
        "existingRateRevision": 2, "existingRateDigest": digest('2'),
        "appendValue": null, "evidenceSegmentId": uuid(46),
        "evidenceSegmentDigest": digest('3'), "sourceSignatureDigest": digest('4'),
        "expectedHeadId": uuid(43), "expectedHeadRevision": 2,
        "expectedHeadDigest": digest('2')
    })
}

fn qualification_is_valid(value: Value) -> bool {
    serde_json::from_value::<EconomicsQualificationImportV1>(value)
        .is_ok_and(|value| value.validate().is_ok())
}

fn qualification_parse_fails(value: Value) -> bool {
    serde_json::from_value::<EconomicsQualificationImportV1>(value).is_err()
}

fn cost_close_is_valid(value: Value) -> bool {
    serde_json::from_value::<EconomicsCostCloseImportV1>(value)
        .is_ok_and(|value| value.validate().is_ok())
}

fn cost_close_parse_fails(value: Value) -> bool {
    serde_json::from_value::<EconomicsCostCloseImportV1>(value).is_err()
}

fn remove_key(value: &mut Value, key: &str) {
    if let Some(object) = value.as_object_mut() {
        object.remove(key);
    }
}

fn merge_objects<const N: usize>(values: [Value; N]) -> Value {
    let mut merged = serde_json::Map::new();
    for value in values {
        if let Value::Object(object) = value {
            merged.extend(object);
        }
    }
    Value::Object(merged)
}

fn digest(fill: char) -> String {
    std::iter::repeat_n(fill, 64).collect()
}

fn uuid(value: u128) -> String {
    Uuid::from_u128(value).to_string()
}
