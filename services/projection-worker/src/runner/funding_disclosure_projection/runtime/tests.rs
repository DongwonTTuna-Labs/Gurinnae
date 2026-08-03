use std::time::Duration;

use gurine_jobs::{fencing::Fence, postgres::ClaimedJob};
use serde_json::{Value, json};
use sqlx::postgres::PgPoolOptions;
use time::OffsetDateTime;
use uuid::Uuid;

use super::{
    PROJECT_QUERY, ProjectionMutationReceipt, classify_projection_database_failure, handle,
    redacted_result, require_approved_digest_abi, validate_receipt,
};
use crate::runner::{Failure, funding_disclosure_projection::FundingDisclosurePublishedEvent};

fn event_envelope() -> Value {
    json!({
        "consumerId":"public-projection-worker",
        "eventId":"00000000-0000-4000-8000-000000000001",
        "eventType":"governance.funding_disclosure_published.v1",
        "aggregateType":"FundingDisclosureRevision",
        "aggregateId":"00000000-0000-4000-8000-000000000003",
        "aggregateVersion":2,
        "occurredAt":"2026-08-02T12:00:00Z",
        "payload":{
            "disclosureId":"00000000-0000-4000-8000-000000000002",
            "revisionId":"00000000-0000-4000-8000-000000000003",
            "revision":2,
            "revisionDigest":"1".repeat(64),
            "snapshotBatchId":"00000000-0000-4000-8000-000000000004",
            "snapshotDigest":"2".repeat(64),
            "concentrationBand":"UNKNOWN",
            "entrySetDigest":"3".repeat(64),
            "priorRevision":1,
            "effectiveAt":"2026-08-02T00:00:00Z",
            "receiptDigest":"4".repeat(64)
        }
    })
}

fn event_id() -> Uuid {
    Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0001)
}

fn event() -> Result<FundingDisclosurePublishedEvent, Failure> {
    FundingDisclosurePublishedEvent::parse(&event_envelope(), event_id())
}

fn claimed_job(payload: Value) -> ClaimedJob {
    ClaimedJob {
        id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0021),
        job_type: "EVENT_DELIVERY".to_owned(),
        queue: "projection-worker".to_owned(),
        payload,
        attempt: 1,
        max_attempts: 8,
        fence: Fence {
            lease_token: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0022),
            fencing_token: 5,
        },
        lease_expires_at: OffsetDateTime::UNIX_EPOCH,
    }
}

fn receipt(event: &FundingDisclosurePublishedEvent) -> ProjectionMutationReceipt {
    ProjectionMutationReceipt {
        operation_id: "ECONOMICS.PROJECT_FUNDING_DISCLOSURE.V2".to_owned(),
        event_id: event.event_id,
        source_aggregate_id: event.revision_id,
        source_aggregate_version: event.revision,
        source_aggregate_digest: event.revision_digest.clone(),
        projection_id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0011),
        projection_version: event.revision,
        projection_digest: "5".repeat(64),
        projected_row_count: 1,
        inbox_receipt_digest: "6".repeat(64),
        job_receipt_digest: "7".repeat(64),
        audit_event_id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0012),
        outbox_event_ids: Vec::new(),
        receipt_digest: "8".repeat(64),
        completed_at: event.occurred_at,
    }
}

#[test]
fn exact_owner_receipt_is_accepted_and_redacted() {
    let event = event();
    assert!(event.is_ok(), "event fixture must parse");
    let Some(event) = event.ok() else {
        return;
    };
    let receipt = receipt(&event);
    assert!(validate_receipt(&event, &receipt).is_ok());
    let result = redacted_result(&event, &receipt);
    assert_eq!(
        result.as_object().map(|object| object.len()),
        Some(7),
        "result must remain a closed metrics receipt"
    );
    for forbidden in [
        "sourceAggregateId",
        "projectionId",
        "auditEventId",
        "disclosureId",
        "revisionId",
    ] {
        assert!(result.get(forbidden).is_none());
    }
}

