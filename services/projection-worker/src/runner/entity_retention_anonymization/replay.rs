use serde_json::{Value, json};

use super::{CONSUMER_ID, EVENT_TYPE, Failure, RetentionAnonymizedEvent, exact_object};

const RESULT_FIELDS: [&str; 8] = [
    "consumerId",
    "eventId",
    "eventType",
    "entityKind",
    "entityId",
    "executionReceiptId",
    "outcome",
    "projectionRowChanged",
];
const RESULT_OUTCOME: &str = "PUBLIC_PLAINTEXT_ANONYMIZED";

pub(super) fn result(event: &RetentionAnonymizedEvent, changed: bool) -> Value {
    json!({
        "consumerId":CONSUMER_ID,
        "eventId":event.event_id,
        "eventType":EVENT_TYPE,
        "entityKind":event.entity_kind.as_str(),
        "entityId":event.entity_id,
        "executionReceiptId":event.execution_receipt_id,
        "outcome":RESULT_OUTCOME,
        "projectionRowChanged":changed,
    })
}

pub(super) fn validate_stored_result(
    event: &RetentionAnonymizedEvent,
    stored: &str,
) -> Result<Value, Failure> {
    let value: Value = serde_json::from_str(stored)
        .map_err(|_| Failure::Terminal("INBOX_RESULT_INVALID", event.event_id.to_string()))?;
    let object = exact_object(&value, &RESULT_FIELDS, "inboxResult")
        .map_err(|_| Failure::Terminal("INBOX_RESULT_INVALID", event.event_id.to_string()))?;
    let changed = object
        .get("projectionRowChanged")
        .and_then(Value::as_bool)
        .ok_or_else(|| Failure::Terminal("INBOX_RESULT_INVALID", event.event_id.to_string()))?;
    if value == result(event, changed) {
        Ok(value)
    } else {
        Err(Failure::Terminal(
            "INBOX_RESULT_INVALID",
            event.event_id.to_string(),
        ))
    }
}
