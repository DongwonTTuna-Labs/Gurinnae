use gurine_application::privacy::{
    CreatedPrivacyRequest, PrivacyCommandReceipt, PrivacyRequestPublicStatus, PrivacyRequestSession,
};
use gurine_domain::privacy::PrivacyRequestSummary;
use serde_json::{Value, json};

use super::{ServiceError, common};

pub(super) fn created(
    created: &CreatedPrivacyRequest,
    receipt_token: &str,
) -> Result<Value, ServiceError> {
    Ok(json!({
        "command": command(&created.command)?,
        "request": summary(&created.request)?,
        "receiptToken": receipt_token,
    }))
}

pub(super) fn session(session: &PrivacyRequestSession) -> Result<Value, ServiceError> {
    Ok(json!({
        "requestId": session.request_id,
        "sessionId": session.session_id,
        "state": "ACTIVE",
        "expiresAt": common::timestamp(session.expires_at)?,
        "cookieName": &session.cookie_name,
        "tokenConsumedAt": common::timestamp(session.token_consumed_at)?,
    }))
}

pub(super) fn public_status(status: &PrivacyRequestPublicStatus) -> Result<Value, ServiceError> {
    Ok(json!({
        "request": summary(&status.request)?,
        "decisionReasonCode": status.decision_reason_code.as_deref(),
        "decisionReceiptId": status.decision_receipt_id,
        "decisionReceiptSha256": status.decision_receipt_sha256.as_ref().map(|digest| digest.as_str()),
        "refusalNoticeReceiptId": status.refusal_notice_receipt_id,
        "refusalNoticeReceiptSha256": status.refusal_notice_receipt_sha256.as_ref().map(|digest| digest.as_str()),
        "noticeReceiptIds": &status.notice_receipt_ids,
        "noticeReceiptSha256s": status.notice_receipt_sha256s.iter().map(|digest| digest.as_str()).collect::<Vec<_>>(),
        "nextActionCodes": [status.next_action_code.as_str()],
        "asOf": common::timestamp(status.as_of)?,
        "links": [],
        "operationId": "getPrivacyRequest",
    }))
}

fn command(receipt: &PrivacyCommandReceipt) -> Result<Value, ServiceError> {
    Ok(json!({
        "operationId": "createPrivacyRequest",
        "requestId": receipt.transport_request_id,
        "status": "ACCEPTED",
        "aggregateId": receipt.aggregate_id,
        "aggregateVersion": receipt.aggregate_version,
        "auditEventId": receipt.audit_event_id,
        "acceptedAt": common::timestamp(receipt.accepted_at)?,
        "receiptDigest": receipt.receipt_digest.as_str(),
        "emittedEventIds": &receipt.emitted_event_ids,
        "idempotencyReplay": false,
        "links": [],
    }))
}

fn summary(summary: &PrivacyRequestSummary) -> Result<Value, ServiceError> {
    Ok(json!({
        "privacyRequestId": summary.privacy_request_id,
        "requestType": summary.request_type.as_str(),
        "state": summary.state.as_str(),
        "jurisdiction": &summary.jurisdiction,
        "scopeDigest": summary.scope_digest.as_str(),
        "identityState": summary.identity_state.as_str(),
        "identityVerifiedAt": summary.identity_verified_at.map(common::timestamp).transpose()?,
        "dueAt": summary.due_at.map(common::timestamp).transpose()?,
        "createdAt": common::timestamp(summary.created_at)?,
        "updatedAt": common::timestamp(summary.updated_at)?,
    }))
}

#[cfg(test)]
mod tests {
    use gurine_application::privacy::{
        CreatedPrivacyRequest, PRIVACY_REQUEST_RECEIPT_COOKIE_NAME, PrivacyCommandReceipt,
        PrivacyRequestSession,
    };
    use gurine_domain::privacy::{
        PrivacyDigest, PrivacyIdentityState, PrivacyRequestState, PrivacyRequestSummary,
        PrivacyRequestType,
    };
    use time::OffsetDateTime;
    use uuid::Uuid;

    use super::{created, session};

    const SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn digest() -> PrivacyDigest {
        PrivacyDigest::try_new(SHA).unwrap_or_else(|error| panic!("digest: {error}"))
    }

    fn timestamp() -> OffsetDateTime {
        OffsetDateTime::from_unix_timestamp(1_800_000_000)
            .unwrap_or_else(|error| panic!("timestamp: {error}"))
    }

    #[test]
    fn create_render_keeps_the_singleton_replay_flag_false() {
        let created_request = CreatedPrivacyRequest {
            command: PrivacyCommandReceipt {
                transport_request_id: Uuid::from_u128(1),
                aggregate_id: Uuid::from_u128(2),
                aggregate_version: 1,
                audit_event_id: Uuid::from_u128(3),
                accepted_at: timestamp(),
                receipt_digest: digest(),
                emitted_event_ids: vec![Uuid::from_u128(4)],
            },
            request: PrivacyRequestSummary::try_new(
                Uuid::from_u128(2),
                PrivacyRequestType::Access,
                PrivacyRequestState::Received,
                "KR",
                digest(),
                PrivacyIdentityState::PendingVerification,
                None,
                None,
                timestamp(),
                timestamp(),
            )
            .unwrap_or_else(|error| panic!("summary: {error}")),
            replayed: true,
        };
        let rendered = created(&created_request, "one-time-secret")
            .unwrap_or_else(|error| panic!("render: {error}"));

        assert_eq!(rendered["receiptToken"], "one-time-secret");
        assert_eq!(rendered["command"]["idempotencyReplay"], false);
        assert!(rendered.get("replayed").is_none());
    }

    #[test]
    fn session_render_exposes_no_internal_receipt_or_replay_metadata() {
        let session_receipt = PrivacyRequestSession {
            request_id: Uuid::from_u128(1),
            session_id: Uuid::from_u128(2),
            expires_at: timestamp() + time::Duration::minutes(30),
            cookie_name: PRIVACY_REQUEST_RECEIPT_COOKIE_NAME.to_owned(),
            token_consumed_at: timestamp(),
            audit_event_id: Uuid::from_u128(3),
            emitted_event_ids: vec![Uuid::from_u128(4)],
            receipt_digest: digest(),
            replayed: true,
        };
        let rendered = session(&session_receipt).unwrap_or_else(|error| panic!("render: {error}"));

        assert_eq!(rendered["cookieName"], PRIVACY_REQUEST_RECEIPT_COOKIE_NAME);
        for forbidden in [
            "auditEventId",
            "emittedEventIds",
            "receiptDigest",
            "replayed",
            "token",
        ] {
            assert!(rendered.get(forbidden).is_none(), "{forbidden}");
        }
    }
}
