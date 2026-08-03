use super::super::{
    ECONOMICS_IMPORT_EXECUTOR_CAPABILITY, ECONOMICS_IMPORT_EXECUTOR_OPERATION,
    validate_economics_import_execution_receipt,
};
use super::execution_receipt;
use super::fixtures::{digest, uuid};
use serde_json::json;

#[test]
fn exact_executor_receipt_is_accepted_and_aliases_are_rejected() {
    assert!(validate_economics_import_execution_receipt(execution_receipt()).is_ok());
    for alias in [
        "private.ApplyEconomicsImport",
        "private.executeEconomicsImport",
        "ExecuteEconomicsImport",
    ] {
        let mut receipt = execution_receipt();
        receipt["command"]["operationId"] = json!(alias);
        assert!(validate_economics_import_execution_receipt(receipt).is_err());
    }
    assert_eq!(
        ECONOMICS_IMPORT_EXECUTOR_OPERATION,
        "private.ExecuteEconomicsImport"
    );
    assert_eq!(ECONOMICS_IMPORT_EXECUTOR_CAPABILITY, "economics.import");
}

#[test]
fn execution_receipt_is_closed_at_outer_and_command_boundaries() {
    let mut outer_extra = execution_receipt();
    outer_extra["opaqueProviderBody"] = json!({});
    assert!(validate_economics_import_execution_receipt(outer_extra).is_err());

    let mut command_extra = execution_receipt();
    command_extra["command"]["callerApprovalDigest"] = json!(digest('a'));
    assert!(validate_economics_import_execution_receipt(command_extra).is_err());

    let mut replay = execution_receipt();
    replay["command"]["idempotencyReplay"] = json!(true);
    assert!(validate_economics_import_execution_receipt(replay).is_err());
}

#[test]
fn terminal_kind_is_the_exact_closed_owner_disposition_set() {
    for terminal_kind in ["SUCCEEDED", "OPERATION_REJECTED", "PERMANENT_FAILED"] {
        let mut receipt = execution_receipt();
        receipt["terminalKind"] = json!(terminal_kind);
        assert!(validate_economics_import_execution_receipt(receipt).is_ok());
    }

    for nonterminal in ["RECONCILIATION_REQUIRED", "PARTIALLY_SUCCEEDED", "RUNNING"] {
        let mut receipt = execution_receipt();
        receipt["terminalKind"] = json!(nonterminal);
        assert!(validate_economics_import_execution_receipt(receipt).is_err());
    }

    let mut stale_state_alias = execution_receipt();
    stale_state_alias
        .as_object_mut()
        .expect("TEST_FIXTURE receipt")
        .remove("terminalKind");
    stale_state_alias["state"] = json!("SUCCEEDED");
    assert!(validate_economics_import_execution_receipt(stale_state_alias).is_err());
}

#[test]
fn resulting_object_binding_is_all_or_none() {
    let mut partial = execution_receipt();
    partial["resultingObjectId"] = json!(uuid(2_001));
    assert!(validate_economics_import_execution_receipt(partial).is_err());

    let mut complete = execution_receipt();
    complete["resultingObjectId"] = json!(uuid(2_001));
    complete["resultingObjectVersion"] = json!(1);
    complete["resultingObjectDigest"] = json!(digest('b'));
    assert!(validate_economics_import_execution_receipt(complete).is_ok());
}
