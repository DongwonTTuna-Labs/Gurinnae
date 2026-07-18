from __future__ import annotations
from typing import Any
from .design_support import DesignDocuments
OUTER_FIELDS = ["schemaVersion", "command", "decisionReceipt", "replacement", "finalParent", "effectDigest", "decidedAt"]
TERMINAL_FIELDS = ["receiptId", "receiptDigest", "journeyInstanceId", "journeyInstanceVersion", "handoffId", "handoffVersion", "handoffKind", "generation", "decision", "resultingHandoffState", "resultingJourneyState", "currentOwnerBindingDigest", "nextOwnerBindingDigest", "auditEventId", "outboxEventId"]
REPLACEMENT_FIELDS = ["handoffId", "handoffVersion", "generation", "bindingDigest", "requestReceiptId", "requestReceiptDigest", "auditEventId", "outboxEventId", "journeyInstanceVersion", "receiverFunction", "hardExpiryAt", "resultingDueAt"]
HEAD_FIELDS = ["journeyInstanceId", "version", "state", "currentOwnerBindingDigest", "nextOwnerBindingDigest", "activeHandoffId", "activeHandoffGeneration", "activeHandoffState", "escalationState", "dueAt", "headReceiptId", "headReceiptDigest"]
REQUEST_FIELDS = ["schemaVersion", "handoffId", "expectedHandoffVersion", "expectedBindingDigest", "decision", "reasonCode", "reason"]
EVENTS = ["journey.handoff_decided.v1", "journey.handoff_requested.v1"]
COMPOUND_BRANCHES = ["decline_with_replacement", "expiry_with_replacement", "supersession_with_replacement", "terminal_outcome_with_cancellation"]
SUCCESS_CONTRACT = {"decision_receipt": "required-old-terminal-step", "replacement": "nullable-complete-generation-plus-one-request", "final_parent": "required-authoritative-post-command-head"}
TERMINAL_TYPES = {"receiptId": "uuid", "receiptDigest": "sha256", "journeyInstanceId": "uuid", "journeyInstanceVersion": "int64[1..max]", "handoffId": "uuid", "handoffVersion": "int64[1..max]", "generation": "int64[1..max]", "decision": "enum<ACKNOWLEDGE|DECLINE>", "resultingHandoffState": "enum<ACKNOWLEDGED|DECLINED>", "resultingJourneyState": "enum<ACTIVE|BLOCKED>", "currentOwnerBindingDigest": "sha256", "nextOwnerBindingDigest": "nullable<sha256>", "auditEventId": "uuid", "outboxEventId": "uuid"}
REPLACEMENT_TYPES = {"handoffId": "uuid", "handoffVersion": "const<1>", "generation": "int64[1..max]", "bindingDigest": "sha256", "requestReceiptId": "uuid", "requestReceiptDigest": "sha256", "auditEventId": "uuid", "outboxEventId": "uuid", "journeyInstanceVersion": "int64[1..max]", "receiverFunction": "string[1..160]", "hardExpiryAt": "datetime", "resultingDueAt": "datetime"}
HEAD_TYPES = {"journeyInstanceId": "uuid", "version": "int64[1..max]", "state": "enum<ACTIVE|WAITING_ACK|BLOCKED|RECONCILIATION_REQUIRED|COMPLETED|CANCELLED|EXPIRED|REJECTED>", "currentOwnerBindingDigest": "sha256", "nextOwnerBindingDigest": "nullable<sha256>", "activeHandoffId": "nullable<uuid>", "activeHandoffGeneration": "nullable<int64[1..max]>", "activeHandoffState": "nullable<enum<PENDING_ACK>>", "escalationState": "enum<NOT_DUE|DUE|ESCALATED|RESOLVED>", "dueAt": "datetime", "headReceiptId": "uuid", "headReceiptDigest": "sha256"}
BUSINESS_HASH_FIELDS = ["operationId", "handoffId", "expectedHandoffVersion", "expectedBindingDigest", "decision", "reasonCode", "reasonDigest"]
BUSINESS_HASH_EXCLUDES = ["requestId", "actorAssertionJti", "serviceAssertionJti", "assertionTokenBytes", "wireRequestDigest", "randomizedReasonEncrypted", "plaintextReason"]
AUTHORIZATION_ATTEMPT_WRITES = ["ops.assertion_replay_guard", "ops.audit_events#ASSERTION_ATTEMPT_CONSUMED"]
HANDOFF_ERRORS = ["INVALID_PARAMETER", "ACTOR_ASSERTION_INVALID", "ACTOR_ASSERTION_REPLAYED", "SERVICE_ASSERTION_INVALID", "SERVICE_ASSERTION_REPLAYED", "RESOURCE_NOT_FOUND", "CAPABILITY_DENIED", "HANDOFF_RECEIVER_MISMATCH", "HANDOFF_STATE_INVALID", "HANDOFF_BINDING_MISMATCH", "VERSION_CONFLICT", "HANDOFF_EXPIRED", "JOURNEY_TERMINAL", "IDEMPOTENCY_CONFLICT", "INTERNAL_ERROR"]
ACTOR_HANDOFF_ERRORS = [code for code in HANDOFF_ERRORS if not code.startswith("SERVICE_ASSERTION_")]
SERVICE_HANDOFF_ERRORS = [code for code in HANDOFF_ERRORS if not code.startswith("ACTOR_ASSERTION_")]
SERVICE_CANONICAL_TARGET = "ops.consume_journey_handoff_assertion_attempt_v1->ops.prepare_journey_handoff_decision_v1->ops.decide_journey_handoff_v1->ops.finalize_journey_handoff_decision_response_v1"
DECLINE_REASON_CODES = ["CAPABILITY_UNAVAILABLE", "OBJECT_SCOPE_MISMATCH", "CONFLICT_OF_INTEREST", "WORKLOAD_CAPACITY", "DEPENDENCY_BLOCKED", "SUBJECT_INVALID", "OWNER_UNAVAILABLE", "POLICY_BLOCKED", "RECEIVER_DECLINED"]
DECISION_REASON_BRANCHES = {
    "ACKNOWLEDGE": {"reasonCode": "MUST_BE_NULL", "reason": "MUST_BE_NULL", "reasonDigest": "MUST_BE_NULL", "reasonEncrypted": "MUST_BE_NULL"},
    "DECLINE": {"reasonCode": "REQUIRED_CLOSED_DECLINE_REASON_CODE", "reason": "REQUIRED_VALID_UNICODE_NUL_FREE_NFC_NON_WHITESPACE_1_TO_4000", "reasonDigest": "REQUIRED_SHA256_OF_EXACT_NFC_UTF8_BYTES", "reasonEncrypted": "REQUIRED_NEW_CLAIM_ONLY_RANDOMIZED_CIPHERTEXT"},
}
OPERATION_TRANSACTION_IDENTITY = {
    "authorization_attempt": "Transaction A persists non-null equal ops.assertion_replay_guard.attempt_transaction_xid8 and generated ops.audit_events.attempt_transaction_xid8 from server-side pg_current_xact_id(); Transaction B sees both immutable rows and requires that xid8 to differ from its pg_current_xact_id()",
    "business_claim": "a BOUND_V1 NEW ops.idempotency_keys row persists server-only claim_transaction_xid8=pg_current_xact_id(); apply and finalize require equality in the same top-level Transaction B, including SAVEPOINT and nested SAVEPOINT execution",
    "legacy": "all three legacy xid8 values remain NULL and cannot be backfilled into proof",
    "forbidden": ["xmin authorization proof", "hard pg_xact_status committed predicate", "caller-supplied xid", "migration backfill"],
    "diagnostic": "pg_xact_status committed corroborates; NULL is allowed after history truncation; in-progress or aborted is an integrity fault",
}
OPERATION_RELATION_ACCESS = {
    "prepare": "owner claim exactly once and owner replay exactly once iff FINAL_AVAILABLE; zero direct ops.idempotency_keys statements",
    "apply": "exactly one schema-qualified direct SELECT INTO STRICT of the complete prepared-NEW tuple; zero DML, helper or owner calls",
    "finalize": "exactly one pre-finalize SELECT INTO STRICT FOR UPDATE, exactly one owner-finalize call, zero replay-owner calls, then exactly one direct persisted-tuple readback comparing all response bytes, metadata, resource, receipt, audit, outbox and completion fields",
}
COMMAND_TRANSACTION_A_PROOF = {
    "relations": ["ops.assertion_replay_guard", "ops.audit_events"],
    "columns": ["attempt_transaction_xid8", "attempt_transaction_xid8"],
    "predicate": "both MVCC-visible immutable rows have equal non-null xid8 and that xid8 differs from Transaction-B pg_current_xact_id()",
    "producer": "each controlled INSERT binds the stored xid8 to its server-side pg_current_xact_id()",
    "legacy": "NULL is never proof",
}
COMMAND_TRANSACTION_B_PROOF = {
    "relation": "ops.idempotency_keys",
    "column": "claim_transaction_xid8",
    "new_claim_predicate": "BOUND_V1 and claim_transaction_xid8=pg_current_xact_id()",
    "apply_finalize_predicate": "equality with the same top-level xid even inside SAVEPOINT or nested SAVEPOINT",
    "final_replay": "historical claim does not require current-xid equality",
}
COMMAND_RELATION_ACCESS = {
    "prepare": {"direct_ops_idempotency_keys": "zero", "owner_claim_calls": "exactly-one", "owner_replay_calls": "exactly-one-iff-FINAL_AVAILABLE", "owner_finalize_calls": "zero"},
    "apply": {"direct_ops_idempotency_keys": "exactly-one schema-qualified SELECT INTO STRICT complete-tuple read", "dml": "zero", "helper_calls": "zero", "owner_calls": "zero", "proof": "claim_transaction_xid8=pg_current_xact_id()"},
    "finalize": {"pre_read": "exactly-one schema-qualified SELECT INTO STRICT FOR UPDATE complete-tuple read", "owner_finalize_calls": "exactly-one", "owner_replay_calls": "zero", "post_readback": "exactly-one schema-qualified complete persisted-tuple read", "equality": "exact status/schema/media/header bytes/body bytes/digests/resource/receipt/audit/outbox/completed tuple without JSON reserialization"},
}
PERSISTENCE_TRANSACTION_IDENTITY = {
    "attempt_columns": ["ops.assertion_replay_guard.attempt_transaction_xid8", "ops.audit_events.attempt_transaction_xid8"],
    "attempt_predicate": "both immutable rows are MVCC-visible, non-null and equal; their xid8 differs from Transaction-B pg_current_xact_id(); each producer bound it to server-side pg_current_xact_id() in Transaction A",
    "claim_column": "ops.idempotency_keys.claim_transaction_xid8",
    "claim_predicate": "BOUND_V1 NEW stores server-only pg_current_xact_id(); apply and finalize require equality with Transaction B's top-level xid under ordinary, SAVEPOINT and nested SAVEPOINT execution",
    "forbidden": ["xmin", "hard pg_xact_status committed predicate", "caller xid input", "legacy xid backfill"],
    "legacy": "all legacy xid8 values remain NULL and are never proof",
}
PERSISTENCE_RELATION_ACCESS = {
    "prepare": {"owner_claim": "exactly-once", "owner_replay": "exactly-once-iff-FINAL_AVAILABLE", "direct_ops_idempotency_keys": "zero"},
    "apply": {"direct_ops_idempotency_keys": "exactly-one schema-qualified SELECT INTO STRICT of complete prepared-NEW tuple", "direct_dml": "zero", "helper_calls": "zero", "owner_calls": "zero"},
    "finalize": {"pre_finalize_direct_read": "exactly-one schema-qualified SELECT INTO STRICT FOR UPDATE of complete tuple", "owner_finalize": "exactly-once", "owner_replay": "zero", "post_finalize_direct_readback": "exactly-one complete tuple", "equality": "status/schema/media/header bytes/body bytes/digests/resource/receipt/audit/outbox/completed values plus preserved claim xid; JSON reserialization forbidden"},
}
RESOURCE_TRANSACTION_IDENTITY = {
    "attempt_proof": "MVCC-visible replay-guard and SUCCESS audit rows carry equal non-null server-produced attempt_transaction_xid8 values and that xid differs from the business transaction pg_current_xact_id()",
    "claim_proof": "BOUND_V1 NEW carries server-produced claim_transaction_xid8 equal to the business transaction top-level pg_current_xact_id(), including SAVEPOINT and nested SAVEPOINT paths",
    "forbidden": ["xmin proof", "hard pg_xact_status committed requirement", "caller-supplied xid", "legacy xid backfill"],
    "error_mapping": "missing, NULL, mismatch or same-transaction attempt proof is ACTOR_ASSERTION_INVALID or SERVICE_ASSERTION_INVALID by selected boundary with zero business writes; pg_xact_status NULL alone is not an error",
}

