from __future__ import annotations

"""Exact payment state-machine and lifecycle-binding validation."""

from typing import Any

from .design_support import DesignDocuments


PAYMENT_MACHINE_SHAPES = {
    "payment_method_binding": (
        ("PENDING_PROVIDER", "ACTIVE", "FAILED", "REVOKED"),
        ("FAILED", "REVOKED"),
    ),
    "payment_charge_attempt": (
        (
            "REQUESTED",
            "PROVIDER_ACCEPTED",
            "SUCCEEDED",
            "FAILED",
            "RECONCILIATION_REQUIRED",
            "REFUNDED",
        ),
        ("FAILED", "REFUNDED"),
    ),
    "provider_webhook_receipt": (
        ("CLAIMED", "FETCH_CONFIRMED", "RELEASED"),
        ("FETCH_CONFIRMED",),
    ),
    "donation_fact": (
        ("ORIGINAL", "REPLACEMENT", "REVERSAL"),
        ("REVERSAL",),
    ),
}

PAYMENT_EDGE_SIGNATURES = {
    "payment_method_binding": {
        (
            "private_billing_operation",
            "private.QueueDonationIntent",
            "payment_method_binding.QUEUE_DONATION_INTENT",
            "NONE",
            "PENDING_PROVIDER",
            "TEST_ONLY fresh exact intent claim",
            "NONE",
        ),
        (
            "private_billing_operation",
            "private.QueueDonationIntent",
            "payment_method_binding.QUEUE_DONATION_INTENT",
            "PENDING_PROVIDER",
            "ACTIVE",
            "provider billing-key issuance and vault persistence both definitively succeeded",
            "NONE",
        ),
        (
            "private_billing_operation",
            "private.QueueDonationIntent",
            "payment_method_binding.QUEUE_DONATION_INTENT",
            "PENDING_PROVIDER",
            "FAILED",
            "definitive local issuance or vault failure",
            "NONE",
        ),
        (
            "private_command",
            "private.ExecuteDonationCharge",
            "payment_method_binding.EXECUTE_DONATION_CHARGE",
            "ACTIVE",
            "ACTIVE",
            "RECURRING and PROVIDER_FETCH_CONFIRMED SUCCEEDED",
            "donation.fact_recorded.v1",
        ),
        (
            "private_command",
            "private.ExecuteDonationCharge",
            "payment_method_binding.EXECUTE_DONATION_CHARGE",
            "ACTIVE",
            "REVOKED",
            "SINGLE_CHARGE and PROVIDER_FETCH_CONFIRMED SUCCEEDED",
            "donation.fact_recorded.v1",
        ),
        (
            "private_billing_operation",
            "private.ReceivePaymentWebhook",
            "payment_method_binding.RECEIVE_PAYMENT_WEBHOOK",
            "ACTIVE",
            "ACTIVE",
            "RECURRING and PROVIDER_FETCH_CONFIRMED SUCCEEDED",
            "donation.fact_recorded.v1",
        ),
        (
            "private_billing_operation",
            "private.ReceivePaymentWebhook",
            "payment_method_binding.RECEIVE_PAYMENT_WEBHOOK",
            "ACTIVE",
            "REVOKED",
            "SINGLE_CHARGE and PROVIDER_FETCH_CONFIRMED SUCCEEDED",
            "donation.fact_recorded.v1",
        ),
    },
    "payment_charge_attempt": {
        (
            "private_command",
            "private.ExecuteDonationCharge",
            "payment_charge_attempt.EXECUTE_DONATION_CHARGE",
            "NONE",
            "REQUESTED",
            "fresh current DONATION_CHARGE job claim",
            "NONE",
        ),
        (
            "private_command",
            "private.ExecuteDonationCharge",
            "payment_charge_attempt.EXECUTE_DONATION_CHARGE",
            "REQUESTED",
            "PROVIDER_ACCEPTED",
            "definitive provider charge acceptance",
            "NONE",
        ),
        (
            "private_command",
            "private.ExecuteDonationCharge",
            "payment_charge_attempt.EXECUTE_DONATION_CHARGE",
            "REQUESTED",
            "FAILED",
            "definitive local pre-dispatch rejection",
            "NONE",
        ),
        (
            "private_command",
            "private.ExecuteDonationCharge",
            "payment_charge_attempt.EXECUTE_DONATION_CHARGE",
            "REQUESTED|PROVIDER_ACCEPTED",
            "RECONCILIATION_REQUIRED",
            (
                "charge outcome unknown, fetch unavailable, fetched PENDING "
                "or fetched PARTIALLY_REFUNDED"
            ),
            "NONE",
        ),
        (
            "private_command",
            "private.ExecuteDonationCharge",
            "payment_charge_attempt.EXECUTE_DONATION_CHARGE",
            "PROVIDER_ACCEPTED",
            "SUCCEEDED",
            "PROVIDER_FETCH_CONFIRMED SUCCEEDED",
            "donation.fact_recorded.v1",
        ),
        (
            "private_command",
            "private.ExecuteDonationCharge",
            "payment_charge_attempt.EXECUTE_DONATION_CHARGE",
            "PROVIDER_ACCEPTED",
            "FAILED",
            "PROVIDER_FETCH_CONFIRMED FAILED or CANCELED",
            "notification.payment_review_requested.v1",
        ),
        (
            "private_billing_operation",
            "private.ReceivePaymentWebhook",
            "payment_charge_attempt.RECEIVE_PAYMENT_WEBHOOK",
            "REQUESTED|PROVIDER_ACCEPTED|RECONCILIATION_REQUIRED",
            "SUCCEEDED",
            "PROVIDER_FETCH_CONFIRMED SUCCEEDED",
            "donation.fact_recorded.v1",
        ),
        (
            "private_billing_operation",
            "private.ReceivePaymentWebhook",
            "payment_charge_attempt.RECEIVE_PAYMENT_WEBHOOK",
            "REQUESTED|PROVIDER_ACCEPTED|RECONCILIATION_REQUIRED",
            "FAILED",
            "PROVIDER_FETCH_CONFIRMED FAILED or CANCELED",
            "notification.payment_review_requested.v1",
        ),
        (
            "private_billing_operation",
            "private.ReceivePaymentWebhook",
            "payment_charge_attempt.RECEIVE_PAYMENT_WEBHOOK",
            "REQUESTED|PROVIDER_ACCEPTED|RECONCILIATION_REQUIRED",
            "RECONCILIATION_REQUIRED",
            "PROVIDER_FETCH_CONFIRMED PENDING or PARTIALLY_REFUNDED",
            "NONE",
        ),
        (
            "private_billing_operation",
            "private.ReceivePaymentWebhook",
            "payment_charge_attempt.RECEIVE_PAYMENT_WEBHOOK",
            "SUCCEEDED",
            "REFUNDED",
            "PROVIDER_FETCH_CONFIRMED full REFUNDED",
            "donation.fact_recorded.v1",
        ),
    },
    "provider_webhook_receipt": {
        (
            "private_billing_operation",
            "private.ReceivePaymentWebhook",
            "provider_webhook_receipt.RECEIVE_PAYMENT_WEBHOOK",
            "NONE",
            "CLAIMED",
            "fresh authenticated TEST_ONLY provider event identity",
            "NONE",
        ),
        (
            "private_billing_operation",
            "private.ReceivePaymentWebhook",
            "provider_webhook_receipt.RECEIVE_PAYMENT_WEBHOOK",
            "CLAIMED",
            "FETCH_CONFIRMED",
            "authoritative provider fetch returned a closed observation",
            "NONE",
        ),
        (
            "private_billing_operation",
            "private.ReceivePaymentWebhook",
            "provider_webhook_receipt.RECEIVE_PAYMENT_WEBHOOK",
            "CLAIMED",
            "RELEASED",
            "provider fetch or required authentication dependency unavailable",
            "NONE",
        ),
        (
            "private_billing_operation",
            "private.ReceivePaymentWebhook",
            "provider_webhook_receipt.RECEIVE_PAYMENT_WEBHOOK",
            "RELEASED",
            "CLAIMED",
            "identical authenticated hint reclaim",
            "NONE",
        ),
    },
    "donation_fact": {
        (
            "private_command",
            "private.ExecuteDonationCharge",
            "donation_fact.EXECUTE_DONATION_CHARGE",
            "NONE",
            "ORIGINAL",
            "PROVIDER_FETCH_CONFIRMED SUCCEEDED and no existing fact",
            "donation.fact_recorded.v1",
        ),
        (
            "private_billing_operation",
            "private.ReceivePaymentWebhook",
            "donation_fact.RECEIVE_PAYMENT_WEBHOOK",
            "NONE",
            "ORIGINAL",
            "PROVIDER_FETCH_CONFIRMED SUCCEEDED and no existing fact",
            "donation.fact_recorded.v1",
        ),
        (
            "private_billing_operation",
            "private.ReceivePaymentWebhook",
            "donation_fact.RECEIVE_PAYMENT_WEBHOOK",
            "ORIGINAL|REPLACEMENT",
            "REVERSAL",
            "PROVIDER_FETCH_CONFIRMED full REFUNDED",
            "donation.fact_recorded.v1",
        ),
    },
}

