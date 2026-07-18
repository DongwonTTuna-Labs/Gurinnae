async fn process_one(state: &State) -> Result<bool, WorkerError> {
    let Some(job) = state
        .worker
        .claim(&state.pool)
        .await
        .map_err(WorkerError::Job)?
    else {
        return Ok(false);
    };
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
    if inbox_processed(state, event.id).await? {
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

async fn deliver_prepared(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
    delivery_id: Uuid,
    message: EmailMessage,
) -> Result<(), WorkerError> {
    let provider_id = match state.delivery.send(&message).await {
        Ok(value) => value,
        Err(_) => {
            mark_failed(state, delivery_id, "SMTP_DELIVERY_FAILED").await?;
            state
                .worker
                .fail(
                    &state.pool,
                    job,
                    "SMTP_DELIVERY_FAILED",
                    "SMTP gateway delivery failed",
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
    sqlx::query(
        "UPDATE ops.email_deliveries SET status='DELIVERED',provider_message_id=$2,delivered_at=clock_timestamp() WHERE id=$1 AND status='SENDING'",
    )
    .bind(delivery_id)
    .bind(&provider_id)
    .execute(&mut *transaction)
    .await
    .map_err(|_| WorkerError::Database)?;
    let completed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='notification-worker' AND event_id=$1 AND processed_at IS NULL",
    )
    .bind(event.id)
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
    let event_type = job
        .payload
        .get("eventType")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "eventType is missing".to_owned())?;
    let aggregate_id = pointer_uuid(&job.payload, "/aggregateId")?;
    let payload = job
        .payload
        .get("payload")
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| "payload is missing or invalid".to_owned())?;
    Ok(ClaimedEvent {
        id: event_id,
        event_type: event_type.to_owned(),
        aggregate_id,
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

async fn inbox_processed(state: &State, event_id: Uuid) -> Result<bool, WorkerError> {
    sqlx::query_scalar(
        "SELECT processed_at IS NOT NULL FROM ops.inbox \
         WHERE consumer='notification-worker' AND event_id=$1",
    )
    .bind(event_id)
    .fetch_optional(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?
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
    let actual: String = sqlx::query_scalar(
        "SELECT public_payload_sha256 FROM editorial.publication_revisions WHERE id=$1",
    )
    .bind(event.aggregate_id)
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
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='notification-worker' AND event_id=$1 AND processed_at IS NULL",
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
            serde_json::json!({"publicationRevisionId":event.aggregate_id,"notifiedSubscribers":0}),
        )
        .await
        .map_err(WorkerError::Job)?;
    tracing::info!(event_id=%event.id,publication_revision_id=%event.aggregate_id,"publication projection notification reconciled");
    Ok(())
}

async fn process_publication_created(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
) -> Result<(), WorkerError> {
    let case = sqlx::query("SELECT public_slug,title FROM editorial.cases WHERE id=$1")
        .bind(event.aggregate_id)
        .fetch_optional(&state.pool)
        .await
        .map_err(|_| WorkerError::Database)?
        .ok_or(WorkerError::Database)?;
    let slug: Option<String> = case
        .try_get("public_slug")
        .map_err(|_| WorkerError::Database)?;
    let title: String = case.try_get("title").map_err(|_| WorkerError::Database)?;
    let subscriptions = sqlx::query(
        "SELECT id,email_encrypted,locale FROM intake.subscriptions \
         WHERE status='ACTIVE' AND frequency='IMMEDIATE' ORDER BY id",
    )
    .fetch_all(&state.pool)
    .await
    .map_err(|_| WorkerError::Database)?;
    let url = format!(
        "{}/cases/{}",
        state.public_base_url,
        slug.unwrap_or_else(|| event.aggregate_id.to_string())
    );
    let mut delivered = 0_u64;
    for subscription in subscriptions {
        match deliver_publication_subscriber(state, job, event, &title, &url, &subscription).await?
        {
            Some(count) => delivered += count,
            None => return Ok(()),
        }
    }
    let changed = sqlx::query(
        "UPDATE ops.inbox SET processed_at=clock_timestamp(),result='SUCCEEDED' \
         WHERE consumer='notification-worker' AND event_id=$1 AND processed_at IS NULL",
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
            serde_json::json!({"deliveredSubscribers":delivered}),
        )
        .await
        .map_err(WorkerError::Job)?;
    tracing::info!(event_id=%event.id,case_id=%event.aggregate_id,delivered,"publication notification fanout completed");
    Ok(())
}

async fn deliver_publication_subscriber(
    state: &State,
    job: &ClaimedJob,
    event: &ClaimedEvent,
    title: &str,
    url: &str,
    subscription: &sqlx::postgres::PgRow,
) -> Result<Option<u64>, WorkerError> {
    let subscription_id: Uuid = subscription
        .try_get("id")
        .map_err(|_| WorkerError::Database)?;
    let encrypted: Vec<u8> = subscription
        .try_get("email_encrypted")
        .map_err(|_| WorkerError::Database)?;
    let to = decrypt_email(
        state,
        "intake.subscriptions",
        "email_encrypted",
        subscription_id,
        &encrypted,
    )?;
    let recipient_hash = sha256_hex(to.as_bytes());
    let row = sqlx::query(
            "INSERT INTO ops.email_deliveries(message_type,recipient_hash,template_version, \
             object_type,object_id,status,attempt_count) \
             VALUES($1,$2,'v1','publication',$3,'SENDING',1) \
             ON CONFLICT(message_type,object_id,recipient_hash) WHERE object_id IS NOT NULL \
             DO UPDATE SET status=CASE WHEN ops.email_deliveries.status='DELIVERED' \
               THEN 'DELIVERED' ELSE 'SENDING' END, \
               attempt_count=CASE WHEN ops.email_deliveries.status='DELIVERED' \
                 THEN ops.email_deliveries.attempt_count ELSE ops.email_deliveries.attempt_count+1 END, \
               last_error_code=NULL RETURNING id,status",
        )
        .bind(&event.event_type)
        .bind(recipient_hash)
        .bind(event.aggregate_id)
        .fetch_one(&state.pool)
        .await
        .map_err(|_| WorkerError::Database)?;
    let delivery_id: Uuid = row.try_get("id").map_err(|_| WorkerError::Database)?;
    let status: String = row.try_get("status").map_err(|_| WorkerError::Database)?;
    if status == "DELIVERED" {
        return Ok(Some(1));
    }
    let message = EmailMessage {
        from: state.from_email.clone(),
        to,
        subject: format!("구린네 새 공개: {title}"),
        text_body: format!("새 사건 공개가 게시되었습니다: {title}\n{url}"),
        html_body: format!(
            "<p>새 사건 공개가 게시되었습니다: {title}</p><p><a href=\"{url}\">내용 보기</a></p>"
        ),
    };
    match state.delivery.send(&message).await {
        Ok(provider_id) => {
            sqlx::query(
                "UPDATE ops.email_deliveries SET status='DELIVERED',provider_message_id=$2, \
                     delivered_at=clock_timestamp() WHERE id=$1 AND status='SENDING'",
            )
            .bind(delivery_id)
            .bind(provider_id)
            .execute(&state.pool)
            .await
            .map_err(|_| WorkerError::Database)?;
            Ok(Some(1))
        }
        Err(_) => {
            mark_failed(state, delivery_id, "SMTP_DELIVERY_FAILED").await?;
            state
                .worker
                .fail(
                    &state.pool,
                    job,
                    "SMTP_DELIVERY_FAILED",
                    "publication subscriber delivery failed",
                    true,
                    serde_json::json!({"deliveryId":delivery_id}),
                )
                .await
                .map_err(WorkerError::Job)?;
            Ok(None)
        }
    }
}
