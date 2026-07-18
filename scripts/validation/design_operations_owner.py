from __future__ import annotations

from collections import Counter
import re

from .design_operations_facts import OwnerOperationFacts
from .design_support import (
    DesignDocuments,
    all_derived_markers,
    keyed_registry,
    nonempty,
)


def validate_owner_operations(documents: DesignDocuments) -> OwnerOperationFacts:
    result = documents.result
    addendum = documents.addendum
    operation_contracts = documents.operation_contracts
    base_operation_catalog = documents.base_operation_catalog
    resource_error_contracts = documents.resource_error_contracts
    base_error_catalog = documents.base_error_catalog

    result.require(
        addendum["base_authority_zip_sha256"]
        == "960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5",
        "owner addendum authority hash mismatch",
    )
    result.require(
        addendum["status"] in {"REVIEW_REQUIRED", "FINAL"},
        "owner addendum status invalid",
    )
    counts = addendum["operation_counts"]
    operations, owner_operation_by_id = keyed_registry(
        addendum["additive_operations"],
        "operation_id",
        result,
        "owner additive operation registry",
    )
    operation_ids = list(owner_operation_by_id)
    owner_operation_ids = set(owner_operation_by_id)
    owner_operation_api_counts = Counter(
        operation.get("api") for operation in operations
    )
    owner_operation_kind_counts = Counter(
        operation.get("kind") for operation in operations
    )
    result.require(
        set(owner_operation_api_counts)
        <= {"public-api", "submission-api", "control-api", "identity-api"}
        and set(owner_operation_kind_counts) == {"QUERY", "COMMAND"},
        "owner additive operation API or kind registry is not closed",
    )
    additive_api_aliases = {
        "public": "public-api",
        "submission": "submission-api",
        "control": "control-api",
        "browser_identity": "identity-api",
    }
    result.require(
        nonempty(counts.get("count_rule"))
        and set(counts.get("base", {}))
        == {
            "public",
            "submission",
            "control",
            "browser_identity",
            "external_total",
            "private_identity",
        }
        and set(counts.get("final", {}))
        == {
            "public",
            "submission",
            "control",
            "browser_identity",
            "external_total",
            "private_identity",
            "private_communication_gateway",
            "private_control_service",
            "private_application_commands",
        }
        and set(counts.get("kind_counts", {}))
        == {
            "base",
            "additive",
            "external_final",
            "private_identity",
            "private_communication_gateway",
            "private_control_service",
            "private_application_commands",
            "complete_http_catalog",
        }
        and all_derived_markers(counts.get("base"))
        and all_derived_markers(counts.get("final"))
        and all_derived_markers(counts.get("kind_counts")),
        "owner operation count contract must contain only the complete source-derived API/kind fields",
    )
    result.require(
        counts.get("additive")
        == {
            alias: f"derived count(additive_operations where api={api})"
            for alias, api in additive_api_aliases.items()
        },
        "owner additive operation count fields must be source-derived by API",
    )
    result.require(
        counts.get("kind_counts", {}).get("additive")
        == {
            "query": "derived count(additive_operations where kind=QUERY)",
            "command": "derived count(additive_operations where kind=COMMAND)",
        },
        "owner additive operation count fields must be source-derived by kind",
    )
    contracted_operations, contracted_operation_by_id = keyed_registry(
        operation_contracts["operations"],
        "operation_id",
        result,
        "product additive operation registry",
    )
    contracted_operation_ids = list(contracted_operation_by_id)
    contracted_operation_api_counts = Counter(
        operation.get("api") for operation in contracted_operations
    )
    contracted_operation_kind_counts = Counter(
        operation.get("kind") for operation in contracted_operations
    )
    result.require(
        set(contracted_operation_ids) == owner_operation_ids
        and contracted_operation_api_counts == owner_operation_api_counts
        and contracted_operation_kind_counts == owner_operation_kind_counts,
        "addendum operation contracts are not set-equal to owner additive operations",
    )
    expected_contract_count_fields = {
        "operations": "derived len(operations)",
        "queries": "derived count(operations where kind=QUERY)",
        "commands": "derived count(operations where kind=COMMAND)",
        "by_api": {
            api: f"derived count(operations where api={api})"
            for api in sorted(owner_operation_api_counts)
        },
        "rule": operation_contracts["counts"].get("rule"),
    }
    result.require(
        operation_contracts["counts"] == expected_contract_count_fields
        and nonempty(operation_contracts["counts"].get("rule")),
        "addendum operation count fields must be source-derived by API and kind",
    )
    for operation_id in sorted(
        owner_operation_ids & set(contracted_operation_by_id)
    ):
        owner_operation = owner_operation_by_id[operation_id]
        contracted_operation = contracted_operation_by_id[operation_id]
        result.require(
            all(
                owner_operation[key] == contracted_operation[key]
                for key in ("api", "method", "path", "kind")
            ),
            f"{operation_id}: owner and operation contract transport metadata drifted",
        )
        path_parameters = set(
            re.findall(r"\{([^}]+)\}", contracted_operation["path"])
        )
        required_parameters = set(contracted_operation["request"].get("required", []))
        result.require(
            path_parameters <= required_parameters,
            f"{operation_id}: path parameter is not a required typed request field",
        )
    base_operation_ids = {
        operation["operation_id"]
        for operation in base_operation_catalog["operations"]
    }
    base_transport_keys = {
        (operation["method"], operation["path"])
        for operation in base_operation_catalog["operations"]
        if operation.get("path")
    }
    additive_transport_keys = [
        (operation["method"], operation["path"])
        for operation in contracted_operations
    ]
    result.require(
        not (owner_operation_ids & base_operation_ids)
        and len(additive_transport_keys) == len(set(additive_transport_keys))
        and not (set(additive_transport_keys) & base_transport_keys),
        "addendum operation ID or method/path collides with the base or another addition",
    )

    return OwnerOperationFacts(
        operations=operations,
        operation_ids=operation_ids,
        owner_operation_by_id=owner_operation_by_id,
        owner_operation_ids=owner_operation_ids,
        owner_operation_api_counts=owner_operation_api_counts,
        owner_operation_kind_counts=owner_operation_kind_counts,
        contracted_operations=contracted_operations,
        base_operation_ids=base_operation_ids,
        counts=counts,
    )

