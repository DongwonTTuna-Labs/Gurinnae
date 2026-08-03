use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};

fn unexpected_null() -> ServiceError {
    db(sqlx::Error::Decode(Box::new(
        sqlx::error::UnexpectedNullError,
    )))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    CreateSavedView,
    DecideJourneyHandoff,
    DeleteSavedView,
    MarkNotificationRead,
    ReassignTask,
    UpdateSavedView,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    GetInternalDashboard,
    ListInternalNotifications,
    ListMyTasks,
    ListSavedViews,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "createSavedView",
        Handler::Command(CommandHandler::WorkManagement(Command::CreateSavedView)),
    ),
    (
        "decideJourneyHandoff",
        Handler::Command(CommandHandler::WorkManagement(
            Command::DecideJourneyHandoff,
        )),
    ),
    (
        "deleteSavedView",
        Handler::Command(CommandHandler::WorkManagement(Command::DeleteSavedView)),
    ),
    (
        "getInternalDashboard",
        Handler::Query(QueryHandler::WorkManagement(Query::GetInternalDashboard)),
    ),
    (
        "listInternalNotifications",
        Handler::Query(QueryHandler::WorkManagement(
            Query::ListInternalNotifications,
        )),
    ),
    (
        "listMyTasks",
        Handler::Query(QueryHandler::WorkManagement(Query::ListMyTasks)),
    ),
    (
        "listSavedViews",
        Handler::Query(QueryHandler::WorkManagement(Query::ListSavedViews)),
    ),
    (
        "markNotificationRead",
        Handler::Command(CommandHandler::WorkManagement(
            Command::MarkNotificationRead,
        )),
    ),
    (
        "reassignTask",
        Handler::Command(CommandHandler::WorkManagement(Command::ReassignTask)),
    ),
    (
        "updateSavedView",
        Handler::Command(CommandHandler::WorkManagement(Command::UpdateSavedView)),
    ),
];

pub(super) fn command_kind(command: Command) -> CommandKind {
    match command {
        Command::DecideJourneyHandoff => CommandKind::Addendum,
        Command::CreateSavedView
        | Command::DeleteSavedView
        | Command::MarkNotificationRead
        | Command::ReassignTask
        | Command::UpdateSavedView => CommandKind::Base,
    }
}

pub(super) async fn apply(
    command: Command,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::CreateSavedView => create_saved_view(payload, id, actor, transaction).await,
        Command::DecideJourneyHandoff => Err(ServiceError::InvalidRequest),
        Command::DeleteSavedView => delete_saved_view(id, actor, transaction).await,
        Command::MarkNotificationRead => mark_notification_read(payload, transaction).await,
        Command::ReassignTask => reassign_task(payload, id, actor, transaction).await,
        Command::UpdateSavedView => update_saved_view(payload, id, actor, transaction).await,
    }
}

pub(super) async fn query(
    query: Query,
    _operation: &OperationSpec,
    parameters: &BTreeMap<String, String>,
    claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    match query {
        Query::GetInternalDashboard => get_internal_dashboard(claims, pool).await,
        Query::ListInternalNotifications => {
            list_response(list_internal_notifications(claims, pool).await?, parameters)
        }
        Query::ListMyTasks => list_response(list_my_tasks(claims, pool).await?, parameters),
        Query::ListSavedViews => list_response(list_saved_views(claims, pool).await?, parameters),
    }
}

