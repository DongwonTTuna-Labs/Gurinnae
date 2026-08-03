use std::collections::BTreeMap;

use actix_web::{HttpRequest, HttpResponse, http::StatusCode, web};
use gurine_api_contracts::{OperationSpec, addendum, submission_api::OPERATIONS};
use gurine_application::idempotency;
use gurine_auth::assertion::{
    AssertionError,
    canonical::{canonical_request_digest, sha256_hex},
    service::{ServiceClaims, ServiceExpectation, verify_claims},
};
use gurine_persistence_postgres::{
    assertions::{AssertionConsumption, consume},
    idempotency::{Claim, StoredResponse, claim, complete, release},
};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::state::AppState;

mod idempotency_binding;
mod problem_mapping;
mod request_binding;
#[cfg(test)]
mod tests;

use idempotency_binding::{IdempotencyBindingError, derive, derive_owner};
use problem_mapping::service_problem;
use request_binding::{bound_request, header, privacy_exchange_authority_is_closed, request_id};

pub fn configure(config: &mut web::ServiceConfig) {
    let mut by_path = BTreeMap::<&str, Vec<OperationSpec>>::new();
    for operation in OPERATIONS
        .iter()
        .chain(addendum::SUBMISSION_OPERATIONS.iter())
    {
        by_path.entry(operation.path).or_default().push(*operation);
    }
    let mut resources = by_path.into_iter().collect::<Vec<_>>();
    resources.sort_by(|(left, _), (right, _)| {
        right.len().cmp(&left.len()).then_with(|| left.cmp(right))
    });
    for (path, operations) in resources {
        let mut resource = web::resource(path);
        for operation in operations {
            let copy = operation;
            resource = match operation.method {
                "GET" => resource.route(web::get().to(move |r, b, s| handle(copy, r, b, s))),
                "POST" => resource.route(web::post().to(move |r, b, s| handle(copy, r, b, s))),
                "PUT" => resource.route(web::put().to(move |r, b, s| handle(copy, r, b, s))),
                "PATCH" => resource.route(web::patch().to(move |r, b, s| handle(copy, r, b, s))),
                "DELETE" => resource.route(web::delete().to(move |r, b, s| handle(copy, r, b, s))),
                _ => resource,
            };
        }
        config.service(resource);
    }
}

pub async fn upload_attachment(
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<AppState>,
) -> HttpResponse {
    let request_id = request_id(&request);
    let caller = match authorize(&request, &body, &state, &request_id).await {
        Ok(value) => value,
        Err(response) => return response,
    };
    let Some(session_token) = header(&request, "x-gurine-submission-session") else {
        return problem("SUBMISSION_SESSION_REQUIRED", 401, &request_id);
    };
    let attachment_id = match request
        .match_info()
        .get("attachmentId")
        .map(Uuid::parse_str)
        .transpose()
    {
        Ok(Some(value)) => value,
        _ => return problem("INVALID_PARAMETER", 400, &request_id),
    };
    if body.is_empty() || body.len() > state.max_upload_bytes {
        return problem("PAYLOAD_TOO_LARGE", 413, &request_id);
    }
    let (object_key, expected_size, expected_sha256) =
        match scoped_attachment(state.get_ref(), &caller, session_token, attachment_id).await {
            Ok(value) => value,
            Err(status) => return problem(status.0, status.1, &request_id),
        };
    let actual_size = match i64::try_from(body.len()) {
        Ok(value) => value,
        Err(_) => return problem("PAYLOAD_TOO_LARGE", 413, &request_id),
    };
    let actual_sha256 = sha256_hex(&body);
    if actual_size != expected_size || actual_sha256 != expected_sha256 {
        return problem("ATTACHMENT_CONTENT_MISMATCH", 422, &request_id);
    }
    let stored = match state
        .attachment_store
        .put(&object_key, body.to_vec(), &expected_sha256)
        .await
    {
        Ok(value) => value,
        Err(_) => return problem("OBJECT_STORE_UNAVAILABLE", 503, &request_id),
    };
    let mut response = HttpResponse::NoContent();
    response.insert_header(("x-request-id", request_id));
    if let Some(etag) = stored.etag {
        response.insert_header(("etag", etag));
    }
    response.finish()
}

