#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RetentionEventRoute {
    PrivacyRequestDecisionRecordedV1,
    RetentionScheduleRevisedV1,
    LegalHoldReleasedV1,
}

const PRIVACY_DECISION_KEYS: [&str; 9] = [
    "retentionRequestId",
    "decisionVersion",
    "transition",
    "priorState",
    "state",
    "inventorySnapshotDigest",
    "holdCoverageDigest",
    "decisionDigest",
    "receiptDigest",
];

impl RetentionEventRoute {
    const fn handler_name(self) -> &'static str {
        match self {
            Self::PrivacyRequestDecisionRecordedV1 => "handle_privacy_request_decision_recorded_v1",
            Self::RetentionScheduleRevisedV1 => "handle_retention_schedule_revised_v1",
            Self::LegalHoldReleasedV1 => "handle_legal_hold_released_v1",
        }
    }
}

fn retention_event_route(event_type: &str) -> Result<RetentionEventRoute, Failure> {
    match event_type {
        "privacy.request_decision_recorded.v1" => {
            Ok(RetentionEventRoute::PrivacyRequestDecisionRecordedV1)
        }
        "retention.schedule_revised.v1" => Ok(RetentionEventRoute::RetentionScheduleRevisedV1),
        "legal.hold_released.v1" => Ok(RetentionEventRoute::LegalHoldReleasedV1),
        _ => Err(Failure::Terminal(
            "CONSUMER_BINDING_INVALID",
            format!("retention-worker:{event_type}"),
        )),
    }
}

fn reconcile_retention_consumer(
    consumer_id: &str,
    event_type: &str,
    aggregate_id: Uuid,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    if consumer_id != "retention-worker" {
        return Err(Failure::Terminal(
            "CONSUMER_BINDING_INVALID",
            consumer_id.to_owned(),
        ));
    }
    reconcile_retention_event(event_type, aggregate_id, payload)
}

fn reconcile_retention_event(
    event_type: &str,
    aggregate_id: Uuid,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    let route = retention_event_route(event_type)?;
    match route {
        RetentionEventRoute::PrivacyRequestDecisionRecordedV1 => {
            handle_privacy_request_decision_recorded_v1(aggregate_id, payload)
        }
        RetentionEventRoute::RetentionScheduleRevisedV1 => {
            handle_retention_schedule_revised_v1(aggregate_id, payload)
        }
        RetentionEventRoute::LegalHoldReleasedV1 => {
            handle_legal_hold_released_v1(aggregate_id, payload)
        }
    }
}

fn handle_privacy_request_decision_recorded_v1(
    aggregate_id: Uuid,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    validate_privacy_request_decision_recorded_v1(aggregate_id, payload)?;
    Err(retention_owner_routine_unavailable(
        RetentionEventRoute::PrivacyRequestDecisionRecordedV1,
        aggregate_id,
    ))
}

fn handle_retention_schedule_revised_v1(
    aggregate_id: Uuid,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    validate_retention_schedule_revised_v1(payload)?;
    Err(retention_owner_routine_unavailable(
        RetentionEventRoute::RetentionScheduleRevisedV1,
        aggregate_id,
    ))
}

fn handle_legal_hold_released_v1(
    aggregate_id: Uuid,
    payload: &serde_json::Map<String, Value>,
) -> Result<Value, Failure> {
    validate_legal_hold_released_v1(aggregate_id, payload)?;
    Err(retention_owner_routine_unavailable(
        RetentionEventRoute::LegalHoldReleasedV1,
        aggregate_id,
    ))
}

fn retention_owner_routine_unavailable(route: RetentionEventRoute, aggregate_id: Uuid) -> Failure {
    Failure::Retryable(
        "RETENTION_OWNER_ROUTINE_UNAVAILABLE",
        format!("{}:{aggregate_id}", route.handler_name()),
    )
}

