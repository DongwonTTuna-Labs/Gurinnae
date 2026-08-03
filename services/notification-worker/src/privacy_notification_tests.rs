#[cfg(test)]
mod privacy_notification_tests {
    use base64::Engine as _;
    use gurine_auth::envelope::{EnvelopeKey, EnvelopeKeyRing, encrypt};
    use serde_json::{Value, json};
    use uuid::Uuid;

    use super::{
        ClaimedEvent, PrivacyDeliveryDisposition, WorkerError, decrypt_bound_text,
        is_privacy_notification_event, privacy_delivery_channel, privacy_delivery_disposition,
        privacy_sealed_field_kind, render_identity_verification_required,
        validate_privacy_notification,
    };

    const CREATED_EVENT: &str = "privacy.request_created.v2";
    const IDENTITY_EVENT: &str = "privacy.request_identity_verified.v1";
    const EXTENSION_EVENT: &str = "privacy.request_extension_notified.v1";
    const REFUSAL_EVENT: &str = "privacy.request_refusal_notified.v1";

    fn digest(byte: char) -> String {
        byte.to_string().repeat(64)
    }

    fn uuid(number: u128) -> Uuid {
        Uuid::from_u128(0x00000000000040008000000000000000 + number)
    }

    fn claimed_event(event_type: &str, version: i64, payload: Value) -> ClaimedEvent {
        ClaimedEvent {
            consumer_id: "notification-worker".to_owned(),
            id: uuid(1),
            event_type: event_type.to_owned(),
            aggregate_id: uuid(2),
            aggregate_version: version,
            payload,
        }
    }

    fn reason_fields() -> Value {
        json!({
            "reasonCiphertextBase64":"Z3VyaW5lLWZlLXYxLmtpZC5ub25jZS5jaXBoZXI=",
            "reasonSha256":digest('a'),
            "reasonEncryptionKeyId":"kid",
            "reasonAadDigest":digest('b'),
        })
    }

    fn binding_base(
        event: &ClaimedEvent,
        notice_type: &str,
        request_type: &str,
        state: &str,
        branch_or_notice_receipt_digest: &str,
        template: Value,
    ) -> Value {
        json!({
            "schemaVersion":"privacy-request-notification-delivery.v1",
            "noticeType":notice_type,
            "event":{
                "eventId":event.id,
                "eventType":event.event_type,
                "aggregateId":event.aggregate_id,
                "aggregateVersion":event.aggregate_version,
                "eventEnvelopeDigest":digest('1'),
                "occurredAt":"2026-08-01T01:00:00Z",
                "payload":event.payload,
            },
            "request":{
                "retentionRequestId":event.aggregate_id,
                "decisionVersion":event.aggregate_version,
                "requestType":request_type,
                "state":state,
                "identityState":"VERIFIED",
                "identityVerifiedAt":"2026-08-01T00:00:00Z",
                "dueAt":event.payload.get("dueAt").cloned()
                    .unwrap_or_else(|| json!("2026-08-10T00:00:00Z")),
            },
            "transition":{
                "transitionReceiptId":uuid(3),
                "transitionReceiptDigest":digest('2'),
                "eventReceiptId":event.id,
                "eventReceiptDigest":digest('1'),
                "branchReceiptDigest":branch_or_notice_receipt_digest,
                "noticeReceiptId":uuid(5),
                "noticeReceiptDigest":branch_or_notice_receipt_digest,
            },
            "endpoint":{
                "endpointId":uuid(6),
                "channel":"SMTP_EMAIL",
                "state":"ACTIVE",
                "version":1,
                "endpointDigest":digest('4'),
                "endpointCiphertextBase64":"Z3VyaW5lLWZlLXYxLmtpZC5ub25jZS5jaXBoZXI=",
                "encryptionKeyId":"kid",
                "endpointAadDigest":digest('5'),
                "updatedAt":"2026-07-31T01:00:00Z",
            },
            "template":template,
        })
    }

