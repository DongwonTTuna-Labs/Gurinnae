from __future__ import annotations

import hashlib
import json
import re
from typing import Any

from pglast import parse_sql
from pglast.stream import RawStream

from .models import Validation


DECISION_EVENT_MARKER_RE = re.compile(
    r'(?im)^[ \t]*DO[ \t]+\$decision_event_registry\$[ \t]*$'
)
EVENT_INSERT_RE = re.compile(r'\bINSERT\s+INTO\s+ops\.event_types\b', re.I)
EVENT_MUTATION_RE = re.compile(
    r'\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM|MERGE\s+INTO|'
    r'TRUNCATE(?:\s+TABLE)?|COPY)\s+ops\.event_types\b', re.I,
)
DO_JSON_TEXT_RE = re.compile(
    r'\b(?P<variable>[a-z_][a-z0-9_]*)\s+text\s*:=\s*'
    r'\$(?P<tag>[a-z_][a-z0-9_]*)\$(?P<payload>.*?)\$(?P=tag)\$\s*;',
    re.I | re.S,
)
DO_JSONB_BINDING_RE = re.compile(
    r'\b(?P<jsonb_variable>[a-z_][a-z0-9_]*)\s*:=\s*'
    r'(?P<text_variable>[a-z_][a-z0-9_]*)::jsonb\s*;',
    re.I,
)
EVENT_COLUMNS = [
    'event_type',
    'category',
    'schema_version',
    'active',
    'payload_schema_uri',
    'payload_schema',
]


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _canonical_sql(statement: Any) -> str:
    return RawStream()(statement)


def _relation_name(relation: Any) -> str:
    schema = getattr(relation, 'schemaname', None)
    name = getattr(relation, 'relname', None)
    return f'{schema}.{name}' if schema else str(name)


def _routine_signature(canonical: str) -> str:
    for prefix in (
        'CREATE OR REPLACE FUNCTION ',
        'CREATE FUNCTION ',
        'CREATE OR REPLACE PROCEDURE ',
        'CREATE PROCEDURE ',
    ):
        if canonical.startswith(prefix):
            signature, separator, _ = canonical[len(prefix):].partition(' LANGUAGE ')
            if separator:
                return signature
    raise ValueError('routine canonical SQL has no function/procedure LANGUAGE boundary')


def _do_body(statement: Any) -> str:
    bodies = [
        getattr(argument.arg, 'sval', None)
        for argument in statement.args or ()
        if getattr(argument, 'defname', None) == 'as'
    ]
    if len(bodies) != 1 or not isinstance(bodies[0], str):
        raise ValueError('DO statement must contain exactly one string body')
    return bodies[0]


def _nested_event_insert(body: str, start: int) -> Any:
    for terminator in re.finditer(';', body[start:]):
        candidate = body[start:start + terminator.end()]
        try:
            parsed = parse_sql(candidate)
        except Exception:
            continue
        if len(parsed) != 1 or type(parsed[0].stmt).__name__ != 'InsertStmt':
            continue
        relation = parsed[0].stmt.relation
        if _relation_name(relation) == 'ops.event_types':
            return parsed[0].stmt
    raise ValueError('marker DO event-registry INSERT could not be parsed')


def _literal_value(node: Any, attribute: str) -> Any:
    return getattr(getattr(node, 'val', None), attribute, None)


def _embedded_jsonb(node: Any) -> dict[str, Any] | None:
    type_name = getattr(node, 'typeName', None)
    names = [
        getattr(name, 'sval', None)
        for name in getattr(type_name, 'names', ()) or ()
    ]
    payload = _literal_value(getattr(node, 'arg', None), 'sval')
    if names != ['jsonb'] or not isinstance(payload, str):
        return None
    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _column_reference(node: Any) -> str | None:
    fields = getattr(node, 'fields', ()) or ()
    if len(fields) != 1:
        return None
    value = getattr(fields[0], 'sval', None)
    return value if isinstance(value, str) else None


