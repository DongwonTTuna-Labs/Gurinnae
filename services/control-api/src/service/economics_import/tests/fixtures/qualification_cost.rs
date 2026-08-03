use super::{digest, merge_objects, uuid};
use serde_json::{Value, json};

pub(in super::super) fn commercial_qualification() -> Value {
    merge_objects([
        json!({
            "operationId": "recordCommercialQualification",
            "rootReceiptId": uuid(101),
            "revision": 1,
            "receiptEffect": "ORIGINAL",
            "supersedesReceiptId": null,
            "predecessorReceiptDigest": null,
            "qualificationEpisodeId": uuid(102),
            "deploymentId": uuid(1),
            "organizationId": uuid(2),
            "sku": "EVIDENCE_WORKSPACE_ORGANIZATION_V1",
            "decisionEffectiveAt": "2026-08-02T00:00:00Z",
            "firstQualifiedAt": "2026-08-02T00:00:00Z",
            "recurringJobAttested": true,
            "authorizedDataIdentified": true,
            "authorizedDataFeasible": true,
            "economicBuyerRoleBound": true,
            "operationalOwnerRoleBound": true,
            "independentReviewerRoleBound": true
        }),
        json!({
            "sourceRightsOwnerRoleBound": true,
            "incidentSupportOwnerRoleBound": true,
            "pilotScopeAccepted": true,
            "successMetricAccepted": true,
            "budgetAuthorityAccepted": true,
            "supportExpectationAccepted": true,
            "trustTermsAccepted": true,
            "roleBindingHmacKeyVersion": "test-fixture-v1",
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
            "sourceSystemId": "test_fixture",
            "sourceRecordIdentityHmac": digest('3'),
            "acquisitionSourceReceiptId": uuid(150),
            "acquisitionSourceReceiptDigest": digest('7'),
            "sourceSignatureDigest": digest('4'),
            "qualificationPolicyVersion": 1,
            "qualificationPolicyDigest": digest('5'),
            "criterionSetDigest": digest('6'),
            "roleBindingSetDigest": digest('a'),
            "evidenceSetDigest": digest('b'),
            "reasonCode": "QUALIFICATION_ACCEPTED",
            "expectedHeadId": null,
            "expectedHeadRevision": null,
            "expectedHeadDigest": null,
            "acquisitionSource": existing_acquisition_source()
        }),
    ])
}

pub(in super::super) fn commercial_qualification_with_acquisition_source(
    resolution: &str,
) -> Value {
    let mut value = commercial_qualification();
    if resolution == "APPEND" {
        value["acquisitionSourceReceiptId"] = Value::Null;
        value["acquisitionSourceReceiptDigest"] = Value::Null;
        value["acquisitionSource"] = appended_acquisition_source();
    }
    value
}

fn existing_acquisition_source() -> Value {
    json!({
        "resolution": "EXISTING",
        "existingReceiptId": uuid(150),
        "existingReceiptRevision": 1,
        "existingReceiptDigest": digest('7'),
        "appendValue": null,
        "evidenceSegmentId": uuid(10_001),
        "evidenceSegmentDigest": digest('1'),
        "sourceSignatureDigest": digest('8'),
        "expectedHeadId": uuid(150),
        "expectedHeadRevision": 1,
        "expectedHeadDigest": digest('7')
    })
}

fn appended_acquisition_source() -> Value {
    json!({
        "resolution": "APPEND",
        "existingReceiptId": null,
        "existingReceiptRevision": null,
        "existingReceiptDigest": null,
        "appendValue": appended_acquisition_receipt(),
        "evidenceSegmentId": uuid(10_001),
        "evidenceSegmentDigest": digest('1'),
        "sourceSignatureDigest": digest('8'),
        "expectedHeadId": null,
        "expectedHeadRevision": null,
        "expectedHeadDigest": null
    })
}

fn appended_acquisition_receipt() -> Value {
    json!({
        "rootReceiptId": null,
        "revision": 1,
        "receiptEffect": "ORIGINAL",
        "supersedesReceiptId": null,
        "predecessorReceiptDigest": null,
        "deploymentId": uuid(1),
        "organizationId": uuid(2),
        "sourceKind": "DIRECT",
        "sourceSystemId": "test_fixture",
        "sourceRecordIdentityHmac": digest('9'),
        "sourceRecordHmacKeyVersion": "test-fixture-v1",
        "acquisitionCampaignDigest": digest('a'),
        "organizationBindingDigest": digest('b'),
        "attributionModelVersion": "test-fixture-v1",
        "attributionModelDigest": digest('c'),
        "touchpointSetDigest": digest('d'),
        "sourceRecordDigest": digest('e'),
        "sourceSignatureDigest": digest('8'),
        "validFrom": "2026-07-01T00:00:00Z",
        "validUntil": "2026-09-01T00:00:00Z",
        "attributedAt": "2026-07-02T00:00:00Z",
        "receiptDigest": digest('7')
    })
}

pub(in super::super) fn cost_allocation_close() -> Value {
    json!({
        "operationId": "importCostAllocationClose",
        "period": cost_period(),
        "lines": [cost_line()],
        "fxRates": []
    })
}

