use std::{path::Path, sync::Arc, time::Duration};

use arrow_array::{ArrayRef, RecordBatch, StringArray};
use arrow_schema::{DataType, Field, Schema};
use gurine_jobs::postgres::{ClaimedJob, JobError, Worker};
use gurine_object_store::{
    filesystem,
    gateway::GatewayObjectStore,
    port::{ObjectStoreClient, ObjectStoreError},
};
use gurine_persistence_postgres::pool::{PoolConfig, connect};
use parquet::arrow::ArrowWriter;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    config::{Config, ObjectStoreConfig},
    handlers::attachment_scan::{ClamAvScanner, ScanResult},
};

enum Store {
    Filesystem(ObjectStoreClient),
    Gateway(GatewayObjectStore),
}

#[derive(Debug, Error)]
pub enum WorkerError {
    #[error("workflow worker initialization failed")]
    Initialization,
    #[error("workflow worker database operation failed")]
    Database,
    #[error("workflow worker dependency is unavailable")]
    Dependency,
    #[error("workflow worker job operation failed")]
    Job(#[source] JobError),
}

#[derive(Debug)]
enum Failure {
    Terminal(&'static str, String),
    Retryable(&'static str, String),
}

pub async fn run(config: Config) -> Result<(), WorkerError> {
    let pool = connect(&PoolConfig {
        database_url: config.database_url.clone(),
        max_connections: 4,
        acquire_timeout: Duration::from_secs(10),
    })
    .await
    .map_err(|_| WorkerError::Initialization)?;
    let store = open_store(&config.object_store).await?;
    let scanner = ClamAvScanner::new(config.clamav_host.clone(), config.clamav_port);
    let worker = Worker::new(
        config.worker_id.clone(),
        "workflow-worker".to_owned(),
        config.job_lease,
    )
    .map_err(WorkerError::Job)?;
    loop {
        let processed = if process_event_one(&pool, &store, &scanner, &worker).await? {
            true
        } else {
            process_pending_scan(&pool, &store, &scanner).await?
        };
        if config.once {
            if !processed {
                return Ok(());
            }
        } else if !processed {
            tokio::time::sleep(config.poll_interval).await;
        }
    }
}

async fn open_store(config: &ObjectStoreConfig) -> Result<Store, WorkerError> {
    match config {
        ObjectStoreConfig::Filesystem(root) => {
            tokio::fs::create_dir_all(root)
                .await
                .map_err(|_| WorkerError::Initialization)?;
            filesystem::open(Path::new(root))
                .map(Store::Filesystem)
                .map_err(|_| WorkerError::Initialization)
        }
        ObjectStoreConfig::Gateway(url) => GatewayObjectStore::new(url.clone(), "workflow-worker")
            .map(Store::Gateway)
            .map_err(|_| WorkerError::Initialization),
    }
}

async fn process_event_one(
    pool: &PgPool,
    store: &Store,
    scanner: &ClamAvScanner,
    worker: &Worker,
) -> Result<bool, WorkerError> {
    let Some(job) = worker.claim(pool).await.map_err(WorkerError::Job)? else {
        return Ok(false);
    };
    match handle_event(pool, store, scanner, &job).await {
        Ok(metrics) => worker
            .complete(pool, &job, metrics)
            .await
            .map_err(WorkerError::Job)?,
        Err(Failure::Terminal(code, detail)) => {
            worker
                .fail(pool, &job, code, &detail, false, json!({}))
                .await
                .map_err(WorkerError::Job)?;
        }
        Err(Failure::Retryable(code, detail)) => {
            worker
                .fail(pool, &job, code, &detail, true, json!({}))
                .await
                .map_err(WorkerError::Job)?;
        }
    }
    Ok(true)
}

async fn handle_event(
    pool: &PgPool,
    store: &Store,
    scanner: &ClamAvScanner,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    if job.job_type != "EVENT_DELIVERY" {
        return Err(Failure::Terminal(
            "UNSUPPORTED_JOB_TYPE",
            job.job_type.clone(),
        ));
    }
    let event_type = job
        .payload
        .get("eventType")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "eventType is missing".to_owned()))?;
    let event_id = value_uuid(&job.payload, "eventId")?;
    let aggregate_id = value_uuid(&job.payload, "aggregateId")?;
    let payload = job
        .payload
        .get("payload")
        .and_then(Value::as_object)
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "payload is missing".to_owned()))?;
    let processed: bool = sqlx::query_scalar(
        "SELECT processed_at IS NOT NULL FROM ops.inbox \
         WHERE consumer='workflow-worker' AND event_id=$1",
    )
    .bind(event_id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("INBOX_MISSING", event_id.to_string()))?;
    if processed {
        return Ok(json!({"deduplicated":true,"eventId":event_id}));
    }

    let metrics = match event_type {
        "agent.run_completed.v1" => reconcile_agent_run(pool, payload).await?,
        "attachment.correction_scan_requested.v1" => {
            scan_attachment(pool, store, scanner, "CORRECTION", aggregate_id).await?
        }
        "attachment.response_scan_requested.v1" => {
            scan_attachment(pool, store, scanner, "RESPONSE", aggregate_id).await?
        }
        "audit.export_requested.v1" => export_audit(pool, store, aggregate_id).await?,
        "detection.signal_created.v1" => create_signal_task(pool, payload).await?,
        "export.dataset_requested.v1" => export_dataset(pool, store, aggregate_id).await?,
        "source.schema_drift_detected.v1" => reconcile_schema_drift(pool, payload).await?,
        "workflow.response_submitted.v1" => reconcile_response(pool, aggregate_id).await?,
        _ => {
            return Err(Failure::Terminal(
                "UNSUPPORTED_EVENT_TYPE",
                event_type.to_owned(),
            ));
        }
    };
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='workflow-worker' AND event_id=$1 AND processed_at IS NULL",
    )
    .bind(event_id)
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal(
            "INBOX_FENCE_FAILED",
            event_id.to_string(),
        ));
    }
    tracing::info!(%event_id,event_type,"workflow event reconciled");
    Ok(metrics)
}

