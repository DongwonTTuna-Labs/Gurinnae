use super::*;

const ID: &str = "00000000-0000-4000-8000-000000000001";
const SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn pending_summary(id: &str) -> Value {
    json!({
        "retentionRequestId": id,
        "requestType": "ACCESS",
        "decisionVersion": 0,
        "state": "RECEIVED",
        "jurisdiction": "KR",
        "scopeDigest": SHA,
        "identityState": "PENDING_VERIFICATION",
        "identityVerifiedAt": null,
        "dueAt": null,
        "legalHoldBlocked": false,
        "createdAt": "2026-08-01T00:00:00Z",
        "updatedAt": "2026-08-01T00:00:00Z"
    })
}

fn page(item: Value) -> Value {
    json!({
        "items": [item],
        "appliedFilters": {
            "requestType": [],
            "state": [],
            "dueBefore": null,
            "legalHoldBlocked": null,
            "sort": "DUE_ASC"
        },
        "asOf": "2026-08-01T00:01:00Z",
        "nextCursor": null,
        "totalApproximate": 1,
        "links": []
    })
}

fn pending_workspace() -> Value {
    json!({
        "request": pending_summary(ID),
        "identityVerificationReceiptId": null,
        "identityVerificationReceiptDigest": null,
        "policyVersion": null,
        "policyDigest": null,
        "calendarVersionId": null,
        "calendarDigest": null,
        "inventorySnapshotDigest": null,
        "holdCoverageDigest": null,
        "activeHoldIds": [],
        "affectedRecordClasses": [],
        "locationReceipts": [],
        "decisionReceipts": [],
        "completionReceiptId": null,
        "completionReceiptDigest": null,
        "completedResponseVersion": null,
        "completedValueDigest": null,
        "accessProjection": null,
        "asOf": "2026-08-01T00:01:00Z",
        "links": []
    })
}

fn verified_workspace() -> Value {
    let mut workspace = pending_workspace();
    workspace["request"] = json!({
        "retentionRequestId": ID,
        "requestType": "ACCESS",
        "decisionVersion": 1,
        "state": "RECEIVED",
        "jurisdiction": "KR",
        "scopeDigest": SHA,
        "identityState": "VERIFIED",
        "identityVerifiedAt": "2026-08-01T00:00:00Z",
        "dueAt": "2026-08-18T00:00:00Z",
        "legalHoldBlocked": false,
        "createdAt": "2026-07-31T23:59:00Z",
        "updatedAt": "2026-08-01T00:00:00Z"
    });
    workspace["identityVerificationReceiptId"] = json!("00000000-0000-4000-8000-000000000002");
    workspace["identityVerificationReceiptDigest"] = json!("b".repeat(64));
    workspace["policyVersion"] = json!("counsel-approved-v1");
    workspace["policyDigest"] = json!("c".repeat(64));
    workspace["calendarVersionId"] = json!("00000000-0000-4000-8000-000000000003");
    workspace["calendarDigest"] = json!("d".repeat(64));
    workspace["decisionReceipts"] = json!([{
        "transitionReceiptId": "00000000-0000-4000-8000-000000000004",
        "decisionVersion": 1,
        "transition": "VERIFY_IDENTITY",
        "priorState": "RECEIVED",
        "state": "RECEIVED",
        "reasonCode": "IDENTITY_CONFIRMED",
        "reasonDigest": "e".repeat(64),
        "identityReceiptId": "00000000-0000-4000-8000-000000000002",
        "extensionReceiptId": null,
        "refusalReceiptId": null,
        "noticeReceiptId": "00000000-0000-4000-8000-000000000005",
        "decidedAt": "2026-08-01T00:00:00Z",
        "transitionReceiptDigest": "f".repeat(64)
    }]);
    workspace
}