APPLICATION_BINDING = {
    "private.ExecuteDonationCharge": [
        "payment_method_binding.EXECUTE_DONATION_CHARGE",
        "payment_charge_attempt.EXECUTE_DONATION_CHARGE",
        "donation_fact.EXECUTE_DONATION_CHARGE",
    ]
}

BILLING_QUERY_DISPOSITIONS = {
    "private.GetDonationFixtureOffer": "NON_STATE_QUERY",
}

BILLING_COMMAND_BINDINGS = {
    "private.QueueDonationIntent": [
        "payment_method_binding.QUEUE_DONATION_INTENT",
    ],
    "private.ReceivePaymentWebhook": [
        "payment_method_binding.RECEIVE_PAYMENT_WEBHOOK",
        "payment_charge_attempt.RECEIVE_PAYMENT_WEBHOOK",
        "provider_webhook_receipt.RECEIVE_PAYMENT_WEBHOOK",
        "donation_fact.RECEIVE_PAYMENT_WEBHOOK",
    ],
}

def _edge_signature(edge: dict[str, Any]) -> tuple[Any, ...]:
    operation_fields = [
        field
        for field in ("private_command", "private_billing_operation")
        if field in edge
    ]
    if len(operation_fields) != 1:
        return (None, None, None, None, None, None, None)
    field = operation_fields[0]
    return (
        field,
        edge.get(field),
        edge.get("lifecycle_binding"),
        edge.get("from"),
        edge.get("to"),
        edge.get("selector"),
        edge.get("event"),
    )


