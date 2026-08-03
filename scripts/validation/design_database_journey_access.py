from __future__ import annotations

import hashlib
import json
from typing import Any

from .models import Validation


COMPOSITE_FIELDS = {
    "ops.idempotency_claim_v1": [
        ("scope", "text"), ("operation_id", "text"), ("key_hash", "char(64)"),
        ("request_hash", "char(64)"), ("bff_issuer", "text"),
        ("session_token_hash", "char(64)"), ("resource_type", "text"),
        ("resource_id", "text"), ("expires_at", "timestamptz"),
    ],
    "ops.idempotency_claim_receipt_v1": [
        ("disposition", "text"), ("claim_generation", "bigint"),
        ("response_digest", "char(64)"), ("receipt_digest", "char(64)"),
        ("completed_at", "timestamptz"), ("claim_expires_at", "timestamptz"),
    ],
    "ops.idempotency_finalize_v1": [
        ("scope", "text"), ("operation_id", "text"), ("key_hash", "char(64)"),
        ("request_hash", "char(64)"), ("bff_issuer", "text"),
        ("session_token_hash", "char(64)"), ("expected_claim_generation", "bigint"),
        ("response_status", "integer"), ("response_schema", "text"),
        ("response_media_type", "text"), ("response_header_bytes", "bytea"),
        ("response_body_bytes", "bytea"), ("response_digest", "char(64)"),
        ("resource_type", "text"), ("resource_id", "text"), ("receipt_id", "uuid"),
        ("receipt_digest", "char(64)"), ("audit_event_id", "uuid"),
        ("outbox_id", "uuid"), ("completed_at", "timestamptz"),
    ],
    "ops.idempotency_finalize_receipt_v1": [
        ("claim_generation", "bigint"), ("response_status", "integer"),
        ("response_schema", "text"), ("response_media_type", "text"),
        ("response_digest", "char(64)"), ("receipt_id", "uuid"),
        ("receipt_digest", "char(64)"), ("completed_at", "timestamptz"),
        ("idempotency_replay", "boolean"),
    ],
    "ops.idempotency_replay_v1": [
        ("scope", "text"), ("operation_id", "text"), ("key_hash", "char(64)"),
        ("request_hash", "char(64)"), ("bff_issuer", "text"),
        ("session_token_hash", "char(64)"), ("expected_claim_generation", "bigint"),
    ],
    "ops.idempotency_replay_receipt_v1": [
        ("disposition", "text"), ("claim_generation", "bigint"),
        ("response_status", "integer"), ("response_schema", "text"),
        ("response_media_type", "text"), ("response_header_bytes", "bytea"),
        ("response_body_bytes", "bytea"), ("response_digest", "char(64)"),
        ("receipt_id", "uuid"), ("receipt_digest", "char(64)"),
        ("completed_at", "timestamptz"), ("idempotency_replay", "boolean"),
    ],
}
GENERIC_EXECUTE = {
    "ops.claim_idempotency_v1(ops.idempotency_claim_v1)": ["gurine_submission_api", "gurine_control_api", "gurine_identity_api"],
    "ops.finalize_idempotency_response_v1(ops.idempotency_finalize_v1)": ["gurine_submission_api", "gurine_control_api", "gurine_identity_api"],
    "ops.replay_idempotency_response_v1(ops.idempotency_replay_v1)": ["gurine_submission_api", "gurine_control_api", "gurine_identity_api"],
}
COMPOSITE_USAGE = {
    name: ["gurine_submission_api", "gurine_control_api", "gurine_identity_api"]
    + (["gurine_workflow_worker"] if name in {"ops.idempotency_finalize_v1", "ops.idempotency_finalize_receipt_v1"} else [])
    for name in COMPOSITE_FIELDS
}
TYPE_ACL = {
    name: {
        "gurine_submission_api": ["USAGE"],
        "gurine_control_api": ["USAGE"],
        "gurine_identity_api": ["USAGE"],
        "gurine_workflow_worker": ["USAGE"] if "gurine_workflow_worker" in roles else [],
        "PUBLIC": [],
    }
    for name, roles in COMPOSITE_USAGE.items()
}
GENERIC_EXECUTE_ACL = {
    "PUBLIC": [],
    "gurine_submission_api": ["claim", "finalize", "replay"],
    "gurine_control_api": ["claim", "finalize", "replay"],
    "gurine_identity_api": ["claim", "finalize", "replay"],
    "all_other_runtime_roles": [],
}
GENERIC_COMPOSITE_ACL = {
    "PUBLIC": [],
    "gurine_submission_api": ["USAGE"],
    "gurine_control_api": ["USAGE"],
    "gurine_identity_api": ["USAGE"],
    "gurine_workflow_worker": ["USAGE_ON_ops.idempotency_finalize_v1", "USAGE_ON_ops.idempotency_finalize_receipt_v1"],
    "all_other_runtime_roles": [],
}
OWNER_EXECUTE = {
    "ops.claim_owner_idempotency_v1(ops.idempotency_claim_v1)": ["gurine_migrator"],
    "ops.finalize_owner_idempotency_response_v1(ops.idempotency_finalize_v1)": ["gurine_migrator"],
    "ops.replay_owner_idempotency_response_v1(ops.idempotency_replay_v1)": ["gurine_migrator"],
}
WRAPPER_EXECUTE = {
    "ops.prepare_journey_handoff_decision_v1(ops.journey_handoff_decision_prepare_v1)": ["gurine_control_api", "gurine_workflow_worker"],
    "ops.decide_journey_handoff_v1(uuid,bigint,character,text,text,bytea,character,uuid,character,uuid)": ["gurine_control_api", "gurine_workflow_worker"],
    "ops.finalize_journey_handoff_decision_response_v1(ops.idempotency_finalize_v1)": ["gurine_control_api", "gurine_workflow_worker"],
}
CLOSED_KEYS = {
    "boundary_keys": ["closed_key_contract", "decision_reason_shape", "business_hash", "attempt_proof", "prepare", "apply", "finalize", "relation_access_registry_ref", "transaction_xid_runtime_matrix", "commit_guard", "response_rule", "crash_matrix"],
    "prepare_keys": ["signature", "owner", "security", "volatility", "search_path", "execute_roles", "fixed_binding_before_relation_access", "algorithm"],
    "apply_keys": ["rule", "prepared_new_binding", "relation_access", "write_ownership", "forbidden_writes"],
    "finalize_keys": ["signature", "owner", "security", "volatility", "search_path", "execute_roles", "accepted_argument_type", "fixed_binding_before_relation_access", "variable_input_fields", "prepared_new_binding", "validation_order", "internal_composite_constructor", "write_ownership", "relation_access", "rule"],
    "unknown_key_rule": "any extra key, alternate relation-read declaration, dynamic_sql flag, select_star flag, helper declaration or unregistered access surface is a design and migration failure",
}
NEGATIVE_MUTATIONS = [
    "caller_claim_composite_xid_field", "apply_extra_relation_read", "apply_dynamic_sql",
    "apply_select_star", "owner_helper_overload", "finalize_claim_xid_equality_removed",
    "finalize_post_readback_removed", "finalize_partial_tuple_compare",
    "finalize_replay_owner_call",
]
FIELD_EXTRAS = {
    ("ops.idempotency_claim_receipt_v1", "disposition"): {"closed": ["NEW", "RECLAIMED_EXPIRED", "IN_PROGRESS", "FINAL_AVAILABLE", "LEGACY_FINAL_AVAILABLE"]},
    ("ops.idempotency_finalize_receipt_v1", "idempotency_replay"): {"constant": False},
    ("ops.idempotency_replay_receipt_v1", "disposition"): {"closed": ["RESPONSE_FINAL", "LEGACY_FINAL_COMPAT"]},
    ("ops.idempotency_replay_receipt_v1", "idempotency_replay"): {"constant": True},
}
FUNCTION_KEYS = {
    "claim": {"signature", "volatility", "security_definer", "search_path", "input_fields", "algorithm", "forbidden_return_fields"},
    "finalize": {"signature", "volatility", "security_definer", "search_path", "input_fields", "algorithm", "forbidden"},
    "replay": {"signature", "volatility", "security_definer", "search_path", "input_fields", "algorithm", "output_fields"},
}
FUNCTION_METADATA = {
    "claim": {"signature": "ops.claim_idempotency_v1(ops.idempotency_claim_v1) RETURNS ops.idempotency_claim_receipt_v1", "volatility": "VOLATILE", "security_definer": True, "search_path": ["pg_catalog", "ops"]},
    "finalize": {"signature": "ops.finalize_idempotency_response_v1(ops.idempotency_finalize_v1) RETURNS ops.idempotency_finalize_receipt_v1", "volatility": "VOLATILE", "security_definer": True, "search_path": ["pg_catalog", "ops"]},
    "replay": {"signature": "ops.replay_idempotency_response_v1(ops.idempotency_replay_v1) RETURNS ops.idempotency_replay_receipt_v1", "volatility": "STABLE", "security_definer": True, "search_path": ["pg_catalog", "ops"]},
}
FUNCTION_CONTRACT_DIGEST = "735d5ec3b7f6d5672b93e36836345699eec8e1bdf00e1c0061df62471ee02641"
RUNTIME_DEFINITIONS = [
    "ops.prepare_journey_handoff_decision_v1(ops.journey_handoff_decision_prepare_v1)",
    "ops.decide_journey_handoff_v1(uuid,bigint,character,text,text,bytea,character,uuid,character,uuid)",
    "ops.finalize_journey_handoff_decision_response_v1(ops.idempotency_finalize_v1)",
    "ops.claim_owner_idempotency_v1(ops.idempotency_claim_v1)",
    "ops.finalize_owner_idempotency_response_v1(ops.idempotency_finalize_v1)",
    "ops.replay_owner_idempotency_response_v1(ops.idempotency_replay_v1)",
]
RUNTIME_CATALOG_SOURCES = ["pg_proc", "pg_type", "pg_attribute", "pg_attrdef", "pg_trigger", "pg_depend", "aclexplode", "pg_get_functiondef"]
RUNTIME_ASSERTIONS = [
    "six composite attribute sets have exact ordinal/name/type/typmod and no xid field",
    "no overload/default/variadic/duplicate signature",
    "prepare direct idempotency relation statements zero with claim once and replay iff final",
    "apply one schema-qualified SELECT INTO STRICT and zero DML/helper/owner/dynamic-SQL/SELECT-star",
    "finalize one pre-lock/read plus owner-finalize once plus one complete post-readback and zero replay/helper/direct-DML/dynamic-SQL/SELECT-star",
]
RUNTIME_MUTATION_RUNNER = "build each one-mutation SQL fixture on a clean PostgreSQL 18.4 catalog; the exact validator must fail with its named mutation ID before runtime admission, while the unchanged definition set passes"
PROCEDURE_ROWS = {
    "ops.claim_idempotency_v1(ops.idempotency_claim_v1) RETURNS ops.idempotency_claim_receipt_v1": {"execute": ["gurine_submission_api", "gurine_control_api", "gurine_identity_api"], "volatility": "VOLATILE", "search_path": ["pg_catalog", "ops"]},
    "ops.finalize_idempotency_response_v1(ops.idempotency_finalize_v1) RETURNS ops.idempotency_finalize_receipt_v1": {"execute": ["gurine_submission_api", "gurine_control_api", "gurine_identity_api"], "volatility": "VOLATILE", "search_path": ["pg_catalog", "ops"]},
    "ops.replay_idempotency_response_v1(ops.idempotency_replay_v1) RETURNS ops.idempotency_replay_receipt_v1": {"execute": ["gurine_submission_api", "gurine_control_api", "gurine_identity_api"], "volatility": "STABLE", "search_path": ["pg_catalog", "ops"]},
    "ops.claim_owner_idempotency_v1(ops.idempotency_claim_v1) RETURNS ops.idempotency_claim_receipt_v1": {"execute": ["gurine_migrator"], "owner": "gurine_migrator", "security": "INVOKER", "volatility": "VOLATILE", "search_path": ["pg_catalog", "ops"]},
    "ops.finalize_owner_idempotency_response_v1(ops.idempotency_finalize_v1) RETURNS ops.idempotency_finalize_receipt_v1": {"execute": ["gurine_migrator"], "owner": "gurine_migrator", "security": "INVOKER", "volatility": "VOLATILE", "search_path": ["pg_catalog", "ops"]},
    "ops.replay_owner_idempotency_response_v1(ops.idempotency_replay_v1) RETURNS ops.idempotency_replay_receipt_v1": {"execute": ["gurine_migrator"], "owner": "gurine_migrator", "security": "INVOKER", "volatility": "STABLE", "search_path": ["pg_catalog", "ops"]},
}
DECIDE_OWNER_KEYS = {"sql_signature", "input_order", "transaction", "isolation_guard", "request_hash_preimage", "request_hash_excludes", "writes", "forbidden_writes", "receipt_kinds", "events", "statements", "cardinality", "acl"}
COMMON_OWNER_KEYS = {"owner", "security_definer", "volatility", "search_path", "transaction", "isolation_guard", "network_io", "dynamic_sql", "authorization_attempt_precondition", "lock_order", "idempotency_boundary", "replay_rule", "randomized_encryption_replay_rule"}


