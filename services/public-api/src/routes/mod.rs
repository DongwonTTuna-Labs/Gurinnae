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
        None => return availability_problem(operation.id, &request_id),
    };
    match state.public_read_rate_limiter.check(address) {
        Ok(Decision::Allowed) => {}
        Ok(Decision::Limited {
            retry_after_seconds,
        }) => {
            return problem("RATE_LIMITED", 429, &request_id, Some(retry_after_seconds));
        }
        Err(RateLimitUnavailable) => {
            return availability_problem(operation.id, &request_id);
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
        Err(error) => service_problem(operation.id, error, &request_id),
    }
}

fn availability_problem(operation_id: &str, request_id: &str) -> HttpResponse {
    if funding_operation(operation_id) {
        problem("INTERNAL_ERROR", 500, request_id, None)
    } else {
        problem("DEPENDENCY_UNAVAILABLE", 503, request_id, None)
    }
}

fn service_problem(
    operation_id: &str,
    error: service::ServiceError,
    request_id: &str,
) -> HttpResponse {
    match error {
        service::ServiceError::InvalidRequest => {
            problem("INVALID_PARAMETER", 400, request_id, None)
        }
        service::ServiceError::NotFound => problem("RESOURCE_NOT_FOUND", 404, request_id, None),
        service::ServiceError::PreconditionFailed => export_limit_problem(request_id),
        service::ServiceError::ReportPreconditionFailed => {
            problem("PRECONDITION_FAILED", 422, request_id, None)
        }
        service::ServiceError::Persistence if funding_operation(operation_id) => {
            problem("INTERNAL_ERROR", 500, request_id, None)
        }
        service::ServiceError::Persistence => problem("STORAGE_FAILURE", 503, request_id, None),
    }
}

fn funding_operation(operation_id: &str) -> bool {
    matches!(
        operation_id,
        "getFundingContent" | "listTransparencyReports" | "downloadTransparencyReport"
    )
}

