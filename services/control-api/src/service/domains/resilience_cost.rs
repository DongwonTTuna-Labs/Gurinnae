use super::*;
use crate::service::registry::{CommandHandler, Handler, QueryHandler};
use base64::engine::general_purpose::STANDARD as BASE64;

fn unexpected_null() -> ServiceError {
    db(sqlx::Error::Decode(Box::new(
        sqlx::error::UnexpectedNullError,
    )))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Command {
    ActivateKillSwitch,
    DeactivateKillSwitch,
    ExtendKillSwitch,
    UpdateBudgetLimit,
    TriageIncident,
    ContainIncident,
    StartIncidentRecovery,
    ResolveIncident,
    CloseIncidentPostmortem,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::service) enum Query {
    GetBudgetOverview,
    ExportCostReport,
    ListKillSwitches,
    GetIncident,
}

pub(super) const OPERATIONS: &[(&str, Handler)] = &[
    (
        "activateKillSwitch",
        Handler::Command(CommandHandler::ResilienceCost(Command::ActivateKillSwitch)),
    ),
    (
        "deactivateKillSwitch",
        Handler::Command(CommandHandler::ResilienceCost(
            Command::DeactivateKillSwitch,
        )),
    ),
    (
        "extendKillSwitch",
        Handler::Command(CommandHandler::ResilienceCost(Command::ExtendKillSwitch)),
    ),
    (
        "updateBudgetLimit",
        Handler::Command(CommandHandler::ResilienceCost(Command::UpdateBudgetLimit)),
    ),
    (
        "triageIncident",
        Handler::Command(CommandHandler::ResilienceCost(Command::TriageIncident)),
    ),
    (
        "containIncident",
        Handler::Command(CommandHandler::ResilienceCost(Command::ContainIncident)),
    ),
    (
        "startIncidentRecovery",
        Handler::Command(CommandHandler::ResilienceCost(
            Command::StartIncidentRecovery,
        )),
    ),
    (
        "resolveIncident",
        Handler::Command(CommandHandler::ResilienceCost(Command::ResolveIncident)),
    ),
    (
        "closeIncidentPostmortem",
        Handler::Command(CommandHandler::ResilienceCost(
            Command::CloseIncidentPostmortem,
        )),
    ),
    (
        "getBudgetOverview",
        Handler::Query(QueryHandler::ResilienceCost(Query::GetBudgetOverview)),
    ),
    (
        "exportCostReport",
        Handler::Query(QueryHandler::ResilienceCost(Query::ExportCostReport)),
    ),
    (
        "listKillSwitches",
        Handler::Query(QueryHandler::ResilienceCost(Query::ListKillSwitches)),
    ),
    (
        "getIncident",
        Handler::Query(QueryHandler::ResilienceCost(Query::GetIncident)),
    ),
];

pub(super) fn command_kind(command: Command) -> CommandKind {
    match command {
        Command::ActivateKillSwitch
        | Command::DeactivateKillSwitch
        | Command::ExtendKillSwitch
        | Command::UpdateBudgetLimit => CommandKind::Base,
        Command::TriageIncident
        | Command::ContainIncident
        | Command::StartIncidentRecovery
        | Command::ResolveIncident
        | Command::CloseIncidentPostmortem => CommandKind::Addendum,
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
        Command::ActivateKillSwitch => activate_kill_switch(payload, id, actor, tx).await,
        Command::DeactivateKillSwitch => deactivate_kill_switch(payload, actor, tx).await,
        Command::ExtendKillSwitch => extend_kill_switch(payload, tx).await,
        Command::UpdateBudgetLimit => update_budget_limit(payload, actor, tx).await,
        Command::TriageIncident
        | Command::ContainIncident
        | Command::StartIncidentRecovery
        | Command::ResolveIncident
        | Command::CloseIncidentPostmortem => Err(ServiceError::InvalidRequest),
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
        Query::GetBudgetOverview => budget_overview_query(pool).await,
        Query::ExportCostReport => cost_export_query(parameters, pool).await,
        Query::ListKillSwitches => list_kill_switches(parameters, pool).await,
        Query::GetIncident => get_incident(parameters, pool).await,
    }
}

async fn update_budget_limit(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let scope = string_value(payload, "scope").ok_or(ServiceError::InvalidRequest)?;
    let daily = decimal_string(payload, "dailyLimit")?;
    let monthly = decimal_string(payload, "monthlyLimit")?;
    if daily < rust_decimal::Decimal::ZERO || monthly < daily {
        return Err(ServiceError::InvalidRequest);
    }
    let changed = sqlx::query!(
        "UPDATE ops.budget_limits SET daily_limit=$2,monthly_limit=$3,currency=$4, \
         updated_by=$5,updated_at=clock_timestamp() WHERE scope=$1",
        scope,
        daily,
        monthly,
        string_value(payload, "currency").ok_or(ServiceError::InvalidRequest)?,
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

async fn activate_kill_switch(
    payload: &Map<String, Value>,
    id: Uuid,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let changed = sqlx::query!(
        "UPDATE ops.kill_switches SET scope=$2,state='ACTIVE',reason=$3,activated_by=$4,activated_at=clock_timestamp(),expires_at=$5,deactivated_by=NULL,deactivated_at=NULL,updated_at=clock_timestamp() WHERE id=$1",
        id,
        payload.get("scope").cloned().ok_or(ServiceError::InvalidRequest)?,
        string_value(payload,"reason").ok_or(ServiceError::InvalidRequest)?,
        actor,
        timestamp_value(payload,"expiresAt")?,
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

async fn deactivate_kill_switch(
    payload: &Map<String, Value>,
    actor: Uuid,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    if let Some(target) = uuid_value(payload, &["killSwitchId", "id"]) {
        let changed = sqlx::query!("UPDATE ops.kill_switches SET state='INACTIVE',deactivated_by=$2,deactivated_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=$1 AND state='ACTIVE'", target, actor).execute(&mut **tx).await.map_err(db)?.rows_affected();
        if changed == 0 {
            return Err(ServiceError::NotFound);
        }
    }

    Ok(())
}

async fn extend_kill_switch(
    payload: &Map<String, Value>,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<(), ServiceError> {
    let target =
        uuid_value(payload, &["killSwitchId", "id"]).ok_or(ServiceError::InvalidRequest)?;
    let changed = sqlx::query!(
        "UPDATE ops.kill_switches SET expires_at= \
         GREATEST(COALESCE(expires_at,clock_timestamp()),clock_timestamp())+interval '1 hour', \
         updated_at=clock_timestamp() WHERE id=$1 AND state='ACTIVE'",
        target,
    )
    .execute(&mut **tx)
    .await
    .map_err(db)?
    .rows_affected();
    if changed == 0 {
        return Err(ServiceError::NotFound);
    }

    Ok(())
}

/// OPS-004 authority read boundary. The PostgreSQL owner is the canonical
/// source for the BudgetOverview projection consumed by the review console.
async fn business_health_query(
    _parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let data: Value = sqlx::query_scalar!("SELECT ops.read_business_health_projection_v1()")
        .fetch_one(pool)
        .await
        .map_err(db)?
        .ok_or_else(unexpected_null)?;
    let status = data
        .get("summary")
        .and_then(|summary| summary.get("status"))
        .and_then(Value::as_str)
        .unwrap_or("UNKNOWN")
        .to_owned();
    Ok(envelope(
        stable_uuid("budget-overview", "current"),
        status,
        data,
    ))
}

async fn budget_overview_query(pool: &PgPool) -> Result<Value, ServiceError> {
    business_health_query(&BTreeMap::new(), pool).await
}

async fn cost_export_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let params = parse_cost_export_parameters(parameters)?;
    let rows: Value = sqlx::query_scalar!(
        // The contract is an explicit half-open window [from,to).  Do not
        // widen a caller's upper bound by converting it to a date and adding
        // a day; that silently exports rows outside the requested snapshot.
        "SELECT ops.read_cost_export_projection_v1($1::timestamptz, $2::timestamptz, $3)",
        &params.from as _,
        &params.to as _,
        &params.group_by,
    )
    .fetch_one(pool)
    .await
    .map_err(db)?
    .ok_or_else(unexpected_null)?;
    let digest_input = serde_json::json!({
        "from": params.from, "to": params.to, "groupBy": params.group_by,
        "format": params.format, "rows": rows
    });
    let digest = sha256(&serde_json::to_vec(&digest_input).map_err(|_| ServiceError::Persistence)?);
    let payload = render_cost_export_payload(&rows, &params)?;
    Ok(cost_export_document(
        &params,
        &digest,
        &rows,
        payload.as_bytes(),
    ))
}

struct CostExportParameters {
    from: String,
    to: String,
    group_by: String,
    format: String,
}

fn parse_cost_export_parameters(
    parameters: &BTreeMap<String, String>,
) -> Result<CostExportParameters, ServiceError> {
    let from = parameters.get("from").ok_or(ServiceError::InvalidRequest)?;
    let to = parameters.get("to").ok_or(ServiceError::InvalidRequest)?;
    let group_by = parameters
        .get("groupBy")
        .filter(|value| matches!(value.as_str(), "PROVIDER" | "MODEL" | "CASE" | "DAY"))
        .ok_or(ServiceError::InvalidRequest)?;
    let format = parameters
        .get("format")
        .filter(|value| matches!(value.as_str(), "CSV" | "JSON"))
        .ok_or(ServiceError::InvalidRequest)?;
    let date_format = time::format_description::parse("[year]-[month]-[day]")
        .map_err(|_| ServiceError::Persistence)?;
    let from_date = Date::parse(from, &date_format).map_err(|_| ServiceError::InvalidRequest)?;
    let to_date = Date::parse(to, &date_format).map_err(|_| ServiceError::InvalidRequest)?;
    if from_date >= to_date {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(CostExportParameters {
        from: from.clone(),
        to: to.clone(),
        group_by: group_by.clone(),
        format: format.clone(),
    })
}

fn render_cost_export_payload(
    rows: &Value,
    params: &CostExportParameters,
) -> Result<String, ServiceError> {
    if params.format == "JSON" {
        return serde_json::to_string(
            &json!({"rows":rows,"from":params.from,"to":params.to,"groupBy":params.group_by}),
        )
        .map_err(|_| ServiceError::Persistence);
    }
    let mut csv = String::from(
        "group,amount,currency,rowCount,reservationSettled,reservationReserved,state,unknownReason\n",
    );
    for item in rows
        .get("rows")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        csv.push_str(&format!(
            "{},{},{},{},{},{},{},{}\n",
            item.get("key").and_then(Value::as_str).unwrap_or("UNKNOWN"),
            item.get("amount").and_then(Value::as_str).unwrap_or(""),
            item.get("currency")
                .and_then(Value::as_str)
                .unwrap_or("UNKNOWN"),
            item.get("rowCount").and_then(Value::as_i64).unwrap_or(0),
            item.get("reservationSettled")
                .and_then(Value::as_str)
                .unwrap_or(""),
            item.get("reservationReserved")
                .and_then(Value::as_str)
                .unwrap_or(""),
            item.get("state")
                .and_then(Value::as_str)
                .unwrap_or("UNKNOWN"),
            item.get("unknownReason")
                .and_then(Value::as_str)
                .unwrap_or("")
        ));
    }
    Ok(csv)
}

fn cost_export_document(
    params: &CostExportParameters,
    digest: &str,
    rows: &Value,
    bytes: &[u8],
) -> Value {
    let content_sha256 = sha256(bytes);
    let content_base64 = BASE64.encode(bytes);
    let row_count = rows
        .get("rows")
        .and_then(Value::as_array)
        .map_or(0, |items| items.len());
    json!({"id":stable_uuid("cost-export",digest),"status":if row_count > 0 { "READY" } else { "EMPTY" },"version":1,
      "format":params.format,"rowCount":row_count,"byteLength":bytes.len(),"contentSha256":content_sha256,
      "contentBase64":content_base64,"binary":content_base64,
      "filename":format!("gurinnae-cost-report-{}.{}",params.from,if params.format == "CSV" { "csv" } else { "json" }),
      "mediaType":if params.format == "CSV" { "text/csv; charset=utf-8" } else { "application/json" },
      "receiptSha256":sha256(format!("cost-export-receipt:{}:{}:{}",digest,content_sha256,bytes.len()).as_bytes()),
      "from":params.from,"to":params.to,"groupBy":params.group_by})
}

async fn list_kill_switches(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let items: Value = sqlx::query_scalar!("SELECT COALESCE(jsonb_agg(jsonb_build_object('id',id,'code',code,'scope',scope,'state',state::text,'reason',reason,'activatedAt',activated_at,'expiresAt',expires_at,'version',version) ORDER BY updated_at DESC),'[]'::jsonb) FROM ops.kill_switches").fetch_one(pool).await.map_err(db)?.ok_or_else(unexpected_null)?;
    Ok(
        json!({"items":items,"appliedFilters":parameters,"asOf":format_time(OffsetDateTime::now_utc())?}),
    )
}

async fn get_incident(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = parameters
        .get("incidentId")
        .or_else(|| parameters.get("id"))
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ServiceError::InvalidRequest)?;
    let value: Option<Value> = sqlx::query_scalar!("SELECT ops.read_incident_v1($1)", id)
        .fetch_optional(pool)
        .await
        .map_err(db)?
        .map(|value| value.ok_or_else(unexpected_null))
        .transpose()?;
    let Some(value) = value else {
        return Err(ServiceError::NotFound);
    };
    Ok(value)
}