async fn create_saved_view(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if payload.get("isDefault").and_then(Value::as_bool) == Some(true) {
        sqlx::query!(
            "UPDATE ops.saved_views SET is_default=false WHERE user_id=$1 AND surface=$2",
            actor,
            string_value(payload, "surface").ok_or(ServiceError::InvalidRequest)?,
        )
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    }
    sqlx::query!(
        "INSERT INTO ops.saved_views(id,user_id,name,surface,query,is_default) \
         VALUES($1,$2,$3,$4,$5,$6)",
        id,
        actor,
        string_value(payload, "name").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "surface").ok_or(ServiceError::InvalidRequest)?,
        payload
            .get("query")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
        payload
            .get("isDefault")
            .and_then(Value::as_bool)
            .ok_or(ServiceError::InvalidRequest)?,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn update_saved_view(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let target = uuid_value(payload, &["savedViewId", "id"]).unwrap_or(id);
    if payload.get("isDefault").and_then(Value::as_bool) == Some(true) {
        let surface: String = sqlx::query_scalar!(
            "SELECT surface FROM ops.saved_views WHERE id=$1 AND user_id=$2",
            target,
            actor,
        )
        .fetch_optional(&mut **tx)
        .await
        .map_err(db)?
        .ok_or(ServiceError::NotFound)?;
        sqlx::query!("UPDATE ops.saved_views SET is_default=false WHERE user_id=$1 AND surface=$2 AND id<>$3", actor, surface, target).execute(&mut **tx).await.map_err(db)?;
    }
    let changed = sqlx::query!(
        "UPDATE ops.saved_views SET name=COALESCE($3,name),query=COALESCE($4,query), \
         is_default=COALESCE($5,is_default) WHERE id=$1 AND user_id=$2",
        target,
        actor,
        payload.get("name").and_then(Value::as_str),
        payload.get("query").cloned(),
        payload.get("isDefault").and_then(Value::as_bool),
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

async fn delete_saved_view(
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let changed = sqlx::query!(
        "DELETE FROM ops.saved_views WHERE id=$1 AND user_id=$2",
        id,
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

async fn reassign_task(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let assignee = uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query!(
        "UPDATE ops.tasks SET assignee_user_id=$2,assigned_by=$3, \
         assignment_reason='reassigned by control command' WHERE id=$1",
        id,
        assignee,
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

async fn mark_notification_read(
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if let Some(target) = uuid_value(payload, &["notificationId", "id"]) {
        sqlx::query!(
            "UPDATE ops.notifications SET read_at=COALESCE(read_at,clock_timestamp()) WHERE id=$1",
            target,
        )
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    }

    Ok(())
}

async fn get_internal_dashboard(
    claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let actor = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
    let counts: Value = sqlx::query_scalar!(
        "SELECT jsonb_build_object( \
         'incidents',(SELECT count(*) FROM ops.source_incidents WHERE status='OPEN'), \
         'myTasks',(SELECT count(*) FROM ops.tasks WHERE assignee_user_id=$1 AND status<>'DONE'), \
         'overdueTasks',(SELECT count(*) FROM ops.tasks WHERE due_at<clock_timestamp() AND status<>'DONE'), \
         'reviewQueue',(SELECT count(*) FROM editorial.review_assignments WHERE status IN ('ASSIGNED','IN_PROGRESS')), \
         'failedJobs',(SELECT count(*) FROM ops.jobs WHERE status IN ('FAILED','DEAD_LETTER')), \
         'unreadNotifications',(SELECT count(*) FROM ops.notifications WHERE user_id=$1 AND read_at IS NULL))",
        actor,
    )
    .fetch_one(pool)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    Ok(json!({
        "incidents":counts.get("incidents").cloned().unwrap_or(json!(0)),
        "myTasks":counts.get("myTasks").cloned().unwrap_or(json!(0)),
        "overdueTasks":counts.get("overdueTasks").cloned().unwrap_or(json!(0)),
        "reviewQueue":counts.get("reviewQueue").cloned().unwrap_or(json!(0)),
        "sourceHealth":[],
        "jobHealth":counts.get("failedJobs").cloned().unwrap_or(json!(0)),
        "budget":{},
        "notifications":counts.get("unreadNotifications").cloned().unwrap_or(json!(0))
    }))
}

async fn list_internal_notifications(
    claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items: Value = {
        let actor = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
        sqlx::query_scalar!("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'notificationType',notification_type,'title',title,'body',body,'readAt',read_at,'version',version,'createdAt',created_at) ORDER BY created_at DESC),'[]'::jsonb) FROM ops.notifications WHERE user_id=$1", actor).fetch_one(pool).await.map_err(db)?.ok_or_else(unexpected_null)?
    };
    Ok(items)
}

async fn list_my_tasks(claims: &ActorClaims, pool: &PgPool) -> Result<Value, ServiceError> {
    let items: Value = {
        let actor = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
        sqlx::query_scalar!("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'taskType',task_type,'objectType',object_type,'objectId',object_id,'title',title,'status',status,'priority',priority,'dueAt',due_at,'blockerCode',blocker_code,'version',version) ORDER BY due_at NULLS LAST,created_at),'[]'::jsonb) FROM ops.tasks WHERE assignee_user_id=$1", actor).fetch_one(pool).await.map_err(db)?.ok_or_else(unexpected_null)?
    };
    Ok(items)
}

async fn list_saved_views(claims: &ActorClaims, pool: &PgPool) -> Result<Value, ServiceError> {
    let items: Value = {
        let actor = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
        sqlx::query_scalar!("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'name',name,'surface',surface,'query',query,'isDefault',is_default,'version',version,'createdAt',created_at,'updatedAt',updated_at) ORDER BY updated_at DESC),'[]'::jsonb) FROM ops.saved_views WHERE user_id=$1", actor).fetch_one(pool).await.map_err(db)?.ok_or_else(unexpected_null)?
    };
    Ok(items)
}

fn list_response(
    items: Value,
    parameters: &BTreeMap<String, String>,
) -> Result<Value, ServiceError> {
    Ok(json!({"items":items,"appliedFilters":parameters,
        "asOf":format_time(OffsetDateTime::now_utc())?}))
}
