use gurine_auth::{
    assertion::{
        AssertionError, BoundRequest, MemoryReplayGuard,
        actor::{ActorClaims, sign as sign_actor},
        canonical::sha256_hex,
        service::{
            AssertionKey, KeyRing, ServiceClaims, ServiceExpectation, ServiceVerification,
            sign as sign_service, verify as verify_service,
        },
    },
    envelope::{EnvelopeError, EnvelopeKey, EnvelopeKeyRing, decrypt, encrypt_with_nonce},
    session::{CookieContext, InternalSessionCookiePayload, seal_with_nonce},
};
use serde_json::Value;

fn vector(path: &str) -> Result<Value, AssertionError> {
    let text = match path {
        "service" => include_str!("../../../specs/auth/test-vectors/service-assertion.json"),
        "actor" => include_str!("../../../specs/auth/test-vectors/actor-assertion.json"),
        _ => return Err(AssertionError::SchemaInvalid),
    };
    serde_json::from_str(text).map_err(|_| AssertionError::SchemaInvalid)
}

#[test]
fn service_assertion_matches_authority_vector() -> Result<(), AssertionError> {
    let value = vector("service")?;
    let claims: ServiceClaims = serde_json::from_value(
        value
            .get("payload")
            .cloned()
            .ok_or(AssertionError::SchemaInvalid)?,
    )
    .map_err(|_| AssertionError::SchemaInvalid)?;
    let key = AssertionKey::new(std::array::from_fn(|index| index as u8));
    let token = sign_service(&claims, &key)?;
    assert_eq!(
        token,
        value
            .get("token")
            .and_then(Value::as_str)
            .ok_or(AssertionError::SchemaInvalid)?
    );
    Ok(())
}

#[test]
fn actor_assertion_matches_authority_vector() -> Result<(), AssertionError> {
    let value = vector("actor")?;
    let claims: ActorClaims = serde_json::from_value(
        value
            .get("payload")
            .cloned()
            .ok_or(AssertionError::SchemaInvalid)?,
    )
    .map_err(|_| AssertionError::SchemaInvalid)?;
    let key = AssertionKey::new(std::array::from_fn(|index| (index + 32) as u8));
    let token = sign_actor(&claims, &key)?;
    assert_eq!(
        token,
        value
            .get("token")
            .and_then(Value::as_str)
            .ok_or(AssertionError::SchemaInvalid)?
    );
    Ok(())
}

#[test]
fn exact_request_binding_and_single_use_are_enforced() -> Result<(), AssertionError> {
    let body = br#"{"sessionToken":"opaque"}"#;
    let claims = ServiceClaims {
        aud: "identity-api".to_owned(),
        body_sha256: sha256_hex(body),
        content_type: "application/json".to_owned(),
        exp: 1_783_814_430,
        iat: 1_783_814_400,
        iss: "review-console".to_owned(),
        jti: "11111111-1111-4111-8111-111111111111".to_owned(),
        method: "POST".to_owned(),
        next_submission_session_sha256: None,
        path: "/internal/v1/sessions/resolve".to_owned(),
        query_sha256: sha256_hex(b""),
        typ: "service".to_owned(),
        v: 1,
    };
    let key = AssertionKey::new(std::array::from_fn(|index| index as u8));
    let token = sign_service(&claims, &key)?;
    let keys = KeyRing {
        current: key,
        previous: None,
    };
    let request = BoundRequest {
        method: "POST",
        path: "/internal/v1/sessions/resolve",
        raw_query: "",
        body,
        content_type: Some("application/json; charset=utf-8"),
        idempotency_key: None,
        next_submission_session: None,
    };
    let guard = MemoryReplayGuard::default();
    let verification = || ServiceVerification {
        expectation: ServiceExpectation {
            issuer: "review-console",
            audience: "identity-api",
            now: 1_783_814_405,
        },
        replay_guard: &guard,
    };
    verify_service(&token, &keys, &request, verification())?;
    assert!(matches!(
        verify_service(&token, &keys, &request, verification()),
        Err(AssertionError::Replayed)
    ));
    Ok(())
}

