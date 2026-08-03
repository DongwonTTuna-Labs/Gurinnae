use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};

fn unexpected_null() -> ServiceError {
    db(sqlx::Error::Decode(Box::new(
        sqlx::error::UnexpectedNullError,
    )))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    CreateAccessRequest,
    DisableUser,
    GrantRole,
    InviteUser,
    PlaceTemporaryRestriction,
    ProposeRoleDefinitionChange,
    RevokeOwnSession,
    RevokeRole,
    RevokeUserSessions,
    StartAccessReview,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    GetCurrentAccount,
    GetCurrentUserCapabilities,
    GetUserAccessDetail,
    ListRoleDefinitions,
    ListUsers,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "createAccessRequest",
        Handler::Command(CommandHandler::IdentityGovernance(
            Command::CreateAccessRequest,
        )),
    ),
    (
        "disableUser",
        Handler::Command(CommandHandler::IdentityGovernance(Command::DisableUser)),
    ),
    (
        "getCurrentAccount",
        Handler::Query(QueryHandler::IdentityGovernance(Query::GetCurrentAccount)),
    ),
    (
        "getCurrentUserCapabilities",
        Handler::Query(QueryHandler::IdentityGovernance(
            Query::GetCurrentUserCapabilities,
        )),
    ),
    (
        "getUserAccessDetail",
        Handler::Query(QueryHandler::IdentityGovernance(Query::GetUserAccessDetail)),
    ),
    (
        "grantRole",
        Handler::Command(CommandHandler::IdentityGovernance(Command::GrantRole)),
    ),
    (
        "inviteUser",
        Handler::Command(CommandHandler::IdentityGovernance(Command::InviteUser)),
    ),
    (
        "listRoleDefinitions",
        Handler::Query(QueryHandler::IdentityGovernance(Query::ListRoleDefinitions)),
    ),
    (
        "listUsers",
        Handler::Query(QueryHandler::IdentityGovernance(Query::ListUsers)),
    ),
    (
        "placeTemporaryRestriction",
        Handler::Command(CommandHandler::IdentityGovernance(
            Command::PlaceTemporaryRestriction,
        )),
    ),
    (
        "proposeRoleDefinitionChange",
        Handler::Command(CommandHandler::IdentityGovernance(
            Command::ProposeRoleDefinitionChange,
        )),
    ),
    (
        "revokeOwnSession",
        Handler::Command(CommandHandler::IdentityGovernance(
            Command::RevokeOwnSession,
        )),
    ),
    (
        "revokeRole",
        Handler::Command(CommandHandler::IdentityGovernance(Command::RevokeRole)),
    ),
    (
        "revokeUserSessions",
        Handler::Command(CommandHandler::IdentityGovernance(
            Command::RevokeUserSessions,
        )),
    ),
    (
        "startAccessReview",
        Handler::Command(CommandHandler::IdentityGovernance(
            Command::StartAccessReview,
        )),
    ),
];

pub(super) fn command_kind(_command: Command) -> CommandKind {
    CommandKind::Base
}

pub(super) async fn apply(
    command: Command,
    _operation: &str,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    session_id: Uuid,
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::CreateAccessRequest => {
            create_access_request(payload, id, actor, transaction).await
        }
        Command::DisableUser => disable_user(id, transaction).await,
        Command::GrantRole => grant_role(payload, actor, transaction).await,
        Command::InviteUser => invite_user(payload, id, actor, transaction).await,
        Command::PlaceTemporaryRestriction => {
            place_temporary_restriction(payload, id, actor, transaction).await
        }
        Command::ProposeRoleDefinitionChange => {
            propose_role_definition_change(payload, id, actor, transaction).await
        }
        Command::RevokeOwnSession => revoke_own_session(actor, session_id, transaction).await,
        Command::RevokeRole => revoke_role(payload, actor, transaction).await,
        Command::RevokeUserSessions => revoke_user_sessions(payload, transaction).await,
        Command::StartAccessReview => start_access_review(payload, id, actor, transaction).await,
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
        Query::GetCurrentAccount => current_account(claims, pool).await,
        Query::GetCurrentUserCapabilities => Ok(json!({
            "id":claims.sub,"status":"ACTIVE","data":{"capabilities":claims.capabilities,
            "rolesVersion":claims.roles_version},"links":[]
        })),
        Query::GetUserAccessDetail => user_access_detail(parameters, pool).await,
        Query::ListRoleDefinitions => list_role_definitions(parameters, pool).await,
        Query::ListUsers => list_users(parameters, pool).await,
    }
}

