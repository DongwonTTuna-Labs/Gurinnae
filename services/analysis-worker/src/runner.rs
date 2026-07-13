use gurine_agent_orchestration::{
    policy::{self, EvaluationContext},
    schema_validation::{ObjectSchema, validate_object},
};
use gurine_jobs::postgres::{ClaimedJob, JobError, Worker};
use gurine_persistence_postgres::pool::{PoolConfig, connect};
use reqwest::Client;
use rust_decimal::Decimal;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row};
use thiserror::Error;
use uuid::Uuid;

use crate::config::Config;

struct State {
    pool: PgPool,
    worker: Worker,
    client: Client,
    config: Config,
}

#[derive(Debug, Error)]
pub enum WorkerError {
    #[error("analysis worker initialization failed")]
    Initialization,
    #[error("analysis worker job operation failed")]
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
    let worker = Worker::new(
        config.worker_id.clone(),
        "analysis-worker".to_owned(),
        config.lease,
    )
    .map_err(WorkerError::Job)?;
    let state = State {
        pool,
        worker,
        client: Client::builder()
            .timeout(std::time::Duration::from_secs(120))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| WorkerError::Initialization)?,
        config,
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

async fn reconcile_terminal_failure(
    pool: &PgPool,
    job: &ClaimedJob,
    code: &str,
) -> Result<(), JobError> {
    let mut tx = pool.begin().await.map_err(JobError::Database)?;
    match job.job_type.as_str() {
        "AGENT_RUN" => {
            if let Some(id) = job
                .payload
                .get("agentRunId")
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
            {
                sqlx::query(
                    "UPDATE ops.agent_runs SET status='FAILED',completed_at=clock_timestamp(), \
                     output_payload=$2,output_schema_version='failure-v1' \
                     WHERE id=$1 AND status IN ('QUEUED','RUNNING')",
                )
                .bind(id)
                .bind(json!({"code":code,"redacted":true}))
                .execute(&mut *tx)
                .await
                .map_err(JobError::Database)?;
            }
        }
        "RULE_EVALUATION" => {
            if let Some(id) = job
                .payload
                .get("evaluationId")
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
            {
                sqlx::query(
                    "UPDATE core.rule_evaluations SET status='FAILED',completed_at=clock_timestamp(), \
                     result_payload=$2 WHERE id=$1 AND status IN ('QUEUED','RUNNING')",
                )
                .bind(id)
                .bind(json!({"code":code,"redacted":true}))
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
                sqlx::query(
                    "WITH failed AS (UPDATE ops.provider_connection_tests SET status='FAILED', \
                       redacted_result=$2,completed_at=clock_timestamp() \
                     WHERE id=$1 AND status IN ('QUEUED','RUNNING') RETURNING provider_id) \
                     UPDATE ops.provider_configs p SET last_connection_test_at=clock_timestamp(), \
                       last_connection_test_status='FAILED' FROM failed WHERE p.id=failed.provider_id",
                )
                .bind(id)
                .bind(json!({"code":code,"redacted":true}))
                .execute(&mut *tx)
                .await
                .map_err(JobError::Database)?;
            }
        }
        "EVENT_DELIVERY" => {
            if let Some(event_id) = job
                .payload
                .get("eventId")
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
            {
                sqlx::query(
                    "UPDATE ops.inbox SET processed_at=COALESCE(processed_at,clock_timestamp()), \
                       result=$2 WHERE consumer='analysis-worker' AND event_id=$1",
                )
                .bind(event_id)
                .bind(format!("FAILED:{code}"))
                .execute(&mut *tx)
                .await
                .map_err(JobError::Database)?;
            }
        }
        _ => {}
    }
    tx.commit().await.map_err(JobError::Database)
}

async fn handle(state: &State, job: &ClaimedJob) -> Result<Value, Failure> {
    match job.job_type.as_str() {
        "EVENT_DELIVERY" => activation_event(&state.pool, job).await,
        "RULE_EVALUATION" => rule_evaluation(&state.pool, job).await,
        "AGENT_RUN" => agent_run(state, job).await,
        "PROVIDER_CONNECTION_TEST" => provider_connection_test(state, job).await,
        _ => Err(Failure::Terminal(
            "UNSUPPORTED_JOB_TYPE",
            job.job_type.clone(),
        )),
    }
}

async fn activation_event(pool: &PgPool, job: &ClaimedJob) -> Result<Value, Failure> {
    if job.payload.get("eventType").and_then(Value::as_str)
        != Some("workflow.rule_activation_applied.v1")
    {
        return Err(Failure::Terminal(
            "INVALID_RULE_ACTIVATION_EVENT",
            "event type".to_owned(),
        ));
    }
    let event_id = pointer_uuid(&job.payload, "/eventId")?;
    let target = pointer_uuid(&job.payload, "/payload/targetVersionId")?;
    let operation = job
        .payload
        .pointer("/payload/operation_id")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "activateRuleVersion" | "rollbackRuleVersion"))
        .ok_or_else(|| Failure::Terminal("INVALID_RULE_ACTIVATION_EVENT", "operation".into()))?;
    let active: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM core.rule_versions WHERE id=$1 AND status='ACTIVE')",
    )
    .bind(target)
    .fetch_one(pool)
    .await
    .map_err(database)?;
    if !active {
        return Err(Failure::Terminal(
            "RULE_VERSION_NOT_ACTIVE",
            target.to_string(),
        ));
    }
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='analysis-worker' AND event_id=$1 AND processed_at IS NULL",
    )
    .bind(event_id)
    .execute(pool)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        let processed: bool = sqlx::query_scalar(
            "SELECT COALESCE(processed_at IS NOT NULL,false) FROM ops.inbox \
             WHERE consumer='analysis-worker' AND event_id=$1",
        )
        .bind(event_id)
        .fetch_optional(pool)
        .await
        .map_err(database)?
        .unwrap_or(false);
        if !processed {
            return Err(Failure::Terminal(
                "INBOX_FENCE_FAILED",
                event_id.to_string(),
            ));
        }
    }
    Ok(json!({"eventId":event_id,"ruleVersionId":target,"operationId":operation}))
}