async fn scan_attachment(
    pool: &PgPool,
    store: &Store,
    scanner: &ClamAvScanner,
    kind: &str,
    id: Uuid,
) -> Result<Value, Failure> {
    let sql = match kind {
        "RESPONSE" => {
            "SELECT object_key,size_bytes,sha256::text FROM intake.response_attachments \
             WHERE id=$1 AND upload_status='FINALIZED' AND scan_status='PENDING'"
        }
        "CORRECTION" => {
            "SELECT object_key,size_bytes,sha256::text FROM intake.correction_draft_attachments \
             WHERE id=$1 AND upload_status='FINALIZED' AND scan_status='PENDING'"
        }
        _ => {
            return Err(Failure::Terminal(
                "ATTACHMENT_KIND_INVALID",
                kind.to_owned(),
            ));
        }
    };
    let row = sqlx::query(sql)
        .bind(id)
        .fetch_optional(pool)
        .await
        .map_err(database)?
        .ok_or_else(|| Failure::Terminal("ATTACHMENT_NOT_PENDING", id.to_string()))?;
    let key: String = row.try_get("object_key").map_err(database)?;
    let expected_size: i64 = row.try_get("size_bytes").map_err(database)?;
    let expected_sha256: String = row.try_get::<String, _>("sha256").map_err(database)?;
    let bytes = get(store, &key, expected_sha256.trim())
        .await
        .map_err(|error| match error {
            ObjectStoreError::DigestMismatch | ObjectStoreError::InvalidKey => {
                Failure::Terminal("ATTACHMENT_OBJECT_INVALID", id.to_string())
            }
            ObjectStoreError::Backend(error) => {
                Failure::Retryable("OBJECT_STORE_UNAVAILABLE", error.to_string())
            }
        })?;
    if i64::try_from(bytes.len()).ok() != Some(expected_size) {
        return Err(Failure::Terminal(
            "ATTACHMENT_SIZE_MISMATCH",
            id.to_string(),
        ));
    }
    let status = match scanner.scan(&bytes).await {
        Ok(ScanResult::Clean) => "CLEAN",
        Ok(ScanResult::Infected) => "INFECTED",
        Err(error) => return Err(Failure::Retryable("SCANNER_UNAVAILABLE", error.to_string())),
    };
    let event_id: Uuid = sqlx::query_scalar(
        "SELECT ops.enqueue_outbox('attachment',$1,1,'attachment.scan_completed.v1',$2,clock_timestamp())",
    )
    .bind(id.to_string())
    .bind(json!({"attachment_id":id,"attachment_kind":kind,"scan_status":status,
        "sha256":expected_sha256.trim()}))
    .fetch_one(pool)
    .await
    .map_err(database)?;
    tracing::info!(attachment_id=%id, attachment_kind=%kind, scan_status=status, %event_id, "attachment scan completed");
    Ok(json!({"attachmentId":id,"attachmentKind":kind,"scanStatus":status,"eventId":event_id}))
}

