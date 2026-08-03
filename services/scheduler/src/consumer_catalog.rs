use serde_json::Value;

const PROVIDER_CONTROL_CONSUMERS: &[(&str, &str)] = &[
    ("provider-control-execution-worker", "analysis-worker"),
    ("audit-indexer", "projection-worker"),
];
const ACTION_EXECUTION_CONSUMERS: &[(&str, &str)] = &[
    ("action-execution-worker", "workflow-worker"),
    ("audit-indexer", "projection-worker"),
];
const ACTION_EXECUTION_COMPLETED_CONSUMERS: &[(&str, &str)] = &[
    ("notification-worker", "notification-worker"),
    ("product-fact-projector", "projection-worker"),
    ("audit-indexer", "projection-worker"),
    ("workflow-worker", "workflow-worker"),
];
const ANALYSIS_WORKER_CONSUMERS: &[(&str, &str)] = &[("analysis-worker", "analysis-worker")];
const RETENTION_WORKER_CONSUMERS: &[(&str, &str)] = &[("retention-worker", "workflow-worker")];
const RESPONSE_MATERIALIZED_CONSUMERS: &[(&str, &str)] = &[
    ("submission-projector", "projection-worker"),
    ("audit-indexer", "projection-worker"),
];
const FUNDING_DISCLOSURE_CONSUMERS: &[(&str, &str)] = &[
    ("public-projection-worker", "projection-worker"),
    ("audit-indexer", "projection-worker"),
];
const FUNDING_CANDIDATE_CONSUMERS: &[(&str, &str)] = &[("funding-projector", "projection-worker")];
const PAYMENT_REVIEW_CONSUMERS: &[(&str, &str)] = &[("notification-worker", "notification-worker")];

fn dataset_snapshot_consumers(
    payload: &Value,
) -> Result<&'static [(&'static str, &'static str)], &'static str> {
    let state = payload.get("state").and_then(Value::as_str);
    let snapshot_kind = payload.get("snapshotKind").and_then(Value::as_str);
    match (state, snapshot_kind) {
        (Some("READY"), Some("DETECTION_DATASET")) => Ok(ANALYSIS_WORKER_CONSUMERS),
        (
            Some("READY" | "FAILED"),
            Some(
                "AGENT_CASE"
                | "DETECTION_DATASET"
                | "PUBLIC_SEARCH_PROJECTION"
                | "INTERNAL_SEARCH_PROJECTION",
            ),
        ) => Ok(&[]),
        (Some("READY" | "FAILED"), _) => {
            Err("dataset.snapshot_created.v1 payload requires a supported snapshotKind")
        }
        _ => Err("dataset.snapshot_created.v1 payload requires READY or FAILED state"),
    }
}

fn privacy_request_decision_consumers(
    payload: &Value,
) -> Result<&'static [(&'static str, &'static str)], &'static str> {
    match payload.get("transition").and_then(Value::as_str) {
        Some("APPROVE") => Ok(RETENTION_WORKER_CONSUMERS),
        Some("START_REVIEW" | "REJECT") => Ok(&[]),
        _ => Err(
            "privacy.request_decision_recorded.v1 payload requires START_REVIEW, APPROVE, or REJECT transition",
        ),
    }
}

