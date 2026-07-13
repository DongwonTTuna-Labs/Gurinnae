use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use gurine_auth::{
    assertion::canonical::sha256_hex,
    envelope::{EnvelopeKey, EnvelopeKeyRing, decrypt},
};
use gurine_email::{port::EmailMessage, templates::escape_html};
use gurine_jobs::postgres::{ClaimedJob, JobError, Worker};
use gurine_persistence_postgres::pool::{PoolConfig, connect};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use sqlx::{PgPool, Row};
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroize;

use crate::{
    config::{Config, EmailAdapter},
    handlers::delivery::{DeliveryGateway, FileGateway, SmtpGateway},
};

struct State {
    pool: PgPool,
    field_keys: EnvelopeKeyRing,
    token_hmac_key: Vec<u8>,
    delivery: DeliveryGateway,
    from_email: String,
    reply_to: String,
    public_base_url: String,
    response_base_url: String,
    worker: Worker,
}

struct ClaimedEvent {
    id: Uuid,
    event_type: String,
    aggregate_id: Uuid,
    payload: serde_json::Value,
}

#[derive(Debug, Error)]
pub enum WorkerError {
    #[error("notification worker initialization failed")]
    Initialization,
    #[error("notification worker database operation failed")]
    Database,
    #[error("notification worker cryptography failed")]
    Cryptography,
    #[error("notification event contract is invalid")]
    Contract,
    #[error("notification delivery failed")]
    Delivery,
    #[error("notification job operation failed")]
    Job(#[source] JobError),
}

pub async fn run(config: Config) -> Result<(), WorkerError> {
    let state = State {
        pool: connect(&PoolConfig {
            database_url: config.database_url.clone(),
            max_connections: 4,
            acquire_timeout: std::time::Duration::from_secs(10),
        })
        .await
        .map_err(|_| WorkerError::Initialization)?,
        field_keys: EnvelopeKeyRing {
            current: EnvelopeKey::new(config.field_key_current),
            previous: config.field_key_previous.map(EnvelopeKey::new),
        },
        token_hmac_key: config.token_hmac_key.clone(),
        delivery: match config.email_adapter {
            EmailAdapter::File => DeliveryGateway::File(
                FileGateway::new(
                    config
                        .email_file_outbox
                        .clone()
                        .ok_or(WorkerError::Initialization)?,
                )
                .map_err(|_| WorkerError::Initialization)?,
            ),
            EmailAdapter::Smtp => DeliveryGateway::Smtp(
                SmtpGateway::new(config.smtp_egress_url.clone())
                    .map_err(|_| WorkerError::Initialization)?,
            ),
        },
        from_email: config.from_email.clone(),
        reply_to: config.reply_to.clone(),
        public_base_url: config.public_base_url.clone(),
        response_base_url: config.response_base_url.clone(),
        worker: Worker::new(
            std::env::var("HOSTNAME")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| format!("notification-worker-{}", std::process::id())),
            "notification-worker".to_owned(),
            std::time::Duration::from_secs(
                u64::try_from(config.lease_seconds).map_err(|_| WorkerError::Initialization)?,
            ),
        )
        .map_err(WorkerError::Job)?,
    };
    loop {
        let processed = process_one(&state).await?;
        if config.once {
            if !processed {
                return Ok(());
            }
        } else if !processed {
            tokio::time::sleep(config.poll_interval).await;
        }
    }
}

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
    let provider_id = match state.delivery.send(&message).await {
        Ok(value) => value,
        Err(_) => {
            mark_failed(state, delivery_id, "SMTP_DELIVERY_FAILED").await?;
            state
                .worker
                .fail(
                    &state.pool,
                    &job,
                    "SMTP_DELIVERY_FAILED",
                    "SMTP gateway delivery failed",
                    true,
                    serde_json::json!({"deliveryId":delivery_id}),
                )
                .await
                .map_err(WorkerError::Job)?;
            return Ok(true);
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
            &job,
            serde_json::json!({"deliveryId":delivery_id,"providerMessageId":provider_id}),
        )
        .await
        .map_err(WorkerError::Job)?;
    tracing::info!(event_id=%event.id,event_type=%event.event_type,"notification delivered");
    Ok(true)
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
            delivered += 1;
            continue;
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
                delivered += 1;
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
                return Ok(());
            }
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

