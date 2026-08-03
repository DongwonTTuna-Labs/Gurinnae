use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    AcknowledgeSourceIncident,
    ApproveSchemaMapping,
    PauseBackfill,
    PauseSource,
    RejectSchemaMapping,
    RetrySourceRun,
    StartBackfill,
    StartSourceRun,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    DownloadSourceRunReport,
    EstimateBackfill,
    GetInternalSource,
    GetSchemaDrift,
    GetSourceRun,
    ListInternalSources,
    ListSourceRuns,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "acknowledgeSourceIncident",
        Handler::Command(CommandHandler::Sources(Command::AcknowledgeSourceIncident)),
    ),
    (
        "approveSchemaMapping",
        Handler::Command(CommandHandler::Sources(Command::ApproveSchemaMapping)),
    ),
    (
        "downloadSourceRunReport",
        Handler::Query(QueryHandler::Sources(Query::DownloadSourceRunReport)),
    ),
    (
        "estimateBackfill",
        Handler::Query(QueryHandler::Sources(Query::EstimateBackfill)),
    ),
    (
        "getInternalSource",
        Handler::Query(QueryHandler::Sources(Query::GetInternalSource)),
    ),
    (
        "getSchemaDrift",
        Handler::Query(QueryHandler::Sources(Query::GetSchemaDrift)),
    ),
    (
        "getSourceRun",
        Handler::Query(QueryHandler::Sources(Query::GetSourceRun)),
    ),
    (
        "listInternalSources",
        Handler::Query(QueryHandler::Sources(Query::ListInternalSources)),
    ),
    (
        "listSourceRuns",
        Handler::Query(QueryHandler::Sources(Query::ListSourceRuns)),
    ),
    (
        "pauseBackfill",
        Handler::Command(CommandHandler::Sources(Command::PauseBackfill)),
    ),
    (
        "pauseSource",
        Handler::Command(CommandHandler::Sources(Command::PauseSource)),
    ),
    (
        "rejectSchemaMapping",
        Handler::Command(CommandHandler::Sources(Command::RejectSchemaMapping)),
    ),
    (
        "retrySourceRun",
        Handler::Command(CommandHandler::Sources(Command::RetrySourceRun)),
    ),
    (
        "startBackfill",
        Handler::Command(CommandHandler::Sources(Command::StartBackfill)),
    ),
    (
        "startSourceRun",
        Handler::Command(CommandHandler::Sources(Command::StartSourceRun)),
    ),
];

pub(super) const fn command_kind(_command: Command) -> CommandKind {
    CommandKind::Base
}

pub(super) async fn apply(
    command: Command,
    operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::AcknowledgeSourceIncident => acknowledge_source_incident(payload, actor, tx).await,
        Command::ApproveSchemaMapping | Command::RejectSchemaMapping => {
            apply_schema_mapping(operation, payload, actor, tx).await
        }
        Command::PauseBackfill => pause_backfill(payload, tx).await,
        Command::PauseSource => pause_source(payload, tx).await,
        Command::RetrySourceRun => retry_source_run(payload, actor, tx).await,
        Command::StartBackfill => start_backfill(payload, id, actor, tx).await,
        Command::StartSourceRun => start_source_run(payload, id, actor, tx).await,
    }
}

async fn apply_schema_mapping(
    operation: &str,
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    decide_schema_mapping(operation, payload, actor, tx).await?;

    Ok(())
}

async fn acknowledge_source_incident(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let source = string_value(payload, "sourceId").ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE ops.source_incidents SET status='ACKNOWLEDGED',acknowledged_by=$2, \
         acknowledged_at=clock_timestamp() WHERE source_id=$1 AND status='OPEN'",
    )
    .bind(source)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

async fn pause_backfill(
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let run = uuid_value(payload, &["backfillRunId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query(
        "UPDATE ops.source_runs SET status='PAUSED',request_reason=$2 \
         WHERE id=$1 AND mode IN ('BACKFILL','DRY_RUN') AND status='RUNNING'",
    )
    .bind(run)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }

    Ok(())
}

