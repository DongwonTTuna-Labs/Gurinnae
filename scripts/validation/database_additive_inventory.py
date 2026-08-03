from __future__ import annotations

from pathlib import Path
from typing import Any

from pglast import parse_sql

from .database_additive_contract import _difference, _object_inventory_digest
from .database_event_inventory import (
    _canonical_sql,
    _event_registry_inventory,
    _relation_mutation_targets,
    _relation_name,
    _routine_signature,
    _sha256,
)
from .database_payload_inventory import (
    _validate_event_payload_forward_overrides,
    _validate_event_payload_inventory,
)
from .loaders import load_yaml
from .models import Validation


def _altered_relations(
    statements: tuple[Any, ...],
    new_relations: set[str],
    marker_statements: set[int],
) -> list[str]:
    altered: list[str] = []
    seen: set[str] = set()
    for position, raw_statement in enumerate(statements):
        targets = _relation_mutation_targets(raw_statement.stmt)
        if position in marker_statements:
            targets.append('ops.event_types')
        for target in targets:
            if target not in new_relations and target not in seen:
                seen.add(target)
                altered.append(target)
    return altered


def _extract_additive_inventory(
    migration: Path,
    result: Validation,
    migration_label: str,
    expected_marker_count: int,
) -> dict[str, Any] | None:
    source = migration.read_bytes()
    migration_sha256 = _sha256(source)
    try:
        statements = parse_sql(source.decode('utf-8'))
    except Exception as exc:
        result.error(
            f'{migration_label} runtime migration PostgreSQL parser failed: {exc}'
        )
        return None

    tables: list[tuple[str, str]] = []
    views: list[str] = []
    routines: list[tuple[str, str]] = []
    triggers: list[tuple[str, str]] = []
    indexes: list[tuple[str, str]] = []
    alter_hashes: dict[str, list[str]] = {}
    for raw_statement in statements:
        statement = raw_statement.stmt
        statement_type = type(statement).__name__
        canonical = _canonical_sql(statement)
        canonical_sha256 = _sha256(canonical.encode('utf-8'))
        if statement_type == 'CreateStmt':
            tables.append((_relation_name(statement.relation), canonical_sha256))
        elif statement_type == 'ViewStmt':
            views.append(_relation_name(statement.view))
        elif statement_type == 'CreateFunctionStmt':
            try:
                signature = _routine_signature(canonical)
            except ValueError as exc:
                result.error(f'{migration_label} routine inventory failed: {exc}')
                signature = canonical
            routines.append((signature, canonical_sha256))
        elif statement_type == 'CreateTrigStmt':
            triggers.append((canonical, canonical_sha256))
        elif statement_type == 'IndexStmt':
            indexes.append((canonical, canonical_sha256))
        elif statement_type == 'AlterTableStmt':
            relation = _relation_name(statement.relation)
            alter_hashes.setdefault(relation, []).append(canonical_sha256)

    event_rows, marker_statements = _event_registry_inventory(
        source,
        statements,
        result,
        migration_label,
        expected_marker_count=expected_marker_count,
    )
    table_names = [name for name, _ in tables]
    events = [row['event_type'] for row in event_rows]
    altered = _altered_relations(
        statements,
        set(table_names) | set(views),
        marker_statements,
    )
    counts = {
        'create_table_count': len(tables),
        'create_view_count': len(views),
        'owner_routine_count': len(routines),
        'trigger_count': len(triggers),
        'explicit_index_count': len(indexes),
        'event_registry_upsert_count': len(events),
    }
    return {
        'migration_sha256': migration_sha256,
        'tables': tables,
        'views': views,
        'routines': routines,
        'triggers': triggers,
        'indexes': indexes,
        'alter_hashes': alter_hashes,
        'event_rows': event_rows,
        'table_names': table_names,
        'events': events,
        'altered_relations': altered,
        'counts': counts,
        'object_inventory_sha256': _object_inventory_digest(
            migration_sha256,
            table_names,
            views,
            altered,
            [signature for signature, _ in routines],
            [statement for statement, _ in triggers],
            events,
        ),
    }