fn validate_privacy_request_decision_recorded_v1(
    aggregate_id: Uuid,
    payload: &serde_json::Map<String, Value>,
) -> Result<(), Failure> {
    retention_payload_exact_keys(payload, &PRIVACY_DECISION_KEYS)?;
    retention_payload_aggregate(payload, "retentionRequestId", aggregate_id)?;
    retention_payload_nonnegative_integer(payload, "decisionVersion")?;
    retention_payload_literal(payload, "transition", "APPROVE")?;
    retention_payload_literal(payload, "priorState", "REVIEW")?;
    retention_payload_literal(payload, "state", "APPROVED")?;
    for field in [
        "inventorySnapshotDigest",
        "holdCoverageDigest",
        "decisionDigest",
        "receiptDigest",
    ] {
        retention_payload_sha256(payload, field)?;
    }
    Ok(())
}

fn retention_payload_exact_keys(
    payload: &serde_json::Map<String, Value>,
    expected: &[&str],
) -> Result<(), Failure> {
    if payload.len() != expected.len() || expected.iter().any(|key| !payload.contains_key(*key)) {
        return Err(invalid_retention_payload("keys"));
    }
    Ok(())
}

fn validate_retention_schedule_revised_v1(
    payload: &serde_json::Map<String, Value>,
) -> Result<(), Failure> {
    retention_payload_nonempty_string(payload, "recordClass")?;
    retention_payload_nonnegative_integer(payload, "revision")?;
    retention_payload_sha256(payload, "scheduleDigest")?;
    retention_payload_sha256(payload, "policyDigest")?;
    retention_payload_datetime(payload, "effectiveAt")?;
    retention_payload_datetime(payload, "reviewExpiresAt")?;
    Ok(())
}

fn validate_legal_hold_released_v1(
    aggregate_id: Uuid,
    payload: &serde_json::Map<String, Value>,
) -> Result<(), Failure> {
    retention_payload_aggregate(payload, "holdId", aggregate_id)?;
    retention_payload_nonnegative_integer(payload, "releaseSequence")?;
    retention_payload_unique_strings(payload, "releasedScopeAtoms")?;
    for field in [
        "affectedSetDigest",
        "priorCoverageDigest",
        "resultingCoverageDigest",
        "authorityReferenceDigest",
        "receiptDigest",
    ] {
        retention_payload_sha256(payload, field)?;
    }
    Ok(())
}

fn retention_payload_aggregate(
    payload: &serde_json::Map<String, Value>,
    field: &str,
    aggregate_id: Uuid,
) -> Result<(), Failure> {
    let payload_id = object_uuid(payload, field)?;
    if payload_id != aggregate_id {
        return Err(Failure::Terminal(
            "RETENTION_EVENT_AGGREGATE_MISMATCH",
            format!("{field}:{payload_id}:{aggregate_id}"),
        ));
    }
    Ok(())
}

fn retention_payload_nonnegative_integer(
    payload: &serde_json::Map<String, Value>,
    field: &str,
) -> Result<(), Failure> {
    if payload.get(field).and_then(Value::as_u64).is_none() {
        return Err(invalid_retention_payload(field));
    }
    Ok(())
}

fn retention_payload_literal(
    payload: &serde_json::Map<String, Value>,
    field: &str,
    expected: &str,
) -> Result<(), Failure> {
    let value = payload
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_retention_payload(field))?;
    if value != expected {
        return Err(invalid_retention_payload(field));
    }
    Ok(())
}

fn retention_payload_nonempty_string(
    payload: &serde_json::Map<String, Value>,
    field: &str,
) -> Result<(), Failure> {
    let valid = payload
        .get(field)
        .and_then(Value::as_str)
        .is_some_and(|value| !value.is_empty() && value.chars().count() <= 10_000);
    if !valid {
        return Err(invalid_retention_payload(field));
    }
    Ok(())
}

fn retention_payload_sha256(
    payload: &serde_json::Map<String, Value>,
    field: &str,
) -> Result<(), Failure> {
    let valid = payload
        .get(field)
        .and_then(Value::as_str)
        .is_some_and(is_sha256);
    if !valid {
        return Err(invalid_retention_payload(field));
    }
    Ok(())
}

