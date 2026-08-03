from __future__ import annotations

from typing import Any

from .design_support import DesignDocuments


def validate_provider_control_governance(
    documents: DesignDocuments,
    provider_operation_policies: dict[str, dict[str, Any]],
) -> None:
    result = documents.result
    operation_contracts = documents.operation_contracts
    action_variants = operation_contracts["action_payloads"]["variants"]
    approval_policy = documents.approval_policy
    quorum_kinds = approval_policy["quorum_policies"]["action_kinds"]
    executor_catalog = approval_policy["executor_catalog"]
    provider_operation_ids = set(provider_operation_policies)
    provider_variant = action_variants.get("PROVIDER_CONTROL", {})
    provider_quorum = quorum_kinds.get("PROVIDER_CONTROL", {})
    provider_executor = executor_catalog.get("PROVIDER_CONTROL", {})
    result.require(
        provider_variant.get("required") == ["providerControl"]
        and provider_variant.get("executor") == "private.ExecuteProviderControl"
        and provider_variant.get("proposer_capability")
        == "selected by providerControl.operationId"
        and set(provider_variant.get("operation_policies", {}))
        == provider_operation_ids
        and provider_quorum.get("classifier") == "provider_control_operation"
        and provider_quorum.get("proposer_capability")
        == "selected by providerControl.operationId"
        and set(provider_quorum.get("classes", {})) == provider_operation_ids
        and provider_executor.get("executor_id") == "private.ExecuteProviderControl"
        and provider_executor.get("transport") == "PRIVATE_APPLICATION_COMMAND"
        and provider_executor.get("owner")
        == "analysis-worker.provider-control-executor"
        and provider_executor.get("capability") == "jobs.operate"
        and provider_executor.get("assurance") == "BY_PROVIDER_CONTROL_OPERATION"
        and set(provider_executor.get("operation_policies", {}))
        == provider_operation_ids,
        "PROVIDER_CONTROL outer variant, quorum or analysis-worker executor binding is incomplete",
    )
    for operation_id, expected in provider_operation_policies.items():
        variant_policy = provider_variant["operation_policies"].get(operation_id, {})
        executor_policy = provider_executor["operation_policies"].get(
            operation_id, {}
        )
        quorum_class = provider_quorum["classes"].get(operation_id, {})
        slots = quorum_class.get("slots", [])
        result.require(
            variant_policy
            == {
                "capability": expected["capability"],
                "assurance": expected["assurance"],
            }
            and executor_policy == variant_policy
            and quorum_class.get("proposer_capability")
            == expected["capability"]
            and quorum_class.get("assurance") == expected["assurance"]
            and len(slots) == 1
            and slots[0].get("capability") == expected["capability"]
            and set(slots[0].get("allowed_roles", [])) == expected["roles"],
            f"{operation_id}: provider control capability, assurance or independent reviewer policy drifted",
        )
    submit_decision = next(
        (
            row
            for row in operation_contracts.get("operations", [])
            if row.get("operation_id") == "submitActionDecision"
        ),
        {},
    )
    submit_request = submit_decision.get("request", {})
    submit_resource = documents.resource_error_contracts.get(
        "request_schemas_by_operation", {}
    ).get("submitActionDecision", {})
    result.require(
        submit_request.get("fields", {}).get("providerOperationId")
        == "optional<ProviderControlOperationIdV1>"
        and "providerOperationId" not in submit_request.get("required", [])
        and submit_resource.get("fields", {}).get("providerOperationId")
        == "optional<ProviderControlOperationIdV1>@body"
        and any(
            "required iff actionKind=PROVIDER_CONTROL" in invariant
            for invariant in submit_resource.get("invariants", [])
        ),
        "submitActionDecision does not expose the conditional provider operation assurance discriminator",
    )