fn response_access_projection() -> Value {
    let party_name = "정정 전 기관명";
    let mut projection = json!({
        "schemaVersion": "privacy-response-party-name-access.v1",
        "retentionRequestId": ID,
        "targetObjectType": "RESPONSE",
        "targetObjectId": "00000000-0000-4000-8000-000000000010",
        "fieldPath": "/partyName",
        "partyName": party_name,
        "currentValueDigest": sha256(party_name.as_bytes()),
        "projectionDigest": "1".repeat(64),
        "responseVersion": 4,
        "privacyIdentityProofReceiptId": "00000000-0000-4000-8000-000000000011",
        "privacyIdentityProofReceiptDigest": "2".repeat(64),
        "responseSubmissionReceiptId": "00000000-0000-4000-8000-000000000012",
        "responseSubmissionReceiptDigest": "3".repeat(64),
        "responseOriginReceiptId": "00000000-0000-4000-8000-000000000013",
        "responseOriginReceiptDigest": "4".repeat(64),
        "sourceResponseRequestId": "00000000-0000-4000-8000-000000000014",
        "asOf": "2026-08-01T00:01:00Z"
    });
    let mut preimage = projection.clone();
    if let Some(preimage) = preimage.as_object_mut() {
        preimage.remove("projectionDigest");
        preimage.remove("asOf");
        preimage.insert(
            "schemaVersion".to_owned(),
            json!("privacy-response-party-name-access-preimage.v1"),
        );
    }
    if let Ok(projection_digest) = canonical_json_digest(&preimage) {
        projection["projectionDigest"] = json!(projection_digest);
    }
    projection
}

fn approved_correction_workspace() -> Value {
    let mut workspace = verified_workspace();
    workspace["request"]["requestType"] = json!("CORRECTION");
    workspace["request"]["decisionVersion"] = json!(3);
    workspace["request"]["state"] = json!("APPROVED");
    workspace["request"]["updatedAt"] = json!("2026-08-01T00:00:30Z");
    if let Some(decisions) = workspace["decisionReceipts"].as_array_mut() {
        decisions.extend([
            json!({
                    "transitionReceiptId": "00000000-0000-4000-8000-000000000006",
                    "decisionVersion": 2,
                    "transition": "START_REVIEW",
                    "priorState": "RECEIVED",
                    "state": "REVIEW",
                    "reasonCode": "REVIEW_STARTED",
                    "reasonDigest": "6".repeat(64),
                    "identityReceiptId": null,
                    "extensionReceiptId": null,
                    "refusalReceiptId": null,
                    "noticeReceiptId": null,
                    "decidedAt": "2026-08-01T00:00:10Z",
                    "transitionReceiptDigest": "7".repeat(64)
            }),
            json!({
                    "transitionReceiptId": "00000000-0000-4000-8000-000000000007",
                    "decisionVersion": 3,
                    "transition": "APPROVE",
                    "priorState": "REVIEW",
                    "state": "APPROVED",
                    "reasonCode": "CORRECTION_APPROVED",
                    "reasonDigest": "8".repeat(64),
                    "identityReceiptId": null,
                    "extensionReceiptId": null,
                    "refusalReceiptId": null,
                    "noticeReceiptId": null,
                    "decidedAt": "2026-08-01T00:00:30Z",
                    "transitionReceiptDigest": "9".repeat(64)
            }),
        ]);
    }
    workspace["accessProjection"] = response_access_projection();
    workspace
}

#[test]
fn queue_filters_are_closed_and_preserve_effective_values() {
    let defaults = RetentionQueueFilters::parse(&BTreeMap::new());
    assert!(defaults.is_ok());
    let defaults = defaults.ok();
    assert_eq!(
        defaults.as_ref().map(RetentionQueueFilters::owner_payload),
        Some(json!({
            "requestType": [],
            "state": [],
            "dueBefore": null,
            "legalHoldBlocked": null,
            "cursor": null,
            "limit": 20,
            "sort": "DUE_ASC"
        }))
    );

    let parameters = BTreeMap::from([
        ("requestType".to_owned(), "ACCESS,DELETION".to_owned()),
        ("state".to_owned(), "RECEIVED,REVIEW".to_owned()),
        ("dueBefore".to_owned(), "2026-08-10T00:00:00Z".to_owned()),
        ("legalHoldBlocked".to_owned(), "true".to_owned()),
        ("limit".to_owned(), "50".to_owned()),
        ("sort".to_owned(), "CREATED_DESC".to_owned()),
    ]);
    let parsed = RetentionQueueFilters::parse(&parameters);
    assert!(parsed.is_ok());
    assert_eq!(
        parsed.ok().map(|filters| filters.applied_filters()),
        Some(json!({
            "requestType": ["ACCESS", "DELETION"],
            "state": ["RECEIVED", "REVIEW"],
            "dueBefore": "2026-08-10T00:00:00Z",
            "legalHoldBlocked": true,
            "sort": "CREATED_DESC"
        }))
    );
}

