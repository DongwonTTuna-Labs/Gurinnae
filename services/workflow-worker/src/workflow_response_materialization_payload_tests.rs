use serde_json::{Map, Value};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use super::{
    Failure, ResponseSubmissionIntakeMaterializeInput,
    parse_response_submission_intake_materialize_input,
};

const SOURCE_EVENT_ID: &str = "9b864962-7d1e-45c7-b02f-4191e4d82632";
const SUBMISSION_ID: &str = "d47262d2-6807-4ed5-9ca1-b960e2222e0f";
const REQUEST_ID: &str = "4952c25f-fca2-41d3-aab9-647a70f66d88";
const DIGEST: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn valid_payload() -> Map<String, Value> {
    Map::from_iter([
        (
            "responseSubmissionId".to_owned(),
            Value::String(SUBMISSION_ID.to_owned()),
        ),
        (
            "responseRequestId".to_owned(),
            Value::String(REQUEST_ID.to_owned()),
        ),
        ("responseRequestVersion".to_owned(), Value::from(4)),
        (
            "responseRequestBindingDigest".to_owned(),
            Value::String(DIGEST.to_owned()),
        ),
        (
            "submissionSha256".to_owned(),
            Value::String(DIGEST.to_owned()),
        ),
        ("receiptVersion".to_owned(), Value::from(7)),
        ("receiptDigest".to_owned(), Value::String(DIGEST.to_owned())),
        (
            "submittedAt".to_owned(),
            Value::String("2026-08-01T12:34:56.123Z".to_owned()),
        ),
    ])
}

fn parse(
    payload: &Map<String, Value>,
) -> Result<ResponseSubmissionIntakeMaterializeInput, Failure> {
    let source_event_id = Uuid::parse_str(SOURCE_EVENT_ID)
        .map_err(|error| Failure::Terminal("TEST_UUID_INVALID", error.to_string()))?;
    parse_response_submission_intake_materialize_input(source_event_id, DIGEST, payload)
}

fn assert_invalid(payload: &Map<String, Value>, field: &str) -> Result<(), String> {
    match parse(payload) {
        Err(Failure::Terminal("INVALID_EVENT_PAYLOAD", detail)) => {
            if detail.contains(field) {
                Ok(())
            } else {
                Err(format!("unexpected detail: {detail}"))
            }
        }
        other => Err(format!("expected invalid payload, got {other:?}")),
    }
}

#[test]
fn parses_exact_ten_field_materializer_input() -> Result<(), String> {
    let parsed =
        parse(&valid_payload()).map_err(|error| format!("valid payload rejected: {error:?}"))?;
    let submitted_at = OffsetDateTime::parse("2026-08-01T12:34:56.123Z", &Rfc3339)
        .map_err(|error| format!("test timestamp invalid: {error}"))?;

    assert_eq!(parsed.source_event_id.to_string(), SOURCE_EVENT_ID);
    assert_eq!(parsed.source_event_envelope_digest, DIGEST);
    assert_eq!(parsed.response_submission_id.to_string(), SUBMISSION_ID);
    assert_eq!(parsed.response_request_id.to_string(), REQUEST_ID);
    assert_eq!(parsed.response_request_version, 4);
    assert_eq!(parsed.response_request_binding_digest, DIGEST);
    assert_eq!(parsed.submission_sha256, DIGEST);
    assert_eq!(parsed.receipt_version, 7);
    assert_eq!(parsed.receipt_digest, DIGEST);
    assert_eq!(parsed.submitted_at, submitted_at);
    Ok(())
}

#[test]
fn rejects_missing_required_field() -> Result<(), String> {
    let mut payload = valid_payload();
    payload.remove("responseRequestId");
    assert_invalid(&payload, "responseRequestId")
}

#[test]
fn rejects_additional_property() -> Result<(), String> {
    let mut payload = valid_payload();
    payload.insert("opaqueToken".to_owned(), Value::String("secret".to_owned()));
    assert_invalid(&payload, "opaqueToken")
}

#[test]
fn rejects_zero_versions() -> Result<(), String> {
    for field in ["responseRequestVersion", "receiptVersion"] {
        let mut payload = valid_payload();
        payload.insert(field.to_owned(), Value::from(0));
        assert_invalid(&payload, field)?;
    }
    Ok(())
}

#[test]
fn rejects_invalid_digests() -> Result<(), String> {
    for (field, value) in [
        ("responseRequestBindingDigest", "abc"),
        (
            "submissionSha256",
            "ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        ),
        (
            "receiptDigest",
            "g123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        ),
    ] {
        let mut payload = valid_payload();
        payload.insert(field.to_owned(), Value::String(value.to_owned()));
        assert_invalid(&payload, field)?;
    }
    Ok(())
}

#[test]
fn rejects_invalid_source_envelope_digest() -> Result<(), String> {
    let source_event_id =
        Uuid::parse_str(SOURCE_EVENT_ID).map_err(|error| format!("test UUID invalid: {error}"))?;
    match parse_response_submission_intake_materialize_input(
        source_event_id,
        "not-a-digest",
        &valid_payload(),
    ) {
        Err(Failure::Terminal("INVALID_EVENT_PAYLOAD", detail)) => {
            if detail.contains("sourceEventEnvelopeDigest") {
                Ok(())
            } else {
                Err(format!("unexpected detail: {detail}"))
            }
        }
        other => Err(format!("expected invalid envelope digest, got {other:?}")),
    }
}

#[test]
fn rejects_invalid_timestamp() -> Result<(), String> {
    let mut payload = valid_payload();
    payload.insert(
        "submittedAt".to_owned(),
        Value::String("2026-08-01 12:34:56".to_owned()),
    );
    assert_invalid(&payload, "submittedAt")
}
