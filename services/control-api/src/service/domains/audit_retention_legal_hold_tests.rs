use super::*;

const TARGET_ID: &str = "10000000-0000-4000-8000-000000000001";
const CONTEXT_ID: &str = "10000000-0000-4000-8000-000000000002";
const RECEIPT_ID: &str = "10000000-0000-4000-8000-000000000003";
const AUDIT_ID: &str = "10000000-0000-4000-8000-000000000004";
const OUTBOX_ID: &str = "10000000-0000-4000-8000-000000000005";
const REQUEST_ID: &str = "10000000-0000-4000-8000-000000000006";
const ACTOR_ID: &str = "10000000-0000-4000-8000-000000000007";
const DIGEST_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const DIGEST_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const DIGEST_C: &str = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

fn request_payload(target: Value) -> Map<String, Value> {
    json!({
        "target":target,
        "scopeAtoms":["RETENTION","DISCLOSURE"],
        "affectedIds":[CONTEXT_ID,TARGET_ID],
        "authorityReference":"법적 보존 명령 2026-08-01",
        "reasonCode":"PENDING_LITIGATION",
        "reason":"관련 기록을 정확히 보존",
        "expiresAt":null,
        "_actorEffectiveCapability":"review.legal",
        "_actorAssertionJti":CONTEXT_ID,
        "_actorAssuranceLevel":"STEP_UP",
        "_actorActionDigest":DIGEST_A,
        "_actorStepUpAuthorizationId":CONTEXT_ID,
        "_actorIdempotencyKeySha256":DIGEST_B,
        "_actorAssertionRequestSha256":DIGEST_A,
        "_actorRequestKeySha256":DIGEST_B,
        "_requestId":REQUEST_ID,
        "_requestSha256":DIGEST_C,
        "_idempotencyKeySha256":DIGEST_B
    })
    .as_object()
    .cloned()
    .unwrap_or_default()
}

