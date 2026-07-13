use std::{collections::BTreeMap, path::Path};

use gurine_jobs::postgres::{ClaimedJob, JobError, Worker};
use gurine_object_store::{
    filesystem,
    gateway::GatewayObjectStore,
    port::{ObjectStoreClient, ObjectStoreError},
};
use gurine_persistence_postgres::pool::{PoolConfig, connect};
use gurine_source_connectors::{ConnectorOperation, operations};
use reqwest::{Client, StatusCode, Url};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Postgres, Row, Transaction};
use thiserror::Error;
use uuid::Uuid;

use crate::config::{Config, ObjectStoreConfig};

enum Store {
    Filesystem(ObjectStoreClient),
    Gateway(GatewayObjectStore),
}

#[derive(Debug, Error)]
pub enum WorkerError {
    #[error("ingest worker initialization failed")]
    Initialization,
    #[error("ingest worker job operation failed")]
    Job(#[source] JobError),
}

enum Failure {
    Terminal(&'static str, String),
    Retryable(&'static str, String),
}

pub async fn run(config: Config) -> Result<(), WorkerError> {
    let pool = connect(&PoolConfig {
        database_url: config.database_url.clone(),
        max_connections: 6,
        acquire_timeout: std::time::Duration::from_secs(10),
    })
    .await
    .map_err(|_| WorkerError::Initialization)?;
    let store = open_store(&config.object_store).await?;
    let worker = Worker::new(
        config.worker_id.clone(),
        "ingest-worker".to_owned(),
        config.lease,
    )
    .map_err(WorkerError::Job)?;
    let source_client = Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .timeout(std::time::Duration::from_secs(120))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| WorkerError::Initialization)?;
    tracing::info!(worker_id=%config.worker_id,"ingest worker ready");
    loop {
        let processed = process_one(
            &pool,
            &store,
            &source_client,
            config.source_egress_url.as_ref(),
            &worker,
        )
        .await?;
        if config.once {
            if !processed {
                return Ok(());
            }
        } else if !processed {
            tokio::select! {
                () = tokio::time::sleep(config.poll_interval) => {},
                signal = tokio::signal::ctrl_c() => {
                    signal.map_err(|_| WorkerError::Initialization)?;
                    tracing::info!("ingest worker shutdown requested");
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
            filesystem::open(Path::new(root))
                .map(Store::Filesystem)
                .map_err(|_| WorkerError::Initialization)
        }
        ObjectStoreConfig::Gateway(url) => GatewayObjectStore::new(url.clone(), "ingest-worker")
            .map(Store::Gateway)
            .map_err(|_| WorkerError::Initialization),
    }
}

async fn process_one(
    pool: &PgPool,
    store: &Store,
    source_client: &Client,
    source_egress_url: Option<&Url>,
    worker: &Worker,
) -> Result<bool, WorkerError> {
    let Some(job) = worker.claim(pool).await.map_err(WorkerError::Job)? else {
        return Ok(false);
    };
    match process_claimed(pool, store, source_client, source_egress_url, &job).await {
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

async fn process_claimed(
    pool: &PgPool,
    store: &Store,
    source_client: &Client,
    source_egress_url: Option<&Url>,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    match job.job_type.as_str() {
        "SOURCE_RUN" => {
            return process_source_run(pool, store, source_client, source_egress_url, job).await;
        }
        "EVENT_DELIVERY"
            if job.payload.get("eventType").and_then(Value::as_str)
                == Some("source.document_parsed.v1") => {}
        _ => {
            return Err(Failure::Terminal(
                "UNSUPPORTED_JOB_TYPE",
                job.job_type.clone(),
            ));
        }
    }
    let event_id = uuid(&job.payload, "eventId")
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "eventId is invalid".to_owned()))?;
    if inbox_processed(pool, event_id).await? {
        return Ok(json!({"deduplicated":true}));
    }
    let payload = job
        .payload
        .get("payload")
        .and_then(Value::as_object)
        .ok_or_else(|| Failure::Terminal("INVALID_EVENT", "payload is invalid".to_owned()))?;
    let document_id = uuid_object(payload, "source_document_id").ok_or_else(|| {
        Failure::Terminal(
            "INVALID_EVENT_PAYLOAD",
            "source_document_id is invalid".to_owned(),
        )
    })?;
    let output_digest = text_object(payload, "output_digest")
        .filter(|value| is_sha256(value))
        .ok_or_else(|| {
            Failure::Terminal(
                "INVALID_EVENT_PAYLOAD",
                "output_digest is invalid".to_owned(),
            )
        })?;
    let parser_version = text_object(payload, "parser_version")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            Failure::Terminal(
                "INVALID_EVENT_PAYLOAD",
                "parser_version is invalid".to_owned(),
            )
        })?;
    let row = sqlx::query(
        "SELECT source_id,status::text status,content_sha256,parser_version,metadata \
         FROM raw.source_documents WHERE id=$1",
    )
    .bind(document_id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("SOURCE_DOCUMENT_NOT_FOUND", document_id.to_string()))?;
    let source_id: String = row.try_get("source_id").map_err(database)?;
    let status: String = row.try_get("status").map_err(database)?;
    let source_digest = row
        .try_get::<String, _>("content_sha256")
        .map_err(database)?
        .trim()
        .to_owned();
    let persisted_parser: Option<String> = row.try_get("parser_version").map_err(database)?;
    if status != "PARSED" || persisted_parser.as_deref() != Some(parser_version) {
        return Err(Failure::Terminal(
            "SOURCE_DOCUMENT_CONTRACT_MISMATCH",
            format!("status={status} parserVersion={persisted_parser:?}"),
        ));
    }
    let key = format!("parsed/{document_id}/{output_digest}.json");
    let bytes = get(store, &key, output_digest)
        .await
        .map_err(object_store)?;
    let extraction: Value = serde_json::from_slice(&bytes)
        .map_err(|error| Failure::Terminal("PARSED_OBJECT_INVALID", error.to_string()))?;
    validate_extraction(&extraction, &source_digest, parser_version)?;
    let records = flatten_records(&extraction)?;
    let schema_fingerprint = schema_fingerprint(&records)?;
    let mut tx = pool.begin().await.map_err(database)?;
    for (index, record) in records.iter().enumerate() {
        let bytes = serde_json::to_vec(record)
            .map_err(|error| Failure::Terminal("PARSED_RECORD_INVALID", error.to_string()))?;
        sqlx::query(
            "INSERT INTO raw.parsed_records(source_document_id,record_type,record_index, \
             parser_version,payload,payload_sha256) VALUES($1,$2,$3,$4,$5,$6) \
             ON CONFLICT(source_document_id,record_type,record_index,parser_version) DO NOTHING",
        )
        .bind(document_id)
        .bind(
            record
                .get("recordType")
                .and_then(Value::as_str)
                .unwrap_or("DOCUMENT"),
        )
        .bind(
            i32::try_from(index).map_err(|_| {
                Failure::Terminal("PARSED_RECORD_LIMIT", "too many records".to_owned())
            })?,
        )
        .bind(parser_version)
        .bind(record)
        .bind(sha256(&bytes))
        .execute(&mut *tx)
        .await
        .map_err(database)?;
    }
    let previous = sqlx::query(
        "SELECT id,metadata->>'parsedSchemaFingerprint' fingerprint \
         FROM raw.source_documents WHERE source_id=$1 AND id<>$2 \
           AND metadata ? 'parsedSchemaFingerprint' ORDER BY retrieved_at DESC LIMIT 1",
    )
    .bind(&source_id)
    .bind(document_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(database)?;
    if let Some(previous) = previous {
        let before: String = previous.try_get("fingerprint").map_err(database)?;
        if before != schema_fingerprint {
            persist_schema_drift(
                &mut tx,
                &source_id,
                document_id,
                &before,
                &schema_fingerprint,
            )
            .await?;
        }
    }
    sqlx::query(
        "UPDATE raw.source_documents SET metadata=metadata || $2 \
         WHERE id=$1 AND status='PARSED'",
    )
    .bind(document_id)
    .bind(json!({
        "parsedSchemaFingerprint":schema_fingerprint,
        "parsedOutputDigest":output_digest,
        "parsedOutputObjectKey":key,
        "parsedRecordCount":records.len(),
    }))
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    update_inbox(&mut tx, event_id).await?;
    tx.commit().await.map_err(database)?;
    tracing::info!(source_document_id=%document_id,record_count=records.len(),"parsed document ingested");
    Ok(json!({"recordCount":records.len(),"schemaFingerprint":schema_fingerprint}))
}

#[derive(Clone)]
struct ManifestDocument {
    external_id: String,
    revision: String,
    target: String,
    content_type: String,
    published_at: Option<String>,
}

struct SourceResponse {
    bytes: Vec<u8>,
    content_type: String,
    http_status: u16,
}

async fn process_source_run(
    pool: &PgPool,
    store: &Store,
    source_client: &Client,
    source_egress_url: Option<&Url>,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    let run_id = uuid(&job.payload, "sourceRunId")
        .ok_or_else(|| Failure::Terminal("INVALID_SOURCE_RUN_JOB", "sourceRunId".into()))?;
    let gateway = source_egress_url
        .ok_or_else(|| Failure::Terminal("SOURCE_EGRESS_MISSING", run_id.to_string()))?;
    let row = sqlx::query(
        "UPDATE ops.source_runs r SET status='RUNNING',started_at=COALESCE(started_at,clock_timestamp()), \
           checkpoint_before=COALESCE(checkpoint_before,(SELECT COALESCE(jsonb_object_agg(c.partition_key,c.cursor_payload),'{}'::jsonb) \
             FROM ops.source_checkpoints c WHERE c.source_id=r.source_id)) \
         FROM ops.source_registry s WHERE r.id=$1 AND r.source_id=s.source_id \
           AND r.status IN ('QUEUED','RUNNING') AND s.enabled AND s.legal_status='APPROVED' \
         RETURNING r.source_id,r.mode,r.requested_from,r.requested_to,s.base_url,s.configuration",
    )
    .bind(run_id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("SOURCE_RUN_NOT_ALLOWED", run_id.to_string()))?;
    let source_id: String = row.try_get("source_id").map_err(database)?;
    let mode: String = row.try_get("mode").map_err(database)?;
    let requested_from: Option<time::Date> = row.try_get("requested_from").map_err(database)?;
    let requested_to: Option<time::Date> = row.try_get("requested_to").map_err(database)?;
    let base_url: Option<String> = row.try_get("base_url").map_err(database)?;
    let configuration: Value = row.try_get("configuration").map_err(database)?;
    let catalog = operations()
        .filter(|operation| operation.connector_id == source_id)
        .collect::<Vec<_>>();
    if catalog.is_empty() {
        mark_source_terminal(pool, run_id, &source_id, "CONNECTOR_NOT_CATALOGED").await?;
        return Err(Failure::Terminal("CONNECTOR_NOT_CATALOGED", source_id));
    }

    let mut seen = 0_i64;
    let mut changed = 0_i64;
    let mut fingerprints = Vec::new();
    let mut manifest_documents = Vec::<ManifestDocument>::new();
    for operation in catalog {
        let targets = if operation.kind == "document" && !manifest_documents.is_empty() {
            manifest_documents.clone()
        } else {
            vec![ManifestDocument {
                external_id: operation.id.to_owned(),
                revision: "runtime".to_owned(),
                target: operation_target(operation, base_url.as_deref(), &configuration)?,
                content_type: "application/json".to_owned(),
                published_at: None,
            }]
        };
        for target in targets {
            let target_url = with_operation_parameters(
                &target.target,
                operation,
                &configuration,
                requested_from,
                requested_to,
            )?;
            let response = match fetch_source(source_client, gateway, &source_id, &target_url).await
            {
                Ok(response) => response,
                Err(Failure::Terminal(code, detail)) => {
                    mark_source_terminal(pool, run_id, &source_id, code).await?;
                    return Err(Failure::Terminal(code, detail));
                }
                Err(error @ Failure::Retryable(_, _)) => return Err(error),
            };
            seen += 1;
            let digest = sha256(&response.bytes);
            if operation.kind == "manifest" {
                manifest_documents = validate_manifest(&response.bytes)?;
            } else if source_id.starts_with("koneps-") {
                let value: Value = serde_json::from_slice(&response.bytes).map_err(|error| {
                    Failure::Terminal("SOURCE_PAYLOAD_MALFORMED", error.to_string())
                })?;
                gurine_source_connectors::data_go_kr::decode(value).map_err(|error| {
                    Failure::Terminal("SOURCE_PAYLOAD_REJECTED", error.to_string())
                })?;
            } else if source_id == "open-dart" && operation.kind != "snapshot-zip-xml" {
                let value: Value = serde_json::from_slice(&response.bytes).map_err(|error| {
                    Failure::Terminal("SOURCE_PAYLOAD_MALFORMED", error.to_string())
                })?;
                if value.get("status").and_then(Value::as_str) != Some("000") {
                    return Err(Failure::Terminal(
                        "SOURCE_PAYLOAD_REJECTED",
                        operation.id.to_owned(),
                    ));
                }
            }
            let object_key = format!("raw/{source_id}/{run_id}/{}/{digest}", operation.id);
            put_object(store, &object_key, response.bytes.clone(), &digest).await?;
            let mut tx = pool.begin().await.map_err(database)?;
            let fetch_id = Uuid::new_v4();
            sqlx::query(
                "INSERT INTO raw.source_fetches(id,source_id,source_run_id,external_locator, \
                   requested_at,completed_at,http_status,content_type,payload_sha256,payload_size_bytes,object_key) \
                 VALUES($1,$2,$3,$4,clock_timestamp(),clock_timestamp(),$5,$6,$7,$8,$9) \
                 ON CONFLICT(source_id,external_locator,payload_sha256) DO NOTHING",
            )
            .bind(fetch_id)
            .bind(&source_id)
            .bind(run_id)
            .bind(&target_url)
            .bind(i32::from(response.http_status))
            .bind(&response.content_type)
            .bind(&digest)
            .bind(i64::try_from(response.bytes.len()).map_err(|_| {
                Failure::Terminal("SOURCE_PAYLOAD_TOO_LARGE", operation.id.to_owned())
            })?)
            .bind(&object_key)
            .execute(&mut *tx)
            .await
            .map_err(database)?;
            let document_id = Uuid::new_v4();
            let inserted = if mode == "DRY_RUN" {
                None
            } else {
                sqlx::query_scalar::<_, Uuid>(
                    "INSERT INTO raw.source_documents(id,source_id,source_fetch_id,external_id, \
                       external_version,canonical_url,retrieved_at,source_published_at,content_type, \
                       content_sha256,content_size_bytes,object_key,status,metadata) \
                     VALUES($1,$2,$3,$4,$5,$6,clock_timestamp(),$7::timestamptz,$8,$9,$10,$11,'FETCHED',$12) \
                     ON CONFLICT(source_id,external_id,content_sha256) DO NOTHING RETURNING id",
                )
                .bind(document_id)
                .bind(&source_id)
                .bind(fetch_id)
                .bind(format!("{}:{}", operation.id, target.external_id))
                .bind(&target.revision)
                .bind(&target_url)
                .bind(target.published_at.as_deref())
                .bind(if response.content_type.is_empty() {
                    target.content_type.as_str()
                } else {
                    response.content_type.as_str()
                })
                .bind(&digest)
                .bind(i64::try_from(response.bytes.len()).unwrap_or(i64::MAX))
                .bind(&object_key)
                .bind(json!({"connectorOperationId":operation.id,"sourceRunId":run_id}))
                .fetch_optional(&mut *tx)
                .await
                .map_err(database)?
            };
            if let Some(document_id) = inserted {
                changed += 1;
                if response.content_type == "application/json" {
                    persist_structured_json(
                        &mut tx,
                        &source_id,
                        operation,
                        document_id,
                        &response.bytes,
                    )
                    .await?;
                }
                sqlx::query(
                    "SELECT ops.enqueue_outbox('source_document',$1,1,'source.document_stored.v1',$2,clock_timestamp())",
                )
                .bind(document_id.to_string())
                .bind(json!({"content_sha256":digest,"source_document_id":document_id,"source_id":source_id}))
                .fetch_one(&mut *tx)
                .await
                .map_err(database)?;
            }
            sqlx::query(
                "INSERT INTO ops.source_checkpoints(source_id,partition_key,cursor_payload,remote_high_watermark,last_success_at) \
                 VALUES($1,$2,$3,$4,clock_timestamp()) \
                 ON CONFLICT(source_id,partition_key) DO UPDATE SET cursor_payload=EXCLUDED.cursor_payload, \
                   remote_high_watermark=EXCLUDED.remote_high_watermark,last_success_at=EXCLUDED.last_success_at, \
                   version=ops.source_checkpoints.version+1,updated_at=clock_timestamp()",
            )
            .bind(&source_id)
            .bind(operation.id)
            .bind(json!({"operationId":operation.id,"digest":digest,"sourceRunId":run_id}))
            .bind(&digest)
            .execute(&mut *tx)
            .await
            .map_err(database)?;
            tx.commit().await.map_err(database)?;
            fingerprints.push(json!({"operationId":operation.id,"sha256":digest}));
        }
    }
    let report = json!({
        "sourceRunId":run_id,"sourceId":source_id,"mode":mode,
        "recordsSeen":seen,"recordsChanged":changed,"responseFingerprints":fingerprints
    });
    let report_bytes = serde_json::to_vec(&report)
        .map_err(|error| Failure::Terminal("SOURCE_REPORT_INVALID", error.to_string()))?;
    let report_digest = sha256(&report_bytes);
    let report_key = format!("reports/source-runs/{run_id}/{report_digest}.json");
    put_object(store, &report_key, report_bytes, &report_digest).await?;
    let mut tx = pool.begin().await.map_err(database)?;
    let checkpoint_after: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_object_agg(partition_key,cursor_payload),'{}'::jsonb) \
         FROM ops.source_checkpoints WHERE source_id=$1",
    )
    .bind(&source_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?;
    sqlx::query(
        "UPDATE ops.source_runs SET status='SUCCEEDED',records_seen=$2,records_changed=$3, \
           checkpoint_after=$4,report_object_key=$5,completed_at=clock_timestamp(),error_detail=NULL \
         WHERE id=$1 AND status='RUNNING'",
    )
    .bind(run_id)
    .bind(seen)
    .bind(changed)
    .bind(checkpoint_after)
    .bind(&report_key)
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    sqlx::query(
        "UPDATE ops.source_registry SET configuration=configuration || jsonb_build_object( \
           'activationReceipt',jsonb_build_object('passedAt',clock_timestamp(), \
             'sourceRunId',$2,'responseFingerprints',$3::jsonb)),updated_at=clock_timestamp() \
         WHERE source_id=$1",
    )
    .bind(&source_id)
    .bind(run_id)
    .bind(json!(fingerprints))
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)?;
    Ok(
        json!({"sourceRunId":run_id,"recordsSeen":seen,"recordsChanged":changed,"reportObjectKey":report_key}),
    )
}

fn operation_target(
    operation: &ConnectorOperation,
    base_url: Option<&str>,
    configuration: &Value,
) -> Result<String, Failure> {
    if let Some(value) = configuration
        .pointer(&format!("/operationUrls/{}", operation.id))
        .and_then(Value::as_str)
    {
        return validate_target(value);
    }
    if operation.kind == "manifest" {
        return configuration
            .get("manifestUrl")
            .and_then(Value::as_str)
            .ok_or_else(|| Failure::Terminal("SOURCE_MANIFEST_URL_MISSING", operation.id.into()))
            .and_then(validate_target);
    }
    let base = base_url
        .ok_or_else(|| Failure::Terminal("SOURCE_BASE_URL_MISSING", operation.id.into()))?;
    let base = Url::parse(base)
        .map_err(|_| Failure::Terminal("SOURCE_BASE_URL_INVALID", operation.id.into()))?;
    base.join(operation.remote_path.trim_start_matches('/'))
        .map_err(|_| Failure::Terminal("SOURCE_TARGET_INVALID", operation.id.into()))
        .and_then(|value| validate_target(value.as_str()))
}

fn validate_target(value: &str) -> Result<String, Failure> {
    let url =
        Url::parse(value).map_err(|_| Failure::Terminal("SOURCE_TARGET_INVALID", "URL".into()))?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || url.username() != ""
        || url.password().is_some()
    {
        return Err(Failure::Terminal("SOURCE_TARGET_INVALID", "HTTPS".into()));
    }
    Ok(url.to_string())
}

fn with_operation_parameters(
    target: &str,
    operation: &ConnectorOperation,
    configuration: &Value,
    requested_from: Option<time::Date>,
    requested_to: Option<time::Date>,
) -> Result<String, Failure> {
    let mut url = Url::parse(target)
        .map_err(|_| Failure::Terminal("SOURCE_TARGET_INVALID", operation.id.into()))?;
    {
        let mut pairs = url.query_pairs_mut();
        pairs.append_pair("operationId", operation.id);
        if operation.pagination == "page-number" {
            pairs.append_pair("pageNo", "1");
            pairs.append_pair("numOfRows", "1000");
            pairs.append_pair("type", "json");
        }
        if let Some(value) = requested_from {
            pairs.append_pair("from", &value.to_string());
        }
        if let Some(value) = requested_to {
            pairs.append_pair("to", &value.to_string());
        }
        if let Some(values) = configuration
            .pointer(&format!("/parameters/{}", operation.id))
            .and_then(Value::as_object)
        {
            for (key, value) in values {
                if let Some(value) = value.as_str() {
                    pairs.append_pair(key, value);
                }
            }
        }
    }
    Ok(url.to_string())
}

async fn fetch_source(
    client: &Client,
    gateway: &Url,
    source_id: &str,
    target: &str,
) -> Result<SourceResponse, Failure> {
    let response = client
        .get(gateway.clone())
        .header("x-gurine-egress-caller", "ingest-worker")
        .header("x-gurine-source-id", source_id)
        .header("x-gurine-egress-target", target)
        .send()
        .await
        .map_err(|error| Failure::Retryable("SOURCE_UNAVAILABLE", error.to_string()))?;
    let status = response.status();
    if status == StatusCode::TOO_MANY_REQUESTS || status.is_server_error() {
        return Err(Failure::Retryable("SOURCE_UNAVAILABLE", status.to_string()));
    }
    if status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN {
        return Err(Failure::Terminal(
            "SOURCE_AUTHORIZATION_FAILED",
            status.to_string(),
        ));
    }
    if !status.is_success() {
        return Err(Failure::Terminal(
            "SOURCE_REQUEST_REJECTED",
            status.to_string(),
        ));
    }
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("application/octet-stream")
        .split(';')
        .next()
        .unwrap_or("application/octet-stream")
        .to_owned();
    let bytes = response
        .bytes()
        .await
        .map_err(|error| Failure::Retryable("SOURCE_UNAVAILABLE", error.to_string()))?;
    if bytes.len() > 67_108_864 {
        return Err(Failure::Terminal(
            "SOURCE_PAYLOAD_TOO_LARGE",
            bytes.len().to_string(),
        ));
    }
    Ok(SourceResponse {
        bytes: bytes.to_vec(),
        content_type,
        http_status: status.as_u16(),
    })
}

fn validate_manifest(bytes: &[u8]) -> Result<Vec<ManifestDocument>, Failure> {
    let value: Value = serde_json::from_slice(bytes)
        .map_err(|error| Failure::Terminal("SOURCE_MANIFEST_INVALID", error.to_string()))?;
    if value.get("manifest_version").and_then(Value::as_str) != Some("1")
        || value.get("publisher").and_then(Value::as_str).is_none()
        || value.get("generated_at").and_then(Value::as_str).is_none()
    {
        return Err(Failure::Terminal(
            "SOURCE_MANIFEST_INVALID",
            "header".into(),
        ));
    }
    let documents = value
        .get("documents")
        .and_then(Value::as_array)
        .ok_or_else(|| Failure::Terminal("SOURCE_MANIFEST_INVALID", "documents".into()))?;
    documents
        .iter()
        .filter(|document| document.get("deleted").and_then(Value::as_bool) != Some(true))
        .map(|document| {
            Ok(ManifestDocument {
                external_id: required_text(document, "external_id")?.to_owned(),
                revision: required_text(document, "revision")?.to_owned(),
                target: validate_target(required_text(document, "url")?)?,
                content_type: required_text(document, "content_type")?.to_owned(),
                published_at: Some(required_text(document, "published_at")?.to_owned()),
            })
        })
        .collect()
}

fn required_text<'a>(value: &'a Value, key: &str) -> Result<&'a str, Failure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| Failure::Terminal("SOURCE_MANIFEST_INVALID", key.into()))
}

