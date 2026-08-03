#[derive(Clone, Copy)]
struct EconomicsAuthorizationBinding<'a> {
    event_id: Uuid,
    execution_id: Uuid,
    generation: i64,
    decision_digest: &'a str,
    execution_digest: &'a str,
    target_request_sha256: &'a str,
    expires_at: time::OffsetDateTime,
}

#[derive(Clone, Copy)]
struct EconomicsProducerBinding {
    job_id: Uuid,
    fencing_token: i64,
    lease_expires_at: time::OffsetDateTime,
}

fn validate_economics_claim_binding(
    claim: &EconomicsClaimReceipt<'_>,
    authorization: EconomicsAuthorizationBinding<'_>,
    producer: EconomicsProducerBinding,
) -> Result<(), EconomicsContractError> {
    for (matches, field) in [
        (claim.producer_job_id == producer.job_id, "producerJobId"),
        (
            claim.producer_job_fencing_token == producer.fencing_token,
            "producerJobFencingToken",
        ),
        (
            claim.producer_job_lease_expires_at == producer.lease_expires_at,
            "producerJobLeaseExpiresAt",
        ),
        (claim.event_id == authorization.event_id, "eventId"),
        (
            claim.execution_id == authorization.execution_id,
            "executionId",
        ),
        (
            claim.generation == authorization.generation,
            "generation",
        ),
        (
            claim.execution_digest == authorization.execution_digest,
            "executionDigest",
        ),
        (
            claim.terminal_decision_receipt_digest == authorization.decision_digest,
            "terminalDecisionReceiptDigest",
        ),
        (
            claim.target_request_sha256 == authorization.target_request_sha256,
            "targetRequestSha256",
        ),
        (
            claim.authorization_expires_at == authorization.expires_at,
            "authorizationExpiresAt",
        ),
    ] {
        if !matches {
            return Err(EconomicsContractError::ClaimBinding(field));
        }
    }
    Ok(())
}

fn validate_economics_terminal_binding(
    disposition: EconomicsOwnerDisposition,
    claim: &EconomicsClaimReceipt<'_>,
    terminal: &EconomicsTerminalReceipt<'_>,
) -> Result<(), EconomicsContractError> {
    validate_economics_terminal_disposition(disposition, terminal)?;
    validate_economics_terminal_identity_binding(claim, terminal)?;
    validate_economics_terminal_digest_binding(claim, terminal)?;
    validate_economics_terminal_sequence(disposition, claim, terminal)
}

fn validate_economics_terminal_identity_binding(
    claim: &EconomicsClaimReceipt<'_>,
    terminal: &EconomicsTerminalReceipt<'_>,
) -> Result<(), EconomicsContractError> {
    for (matches, field) in [
        (
            terminal.producer_job_id == claim.producer_job_id,
            "producerJobId",
        ),
        (
            terminal.producer_job_fencing_token == claim.producer_job_fencing_token,
            "producerJobFencingToken",
        ),
        (terminal.event_id == claim.event_id, "eventId"),
        (terminal.execution_id == claim.execution_id, "executionId"),
        (terminal.generation == claim.generation, "generation"),
        (terminal.attempt_id == claim.attempt_id, "attemptId"),
        (
            terminal.execution_fencing_token == claim.execution_fencing_token,
            "executionFencingToken",
        ),
    ] {
        if !matches {
            return Err(EconomicsContractError::TerminalBinding(field));
        }
    }
    Ok(())
}

fn validate_economics_terminal_digest_binding(
    claim: &EconomicsClaimReceipt<'_>,
    terminal: &EconomicsTerminalReceipt<'_>,
) -> Result<(), EconomicsContractError> {
    for (matches, field) in [
        (
            terminal.execution_digest == claim.execution_digest,
            "executionDigest",
        ),
        (
            terminal.approval_digest == claim.approval_digest,
            "approvalDigest",
        ),
        (
            terminal.counted_decision_set_digest == claim.counted_decision_set_digest,
            "countedDecisionSetDigest",
        ),
        (
            terminal.terminal_decision_receipt_digest
                == claim.terminal_decision_receipt_digest,
            "terminalDecisionReceiptDigest",
        ),
        (
            terminal.effect_idempotency_key_sha256 == claim.effect_idempotency_key_sha256,
            "effectIdempotencyKeySha256",
        ),
        (
            terminal.action_detail_digest == claim.action_detail_digest,
            "actionDetailDigest",
        ),
        (
            terminal.target_request_sha256 == claim.target_request_sha256,
            "targetRequestSha256",
        ),
        (terminal.operation == claim.operation, "operationId"),
        (
            terminal.operation_digest == claim.operation_digest,
            "operationDigest",
        ),
        (
            terminal.source_evidence_set_digest == claim.source_evidence_set_digest,
            "sourceEvidenceSetDigest",
        ),
        (
            terminal.import_policy_digest == claim.import_policy_digest,
            "importPolicyDigest",
        ),
        (terminal.as_of == claim.as_of, "asOf"),
        (
            terminal.authorization_expires_at == claim.authorization_expires_at,
            "authorizationExpiresAt",
        ),
    ] {
        if !matches {
            return Err(EconomicsContractError::TerminalBinding(field));
        }
    }
    Ok(())
}

