#![forbid(unsafe_code)]

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    tracing_subscriber::fmt().json().init();
    let config = gurine_scheduler::config::Config::from_env().map_err(std::io::Error::other)?;
    gurine_scheduler::scheduler::run(config)
        .await
        .map_err(std::io::Error::other)
}
