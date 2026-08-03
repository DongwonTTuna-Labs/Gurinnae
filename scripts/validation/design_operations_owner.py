from __future__ import annotations

from collections import Counter
import re

from git_authority import AUTHORITY_ZIP_SHA256

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
        addendum["base_authority_zip_sha256"] == AUTHORITY_ZIP_SHA256,
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
    base_counts = counts.get("base", {})
    additive_counts = counts.get("additive", {})
    final_counts = counts.get("final", {})
    private_counts = counts.get("separate_private_inventories", {})
    kind_counts = counts.get("kind_counts", {})
    declared_private_identity_ids = counts.get(
        "private_identity_api_operation_ids", []
    )
    expected_private_identity_ids = {
        operation["operation_id"]
        for operation in operations
        if operation.get("api") == "identity-api"
    }
    additive_derived = {
        key: value
        for key, value in additive_counts.items()
        if key != "partition_contract"
    }
    private_derived = {
        key: value
        for key, value in private_counts.items()
        if key != "scope_rule"
    }
    result.require(
        set(counts)
        == {
            "count_rule",
            "external_scope_rule",
            "all_scope_http_rule",
            "private_identity_api_scope",
            "private_identity_api_operation_ids",
            "private_identity_api_registry_contract",
            "base_additive_disjointness_rule",
            "base",
            "additive",
            "final",
            "separate_private_inventories",
            "kind_counts",
            "additive_operations",
        }
        and all(
            nonempty(counts.get(field))
            for field in (
                "count_rule",
                "external_scope_rule",
                "all_scope_http_rule",
                "private_identity_api_registry_contract",
                "base_additive_disjointness_rule",
            )
        )
        and counts.get("private_identity_api_scope") == "PRIVATE_IDENTITY_API"
        and len(declared_private_identity_ids)
        == len(set(declared_private_identity_ids))
        and set(declared_private_identity_ids) == expected_private_identity_ids
        and counts.get("additive_operations") == operations
        and set(base_counts)
        == {
            "external_operation_ids",
            "public",
            "submission",
            "control",
            "browser_identity",
            "external_total",
        }
        and set(additive_counts)
        == {
            "operation_ids",
            "external_operation_ids",
            "private_identity_api_operation_ids",
            "public",
            "submission",
            "control",
            "browser_identity",
            "external_total",
            "private_identity_api",
            "all_scope_http_total",
            "partition_contract",
        }
        and set(final_counts)
        == {
            "external_operation_ids",
            "public",
            "submission",
            "control",
            "browser_identity",
            "external_total",
            "private_identity_api_operation_ids",
            "all_scope_http_operation_ids",
            "all_scope_http_total",
        }
        and set(private_counts)
        == {
            "private_identity_service",
            "private_communication_gateway",
            "private_billing_gateway",
            "private_control_service",
            "private_application_commands",
            "scope_rule",
        }
        and set(kind_counts)
        == {
            "base",
            "additive_external",
            "private_identity_api",
            "external_final",
            "all_scope_http",
        }
        and set(kind_counts.get("base", {}))
        == {"query", "command", "non_get"}
        and set(kind_counts.get("additive_external", {}))
        == {"query", "command", "non_get"}
        and set(kind_counts.get("private_identity_api", {}))
        == {"query", "command", "non_get"}
        and set(kind_counts.get("external_final", {}))
        == {"query", "command", "non_get", "total"}
        and set(kind_counts.get("all_scope_http", {}))
        == {"query", "command", "non_get", "total"}
        and nonempty(additive_counts.get("partition_contract"))
        and nonempty(private_counts.get("scope_rule"))
        and all_derived_markers(base_counts)
        and all_derived_markers(additive_derived)
        and all_derived_markers(final_counts)
        and all_derived_markers(private_derived)
        and all_derived_markers(kind_counts),
        "owner operation count contract must contain only the complete source-derived API/kind fields",
    )
    result.require(
        additive_counts
        == {
            "operation_ids": "derived set(additive_operations[*].operation_id)",
            "external_operation_ids": "derived set(additive_operations operation IDs where api in [public-api, submission-api, control-api, identity-provider])",
            "private_identity_api_operation_ids": "derived set(operation_counts.private_identity_api_operation_ids)",
            "public": "derived count(additive_operations where api=public-api and operation_id in additive.external_operation_ids)",
            "submission": "derived count(additive_operations where api=submission-api and operation_id in additive.external_operation_ids)",
            "control": "derived count(additive_operations where api=control-api and operation_id in additive.external_operation_ids)",
            "browser_identity": "derived count(additive_operations where api=identity-provider and operation_id in additive.external_operation_ids)",
            "external_total": "derived cardinality(additive.external_operation_ids)",
            "private_identity_api": "derived cardinality(additive.private_identity_api_operation_ids)",
            "all_scope_http_total": "derived cardinality(additive.operation_ids)",
            "partition_contract": "additive.operation_ids is set-equal to the disjoint union of additive.external_operation_ids and additive.private_identity_api_operation_ids; the selected supplier operations are not browser identity flows",
        },
        "owner additive operation count fields must be source-derived by API",
    )
    result.require(
        kind_counts.get("additive_external")
        == {
            "query": "derived count(additive_operations where operation_id in additive.external_operation_ids and kind=QUERY)",
            "command": "derived count(additive_operations where operation_id in additive.external_operation_ids and kind=COMMAND)",
            "non_get": "derived count(additive_operations where operation_id in additive.external_operation_ids and method is not GET)",
        }
        and kind_counts.get("private_identity_api")
        == {
            "query": "derived count(additive_operations where operation_id in additive.private_identity_api_operation_ids and kind=QUERY)",
            "command": "derived count(additive_operations where operation_id in additive.private_identity_api_operation_ids and kind=COMMAND)",
            "non_get": "derived count(additive_operations where operation_id in additive.private_identity_api_operation_ids and method is not GET)",
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
