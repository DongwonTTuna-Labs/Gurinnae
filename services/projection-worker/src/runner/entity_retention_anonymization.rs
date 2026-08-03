use serde_json::{Map, Value};
use sqlx::{PgPool, Postgres, Transaction};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;

use super::{Failure, database};
use replay::{result, validate_stored_result};

mod replay;

const CONSUMER_ID: &str = "public-projection-worker";
const EVENT_TYPE: &str = "entity.retention_anonymized.v1";
const AGGREGATE_TYPE: &str = "r6d_entity_retention_execution";
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
const PAYLOAD_FIELDS: [&str; 8] = [
    "entityKind",
    "entityId",
    "executionReceiptId",
    "executionReceiptDigest",
    "masterRowCount",
    "identifierRowCount",
    "aliasRowCount",
    "anonymizedAt",
];
const CLEAR_AGENCY_PLAINTEXT: &str = "UPDATE public.agencies SET name=NULL,jurisdiction=NULL, \
     updated_at=GREATEST(updated_at,$2) WHERE id=$1 \
     AND (name IS NOT NULL OR jurisdiction IS NOT NULL)";
const CLEAR_SUPPLIER_PLAINTEXT: &str = "UPDATE public.suppliers SET name=NULL,updated_at=GREATEST(updated_at,$2) \
     WHERE id=$1 AND name IS NOT NULL";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EntityKind {
    Agency,
    Supplier,
}

impl EntityKind {
    fn parse(payload: &Map<String, Value>) -> Result<Self, Failure> {
        match payload.get("entityKind").and_then(Value::as_str) {
            Some("AGENCY") => Ok(Self::Agency),
            Some("SUPPLIER") => Ok(Self::Supplier),
            _ => Err(invalid("entityKind", "expected AGENCY or SUPPLIER")),
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Agency => "AGENCY",
            Self::Supplier => "SUPPLIER",
        }
    }
}

#[derive(Debug)]
struct RetentionAnonymizedEvent {
    event_id: Uuid,
    aggregate_id: String,
    occurred_at: OffsetDateTime,
    payload: Value,
    entity_kind: EntityKind,
    entity_id: Uuid,
    execution_receipt_id: Uuid,
    execution_receipt_digest: String,
    master_row_count: i64,
    identifier_row_count: i64,
    alias_row_count: i64,
    anonymized_at: OffsetDateTime,
}

impl RetentionAnonymizedEvent {
    fn parse(envelope: &Value, expected_event_id: Uuid) -> Result<Self, Failure> {
        let envelope = exact_object(envelope, &ENVELOPE_FIELDS, "envelope")?;
        exact_string(envelope, "consumerId", CONSUMER_ID)?;
        exact_string(envelope, "eventType", EVENT_TYPE)?;
        exact_string(envelope, "aggregateType", AGGREGATE_TYPE)?;
        let event_id = uuid(envelope, "eventId")?;
        if event_id != expected_event_id {
            return Err(invalid("eventId", "dispatcher identity mismatch"));
        }
        if envelope.get("aggregateVersion").and_then(Value::as_i64) != Some(1) {
            return Err(invalid("aggregateVersion", "expected 1"));
        }
        let aggregate_id = envelope
            .get("aggregateId")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("aggregateId", "expected UUID"))?
            .to_owned();
        let aggregate_uuid =
            Uuid::parse_str(&aggregate_id).map_err(|_| invalid("aggregateId", "expected UUID"))?;
        let occurred_at = timestamp(envelope, "occurredAt")?;
        let payload_value = envelope
            .get("payload")
            .ok_or_else(|| invalid("payload", "expected object"))?;
        let payload = exact_object(payload_value, &PAYLOAD_FIELDS, "payload")?;
        let entity_kind = EntityKind::parse(payload)?;
        let entity_id = uuid(payload, "entityId")?;
        let execution_receipt_id = uuid(payload, "executionReceiptId")?;
        if execution_receipt_id != aggregate_uuid {
            return Err(invalid("executionReceiptId", "aggregate identity mismatch"));
        }
        let execution_receipt_digest = digest(payload, "executionReceiptDigest")?;
        let master_row_count = positive_integer(payload, "masterRowCount")?;
        let identifier_row_count = nonnegative_integer(payload, "identifierRowCount")?;
        let alias_row_count = nonnegative_integer(payload, "aliasRowCount")?;
        let anonymized_at = timestamp(payload, "anonymizedAt")?;
        Ok(Self {
            event_id,
            aggregate_id,
            occurred_at,
            payload: payload_value.clone(),
            entity_kind,
            entity_id,
            execution_receipt_id,
            execution_receipt_digest,
            master_row_count,
            identifier_row_count,
            alias_row_count,
            anonymized_at,
        })
    }
}

