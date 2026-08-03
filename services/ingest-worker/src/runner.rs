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
use sqlx::{PgPool, Postgres, Transaction};
use thiserror::Error;
use uuid::Uuid;

use crate::config::{Config, ObjectStoreConfig};

mod source_fetch_persistence;

use source_fetch_persistence::persist_source_fetch;

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

include!("ingest_jobs.rs");
include!("ingest_connector.rs");
include!("ingest_persist.rs");
