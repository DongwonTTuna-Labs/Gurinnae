const ECONOMICS_OWNER_RESULT_KEYS: [&str; 5] = [
    "schemaVersion",
    "disposition",
    "retryable",
    "code",
    "receipt",
];

const ECONOMICS_CLAIM_OWNER_SQL: &str =
    "SELECT ops.claim_economics_import_execution_v1($1,$2,$3,$4,$5,$6,$7,$8,$9)";
const ECONOMICS_COMPLETE_OWNER_SQL: &str =
    "SELECT ops.complete_economics_import_execution_v1($1,$2,$3,$4,$5,$6)";
const ECONOMICS_FAIL_OWNER_SQL: &str =
    "SELECT ops.fail_economics_import_execution_v1($1,$2,$3,$4,$5,$6,$7,$8)";

const ECONOMICS_JOB_RESULT_KEYS: [&str; 7] = [
    "schemaVersion",
    "operationId",
    "terminalKind",
    "executionReceiptId",
    "executionReceiptSequence",
    "executionReceiptDigest",
    "resultSetDigest",
];

const ECONOMICS_CLAIM_RECEIPT_KEYS: [&str; 25] = [
    "schemaVersion",
    "producerJobId",
    "producerJobFencingToken",
    "producerJobLeaseExpiresAt",
    "eventId",
    "executionId",
    "generation",
    "attemptId",
    "executionFencingToken",
    "executionDigest",
    "approvalDigest",
    "countedDecisionSetDigest",
    "terminalDecisionReceiptDigest",
    "effectIdempotencyKeySha256",
    "actionDetailDigest",
    "targetRequestSha256",
    "operationId",
    "operationDigest",
    "sourceEvidenceSetDigest",
    "importPolicyDigest",
    "asOf",
    "authorizationExpiresAt",
    "executionReceiptId",
    "executionReceiptSequence",
    "executionReceiptDigest",
];

// The DB owner corrected the provisional 28-field sketch to this closed 32-field set.
const ECONOMICS_TERMINAL_RECEIPT_KEYS: [&str; 32] = [
    "schemaVersion",
    "terminalKind",
    "producerJobId",
    "producerJobFencingToken",
    "eventId",
    "executionId",
    "generation",
    "attemptId",
    "executionFencingToken",
    "executionDigest",
    "approvalDigest",
    "countedDecisionSetDigest",
    "terminalDecisionReceiptDigest",
    "effectIdempotencyKeySha256",
    "actionDetailDigest",
    "targetRequestSha256",
    "operationId",
    "operationDigest",
    "sourceEvidenceSetDigest",
    "importPolicyDigest",
    "asOf",
    "authorizationExpiresAt",
    "resultSetDigest",
    "errorCode",
    "errorDetailDigest",
    "executionReceiptId",
    "executionReceiptSequence",
    "executionReceiptDigest",
    "auditEventId",
    "outboxEventId",
    "notificationOutboxEventId",
    "occurredAt",
];
