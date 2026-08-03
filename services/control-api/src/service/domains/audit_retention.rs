use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    CreateAuditExport,
    PlaceLegalHold,
    ReleaseLegalHold,
    TransitionRetentionRequest,
    VerifyAuditIntegrity,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    GetAuditExport,
    GetRetentionRequest,
    ListCaseAuditEvents,
    ListRecordClassSchedules,
    ListRetentionRequests,
    SearchAuditEvents,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "createAuditExport",
        Handler::Command(CommandHandler::AuditRetention(Command::CreateAuditExport)),
    ),
    (
        "getAuditExport",
        Handler::Query(QueryHandler::AuditRetention(Query::GetAuditExport)),
    ),
    (
        "getRetentionRequest",
        Handler::Query(QueryHandler::AuditRetention(Query::GetRetentionRequest)),
    ),
    (
        "listCaseAuditEvents",
        Handler::Query(QueryHandler::AuditRetention(Query::ListCaseAuditEvents)),
    ),
    (
        "listRecordClassSchedules",
        Handler::Query(QueryHandler::AuditRetention(
            Query::ListRecordClassSchedules,
        )),
    ),
    (
        "listRetentionRequests",
        Handler::Query(QueryHandler::AuditRetention(Query::ListRetentionRequests)),
    ),
    (
        "placeLegalHold",
        Handler::Command(CommandHandler::AuditRetention(Command::PlaceLegalHold)),
    ),
    (
        "releaseLegalHold",
        Handler::Command(CommandHandler::AuditRetention(Command::ReleaseLegalHold)),
    ),
    (
        "searchAuditEvents",
        Handler::Query(QueryHandler::AuditRetention(Query::SearchAuditEvents)),
    ),
    (
        "transitionRetentionRequest",
        Handler::Command(CommandHandler::AuditRetention(
            Command::TransitionRetentionRequest,
        )),
    ),
    (
        "verifyAuditIntegrity",
        Handler::Command(CommandHandler::AuditRetention(
            Command::VerifyAuditIntegrity,
        )),
    ),
];

pub(super) const fn command_kind(command: Command) -> CommandKind {
    match command {
        Command::ReleaseLegalHold | Command::TransitionRetentionRequest => CommandKind::Addendum,
        Command::CreateAuditExport | Command::PlaceLegalHold | Command::VerifyAuditIntegrity => {
            CommandKind::Base
        }
    }
}

pub(super) async fn apply(
    command: Command,
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::CreateAuditExport => create_audit_export(payload, id, actor, tx).await,
        Command::PlaceLegalHold => place_legal_hold(payload, id, actor, tx).await,
        Command::VerifyAuditIntegrity => verify_audit_integrity(payload, id, actor, tx).await,
        Command::ReleaseLegalHold | Command::TransitionRetentionRequest => {
            Err(ServiceError::InvalidRequest)
        }
    }
}

pub(super) async fn query(
    query: Query,
    operation: &OperationSpec,
    parameters: &BTreeMap<String, String>,
    _claims: &ActorClaims,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    match query {
        Query::GetAuditExport => get_audit_export(parameters, pool).await,
        Query::GetRetentionRequest => get_retention_request(parameters, pool).await,
        Query::ListCaseAuditEvents | Query::SearchAuditEvents => {
            audit_query(pool, parameters).await
        }
        Query::ListRecordClassSchedules | Query::ListRetentionRequests => {
            retention_queue_query(operation.id, parameters, pool).await
        }
    }
}

