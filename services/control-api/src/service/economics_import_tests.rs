use super::*;

#[path = "economics_import/tests/boundaries.rs"]
mod boundaries;
#[path = "economics_import/tests/decimal_wire.rs"]
mod decimal_wire;
#[path = "economics_import/tests/fixtures/mod.rs"]
mod fixtures;
#[path = "economics_import/tests/operations.rs"]
mod operations;
#[path = "economics_import/tests/receipts.rs"]
mod receipts;

fn parse_and_validate(value: Value) -> Result<EconomicsImportOperationV1, ServiceError> {
    let operation: EconomicsImportOperationV1 =
        serde_json::from_value(value).map_err(|_| ServiceError::InvalidRequest)?;
    operation.validate()?;
    Ok(operation)
}

fn execution_receipt() -> Value {
    json!({
        "command": {
            "operationId": ECONOMICS_IMPORT_EXECUTOR_OPERATION,
            "requestId": Uuid::from_u128(1),
            "status": "COMPLETED",
            "aggregateId": Uuid::from_u128(2),
            "aggregateVersion": 1,
            "auditEventId": Uuid::from_u128(3),
            "acceptedAt": "2026-08-02T00:00:00Z",
            "receiptDigest": fixtures::digest('d'),
            "emittedEventIds": [Uuid::from_u128(4)],
            "idempotencyReplay": false,
            "links": []
        },
        "actionKind": ECONOMICS_IMPORT_ACTION_KIND,
        "executionId": Uuid::from_u128(5),
        "generation": 1,
        "executionDigest": fixtures::digest('e'),
        "approvalDigest": fixtures::digest('f'),
        "countedDecisionReceiptSetDigest": fixtures::digest('1'),
        "effectIdempotencyKeySha256": fixtures::digest('2'),
        "targetBindingDigest": fixtures::digest('3'),
        "effectReceiptId": Uuid::from_u128(6),
        "effectReceiptDigest": fixtures::digest('4'),
        "resultingObjectId": null,
        "resultingObjectVersion": null,
        "resultingObjectDigest": null,
        "terminalKind": "SUCCEEDED",
        "occurredAt": "2026-08-02T00:00:01Z"
    })
}
