{
    let intent_id = event
        .payload
        .get("intentId")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(WorkerError::Contract)?;
    let expected_version = event
        .payload
        .get("expectedVersion")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(1);
    let request_digest = event
        .payload
        .get("requestDigest")
        .and_then(serde_json::Value::as_str)
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .map(str::to_owned)
        .unwrap_or_else(|| sha256_hex(event.id.as_bytes()));
    let receipt = sqlx::query(
        "SELECT (ops.materialize_communication_intent(ROW($1::uuid,$2::bigint,$3::char(64))::ops.communication_intent_materialize_v1)).*",
    )
    .bind(intent_id)
    .bind(expected_version)
    .bind(request_digest)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let version: i64 = receipt.try_get("version").map_err(|_| WorkerError::Database)?;
    let rendering = event
        .payload
        .get("rendering")
        .filter(|value| value.is_object())
        .ok_or(WorkerError::Contract)?;
    let rendering = snake_case_contract(rendering);
    let rendering_receipt: serde_json::Value = sqlx::query_scalar(
        "SELECT ops.create_communication_rendering_json($1::jsonb)",
    )
    .bind(&rendering)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let rendering_id = rendering_receipt
        .get("rendering_id")
        .and_then(serde_json::Value::as_str)
        .ok_or(WorkerError::Contract)?;
    let rendering_digest = rendering_receipt
        .get("rendering_digest")
        .and_then(serde_json::Value::as_str)
        .ok_or(WorkerError::Contract)?;
    let approval = event
        .payload
        .get("approval")
        .filter(|value| value.is_object())
        .ok_or(WorkerError::Contract)?;
    let mut approval = snake_case_contract(approval);
    approval["rendering_id"] = serde_json::Value::String(rendering_id.to_owned());
    approval["expected_version"] = serde_json::json!(1);
    approval["target_state"] = serde_json::Value::String("APPROVED".to_owned());
    let transition_receipt: serde_json::Value = sqlx::query_scalar(
        "SELECT ops.transition_communication_rendering_json($1::jsonb)",
    )
    .bind(&approval)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let approved_version = transition_receipt
        .get("version")
        .and_then(serde_json::Value::as_i64)
        .ok_or(WorkerError::Contract)?;
    let queue_payload = event
        .payload
        .get("queue")
        .filter(|value| value.is_object())
        .ok_or(WorkerError::Contract)?;
    let mut queue_payload = snake_case_contract(queue_payload);
    queue_payload["intent_id"] = serde_json::Value::String(intent_id.to_string());
    queue_payload["rendering_id"] = serde_json::Value::String(rendering_id.to_owned());
    queue_payload["rendering_digest"] = serde_json::Value::String(rendering_digest.to_owned());
    queue_payload["expected_rendering_version"] = serde_json::json!(approved_version);
    // The queue owner re-checks every endpoint/provider/budget fence and is
    // the sole producer of communication.delivery_requested.v1.
    let queue_receipt: serde_json::Value = sqlx::query_scalar(
        "SELECT ops.queue_outbound_delivery_json($1::jsonb)",
    )
    .bind(&queue_payload)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let delivery_id = queue_receipt
        .get("delivery_id")
        .and_then(serde_json::Value::as_str)
        .ok_or(WorkerError::Contract)?;
    let delivery_event = sqlx::query_scalar::<_, Uuid>(
        "SELECT id FROM ops.outbox WHERE event_type='communication.delivery_requested.v1' AND aggregate_id=$1 ORDER BY id DESC LIMIT 1",
    )
    .bind(delivery_id)
    .fetch_optional(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    if delivery_event.is_none() {
        return Err(WorkerError::Database);
    }
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
        .complete(
            &state.pool,
            job,
            serde_json::json!({"intentId": intent_id, "materializedVersion": version, "renderingId": rendering_id, "renderingVersion": approved_version, "deliveryId": delivery_id}),
        )
        .await
        .map_err(WorkerError::Job)
}