def _validate_additive_inventory(
    root: Path,
    result: Validation,
    *,
    migration_name: str,
    contract_name: str,
    migration_label: str,
    expected_marker_count: int,
    historical_event_ordinals: set[int] | None = None,
) -> None:
    migration = root / 'db/migrations' / migration_name
    contract_path = root / 'specs/database/addendum' / contract_name
    result.require(
        migration.is_file(),
        f'{migration_label} runtime migration is missing',
    )
    result.require(
        contract_path.is_file(),
        f'{migration_label} physical inventory contract is missing',
    )
    if not migration.is_file() or not contract_path.is_file():
        return
    contract = load_yaml(contract_path)
    actual_inventory = _extract_additive_inventory(
        migration,
        result,
        migration_label,
        expected_marker_count,
    )
    if actual_inventory is None:
        return
    migration_sha256 = actual_inventory['migration_sha256']
    tables = actual_inventory['tables']
    views = actual_inventory['views']
    routines = actual_inventory['routines']
    triggers = actual_inventory['triggers']
    indexes = actual_inventory['indexes']
    alter_hashes = actual_inventory['alter_hashes']
    event_rows = actual_inventory['event_rows']
    table_names = actual_inventory['table_names']
    events = actual_inventory['events']
    altered = actual_inventory['altered_relations']
    counts = actual_inventory['counts']
    actual_object_sha256 = actual_inventory['object_inventory_sha256']
    scope = contract['scope']
    inventory = contract['statement_inventory']
    result.require(
        scope['migration'] == migration.name,
        f'{migration_label} migration filename differs',
    )
    result.require(
        scope['migration_sha256'] == migration_sha256,
        f'{migration_label} raw migration SHA-256 differs: '
        f'YAML={scope["migration_sha256"]}, SQL={migration_sha256}',
    )
    declared_tables = contract['tables']
    declared_views = contract['compatibility_views']
    existing_changes = contract['existing_relation_changes']
    expected_tables = [
        (name, row.get('create_statement_sha256'))
        for name, row in declared_tables.items()
    ]
    expected_routines = [
        (row.get('signature'), row.get('canonical_ddl_sha256'))
        for row in contract['owner_routines']
    ]
    expected_triggers = [
        (row.get('statement'), row.get('canonical_ddl_sha256'))
        for row in contract['trigger_inventory']
    ]
    expected_indexes = [
        (row.get('statement'), row.get('canonical_ddl_sha256'))
        for row in contract['index_inventory']
    ]
    declared_events = contract['event_registry_contract']['events_in_order']
    expected_events = [row.get('event_type') for row in declared_events]
    comparisons = [
        ('scope relation order', scope['exact_relations'], table_names),
        ('table canonical inventory', expected_tables, tables),
        ('scope view order', scope['compatibility_views'], views),
        ('view inventory order', list(declared_views), views),
        ('owner routine canonical inventory', expected_routines, routines),
        ('trigger canonical inventory', expected_triggers, triggers),
        ('index canonical inventory', expected_indexes, indexes),
        ('altered relation order', scope['altered_relations'], altered),
        ('existing relation change order', [row['relation'] for row in existing_changes], altered),
        ('event registry order', expected_events, events),
    ]
    for inventory_label, expected, actual in comparisons:
        result.require(
            expected == actual,
            _difference(migration_label, inventory_label, expected, actual),
        )
    _validate_event_payload_inventory(
        root,
        declared_events,
        event_rows,
        migration_label,
        result,
        historical_event_ordinals,
    )

    expected_alters = [
        (name, row.get('alter_statement_sha256', []))
        for name, row in declared_tables.items()
    ] + [
        (row['relation'], row.get('alter_statement_sha256', []))
        for row in existing_changes
    ]
    actual_alters = [(name, alter_hashes.get(name, [])) for name, _ in expected_alters]
    result.require(
        expected_alters == actual_alters,
        _difference(
            migration_label,
            'ALTER TABLE canonical inventory',
            expected_alters,
            actual_alters,
        ),
    )
    for key, actual in counts.items():
        result.require(
            inventory.get(key) == actual,
            f'{migration_label} {key} differs: '
            f'YAML={inventory.get(key)}, SQL={actual}',
        )
    result.require(
        scope['exact_new_relation_count'] == len(tables),
        f'{migration_label} exact new relation count differs',
    )
    result.require(
        scope['relation_delta'] == len(tables),
        f'{migration_label} relation delta differs',
    )
    result.require(
        contract['event_registry_contract']['exact_upsert_count'] == len(events),
        f'{migration_label} event registry exact upsert count differs',
    )

    declared_object_sha256 = _object_inventory_digest(
        scope['migration_sha256'], scope['exact_relations'], scope['compatibility_views'],
        scope['altered_relations'], [row['signature'] for row in contract['owner_routines']],
        [row['statement'] for row in contract['trigger_inventory']], expected_events,
    )
    result.require(
        inventory['object_inventory_sha256'] == declared_object_sha256,
        f'{migration_label} YAML object inventory SHA-256 is not self-consistent',
    )
    result.require(
        inventory['object_inventory_sha256'] == actual_object_sha256,
        f'{migration_label} SQL object inventory SHA-256 differs: '
        f'YAML={inventory["object_inventory_sha256"]}, SQL={actual_object_sha256}',
    )
    stats_prefix = f'r6d_{migration_label}_'
    result.stats.update({f'{stats_prefix}{key}': value for key, value in counts.items()})
    result.stats[f'{stats_prefix}altered_relation_count'] = len(altered)
    result.stats[f'{stats_prefix}object_inventory_sha256'] = actual_object_sha256


