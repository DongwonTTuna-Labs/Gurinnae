use gurine_auth::{
    assertion::canonical::canonical_json,
    envelope::{EnvelopeKey, encrypt_with_nonce},
};
use gurine_domain::privacy::{
    PrivacyObjectRef, PrivacyObjectType, PrivacyRequestScope, PrivacyScopeKind,
};

use super::*;

const SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn digest() -> Option<PrivacyDigest> {
    PrivacyDigest::try_new(SHA).ok()
}

fn timestamp() -> Option<OffsetDateTime> {
    OffsetDateTime::from_unix_timestamp(1_800_000_000).ok()
}

#[test]
fn endpoint_proof_provider_shape_is_closed() {
    let Some(digest) = digest() else {
        assert!(false, "valid digest fixture");
        return;
    };
    let missing_provider = PrivacyIdentityProofClaim::VerifiedEndpoint {
        endpoint_challenge_id: Uuid::from_u128(1),
        proof_kind: EndpointProofKind::ProviderSignedBinding,
        proof_verifier_hmac: digest.clone(),
        provider: None,
    };
    assert_eq!(
        missing_provider.validate(),
        Err(PrivacyCommandError::IdentityProofInvalid)
    );

    let valid_email = PrivacyIdentityProofClaim::VerifiedEndpoint {
        endpoint_challenge_id: Uuid::from_u128(1),
        proof_kind: EndpointProofKind::EmailLink,
        proof_verifier_hmac: digest,
        provider: None,
    };
    assert_eq!(valid_email.validate(), Ok(()));
}

#[test]
fn request_type_serialization_never_collapses_destructive_rights() {
    assert_ne!(
        PrivacyRequestType::Correction.as_str(),
        PrivacyRequestType::Deletion.as_str()
    );
    assert_ne!(
        PrivacyRequestType::Deletion.as_str(),
        PrivacyRequestType::Restriction.as_str()
    );
}

#[test]
fn create_rejects_scope_ciphertext_bound_to_another_digest() {
    let Some(digest) = digest() else {
        assert!(false, "valid digest fixture");
        return;
    };
    let Ok(encrypted_scope) =
        EncryptedPrivacyScope::try_new(vec![1], digest.clone(), digest.clone(), "field-key-v1")
    else {
        assert!(false, "valid encrypted scope fixture");
        return;
    };
    let Ok(encrypted_statement) =
        EncryptedPrivacyStatement::try_new(vec![1], digest.clone(), digest.clone(), "field-key-v1")
    else {
        assert!(false, "valid encrypted statement fixture");
        return;
    };
    let Ok(receipt_token_sha256) =
        PrivacyDigest::try_new("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    else {
        assert!(false, "valid token digest fixture");
        return;
    };
    let request = CreatePrivacyRequest {
        privacy_request_id: Uuid::from_u128(1),
        communication_subject_id: Uuid::from_u128(5),
        communication_subject_hmac_key_version: "hmac-key-v1".to_owned(),
        request_type: PrivacyRequestType::Access,
        identity_proof: PrivacyIdentityProofClaim::ResponseReceipt {
            receipt_id: Uuid::from_u128(2),
            possession_token_hmac: digest.clone(),
        },
        jurisdiction: "KR".to_owned(),
        scope: PrivacyRequestScope {
            scope_kind: PrivacyScopeKind::AllVerifiedSubjectData,
            object_refs: Vec::new(),
            date_from: None,
            date_to: None,
            include_derivatives: true,
            include_backups: false,
        },
        encrypted_scope,
        contact: EncryptedPrivacyContact {
            endpoint_id: Uuid::from_u128(3),
            channel: PrivacyContactChannel::Email,
            endpoint_hmac: digest.clone(),
            hmac_key_version: "hmac-key-v1".to_owned(),
            endpoint_ciphertext: vec![1],
            encryption_key_id: "field-key-v1".to_owned(),
            endpoint_aad_digest: digest.clone(),
            locale: "ko-KR".to_owned(),
            explicit_voice_consent_receipt_id: None,
        },
        encrypted_statement,
        receipt_token_hmac: digest.clone(),
        receipt_token_sha256,
        receipt_token_key_version: "hmac-key-v1".to_owned(),
        idempotency_key_sha256: digest.clone(),
        request_sha256: digest,
        bff_issuer: "public-web".to_owned(),
        transport_request_id: Uuid::from_u128(4),
    };
    assert!(matches!(
        request.validate(),
        Err(PrivacyCommandError::ScopeInvalid)
    ));
}