#[test]
fn next_submission_session_is_digest_bound_and_single_use() -> Result<(), AssertionError> {
    let body = br#"{"receiptToken":"opaque"}"#;
    let next_session = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    let claims = ServiceClaims {
        aud: "submission-api".to_owned(),
        body_sha256: sha256_hex(body),
        content_type: "application/json".to_owned(),
        exp: 1_783_814_430,
        iat: 1_783_814_400,
        iss: "response-portal".to_owned(),
        jti: "22222222-2222-4222-8222-222222222222".to_owned(),
        method: "POST".to_owned(),
        next_submission_session_sha256: Some(sha256_hex(next_session.as_bytes())),
        path: "/v1/internal/privacy-requests/exchange".to_owned(),
        query_sha256: sha256_hex(b""),
        typ: "service".to_owned(),
        v: 1,
    };
    let key = AssertionKey::new(std::array::from_fn(|index| index as u8));
    let token = sign_service(&claims, &key)?;
    assert!(!token.contains(next_session));
    let keys = KeyRing {
        current: key,
        previous: None,
    };
    let request = BoundRequest {
        method: "POST",
        path: "/v1/internal/privacy-requests/exchange",
        raw_query: "",
        body,
        content_type: Some("application/json"),
        idempotency_key: None,
        next_submission_session: Some(next_session),
    };
    let guard = MemoryReplayGuard::default();
    let verification = || ServiceVerification {
        expectation: ServiceExpectation {
            issuer: "response-portal",
            audience: "submission-api",
            now: 1_783_814_405,
        },
        replay_guard: &guard,
    };

    verify_service(&token, &keys, &request, verification())?;
    assert!(matches!(
        verify_service(&token, &keys, &request, verification()),
        Err(AssertionError::Replayed)
    ));
    Ok(())
}

#[test]
fn next_submission_session_mismatch_and_unbound_header_are_rejected() -> Result<(), AssertionError>
{
    let body = br#"{"receiptToken":"opaque"}"#;
    let signed_session = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    let other_session = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
    let claims = ServiceClaims {
        aud: "submission-api".to_owned(),
        body_sha256: sha256_hex(body),
        content_type: "application/json".to_owned(),
        exp: 1_783_814_430,
        iat: 1_783_814_400,
        iss: "response-portal".to_owned(),
        jti: "33333333-3333-4333-8333-333333333333".to_owned(),
        method: "POST".to_owned(),
        next_submission_session_sha256: Some(sha256_hex(signed_session.as_bytes())),
        path: "/v1/internal/privacy-requests/exchange".to_owned(),
        query_sha256: sha256_hex(b""),
        typ: "service".to_owned(),
        v: 1,
    };
    let key = AssertionKey::new(std::array::from_fn(|index| index as u8));
    let token = sign_service(&claims, &key)?;
    let keys = KeyRing {
        current: key,
        previous: None,
    };
    let guard = MemoryReplayGuard::default();
    let verification = || ServiceVerification {
        expectation: ServiceExpectation {
            issuer: "response-portal",
            audience: "submission-api",
            now: 1_783_814_405,
        },
        replay_guard: &guard,
    };
    let request = |next_submission_session| BoundRequest {
        method: "POST",
        path: "/v1/internal/privacy-requests/exchange",
        raw_query: "",
        body,
        content_type: Some("application/json"),
        idempotency_key: None,
        next_submission_session,
    };

    assert!(matches!(
        verify_service(&token, &keys, &request(Some(other_session)), verification()),
        Err(AssertionError::RequestMismatch)
    ));
    assert!(matches!(
        verify_service(&token, &keys, &request(None), verification()),
        Err(AssertionError::RequestMismatch)
    ));
    Ok(())
}