async fn pause_source(
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let source = string_value(payload, "sourceId").ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query("UPDATE ops.source_registry SET enabled=false WHERE source_id=$1")
        .bind(source)
        .execute(&mut **tx)
        .await
        .map_err(db)?
        .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

async fn retry_source_run(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let source_run = uuid_value(payload, &["sourceRunId"]).ok_or(ServiceError::InvalidRequest)?;
    let row = sqlx::query(
        "SELECT source_id,mode,checkpoint_before FROM ops.source_runs \
         WHERE id=$1 AND status IN ('FAILED','CANCELLED')",
    )
    .bind(source_run)
    .fetch_optional(&mut **tx)
    .await
    .map_err(db)?
    .ok_or(ServiceError::VersionConflict)?;
    sqlx::query(
        "INSERT INTO ops.source_runs(id,source_id,mode,checkpoint_before,status, \
         retry_of_source_run_id,request_reason,requested_by) \
         VALUES($1,$2,$3,$4,'QUEUED',$5,$6,$7)",
    )
    .bind(Uuid::new_v4())
    .bind(row.try_get::<String, _>("source_id").map_err(db)?)
    .bind(row.try_get::<String, _>("mode").map_err(db)?)
    .bind(
        row.try_get::<Option<Value>, _>("checkpoint_before")
            .map_err(db)?,
    )
    .bind(source_run)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn start_backfill(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let source = string_value(payload, "sourceId").ok_or(ServiceError::InvalidRequest)?;
    let from = date_value(payload, "from")?;
    let to = date_value(payload, "to")?;
    if from > to {
        return Err(ServiceError::InvalidRequest);
    }
    let mode = match string_value(payload, "mode") {
        Some("dry_run") => "DRY_RUN",
        Some("execute") => "BACKFILL",
        _ => return Err(ServiceError::InvalidRequest),
    };
    let allowed: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM ops.source_registry \
         WHERE source_id=$1 AND enabled AND legal_status='APPROVED')",
    )
    .bind(source)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if !allowed {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query(
        "INSERT INTO ops.source_runs(id,source_id,mode,status,requested_from,requested_to, \
         request_reason,requested_by) VALUES($1,$2,$3,'QUEUED',$4,$5,$6,$7)",
    )
    .bind(id)
    .bind(source)
    .bind(mode)
    .bind(from)
    .bind(to)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    enqueue_runtime_job(
        tx,
        "SOURCE_RUN",
        "ingest-worker",
        json!({"sourceRunId":id}),
        format!("source-run:{id}"),
    )
    .await?;

    Ok(())
}

async fn start_source_run(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let source = string_value(payload, "sourceId").ok_or(ServiceError::InvalidRequest)?;
    let mode = match string_value(payload, "mode") {
        Some("incremental") => "INCREMENTAL",
        Some("reconcile") => "RECONCILE",
        Some("full") => "FULL",
        _ => return Err(ServiceError::InvalidRequest),
    };
    let allowed: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM ops.source_registry \
         WHERE source_id=$1 AND enabled AND legal_status='APPROVED')",
    )
    .bind(source)
    .fetch_one(&mut **tx)
    .await
    .map_err(db)?;
    if !allowed {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query(
        "INSERT INTO ops.source_runs(id,source_id,mode,status,request_reason,requested_by) \
         VALUES($1,$2,$3,'QUEUED',$4,$5)",
    )
    .bind(id)
    .bind(source)
    .bind(mode)
    .bind(payload.get("reason").and_then(Value::as_str))
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    enqueue_runtime_job(
        tx,
        "SOURCE_RUN",
        "ingest-worker",
        json!({"sourceRunId":id}),
        format!("source-run:{id}"),
    )
    .await?;

    Ok(())
}

pub(super) async fn query(
    query: Query,
    _operation: &OperationSpec,
    parameters: &BTreeMap<String, String>,
    _claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    match query {
        Query::DownloadSourceRunReport => source_run_download(parameters, pool).await,
        Query::EstimateBackfill => estimate_backfill_query(parameters, pool).await,
        Query::GetInternalSource => source_query(parameters, pool).await,
        Query::GetSchemaDrift => schema_drift_query(parameters, pool).await,
        Query::GetSourceRun => source_run_query(parameters, pool).await,
        Query::ListInternalSources => list_internal_sources(parameters, pool).await,
        Query::ListSourceRuns => list_source_runs(parameters, pool).await,
    }
}

async fn list_internal_sources(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items: Value = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('sourceId',source_id,'displayName',display_name,'connectorType',connector_type,'ownerTeam',owner_team,'enabled',enabled,'legalStatus',legal_status,'version',version,'updatedAt',updated_at) ORDER BY source_id),'[]'::jsonb) FROM ops.source_registry").fetch_one(pool).await.map_err(db)?;
    Ok(json!({"items":items,"appliedFilters":parameters,
        "asOf":format_time(OffsetDateTime::now_utc())?}))
}

async fn list_source_runs(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let source = parameters
        .get("sourceId")
        .ok_or(ServiceError::InvalidRequest)?;
    let items: Value = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'sourceId',source_id,'mode',mode,'status',status,'recordsSeen',records_seen,'recordsChanged',records_changed,'version',version,'startedAt',started_at,'completedAt',completed_at) ORDER BY created_at DESC),'[]'::jsonb) FROM ops.source_runs WHERE source_id=$1").bind(source).fetch_one(pool).await.map_err(db)?;
    Ok(json!({"items":items,"appliedFilters":parameters,
        "asOf":format_time(OffsetDateTime::now_utc())?}))
}
