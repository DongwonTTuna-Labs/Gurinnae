const ECONOMICS_CLAIM_RECEIPT_INVALID: &str = "ECONOMICS_IMPORT_CLAIM_RECEIPT_INVALID";
const ECONOMICS_TERMINAL_RECEIPT_INVALID: &str = "ECONOMICS_IMPORT_TERMINAL_RECEIPT_INVALID";

async fn execute_economics_owner_workflow(
    pool: &PgPool,
    authorization: EconomicsAuthorizationEvent<'_>,
    producer: ProducerJobFence,
    worker_id: &str,
) -> Result<WorkflowJobCompletion, Failure> {
    let claim_value = claim_economics_import(pool, authorization, producer, worker_id).await?;
    let owner = match parse_economics_owner_result(&claim_value, EconomicsOwnerCall::Claim) {
        Ok(owner) => owner,
        Err(_) => {
            return fail_invalid_economics_claim(pool, authorization, producer).await;
        }
    };
    resolve_economics_claim_owner(pool, authorization, producer, owner).await
}

async fn resolve_economics_claim_owner(
    pool: &PgPool,
    authorization: EconomicsAuthorizationEvent<'_>,
    producer: ProducerJobFence,
    owner: EconomicsOwnerResult<'_>,
) -> Result<WorkflowJobCompletion, Failure> {
    let disposition = owner.disposition;
    match owner.receipt {
        EconomicsOwnerReceipt::Claim(claim) => {
            let authorization_binding = economics_authorization_binding(authorization);
            let producer_binding = economics_producer_binding(producer);
            if validate_economics_claim_binding(&claim, authorization_binding, producer_binding)
                .is_err()
            {
                return fail_invalid_economics_claim(pool, authorization, producer).await;
            }
            complete_economics_import(pool, authorization, producer, &claim).await
        }
        EconomicsOwnerReceipt::Terminal(terminal) => {
            validate_economics_terminal_replay(
                disposition,
                &terminal,
                authorization,
                producer.id,
                "CLAIM",
            )?;
            Ok(WorkflowJobCompletion::OwnerTerminalized)
        }
        EconomicsOwnerReceipt::Empty => Err(economics_owner_semantic_failure(disposition)),
    }
}

async fn complete_economics_import(
    pool: &PgPool,
    authorization: EconomicsAuthorizationEvent<'_>,
    producer: ProducerJobFence,
    claim: &EconomicsClaimReceipt<'_>,
) -> Result<WorkflowJobCompletion, Failure> {
    let value = call_economics_complete(pool, authorization, producer).await?;
    let owner = parse_economics_owner_result(&value, EconomicsOwnerCall::Complete)
        .map_err(|error| economics_terminal_contract_failure("COMPLETE", error))?;
    let disposition = owner.disposition;
    let EconomicsOwnerReceipt::Terminal(terminal) = owner.receipt else {
        return Err(economics_owner_semantic_failure(disposition));
    };
    validate_economics_terminal_binding(disposition, claim, &terminal)
        .map_err(|error| economics_terminal_contract_failure("COMPLETE", error))?;
    validate_economics_success_projection(&terminal)
        .map_err(|error| economics_terminal_contract_failure("COMPLETE", error))?;
    Ok(WorkflowJobCompletion::OwnerTerminalized)
}

async fn fail_invalid_economics_claim(
    pool: &PgPool,
    authorization: EconomicsAuthorizationEvent<'_>,
    producer: ProducerJobFence,
) -> Result<WorkflowJobCompletion, Failure> {
    let detail_digest = sha256(b"economics-import-claim-receipt-invalid:v1");
    let value = call_economics_fail(
        pool,
        authorization,
        producer,
        ECONOMICS_CLAIM_RECEIPT_INVALID,
        &detail_digest,
    )
    .await?;
    let owner = parse_economics_owner_result(&value, EconomicsOwnerCall::Fail)
        .map_err(|error| economics_terminal_contract_failure("FAIL", error))?;
    let disposition = owner.disposition;
    match owner.receipt {
        EconomicsOwnerReceipt::Terminal(terminal) => {
            validate_economics_terminal_replay(
                disposition,
                &terminal,
                authorization,
                producer.id,
                "FAIL",
            )?;
            Ok(WorkflowJobCompletion::OwnerTerminalized)
        }
        EconomicsOwnerReceipt::Empty => Err(economics_owner_semantic_failure(disposition)),
        EconomicsOwnerReceipt::Claim(_) => Err(economics_terminal_contract_failure(
            "FAIL",
            EconomicsContractError::OwnerEnvelope("receipt"),
        )),
    }
}

