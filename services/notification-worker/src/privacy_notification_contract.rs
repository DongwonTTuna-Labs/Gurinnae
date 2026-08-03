use serde::Deserialize;
use time::{OffsetDateTime, UtcOffset, format_description::well_known::Rfc3339};

const PRIVACY_NOTIFICATION_SCHEMA: &str = "privacy-request-notification-delivery.v1";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum PrivacyNoticeType {
    IdentityVerificationRequired,
    IdentityVerified,
    Extension,
    Refusal,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum PrivacyRequestType {
    Access,
    Correction,
    Deletion,
    Restriction,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum PrivacyRequestState {
    Received,
    Review,
    Approved,
    Rejected,
    Completed,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum PrivacyIdentityState {
    PendingVerification,
    Verified,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PrivacyNotificationBinding {
    schema_version: String,
    notice_type: PrivacyNoticeType,
    event: PrivacyNotificationEventBinding,
    request: PrivacyNotificationRequestBinding,
    transition: PrivacyNotificationTransitionBinding,
    endpoint: PrivacyNotificationEndpointBinding,
    template: PrivacyNoticeTemplate,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PrivacyNotificationEventBinding {
    event_id: Uuid,
    event_type: String,
    aggregate_id: Uuid,
    aggregate_version: i64,
    event_envelope_digest: String,
    occurred_at: String,
    payload: serde_json::Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PrivacyNotificationRequestBinding {
    retention_request_id: Uuid,
    decision_version: i64,
    request_type: PrivacyRequestType,
    state: PrivacyRequestState,
    identity_state: PrivacyIdentityState,
    identity_verified_at: Option<String>,
    due_at: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PrivacyNotificationTransitionBinding {
    transition_receipt_id: Uuid,
    transition_receipt_digest: String,
    event_receipt_id: Uuid,
    event_receipt_digest: String,
    branch_receipt_digest: String,
    notice_receipt_id: Uuid,
    notice_receipt_digest: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PrivacyNotificationEndpointBinding {
    endpoint_id: Uuid,
    channel: String,
    state: String,
    version: i64,
    endpoint_digest: String,
    endpoint_ciphertext_base64: String,
    encryption_key_id: String,
    endpoint_aad_digest: String,
    updated_at: String,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "SCREAMING_SNAKE_CASE", deny_unknown_fields)]
enum PrivacyNoticeTemplate {
    IdentityVerificationRequired,
    IdentityVerified {
        #[serde(rename = "dueAt")]
        due_at: String,
        #[serde(flatten)]
        reason: ReasonSealedFields,
    },
    Extension {
        #[serde(rename = "priorDueAt")]
        prior_due_at: String,
        #[serde(rename = "dueAt")]
        due_at: String,
        #[serde(rename = "extensionBusinessDays")]
        extension_business_days: i64,
        #[serde(rename = "reasonCode")]
        reason_code: String,
        #[serde(flatten)]
        reason: ReasonSealedFields,
        #[serde(flatten)]
        extension_reason: ExtensionReasonSealedFields,
    },
    Refusal {
        #[serde(rename = "decisionAt")]
        decision_at: String,
        #[serde(rename = "noticeDueAt")]
        notice_due_at: String,
        #[serde(rename = "reasonCode")]
        reason_code: String,
        #[serde(flatten)]
        reason: ReasonSealedFields,
        #[serde(flatten)]
        rejection_reason: RejectionReasonSealedFields,
        #[serde(flatten)]
        appeal_instructions: AppealInstructionsSealedFields,
    },
}

macro_rules! sealed_fields {
    ($name:ident, $ciphertext:literal, $sha:literal, $key:literal, $aad:literal) => {
        #[derive(Debug, Deserialize)]
        #[serde(deny_unknown_fields)]
        struct $name {
            #[serde(rename = $ciphertext)]
            ciphertext_base64: String,
            #[serde(rename = $sha)]
            sha256: String,
            #[serde(rename = $key)]
            encryption_key_id: String,
            #[serde(rename = $aad)]
            aad_digest: String,
        }
    };
}

sealed_fields!(
    ReasonSealedFields,
    "reasonCiphertextBase64",
    "reasonSha256",
    "reasonEncryptionKeyId",
    "reasonAadDigest"
);
sealed_fields!(
    ExtensionReasonSealedFields,
    "extensionReasonCiphertextBase64",
    "extensionReasonSha256",
    "extensionReasonEncryptionKeyId",
    "extensionReasonAadDigest"
);
sealed_fields!(
    RejectionReasonSealedFields,
    "rejectionReasonCiphertextBase64",
    "rejectionReasonSha256",
    "rejectionReasonEncryptionKeyId",
    "rejectionReasonAadDigest"
);
sealed_fields!(
    AppealInstructionsSealedFields,
    "appealInstructionsCiphertextBase64",
    "appealInstructionsSha256",
    "appealInstructionsEncryptionKeyId",
    "appealInstructionsAadDigest"
);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct IdentityVerifiedPayload {
    retention_request_id: Uuid,
    request_type: PrivacyRequestType,
    prior_identity_state: PrivacyIdentityState,
    identity_state: PrivacyIdentityState,
    identity_proof_receipt_digest: String,
    identity_verified_at: String,
    response_policy_version: String,
    response_policy_digest: String,
    calendar_version_id: Uuid,
    calendar_digest: String,
    due_at: String,
    verification_receipt_digest: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExtensionNotifiedPayload {
    retention_request_id: Uuid,
    request_type: PrivacyRequestType,
    prior_due_at: String,
    due_at: String,
    extension_business_days: i64,
    extension_sequence: i64,
    reason_digest: String,
    response_policy_version: String,
    response_policy_digest: String,
    calendar_version_id: Uuid,
    calendar_digest: String,
    notified_at: String,
    notification_receipt_digest: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RefusalNotifiedPayload {
    retention_request_id: Uuid,
    request_type: PrivacyRequestType,
    decision_digest: String,
    reason_digest: String,
    appeal_instructions_digest: String,
    response_policy_version: String,
    response_policy_digest: String,
    calendar_version_id: Uuid,
    calendar_digest: String,
    decision_at: String,
    notice_due_at: String,
    notified_at: String,
    notification_receipt_digest: String,
}

enum PrivacyEventPayload {
    Identity(IdentityVerifiedPayload),
    Extension(ExtensionNotifiedPayload),
    Refusal(RefusalNotifiedPayload),
}

struct ValidatedPrivacyNotification {
    notice_type: PrivacyNoticeType,
    request_type: PrivacyRequestType,
    retention_request_id: Uuid,
    event_envelope_digest: String,
    transition_receipt_id: Option<Uuid>,
    endpoint: PrivacyNotificationEndpointBinding,
    template: PrivacyNoticeTemplate,
}

fn is_privacy_notification_event(event_type: &str) -> bool {
    matches!(
        event_type,
        "privacy.request_created.v2"
            | "privacy.request_identity_verified.v1"
            | "privacy.request_extension_notified.v1"
            | "privacy.request_refusal_notified.v1"
    )
}

fn validate_privacy_notification(
    event: &ClaimedEvent,
    value: serde_json::Value,
) -> Result<ValidatedPrivacyNotification, WorkerError> {
    if event.event_type == "privacy.request_created.v2" {
        return validate_created_privacy_notification(event, value);
    }
    let binding: PrivacyNotificationBinding =
        serde_json::from_value(value).map_err(|_| WorkerError::Contract)?;
    let occurred_at = validate_privacy_notification_common(
        event,
        &binding.schema_version,
        &binding.event,
        &binding.request,
        &binding.endpoint,
    )?;
    if binding.endpoint.state != "ACTIVE"
        || binding.request.decision_version != event.aggregate_version
        || binding.transition.transition_receipt_id.is_nil()
        || binding.transition.event_receipt_id.is_nil()
        || binding.transition.event_receipt_id != binding.event.event_id
        || binding.transition.event_receipt_digest != binding.event.event_envelope_digest
        || binding.transition.notice_receipt_id.is_nil()
    {
        return Err(WorkerError::Contract);
    }
    for digest in [
        &binding.transition.transition_receipt_digest,
        &binding.transition.event_receipt_digest,
        &binding.transition.branch_receipt_digest,
        &binding.transition.notice_receipt_digest,
    ] {
        validate_sha256(digest)?;
    }
    let payload = parse_privacy_event_payload(event)?;
    validate_payload_binding(&binding, &payload, occurred_at)?;
    Ok(ValidatedPrivacyNotification {
        notice_type: binding.notice_type,
        request_type: binding.request.request_type,
        retention_request_id: binding.request.retention_request_id,
        event_envelope_digest: binding.event.event_envelope_digest,
        transition_receipt_id: Some(binding.transition.transition_receipt_id),
        endpoint: binding.endpoint,
        template: binding.template,
    })
}

fn parse_privacy_event_payload(event: &ClaimedEvent) -> Result<PrivacyEventPayload, WorkerError> {
    match event.event_type.as_str() {
        "privacy.request_identity_verified.v1" => serde_json::from_value(event.payload.clone())
            .map(PrivacyEventPayload::Identity)
            .map_err(|_| WorkerError::Contract),
        "privacy.request_extension_notified.v1" => serde_json::from_value(event.payload.clone())
            .map(PrivacyEventPayload::Extension)
            .map_err(|_| WorkerError::Contract),
        "privacy.request_refusal_notified.v1" => serde_json::from_value(event.payload.clone())
            .map(PrivacyEventPayload::Refusal)
            .map_err(|_| WorkerError::Contract),
        _ => Err(WorkerError::Contract),
    }
}

fn validate_payload_binding(
    binding: &PrivacyNotificationBinding,
    payload: &PrivacyEventPayload,
    occurred_at: OffsetDateTime,
) -> Result<(), WorkerError> {
    match (binding.notice_type, &binding.template, payload) {
        (
            PrivacyNoticeType::IdentityVerified,
            PrivacyNoticeTemplate::IdentityVerified { due_at, reason },
            PrivacyEventPayload::Identity(payload),
        ) => validate_identity_payload(binding, payload, due_at, reason, occurred_at),
        (
            PrivacyNoticeType::Extension,
            PrivacyNoticeTemplate::Extension {
                prior_due_at,
                due_at,
                extension_business_days,
                reason_code,
                reason,
                extension_reason,
            },
            PrivacyEventPayload::Extension(payload),
        ) => validate_extension_payload(
            binding,
            payload,
            ExtensionTemplateRef {
                prior_due_at,
                due_at,
                extension_business_days: *extension_business_days,
                reason_code,
                reason,
                extension_reason,
            },
            occurred_at,
        ),
        (
            PrivacyNoticeType::Refusal,
            PrivacyNoticeTemplate::Refusal {
                decision_at,
                notice_due_at,
                reason_code,
                reason,
                rejection_reason,
                appeal_instructions,
            },
            PrivacyEventPayload::Refusal(payload),
        ) => validate_refusal_payload(
            binding,
            payload,
            RefusalTemplateRef {
                decision_at,
                notice_due_at,
                reason_code,
                reason,
                rejection_reason,
                appeal_instructions,
            },
            occurred_at,
        ),
        _ => Err(WorkerError::Contract),
    }
}
