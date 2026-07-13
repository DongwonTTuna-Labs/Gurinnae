#![forbid(unsafe_code)]

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    if gurine_observability::healthcheck::run_if_requested()? {
        return Ok(());
    }
    tracing_subscriber::fmt().json().init();
    gurine_egress_gateway::runner::run().await
}
