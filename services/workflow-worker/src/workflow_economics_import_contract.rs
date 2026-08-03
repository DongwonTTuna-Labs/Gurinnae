include!("workflow_economics_import_contract_schema.rs");

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EconomicsOperation {
    RecordCommercialQualification,
    ImportCostAllocationClose,
    CreateTariffVersion,
    RecordCommercialContractPeriod,
    RecordUsageWindow,
    RecordInvoice,
    RecordRevenue,
    RecordAccountingCorrection,
    RecordCashApplication,
    RecordTaxInvoiceIssuance,
    RecordCollectionFailure,
}

impl EconomicsOperation {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "recordCommercialQualification" => Some(Self::RecordCommercialQualification),
            "importCostAllocationClose" => Some(Self::ImportCostAllocationClose),
            "createTariffVersion" => Some(Self::CreateTariffVersion),
            "recordCommercialContractPeriod" => Some(Self::RecordCommercialContractPeriod),
            "recordUsageWindow" => Some(Self::RecordUsageWindow),
            "recordInvoice" => Some(Self::RecordInvoice),
            "recordRevenue" => Some(Self::RecordRevenue),
            "recordAccountingCorrection" => Some(Self::RecordAccountingCorrection),
            "recordCashApplication" => Some(Self::RecordCashApplication),
            "recordTaxInvoiceIssuance" => Some(Self::RecordTaxInvoiceIssuance),
            "recordCollectionFailure" => Some(Self::RecordCollectionFailure),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EconomicsOwnerDisposition {
    Claimed,
    ClaimReplay,
    Completed,
    CompletionReplay,
    Failed,
    FailureReplay,
    ProducerFenceStale,
    ProducerLeaseExpired,
    AuthorizationExpired,
    ExecutionNotClaimable,
    BindingRejected,
    IdempotencyConflict,
    OperationRejected,
}

impl EconomicsOwnerDisposition {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "CLAIMED" => Some(Self::Claimed),
            "CLAIM_REPLAY" => Some(Self::ClaimReplay),
            "COMPLETED" => Some(Self::Completed),
            "COMPLETION_REPLAY" => Some(Self::CompletionReplay),
            "FAILED" => Some(Self::Failed),
            "FAILURE_REPLAY" => Some(Self::FailureReplay),
            "PRODUCER_FENCE_STALE" => Some(Self::ProducerFenceStale),
            "PRODUCER_LEASE_EXPIRED" => Some(Self::ProducerLeaseExpired),
            "AUTHORIZATION_EXPIRED" => Some(Self::AuthorizationExpired),
            "EXECUTION_NOT_CLAIMABLE" => Some(Self::ExecutionNotClaimable),
            "BINDING_REJECTED" => Some(Self::BindingRejected),
            "IDEMPOTENCY_CONFLICT" => Some(Self::IdempotencyConflict),
            "OPERATION_REJECTED" => Some(Self::OperationRejected),
            _ => None,
        }
    }

    fn is_claim(self) -> bool {
        matches!(self, Self::Claimed | Self::ClaimReplay)
    }

    fn is_success(self) -> bool {
        matches!(self, Self::Completed | Self::CompletionReplay)
    }

    fn is_permanent_failure(self) -> bool {
        matches!(
            self,
            Self::Failed | Self::FailureReplay | Self::OperationRejected
        )
    }

    fn is_contract_failure(self) -> bool {
        matches!(self, Self::Failed | Self::FailureReplay)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EconomicsTerminalKind {
    Succeeded,
    OperationRejected,
    PermanentFailed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EconomicsContractError {
    OwnerEnvelope(&'static str),
    ClaimReceipt(&'static str),
    ClaimBinding(&'static str),
    TerminalReceipt(&'static str),
    TerminalBinding(&'static str),
    JobResult(&'static str),
}

#[derive(Debug)]
struct EconomicsClaimReceipt<'a> {
    producer_job_id: Uuid,
    producer_job_fencing_token: i64,
    producer_job_lease_expires_at: time::OffsetDateTime,
    event_id: Uuid,
    execution_id: Uuid,
    generation: i64,
    attempt_id: Uuid,
    execution_fencing_token: i64,
    execution_digest: &'a str,
    approval_digest: &'a str,
    counted_decision_set_digest: &'a str,
    terminal_decision_receipt_digest: &'a str,
    effect_idempotency_key_sha256: &'a str,
    action_detail_digest: &'a str,
    target_request_sha256: &'a str,
    operation: EconomicsOperation,
    operation_digest: &'a str,
    source_evidence_set_digest: &'a str,
    import_policy_digest: &'a str,
    as_of: time::OffsetDateTime,
    authorization_expires_at: time::OffsetDateTime,
    execution_receipt_sequence: i64,
}

#[derive(Debug)]
struct EconomicsTerminalReceipt<'a> {
    terminal_kind: EconomicsTerminalKind,
    producer_job_id: Uuid,
    producer_job_fencing_token: i64,
    event_id: Uuid,
    execution_id: Uuid,
    generation: i64,
    attempt_id: Uuid,
    execution_fencing_token: i64,
    execution_digest: &'a str,
    approval_digest: &'a str,
    counted_decision_set_digest: &'a str,
    terminal_decision_receipt_digest: &'a str,
    effect_idempotency_key_sha256: &'a str,
    action_detail_digest: &'a str,
    target_request_sha256: &'a str,
    operation: EconomicsOperation,
    operation_digest: &'a str,
    source_evidence_set_digest: &'a str,
    import_policy_digest: &'a str,
    as_of: time::OffsetDateTime,
    authorization_expires_at: time::OffsetDateTime,
    result_set_digest: Option<&'a str>,
    error_code: Option<&'a str>,
    error_detail_digest: Option<&'a str>,
    execution_receipt_id: Uuid,
    execution_receipt_sequence: i64,
    execution_receipt_digest: &'a str,
    notification_outbox_event_id: Option<Uuid>,
}

#[derive(Debug)]
enum EconomicsOwnerReceipt<'a> {
    Claim(EconomicsClaimReceipt<'a>),
    Terminal(EconomicsTerminalReceipt<'a>),
    Empty,
}

#[derive(Debug)]
struct EconomicsOwnerResult<'a> {
    disposition: EconomicsOwnerDisposition,
    receipt: EconomicsOwnerReceipt<'a>,
}

fn parse_economics_owner_result(
    value: &Value,
    call: EconomicsOwnerCall,
) -> Result<EconomicsOwnerResult<'_>, EconomicsContractError> {
    let object = economics_exact_object(
        value,
        &ECONOMICS_OWNER_RESULT_KEYS,
        EconomicsContractError::OwnerEnvelope,
    )?;
    economics_literal(
        object,
        "schemaVersion",
        "economics-import-owner-result.v1",
        EconomicsContractError::OwnerEnvelope,
    )?;
    if object.get("retryable").and_then(Value::as_bool) != Some(false) {
        return Err(EconomicsContractError::OwnerEnvelope("retryable"));
    }
    let disposition = economics_string(
        object,
        "disposition",
        EconomicsContractError::OwnerEnvelope,
    )
    .and_then(|value| {
        EconomicsOwnerDisposition::parse(value)
            .ok_or(EconomicsContractError::OwnerEnvelope("disposition"))
    })?;
    let code = economics_string(object, "code", EconomicsContractError::OwnerEnvelope)?;
    if !economics_owner_code_is_allowed(call, disposition, code) {
        return Err(EconomicsContractError::OwnerEnvelope("code"));
    }
    let receipt_value = object
        .get("receipt")
        .ok_or(EconomicsContractError::OwnerEnvelope("receipt"))?;
    let receipt = if disposition.is_claim() {
        EconomicsOwnerReceipt::Claim(parse_economics_claim_receipt(receipt_value)?)
    } else if disposition.is_success() || disposition.is_permanent_failure() {
        EconomicsOwnerReceipt::Terminal(parse_economics_terminal_receipt(receipt_value)?)
    } else if receipt_value.as_object().is_some_and(serde_json::Map::is_empty) {
        EconomicsOwnerReceipt::Empty
    } else {
        return Err(EconomicsContractError::OwnerEnvelope("receipt"));
    };
    Ok(EconomicsOwnerResult {
        disposition,
        receipt,
    })
}

fn parse_economics_claim_receipt(
    value: &Value,
) -> Result<EconomicsClaimReceipt<'_>, EconomicsContractError> {
    let error = EconomicsContractError::ClaimReceipt;
    let object = economics_exact_object(value, &ECONOMICS_CLAIM_RECEIPT_KEYS, error)?;
    economics_literal(
        object,
        "schemaVersion",
        "economics-import-claim-receipt.v1",
        error,
    )?;
    economics_uuid(object, "executionReceiptId", error)?;
    economics_digest(object, "executionReceiptDigest", error)?;
    Ok(EconomicsClaimReceipt {
        producer_job_id: economics_uuid(object, "producerJobId", error)?,
        producer_job_fencing_token: economics_positive(object, "producerJobFencingToken", error)?,
        producer_job_lease_expires_at: economics_datetime(
            object,
            "producerJobLeaseExpiresAt",
            error,
        )?,
        event_id: economics_uuid(object, "eventId", error)?,
        execution_id: economics_uuid(object, "executionId", error)?,
        generation: economics_positive(object, "generation", error)?,
        attempt_id: economics_uuid(object, "attemptId", error)?,
        execution_fencing_token: economics_positive(object, "executionFencingToken", error)?,
        execution_digest: economics_digest(object, "executionDigest", error)?,
        approval_digest: economics_digest(object, "approvalDigest", error)?,
        counted_decision_set_digest: economics_digest(object, "countedDecisionSetDigest", error)?,
        terminal_decision_receipt_digest: economics_digest(
            object,
            "terminalDecisionReceiptDigest",
            error,
        )?,
        effect_idempotency_key_sha256: economics_digest(
            object,
            "effectIdempotencyKeySha256",
            error,
        )?,
        action_detail_digest: economics_digest(object, "actionDetailDigest", error)?,
        target_request_sha256: economics_digest(object, "targetRequestSha256", error)?,
        operation: economics_operation(object, error)?,
        operation_digest: economics_digest(object, "operationDigest", error)?,
        source_evidence_set_digest: economics_digest(object, "sourceEvidenceSetDigest", error)?,
        import_policy_digest: economics_digest(object, "importPolicyDigest", error)?,
        as_of: economics_datetime(object, "asOf", error)?,
        authorization_expires_at: economics_datetime(object, "authorizationExpiresAt", error)?,
        execution_receipt_sequence: economics_positive(object, "executionReceiptSequence", error)?,
    })
}

fn parse_economics_terminal_receipt(
    value: &Value,
) -> Result<EconomicsTerminalReceipt<'_>, EconomicsContractError> {
    let error = EconomicsContractError::TerminalReceipt;
    let object = economics_exact_object(value, &ECONOMICS_TERMINAL_RECEIPT_KEYS, error)?;
    economics_literal(
        object,
        "schemaVersion",
        "economics-import-terminal-receipt.v1",
        error,
    )?;
    let terminal_kind = match economics_string(object, "terminalKind", error)? {
        "SUCCEEDED" => EconomicsTerminalKind::Succeeded,
        "OPERATION_REJECTED" => EconomicsTerminalKind::OperationRejected,
        "PERMANENT_FAILED" => EconomicsTerminalKind::PermanentFailed,
        _ => return Err(error("terminalKind")),
    };
    economics_uuid(object, "auditEventId", error)?;
    economics_uuid(object, "outboxEventId", error)?;
    economics_datetime(object, "occurredAt", error)?;
    Ok(EconomicsTerminalReceipt {
        terminal_kind,
        producer_job_id: economics_uuid(object, "producerJobId", error)?,
        producer_job_fencing_token: economics_positive(object, "producerJobFencingToken", error)?,
        event_id: economics_uuid(object, "eventId", error)?,
        execution_id: economics_uuid(object, "executionId", error)?,
        generation: economics_positive(object, "generation", error)?,
        attempt_id: economics_uuid(object, "attemptId", error)?,
        execution_fencing_token: economics_positive(object, "executionFencingToken", error)?,
        execution_digest: economics_digest(object, "executionDigest", error)?,
        approval_digest: economics_digest(object, "approvalDigest", error)?,
        counted_decision_set_digest: economics_digest(object, "countedDecisionSetDigest", error)?,
        terminal_decision_receipt_digest: economics_digest(
            object,
            "terminalDecisionReceiptDigest",
            error,
        )?,
        effect_idempotency_key_sha256: economics_digest(
            object,
            "effectIdempotencyKeySha256",
            error,
        )?,
        action_detail_digest: economics_digest(object, "actionDetailDigest", error)?,
        target_request_sha256: economics_digest(object, "targetRequestSha256", error)?,
        operation: economics_operation(object, error)?,
        operation_digest: economics_digest(object, "operationDigest", error)?,
        source_evidence_set_digest: economics_digest(object, "sourceEvidenceSetDigest", error)?,
        import_policy_digest: economics_digest(object, "importPolicyDigest", error)?,
        as_of: economics_datetime(object, "asOf", error)?,
        authorization_expires_at: economics_datetime(object, "authorizationExpiresAt", error)?,
        result_set_digest: economics_optional_digest(object, "resultSetDigest", error)?,
        error_code: economics_optional_string(object, "errorCode", error)?,
        error_detail_digest: economics_optional_digest(object, "errorDetailDigest", error)?,
        execution_receipt_id: economics_uuid(object, "executionReceiptId", error)?,
        execution_receipt_sequence: economics_positive(object, "executionReceiptSequence", error)?,
        execution_receipt_digest: economics_digest(object, "executionReceiptDigest", error)?,
        notification_outbox_event_id: economics_optional_uuid(
            object,
            "notificationOutboxEventId",
            error,
        )?,
    })
}

include!("workflow_economics_import_contract_support.rs");
include!("workflow_economics_import_contract_validation.rs");
include!("workflow_economics_import_contract_job_result.rs");
include!("workflow_economics_import_owner_matrix.rs");
