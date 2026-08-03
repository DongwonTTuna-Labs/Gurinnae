mod retention_response_tests {
    use super::*;

    fn owner(receipt: Value, event_count: usize) -> (Value, Value) {
        let audit_event_id = "00000000-0000-4000-8000-000000000010";
        let aggregate_id = receipt["retentionRequestId"].clone();
        let aggregate_version = receipt["decisionVersion"].clone();
        let receipt_digest = receipt["transitionReceiptDigest"].clone();
        let event_ids = (0..event_count)
            .map(|index| json!(format!("00000000-0000-4000-8000-{:012}", 20 + index)))
            .collect::<Vec<_>>();
        (
            json!({
                "transition": receipt,
                "auditEventId": audit_event_id,
                "outboxEventIds": event_ids
            }),
            json!({
                "status":"COMPLETED",
                "aggregateId": aggregate_id,
                "aggregateVersion": aggregate_version,
                "receiptDigest": receipt_digest,
                "acceptedAt": "2026-08-01T00:00:01Z",
                "auditEventId": audit_event_id,
                "emittedEventIds": event_ids
            }),
        )
    }

    fn base(transition: &str, state: &str) -> Value {
        json!({
            "retentionRequestId": "00000000-0000-4000-8000-000000000001",
            "decisionVersion": 2,
            "requestType": "ACCESS",
            "state": state,
            "transition": transition,
            "transitionReceiptId": "00000000-0000-4000-8000-000000000002",
            "transitionReceiptDigest": "a".repeat(64),
            "identityVerifiedAt": "2026-08-01T00:00:00Z",
            "dueAt": "2026-08-18T00:00:00Z",
            "policyVersion": "supervisor-decision-v1",
            "policyDigest": "b".repeat(64),
            "calendarVersionId": "00000000-0000-4000-8000-000000000003",
            "calendarDigest": "c".repeat(64),
            "identityReceiptId": null,
            "identityReceiptDigest": null,
            "extensionReceiptId": null,
            "extensionReceiptDigest": null,
            "refusalReceiptId": null,
            "refusalReceiptDigest": null,
            "noticeReceiptId": null,
            "noticeReceiptDigest": null,
            "appealInstructionsDigest": null,
            "updatedAt": "2026-08-01T00:00:01Z",
            "replayed": false
        })
    }

    fn finalized_replay_response(
        receipt: Value,
        event_count: usize,
    ) -> Result<Value, ServiceError> {
        let (data, mut command) = owner(receipt, event_count);
        command["operationId"] = json!("transitionRetentionRequest");
        command["requestId"] = json!("00000000-0000-4000-8000-000000000006");
        command["idempotencyReplay"] = json!(false);
        command["links"] = json!([]);
        retention_command_response(&data, command)
    }

    #[test]
    fn identity_verification_requires_its_exact_receipt_pair_and_notice() {
        let mut receipt = base("VERIFY_IDENTITY", "RECEIVED");
        receipt["identityReceiptId"] = json!("00000000-0000-4000-8000-000000000004");
        receipt["identityReceiptDigest"] = json!("d".repeat(64));
        receipt["noticeReceiptId"] = json!("00000000-0000-4000-8000-000000000005");
        receipt["noticeReceiptDigest"] = json!("e".repeat(64));
        let (data, command) = owner(receipt.clone(), 1);
        assert!(retention_command_response(&data, command).is_ok());

        receipt["noticeReceiptId"] = Value::Null;
        receipt["noticeReceiptDigest"] = Value::Null;
        let (data, command) = owner(receipt, 1);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));

        let mut missing_nullable = base("VERIFY_IDENTITY", "RECEIVED");
        missing_nullable["identityReceiptId"] = json!("00000000-0000-4000-8000-000000000004");
        missing_nullable["identityReceiptDigest"] = json!("d".repeat(64));
        missing_nullable["noticeReceiptId"] = json!("00000000-0000-4000-8000-000000000005");
        missing_nullable["noticeReceiptDigest"] = json!("e".repeat(64));
        let _ = missing_nullable
            .as_object_mut()
            .and_then(|receipt| receipt.remove("appealInstructionsDigest"));
        let (data, command) = owner(missing_nullable, 1);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn finalized_transition_replay_validates_the_nested_command_shape() -> Result<(), ServiceError>
    {
        let mut receipt = base("VERIFY_IDENTITY", "RECEIVED");
        receipt["identityReceiptId"] = json!("00000000-0000-4000-8000-000000000004");
        receipt["identityReceiptDigest"] = json!("d".repeat(64));
        receipt["noticeReceiptId"] = json!("00000000-0000-4000-8000-000000000005");
        receipt["noticeReceiptDigest"] = json!("e".repeat(64));
        let response = finalized_replay_response(receipt, 1)?;
        assert!(validate_retention_replay_response(&response).is_ok());

        let mut expanded = response.clone();
        expanded["rawIdentityProof"] = json!("must not survive replay");
        assert!(matches!(
            validate_retention_replay_response(&expanded),
            Err(ServiceError::IdempotencyConflict)
        ));

        let mut missing_nullable = response.clone();
        let _ = missing_nullable
            .as_object_mut()
            .and_then(|receipt| receipt.remove("appealInstructionsDigest"));
        assert!(matches!(
            validate_retention_replay_response(&missing_nullable),
            Err(ServiceError::IdempotencyConflict)
        ));

        let mut changed_command = response;
        changed_command["command"]["idempotencyReplay"] = json!(true);
        assert!(matches!(
            validate_retention_replay_response(&changed_command),
            Err(ServiceError::IdempotencyConflict)
        ));
        Ok(())
    }

    #[test]
    fn finalized_replay_accepts_every_physically_available_transition_shape()
    -> Result<(), ServiceError> {
        let start_review = base("START_REVIEW", "REVIEW");

        let mut approve = base("APPROVE", "APPROVED");
        approve["requestType"] = json!("CORRECTION");

        let mut extend = base("EXTEND", "REVIEW");
        extend["extensionReceiptId"] = json!("00000000-0000-4000-8000-000000000004");
        extend["extensionReceiptDigest"] = json!("d".repeat(64));
        extend["noticeReceiptId"] = json!("00000000-0000-4000-8000-000000000005");
        extend["noticeReceiptDigest"] = json!("e".repeat(64));

        let mut reject = base("REJECT", "REJECTED");
        reject["refusalReceiptId"] = json!("00000000-0000-4000-8000-000000000004");
        reject["refusalReceiptDigest"] = json!("d".repeat(64));
        reject["noticeReceiptId"] = json!("00000000-0000-4000-8000-000000000005");
        reject["noticeReceiptDigest"] = json!("e".repeat(64));
        reject["appealInstructionsDigest"] = json!("f".repeat(64));

        for (receipt, event_count) in [(start_review, 1), (approve, 1), (extend, 1), (reject, 2)] {
            let response = finalized_replay_response(receipt, event_count)?;
            assert!(validate_retention_replay_response(&response).is_ok());
        }
        Ok(())
    }

    #[test]
    fn approve_is_closed_to_correction_requests_and_has_no_branch_receipts() {
        let mut correction = base("APPROVE", "APPROVED");
        correction["requestType"] = json!("CORRECTION");
        let (data, command) = owner(correction.clone(), 1);
        assert!(retention_command_response(&data, command).is_ok());

        correction["noticeReceiptId"] = json!("00000000-0000-4000-8000-000000000004");
        correction["noticeReceiptDigest"] = json!("d".repeat(64));
        let (data, command) = owner(correction, 1);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));

        let (data, command) = owner(base("APPROVE", "APPROVED"), 1);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn refusal_receipt_rejects_missing_appeal_digest_and_raw_text() {
        let mut receipt = base("REJECT", "REJECTED");
        receipt["refusalReceiptId"] = json!("00000000-0000-4000-8000-000000000004");
        receipt["refusalReceiptDigest"] = json!("d".repeat(64));
        receipt["noticeReceiptId"] = json!("00000000-0000-4000-8000-000000000005");
        receipt["noticeReceiptDigest"] = json!("e".repeat(64));
        let (data, command) = owner(receipt.clone(), 2);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));

        receipt["appealInstructionsDigest"] = json!("f".repeat(64));
        let (data, command) = owner(receipt.clone(), 2);
        assert!(retention_command_response(&data, command).is_ok());

        receipt["appealInstructions"] = json!("raw text must not cross this boundary");
        let (data, command) = owner(receipt, 2);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn transition_receipts_keep_closed_branch_cardinality() {
        let (data, command) = owner(base("START_REVIEW", "REVIEW"), 1);
        assert!(retention_command_response(&data, command).is_ok());

        let mut extension = base("EXTEND", "REVIEW");
        extension["extensionReceiptId"] = json!("00000000-0000-4000-8000-000000000004");
        extension["extensionReceiptDigest"] = json!("d".repeat(64));
        extension["noticeReceiptId"] = json!("00000000-0000-4000-8000-000000000005");
        extension["noticeReceiptDigest"] = json!("e".repeat(64));
        let (data, command) = owner(extension.clone(), 1);
        assert!(retention_command_response(&data, command).is_ok());

        extension["identityReceiptId"] = json!("00000000-0000-4000-8000-000000000006");
        extension["identityReceiptDigest"] = json!("f".repeat(64));
        let (data, command) = owner(extension, 1);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn transition_receipts_fail_closed_on_clock_or_digest_drift() {
        let mut receipt = base("START_REVIEW", "REVIEW");
        receipt["dueAt"] = Value::Null;
        let (data, command) = owner(receipt, 1);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));

        let mut receipt = base("START_REVIEW", "REVIEW");
        receipt["transitionReceiptDigest"] = json!("not-a-digest");
        let (data, command) = owner(receipt, 1);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));

        let mut receipt = base("START_REVIEW", "REVIEW");
        receipt["replayed"] = json!(true);
        let (data, command) = owner(receipt, 1);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn approved_policy_versions_are_not_hard_coded_to_the_declared_seed() {
        let mut receipt = base("START_REVIEW", "REVIEW");
        receipt["policyVersion"] = json!("counsel-approved-v2");
        let (data, command) = owner(receipt, 1);
        assert!(retention_command_response(&data, command).is_ok());

        for invalid in [
            String::new(),
            "Counsel-v2".to_owned(),
            "counsel/v2".to_owned(),
            "a".repeat(101),
        ] {
            let mut receipt = base("START_REVIEW", "REVIEW");
            receipt["policyVersion"] = json!(invalid);
            let (data, command) = owner(receipt, 1);
            assert!(matches!(
                retention_command_response(&data, command),
                Err(ServiceError::Persistence)
            ));
        }
    }

    #[test]
    fn owner_event_set_must_match_command_and_transition_cardinality() {
        let receipt = base("START_REVIEW", "REVIEW");
        let (data, mut command) = owner(receipt, 1);
        command["emittedEventIds"] = json!([]);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));

        let mut refusal = base("REJECT", "REJECTED");
        refusal["refusalReceiptId"] = json!("00000000-0000-4000-8000-000000000004");
        refusal["refusalReceiptDigest"] = json!("d".repeat(64));
        refusal["noticeReceiptId"] = json!("00000000-0000-4000-8000-000000000005");
        refusal["noticeReceiptDigest"] = json!("e".repeat(64));
        refusal["appealInstructionsDigest"] = json!("f".repeat(64));
        let (data, command) = owner(refusal, 1);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));

        let mut refusal = base("REJECT", "REJECTED");
        refusal["refusalReceiptId"] = json!("00000000-0000-4000-8000-000000000004");
        refusal["refusalReceiptDigest"] = json!("d".repeat(64));
        refusal["noticeReceiptId"] = json!("00000000-0000-4000-8000-000000000005");
        refusal["noticeReceiptDigest"] = json!("e".repeat(64));
        refusal["appealInstructionsDigest"] = json!("f".repeat(64));
        let (mut data, mut command) = owner(refusal, 2);
        data["outboxEventIds"] = json!([
            "00000000-0000-4000-8000-000000000021",
            "00000000-0000-4000-8000-000000000020"
        ]);
        command["emittedEventIds"] = data["outboxEventIds"].clone();
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn command_envelope_must_bind_the_exact_transition_receipt() {
        let receipt = base("START_REVIEW", "REVIEW");
        let (data, mut command) = owner(receipt.clone(), 1);
        command["aggregateId"] = json!("00000000-0000-4000-8000-000000000099");
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));

        let (data, mut command) = owner(receipt.clone(), 1);
        command["aggregateVersion"] = json!(3);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));

        let (data, mut command) = owner(receipt, 1);
        command["receiptDigest"] = json!("f".repeat(64));
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));

        let (data, mut command) = owner(base("START_REVIEW", "REVIEW"), 1);
        command["acceptedAt"] = json!("2026-08-01T00:00:02Z");
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));
    }

    #[test]
    fn v2_transition_receipt_rejects_legacy_completion_fields() {
        let mut receipt = base("START_REVIEW", "REVIEW");
        receipt["inventorySnapshotDigest"] = json!("d".repeat(64));
        receipt["holdCoverageDigest"] = json!("e".repeat(64));
        receipt["completionReceiptId"] = json!("00000000-0000-4000-8000-000000000006");
        receipt["locationReceipts"] = json!([]);
        let (data, command) = owner(receipt, 1);
        assert!(matches!(
            retention_command_response(&data, command),
            Err(ServiceError::Persistence)
        ));
    }
}
