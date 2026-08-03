from __future__ import annotations

import sys
import unittest
from pathlib import Path

from pglast import parse_sql


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from validation.database_r6e_security_inventory import (
    _funding_disclosure_lifecycle_guard,
    _function_acl_inventory,
    _role_preflight,
    _table_acl_inventory,
)
from validation.database_event_inventory import (
    _canonical_sql,
    _routine_signature,
    _sha256,
)
from validation.database_r6e_security_support import (
    _function_identity,
    _function_mutation_inventory,
    _function_mutations,
    _is_security_definer,
    _runtime_dml,
    _search_path,
)
from validation.design_database import _validate_billing_key_fixture_reference
from validation.models import Validation


OWNER_FUNCTION = """
CREATE FUNCTION ops.fixture_owner_v1(p_input ops.fixture_input_v1)
RETURNS ops.fixture_receipt_v1
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
BEGIN
  INSERT INTO ops.fixture_facts(id) VALUES (gen_random_uuid());
  RETURN NULL;
END
$$;
ALTER FUNCTION ops.fixture_owner_v1(ops.fixture_input_v1)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.fixture_owner_v1(ops.fixture_input_v1) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.fixture_owner_v1(ops.fixture_input_v1)
  TO gurine_economics_importer;
"""


FUNDING_LIFECYCLE_DISPATCHER = """
CREATE FUNCTION ops.execute_action_approval_v1(
  p_operation text,
  p_request jsonb,
  p_actor uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF p_operation IN (
    'createActionProposal',
    'updateActionDraft',
    'previewActionDraft',
    'submitActionForReview',
    'claimActionReview',
    'submitActionDecision'
  ) THEN
    PERFORM 1
      FROM ops.action_proposals AS proposal
      FOR SHARE OF proposal;
  END IF;
  IF FALSE THEN
    RAISE EXCEPTION 'FUNDING_DISCLOSURE_AUTHORITY_UNAVAILABLE';
  END IF;
  RETURN ops.execute_action_approval_v1_legacy_0030(
    p_operation,
    p_request,
    p_actor
  );
END
$$;
ALTER FUNCTION ops.execute_action_approval_v1(text,jsonb,uuid)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.execute_action_approval_v1(text,jsonb,uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.execute_action_approval_v1(text,jsonb,uuid)
  TO gurine_control_api;
"""


