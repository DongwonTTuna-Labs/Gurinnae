from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import sys
import unittest

from pglast import parse_sql


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from validation.database_event_inventory import _canonical_sql, _routine_signature
from validation.database_r6e_ledger_security import (
    validate_new_ledger_security_inventory,
)
from validation.database_r6e_security_inventory import (
    _function_acl_inventory,
    _table_acl_inventory,
)
from validation.database_r6e_security_support import _function_identity
from validation.models import Validation


RELATIONS = (
    ("ops.cash_application_facts", "gurine_economics_importer"),
    ("ops.tax_invoice_issuance_receipts", "gurine_economics_importer"),
    ("ops.payment_method_bindings", "gurine_billing_gateway"),
    ("ops.payment_charge_attempts", "gurine_billing_gateway"),
    ("ops.provider_webhook_receipts", "gurine_billing_gateway"),
    ("ops.donation_facts", "gurine_billing_gateway"),
)
RUNTIME_ROLES = {
    "gurine_economics_writer",
    "gurine_payment_writer",
    "gurine_economics_importer",
    "gurine_billing_gateway",
    "gurine_workflow_worker",
}


def routine_name(relation: str) -> str:
    return f"ops.owner_{relation.split('.', 1)[1]}_v1"


def valid_contract() -> dict[str, object]:
    rows = []
    for relation, service in RELATIONS:
        name = routine_name(relation)
        rows.append(
            {
                "relation": relation,
                "owner_role": "gurine_migrator",
                "owner_access": "OWNER_IMPLIED",
                "runtime_direct_table_dml_grants_exactly": [],
                "owner_routines_in_order": [
                    {
                        "signature": f"{name}() RETURNS void",
                        "execute_roles": [service],
                        "logical_producer": f"fixture.{name}",
                        "operation_id": f"fixture.{name}",
                        "relation_mutations_exactly": ["INSERT"],
                    }
                ],
            }
        )
    return {
        "new_ledger_relation_owner_matrix": {
            "freeze_status": "FINAL",
            "relation_count_exactly": 6,
            "row_keys_exactly": [
                "relation",
                "owner_role",
                "owner_access",
                "runtime_direct_table_dml_grants_exactly",
                "owner_routines_in_order",
            ],
            "routine_entry_keys_exactly": [
                "signature",
                "execute_roles",
                "logical_producer",
                "operation_id",
                "relation_mutations_exactly",
            ],
            "rows": rows,
            "closure_rule": "fixture exact closure",
        }
    }


def fixture_sql(*, update_relation: str | None = None) -> str:
    statements = []
    for relation, service in RELATIONS:
        name = routine_name(relation)
        mutation = (
            f"UPDATE {relation} SET id=id WHERE false;"
            if relation == update_relation
            else f"INSERT INTO {relation}(id) VALUES (gen_random_uuid());"
        )
        denied = sorted(RUNTIME_ROLES | {"PUBLIC"})
        statements.append(
            f"""
CREATE FUNCTION {name}() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$ BEGIN {mutation} END $$;
ALTER FUNCTION {name}() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION {name}() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION {name}() TO {service};
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER
  ON {relation} FROM {','.join(denied)};
"""
        )
    return "\n".join(statements)


def inventories(sql: str) -> tuple[
    dict[str, tuple[str, object]],
    dict[str, str],
    dict[str, set[str]],
    set[str],
    dict[str, dict[str, set[str]]],
    dict[str, dict[str, set[str]]],
]:
    statements = parse_sql(sql)
    functions = {}
    for raw_statement in statements:
        statement = raw_statement.stmt
        if type(statement).__name__ != "CreateFunctionStmt":
            continue
        signature = _routine_signature(_canonical_sql(statement))
        functions[signature] = (_function_identity(statement), statement)
    owners, execute_grants, public_revokes = _function_acl_inventory(statements)
    table_grants, table_revokes = _table_acl_inventory(statements)
    return (
        functions,
        owners,
        execute_grants,
        public_revokes,
        table_grants,
        table_revokes,
    )


def validate(
    contract: dict[str, object],
    sql: str,
) -> Validation:
    result = Validation()
    validate_new_ledger_security_inventory(
        contract,
        *inventories(sql),
        RUNTIME_ROLES,
        result,
    )
    return result


class NewLedgerSecurityInventoryTests(unittest.TestCase):
    def test_final_six_relation_matrix_matches_sql(self) -> None:
        result = validate(valid_contract(), fixture_sql())

        self.assertEqual(result.errors, [])
        self.assertEqual(result.stats["r6e_new_ledger_owner_relations"], 6)
        self.assertEqual(result.stats["r6e_new_ledger_owner_routines"], 6)

    def test_pending_matrix_is_rejected(self) -> None:
        contract = deepcopy(valid_contract())
        matrix = contract["new_ledger_relation_owner_matrix"]
        assert isinstance(matrix, dict)
        matrix["freeze_status"] = "PENDING_FINAL_SQL"

        result = validate(contract, fixture_sql())

        self.assertIn(
            "0041 new-ledger owner matrix is not FINAL and closed",
            result.errors,
        )

    def test_update_in_insert_only_owner_is_rejected(self) -> None:
        result = validate(
            valid_contract(),
            fixture_sql(update_relation="ops.donation_facts"),
        )

        self.assertTrue(
            any("new-ledger owner routine DML differs" in error for error in result.errors),
            result.errors,
        )

    def test_undeclared_new_ledger_mutator_is_rejected(self) -> None:
        sql = fixture_sql() + """
CREATE FUNCTION ops.hidden_ledger_writer_v1() RETURNS void
LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$ INSERT INTO ops.donation_facts(id) VALUES (gen_random_uuid()) $$;
"""

        result = validate(valid_contract(), sql)

        self.assertIn(
            "0041 undeclared routine mutates a new ledger relation: "
            "ops.hidden_ledger_writer_v1() RETURNS void",
            result.errors,
        )

    def test_undeclared_dynamic_sql_cannot_hide_a_ledger_mutator(self) -> None:
        sql = fixture_sql() + """
CREATE FUNCTION ops.hidden_dynamic_writer_v1(p_relation text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$ BEGIN
  EXECUTE 'INSERT INTO ops.' || p_relation || '(id) VALUES (gen_random_uuid())';
END $$;
"""

        result = validate(valid_contract(), sql)

        self.assertTrue(
            any("forbidden dynamic SQL" in error for error in result.errors),
            result.errors,
        )


if __name__ == "__main__":
    unittest.main()
