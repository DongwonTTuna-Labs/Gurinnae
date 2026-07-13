#![forbid(unsafe_code)]

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    tracing_subscriber::fmt().json().init();
    let config =
        gurine_notification_worker::config::Config::from_env().map_err(std::io::Error::other)?;
    gurine_notification_worker::runner::run(config)
        .await
        .map_err(std::io::Error::other)
}
