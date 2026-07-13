use actix_web::{HttpRequest, HttpResponse, http::StatusCode, web};
use gurine_api_contracts::{OperationSpec, public_api::OPERATIONS};
use uuid::Uuid;

use crate::{service, state::AppState};

pub fn configure(config: &mut web::ServiceConfig) {
    // Actix resolves resources in registration order. Literal paths must win
    // over parameters such as `/v1/sources/{sourceId}`.
    for dynamic in [false, true] {
        for operation in OPERATIONS
            .iter()
            .filter(|operation| operation.path.contains('{') == dynamic)
        {
            let resource = web::resource(operation.path).name(operation.id);
            let operation_copy = *operation;
            let resource = match operation.method {
                "GET" => resource.route(
                    web::get().to(move |request, state| handle(operation_copy, request, state)),
                ),
                _ => resource,
            };
            config.service(resource);
        }
    }
}

async fn handle(
    operation: OperationSpec,
    request: HttpRequest,
    state: web::Data<AppState>,
) -> HttpResponse {
    let request_id = request
        .headers()
        .get("x-request-id")
        .and_then(|value| value.to_str().ok())
        .filter(|value| Uuid::parse_str(value).is_ok())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| Uuid::new_v4().to_string());
    match service::execute(operation.id, &request, &state).await {
        Ok(output) => {
            let status = StatusCode::from_u16(output.status).unwrap_or(StatusCode::OK);
            HttpResponse::build(status)
                .insert_header(("x-request-id", request_id))
                .insert_header(("content-type", output.media_type))
                .insert_header((
                    "cache-control",
                    "public, max-age=60, stale-while-revalidate=300",
                ))
                .insert_header(("x-content-type-options", "nosniff"))
                .insert_header((
                    "content-security-policy",
                    "default-src 'none'; frame-ancestors 'none'",
                ))
                .json(output.body)
        }
        Err(service::ServiceError::InvalidRequest) => problem("INVALID_REQUEST", 400, &request_id),
        Err(service::ServiceError::NotFound) => {
            problem("PUBLIC_RECORD_NOT_FOUND", 404, &request_id)
        }
        Err(service::ServiceError::Persistence) => {
            problem("PUBLIC_PROJECTION_UNAVAILABLE", 503, &request_id)
        }
    }
}

fn problem(code: &str, status: u16, request_id: &str) -> HttpResponse {
    let status_code = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    HttpResponse::build(status_code)
        .insert_header(("content-type", "application/problem+json"))
        .insert_header(("cache-control", "no-store"))
        .insert_header(("x-content-type-options", "nosniff"))
        .json(serde_json::json!({
            "code":code,
            "title":code,
            "status":status,
            "requestId":request_id,
        }))
}
