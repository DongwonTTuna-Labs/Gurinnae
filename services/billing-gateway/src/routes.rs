use actix_web::{HttpRequest, HttpResponse, http::StatusCode, web};
use gurine_auth::assertion::{
    AssertionError, BoundRequest,
    canonical::canonical_request_digest,
    service::{KeyRing, ServiceExpectation, verify_claims},
};
use gurine_payment_providers::{ProviderKind, SecretText, WebhookHeaders};
use time::OffsetDateTime;
use uuid::Uuid;

use crate::{
    digest::Sha256Digest,
    payment::{DonationIntentRequest, PaymentRuntimeError},
    state::{AppState, AssertionConsumptionRecord, TestOnlyState},
};

const MAX_WEBHOOK_BYTES: usize = 65_536;

pub fn configure(config: &mut web::ServiceConfig) {
    config
        .service(web::resource("/health/live").route(web::get().to(live)))
        .service(web::resource("/health/ready").route(web::get().to(ready)))
        .service(
            web::resource("/internal/v1/donation-offers")
                .name("private.GetDonationFixtureOffer")
                .route(web::get().to(get_fixture_offer)),
        )
        .service(
            web::resource("/internal/v1/donation-intents")
                .name("private.QueueDonationIntent")
                .route(web::post().to(queue_donation_intent)),
        )
        .service(
            web::resource("/internal/v1/payment-webhooks/{provider}")
                .name("private.ReceivePaymentWebhook")
                .route(web::post().to(receive_payment_webhook)),
        );
}

async fn live() -> HttpResponse {
    HttpResponse::Ok().json(serde_json::json!({"status":"live"}))
}

async fn ready(state: web::Data<AppState>) -> HttpResponse {
    let Some(runtime) = state.test_only() else {
        return HttpResponse::Ok().json(serde_json::json!({
            "status": "ready",
            "paymentRuntime": "disabled",
        }));
    };
    match sqlx::query_scalar::<_, i32>("SELECT 1")
        .fetch_one(runtime.pool())
        .await
    {
        Ok(1) => HttpResponse::Ok().json(serde_json::json!({"status":"ready"})),
        _ => problem("DEPENDENCY_UNAVAILABLE", 503, &Uuid::new_v4().to_string()),
    }
}

async fn get_fixture_offer(request: HttpRequest, state: web::Data<AppState>) -> HttpResponse {
    let request_id = request_id(&request);
    let runtime = match test_only_runtime(&state, &request_id) {
        Ok(runtime) => runtime,
        Err(response) => return response,
    };
    if let Err(response) = authorize(
        &request,
        &[],
        runtime.public_web_keys(),
        "public-web",
        None,
        runtime,
        &request_id,
    )
    .await
    {
        return response;
    }
    match runtime.application().fixture_offer() {
        Ok(offer) => HttpResponse::Ok()
            .insert_header(("x-request-id", request_id))
            .json(offer),
        Err(error) => payment_problem(error, &request_id),
    }
}

async fn queue_donation_intent(
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<AppState>,
) -> HttpResponse {
    let request_id = request_id(&request);
    let runtime = match test_only_runtime(&state, &request_id) {
        Ok(runtime) => runtime,
        Err(response) => return response,
    };
    let idempotency_key = match single_header(&request, "idempotency-key") {
        Ok(Some(value)) => value,
        _ => return problem("IDEMPOTENCY_KEY_REQUIRED", 400, &request_id),
    };
    let request_digest = match authorize(
        &request,
        &body,
        runtime.public_web_keys(),
        "public-web",
        Some(&idempotency_key),
        runtime,
        &request_id,
    )
    .await
    {
        Ok(digest) => digest,
        Err(response) => return response,
    };
    let intent = match serde_json::from_slice::<DonationIntentRequest>(&body) {
        Ok(intent) => intent,
        Err(_) => return problem("DONATION_INTENT_INVALID", 400, &request_id),
    };
    if Uuid::parse_str(&idempotency_key).ok() != Some(intent.request_id) {
        return problem("IDEMPOTENCY_KEY_INVALID", 400, &request_id);
    }
    let request_digest = match request_digest.parse::<Sha256Digest>() {
        Ok(digest) => digest,
        Err(_) => return problem("REQUEST_BINDING_INVALID", 400, &request_id),
    };
    match runtime
        .application()
        .queue_donation_intent(intent, request_digest)
        .await
    {
        Ok(receipt) => HttpResponse::Accepted()
            .insert_header(("x-request-id", request_id))
            .json(receipt),
        Err(error) => payment_problem(error, &request_id),
    }
}

async fn receive_payment_webhook(
    request: HttpRequest,
    body: web::Bytes,
    path: web::Path<String>,
    state: web::Data<AppState>,
) -> HttpResponse {
    let request_id = request_id(&request);
    let runtime = match test_only_runtime(&state, &request_id) {
        Ok(runtime) => runtime,
        Err(response) => return response,
    };
    if body.is_empty() || body.len() > MAX_WEBHOOK_BYTES {
        return problem("PAYMENT_WEBHOOK_INVALID", 400, &request_id);
    }
    if let Err(response) = authorize(
        &request,
        &body,
        runtime.payment_fixture_keys(),
        "payment-fixture",
        None,
        runtime,
        &request_id,
    )
    .await
    {
        return response;
    }
    let provider = match path.as_str() {
        "toss-payments" => ProviderKind::TossPayments,
        "kakao-pay" => ProviderKind::KakaoPay,
        "stripe" => ProviderKind::Stripe,
        _ => return problem("PAYMENT_PROVIDER_INVALID", 400, &request_id),
    };
    let headers = match webhook_headers(provider, &request) {
        Ok(headers) => headers,
        Err(_) => return problem("PAYMENT_WEBHOOK_AUTHENTICATION_FAILED", 401, &request_id),
    };
    match runtime
        .application()
        .process_webhook(
            provider,
            headers,
            body.to_vec(),
            OffsetDateTime::now_utc().unix_timestamp(),
        )
        .await
    {
        Ok(receipt) => HttpResponse::Ok()
            .insert_header(("x-request-id", request_id))
            .json(receipt),
        Err(error) => payment_problem(error, &request_id),
    }
}

