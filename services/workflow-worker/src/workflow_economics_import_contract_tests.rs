use std::collections::BTreeSet;

use super::*;

fn contract_digest(byte: char) -> String {
    std::iter::repeat_n(byte, 64).collect()
}

fn contract_uuid(value: u128) -> String {
    Uuid::from_u128(value).to_string()
}

fn claim_receipt(sequence: i64, fencing_token: i64, operation_id: &str) -> Value {
    json!({
        "schemaVersion":"economics-import-claim-receipt.v1",
        "producerJobId":contract_uuid(1),
        "producerJobFencingToken":fencing_token,
        "producerJobLeaseExpiresAt":"2030-01-01T00:00:00Z",
        "eventId":contract_uuid(2),
        "executionId":contract_uuid(3),
        "generation":4,
        "attemptId":contract_uuid(5),
        "executionFencingToken":fencing_token,
        "executionDigest":contract_digest('a'),
        "approvalDigest":contract_digest('b'),
        "countedDecisionSetDigest":contract_digest('c'),
        "terminalDecisionReceiptDigest":contract_digest('d'),
        "effectIdempotencyKeySha256":contract_digest('e'),
        "actionDetailDigest":contract_digest('f'),
        "targetRequestSha256":contract_digest('1'),
        "operationId":operation_id,
        "operationDigest":contract_digest('2'),
        "sourceEvidenceSetDigest":contract_digest('3'),
        "importPolicyDigest":contract_digest('4'),
        "asOf":"2026-08-02T00:00:00Z",
        "authorizationExpiresAt":"2031-01-01T00:00:00Z",
        "executionReceiptId":contract_uuid(6),
        "executionReceiptSequence":sequence,
        "executionReceiptDigest":contract_digest('5'),
    })
}

fn terminal_receipt(
    claim: &Value,
    terminal_kind: &str,
    sequence: i64,
    notification: Option<Uuid>,
) -> Value {
    let mut receipt = claim.as_object().cloned().unwrap_or_default();
    receipt.remove("producerJobLeaseExpiresAt");
    receipt.insert(
        "schemaVersion".to_owned(),
        json!("economics-import-terminal-receipt.v1"),
    );
    receipt.insert("terminalKind".to_owned(), json!(terminal_kind));
    let succeeded = terminal_kind == "SUCCEEDED";
    receipt.insert(
        "resultSetDigest".to_owned(),
        if succeeded {
            json!(contract_digest('6'))
        } else {
            Value::Null
        },
    );
    receipt.insert(
        "errorCode".to_owned(),
        match terminal_kind {
            "SUCCEEDED" => Value::Null,
            "OPERATION_REJECTED" => json!("ECONOMICS_IMPORT_OPERATION_REJECTED"),
            _ => json!("ECONOMICS_IMPORT_CLAIM_RECEIPT_INVALID"),
        },
    );
    receipt.insert(
        "errorDetailDigest".to_owned(),
        if succeeded {
            Value::Null
        } else {
            json!(contract_digest('7'))
        },
    );
    receipt.insert("executionReceiptId".to_owned(), json!(contract_uuid(7)));
    receipt.insert("executionReceiptSequence".to_owned(), json!(sequence));
    receipt.insert(
        "executionReceiptDigest".to_owned(),
        json!(contract_digest('8')),
    );
    receipt.insert("auditEventId".to_owned(), json!(contract_uuid(8)));
    receipt.insert("outboxEventId".to_owned(), json!(contract_uuid(9)));
    receipt.insert("notificationOutboxEventId".to_owned(), json!(notification));
    receipt.insert("occurredAt".to_owned(), json!("2030-01-01T00:00:01Z"));
    Value::Object(receipt)
}

fn owner_result(disposition: &str, code: &str, receipt: Value) -> Value {
    json!({
        "schemaVersion":"economics-import-owner-result.v1",
        "disposition":disposition,
        "retryable":false,
        "code":code,
        "receipt":receipt,
    })
}

