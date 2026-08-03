use super::{digest, merge_objects, uuid};
use serde_json::{Value, json};

pub(in super::super) fn tariff_version() -> Value {
    merge_objects([
        tariff_terms(),
        tariff_sla(),
        tariff_margin(),
        tariff_governance(),
    ])
}

fn tariff_terms() -> Value {
    json!({
        "operationId": "createTariffVersion",
        "deploymentId": uuid(1),
        "sku": "EVIDENCE_WORKSPACE_ORGANIZATION_V1",
        "currency": "KRW",
        "accountingTimezone": "Asia/Seoul",
        "accountingPolicyDigest": digest('1'),
        "effectiveFrom": "2026-08-01",
        "effectiveUntil": "2026-09-01",
        "workspaceBaseAmount": "100",
        "includedActiveContributors": 10,
        "activeContributorBlockSize": 10,
        "activeContributorBlockAmount": "0",
        "includedProcessingCredits": "0",
        "processingCreditOverageAmount": "0",
        "includedStorageGbMonth": "0",
        "storageGbMonthOverageAmount": "0"
    })
}

fn tariff_sla() -> Value {
    json!({
        "includedApiRecordUnits": "0",
        "apiRecordUnitOverageAmount": "0",
        "slaAddOnAmount": null,
        "slaOfferState": "UNCONFIGURED_NOT_SOLD",
        "slaPolicyVersion": null,
        "slaPolicyDigest": null,
        "slaTargetAvailabilityRatio": null,
        "slaCapabilitySetDigest": null,
        "slaExclusionScheduleDigest": null,
        "slaServiceCreditScheduleDigest": null,
        "slaMeasurementPolicyDigest": null,
        "slaPolicySourceReceiptDigest": null,
        "slaPolicySignatureDigest": null,
        "includedSignedWebhookDeliveries": 0,
        "includedDigestDeliveries": 0,
        "expectedRequiredVariableGrossMarginBasisPoints": 6000,
        "expectedProjectedP75VariableGrossMarginBasisPoints": 6000
    })
}

fn tariff_margin() -> Value {
    json!({
        "p75AssumptionDigest": digest('2'),
        "costAllocationPeriodId": uuid(201),
        "costAllocationRowKind": "PERIOD",
        "costAllocationRecordDigest": digest('3'),
        "costAllocationSetDigest": digest('4'),
        "costAllocationCloseReceiptDigest": digest('5'),
        "costCaptureCoverage": "1",
        "directCostCoverage": "1",
        "totalCostCoverage": "1",
        "p75RevenueAmount": "100",
        "p75VariableCostAmount": "40",
        "marginFormulaDigest": digest('6'),
        "marginEvidenceAsOf": "2026-08-02T00:00:00Z",
        "marginExceptionReason": null
    })
}

fn tariff_governance() -> Value {
    json!({
        "componentSetDigest": digest('a'),
        "pricingPolicyDigest": digest('b'),
        "taxPolicyDigest": digest('c'),
        "sourceReceiptDigest": digest('e'),
        "signatureDigest": digest('f'),
        "expectedCostHeadId": uuid(201),
        "expectedCostHeadVersion": 1,
        "expectedCostHeadDigest": digest('3'),
        "expectedCurrentTariffId": null,
        "expectedCurrentTariffDigest": null
    })
}

pub(in super::super) fn commercial_contract_period() -> Value {
    merge_objects([
        contract_identity(),
        contract_offer(),
        contract_service_level(),
        contract_governance(),
    ])
}

fn contract_identity() -> Value {
    json!({
        "operationId": "recordCommercialContractPeriod",
        "deploymentId": uuid(1),
        "organizationId": uuid(2),
        "contractId": uuid(401),
        "rootContractPeriodId": uuid(402),
        "revision": 1,
        "factEffect": "ORIGINAL",
        "supersedesContractPeriodId": null,
        "predecessorRecordDigest": null,
        "contractReferenceHmac": digest('1'),
        "contractReferenceHmacKeyVersion": "test-fixture-v1",
        "periodStart": "2026-08-01",
        "periodEnd": "2026-09-01",
        "sku": "EVIDENCE_WORKSPACE_ORGANIZATION_V1",
        "tariffVersionId": uuid(403),
        "tariffRecordDigest": digest('2')
    })
}

fn contract_offer() -> Value {
    json!({
        "qualificationReceiptId": uuid(101),
        "qualificationEpisodeId": uuid(102),
        "qualificationReceiptDigest": digest('3'),
        "offerContractBindingDigest": digest('4'),
        "offerProfileId": uuid(404),
        "offerProfileVersion": 1,
        "offerProfileDigest": digest('5'),
        "offerCapabilitySetDigest": digest('6'),
        "offerQuotaSetDigest": digest('a'),
        "offerOveragePolicySetDigest": digest('b'),
        "offerServiceCreditPolicyDigest": digest('c'),
        "offerEffectiveFrom": "2026-07-01T00:00:00Z",
        "offerEffectiveUntil": "2026-09-01T00:00:00Z",
        "offerSourceReceiptDigest": digest('d'),
        "offerSignatureDigest": digest('e'),
        "currency": "KRW"
    })
}

fn contract_service_level() -> Value {
    json!({
        "accountingTimezone": "Asia/Seoul",
        "accountingPolicyDigest": digest('f'),
        "bindingCommittedAmount": "100",
        "commitmentPolicyDigest": digest('1'),
        "status": "ACTIVE",
        "stage": "PILOT",
        "provisioningState": "PROVISIONED",
        "slaAddOnSelected": false,
        "slaSelectionState": "UNAVAILABLE_NOT_SOLD",
        "slaPolicyVersion": null,
        "slaPolicyDigest": null,
        "slaTargetAvailabilityRatio": null,
        "slaCapabilitySetDigest": null,
        "slaExclusionScheduleDigest": null,
        "slaServiceCreditScheduleDigest": null,
        "slaMeasurementPolicyDigest": null
    })
}

fn contract_governance() -> Value {
    json!({
        "signedAt": "2026-07-02T00:00:00Z",
        "provisionedAt": "2026-07-03T00:00:00Z",
        "stateEffectiveAt": "2026-08-01T00:00:00Z",
        "deploymentConfigurationDigest": digest('2'),
        "authorityReferenceDigest": digest('3'),
        "sourceReceiptDigest": digest('5'),
        "signatureDigest": digest('6'),
        "expectedHeadId": null,
        "expectedHeadRevision": null,
        "expectedHeadDigest": null,
        "collectionFailureTaskId": null,
        "collectionFailureTaskVersion": null,
        "collectionFailureTaskDigest": null,
        "capabilities": capability_set()
    })
}

fn capability_set() -> Vec<Value> {
    const CODES: [&str; 12] = [
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
    ];
    CODES
        .into_iter()
        .enumerate()
        .map(|(index, code)| {
            let public_web = index == 0;
            json!({
                "capabilityOrdinal": index + 1,
                "capabilityCode": code,
                "offerState": if public_web { "INCLUDED_REQUIRED" } else { "NOT_OFFERED" },
                "quotaKind": "NOT_METERED",
                "includedQuantity": null,
                "overagePolicy": "NOT_APPLICABLE",
                "overageUnitPrice": null,
                "activationPolicyDigest": null,
                "consentPolicyDigest": null,
                "costPolicyDigest": null
            })
        })
        .collect()
}