fn retention_payload_datetime(
    payload: &serde_json::Map<String, Value>,
    field: &str,
) -> Result<(), Failure> {
    let valid = payload
        .get(field)
        .and_then(Value::as_str)
        .is_some_and(|value| {
            time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339)
                .is_ok()
        });
    if !valid {
        return Err(invalid_retention_payload(field));
    }
    Ok(())
}

fn retention_payload_unique_strings(
    payload: &serde_json::Map<String, Value>,
    field: &str,
) -> Result<(), Failure> {
    let values = payload
        .get(field)
        .and_then(Value::as_array)
        .ok_or_else(|| invalid_retention_payload(field))?;
    let mut seen = std::collections::BTreeSet::new();
    for value in values {
        let value = value
            .as_str()
            .filter(|value| !value.is_empty() && value.chars().count() <= 10_000)
            .ok_or_else(|| invalid_retention_payload(field))?;
        if !seen.insert(value) {
            return Err(invalid_retention_payload(field));
        }
    }
    Ok(())
}

fn invalid_retention_payload(field: &str) -> Failure {
    Failure::Terminal("INVALID_RETENTION_EVENT", field.to_owned())
}

#[cfg(test)]
mod retention_event_tests {
    use serde_json::{Map, Value, json};
    use uuid::Uuid;

    use super::{
        Failure, RetentionEventRoute, handle_privacy_request_decision_recorded_v1,
        retention_event_route, retention_owner_routine_unavailable,
        validate_legal_hold_released_v1, validate_privacy_request_decision_recorded_v1,
        validate_retention_schedule_revised_v1,
    };

    const DIGEST: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    #[test]
    fn routes_only_the_three_authoritative_retention_bindings() {
        let bindings = [
            (
                "privacy.request_decision_recorded.v1",
                RetentionEventRoute::PrivacyRequestDecisionRecordedV1,
                "handle_privacy_request_decision_recorded_v1",
            ),
            (
                "retention.schedule_revised.v1",
                RetentionEventRoute::RetentionScheduleRevisedV1,
                "handle_retention_schedule_revised_v1",
            ),
            (
                "legal.hold_released.v1",
                RetentionEventRoute::LegalHoldReleasedV1,
                "handle_legal_hold_released_v1",
            ),
        ];
        for (event_type, expected, handler) in bindings {
            let route = retention_event_route(event_type).expect("authoritative binding");
            assert_eq!(route, expected);
            assert_eq!(route.handler_name(), handler);
        }

        let error = retention_event_route("legal_hold.placed.v2")
            .expect_err("undeclared retention consumer binding must fail closed");
        assert!(matches!(
            error,
            Failure::Terminal("CONSUMER_BINDING_INVALID", _)
        ));
    }

    #[test]
    fn validates_decision_event_payload_and_aggregate_binding() {
        let aggregate_id = Uuid::from_u128(1);
        let payload = object(json!({
            "retentionRequestId": aggregate_id,
            "decisionVersion": 2,
            "transition": "APPROVE",
            "priorState": "REVIEW",
            "state": "APPROVED",
            "inventorySnapshotDigest": DIGEST,
            "holdCoverageDigest": DIGEST,
            "decisionDigest": DIGEST,
            "receiptDigest": DIGEST
        }));
        assert!(validate_privacy_request_decision_recorded_v1(aggregate_id, &payload).is_ok());
        let error = validate_privacy_request_decision_recorded_v1(Uuid::from_u128(2), &payload)
            .expect_err("aggregate mismatch must fail closed");
        assert!(matches!(
            error,
            Failure::Terminal("RETENTION_EVENT_AGGREGATE_MISMATCH", _)
        ));

        for (transition, prior_state, state) in [
            ("START_REVIEW", "RECEIVED", "REVIEW"),
            ("REJECT", "REVIEW", "REJECTED"),
        ] {
            let rejected_branch = object(json!({
                "retentionRequestId": aggregate_id,
                "decisionVersion": 2,
                "transition": transition,
                "priorState": prior_state,
                "state": state,
                "inventorySnapshotDigest": null,
                "holdCoverageDigest": null,
                "decisionDigest": DIGEST,
                "receiptDigest": DIGEST
            }));
            assert!(matches!(
                validate_privacy_request_decision_recorded_v1(
                    aggregate_id,
                    &rejected_branch
                ),
                Err(Failure::Terminal("INVALID_RETENTION_EVENT", detail))
                    if detail == "transition"
            ));
        }

        let mut extra = payload.clone();
        extra.insert("unexpected".to_owned(), json!(true));
        assert!(matches!(
            validate_privacy_request_decision_recorded_v1(aggregate_id, &extra),
            Err(Failure::Terminal("INVALID_RETENTION_EVENT", detail)) if detail == "keys"
        ));

        let mut missing_inventory = payload.clone();
        missing_inventory.insert("inventorySnapshotDigest".to_owned(), Value::Null);
        assert!(matches!(
            validate_privacy_request_decision_recorded_v1(
                aggregate_id,
                &missing_inventory
            ),
            Err(Failure::Terminal("INVALID_RETENTION_EVENT", detail))
                if detail == "inventorySnapshotDigest"
        ));

        let mut missing = payload;
        missing.remove("holdCoverageDigest");
        assert!(matches!(
            validate_privacy_request_decision_recorded_v1(aggregate_id, &missing),
            Err(Failure::Terminal("INVALID_RETENTION_EVENT", detail)) if detail == "keys"
        ));
    }

