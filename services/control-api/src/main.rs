#![forbid(unsafe_code)]

use std::io;

#[actix_web::main]
async fn main() -> io::Result<()> {
    if gurine_observability::healthcheck::run_if_requested()? {
        return Ok(());
    }
    tracing_subscriber::fmt().json().init();
    gurine_control_api::app::run().await
}
