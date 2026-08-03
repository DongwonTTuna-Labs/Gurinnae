from __future__ import annotations

from typing import Any

from .design_support import DesignDocuments


CORE_PAYMENT_RELATIONS = [
    "ops.payment_method_bindings",
    "ops.payment_charge_attempts",
    "ops.donation_facts",
]
AUXILIARY_PAYMENT_RELATIONS = ["ops.tasks", "ops.audit_events", "ops.outbox"]

CHARGE_LIFECYCLE_CONTRACT = {
    "core_target_relations": CORE_PAYMENT_RELATIONS,
    "auxiliary_relations": AUXILIARY_PAYMENT_RELATIONS,
    "success_binding_transitions": {
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
    },
    "success_atomicity": (
        "the definitive SUCCEEDED charge attempt, donation fact and "
        "credential-use-policy-selected binding transition commit in one "
        "payment-owner transaction; only SINGLE_CHARGE appends the ACTIVE to "
        "REVOKED consumption transition"
    ),
    "recurring_scheduler_owner": "ops.enqueue_due_r6e_donation_charge_jobs_v1",
    "local_reject_terminal_owner": "ops.fail_r6e_donation_charge_v1",
    "failure_outcomes": {
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
    },
    "non_success_rule": (
        "replay, reconciliation and every failure append no second binding "
        "consumption and authorize no automatic resubmission, new logical "
        "charge or new idempotency identity"
    ),
    "authority_effects": (
        "entitlement, access, investigation-priority, publication-priority "
        "and public-readiness effects are always zero"
    ),
}


def _valid_database_blockers(row: Any) -> bool:
    if (
        not isinstance(row, dict)
        or row.get("source_contract_status")
        != "SOURCE_ONLY_DATABASE_FINAL_BLOCKED"
    ):
        return False
    blockers = row.get("database_final_blockers")
    if not isinstance(blockers, list) or len(blockers) < 3:
        return False
    text = " ".join(item for item in blockers if isinstance(item, str)).lower()
    return (
        len(blockers)
        == sum(isinstance(item, str) and bool(item.strip()) for item in blockers)
        and "signature" in text
        and "security definer" in text
        and "lock order" in text
        and "status" in text
        and "atomic" in text
    )


def validate_payment_persistence_source_boundary(
    documents: DesignDocuments,
) -> None:
    registry = documents.persistence_contracts.get("exact_persistence_registry", {})
    application = registry.get("private_application_command_persistence", {})
    billing = registry.get("private_billing_gateway_persistence", {})
    economics = application.get("private.ExecuteEconomicsImport", {})
    charge = application.get("private.ExecuteDonationCharge", {})
    offer = billing.get("private.GetDonationFixtureOffer", {})
    queue = billing.get("private.QueueDonationIntent", {})
    webhook = billing.get("private.ReceivePaymentWebhook", {})
    operation_charge = documents.operation_contracts.get(
        "private_application_commands", {}
    ).get("private.ExecuteDonationCharge", {})
    command_charge = documents.command_semantics.get(
        "private_application_commands", {}
    ).get("private.ExecuteDonationCharge", {})
    resource_charge = documents.resource_error_contracts.get(
        "private_application_command_bindings", {}
    ).get("private.ExecuteDonationCharge", {})
    documents.result.require(
        _valid_database_blockers(economics)
        and economics.get("target_relation_registry")
        == "economics_import_effect_disposition_registry.variants"
        and economics.get("terminal_contract") == "economics_import_terminal_contract",
        "economics source-only persistence row or database-final blockers are incomplete",
    )
    documents.result.require(
        _valid_database_blockers(charge)
        and charge.get("core_target_relations") == CORE_PAYMENT_RELATIONS
        and charge.get("auxiliary_relations") == AUXILIARY_PAYMENT_RELATIONS
        and charge.get("lifecycle_contract") == CHARGE_LIFECYCLE_CONTRACT
        and operation_charge.get("lifecycle_contract")
        == CHARGE_LIFECYCLE_CONTRACT
        and command_charge.get("lifecycle_contract") == CHARGE_LIFECYCLE_CONTRACT
        and resource_charge.get("lifecycle_contract")
        == CHARGE_LIFECYCLE_CONTRACT
        and charge.get("recurring_scheduler", {}).get("owner_function")
        == "ops.enqueue_due_r6e_donation_charge_jobs_v1"
        and "ops.fail_r6e_donation_charge_v1"
        in " ".join(charge.get("transaction_phases", [])),
        "donation charge source-only persistence boundary is incomplete",
    )
    documents.result.require(
        offer.get("source_contract_status") == "SOURCE_CONFIRMED"
        and offer.get("operation_kind") == "QUERY"
        and offer.get("relations") == ["ops.assertion_replay_guard"]
        and offer.get("writes")
        == (
            "exactly one authorization replay-guard consume on a fresh valid "
            "assertion and zero business-state writes"
        ),
        "donation fixture query persistence is not the exact non-domain query contract",
    )
    documents.result.require(
        _valid_database_blockers(queue)
        and queue.get("core_target_relations") == ["ops.payment_method_bindings"]
        and queue.get("authorization_relations") == ["ops.assertion_replay_guard"]
        and queue.get("auxiliary_relations") == ["ops.jobs", "ops.audit_events"],
        "donation intent source-only persistence boundary is incomplete",
    )
    documents.result.require(
        _valid_database_blockers(webhook)
        and webhook.get("core_target_relations") == CORE_PAYMENT_RELATIONS
        and webhook.get("auxiliary_relations") == AUXILIARY_PAYMENT_RELATIONS
        and webhook.get("authorization_relations") == ["ops.assertion_replay_guard"]
        and webhook.get("webhook_relation") == "ops.provider_webhook_receipts",
        "payment webhook source-only persistence boundary is incomplete",
    )