#[test]
fn owner_session_result_is_closed_and_time_bound() {
    let Some(requested_at) = timestamp() else {
        assert!(false, "valid timestamp fixture");
        return;
    };
    let Some(digest) = digest() else {
        assert!(false, "valid digest fixture");
        return;
    };
    let invalid = PrivacyRequestSession {
        request_id: Uuid::from_u128(1),
        session_id: Uuid::from_u128(4),
        expires_at: requested_at,
        cookie_name: PRIVACY_REQUEST_RECEIPT_COOKIE_NAME.to_owned(),
        token_consumed_at: requested_at,
        audit_event_id: Uuid::from_u128(2),
        emitted_event_ids: vec![Uuid::from_u128(3)],
        receipt_digest: digest,
        replayed: false,
    };
    assert!(matches!(
        invalid.validate(),
        Err(PrivacyCommandError::InvalidOwnerResult)
    ));
}

#[test]
fn replayed_session_keeps_the_database_owned_original_bounds() {
    let Some(consumed_at) = timestamp() else {
        assert!(false, "valid timestamp fixture");
        return;
    };
    let Some(digest) = digest() else {
        assert!(false, "valid digest fixture");
        return;
    };
    let session = PrivacyRequestSession {
        request_id: Uuid::from_u128(1),
        session_id: Uuid::from_u128(2),
        expires_at: consumed_at + time::Duration::minutes(30),
        cookie_name: PRIVACY_REQUEST_RECEIPT_COOKIE_NAME.to_owned(),
        token_consumed_at: consumed_at,
        audit_event_id: Uuid::from_u128(3),
        emitted_event_ids: vec![Uuid::from_u128(4)],
        receipt_digest: digest,
        replayed: true,
    };

    assert!(session.validate().is_ok());
}

#[test]
fn create_owner_accepts_a_different_proposal_id_only_on_exact_replay() {
    let Some(created_at) = timestamp() else {
        assert!(false, "valid timestamp fixture");
        return;
    };
    let Some(digest) = digest() else {
        assert!(false, "valid digest fixture");
        return;
    };
    let persisted_id = Uuid::from_u128(1);
    let Ok(summary) = gurine_domain::privacy::PrivacyRequestSummary::try_new(
        persisted_id,
        PrivacyRequestType::Access,
        PrivacyRequestState::Received,
        "KR",
        digest.clone(),
        PrivacyIdentityState::PendingVerification,
        None,
        None,
        created_at,
        created_at,
    ) else {
        assert!(false, "valid privacy request summary fixture");
        return;
    };
    let build = |replayed| CreatedPrivacyRequest {
        command: PrivacyCommandReceipt {
            transport_request_id: Uuid::from_u128(2),
            aggregate_id: persisted_id,
            aggregate_version: 1,
            audit_event_id: Uuid::from_u128(3),
            accepted_at: created_at,
            receipt_digest: digest.clone(),
            emitted_event_ids: vec![Uuid::from_u128(4)],
        },
        request: summary.clone(),
        replayed,
    };

    assert!(matches!(
        build(false).validate(Uuid::from_u128(9)),
        Err(PrivacyCommandError::InvalidOwnerResult)
    ));
    assert!(build(true).validate(Uuid::from_u128(9)).is_ok());
}

#[test]
fn public_status_requires_the_closed_pending_action() {
    let Some(created_at) = timestamp() else {
        assert!(false, "valid timestamp fixture");
        return;
    };
    let Some(digest) = digest() else {
        assert!(false, "valid digest fixture");
        return;
    };
    let Ok(request) = gurine_domain::privacy::PrivacyRequestSummary::try_new(
        Uuid::from_u128(1),
        PrivacyRequestType::Access,
        PrivacyRequestState::Received,
        "KR",
        digest,
        PrivacyIdentityState::PendingVerification,
        None,
        None,
        created_at,
        created_at,
    ) else {
        assert!(false, "valid privacy request summary fixture");
        return;
    };
    let status = PrivacyRequestPublicStatus {
        request,
        decision_reason_code: None,
        decision_receipt_id: None,
        decision_receipt_sha256: None,
        refusal_notice_receipt_id: None,
        refusal_notice_receipt_sha256: None,
        notice_receipt_ids: Vec::new(),
        notice_receipt_sha256s: Vec::new(),
        next_action_code: PrivacyNextActionCode::AwaitReview,
        as_of: created_at,
    };

    assert!(matches!(
        status.validate(),
        Err(PrivacyCommandError::InvalidOwnerResult)
    ));
}