async fn mark_source_terminal(
    pool: &PgPool,
    run_id: Uuid,
    source_id: &str,
    code: &str,
) -> Result<(), Failure> {
    let mut tx = pool.begin().await.map_err(database)?;
    sqlx::query(
        "UPDATE ops.source_runs SET status='FAILED',error_detail=$2,completed_at=clock_timestamp() \
         WHERE id=$1 AND status='RUNNING'",
    )
    .bind(run_id)
    .bind(code)
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    sqlx::query(
        "INSERT INTO ops.source_incidents(source_id,source_run_id,severity,incident_type,summary,impact,status) \
         VALUES($1,$2,'MAJOR',$3,'Source run terminal failure',$4,'OPEN')",
    )
    .bind(source_id)
    .bind(run_id)
    .bind(code)
    .bind(json!({"sourceRunId":run_id,"errorCode":code}))
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    if code == "SOURCE_AUTHORIZATION_FAILED" {
        sqlx::query("UPDATE ops.source_registry SET enabled=false WHERE source_id=$1")
            .bind(source_id)
            .execute(&mut *tx)
            .await
            .map_err(database)?;
    }
    tx.commit().await.map_err(database)?;
    Ok(())
}

async fn put_object(store: &Store, key: &str, bytes: Vec<u8>, digest: &str) -> Result<(), Failure> {
    let result = match store {
        Store::Filesystem(client) => client.put(key, bytes, digest).await,
        Store::Gateway(client) => client.put(key, bytes, digest).await,
    };
    result.map(|_| ()).map_err(object_store)
}

