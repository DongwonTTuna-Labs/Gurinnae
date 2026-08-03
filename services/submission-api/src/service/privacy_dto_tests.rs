use super::{
    CreatePrivacyRequestBody, ExchangePrivacyReceiptBody, PrivacyReceiptMaterial, ServiceError,
    derived_privacy_receipt_token,
};

#[test]
fn privacy_receipt_derivation_is_stable_and_request_bound() -> Result<(), ServiceError> {
    let key_hash = "a".repeat(64);
    let request_hash = "b".repeat(64);
    let derive = |request_hash: &str| {
        derived_privacy_receipt_token(b"test-key", "createPrivacyRequest", &key_hash, request_hash)
    };
    let first = derive(&request_hash)?;
    assert_eq!(first.len(), 43);
    assert_eq!(first, "wncVOtAvDZVwUEvF7gA0V14TPRusFRcaaZJ333bSaKU");
    assert_eq!(first, derive(&request_hash)?);
    assert_ne!(first, derive(&"c".repeat(64))?);
    assert!(
        derived_privacy_receipt_token(
            b"test-key",
            "createPrivacyRequest",
            &"A".repeat(64),
            &request_hash,
        )
        .is_err()
    );
    Ok(())
}

#[test]
fn privacy_receipt_material_closes_both_persistent_token_digests() -> Result<(), ServiceError> {
    let material = PrivacyReceiptMaterial::derive(b"test-key", &"a".repeat(64), &"b".repeat(64))?;
    assert_eq!(
        material.token(),
        "wncVOtAvDZVwUEvF7gA0V14TPRusFRcaaZJ333bSaKU"
    );
    assert_eq!(material.token_hmac().as_str().len(), 64);
    assert_eq!(material.token_sha256().as_str().len(), 64);
    assert!(!material.key_version().is_empty());
    assert_ne!(material.token_hmac(), material.token_sha256());
    Ok(())
}

#[test]
fn privacy_create_rejects_unknown_nested_identity_fields() {
    let body = r#"{
      "requestType":"ACCESS",
      "subjectIdentityProof":{"kind":"RESPONSE_RECEIPT","receiptId":"00000000-0000-4000-8000-000000000001","possessionToken":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","extra":true},
      "jurisdiction":"KR",
      "scope":{"scopeKind":"ALL_VERIFIED_SUBJECT_DATA","objectRefs":[],"dateFrom":null,"dateTo":null,"includeDerivatives":true,"includeBackups":false},
      "contactEndpoint":{"channel":"EMAIL","address":"owner@example.test","locale":"ko-KR"},
      "statement":"열람 요청",
      "attestation":true,
      "privacyConsent":true,
      "abuseProof":{"provider":"SYNTHETIC_TEST","token":"a","action":"createPrivacyRequest","issuedAtEpochSeconds":1}
    }"#;
    assert!(CreatePrivacyRequestBody::parse(body.as_bytes()).is_err());
}

#[test]
fn privacy_create_rejects_unowned_document_challenge_proof() {
    let body = r#"{
      "requestType":"ACCESS",
      "subjectIdentityProof":{"kind":"IDENTITY_DOCUMENT_CHALLENGE","challengeId":"00000000-0000-4000-8000-000000000001","verificationReceiptId":"00000000-0000-4000-8000-000000000002","verificationReceiptDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      "jurisdiction":"KR",
      "scope":{"scopeKind":"ALL_VERIFIED_SUBJECT_DATA","objectRefs":[],"dateFrom":null,"dateTo":null,"includeDerivatives":true,"includeBackups":false},
      "contactEndpoint":{"channel":"EMAIL","address":"owner@example.test","locale":"ko-KR"},
      "statement":"열람 요청",
      "attestation":true,
      "privacyConsent":true,
      "abuseProof":{"provider":"SYNTHETIC_TEST","token":"a","action":"createPrivacyRequest","issuedAtEpochSeconds":1}
    }"#;
    assert!(CreatePrivacyRequestBody::parse(body.as_bytes()).is_err());
}

#[test]
fn exchange_accepts_only_the_one_time_token_body() {
    assert!(
        ExchangePrivacyReceiptBody::parse(br#"{"token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#)
            .is_ok()
    );
    assert!(
        ExchangePrivacyReceiptBody::parse(
            br#"{"token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","proof":{}}"#
        )
        .is_err()
    );
}

#[test]
fn voice_enrollment_fails_closed_without_pre_enrollment_consent_authority() {
    let body = r#"{
      "requestType":"ACCESS",
      "subjectIdentityProof":{"kind":"RESPONSE_RECEIPT","receiptId":"00000000-0000-4000-8000-000000000001","possessionToken":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      "jurisdiction":"KR",
      "scope":{"scopeKind":"ALL_VERIFIED_SUBJECT_DATA","objectRefs":[],"dateFrom":null,"dateTo":null,"includeDerivatives":true,"includeBackups":false},
      "contactEndpoint":{"channel":"VOICE","e164":"+821012345678","locale":"ko-KR","explicitVoiceConsentReceiptId":"00000000-0000-4000-8000-000000000002"},
      "statement":"열람 요청",
      "attestation":true,
      "privacyConsent":true,
      "abuseProof":{"provider":"SYNTHETIC_TEST","token":"a","action":"createPrivacyRequest","issuedAtEpochSeconds":1}
    }"#;
    assert!(matches!(
        CreatePrivacyRequestBody::parse(body.as_bytes()),
        Err(ServiceError::PrivacyVoiceConsentAuthorityMissing)
    ));
}

#[test]
fn explicit_cleanup_erases_all_create_request_secrets() -> Result<(), ServiceError> {
    let body = r#"{
      "requestType":"ACCESS",
      "subjectIdentityProof":{"kind":"RESPONSE_RECEIPT","receiptId":"00000000-0000-4000-8000-000000000001","possessionToken":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      "jurisdiction":"KR",
      "scope":{"scopeKind":"ALL_VERIFIED_SUBJECT_DATA","objectRefs":[],"dateFrom":null,"dateTo":null,"includeDerivatives":true,"includeBackups":false},
      "contactEndpoint":{"channel":"EMAIL","address":"owner@example.test","locale":"ko-KR"},
      "statement":"열람 요청",
      "attestation":true,
      "privacyConsent":true,
      "abuseProof":{"provider":"SYNTHETIC_TEST","token":"proof-secret","action":"createPrivacyRequest","issuedAtEpochSeconds":1}
    }"#;
    let mut parsed = CreatePrivacyRequestBody::parse(body.as_bytes())?;
    parsed.zeroize_sensitive();
    assert!(parsed.statement.is_empty());
    assert!(parsed.abuse_proof.token.is_empty());
    assert!(matches!(
        parsed.subject_identity_proof,
        super::IdentityProof::ResponseReceipt {
            ref possession_token,
            ..
        } if possession_token.is_empty()
    ));
    assert!(matches!(
        parsed.contact_endpoint,
        super::EndpointEnrollment::Email { ref address, .. } if address.is_empty()
    ));
    Ok(())
}