    fn identity_fixture() -> (ClaimedEvent, Value) {
        let receipt_digest = digest('6');
        let payload = json!({
            "retentionRequestId":uuid(2),
            "requestType":"ACCESS",
            "priorIdentityState":"PENDING_VERIFICATION",
            "identityState":"VERIFIED",
            "identityProofReceiptDigest":digest('7'),
            "identityVerifiedAt":"2026-08-01T00:00:00Z",
            "responsePolicyVersion":"supervisor-decision-v1",
            "responsePolicyDigest":digest('8'),
            "calendarVersionId":uuid(7),
            "calendarDigest":digest('9'),
            "dueAt":"2026-08-15T00:00:00Z",
            "verificationReceiptDigest":receipt_digest,
        });
        let event = claimed_event(IDENTITY_EVENT, 1, payload);
        let mut template = reason_fields();
        template["kind"] = json!("IDENTITY_VERIFIED");
        template["dueAt"] = json!("2026-08-15T00:00:00Z");
        let binding = binding_base(
            &event,
            "IDENTITY_VERIFIED",
            "ACCESS",
            "RECEIVED",
            &receipt_digest,
            template,
        );
        (event, binding)
    }

    fn extension_fixture() -> (ClaimedEvent, Value) {
        let receipt_digest = digest('6');
        let payload = json!({
            "retentionRequestId":uuid(2),
            "requestType":"CORRECTION",
            "priorDueAt":"2026-08-10T00:00:00Z",
            "dueAt":"2026-08-17T00:00:00Z",
            "extensionBusinessDays":5,
            "extensionSequence":1,
            "reasonDigest":digest('c'),
            "responsePolicyVersion":"supervisor-decision-v1",
            "responsePolicyDigest":digest('8'),
            "calendarVersionId":uuid(7),
            "calendarDigest":digest('9'),
            "notifiedAt":"2026-08-01T00:00:00Z",
            "notificationReceiptDigest":receipt_digest,
        });
        let event = claimed_event(EXTENSION_EVENT, 2, payload);
        let mut template = reason_fields();
        template["kind"] = json!("EXTENSION");
        template["priorDueAt"] = json!("2026-08-10T00:00:00Z");
        template["dueAt"] = json!("2026-08-17T00:00:00Z");
        template["extensionBusinessDays"] = json!(5);
        template["reasonCode"] = json!("LARGE_SCOPE");
        template["extensionReasonCiphertextBase64"] =
            json!("Z3VyaW5lLWZlLXYxLmtpZC5ub25jZS5jaXBoZXI=");
        template["extensionReasonSha256"] = json!(digest('c'));
        template["extensionReasonEncryptionKeyId"] = json!("kid");
        template["extensionReasonAadDigest"] = json!(digest('d'));
        let binding = binding_base(
            &event,
            "EXTENSION",
            "CORRECTION",
            "REVIEW",
            &receipt_digest,
            template,
        );
        (event, binding)
    }

    fn refusal_fixture() -> (ClaimedEvent, Value) {
        let receipt_digest = digest('6');
        let payload = json!({
            "retentionRequestId":uuid(2),
            "requestType":"DELETION",
            "decisionDigest":digest('d'),
            "reasonDigest":digest('e'),
            "appealInstructionsDigest":digest('f'),
            "responsePolicyVersion":"supervisor-decision-v1",
            "responsePolicyDigest":digest('8'),
            "calendarVersionId":uuid(7),
            "calendarDigest":digest('9'),
            "decisionAt":"2026-08-01T00:00:00Z",
            "noticeDueAt":"2026-08-15T00:00:00Z",
            "notifiedAt":"2026-08-01T00:30:00Z",
            "notificationReceiptDigest":receipt_digest,
        });
        let event = claimed_event(REFUSAL_EVENT, 3, payload);
        let mut template = reason_fields();
        template["kind"] = json!("REFUSAL");
        template["decisionAt"] = json!("2026-08-01T00:00:00Z");
        template["noticeDueAt"] = json!("2026-08-15T00:00:00Z");
        template["reasonCode"] = json!("PROOF_INVALID");
        template["rejectionReasonCiphertextBase64"] =
            json!("Z3VyaW5lLWZlLXYxLmtpZC5ub25jZS5jaXBoZXI=");
        template["rejectionReasonSha256"] = json!(digest('e'));
        template["rejectionReasonEncryptionKeyId"] = json!("kid");
        template["rejectionReasonAadDigest"] = json!(digest('1'));
        template["appealInstructionsCiphertextBase64"] =
            json!("Z3VyaW5lLWZlLXYxLmtpZC5ub25jZS5jaXBoZXI=");
        template["appealInstructionsSha256"] = json!(digest('f'));
        template["appealInstructionsEncryptionKeyId"] = json!("kid");
        template["appealInstructionsAadDigest"] = json!(digest('2'));
        let binding = binding_base(
            &event,
            "REFUSAL",
            "DELETION",
            "REJECTED",
            &receipt_digest,
            template,
        );
        (event, binding)
    }