class R6eSecurityInventoryTests(unittest.TestCase):
    @staticmethod
    def _funding_lifecycle_guard_fixture() -> tuple[
        dict[str, object],
        dict[str, tuple[str, object]],
        dict[str, str],
        dict[str, set[str]],
        set[str],
    ]:
        statements = parse_sql(FUNDING_LIFECYCLE_DISPATCHER)
        function = statements[0].stmt
        canonical = _canonical_sql(function)
        signature = _routine_signature(canonical)
        identity = _function_identity(function)
        owners, grants, public_revokes = _function_acl_inventory(statements)
        contract = {
            "funding_disclosure_publisher_gate": {
                "lifecycle_gate": {
                    "source_freeze_status": "FINAL",
                    "dispatcher_source_signature": signature,
                    "dispatcher_canonical_ddl_sha256": _sha256(
                        canonical.encode()
                    ),
                    "supported_operations_exactly": [
                        "createActionProposal",
                        "updateActionDraft",
                        "previewActionDraft",
                        "submitActionForReview",
                        "claimActionReview",
                        "submitActionDecision",
                    ],
                    "error_sqlstate": "55000",
                    "error_code": (
                        "FUNDING_DISCLOSURE_AUTHORITY_UNAVAILABLE"
                    ),
                }
            }
        }
        return (
            contract,
            {signature: (identity, function)},
            owners,
            grants,
            public_revokes,
        )

    def test_funding_lifecycle_guard_rejects_missing_dispatcher(self) -> None:
        contract, _functions, owners, grants, public_revokes = (
            self._funding_lifecycle_guard_fixture()
        )
        result = Validation()

        _funding_disclosure_lifecycle_guard(
            contract,
            {},
            owners,
            grants,
            public_revokes,
            result,
        )

        self.assertIn(
            "0041 funding-disclosure lifecycle dispatcher is missing",
            result.errors,
        )

    def test_funding_lifecycle_guard_rejects_digest_drift(self) -> None:
        contract, functions, owners, grants, public_revokes = (
            self._funding_lifecycle_guard_fixture()
        )
        gate = contract["funding_disclosure_publisher_gate"]
        assert isinstance(gate, dict)
        lifecycle = gate["lifecycle_gate"]
        assert isinstance(lifecycle, dict)
        lifecycle["dispatcher_canonical_ddl_sha256"] = "0" * 64
        result = Validation()

        _funding_disclosure_lifecycle_guard(
            contract,
            functions,
            owners,
            grants,
            public_revokes,
            result,
        )

        self.assertIn(
            "0041 funding-disclosure lifecycle dispatcher digest differs",
            result.errors,
        )

    @staticmethod
    def _payment_binding_rows(version: str) -> dict[str, dict[str, object]]:
        expression = (
            "environment = 'TEST' AND billing_key_secret_reference ~ "
            "'^fixture://billing-key/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
            f"[89ab][0-9a-f]{{3}}-[0-9a-f]{{12}}@{version}$'"
        )
        return {
            "ops.payment_method_bindings": {
                "checks": [{"name": "fixture_reference_ck", "expression": expression}]
            }
        }

    def test_billing_key_fixture_reference_requires_exact_v2_form(self) -> None:
        result = Validation()

        _validate_billing_key_fixture_reference(
            self._payment_binding_rows("v2"),
            result,
        )

        self.assertEqual(result.errors, [])

    def test_billing_key_fixture_reference_rejects_v1(self) -> None:
        result = Validation()

        _validate_billing_key_fixture_reference(
            self._payment_binding_rows("v1"),
            result,
        )

        self.assertIn(
            "0041 billing-key fixture reference is not the exact @v2 canonical form",
            result.errors,
        )

    def test_runtime_role_preflight_must_immediately_follow_begin(self) -> None:
        sql = """
BEGIN;
CREATE TYPE ops.too_early_v1 AS ENUM ('VALUE');
DO $$ BEGIN
  PERFORM 'gurine_economics_writer';
  PERFORM 'gurine_payment_writer';
  PERFORM 'gurine_billing_gateway';
  PERFORM 'gurine_economics_importer';
END $$;
COMMIT;
"""
        statements = parse_sql(sql)
        preflight = statements[2].stmt
        contract = {
            "runtime_role_preflight_contract": {
                "roles": [
                    {"role": "gurine_economics_writer"},
                    {"role": "gurine_payment_writer"},
                    {"role": "gurine_billing_gateway"},
                    {"role": "gurine_economics_importer"},
                ],
                "preflight_do_canonical_sha256": _sha256(
                    _canonical_sql(preflight).encode()
                ),
            }
        }
        result = Validation()

        _role_preflight(statements, contract, result)

        self.assertIn(
            "0041 runtime-role preflight must immediately follow the outer BEGIN",
            result.errors,
        )

    def test_function_boundary_inventory_is_exact(self) -> None:
        statements = parse_sql(OWNER_FUNCTION)
        function = statements[0].stmt
        result = Validation()

        mutations = _function_mutations(function, result)
        owners, grants, public_revokes = _function_acl_inventory(statements)
        identity = _function_identity(function)

        self.assertEqual(result.errors, [])
        self.assertTrue(_is_security_definer(function))
        self.assertEqual(
            _search_path(function),
            ("pg_catalog", "ops", "extensions", "pg_temp"),
        )
        self.assertEqual(mutations, {"ops.fixture_facts"})
        self.assertEqual(owners[identity], "gurine_migrator")
        self.assertEqual(grants[identity], {"gurine_economics_importer"})
        self.assertIn(identity, public_revokes)

    def test_function_acl_identity_ignores_outputs_typmods_and_aliases(self) -> None:
        statements = parse_sql(
            """
CREATE FUNCTION ops.fixture_reader_v1(
  p_label character varying(64),
  p_type regtype
)
RETURNS TABLE(result text, amount numeric(24,6))
LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$ SELECT p_label::text, 1::numeric $$;
ALTER FUNCTION ops.fixture_reader_v1(varchar,regtype)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.fixture_reader_v1(
  character varying,pg_catalog.regtype
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.fixture_reader_v1(
  pg_catalog.varchar,regtype
)
  TO gurine_economics_importer;
"""
        )
        function = statements[0].stmt

        owners, grants, public_revokes = _function_acl_inventory(statements)
        identity = _function_identity(function)

        self.assertEqual(
            identity,
            "ops.fixture_reader_v1(pg_catalog.varchar,pg_catalog.regtype)",
        )
        self.assertEqual(owners[identity], "gurine_migrator")
        self.assertEqual(grants[identity], {"gurine_economics_importer"})
        self.assertIn(identity, public_revokes)

    def test_dynamic_sql_in_owner_routine_is_rejected(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.dynamic_owner_v1(p_relation text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$ BEGIN EXECUTE 'INSERT INTO ' || p_relation || ' DEFAULT VALUES'; END $$;
"""
        )[0].stmt
        result = Validation()

        _function_mutations(statement, result)

        self.assertTrue(
            any("forbidden dynamic SQL" in error for error in result.errors),
            result.errors,
        )

    def test_invalid_plpgsql_body_reports_an_empty_inventory(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.invalid_owner_v1() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$ BEGIN THIS IS NOT SQL; END $$;
"""
        )[0].stmt
        result = Validation()

        mutations = _function_mutation_inventory(statement, result)

        self.assertEqual(mutations, {})
        self.assertTrue(
            any("PL/pgSQL parser failed" in error for error in result.errors),
            result.errors,
        )

    def test_data_modifying_cte_is_included_in_owner_mutations(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.cte_owner_v1() RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE v_count bigint;
BEGIN
  WITH inserted AS (
    INSERT INTO ops.fixture_facts(id) VALUES (gen_random_uuid()) RETURNING id
  )
  SELECT count(*) INTO v_count FROM inserted;
  RETURN v_count;
END
$$;
"""
        )[0].stmt
        result = Validation()

        mutations = _function_mutations(statement, result)

        self.assertEqual(result.errors, [])
        self.assertEqual(mutations, {"ops.fixture_facts"})

    def test_return_query_dml_is_included_in_owner_mutations(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.return_query_owner_v1() RETURNS SETOF uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  RETURN QUERY
  INSERT INTO ops.fixture_facts(id)
  VALUES (gen_random_uuid())
  RETURNING id;
END
$$;
"""
        )[0].stmt
        result = Validation()

        mutations = _function_mutation_inventory(statement, result)

        self.assertEqual(result.errors, [])
        self.assertEqual(mutations, {"ops.fixture_facts": {"insert"}})

    def test_return_query_execute_is_rejected_as_dynamic_sql(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.dynamic_return_owner_v1(p_query text) RETURNS SETOF uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$ BEGIN RETURN QUERY EXECUTE p_query; END $$;
"""
        )[0].stmt
        result = Validation()

        _function_mutation_inventory(statement, result)

        self.assertTrue(
            any("forbidden dynamic SQL" in error for error in result.errors),
            result.errors,
        )

    def test_owner_mutation_inventory_preserves_operation_kinds(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.mixed_owner_v1() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  INSERT INTO ops.fixture_facts(id) VALUES (gen_random_uuid());
  UPDATE ops.fixture_facts SET id=id WHERE false;
END
$$;
"""
        )[0].stmt
        result = Validation()

        mutations = _function_mutation_inventory(statement, result)

        self.assertEqual(result.errors, [])
        self.assertEqual(
            mutations,
            {"ops.fixture_facts": {"insert", "update"}},
        )

    def test_sql_language_owner_mutation_is_not_hidden(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.sql_owner_v1() RETURNS uuid
LANGUAGE sql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$ INSERT INTO ops.fixture_facts(id) VALUES (gen_random_uuid()) RETURNING id $$;
"""
        )[0].stmt
        result = Validation()

        mutations = _function_mutation_inventory(statement, result)

        self.assertEqual(result.errors, [])
        self.assertEqual(mutations, {"ops.fixture_facts": {"insert"}})

    def test_unqualified_owner_mutation_is_rejected(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.unqualified_owner_v1() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$ BEGIN INSERT INTO fixture_facts(id) VALUES (gen_random_uuid()); END $$;
"""
        )[0].stmt
        result = Validation()

        _function_mutations(statement, result)

        self.assertTrue(
            any("schema-qualified" in error for error in result.errors),
            result.errors,
        )

    def test_table_acl_tracks_grants_and_explicit_revokes(self) -> None:
        statements = parse_sql(
            """
GRANT SELECT,INSERT ON ops.fixture_facts TO fixture_acl_role;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER
  ON ops.fixture_facts FROM PUBLIC,gurine_economics_importer;
"""
        )

        grants, revokes = _table_acl_inventory(statements)

        self.assertEqual(
            grants["ops.fixture_facts"]["fixture_acl_role"],
            {"select", "insert"},
        )
        self.assertEqual(
            revokes["ops.fixture_facts"]["PUBLIC"],
            {"insert", "update", "delete", "truncate", "references", "trigger"},
        )
        self.assertEqual(
            revokes["ops.fixture_facts"]["gurine_economics_importer"],
            {"insert", "update", "delete", "truncate", "references", "trigger"},
        )

    def test_column_acl_cannot_satisfy_exact_table_privilege(self) -> None:
        statements = parse_sql(
            """
GRANT SELECT(id),INSERT(id) ON ops.fixture_facts TO fixture_acl_role;
REVOKE INSERT(id),UPDATE(id),DELETE
  ON ops.fixture_facts FROM gurine_economics_importer;
"""
        )

        grants, revokes = _table_acl_inventory(statements)

        self.assertEqual(
            grants["ops.fixture_facts"]["fixture_acl_role"],
            {"select(columns)", "insert(columns)"},
        )
        self.assertEqual(
            _runtime_dml(
                grants["ops.fixture_facts"]["fixture_acl_role"]
            ),
            {"insert"},
        )
        self.assertEqual(
            revokes["ops.fixture_facts"]["gurine_economics_importer"],
            {"insert(columns)", "update(columns)", "delete"},
        )

    def test_table_acl_inventory_applies_revoke_after_grant(self) -> None:
        statements = parse_sql(
            """
GRANT SELECT,INSERT ON ops.fixture_facts TO fixture_acl_role;
REVOKE INSERT ON ops.fixture_facts FROM fixture_acl_role;
"""
        )

        grants, revokes = _table_acl_inventory(statements)

        self.assertEqual(
            grants["ops.fixture_facts"]["fixture_acl_role"],
            {"select"},
        )
        self.assertEqual(
            revokes["ops.fixture_facts"]["fixture_acl_role"],
            {"insert"},
        )


if __name__ == "__main__":
    unittest.main()
