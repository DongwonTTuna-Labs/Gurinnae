const R6D_PERSON_RETENTION_OWNER_SQL: &str =
    "SELECT ops.execute_due_r6d_person_retention_job_v1($1,$2,$3)";
const INVALID_RETENTION_JOB: &str = "INVALID_R6D_PERSON_RETENTION_JOB";
const INVALID_RETENTION_RESULT: &str = "INVALID_R6D_PERSON_RETENTION_RESULT";
const RETENTION_ERASURE_ACTOR_TYPE: &str = "SERVICE";
const RETENTION_ERASURE_ACTOR_ID: &str = "retention-worker";

const RETENTION_JOB_KEYS: [&str; 19] = [
    "schemaVersion",
    "contextId",
    "personNodeId",
    "topologyDigest",
    "recordClass",
    "scheduleId",
    "scheduleRevision",
    "scheduleDigest",
    "triggerKind",
    "terminalAction",
    "holdBehavior",
    "activeDurationSeconds",
    "backupDurationSeconds",
    "triggerAt",
    "dueAt",
    "contextStateDigest",
    "requestId",
    "idempotencyKeySha256",
    "requestDigest",
];

const RETENTION_RESULT_KEYS: [&str; 32] = [
    "schemaVersion",
    "receiptId",
    "jobId",
    "jobFencingToken",
    "jobLeaseTokenSha256",
    "jobPayloadDigest",
    "contextId",
    "personNodeId",
    "topologyDigest",
    "personNameDigest",
    "contextStateDigest",
    "scheduleId",
    "scheduleRevision",
    "scheduleDigest",
    "triggerKind",
    "triggerAt",
    "dueAt",
    "erasureReceiptId",
    "erasureReceiptDigest",
    "erasureAuditEventId",
    "erasureActorType",
    "erasureActorId",
    "requestId",
    "idempotencyKeySha256",
    "requestDigest",
    "governanceRetentionScheduleId",
    "governanceRetentionRecordClass",
    "governanceRetentionScheduleDigest",
    "auditEventId",
    "completedAt",
    "receiptDigest",
    "replayed",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WorkflowJobRoute {
    EventDelivery,
    PrivacyResponsePartyNameCorrection,
    R6dEntityRetention,
    R6dPersonRetention,
}

#[derive(Debug)]
struct R6dPersonRetentionPayload<'a> {
    context_id: Uuid,
    person_node_id: Uuid,
    topology_digest: &'a str,
    schedule_id: Uuid,
    schedule_revision: i64,
    schedule_digest: &'a str,
    trigger_kind: &'a str,
    trigger_at: time::OffsetDateTime,
    due_at: time::OffsetDateTime,
    context_state_digest: &'a str,
    request_id: Uuid,
    idempotency_key_sha256: &'a str,
    request_digest: &'a str,
}

#[derive(Debug)]
struct R6dPersonRetentionResult<'a> {
    job_id: Uuid,
    job_fencing_token: i64,
    job_lease_token_sha256: &'a str,
    job_payload_digest: &'a str,
    context_id: Uuid,
    person_node_id: Uuid,
    topology_digest: &'a str,
    context_state_digest: &'a str,
    schedule_id: Uuid,
    schedule_revision: i64,
    schedule_digest: &'a str,
    trigger_kind: &'a str,
    trigger_at: time::OffsetDateTime,
    due_at: time::OffsetDateTime,
    request_id: Uuid,
    idempotency_key_sha256: &'a str,
    request_digest: &'a str,
    receipt_digest: &'a str,
    replayed: bool,
}

async fn handle_workflow_job(
    pool: &PgPool,
    store: &Store,
    scanner: &ClamAvScanner,
    field_keys: &EnvelopeKeyRing,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    match workflow_job_route(&job.job_type)? {
        WorkflowJobRoute::EventDelivery => {
            handle_event(pool, store, scanner, field_keys, job).await
        }
        WorkflowJobRoute::PrivacyResponsePartyNameCorrection => {
            execute_privacy_response_party_name_correction(pool, field_keys, job).await
        }
        WorkflowJobRoute::R6dEntityRetention => execute_r6d_entity_retention(pool, job).await,
        WorkflowJobRoute::R6dPersonRetention => execute_r6d_person_retention(pool, job).await,
    }
}

