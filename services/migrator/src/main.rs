#![forbid(unsafe_code)]

mod config;

use sqlx::postgres::PgPoolOptions;
use thiserror::Error;

#[derive(Debug, Error)]
enum MigratorError {
    #[error(transparent)]
    Config(#[from] config::ConfigError),
    #[error("database connection failed")]
    Connect(#[source] sqlx::Error),
    #[error("database migration failed")]
    Migrate(#[source] sqlx::migrate::MigrateError),
    #[error("database migration count mismatch: expected 24, found {0}")]
    MigrationCount(i64),
    #[error("database migration count query failed")]
    Count(#[source] sqlx::Error),
}

#[tokio::main]
async fn main() -> Result<(), MigratorError> {
    tracing_subscriber::fmt().json().init();
    let config = config::Config::from_env()?;
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&config.database_url)
        .await
        .map_err(MigratorError::Connect)?;
    sqlx::migrate!("../../db/migrations")
        .run(&pool)
        .await
        .map_err(MigratorError::Migrate)?;
    let migration_count: i64 =
        sqlx::query_scalar("SELECT count(*) FROM _sqlx_migrations WHERE success")
            .fetch_one(&pool)
            .await
            .map_err(MigratorError::Count)?;
    if migration_count != 24 {
        return Err(MigratorError::MigrationCount(migration_count));
    }
    tracing::info!(migration_count, "database migrations completed");
    Ok(())
}
