#[test]
fn operation_rejection_has_its_own_permanent_terminal_kind(
) -> Result<(), EconomicsContractError> {
    let claim_value = claim_receipt(53, 59, "createTariffVersion");
    let claim = parse_economics_claim_receipt(&claim_value)?;
    let rejected_value = terminal_receipt(&claim_value, "OPERATION_REJECTED", 55, None);
    let rejected = parse_economics_terminal_receipt(&rejected_value)?;
    validate_economics_terminal_binding(
        EconomicsOwnerDisposition::OperationRejected,
        &claim,
        &rejected,
    )?;
    assert_eq!(
        economics_success_job_result(&rejected),
        Err(EconomicsContractError::JobResult("terminalKind"))
    );

    let mut wrong_code = rejected_value;
    wrong_code["errorCode"] = json!("ECONOMICS_IMPORT_CLAIM_RECEIPT_INVALID");
    let wrong_code = parse_economics_terminal_receipt(&wrong_code)?;
    assert_eq!(
        validate_economics_terminal_binding(
            EconomicsOwnerDisposition::OperationRejected,
            &claim,
            &wrong_code,
        ),
        Err(EconomicsContractError::TerminalBinding("errorCode"))
    );
    Ok(())
}

#[test]
fn terminal_replay_preserves_prior_fence_but_rebinds_immutable_authority(
) -> Result<(), EconomicsContractError> {
    let claim_value = claim_receipt(61, 67, "recordInvoice");
    let claim = parse_economics_claim_receipt(&claim_value)?;
    let (authorization, _) = claim_bindings(&claim);
    let terminal_value = terminal_receipt(&claim_value, "SUCCEEDED", 63, None);
    let terminal = parse_economics_terminal_receipt(&terminal_value)?;

    // A later producer claim may have a higher fence; immutable terminal replay
    // validates the same job identity and authority rather than rewriting it.
    assert_eq!(terminal.producer_job_fencing_token, 67);
    validate_economics_terminal_replay_binding(
        EconomicsOwnerDisposition::CompletionReplay,
        &terminal,
        authorization,
        claim.producer_job_id,
    )?;
    let changed_job = Uuid::from_u128(70);
    assert_eq!(
        validate_economics_terminal_replay_binding(
            EconomicsOwnerDisposition::CompletionReplay,
            &terminal,
            authorization,
            changed_job,
        ),
        Err(EconomicsContractError::TerminalBinding("producerJobId"))
    );
    Ok(())
}

#[test]
fn replay_receipts_converge_and_changed_bindings_do_not() -> Result<(), EconomicsContractError> {
    let claim_value = claim_receipt(17, 23, "recordCashApplication");
    let first_value = owner_result(
        "CLAIM_REPLAY",
        "ECONOMICS_IMPORT_CLAIM_REPLAYED",
        claim_value.clone(),
    );
    let first = parse_economics_owner_result(&first_value, EconomicsOwnerCall::Claim)?;
    let second_value = owner_result(
        "CLAIM_REPLAY",
        "ECONOMICS_IMPORT_CLAIM_REPLAYED",
        claim_value.clone(),
    );
    let second = parse_economics_owner_result(&second_value, EconomicsOwnerCall::Claim)?;
    let (EconomicsOwnerReceipt::Claim(first), EconomicsOwnerReceipt::Claim(_second)) =
        (first.receipt, second.receipt)
    else {
        return Err(EconomicsContractError::OwnerEnvelope("receipt"));
    };
    assert_eq!(
        first_value["receipt"]["executionReceiptId"],
        second_value["receipt"]["executionReceiptId"]
    );
    assert_eq!(
        first_value["receipt"]["executionReceiptDigest"],
        second_value["receipt"]["executionReceiptDigest"]
    );

    let mut changed = terminal_receipt(&claim_value, "SUCCEEDED", 19, None);
    changed["operationDigest"] = json!(contract_digest('9'));
    let changed = parse_economics_terminal_receipt(&changed)?;
    assert_eq!(
        validate_economics_terminal_binding(
            EconomicsOwnerDisposition::CompletionReplay,
            &first,
            &changed,
        ),
        Err(EconomicsContractError::TerminalBinding(
            "operationDigest"
        ))
    );
    Ok(())
}
