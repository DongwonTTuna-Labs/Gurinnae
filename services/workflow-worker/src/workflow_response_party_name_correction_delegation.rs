const PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DELEGATION_SQL: &str =
    "SELECT ops.ack_privacy_response_party_name_correction_delegation_v1($1,$2,$3,$4,$5,$6,$7)";
const INVALID_PARTY_NAME_CORRECTION_DELEGATION: &str =
    "INVALID_PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DELEGATION";
const PARTY_NAME_CORRECTION_DELEGATION_KEYS: [&str; 8] = [
    "schemaVersion",
    "eventId",
    "privacyRequestId",
    "decisionVersion",
    "transitionReceiptDigest",
    "jobId",
    "jobPayloadDigest",
    "delegated",
];

struct PartyNameCorrectionDelegation<'a> {
    event_id: Uuid,
    privacy_request_id: Uuid,
    decision_version: i64,
    transition_receipt_digest: &'a str,
}

fn is_party_name_correction_delegation_event(consumer_id: &str, event_type: &str) -> bool {
    consumer_id == "retention-worker" && event_type == "privacy.request_decision_recorded.v1"
}

async fn reconcile_privacy_response_party_name_correction_delegation(
    pool: &PgPool,
    source_event_id: Uuid,
    aggregate_id: Uuid,
    payload: &serde_json::Map<String, Value>,
    producer_job_id: Uuid,
    producer_job_lease_token: Uuid,
    producer_job_fencing_token: i64,
) -> Result<Value, Failure> {
    let (decision_version, transition_receipt_digest) =
        party_name_correction_delegation_input(aggregate_id, payload)?;
    let result =
        sqlx::query_scalar::<_, Value>(PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DELEGATION_SQL)
            .bind(source_event_id)
            .bind(aggregate_id)
            .bind(decision_version)
            .bind(transition_receipt_digest)
            .bind(producer_job_id)
            .bind(producer_job_lease_token)
            .bind(producer_job_fencing_token)
            .fetch_one(pool)
            .await
            .map_err(|error| {
                party_name_correction_delegation_database_failure(error, aggregate_id)
            })?;
    validate_party_name_correction_delegation(
        &result,
        source_event_id,
        aggregate_id,
        decision_version,
        transition_receipt_digest,
    )?;
    Ok(result)
}

fn party_name_correction_delegation_input(
    aggregate_id: Uuid,
    payload: &serde_json::Map<String, Value>,
) -> Result<(i64, &str), Failure> {
    validate_privacy_request_decision_recorded_v1(aggregate_id, payload)?;
    let decision_version = payload
        .get("decisionVersion")
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| invalid_party_name_correction_delegation("decisionVersion"))?;
    let transition_receipt_digest = payload
        .get("receiptDigest")
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or_else(|| invalid_party_name_correction_delegation("receiptDigest"))?;
    Ok((decision_version, transition_receipt_digest))
}

fn parse_party_name_correction_delegation(
    value: &Value,
) -> Result<PartyNameCorrectionDelegation<'_>, Failure> {
    let object = retention_closed_object(
        value,
        &PARTY_NAME_CORRECTION_DELEGATION_KEYS,
        INVALID_PARTY_NAME_CORRECTION_DELEGATION,
    )?;
    retention_literal(
        object,
        "schemaVersion",
        "privacy-response-party-name-correction-delegation.v1",
        INVALID_PARTY_NAME_CORRECTION_DELEGATION,
    )?;
    retention_uuid(object, "jobId", INVALID_PARTY_NAME_CORRECTION_DELEGATION)?;
    retention_digest(
        object,
        "jobPayloadDigest",
        INVALID_PARTY_NAME_CORRECTION_DELEGATION,
    )?;
    if !retention_boolean(
        object,
        "delegated",
        INVALID_PARTY_NAME_CORRECTION_DELEGATION,
    )? {
        return Err(invalid_party_name_correction_delegation("delegated"));
    }
    Ok(PartyNameCorrectionDelegation {
        event_id: retention_uuid(object, "eventId", INVALID_PARTY_NAME_CORRECTION_DELEGATION)?,
        privacy_request_id: retention_uuid(
            object,
            "privacyRequestId",
            INVALID_PARTY_NAME_CORRECTION_DELEGATION,
        )?,
        decision_version: retention_positive_integer(
            object,
            "decisionVersion",
            INVALID_PARTY_NAME_CORRECTION_DELEGATION,
        )?,
        transition_receipt_digest: retention_digest(
            object,
            "transitionReceiptDigest",
            INVALID_PARTY_NAME_CORRECTION_DELEGATION,
        )?,
    })
}

fn validate_party_name_correction_delegation(
    value: &Value,
    source_event_id: Uuid,
    privacy_request_id: Uuid,
    decision_version: i64,
    transition_receipt_digest: &str,
) -> Result<(), Failure> {
    let delegation = parse_party_name_correction_delegation(value)?;
    for (matches, field) in [
        (delegation.event_id == source_event_id, "eventId"),
        (
            delegation.privacy_request_id == privacy_request_id,
            "privacyRequestId",
        ),
        (
            delegation.decision_version == decision_version,
            "decisionVersion",
        ),
        (
            delegation.transition_receipt_digest == transition_receipt_digest,
            "transitionReceiptDigest",
        ),
    ] {
        if !matches {
            return Err(Failure::Terminal(
                "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DELEGATION_BINDING_MISMATCH",
                field.to_owned(),
            ));
        }
    }
    Ok(())
}

fn invalid_party_name_correction_delegation(field: &str) -> Failure {
    Failure::Terminal(INVALID_PARTY_NAME_CORRECTION_DELEGATION, field.to_owned())
}

fn party_name_correction_delegation_database_failure(
    error: sqlx::Error,
    privacy_request_id: Uuid,
) -> Failure {
    let sqlstate = match &error {
        sqlx::Error::Database(database) => database.code(),
        _ => None,
    };
    party_name_correction_delegation_sqlstate_failure(sqlstate.as_deref(), privacy_request_id)
}

fn party_name_correction_delegation_sqlstate_failure(
    sqlstate: Option<&str>,
    privacy_request_id: Uuid,
) -> Failure {
    if sqlstate == Some("22023") {
        return Failure::Terminal(
            "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DELEGATION_REJECTED",
            "redacted:sqlstate=22023".to_owned(),
        );
    }
    if sqlstate == Some("23514") {
        return Failure::Terminal(
            "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION_DELEGATION_BINDING_INVALID",
            "redacted:sqlstate=23514".to_owned(),
        );
    }
    retention_owner_routine_unavailable(
        RetentionEventRoute::PrivacyRequestDecisionRecordedV1,
        privacy_request_id,
    )
}

#[cfg(test)]
include!("workflow_response_party_name_correction_delegation_tests.rs");
