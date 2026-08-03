use super::*;

#[path = "audit_retention_privacy_projection.rs"]
mod projection;
use projection::{RequestState, RequestType};

const SUMMARY_KEYS: &[&str] = &[
    "retentionRequestId",
    "requestType",
    "decisionVersion",
    "state",
    "jurisdiction",
    "scopeDigest",
    "identityState",
    "identityVerifiedAt",
    "dueAt",
    "legalHoldBlocked",
    "createdAt",
    "updatedAt",
];
const DECISION_KEYS: &[&str] = &[
    "transitionReceiptId",
    "decisionVersion",
    "transition",
    "priorState",
    "state",
    "reasonCode",
    "reasonDigest",
    "identityReceiptId",
    "extensionReceiptId",
    "refusalReceiptId",
    "noticeReceiptId",
    "decidedAt",
    "transitionReceiptDigest",
];
const WORKSPACE_KEYS: &[&str] = &[
    "request",
    "identityVerificationReceiptId",
    "identityVerificationReceiptDigest",
    "policyVersion",
    "policyDigest",
    "calendarVersionId",
    "calendarDigest",
    "inventorySnapshotDigest",
    "holdCoverageDigest",
    "activeHoldIds",
    "affectedRecordClasses",
    "locationReceipts",
    "decisionReceipts",
    "completionReceiptId",
    "completionReceiptDigest",
    "completedResponseVersion",
    "completedValueDigest",
    "accessProjection",
    "asOf",
    "links",
];

pub(super) fn validate_queue_page(
    page: &Value,
    expected_filters: &Value,
    sort: &str,
) -> Result<(), ServiceError> {
    let page = exact_object(
        page,
        &[
            "items",
            "appliedFilters",
            "asOf",
            "nextCursor",
            "totalApproximate",
            "links",
        ],
    )?;
    if page.get("appliedFilters") != Some(expected_filters)
        || !timestamp(required(page, "asOf")?)
        || !optional_bounded_string(required(page, "nextCursor")?, 4_096)
        || !optional_nonnegative_integer(required(page, "totalApproximate")?)
    {
        return Err(ServiceError::Persistence);
    }
    validate_links(required(page, "links")?)?;
    let items = required(page, "items")?
        .as_array()
        .filter(|items| items.len() <= 100)
        .ok_or(ServiceError::Persistence)?;
    let mut summaries = Vec::with_capacity(items.len());
    for item in items {
        summaries.push(validate_summary(item)?);
    }
    if !unique_ids(&summaries) || !ordered_summaries(&summaries, sort) {
        return Err(ServiceError::Persistence);
    }
    Ok(())
}

