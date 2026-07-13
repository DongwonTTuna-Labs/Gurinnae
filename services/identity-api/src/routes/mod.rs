use actix_web::{HttpRequest, HttpResponse, http::StatusCode, web};
use gurine_api_contracts::{OperationSpec, identity_service_internal::OPERATIONS};
use gurine_application::idempotency;
use gurine_auth::assertion::{
    AssertionError, BoundRequest,
    canonical::canonical_request_digest,
    service::{ServiceExpectation, verify_claims},
};
use gurine_persistence_postgres::{
    assertions::{AssertionConsumption, consume},
    idempotency::{Claim, StoredResponse, claim, complete},
};
use serde::de::DeserializeOwned;
use serde_json::Value;
use time::OffsetDateTime;
use uuid::Uuid;

use crate::{service, service::ServiceError, state::AppState};

pub fn configure(config: &mut web::ServiceConfig) {
    for operation in OPERATIONS {
        let operation_copy = *operation;
        config.service(
            web::resource(operation.path).name(operation.id).route(
                web::post()
                    .to(move |request, body, state| handle(operation_copy, request, body, state)),
            ),
        );
    }
}

async fn handle(
    operation: OperationSpec,
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<AppState>,
) -> HttpResponse {
    let request_id = request_id(&request);
    if let Err(response) = authorize(&request, &body, &state).await {
        return response;
    }
    let Some(idempotency_key) = header(&request, "idempotency-key") else {
        return problem("IDEMPOTENCY_KEY_REQUIRED", 400, &request_id);
    };
    let bound = bound_request(&request, &body, Some(idempotency_key));
    let request_digest = match canonical_request_digest(&bound) {
        Ok(value) => value,
        Err(_) => return problem("INVALID_REQUEST_BINDING", 400, &request_id),
    };
    let idempotency =
        match idempotency::request(operation.id, idempotency_key, request_digest.as_bytes()) {
            Ok(value) => value,
            Err(_) => return problem("IDEMPOTENCY_KEY_INVALID", 400, &request_id),
        };
    match claim(
        &state.pool,
        &idempotency.scope,
        &idempotency.key_hash,
        &idempotency.request_hash,
    )
    .await
    {
        Ok(Claim::Replay(response)) => return stored_response(response, &request_id),
        Ok(Claim::RequestConflict) => {
            return problem("IDEMPOTENCY_KEY_REUSED", 409, &request_id);
        }
        Ok(Claim::InFlight) => return problem("IDEMPOTENCY_IN_PROGRESS", 409, &request_id),
        Ok(Claim::Execute) => {}
        Err(_) => return problem("DEPENDENCY_UNAVAILABLE", 503, &request_id),
    }
    let value = match dispatch(operation.id, &body, &state).await {
        Ok(value) => value,
        Err(error) => return service_problem(error, &request_id),
    };
    let stored = StoredResponse {
        status: i32::from(operation.success_status),
        body: value.clone(),
    };
    match complete(
        &state.pool,
        &idempotency.scope,
        &idempotency.key_hash,
        &idempotency.request_hash,
        &stored,
    )
    .await
    {
        Ok(true) => HttpResponse::build(
            StatusCode::from_u16(operation.success_status).unwrap_or(StatusCode::OK),
        )
        .insert_header(("x-request-id", request_id))
        .json(value),
        _ => problem("IDEMPOTENCY_COMPLETION_FAILED", 503, &request_id),
    }
}

async fn authorize(
    request: &HttpRequest,
    body: &[u8],
    state: &AppState,
) -> Result<(), HttpResponse> {
    let request_id = request_id(request);
    let token = header(request, "x-gurine-service-assertion")
        .ok_or_else(|| problem("SERVICE_ASSERTION_REQUIRED", 401, &request_id))?;
    let bound = bound_request(request, body, header(request, "idempotency-key"));
    let claims = verify_claims(
        token,
        &state.service_assertion_keys,
        &bound,
        ServiceExpectation {
            issuer: "review-console",
            audience: "identity-api",
            now: OffsetDateTime::now_utc().unix_timestamp(),
        },
    )
    .map_err(|error| assertion_problem(error, &request_id))?;
    let digest = canonical_request_digest(&bound)
        .map_err(|_| problem("SERVICE_ASSERTION_INVALID", 401, &request_id))?;
    let consumed = consume(
        &state.pool,
        &AssertionConsumption {
            assertion_type: "SERVICE",
            jti: &claims.jti,
            issuer: &claims.iss,
            audience: &claims.aud,
            expires_at_unix: claims.exp,
            request_digest: &digest,
        },
    )
    .await
    .map_err(|_| problem("DEPENDENCY_UNAVAILABLE", 503, &request_id))?;
    if !consumed {
        return Err(problem("SERVICE_ASSERTION_REPLAYED", 409, &request_id));
    }
    Ok(())
}

