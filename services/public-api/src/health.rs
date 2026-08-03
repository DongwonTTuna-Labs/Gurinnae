use std::time::Duration;

use actix_web::{HttpResponse, Responder, web};

use crate::state::AppState;

pub async fn live() -> impl Responder {
    HttpResponse::Ok().json(serde_json::json!({"status": "live"}))
}

pub async fn ready(state: web::Data<AppState>) -> impl Responder {
    match actix_web::rt::time::timeout(
        Duration::from_secs(2),
        sqlx::query("SELECT 1").execute(&state.pool),
    )
    .await
    {
        Ok(Ok(_)) => HttpResponse::Ok().json(serde_json::json!({"status": "ready"})),
        Ok(Err(_)) | Err(_) => {
            HttpResponse::ServiceUnavailable().json(serde_json::json!({"status": "not-ready"}))
        }
    }
}
