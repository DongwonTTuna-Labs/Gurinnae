async fn process_one(state: &State) -> Result<bool, WorkerError> {
    let Some(job) = state
        .worker
        .claim(&state.pool)
        .await
        .map_err(WorkerError::Job)?
    else {
        return Ok(false);
    };
    if job.job_type == "COMMUNICATION_PROVIDER_PREFLIGHT" {
        process_provider_preflight_claim(state, &job).await?;
        return Ok(true);
    }
    if job.job_type == "COMMUNICATION_PROVIDER_POLL" {
        process_provider_poll_claim(state, &job).await?;
        return Ok(true);
    }
    let event = match event_from_job(&job) {
        Ok(event) => event,
        Err(error) => {
            state
                .worker
                .fail(
                    &state.pool,
                    &job,
                    "INVALID_NOTIFICATION_EVENT",
                    &error,
                    false,
                    serde_json::json!({}),
                )
                .await
                .map_err(WorkerError::Job)?;
            return Ok(true);
        }
    };
    if inbox_processed(state, &event.consumer_id, event.id).await? {
        state
            .worker
            .complete(&state.pool, &job, serde_json::json!({"deduplicated":true}))
            .await
            .map_err(WorkerError::Job)?;
        return Ok(true);
    }
    if event.event_type == "projection.publication_applied.v1" {
        process_projection_applied(state, &job, &event).await?;
        return Ok(true);
    }
    if event.event_type == "notification.publication_created.v1" {
        process_publication_created(state, &job, &event).await?;
        return Ok(true);
    }
    if is_privacy_notification_event(&event.event_type) {
        process_privacy_notification_claim(state, &job, &event).await?;
        return Ok(true);
    }
    if let Some(processed) = process_communication_event(state, &job, &event).await? {
        return Ok(processed);
    }
    let delivery = prepare(state, &event).await;
    let (delivery_id, message) = match delivery {
        Ok(value) => value,
        Err(error) => {
            state
                .worker
                .fail(
                    &state.pool,
                    &job,
                    "NOTIFICATION_PREPARE_FAILED",
                    &error.to_string(),
                    !matches!(error, WorkerError::Cryptography | WorkerError::Contract),
                    serde_json::json!({}),
                )
                .await
                .map_err(WorkerError::Job)?;
            return Ok(true);
        }
    };
    deliver_prepared(state, &job, &event, delivery_id, message).await?;
    Ok(true)
}

async fn process_provider_preflight_claim(
    state: &State,
    job: &ClaimedJob,
) -> Result<(), WorkerError> {
    if let Err(error) = process_provider_preflight_job(state, job).await {
        let (error_code, error_detail, retryable) = match error {
            WorkerError::Delivery => (
                "COMMUNICATION_PROVIDER_PREFLIGHT_FAILED",
                "provider preflight egress failed",
                true,
            ),
            WorkerError::Database => (
                "COMMUNICATION_PROVIDER_PREFLIGHT_PERSISTENCE_FAILED",
                "provider preflight state could not be loaded",
                true,
            ),
            WorkerError::Contract => (
                "COMMUNICATION_PROVIDER_PREFLIGHT_CONTRACT_INVALID",
                "provider preflight job or receipt contract is invalid",
                false,
            ),
            WorkerError::Cryptography | WorkerError::Initialization => (
                "COMMUNICATION_PROVIDER_PREFLIGHT_INTERNAL_INVALID",
                "provider preflight worker state is invalid",
                false,
            ),
            WorkerError::Job(error) => return Err(WorkerError::Job(error)),
        };
        state
            .worker
            .fail(
                &state.pool,
                job,
                error_code,
                error_detail,
                retryable,
                serde_json::json!({
                    "providerConnectionTestId": job.payload.get("providerConnectionTestId"),
                    "providerConfigId": job.payload.get("providerConfigId"),
                }),
            )
            .await
            .map_err(WorkerError::Job)?;
    }
    Ok(())
}

