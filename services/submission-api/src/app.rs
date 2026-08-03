use std::io;

use actix_web::{App, HttpServer, web};

use crate::{config::Config, health, routes, state::AppState};

pub async fn run() -> io::Result<()> {
    let config = Config::from_env().map_err(io::Error::other)?;
    let bind = config.bind.clone();
    let state = web::Data::new(
        AppState::initialize(&config)
            .await
            .map_err(io::Error::other)?,
    );
    HttpServer::new(move || {
        App::new()
            .app_data(state.clone())
            .app_data(web::PayloadConfig::new(state.max_upload_bytes))
            .route("/health/live", web::get().to(health::live))
            .route("/health/ready", web::get().to(health::ready))
            .route(
                "/internal/submission-uploads/{attachmentId}",
                web::put().to(routes::upload_attachment),
            )
            .configure(routes::configure)
    })
    .bind(bind)?
    .run()
    .await
}
