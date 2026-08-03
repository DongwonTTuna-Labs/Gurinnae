use std::path::{Path, PathBuf};

use gurine_jobs::postgres::{ClaimedJob, JobError, Worker};
use gurine_object_store::{
    filesystem,
    gateway::GatewayObjectStore,
    port::{ObjectStoreClient, ObjectStoreError},
};
use gurine_persistence_postgres::pool::{PoolConfig, connect};
use serde_json::{Value, json};
use sqlx::PgPool;
use thiserror::Error;
use uuid::Uuid;

use crate::{
    config::{Config, ObjectStoreConfig},
    model::{ExtractionResult, ExtractionStatus, sha256_hex},
    multimodal::{AssetBinding, MultimodalStatus, detect_format},
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

include!("document_process.rs");
include!("document_helpers.rs");
