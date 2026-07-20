{
    let receipt = if let Some(rendering) = event.payload.get("rendering").filter(|v| v.is_object()) {
        sqlx::query_scalar::<_, serde_json::Value>(
            "SELECT ops.create_communication_rendering_json($1::jsonb)",
        )
        .bind(snake_case_contract(rendering))
        .fetch_one(&state.pool)
        .await
        .map_err(|_| WorkerError::Database)?
    } else {
        // The intent owner may have completed rendering and queue admission in
        // one transaction; its flat outbox event is an idempotent wake-up.
        serde_json::json!({"reconciled": true})
    };
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' WHERE consumer='notification-worker' AND event_id=$1 AND processed_at IS NULL",
    )
    .bind(event.id)
    .execute(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?
    .rows_affected();
    if changed != 1 {
        return Err(WorkerError::Database);
    }
    state
        .worker
        .complete(&state.pool, job, serde_json::json!({"rendering": receipt}))
        .await
        .map_err(WorkerError::Job)
}
