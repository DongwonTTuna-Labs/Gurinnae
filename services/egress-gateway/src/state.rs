use gurine_object_store::{
    filesystem,
    port::ObjectStoreClient,
    s3::{self, S3Config},
};
use sqlx::{PgPool, postgres::PgPoolOptions};
use thiserror::Error;

use crate::config::{Config, ObjectStoreConfig};

pub struct GatewayState {
    pub config: Config,
    pub object_store: Option<ObjectStoreClient>,
    pub smtp: Option<Arc<SmtpSender>>,
    pub database: Option<PgPool>,
}

#[derive(Debug, Error)]
pub enum StateError {
    #[error("egress object store initialization failed")]
    ObjectStore,
    #[error("egress SMTP initialization failed")]
    Smtp,
    #[error("egress database initialization failed")]
    Database,
}

impl GatewayState {
    pub async fn initialize(config: Config) -> Result<Self, StateError> {
        let object_store = match &config.object_store {
            None => None,
            Some(ObjectStoreConfig::Filesystem(root)) => {
                tokio::fs::create_dir_all(root)
                    .await
                    .map_err(|_| StateError::ObjectStore)?;
                Some(filesystem::open(root).map_err(|_| StateError::ObjectStore)?)
            }
            Some(ObjectStoreConfig::S3 {
                bucket,
                region,
                endpoint,
                access_key_id,
                secret_access_key,
            }) => Some(
                s3::open(S3Config {
                    bucket,
                    region,
                    endpoint: endpoint.as_deref(),
                    access_key_id,
                    secret_access_key,
                    allow_http: config.development(),
                })
                .map_err(|_| StateError::ObjectStore)?,
            ),
        };
        let smtp = config
            .smtp_url
            .as_deref()
            .map(SmtpSender::from_url)
            .transpose()
            .map_err(|_| StateError::Smtp)?
            .map(Arc::new);
        let database = config
            .database_url
            .as_deref()
            .map(|url| {
                PgPoolOptions::new()
                    .max_connections(4)
                    .connect_lazy(url)
                    .map_err(|_| StateError::Database)
            })
            .transpose()?;
        Ok(Self {
            config,
            object_store,
            smtp,
            database,
        })
    }
}
use std::sync::Arc;

use gurine_email::smtp::SmtpSender;