async fn scoped_attachment(
    state: &AppState,
    caller: &ServiceClaims,
    session_token: &str,
    attachment_id: Uuid,
) -> Result<(String, i64, String), (&'static str, u16)> {
    let scoped: Result<serde_json::Value, _> = match caller.iss.as_str() {
        "public-web" => sqlx::query_scalar!(
            "SELECT intake.get_correction_draft_preview_session($1,$2) AS \"value?\"",
            sha256_hex(session_token.as_bytes()),
            &caller.iss
        )
        .fetch_one(&state.pool)
        .await
        .and_then(|value| {
            value.ok_or_else(|| sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError)))
        }),
        "response-portal" => sqlx::query_scalar!(
            "SELECT intake.get_response_preview_session_v2($1,$2) AS \"value?\"",
            sha256_hex(session_token.as_bytes()),
            &caller.iss
        )
        .fetch_one(&state.pool)
        .await
        .and_then(|value| {
            value.ok_or_else(|| sqlx::Error::Decode(Box::new(sqlx::error::UnexpectedNullError)))
        }),
        _ => return Err(("BFF_CALLER_DENIED", 403)),
    };
    let scoped = scoped.map_err(|_| ("ATTACHMENT_UPLOAD_TARGET_INVALID", 404))?;
    let id = attachment_id.to_string();
    let target = scoped
        .get("attachments")
        .and_then(serde_json::Value::as_array)
        .and_then(|items| {
            items.iter().find(|item| {
                item.get("id").and_then(serde_json::Value::as_str) == Some(id.as_str())
            })
        })
        .ok_or(("ATTACHMENT_UPLOAD_TARGET_INVALID", 404))?;
    if target
        .get("upload_status")
        .and_then(serde_json::Value::as_str)
        != Some("PENDING")
    {
        return Err(("ATTACHMENT_UPLOAD_TARGET_INVALID", 409));
    }
    let object_key = target
        .get("object_key")
        .and_then(serde_json::Value::as_str)
        .ok_or(("DEPENDENCY_UNAVAILABLE", 503))?
        .to_owned();
    let expected_size = target
        .get("size_bytes")
        .and_then(serde_json::Value::as_i64)
        .ok_or(("DEPENDENCY_UNAVAILABLE", 503))?;
    let expected_sha256 = target
        .get("sha256")
        .and_then(serde_json::Value::as_str)
        .ok_or(("DEPENDENCY_UNAVAILABLE", 503))?
        .trim()
        .to_owned();
    Ok((object_key, expected_size, expected_sha256))
}

async fn handle(
    operation: OperationSpec,
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<AppState>,
) -> HttpResponse {
    let request_id = request_id(&request);
    let caller = match authorize(&request, &body, &state, &request_id).await {
        Ok(value) => value,
        Err(response) => return response,
    };
    if !caller_allowed(operation.id, &caller.iss) {
        return problem("BFF_CALLER_DENIED", 403, &request_id);
    }
    if !privacy_exchange_authority_is_closed(operation.id, &request) {
        return problem("SERVICE_ASSERTION_REQUEST_MISMATCH", 401, &request_id);
    }
    let session_token = header(&request, "x-gurine-submission-session").map(str::to_owned);
    let session_id = match validate_operation_session(
        &operation,
        session_token.as_deref(),
        &caller.iss,
        &state,
        &request_id,
    )
    .await
    {
        Ok(value) => value,
        Err(response) => return response,
    };
    let attachment_id = match parse_attachment_id(request.match_info().get("attachmentId")) {
        Ok(value) => value,
        Err(()) => return problem("INVALID_PARAMETER", 400, &request_id),
    };
    let owner_idempotency = if owner_atomic_idempotency(operation.id) {
        match derive_owner(&operation, &request, &body) {
            Ok(value) => Some(value),
            Err(error) => return idempotency_problem(error, &request_id),
        }
    } else {
        None
    };
    let idempotency = if operation.idempotency_required && owner_idempotency.is_none() {
        match prepare_idempotency(&operation, &request, &body, &state, &request_id).await {
            Ok(Prepared::Replay(response)) => return stored_response(response, &request_id),
            Ok(Prepared::Execute(value)) => Some(value),
            Err(response) => return response,
        }
    } else {
        None
    };
    let output = match crate::service::execute(crate::service::RequestContext {
        operation: operation.id,
        body: &body,
        issuer: &caller.iss,
        request_id: &request_id,
        session_token: session_token.as_deref(),
        session_id,
        idempotency_key_hash: owner_idempotency
            .as_ref()
            .or(idempotency.as_ref())
            .map(|value| value.key_hash.as_str()),
        request_hash: owner_idempotency
            .as_ref()
            .or(idempotency.as_ref())
            .map(|value| value.request_hash.as_str()),
        next_session_token: header(&request, "x-gurine-next-submission-session"),
        attachment_id,
        state: &state,
    })
    .await
    {
        Ok(value) => value,
        Err(error) => {
            if let Some(prepared) = idempotency.as_ref()
                && !matches!(
                    release(
                        &state.pool,
                        &prepared.scope,
                        &prepared.key_hash,
                        &prepared.request_hash,
                    )
                    .await,
                    Ok(true)
                )
            {
                return problem("DEPENDENCY_UNAVAILABLE", 503, &request_id);
            }
            return service_problem(error, &request_id);
        }
    };
    if let Err(response) = complete_idempotency(
        &state,
        operation.success_status,
        idempotency,
        &output,
        &request_id,
    )
    .await
    {
        return response;
    }
    response(
        operation.success_status,
        operation.media_type,
        output,
        &request_id,
    )
}

