from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from typing import Any

from .design_operations_owner import validate_owner_operations
from .design_operations_resources import validate_private_and_resources
from .design_operations_semantics import validate_operation_semantics
from .design_support import DesignDocuments


@dataclass(frozen=True)
class OperationFacts:
    operations: list[dict[str, Any]]
    operation_ids: list[str]
    owner_operation_ids: set[str]
    owner_operation_api_counts: Counter[Any]
    owner_operation_kind_counts: Counter[Any]
    contracted_operations: list[dict[str, Any]]
    private_callback_ids: set[str]
    private_billing_ids: set[str]
    private_billing_command_ids: set[str]
    private_billing_query_ids: set[str]
    private_control_ids: set[str]
    private_application_ids: set[str]
    base_operation_ids: set[str]


def validate_operations(documents: DesignDocuments) -> OperationFacts:
    owner = validate_owner_operations(documents)
    private = validate_private_and_resources(documents, owner)
    validate_operation_semantics(documents, owner, private)
    return OperationFacts(
        operations=owner.operations,
        operation_ids=owner.operation_ids,
        owner_operation_ids=owner.owner_operation_ids,
        owner_operation_api_counts=owner.owner_operation_api_counts,
        owner_operation_kind_counts=owner.owner_operation_kind_counts,
        contracted_operations=owner.contracted_operations,
        private_callback_ids=private.private_callback_ids,
        private_billing_ids=private.private_billing_ids,
        private_billing_command_ids=private.private_billing_command_ids,
        private_billing_query_ids=private.private_billing_query_ids,
        private_control_ids=private.private_control_ids,
        private_application_ids=private.private_application_ids,
        base_operation_ids=owner.base_operation_ids,
    )