#[test]
fn unsigned_next_submission_session_header_is_rejected() -> Result<(), AssertionError> {
    let body = br#"{"receiptToken":"opaque"}"#;
    let claims = ServiceClaims {
        aud: "submission-api".to_owned(),
        body_sha256: sha256_hex(body),
        content_type: "application/json".to_owned(),
        exp: 1_783_814_430,
        iat: 1_783_814_400,
        iss: "response-portal".to_owned(),
        jti: "44444444-4444-4444-8444-444444444444".to_owned(),
        method: "POST".to_owned(),
        next_submission_session_sha256: None,
        path: "/v1/internal/privacy-requests/exchange".to_owned(),
        query_sha256: sha256_hex(b""),
        typ: "service".to_owned(),
        v: 1,
    };
    let key = AssertionKey::new(std::array::from_fn(|index| index as u8));
    let token = sign_service(&claims, &key)?;
    let keys = KeyRing {
        current: key,
        previous: None,
    };
    let guard = MemoryReplayGuard::default();
    let request = BoundRequest {
        method: "POST",
        path: "/v1/internal/privacy-requests/exchange",
        raw_query: "",
        body,
        content_type: Some("application/json"),
        idempotency_key: None,
        next_submission_session: Some("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
    };

    assert!(matches!(
        verify_service(
            &token,
            &keys,
            &request,
            ServiceVerification {
                expectation: ServiceExpectation {
                    issuer: "response-portal",
                    audience: "submission-api",
                    now: 1_783_814_405,
                },
                replay_guard: &guard,
            }
        ),
        Err(AssertionError::RequestMismatch)
    ));
    Ok(())
}

#[test]
fn field_encryption_matches_authority_vector_and_binds_aad() -> Result<(), EnvelopeError> {
    let key = EnvelopeKey::new(std::array::from_fn(|index| index as u8));
    let aad = [
        "editorial.responses",
        "full_text_encrypted",
        "33333333-3333-4333-8333-333333333333",
        "response-body",
        "1",
    ];
    let token = encrypt_with_nonce(
        "gurine-fe-v1",
        &key,
        &aad,
        b"confidential response text",
        std::array::from_fn(|index| index as u8),
    )?;
    assert_eq!(
        token,
        "gurine-fe-v1.630dcd2966c43366.AAECAwQFBgcICQoL.6pRmZkBzwC7D6l6fuG9rELkf3JQ0VNncnuNIaBEiHk_bQafFEAFjxCoV"
    );
    let keys = EnvelopeKeyRing {
        current: key,
        previous: None,
    };
    assert_eq!(
        decrypt("gurine-fe-v1", &keys, &aad, &token)?,
        b"confidential response text"
    );
    let wrong_aad = [
        "editorial.responses",
        "full_text_encrypted",
        "44444444-4444-4444-8444-444444444444",
        "response-body",
        "1",
    ];
    assert_eq!(
        decrypt("gurine-fe-v1", &keys, &wrong_aad, &token),
        Err(EnvelopeError::AuthenticatedDecryptionFailed)
    );
    Ok(())
}

#[test]
fn internal_session_cookie_matches_authority_vector() -> Result<(), Box<dyn std::error::Error>> {
    let key = EnvelopeKey::new(std::array::from_fn(|index| index as u8));
    let payload = InternalSessionCookiePayload {
        absolute_expires_at: 1_783_872_000,
        csrf_rotated_at: 1_783_828_800,
        csrf_token: "test-only-csrf-token-43-characters-00000000000".to_owned(),
        issued_at: 1_783_828_800,
        opaque_identity_session_token: "test-only-opaque-session-token-43-characters-0000000"
            .to_owned(),
        typ: "internal-session".to_owned(),
        v: 1,
    };
    let context = CookieContext {
        origin: "https://review.gurine.invalid",
        path: "/",
        same_site: "Lax",
    };
    let token = seal_with_nonce(
        &key,
        context,
        &payload,
        std::array::from_fn(|index| index as u8),
    )?;
    let vector: Value = serde_json::from_str(include_str!(
        "../../../specs/cryptography/test-vectors/session-cookie.json"
    ))?;
    assert_eq!(
        token,
        vector
            .get("token")
            .and_then(Value::as_str)
            .ok_or("missing token")?
    );
    Ok(())
}
