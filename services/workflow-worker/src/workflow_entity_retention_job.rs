const R6D_ENTITY_RETENTION_OWNER_SQL: &str =
    "SELECT ops.execute_due_r6d_entity_retention_job_v1($1,$2,$3)";
const INVALID_ENTITY_RETENTION_JOB: &str = "INVALID_R6D_ENTITY_RETENTION_JOB";
const INVALID_ENTITY_RETENTION_RESULT: &str = "INVALID_R6D_ENTITY_RETENTION_RESULT";

const ENTITY_RETENTION_JOB_KEYS: [&str; 15] = [
    "schemaVersion",
    "entityKind",
    "entityId",
    "personhoodReceiptId",
    "personhoodReceiptDigest",
    "closureReceiptId",
    "closureReceiptDigest",
    "closureAt",
    "scheduleId",
    "scheduleRevision",
    "scheduleDigest",
    "dueAt",
    "requestDigest",
    "idempotencyDigest",
    "queuedAt",
];

const ENTITY_RETENTION_RESULT_KEYS: [&str; 15] = [
    "status",
    "jobId",
    "entityKind",
    "entityId",
    "executionReceiptId",
    "executionReceiptDigest",
    "closureReceiptId",
    "closureReceiptDigest",
    "anonymizedAt",
    "masterRowCount",
    "identifierRowCount",
    "aliasRowCount",
    "backupDisposalDueAt",
    "auditEventId",
    "replayed",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum R6dRetainedEntityKind {
    Agency,
    Supplier,
}

impl R6dRetainedEntityKind {
    fn parse(value: &str, code: &'static str) -> Result<Self, Failure> {
        match value {
            "AGENCY" => Ok(Self::Agency),
            "SUPPLIER" => Ok(Self::Supplier),
            _ => Err(entity_retention_contract_failure(code, "entityKind")),
        }
    }
}

#[derive(Debug)]
struct R6dEntityRetentionPayload<'a> {
    entity_kind: R6dRetainedEntityKind,
    entity_id: Uuid,
    closure_receipt_id: Uuid,
    closure_receipt_digest: &'a str,
    due_at: time::OffsetDateTime,
}

#[derive(Debug)]
struct R6dEntityRetentionResult<'a> {
    job_id: Uuid,
    entity_kind: R6dRetainedEntityKind,
    entity_id: Uuid,
    closure_receipt_id: Uuid,
    closure_receipt_digest: &'a str,
    anonymized_at: time::OffsetDateTime,
    backup_disposal_due_at: time::OffsetDateTime,
}

async fn execute_r6d_entity_retention(pool: &PgPool, job: &ClaimedJob) -> Result<Value, Failure> {
    validate_claimed_entity_retention_job(job)?;
    let payload = parse_r6d_entity_retention_payload(&job.payload)?;
    let result = call_r6d_entity_retention_owner(pool, job).await?;
    validate_r6d_entity_retention_result(job, &payload, &result)?;
    Ok(result)
}

fn validate_claimed_entity_retention_job(job: &ClaimedJob) -> Result<(), Failure> {
    if job.queue != "workflow-worker" {
        return Err(entity_retention_contract_failure(
            INVALID_ENTITY_RETENTION_JOB,
            "queue",
        ));
    }
    if job.id.is_nil() {
        return Err(entity_retention_contract_failure(
            INVALID_ENTITY_RETENTION_JOB,
            "jobId",
        ));
    }
    if job.fence.lease_token.is_nil() {
        return Err(entity_retention_contract_failure(
            INVALID_ENTITY_RETENTION_JOB,
            "leaseToken",
        ));
    }
    if job.fence.fencing_token < 1 {
        return Err(entity_retention_contract_failure(
            INVALID_ENTITY_RETENTION_JOB,
            "fencingToken",
        ));
    }
    Ok(())
}

async fn call_r6d_entity_retention_owner(
    pool: &PgPool,
    job: &ClaimedJob,
) -> Result<Value, Failure> {
    sqlx::query_scalar::<_, Value>(R6D_ENTITY_RETENTION_OWNER_SQL)
        .bind(job.id)
        .bind(job.fence.lease_token)
        .bind(job.fence.fencing_token)
        .fetch_one(pool)
        .await
        .map_err(entity_retention_owner_database_failure)
}