_R6D_INVENTORY_CONTRACTS = (
    (
        '0038_r6d_legal_hardening.sql',
        '0038-r6d-legal-hardening.yaml',
        '0038',
        1,
    ),
    (
        '0039_r6d_authority_closure.sql',
        '0039-r6d-authority-closure.yaml',
        '0039',
        0,
    ),
    (
        '0040_r6d_privacy_authority_closure.sql',
        '0040-r6d-privacy-authority-closure.yaml',
        '0040',
        0,
    ),
)


def _r6d_forward_override_inventories(
    root: Path,
) -> list[dict[str, Any]]:
    inventories: list[dict[str, Any]] = []
    for migration_name, contract_name, migration_label, marker_count in (
        _R6D_INVENTORY_CONTRACTS
    ):
        migration = root / 'db/migrations' / migration_name
        contract_path = root / 'specs/database/addendum' / contract_name
        if not migration.is_file() or not contract_path.is_file():
            continue
        contract = load_yaml(contract_path)
        declared_events = contract.get('event_registry_contract', {}).get(
            'events_in_order'
        )
        if not isinstance(declared_events, list):
            continue
        scratch = Validation()
        actual_inventory = _extract_additive_inventory(
            migration,
            scratch,
            migration_label,
            marker_count,
        )
        if actual_inventory is None or scratch.errors:
            continue
        inventories.append(
            {
                'migration_name': migration_name,
                'declared_events': declared_events,
                'actual_events': actual_inventory['event_rows'],
            }
        )
    return inventories


def _validate_r6d_inventory(root: Path, result: Validation) -> None:
    proven_history = _validate_event_payload_forward_overrides(
        _r6d_forward_override_inventories(root),
        result,
    )
    for migration_name, contract_name, migration_label, marker_count in (
        _R6D_INVENTORY_CONTRACTS
    ):
        historical_ordinals = {
            event_ordinal
            for owner_migration, event_ordinal in proven_history
            if owner_migration == migration_name
        }
        _validate_additive_inventory(
            root,
            result,
            migration_name=migration_name,
            contract_name=contract_name,
            migration_label=migration_label,
            expected_marker_count=marker_count,
            historical_event_ordinals=historical_ordinals,
        )