async fn reconcile_agent_run(
    pool: &PgPool,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    let run_id = object_uuid(payload, "agent_run_id")?;
    let case_id = object_uuid(payload, "case_id")?;
    let expected = payload
        .get("output_digest")
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or_else(|| Failure::Terminal("INVALID_AGENT_EVENT", "output digest".to_owned()))?;
    let row =
        sqlx::query("SELECT status,output_payload FROM ops.agent_runs WHERE id=$1 AND case_id=$2")
            .bind(run_id)
            .bind(case_id)
            .fetch_optional(pool)
            .await
            .map_err(database)?
            .ok_or_else(|| Failure::Terminal("AGENT_RUN_NOT_FOUND", run_id.to_string()))?;
    let status: String = row.try_get("status").map_err(database)?;
    let output: Option<Value> = row.try_get("output_payload").map_err(database)?;
    if status != "SUCCEEDED" {
        return Err(Failure::Terminal("AGENT_RUN_NOT_SUCCEEDED", status));
    }
    let output = output.ok_or_else(|| {
        Failure::Terminal("AGENT_OUTPUT_MISSING", "output payload is null".to_owned())
    })?;
    if sha256(
        &serde_json::to_vec(&output)
            .map_err(|error| Failure::Terminal("AGENT_OUTPUT_INVALID", error.to_string()))?,
    ) != expected
    {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_DIGEST_MISMATCH",
            run_id.to_string(),
        ));
    }
    let suggestions: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM ops.agent_suggestions WHERE agent_run_id=$1 AND status='PENDING'",
    )
    .bind(run_id)
    .fetch_one(pool)
    .await
    .map_err(database)?;
    if suggestions > 0 {
        sqlx::query(
            "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority) \
             VALUES('AGENT_REVIEW','AGENT_RUN',$1,'Review agent suggestions','OPEN','NORMAL') \
             ON CONFLICT DO NOTHING",
        )
        .bind(run_id)
        .execute(pool)
        .await
        .map_err(database)?;
    }
    Ok(json!({"agentRunId":run_id,"suggestions":suggestions}))
}

