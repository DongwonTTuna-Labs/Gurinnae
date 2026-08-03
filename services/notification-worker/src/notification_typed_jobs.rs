fn snake_case_contract(value: &serde_json::Value) -> serde_json::Value {
    let Some(object) = value.as_object() else {
        return value.clone();
    };
    let mut output = serde_json::Map::new();
    for (key, value) in object {
        let mapped = match key.as_str() {
            "intentId" => "intent_id", "endpointId" => "endpoint_id",
            "endpointVersion" => "endpoint_version", "endpointSnapshotDigest" => "endpoint_snapshot_digest",
            "templateId" => "template_id", "templateRevision" => "template_revision",
            "variableSet" => "variable_set", "attachmentManifest" => "attachment_manifest",
            "disclosureClass" => "disclosure_class", "semanticPayloadDigest" => "semantic_payload_digest",
            "recipientBindingDigest" => "recipient_binding_digest", "renderedEnvelopeCiphertext" => "rendered_envelope_ciphertext",
            "encryptionKeyId" => "encryption_key_id", "renderedSha256" => "rendered_sha256",
            "renderedByteLength" => "rendered_byte_length", "transportContentType" => "transport_content_type",
            "expiresAt" => "expires_at", "requestDigest" => "request_digest", "expectedVersion" => "expected_version",
            "targetState" => "target_state", "approvalKind" => "approval_kind", "approvalDigest" => "approval_digest",
            "policyDecisionDigest" => "policy_decision_digest", "approvalReceiptDigest" => "approval_receipt_digest",
            "approvalExpiresAt" => "approval_expires_at", "deliveryKey" => "delivery_key",
            "intentDigest" => "intent_digest", "intentSourceDecisionDigest" => "intent_source_decision_digest",
            "renderingDigest" => "rendering_digest", "providerConfigId" => "provider_config_id",
            "providerConfigVersion" => "provider_config_version", "providerConfigurationDigest" => "provider_configuration_digest",
            "providerPreflightReceiptId" => "provider_preflight_receipt_id", "providerPreflightReceiptDigest" => "provider_preflight_receipt_digest",
            "recipientEndpointHmac" => "recipient_endpoint_hmac", "authorizationSnapshotDigest" => "authorization_snapshot_digest",
            "activationReceiptDigest" => "activation_receipt_digest", "budgetReservationId" => "budget_reservation_id",
            "providerIdempotencyKeyCiphertext" => "provider_idempotency_key_ciphertext", "providerKeyEncryptionKeyId" => "provider_key_encryption_key_id",
            "providerIdempotencyKeySha256" => "provider_idempotency_key_sha256", "suppressionSnapshotDigest" => "suppression_snapshot_digest",
            "effectSafetyClass" => "effect_safety_class", "notBefore" => "not_before", _ => key,
        };
        let normalized = if matches!(mapped, "provider_idempotency_key_ciphertext" | "rendered_envelope_ciphertext") {
            value.as_str().and_then(|encoded| {
                base64::engine::general_purpose::STANDARD
                    .decode(encoded)
                    .or_else(|_| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(encoded))
                    .ok()
                    .map(|bytes| {
                        serde_json::Value::String(
                            bytes.iter().map(|byte| format!("{byte:02x}")).collect(),
                        )
                    })
            }).unwrap_or_else(|| value.clone())
        } else {
            value.clone()
        };
        output.insert(mapped.to_owned(), normalized);
    }
    serde_json::Value::Object(output)
}

