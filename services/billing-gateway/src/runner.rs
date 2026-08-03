use std::{io, sync::Arc};

use actix_web::{App, HttpServer, dev::Server, web};
use gurine_payment_providers::{
    DeterministicFixtureProviderFactory, FixturePaymentOutcome, InMemoryTestFixtureBillingKeyVault,
    KeyVersion, TestFixtureAuthority,
};
use thiserror::Error;
use time::OffsetDateTime;

use crate::{
    app::BillingApplication,
    config::{Config, RuntimeMode},
    health,
    payment::{PaymentEngine, PaymentRuntimeError, PostgresPaymentStore, ProviderSet},
    routes, shutdown,
    state::{AppState, StateError, connect_verified_pool},
};

/// The current 0041 charge-claim receipt cannot prove terminal TEST_ONLY
/// replay authority. It must remain false until a separately approved ABI
/// delta and its runtime fixture are both final.
pub const PAYMENT_OWNER_ABI_READY: bool = false;

#[derive(Debug, Error)]
pub enum RunnerError {
    #[error(transparent)]
    State(#[from] StateError),
    #[error("billing gateway HTTP runtime failed")]
    Http(#[source] io::Error),
    #[error("billing gateway payment owner ABI is not final")]
    OwnerAbiUnavailable,
    #[error("billing gateway TEST_ONLY runtime configuration is incomplete")]
    RuntimeConfiguration,
    #[error(transparent)]
    Payment(#[from] PaymentRuntimeError),
}

pub async fn run(config: Config) -> Result<(), RunnerError> {
    if config.mode == RuntimeMode::Disabled {
        return serve(config.bind, AppState::disabled()).await;
    }
    ensure_owner_abi_ready(config.mode)?;
    let verified_pool = connect_verified_pool(&config).await?;
    let pool = verified_pool.pool().clone();
    let factory = test_provider_factory(&config)?;
    let store = test_payment_store(&config, pool, factory.clone())?;
    let engine = Arc::new(test_payment_engine(&config, store.clone(), factory)?);
    let application: Arc<dyn BillingApplication> = engine.clone();
    let state = AppState::from_verified_pool(&config, verified_pool, application)?;
    if config.once {
        return drain_charge_jobs(&config, &store, engine.as_ref()).await;
    }
    serve_with_worker(config, state, store, engine).await
}

async fn serve(bind: String, state: AppState) -> Result<(), RunnerError> {
    let server = http_server(bind, state)?;
    let result = server.await;
    tracing::info!(component = shutdown::COMPONENT, "billing gateway stopped");
    result.map_err(RunnerError::Http)
}

async fn serve_with_worker(
    config: Config,
    state: AppState,
    store: PostgresPaymentStore,
    engine: Arc<PaymentEngine<PostgresPaymentStore>>,
) -> Result<(), RunnerError> {
    let server = http_server(config.bind.clone(), state)?;
    let handle = server.handle();
    tokio::select! {
        result = server => {
            tracing::info!(component = shutdown::COMPONENT, "billing gateway stopped");
            result.map_err(RunnerError::Http)
        }
        result = drain_charge_jobs(&config, &store, engine.as_ref()) => {
            handle.stop(true).await;
            result
        }
    }
}

fn http_server(bind: String, state: AppState) -> Result<Server, RunnerError> {
    let state = web::Data::new(state);
    tracing::info!(component = health::COMPONENT, %bind, "billing gateway ready");
    let server = HttpServer::new(move || {
        App::new()
            .app_data(state.clone())
            .configure(routes::configure)
    })
    .workers(2)
    .shutdown_timeout(10)
    .bind(bind)
    .map_err(RunnerError::Http)?
    .run();
    Ok(server)
}

async fn drain_charge_jobs(
    config: &Config,
    store: &PostgresPaymentStore,
    engine: &PaymentEngine<PostgresPaymentStore>,
) -> Result<(), RunnerError> {
    loop {
        match store
            .claim_next_charge_job(&config.worker_id, config.lease)
            .await?
        {
            Some(job) => {
                engine.execute_charge_job(&config.worker_id, &job).await?;
            }
            None if config.once => return Ok(()),
            None => {
                tokio::select! {
                    () = tokio::time::sleep(config.poll_interval) => {}
                    signal = tokio::signal::ctrl_c() => {
                        signal.map_err(RunnerError::Http)?;
                        tracing::info!(component = shutdown::COMPONENT, "billing gateway shutdown requested");
                        return Ok(());
                    }
                }
            }
        }
    }
}

fn test_payment_store(
    config: &Config,
    pool: sqlx::PgPool,
    factory: DeterministicFixtureProviderFactory,
) -> Result<PostgresPaymentStore, RunnerError> {
    let identity = config
        .payment_identity_keys
        .as_ref()
        .ok_or(RunnerError::RuntimeConfiguration)?;
    let current = (
        identity.current.material.clone(),
        identity.current.version.clone(),
    );
    let previous = identity
        .previous
        .as_ref()
        .map(|key| (key.material.clone(), key.version.clone()));
    PostgresPaymentStore::test_only(pool, factory, current, previous).map_err(Into::into)
}

fn test_payment_engine(
    config: &Config,
    store: PostgresPaymentStore,
    factory: DeterministicFixtureProviderFactory,
) -> Result<PaymentEngine<PostgresPaymentStore>, RunnerError> {
    let providers = ProviderSet::test_fixture(factory)?;
    let authority = test_fixture_authority()?;
    let vault_key = &config
        .billing_vault_keys
        .as_ref()
        .ok_or(RunnerError::RuntimeConfiguration)?
        .current;
    let vault = Arc::new(
        InMemoryTestFixtureBillingKeyVault::new(
            authority,
            vault_key.material.clone(),
            KeyVersion::try_new(vault_key.version.clone()).map_err(PaymentRuntimeError::from)?,
        )
        .map_err(PaymentRuntimeError::from)?,
    );
    let authorization = config
        .authorization_token_sha256
        .clone()
        .ok_or(RunnerError::RuntimeConfiguration)?;
    let outcome_digest = config
        .test_payment_outcome_config_digest
        .clone()
        .ok_or(RunnerError::RuntimeConfiguration)?;
    Ok(PaymentEngine::test_only(
        store,
        providers,
        vault,
        authorization,
        outcome_digest,
    ))
}

fn test_provider_factory(
    config: &Config,
) -> Result<DeterministicFixtureProviderFactory, RunnerError> {
    let outcome = config
        .test_payment_outcome
        .ok_or(RunnerError::RuntimeConfiguration)?;
    let observed_at_unix = OffsetDateTime::now_utc().unix_timestamp();
    DeterministicFixtureProviderFactory::new(
        test_fixture_authority()?,
        fixture_outcome(outcome),
        observed_at_unix,
    )
    .map_err(PaymentRuntimeError::from)
    .map_err(Into::into)
}

fn fixture_outcome(value: crate::config::DonationTestOutcome) -> FixturePaymentOutcome {
    use crate::config::DonationTestOutcome;
    match value {
        DonationTestOutcome::Pending => FixturePaymentOutcome::Pending,
        DonationTestOutcome::Succeeded => FixturePaymentOutcome::Succeeded,
        DonationTestOutcome::Failed => FixturePaymentOutcome::Failed,
        DonationTestOutcome::Canceled => FixturePaymentOutcome::Canceled,
    }
}

fn test_fixture_authority() -> Result<TestFixtureAuthority, RunnerError> {
    TestFixtureAuthority::try_new("TEST_FIXTURE_ONLY_NO_PRODUCTION_AUTHORITY")
        .map_err(PaymentRuntimeError::from)
        .map_err(Into::into)
}

fn ensure_owner_abi_ready(mode: RuntimeMode) -> Result<(), RunnerError> {
    if mode == RuntimeMode::TestOnly && !PAYMENT_OWNER_ABI_READY {
        Err(RunnerError::OwnerAbiUnavailable)
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owner_abi_gate_is_explicit_and_test_only_fail_closed() {
        assert!(!PAYMENT_OWNER_ABI_READY);
        assert!(ensure_owner_abi_ready(RuntimeMode::Disabled).is_ok());
        assert!(matches!(
            ensure_owner_abi_ready(RuntimeMode::TestOnly),
            Err(RunnerError::OwnerAbiUnavailable)
        ));
    }

    #[test]
    fn fixture_outcome_mapping_has_no_default_or_live_branch() {
        use crate::config::DonationTestOutcome;
        assert_eq!(
            fixture_outcome(DonationTestOutcome::Pending),
            FixturePaymentOutcome::Pending
        );
        assert_eq!(
            fixture_outcome(DonationTestOutcome::Succeeded),
            FixturePaymentOutcome::Succeeded
        );
        assert_eq!(
            fixture_outcome(DonationTestOutcome::Failed),
            FixturePaymentOutcome::Failed
        );
        assert_eq!(
            fixture_outcome(DonationTestOutcome::Canceled),
            FixturePaymentOutcome::Canceled
        );
    }

    #[test]
    fn worker_source_uses_only_the_closed_payment_store() {
        let source = include_str!("runner.rs");
        let production = source.split("#[cfg(test)]").next().unwrap_or_default();
        assert!(production.contains("claim_next_charge_job"));
        assert!(production.contains("execute_charge_job"));
        assert!(!production.contains("gurine_jobs::postgres::Worker"));
        assert!(!production.contains("INSERT "));
        assert!(!production.contains("UPDATE "));
        assert!(!production.contains("DELETE "));
    }

    #[test]
    fn runtime_wiring_has_no_live_provider_or_credential_transport() {
        let source = include_str!("runner.rs");
        let production = source.split("#[cfg(test)]").next().unwrap_or_default();
        assert!(production.contains("DeterministicFixtureProviderFactory"));
        assert!(production.contains("InMemoryTestFixtureBillingKeyVault"));
        for forbidden in [
            "AdapterEnvironment::Production",
            "DisabledLiveTransport",
            "DisabledLiveBillingKeyVault",
            "PaymentTransport",
            "reqwest",
            "awc::Client",
            "http://",
            "https://",
        ] {
            assert!(!production.contains(forbidden));
        }
    }
}