pub(super) async fn handle_entity_retention_anonymized_v1(
    pool: &PgPool,
    event_id: Uuid,
    envelope: &Value,
) -> Result<Value, Failure> {
    let mut transaction = pool.begin().await.map_err(database)?;
    let event_exists = outbox_event_exists(&mut transaction, event_id).await?;
    let event = RetentionAnonymizedEvent::parse(envelope, event_id).map_err(|failure| {
        if event_exists {
            Failure::Terminal("EVENT_REPLAY_CONFLICT", event_id.to_string())
        } else {
            failure
        }
    })?;
    verify_authoritative_event(&mut transaction, &event).await?;
    if let Some(stored) = inbox_result(&mut transaction, event.event_id).await? {
        let stored = validate_stored_result(&event, &stored)?;
        transaction.commit().await.map_err(database)?;
        return Ok(stored);
    }
    let projection_row_changed = clear_public_plaintext(&mut transaction, &event).await?;
    let result = result(&event, projection_row_changed);
    complete_inbox(&mut transaction, event.event_id, &result).await?;
    transaction.commit().await.map_err(database)?;
    Ok(result)
}

pub(super) async fn claims(
    pool: &PgPool,
    event_id: Uuid,
    envelope: &Value,
) -> Result<bool, Failure> {
    if envelope.get("consumerId").and_then(Value::as_str) == Some(CONSUMER_ID)
        || envelope.get("eventType").and_then(Value::as_str) == Some(EVENT_TYPE)
    {
        return Ok(true);
    }
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM ops.outbox WHERE id=$1 AND event_type=$2)",
    )
    .bind(event_id)
    .bind(EVENT_TYPE)
    .fetch_one(pool)
    .await
    .map_err(database)
}

async fn outbox_event_exists(
    transaction: &mut Transaction<'_, Postgres>,
    event_id: Uuid,
) -> Result<bool, Failure> {
    sqlx::query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM ops.outbox WHERE id=$1)")
        .bind(event_id)
        .fetch_one(&mut **transaction)
        .await
        .map_err(database)
}

async fn verify_authoritative_event(
    transaction: &mut Transaction<'_, Postgres>,
    event: &RetentionAnonymizedEvent,
) -> Result<(), Failure> {
    let (event_exists, exact) = sqlx::query_as::<_, (bool, bool)>(
        "SELECT EXISTS(SELECT 1 FROM ops.outbox WHERE id=$1), \
         EXISTS(SELECT 1 FROM ops.outbox AS event \
         JOIN ops.r6d_entity_retention_execution_receipts_v1 AS receipt \
           ON receipt.outbox_event_id=event.id \
         WHERE event.id=$1 AND event.event_type=$2 AND event.aggregate_type=$3 \
           AND event.aggregate_id=$4 AND event.aggregate_version=1 \
           AND event.payload=$5 AND event.occurred_at=$6 \
           AND receipt.execution_receipt_id=$7 \
           AND receipt.execution_receipt_digest=$8::char(64) \
           AND receipt.entity_kind=$9 AND receipt.entity_id=$10 \
           AND receipt.master_row_count=$11 AND receipt.identifier_row_count=$12 \
           AND receipt.alias_row_count=$13 AND receipt.anonymized_at=$14)",
    )
    .bind(event.event_id)
    .bind(EVENT_TYPE)
    .bind(AGGREGATE_TYPE)
    .bind(&event.aggregate_id)
    .bind(&event.payload)
    .bind(event.occurred_at)
    .bind(event.execution_receipt_id)
    .bind(&event.execution_receipt_digest)
    .bind(event.entity_kind.as_str())
    .bind(event.entity_id)
    .bind(event.master_row_count)
    .bind(event.identifier_row_count)
    .bind(event.alias_row_count)
    .bind(event.anonymized_at)
    .fetch_one(&mut **transaction)
    .await
    .map_err(database)?;
    if exact {
        Ok(())
    } else {
        Err(Failure::Terminal(
            if event_exists {
                "EVENT_REPLAY_CONFLICT"
            } else {
                "EVENT_ENVELOPE_MISMATCH"
            },
            event.event_id.to_string(),
        ))
    }
}

