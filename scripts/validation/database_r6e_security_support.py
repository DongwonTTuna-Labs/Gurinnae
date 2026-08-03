from __future__ import annotations

from typing import Any

from pglast import parse_plpgsql, parse_sql
from pglast.enums import RoleSpecType
from pglast.parser import ParseError
from pglast.visitors import Visitor

from .database_event_inventory import _canonical_sql, _routine_signature
from .models import Validation


TABLE_DML_PRIVILEGES = {
    "delete",
    "insert",
    "references",
    "trigger",
    "truncate",
    "update",
}
SAFE_SEARCH_PATH = {
    "pg_catalog",
    "raw",
    "core",
    "editorial",
    "intake",
    "ops",
    "extensions",
    "pg_temp",
}
ROLE_PREFLIGHT_TOKENS = {
    "pg_roles",
    "pg_auth_members",
    "pg_shdepend",
    "rolcanlogin",
    "rolinherit",
    "rolsuper",
    "rolcreatedb",
    "rolcreaterole",
    "rolreplication",
    "rolbypassrls",
    "rolconnlimit",
    "42501",
}
CATALOG_BUILTIN_TYPES = frozenset(
    {
        "bit",
        "bool",
        "bpchar",
        "bytea",
        "date",
        "float4",
        "float8",
        "int2",
        "int4",
        "int8",
        "interval",
        "json",
        "jsonb",
        "numeric",
        "regtype",
        "text",
        "time",
        "timestamp",
        "timestamptz",
        "timetz",
        "uuid",
        "varbit",
        "varchar",
    }
)


def _parts(values: Any) -> str:
    return ".".join(
        value.sval for value in values or () if isinstance(value.sval, str)
    )


def _catalog_type_identity(type_name: Any) -> str:
    names = [
        value.sval
        for value in type_name.names or ()
        if isinstance(value.sval, str)
    ]
    if len(names) == 1 and names[0] in CATALOG_BUILTIN_TYPES:
        base = f"pg_catalog.{names[0]}"
    elif (
        len(names) == 2
        and names[0] == "pg_catalog"
        and names[1] in CATALOG_BUILTIN_TYPES
    ):
        base = ".".join(names)
    elif len(names) == 2 and names[0] != "pg_catalog":
        base = ".".join(names)
    else:
        raise ValueError(f"routine argument type is not canonical: {names!r}")
    return base + ("[]" if type_name.arrayBounds else "")


def _function_identity(statement: Any) -> str:
    types = ",".join(
        _catalog_type_identity(parameter.argType)
        for parameter in statement.parameters or ()
        if str(parameter.mode) not in {"o", "t"}
    )
    return f"{_parts(statement.funcname)}({types})"


def _object_identity(value: Any) -> str:
    types = ",".join(
        _catalog_type_identity(argument) for argument in value.objargs or ()
    )
    return f"{_parts(value.objname)}({types})"


def _role_name(value: Any) -> str:
    if value.roletype == RoleSpecType.ROLESPEC_PUBLIC:
        return "PUBLIC"
    return value.rolename or ""


def _runtime_dml(privileges: set[str]) -> set[str]:
    return {
        privilege.split("(", 1)[0]
        for privilege in privileges
        if privilege.split("(", 1)[0] in TABLE_DML_PRIVILEGES
    }


def _search_path(statement: Any) -> tuple[str, ...]:
    paths: list[str] = []
    for option in statement.options or ():
        setting = option.arg if option.defname == "set" else None
        if getattr(setting, "name", None) != "search_path":
            continue
        for argument in setting.args or ():
            value = getattr(getattr(argument, "val", None), "sval", None)
            if isinstance(value, str):
                paths.append(value)
    return tuple(paths)


def _is_security_definer(statement: Any) -> bool:
    return any(
        option.defname == "security"
        and getattr(option.arg, "boolval", None) is True
        for option in statement.options or ()
    )


