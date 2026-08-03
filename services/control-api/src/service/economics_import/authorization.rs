use sqlx::PgPool;
use uuid::Uuid;

use super::{ECONOMICS_IMPORT_ACTION_KIND, ServiceError, Value};

const PROPOSAL_BOUND_OPERATIONS: &[&str] = &[
    "updateActionDraft",
    "previewActionDraft",
    "submitActionForReview",
    "claimActionReview",
    "submitActionDecision",
];

pub(crate) fn economics_import_kind_may_be_persisted(operation: &str) -> bool {
    PROPOSAL_BOUND_OPERATIONS.contains(&operation)
}

pub(crate) async fn required(
    operation: &str,
    proposal_id: Option<Uuid>,
    body: &[u8],
    pool: &PgPool,
) -> Result<bool, ServiceError> {
    let caller_selected = caller_selects_economics_import(operation, body);
    if operation == "createActionProposal" {
        return Ok(caller_selected);
    }
    if !PROPOSAL_BOUND_OPERATIONS.contains(&operation) {
        return Ok(false);
    }
    let Some(proposal_id) = proposal_id else {
        return Ok(caller_selected);
    };
    let persisted_kind = sqlx::query_scalar::<_, String>(
        "SELECT action_kind::text FROM ops.action_proposals WHERE id=$1",
    )
    .bind(proposal_id)
    .fetch_optional(pool)
    .await
    .map_err(super::db)?;
    Ok(required_from_sources(
        operation,
        caller_selected,
        persisted_kind.as_deref(),
    ))
}

pub(crate) fn caller_selects_economics_import(operation: &str, body: &[u8]) -> bool {
    let Ok(payload) = serde_json::from_slice::<Value>(body) else {
        return false;
    };
    match operation {
        "createActionProposal" => {
            payload.get("actionKind").and_then(Value::as_str) == Some(ECONOMICS_IMPORT_ACTION_KIND)
                || draft_kind(&payload) == Some(ECONOMICS_IMPORT_ACTION_KIND)
        }
        "updateActionDraft" => draft_kind(&payload) == Some(ECONOMICS_IMPORT_ACTION_KIND),
        "submitActionDecision" => {
            payload.get("actionKind").and_then(Value::as_str) == Some(ECONOMICS_IMPORT_ACTION_KIND)
        }
        _ => false,
    }
}

fn draft_kind(payload: &Value) -> Option<&str> {
    payload
        .get("draft")
        .and_then(Value::as_object)
        .and_then(|draft| draft.get("kind"))
        .and_then(Value::as_str)
}

fn required_from_sources(
    operation: &str,
    caller_selected: bool,
    persisted_kind: Option<&str>,
) -> bool {
    PROPOSAL_BOUND_OPERATIONS.contains(&operation)
        && (caller_selected || persisted_kind == Some(ECONOMICS_IMPORT_ACTION_KIND))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_kind_mismatch_cannot_downgrade_authorization() {
        for body in [
            br#"{"actionKind":"TASK","draft":{"kind":"ECONOMICS_IMPORT"}}"#.as_slice(),
            br#"{"actionKind":"ECONOMICS_IMPORT","draft":{"kind":"TASK"}}"#.as_slice(),
        ] {
            assert!(caller_selects_economics_import(
                "createActionProposal",
                body
            ));
        }
        assert!(!caller_selects_economics_import(
            "createActionProposal",
            br#"{"actionKind":"TASK","draft":{"kind":"TASK"}}"#,
        ));
    }

    #[test]
    fn persisted_kind_cannot_be_downgraded_by_later_request_bytes() {
        for operation in PROPOSAL_BOUND_OPERATIONS {
            assert!(required_from_sources(
                operation,
                false,
                Some(ECONOMICS_IMPORT_ACTION_KIND),
            ));
        }
    }

    #[test]
    fn caller_economics_kind_strengthens_update_and_decision_authorization() {
        assert!(caller_selects_economics_import(
            "updateActionDraft",
            br#"{"draft":{"kind":"ECONOMICS_IMPORT"}}"#,
        ));
        assert!(caller_selects_economics_import(
            "submitActionDecision",
            br#"{"actionKind":"ECONOMICS_IMPORT","decision":{"kind":"REJECT"}}"#,
        ));
        assert!(required_from_sources(
            "updateActionDraft",
            true,
            Some("TASK"),
        ));
        assert!(required_from_sources(
            "submitActionDecision",
            true,
            Some("TASK"),
        ));
    }

    #[test]
    fn unrelated_operation_ignores_an_untrusted_economics_discriminator() {
        assert!(!caller_selects_economics_import(
            "previewActionDraft",
            br#"{"actionKind":"ECONOMICS_IMPORT"}"#,
        ));
        assert!(!required_from_sources(
            "publishCase",
            true,
            Some(ECONOMICS_IMPORT_ACTION_KIND),
        ));
    }

    #[test]
    fn withdrawal_operations_remain_outside_the_economics_overlay() {
        for operation in ["withdrawActionProposal", "withdrawActionDecision"] {
            assert!(!economics_import_kind_may_be_persisted(operation));
            assert!(!caller_selects_economics_import(
                operation,
                br#"{"actionKind":"ECONOMICS_IMPORT"}"#,
            ));
            assert!(!required_from_sources(
                operation,
                true,
                Some(ECONOMICS_IMPORT_ACTION_KIND),
            ));
        }
    }
}