def _validate_machine_closure(documents: DesignDocuments) -> None:
    machines = documents.state_machines.get("machines", {})
    for name, (states, terminal) in PAYMENT_MACHINE_SHAPES.items():
        machine = machines.get(name, {})
        edges = machine.get("edges", []) if isinstance(machine, dict) else []
        actual_edges = {
            _edge_signature(edge) for edge in edges if isinstance(edge, dict)
        }
        documents.result.require(
            tuple(machine.get("states", [])) == states
            and tuple(machine.get("terminal", [])) == terminal
            and len(edges) == len(actual_edges) == len(PAYMENT_EDGE_SIGNATURES[name])
            and actual_edges == PAYMENT_EDGE_SIGNATURES[name],
            f"{name} is not the exact source-authorized payment lifecycle",
        )


def _edge_bindings_by_operation(
    documents: DesignDocuments, operation_field: str
) -> dict[str, set[str]]:
    bindings: dict[str, set[str]] = {}
    for machine in documents.state_machines.get("machines", {}).values():
        if not isinstance(machine, dict):
            continue
        for edge in machine.get("edges", []):
            if not isinstance(edge, dict) or operation_field not in edge:
                continue
            operation = edge.get(operation_field)
            binding = edge.get("lifecycle_binding")
            if isinstance(operation, str) and isinstance(binding, str):
                bindings.setdefault(operation, set()).add(binding)
    return bindings


def _validate_lifecycle_bindings(documents: DesignDocuments) -> None:
    states = documents.state_machines
    application = states.get("private_application_lifecycle_bindings", {}).get(
        "current_bindings", {}
    )
    billing = states.get("private_billing_gateway_lifecycle_bindings", {})
    command_edges = _edge_bindings_by_operation(documents, "private_command")
    billing_edges = _edge_bindings_by_operation(
        documents, "private_billing_operation"
    )
    documents.result.require(
        all(application.get(key) == value for key, value in APPLICATION_BINDING.items())
        and all(command_edges.get(key) == set(value) for key, value in APPLICATION_BINDING.items()),
        "private.ExecuteDonationCharge lifecycle bindings are not set-equal to payment edges",
    )
    documents.result.require(
        billing.get("query_dispositions") == BILLING_QUERY_DISPOSITIONS
        and billing.get("current_bindings") == BILLING_COMMAND_BINDINGS
        and all(
            billing_edges.get(key) == set(value)
            for key, value in BILLING_COMMAND_BINDINGS.items()
        )
        and "private.GetDonationFixtureOffer" not in billing_edges,
        "private billing query and command lifecycle bindings are not exact",
    )


def validate_payment_lifecycle_contracts(documents: DesignDocuments) -> None:
    _validate_machine_closure(documents)
    _validate_lifecycle_bindings(documents)
