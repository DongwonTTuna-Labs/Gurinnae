use actix_web::HttpRequest;
use gurine_application::idempotency::IdempotencyRequest;
use gurine_auth::assertion::{AssertionError, BoundRequest};
use uuid::Uuid;

pub(super) fn bound_request<'a>(
    request: &'a HttpRequest,
    body: &'a [u8],
) -> Result<BoundRequest<'a>, AssertionError> {
    Ok(BoundRequest {
        method: request.method().as_str(),
        path: request.path(),
        raw_query: request.query_string(),
        body,
        content_type: header(request, "content-type"),
        idempotency_key: header(request, "idempotency-key"),
        next_submission_session: next_submission_session_header(request)?,
    })
}

fn next_submission_session_header(request: &HttpRequest) -> Result<Option<&str>, AssertionError> {
    let mut values = request
        .headers()
        .get_all("x-gurine-next-submission-session");
    let Some(value) = values.next() else {
        return Ok(None);
    };
    if values.next().is_some() {
        return Err(AssertionError::RequestMismatch);
    }
    let value = value
        .to_str()
        .map_err(|_| AssertionError::RequestMismatch)?;
    if value.len() != 43
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(AssertionError::RequestMismatch);
    }
    Ok(Some(value))
}

pub(super) fn request_id(request: &HttpRequest) -> String {
    header(request, "x-request-id")
        .and_then(|value| Uuid::parse_str(value).ok())
        .unwrap_or_else(Uuid::new_v4)
        .to_string()
}

pub(super) fn privacy_exchange_authority_is_closed(operation: &str, request: &HttpRequest) -> bool {
    operation != "exchangePrivacyRequestReceiptToken"
        || request
            .headers()
            .get("x-gurine-next-submission-session")
            .is_some()
            && request
                .headers()
                .get("x-gurine-submission-session")
                .is_none()
            && request.headers().get("x-gurine-actor-assertion").is_none()
            && request.headers().get("cookie").is_none()
}

pub(super) fn header<'a>(request: &'a HttpRequest, name: &str) -> Option<&'a str> {
    request
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
}

