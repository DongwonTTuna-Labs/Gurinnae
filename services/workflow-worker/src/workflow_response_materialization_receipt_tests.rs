use serde_json::{Value, json};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use super::{
    Failure, ResponseSubmissionIntakeMaterializeInput, validate_response_materialization_receipt,
};

const SOURCE_EVENT_ID: &str = "9b864962-7d1e-45c7-b02f-4191e4d82632";
const SUBMISSION_ID: &str = "d47262d2-6807-4ed5-9ca1-b960e2222e0f";
const REQUEST_ID: &str = "4952c25f-fca2-41d3-aab9-647a70f66d88";
const RESPONSE_ID: &str = "27f4e9ba-d9a4-4b2f-8969-d7b3f0189111";
const PARTY_ID: &str = "32fbb2da-168b-491d-b54e-46a0bd14426d";
const AUDIT_ID: &str = "769b6ac0-a4bd-4a15-9907-a0ca20ad160b";
const OUTBOX_ID: &str = "b23b38f5-ff96-43dd-8a3a-c7859f6465d3";
const DIGEST: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn uuid(value: &str) -> Result<Uuid, String> {
    Uuid::parse_str(value).map_err(|error| format!("invalid test UUID: {error}"))
}

fn timestamp() -> Result<OffsetDateTime, String> {
    OffsetDateTime::parse("2026-08-01T12:34:56.123Z", &Rfc3339)
        .map_err(|error| format!("invalid test timestamp: {error}"))
}

fn input() -> Result<ResponseSubmissionIntakeMaterializeInput, String> {
    Ok(ResponseSubmissionIntakeMaterializeInput {
        source_event_id: uuid(SOURCE_EVENT_ID)?,
        source_event_envelope_digest: DIGEST.to_owned(),
        response_submission_id: uuid(SUBMISSION_ID)?,
        response_request_id: uuid(REQUEST_ID)?,
        response_request_version: 4,
        response_request_binding_digest: DIGEST.to_owned(),
        submission_sha256: DIGEST.to_owned(),
        receipt_version: 7,
        receipt_digest: DIGEST.to_owned(),
        submitted_at: timestamp()?,
    })
}

fn receipt() -> Value {
    json!({
        "disposition": "APPLIED",
        "source_event_id": SOURCE_EVENT_ID,
        "response_submission_id": SUBMISSION_ID,
        "response_request_id": REQUEST_ID,
        "editorial_response_id": RESPONSE_ID,
        "party_type": "SUPPLIER",
        "party_entity_id": PARTY_ID,
        "response_version": 1,
        "response_content_sha256": DIGEST,
        "publication_consent_sha256": DIGEST,
        "identity_status": "UNVERIFIED",
        "publication_form": "INTERNAL_ONLY",
        "submission_receipt_version": 7,
        "submission_receipt_digest": DIGEST,
        "owned_intake_receipt_digest": DIGEST,
        "audit_event_id": AUDIT_ID,
        "emitted_event_id": OUTBOX_ID,
        "materialized_at": "2026-08-01T12:35:00Z",
        "result_digest": DIGEST,
    })
}

fn assert_invalid(receipt: &Value, field: &str) -> Result<(), String> {
    match validate_response_materialization_receipt(receipt, &input()?) {
        Err(Failure::Terminal("INVALID_RESPONSE_MATERIALIZATION_RECEIPT", detail)) => {
            if detail.contains(field) {
                Ok(())
            } else {
                Err(format!("unexpected detail: {detail}"))
            }
        }
        other => Err(format!("expected invalid receipt, got {other:?}")),
    }
}

#[test]
fn accepts_only_the_unverified_internal_materialization_shape() -> Result<(), String> {
    let metrics = validate_response_materialization_receipt(&receipt(), &input()?)
        .map_err(|error| format!("valid receipt rejected: {error:?}"))?;
    assert_eq!(metrics["identityStatus"], "UNVERIFIED");
    assert_eq!(metrics["publicationForm"], "INTERNAL_ONLY");
    assert_eq!(metrics["responseSubmissionId"], SUBMISSION_ID);
    Ok(())
}

#[test]
fn rejects_identity_or_publication_escalation_from_materialization() -> Result<(), String> {
    for (field, value) in [
        ("identity_status", "SECOND_FACTOR_VERIFIED"),
        ("publication_form", "FULL"),
    ] {
        let mut receipt = receipt();
        receipt[field] = Value::String(value.to_owned());
        assert_invalid(&receipt, "identity_status")?;
    }
    Ok(())
}

#[test]
fn rejects_changed_binding_and_additional_fields() -> Result<(), String> {
    let mut changed = receipt();
    changed["response_submission_id"] = Value::String(REQUEST_ID.to_owned());
    assert_invalid(&changed, "response_submission_id")?;

    let mut expanded = receipt();
    expanded["plaintext"] = Value::String("forbidden".to_owned());
    assert_invalid(&expanded, "receipt")
}
