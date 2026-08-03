use gurine_api_contracts::addendum::CommandReceiptV1;
use rust_decimal::Decimal;
use serde::Serialize;

use super::*;

#[path = "economics_import/accounting_cash.rs"]
mod accounting_cash;
#[path = "economics_import/action_scaffold.rs"]
mod action_scaffold;
#[path = "economics_import/authorization.rs"]
pub(crate) mod authorization;
#[path = "economics_import/decimal_wire.rs"]
mod decimal_wire;
#[path = "economics_import/operation.rs"]
mod operation;
#[path = "economics_import/qualification_cost.rs"]
mod qualification_cost;
#[path = "economics_import/tariff_contract.rs"]
mod tariff_contract;
#[path = "economics_import/types.rs"]
mod types;
#[path = "economics_import/usage_invoice.rs"]
mod usage_invoice;

use accounting_cash::*;
use action_scaffold::*;
use decimal_wire::*;
use operation::*;
use qualification_cost::*;
use tariff_contract::*;
use types::*;
use usage_invoice::*;

pub(super) const ECONOMICS_IMPORT_ACTION_KIND: &str = "ECONOMICS_IMPORT";
pub(super) const ECONOMICS_IMPORT_EXECUTOR_OPERATION: &str = "private.ExecuteEconomicsImport";
#[cfg_attr(
    not(test),
    expect(
        dead_code,
        reason = "consumed by the private workflow-worker economics executor contract"
    )
)]
pub(super) const ECONOMICS_IMPORT_EXECUTOR_CAPABILITY: &str = "economics.import";

pub(super) fn validate_economics_import_command(
    command: &str,
    payload: &Map<String, Value>,
) -> Result<(), ServiceError> {
    if !matches!(command, "createActionProposal" | "updateActionDraft") {
        return Ok(());
    }
    let draft = payload.get("draft").and_then(Value::as_object);
    let draft_kind = draft
        .and_then(|draft| draft.get("kind"))
        .and_then(Value::as_str);
    let request_kind = payload.get("actionKind").and_then(Value::as_str);
    if command == "createActionProposal"
        && matches!(request_kind, Some(ECONOMICS_IMPORT_ACTION_KIND))
            != matches!(draft_kind, Some(ECONOMICS_IMPORT_ACTION_KIND))
    {
        return Err(ServiceError::InvalidRequest);
    }
    if draft_kind != Some(ECONOMICS_IMPORT_ACTION_KIND) {
        return Ok(());
    }
    let draft_value = Value::Object(draft.cloned().ok_or(ServiceError::InvalidRequest)?);
    let draft: EconomicsImportDraftScaffold =
        serde_json::from_value(draft_value).map_err(|_| ServiceError::InvalidRequest)?;
    draft.validate()?;
    if payload.get("rationale")
        != payload
            .get("draft")
            .and_then(|draft| draft.get("rationale"))
    {
        return Err(ServiceError::InvalidRequest);
    }
    let _typed_owner_payload = map_economics_import_owner_payload(&draft)?;
    Ok(())
}

fn map_economics_import_owner_payload(
    draft: &EconomicsImportDraftScaffold,
) -> Result<Value, ServiceError> {
    // The action owner consumes this same public row-valued shape; there is no
    // second hidden owner payload. Re-serialization proves that no untyped
    // field survives the pre-I/O boundary. The generic proposal command still
    // receives the original request bytes; PostgreSQL owns immutable detail
    // materialization and every canonical/digest decision.
    let value =
        serde_json::to_value(draft.operation()).map_err(|_| ServiceError::InvalidRequest)?;
    let object = value.as_object().ok_or(ServiceError::InvalidRequest)?;
    if object.get("operationId").and_then(Value::as_str) != Some(draft.operation().as_str())
        || object.len() < 2
    {
        return Err(ServiceError::InvalidRequest);
    }
    Ok(value)
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
enum EconomicsImportTerminalKind {
    Succeeded,
    OperationRejected,
    PermanentFailed,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EconomicsImportExecutionReceiptV1 {
    command: CommandReceiptV1,
    action_kind: EconomicsImportActionKind,
    execution_id: Uuid,
    generation: i64,
    execution_digest: Sha256Digest,
    approval_digest: Sha256Digest,
    counted_decision_receipt_set_digest: Sha256Digest,
    effect_idempotency_key_sha256: Sha256Digest,
    target_binding_digest: Sha256Digest,
    effect_receipt_id: Uuid,
    effect_receipt_digest: Sha256Digest,
    resulting_object_id: Option<Uuid>,
    resulting_object_version: Option<i64>,
    resulting_object_digest: Option<Sha256Digest>,
    terminal_kind: EconomicsImportTerminalKind,
    occurred_at: String,
}

#[cfg_attr(
    not(test),
    expect(
        dead_code,
        reason = "wired when the FINAL-A private owner returns its exact receipt"
    )
)]
pub(super) fn validate_economics_import_execution_receipt(
    value: Value,
) -> Result<(), ServiceError> {
    let receipt: EconomicsImportExecutionReceiptV1 =
        serde_json::from_value(value).map_err(|_| ServiceError::Persistence)?;
    let resulting_binding = (
        receipt.resulting_object_id.is_some(),
        receipt.resulting_object_version.is_some(),
        receipt.resulting_object_digest.is_some(),
    );
    if receipt.command.operation_id != ECONOMICS_IMPORT_EXECUTOR_OPERATION
        || receipt.command.status != "COMPLETED"
        || receipt.command.idempotency_replay
        || receipt.command.emitted_event_ids.is_empty()
        || receipt.command.emitted_event_ids.len() > 32
        || receipt.execution_id.is_nil()
        || receipt.effect_receipt_id.is_nil()
        || receipt.generation < 1
        || receipt
            .resulting_object_version
            .is_some_and(|version| version < 1)
        || !matches!(
            resulting_binding,
            (false, false, false) | (true, true, true)
        )
        || OffsetDateTime::parse(&receipt.occurred_at, &Rfc3339).is_err()
    {
        return Err(ServiceError::Persistence);
    }
    let _immutable_bindings = (
        receipt.action_kind,
        receipt.execution_digest,
        receipt.approval_digest,
        receipt.counted_decision_receipt_set_digest,
        receipt.effect_idempotency_key_sha256,
        receipt.target_binding_digest,
        receipt.effect_receipt_digest,
        receipt.terminal_kind,
    );
    Ok(())
}

#[cfg(test)]
#[path = "economics_import_tests.rs"]
mod tests;
