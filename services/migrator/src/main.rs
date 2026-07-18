#![forbid(unsafe_code)]

mod config;

use sqlx::postgres::PgPoolOptions;
use thiserror::Error;

/// The runtime contains the 24 byte-immutable authority migrations plus the
/// six additive v13 migrations.  Keep this separate from the authority
/// validator's base count: changing the latter would silently weaken the
/// hash-pinned archive lock.
pub const EXPECTED_MIGRATION_COUNT: i64 = 30;

#[derive(Debug, Error)]
enum MigratorError {
    #[error(transparent)]
    Config(#[from] config::ConfigError),
    #[error("database connection failed")]
    Connect(#[source] sqlx::Error),
    #[error("database migration failed")]
    Migrate(#[source] sqlx::migrate::MigrateError),
    #[error("database migration count mismatch: expected {EXPECTED_MIGRATION_COUNT}, found {0}")]
    MigrationCount(i64),
    #[error(
        "database migration sequence is incomplete: expected versions 1..={EXPECTED_MIGRATION_COUNT}, found {0}"
    )]
    MigrationSequence(String),
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
    if migration_count != EXPECTED_MIGRATION_COUNT {
        return Err(MigratorError::MigrationCount(migration_count));
    }
    let sequence: Vec<i64> =
        sqlx::query_scalar("SELECT version FROM _sqlx_migrations WHERE success ORDER BY version")
            .fetch_all(&pool)
            .await
            .map_err(MigratorError::Count)?;
    let expected: Vec<i64> = (1..=EXPECTED_MIGRATION_COUNT).collect();
    if sequence != expected {
        return Err(MigratorError::MigrationSequence(format!(
            "expected {:?}, found {:?}",
            expected, sequence
        )));
    }
    tracing::info!(migration_count, "database migrations completed");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::EXPECTED_MIGRATION_COUNT;

    #[test]
    fn runtime_count_is_additive_over_immutable_authority_base() {
        assert_eq!(EXPECTED_MIGRATION_COUNT, 30);
    }

    #[test]
    fn expected_sequence_has_no_reserved_gap() {
        let versions: Vec<i64> = (1..=EXPECTED_MIGRATION_COUNT).collect();
        assert_eq!(versions.first(), Some(&1));
        assert_eq!(versions.last(), Some(&30));
        assert_eq!(versions.len() as i64, EXPECTED_MIGRATION_COUNT);
    }
}