pub(super) fn validate_workspace(workspace: &Value) -> Result<(), ServiceError> {
    let workspace = exact_object(workspace, WORKSPACE_KEYS)?;
    let summary = validate_summary(required(workspace, "request")?)?;
    let identity_id = nullable_uuid(required(workspace, "identityVerificationReceiptId")?)?;
    let identity_digest =
        nullable_digest(required(workspace, "identityVerificationReceiptDigest")?)?;
    let policy_version = nullable_text(required(workspace, "policyVersion")?, 100)?;
    let policy_digest = nullable_digest(required(workspace, "policyDigest")?)?;
    let calendar_id = nullable_uuid(required(workspace, "calendarVersionId")?)?;
    let calendar_digest = nullable_digest(required(workspace, "calendarDigest")?)?;
    let clock_binding = [
        identity_id.is_some(),
        identity_digest.is_some(),
        policy_version.is_some(),
        policy_digest.is_some(),
        calendar_id.is_some(),
        calendar_digest.is_some(),
    ];
    if clock_binding.iter().any(|present| *present) && !clock_binding.iter().all(|present| *present)
    {
        return Err(ServiceError::Persistence);
    }
    match summary.identity_state {
        IdentityState::PendingVerification if clock_binding.iter().any(|present| *present) => {
            return Err(ServiceError::Persistence);
        }
        IdentityState::Verified if !clock_binding.iter().all(|present| *present) => {
            return Err(ServiceError::Persistence);
        }
        _ => {}
    }

    let inventory_digest = nullable_digest(required(workspace, "inventorySnapshotDigest")?)?;
    let hold_digest = nullable_digest(required(workspace, "holdCoverageDigest")?)?;
    if inventory_digest.is_some() != hold_digest.is_some() {
        return Err(ServiceError::Persistence);
    }
    let active_holds = uuid_array(required(workspace, "activeHoldIds")?, 1_000)?;
    if !strictly_sorted(&active_holds) {
        return Err(ServiceError::Persistence);
    }
    let record_classes = string_array(required(workspace, "affectedRecordClasses")?, 100, 200)?;
    if !strictly_sorted(&record_classes) {
        return Err(ServiceError::Persistence);
    }
    validate_location_receipts(required(workspace, "locationReceipts")?)?;
    let highest_transition_version = validate_decisions(
        required(workspace, "decisionReceipts")?,
        summary.request_type,
    )?;
    let as_of = required_timestamp(workspace, "asOf")?;
    let access_projection = projection::validate_access_projection(
        required(workspace, "accessProjection")?,
        summary.id,
        summary.request_type,
        as_of,
    )?;
    projection::validate_completion(
        workspace,
        &summary,
        access_projection.as_ref(),
        highest_transition_version,
    )?;
    validate_links(required(workspace, "links")?)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum IdentityState {
    PendingVerification,
    Verified,
}

struct Summary {
    id: Uuid,
    decision_version: i64,
    request_type: RequestType,
    state: RequestState,
    identity_state: IdentityState,
    due_at: Option<OffsetDateTime>,
    created_at: OffsetDateTime,
}

fn validate_summary(value: &Value) -> Result<Summary, ServiceError> {
    let value = exact_object(value, SUMMARY_KEYS)?;
    let id = uuid(required(value, "retentionRequestId")?)?;
    let request_type = match required(value, "requestType")?.as_str() {
        Some("ACCESS") => RequestType::Access,
        Some("CORRECTION") => RequestType::Correction,
        Some("DELETION") => RequestType::Deletion,
        Some("RESTRICTION") => RequestType::Restriction,
        _ => return Err(ServiceError::Persistence),
    };
    let decision_version = nonnegative_integer(required(value, "decisionVersion")?)?;
    let state = match required(value, "state")?.as_str() {
        Some("RECEIVED") => RequestState::Received,
        Some("REVIEW") => RequestState::Review,
        Some("APPROVED") => RequestState::Approved,
        Some("REJECTED") => RequestState::Rejected,
        Some("COMPLETED") => RequestState::Completed,
        _ => return Err(ServiceError::Persistence),
    };
    text(required(value, "jurisdiction")?, 2, 64)?;
    digest(required(value, "scopeDigest")?)?;
    let identity_state = match required(value, "identityState")?.as_str() {
        Some("PENDING_VERIFICATION") => IdentityState::PendingVerification,
        Some("VERIFIED") => IdentityState::Verified,
        _ => return Err(ServiceError::Persistence),
    };
    let identity_verified_at = nullable_timestamp(required(value, "identityVerifiedAt")?)?;
    let due_at = nullable_timestamp(required(value, "dueAt")?)?;
    if !required(value, "legalHoldBlocked")?.is_boolean() {
        return Err(ServiceError::Persistence);
    }
    let created_at = required_timestamp(value, "createdAt")?;
    let updated_at = required_timestamp(value, "updatedAt")?;
    if updated_at < created_at {
        return Err(ServiceError::Persistence);
    }
    match (identity_state, identity_verified_at, due_at) {
        (IdentityState::PendingVerification, None, None) => {}
        (IdentityState::Verified, Some(verified_at), Some(due_at)) if due_at > verified_at => {}
        _ => return Err(ServiceError::Persistence),
    }
    Ok(Summary {
        id,
        decision_version,
        request_type,
        state,
        identity_state,
        due_at,
        created_at,
    })
}

fn validate_decisions(value: &Value, request_type: RequestType) -> Result<i64, ServiceError> {
    let decisions = value
        .as_array()
        .filter(|items| items.len() <= 100)
        .ok_or(ServiceError::Persistence)?;
    let mut prior_version = 0_i64;
    for decision in decisions {
        let decision = exact_object(decision, DECISION_KEYS)?;
        uuid(required(decision, "transitionReceiptId")?)?;
        let version = positive_integer(required(decision, "decisionVersion")?)?;
        if version != prior_version + 1 {
            return Err(ServiceError::Persistence);
        }
        prior_version = version;
        let transition = enum_value(
            required(decision, "transition")?,
            &[
                "VERIFY_IDENTITY",
                "START_REVIEW",
                "APPROVE",
                "REJECT",
                "EXTEND",
            ],
        )?;
        let prior_state = enum_value(
            required(decision, "priorState")?,
            &["RECEIVED", "REVIEW", "APPROVED"],
        )?;
        let state = enum_value(
            required(decision, "state")?,
            &["RECEIVED", "REVIEW", "APPROVED", "REJECTED"],
        )?;
        text(required(decision, "reasonCode")?, 1, 100)?;
        digest(required(decision, "reasonDigest")?)?;
        let identity = nullable_uuid(required(decision, "identityReceiptId")?)?;
        let extension = nullable_uuid(required(decision, "extensionReceiptId")?)?;
        let refusal = nullable_uuid(required(decision, "refusalReceiptId")?)?;
        let notice = nullable_uuid(required(decision, "noticeReceiptId")?)?;
        let branch = BranchReceipts {
            identity,
            extension,
            refusal,
            notice,
        };
        if !decision_branch_is_valid(transition, prior_state, state, branch, request_type) {
            return Err(ServiceError::Persistence);
        }
        required_timestamp(decision, "decidedAt")?;
        digest(required(decision, "transitionReceiptDigest")?)?;
    }
    Ok(prior_version)
}

struct BranchReceipts {
    identity: Option<Uuid>,
    extension: Option<Uuid>,
    refusal: Option<Uuid>,
    notice: Option<Uuid>,
}

fn decision_branch_is_valid(
    transition: &str,
    prior_state: &str,
    state: &str,
    branch: BranchReceipts,
    request_type: RequestType,
) -> bool {
    let BranchReceipts {
        identity,
        extension,
        refusal,
        notice,
    } = branch;
    match transition {
        "VERIFY_IDENTITY" => {
            prior_state == "RECEIVED"
                && state == "RECEIVED"
                && identity.is_some()
                && notice.is_some()
                && extension.is_none()
                && refusal.is_none()
        }
        "START_REVIEW" => {
            prior_state == "RECEIVED"
                && state == "REVIEW"
                && [identity, extension, refusal, notice]
                    .iter()
                    .all(Option::is_none)
        }
        "APPROVE" => {
            request_type == RequestType::Correction
                && prior_state == "REVIEW"
                && state == "APPROVED"
                && [identity, extension, refusal, notice]
                    .iter()
                    .all(Option::is_none)
        }
        "REJECT" => {
            prior_state == "REVIEW"
                && state == "REJECTED"
                && refusal.is_some()
                && notice.is_some()
                && identity.is_none()
                && extension.is_none()
        }
        "EXTEND" => {
            matches!(prior_state, "RECEIVED" | "REVIEW" | "APPROVED")
                && state == prior_state
                && extension.is_some()
                && notice.is_some()
                && identity.is_none()
                && refusal.is_none()
        }
        _ => false,
    }
}

fn validate_location_receipts(value: &Value) -> Result<(), ServiceError> {
    let receipts = value
        .as_array()
        .filter(|items| items.len() <= 1_000)
        .ok_or(ServiceError::Persistence)?;
    for receipt in receipts {
        let receipt = exact_object(
            receipt,
            &[
                "location",
                "objectCount",
                "derivativeCount",
                "action",
                "completedAt",
                "receiptDigest",
            ],
        )?;
        text(required(receipt, "location")?, 1, 200)?;
        nonnegative_integer(required(receipt, "objectCount")?)?;
        nonnegative_integer(required(receipt, "derivativeCount")?)?;
        enum_value(
            required(receipt, "action")?,
            &[
                "EXPORTED",
                "CORRECTED",
                "DELETED",
                "RESTRICTED",
                "SUPPRESSED_FROM_RESTORE",
            ],
        )?;
        required_timestamp(receipt, "completedAt")?;
        digest(required(receipt, "receiptDigest")?)?;
    }
    Ok(())
}

fn validate_links(value: &Value) -> Result<(), ServiceError> {
    let links = value
        .as_array()
        .filter(|links| links.len() <= 32)
        .ok_or(ServiceError::Persistence)?;
    for link in links {
        let link = link.as_object().ok_or(ServiceError::Persistence)?;
        if link
            .keys()
            .any(|key| !["rel", "href", "label"].contains(&key.as_str()))
            || !link.contains_key("rel")
            || !link.contains_key("href")
        {
            return Err(ServiceError::Persistence);
        }
        text(required(link, "rel")?, 1, 100)?;
        text(required(link, "href")?, 1, 4_096)?;
        if let Some(label) = link.get("label") {
            text(label, 1, 200)?;
        }
    }
    Ok(())
}

fn exact_object<'a>(
    value: &'a Value,
    keys: &[&str],
) -> Result<&'a Map<String, Value>, ServiceError> {
    let object = value.as_object().ok_or(ServiceError::Persistence)?;
    if object.len() != keys.len()
        || object.keys().any(|key| !keys.contains(&key.as_str()))
        || keys.iter().any(|key| !object.contains_key(*key))
    {
        return Err(ServiceError::Persistence);
    }
    Ok(object)
}

