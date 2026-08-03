from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class OwnerOperationFacts:
    operations: list[dict[str, Any]]
    operation_ids: list[str]
    owner_operation_by_id: dict[str, dict[str, Any]]
    owner_operation_ids: set[str]
    owner_operation_api_counts: Counter[Any]
    owner_operation_kind_counts: Counter[Any]
    contracted_operations: list[dict[str, Any]]
    base_operation_ids: set[str]
    counts: dict[str, Any]


@dataclass(frozen=True)
class PrivateOperationFacts:
    private_callback_ids: set[str]
    private_control_ids: set[str]
    private_application_ids: set[str]

