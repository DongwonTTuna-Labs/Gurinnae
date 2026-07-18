from __future__ import annotations

from typing import Any

from .design_database_journey_access import validate_journey_access_surface
from .design_database_journey_policy_contracts import (
    ASSERTION_ATTEMPT_INPUT_FIELDS,
    ASSERTION_ATTEMPT_OUTPUT_FIELDS,
    ATTEMPT_REASON_BRANCHES,
    COMPOUNDS,
    DECISION_BOUNDARY_EXCLUDES,
    DECISION_BUSINESS_HASH_EXCLUDES,
    DECISION_BUSINESS_HASH_FIELDS,
    DECISION_IDEMPOTENCY_REGPROCEDURES,
    DECISION_REASON_SHAPE,
    DECLINE_REASON_CODES,
    ENTRY_TRANSPORT_MAPPING,
    FIXED_FINALIZE_BINDING,
    OWNER_FUNCTION_CALLERS,
    OWNER_FUNCTIONS,
    PREPARE_FIELDS,
    PREPARE_RECEIPT_FIELDS,
    RELATION_ACCESS_REGISTRY,
    ROUTINE_CONTRACTS,
    SCOPES,
    TYPE_ACL,
    TYPE_FIELDS,
    ZERO_OWNER_FUNCTION_CALLERS,
)
from .models import Validation


def _relation_change(document: dict[str, Any], relation: str) -> dict[str, Any]:
    return next(
        (row for row in document.get("migration", {}).get("existing_relation_changes", []) if row.get("relation") == relation),
        {},
    )


