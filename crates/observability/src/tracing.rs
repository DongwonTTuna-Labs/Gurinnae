use tracing_subscriber::{EnvFilter, fmt, prelude::*};

pub fn initialize(service_name: &str, default_filter: &str) -> Result<(), String> {
    if service_name.is_empty() {
        return Err("service name is empty".to_owned());
    }
    let filter = EnvFilter::try_from_default_env()
        .or_else(|_| EnvFilter::try_new(default_filter))
        .map_err(|_| "tracing filter is invalid".to_owned())?;
    tracing_subscriber::registry()
        .with(filter)
        .with(
            fmt::layer()
                .json()
                .with_target(true)
                .with_current_span(true),
        )
        .try_init()
        .map_err(|_| "tracing subscriber is already initialized".to_owned())?;
    tracing::info!(service = service_name, "tracing initialized");
    Ok(())
}