#[test]
fn rejected_public_status_requires_matching_decision_and_notice_receipts() {
    let Some(created_at) = timestamp() else {
        assert!(false, "valid timestamp fixture");
        return;
    };
    let Some(digest) = digest() else {
        assert!(false, "valid digest fixture");
        return;
    };
    let verified_at = created_at + time::Duration::hours(1);
    let Ok(request) = gurine_domain::privacy::PrivacyRequestSummary::try_new(
        Uuid::from_u128(1),
        PrivacyRequestType::Deletion,
        PrivacyRequestState::Rejected,
        "KR",
        digest.clone(),
        PrivacyIdentityState::Verified,
        Some(verified_at),
        Some(verified_at + time::Duration::days(14)),
        created_at,
        verified_at,
    ) else {
        assert!(false, "valid privacy request summary fixture");
        return;
    };
    let status = PrivacyRequestPublicStatus {
        request,
        decision_reason_code: Some("LEGAL_BASIS_REQUIRED".to_owned()),
        decision_receipt_id: Some(Uuid::from_u128(2)),
        decision_receipt_sha256: Some(digest.clone()),
        refusal_notice_receipt_id: None,
        refusal_notice_receipt_sha256: None,
        notice_receipt_ids: vec![Uuid::from_u128(3)],
        notice_receipt_sha256s: vec![digest],
        next_action_code: PrivacyNextActionCode::ReviewRefusalNotice,
        as_of: verified_at,
    };

    assert!(matches!(
        status.validate(),
        Err(PrivacyCommandError::InvalidOwnerResult)
    ));
}

#[test]
fn privacy_query_carries_only_the_session_digest_to_the_owner() {
    let Some(digest) = digest() else {
        assert!(false, "valid digest fixture");
        return;
    };
    let query = GetPrivacyRequest {
        session_token_sha256: digest,
        bff_issuer: "public-web".to_owned(),
    };
    assert!(query.validate().is_ok());
}

#[test]
fn maximum_object_scope_fits_the_measured_encrypted_cap() {
    let scope = PrivacyRequestScope {
        scope_kind: PrivacyScopeKind::ObjectSet,
        object_refs: (1_u128..=1_000)
            .map(|id| PrivacyObjectRef {
                object_type: PrivacyObjectType::CommunicationEndpoint,
                object_id: Uuid::from_u128(id),
            })
            .collect(),
        date_from: None,
        date_to: None,
        include_derivatives: true,
        include_backups: false,
    };
    let Ok(scope_value) = serde_json::to_value(&scope) else {
        assert!(false, "maximum scope must serialize");
        return;
    };
    let Ok(canonical) = canonical_json(&scope_value) else {
        assert!(false, "maximum scope must canonicalize");
        return;
    };
    // 1,000 89-byte objects + 999 separators + two array delimiters = 90,001;
    // the sorted outer object contributes 119 bytes and JCS appends no newline.
    assert_eq!(canonical.len(), 90_120);

    let record_id = Uuid::from_u128(1).to_string();
    let key = EnvelopeKey::new([7_u8; 32]);
    let Ok(envelope) = encrypt_with_nonce(
        "gurine-fe-v1",
        &key,
        &[
            "ops.privacy_requests_v2",
            "scope_ciphertext",
            &record_id,
            "privacy-request-scope",
            "1",
        ],
        &canonical,
        [3_u8; 12],
    ) else {
        assert!(false, "maximum scope envelope must encrypt");
        return;
    };
    // 90,120 plaintext + 16-byte tag -> 120,182 base64url bytes, plus the
    // fixed 47-byte prefix/key-id/nonce/separator envelope = 120,229.
    assert_eq!(envelope.len(), 120_229);
    assert!(envelope.len() <= MAX_ENCRYPTED_PRIVACY_SCOPE_BYTES);

    let Some(digest) = digest() else {
        assert!(false, "valid digest fixture");
        return;
    };
    assert!(
        EncryptedPrivacyScope::try_new(
            envelope.into_bytes(),
            digest.clone(),
            digest.clone(),
            "field-key-v1",
        )
        .is_ok()
    );
    assert!(
        EncryptedPrivacyScope::try_new(
            vec![0_u8; MAX_ENCRYPTED_PRIVACY_SCOPE_BYTES + 1],
            digest.clone(),
            digest,
            "field-key-v1",
        )
        .is_err()
    );
}
