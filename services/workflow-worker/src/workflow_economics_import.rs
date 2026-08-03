const ECONOMICS_ACTION_KIND: &str = "ECONOMICS_IMPORT";
const ECONOMICS_TARGET_COMMAND: &str = "private.ExecuteEconomicsImport";
const ECONOMICS_DATABASE_ROLE: &str = "gurine_economics_importer";
// Claim must stay disabled until the DB-owned apply routine and complete wrapper
// have passed the same FINAL migration validation.
const ECONOMICS_OWNER_ABI_READY: bool = false;
const ECONOMICS_ROLE_CHECK_SQL: &str =
    "SELECT session_user='gurine_economics_importer', current_user='gurine_economics_importer'";

#[derive(Clone, Copy)]
struct EconomicsAuthorizationEvent<'a> {
    source_event_id: Uuid,
    execution_id: Uuid,
    generation: i64,
    decision_digest: &'a str,
    execution_digest: &'a str,
    target_request_sha256: &'a str,
    expires_at: time::OffsetDateTime,
}

async fn verify_economics_pool_role(pool: &PgPool) -> Result<(), WorkerError> {
    match economics_pool_has_dedicated_role(pool).await {
        Ok(has_dedicated_role) => validate_economics_pool_role(has_dedicated_role),
        Err(_) => Err(WorkerError::Initialization),
    }
}

async fn open_economics_pool(database_url: Option<&str>) -> Result<Option<PgPool>, WorkerError> {
    let Some(database_url) = database_url else {
        return Ok(None);
    };
    let pool = connect(&PoolConfig {
        database_url: database_url.to_owned(),
        max_connections: 2,
        acquire_timeout: Duration::from_secs(10),
    })
    .await
    .map_err(|_| WorkerError::Initialization)?;
    verify_economics_pool_role(&pool).await?;
    Ok(Some(pool))
}

fn validate_economics_pool_role(has_dedicated_role: bool) -> Result<(), WorkerError> {
    if has_dedicated_role {
        Ok(())
    } else {
        Err(WorkerError::Initialization)
    }
}

async fn economics_pool_has_dedicated_role(pool: &PgPool) -> Result<bool, sqlx::Error> {
    let (session_user_matches, current_user_matches) =
        sqlx::query_as::<_, (bool, bool)>(ECONOMICS_ROLE_CHECK_SQL)
            .fetch_one(pool)
            .await?;
    Ok(economics_principals_are_dedicated(
        session_user_matches,
        current_user_matches,
    ))
}

const fn economics_principals_are_dedicated(
    session_user_matches: bool,
    current_user_matches: bool,
) -> bool {
    session_user_matches && current_user_matches
}

async fn execute_approved_economics_import(
    economics_pool: &PgPool,
    source_event_id: Uuid,
    producer_job: ProducerJobFence,
    worker_id: &str,
    execution: &ApprovedExecution,
) -> Result<WorkflowJobCompletion, Failure> {
    let authorization = economics_authorization_event(source_event_id, execution)?;
    validate_economics_producer_fence(producer_job, worker_id)?;
    if !economics_pool_has_dedicated_role(economics_pool)
        .await
        .map_err(economics_owner_database_failure)?
    {
        return Err(Failure::Terminal(
            "ECONOMICS_DATABASE_ROLE_INVALID",
            ECONOMICS_DATABASE_ROLE.to_owned(),
        ));
    }
    if !ECONOMICS_OWNER_ABI_READY {
        return Err(Failure::Retryable(
            "ECONOMICS_OWNER_ABI_UNAVAILABLE",
            "redacted:owner-abi-not-final".to_owned(),
        ));
    }
    execute_economics_owner_workflow(economics_pool, authorization, producer_job, worker_id).await
}

