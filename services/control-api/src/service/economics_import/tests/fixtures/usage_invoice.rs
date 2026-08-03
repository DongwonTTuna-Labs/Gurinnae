use super::{digest, merge_objects, uuid};
use serde_json::{Value, json};

pub(in super::super) fn usage_window() -> Value {
    json!({
        "operationId": "recordUsageWindow",
        "receipt": usage_receipt(),
        "fact": usage_fact()
    })
}

fn usage_receipt() -> Value {
    merge_objects([
        json!({
            "rootReceiptId": uuid(501),
            "receiptVersion": 1,
            "receiptEffect": "ORIGINAL",
            "supersedesReceiptId": null,
            "predecessorReceiptDigest": null,
            "deploymentId": uuid(1),
            "organizationId": uuid(2),
            "contractPeriodId": uuid(402),
            "contractId": uuid(401),
            "tariffVersionId": uuid(403),
            "sku": "EVIDENCE_WORKSPACE_ORGANIZATION_V1",
            "accountingTimezone": "Asia/Seoul",
            "accountingPolicyDigest": digest('1'),
            "periodStart": "2026-08-01",
            "periodEnd": "2026-09-01",
            "measurementWindowDigest": digest('2'),
            "receiptKind": "IDENTITY_USAGE_WINDOW",
            "meterKind": "SEAT",
            "unit": "COUNT",
            "measurementState": "COMPLETE",
            "expectedItemCount": 1,
            "observedItemCount": 1,
            "observedQuantity": "1",
            "normalizationBasisKind": "ACTIVE_CONTRIBUTOR_COUNT"
        }),
        json!({
            "normalizationInputQuantity": "1",
            "coverageDigest": digest('3'),
            "sourceSystemId": "test_fixture",
            "sourceWindowIdentityHmac": digest('4'),
            "sourceWindowHmacKeyVersion": "test-fixture-v1",
            "sourceCursorSetDigest": digest('5'),
            "sourceRecordSetDigest": digest('6'),
            "sourceSignatureDigest": digest('a'),
            "meterPolicyVersion": "test-fixture-v1",
            "meterPolicyDigest": digest('b'),
            "measuredAt": "2026-09-01T00:00:00Z",
            "expectedHeadId": null,
            "expectedHeadVersion": null,
            "expectedHeadDigest": null
        }),
    ])
}

fn usage_fact() -> Value {
    merge_objects([
        json!({
            "rootUsageFactId": uuid(502),
            "revision": 1,
            "factEffect": "ORIGINAL",
            "supersedesUsageFactId": null,
            "predecessorRecordDigest": null,
            "deploymentId": uuid(1),
            "organizationId": uuid(2),
            "contractPeriodId": uuid(402),
            "contractId": uuid(401),
            "tariffVersionId": uuid(403),
            "sku": "EVIDENCE_WORKSPACE_ORGANIZATION_V1",
            "accountingTimezone": "Asia/Seoul",
            "accountingPolicyDigest": digest('1'),
            "periodStart": "2026-08-01",
            "periodEnd": "2026-09-01",
            "measurementWindowDigest": digest('2'),
            "measurementState": "COMPLETE",
            "expectedItemCount": 1,
            "observedItemCount": 1,
            "coverageDigest": digest('3'),
            "meterKind": "SEAT",
            "unit": "COUNT",
            "quantity": "1"
        }),
        json!({
            "billableMetric": "ACTIVE_CONTRIBUTOR",
            "billableQuantity": "1",
            "billableUnit": "CONTRIBUTOR_MONTH",
            "conversionPolicyDigest": digest('c'),
            "sourceReceiptKind": "IDENTITY_USAGE_WINDOW",
            "sourceReceiptId": uuid(501),
            "sourceReceiptVersion": 1,
            "sourceReceiptDigest": digest('d'),
            "meterPolicyVersion": "test-fixture-v1",
            "meterPolicyDigest": digest('b'),
            "measuredAt": "2026-09-01T00:00:00Z",
            "expectedHeadId": null,
            "expectedHeadRevision": null,
            "expectedHeadDigest": null
        }),
    ])
}

