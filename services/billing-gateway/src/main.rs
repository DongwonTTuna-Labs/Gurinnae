#![forbid(unsafe_code)]

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    if gurine_observability::healthcheck::run_if_requested()? {
        return Ok(());
    }
    tracing_subscriber::fmt().json().init();
    let config =
        gurine_billing_gateway::config::Config::from_env().map_err(std::io::Error::other)?;
    gurine_billing_gateway::runner::run(config)
        .await
        .map_err(std::io::Error::other)
}
