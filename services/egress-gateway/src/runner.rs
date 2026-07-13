use std::io;

use actix_web::{App, HttpServer, web};

use crate::{config::Config, handlers, health, state::GatewayState};

pub async fn run() -> io::Result<()> {
    let config = Config::from_env().map_err(io::Error::other)?;
    let bind = config.bind.clone();
    let state = web::Data::new(
        GatewayState::initialize(config)
            .await
            .map_err(io::Error::other)?,
    );
    HttpServer::new(move || {
        App::new()
            .app_data(state.clone())
            .app_data(web::PayloadConfig::new(52_428_800))
            .route("/health/live", web::get().to(health::live))
            .route("/health/ready", web::get().to(health::ready))
            .route("/oidc", web::to(handlers::oidc))
            .route("/source", web::to(handlers::source))
            .route("/ai", web::to(handlers::ai))
            .route("/challenge", web::to(handlers::challenge))
            .route("/object-store", web::to(handlers::object_store))
            .route("/smtp", web::post().to(handlers::smtp))
    })
    .bind(bind)?
    .run()
    .await
}
