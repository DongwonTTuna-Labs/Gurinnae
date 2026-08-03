from __future__ import annotations

from .design_operations_payment_lifecycle import (
    validate_payment_lifecycle_contracts,
)
from .design_operations_payment_persistence import (
    validate_payment_persistence_source_boundary,
)
from .design_operations_payment_review import validate_payment_review_cross_effect
from .design_support import DesignDocuments


def validate_payment_source_contracts(documents: DesignDocuments) -> None:
    validate_payment_lifecycle_contracts(documents)
    validate_payment_persistence_source_boundary(documents)
    validate_payment_review_cross_effect(documents)