fn validate_economics_terminal_replay(
    disposition: EconomicsOwnerDisposition,
    terminal: &EconomicsTerminalReceipt<'_>,
    authorization: EconomicsAuthorizationEvent<'_>,
    producer_job_id: Uuid,
    phase: &'static str,
) -> Result<(), Failure> {
    validate_economics_terminal_replay_binding(
        disposition,
        terminal,
        economics_authorization_binding(authorization),
        producer_job_id,
    )
    .and_then(|()| validate_economics_success_projection(terminal))
    .map_err(|error| economics_terminal_contract_failure(phase, error))
}

fn validate_economics_success_projection(
    terminal: &EconomicsTerminalReceipt<'_>,
) -> Result<(), EconomicsContractError> {
    if terminal.terminal_kind != EconomicsTerminalKind::Succeeded {
        return Ok(());
    }
    let projection = economics_success_job_result(terminal)?;
    let parsed = parse_economics_success_job_result(&projection)?;
    let result_set_digest = terminal
        .result_set_digest
        .ok_or(EconomicsContractError::JobResult("resultSetDigest"))?;
    for (matches, field) in [
        (parsed.operation == terminal.operation, "operationId"),
        (
            parsed.execution_receipt_id == terminal.execution_receipt_id,
            "executionReceiptId",
        ),
        (
            parsed.execution_receipt_sequence == terminal.execution_receipt_sequence,
            "executionReceiptSequence",
        ),
        (
            parsed.execution_receipt_digest == terminal.execution_receipt_digest,
            "executionReceiptDigest",
        ),
        (
            parsed.result_set_digest == result_set_digest,
            "resultSetDigest",
        ),
    ] {
        if !matches {
            return Err(EconomicsContractError::JobResult(field));
        }
    }
    Ok(())
}

async fn claim_economics_import(
    pool: &PgPool,
    authorization: EconomicsAuthorizationEvent<'_>,
    producer: ProducerJobFence,
    worker_id: &str,
) -> Result<Value, Failure> {
    let detail_digest = economics_owner_correlation_digest("CLAIM", authorization, producer);
    sqlx::query_scalar::<_, Value>(ECONOMICS_CLAIM_OWNER_SQL)
        .bind(producer.id)
        .bind(producer.lease_token)
        .bind(producer.fencing_token)
        .bind(authorization.source_event_id)
        .bind(authorization.execution_id)
        .bind(authorization.generation)
        .bind(authorization.execution_digest)
        .bind(authorization.target_request_sha256)
        .bind(worker_id)
        .fetch_one(pool)
        .await
        .map_err(|error| economics_owner_call_failure(error, "CLAIM", detail_digest))
}

async fn call_economics_complete(
    pool: &PgPool,
    authorization: EconomicsAuthorizationEvent<'_>,
    producer: ProducerJobFence,
) -> Result<Value, Failure> {
    let detail_digest = economics_owner_correlation_digest("COMPLETE", authorization, producer);
    sqlx::query_scalar::<_, Value>(ECONOMICS_COMPLETE_OWNER_SQL)
        .bind(producer.id)
        .bind(producer.lease_token)
        .bind(producer.fencing_token)
        .bind(authorization.execution_id)
        .bind(authorization.generation)
        .bind(economics_owner_request_id(authorization))
        .fetch_one(pool)
        .await
        .map_err(|error| economics_owner_call_failure(error, "COMPLETE", detail_digest))
}

async fn call_economics_fail(
    pool: &PgPool,
    authorization: EconomicsAuthorizationEvent<'_>,
    producer: ProducerJobFence,
    error_code: &str,
    error_detail_digest: &str,
) -> Result<Value, Failure> {
    let detail_digest = economics_owner_correlation_digest("FAIL", authorization, producer);
    sqlx::query_scalar::<_, Value>(ECONOMICS_FAIL_OWNER_SQL)
        .bind(producer.id)
        .bind(producer.lease_token)
        .bind(producer.fencing_token)
        .bind(authorization.execution_id)
        .bind(authorization.generation)
        .bind(error_code)
        .bind(error_detail_digest)
        .bind(economics_owner_request_id(authorization))
        .fetch_one(pool)
        .await
        .map_err(|error| economics_owner_call_failure(error, "FAIL", detail_digest))
}

