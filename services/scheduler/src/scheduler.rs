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
use crate::consumer_catalog::consumers_for;
use crate::relay_model_catalog_sync::schedule_relay_model_catalog_sync;

#[derive(Debug, Error)]
pub enum SchedulerError {
    #[error("scheduler initialization failed")]
    Initialization,
    #[error("scheduler database operation failed: {0}")]
    Database(#[source] sqlx::Error),
    #[error("scheduler event routing failed: {0}")]
    EventRouting(&'static str),
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
        let activity = run_cycle(&pool, &event_worker, &config).await?;
        if config.once {
            if activity.is_idle() {
                return Ok(());
            }
        } else if activity.is_idle() && wait_for_work(config.poll_interval).await? {
            return Ok(());
        }
    }
}

struct CycleActivity {
    recovered: u64,
    source_runs: u64,
    delivery_polls: u64,
    snapshot_builds: u64,
    catalog_syncs: u64,
    publication_expiry: Option<Uuid>,
    dispatched: u64,
    consumed: bool,
}

impl CycleActivity {
    fn is_idle(&self) -> bool {
        self.recovered == 0
            && self.source_runs == 0
            && self.delivery_polls == 0
            && self.snapshot_builds == 0
            && self.catalog_syncs == 0
            && self.publication_expiry.is_none()
            && self.dispatched == 0
            && !self.consumed
    }
}

async fn run_cycle(
    pool: &PgPool,
    event_worker: &Worker,
    config: &Config,
) -> Result<CycleActivity, SchedulerError> {
    let recovered = recover_expired(pool, 100).await.map_err(|error| {
        tracing::error!(stage="recover_expired", error=%error, "scheduler stage failed");
        SchedulerError::Database(job_sqlx(error))
    })?;
    let source_runs = schedule_source_runs(pool, config.batch_size)
        .await
        .map_err(|error| log_stage_error("schedule_source_runs", error))?;
    let delivery_polls = schedule_delivery_poll_requests(pool, config.batch_size)
        .await
        .map_err(|error| log_stage_error("schedule_delivery_poll_requests", error))?;
    let snapshot_builds = schedule_detection_snapshot_builds(pool, config.batch_size)
        .await
        .map_err(|error| log_stage_error("schedule_detection_snapshot_builds", error))?;
    let catalog_syncs = schedule_relay_model_catalog_sync(pool)
        .await
        .map_err(|error| log_stage_error("schedule_relay_model_catalog_sync", error))?;
    let publication_expiry = enqueue_publication_access_expiry(pool, config.batch_size).await?;
    Ok(CycleActivity {
        recovered,
        source_runs,
        delivery_polls,
        snapshot_builds,
        catalog_syncs,
        publication_expiry,
        dispatched: dispatch_batch(pool, config.batch_size).await?,
        consumed: consume_scheduler_job(pool, event_worker).await?,
    })
}

fn log_stage_error(stage: &'static str, error: SchedulerError) -> SchedulerError {
    tracing::error!(stage, error=%error, "scheduler stage failed");
    error
}

async fn enqueue_publication_access_expiry(
    pool: &PgPool,
    batch_size: i64,
) -> Result<Option<Uuid>, SchedulerError> {
    sqlx::query_scalar!(
        "SELECT ops.enqueue_outbox('internal.publication_access_expiry',$1,0, \
         'internal.expire_due_publication_access.v1',$2,clock_timestamp())",
        batch_size.to_string(),
        json!({"limit":batch_size}),
    )
    .fetch_one(pool)
    .await
    .map_err(|error| {
        tracing::error!(stage="publication_access_expiry", error=%error, "scheduler stage failed");
        SchedulerError::Database(error)
    })
}

async fn wait_for_work(poll_interval: std::time::Duration) -> Result<bool, SchedulerError> {
    tokio::select! {
        () = tokio::time::sleep(poll_interval) => Ok(false),
        signal = tokio::signal::ctrl_c() => {
            signal.map_err(|_| SchedulerError::Initialization)?;
            tracing::info!("scheduler shutdown requested");
            Ok(true)
        }
    }
}

/// Ask the database owner routine to create only due, digest-bound detection
/// snapshot jobs. The routine owns deduplication and sees the same authority
/// tables as the later snapshot producer; the scheduler never invents a
/// cohort or a rule configuration.
pub async fn schedule_detection_snapshot_builds(
    pool: &PgPool,
    limit: i64,
) -> Result<u64, SchedulerError> {
    let count = sqlx::query_scalar!(
        r#"SELECT ops.enqueue_due_detection_snapshot_builds_v1($1) AS "count!""#,
        limit,
    )
    .fetch_one(pool)
    .await
    .map_err(SchedulerError::Database)?;
    u64::try_from(count).map_err(|_| SchedulerError::Initialization)
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
    let applied = sqlx::query_scalar!(
        "SELECT ops.enqueue_outbox('internal.rule_activation',$1,0, \
         'internal.apply_due_rule_activation.v1',$2,clock_timestamp())",
        rule_version_id.to_string(),
        json!({"ruleVersionId":rule_version_id,"actorId":actor_id,"requestId":request_id}),
    )
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
            let changed = sqlx::query!(
                "UPDATE ops.inbox SET processed_at=COALESCE(processed_at,clock_timestamp()),result='SUCCEEDED' \
                 WHERE consumer='scheduler' AND event_id=$1",
                event_id,
            )
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
    let sources = sqlx::query!(
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
        let source_id = row.source_id;
        let expression = row.schedule_cron;
        let last = row.last_scheduled_for;
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
        let inserted = sqlx::query_scalar!(
            "INSERT INTO ops.source_runs(id,source_id,mode,status,scheduled_for,schedule_expression) \
             VALUES($1,$2,'INCREMENTAL','QUEUED',$3,$4) \
             ON CONFLICT(source_id,scheduled_for) WHERE scheduled_for IS NOT NULL DO NOTHING \
             RETURNING id",
            run_id,
            &source_id,
            due,
            &expression,
        )
        .fetch_optional(&mut *tx)
        .await
        .map_err(SchedulerError::Database)?;
        if inserted.is_none() {
            tx.commit().await.map_err(SchedulerError::Database)?;
            continue;
        }
        sqlx::query!(
            "INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,max_attempts) \
             VALUES('SOURCE_RUN','ingest-worker',$1,$2,8)",
            json!({"sourceRunId":run_id,"scheduledFor":due}),
            format!("source-run:{source_id}:{}", due.unix_timestamp_nanos()),
        )
        .execute(&mut *tx)
        .await
        .map_err(SchedulerError::Database)?;
        tx.commit().await.map_err(SchedulerError::Database)?;
        scheduled += 1;
        tracing::info!(%source_id,%run_id,scheduled_for=%due,"source run scheduled");
    }
    Ok(scheduled)
}

/// Queue one internal provider-poll job for each due Solapi delivery. Polling
/// is orchestration, not a domain event: only an applied provider observation
/// may emit the authority-declared delivery receipt event.
pub async fn schedule_delivery_poll_requests(
    pool: &PgPool,
    limit: i64,
) -> Result<u64, SchedulerError> {
    let rows = sqlx::query(
        r#"SELECT id,version,channel,provider_message_id,provider_config_id,
                provider_config_version,provider_configuration_digest,
                provider_preflight_receipt_id,provider_preflight_receipt_digest
           FROM ops.outbound_deliveries
          WHERE state='PROVIDER_ACCEPTED'
            AND channel IN ('SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE')
            AND provider_message_id IS NOT NULL AND dispatch_eligible
            AND next_attempt_at<=clock_timestamp()
          ORDER BY next_attempt_at,id LIMIT $1"#,
    )
    .bind(limit)
    .fetch_all(pool)
    .await
    .map_err(SchedulerError::Database)?;
    let mut emitted = 0_u64;
    for row in rows {
        let id: Uuid = row.try_get("id").map_err(SchedulerError::Database)?;
        let version: i64 = row.try_get("version").map_err(SchedulerError::Database)?;
        let channel: String = row.try_get("channel").map_err(SchedulerError::Database)?;
        let provider_message_id: String = row
            .try_get("provider_message_id")
            .map_err(SchedulerError::Database)?;
        let config_id: Uuid = row
            .try_get("provider_config_id")
            .map_err(SchedulerError::Database)?;
        let config_version: i64 = row
            .try_get("provider_config_version")
            .map_err(SchedulerError::Database)?;
        let configuration_digest: String = row
            .try_get("provider_configuration_digest")
            .map_err(SchedulerError::Database)?;
        let preflight_id: Uuid = row
            .try_get("provider_preflight_receipt_id")
            .map_err(SchedulerError::Database)?;
        let preflight_digest: String = row
            .try_get("provider_preflight_receipt_digest")
            .map_err(SchedulerError::Database)?;
        let poll_key = format!("communication-provider-poll:{id}:{version}:{provider_message_id}");
        let inserted = sqlx::query!(
            "INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key,max_attempts) \
             VALUES('COMMUNICATION_PROVIDER_POLL','notification-worker',$1,$2,8) \
             ON CONFLICT DO NOTHING",
            json!({
                "deliveryId": id,
                "expectedDeliveryVersion": version,
                "channel": channel,
                "providerMessageId": provider_message_id,
                "providerConfigId": config_id,
                "providerConfigVersion": config_version,
                "providerConfigurationDigest": configuration_digest,
                "providerPreflightReceiptId": preflight_id,
                "providerPreflightReceiptDigest": preflight_digest,
            }),
            poll_key,
        )
        .execute(pool)
        .await
        .map_err(SchedulerError::Database)?
        .rows_affected();
        emitted += inserted;
    }
    Ok(emitted)
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
    let status = sqlx::query_scalar!("SELECT status FROM core.rule_versions WHERE id=$1", target)
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
    let row = sqlx::query_as!(
        Event,
        "SELECT id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at \
         FROM ops.outbox WHERE published_at IS NULL AND available_at<=clock_timestamp() \
         ORDER BY available_at,id LIMIT 1",
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(SchedulerError::Database)?;
    let Some(event) = row else {
        tx.commit().await.map_err(SchedulerError::Database)?;
        return Ok(false);
    };
    let consumers =
        consumers_for(&event.event_type, &event.payload).map_err(SchedulerError::EventRouting)?;
    for (consumer, queue) in consumers {
        let job_id = Uuid::new_v4();
        let inserted = sqlx::query!(
            "INSERT INTO ops.inbox(consumer,event_id,result) VALUES($1,$2,$3) \
             ON CONFLICT DO NOTHING",
            consumer,
            event.id,
            format!("DISPATCHED:{job_id}"),
        )
        .execute(&mut *tx)
        .await
        .map_err(SchedulerError::Database)?
        .rows_affected();
        if inserted == 0 {
            continue;
        }
        sqlx::query!(
            "INSERT INTO ops.jobs(id,job_type,queue,payload,dedupe_key,max_attempts) \
             VALUES($1,'EVENT_DELIVERY',$2,$3,$4,8)",
            job_id,
            queue,
            json!({
                "consumerId": consumer,
                "eventId": event.id,
                "eventType": event.event_type,
                "aggregateType": event.aggregate_type,
                "aggregateId": event.aggregate_id,
                "aggregateVersion": event.aggregate_version,
                "occurredAt": event.occurred_at,
                "payload": event.payload,
            }),
            format!("event:{}:{consumer}", event.id),
        )
        .execute(&mut *tx)
        .await
        .map_err(SchedulerError::Database)?;
    }
    let marked: Option<Uuid> = sqlx::query_scalar!(
        "SELECT ops.enqueue_outbox('internal.outbox_dispatch',$1,0, \
         'internal.mark_outbox_published.v1','{}'::jsonb,clock_timestamp())",
        event.id.to_string(),
    )
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