async fn persist_structured_json(
    tx: &mut Transaction<'_, Postgres>,
    source_id: &str,
    operation: &ConnectorOperation,
    document_id: Uuid,
    bytes: &[u8],
) -> Result<(), Failure> {
    let value: Value = serde_json::from_slice(bytes)
        .map_err(|error| Failure::Terminal("SOURCE_PAYLOAD_MALFORMED", error.to_string()))?;
    let records = structured_records(source_id, operation, &value);
    for (index, record) in records.iter().enumerate() {
        let record_bytes = serde_json::to_vec(record)
            .map_err(|error| Failure::Terminal("SOURCE_PAYLOAD_MALFORMED", error.to_string()))?;
        sqlx::query(
            "INSERT INTO raw.parsed_records(source_document_id,record_type,record_index,parser_version,payload,payload_sha256) \
             VALUES($1,$2,$3,'connector-structured-json-v1',$4,$5) \
             ON CONFLICT(source_document_id,record_type,record_index,parser_version) DO NOTHING",
        )
        .bind(document_id)
        .bind(operation.kind.to_ascii_uppercase())
        .bind(i32::try_from(index).map_err(|_| {
            Failure::Terminal("SOURCE_RECORD_LIMIT", operation.id.to_owned())
        })?)
        .bind(record)
        .bind(sha256(&record_bytes))
        .execute(&mut **tx)
        .await
        .map_err(database)?;
        if source_id == "koneps-contracts" {
            normalize_koneps_contract(tx, source_id, operation, document_id, index, record).await?;
        } else if source_id == "open-dart" {
            normalize_dart_supplier(tx, document_id, record).await?;
        }
    }
    sqlx::query(
        "UPDATE raw.source_documents SET status='PARSED',parser_name='connector-structured-json', \
           parser_version='connector-structured-json-v1',schema_version='v1', \
           metadata=metadata || $2 WHERE id=$1 AND status='FETCHED'",
    )
    .bind(document_id)
    .bind(json!({"structuredRecordCount":records.len(),"connectorOperationId":operation.id}))
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

fn structured_records(
    source_id: &str,
    operation: &ConnectorOperation,
    value: &Value,
) -> Vec<Value> {
    let candidate = if source_id.starts_with("koneps-") {
        value
            .pointer("/response/body/items/item")
            .or_else(|| value.pointer("/response/body/items"))
    } else if source_id == "open-dart" {
        value.get("list").or(Some(value))
    } else if operation.kind == "manifest" {
        value.get("documents")
    } else {
        value.get("records").or(Some(value))
    };
    match candidate {
        Some(Value::Array(values)) => values.clone(),
        Some(Value::Object(values)) if !values.is_empty() => vec![Value::Object(values.clone())],
        _ => Vec::new(),
    }
}

async fn normalize_koneps_contract(
    tx: &mut Transaction<'_, Postgres>,
    source_id: &str,
    operation: &ConnectorOperation,
    document_id: Uuid,
    index: usize,
    record: &Value,
) -> Result<(), Failure> {
    let Some(external_id) = first_text(record, &["untyCntrctNo", "cntrctNo"]) else {
        return data_quality_incident(
            tx,
            source_id,
            document_id,
            operation.id,
            "CONTRACT_ID_MISSING",
        )
        .await;
    };
    let Some(title) = first_text(record, &["cntrctNm"]) else {
        return data_quality_incident(
            tx,
            source_id,
            document_id,
            operation.id,
            "CONTRACT_TITLE_MISSING",
        )
        .await;
    };
    let Some(agency_name) = first_text(record, &["cntrctInsttNm", "dminsttNm"]) else {
        return data_quality_incident(
            tx,
            source_id,
            document_id,
            operation.id,
            "AGENCY_NAME_MISSING",
        )
        .await;
    };
    let agency_identifier = first_text(record, &["cntrctInsttCd", "dminsttCd"]);
    let agency_id = resolve_agency(tx, agency_name, agency_identifier, document_id).await?;
    let supplier_name = first_text(record, &["corpNm", "cntrctCorpNm"]);
    let supplier_identifier = first_text(record, &["bizno", "corpBizno"]);
    let supplier_id = match supplier_name {
        Some(name) => Some(resolve_supplier(tx, name, supplier_identifier, document_id).await?),
        None => None,
    };
    let amount = first_text_or_number(record, &["thtmCntrctAmt", "totCntrctAmt", "cntrctAmt"]);
    let signed_at = first_text(record, &["cntrctCnclsDate", "cntrctDt"]).and_then(normalize_date);
    let contract_id: Uuid = sqlx::query_scalar(
        "INSERT INTO core.contracts(source_id,external_contract_id,contract_number,title,agency_id, \
           supplier_id,status,signed_at,original_amount,current_amount,normalization_version, \
           source_document_id,source_record_locator) \
         VALUES($1,$2,$2,$3,$4,$5,'ACTIVE',$6::date,NULLIF($7,'')::numeric,NULLIF($7,'')::numeric, \
           'connector-v1',$8,$9) \
         ON CONFLICT(source_id,external_contract_id) DO UPDATE SET title=EXCLUDED.title, \
           agency_id=EXCLUDED.agency_id,supplier_id=EXCLUDED.supplier_id,signed_at=EXCLUDED.signed_at, \
           current_amount=EXCLUDED.current_amount,source_document_id=EXCLUDED.source_document_id, \
           source_record_locator=EXCLUDED.source_record_locator,version=core.contracts.version+1 \
         RETURNING id",
    )
    .bind(source_id)
    .bind(external_id)
    .bind(title)
    .bind(agency_id)
    .bind(supplier_id)
    .bind(signed_at.as_deref())
    .bind(amount.as_deref().unwrap_or(""))
    .bind(document_id)
    .bind(format!("json-pointer:/response/body/items/item/{index}"))
    .fetch_one(&mut **tx)
    .await
    .map_err(database)?;
    sqlx::query(
        "INSERT INTO core.field_provenance(entity_type,entity_id,field_path,source_document_id, \
           source_locator,raw_value,normalized_value,transformation,parser_version,normalization_version) \
         VALUES('CONTRACT',$1,'title',$2,$3,$4,$5,'alias-list:first-non-empty', \
           'connector-structured-json-v1','connector-v1') ON CONFLICT DO NOTHING",
    )
    .bind(contract_id)
    .bind(document_id)
    .bind(format!("json-pointer:/response/body/items/item/{index}/cntrctNm"))
    .bind(json!(title))
    .bind(json!(title))
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

async fn normalize_dart_supplier(
    tx: &mut Transaction<'_, Postgres>,
    document_id: Uuid,
    record: &Value,
) -> Result<(), Failure> {
    let Some(corp_code) = first_text(record, &["corp_code"]) else {
        return Ok(());
    };
    let Some(name) = first_text(record, &["corp_name"]) else {
        return Ok(());
    };
    let _ = resolve_supplier(tx, name, Some(corp_code), document_id).await?;
    Ok(())
}

async fn resolve_agency(
    tx: &mut Transaction<'_, Postgres>,
    name: &str,
    identifier: Option<&str>,
    document_id: Uuid,
) -> Result<Uuid, Failure> {
    if let Some(identifier) = identifier
        && let Some(id) = sqlx::query_scalar::<_, Uuid>(
            "SELECT agency_id FROM core.agency_identifiers WHERE scheme='KONEPS' AND value=$1",
        )
        .bind(identifier)
        .fetch_optional(&mut **tx)
        .await
        .map_err(database)?
    {
        return Ok(id);
    }
    if let Some(id) = sqlx::query_scalar::<_, Uuid>(
        "SELECT id FROM core.agencies WHERE canonical_name=$1 ORDER BY created_at LIMIT 1",
    )
    .bind(name)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?
    {
        return Ok(id);
    }
    let id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO core.agencies(id,canonical_name,agency_type,jurisdiction,identity_confidence,identity_status) \
         VALUES($1,$2,'PUBLIC_AGENCY','KR',1,'VERIFIED')",
    )
    .bind(id)
    .bind(name)
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    if let Some(identifier) = identifier {
        sqlx::query(
            "INSERT INTO core.agency_identifiers(agency_id,scheme,value,source_document_id) \
             VALUES($1,'KONEPS',$2,$3) ON CONFLICT DO NOTHING",
        )
        .bind(id)
        .bind(identifier)
        .bind(document_id)
        .execute(&mut **tx)
        .await
        .map_err(database)?;
    }
    Ok(id)
}

async fn resolve_supplier(
    tx: &mut Transaction<'_, Postgres>,
    name: &str,
    identifier: Option<&str>,
    document_id: Uuid,
) -> Result<Uuid, Failure> {
    let identifier_hash = identifier.map(|value| sha256(value.as_bytes()));
    if let Some(hash) = &identifier_hash
        && let Some(id) = sqlx::query_scalar::<_, Uuid>(
            "SELECT supplier_id FROM core.supplier_identifiers WHERE scheme IN ('BUSINESS_NUMBER','DART_CORP_CODE') AND value_hash=$1",
        )
        .bind(hash)
        .fetch_optional(&mut **tx)
        .await
        .map_err(database)?
    {
        return Ok(id);
    }
    if let Some(id) = sqlx::query_scalar::<_, Uuid>(
        "SELECT id FROM core.suppliers WHERE canonical_name=$1 ORDER BY created_at LIMIT 1",
    )
    .bind(name)
    .fetch_optional(&mut **tx)
    .await
    .map_err(database)?
    {
        return Ok(id);
    }
    let id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO core.suppliers(id,canonical_name,identity_confidence,identity_status) \
         VALUES($1,$2,0.9,'VERIFIED')",
    )
    .bind(id)
    .bind(name)
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    if let (Some(identifier), Some(hash)) = (identifier, identifier_hash) {
        let scheme = if identifier.len() == 8 {
            "DART_CORP_CODE"
        } else {
            "BUSINESS_NUMBER"
        };
        let display = if identifier.len() > 4 {
            format!("***{}", &identifier[identifier.len() - 4..])
        } else {
            "***".to_owned()
        };
        sqlx::query(
            "INSERT INTO core.supplier_identifiers(supplier_id,scheme,value_hash,display_value, \
               source_document_id,verification_status) VALUES($1,$2,$3,$4,$5,'VERIFIED') \
             ON CONFLICT DO NOTHING",
        )
        .bind(id)
        .bind(scheme)
        .bind(hash)
        .bind(display)
        .bind(document_id)
        .execute(&mut **tx)
        .await
        .map_err(database)?;
    }
    Ok(id)
}

