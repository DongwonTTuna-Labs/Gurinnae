{
    let delivery_id = event
        .payload
        .get("deliveryId")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .unwrap_or(event.aggregate_id);
    let expected_version = event.aggregate_version;
    let worker_id = std::env::var("HOSTNAME")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| format!("notification-worker-{}", std::process::id()));
    let lease_token_hash = sha256_hex(Uuid::new_v4().to_string().as_bytes());
    let lease_seconds = event
        .payload
        .get("leaseSeconds")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(60);
    let transport_policy_version = event
        .payload
        .get("transportPolicyVersion")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("communication-v1")
        .to_owned();
    let snapshot = sqlx::query(
        "SELECT rendering_id,rendering_digest,rendered_sha256,channel,generation, \
                provider_config_id,provider_config_version,provider_configuration_digest, \
                provider_preflight_receipt_id,provider_preflight_receipt_digest \
           FROM ops.outbound_deliveries WHERE id=$1 AND version=$2",
    )
    .bind(delivery_id)
    .bind(expected_version)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let expected_generation: i64 = snapshot.try_get("generation").map_err(|_| WorkerError::Database)?;
    let attempt = sqlx::query(
        "SELECT (ops.claim_outbound_delivery_attempt(ROW($1::uuid,$2::text,$3::char(64),$4::bigint,$5::bigint,$6::integer,$7::text)::ops.outbound_delivery_claim_v1)).*",
    )
    .bind(delivery_id)
    .bind(&worker_id)
    .bind(&lease_token_hash)
    .bind(expected_version)
    .bind(expected_generation)
    .bind(lease_seconds)
    .bind(&transport_policy_version)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let attempt_id: Uuid = attempt.try_get("attempt_id").map_err(|_| WorkerError::Database)?;
    let provider_idempotency_key: String = attempt
        .try_get("provider_idempotency_key_sha256")
        .map_err(|_| WorkerError::Database)?;
    let rendering_id: Uuid = snapshot.try_get("rendering_id").map_err(|_| WorkerError::Database)?;
    let rendering_digest: String = snapshot.try_get("rendering_digest").map_err(|_| WorkerError::Database)?;
    let rendered_sha256: String = snapshot.try_get("rendered_sha256").map_err(|_| WorkerError::Database)?;
    let snapshot_channel: String = snapshot.try_get("channel").map_err(|_| WorkerError::Database)?;
    let envelope = sqlx::query(
        "SELECT rendered_envelope_ciphertext, encryption_key_id FROM ops.communication_renderings WHERE id=$1 AND rendering_digest=$2 AND rendered_sha256=$3 AND state='APPROVED'",
    )
    .bind(rendering_id)
    .bind(&rendering_digest)
    .bind(&rendered_sha256)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let token: Vec<u8> = envelope.try_get("rendered_envelope_ciphertext").map_err(|_| WorkerError::Database)?;
    let plaintext = decrypt_rendered_envelope(state, rendering_id, &token)?;
    let rendered: serde_json::Value = serde_json::from_slice(&plaintext).map_err(|_| WorkerError::Cryptography)?;
    let message = EmailMessage {
        from: rendered.get("from").and_then(serde_json::Value::as_str).unwrap_or(&state.from_email).to_owned(),
        to: rendered.get("to").and_then(serde_json::Value::as_str).ok_or(WorkerError::Contract)?.to_owned(),
        subject: rendered.get("subject").and_then(serde_json::Value::as_str).ok_or(WorkerError::Contract)?.to_owned(),
        text_body: rendered.get("textBody").and_then(serde_json::Value::as_str).ok_or(WorkerError::Contract)?.to_owned(),
        html_body: rendered.get("htmlBody").and_then(serde_json::Value::as_str).unwrap_or("").to_owned(),
    };
    let canonical_channel = event
        .payload
        .get("channel")
        .and_then(serde_json::Value::as_str)
        .unwrap_or(&snapshot_channel);
    if canonical_channel != snapshot_channel {
        return Err(WorkerError::Contract);
    }
    let channel = provider_adapter_channel(canonical_channel)?;
    let binding = ProviderBinding {
        config_id: snapshot.try_get("provider_config_id").map_err(|_| WorkerError::Database)?,
        config_version: snapshot.try_get("provider_config_version").map_err(|_| WorkerError::Database)?,
        configuration_digest: snapshot.try_get("provider_configuration_digest").map_err(|_| WorkerError::Database)?,
        preflight_id: snapshot.try_get("provider_preflight_receipt_id").map_err(|_| WorkerError::Database)?,
        preflight_digest: snapshot.try_get("provider_preflight_receipt_digest").map_err(|_| WorkerError::Database)?,
    };
    let provider_id = state
        .delivery
        .send_for_channel_with_binding(&message, &channel, &provider_idempotency_key, &binding)
        .await;
    let provider_id = match provider_id {
        Ok(value) => value,
        Err(_) => {
            // A timeout or transport error does not prove that the provider
            // rejected the request. Keep the immutable claim/lease in place,
            // let reconciliation inspect the provider idempotency key, and
            // retry only through the normal job lease path. Never mark the
            // inbox succeeded or synthesize a failed delivery receipt here.
            state
                .worker
                .fail(
                    &state.pool,
                    job,
                    "COMMUNICATION_PROVIDER_OUTCOME_UNKNOWN",
                    "provider outcome requires authenticated reconciliation",
                    true,
                    serde_json::json!({"deliveryId": delivery_id, "channel": channel}),
                )
                .await
                .map_err(WorkerError::Job)?;
            return Ok(());
        }
    };
    let provider_evidence_digest = sha256_hex(provider_id.as_bytes());
    let observation_key_digest = sha256_hex(
        format!("provider-response:{}:{}", attempt_id, provider_id).as_bytes(),
    );
    let observation = sqlx::query(
        "SELECT (ops.record_outbound_delivery_observation(ROW($1::uuid,$2::bigint,'PROVIDER_RESPONSE',$3::uuid,NULL::uuid,NULL::char(64),$4::char(64),'PROVIDER_RESPONSE','PROVIDER_ACCEPTED',$5::char(64),NULL::timestamptz)::ops.outbound_delivery_observation_v1)).*",
    )
    .bind(delivery_id)
    .bind(expected_version + 1)
    .bind(attempt_id)
    .bind(observation_key_digest)
    .bind(provider_evidence_digest)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let receipt_id: Uuid = observation
        .try_get("receipt_id")
        .map_err(|_| WorkerError::Database)?;
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
    )
    .bind(&event.consumer_id)
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
                "attemptId": attempt_id,
                "receiptId": receipt_id,
                "providerMessageId": provider_id
            }),
        )
        .await
        .map_err(WorkerError::Job)?;
    Ok(())
}