def _walk_plpgsql(value: object) -> tuple[list[str], bool]:
    queries: list[str] = []
    dynamic = False

    def visit(node: object) -> None:
        nonlocal dynamic
        if isinstance(node, dict):
            expression = node.get("PLpgSQL_expr")
            if isinstance(expression, dict) and expression.get("parseMode") == 0:
                query = expression.get("query")
                if isinstance(query, str):
                    queries.append(query)
            if (
                "PLpgSQL_stmt_dynexecute" in node
                or "PLpgSQL_stmt_dynfors" in node
                or "dynquery" in node
            ):
                dynamic = True
            for child in node.values():
                visit(child)
        elif isinstance(node, list):
            for child in node:
                visit(child)

    visit(value)
    return queries, dynamic


class _MutationCollector(Visitor):
    def __init__(self) -> None:
        super().__init__()
        self.mutations: dict[str, set[str]] = {}

    def _add_relation(self, relation: Any, operation: str) -> None:
        schema = getattr(relation, "schemaname", None)
        name = getattr(relation, "relname", None)
        if not isinstance(schema, str) or not isinstance(name, str):
            raise ValueError("owner routine DML target must be schema-qualified")
        self.mutations.setdefault(f"{schema}.{name}", set()).add(operation)

    def visit_InsertStmt(self, _ancestors: Any, node: Any) -> None:
        self._add_relation(node.relation, "insert")

    def visit_UpdateStmt(self, _ancestors: Any, node: Any) -> None:
        self._add_relation(node.relation, "update")

    def visit_DeleteStmt(self, _ancestors: Any, node: Any) -> None:
        self._add_relation(node.relation, "delete")

    def visit_MergeStmt(self, _ancestors: Any, node: Any) -> None:
        self._add_relation(node.relation, "merge")

    def visit_TruncateStmt(self, _ancestors: Any, node: Any) -> None:
        for relation in node.relations or ():
            self._add_relation(relation, "truncate")


def _query_mutation_inventory(query: str) -> dict[str, set[str]]:
    collector = _MutationCollector()
    collector(parse_sql(query))
    return collector.mutations


def _query_mutations(query: str) -> set[str]:
    return set(_query_mutation_inventory(query))


def _function_language(statement: Any) -> str | None:
    for option in statement.options or ():
        if option.defname == "language":
            value = getattr(option.arg, "sval", None)
            return value.lower() if isinstance(value, str) else None
    return None


def _sql_function_bodies(statement: Any) -> tuple[str, ...]:
    for option in statement.options or ():
        if option.defname != "as":
            continue
        return tuple(
            value.sval
            for value in option.arg or ()
            if isinstance(getattr(value, "sval", None), str)
        )
    return ()


def _function_mutation_inventory(
    statement: Any,
    result: Validation,
) -> dict[str, set[str]]:
    signature = _routine_signature(_canonical_sql(statement))
    if _function_language(statement) == "sql":
        mutations: dict[str, set[str]] = {}
        bodies = _sql_function_bodies(statement)
        result.require(
            len(bodies) == 1,
            f"0041 SQL owner routine body is not exact for {signature}",
        )
        for body in bodies:
            try:
                for relation, operations in _query_mutation_inventory(body).items():
                    mutations.setdefault(relation, set()).update(operations)
            except (ParseError, ValueError) as error:
                result.error(
                    f"0041 SQL owner routine parser failed for {signature}: {error}"
                )
        return mutations
    try:
        block = parse_plpgsql(_canonical_sql(statement))
    except ParseError as error:
        result.error(f"0041 owner routine PL/pgSQL parser failed for {signature}: {error}")
        return {}
    queries, dynamic = _walk_plpgsql(block)
    result.require(
        not dynamic,
        f"0041 owner routine uses forbidden dynamic SQL: {signature}",
    )
    mutations: dict[str, set[str]] = {}
    for query in queries:
        try:
            for relation, operations in _query_mutation_inventory(query).items():
                mutations.setdefault(relation, set()).update(operations)
        except (ParseError, ValueError) as error:
            result.error(
                f"0041 owner routine nested SQL parser failed for {signature}: {error}"
            )
    return mutations


def _function_mutations(statement: Any, result: Validation) -> set[str]:
    return set(_function_mutation_inventory(statement, result))
