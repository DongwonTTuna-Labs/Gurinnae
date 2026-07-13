use std::path::{Path, PathBuf};

use gurine_jobs::postgres::{ClaimedJob, JobError, Worker};
use gurine_object_store::{
    filesystem,
    gateway::GatewayObjectStore,
    port::{ObjectStoreClient, ObjectStoreError},
};
use gurine_persistence_postgres::pool::{PoolConfig, connect};
use serde_json::{Value, json};
use sqlx::{PgPool, Row};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    config::{Config, ObjectStoreConfig},
    model::{ExtractionResult, ExtractionStatus, sha256_hex},
};

const PARSER_IMPLEMENTATION_DIGEST: &str =
    "34b412736d397390465b9c085b15b6f4e95ff4733588d12623fb7154b4a3a2eb";

enum Store {
    Filesystem(ObjectStoreClient),
    Gateway(GatewayObjectStore),
}

struct SourceDocument {
    id: Uuid,
    content_type: String,
    content_sha256: String,
    content_size_bytes: i64,
    object_key: String,
    status: String,
}

#[derive(Debug, Error)]
pub enum WorkerError {
    #[error("document extractor initialization failed")]
    Initialization,
    #[error("document extractor database operation failed")]
    Database(#[source] JobError),
    #[error("document extractor object store operation failed")]
    ObjectStore,
    #[error("document extractor job contract is invalid")]
    InvalidJob,
    #[error("document extraction failed")]
    Extraction,
}

pub async fn run(config: Config) -> Result<(), WorkerError> {
    let pool = connect(&PoolConfig {
        database_url: config.database_url.clone(),
        max_connections: 4,
        acquire_timeout: std::time::Duration::from_secs(10),
    })
    .await
    .map_err(|_| WorkerError::Initialization)?;
    let store = open_store(&config.object_store).await?;
    let worker = Worker::new(
        config.worker_id.clone(),
        "document-extractor".to_owned(),
        config.lease,
    )
    .map_err(|_| WorkerError::Initialization)?;
    tracing::info!(worker_id=%config.worker_id,"document extractor ready");
    loop {
        let processed = process_one(&pool, &store, &worker).await?;
        if config.once {
            if !processed {
                return Ok(());
            }
        } else if !processed {
            tokio::select! {
                () = tokio::time::sleep(config.poll_interval) => {},
                signal = tokio::signal::ctrl_c() => {
                    signal.map_err(|_| WorkerError::Initialization)?;
                    tracing::info!("document extractor shutdown requested");
                    return Ok(());
                }
            }
        }
    }
}

async fn open_store(config: &ObjectStoreConfig) -> Result<Store, WorkerError> {
    match config {
        ObjectStoreConfig::Filesystem(root) => {
            tokio::fs::create_dir_all(root)
                .await
                .map_err(|_| WorkerError::Initialization)?;
            filesystem::open(root)
                .map(Store::Filesystem)
                .map_err(|_| WorkerError::Initialization)
        }
        ObjectStoreConfig::Gateway(url) => {
            GatewayObjectStore::new(url.clone(), "document-extractor")
                .map(Store::Gateway)
                .map_err(|_| WorkerError::Initialization)
        }
    }
}

async fn process_one(pool: &PgPool, store: &Store, worker: &Worker) -> Result<bool, WorkerError> {
    let Some(job) = worker.claim(pool).await.map_err(map_job_error)? else {
        return Ok(false);
    };
    match process_claimed(pool, store, &job).await {
        Ok(metrics) => worker
            .complete(pool, &job, metrics)
            .await
            .map_err(map_job_error)?,
        Err(Failure::Terminal(code, detail)) => {
            worker
                .fail(pool, &job, code, &detail, false, json!({}))
                .await
                .map_err(map_job_error)?;
        }
        Err(Failure::Retryable(code, detail)) => {
            worker
                .fail(pool, &job, code, &detail, true, json!({}))
                .await
                .map_err(map_job_error)?;
        }
    }
    Ok(true)
}

enum Failure {
    Terminal(&'static str, String),
    Retryable(&'static str, String),
}

async fn process_claimed(pool: &PgPool, store: &Store, job: &ClaimedJob) -> Result<Value, Failure> {
    if job.job_type != "EVENT_DELIVERY"
        || text(&job.payload, "eventType") != Some("source.document_stored.v1")
    {
        return Err(Failure::Terminal(
            "UNSUPPORTED_JOB_TYPE",
            "document-extractor only accepts source.document_stored.v1".to_owned(),
        ));
    }
    let event_id = uuid(&job.payload, "eventId").ok_or_else(|| {
        Failure::Terminal("INVALID_EVENT", "eventId is missing or invalid".to_owned())
    })?;
    if inbox_processed(pool, event_id).await? {
        return Ok(json!({"deduplicated":true}));
    }
    let source_document_id = job
        .payload
        .pointer("/payload/source_document_id")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| {
            Failure::Terminal(
                "INVALID_EVENT_PAYLOAD",
                "source_document_id is missing or invalid".to_owned(),
            )
        })?;
    let row = sqlx::query(
        "SELECT id,content_type,content_sha256,content_size_bytes,object_key,status::text status \
         FROM raw.source_documents WHERE id=$1",
    )
    .bind(source_document_id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| {
        Failure::Terminal("SOURCE_DOCUMENT_NOT_FOUND", source_document_id.to_string())
    })?;
    let document = SourceDocument {
        id: row.try_get("id").map_err(database)?,
        content_type: row.try_get("content_type").map_err(database)?,
        content_sha256: row
            .try_get::<String, _>("content_sha256")
            .map_err(database)?
            .trim()
            .to_owned(),
        content_size_bytes: row.try_get("content_size_bytes").map_err(database)?,
        object_key: row.try_get("object_key").map_err(database)?,
        status: row.try_get("status").map_err(database)?,
    };
    if document.status != "FETCHED" {
        if matches!(
            document.status.as_str(),
            "PARSED" | "REJECTED" | "QUARANTINED"
        ) {
            mark_inbox(pool, event_id, "DEDUPLICATED").await?;
            return Ok(json!({"deduplicated":true,"sourceDocumentStatus":document.status}));
        }
        return Err(Failure::Terminal(
            "INVALID_SOURCE_DOCUMENT_STATE",
            document.status,
        ));
    }
    let bytes = get(store, &document.object_key, &document.content_sha256)
        .await
        .map_err(|error| match error {
            ObjectStoreError::DigestMismatch | ObjectStoreError::InvalidKey => {
                Failure::Terminal("SOURCE_OBJECT_INTEGRITY_FAILURE", error.to_string())
            }
            ObjectStoreError::Backend(_) => {
                Failure::Retryable("OBJECT_STORE_UNAVAILABLE", error.to_string())
            }
        })?;
    if i64::try_from(bytes.len()).ok() != Some(document.content_size_bytes) {
        return terminal_document(
            pool,
            event_id,
            &document,
            "QUARANTINED",
            "SOURCE_OBJECT_SIZE_MISMATCH",
            "source object size does not match immutable metadata",
        )
        .await;
    }
    let temp = TempDocument::create(&document, &bytes)
        .await
        .map_err(|error| Failure::Retryable("TEMPFILE_UNAVAILABLE", error.to_string()))?;
    let result = crate::extract_path(&temp.path)
        .await
        .map_err(|error| Failure::Retryable("EXTRACTION_IO_FAILURE", error.to_string()))?;
    drop(temp);
    if result.document_sha256 != document.content_sha256 {
        return terminal_document(
            pool,
            event_id,
            &document,
            "QUARANTINED",
            "EXTRACTION_DIGEST_MISMATCH",
            "parser observed bytes different from immutable source digest",
        )
        .await;
    }
    match result.status {
        ExtractionStatus::Extracted => {
            persist_success(pool, store, event_id, &document, &result).await
        }
        ExtractionStatus::Rejected => {
            let code = result
                .rejection_code
                .as_deref()
                .unwrap_or("DOCUMENT_REJECTED");
            let status = if code.contains("HWP_UNSUPPORTED")
                || code.contains("ZIP_")
                || code.contains("EXTERNAL_RELATIONSHIP")
                || code.contains("ENCRYPTED_DOCUMENT")
            {
                "QUARANTINED"
            } else {
                "REJECTED"
            };
            persist_terminal(pool, event_id, &document, &result, status, code).await
        }
        ExtractionStatus::Failed | ExtractionStatus::OcrRequired => Err(Failure::Retryable(
            "PARSER_RUNTIME_FAILURE",
            result
                .rejection_code
                .clone()
                .unwrap_or_else(|| "parser did not produce a terminal extraction".to_owned()),
        )),
    }
}

async fn persist_success(
    pool: &PgPool,
    store: &Store,
    event_id: Uuid,
    document: &SourceDocument,
    result: &ExtractionResult,
) -> Result<Value, Failure> {
    ensure_parser_active(pool, result).await?;
    let output = serde_json::to_vec(result)
        .map_err(|error| Failure::Terminal("EXTRACTION_SERIALIZATION_FAILED", error.to_string()))?;
    let output_digest = sha256_hex(&output);
    let output_key = format!("parsed/{}/{output_digest}.json", document.id);
    put(store, &output_key, output, &output_digest)
        .await
        .map_err(|error| match error {
            ObjectStoreError::DigestMismatch | ObjectStoreError::InvalidKey => {
                Failure::Terminal("PARSED_OBJECT_INTEGRITY_FAILURE", error.to_string())
            }
            ObjectStoreError::Backend(_) => {
                Failure::Retryable("OBJECT_STORE_UNAVAILABLE", error.to_string())
            }
        })?;
    let count = result
        .pages
        .iter()
        .map(|page| page.blocks.len() + page.tables.len())
        .sum::<usize>();
    let flags = prompt_injection_flags(result);
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query(
        "INSERT INTO core.parser_runs(source_document_id,parser_name,parser_version,status, \
         output_record_count,output_digest,started_at,completed_at) \
         VALUES($1,$2,$3,'SUCCEEDED',$4,$5,clock_timestamp(),clock_timestamp())",
    )
    .bind(document.id)
    .bind(&result.parser_id)
    .bind(&result.parser_version)
    .bind(i32::try_from(count).map_err(|_| {
        Failure::Terminal(
            "OUTPUT_LIMIT_EXCEEDED",
            "record count exceeds i32".to_owned(),
        )
    })?)
    .bind(&output_digest)
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    let changed = sqlx::query(
        "UPDATE raw.source_documents SET status='PARSED',parser_name=$2,parser_version=$3, \
         schema_version='extraction-result-v1',prompt_injection_flags=$4,quarantine_reason=NULL \
         WHERE id=$1 AND status='FETCHED'",
    )
    .bind(document.id)
    .bind(&result.parser_id)
    .bind(&result.parser_version)
    .bind(&flags)
    .execute(&mut *tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal(
            "STALE_SOURCE_DOCUMENT",
            document.id.to_string(),
        ));
    }
    sqlx::query(
        "SELECT ops.enqueue_outbox('source_document',$1,1,'source.document_parsed.v1',$2,clock_timestamp())",
    )
    .bind(document.id.to_string())
    .bind(json!({
        "output_digest":output_digest,
        "parser_version":result.parser_version,
        "source_document_id":document.id,
    }))
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?;
    update_inbox(&mut tx, event_id, "SUCCEEDED").await?;
    tx.commit().await.map_err(database)?;
    tracing::info!(source_document_id=%document.id,output_digest,"document extracted");
    Ok(json!({"outputDigest":output_digest,"outputKey":output_key,"recordCount":count}))
}

async fn persist_terminal(
    pool: &PgPool,
    event_id: Uuid,
    document: &SourceDocument,
    result: &ExtractionResult,
    status: &str,
    code: &str,
) -> Result<Value, Failure> {
    ensure_parser_active(pool, result).await?;
    let parser_status = if status == "QUARANTINED" {
        "QUARANTINED"
    } else {
        "FAILED"
    };
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query(
        "INSERT INTO core.parser_runs(source_document_id,parser_name,parser_version,status, \
         output_record_count,error_code,started_at,completed_at) \
         VALUES($1,$2,$3,$4,0,$5,clock_timestamp(),clock_timestamp())",
    )
    .bind(document.id)
    .bind(&result.parser_id)
    .bind(&result.parser_version)
    .bind(parser_status)
    .bind(code)
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    let changed = sqlx::query(
        "UPDATE raw.source_documents SET status=$2::core.source_document_status,parser_name=$3, \
         parser_version=$4,quarantine_reason=$5 WHERE id=$1 AND status='FETCHED'",
    )
    .bind(document.id)
    .bind(status)
    .bind(&result.parser_id)
    .bind(&result.parser_version)
    .bind(code)
    .execute(&mut *tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal(
            "STALE_SOURCE_DOCUMENT",
            document.id.to_string(),
        ));
    }
    update_inbox(&mut tx, event_id, status).await?;
    tx.commit().await.map_err(database)?;
    Ok(json!({"sourceDocumentStatus":status,"rejectionCode":code}))
}