async fn prepare(state: &State, event: &ClaimedEvent) -> Result<(Uuid, EmailMessage), WorkerError> {
    let (to, subject, text, html) = match event.event_type.as_str() {
        "attachment.scan_completed.v1" => {
            let attachment_id = pointer_uuid(&event.payload, "/attachment_id")
                .map_err(|_| WorkerError::Contract)?;
            if attachment_id != event.aggregate_id {
                return Err(WorkerError::Contract);
            }
            let status = event
                .payload
                .get("scan_status")
                .and_then(serde_json::Value::as_str)
                .filter(|value| matches!(*value, "CLEAN" | "INFECTED" | "FAILED"))
                .ok_or(WorkerError::Contract)?;
            let digest = event
                .payload
                .get("sha256")
                .and_then(serde_json::Value::as_str)
                .filter(|value| {
                    value.len() == 64
                        && value
                            .bytes()
                            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
                })
                .ok_or(WorkerError::Contract)?;
            (
                state.reply_to.clone(),
                format!("구린네 첨부 검사 결과: {status}"),
                format!(
                    "첨부 {} 검사 상태: {status}, SHA-256: {}",
                    event.aggregate_id, digest
                ),
                format!(
                    "<p>첨부 {} 검사 상태: <strong>{status}</strong></p><p>SHA-256: {}</p>",
                    event.aggregate_id, digest
                ),
            )
        }
        "intake.contact_received.v1" => {
            let subject: String =
                sqlx::query_scalar("SELECT subject FROM intake.contact_requests WHERE id=$1")
                    .bind(event.aggregate_id)
                    .fetch_optional(&state.pool)
                    .await
                    .map_err(|_| WorkerError::Database)?
                    .ok_or(WorkerError::Database)?;
            let html_subject = escape_html(&subject);
            (
                state.reply_to.clone(),
                "구린네 새 문의 접수".to_owned(),
                format!(
                    "새 문의가 접수되었습니다. ID: {}\n제목: {subject}",
                    event.aggregate_id
                ),
                format!(
                    "<p>새 문의가 접수되었습니다.</p><p>ID: {}</p><p>제목: {html_subject}</p>",
                    event.aggregate_id,
                ),
            )
        }
        "notification.subscription_verification_requested.v1" => {
            let verification = derived_token(
                &state.token_hmac_key,
                "subscription-verification",
                event.aggregate_id,
            )?;
            let management = derived_token(
                &state.token_hmac_key,
                "subscription-management",
                event.aggregate_id,
            )?;
            let row = sqlx::query(
                "SELECT email_encrypted,locale FROM intake.subscriptions WHERE id=$1 AND status='PENDING'",
            )
            .bind(event.aggregate_id)
            .fetch_one(&state.pool).await.map_err(|_|WorkerError::Database)?;
            let encrypted: Vec<u8> = row
                .try_get("email_encrypted")
                .map_err(|_| WorkerError::Database)?;
            let to = decrypt_email(
                state,
                "intake.subscriptions",
                "email_encrypted",
                event.aggregate_id,
                &encrypted,
            )?;
            let verify_url = format!(
                "{}/subscription/verify?token={}",
                state.public_base_url, verification
            );
            let manage_url = format!(
                "{}/subscription/manage?token={}",
                state.public_base_url, management
            );
            (
                to,
                "구린네 구독 확인".to_owned(),
                format!("구독 확인: {verify_url}\n향후 구독 관리: {manage_url}"),
                format!(
                    "<p><a href=\"{verify_url}\">구독 확인</a></p><p><a href=\"{manage_url}\">구독 관리</a></p>"
                ),
            )
        }
        "notification.correction_received.v1" => {
            let token = derived_token(
                &state.token_hmac_key,
                "correction-receipt",
                event.aggregate_id,
            )?;
            let encrypted: Vec<u8> = sqlx::query_scalar(
                "SELECT contact_email_encrypted FROM intake.correction_requests WHERE id=$1",
            )
            .bind(event.aggregate_id)
            .fetch_one(&state.pool)
            .await
            .map_err(|_| WorkerError::Database)?;
            let to = decrypt_email(
                state,
                "intake.correction_requests",
                "contact_email_encrypted",
                event.aggregate_id,
                &encrypted,
            )?;
            let url = format!(
                "{}/correction-request/receipt?token={}",
                state.public_base_url, token
            );
            (
                to,
                "구린네 정정 요청 접수".to_owned(),
                format!("정정 요청이 접수되었습니다. 영수증: {url}"),
                format!("<p>정정 요청이 접수되었습니다. <a href=\"{url}\">영수증 보기</a></p>"),
            )
        }
        "notification.correction_resolved.v1" => (
            state.reply_to.clone(),
            "구린네 정정 검토 완료".to_owned(),
            format!(
                "정정 검토가 완료되었습니다. 정정 ID: {}",
                event.aggregate_id
            ),
            format!(
                "<p>정정 검토가 완료되었습니다.</p><p>정정 ID: {}</p>",
                event.aggregate_id
            ),
        ),
        "notification.response_extension_requested.v1" => {
            let row = sqlx::query(
                "SELECT r.id,r.recipient_email_encrypted,x.requested_due_at \
                 FROM intake.response_extension_requests x JOIN editorial.response_requests r \
                   ON r.id=x.response_request_id WHERE x.id=$1",
            )
            .bind(event.aggregate_id)
            .fetch_optional(&state.pool)
            .await
            .map_err(|_| WorkerError::Database)?
            .ok_or(WorkerError::Database)?;
            let request_id: Uuid = row.try_get("id").map_err(|_| WorkerError::Database)?;
            let encrypted: Vec<u8> = row
                .try_get("recipient_email_encrypted")
                .map_err(|_| WorkerError::Database)?;
            let to = decrypt_email(
                state,
                "editorial.response_requests",
                "recipient_email_encrypted",
                request_id,
                &encrypted,
            )?;
            let due: time::OffsetDateTime = row
                .try_get("requested_due_at")
                .map_err(|_| WorkerError::Database)?;
            (
                to,
                "구린네 소명 기한 연장 요청 접수".to_owned(),
                format!("소명 기한 연장 요청이 접수되었습니다. 요청 기한: {due}"),
                format!("<p>소명 기한 연장 요청이 접수되었습니다.</p><p>요청 기한: {due}</p>"),
            )
        }
        "notification.response_request_delivery_requested.v1" => {
            let row = sqlx::query(
                "SELECT recipient_email_encrypted,party_name,due_at FROM editorial.response_requests WHERE id=$1",
            )
            .bind(event.aggregate_id)
            .fetch_optional(&state.pool)
            .await
            .map_err(|_| WorkerError::Database)?
            .ok_or(WorkerError::Database)?;
            let encrypted: Vec<u8> = row
                .try_get("recipient_email_encrypted")
                .map_err(|_| WorkerError::Database)?;
            let to = decrypt_email(
                state,
                "editorial.response_requests",
                "recipient_email_encrypted",
                event.aggregate_id,
                &encrypted,
            )?;
            let access_token = random_token()?;
            let access_token_hash = token_hmac(&state.token_hmac_key, &access_token)?;
            let otp = response_otp(&state.token_hmac_key, &access_token_hash)?;
            sqlx::query(
                "INSERT INTO intake.response_access_tokens(response_request_id,token_hash,expires_at) \
                 VALUES($1,$2,clock_timestamp()+interval '14 days')",
            )
            .bind(event.aggregate_id)
            .bind(access_token_hash)
            .execute(&state.pool)
            .await
            .map_err(|_| WorkerError::Database)?;
            let url = format!("{}/respond?token={access_token}", state.response_base_url);
            let party: String = row
                .try_get("party_name")
                .map_err(|_| WorkerError::Database)?;
            (
                to,
                "구린네 소명 요청".to_owned(),
                format!(
                    "{party} 담당자께 소명을 요청드립니다. 제출: {url}\n이메일 확인 코드: {otp}"
                ),
                format!(
                    "<p>{party} 담당자께 소명을 요청드립니다.</p><p><a href=\"{url}\">소명 제출</a></p><p>이메일 확인 코드: <strong>{otp}</strong></p>"
                ),
            )
        }
        "notification.response_submitted.v1" => {
            let token = derived_token(
                &state.token_hmac_key,
                "response-receipt",
                event.aggregate_id,
            )?;
            let row = sqlx::query(
                "SELECT r.recipient_email_encrypted AS email_encrypted,s.response_request_id \
                 FROM intake.response_submissions s JOIN editorial.response_requests r \
                   ON r.id=s.response_request_id WHERE s.id=$1",
            )
            .bind(event.aggregate_id)
            .fetch_one(&state.pool)
            .await
            .map_err(|_| WorkerError::Database)?;
            let encrypted: Vec<u8> = row
                .try_get("email_encrypted")
                .map_err(|_| WorkerError::Database)?;
            let request_id: Uuid = row
                .try_get("response_request_id")
                .map_err(|_| WorkerError::Database)?;
            let to = decrypt_email(
                state,
                "editorial.response_requests",
                "recipient_email_encrypted",
                request_id,
                &encrypted,
            )?;
            let url = format!(
                "{}/respond/receipt?token={}",
                state.response_base_url, token
            );
            (
                to,
                "구린네 소명 제출 완료".to_owned(),
                format!("소명이 제출되었습니다. 영수증: {url}"),
                format!("<p>소명이 제출되었습니다. <a href=\"{url}\">영수증 보기</a></p>"),
            )
        }
        "notification.user_invitation_requested.v1" => {
            let row = sqlx::query(
                "SELECT email::text email,display_name FROM ops.users WHERE id=$1 AND status='INVITED'",
            )
            .bind(event.aggregate_id)
            .fetch_optional(&state.pool)
            .await
            .map_err(|_| WorkerError::Database)?
            .ok_or(WorkerError::Database)?;
            let to: String = row.try_get("email").map_err(|_| WorkerError::Database)?;
            let display: String = row
                .try_get("display_name")
                .map_err(|_| WorkerError::Database)?;
            (
                to,
                "구린네 내부 사용자 초대".to_owned(),
                format!("{display}님이 구린네 내부 검토 시스템에 초대되었습니다."),
                format!("<p>{display}님이 구린네 내부 검토 시스템에 초대되었습니다.</p>"),
            )
        }
        _ => return Err(WorkerError::Database),
    };
    let recipient_hash = sha256_hex(to.as_bytes());
    let delivery_id:Uuid=sqlx::query_scalar(
        "INSERT INTO ops.email_deliveries(message_type,recipient_hash,template_version,object_type,object_id,status,attempt_count) VALUES($1,$2,'v1',$3,$4,'SENDING',1) ON CONFLICT(message_type,object_id,recipient_hash) WHERE object_id IS NOT NULL DO UPDATE SET status='SENDING',attempt_count=ops.email_deliveries.attempt_count+1,last_error_code=NULL RETURNING id",
    ).bind(&event.event_type).bind(recipient_hash).bind("notification").bind(event.aggregate_id)
     .fetch_one(&state.pool).await.map_err(|_|WorkerError::Database)?;
    Ok((
        delivery_id,
        EmailMessage {
            from: state.from_email.clone(),
            to,
            subject,
            text_body: text,
            html_body: html,
        },
    ))
}