async fn rule_evaluation(pool: &PgPool, job: &ClaimedJob) -> Result<Value, Failure> {
    let evaluation_id = payload_uuid(&job.payload, "evaluationId")?;
    let mut tx = pool.begin().await.map_err(database)?;
    let row = sqlx::query(
        "UPDATE core.rule_evaluations e SET status='RUNNING', \
           started_at=COALESCE(started_at,clock_timestamp()) \
         FROM core.rule_versions v WHERE e.id=$1 AND e.rule_version_id=v.id \
           AND e.status IN ('QUEUED','RUNNING') \
         RETURNING e.rule_version_id,e.dataset_snapshot_id,v.rule_id,v.configuration",
    )
    .bind(evaluation_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("RULE_EVALUATION_NOT_QUEUED", evaluation_id.to_string()))?;
    let rule_version_id: Uuid = row.try_get("rule_version_id").map_err(database)?;
    let dataset_snapshot_id: Uuid = row.try_get("dataset_snapshot_id").map_err(database)?;
    let rule_id: String = row.try_get("rule_id").map_err(database)?;
    let configuration: Value = row.try_get("configuration").map_err(database)?;
    let input = configuration
        .get("evaluationInput")
        .ok_or_else(|| Failure::Terminal("RULE_INPUT_MISSING", rule_id.clone()))?;
    let result = gurine_detection::engine::evaluate(&rule_id, input)
        .map_err(|error| Failure::Terminal("RULE_EVALUATION_INVALID", error.to_string()))?;
    let input_digest = sha256(&canonical_bytes(input)?);
    let result_digest = sha256(&canonical_bytes(&result)?);
    let run_id: Uuid = sqlx::query_scalar(
        "INSERT INTO core.rule_runs(rule_version_id,run_key,input_snapshot_at,input_digest, \
           started_at,status) VALUES($1,$2,clock_timestamp(),$3,clock_timestamp(),'RUNNING') \
         ON CONFLICT(run_key) DO UPDATE SET input_digest=EXCLUDED.input_digest \
         WHERE core.rule_runs.status='RUNNING' RETURNING id",
    )
    .bind(rule_version_id)
    .bind(format!("evaluation:{evaluation_id}"))
    .bind(&input_digest)
    .fetch_optional(&mut *tx)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("RULE_RUN_ALREADY_TERMINAL", evaluation_id.to_string()))?;
    let mut signal_count = 0_i64;
    if result.get("outcome").and_then(Value::as_str) == Some("SIGNAL") {
        let target_id = result
            .pointer("/included_ids/0")
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .unwrap_or(dataset_snapshot_id);
        let severity = configuration
            .get("severity")
            .and_then(Value::as_str)
            .filter(|value| matches!(*value, "INFO" | "LOW" | "MEDIUM" | "HIGH" | "CRITICAL"))
            .unwrap_or("HIGH");
        let signal_id = Uuid::new_v4();
        let inserted: Option<Uuid> = sqlx::query_scalar(
            "INSERT INTO core.anomaly_signals(id,rule_run_id,rule_version_id,signal_type, \
               target_type,target_id,severity,explanation,calculation,blockers,comparison_digest) \
             VALUES($1,$2,$3,$4,'DATASET_SNAPSHOT',$5,$6,$7,$8,$9,$10) \
             ON CONFLICT(rule_version_id,target_type,target_id,comparison_digest) DO NOTHING \
             RETURNING id",
        )
        .bind(signal_id)
        .bind(run_id)
        .bind(rule_version_id)
        .bind(&rule_id)
        .bind(target_id)
        .bind(severity)
        .bind(json!({"outcome":"SIGNAL","includedIds":result["included_ids"]}))
        .bind(result.get("metrics").cloned().unwrap_or_else(|| json!({})))
        .bind(result.get("blockers").cloned().unwrap_or_else(|| json!([])))
        .bind(&result_digest)
        .fetch_optional(&mut *tx)
        .await
        .map_err(database)?;
        if let Some(signal_id) = inserted {
            signal_count = 1;
            sqlx::query(
                "SELECT ops.enqueue_outbox('signal',$1,1,'detection.signal_created.v1',$2,clock_timestamp())",
            )
            .bind(signal_id.to_string())
            .bind(json!({
                "signal_id":signal_id,"rule_version_id":rule_version_id,"target_id":target_id
            }))
            .fetch_one(&mut *tx)
            .await
            .map_err(database)?;
        }
    }
    sqlx::query(
        "UPDATE core.rule_runs SET status='SUCCEEDED',completed_at=clock_timestamp(), \
           record_count=1,signal_count=$2 WHERE id=$1 AND status='RUNNING'",
    )
    .bind(run_id)
    .bind(signal_count)
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    sqlx::query(
        "UPDATE core.rule_evaluations SET status='SUCCEEDED',result_payload=$2,result_digest=$3, \
           completed_at=clock_timestamp() WHERE id=$1 AND status='RUNNING'",
    )
    .bind(evaluation_id)
    .bind(&result)
    .bind(&result_digest)
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)?;
    Ok(
        json!({"evaluationId":evaluation_id,"runId":run_id,"signalCount":signal_count,"resultDigest":result_digest}),
    )
}