async fn ensure_parser_active(pool: &PgPool, result: &ExtractionResult) -> Result<(), Failure> {
    let active: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM core.parser_versions \
         WHERE parser_name=$1 AND version=$2 AND status='ACTIVE' \
           AND btrim(implementation_digest::text)=$3 \
           AND supported_media_types ? $4)",
    )
    .bind(&result.parser_id)
    .bind(&result.parser_version)
    .bind(PARSER_IMPLEMENTATION_DIGEST)
    .bind(&result.media_type)
    .fetch_one(pool)
    .await
    .map_err(database)?;
    if active {
        Ok(())
    } else {
        Err(Failure::Terminal(
            "PARSER_REGISTRY_MISMATCH",
            format!(
                "{}:{}:{}",
                result.parser_id, result.parser_version, result.media_type
            ),
        ))
    }
}

async fn terminal_document(
    pool: &PgPool,
    event_id: Uuid,
    document: &SourceDocument,
    status: &str,
    code: &str,
    detail: &str,
) -> Result<Value, Failure> {
    let result = ExtractionResult {
        document_sha256: document.content_sha256.clone(),
        media_type: document.content_type.clone(),
        parser_id: "document-extractor".to_owned(),
        parser_version: "integrity-v1".to_owned(),
        status: ExtractionStatus::Rejected,
        pages: Vec::new(),
        warnings: Vec::new(),
        rejection_code: Some(code.to_owned()),
    };
    let value = persist_terminal(pool, event_id, document, &result, status, code).await?;
    tracing::warn!(source_document_id=%document.id,error_code=code,error_detail=detail,"document rejected");
    Ok(value)
}