pub(in super::super) fn invoice() -> Value {
    json!({
        "operationId": "recordInvoice",
        "invoice": invoice_header(),
        "lines": [invoice_line()],
        "memberships": [],
        "discounts": []
    })
}

pub(in super::super) fn invoice_with_discount_source(resolution: &str) -> Value {
    let mut value = invoice();
    value["invoice"]["expectedDiscountTotal"] = json!("10");
    value["invoice"]["expectedTaxableAmount"] = json!("90");
    value["invoice"]["expectedTaxTotal"] = json!("9");
    value["invoice"]["expectedInvoiceTotal"] = json!("99");
    value["lines"][0]["expectedDiscountAmount"] = json!("10");
    value["lines"][0]["expectedTaxableAmount"] = json!("90");
    value["lines"][0]["expectedTaxAmount"] = json!("9");
    value["lines"][0]["expectedLineTotal"] = json!("99");
    value["lines"][0]["discountSourceOrdinal"] = json!(1);
    value["discounts"] = match resolution {
        "EXISTING" => {
            value["lines"][0]["discountDecisionId"] = json!(uuid(610));
            value["lines"][0]["discountRecordDigest"] = json!(digest('7'));
            json!([existing_discount_source()])
        }
        "APPEND" => json!([appended_discount_source()]),
        _ => json!([]),
    };
    value
}

fn existing_discount_source() -> Value {
    json!({
        "resolution": "EXISTING",
        "existingDiscountId": uuid(610),
        "existingDiscountRevision": 1,
        "existingDiscountDigest": digest('7'),
        "appendValue": null,
        "evidenceSegmentId": uuid(10_001),
        "evidenceSegmentDigest": digest('1'),
        "sourceSignatureDigest": digest('8'),
        "expectedHeadId": uuid(610),
        "expectedHeadRevision": 1,
        "expectedHeadDigest": digest('7')
    })
}

fn appended_discount_source() -> Value {
    json!({
        "resolution": "APPEND",
        "existingDiscountId": null,
        "existingDiscountRevision": null,
        "existingDiscountDigest": null,
        "appendValue": appended_discount(),
        "evidenceSegmentId": uuid(10_001),
        "evidenceSegmentDigest": digest('1'),
        "sourceSignatureDigest": digest('8'),
        "expectedHeadId": null,
        "expectedHeadRevision": null,
        "expectedHeadDigest": null
    })
}

fn appended_discount() -> Value {
    merge_objects([
        json!({
            "deploymentId": uuid(1),
            "organizationId": uuid(2),
            "contractPeriodId": uuid(402),
            "contractId": uuid(401),
            "sku": "EVIDENCE_WORKSPACE_ORGANIZATION_V1",
            "tariffVersionId": uuid(403),
            "tariffRecordDigest": digest('6'),
            "accountingTimezone": "Asia/Seoul",
            "accountingPolicyDigest": digest('4'),
            "rootDiscountId": null,
            "revision": 1,
            "state": "ACTIVE",
            "supersedesDiscountId": null,
            "appliesWorkspaceBase": true,
            "appliesActiveContributorBlock": false,
            "appliesProcessingCreditOverage": false
        }),
        json!({
            "appliesStorageGbMonthOverage": false,
            "appliesApiRecordUnitOverage": false,
            "appliesSlaAddOn": false,
            "basisPoints": 1000,
            "reasonCode": "CONTRACTED",
            "effectiveFrom": "2026-08-01",
            "effectiveUntil": "2026-09-01",
            "requiredVariableGrossMarginBasisPoints": 6000,
            "projectedMarginAfterDiscountBasisPoints": 7000,
            "marginAssumptionDigest": digest('9'),
            "expectedResultingDiscountSetDigest": digest('a'),
            "undiscountedP75RevenueAmount": "100",
            "discountedP75RevenueAmount": "90",
            "p75VariableCostAmount": "27",
            "costEvidenceDigest": digest('b'),
            "marginFormulaDigest": digest('c')
        }),
        json!({
            "marginEvidenceAsOf": "2026-08-02T00:00:00Z",
            "oversightReason": null,
            "sourceReceiptDigest": digest('e'),
            "signatureDigest": digest('8'),
            "expectedRecordDigest": digest('7')
        }),
    ])
}