fn decrypt_email(
    state: &State,
    table: &str,
    column: &str,
    id: Uuid,
    ciphertext: &[u8],
) -> Result<String, WorkerError> {
    let token = std::str::from_utf8(ciphertext).map_err(|_| WorkerError::Cryptography)?;
    let id_text = id.to_string();
    let bytes = decrypt(
        "gurine-fe-v1",
        &state.field_keys,
        &[table, column, &id_text, "email-address", "1"],
        token,
    )
    .map_err(|_| WorkerError::Cryptography)?;
    String::from_utf8(bytes).map_err(|_| WorkerError::Cryptography)
}

fn random_token() -> Result<String, WorkerError> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| WorkerError::Cryptography)?;
    let value = URL_SAFE_NO_PAD.encode(bytes);
    bytes.zeroize();
    Ok(value)
}
fn token_hmac(key: &[u8], token: &str) -> Result<String, WorkerError> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).map_err(|_| WorkerError::Cryptography)?;
    mac.update(token.as_bytes());
    Ok(mac
        .finalize()
        .into_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn derived_token(key: &[u8], purpose: &str, id: Uuid) -> Result<String, WorkerError> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).map_err(|_| WorkerError::Cryptography)?;
    mac.update(purpose.as_bytes());
    mac.update(b":");
    mac.update(id.as_bytes());
    Ok(URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes()))
}

fn response_otp(key: &[u8], access_token_hash: &str) -> Result<String, WorkerError> {
    let digest = token_hmac(key, &format!("response-otp:{access_token_hash}"))?;
    let prefix = digest.get(..8).ok_or(WorkerError::Cryptography)?;
    let value = u32::from_str_radix(prefix, 16).map_err(|_| WorkerError::Cryptography)?;
    Ok(format!("{:06}", value % 1_000_000))
}

async fn mark_failed(state: &State, id: Uuid, code: &str) -> Result<(), WorkerError> {
    sqlx::query("UPDATE ops.email_deliveries SET status='FAILED',last_error_code=$2 WHERE id=$1")
        .bind(id)
        .bind(code)
        .execute(&state.pool)
        .await
        .map_err(|_| WorkerError::Database)?;
    Ok(())
}
