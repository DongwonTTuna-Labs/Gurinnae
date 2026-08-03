use super::{digest, merge_objects, uuid};
use serde_json::{Value, json};

pub(in super::super) fn revenue() -> Value {
    json!({
        "operationId": "recordRevenue",
        "expectedInvoiceId": uuid(601),
        "expectedInvoiceRevision": 1,
        "expectedInvoiceRecordDigest": digest('f'),
        "expectedInvoiceReconciliationDigest": digest('1'),
        "rows": [{
            "deploymentId": uuid(1),
            "organizationId": uuid(2),
            "contractPeriodId": uuid(3),
            "contractId": uuid(4),
            "invoiceId": uuid(601),
            "invoiceLineId": uuid(602),
            "invoiceLineDigest": digest('7'),
            "sku": "EVIDENCE_WORKSPACE_ORGANIZATION_V1",
            "accountingTimezone": "Asia/Seoul",
            "recognitionPeriodStart": "2026-07-01",
            "recognitionPeriodEnd": "2026-08-01",
            "amount": "100",
            "currency": "KRW",
            "recognitionPolicyVersion": "test-fixture-v1",
            "accountingPolicyDigest": digest('2'),
            "sourceReceiptDigest": digest('3'),
            "sourceRecordDigest": digest('4'),
            "signatureDigest": digest('5'),
            "importReceiptDigest": digest('6'),
            "recognizedAt": "2026-08-02T00:00:00Z"
        }]
    })
}

pub(in super::super) fn accounting_correction() -> Value {
    let row = merge_objects([
        json!({
            "deploymentId": uuid(1),
            "scopeKind": "DEPLOYMENT",
            "organizationId": null,
            "accountingTimezone": "Asia/Seoul",
            "accountingPolicyDigest": digest('1'),
            "rootCorrectionId": uuid(701),
            "revision": 1,
            "correctionSequence": 1,
            "correctionKind": "ADJUSTMENT",
            "supersedesCorrectionId": null,
            "reversesCorrectionId": null,
            "predecessorCorrectionDigest": null,
            "sourceSystemId": "test_fixture",
            "sourceRecordIdentityDigest": digest('2'),
            "correctionIdentityDigest": digest('3'),
            "targetFactKind": "INVOICE_FACT",
            "targetAmountKind": "INVOICE_TOTAL",
            "targetFactId": uuid(601),
            "targetCostEventId": null,
            "targetCostAllocationId": null
        }),
        json!({
            "targetInvoiceFactId": uuid(601),
            "targetInvoiceLineFactId": null,
            "targetRevenueFactId": null,
            "targetFactDigest": digest('4'),
            "periodStart": "2026-07-01",
            "periodEnd": "2026-08-01",
            "amount": "10",
            "effectiveDelta": "10",
            "expectedResultingEffectiveAmount": "110",
            "expectedResultingCorrectionSetDigest": digest('5'),
            "currency": "KRW",
            "reasonCode": "LATE_PROVIDER_INVOICE",
            "sourceReceiptDigest": digest('a'),
            "signatureDigest": digest('b'),
            "expectedHeadId": null,
            "expectedHeadRevision": null,
            "expectedHeadDigest": null
        }),
    ]);
    json!({
        "operationId": "recordAccountingCorrection",
        "rows": [row]
    })
}

pub(in super::super) fn cash_application(source_kind: &str) -> Value {
    json!({
        "operationId": "recordCashApplication",
        "rows": [{
            "rootFactId": uuid(801),
            "revision": 1,
            "factEffect": "ORIGINAL",
            "supersedesFactId": null,
            "predecessorFactDigest": null,
            "invoiceFactId": uuid(601),
            "invoiceFactDigest": digest('1'),
            "invoiceReconciliationDigest": digest('2'),
            "sourceKind": source_kind,
            "sourceSystemId": "test_fixture",
            "sourceSettlementIdentityHmac": digest('3'),
            "sourceSettlementHmacKeyVersion": "test-fixture-v1",
            "sourceSettlementAmount": "110",
            "appliedAmount": "110",
            "currency": "KRW",
            "sourceRecordDigest": digest('4'),
            "sourceSignatureDigest": digest('5'),
            "importReceiptDigest": digest('6'),
            "appliedAt": "2026-08-02T00:00:00Z",
            "expectedInvoiceRevision": 1,
            "expectedHeadId": null,
            "expectedHeadRevision": null,
            "expectedHeadDigest": null
        }]
    })
}

pub(in super::super) fn tax_invoice() -> Value {
    json!({
        "operationId": "recordTaxInvoiceIssuance",
        "rows": [{
            "rootReceiptId": uuid(901),
            "revision": 1,
            "receiptEffect": "ORIGINAL",
            "supersedesReceiptId": null,
            "predecessorReceiptDigest": null,
            "invoiceFactId": uuid(601),
            "invoiceFactDigest": digest('1'),
            "invoiceReconciliationDigest": digest('2'),
            "taxableAmount": "100",
            "taxAmount": "10",
            "currency": "KRW",
            "issuanceState": "ISSUED_CONFIRMED",
            "approvalNumberHmac": digest('3'),
            "approvalNumberHmacKeyVersion": "test-fixture-v1",
            "aspReceiptReferenceHmac": digest('4'),
            "aspReceiptReferenceHmacKeyVersion": "test-fixture-v1",
            "aspReceiptDigest": digest('5'),
            "sourceSystemId": "test_fixture",
            "sourceRecordDigest": digest('6'),
            "sourceSignatureDigest": digest('a'),
            "importReceiptDigest": digest('b'),
            "issuedAt": "2026-08-02T00:00:00Z",
            "cancelledAt": null,
            "expectedInvoiceRevision": 1,
            "expectedHeadId": null,
            "expectedHeadRevision": null,
            "expectedHeadDigest": null
        }]
    })
}

pub(in super::super) fn collection_failure(authority_kind: &str) -> Value {
    let provider = authority_kind == "PROVIDER_FETCH_CONFIRMED";
    json!({
        "operationId": "recordCollectionFailure",
        "authorityKind": authority_kind,
        "providerChargeAttemptId": provider.then(|| uuid(1_001)),
        "providerChargeAttemptDigest": provider.then(|| digest('1')),
        "providerFetchDigest": provider.then(|| digest('2')),
        "invoiceFactId": (!provider).then(|| uuid(601)),
        "invoiceFactDigest": (!provider).then(|| digest('3')),
        "invoiceReconciliationDigest": (!provider).then(|| digest('4')),
        "expectedInvoiceRevision": (!provider).then_some(1),
        "signedEvidenceSegmentId": (!provider).then(|| uuid(1_002)),
        "signedEvidenceSegmentDigest": (!provider).then(|| digest('5')),
        "taskAssigneeId": uuid(1_003),
        "taskDueAt": "2026-08-03T00:00:00Z",
        "reasonCode": "TEST_FIXTURE_CONFIRMED_FAILURE",
        "reasonDigest": digest('6')
    })
}
