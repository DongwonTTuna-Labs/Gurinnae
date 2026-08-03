use serde_json::{Value, json};
use uuid::Uuid;

use super::{FundingDisclosurePublishedEvent, claims, invalid, validate_audit_delivery};
use crate::runner::Failure;

fn event(revision: i64, prior_revision: Value) -> Value {
    json!({
        "consumerId":"public-projection-worker",
        "eventId":"00000000-0000-4000-8000-000000000001",
        "eventType":"governance.funding_disclosure_published.v1",
        "aggregateType":"FundingDisclosureRevision",
        "aggregateId":"00000000-0000-4000-8000-000000000003",
        "aggregateVersion":revision,
        "occurredAt":"2026-08-02T12:00:00Z",
        "payload":{
            "disclosureId":"00000000-0000-4000-8000-000000000002",
            "revisionId":"00000000-0000-4000-8000-000000000003",
            "revision":revision,
            "revisionDigest":"1".repeat(64),
            "snapshotBatchId":"00000000-0000-4000-8000-000000000004",
            "snapshotDigest":"2".repeat(64),
            "concentrationBand":"UNKNOWN",
            "entrySetDigest":"3".repeat(64),
            "priorRevision":prior_revision,
            "effectiveAt":"2026-08-02T00:00:00Z",
            "receiptDigest":"4".repeat(64)
        }
    })
}

fn event_id() -> Uuid {
    Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0001)
}

#[test]
fn exact_first_and_successor_revisions_are_closed_and_accepted() {
    let first = FundingDisclosurePublishedEvent::parse(&event(1, Value::Null), event_id());
    assert!(first.as_ref().is_ok_and(|event| {
        event.revision == 1
            && event.prior_revision.is_none()
            && event.revision_id.to_string() == "00000000-0000-4000-8000-000000000003"
    }));

    let successor = FundingDisclosurePublishedEvent::parse(&event(2, json!(1)), event_id());
    assert!(successor.as_ref().is_ok_and(|event| {
        event.revision == 2
            && event.prior_revision == Some(1)
            && event
                .payload
                .as_object()
                .is_some_and(|payload| payload.len() == 11)
    }));
}

#[test]
fn zero_revision_and_every_invalid_prior_shape_fail_closed() {
    for candidate in [
        event(0, Value::Null),
        event(1, json!(0)),
        event(1, json!(1)),
        event(2, Value::Null),
        event(2, json!(0)),
        event(2, json!(2)),
    ] {
        assert!(matches!(
            FundingDisclosurePublishedEvent::parse(&candidate, event_id()),
            Err(Failure::Terminal("INVALID_FUNDING_DISCLOSURE_EVENT", _))
        ));
    }
}

#[test]
fn aggregate_identity_type_and_version_are_exactly_bound() {
    let mut wrong_identity = event(2, json!(1));
    wrong_identity["aggregateId"] = json!("00000000-0000-4000-8000-000000000005");
    let mut wrong_version = event(2, json!(1));
    wrong_version["aggregateVersion"] = json!(1);
    let mut wrong_type = event(2, json!(1));
    wrong_type["aggregateType"] = json!("funding_disclosure_revision");
    let mut wrong_event = event(2, json!(1));
    wrong_event["eventId"] = json!("00000000-0000-4000-8000-000000000005");
    for candidate in [wrong_identity, wrong_version, wrong_type, wrong_event] {
        assert!(FundingDisclosurePublishedEvent::parse(&candidate, event_id()).is_err());
    }
}

#[test]
fn changed_or_private_event_fields_are_rejected() {
    let mut envelope_extra = event(1, Value::Null);
    envelope_extra["traceId"] = json!("private");
    let mut payload_extra = event(1, Value::Null);
    payload_extra["payload"]["publisherUserId"] = json!("00000000-0000-4000-8000-000000000005");
    let mut missing = event(1, Value::Null);
    if let Some(payload) = missing["payload"].as_object_mut() {
        payload.remove("receiptDigest");
    }
    for candidate in [envelope_extra, payload_extra, missing] {
        assert!(FundingDisclosurePublishedEvent::parse(&candidate, event_id()).is_err());
    }
}

#[test]
fn malformed_authority_fields_are_rejected_without_echoing_values() {
    let mut bad_digest = event(1, Value::Null);
    bad_digest["payload"]["revisionDigest"] = json!("A".repeat(64));
    let mut bad_uuid = event(1, Value::Null);
    bad_uuid["payload"]["disclosureId"] = json!("00000000-0000-0000-0000-000000000000");
    let mut bad_band = event(1, Value::Null);
    bad_band["payload"]["concentrationBand"] = json!("KNOWN");
    let mut bad_time = event(1, Value::Null);
    bad_time["occurredAt"] = json!("not-a-time");
    for candidate in [bad_digest, bad_uuid, bad_band, bad_time] {
        let failure = FundingDisclosurePublishedEvent::parse(&candidate, event_id());
        assert!(matches!(
            failure,
            Err(Failure::Terminal("INVALID_FUNDING_DISCLOSURE_EVENT", detail))
                if !detail.contains("00000000") && !detail.contains(&"A".repeat(64))
        ));
    }
}

#[test]
fn invalid_errors_are_static_and_redacted() {
    assert!(matches!(
        invalid("revision", "expected positive integer"),
        Failure::Terminal("INVALID_FUNDING_DISCLOSURE_EVENT", detail)
            if detail == "revision: expected positive integer"
    ));
}

#[test]
fn dispatcher_claims_only_the_exact_public_owner_delivery() {
    let exact = event(1, Value::Null);
    assert!(claims(&exact));
    let mut changed_consumer = exact.clone();
    changed_consumer["consumerId"] = json!("projection-worker");
    assert!(!claims(&changed_consumer));
    let mut changed_event = exact.clone();
    changed_event["eventType"] = json!("governance.other.v1");
    assert!(!claims(&changed_event));
    let mut unrelated = changed_consumer;
    unrelated["eventType"] = json!("governance.other.v1");
    assert!(!claims(&unrelated));
}

#[test]
fn audit_delivery_is_typed_without_duplicate_public_owner_claim() {
    let mut audit = event(1, Value::Null);
    audit["consumerId"] = json!("audit-indexer");

    assert!(!claims(&audit));
    assert!(validate_audit_delivery(&audit, event_id()).is_ok());
    assert!(FundingDisclosurePublishedEvent::parse(&audit, event_id()).is_err());
}

#[test]
fn audit_delivery_rejects_consumer_mismatch_and_payload_drift() {
    let public = event(1, Value::Null);
    assert!(validate_audit_delivery(&public, event_id()).is_err());

    let mut changed = public;
    changed["consumerId"] = json!("audit-indexer");
    changed["payload"]["donorIdentity"] = json!("private");
    assert!(validate_audit_delivery(&changed, event_id()).is_err());
}
