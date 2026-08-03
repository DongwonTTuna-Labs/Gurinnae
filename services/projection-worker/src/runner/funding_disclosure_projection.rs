use serde_json::{Map, Value};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use super::Failure;

pub(super) const CONSUMER_ID: &str = "public-projection-worker";
pub(super) const AUDIT_CONSUMER_ID: &str = "audit-indexer";
pub(super) const EVENT_TYPE: &str = "governance.funding_disclosure_published.v1";
const AGGREGATE_TYPE: &str = "FundingDisclosureRevision";
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
const PAYLOAD_FIELDS: [&str; 11] = [
    "disclosureId",
    "revisionId",
    "revision",
    "revisionDigest",
    "snapshotBatchId",
    "snapshotDigest",
    "concentrationBand",
    "entrySetDigest",
    "priorRevision",
    "effectiveAt",
    "receiptDigest",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct FundingDisclosurePublishedEvent {
    pub(super) event_id: Uuid,
    pub(super) disclosure_id: Uuid,
    pub(super) revision_id: Uuid,
    pub(super) revision: i64,
    pub(super) revision_digest: String,
    pub(super) snapshot_batch_id: Uuid,
    pub(super) snapshot_digest: String,
    pub(super) concentration_band: String,
    pub(super) entry_set_digest: String,
    pub(super) prior_revision: Option<i64>,
    pub(super) effective_at: OffsetDateTime,
    pub(super) receipt_digest: String,
    pub(super) occurred_at: OffsetDateTime,
    pub(super) payload: Value,
}

impl FundingDisclosurePublishedEvent {
    pub(super) fn parse(envelope: &Value, expected_event_id: Uuid) -> Result<Self, Failure> {
        Self::parse_for_consumer(envelope, expected_event_id, CONSUMER_ID)
    }

    fn parse_for_consumer(
        envelope: &Value,
        expected_event_id: Uuid,
        expected_consumer_id: &str,
    ) -> Result<Self, Failure> {
        let envelope = exact_object(envelope, &ENVELOPE_FIELDS, "envelope")?;
        exact_string(envelope, "consumerId", expected_consumer_id)?;
        exact_string(envelope, "eventType", EVENT_TYPE)?;
        exact_string(envelope, "aggregateType", AGGREGATE_TYPE)?;
        let event_id = uuid(envelope, "eventId")?;
        if event_id != expected_event_id {
            return Err(invalid("eventId", "dispatcher identity mismatch"));
        }
        let aggregate_id = uuid(envelope, "aggregateId")?;
        let aggregate_version = positive_integer(envelope, "aggregateVersion")?;
        let occurred_at = timestamp(envelope, "occurredAt")?;
        let payload_value = envelope
            .get("payload")
            .ok_or_else(|| invalid("payload", "expected object"))?;
        let payload = exact_object(payload_value, &PAYLOAD_FIELDS, "payload")?;
        let disclosure_id = uuid(payload, "disclosureId")?;
        let revision_id = uuid(payload, "revisionId")?;
        let revision = positive_integer(payload, "revision")?;
        let prior_revision = optional_nonnegative_integer(payload, "priorRevision")?;
        if revision_id != aggregate_id || revision != aggregate_version {
            return Err(invalid(
                "aggregate",
                "revision identity or version mismatch",
            ));
        }
        validate_revision_chain(revision, prior_revision)?;
        let concentration_band = payload
            .get("concentrationBand")
            .and_then(Value::as_str)
            .filter(|value| funding_band(value))
            .ok_or_else(|| invalid("concentrationBand", "unexpected value"))?
            .to_owned();
        Ok(Self {
            event_id,
            disclosure_id,
            revision_id,
            revision,
            revision_digest: digest(payload, "revisionDigest")?,
            snapshot_batch_id: uuid(payload, "snapshotBatchId")?,
            snapshot_digest: digest(payload, "snapshotDigest")?,
            concentration_band,
            entry_set_digest: digest(payload, "entrySetDigest")?,
            prior_revision,
            effective_at: timestamp(payload, "effectiveAt")?,
            receipt_digest: digest(payload, "receiptDigest")?,
            occurred_at,
            payload: payload_value.clone(),
        })
    }
}

pub(super) fn claims(envelope: &Value) -> bool {
    envelope.get("consumerId").and_then(Value::as_str) == Some(CONSUMER_ID)
        && envelope.get("eventType").and_then(Value::as_str) == Some(EVENT_TYPE)
}

pub(super) fn validate_audit_delivery(
    envelope: &Value,
    expected_event_id: Uuid,
) -> Result<(), Failure> {
    FundingDisclosurePublishedEvent::parse_for_consumer(
        envelope,
        expected_event_id,
        AUDIT_CONSUMER_ID,
    )
    .map(|_| ())
}

fn validate_revision_chain(revision: i64, prior_revision: Option<i64>) -> Result<(), Failure> {
    let valid = if revision == 1 {
        prior_revision.is_none()
    } else {
        prior_revision == revision.checked_sub(1)
    };
    if valid {
        Ok(())
    } else {
        Err(invalid(
            "priorRevision",
            "must be null for revision 1 and exactly revision minus one thereafter",
        ))
    }
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
    expected: &str,
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
    if canonical_contract_uuid(raw, parsed) {
        Ok(parsed)
    } else {
        Err(invalid(field, "expected canonical contract UUID"))
    }
}

fn canonical_contract_uuid(raw: &str, parsed: Uuid) -> bool {
    let bytes = raw.as_bytes();
    raw == parsed.hyphenated().to_string()
        && bytes.len() == 36
        && matches!(bytes.get(14), Some(b'1'..=b'5'))
        && matches!(bytes.get(19), Some(b'8' | b'9' | b'a' | b'b'))
}

fn positive_integer(object: &Map<String, Value>, field: &'static str) -> Result<i64, Failure> {
    object
        .get(field)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| invalid(field, "expected positive integer"))
}

fn optional_nonnegative_integer(
    object: &Map<String, Value>,
    field: &'static str,
) -> Result<Option<i64>, Failure> {
    match object.get(field) {
        Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_i64()
            .filter(|value| *value >= 0)
            .map(Some)
            .ok_or_else(|| invalid(field, "expected nonnegative integer or null")),
        None => Err(invalid(field, "field is required")),
    }
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

fn funding_band(value: &str) -> bool {
    matches!(
        value,
        "UNKNOWN" | "LE_5_PERCENT" | "GT_5_TO_15_PERCENT" | "GT_15_TO_25_PERCENT" | "GT_25_PERCENT"
    )
}

fn invalid(field: &'static str, detail: &'static str) -> Failure {
    Failure::Terminal(
        "INVALID_FUNDING_DISCLOSURE_EVENT",
        format!("{field}: {detail}"),
    )
}

mod runtime;
pub(super) use runtime::handle;

#[cfg(test)]
mod tests;