fn target_variants() -> Vec<Value> {
    vec![
        json!({"targetKind":"CASE","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"caseId":TARGET_ID,"reviewSnapshotId":CONTEXT_ID,"reviewSnapshotDigest":DIGEST_B}),
        json!({"targetKind":"PUBLICATION","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"publicationRevisionId":TARGET_ID}),
        json!({"targetKind":"EVIDENCE","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"evidenceId":TARGET_ID}),
        json!({"targetKind":"RESPONSE","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"responseId":TARGET_ID}),
        json!({"targetKind":"SOURCE_ASSET","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"sourceDocumentId":CONTEXT_ID,"sourceAssetId":TARGET_ID}),
        json!({"targetKind":"RESEARCH_ARTIFACT","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"researchArtifactId":CONTEXT_ID,"researchAssetId":TARGET_ID}),
        json!({"targetKind":"PRIVACY_REQUEST","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"privacyRequestId":TARGET_ID,"privacyRequestType":"DELETION"}),
        json!({"targetKind":"COMMUNICATION_SUBJECT","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"communicationSubjectId":TARGET_ID,"communicationSubjectOriginDigest":DIGEST_B}),
        json!({"targetKind":"SUPPLIER_RETENTION_SNAPSHOT","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"entityKind":"SUPPLIER","entityRetentionSnapshotId":TARGET_ID,"entityRetentionSnapshotDigest":DIGEST_A}),
        json!({"targetKind":"AGENCY_RETENTION_SNAPSHOT","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"entityKind":"AGENCY","entityRetentionSnapshotId":TARGET_ID,"entityRetentionSnapshotDigest":DIGEST_A}),
        json!({"targetKind":"CORRECTION","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"correctionId":CONTEXT_ID,"correctionSnapshotId":TARGET_ID,"correctionSnapshotDigest":DIGEST_A}),
        json!({"targetKind":"SUBSCRIPTION","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"subscriptionId":CONTEXT_ID,"subscriptionSnapshotId":TARGET_ID,"subscriptionSnapshotDigest":DIGEST_A}),
        json!({"targetKind":"COMMUNICATION_ENDPOINT","targetId":TARGET_ID,"targetVersion":1,"targetDigest":DIGEST_A,"communicationEndpointId":TARGET_ID}),
    ]
}

fn parsed_request() -> Option<LegalHoldOwnerRequest> {
    let target = target_variants().into_iter().next()?;
    LegalHoldOwnerRequest::parse(&request_payload(target)).ok()
}

fn owner_result(request: &LegalHoldOwnerRequest) -> Value {
    let mut persisted_target = request.target.as_object().cloned().unwrap_or_default();
    persisted_target.insert("targetAnchorDigest".to_owned(), json!(DIGEST_B));
    json!({
        "schemaVersion":RECEIPT_SCHEMA,
        "receiptId":RECEIPT_ID,
        "legalHoldId":TARGET_ID,
        "target":persisted_target,
        "scopeAtoms":request.scope_atoms,
        "scopeAtomsDigest":canonical_value_digest(&request.scope_atoms).unwrap_or_default(),
        "affectedIds":request.affected_ids,
        "affectedSetDigest":canonical_value_digest(&request.affected_ids).unwrap_or_default(),
        "authorityReferenceDigest":sha256(request.authority_reference.as_bytes()),
        "reasonDigest":sha256(request.reason.as_bytes()),
        "placedByActorId":ACTOR_ID,
        "placedAt":"2026-08-01T00:00:00Z",
        "expiresAt":null,
        "requestId":REQUEST_ID,
        "requestDigest":DIGEST_C,
        "idempotencyKeySha256":DIGEST_B,
        "auditEventId":AUDIT_ID,
        "auditReceiptDigest":DIGEST_C,
        "receiptDigest":DIGEST_A,
        "holdReceiptDigest":DIGEST_A,
        "outboxEventIds":[OUTBOX_ID],
        "replayed":false
    })
}

#[test]
fn all_thirteen_supported_target_branches_build_the_exact_canonical_owner_payload() {
    for target in target_variants() {
        let request = request_payload(target);
        let parsed = LegalHoldOwnerRequest::parse(&request);
        assert!(parsed.is_ok());
        if let Ok(parsed) = parsed {
            let keys = parsed
                .payload
                .as_object()
                .map(|object| object.keys().map(String::as_str).collect::<BTreeSet<_>>())
                .unwrap_or_default();
            assert_eq!(
                keys,
                BTreeSet::from([
                    "target",
                    "scopeAtoms",
                    "affectedIds",
                    "authorityReference",
                    "reasonCode",
                    "reason",
                    "expiresAt",
                    "_actorEffectiveCapability",
                    "_actorAssertionJti",
                    "_actorAssuranceLevel",
                    "_actorActionDigest",
                    "_actorStepUpAuthorizationId",
                    "_actorIdempotencyKeySha256",
                    "_actorAssertionRequestSha256",
                    "_actorRequestKeySha256",
                    "_requestId",
                    "_requestSha256",
                    "_idempotencyKeySha256",
                ])
            );
            assert_eq!(
                parsed.payload.get("scopeAtoms"),
                Some(&json!(["DISCLOSURE", "RETENTION"]))
            );
            assert_eq!(
                parsed.payload.get("affectedIds"),
                Some(&json!([TARGET_ID, CONTEXT_ID]))
            );
            for key in PUBLIC_REQUEST_KEYS
                .iter()
                .filter(|key| !matches!(**key, "scopeAtoms" | "affectedIds"))
                .chain(INTERNAL_REQUEST_KEYS)
            {
                assert_eq!(parsed.payload.get(*key), request.get(*key));
            }
        }
    }
}

#[test]
fn request_and_target_shapes_fail_closed() {
    let mut extra_request = request_payload(target_variants()[0].clone());
    extra_request.insert("anchorId".to_owned(), json!(TARGET_ID));
    assert!(matches!(
        LegalHoldOwnerRequest::parse(&extra_request),
        Err(ServiceError::InvalidRequest)
    ));

    let mut duplicate_scope = request_payload(target_variants()[0].clone());
    duplicate_scope.insert("scopeAtoms".to_owned(), json!(["RETENTION", "RETENTION"]));
    assert!(matches!(
        LegalHoldOwnerRequest::parse(&duplicate_scope),
        Err(ServiceError::InvalidRequest)
    ));

    let mut wrong_asset = target_variants()[4].clone();
    wrong_asset["sourceAssetId"] = json!(CONTEXT_ID);
    assert!(matches!(
        LegalHoldOwnerRequest::parse(&request_payload(wrong_asset)),
        Err(ServiceError::InvalidRequest)
    ));

    let mut extra_target = target_variants()[0].clone();
    extra_target["anchorDigest"] = json!(DIGEST_B);
    assert!(matches!(
        LegalHoldOwnerRequest::parse(&request_payload(extra_target)),
        Err(ServiceError::InvalidRequest)
    ));

    let mut active_session = request_payload(target_variants()[0].clone());
    active_session.insert("_actorAssuranceLevel".to_owned(), json!("ACTIVE_SESSION"));
    assert!(matches!(
        LegalHoldOwnerRequest::parse(&active_session),
        Err(ServiceError::Persistence)
    ));

    let mut mismatched_idempotency = request_payload(target_variants()[0].clone());
    mismatched_idempotency.insert("_actorIdempotencyKeySha256".to_owned(), json!(DIGEST_A));
    assert!(matches!(
        LegalHoldOwnerRequest::parse(&mismatched_idempotency),
        Err(ServiceError::Persistence)
    ));

    for target_index in [10_usize, 11] {
        let mut mismatched_snapshot = target_variants()[target_index].clone();
        if target_index == 10 {
            mismatched_snapshot["correctionSnapshotDigest"] = json!(DIGEST_B);
        } else {
            mismatched_snapshot["subscriptionSnapshotDigest"] = json!(DIGEST_B);
        }
        assert!(matches!(
            LegalHoldOwnerRequest::parse(&request_payload(mismatched_snapshot)),
            Err(ServiceError::InvalidRequest)
        ));
    }

    let mut mismatched_endpoint = target_variants()[12].clone();
    mismatched_endpoint["communicationEndpointId"] = json!(CONTEXT_ID);
    assert!(matches!(
        LegalHoldOwnerRequest::parse(&request_payload(mismatched_endpoint)),
        Err(ServiceError::InvalidRequest)
    ));
}

#[test]
fn audit_subject_record_is_explicitly_unsupported_before_generic_shape_validation() {
    let target = json!({"targetKind":"AUDIT_SUBJECT_RECORD"});
    assert!(matches!(
        LegalHoldOwnerRequest::parse(&request_payload(target)),
        Err(ServiceError::LegalHoldTargetUnsupported)
    ));
}

#[test]
#[expect(
    clippy::assertions_on_constants,
    reason = "fixture setup failures are test assertions"
)]
fn owner_receipt_requires_exact_bound_proof_and_one_outbox_event() {
    let Some(request) = parsed_request() else {
        assert!(false, "valid legal-hold request fixture must parse");
        return;
    };
    let actor = Uuid::parse_str(ACTOR_ID).ok();
    assert!(actor.is_some());
    if let Some(actor) = actor {
        let receipt = parse_owner_result(&owner_result(&request), &request, actor);
        assert!(receipt.is_ok());

        let mut missing_event = owner_result(&request);
        missing_event["outboxEventIds"] = json!([]);
        assert!(matches!(
            parse_owner_result(&missing_event, &request, actor),
            Err(ServiceError::Persistence)
        ));

        let mut mismatched_digest = owner_result(&request);
        mismatched_digest["holdReceiptDigest"] = json!(DIGEST_B);
        assert!(matches!(
            parse_owner_result(&mismatched_digest, &request, actor),
            Err(ServiceError::Persistence)
        ));

        let mut wrong_scope_digest = owner_result(&request);
        wrong_scope_digest["scopeAtomsDigest"] = json!(DIGEST_B);
        assert!(matches!(
            parse_owner_result(&wrong_scope_digest, &request, actor),
            Err(ServiceError::Persistence)
        ));

        let mut wrong_affected_digest = owner_result(&request);
        wrong_affected_digest["affectedSetDigest"] = json!(DIGEST_A);
        assert!(matches!(
            parse_owner_result(&wrong_affected_digest, &request, actor),
            Err(ServiceError::Persistence)
        ));

        let mut plaintext_leak = owner_result(&request);
        plaintext_leak["reason"] = json!(request.reason);
        assert!(matches!(
            parse_owner_result(&plaintext_leak, &request, actor),
            Err(ServiceError::Persistence)
        ));
    }
}

#[test]
#[expect(
    clippy::assertions_on_constants,
    reason = "fixture setup failures are test assertions"
)]
fn owner_receipt_echoes_exact_request_and_target_binding() {
    let Some(request) = parsed_request() else {
        assert!(false, "valid legal-hold request fixture must parse");
        return;
    };
    let Some(actor) = Uuid::parse_str(ACTOR_ID).ok() else {
        assert!(false, "valid actor fixture must parse");
        return;
    };
    let mut wrong_request = owner_result(&request);
    wrong_request["requestDigest"] = json!(DIGEST_A);
    assert!(matches!(
        parse_owner_result(&wrong_request, &request, actor),
        Err(ServiceError::Persistence)
    ));

    let mut wrong_target = owner_result(&request);
    wrong_target["target"]["targetId"] = json!(CONTEXT_ID);
    assert!(matches!(
        parse_owner_result(&wrong_target, &request, actor),
        Err(ServiceError::Persistence)
    ));

    let mut wrong_schema = owner_result(&request);
    wrong_schema["schemaVersion"] = json!(2);
    assert!(matches!(
        parse_owner_result(&wrong_schema, &request, actor),
        Err(ServiceError::Persistence)
    ));
}