async fn process_provider_poll_claim(state: &State, job: &ClaimedJob) -> Result<(), WorkerError> {
    if let Err(error) = process_provider_poll_job(state, job).await {
        let (error_code, error_detail, retryable) = match error {
            WorkerError::Delivery => (
                "COMMUNICATION_PROVIDER_POLL_FAILED",
                "authenticated provider poll failed",
                true,
            ),
            WorkerError::Database => (
                "COMMUNICATION_PROVIDER_POLL_PERSISTENCE_FAILED",
                "provider poll receipt persistence failed",
                true,
            ),
            WorkerError::Contract => (
                "COMMUNICATION_PROVIDER_POLL_CONTRACT_INVALID",
                "provider poll job or receipt contract is invalid",
                false,
            ),
            WorkerError::Cryptography | WorkerError::Initialization => (
                "COMMUNICATION_PROVIDER_POLL_INTERNAL_INVALID",
                "provider poll worker state is invalid",
                false,
            ),
            WorkerError::Job(error) => return Err(WorkerError::Job(error)),
        };
        state
            .worker
            .fail(
                &state.pool,
                job,
                error_code,
                error_detail,
                retryable,
                serde_json::json!({"deliveryId":job.payload.get("deliveryId")}),
            )
            .await
            .map_err(WorkerError::Job)?;
    }
    Ok(())
}

async fn process_provider_preflight_job(
    state: &State,
    job: &ClaimedJob,
) -> Result<(), WorkerError> {
    let test_id = pointer_uuid(&job.payload, "/providerConnectionTestId")
        .map_err(|_| WorkerError::Contract)?;
    let config_id =
        pointer_uuid(&job.payload, "/providerConfigId").map_err(|_| WorkerError::Contract)?;
    let row = sqlx::query!(
        "SELECT pc.version, btrim(pc.configuration_digest::text) AS configuration_digest \
           FROM ops.provider_connection_tests t \
           JOIN ops.communication_provider_bindings b ON b.generic_provider_id=t.provider_id \
           JOIN ops.communication_provider_configs pc \
             ON pc.id=b.communication_provider_config_id \
          WHERE t.id=$1 AND t.status IN ('QUEUED','RUNNING') \
            AND pc.id=$2",
        test_id,
        config_id,
    )
    .fetch_optional(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?
    .ok_or(WorkerError::Contract)?;
    let revision = ProviderRevision {
        config_id,
        config_version: row.version,
        configuration_digest: row.configuration_digest.ok_or(WorkerError::Database)?,
    };
    let receipt = state
        .delivery
        .preflight_provider_revision(test_id, &revision)
        .await
        .map_err(|_| WorkerError::Delivery)?;
    if receipt.provider_connection_test_id != test_id
        || receipt.provider_config_id != config_id
        || receipt.provider_config_version != revision.config_version
        || receipt.receipt_digest.len() != 64
        || !matches!(receipt.status.as_str(), "SUCCEEDED" | "FAILED")
    {
        return Err(WorkerError::Contract);
    }
    state
        .worker
        .complete(
            &state.pool,
            job,
            serde_json::json!({
                "providerConnectionTestId": receipt.provider_connection_test_id,
                "providerConfigId": receipt.provider_config_id,
                "providerConfigVersion": receipt.provider_config_version,
                "preflightReceiptId": receipt.receipt_id,
                "preflightReceiptDigest": receipt.receipt_digest,
                "status": receipt.status,
            }),
        )
        .await
        .map_err(WorkerError::Job)?;
    Ok(())
}

// COMMUNICATION_V1 dispatch path.  The database owner routine is the
// linearization point: it re-checks consent, provider activation/preflight,
// suppression and kill-switch fences and commits an immutable attempt before
// this function performs provider I/O.  A provider response is persisted only
// through the typed observation owner routine; no direct delivery/receipt DML
// is allowed from this worker.
include!("notification_typed_jobs.rs");
async fn deliver_prepared(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
    delivery_id: Uuid,
    message: EmailMessage,
) -> Result<(), WorkerError> {
    let channel = event
        .payload
        .get("channel")
        .or_else(|| event.payload.get("deliveryChannel"))
        .and_then(serde_json::Value::as_str)
        .map(str::to_ascii_uppercase)
        .unwrap_or_else(|| "EMAIL".to_owned());
    let provider_id = match state.delivery.send_for_channel(&message, &channel).await {
        Ok(value) => value,
        Err(_) => {
            let error_code = if channel == "EMAIL" {
                "SMTP_DELIVERY_FAILED"
            } else {
                "CHANNEL_DELIVERY_FAILED"
            };
            mark_failed(state, delivery_id, error_code).await?;
            state
                .worker
                .fail(
                    &state.pool,
                    job,
                    error_code,
                    "channel gateway delivery failed",
                    true,
                    serde_json::json!({"deliveryId":delivery_id}),
                )
                .await
                .map_err(WorkerError::Job)?;
            return Ok(());
        }
    };
    let mut transaction = state
        .pool
        .begin()
        .await
        .map_err(|_| WorkerError::Database)?;
    sqlx::query!(
        "UPDATE ops.email_deliveries SET status='DELIVERED',provider_message_id=$2,delivered_at=clock_timestamp() WHERE id=$1 AND status='SENDING'",
        delivery_id,
        &provider_id,
    )
    .execute(&mut *transaction)
    .await
    .map_err(|_| WorkerError::Database)?;
    let completed = sqlx::query!(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
        &event.consumer_id,
        event.id,
    )
    .execute(&mut *transaction)
    .await
    .map_err(|_| WorkerError::Database)?
    .rows_affected();
    if completed != 1 {
        return Err(WorkerError::Database);
    }
    transaction
        .commit()
        .await
        .map_err(|_| WorkerError::Database)?;
    state
        .worker
        .complete(
            &state.pool,
            job,
            serde_json::json!({"deliveryId":delivery_id,"providerMessageId":provider_id}),
        )
        .await
        .map_err(WorkerError::Job)?;

    tracing::info!(event_id=%event.id,event_type=%event.event_type,"notification delivered");
    Ok(())
}

fn event_from_job(job: &ClaimedJob) -> Result<ClaimedEvent, String> {
    if job.job_type != "EVENT_DELIVERY" {
        return Err(format!("unsupported job type {}", job.job_type));
    }
    let event_id = pointer_uuid(&job.payload, "/eventId")?;
    let consumer_id = job
        .payload
        .get("consumerId")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "consumerId is missing".to_owned())?;
    let event_type = job
        .payload
        .get("eventType")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "eventType is missing".to_owned())?;
    let aggregate_id = pointer_uuid(&job.payload, "/aggregateId")?;
    let aggregate_version = job
        .payload
        .get("aggregateVersion")
        .and_then(serde_json::Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| "aggregateVersion is missing or invalid".to_owned())?;
    let payload = job
        .payload
        .get("payload")
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| "payload is missing or invalid".to_owned())?;
    Ok(ClaimedEvent {
        consumer_id: consumer_id.to_owned(),
        id: event_id,
        event_type: event_type.to_owned(),
        aggregate_id,
        aggregate_version,
        payload,
    })
}

