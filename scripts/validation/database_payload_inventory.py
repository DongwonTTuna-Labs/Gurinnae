from __future__ import annotations

import json
from pathlib import Path
import re
from typing import Any

from .database_event_inventory import _sha256
from .loaders import load_yaml
from .models import Validation


_MIGRATION_NAME_RE = re.compile(r'^(?P<ordinal>[0-9]{4})_[a-z0-9_]+\.sql$')
_SHA256_RE = re.compile(r'^[0-9a-f]{64}$')


def _canonical_json_sha256(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(',', ':'),
    ).encode('utf-8')
    return _sha256(encoded)


def _forward_pointer(
    value: Any,
    *,
    context: str,
    result: Validation,
) -> tuple[str, int] | None:
    if value is None:
        return None
    valid_shape = (
        isinstance(value, dict)
        and set(value) == {'migration', 'event_ordinal'}
        and isinstance(value.get('migration'), str)
        and _MIGRATION_NAME_RE.fullmatch(value['migration']) is not None
        and isinstance(value.get('event_ordinal'), int)
        and not isinstance(value.get('event_ordinal'), bool)
        and value['event_ordinal'] >= 1
    )
    result.require(
        valid_shape,
        f'{context} must be a closed migration/event_ordinal pointer',
    )
    if not valid_shape:
        return None
    return value['migration'], value['event_ordinal']


def _event_tuple(row: dict[str, Any]) -> tuple[Any, Any, Any, Any]:
    return (
        row.get('event_type'),
        row.get('category'),
        row.get('schema_version'),
        row.get('payload_schema_uri'),
    )


