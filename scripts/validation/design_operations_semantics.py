from __future__ import annotations

from typing import Any

from .design_operations_facts import OwnerOperationFacts, PrivateOperationFacts
from .design_operations_journeys import validate_journey_operations
from .design_operations_payments import validate_payment_source_contracts
from .design_support import DesignDocuments, state_tokens
from .loaders import load_yaml


ECONOMICS_VARIANTS = (
    "recordCommercialQualification",
    "importCostAllocationClose",
    "createTariffVersion",
    "recordCommercialContractPeriod",
    "recordUsageWindow",
    "recordInvoice",
    "recordRevenue",
    "recordAccountingCorrection",
    "recordCashApplication",
    "recordTaxInvoiceIssuance",
    "recordCollectionFailure",
)
ECONOMICS_EFFECTS = (
    "RECORDED",
    "REPLACED",
    "REVERSED",
    "REVIEW_TASK_CREATED",
)
ECONOMICS_BRANCH_FIELDS = (
    "target_relations",
    "atomic_cardinality",
    "allowed_result_effects",
)
ECONOMICS_TERMINALS = (
    "SUCCEEDED",
    "OPERATION_REJECTED",
    "PERMANENT_FAILED",
)
ECONOMICS_TERMINAL_STATES = {
    "SUCCEEDED": "SUCCEEDED",
    "OPERATION_REJECTED": "PERMANENT_FAILED",
    "PERMANENT_FAILED": "PERMANENT_FAILED",
}
ECONOMICS_REGISTRY_POINTER = (
    "specs/product/addendum-operation-contracts.yaml"
    "#economics_import_effect_disposition_registry"
)


def _economics_database_variants(
    documents: DesignDocuments,
) -> tuple[list[Any], dict[str, dict[str, Any]]]:
    database = load_yaml(
        documents.root
        / "specs/database/addendum/0041-r6e-monetization-runtime.yaml"
    )
    raw = database.get("economics_import_runtime_contract", {}).get(
        "variants_in_order", []
    )
    rows = raw if isinstance(raw, list) else []
    variants = {
        row.get("operation_id"): {
            field: row.get(field) for field in ECONOMICS_BRANCH_FIELDS
        }
        for row in rows
        if isinstance(row, dict) and isinstance(row.get("operation_id"), str)
    }
    return rows, variants


def _validate_economics_effect_registry(documents: DesignDocuments) -> None:
    result = documents.result
    canonical = documents.operation_contracts.get(
        "economics_import_effect_disposition_registry", {}
    )
    variants = canonical.get("variants", {}) if isinstance(canonical, dict) else {}
    rows = [row for row in variants.values() if isinstance(row, dict)]
    database_rows, database_variants = _economics_database_variants(documents)
    effects = set().union(
        *(set(row.get("allowed_result_effects", [])) for row in rows), set()
    )
    result.require(
        canonical.get("key") == "operationId"
        and tuple(canonical.get("dispositions_exactly", [])) == ECONOMICS_EFFECTS
        and tuple(variants) == ECONOMICS_VARIANTS
        and len(rows) == len(variants)
        and all(
            set(row) == set(ECONOMICS_BRANCH_FIELDS)
            and isinstance(row.get("target_relations"), list)
            and len(row["target_relations"]) == len(set(row["target_relations"])) > 0
            and isinstance(row.get("atomic_cardinality"), str)
            and bool(row["atomic_cardinality"].strip())
            and isinstance(row.get("allowed_result_effects"), list)
            and len(row["allowed_result_effects"])
            == len(set(row["allowed_result_effects"]))
            > 0
            and set(row["allowed_result_effects"]) <= set(ECONOMICS_EFFECTS)
            for row in rows
        )
        and effects == set(ECONOMICS_EFFECTS),
        "economics import effect registry is not the exact eleven-branch four-effect registry",
    )
    result.require(
        len(database_rows) == len(database_variants) == 11
        and tuple(
            row.get("operation_id") if isinstance(row, dict) else None
            for row in database_rows
        )
        == ECONOMICS_VARIANTS
        and all(
            isinstance(row, dict)
            and set(row) == {"operation_id", *ECONOMICS_BRANCH_FIELDS}
            for row in database_rows
        )
        and database_variants == variants,
        "0041 database economics variants differ from the canonical effect registry",
    )
    persistence = documents.persistence_contracts["exact_persistence_registry"]
    command = documents.command_semantics["private_application_commands"][
        "private.ExecuteEconomicsImport"
    ]
    approval = documents.approval_policy["economics_import_effect_disposition_contract"]
    result.require(
        persistence.get("economics_import_effect_disposition_registry") == canonical
        and command.get("effect_disposition_registry") == ECONOMICS_REGISTRY_POINTER
        and command.get("branch_contracts") == variants
        and approval.get("canonical_registry") == ECONOMICS_REGISTRY_POINTER
        and approval.get("key") == "operationId"
        and approval.get("mirrored_fields") == list(ECONOMICS_BRANCH_FIELDS),
        "economics operation, approval, command and persistence effect registries differ",
    )