async fn export_audit(pool: &PgPool, store: &Store, id: Uuid) -> Result<Value, Failure> {
    let row = sqlx::query(
        "UPDATE ops.audit_exports SET status='RUNNING',started_at=COALESCE(started_at,clock_timestamp()) \
         WHERE id=$1 AND status IN ('QUEUED','RUNNING') \
         RETURNING from_at,to_at,format,scope,object_type,object_id,watermark_policy",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("AUDIT_EXPORT_NOT_QUEUED", id.to_string()))?;
    let from: time::OffsetDateTime = row.try_get("from_at").map_err(database)?;
    let to: time::OffsetDateTime = row.try_get("to_at").map_err(database)?;
    let format: String = row.try_get("format").map_err(database)?;
    let scope: String = row.try_get("scope").map_err(database)?;
    let object_type: Option<String> = row.try_get("object_type").map_err(database)?;
    let object_id: Option<String> = row.try_get("object_id").map_err(database)?;
    let watermark: String = row.try_get("watermark_policy").map_err(database)?;
    let rows = sqlx::query(
        "SELECT id,occurred_at,actor_type,actor_id,action,object_type,object_id,capability, \
         outcome::text outcome,reason,request_id,details,event_hash,previous_event_hash \
         FROM ops.audit_events WHERE occurred_at >= $1 AND occurred_at <= $2 \
           AND ($3='GLOBAL' OR ($3='CASE' AND object_type='case' AND object_id=$5) \
             OR ($3='OBJECT' AND upper(object_type)=upper($4) AND object_id=$5)) \
         ORDER BY occurred_at,id LIMIT 1000001",
    )
    .bind(from)
    .bind(to)
    .bind(&scope)
    .bind(object_type.as_deref())
    .bind(object_id.as_deref())
    .fetch_all(pool)
    .await
    .map_err(database)?;
    if rows.len() > 1_000_000 {
        return Err(Failure::Terminal(
            "AUDIT_EXPORT_LIMIT",
            "more than 1000000 rows".to_owned(),
        ));
    }
    let bytes = if format == "JSONL" {
        let mut output = Vec::new();
        for row in &rows {
            let value = audit_row(row)?;
            serde_json::to_writer(&mut output, &value)
                .map_err(|error| Failure::Terminal("AUDIT_SERIALIZE", error.to_string()))?;
            output.push(b'\n');
        }
        output
    } else if format == "CSV" {
        let mut output = b"id,occurred_at,actor_type,actor_id,action,object_type,object_id,capability,outcome,reason,request_id,event_hash,previous_event_hash\n".to_vec();
        for row in &rows {
            let fields = [
                row.try_get::<Uuid, _>("id").map_err(database)?.to_string(),
                row.try_get::<time::OffsetDateTime, _>("occurred_at")
                    .map_err(database)?
                    .to_string(),
                row.try_get::<String, _>("actor_type").map_err(database)?,
                row.try_get::<Option<String>, _>("actor_id")
                    .map_err(database)?
                    .unwrap_or_default(),
                row.try_get::<String, _>("action").map_err(database)?,
                row.try_get::<Option<String>, _>("object_type")
                    .map_err(database)?
                    .unwrap_or_default(),
                row.try_get::<Option<String>, _>("object_id")
                    .map_err(database)?
                    .unwrap_or_default(),
                row.try_get::<Option<String>, _>("capability")
                    .map_err(database)?
                    .unwrap_or_default(),
                row.try_get::<String, _>("outcome").map_err(database)?,
                row.try_get::<Option<String>, _>("reason")
                    .map_err(database)?
                    .unwrap_or_default(),
                row.try_get::<Uuid, _>("request_id")
                    .map_err(database)?
                    .to_string(),
                row.try_get::<String, _>("event_hash")
                    .map_err(database)?
                    .trim()
                    .to_owned(),
                row.try_get::<Option<String>, _>("previous_event_hash")
                    .map_err(database)?
                    .unwrap_or_default()
                    .trim()
                    .to_owned(),
            ];
            output.extend_from_slice(
                fields
                    .iter()
                    .map(|field| csv_field(field))
                    .collect::<Vec<_>>()
                    .join(",")
                    .as_bytes(),
            );
            output.push(b'\n');
        }
        output
    } else {
        return Err(Failure::Terminal("AUDIT_FORMAT_INVALID", format));
    };
    if bytes.len() > 200 * 1024 * 1024 {
        return Err(Failure::Terminal(
            "AUDIT_EXPORT_SIZE",
            bytes.len().to_string(),
        ));
    }
    let digest = sha256(&bytes);
    let extension = if format == "CSV" { "csv" } else { "jsonl" };
    let key = format!("exports/audit/{id}/{digest}.{extension}");
    put(store, &key, bytes, &digest).await?;
    let changed = sqlx::query(
        "UPDATE ops.audit_exports SET status='READY',object_key=$2,content_sha256=$3, \
         row_count=$4,completed_at=clock_timestamp() WHERE id=$1 AND status='RUNNING'",
    )
    .bind(id)
    .bind(&key)
    .bind(&digest)
    .bind(
        i64::try_from(rows.len())
            .map_err(|_| Failure::Terminal("AUDIT_EXPORT_LIMIT", rows.len().to_string()))?,
    )
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal("AUDIT_EXPORT_FENCE", id.to_string()));
    }
    Ok(
        json!({"auditExportId":id,"rowCount":rows.len(),"contentSha256":digest,
        "objectKey":key,"watermarkPolicy":watermark}),
    )
}

