use super::addendum_projection_contract::event_is_accepted as addendum_event_is_accepted;
use super::agency_projection::agency_id_from_payload;
use super::{Failure, sha256, verified_revision_payload};
use serde_json::json;
use uuid::Uuid;

#[test]
fn action_execution_authorization_is_accepted_by_audit_indexer() {
    assert!(addendum_event_is_accepted(
        "audit-indexer",
        "action.execution_authorized.v1"
    ));
    assert!(!addendum_event_is_accepted(
        "cost-projector",
        "action.execution_authorized.v1"
    ));
}

#[test]
fn response_submission_v2_is_accepted_only_as_the_audit_fact() {
    assert!(addendum_event_is_accepted(
        "audit-indexer",
        "response.submitted.v2"
    ));
    for consumer in ["cost-projector", "submission-projector"] {
        assert!(!addendum_event_is_accepted(
            consumer,
            "response.submitted.v2"
        ));
    }
    for retired_or_side_effect_event in [
        "response.submitted.v1",
        "notification.response_submitted.v2",
        "workflow.response_submitted.v2",
    ] {
        assert!(!addendum_event_is_accepted(
            "audit-indexer",
            retired_or_side_effect_event
        ));
    }
}

#[test]
fn response_materialized_v2_is_accepted_by_its_two_projection_consumers() {
    for consumer in ["submission-projector", "audit-indexer"] {
        assert!(addendum_event_is_accepted(
            consumer,
            "editorial.response_materialized.v2"
        ));
    }
    for consumer in ["cost-projector", "projection-worker"] {
        assert!(!addendum_event_is_accepted(
            consumer,
            "editorial.response_materialized.v2"
        ));
    }
    assert!(!addendum_event_is_accepted(
        "submission-projector",
        "editorial.response_materialized.v1"
    ));
}

#[test]
fn funding_disclosure_publication_has_distinct_public_and_audit_deliveries() {
    assert!(addendum_event_is_accepted(
        "audit-indexer",
        "governance.funding_disclosure_published.v1"
    ));
    for consumer in [
        "public-projection-worker",
        "projection-worker",
        "cost-projector",
        "submission-projector",
    ] {
        assert!(!addendum_event_is_accepted(
            consumer,
            "governance.funding_disclosure_published.v1"
        ));
    }
    assert!(!addendum_event_is_accepted(
        "audit-indexer",
        "governance.funding_disclosure_publish_requested.v1"
    ));
}

#[test]
fn verified_revision_payload_preserves_frozen_evidence_metadata() {
    let revision_id = Uuid::from_u128(1);
    let payload = json!({
        "caseId":"00000000-0000-4000-8000-000000000010",
        "evidence":[{
            "id":"00000000-0000-4000-8000-000000000011",
            "documentTitle":"공공 조달 계약 원문",
            "publisher":"가상 중앙조달원",
            "publishedAt":"2026-07-30T09:15:00Z",
            "sourceUrl":"https://example.test/contracts/2026-001",
            "pageAnchor":"page=7"
        }]
    });
    let digest = sha256(payload.to_string().as_bytes());

    assert_eq!(
        verified_revision_payload(payload.clone(), &digest, revision_id).ok(),
        Some(payload.clone())
    );
    assert!(matches!(
        verified_revision_payload(payload, &"0".repeat(64), revision_id),
        Err(Failure::Terminal("PUBLIC_PAYLOAD_DIGEST_MISMATCH", detail))
            if detail == revision_id.to_string()
    ));
}

#[test]
fn agency_projection_accepts_only_a_scalar_uuid_binding() {
    let agency_id = Uuid::from_u128(42);
    assert_eq!(
        agency_id_from_payload(&json!({"agencyId":agency_id})),
        Some(agency_id)
    );
    for payload in [
        json!({}),
        json!({"agencyId":null}),
        json!({"agencyId":"not-a-uuid"}),
        json!({"agencyId":[agency_id]}),
        json!({"agencyIds":[agency_id]}),
    ] {
        assert_eq!(agency_id_from_payload(&payload), None, "payload={payload}");
    }
}
