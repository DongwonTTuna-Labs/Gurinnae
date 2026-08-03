use std::{path::Path, sync::Arc, time::Duration};

use arrow_array::{ArrayRef, RecordBatch, StringArray};
use arrow_schema::{DataType, Field, Schema};
use gurine_auth::envelope::{EnvelopeKey, EnvelopeKeyRing};
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
    let field_keys = EnvelopeKeyRing {
        current: EnvelopeKey::new(config.field_key_current),
        previous: config.field_key_previous.map(EnvelopeKey::new),
    };
    let worker = Worker::new(
        config.worker_id.clone(),
        "workflow-worker".to_owned(),
        config.job_lease,
    )
    .map_err(WorkerError::Job)?;
    loop {
        let processed = if process_event_one(&pool, &store, &scanner, &field_keys, &worker).await? {
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
    field_keys: &EnvelopeKeyRing,
    worker: &Worker,
) -> Result<bool, WorkerError> {
    let Some(job) = worker.claim(pool).await.map_err(WorkerError::Job)? else {
        return Ok(false);
    };
    match handle_event(pool, store, scanner, field_keys, &job).await {
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

include!("workflow_events.rs");
include!("workflow_action_execution.rs");
include!("workflow_exports.rs");
include!("workflow_pending.rs");
