use std::time::Duration;

use gurine_auth::{
    assertion::service::{AssertionKey, KeyRing},
    envelope::{EnvelopeKey, EnvelopeKeyRing},
};
use gurine_persistence_postgres::pool::{PoolConfig, PoolError, connect};
use sqlx::PgPool;
use thiserror::Error;

use crate::config::Config;

pub struct AppState {
    pub pool: PgPool,
    pub assertion_keys: KeyRing,
    pub field_keys: EnvelopeKeyRing,
}

#[derive(Debug, Error)]
pub enum StateError {
    #[error(transparent)]
    Pool(#[from] PoolError),
    #[error("identity assertion key is invalid")]
    AssertionKey,
}

impl AppState {
    pub async fn initialize(config: &Config) -> Result<Self, StateError> {
        let pool = connect(&PoolConfig {
            database_url: config.database_url.clone(),
            max_connections: 20,
            acquire_timeout: Duration::from_secs(10),
        })
        .await?;
        let current = AssertionKey::from_bytes(config.assertion_key_current.clone())
            .map_err(|_| StateError::AssertionKey)?;
        let previous = config
            .assertion_key_previous
            .clone()
            .map(AssertionKey::from_bytes)
            .transpose()
            .map_err(|_| StateError::AssertionKey)?;
        Ok(Self {
            pool,
            assertion_keys: KeyRing { current, previous },
            field_keys: EnvelopeKeyRing {
                current: EnvelopeKey::new(config.field_key_current),
                previous: config.field_key_previous.map(EnvelopeKey::new),
            },
        })
    }
}
