from __future__ import annotations

from .design_operations_facts import OwnerOperationFacts, PrivateOperationFacts
from .design_support import (
    DesignDocuments,
    collect_versioned_refs,
    keyed_registry,
    nonempty,
)


def validate_private_and_resources(
    documents: DesignDocuments,
    owner: OwnerOperationFacts,
) -> PrivateOperationFacts:
    result = documents.result
    addendum = documents.addendum
    operation_contracts = documents.operation_contracts
    resource_error_contracts = documents.resource_error_contracts
    base_error_catalog = documents.base_error_catalog
    counts = owner.counts
    owner_operation_ids = owner.owner_operation_ids
    base_operation_ids = owner.base_operation_ids
    contracted_operations = owner.contracted_operations
    private_callback_operations, private_callback_by_id = keyed_registry(
        addendum["private_communication_gateway_operations"],
        "operation_id",
        result,
        "private communication gateway operation registry",
    )
    private_callback_ids = set(private_callback_by_id)
    private_callback_transport_keys = [
        (operation.get("method"), operation.get("path"))
        for operation in private_callback_operations
    ]
    result.require(
        all(
            operation.get("kind") in {"QUERY", "COMMAND"}
            and nonempty(operation.get("method"))
            and nonempty(operation.get("path"))
            for operation in private_callback_operations
        )
        and len(private_callback_transport_keys)
        == len(set(private_callback_transport_keys))
        and not (private_callback_ids & owner_operation_ids)
        and not (private_callback_ids & base_operation_ids),
        "private communication gateway operation registry is duplicated, incomplete or colliding",
    )
    private_billing_operations, private_billing_by_id = keyed_registry(
        addendum.get("private_billing_gateway_operations", []),
        "operation_id",
        result,
        "private billing gateway operation registry",
    )
    private_billing_ids = set(private_billing_by_id)
    private_billing_command_ids = {
        operation["operation_id"]
        for operation in private_billing_operations
        if operation.get("kind") == "COMMAND"
    }
    private_billing_query_ids = private_billing_ids - private_billing_command_ids
    expected_private_billing_ids = {
        "private.GetDonationFixtureOffer",
        "private.QueueDonationIntent",
        "private.ReceivePaymentWebhook",
    }
    private_billing_transport_keys = [
        (operation.get("method"), operation.get("path"))
        for operation in private_billing_operations
    ]
    result.require(
        all(
            operation.get("kind") in {"QUERY", "COMMAND"}
            and nonempty(operation.get("method"))
            and nonempty(operation.get("path"))
            and nonempty(operation.get("caller"))
            and operation.get("runtime_mode") == "TEST_MODE_ONLY"
            for operation in private_billing_operations
        )
        and len(private_billing_transport_keys)
        == len(set(private_billing_transport_keys))
        and private_billing_ids == expected_private_billing_ids
        and private_billing_query_ids
        == {"private.GetDonationFixtureOffer"}
        and private_billing_command_ids
        == {
            "private.QueueDonationIntent",
            "private.ReceivePaymentWebhook",
        }
        and not (
            private_billing_ids
            & (owner_operation_ids | base_operation_ids | private_callback_ids)
        ),
        "private billing gateway operation registry is duplicated, incomplete, live-enabled or colliding",
    )
    private_application = addendum.get("private_application_commands", {})
    private_control_operations, private_control_by_id = keyed_registry(
        addendum.get("private_control_service_operations", []),
        "operation_id",
        result,
        "private control service operation registry",
    )
    private_control_ids = set(private_control_by_id)
    private_control_transport_keys = [
        (operation.get("method"), operation.get("path"))
        for operation in private_control_operations
    ]
    result.require(
        all(
            operation.get("kind") in {"QUERY", "COMMAND"}
            and operation.get("api") == "control-api-private"
            and nonempty(operation.get("method"))
            and nonempty(operation.get("path"))
            and nonempty(operation.get("caller"))
            for operation in private_control_operations
        )
        and len(private_control_transport_keys) == len(set(private_control_transport_keys))
        and not (
            private_control_ids
            & (
                owner_operation_ids
                | base_operation_ids
                | private_callback_ids
                | private_billing_ids
            )
        ),
        "private control service operation registry is duplicated, incomplete or colliding",
    )
    private_application_operations, private_application_by_id = keyed_registry(
        private_application.get("commands", []),
        "operation_id",
        result,
        "private application command registry",
    )
    private_application_ids = set(private_application_by_id)
    result.require(
        private_application.get("count") == "derived len(commands)"
        and all(
            operation.get("kind") == "COMMAND"
            and operation.get("transport") == "PRIVATE_APPLICATION_COMMAND"
            and nonempty(operation.get("owner"))
            for operation in private_application_operations
        )
        and not (
            private_application_ids
            & (
                owner_operation_ids
                | base_operation_ids
                | private_callback_ids
                | private_billing_ids
                | private_control_ids
            )
        ),
        "private application command registry is not source-derived, closed or disjoint",
    )
    private_counts = counts.get("separate_private_inventories", {})
    result.require(
        private_counts.get("private_communication_gateway")
        == "derived len(private_communication_gateway_operations)"
        and private_counts.get("private_billing_gateway")
        == "derived len(private_billing_gateway_operations)"
        and private_counts.get("private_control_service")
        == "derived len(private_control_service_operations)"
        and private_counts.get("private_application_commands")
        == "derived len(private_application_commands.commands)",
        "owner private operation count fields must be source-derived",
    )
    effective_additive_http_ids = (
        owner_operation_ids | private_callback_ids | private_control_ids
    )
    resource_bindings = resource_error_contracts["operation_bindings"]
    request_schemas = resource_error_contracts["request_schemas_by_operation"]
    operation_error_sets = resource_error_contracts["operation_error_sets"]
    external_operation_ids = {
        operation["operation_id"]
        for operation in contracted_operations
        if operation.get("api") != "identity-api"
    }
    private_identity_operation_ids = owner_operation_ids - external_operation_ids
    expected_private_identity_operation_ids = {
        "recordSupplierIdentityResolution",
        "recordSupplierRelationshipAssertion",
        "decideSupplierRelationshipAssertion",
    }
    declared_sets = resource_error_contracts.get("set_equality", {})
    resource_scope_ids = {
        scope: {
            operation_id
            for operation_id, binding in resource_bindings.items()
            if binding.get("scope") == scope
        }
        for scope in (
            "ADDITIVE_EXTERNAL",
            "PRIVATE_IDENTITY_API",
            "PRIVATE_COMMUNICATION",
            "PRIVATE_CONTROL",
        )
    }
    resource_partitions = [
        external_operation_ids,
        private_identity_operation_ids,
        private_callback_ids,
        private_control_ids,
    ]
    result.require(
        resource_error_contracts["status"] in {"REVIEW_REQUIRED", "FINAL"}
        and set(resource_bindings)
        == set(request_schemas)
        == set(operation_error_sets)
        == effective_additive_http_ids
        and len(owner_operation_ids) == 54
        and len(external_operation_ids) == 51
        and private_identity_operation_ids
        == expected_private_identity_operation_ids
        and external_operation_ids | private_identity_operation_ids
        == owner_operation_ids
        and all(
            left.isdisjoint(right)
            for index, left in enumerate(resource_partitions)
            for right in resource_partitions[index + 1 :]
        )
        and set(declared_sets.get("additive_external_operation_ids", []))
        == resource_scope_ids["ADDITIVE_EXTERNAL"]
        == external_operation_ids
        and set(declared_sets.get("private_identity_api_operation_ids", []))
        == resource_scope_ids["PRIVATE_IDENTITY_API"]
        == private_identity_operation_ids
        and set(declared_sets.get("private_communication_operation_ids", []))
        == resource_scope_ids["PRIVATE_COMMUNICATION"]
        == private_callback_ids
        and set(declared_sets.get("private_control_service_operation_ids", []))
        == resource_scope_ids["PRIVATE_CONTROL"]
        == private_control_ids
        and owner_operation_ids.isdisjoint(private_callback_ids),
        "additive resource/error operation sets are not exact",
    )
    private_billing_bindings = resource_error_contracts.get(
        "private_billing_gateway_operation_bindings", {}
    )
    private_billing_request_schemas = resource_error_contracts.get(
        "private_billing_gateway_request_schemas", {}
    )
    private_billing_error_sets = resource_error_contracts.get(
        "private_billing_gateway_error_sets", {}
    )
    result.require(
        set(private_billing_bindings)
        == set(private_billing_request_schemas)
        == set(private_billing_error_sets)
        == private_billing_ids,
        "private billing resource/error operation sets are not exact",
    )
    for operation_id in sorted(private_billing_ids):
        owner_operation = private_billing_by_id[operation_id]
        binding = private_billing_bindings.get(operation_id, {})
        request_schema = private_billing_request_schemas.get(operation_id, {})
        result.require(
            binding.get("scope") == "PRIVATE_BILLING_GATEWAY"
            and binding.get("operation_kind") == owner_operation.get("kind")
            and binding.get("request_schema") == request_schema.get("name")
            and nonempty(binding.get("success_schema")),
            f"{operation_id}: private billing resource binding drifted from its owner operation",
        )
    for operation in contracted_operations:
        operation_id = operation["operation_id"]
        if not all(
            operation_id in registry
            for registry in (resource_bindings, request_schemas, operation_error_sets)
        ):
            continue
        binding = resource_bindings[operation_id]
        expected_scope = (
            "PRIVATE_IDENTITY_API"
            if operation_id in private_identity_operation_ids
            else "ADDITIVE_EXTERNAL"
        )
        result.require(
            binding["scope"] == expected_scope
            and binding["request_schema"] == request_schemas[operation_id]["name"]
            and binding["success_schema"] == operation["response"]
            and operation_error_sets[operation_id] == operation["errors"],
            f"{operation_id}: resource/error binding drifted from the operation contract",
        )
    schema_registry = resource_error_contracts["schemas"]
    request_schema_names = {
        schema["name"]
        for schema in (
            list(request_schemas.values())
            + list(private_billing_request_schemas.values())
        )
    }
    success_schema_names = {
        binding["success_schema"] for binding in resource_bindings.values()
    } | {
        binding["success_schema"] for binding in private_billing_bindings.values()
    }
    result.require(
        bool(schema_registry)
        and len(request_schema_names)
        == len(request_schemas) + len(private_billing_request_schemas)
        and success_schema_names <= set(schema_registry),
        "additive resource schema registries are empty, duplicated or have dangling success references",
    )
    reachable_versioned = collect_versioned_refs(
        {
            "bindings": resource_bindings,
            "requests": request_schemas,
            "private_billing_bindings": private_billing_bindings,
            "private_billing_requests": private_billing_request_schemas,
            "schemas": schema_registry,
            "rfc9457": resource_error_contracts["rfc9457_contract"],
        }
    )
    versioned_definitions = set(schema_registry) | request_schema_names
    result.require(
        reachable_versioned == versioned_definitions,
        "additive versioned schema references are dangling or unreachable",
    )
    base_error_code_rows = [error["code"] for error in base_error_catalog["errors"]]
    base_error_codes = set(base_error_code_rows)
    additive_error_rows = resource_error_contracts["error_catalog_additions"]
    additive_error_codes = set(additive_error_rows)
    effective_error_codes = base_error_codes | additive_error_codes
    result.require(
        len(base_error_code_rows) == len(base_error_codes)
        and bool(additive_error_codes)
        and not (base_error_codes & additive_error_codes)
        and all(
            set(error_codes) <= effective_error_codes
            for error_codes in (
                list(operation_error_sets.values())
                + list(private_billing_error_sets.values())
            )
        ),
        "effective error catalog is duplicated, overlapping or does not close every additive operation",
    )
    for code, row in additive_error_rows.items():
        result.require(
            row["layer"] in set(base_error_catalog["layers"])
            and isinstance(row["http_status"], int)
            and nonempty(row["title"])
            and isinstance(row["retryable"], bool)
            and row["exposure"] in {"safe", "redacted", "request-id-only"}
            and row["state_effect"] == "UNCHANGED"
            and isinstance(row["allowed_extensions"], list),
            f"{code}: additive error contract is incomplete",
        )

    return PrivateOperationFacts(
        private_callback_ids=private_callback_ids,
        private_billing_ids=private_billing_ids,
        private_billing_command_ids=private_billing_command_ids,
        private_billing_query_ids=private_billing_query_ids,
        private_control_ids=private_control_ids,
        private_application_ids=private_application_ids,
    )