fn parse_r6d_entity_retention_payload(
    value: &Value,
) -> Result<R6dEntityRetentionPayload<'_>, Failure> {
    let object = retention_closed_object(
        value,
        &ENTITY_RETENTION_JOB_KEYS,
        INVALID_ENTITY_RETENTION_JOB,
    )?;
    retention_literal(
        object,
        "schemaVersion",
        "r6d-entity-retention-job.v1",
        INVALID_ENTITY_RETENTION_JOB,
    )?;
    let closure_at = retention_datetime(object, "closureAt", INVALID_ENTITY_RETENTION_JOB)?;
    let due_at = retention_datetime(object, "dueAt", INVALID_ENTITY_RETENTION_JOB)?;
    let queued_at = retention_datetime(object, "queuedAt", INVALID_ENTITY_RETENTION_JOB)?;
    if closure_at > due_at || due_at > queued_at {
        return Err(entity_retention_contract_failure(
            INVALID_ENTITY_RETENTION_JOB,
            "retentionTimeline",
        ));
    }
    retention_uuid(object, "personhoodReceiptId", INVALID_ENTITY_RETENTION_JOB)?;
    retention_digest(
        object,
        "personhoodReceiptDigest",
        INVALID_ENTITY_RETENTION_JOB,
    )?;
    retention_uuid(object, "scheduleId", INVALID_ENTITY_RETENTION_JOB)?;
    retention_positive_integer(object, "scheduleRevision", INVALID_ENTITY_RETENTION_JOB)?;
    retention_digest(object, "scheduleDigest", INVALID_ENTITY_RETENTION_JOB)?;
    retention_digest(object, "requestDigest", INVALID_ENTITY_RETENTION_JOB)?;
    retention_digest(object, "idempotencyDigest", INVALID_ENTITY_RETENTION_JOB)?;
    Ok(R6dEntityRetentionPayload {
        entity_kind: R6dRetainedEntityKind::parse(
            retention_string(object, "entityKind", INVALID_ENTITY_RETENTION_JOB)?,
            INVALID_ENTITY_RETENTION_JOB,
        )?,
        entity_id: retention_uuid(object, "entityId", INVALID_ENTITY_RETENTION_JOB)?,
        closure_receipt_id: retention_uuid(
            object,
            "closureReceiptId",
            INVALID_ENTITY_RETENTION_JOB,
        )?,
        closure_receipt_digest: retention_digest(
            object,
            "closureReceiptDigest",
            INVALID_ENTITY_RETENTION_JOB,
        )?,
        due_at,
    })
}