async fn inbox_processed(pool: &PgPool, event_id: Uuid) -> Result<bool, Failure> {
    sqlx::query_scalar(
        "SELECT processed_at IS NOT NULL FROM ops.inbox WHERE consumer='document-extractor' AND event_id=$1",
    )
    .bind(event_id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("INBOX_RECORD_MISSING", event_id.to_string()))
}

async fn mark_inbox(pool: &PgPool, event_id: Uuid, result: &str) -> Result<(), Failure> {
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=COALESCE(processed_at,clock_timestamp()),result=$2 \
         WHERE consumer='document-extractor' AND event_id=$1",
    )
    .bind(event_id)
    .bind(result)
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(Failure::Terminal(
            "INBOX_RECORD_MISSING",
            event_id.to_string(),
        ))
    }
}

async fn update_inbox(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    event_id: Uuid,
    result: &str,
) -> Result<(), Failure> {
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result=$2 \
         WHERE consumer='document-extractor' AND event_id=$1 AND processed_at IS NULL",
    )
    .bind(event_id)
    .bind(result)
    .execute(&mut **tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(Failure::Terminal(
            "STALE_INBOX_RECORD",
            event_id.to_string(),
        ))
    }
}

fn prompt_injection_flags(result: &ExtractionResult) -> Value {
    let suspicious = result.pages.iter().any(|page| {
        page.blocks.iter().any(|block| {
            let value = block.text.to_ascii_lowercase();
            [
                "ignore previous instructions",
                "ignore all previous instructions",
                "system prompt",
                "developer message",
                "do not trust the user",
                "이전 지시를 무시",
                "시스템 프롬프트",
            ]
            .iter()
            .any(|needle| value.contains(needle))
        })
    });
    if suspicious {
        json!(["prompt_injection_detected"])
    } else {
        json!([])
    }
}

