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
    OwnerTerminalizedContractInvalid(&'static str, String),
    OwnerOutcomeUnknown(&'static str, String),
}

enum WorkflowJobCompletion {
    WorkerOwned(Value),
    OwnerTerminalized,
}

enum WorkflowJobResolution {
    Complete(Value),
    Fail {
        code: &'static str,
        detail: String,
        retryable: bool,
    },
    SkipOwnerTerminalized,
    StopOnOwnerContract {
        code: &'static str,
        detail_digest: String,
    },
    StopOnOwnerOutcomeUnknown {
        phase: &'static str,
        detail_digest: String,
    },
}

fn workflow_job_resolution(
    result: Result<WorkflowJobCompletion, Failure>,
) -> WorkflowJobResolution {
    match result {
        Ok(WorkflowJobCompletion::WorkerOwned(metrics)) => WorkflowJobResolution::Complete(metrics),
        Ok(WorkflowJobCompletion::OwnerTerminalized) => {
            WorkflowJobResolution::SkipOwnerTerminalized
        }
        Err(Failure::Terminal(code, detail)) => WorkflowJobResolution::Fail {
            code,
            detail,
            retryable: false,
        },
        Err(Failure::Retryable(code, detail)) => WorkflowJobResolution::Fail {
            code,
            detail,
            retryable: true,
        },
        Err(Failure::OwnerTerminalizedContractInvalid(code, detail_digest)) => {
            WorkflowJobResolution::StopOnOwnerContract {
                code,
                detail_digest,
            }
        }
        Err(Failure::OwnerOutcomeUnknown(phase, detail_digest)) => {
            WorkflowJobResolution::StopOnOwnerOutcomeUnknown {
                phase,
                detail_digest,
            }
        }
    }
}

fn required<T>(value: Option<T>) -> Result<T, sqlx::Error> {
    value.ok_or_else(|| sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError)))
}

pub async fn run(config: Config) -> Result<(), WorkerError> {
    let pool = connect(&PoolConfig {
        database_url: config.database_url.clone(),
        max_connections: 4,
        acquire_timeout: Duration::from_secs(10),
    })
    .await
    .map_err(|_| WorkerError::Initialization)?;
    let economics_pool = open_economics_pool(config.economics_database_url.as_deref()).await?;
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
        let processed = if process_event_one(
            &pool,
            economics_pool.as_ref(),
            &store,
            &scanner,
            &field_keys,
            &config.worker_id,
            &worker,
        )
        .await?
        {
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
    economics_pool: Option<&PgPool>,
    store: &Store,
    scanner: &ClamAvScanner,
    field_keys: &EnvelopeKeyRing,
    worker_id: &str,
    worker: &Worker,
) -> Result<bool, WorkerError> {
    let Some(job) = worker.claim(pool).await.map_err(WorkerError::Job)? else {
        return Ok(false);
    };
    let result = handle_workflow_job(
        pool,
        economics_pool,
        store,
        scanner,
        field_keys,
        worker_id,
        &job,
    )
    .await;
    match workflow_job_resolution(result) {
        WorkflowJobResolution::Complete(metrics) => worker
            .complete(pool, &job, metrics)
            .await
            .map_err(WorkerError::Job)?,
        WorkflowJobResolution::Fail {
            code,
            detail,
            retryable,
        } => {
            worker
                .fail(pool, &job, code, &detail, retryable, json!({}))
                .await
                .map_err(WorkerError::Job)?;
        }
        WorkflowJobResolution::SkipOwnerTerminalized => {}
        WorkflowJobResolution::StopOnOwnerContract {
            code,
            detail_digest,
        } => {
            tracing::error!(code, %detail_digest, "economics owner terminal contract invalid");
            return Err(WorkerError::Database);
        }
        WorkflowJobResolution::StopOnOwnerOutcomeUnknown {
            phase,
            detail_digest,
        } => {
            tracing::error!(phase, %detail_digest, "economics owner outcome unknown");
            return Err(WorkerError::Database);
        }
    }
    Ok(true)
}

include!("workflow_events.rs");
include!("workflow_action_execution.rs");
include!("workflow_funding_disclosure.rs");
include!("workflow_economics_import.rs");
include!("workflow_hypothesis_execution.rs");
include!("workflow_exports.rs");
include!("workflow_response_materialization.rs");
include!("workflow_signal.rs");
include!("workflow_hypothesis_recursion.rs");
include!("workflow_retention.rs");
include!("workflow_entity_retention_job.rs");
include!("workflow_retention_job.rs");
include!("workflow_response_party_name_correction_contract.rs");
include!("workflow_response_party_name_correction_job.rs");
include!("workflow_response_party_name_correction_delegation.rs");
include!("workflow_pending.rs");
