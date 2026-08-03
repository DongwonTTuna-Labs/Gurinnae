use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};

mod provider_models;

fn unexpected_null() -> ServiceError {
    db(sqlx::Error::Decode(Box::new(
        sqlx::error::UnexpectedNullError,
    )))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    CancelJob,
    DisableProviderRouting,
    PauseJobQueue,
    QuarantineJob,
    RetryJob,
    RetryJobs,
    SetModelAutoUpgrade,
    TestProviderConnection,
    UpgradeProviderModel,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    GetJob,
    GetOperationsOverview,
    ListJobs,
    ListProviders,
    ListRelayModels,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "cancelJob",
        Handler::Command(CommandHandler::Operations(Command::CancelJob)),
    ),
    (
        "disableProviderRouting",
        Handler::Command(CommandHandler::Operations(Command::DisableProviderRouting)),
    ),
    (
        "getJob",
        Handler::Query(QueryHandler::Operations(Query::GetJob)),
    ),
    (
        "getOperationsOverview",
        Handler::Query(QueryHandler::Operations(Query::GetOperationsOverview)),
    ),
    (
        "listJobs",
        Handler::Query(QueryHandler::Operations(Query::ListJobs)),
    ),
    (
        "listProviders",
        Handler::Query(QueryHandler::Operations(Query::ListProviders)),
    ),
    (
        "listRelayModels",
        Handler::Query(QueryHandler::Operations(Query::ListRelayModels)),
    ),
    (
        "pauseJobQueue",
        Handler::Command(CommandHandler::Operations(Command::PauseJobQueue)),
    ),
    (
        "quarantineJob",
        Handler::Command(CommandHandler::Operations(Command::QuarantineJob)),
    ),
    (
        "retryJob",
        Handler::Command(CommandHandler::Operations(Command::RetryJob)),
    ),
    (
        "retryJobs",
        Handler::Command(CommandHandler::Operations(Command::RetryJobs)),
    ),
    (
        "setModelAutoUpgrade",
        Handler::Command(CommandHandler::Operations(Command::SetModelAutoUpgrade)),
    ),
    (
        "testProviderConnection",
        Handler::Command(CommandHandler::Operations(Command::TestProviderConnection)),
    ),
    (
        "upgradeProviderModel",
        Handler::Command(CommandHandler::Operations(Command::UpgradeProviderModel)),
    ),
];

pub(super) const fn command_kind(_command: Command) -> CommandKind {
    CommandKind::Base
}