async fn agent_run(state: &State, job: &ClaimedJob) -> Result<Value, Failure> {
    let run_id = payload_uuid(&job.payload, "agentRunId")?;
    let row = sqlx::query(
        "UPDATE ops.agent_runs SET status='RUNNING',started_at=COALESCE(started_at,clock_timestamp()) \
         WHERE id=$1 AND status IN ('QUEUED','RUNNING') \
         RETURNING case_id,agent_type,objective,evidence_scope_ids,input_snapshot_hash,max_cost",
    )
    .bind(run_id)
    .fetch_optional(&state.pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("AGENT_RUN_NOT_QUEUED", run_id.to_string()))?;
    let case_id: Uuid = row.try_get("case_id").map_err(database)?;
    let agent_type: String = row.try_get("agent_type").map_err(database)?;
    let objective: String = row.try_get("objective").map_err(database)?;
    let evidence_ids = json_uuids(row.try_get("evidence_scope_ids").map_err(database)?)?;
    let expected_snapshot: String = row
        .try_get::<String, _>("input_snapshot_hash")
        .map_err(database)?
        .trim()
        .to_owned();
    let maximum_cost: Decimal = row.try_get("max_cost").map_err(database)?;
    let evidence = evidence_snapshot(&state.pool, case_id, &evidence_ids).await?;
    let snapshot = json!({"caseId":case_id,"evidence":evidence,"objective":objective});
    let current_snapshot = sha256(&canonical_bytes(&snapshot)?);
    let maximum_cost_krw = maximum_cost
        .trunc()
        .to_string()
        .parse::<i64>()
        .map_err(|_| Failure::Terminal("AGENT_BUDGET_INVALID", run_id.to_string()))?;
    let policy_flags = evidence
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|item| {
            item.get("promptInjectionFlags")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let locator_map = evidence
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| Some((item.get("id")?.as_str()?, item.get("locator")?.as_str()?)))
        .map(|(id, locator)| (id.to_owned(), json!([locator])))
        .collect::<serde_json::Map<_, _>>();
    let allowed_ids = evidence_ids.iter().map(Uuid::to_string).collect::<Vec<_>>();
    let input = json!({
        "evidence_snapshot_hash":current_snapshot,
        "allowed_evidence_ids":allowed_ids,
        "budget_krw":maximum_cost_krw,
        "policy_flags":if policy_flags.is_empty(){json!([])}else{json!(["prompt_injection_detected"])},
    });
    let tool = match agent_type.as_str() {
        "market-researcher" => "evidence.search",
        "investigator" | "skeptic" | "claim-drafter" | "citation-verifier" => "evidence.read",
        _ => return Err(Failure::Terminal("AGENT_TYPE_UNKNOWN", agent_type)),
    };
    let transcript = json!({"calls":evidence.as_array().into_iter().flatten().map(|item|json!({
        "tool_id":tool,"mode":"READ_ONLY","cost_krw":0,
        "request":{"evidence_id":item["id"]},
        "response":{"results":[{"id":item["id"],"locator":item["locator"]}]}
    })).collect::<Vec<_>>()});

    let (provider, model, provider_output, actual_cost, provider_available) =
        if expected_snapshot != current_snapshot {
            (
                "none".to_owned(),
                "none".to_owned(),
                blocked_output("ABSTAINED", "EVIDENCE_SNAPSHOT_STALE"),
                0_i64,
                false,
            )
        } else if !state.config.ai_enabled {
            (
                "none".to_owned(),
                "none".to_owned(),
                blocked_output("POLICY_BLOCKED", "AI_DISABLED"),
                0_i64,
                false,
            )
        } else if matches!(state.config.environment.as_str(), "development" | "test") {
            (
                "deterministic".to_owned(),
                "authority-double-v1".to_owned(),
                deterministic_output(&evidence),
                0_i64,
                true,
            )
        } else {
            production_provider(
                state,
                run_id,
                &agent_type,
                &objective,
                &evidence,
                maximum_cost_krw,
            )
            .await?
        };

    validate_agent_output(&provider_output)?;
    let output = if matches!(
        provider_output.get("status").and_then(Value::as_str),
        Some("POLICY_BLOCKED" | "BUDGET_BLOCKED")
    ) || expected_snapshot != current_snapshot
    {
        provider_output
    } else {
        let scenario = json!({
            "kind":"normal","current_evidence_snapshot_hash":current_snapshot,
            "provider_attempts":[{"provider":provider,"status":if provider_available{"OK"}else{"UNAVAILABLE"},"cost_krw":actual_cost}],
            "expected_locator_map":Value::Object(locator_map),"max_iterations":16
        });
        policy::evaluate(EvaluationContext {
            agent_id: &agent_type,
            scenario: &scenario,
            input: &input,
            provider_output: &provider_output,
            transcript: &transcript,
        })
        .map_err(|error| Failure::Terminal("AGENT_POLICY_INVALID", error.to_string()))?
    };
    validate_agent_output(&output)?;
    let status = match output.get("status").and_then(Value::as_str) {
        Some("BUDGET_BLOCKED") => "BUDGET_BLOCKED",
        Some("POLICY_BLOCKED") => "POLICY_BLOCKED",
        Some("COMPLETED" | "ABSTAINED") => "SUCCEEDED",
        _ => return Err(Failure::Terminal("AGENT_OUTPUT_INVALID", "status".into())),
    };
    let digest = sha256(&canonical_bytes(&output)?);
    let mut tx = state.pool.begin().await.map_err(database)?;
    let changed = sqlx::query(
        "UPDATE ops.agent_runs SET status=$2,provider=$3,model=$4,output_payload=$5, \
           output_schema_version='v1',actual_cost=$6,completed_at=clock_timestamp() \
         WHERE id=$1 AND status='RUNNING'",
    )
    .bind(run_id)
    .bind(status)
    .bind(&provider)
    .bind(&model)
    .bind(&output)
    .bind(Decimal::from(actual_cost))
    .execute(&mut *tx)
    .await
    .map_err(database)?
    .rows_affected();
    if changed != 1 {
        return Err(Failure::Terminal(
            "AGENT_RUN_FENCE_FAILED",
            run_id.to_string(),
        ));
    }
    if actual_cost > 0 {
        sqlx::query(
            "INSERT INTO ops.cost_events(provider_id,case_id,job_id,occurred_at,model,amount,currency,metadata) \
             VALUES((SELECT id FROM ops.provider_configs WHERE lower(provider_type)=lower($1) LIMIT 1), \
               $2,$3,clock_timestamp(),$4,$5,'KRW',$6)",
        )
        .bind(&provider)
        .bind(case_id)
        .bind(job.id)
        .bind(&model)
        .bind(Decimal::from(actual_cost))
        .bind(json!({"agentRunId":run_id,"redacted":true}))
        .execute(&mut *tx)
        .await
        .map_err(database)?;
    }
    if output.get("status").and_then(Value::as_str) == Some("COMPLETED") {
        sqlx::query(
            "INSERT INTO ops.agent_suggestions(agent_run_id,case_id,suggestion_type,payload,evidence_ids,citation_checks,status) \
             VALUES($1,$2,$3,$4,$5,$6,'PENDING')",
        )
        .bind(run_id)
        .bind(case_id)
        .bind(agent_type.to_uppercase().replace('-', "_"))
        .bind(&output)
        .bind(json!(allowed_ids))
        .bind(output.get("citations").cloned().unwrap_or_else(|| json!([])))
        .execute(&mut *tx)
        .await
        .map_err(database)?;
    }
    sqlx::query(
        "SELECT ops.enqueue_outbox('agent_run',$1,1,'agent.run_completed.v1',$2,clock_timestamp())",
    )
    .bind(run_id.to_string())
    .bind(json!({"agent_run_id":run_id,"case_id":case_id,"output_digest":digest,"status":status}))
    .fetch_one(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)?;
    Ok(json!({"agentRunId":run_id,"status":status,"outputDigest":digest,"provider":provider}))
}