fn validate_economics_terminal_sequence(
    disposition: EconomicsOwnerDisposition,
    claim: &EconomicsClaimReceipt<'_>,
    terminal: &EconomicsTerminalReceipt<'_>,
) -> Result<(), EconomicsContractError> {
    let offset = if disposition.is_success()
        || disposition == EconomicsOwnerDisposition::OperationRejected
    {
        2
    } else {
        1
    };
    let expected_sequence = claim
        .execution_receipt_sequence
        .checked_add(offset)
        .ok_or(EconomicsContractError::TerminalBinding(
            "executionReceiptSequence",
        ))?;
    if terminal.execution_receipt_sequence != expected_sequence {
        return Err(EconomicsContractError::TerminalBinding(
            "executionReceiptSequence",
        ));
    }
    Ok(())
}

fn validate_economics_terminal_disposition(
    disposition: EconomicsOwnerDisposition,
    terminal: &EconomicsTerminalReceipt<'_>,
) -> Result<(), EconomicsContractError> {
    let success_shape = terminal.result_set_digest.is_some()
        && terminal.error_code.is_none()
        && terminal.error_detail_digest.is_none();
    let failure_shape = terminal.result_set_digest.is_none()
        && terminal.error_code.is_some()
        && terminal.error_detail_digest.is_some();
    let valid = if disposition.is_success() {
        terminal.terminal_kind == EconomicsTerminalKind::Succeeded && success_shape
    } else if disposition == EconomicsOwnerDisposition::OperationRejected {
        terminal.terminal_kind == EconomicsTerminalKind::OperationRejected && failure_shape
    } else if disposition.is_contract_failure() {
        terminal.terminal_kind == EconomicsTerminalKind::PermanentFailed && failure_shape
    } else {
        false
    };
    if !valid {
        return Err(EconomicsContractError::TerminalBinding("terminalKind"));
    }
    if !economics_terminal_error_code_is_allowed(disposition, terminal.error_code) {
        return Err(EconomicsContractError::TerminalBinding("errorCode"));
    }
    let expects_notification = disposition.is_success()
        && terminal.operation == EconomicsOperation::RecordCollectionFailure;
    if terminal.notification_outbox_event_id.is_some() != expects_notification {
        return Err(EconomicsContractError::TerminalBinding(
            "notificationOutboxEventId",
        ));
    }
    Ok(())
}

fn validate_economics_terminal_replay_binding(
    disposition: EconomicsOwnerDisposition,
    terminal: &EconomicsTerminalReceipt<'_>,
    authorization: EconomicsAuthorizationBinding<'_>,
    producer_job_id: Uuid,
) -> Result<(), EconomicsContractError> {
    validate_economics_terminal_disposition(disposition, terminal)?;
    for (matches, field) in [
        (terminal.producer_job_id == producer_job_id, "producerJobId"),
        (terminal.event_id == authorization.event_id, "eventId"),
        (
            terminal.execution_id == authorization.execution_id,
            "executionId",
        ),
        (
            terminal.generation == authorization.generation,
            "generation",
        ),
        (
            terminal.execution_digest == authorization.execution_digest,
            "executionDigest",
        ),
        (
            terminal.terminal_decision_receipt_digest == authorization.decision_digest,
            "terminalDecisionReceiptDigest",
        ),
        (
            terminal.target_request_sha256 == authorization.target_request_sha256,
            "targetRequestSha256",
        ),
        (
            terminal.authorization_expires_at == authorization.expires_at,
            "authorizationExpiresAt",
        ),
    ] {
        if !matches {
            return Err(EconomicsContractError::TerminalBinding(field));
        }
    }
    Ok(())
}
