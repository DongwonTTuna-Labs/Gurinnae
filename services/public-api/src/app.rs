use std::io;

use actix_web::{App, HttpServer, web};
use gurine_persistence_postgres::pool::{PoolConfig, connect};

use crate::{config::Config, health, routes, state::AppState};

pub async fn run() -> io::Result<()> {
    let config = Config::from_env("0.0.0.0:8080")?;
    let pool = connect(&PoolConfig {
        database_url: config.database_url,
        max_connections: 16,
        acquire_timeout: std::time::Duration::from_secs(10),
    })
    .await
    .map_err(|error| io::Error::other(error.to_string()))?;
    let state = web::Data::new(AppState::new(pool));
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
