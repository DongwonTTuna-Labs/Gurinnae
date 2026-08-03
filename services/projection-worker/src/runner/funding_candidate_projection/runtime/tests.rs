use gurine_jobs::{fencing::Fence, postgres::ClaimedJob};
use serde_json::json;
use time::OffsetDateTime;
use uuid::Uuid;

use super::{
    DonationFundingCandidateReceipt, PROJECT_QUERY, classify_candidate_database_failure,
    redacted_result, validate_receipt,
};
use crate::runner::{Failure, funding_candidate_projection::DonationFactRecordedEvent};

fn event() -> Result<DonationFactRecordedEvent, Failure> {
    DonationFactRecordedEvent::parse(
        &json!({
            "consumerId":"funding-projector",
            "eventId":"00000000-0000-4000-8000-000000000011",
            "eventType":"donation.fact_recorded.v1",
            "aggregateType":"DonationFact",
            "aggregateId":"00000000-0000-4000-8000-000000000012",
            "aggregateVersion":3,
            "occurredAt":"2026-08-02T12:00:01Z",
            "payload":{
                "donationFactId":"00000000-0000-4000-8000-000000000013",
                "donationFactDigest":"1".repeat(64),
                "chargeAttemptId":"00000000-0000-4000-8000-000000000014",
                "chargeAttemptDigest":"2".repeat(64),
                "providerFetchDigest":"3".repeat(64),
                "occurredAt":"2026-08-02T12:00:00Z"
            }
        }),
        Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0011),
    )
}

fn claimed_job() -> ClaimedJob {
    ClaimedJob {
        id: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0021),
        job_type: "EVENT_DELIVERY".to_owned(),
        queue: "projection-worker".to_owned(),
        payload: json!({}),
        attempt: 1,
        max_attempts: 8,
        fence: Fence {
            lease_token: Uuid::from_u128(0x0000_0000_0000_4000_8000_0000_0000_0022),
            fencing_token: 5,
        },
        lease_expires_at: OffsetDateTime::UNIX_EPOCH,
    }
}

fn receipt(job: &ClaimedJob, event: &DonationFactRecordedEvent) -> DonationFundingCandidateReceipt {
    DonationFundingCandidateReceipt {
        job_id: job.id,
        job_fencing_token: job.fence.fencing_token,
        event_id: event.event_id,
        aggregate_root_fact_id: event.aggregate_id,
        aggregate_version: event.aggregate_version,
        donation_fact_id: event.donation_fact_id,
        donation_fact_digest: event.donation_fact_digest.clone(),
        candidate_header_digest: "4".repeat(64),
        candidate_entry_digest: "5".repeat(64),
        inbox_receipt_digest: "6".repeat(64),
        job_receipt_digest: "7".repeat(64),
        audit_event_digest: "8".repeat(64),
        receipt_digest: "9".repeat(64),
        completed_at: event.event_occurred_at,
    }
}

#[test]
fn exact_owner_receipt_is_accepted_and_redacted() {
    let event = event();
    assert!(event.is_ok(), "event fixture must parse");
    let Some(event) = event.ok() else {
        return;
    };
    let job = claimed_job();
    let receipt = receipt(&job, &event);
    assert!(validate_receipt(&job, &event, &receipt).is_ok());
    let result = redacted_result(&event, &receipt);
    assert_eq!(result.as_object().map(|object| object.len()), Some(7));
    for forbidden in [
        "jobId",
        "eventId",
        "aggregateRootFactId",
        "donationFactId",
        "jobFencingToken",
    ] {
        assert!(result.get(forbidden).is_none());
    }
}

#[test]
fn changed_claim_source_or_receipt_bindings_fail_before_commit() {
    let event = event();
    assert!(event.is_ok(), "event fixture must parse");
    let Some(event) = event.ok() else {
        return;
    };
    let job = claimed_job();
    let mut wrong_fence = receipt(&job, &event);
    wrong_fence.job_fencing_token += 1;
    let mut wrong_source = receipt(&job, &event);
    wrong_source.aggregate_version += 1;
    let mut malformed_digest = receipt(&job, &event);
    malformed_digest.audit_event_digest = "A".repeat(64);
    let mut early_completion = receipt(&job, &event);
    early_completion.completed_at = OffsetDateTime::UNIX_EPOCH;
    for candidate in [
        wrong_fence,
        wrong_source,
        malformed_digest,
        early_completion,
    ] {
        assert!(validate_receipt(&job, &event, &candidate).is_err());
    }
}

#[test]
fn owner_call_binds_job_worker_fence_and_event_authority_once() {
    for placeholder in [
        "$1::uuid",
        "$2::uuid",
        "$3::bigint",
        "$4::text",
        "$14::timestamptz",
    ] {
        assert_eq!(PROJECT_QUERY.matches(placeholder).count(), 1);
    }
    assert!(PROJECT_QUERY.contains("ops.donation_funding_candidate_projection_v1"));
}

#[test]
fn stale_or_out_of_order_candidate_is_retryable() {
    assert!(matches!(
        classify_candidate_database_failure(Some("40001")),
        Some(Failure::Retryable(
            "DONATION_FUNDING_CANDIDATE_RECONCILIATION_REQUIRED",
            _
        ))
    ));
    assert!(matches!(
        classify_candidate_database_failure(Some("23514")),
        Some(Failure::Terminal(
            "DONATION_FUNDING_CANDIDATE_BINDING_INVALID",
            _
        ))
    ));
}

#[test]
fn malformed_database_timestamp_is_terminal_input_rejection() {
    for sqlstate in ["22007", "22P02"] {
        assert!(matches!(
            classify_candidate_database_failure(Some(sqlstate)),
            Some(Failure::Terminal(
                "DONATION_FUNDING_CANDIDATE_INPUT_INVALID",
                _
            ))
        ));
    }
}