def _validate_owner_idempotency(document: dict[str, Any], result: Validation) -> None:
    change = _relation_change(document, "ops.idempotency_keys")
    replay_guard_change = _relation_change(document, "ops.assertion_replay_guard")
    audit_change = _relation_change(document, "ops.audit_events")
    scopes = change.get("journey_owner_routine_internal_scope_registry", {})
    claim_xid = change.get("add_columns", {}).get("claim_transaction_xid8", {})
    attempt_xid = replay_guard_change.get("add_columns", {}).get("attempt_transaction_xid8", {})
    audit_xid = audit_change.get("add_columns", {}).get("attempt_transaction_xid8", {})
    result.require(
        attempt_xid.get("type") == "xid8"
        and attempt_xid.get("nullable") is True
        and attempt_xid.get("legacy_rows") == "MUST_REMAIN_NULL"
        and "SET DEFAULT pg_current_xact_id()" in str(attempt_xid.get("staged_install", ""))
        and "no function argument" in str(attempt_xid.get("new_insert_rule", ""))
        and claim_xid.get("type") == "xid8"
        and claim_xid.get("nullable") is True
        and claim_xid.get("legacy_rows") == "MUST_REMAIN_NULL"
        and "SET DEFAULT pg_current_xact_id()" in str(claim_xid.get("staged_install", ""))
        and "BOUND_V1 NEW INSERT" in str(claim_xid.get("owner_write_rule", ""))
        and claim_xid.get("caller_input") == "FORBIDDEN"
        and audit_xid.get("type") == "xid8"
        and audit_xid.get("nullable") is True
        and audit_xid.get("generated") == "GENERATED ALWAYS AS (CASE WHEN details ? 'attemptTransactionXid8' THEN (details ->> 'attemptTransactionXid8')::xid8 ELSE NULL END) STORED"
        and "audit event-hash preimage" in str(audit_change.get("hash_binding", "")),
        "journey persisted attempt/claim xid8 physical column, producer or generated audit contract drifted",
    )
    checks = {row.get("name"): row.get("expression") for row in change.get("add_checks", [])}
    result.require(
        checks.get("idempotency_claim_transaction_xid_shape_ck")
        == "(storage_format = 'BOUND_V1' AND claim_transaction_xid8 IS NOT NULL) OR (storage_format = 'LEGACY_V13' AND claim_transaction_xid8 IS NULL) OR storage_format IS NULL"
        and "claim_transaction_xid8" in change.get("privilege_reset", {}).get("all_columns", [])
        and "claim_transaction_xid8" in change.get("privilege_reset", {}).get("sensitive_columns", []),
        "idempotency claim xid8 BOUND/legacy shape or ACL inventory drifted",
    )
    result.require(
        all(scopes.get(name, {}).get("operations") == row["operations"] and scopes.get(name, {}).get("session_users") == row["session_users"] for name, row in SCOPES.items())
        and {key for key in scopes if key.startswith("JOURNEY_")} == set(SCOPES)
        and "forbidden to the generic" in str(scopes.get("rule", ""))
        and "wire_request_digest" in " ".join(str(value) for value in scopes.get("binding_rules", []))
        and "exact selected entry-boundary envelope" in " ".join(str(value) for value in scopes.get("binding_rules", []))
        and "service commandEnvelopeDigest" in " ".join(str(value) for value in scopes.get("binding_rules", []))
        and "seven-field" in " ".join(str(value) for value in scopes.get("binding_rules", []))
        and "randomized" in " ".join(str(value) for value in scopes.get("binding_rules", [])),
        "journey owner idempotency scope, caller or randomized-encryption replay contract drifted",
    )
    fresh = scopes.get("fresh_assertion_attempt_boundary", {})
    result.require(
        fresh.get("applies_to_scopes") == ["JOURNEY_HANDOFF_DECISION"]
        and fresh.get("applies_to_operations") == ["decideJourneyHandoff"]
        and fresh.get("inference_to_other_scopes") == "FORBIDDEN"
        and fresh.get("transaction_a", {}).get("writes") == ["ops.assertion_replay_guard", "ops.audit_events#ASSERTION_ATTEMPT_CONSUMED"]
        and "attempt_transaction_xid8" in str(fresh.get("transaction_a", {}).get("persisted_xid_proof", ""))
        and "prepare business claim" in str(fresh.get("transaction_b", {}).get("order", ""))
        and "claim_transaction_xid8=pg_current_xact_id()" in str(fresh.get("transaction_b", {}).get("top_level_xid_proof", ""))
        and "nested SAVEPOINT" in str(fresh.get("transaction_b", {}).get("top_level_xid_proof", ""))
        and fresh.get("transaction_b", {}).get("incomplete_claim_commit") == "rejected by deferred constraint trigger"
        and "byte-identical" in str(fresh.get("crash_semantics", {}).get("after_transaction_b_commit_before_http_response", "")),
        "journey fresh assertion attempt and two-transaction crash contract drifted",
    )
    boundary = document.get("boundary_procedure_acl", {}).get("idempotency_boundary", {})
    catalog = boundary.get("owner_internal_function_catalog", {})
    owner_scope_contract = change.get("journey_owner_routine_internal_scope_registry", {}).get("owner_internal_functions", {})
    routines = {row.get("name"): row for row in catalog.get("routines", [])}
    result.require(set(routines) == set(OWNER_FUNCTIONS), "journey owner idempotency function registry is not exact")
    for name, (signature, returns, volatility) in OWNER_FUNCTIONS.items():
        row = routines.get(name, {})
        result.require(
            row == {"name": name, "signature": signature, "returns": returns, "owner": "gurine_migrator", "security": "INVOKER", "volatility": volatility, "search_path": ["pg_catalog", "ops"], "execute": ["gurine_migrator"]},
            f"{name}: owner idempotency regprocedure/security/ACL contract drifted",
        )
    procedure_signatures = {row.get("signature") for row in document.get("boundary_procedure_acl", {}).get("procedures", [])}
    result.require(
        all(f"{signature} RETURNS {returns}" in procedure_signatures for signature, returns, _ in OWNER_FUNCTIONS.values())
        and "reject every JOURNEY_*" in str(catalog.get("generic_exclusion_rule", ""))
        and "no runtime login role" in str(catalog.get("membership_rule", "")),
        "journey owner idempotency physical procedure, generic exclusion or role-membership contract drifted",
    )
    result.require(
        owner_scope_contract.get("exact_outer_caller_registry") == OWNER_FUNCTION_CALLERS
        and owner_scope_contract.get("zero_owner_function_callers") == ZERO_OWNER_FUNCTION_CALLERS
        and "decision prepare calls claim and conditionally replay" in str(owner_scope_contract.get("invocation_rule", ""))
        and "decision finalize calls finalize" in str(owner_scope_contract.get("invocation_rule", ""))
        and "decision apply and both scheduler routines call no owner function" in str(owner_scope_contract.get("invocation_rule", ""))
        and "pg_get_functiondef" in str(owner_scope_contract.get("caller_set_equality_oracle", ""))
        and owner_scope_contract.get("relation_access_registry") == RELATION_ACCESS_REGISTRY
        and "schema-qualified SQL call graph" in str(owner_scope_contract.get("relation_access_set_equality_oracle", ""))
        and "journey runtime access reaches this relation only through the exact owner-call and schema-qualified direct-read registry" in str(change.get("privilege_reset", {}).get("regrant_rule", "")),
        "journey owner idempotency exact outer caller registry or relation access rule drifted",
    )
    attempt_boundary = document.get("journey_handoff_assertion_attempt_boundary", {})
    attempt_function = attempt_boundary.get("function", {})
    reason_shape = attempt_boundary.get("decision_reason_shape", {})
    result.require(
        [row.get("name") for row in attempt_boundary.get("input_type", {}).get("fields", [])] == ASSERTION_ATTEMPT_INPUT_FIELDS
        and [row.get("name") for row in attempt_boundary.get("output_type", {}).get("fields", [])] == ASSERTION_ATTEMPT_OUTPUT_FIELDS
        and attempt_function.get("signature") == "ops.consume_journey_handoff_assertion_attempt_v1(ops.journey_handoff_assertion_attempt_v1) RETURNS ops.journey_handoff_assertion_attempt_receipt_v1"
        and attempt_function.get("execute_roles") == ["gurine_control_api", "gurine_workflow_worker"]
        and "ops.consume_assertion_jti" in " ".join(str(row) for row in attempt_function.get("algorithm", []))
        and "ACTOR_ASSERTION_REPLAYED or SERVICE_ASSERTION_REPLAYED" in " ".join(str(row) for row in attempt_function.get("algorithm", []))
        and attempt_boundary.get("audit_contract", {}).get("exact_detail_keys") == ["assertionType", "operationId", "jtiDigest", "wireRequestDigest", "idempotencyKeySha256", "businessRequestHash", "attemptTransactionXid8"]
        and attempt_boundary.get("audit_contract", {}).get("attempt_transaction_xid8") == {"source": "server-only pg_current_xact_id()", "wire_type": "canonical unsigned decimal string", "generated_column": "ops.audit_events.attempt_transaction_xid8", "audit_hash_preimage": "REQUIRED"}
        and "v_attempt_transaction_xid8=pg_current_xact_id()" in " ".join(str(row) for row in attempt_function.get("algorithm", []))
        and "raw JTI" in attempt_boundary.get("audit_contract", {}).get("forbidden", []),
        "journey assertion attempt wrapper type, replay error, audit or ACL contract drifted",
    )
    result.require(
        attempt_boundary.get("entry_transport_mapping") == ENTRY_TRANSPORT_MAPPING,
        "journey assertion attempt ACTOR/SERVICE transport request, wire digest or business hash mapping drifted",
    )
    result.require(
        reason_shape.get("discriminator") == "decision"
        and reason_shape.get("closed_decline_reason_codes") == DECLINE_REASON_CODES
        and reason_shape.get("branches") == ATTEMPT_REASON_BRANCHES
        and "before replay-guard access" in str(reason_shape.get("attempt_boundary_rule", ""))
        and attempt_function.get("assertion_authority_by_session_user")
        == {
            "gurine_control_api": {"assertion_type": "ACTOR", "authority": "persisted human receiver identity"},
            "gurine_workflow_worker": {"assertion_type": "SERVICE", "authority": "persisted service acknowledgement authority"},
        },
        "journey assertion attempt ACK/DECLINE shape or ACTOR/SERVICE authority mapping drifted",
    )
    type_acl = boundary.get("sql_composite_types", {}).get("exact_type_acl", {})
    result.require(
        type_acl.get("ops.idempotency_finalize_v1", {}).get("gurine_workflow_worker") == ["USAGE"]
        and type_acl.get("ops.idempotency_finalize_receipt_v1", {}).get("gurine_workflow_worker") == ["USAGE"]
        and all(
            type_acl.get(name, {}).get("gurine_workflow_worker") == []
            for name in ("ops.idempotency_claim_v1", "ops.idempotency_claim_receipt_v1", "ops.idempotency_replay_v1", "ops.idempotency_replay_receipt_v1")
        )
        and boundary.get("composite_type_acl", {}).get("gurine_workflow_worker")
        == ["USAGE_ON_ops.idempotency_finalize_v1", "USAGE_ON_ops.idempotency_finalize_receipt_v1"],
        "workflow-worker generic finalize composite type USAGE ACL is not exact",
    )


