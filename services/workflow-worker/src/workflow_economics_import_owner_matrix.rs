#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EconomicsOwnerCall {
    Claim,
    Complete,
    Fail,
}

fn economics_owner_code_is_allowed(
    call: EconomicsOwnerCall,
    disposition: EconomicsOwnerDisposition,
    code: &str,
) -> bool {
    let allowed: &[&str] = match (call, disposition) {
        (EconomicsOwnerCall::Claim, EconomicsOwnerDisposition::Claimed) => {
            &["ECONOMICS_IMPORT_EXECUTION_CLAIMED"]
        }
        (EconomicsOwnerCall::Claim, EconomicsOwnerDisposition::ClaimReplay) => {
            &["ECONOMICS_IMPORT_CLAIM_REPLAYED"]
        }
        (EconomicsOwnerCall::Claim, EconomicsOwnerDisposition::CompletionReplay)
        | (EconomicsOwnerCall::Complete, EconomicsOwnerDisposition::CompletionReplay)
        | (EconomicsOwnerCall::Fail, EconomicsOwnerDisposition::CompletionReplay) => {
            &["ECONOMICS_IMPORT_COMPLETION_REPLAYED"]
        }
        (EconomicsOwnerCall::Claim, EconomicsOwnerDisposition::OperationRejected)
        | (EconomicsOwnerCall::Complete, EconomicsOwnerDisposition::OperationRejected)
        | (EconomicsOwnerCall::Fail, EconomicsOwnerDisposition::OperationRejected) => {
            &["ECONOMICS_IMPORT_OPERATION_REJECTED"]
        }
        (EconomicsOwnerCall::Claim, EconomicsOwnerDisposition::FailureReplay)
        | (EconomicsOwnerCall::Complete, EconomicsOwnerDisposition::FailureReplay)
        | (EconomicsOwnerCall::Fail, EconomicsOwnerDisposition::FailureReplay) => {
            &["ECONOMICS_IMPORT_FAILURE_REPLAYED"]
        }
        (_, EconomicsOwnerDisposition::ProducerFenceStale) => {
            &["ECONOMICS_IMPORT_PRODUCER_FENCE_STALE"]
        }
        (_, EconomicsOwnerDisposition::ProducerLeaseExpired) => {
            &["ECONOMICS_IMPORT_PRODUCER_LEASE_EXPIRED"]
        }
        (_, EconomicsOwnerDisposition::AuthorizationExpired) => {
            &["ECONOMICS_IMPORT_AUTHORIZATION_EXPIRED"]
        }
        (_, EconomicsOwnerDisposition::ExecutionNotClaimable) => {
            &["ECONOMICS_IMPORT_EXECUTION_NOT_CLAIMABLE"]
        }
        (EconomicsOwnerCall::Claim, EconomicsOwnerDisposition::IdempotencyConflict) => {
            &["ECONOMICS_IMPORT_IDEMPOTENCY_CONFLICT"]
        }
        (EconomicsOwnerCall::Claim, EconomicsOwnerDisposition::BindingRejected) => &[
            "ECONOMICS_IMPORT_CLAIM_BINDING_REJECTED",
            "ECONOMICS_IMPORT_TERMINAL_RECEIPT_BINDING_REJECTED",
            "ECONOMICS_IMPORT_CLAIM_RECEIPT_BINDING_REJECTED",
            "ECONOMICS_IMPORT_CLAIM_CHAIN_REJECTED",
        ],
        (EconomicsOwnerCall::Fail, EconomicsOwnerDisposition::BindingRejected) => {
            &["ECONOMICS_IMPORT_FAILURE_BINDING_REJECTED"]
        }
        (EconomicsOwnerCall::Complete, EconomicsOwnerDisposition::BindingRejected) => {
            &["ECONOMICS_IMPORT_COMPLETION_BINDING_REJECTED"]
        }
        (EconomicsOwnerCall::Complete, EconomicsOwnerDisposition::Completed) => {
            &["ECONOMICS_IMPORT_EXECUTION_COMPLETED"]
        }
        (EconomicsOwnerCall::Fail, EconomicsOwnerDisposition::Failed) => {
            &["ECONOMICS_IMPORT_EXECUTION_FAILED"]
        }
        _ => &[],
    };
    allowed.contains(&code)
}

fn economics_terminal_error_code_is_allowed(
    disposition: EconomicsOwnerDisposition,
    code: Option<&str>,
) -> bool {
    match disposition {
        EconomicsOwnerDisposition::Completed | EconomicsOwnerDisposition::CompletionReplay => {
            code.is_none()
        }
        EconomicsOwnerDisposition::OperationRejected => {
            code == Some("ECONOMICS_IMPORT_OPERATION_REJECTED")
        }
        EconomicsOwnerDisposition::Failed | EconomicsOwnerDisposition::FailureReplay => code
            .is_some_and(|value| {
                [
                    "ECONOMICS_IMPORT_CLAIM_RECEIPT_INVALID",
                    "ECONOMICS_IMPORT_TARGET_DECRYPTION_FAILED",
                    "ECONOMICS_IMPORT_TARGET_PAYLOAD_INVALID",
                    "ECONOMICS_IMPORT_TARGET_BINDING_INVALID",
                    "ECONOMICS_IMPORT_OPERATION_CONTRACT_INVALID",
                ]
                .contains(&value)
            }),
        _ => false,
    }
}
