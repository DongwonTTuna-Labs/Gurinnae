use super::*;

fn owner_response() -> Value {
    json!({
        "operationId":"publishCase",
        "requestId":"10000000-0000-4000-8000-000000000001",
        "status":"completed",
        "aggregateId":"10000000-0000-4000-8000-000000000002",
        "aggregateVersion":3,
        "auditEventId":"10000000-0000-4000-8000-000000000003",
        "receiptToken":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "acceptedAt":"2026-08-01T00:00:00Z",
        "links":[]
    })
}

fn request_digest(body: &[u8]) -> Result<String, ServiceError> {
    canonical_request_digest(&BoundRequest {
        method: "POST",
        path: "/v1/internal/commands/place-legal-hold",
        raw_query: "",
        body,
        content_type: Some("application/json"),
        idempotency_key: Some("legal-hold-idempotency-key"),
        next_submission_session: None,
    })
    .map_err(|_| ServiceError::InvalidRequest)
}

fn actor_claims_for_raw_body(body: &[u8]) -> ActorClaims {
    ActorClaims {
        action_digest: Some("a".repeat(64)),
        assurance_level: "STEP_UP".to_owned(),
        aud: "control-api".to_owned(),
        auth_time: 1,
        body_sha256: sha256(body),
        capabilities: vec!["review.legal".to_owned()],
        capability_hash: "b".repeat(64),
        content_type: "application/json".to_owned(),
        exp: 20,
        iat: 1,
        idempotency_key_sha256: Some(sha256(b"legal-hold-idempotency-key")),
        iss: "identity-api".to_owned(),
        jti: "10000000-0000-4000-8000-000000000001".to_owned(),
        method: "POST".to_owned(),
        operation_id: "placeLegalHold".to_owned(),
        path: "/v1/internal/commands/place-legal-hold".to_owned(),
        query_sha256: sha256(b""),
        required_capability: "review.legal".to_owned(),
        roles_version: 1,
        sid: "10000000-0000-4000-8000-000000000002".to_owned(),
        step_up_at: Some(1),
        step_up_authorization_id: Some("10000000-0000-4000-8000-000000000003".to_owned()),
        sub: "10000000-0000-4000-8000-000000000004".to_owned(),
        typ: "actor".to_owned(),
        v: 1,
    }
}

#[test]
fn omitted_and_explicit_null_expiration_share_one_request_digest() -> Result<(), ServiceError> {
    let omitted_raw = br#"{"reason":"hold","scopeAtoms":["RETENTION"],"affectedIds":["10000000-0000-4000-8000-000000000001"]}"#;
    let explicit_raw = br#"{ "expiresAt" : null, "reason" : "hold", "scopeAtoms" : ["RETENTION"], "affectedIds" : ["10000000-0000-4000-8000-000000000001"] }"#;
    let omitted = serde_json::from_slice(omitted_raw).map_err(|_| ServiceError::InvalidRequest)?;
    let explicit =
        serde_json::from_slice(explicit_raw).map_err(|_| ServiceError::InvalidRequest)?;
    let (omitted, omitted_body) = normalized_command_input("placeLegalHold", omitted, omitted_raw)?;
    let (explicit, explicit_body) =
        normalized_command_input("placeLegalHold", explicit, explicit_raw)?;

    assert_eq!(omitted.get("expiresAt"), Some(&Value::Null));
    assert_eq!(omitted, explicit);
    assert_eq!(omitted_body, explicit_body);
    assert_eq!(
        request_digest(&omitted_body)?,
        request_digest(&explicit_body)?
    );
    assert_ne!(
        actor_assertion_request_digest(&actor_claims_for_raw_body(omitted_raw)),
        actor_assertion_request_digest(&actor_claims_for_raw_body(explicit_raw)),
        "semantic idempotency normalization must not replace the signed raw-body binding"
    );
    Ok(())
}

