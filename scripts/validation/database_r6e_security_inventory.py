from __future__ import annotations

from pathlib import Path
from typing import Any

from pglast import parse_sql
from pglast.enums import ObjectType
from pglast.parser import ParseError

from .database_event_inventory import _canonical_sql, _routine_signature, _sha256
from .database_r6e_ledger_security import validate_new_ledger_security_inventory
from .database_r6e_security_support import (
    ROLE_PREFLIGHT_TOKENS,
    SAFE_SEARCH_PATH,
    TABLE_DML_PRIVILEGES,
    _function_identity,
    _function_mutation_inventory,
    _is_security_definer,
    _object_identity,
    _role_name,
    _runtime_dml,
    _search_path,
)
from .loaders import load_yaml
from .models import Validation


_INERT_WRITER_ROLES = {"gurine_economics_writer", "gurine_payment_writer"}
_R6E_SERVICE_ROLES = {"gurine_billing_gateway", "gurine_economics_importer"}
_UNAVAILABLE_ECONOMICS_RELATIONS = {
    "ops.outcome_facts",
    "editorial.funding_disclosure_revisions",
    "editorial.funding_disclosure_entries",
}
_FUNDING_LIFECYCLE_OPERATIONS = [
    "createActionProposal",
    "updateActionDraft",
    "previewActionDraft",
    "submitActionForReview",
    "claimActionReview",
    "submitActionDecision",
]
_FUNDING_DISPATCHER_SIGNATURE = (
    "ops.execute_action_approval_v1(p_operation text, p_request jsonb, "
    "p_actor uuid) RETURNS jsonb"
)


def _funding_disclosure_lifecycle_guard(
    contract: dict[str, Any],
    functions: dict[str, tuple[str, Any]],
    owners: dict[str, str],
    execute_grants: dict[str, set[str]],
    public_revokes: set[str],
    result: Validation,
) -> None:
    gate = contract.get("funding_disclosure_publisher_gate", {}).get(
        "lifecycle_gate", {}
    )
    function = functions.get(_FUNDING_DISPATCHER_SIGNATURE)
    result.require(
        gate.get("source_freeze_status") == "FINAL"
        and gate.get("dispatcher_source_signature")
        == _FUNDING_DISPATCHER_SIGNATURE
        and gate.get("supported_operations_exactly")
        == _FUNDING_LIFECYCLE_OPERATIONS
        and gate.get("error_sqlstate") == "55000"
        and gate.get("error_code")
        == "FUNDING_DISCLOSURE_AUTHORITY_UNAVAILABLE",
        "0041 funding-disclosure lifecycle guard contract is not FINAL",
    )
    result.require(
        function is not None,
        "0041 funding-disclosure lifecycle dispatcher is missing",
    )
    if function is None:
        return
    identity, statement = function
    canonical = _canonical_sql(statement)
    expected_digest = gate.get("dispatcher_canonical_ddl_sha256")
    result.require(
        isinstance(expected_digest, str)
        and _sha256(canonical.encode()) == expected_digest,
        "0041 funding-disclosure lifecycle dispatcher digest differs",
    )
    result.require(
        _is_security_definer(statement)
        and owners.get(identity) == "gurine_migrator"
        and execute_grants.get(identity, set()) == {"gurine_control_api"}
        and identity in public_revokes
        and _search_path(statement) == ("pg_catalog", "ops", "pg_temp")
        and not _function_mutation_inventory(statement, result),
        "0041 funding-disclosure lifecycle dispatcher ACL or direct DML differs",
    )
    folded = canonical.lower()
    result.require(
        all(operation.lower() in folded for operation in _FUNDING_LIFECYCLE_OPERATIONS)
        and "funding_disclosure_authority_unavailable" in folded
        and "for share of proposal" in folded
        and "execute_action_approval_v1_legacy_0030" in folded,
        "0041 funding-disclosure lifecycle dispatcher source fence differs",
    )


