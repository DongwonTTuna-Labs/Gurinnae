use std::time::Duration;

use gurine_auth::{
    assertion::service::{AssertionKey, KeyRing},
    envelope::EnvelopeKeyRing,
};
use gurine_persistence_postgres::pool::{PoolConfig, PoolError, connect};
use openidconnect::core::CoreProviderMetadata;
use sqlx::PgPool;
use thiserror::Error;

use crate::{
    config::Config, oidc_client, oidc_egress::OidcEgressClient,
    session_assertion::SessionAssertionMaterial,
};

pub struct AppState {
    pub pool: PgPool,
    pub service_assertion_keys: KeyRing,
    pub actor_assertion_key: AssertionKey,
    pub field_keys: EnvelopeKeyRing,
    pub oidc_provider: CoreProviderMetadata,
    pub oidc_http: OidcEgressClient,
    pub config: Config,
}

#[derive(Debug, Error)]
pub enum StateError {
    #[error(transparent)]
    Pool(#[from] PoolError),
    #[error("identity assertion key is invalid")]
    AssertionKey,
    #[error("OIDC egress client initialization failed")]
    Egress,
    #[error("OIDC issuer URL is invalid")]
    Issuer,
    #[error("OIDC discovery failed")]
    Discovery,
}

impl AppState {
    pub async fn initialize(config: Config) -> Result<Self, StateError> {
        let pool = connect(&PoolConfig {
            database_url: config.database_url.clone(),
            max_connections: 20,
            acquire_timeout: Duration::from_secs(10),
        })
        .await?;
        let (oidc_provider, oidc_http) =
            oidc_client::discover(&config)
                .await
                .map_err(|error| match error {
                    oidc_client::OidcClientError::Egress => StateError::Egress,
                    oidc_client::OidcClientError::Issuer => StateError::Issuer,
                    oidc_client::OidcClientError::Discovery => StateError::Discovery,
                })?;
        let material =
            SessionAssertionMaterial::from_config(&config).map_err(|_| StateError::AssertionKey)?;
        Ok(Self {
            pool,
            service_assertion_keys: material.service_keys,
            actor_assertion_key: material.actor_key,
            field_keys: material.field_keys,
            oidc_provider,
            oidc_http,
            config,
        })
    }
}
