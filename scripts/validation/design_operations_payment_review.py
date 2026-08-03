from __future__ import annotations

from .design_support import DesignDocuments


PAYMENT_REVIEW_PRODUCERS = {
    "private.ExecuteEconomicsImport": {
        "source_authority": "BANK_RETURN_CONFIRMED",
        "source_kind": "SIGNED_COLLECTION_FAILURE",
    },
    "private.ExecuteDonationCharge": {
        "source_authority": "PROVIDER_FETCH_CONFIRMED",
        "source_kind": "DONATION_PAYMENT_FAILURE",
    },
    "private.ReceivePaymentWebhook": {
        "source_authority": "PROVIDER_FETCH_CONFIRMED",
        "source_kind": "DONATION_PAYMENT_FAILURE",
    },
}


def validate_payment_review_cross_effect(documents: DesignDocuments) -> None:
    states = documents.state_machines
    task = states.get("machines", {}).get("task", {})
    task_reference = task.get("cross_effect_references", {}).get(
        "payment_review", {}
    )
    registry = states.get("payment_review_task_cross_effect_bindings", {})
    task_edges = task.get("edges", []) if isinstance(task, dict) else []
    documents.result.require(
        task_reference.get("producer_source_map") == PAYMENT_REVIEW_PRODUCERS
        and registry.get("producers_exactly") == PAYMENT_REVIEW_PRODUCERS
        and registry.get("authority")
        == "machines.task.cross_effect_references.payment_review"
        and all(
            edge.get("private_command") not in PAYMENT_REVIEW_PRODUCERS
            and edge.get("private_billing_operation") not in PAYMENT_REVIEW_PRODUCERS
            for edge in task_edges
            if isinstance(edge, dict)
        ),
        (
            "payment review task source mapping must reference, not duplicate, "
            "task lifecycle authority"
        ),
    )
    events = documents.event_contracts.get("events", {})
    documents.result.require(
        events.get("donation.fact_recorded.v1", {}).get("producer_operations")
        == ["private.ExecuteDonationCharge", "private.ReceivePaymentWebhook"]
        and events.get("notification.payment_review_requested.v1", {}).get(
            "producer_operations"
        )
        == ["private.ReceivePaymentWebhook", "private.ExecuteEconomicsImport"],
        "payment fact or review event producer set differs from the source lifecycle",
    )