async fn authorize(
    request: &HttpRequest,
    body: &[u8],
    keys: &KeyRing,
    issuer: &'static str,
    idempotency_key: Option<&str>,
    runtime: &TestOnlyState,
    request_id: &str,
) -> Result<String, HttpResponse> {
    let token = single_header(request, "x-gurine-service-assertion")
        .ok()
        .flatten()
        .ok_or_else(|| problem("SERVICE_ASSERTION_REQUIRED", 401, request_id))?;
    let content_type = single_header(request, "content-type")
        .map_err(|_| problem("SERVICE_ASSERTION_INVALID", 401, request_id))?;
    let bound = BoundRequest {
        method: request.method().as_str(),
        path: request.path(),
        raw_query: request.query_string(),
        body,
        content_type: content_type.as_deref(),
        idempotency_key,
        next_submission_session: None,
    };
    let claims = verify_claims(
        &token,
        keys,
        &bound,
        ServiceExpectation {
            issuer,
            audience: "billing-gateway",
            now: OffsetDateTime::now_utc().unix_timestamp(),
        },
    )
    .map_err(|error| assertion_problem(error, request_id))?;
    let digest = canonical_request_digest(&bound)
        .map_err(|_| problem("SERVICE_ASSERTION_INVALID", 401, request_id))?;
    let consumed = runtime
        .assertion_replay()
        .consume(&AssertionConsumptionRecord {
            assertion_type: "SERVICE",
            jti: claims.jti,
            issuer: claims.iss,
            audience: claims.aud,
            expires_at_unix: claims.exp,
            request_digest: digest.clone(),
        })
        .await
        .map_err(|_| problem("DEPENDENCY_UNAVAILABLE", 503, request_id))?;
    if !consumed {
        return Err(problem("SERVICE_ASSERTION_REPLAYED", 409, request_id));
    }
    Ok(digest)
}

fn test_only_runtime<'a>(
    state: &'a AppState,
    request_id: &str,
) -> Result<&'a TestOnlyState, HttpResponse> {
    state
        .test_only()
        .ok_or_else(|| problem("PAYMENT_RUNTIME_UNAVAILABLE", 503, request_id))
}

fn webhook_headers(provider: ProviderKind, request: &HttpRequest) -> Result<WebhookHeaders, ()> {
    match provider {
        ProviderKind::Stripe => {
            let signature = single_header(request, "stripe-signature")
                .map_err(|_| ())?
                .ok_or(())?;
            Ok(WebhookHeaders::stripe(
                SecretText::try_new(signature).map_err(|_| ())?,
            ))
        }
        ProviderKind::TossPayments | ProviderKind::KakaoPay => {
            if single_header(request, "stripe-signature")
                .map_err(|_| ())?
                .is_some()
            {
                Err(())
            } else {
                Ok(WebhookHeaders::none())
            }
        }
    }
}

fn single_header(request: &HttpRequest, name: &str) -> Result<Option<String>, ()> {
    let mut values = request.headers().get_all(name);
    let Some(value) = values.next() else {
        return Ok(None);
    };
    if values.next().is_some() {
        return Err(());
    }
    let value = value.to_str().map_err(|_| ())?;
    if value.is_empty() {
        Err(())
    } else {
        Ok(Some(value.to_owned()))
    }
}

fn request_id(request: &HttpRequest) -> String {
    single_header(request, "x-request-id")
        .ok()
        .flatten()
        .and_then(|value| Uuid::parse_str(&value).ok())
        .unwrap_or_else(Uuid::new_v4)
        .to_string()
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
        _ => problem("SERVICE_ASSERTION_INVALID", 401, request_id),
    }
}

fn payment_problem(error: PaymentRuntimeError, request_id: &str) -> HttpResponse {
    match error {
        PaymentRuntimeError::Unavailable => problem("PAYMENT_RUNTIME_UNAVAILABLE", 503, request_id),
        PaymentRuntimeError::InvalidRequest => problem("PAYMENT_REQUEST_INVALID", 400, request_id),
        PaymentRuntimeError::Conflict => problem("PAYMENT_RECEIPT_CONFLICT", 409, request_id),
        PaymentRuntimeError::InProgress => problem("PAYMENT_IN_PROGRESS", 503, request_id),
        PaymentRuntimeError::AuthenticationFailed => {
            problem("PAYMENT_WEBHOOK_AUTHENTICATION_FAILED", 401, request_id)
        }
        PaymentRuntimeError::ReconciliationRequired => {
            problem("PAYMENT_RECONCILIATION_REQUIRED", 503, request_id)
        }
        PaymentRuntimeError::OwnerFunction => problem("DEPENDENCY_UNAVAILABLE", 503, request_id),
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

#[cfg(test)]
#[path = "routes_tests.rs"]
mod tests;