async fn provider_connection_test(state: &State, job: &ClaimedJob) -> Result<Value, Failure> {
    let test_id = payload_uuid(&job.payload, "providerConnectionTestId")?;
    let row = sqlx::query(
        "UPDATE ops.provider_connection_tests t SET status='RUNNING', \
           started_at=COALESCE(started_at,clock_timestamp()) \
         FROM ops.provider_configs p WHERE t.id=$1 AND t.provider_id=p.id \
           AND t.status IN ('QUEUED','RUNNING') \
         RETURNING t.provider_id,t.test_model,p.provider_type,p.enabled,p.routing_policy",
    )
    .bind(test_id)
    .fetch_optional(&state.pool)
    .await
    .map_err(database)?
    .ok_or_else(|| Failure::Terminal("PROVIDER_TEST_NOT_QUEUED", test_id.to_string()))?;
    let provider_id: Uuid = row.try_get("provider_id").map_err(database)?;
    let model: String = row.try_get("test_model").map_err(database)?;
    let provider_type: String = row.try_get("provider_type").map_err(database)?;
    let enabled: bool = row.try_get("enabled").map_err(database)?;
    let routing: Value = row.try_get("routing_policy").map_err(database)?;
    let (status, redacted) = if !enabled || !state.config.ai_enabled {
        (
            "FAILED",
            json!({"code":"PROVIDER_DISABLED","redacted":true}),
        )
    } else if matches!(state.config.environment.as_str(), "development" | "test") {
        (
            "SUCCEEDED",
            json!({"provider":"deterministic","model":model,"redacted":true}),
        )
    } else {
        let target = routing
            .get("targetUrl")
            .and_then(Value::as_str)
            .ok_or_else(|| Failure::Terminal("PROVIDER_TARGET_MISSING", provider_id.to_string()))?;
        let gateway = state
            .config
            .egress_ai_url
            .as_ref()
            .ok_or_else(|| Failure::Terminal("AI_EGRESS_MISSING", provider_id.to_string()))?;
        let response = state
            .client
            .post(gateway.clone())
            .header("x-gurine-egress-caller", "analysis-worker")
            .header("x-gurine-ai-provider", &provider_type)
            .header("x-gurine-egress-target", target)
            .json(&json!({"operation":"connection_test","model":model}))
            .send()
            .await
            .map_err(|error| Failure::Retryable("PROVIDER_UNAVAILABLE", error.to_string()))?;
        let http_status = response.status().as_u16();
        (
            if response.status().is_success() {
                "SUCCEEDED"
            } else {
                "FAILED"
            },
            json!({"httpStatus":http_status,"redacted":true}),
        )
    };
    let mut tx = state.pool.begin().await.map_err(database)?;
    sqlx::query(
        "UPDATE ops.provider_connection_tests SET status=$2,redacted_result=$3,completed_at=clock_timestamp() \
         WHERE id=$1 AND status='RUNNING'",
    )
    .bind(test_id)
    .bind(status)
    .bind(&redacted)
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    sqlx::query(
        "UPDATE ops.provider_configs SET last_connection_test_at=clock_timestamp(), \
           last_connection_test_status=$2 WHERE id=$1",
    )
    .bind(provider_id)
    .bind(status)
    .execute(&mut *tx)
    .await
    .map_err(database)?;
    tx.commit().await.map_err(database)?;
    Ok(json!({"providerConnectionTestId":test_id,"providerType":provider_type,"status":status}))
}

