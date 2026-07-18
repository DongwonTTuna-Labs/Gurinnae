use std::time::Duration;

use gurine_auth::{
    assertion::service::{AssertionKey, KeyRing},
    envelope::{EnvelopeKey, EnvelopeKeyRing},
};
use gurine_persistence_postgres::pool::{PoolConfig, PoolError, connect};
use sqlx::PgPool;
use thiserror::Error;

use crate::{
    attachment_store::{AttachmentStore, AttachmentStoreError},
    config::{AttachmentStoreConfig, Config},
};

pub struct AppState {
    pub pool: PgPool,
    pub public_web_keys: KeyRing,
    pub response_portal_keys: KeyRing,
    pub response_portal_otp_key_current: Vec<u8>,
    pub response_portal_otp_key_previous: Option<Vec<u8>>,
    pub field_keys: EnvelopeKeyRing,
    pub token_hmac_key: Vec<u8>,
    pub environment: String,
    pub bot_challenge_secret: String,
    pub abuse_http: reqwest::Client,
    pub attachment_store: AttachmentStore,
    pub max_upload_bytes: usize,
    pub abuse_egress_url: Option<reqwest::Url>,
}

#[derive(Debug, Error)]
pub enum StateError {
    #[error(transparent)]
    Pool(#[from] PoolError),
    #[error("submission assertion key is invalid")]
    AssertionKey,
    #[error("abuse proof client initialization failed")]
    AbuseClient,
    #[error(transparent)]
    AttachmentStore(#[from] AttachmentStoreError),
}

impl AppState {
    pub async fn initialize(config: &Config) -> Result<Self, StateError> {
        let pool = connect(&PoolConfig {
            database_url: config.database_url.clone(),
            max_connections: 20,
            acquire_timeout: Duration::from_secs(10),
        })
        .await?;
        let attachment_store = match &config.attachment_store {
            AttachmentStoreConfig::Filesystem(root) => AttachmentStore::filesystem(root).await?,
            AttachmentStoreConfig::Egress(url) => AttachmentStore::egress(url.clone())?,
        };
        Ok(Self {
            pool,
            public_web_keys: key_ring(
                &config.public_web_key_current,
                config.public_web_key_previous.as_deref(),
            )?,
            response_portal_keys: key_ring(
                &config.response_portal_key_current,
                config.response_portal_key_previous.as_deref(),
            )?,
            response_portal_otp_key_current: config.response_portal_otp_key_current.clone(),
            response_portal_otp_key_previous: config.response_portal_otp_key_previous.clone(),
            field_keys: EnvelopeKeyRing {
                current: EnvelopeKey::new(config.field_key_current),
                previous: config.field_key_previous.map(EnvelopeKey::new),
            },
            token_hmac_key: config.token_hmac_key.clone(),
            environment: config.environment.clone(),
            bot_challenge_secret: config.bot_challenge_secret.clone(),
            abuse_http: reqwest::Client::builder()
                .https_only(config.environment == "production")
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(10))
                .build()
                .map_err(|_| StateError::AbuseClient)?,
            attachment_store,
            max_upload_bytes: config.max_upload_bytes,
            abuse_egress_url: config.abuse_egress_url.clone(),
        })
    }
}

fn key_ring(current: &[u8], previous: Option<&[u8]>) -> Result<KeyRing, StateError> {
    Ok(KeyRing {
        current: assertion_key(current)?,
        previous: previous.map(assertion_key).transpose()?,
    })
}

fn assertion_key(bytes: &[u8]) -> Result<AssertionKey, StateError> {
    AssertionKey::from_bytes(bytes.to_vec()).map_err(|_| StateError::AssertionKey)
}