#[test]
fn legal_hold_set_inputs_share_the_database_canonical_order() -> Result<(), ServiceError> {
    let raw = br#"{"scopeAtoms":["RETENTION","DISCLOSURE"],"affectedIds":["20000000-0000-4000-8000-000000000002","10000000-0000-4000-8000-000000000001"]}"#;
    let payload: Value = serde_json::from_slice(raw).map_err(|_| ServiceError::InvalidRequest)?;
    let (normalized, _) = normalized_command_input("placeLegalHold", payload, raw)?;

    assert_eq!(
        normalized.get("scopeAtoms"),
        Some(&json!(["DISCLOSURE", "RETENTION"]))
    );
    assert_eq!(
        normalized.get("affectedIds"),
        Some(&json!([
            "10000000-0000-4000-8000-000000000001",
            "20000000-0000-4000-8000-000000000002"
        ]))
    );
    Ok(())
}

#[test]
fn actor_assertion_digest_remains_bound_to_the_raw_http_body() -> Result<(), ServiceError> {
    let raw =
        br#"{"scopeAtoms":["RETENTION"],"affectedIds":["10000000-0000-4000-8000-000000000001"]}"#;
    let claims = actor_claims_for_raw_body(raw);

    assert_eq!(
        actor_assertion_request_digest(&claims),
        request_digest(raw)?
    );
    Ok(())
}

#[test]
fn owner_payload_keeps_raw_assertion_proof_separate_from_semantic_idempotency()
-> Result<(), ServiceError> {
    let raw = br#"{"target":{},"scopeAtoms":["RETENTION"],"affectedIds":["10000000-0000-4000-8000-000000000001"]}"#;
    let payload: Value = serde_json::from_slice(raw).map_err(|_| ServiceError::InvalidRequest)?;
    let (mut normalized, semantic_body) = normalized_command_input("placeLegalHold", payload, raw)?;
    let claims = actor_claims_for_raw_body(raw);
    let assertion_request_digest = actor_assertion_request_digest(&claims);
    let semantic_request_digest = request_digest(&semantic_body)?;
    let key = CommandKey {
        scope: "control:actor:placeLegalHold".to_owned(),
        key_hash: sha256(b"legal-hold-idempotency-key"),
        request_hash: semantic_request_digest.clone(),
    };
    let object = normalized
        .as_object_mut()
        .ok_or(ServiceError::InvalidRequest)?;

    bind_editorial_owner_authority("placeLegalHold", &claims, Uuid::from_u128(7), &key, object);

    assert_eq!(
        object
            .get("_actorAssertionRequestSha256")
            .and_then(Value::as_str),
        Some(assertion_request_digest.as_str())
    );
    assert_eq!(
        object.get("_requestSha256").and_then(Value::as_str),
        Some(semantic_request_digest.as_str())
    );
    assert_ne!(
        object.get("_actorAssertionRequestSha256"),
        object.get("_requestSha256")
    );
    Ok(())
}

#[test]
fn r6d_authority_owner_payloads_keep_the_signed_assertion_request_digest()
-> Result<(), ServiceError> {
    let raw = br#"{"entityKind":"SUPPLIER"}"#;
    let claims = actor_claims_for_raw_body(raw);
    let expected = actor_assertion_request_digest(&claims);
    let key = CommandKey {
        scope: "control:actor:r6d-authority".to_owned(),
        key_hash: sha256(b"r6d-authority-idempotency-key"),
        request_hash: "f".repeat(64),
    };

    for operation in [
        "attestOrganizationOfficialChannel",
        "revokeOrganizationOfficialChannel",
        "classifyEntityPersonhood",
        "attestEntityMaterialUseClosure",
    ] {
        let mut payload = Map::new();
        bind_editorial_owner_authority(operation, &claims, Uuid::from_u128(7), &key, &mut payload);
        assert_eq!(
            payload
                .get("_actorAssertionRequestSha256")
                .and_then(Value::as_str),
            Some(expected.as_str())
        );
        assert_eq!(
            payload.get("_requestSha256").and_then(Value::as_str),
            Some(key.request_hash.as_str())
        );
        assert_ne!(
            payload.get("_actorAssertionRequestSha256"),
            payload.get("_requestSha256")
        );
    }
    Ok(())
}