pub(super) fn privacy_owner_idempotency(
    operation: &str,
    request: &HttpRequest,
    body: &[u8],
) -> Result<IdempotencyRequest, PrivacyIdempotencyError> {
    if !matches!(
        operation,
        "createPrivacyRequest" | "exchangePrivacyRequestReceiptToken"
    ) {
        return Err(PrivacyIdempotencyError::InvalidOperation);
    }
    let key = header(request, "idempotency-key").ok_or(PrivacyIdempotencyError::MissingKey)?;
    if !(16..=200).contains(&key.len()) || !key.is_ascii() {
        return Err(PrivacyIdempotencyError::InvalidKey);
    }
    let bound = bound_request(request, body).map_err(|_| PrivacyIdempotencyError::Binding)?;
    let request_hash = gurine_auth::assertion::canonical::canonical_request_digest(&bound)
        .map_err(|_| PrivacyIdempotencyError::Binding)?;
    Ok(IdempotencyRequest {
        scope: operation.to_owned(),
        key_hash: gurine_auth::assertion::canonical::sha256_hex(key.as_bytes()),
        request_hash,
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum PrivacyIdempotencyError {
    InvalidOperation,
    MissingKey,
    InvalidKey,
    Binding,
}

#[cfg(test)]
mod tests {
    use actix_web::test::TestRequest;
    use gurine_auth::assertion::canonical::{canonical_request_digest, sha256_hex};

    use super::{
        AssertionError, PrivacyIdempotencyError, bound_request,
        privacy_exchange_authority_is_closed, privacy_owner_idempotency,
    };

    const NEXT_SESSION: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    #[test]
    fn next_submission_session_header_is_bound_only_as_sha256() {
        let request = TestRequest::post()
            .uri("/v1/internal/privacy-requests/exchange")
            .insert_header(("content-type", "application/json"))
            .insert_header(("x-gurine-next-submission-session", NEXT_SESSION))
            .to_http_request();
        let bound = bound_request(&request, b"{}").expect("valid unique bound header");
        let digest = canonical_request_digest(&bound).expect("canonical digest");

        assert_eq!(
            gurine_auth::assertion::canonical::request_hashes(&bound)
                .expect("request hashes")
                .next_submission_session_sha256
                .as_deref(),
            Some(sha256_hex(NEXT_SESSION.as_bytes()).as_str())
        );
        assert!(!digest.contains(NEXT_SESSION));
    }

    #[test]
    fn empty_or_duplicate_next_submission_session_header_is_rejected() {
        let empty = TestRequest::post()
            .uri("/v1/internal/privacy-requests/exchange")
            .insert_header(("x-gurine-next-submission-session", ""))
            .to_http_request();
        assert!(matches!(
            bound_request(&empty, b""),
            Err(AssertionError::RequestMismatch)
        ));

        let duplicate = TestRequest::post()
            .uri("/v1/internal/privacy-requests/exchange")
            .append_header(("x-gurine-next-submission-session", NEXT_SESSION))
            .append_header((
                "x-gurine-next-submission-session",
                "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            ))
            .to_http_request();
        assert!(matches!(
            bound_request(&duplicate, b""),
            Err(AssertionError::RequestMismatch)
        ));
    }

    #[test]
    fn privacy_owner_uses_the_canonical_request_digest_without_rehashing() {
        let key = "privacy-key-0001";
        let body = br#"{"requestType":"ACCESS"}"#;
        let request = TestRequest::post()
            .uri("/v1/privacy-requests")
            .insert_header(("content-type", "application/json"))
            .insert_header(("idempotency-key", key))
            .to_http_request();
        let bound = bound_request(&request, body).expect("valid bound request");
        let expected = canonical_request_digest(&bound).expect("canonical digest");
        let derived = privacy_owner_idempotency("createPrivacyRequest", &request, body)
            .expect("privacy idempotency");

        assert_eq!(derived.key_hash, sha256_hex(key.as_bytes()));
        assert_eq!(derived.request_hash, expected);
        assert_ne!(derived.request_hash, sha256_hex(expected.as_bytes()));
    }

    #[test]
    fn privacy_owner_rejects_short_keys_and_binds_the_next_session_header() {
        let short = TestRequest::post()
            .uri("/v1/privacy-requests")
            .insert_header(("content-type", "application/json"))
            .insert_header(("idempotency-key", "short-key"))
            .to_http_request();
        assert_eq!(
            privacy_owner_idempotency("createPrivacyRequest", &short, b"{}"),
            Err(PrivacyIdempotencyError::InvalidKey)
        );

        let exchange = |next_session: &'static str| {
            TestRequest::post()
                .uri("/v1/submission-session/privacy-request-receipt:exchange")
                .insert_header(("content-type", "application/json"))
                .insert_header(("idempotency-key", "privacy-exchange-0001"))
                .insert_header(("x-gurine-next-submission-session", next_session))
                .to_http_request()
        };
        let first = privacy_owner_idempotency(
            "exchangePrivacyRequestReceiptToken",
            &exchange(NEXT_SESSION),
            br#"{"token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
        )
        .expect("first exchange digest");
        let second = privacy_owner_idempotency(
            "exchangePrivacyRequestReceiptToken",
            &exchange("BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"),
            br#"{"token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#,
        )
        .expect("second exchange digest");
        assert_ne!(first.request_hash, second.request_hash);
    }

    #[test]
    fn privacy_exchange_rejects_prior_session_cookie_and_actor_authority() {
        let valid = || {
            TestRequest::post()
                .uri("/v1/submission-session/privacy-request-receipt:exchange")
                .insert_header(("x-gurine-next-submission-session", NEXT_SESSION))
        };
        assert!(privacy_exchange_authority_is_closed(
            "exchangePrivacyRequestReceiptToken",
            &valid().to_http_request(),
        ));
        for (name, value) in [
            ("x-gurine-submission-session", "prior-session"),
            ("x-gurine-actor-assertion", "actor-assertion"),
            ("cookie", "session=browser-side-door"),
        ] {
            assert!(!privacy_exchange_authority_is_closed(
                "exchangePrivacyRequestReceiptToken",
                &valid().insert_header((name, value)).to_http_request(),
            ));
        }
        assert!(!privacy_exchange_authority_is_closed(
            "exchangePrivacyRequestReceiptToken",
            &TestRequest::post().to_http_request(),
        ));
    }
}
