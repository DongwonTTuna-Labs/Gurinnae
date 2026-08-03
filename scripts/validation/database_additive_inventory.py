from __future__ import annotations

from pathlib import Path
from typing import Any

from .database_additive_inventory_core import (
    _extract_additive_inventory,
    _validate_additive_inventory,
)
from .database_payload_inventory import _validate_event_payload_forward_overrides
from .database_r6e_event_inventory import (
    _R6E_EVENT_TYPES,
    _declared_event_inventory,
    _legacy_effective_event_rows,
    _validate_historical_event_forward_overrides,
)
from .loaders import load_yaml
from .models import Validation


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

_R6E_INVENTORY_CONTRACTS = (
    (
        '0041_r6e_monetization_runtime.sql',
        '0041-r6e-monetization-runtime.yaml',
        '0041',
        0,
    ),
)

_LATE_ADDITIVE_INVENTORY_CONTRACTS = (
    *_R6D_INVENTORY_CONTRACTS,
    *_R6E_INVENTORY_CONTRACTS,
)


def _r6d_forward_override_inventories(
    root: Path,
) -> list[dict[str, Any]]:
    inventories: list[dict[str, Any]] = []
    for migration_name, contract_name, migration_label, marker_count in (
        _LATE_ADDITIVE_INVENTORY_CONTRACTS
    ):
        migration = root / 'db/migrations' / migration_name
        contract_path = root / 'specs/database/addendum' / contract_name
        if not migration.is_file() or not contract_path.is_file():
            continue
        contract = load_yaml(contract_path)
        event_contract = contract.get('event_registry_contract', {})
        declared_events = event_contract.get('events_in_order')
        owned_count: int | None = None
        if not isinstance(declared_events, list):
            declared_events = event_contract.get('owned_events_in_order')
            owned_count = len(declared_events) if isinstance(declared_events, list) else None
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
                'actual_events': (
                    actual_inventory['event_rows'][:owned_count]
                    if owned_count is not None
                    else actual_inventory['event_rows']
                ),
            }
        )
    return inventories


def _validate_r6d_inventory(root: Path, result: Validation) -> None:
    proven_history = _validate_event_payload_forward_overrides(
        _r6d_forward_override_inventories(root),
        result,
    )
    for migration_name, contract_name, migration_label, marker_count in (
        _LATE_ADDITIVE_INVENTORY_CONTRACTS
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