#[test]
fn unrelated_operations_keep_the_exact_raw_idempotency_body() -> Result<(), ServiceError> {
    let raw = br#"{ "jobId" : "10000000-0000-4000-8000-000000000001" }"#;
    let payload: Value = serde_json::from_slice(raw).map_err(|_| ServiceError::InvalidRequest)?;
    let expected = payload.clone();
    let (actual, digest_body) = normalized_command_input("cancelJob", payload, raw)?;

    assert_eq!(actual, expected);
    assert_eq!(digest_body.as_ref(), raw);
    assert!(matches!(digest_body, std::borrow::Cow::Borrowed(_)));
    Ok(())
}

#[test]
fn owner_operation_allowlist_is_closed() {
    for operation in [
        "attestOrganizationOfficialChannel",
        "attestEntityMaterialUseClosure",
        "approveResponseExcerpt",
        "previewPublication",
        "publishCase",
        "placeLegalHold",
        "submitReview",
        "transitionRetentionRequest",
        "verifyResponseOrganizationIdentity",
        "revokeOrganizationOfficialChannel",
        "classifyEntityPersonhood",
    ] {
        assert!(
            matches!(owner_managed_request(operation, &json!({})), Ok(true)),
            "missing {operation}"
        );
    }
    for operation in ["transitionCase", "createCorrection"] {
        assert!(
            matches!(owner_managed_request(operation, &json!({})), Ok(false)),
            "unexpected {operation}"
        );
    }
    assert!(matches!(
        owner_managed_request(
            "resolveCorrectionRequest",
            &json!({"resolution":"RESOLVED"}),
        ),
        Ok(true)
    ));
    assert!(matches!(
        owner_managed_request(
            "resolveCorrectionRequest",
            &json!({"resolution":"REJECTED"}),
        ),
        Ok(false)
    ));
    assert!(matches!(
        owner_managed_request("resolveCorrectionRequest", &json!({})),
        Err(ServiceError::InvalidRequest)
    ));
}

#[test]
fn cached_official_channel_receipts_require_closed_authority_proof() {
    let mut attest = owner_response();
    attest["operationId"] = json!("attestOrganizationOfficialChannel");
    attest["aggregateVersion"] = json!(1);
    attest["assertionId"] = json!("10000000-0000-4000-8000-000000000002");
    attest["authorityReceiptId"] = json!("10000000-0000-4000-8000-000000000005");
    attest["authorityReceiptDigest"] = json!("b".repeat(64));
    attest["registryReceiptDigest"] = json!("a".repeat(64));
    attest["expiresAt"] = json!("2027-08-01T00:00:00Z");
    assert!(
        validate_owner_replay_if_required("attestOrganizationOfficialChannel", &attest).is_ok()
    );
    let mut expanded = attest.clone();
    expanded["rawDomain"] = json!("organization.example");
    assert!(matches!(
        validate_owner_replay_if_required("attestOrganizationOfficialChannel", &expanded),
        Err(ServiceError::IdempotencyConflict)
    ));
    attest["authorityReceiptDigest"] = Value::Null;
    assert!(matches!(
        validate_owner_replay_if_required("attestOrganizationOfficialChannel", &attest),
        Err(ServiceError::IdempotencyConflict)
    ));

    let mut revoke = owner_response();
    revoke["operationId"] = json!("revokeOrganizationOfficialChannel");
    revoke["aggregateVersion"] = json!(1);
    revoke["revocationId"] = json!("10000000-0000-4000-8000-000000000002");
    revoke["assertionId"] = json!("10000000-0000-4000-8000-000000000004");
    revoke["aggregateId"] = revoke["assertionId"].clone();
    assert!(
        validate_owner_replay_if_required("revokeOrganizationOfficialChannel", &revoke).is_ok()
    );
    let mut receipt_as_aggregate = revoke.clone();
    receipt_as_aggregate["aggregateId"] = receipt_as_aggregate["revocationId"].clone();
    assert!(matches!(
        validate_owner_replay_if_required(
            "revokeOrganizationOfficialChannel",
            &receipt_as_aggregate,
        ),
        Err(ServiceError::IdempotencyConflict)
    ));
    revoke["operationId"] = json!("attestOrganizationOfficialChannel");
    assert!(matches!(
        validate_owner_replay_if_required("revokeOrganizationOfficialChannel", &revoke),
        Err(ServiceError::IdempotencyConflict)
    ));
}