fn audit_row(row: &sqlx::postgres::PgRow) -> Result<Value, Failure> {
    Ok(json!({
        "id":row.try_get::<Uuid,_>("id").map_err(database)?,
        "occurredAt":row.try_get::<time::OffsetDateTime,_>("occurred_at").map_err(database)?.to_string(),
        "actorType":row.try_get::<String,_>("actor_type").map_err(database)?,
        "actorId":row.try_get::<Option<String>,_>("actor_id").map_err(database)?,
        "action":row.try_get::<String,_>("action").map_err(database)?,
        "objectType":row.try_get::<Option<String>,_>("object_type").map_err(database)?,
        "objectId":row.try_get::<Option<String>,_>("object_id").map_err(database)?,
        "capability":row.try_get::<Option<String>,_>("capability").map_err(database)?,
        "outcome":row.try_get::<String,_>("outcome").map_err(database)?,
        "reason":row.try_get::<Option<String>,_>("reason").map_err(database)?,
        "requestId":row.try_get::<Uuid,_>("request_id").map_err(database)?,
        "details":row.try_get::<Value,_>("details").map_err(database)?,
        "eventHash":row.try_get::<String,_>("event_hash").map_err(database)?.trim(),
        "previousEventHash":row.try_get::<Option<String>,_>("previous_event_hash").map_err(database)?.map(|value|value.trim().to_owned()),
    }))
}

fn csv_field(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

async fn export_dataset(pool: &PgPool, store: &Store, id: Uuid) -> Result<Value, Failure> {
    let row = sqlx::query(
        "UPDATE intake.dataset_export_requests SET status='RUNNING' \
         WHERE id=$1 AND status IN ('QUEUED','RUNNING') \
         RETURNING dataset_id,format,filters,expires_at",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("DATASET_EXPORT_NOT_QUEUED", id.to_string()))?;
    let dataset_id: String = row.try_get("dataset_id").map_err(database)?;
    let format: String = row.try_get("format").map_err(database)?;
    let filters: Value = row.try_get("filters").map_err(database)?;
    let expires_at: time::OffsetDateTime = row.try_get("expires_at").map_err(database)?;
    if expires_at <= time::OffsetDateTime::now_utc() {
        return Err(Failure::Terminal("DATASET_EXPORT_EXPIRED", id.to_string()));
    }
    let dataset: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',id,'title',title,'description',description, \
         'format',format,'coverage',coverage,'license',license,'updatedAt',updated_at) \
         FROM public.datasets WHERE id=$1",
    )
    .bind(&dataset_id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("DATASET_NOT_FOUND", dataset_id.clone()))?;
    let envelope = json!({"dataset":dataset,"filters":filters,"exportedAt":time::OffsetDateTime::now_utc().to_string()});
    let (bytes, extension) = match format.as_str() {
        "JSONL" => {
            let mut bytes = serde_json::to_vec(&envelope)
                .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?;
            bytes.push(b'\n');
            (bytes, "jsonl")
        }
        "CSV" => {
            let line = [
                dataset_id.clone(),
                dataset
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                dataset
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                serde_json::to_string(&filters)
                    .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?,
            ]
            .iter()
            .map(|value| csv_field(value))
            .collect::<Vec<_>>()
            .join(",");
            (
                format!("dataset_id,title,description,filters\n{line}\n").into_bytes(),
                "csv",
            )
        }
        "PARQUET" => (dataset_parquet(&dataset_id, &dataset, &filters)?, "parquet"),
        _ => return Err(Failure::Terminal("DATASET_FORMAT_INVALID", format)),
    };
    let digest = sha256(&bytes);
    let key = format!("exports/datasets/{id}/{digest}.{extension}");
    put(store, &key, bytes, &digest).await?;
    let changed = sqlx::query(
        "UPDATE intake.dataset_export_requests SET status='READY',object_key=$2, \
         completed_at=clock_timestamp() WHERE id=$1 AND status='RUNNING'",
    )
    .bind(id)
    .bind(&key)
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal("DATASET_EXPORT_FENCE", id.to_string()));
    }
    Ok(json!({"datasetExportId":id,"contentSha256":digest,"objectKey":key}))
}

