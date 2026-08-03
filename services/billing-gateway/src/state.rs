use std::{future::Future, pin::Pin, sync::Arc, time::Duration};

use gurine_auth::assertion::service::{AssertionKey, KeyRing};
use gurine_persistence_postgres::pool::{PoolConfig, PoolError, connect};
use sqlx::PgPool;
use thiserror::Error;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::{
    app::BillingApplication,
    config::{AssertionKeys, Config, RuntimeMode},
};

const BILLING_DATABASE_ROLE: &str = "gurine_billing_gateway";
const BILLING_PRINCIPAL_SQL: &str = "SELECT session_user::text, current_user::text";
const BILLING_ASSERTION_CONSUME_SQL: &str = "SELECT ops.consume_billing_gateway_assertion_jti_v1(\
    $1::text,$2::uuid,$3::text,$4::text,$5::timestamptz,$6::char(64))";

pub enum AppState {
    Disabled,
    TestOnly(Box<TestOnlyState>),
}

pub struct TestOnlyState {
    pool: PgPool,
    public_web_keys: KeyRing,
    payment_fixture_keys: KeyRing,
    application: Arc<dyn BillingApplication>,
    assertion_replay: Arc<dyn AssertionReplayStore>,
}

impl TestOnlyState {
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    pub fn public_web_keys(&self) -> &KeyRing {
        &self.public_web_keys
    }

    pub fn payment_fixture_keys(&self) -> &KeyRing {
        &self.payment_fixture_keys
    }

    pub fn application(&self) -> &dyn BillingApplication {
        self.application.as_ref()
    }

