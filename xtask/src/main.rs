#![forbid(unsafe_code)]

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    tracing_subscriber::fmt().json().init();
    tracing::info!(service = "xtask", "service started");
    tokio::signal::ctrl_c().await
}
