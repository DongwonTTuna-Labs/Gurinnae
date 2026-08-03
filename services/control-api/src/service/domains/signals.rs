use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    AssignSignal,
    LinkSignalToCase,
    TriageSignal,
    UnlinkSignalFromCase,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    GetSignalTriageView,
    ListCaseSignals,
    ListSignals,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "assignSignal",
        Handler::Command(CommandHandler::Signals(Command::AssignSignal)),
    ),
    (
        "getSignalTriageView",
        Handler::Query(QueryHandler::Signals(Query::GetSignalTriageView)),
    ),
    (
        "linkSignalToCase",
        Handler::Command(CommandHandler::Signals(Command::LinkSignalToCase)),
    ),
    (
        "listCaseSignals",
        Handler::Query(QueryHandler::Signals(Query::ListCaseSignals)),
    ),
    (
        "listSignals",
        Handler::Query(QueryHandler::Signals(Query::ListSignals)),
    ),
    (
        "triageSignal",
        Handler::Command(CommandHandler::Signals(Command::TriageSignal)),
    ),
    (
        "unlinkSignalFromCase",
        Handler::Command(CommandHandler::Signals(Command::UnlinkSignalFromCase)),
    ),
];

pub(super) const fn command_kind(_command: Command) -> CommandKind {
    CommandKind::Base
}

pub(super) async fn apply(
    command: Command,
    payload: &Map<String, Value>,
    _id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    match command {
        Command::AssignSignal => assign_signal(payload, actor, tx).await,
        Command::LinkSignalToCase => link_signal_to_case(payload, actor, tx).await,
        Command::TriageSignal => triage_signal(payload, actor, tx).await,
        Command::UnlinkSignalFromCase => unlink_signal_from_case(payload, tx).await,
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
        Query::GetSignalTriageView => signal_query(parameters, pool).await,
        Query::ListCaseSignals => list_case_signals(parameters, pool).await,
        Query::ListSignals => list_signals(parameters, pool).await,
    }
}

async fn assign_signal(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let signal = uuid_value(payload, &["signalId"]).ok_or(ServiceError::InvalidRequest)?;
    let assignee = uuid_value(payload, &["assigneeUserId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "UPDATE core.anomaly_signals SET assigned_user_id=$2,status='ASSIGNED' WHERE id=$1",
    )
    .bind(signal)
    .bind(assignee)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    upsert_task(
        tx,
        "SIGNAL",
        signal,
        "Signal triage",
        "OPEN",
        "HIGH",
        Some(assignee),
        actor,
        payload.get("reason").and_then(Value::as_str),
    )
    .await?;

    Ok(())
}

async fn link_signal_to_case(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let signal = uuid_value(payload, &["signalId"]).ok_or(ServiceError::InvalidRequest)?;
    sqlx::query(
        "INSERT INTO editorial.case_signals(case_id,signal_id,link_reason,linked_by) \
         VALUES($1,$2,$3,$4) ON CONFLICT(case_id,signal_id) DO NOTHING",
    )
    .bind(case_id)
    .bind(signal)
    .bind(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?)
    .bind(actor)
    .execute(&mut **tx)
    .await
    .map_err(db)?;
    sqlx::query("UPDATE core.anomaly_signals SET status='LINKED' WHERE id=$1")
        .bind(signal)
        .execute(&mut **tx)
        .await
        .map_err(db)?;

    Ok(())
}

async fn triage_signal(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let signal = uuid_value(payload, &["signalId"]).ok_or(ServiceError::InvalidRequest)?;
    let detail = payload.get("decisionDetail").and_then(Value::as_object);
    let decision = detail
        .and_then(|value| value.get("decision").and_then(Value::as_str))
        .or_else(|| string_value(payload, "decision"));
    let status = signal_status(decision)?;
    let expected_version = detail
        .and_then(|value| value.get("expectedSignalVersion").and_then(Value::as_i64))
        .or_else(|| payload.get("expectedVersion").and_then(Value::as_i64))
        .ok_or(ServiceError::InvalidRequest)?;
    let duplicate_target = detail
        .and_then(|value| value.get("duplicateSignalId").and_then(Value::as_str))
        .or_else(|| payload.get("duplicateSignalId").and_then(Value::as_str))
        .map(|raw| Uuid::parse_str(raw).map_err(|_| ServiceError::InvalidRequest))
        .transpose()?;
    if status == "DUPLICATE" {
        mark_duplicate_signal(
            payload,
            detail,
            signal,
            actor,
            expected_version,
            duplicate_target,
            tx,
        )
        .await?;
    } else {
        mark_signal_status(payload, detail, signal, status, expected_version, tx).await?;
    }
    upsert_task(
        tx,
        "SIGNAL",
        signal,
        "Signal triage",
        if matches!(status, "DISMISSED" | "DUPLICATE") {
            "DONE"
        } else {
            "OPEN"
        },
        "HIGH",
        None,
        actor,
        Some(string_value(payload, "reason").ok_or(ServiceError::InvalidRequest)?),
    )
    .await?;
    Ok(())
}

fn signal_status(decision: Option<&str>) -> Result<&'static str, ServiceError> {
    match decision {
        Some("investigate") | Some("PROMOTE_TO_CASE") => Ok("ASSIGNED"),
        Some("dismiss") | Some("DISMISS") => Ok("DISMISSED"),
        Some("duplicate") | Some("MARK_DUPLICATE") => Ok("DUPLICATE"),
        Some("needs_data") | Some("NEEDS_DATA") => Ok("NEEDS_DATA"),
        Some("link") | Some("LINK_TO_CASE") => Ok("LINKED"),
        _ => Err(ServiceError::InvalidRequest),
    }
}

