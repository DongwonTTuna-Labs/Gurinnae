from __future__ import annotations

from typing import Any

from .design_support import DesignDocuments


def validate_provider_control_contracts(
    documents: DesignDocuments,
) -> dict[str, dict[str, Any]]:
    result = documents.result
    operation_contracts = documents.operation_contracts
    event_contracts = documents.event_contracts
    provider_operation_policies = {
        "disableProviderRouting": {
            "capability": "kill_switch.execute",
            "assurance": "STEP_UP",
            "roles": {"OPERATIONS", "SECURITY_ADMIN", "EXECUTIVE_APPROVER"},
        },
        "testProviderConnection": {
            "capability": "jobs.operate",
            "assurance": "ACTIVE_SESSION",
            "roles": {"OPERATIONS"},
        },
        "upgradeProviderModel": {
            "capability": "kill_switch.execute",
            "assurance": "STEP_UP",
            "roles": {"OPERATIONS", "SECURITY_ADMIN", "EXECUTIVE_APPROVER"},
        },
        "setModelAutoUpgrade": {
            "capability": "kill_switch.execute",
            "assurance": "STEP_UP",
            "roles": {"OPERATIONS", "SECURITY_ADMIN", "EXECUTIVE_APPROVER"},
        },
    }
    provider_operation_ids = set(provider_operation_policies)
    side_door = operation_contracts.get("provider_control_http_side_door", {})
    side_door_direct = side_door.get("direct_http", {})
    side_door_errors = documents.resource_error_contracts.get(
        "provider_control_http_side_door_error_sets", {}
    )
    side_door_semantics = documents.command_semantics.get(
        "provider_control_http_side_door_semantics", {}
    )
    side_door_error_contract = documents.resource_error_contracts.get(
        "error_catalog_additions", {}
    ).get("ACTION_PROPOSAL_REQUIRED", {})
    result.require(
        len(side_door.get("operation_ids", [])) == len(provider_operation_ids)
        and set(side_door.get("operation_ids", [])) == provider_operation_ids
        and side_door_direct
        == {
            "status": 409,
            "error_code": "ACTION_PROPOSAL_REQUIRED",
            "state_effect": "UNCHANGED",
            "transaction": "NONE",
            "writes": [],
            "outbox_events": [],
            "external_effects": [],
        }
        and {
            operation_id: side_door_errors.get(operation_id)
            for operation_id in provider_operation_ids
        }
        == {
            operation_id: ["ACTION_PROPOSAL_REQUIRED"]
            for operation_id in provider_operation_ids
        }
        and set(side_door_errors) == provider_operation_ids | {"invariants"}
        and len(side_door_semantics.get("operation_ids", []))
        == len(provider_operation_ids)
        and set(side_door_semantics.get("operation_ids", []))
        == provider_operation_ids
        and side_door_semantics.get("direct_http_result")
        == {
            "status": 409,
            "error_code": "ACTION_PROPOSAL_REQUIRED",
            "state_effect": "UNCHANGED",
        }
        and set(side_door_semantics.get("forbidden_paths", []))
        == {
            "browser_to_control_command_effect",
            "bff_to_control_command_effect",
            "control_api_to_relay",
            "workflow_worker_provider_control_executor",
        }
        and side_door_error_contract
        == {
            "layer": "DOMAIN",
            "http_status": 409,
            "title": "이 공급자 제어는 행동 제안과 승인을 거쳐야 합니다",
            "retryable": False,
            "exposure": "safe",
            "state_source": "NONE",
            "state_effect": "UNCHANGED",
            "allowed_extensions": [],
        },
        "provider control direct HTTP side door is not closed by one exact 409 no-effect contract",
    )
    execution_authorized = event_contracts.get("events", {}).get(
        "action.execution_authorized.v1", {}
    )
    execution_consumers = {
        binding.get("consumer"): binding
        for binding in execution_authorized.get("consumer_bindings", [])
    }
    workflow_binding = execution_consumers.get("action-execution-worker", {})
    provider_binding = execution_consumers.get(
        "provider-control-execution-worker", {}
    )
    provider_component = event_contracts.get("logical_component_bindings", {}).get(
        "provider-control-execution-worker", {}
    )
    result.require(
        set(execution_authorized.get("consumers", []))
        == {
            "action-execution-worker",
            "provider-control-execution-worker",
            "audit-indexer",
        }
        and set(execution_consumers)
        == set(execution_authorized.get("consumers", []))
        and workflow_binding.get("physical_service") == "workflow-worker"
        and workflow_binding.get("module") == "action_execution"
        and workflow_binding.get("dispatch_predicate")
        == "payload.actionKind != PROVIDER_CONTROL"
        and provider_binding.get("physical_service") == "analysis-worker"
        and provider_binding.get("module") == "provider_control"
        and provider_binding.get("dispatch_predicate")
        == "payload.actionKind == PROVIDER_CONTROL"
        and provider_component
        == {
            "physical_service": "analysis-worker",
            "module": "provider_control",
        },
        "action.execution_authorized.v1 does not route PROVIDER_CONTROL only to analysis-worker while preserving every other kind on workflow-worker",
    )
    resource_schemas = documents.resource_error_contracts.get("schemas", {})
    provider_operation_id_schema = resource_schemas.get(
        "ProviderControlOperationIdV1", {}
    )
    provider_action_schema = resource_schemas.get("ProviderControlActionV1", {})
    provider_action_variants = provider_action_schema.get("variants", {})
    provider_action_fields = {
        "disableProviderRouting": {
            "operationId",
            "providerId",
            "reason",
            "expectedVersion",
        },
        "testProviderConnection": {
            "operationId",
            "providerId",
            "testModel",
            "reason",
            "expectedVersion",
        },
        "upgradeProviderModel": {
            "operationId",
            "providerId",
            "modelId",
            "expectedVersion",
            "reason",
            "dataPolicy",
        },
        "setModelAutoUpgrade": {
            "operationId",
            "providerId",
            "expectedVersion",
            "enabled",
            "track",
            "reason",
        },
    }
    provider_action_required = {
        "disableProviderRouting": {
            "operationId",
            "providerId",
            "reason",
            "expectedVersion",
        },
        "testProviderConnection": {
            "operationId",
            "providerId",
            "testModel",
            "expectedVersion",
        },
        "upgradeProviderModel": {
            "operationId",
            "providerId",
            "modelId",
            "expectedVersion",
            "reason",
        },
        "setModelAutoUpgrade": {
            "operationId",
            "providerId",
            "expectedVersion",
            "enabled",
            "reason",
        },
    }
    result.require(
        provider_operation_id_schema.get("kind") == "enum"
        and set(provider_operation_id_schema.get("values", []))
        == provider_operation_ids
        and provider_action_schema.get("kind") == "discriminated_union"
        and provider_action_schema.get("discriminator") == "operationId"
        and set(provider_action_variants) == provider_operation_ids,
        "provider control operation discriminator is not the exact closed four-operation set",
    )
    for operation_id in sorted(provider_operation_ids):
        branch = provider_action_variants.get(operation_id, {})
        result.require(
            branch.get("additional_properties") is False
            and set(branch.get("fields", {}))
            == provider_action_fields[operation_id]
            and set(branch.get("required", []))
            == provider_action_required[operation_id]
            and branch.get("fields", {}).get("operationId")
            == f"const<{operation_id}>",
            f"{operation_id}: provider control request branch is open or field-inexact",
        )
    provider_approval_schema = resource_schemas.get(
        "ProviderControlApprovalDetailV1", {}
    )
    provider_approval_variants = provider_approval_schema.get("variants", {})
    provider_approval_fields = {
        "disableProviderRouting": {
            "operationId",
            "providerId",
            "expectedVersion",
            "reasonDigest",
        },
        "testProviderConnection": {
            "operationId",
            "providerId",
            "expectedVersion",
            "testModel",
            "reasonDigest",
        },
        "upgradeProviderModel": {
            "operationId",
            "providerId",
            "expectedVersion",
            "modelId",
            "reasonDigest",
            "dataPolicyDigest",
        },
        "setModelAutoUpgrade": {
            "operationId",
            "providerId",
            "expectedVersion",
            "enabled",
            "track",
            "reasonDigest",
        },
    }
    provider_approval_required = {
        "disableProviderRouting": provider_approval_fields[
            "disableProviderRouting"
        ],
        "testProviderConnection": provider_approval_fields[
            "testProviderConnection"
        ]
        - {"reasonDigest"},
        "upgradeProviderModel": provider_approval_fields[
            "upgradeProviderModel"
        ]
        - {"dataPolicyDigest"},
        "setModelAutoUpgrade": provider_approval_fields[
            "setModelAutoUpgrade"
        ]
        - {"track"},
    }
    result.require(
        provider_approval_schema.get("kind") == "discriminated_union"
        and provider_approval_schema.get("discriminator") == "operationId"
        and set(provider_approval_variants) == provider_operation_ids,
        "provider control approval detail is not the exact closed four-operation set",
    )
    for operation_id in sorted(provider_operation_ids):
        branch = provider_approval_variants.get(operation_id, {})
        result.require(
            branch.get("additional_properties") is False
            and set(branch.get("fields", {}))
            == provider_approval_fields[operation_id]
            and set(branch.get("required", []))
            == provider_approval_required[operation_id]
            and branch.get("fields", {}).get("operationId")
            == f"const<{operation_id}>",
            f"{operation_id}: provider approval detail is open or field-inexact",
        )
    action_payload_schema = resource_schemas.get("ActionPayloadV1", {})
    action_detail_schema = resource_schemas.get("ActionApprovalDetailV1", {})
    action_detail_view_schema = resource_schemas.get(
        "ActionApprovalDetailViewV1", {}
    )
    provider_target_schema = resource_schemas.get(
        "ProviderControlActionTargetV1", {}
    )
    result.require(
        action_payload_schema.get("variants", {}).get("PROVIDER_CONTROL")
        == {
            "additional_properties": False,
            "fields": {"providerControl": "ProviderControlActionV1"},
        }
        and action_detail_schema.get("variants", {}).get("PROVIDER_CONTROL")
        == {
            "additional_properties": False,
            "fields": {
                "kind": "const<PROVIDER_CONTROL>",
                "providerControl": "ProviderControlApprovalDetailV1",
            },
        }
        and action_detail_view_schema.get("variants", {}).get(
            "PROVIDER_CONTROL"
        )
        == {
            "additional_properties": False,
            "fields": {
                "kind": "const<PROVIDER_CONTROL>",
                "providerControl": "ProviderControlActionV1",
            },
        }
        and provider_target_schema.get("kind") == "closed_specialization"
        and provider_target_schema.get("source") == "ProviderControlActionV1",
        "PROVIDER_CONTROL payload, approval detail, reviewer view or executor target has an open fallback",
    )
    return provider_operation_policies
