use serde_json::Value;

const PROVIDER_CONTROL_CONSUMERS: &[(&str, &str)] = &[
    ("provider-control-execution-worker", "analysis-worker"),
    ("audit-indexer", "projection-worker"),
];
const ACTION_EXECUTION_CONSUMERS: &[(&str, &str)] = &[
    ("action-execution-worker", "workflow-worker"),
    ("audit-indexer", "projection-worker"),
];

pub(crate) fn consumers_for(
    event_type: &str,
    payload: &Value,
) -> Result<&'static [(&'static str, &'static str)], &'static str> {
    let consumers: &'static [(&'static str, &'static str)] = match event_type {
        "workflow.rule_activation_applied.v1" => &[
            ("analysis-worker", "analysis-worker"),
            ("scheduler", "scheduler"),
        ],
        "source.document_stored.v1" => &[("document-extractor", "document-extractor")],
        "source.document_parsed.v1" => &[("ingest-worker", "ingest-worker")],
        "projection.publication_access_changed.v1"
        | "projection.publication_revision_created.v1" => {
            &[("projection-worker", "projection-worker")]
        }
        "agent.run_completed.v1"
        | "attachment.correction_scan_requested.v1"
        | "attachment.response_scan_requested.v1"
        | "audit.export_requested.v1"
        | "detection.signal_created.v1"
        | "export.dataset_requested.v1"
        | "source.schema_drift_detected.v1"
        | "workflow.response_submitted.v1" => &[("workflow-worker", "workflow-worker")],
        "action.execution_authorized.v1" => {
            let action_kind = payload
                .get("actionKind")
                .and_then(Value::as_str)
                .ok_or("action.execution_authorized.v1 payload requires a string actionKind")?;
            if action_kind == "PROVIDER_CONTROL" {
                PROVIDER_CONTROL_CONSUMERS
            } else {
                ACTION_EXECUTION_CONSUMERS
            }
        }
        "attachment.scan_completed.v1"
        | "intake.contact_received.v1"
        | "notification.correction_received.v1"
        | "notification.correction_resolved.v1"
        | "notification.publication_created.v1"
        | "notification.response_extension_requested.v1"
        | "notification.response_request_delivery_requested.v1"
        | "notification.response_submitted.v1"
        | "notification.subscription_verification_requested.v1"
        | "notification.user_invitation_requested.v1"
        | "projection.publication_applied.v1" => &[("notification-worker", "notification-worker")],
        "communication.intent_created.v1" => &[
            ("notification-worker", "notification-worker"),
            ("audit-indexer", "projection-worker"),
        ],
        "communication.delivery_requested.v1" => &[
            ("communication-gateway", "notification-worker"),
            ("audit-indexer", "projection-worker"),
        ],
        "communication.delivery_receipt_recorded.v1" => &[
            ("response-request-materializer", "workflow-worker"),
            ("notification-worker", "notification-worker"),
            ("response-clock-worker", "workflow-worker"),
            ("cost-projector", "projection-worker"),
            ("audit-indexer", "projection-worker"),
        ],
        "communication.authorization_changed.v1" => &[
            ("notification-worker", "notification-worker"),
            ("submission-projector", "projection-worker"),
            ("audit-indexer", "projection-worker"),
        ],
        "communication.subscription_update_requested.v1" => &[
            ("notification-worker", "notification-worker"),
            ("audit-indexer", "projection-worker"),
        ],
        _ => &[],
    };
    Ok(consumers)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn consumer_catalog_contract_is_embedded() {
        let empty_payload = serde_json::json!({});
        assert_eq!(
            consumers_for("source.document_stored.v1", &empty_payload),
            Ok(&[("document-extractor", "document-extractor")][..])
        );
        assert_eq!(
            consumers_for("source.document_parsed.v1", &empty_payload),
            Ok(&[("ingest-worker", "ingest-worker")][..])
        );
        assert_eq!(
            consumers_for("workflow.rule_activation_applied.v1", &empty_payload),
            Ok(&[
                ("analysis-worker", "analysis-worker"),
                ("scheduler", "scheduler")
            ][..])
        );
        assert_eq!(
            consumers_for("case.assigned.v1", &empty_payload),
            Ok(&[][..])
        );
    }

    #[test]
    fn provider_control_authorization_routes_to_executor_and_audit() {
        assert_eq!(
            consumers_for(
                "action.execution_authorized.v1",
                &serde_json::json!({"actionKind": "PROVIDER_CONTROL"}),
            ),
            Ok(PROVIDER_CONTROL_CONSUMERS)
        );
    }

    #[test]
    fn existing_action_execution_routes_to_executor_and_audit() {
        assert_eq!(
            consumers_for(
                "action.execution_authorized.v1",
                &serde_json::json!({"actionKind": "COMMUNICATION"}),
            ),
            Ok(ACTION_EXECUTION_CONSUMERS)
        );
    }

    #[test]
    fn action_authorization_without_string_kind_fails_closed() {
        for payload in [
            serde_json::json!({"executionId": "missing-kind"}),
            serde_json::json!({"actionKind": 17}),
        ] {
            assert_eq!(
                consumers_for("action.execution_authorized.v1", &payload),
                Err("action.execution_authorized.v1 payload requires a string actionKind")
            );
        }
    }
}