def _operation(documents: DesignDocuments) -> dict[str, Any]:
    return next(
        (
            row
            for row in documents.operation_contracts.get("operations", [])
            if row.get("operation_id") == "decideJourneyHandoff"
        ),
        {},
    )

def _validate_reason_shape(value: dict[str, Any]) -> bool:
    return (
        value.get("discriminator") == "decision"
        and value.get("closed_decline_reason_codes") == DECLINE_REASON_CODES
        and value.get("branches") == DECISION_REASON_BRANCHES
    )

def _validate_operation_and_request(documents: DesignDocuments) -> None:
    result = documents.result
    operation = _operation(documents)
    request = documents.resource_error_contracts.get("request_schemas_by_operation", {}).get("decideJourneyHandoff", {})
    resources = documents.resource_error_contracts
    resource_binding = resources.get("operation_bindings", {}).get("decideJourneyHandoff", {})
    entries = resources.get("journey_handoff_decision_entry_boundaries", {})
    service_profile = resources.get("transport_profiles", {}).get("JOURNEY_WORKFLOW_DB_COMMAND", {})
    result.require(
        operation.get("response") == "JourneyHandoffDecisionReceiptV1"
        and operation.get("request", {}).get("required") == REQUEST_FIELDS
        and list(operation.get("request", {}).get("fields", {})) == REQUEST_FIELDS
        and list(request.get("fields", {})) == REQUEST_FIELDS
        and operation.get("request", {}).get("forbidden")
        == ["journeyId", "edgeId", "handoffKind", "receiver", "receiverFunction", "receiverCapability", "destination", "owner", "domainAdapter"],
        "decideJourneyHandoff request, response or forbidden routing field contract drifted",
    )
    constraints = " ".join(str(value) for value in operation.get("constraints", []))
    result.require(
        "encrypt" in constraints.lower()
        and "decision receipt" in constraints.lower()
        and "final parent" in constraints.lower()
        and "fresh request-bound" in constraints.lower()
        and "stored bytes" in constraints.lower()
        and "only a new business claim" in constraints.lower(),
        "decideJourneyHandoff does not expose the encrypted reason and complete durable response boundary",
    )
    result.require(
        operation.get("compound_branches") == COMPOUND_BRANCHES
        and operation.get("success_contract") == SUCCESS_CONTRACT
        and "final parent state WAITING_ACK" in str(operation.get("transition", "")),
        "decideJourneyHandoff operation compound branch, success or transition contract drifted",
    )
    result.require(
        operation.get("transaction_identity_contract") == OPERATION_TRANSACTION_IDENTITY
        and operation.get("idempotency_relation_access") == OPERATION_RELATION_ACCESS
        and "attempt_transaction_xid8" in constraints
        and "claim_transaction_xid8" in constraints
        and "post-owner readback" in constraints,
        "decideJourneyHandoff persisted xid8 or exact idempotency relation-access contract drifted",
    )
    result.require(
        _validate_reason_shape(operation.get("decision_reason_shape", {}))
        and _validate_reason_shape(request.get("decision_reason_shape", {}))
        and request.get("decision_reason_shape", {}).get("derived_fields")
        == {"reasonDigest": "SERVER_DERIVED_BEFORE_PREPARE", "reasonEncrypted": "SERVER_DERIVED_ONLY_AFTER_PREPARE_NEW"},
        "decideJourneyHandoff operation/resource ACK or DECLINE reason shape drifted",
    )
    result.require(
        operation.get("entry_boundaries")
        == {
            "external_actor_http": {"transport": "CONTROL_COMMAND", "session_user": "gurine_control_api", "assertion_type": "ACTOR", "credential": "X-Gurine-Actor-Assertion", "service_credential": "FORBIDDEN"},
            "internal_service_workflow": {"transport": "JOURNEY_WORKFLOW_DB_COMMAND", "session_user": "gurine_workflow_worker", "assertion_type": "SERVICE", "credential": "closed in-process workload envelope serviceAssertion", "actor_or_http_credential": "FORBIDDEN"},
            "mutual_exclusion": "session_user and assertion type select exactly one boundary; the public control HTTP route is ACTOR-only and the workflow service path has no HTTP endpoint",
            "shared_semantics": "exact request schema, stable seven-field business hash, prepare/apply/finalize transaction, durable receipt and error-to-zero-write rules are identical",
        }
        and resource_binding.get("transport_profile") == "CONTROL_COMMAND"
        and resource_binding.get("entry_boundary") == "external_actor_http"
        and "X-Gurine-Service-Assertion" not in resources.get("transport_profiles", {}).get("CONTROL_COMMAND", {}).get("required_headers", {})
        and entries.get("logical_operation_id") == "decideJourneyHandoff"
        and entries.get("semantic_request_schema") == "DecideJourneyHandoffRequestV1"
        and entries.get("stable_business_hash_profile") == "journey-handoff-business-v1"
        and entries.get("external_actor_http", {}).get("session_user") == "gurine_control_api"
        and entries.get("external_actor_http", {}).get("assertion_type") == "ACTOR"
        and entries.get("external_actor_http", {}).get("error_set") == ACTOR_HANDOFF_ERRORS
        and entries.get("internal_service_workflow", {}).get("session_user") == "gurine_workflow_worker"
        and entries.get("internal_service_workflow", {}).get("assertion_type") == "SERVICE"
        and entries.get("internal_service_workflow", {}).get("error_set") == SERVICE_HANDOFF_ERRORS
        and "exactly one boundary" in str(entries.get("mutual_exclusion", "")),
        "decideJourneyHandoff ACTOR HTTP and SERVICE workflow entry boundaries are not exact or mutually exclusive",
    )
    result.require(
        entries.get("transaction_identity_contract") == RESOURCE_TRANSACTION_IDENTITY
        and "one pre-read" in str(entries.get("persisted_response_verification", ""))
        and "one owner-finalize" in str(entries.get("persisted_response_verification", ""))
        and "one post-readback" in str(entries.get("persisted_response_verification", ""))
        and "replay-owner" in str(entries.get("persisted_response_verification", "")),
        "journey resource persisted xid8 or full response-readback error contract drifted",
    )
    required_envelope = service_profile.get("required_envelope", {})
    digest_contract = service_profile.get("digest_contract", {})
    result.require(
        service_profile.get("protocol") == "POSTGRES_REGPROCEDURE_CHAIN"
        and service_profile.get("caller") == "gurine_workflow_worker only"
        and service_profile.get("session_user") == "gurine_workflow_worker"
        and service_profile.get("assertion_type") == "SERVICE"
        and required_envelope.get("operationId") == "const<decideJourneyHandoff>"
        and required_envelope.get("canonicalTarget") == f"const<{SERVICE_CANONICAL_TARGET}>"
        and required_envelope.get("commandEnvelopeDigest") == "sha256"
        and service_profile.get("service_assertion_binding") == ["operationId", "canonicalTarget", "commandInstanceId", "semanticRequestDigest", "commandEnvelopeDigest", "idempotencyKeySha256", "deploymentId", "workloadPrincipalId", "acknowledgementAuthorityDigest", "expiry", "fresh JTI"]
        and service_profile.get("database_mapping") == {"transport_request_id": "commandInstanceId", "wire_request_digest": "commandEnvelopeDigest", "business_request_hash": "businessRequestHash", "idempotency_key_sha256": "idempotencyKeySha256", "assertion_type": "SERVICE"}
        and "excluding serviceAssertion token signature" in str(digest_contract.get("commandEnvelopeDigest", ""))
        and "three distinct domains and values" in str(digest_contract.get("non_substitution", ""))
        and "not an HTTP endpoint" in str(service_profile.get("rule", "")),
        "journey SERVICE workflow envelope target or wire/business digest mapping drifted",
    )

