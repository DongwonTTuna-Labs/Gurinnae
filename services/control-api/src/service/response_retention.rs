#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum RetentionRequestTypeV2 {
    Access,
    Correction,
    Deletion,
    Restriction,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum RetentionRequestStateV2 {
    Received,
    Review,
    Approved,
    Rejected,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum RetentionTransitionV2 {
    VerifyIdentity,
    StartReview,
    Approve,
    Reject,
    Extend,
}

const RETENTION_TRANSITION_RECEIPT_KEYS: &[&str] = &[
    "retentionRequestId",
    "decisionVersion",
    "requestType",
    "state",
    "transition",
    "transitionReceiptId",
    "transitionReceiptDigest",
    "identityVerifiedAt",
    "dueAt",
    "policyVersion",
    "policyDigest",
    "calendarVersionId",
    "calendarDigest",
    "identityReceiptId",
    "identityReceiptDigest",
    "extensionReceiptId",
    "extensionReceiptDigest",
    "refusalReceiptId",
    "refusalReceiptDigest",
    "noticeReceiptId",
    "noticeReceiptDigest",
    "appealInstructionsDigest",
    "updatedAt",
    "replayed",
];

#[derive(Clone, Debug, serde::Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RetentionTransitionReceiptV2 {
    retention_request_id: Uuid,
    decision_version: i64,
    request_type: RetentionRequestTypeV2,
    state: RetentionRequestStateV2,
    transition: RetentionTransitionV2,
    transition_receipt_id: Uuid,
    transition_receipt_digest: String,
    identity_verified_at: Option<String>,
    due_at: Option<String>,
    policy_version: Option<String>,
    policy_digest: Option<String>,
    calendar_version_id: Option<Uuid>,
    calendar_digest: Option<String>,
    identity_receipt_id: Option<Uuid>,
    identity_receipt_digest: Option<String>,
    extension_receipt_id: Option<Uuid>,
    extension_receipt_digest: Option<String>,
    refusal_receipt_id: Option<Uuid>,
    refusal_receipt_digest: Option<String>,
    notice_receipt_id: Option<Uuid>,
    notice_receipt_digest: Option<String>,
    appeal_instructions_digest: Option<String>,
    updated_at: String,
    replayed: bool,
}

impl RetentionTransitionReceiptV2 {
    fn validate(&self) -> Result<(), ServiceError> {
        if self.retention_request_id.is_nil()
            || self.transition_receipt_id.is_nil()
            || self.decision_version < 1
            || self.replayed
            || !is_sha256(&self.transition_receipt_digest)
            || !timestamp_is_valid(&self.updated_at)
            || !optional_digests_are_valid(self)
            || !optional_uuid_digest_pair(&self.identity_receipt_id, &self.identity_receipt_digest)
            || !optional_uuid_digest_pair(
                &self.extension_receipt_id,
                &self.extension_receipt_digest,
            )
            || !optional_uuid_digest_pair(&self.refusal_receipt_id, &self.refusal_receipt_digest)
            || !optional_uuid_digest_pair(&self.notice_receipt_id, &self.notice_receipt_digest)
            || !verified_clock_is_valid(self)
        {
            return Err(ServiceError::Persistence);
        }

        let no_branch_receipts = self.identity_receipt_id.is_none()
            && self.extension_receipt_id.is_none()
            && self.refusal_receipt_id.is_none()
            && self.notice_receipt_id.is_none()
            && self.appeal_instructions_digest.is_none();
        let branch_valid = match self.transition {
            RetentionTransitionV2::VerifyIdentity => {
                self.state == RetentionRequestStateV2::Received
                    && self.identity_receipt_id.is_some()
                    && self.notice_receipt_id.is_some()
                    && self.extension_receipt_id.is_none()
                    && self.refusal_receipt_id.is_none()
                    && self.appeal_instructions_digest.is_none()
            }
            RetentionTransitionV2::StartReview => {
                self.state == RetentionRequestStateV2::Review && no_branch_receipts
            }
            RetentionTransitionV2::Approve => {
                self.request_type == RetentionRequestTypeV2::Correction
                    && self.state == RetentionRequestStateV2::Approved
                    && no_branch_receipts
            }
            RetentionTransitionV2::Extend => {
                self.state != RetentionRequestStateV2::Rejected
                    && self.extension_receipt_id.is_some()
                    && self.notice_receipt_id.is_some()
                    && self.identity_receipt_id.is_none()
                    && self.refusal_receipt_id.is_none()
                    && self.appeal_instructions_digest.is_none()
            }
            RetentionTransitionV2::Reject => {
                self.state == RetentionRequestStateV2::Rejected
                    && self.refusal_receipt_id.is_some()
                    && self.notice_receipt_id.is_some()
                    && self.appeal_instructions_digest.is_some()
                    && self.identity_receipt_id.is_none()
                    && self.extension_receipt_id.is_none()
            }
        };
        if branch_valid {
            Ok(())
        } else {
            Err(ServiceError::Persistence)
        }
    }
}