#[test]
fn changed_source_or_receipt_bindings_fail_before_commit() {
    let event = event();
    assert!(event.is_ok(), "event fixture must parse");
    let Some(event) = event.ok() else {
        return;
    };
    let mut wrong_source = receipt(&event);
    wrong_source.source_aggregate_version += 1;
    let mut repeated_effect = receipt(&event);
    repeated_effect
        .outbox_event_ids
        .push(Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0013));
    let mut malformed_digest = receipt(&event);
    malformed_digest.projection_digest = "A".repeat(64);
    let mut early_completion = receipt(&event);
    early_completion.completed_at = time::OffsetDateTime::UNIX_EPOCH;
    for candidate in [
        wrong_source,
        repeated_effect,
        malformed_digest,
        early_completion,
    ] {
        assert!(validate_receipt(&event, &candidate).is_err());
    }
}

#[test]
fn owner_call_binds_the_exact_claim_identity_and_fence() {
    assert!(PROJECT_QUERY.contains("$13::uuid,$14::uuid,$15::bigint"));
    assert_eq!(PROJECT_QUERY.matches("$13").count(), 1);
    assert_eq!(PROJECT_QUERY.matches("$14").count(), 1);
    assert_eq!(PROJECT_QUERY.matches("$15").count(), 1);
}

#[test]
fn stale_claim_is_retryable_but_never_reported_as_success() {
    let failure =
        classify_projection_database_failure(Some("40001"), "FUNDING_PROJECTION_STALE_FENCE");
    assert!(matches!(
        failure,
        Some(Failure::Retryable("FUNDING_PROJECTION_STALE_FENCE", _))
    ));
}

#[test]
fn unapproved_digest_abi_fails_closed_before_owner_io() {
    let failure = require_approved_digest_abi();
    assert!(matches!(
        failure,
        Err(Failure::Retryable(
            "FUNDING_PROJECTION_DIGEST_ABI_UNAVAILABLE",
            detail
        )) if detail == "redacted:funding-digest-abi-not-approved"
    ));
}

#[test]
fn database_digest_abi_unavailable_is_narrowly_retryable() {
    let unavailable = classify_projection_database_failure(
        Some("55000"),
        "FUNDING_PROJECTION_DIGEST_ABI_UNAVAILABLE",
    );
    let near_miss = classify_projection_database_failure(
        Some("55000"),
        "FUNDING_PROJECTION_DIGEST_ABI_UNAVAILABLE_CHANGED",
    );
    assert!(matches!(
        unavailable,
        Some(Failure::Retryable(
            "FUNDING_PROJECTION_DIGEST_ABI_UNAVAILABLE",
            _
        ))
    ));
    assert!(matches!(
        near_miss,
        Some(Failure::Terminal("FUNDING_PROJECTION_SOURCE_INVALID", _))
    ));
}

#[tokio::test]
async fn handle_validates_safe_fields_then_fails_before_database_io() {
    let pool = PgPoolOptions::new()
        .acquire_timeout(Duration::from_millis(20))
        .connect_lazy("postgres://gurine:unused@127.0.0.1:1/gurine");
    assert!(pool.is_ok(), "lazy test pool must be constructible");
    let Some(pool) = pool.ok() else {
        return;
    };

    let valid = handle(&pool, &claimed_job(event_envelope()), event_id()).await;
    assert!(matches!(
        valid,
        Err(Failure::Retryable(
            "FUNDING_PROJECTION_DIGEST_ABI_UNAVAILABLE",
            _
        ))
    ));

    let mut private_field = event_envelope();
    private_field["payload"]["donorId"] = json!("private");
    let invalid = handle(&pool, &claimed_job(private_field), event_id()).await;
    assert!(matches!(
        invalid,
        Err(Failure::Terminal("INVALID_FUNDING_DISCLOSURE_EVENT", _))
    ));
}