fn workflow_job_route(job_type: &str) -> Result<WorkflowJobRoute, Failure> {
    match job_type {
        "EVENT_DELIVERY" => Ok(WorkflowJobRoute::EventDelivery),
        "PRIVACY_RESPONSE_PARTY_NAME_CORRECTION" => {
            Ok(WorkflowJobRoute::PrivacyResponsePartyNameCorrection)
        }
        "R6D_ENTITY_RETENTION" => Ok(WorkflowJobRoute::R6dEntityRetention),
        "R6D_PERSON_RETENTION" => Ok(WorkflowJobRoute::R6dPersonRetention),
        _ => Err(Failure::Terminal(
            "UNSUPPORTED_JOB_TYPE",
            job_type.to_owned(),
        )),
    }
}

async fn execute_r6d_person_retention(pool: &PgPool, job: &ClaimedJob) -> Result<Value, Failure> {
    validate_claimed_retention_job(job)?;
    let payload = parse_r6d_person_retention_payload(&job.payload)?;
    let job_payload_digest =
        retention_json_digest(&job.payload, INVALID_RETENTION_JOB, "canonicalPayload")?;
    let result = call_r6d_person_retention_owner(pool, job).await?;
    validate_r6d_person_retention_result(job, &payload, &job_payload_digest, &result)?;
    Ok(result)
}

fn validate_claimed_retention_job(job: &ClaimedJob) -> Result<(), Failure> {
    if job.queue != "workflow-worker" {
        return Err(retention_contract_failure(INVALID_RETENTION_JOB, "queue"));
    }
    if job.id.is_nil() {
        return Err(retention_contract_failure(INVALID_RETENTION_JOB, "jobId"));
    }
    if job.fence.lease_token.is_nil() {
        return Err(retention_contract_failure(
            INVALID_RETENTION_JOB,
            "leaseToken",
        ));
    }
    if job.fence.fencing_token < 1 {
        return Err(retention_contract_failure(
            INVALID_RETENTION_JOB,
            "fencingToken",
        ));
    }
    Ok(())
}

async fn call_r6d_person_retention_owner(
    pool: &PgPool,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    sqlx::query_scalar::<_, Value>(R6D_PERSON_RETENTION_OWNER_SQL)
        .bind(job.id)
        .bind(job.fence.lease_token)
        .bind(job.fence.fencing_token)
        .fetch_one(pool)
        .await
        .map_err(retention_owner_database_failure)
}

fn parse_r6d_person_retention_payload(
    value: &Value,
) -> Result<R6dPersonRetentionPayload<'_>, Failure> {
    let object = retention_closed_object(value, &RETENTION_JOB_KEYS, INVALID_RETENTION_JOB)?;
    retention_literal(
        object,
        "schemaVersion",
        "r6d-person-retention-job.v1",
        INVALID_RETENTION_JOB,
    )?;
    retention_literal(
        object,
        "recordClass",
        "RELATIONSHIP_PERSON_CONTEXT",
        INVALID_RETENTION_JOB,
    )?;
    let trigger_kind =
        retention_literal(object, "triggerKind", "CREATED_AT", INVALID_RETENTION_JOB)?;
    retention_literal(object, "terminalAction", "ANONYMIZE", INVALID_RETENTION_JOB)?;
    retention_one_of(
        object,
        "holdBehavior",
        &["BLOCK_ON_RETENTION", "BLOCK_ON_RETENTION_OR_DELETION"],
        INVALID_RETENTION_JOB,
    )?;
    retention_nonnegative_integer(object, "activeDurationSeconds", INVALID_RETENTION_JOB)?;
    retention_nonnegative_integer(object, "backupDurationSeconds", INVALID_RETENTION_JOB)?;
    Ok(R6dPersonRetentionPayload {
        context_id: retention_uuid(object, "contextId", INVALID_RETENTION_JOB)?,
        person_node_id: retention_uuid(object, "personNodeId", INVALID_RETENTION_JOB)?,
        topology_digest: retention_digest(object, "topologyDigest", INVALID_RETENTION_JOB)?,
        schedule_id: retention_uuid(object, "scheduleId", INVALID_RETENTION_JOB)?,
        schedule_revision: retention_positive_integer(
            object,
            "scheduleRevision",
            INVALID_RETENTION_JOB,
        )?,
        schedule_digest: retention_digest(object, "scheduleDigest", INVALID_RETENTION_JOB)?,
        trigger_kind,
        trigger_at: retention_datetime(object, "triggerAt", INVALID_RETENTION_JOB)?,
        due_at: retention_datetime(object, "dueAt", INVALID_RETENTION_JOB)?,
        context_state_digest: retention_digest(
            object,
            "contextStateDigest",
            INVALID_RETENTION_JOB,
        )?,
        request_id: retention_uuid(object, "requestId", INVALID_RETENTION_JOB)?,
        idempotency_key_sha256: retention_digest(
            object,
            "idempotencyKeySha256",
            INVALID_RETENTION_JOB,
        )?,
        request_digest: retention_digest(object, "requestDigest", INVALID_RETENTION_JOB)?,
    })
}