async fn create_access_request(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    sqlx::query!(
        "INSERT INTO ops.access_requests(id,requester_user_id,requested_role_codes,reason, \
         requested_until,status) VALUES($1,$2,$3,$4,$5,'PENDING')",
        id,
        actor,
        payload
            .get("requestedRoleCodes")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        timestamp_value(payload, "requestedUntil")?,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn disable_user(id: Uuid, tx: &mut Transaction<'_, Postgres>) -> Result<(), ServiceError> {
    let changed = sqlx::query!("UPDATE ops.users SET status='DISABLED' WHERE id=$1", id)
        .execute(&mut **tx)
        .await
        .map_err(db)?
        .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    sqlx::query!(
        "UPDATE ops.sessions SET revoked_at=COALESCE(revoked_at,clock_timestamp()) \
         WHERE user_id=$1 AND revoked_at IS NULL",
        id,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn grant_role(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let user = uuid_value(payload, &["userId"]).ok_or(ServiceError::InvalidRequest)?;
    let role = uuid_value(payload, &["roleId"]).ok_or(ServiceError::InvalidRequest)?;
    let role_exists: bool =
        sqlx::query_scalar!("SELECT EXISTS(SELECT 1 FROM ops.roles WHERE id=$1)", role)
            .fetch_one(&mut **tx)
            .await
            .map_err(db)?
            .ok_or_else(unexpected_null)?;
    if !role_exists {
        return Err(ServiceError::NotFound);
    }
    sqlx::query!(
        "INSERT INTO ops.user_roles(user_id,role_id,granted_by,reason,expires_at) \
         VALUES($1,$2,$3,$4,$5)",
        user,
        role,
        actor,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        timestamp_value(payload, "expiresAt")?,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn invite_user(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let email = string_value(payload, "email").ok_or(ServiceError::InvalidRequest)?;
    let display = string_value(payload, "displayName").ok_or(ServiceError::InvalidRequest)?;
    let oidc_subject = format!("invited:{}", sha256(email.to_ascii_lowercase().as_bytes()));
    sqlx::query!(
        "INSERT INTO ops.users(id,oidc_subject,email,display_name,status) \
         VALUES($1,$2,$3,$4,'INVITED')",
        id,
        oidc_subject,
        email as _,
        display,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    for role in uuid_array(payload, "roleIds")? {
        let exists: bool =
            sqlx::query_scalar!("SELECT EXISTS(SELECT 1 FROM ops.roles WHERE id=$1)", role)
                .fetch_one(&mut **tx)
                .await
                .map_err(db)?
                .ok_or_else(unexpected_null)?;
        if !exists {
            return Err(ServiceError::NotFound);
        }
        sqlx::query!(
            "INSERT INTO ops.user_roles(user_id,role_id,granted_by,reason,expires_at) \
             VALUES($1,$2,$3,'initial invitation grant',$4)",
            id,
            role,
            actor,
            timestamp_value(payload, "expiresAt")?,
        )
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    }

    Ok(())
}

async fn place_temporary_restriction(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let publication =
        uuid_value(payload, &["publicationId"]).ok_or(ServiceError::InvalidRequest)?;
    let expires = timestamp_value(payload, "expiresAt")?.ok_or(ServiceError::InvalidRequest)?;
    if expires <= OffsetDateTime::now_utc() {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query!(
        "INSERT INTO editorial.publication_access_decisions(id,publication_revision_id, \
         scope,affected_ids,state,reason,expires_at,placed_by) \
         VALUES($1,$2,$3,$4,'ACTIVE',$5,$6,$7)",
        id,
        publication,
        string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?,
        payload
            .get("affectedIds")
            .cloned()
            .unwrap_or_else(|| json!([])),
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        expires,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn propose_role_definition_change(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let role = uuid_value(payload, &["roleId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query!(
        "INSERT INTO ops.role_change_proposals(id,role_id,add_capabilities, \
         remove_capabilities,reason,status,proposed_by) \
         VALUES($1,$2,$3,$4,$5,'REVIEW',$6)",
        id,
        role,
        payload
            .get("addCapabilities")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
        payload
            .get("removeCapabilities")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn revoke_own_session(
    actor: Uuid,
    session_id: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let changed = sqlx::query!(
        "UPDATE ops.sessions SET revoked_at=clock_timestamp() \
         WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL",
        session_id,
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

async fn revoke_role(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let user = uuid_value(payload, &["userId"]).ok_or(ServiceError::InvalidRequest)?;
    let role = uuid_value(payload, &["roleId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query!(
        "UPDATE ops.user_roles SET revoked_at=clock_timestamp(),revoked_by=$3,version=version+1 \
         WHERE user_id=$1 AND role_id=$2 AND revoked_at IS NULL",
        user,
        role,
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

async fn revoke_user_sessions(
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if let Some(user) = uuid_value(payload, &["userId"]) {
        sqlx::query!("UPDATE ops.sessions SET revoked_at=COALESCE(revoked_at,clock_timestamp()) WHERE user_id=$1 AND revoked_at IS NULL", user).execute(&mut **tx).await.map_err(db)?;
    }

    Ok(())
}

async fn start_access_review(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let reviewers = uuid_array(payload, "reviewerUserIds")?;
    if reviewers.is_empty() {
        return Err(ServiceError::InvalidRequest);
    }
    let scope = string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?;
    let scope_id = uuid_value(payload, &["scopeId"]);
    sqlx::query!(
        "INSERT INTO ops.access_reviews(id,scope,scope_id,reviewer_user_ids,due_at,reason, \
         status,created_by) VALUES($1,$2,$3,$4,$5,$6,'OPEN',$7)",
        id,
        scope,
        scope_id,
        payload
            .get("reviewerUserIds")
            .cloned()
            .ok_or(ServiceError::InvalidRequest)?,
        timestamp_value(payload, "dueAt")?.ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    for reviewer in reviewers {
        sqlx::query!(
            "INSERT INTO ops.tasks(task_type,object_type,object_id,title,status,priority, \
             assignee_user_id,due_at,assigned_by,assignment_reason) \
             VALUES('ACCESS_REVIEW','ACCESS_REVIEW',$1,'Access review','OPEN','HIGH',$2,$3,$4,$5)",
            id,
            reviewer,
            timestamp_value(payload, "dueAt")?,
            actor,
            string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        )
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    }

    Ok(())
}

async fn current_account(claims: &ActorClaims, pool: &PgPool) -> Result<Value, ServiceError> {
    let user = Uuid::parse_str(&claims.sub).map_err(|_| ServiceError::InvalidRequest)?;
    let data: Value = sqlx::query_scalar!(
        "SELECT jsonb_build_object('userId',u.id,'email',u.email,'displayName',u.display_name, \
         'status',u.status,'rolesVersion',$3::bigint,'sessionId',$2::text) \
         FROM ops.users u WHERE u.id=$1",
        user,
        &claims.sid,
        claims.roles_version,
    )
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?
    .ok_or_else(unexpected_null)?;
    Ok(envelope(user, "ACTIVE", data))
}

async fn user_access_detail(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "userId")?;
    let row: Value = sqlx::query_scalar!(
        "SELECT jsonb_build_object('id',u.id,'email',u.email,'displayName',u.display_name, \
         'status',u.status,'rolesVersion',COALESCE((SELECT max(urv.version) FROM ops.user_roles urv \
           WHERE urv.user_id=u.id AND urv.revoked_at IS NULL),0),'version',u.version, \
         'roles',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',r.id,'code',r.code, \
           'name',r.name,'riskLevel',r.risk_level,'expiresAt',ur.expires_at) ORDER BY r.code) \
           FROM ops.user_roles ur JOIN ops.roles r ON r.id=ur.role_id \
           WHERE ur.user_id=u.id AND ur.revoked_at IS NULL),'[]'::jsonb), \
         'activeSessions',(SELECT count(*) FROM ops.sessions s WHERE s.user_id=u.id AND s.revoked_at IS NULL)) \
         FROM ops.users u WHERE u.id=$1",
        id,
    )
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?
    .ok_or_else(unexpected_null)?;
    Ok(envelope(id, value_status(&row), row))
}

async fn list_role_definitions(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items = sqlx::query_scalar!("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',r.id,'code',r.code,'name',r.name,'description',r.description,'riskLevel',r.risk_level,'version',r.version,'capabilities',COALESCE((SELECT jsonb_agg(rc.capability_code ORDER BY rc.capability_code) FROM ops.role_capabilities rc WHERE rc.role_id=r.id),'[]'::jsonb)) ORDER BY r.code),'[]'::jsonb) FROM ops.roles r").fetch_one(pool).await.map_err(db)?.ok_or_else(unexpected_null)?;
    list_response(items, parameters)
}

async fn list_users(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items = sqlx::query_scalar!("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',u.id,'email',u.email,'displayName',u.display_name,'status',u.status,'rolesVersion',COALESCE((SELECT max(ur.version) FROM ops.user_roles ur WHERE ur.user_id=u.id AND ur.revoked_at IS NULL),0),'version',u.version,'lastLoginAt',u.last_login_at) ORDER BY u.display_name),'[]'::jsonb) FROM ops.users u").fetch_one(pool).await.map_err(db)?.ok_or_else(unexpected_null)?;
    list_response(items, parameters)
}

fn list_response(
    items: Value,
    parameters: &BTreeMap<String, String>,
) -> Result<Value, ServiceError> {
    Ok(json!({"items":items,"appliedFilters":parameters,
        "asOf":format_time(OffsetDateTime::now_utc())?}))
}