async fn data_quality_incident(
    tx: &mut Transaction<'_, Postgres>,
    source_id: &str,
    document_id: Uuid,
    operation_id: &str,
    code: &str,
) -> Result<(), Failure> {
    sqlx::query(
        "INSERT INTO ops.source_incidents(source_id,severity,incident_type,summary,impact,status) \
         VALUES($1,'MINOR',$2,'Structured record missing required canonical field',$3,'OPEN')",
    )
    .bind(source_id)
    .bind(code)
    .bind(json!({"sourceDocumentId":document_id,"operationId":operation_id}))
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

fn first_text<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| {
        value
            .get(*key)
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
    })
}

fn first_text_or_number(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| match value.get(*key) {
        Some(Value::String(value)) if !value.trim().is_empty() => Some(value.clone()),
        Some(Value::Number(value)) => Some(value.to_string()),
        _ => None,
    })
}

fn normalize_date(value: &str) -> Option<String> {
    let digits = value
        .chars()
        .filter(char::is_ascii_digit)
        .collect::<String>();
    if digits.len() < 8 {
        return None;
    }
    Some(format!(
        "{}-{}-{}",
        &digits[0..4],
        &digits[4..6],
        &digits[6..8]
    ))
}

async fn persist_schema_drift(
    tx: &mut Transaction<'_, Postgres>,
    source_id: &str,
    document_id: Uuid,
    before: &str,
    after: &str,
) -> Result<(), Failure> {
    let drift_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO ops.schema_drifts(id,source_id,detected_at,fingerprint_before, \
         fingerprint_after,sample_document_ids,status,impact) \
         VALUES($1,$2,clock_timestamp(),$3,$4,$5,'OPEN','UNKNOWN')",
    )
    .bind(drift_id)
    .bind(source_id)
    .bind(before)
    .bind(after)
    .bind(json!([document_id]))
    .execute(&mut **tx)
    .await
    .map_err(database)?;
    sqlx::query(
        "SELECT ops.enqueue_outbox('schema_drift',$1,1,'source.schema_drift_detected.v1',$2,clock_timestamp())",
    )
    .bind(drift_id.to_string())
    .bind(json!({"schema_drift_id":drift_id,"source_id":source_id,"fingerprint_before":before,"fingerprint_after":after}))
    .fetch_one(&mut **tx)
    .await
    .map_err(database)?;
    Ok(())
}

