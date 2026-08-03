use super::*;

fn actor_fields() -> Value {
    json!({
        "_actorAssertionJti":"10000000-0000-4000-8000-000000000010",
        "_actorAssertionRequestSha256":"9".repeat(64),
        "_actorAssuranceLevel":"STEP_UP",
        "_actorEffectiveCapability":"responses.review",
        "_actorActionDigest":"a".repeat(64),
        "_actorStepUpAuthorizationId":"10000000-0000-4000-8000-000000000011",
        "_actorIdempotencyKeySha256":"b".repeat(64),
        "_actorRequestKeySha256":"c".repeat(64),
        "_requestId":"10000000-0000-4000-8000-000000000012",
        "_idempotencyKeySha256":"d".repeat(64),
        "_requestSha256":"e".repeat(64)
    })
}

fn with_actor_fields(mut public: Value) -> Result<Map<String, Value>, ServiceError> {
    let actor = actor_fields();
    let public = public.as_object_mut().ok_or(ServiceError::Persistence)?;
    for (key, value) in actor.as_object().ok_or(ServiceError::Persistence)? {
        public.insert(key.clone(), value.clone());
    }
    Ok(public.clone())
}

fn attest_payload(method: &str) -> Result<Map<String, Value>, ServiceError> {
    with_actor_fields(json!({
        "organizationKind":"AGENCY",
        "organizationId":"10000000-0000-4000-8000-000000000001",
        "verificationMethod":method,
        "sourceId":"10000000-0000-4000-8000-000000000002",
        "expiresAt":"2099-08-01T00:00:00Z",
        "reason":"독립 검토자가 공식 채널 근거를 확인함",
        "expectedAuthorityVersion":1
    }))
}

#[test]
fn attest_request_is_closed_to_server_bound_authority() -> Result<(), ServiceError> {
    for method in ["OFFICIAL_DOMAIN_EMAIL", "OFFICIAL_DOCUMENT"] {
        let request = attest_owner_request(&attest_payload(method)?)?;
        assert_eq!(request.as_object().map(Map::len), Some(15));
        assert_eq!(request["verificationMethod"], method);
        assert_eq!(request["expectedAuthorityVersion"], 1);
        assert_eq!(request["expiresAt"], "2099-08-01T00:00:00Z");
        assert_eq!(request["_actorAssertionRequestSha256"], "9".repeat(64));
        assert_ne!(
            request["_actorAssertionRequestSha256"],
            request["_requestSha256"]
        );
        assert!(request.get("authorityReceiptDigest").is_none());
        assert!(request.get("registryReceiptDigest").is_none());
    }

    let mut invalid_version = attest_payload("OFFICIAL_DOCUMENT")?;
    invalid_version.insert("expectedAuthorityVersion".to_owned(), json!(2));
    assert!(matches!(
        attest_owner_request(&invalid_version),
        Err(ServiceError::InvalidRequest)
    ));

    let mut otp = attest_payload("EMAIL_OTP")?;
    otp.insert("verificationMethod".to_owned(), json!("EMAIL_OTP"));
    assert!(matches!(
        attest_owner_request(&otp),
        Err(ServiceError::InvalidRequest)
    ));
    Ok(())
}

#[test]
fn attest_request_requires_exact_step_up_and_server_digests() -> Result<(), ServiceError> {
    let mut weak = attest_payload("OFFICIAL_DOCUMENT")?;
    weak.insert("_actorAssuranceLevel".to_owned(), json!("ACTIVE_SESSION"));
    assert!(matches!(
        attest_owner_request(&weak),
        Err(ServiceError::PreconditionFailed)
    ));

    let mut missing = attest_payload("OFFICIAL_DOCUMENT")?;
    missing.remove("_actorActionDigest");
    assert!(matches!(
        attest_owner_request(&missing),
        Err(ServiceError::Persistence)
    ));
    Ok(())
}

#[test]
fn revocation_reason_is_nonempty_bounded_and_actor_bound() -> Result<(), ServiceError> {
    let valid = with_actor_fields(json!({
        "assertionId":"10000000-0000-4000-8000-000000000001",
        "reasonCode":"SOURCE_AUTHORITY_REVOKED",
        "reason":"공식 채널 권위가 철회됨"
    }))?;
    let request = revoke_owner_request(&valid)?;
    assert_eq!(request.as_object().map(Map::len), Some(11));
    assert_eq!(request["_actorAssertionRequestSha256"], "9".repeat(64));
    assert_ne!(
        request["_actorAssertionRequestSha256"],
        request["_requestSha256"]
    );

    let mut free_form = valid.clone();
    free_form.insert("reasonCode".to_owned(), json!("source authority revoked"));
    assert!(revoke_owner_request(&free_form).is_ok());

    for invalid_reason_code in [
        "".to_owned(),
        " ".to_owned(),
        " leading".to_owned(),
        "trailing ".to_owned(),
        "CONTROL\nCODE".to_owned(),
        "a".repeat(101),
    ] {
        let mut invalid = valid.clone();
        invalid.insert("reasonCode".to_owned(), json!(invalid_reason_code));
        assert!(matches!(
            revoke_owner_request(&invalid),
            Err(ServiceError::InvalidRequest)
        ));
    }

    let mut missing_assertion_request = valid;
    missing_assertion_request.remove("_actorAssertionRequestSha256");
    assert!(matches!(
        revoke_owner_request(&missing_assertion_request),
        Err(ServiceError::Persistence)
    ));
    Ok(())
}

#[test]
fn owner_results_require_exact_immutable_receipts() -> Result<(), ServiceError> {
    let attest_result = json!({
        "assertionId":"10000000-0000-4000-8000-000000000001",
        "assertionVersion":1,
        "authorityReceiptId":"10000000-0000-4000-8000-000000000002",
        "authorityReceiptDigest":"a".repeat(64),
        "registryReceiptDigest":"b".repeat(64),
        "auditEventId":"10000000-0000-4000-8000-000000000003",
        "attestedAt":"2026-08-01T00:00:00Z",
        "expiresAt":"2027-08-01T00:00:00Z",
        "outboxEventIds":["10000000-0000-4000-8000-000000000004"],
        "replayed":false
    });
    let receipt = parse_attest_result(&attest_result)?;
    assert_eq!(receipt.aggregate_version, 1);
    assert_eq!(receipt.receipt_digest, "b".repeat(64));
    assert_eq!(
        receipt.response_fields["authorityReceiptDigest"],
        "a".repeat(64)
    );

    let mut injected = attest_result;
    injected["rawDomain"] = json!("example.invalid");
    assert!(matches!(
        parse_attest_result(&injected),
        Err(ServiceError::Persistence)
    ));

    let revoke_result = json!({
        "revocationId":"10000000-0000-4000-8000-000000000005",
        "assertionId":"10000000-0000-4000-8000-000000000001",
        "revocationReceiptDigest":"c".repeat(64),
        "auditEventId":"10000000-0000-4000-8000-000000000006",
        "revokedAt":"2026-08-01T00:00:00Z",
        "outboxEventIds":["10000000-0000-4000-8000-000000000007"],
        "replayed":false
    });
    let revoke_receipt = parse_revoke_result(&revoke_result)?;
    assert_eq!(
        revoke_receipt.aggregate_id,
        Uuid::parse_str("10000000-0000-4000-8000-000000000001")
            .map_err(|_| ServiceError::Persistence)?
    );
    assert_eq!(
        revoke_receipt.response_fields["revocationId"],
        "10000000-0000-4000-8000-000000000005"
    );
    Ok(())
}
