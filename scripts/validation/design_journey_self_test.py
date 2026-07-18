from __future__ import annotations

from copy import deepcopy
from dataclasses import replace
from typing import Any, Callable

from .design_database_journeys import validate_journey_database
from .design_database_support import _rows
from .design_domain_journeys import validate_journey_domain
from .design_lifecycle_journeys import validate_journey_events
from .design_journey_graph import validate_journey_graph
from .design_operations_journeys import validate_journey_operations
from .design_support import DesignDocuments
from .design_ui_journeys import validate_journey_ui_contracts
from .loaders import load_yaml
from .models import Validation


def _document_canary(
    documents: DesignDocuments,
    field: str,
    mutate: Callable[[Any], None],
    validator: Callable[[DesignDocuments], None],
) -> bool:
    value = deepcopy(getattr(documents, field))
    mutate(value)
    probe = Validation()
    validator(replace(documents, result=probe, **{field: value}))
    return bool(probe.errors)


def _database_canary(
    documents: DesignDocuments,
    mutate: Callable[[dict[str, Any], dict[str, Any]], None],
) -> bool:
    database = deepcopy(
        documents.physical_table_documents[
            "specs/database/addendum/0028-governance-operations.yaml"
        ]
    )
    idempotency = deepcopy(
        documents.physical_table_documents[
            "specs/database/addendum/0027-communication-consent-delivery.yaml"
        ]
    )
    mutate(database, idempotency)
    probe = Validation()
    validate_journey_database(database, idempotency, _rows(database), probe)
    return bool(probe.errors)


def _ui_canary(
    documents: DesignDocuments,
    mutate: Callable[[dict[str, Any], dict[str, Any]], None],
) -> bool:
    actions = load_yaml(documents.root / "specs/ui/screen-action-contracts.yaml")
    effective = load_yaml(documents.root / "specs/ui/effective-screen-contracts.yaml")
    mutate(actions, effective)
    probe = Validation()
    validate_journey_ui_contracts(actions, effective, probe)
    return bool(probe.errors)


def _graph_canary(
    documents: DesignDocuments,
    field: str,
    mutate: Callable[[dict[str, Any]], None],
) -> bool:
    value = deepcopy(getattr(documents, field))
    mutate(value)
    probe = Validation()
    validate_journey_graph(replace(documents, result=probe, **{field: value}))
    return bool(probe.errors)


def _journey_command(document: dict[str, Any]) -> dict[str, Any]:
    return document["external_commands"]["decideJourneyHandoff"]


