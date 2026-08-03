use serde_json::{Map, Value, json};
use sqlx::PgPool;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use super::{Failure, database};

const RESPONSE_SUBMITTED_V2_FIELDS: [&str; 8] = [
    "responseSubmissionId",
    "responseRequestId",
    "responseRequestVersion",
    "responseRequestBindingDigest",
    "submissionSha256",
    "receiptVersion",
    "receiptDigest",
    "submittedAt",
];

#[derive(Clone, Debug, Eq, PartialEq)]
struct ResponseSubmittedV2Fact {
    response_submission_id: Uuid,
    response_request_id: Uuid,
    response_request_version: i64,
    response_request_binding_digest: String,
    submission_sha256: String,
    receipt_version: i64,
    receipt_digest: String,
    submitted_at: OffsetDateTime,
}

pub(super) async fn handle_response_submitted_v2(
    pool: &PgPool,
    event_id: Uuid,
    envelope: &Value,
) -> Result<Value, Failure> {
    let fact = response_submitted_v2_fact(envelope)?;
    complete_audit_index(pool, event_id).await?;
    Ok(audit_projection(event_id, &fact))
}

fn response_submitted_v2_fact(envelope: &Value) -> Result<ResponseSubmittedV2Fact, Failure> {
    if envelope.get("aggregateType").and_then(Value::as_str) != Some("response_submission") {
        return Err(invalid("aggregateType", "expected response_submission"));
    }
    let aggregate_id = envelope_uuid(envelope, "aggregateId")?;
    let aggregate_version = envelope_version(envelope, "aggregateVersion")?;
    let payload = envelope
        .get("payload")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid("payload", "expected object"))?;
    if let Some(unexpected) = payload
        .keys()
        .find(|field| !RESPONSE_SUBMITTED_V2_FIELDS.contains(&field.as_str()))
    {
        return Err(invalid(unexpected, "unexpected field"));
    }

    let fact = ResponseSubmittedV2Fact {
        response_submission_id: payload_uuid(payload, "responseSubmissionId")?,
        response_request_id: payload_uuid(payload, "responseRequestId")?,
        response_request_version: payload_version(payload, "responseRequestVersion")?,
        response_request_binding_digest: payload_digest(payload, "responseRequestBindingDigest")?,
        submission_sha256: payload_digest(payload, "submissionSha256")?,
        receipt_version: payload_version(payload, "receiptVersion")?,
        receipt_digest: payload_digest(payload, "receiptDigest")?,
        submitted_at: payload_timestamp(payload, "submittedAt")?,
    };
    if fact.response_submission_id != aggregate_id {
        return Err(invalid(
            "responseSubmissionId",
            "aggregate identity mismatch",
        ));
    }
    if fact.receipt_version != aggregate_version {
        return Err(invalid("receiptVersion", "aggregate version mismatch"));
    }
    Ok(fact)
}

async fn complete_audit_index(pool: &PgPool, event_id: Uuid) -> Result<(), Failure> {
    let mut transaction = pool.begin().await.map_err(database)?;
    let processed = sqlx::query_scalar::<_, bool>(
        "SELECT processed_at IS NOT NULL FROM ops.inbox \
         WHERE consumer='audit-indexer' AND event_id=$1 FOR UPDATE",
    )
    .bind(event_id)
    .fetch_optional(&mut *transaction)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("INBOX_RECORD_MISSING", event_id.to_string()))?;
    if processed {
        transaction.commit().await.map_err(database)?;
        return Ok(());
    }

    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='audit-indexer' AND event_id=$1 AND processed_at IS NULL",
    )
    .bind(event_id)
    .execute(&mut *transaction)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal("STALE_INBOX", event_id.to_string()));
    }
    transaction.commit().await.map_err(database)?;
    Ok(())
}

fn audit_projection(event_id: Uuid, fact: &ResponseSubmittedV2Fact) -> Value {
    json!({
        "consumerId":"audit-indexer",
        "eventId":event_id,
        "eventType":"response.submitted.v2",
        "responseSubmissionId":fact.response_submission_id,
        "responseRequestId":fact.response_request_id,
        "responseRequestVersion":fact.response_request_version,
        "responseRequestBindingDigest":fact.response_request_binding_digest,
        "submissionSha256":fact.submission_sha256,
        "receiptVersion":fact.receipt_version,
        "receiptDigest":fact.receipt_digest,
        "submittedAt":fact.submitted_at,
    })
}

fn envelope_uuid(envelope: &Value, field: &'static str) -> Result<Uuid, Failure> {
    envelope
        .get(field)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| invalid(field, "expected UUID"))
}

fn envelope_version(envelope: &Value, field: &'static str) -> Result<i64, Failure> {
    envelope
        .get(field)
        .and_then(Value::as_i64)
        .filter(|version| *version > 0)
        .ok_or_else(|| invalid(field, "expected positive integer"))
}

fn payload_uuid(payload: &Map<String, Value>, field: &'static str) -> Result<Uuid, Failure> {
    payload
        .get(field)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| invalid(field, "expected UUID"))
}

fn payload_version(payload: &Map<String, Value>, field: &'static str) -> Result<i64, Failure> {
    payload
        .get(field)
        .and_then(Value::as_i64)
        .filter(|version| *version > 0)
        .ok_or_else(|| invalid(field, "expected positive integer"))
}