    #[test]
    fn validates_schedule_and_release_contract_shapes() {
        let schedule = object(json!({
            "recordClass": "RELATIONSHIP_PERSON_CONTEXT",
            "revision": 3,
            "scheduleDigest": DIGEST,
            "policyDigest": DIGEST,
            "effectiveAt": "2026-08-01T00:00:00Z",
            "reviewExpiresAt": "2027-08-01T00:00:00Z"
        }));
        assert!(validate_retention_schedule_revised_v1(&schedule).is_ok());

        let hold_id = Uuid::from_u128(3);
        let mut release = object(json!({
            "holdId": hold_id,
            "releaseSequence": 1,
            "releasedScopeAtoms": ["RETENTION", "DELETION"],
            "affectedSetDigest": DIGEST,
            "priorCoverageDigest": DIGEST,
            "resultingCoverageDigest": DIGEST,
            "authorityReferenceDigest": DIGEST,
            "receiptDigest": DIGEST
        }));
        assert!(validate_legal_hold_released_v1(hold_id, &release).is_ok());
        release.insert(
            "releasedScopeAtoms".to_owned(),
            json!(["RETENTION", "RETENTION"]),
        );
        assert!(validate_legal_hold_released_v1(hold_id, &release).is_err());
    }

    #[test]
    fn valid_trigger_remains_retryable_until_owner_routine_exists() {
        let error = retention_owner_routine_unavailable(
            RetentionEventRoute::PrivacyRequestDecisionRecordedV1,
            Uuid::from_u128(4),
        );
        assert!(matches!(
            error,
            Failure::Retryable("RETENTION_OWNER_ROUTINE_UNAVAILABLE", _)
        ));
    }

    #[test]
    fn valid_privacy_approval_remains_retryable_without_an_effect_owner() {
        let aggregate_id = Uuid::from_u128(5);
        let payload = object(json!({
            "retentionRequestId": aggregate_id,
            "decisionVersion": 2,
            "transition": "APPROVE",
            "priorState": "REVIEW",
            "state": "APPROVED",
            "inventorySnapshotDigest": DIGEST,
            "holdCoverageDigest": DIGEST,
            "decisionDigest": DIGEST,
            "receiptDigest": DIGEST
        }));
        let failure = handle_privacy_request_decision_recorded_v1(aggregate_id, &payload)
            .expect_err("effect execution must remain unavailable");
        assert!(matches!(
            failure,
            Failure::Retryable("RETENTION_OWNER_ROUTINE_UNAVAILABLE", _)
        ));
    }

    fn object(value: Value) -> Map<String, Value> {
        match value {
            Value::Object(object) => object,
            _ => Map::new(),
        }
    }
}