async fn production_provider(
    state: &State,
    run_id: Uuid,
    agent_type: &str,
    objective: &str,
    evidence: &Value,
    maximum_cost_krw: i64,
) -> Result<(String, String, Value, i64, bool), Failure> {
    let rows = sqlx::query(
        "SELECT provider_type,name,routing_policy FROM ops.provider_configs WHERE enabled",
    )
    .fetch_all(&state.pool)
    .await
    .map_err(database)?;
    let gateway = state
        .config
        .egress_ai_url
        .as_ref()
        .ok_or_else(|| Failure::Terminal("AI_EGRESS_MISSING", run_id.to_string()))?;
    for requested in &state.config.provider_order {
        let Some(row) = rows.iter().find(|row| {
            row.try_get::<String, _>("provider_type")
                .is_ok_and(|value| value.eq_ignore_ascii_case(requested))
                || row
                    .try_get::<String, _>("name")
                    .is_ok_and(|value| value.eq_ignore_ascii_case(requested))
        }) else {
            continue;
        };
        let provider: String = row.try_get("provider_type").map_err(database)?;
        let routing: Value = row.try_get("routing_policy").map_err(database)?;
        let Some(target) = routing.get("targetUrl").and_then(Value::as_str) else {
            continue;
        };
        let model = routing
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or("approved-default")
            .to_owned();
        let response = match state
            .client
            .post(gateway.clone())
            .header("x-gurine-egress-caller", "analysis-worker")
            .header("x-gurine-ai-provider", &provider)
            .header("x-gurine-egress-target", target)
            .json(&json!({
                "agentRunId":run_id,"agentType":agent_type,"objective":objective,
                "evidence":evidence,"model":model,"maxCostKrw":maximum_cost_krw,
                "responseFormat":"gurine-agent-output-v1"
            }))
            .send()
            .await
        {
            Ok(response) if response.status().is_success() => response,
            Ok(_) | Err(_) => continue,
        };
        let body: Value = response
            .json()
            .await
            .map_err(|error| Failure::Terminal("PROVIDER_OUTPUT_INVALID", error.to_string()))?;
        let output = body.get("output").cloned().unwrap_or_else(|| body.clone());
        let actual_cost = body.get("costKrw").and_then(Value::as_i64).unwrap_or(0);
        if actual_cost < 0 || actual_cost > maximum_cost_krw {
            return Err(Failure::Terminal("PROVIDER_COST_INVALID", provider));
        }
        validate_agent_output(&output)?;
        return Ok((provider, model, output, actual_cost, true));
    }
    Ok((
        "none".to_owned(),
        "none".to_owned(),
        blocked_output("ABSTAINED", "PROVIDER_UNAVAILABLE"),
        0,
        false,
    ))
}