fn claim_bindings<'a>(
    claim: &'a EconomicsClaimReceipt<'a>,
) -> (EconomicsAuthorizationBinding<'a>, EconomicsProducerBinding) {
    (
        EconomicsAuthorizationBinding {
            event_id: claim.event_id,
            execution_id: claim.execution_id,
            generation: claim.generation,
            decision_digest: claim.terminal_decision_receipt_digest,
            execution_digest: claim.execution_digest,
            target_request_sha256: claim.target_request_sha256,
            expires_at: claim.authorization_expires_at,
        },
        EconomicsProducerBinding {
            job_id: claim.producer_job_id,
            fencing_token: claim.producer_job_fencing_token,
            lease_expires_at: claim.producer_job_lease_expires_at,
        },
    )
}

#[test]
fn economics_operation_catalog_is_exactly_the_frozen_eleven() {
    let operations = [
        "recordCommercialQualification",
        "importCostAllocationClose",
        "createTariffVersion",
        "recordCommercialContractPeriod",
        "recordUsageWindow",
        "recordInvoice",
        "recordRevenue",
        "recordAccountingCorrection",
        "recordCashApplication",
        "recordTaxInvoiceIssuance",
        "recordCollectionFailure",
    ];
    assert_eq!(operations.len(), 11);
    assert!(operations.iter().all(|value| EconomicsOperation::parse(value).is_some()));
    assert!(EconomicsOperation::parse("recordPayment").is_none());
}

#[test]
fn corrected_terminal_contract_is_a_unique_exact_32_field_set() {
    assert_eq!(ECONOMICS_CLAIM_RECEIPT_KEYS.len(), 25);
    assert_eq!(ECONOMICS_TERMINAL_RECEIPT_KEYS.len(), 32);
    let unique = ECONOMICS_TERMINAL_RECEIPT_KEYS
        .iter()
        .copied()
        .collect::<BTreeSet<_>>();
    assert_eq!(unique.len(), 32);
    assert!(unique.contains("notificationOutboxEventId"));
    assert!(unique.contains("occurredAt"));
}

#[test]
fn successful_job_result_is_the_exact_seven_key_receipt_pointer(
) -> Result<(), EconomicsContractError> {
    let claim_value = claim_receipt(31, 37, "recordRevenue");
    let terminal_value = terminal_receipt(&claim_value, "SUCCEEDED", 33, None);
    let terminal = parse_economics_terminal_receipt(&terminal_value)?;
    let projection = economics_success_job_result(&terminal)?;
    let parsed = parse_economics_success_job_result(&projection)?;
    assert_eq!(projection.as_object().map(serde_json::Map::len), Some(7));
    assert_eq!(parsed.operation, EconomicsOperation::RecordRevenue);
    assert_eq!(parsed.execution_receipt_id, terminal.execution_receipt_id);
    assert_eq!(
        parsed.execution_receipt_sequence,
        terminal.execution_receipt_sequence
    );
    assert_eq!(
        parsed.execution_receipt_digest,
        terminal.execution_receipt_digest
    );
    assert_eq!(parsed.result_set_digest, terminal.result_set_digest.unwrap_or_default());
    for forbidden in [
        "operationDigest",
        "sourceEvidenceSetDigest",
        "importPolicyDigest",
        "auditEventId",
        "outboxEventId",
    ] {
        assert!(projection.get(forbidden).is_none());
    }

    let replay_projection = economics_success_job_result(&terminal)?;
    assert_eq!(projection, replay_projection);
    Ok(())
}

#[test]
fn permanent_failure_cannot_be_projected_as_success() -> Result<(), EconomicsContractError> {
    let claim_value = claim_receipt(41, 43, "recordRevenue");
    let terminal_value = terminal_receipt(&claim_value, "PERMANENT_FAILED", 42, None);
    let terminal = parse_economics_terminal_receipt(&terminal_value)?;
    assert_eq!(
        economics_success_job_result(&terminal),
        Err(EconomicsContractError::JobResult("terminalKind"))
    );
    Ok(())
}

