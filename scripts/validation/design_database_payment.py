from __future__ import annotations

from typing import Any

from .design_database_support import _check_expressions
from .models import Validation


def _validate_billing_key_fixture_reference(
    rows: dict[str, dict[str, Any]],
    result: Validation,
) -> None:
    canonical_pattern = (
        "billing_key_secret_reference ~ "
        "'^fixture://billing-key/[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
        "[89ab][0-9a-f]{3}-[0-9a-f]{12}@v2$'"
    )
    matching_checks = [
        expression
        for expression in _check_expressions(rows.get("ops.payment_method_bindings", {}))
        if "fixture://billing-key/" in expression
    ]
    result.require(
        len(matching_checks) == 1 and canonical_pattern in matching_checks[0],
        "0041 billing-key fixture reference is not the exact @v2 canonical form",
    )
