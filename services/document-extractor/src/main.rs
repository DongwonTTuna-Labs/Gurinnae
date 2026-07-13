#![forbid(unsafe_code)]

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    tracing_subscriber::fmt().json().init();
    let config =
        gurine_document_extractor::config::Config::from_env().map_err(std::io::Error::other)?;
    gurine_document_extractor::runner::run(config)
        .await
        .map_err(std::io::Error::other)
}
