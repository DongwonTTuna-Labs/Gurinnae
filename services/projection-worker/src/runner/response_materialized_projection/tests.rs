use super::{Failure, projection_result, response_materialized_v2_fact};
use serde_json::{Value, json};
use uuid::Uuid;

const EVENT_ID: &str = "a9000000-0000-4000-8000-000000000001";
const SUBMISSION_ID: &str = "a9000000-0000-4000-8000-000000000002";
const REQUEST_ID: &str = "a9000000-0000-4000-8000-000000000003";
const RESPONSE_ID: &str = "a9000000-0000-4000-8000-000000000004";
const ENTITY_ID: &str = "a9000000-0000-4000-8000-000000000005";
const DIGEST: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn valid_envelope() -> Value {
    json!({
        "consumerId":"submission-projector",
        "eventId":EVENT_ID,
        "eventType":"editorial.response_materialized.v2",
        "aggregateType":"response_submission",
        "aggregateId":SUBMISSION_ID,
        "aggregateVersion":1,
        "occurredAt":"2026-08-02T12:34:56.123Z",
        "payload":{
            "responseSubmissionId":SUBMISSION_ID,
            "responseRequestId":REQUEST_ID,
            "editorialResponseId":RESPONSE_ID,
            "partyType":"AGENCY",
            "partyEntityId":ENTITY_ID,
            "responseVersion":1,
            "responseContentSha256":DIGEST,
            "publicationConsentSha256":DIGEST,
            "identityStatus":"UNVERIFIED",
            "submissionReceiptVersion":1,
            "submissionReceiptDigest":DIGEST,
            "ownedIntakeReceiptDigest":DIGEST,
            "materializedAt":"2026-08-02T12:34:56.123Z",
            "resultDigest":DIGEST
        }
    })
}

#[expect(
    clippy::assertions_on_constants,
    reason = "unexpected results are test assertion failures"
)]
fn assert_invalid(envelope: &Value, field: &str) {
    match response_materialized_v2_fact(envelope) {
        Err(Failure::Terminal("INVALID_EVENT_PAYLOAD", detail)) => {
            assert!(detail.contains(field), "unexpected detail: {detail}");
        }
        other => {
            assert!(false, "expected invalid payload, got {other:?}");
        }
    }
}

#[test]
#[expect(
    clippy::assertions_on_constants,
    reason = "unexpected results are test assertion failures"
)]
fn exact_payload_produces_digest_only_consumer_results() {
    let envelope = valid_envelope();
    let fact = match response_materialized_v2_fact(&envelope) {
        Ok(fact) => fact,
        Err(error) => {
            assert!(false, "valid payload rejected: {error:?}");
            return;
        }
    };
    let event_id = Uuid::parse_str(EVENT_ID).unwrap_or_default();
    for consumer in ["submission-projector", "audit-indexer"] {
        let result = projection_result(event_id, consumer, &fact);
        assert_eq!(result["consumerId"], consumer);
        assert_eq!(result["eventType"], "editorial.response_materialized.v2");
        assert_eq!(result["responseContentSha256"], DIGEST);
        for forbidden in [
            "partyName",
            "responseBody",
            "consentText",
            "endpoint",
            "token",
        ] {
            assert!(result.get(forbidden).is_none());
        }
    }
}

#[test]
fn aggregate_identity_and_response_version_bind_the_fact() {
    let mut wrong_id = valid_envelope();
    wrong_id["aggregateId"] = Value::String(REQUEST_ID.to_owned());
    assert_invalid(&wrong_id, "responseSubmissionId");

    let mut wrong_version = valid_envelope();
    wrong_version["aggregateVersion"] = Value::from(2);
    assert_invalid(&wrong_version, "responseVersion");
}

#[test]
fn party_entity_matrix_and_identity_status_fail_closed() {
    let mut agency_without_entity = valid_envelope();
    agency_without_entity["payload"]["partyEntityId"] = Value::Null;
    assert_invalid(&agency_without_entity, "partyEntityId");

    let mut other_with_entity = valid_envelope();
    other_with_entity["payload"]["partyType"] = Value::String("OTHER".to_owned());
    assert_invalid(&other_with_entity, "partyEntityId");

    let mut verified = valid_envelope();
    verified["payload"]["identityStatus"] = Value::String("VERIFIED".to_owned());
    assert_invalid(&verified, "identityStatus");

    let mut other = valid_envelope();
    other["payload"]["partyType"] = Value::String("OTHER".to_owned());
    other["payload"]["partyEntityId"] = Value::Null;
    assert!(response_materialized_v2_fact(&other).is_ok());
}

#[test]
fn malformed_or_plaintext_payload_fields_are_rejected() {
    for (field, value) in [
        ("resultDigest", Value::String("not-a-digest".to_owned())),
        ("responseVersion", Value::from(0)),
        (
            "materializedAt",
            Value::String("2026-08-02 12:34:56".to_owned()),
        ),
    ] {
        let mut envelope = valid_envelope();
        envelope["payload"][field] = value;
        assert_invalid(&envelope, field);
    }
    let mut plaintext = valid_envelope();
    if let Some(payload) = plaintext.get_mut("payload").and_then(Value::as_object_mut) {
        payload.insert(
            "partyName".to_owned(),
            Value::String("forbidden".to_owned()),
        );
    }
    assert_invalid(&plaintext, "payload");
}