pub(in super::super) fn cost_allocation_close_with_fx_source(resolution: &str) -> Value {
    let mut value = cost_allocation_close();
    for key in [
        "expectedDirectEligibleAmount",
        "expectedDirectAllocatedAmount",
        "expectedCapturedCostAmount",
        "expectedAttributedCostAmount",
    ] {
        value["period"][key] = json!("130");
    }
    value["lines"][0]["sourceCurrency"] = json!("USD");
    value["lines"][0]["fxSourceOrdinal"] = json!(1);
    value["lines"][0]["reportingSourceAmount"] = json!("130");
    value["lines"][0]["allocatedAmount"] = json!("130");
    value["fxRates"] = match resolution {
        "EXISTING" => {
            value["lines"][0]["fxRateFactId"] = json!(uuid(250));
            json!([existing_fx_source()])
        }
        "APPEND" => json!([appended_fx_source()]),
        _ => json!([]),
    };
    value
}

fn existing_fx_source() -> Value {
    json!({
        "resolution": "EXISTING",
        "existingRateId": uuid(250),
        "existingRateRevision": 1,
        "existingRateDigest": digest('7'),
        "appendValue": null,
        "evidenceSegmentId": uuid(10_001),
        "evidenceSegmentDigest": digest('1'),
        "sourceSignatureDigest": digest('8'),
        "expectedHeadId": uuid(250),
        "expectedHeadRevision": 1,
        "expectedHeadDigest": digest('7')
    })
}

fn appended_fx_source() -> Value {
    json!({
        "resolution": "APPEND",
        "existingRateId": null,
        "existingRateRevision": null,
        "existingRateDigest": null,
        "appendValue": appended_fx_rate(),
        "evidenceSegmentId": uuid(10_001),
        "evidenceSegmentDigest": digest('1'),
        "sourceSignatureDigest": digest('8'),
        "expectedHeadId": null,
        "expectedHeadRevision": null,
        "expectedHeadDigest": null
    })
}

fn appended_fx_rate() -> Value {
    json!({
        "rootRateId": null,
        "revision": 1,
        "factKind": "OBSERVATION",
        "supersedesRateId": null,
        "sourceCurrency": "USD",
        "targetCurrency": "KRW",
        "quoteConvention": "TARGET_PER_SOURCE",
        "rate": "1.3",
        "rateKind": "TRANSACTION",
        "sourceId": "test_fixture",
        "sourceRecordIdentityHmac": digest('9'),
        "sourceRecordHmacKeyVersion": "test-fixture-v1",
        "sourcePriority": 0,
        "observedAt": "2026-07-01T00:00:00Z",
        "validUntil": "2026-09-01T00:00:00Z",
        "ratePolicyDigest": digest('a'),
        "sourceReceiptDigest": digest('b'),
        "signatureDigest": digest('8'),
        "correctionReason": null,
        "expectedRecordDigest": digest('7')
    })
}

fn cost_period() -> Value {
    merge_objects([
        json!({
            "periodRevisionId": uuid(201),
            "supersedesPeriodRevisionId": null,
            "deploymentId": uuid(1),
            "accountingTimezone": "Asia/Seoul",
            "accountingPolicyDigest": digest('1'),
            "periodStart": "2026-07-01",
            "periodEnd": "2026-08-01",
            "currency": "KRW",
            "periodVersion": 1,
            "sourceSetDigest": digest('2'),
            "poolSetDigest": digest('3'),
            "driverSetDigest": digest('4'),
            "correctionSetDigest": digest('5'),
            "expectedAllocationSetDigest": digest('6'),
            "expectedCapturedCostCount": 1,
            "expectedCostCount": 1,
            "expectedCostCaptureState": "MEASURED",
            "expectedCostCaptureCoverage": "1"
        }),
        json!({
            "expectedDirectEligibleAmount": "100",
            "expectedDirectAllocatedAmount": "100",
            "expectedCapturedCostAmount": "100",
            "expectedAttributedCostAmount": "100",
            "expectedUnallocatedAmount": "0",
            "expectedDirectCoverage": "1",
            "expectedTotalCoverage": "1",
            "expectedClaimState": "ELIGIBLE",
            "incompleteReasonSetDigest": null,
            "unknownCostScopeDigest": null,
            "closeReceiptId": uuid(202),
            "closeReceiptDigest": digest('a'),
            "closedAt": "2026-08-02T00:00:00Z",
            "scheduleRevision": 1,
            "scheduleDigest": digest('b'),
            "expectedHeadId": null,
            "expectedHeadVersion": null,
            "expectedHeadDigest": null
        }),
    ])
}

fn cost_line() -> Value {
    merge_objects([
        json!({
            "lineSequence": 1,
            "allocationKind": "DIRECT",
            "costCategory": "COMPUTE",
            "sourceCostEventId": uuid(203),
            "sourceEffectiveDigest": digest('c'),
            "sourceCurrency": "KRW",
            "sourceAmount": "100",
            "fxRateFactId": null,
            "fxSourceOrdinal": null,
            "reportingSourceAmount": "100",
            "targetKind": "ORGANIZATION",
            "jobId": null,
            "agentRunId": null,
            "caseId": null,
            "organizationId": uuid(2),
            "outcomeFactId": null,
            "acquisitionCampaignDigest": null,
            "acquisitionSourceReceiptId": null,
            "acquisitionSourceReceiptDigest": null,
            "acquisitionAttributionState": null,
            "unattributedAcquisitionPoolDigest": null
        }),
        json!({
            "driverKind": "DIRECT_IDENTITY",
            "driverQuantity": null,
            "driverTotalQuantity": null,
            "allocationRatio": null,
            "roundingAdjustment": "0",
            "allocatedAmount": "100",
            "allocationRuleVersion": 1,
            "allocationRuleDigest": digest('d'),
            "scheduleRevision": 1,
            "scheduleDigest": digest('b')
        }),
    ])
}
