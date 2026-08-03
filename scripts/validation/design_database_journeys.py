from __future__ import annotations
from typing import Any
import re
from .design_database_support import _foreign_keys, _key_columns, _parse_reference
from .design_database_journey_policy import validate_journey_policy
from .models import Validation
RELATIONS = {
    "ops.journey_instances",
    "ops.journey_handoffs",
    "ops.journey_transition_receipts",
}
ROUTINES = {
    "ops.start_journey_instance_v1",
    "ops.request_journey_handoff_v1",
    "ops.decide_journey_handoff_v1",
    "ops.escalate_journey_handoff_v1",
    "ops.expire_journey_handoff_v1",
    "ops.record_journey_outcome_v1",
}
TRIGGERS = {
    "ops.guard_journey_instance_update_v1",
    "ops.guard_journey_handoff_update_v1",
    "ops.check_journey_decision_idempotency_complete_v1",
    "ops.check_journey_instance_head_v1",
    "ops.check_journey_instance_transition_v1",
    "ops.check_journey_handoff_binding_v1",
    "ops.check_journey_handoff_head_v1",
    "ops.check_journey_receipt_chain_v1",
    "ops.check_journey_receipt_parent_versions_v1",
    "ops.check_journey_receipt_state_owner_v1",
}
TRIGGER_INSTALL = {
    "ops.guard_journey_instance_update_v1": "BEFORE UPDATE OR DELETE ON ops.journey_instances FOR EACH ROW",
    "ops.guard_journey_handoff_update_v1": "BEFORE UPDATE OR DELETE ON ops.journey_handoffs FOR EACH ROW",
    "ops.check_journey_decision_idempotency_complete_v1": "AFTER INSERT OR UPDATE ON ops.idempotency_keys FOR EACH ROW CONSTRAINT DEFERRABLE INITIALLY DEFERRED",
    "ops.check_journey_instance_head_v1": "AFTER INSERT OR UPDATE ON ops.journey_instances FOR EACH ROW CONSTRAINT DEFERRABLE INITIALLY DEFERRED",
    "ops.check_journey_instance_transition_v1": "AFTER INSERT OR UPDATE ON ops.journey_instances FOR EACH ROW CONSTRAINT DEFERRABLE INITIALLY DEFERRED",
    "ops.check_journey_handoff_binding_v1": "AFTER INSERT OR UPDATE ON ops.journey_handoffs FOR EACH ROW CONSTRAINT DEFERRABLE INITIALLY DEFERRED",
    "ops.check_journey_handoff_head_v1": "AFTER INSERT OR UPDATE ON ops.journey_handoffs FOR EACH ROW CONSTRAINT DEFERRABLE INITIALLY DEFERRED",
    "ops.check_journey_receipt_chain_v1": "AFTER INSERT ON ops.journey_transition_receipts FOR EACH ROW CONSTRAINT DEFERRABLE INITIALLY DEFERRED",
    "ops.check_journey_receipt_parent_versions_v1": "AFTER INSERT ON ops.journey_transition_receipts FOR EACH ROW CONSTRAINT DEFERRABLE INITIALLY DEFERRED",
    "ops.check_journey_receipt_state_owner_v1": "AFTER INSERT ON ops.journey_transition_receipts FOR EACH ROW CONSTRAINT DEFERRABLE INITIALLY DEFERRED",
}
RECEIPT_PARTITION = {
    "INSTANCE_STARTED": ["ops.start_journey_instance_v1"],
    "HANDOFF_REQUESTED": ["ops.request_journey_handoff_v1", "ops.decide_journey_handoff_v1", "ops.expire_journey_handoff_v1"],
    "HANDOFF_ACKNOWLEDGED": ["ops.decide_journey_handoff_v1"],
    "HANDOFF_DECLINED": ["ops.decide_journey_handoff_v1"],
    "HANDOFF_ESCALATED": ["ops.escalate_journey_handoff_v1"],
    "HANDOFF_EXPIRED": ["ops.expire_journey_handoff_v1"],
    "HANDOFF_CANCELLED": ["ops.record_journey_outcome_v1"],
    "HANDOFF_SUPERSEDED": ["ops.request_journey_handoff_v1"],
    "OUTCOME_RECORDED": ["ops.record_journey_outcome_v1"],
}
ROUTINE_SIGNATURES = {
    "ops.start_journey_instance_v1": "(text,text,text,bigint,char(64),text,text,bigint,char(64),text,text,text,char(64),timestamptz,uuid,char(64),uuid) -> ops.journey_transition_receipts",
    "ops.request_journey_handoff_v1": "(uuid,bigint,text,char(64),uuid,char(64),uuid) -> ops.journey_transition_receipts",
    "ops.decide_journey_handoff_v1": "(uuid,bigint,char(64),text,text,bytea,char(64),uuid,char(64),uuid) -> ops.journey_handoff_decision_result_v1",
    "ops.escalate_journey_handoff_v1": "(uuid,bigint,uuid) -> ops.journey_scheduler_result_v1",
    "ops.expire_journey_handoff_v1": "(uuid,bigint,uuid) -> ops.journey_scheduler_result_v1",
    "ops.record_journey_outcome_v1": "(uuid,bigint,text,text,text,bigint,char(64),char(64),uuid,char(64),uuid) -> ops.journey_transition_receipts",
}
REGPROCEDURE_IDENTITIES = {
    "ops.start_journey_instance_v1": "ops.start_journey_instance_v1(text,text,text,bigint,character,text,text,bigint,character,text,text,text,character,timestamp with time zone,uuid,character,uuid)",
    "ops.request_journey_handoff_v1": "ops.request_journey_handoff_v1(uuid,bigint,text,character,uuid,character,uuid)",
    "ops.decide_journey_handoff_v1": "ops.decide_journey_handoff_v1(uuid,bigint,character,text,text,bytea,character,uuid,character,uuid)",
    "ops.escalate_journey_handoff_v1": "ops.escalate_journey_handoff_v1(uuid,bigint,uuid)",
    "ops.expire_journey_handoff_v1": "ops.expire_journey_handoff_v1(uuid,bigint,uuid)",
    "ops.record_journey_outcome_v1": "ops.record_journey_outcome_v1(uuid,bigint,text,text,text,bigint,character,character,uuid,character,uuid)",
}
ROUTINE_ROLES = {
    "ops.start_journey_instance_v1": ["gurine_control_api", "gurine_workflow_worker"],
    "ops.request_journey_handoff_v1": ["gurine_control_api", "gurine_workflow_worker"],
    "ops.decide_journey_handoff_v1": ["gurine_control_api", "gurine_workflow_worker"],
    "ops.escalate_journey_handoff_v1": ["gurine_scheduler"],
    "ops.expire_journey_handoff_v1": ["gurine_scheduler"],
    "ops.record_journey_outcome_v1": ["gurine_control_api", "gurine_workflow_worker"],
}
BOUNDARY_ROUTINE_ROLES = {
    "ops.consume_journey_handoff_assertion_attempt_v1": ["gurine_control_api", "gurine_workflow_worker"],
    "ops.prepare_journey_handoff_decision_v1": ["gurine_control_api", "gurine_workflow_worker"],
    "ops.finalize_journey_handoff_decision_response_v1": ["gurine_control_api", "gurine_workflow_worker"],
}
def _named(rows: list[dict[str, Any]], key: str = "name") -> dict[str, dict[str, Any]]:
    return {str(row.get(key)): row for row in rows if isinstance(row, dict)}
