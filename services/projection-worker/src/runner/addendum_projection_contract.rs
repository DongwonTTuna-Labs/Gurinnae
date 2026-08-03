pub(super) fn event_is_accepted(consumer_id: &str, event_type: &str) -> bool {
    match consumer_id {
        "audit-indexer" => matches!(
            event_type,
            "communication.intent_created.v1"
                | "communication.delivery_requested.v1"
                | "communication.delivery_receipt_recorded.v1"
                | "communication.authorization_changed.v1"
                | "communication.subscription_update_requested.v1"
                | "action.execution_authorized.v1"
                | "editorial.response_materialized.v2"
                | "response.submitted.v2"
        ),
        "cost-projector" => event_type == "communication.delivery_receipt_recorded.v1",
        "submission-projector" => matches!(
            event_type,
            "communication.authorization_changed.v1" | "editorial.response_materialized.v2"
        ),
        _ => false,
    }
}