async fn evidence_snapshot(pool: &PgPool, case_id: Uuid, ids: &[Uuid]) -> Result<Value, Failure> {
    let value: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object( \
           'id',e.id,'contentSha256',btrim(e.content_sha256::text), \
           'locator',e.source_locator,'updatedAt',e.updated_at, \
           'promptInjectionFlags',COALESCE(d.prompt_injection_flags,'[]'::jsonb) \
         ) ORDER BY e.id),'[]'::jsonb) \
         FROM editorial.evidence e LEFT JOIN raw.source_documents d ON d.id=e.source_document_id \
         WHERE e.case_id=$1 AND e.id=ANY($2::uuid[]) \
           AND e.verification_status='VERIFIED'",
    )
    .bind(case_id)
    .bind(ids)
    .fetch_one(pool)
    .await
    .map_err(database)?;
    if value.as_array().is_none_or(|rows| rows.len() != ids.len()) {
        return Err(Failure::Terminal(
            "AGENT_EVIDENCE_SCOPE_INVALID",
            case_id.to_string(),
        ));
    }
    Ok(value)
}

fn deterministic_output(evidence: &Value) -> Value {
    let Some(first) = evidence.as_array().and_then(|items| items.first()) else {
        return blocked_output("ABSTAINED", "EVIDENCE_REQUIRED");
    };
    json!({
        "status":"COMPLETED",
        "summary":"고정된 검증 근거 snapshot을 읽기 전용으로 검토했습니다. 사람의 독립 검토가 필요합니다.",
        "citations":[{"evidence_id":first["id"],"locator":first["locator"],"supports":"검토 대상 근거 snapshot"}],
        "unknowns":[],"abstention_reasons":[],"recommended_actions":[]
    })
}