const fn economics_owner_request_id(authorization: EconomicsAuthorizationEvent<'_>) -> Uuid {
    // The authorized source event is immutable across retries. Reusing it as
    // the owner request identity prevents a commit-ack retry from inventing a
    // second request ID while keeping the execution idempotency tuple intact.
    authorization.source_event_id
}

fn economics_authorization_binding(
    authorization: EconomicsAuthorizationEvent<'_>,
) -> EconomicsAuthorizationBinding<'_> {
    EconomicsAuthorizationBinding {
        event_id: authorization.source_event_id,
        execution_id: authorization.execution_id,
        generation: authorization.generation,
        decision_digest: authorization.decision_digest,
        execution_digest: authorization.execution_digest,
        target_request_sha256: authorization.target_request_sha256,
        expires_at: authorization.expires_at,
    }
}

fn economics_producer_binding(producer: ProducerJobFence) -> EconomicsProducerBinding {
    EconomicsProducerBinding {
        job_id: producer.id,
        fencing_token: producer.fencing_token,
        lease_expires_at: producer.lease_expires_at,
    }
}

fn economics_owner_semantic_failure(disposition: EconomicsOwnerDisposition) -> Failure {
    let code = match disposition {
        EconomicsOwnerDisposition::ProducerFenceStale => "ECONOMICS_IMPORT_PRODUCER_FENCE_STALE",
        EconomicsOwnerDisposition::ProducerLeaseExpired => {
            "ECONOMICS_IMPORT_PRODUCER_LEASE_EXPIRED"
        }
        EconomicsOwnerDisposition::AuthorizationExpired => "ECONOMICS_IMPORT_AUTHORIZATION_EXPIRED",
        EconomicsOwnerDisposition::ExecutionNotClaimable => {
            "ECONOMICS_IMPORT_EXECUTION_NOT_CLAIMABLE"
        }
        EconomicsOwnerDisposition::BindingRejected => "ECONOMICS_EXECUTION_REJECTED",
        EconomicsOwnerDisposition::IdempotencyConflict => "ECONOMICS_IMPORT_IDEMPOTENCY_CONFLICT",
        _ => "ECONOMICS_EXECUTION_REJECTED",
    };
    Failure::Terminal(code, "redacted:owner-semantic-rejection".to_owned())
}

fn economics_terminal_contract_failure(
    phase: &'static str,
    error: EconomicsContractError,
) -> Failure {
    let detail = economics_contract_error_detail(phase, error);
    Failure::OwnerTerminalizedContractInvalid(ECONOMICS_TERMINAL_RECEIPT_INVALID, detail)
}

fn economics_contract_error_detail(phase: &str, error: EconomicsContractError) -> String {
    let (category, field) = match error {
        EconomicsContractError::OwnerEnvelope(field) => ("owner-envelope", field),
        EconomicsContractError::ClaimReceipt(field) => ("claim-receipt", field),
        EconomicsContractError::ClaimBinding(field) => ("claim-binding", field),
        EconomicsContractError::TerminalReceipt(field) => ("terminal-receipt", field),
        EconomicsContractError::TerminalBinding(field) => ("terminal-binding", field),
        EconomicsContractError::JobResult(field) => ("job-result", field),
    };
    sha256(format!("economics-owner-contract:v1:{phase}:{category}:{field}").as_bytes())
}

fn economics_owner_correlation_digest(
    phase: &str,
    authorization: EconomicsAuthorizationEvent<'_>,
    producer: ProducerJobFence,
) -> String {
    sha256(
        format!(
            "economics-owner-call:v1:{phase}:{}:{}:{}:{}",
            producer.id,
            producer.fencing_token,
            authorization.execution_id,
            authorization.generation,
        )
        .as_bytes(),
    )
}

fn economics_owner_call_failure(
    error: sqlx::Error,
    phase: &'static str,
    detail_digest: String,
) -> Failure {
    let sqlstate = match &error {
        sqlx::Error::Database(database) => database.code().map(|value| value.into_owned()),
        _ => None,
    };
    economics_owner_call_sqlstate_failure(sqlstate.as_deref(), phase, detail_digest)
}

fn economics_owner_call_sqlstate_failure(
    sqlstate: Option<&str>,
    phase: &'static str,
    detail_digest: String,
) -> Failure {
    match sqlstate {
        Some(value @ ("40001" | "40P01")) => Failure::Retryable(
            "ECONOMICS_DATABASE_UNAVAILABLE",
            format!("redacted:sqlstate={value}"),
        ),
        _ => Failure::OwnerOutcomeUnknown(phase, detail_digest),
    }
}
