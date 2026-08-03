from __future__ import annotations

from typing import Any

from .database_r6e_security_support import (
    SAFE_SEARCH_PATH,
    _function_mutation_inventory,
    _is_security_definer,
    _runtime_dml,
    _search_path,
)
from .models import Validation


_MATRIX_KEYS = {
    "freeze_status",
    "relation_count_exactly",
    "row_keys_exactly",
    "routine_entry_keys_exactly",
    "rows",
    "closure_rule",
}
_ROW_KEYS = [
    "relation",
    "owner_role",
    "owner_access",
    "runtime_direct_table_dml_grants_exactly",
    "owner_routines_in_order",
]
_ROUTINE_KEYS = [
    "signature",
    "execute_roles",
    "logical_producer",
    "operation_id",
    "relation_mutations_exactly",
]
_RELATION_OWNERS = (
    ("ops.cash_application_facts", "gurine_economics_importer"),
    ("ops.tax_invoice_issuance_receipts", "gurine_economics_importer"),
    ("ops.payment_method_bindings", "gurine_billing_gateway"),
    ("ops.payment_charge_attempts", "gurine_billing_gateway"),
    ("ops.provider_webhook_receipts", "gurine_billing_gateway"),
    ("ops.donation_facts", "gurine_billing_gateway"),
)


def validate_new_ledger_security_inventory(
    contract: dict[str, Any],
    functions: dict[str, tuple[str, Any]],
    owners: dict[str, str],
    execute_grants: dict[str, set[str]],
    public_revokes: set[str],
    table_grants: dict[str, dict[str, set[str]]],
    table_revokes: dict[str, dict[str, set[str]]],
    runtime_roles: set[str],
    result: Validation,
) -> None:
    function_mutations = {
        signature: _function_mutation_inventory(statement, result)
        for signature, (_identity, statement) in functions.items()
    }
    matrix = contract.get("new_ledger_relation_owner_matrix")
    valid_matrix = (
        isinstance(matrix, dict)
        and set(matrix) == _MATRIX_KEYS
        and matrix.get("freeze_status") == "FINAL"
        and matrix.get("relation_count_exactly") == len(_RELATION_OWNERS)
        and matrix.get("row_keys_exactly") == _ROW_KEYS
        and matrix.get("routine_entry_keys_exactly") == _ROUTINE_KEYS
        and isinstance(matrix.get("closure_rule"), str)
        and bool(matrix.get("closure_rule"))
    )
    result.require(
        valid_matrix,
        "0041 new-ledger owner matrix is not FINAL and closed",
    )
    if not isinstance(matrix, dict):
        return
    rows = matrix.get("rows")
    valid_rows = isinstance(rows, list) and len(rows) == len(_RELATION_OWNERS)
    result.require(
        valid_rows,
        "0041 new-ledger owner matrix must contain exactly six rows",
    )
    if not valid_rows or not isinstance(rows, list):
        return

    ledger_relations = {relation for relation, _service in _RELATION_OWNERS}
    expected_mutations: dict[str, dict[str, set[str]]] = {}
    routine_contracts: dict[str, tuple[str, tuple[str, ...], str, str]] = {}
    declared_signatures: set[str] = set()
    for ordinal, (row, expected) in enumerate(
        zip(rows, _RELATION_OWNERS, strict=True),
        start=1,
    ):
        relation, service_role = expected
        owner_role = "gurine_migrator"
        valid_row = (
            isinstance(row, dict)
            and list(row) == _ROW_KEYS
            and row.get("relation") == relation
            and row.get("owner_role") == owner_role
            and row.get("owner_access") == "OWNER_IMPLIED"
            and row.get("runtime_direct_table_dml_grants_exactly") == []
            and isinstance(row.get("owner_routines_in_order"), list)
            and bool(row.get("owner_routines_in_order"))
        )
        result.require(
            valid_row,
            f"0041 new-ledger owner matrix row {ordinal} differs",
        )
        if not valid_row or not isinstance(row, dict):
            continue
        for routine_ordinal, routine in enumerate(
            row["owner_routines_in_order"],
            start=1,
        ):
            execute_roles = routine.get("execute_roles") if isinstance(routine, dict) else None
            valid_routine = (
                isinstance(routine, dict)
                and list(routine) == _ROUTINE_KEYS
                and isinstance(routine.get("signature"), str)
                and bool(routine.get("signature"))
                and isinstance(execute_roles, list)
                and len(execute_roles) == len(set(execute_roles))
                and execute_roles in ([], [service_role])
                and isinstance(routine.get("logical_producer"), str)
                and bool(routine.get("logical_producer"))
                and isinstance(routine.get("operation_id"), str)
                and bool(routine.get("operation_id"))
                and routine.get("relation_mutations_exactly") == ["INSERT"]
            )
            result.require(
                valid_routine,
                f"0041 {relation} owner routine {routine_ordinal} differs",
            )
            if not valid_routine or not isinstance(routine, dict):
                continue
            signature = routine["signature"]
            contract_identity = (
                owner_role,
                tuple(execute_roles),
                routine["logical_producer"],
                routine["operation_id"],
            )
            previous = routine_contracts.setdefault(signature, contract_identity)
            result.require(
                previous == contract_identity,
                f"0041 new-ledger routine contract is inconsistent: {signature}",
            )
            declared_signatures.add(signature)
            expected_mutations.setdefault(signature, {})[relation] = {"insert"}

    for signature, expected in expected_mutations.items():
        function = functions.get(signature)
        result.require(
            function is not None,
            f"0041 new-ledger SQL owner routine is missing: {signature}",
        )
        if function is None:
            continue
        identity, statement = function
        owner_role, execute_roles, _producer, _operation = routine_contracts[signature]
        path = _search_path(statement)
        result.require(
            _is_security_definer(statement)
            and path[:1] == ("pg_catalog",)
            and path[-1:] == ("pg_temp",)
            and len(path) == len(set(path))
            and set(path) <= SAFE_SEARCH_PATH,
            f"0041 new-ledger owner routine search_path differs: {signature}",
        )
        result.require(
            owners.get(identity) == owner_role,
            f"0041 new-ledger owner routine role differs: {signature}",
        )
        result.require(
            execute_grants.get(identity, set()) == set(execute_roles)
            and identity in public_revokes,
            f"0041 new-ledger owner routine EXECUTE ACL differs: {signature}",
        )
        actual = {
            relation: operations
            for relation, operations in function_mutations[signature].items()
            if relation in ledger_relations
        }
        result.require(
            actual == expected,
            f"0041 new-ledger owner routine DML differs: {signature}",
        )

    for signature in functions:
        if signature in declared_signatures:
            continue
        actual = set(function_mutations[signature]) & ledger_relations
        result.require(
            not actual,
            f"0041 undeclared routine mutates a new ledger relation: {signature}",
        )

    for relation, _service_role in _RELATION_OWNERS:
        denied_roles = runtime_roles | {"PUBLIC"}
        for role in denied_roles:
            result.require(
                not _runtime_dml(table_grants.get(relation, {}).get(role, set())),
                f"{relation}: direct new-ledger DML is granted to {role}",
            )
    result.stats["r6e_new_ledger_owner_relations"] = len(_RELATION_OWNERS)
    result.stats["r6e_new_ledger_owner_routines"] = len(declared_signatures)
