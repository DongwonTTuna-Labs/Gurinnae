from __future__ import annotations

from pathlib import Path
import re
from typing import Any

from .loaders import load_yaml
from .models import Validation


_DONATION_PRODUCER_BINDINGS = [
    {
        "producer_operation": "private.ExecuteDonationCharge",
        "source_authority": "PROVIDER_FETCH_CONFIRMED",
        "owner_result_branch": "SUCCEEDED",
    },
    {
        "producer_operation": "private.ReceivePaymentWebhook",
        "source_authority": "PROVIDER_FETCH_CONFIRMED",
        "owner_result_branch": "SUCCEEDED",
    },
]
_PAYMENT_REVIEW_PRODUCER_BINDINGS = [
    {
        "producer": "billing-gateway",
        "producer_operation": "private.ReceivePaymentWebhook",
        "source_authority": "PROVIDER_FETCH_CONFIRMED",
        "sourceKind": "DONATION_PAYMENT_FAILURE",
    },
    {
        "producer": "workflow-worker.economics-import-executor",
        "producer_operation": "private.ExecuteEconomicsImport",
        "source_authority": "BANK_RETURN_CONFIRMED",
        "sourceKind": "SIGNED_COLLECTION_FAILURE",
    },
]
_OWNED_EVENT_FIELDS = {
    "donation.fact_recorded.v1": [
        "donationFactId",
        "donationFactDigest",
        "chargeAttemptId",
        "chargeAttemptDigest",
        "providerFetchDigest",
        "occurredAt",
    ],
    "notification.payment_review_requested.v1": [
        "reviewTaskId",
        "reviewTaskVersion",
        "reviewTaskDigest",
        "sourceKind",
        "sourceReceiptId",
        "sourceReceiptDigest",
        "occurredAt",
    ],
}
_REVIEW_SOURCE_KINDS = [
    "DONATION_PAYMENT_FAILURE",
    "SIGNED_COLLECTION_FAILURE",
]
_OWNED_EVENT_KEYS = {
    "event_type",
    "category",
    "schema_version",
    "payload_schema_uri",
    "payload_schema_path",
    "payload_schema_sha256",
    "embedded_json_equivalent",
    "fields_exactly",
}
_SIGNATURE = re.compile(
    r"^(?P<name>[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*)"
    r"\((?P<arguments>.*)\) RETURNS .+$"
)


def _routine_identity(signature: Any) -> str | None:
    match = _SIGNATURE.fullmatch(signature) if isinstance(signature, str) else None
    if match is None:
        return None
    arguments = match.group("arguments")
    if not arguments:
        return f'{match.group("name")}()'
    types: list[str] = []
    for argument in arguments.split(", "):
        parts = argument.split(" ", 1)
        if len(parts) != 2 or not parts[0].startswith("p_") or not parts[1]:
            return None
        types.append(parts[1])
    return f'{match.group("name")}({",".join(types)})'


def _funding_producer_bindings(
    contract: dict[str, Any],
) -> list[dict[str, str]] | None:
    delegation = contract.get("funding_snapshot_outer_producer_delegation", {})
    producers = delegation.get("outer_producers_in_order")
    if not isinstance(producers, list) or len(producers) != 2:
        return None
    logical_producers = [
        row.get("logical_producer") if isinstance(row, dict) else None
        for row in producers
    ]
    owner_functions = [
        _routine_identity(row.get("entry_routine_signature"))
        if isinstance(row, dict)
        else None
        for row in producers
    ]
    if not all(isinstance(value, str) and value for value in [
        *logical_producers,
        *owner_functions,
    ]):
        return None
    return [
        {
            "producer": "funding-importer",
            "logical_producer": logical_producers[0],
            "source_authority": "SIGNED_FUNDING_SOURCES",
            "owner_function": owner_functions[0],
            "audit_action": "IMPORT_FUNDING_SNAPSHOT",
        },
        {
            "producer": "funding-projector",
            "logical_producer": logical_producers[1],
            "source_authority": "AUTHENTICATED_DONATION_FACT",
            "owner_function": owner_functions[1],
            "audit_action": "DONATION_FUNDING_CANDIDATE_PROJECTED",
        },
    ]


def validate_r6e_product_event_provenance(
    root: Path,
    contract: dict[str, Any],
    result: Validation,
) -> None:
    events = load_yaml(
        root / "specs/product/addendum-event-contracts.yaml"
    ).get("events", {})
    if not isinstance(events, dict):
        result.error("0041 product event provenance registry is missing")
        return
    owned = contract.get("event_registry_contract", {}).get(
        "owned_events_in_order"
    )
    valid_owned = isinstance(owned, list) and len(owned) == 2
    result.require(
        valid_owned,
        "0041 owned event mirror must contain exactly two rows",
    )
    if valid_owned and isinstance(owned, list):
        for ordinal, row in enumerate(owned, start=1):
            event_type = row.get("event_type") if isinstance(row, dict) else None
            expected_keys = _OWNED_EVENT_KEYS | (
                {"source_kind_values"}
                if event_type == "notification.payment_review_requested.v1"
                else set()
            )
            product_event = events.get(event_type, {})
            result.require(
                isinstance(row, dict)
                and set(row) == expected_keys
                and list(_OWNED_EVENT_FIELDS)[ordinal - 1] == event_type
                and row.get("fields_exactly") == _OWNED_EVENT_FIELDS.get(event_type)
                and product_event.get("payload_required")
                == _OWNED_EVENT_FIELDS.get(event_type),
                f"0041 owned event mirror row {ordinal} differs",
            )
        review_row = owned[1] if isinstance(owned[1], dict) else {}
        review_event = events.get("notification.payment_review_requested.v1", {})
        review_enum = (
            review_event.get("payload_schema", {})
            .get("properties", {})
            .get("sourceKind", {})
            .get("enum")
        )
        result.require(
            review_row.get("source_kind_values") == _REVIEW_SOURCE_KINDS
            and review_enum == _REVIEW_SOURCE_KINDS,
            "0041 payment-review source-kind mirror differs",
        )
    donation = events.get("donation.fact_recorded.v1", {})
    result.require(
        donation.get("producer") == "billing-gateway"
        and donation.get("producer_operations")
        == ["private.ExecuteDonationCharge", "private.ReceivePaymentWebhook"]
        and donation.get("producer_bindings") == _DONATION_PRODUCER_BINDINGS,
        "0041 donation event producer provenance differs from the exact payment-owner pair",
    )
    review = events.get("notification.payment_review_requested.v1", {})
    result.require(
        review.get("producer")
        == "billing-gateway|workflow-worker.economics-import-executor"
        and review.get("producer_operations")
        == ["private.ReceivePaymentWebhook", "private.ExecuteEconomicsImport"]
        and review.get("producer_bindings") == _PAYMENT_REVIEW_PRODUCER_BINDINGS,
        "0041 payment-review event producer provenance differs",
    )
    funding = events.get("governance.funding_snapshot_created.v1", {})
    expected_funding_bindings = _funding_producer_bindings(contract)
    result.require(
        expected_funding_bindings is not None
        and funding.get("producer") == "funding-importer|funding-projector"
        and funding.get("producer_operations") == []
        and funding.get("producer_bindings") == expected_funding_bindings,
        "0041 funding snapshot product provenance differs from DB outer producers",
    )