def _validate_event_payload_forward_overrides(
    inventories: list[dict[str, Any]],
    result: Validation,
) -> set[tuple[str, int]]:
    """Validate forward-only event schema ownership and return proven history.

    A historical row is exempt from comparison with the *current* named JSON
    Schema only after the complete reciprocal chain has been proven. Its own
    embedded schema remains pinned by a canonical digest. The unique final row
    is deliberately not returned, so ordinary current-file validation remains
    mandatory for the latest owner.
    """
    nodes: dict[tuple[str, int], dict[str, Any]] = {}
    by_event: dict[str, list[tuple[str, int]]] = {}
    for inventory in inventories:
        migration = inventory.get('migration_name')
        migration_match = (
            _MIGRATION_NAME_RE.fullmatch(migration)
            if isinstance(migration, str)
            else None
        )
        result.require(
            migration_match is not None,
            f'event payload inventory migration name is invalid: {migration!r}',
        )
        declared_events = inventory.get('declared_events')
        actual_events = inventory.get('actual_events')
        valid_events = (
            isinstance(declared_events, list)
            and isinstance(actual_events, list)
            and len(declared_events) == len(actual_events)
        )
        result.require(
            valid_events,
            f'{migration} event payload forward inventory count differs',
        )
        if migration_match is None or not valid_events:
            continue
        for event_ordinal, (declared, actual) in enumerate(
            zip(declared_events, actual_events, strict=True),
            start=1,
        ):
            if not isinstance(declared, dict) or not isinstance(actual, dict):
                result.error(
                    f'{migration} event row {event_ordinal} is not a mapping'
                )
                continue
            key = (migration, event_ordinal)
            nodes[key] = {
                'declared': declared,
                'actual': actual,
                'migration_ordinal': int(migration_match.group('ordinal')),
            }
            event_type = declared.get('event_type')
            if isinstance(event_type, str):
                by_event.setdefault(event_type, []).append(key)

    proven_historical_rows: set[tuple[str, int]] = set()
    for event_type, group_keys in by_event.items():
        group_result = Validation()
        successors: dict[tuple[str, int], tuple[str, int]] = {}
        predecessors: dict[tuple[str, int], tuple[str, int]] = {}
        for key in group_keys:
            node = nodes[key]
            declared = node['declared']
            actual = node['actual']
            group_result.require(
                _event_tuple(declared) == _event_tuple(actual),
                f'{key[0]} event row {key[1]} declared/embedded tuple differs',
            )
            successor = _forward_pointer(
                declared.get('forward_superseded_by'),
                context=(
                    f'{key[0]} event row {key[1]} forward_superseded_by'
                ),
                result=group_result,
            )
            predecessor = _forward_pointer(
                declared.get('forward_supersedes'),
                context=f'{key[0]} event row {key[1]} forward_supersedes',
                result=group_result,
            )
            if successor is not None:
                successors[key] = successor
            if predecessor is not None:
                predecessors[key] = predecessor

        if len(group_keys) > 1 and not successors and not predecessors:
            group_result.error(
                f'{event_type} duplicate event owners are linkless'
            )
        final_keys = [key for key in group_keys if key not in successors]
        initial_keys = [key for key in group_keys if key not in predecessors]
        group_result.require(
            len(final_keys) == 1,
            f'{event_type} must have exactly one final event schema owner',
        )
        group_result.require(
            len(initial_keys) == 1,
            f'{event_type} must have exactly one initial event schema owner',
        )
        group_result.require(
            len(successors) == max(0, len(group_keys) - 1),
            f'{event_type} forward schema chain has a missing successor link',
        )
        group_result.require(
            len(predecessors) == max(0, len(group_keys) - 1),
            f'{event_type} forward schema chain has a missing predecessor link',
        )

        for source_key, target_key in successors.items():
            source = nodes[source_key]
            target = nodes.get(target_key)
            group_result.require(
                target is not None,
                f'{source_key[0]} event row {source_key[1]} forward target is missing: '
                f'{target_key[0]}#{target_key[1]}',
            )
            if target is None:
                continue
            group_result.require(
                predecessors.get(target_key) == source_key,
                f'{source_key[0]} event row {source_key[1]} forward link is not reciprocal',
            )
            group_result.require(
                target['migration_ordinal'] > source['migration_ordinal'],
                f'{source_key[0]} event row {source_key[1]} forward target is not later',
            )
            source_tuple = _event_tuple(source['actual'])
            target_tuple = _event_tuple(target['actual'])
            group_result.require(
                source_tuple == target_tuple,
                f'{event_type} forward owner event/category/version/URI tuple differs',
            )
            declared_digest = source['declared'].get(
                'embedded_payload_schema_canonical_sha256'
            )
            actual_digest = _canonical_json_sha256(
                source['actual'].get('payload_schema')
            )
            group_result.require(
                isinstance(declared_digest, str)
                and _SHA256_RE.fullmatch(declared_digest) is not None
                and declared_digest == actual_digest,
                f'{source_key[0]} event row {source_key[1]} historical embedded '
                'payload schema canonical SHA-256 differs',
            )

        for target_key, source_key in predecessors.items():
            source = nodes.get(source_key)
            group_result.require(
                source is not None,
                f'{target_key[0]} event row {target_key[1]} forward predecessor is missing: '
                f'{source_key[0]}#{source_key[1]}',
            )
            if source is not None:
                group_result.require(
                    successors.get(source_key) == target_key,
                    f'{target_key[0]} event row {target_key[1]} backward link is not reciprocal',
                )

        if len(initial_keys) == 1 and len(final_keys) == 1:
            visited: set[tuple[str, int]] = set()
            cursor = initial_keys[0]
            while cursor not in visited:
                visited.add(cursor)
                next_key = successors.get(cursor)
                if next_key is None:
                    break
                cursor = next_key
            group_result.require(
                visited == set(group_keys) and cursor == final_keys[0],
                f'{event_type} forward schema chain is disconnected or cyclic',
            )

        result.errors.extend(group_result.errors)
        result.warnings.extend(group_result.warnings)
        if not group_result.errors:
            proven_historical_rows.update(successors)

    return proven_historical_rows


def _resolve_local_schema_refs(value: Any, definitions: dict[str, Any]) -> Any:
    if isinstance(value, list):
        return [_resolve_local_schema_refs(item, definitions) for item in value]
    if not isinstance(value, dict):
        return value
    reference = value.get('$ref')
    if isinstance(reference, str) and reference.startswith('#/$defs/'):
        target = definitions.get(reference.removeprefix('#/$defs/'))
        if not isinstance(target, dict):
            raise ValueError(f'missing local JSON Schema definition: {reference}')
        siblings = {key: item for key, item in value.items() if key != '$ref'}
        return _resolve_local_schema_refs({**target, **siblings}, definitions)
    return {
        key: _resolve_local_schema_refs(item, definitions)
        for key, item in value.items()
        if key != '$defs'
    }