#[test]
fn owner_envelope_and_claim_are_closed_and_typed() -> Result<(), EconomicsContractError> {
    let receipt = claim_receipt(7, 9, "recordRevenue");
    let value = owner_result(
        "CLAIMED",
        "ECONOMICS_IMPORT_EXECUTION_CLAIMED",
        receipt.clone(),
    );
    let parsed = parse_economics_owner_result(&value, EconomicsOwnerCall::Claim)?;
    assert_eq!(parsed.disposition, EconomicsOwnerDisposition::Claimed);
    let EconomicsOwnerReceipt::Claim(claim) = parsed.receipt else {
        return Err(EconomicsContractError::OwnerEnvelope("receipt"));
    };
    assert_eq!(claim.execution_receipt_sequence, 7);
    assert!(claim.execution_fencing_token > 0);

    let mut extra = value.clone();
    extra["rawEvidence"] = json!("must-not-cross-owner-boundary");
    assert!(matches!(
        parse_economics_owner_result(&extra, EconomicsOwnerCall::Claim),
        Err(EconomicsContractError::OwnerEnvelope("keys"))
    ));
    let mut retryable = value;
    retryable["retryable"] = json!(true);
    assert!(parse_economics_owner_result(&retryable, EconomicsOwnerCall::Claim).is_err());

    let unknown_code = owner_result("CLAIMED", "UNKNOWN_CODE", receipt.clone());
    assert!(matches!(
        parse_economics_owner_result(&unknown_code, EconomicsOwnerCall::Claim),
        Err(EconomicsContractError::OwnerEnvelope("code"))
    ));

    let mut extra_claim = receipt;
    extra_claim["rawOperation"] = json!({});
    assert!(parse_economics_claim_receipt(&extra_claim).is_err());
    Ok(())
}

#[test]
fn semantic_rejection_requires_an_exact_empty_receipt() -> Result<(), EconomicsContractError> {
    let value = owner_result(
        "IDEMPOTENCY_CONFLICT",
        "ECONOMICS_IMPORT_IDEMPOTENCY_CONFLICT",
        json!({}),
    );
    let parsed = parse_economics_owner_result(&value, EconomicsOwnerCall::Claim)?;
    assert_eq!(
        parsed.disposition,
        EconomicsOwnerDisposition::IdempotencyConflict
    );
    assert!(matches!(parsed.receipt, EconomicsOwnerReceipt::Empty));

    let nonempty = owner_result(
        "ECONOMICS_IMPORT_AUTHORIZATION_EXPIRED",
        "AUTHORIZATION_EXPIRED",
        json!({"expiresAt":"redacted"}),
    );
    assert!(parse_economics_owner_result(&nonempty, EconomicsOwnerCall::Claim).is_err());
    Ok(())
}

#[test]
fn landed_claim_and_fail_code_matrices_are_closed() {
    assert!(economics_owner_code_is_allowed(
        EconomicsOwnerCall::Claim,
        EconomicsOwnerDisposition::Claimed,
        "ECONOMICS_IMPORT_EXECUTION_CLAIMED"
    ));
    assert!(economics_owner_code_is_allowed(
        EconomicsOwnerCall::Fail,
        EconomicsOwnerDisposition::Failed,
        "ECONOMICS_IMPORT_EXECUTION_FAILED"
    ));
    assert!(!economics_owner_code_is_allowed(
        EconomicsOwnerCall::Claim,
        EconomicsOwnerDisposition::Claimed,
        "ECONOMICS_IMPORT_EXECUTION_FAILED"
    ));
    assert!(!economics_owner_code_is_allowed(
        EconomicsOwnerCall::Complete,
        EconomicsOwnerDisposition::Completed,
        "UNLANDED_COMPLETE_CODE"
    ));
    assert!(economics_owner_code_is_allowed(
        EconomicsOwnerCall::Complete,
        EconomicsOwnerDisposition::Completed,
        "ECONOMICS_IMPORT_EXECUTION_COMPLETED"
    ));
}