fn required<'a>(object: &'a Map<String, Value>, key: &str) -> Result<&'a Value, ServiceError> {
    object.get(key).ok_or(ServiceError::Persistence)
}

fn uuid(value: &Value) -> Result<Uuid, ServiceError> {
    value
        .as_str()
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil())
        .ok_or(ServiceError::Persistence)
}

fn nullable_uuid(value: &Value) -> Result<Option<Uuid>, ServiceError> {
    if value.is_null() {
        Ok(None)
    } else {
        uuid(value).map(Some)
    }
}

fn digest(value: &Value) -> Result<&str, ServiceError> {
    value
        .as_str()
        .filter(|value| is_sha256(value))
        .ok_or(ServiceError::Persistence)
}

fn nullable_digest(value: &Value) -> Result<Option<&str>, ServiceError> {
    if value.is_null() {
        Ok(None)
    } else {
        digest(value).map(Some)
    }
}

fn nullable_text(value: &Value, maximum: usize) -> Result<Option<&str>, ServiceError> {
    if value.is_null() {
        Ok(None)
    } else {
        text(value, 1, maximum).map(Some)
    }
}

fn text(value: &Value, minimum: usize, maximum: usize) -> Result<&str, ServiceError> {
    value
        .as_str()
        .filter(|value| {
            let length = value.chars().count();
            value.trim() == *value && (minimum..=maximum).contains(&length)
        })
        .ok_or(ServiceError::Persistence)
}

