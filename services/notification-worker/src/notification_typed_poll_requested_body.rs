{
    let delivery_id = event
        .payload
        .get("deliveryId")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(WorkerError::Contract)?;
    let expected_version = event
        .payload
        .get("expectedDeliveryVersion")
        .and_then(serde_json::Value::as_i64)
        .ok_or(WorkerError::Contract)?;
    let channel = event
        .payload
        .get("channel")
        .and_then(serde_json::Value::as_str)
        .ok_or(WorkerError::Contract)?
        .to_ascii_uppercase();
    let provider_message_id = event
        .payload
        .get("providerMessageId")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or(WorkerError::Contract)?;
    let binding = ProviderBinding {
        config_id: event
            .payload
            .get("providerConfigId")
            .and_then(serde_json::Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .ok_or(WorkerError::Contract)?,
        config_version: event
            .payload
            .get("providerConfigVersion")
            .and_then(serde_json::Value::as_i64)
            .ok_or(WorkerError::Contract)?,
        configuration_digest: event
            .payload
            .get("providerConfigurationDigest")
            .and_then(serde_json::Value::as_str)
            .ok_or(WorkerError::Contract)?
            .to_owned(),
        preflight_id: event
            .payload
            .get("providerPreflightReceiptId")
            .and_then(serde_json::Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            .ok_or(WorkerError::Contract)?,
        preflight_digest: event
            .payload
            .get("providerPreflightReceiptDigest")
            .and_then(serde_json::Value::as_str)
            .ok_or(WorkerError::Contract)?
            .to_owned(),
    };
    let receipt = state
        .delivery
        .poll_for_channel_with_binding(&channel, provider_message_id, &binding)
        .await
        .map_err(|_| WorkerError::Database)?;
    let source_payload = serde_json::json!({
        "deliveryId": delivery_id,
        "expectedDeliveryVersion": expected_version,
        "assertedState": receipt.asserted_state,
        "providerEvidenceDigest": receipt.provider_evidence_digest,
        "providerOccurredAt": event.payload.get("providerOccurredAt"),
    });
    let source: serde_json::Value = sqlx::query_scalar(
        "SELECT ops.record_provider_poll_source_receipt_v1($1::jsonb)",
    )
    .bind(source_payload)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
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
            serde_json::json!({
                "deliveryId": delivery_id,
                "sourceReceiptId": source.get("sourceReceiptId"),
                "sourceReceiptDigest": source.get("sourceReceiptDigest"),
                "emittedEventId": source.get("emittedEventId"),
            }),
        )
        .await
        .map_err(WorkerError::Job)
}