def _validate_economics_terminal_contract(documents: DesignDocuments) -> None:
    result = documents.result
    canonical = documents.operation_contracts.get(
        "economics_import_terminal_contract", {}
    )
    persistence = documents.persistence_contracts["exact_persistence_registry"]
    command = documents.command_semantics["private_application_commands"][
        "private.ExecuteEconomicsImport"
    ]
    approval = documents.approval_policy["private_application_command_authorization"][
        "private.ExecuteEconomicsImport"
    ]
    receipt = documents.resource_error_contracts["schemas"].get(
        "EconomicsImportExecutionReceiptV1", {}
    )
    expected_command = {
        "owner_dispositions_exactly": list(ECONOMICS_TERMINALS),
        "receipt_field": "terminalKind",
        "action_execution_state_selector": ECONOMICS_TERMINAL_STATES,
        "worker_job_success_only": "SUCCEEDED",
        "operation_rejected": "nested branch apply rollback followed by one redacted non-retryable business or constraint rejection terminalization",
        "commit_ack_ambiguity": "no terminal receipt or state; same claim, idempotency identity and fence recalls committed replay or executes only the uncommitted transaction",
        "forbidden": [
            "RECONCILIATION_REQUIRED economics receipt",
            "reconciliation economics state",
            "external send",
            "automatic resubmission",
            "new idempotency identity",
        ],
    }
    result.require(
        tuple(canonical.get("owner_dispositions_exactly", []))
        == ECONOMICS_TERMINALS
        and canonical.get("receipt_field") == "terminalKind"
        and canonical.get("generic_action_execution_state_selector")
        == ECONOMICS_TERMINAL_STATES
        and persistence.get("economics_import_terminal_contract") == canonical
        and command.get("terminal_contract") == expected_command
        and approval.get("terminal_contract")
        == {
            "owner_dispositions": list(ECONOMICS_TERMINALS),
            "generic_action_execution_state": ECONOMICS_TERMINAL_STATES,
            "worker_job_success_only": "SUCCEEDED",
        }
        and receipt.get("kind") == "object"
        and receipt.get("additional_properties") is False
        and receipt.get("fields", {}).get("terminalKind")
        == "enum<SUCCEEDED|OPERATION_REJECTED|PERMANENT_FAILED>"
        and "state" not in receipt.get("fields", {}),
        "economics terminalKind operation, receipt, approval, command and persistence contracts differ",
    )


def _validate_economics_action_edge(documents: DesignDocuments) -> None:
    result = documents.result
    machines = documents.state_machines.get("machines", {})
    edges = [
        (name, machine, edge)
        for name, machine in machines.items()
        for edge in machine.get("edges", [])
        if edge.get("private_command") == "private.ExecuteEconomicsImport"
    ]
    edge = edges[0][2] if len(edges) == 1 else {}
    result.require(
        len(edges) == 1
        and edges[0][0] == "action_execution"
        and edge.get("from") == "RUNNING"
        and edge.get("to") == "SUCCEEDED|PERMANENT_FAILED"
        and edge.get("selector") == "action-kind-ECONOMICS_IMPORT"
        and edge.get("owner_terminal_mapping") == ECONOMICS_TERMINAL_STATES
        and set(edge["owner_terminal_mapping"].values()) == state_tokens(edge["to"])
        and edge.get("event") == "action.execution_completed.v1"
        and state_tokens(edge["to"]) <= set(edges[0][1].get("terminal", []))
        and all("economics_import" not in name.lower() for name in machines)
        and all(
            "UNRECORDED" not in state_tokens(machine.get(field))
            for machine in machines.values()
            for field in ("states", "legal_states", "terminal")
        ),
        "private.ExecuteEconomicsImport must use one exact existing action_execution edge and no pseudo-machine",
    )


def validate_economics_import_closure(documents: DesignDocuments) -> None:
    _validate_economics_effect_registry(documents)
    _validate_economics_terminal_contract(documents)
    _validate_economics_action_edge(documents)