fn dataset_parquet(dataset_id: &str, dataset: &Value, filters: &Value) -> Result<Vec<u8>, Failure> {
    let title = dataset
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let description = dataset
        .get("description")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let filters = serde_json::to_string(filters)
        .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?;
    let exported_at = time::OffsetDateTime::now_utc().to_string();
    let schema = Arc::new(Schema::new(vec![
        Field::new("dataset_id", DataType::Utf8, false),
        Field::new("title", DataType::Utf8, false),
        Field::new("description", DataType::Utf8, false),
        Field::new("filters_json", DataType::Utf8, false),
        Field::new("exported_at", DataType::Utf8, false),
    ]));
    let columns: Vec<ArrayRef> = vec![
        Arc::new(StringArray::from(vec![dataset_id])),
        Arc::new(StringArray::from(vec![title])),
        Arc::new(StringArray::from(vec![description])),
        Arc::new(StringArray::from(vec![filters.as_str()])),
        Arc::new(StringArray::from(vec![exported_at.as_str()])),
    ];
    let batch = RecordBatch::try_new(schema.clone(), columns)
        .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?;
    let mut writer = ArrowWriter::try_new(Vec::new(), schema, None)
        .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?;
    writer
        .write(&batch)
        .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))?;
    writer
        .into_inner()
        .map_err(|error| Failure::Terminal("DATASET_SERIALIZE", error.to_string()))
}

async fn create_signal_task(
    pool: &PgPool,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    let signal = object_uuid(payload, "signal_id")?;
    let exists: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM core.anomaly_signals WHERE id=$1)")
            .bind(signal)
            .fetch_one(pool)
            .await
            .map_err(database)?;
    if !exists {
        return Err(Failure::Terminal("SIGNAL_NOT_FOUND", signal.to_string()));
    }
    sqlx::query(
        "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority) \
         SELECT 'SIGNAL_TRIAGE','SIGNAL',$1,'Triage detected signal','OPEN', \
           CASE severity WHEN 'CRITICAL' THEN 'URGENT' WHEN 'HIGH' THEN 'HIGH' ELSE 'NORMAL' END \
         FROM core.anomaly_signals WHERE id=$1 AND NOT EXISTS( \
           SELECT 1 FROM ops.tasks WHERE task_type='SIGNAL_TRIAGE' AND object_id=$1 AND status<>'DONE')",
    )
    .bind(signal)
    .execute(pool)
    .await
    .map_err(database)?;
    Ok(json!({"signalId":signal,"taskCreated":true}))
}

async fn reconcile_schema_drift(
    pool: &PgPool,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    let drift = object_uuid(payload, "schema_drift_id")?;
    let source = payload
        .get("source_id")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| Failure::Terminal("INVALID_SCHEMA_DRIFT", "source_id".to_owned()))?;
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM ops.schema_drifts WHERE id=$1 AND source_id=$2 AND status='OPEN')",
    )
    .bind(drift)
    .bind(source)
    .fetch_one(pool)
    .await
    .map_err(database)?;
    if !exists {
        return Err(Failure::Terminal(
            "SCHEMA_DRIFT_NOT_OPEN",
            drift.to_string(),
        ));
    }
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query("UPDATE ops.source_registry SET enabled=false WHERE source_id=$1")
        .bind(source)
        .execute(&mut *tx)
        .await
        .map_err(database)?;
    sqlx::query(
        "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority,blocker_code) \
         SELECT 'SCHEMA_DRIFT','SCHEMA_DRIFT',$1,'Review source schema drift','OPEN','HIGH', \
           'SOURCE_SCHEMA_DRIFT' WHERE NOT EXISTS(SELECT 1 FROM ops.tasks \
             WHERE task_type='SCHEMA_DRIFT' AND object_id=$1 AND status<>'DONE')",
    )
    .bind(drift)
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)?;
    Ok(json!({"schemaDriftId":drift,"sourceId":source,"sourcePaused":true}))
}