def _validate_event_payload_inventory(
    root: Path,
    declared_events: list[dict[str, Any]],
    actual_events: list[dict[str, Any]],
    migration_label: str,
    result: Validation,
    historical_event_ordinals: set[int] | None = None,
) -> None:
    if len(declared_events) != len(actual_events):
        return
    base_events = load_yaml(root / 'specs/events/event-catalog.yaml').get('events', [])
    additive_events = load_yaml(
        root / 'specs/product/addendum-event-contracts.yaml'
    ).get('events', {})
    source_events = {
        row['event_type']: row
        for row in base_events
        if isinstance(row, dict) and isinstance(row.get('event_type'), str)
    }
    if isinstance(additive_events, dict):
        result.require(
            not (set(source_events) & set(additive_events)),
            f'{migration_label} base/additive event catalog keys overlap',
        )
        source_events.update(additive_events)
    proven_historical = historical_event_ordinals or set()
    for event_ordinal, (declared, actual) in enumerate(
        zip(declared_events, actual_events, strict=True),
        start=1,
    ):
        event_type = declared.get('event_type')
        schema_path_value = declared.get('payload_schema_path')
        schema_sha256 = declared.get('payload_schema_sha256')
        structurally_embedded = declared.get('embedded_json_equivalent') is True
        valid_path = (
            isinstance(schema_path_value, str)
            and schema_path_value.startswith('specs/events/payloads/')
        )
        result.require(
            valid_path and structurally_embedded,
            f'{migration_label} {event_type} payload contract is not closed',
        )
        if not valid_path:
            continue
        schema_path = root / schema_path_value
        result.require(
            schema_path.is_file(),
            f'{migration_label} {event_type} payload schema is missing',
        )
        if not schema_path.is_file():
            continue
        schema_bytes = schema_path.read_bytes()
        actual_sha256 = _sha256(schema_bytes)
        is_proven_historical = event_ordinal in proven_historical
        resolved_file_schema: Any | None = None
        if is_proven_historical:
            embedded_digest = declared.get(
                'embedded_payload_schema_canonical_sha256'
            )
            actual_embedded_digest = _canonical_json_sha256(
                actual.get('payload_schema')
            )
            result.require(
                isinstance(schema_sha256, str)
                and _SHA256_RE.fullmatch(schema_sha256) is not None,
                f'{migration_label} {event_type} historical named payload schema '
                'SHA-256 is invalid',
            )
            result.require(
                embedded_digest == actual_embedded_digest,
                f'{migration_label} {event_type} historical embedded payload schema '
                'canonical SHA-256 differs',
            )
        else:
            result.require(
                schema_sha256 == actual_sha256,
                f'{migration_label} {event_type} payload schema SHA-256 differs: '
                f'YAML={schema_sha256}, file={actual_sha256}',
            )
            try:
                file_schema = json.loads(schema_bytes)
            except json.JSONDecodeError as exc:
                result.error(
                    f'{migration_label} {event_type} payload schema JSON failed: {exc}'
                )
                continue
            try:
                resolved_file_schema = _resolve_local_schema_refs(
                    file_schema,
                    file_schema.get('$defs', {})
                    if isinstance(file_schema, dict)
                    else {},
                )
            except ValueError as exc:
                result.error(
                    f'{migration_label} {event_type} payload schema failed: {exc}'
                )
                continue
        expected_uri = schema_path_value.removeprefix('specs/events/')
        result.require(
            actual.get('event_type') == event_type,
            f'{migration_label} event payload inventory order differs at {event_type}',
        )
        source_event = source_events.get(event_type)
        result.require(
            isinstance(source_event, dict),
            f'{migration_label} {event_type} is absent from the effective event catalog',
        )
        if isinstance(source_event, dict):
            result.require(
                actual.get('category') == source_event.get('category')
                and actual.get('schema_version') == source_event.get('schema_version'),
                f'{migration_label} {event_type} category/schema version differs '
                'from the additive event catalog',
            )
        result.require(
            actual.get('payload_schema_uri') == expected_uri,
            f'{migration_label} {event_type} payload schema URI differs',
        )
        if not is_proven_historical:
            result.require(
                actual.get('payload_schema') == resolved_file_schema,
                f'{migration_label} {event_type} embedded payload schema differs from source JSON',
            )
