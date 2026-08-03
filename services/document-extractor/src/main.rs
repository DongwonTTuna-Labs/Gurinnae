#![forbid(unsafe_code)]

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {
    tracing_subscriber::fmt().json().init();
    if std::env::var_os("GURINE_MEDIA_RUNTIME_PROBE").is_some() {
        let result = gurine_document_extractor::run_runtime_lifecycle_probe()
            .map_err(std::io::Error::other)?;
        println!("{}", result);
        return Ok(());
    }
    let config =
        gurine_document_extractor::config::Config::from_env().map_err(std::io::Error::other)?;
    gurine_document_extractor::runner::run(config)
        .await
        .map_err(std::io::Error::other)
}