fn parse_r6d_person_retention_result(
    value: &Value,
) -> Result<R6dPersonRetentionResult<'_>, Failure> {
    let object = retention_closed_object(value, &RETENTION_RESULT_KEYS, INVALID_RETENTION_RESULT)?;
    retention_literal(
        object,
        "schemaVersion",
        "r6d-person-retention-execution.v1",
        INVALID_RETENTION_RESULT,
    )?;
    retention_uuid(object, "receiptId", INVALID_RETENTION_RESULT)?;
    retention_digest(object, "personNameDigest", INVALID_RETENTION_RESULT)?;
    validate_r6d_erasure_result_fields(object)?;
    Ok(R6dPersonRetentionResult {
        job_id: retention_uuid(object, "jobId", INVALID_RETENTION_RESULT)?,
        job_fencing_token: retention_positive_integer(
            object,
            "jobFencingToken",
            INVALID_RETENTION_RESULT,
        )?,
        job_lease_token_sha256: retention_digest(
            object,
            "jobLeaseTokenSha256",
            INVALID_RETENTION_RESULT,
        )?,
        job_payload_digest: retention_digest(object, "jobPayloadDigest", INVALID_RETENTION_RESULT)?,
        context_id: retention_uuid(object, "contextId", INVALID_RETENTION_RESULT)?,
        person_node_id: retention_uuid(object, "personNodeId", INVALID_RETENTION_RESULT)?,
        topology_digest: retention_digest(object, "topologyDigest", INVALID_RETENTION_RESULT)?,
        context_state_digest: retention_digest(
            object,
            "contextStateDigest",
            INVALID_RETENTION_RESULT,
        )?,
        schedule_id: retention_uuid(object, "scheduleId", INVALID_RETENTION_RESULT)?,
        schedule_revision: retention_positive_integer(
            object,
            "scheduleRevision",
            INVALID_RETENTION_RESULT,
        )?,
        schedule_digest: retention_digest(object, "scheduleDigest", INVALID_RETENTION_RESULT)?,
        trigger_kind: retention_literal(
            object,
            "triggerKind",
            "CREATED_AT",
            INVALID_RETENTION_RESULT,
        )?,
        trigger_at: retention_datetime(object, "triggerAt", INVALID_RETENTION_RESULT)?,
        due_at: retention_datetime(object, "dueAt", INVALID_RETENTION_RESULT)?,
        request_id: retention_uuid(object, "requestId", INVALID_RETENTION_RESULT)?,
        idempotency_key_sha256: retention_digest(
            object,
            "idempotencyKeySha256",
            INVALID_RETENTION_RESULT,
        )?,
        request_digest: retention_digest(object, "requestDigest", INVALID_RETENTION_RESULT)?,
        receipt_digest: retention_digest(object, "receiptDigest", INVALID_RETENTION_RESULT)?,
        replayed: retention_boolean(object, "replayed", INVALID_RETENTION_RESULT)?,
    })
}

fn validate_r6d_erasure_result_fields(
    object: &serde_json::Map<String, Value>,
) -> Result<(), Failure> {
    for field in [
        "erasureReceiptId",
        "erasureAuditEventId",
        "governanceRetentionScheduleId",
        "auditEventId",
    ] {
        retention_uuid(object, field, INVALID_RETENTION_RESULT)?;
    }
    for field in ["erasureReceiptDigest", "governanceRetentionScheduleDigest"] {
        retention_digest(object, field, INVALID_RETENTION_RESULT)?;
    }
    retention_literal(
        object,
        "erasureActorType",
        RETENTION_ERASURE_ACTOR_TYPE,
        INVALID_RETENTION_RESULT,
    )?;
    retention_literal(
        object,
        "erasureActorId",
        RETENTION_ERASURE_ACTOR_ID,
        INVALID_RETENTION_RESULT,
    )?;
    retention_literal(
        object,
        "governanceRetentionRecordClass",
        "PERSON_ERASURE_GOVERNANCE",
        INVALID_RETENTION_RESULT,
    )?;
    retention_datetime(object, "completedAt", INVALID_RETENTION_RESULT)?;
    retention_boolean(object, "replayed", INVALID_RETENTION_RESULT)?;
    Ok(())
}