def _role_preflight(
    statements: tuple[Any, ...],
    contract: dict[str, Any],
    result: Validation,
) -> None:
    roles = contract.get("runtime_role_preflight_contract", {}).get("roles", [])
    role_names = {
        row.get("role") for row in roles if isinstance(row, dict)
    }
    candidates: list[tuple[int, str]] = []
    for ordinal, raw_statement in enumerate(statements):
        statement = raw_statement.stmt
        if type(statement).__name__ != "DoStmt":
            continue
        canonical = _canonical_sql(statement)
        if role_names and all(role in canonical for role in role_names):
            candidates.append((ordinal, canonical))
    result.require(
        len(candidates) == 1,
        "0041 must contain one exact runtime-role preflight DO block",
    )
    if len(candidates) != 1:
        return
    ordinal, canonical = candidates[0]
    expected_digest = contract["runtime_role_preflight_contract"].get(
        "preflight_do_canonical_sha256"
    )
    result.require(
        _sha256(canonical.encode()) == expected_digest,
        "0041 runtime-role preflight DO canonical SHA-256 differs",
    )
    folded = canonical.lower()
    result.require(
        all(token in folded for token in ROLE_PREFLIGHT_TOKENS),
        "0041 runtime-role preflight omits an attribute, membership, or ownership fence",
    )
    result.require(
        ordinal == 1
        and bool(statements)
        and type(statements[0].stmt).__name__ == "TransactionStmt",
        "0041 runtime-role preflight must immediately follow the outer BEGIN",
    )


def _function_acl_inventory(
    statements: tuple[Any, ...],
) -> tuple[dict[str, str], dict[str, set[str]], set[str]]:
    owners: dict[str, str] = {}
    grants: dict[str, set[str]] = {}
    public_revokes: set[str] = set()
    for raw_statement in statements:
        statement = raw_statement.stmt
        if (
            type(statement).__name__ == "AlterOwnerStmt"
            and statement.objectType == ObjectType.OBJECT_FUNCTION
        ):
            owners[_object_identity(statement.object)] = _role_name(statement.newowner)
        if (
            type(statement).__name__ != "GrantStmt"
            or statement.objtype != ObjectType.OBJECT_FUNCTION
        ):
            continue
        privileges = {
            privilege.priv_name for privilege in statement.privileges or ()
        }
        if privileges and "execute" not in privileges:
            continue
        grantees = {_role_name(grantee) for grantee in statement.grantees or ()}
        for value in statement.objects or ():
            identity = _object_identity(value)
            if statement.is_grant:
                grants.setdefault(identity, set()).update(grantees)
            else:
                grants.setdefault(identity, set()).difference_update(grantees)
                if "PUBLIC" in grantees:
                    public_revokes.add(identity)
    return owners, grants, public_revokes


def _table_acl_inventory(
    statements: tuple[Any, ...],
) -> tuple[dict[str, dict[str, set[str]]], dict[str, dict[str, set[str]]]]:
    grants: dict[str, dict[str, set[str]]] = {}
    revokes: dict[str, dict[str, set[str]]] = {}
    for raw_statement in statements:
        statement = raw_statement.stmt
        if type(statement).__name__ != "GrantStmt" or statement.objtype != ObjectType.OBJECT_TABLE:
            continue
        privileges = {
            (
                f"{privilege.priv_name}(columns)"
                if privilege.cols
                else privilege.priv_name
            )
            for privilege in statement.privileges or ()
        } or TABLE_DML_PRIVILEGES | {"select"}
        for relation in statement.objects or ():
            name = f"{relation.schemaname}.{relation.relname}"
            for grantee in statement.grantees or ():
                role = _role_name(grantee)
                effective = grants.setdefault(name, {}).setdefault(role, set())
                if statement.is_grant:
                    effective.update(privileges)
                    continue
                effective.difference_update(privileges)
                revokes.setdefault(name, {}).setdefault(role, set()).update(
                    privileges
                )
    return grants, revokes


