use std::{
    collections::HashSet,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};

use actix_web::{App, http::StatusCode, test as actix_test, web};
use gurine_auth::assertion::{
    AssertionError, BoundRequest,
    canonical::{canonical_request_digest, request_hashes, sha256_hex},
    service::{AssertionKey, KeyRing, ServiceClaims, sign},
};
use gurine_payment_providers::{ProviderKind, WebhookHeaders};
use serde_json::json;
use sqlx::postgres::PgPoolOptions;
use thiserror::Error;
use time::OffsetDateTime;
use uuid::Uuid;

use super::configure;
use crate::{
    app::{ApplicationFuture, BillingApplication},
    config::RuntimeMode,
    digest::Sha256Digest,
    payment::{
        DonationIntentRequest, DonationQueuedReceipt, FixtureDonationOffer, PaymentRuntimeError,
        WebhookProcessingReceipt,
    },
    state::{AppState, AssertionConsumptionRecord, AssertionFuture, AssertionReplayStore},
};

const DONATION_PATH: &str = "/internal/v1/donation-intents";
const CONTENT_TYPE: &str = "application/json";
const TEST_DATABASE_URL: &str = "postgresql://gurine:unused@127.0.0.1:1/gurine";
const ASSERTION_KEY_BYTES: [u8; 32] = [0x5a; 32];

#[derive(Debug, Error)]
enum TestError {
    #[error(transparent)]
    Assertion(#[from] AssertionError),
    #[error(transparent)]
    Database(#[from] sqlx::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[derive(Clone, Copy, Debug)]
enum AssertionVariant {
    Valid,
    WrongIssuer,
    WrongAudience,
    WrongBodyDigest,
}

#[derive(Default)]
struct CountingApplication {
    calls: AtomicUsize,
    last_request_digest: Mutex<Option<Sha256Digest>>,
}

impl CountingApplication {
    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }

    fn last_request_digest(&self) -> Option<Sha256Digest> {
        self.last_request_digest
            .lock()
            .ok()
            .and_then(|digest| digest.clone())
    }
}

impl BillingApplication for CountingApplication {
    fn fixture_offer(&self) -> Result<FixtureDonationOffer, PaymentRuntimeError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(FixtureDonationOffer::test_fixture())
    }

    fn queue_donation_intent<'a>(
        &'a self,
        request: DonationIntentRequest,
        request_digest: Sha256Digest,
    ) -> ApplicationFuture<'a, DonationQueuedReceipt> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let Ok(mut last_digest) = self.last_request_digest.lock() else {
            return Box::pin(async { Err(PaymentRuntimeError::Unavailable) });
        };
        *last_digest = Some(request_digest);
        let receipt = DonationQueuedReceipt {
            schema_version: "donation-intent-queued.v1",
            request_id: request.request_id,
            job_id: Uuid::from_u128(0x7001),
            status: "QUEUED",
            receipt_digest: Sha256Digest::of(b"route-test-receipt"),
        };
        Box::pin(async move { Ok(receipt) })
    }

    fn process_webhook<'a>(
        &'a self,
        _provider: ProviderKind,
        _headers: WebhookHeaders,
        _body: Vec<u8>,
        _now_unix: i64,
    ) -> ApplicationFuture<'a, WebhookProcessingReceipt> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Box::pin(async { Err(PaymentRuntimeError::Unavailable) })
    }
}

#[derive(Default)]
struct MemoryAssertionReplayStore {
    consumed: Mutex<HashSet<(&'static str, String)>>,
    calls: AtomicUsize,
}

impl MemoryAssertionReplayStore {
    fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }
}

impl AssertionReplayStore for MemoryAssertionReplayStore {
    fn consume<'a>(&'a self, record: &'a AssertionConsumptionRecord) -> AssertionFuture<'a> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let result = match self.consumed.lock() {
            Ok(mut consumed) => Ok(consumed.insert((record.assertion_type, record.jti.clone()))),
            Err(_) => Err(sqlx::Error::Protocol(
                "in-memory assertion replay lock was poisoned".to_owned(),
            )),
        };
        Box::pin(async move { result })
    }
}

struct TestContext {
    state: web::Data<AppState>,
    application: Arc<CountingApplication>,
    replay: Arc<MemoryAssertionReplayStore>,
}

