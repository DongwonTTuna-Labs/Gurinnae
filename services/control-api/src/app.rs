use std::io;

use actix_web::{App, HttpServer, web};

use crate::{config::Config, health, routes, state::AppState};

pub async fn run() -> io::Result<()> {
    let config = Config::from_env().map_err(io::Error::other)?;
    let state = web::Data::new(
        AppState::initialize(&config)
            .await
            .map_err(io::Error::other)?,
    );
    HttpServer::new(move || {
        App::new()
            .app_data(state.clone())
            .route("/health/live", web::get().to(health::live))
            .route("/health/ready", web::get().to(health::ready))
            .configure(routes::configure)
    })
    .bind(config.bind)?
    .run()
    .await
}