fn retention_command_response(data: &Value, command: Value) -> Result<Value, ServiceError> {
    let raw = data
        .get("transition")
        .cloned()
        .ok_or(ServiceError::Persistence)?;
    if !raw
        .as_object()
        .is_some_and(retention_receipt_has_exact_keys)
    {
        return Err(ServiceError::Persistence);
    }
    let receipt: RetentionTransitionReceiptV2 =
        serde_json::from_value(raw).map_err(|_| ServiceError::Persistence)?;
    receipt.validate()?;
    validate_owner_command_binding(data, &command, &receipt)?;
    let mut response = serde_json::to_value(receipt).map_err(|_| ServiceError::Persistence)?;
    response
        .as_object_mut()
        .ok_or(ServiceError::Persistence)?
        .insert("command".to_owned(), command);
    Ok(response)
}

fn retention_receipt_has_exact_keys(object: &Map<String, Value>) -> bool {
    object.len() == RETENTION_TRANSITION_RECEIPT_KEYS.len()
        && RETENTION_TRANSITION_RECEIPT_KEYS
            .iter()
            .all(|key| object.contains_key(*key))
}

fn validate_owner_command_binding(
    data: &Value,
    command: &Value,
    receipt: &RetentionTransitionReceiptV2,
) -> Result<(), ServiceError> {
    let command_aggregate_id = command
        .get("aggregateId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::Persistence)?;
    let command_aggregate_version = command
        .get("aggregateVersion")
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or(ServiceError::Persistence)?;
    let command_receipt_digest = command
        .get("receiptDigest")
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)?;
    let command_accepted_at = command
        .get("acceptedAt")
        .and_then(Value::as_str)
        .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
        .ok_or(ServiceError::Persistence)?;
    let receipt_updated_at = OffsetDateTime::parse(&receipt.updated_at, &Rfc3339)
        .map_err(|_| ServiceError::Persistence)?;
    if command_aggregate_id != receipt.retention_request_id
        || command_aggregate_version != receipt.decision_version
        || command_receipt_digest != receipt.transition_receipt_digest
        || command.get("status").and_then(Value::as_str) != Some("COMPLETED")
        || command_accepted_at != receipt_updated_at
    {
        return Err(ServiceError::Persistence);
    }

    let audit_event_id = data
        .get("auditEventId")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::Persistence)?;
    if command.get("auditEventId") != Some(&json!(audit_event_id)) {
        return Err(ServiceError::Persistence);
    }

    let owner_events = data
        .get("outboxEventIds")
        .and_then(Value::as_array)
        .ok_or(ServiceError::Persistence)?;
    let expected_count = if receipt.transition == RetentionTransitionV2::Reject {
        2
    } else {
        1
    };
    let event_ids = owner_events
        .iter()
        .map(|value| {
            value
                .as_str()
                .and_then(|value| Uuid::parse_str(value).ok())
                .filter(|value| !value.is_nil())
                .ok_or(ServiceError::Persistence)
        })
        .collect::<Result<Vec<_>, _>>()?;
    let unique_event_ids = event_ids.iter().collect::<std::collections::BTreeSet<_>>();
    if event_ids.len() != expected_count
        || unique_event_ids.len() != event_ids.len()
        || !event_ids.windows(2).all(|pair| pair[0] < pair[1])
        || command.get("emittedEventIds") != Some(&Value::Array(owner_events.clone()))
    {
        return Err(ServiceError::Persistence);
    }
    Ok(())
}

fn timestamp_is_valid(value: &str) -> bool {
    OffsetDateTime::parse(value, &Rfc3339).is_ok()
}

fn optional_uuid_digest_pair(id: &Option<Uuid>, digest: &Option<String>) -> bool {
    match (id, digest) {
        (None, None) => true,
        (Some(id), Some(digest)) => !id.is_nil() && is_sha256(digest),
        _ => false,
    }
}

fn verified_clock_is_valid(receipt: &RetentionTransitionReceiptV2) -> bool {
    let (
        Some(identity_verified_at),
        Some(due_at),
        Some(policy_version),
        Some(policy_digest),
        Some(calendar_version_id),
        Some(calendar_digest),
    ) = (
        receipt.identity_verified_at.as_deref(),
        receipt.due_at.as_deref(),
        receipt.policy_version.as_deref(),
        receipt.policy_digest.as_deref(),
        receipt.calendar_version_id,
        receipt.calendar_digest.as_deref(),
    )
    else {
        return false;
    };
    let Ok(verified_at) = OffsetDateTime::parse(identity_verified_at, &Rfc3339) else {
        return false;
    };
    let Ok(due_at) = OffsetDateTime::parse(due_at, &Rfc3339) else {
        return false;
    };
    policy_version_is_valid(policy_version)
        && is_sha256(policy_digest)
        && !calendar_version_id.is_nil()
        && is_sha256(calendar_digest)
        && due_at > verified_at
}

fn policy_version_is_valid(value: &str) -> bool {
    let mut chars = value.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    value.len() <= 100
        && (first.is_ascii_lowercase() || first.is_ascii_digit())
        && chars.all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || matches!(character, '.' | '_' | '-')
        })
}

fn optional_digests_are_valid(receipt: &RetentionTransitionReceiptV2) -> bool {
    [
        receipt.policy_digest.as_deref(),
        receipt.calendar_digest.as_deref(),
        receipt.identity_receipt_digest.as_deref(),
        receipt.extension_receipt_digest.as_deref(),
        receipt.refusal_receipt_digest.as_deref(),
        receipt.notice_receipt_digest.as_deref(),
        receipt.appeal_instructions_digest.as_deref(),
    ]
    .into_iter()
    .flatten()
    .all(is_sha256)
}

#[cfg(test)]
include!("response_retention_tests.rs");