def _validate_command_persistence(documents: DesignDocuments) -> None:
    result = documents.result
    operation = _operation(documents)
    command = documents.command_semantics.get("external_commands", {}).get("decideJourneyHandoff", {})
    persistence = documents.persistence_contracts.get("exact_persistence_registry", {}).get("external_command_persistence", {}).get("decideJourneyHandoff", {})
    command_tx = command.get("transaction", {})
    profile = documents.command_semantics.get("shared_contracts", {}).get("fresh-assertion-stable-business-idempotency-v1", {})
    external_commands = documents.command_semantics.get("external_commands", {})
    result.require(
        profile.get("operations") == ["decideJourneyHandoff"]
        and profile.get("fixed_scope") == "JOURNEY_HANDOFF_DECISION"
        and profile.get("fixed_operation_id") == "decideJourneyHandoff"
        and profile.get("bff_issuer") == "MUST_BE_NULL"
        and profile.get("session_token_hash") == "MUST_BE_NULL"
        and command.get("idempotency_profile") == "fresh-assertion-stable-business-idempotency-v1"
        and all(
            name == "decideJourneyHandoff" or row.get("idempotency_profile") != "fresh-assertion-stable-business-idempotency-v1"
            for name, row in external_commands.items()
        )
        and "Only `decideJourneyHandoff`" in " ".join(str(row) for row in documents.command_semantics.get("global_invariants", [])),
        "fresh-assertion stable-business profile is not an exact decideJourneyHandoff singleton",
    )
    result.require(
        profile.get("transaction_a_proof") == COMMAND_TRANSACTION_A_PROOF
        and profile.get("transaction_b_claim_proof") == COMMAND_TRANSACTION_B_PROOF
        and profile.get("forbidden_transaction_proofs")
        == ["tuple xmin", "row xmin", "caller-supplied xid", "legacy xid backfill", "hard pg_xact_status=committed"]
        and "NULL is permitted" in str(profile.get("pg_xact_status_diagnostic", "")),
        "fresh-assertion profile persisted xid8, savepoint or pg_xact_status contract drifted",
    )
    result.require(
        command.get("entry_boundaries")
        == {
            "external_actor_http": {"transport_profile": "CONTROL_COMMAND", "session_user": "gurine_control_api", "assertion_type": "ACTOR", "credential": "X-Gurine-Actor-Assertion", "opposite_credential": "FORBIDDEN"},
            "internal_service_workflow": {"transport_profile": "JOURNEY_WORKFLOW_DB_COMMAND", "session_user": "gurine_workflow_worker", "assertion_type": "SERVICE", "credential": "closed workload envelope serviceAssertion", "HTTP_and_actor_credentials": "FORBIDDEN"},
            "service_canonical_target": SERVICE_CANONICAL_TARGET,
            "mutual_exclusion": "exact one boundary by session_user plus assertion_type before attempt consume; cross-boundary credential or transport is INVALID assertion with zero replay-guard or business writes",
            "shared_semantics": "semantic request and seven-field hash are byte-equal before entering the shared prepare/apply/finalize business transaction",
        }
        and persistence.get("entry_boundaries")
        == {
            "external_actor_http": {"transport_profile": "CONTROL_COMMAND", "session_user": "gurine_control_api", "assertion_type": "ACTOR", "attempt_wrapper": "ops.consume_journey_handoff_assertion_attempt_v1"},
            "internal_service_workflow": {"transport_profile": "JOURNEY_WORKFLOW_DB_COMMAND", "session_user": "gurine_workflow_worker", "assertion_type": "SERVICE", "canonical_target": SERVICE_CANONICAL_TARGET},
            "mutual_exclusion": "selected before any assertion replay-guard or business relation access; both paths converge only after exact semantic request and stable business-hash parity",
        },
        "decideJourneyHandoff command/persistence entry-boundary parity drifted",
    )
    result.require(
        command_tx.get("lock_order") == persistence.get("lock_order")
        and command.get("cardinality") == persistence.get("cardinality")
        and command.get("outbox") == persistence.get("outbox")
        and command.get("receipt") == persistence.get("receipt")
        and command.get("atomic_transition_group") == persistence.get("atomic_transition_group"),
        "decideJourneyHandoff command and persistence lock/cardinality/outbox/receipt contracts drifted",
    )
    result.require(
        command.get("compound_branches") == persistence.get("compound_branches") == COMPOUND_BRANCHES
        and command.get("success_contract") == persistence.get("success_contract") == SUCCESS_CONTRACT
        and "conditional second ordered row" in str(persistence.get("update_relations", ""))
        and "final WAITING_ACK" in str(persistence.get("state_disposition", "")),
        "decideJourneyHandoff command/persistence compound, success or update relation contract drifted",
    )
    statements = " ".join(str(value) for value in command_tx.get("statements", []))
    result.require(
        "ops.prepare_journey_handoff_decision_v1" in statements
        and "FINAL_REPLAY" in statements
        and "NEW_ONLY_ENCRYPTION" in statements
        and "non-locking identity only" in statements
        and "reason_encrypted" in statements
        and "one-or-two ordered statements" in statements
        and "HANDOFF_REQUESTED" in statements
        and "ops.finalize_journey_handoff_decision_response_v1" in statements
        and command.get("outbox", {}).get("events") == EVENTS,
        "decideJourneyHandoff transaction omits prepare/replay/NEW-encryption/finalize or two-step replacement semantics",
    )
    result.require(
        _validate_reason_shape(command.get("decision_reason_shape", {}))
        and _validate_reason_shape(persistence.get("decision_reason_shape", {}))
        and command.get("decision_reason_shape", {}).get("enforcement_points")
        == ["trusted wire validation before attempt consume", "prepare business-hash validation before idempotency relation access", "apply SQL branch validation before domain writes", "finalize receipt graph validation"],
        "decideJourneyHandoff command/persistence decision reason branch contract drifted",
    )
    result.require(
        persistence.get("write_ownership")
        == {
            "attempt_consume": AUTHORIZATION_ATTEMPT_WRITES,
            "prepare": ["ops.idempotency_keys"],
            "apply": ["binding-specific domain relations", "ops.journey_instances", "ops.journey_handoffs", "ops.journey_transition_receipts", "ops.audit_events#command", "ops.outbox"],
            "finalize": ["ops.idempotency_keys"],
            "apply_forbidden": ["ops.idempotency_keys", "ops.assertion_replay_guard"],
        }
        and "fixed scope JOURNEY_HANDOFF_DECISION" in statements
        and "construct the internal generic composite" in statements,
        "decideJourneyHandoff prepare/apply/finalize write ownership or fixed finalize wrapper drifted",
    )
    result.require(
        command.get("idempotency_relation_access") == COMMAND_RELATION_ACCESS
        and persistence.get("transaction_identity") == PERSISTENCE_TRANSACTION_IDENTITY
        and persistence.get("relation_access_registry") == PERSISTENCE_RELATION_ACCESS
        and "attempt xid8" in str(command.get("authorization_attempt_contract", {}).get("transaction_proof", ""))
        and "directly read back" in statements
        and "never call replay-owner" in statements,
        "decideJourneyHandoff command/persistence xid8, exact access or persisted readback contract drifted",
    )
    request_hash = command.get("idempotency_request_hash", {})
    result.require(
        request_hash.get("profile") == "journey-handoff-business-v1"
        and request_hash.get("algorithm") == "SHA256(GURINE_CANONICAL_JSON_V1(closed object with explicit null reason fields))"
        and request_hash.get("includes") == BUSINESS_HASH_FIELDS
        and request_hash.get("excludes") == BUSINESS_HASH_EXCLUDES
        and "NFC" in str(request_hash.get("rule", ""))
        and "only NEW encrypts or mutates" in str(request_hash.get("rule", ""))
        and "only a changed included business field" in str(request_hash.get("rule", "")),
        "decideJourneyHandoff stable business hash includes ephemeral identity, omits reasonDigest or weakens NEW-only encryption",
    )
    result.require(
        command.get("idempotency_key_sources")
        == {
            "external_actor_http": "SHA256(UTF8(raw HTTP Idempotency-Key header))",
            "internal_service_workflow": "exact idempotencyKeySha256 from the authenticated closed workload envelope",
            "parity": "both map to the same ops.idempotency_keys key_hash field and neither request ID, wire digest, JTI nor business hash may substitute for it",
        }
        and "one logical request-bound idempotency key" in str(operation.get("concurrency", ""))
        and "ACTOR derives its digest from the HTTP Idempotency-Key header" in str(operation.get("concurrency", ""))
        and "SERVICE supplies the already-derived idempotencyKeySha256" in str(operation.get("concurrency", "")),
        "decideJourneyHandoff ACTOR/SERVICE logical idempotency key source parity drifted",
    )
    attempt = command.get("authorization_attempt_contract", {})
    result.require(
        attempt.get("accepted_attempt_writes") == AUTHORIZATION_ATTEMPT_WRITES
        and attempt.get("duplicate_jti") == "ACTOR_ASSERTION_REPLAYED or SERVICE_ASSERTION_REPLAYED before business claim with zero business writes"
        and "fresh JTI retry" in str(attempt.get("crash_after_attempt_before_business", ""))
        and "byte-identical" in str(attempt.get("replay", "")),
        "decideJourneyHandoff fresh assertion consume/audit/replay contract drifted",
    )
    result.require(
        command.get("cardinality", {}).get("exact_replay")
        == {"authorization_attempt_writes": AUTHORIZATION_ATTEMPT_WRITES, "business_writes": 0, "response": "byte-identical-finalized"}
        and persistence.get("idempotency", {}).get("key_sources")
        == {"external_actor_http": "SHA256(UTF8(raw HTTP Idempotency-Key header))", "internal_service_workflow": "exact authenticated workload envelope idempotencyKeySha256"}
        and persistence.get("idempotency", {}).get("stable_business_identity") == "seven-field business hash excluding transport request and assertion-attempt identity"
        and "distinct fields" in str(persistence.get("idempotency", {}).get("non_substitution", ""))
        and persistence.get("audit", {}).get("exact_replay_command_rows") == 0
        and persistence.get("audit", {}).get("exact_replay_authorization_attempt_rows") == 1,
        "decideJourneyHandoff replay write scope or persistence attempt audit contract drifted",
    )
    resource_errors = documents.resource_error_contracts.get("operation_error_sets", {}).get("decideJourneyHandoff")
    result.require(
        operation.get("errors") == HANDOFF_ERRORS
        and command.get("errors", {}).get("exact_codes") == HANDOFF_ERRORS
        and persistence.get("errors") == HANDOFF_ERRORS
        and resource_errors == HANDOFF_ERRORS,
        "decideJourneyHandoff actor/service assertion replay or command error set drifted",
    )

