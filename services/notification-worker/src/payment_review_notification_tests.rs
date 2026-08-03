mod payment_review_notification_tests {
    use super::*;

    fn event(payload: serde_json::Value) -> ClaimedEvent {
        ClaimedEvent {
            consumer_id: "notification-worker".to_owned(),
            id: Uuid::from_u128(0x42000000000040008000000000000001),
            event_type: PAYMENT_REVIEW_REQUESTED_EVENT_TYPE.to_owned(),
            aggregate_id: Uuid::from_u128(0x42000000000040008000000000000002),
            aggregate_version: 3,
            payload,
        }
    }

    fn payload() -> serde_json::Value {
        serde_json::json!({
            "reviewTaskId":"42000000-0000-4000-8000-000000000002",
            "reviewTaskVersion":3,
            "reviewTaskDigest":"a".repeat(64),
            "sourceKind":"DONATION_PAYMENT_FAILURE",
            "sourceReceiptId":"42000000-0000-4000-8000-000000000003",
            "sourceReceiptDigest":"b".repeat(64),
            "occurredAt":"1970-01-01T00:00:00Z",
        })
    }

    fn materialization_receipt(
        event: &ClaimedEvent,
        replay: bool,
    ) -> PaymentReviewMaterializationReceipt {
        PaymentReviewMaterializationReceipt {
            event_id: event.id,
            review_task_id: event.aggregate_id,
            review_task_version: event.aggregate_version,
            review_task_digest: "a".repeat(64),
            source_kind: PaymentReviewSourceKind::DonationPaymentFailure,
            source_receipt_id: Uuid::from_u128(0x42000000000040008000000000000003),
            source_receipt_digest: "b".repeat(64),
            occurred_at: time::OffsetDateTime::UNIX_EPOCH,
            intent_id: Uuid::from_u128(0x42000000000040008000000000000004),
            intent_digest: "c".repeat(64),
            prior_intent_version: if replay { 2 } else { 1 },
            intent_version: 2,
            intent_state: "MATERIALIZED".to_owned(),
            transition_receipt_digest: "d".repeat(64),
            audit_event_id: (!replay).then(|| Uuid::from_u128(0x42000000000040008000000000000005)),
            outbox_event_id: None,
            idempotency_replay: replay,
        }
    }

    fn assert_payment_review_receipt_rejected(
        event: &ClaimedEvent,
        requested: &PaymentReviewRequestedV1,
        receipt: &PaymentReviewMaterializationReceipt,
    ) {
        assert!(
            validate_payment_review_materialization_receipt(event, requested, receipt).is_err()
        );
    }

    #[test]
    fn payment_review_payload_accepts_only_the_exact_bound_shape() {
        let valid_event = event(payload());
        let parsed = parse_payment_review_requested_v1(&valid_event);
        assert!(parsed.is_ok());
        let Some(parsed) = parsed.ok() else {
            return;
        };

        assert_eq!(parsed.review_task_id, valid_event.aggregate_id);
        assert_eq!(parsed.review_task_version, valid_event.aggregate_version);
        assert_eq!(
            parsed.source_kind,
            PaymentReviewSourceKind::DonationPaymentFailure
        );
        assert_eq!(parsed.source_kind.as_str(), "DONATION_PAYMENT_FAILURE");

        let mut wrong_id = valid_event.payload.clone();
        wrong_id["reviewTaskId"] = serde_json::json!(Uuid::new_v4());
        assert!(parse_payment_review_requested_v1(&event(wrong_id)).is_err());

        let mut wrong_version = valid_event.payload;
        wrong_version["reviewTaskVersion"] = serde_json::json!(4);
        assert!(parse_payment_review_requested_v1(&event(wrong_version)).is_err());

        let mut wrong_consumer = event(payload());
        wrong_consumer.consumer_id = "audit-indexer".to_owned();
        assert!(parse_payment_review_requested_v1(&wrong_consumer).is_err());
    }

    #[test]
    fn payment_review_payload_accepts_only_closed_source_kinds() {
        let mut signed_collection = payload();
        signed_collection["sourceKind"] = serde_json::json!("SIGNED_COLLECTION_FAILURE");
        let parsed = parse_payment_review_requested_v1(&event(signed_collection));
        assert!(parsed.is_ok());
        let Some(parsed) = parsed.ok() else {
            return;
        };
        assert_eq!(
            parsed.source_kind,
            PaymentReviewSourceKind::SignedCollectionFailure
        );

        for invalid in [
            "DONATION_FAILURE",
            "COLLECTION_FAILURE",
            "donation_payment_failure",
            "",
        ] {
            let mut invalid_source = payload();
            invalid_source["sourceKind"] = serde_json::json!(invalid);
            assert!(parse_payment_review_requested_v1(&event(invalid_source)).is_err());
        }
    }

    #[test]
    fn payment_review_payload_rejects_sensitive_or_payment_detail_fields() {
        for forbidden in [
            "customer",
            "donor",
            "invoice",
            "payment",
            "provider",
            "body",
            "signature",
            "amount",
        ] {
            let mut with_forbidden = payload();
            with_forbidden[forbidden] = serde_json::json!("must-not-cross-event-boundary");
            assert!(
                parse_payment_review_requested_v1(&event(with_forbidden)).is_err(),
                "forbidden field must be rejected: {forbidden}"
            );
        }

        for (forbidden_alias, canonical_field) in [
            ("taskId", "reviewTaskId"),
            ("taskVersion", "reviewTaskVersion"),
            ("taskDigest", "reviewTaskDigest"),
        ] {
            let mut with_alias = payload();
            with_alias[forbidden_alias] = with_alias
                .get(canonical_field)
                .cloned()
                .unwrap_or(serde_json::Value::Null);
            assert!(
                parse_payment_review_requested_v1(&event(with_alias)).is_err(),
                "legacy task alias must be rejected: {forbidden_alias}"
            );
        }
    }

    #[test]
    fn payment_review_payload_rejects_noncanonical_digests_and_time() {
        for (field, value) in [
            ("reviewTaskDigest", "A".repeat(64)),
            ("reviewTaskDigest", "a".repeat(63)),
            ("sourceReceiptDigest", "g".repeat(64)),
            ("sourceReceiptDigest", "0x".to_owned() + &"b".repeat(64)),
        ] {
            let mut invalid = payload();
            invalid[field] = serde_json::json!(value);
            assert!(parse_payment_review_requested_v1(&event(invalid)).is_err());
        }

        let mut invalid_time = payload();
        invalid_time["occurredAt"] = serde_json::json!("2026-08-02");
        assert!(parse_payment_review_requested_v1(&event(invalid_time)).is_err());

        let mut nil_source_receipt = payload();
        nil_source_receipt["sourceReceiptId"] = serde_json::json!(Uuid::nil());
        assert!(parse_payment_review_requested_v1(&event(nil_source_receipt)).is_err());

        for (field, value) in [
            (
                "sourceReceiptId",
                "42000000-0000-4000-8000-00000000000A".to_owned(),
            ),
            (
                "sourceReceiptId",
                "42000000000040008000000000000003".to_owned(),
            ),
            (
                "sourceReceiptId",
                "42000000-0000-7000-8000-000000000003".to_owned(),
            ),
            (
                "sourceReceiptId",
                "42000000-0000-4000-7000-000000000003".to_owned(),
            ),
        ] {
            let mut noncanonical = payload();
            noncanonical[field] = serde_json::json!(value);
            assert!(
                parse_payment_review_requested_v1(&event(noncanonical)).is_err(),
                "noncanonical UUID must be rejected: {field}={value}"
            );
        }
    }

    #[test]
    fn payment_review_materialization_receipt_requires_exact_fresh_or_replay_binding() {
        let event = event(payload());
        let requested = parse_payment_review_requested_v1(&event);
        assert!(requested.is_ok());
        let Some(requested) = requested.ok() else {
            return;
        };

        for replay in [false, true] {
            let receipt = materialization_receipt(&event, replay);
            assert!(
                validate_payment_review_materialization_receipt(&event, &requested, &receipt)
                    .is_ok()
            );
        }

        let mut stale_task = materialization_receipt(&event, false);
        stale_task.review_task_version += 1;
        assert_payment_review_receipt_rejected(&event, &requested, &stale_task);

        let mut mismatched_source = materialization_receipt(&event, false);
        mismatched_source.source_receipt_digest = "e".repeat(64);
        assert_payment_review_receipt_rejected(&event, &requested, &mismatched_source);

        let mut invalid_replay = materialization_receipt(&event, true);
        invalid_replay.audit_event_id = Some(Uuid::new_v4());
        assert_payment_review_receipt_rejected(&event, &requested, &invalid_replay);

        let mut replay_with_outbox = materialization_receipt(&event, true);
        replay_with_outbox.outbox_event_id = Some(Uuid::new_v4());
        assert_payment_review_receipt_rejected(&event, &requested, &replay_with_outbox);

        let mut invalid_fresh = materialization_receipt(&event, false);
        invalid_fresh.outbox_event_id = Some(Uuid::new_v4());
        assert_payment_review_receipt_rejected(&event, &requested, &invalid_fresh);

        let mut fresh_without_audit = materialization_receipt(&event, false);
        fresh_without_audit.audit_event_id = None;
        assert_payment_review_receipt_rejected(&event, &requested, &fresh_without_audit);

        let mut overflowing_fresh = materialization_receipt(&event, false);
        overflowing_fresh.prior_intent_version = i64::MAX;
        overflowing_fresh.intent_version = i64::MAX;
        assert_payment_review_receipt_rejected(&event, &requested, &overflowing_fresh);

        let mut invalid_intent_id = materialization_receipt(&event, false);
        invalid_intent_id.intent_id =
            Uuid::from_u128(0x42000000000070008000000000000004);
        assert_payment_review_receipt_rejected(&event, &requested, &invalid_intent_id);
    }

    #[test]
    fn payment_review_corrupt_authority_sqlstates_are_not_retried() {
        for code in [
            "22003", "22007", "22008", "22023", "22P02", "23502", "23503", "23505", "23514",
            "42501", "55000", "P0002",
        ] {
            assert!(
                payment_review_sqlstate_is_contract(code),
                "contract SQLSTATE must fail without retry: {code}"
            );
        }
        for code in ["08006", "40001", "40P01", "53300"] {
            assert!(
                !payment_review_sqlstate_is_contract(code),
                "transient SQLSTATE must remain retryable: {code}"
            );
        }
    }
}
