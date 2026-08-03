use super::*;

fn funding_digest(byte: char) -> String {
    std::iter::repeat_n(byte, 64).collect()
}

fn funding_authorization_payload(execution_id: Uuid, generation: i64) -> Value {
    json!({
        "executionId":execution_id,
        "generation":generation,
        "actionKind":FUNDING_DISCLOSURE_ACTION_KIND,
        "decisionDigest":funding_digest('a'),
        "executionDigest":funding_digest('b'),
        "targetCommand":FUNDING_DISCLOSURE_TARGET_COMMAND,
        "targetRequestSha256":funding_digest('c'),
        "expiresAt":"2027-01-01T00:00:00Z",
    })
}

fn funding_execution() -> ApprovedExecution {
    let execution_id = Uuid::from_u128(1);
    ApprovedExecution {
        execution_id,
        generation: 1,
        event_payload: funding_authorization_payload(execution_id, 1),
        kind: ApprovedExecutionKind::FundingDisclosure,
    }
}

fn producer_job() -> ProducerJobFence {
    ProducerJobFence {
        id: Uuid::from_u128(2),
        lease_token: Uuid::from_u128(3),
        fencing_token: 4,
        lease_expires_at: time::OffsetDateTime::from_unix_timestamp(1_800_000_000)
            .unwrap_or(time::OffsetDateTime::UNIX_EPOCH),
    }
}

#[test]
fn funding_authorization_is_closed_and_digest_bound() -> Result<(), Failure> {
    let execution = funding_execution();
    let parsed = funding_disclosure_authorization_event(Uuid::from_u128(4), &execution)?;
    assert_eq!(parsed.source_event_id, Uuid::from_u128(4));
    assert_eq!(parsed.execution_id, execution.execution_id);
    assert_eq!(parsed.generation, 1);
    assert_eq!(parsed.decision_digest, funding_digest('a'));
    assert_eq!(parsed.execution_digest, funding_digest('b'));
    assert_eq!(parsed.target_request_sha256, funding_digest('c'));
    assert!(parsed.expires_at > time::OffsetDateTime::UNIX_EPOCH);

    let mut additional = funding_execution();
    additional.event_payload["callerDerivedQuorum"] = json!(true);
    assert!(funding_disclosure_authorization_event(Uuid::from_u128(4), &additional).is_err());

    for field in ["decisionDigest", "executionDigest", "targetRequestSha256"] {
        let mut invalid = funding_execution();
        invalid.event_payload[field] = json!("not-a-digest");
        assert!(funding_disclosure_authorization_event(Uuid::from_u128(4), &invalid).is_err());
    }
    Ok(())
}

#[test]
fn funding_dispatch_requires_exact_action_and_private_command() -> Result<(), Failure> {
    let execution_id = Uuid::from_u128(1);
    let payload = funding_authorization_payload(execution_id, 1);
    let parsed = approved_execution(
        payload
            .as_object()
            .ok_or_else(|| invalid_funding_disclosure_execution("test payload"))?,
        execution_id,
    )?;
    assert_eq!(parsed.kind, ApprovedExecutionKind::FundingDisclosure);

    for (action_kind, target_command) in [
        (FUNDING_DISCLOSURE_ACTION_KIND, "publishCase"),
        ("PUBLICATION", FUNDING_DISCLOSURE_TARGET_COMMAND),
    ] {
        let mut invalid = funding_authorization_payload(execution_id, 1);
        invalid["actionKind"] = json!(action_kind);
        invalid["targetCommand"] = json!(target_command);
        assert!(
            approved_execution(
                invalid
                    .as_object()
                    .ok_or_else(|| invalid_funding_disclosure_execution("test payload"))?,
                execution_id,
            )
            .is_err()
        );
    }
    Ok(())
}

#[test]
fn funding_producer_fence_rejects_missing_identity_or_fence() {
    let valid = producer_job();
    assert!(validate_funding_disclosure_producer_fence(valid).is_ok());
    for invalid in [
        ProducerJobFence {
            id: Uuid::nil(),
            ..valid
        },
        ProducerJobFence {
            lease_token: Uuid::nil(),
            ..valid
        },
        ProducerJobFence {
            fencing_token: 0,
            ..valid
        },
        ProducerJobFence {
            lease_expires_at: time::OffsetDateTime::UNIX_EPOCH,
            ..valid
        },
    ] {
        assert!(validate_funding_disclosure_producer_fence(invalid).is_err());
    }
}

#[tokio::test]
async fn funding_execution_has_no_owner_call_without_final_abi() {
    let result = execute_approved_funding_disclosure(
        Uuid::from_u128(4),
        producer_job(),
        &funding_execution(),
    )
    .await;
    assert!(matches!(
        result,
        Err(Failure::Retryable(
            "FUNDING_DISCLOSURE_OWNER_ABI_UNAVAILABLE",
            detail
        )) if detail == "redacted:owner-abi-not-final"
    ));
}