fn parse_r6d_entity_retention_result(
    value: &Value,
) -> Result<R6dEntityRetentionResult<'_>, Failure> {
    let object = retention_closed_object(
        value,
        &ENTITY_RETENTION_RESULT_KEYS,
        INVALID_ENTITY_RETENTION_RESULT,
    )?;
    retention_literal(
        object,
        "status",
        "COMPLETED",
        INVALID_ENTITY_RETENTION_RESULT,
    )?;
    retention_uuid(
        object,
        "executionReceiptId",
        INVALID_ENTITY_RETENTION_RESULT,
    )?;
    // This digest covers the owner's immutable, richer receipt payload, not
    // this deliberately narrow response envelope. Validate its encoding here;
    // the database owner validates the receipt preimage and relation binding.
    retention_digest(
        object,
        "executionReceiptDigest",
        INVALID_ENTITY_RETENTION_RESULT,
    )?;
    for field in ["masterRowCount", "identifierRowCount", "aliasRowCount"] {
        retention_nonnegative_integer(object, field, INVALID_ENTITY_RETENTION_RESULT)?;
    }
    if retention_nonnegative_integer(object, "masterRowCount", INVALID_ENTITY_RETENTION_RESULT)?
        != 1
    {
        return Err(entity_retention_contract_failure(
            INVALID_ENTITY_RETENTION_RESULT,
            "masterRowCount",
        ));
    }
    retention_uuid(object, "auditEventId", INVALID_ENTITY_RETENTION_RESULT)?;
    retention_boolean(object, "replayed", INVALID_ENTITY_RETENTION_RESULT)?;
    let anonymized_at =
        retention_datetime(object, "anonymizedAt", INVALID_ENTITY_RETENTION_RESULT)?;
    let backup_disposal_due_at = retention_datetime(
        object,
        "backupDisposalDueAt",
        INVALID_ENTITY_RETENTION_RESULT,
    )?;
    if backup_disposal_due_at <= anonymized_at {
        return Err(entity_retention_contract_failure(
            INVALID_ENTITY_RETENTION_RESULT,
            "backupDisposalDueAt",
        ));
    }
    Ok(R6dEntityRetentionResult {
        job_id: retention_uuid(object, "jobId", INVALID_ENTITY_RETENTION_RESULT)?,
        entity_kind: R6dRetainedEntityKind::parse(
            retention_string(object, "entityKind", INVALID_ENTITY_RETENTION_RESULT)?,
            INVALID_ENTITY_RETENTION_RESULT,
        )?,
        entity_id: retention_uuid(object, "entityId", INVALID_ENTITY_RETENTION_RESULT)?,
        closure_receipt_id: retention_uuid(
            object,
            "closureReceiptId",
            INVALID_ENTITY_RETENTION_RESULT,
        )?,
        closure_receipt_digest: retention_digest(
            object,
            "closureReceiptDigest",
            INVALID_ENTITY_RETENTION_RESULT,
        )?,
        anonymized_at,
        backup_disposal_due_at,
    })
}

fn validate_r6d_entity_retention_result(
    job: &ClaimedJob,
    payload: &R6dEntityRetentionPayload<'_>,
    value: &Value,
) -> Result<(), Failure> {
    let result = parse_r6d_entity_retention_result(value)?;
    require_entity_retention_binding(result.job_id == job.id, "jobId")?;
    require_entity_retention_binding(result.entity_kind == payload.entity_kind, "entityKind")?;
    require_entity_retention_binding(result.entity_id == payload.entity_id, "entityId")?;
    require_entity_retention_binding(
        result.closure_receipt_id == payload.closure_receipt_id,
        "closureReceiptId",
    )?;
    require_entity_retention_binding(
        result.closure_receipt_digest == payload.closure_receipt_digest,
        "closureReceiptDigest",
    )?;
    require_entity_retention_binding(result.anonymized_at >= payload.due_at, "anonymizedAt")?;
    require_entity_retention_binding(
        result.backup_disposal_due_at > result.anonymized_at,
        "backupDisposalDueAt",
    )?;
    Ok(())
}

fn require_entity_retention_binding(matches: bool, field: &str) -> Result<(), Failure> {
    if !matches {
        return Err(Failure::Terminal(
            "R6D_ENTITY_RETENTION_BINDING_MISMATCH",
            field.to_owned(),
        ));
    }
    Ok(())
}

fn entity_retention_contract_failure(code: &'static str, field: &str) -> Failure {
    Failure::Terminal(code, field.to_owned())
}

fn entity_retention_owner_database_failure(error: sqlx::Error) -> Failure {
    let sqlstate = match &error {
        sqlx::Error::Database(database) => database.code().map(|value| value.into_owned()),
        _ => None,
    };
    match sqlstate.as_deref() {
        Some("22023") => Failure::Terminal(
            "R6D_ENTITY_RETENTION_OWNER_REJECTED",
            "redacted:sqlstate=22023".to_owned(),
        ),
        Some("40001") => Failure::Retryable(
            "R6D_ENTITY_RETENTION_OWNER_CONFLICT",
            "redacted:sqlstate=40001".to_owned(),
        ),
        Some("55000") => Failure::Retryable(
            "R6D_ENTITY_RETENTION_OWNER_NOT_READY",
            "redacted:sqlstate=55000".to_owned(),
        ),
        _ => Failure::Retryable(
            "R6D_ENTITY_RETENTION_OWNER_UNAVAILABLE",
            "redacted:database_error".to_owned(),
        ),
    }
}

#[cfg(test)]
include!("workflow_entity_retention_job_tests.rs");