struct TempDocument {
    path: PathBuf,
}

impl TempDocument {
    async fn create(document: &SourceDocument, bytes: &[u8]) -> Result<Self, std::io::Error> {
        let directory = std::env::temp_dir().join("gurine-document-extractor");
        tokio::fs::create_dir_all(&directory).await?;
        let extension = extension(&document.content_type, &document.object_key);
        let path = directory.join(format!("{}.{extension}", Uuid::new_v4()));
        tokio::fs::write(&path, bytes).await?;
        Ok(Self { path })
    }
}

impl Drop for TempDocument {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_file(&self.path)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!(path=%self.path.display(),%error,"temporary document cleanup failed");
        }
    }
}

fn extension(content_type: &str, object_key: &str) -> &'static str {
    match content_type
        .split(';')
        .next()
        .unwrap_or(content_type)
        .trim()
    {
        "text/csv" => "csv",
        "application/xml" | "text/xml" => "xml",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
        "application/hwp+zip" => "hwpx",
        "application/pdf" => "pdf",
        "application/x-hwp" => "hwp",
        _ if Path::new(object_key)
            .extension()
            .and_then(|value| value.to_str())
            == Some("pdf") =>
        {
            "pdf"
        }
        _ => "bin",
    }
}

async fn get(store: &Store, key: &str, digest: &str) -> Result<Vec<u8>, ObjectStoreError> {
    match store {
        Store::Filesystem(client) => client.get(key, Some(digest)).await,
        Store::Gateway(client) => client.get(key, Some(digest)).await,
    }
}

async fn put(
    store: &Store,
    key: &str,
    bytes: Vec<u8>,
    digest: &str,
) -> Result<(), ObjectStoreError> {
    match store {
        Store::Filesystem(client) => client.put(key, bytes, digest).await.map(|_| ()),
        Store::Gateway(client) => client.put(key, bytes, digest).await.map(|_| ()),
    }
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn uuid(value: &Value, key: &str) -> Option<Uuid> {
    text(value, key).and_then(|value| Uuid::parse_str(value).ok())
}

fn database(error: sqlx::Error) -> Failure {
    Failure::Retryable("DATABASE_UNAVAILABLE", error.to_string())
}

fn map_job_error(error: JobError) -> WorkerError {
    match error {
        error @ (JobError::Database(_) | JobError::StaleFence) => WorkerError::Database(error),
        JobError::InvalidConfiguration => WorkerError::Initialization,
    }
}