    pub fn assertion_replay(&self) -> &dyn AssertionReplayStore {
        self.assertion_replay.as_ref()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssertionConsumptionRecord {
    pub assertion_type: &'static str,
    pub jti: String,
    pub issuer: String,
    pub audience: String,
    pub expires_at_unix: i64,
    pub request_digest: String,
}

pub type AssertionFuture<'a> = Pin<Box<dyn Future<Output = Result<bool, sqlx::Error>> + Send + 'a>>;

pub trait AssertionReplayStore: Send + Sync {
    fn consume<'a>(&'a self, record: &'a AssertionConsumptionRecord) -> AssertionFuture<'a>;
}

struct PostgresAssertionReplayStore {
    pool: PgPool,
}

impl AssertionReplayStore for PostgresAssertionReplayStore {
    fn consume<'a>(&'a self, record: &'a AssertionConsumptionRecord) -> AssertionFuture<'a> {
        Box::pin(async move {
            let jti = record
                .jti
                .parse::<Uuid>()
                .map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
            let expires_at = OffsetDateTime::from_unix_timestamp(record.expires_at_unix)
                .map_err(|error| sqlx::Error::Decode(Box::new(error)))?;
            sqlx::query_scalar::<_, bool>(BILLING_ASSERTION_CONSUME_SQL)
                .bind(record.assertion_type)
                .bind(jti)
                .bind(&record.issuer)
                .bind(&record.audience)
                .bind(expires_at)
                .bind(&record.request_digest)
                .fetch_one(&self.pool)
                .await
        })
    }
}

pub struct VerifiedBillingPool(PgPool);

impl VerifiedBillingPool {
    pub fn pool(&self) -> &PgPool {
        &self.0
    }

    fn into_inner(self) -> PgPool {
        self.0
    }
}

#[derive(Debug, Error)]
pub enum StateError {
    #[error(transparent)]
    Pool(#[from] PoolError),
    #[error("billing database principal query failed")]
    PrincipalQuery(#[source] sqlx::Error),
    #[error("billing database principal is invalid")]
    PrincipalMismatch,
    #[error("billing TEST_ONLY database URL is missing")]
    DatabaseUrlMissing,
    #[error("billing TEST_ONLY state requires TEST_ONLY mode")]
    ModeMismatch,
    #[error("billing TEST_ONLY runtime configuration is incomplete")]
    RuntimeConfiguration,
    #[error("billing assertion key is invalid")]
    AssertionKey,
}

impl AppState {
    pub const fn disabled() -> Self {
        Self::Disabled
    }

    pub const fn mode(&self) -> RuntimeMode {
        match self {
            Self::Disabled => RuntimeMode::Disabled,
            Self::TestOnly(_) => RuntimeMode::TestOnly,
        }
    }

    pub const fn test_only(&self) -> Option<&TestOnlyState> {
        match self {
            Self::Disabled => None,
            Self::TestOnly(state) => Some(state),
        }
    }

    pub fn from_verified_pool(
        config: &Config,
        verified_pool: VerifiedBillingPool,
        application: Arc<dyn BillingApplication>,
    ) -> Result<Self, StateError> {
        if config.mode != RuntimeMode::TestOnly {
            return Err(StateError::ModeMismatch);
        }
        let public_web_keys = config
            .public_web_keys
            .as_ref()
            .ok_or(StateError::RuntimeConfiguration)
            .and_then(key_ring)?;
        let payment_fixture_keys = config
            .payment_fixture_keys
            .as_ref()
            .ok_or(StateError::RuntimeConfiguration)
            .and_then(key_ring)?;
        let pool = verified_pool.into_inner();
        let assertion_replay = Arc::new(PostgresAssertionReplayStore { pool: pool.clone() });
        Ok(Self::TestOnly(Box::new(TestOnlyState {
            pool,
            public_web_keys,
            payment_fixture_keys,
            application,
            assertion_replay,
        })))
    }

    #[cfg(test)]
    pub(crate) fn test_only_with_dependencies(
        pool: PgPool,
        public_web_keys: KeyRing,
        payment_fixture_keys: KeyRing,
        application: Arc<dyn BillingApplication>,
        assertion_replay: Arc<dyn AssertionReplayStore>,
    ) -> Self {
        Self::TestOnly(Box::new(TestOnlyState {
            pool,
            public_web_keys,
            payment_fixture_keys,
            application,
            assertion_replay,
        }))
    }
}

pub async fn connect_verified_pool(config: &Config) -> Result<VerifiedBillingPool, StateError> {
    if config.mode != RuntimeMode::TestOnly {
        return Err(StateError::ModeMismatch);
    }
    let database_url = config
        .database_url
        .as_ref()
        .ok_or(StateError::DatabaseUrlMissing)?;
    let pool = connect(&PoolConfig {
        database_url: database_url.clone(),
        max_connections: 8,
        acquire_timeout: Duration::from_secs(10),
    })
    .await?;
    verify_billing_principal(&pool).await?;
    Ok(VerifiedBillingPool(pool))
}

async fn verify_billing_principal(pool: &PgPool) -> Result<(), StateError> {
    let rows = sqlx::query_as::<_, (Option<String>, Option<String>)>(BILLING_PRINCIPAL_SQL)
        .fetch_all(pool)
        .await
        .map_err(StateError::PrincipalQuery)?;
    validate_billing_principal(&rows)
}

fn validate_billing_principal(rows: &[(Option<String>, Option<String>)]) -> Result<(), StateError> {
    match rows {
        [(Some(session_user), Some(current_user))]
            if session_user == BILLING_DATABASE_ROLE && current_user == BILLING_DATABASE_ROLE =>
        {
            Ok(())
        }
        _ => Err(StateError::PrincipalMismatch),
    }
}

fn key_ring(keys: &AssertionKeys) -> Result<KeyRing, StateError> {
    Ok(KeyRing {
        current: AssertionKey::from_bytes(keys.current.clone())
            .map_err(|_| StateError::AssertionKey)?,
        previous: keys
            .previous
            .as_ref()
            .map(|value| AssertionKey::from_bytes(value.clone()))
            .transpose()
            .map_err(|_| StateError::AssertionKey)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn role(value: &str) -> Option<String> {
        Some(value.to_owned())
    }

    #[test]
    fn billing_principal_requires_exactly_one_exact_non_null_row() {
        let expected = [(role(BILLING_DATABASE_ROLE), role(BILLING_DATABASE_ROLE))];
        assert!(validate_billing_principal(&expected).is_ok());

        for invalid in [
            Vec::new(),
            vec![(None, role(BILLING_DATABASE_ROLE))],
            vec![(role(BILLING_DATABASE_ROLE), None)],
            vec![(role("gurine_dev"), role("gurine_dev"))],
            vec![(role(BILLING_DATABASE_ROLE), role("gurine_payment_writer"))],
            vec![
                (role(BILLING_DATABASE_ROLE), role(BILLING_DATABASE_ROLE)),
                (role(BILLING_DATABASE_ROLE), role(BILLING_DATABASE_ROLE)),
            ],
        ] {
            assert!(matches!(
                validate_billing_principal(&invalid),
                Err(StateError::PrincipalMismatch)
            ));
        }
    }

    #[test]
    fn assertion_replay_uses_only_the_billing_owner_wrapper() {
        assert!(
            BILLING_ASSERTION_CONSUME_SQL.contains("ops.consume_billing_gateway_assertion_jti_v1")
        );
        assert!(!BILLING_ASSERTION_CONSUME_SQL.contains("assertion_replay_guard"));
        assert!(!BILLING_ASSERTION_CONSUME_SQL.contains("INSERT"));
    }
}