fn parse_attachment_id(value: Option<&str>) -> Result<Option<Uuid>, ()> {
    value.map(Uuid::parse_str).transpose().map_err(|_| ())
}

async fn complete_idempotency(
    state: &AppState,
    success_status: u16,
    idempotency: Option<idempotency::IdempotencyRequest>,
    output: &serde_json::Value,
    request_id: &str,
) -> Result<(), HttpResponse> {
    let Some(prepared) = idempotency else {
        return Ok(());
    };
    let stored = StoredResponse {
        status: i32::from(success_status),
        body: output.clone(),
    };
    if matches!(
        complete(
            &state.pool,
            &prepared.scope,
            &prepared.key_hash,
            &prepared.request_hash,
            &stored
        )
        .await,
        Ok(true)
    ) {
        Ok(())
    } else {
        Err(problem("IDEMPOTENCY_COMPLETION_FAILED", 503, request_id))
    }
}

async fn validate_operation_session(
    operation: &OperationSpec,
    session_token: Option<&str>,
    issuer: &str,
    state: &AppState,
    request_id: &str,
) -> Result<Option<Uuid>, HttpResponse> {
    if !operation.auth.contains("scoped-submission-session") {
        return Ok(None);
    }
    if owner_authorizes_session(operation.id) {
        return Ok(None);
    }
    let Some(token) = session_token else {
        return Err(problem("SUBMISSION_SESSION_REQUIRED", 401, request_id));
    };
    validate_session(
        state,
        token,
        issuer,
        allowed_session_kinds(operation.id),
        request_id,
    )
    .await
    .map(Some)
}

fn owner_authorizes_session(operation: &str) -> bool {
    operation == "getPrivacyRequest"
}

async fn authorize(
    request: &HttpRequest,
    body: &[u8],
    state: &AppState,
    request_id: &str,
) -> Result<ServiceClaims, HttpResponse> {
    let token = header(request, "x-gurine-service-assertion")
        .ok_or_else(|| problem("SERVICE_ASSERTION_REQUIRED", 401, request_id))?;
    let bound =
        bound_request(request, body).map_err(|error| assertion_problem(error, request_id))?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    let public = verify_claims(
        token,
        &state.public_web_keys,
        &bound,
        ServiceExpectation {
            issuer: "public-web",
            audience: "submission-api",
            now,
        },
    );
    let claims = match public {
        Ok(value) => value,
        Err(_) => verify_claims(
            token,
            &state.response_portal_keys,
            &bound,
            ServiceExpectation {
                issuer: "response-portal",
                audience: "submission-api",
                now,
            },
        )
        .map_err(|error| {
            tracing::warn!(?error, "submission service assertion rejected");
            assertion_problem(error, request_id)
        })?,
    };
    let digest = canonical_request_digest(&bound)
        .map_err(|_| problem("SERVICE_ASSERTION_INVALID", 401, request_id))?;
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
    .map_err(|_| problem("DEPENDENCY_UNAVAILABLE", 503, request_id))?;
    if !consumed {
        return Err(problem("SERVICE_ASSERTION_REPLAYED", 409, request_id));
    }
    Ok(claims)
}

async fn validate_session(
    state: &AppState,
    token: &str,
    issuer: &str,
    kinds: &[&str],
    request_id: &str,
) -> Result<Uuid, HttpResponse> {
    if token.len() < 43 || kinds.is_empty() {
        return Err(problem("SUBMISSION_SESSION_INVALID", 401, request_id));
    }
    let kinds = kinds
        .iter()
        .map(|value| (*value).to_owned())
        .collect::<Vec<_>>();
    let session_id = sqlx::query!(
        "SELECT session_id AS \"session_id?\" FROM intake.resolve_submission_session($1,$2,$3)",
        sha256_hex(token.as_bytes()),
        issuer,
        &kinds
    )
    .fetch_optional(&state.pool)
    .await
    .map_err(|_| problem("SUBMISSION_SESSION_INVALID", 401, request_id))?
    .and_then(|row| row.session_id)
    .ok_or_else(|| problem("SUBMISSION_SESSION_INVALID", 401, request_id))?;
    Ok(session_id)
}