fn validate_extraction(
    extraction: &Value,
    source_digest: &str,
    parser_version: &str,
) -> Result<(), Failure> {
    let object = extraction.as_object().ok_or_else(|| {
        Failure::Terminal("PARSED_OBJECT_INVALID", "root must be an object".to_owned())
    })?;
    if text_object(object, "documentSha256") != Some(source_digest)
        || text_object(object, "parserVersion") != Some(parser_version)
        || text_object(object, "status") != Some("EXTRACTED")
        || object.get("pages").and_then(Value::as_array).is_none()
    {
        return Err(Failure::Terminal(
            "PARSED_OBJECT_CONTRACT_MISMATCH",
            "digest, parser version, status, or pages mismatch".to_owned(),
        ));
    }
    Ok(())
}

fn flatten_records(extraction: &Value) -> Result<Vec<Value>, Failure> {
    let pages = extraction
        .get("pages")
        .and_then(Value::as_array)
        .ok_or_else(|| Failure::Terminal("PARSED_OBJECT_INVALID", "pages missing".to_owned()))?;
    let mut records = Vec::new();
    for page in pages {
        let page_index = page.get("index").cloned().unwrap_or_else(|| json!(0));
        for block in page
            .get("blocks")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            records.push(json!({"recordType":"BLOCK","pageIndex":page_index,"block":block}));
        }
        for table in page
            .get("tables")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let table_id = table.get("id").cloned().unwrap_or(Value::Null);
            for (row_index, row) in table
                .get("rows")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .enumerate()
            {
                records.push(json!({
                    "recordType":"TABLE_ROW","pageIndex":page_index,"tableId":table_id,
                    "rowIndex":row_index,"cells":row,
                }));
            }
        }
    }
    if records.len() > 1_000_000 {
        return Err(Failure::Terminal(
            "PARSED_RECORD_LIMIT",
            format!("{} records exceed limit", records.len()),
        ));
    }
    if records.is_empty() {
        records.push(json!({"recordType":"DOCUMENT","pages":pages.len()}));
    }
    Ok(records)
}

