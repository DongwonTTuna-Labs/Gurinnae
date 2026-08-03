use super::{
    BoundRequest,
    canonical::{canonical_request_digest, request_hashes, sha256_hex},
    errors::AssertionError,
};

#[test]
fn absent_next_submission_session_preserves_v1_digest_bytes() {
    let request = BoundRequest {
        method: "POST",
        path: "/internal/v1/sessions/resolve",
        raw_query: "",
        body: br#"{"sessionToken":"opaque"}"#,
        content_type: Some("application/json; charset=utf-8"),
        idempotency_key: None,
        next_submission_session: None,
    };

    assert_eq!(
        canonical_request_digest(&request),
        Ok("2f39c2e223e97c0b3dc78b27b39b596312404892646dbb6b495c09c5c6570e1c".to_owned())
    );
}

#[test]
fn present_next_submission_session_adds_one_digest_bound_line() -> Result<(), AssertionError> {
    let token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    let request = BoundRequest {
        method: "POST",
        path: "/v1/internal/privacy-requests/exchange",
        raw_query: "",
        body: br#"{"receiptToken":"opaque"}"#,
        content_type: Some("application/json"),
        idempotency_key: Some("privacy-exchange-idempotency"),
        next_submission_session: Some(token),
    };
    let hashes = request_hashes(&request)?;
    let next_hash = sha256_hex(token.as_bytes());
    assert_eq!(
        hashes.next_submission_session_sha256.as_deref(),
        Some(next_hash.as_str())
    );
    let expected = sha256_hex(
        format!(
            "{}\n{}\n{}\n{}\n{}\n{}\n{}",
            hashes.method,
            hashes.path,
            hashes.query_sha256,
            hashes.body_sha256,
            hashes.content_type,
            hashes.idempotency_key_sha256.as_deref().unwrap_or(""),
            next_hash
        )
        .as_bytes(),
    );
    assert_eq!(canonical_request_digest(&request), Ok(expected));
    Ok(())
}

#[test]
fn empty_next_submission_session_is_rejected_without_echoing_it() {
    let result = request_hashes(&BoundRequest {
        method: "POST",
        path: "/v1/internal/privacy-requests/exchange",
        raw_query: "",
        body: b"{}",
        content_type: Some("application/json"),
        idempotency_key: None,
        next_submission_session: Some(""),
    });
    assert_eq!(result, Err(AssertionError::RequestMismatch));
}