fn economics_authorization_event<'a>(
    source_event_id: Uuid,
    execution: &'a ApprovedExecution,
) -> Result<EconomicsAuthorizationEvent<'a>, Failure> {
    if source_event_id.is_nil() {
        return Err(invalid_economics_execution("eventId"));
    }
    let payload = execution
        .event_payload
        .as_object()
        .ok_or_else(|| invalid_economics_execution("payload"))?;
    const KEYS: [&str; 8] = [
        "executionId",
        "generation",
        "actionKind",
        "decisionDigest",
        "executionDigest",
        "targetCommand",
        "targetRequestSha256",
        "expiresAt",
    ];
    if payload.len() != KEYS.len() || KEYS.iter().any(|key| !payload.contains_key(*key)) {
        return Err(invalid_economics_execution("payload keys"));
    }
    validate_economics_authorization_binding(payload, execution)?;
    Ok(EconomicsAuthorizationEvent {
        source_event_id,
        execution_id: execution.execution_id,
        generation: execution.generation,
        decision_digest: economics_authorization_digest(payload, "decisionDigest")?,
        execution_digest: economics_authorization_digest(payload, "executionDigest")?,
        target_request_sha256: economics_authorization_digest(payload, "targetRequestSha256")?,
        expires_at: economics_authorization_expiry(payload)?,
    })
}

fn validate_economics_authorization_binding(
    payload: &serde_json::Map<String, Value>,
    execution: &ApprovedExecution,
) -> Result<(), Failure> {
    if execution.execution_id.is_nil()
        || object_uuid(payload, "executionId")? != execution.execution_id
        || execution.generation != 1
        || payload.get("generation").and_then(Value::as_i64) != Some(execution.generation)
        || payload.get("actionKind").and_then(Value::as_str) != Some(ECONOMICS_ACTION_KIND)
        || payload.get("targetCommand").and_then(Value::as_str) != Some(ECONOMICS_TARGET_COMMAND)
    {
        return Err(invalid_economics_execution("authorization binding"));
    }
    Ok(())
}

fn economics_authorization_digest<'a>(
    payload: &'a serde_json::Map<String, Value>,
    key: &'static str,
) -> Result<&'a str, Failure> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or_else(|| invalid_economics_execution(key))
}

fn economics_authorization_expiry(
    payload: &serde_json::Map<String, Value>,
) -> Result<time::OffsetDateTime, Failure> {
    let value = payload
        .get("expiresAt")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_economics_execution("expiresAt"))?;
    time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339)
        .map_err(|_| invalid_economics_execution("expiresAt"))
}

fn validate_economics_producer_fence(
    producer_job: ProducerJobFence,
    worker_id: &str,
) -> Result<(), Failure> {
    if producer_job.id.is_nil()
        || producer_job.lease_token.is_nil()
        || producer_job.fencing_token < 1
        || producer_job.lease_expires_at.unix_timestamp() <= 0
        || worker_id.is_empty()
        || worker_id != worker_id.trim()
        || worker_id.len() > 160
    {
        return Err(invalid_economics_execution("producer job fence"));
    }
    Ok(())
}

fn economics_owner_database_failure(error: sqlx::Error) -> Failure {
    let sqlstate = match &error {
        sqlx::Error::Database(database) => database.code().map(|value| value.into_owned()),
        _ => None,
    };
    economics_owner_sqlstate_failure(sqlstate.as_deref())
}

fn economics_owner_sqlstate_failure(sqlstate: Option<&str>) -> Failure {
    let detail = sqlstate
        .map(|value| format!("redacted:sqlstate={value}"))
        .unwrap_or_else(|| "redacted:database-unavailable".to_owned());
    match sqlstate {
        Some("40001" | "40P01") => Failure::Retryable("ECONOMICS_DATABASE_UNAVAILABLE", detail),
        Some(value) if value.starts_with("08") => {
            Failure::Retryable("ECONOMICS_DATABASE_UNAVAILABLE", detail)
        }
        Some(_) => Failure::Terminal("ECONOMICS_EXECUTION_REJECTED", detail),
        None => Failure::Retryable("ECONOMICS_DATABASE_UNAVAILABLE", detail),
    }
}

fn invalid_economics_execution(field: &'static str) -> Failure {
    Failure::Terminal("ECONOMICS_EXECUTION_INVALID", field.to_owned())
}

include!("workflow_economics_import_contract.rs");
include!("workflow_economics_import_owner_runtime.rs");

#[cfg(test)]
#[path = "workflow_economics_import_tests.rs"]
mod workflow_economics_import_tests;

#[cfg(test)]
#[path = "workflow_economics_import_contract_tests.rs"]
mod workflow_economics_import_contract_tests;
