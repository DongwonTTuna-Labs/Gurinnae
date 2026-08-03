from __future__ import annotations

import json
from typing import Any

from .database_event_inventory import _sha256


def _difference(
    migration_label: str,
    label: str,
    expected: list[Any],
    actual: list[Any],
) -> str:
    common = min(len(expected), len(actual))
    for position in range(common):
        if expected[position] != actual[position]:
            return (
                f'{migration_label} {label} differs at source position {position + 1}: '
                f'YAML={expected[position]!r}, SQL={actual[position]!r}'
            )
    return (
        f'{migration_label} {label} count differs: '
        f'YAML={len(expected)}, SQL={len(actual)}'
    )


def _object_inventory_digest(
    migration_sha256: str,
    relations: list[str],
    views: list[str],
    altered_relations: list[str],
    routines: list[str],
    triggers: list[str],
    event_types: list[str],
) -> str:
    preimage = {
        'migration_sha256': migration_sha256,
        'relations': relations,
        'views': views,
        'altered_relations': altered_relations,
        'routines': routines,
        'triggers': triggers,
        'event_types': event_types,
    }
    encoded = json.dumps(
        preimage, ensure_ascii=False, sort_keys=True, separators=(',', ':'),
    ).encode('utf-8')
    return _sha256(encoded)
