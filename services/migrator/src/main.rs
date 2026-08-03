#![forbid(unsafe_code)]

mod config;

use sqlx::migrate::Migrator;
use sqlx::postgres::PgPoolOptions;
use thiserror::Error;

static MIGRATOR: Migrator = sqlx::migrate!("../../db/migrations");

fn expected_migration_sequence() -> Vec<i64> {
    MIGRATOR
        .migrations
        .iter()
        .map(|migration| migration.version)
        .collect()
}

#[derive(Debug, Error)]
enum MigratorError {
    #[error(transparent)]
    Config(#[from] config::ConfigError),
    #[error("database connection failed")]
    Connect(#[source] sqlx::Error),
    #[error("database migration failed")]
    Migrate(#[source] sqlx::migrate::MigrateError),
    #[error("embedded migration count cannot fit in the database ledger type: {0}")]
    EmbeddedMigrationCount(usize),
    #[error("database migration count mismatch: expected {expected}, found {found}")]
    MigrationCount { expected: i64, found: i64 },
    #[error("database migration sequence is incomplete: expected {expected}, found {found}")]
    MigrationSequence { expected: String, found: String },
    #[error("database migration count query failed")]
    Count(#[source] sqlx::Error),
}

#[tokio::main]
async fn main() -> Result<(), MigratorError> {
    tracing_subscriber::fmt().json().init();
    let config = config::Config::from_env()?;
    let expected_sequence = expected_migration_sequence();
    let expected_migration_count = i64::try_from(expected_sequence.len())
        .map_err(|_| MigratorError::EmbeddedMigrationCount(expected_sequence.len()))?;
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&config.database_url)
        .await
        .map_err(MigratorError::Connect)?;
    MIGRATOR.run(&pool).await.map_err(MigratorError::Migrate)?;
    let migration_count: i64 =
        sqlx::query_scalar("SELECT count(*) FROM _sqlx_migrations WHERE success")
            .fetch_one(&pool)
            .await
            .map_err(MigratorError::Count)?;
    if migration_count != expected_migration_count {
        return Err(MigratorError::MigrationCount {
            expected: expected_migration_count,
            found: migration_count,
        });
    }
    let sequence: Vec<i64> =
        sqlx::query_scalar("SELECT version FROM _sqlx_migrations WHERE success ORDER BY version")
            .fetch_all(&pool)
            .await
            .map_err(MigratorError::Count)?;
    if sequence != expected_sequence {
        return Err(MigratorError::MigrationSequence {
            expected: format!("{expected_sequence:?}"),
            found: format!("{sequence:?}"),
        });
    }
    tracing::info!(migration_count, "database migrations completed");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::expected_migration_sequence;

    #[test]
    fn embedded_migration_sequence_is_complete_and_contiguous() {
        let versions = expected_migration_sequence();
        let expected_last = i64::try_from(versions.len()).ok();
        assert!(!versions.is_empty());
        assert_eq!(versions.first(), Some(&1));
        assert_eq!(versions.last(), expected_last.as_ref());
        assert!(versions.windows(2).all(|pair| pair[1] == pair[0] + 1));
    }
}
