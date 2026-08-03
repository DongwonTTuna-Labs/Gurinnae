use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use gurine_agent_orchestration::{
    policy::{self, EvaluationContext},
    provider_double::{embedded_provider_response, validate_authority_agent_output},
    runtime::{
        AgentFinalOutput, FinalStatus, MultiTurnConfig, MultiTurnRuntime, ProviderAdapter,
        ProviderEnvelope, ProviderOutcome, ProviderReceipt, ProviderReply, ProviderRequest,
        ProviderRuntimeError, SnapshotBinding, ToolCall, TypedDispatcher, provider_receipt_sha256,
        provider_request_sha256,
    },
    schema_validation::{ObjectSchema, validate_object},
};
use gurine_api_contracts::agent_snapshot::agent_case_snapshot_sha256;
use gurine_jobs::postgres::{ClaimedJob, JobError, Worker};
use gurine_object_store::gateway::GatewayObjectStore;
use gurine_persistence_postgres::pool::{PoolConfig, connect};
use reqwest::Client;
use rust_decimal::Decimal;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use thiserror::Error;
use uuid::Uuid;

use crate::config::Config;

#[path = "analysis_relay_upgrade_receipt.rs"]
mod analysis_relay_upgrade_receipt;
#[path = "analysis_runtime_snapshot.rs"]
mod analysis_runtime_snapshot;

use analysis_relay_upgrade_receipt::{
    RelayUpgradeAttemptKind, RelayUpgradeReceipt, RelayUpgradeReceiptInput,
    RelayUpgradeReceiptOutcome,
};

struct State {
    pool: PgPool,
    worker: Worker,
    client: Client,
    config: Config,
    object_store: Option<GatewayObjectStore>,
}

#[derive(Debug, Error)]
pub enum WorkerError {
    #[error("analysis worker initialization failed")]
    Initialization,
    #[error("analysis worker job operation failed")]
    Job(#[source] JobError),
}

#[derive(Debug)]
pub(crate) enum Failure {
    Terminal(&'static str, String),
    Retryable(&'static str, String),
}

fn required<T>(value: Option<T>) -> Result<T, sqlx::Error> {
    value.ok_or_else(|| sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError)))
}

pub async fn run(config: Config) -> Result<(), WorkerError> {
    let pool = connect(&PoolConfig {
        database_url: config.database_url.clone(),
        max_connections: 6,
        acquire_timeout: std::time::Duration::from_secs(10),
    })
    .await
    .map_err(|_| WorkerError::Initialization)?;
    let worker = Worker::new(
        config.worker_id.clone(),
        "analysis-worker".to_owned(),
        config.lease,
    )
    .map_err(WorkerError::Job)?;
    let object_store = config
        .egress_object_store_url
        .clone()
        .map(|url| GatewayObjectStore::new(url, "analysis-worker"))
        .transpose()
        .map_err(|_| WorkerError::Initialization)?;
    let state = State {
        pool,
        worker,
        client: Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| WorkerError::Initialization)?,
        config,
        object_store,
    };
    tracing::info!(worker_id=%state.config.worker_id,"analysis worker ready");
    loop {
        let processed = process_one(&state).await?;
        if state.config.once {
            if !processed {
                return Ok(());
            }
        } else if !processed {
            tokio::select! {
                () = tokio::time::sleep(state.config.poll_interval) => {},
                signal = tokio::signal::ctrl_c() => {
                    signal.map_err(|_| WorkerError::Initialization)?;
                    tracing::info!("analysis worker shutdown requested");
                    return Ok(());
                }
            }
        }
    }
}

async fn process_one(state: &State) -> Result<bool, WorkerError> {
    let Some(job) = state
        .worker
        .claim(&state.pool)
        .await
        .map_err(WorkerError::Job)?
    else {
        return Ok(false);
    };
    match handle(state, &job).await {
        Ok(metrics) => state
            .worker
            .complete(&state.pool, &job, metrics)
            .await
            .map_err(WorkerError::Job)?,
        Err(Failure::Terminal(code, detail)) => {
            tracing::error!(job_type=%job.job_type, code, detail=%detail, "analysis job terminal failure");
            reconcile_terminal_failure(&state.pool, &job, code)
                .await
                .map_err(WorkerError::Job)?;
            state
                .worker
                .fail(&state.pool, &job, code, &detail, false, json!({}))
                .await
                .map_err(WorkerError::Job)?;
        }
        Err(Failure::Retryable(code, detail)) => {
            tracing::warn!(job_type=%job.job_type, code, detail=%detail, "analysis job retryable failure");
            let retrying = state
                .worker
                .fail(&state.pool, &job, code, &detail, true, json!({}))
                .await
                .map_err(WorkerError::Job)?;
            if !retrying {
                reconcile_terminal_failure(&state.pool, &job, code)
                    .await
                    .map_err(WorkerError::Job)?;
            }
        }
    }
    Ok(true)
}