async fn verify_audit_integrity(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let mode = string_value(payload, "mode").ok_or(ServiceError::InvalidRequest)?;
    let from = uuid_value(payload, &["fromEventId"]);
    let to = uuid_value(payload, &["toEventId"]);
    let expected = payload.get("expectedChainHead").and_then(Value::as_str);
    match mode {
        "FULL" | "TAIL" if from.is_none() && to.is_none() => {}
        "RANGE" if from.is_some() && to.is_some() => {}
        _ => return Err(ServiceError::InvalidRequest),
    }
    if expected.is_some_and(|value| !is_sha256(value)) {
        return Err(ServiceError::InvalidRequest);
    }
    sqlx::query!(
        "INSERT INTO ops.audit_verification_runs(id,mode,from_event_id,to_event_id, \
         expected_chain_head,status,requested_by) VALUES($1,$2,$3,$4,$5,'QUEUED',$6)",
        id,
        mode,
        from,
        to,
        expected,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn create_audit_export(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let seconds = payload
        .get("expiresInSeconds")
        .and_then(Value::as_i64)
        .filter(|value| (300..=86_400).contains(value))
        .ok_or(ServiceError::InvalidRequest)?;
    let expires_at = OffsetDateTime::now_utc()
        .checked_add(time::Duration::seconds(seconds))
        .ok_or(ServiceError::InvalidRequest)?;
    sqlx::query!(
        "INSERT INTO ops.audit_exports(id,requested_by,from_at,to_at,format,scope,object_type,object_id,reason,watermark_policy,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
        id,
        actor,
        timestamp_value(payload, "from")?.ok_or(ServiceError::InvalidRequest)?,
        timestamp_value(payload, "to")?.ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "format").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?,
        payload.get("objectType").and_then(Value::as_str),
        payload.get("objectId").and_then(Value::as_str),
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "watermarkPolicy").ok_or(ServiceError::InvalidRequest)?,
        expires_at,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query!(
        "INSERT INTO ops.jobs(job_type,queue,payload,dedupe_key) VALUES('AUDIT_EXPORT','audit-export',$1,$2)",
        json!({"auditExportId":id}),
        format!("audit-export:{id}"),
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn place_legal_hold(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    // Match the research-fetch owner preflight lock. A legal hold placement
    // therefore cannot commit between rights admission and artifact record.
    let held_object = uuid_value(payload, &["objectId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query!(
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 13))",
        held_object.to_string(),
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    if let Some(case_id) = uuid_value(payload, &["caseId"]) {
        sqlx::query!(
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 13))",
            case_id.to_string(),
        )
        .execute(&mut **tx)
        .await
        .map_err(db)?;
    }
    // Fetch admission locks the exact affected-id atoms as text.  Acquire
    // those same locks before inserting the hold so placement cannot commit
    // between the admission check and the immutable fetch record.
    sqlx::query!(
        "SELECT pg_advisory_xact_lock(hashtextextended(value, 13)) FROM jsonb_array_elements_text(COALESCE($1::jsonb, '[]'::jsonb)) ORDER BY value",
        payload
            .get("affectedIds")
            .cloned()
            .unwrap_or_else(|| json!([])),
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query!(
        "INSERT INTO editorial.legal_holds(id,case_id,review_snapshot_id,object_type,object_id,scope,affected_ids,reason,authority_reference,expires_at,placed_by) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
        id,
        uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?,
        uuid_value(payload, &["reviewSnapshotId"]).ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "objectType").ok_or(ServiceError::InvalidRequest)?,
        held_object,
        string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?,
        payload
            .get("affectedIds")
            .cloned()
            .unwrap_or_else(|| json!([])),
        string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?,
        string_value(payload, "authorityReference").ok_or(ServiceError::InvalidRequest)?,
        timestamp_value(payload, "expiresAt")?,
        actor,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn get_audit_export(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "auditExportId")?;
    sqlx::query_scalar!(
        "SELECT jsonb_build_object('id',id,'status',status,'format',format,'scope',scope, \
         'from',from_at,'to',to_at,'objectType',object_type,'objectId',object_id, \
         'watermarkPolicy',watermark_policy,'createdAt',created_at,'startedAt',started_at, \
         'completedAt',completed_at,'expiresAt',expires_at,'rowCount',row_count, \
         'contentSha256',content_sha256,'downloadUrl',NULL::text, \
         'failureCode',failure_code,'links','[]'::jsonb) \
         FROM ops.audit_exports WHERE id=$1",
        id,
    )
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?
    .ok_or_else(|| {
        db(sqlx::Error::Decode(Box::new(
            sqlx::error::UnexpectedNullError,
        )))
    })
}

async fn get_retention_request(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = parameters
        .get("retentionRequestId")
        .or_else(|| parameters.get("id"))
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ServiceError::InvalidRequest)?;
    let value: Option<Value> = sqlx::query_scalar!("SELECT ops.read_retention_request_v1($1)", id)
        .fetch_optional(pool)
        .await
        .map_err(db)?
        .flatten();
    let Some(value) = value else {
        return Err(ServiceError::NotFound);
    };
    Ok(value)
}

async fn retention_queue_query(
    operation: &str,
    _parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items: Value = match operation {
        "listRetentionRequests" => sqlx::query_scalar!("SELECT ops.read_retention_queue_v1()")
            .fetch_one(pool)
            .await
            .map_err(db)?
            .ok_or_else(|| {
                db(sqlx::Error::Decode(Box::new(
                    sqlx::error::UnexpectedNullError,
                )))
            })?,
        "listRecordClassSchedules" => {
            sqlx::query_scalar!("SELECT ops.read_record_class_schedule_queue_v1()")
                .fetch_one(pool)
                .await
                .map_err(db)?
                .ok_or_else(|| {
                    db(sqlx::Error::Decode(Box::new(
                        sqlx::error::UnexpectedNullError,
                    )))
                })?
        }
        _ => return Err(ServiceError::Persistence),
    };
    let items = match operation {
        "listRetentionRequests" => normalize_retention_queue_items(items),
        "listRecordClassSchedules" => normalize_record_class_schedule_items(items),
        _ => items,
    };
    queue_page(operation, items)
}

fn queue_page(operation: &str, items: Value) -> Result<Value, ServiceError> {
    let as_of = format_time(OffsetDateTime::now_utc())?;
    Ok(match operation {
        "listRetentionRequests" => {
            json!({"items":items,"appliedFilters":{"requestType":[],"state":[],"dueBefore":null,"legalHoldBlocked":null,"sort":"DUE_ASC"},"asOf":as_of,"nextCursor":null,"totalApproximate":null,"operationId":operation,"links":[]})
        }
        "listRecordClassSchedules" => {
            json!({"items":items,"appliedRecordClasses":[],"appliedStates":[],"asOf":as_of,"nextCursor":null,"operationId":operation,"links":[]})
        }
        _ => {
            json!({"items":items,"appliedFilters":{},"asOf":as_of,"nextCursor":null,"totalApproximate":null,"operationId":operation,"links":[]})
        }
    })
}

fn normalize_retention_queue_items(value: Value) -> Value {
    let Some(rows) = value.as_array() else {
        return json!([]);
    };
    Value::Array(rows.iter().filter_map(|row| {
        Some(json!({
            "retentionRequestId": row.get("retention_request_id")?.clone(),
            "requestType": row.get("request_type")?.clone(),
            "decisionVersion": row.get("decision_version").cloned().unwrap_or_else(|| json!(1)),
            "state": row.get("state").cloned().unwrap_or_else(|| json!("REVIEW")),
            "jurisdiction": row.get("jurisdiction").cloned().unwrap_or_else(|| json!("UNKNOWN")),
            "scopeDigest": row.get("scope_digest").cloned().unwrap_or_else(|| json!("0000000000000000000000000000000000000000000000000000000000000000")),
            "legalHoldBlocked": row.get("legal_hold_blocked").cloned().unwrap_or(json!(false)),
            // The immutable decision table has no separate due_at column;
            // expose the decision timestamp as the queue's deterministic
            // due-at witness rather than emitting a schema-invalid null.
            "dueAt": row.get("due_at").cloned().or_else(|| row.get("decided_at").cloned()).unwrap_or(Value::Null),
            "createdAt": row.get("created_at").cloned().unwrap_or(row.get("decided_at").cloned().unwrap_or(Value::Null)),
            "updatedAt": row.get("decided_at").cloned().unwrap_or(Value::Null)
        }))
    }).collect())
}

fn normalize_record_class_schedule_items(value: Value) -> Value {
    let Some(rows) = value.as_array() else {
        return json!([]);
    };
    Value::Array(rows.iter().filter_map(|row| {
        Some(json!({
            "recordClass": row.get("record_class")?.clone(),
            "revision": row.get("revision").cloned().unwrap_or_else(|| json!(1)),
            "state": row.get("state").cloned().unwrap_or_else(|| json!("CURRENT")),
            "lawfulBasis": row.get("lawful_basis").cloned().unwrap_or_else(|| json!("UNKNOWN")),
            "activeDuration": row.get("active_duration_seconds").cloned().map(|v| json!(v.to_string())).unwrap_or_else(|| json!("indefinite")),
            "backupDuration": row.get("backup_duration_seconds").cloned().map(|v| json!(v.to_string())).unwrap_or_else(|| json!("indefinite")),
            "terminalAction": row.get("terminal_action").cloned().unwrap_or_else(|| json!("ARCHIVE")),
            "effectiveAt": row.get("effective_at").cloned().unwrap_or(Value::Null),
            "reviewExpiresAt": row.get("review_expires_at").cloned().unwrap_or(Value::Null),
            "scheduleDigest": row.get("schedule_digest").cloned().unwrap_or_else(|| json!("0000000000000000000000000000000000000000000000000000000000000000"))
        }))
    }).collect())
}
