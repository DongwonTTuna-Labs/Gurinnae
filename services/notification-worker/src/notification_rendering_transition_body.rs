{
let rendering_id = event
    .payload
    .get("renderingId")
    .and_then(serde_json::Value::as_str)
    .and_then(|value| Uuid::parse_str(value).ok())
    .ok_or(WorkerError::Contract)?;
let state_name = event.payload.get("state").and_then(serde_json::Value::as_str).ok_or(WorkerError::Contract)?;
if state_name == "APPROVED"
    && let Some(queue) = event.payload.get("queue").filter(|value| value.is_object())
{
    sqlx::query_scalar::<_, serde_json::Value>("SELECT ops.queue_outbound_delivery_json($1::jsonb)")
        .bind(queue).fetch_one(&state.pool).await.map_err(|_| WorkerError::Database)?;
}
let changed = sqlx::query("UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' WHERE consumer='notification-worker' AND event_id=$1 AND processed_at IS NULL")
    .bind(event.id).execute(&state.pool).await.map_err(|_| WorkerError::Database)?.rows_affected();
if changed != 1 { return Err(WorkerError::Database); }
state.worker.complete(&state.pool, job, serde_json::json!({"renderingId":rendering_id,"state":state_name,"queued":state_name=="APPROVED"})).await.map_err(WorkerError::Job)
}