fn invoice_header() -> Value {
    merge_objects([
        json!({
            "rootInvoiceId": uuid(601),
            "invoiceRevision": 1,
            "invoiceEffect": "ORIGINAL",
            "supersedesInvoiceId": null,
            "predecessorReconciliationDigest": null,
            "deploymentId": uuid(1),
            "organizationId": uuid(2),
            "contractPeriodId": uuid(402),
            "contractId": uuid(401),
            "sku": "EVIDENCE_WORKSPACE_ORGANIZATION_V1",
            "accountingTimezone": "Asia/Seoul",
            "sourceSystemId": "test_fixture",
            "externalInvoiceReferenceDigest": digest('1'),
            "periodStart": "2026-08-01",
            "periodEnd": "2026-09-01",
            "billingCutoffAt": "2026-09-01T00:00:00Z",
            "currency": "KRW",
            "expectedLineCount": 1,
            "expectedLineSetDigest": digest('2'),
            "expectedUsageMembershipCount": 0,
            "expectedUsageMembershipSetDigest": digest('3'),
            "expectedUsageFactSetDigest": digest('4'),
            "expectedUsageWindowReceiptSetDigest": digest('5'),
            "expectedTariffSetDigest": digest('6')
        }),
        json!({
            "expectedDiscountLeafSetDigest": digest('a'),
            "expectedCorrectionSetDigest": digest('b'),
            "expectedContractStateIntervalSetDigest": digest('c'),
            "taxPolicyDigest": digest('d'),
            "roundingPolicyDigest": digest('e'),
            "expectedSubtotal": "100",
            "expectedDiscountTotal": "0",
            "expectedTaxableAmount": "100",
            "expectedTaxTotal": "10",
            "expectedCorrectionTotal": "0",
            "expectedInvoiceTotal": "110",
            "providerReceiptDigest": digest('f'),
            "sourceRecordDigest": digest('1'),
            "signatureDigest": digest('2'),
            "importReceiptDigest": digest('3'),
            "accountingPolicyDigest": digest('4'),
            "expectedReconciliationDigest": digest('5'),
            "reconciledAt": "2026-09-01T00:00:01Z",
            "expectedHeadId": null,
            "expectedHeadRevision": null,
            "expectedHeadReconciliationDigest": null
        }),
    ])
}

fn invoice_line() -> Value {
    merge_objects([
        json!({
            "lineOrdinal": 1,
            "lineKind": "WORKSPACE_BASE",
            "sku": "EVIDENCE_WORKSPACE_ORGANIZATION_V1",
            "servicePeriodStart": "2026-08-01",
            "servicePeriodEnd": "2026-09-01",
            "usageFactId": null,
            "usageFactDigest": null,
            "tariffVersionId": uuid(403),
            "tariffRecordDigest": digest('6'),
            "discountDecisionId": null,
            "discountRecordDigest": null,
            "discountSourceOrdinal": null,
            "correctsLineId": null,
            "meterKind": null,
            "quantity": "1",
            "unitPrice": "100",
            "expectedSubtotal": "100",
            "expectedDiscountAmount": "0",
            "expectedTaxableAmount": "100",
            "taxCategory": "STANDARD"
        }),
        json!({
            "taxRateBasisPoints": 1000,
            "taxExemptionDigest": null,
            "taxPolicyDigest": digest('d'),
            "expectedTaxAmount": "10",
            "expectedCorrectionAmount": "0",
            "correctionSetDigest": digest('b'),
            "roundingPolicyDigest": digest('e'),
            "expectedLineTotal": "110",
            "currency": "KRW",
            "sourceLineDigest": digest('a')
        }),
    ])
}