fn validate_r6d_person_retention_result(
    job: &ClaimedJob,
    payload: &R6dPersonRetentionPayload<'_>,
    job_payload_digest: &str,
    value: &Value,
) -> Result<(), Failure> {
    let result = parse_r6d_person_retention_result(value)?;
    let lease_digest = sha256(job.fence.lease_token.to_string().as_bytes());
    require_retention_binding(result.job_id == job.id, "jobId")?;
    // The owner validates the current claim tuple before it can return an
    // immutable execution receipt.  On recovery after an owner commit and
    // before `Worker::complete`, that receipt still contains the prior claim's
    // fence and lease digest.  Preserve those immutable values on replay while
    // keeping the exact current-claim comparison for the first execution.
    if !result.replayed {
        require_retention_binding(
            result.job_fencing_token == job.fence.fencing_token,
            "jobFencingToken",
        )?;
        require_retention_binding(
            result.job_lease_token_sha256 == lease_digest,
            "jobLeaseTokenSha256",
        )?;
    }
    require_retention_binding(
        result.job_payload_digest == job_payload_digest,
        "jobPayloadDigest",
    )?;
    validate_r6d_payload_result_binding(payload, &result)?;
    let receipt_digest = retention_receipt_digest(value)?;
    require_retention_binding(result.receipt_digest == receipt_digest, "receiptDigest")
}

fn validate_r6d_payload_result_binding(
    payload: &R6dPersonRetentionPayload<'_>,
    result: &R6dPersonRetentionResult<'_>,
) -> Result<(), Failure> {
    require_retention_binding(result.context_id == payload.context_id, "contextId")?;
    require_retention_binding(
        result.person_node_id == payload.person_node_id,
        "personNodeId",
    )?;
    require_retention_binding(
        result.topology_digest == payload.topology_digest,
        "topologyDigest",
    )?;
    require_retention_binding(
        result.context_state_digest == payload.context_state_digest,
        "contextStateDigest",
    )?;
    require_retention_binding(result.schedule_id == payload.schedule_id, "scheduleId")?;
    require_retention_binding(
        result.schedule_revision == payload.schedule_revision,
        "scheduleRevision",
    )?;
    require_retention_binding(
        result.schedule_digest == payload.schedule_digest,
        "scheduleDigest",
    )?;
    require_retention_binding(result.trigger_kind == payload.trigger_kind, "triggerKind")?;
    require_retention_binding(result.trigger_at == payload.trigger_at, "triggerAt")?;
    require_retention_binding(result.due_at == payload.due_at, "dueAt")?;
    require_retention_binding(result.request_id == payload.request_id, "requestId")?;
    require_retention_binding(
        result.idempotency_key_sha256 == payload.idempotency_key_sha256,
        "idempotencyKeySha256",
    )?;
    require_retention_binding(
        result.request_digest == payload.request_digest,
        "requestDigest",
    )
}

fn retention_receipt_digest(value: &Value) -> Result<String, Failure> {
    let mut receipt_payload = value.clone();
    let object = receipt_payload
        .as_object_mut()
        .ok_or_else(|| retention_contract_failure(INVALID_RETENTION_RESULT, "receiptDigest"))?;
    object.remove("receiptDigest");
    object.remove("replayed");
    retention_json_digest(&receipt_payload, INVALID_RETENTION_RESULT, "receiptDigest")
}

fn retention_closed_object<'a>(
    value: &'a Value,
    keys: &[&str],
    code: &'static str,
) -> Result<&'a serde_json::Map<String, Value>, Failure> {
    let object = value
        .as_object()
        .ok_or_else(|| retention_contract_failure(code, "object"))?;
    if object.len() != keys.len() || keys.iter().any(|key| !object.contains_key(*key)) {
        return Err(retention_contract_failure(code, "keys"));
    }
    Ok(object)
}

fn retention_string<'a>(
    object: &'a serde_json::Map<String, Value>,
    field: &str,
    code: &'static str,
) -> Result<&'a str, Failure> {
    object
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| retention_contract_failure(code, field))
}