def validate_journey_access_surface(
    database: dict[str, Any], document: dict[str, Any], result: Validation,
) -> None:
    boundary = document.get("boundary_procedure_acl", {}).get("idempotency_boundary", {})
    types = boundary.get("sql_composite_types", {})
    result.require(
        types.get("creation_order") == list(COMPOSITE_FIELDS)
        and set(types) == {*COMPOSITE_FIELDS, "creation_order", "nullability_rule", "field_set_oracle", "acl", "exact_type_acl"},
        "idempotency composite type registry or creation order drifted",
    )
    for name, expected in COMPOSITE_FIELDS.items():
        type_row = types.get(name, {})
        rows = type_row.get("fields", [])
        actual = [(row.get("name"), row.get("type")) for row in rows]
        exact_rows = []
        for field, field_type in expected:
            exact_rows.append({"name": field, "type": field_type, **FIELD_EXTRAS.get((name, field), {})})
        result.require(
            actual == expected
            and set(type_row) == {"fields"}
            and rows == exact_rows
            and not any("xid" in str(field).lower() for field, _ in actual),
            f"{name}: caller composite attribute name/type/order or server-xid exclusion drifted",
        )
    functions = boundary.get("functions", {})
    result.require(set(functions) == {"claim", "finalize", "replay"}, "generic idempotency function registry is not exact")
    for key, type_name in (("claim", "ops.idempotency_claim_v1"), ("finalize", "ops.idempotency_finalize_v1"), ("replay", "ops.idempotency_replay_v1")):
        result.require(
            set(functions.get(key, {})) == FUNCTION_KEYS[key]
            and functions.get(key, {}).get("input_fields") == [field for field, _ in COMPOSITE_FIELDS[type_name]],
            f"{key}: function input fields are not exact-equal to its caller composite",
        )
    function_contract_digest = hashlib.sha256(
        json.dumps(
            functions,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    ).hexdigest()
    result.require(
        all(
            all(functions.get(name, {}).get(field) == expected for field, expected in metadata.items())
            for name, metadata in FUNCTION_METADATA.items()
        )
        and function_contract_digest == FUNCTION_CONTRACT_DIGEST,
        "generic idempotency function signature/security/search-path/behavior contract drifted",
    )
    role_surface = document.get("runtime_oracles", {}).get("idempotency_role_surface_exact", {})
    result.require(
        role_surface == {
            "generic_function_execute": GENERIC_EXECUTE,
            "generic_composite_usage": COMPOSITE_USAGE,
            "owner_helper_execute": OWNER_EXECUTE,
            "journey_wrapper_execute": WRAPPER_EXECUTE,
        },
        "idempotency generic/type/owner/wrapper role surface drifted",
    )
    result.require(
        types.get("exact_type_acl") == TYPE_ACL
        and boundary.get("execute_acl") == GENERIC_EXECUTE_ACL
        and boundary.get("composite_type_acl") == GENERIC_COMPOSITE_ACL,
        "declared type/function ACLs are not exact-equal to the role-surface registry",
    )
    decision = database.get("journey_decision_idempotency_boundary", {})
    closed = decision.get("closed_key_contract", {})
    result.require(
        closed == CLOSED_KEYS
        and set(decision) == set(CLOSED_KEYS["boundary_keys"])
        and set(decision.get("prepare", {})) == set(CLOSED_KEYS["prepare_keys"])
        and set(decision.get("apply", {})) == set(CLOSED_KEYS["apply_keys"])
        and set(decision.get("finalize", {})) == set(CLOSED_KEYS["finalize_keys"]),
        "journey decision boundary accepts an unknown access/helper/dynamic-SQL key",
    )
    decide_owner = database.get("owner_procedure_contracts", {}).get("ops.decide_journey_handoff_v1", {})
    common_owner = database.get("journey_owner_routine_common", {})
    result.require(
        set(decide_owner) == DECIDE_OWNER_KEYS
        and set(common_owner) == COMMON_OWNER_KEYS
        and str(common_owner.get("dynamic_sql", "")).startswith("FORBIDDEN")
        and "SELECT *" not in " ".join(str(row) for row in decide_owner.get("statements", [])),
        "journey apply owner/common contract permits an undeclared read, helper, dynamic SQL or SELECT star",
    )
    owner_catalog = boundary.get("owner_internal_function_catalog", {})
    owner_rows = owner_catalog.get("routines", [])
    owner_signatures = [str(row.get("signature")) for row in owner_rows]
    expected_owner = list(OWNER_EXECUTE)
    result.require(
        len(owner_rows) == len(expected_owner)
        and set(owner_catalog) == {"reuse_input_output_types", "creation_order", "routines", "dependency_rule", "generic_exclusion_rule", "membership_rule", "catalog_canary"}
        and len(owner_signatures) == len(set(owner_signatures))
        and set(owner_signatures) == set(expected_owner),
        "owner helper signature registry permits an overload, duplicate, default or variadic shadow",
    )
    infrastructure = [
        row for row in document.get("boundary_procedure_acl", {}).get("procedures", [])
        if str(row.get("signature", "")).startswith(tuple(name.split("(", 1)[0] + "(" for name in PROCEDURE_ROWS))
    ]
    actual_procedures = {
        str(row.get("signature")): {key: value for key, value in row.items() if key != "signature"}
        for row in infrastructure
    }
    result.require(
        len(infrastructure) == len(PROCEDURE_ROWS)
        and len(infrastructure) == len(actual_procedures)
        and actual_procedures == PROCEDURE_ROWS,
        "generic/owner infrastructure regprocedure set permits an overload or duplicate",
    )
    journey_rows = database.get("journey_regprocedure_registry", [])
    decision_rows = database.get("journey_decision_idempotency_regprocedure_registry", [])
    result.require(
        len(journey_rows) == len({row.get("name") for row in journey_rows}) == len({row.get("identity") for row in journey_rows})
        and len(decision_rows) == len({row.get("name") for row in decision_rows}) == len({row.get("identity") for row in decision_rows}),
        "journey wrapper regprocedure registry permits an overload or duplicate",
    )
    runtime = document.get("runtime_oracles", {}).get("postgres_18_4_idempotency_canary", {}).get("journey_decision_exact_access", {})
    result.require(
        runtime == {
            "definitions": RUNTIME_DEFINITIONS,
            "catalog_sources": RUNTIME_CATALOG_SOURCES,
            "exact_assertions": RUNTIME_ASSERTIONS,
            "negative_mutations": NEGATIVE_MUTATIONS,
            "mutation_runner": RUNTIME_MUTATION_RUNNER,
        },
        "PostgreSQL 18.4 exact access/call-count mutation gate drifted",
    )