fn export_limit_problem(request_id: &str) -> HttpResponse {
    HttpResponse::UnprocessableEntity()
        .insert_header(("content-type", "application/problem+json"))
        .insert_header(("cache-control", "no-store"))
        .insert_header(("x-request-id", request_id))
        .insert_header(("x-content-type-options", "nosniff"))
        .insert_header((
            "content-security-policy",
            "default-src 'none'; frame-ancestors 'none'",
        ))
        .json(serde_json::json!({
            "code": "PRECONDITION_FAILED",
            "title": "작업 선행 조건을 충족하지 못했습니다",
            "detail": "현재 조건의 결과가 5,000건을 초과합니다. 전체 자료는 데이터 내려받기에서 요청하세요.",
            "status": 422,
            "requestId": request_id,
        }))
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
    use std::net::SocketAddr;

    use actix_web::{App, body::to_bytes, http::StatusCode, test as actix_test, web};
    use gurine_api_contracts::public_api::OPERATIONS;
    use serde_json::Value;
    use sqlx::postgres::PgPoolOptions;

    use super::{
        availability_problem, configure, etag_matches, export_limit_problem, problem,
        service_problem,
    };
    use crate::{service::ServiceError, state::AppState};

    #[test]
    fn conditional_etag_lists_are_parsed_exactly() {
        assert!(etag_matches("\"first\", \"second\"", "\"second\""));
        assert!(etag_matches("*", "\"second\""));
        assert!(!etag_matches("W/\"second\"", "\"second\""));
    }

    #[actix_web::test]
    async fn export_limit_maps_to_the_catalog_precondition_problem() {
        let response = export_limit_problem("00000000-0000-0000-0000-000000000001");
        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
        let bytes = to_bytes(response.into_body()).await.expect("problem body");
        let body: Value = serde_json::from_slice(&bytes).expect("problem JSON");
        assert_eq!(body["code"], "PRECONDITION_FAILED");
        assert_eq!(body["title"], "작업 선행 조건을 충족하지 못했습니다");
        assert_eq!(
            body["detail"],
            "현재 조건의 결과가 5,000건을 초과합니다. 전체 자료는 데이터 내려받기에서 요청하세요."
        );
        assert_eq!(body["status"], 422);
    }

    #[actix_web::test]
    async fn transparency_download_route_rejects_invalid_path_or_query_before_database_io() {
        assert!(OPERATIONS.iter().any(|operation| {
            operation.id == "downloadTransparencyReport"
                && operation.method == "GET"
                && operation.path == "/v1/transparency-reports/{reportId}/download"
        }));
        let pool = PgPoolOptions::new().connect_lazy("postgres://gurine:unused@127.0.0.1:1/gurine");
        assert!(pool.is_ok(), "lazy test pool must be constructible");
        let Some(pool) = pool.ok() else {
            return;
        };
        let application = actix_test::init_service(
            App::new()
                .app_data(web::Data::new(AppState::new(pool)))
                .configure(configure),
        )
        .await;
        let request = actix_test::TestRequest::get()
            .uri("/v1/transparency-reports/not-a-uuid/download")
            .peer_addr(SocketAddr::from(([127, 0, 0, 1], 31_023)))
            .to_request();
        let response = actix_test::call_service(&application, request).await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body = actix_test::read_body(response).await;
        let parsed: Result<Value, _> = serde_json::from_slice(&body);
        assert!(
            parsed.as_ref().is_ok_and(|value| {
                value["code"] == "INVALID_PARAMETER" && value["status"] == 400
            })
        );

        let request = actix_test::TestRequest::get()
            .uri(
                "/v1/transparency-reports/00000000-0000-4000-8000-000000000001/download?format=YAML",
            )
            .peer_addr(SocketAddr::from(([127, 0, 0, 1], 31_024)))
            .to_request();
        let response = actix_test::call_service(&application, request).await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body = actix_test::read_body(response).await;
        let parsed: Result<Value, _> = serde_json::from_slice(&body);
        assert!(
            parsed.as_ref().is_ok_and(|value| {
                value["code"] == "INVALID_PARAMETER" && value["status"] == 400
            })
        );
    }

    #[actix_web::test]
    async fn transparency_download_uses_only_its_closed_redacted_error_set() {
        let request_id = "00000000-0000-4000-8000-000000000001";
        let cases = [
            (
                service_problem(
                    "downloadTransparencyReport",
                    ServiceError::NotFound,
                    request_id,
                ),
                StatusCode::NOT_FOUND,
                "RESOURCE_NOT_FOUND",
            ),
            (
                service_problem(
                    "downloadTransparencyReport",
                    ServiceError::ReportPreconditionFailed,
                    request_id,
                ),
                StatusCode::UNPROCESSABLE_ENTITY,
                "PRECONDITION_FAILED",
            ),
            (
                problem("RATE_LIMITED", 429, request_id, Some(1)),
                StatusCode::TOO_MANY_REQUESTS,
                "RATE_LIMITED",
            ),
            (
                service_problem(
                    "downloadTransparencyReport",
                    ServiceError::Persistence,
                    request_id,
                ),
                StatusCode::INTERNAL_SERVER_ERROR,
                "INTERNAL_ERROR",
            ),
            (
                availability_problem("downloadTransparencyReport", request_id),
                StatusCode::INTERNAL_SERVER_ERROR,
                "INTERNAL_ERROR",
            ),
        ];
        for (response, status, code) in cases {
            assert_eq!(response.status(), status);
            let body = to_bytes(response.into_body()).await;
            assert!(body.is_ok(), "problem body must serialize");
            let Some(body) = body.ok() else {
                continue;
            };
            let parsed: Result<Value, _> = serde_json::from_slice(&body);
            assert!(parsed.as_ref().is_ok_and(|value| {
                value["code"] == code
                    && value["status"] == status.as_u16()
                    && value.get("storageError").is_none()
            }));
            assert!(
                !body
                    .windows(b"STORAGE_FAILURE".len())
                    .any(|window| { window == b"STORAGE_FAILURE" })
            );
        }
        for operation_id in [
            "getFundingContent",
            "listTransparencyReports",
            "downloadTransparencyReport",
        ] {
            let response = service_problem(operation_id, ServiceError::Persistence, request_id);
            assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
            let body = to_bytes(response.into_body()).await;
            assert!(body.as_ref().is_ok_and(|body| {
                !body
                    .windows(b"STORAGE_FAILURE".len())
                    .any(|window| window == b"STORAGE_FAILURE")
            }));
            assert_eq!(
                availability_problem(operation_id, request_id).status(),
                StatusCode::INTERNAL_SERVER_ERROR
            );
        }
    }

    #[actix_web::test]
    async fn funding_queries_share_the_closed_projection_precondition_error() {
        let request_id = "00000000-0000-4000-8000-000000000001";
        for operation_id in [
            "getFundingContent",
            "listTransparencyReports",
            "downloadTransparencyReport",
        ] {
            let response = service_problem(
                operation_id,
                ServiceError::ReportPreconditionFailed,
                request_id,
            );
            assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
            let body = to_bytes(response.into_body()).await;
            assert!(body.as_ref().is_ok_and(|body| {
                serde_json::from_slice::<Value>(body).is_ok_and(|problem| {
                    problem["code"] == "PRECONDITION_FAILED"
                        && problem["status"] == 422
                        && problem.get("storageError").is_none()
                })
            }));
        }
    }
}
