fn created_fixture() -> (ClaimedEvent, Value) {
    let payload = json!({
        "retentionRequestId":uuid(2),
        "requestType":"ACCESS",
        "subjectProofHash":digest('a'),
        "jurisdiction":"KR",
        "scopeDigest":digest('b'),
        "identityState":"PENDING_VERIFICATION",
        "identityVerifiedAt":null,
        "dueAt":null,
        "receiptDigest":digest('c'),
        "commandReceiptDigest":digest('d'),
    });
    let event = claimed_event(CREATED_EVENT, 1, payload);
    let binding = json!({
        "schemaVersion":"privacy-request-notification-delivery.v1",
        "noticeType":"IDENTITY_VERIFICATION_REQUIRED",
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
            "decisionVersion":0,
            "requestType":"ACCESS",
            "state":"RECEIVED",
            "identityState":"PENDING_VERIFICATION",
            "identityVerifiedAt":null,
            "dueAt":null,
        },
        "endpoint":{
            "endpointId":uuid(6),
            "channel":"SMTP_EMAIL",
            "state":"PENDING_VERIFICATION",
            "version":1,
            "endpointDigest":digest('4'),
            "endpointCiphertextBase64":"Z3VyaW5lLWZlLXYxLmtpZC5ub25jZS5jaXBoZXI=",
            "encryptionKeyId":"kid",
            "endpointAadDigest":digest('5'),
            "updatedAt":"2026-07-31T01:00:00Z",
        },
        "template":{"kind":"IDENTITY_VERIFICATION_REQUIRED"},
    });
    (event, binding)
}

#[test]
fn created_notice_keeps_deadline_unstarted_and_has_no_success_claim() {
    assert_eq!(
        render_identity_verification_required("열람"),
        (
            "구린네 개인정보 열람 요청 접수".to_owned(),
            "개인정보 열람 요청 접수\n신원 확인 완료 전 처리 기한 미기산".to_owned(),
            "<p>개인정보 열람 요청 접수</p><p>신원 확인 완료 전 처리 기한 미기산</p>"
                .to_owned(),
        )
    );
}

#[test]
fn created_contract_requires_identity_and_due_times_to_remain_null() {
    for field in ["identityVerifiedAt", "dueAt"] {
        let (mut event, mut binding) = created_fixture();
        event.payload[field] = json!("2026-08-15T00:00:00Z");
        binding["event"]["payload"] = event.payload.clone();
        assert!(matches!(
            validate_privacy_notification(&event, binding),
            Err(WorkerError::Contract)
        ));
    }
}

#[test]
fn created_notice_uses_the_pending_endpoint_before_identity_verification() {
    let (event, mut binding) = created_fixture();
    binding["endpoint"]["state"] = json!("ACTIVE");
    assert!(matches!(
        validate_privacy_notification(&event, binding),
        Err(WorkerError::Contract)
    ));
}
