use serde_json::Value;
use sqlx::{Postgres, Transaction};
use time::OffsetDateTime;
use uuid::Uuid;

pub struct OutboxEvent<'a> {
    pub aggregate_type: &'a str,
    pub aggregate_id: &'a str,
    pub aggregate_version: i64,
    pub event_type: &'a str,
    pub payload: &'a Value,
    pub occurred_at: OffsetDateTime,
}

pub async fn append(
    transaction: &mut Transaction<'_, Postgres>,
    event: &OutboxEvent<'_>,
) -> Result<Uuid, sqlx::Error> {
    sqlx::query_scalar("SELECT ops.enqueue_outbox($1, $2, $3, $4, $5, $6)")
        .bind(event.aggregate_type)
        .bind(event.aggregate_id)
        .bind(event.aggregate_version)
        .bind(event.event_type)
        .bind(event.payload)
        .bind(event.occurred_at)
        .fetch_one(&mut **transaction)
        .await
}