pub(super) async fn apply(
    command: Command,
    operation: &str,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<Map<String, Value>, ServiceError> {
    if direct_provider_control_command(command) {
        return Err(ServiceError::ProposalRequired);
    }
    match command {
        Command::CancelJob | Command::QuarantineJob => {
            no_effect(arm_canceljob_quarantinejob(operation, payload, tx).await)
        }
        Command::DisableProviderRouting
        | Command::SetModelAutoUpgrade
        | Command::TestProviderConnection
        | Command::UpgradeProviderModel => Err(ServiceError::ProposalRequired),
        Command::PauseJobQueue => no_effect(arm_pausejobqueue(payload, actor, tx).await),
        Command::RetryJob => no_effect(arm_retryjob(payload, tx).await),
        Command::RetryJobs => no_effect(arm_retryjobs(payload, actor, tx).await),
    }
}

fn direct_provider_control_command(command: Command) -> bool {
    matches!(
        command,
        Command::DisableProviderRouting
            | Command::SetModelAutoUpgrade
            | Command::TestProviderConnection
            | Command::UpgradeProviderModel
    )
}

pub(super) async fn query(
    query: Query,
    _operation: &OperationSpec,
    parameters: &BTreeMap<String, String>,
    _claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    match query {
        Query::GetJob => job_query(parameters, pool).await,
        Query::GetOperationsOverview => operations_query(pool).await,
        Query::ListJobs => list_jobs_query(parameters, pool).await,
        Query::ListProviders => list_providers_query(parameters, pool).await,
        Query::ListRelayModels => provider_models::list_relay_models(pool).await,
    }
}

fn no_effect(result: Result<(), ServiceError>) -> Result<Map<String, Value>, ServiceError> {
    result?;
    Ok(Map::new())
}

async fn arm_canceljob_quarantinejob(
    operation: &str,
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if let Some(job) = uuid_value(payload, &["jobId", "id"]) {
        let status = if operation == "cancelJob" {
            "CANCELLED"
        } else {
            "QUARANTINED"
        };
        sqlx::query!("UPDATE ops.jobs SET status=$2::ops.job_status,lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,run_after=CASE WHEN $2='QUEUED' THEN clock_timestamp() ELSE run_after END WHERE id=$1", job, status as _).execute(&mut **tx).await.map_err(db)?;
    }

    Ok(())
}

async fn arm_pausejobqueue(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let state = match string_value(payload, "mode") {
        Some("PAUSE_NEW") => "PAUSED_NEW",
        Some("PAUSE_AND_DRAIN") => "DRAINING",
        _ => return Err(ServiceError::InvalidRequest),
    };
    let queue = string_value(payload, "queueName").ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query!(
        "UPDATE ops.queue_controls SET state=$2,reason=$3,changed_by=$4, \
         changed_at=clock_timestamp() WHERE queue_name=$1",
        queue,
        state,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

async fn arm_retryjob(
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let job = uuid_value(payload, &["jobId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query!(
        "UPDATE ops.jobs SET status='QUEUED',run_after=clock_timestamp(),lease_owner=NULL, \
         lease_token=NULL,lease_expires_at=NULL,last_error_code=NULL,last_error_detail=$2, \
         completed_at=NULL WHERE id=$1 AND status IN ('FAILED','DEAD_LETTER')",
        job,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }

    Ok(())
}

async fn arm_retryjobs(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let max_count = payload
        .get("maxCount")
        .and_then(Value::as_i64)
        .filter(|value| (1..=1000).contains(value))
        .ok_or(ServiceError::InvalidRequest)?;
    let selected = if payload.contains_key("jobIds") {
        uuid_array(payload, "jobIds")?
    } else if let Some(snapshot) = uuid_value(payload, &["querySnapshotId"]) {
        sqlx::query_scalar!(
            "SELECT selected_job_ids FROM ops.job_query_snapshots \
             WHERE id=$1 AND actor_user_id=$2 AND expires_at>clock_timestamp()",
            snapshot,
            actor,
        )
        .fetch_optional(&mut **tx)
        .await
        .map_err(db)?
        .ok_or(ServiceError::NotFound)?
    } else {
        return Err(ServiceError::InvalidRequest);
    };
    if selected.is_empty() || selected.len() as i64 > max_count {
        return Err(ServiceError::InvalidRequest);
    }
    let rows = sqlx::query!(
        "UPDATE ops.jobs SET status='QUEUED',run_after=clock_timestamp(),lease_owner=NULL, \
         lease_token=NULL,lease_expires_at=NULL,last_error_code=NULL,last_error_detail=$2, \
         completed_at=NULL,version=version+1 \
         WHERE id=ANY($1::uuid[]) AND status IN ('FAILED','DEAD_LETTER')",
        &selected,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if rows != selected.len() as u64 {
        return Err(ServiceError::VersionConflict);
    }

    Ok(())
}

async fn job_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "jobId")?;
    let row: Value = sqlx::query_scalar!(
        "SELECT jsonb_build_object('id',id,'jobType',job_type,'queue',queue,'status',status::text, \
         'priority',priority,'payload',payload,'runAfter',run_after,'leaseOwner',lease_owner, \
         'leaseExpiresAt',lease_expires_at,'fencingToken',fencing_token,'attemptCount',attempt_count, \
         'maxAttempts',max_attempts,'lastErrorCode',last_error_code,'lastErrorDetail',last_error_detail, \
         'version',version,'createdAt',created_at,'updatedAt',updated_at,'completedAt',completed_at) \
         FROM ops.jobs WHERE id=$1",
        id,
    )
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?
    .ok_or_else(unexpected_null)?;
    Ok(envelope(id, value_status(&row), row))
}

async fn operations_query(pool: &PgPool) -> Result<Value, ServiceError> {
    let queues: Value = sqlx::query_scalar!(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('queueName',q.queue, \
         'queued',q.queued,'running',q.running,'failed',q.failed)),'[]'::jsonb) FROM ( \
         SELECT queue,count(*) FILTER (WHERE status='QUEUED') queued, \
         count(*) FILTER (WHERE status IN ('LEASED','RUNNING')) running, \
         count(*) FILTER (WHERE status IN ('FAILED','DEAD_LETTER')) failed \
         FROM ops.jobs GROUP BY queue ORDER BY queue) q",
    )
    .fetch_one(pool)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    let sources: Value = sqlx::query_scalar!(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('sourceId',source_id,'enabled',enabled, \
         'legalStatus',legal_status) ORDER BY source_id),'[]'::jsonb) FROM ops.source_registry",
    )
    .fetch_one(pool)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    let incidents: Value = sqlx::query_scalar!(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'sourceId',source_id, \
         'severity',severity::text,'type',incident_type,'summary',summary,'status',status) \
         ORDER BY created_at DESC),'[]'::jsonb) FROM ops.source_incidents WHERE status<>'RESOLVED'",
    )
    .fetch_one(pool)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    Ok(
        json!({"systemStatus":"OPERATIONAL","services":[],"queues":queues,
        "sources":sources,"incidents":incidents,"telemetryGaps":[],"recentActions":[]}),
    )
}

async fn list_jobs_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items: Value = sqlx::query_scalar!("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'jobType',job_type,'queue',queue,'status',status::text,'priority',priority,'attemptCount',attempt_count,'maxAttempts',max_attempts,'version',version,'runAfter',run_after,'updatedAt',updated_at) ORDER BY created_at DESC),'[]'::jsonb) FROM ops.jobs").fetch_one(pool).await.map_err(db)?.ok_or_else(unexpected_null)?;
    list_response(items, parameters)
}

async fn list_providers_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items: Value = sqlx::query_scalar!("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'providerType',provider_type,'name',name,'enabled',enabled,'routingPolicy',routing_policy,'dataRetentionPolicy',data_retention_policy,'lastConnectionTestAt',last_connection_test_at,'lastConnectionTestStatus',last_connection_test_status,'version',version) ORDER BY name),'[]'::jsonb) FROM ops.provider_configs").fetch_one(pool).await.map_err(db)?.ok_or_else(unexpected_null)?;
    list_response(items, parameters)
}

fn list_response(
    items: Value,
    parameters: &BTreeMap<String, String>,
) -> Result<Value, ServiceError> {
    let response = json!({"items":items,"appliedFilters":parameters,
        "asOf":format_time(OffsetDateTime::now_utc())?});
    Ok(response)
}

#[cfg(test)]
mod proposal_fence_tests {
    use super::*;

    #[test]
    fn only_provider_control_commands_are_fenced_to_proposals() {
        for command in [
            Command::DisableProviderRouting,
            Command::SetModelAutoUpgrade,
            Command::TestProviderConnection,
            Command::UpgradeProviderModel,
        ] {
            assert!(direct_provider_control_command(command));
        }
        for command in [
            Command::CancelJob,
            Command::RetryJob,
            Command::PauseJobQueue,
        ] {
            assert!(!direct_provider_control_command(command));
        }
    }
}