async fn reconcile_response(pool: &PgPool, submission: Uuid) -> Result<Value, Failure> {
    let row = sqlx::query(
        "SELECT s.response_request_id,s.answers_encrypted,s.publication_consent,s.submitted_at, \
         s.editorial_response_id,r.case_id,r.party_name \
         FROM intake.response_submissions s JOIN editorial.response_requests r \
           ON r.id=s.response_request_id WHERE s.id=$1 AND s.status='SUBMITTED'",
    )
    .bind(submission)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("RESPONSE_SUBMISSION_NOT_FOUND", submission.to_string()))?;
    if let Some(existing) = row
        .try_get::<Option<Uuid>, _>("editorial_response_id")
        .map_err(database)?
    {
        return Ok(json!({"submissionId":submission,"responseId":existing,"deduplicated":true}));
    }
    let response_id = Uuid::new_v4();
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query(
        "INSERT INTO editorial.responses(id,case_id,response_request_id,party_name,submitted_at, \
         full_text_encrypted,publication_consent,editorial_status) \
         VALUES($1,$2,$3,$4,$5,$6,$7,'PENDING')",
    )
    .bind(response_id)
    .bind(row.try_get::<Uuid, _>("case_id").map_err(database)?)
    .bind(
        row.try_get::<Uuid, _>("response_request_id")
            .map_err(database)?,
    )
    .bind(row.try_get::<String, _>("party_name").map_err(database)?)
    .bind(
        row.try_get::<time::OffsetDateTime, _>("submitted_at")
            .map_err(database)?,
    )
    .bind(
        row.try_get::<Vec<u8>, _>("answers_encrypted")
            .map_err(database)?,
    )
    .bind(
        row.try_get::<Value, _>("publication_consent")
            .map_err(database)?,
    )
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    let changed = sqlx::query(
        "UPDATE intake.response_submissions SET editorial_response_id=$2 \
         WHERE id=$1 AND editorial_response_id IS NULL",
    )
    .bind(submission)
    .bind(response_id)
    .execute(&mut *tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal(
            "RESPONSE_SUBMISSION_FENCE",
            submission.to_string(),
        ));
    }
    tx.commit().await.map_err(database)?;
    Ok(json!({"submissionId":submission,"responseId":response_id}))
}

async fn process_pending_scan(
    pool: &PgPool,
    store: &Store,
    scanner: &ClamAvScanner,
) -> Result<bool, WorkerError> {
    let mut transaction = pool.begin().await.map_err(|_| WorkerError::Database)?;
    let correction = sqlx::query(
        "SELECT id,object_key,size_bytes,sha256::text AS sha256 \
         FROM intake.correction_draft_attachments \
         WHERE upload_status='FINALIZED' AND scan_status='PENDING' \
         ORDER BY created_at,id LIMIT 1",
    )
    .fetch_optional(&mut *transaction)
    .await
    .map_err(|_| WorkerError::Database)?;
    let (kind, row) = if let Some(row) = correction {
        ("CORRECTION", row)
    } else {
        let response = sqlx::query(
            "SELECT id,object_key,size_bytes,sha256::text AS sha256 \
             FROM intake.response_attachments \
             WHERE upload_status='FINALIZED' AND scan_status='PENDING' \
             ORDER BY created_at,id LIMIT 1",
        )
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| WorkerError::Database)?;
        let Some(row) = response else {
            transaction
                .rollback()
                .await
                .map_err(|_| WorkerError::Database)?;
            return Ok(false);
        };
        ("RESPONSE", row)
    };
    let id: Uuid = row.try_get("id").map_err(|_| WorkerError::Database)?;
    let locked: bool =
        sqlx::query_scalar("SELECT pg_try_advisory_xact_lock(hashtextextended($1,0))")
            .bind(format!("attachment-scan:{id}"))
            .fetch_one(&mut *transaction)
            .await
            .map_err(|_| WorkerError::Database)?;
    if !locked {
        transaction
            .rollback()
            .await
            .map_err(|_| WorkerError::Database)?;
        return Ok(false);
    }
    let key: String = row
        .try_get("object_key")
        .map_err(|_| WorkerError::Database)?;
    let size: i64 = row
        .try_get("size_bytes")
        .map_err(|_| WorkerError::Database)?;
    let digest: String = row
        .try_get::<String, _>("sha256")
        .map_err(|_| WorkerError::Database)?;
    let bytes = get(store, &key, digest.trim())
        .await
        .map_err(|error| match error {
            ObjectStoreError::Backend(_) => WorkerError::Dependency,
            ObjectStoreError::DigestMismatch | ObjectStoreError::InvalidKey => {
                WorkerError::Database
            }
        })?;
    if i64::try_from(bytes.len()).ok() != Some(size) {
        return Err(WorkerError::Database);
    }
    let status = match scanner.scan(&bytes).await {
        Ok(ScanResult::Clean) => "CLEAN",
        Ok(ScanResult::Infected) => "INFECTED",
        Err(_) => return Err(WorkerError::Dependency),
    };
    let event_id: Uuid = sqlx::query_scalar(
        "SELECT ops.enqueue_outbox('attachment',$1,1,'attachment.scan_completed.v1',$2,clock_timestamp())",
    )
    .bind(id.to_string())
    .bind(json!({"attachment_id":id,"attachment_kind":kind,"scan_status":status,
        "sha256":digest.trim()}))
    .fetch_one(&mut *transaction)
    .await
    .map_err(|_| WorkerError::Database)?;
    transaction
        .commit()
        .await
        .map_err(|_| WorkerError::Database)?;
    tracing::info!(attachment_id=%id, attachment_kind=%kind, scan_status=status, %event_id, "pending attachment scan completed");
    Ok(true)
}

