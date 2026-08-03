from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from .loaders import load_yaml


BASE_OPERATION_CONTRACT = 'specs/api/operation-contracts.yaml'
ADDITIVE_OPERATION_CONTRACT = 'specs/product/addendum-operation-contracts.yaml'
ADDITIVE_RESOURCE_CONTRACT = 'specs/product/addendum-resource-error-contracts.yaml'
BASE_EXTERNAL_APIS = frozenset({
    'public-api', 'submission-api', 'control-api', 'identity-provider',
})
ADDITIVE_EXTERNAL_APIS = frozenset({
    'public-api', 'submission-api', 'control-api',
})
PRIVATE_IDENTITY_API = 'identity-api'


@dataclass(frozen=True)
class HttpOperationInventory:
    base_external: tuple[dict[str, Any], ...]
    additive_all: tuple[dict[str, Any], ...]
    additive_external: tuple[dict[str, Any], ...]
    private_identity_api: tuple[dict[str, Any], ...]
    declared_additive_external_ids: frozenset[str]
    declared_private_identity_api_ids: frozenset[str]
    binding_additive_external_ids: frozenset[str]
    binding_private_identity_api_ids: frozenset[str]

    @property
    def final_external(self) -> tuple[dict[str, Any], ...]:
        return (*self.base_external, *self.additive_external)

    @property
    def all_scope_http(self) -> tuple[dict[str, Any], ...]:
        return (*self.base_external, *self.additive_all)


def operation_ids(rows: Iterable[dict[str, Any]]) -> list[str]:
    return [str(row.get('operation_id', '')) for row in rows]


def operation_api_counts(rows: Iterable[dict[str, Any]]) -> Counter[str]:
    return Counter(str(row.get('api', '')) for row in rows)


def operation_kind_counts(rows: Iterable[dict[str, Any]]) -> Counter[str]:
    return Counter(
        str(row.get('operation_kind', row.get('kind', ''))) for row in rows
    )


def non_get_count(rows: Iterable[dict[str, Any]]) -> int:
    return sum(row.get('method') != 'GET' for row in rows)


def derive_http_operation_inventory(root: Path) -> HttpOperationInventory:
    base_document = load_yaml(root / BASE_OPERATION_CONTRACT)
    additive_document = load_yaml(root / ADDITIVE_OPERATION_CONTRACT)
    resource_document = load_yaml(root / ADDITIVE_RESOURCE_CONTRACT)
    base_rows = tuple(base_document.get('operations', ()))
    additive_rows = tuple(additive_document.get('operations', ()))
    if not all(isinstance(row, dict) for row in (*base_rows, *additive_rows)):
        raise ValueError('HTTP operation catalogs must contain only mappings')
    additive_external = tuple(
        row for row in additive_rows if row.get('api') in ADDITIVE_EXTERNAL_APIS
    )
    private_identity_api = tuple(
        row for row in additive_rows if row.get('api') == PRIVATE_IDENTITY_API
    )
    declared_sets = resource_document.get('set_equality', {})
    if not isinstance(declared_sets, dict):
        raise ValueError('set_equality must be a mapping')
    declared_private_ids = declared_sets.get(
        'private_identity_api_operation_ids', ()
    )
    declared_external_ids = declared_sets.get(
        'additive_external_operation_ids', ()
    )
    if not isinstance(declared_external_ids, list) or not isinstance(
        declared_private_ids, list
    ):
        raise ValueError('additive operation ID registries must be lists')
    bindings = resource_document.get('operation_bindings', {})
    if not isinstance(bindings, dict):
        raise ValueError('operation_bindings must be a mapping')
    binding_external_ids = frozenset(
        str(operation_id)
        for operation_id, binding in bindings.items()
        if isinstance(binding, dict) and binding.get('scope') == 'ADDITIVE_EXTERNAL'
    )
    binding_private_ids = frozenset(
        str(operation_id)
        for operation_id, binding in bindings.items()
        if isinstance(binding, dict) and binding.get('scope') == 'PRIVATE_IDENTITY_API'
    )
    return HttpOperationInventory(
        base_external=base_rows,
        additive_all=additive_rows,
        additive_external=additive_external,
        private_identity_api=private_identity_api,
        declared_additive_external_ids=frozenset(
            str(value) for value in declared_external_ids
        ),
        declared_private_identity_api_ids=frozenset(
            str(value) for value in declared_private_ids
        ),
        binding_additive_external_ids=binding_external_ids,
        binding_private_identity_api_ids=binding_private_ids,
    )