fn schema_fingerprint(records: &[Value]) -> Result<String, Failure> {
    let mut shapes = BTreeMap::<String, Value>::new();
    for record in records {
        let record_type = record
            .get("recordType")
            .and_then(Value::as_str)
            .unwrap_or("UNKNOWN")
            .to_owned();
        shapes.insert(record_type, shape(record));
    }
    serde_json::to_vec(&shapes)
        .map(|bytes| sha256(&bytes))
        .map_err(|error| Failure::Terminal("SCHEMA_FINGERPRINT_FAILED", error.to_string()))
}

fn shape(value: &Value) -> Value {
    match value {
        Value::Null => json!("null"),
        Value::Bool(_) => json!("boolean"),
        Value::Number(_) => json!("number"),
        Value::String(_) => json!("string"),
        Value::Array(values) => {
            let mut variants = values
                .iter()
                .map(shape)
                .map(|value| serde_json::to_string(&value).unwrap_or_default())
                .collect::<Vec<_>>();
            variants.sort();
            variants.dedup();
            json!({"array":variants})
        }
        Value::Object(values) => Value::Object(
            values
                .iter()
                .map(|(key, value)| (key.clone(), shape(value)))
                .collect(),
        ),
    }
}

async fn inbox_processed(pool: &PgPool, event_id: Uuid) -> Result<bool, Failure> {
    sqlx::query_scalar(
        "SELECT processed_at IS NOT NULL FROM ops.inbox WHERE consumer='ingest-worker' AND event_id=$1",
    )
    .bind(event_id)
    .fetch_optional(pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("INBOX_RECORD_MISSING", event_id.to_string()))
}

