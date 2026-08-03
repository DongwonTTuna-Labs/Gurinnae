use serde_json::{Value, json};
use uuid::Uuid;

use super::{DonationFactRecordedEvent, claims};
use crate::runner::Failure;

fn event() -> Value {
    json!({
        "consumerId":"funding-projector",
        "eventId":"00000000-0000-4000-8000-000000000011",
        "eventType":"donation.fact_recorded.v1",
        "aggregateType":"DonationFact",
        "aggregateId":"00000000-0000-4000-8000-000000000012",
        "aggregateVersion":3,
        "occurredAt":"2026-08-02T12:00:01Z",
        "payload":{
            "donationFactId":"00000000-0000-4000-8000-000000000013",
            "donationFactDigest":"1".repeat(64),
            "chargeAttemptId":"00000000-0000-4000-8000-000000000014",
            "chargeAttemptDigest":"2".repeat(64),
            "providerFetchDigest":"3".repeat(64),
            "occurredAt":"2026-08-02T12:00:00Z"
        }
    })
}

fn event_id() -> Uuid {
    Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0011)
}

#[test]
fn correction_fact_keeps_aggregate_root_separate_from_row_identity() {
    let parsed = DonationFactRecordedEvent::parse(&event(), event_id());
    assert!(parsed.as_ref().is_ok_and(|event| {
        event.aggregate_version == 3
            && event.aggregate_id != event.donation_fact_id
            && event
                .payload
                .as_object()
                .is_some_and(|payload| payload.len() == 6)
    }));
}

#[test]
fn event_envelope_and_payload_are_closed() {
    let mut envelope_extra = event();
    envelope_extra["providerPaymentId"] = json!("private");
    let mut payload_extra = event();
    payload_extra["payload"]["amount"] = json!(10000);
    let mut missing = event();
    if let Some(payload) = missing["payload"].as_object_mut() {
        payload.remove("providerFetchDigest");
    }
    for candidate in [envelope_extra, payload_extra, missing] {
        assert!(matches!(
            DonationFactRecordedEvent::parse(&candidate, event_id()),
            Err(Failure::Terminal("INVALID_DONATION_FACT_EVENT", _))
        ));
    }
}

#[test]
fn aggregate_requires_logical_type_uuid_and_positive_version_only() {
    let mut wrong_type = event();
    wrong_type["aggregateType"] = json!("donation_fact");
    let mut invalid_root = event();
    invalid_root["aggregateId"] = json!("not-a-uuid");
    let mut zero_version = event();
    zero_version["aggregateVersion"] = json!(0);
    for candidate in [wrong_type, invalid_root, zero_version] {
        assert!(DonationFactRecordedEvent::parse(&candidate, event_id()).is_err());
    }
}

#[test]
fn payload_authority_fields_are_typed_and_redacted_on_failure() {
    let mut bad_fact_id = event();
    bad_fact_id["payload"]["donationFactId"] = json!("00000000-0000-0000-0000-000000000000");
    let mut bad_digest = event();
    bad_digest["payload"]["chargeAttemptDigest"] = json!("A".repeat(64));
    let mut bad_time = event();
    bad_time["payload"]["occurredAt"] = json!("not-a-time");
    for candidate in [bad_fact_id, bad_digest, bad_time] {
        assert!(matches!(
            DonationFactRecordedEvent::parse(&candidate, event_id()),
            Err(Failure::Terminal("INVALID_DONATION_FACT_EVENT", detail))
                if !detail.contains("00000000") && !detail.contains(&"A".repeat(64))
        ));
    }
}

#[test]
fn dispatcher_claims_only_the_exact_funding_projector_delivery() {
    let exact = event();
    assert!(claims(&exact));

    let mut wrong_consumer = event();
    wrong_consumer["consumerId"] = json!("public-projection-worker");
    let mut wrong_event = event();
    wrong_event["eventType"] = json!("donation.fact_recorded.v2");
    let mut missing_event = event();
    if let Some(object) = missing_event.as_object_mut() {
        object.remove("eventType");
    }
    for candidate in [wrong_consumer, wrong_event, missing_event] {
        assert!(!claims(&candidate));
    }
}