fn test_context(mode: RuntimeMode) -> Result<TestContext, sqlx::Error> {
    let application = Arc::new(CountingApplication::default());
    let replay = Arc::new(MemoryAssertionReplayStore::default());
    let state = match mode {
        RuntimeMode::Disabled => AppState::disabled(),
        RuntimeMode::TestOnly => AppState::test_only_with_dependencies(
            PgPoolOptions::new().connect_lazy(TEST_DATABASE_URL)?,
            test_key_ring(),
            test_key_ring(),
            application.clone(),
            replay.clone(),
        ),
    };
    let state = web::Data::new(state);
    Ok(TestContext {
        state,
        application,
        replay,
    })
}

fn test_key_ring() -> KeyRing {
    KeyRing {
        current: AssertionKey::new(ASSERTION_KEY_BYTES),
        previous: None,
    }
}

fn donation_body(request_id: Uuid) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec(&json!({
        "schemaVersion": "donation-intent-request.v1",
        "requestId": request_id,
        "offerVersionId": Uuid::from_u128(0x7101),
        "offerDigest": "a".repeat(64),
        "tierId": Uuid::from_u128(0x7102),
        "cadence": "ONE_TIME",
        "provider": "TOSS_PAYMENTS",
        "consentReceiptDigest": "b".repeat(64),
        "paymentAuthorizationToken": "TEST_ONLY_OPAQUE_AUTHORIZATION",
    }))
}

fn bound_request<'a>(body: &'a [u8], idempotency_key: &'a str) -> BoundRequest<'a> {
    BoundRequest {
        method: "POST",
        path: DONATION_PATH,
        raw_query: "",
        body,
        content_type: Some(CONTENT_TYPE),
        idempotency_key: Some(idempotency_key),
        next_submission_session: None,
    }
}

fn signed_assertion(
    body: &[u8],
    idempotency_key: &str,
    jti: Uuid,
    variant: AssertionVariant,
) -> Result<String, AssertionError> {
    let hashes = request_hashes(&bound_request(body, idempotency_key))?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    let claims = ServiceClaims {
        aud: match variant {
            AssertionVariant::WrongAudience => "another-service",
            _ => "billing-gateway",
        }
        .to_owned(),
        body_sha256: match variant {
            AssertionVariant::WrongBodyDigest => sha256_hex(b"different-request-body"),
            _ => hashes.body_sha256,
        },
        content_type: hashes.content_type,
        exp: now + 30,
        iat: now,
        iss: match variant {
            AssertionVariant::WrongIssuer => "another-caller",
            _ => "public-web",
        }
        .to_owned(),
        jti: jti.to_string(),
        method: hashes.method,
        next_submission_session_sha256: None,
        path: hashes.path,
        query_sha256: hashes.query_sha256,
        typ: "service".to_owned(),
        v: 1,
    };
    sign(&claims, &AssertionKey::new(ASSERTION_KEY_BYTES))
}

#[actix_web::test]
async fn valid_assertion_is_accepted_once_and_same_jti_replay_is_rejected() -> Result<(), TestError>
{
    let request_id = Uuid::from_u128(0x7201);
    let idempotency_key = request_id.to_string();
    let body = donation_body(request_id)?;
    let assertion = signed_assertion(
        &body,
        &idempotency_key,
        Uuid::from_u128(0x7202),
        AssertionVariant::Valid,
    )?;
    let expected_digest = canonical_request_digest(&bound_request(&body, &idempotency_key))?;
    let context = test_context(RuntimeMode::TestOnly)?;
    let app = actix_test::init_service(
        App::new()
            .app_data(context.state.clone())
            .configure(configure),
    )
    .await;

    let first_request = actix_test::TestRequest::post()
        .uri(DONATION_PATH)
        .insert_header(("content-type", CONTENT_TYPE))
        .insert_header(("idempotency-key", idempotency_key.as_str()))
        .insert_header(("x-gurine-service-assertion", assertion.as_str()))
        .set_payload(body.clone())
        .to_request();
    let first_response = actix_test::call_service(&app, first_request).await;
    assert_eq!(first_response.status(), StatusCode::ACCEPTED);
    assert_eq!(context.application.calls(), 1);
    assert_eq!(context.replay.calls(), 1);
    assert_eq!(
        context
            .application
            .last_request_digest()
            .as_ref()
            .map(Sha256Digest::as_str),
        Some(expected_digest.as_str())
    );

    let replay_request = actix_test::TestRequest::post()
        .uri(DONATION_PATH)
        .insert_header(("content-type", CONTENT_TYPE))
        .insert_header(("idempotency-key", idempotency_key.as_str()))
        .insert_header(("x-gurine-service-assertion", assertion.as_str()))
        .set_payload(body)
        .to_request();
    let replay_response = actix_test::call_service(&app, replay_request).await;
    assert_eq!(replay_response.status(), StatusCode::CONFLICT);
    assert_eq!(context.application.calls(), 1);
    assert_eq!(context.replay.calls(), 2);
    Ok(())
}

