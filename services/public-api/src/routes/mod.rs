use actix_web::{
    HttpRequest, HttpResponse,
    http::{StatusCode, header},
    web,
};
use gurine_api_contracts::{OperationSpec, public_api::OPERATIONS};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    rate_limit::{Decision, RateLimitUnavailable},
    service,
    state::AppState,
};

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
    let address = match request.peer_addr() {
        Some(peer) => peer.ip(),
        None => return problem("DEPENDENCY_UNAVAILABLE", 503, &request_id, None),
    };
    match state.public_read_rate_limiter.check(address) {
        Ok(Decision::Allowed) => {}
        Ok(Decision::Limited {
            retry_after_seconds,
        }) => {
            return problem("RATE_LIMITED", 429, &request_id, Some(retry_after_seconds));
        }
        Err(RateLimitUnavailable) => {
            return problem("DEPENDENCY_UNAVAILABLE", 503, &request_id, None);
        }
    }
    match service::execute(operation.id, &request, &state).await {
        Ok(output) => {
            let status = StatusCode::from_u16(output.status).unwrap_or(StatusCode::OK);
            let body = match serde_json::to_vec(&output.body) {
                Ok(body) => body,
                Err(_) => return problem("INTERNAL_ERROR", 500, &request_id, None),
            };
            let etag = format!("\"{}\"", hex(&Sha256::digest(&body)));
            if request
                .headers()
                .get(header::IF_NONE_MATCH)
                .and_then(|value| value.to_str().ok())
                .is_some_and(|value| etag_matches(value, &etag))
            {
                return HttpResponse::NotModified()
                    .insert_header(("x-request-id", request_id))
                    .insert_header((header::ETAG, etag))
                    .insert_header((
                        header::CACHE_CONTROL,
                        "public, max-age=60, stale-while-revalidate=300",
                    ))
                    .insert_header(("x-content-type-options", "nosniff"))
                    .insert_header((
                        "content-security-policy",
                        "default-src 'none'; frame-ancestors 'none'",
                    ))
                    .finish();
            }
            HttpResponse::build(status)
                .insert_header(("x-request-id", request_id))
                .insert_header(("content-type", output.media_type))
                .insert_header((header::ETAG, etag))
                .insert_header((
                    "cache-control",
                    "public, max-age=60, stale-while-revalidate=300",
                ))
                .insert_header(("x-content-type-options", "nosniff"))
                .insert_header((
                    "content-security-policy",
                    "default-src 'none'; frame-ancestors 'none'",
                ))
                .body(body)
        }
        Err(service::ServiceError::InvalidRequest) => {
            problem("INVALID_PARAMETER", 400, &request_id, None)
        }
        Err(service::ServiceError::NotFound) => {
            problem("RESOURCE_NOT_FOUND", 404, &request_id, None)
        }
        Err(service::ServiceError::Persistence) => {
            problem("STORAGE_FAILURE", 503, &request_id, None)
        }
    }
}

fn problem(
    code: &str,
    status: u16,
    request_id: &str,
    retry_after_seconds: Option<u64>,
) -> HttpResponse {
    let status_code = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let mut response = HttpResponse::build(status_code);
    if let Some(retry_after) = retry_after_seconds {
        response.insert_header((header::RETRY_AFTER, retry_after.to_string()));
    }
    response
        .insert_header(("content-type", "application/problem+json"))
        .insert_header(("cache-control", "no-store"))
        .insert_header(("x-request-id", request_id))
        .insert_header(("x-content-type-options", "nosniff"))
        .insert_header((
            "content-security-policy",
            "default-src 'none'; frame-ancestors 'none'",
        ))
        .json(serde_json::json!({
            "code":code,
            "title":code,
            "status":status,
            "requestId":request_id,
        }))
}

fn etag_matches(value: &str, etag: &str) -> bool {
    value
        .split(',')
        .map(str::trim)
        .any(|candidate| candidate == "*" || candidate == etag)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::etag_matches;

    #[test]
    fn conditional_etag_lists_are_parsed_exactly() {
        assert!(etag_matches("\"first\", \"second\"", "\"second\""));
        assert!(etag_matches("*", "\"second\""));
        assert!(!etag_matches("W/\"second\"", "\"second\""));
    }
}
