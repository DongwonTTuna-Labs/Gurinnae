{
    let delivery_id = event
        .payload
        .get("deliveryId")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .unwrap_or(event.aggregate_id);
    let expected_version = event
        .payload
        .get("expectedDeliveryVersion")
        .and_then(serde_json::Value::as_i64)
        .ok_or(WorkerError::Contract)?;
    let source_receipt_id = event
        .payload
        .get("sourceReceiptId")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(WorkerError::Contract)?;
    let source_receipt_digest = event
        .payload
        .get("sourceReceiptDigest")
        .and_then(serde_json::Value::as_str)
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or(WorkerError::Contract)?;
    let source_kind = match event.event_type.as_str() {
        "communication.delivery_callback.v1" => "PROVIDER_CALLBACK",
        "communication.delivery_poll.v1" => "PROVIDER_POLL",
        "communication.delivery_reconciliation.v1" => "RECONCILIATION_DECISION",
        _ => return Err(WorkerError::Contract),
    };
    let evidence_kind = match source_kind {
        "PROVIDER_CALLBACK" => "SIGNED_PROVIDER_CALLBACK",
        "PROVIDER_POLL" => "AUTHENTICATED_PROVIDER_POLL",
        _ => "RECONCILIATION_PROOF",
    };
    let asserted_state = event
        .payload
        .get("assertedState")
        .and_then(serde_json::Value::as_str)
        .ok_or(WorkerError::Contract)?;
    let provider_evidence_digest = event
        .payload
        .get("providerEvidenceDigest")
        .and_then(serde_json::Value::as_str)
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or(WorkerError::Contract)?;
    let observation_key_digest = event
        .payload
        .get("observationKeyDigest")
        .and_then(serde_json::Value::as_str)
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .map(str::to_owned)
        .unwrap_or_else(|| sha256_hex(format!("{}:{}", event.id, source_receipt_id).as_bytes()));
    let observed_at = event
        .payload
        .get("providerOccurredAt")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| {
            time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339)
                .ok()
        });
    let observation = sqlx::query(
        "SELECT (ops.record_outbound_delivery_observation(ROW($1::uuid,$2::bigint,$3::text,NULL::uuid,$4::uuid,$5::char(64),$6::char(64),$7::text,$8::text,$9::char(64),$10::timestamptz)::ops.outbound_delivery_observation_v1)).*",
    )
    .bind(delivery_id)
    .bind(expected_version)
    .bind(source_kind)
    .bind(source_receipt_id)
    .bind(source_receipt_digest)
    .bind(&observation_key_digest)
    .bind(evidence_kind)
    .bind(asserted_state)
    .bind(provider_evidence_digest)
    .bind(observed_at)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let receipt_id: Uuid = observation
        .try_get("receipt_id")
        .map_err(|_| WorkerError::Database)?;
    let completed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' WHERE consumer='notification-worker' AND event_id=$1 AND processed_at IS NULL",
    )
    .bind(event.id)
    .execute(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?
    .rows_affected();
    if completed != 1 {
        return Err(WorkerError::Database);
    }
    state
        .worker
        .complete(
            &state.pool,
            job,
            serde_json::json!({"deliveryId": delivery_id, "receiptId": receipt_id}),
        )
        .await
    .map_err(WorkerError::Job)
}
