use serde_json::{Map, Value, json};
use sqlx::{PgPool, Row};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use super::{Failure, database};

const EVENT_TYPE: &str = "editorial.response_materialized.v2";
const PAYLOAD_FIELDS: [&str; 14] = [
    "responseSubmissionId",
    "responseRequestId",
    "editorialResponseId",
    "partyType",
    "partyEntityId",
    "responseVersion",
    "responseContentSha256",
    "publicationConsentSha256",
    "identityStatus",
    "submissionReceiptVersion",
    "submissionReceiptDigest",
    "ownedIntakeReceiptDigest",
    "materializedAt",
    "resultDigest",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PartyType {
    Agency,
    Supplier,
    Other,
}

impl PartyType {
    fn parse(value: Option<&str>) -> Result<Self, Failure> {
        match value {
            Some("AGENCY") => Ok(Self::Agency),
            Some("SUPPLIER") => Ok(Self::Supplier),
            Some("OTHER") => Ok(Self::Other),
            _ => Err(invalid("partyType", "expected AGENCY, SUPPLIER, or OTHER")),
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Agency => "AGENCY",
            Self::Supplier => "SUPPLIER",
            Self::Other => "OTHER",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ResponseMaterializedV2Fact {
    response_submission_id: Uuid,
    response_request_id: Uuid,
    editorial_response_id: Uuid,
    party_type: PartyType,
    party_entity_id: Option<Uuid>,
    response_version: i64,
    response_content_sha256: String,
    publication_consent_sha256: String,
    submission_receipt_version: i64,
    submission_receipt_digest: String,
    owned_intake_receipt_digest: String,
    materialized_at: OffsetDateTime,
    result_digest: String,
}

pub(super) async fn handle_response_materialized_v2(
    pool: &PgPool,
    event_id: Uuid,
    consumer_id: &str,
    envelope: &Value,
) -> Result<Value, Failure> {
    if !matches!(consumer_id, "submission-projector" | "audit-indexer") {
        return Err(Failure::Terminal(
            "CONSUMER_BINDING_INVALID",
            consumer_id.to_owned(),
        ));
    }
    let fact = response_materialized_v2_fact(envelope)?;
    let result = projection_result(event_id, consumer_id, &fact);
    complete_with_stored_result(pool, event_id, consumer_id, &result).await
}

fn response_materialized_v2_fact(envelope: &Value) -> Result<ResponseMaterializedV2Fact, Failure> {
    if envelope.get("eventType").and_then(Value::as_str) != Some(EVENT_TYPE) {
        return Err(invalid("eventType", "unexpected event type"));
    }
    if envelope.get("aggregateType").and_then(Value::as_str) != Some("response_submission") {
        return Err(invalid("aggregateType", "expected response_submission"));
    }
    let aggregate_id = envelope_uuid(envelope, "aggregateId")?;
    let aggregate_version = envelope_positive_integer(envelope, "aggregateVersion")?;
    let payload = exact_payload(envelope)?;
    let party_type = PartyType::parse(payload.get("partyType").and_then(Value::as_str))?;
    let party_entity_id = optional_uuid(payload, "partyEntityId")?;
    validate_party_binding(party_type, party_entity_id)?;
    if payload.get("identityStatus").and_then(Value::as_str) != Some("UNVERIFIED") {
        return Err(invalid("identityStatus", "expected UNVERIFIED"));
    }
    let fact = ResponseMaterializedV2Fact {
        response_submission_id: payload_uuid(payload, "responseSubmissionId")?,
        response_request_id: payload_uuid(payload, "responseRequestId")?,
        editorial_response_id: payload_uuid(payload, "editorialResponseId")?,
        party_type,
        party_entity_id,
        response_version: positive_integer(payload, "responseVersion")?,
        response_content_sha256: digest(payload, "responseContentSha256")?,
        publication_consent_sha256: digest(payload, "publicationConsentSha256")?,
        submission_receipt_version: positive_integer(payload, "submissionReceiptVersion")?,
        submission_receipt_digest: digest(payload, "submissionReceiptDigest")?,
        owned_intake_receipt_digest: digest(payload, "ownedIntakeReceiptDigest")?,
        materialized_at: timestamp(payload, "materializedAt")?,
        result_digest: digest(payload, "resultDigest")?,
    };
    if fact.response_submission_id != aggregate_id {
        return Err(invalid(
            "responseSubmissionId",
            "aggregate identity mismatch",
        ));
    }
    if fact.response_version != aggregate_version {
        return Err(invalid("responseVersion", "aggregate version mismatch"));
    }
    Ok(fact)
}

fn exact_payload(envelope: &Value) -> Result<&Map<String, Value>, Failure> {
    let payload = envelope
        .get("payload")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid("payload", "expected object"))?;
    if payload.len() != PAYLOAD_FIELDS.len() {
        return Err(invalid("payload", "expected exact field set"));
    }
    if let Some(field) = payload
        .keys()
        .find(|field| !PAYLOAD_FIELDS.contains(&field.as_str()))
    {
        return Err(invalid(field, "unexpected field"));
    }
    Ok(payload)
}

fn validate_party_binding(
    party_type: PartyType,
    party_entity_id: Option<Uuid>,
) -> Result<(), Failure> {
    match (party_type, party_entity_id) {
        (PartyType::Agency | PartyType::Supplier, Some(_)) | (PartyType::Other, None) => Ok(()),
        _ => Err(invalid("partyEntityId", "does not match partyType")),
    }
}

fn projection_result(
    event_id: Uuid,
    consumer_id: &str,
    fact: &ResponseMaterializedV2Fact,
) -> Value {
    json!({
        "consumerId":consumer_id,
        "eventId":event_id,
        "eventType":EVENT_TYPE,
        "responseSubmissionId":fact.response_submission_id,
        "responseRequestId":fact.response_request_id,
        "editorialResponseId":fact.editorial_response_id,
        "partyType":fact.party_type.as_str(),
        "partyEntityId":fact.party_entity_id,
        "responseVersion":fact.response_version,
        "responseContentSha256":fact.response_content_sha256,
        "publicationConsentSha256":fact.publication_consent_sha256,
        "identityStatus":"UNVERIFIED",
        "submissionReceiptVersion":fact.submission_receipt_version,
        "submissionReceiptDigest":fact.submission_receipt_digest,
        "ownedIntakeReceiptDigest":fact.owned_intake_receipt_digest,
        "materializedAt":fact.materialized_at,
        "resultDigest":fact.result_digest,
    })
}

async fn complete_with_stored_result(
    pool: &PgPool,
    event_id: Uuid,
    consumer_id: &str,
    expected: &Value,
) -> Result<Value, Failure> {
    let mut transaction = pool.begin().await.map_err(database)?;
    let row = sqlx::query(
        "SELECT processed_at,result FROM ops.inbox \
         WHERE consumer=$1 AND event_id=$2 FOR UPDATE",
    )
    .bind(consumer_id)
    .bind(event_id)
    .fetch_optional(&mut *transaction)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("INBOX_RECORD_MISSING", event_id.to_string()))?;
    let processed_at: Option<OffsetDateTime> = row.try_get("processed_at").map_err(database)?;
    let stored_text: Option<String> = row.try_get("result").map_err(database)?;
    if processed_at.is_some() {
        let stored = stored_result(stored_text, event_id)?;
        if stored != *expected {
            return Err(Failure::Terminal(
                "EVENT_REPLAY_CONFLICT",
                event_id.to_string(),
            ));
        }
        transaction.commit().await.map_err(database)?;
        return Ok(stored);
    }
    let encoded = serde_json::to_string(expected)
        .map_err(|_| Failure::Terminal("PROJECTION_RESULT_INVALID", event_id.to_string()))?;
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result=$3 \
         WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
    )
    .bind(consumer_id)
    .bind(event_id)
    .bind(encoded)
    .execute(&mut *transaction)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal("STALE_INBOX", event_id.to_string()));
    }
    transaction.commit().await.map_err(database)?;
    Ok(expected.clone())
}

