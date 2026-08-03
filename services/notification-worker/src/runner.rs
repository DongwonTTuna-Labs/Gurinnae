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
    handlers::delivery::{
        DeliveryError, DeliveryGateway, FileGateway, ProviderBinding, ProviderRevision, SmtpGateway,
    },
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
    consumer_id: String,
    id: Uuid,
    event_type: String,
    aggregate_id: Uuid,
    aggregate_version: i64,
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

include!("notification_jobs.rs");
include!("notification_prepare.rs");
include!("notification_helpers.rs");
