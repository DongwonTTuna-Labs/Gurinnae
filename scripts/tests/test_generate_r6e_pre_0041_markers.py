from __future__ import annotations

from pathlib import Path
import sys
import unittest

from pglast import parse_sql


SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from generate_r6e_pre_0041_markers import (
    _standalone_type_identity,
    render_markers,
    routine_catalog_identity,
    validate_markers,
)


def event_contract() -> dict[str, object]:
    return {
        "category": "DOMAIN",
        "schemaVersion": 1,
        "active": True,
        "payloadSchemaUri": "payloads/example_v1.schema.json",
        "payloadSchema": {
            "type": "object",
            "additionalProperties": False,
        },
    }


def markers() -> list[tuple[str, str, dict[str, object] | None]]:
    return [
        ("RELATION", "ops.example_facts", None),
        ("TYPE", "ops.example_input_v1", None),
        (
            "ROUTINE",
            "ops.example_owner_v1(pg_catalog.uuid,pg_catalog.text,"
            "pg_catalog.bpchar,pg_catalog.int8,pg_catalog.numeric,ops.custom_v1[])",
            None,
        ),
        ("EVENT_SCHEMA", "example.fact_recorded.v1", event_contract()),
    ]


class R6ePre0041MarkerGeneratorTests(unittest.TestCase):
    def test_all_create_type_forms_have_catalog_markers(self) -> None:
        statements = parse_sql(
            """
CREATE TYPE ops.example_enum_v1 AS ENUM ('VALUE');
CREATE TYPE ops.example_composite_v1 AS (value text);
CREATE TYPE ops.example_range_v1 AS RANGE (subtype = integer);
CREATE TYPE ops.example_base_v1;
"""
        )

        identities = [
            _standalone_type_identity(raw_statement.stmt)
            for raw_statement in statements
        ]

        self.assertEqual(
            identities,
            [
                "ops.example_enum_v1",
                "ops.example_composite_v1",
                "ops.example_range_v1",
                "ops.example_base_v1",
            ],
        )

    def test_routine_identity_uses_catalog_types_without_typmods(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.example_owner_v1(
  p_id uuid,
  p_text text,
  p_digest char(64),
  p_count bigint,
  p_amount numeric(24,6),
  p_custom ops.custom_v1[]
) RETURNS void LANGUAGE sql AS $$ SELECT $$;
"""
        )[0].stmt

        identity = routine_catalog_identity(statement)

        self.assertEqual(
            identity,
            "ops.example_owner_v1(pg_catalog.uuid,pg_catalog.text,"
            "pg_catalog.bpchar,pg_catalog.int8,pg_catalog.numeric,ops.custom_v1[])",
        )

    def test_routine_identity_excludes_table_output_columns(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.example_reader_v1(p_id uuid)
RETURNS TABLE(result text, amount numeric(24,6))
LANGUAGE sql AS $$ SELECT 'ok', 1::numeric $$;
"""
        )[0].stmt

        identity = routine_catalog_identity(statement)

        self.assertEqual(identity, "ops.example_reader_v1(pg_catalog.uuid)")

    def test_routine_identity_uses_catalog_aliases_for_varying_types(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.example_alias_v1(
  p_text character varying(64),
  p_bits bit varying(8)
) RETURNS void LANGUAGE sql AS $$ SELECT $$;
"""
        )[0].stmt

        identity = routine_catalog_identity(statement)

        self.assertEqual(
            identity,
            "ops.example_alias_v1(pg_catalog.varchar,pg_catalog.varbit)",
        )

    def test_routine_identity_qualifies_regtype_as_catalog_type(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.example_regtype_v1(p_type regtype)
RETURNS void LANGUAGE sql AS $$ SELECT $$;
"""
        )[0].stmt

        identity = routine_catalog_identity(statement)

        self.assertEqual(
            identity,
            "ops.example_regtype_v1(pg_catalog.regtype)",
        )

    def test_routine_identity_collapses_declared_array_dimensions(self) -> None:
        statement = parse_sql(
            """
CREATE FUNCTION ops.example_array_v1(p_values uuid[][])
RETURNS void LANGUAGE sql AS $$ SELECT $$;
"""
        )[0].stmt

        identity = routine_catalog_identity(statement)

        self.assertEqual(identity, "ops.example_array_v1(pg_catalog.uuid[])")

    def test_render_is_one_data_only_insert(self) -> None:
        rendered = render_markers(markers())
        statements = parse_sql(rendered.decode("utf-8"))

        self.assertEqual(len(statements), 1)
        statement = statements[0].stmt
        self.assertEqual(type(statement).__name__, "InsertStmt")
        self.assertEqual(statement.relation.schemaname, "pg_temp")
        self.assertEqual(statement.relation.relname, "r6e_pre_0041_markers_v1")
        self.assertEqual(len(statement.selectStmt.valuesLists), 4)

    def test_one_added_marker_changes_generated_bytes(self) -> None:
        original = render_markers(markers())
        mutated = markers()
        mutated.insert(1, ("RELATION", "ops.unreviewed_facts", None))

        self.assertNotEqual(render_markers(mutated), original)

    def test_duplicate_marker_is_rejected(self) -> None:
        mutated = markers()
        mutated.insert(1, mutated[0])

        with self.assertRaisesRegex(ValueError, "duplicate R6e marker"):
            validate_markers(mutated)

    def test_noncanonical_builtin_routine_argument_is_rejected(self) -> None:
        mutated = markers()
        mutated[2] = ("ROUTINE", "ops.example_owner_v1(uuid)", None)

        with self.assertRaisesRegex(ValueError, "invalid routine marker"):
            validate_markers(mutated)

    def test_schema_qualified_custom_type_can_share_a_builtin_name(self) -> None:
        mutated = markers()
        mutated[2] = ("ROUTINE", "ops.example_owner_v1(ops.text)", None)

        validate_markers(mutated)


if __name__ == "__main__":
    unittest.main()