async fn mark_duplicate_signal(
    payload: &Map<String, Value>,
    detail: Option<&Map<String, Value>>,
    signal: Uuid,
    actor: Uuid,
    expected_version: i64,
    duplicate_target: Option<Uuid>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let target = duplicate_target.ok_or(ServiceError::InvalidRequest)?;
    if target == signal {
        return Err(ServiceError::InvalidRequest);
    }
    let pair = sqlx::query(
        "SELECT id, version FROM core.anomaly_signals \
         WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE",
    )
    .bind(vec![signal, target])
    .fetch_all(&mut **tx)
    .await
    .map_err(db)?;
    if pair.len() != 2 {
        return Err(ServiceError::NotFound);
    }
    // A duplicate decision changes two aggregates. Require the target's
    // expected version in the request so a stale pair cannot be accepted.
    let target_expected = detail
        .and_then(|value| {
            value
                .get("expectedDuplicateSignalVersion")
                .and_then(Value::as_i64)
        })
        .or_else(|| {
            payload
                .get("expectedDuplicateSignalVersion")
                .and_then(Value::as_i64)
        })
        .ok_or(ServiceError::InvalidRequest)?;
    let target_version = pair
        .iter()
        .find(|row| row.try_get::<Uuid, _>("id").ok() == Some(target))
        .and_then(|row| row.try_get::<i64, _>("version").ok())
        .ok_or(ServiceError::NotFound)?;
    if target_expected != target_version {
        return Err(ServiceError::VersionConflict);
    }
    let relationship = detail
        .and_then(|value| value.get("duplicateRelationship").and_then(Value::as_str))
        .or_else(|| payload.get("duplicateRelationship").and_then(Value::as_str))
        .unwrap_or("SAME_LOGICAL_EVENT");
    if !matches!(
        relationship,
        "SAME_LOGICAL_EVENT" | "SAME_TARGET" | "SAME_SOURCE" | "OTHER"
    ) {
        return Err(ServiceError::InvalidRequest);
    }
    let reason = signal_reason(payload, detail)?;
    // Bind the rationale to the complete duplicate relation rather than to
    // free text alone; otherwise the same reason can be replayed for another
    // signal/target pair without changing its digest.
    let rationale_binding = json!({
        "signalId": signal,
        "expectedSignalVersion": expected_version,
        "duplicateSignalId": target,
        "expectedDuplicateSignalVersion": target_expected,
        "duplicateRelationship": relationship,
        "reason": reason,
    });
    let rationale_digest =
        sha256(&serde_json::to_vec(&rationale_binding).map_err(|_| ServiceError::InvalidRequest)?);
    let changed = sqlx::query(
        "UPDATE core.anomaly_signals
            SET status='DUPLICATE'::core.signal_status,
                duplicate_signal_id=$2, duplicate_relationship=$3,
                duplicate_reason_digest=$4, duplicate_marked_by=$5,
                duplicate_marked_at=clock_timestamp(), version=version+1
          WHERE id=$1 AND version=$6 AND status <> 'DUPLICATE'::core.signal_status",
    )
    .bind(signal)
    .bind(target)
    .bind(relationship)
    .bind(rationale_digest)
    .bind(actor)
    .bind(expected_version)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }
    Ok(())
}

async fn mark_signal_status(
    payload: &Map<String, Value>,
    detail: Option<&Map<String, Value>>,
    signal: Uuid,
    status: &str,
    expected_version: i64,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let _reason = signal_reason(payload, detail)?;
    let changed = sqlx::query(
        "UPDATE core.anomaly_signals
            SET status=$2::core.signal_status,
                duplicate_signal_id=NULL, duplicate_relationship=NULL,
                duplicate_reason_digest=NULL, duplicate_marked_by=NULL,
                duplicate_marked_at=NULL, version=version+1
          WHERE id=$1 AND version=$3 AND status <> 'DUPLICATE'::core.signal_status",
    )
    .bind(signal)
    .bind(status)
    .bind(expected_version)
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed != 1 {
        return Err(ServiceError::VersionConflict);
    }
    Ok(())
}