fn stored_result(value: Option<String>, event_id: Uuid) -> Result<Value, Failure> {
    value
        .and_then(|value| serde_json::from_str(&value).ok())
        .ok_or_else(|| Failure::Terminal("STORED_PROJECTION_RESULT_INVALID", event_id.to_string()))
}

fn envelope_uuid(value: &Value, field: &'static str) -> Result<Uuid, Failure> {
    value
        .get(field)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| invalid(field, "expected UUID"))
}

fn payload_uuid(payload: &Map<String, Value>, field: &'static str) -> Result<Uuid, Failure> {
    payload
        .get(field)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| invalid(field, "expected UUID"))
}

fn envelope_positive_integer(value: &Value, field: &'static str) -> Result<i64, Failure> {
    value
        .get(field)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| invalid(field, "expected positive integer"))
}

fn optional_uuid(
    payload: &Map<String, Value>,
    field: &'static str,
) -> Result<Option<Uuid>, Failure> {
    match payload.get(field) {
        Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Uuid::parse_str(value)
            .map(Some)
            .map_err(|_| invalid(field, "expected UUID or null")),
        _ => Err(invalid(field, "expected UUID or null")),
    }
}

fn positive_integer(value: &Map<String, Value>, field: &'static str) -> Result<i64, Failure> {
    value
        .get(field)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| invalid(field, "expected positive integer"))
}

fn digest(payload: &Map<String, Value>, field: &'static str) -> Result<String, Failure> {
    let value = payload
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(field, "expected lowercase SHA-256"))?;
    if value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(value.to_owned())
    } else {
        Err(invalid(field, "expected lowercase SHA-256"))
    }
}

fn timestamp(payload: &Map<String, Value>, field: &'static str) -> Result<OffsetDateTime, Failure> {
    let value = payload
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(field, "expected RFC 3339 date-time"))?;
    OffsetDateTime::parse(value, &Rfc3339)
        .map_err(|_| invalid(field, "expected RFC 3339 date-time"))
}

fn invalid(field: &str, reason: &str) -> Failure {
    Failure::Terminal(
        "INVALID_EVENT_PAYLOAD",
        format!("{EVENT_TYPE} {field}: {reason}"),
    )
}

#[cfg(test)]
mod tests;