fn retention_literal<'a>(
    object: &'a serde_json::Map<String, Value>,
    field: &str,
    expected: &str,
    code: &'static str,
) -> Result<&'a str, Failure> {
    let value = retention_string(object, field, code)?;
    (value == expected)
        .then_some(value)
        .ok_or_else(|| retention_contract_failure(code, field))
}

fn retention_one_of<'a>(
    object: &'a serde_json::Map<String, Value>,
    field: &str,
    expected: &[&str],
    code: &'static str,
) -> Result<&'a str, Failure> {
    let value = retention_string(object, field, code)?;
    expected
        .contains(&value)
        .then_some(value)
        .ok_or_else(|| retention_contract_failure(code, field))
}

fn retention_uuid(
    object: &serde_json::Map<String, Value>,
    field: &str,
    code: &'static str,
) -> Result<Uuid, Failure> {
    retention_string(object, field, code)?
        .parse()
        .ok()
        .filter(|value: &Uuid| !value.is_nil())
        .ok_or_else(|| retention_contract_failure(code, field))
}

fn retention_digest<'a>(
    object: &'a serde_json::Map<String, Value>,
    field: &str,
    code: &'static str,
) -> Result<&'a str, Failure> {
    let value = retention_string(object, field, code)?;
    is_sha256(value)
        .then_some(value)
        .ok_or_else(|| retention_contract_failure(code, field))
}

fn retention_positive_integer(
    object: &serde_json::Map<String, Value>,
    field: &str,
    code: &'static str,
) -> Result<i64, Failure> {
    object
        .get(field)
        .and_then(Value::as_i64)
        .filter(|value| *value > 0)
        .ok_or_else(|| retention_contract_failure(code, field))
}

fn retention_nonnegative_integer(
    object: &serde_json::Map<String, Value>,
    field: &str,
    code: &'static str,
) -> Result<i64, Failure> {
    object
        .get(field)
        .and_then(Value::as_i64)
        .filter(|value| *value >= 0)
        .ok_or_else(|| retention_contract_failure(code, field))
}

fn retention_datetime(
    object: &serde_json::Map<String, Value>,
    field: &str,
    code: &'static str,
) -> Result<time::OffsetDateTime, Failure> {
    time::OffsetDateTime::parse(
        retention_string(object, field, code)?,
        &time::format_description::well_known::Rfc3339,
    )
    .map_err(|_| retention_contract_failure(code, field))
}

fn retention_boolean(
    object: &serde_json::Map<String, Value>,
    field: &str,
    code: &'static str,
) -> Result<bool, Failure> {
    object
        .get(field)
        .and_then(Value::as_bool)
        .ok_or_else(|| retention_contract_failure(code, field))
}

fn retention_json_digest(
    value: &Value,
    code: &'static str,
    field: &str,
) -> Result<String, Failure> {
    gurine_auth::assertion::canonical::canonical_json(value)
        .map(|canonical| sha256(&canonical))
        .map_err(|_| retention_contract_failure(code, field))
}

fn require_retention_binding(matches: bool, field: &str) -> Result<(), Failure> {
    if !matches {
        return Err(Failure::Terminal(
            "R6D_PERSON_RETENTION_BINDING_MISMATCH",
            field.to_owned(),
        ));
    }
    Ok(())
}

fn retention_contract_failure(code: &'static str, field: &str) -> Failure {
    Failure::Terminal(code, field.to_owned())
}

fn retention_owner_database_failure(error: sqlx::Error) -> Failure {
    let sqlstate = match &error {
        sqlx::Error::Database(database) => database.code().map(|value| value.into_owned()),
        _ => None,
    };
    match sqlstate.as_deref() {
        Some("22023") => Failure::Terminal(
            "R6D_PERSON_RETENTION_OWNER_REJECTED",
            "redacted:sqlstate=22023".to_owned(),
        ),
        Some("40001") => Failure::Retryable(
            "R6D_PERSON_RETENTION_OWNER_CONFLICT",
            "redacted:sqlstate=40001".to_owned(),
        ),
        Some("55000") => Failure::Retryable(
            "R6D_PERSON_RETENTION_OWNER_NOT_READY",
            "redacted:sqlstate=55000".to_owned(),
        ),
        _ => Failure::Retryable(
            "R6D_PERSON_RETENTION_OWNER_UNAVAILABLE",
            "redacted:database_error".to_owned(),
        ),
    }
}

#[cfg(test)]
include!("workflow_retention_job_tests.rs");
