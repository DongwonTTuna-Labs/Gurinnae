use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    AssignCase,
    TransitionCase,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    GetCaseWorkspaceOverview,
    GetInternalCase,
    ListCaseTimeline,
    ListInternalCases,
    SearchInternalRecords,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "assignCase",
        Handler::Command(CommandHandler::Cases(Command::AssignCase)),
    ),
    (
        "getCaseWorkspaceOverview",
        Handler::Query(QueryHandler::Cases(Query::GetCaseWorkspaceOverview)),
    ),
    (
        "getInternalCase",
        Handler::Query(QueryHandler::Cases(Query::GetInternalCase)),
    ),
    (
        "listCaseTimeline",
        Handler::Query(QueryHandler::Cases(Query::ListCaseTimeline)),
    ),
    (
        "listInternalCases",
        Handler::Query(QueryHandler::Cases(Query::ListInternalCases)),
    ),
    (
        "searchInternalRecords",
        Handler::Query(QueryHandler::Cases(Query::SearchInternalRecords)),
    ),
    (
        "transitionCase",
        Handler::Command(CommandHandler::Cases(Command::TransitionCase)),
    ),
];

pub(super) const fn command_kind(_command: Command) -> CommandKind {
    CommandKind::Base
}

pub(super) async fn apply(
    command: Command,
    payload: &Map<String, Value>,
    actor: Uuid,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::AssignCase => assign_case(payload, actor, transaction).await,
        Command::TransitionCase => transition_case(payload, transaction).await,
    }
}

pub(super) async fn query(
    query: Query,
    _operation: &OperationSpec,
    parameters: &BTreeMap<String, String>,
    _claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    match query {
        Query::GetCaseWorkspaceOverview => {
            case_query("getCaseWorkspaceOverview", parameters, pool).await
        }
        Query::GetInternalCase => case_query("getInternalCase", parameters, pool).await,
        Query::ListCaseTimeline => list_case_timeline(parameters, pool).await,
        Query::ListInternalCases => list_internal_cases(parameters, pool).await,
        Query::SearchInternalRecords => search_internal_records(parameters, pool).await,
    }
}

async fn assign_case(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let assignee = uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query("UPDATE editorial.cases SET lead_investigator_id=$2 WHERE id=$1")
        .bind(case_id)
        .bind(assignee)
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    upsert_task(
        tx,
        "CASE",
        case_id,
        "Case investigation",
        "OPEN",
        "HIGH",
        Some(assignee),
        actor,
        payload.get("reason").and_then(Value::as_str),
    )
    .await?;

    Ok(())
}

async fn transition_case(
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let target = string_value(payload, "targetState").ok_or(ServiceError::InvalidRequest)?;
    let current: String =
        sqlx::query_scalar("SELECT investigation_state::text FROM editorial.cases WHERE id=$1")
            .bind(case_id)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?;
    if !valid_case_transition(&current, target) {
        return Err(ServiceError::InvalidStateTransition);
    }
    sqlx::query(
        "UPDATE editorial.cases SET investigation_state=$2::editorial.investigation_state \
         WHERE id=$1",
    )
    .bind(case_id)
    .bind(target)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn list_case_timeline(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let case_id = query_uuid(parameters, "caseId")?;
    let items = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'occurredAt',occurred_at,'action',action,'actorId',actor_id,'outcome',outcome::text,'reason',reason,'details',details) ORDER BY occurred_at DESC),'[]'::jsonb) FROM ops.audit_events WHERE object_id=$1::text").bind(case_id.to_string()).fetch_one(pool).await.map_err(db)?;
    list_response(items, parameters)
}

async fn list_internal_cases(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'slug',public_slug,'title',title,'investigationState',investigation_state::text,'publicationState',publication_state::text,'priority',priority,'leadInvestigatorId',lead_investigator_id,'version',version,'updatedAt',updated_at) ORDER BY updated_at DESC),'[]'::jsonb) FROM editorial.cases").fetch_one(pool).await.map_err(db)?;
    list_response(items, parameters)
}

async fn search_internal_records(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let query = parameters
        .get("q")
        .filter(|value| !value.trim().is_empty())
        .ok_or(ServiceError::InvalidRequest)?;
    let pattern = format!("%{}%", query.replace('%', "\\%").replace('_', "\\_"));
    let items = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(item),'[]'::jsonb) FROM (SELECT jsonb_build_object('resultType','CASE','id',id,'title',title,'summary',summary) item,updated_at sort_at FROM editorial.cases WHERE title ILIKE $1 ESCAPE '\\' OR summary ILIKE $1 ESCAPE '\\' UNION ALL SELECT jsonb_build_object('resultType','EVIDENCE','id',id,'title',title,'summary',description),updated_at FROM editorial.evidence WHERE title ILIKE $1 ESCAPE '\\' OR description ILIKE $1 ESCAPE '\\' ORDER BY sort_at DESC LIMIT 100) results").bind(pattern).fetch_one(pool).await.map_err(db)?;
    list_response(items, parameters)
}

fn list_response(
    items: Value,
    parameters: &BTreeMap<String, String>,
) -> Result<Value, ServiceError> {
    Ok(json!({"items":items,"appliedFilters":parameters,
        "asOf":format_time(OffsetDateTime::now_utc())?}))
}
