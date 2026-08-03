mod retention_job_tests {
    use gurine_jobs::{fencing::Fence, postgres::ClaimedJob};
    use serde_json::{Value, json};
    use time::OffsetDateTime;
    use uuid::Uuid;

    use super::{
        Failure, INVALID_RETENTION_JOB, INVALID_RETENTION_RESULT, R6D_PERSON_RETENTION_OWNER_SQL,
        RETENTION_ERASURE_ACTOR_ID, RETENTION_ERASURE_ACTOR_TYPE, RETENTION_JOB_KEYS,
        RETENTION_RESULT_KEYS, WorkflowJobRoute, parse_r6d_person_retention_payload,
        parse_r6d_person_retention_result, retention_owner_database_failure, sha256,
        validate_claimed_retention_job, validate_r6d_person_retention_result, workflow_job_route,
    };

    const DIGEST_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const DIGEST_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const DB_CANONICAL_PAYLOAD_DIGEST: &str =
        "7a902e406a8c56f08e4b41bb77d2e2ee1266482971e2a16abe1196f830ba7381";

    #[test]
    fn dispatcher_is_closed_to_the_four_supported_job_types() {
        assert_eq!(
            workflow_job_route("EVENT_DELIVERY").ok(),
            Some(WorkflowJobRoute::EventDelivery)
        );
        assert_eq!(
            workflow_job_route("PRIVACY_RESPONSE_PARTY_NAME_CORRECTION").ok(),
            Some(WorkflowJobRoute::PrivacyResponsePartyNameCorrection)
        );
        assert_eq!(
            workflow_job_route("R6D_ENTITY_RETENTION").ok(),
            Some(WorkflowJobRoute::R6dEntityRetention)
        );
        assert_eq!(
            workflow_job_route("R6D_PERSON_RETENTION").ok(),
            Some(WorkflowJobRoute::R6dPersonRetention)
        );
        assert!(matches!(
            workflow_job_route("R6D_PERSON_DELETE"),
            Err(Failure::Terminal("UNSUPPORTED_JOB_TYPE", _))
        ));
        assert_eq!(
            R6D_PERSON_RETENTION_OWNER_SQL,
            "SELECT ops.execute_due_r6d_person_retention_job_v1($1,$2,$3)"
        );
        assert!(!R6D_PERSON_RETENTION_OWNER_SQL.contains("clock_timestamp"));

        let mut invalid_claim = claimed_retention_job();
        invalid_claim.fence.lease_token = Uuid::nil();
        assert!(matches!(
            validate_claimed_retention_job(&invalid_claim),
            Err(Failure::Terminal(INVALID_RETENTION_JOB, detail))
                if detail == "leaseToken"
        ));
    }

    #[test]
    fn payload_parser_requires_the_exact_closed_contract() {
        let payload = valid_payload();
        assert_eq!(payload.as_object().map(serde_json::Map::len), Some(19));
        assert_eq!(RETENTION_JOB_KEYS.len(), 19);
        assert!(parse_r6d_person_retention_payload(&payload).is_ok());
        assert_eq!(canonical_digest(&payload), DB_CANONICAL_PAYLOAD_DIGEST);

        let mutations = [
            ("scheduleRevision", json!(0)),
            ("activeDurationSeconds", json!(-1)),
            ("backupDurationSeconds", json!(1.5)),
            ("recordClass", json!("PERSON_CONTEXT")),
            ("holdBehavior", json!("DELETE_ON_RETENTION")),
            ("contextId", json!("not-a-uuid")),
            ("personNodeId", json!(Uuid::nil())),
            ("scheduleDigest", json!(DIGEST_A.to_uppercase())),
            ("dueAt", json!("not-a-timestamp")),
        ];
        for (field, replacement) in mutations {
            let mut invalid = payload.clone();
            invalid[field] = replacement;
            assert_invalid_payload(&invalid, field);
        }

        let mut extra = payload.clone();
        extra["unexpected"] = json!(true);
        assert_invalid_payload(&extra, "keys");
        let mut missing = payload;
        missing
            .as_object_mut()
            .and_then(|object| object.remove("requestId"));
        assert_invalid_payload(&missing, "keys");
    }

    #[test]
    fn result_parser_and_bindings_accept_only_the_owner_receipt() {
        let job = claimed_retention_job();
        let parsed_payload = parse_r6d_person_retention_payload(&job.payload);
        assert!(parsed_payload.is_ok());
        let Ok(payload) = parsed_payload else {
            return;
        };
        let payload_digest = canonical_digest(&job.payload);
        let result = valid_result(&job, &payload_digest);

        assert_eq!(result.as_object().map(serde_json::Map::len), Some(32));
        assert_eq!(RETENTION_RESULT_KEYS.len(), 32);
        assert!(parse_r6d_person_retention_result(&result).is_ok());
        assert!(
            validate_r6d_person_retention_result(&job, &payload, &payload_digest, &result).is_ok()
        );

        let binding_mutations = [
            ("jobId", json!(Uuid::from_u128(90))),
            ("jobFencingToken", json!(8)),
            ("jobLeaseTokenSha256", json!(DIGEST_B)),
            ("jobPayloadDigest", json!(DIGEST_B)),
            ("contextId", json!(Uuid::from_u128(91))),
            ("personNodeId", json!(Uuid::from_u128(92))),
            ("topologyDigest", json!(DIGEST_B)),
            ("contextStateDigest", json!(DIGEST_B)),
            ("scheduleId", json!(Uuid::from_u128(93))),
            ("scheduleRevision", json!(4)),
            ("scheduleDigest", json!(DIGEST_B)),
            ("triggerAt", json!("2026-07-31T00:00:00Z")),
            ("dueAt", json!("2027-08-02T00:00:00Z")),
            ("requestId", json!(Uuid::from_u128(94))),
            ("idempotencyKeySha256", json!(DIGEST_B)),
            ("requestDigest", json!(DIGEST_B)),
        ];
        for (field, replacement) in binding_mutations {
            let mut invalid = result.clone();
            invalid[field] = replacement;
            let outcome =
                validate_r6d_person_retention_result(&job, &payload, &payload_digest, &invalid);
            assert!(matches!(
                outcome,
                Err(Failure::Terminal("R6D_PERSON_RETENTION_BINDING_MISMATCH", detail))
                    if detail == field
            ));
        }
    }

    #[test]
    fn replay_keeps_the_immutable_prior_claim_but_revalidates_payload_bindings() {
        let job = claimed_retention_job();
        let parsed_payload = parse_r6d_person_retention_payload(&job.payload);
        assert!(parsed_payload.is_ok());
        let Ok(payload) = parsed_payload else {
            return;
        };
        let payload_digest = canonical_digest(&job.payload);
        let mut replay = valid_result(&job, &payload_digest);
        replay["jobFencingToken"] = json!(job.fence.fencing_token - 1);
        replay["jobLeaseTokenSha256"] = json!(DIGEST_B);
        replay["replayed"] = json!(true);
        replay["receiptDigest"] = json!(canonical_receipt_digest(&replay));

        assert!(
            validate_r6d_person_retention_result(&job, &payload, &payload_digest, &replay).is_ok()
        );

        replay["contextStateDigest"] = json!(DIGEST_B);
        replay["receiptDigest"] = json!(canonical_receipt_digest(&replay));
        assert!(matches!(
            validate_r6d_person_retention_result(&job, &payload, &payload_digest, &replay),
            Err(Failure::Terminal(
                "R6D_PERSON_RETENTION_BINDING_MISMATCH",
                detail
            )) if detail == "contextStateDigest"
        ));
    }

    #[test]
    fn result_shape_digest_and_database_details_fail_closed() {
        let job = claimed_retention_job();
        let parsed_payload = parse_r6d_person_retention_payload(&job.payload);
        assert!(parsed_payload.is_ok());
        let Ok(payload) = parsed_payload else {
            return;
        };
        let payload_digest = canonical_digest(&job.payload);
        let result = valid_result(&job, &payload_digest);

        let mut extra = result.clone();
        extra["unexpected"] = json!(true);
        assert_invalid_result(&extra, "keys");

        let mut malformed = result.clone();
        malformed["replayed"] = json!("false");
        assert_invalid_result(&malformed, "replayed");

        let mut human_actor = result.clone();
        human_actor["erasureActorType"] = json!("HUMAN");
        assert_invalid_result(&human_actor, "erasureActorType");

        let mut wrong_service = result.clone();
        wrong_service["erasureActorId"] = json!("workflow-worker");
        assert_invalid_result(&wrong_service, "erasureActorId");

        let mut bad_digest = result;
        bad_digest["receiptDigest"] = json!(DIGEST_B);
        assert!(matches!(
            validate_r6d_person_retention_result(
                &job,
                &payload,
                &payload_digest,
                &bad_digest,
            ),
            Err(Failure::Terminal(
                "R6D_PERSON_RETENTION_BINDING_MISMATCH",
                detail
            )) if detail == "receiptDigest"
        ));

        let secret = "database response contained private context";
        let failure =
            retention_owner_database_failure(sqlx::Error::Io(std::io::Error::other(secret)));
        assert!(matches!(
            failure,
            Failure::Retryable(
                "R6D_PERSON_RETENTION_OWNER_UNAVAILABLE",
                detail
            ) if detail == "redacted:database_error" && !detail.contains(secret)
        ));
    }

    fn valid_payload() -> Value {
        json!({
            "schemaVersion": "r6d-person-retention-job.v1",
            "contextId": Uuid::from_u128(1),
            "personNodeId": Uuid::from_u128(2),
            "topologyDigest": DIGEST_A,
            "recordClass": "RELATIONSHIP_PERSON_CONTEXT",
            "scheduleId": Uuid::from_u128(3),
            "scheduleRevision": 3,
            "scheduleDigest": DIGEST_A,
            "triggerKind": "CREATED_AT",
            "terminalAction": "ANONYMIZE",
            "holdBehavior": "BLOCK_ON_RETENTION_OR_DELETION",
            "activeDurationSeconds": 31_536_000,
            "backupDurationSeconds": 2_592_000,
            "triggerAt": "2026-08-01T00:00:00Z",
            "dueAt": "2027-08-01T00:00:00Z",
            "contextStateDigest": DIGEST_A,
            "requestId": Uuid::from_u128(4),
            "idempotencyKeySha256": DIGEST_A,
            "requestDigest": DIGEST_A,
        })
    }

    fn claimed_retention_job() -> ClaimedJob {
        ClaimedJob {
            id: Uuid::from_u128(10),
            job_type: "R6D_PERSON_RETENTION".to_owned(),
            queue: "workflow-worker".to_owned(),
            payload: valid_payload(),
            attempt: 1,
            max_attempts: 8,
            fence: Fence {
                lease_token: Uuid::from_u128(11),
                fencing_token: 7,
            },
            lease_expires_at: OffsetDateTime::UNIX_EPOCH,
        }
    }

    fn valid_result(job: &ClaimedJob, payload_digest: &str) -> Value {
        let lease_digest = sha256(job.fence.lease_token.to_string().as_bytes());
        let mut result = json!({
            "schemaVersion": "r6d-person-retention-execution.v1",
            "receiptId": Uuid::from_u128(20),
            "jobId": job.id,
            "jobFencingToken": job.fence.fencing_token,
            "jobLeaseTokenSha256": lease_digest,
            "jobPayloadDigest": payload_digest,
            "contextId": job.payload["contextId"],
            "personNodeId": job.payload["personNodeId"],
            "topologyDigest": job.payload["topologyDigest"],
            "personNameDigest": DIGEST_A,
            "contextStateDigest": job.payload["contextStateDigest"],
            "scheduleId": job.payload["scheduleId"],
            "scheduleRevision": job.payload["scheduleRevision"],
            "scheduleDigest": job.payload["scheduleDigest"],
            "triggerKind": job.payload["triggerKind"],
            "triggerAt": job.payload["triggerAt"],
            "dueAt": job.payload["dueAt"],
            "erasureReceiptId": Uuid::from_u128(21),
            "erasureReceiptDigest": DIGEST_A,
            "erasureAuditEventId": Uuid::from_u128(22),
            "erasureActorType": RETENTION_ERASURE_ACTOR_TYPE,
            "erasureActorId": RETENTION_ERASURE_ACTOR_ID,
            "requestId": job.payload["requestId"],
            "idempotencyKeySha256": job.payload["idempotencyKeySha256"],
            "requestDigest": job.payload["requestDigest"],
            "governanceRetentionScheduleId": Uuid::from_u128(23),
            "governanceRetentionRecordClass": "PERSON_ERASURE_GOVERNANCE",
            "governanceRetentionScheduleDigest": DIGEST_A,
            "auditEventId": Uuid::from_u128(24),
            "completedAt": "2027-08-01T00:00:01Z",
        });
        let receipt_digest = canonical_digest(&result);
        result["receiptDigest"] = json!(receipt_digest);
        result["replayed"] = json!(false);
        result
    }

    fn canonical_digest(value: &Value) -> String {
        match gurine_auth::assertion::canonical::canonical_json(value) {
            Ok(canonical) => sha256(&canonical),
            Err(_) => String::new(),
        }
    }

    fn canonical_receipt_digest(value: &Value) -> String {
        let mut receipt = value.clone();
        if let Some(object) = receipt.as_object_mut() {
            object.remove("receiptDigest");
            object.remove("replayed");
        }
        canonical_digest(&receipt)
    }

    fn assert_invalid_payload(value: &Value, field: &str) {
        assert!(matches!(
            parse_r6d_person_retention_payload(value),
            Err(Failure::Terminal(INVALID_RETENTION_JOB, detail)) if detail == field
        ));
    }

    fn assert_invalid_result(value: &Value, field: &str) {
        assert!(matches!(
            parse_r6d_person_retention_result(value),
            Err(Failure::Terminal(INVALID_RETENTION_RESULT, detail)) if detail == field
        ));
    }
}