fn signal_reason<'a>(
    payload: &'a Map<String, Value>,
    detail: Option<&'a Map<String, Value>>,
) -> Result<&'a str, ServiceError> {
    string_value(payload, "reason")
        .or_else(|| detail.and_then(|value| value.get("reason").and_then(Value::as_str)))
        .ok_or(ServiceError::InvalidRequest)
}

async fn unlink_signal_from_case(
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let case_id = uuid_value(payload, &["caseId"]).ok_or(ServiceError::InvalidRequest)?;
    let signal = uuid_value(payload, &["signalId"]).ok_or(ServiceError::InvalidRequest)?;
    let changed =
        sqlx::query("DELETE FROM editorial.case_signals WHERE case_id=$1 AND signal_id=$2")
            .bind(case_id)
            .bind(signal)
            .execute(&mut **tx)
            .await
            .map_err(db)?
            .rows_affected();
    if changed != 1 {
        return Err(ServiceError::NotFound);
    }
    sqlx::query(
        "UPDATE core.anomaly_signals SET status= \
         CASE WHEN assigned_user_id IS NULL THEN 'NEW'::core.signal_status \
              ELSE 'ASSIGNED'::core.signal_status END WHERE id=$1",
    )
    .bind(signal)
    .execute(&mut **tx)
    .await
    .map_err(db)?;

    Ok(())
}

async fn signal_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "signalId")?;
    let signal: Value = sqlx::query_scalar(
        "SELECT jsonb_build_object('id',s.id,'ruleRunId',s.rule_run_id, \
         'ruleVersionId',s.rule_version_id,'signalType',s.signal_type,'targetType',s.target_type, \
         'targetId',s.target_id,'score',s.score,'severity',s.severity,'status',s.status::text, \
         'explanation',s.explanation,'calculation',s.calculation,'blockers',s.blockers, \
         'comparisonDigest',s.comparison_digest,'assignedUserId',s.assigned_user_id,'version',s.version, \
         'duplicateSignalId',s.duplicate_signal_id,'duplicateRelationship',s.duplicate_relationship, \
         'duplicateReasonDigest',s.duplicate_reason_digest,'duplicateMarkedBy',s.duplicate_marked_by, \
         'duplicateMarkedAt',s.duplicate_marked_at) \
         FROM core.anomaly_signals s WHERE s.id=$1",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let duplicates: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(jsonb_build_object('id',d.id,'signalType',d.signal_type,
          'severity',d.severity,'status',d.status::text,'targetType',d.target_type,
          'targetId',d.target_id,'explanation',d.explanation,'createdAt',d.created_at,
          'assignedUserId',d.assigned_user_id,'duplicateRelationship',d.duplicate_relationship)
          ORDER BY d.created_at DESC),'[]'::jsonb)
           FROM core.anomaly_signals d
          WHERE d.id=(SELECT duplicate_signal_id FROM core.anomaly_signals WHERE id=$1)
             OR d.duplicate_signal_id=$1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .map_err(db)?;
    Ok(
        json!({"signal":signal,"triggerExplanation":signal.get("explanation").cloned().unwrap_or(json!({})),
        "dataQuality":{},"targetRecord":{},"duplicates":duplicates,
        "blockers":signal.get("blockers").cloned().unwrap_or(json!([])),
        "recommendedActions":[],"auditSummary":{}}),
    )
}

async fn list_case_signals(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let case_id = query_uuid(parameters, "caseId")?;
    let items = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',s.id,'signalType',s.signal_type,'severity',s.severity,'status',s.status::text,'score',s.score,'version',s.version,'linkedAt',cs.linked_at) ORDER BY cs.linked_at DESC),'[]'::jsonb) FROM editorial.case_signals cs JOIN core.anomaly_signals s ON s.id=cs.signal_id WHERE cs.case_id=$1").bind(case_id).fetch_one(pool).await.map_err(db)?;
    list_response(items, parameters)
}

async fn list_signals(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items = sqlx::query_scalar("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'signalType',signal_type,'targetType',target_type,'targetId',target_id,'score',score,'severity',severity,'status',status::text,'assignedUserId',assigned_user_id,'version',version,'createdAt',created_at,'duplicateSignalId',duplicate_signal_id,'duplicateRelationship',duplicate_relationship) ORDER BY created_at DESC),'[]'::jsonb) FROM core.anomaly_signals").fetch_one(pool).await.map_err(db)?;
    list_response(items, parameters)
}

fn list_response(
    items: Value,
    parameters: &BTreeMap<String, String>,
) -> Result<Value, ServiceError> {
    Ok(json!({"items":items,"appliedFilters":parameters,
        "asOf":format_time(OffsetDateTime::now_utc())?}))
}
