use std::time::Duration;

use sqlx::{PgPool, postgres::PgPoolOptions};
use thiserror::Error;

#[derive(Clone, Debug)]
pub struct PoolConfig {
    pub database_url: String,
    pub max_connections: u32,
    pub acquire_timeout: Duration,
}

#[derive(Debug, Error)]
pub enum PoolError {
    #[error("database connection failed")]
    Connect(#[source] sqlx::Error),
    #[error("database readiness query failed")]
    Readiness(#[source] sqlx::Error),
}

pub async fn connect(config: &PoolConfig) -> Result<PgPool, PoolError> {
    let pool = PgPoolOptions::new()
        .max_connections(config.max_connections)
        .acquire_timeout(config.acquire_timeout)
        .connect(&config.database_url)
        .await
        .map_err(PoolError::Connect)?;
    sqlx::Executor::execute(&pool, sqlx::query_scalar!("SELECT 1"))
        .await
        .map_err(PoolError::Readiness)?;
    Ok(pool)
}
