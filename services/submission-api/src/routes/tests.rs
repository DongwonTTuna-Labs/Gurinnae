use super::{owner_atomic_idempotency, owner_authorizes_session};

#[test]
fn only_privacy_owner_commands_bypass_transport_idempotency_writes() {
    assert!(owner_atomic_idempotency("createPrivacyRequest"));
    assert!(owner_atomic_idempotency(
        "exchangePrivacyRequestReceiptToken"
    ));
    assert!(owner_atomic_idempotency("submitResponse"));
    assert!(!owner_atomic_idempotency("createCorrectionRequest"));
    assert!(!owner_atomic_idempotency("getPrivacyRequest"));
}

#[test]
fn privacy_query_defers_scoped_session_authority_to_its_database_owner() {
    assert!(owner_authorizes_session("getPrivacyRequest"));
    assert!(!owner_authorizes_session("getResponseReceipt"));
}