def _validate_decision_idempotency_boundary(database: dict[str, Any], result: Validation) -> None:
    types = database.get("journey_decision_idempotency_types", {})
    prepare = types.get("ops.journey_handoff_decision_prepare_v1", {})
    receipt = types.get("ops.journey_handoff_decision_prepare_receipt_v1", {})
    actual_prepare = [(row.get("name"), row.get("type"), row.get("nullable")) for row in prepare.get("fields", [])]
    actual_receipt = [(row.get("name"), row.get("type"), row.get("nullable")) for row in receipt.get("fields", [])]
    result.require(
        actual_prepare == PREPARE_FIELDS
        and actual_receipt == PREPARE_RECEIPT_FIELDS
        and next((row for row in prepare.get("fields", []) if row.get("name") == "decision"), {}).get("closed_values") == ["ACKNOWLEDGE", "DECLINE"]
        and next((row for row in prepare.get("fields", []) if row.get("name") == "assertion_type"), {}).get("closed_values") == ["ACTOR", "SERVICE"]
        and next((row for row in receipt.get("fields", []) if row.get("name") == "disposition"), {}).get("closed_values") == ["NEW", "FINAL_REPLAY"]
        and "FINAL_REPLAY" in str(receipt.get("shape", "")),
        "journey decision prepare input/receipt type, nullability or closed disposition drifted",
    )
    expected_acl = {"gurine_control_api": ["USAGE"], "gurine_workflow_worker": ["USAGE"], "PUBLIC": []}
    result.require(
        types.get("acl", {}).get("ops.journey_handoff_decision_prepare_v1") == expected_acl
        and types.get("acl", {}).get("ops.journey_handoff_decision_prepare_receipt_v1") == expected_acl,
        "journey decision prepare composite type ACL drifted",
    )
    boundary = database.get("journey_decision_idempotency_boundary", {})
    reason_shape = boundary.get("decision_reason_shape", {})
    business_hash = boundary.get("business_hash", {})
    result.require(
        business_hash.get("domain") == "JOURNEY_HANDOFF_DECISION_BUSINESS_V1"
        and business_hash.get("algorithm") == "SHA256(GURINE_CANONICAL_JSON_V1(closed object))"
        and business_hash.get("preimage") == DECISION_BUSINESS_HASH_FIELDS
        and business_hash.get("excludes") == DECISION_BOUNDARY_EXCLUDES,
        "journey decision wire/business/response digest separation or stable preimage drifted",
    )
    result.require(
        {key: value for key, value in reason_shape.items() if key != "enforcement"} == DECISION_REASON_SHAPE
        and "before relation access" in str(reason_shape.get("enforcement", ""))
        and "never accepts plaintext" in str(reason_shape.get("enforcement", "")),
        "journey decision database ACK/DECLINE reason branch contract drifted",
    )
    attempt = boundary.get("attempt_proof", {})
    prepare_boundary = boundary.get("prepare", {})
    apply_boundary = boundary.get("apply", {})
    finalize_boundary = boundary.get("finalize", {})
    xid_matrix = boundary.get("transaction_xid_runtime_matrix", {})
    result.require(
        attempt.get("required_rows") == ["ops.assertion_replay_guard exact assertion_type+jti+wire_request_digest+attempt_transaction_xid8", "ops.audit_events exact auth.assertion.consume SUCCESS attempt+generated attempt_transaction_xid8"]
        and "separately committed" in str(attempt.get("transaction", ""))
        and "ordinary SERIALIZABLE snapshot" in str(attempt.get("mvcc_visibility", ""))
        and "not equal to pg_current_xact_id()" in str(attempt.get("persisted_xid_rule", ""))
        and attempt.get("forbidden_proof") == ["tuple xmin", "row xmin", "txid_current", "caller-supplied xid", "migration backfill"]
        and "NULL is allowed" in str(attempt.get("pg_xact_status_diagnostic", ""))
        and "*_ASSERTION_REPLAYED" in str(attempt.get("duplicate", ""))
        and attempt.get("authority_by_session_user")
        == {
            "gurine_control_api": {"assertion_type": "ACTOR", "entry_boundary": "CONTROL_COMMAND", "receiver_authority": "persisted human receiver identity plus capability object scope and stored assurance"},
            "gurine_workflow_worker": {"assertion_type": "SERVICE", "entry_boundary": "JOURNEY_WORKFLOW_DB_COMMAND", "receiver_authority": "persisted service acknowledgement authority plus workload identity capability object scope and stored assurance"},
        }
        and prepare_boundary.get("signature") == "ops.prepare_journey_handoff_decision_v1(ops.journey_handoff_decision_prepare_v1) RETURNS ops.journey_handoff_decision_prepare_receipt_v1"
        and prepare_boundary.get("execute_roles") == ["gurine_control_api", "gurine_workflow_worker"]
        and prepare_boundary.get("fixed_binding_before_relation_access")
        == {"scope": "JOURNEY_HANDOFF_DECISION", "operation_id": "decideJourneyHandoff", "bff_issuer": None, "session_token_hash": None, "resource_type": "JOURNEY_HANDOFF", "resource_id": "canonical lowercase UUID text of handoff_id"}
        and "RECLAIMED_EXPIRED and IN_PROGRESS are forbidden" in " ".join(str(row) for row in prepare_boundary.get("algorithm", []))
        and "claim_transaction_xid8=pg_current_xact_id()" in " ".join(str(row) for row in prepare_boundary.get("algorithm", []))
        and apply_boundary.get("write_ownership") == ["compiled domain owner relation", "ops.journey_instances", "ops.journey_handoffs", "ops.journey_transition_receipts", "ops.audit_events", "ops.outbox"]
        and apply_boundary.get("forbidden_writes") == ["ops.idempotency_keys", "ops.assertion_replay_guard"]
        and apply_boundary.get("prepared_new_binding")
        == {"row_identity": "(JOURNEY_HANDOFF_DECISION,idempotency_key_sha256)", "operation_id": "decideJourneyHandoff", "request_hash": "recomputed seven-field business hash", "generation": "exact current row generation", "transaction_proof": "claim_transaction_xid8 = pg_current_xact_id(); terminal marker, compatibility JSON, response bytes, digests, receipt, audit, outbox and completion tuple all NULL; xmin is forbidden"}
        and apply_boundary.get("relation_access") == {"ops.idempotency_keys": "exactly-one schema-qualified direct SELECT INTO STRICT of the complete registry column set; zero INSERT/UPDATE/DELETE/COPY; zero helper or owner calls; no SELECT star or dynamic SQL"}
        and finalize_boundary.get("signature") == "ops.finalize_journey_handoff_decision_response_v1(ops.idempotency_finalize_v1) RETURNS ops.idempotency_finalize_receipt_v1"
        and finalize_boundary.get("accepted_argument_type") == "ops.idempotency_finalize_v1"
        and finalize_boundary.get("fixed_binding_before_relation_access") == FIXED_FINALIZE_BINDING
        and finalize_boundary.get("variable_input_fields") == ["key_hash", "request_hash", "expected_claim_generation", "response_header_bytes", "response_body_bytes", "response_digest", "receipt_id", "receipt_digest", "audit_event_id", "outbox_id", "completed_at"]
        and finalize_boundary.get("prepared_new_binding")
        == {"row_identity": "(JOURNEY_HANDOFF_DECISION,key_hash)", "operation_id": "decideJourneyHandoff", "request_hash": "exact seven-field business hash", "generation": "expected_claim_generation", "transaction_proof": "claim_transaction_xid8 = pg_current_xact_id(); terminal marker, compatibility JSON, response bytes, digests, receipt, audit, outbox and completion tuple all NULL before finalize; xmin is forbidden"}
        and finalize_boundary.get("internal_composite_constructor")
        == {"constants": ["scope", "operation_id", "bff_issuer", "session_token_hash", "resource_type", "resource_id", "response_status", "response_schema", "response_media_type"], "verified_variables": ["key_hash", "request_hash", "expected_claim_generation", "response_header_bytes", "response_body_bytes", "response_digest", "receipt_id", "receipt_digest", "audit_event_id", "outbox_id", "completed_at"], "direct_forwarding": "FORBIDDEN"}
        and finalize_boundary.get("write_ownership") == ["ops.idempotency_keys"]
        and len(finalize_boundary.get("validation_order", [])) == 6
        and "claim_transaction_xid8=pg_current_xact_id()" in " ".join(str(row) for row in finalize_boundary.get("validation_order", []))
        and "exact command audit rows" in " ".join(str(row) for row in finalize_boundary.get("validation_order", []))
        and "ops.replay_owner_idempotency_response_v1 is forbidden" in " ".join(str(row) for row in finalize_boundary.get("validation_order", []))
        and "direct post-finalize readback" in str(finalize_boundary.get("rule", ""))
        and finalize_boundary.get("relation_access") == {"ops.idempotency_keys": "exactly one pre-finalize direct locked read plus exactly one post-finalize direct persisted-tuple readback; exactly one owner-finalize call; zero replay-owner calls, other helpers, direct DML, SELECT star or dynamic SQL"}
        and "relation_access_registry" in str(boundary.get("relation_access_registry_ref", ""))
        and set(xid_matrix) == {"same_transaction_attempt", "committed_attempt", "uncommitted_or_aborted_attempt", "savepoint_claim", "vacuum_freeze"}
        and "business writes remain zero" in str(xid_matrix.get("same_transaction_attempt", ""))
        and "nested SAVEPOINT" in str(xid_matrix.get("savepoint_claim", ""))
        and "tuple xmin is a subxid" in str(xid_matrix.get("savepoint_claim", ""))
        and "VACUUM FREEZE" in str(xid_matrix.get("vacuum_freeze", ""))
        and "pg_xact_status NULL is not a hard failure" in str(xid_matrix.get("vacuum_freeze", ""))
        and "inject a new x-request-id" in str(boundary.get("response_rule", ""))
        and "finalized and tombstoned rows are never reclaimed" in str(boundary.get("commit_guard", "")),
        "journey decision prepare/NEW/finalize, no-reclaim or exact-response boundary drifted",
    )
    result.require(
        database.get("journey_decision_idempotency_regprocedure_registry") == DECISION_IDEMPOTENCY_REGPROCEDURES
        and "exactly one pg_proc" in str(database.get("journey_decision_idempotency_regprocedure_exactness_rule", "")),
        "journey decision prepare/finalize regprocedure registry drifted",
    )
    entries = {row.get("name"): row for row in database.get("mutation_entrypoints", {}).get("functions", [])}
    result.require(
        entries.get("ops.prepare_journey_handoff_decision_v1") == {"name": "ops.prepare_journey_handoff_decision_v1", "execute_roles": ["gurine_control_api", "gurine_workflow_worker"], "writes": ["ops.idempotency_keys"]}
        and entries.get("ops.finalize_journey_handoff_decision_response_v1") == {"name": "ops.finalize_journey_handoff_decision_response_v1", "execute_roles": ["gurine_control_api", "gurine_workflow_worker"], "writes": ["ops.idempotency_keys"]},
        "journey decision prepare/finalize mutation entrypoint ACL or write set drifted",
    )