async fn process_communication_event(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<Option<bool>, WorkerError> {
    match event.event_type.as_str() {
        "communication.delivery_requested.v1" => {
            process_typed_communication_delivery(state, job, event).await?
        }
        "communication.intent_created.v1" => {
            process_typed_communication_intent(state, job, event).await?
        }
        "communication.intent_materialized.v1" => {
            process_typed_communication_rendering(state, job, event).await?
        }
        "communication.rendering_created.v1" => {
            process_typed_communication_rendering_created(state, job, event).await?
        }
        "communication.rendering_transition.v1" => {
            process_typed_communication_rendering_transition(state, job, event).await?
        }
        "communication.delivery_callback.v1"
        | "communication.delivery_poll.v1"
        | "communication.delivery_reconciliation.v1" => {
            process_typed_communication_observation(state, job, event).await?
        }
        "communication.delivery_poll_requested.v1" => {
            process_typed_communication_poll_requested(state, job, event).await?
        }
        "communication.callback_received.v1" => {
            process_typed_communication_callback(state, job, event).await?
        }
        _ => return Ok(None),
    };
    Ok(Some(true))
}

/// Applies delivery-observation items from the authenticated callback ledger.
/// The gateway/owner first commits the immutable callback event; this handler
/// then binds each matched item to the exact delivery version and enters the
/// same observation owner routine used by explicit poll/reconciliation paths.
async fn process_typed_communication_callback(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    let callback_id = event
        .payload
        .get("callbackEventId")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(WorkerError::Contract)?;
    let callback_digest: String = sqlx::query_scalar(
        "SELECT callback_digest FROM ops.communication_callback_events WHERE id=$1",
    )
    .bind(callback_id)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let items: serde_json::Value = sqlx::query_scalar(
        "SELECT normalized_items FROM ops.communication_callback_events WHERE id=$1",
    )
    .bind(callback_id)
    .fetch_one(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let Some(items) = items.get("items").and_then(serde_json::Value::as_array) else {
        return Err(WorkerError::Contract);
    };
    for item in items {
        apply_callback_item(state, callback_id, &callback_digest, item).await?;
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
            serde_json::json!({"callbackEventId": callback_id}),
        )
        .await
        .map_err(WorkerError::Job)
}

async fn apply_callback_item(
    state: &State,
    callback_id: Uuid,
    callback_digest: &str,
    item: &serde_json::Value,
) -> Result<(), WorkerError> {
    if item.get("effectKind").and_then(serde_json::Value::as_str)
        != Some("DELIVERY_OBSERVATION") {
        return Ok(());
    }
    let Some(delivery_id) = item.get("matchedDeliveryId")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok()) else { return Ok(()); };
    let expected_version: i64 = sqlx::query_scalar(
        "SELECT version FROM ops.outbound_deliveries WHERE id=$1",
    ).bind(delivery_id).fetch_one(&state.pool).await
        .map_err(|_| WorkerError::Database)?;
    let asserted_state = item.get("assertedState")
        .and_then(serde_json::Value::as_str).ok_or(WorkerError::Contract)?;
    let evidence_digest = valid_digest(item, "normalizedEvidenceDigest")?;
    let observation_key = valid_digest(item, "itemDigest")?;
    sqlx::query(
        "SELECT (ops.record_outbound_delivery_observation(ROW($1::uuid,$2::bigint,'PROVIDER_CALLBACK',NULL::uuid,$3::uuid,$4::char(64),$5::char(64),'SIGNED_PROVIDER_CALLBACK',$6::text,$7::char(64),NULL::timestamptz)::ops.outbound_delivery_observation_v1)).*",
    ).bind(delivery_id).bind(expected_version).bind(callback_id).bind(callback_digest)
        .bind(observation_key).bind(asserted_state).bind(evidence_digest)
        .fetch_one(&state.pool).await.map_err(|_| WorkerError::Database)?;
    Ok(())
}

fn valid_digest<'a>(item: &'a serde_json::Value, name: &str) -> Result<&'a str, WorkerError> {
    item.get(name).and_then(serde_json::Value::as_str)
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or(WorkerError::Contract)
}

async fn process_typed_communication_delivery(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    include!("notification_typed_delivery_body.rs")
}

async fn process_typed_communication_intent(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    include!("notification_intent_materialize_body.rs")
}

async fn process_typed_communication_rendering(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    include!("notification_rendering_materialize_body.rs")
}

async fn process_typed_communication_rendering_created(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    include!("notification_rendering_created_body.rs")
}

async fn process_typed_communication_rendering_transition(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    include!("notification_rendering_transition_body.rs")
}
/// Records an authenticated callback/poll/reconciliation observation through
/// the same SECURITY DEFINER owner routine as the synchronous provider
/// response.  The callback/poll producer must first persist its immutable
/// source receipt; this worker only forwards the composite identity and never
/// treats an unbound provider payload as evidence.
async fn process_typed_communication_observation(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    include!("notification_typed_observation_body.rs")
}

async fn process_typed_communication_poll_requested(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    include!("notification_typed_poll_requested_body.rs")
}
