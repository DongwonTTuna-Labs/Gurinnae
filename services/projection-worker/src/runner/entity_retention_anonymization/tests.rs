use serde_json::{Value, json};
use uuid::Uuid;

use super::replay::{result, validate_stored_result};
use super::{
    CLEAR_AGENCY_PLAINTEXT, CLEAR_SUPPLIER_PLAINTEXT, EntityKind, Failure, RetentionAnonymizedEvent,
};

const EVENT_ID: &str = "31404c38-0ab9-41f8-9071-111c0df9ec04";
const EVENT_UUID: Uuid = Uuid::from_u128(0x31404c38_0ab9_41f8_9071_111c0df9ec04);
const ENTITY_ID: &str = "4dc50f76-fcce-42ac-9c0f-890f3858972a";
const RECEIPT_ID: &str = "7c1acddc-d241-48c4-a772-1853eb8db157";
const DIGEST: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn valid_envelope(entity_kind: &str) -> Value {
    json!({
        "consumerId":"public-projection-worker",
        "eventId":EVENT_ID,
        "eventType":"entity.retention_anonymized.v1",
        "aggregateType":"r6d_entity_retention_execution",
        "aggregateId":RECEIPT_ID,
        "aggregateVersion":1,
        "occurredAt":"2026-08-01T12:34:56Z",
        "payload":{
            "entityKind":entity_kind,
            "entityId":ENTITY_ID,
            "executionReceiptId":RECEIPT_ID,
            "executionReceiptDigest":DIGEST,
            "masterRowCount":1,
            "identifierRowCount":2,
            "aliasRowCount":3,
            "anonymizedAt":"2026-08-01T12:34:56Z"
        }
    })
}

#[test]
fn exact_agency_and_supplier_events_are_accepted() -> Result<(), String> {
    let agency = RetentionAnonymizedEvent::parse(&valid_envelope("AGENCY"), EVENT_UUID)
        .map_err(|error| format!("exact agency event: {error:?}"))?;
    let supplier = RetentionAnonymizedEvent::parse(&valid_envelope("SUPPLIER"), EVENT_UUID)
        .map_err(|error| format!("exact supplier event: {error:?}"))?;

    assert_eq!(agency.entity_kind, EntityKind::Agency);
    assert_eq!(supplier.entity_kind, EntityKind::Supplier);
    Ok(())
}

#[test]
fn changed_or_open_event_shapes_fail_closed() {
    let mut unexpected = valid_envelope("AGENCY");
    unexpected["payload"]["priorName"] = json!("forbidden");
    let mut missing = valid_envelope("AGENCY");
    assert_eq!(
        missing["payload"]
            .as_object_mut()
            .and_then(|payload| payload.remove("aliasRowCount")),
        Some(json!(3))
    );

    for envelope in [unexpected, missing] {
        assert!(matches!(
            RetentionAnonymizedEvent::parse(&envelope, EVENT_UUID),
            Err(Failure::Terminal("INVALID_EVENT_PAYLOAD", _))
        ));
    }
}

#[test]
fn authority_bindings_and_scalar_constraints_fail_closed() {
    let cases = [
        ("consumerId", json!("projection-worker")),
        ("aggregateType", json!("entity")),
        ("aggregateVersion", json!(2)),
        ("occurredAt", json!("not-a-time")),
    ];
    for (field, value) in cases {
        let mut envelope = valid_envelope("AGENCY");
        envelope[field] = value;
        assert!(RetentionAnonymizedEvent::parse(&envelope, EVENT_UUID).is_err());
    }

    for (field, value) in [
        ("entityKind", json!("PERSON")),
        ("executionReceiptDigest", json!("A".repeat(64))),
        ("masterRowCount", json!(0)),
        ("identifierRowCount", json!(-1)),
        ("aliasRowCount", json!(1.5)),
        ("anonymizedAt", json!("not-a-time")),
    ] {
        let mut envelope = valid_envelope("AGENCY");
        envelope["payload"][field] = value;
        assert!(RetentionAnonymizedEvent::parse(&envelope, EVENT_UUID).is_err());
    }
}

#[test]
fn execution_receipt_is_the_aggregate_identity() {
    let mut envelope = valid_envelope("AGENCY");
    envelope["aggregateId"] = json!("6d01a112-464f-4c78-8bc6-99e88ace3cc3");
    assert!(matches!(
        RetentionAnonymizedEvent::parse(&envelope, EVENT_UUID),
        Err(Failure::Terminal("INVALID_EVENT_PAYLOAD", detail))
            if detail.contains("aggregate identity mismatch")
    ));
}

#[test]
fn projection_mutation_preserves_identity_links_and_revision_history() {
    assert!(CLEAR_AGENCY_PLAINTEXT.contains("SET name=NULL,jurisdiction=NULL"));
    assert!(CLEAR_SUPPLIER_PLAINTEXT.contains("SET name=NULL"));
    for statement in [CLEAR_AGENCY_PLAINTEXT, CLEAR_SUPPLIER_PLAINTEXT] {
        assert!(!statement.contains("DELETE"));
        assert!(!statement.contains("public.contracts"));
        assert!(!statement.contains("public.case_revisions"));
    }
}

#[test]
fn exact_replay_returns_the_closed_stored_result() -> Result<(), String> {
    let event = RetentionAnonymizedEvent::parse(&valid_envelope("AGENCY"), EVENT_UUID)
        .map_err(|error| format!("exact agency event: {error:?}"))?;
    let fresh = result(&event, true);
    let stored =
        serde_json::to_string(&fresh).map_err(|error| format!("serialize test result: {error}"))?;
    let replayed = validate_stored_result(&event, &stored)
        .map_err(|error| format!("validate stored result: {error:?}"))?;

    assert_eq!(replayed, fresh);
    Ok(())
}

#[test]
fn changed_or_open_stored_results_fail_closed() -> Result<(), String> {
    let event = RetentionAnonymizedEvent::parse(&valid_envelope("SUPPLIER"), EVENT_UUID)
        .map_err(|error| format!("exact supplier event: {error:?}"))?;
    let mut changed = result(&event, false);
    changed["entityId"] = json!("6d01a112-464f-4c78-8bc6-99e88ace3cc3");
    let mut open = result(&event, false);
    open["deduplicated"] = json!(true);

    for invalid in [changed, open, json!("SUCCEEDED")] {
        let stored = serde_json::to_string(&invalid)
            .map_err(|error| format!("serialize invalid test result: {error}"))?;
        assert!(matches!(
            validate_stored_result(&event, &stored),
            Err(Failure::Terminal("INBOX_RESULT_INVALID", _))
        ));
    }
    Ok(())
}