#[test]
fn cached_entity_authority_receipts_keep_exact_owner_bindings() {
    let mut classification = owner_response();
    classification["operationId"] = json!("classifyEntityPersonhood");
    classification["aggregateVersion"] = json!(1);
    classification["receiptId"] = json!("10000000-0000-4000-8000-000000000002");
    classification["entityKind"] = json!("SUPPLIER");
    classification["entityId"] = json!("10000000-0000-4000-8000-000000000010");
    classification["classification"] = json!("NATURAL_PERSON");
    assert!(validate_owner_replay_if_required("classifyEntityPersonhood", &classification).is_ok());
    let mut leaked_name = classification.clone();
    leaked_name["personName"] = json!("평문 이름");
    assert!(matches!(
        validate_owner_replay_if_required("classifyEntityPersonhood", &leaked_name),
        Err(ServiceError::IdempotencyConflict)
    ));

    let mut closure = owner_response();
    closure["operationId"] = json!("attestEntityMaterialUseClosure");
    closure["aggregateVersion"] = json!(1);
    closure["closureReceiptId"] = json!("10000000-0000-4000-8000-000000000002");
    closure["entityKind"] = json!("AGENCY");
    closure["entityId"] = json!("10000000-0000-4000-8000-000000000011");
    closure["personhoodReceiptId"] = json!("10000000-0000-4000-8000-000000000012");
    closure["closureAt"] = json!("2026-08-01T00:00:00Z");
    closure["lastContractEndAt"] = Value::Null;
    closure["linkedPublicationRevisionCount"] = json!(0);
    assert!(validate_owner_replay_if_required("attestEntityMaterialUseClosure", &closure).is_ok());

    let mut malformed_links = closure.clone();
    malformed_links["links"] = json!([{"rel":"self","href":"/ok","rawAddress":"주소"}]);
    assert!(matches!(
        validate_owner_replay_if_required("attestEntityMaterialUseClosure", &malformed_links),
        Err(ServiceError::IdempotencyConflict)
    ));

    closure["linkedPublicationRevisionCount"] = json!(-1);
    assert!(matches!(
        validate_owner_replay_if_required("attestEntityMaterialUseClosure", &closure),
        Err(ServiceError::IdempotencyConflict)
    ));
}

#[test]
fn cached_owner_response_requires_exact_receipt_metadata() {
    assert!(validate_owner_replay_if_required("publishCase", &owner_response()).is_ok());
    let mut missing = owner_response();
    missing["receiptToken"] = Value::Null;
    assert!(matches!(
        validate_owner_replay_if_required("publishCase", &missing),
        Err(ServiceError::IdempotencyConflict)
    ));
}

#[test]
fn correction_replay_uses_receipt_token_as_the_owner_branch_proof() {
    let generic = json!({
        "operationId":"resolveCorrectionRequest",
        "status":"completed"
    });
    assert!(validate_owner_replay_if_required("resolveCorrectionRequest", &generic).is_ok());

    let mut owner = owner_response();
    owner["operationId"] = json!("resolveCorrectionRequest");
    assert!(validate_owner_replay_if_required("resolveCorrectionRequest", &owner).is_ok());

    owner["receiptToken"] = Value::Null;
    assert!(matches!(
        validate_owner_replay_if_required("resolveCorrectionRequest", &owner),
        Err(ServiceError::IdempotencyConflict)
    ));
}

#[test]
fn cached_legal_hold_response_is_the_closed_standard_envelope() {
    let response = json!({
        "operationId":"placeLegalHold",
        "requestId":"10000000-0000-4000-8000-000000000001",
        "status":"completed",
        "aggregateId":"10000000-0000-4000-8000-000000000002",
        "aggregateVersion":1,
        "auditEventId":"10000000-0000-4000-8000-000000000003",
        "acceptedAt":"2026-08-01T00:00:00Z",
        "links":[]
    });
    assert!(validate_owner_replay_response("placeLegalHold", &response).is_ok());
    let mut expanded = response;
    expanded["receiptDigest"] =
        json!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    assert!(matches!(
        validate_owner_replay_response("placeLegalHold", &expanded),
        Err(ServiceError::IdempotencyConflict)
    ));
}
