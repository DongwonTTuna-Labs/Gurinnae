const FUNDING_DISCLOSURE_ACTION_KIND: &str = "FUNDING_DISCLOSURE";
const FUNDING_DISCLOSURE_TARGET_COMMAND: &str = "private.PublishFundingDisclosureRevision";

#[derive(Clone, Copy, Debug)]
struct FundingDisclosureAuthorizationEvent<'a> {
    source_event_id: Uuid,
    execution_id: Uuid,
    generation: i64,
    decision_digest: &'a str,
    execution_digest: &'a str,
    target_request_sha256: &'a str,
    expires_at: time::OffsetDateTime,
}

impl FundingDisclosureAuthorizationEvent<'_> {
    fn is_structurally_valid(&self) -> bool {
        !self.source_event_id.is_nil()
            && !self.execution_id.is_nil()
            && self.generation > 0
            && is_sha256(self.decision_digest)
            && is_sha256(self.execution_digest)
            && is_sha256(self.target_request_sha256)
            && self.expires_at > time::OffsetDateTime::UNIX_EPOCH
    }
}

async fn execute_approved_funding_disclosure(
    source_event_id: Uuid,
    producer_job: ProducerJobFence,
    execution: &ApprovedExecution,
) -> Result<WorkflowJobCompletion, Failure> {
    let authorization = funding_disclosure_authorization_event(source_event_id, execution)?;
    if !authorization.is_structurally_valid() {
        return Err(invalid_funding_disclosure_execution(
            "authorization structure",
        ));
    }
    validate_funding_disclosure_producer_fence(producer_job)?;

    // The approved high-level GFD authority does not currently provide a
    // callable owner routine that can re-derive the locked approval detail,
    // snapshot entries and quorum from the encrypted closed request. The
    // legacy 0029 composite instead asks its caller to supply those derived
    // values. Calling it would move database-owned trust decisions into this
    // worker, so an authorized event remains non-mutating until that ABI lands.
    Err(Failure::Retryable(
        "FUNDING_DISCLOSURE_OWNER_ABI_UNAVAILABLE",
        "redacted:owner-abi-not-final".to_owned(),
    ))
}

fn funding_disclosure_authorization_event<'a>(
    source_event_id: Uuid,
    execution: &'a ApprovedExecution,
) -> Result<FundingDisclosureAuthorizationEvent<'a>, Failure> {
    if source_event_id.is_nil() {
        return Err(invalid_funding_disclosure_execution("eventId"));
    }
    let payload = execution
        .event_payload
        .as_object()
        .ok_or_else(|| invalid_funding_disclosure_execution("payload"))?;
    const KEYS: [&str; 8] = [
        "executionId",
        "generation",
        "actionKind",
        "decisionDigest",
        "executionDigest",
        "targetCommand",
        "targetRequestSha256",
        "expiresAt",
    ];
    if payload.len() != KEYS.len() || KEYS.iter().any(|key| !payload.contains_key(*key)) {
        return Err(invalid_funding_disclosure_execution("payload keys"));
    }
    if execution.execution_id.is_nil()
        || object_uuid(payload, "executionId")? != execution.execution_id
        || payload.get("generation").and_then(Value::as_i64) != Some(execution.generation)
        || payload.get("actionKind").and_then(Value::as_str) != Some(FUNDING_DISCLOSURE_ACTION_KIND)
        || payload.get("targetCommand").and_then(Value::as_str)
            != Some(FUNDING_DISCLOSURE_TARGET_COMMAND)
    {
        return Err(invalid_funding_disclosure_execution(
            "authorization binding",
        ));
    }
    Ok(FundingDisclosureAuthorizationEvent {
        source_event_id,
        execution_id: execution.execution_id,
        generation: execution.generation,
        decision_digest: funding_disclosure_authorization_digest(payload, "decisionDigest")?,
        execution_digest: funding_disclosure_authorization_digest(payload, "executionDigest")?,
        target_request_sha256: funding_disclosure_authorization_digest(
            payload,
            "targetRequestSha256",
        )?,
        expires_at: funding_disclosure_authorization_expiry(payload)?,
    })
}

fn funding_disclosure_authorization_digest<'a>(
    payload: &'a serde_json::Map<String, Value>,
    key: &'static str,
) -> Result<&'a str, Failure> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| is_sha256(value))
        .ok_or_else(|| invalid_funding_disclosure_execution(key))
}

fn funding_disclosure_authorization_expiry(
    payload: &serde_json::Map<String, Value>,
) -> Result<time::OffsetDateTime, Failure> {
    let value = payload
        .get("expiresAt")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_funding_disclosure_execution("expiresAt"))?;
    time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339)
        .map_err(|_| invalid_funding_disclosure_execution("expiresAt"))
}

fn validate_funding_disclosure_producer_fence(
    producer_job: ProducerJobFence,
) -> Result<(), Failure> {
    if producer_job.id.is_nil()
        || producer_job.lease_token.is_nil()
        || producer_job.fencing_token < 1
        || producer_job.lease_expires_at.unix_timestamp() <= 0
    {
        Err(invalid_funding_disclosure_execution("producer job fence"))
    } else {
        Ok(())
    }
}

fn invalid_funding_disclosure_execution(field: &'static str) -> Failure {
    Failure::Terminal("FUNDING_DISCLOSURE_EXECUTION_INVALID", field.to_owned())
}

#[cfg(test)]
#[path = "workflow_funding_disclosure_tests.rs"]
mod workflow_funding_disclosure_tests;