def _qualified_column_reference(node: Any) -> tuple[str, ...] | None:
    fields = getattr(node, 'fields', ()) or ()
    values = tuple(getattr(field, 'sval', None) for field in fields)
    if not values or not all(isinstance(value, str) for value in values):
        return None
    return values


def _do_jsonb_bindings(body: str) -> dict[str, dict[str, Any]]:
    text_payloads: dict[str, dict[str, Any]] = {}
    for match in DO_JSON_TEXT_RE.finditer(body):
        try:
            payload = json.loads(match.group('payload'))
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            text_payloads[match.group('variable')] = payload
    bindings: dict[str, dict[str, Any]] = {}
    for match in DO_JSONB_BINDING_RE.finditer(body):
        payload = text_payloads.get(match.group('text_variable'))
        if payload is not None:
            bindings[match.group('jsonb_variable')] = payload
    return bindings


def _event_rows_from_insert(
    statement: Any,
    context: str,
    result: Validation,
    payload_bindings: dict[str, dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    columns = [getattr(column, 'name', None) for column in statement.cols or ()]
    result.require(columns == EVENT_COLUMNS, f'{context}: event registry columns differ')
    conflict = statement.onConflictClause
    infer = getattr(conflict, 'infer', None)
    conflict_columns = [
        getattr(index_element, 'name', None)
        for index_element in getattr(infer, 'indexElems', ()) or ()
    ]
    action = getattr(getattr(conflict, 'action', None), 'name', None)
    result.require(
        action == 'ONCONFLICT_UPDATE' and conflict_columns == ['event_type'],
        f'{context}: event registry upsert must use ON CONFLICT(event_type) DO UPDATE',
    )
    update_columns = [
        getattr(target, 'name', None)
        for target in getattr(conflict, 'targetList', ()) or ()
    ]
    result.require(
        update_columns == EVENT_COLUMNS[1:],
        f'{context}: event registry conflict update columns differ',
    )
    update_sources = [
        _qualified_column_reference(getattr(target, 'val', None))
        for target in getattr(conflict, 'targetList', ()) or ()
    ]
    result.require(
        update_sources
        == [('excluded', column) for column in EVENT_COLUMNS[1:]],
        f'{context}: event registry conflict update values differ',
    )
    rows = getattr(statement.selectStmt, 'valuesLists', ()) or ()
    result.require(bool(rows), f'{context}: event registry upsert must use VALUES rows')
    event_rows: list[dict[str, Any]] = []
    for position, row in enumerate(rows, start=1):
        valid_width = len(row) == len(EVENT_COLUMNS)
        result.require(valid_width, f'{context}: VALUES row {position} width differs')
        if not valid_width:
            continue
        event_type = _literal_value(row[0], 'sval')
        category = _literal_value(row[1], 'sval')
        schema_version = _literal_value(row[2], 'ival')
        active = _literal_value(row[3], 'boolval')
        payload_schema_uri = _literal_value(row[4], 'sval')
        payload_schema = _embedded_jsonb(row[5])
        if payload_schema is None and payload_bindings is not None:
            reference = _column_reference(row[5])
            payload_schema = payload_bindings.get(reference) if reference else None
        valid = (
            isinstance(event_type, str)
            and bool(event_type)
            and isinstance(category, str)
            and bool(category)
            and isinstance(schema_version, int)
            and schema_version >= 1
            and active is True
            and isinstance(payload_schema_uri, str)
            and bool(payload_schema_uri)
            and payload_schema is not None
        )
        result.require(
            valid,
            f'{context}: VALUES row {position} is not a closed active event tuple',
        )
        if valid:
            event_rows.append(
                {
                    'event_type': event_type,
                    'category': category,
                    'schema_version': schema_version,
                    'active': active,
                    'payload_schema_uri': payload_schema_uri,
                    'payload_schema': payload_schema,
                }
            )
    return event_rows


def _statement_source(source: bytes, raw_statement: Any) -> str:
    start = raw_statement.stmt_location
    length = raw_statement.stmt_len
    return source[start:start + length].decode('utf-8')


def _event_registry_inventory(
    source: bytes,
    statements: tuple[Any, ...],
    result: Validation,
    migration_label: str,
    expected_marker_count: int,
) -> tuple[list[dict[str, Any]], set[int]]:
    event_rows: list[dict[str, Any]] = []
    marker_statements: set[int] = set()
    marker_occurrences = 0
    for position, raw_statement in enumerate(statements):
        statement = raw_statement.stmt
        statement_type = type(statement).__name__
        if statement_type == 'InsertStmt' and _relation_name(statement.relation) == 'ops.event_types':
            event_rows.extend(
                _event_rows_from_insert(
                    statement,
                    f'{migration_label} top-level event INSERT',
                    result,
                )
            )
            continue
        relation = getattr(statement, 'relation', None)
        forbidden_event_mutation = (
            statement_type in {'UpdateStmt', 'DeleteStmt', 'MergeStmt', 'CopyStmt'}
            and relation is not None
            and _relation_name(relation) == 'ops.event_types'
        ) or (
            statement_type == 'TruncateStmt'
            and any(
                _relation_name(target) == 'ops.event_types'
                for target in statement.relations or ()
            )
        )
        if forbidden_event_mutation:
            result.error(
                f'{migration_label} event registry may only be changed by closed upserts'
            )
            continue
        if statement_type != 'DoStmt':
            continue
        try:
            body = _do_body(statement)
        except ValueError as exc:
            result.error(f'{migration_label} DO statement inventory failed: {exc}')
            continue
        insert_matches = list(EVENT_INSERT_RE.finditer(body))
        mutation_matches = list(EVENT_MUTATION_RE.finditer(body))
        marker_matches = DECISION_EVENT_MARKER_RE.findall(
            _statement_source(source, raw_statement)
        )
        marker_occurrences += len(marker_matches)
        marked = bool(marker_matches)
        if not marked:
            result.require(
                not mutation_matches,
                f'{migration_label} unmarked DO statement changes the event registry',
            )
            continue
        marker_statements.add(position)
        result.require(
            len(insert_matches) == 1 and len(mutation_matches) == 1,
            f'{migration_label} $decision_event_registry$ DO must contain only one event INSERT',
        )
        if len(insert_matches) != 1 or len(mutation_matches) != 1:
            continue
        try:
            nested = _nested_event_insert(body, insert_matches[0].start())
        except ValueError as exc:
            result.error(f'{migration_label} marker DO inventory failed: {exc}')
            continue
        nested_events = _event_rows_from_insert(
            nested,
            f'{migration_label} $decision_event_registry$ event INSERT',
            result,
            _do_jsonb_bindings(body),
        )
        result.require(
            len(nested_events) == 1,
            f'{migration_label} $decision_event_registry$ DO must upsert exactly one event type',
        )
        event_rows.extend(nested_events)
    result.require(
        len(marker_statements) == expected_marker_count
        and marker_occurrences == expected_marker_count,
        f'{migration_label} must contain exactly {expected_marker_count} '
        '$decision_event_registry$ DO marker(s)',
    )
    result.require(
        len(event_rows)
        == len({row['event_type'] for row in event_rows}),
        f'{migration_label} event registry inventory contains duplicate event types',
    )
    return event_rows, marker_statements


def _relation_mutation_targets(statement: Any) -> list[str]:
    statement_type = type(statement).__name__
    if statement_type == 'AlterTableStmt':
        command_types = {command.subtype.name for command in statement.cmds or ()}
        if command_types == {'AT_ChangeOwner'}:
            return []
        return [_relation_name(statement.relation)]
    if statement_type == 'CreateTrigStmt':
        return [_relation_name(statement.relation)]
    if statement_type in {'InsertStmt', 'UpdateStmt', 'DeleteStmt'}:
        relation = _relation_name(statement.relation)
        return [relation] if relation == 'ops.event_types' else []
    return []