fn action_execution_authorization_consumers(
    payload: &Value,
) -> Result<&'static [(&'static str, &'static str)], &'static str> {
    let action_kind = payload
        .get("actionKind")
        .and_then(Value::as_str)
        .ok_or("action.execution_authorized.v1 payload requires a string actionKind")?;
    match action_kind {
        "PROVIDER_CONTROL" => Ok(PROVIDER_CONTROL_CONSUMERS),
        _ => Ok(ACTION_EXECUTION_CONSUMERS),
    }
}

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
        "dataset.snapshot_created.v1" => return dataset_snapshot_consumers(payload),
        "privacy.request_decision_recorded.v1" => {
            return privacy_request_decision_consumers(payload);
        }
        "projection.publication_access_changed.v1"
        | "projection.publication_revision_created.v1" => {
            &[("projection-worker", "projection-worker")]
        }
        "entity.retention_anonymized.v1" => &[("public-projection-worker", "projection-worker")],
        "governance.funding_disclosure_published.v1" => FUNDING_DISCLOSURE_CONSUMERS,
        "donation.fact_recorded.v1" => FUNDING_CANDIDATE_CONSUMERS,
        "action.execution_completed.v1" => ACTION_EXECUTION_COMPLETED_CONSUMERS,
        "agent.run_completed.v1"
        | "attachment.correction_scan_requested.v1"
        | "attachment.response_scan_requested.v1"
        | "audit.export_requested.v1"
        | "detection.signal_created.v1"
        | "export.dataset_requested.v1"
        | "source.schema_drift_detected.v1" => &[("workflow-worker", "workflow-worker")],
        "response.submitted.v2" => &[("audit-indexer", "projection-worker")],
        "editorial.response_materialized.v2" => RESPONSE_MATERIALIZED_CONSUMERS,
        "workflow.response_submitted.v2" => {
            &[("response-submission-materializer", "workflow-worker")]
        }
        "action.execution_authorized.v1" => {
            return action_execution_authorization_consumers(payload);
        }
        "attachment.scan_completed.v1"
        | "intake.contact_received.v1"
        | "notification.correction_received.v1"
        | "notification.correction_resolved.v1"
        | "notification.publication_created.v1"
        | "notification.response_extension_requested.v1"
        | "notification.response_request_delivery_requested.v1"
        | "notification.subscription_verification_requested.v1"
        | "notification.user_invitation_requested.v1"
        | "projection.publication_applied.v1" => &[("notification-worker", "notification-worker")],
        "notification.response_submitted.v2" => &[("notification-worker", "notification-worker")],
        "notification.payment_review_requested.v1" => PAYMENT_REVIEW_CONSUMERS,
        "privacy.request_created.v2"
        | "privacy.request_identity_verified.v1"
        | "privacy.request_extension_notified.v1"
        | "privacy.request_refusal_notified.v1" => {
            &[("notification-worker", "notification-worker")]
        }
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
            consumers_for(
                "dataset.snapshot_created.v1",
                &serde_json::json!({
                    "state":"READY",
                    "snapshotKind":"DETECTION_DATASET",
                }),
            ),
            Ok(&[("analysis-worker", "analysis-worker")][..])
        );
        assert_eq!(
            consumers_for(
                "dataset.snapshot_created.v1",
                &serde_json::json!({
                    "state":"FAILED",
                    "snapshotKind":"DETECTION_DATASET",
                }),
            ),
            Ok(&[][..])
        );
        for snapshot_kind in [
            "AGENT_CASE",
            "PUBLIC_SEARCH_PROJECTION",
            "INTERNAL_SEARCH_PROJECTION",
        ] {
            assert_eq!(
                consumers_for(
                    "dataset.snapshot_created.v1",
                    &serde_json::json!({
                        "state":"READY",
                        "snapshotKind":snapshot_kind,
                    }),
                ),
                Ok(&[][..])
            );
        }
        assert_eq!(
            consumers_for(
                "dataset.snapshot_created.v1",
                &serde_json::json!({"state":"READY","snapshotKind":"UNKNOWN"}),
            ),
            Err("dataset.snapshot_created.v1 payload requires a supported snapshotKind")
        );
        assert_eq!(
            consumers_for("case.assigned.v1", &empty_payload),
            Ok(&[][..])
        );
    }

    #[test]
    fn action_execution_completion_preserves_existing_consumers_and_adds_workflow_worker() {
        assert_eq!(
            consumers_for("action.execution_completed.v1", &serde_json::json!({})),
            Ok(ACTION_EXECUTION_COMPLETED_CONSUMERS)
        );
    }

    #[test]
    fn agent_run_completion_still_routes_only_to_workflow_worker() {
        assert_eq!(
            consumers_for("agent.run_completed.v1", &serde_json::json!({})),
            Ok(&[("workflow-worker", "workflow-worker")][..])
        );
    }

    #[test]
    fn response_submission_v2_events_route_to_their_declared_consumers_only() {
        let empty_payload = serde_json::json!({});
        assert_eq!(
            consumers_for("response.submitted.v2", &empty_payload),
            Ok(&[("audit-indexer", "projection-worker")][..])
        );
        assert_eq!(
            consumers_for("notification.response_submitted.v2", &empty_payload),
            Ok(&[("notification-worker", "notification-worker")][..])
        );
        assert_eq!(
            consumers_for("workflow.response_submitted.v2", &empty_payload),
            Ok(&[("response-submission-materializer", "workflow-worker")][..])
        );
        for retired in [
            "response.submitted.v1",
            "notification.response_submitted.v1",
            "workflow.response_submitted.v1",
        ] {
            assert_eq!(consumers_for(retired, &empty_payload), Ok(&[][..]));
        }
    }

    #[test]
    fn response_materialized_v2_routes_to_both_declared_projection_consumers() {
        let empty_payload = serde_json::json!({});
        assert_eq!(
            consumers_for("editorial.response_materialized.v2", &empty_payload),
            Ok(RESPONSE_MATERIALIZED_CONSUMERS)
        );
        assert_eq!(
            consumers_for("editorial.response_materialized.v1", &empty_payload),
            Ok(&[][..])
        );
    }

    #[test]
    fn privacy_request_notice_events_route_only_to_notification_worker() {
        let empty_payload = serde_json::json!({});
        for event_type in [
            "privacy.request_created.v2",
            "privacy.request_identity_verified.v1",
            "privacy.request_extension_notified.v1",
            "privacy.request_refusal_notified.v1",
        ] {
            assert_eq!(
                consumers_for(event_type, &empty_payload),
                Ok(&[("notification-worker", "notification-worker")][..])
            );
        }
    }

    #[test]
    fn entity_retention_anonymization_routes_only_to_public_projection() {
        assert_eq!(
            consumers_for("entity.retention_anonymized.v1", &serde_json::json!({})),
            Ok(&[("public-projection-worker", "projection-worker")][..])
        );
    }

    #[test]
    fn approved_funding_disclosure_routes_to_public_projection_and_audit() {
        let empty_payload = serde_json::json!({});
        assert_eq!(
            consumers_for("governance.funding_disclosure_published.v1", &empty_payload,),
            Ok(FUNDING_DISCLOSURE_CONSUMERS)
        );
        assert_eq!(
            consumers_for("funding.disclosure_published.v1", &empty_payload),
            Ok(&[][..])
        );
    }

    #[test]
    fn donation_fact_routes_only_to_private_funding_candidate_projection() {
        let empty_payload = serde_json::json!({});
        assert_eq!(
            consumers_for("donation.fact_recorded.v1", &empty_payload),
            Ok(FUNDING_CANDIDATE_CONSUMERS)
        );
        for unsupported in ["donation.fact_recorded.v0", "donation.payment_succeeded.v1"] {
            assert_eq!(consumers_for(unsupported, &empty_payload), Ok(&[][..]));
        }
    }

    #[test]
    fn payment_review_request_routes_only_to_notification_worker() {
        let empty_payload = serde_json::json!({});
        assert_eq!(
            consumers_for("notification.payment_review_requested.v1", &empty_payload),
            Ok(PAYMENT_REVIEW_CONSUMERS)
        );
        for unsupported in [
            "notification.payment_review_request.v1",
            "notification.payment_review_requested.v2",
            "payment.review_requested.v1",
        ] {
            assert_eq!(consumers_for(unsupported, &empty_payload), Ok(&[][..]));
        }
    }

    #[test]
    fn only_approved_privacy_decisions_route_to_retention_worker() {
        assert_eq!(
            consumers_for(
                "privacy.request_decision_recorded.v1",
                &serde_json::json!({"transition":"APPROVE"}),
            ),
            Ok(RETENTION_WORKER_CONSUMERS)
        );
        for transition in ["START_REVIEW", "REJECT"] {
            assert_eq!(
                consumers_for(
                    "privacy.request_decision_recorded.v1",
                    &serde_json::json!({"transition":transition}),
                ),
                Ok(&[][..])
            );
        }
        for payload in [
            serde_json::json!({}),
            serde_json::json!({"transition":"COMPLETE"}),
            serde_json::json!({"transition":7}),
        ] {
            assert!(
                consumers_for("privacy.request_decision_recorded.v1", &payload).is_err(),
                "invalid transition must fail closed: {payload}"
            );
        }
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