def _validate_external_command_registries(
    documents: DesignDocuments, owner: OwnerOperationFacts
) -> None:
    result = documents.result
    persistence_registry = documents.persistence_contracts.get(
        "exact_persistence_registry", {}
    )
    owner_external_command_ids = {
        operation_id
        for operation_id, operation in owner.owner_operation_by_id.items()
        if operation.get("kind") == "COMMAND"
    }
    result.require(
        set(documents.command_semantics.get("external_commands", {}))
        == owner_external_command_ids,
        "external command semantics are not set-equal to owner command operations",
    )
    result.require(
        set(persistence_registry.get("external_command_persistence", {}))
        == owner_external_command_ids,
        "detailed external command persistence is not set-equal to owner command operations",
    )


def _validate_private_application_and_control(
    documents: DesignDocuments, private: PrivateOperationFacts
) -> None:
    result = documents.result
    operations = documents.operation_contracts
    resources = documents.resource_error_contracts
    semantics = documents.command_semantics
    states = documents.state_machines
    persistence = documents.persistence_contracts["exact_persistence_registry"]
    application_sets = {
        "operation": set(operations.get("private_application_commands", {})),
        "resource_binding": set(
            resources.get("private_application_command_bindings", {})
        ),
        "resource_request": set(
            resources.get("private_application_request_schemas", {})
        ),
        "resource_error": set(
            resources.get("private_application_error_sets", {})
        ),
        "command": set(semantics.get("private_application_commands", {})),
        "state": set(
            states.get("private_application_lifecycle_bindings", {}).get(
                "current_bindings", {}
            )
        ),
        "persistence": set(
            persistence.get("private_application_command_persistence", {})
        ),
    }
    result.require(
        all(
            registry == private.private_application_ids
            for registry in application_sets.values()
        ),
        "private application operation/resource/command/state/persistence registries are not exact",
    )
    control_sets = {
        "operation": set(
            operations.get("private_control_service_operations", {})
        ),
        "command": set(semantics.get("private_control_service_commands", {})),
        "state": set(
            states.get("private_control_lifecycle_bindings", {}).get(
                "current_bindings", {}
            )
        ),
        "persistence": set(persistence.get("private_control_service_persistence", {})),
    }
    result.require(
        all(registry == private.private_control_ids for registry in control_sets.values()),
        "private control operation/command/state/persistence registries are not exact",
    )


def _validate_private_billing(
    documents: DesignDocuments, private: PrivateOperationFacts
) -> None:
    result = documents.result
    operations = documents.operation_contracts
    resources = documents.resource_error_contracts
    semantics = documents.command_semantics
    persistence = documents.persistence_contracts["exact_persistence_registry"]
    registry_sets = {
        "operation": set(
            operations.get("private_billing_gateway_operations", {})
        ),
        "resource_binding": set(
            resources.get("private_billing_gateway_operation_bindings", {})
        ),
        "resource_request": set(
            resources.get("private_billing_gateway_request_schemas", {})
        ),
        "resource_error": set(
            resources.get("private_billing_gateway_error_sets", {})
        ),
        "command": set(semantics.get("private_billing_gateway_operations", {})),
        "persistence": set(persistence.get("private_billing_gateway_persistence", {})),
    }
    result.require(
        all(registry == private.private_billing_ids for registry in registry_sets.values()),
        "private billing operation/resource/command/persistence registries are not exact",
    )
    lifecycle = documents.state_machines.get(
        "private_billing_gateway_lifecycle_bindings", {}
    )
    queries = lifecycle.get("query_dispositions", {})
    commands = lifecycle.get("current_bindings", {})
    result.require(
        set(queries) == private.private_billing_query_ids
        and all(value == "NON_STATE_QUERY" for value in queries.values())
        and set(commands) == private.private_billing_command_ids,
        "private billing query dispositions and command lifecycle bindings are not exact",
    )


def validate_operation_semantics(
    documents: DesignDocuments,
    owner: OwnerOperationFacts,
    private: PrivateOperationFacts,
) -> None:
    validate_journey_operations(documents)
    _validate_external_command_registries(documents, owner)
    _validate_private_application_and_control(documents, private)
    _validate_private_billing(documents, private)
    validate_economics_import_closure(documents)
    validate_payment_source_contracts(documents)
    kill_switch_fields = documents.operation_contracts["action_payloads"]["variants"][
        "KILL_SWITCH"
    ]["required"]
    documents.result.require(
        "switchTarget" in kill_switch_fields
        and "switchEffect" in kill_switch_fields
        and "target" not in kill_switch_fields
        and "effect" not in kill_switch_fields,
        "KILL_SWITCH variant collides with common ActionPayloadV1 fields",
    )