#[test]
fn queue_filters_reject_unknown_duplicate_or_unbounded_values() {
    for parameters in [
        BTreeMap::from([("requestType".to_owned(), ",ACCESS".to_owned())]),
        BTreeMap::from([("requestType".to_owned(), "ACCESS,ACCESS".to_owned())]),
        BTreeMap::from([("state".to_owned(), "UNKNOWN".to_owned())]),
        BTreeMap::from([("legalHoldBlocked".to_owned(), "1".to_owned())]),
        BTreeMap::from([("limit".to_owned(), "101".to_owned())]),
        BTreeMap::from([("sort".to_owned(), "UPDATED_DESC".to_owned())]),
        BTreeMap::from([("rawProof".to_owned(), "forbidden".to_owned())]),
    ] {
        assert!(matches!(
            RetentionQueueFilters::parse(&parameters),
            Err(ServiceError::InvalidRequest)
        ));
    }
}

#[test]
fn authority_unavailable_is_the_only_typed_privacy_reader_failure() {
    assert!(matches!(
        privacy_reader_error(Some("55000")),
        Some(ServiceError::DependencyUnavailable)
    ));
    assert!(privacy_reader_error(Some("P0002")).is_none());
    assert!(privacy_reader_error(Some("22023")).is_none());
    assert!(privacy_reader_error(None).is_none());
}

#[test]
fn queue_page_accepts_only_v2_summaries_and_exact_filter_echo() {
    let filters = json!({
        "requestType": [],
        "state": [],
        "dueBefore": null,
        "legalHoldBlocked": null,
        "sort": "DUE_ASC"
    });
    let value = page(pending_summary(ID));
    assert!(validation::validate_queue_page(&value, &filters, "DUE_ASC").is_ok());

    let mut legacy = value.clone();
    legacy["items"][0]["inventory_snapshot_digest"] = json!(SHA);
    assert!(matches!(
        validation::validate_queue_page(&legacy, &filters, "DUE_ASC"),
        Err(ServiceError::Persistence)
    ));

    let mut wrong_echo = value;
    wrong_echo["appliedFilters"]["sort"] = json!("CREATED_DESC");
    assert!(matches!(
        validation::validate_queue_page(&wrong_echo, &filters, "DUE_ASC"),
        Err(ServiceError::Persistence)
    ));
}

#[test]
fn workspace_keeps_pending_and_verified_authority_shapes_distinct() {
    assert!(validation::validate_workspace(&pending_workspace()).is_ok());
    assert!(validation::validate_workspace(&verified_workspace()).is_ok());

    let mut partial = verified_workspace();
    partial["calendarDigest"] = Value::Null;
    assert!(matches!(
        validation::validate_workspace(&partial),
        Err(ServiceError::Persistence)
    ));

    let mut raw = verified_workspace();
    raw["decisionReceipts"][0]["reason"] = json!("raw reason");
    assert!(matches!(
        validation::validate_workspace(&raw),
        Err(ServiceError::Persistence)
    ));
}

#[test]
fn workspace_rejects_branch_receipt_substitution_and_unsorted_authority_sets() {
    let mut substituted = verified_workspace();
    substituted["decisionReceipts"][0]["extensionReceiptId"] =
        json!("00000000-0000-4000-8000-000000000006");
    assert!(matches!(
        validation::validate_workspace(&substituted),
        Err(ServiceError::Persistence)
    ));

    let mut unsorted = verified_workspace();
    unsorted["activeHoldIds"] = json!([
        "00000000-0000-4000-8000-000000000009",
        "00000000-0000-4000-8000-000000000008"
    ]);
    assert!(matches!(
        validation::validate_workspace(&unsorted),
        Err(ServiceError::Persistence)
    ));
}

#[test]
fn workspace_accepts_only_the_exact_internal_party_name_access_projection() {
    let mut access = verified_workspace();
    access["accessProjection"] = response_access_projection();
    assert!(validation::validate_workspace(&access).is_ok());

    let mut stale_digest = access.clone();
    stale_digest["accessProjection"]["currentValueDigest"] = json!("f".repeat(64));
    assert!(matches!(
        validation::validate_workspace(&stale_digest),
        Err(ServiceError::Persistence)
    ));

    let mut leaked_server_field = access.clone();
    leaked_server_field["accessProjection"]["responseReceiptToken"] = json!("secret");
    assert!(matches!(
        validation::validate_workspace(&leaked_server_field),
        Err(ServiceError::Persistence)
    ));

    let mut public_summary_leak = access;
    public_summary_leak["request"]["partyName"] = json!("내부 projection 밖 누출");
    assert!(matches!(
        validation::validate_workspace(&public_summary_leak),
        Err(ServiceError::Persistence)
    ));
}