fn blocked_output(status: &str, reason: &str) -> Value {
    json!({
        "status":status,
        "summary":"정책 또는 검증 조건을 충족하지 못해 결론을 생성하지 않았습니다.",
        "citations":[],"unknowns":[],"abstention_reasons":[reason],"recommended_actions":[]
    })
}

fn validate_agent_output(value: &Value) -> Result<(), Failure> {
    const REQUIRED: &[&str] = &[
        "status",
        "summary",
        "citations",
        "unknowns",
        "abstention_reasons",
    ];
    const ALLOWED: &[&str] = &[
        "status",
        "summary",
        "citations",
        "unknowns",
        "abstention_reasons",
        "recommended_actions",
        "comparables",
        "hypotheses",
        "alternative_explanations",
        "draft_claims",
        "verification_results",
    ];
    validate_object(
        value,
        ObjectSchema {
            required: REQUIRED,
            allowed: ALLOWED,
        },
    )
    .map_err(|error| Failure::Terminal("AGENT_OUTPUT_SCHEMA_INVALID", error.to_string()))?;
    let status = value.get("status").and_then(Value::as_str);
    if !matches!(
        status,
        Some("COMPLETED" | "ABSTAINED" | "POLICY_BLOCKED" | "BUDGET_BLOCKED")
    ) || value.get("summary").and_then(Value::as_str).is_none()
        || value.get("citations").and_then(Value::as_array).is_none()
        || value.get("unknowns").and_then(Value::as_array).is_none()
        || value
            .get("abstention_reasons")
            .and_then(Value::as_array)
            .is_none()
    {
        return Err(Failure::Terminal(
            "AGENT_OUTPUT_SCHEMA_INVALID",
            "field type".into(),
        ));
    }
    for citation in value["citations"].as_array().into_iter().flatten() {
        if citation
            .get("evidence_id")
            .and_then(Value::as_str)
            .is_none()
            || citation.get("locator").and_then(Value::as_str).is_none()
            || citation.get("supports").and_then(Value::as_str).is_none()
        {
            return Err(Failure::Terminal(
                "AGENT_OUTPUT_SCHEMA_INVALID",
                "citation".into(),
            ));
        }
    }
    Ok(())
}

fn pointer_uuid(value: &Value, pointer: &str) -> Result<Uuid, Failure> {
    value
        .pointer(pointer)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("INVALID_JOB_PAYLOAD", pointer.to_owned()))
}

fn payload_uuid(value: &Value, key: &str) -> Result<Uuid, Failure> {
    value
        .get(key)
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| Failure::Terminal("INVALID_JOB_PAYLOAD", key.to_owned()))
}

fn json_uuids(value: Value) -> Result<Vec<Uuid>, Failure> {
    value
        .as_array()
        .ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "array".into()))?
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or_else(|| Failure::Terminal("AGENT_EVIDENCE_SCOPE_INVALID", "uuid".into()))
        })
        .collect()
}

fn canonical_bytes(value: &Value) -> Result<Vec<u8>, Failure> {
    serde_json::to_vec(value)
        .map_err(|error| Failure::Terminal("JSON_SERIALIZATION_FAILED", error.to_string()))
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