async fn update_inbox(tx: &mut Transaction<'_, Postgres>, event_id: Uuid) -> Result<(), Failure> {
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='ingest-worker' AND event_id=$1 AND processed_at IS NULL",
    )
    .bind(event_id)
    .execute(&mut **tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(Failure::Terminal("STALE_INBOX", event_id.to_string()))
    }
}

async fn get(store: &Store, key: &str, digest: &str) -> Result<Vec<u8>, ObjectStoreError> {
    match store {
        Store::Filesystem(client) => client.get(key, Some(digest)).await,
        Store::Gateway(client) => client.get(key, Some(digest)).await,
    }
}

fn text_object<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

fn uuid_object(object: &Map<String, Value>, key: &str) -> Option<Uuid> {
    text_object(object, key).and_then(|value| Uuid::parse_str(value).ok())
}

fn uuid(value: &Value, key: &str) -> Option<Uuid> {
    value
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
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

fn object_store(error: ObjectStoreError) -> Failure {
    match error {
        ObjectStoreError::DigestMismatch | ObjectStoreError::InvalidKey => {
            Failure::Terminal("PARSED_OBJECT_INTEGRITY_FAILURE", error.to_string())
        }
        ObjectStoreError::Backend(_) => {
            Failure::Retryable("OBJECT_STORE_UNAVAILABLE", error.to_string())
        }
    }
}