def self_test_journey_validators(documents: DesignDocuments) -> None:
    result = documents.result
    canaries = {
        "je_edge": _document_canary(documents, "state_machines", lambda value: value["machines"]["journey_escalation"]["edges"][1].__setitem__("to", "ESCALATED"), validate_journey_domain),
        "compound_step": _document_canary(documents, "state_machines", lambda value: value["machines"]["journey_instance"]["compound_branches"]["decline_with_replacement"]["step_1"].__setitem__("parent_to", "WAITING_ACK"), validate_journey_domain),
        "event_field": _document_canary(documents, "event_contracts", lambda value: value["events"]["journey.handoff_requested.v1"]["payload_schema"]["properties"].pop("hardExpiryAt"), validate_journey_events),
        "event_non_due_type": _document_canary(documents, "event_contracts", lambda value: value["events"]["journey.instance_started.v1"]["payload_schema"]["properties"].__setitem__("journeyInstanceId", {"type": "string"}), validate_journey_events),
        "event_due": _document_canary(documents, "event_contracts", lambda value: value["events"]["journey.handoff_decided.v1"].__setitem__("due_binding", "drift"), validate_journey_events),
        "command_cardinality": _document_canary(documents, "command_semantics", lambda value: _journey_command(value)["cardinality"]["with_replacement"].__setitem__("transition_receipts", 1), validate_journey_operations),
        "idempotency_ephemeral_hash_field": _document_canary(documents, "command_semantics", lambda value: _journey_command(value)["idempotency_request_hash"]["includes"].append("requestId"), validate_journey_operations),
        "idempotency_reason_digest_removed": _document_canary(documents, "command_semantics", lambda value: _journey_command(value)["idempotency_request_hash"]["includes"].remove("reasonDigest"), validate_journey_operations),
        "idempotency_profile_overextension": _document_canary(documents, "command_semantics", lambda value: value["shared_contracts"]["fresh-assertion-stable-business-idempotency-v1"]["operations"].append("cancelAgentRun"), validate_journey_operations),
        "operation_attempt_xid_contract": _document_canary(documents, "operation_contracts", lambda value: next(row for row in value["operations"] if row.get("operation_id") == "decideJourneyHandoff")["transaction_identity_contract"].__setitem__("authorization_attempt", "row exists"), validate_journey_operations),
        "operation_finalize_access_contract": _document_canary(documents, "operation_contracts", lambda value: next(row for row in value["operations"] if row.get("operation_id") == "decideJourneyHandoff")["idempotency_relation_access"].__setitem__("finalize", "owner finalize only"), validate_journey_operations),
        "command_attempt_current_xid_inequality": _document_canary(documents, "command_semantics", lambda value: value["shared_contracts"]["fresh-assertion-stable-business-idempotency-v1"]["transaction_a_proof"].__setitem__("predicate", "both rows exist"), validate_journey_operations),
        "command_claim_savepoint_proof": _document_canary(documents, "command_semantics", lambda value: value["shared_contracts"]["fresh-assertion-stable-business-idempotency-v1"]["transaction_b_claim_proof"].__setitem__("apply_finalize_predicate", "xmin=current"), validate_journey_operations),
        "command_apply_access_expanded": _document_canary(documents, "command_semantics", lambda value: _journey_command(value)["idempotency_relation_access"]["apply"].__setitem__("dml", "one update"), validate_journey_operations),
        "operation_ack_reason_digest": _document_canary(documents, "operation_contracts", lambda value: next(row for row in value["operations"] if row.get("operation_id") == "decideJourneyHandoff")["decision_reason_shape"]["branches"]["ACKNOWLEDGE"].__setitem__("reasonDigest", "OPTIONAL"), validate_journey_operations),
        "command_decline_reason_ciphertext": _document_canary(documents, "command_semantics", lambda value: _journey_command(value)["decision_reason_shape"]["branches"]["DECLINE"].__setitem__("reasonEncrypted", "MUST_BE_NULL"), validate_journey_operations),
        "resource_decline_reason_code": _document_canary(documents, "resource_error_contracts", lambda value: value["request_schemas_by_operation"]["decideJourneyHandoff"]["decision_reason_shape"]["closed_decline_reason_codes"].pop(), validate_journey_operations),
        "resource_service_boundary_assertion": _document_canary(documents, "resource_error_contracts", lambda value: value["journey_handoff_decision_entry_boundaries"]["internal_service_workflow"].__setitem__("assertion_type", "ACTOR"), validate_journey_operations),
        "resource_transaction_xid_contract": _document_canary(documents, "resource_error_contracts", lambda value: value["journey_handoff_decision_entry_boundaries"]["transaction_identity_contract"].__setitem__("attempt_proof", "committed row"), validate_journey_operations),
        "resource_persisted_readback": _document_canary(documents, "resource_error_contracts", lambda value: value["journey_handoff_decision_entry_boundaries"].__setitem__("persisted_response_verification", "digest only"), validate_journey_operations),
        "resource_service_envelope_digest": _document_canary(documents, "resource_error_contracts", lambda value: value["transport_profiles"]["JOURNEY_WORKFLOW_DB_COMMAND"]["required_envelope"].pop("commandEnvelopeDigest"), validate_journey_operations),
        "resource_service_wire_digest_mapping": _document_canary(documents, "resource_error_contracts", lambda value: value["transport_profiles"]["JOURNEY_WORKFLOW_DB_COMMAND"]["database_mapping"].__setitem__("wire_request_digest", "semanticRequestDigest"), validate_journey_operations),
        "resource_actor_operation_binding": _document_canary(documents, "resource_error_contracts", lambda value: value["operation_bindings"]["decideJourneyHandoff"].__setitem__("entry_boundary", "internal_service_workflow"), validate_journey_operations),
        "operation_service_transport": _document_canary(documents, "operation_contracts", lambda value: next(row for row in value["operations"] if row.get("operation_id") == "decideJourneyHandoff")["entry_boundaries"]["internal_service_workflow"].__setitem__("transport", "CONTROL_COMMAND"), validate_journey_operations),
        "command_service_target": _document_canary(documents, "command_semantics", lambda value: _journey_command(value)["entry_boundaries"].__setitem__("service_canonical_target", "ops.decide_journey_handoff_v1"), validate_journey_operations),
        "command_service_idempotency_key": _document_canary(documents, "command_semantics", lambda value: _journey_command(value)["idempotency_key_sources"].__setitem__("internal_service_workflow", "HTTP Idempotency-Key"), validate_journey_operations),
        "persistence_service_session": _document_canary(documents, "persistence_contracts", lambda value: value["exact_persistence_registry"]["external_command_persistence"]["decideJourneyHandoff"]["entry_boundaries"]["internal_service_workflow"].__setitem__("session_user", "gurine_control_api"), validate_journey_operations),
        "persistence_service_idempotency_key": _document_canary(documents, "persistence_contracts", lambda value: value["exact_persistence_registry"]["external_command_persistence"]["decideJourneyHandoff"]["idempotency"]["key_sources"].__setitem__("internal_service_workflow", "HTTP Idempotency-Key"), validate_journey_operations),
        "persistence_apply_idempotency_write": _document_canary(documents, "persistence_contracts", lambda value: value["exact_persistence_registry"]["external_command_persistence"]["decideJourneyHandoff"]["write_ownership"]["apply"].append("ops.idempotency_keys"), validate_journey_operations),
        "persistence_claim_xid_contract": _document_canary(documents, "persistence_contracts", lambda value: value["exact_persistence_registry"]["external_command_persistence"]["decideJourneyHandoff"]["transaction_identity"].__setitem__("claim_predicate", "xmin=current"), validate_journey_operations),
        "persistence_finalize_replay_owner": _document_canary(documents, "persistence_contracts", lambda value: value["exact_persistence_registry"]["external_command_persistence"]["decideJourneyHandoff"]["relation_access_registry"]["finalize"].__setitem__("owner_replay", "exactly-once"), validate_journey_operations),
        "assertion_replay_error_weakened": _document_canary(documents, "operation_contracts", lambda value: next(row for row in value["operations"] if row.get("operation_id") == "decideJourneyHandoff")["errors"].remove("ACTOR_ASSERTION_REPLAYED"), validate_journey_operations),
        "resource_type": _document_canary(documents, "resource_error_contracts", lambda value: value["schemas"]["JourneyHandoffReplacementReceiptV1"]["fields"].__setitem__("receiverFunction", "uuid"), validate_journey_operations),
        "trigger_timing": _database_canary(documents, lambda database, _: next(row for row in database["support_functions_and_triggers"] if row.get("name") == "ops.check_journey_receipt_chain_v1")["trigger_contract"].__setitem__("timing", "BEFORE")),
        "fk_target": _database_canary(documents, lambda database, _: next(row for row in next(table for table in database["table_contracts"] if table["relation"] == "ops.journey_transition_receipts")["foreign_keys"] if row["name"] == "journey_transition_receipts_instance_fk").__setitem__("references", "ops.journey_instances(id,version)")),
        "result_nullability": _database_canary(documents, lambda database, _: next(row for row in database["journey_result_types"]["ops.journey_scheduler_result_v1"]["fields"] if row["name"] == "final_parent").__setitem__("nullable", False)),
        "table_acl": _database_canary(documents, lambda database, _: database["journey_runtime_acl"]["table_acl_exact"]["ops.journey_instances"]["gurine_control_api"].append("UPDATE")),
        "owner_idempotency_acl": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["owner_internal_function_catalog"]["routines"][0]["execute"].append("gurine_control_api")),
        "isolation_guard": _database_canary(documents, lambda database, _: database["journey_owner_routine_common"].__setitem__("isolation_guard", "NONE")),
        "database_ephemeral_hash_field": _database_canary(documents, lambda database, _: database["owner_procedure_contracts"]["ops.decide_journey_handoff_v1"]["request_hash_preimage"].append("actor_assertion_jti")),
        "decision_prepare_boundary": _database_canary(documents, lambda database, _: database.pop("journey_decision_idempotency_boundary")),
        "decision_incomplete_claim_guard": _database_canary(documents, lambda database, _: database["support_functions_and_triggers"].__setitem__(slice(None), [row for row in database["support_functions_and_triggers"] if row.get("name") != "ops.check_journey_decision_idempotency_complete_v1"])),
        "decision_fresh_scope_overextension": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["journey_owner_routine_internal_scope_registry"]["fresh_assertion_attempt_boundary"]["applies_to_scopes"].append("JOURNEY_START")),
        "decision_attempt_xid_type": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.assertion_replay_guard")["add_columns"]["attempt_transaction_xid8"].__setitem__("type", "xid")),
        "decision_attempt_xid_default": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.assertion_replay_guard")["add_columns"]["attempt_transaction_xid8"].__setitem__("staged_install", "add nullable only")),
        "decision_audit_xid_generated": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.audit_events")["add_columns"]["attempt_transaction_xid8"].__setitem__("generated", "caller supplied")),
        "decision_audit_xid_hash_key": _database_canary(documents, lambda _, idempotency: idempotency["journey_handoff_assertion_attempt_boundary"]["audit_contract"]["exact_detail_keys"].remove("attemptTransactionXid8")),
        "decision_claim_xid_type": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["add_columns"]["claim_transaction_xid8"].__setitem__("type", "bigint")),
        "decision_claim_xid_legacy_backfill": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["add_columns"]["claim_transaction_xid8"].__setitem__("legacy_rows", "BACKFILL_MIGRATION_XID")),
        "decision_claim_xid_caller_input": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["add_columns"]["claim_transaction_xid8"].__setitem__("caller_input", "ALLOWED")),
        "decision_claim_composite_xid_field": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["sql_composite_types"]["ops.idempotency_claim_v1"]["fields"].append({"name": "claim_transaction_xid8", "type": "xid8"})),
        "decision_claim_composite_unknown_annotation": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["sql_composite_types"]["ops.idempotency_claim_v1"]["fields"][0].__setitem__("caller_supplied", True)),
        "generic_claim_signature": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["functions"]["claim"].__setitem__("signature", "ops.claim_idempotency_v1(text) RETURNS ops.idempotency_claim_receipt_v1")),
        "generic_claim_security_definer": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["functions"]["claim"].__setitem__("security_definer", False)),
        "generic_claim_search_path": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["functions"]["claim"].__setitem__("search_path", ["pg_catalog", "ops", "pg_temp"])),
        "generic_claim_volatility": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["functions"]["claim"].__setitem__("volatility", "STABLE")),
        "generic_claim_forbidden_return": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["functions"]["claim"]["forbidden_return_fields"].remove("session_token_hash")),
        "generic_finalize_forbidden": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["functions"]["finalize"]["forbidden"].remove("response-json-reserialization")),
        "generic_replay_output": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["functions"]["replay"]["output_fields"].append("key_hash")),
        "generic_claim_algorithm": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["functions"]["claim"]["algorithm"].append("Dynamic SQL is allowed")),
        "decision_owner_function_caller": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["journey_owner_routine_internal_scope_registry"]["owner_internal_functions"]["exact_outer_caller_registry"]["ops.claim_owner_idempotency_v1"].append("ops.decide_journey_handoff_v1")),
        "decision_owner_helper_overload": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["owner_internal_function_catalog"]["routines"].append({"name": "ops.claim_owner_idempotency_v1", "signature": "ops.claim_owner_idempotency_v1(ops.idempotency_claim_v1,text)", "returns": "ops.idempotency_claim_receipt_v1", "owner": "gurine_migrator", "security": "INVOKER", "volatility": "VOLATILE", "search_path": ["pg_catalog", "ops"], "execute": ["gurine_migrator"]})),
        "decision_apply_idempotency_read_removed": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["journey_owner_routine_internal_scope_registry"]["owner_internal_functions"]["relation_access_registry"]["ops.decide_journey_handoff_v1"]["direct_ops_idempotency_keys"].__setitem__("select", "zero")),
        "decision_apply_idempotency_read_expanded": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["journey_owner_routine_internal_scope_registry"]["owner_internal_functions"]["relation_access_registry"]["ops.decide_journey_handoff_v1"]["direct_ops_idempotency_keys"]["selected_columns"].append("caller_secret")),
        "decision_apply_idempotency_dml": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["journey_owner_routine_internal_scope_registry"]["owner_internal_functions"]["relation_access_registry"]["ops.decide_journey_handoff_v1"]["direct_ops_idempotency_keys"].__setitem__("update", "exactly-one")),
        "decision_apply_idempotency_helper": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["journey_owner_routine_internal_scope_registry"]["owner_internal_functions"]["relation_access_registry"]["ops.decide_journey_handoff_v1"].__setitem__("other_idempotency_helpers", "one")),
        "decision_apply_extra_relation_read": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["apply"].__setitem__("additional_relation_reads", ["ops.secrets"])),
        "decision_apply_dynamic_sql": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["apply"].__setitem__("dynamic_sql", "ALLOWED")),
        "decision_apply_select_star": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["apply"].__setitem__("select_star", "ALLOWED")),
        "decision_apply_owner_extra_relation_read": _database_canary(documents, lambda database, _: database["owner_procedure_contracts"]["ops.decide_journey_handoff_v1"].__setitem__("additional_relation_reads", ["ops.secrets"])),
        "decision_apply_owner_dynamic_sql": _database_canary(documents, lambda database, _: database["owner_procedure_contracts"]["ops.decide_journey_handoff_v1"].__setitem__("dynamic_sql", "ALLOWED")),
        "decision_finalize_post_readback_removed": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["journey_owner_routine_internal_scope_registry"]["owner_internal_functions"]["relation_access_registry"]["ops.finalize_journey_handoff_decision_response_v1"]["direct_ops_idempotency_keys"].__setitem__("post_finalize", "zero")),
        "decision_finalize_partial_compare": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["journey_owner_routine_internal_scope_registry"]["owner_internal_functions"]["relation_access_registry"]["ops.finalize_journey_handoff_decision_response_v1"]["direct_ops_idempotency_keys"].__setitem__("post_finalize_equality", "response_digest only")),
        "decision_finalize_replay_owner": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["journey_owner_routine_internal_scope_registry"]["owner_internal_functions"]["relation_access_registry"]["ops.finalize_journey_handoff_decision_response_v1"]["owner_calls"].__setitem__("ops.replay_owner_idempotency_response_v1", "exactly-once")),
        "decision_idempotency_relation_access": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["privilege_reset"].__setitem__("regrant_rule", "Runtime access is only generic")),
        "decision_wire_boundary_overextension": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["migration"]["existing_relation_changes"] if row.get("relation") == "ops.idempotency_keys")["journey_owner_routine_internal_scope_registry"]["binding_rules"].__setitem__(1, "wire_request_digest proves only the exact HTTP attempt")),
        "decision_service_authority": _database_canary(documents, lambda _, idempotency: idempotency["journey_handoff_assertion_attempt_boundary"]["function"]["assertion_authority_by_session_user"]["gurine_workflow_worker"].__setitem__("assertion_type", "ACTOR")),
        "decision_service_transport_mapping": _database_canary(documents, lambda _, idempotency: idempotency["journey_handoff_assertion_attempt_boundary"]["entry_transport_mapping"]["SERVICE"].__setitem__("wire_request_digest", "business_request_hash")),
        "decision_service_entry_boundary": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["attempt_proof"]["authority_by_session_user"]["gurine_workflow_worker"].__setitem__("entry_boundary", "CONTROL_COMMAND")),
        "decision_worker_finalize_type_usage": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["sql_composite_types"]["exact_type_acl"]["ops.idempotency_finalize_v1"]["gurine_workflow_worker"].clear()),
        "decision_ack_sql_reason_shape": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["decision_reason_shape"]["branches"]["ACKNOWLEDGE"].__setitem__("reason_encrypted", "OPTIONAL")),
        "decision_prepare_scope": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["prepare"]["fixed_binding_before_relation_access"].__setitem__("scope", "JOURNEY_START")),
        "decision_apply_same_transaction_proof": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["apply"]["prepared_new_binding"].__setitem__("transaction_proof", "row exists")),
        "decision_attempt_same_transaction_allowed": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["attempt_proof"].__setitem__("persisted_xid_rule", "both values are non-null and equal")),
        "decision_attempt_xmin_substitution": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["attempt_proof"].__setitem__("forbidden_proof", ["caller-supplied xid"])),
        "decision_attempt_hard_pg_xact_status": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["attempt_proof"].__setitem__("pg_xact_status_diagnostic", "pg_xact_status(attempt_transaction_xid8) = committed is required")),
        "decision_claim_xmin_substitution": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["apply"]["prepared_new_binding"].__setitem__("transaction_proof", "xmin = pg_current_xact_id()")),
        "decision_nested_savepoint_removed": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["transaction_xid_runtime_matrix"].__setitem__("savepoint_claim", "ordinary transaction only")),
        "decision_vacuum_freeze_status_hard_gate": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["transaction_xid_runtime_matrix"].__setitem__("vacuum_freeze", "pg_xact_status must be committed")),
        "decision_finalize_scope": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["finalize"]["fixed_binding_before_relation_access"].__setitem__("scope", "JOURNEY_OUTCOME")),
        "decision_finalize_operation": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["finalize"]["fixed_binding_before_relation_access"].__setitem__("operation_id", "ops.decide_journey_handoff_v1")),
        "decision_finalize_resource_type": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["finalize"]["fixed_binding_before_relation_access"].__setitem__("resource_type", "JOURNEY")),
        "decision_finalize_response_status": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["finalize"]["fixed_binding_before_relation_access"].__setitem__("response_status", 201)),
        "decision_finalize_same_transaction_proof": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["finalize"]["prepared_new_binding"].__setitem__("transaction_proof", "row exists")),
        "decision_finalize_claim_xid_equality_removed": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["finalize"]["prepared_new_binding"].__setitem__("transaction_proof", "terminal tuple all NULL; xmin forbidden")),
        "decision_finalize_direct_forward": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["finalize"]["internal_composite_constructor"].__setitem__("direct_forwarding", "ALLOWED")),
        "decision_finalize_graph_validation": _database_canary(documents, lambda database, _: database["journey_decision_idempotency_boundary"]["finalize"]["validation_order"].pop(2)),
        "decision_apply_idempotency_write": _database_canary(documents, lambda database, _: database["owner_procedure_contracts"]["ops.decide_journey_handoff_v1"]["writes"].insert(0, "ops.idempotency_keys")),
        "decision_apply_argument_name": _database_canary(documents, lambda database, _: database["owner_procedure_contracts"]["ops.decide_journey_handoff_v1"]["input_order"].__setitem__(-1, "actor_assertion_jti")),
        "decision_runtime_wrapper_acl": _database_canary(documents, lambda database, _: database["journey_runtime_acl"]["execute_acl_exact"]["gurine_workflow_worker"].remove("ops.finalize_journey_handoff_decision_response_v1")),
        "decision_role_surface_finalize_usage": _database_canary(documents, lambda _, idempotency: idempotency["runtime_oracles"]["idempotency_role_surface_exact"]["generic_composite_usage"]["ops.idempotency_finalize_v1"].remove("gurine_workflow_worker")),
        "decision_exact_type_acl_extra_usage": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["sql_composite_types"]["exact_type_acl"]["ops.idempotency_claim_v1"]["gurine_workflow_worker"].append("USAGE")),
        "decision_generic_execute_acl_extra_role": _database_canary(documents, lambda _, idempotency: idempotency["boundary_procedure_acl"]["idempotency_boundary"]["execute_acl"].__setitem__("gurine_workflow_worker", ["claim"])),
        "decision_generic_procedure_execute_extra_role": _database_canary(documents, lambda _, idempotency: next(row for row in idempotency["boundary_procedure_acl"]["procedures"] if row.get("signature", "").startswith("ops.claim_idempotency_v1("))["execute"].append("gurine_workflow_worker")),
        "decision_runtime_mutation_registry": _database_canary(documents, lambda _, idempotency: idempotency["runtime_oracles"]["postgres_18_4_idempotency_canary"]["journey_decision_exact_access"]["negative_mutations"].remove("apply_select_star")),
        "decision_runtime_definition_drift": _database_canary(documents, lambda _, idempotency: idempotency["runtime_oracles"]["postgres_18_4_idempotency_canary"]["journey_decision_exact_access"]["definitions"].__setitem__(0, "ops.prepare_journey_handoff_decision_v1(text)")),
        "regprocedure_identity": _database_canary(documents, lambda database, _: database["journey_regprocedure_registry"][0].__setitem__("identity", "ops.start_journey_instance_v1(uuid,text,text,bigint,character,text,text,bigint,character,text,text,text,character,timestamp with time zone,uuid,character,uuid)")),
        "ui_render_order": _ui_canary(documents, lambda actions, _: next(row for row in actions["commands"] if row["operation_id"] == "decideJourneyHandoff").__setitem__("receipt_render_order", ["finalParent", "decisionReceipt", "replacement"])),
        "effective_response": _ui_canary(documents, lambda _, effective: next(row for row in next(screen for screen in effective["screens"] if screen["screen_id"] == "INT-002")["operation_field_contracts"] if row["operation_id"] == "decideJourneyHandoff")["response_field_set"].pop()),
        "graph_edge_identity": _graph_canary(documents, "journey_contracts", lambda value: value["edge_registry"]["J-01"][0].__setitem__(0, "J-01-E99")),
        "graph_branch_set": _graph_canary(documents, "journey_contracts", lambda value: value["branch_contracts"].pop("J-05-E03")),
        "graph_ui_edge_set": _graph_canary(documents, "journey_ui_contracts", lambda value: value["journeys"][0]["edges"].pop()),
        "graph_reachability": _graph_canary(documents, "journey_ui_contracts", lambda value: value["reachability_receipt"]["J-12"].__setitem__("reachable", False)),
        "graph_action_union": _graph_canary(documents, "screen_action_contracts", lambda value: value["journey_visible_actions"].pop()),
    }
    for name, rejected in canaries.items():
        result.require(rejected, f"journey validator negative canary did not reject {name}")
    result.stats["journey_validator_negative_canaries"] = len(canaries)
