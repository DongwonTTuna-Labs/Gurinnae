use super::*;

fn valid_payload() -> Result<Map<String, Value>, ServiceError> {
    json!({
        "responseId":"10000000-0000-4000-8000-000000000001",
        "organizationId":"10000000-0000-4000-8000-000000000002",
        "publicationForm":"REDACTED",
        "verificationMethod":"OFFICIAL_DOCUMENT",
        "officialChannelSourceId":"10000000-0000-4000-8000-000000000003",
        "reason":"공식 공문 확인",
        "expectedVersion":3,
        "_actorAssertionJti":"10000000-0000-4000-8000-000000000004",
        "_actorAssuranceLevel":"STEP_UP",
        "_actorEffectiveCapability":"responses.review",
        "_actorActionDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "_actorStepUpAuthorizationId":"10000000-0000-4000-8000-000000000005",
        "_actorIdempotencyKeySha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "_actorRequestKeySha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    })
    .as_object()
    .cloned()
    .ok_or(ServiceError::Persistence)
}

fn valid_excerpt_payload() -> Result<Map<String, Value>, ServiceError> {
    json!({
        "responseId":"10000000-0000-4000-8000-000000000011",
        "excerptHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "publicationForm":"REDACTED",
        "reason":"공개 발췌 승인",
        "expectedVersion":4,
        "_actorAssertionJti":"10000000-0000-4000-8000-000000000012",
        "_actorAssuranceLevel":"ACTIVE_SESSION",
        "_actorEffectiveCapability":"responses.review",
        "_actorRequestKeySha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "_requestId":"10000000-0000-4000-8000-000000000013",
        "_idempotencyKeySha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "_requestSha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    })
    .as_object()
    .cloned()
    .ok_or(ServiceError::Persistence)
}

#[test]
fn response_identity_request_is_closed_to_approved_methods_and_forms() -> Result<(), ServiceError> {
    let request = response_organization_identity_request(&valid_payload()?)?;
    assert_eq!(request["verificationMethod"], "OFFICIAL_DOCUMENT");
    assert_eq!(request["publicationForm"], "REDACTED");
    assert_eq!(
        request["officialChannelSourceId"], "10000000-0000-4000-8000-000000000003",
        "the public UUID is the immutable official-channel registry assertion id"
    );
    assert_eq!(
        request.as_object().map(Map::len),
        Some(14),
        "owner request must remain a closed 7 public + 7 server-derived shape"
    );

    let mut otp = valid_payload()?;
    otp.insert("verificationMethod".to_owned(), json!("EMAIL_OTP"));
    assert!(matches!(
        response_organization_identity_request(&otp),
        Err(ServiceError::InvalidRequest)
    ));

    let mut weak_assurance = valid_payload()?;
    weak_assurance.insert("_actorAssuranceLevel".to_owned(), json!("ACTIVE_SESSION"));
    assert!(matches!(
        response_organization_identity_request(&weak_assurance),
        Err(ServiceError::PreconditionFailed)
    ));

    let mut missing_server_binding = valid_payload()?;
    missing_server_binding.remove("_actorRequestKeySha256");
    assert!(matches!(
        response_organization_identity_request(&missing_server_binding),
        Err(ServiceError::Persistence)
    ));

    let mut raw_endpoint_only = valid_payload()?;
    raw_endpoint_only.remove("officialChannelSourceId");
    raw_endpoint_only.insert(
        "communicationVerificationId".to_owned(),
        json!("10000000-0000-4000-8000-000000000006"),
    );
    assert!(matches!(
        response_organization_identity_request(&raw_endpoint_only),
        Err(ServiceError::InvalidRequest)
    ));

    let mut nil_registry_assertion = valid_payload()?;
    nil_registry_assertion.insert(
        "officialChannelSourceId".to_owned(),
        json!("00000000-0000-0000-0000-000000000000"),
    );
    assert!(matches!(
        response_organization_identity_request(&nil_registry_assertion),
        Err(ServiceError::InvalidRequest)
    ));
    Ok(())
}

#[test]
fn response_identity_owner_result_requires_immutable_receipt_fields() -> Result<(), uuid::Error> {
    let response_id = Uuid::parse_str("10000000-0000-4000-8000-000000000010")?;
    let valid = json!({
        "assertionId":"10000000-0000-4000-8000-000000000001",
        "assertionVersion":1,
        "responseVersion":4,
        "receiptDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "auditEventId":"10000000-0000-4000-8000-000000000002",
        "verifiedAt":"2026-08-01T00:00:00Z",
        "outboxEventIds":["10000000-0000-4000-8000-000000000003"],
        "replayed":false
    });
    assert!(
        validate_response_identity_owner_result(
            "verifyResponseOrganizationIdentity",
            &valid,
            response_id,
        )
        .is_ok()
    );

    let mut missing_receipt = valid;
    missing_receipt["receiptDigest"] = Value::Null;
    assert!(matches!(
        validate_response_identity_owner_result(
            "verifyResponseOrganizationIdentity",
            &missing_receipt,
            response_id,
        ),
        Err(ServiceError::Persistence)
    ));
    Ok(())
}

#[test]
fn response_excerpt_request_is_closed_and_requires_server_authority() -> Result<(), ServiceError> {
    let actor = Uuid::parse_str("10000000-0000-4000-8000-000000000014")
        .map_err(|_| ServiceError::Persistence)?;
    let request = response_excerpt_approval_request(&valid_excerpt_payload()?, actor)?;
    assert_eq!(request.as_object().map(Map::len), Some(13));
    assert_eq!(request["_actorId"], actor.to_string());
    assert_eq!(request["publicationForm"], "REDACTED");

    let mut invalid_assurance = valid_excerpt_payload()?;
    invalid_assurance.insert("_actorAssuranceLevel".to_owned(), json!("UNVERIFIED"));
    assert!(matches!(
        response_excerpt_approval_request(&invalid_assurance, actor),
        Err(ServiceError::PreconditionFailed)
    ));

    let mut missing_binding = valid_excerpt_payload()?;
    missing_binding.remove("_requestSha256");
    assert!(matches!(
        response_excerpt_approval_request(&missing_binding, actor),
        Err(ServiceError::Persistence)
    ));
    Ok(())
}