def _validate_routine_guards(database: dict[str, Any], result: Validation) -> None:
    owners = database.get("owner_procedure_contracts", {})
    routine_names = {
        name
        for group in database.get("journey_receipt_kind_partition", {}).values()
        for name in group
    }
    common = database.get("journey_owner_routine_common", {})
    result.require(
        "current_setting('transaction_isolation') = 'serializable'" in str(common.get("isolation_guard", ""))
        and all(owners.get(name, {}).get("transaction") == "SERIALIZABLE" and owners.get(name, {}).get("isolation_guard") == "journey_owner_routine_common.isolation_guard" for name in routine_names),
        "journey owner routines do not fail closed outside SERIALIZABLE caller transactions",
    )
    decide = owners.get("ops.decide_journey_handoff_v1", {})
    result.require(
        decide.get("request_hash_preimage") == DECISION_BUSINESS_HASH_FIELDS
        and decide.get("request_hash_excludes") == DECISION_BUSINESS_HASH_EXCLUDES
        and decide.get("input_order") == ["handoff_id", "expected_handoff_version", "expected_binding_digest", "decision", "reason_code", "reason_encrypted", "reason_digest", "request_id", "idempotency_key_sha256", "assertion_jti"]
        and decide.get("forbidden_writes") == ["ops.idempotency_keys", "ops.assertion_replay_guard"]
        and "JOURNEY_HANDOFF_DECISION alone requires a separately committed fresh JTI" in str(common.get("authorization_attempt_precondition", ""))
        and "no other journey scope inherits that split" in str(common.get("authorization_attempt_precondition", ""))
        and "one exact schema-qualified apply read" in str(common.get("idempotency_boundary", ""))
        and "one full persisted post-readback" in str(common.get("idempotency_boundary", ""))
        and "local encryption occurs only after prepare returns NEW" in str(common.get("randomized_encryption_replay_rule", ""))
        and "same-transaction ops.prepare_journey_handoff_decision_v1 NEW" in " ".join(str(row) for row in decide.get("statements", []))
        and "claim_transaction_xid8=pg_current_xact_id()" in " ".join(str(row) for row in decide.get("statements", []))
        and "Transaction-A attempt_transaction_xid8" in " ".join(str(row) for row in decide.get("statements", []))
        and "zero replay-owner calls" in " ".join(str(row) for row in decide.get("statements", []))
        and "ops.finalize_journey_handoff_decision_response_v1" in " ".join(str(row) for row in decide.get("statements", []))
        and "session_user fixes assertion_jti to ACTOR" in " ".join(str(row) for row in decide.get("statements", []))
        and "service acknowledgement authority" in " ".join(str(row) for row in decide.get("statements", [])),
        "journey decision business hash, fresh attempt, prepare/NEW encryption or finalize boundary drifted",
    )
    entries = {
        row.get("name"): row
        for row in database.get("mutation_entrypoints", {}).get("functions", [])
    }
    for name, expected in ROUTINE_CONTRACTS.items():
        owner = owners.get(name, {})
        result.require(
            entries.get(name, {}).get("execute_roles") == expected["roles"]
            and entries.get(name, {}).get("writes") == expected["writes"]
            and owner.get("writes") == expected["writes"]
            and owner.get("receipt_kinds") == expected["receipts"]
            and owner.get("events") == expected["events"],
            f"{name}: journey routine roles, writes, receipt kinds or event set drifted",
        )
    result.require(
        {receipt for row in ROUTINE_CONTRACTS.values() for receipt in row["receipts"]}
        == set(database.get("journey_receipt_kind_partition", {}))
        and {event for row in ROUTINE_CONTRACTS.values() for event in row["events"]}
        == {"journey.instance_started.v1", "journey.handoff_requested.v1", "journey.handoff_decided.v1", "journey.handoff_escalated.v1", "journey.handoff_expired.v1", "journey.outcome_recorded.v1"},
        "journey routine receipt or event union drifted",
    )


