from __future__ import annotations

from pathlib import Path
from typing import Any

from pglast import parse_sql

from .database_event_inventory import (
    EVENT_COLUMNS,
    _embedded_jsonb,
    _literal_value,
    _relation_name,
)
from .database_payload_inventory import _canonical_json_sha256
from .models import Validation


_R6E_EVENT_TYPES = (
    'donation.fact_recorded.v1',
    'notification.payment_review_requested.v1',
)
_R6E_HISTORICAL_EVENT_OVERRIDE_TYPES = (
    'governance.funding_disclosure_published.v1',
    'action.proposal_created.v1',
    'governance.funding_snapshot_created.v1',
    'commercial.sku_readiness_evaluated.v1',
)
_R6E_HISTORICAL_EVENT_SOURCE_MIGRATION = (
    '0030_v13_submission_session_hardening.sql'
)


def _declared_event_inventory(
    contract: dict[str, Any],
    result: Validation,
    migration_label: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    registry = contract.get('event_registry_contract', {})
    ordinary = registry.get('events_in_order')
    if isinstance(ordinary, list):
        return ordinary, [], ordinary

    owned = registry.get('owned_events_in_order')
    overrides = registry.get('historical_event_forward_overrides')
    result.require(
        isinstance(owned, list) and isinstance(overrides, list),
        f'{migration_label} split event inventory must declare owned events and '
        'historical forward overrides',
    )
    if not isinstance(owned, list) or not isinstance(overrides, list):
        return [], [], []

    current_overrides: list[dict[str, Any]] = []
    for ordinal, row in enumerate(overrides, start=1):
        if not isinstance(row, dict):
            result.error(
                f'{migration_label} historical event override {ordinal} is not a mapping'
            )
            continue
        current_overrides.append(
            {
                'event_type': row.get('event_type'),
                'payload_schema_path': row.get('current_payload_schema_path'),
                'payload_schema_sha256': row.get('current_payload_schema_sha256'),
                'embedded_json_equivalent': True,
            }
        )
    return owned, overrides, [*owned, *current_overrides]


def _legacy_effective_event_rows(
    migration: Path,
    result: Validation,
    migration_label: str,
) -> dict[str, dict[str, Any]]:
    try:
        statements = parse_sql(migration.read_text(encoding='utf-8'))
    except Exception as exc:
        result.error(
            f'{migration_label} historical event source PostgreSQL parser failed: {exc}'
        )
        return {}

    registries: list[tuple[Any, ...]] = []
    for raw_statement in statements:
        statement = raw_statement.stmt
        if (
            type(statement).__name__ != 'InsertStmt'
            or _relation_name(statement.relation) != 'ops.event_types'
            or [getattr(column, 'name', None) for column in statement.cols or ()]
            != EVENT_COLUMNS
        ):
            continue
        with_clause = getattr(statement, 'withClause', None)
        for cte in getattr(with_clause, 'ctes', ()) or ():
            alias_columns = [
                getattr(column, 'sval', None)
                for column in getattr(cte, 'aliascolnames', ()) or ()
            ]
            values = getattr(getattr(cte, 'ctequery', None), 'valuesLists', ()) or ()
            if cte.ctename == 'effective_event_types' and alias_columns == EVENT_COLUMNS:
                registries.append(values)

    result.require(
        len(registries) == 1,
        f'{migration_label} must contain exactly one final effective event registry',
    )
    if len(registries) != 1:
        return {}

    rows: dict[str, dict[str, Any]] = {}
    for ordinal, values in enumerate(registries[0], start=1):
        valid_width = len(values) == len(EVENT_COLUMNS)
        result.require(
            valid_width,
            f'{migration_label} final event row {ordinal} width differs',
        )
        if not valid_width:
            continue
        event_type = _literal_value(values[0], 'sval')
        category = _literal_value(values[1], 'sval')
        schema_version = _literal_value(values[2], 'ival')
        active = _literal_value(values[3], 'boolval')
        payload_schema_uri = _literal_value(values[4], 'sval')
        payload_schema = _embedded_jsonb(values[5])
        valid = (
            isinstance(event_type, str)
            and isinstance(category, str)
            and isinstance(schema_version, int)
            and active is True
            and isinstance(payload_schema_uri, str)
            and payload_schema is not None
        )
        result.require(
            valid,
            f'{migration_label} final event row {ordinal} is not a closed active tuple',
        )
        if not valid or not isinstance(event_type, str):
            continue
        result.require(
            event_type not in rows,
            f'{migration_label} final event registry duplicates {event_type}',
        )
        rows[event_type] = {
            'event_type': event_type,
            'category': category,
            'schema_version': schema_version,
            'active': active,
            'payload_schema_uri': payload_schema_uri,
            'payload_schema': payload_schema,
            'event_ordinal': ordinal,
        }
    return rows


def _validate_historical_event_forward_overrides(
    root: Path,
    result: Validation,
    *,
    migration_label: str,
    overrides: list[dict[str, Any]],
    actual_overrides: list[dict[str, Any]],
) -> None:
    if migration_label != '0041':
        result.require(
            not overrides,
            f'{migration_label} has an unregistered historical event override',
        )
        return

    result.require(
        tuple(row.get('event_type') for row in overrides if isinstance(row, dict))
        == _R6E_HISTORICAL_EVENT_OVERRIDE_TYPES,
        '0041 historical event overrides must be the exact ordered R6e forward set',
    )
    result.require(
        len(overrides) == len(actual_overrides) == 4,
        '0041 historical event override count must be exactly four',
    )
    legacy_path = root / 'db/migrations' / _R6E_HISTORICAL_EVENT_SOURCE_MIGRATION
    result.require(
        legacy_path.is_file(),
        '0041 historical event source migration is missing',
    )
    if not legacy_path.is_file() or len(overrides) != len(actual_overrides):
        return
    legacy_rows = _legacy_effective_event_rows(
        legacy_path,
        result,
        _R6E_HISTORICAL_EVENT_SOURCE_MIGRATION,
    )

    common_keys = {
        'event_type',
        'ordered_current_upsert_position',
        'prior_source_identity',
        'current_payload_schema_path',
        'current_payload_schema_sha256',
        'reason',
    }
    event_specific_keys = {
        'governance.funding_disclosure_published.v1': {'current_fields_exactly'},
        'action.proposal_created.v1': {'current_change'},
        'governance.funding_snapshot_created.v1': {'current_fields_exactly'},
        'commercial.sku_readiness_evaluated.v1': {'current_fields_exactly'},
    }
    for ordinal, (declared, actual) in enumerate(
        zip(overrides, actual_overrides, strict=True),
        start=1,
    ):
        event_type = declared.get('event_type')
        result.require(
            set(declared) == common_keys | event_specific_keys.get(event_type, set()),
            f'0041 historical event override {ordinal} is not a closed declaration',
        )
        result.require(
            declared.get('ordered_current_upsert_position') == ordinal,
            f'0041 historical event override {event_type} position differs',
        )
        prior_identity = declared.get('prior_source_identity')
        valid_prior_shape = isinstance(prior_identity, dict) and set(prior_identity) == {
            'migration',
            'event_ordinal',
            'event_type',
            'payload_schema_uri',
            'embedded_payload_schema_canonical_sha256',
        }
        result.require(
            valid_prior_shape,
            f'0041 historical event override {event_type} prior identity is not closed',
        )
        if not valid_prior_shape or not isinstance(prior_identity, dict):
            continue
        prior = legacy_rows.get(str(event_type))
        result.require(
            prior is not None,
            f'0041 historical event override source is missing for {event_type}',
        )
        if prior is None:
            continue
        current_path = declared.get('current_payload_schema_path')
        expected_uri = (
            current_path.removeprefix('specs/events/')
            if isinstance(current_path, str)
            else None
        )
        result.require(
            prior_identity.get('migration')
            == _R6E_HISTORICAL_EVENT_SOURCE_MIGRATION
            and prior_identity.get('event_ordinal') == prior.get('event_ordinal')
            and prior_identity.get('event_type') == event_type
            and prior_identity.get('payload_schema_uri') == expected_uri
            and actual.get('event_type') == event_type
            and actual.get('category') == prior.get('category')
            and actual.get('schema_version') == prior.get('schema_version')
            and actual.get('payload_schema_uri') == prior.get('payload_schema_uri')
            == expected_uri,
            f'0041 historical event override tuple differs for {event_type}',
        )
        prior_digest = _canonical_json_sha256(prior.get('payload_schema'))
        current_schema = actual.get('payload_schema')
        current_digest = _canonical_json_sha256(current_schema)
        result.require(
            prior_identity.get('embedded_payload_schema_canonical_sha256')
            == prior_digest,
            f'0041 historical embedded payload schema digest differs for {event_type}',
        )
        result.require(
            current_digest != prior_digest,
            f'0041 historical event override does not change {event_type}',
        )

        if event_type in {
            'governance.funding_disclosure_published.v1',
            'governance.funding_snapshot_created.v1',
            'commercial.sku_readiness_evaluated.v1',
        }:
            fields = declared.get('current_fields_exactly')
            result.require(
                isinstance(current_schema, dict)
                and fields == current_schema.get('required')
                and isinstance(fields, list)
                and set(current_schema.get('properties', {})) == set(fields),
                f'0041 historical event fields are not exact for {event_type}',
            )
        elif event_type == 'action.proposal_created.v1':
            prior_enum = (
                prior.get('payload_schema', {})
                .get('properties', {})
                .get('actionKind', {})
                .get('enum')
            )
            current_enum = (
                current_schema.get('properties', {})
                .get('actionKind', {})
                .get('enum')
                if isinstance(current_schema, dict)
                else None
            )
            result.require(
                declared.get('current_change')
                == 'add ECONOMICS_IMPORT to the closed actionKind enum'
                and isinstance(prior_enum, list)
                and current_enum == [*prior_enum, 'ECONOMICS_IMPORT'],
                '0041 action proposal event override is not the exact ECONOMICS_IMPORT extension',
            )
