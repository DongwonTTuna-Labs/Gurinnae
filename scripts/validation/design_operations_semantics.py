from __future__ import annotations

from .design_operations_facts import OwnerOperationFacts, PrivateOperationFacts
from .design_operations_journeys import validate_journey_operations
from .design_support import DesignDocuments


def validate_operation_semantics(
    documents: DesignDocuments,
    owner: OwnerOperationFacts,
    private: PrivateOperationFacts,
) -> None:
    result = documents.result
    operation_contracts = documents.operation_contracts
    resource_error_contracts = documents.resource_error_contracts
    owner_operation_by_id = owner.owner_operation_by_id
    private_application_ids = private.private_application_ids
    private_control_ids = private.private_control_ids
    command_semantics = documents.command_semantics
    persistence_registry = documents.persistence_contracts.get(
        "exact_persistence_registry", {}
    )
    state_machines = documents.state_machines
    validate_journey_operations(documents)
    owner_external_command_ids = {
        operation_id
        for operation_id, operation in owner_operation_by_id.items()
        if operation.get("kind") == "COMMAND"
    }
    result.require(
        set(command_semantics.get("external_commands", {}))
        == owner_external_command_ids,
        "external command semantics are not set-equal to owner command operations",
    )
    result.require(
        set(persistence_registry.get("external_command_persistence", {}))
        == owner_external_command_ids,
        "detailed external command persistence is not set-equal to owner command operations",
    )

    private_application_registry_sets = {
        "operation": set(operation_contracts.get("private_application_commands", {})),
        "resource_binding": set(
            resource_error_contracts.get("private_application_command_bindings", {})
        ),
        "resource_request": set(
            resource_error_contracts.get("private_application_request_schemas", {})
        ),
        "resource_error": set(
            resource_error_contracts.get("private_application_error_sets", {})
        ),
        "command": set(command_semantics.get("private_application_commands", {})),
        "state": set(
            state_machines.get("private_application_lifecycle_bindings", {}).get(
                "current_bindings", {}
            )
        ),
        "persistence": set(
            persistence_registry.get("private_application_command_persistence", {})
        ),
    }
    result.require(
        all(
            registry == private_application_ids
            for registry in private_application_registry_sets.values()
        ),
        "private application operation/resource/command/state/persistence registries are not exact",
    )

    private_control_registry_sets = {
        "operation": set(
            operation_contracts.get("private_control_service_operations", {})
        ),
        "command": set(
            command_semantics.get("private_control_service_commands", {})
        ),
        "state": set(
            state_machines.get("private_control_lifecycle_bindings", {}).get(
                "current_bindings", {}
            )
        ),
        "persistence": set(
            persistence_registry.get("private_control_service_persistence", {})
        ),
    }
    result.require(
        all(
            registry == private_control_ids
            for registry in private_control_registry_sets.values()
        ),
        "private control operation/command/state/persistence registries are not exact",
    )
    kill_switch_fields = operation_contracts["action_payloads"]["variants"][
        "KILL_SWITCH"
    ]["required"]
    result.require(
        "switchTarget" in kill_switch_fields
        and "switchEffect" in kill_switch_fields
        and "target" not in kill_switch_fields
        and "effect" not in kill_switch_fields,
        "KILL_SWITCH variant collides with common ActionPayloadV1 fields",
    )