def _validate_result_semantics(database: dict[str, Any], result: Validation) -> None:
    types = database.get("journey_result_types", {})
    result.require(set(types) == set(TYPE_FIELDS), "journey semantic result type set drifted")
    for name, expected in TYPE_FIELDS.items():
        rows = types.get(name, {}).get("fields", [])
        actual = [(row.get("name"), row.get("type"), row.get("nullable")) for row in rows]
        result.require(
            actual == expected and types.get(name, {}).get("usage_acl") == TYPE_ACL[name],
            f"{name}: result attribute type/nullability/order or type USAGE ACL drifted",
        )
    by_type = {
        name: {row.get("name"): row for row in value.get("fields", [])}
        for name, value in types.items()
    }
    result.require(
        by_type["ops.journey_handoff_terminal_result_v1"]["decision"].get("closed_values") == ["ACKNOWLEDGE", "DECLINE"]
        and by_type["ops.journey_handoff_terminal_result_v1"]["resulting_handoff_state"].get("closed_values") == ["ACKNOWLEDGED", "DECLINED"]
        and by_type["ops.journey_replacement_result_v1"]["handoff_version"].get("invariant") == "exactly 1"
        and by_type["ops.journey_instance_head_result_v1"]["active_handoff_state"].get("closed_nonnull_values") == ["PENDING_ACK"]
        and by_type["ops.journey_instance_head_result_v1"]["escalation_state"].get("closed_values") == ["NOT_DUE", "DUE", "ESCALATED", "RESOLVED"]
        and by_type["ops.journey_scheduler_result_v1"]["disposition"].get("closed_values") == ["APPLIED_NEW", "APPLIED_REPLAY", "NOT_DUE", "NO_LONGER_CURRENT", "VERSION_CONFLICT"]
        and by_type["ops.journey_scheduler_result_v1"]["action"].get("closed_values") == ["ESCALATE", "EXPIRE"],
        "journey result closed-value semantics drifted",
    )


def validate_journey_policy(
    database: dict[str, Any],
    idempotency: dict[str, Any],
    result: Validation,
) -> None:
    result.require(
        database.get("journey_compound_transition_contracts") == COMPOUNDS,
        "journey compound physical transition rows drifted",
    )
    _validate_owner_idempotency(idempotency, result)
    validate_journey_access_surface(database, idempotency, result)
    _validate_decision_idempotency_boundary(database, result)
    _validate_routine_guards(database, result)
    _validate_result_semantics(database, result)
