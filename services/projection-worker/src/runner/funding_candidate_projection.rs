use serde_json::{Map, Value};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use super::Failure;

pub(super) const CONSUMER_ID: &str = "funding-projector";
pub(super) const EVENT_TYPE: &str = "donation.fact_recorded.v1";
const AGGREGATE_TYPE: &str = "DonationFact";
const ENVELOPE_FIELDS: [&str; 8] = [
    "consumerId",
    "eventId",
    "eventType",
    "aggregateType",
    "aggregateId",
    "aggregateVersion",
    "occurredAt",
    "payload",
];
const PAYLOAD_FIELDS: [&str; 6] = [
    "donationFactId",
    "donationFactDigest",
    "chargeAttemptId",
    "chargeAttemptDigest",
    "providerFetchDigest",
    "occurredAt",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct DonationFactRecordedEvent {
    pub(super) event_id: Uuid,
    pub(super) aggregate_id: Uuid,
    pub(super) aggregate_version: i64,
    pub(super) donation_fact_id: Uuid,
    pub(super) donation_fact_digest: String,
    pub(super) charge_attempt_id: Uuid,
    pub(super) charge_attempt_digest: String,
    pub(super) provider_fetch_digest: String,
    pub(super) donation_occurred_at: OffsetDateTime,
    pub(super) event_occurred_at: OffsetDateTime,
    pub(super) payload: Value,
}

impl DonationFactRecordedEvent {
    pub(super) fn parse(envelope: &Value, expected_event_id: Uuid) -> Result<Self, Failure> {
        let envelope = exact_object(envelope, &ENVELOPE_FIELDS, "envelope")?;
        exact_string(envelope, "consumerId", CONSUMER_ID)?;
        exact_string(envelope, "eventType", EVENT_TYPE)?;
        exact_string(envelope, "aggregateType", AGGREGATE_TYPE)?;
        let event_id = uuid(envelope, "eventId")?;
        if event_id != expected_event_id {
            return Err(invalid("eventId", "dispatcher identity mismatch"));
        }
        let payload_value = envelope
            .get("payload")
            .ok_or_else(|| invalid("payload", "expected object"))?;
        let payload = exact_object(payload_value, &PAYLOAD_FIELDS, "payload")?;
        Ok(Self {
            event_id,
            aggregate_id: uuid(envelope, "aggregateId")?,
            aggregate_version: positive_integer(envelope, "aggregateVersion")?,
            donation_fact_id: uuid(payload, "donationFactId")?,
            donation_fact_digest: digest(payload, "donationFactDigest")?,
            charge_attempt_id: uuid(payload, "chargeAttemptId")?,
            charge_attempt_digest: digest(payload, "chargeAttemptDigest")?,
            provider_fetch_digest: digest(payload, "providerFetchDigest")?,
            donation_occurred_at: timestamp(payload, "occurredAt")?,
            event_occurred_at: timestamp(envelope, "occurredAt")?,
            payload: payload_value.clone(),
        })
    }
}

pub(super) fn claims(envelope: &Value) -> bool {
    envelope.get("consumerId").and_then(Value::as_str) == Some(CONSUMER_ID)
        && envelope.get("eventType").and_then(Value::as_str) == Some(EVENT_TYPE)
}

fn exact_object<'a>(
    value: &'a Value,
    fields: &[&str],
    location: &'static str,
) -> Result<&'a Map<String, Value>, Failure> {
    let object = value
        .as_object()
        .ok_or_else(|| invalid(location, "expected object"))?;
    if object.len() == fields.len() && fields.iter().all(|field| object.contains_key(*field)) {
        Ok(object)
    } else {
        Err(invalid(location, "field set mismatch"))
    }
}

fn exact_string(
    object: &Map<String, Value>,
    field: &'static str,
    expected: &'static str,
) -> Result<(), Failure> {
    if object.get(field).and_then(Value::as_str) == Some(expected) {
        Ok(())
    } else {
        Err(invalid(field, "unexpected value"))
    }
}

fn uuid(object: &Map<String, Value>, field: &'static str) -> Result<Uuid, Failure> {
    let raw = object
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(field, "expected UUID"))?;
    let parsed = Uuid::parse_str(raw).map_err(|_| invalid(field, "expected UUID"))?;
    let bytes = raw.as_bytes();
    if raw == parsed.hyphenated().to_string()
        && bytes.len() == 36
        && matches!(bytes.get(14), Some(b'1'..=b'5'))
        && matches!(bytes.get(19), Some(b'8' | b'9' | b'a' | b'b'))
    {
        Ok(parsed)
    } else {
        Err(invalid(field, "expected canonical contract UUID"))
    }
}

fn positive_integer(object: &Map<String, Value>, field: &'static str) -> Result<i64, Failure> {
    object
        .get(field)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| invalid(field, "expected positive integer"))
}

fn digest(object: &Map<String, Value>, field: &'static str) -> Result<String, Failure> {
    object
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| {
            value.len() == 64
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        })
        .map(str::to_owned)
        .ok_or_else(|| invalid(field, "expected lowercase SHA-256"))
}

fn timestamp(object: &Map<String, Value>, field: &'static str) -> Result<OffsetDateTime, Failure> {
    object
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(field, "expected RFC3339 timestamp"))
        .and_then(|value| {
            OffsetDateTime::parse(value, &Rfc3339)
                .map_err(|_| invalid(field, "expected RFC3339 timestamp"))
        })
}

fn invalid(field: &'static str, detail: &'static str) -> Failure {
    Failure::Terminal("INVALID_DONATION_FACT_EVENT", format!("{field}: {detail}"))
}

mod runtime;
pub(super) use runtime::handle;

#[cfg(test)]
mod tests;