    #[test]
    fn closed_contract_accepts_each_privacy_notice_variant() {
        for (event, binding) in [
            created_fixture(),
            identity_fixture(),
            extension_fixture(),
            refusal_fixture(),
        ] {
            assert!(validate_privacy_notification(&event, binding).is_ok());
        }
    }

    #[test]
    fn closed_contract_rejects_unknown_fields_and_wrong_schema() {
        let (event, mut binding) = identity_fixture();
        binding["unexpected"] = json!(true);
        assert!(matches!(
            validate_privacy_notification(&event, binding),
            Err(WorkerError::Contract)
        ));

        let (mut event, mut binding) = identity_fixture();
        event.payload["unexpected"] = json!(true);
        binding["event"]["payload"] = event.payload.clone();
        assert!(matches!(
            validate_privacy_notification(&event, binding),
            Err(WorkerError::Contract)
        ));

        let (event, mut binding) = identity_fixture();
        binding["schemaVersion"] = json!("privacy-request-notification-delivery.v2");
        assert!(validate_privacy_notification(&event, binding).is_err());

        let (event, mut binding) = created_fixture();
        binding["transition"] = json!({});
        assert!(validate_privacy_notification(&event, binding).is_err());
    }

    #[test]
    fn closed_contract_rejects_receipt_state_and_time_mismatches() {
        let (event, mut binding) = extension_fixture();
        binding["transition"]["eventReceiptDigest"] = json!(digest('0'));
        assert!(validate_privacy_notification(&event, binding).is_err());

        let (event, mut binding) = identity_fixture();
        binding["transition"]["branchReceiptDigest"] = json!(digest('0'));
        assert!(validate_privacy_notification(&event, binding).is_err());

        let (event, mut binding) = refusal_fixture();
        binding["transition"]["noticeReceiptDigest"] = json!(digest('0'));
        assert!(validate_privacy_notification(&event, binding).is_err());

        let (event, mut binding) = extension_fixture();
        binding["template"]["extensionReasonSha256"] = json!(digest('0'));
        assert!(matches!(
            validate_privacy_notification(&event, binding),
            Err(WorkerError::Contract)
        ));

        let (event, mut binding) = identity_fixture();
        binding["endpoint"]["state"] = json!("PENDING_VERIFICATION");
        assert!(validate_privacy_notification(&event, binding).is_err());

        let (event, mut binding) = identity_fixture();
        binding["request"]["dueAt"] = json!("2026-08-16T00:00:00Z");
        assert!(validate_privacy_notification(&event, binding).is_err());

        let (event, mut binding) = extension_fixture();
        binding["request"]["dueAt"] = json!("2026-08-18T00:00:00Z");
        assert!(validate_privacy_notification(&event, binding).is_err());

        let (mut event, mut binding) = refusal_fixture();
        event.payload["notifiedAt"] = json!("2026-08-16T00:00:00Z");
        binding["event"]["payload"] = event.payload.clone();
        assert!(validate_privacy_notification(&event, binding).is_err());

        let (event, mut binding) = created_fixture();
        binding["request"]["decisionVersion"] = json!(1);
        assert!(validate_privacy_notification(&event, binding).is_err());

        let (event, mut binding) = created_fixture();
        binding["request"]["identityVerifiedAt"] = json!("2026-08-01T00:00:00Z");
        assert!(validate_privacy_notification(&event, binding).is_err());

        let (mut event, mut binding) = created_fixture();
        event.aggregate_version = 0;
        binding["event"]["aggregateVersion"] = json!(0);
        assert!(validate_privacy_notification(&event, binding).is_err());
    }

