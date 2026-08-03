mod response_party_name_correction_job_tests {
    use base64::Engine as _;
    use gurine_auth::envelope::{EnvelopeKey, EnvelopeKeyRing, encrypt};
    use gurine_jobs::{fencing::Fence, postgres::ClaimedJob};
    use serde_json::{Value, json};
    use time::OffsetDateTime;
    use uuid::Uuid;

    use super::{
        Failure, INVALID_PARTY_NAME_CORRECTION_COMPLETION, INVALID_PARTY_NAME_CORRECTION_JOB,
        INVALID_PARTY_NAME_CORRECTION_LOAD, PARTY_NAME_CORRECTION_COMPLETION_KEYS,
        PARTY_NAME_CORRECTION_JOB_KEYS, PARTY_NAME_CORRECTION_LOAD_KEYS,
        PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_APPLY_SQL,
        PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_LOAD_SQL, WorkflowJobRoute,
        decrypt_requested_party_name, parse_loaded_party_name_correction,
        parse_party_name_correction_completion, parse_party_name_correction_payload,
        party_name_correction_owner_database_failure, party_name_correction_owner_sqlstate_failure,
        sha256, validate_claimed_party_name_correction_job, validate_loaded_party_name_correction,
        validate_party_name_correction_completion, workflow_job_route,
    };

    const PARTY_NAME: &str = "정정된 당사자 표시명";
    const DIGEST_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const DIGEST_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    struct Fixture {
        job: ClaimedJob,
        load: Value,
        keys: EnvelopeKeyRing,
    }

    struct EncryptedPartyNameFixture {
        key: EnvelopeKey,
        ciphertext_base64: String,
        requested_value_sha256: String,
        requested_value_aad_digest: String,
        requested_value_ciphertext_digest: String,
        encryption_key_id: String,
    }

    #[test]
    fn dispatcher_and_owner_sql_are_exact_and_fenced() {
        assert_eq!(
            workflow_job_route("PRIVACY_RESPONSE_PARTY_NAME_CORRECTION").ok(),
            Some(WorkflowJobRoute::PrivacyResponsePartyNameCorrection)
        );
        assert!(matches!(
            workflow_job_route("R6D_RESPONSE_PARTY_NAME_CORRECTION"),
            Err(Failure::Terminal("UNSUPPORTED_JOB_TYPE", _))
        ));
        assert_eq!(
            PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_LOAD_SQL,
            "SELECT ops.load_privacy_response_party_name_correction_job_v1($1,$2,$3)"
        );
        assert_eq!(
            PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_APPLY_SQL,
            "SELECT ops.execute_privacy_response_party_name_correction_job_v1($1,$2,$3,$4,$5)"
        );
        assert!(!PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_LOAD_SQL.contains("clock_timestamp"));
        assert!(!PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_APPLY_SQL.contains("clock_timestamp"));

        let fixture = fixture();
        assert!(fixture.is_some());
        let Some(mut fixture) = fixture else {
            return;
        };
        assert!(validate_claimed_party_name_correction_job(&fixture.job).is_ok());
        fixture.job.fence.lease_token = Uuid::nil();
        assert!(matches!(
            validate_claimed_party_name_correction_job(&fixture.job),
            Err(Failure::Terminal(INVALID_PARTY_NAME_CORRECTION_JOB, detail))
                if detail == "claimFence"
        ));
    }

    #[test]
    fn payload_and_loader_accept_only_the_closed_bound_contract() {
        let fixture = fixture();
        assert!(fixture.is_some());
        let Some(fixture) = fixture else {
            return;
        };
        assert_eq!(
            fixture.job.payload.as_object().map(|value| value.len()),
            Some(24)
        );
        assert_eq!(PARTY_NAME_CORRECTION_JOB_KEYS.len(), 24);
        assert_eq!(fixture.load.as_object().map(|value| value.len()), Some(16));
        assert_eq!(PARTY_NAME_CORRECTION_LOAD_KEYS.len(), 16);

        let payload = parse_party_name_correction_payload(&fixture.job.payload);
        let loaded = parse_loaded_party_name_correction(&fixture.load);
        assert!(payload.is_ok());
        assert!(loaded.is_ok());
        let (Ok(payload), Ok(loaded)) = (payload, loaded) else {
            return;
        };
        let payload_digest = canonical_digest(&fixture.job.payload);
        assert!(
            validate_loaded_party_name_correction(
                &fixture.job,
                &payload,
                &payload_digest,
                &loaded,
            )
            .is_ok()
        );

        let mut extra = fixture.job.payload.clone();
        extra["requestedValue"] = json!(PARTY_NAME);
        assert_contract_failure(
            parse_party_name_correction_payload(&extra).map(|_| ()),
            INVALID_PARTY_NAME_CORRECTION_JOB,
            "keys",
        );
        let mut invalid_load = fixture.load.clone();
        invalid_load["expectedCurrentValueDigest"] = json!(DIGEST_B);
        let parsed = parse_loaded_party_name_correction(&invalid_load);
        assert!(parsed.is_ok());
        let Ok(parsed) = parsed else {
            return;
        };
        assert!(matches!(
            validate_loaded_party_name_correction(
                &fixture.job,
                &payload,
                &payload_digest,
                &parsed,
            ),
            Err(Failure::Terminal(
                "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_BINDING_MISMATCH",
                detail
            )) if detail == "expectedCurrentValueDigest"
        ));
    }

    #[test]
    fn envelope_decryption_is_plan_bound_and_failure_is_plaintext_free() {
        let fixture = fixture();
        assert!(fixture.is_some());
        let Some(fixture) = fixture else {
            return;
        };
        let loaded = parse_loaded_party_name_correction(&fixture.load);
        assert!(loaded.is_ok());
        let Ok(loaded) = loaded else {
            return;
        };
        let plaintext = decrypt_requested_party_name(&fixture.keys, &loaded);
        assert!(plaintext.is_ok());
        let Ok(plaintext) = plaintext else {
            return;
        };
        assert_eq!(plaintext.text().ok(), Some(PARTY_NAME));
        drop(plaintext);

        let mut wrong_aad = fixture.load.clone();
        wrong_aad["requestedValueAadDigest"] = json!(DIGEST_B);
        let loaded = parse_loaded_party_name_correction(&wrong_aad);
        assert!(loaded.is_ok());
        let Ok(loaded) = loaded else {
            return;
        };
        let failure = decrypt_requested_party_name(&fixture.keys, &loaded);
        assert!(matches!(
            &failure,
            Err(Failure::Terminal(
                "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DECRYPTION_FAILED",
                detail
            )) if detail == "aadDigest"
        ));
        let rendered = match &failure {
            Err(error) => format!("{error:?}"),
            Ok(_) => String::new(),
        };
        assert!(!rendered.contains(PARTY_NAME));
    }

    #[test]
    fn envelope_decryption_accepts_the_previous_key_during_rotation() {
        let fixture = fixture();
        assert!(fixture.is_some());
        let Some(mut fixture) = fixture else {
            return;
        };
        fixture.keys = EnvelopeKeyRing {
            current: EnvelopeKey::new([8_u8; 32]),
            previous: Some(EnvelopeKey::new([7_u8; 32])),
        };
        let loaded = parse_loaded_party_name_correction(&fixture.load);
        assert!(loaded.is_ok());
        let Ok(loaded) = loaded else {
            return;
        };
        let plaintext = decrypt_requested_party_name(&fixture.keys, &loaded);
        assert!(plaintext.is_ok());
        let Ok(plaintext) = plaintext else {
            return;
        };
        assert_eq!(plaintext.text().ok(), Some(PARTY_NAME));
    }

    #[test]
    fn completion_is_exact_redacted_and_replay_safe() {
        let fixture = fixture();
        assert!(fixture.is_some());
        let Some(fixture) = fixture else {
            return;
        };
        let payload = parse_party_name_correction_payload(&fixture.job.payload);
        assert!(payload.is_ok());
        let Ok(payload) = payload else {
            return;
        };
        let completion = valid_completion(&fixture.job, false);
        assert_eq!(completion.as_object().map(|value| value.len()), Some(14));
        assert_eq!(PARTY_NAME_CORRECTION_COMPLETION_KEYS.len(), 14);
        assert!(parse_party_name_correction_completion(&completion).is_ok());
        assert!(
            validate_party_name_correction_completion(&fixture.job, &payload, &completion).is_ok()
        );
        assert!(!completion.to_string().contains(PARTY_NAME));

        let replay = valid_completion(&fixture.job, true);
        assert!(validate_party_name_correction_completion(&fixture.job, &payload, &replay).is_ok());
        let mut wrong_version = replay.clone();
        wrong_version["responseVersion"] = json!(9);
        assert!(matches!(
            validate_party_name_correction_completion(&fixture.job, &payload, &wrong_version),
            Err(Failure::Terminal(
                "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_BINDING_MISMATCH",
                detail
            )) if detail == "responseVersion"
        ));
        let mut extra = replay.clone();
        extra["partyName"] = json!(PARTY_NAME);
        assert_contract_failure(
            parse_party_name_correction_completion(&extra).map(|_| ()),
            INVALID_PARTY_NAME_CORRECTION_COMPLETION,
            "keys",
        );
        let mut no_outbox = replay;
        no_outbox["outboxEventIds"] = json!([]);
        assert_contract_failure(
            parse_party_name_correction_completion(&no_outbox).map(|_| ()),
            INVALID_PARTY_NAME_CORRECTION_COMPLETION,
            "outboxEventIds",
        );
    }

    #[test]
    fn owner_error_policy_is_retry_compatible_and_always_redacted() {
        let cases = [
            (Some("22023"), false, "sqlstate=22023"),
            (Some("0A000"), false, "sqlstate=0A000"),
            (Some("40001"), true, "sqlstate=40001"),
            (Some("55000"), true, "sqlstate=55000"),
            (Some("PVT09"), true, "sqlstate=PVT09"),
            (None, true, "database_error"),
        ];
        for (sqlstate, retryable, detail) in cases {
            let failure = party_name_correction_owner_sqlstate_failure(sqlstate);
            assert_eq!(matches!(failure, Failure::Retryable(_, _)), retryable);
            let rendered = format!("{failure:?}");
            assert!(rendered.contains(detail));
            assert!(!rendered.contains(PARTY_NAME));
        }
        let secret = format!("database included {PARTY_NAME}");
        let failure = party_name_correction_owner_database_failure(sqlx::Error::Io(
            std::io::Error::other(secret),
        ));
        assert!(!format!("{failure:?}").contains(PARTY_NAME));
    }

    fn fixture() -> Option<Fixture> {
        let plan_id = Uuid::from_u128(3);
        let encrypted = encrypted_party_name_fixture(plan_id)?;
        let payload = party_name_correction_job_payload(plan_id, &encrypted);
        let job = party_name_correction_claimed_job(payload);
        let load = party_name_correction_load(&job, &encrypted.ciphertext_base64);
        Some(Fixture {
            job,
            load,
            keys: EnvelopeKeyRing {
                current: encrypted.key,
                previous: None,
            },
        })
    }

    fn encrypted_party_name_fixture(plan_id: Uuid) -> Option<EncryptedPartyNameFixture> {
        let plan_id_text = plan_id.to_string();
        let aad_parts = [
            "ops.privacy_correction_plans_v1",
            "requested_value_ciphertext",
            plan_id_text.as_str(),
            "privacy-correction-requested-value",
            "1",
        ];
        let key = EnvelopeKey::new([7_u8; 32]);
        let token = encrypt("gurine-fe-v1", &key, &aad_parts, PARTY_NAME.as_bytes()).ok()?;
        let encryption_key_id = token.split('.').nth(1)?.to_owned();
        let ciphertext_base64 = base64::engine::general_purpose::STANDARD.encode(token.as_bytes());
        let requested_value_sha256 = sha256(PARTY_NAME.as_bytes());
        let requested_value_aad_digest = sha256(aad_parts.join("\0").as_bytes());
        let requested_value_ciphertext_digest = sha256(token.as_bytes());
        Some(EncryptedPartyNameFixture {
            key,
            ciphertext_base64,
            requested_value_sha256,
            requested_value_aad_digest,
            requested_value_ciphertext_digest,
            encryption_key_id,
        })
    }

    fn party_name_correction_job_payload(
        plan_id: Uuid,
        encrypted: &EncryptedPartyNameFixture,
    ) -> Value {
        json!({
            "schemaVersion":"privacy-response-party-name-correction-job.v1",
            "privacyRequestId":Uuid::from_u128(1),
            "requestDecisionVersion":4,
            "correctionPlanId":plan_id,
            "planVersion":2,
            "planDigest":DIGEST_A,
            "responseId":Uuid::from_u128(4),
            "expectedResponseVersion":7,
            "expectedCurrentValueDigest":DIGEST_A,
            "accessProjectionDigest":DIGEST_A,
            "privacyIdentityProofReceiptId":Uuid::from_u128(5),
            "privacyIdentityProofReceiptDigest":DIGEST_A,
            "responseSubmissionReceiptId":Uuid::from_u128(6),
            "responseSubmissionReceiptDigest":DIGEST_A,
            "responseOriginReceiptId":Uuid::from_u128(7),
            "responseOriginReceiptDigest":DIGEST_A,
            "approvalTransitionReceiptId":Uuid::from_u128(8),
            "approvalTransitionReceiptDigest":DIGEST_A,
            "requestedValueSha256":encrypted.requested_value_sha256,
            "requestedValueAadDigest":encrypted.requested_value_aad_digest,
            "requestedValueCiphertextDigest":encrypted.requested_value_ciphertext_digest,
            "encryptionKeyId":encrypted.encryption_key_id,
            "holdCoverageDigest":DIGEST_A,
            "queuedAt":"2026-08-02T00:00:00Z"
        })
    }

    fn party_name_correction_claimed_job(payload: Value) -> ClaimedJob {
        ClaimedJob {
            id: Uuid::from_u128(2),
            job_type: "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION".to_owned(),
            queue: "workflow-worker".to_owned(),
            payload,
            attempt: 1,
            max_attempts: 8,
            fence: Fence {
                lease_token: Uuid::from_u128(9),
                fencing_token: 3,
            },
            lease_expires_at: OffsetDateTime::UNIX_EPOCH,
        }
    }

    fn party_name_correction_load(job: &ClaimedJob, ciphertext_base64: &str) -> Value {
        json!({
            "schemaVersion":"privacy-response-party-name-correction-job-load.v1",
            "jobId":job.id,
            "correctionPlanId":job.payload["correctionPlanId"],
            "privacyRequestId":job.payload["privacyRequestId"],
            "responseId":job.payload["responseId"],
            "expectedResponseVersion":job.payload["expectedResponseVersion"],
            "expectedCurrentValueDigest":job.payload["expectedCurrentValueDigest"],
            "requestedValueCiphertextBase64":ciphertext_base64,
            "requestedValueSha256":job.payload["requestedValueSha256"],
            "requestedValueAadDigest":job.payload["requestedValueAadDigest"],
            "requestedValueCiphertextDigest":job.payload["requestedValueCiphertextDigest"],
            "encryptionKeyId":job.payload["encryptionKeyId"],
            "planDigest":job.payload["planDigest"],
            "approvalTransitionReceiptId":job.payload["approvalTransitionReceiptId"],
            "approvalTransitionReceiptDigest":job.payload["approvalTransitionReceiptDigest"],
            "jobPayloadDigest":canonical_digest(&job.payload)
        })
    }

    fn valid_completion(job: &ClaimedJob, replayed: bool) -> Value {
        json!({
            "schemaVersion":"privacy-response-party-name-correction-completion.v1",
            "status":"COMPLETED",
            "jobId":job.id,
            "privacyRequestId":job.payload["privacyRequestId"],
            "correctionPlanId":job.payload["correctionPlanId"],
            "responseId":job.payload["responseId"],
            "responseVersion":8,
            "partyNameDigest":job.payload["requestedValueSha256"],
            "completionReceiptId":Uuid::from_u128(10),
            "completionReceiptDigest":DIGEST_A,
            "auditEventId":Uuid::from_u128(11),
            "outboxEventIds":[Uuid::from_u128(12)],
            "completedAt":"2026-08-02T00:00:01Z",
            "replayed":replayed
        })
    }

    fn canonical_digest(value: &Value) -> String {
        match gurine_auth::assertion::canonical::canonical_json(value) {
            Ok(canonical) => sha256(&canonical),
            Err(_) => String::new(),
        }
    }

    fn assert_contract_failure(result: Result<(), Failure>, code: &'static str, field: &str) {
        assert!(matches!(
            result,
            Err(Failure::Terminal(actual, detail)) if actual == code && detail == field
        ));
    }

    #[test]
    fn malformed_loader_shape_uses_the_loader_code() {
        let fixture = fixture();
        assert!(fixture.is_some());
        let Some(fixture) = fixture else {
            return;
        };
        let mut load = fixture.load;
        load["requestedValueCiphertextBase64"] = json!("");
        assert_contract_failure(
            parse_loaded_party_name_correction(&load).map(|_| ()),
            INVALID_PARTY_NAME_CORRECTION_LOAD,
            "requestedValueCiphertextBase64",
        );
    }
}