fn enum_value<'a>(value: &'a Value, allowed: &[&str]) -> Result<&'a str, ServiceError> {
    value
        .as_str()
        .filter(|value| allowed.contains(value))
        .ok_or(ServiceError::Persistence)
}

fn nonnegative_integer(value: &Value) -> Result<i64, ServiceError> {
    value
        .as_i64()
        .filter(|value| *value >= 0)
        .ok_or(ServiceError::Persistence)
}

fn positive_integer(value: &Value) -> Result<i64, ServiceError> {
    value
        .as_i64()
        .filter(|value| *value > 0)
        .ok_or(ServiceError::Persistence)
}

fn nullable_timestamp(value: &Value) -> Result<Option<OffsetDateTime>, ServiceError> {
    if value.is_null() {
        Ok(None)
    } else {
        value
            .as_str()
            .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
            .map(Some)
            .ok_or(ServiceError::Persistence)
    }
}

fn required_timestamp(
    object: &Map<String, Value>,
    key: &str,
) -> Result<OffsetDateTime, ServiceError> {
    nullable_timestamp(required(object, key)?)?.ok_or(ServiceError::Persistence)
}

fn timestamp(value: &Value) -> bool {
    value
        .as_str()
        .is_some_and(|value| OffsetDateTime::parse(value, &Rfc3339).is_ok())
}

fn optional_bounded_string(value: &Value, maximum: usize) -> bool {
    value.is_null()
        || value.as_str().is_some_and(|value| {
            let length = value.chars().count();
            value.trim() == value && (1..=maximum).contains(&length)
        })
}

fn optional_nonnegative_integer(value: &Value) -> bool {
    value.is_null() || value.as_i64().is_some_and(|value| value >= 0)
}

fn uuid_array(value: &Value, maximum: usize) -> Result<Vec<Uuid>, ServiceError> {
    value
        .as_array()
        .filter(|values| values.len() <= maximum)
        .ok_or(ServiceError::Persistence)?
        .iter()
        .map(uuid)
        .collect()
}

fn string_array(
    value: &Value,
    maximum_items: usize,
    maximum_chars: usize,
) -> Result<Vec<String>, ServiceError> {
    value
        .as_array()
        .filter(|values| values.len() <= maximum_items)
        .ok_or(ServiceError::Persistence)?
        .iter()
        .map(|value| text(value, 1, maximum_chars).map(str::to_owned))
        .collect()
}

fn strictly_sorted<T: Ord>(values: &[T]) -> bool {
    values.windows(2).all(|pair| pair[0] < pair[1])
}

fn unique_ids(items: &[Summary]) -> bool {
    items
        .iter()
        .map(|item| item.id)
        .collect::<std::collections::BTreeSet<_>>()
        .len()
        == items.len()
}

fn ordered_summaries(items: &[Summary], sort: &str) -> bool {
    items.windows(2).all(|pair| match sort {
        "DUE_ASC" => match (pair[0].due_at, pair[1].due_at) {
            (Some(left), Some(right)) => left < right || left == right && pair[0].id < pair[1].id,
            (Some(_), None) => true,
            (None, Some(_)) => false,
            (None, None) => pair[0].id < pair[1].id,
        },
        "CREATED_DESC" => {
            pair[0].created_at > pair[1].created_at
                || pair[0].created_at == pair[1].created_at && pair[0].id > pair[1].id
        }
        _ => false,
    })
}