    #[test]
    fn event_and_delivery_dispatch_are_closed() {
        assert!(is_privacy_notification_event(CREATED_EVENT));
        assert!(is_privacy_notification_event(IDENTITY_EVENT));
        assert!(is_privacy_notification_event(EXTENSION_EVENT));
        assert!(is_privacy_notification_event(REFUSAL_EVENT));
        assert!(!is_privacy_notification_event(
            "privacy.request_decision_recorded.v1"
        ));
        assert_eq!(
            privacy_delivery_disposition("DELIVERED").ok(),
            Some(PrivacyDeliveryDisposition::CompleteReplay)
        );
        assert_eq!(
            privacy_delivery_disposition("SENDING").ok(),
            Some(PrivacyDeliveryDisposition::Send)
        );
        assert!(privacy_delivery_disposition("FAILED").is_err());
        assert_eq!(privacy_delivery_channel("SMTP_EMAIL").ok(), Some("EMAIL"));
        assert!(privacy_delivery_channel("TWILIO_VOICE").is_err());
    }

    #[test]
    fn sealed_text_requires_exact_aad_key_and_plaintext_digest() {
        let key = EnvelopeKey::new([7_u8; 32]);
        let parts = [
            "ops.privacy_request_sealed_content_v2",
            "sealed_ciphertext",
            "00000000-0000-4000-8000-000000000003",
            "REJECTION_REASON",
            "1",
        ];
        let encrypted = encrypt("gurine-fe-v1", &key, &parts, "검토 사유".as_bytes());
        assert!(encrypted.is_ok());
        let Some(token) = encrypted.ok() else {
            return;
        };
        let key_id = token.split('.').nth(1).map(str::to_owned);
        assert!(key_id.is_some());
        let Some(key_id) = key_id else {
            return;
        };
        let keys = EnvelopeKeyRing {
            current: key,
            previous: None,
        };
        let ciphertext = base64::engine::general_purpose::STANDARD.encode(token.as_bytes());
        let aad_digest = gurine_auth::assertion::canonical::sha256_hex(parts.join("\0").as_bytes());
        let plaintext_digest =
            gurine_auth::assertion::canonical::sha256_hex("검토 사유".as_bytes());
        assert_eq!(
            decrypt_bound_text(
                &keys,
                &ciphertext,
                &key_id,
                &aad_digest,
                &parts,
                100,
                Some(&plaintext_digest),
            )
            .ok()
            .as_deref(),
            Some("검토 사유")
        );
        let mut noncanonical = ciphertext.clone();
        if noncanonical.ends_with('=') {
            noncanonical.pop();
        } else {
            noncanonical.push('=');
        }
        assert!(
            decrypt_bound_text(
                &keys,
                &noncanonical,
                &key_id,
                &aad_digest,
                &parts,
                100,
                Some(&plaintext_digest),
            )
            .is_err()
        );
        assert!(
            decrypt_bound_text(
                &keys,
                &ciphertext,
                &key_id,
                &digest('0'),
                &parts,
                100,
                Some(&plaintext_digest),
            )
            .is_err()
        );
        assert!(
            decrypt_bound_text(
                &keys,
                &ciphertext,
                "different-key",
                &aad_digest,
                &parts,
                100,
                Some(&plaintext_digest),
            )
            .is_err()
        );
        assert!(
            decrypt_bound_text(
                &keys,
                &ciphertext,
                &key_id,
                &aad_digest,
                &parts,
                100,
                Some(&digest('0')),
            )
            .is_err()
        );
        assert_eq!(privacy_sealed_field_kind("reason").ok(), Some("REASON"));
        assert_eq!(
            privacy_sealed_field_kind("extensionReason").ok(),
            Some("EXTENSION_REASON")
        );
        assert_eq!(
            privacy_sealed_field_kind("rejectionReason").ok(),
            Some("REJECTION_REASON")
        );
        assert_eq!(
            privacy_sealed_field_kind("appealInstructions").ok(),
            Some("APPEAL_INSTRUCTIONS")
        );
        assert!(privacy_sealed_field_kind("unknownField").is_err());
    }

    include!("privacy_notification_created_tests.rs");
}