def _columns(row: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return _named(row.get("columns", []))
def _checks(row: dict[str, Any]) -> dict[str, str]:
    return {
        str(item.get("name")): str(item.get("expression"))
        for item in row.get("checks", [])
        if isinstance(item, dict)
    }
def _validate_relation_shapes(rows: dict[str, dict[str, Any]], result: Validation) -> None:
    instance = rows["ops.journey_instances"]
    handoff = rows["ops.journey_handoffs"]
    receipt = rows["ops.journey_transition_receipts"]
    instance_columns = _columns(instance)
    receipt_columns = _columns(receipt)
    result.require(
        instance_columns.get("escalation_state", {}).get("default") == "'NOT_DUE'"
        and "last_receipt_sequence = version" in _checks(instance).get("journey_instances_sequence_ck", "")
        and "'NOT_DUE'" in _checks(instance).get("journey_instances_escalation_ck", "")
        and "'NONE'" not in _checks(instance).get("journey_instances_escalation_ck", ""),
        "ops.journey_instances escalation or version/head parity drifted",
    )
    indexes = _named(handoff.get("indexes", []))
    result.require(
        indexes.get("journey_handoffs_pending_due_idx", {}).get("keys")
        == ["due_at ASC", "journey_instance_id ASC", "id ASC"]
        and indexes.get("journey_handoffs_pending_due_idx", {}).get("predicate")
        == "state = 'PENDING_ACK'",
        "ops.journey_handoffs pending due index drifted",
    )
    outbox = receipt_columns.get("outbox_event_id", {})
    result.require(
        receipt_columns.get("prior_due_at") == {"name": "prior_due_at", "type": "timestamptz", "nullable": True, "default": "NONE"}
        and receipt_columns.get("resulting_due_at") == {"name": "resulting_due_at", "type": "timestamptz", "nullable": False, "default": "NONE"}
        and outbox.get("nullable") is True,
        "journey receipt due continuity columns or eventless outbox nullability drifted",
    )
    checks = _checks(receipt)
    instance_tokens = set(re.findall(r"'([A-Z_]+)'", _checks(instance).get("journey_instances_escalation_ck", "")))
    receipt_tokens = set(re.findall(r"'([A-Z_]+)'", checks.get("journey_transition_receipts_escalation_ck", "")))
    result.require(
        "journey_instance_version = sequence" in checks.get("journey_transition_receipts_sequence_ck", "")
        and "prior_due_at IS NULL" in checks.get("journey_transition_receipts_sequence_ck", "")
        and "prior_due_at IS NOT NULL" in checks.get("journey_transition_receipts_sequence_ck", "")
        and "'NOT_DUE'" in checks.get("journey_transition_receipts_escalation_ck", "")
        and "HANDOFF_CANCELLED" in checks.get("journey_transition_receipts_outbox_ck", "")
        and "HANDOFF_SUPERSEDED" in checks.get("journey_transition_receipts_outbox_ck", ""),
        "journey receipt sequence, escalation or eventless outbox CHECK drifted",
    )
    result.require(
        instance_tokens == receipt_tokens == {"NOT_DUE", "DUE", "ESCALATED", "RESOLVED"},
        "journey stored escalation CHECK token sets are not exact",
    )
    handoff_uniques = _named(handoff.get("uniques", []))
    receipt_uniques = _named(receipt.get("uniques", []))
    result.require(
        handoff_uniques.get("journey_handoffs_one_pending_uq")
        == {"name": "journey_handoffs_one_pending_uq", "columns": ["journey_instance_id"], "predicate": "state = 'PENDING_ACK'"}
        and receipt_uniques.get("journey_transition_receipts_one_handoff_version_uq")
        == {"name": "journey_transition_receipts_one_handoff_version_uq", "columns": ["journey_instance_id", "handoff_id", "handoff_version"], "nulls": "DISTINCT"},
        "journey pending-handoff or one-handoff-version unique contract drifted",
    )
def _validate_foreign_keys(rows: dict[str, dict[str, Any]], result: Validation) -> None:
    expected = {
        "ops.journey_instances": {
            "journey_instances_last_receipt_fk": (("last_receipt_id", "id", "version", "last_receipt_digest"), ("ops.journey_transition_receipts", ("id", "journey_instance_id", "journey_instance_version", "receipt_digest"))),
            "journey_instances_active_handoff_fk": (("active_handoff_id", "id", "active_handoff_generation", "active_handoff_state"), ("ops.journey_handoffs", ("id", "journey_instance_id", "generation", "state"))),
        },
        "ops.journey_handoffs": {
            "journey_handoffs_instance_fk": (("journey_instance_id", "journey_code"), ("ops.journey_instances", ("id", "journey_code"))),
            "journey_handoffs_request_receipt_fk": (("request_receipt_id", "journey_instance_id", "id", "request_receipt_digest"), ("ops.journey_transition_receipts", ("id", "journey_instance_id", "handoff_id", "receipt_digest"))),
            "journey_handoffs_last_receipt_fk": (("last_receipt_id", "journey_instance_id", "id", "version", "last_receipt_digest"), ("ops.journey_transition_receipts", ("id", "journey_instance_id", "handoff_id", "handoff_version", "receipt_digest"))),
        },
        "ops.journey_transition_receipts": {
            "journey_transition_receipts_instance_fk": (("journey_instance_id",), ("ops.journey_instances", ("id",))),
            "journey_transition_receipts_handoff_fk": (("handoff_id", "journey_instance_id"), ("ops.journey_handoffs", ("id", "journey_instance_id"))),
            "journey_transition_receipts_prior_fk": (("prior_receipt_id", "journey_instance_id", "prior_receipt_digest"), ("ops.journey_transition_receipts", ("id", "journey_instance_id", "receipt_digest"))),
        },
    }
    deferred = {
        "journey_instances_last_receipt_fk": "INITIALLY_DEFERRED",
        "journey_instances_active_handoff_fk": "INITIALLY_DEFERRED",
        "journey_handoffs_instance_fk": False,
        "journey_handoffs_request_receipt_fk": "INITIALLY_DEFERRED",
        "journey_handoffs_last_receipt_fk": "INITIALLY_DEFERRED",
        "journey_transition_receipts_instance_fk": "INITIALLY_DEFERRED",
        "journey_transition_receipts_handoff_fk": "INITIALLY_DEFERRED",
        "journey_transition_receipts_prior_fk": "INITIALLY_DEFERRED",
    }
    for relation, contracts in expected.items():
        foreign_keys = _foreign_keys(rows[relation])
        by_name = _named(foreign_keys)
        result.require(
            set(by_name) == set(contracts),
            f"{relation}: journey FK registry drifted",
        )
        index_keys = [
            tuple(str(key).split()[0] for key in item.get("keys", item.get("columns", [])))
            for item in rows[relation].get("indexes", []) + rows[relation].get("uniques", [])
            if isinstance(item, dict)
        ]
        for foreign_key in foreign_keys:
            source = _key_columns(foreign_key.get("columns"))
            expected_source, expected_target = contracts.get(str(foreign_key.get("name")), ((), None))
            target = _parse_reference(foreign_key)
            result.require(
                source == expected_source
                and target == expected_target
                and foreign_key.get("on_delete") == "RESTRICT"
                and foreign_key.get("deferrable") == deferred[foreign_key.get("name")]
                and any(keys[: len(source)] == source for keys in index_keys),
                f"{relation}: FK {foreign_key.get('name')} mapping, delete action or leading index drifted",
            )
            if relation == "ops.journey_transition_receipts" and target:
                result.require(
                    "version" not in target[1],
                    f"{relation}: receipt FK targets mutable parent version columns",
                )
    exact_indexes = {
        "ops.journey_instances": {
            "journey_instances_receipt_fk_idx": {"name": "journey_instances_receipt_fk_idx", "method": "btree", "keys": ["last_receipt_id", "id", "version", "last_receipt_digest"]},
            "journey_instances_active_handoff_fk_idx": {"name": "journey_instances_active_handoff_fk_idx", "method": "btree", "keys": ["active_handoff_id", "id", "active_handoff_generation", "active_handoff_state"], "predicate": "active_handoff_id IS NOT NULL"},
        },
        "ops.journey_handoffs": {
            "journey_handoffs_instance_fk_idx": {"name": "journey_handoffs_instance_fk_idx", "method": "btree", "keys": ["journey_instance_id", "journey_code"]},
            "journey_handoffs_request_receipt_fk_idx": {"name": "journey_handoffs_request_receipt_fk_idx", "method": "btree", "keys": ["request_receipt_id", "journey_instance_id", "id", "request_receipt_digest"]},
            "journey_handoffs_last_receipt_fk_idx": {"name": "journey_handoffs_last_receipt_fk_idx", "method": "btree", "keys": ["last_receipt_id", "journey_instance_id", "id", "version", "last_receipt_digest"]},
            "journey_handoffs_pending_due_idx": {"name": "journey_handoffs_pending_due_idx", "method": "btree", "keys": ["due_at ASC", "journey_instance_id ASC", "id ASC"], "predicate": "state = 'PENDING_ACK'"},
        },
        "ops.journey_transition_receipts": {
            "journey_transition_receipts_handoff_fk_idx": {"name": "journey_transition_receipts_handoff_fk_idx", "method": "btree", "keys": ["handoff_id", "journey_instance_id"], "predicate": "handoff_id IS NOT NULL"},
            "journey_transition_receipts_prior_fk_idx": {"name": "journey_transition_receipts_prior_fk_idx", "method": "btree", "keys": ["prior_receipt_id", "journey_instance_id", "prior_receipt_digest"], "predicate": "prior_receipt_id IS NOT NULL"},
        },
    }
    for relation, expected_indexes in exact_indexes.items():
        actual = _named(rows[relation].get("indexes", []))
        result.require(
            all(actual.get(name) == row for name, row in expected_indexes.items()),
            f"{relation}: journey FK/due btree index or predicate-safety contract drifted",
        )
def _validate_trigger_catalog(document: dict[str, Any], result: Validation) -> None:
    rows = document.get("support_functions_and_triggers", [])
    by_name = _named(rows)
    result.require(len(rows) == len(by_name), "0028 support function registry has duplicate names")
    journey_trigger_names = {
        name
        for name, row in by_name.items()
        if "journey_" in name and row.get("signature") == "() -> trigger"
    }
    result.require(journey_trigger_names == TRIGGERS, "journey trigger function registry is not exact")
    for name in TRIGGERS:
        row = by_name.get(name, {})
        guard = name.startswith("ops.guard_")
        relation = (
            "ops.idempotency_keys" if "journey_decision_idempotency_" in name else
            "ops.journey_instances" if "journey_instance_" in name else
            "ops.journey_handoffs" if "journey_handoff_" in name else
            "ops.journey_transition_receipts"
        )
        events = ["UPDATE", "DELETE"] if guard else (["INSERT", "UPDATE"] if relation != "ops.journey_transition_receipts" else ["INSERT"])
        trigger_contract = {"timing": "BEFORE" if guard else "AFTER", "events": events, "relation": relation, "for_each": "ROW", "constraint": not guard, "deferrable": not guard, "initially_deferred": not guard}
        result.require(
            row.get("signature") == "() -> trigger"
            and row.get("owner") == "gurine_migrator"
            and row.get("execute_roles") == []
            and row.get("install") == TRIGGER_INSTALL[name]
            and "SECURITY DEFINER" in str(row.get("properties", ""))
            and "fixed search_path pg_catalog,ops,pg_temp" in str(row.get("properties", ""))
            and (name.startswith("ops.guard_") or "DEFERRABLE INITIALLY DEFERRED" in str(row.get("properties", ""))),
            f"{name}: trigger signature, owner, ACL or installation drifted",
        )
        result.require(
            row.get("trigger_contract") == trigger_contract
            and row.get("security_contract") == {"security_definer": True, "search_path": ["pg_catalog", "ops", "pg_temp"], "public_execute": False, "runtime_execute": []},
            f"{name}: structured trigger timing, deferrability or security contract drifted",
        )
    failure = document.get("journey_trigger_failure_contract", {})
    result.require(
        failure.get("sqlstates") == {"parity": "23514", "immutable": "55000", "privilege": "42501", "unique": "23505"}
        and failure.get("named_constraints") == ["journey_receipt_chain_parity", "journey_receipt_parent_version_parity", "journey_receipt_state_owner_parity", "journey_instance_head_parity", "journey_instance_transition_parity", "journey_handoff_binding_parity", "journey_handoff_head_parity", "journey_decision_idempotency_complete"],
        "journey trigger SQLSTATE or named parity constraint contract drifted",
    )
def _validate_routines(document: dict[str, Any], result: Validation) -> None:
    entries = _named(document.get("mutation_entrypoints", {}).get("functions", []))
    owners = document.get("owner_procedure_contracts", {})
    result.require(ROUTINES <= set(entries) and ROUTINES <= set(owners), "journey routine registry is incomplete")
    idempotency_owner_routines = {"ops.start_journey_instance_v1", "ops.request_journey_handoff_v1", "ops.record_journey_outcome_v1"}
    result.require(
        all(entries[name].get("execute_roles") == ROUTINE_ROLES[name] for name in ROUTINES)
        and all(owners[name].get("sql_signature") == ROUTINE_SIGNATURES[name] for name in ROUTINES)
        and all("ops.idempotency_keys" in entries[name].get("writes", []) for name in idempotency_owner_routines)
        and "ops.idempotency_keys" not in entries["ops.decide_journey_handoff_v1"].get("writes", [])
        and "ops.idempotency_keys" not in owners["ops.decide_journey_handoff_v1"].get("writes", [])
        and owners["ops.decide_journey_handoff_v1"].get("forbidden_writes") == ["ops.idempotency_keys", "ops.assertion_replay_guard"]
        and "observed_at" not in str(owners["ops.escalate_journey_handoff_v1"].get("input_order", []))
        and "observed_at" not in str(owners["ops.expire_journey_handoff_v1"].get("input_order", []))
        and "bytea" in owners["ops.decide_journey_handoff_v1"].get("sql_signature", "")
        and "char(64)" in owners["ops.decide_journey_handoff_v1"].get("sql_signature", ""),
        "journey owner routine idempotency, clock or encrypted reason boundary drifted",
    )
    result.require(
        document.get("journey_receipt_kind_partition") == RECEIPT_PARTITION,
        "journey six-routine to nine-receipt partition drifted",
    )
    registry = _named(document.get("journey_regprocedure_registry", []))
    result.require(
        set(registry) == ROUTINES
        and all(registry[name].get("execute_roles") == ROUTINE_ROLES[name] for name in ROUTINES)
        and all(registry[name].get("returns") == ROUTINE_SIGNATURES[name].split(" -> ", 1)[1] for name in ROUTINES)
        and all(
            registry[name].get("identity") == REGPROCEDURE_IDENTITIES[name]
            for name in ROUTINES
        )
        and "to_regprocedure" in str(document.get("journey_regprocedure_exactness_rule", "")),
        "journey exact regprocedure identity, return type or EXECUTE role registry drifted",
    )
    common = document.get("journey_owner_routine_common", {})
    result.require(
        common.get("owner") == "gurine_migrator"
        and common.get("security_definer") is True
        and common.get("search_path") == ["pg_catalog", "ops", "editorial", "core", "raw", "intake", "extensions", "pg_temp"]
        and "claim_owner_idempotency_v1" in str(common.get("idempotency_boundary", "")),
        "journey owner routine security or dedicated idempotency boundary drifted",
    )
def _validate_result_types(document: dict[str, Any], result: Validation) -> None:
    types = document.get("journey_result_types", {})
    expected = {
        "ops.journey_replacement_result_v1": ["handoff_id", "handoff_version", "generation", "binding_digest", "request_receipt_id", "request_receipt_digest", "request_journey_instance_version", "audit_event_id", "outbox_event_id", "receiver_function", "hard_expiry_at", "resulting_due_at"],
        "ops.journey_handoff_terminal_result_v1": ["receipt_id", "receipt_digest", "journey_instance_id", "journey_instance_version", "handoff_id", "handoff_version", "handoff_kind", "generation", "decision", "resulting_handoff_state", "resulting_journey_state", "current_owner_binding_digest", "next_owner_binding_digest", "audit_event_id", "outbox_event_id"],
        "ops.journey_instance_head_result_v1": ["journey_instance_id", "version", "state", "current_owner_binding_digest", "next_owner_binding_digest", "active_handoff_id", "active_handoff_generation", "active_handoff_state", "escalation_state", "due_at", "head_receipt_id", "head_receipt_digest"],
        "ops.journey_handoff_decision_result_v1": ["decision_receipt", "replacement", "final_parent", "effect_digest", "decided_at"],
        "ops.journey_scheduler_result_v1": ["disposition", "action", "transition_receipt_id", "transition_receipt_digest", "transition_journey_instance_version", "transition_handoff_id", "transition_handoff_version", "transition_audit_event_id", "transition_outbox_event_id", "replacement", "final_parent", "hard_expiry_at", "next_scheduler_at"],
    }
    result.require(set(types) == set(expected), "journey PostgreSQL result type registry drifted")
    for name, fields in expected.items():
        rows = types.get(name, {}).get("fields", [])
        result.require(
            [row.get("name") for row in rows] == fields
            and all(isinstance(row.get("type"), str) and isinstance(row.get("nullable"), bool) for row in rows),
            f"{name}: composite attribute order drifted",
        )
    result.require(
        _named(types["ops.journey_handoff_decision_result_v1"]["fields"])["decision_receipt"]
        == {"name": "decision_receipt", "type": "ops.journey_handoff_terminal_result_v1", "nullable": False}
        and _named(types["ops.journey_handoff_decision_result_v1"]["fields"])["final_parent"]
        == {"name": "final_parent", "type": "ops.journey_instance_head_result_v1", "nullable": False}
        and _named(types["ops.journey_scheduler_result_v1"]["fields"])["final_parent"]
        == {"name": "final_parent", "type": "ops.journey_instance_head_result_v1", "nullable": True},
        "journey nested decision or scheduler final-parent type/nullability drifted",
    )
    catalog = document.get("journey_result_type_catalog_contract", {})
    result.require(
        catalog.get("creation_order") == list(expected)
        and "cannot carry physical NOT NULL" in str(catalog.get("semantic_attribute_rule", ""))
        and "REVOKE ALL ON TYPE" in str(catalog.get("acl_rule", ""))
        and "REVOKE ALL ON TYPES" in str(catalog.get("default_privileges", "")),
        "journey result type creation, semantic validation or ACL contract drifted",
    )
def _validate_acl(document: dict[str, Any], rows: dict[str, dict[str, Any]], result: Validation) -> None:
    acl = document.get("journey_runtime_acl", {})
    table_acl = acl.get("table_acl_exact", {})
    result.require(
        set(table_acl) == RELATIONS
        and all(rows[relation].get("grants") == table_acl[relation] for relation in RELATIONS)
        and acl.get("denied_table_privileges_for_every_runtime_role") == ["INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER"]
        and acl.get("runtime_relation_ownership") == []
        and acl.get("trigger_execute_acl") == [],
        "journey exact table ACL, mutation denial, ownership or trigger ACL drifted",
    )
    effective: dict[str, list[str]] = {}
    for routine, roles in {**ROUTINE_ROLES, **BOUNDARY_ROUTINE_ROLES}.items():
        for role in roles:
            effective.setdefault(role, []).append(routine)
    execute_acl = acl.get("execute_acl_exact", {})
    result.require(
        all(
            len(execute_acl.get(role, [])) == len(set(execute_acl.get(role, [])))
            and set(execute_acl.get(role, [])) == set(routines)
            for role, routines in effective.items()
        )
        and all(execute_acl.get(role) == [] for role in set(execute_acl) - set(effective)),
        "journey effective function EXECUTE ACL is not exact by runtime role",
    )
def validate_journey_database(
    document: dict[str, Any],
    idempotency_document: dict[str, Any],
    rows: dict[str, dict[str, Any]],
    result: Validation,
) -> None:
    result.require(RELATIONS <= set(rows), "journey physical relation set is incomplete")
    if not RELATIONS <= set(rows):
        return
    _validate_relation_shapes(rows, result)
    _validate_foreign_keys(rows, result)
    _validate_trigger_catalog(document, result)
    _validate_routines(document, result)
    _validate_result_types(document, result)
    _validate_acl(document, rows, result)
    validate_journey_policy(document, idempotency_document, result)
    result.require(
        set(document.get("journey_compound_transition_contracts", {}))
        == {"shared_step_one", "decline_with_replacement", "expiry_with_replacement", "supersession_with_replacement", "terminal_outcome_with_cancellation", "replacement_step_two_due_rule", "atomicity"},
        "journey compound physical transition registry drifted",
    )