async fn inbox_result(
    transaction: &mut Transaction<'_, Postgres>,
    event_id: Uuid,
) -> Result<Option<String>, Failure> {
    let (processed_at, result) = sqlx::query_as::<_, (Option<OffsetDateTime>, Option<String>)>(
        "SELECT processed_at,result FROM ops.inbox \
         WHERE consumer=$1 AND event_id=$2 FOR UPDATE",
    )
    .bind(CONSUMER_ID)
    .bind(event_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("INBOX_RECORD_MISSING", event_id.to_string()))?;
    match processed_at {
        Some(_) => result
            .map(Some)
            .ok_or_else(|| Failure::Terminal("INBOX_RESULT_INVALID", event_id.to_string())),
        None => Ok(None),
    }
}

async fn clear_public_plaintext(
    transaction: &mut Transaction<'_, Postgres>,
    event: &RetentionAnonymizedEvent,
) -> Result<bool, Failure> {
    let query = match event.entity_kind {
        EntityKind::Agency => CLEAR_AGENCY_PLAINTEXT,
        EntityKind::Supplier => CLEAR_SUPPLIER_PLAINTEXT,
    };
    let changed = sqlx::query(query)
        .bind(event.entity_id)
        .bind(event.anonymized_at)
        .execute(&mut **transaction)
        .await
        .map_err(database)?
        .rows_affected();
    if changed <= 1 {
        Ok(changed == 1)
    } else {
        Err(Failure::Terminal(
            "PUBLIC_PROJECTION_CARDINALITY_INVALID",
            event.entity_id.to_string(),
        ))
    }
}

async fn complete_inbox(
    transaction: &mut Transaction<'_, Postgres>,
    event_id: Uuid,
    result: &Value,
) -> Result<(), Failure> {
    let stored = serde_json::to_string(result)
        .map_err(|_| Failure::Terminal("INBOX_RESULT_INVALID", event_id.to_string()))?;
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result=$3 \
         WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
    )
    .bind(CONSUMER_ID)
    .bind(event_id)
    .bind(stored)
    .execute(&mut **transaction)
    .await
    .map_err(database)?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(Failure::Terminal("STALE_INBOX", event_id.to_string()))
    }
}

fn exact_object<'a>(
    value: &'a Value,
    fields: &[&str],
    location: &str,
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
    object
        .get(field)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| invalid(field, "expected UUID"))
}

fn digest(object: &Map<String, Value>, field: &'static str) -> Result<String, Failure> {
    let value = object
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(field, "expected lowercase SHA-256"))?;
    if value.len() == 64
        && value
            .as_bytes()
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        Ok(value.to_owned())
    } else {
        Err(invalid(field, "expected lowercase SHA-256"))
    }
}

fn positive_integer(object: &Map<String, Value>, field: &'static str) -> Result<i64, Failure> {
    match object.get(field).and_then(Value::as_i64) {
        Some(value) if value > 0 => Ok(value),
        _ => Err(invalid(field, "expected positive integer")),
    }
}

fn nonnegative_integer(object: &Map<String, Value>, field: &'static str) -> Result<i64, Failure> {
    match object.get(field).and_then(Value::as_i64) {
        Some(value) if value >= 0 => Ok(value),
        _ => Err(invalid(field, "expected nonnegative integer")),
    }
}

fn timestamp(object: &Map<String, Value>, field: &'static str) -> Result<OffsetDateTime, Failure> {
    let value = object
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
