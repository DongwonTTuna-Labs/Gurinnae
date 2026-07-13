use std::str::FromStr;

use chrono::{DateTime, Utc};
use croner::Cron;
use gurine_jobs::postgres::{ClaimedJob, Worker, recover_expired};
use gurine_persistence_postgres::pool::{PoolConfig, connect};
use serde_json::{Value, json};
use sqlx::{PgPool, Row};
use thiserror::Error;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::config::Config;

#[derive(Debug, Error)]
pub enum SchedulerError {
    #[error("scheduler initialization failed")]
    Initialization,
    #[error("scheduler database operation failed: {0}")]
    Database(#[source] sqlx::Error),
}

struct Event {
    id: Uuid,
    aggregate_type: String,
    aggregate_id: String,
    aggregate_version: i64,
    event_type: String,
    payload: Value,
    occurred_at: OffsetDateTime,
}

pub async fn run(config: Config) -> Result<(), SchedulerError> {
    let pool = connect(&PoolConfig {
        database_url: config.database_url.clone(),
        max_connections: 4,
        acquire_timeout: std::time::Duration::from_secs(10),
    })
    .await
    .map_err(|_| SchedulerError::Initialization)?;
    let event_worker = Worker::new(
        config.instance_id.clone(),
        "scheduler".to_owned(),
        std::time::Duration::from_secs(60),
    )
    .map_err(|_| SchedulerError::Initialization)?;
    tracing::info!(instance_id=%config.instance_id,"scheduler ready");
    loop {
        let recovered = recover_expired(&pool, 100)
            .await
            .map_err(|error| SchedulerError::Database(job_sqlx(error)))?;
        let scheduled = schedule_source_runs(&pool, config.batch_size).await?;
        let expired: Option<Uuid> = sqlx::query_scalar(
            "SELECT ops.enqueue_outbox('internal.publication_access_expiry',$1,0, \
             'internal.expire_due_publication_access.v1',$2,clock_timestamp())",
        )
        .bind(config.batch_size.to_string())
        .bind(json!({"limit":config.batch_size}))
        .fetch_one(&pool)
        .await
        .map_err(SchedulerError::Database)?;
        let dispatched = dispatch_batch(&pool, config.batch_size).await?;
        let consumed = consume_scheduler_job(&pool, &event_worker).await?;
        if config.once {
            if scheduled == 0 && expired.is_none() && dispatched == 0 && !consumed && recovered == 0
            {
                return Ok(());
            }
        } else if scheduled == 0
            && expired.is_none()
            && dispatched == 0
            && !consumed
            && recovered == 0
        {
            tokio::select! {
                () = tokio::time::sleep(config.poll_interval) => {},
                signal = tokio::signal::ctrl_c() => {
                    signal.map_err(|_| SchedulerError::Initialization)?;
                    tracing::info!("scheduler shutdown requested");
                    return Ok(());
                }
            }
        }
    }
}

async fn consume_scheduler_job(pool: &PgPool, worker: &Worker) -> Result<bool, SchedulerError> {
    let Some(job) = worker
        .claim(pool)
        .await
        .map_err(|error| SchedulerError::Database(job_sqlx(error)))?
    else {
        return Ok(false);
    };
    if job.job_type == "RULE_ACTIVATION" {
        return consume_rule_activation(pool, worker, &job).await;
    }
    consume_scheduler_event(pool, worker, &job).await
}

async fn consume_rule_activation(
    pool: &PgPool,
    worker: &Worker,
    job: &ClaimedJob,
) -> Result<bool, SchedulerError> {
    let rule_version_id = job
        .payload
        .get("ruleVersionId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok());
    let actor_id = job
        .payload
        .get("actorId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok());
    let request_id = job
        .payload
        .get("requestId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok());
    let (Some(rule_version_id), Some(actor_id), Some(request_id)) =
        (rule_version_id, actor_id, request_id)
    else {
        worker
            .fail(
                pool,
                job,
                "INVALID_RULE_ACTIVATION_JOB",
                "ruleVersionId, actorId, and requestId must be UUIDs",
                false,
                json!({}),
            )
            .await
            .map_err(|error| SchedulerError::Database(job_sqlx(error)))?;
        return Ok(true);
    };
    let applied = sqlx::query_scalar::<_, Option<Uuid>>(
        "SELECT ops.enqueue_outbox('internal.rule_activation',$1,0, \
         'internal.apply_due_rule_activation.v1',$2,clock_timestamp())",
    )
    .bind(rule_version_id.to_string())
    .bind(json!({"ruleVersionId":rule_version_id,"actorId":actor_id,"requestId":request_id}))
    .fetch_one(pool)
    .await;
    match applied {
        Ok(event_id) => {
            worker
                .complete(
                    pool,
                    job,
                    json!({
                        "ruleVersionId":rule_version_id,
                        "eventId":event_id,
                        "deduplicated":event_id.is_none(),
                    }),
                )
                .await
                .map_err(|error| SchedulerError::Database(job_sqlx(error)))?;
            tracing::info!(%rule_version_id,?event_id,"scheduled rule activation reconciled");
        }
        Err(error) => {
            let retryable = error
                .as_database_error()
                .and_then(|database| database.code())
                .is_some_and(|code| code == "40001" || code == "55000");
            worker
                .fail(
                    pool,
                    job,
                    "RULE_ACTIVATION_APPLY_FAILED",
                    &error.to_string(),
                    retryable,
                    json!({"ruleVersionId":rule_version_id}),
                )
                .await
                .map_err(|failure| SchedulerError::Database(job_sqlx(failure)))?;
        }
    }
    Ok(true)
}

async fn consume_scheduler_event(
    pool: &PgPool,
    worker: &Worker,
    job: &ClaimedJob,
) -> Result<bool, SchedulerError> {
    let outcome = validate_scheduler_event(pool, job).await;
    match outcome {
        Ok((event_id, rule_version_id)) => {
            let changed = sqlx::query(
                "UPDATE ops.inbox SET processed_at=COALESCE(processed_at,clock_timestamp()),result='SUCCEEDED' \
                 WHERE consumer='scheduler' AND event_id=$1",
            )
            .bind(event_id)
            .execute(pool)
            .await
            .map_err(SchedulerError::Database)?
            .rows_affected();
            if changed != 1 {
                return Err(SchedulerError::Database(sqlx::Error::RowNotFound));
            }
            worker
                .complete(pool, job, json!({"ruleVersionId":rule_version_id}))
                .await
                .map_err(|error| SchedulerError::Database(job_sqlx(error)))?;
            tracing::info!(event_id=%event_id,rule_version_id=%rule_version_id,"scheduler activation event reconciled");
        }
        Err(detail) => {
            worker
                .fail(
                    pool,
                    job,
                    "INVALID_RULE_ACTIVATION_EVENT",
                    &detail,
                    false,
                    json!({}),
                )
                .await
                .map_err(|error| SchedulerError::Database(job_sqlx(error)))?;
        }
    }
    Ok(true)
}

pub async fn schedule_source_runs(pool: &PgPool, limit: i64) -> Result<u64, SchedulerError> {
    let sources = sqlx::query(
        "SELECT s.source_id,s.schedule_cron,MAX(r.scheduled_for) AS last_scheduled_for \
         FROM ops.source_registry s LEFT JOIN ops.source_runs r ON r.source_id=s.source_id \
         WHERE s.enabled AND s.legal_status='APPROVED' \
         GROUP BY s.source_id,s.schedule_cron ORDER BY s.source_id",
    )
    .fetch_all(pool)
    .await
    .map_err(SchedulerError::Database)?;
    let now = OffsetDateTime::now_utc();
    let mut scheduled = 0_u64;
    for row in sources {
        if scheduled >= u64::try_from(limit).map_err(|_| SchedulerError::Initialization)? {
            break;
        }
        let source_id: String = row.try_get("source_id").map_err(SchedulerError::Database)?;
        let expression: String = row
            .try_get("schedule_cron")
            .map_err(SchedulerError::Database)?;
        let last: Option<OffsetDateTime> = row
            .try_get("last_scheduled_for")
            .map_err(SchedulerError::Database)?;
        let cron = match Cron::from_str(&expression) {
            Ok(cron) => cron,
            Err(error) => {
                tracing::warn!(%source_id,%expression,%error,"source cron is invalid");
                continue;
            }
        };
        let now_chrono = to_chrono(now)?;
        let due = if let Some(last) = last {
            cron.find_next_occurrence(&to_chrono(last)?, false)
        } else {
            cron.find_previous_occurrence(&now_chrono, true)
        };
        let due = match due {
            Ok(due) if due <= now_chrono => from_chrono(due)?,
            Ok(_) => continue,
            Err(error) => {
                tracing::warn!(%source_id,%expression,%error,"source cron occurrence cannot be calculated");
                continue;
            }
        };
        let run_id = Uuid::new_v4();
        let mut tx = pool.begin().await.map_err(SchedulerError::Database)?;
        let inserted = sqlx::query_scalar::<_, Uuid>(
            "INSERT INTO ops.source_runs(id,source_id,mode,status,scheduled_for,schedule_expression) \
             VALUES($1,$2,'INCREMENTAL','QUEUED',$3,$4) \
             ON CONFLICT(source_id,scheduled_for) WHERE scheduled_for IS NOT NULL DO NOTHING \
             RETURNING id",
        )
        .bind(run_id)
        .bind(&source_id)
        .bind(due)
        .bind(&expression)
        .fetch_optional(&mut *tx)
        .await
        .map_err(SchedulerError::Database)?;
        if inserted.is_none() {
            tx.commit().await.map_err(SchedulerError::Database)?;
            continue;
        }
        sqlx::query(
            "INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,max_attempts) \
             VALUES('SOURCE_RUN','ingest-worker',$1,$2,8)",
        )
        .bind(json!({"sourceRunId":run_id,"scheduledFor":due}))
        .bind(format!(
            "source-run:{source_id}:{}",
            due.unix_timestamp_nanos()
        ))
        .execute(&mut *tx)
        .await
        .map_err(SchedulerError::Database)?;
        tx.commit().await.map_err(SchedulerError::Database)?;
        scheduled += 1;
        tracing::info!(%source_id,%run_id,scheduled_for=%due,"source run scheduled");
    }
    Ok(scheduled)
}

fn to_chrono(value: OffsetDateTime) -> Result<DateTime<Utc>, SchedulerError> {
    // Cron slots are second-granular.  Carrying database/client sub-second
    // precision through Croner's previous-occurrence search would let two
    // scheduler instances represent the same slot with different timestamps.
    DateTime::from_timestamp(value.unix_timestamp(), 0).ok_or(SchedulerError::Initialization)
}

fn from_chrono(value: DateTime<Utc>) -> Result<OffsetDateTime, SchedulerError> {
    let nanos =
        i128::from(value.timestamp()) * 1_000_000_000 + i128::from(value.timestamp_subsec_nanos());
    OffsetDateTime::from_unix_timestamp_nanos(nanos).map_err(|_| SchedulerError::Initialization)
}

async fn validate_scheduler_event(pool: &PgPool, job: &ClaimedJob) -> Result<(Uuid, Uuid), String> {
    if job.job_type != "EVENT_DELIVERY"
        || job.payload.get("eventType").and_then(Value::as_str)
            != Some("workflow.rule_activation_applied.v1")
    {
        return Err("scheduler received an unsupported job".to_owned());
    }
    let event_id = job
        .payload
        .get("eventId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| "eventId is missing".to_owned())?;
    let target = job
        .payload
        .pointer("/payload/targetVersionId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| "targetVersionId is missing".to_owned())?;
    let status =
        sqlx::query_scalar::<_, String>("SELECT status FROM core.rule_versions WHERE id=$1")
            .bind(target)
            .fetch_optional(pool)
            .await
            .map_err(|error| error.to_string())?
            .ok_or_else(|| "target rule version does not exist".to_owned())?;
    if status != "ACTIVE" {
        return Err(format!("target rule version is {status}, expected ACTIVE"));
    }
    Ok((event_id, target))
}

fn job_sqlx(error: gurine_jobs::postgres::JobError) -> sqlx::Error {
    sqlx::Error::Protocol(error.to_string())
}

pub async fn dispatch_batch(pool: &PgPool, limit: i64) -> Result<u64, SchedulerError> {
    let mut count = 0_u64;
    for _ in 0..limit {
        if !dispatch_one(pool).await? {
            break;
        }
        count += 1;
    }
    Ok(count)
}

async fn dispatch_one(pool: &PgPool) -> Result<bool, SchedulerError> {
    let mut tx = pool.begin().await.map_err(SchedulerError::Database)?;
    let row = sqlx::query(
        "SELECT id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at \
         FROM ops.outbox WHERE published_at IS NULL AND available_at<=clock_timestamp() \
         ORDER BY available_at,id LIMIT 1",
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(SchedulerError::Database)?;
    let Some(row) = row else {
        tx.commit().await.map_err(SchedulerError::Database)?;
        return Ok(false);
    };
    let event = Event {
        id: row.try_get("id").map_err(SchedulerError::Database)?,
        aggregate_type: row
            .try_get("aggregate_type")
            .map_err(SchedulerError::Database)?,
        aggregate_id: row
            .try_get("aggregate_id")
            .map_err(SchedulerError::Database)?,
        aggregate_version: row
            .try_get("aggregate_version")
            .map_err(SchedulerError::Database)?,
        event_type: row
            .try_get("event_type")
            .map_err(SchedulerError::Database)?,
        payload: row.try_get("payload").map_err(SchedulerError::Database)?,
        occurred_at: row
            .try_get("occurred_at")
            .map_err(SchedulerError::Database)?,
    };
    for consumer in consumers_for(&event.event_type) {
        let job_id = Uuid::new_v4();
        let inserted = sqlx::query(
            "INSERT INTO ops.inbox(consumer,event_id,result) VALUES($1,$2,$3) \
             ON CONFLICT DO NOTHING",
        )
        .bind(consumer)
        .bind(event.id)
        .bind(format!("DISPATCHED:{job_id}"))
        .execute(&mut *tx)
        .await
        .map_err(SchedulerError::Database)?
        .rows_affected();
        if inserted == 0 {
            continue;
        }
        sqlx::query(
            "INSERT INTO ops.jobs(id,job_type,queue,payload,dedupe_key,max_attempts) \
             VALUES($1,'EVENT_DELIVERY',$2,$3,$4,8)",
        )
        .bind(job_id)
        .bind(consumer)
        .bind(json!({
            "eventId": event.id,
            "eventType": event.event_type,
            "aggregateType": event.aggregate_type,
            "aggregateId": event.aggregate_id,
            "aggregateVersion": event.aggregate_version,
            "occurredAt": event.occurred_at,
            "payload": event.payload,
        }))
        .bind(format!("event:{}:{consumer}", event.id))
        .execute(&mut *tx)
        .await
        .map_err(SchedulerError::Database)?;
    }
    let marked: Option<Uuid> = sqlx::query_scalar(
        "SELECT ops.enqueue_outbox('internal.outbox_dispatch',$1,0, \
         'internal.mark_outbox_published.v1','{}'::jsonb,clock_timestamp())",
    )
    .bind(event.id.to_string())
    .fetch_one(&mut *tx)
    .await
    .map_err(SchedulerError::Database)?;
    if marked != Some(event.id) {
        return Err(SchedulerError::Database(sqlx::Error::RowNotFound));
    }
    tx.commit().await.map_err(SchedulerError::Database)?;
    tracing::info!(event_id=%event.id,event_type=%event.event_type,"outbox event dispatched");
    Ok(true)
}

fn consumers_for(event_type: &str) -> &'static [&'static str] {
    match event_type {
        "workflow.rule_activation_applied.v1" => &["analysis-worker", "scheduler"],
        "source.document_stored.v1" => &["document-extractor"],
        "source.document_parsed.v1" => &["ingest-worker"],
        "projection.publication_access_changed.v1"
        | "projection.publication_revision_created.v1" => &["projection-worker"],
        "agent.run_completed.v1"
        | "attachment.correction_scan_requested.v1"
        | "attachment.response_scan_requested.v1"
        | "audit.export_requested.v1"
        | "detection.signal_created.v1"
        | "export.dataset_requested.v1"
        | "source.schema_drift_detected.v1"
        | "workflow.response_submitted.v1" => &["workflow-worker"],
        "attachment.scan_completed.v1"
        | "intake.contact_received.v1"
        | "notification.correction_received.v1"
        | "notification.correction_resolved.v1"
        | "notification.publication_created.v1"
        | "notification.response_extension_requested.v1"
        | "notification.response_request_delivery_requested.v1"
        | "notification.response_submitted.v1"
        | "notification.subscription_verification_requested.v1"
        | "notification.user_invitation_requested.v1"
        | "projection.publication_applied.v1" => &["notification-worker"],
        _ => &[],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn consumer_catalog_contract_is_embedded() {
        assert_eq!(
            consumers_for("source.document_stored.v1"),
            &["document-extractor"]
        );
        assert_eq!(
            consumers_for("source.document_parsed.v1"),
            &["ingest-worker"]
        );
        assert_eq!(
            consumers_for("workflow.rule_activation_applied.v1"),
            &["analysis-worker", "scheduler"]
        );
        assert!(consumers_for("case.assigned.v1").is_empty());
    }
}