async fn dispatch(operation: &str, body: &[u8], state: &AppState) -> Result<Value, ServiceError> {
    match operation {
        "createLoginTransaction" => {
            json(service::create_login_transaction(state, parse(body)?).await?)
        }
        "consumeLoginCallback" => json(service::consume_login_callback(state, parse(body)?).await?),
        "createStepUpTransaction" => {
            json(service::create_step_up_transaction(state, parse(body)?).await?)
        }
        "consumeStepUpCallback" => {
            json(service::consume_step_up_callback(state, parse(body)?).await?)
        }
        "resolveInternalSession" => json(service::resolve_session(state, parse(body)?).await?),
        "revokeInternalSession" => json(service::revoke_session(state, parse(body)?).await?),
        "getSecurityManagementRedirectInternal" => {
            json(service::security_management_redirect(state, parse(body)?).await?)
        }
        "issueActorAssertion" => json(service::issue_actor_assertion(state, parse(body)?).await?),
        "closeStepUpAuthorization" => {
            json(service::close_step_up_authorization(state, parse(body)?).await?)
        }
        _ => Err(ServiceError::InvalidRequest),
    }
}

fn parse<T: DeserializeOwned>(body: &[u8]) -> Result<T, ServiceError> {
    serde_json::from_slice(body).map_err(|_| ServiceError::InvalidRequest)
}

fn json<T: serde::Serialize>(value: T) -> Result<Value, ServiceError> {
    serde_json::to_value(value).map_err(|_| ServiceError::InvalidRequest)
}

fn bound_request<'a>(
    request: &'a HttpRequest,
    body: &'a [u8],
    idempotency_key: Option<&'a str>,
) -> BoundRequest<'a> {
    BoundRequest {
        method: request.method().as_str(),
        path: request.path(),
        raw_query: request.query_string(),
        body,
        content_type: header(request, "content-type"),
        idempotency_key,
    }
}

fn request_id(request: &HttpRequest) -> String {
    header(request, "x-request-id")
        .and_then(|value| Uuid::parse_str(value).ok())
        .unwrap_or_else(Uuid::new_v4)
        .to_string()
}

fn header<'a>(request: &'a HttpRequest, name: &str) -> Option<&'a str> {
    request
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
}

fn stored_response(response: StoredResponse, request_id: &str) -> HttpResponse {
    let status = u16::try_from(response.status)
        .ok()
        .and_then(|value| StatusCode::from_u16(value).ok())
        .unwrap_or(StatusCode::OK);
    HttpResponse::build(status)
        .insert_header(("x-request-id", request_id))
        .insert_header(("idempotent-replay", "true"))
        .json(response.body)
}

fn assertion_problem(error: AssertionError, request_id: &str) -> HttpResponse {
    match error {
        AssertionError::Expired => problem("SERVICE_ASSERTION_EXPIRED", 401, request_id),
        AssertionError::AudienceMismatch => {
            problem("SERVICE_ASSERTION_AUDIENCE_MISMATCH", 401, request_id)
        }
        AssertionError::RequestMismatch => {
            problem("SERVICE_ASSERTION_REQUEST_MISMATCH", 401, request_id)
        }
        AssertionError::Replayed => problem("SERVICE_ASSERTION_REPLAYED", 409, request_id),
        _ => problem("SERVICE_ASSERTION_INVALID", 401, request_id),
    }
}

fn service_problem(error: ServiceError, request_id: &str) -> HttpResponse {
    match error {
        ServiceError::InvalidRequest => problem("INVALID_REQUEST", 400, request_id),
        ServiceError::CallbackBinding => problem("OIDC_CALLBACK_INVALID", 401, request_id),
        ServiceError::OidcUnavailable => problem("OIDC_PROVIDER_UNAVAILABLE", 502, request_id),
        ServiceError::OidcValidation => problem("OIDC_TOKEN_INVALID", 401, request_id),
        ServiceError::SessionNotActive => problem("SESSION_NOT_ACTIVE", 401, request_id),
        ServiceError::CsrfInvalid => problem("CSRF_TOKEN_STALE", 403, request_id),
        ServiceError::CapabilityDenied => problem("CAPABILITY_DENIED", 403, request_id),
        ServiceError::AssuranceInsufficient => problem("STEP_UP_REQUIRED", 403, request_id),
        ServiceError::Conflict => problem("RESOURCE_CONFLICT", 409, request_id),
        ServiceError::Persistence => problem("DEPENDENCY_UNAVAILABLE", 503, request_id),
        ServiceError::Cryptography => problem("CRYPTOGRAPHIC_OPERATION_FAILED", 500, request_id),
    }
}

fn problem(code: &str, status: u16, request_id: &str) -> HttpResponse {
    let status_code = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    HttpResponse::build(status_code)
        .insert_header(("content-type", "application/problem+json"))
        .insert_header(("x-request-id", request_id))
        .json(serde_json::json!({
            "code": code,
            "title": code,
            "status": status,
            "requestId": request_id,
        }))
}
