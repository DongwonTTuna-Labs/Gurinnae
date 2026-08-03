//! Closed public-wire JSON fixtures for the economics importer.
//!
//! Every amount, identifier, digest, and authority marker in this module is
//! `TEST_FIXTURE` data. It is only evidence that the typed boundary is
//! executable and is never production pricing, accounting, or approval
//! authority.

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

mod accounting_cash;
mod qualification_cost;
mod tariff_contract;
mod usage_invoice;

pub(super) use accounting_cash::*;
pub(super) use qualification_cost::*;
pub(super) use tariff_contract::*;
pub(super) use usage_invoice::*;

pub(super) fn digest(byte: char) -> String {
    let canonical_test_fixture = format!("TEST_FIXTURE_NO_PRODUCTION_AUTHORITY:R6E:{byte}");
    format!("{:x}", Sha256::digest(canonical_test_fixture.as_bytes()))
}

pub(super) fn uuid(value: u128) -> String {
    Uuid::from_u128(value).to_string()
}

pub(super) fn merge_objects<const N: usize>(parts: [Value; N]) -> Value {
    let mut merged = Map::new();
    for part in parts {
        if let Value::Object(fields) = part {
            merged.extend(fields);
        }
    }
    Value::Object(merged)
}

pub(super) fn all_operations() -> Vec<(&'static str, Value)> {
    vec![
        ("recordCommercialQualification", commercial_qualification()),
        ("importCostAllocationClose", cost_allocation_close()),
        ("createTariffVersion", tariff_version()),
        (
            "recordCommercialContractPeriod",
            commercial_contract_period(),
        ),
        ("recordUsageWindow", usage_window()),
        ("recordInvoice", invoice()),
        ("recordRevenue", revenue()),
        ("recordAccountingCorrection", accounting_correction()),
        ("recordCashApplication", cash_application("BANK_TRANSFER")),
        ("recordTaxInvoiceIssuance", tax_invoice()),
        (
            "recordCollectionFailure",
            collection_failure("PROVIDER_FETCH_CONFIRMED"),
        ),
    ]
}

pub(super) fn action_draft(operation: Value) -> Value {
    let disposition = match operation.get("operationId").and_then(Value::as_str) {
        Some("recordCollectionFailure") => "REVIEW_TASK_CREATED",
        _ => "RECORDED",
    };
    json!({
        "schemaVersion": "action-payload.v1",
        "kind": "ECONOMICS_IMPORT",
        "target": {
            "targetType": "ECONOMICS_IMPORT",
            "targetId": "test-fixture-customer-one-import",
            "expectedVersion": null
        },
        "rationale": {
            "summary": "TEST_FIXTURE typed economics import boundary proof",
            "evidenceSegmentIds": [uuid(10_001), uuid(10_002)],
            "unknowns": [],
            "alternativesConsidered": [],
            "riskNote": "TEST_FIXTURE values have no production authority"
        },
        "effect": {
            "effectClass": "INTERNAL_MATERIALIZATION",
            "fromState": {"aggregate": "ECONOMICS_IMPORT", "state": "UNRECORDED"},
            "toState": {"aggregate": "ECONOMICS_IMPORT", "state": disposition},
            "externalSideEffect": false,
            "reversible": true,
            "expectedOutcome": "TEST_FIXTURE immutable import receipt"
        },
        "operation": operation,
        "sourceEvidenceDigests": [digest('1'), digest('2')],
        "importPolicyDigest": digest('3'),
        "asOf": "2026-08-02T00:00:00Z"
    })
}

pub(super) fn create_payload(draft: Value) -> Map<String, Value> {
    let rationale = draft.get("rationale").cloned().unwrap_or_else(|| json!({}));
    json!({
        "actionKind": "ECONOMICS_IMPORT",
        "draft": draft,
        "rationale": rationale
    })
    .as_object()
    .cloned()
    .unwrap_or_default()
}
