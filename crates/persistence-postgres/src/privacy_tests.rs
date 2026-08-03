use serde_json::{Value, json};

use super::{
    PrivacySqlStateError, parse_created, parse_session, parse_status, repository_error_for_sqlstate,
};

const SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn request() -> Value {
    json!({
        "privacyRequestId":"00000000-0000-4000-8000-000000000001",
        "requestType":"ACCESS",
        "state":"RECEIVED",
        "jurisdiction":"KR",
        "scopeDigest":SHA,
        "identityState":"PENDING_VERIFICATION",
        "identityVerifiedAt":null,
        "dueAt":null,
        "createdAt":"2026-08-01T12:00:00Z",
        "updatedAt":"2026-08-01T12:00:00Z"
    })
}

fn session_owner_result(replayed: bool) -> Value {
    json!({
        "sessionId":"00000000-0000-4000-8000-000000000002",
        "privacyRequestId":"00000000-0000-4000-8000-000000000001",
        "sessionKind":"PRIVACY_REQUEST_RECEIPT",
        "scopeType":"PRIVACY_REQUEST",
        "scopeId":"00000000-0000-4000-8000-000000000001",
        "bffIssuer":"public-web",
        "issuedAt":"2026-08-01T12:00:00Z",
        "expiresAt":"2026-08-01T12:30:00Z",
        "auditEventId":"00000000-0000-4000-8000-000000000003",
        "emittedEventIds":["00000000-0000-4000-8000-000000000004"],
        "receiptDigest":SHA,
        "replayed":replayed
    })
}

#[test]
fn create_parser_accepts_only_the_closed_pending_owner_result() {
    let value = json!({
        "command":{
            "transportRequestId":"00000000-0000-4000-8000-000000000002",
            "aggregateId":"00000000-0000-4000-8000-000000000001",
            "aggregateVersion":1,
            "auditEventId":"00000000-0000-4000-8000-000000000003",
            "acceptedAt":"2026-08-01T12:00:00Z",
            "receiptDigest":SHA,
            "emittedEventIds":["00000000-0000-4000-8000-000000000004"]
        },
        "request":request(),
        "replayed":false
    });
    assert!(parse_created(&value).is_ok());
    let mut widened = value;
    widened["command"]["rawToken"] = json!("forbidden");
    assert!(parse_created(&widened).is_err());
}

#[test]
fn session_parser_keeps_replay_metadata_internal() {
    let new_result = session_owner_result(false);
    let replay_result = session_owner_result(true);
    assert!(parse_session(&new_result).is_ok());
    assert!(parse_session(&replay_result).is_ok());

    let mut widened = replay_result;
    widened["token"] = json!("forbidden");
    assert!(parse_session(&widened).is_err());

    let value = session_owner_result(true);
    let mut wrong_scope = value.clone();
    wrong_scope["scopeId"] = json!("00000000-0000-4000-8000-000000000009");
    assert!(parse_session(&wrong_scope).is_err());
    let mut wrong_issuer = value;
    wrong_issuer["bffIssuer"] = json!("response-portal");
    assert!(parse_session(&wrong_issuer).is_err());
}

#[test]
fn already_consumed_receipt_token_keeps_the_typed_replay_error() {
    assert_eq!(
        repository_error_for_sqlstate("PVT03"),
        Some(PrivacySqlStateError::TokenReplayed)
    );
}

#[test]
fn status_parser_rejects_free_text_and_nonclosed_actions() {
    let value = json!({
        "request":request(),
        "decisionReasonCode":null,
        "decisionReceiptId":null,
        "decisionReceiptSha256":null,
        "refusalNoticeReceiptId":null,
        "refusalNoticeReceiptSha256":null,
        "noticeReceiptIds":[],
        "noticeReceiptSha256s":[],
        "nextActionCodes":["VERIFY_IDENTITY"],
        "asOf":"2026-08-01T12:00:00Z",
        "links":[],
        "operationId":"getPrivacyRequest"
    });
    assert!(parse_status(&value).is_ok());
    let mut widened = value;
    widened["decisionReason"] = json!("raw free text");
    assert!(parse_status(&widened).is_err());

    let mut wrong_operation = json!({
        "request":request(),
        "decisionReasonCode":null,
        "decisionReceiptId":null,
        "decisionReceiptSha256":null,
        "refusalNoticeReceiptId":null,
        "refusalNoticeReceiptSha256":null,
        "noticeReceiptIds":[],
        "noticeReceiptSha256s":[],
        "nextActionCodes":["VERIFY_IDENTITY"],
        "asOf":"2026-08-01T12:00:00Z",
        "links":[],
        "operationId":"getAnotherRequest"
    });
    assert!(parse_status(&wrong_operation).is_err());
    wrong_operation["operationId"] = json!("getPrivacyRequest");
    assert!(parse_status(&wrong_operation).is_ok());
}

#[test]
fn privacy_sqlstates_are_closed_and_unknown_states_fail_closed() {
    let recognized = [
        ("PVT01", PrivacySqlStateError::TokenInvalid),
        ("PVT02", PrivacySqlStateError::TokenExpired),
        ("PVT03", PrivacySqlStateError::TokenReplayed),
        ("PVT04", PrivacySqlStateError::ScopedSessionRequired),
        ("PVT05", PrivacySqlStateError::IdempotencyConflict),
        ("PVT06", PrivacySqlStateError::IdentityProofInvalid),
        ("PVT07", PrivacySqlStateError::ScopeInvalid),
        ("P0002", PrivacySqlStateError::NotFound),
    ];
    for (code, expected) in recognized {
        assert_eq!(repository_error_for_sqlstate(code), Some(expected));
    }
    for code in ["40001", "23505", "55000", "PVT08", "XXXXX", ""] {
        assert_eq!(repository_error_for_sqlstate(code), None);
    }
}
