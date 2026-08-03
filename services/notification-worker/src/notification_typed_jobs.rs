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
        "communication.delivery_receipt_recorded.v1" => {
            complete_communication_receipt_notification(state, job, event).await?
        }
        "communication.authorization_changed.v1"
        | "communication.subscription_update_requested.v1" => {
            complete_communication_notification(state, job, event).await?
        }
        _ => return Ok(None),
    };
    Ok(Some(true))
}

async fn complete_communication_notification(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
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
            serde_json::json!({"eventType":event.event_type,"aggregateId":event.aggregate_id}),
        )
        .await
        .map_err(WorkerError::Job)
}

async fn complete_communication_receipt_notification(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer=$1 AND event_id=$2 AND processed_at IS NULL",
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
            serde_json::json!({"deliveryId":event.aggregate_id,"deliveryVersion":event.aggregate_version}),
        )
        .await
        .map_err(WorkerError::Job)
}

async fn process_provider_poll_job(
    state: &State,
    job: &ClaimedJob,
) -> Result<(), WorkerError> {
    include!("notification_typed_poll_requested_body.rs")
}

fn provider_adapter_channel(channel: &str) -> Result<&'static str, WorkerError> {
    match channel {
        "SMTP_EMAIL" => Ok("EMAIL"),
        "TELEGRAM_BOT_API" => Ok("TELEGRAM"),
        "META_WHATSAPP_BUSINESS_CLOUD" => Ok("WHATSAPP"),
        "LINE_MESSAGING_API" => Ok("LINE"),
        "SOLAPI_SMS" => Ok("SMS"),
        "SOLAPI_KAKAO_BIZMESSAGE" => Ok("KAKAO"),
        "TWILIO_VOICE" => Ok("VOICE"),
        "SIGNED_WEBHOOK" => Ok("WEBHOOK"),
        _ => Err(WorkerError::Contract),
    }
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