def validate_r6e_security_inventory(
    root: Path,
    migration: Path,
    contract: dict[str, Any],
    result: Validation,
) -> None:
    try:
        statements = parse_sql(migration.read_text(encoding="utf-8"))
    except ParseError as error:
        result.error(f"0041 security inventory PostgreSQL parser failed: {error}")
        return
    _role_preflight(statements, contract, result)
    matrix = contract.get("economics_relation_owner_matrix")
    unavailable_rows = contract.get("economics_unavailable_relation_rows")
    unavailable_relations = {
        row.get("relation")
        for row in unavailable_rows or []
        if isinstance(row, dict) and isinstance(row.get("relation"), str)
    }
    if (
        not isinstance(matrix, list)
        or len(matrix) != 21
        or unavailable_relations != _UNAVAILABLE_ECONOMICS_RELATIONS
    ):
        result.error("0041 security inventory lacks the economics owner matrix")
        return
    functions: dict[str, tuple[str, Any]] = {}
    for raw_statement in statements:
        statement = raw_statement.stmt
        if type(statement).__name__ != "CreateFunctionStmt":
            continue
        signature = _routine_signature(_canonical_sql(statement))
        functions[signature] = (_function_identity(statement), statement)
    function_mutations = {
        signature: _function_mutation_inventory(statement, result)
        for signature, (_identity, statement) in functions.items()
    }
    owners, execute_grants, public_revokes = _function_acl_inventory(statements)
    result.require(
        all(owner == "gurine_migrator" for owner in owners.values()),
        "0041 explicitly assigns an application routine to a non-migrator owner",
    )
    result.require(
        all(not (roles & _INERT_WRITER_ROLES) for roles in execute_grants.values()),
        "0041 grants routine EXECUTE to an inert writer role",
    )
    for raw_statement in statements:
        statement = raw_statement.stmt
        if type(statement).__name__ != "GrantStmt" or not statement.is_grant:
            continue
        grantees = {_role_name(grantee) for grantee in statement.grantees or ()}
        result.require(
            not (grantees & _INERT_WRITER_ROLES),
            "0041 grants a privilege to an inert writer role",
        )
    for signature, (identity, statement) in functions.items():
        service_grants = execute_grants.get(identity, set()) - {"gurine_migrator"}
        if not service_grants:
            continue
        canonical = _canonical_sql(statement).lower()
        result.require(
            _is_security_definer(statement)
            and owners.get(identity) == "gurine_migrator"
            and "session_user" in canonical
            and "current_user" in canonical
            and "gurine_migrator" in canonical
            and all(role in canonical for role in service_grants)
            and identity in public_revokes,
            f"0041 runtime entry guard or migrator ownership differs: {signature}",
        )
    generic_assertion = (
        "ops.consume_assertion_jti(pg_catalog.text,pg_catalog.uuid,"
        "pg_catalog.text,pg_catalog.text,pg_catalog.timestamptz,pg_catalog.bpchar)"
    )
    result.require(
        "gurine_billing_gateway" not in execute_grants.get(generic_assertion, set()),
        "0041 billing-gateway directly executes the unguarded generic assertion helper",
    )
    _funding_disclosure_lifecycle_guard(
        contract,
        functions,
        owners,
        execute_grants,
        public_revokes,
        result,
    )
    postcondition = functions.get(
        "ops.assert_r6e_runtime_role_postconditions_v1() RETURNS boolean"
    )
    result.require(
        postcondition is not None,
        "0041 runtime-role postcondition oracle is missing",
    )
    if postcondition is not None:
        identity, statement = postcondition
        canonical = _canonical_sql(statement).lower()
        result.require(
            not _is_security_definer(statement)
            and owners.get(identity) == "gurine_migrator"
            and execute_grants.get(identity, set()) == set()
            and identity in public_revokes
            and _search_path(statement) == ("pg_catalog", "pg_temp")
            and all(
                token in canonical
                for token in (
                    "pg_auth_members",
                    "pg_db_role_setting",
                    "pg_shdepend",
                    "gurine_economics_writer",
                    "gurine_payment_writer",
                )
            ),
            "0041 runtime-role postcondition oracle differs",
        )
    relations = {
        row["relation"]
        for row in matrix
        if isinstance(row, dict) and isinstance(row.get("relation"), str)
    }
    ownership = contract.get("economics_relation_ownership_exactly_24", {})
    all_economics_relations = {
        relation
        for key in (
            "signed_economics_import_owner",
            "product_runtime_owner",
            "funding_governance_owner",
        )
        for relation in ownership.get(key, [])
        if isinstance(relation, str)
    }
    result.require(
        len(relations) == 21
        and relations | unavailable_relations == all_economics_relations
        and not (relations & unavailable_relations)
        and len(all_economics_relations) == 24,
        "0041 economics active and unavailable relation inventory differs",
    )
    declared_by_function: dict[str, set[str]] = {}
    for row in matrix:
        if (
            isinstance(row, dict)
            and isinstance(row.get("owner_routine_signature"), str)
            and isinstance(row.get("relation"), str)
        ):
            declared_by_function.setdefault(row["owner_routine_signature"], set()).add(
                row["relation"]
            )
    delegation = contract.get("funding_snapshot_outer_producer_delegation", {})
    candidate_signature = None
    producers = delegation.get("outer_producers_in_order", [])
    if isinstance(producers, list) and len(producers) == 2 and isinstance(producers[1], dict):
        candidate_signature = producers[1].get("entry_routine_signature")
    checked = set(declared_by_function)
    if isinstance(candidate_signature, str):
        checked.add(candidate_signature)
    mutation_inventory: dict[str, set[str]] = {}
    for signature in checked:
        function = functions.get(signature)
        result.require(function is not None, f"0041 SQL owner routine is missing: {signature}")
        if function is None:
            continue
        identity, statement = function
        path = _search_path(statement)
        expected_roles = {
            role
            for row in matrix
            if isinstance(row, dict) and row.get("owner_routine_signature") == signature
            for role in row.get("execute_roles", [])
        }
        if signature == candidate_signature:
            expected_roles = {"gurine_public_projector"}
        result.require(
            _is_security_definer(statement)
            and path[:1] == ("pg_catalog",)
            and path[-1:] == ("pg_temp",)
            and len(path) == len(set(path))
            and set(path) <= SAFE_SEARCH_PATH,
            f"0041 owner routine SECURITY DEFINER search_path differs: {signature}",
        )
        result.require(
            owners.get(identity) == "gurine_migrator",
            f"0041 owner routine role differs: {signature}",
        )
        result.require(
            execute_grants.get(identity, set()) == expected_roles
            and identity in public_revokes,
            f"0041 owner routine EXECUTE ACL differs: {signature}",
        )
        mutation_inventory[signature] = set(function_mutations[signature]) & relations
    legacy_names = set(
        ownership.get("legacy_side_door_revoke_exactly", [])
    )
    for signature, (identity, _statement) in functions.items():
        if signature in mutation_inventory:
            continue
        mutations = set(function_mutations[signature]) & all_economics_relations
        if mutations and signature.split("(", 1)[0] in legacy_names:
            result.require(
                owners.get(identity) == "gurine_migrator"
                and execute_grants.get(identity, set()) == set()
                and identity in public_revokes
                and not (mutations & unavailable_relations),
                f"0041 legacy economics mutator is not inert: {signature}",
            )
            continue
        result.require(
            not mutations,
            f"0041 unregistered routine has direct economics DML: {signature}",
        )
    for signature, expected in declared_by_function.items():
        result.require(
            mutation_inventory.get(signature) == expected,
            f"0041 owner routine relation DML differs: {signature}",
        )
    if isinstance(candidate_signature, str):
        direct_signature = delegation.get("direct_owner_routine_signature")
        candidate_function = functions.get(candidate_signature)
        result.require(
            mutation_inventory.get(candidate_signature) == set(),
            "0041 donation candidate routine performs forbidden direct economics DML",
        )
        result.require(
            isinstance(direct_signature, str)
            and candidate_function is not None
            and direct_signature.split("(", 1)[0]
            in _canonical_sql(candidate_function[1]),
            "0041 donation candidate routine does not call the declared direct owner",
        )

    global_contract = load_yaml(root / "specs/database/addendum/global.yaml")
    base_roles = global_contract.get("privilege_closure", {}).get("required_roles", [])
    additive_roles = contract.get("additive_role_registry", {}).get("roles_in_order", [])
    runtime_roles = set(base_roles) | {
        row.get("role") for row in additive_roles if isinstance(row, dict)
    }
    denied_roles = runtime_roles | {"PUBLIC"}
    table_grants, table_revokes = _table_acl_inventory(statements)
    validate_new_ledger_security_inventory(
        contract,
        functions,
        owners,
        execute_grants,
        public_revokes,
        table_grants,
        table_revokes,
        runtime_roles,
        result,
    )
    for relation in all_economics_relations:
        for role in denied_roles:
            result.require(
                not _runtime_dml(
                    table_grants.get(relation, {}).get(role, set())
                ),
                f"{relation}: direct runtime DML is granted to {role}",
            )
    result.stats["r6e_owner_boundary_functions"] = len(checked)
    result.stats["r6e_owner_boundary_relations"] = len(relations)
    result.stats["r6e_unavailable_economics_relations"] = len(
        unavailable_relations
    )
