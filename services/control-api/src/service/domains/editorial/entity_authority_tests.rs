use super::*;

fn with_authority(mut public: Value) -> Result<Map<String, Value>, ServiceError> {
    let server = json!({
        "_actorAssertionJti":"10000000-0000-4000-8000-000000000010",
        "_actorAssertionRequestSha256":"9".repeat(64),
        "_actorAssuranceLevel":"STEP_UP",
        "_actorEffectiveCapability":"users.manage",
        "_actorActionDigest":"a".repeat(64),
        "_actorStepUpAuthorizationId":"10000000-0000-4000-8000-000000000011",
        "_actorIdempotencyKeySha256":"b".repeat(64),
        "_actorRequestKeySha256":"c".repeat(64),
        "_requestId":"10000000-0000-4000-8000-000000000012",
        "_idempotencyKeySha256":"d".repeat(64),
        "_requestSha256":"e".repeat(64)
    });
    let public = public.as_object_mut().ok_or(ServiceError::Persistence)?;
    for (key, value) in server.as_object().ok_or(ServiceError::Persistence)? {
        public.insert(key.clone(), value.clone());
    }
    Ok(public.clone())
}

fn classification_payload() -> Result<Map<String, Value>, ServiceError> {
    with_authority(json!({
        "entityKind":"SUPPLIER",
        "entityId":"10000000-0000-4000-8000-000000000001",
        "classification":"NATURAL_PERSON",
        "evidenceSourceLocator":"https://public.example.invalid/registration/1",
        "expectedEntityUpdatedAt":"2026-08-01T00:00:00Z",
        "reason":"공개 사업자 등록 형태를 사람이 검토함"
    }))
}

#[test]
fn classification_request_is_exact_public_six_plus_actor_eight() -> Result<(), ServiceError> {
    let request = classification_owner_request(&classification_payload()?)?;
    assert_eq!(request.as_object().map(Map::len), Some(14));
    assert_eq!(request["classification"], "NATURAL_PERSON");
    assert_eq!(request["_actorEffectiveCapability"], "users.manage");
    assert_eq!(request["_actorAssertionRequestSha256"], "9".repeat(64));
    assert_ne!(
        request["_actorAssertionRequestSha256"],
        request["_requestSha256"]
    );
    assert!(request.get("receiptDigest").is_none());

    let mut automated = classification_payload()?;
    automated.insert("classification".to_owned(), json!("AUTO_DETECTED"));
    assert!(matches!(
        classification_owner_request(&automated),
        Err(ServiceError::InvalidRequest)
    ));

    let mut oversized_locator = classification_payload()?;
    oversized_locator.insert("evidenceSourceLocator".to_owned(), json!("x".repeat(2_001)));
    assert!(matches!(
        classification_owner_request(&oversized_locator),
        Err(ServiceError::InvalidRequest)
    ));

    let mut control_reason = classification_payload()?;
    control_reason.insert("reason".to_owned(), json!("검토\n사유"));
    assert!(matches!(
        classification_owner_request(&control_reason),
        Err(ServiceError::InvalidRequest)
    ));

    let mut source_operator = classification_payload()?;
    source_operator.insert(
        "_actorEffectiveCapability".to_owned(),
        json!("sources.operate"),
    );
    assert!(matches!(
        classification_owner_request(&source_operator),
        Err(ServiceError::PreconditionFailed)
    ));
    Ok(())
}

#[test]
fn closure_request_is_exact_public_five_plus_actor_eight() -> Result<(), ServiceError> {
    let request = closure_owner_request(&with_authority(json!({
        "entityKind":"AGENCY",
        "entityId":"10000000-0000-4000-8000-000000000001",
        "personhoodReceiptId":"10000000-0000-4000-8000-000000000002",
        "expectedEntityUpdatedAt":"2026-08-01T00:00:00Z",
        "reason":"계약 종료와 공개 revision 폐쇄를 사람이 확인함"
    }))?)?;
    assert_eq!(request.as_object().map(Map::len), Some(13));
    assert_eq!(request["_actorEffectiveCapability"], "users.manage");
    assert_eq!(request["_actorAssertionRequestSha256"], "9".repeat(64));
    assert_ne!(
        request["_actorAssertionRequestSha256"],
        request["_requestSha256"]
    );
    assert!(request.get("closureReceiptId").is_none());
    Ok(())
}

#[test]
fn owner_results_bind_exact_entity_and_receipt() -> Result<(), ServiceError> {
    let classification_request = classification_owner_request(&classification_payload()?)?;
    let classification_result = json!({
        "receiptId":"10000000-0000-4000-8000-000000000020",
        "entityKind":"SUPPLIER",
        "entityId":"10000000-0000-4000-8000-000000000001",
        "classification":"NATURAL_PERSON",
        "receiptDigest":"a".repeat(64),
        "auditEventId":"10000000-0000-4000-8000-000000000021",
        "classifiedAt":"2026-08-01T00:00:00Z",
        "outboxEventIds":["10000000-0000-4000-8000-000000000022"],
        "replayed":false
    });
    assert!(parse_classification_result(&classification_result, &classification_request).is_ok());

    let mut wrong_entity = classification_result;
    wrong_entity["entityId"] = json!("10000000-0000-4000-8000-000000000099");
    assert!(matches!(
        parse_classification_result(&wrong_entity, &classification_request),
        Err(ServiceError::Persistence)
    ));
    Ok(())
}

#[test]
fn closure_result_allows_no_contract_and_rejects_bad_count() -> Result<(), ServiceError> {
    let request = closure_owner_request(&with_authority(json!({
        "entityKind":"SUPPLIER",
        "entityId":"10000000-0000-4000-8000-000000000001",
        "personhoodReceiptId":"10000000-0000-4000-8000-000000000002",
        "expectedEntityUpdatedAt":"2026-08-01T00:00:00Z",
        "reason":"물질적 이용 종료 확인"
    }))?)?;
    let result = json!({
        "closureReceiptId":"10000000-0000-4000-8000-000000000030",
        "entityKind":"SUPPLIER",
        "entityId":"10000000-0000-4000-8000-000000000001",
        "personhoodReceiptId":"10000000-0000-4000-8000-000000000002",
        "receiptDigest":"a".repeat(64),
        "closureAt":"2026-08-01T14:59:59Z",
        "lastContractEndAt":null,
        "linkedPublicationRevisionCount":0,
        "auditEventId":"10000000-0000-4000-8000-000000000031",
        "attestedAt":"2026-08-01T15:00:00Z",
        "outboxEventIds":["10000000-0000-4000-8000-000000000032"],
        "replayed":false
    });
    assert!(parse_closure_result(&result, &request).is_ok());

    let mut invalid = result;
    invalid["linkedPublicationRevisionCount"] = json!(-1);
    assert!(matches!(
        parse_closure_result(&invalid, &request),
        Err(ServiceError::Persistence)
    ));
    Ok(())
}