#[actix_web::test]
async fn invalid_request_bound_assertions_are_rejected_before_application() -> Result<(), TestError>
{
    let request_id = Uuid::from_u128(0x7301);
    let idempotency_key = request_id.to_string();
    let body = donation_body(request_id)?;
    let context = test_context(RuntimeMode::TestOnly)?;
    let app = actix_test::init_service(
        App::new()
            .app_data(context.state.clone())
            .configure(configure),
    )
    .await;

    for (jti, variant) in [
        (Uuid::from_u128(0x7302), AssertionVariant::WrongIssuer),
        (Uuid::from_u128(0x7303), AssertionVariant::WrongAudience),
        (Uuid::from_u128(0x7304), AssertionVariant::WrongBodyDigest),
    ] {
        let assertion = signed_assertion(&body, &idempotency_key, jti, variant)?;
        let request = actix_test::TestRequest::post()
            .uri(DONATION_PATH)
            .insert_header(("content-type", CONTENT_TYPE))
            .insert_header(("idempotency-key", idempotency_key.as_str()))
            .insert_header(("x-gurine-service-assertion", assertion))
            .set_payload(body.clone())
            .to_request();
        let response = actix_test::call_service(&app, request).await;
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED, "{variant:?}");
        assert_eq!(context.application.calls(), 0, "{variant:?}");
        assert_eq!(context.replay.calls(), 0, "{variant:?}");
    }
    Ok(())
}

#[actix_web::test]
async fn disabled_runtime_returns_unavailable_before_authentication_or_application()
-> Result<(), TestError> {
    let request_id = Uuid::from_u128(0x7401);
    let body = donation_body(request_id)?;
    let context = test_context(RuntimeMode::Disabled)?;
    let app = actix_test::init_service(
        App::new()
            .app_data(context.state.clone())
            .configure(configure),
    )
    .await;
    let request = actix_test::TestRequest::post()
        .uri(DONATION_PATH)
        .insert_header(("content-type", CONTENT_TYPE))
        .insert_header(("idempotency-key", request_id.to_string()))
        .insert_header(("x-gurine-service-assertion", "not-an-assertion"))
        .set_payload(body)
        .to_request();

    let response = actix_test::call_service(&app, request).await;
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(context.replay.calls(), 0);
    assert_eq!(context.application.calls(), 0);
    Ok(())
}

#[actix_web::test]
async fn disabled_readiness_is_health_only_and_does_not_require_database() -> Result<(), TestError>
{
    let context = test_context(RuntimeMode::Disabled)?;
    assert_eq!(context.state.mode(), RuntimeMode::Disabled);
    assert!(context.state.test_only().is_none());
    let app = actix_test::init_service(
        App::new()
            .app_data(context.state.clone())
            .configure(configure),
    )
    .await;

    let request = actix_test::TestRequest::get()
        .uri("/health/ready")
        .to_request();
    let response = actix_test::call_service(&app, request).await;
    assert_eq!(response.status(), StatusCode::OK);
    let body: serde_json::Value = actix_test::read_body_json(response).await;
    assert_eq!(body["status"], "ready");
    assert_eq!(body["paymentRuntime"], "disabled");
    assert_eq!(context.replay.calls(), 0);
    assert_eq!(context.application.calls(), 0);
    Ok(())
}