fn payload_digest(payload: &Map<String, Value>, field: &'static str) -> Result<String, Failure> {
    let digest = payload
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(field, "expected lowercase SHA-256"))?;
    if digest.len() == 64
        && digest
            .as_bytes()
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        Ok(digest.to_owned())
    } else {
        Err(invalid(field, "expected lowercase SHA-256"))
    }
}

fn payload_timestamp(
    payload: &Map<String, Value>,
    field: &'static str,
) -> Result<OffsetDateTime, Failure> {
    let timestamp = payload
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(field, "expected RFC 3339 date-time"))?;
    OffsetDateTime::parse(timestamp, &Rfc3339)
        .map_err(|_| invalid(field, "expected RFC 3339 date-time"))
}

fn invalid(field: &str, reason: &str) -> Failure {
    Failure::Terminal(
        "INVALID_EVENT_PAYLOAD",
        format!("response.submitted.v2 {field}: {reason}"),
    )
}

#[cfg(test)]
mod tests {
    use super::{Failure, audit_projection, response_submitted_v2_fact};
    use serde_json::{Value, json};
    use uuid::Uuid;

    const EVENT_ID: &str = "9b864962-7d1e-45c7-b02f-4191e4d82632";
    const SUBMISSION_ID: &str = "d47262d2-6807-4ed5-9ca1-b960e2222e0f";
    const REQUEST_ID: &str = "4952c25f-fca2-41d3-aab9-647a70f66d88";
    const DIGEST: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn valid_envelope() -> Value {
        json!({
            "consumerId":"audit-indexer",
            "eventId":EVENT_ID,
            "eventType":"response.submitted.v2",
            "aggregateType":"response_submission",
            "aggregateId":SUBMISSION_ID,
            "aggregateVersion":7,
            "occurredAt":"2026-08-01T12:34:56.123Z",
            "payload":{
                "responseSubmissionId":SUBMISSION_ID,
                "responseRequestId":REQUEST_ID,
                "responseRequestVersion":4,
                "responseRequestBindingDigest":DIGEST,
                "submissionSha256":DIGEST,
                "receiptVersion":7,
                "receiptDigest":DIGEST,
                "submittedAt":"2026-08-01T12:34:56.123Z"
            }
        })
    }

    fn assert_invalid(envelope: &Value, field: &str) {
        match response_submitted_v2_fact(envelope) {
            Err(Failure::Terminal("INVALID_EVENT_PAYLOAD", detail)) => {
                assert!(detail.contains(field), "unexpected detail: {detail}");
            }
            other => panic!("expected invalid payload, got {other:?}"),
        }
    }

    #[test]
    fn exact_v2_payload_becomes_a_digest_only_audit_projection() {
        let envelope = valid_envelope();
        let fact = match response_submitted_v2_fact(&envelope) {
            Ok(fact) => fact,
            Err(error) => {
                panic!("valid payload rejected: {error:?}");
            }
        };
        let event_id = match Uuid::parse_str(EVENT_ID) {
            Ok(event_id) => event_id,
            Err(error) => {
                panic!("test event ID invalid: {error}");
            }
        };
        let projection = audit_projection(event_id, &fact);

        assert_eq!(projection["eventType"], "response.submitted.v2");
        assert_eq!(projection["responseSubmissionId"], SUBMISSION_ID);
        assert_eq!(projection["responseRequestId"], REQUEST_ID);
        assert_eq!(projection["submissionSha256"], DIGEST);
        assert!(projection.get("responseBody").is_none());
        assert!(projection.get("partyIdentity").is_none());
        assert!(projection.get("requestToken").is_none());
    }

    #[test]
    fn raw_response_or_pii_fields_are_rejected_instead_of_indexed() {
        for field in ["responseBody", "partyIdentity", "requestToken"] {
            let mut envelope = valid_envelope();
            if let Some(payload) = envelope.get_mut("payload").and_then(Value::as_object_mut) {
                payload.insert(field.to_owned(), Value::String("forbidden".to_owned()));
            }
            assert_invalid(&envelope, field);
        }
    }

    #[test]
    fn aggregate_identity_and_version_must_bind_the_fact() {
        let mut identity_mismatch = valid_envelope();
        identity_mismatch["aggregateId"] =
            Value::String("90bfbadd-7240-451c-b779-a7ddf23dbdc4".to_owned());
        assert_invalid(&identity_mismatch, "responseSubmissionId");

        let mut version_mismatch = valid_envelope();
        version_mismatch["aggregateVersion"] = Value::from(8);
        assert_invalid(&version_mismatch, "receiptVersion");
    }

    #[test]
    fn malformed_safe_fields_fail_closed() {
        for (field, value) in [
            ("receiptDigest", Value::String("not-a-digest".to_owned())),
            ("responseRequestVersion", Value::from(0)),
            (
                "submittedAt",
                Value::String("2026-08-01 12:34:56".to_owned()),
            ),
        ] {
            let mut envelope = valid_envelope();
            if let Some(payload) = envelope.get_mut("payload").and_then(Value::as_object_mut) {
                payload.insert(field.to_owned(), value);
            }
            assert_invalid(&envelope, field);
        }
    }
}
