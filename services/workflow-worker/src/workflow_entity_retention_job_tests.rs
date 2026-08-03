mod entity_retention_job_tests {
    use gurine_jobs::{fencing::Fence, postgres::ClaimedJob};
    use serde_json::{Value, json};
    use time::OffsetDateTime;
    use uuid::Uuid;

    use super::{
        ENTITY_RETENTION_JOB_KEYS, ENTITY_RETENTION_RESULT_KEYS, Failure,
        INVALID_ENTITY_RETENTION_JOB, INVALID_ENTITY_RETENTION_RESULT,
        R6D_ENTITY_RETENTION_OWNER_SQL, R6dRetainedEntityKind,
        entity_retention_owner_database_failure, parse_r6d_entity_retention_payload,
        parse_r6d_entity_retention_result, validate_claimed_entity_retention_job,
        validate_r6d_entity_retention_result,
    };

    const DIGEST_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const DIGEST_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    #[test]
    fn owner_call_is_fenced_and_claim_validation_fails_closed() {
        assert_eq!(
            R6D_ENTITY_RETENTION_OWNER_SQL,
            "SELECT ops.execute_due_r6d_entity_retention_job_v1($1,$2,$3)"
        );
        assert!(!R6D_ENTITY_RETENTION_OWNER_SQL.contains("clock_timestamp"));

        let mut invalid_claim = claimed_entity_retention_job();
        invalid_claim.fence.lease_token = Uuid::nil();
        assert!(matches!(
            validate_claimed_entity_retention_job(&invalid_claim),
            Err(Failure::Terminal(INVALID_ENTITY_RETENTION_JOB, detail))
                if detail == "leaseToken"
        ));
    }

    #[test]
    fn payload_parser_accepts_only_the_exact_authority_bound_contract() {
        let payload = valid_payload();
        assert_eq!(payload.as_object().map(serde_json::Map::len), Some(15));
        assert_eq!(ENTITY_RETENTION_JOB_KEYS.len(), 15);
        let parsed = parse_r6d_entity_retention_payload(&payload);
        assert!(parsed.is_ok());
        let Ok(parsed) = parsed else {
            return;
        };
        assert_eq!(parsed.entity_kind, R6dRetainedEntityKind::Supplier);
        assert_eq!(parsed.entity_id, Uuid::from_u128(1));
        assert_eq!(parsed.closure_receipt_id, Uuid::from_u128(3));
        assert_eq!(parsed.closure_receipt_digest, DIGEST_A);

        let mut agency_payload = payload.clone();
        agency_payload["entityKind"] = json!("AGENCY");
        assert!(matches!(
            parse_r6d_entity_retention_payload(&agency_payload),
            Ok(parsed) if parsed.entity_kind == R6dRetainedEntityKind::Agency
        ));

        let mutations = [
            ("entityKind", json!("PERSON")),
            ("entityId", json!(Uuid::nil())),
            ("personhoodReceiptDigest", json!(DIGEST_A.to_uppercase())),
            ("closureReceiptId", json!("not-a-uuid")),
            ("scheduleRevision", json!(0)),
            ("dueAt", json!("not-a-timestamp")),
            ("idempotencyDigest", json!(DIGEST_A.to_uppercase())),
        ];
        for (field, replacement) in mutations {
            let mut invalid = payload.clone();
            invalid[field] = replacement;
            assert_invalid_payload(&invalid, field);
        }

        let mut reversed_timeline = payload.clone();
        reversed_timeline["queuedAt"] = json!("2031-07-31T23:59:59+09:00");
        assert_invalid_payload(&reversed_timeline, "retentionTimeline");

        let mut extra = payload.clone();
        extra["canonicalName"] = json!("must never enter the job envelope");
        assert_invalid_payload(&extra, "keys");
        let mut missing = payload;
        missing
            .as_object_mut()
            .and_then(|object| object.remove("personhoodReceiptId"));
        assert_invalid_payload(&missing, "keys");
    }

    #[test]
    fn result_parser_and_bindings_accept_only_the_exact_owner_receipt() {
        let job = claimed_entity_retention_job();
        let parsed_payload = parse_r6d_entity_retention_payload(&job.payload);
        assert!(parsed_payload.is_ok());
        let Ok(payload) = parsed_payload else {
            return;
        };
        let result = valid_result(&job);

        assert_eq!(result.as_object().map(serde_json::Map::len), Some(15));
        assert_eq!(ENTITY_RETENTION_RESULT_KEYS.len(), 15);
        assert!(parse_r6d_entity_retention_result(&result).is_ok());
        assert!(validate_r6d_entity_retention_result(&job, &payload, &result).is_ok());

        let binding_mutations = [
            ("jobId", json!(Uuid::from_u128(90))),
            ("entityKind", json!("AGENCY")),
            ("entityId", json!(Uuid::from_u128(91))),
            ("closureReceiptId", json!(Uuid::from_u128(92))),
            ("closureReceiptDigest", json!(DIGEST_B)),
            ("anonymizedAt", json!("2031-07-31T23:59:59+09:00")),
        ];
        for (field, replacement) in binding_mutations {
            let mut invalid = result.clone();
            invalid[field] = replacement;
            let outcome = validate_r6d_entity_retention_result(&job, &payload, &invalid);
            assert!(matches!(
                outcome,
                Err(Failure::Terminal(
                    "R6D_ENTITY_RETENTION_BINDING_MISMATCH",
                    detail
                )) if detail == field
            ));
        }
    }

    #[test]
    fn result_shape_counts_timeline_and_database_details_fail_closed() {
        let result = valid_result(&claimed_entity_retention_job());

        let mutations = [
            ("status", json!("RUNNING")),
            ("executionReceiptId", json!(Uuid::nil())),
            ("executionReceiptDigest", json!(DIGEST_A.to_uppercase())),
            ("masterRowCount", json!(0)),
            ("identifierRowCount", json!(-1)),
            ("aliasRowCount", json!(1.5)),
            ("backupDisposalDueAt", json!("2031-08-02T00:00:01+09:00")),
            ("replayed", json!("false")),
        ];
        for (field, replacement) in mutations {
            let mut invalid = result.clone();
            invalid[field] = replacement;
            assert_invalid_result(&invalid, field);
        }

        let mut extra = result;
        extra["plaintextName"] = json!("must never leave the owner boundary");
        assert_invalid_result(&extra, "keys");

        let secret = "database response contained an entity plaintext";
        let failure =
            entity_retention_owner_database_failure(sqlx::Error::Io(std::io::Error::other(secret)));
        assert!(matches!(
            failure,
            Failure::Retryable(
                "R6D_ENTITY_RETENTION_OWNER_UNAVAILABLE",
                detail
            ) if detail == "redacted:database_error" && !detail.contains(secret)
        ));
    }

    fn valid_payload() -> Value {
        json!({
            "schemaVersion": "r6d-entity-retention-job.v1",
            "entityKind": "SUPPLIER",
            "entityId": Uuid::from_u128(1),
            "personhoodReceiptId": Uuid::from_u128(2),
            "personhoodReceiptDigest": DIGEST_A,
            "closureReceiptId": Uuid::from_u128(3),
            "closureReceiptDigest": DIGEST_A,
            "closureAt": "2026-07-31T23:59:59+09:00",
            "scheduleId": Uuid::from_u128(4),
            "scheduleRevision": 7,
            "scheduleDigest": DIGEST_A,
            "dueAt": "2031-08-01T23:59:59+09:00",
            "requestDigest": DIGEST_A,
            "idempotencyDigest": DIGEST_A,
            "queuedAt": "2031-08-02T00:00:00+09:00",
        })
    }

    fn claimed_entity_retention_job() -> ClaimedJob {
        ClaimedJob {
            id: Uuid::from_u128(10),
            job_type: "R6D_ENTITY_RETENTION".to_owned(),
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

    fn valid_result(job: &ClaimedJob) -> Value {
        json!({
            "status": "COMPLETED",
            "jobId": job.id,
            "entityKind": job.payload["entityKind"],
            "entityId": job.payload["entityId"],
            "executionReceiptId": Uuid::from_u128(20),
            "executionReceiptDigest": DIGEST_A,
            "closureReceiptId": job.payload["closureReceiptId"],
            "closureReceiptDigest": job.payload["closureReceiptDigest"],
            "anonymizedAt": "2031-08-02T00:00:01+09:00",
            "masterRowCount": 1,
            "identifierRowCount": 2,
            "aliasRowCount": 3,
            "backupDisposalDueAt": "2032-08-02T00:00:01+09:00",
            "auditEventId": Uuid::from_u128(21),
            "replayed": false,
        })
    }

    fn assert_invalid_payload(value: &Value, field: &str) {
        assert!(matches!(
            parse_r6d_entity_retention_payload(value),
            Err(Failure::Terminal(INVALID_ENTITY_RETENTION_JOB, detail)) if detail == field
        ));
    }

    fn assert_invalid_result(value: &Value, field: &str) {
        assert!(matches!(
            parse_r6d_entity_retention_result(value),
            Err(Failure::Terminal(INVALID_ENTITY_RETENTION_RESULT, detail)) if detail == field
        ));
    }
}