fn pointer_uuid(value: &serde_json::Value, pointer: &str) -> Result<Uuid, String> {
    value
        .pointer(pointer)
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| format!("{pointer} is missing or invalid"))
}

async fn inbox_processed(
    state: &State,
    consumer_id: &str,
    event_id: Uuid,
) -> Result<bool, WorkerError> {
    sqlx::query_scalar!(
        "SELECT processed_at IS NOT NULL FROM ops.inbox \
         WHERE consumer=$1 AND event_id=$2",
        consumer_id,
        event_id,
    )
    .fetch_optional(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?
    .flatten()
    .ok_or(WorkerError::Database)
}

async fn process_projection_applied(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    let expected = job
        .payload
        .pointer("/payload/public_payload_sha256")
        .and_then(serde_json::Value::as_str)
        .ok_or(WorkerError::Database)?;
    let actual: String = sqlx::query_scalar!(
        "SELECT public_payload_sha256 FROM editorial.publication_revisions WHERE id=$1",
        event.aggregate_id,
    )
    .fetch_optional(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?
    .ok_or(WorkerError::Database)?;
    if actual.trim() != expected {
        state
            .worker
            .fail(
                &state.pool,
                job,
                "PUBLICATION_PROJECTION_DIGEST_MISMATCH",
                "projection event digest does not match immutable publication revision",
                false,
                serde_json::json!({}),
            )
            .await
            .map_err(WorkerError::Job)?;
        return Ok(());
    }
    let changed = sqlx::query!(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
        &event.consumer_id,
        event.id,
    )
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
            serde_json::json!({"publicationRevisionId":event.aggregate_id,"notifiedSubscribers":0}),
        )
        .await
        .map_err(WorkerError::Job)?;
    tracing::info!(event_id=%event.id,publication_revision_id=%event.aggregate_id,"publication projection notification reconciled");
    Ok(())
}

include!("publication_fanout.rs");
