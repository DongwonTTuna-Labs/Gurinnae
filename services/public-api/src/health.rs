use actix_web::{HttpResponse, Responder};

pub async fn live() -> impl Responder {
    HttpResponse::Ok().json(serde_json::json!({"status": "live"}))
}

pub async fn ready() -> impl Responder {
    HttpResponse::Ok().json(serde_json::json!({"status": "ready"}))
}
