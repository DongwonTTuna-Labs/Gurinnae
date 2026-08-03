mod response_party_name_correction_delegation_tests {
    use serde_json::{Map, Value, json};
    use uuid::Uuid;

    use super::{
        Failure, INVALID_PARTY_NAME_CORRECTION_DELEGATION, PARTY_NAME_CORRECTION_DELEGATION_KEYS,
        PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DELEGATION_SQL,
        is_party_name_correction_delegation_event, parse_party_name_correction_delegation,
        party_name_correction_delegation_input, party_name_correction_delegation_sqlstate_failure,
        validate_party_name_correction_delegation,
    };

    const DIGEST_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    #[test]
    fn only_the_existing_approved_retention_event_uses_delegated_ack() {
        assert!(is_party_name_correction_delegation_event(
            "retention-worker",
            "privacy.request_decision_recorded.v1"
        ));
        assert!(!is_party_name_correction_delegation_event(
            "workflow-worker",
            "privacy.request_decision_recorded.v1"
        ));
        assert!(!is_party_name_correction_delegation_event(
            "retention-worker",
            "privacy.response_party_name_correction_approved.v1"
        ));
        assert_eq!(
            PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DELEGATION_SQL,
            "SELECT ops.ack_privacy_response_party_name_correction_delegation_v1($1,$2,$3,$4,$5,$6,$7)"
        );
        assert!(!PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DELEGATION_SQL.contains("clock_timestamp"));
    }

    #[test]
    fn input_preserves_the_existing_event_contract_and_requires_positive_version() {
        let privacy_request_id = Uuid::from_u128(1);
        let payload = valid_event_payload(privacy_request_id);
        let input = party_name_correction_delegation_input(privacy_request_id, &payload);
        assert_eq!(input.ok(), Some((4, DIGEST_A)));

        let mut wrong_aggregate = payload.clone();
        wrong_aggregate.insert("retentionRequestId".to_owned(), json!(Uuid::from_u128(2)));
        assert!(matches!(
            party_name_correction_delegation_input(privacy_request_id, &wrong_aggregate),
            Err(Failure::Terminal("RETENTION_EVENT_AGGREGATE_MISMATCH", _))
        ));
        let mut zero_version = payload;
        zero_version.insert("decisionVersion".to_owned(), json!(0));
        assert!(matches!(
            party_name_correction_delegation_input(privacy_request_id, &zero_version),
            Err(Failure::Terminal(INVALID_PARTY_NAME_CORRECTION_DELEGATION, detail))
                if detail == "decisionVersion"
        ));
    }

    #[test]
    fn acknowledgement_result_is_closed_bound_and_digest_only() {
        let event_id = Uuid::from_u128(3);
        let privacy_request_id = Uuid::from_u128(1);
        let result = valid_delegation(event_id, privacy_request_id);
        assert_eq!(result.as_object().map(|value| value.len()), Some(8));
        assert_eq!(PARTY_NAME_CORRECTION_DELEGATION_KEYS.len(), 8);
        assert!(parse_party_name_correction_delegation(&result).is_ok());
        assert!(
            validate_party_name_correction_delegation(
                &result,
                event_id,
                privacy_request_id,
                4,
                DIGEST_A,
            )
            .is_ok()
        );
        assert!(!result.to_string().contains("partyName"));

        let mut mismatch = result.clone();
        mismatch["transitionReceiptDigest"] =
            json!("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        assert!(matches!(
            validate_party_name_correction_delegation(
                &mismatch,
                event_id,
                privacy_request_id,
                4,
                DIGEST_A,
            ),
            Err(Failure::Terminal(
                "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DELEGATION_BINDING_MISMATCH",
                detail
            )) if detail == "transitionReceiptDigest"
        ));
        let mut leaked = result;
        leaked["partyName"] = json!("비밀 평문");
        assert!(matches!(
            parse_party_name_correction_delegation(&leaked),
            Err(Failure::Terminal(INVALID_PARTY_NAME_CORRECTION_DELEGATION, detail))
                if detail == "keys"
        ));
    }

    #[test]
    fn missing_delegation_keeps_the_legacy_retry_contract() {
        let privacy_request_id = Uuid::from_u128(1);
        let invalid =
            party_name_correction_delegation_sqlstate_failure(Some("22023"), privacy_request_id);
        assert!(matches!(
            invalid,
            Failure::Terminal(
                "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DELEGATION_REJECTED",
                detail
            ) if detail == "redacted:sqlstate=22023"
        ));
        let binding_invalid =
            party_name_correction_delegation_sqlstate_failure(Some("23514"), privacy_request_id);
        assert!(matches!(
            binding_invalid,
            Failure::Terminal(
                "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DELEGATION_BINDING_INVALID",
                detail
            ) if detail == "redacted:sqlstate=23514"
        ));
        for sqlstate in [Some("55000"), Some("40001"), None] {
            let failure =
                party_name_correction_delegation_sqlstate_failure(sqlstate, privacy_request_id);
            assert!(matches!(
                failure,
                Failure::Retryable("RETENTION_OWNER_ROUTINE_UNAVAILABLE", detail)
                    if detail == format!(
                        "handle_privacy_request_decision_recorded_v1:{privacy_request_id}"
                    )
            ));
        }
    }

    fn valid_event_payload(privacy_request_id: Uuid) -> Map<String, Value> {
        let value = json!({
            "retentionRequestId":privacy_request_id,
            "decisionVersion":4,
            "transition":"APPROVE",
            "priorState":"REVIEW",
            "state":"APPROVED",
            "inventorySnapshotDigest":DIGEST_A,
            "holdCoverageDigest":DIGEST_A,
            "decisionDigest":DIGEST_A,
            "receiptDigest":DIGEST_A
        });
        match value.as_object() {
            Some(object) => object.clone(),
            None => Map::new(),
        }
    }

    fn valid_delegation(event_id: Uuid, privacy_request_id: Uuid) -> Value {
        json!({
            "schemaVersion":"privacy-response-party-name-correction-delegation.v1",
            "eventId":event_id,
            "privacyRequestId":privacy_request_id,
            "decisionVersion":4,
            "transitionReceiptDigest":DIGEST_A,
            "jobId":Uuid::from_u128(4),
            "jobPayloadDigest":DIGEST_A,
            "delegated":true
        })
    }
}