async fn get(store: &Store, key: &str, expected_sha256: &str) -> Result<Vec<u8>, ObjectStoreError> {
    match store {
        Store::Filesystem(client) => client.get(key, Some(expected_sha256)).await,
        Store::Gateway(client) => client.get(key, Some(expected_sha256)).await,
    }
}

async fn put(
    store: &Store,
    key: &str,
    bytes: Vec<u8>,
    expected_sha256: &str,
) -> Result<(), Failure> {
    let result = match store {
        Store::Filesystem(client) => client.put(key, bytes, expected_sha256).await,
        Store::Gateway(client) => client.put(key, bytes, expected_sha256).await,
    };
    match result {
        Ok(_) => Ok(()),
        Err(ObjectStoreError::InvalidKey | ObjectStoreError::DigestMismatch) => {
            Err(Failure::Terminal("OBJECT_STORE_CONTRACT", key.to_owned()))
        }
        Err(ObjectStoreError::Backend(error)) => Err(Failure::Retryable(
            "OBJECT_STORE_UNAVAILABLE",
            error.to_string(),
        )),
    }
}

fn value_uuid(value: &Value, key: &str) -> Result<Uuid, Failure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", format!("{key} is invalid")))
}

fn object_uuid(value: &serde_json::Map<String, Value>, key: &str) -> Result<Uuid, Failure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT_PAYLOAD", format!("{key} is invalid")))
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn sha256(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn database(error: sqlx::Error) -> Failure {
    Failure::Retryable("DATABASE_UNAVAILABLE", error.to_string())
}

#[cfg(test)]
mod tests {
    use arrow_array::StringArray;
    use bytes::Bytes;
    use parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder;
    use serde_json::json;

    use super::dataset_parquet;

    #[test]
    fn dataset_parquet_round_trips_with_apache_reader() {
        let bytes = dataset_parquet(
            "dataset-1",
            &json!({"title":"Dataset","description":"Description"}),
            &json!({"year":2026}),
        )
        .expect("parquet export");
        assert_eq!(&bytes[..4], b"PAR1");
        assert_eq!(&bytes[bytes.len() - 4..], b"PAR1");
        let mut reader = ParquetRecordBatchReaderBuilder::try_new(Bytes::from(bytes))
            .expect("parquet metadata")
            .build()
            .expect("parquet reader");
        let batch = reader.next().expect("one batch").expect("valid batch");
        assert_eq!(batch.num_rows(), 1);
        assert!(reader.next().is_none());
        let ids = batch
            .column(0)
            .as_any()
            .downcast_ref::<StringArray>()
            .expect("dataset_id string column");
        assert_eq!(ids.value(0), "dataset-1");
    }
}