#[test]
fn workspace_rejects_structurally_valid_access_projection_binding_tampering() {
    let mut access = verified_workspace();
    access["accessProjection"] = response_access_projection();
    assert!(validation::validate_workspace(&access).is_ok());

    let mut changed_origin_receipt = access.clone();
    changed_origin_receipt["accessProjection"]["responseOriginReceiptId"] =
        json!("00000000-0000-4000-8000-000000000015");
    assert!(matches!(
        validation::validate_workspace(&changed_origin_receipt),
        Err(ServiceError::Persistence)
    ));

    let mut changed_source_request = access.clone();
    changed_source_request["accessProjection"]["sourceResponseRequestId"] =
        json!("00000000-0000-4000-8000-000000000016");
    assert!(matches!(
        validation::validate_workspace(&changed_source_request),
        Err(ServiceError::Persistence)
    ));

    let mut changed_response_version = access.clone();
    changed_response_version["accessProjection"]["responseVersion"] = json!(5);
    assert!(matches!(
        validation::validate_workspace(&changed_response_version),
        Err(ServiceError::Persistence)
    ));

    let mut changed_projection_digest = access;
    changed_projection_digest["accessProjection"]["projectionDigest"] = json!("5".repeat(64));
    assert!(matches!(
        validation::validate_workspace(&changed_projection_digest),
        Err(ServiceError::Persistence)
    ));
}

#[test]
fn completed_correction_requires_the_exact_completion_projection_binding() {
    let approved = approved_correction_workspace();
    assert!(validation::validate_workspace(&approved).is_ok());

    let mut completed = approved.clone();
    completed["request"]["state"] = json!("COMPLETED");
    completed["request"]["decisionVersion"] = json!(4);
    completed["completionReceiptId"] = json!("00000000-0000-4000-8000-000000000020");
    completed["completionReceiptDigest"] = json!("a".repeat(64));
    completed["completedResponseVersion"] = json!(4);
    completed["completedValueDigest"] = completed["accessProjection"]["currentValueDigest"].clone();
    assert!(validation::validate_workspace(&completed).is_ok());

    let mut missing = approved.clone();
    missing["request"]["state"] = json!("COMPLETED");
    missing["request"]["decisionVersion"] = json!(4);
    assert!(matches!(
        validation::validate_workspace(&missing),
        Err(ServiceError::Persistence)
    ));

    let mut partial = completed.clone();
    partial["completionReceiptDigest"] = Value::Null;
    assert!(matches!(
        validation::validate_workspace(&partial),
        Err(ServiceError::Persistence)
    ));

    let mut version_gap = completed.clone();
    version_gap["request"]["decisionVersion"] = json!(5);
    assert!(matches!(
        validation::validate_workspace(&version_gap),
        Err(ServiceError::Persistence)
    ));

    let mut stale_response = completed.clone();
    stale_response["completedResponseVersion"] = json!(5);
    assert!(matches!(
        validation::validate_workspace(&stale_response),
        Err(ServiceError::Persistence)
    ));

    let mut non_correction = verified_workspace();
    non_correction["request"]["state"] = json!("COMPLETED");
    non_correction["request"]["decisionVersion"] = json!(2);
    non_correction["accessProjection"] = response_access_projection();
    non_correction["completionReceiptId"] = json!("00000000-0000-4000-8000-000000000021");
    non_correction["completionReceiptDigest"] = json!("b".repeat(64));
    non_correction["completedResponseVersion"] = json!(4);
    non_correction["completedValueDigest"] =
        non_correction["accessProjection"]["currentValueDigest"].clone();
    assert!(matches!(
        validation::validate_workspace(&non_correction),
        Err(ServiceError::Persistence)
    ));

    let mut non_completed_gap = approved.clone();
    non_completed_gap["request"]["decisionVersion"] = json!(4);
    assert!(matches!(
        validation::validate_workspace(&non_completed_gap),
        Err(ServiceError::Persistence)
    ));

    let mut premature = completed;
    premature["request"]["state"] = json!("APPROVED");
    premature["request"]["decisionVersion"] = json!(3);
    assert!(matches!(
        validation::validate_workspace(&premature),
        Err(ServiceError::Persistence)
    ));
}
