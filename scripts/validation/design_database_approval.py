from __future__ import annotations

from pathlib import Path
from typing import Any

from .design_database_support import (
    APPROVAL_BINDING_V1_FIELDS,
    APPROVAL_DETAIL_RELATIONS,
    _candidate_keys,
    _check_expressions,
    _column_names,
    _foreign_keys,
    _parse_reference,
)
from .loaders import load_yaml
from .models import Validation

def _validate_approval_option_b(
    root: Path,
    approval_database: dict[str, Any],
    rows: dict[str, dict[str, Any]],
    result: Validation,
) -> None:
    policy = load_yaml(root / "specs/product/addendum-approval-policy.yaml")
    resources = load_yaml(
        root / "specs/product/addendum-resource-error-contracts.yaml"
    )
    expected_fields = set(APPROVAL_BINDING_V1_FIELDS)
    expected_kinds = set(APPROVAL_DETAIL_RELATIONS)
    policy_binding = policy["closed_binding_schemas"]["ApprovalBindingV1"]
    resource_binding = resources["schemas"]["ApprovalBindingV1"]
    database_binding = approval_database["closed_json_types"]["ApprovalBindingV1"]
    result.require(
        len(APPROVAL_BINDING_V1_FIELDS) == len(expected_fields) == 32
        and set(policy_binding.get("required", [])) == expected_fields
        and set(policy_binding.get("properties", {})) == expected_fields
        and set(resource_binding.get("required", [])) == expected_fields
        and set(resource_binding.get("fields", {})) == expected_fields
        and set(database_binding.get("required_keys", [])) == expected_fields
        and set(
            approval_database["approval_binding_physical_contract"][
                "exact_field_mapping"
            ]
        )
        == expected_fields,
        "ApprovalBindingV1 is not exact-set equal to the canonical Option B 32-field common binding",
    )
    detail_schema = resources["schemas"]["ActionApprovalDetailV1"]
    detail_binding = resources["schemas"]["ActionApprovalDetailBindingV1"]
    result.require(
        set(detail_schema.get("variants", {})) == expected_kinds
        and detail_binding.get("additional_properties") is False
        and detail_binding.get("required") == ["actionDetailKind", "actionDetail"]
        and set(detail_binding.get("fields", {}))
        == {"actionDetailKind", "actionDetail"}
        and set(database_binding.get("action_detail_kinds", [])) == expected_kinds,
        "ActionApprovalDetailBindingV1 is not the closed exact seventeen-branch wrapper",
    )
    detail_rows = {
        row.get("detail_kind"): relation
        for relation, row in rows.items()
        if relation.startswith("ops.action_approval_")
        and relation.endswith("_details")
    }
    result.require(
        len(detail_rows) == len(APPROVAL_DETAIL_RELATIONS) == 17
        and detail_rows == APPROVAL_DETAIL_RELATIONS,
        "Option B action-kind to typed approval-detail relation registry is not exact",
    )
    parent = rows.get("ops.action_proposal_versions", {})
    parent_columns = {
        column["name"]: column for column in parent.get("columns", [])
    }
    parent_checks = "\n".join(_check_expressions(parent))
    result.require(
        parent_columns.get("action_detail_canonical", {}).get("logical_type")
        == "GURINE_CANONICAL_JSON_V1<ActionApprovalDetailBindingV1>"
        and "jsonb_build_object('actionDetailKind',action_detail_kind,'actionDetail',action_detail)"
        in parent_checks
        and "action_detail_digest = encode(extensions.digest(action_detail_canonical,'sha256'),'hex')"
        in parent_checks,
        "action proposal detail digest is not computed from the canonical kind-plus-detail wrapper",
    )
    parent_key = (
        "proposal_id",
        "version",
        "action_detail_kind",
        "action_detail_digest",
    )
    result.require(
        parent_key in _candidate_keys(parent),
        "action proposal version lacks the exact typed-detail parent candidate key",
    )
    support_signatures = {
        row["signature"]
        for row in approval_database["support_function_catalog"]["functions"]
    }
    common_child_columns = {
        "proposal_id",
        "proposal_version",
        "detail_kind",
        "detail_binding_canonical",
        "action_detail_digest",
        "created_at",
    }
    for kind, relation in APPROVAL_DETAIL_RELATIONS.items():
        row = rows.get(relation, {})
        columns = set(_column_names(row))
        parent_targets = {
            _parse_reference(foreign_key)
            for foreign_key in _foreign_keys(row)
        }
        validator = row.get("validator")
        result.require(
            common_child_columns <= columns
            and row.get("detail_kind") == kind
            and row.get("primary_key") == ["proposal_id", "proposal_version"]
            and (
                "ops.action_proposal_versions",
                parent_key,
            )
            in parent_targets
            and isinstance(validator, str)
            and f"{validator} RETURNS boolean" in support_signatures
            and bool(row.get("source_binding_contract")),
            f"{relation}: typed Option B detail physical contract is incomplete",
        )
    result.stats["approval_binding_common_fields"] = len(expected_fields)
    result.stats["approval_detail_relations"] = len(detail_rows)

