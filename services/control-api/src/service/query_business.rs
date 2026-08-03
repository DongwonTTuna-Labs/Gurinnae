use super::*;

fn business_query_required<T>(value: Option<T>) -> Result<T, ServiceError> {
    value.ok_or_else(|| {
        db(sqlx::Error::Decode(Box::new(
            sqlx::error::UnexpectedNullError,
        )))
    })
}

pub(super) async fn estimate_backfill_query(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let source = parameters
        .get("sourceId")
        .filter(|value| !value.is_empty())
        .ok_or(ServiceError::InvalidRequest)?;
    let from = query_date(parameters, "from")?;
    let to = query_date(parameters, "to")?;
    if from > to {
        return Err(ServiceError::InvalidRequest);
    }
    let enabled = sqlx::query_scalar!(
        "SELECT enabled AND legal_status='APPROVED' FROM ops.source_registry WHERE source_id=$1",
        source,
    )
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let enabled = business_query_required(enabled)?;
    let history = sqlx::query_scalar!(
        "SELECT jsonb_build_object('historicalRuns',count(*),'historicalRecords', \
         COALESCE(sum(records_seen),0),'historicalChanges',COALESCE(sum(records_changed),0)) \
         FROM ops.source_runs WHERE source_id=$1",
        source,
    )
    .fetch_one(pool)
    .await
    .map_err(db)?;
    let history = business_query_required(history)?;
    Ok(envelope(
        stable_uuid("backfill-estimate", &format!("{source}:{from}:{to}")),
        if enabled { "READY" } else { "BLOCKED" },
        json!({"sourceId":source,"from":from.to_string(),"to":to.to_string(),"estimate":history}),
    ))
}

pub(super) async fn source_run_download(
    parameters: &BTreeMap<String, String>,
    pool: &PgPool,
) -> Result<Value, ServiceError> {
    let id = query_uuid(parameters, "sourceRunId")?;
    let available = sqlx::query_scalar!(
        "SELECT status='SUCCEEDED' AND report_object_key IS NOT NULL FROM ops.source_runs WHERE id=$1",
        id,
    )
    .fetch_optional(pool)
    .await
    .map_err(db)?
    .ok_or(ServiceError::NotFound)?;
    let available = business_query_required(available)?;
    if !available {
        return Err(ServiceError::NotFound);
    }
    Ok(json!({"id":id,"status":"READY","version":1}))
}

pub(super) fn query_date(
    parameters: &BTreeMap<String, String>,
    name: &str,
) -> Result<Date, ServiceError> {
    let format = time::format_description::parse("[year]-[month]-[day]")
        .map_err(|_| ServiceError::Persistence)?;
    parameters
        .get(name)
        .ok_or(ServiceError::InvalidRequest)
        .and_then(|value| Date::parse(value, &format).map_err(|_| ServiceError::InvalidRequest))
}

pub(super) fn stable_uuid(namespace: &str, value: &str) -> Uuid {
    let digest = Sha256::digest(format!("gurine:{namespace}:{value}").as_bytes());
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

pub(super) async fn audit_query(
    pool: &PgPool,
    parameters: &BTreeMap<String, String>,
) -> Result<Value, ServiceError> {
    let object_id = parameters
        .get("caseId")
        .or_else(|| parameters.get("objectId"));
    let rows=sqlx::query!("SELECT id,occurred_at,actor_type,actor_id,action,object_type,object_id,capability,outcome::text outcome,reason,request_id,details,event_hash,previous_event_hash FROM ops.audit_events WHERE ($1::text IS NULL OR object_id=$1) ORDER BY occurred_at DESC LIMIT 200", object_id)
        .fetch_all(pool).await.map_err(db)?;
    let mut items = Vec::new();
    for r in rows {
        let outcome = business_query_required(r.outcome)?;
        items.push(json!({"id":r.id,"occurredAt":format_time(r.occurred_at)?,"actorType":r.actor_type,"actorId":r.actor_id,"action":r.action,"objectType":r.object_type,"objectId":r.object_id,"capability":r.capability,"outcome":outcome,"reason":r.reason,"requestId":r.request_id,"details":r.details,"eventHash":r.event_hash.trim(),"previousEventHash":r.previous_event_hash.map(|v|v.trim().to_owned())}));
    }
    Ok(
        json!({"items":items,"appliedFilters":parameters,"asOf":format_time(OffsetDateTime::now_utc())?}),
    )
}
