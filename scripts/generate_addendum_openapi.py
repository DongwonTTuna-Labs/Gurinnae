#!/usr/bin/env python3
"""Merge the owner-addendum HTTP operations into the generated API specs.

The addendum operation/resource contracts are the only input; this generator
does not invent routes.  Every generated operation has a closed request
schema, an explicit operation-specific response schema name, the service
assertion security binding and the exact error-code list from the resource
contract.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ADDENDUM = ROOT / "specs/product/addendum-operation-contracts.yaml"
RESOURCES = ROOT / "specs/product/addendum-resource-error-contracts.yaml"
COMMAND_SEMANTICS = ROOT / "specs/product/addendum-command-semantics.yaml"
OWNER_ADDENDUM = ROOT / "specs/product/owner-addendum-2026-07-14.yaml"
BASE_OPERATIONS = ROOT / "specs/api/operation-contracts.yaml"
HANDWRITTEN_RESOURCES = ROOT / "specs/api/resource-schemas.yaml"
BASE_ERROR_CATALOG = ROOT / "specs/api/error-code-catalog.yaml"
PROVIDER_CONTROL_OPERATION_IDS = (
    "disableProviderRouting",
    "testProviderConnection",
    "upgradeProviderModel",
    "setModelAutoUpgrade",
)
CONTROL_BASE_SCHEMA_IMPORTS = (
    "LegalHoldTargetBinding",
    "placeLegalHoldRequest",
    "placeLegalHoldReceipt",
)
PUBLIC_BASE_SCHEMA_IMPORTS = (
    "CaseReproducibilityDownloadAppliedFilters",
    "CaseReproducibilityDownload",
)

ADDITIVE_EXTERNAL_APIS = frozenset(
    {"public-api", "control-api", "submission-api"}
)
RESOURCE_OPERATION_PARTITIONS = {
    "additive_external_operation_ids": "ADDITIVE_EXTERNAL",
    "private_identity_api_operation_ids": "PRIVATE_IDENTITY_API",
    "private_communication_operation_ids": "PRIVATE_COMMUNICATION",
    "private_control_service_operation_ids": "PRIVATE_CONTROL",
}
RESOURCE_PRIVATE_OPERATION_PARTITIONS = {
    "private_application_command_ids": (
        "private_application_commands",
        "private_application_command_bindings",
        "private_application_request_schemas",
        "private_application_error_sets",
    ),
    "private_billing_gateway_operation_ids": (
        "private_billing_gateway_operations",
        "private_billing_gateway_operation_bindings",
        "private_billing_gateway_request_schemas",
        "private_billing_gateway_error_sets",
    ),
}
DONATION_CHARGE_OPERATION_ID = "private.ExecuteDonationCharge"
DONATION_QUEUE_OPERATION_ID = "private.QueueDonationIntent"
DONATION_FACT_PRODUCER_OPERATIONS = (
    DONATION_CHARGE_OPERATION_ID,
    "private.ReceivePaymentWebhook",
)
DONATION_CHARGE_PAYLOAD_FIELDS = (
    "schemaVersion",
    "donationScheduleId",
    "donationScheduleVersion",
    "donationScheduleDigest",
    "paymentMethodBindingId",
    "paymentMethodBindingDigest",
    "offerVersionId",
    "offerDigest",
    "tierId",
    "consentReceiptDigest",
    "logicalChargeId",
    "chargeIdempotencyKeySha256",
    "scheduledFor",
)
DONATION_CHARGE_ERROR_CODES = (
    "INVALID_REQUEST",
    "IDEMPOTENCY_CONFLICT",
    "PAYMENT_RUNTIME_UNAVAILABLE",
    "RECONCILIATION_REQUIRED",
    "INTERNAL_ERROR",
)
DONATION_CHARGE_RESOURCE_BINDING = {
    "scope": "PRIVATE_APPLICATION",
    "request_schema": "DonationChargeJobPayloadV1",
    "success_schema": "DonationChargeExecutionResultV1",
    "caller": "billing-gateway.donation-charge-executor",
    "effect_owner": "payment-owner-function-boundary",
    "database_role": "gurine_billing_gateway",
}
DONATION_CHARGE_RESULT_VARIANTS = {
    "CONFIRMED": {
        "additional_properties": False,
        "fields": {
            "disposition": "const<CONFIRMED>",
            "attemptId": "uuid",
            "receiptDigest": "sha256",
            "effects": "const<NONE>",
        },
    },
    "REPLAY": {
        "additional_properties": False,
        "fields": {
            "disposition": "const<REPLAY>",
            "attemptId": "uuid",
            "receiptDigest": "sha256",
            "effects": "const<NONE>",
        },
    },
    "RECONCILIATION_REQUIRED": {
        "additional_properties": False,
        "fields": {
            "disposition": "const<RECONCILIATION_REQUIRED>",
            "attemptId": "uuid",
        },
    },
}
DONATION_CHARGE_LIFECYCLE_KEYS = (
    "core_target_relations",
    "auxiliary_relations",
    "success_binding_transitions",
    "success_atomicity",
    "recurring_scheduler_owner",
    "local_reject_terminal_owner",
    "failure_outcomes",
    "non_success_rule",
    "authority_effects",
)
DONATION_CHARGE_CORE_TARGET_RELATIONS = (
    "ops.payment_method_bindings",
    "ops.payment_charge_attempts",
    "ops.donation_facts",
)
DONATION_CHARGE_AUXILIARY_RELATIONS = (
    "ops.tasks",
    "ops.audit_events",
    "ops.outbox",
)
DONATION_CHARGE_SUCCESS_BINDING_TRANSITIONS = {
    "SINGLE_CHARGE": {
        "from": "ACTIVE",
        "to": "REVOKED",
        "terminal_disposition": "CONSUMED",
    },
    "RECURRING": {
        "from": "ACTIVE",
        "to": "ACTIVE",
        "terminal_disposition": "RETAINED",
    },
}
DONATION_CHARGE_FAILURE_OUTCOMES = {
    "LOCAL_REJECT": {
        "attempt_transition": "REQUESTED_TO_FAILED",
        "review_tasks": "ZERO",
        "donation_facts": "ZERO",
        "binding_consumptions": "ZERO",
    },
    "FETCHED_FAILED": {
        "attempt_transition": "PROVIDER_ACCEPTED_TO_FAILED",
        "review_tasks": "EXACTLY_ONE",
        "donation_facts": "ZERO",
        "binding_consumptions": "ZERO",
    },
    "FETCHED_CANCELED": {
        "attempt_transition": "PROVIDER_ACCEPTED_TO_FAILED",
        "review_tasks": "EXACTLY_ONE",
        "donation_facts": "ZERO",
        "binding_consumptions": "ZERO",
    },
}
DONATION_QUEUE_REQUEST_FIELDS = (
    "schemaVersion",
    "requestId",
    "offerVersionId",
    "offerDigest",
    "tierId",
    "cadence",
    "provider",
    "consentReceiptDigest",
    "paymentAuthorizationToken",
)
DONATION_QUEUE_RESPONSE_FIELDS = (
    "schemaVersion",
    "requestId",
    "jobId",
    "status",
    "receiptDigest",
)
DONATION_QUEUE_ERROR_CODES = (
    "INVALID_REQUEST",
    "SERVICE_ASSERTION_INVALID",
    "IDEMPOTENCY_CONFLICT",
    "DEPENDENCY_UNAVAILABLE",
    "INTERNAL_ERROR",
)
DONATION_QUEUE_TYPED_REQUEST_FIELDS = {
    "schemaVersion": {"type": "string", "const": "donation-intent-request.v1"},
    "requestId": {"type": "string", "format": "uuid"},
    "offerVersionId": {"type": "string", "format": "uuid"},
    "offerDigest": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
    "tierId": {"type": "string", "format": "uuid"},
    "cadence": {"type": "string", "enum": ["ONE_TIME", "RECURRING"]},
    "provider": {
        "type": "string",
        "enum": ["TOSS_PAYMENTS", "KAKAO_PAY", "STRIPE"],
    },
    "consentReceiptDigest": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
    "paymentAuthorizationToken": {"type": "string", "minLength": 1},
}
DONATION_QUEUE_TYPED_RESPONSE_FIELDS = {
    "schemaVersion": {"type": "string", "const": "donation-intent-queued.v1"},
    "requestId": {"type": "string", "format": "uuid"},
    "jobId": {"type": "string", "format": "uuid"},
    "status": {"type": "string", "const": "QUEUED"},
    "receiptDigest": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
}
FUNDING_REPORT_QUERY_ERROR_OVERLAYS = {
    "getFundingContent": {
        "preserved_base_statuses": ("404", "429", "500"),
        "canonical_statuses": ("404", "422", "429", "500"),
        "domain_errors": ("RESOURCE_NOT_FOUND", "PRECONDITION_FAILED"),
        "effective_errors": (
            "RATE_LIMITED",
            "RESOURCE_NOT_FOUND",
            "PRECONDITION_FAILED",
            "INTERNAL_ERROR",
        ),
        "http_error_mapping": {
            "404": ("RESOURCE_NOT_FOUND",),
            "422": ("PRECONDITION_FAILED",),
            "429": ("RATE_LIMITED",),
            "500": ("INTERNAL_ERROR",),
        },
    },
    "listTransparencyReports": {
        "preserved_base_statuses": ("400", "429", "500"),
        "canonical_statuses": ("400", "422", "429", "500"),
        "domain_errors": ("PRECONDITION_FAILED",),
        "effective_errors": (
            "INVALID_PARAMETER",
            "INVALID_CURSOR",
            "RATE_LIMITED",
            "PRECONDITION_FAILED",
            "INTERNAL_ERROR",
        ),
        "http_error_mapping": {
            "400": ("INVALID_PARAMETER", "INVALID_CURSOR"),
            "422": ("PRECONDITION_FAILED",),
            "429": ("RATE_LIMITED",),
            "500": ("INTERNAL_ERROR",),
        },
    },
}
ECONOMICS_IMPORT_VARIANTS = (
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


def operation_index(rows: list[dict], label: str) -> dict[str, dict]:
    indexed: dict[str, dict] = {}
    for row in rows:
        operation_id = row.get("operation_id")
        if not isinstance(operation_id, str) or not operation_id:
            raise ValueError(f"{label} contains an invalid operation_id")
        if operation_id in indexed:
            raise ValueError(f"{label} contains duplicate operation_id: {operation_id}")
        indexed[operation_id] = row
    return indexed


def require_set_equal(label: str, actual: set[str], expected: set[str]) -> None:
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing or extra:
        raise ValueError(
            f"{label} is not set-equal; missing={missing}, extra={extra}"
        )


def validate_base_operation_counts(base_doc: dict, base_rows: list[dict]) -> None:
    counts = base_doc.get("counts", {})
    derived = {
        "total": len(base_rows),
        "query": sum(row.get("operation_kind") == "QUERY" for row in base_rows),
        "command": sum(
            row.get("operation_kind") == "COMMAND" for row in base_rows
        ),
        "httpNonGet": sum(row.get("method") != "GET" for row in base_rows),
        "public": sum(row.get("api") == "public-api" for row in base_rows),
        "submission": sum(
            row.get("api") == "submission-api" for row in base_rows
        ),
        "control": sum(row.get("api") == "control-api" for row in base_rows),
        "identity": sum(
            row.get("api") == "identity-provider" for row in base_rows
        ),
    }
    if counts != derived:
        raise ValueError(
            "base operation counts do not match source rows: "
            f"declared={counts}, derived={derived}"
        )


def validate_resource_partitions(
    resource_doc: dict, expected: dict[str, set[str]]
) -> None:
    declared = resource_doc.get("set_equality", {})
    bindings = resource_doc.get("operation_bindings", {})
    partition_union: set[str] = set()
    for registry_key, scope in RESOURCE_OPERATION_PARTITIONS.items():
        declared_ids = set(declared.get(registry_key, []))
        require_set_equal(registry_key, declared_ids, expected[registry_key])
        overlap = partition_union & declared_ids
        if overlap:
            raise ValueError(
                f"resource operation partitions overlap: {sorted(overlap)}"
            )
        partition_union.update(declared_ids)
        bound_ids = {
            operation_id
            for operation_id, binding in bindings.items()
            if binding.get("scope") == scope
        }
        require_set_equal(f"operation_bindings scope={scope}", bound_ids, declared_ids)

    require_set_equal("operation_bindings", set(bindings), partition_union)
    require_set_equal(
        "request_schemas_by_operation",
        set(resource_doc.get("request_schemas_by_operation", {})),
        partition_union,
    )
    require_set_equal(
        "operation_error_sets",
        set(resource_doc.get("operation_error_sets", {})),
        partition_union,
    )


def private_operation_ids(addendum_doc: dict, resource_doc: dict) -> set[str]:
    declared = resource_doc.get("set_equality", {})
    private_union: set[str] = set()
    for registry_key, registry_names in RESOURCE_PRIVATE_OPERATION_PARTITIONS.items():
        source_name, binding_name, request_name, error_name = registry_names
        source_ids = set(addendum_doc.get(source_name, {}))
        declared_ids = set(declared.get(registry_key, []))
        require_set_equal(registry_key, declared_ids, source_ids)
        for name in (binding_name, request_name, error_name):
            require_set_equal(name, set(resource_doc.get(name, {})), source_ids)
        overlap = private_union & source_ids
        if overlap:
            raise ValueError(
                f"private operation partitions overlap: {sorted(overlap)}"
            )
        private_union.update(source_ids)
    return private_union


def validate_donation_charge_operation(addendum_doc: dict) -> dict:
    charge_operation = addendum_doc.get("private_application_commands", {}).get(
        DONATION_CHARGE_OPERATION_ID
    )
    if not isinstance(charge_operation, dict):
        raise ValueError("private.ExecuteDonationCharge command is missing")
    operation_request = charge_operation.get("request_schema", {})
    if (
        tuple(operation_request.get("fields", {})) != DONATION_CHARGE_PAYLOAD_FIELDS
        or tuple(operation_request.get("required", []))
        != DONATION_CHARGE_PAYLOAD_FIELDS
    ):
        raise ValueError("private.ExecuteDonationCharge operation payload is not exact")
    if tuple(charge_operation.get("errors", [])) != DONATION_CHARGE_ERROR_CODES:
        raise ValueError("private.ExecuteDonationCharge operation errors are not exact")
    return charge_operation


def validate_donation_charge_resource(resource_doc: dict) -> dict:
    resource_request = resource_doc.get("private_application_request_schemas", {}).get(
        DONATION_CHARGE_OPERATION_ID, {}
    )
    if resource_request.get("name") != "DonationChargeJobPayloadV1" or tuple(
        resource_request.get("fields", {})
    ) != DONATION_CHARGE_PAYLOAD_FIELDS:
        raise ValueError("private.ExecuteDonationCharge resource payload is not exact")
    resource_binding = resource_doc.get("private_application_command_bindings", {}).get(
        DONATION_CHARGE_OPERATION_ID, {}
    )
    if any(
        resource_binding.get(key) != value
        for key, value in DONATION_CHARGE_RESOURCE_BINDING.items()
    ):
        raise ValueError("private.ExecuteDonationCharge resource binding is not exact")
    resource_errors = resource_doc.get("private_application_error_sets", {}).get(
        DONATION_CHARGE_OPERATION_ID, []
    )
    if tuple(resource_errors) != DONATION_CHARGE_ERROR_CODES:
        raise ValueError("private.ExecuteDonationCharge resource errors are not exact")
    result_schema = resource_doc.get("schemas", {}).get(
        "DonationChargeExecutionResultV1", {}
    )
    if (
        result_schema.get("kind") != "discriminated_union"
        or result_schema.get("discriminator") != "disposition"
        or result_schema.get("variants") != DONATION_CHARGE_RESULT_VARIANTS
    ):
        raise ValueError("DonationChargeExecutionResultV1 is not exact")
    return resource_binding


def validate_donation_charge_semantics(command_doc: dict) -> dict:
    command = command_doc.get("private_application_commands", {}).get(
        DONATION_CHARGE_OPERATION_ID, {}
    )
    if (
        command.get("caller") != "billing-gateway.donation-charge-executor"
        or command.get("effect_owner") != "payment-owner-function-boundary"
        or command.get("database_role") != "gurine_billing_gateway"
        or command.get("direct_dml") != "FORBIDDEN"
        or tuple(command.get("errors", [])) != DONATION_CHARGE_ERROR_CODES
    ):
        raise ValueError("private.ExecuteDonationCharge command semantics are not exact")
    return command


def validate_donation_charge_lifecycle(
    operation: dict, resource_binding: dict, command: dict
) -> None:
    contracts = (
        operation.get("lifecycle_contract", {}),
        resource_binding.get("lifecycle_contract", {}),
        command.get("lifecycle_contract", {}),
    )
    if contracts[0] != contracts[1] or contracts[0] != contracts[2]:
        raise ValueError("private.ExecuteDonationCharge lifecycle contracts differ")
    lifecycle = contracts[0]
    if tuple(lifecycle) != DONATION_CHARGE_LIFECYCLE_KEYS:
        raise ValueError("private.ExecuteDonationCharge lifecycle keys are not exact")
    if (
        tuple(lifecycle.get("core_target_relations", []))
        != DONATION_CHARGE_CORE_TARGET_RELATIONS
        or tuple(lifecycle.get("auxiliary_relations", []))
        != DONATION_CHARGE_AUXILIARY_RELATIONS
        or lifecycle.get("success_binding_transitions")
        != DONATION_CHARGE_SUCCESS_BINDING_TRANSITIONS
        or lifecycle.get("recurring_scheduler_owner")
        != "ops.enqueue_due_r6e_donation_charge_jobs_v1"
        or lifecycle.get("local_reject_terminal_owner")
        != "ops.fail_r6e_donation_charge_v1"
        or lifecycle.get("failure_outcomes") != DONATION_CHARGE_FAILURE_OUTCOMES
    ):
        raise ValueError("private.ExecuteDonationCharge lifecycle is not exact")
    if (
        tuple(command.get("target_relations", []))
        != DONATION_CHARGE_CORE_TARGET_RELATIONS
        or tuple(command.get("auxiliary_relations", []))
        != DONATION_CHARGE_AUXILIARY_RELATIONS
    ):
        raise ValueError("private.ExecuteDonationCharge relation classes are not exact")


def normalize_private_billing_operation_contract(
    operation_id: str, addendum_doc: dict, resource_doc: dict
) -> dict:
    operation = addendum_doc.get("private_billing_gateway_operations", {}).get(
        operation_id, {}
    )
    binding = resource_doc.get("private_billing_gateway_operation_bindings", {}).get(
        operation_id, {}
    )
    request = resource_doc.get("private_billing_gateway_request_schemas", {}).get(
        operation_id, {}
    )
    response_name = binding.get("success_schema")
    response = resource_doc.get("schemas", {}).get(response_name, {})
    entrypoint = operation.get("entrypoint", {})
    if not all(
        isinstance(value, dict)
        for value in (operation, binding, request, response, entrypoint)
    ):
        raise ValueError(f"{operation_id} private billing source is incomplete")
    request_fields = request.get("fields", {})
    response_fields = response.get("fields", {})
    return {
        "operation_id": operation_id,
        "scope": binding.get("scope"),
        "operation_kind": operation.get("operation_kind"),
        "transport": operation.get("transport"),
        "method": entrypoint.get("method"),
        "path": entrypoint.get("path"),
        "success_status": binding.get("success_status"),
        "request_schema": binding.get("request_schema"),
        "response_schema": response_name,
        "request_fields": {
            name: contract_property(str(expression), resource_doc, {})
            for name, expression in request_fields.items()
        },
        "response_fields": {
            name: contract_property(str(expression), resource_doc, {})
            for name, expression in response_fields.items()
        },
        "errors": tuple(
            resource_doc.get("private_billing_gateway_error_sets", {}).get(
                operation_id, []
            )
        ),
    }


def validate_donation_queue_contract(
    addendum_doc: dict, resource_doc: dict, command_doc: dict
) -> None:
    operation = addendum_doc.get("private_billing_gateway_operations", {}).get(
        DONATION_QUEUE_OPERATION_ID, {}
    )
    binding = resource_doc.get("private_billing_gateway_operation_bindings", {}).get(
        DONATION_QUEUE_OPERATION_ID, {}
    )
    request = resource_doc.get("private_billing_gateway_request_schemas", {}).get(
        DONATION_QUEUE_OPERATION_ID, {}
    )
    response = resource_doc.get("schemas", {}).get(
        "DonationIntentQueuedReceiptV1", {}
    )
    command = command_doc.get("private_billing_gateway_operations", {}).get(
        DONATION_QUEUE_OPERATION_ID, {}
    )
    if (
        operation.get("operation_kind") != "COMMAND"
        or operation.get("transport") != "PRIVATE_BILLING_GATEWAY_HTTP"
        or operation.get("entrypoint")
        != {
            "method": "POST",
            "path": "/internal/v1/donation-intents",
            "success_status": 202,
        }
        or operation.get("caller") != "public-web SvelteKit server action"
        or operation.get("effect_owner") != "billing-gateway"
        or operation.get("required_headers")
        != {
            "Idempotency-Key": "secret-string[8..200]",
            "X-Gurine-Service-Assertion": "request-bound-service-assertion",
        }
        or operation.get("request_schema") != "DonationIntentQueueRequestV1"
        or operation.get("response_schema") != "DonationIntentQueuedReceiptV1"
        or tuple(operation.get("errors", [])) != DONATION_QUEUE_ERROR_CODES
    ):
        raise ValueError("private.QueueDonationIntent operation contract is not exact")
    expected_binding = {
        "scope": "PRIVATE_BILLING_GATEWAY",
        "operation_kind": "COMMAND",
        "request_schema": "DonationIntentQueueRequestV1",
        "success_status": 202,
        "success_schema": "DonationIntentQueuedReceiptV1",
        "caller": "public-web",
        "issuer": "public-web",
        "audience": "billing-gateway",
        "effect_owner": "billing-gateway",
        "required_header": "Idempotency-Key",
    }
    if any(binding.get(key) != value for key, value in expected_binding.items()):
        raise ValueError("private.QueueDonationIntent resource binding is not exact")
    if (
        request.get("name") != "DonationIntentQueueRequestV1"
        or request.get("additional_properties") is not False
        or tuple(request.get("fields", {})) != DONATION_QUEUE_REQUEST_FIELDS
        or response.get("kind") != "object"
        or response.get("additional_properties") is not False
        or tuple(response.get("required", [])) != DONATION_QUEUE_RESPONSE_FIELDS
        or tuple(response.get("fields", {})) != DONATION_QUEUE_RESPONSE_FIELDS
        or tuple(
            resource_doc.get("private_billing_gateway_error_sets", {}).get(
                DONATION_QUEUE_OPERATION_ID, []
            )
        )
        != DONATION_QUEUE_ERROR_CODES
    ):
        raise ValueError("private.QueueDonationIntent resource schemas are not exact")
    if (
        command.get("operation_id") != DONATION_QUEUE_OPERATION_ID
        or command.get("operation_kind") != "COMMAND"
        or command.get("transport") != "PRIVATE_BILLING_GATEWAY_HTTP"
        or command.get("entrypoint") != "POST /internal/v1/donation-intents"
        or command.get("success_status") != 202
        or command.get("caller") != "public-web SvelteKit server action"
        or command.get("effect_owner") != "billing-gateway"
        or command.get("receipt") != "DonationIntentQueuedReceiptV1"
        or tuple(command.get("errors", [])) != DONATION_QUEUE_ERROR_CODES
    ):
        raise ValueError("private.QueueDonationIntent command semantics are not exact")
    normalized = normalize_private_billing_operation_contract(
        DONATION_QUEUE_OPERATION_ID, addendum_doc, resource_doc
    )
    if (
        normalized["scope"] != "PRIVATE_BILLING_GATEWAY"
        or normalized["operation_kind"] != "COMMAND"
        or normalized["transport"] != "PRIVATE_BILLING_GATEWAY_HTTP"
        or normalized["method"] != "POST"
        or normalized["path"] != "/internal/v1/donation-intents"
        or normalized["success_status"] != 202
        or normalized["request_schema"] != "DonationIntentQueueRequestV1"
        or normalized["response_schema"] != "DonationIntentQueuedReceiptV1"
        or normalized["request_fields"] != DONATION_QUEUE_TYPED_REQUEST_FIELDS
        or normalized["response_fields"] != DONATION_QUEUE_TYPED_RESPONSE_FIELDS
        or normalized["errors"] != DONATION_QUEUE_ERROR_CODES
    ):
        raise ValueError("private.QueueDonationIntent typed normalization is not exact")


def validate_donation_fact_producers(
    addendum_doc: dict,
    resource_doc: dict,
    command_doc: dict,
    command: dict,
) -> None:
    producer_contracts = (
        ("operation", addendum_doc.get("donation_fact_producer_contract", {})),
        ("resource", resource_doc.get("donation_fact_producer_contract", {})),
        ("command", command.get("producer_contract", {})),
    )
    for label, producer_contract in producer_contracts:
        observed = tuple(producer_contract.get("producer_operations_exactly", []))
        if observed != DONATION_FACT_PRODUCER_OPERATIONS:
            raise ValueError(f"{label} donation.fact_recorded.v1 producers are not exact")
    webhook_id = DONATION_FACT_PRODUCER_OPERATIONS[1]
    producer_effect_owners = (
        addendum_doc.get("private_billing_gateway_operations", {})
        .get(webhook_id, {})
        .get("effect_owner"),
        resource_doc.get("private_billing_gateway_operation_bindings", {})
        .get(webhook_id, {})
        .get("effect_owner"),
        command_doc.get("private_billing_gateway_operations", {})
        .get(webhook_id, {})
        .get("effect_owner"),
    )
    expected_owner = "payment-owner-function-boundary"
    if producer_effect_owners != (expected_owner, expected_owner, expected_owner):
        raise ValueError("donation fact producers do not share the payment owner")


def validate_funding_report_query_error_overlays(
    addendum_doc: dict, resource_doc: dict, base_doc: dict
) -> None:
    source = addendum_doc.get("funding_report_query_error_overlays", {})
    source_operations = source.get("operations", {})
    resource_operations = resource_doc.get(
        "funding_report_query_error_overlays", {}
    )
    resource_ids = {
        operation_id
        for operation_id in resource_operations
        if operation_id != "invariants"
    }
    expected_ids = set(FUNDING_REPORT_QUERY_ERROR_OVERLAYS)
    require_set_equal("funding report source error overlays", set(source_operations), expected_ids)
    require_set_equal("funding report resource error overlays", resource_ids, expected_ids)
    base = operation_index(base_doc.get("operations", []), "base operation registry")
    for operation_id, expected in FUNDING_REPORT_QUERY_ERROR_OVERLAYS.items():
        operation = base.get(operation_id, {})
        source_contract = source_operations.get(operation_id, {})
        resource_errors = tuple(resource_operations.get(operation_id, []))
        raw_mapping = operation.get("http_error_mapping", {})
        operation_mapping = (
            {
                str(status): tuple(codes)
                for status, codes in raw_mapping.items()
                if isinstance(codes, list)
            }
            if isinstance(raw_mapping, dict)
            else {}
        )
        if (
            tuple(str(status) for status in operation.get("errors", []))
            != expected["canonical_statuses"]
            or tuple(operation.get("domain_errors", []))
            != expected["domain_errors"]
            or tuple(
                str(status) for status in source_contract.get(
                    "preserved_base_statuses", []
                )
            )
            != expected["preserved_base_statuses"]
            or tuple(
                str(status) for status in source_contract.get(
                    "canonical_statuses", []
                )
            )
            != expected["canonical_statuses"]
            or tuple(source_contract.get("effective_errors", []))
            != expected["effective_errors"]
            or tuple(operation.get("error_codes", []))
            != expected["effective_errors"]
            or operation_mapping != expected["http_error_mapping"]
            or resource_errors != expected["effective_errors"]
        ):
            raise ValueError(f"{operation_id} funding report error overlay is not exact")
    precondition = error_responses(["PRECONDITION_FAILED"], resource_doc)
    if tuple(precondition) != ("422",):
        raise ValueError("funding report PRECONDITION_FAILED must map only to 422")


def validate_private_operation_partitions(
    addendum_doc: dict,
    resource_doc: dict,
    command_doc: dict,
    http_operation_ids: set[str],
) -> None:
    private_union = private_operation_ids(addendum_doc, resource_doc)

    http_overlap = private_union & http_operation_ids
    if http_overlap:
        raise ValueError(
            "private operations must not enter the external/all-scope HTTP set: "
            f"{sorted(http_overlap)}"
        )
    charge_operation = validate_donation_charge_operation(addendum_doc)
    charge_binding = validate_donation_charge_resource(resource_doc)
    command = validate_donation_charge_semantics(command_doc)
    validate_donation_charge_lifecycle(charge_operation, charge_binding, command)
    validate_donation_fact_producers(addendum_doc, resource_doc, command_doc, command)
    validate_donation_queue_contract(addendum_doc, resource_doc, command_doc)


def operation_partition_summary(
    base_rows: list[dict],
    additive_rows: list[dict],
    additive_external_ids: set[str],
    private_identity_ids: set[str],
) -> dict[str, int]:
    additive_external = [
        row for row in additive_rows if row["operation_id"] in additive_external_ids
    ]
    private_identity = [
        row for row in additive_rows if row["operation_id"] in private_identity_ids
    ]
    return {
        "additive_external": len(additive_external),
        "private_identity_api": len(private_identity),
        "final_external": len(base_rows) + len(additive_external),
        "all_scope_http": len(base_rows) + len(additive_rows),
        "final_query": sum(
            row.get("operation_kind") == "QUERY" for row in base_rows
        )
        + sum(row.get("kind") == "QUERY" for row in additive_external),
        "all_scope_query": sum(
            row.get("operation_kind") == "QUERY" for row in base_rows
        )
        + sum(row.get("kind") == "QUERY" for row in additive_rows),
        "final_command": sum(
            row.get("operation_kind") == "COMMAND" for row in base_rows
        )
        + sum(row.get("kind") == "COMMAND" for row in additive_external),
        "all_scope_command": sum(
            row.get("operation_kind") == "COMMAND" for row in base_rows
        )
        + sum(row.get("kind") == "COMMAND" for row in additive_rows),
        "final_non_get": sum(row.get("method") != "GET" for row in base_rows)
        + sum(row.get("method") != "GET" for row in additive_external),
        "all_scope_non_get": sum(row.get("method") != "GET" for row in base_rows)
        + sum(row.get("method") != "GET" for row in additive_rows),
    }


def validate_operation_partition(
    operations: list[dict], resource_doc: dict, owner_doc: dict, base_doc: dict
) -> dict[str, int]:
    additive = operation_index(operations, "addendum operation contract")
    owner_additive = operation_index(
        owner_doc.get("additive_operations", []), "owner additive operation registry"
    )
    require_set_equal(
        "addendum operations", set(additive), set(owner_additive)
    )
    for operation_id, operation in additive.items():
        owner_operation = owner_additive[operation_id]
        for field in ("api", "method", "path", "kind"):
            if operation.get(field) != owner_operation.get(field):
                raise ValueError(
                    f"{operation_id} {field} differs from owner additive registry"
                )

    owner_counts = owner_doc.get("operation_counts", {})
    private_identity_ids = set(
        owner_counts.get("private_identity_api_operation_ids", [])
    )
    observed_identity_ids = {
        operation_id
        for operation_id, operation in additive.items()
        if operation.get("api") == "identity-api"
    }
    require_set_equal(
        "PRIVATE_IDENTITY_API operations",
        observed_identity_ids,
        private_identity_ids,
    )
    additive_external_ids = set(additive) - private_identity_ids
    invalid_external_apis = {
        operation.get("api")
        for operation_id, operation in additive.items()
        if operation_id in additive_external_ids
        and operation.get("api") not in ADDITIVE_EXTERNAL_APIS
    }
    if invalid_external_apis:
        raise ValueError(
            "unsupported additive external APIs: "
            f"{sorted(invalid_external_apis, key=str)}"
        )

    private_communication_ids = set(
        operation_index(
            owner_doc.get("private_communication_gateway_operations", []),
            "owner private communication registry",
        )
    )
    private_control_ids = set(
        operation_index(
            owner_doc.get("private_control_service_operations", []),
            "owner private control registry",
        )
    )
    validate_resource_partitions(
        resource_doc,
        {
            "additive_external_operation_ids": additive_external_ids,
            "private_identity_api_operation_ids": private_identity_ids,
            "private_communication_operation_ids": private_communication_ids,
            "private_control_service_operation_ids": private_control_ids,
        },
    )

    base_rows = base_doc.get("operations", [])
    base = operation_index(base_rows, "base external operation registry")
    overlap = set(base) & set(additive)
    if overlap:
        raise ValueError(
            f"base and additive HTTP operations overlap: {sorted(overlap)}"
        )
    validate_base_operation_counts(base_doc, base_rows)
    summary = operation_partition_summary(
        base_rows, operations, additive_external_ids, private_identity_ids
    )
    if summary["final_query"] + summary["final_command"] != summary["final_external"]:
        raise ValueError("final external query/command partition is incomplete")
    if (
        summary["all_scope_query"] + summary["all_scope_command"]
        != summary["all_scope_http"]
    ):
        raise ValueError("all-scope HTTP query/command partition is incomplete")
    return summary


def direct_contract_expression(expression: str) -> str:
    return expression.split("@", 1)[0].strip()


def generic_argument(expression: str, name: str) -> str | None:
    prefix = f"{name}<"
    if expression.lower().startswith(prefix) and expression.endswith(">"):
        return expression[len(prefix) : -1]
    return None


def required_contract_fields(fields: dict) -> list[str]:
    return [
        name
        for name, expression in fields.items()
        if generic_argument(
            direct_contract_expression(str(expression)), "optional"
        )
        is None
    ]


def const_schema(value: str) -> dict:
    normalized = value.strip()
    if normalized.lower() in {"true", "false"}:
        return {"type": "boolean", "const": normalized.lower() == "true"}
    if re.fullmatch(r"-?(?:0|[1-9]\d*)", normalized):
        return {"type": "integer", "const": int(normalized)}
    return {"type": "string", "const": normalized}


def bounded_string_schema(expression: str) -> dict | None:
    match = re.fullmatch(
        r"(?:secret-)?string\[(\d+)\.\.(\d+|max)\]",
        expression,
        re.IGNORECASE,
    )
    if match is None:
        return None
    schema = {"type": "string", "minLength": int(match.group(1))}
    if match.group(2).lower() != "max":
        schema["maxLength"] = int(match.group(2))
    return schema


def patterned_string_schema(expression: str) -> dict | None:
    match = re.fullmatch(
        r"string-pattern<(.+)>(?:\[(\d+)\.\.(\d+|max)\])?",
        expression,
        re.IGNORECASE,
    )
    if match is None:
        return None
    schema = {"type": "string", "pattern": match.group(1)}
    if match.group(2) is not None:
        schema["minLength"] = int(match.group(2))
    if match.group(3) is not None and match.group(3).lower() != "max":
        schema["maxLength"] = int(match.group(3))
    return schema


def integer_schema(expression: str) -> dict | None:
    match = re.fullmatch(
        r"(int32|int64)(?:\[(-?\d+)\.\.(-?\d+|max)\]|>=(-?\d+))?(?:=(-?\d+))?",
        expression,
        re.IGNORECASE,
    )
    if match is None:
        return None
    schema = {"type": "integer", "format": match.group(1).lower()}
    bracket_minimum = match.group(2)
    minimum = bracket_minimum if bracket_minimum is not None else match.group(4)
    if minimum is not None:
        schema["minimum"] = int(minimum)
    maximum = match.group(3)
    if maximum is not None and maximum.lower() != "max":
        schema["maximum"] = int(maximum)
    default = match.group(5)
    if default is not None:
        schema["default"] = int(default)
    return schema


def decimal_schema(expression: str) -> dict | None:
    bounded = re.fullmatch(
        r"(?:decimal|numeric)\((\d+),(\d+)\)",
        expression,
        re.IGNORECASE,
    )
    if bounded is not None:
        precision = int(bounded.group(1))
        scale = int(bounded.group(2))
        integer_digits = precision - scale
        if precision <= 0 or scale < 0 or integer_digits <= 0:
            raise ValueError(f"invalid decimal precision/scale: {expression}")
        fractional = (
            rf"(?:\.[0-9]{{0,{scale - 1}}}[1-9])?" if scale > 0 else ""
        )
        return {
            "type": "string",
            "pattern": (
                rf"^(?!-0$)-?(?:0|[1-9][0-9]{{0,{integer_digits - 1}}})"
                rf"{fractional}$"
            ),
            "maxLength": precision + 2,
            "x-canonical-decimal": True,
            "x-precision": precision,
            "x-scale": scale,
        }
    if expression.lower() == "decimal":
        return {
            "type": "string",
            "pattern": r"^(?!-0$)-?(?:0|[1-9][0-9]*)(?:\.[0-9]*[1-9])?$",
            "x-canonical-decimal": True,
        }
    return None


def enum_schema(expression: str) -> dict | None:
    generic = re.fullmatch(
        r"enum<(.+)>(?:=([^=]+))?",
        expression,
        re.IGNORECASE,
    )
    if generic is not None:
        values = generic.group(1).split("|")
        default = generic.group(2)
    else:
        normalized = expression.lower()
        if "|" not in expression or normalized.startswith(
            ("array<", "unique-array<", "optional<", "nullable<", "const<")
        ):
            return None
        raw_values, separator, raw_default = expression.partition("=")
        values = raw_values.split("|")
        default = raw_default if separator else None
    schema = {"type": "string", "enum": values}
    if default is not None:
        if default not in values:
            raise ValueError(f"enum default is outside the closed set: {expression}")
        schema["default"] = default
    return schema


def array_expression(
    expression: str,
) -> tuple[bool, str, int | None, int | None] | None:
    match = re.fullmatch(
        r"(unique-array|array)<(.+)>(?:\[(\d+)\.\.(\d+|max)\])?",
        expression,
        re.IGNORECASE,
    )
    if match is None:
        return None
    minimum = int(match.group(3)) if match.group(3) is not None else None
    raw_maximum = match.group(4)
    maximum = (
        int(raw_maximum)
        if raw_maximum is not None and raw_maximum.lower() != "max"
        else None
    )
    return match.group(1).lower() == "unique-array", match.group(2), minimum, maximum


def array_schema(
    item_schema: dict,
    *,
    unique: bool,
    minimum: int | None,
    maximum: int | None,
) -> dict:
    schema = {"type": "array", "items": item_schema}
    if minimum is not None:
        schema["minItems"] = minimum
    if maximum is not None:
        schema["maxItems"] = maximum
    if unique:
        schema["uniqueItems"] = True
    return schema


def primitive(expression: str) -> dict:
    direct_expression = direct_contract_expression(expression)
    normalized_expression = direct_expression.lower()
    bounded_uri_reference = re.fullmatch(
        r"uri-reference\[(\d+)\.\.(\d+)\]", direct_expression, re.IGNORECASE
    )
    if bounded_uri_reference:
        return {
            "type": "string",
            "format": "uri-reference",
            "minLength": int(bounded_uri_reference.group(1)),
            "maxLength": int(bounded_uri_reference.group(2)),
        }
    bounded_json_pointer = re.fullmatch(
        r"json-pointer\[(\d+)\.\.(\d+)\]", direct_expression, re.IGNORECASE
    )
    if bounded_json_pointer:
        return {
            "type": "string",
            "format": "json-pointer",
            "minLength": int(bounded_json_pointer.group(1)),
            "maxLength": int(bounded_json_pointer.group(2)),
        }
    bounded_string = bounded_string_schema(direct_expression)
    if bounded_string is not None:
        return bounded_string
    patterned_string = patterned_string_schema(direct_expression)
    if patterned_string is not None:
        return patterned_string
    integer = integer_schema(direct_expression)
    if integer is not None:
        return integer
    decimal = decimal_schema(direct_expression)
    if decimal is not None:
        return decimal
    enum = enum_schema(direct_expression)
    if enum is not None:
        return enum
    const_value = generic_argument(direct_expression, "const")
    if const_value is not None:
        return const_schema(const_value)
    # The product operation catalog also uses the compact `const value`
    # spelling.  Keep it a literal in OpenAPI; falling through to an empty
    # object makes generic contract fixtures emit `{}` and the owner routine
    # correctly rejects the request as invalid.
    if normalized_expression.startswith("const "):
        return const_schema(direct_expression[len("const ") :])
    if normalized_expression == "enum action_payloads.kinds":
        return {"type": "string", "enum": [
            "HYPOTHESIS", "CLAIM", "TASK", "COMPARABLE", "COMMUNICATION", "PUBLICATION",
            "RETRACTION", "RULE_ACTIVATION", "ROLE_GRANT", "KILL_SWITCH",
            "COMMUNICATION_AUTHORIZATION", "ASSET_RIGHTS_DECISION", "RETENTION_SCHEDULE",
            "FUNDING_DISCLOSURE", "ECONOMICS_IMPORT", "CAPABILITY_ACTIVATION", "RESPONSE_POLICY_CALENDAR",
            "COMMERCIAL_CONTROL", "PROVIDER_CONTROL",
        ]}
    optional_value = generic_argument(direct_expression, "optional")
    if optional_value is not None:
        return primitive(optional_value)
    nullable_value = generic_argument(direct_expression, "nullable")
    if nullable_value is not None:
        return {"anyOf": [primitive(nullable_value), {"type": "null"}]}
    collection = array_expression(direct_expression)
    if collection is not None:
        unique, item_expression, minimum, maximum = collection
        return array_schema(
            primitive(item_expression),
            unique=unique,
            minimum=minimum,
            maximum=maximum,
        )
    if "boolean" in normalized_expression:
        return {"type": "boolean"}
    if "int" in normalized_expression:
        return {"type": "integer", "format": "int64"}
    if "datetime" in normalized_expression:
        return {"type": "string", "format": "date-time"}
    if "date" in normalized_expression:
        return {"type": "string", "format": "date"}
    if "uuid" in normalized_expression:
        return {"type": "string", "format": "uuid"}
    if normalized_expression.startswith(
        "uri-reference"
    ) or normalized_expression.startswith("uri"):
        return {"type": "string", "format": "uri-reference"}
    if "sha256" in normalized_expression or "digest" in normalized_expression:
        return {"type": "string", "pattern": "^[0-9a-f]{64}$"}
    if normalized_expression in {"nonempty_string", "secret-nonempty-string"}:
        return {"type": "string", "minLength": 1}
    if normalized_expression == "cursor":
        return {"type": "string"}
    if normalized_expression.startswith("string") or "secret" in normalized_expression:
        return {"type": "string"}
    # Nested schemas are named in the contract.  A closed object reference is
    # emitted here and replaced by a component with no open properties.
    return {"type": "object", "additionalProperties": False}


def referenced_names(expression: str, known: set[str]) -> set[str]:
    return {name for name in known if name in expression}


def variant_fields(
    definition: dict, resource_doc: dict, schema_name: str, variant: str
) -> dict:
    direct_fields = dict(definition.get("fields", {}))
    source_name = definition.get("fields_from")
    if source_name is None:
        return direct_fields
    if (
        schema_name != "EconomicsImportOperationV1"
        or variant not in ECONOMICS_IMPORT_VARIANTS
    ):
        raise ValueError(
            "fields_from is allowed only on exact EconomicsImportOperationV1 variants"
        )
    if not isinstance(source_name, str) or not source_name:
        raise ValueError(f"{schema_name}.{variant} has invalid fields_from")
    source = resource_doc.get("schemas", {}).get(source_name)
    if not isinstance(source, dict):
        raise ValueError(
            f"{schema_name}.{variant} fields_from schema is missing: {source_name}"
        )
    if source.get("kind", "object") != "object" or source.get(
        "additional_properties", False
    ) or "fields_from" in source:
        raise ValueError(
            f"{schema_name}.{variant} fields_from must name a closed object"
        )
    inherited_fields = source.get("fields")
    if not isinstance(inherited_fields, dict) or not inherited_fields:
        raise ValueError(
            f"{schema_name}.{variant} fields_from has no closed fields: {source_name}"
        )
    collisions = set(direct_fields) & set(inherited_fields)
    if collisions:
        raise ValueError(
            f"{schema_name}.{variant} fields_from collisions: {sorted(collisions)}"
        )
    if direct_fields != {"operationId": f"const<{variant}>"}:
        raise ValueError(
            f"{schema_name}.{variant} may declare only its operationId discriminator"
        )
    forbidden_source_types = [
        field
        for field, expression in inherited_fields.items()
        if direct_contract_expression(str(expression)).lower()
        in {"json", "object", "map"}
        or direct_contract_expression(str(expression)).lower().startswith("map<")
        or source_name in str(expression)
    ]
    if forbidden_source_types:
        raise ValueError(
            f"{schema_name}.{variant} fields_from is recursive or map-valued: "
            f"{sorted(forbidden_source_types)}"
        )
    flattened = dict(direct_fields)
    flattened.update(inherited_fields)
    if "required" in definition:
        selected_required = set(definition["required"])
        expected_required = set(required_contract_fields(flattened))
        if selected_required != expected_required:
            raise ValueError(
                f"{schema_name}.{variant} required differs from flattened fields"
            )
    return flattened


def add_contract_schema(name: str, resource_doc: dict, schemas: dict, seen: set[str]) -> None:
    if name in seen or name not in resource_doc.get("schemas", {}):
        return
    seen.add(name)
    contract = resource_doc["schemas"][name]
    known = set(resource_doc.get("schemas", {}))
    if contract.get("kind") == "enum":
        schemas[name] = {"type": "string", "enum": list(contract.get("values", []))}
        return
    if contract.get("kind") == "discriminated_union":
        discriminator = contract.get("discriminator", "kind")
        common = contract.get("common_fields", {})
        if not contract.get("variants") and contract.get("fields"):
            fields = contract.get("fields", {})
            schemas[name] = {
                "type": "object", "additionalProperties": False,
                "properties": {field: contract_property(str(value), resource_doc, schemas) for field, value in fields.items()},
                "required": list(
                    contract.get("required", required_contract_fields(fields))
                ),
            }
            return
        variants = contract.get("variants", {})
        if any("fields_from" in definition for definition in variants.values()):
            if (
                name != "EconomicsImportOperationV1"
                or tuple(variants) != ECONOMICS_IMPORT_VARIANTS
            ):
                raise ValueError(
                    "fields_from requires the exact ordered economics import variants"
                )
            if discriminator != "operationId" or common:
                raise ValueError(
                    "EconomicsImportOperationV1 composition requires only operationId"
                )
            if not all(
                "fields_from" in definition for definition in variants.values()
            ):
                raise ValueError(
                    "every economics import variant requires exactly one fields_from"
                )
        branches = []
        for variant, definition in variants.items():
            selected_fields = variant_fields(
                definition, resource_doc, name, variant
            )
            fields = dict(common)
            fields.update(selected_fields)
            properties = {
                field: contract_property(str(value), resource_doc, schemas)
                for field, value in fields.items()
            }
            properties[discriminator] = {"type": "string", "const": variant}
            selected_required = definition.get("required")
            if selected_required is None:
                selected_required = required_contract_fields(selected_fields)
            required = list(
                dict.fromkeys(
                    [*required_contract_fields(common), *selected_required]
                )
            )
            if discriminator in fields and discriminator not in required:
                required.append(discriminator)
            branches.append({
                "type": "object",
                "additionalProperties": bool(definition.get("additional_properties", False)),
                "properties": properties,
                "required": required,
            })
        schemas[name] = {"oneOf": branches}
        for value in common.values():
            for child in referenced_names(str(value), known):
                add_contract_schema(child, resource_doc, schemas, seen)
        for variant, definition in variants.items():
            source_name = definition.get("fields_from")
            if source_name is not None:
                add_contract_schema(source_name, resource_doc, schemas, seen)
            selected_fields = variant_fields(
                definition, resource_doc, name, variant
            )
            for value in selected_fields.values():
                for child in referenced_names(str(value), known):
                    add_contract_schema(child, resource_doc, schemas, seen)
        return
    fields = contract.get("fields", {})
    schemas[name] = {
        "type": "object", "additionalProperties": False,
        "properties": {
            field: contract_property(str(value), resource_doc, schemas)
            for field, value in fields.items()
        },
        "required": required_contract_fields(fields),
    }
    for value in fields.values():
        for child in referenced_names(str(value), known):
            add_contract_schema(child, resource_doc, schemas, seen)


def contract_property(expression: str, resource_doc: dict, schemas: dict) -> dict:
    known = set(resource_doc.get("schemas", {})) | set(schemas)
    direct = direct_contract_expression(expression)
    if direct in known:
        add_contract_schema(direct, resource_doc, schemas, set())
        return {"$ref": f"#/components/schemas/{direct}"}
    optional_value = generic_argument(direct, "optional")
    if optional_value is not None:
        return contract_property(optional_value, resource_doc, schemas)
    nullable_value = generic_argument(direct, "nullable")
    if nullable_value is not None:
        return {
            "anyOf": [
                contract_property(nullable_value, resource_doc, schemas),
                {"type": "null"},
            ]
        }
    shorthand = re.fullmatch(r"nullable-(.+)", direct)
    if shorthand:
        inner = shorthand.group(1)
        return {"anyOf": [primitive(inner), {"type": "null"}]}
    collection = array_expression(direct)
    if collection is not None and collection[1] in known:
        unique, child, minimum, maximum = collection
        add_contract_schema(child, resource_doc, schemas, set())
        return array_schema(
            {"$ref": f"#/components/schemas/{child}"},
            unique=unique,
            minimum=minimum,
            maximum=maximum,
        )
    return primitive(expression)


def error_responses(codes: list[str], resource_doc: dict) -> dict:
    grouped: dict[str, list[str]] = {}
    base_catalog = yaml.safe_load(BASE_ERROR_CATALOG.read_text()).get("errors", [])
    status_by_code = {
        row["code"]: str(row["http_status"])
        for row in base_catalog
        if isinstance(row, dict) and isinstance(row.get("code"), str)
    }
    status_by_code.update({
        code: str(contract["http_status"])
        for code, contract in resource_doc.get("error_catalog_additions", {}).items()
    })
    for code in codes:
        status = status_by_code.get(code)
        if status is None:
            raise ValueError(f"uncataloged additive error code: {code}")
        grouped.setdefault(status, []).append(code)
    return {
        status: {
            "description": "Problem response: " + ", ".join(values),
            "content": {"application/problem+json": {"schema": {"$ref": "#/components/schemas/AddendumProblemDetailsV1"}}},
            "x-error-codes": values,
        }
        for status, values in grouped.items()
    }


def apply_funding_report_query_error_overlays(
    document: dict, resource_doc: dict
) -> None:
    base_doc = yaml.safe_load(BASE_OPERATIONS.read_text())
    base = operation_index(base_doc.get("operations", []), "base operation registry")
    overlays = resource_doc.get("funding_report_query_error_overlays", {})
    precondition_response = error_responses(["PRECONDITION_FAILED"], resource_doc)[
        "422"
    ]
    for operation_id in FUNDING_REPORT_QUERY_ERROR_OVERLAYS:
        operation = base[operation_id]
        node = (
            document.get("paths", {})
            .get(operation["path"], {})
            .get(operation["method"].lower())
        )
        if not isinstance(node, dict) or node.get("operationId") != operation_id:
            raise ValueError(f"{operation_id} generated base operation is missing")
        responses = node.setdefault("responses", {})
        responses["422"] = copy.deepcopy(precondition_response)
        node["responses"] = {
            status: responses[status]
            for status in sorted(responses, key=lambda value: int(value))
        }
        node["x-error-codes"] = list(overlays[operation_id])


def operation_node(operation: dict, binding: dict, schemas: dict, resource_doc: dict, control: bool) -> dict:
    request = operation.get("request", {})
    fields = request.get("fields", {})
    required = list(request.get("required", []))
    request_name = binding["request_schema"]
    response_name = binding["success_schema"]
    query_envelope = (
        operation["kind"] == "QUERY"
        and operation["operation_id"] != "downloadTransparencyReport"
    )
    schemas[request_name] = {
        "type": "object",
        "additionalProperties": False,
        **(
            {"description": request["description"]}
            if request.get("description")
            else {}
        ),
        "properties": {
            name: contract_property(str(value), resource_doc, schemas)
            for name, value in fields.items()
        },
        "required": required,
    }
    field_descriptions = request.get("field_descriptions", {})
    unknown_descriptions = set(field_descriptions) - set(fields)
    if unknown_descriptions:
        raise ValueError(
            f"{operation['operation_id']} describes unknown request fields: "
            + ", ".join(sorted(unknown_descriptions))
        )
    for field_name, description in field_descriptions.items():
        schemas[request_name]["properties"][field_name]["description"] = description
    # The journey handoff request has a discriminator-sensitive nullable enum
    # branch.  Keep this exact wire shape in the generated OpenAPI even when a
    # legacy operation fixture uses the older shorthand expressions.
    if operation["operation_id"] == "decideJourneyHandoff":
        schemas[request_name]["properties"].update({
            "schemaVersion": {
                "type": "string",
                "const": "decide-journey-handoff.request.v1",
            },
            "decision": {
                "type": "string",
                "enum": ["ACKNOWLEDGE", "DECLINE"],
            },
            "reasonCode": {
                "anyOf": [
                    {
                        "type": "string",
                        "enum": [
                            "CAPABILITY_UNAVAILABLE",
                            "OBJECT_SCOPE_MISMATCH",
                            "CONFLICT_OF_INTEREST",
                            "WORKLOAD_CAPACITY",
                            "DEPENDENCY_BLOCKED",
                            "SUBJECT_INVALID",
                            "OWNER_UNAVAILABLE",
                            "POLICY_BLOCKED",
                            "RECEIVER_DECLINED",
                        ],
                    },
                    {"type": "null"},
                ]
            },
        })
    add_contract_schema(request_name, resource_doc, schemas, set())
    contract_schema = resource_doc.get("schemas", {}).get(response_name, {})
    response_fields = contract_schema.get("fields", {})
    schemas[response_name] = {
        "type": "object", "additionalProperties": False,
        "properties": {name: contract_property(str(value), resource_doc, schemas) for name, value in response_fields.items()},
        "required": required_contract_fields(response_fields),
    }
    # The registered query boundary adds the operation identifier to every
    # query envelope so receipts and readbacks remain self-describing. Keep that field in the
    # additive response contract instead of returning a schema-invalid extra.
    if query_envelope:
        schemas[response_name]["properties"]["operationId"] = {"type": "string"}
        schemas[response_name]["required"].append("operationId")
        # Query adapters use the same navigable link envelope as the legacy
        # Control API.  Preserve links in the additive contract so the
        # response validator cannot discard destination affordances.
        schemas[response_name]["properties"].setdefault(
            "links", {"type": "array", "items": {"$ref": "#/components/schemas/Link"}}
        )
        if "links" not in schemas[response_name]["required"]:
            schemas[response_name]["required"].append("links")
    add_contract_schema(response_name, resource_doc, schemas, set())
    # add_contract_schema materialises nested references and may replace the
    # top-level response object; reapply the transport envelope fields after
    # that expansion so query adapters remain schema-closed.
    if query_envelope:
        schemas[response_name]["properties"]["operationId"] = {"type": "string"}
        schemas[response_name]["properties"].setdefault(
            "links", {"type": "array", "items": {"$ref": "#/components/schemas/Link"}}
        )
        for field in ("operationId", "links"):
            if field not in schemas[response_name]["required"]:
                schemas[response_name]["required"].append(field)
    node = {
        "operationId": operation["operation_id"],
        "summary": operation["operation_id"],
        **(
            {"description": operation["description"]}
            if operation.get("description")
            else {}
        ),
        "tags": ["addendum"],
        "x-operation-kind": operation["kind"],
        "x-capability": operation.get("capability", "none"),
        "x-assurance-level": operation.get("assurance", "ACTIVE_SESSION"),
        "x-error-codes": list(operation.get("errors", [])),
        "security": (
            [{"ActorAssertion": []}]
            if control
            else (
                []
                if binding["transport_profile"].upper().startswith("PUBLIC_")
                else (
                    [{"BffServiceAssertion": [], "ScopedSubmissionSession": []}]
                    if "scoped" in binding["transport_profile"].lower()
                    else [{"BffServiceAssertion": []}]
                )
            )
        ),
        "responses": {
            str(binding["success_status"]): {
                "description": "Successful response",
                "content": {binding["success_media_type"]: {"schema": {"$ref": f"#/components/schemas/{response_name}"}}},
            },
        },
    }
    path_parameters = re.findall(r"\{([^}]+)\}", operation["path"])
    if path_parameters:
        node["parameters"] = [{"name": name, "in": "path", "required": True, "schema": {"type": "string", "format": "uuid"}} for name in path_parameters]
    # GET contracts carry their request shape in the query string.  The
    # previous generator only emitted path parameters, which silently made
    # required detail identifiers (for example appealId) unavailable to the
    # generated clients and caused the runtime to reject an otherwise valid
    # request as INVALID_REQUEST.  Emit both required `fields` and optional
    # filter entries as real OpenAPI query parameters so the wire contract,
    # clients and control-flow witness share one source of truth.
    if operation["method"] == "GET":
        query_parameters = []
        for name in required:
            if name in fields and name not in path_parameters:
                query_parameters.append({
                    "name": name,
                    "in": "query",
                    "required": True,
                    "schema": contract_property(str(fields[name]), resource_doc, schemas),
                })
        for name, expression in request.get("optional", {}).items():
            query_parameters.append({
                "name": name,
                "in": "query",
                "required": False,
                "schema": contract_property(str(expression), resource_doc, schemas),
            })
        if query_parameters:
            node.setdefault("parameters", []).extend(query_parameters)
    node["responses"].update(error_responses(list(operation.get("errors", [])), resource_doc))
    if operation["method"] != "GET":
        node.setdefault("parameters", []).append({"name": "Idempotency-Key", "in": "header", "required": True, "schema": {"type": "string", "minLength": 8, "maxLength": 200}})
        node["requestBody"] = {"required": True, "content": {"application/json": {"schema": {"$ref": f"#/components/schemas/{request_name}"}}}}
    return node


def close_provider_control_side_doors(document: dict) -> None:
    """Keep provider command schemas as form anchors without exposing effects.

    Provider state can change only after a PROVIDER_CONTROL proposal becomes a
    current ExecutionAuthorization.  The historical HTTP operations remain in
    the document solely as closed request/discriminator types and therefore
    have one possible authenticated application response: the no-effect 409.
    """
    expected = set(PROVIDER_CONTROL_OPERATION_IDS)
    found: set[str] = set()
    for path_item in document.get("paths", {}).values():
        if not isinstance(path_item, dict):
            continue
        for node in path_item.values():
            if not isinstance(node, dict):
                continue
            operation_id = node.get("operationId")
            if operation_id not in expected:
                continue
            found.add(operation_id)
            node["x-error-codes"] = ["ACTION_PROPOSAL_REQUIRED"]
            node["x-provider-control-entrypoint"] = "ACTION_PROPOSAL"
            node["x-state-effect"] = "UNCHANGED"
            node["responses"] = {
                "409": {
                    "description": "Provider control requires an approved action proposal",
                    "content": {
                        "application/problem+json": {
                            "schema": {
                                "$ref": "#/components/schemas/AddendumProblemDetailsV1"
                            }
                        }
                    },
                    "x-error-codes": ["ACTION_PROPOSAL_REQUIRED"],
                }
            }
    if found != expected:
        missing = ", ".join(sorted(expected - found))
        extra = ", ".join(sorted(found - expected))
        raise ValueError(
            f"provider control HTTP side-door catalog drifted; missing={missing}; extra={extra}"
        )

    schemas = document.setdefault("components", {}).setdefault("schemas", {})
    connection_request = schemas.get("testProviderConnectionRequest")
    if not isinstance(connection_request, dict):
        raise ValueError("testProviderConnectionRequest schema is missing")
    properties = connection_request.setdefault("properties", {})
    properties["expectedVersion"] = {"type": "integer", "format": "int64", "minimum": 1}
    required = connection_request.setdefault("required", [])
    if "expectedVersion" not in required:
        required.append("expectedVersion")


def import_control_base_operation_extensions(document: dict) -> None:
    """Project the authoritative handwritten schema for extended base operations.

    Additive operations are rebuilt from the owner addendum below.  A base
    operation remains in the original OpenAPI path table, so its replacement
    request union must be copied explicitly instead of leaving the historical
    case-shaped component in generated clients.
    """

    resource_document = yaml.safe_load(HANDWRITTEN_RESOURCES.read_text())
    resource_schemas = resource_document.get("resources", {})
    schemas = document.setdefault("components", {}).setdefault("schemas", {})
    for name in CONTROL_BASE_SCHEMA_IMPORTS:
        entry = resource_schemas.get(name)
        if not isinstance(entry, dict) or not isinstance(entry.get("schema"), dict):
            raise ValueError(f"handwritten resource schema is missing: {name}")
        if "control-api" not in entry.get("apis", []):
            raise ValueError(f"handwritten resource schema is not control-api bound: {name}")
        schemas[name] = copy.deepcopy(entry["schema"])

    operation = (
        document.get("paths", {})
        .get("/v1/internal/commands/place-legal-hold", {})
        .get("post")
    )
    if not isinstance(operation, dict) or operation.get("operationId") != "placeLegalHold":
        raise ValueError("base placeLegalHold OpenAPI operation is missing")
    operation["description"] = (
        "Places a retention, deletion or disclosure hold on one exact "
        "versioned target from the closed thirteen-kind legal-hold union."
    )


def import_public_base_operation_extensions(document: dict) -> None:
    """Project the closed reproducibility download contract into Public OpenAPI."""

    resource_document = yaml.safe_load(HANDWRITTEN_RESOURCES.read_text())
    resource_schemas = resource_document.get("resources", {})
    schemas = document.setdefault("components", {}).setdefault("schemas", {})
    for name in PUBLIC_BASE_SCHEMA_IMPORTS:
        entry = resource_schemas.get(name)
        if not isinstance(entry, dict) or not isinstance(entry.get("schema"), dict):
            raise ValueError(f"handwritten resource schema is missing: {name}")
        if "public-api" not in entry.get("apis", []):
            raise ValueError(f"handwritten resource schema is not public-api bound: {name}")
        schemas[name] = copy.deepcopy(entry["schema"])

    operation = (
        document.get("paths", {})
        .get("/v1/cases/{caseSlug}/reproducibility/download", {})
        .get("get")
    )
    if not isinstance(operation, dict) or operation.get("operationId") != "downloadCaseReproducibility":
        raise ValueError("base downloadCaseReproducibility OpenAPI operation is missing")
    operation["description"] = (
        "공개 재배포 산출물입니다. JSON 파일 본문은 재배포 고지와 상태별 비확정 문구를 "
        "최상위에 포함하고, CSV 파일 본문은 재배포 고지 한 셀 행과 비확정 문구 열을 보존합니다."
    )
    operation["responses"]["200"]["content"]["application/json"]["schema"] = {
        "$ref": "#/components/schemas/CaseReproducibilityDownload"
    }


def merge(
    api: str, operations: list[dict], resource_doc: dict, *, check: bool
) -> list[Path]:
    yaml_path = ROOT / f"specs/api/{api}.openapi.yaml"
    json_path = ROOT / f"specs/api/{api}.openapi.json"
    generated_path = ROOT / f"specs/generated/{api}.openapi.json"
    document = yaml.safe_load(yaml_path.read_text())
    if api == "control-api":
        import_control_base_operation_extensions(document)
    elif api == "public-api":
        import_public_base_operation_extensions(document)
    # Re-running the generator must be idempotent; older runs appended the
    # same tag repeatedly and inflated the source diff on every regeneration.
    document["tags"] = [
        tag for tag in document.get("tags", []) if tag.get("name") != "addendum"
    ] + ([{"name": "addendum"}] if operations else [])
    schemas = document.setdefault("components", {}).setdefault("schemas", {})
    if operations:
        schemas.setdefault("AddendumProblemDetailsV1", {
            "type": "object", "additionalProperties": False,
            "properties": {
                "code": {"type": "string"}, "title": {"type": "string"},
                "status": {"type": "integer"}, "requestId": {"type": "string", "format": "uuid"},
                "detail": {"type": ["string", "null"]},
            },
            "required": ["code", "title", "status", "requestId"],
        })
    # Repair the legacy self-reference in the estimate query schema while
    # materialising the merged document.  Its data payload is a concrete
    # estimate, not another envelope.
    estimate = schemas.get("estimateBackfillReceipt")
    if isinstance(estimate, dict) and isinstance(estimate.get("properties"), dict):
        data = estimate["properties"].get("data")
        if isinstance(data, dict) and data.get("$ref") == "#/components/schemas/estimateBackfillReceipt":
            data.clear()
            data.update({
                "type": "object", "additionalProperties": False,
                "properties": {
                    "sourceId": {"type": "string"}, "from": {"type": "string", "format": "date"},
                    "to": {"type": "string", "format": "date"}, "estimatedRecords": {"type": "integer"},
                    "estimatedJobs": {"type": "integer"}, "estimatedCostKrw": {"type": "string"},
                    "estimatedDurationSeconds": {"type": "integer"}, "dedupeStrategy": {"type": "string"},
                    "downstreamEffects": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["sourceId", "from", "to", "estimatedRecords", "estimatedJobs", "estimatedCostKrw", "estimatedDurationSeconds", "dedupeStrategy", "downstreamEffects"],
            })
    # OPS-004 reuses the historical getBudgetOverview operation and returns
    # the closed BudgetOverviewResponse envelope. The registered query boundary
    # stamps operationId on that envelope, so the merged schema must permit the
    # discriminator field as well.
    budget_response = schemas.get("BudgetOverviewResponse")
    if isinstance(budget_response, dict) and isinstance(budget_response.get("properties"), dict):
        budget_response["properties"]["operationId"] = {"type": "string"}
        required = budget_response.setdefault("required", [])
        if "operationId" not in required:
            required.append("operationId")
    business_response = schemas.get("BusinessHealthResponse")
    if isinstance(business_response, dict) and isinstance(business_response.get("properties"), dict):
        business_response["properties"]["operationId"] = {"type": "string"}
        required = business_response.setdefault("required", [])
        if "operationId" not in required:
            required.append("operationId")
    for operation in operations:
        binding = resource_doc["operation_bindings"][operation["operation_id"]]
        path = document.setdefault("paths", {}).setdefault(operation["path"], {})
        node = operation_node(operation, binding, schemas, resource_doc, api == "control-api")
        if operation["operation_id"] == "getBudgetOverview":
            node["responses"][str(binding["success_status"])]["content"][binding["success_media_type"]]["schema"] = {
                "$ref": "#/components/schemas/BudgetOverviewResponse"
            }
        path[operation["method"].lower()] = node
    if api == "public-api":
        apply_funding_report_query_error_overlays(document, resource_doc)
    if api == "control-api":
        legacy_budget = document.get("paths", {}).get("/v1/internal/queries/get-budget-overview", {}).get("get")
        if isinstance(legacy_budget, dict) and "200" in legacy_budget.get("responses", {}):
            legacy_budget["responses"]["200"]["content"]["application/json"]["schema"] = {
                "$ref": "#/components/schemas/BudgetOverviewResponse"
            }
        close_provider_control_side_doors(document)
    # JSON is the generated source consumed by Rust and BFF imports. YAML and
    # JSON are written from the same object so semantic equality is guaranteed.
    json_bytes = json.dumps(document, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    if check:
        failures: list[Path] = []
        if yaml.safe_load(yaml_path.read_text()) != document:
            failures.append(yaml_path)
        for path in (json_path, generated_path):
            if not path.is_file() or json.loads(path.read_text()) != document:
                failures.append(path)
        return failures
    yaml_path.write_text(yaml.safe_dump(document, allow_unicode=True, sort_keys=False))
    json_path.write_text(json_bytes)
    subprocess.run(
        [
            "bunx",
            "biome",
            "format",
            "--write",
            "--no-errors-on-unmatched",
            str(json_path),
        ],
        cwd=ROOT,
        check=True,
    )
    generated_path.write_bytes(json_path.read_bytes())
    return []


def write_identity(
    operations: list[dict], resource_doc: dict, *, check: bool
) -> list[Path]:
    """Emit the small procurement identity-api document separately from the
    nine-operation identity-service-internal document."""
    document = {
        "openapi": "3.1.0",
        "info": {"title": "Gurine Identity API", "version": "13.0.0"},
        "servers": [{"url": "http://identity-api:8085"}],
        "tags": [{"name": "procurement"}],
        "paths": {},
        "components": {
            "securitySchemes": {"ServiceAssertion": {"type": "apiKey", "in": "header", "name": "X-Gurine-Service-Assertion"}},
            "schemas": {"AddendumProblemDetailsV1": {"type": "object", "additionalProperties": False, "properties": {"code": {"type": "string"}, "title": {"type": "string"}, "status": {"type": "integer"}, "requestId": {"type": "string", "format": "uuid"}}, "required": ["code", "title", "status", "requestId"]}},
        },
    }
    schemas = document["components"]["schemas"]
    for operation in operations:
        binding = resource_doc["operation_bindings"].get(operation["operation_id"], {})
        node = operation_node(operation, binding, schemas, resource_doc, False)
        node["security"] = [{"ServiceAssertion": []}]
        document["paths"].setdefault(operation["path"], {})[operation["method"].lower()] = node
    failures: list[Path] = []
    for suffix in ("api", "generated"):
        path = ROOT / f"specs/{suffix}/identity-api.openapi.{'yaml' if suffix == 'api' else 'json'}"
        payload = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
        if check:
            current = yaml.safe_load(path.read_text()) if path.is_file() else None
            if current != document:
                failures.append(path)
        elif suffix == "api":
            path.write_text(yaml.safe_dump(document, allow_unicode=True, sort_keys=False))
        else:
            path.write_text(payload)
    return failures


def sync_internal_identity(*, check: bool = False) -> list[Path]:
    """Materialise the authoritative private Identity YAML as JSON.

    The addendum does not own the nine private operations, but R6d extends
    their request-bound capability contract. Keeping this projection in the
    same source generator prevents the handwritten YAML and both JSON
    consumers from drifting after an additive contract change.
    """

    yaml_path = ROOT / "specs/api/identity-service-internal.openapi.yaml"
    json_path = ROOT / "specs/api/identity-service-internal.openapi.json"
    generated_path = ROOT / "specs/generated/identity-service-internal.openapi.json"
    document = yaml.safe_load(yaml_path.read_text())
    if check:
        failures: list[Path] = []
        for path in (json_path, generated_path):
            if not path.is_file() or json.loads(path.read_text()) != document:
                failures.append(path)
        return failures
    json_path.write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    )
    subprocess.run(
        [
            "bunx",
            "biome",
            "format",
            "--write",
            "--no-errors-on-unmatched",
            str(json_path),
        ],
        cwd=ROOT,
        check=True,
    )
    generated_path.write_bytes(json_path.read_bytes())
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check", action="store_true", help="fail without writing when projections differ"
    )
    args = parser.parse_args()
    addendum_doc = yaml.safe_load(ADDENDUM.read_text())
    operations = addendum_doc["operations"]
    resource_doc = yaml.safe_load(RESOURCES.read_text())
    command_doc = yaml.safe_load(COMMAND_SEMANTICS.read_text())
    owner_doc = yaml.safe_load(OWNER_ADDENDUM.read_text())
    base_doc = yaml.safe_load(BASE_OPERATIONS.read_text())
    validate_private_operation_partitions(
        addendum_doc,
        resource_doc,
        command_doc,
        {operation["operation_id"] for operation in operations},
    )
    validate_funding_report_query_error_overlays(
        addendum_doc, resource_doc, base_doc
    )
    partition = validate_operation_partition(
        operations, resource_doc, owner_doc, base_doc
    )
    grouped = {
        "public-api": [row for row in operations if row["api"] == "public-api"],
        "control-api": [row for row in operations if row["api"] == "control-api"],
        "submission-api": [row for row in operations if row["api"] == "submission-api"],
    }
    failures: list[Path] = []
    for api, rows in grouped.items():
        failures.extend(merge(api, rows, resource_doc, check=args.check))
    failures.extend(
        write_identity(
            [row for row in operations if row.get("api") == "identity-api"],
            resource_doc,
            check=args.check,
        )
    )
    failures.extend(sync_internal_identity(check=args.check))
    if failures:
        print("generated OpenAPI projections differ:")
        for path in failures:
            print(f"- {path.relative_to(ROOT)}")
        return 1
    if args.check:
        print(
            "generated OpenAPI projections: PASS "
            f"additive_external={partition['additive_external']} "
            f"private_identity_api={partition['private_identity_api']} "
            f"final_external={partition['final_external']} "
            f"all_scope_http={partition['all_scope_http']}"
        )
    else:
        print(
            f"merged {partition['additive_external']} additive external operations "
            f"and {partition['private_identity_api']} private identity-api operations"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