def _validate_resource_schemas(documents: DesignDocuments) -> None:
    result = documents.result
    schemas = documents.resource_error_contracts.get("schemas", {})
    expected = {
        "JourneyHandoffDecisionReceiptV1": OUTER_FIELDS,
        "JourneyHandoffTerminalReceiptV1": TERMINAL_FIELDS,
        "JourneyHandoffReplacementReceiptV1": REPLACEMENT_FIELDS,
        "JourneyInstanceHeadReceiptV1": HEAD_FIELDS,
    }
    for name, fields in expected.items():
        schema = schemas.get(name, {})
        result.require(
            schema.get("kind") == "object"
            and schema.get("additional_properties") is False
            and list(schema.get("fields", {})) == fields,
            f"{name}: journey response schema field order drifted",
        )
    outer = schemas.get("JourneyHandoffDecisionReceiptV1", {}).get("fields", {})
    result.require(
        outer.get("decisionReceipt") == "JourneyHandoffTerminalReceiptV1"
        and outer.get("replacement") == "nullable<JourneyHandoffReplacementReceiptV1>"
        and outer.get("finalParent") == "JourneyInstanceHeadReceiptV1",
        "JourneyHandoffDecisionReceiptV1 nested durable receipt types drifted",
    )
    head = schemas.get("JourneyInstanceHeadReceiptV1", {}).get("fields", {})
    result.require(
        head.get("escalationState") == "enum<NOT_DUE|DUE|ESCALATED|RESOLVED>"
        and head.get("activeHandoffState") == "nullable<enum<PENDING_ACK>>",
        "JourneyInstanceHeadReceiptV1 active handoff or escalation vocabulary drifted",
    )
    terminal = schemas.get("JourneyHandoffTerminalReceiptV1", {}).get("fields", {})
    replacement = schemas.get("JourneyHandoffReplacementReceiptV1", {}).get("fields", {})
    result.require(
        {key: value for key, value in terminal.items() if key != "handoffKind"} == TERMINAL_TYPES
        and replacement == REPLACEMENT_TYPES
        and head == HEAD_TYPES
        and terminal.get("handoffKind", "").startswith("enum<HS-01-")
        and terminal.get("handoffKind", "").endswith("HS-20-COMMERCIAL_CONTROL_EXTERNAL_ACK>"),
        "journey nested response field types or closed handoff-kind boundary drifted",
    )
    result.require(
        all(schemas[name].get("invariants") for name in ("JourneyHandoffDecisionReceiptV1", "JourneyHandoffTerminalReceiptV1", "JourneyHandoffReplacementReceiptV1", "JourneyInstanceHeadReceiptV1"))
        and "receiver identity bytes" in " ".join(schemas["JourneyHandoffReplacementReceiptV1"].get("invariants", [])),
        "journey nested receipt invariants or safe receiver-function rule drifted",
    )

def validate_journey_operations(documents: DesignDocuments) -> None:
    _validate_operation_and_request(documents)
    _validate_command_persistence(documents)
    _validate_resource_schemas(documents)