#[test]
fn claim_binding_uses_current_reclaimed_job_fence_and_authorization(
) -> Result<(), EconomicsContractError> {
    let value = claim_receipt(13, 21, "recordInvoice");
    let claim = parse_economics_claim_receipt(&value)?;
    let (authorization, producer) = claim_bindings(&claim);
    assert!(validate_economics_claim_binding(&claim, authorization, producer).is_ok());

    let stale = EconomicsProducerBinding {
        fencing_token: 20,
        ..producer
    };
    assert_eq!(
        validate_economics_claim_binding(&claim, authorization, stale),
        Err(EconomicsContractError::ClaimBinding(
            "producerJobFencingToken"
        ))
    );
    Ok(())
}

#[test]
fn terminal_sequences_are_relative_to_dynamic_claim_sequence() -> Result<(), EconomicsContractError>
{
    let claim_value = claim_receipt(13, 21, "recordRevenue");
    let claim = parse_economics_claim_receipt(&claim_value)?;

    let completed_value = terminal_receipt(&claim_value, "SUCCEEDED", 15, None);
    let completed = parse_economics_terminal_receipt(&completed_value)?;
    validate_economics_terminal_binding(EconomicsOwnerDisposition::Completed, &claim, &completed)?;

    let failed_value = terminal_receipt(&claim_value, "PERMANENT_FAILED", 14, None);
    let failed = parse_economics_terminal_receipt(&failed_value)?;
    validate_economics_terminal_binding(EconomicsOwnerDisposition::Failed, &claim, &failed)?;

    let hard_coded = terminal_receipt(&claim_value, "SUCCEEDED", 4, None);
    let hard_coded = parse_economics_terminal_receipt(&hard_coded)?;
    assert_eq!(
        validate_economics_terminal_binding(
            EconomicsOwnerDisposition::CompletionReplay,
            &claim,
            &hard_coded,
        ),
        Err(EconomicsContractError::TerminalBinding(
            "executionReceiptSequence"
        ))
    );
    Ok(())
}

#[test]
fn terminal_shape_and_notification_are_disposition_bound() -> Result<(), EconomicsContractError> {
    let claim_value = claim_receipt(5, 8, "recordCollectionFailure");
    let claim = parse_economics_claim_receipt(&claim_value)?;
    let terminal_value = terminal_receipt(
        &claim_value,
        "SUCCEEDED",
        7,
        Some(Uuid::from_u128(10)),
    );
    let owner_value = owner_result(
        "COMPLETION_REPLAY",
        "ECONOMICS_IMPORT_COMPLETION_REPLAYED",
        terminal_value,
    );
    let owner = parse_economics_owner_result(&owner_value, EconomicsOwnerCall::Complete)?;
    let EconomicsOwnerReceipt::Terminal(terminal) = owner.receipt else {
        return Err(EconomicsContractError::OwnerEnvelope("receipt"));
    };
    validate_economics_terminal_binding(
        EconomicsOwnerDisposition::CompletionReplay,
        &claim,
        &terminal,
    )?;
    assert!(terminal.result_set_digest.is_some());
    assert!(terminal.error_code.is_none());
    assert!(!terminal.execution_receipt_id.is_nil());
    assert!(is_sha256(terminal.execution_receipt_digest));

    let missing_notification = terminal_receipt(&claim_value, "SUCCEEDED", 7, None);
    let missing_notification = parse_economics_terminal_receipt(&missing_notification)?;
    assert_eq!(
        validate_economics_terminal_binding(
            EconomicsOwnerDisposition::Completed,
            &claim,
            &missing_notification,
        ),
        Err(EconomicsContractError::TerminalBinding(
            "notificationOutboxEventId"
        ))
    );
    Ok(())
}

include!("workflow_economics_import_replay_tests.rs");
