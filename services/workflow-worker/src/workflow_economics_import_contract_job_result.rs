#[derive(Debug)]
struct EconomicsSuccessJobResult<'a> {
    operation: EconomicsOperation,
    execution_receipt_id: Uuid,
    execution_receipt_sequence: i64,
    execution_receipt_digest: &'a str,
    result_set_digest: &'a str,
}

fn economics_success_job_result(
    terminal: &EconomicsTerminalReceipt<'_>,
) -> Result<Value, EconomicsContractError> {
    if terminal.terminal_kind != EconomicsTerminalKind::Succeeded {
        return Err(EconomicsContractError::JobResult("terminalKind"));
    }
    let result_set_digest = terminal
        .result_set_digest
        .ok_or(EconomicsContractError::JobResult("resultSetDigest"))?;
    Ok(json!({
        "schemaVersion":"economics-import-job-result.v1",
        "operationId":economics_operation_id(terminal.operation),
        "terminalKind":"SUCCEEDED",
        "executionReceiptId":terminal.execution_receipt_id,
        "executionReceiptSequence":terminal.execution_receipt_sequence,
        "executionReceiptDigest":terminal.execution_receipt_digest,
        "resultSetDigest":result_set_digest,
    }))
}

fn parse_economics_success_job_result(
    value: &Value,
) -> Result<EconomicsSuccessJobResult<'_>, EconomicsContractError> {
    let error = EconomicsContractError::JobResult;
    let object = economics_exact_object(value, &ECONOMICS_JOB_RESULT_KEYS, error)?;
    economics_literal(
        object,
        "schemaVersion",
        "economics-import-job-result.v1",
        error,
    )?;
    economics_literal(object, "terminalKind", "SUCCEEDED", error)?;
    Ok(EconomicsSuccessJobResult {
        operation: economics_operation(object, error)?,
        execution_receipt_id: economics_uuid(object, "executionReceiptId", error)?,
        execution_receipt_sequence: economics_positive(
            object,
            "executionReceiptSequence",
            error,
        )?,
        execution_receipt_digest: economics_digest(object, "executionReceiptDigest", error)?,
        result_set_digest: economics_digest(object, "resultSetDigest", error)?,
    })
}

fn economics_operation_id(operation: EconomicsOperation) -> &'static str {
    match operation {
        EconomicsOperation::RecordCommercialQualification => "recordCommercialQualification",
        EconomicsOperation::ImportCostAllocationClose => "importCostAllocationClose",
        EconomicsOperation::CreateTariffVersion => "createTariffVersion",
        EconomicsOperation::RecordCommercialContractPeriod => "recordCommercialContractPeriod",
        EconomicsOperation::RecordUsageWindow => "recordUsageWindow",
        EconomicsOperation::RecordInvoice => "recordInvoice",
        EconomicsOperation::RecordRevenue => "recordRevenue",
        EconomicsOperation::RecordAccountingCorrection => "recordAccountingCorrection",
        EconomicsOperation::RecordCashApplication => "recordCashApplication",
        EconomicsOperation::RecordTaxInvoiceIssuance => "recordTaxInvoiceIssuance",
        EconomicsOperation::RecordCollectionFailure => "recordCollectionFailure",
    }
}