enum Prepared {
    Execute(idempotency::IdempotencyRequest),
    Replay(StoredResponse),
}

async fn prepare_idempotency(
    operation: &OperationSpec,
    request: &HttpRequest,
    body: &[u8],
    state: &AppState,
    request_id: &str,
) -> Result<Prepared, HttpResponse> {
    let prepared =
        derive(operation, request, body).map_err(|error| idempotency_problem(error, request_id))?;
    match claim(
        &state.pool,
        &prepared.scope,
        &prepared.key_hash,
        &prepared.request_hash,
    )
    .await
    {
        Ok(Claim::Execute) => Ok(Prepared::Execute(prepared)),
        Ok(Claim::Replay(response)) => Ok(Prepared::Replay(response)),
        Ok(Claim::RequestConflict) => Err(problem("IDEMPOTENCY_KEY_REUSED", 409, request_id)),
        Ok(Claim::InFlight) => Err(problem("IDEMPOTENCY_IN_PROGRESS", 409, request_id)),
        Err(_) => Err(problem("DEPENDENCY_UNAVAILABLE", 503, request_id)),
    }
}

fn idempotency_problem(error: IdempotencyBindingError, request_id: &str) -> HttpResponse {
    match error {
        IdempotencyBindingError::MissingKey => problem("IDEMPOTENCY_KEY_REQUIRED", 400, request_id),
        IdempotencyBindingError::InvalidKey => problem("IDEMPOTENCY_KEY_INVALID", 400, request_id),
        IdempotencyBindingError::Binding => problem("INVALID_REQUEST_BINDING", 400, request_id),
    }
}

fn owner_atomic_idempotency(operation: &str) -> bool {
    matches!(
        operation,
        "createPrivacyRequest" | "exchangePrivacyRequestReceiptToken" | "submitResponse"
    )
}

fn caller_allowed(operation: &str, issuer: &str) -> bool {
    let response_operation = operation.contains("Response") || operation == "verifyResponseAccess";
    if response_operation {
        issuer == "response-portal"
    } else {
        issuer == "public-web"
    }
}

fn allowed_session_kinds(operation: &str) -> &'static [&'static str] {
    match operation {
        "getResponseAccessStatus" => &["RESPONSE_PENDING", "RESPONSE_ACTIVE"],
        "verifyResponseAccess" => &["RESPONSE_PENDING"],
        "getResponseReceipt" => &["RESPONSE_RECEIPT"],
        value if value.contains("Response") => &["RESPONSE_ACTIVE"],
        "getCorrectionReceipt" => &["CORRECTION_RECEIPT"],
        value if value.contains("Correction") => &["CORRECTION_DRAFT"],
        "getSubscription" | "updateSubscription" | "unsubscribe" => &["SUBSCRIPTION_MANAGEMENT"],
        "getPrivacyRequest" => &["PRIVACY_REQUEST_RECEIPT"],
        _ => &[],
    }
}

fn assertion_problem(error: AssertionError, request_id: &str) -> HttpResponse {
    match error {
        AssertionError::Expired => problem("SERVICE_ASSERTION_EXPIRED", 401, request_id),
        AssertionError::RequestMismatch => {
            problem("SERVICE_ASSERTION_REQUEST_MISMATCH", 401, request_id)
        }
        _ => problem("SERVICE_ASSERTION_INVALID", 401, request_id),
    }
}

fn response(
    status: u16,
    media_type: &str,
    body: serde_json::Value,
    request_id: &str,
) -> HttpResponse {
    let status = StatusCode::from_u16(status).unwrap_or(StatusCode::OK);
    let mut response = HttpResponse::build(status);
    response.insert_header(("x-request-id", request_id));
    if media_type.is_empty() {
        response.finish()
    } else if media_type == "application/json" {
        response.json(body)
    } else {
        response
            .insert_header(("content-type", media_type))
            .body(body.as_str().unwrap_or_default().to_owned())
    }
}

fn stored_response(response: StoredResponse, request_id: &str) -> HttpResponse {
    let status = u16::try_from(response.status).unwrap_or(200);
    HttpResponse::build(StatusCode::from_u16(status).unwrap_or(StatusCode::OK))
        .insert_header(("x-request-id", request_id))
        .insert_header(("idempotent-replay", "true"))
        .json(response.body)
}

fn problem(code: &str, status: u16, request_id: &str) -> HttpResponse {
    let status = StatusCode::from_u16(status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    HttpResponse::build(status)
        .insert_header(("content-type", "application/problem+json"))
        .insert_header(("x-request-id", request_id))
        .json(serde_json::json!({
            "code":code,"title":code,"status":status.as_u16(),"requestId":request_id
        }))
}