#[rustfmt::skip]
async fn reconcile_terminal_failure(
    pool: &PgPool,
    job: &ClaimedJob,
    code: &str,
) -> Result<(), JobError> {
    let mut tx = pool.begin().await.map_err(JobError::Database)?; match job.job_type.as_str() {
        "AGENT_RUN" => {
            reconcile_agent_run(&mut tx, job, code).await?;
        }
        "RULE_EVALUATION" => {
            if let Some(id) = job
                .payload
                .get("evaluationId")
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
            {
                sqlx::query!(
                    "UPDATE core.rule_evaluations SET status='FAILED',completed_at=clock_timestamp(), \
                     result_payload=$2 WHERE id=$1 AND status IN ('QUEUED','RUNNING')",
                    id,
                    json!({"code":code,"redacted":true}),
                )
                .execute(&mut *tx)
                .await
                .map_err(JobError::Database)?;
            }
        }
        "PROVIDER_CONNECTION_TEST" => {
            if let Some(id) = job
                .payload
                .get("providerConnectionTestId")
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
            {
                sqlx::query!(
                    "WITH failed AS (UPDATE ops.provider_connection_tests SET status='FAILED', \
                       redacted_result=$2,completed_at=clock_timestamp() \
                     WHERE id=$1 AND status IN ('QUEUED','RUNNING') RETURNING provider_id) \
                     UPDATE ops.provider_configs p SET last_connection_test_at=clock_timestamp(), \
                       last_connection_test_status='FAILED' FROM failed WHERE p.id=failed.provider_id",
                    id,
                    json!({"code":code,"redacted":true}),
                )
                .execute(&mut *tx)
                .await
                .map_err(JobError::Database)?;
            }
        }
        "RELAY_MODEL_CATALOG_SYNC" => {
            if let Some(id) = job
                .payload
                .get("catalogSyncRunId")
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
            {
                sqlx::query!(
                    "UPDATE ops.relay_model_catalog_sync_runs SET status='FAILED',error_code=$2, \
                       started_at=COALESCE(started_at,clock_timestamp()),completed_at=clock_timestamp() \
                     WHERE id=$1 AND status IN ('QUEUED','RUNNING')",
                    id,
                    code,
                )
                .execute(&mut *tx)
                .await
                .map_err(JobError::Database)?;
            }
        }
        "PROVIDER_MODEL_UPGRADE" => {
            reconcile_relay_upgrade_failure(&mut tx, job, code).await?;
        }
        "EVENT_DELIVERY" => {
            if let Some(event_id) = job
                .payload
                .get("eventId")
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
            {
                let consumer = event_delivery_inbox_consumer(job);
                sqlx::query!(
                    "UPDATE ops.inbox SET processed_at=COALESCE(processed_at,clock_timestamp()), \
                       result=$2 WHERE consumer=$3 AND event_id=$1",
                    event_id,
                    format!("FAILED:{code}"),
                    consumer,
                )
                .execute(&mut *tx)
                .await
                .map_err(JobError::Database)?;
            }
        }
        _ => {}
    }
    tx.commit().await.map_err(JobError::Database)
}

fn event_delivery_inbox_consumer(job: &ClaimedJob) -> &'static str {
    if job.payload.get("consumerId").and_then(Value::as_str) == Some(PROVIDER_CONTROL_CONSUMER) {
        PROVIDER_CONTROL_CONSUMER
    } else {
        "analysis-worker"
    }
}

async fn reconcile_agent_run(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    job: &ClaimedJob,
    code: &str,
) -> Result<(), JobError> {
    let Some(id) = job
        .payload
        .get("agentRunId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
    else {
        return Ok(());
    };
    if code == "PROVIDER_OUTCOME_UNKNOWN" {
        // A request may have reached the gateway. Keep RUNNING for
        // reconciliation; FAILED here would permit duplicate dispatch.
        sqlx::Executor::execute(
            &mut **tx,
            sqlx::query_scalar!(
                "SELECT ops.transition_agent_run_worker_v1($1,NULL,NULL,NULL,NULL,$2,NULL,NULL,false)",
                id,
                json!({"status":"RECONCILIATION_REQUIRED","code":code,"redacted":true}),
            ),
        )
        .await
        .map_err(JobError::Database)?;
        return Ok(());
    }
    sqlx::Executor::execute(
        &mut **tx,
        sqlx::query_scalar!(
            "SELECT ops.transition_agent_run_worker_v1($1,NULL,'FAILED',NULL,NULL,$2,'failure-v1',NULL,true)",
            id,
            json!({"code":code,"redacted":true}),
        ),
    )
    .await
    .map_err(JobError::Database)?;
    Ok(())
}

async fn handle(state: &State, job: &ClaimedJob) -> Result<Value, Failure> {
    match job.job_type.as_str() {
        "EVENT_DELIVERY" => analysis_event(state, job).await,
        "RULE_EVALUATION" => rule_evaluation(&state.pool, job).await,
        "AGENT_RUN" => agent_run(state, job).await,
        "PROVIDER_CONNECTION_TEST" => provider_connection_test(state, job).await,
        "RELAY_MODEL_CATALOG_SYNC" => relay_model_catalog_sync(state, job).await,
        "PROVIDER_MODEL_UPGRADE" => provider_model_upgrade(state, job).await,
        _ => Err(Failure::Terminal(
            "UNSUPPORTED_JOB_TYPE",
            job.job_type.clone(),
        )),
    }
}

include!("analysis_jobs.rs");
include!("analysis_job_persistence.rs");
include!("analysis_context.rs");
include!("analysis_source_use_roots.rs");
include!("analysis_provider_connection.rs");
include!("analysis_provider_rights.rs");
include!("analysis_relay_protocol.rs");
include!("analysis_provider_control.rs");
include!("analysis_relay_catalog.rs");
include!("analysis_provider_upgrade.rs");
include!("analysis_provider_upgrade_failure.rs");
include!("analysis_provider.rs");
include!("analysis_provider_types.rs");
include!("analysis_provider_persistence.rs");
include!("analysis_provider_receipt.rs");
include!("analysis_provider_completion.rs");
include!("analysis_provider_owner.rs");
include!("analysis_tool_decode.rs");
include!("analysis_runtime_bridge.rs");
include!("analysis_validation_helpers.rs");
include!("analysis_helpers.rs");
