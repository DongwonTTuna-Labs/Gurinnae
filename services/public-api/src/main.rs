#![forbid(unsafe_code)]

use std::io;

#[actix_web::main]
async fn main() -> io::Result<()> {
    if gurine_observability::healthcheck::run_if_requested()? {
        return Ok(());
    }
    gurine_public_api::app::run().await
}
