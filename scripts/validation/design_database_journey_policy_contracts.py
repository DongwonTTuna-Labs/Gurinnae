from __future__ import annotations


COMPOUNDS = {
    "shared_step_one": {
        "parent_state": "ACTIVE",
        "active_handoff": {"id": None, "generation": None, "state": None},
        "next_owner": {"kind": None, "function": None, "ref_hmac": None},
        "current_owner": "unchanged",
        "escalation_state": "RESOLVED",
        "version_delta": 1,
        "receipt_sequence_delta": 1,
        "parent_head": "exact old terminal handoff receipt",
        "receipt_due_continuity": "prior_due_at equals the locked old parent due_at and resulting_due_at equals the persisted step-one parent due_at",
        "rationale": "WAITING_ACK would violate the exact active-PENDING_ACK tuple check, BLOCKED would contradict an immediate compiled replacement, and a terminal intermediate would forbid the second parent update",
    },
    "decline_with_replacement": {"first_receipt": "HANDOFF_DECLINED", "first_parent_due_at": "exact replacement-origin node SLA checkpoint from the compiled decline policy", "second_receipt": "HANDOFF_REQUESTED", "final_parent": "WAITING_ACK with generation+1 active PENDING_ACK, nonnull next owner and NOT_DUE escalation"},
    "expiry_with_replacement": {"first_receipt": "HANDOFF_EXPIRED", "first_parent_due_at": "exact replacement-origin node SLA checkpoint from the compiled expiry policy", "second_receipt": "HANDOFF_REQUESTED", "final_parent": "WAITING_ACK with generation+1 active PENDING_ACK, nonnull next owner and NOT_DUE escalation"},
    "supersession_with_replacement": {"first_receipt": "HANDOFF_SUPERSEDED", "first_parent_due_at": "exact replacement-origin node SLA checkpoint from the compiled supersession policy", "second_receipt": "HANDOFF_REQUESTED", "final_parent": "WAITING_ACK with generation+1 active PENDING_ACK, nonnull next owner and NOT_DUE escalation"},
    "terminal_outcome_with_cancellation": {"first_receipt": "HANDOFF_CANCELLED", "first_parent_due_at": "exact destination-node or terminal-policy SLA of the compiled outcome", "second_receipt": "OUTCOME_RECORDED", "second_parent_due_at": "exactly the first step resulting_due_at for receipt continuity", "final_parent_state": "exact compiled outcome state with no active handoff and no next owner"},
    "replacement_step_two_due_rule": "new handoff due_at is its immutable hard acknowledgement expiry; parent and request receipt resulting_due_at are the first escalation threshold or hard expiry when no threshold exists; request receipt prior_due_at equals step-one resulting_due_at",
    "atomicity": "both ordered parent UPDATE statements and both immutable receipts occur in one SERIALIZABLE transaction and one atomic transition group; each intermediate tuple independently satisfies all immediate and deferred contracts",
}
SCOPES = {
    "JOURNEY_START": {"operations": ["ops.start_journey_instance_v1"], "session_users": ["gurine_control_api", "gurine_workflow_worker"]},
    "JOURNEY_HANDOFF_REQUEST": {"operations": ["ops.request_journey_handoff_v1"], "session_users": ["gurine_control_api", "gurine_workflow_worker"]},
    "JOURNEY_HANDOFF_DECISION": {"operations": ["decideJourneyHandoff", "ops.decide_journey_handoff_v1"], "session_users": ["gurine_control_api", "gurine_workflow_worker"]},
    "JOURNEY_OUTCOME": {"operations": ["ops.record_journey_outcome_v1"], "session_users": ["gurine_control_api", "gurine_workflow_worker"]},
}
OWNER_FUNCTIONS = {
    "ops.claim_owner_idempotency_v1": ("ops.claim_owner_idempotency_v1(ops.idempotency_claim_v1)", "ops.idempotency_claim_receipt_v1", "VOLATILE"),
    "ops.finalize_owner_idempotency_response_v1": ("ops.finalize_owner_idempotency_response_v1(ops.idempotency_finalize_v1)", "ops.idempotency_finalize_receipt_v1", "VOLATILE"),
    "ops.replay_owner_idempotency_response_v1": ("ops.replay_owner_idempotency_response_v1(ops.idempotency_replay_v1)", "ops.idempotency_replay_receipt_v1", "STABLE"),
}
OWNER_FUNCTION_CALLERS = {
    "ops.claim_owner_idempotency_v1": ["ops.start_journey_instance_v1", "ops.request_journey_handoff_v1", "ops.prepare_journey_handoff_decision_v1", "ops.record_journey_outcome_v1"],
    "ops.finalize_owner_idempotency_response_v1": ["ops.start_journey_instance_v1", "ops.request_journey_handoff_v1", "ops.finalize_journey_handoff_decision_response_v1", "ops.record_journey_outcome_v1"],
    "ops.replay_owner_idempotency_response_v1": ["ops.start_journey_instance_v1", "ops.request_journey_handoff_v1", "ops.prepare_journey_handoff_decision_v1", "ops.record_journey_outcome_v1"],
}
ZERO_OWNER_FUNCTION_CALLERS = ["ops.decide_journey_handoff_v1", "ops.escalate_journey_handoff_v1", "ops.expire_journey_handoff_v1"]
IDEMPOTENCY_READ_COLUMNS = [
    "scope", "key_hash", "request_hash", "operation_id", "bff_issuer", "session_token_hash",
    "claim_generation", "claim_transaction_xid8", "storage_format", "terminal_disposition",
    "terminalized_at", "tombstone_digest", "response_status", "response_body", "response_schema",
    "response_media_type", "response_header_bytes", "response_body_bytes", "response_digest",
    "resource_type", "resource_id", "receipt_id", "receipt_digest", "audit_event_id", "outbox_id",
    "completed_at", "expires_at",
]
RELATION_ACCESS_REGISTRY = {
    "ops.prepare_journey_handoff_decision_v1": {
        "owner_calls": {"ops.claim_owner_idempotency_v1": "exactly-once", "ops.replay_owner_idempotency_response_v1": "exactly-once-iff-FINAL_AVAILABLE", "ops.finalize_owner_idempotency_response_v1": "zero"},
        "direct_ops_idempotency_keys": {"select": "zero", "insert": "zero", "update": "zero", "delete": "zero", "copy": "zero"},
    },
    "ops.decide_journey_handoff_v1": {
        "owner_calls": {"ops.claim_owner_idempotency_v1": "zero", "ops.replay_owner_idempotency_response_v1": "zero", "ops.finalize_owner_idempotency_response_v1": "zero"},
        "direct_ops_idempotency_keys": {
            "select": "exactly-one-schema-qualified-SELECT-INTO-STRICT",
            "lock": "none-additional-prepare-retains-row-lock",
            "selected_columns": IDEMPOTENCY_READ_COLUMNS,
            "predicate": "exact JOURNEY_HANDOFF_DECISION key; BOUND_V1; decideJourneyHandoff; null BFF/session; exact seven-field request hash, claim generation and canonical JOURNEY_HANDOFF resource; unexpired lease; claim_transaction_xid8 = pg_current_xact_id(); all terminal marker, compatibility JSON, response byte, digest, receipt, audit, outbox and completion fields NULL",
            "insert": "zero", "update": "zero", "delete": "zero", "copy": "zero",
        },
        "other_idempotency_helpers": "zero",
    },
    "ops.finalize_journey_handoff_decision_response_v1": {
        "owner_calls": {"ops.claim_owner_idempotency_v1": "zero", "ops.replay_owner_idempotency_response_v1": "zero", "ops.finalize_owner_idempotency_response_v1": "exactly-once"},
        "direct_ops_idempotency_keys": {
            "pre_finalize": "exactly-one-schema-qualified-SELECT-INTO-STRICT-FOR-UPDATE of the complete selected_columns set; require the same incomplete BOUND_V1 tuple and claim_transaction_xid8 = pg_current_xact_id()",
            "post_finalize": "exactly-one-schema-qualified-SELECT-INTO-STRICT of the complete selected_columns set after the owner call",
            "selected_columns": IDEMPOTENCY_READ_COLUMNS,
            "post_finalize_equality": "persisted scope, key, request, operation, null BFF/session, generation, preserved claim_transaction_xid8, BOUND_V1, RESPONSE_FINAL marker, terminalized/completed time, status, schema, media type, exact header bytes, exact body bytes, parsed compatibility response JSON, response digest, JOURNEY_HANDOFF resource, receipt ID/digest, audit ID, outbox ID and completed tuple all equal the verified internal finalize composite and pre-finalize binding; JSON reserialization is forbidden",
            "insert": "zero", "update": "only-transitively-through-exactly-one-owner-finalize-call", "delete": "zero", "copy": "zero",
        },
        "other_idempotency_helpers": "zero",
    },
}
DECISION_BUSINESS_HASH_FIELDS = ["operation_id", "handoff_id", "expected_handoff_version", "expected_binding_digest", "decision", "reason_code", "reason_digest"]
DECISION_BUSINESS_HASH_EXCLUDES = ["request_id", "assertion_jti", "assertion_token_bytes", "reason_encrypted", "plaintext_reason"]
DECISION_BOUNDARY_EXCLUDES = ["transport_request_id", "actor_assertion_jti", "service_assertion_jti", "assertion_token_bytes", "actor_or_service_identity_bytes", "action_or_step_up_token_bytes", "raw_idempotency_key", "idempotency_key_sha256", "reason_encrypted", "plaintext_reason", "http_header_order", "json_field_order"]
DECLINE_REASON_CODES = ["CAPABILITY_UNAVAILABLE", "OBJECT_SCOPE_MISMATCH", "CONFLICT_OF_INTEREST", "WORKLOAD_CAPACITY", "DEPENDENCY_BLOCKED", "SUBJECT_INVALID", "OWNER_UNAVAILABLE", "POLICY_BLOCKED", "RECEIVER_DECLINED"]
DECISION_REASON_SHAPE = {
    "discriminator": "decision",
    "closed_decline_reason_codes": DECLINE_REASON_CODES,
    "sql_field_mapping": {"reasonCode": "reason_code", "reason": "FORBIDDEN_SQL_INPUT", "reasonDigest": "reason_digest", "reasonEncrypted": "reason_encrypted"},
    "branches": {
        "ACKNOWLEDGE": {"reasonCode": "MUST_BE_NULL", "reason": "MUST_BE_NULL", "reasonDigest": "MUST_BE_NULL", "reasonEncrypted": "MUST_BE_NULL"},
        "DECLINE": {"reasonCode": "REQUIRED_CLOSED_DECLINE_REASON_CODE", "reason": "REQUIRED_VALID_UNICODE_NUL_FREE_NFC_NON_WHITESPACE_1_TO_4000", "reasonDigest": "REQUIRED_SHA256_OF_EXACT_NFC_UTF8_BYTES", "reasonEncrypted": "REQUIRED_NEW_CLAIM_ONLY_RANDOMIZED_CIPHERTEXT"},
    },
}
ATTEMPT_REASON_BRANCHES = {
    "ACKNOWLEDGE": {"reason_code": "MUST_BE_NULL", "reason_plaintext": "MUST_BE_NULL", "reason_digest": "MUST_BE_NULL", "reason_encrypted": "MUST_BE_NULL"},
    "DECLINE": {"reason_code": "REQUIRED_CLOSED_DECLINE_REASON_CODE", "reason_plaintext": "REQUIRED_VALID_UNICODE_NUL_FREE_NFC_NON_WHITESPACE_1_TO_4000", "reason_digest": "REQUIRED_SHA256_OF_EXACT_NFC_UTF8_BYTES", "reason_encrypted": "DERIVED_ONLY_AFTER_PREPARE_NEW"},
}
ENTRY_TRANSPORT_MAPPING = {
    "ACTOR": {"session_user": "gurine_control_api", "transport": "CONTROL_COMMAND", "transport_request_id": "HTTP request ID", "wire_request_digest": "request-bound ActorAssertion canonical HTTP attempt digest"},
    "SERVICE": {"session_user": "gurine_workflow_worker", "transport": "JOURNEY_WORKFLOW_DB_COMMAND", "transport_request_id": "commandInstanceId", "wire_request_digest": "commandEnvelopeDigest"},
    "business_request_hash": "JOURNEY_HANDOFF_DECISION_BUSINESS_V1(exact seven semantic fields)",
    "non_substitution": "transport_request_id identifies one attempt; wire_request_digest authenticates its complete boundary envelope; business_request_hash identifies stable business bytes. No field or digest may be copied into another slot.",
}
FIXED_FINALIZE_BINDING = {
    "scope": "JOURNEY_HANDOFF_DECISION",
    "operation_id": "decideJourneyHandoff",
    "bff_issuer": None,
    "session_token_hash": None,
    "resource_type": "JOURNEY_HANDOFF",
    "resource_id": "canonical lowercase UUID text of the decision receipt handoff_id",
    "response_status": 200,
    "response_schema": "JourneyHandoffDecisionReceiptV1",
    "response_media_type": "application/json",
}
PREPARE_FIELDS = [
    ("handoff_id", "uuid", False),
    ("expected_handoff_version", "bigint", False),
    ("expected_binding_digest", "char(64)", False),
    ("decision", "text", False),
    ("reason_code", "text", True),
    ("reason_digest", "char(64)", True),
    ("transport_request_id", "uuid", False),
    ("idempotency_key_sha256", "char(64)", False),
    ("assertion_type", "text", False),
    ("assertion_jti", "uuid", False),
    ("wire_request_digest", "char(64)", False),
    ("attempt_audit_event_id", "uuid", False),
    ("attempt_audit_event_hash", "char(64)", False),
]
PREPARE_RECEIPT_FIELDS = [
    ("disposition", "text", False),
    ("claim_generation", "bigint", False),
    ("business_request_hash", "char(64)", False),
    ("response_status", "integer", True),
    ("response_schema", "text", True),
    ("response_media_type", "text", True),
    ("response_header_bytes", "bytea", True),
    ("response_body_bytes", "bytea", True),
    ("response_digest", "char(64)", True),
    ("receipt_id", "uuid", True),
    ("receipt_digest", "char(64)", True),
    ("completed_at", "timestamptz", True),
]
DECISION_IDEMPOTENCY_REGPROCEDURES = [
    {"name": "ops.prepare_journey_handoff_decision_v1", "identity": "ops.prepare_journey_handoff_decision_v1(ops.journey_handoff_decision_prepare_v1)", "returns": "ops.journey_handoff_decision_prepare_receipt_v1", "execute_roles": ["gurine_control_api", "gurine_workflow_worker"]},
    {"name": "ops.finalize_journey_handoff_decision_response_v1", "identity": "ops.finalize_journey_handoff_decision_response_v1(ops.idempotency_finalize_v1)", "returns": "ops.idempotency_finalize_receipt_v1", "execute_roles": ["gurine_control_api", "gurine_workflow_worker"]},
]
ASSERTION_ATTEMPT_INPUT_FIELDS = ["assertion_type", "assertion_jti", "issuer", "audience", "expires_at", "wire_request_digest", "operation_id", "handoff_id", "expected_handoff_version", "expected_binding_digest", "decision", "reason_code", "reason_digest", "transport_request_id", "idempotency_key_sha256"]
ASSERTION_ATTEMPT_OUTPUT_FIELDS = ["assertion_type", "jti_digest", "wire_request_digest", "business_request_hash", "audit_event_id", "audit_event_hash", "consumed_at"]
TYPE_FIELDS = {
    "ops.journey_replacement_result_v1": [("handoff_id", "uuid", False), ("handoff_version", "bigint", False), ("generation", "bigint", False), ("binding_digest", "char(64)", False), ("request_receipt_id", "uuid", False), ("request_receipt_digest", "char(64)", False), ("request_journey_instance_version", "bigint", False), ("audit_event_id", "uuid", False), ("outbox_event_id", "uuid", False), ("receiver_function", "text", False), ("hard_expiry_at", "timestamptz", False), ("resulting_due_at", "timestamptz", False)],
    "ops.journey_handoff_terminal_result_v1": [("receipt_id", "uuid", False), ("receipt_digest", "char(64)", False), ("journey_instance_id", "uuid", False), ("journey_instance_version", "bigint", False), ("handoff_id", "uuid", False), ("handoff_version", "bigint", False), ("handoff_kind", "text", False), ("generation", "bigint", False), ("decision", "text", False), ("resulting_handoff_state", "text", False), ("resulting_journey_state", "text", False), ("current_owner_binding_digest", "char(64)", False), ("next_owner_binding_digest", "char(64)", True), ("audit_event_id", "uuid", False), ("outbox_event_id", "uuid", False)],
    "ops.journey_instance_head_result_v1": [("journey_instance_id", "uuid", False), ("version", "bigint", False), ("state", "text", False), ("current_owner_binding_digest", "char(64)", False), ("next_owner_binding_digest", "char(64)", True), ("active_handoff_id", "uuid", True), ("active_handoff_generation", "bigint", True), ("active_handoff_state", "text", True), ("escalation_state", "text", False), ("due_at", "timestamptz", False), ("head_receipt_id", "uuid", False), ("head_receipt_digest", "char(64)", False)],
    "ops.journey_handoff_decision_result_v1": [("decision_receipt", "ops.journey_handoff_terminal_result_v1", False), ("replacement", "ops.journey_replacement_result_v1", True), ("final_parent", "ops.journey_instance_head_result_v1", False), ("effect_digest", "char(64)", False), ("decided_at", "timestamptz", False)],
    "ops.journey_scheduler_result_v1": [("disposition", "text", False), ("action", "text", False), ("transition_receipt_id", "uuid", True), ("transition_receipt_digest", "char(64)", True), ("transition_journey_instance_version", "bigint", True), ("transition_handoff_id", "uuid", True), ("transition_handoff_version", "bigint", True), ("transition_audit_event_id", "uuid", True), ("transition_outbox_event_id", "uuid", True), ("replacement", "ops.journey_replacement_result_v1", True), ("final_parent", "ops.journey_instance_head_result_v1", True), ("hard_expiry_at", "timestamptz", True), ("next_scheduler_at", "timestamptz", True)],
}
TYPE_ACL = {
    "ops.journey_replacement_result_v1": {"gurine_control_api": ["USAGE"], "gurine_workflow_worker": ["USAGE"], "gurine_scheduler": ["USAGE"], "PUBLIC": []},
    "ops.journey_handoff_terminal_result_v1": {"gurine_control_api": ["USAGE"], "gurine_workflow_worker": ["USAGE"], "PUBLIC": []},
    "ops.journey_instance_head_result_v1": {"gurine_control_api": ["USAGE"], "gurine_workflow_worker": ["USAGE"], "gurine_scheduler": ["USAGE"], "PUBLIC": []},
    "ops.journey_handoff_decision_result_v1": {"gurine_control_api": ["USAGE"], "gurine_workflow_worker": ["USAGE"], "PUBLIC": []},
    "ops.journey_scheduler_result_v1": {"gurine_scheduler": ["USAGE"], "PUBLIC": []},
}
ROUTINE_CONTRACTS = {
    "ops.start_journey_instance_v1": {"roles": ["gurine_control_api", "gurine_workflow_worker"], "writes": ["ops.idempotency_keys", "ops.journey_instances", "ops.journey_transition_receipts", "ops.audit_events", "ops.outbox"], "receipts": ["INSTANCE_STARTED"], "events": ["journey.instance_started.v1"]},
    "ops.request_journey_handoff_v1": {"roles": ["gurine_control_api", "gurine_workflow_worker"], "writes": ["ops.idempotency_keys", "ops.journey_instances", "ops.journey_handoffs", "ops.journey_transition_receipts", "ops.audit_events", "ops.outbox"], "receipts": ["HANDOFF_REQUESTED", "HANDOFF_SUPERSEDED"], "events": ["journey.handoff_requested.v1"]},
    "ops.decide_journey_handoff_v1": {"roles": ["gurine_control_api", "gurine_workflow_worker"], "writes": ["compiled domain owner relation", "ops.journey_instances", "ops.journey_handoffs", "ops.journey_transition_receipts", "ops.audit_events", "ops.outbox"], "receipts": ["HANDOFF_ACKNOWLEDGED", "HANDOFF_DECLINED", "HANDOFF_REQUESTED"], "events": ["journey.handoff_decided.v1", "journey.handoff_requested.v1"]},
    "ops.escalate_journey_handoff_v1": {"roles": ["gurine_scheduler"], "writes": ["ops.journey_instances", "ops.journey_handoffs", "ops.journey_transition_receipts", "ops.audit_events", "ops.outbox"], "receipts": ["HANDOFF_ESCALATED"], "events": ["journey.handoff_escalated.v1"]},
    "ops.expire_journey_handoff_v1": {"roles": ["gurine_scheduler"], "writes": ["ops.journey_instances", "ops.journey_handoffs", "ops.journey_transition_receipts", "ops.audit_events", "ops.outbox"], "receipts": ["HANDOFF_EXPIRED", "HANDOFF_REQUESTED"], "events": ["journey.handoff_expired.v1", "journey.handoff_requested.v1"]},
    "ops.record_journey_outcome_v1": {"roles": ["gurine_control_api", "gurine_workflow_worker"], "writes": ["ops.idempotency_keys", "ops.journey_instances", "ops.journey_handoffs", "ops.journey_transition_receipts", "ops.audit_events", "ops.outbox"], "receipts": ["HANDOFF_CANCELLED", "OUTCOME_RECORDED"], "events": ["journey.outcome_recorded.v1"]},
}
