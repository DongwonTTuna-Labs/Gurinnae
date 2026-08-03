from __future__ import annotations

from .design_support import DesignDocuments
from .loaders import load_yaml


OUTER_FIELDS = [
    ("schemaVersion", "const<journey-handoff-decision-receipt.v1>"),
    ("command", "CommandReceiptV1"),
    ("decisionReceipt", "JourneyHandoffTerminalReceiptV1"),
    ("replacement", "nullable<JourneyHandoffReplacementReceiptV1>"),
    ("finalParent", "JourneyInstanceHeadReceiptV1"),
    ("effectDigest", "sha256"),
    ("decidedAt", "datetime"),
]
REQUEST_FIELDS = [
    "schemaVersion",
    "handoffId",
    "expectedHandoffVersion",
    "expectedBindingDigest",
    "decision",
    "reasonCode",
    "reason",
]


def validate_journey_ui_contracts(
    actions: dict,
    effective: dict,
    result,
) -> None:
    commands = [
        row
        for row in actions.get("commands", [])
        if row.get("operation_id") == "decideJourneyHandoff"
    ]
    result.require(
        len(commands) == 1,
        "decideJourneyHandoff must have one canonical UI command contract",
    )
    if len(commands) != 1:
        return
    command = commands[0]
    request_fields = command.get("request_field_set", [])
    receipt_fields = command.get("receipt_field_set", [])
    result.require(
        [row.get("name") for row in request_fields] == REQUEST_FIELDS
        and all(row.get("required") is True for row in request_fields)
        and [(row.get("name"), row.get("type")) for row in receipt_fields]
        == OUTER_FIELDS
        and all(row.get("required") is True for row in receipt_fields),
        "decideJourneyHandoff UI request or nested receipt field set drifted",
    )
    placements = command.get("placements", [])
    screen = next(
        (row for row in effective.get("screens", []) if row.get("screen_id") == "INT-002"),
        {},
    )
    effective_rows = [
        row
        for row in screen.get("operation_field_contracts", [])
        if row.get("operation_id") == "decideJourneyHandoff"
    ]
    result.require(
        command.get("receipt_render_order")
        == ["decisionReceipt", "replacement", "finalParent"]
        and command.get("success_focus_source") == "finalParent heading"
        and "receiver identity bytes" in str(command.get("success_receipt_rule", ""))
        and len(placements) == 1
        and placements[0].get("screen_id") == "INT-002"
        and placements[0].get("section_id") == "handoff"
        and placements[0].get("success_destination", {}).get("receipt_focus_test_id"),
        "decideJourneyHandoff UI render order, final-parent focus, privacy or placement drifted",
    )
    result.require(
        len(effective_rows) == 1
        and effective_rows[0].get("response_schema") == "JourneyHandoffDecisionReceiptV1"
        and [(row.get("name"), row.get("type")) for row in effective_rows[0].get("response_field_set", [])]
        == OUTER_FIELDS
        and effective_rows[0].get("section_binding") == "handoff"
        and placements[0].get("success_destination", {}).get("section_heading_test_id")
        == next((row.get("test_id") for row in screen.get("sections", []) if row.get("section_id") == "handoff"), None)
        and placements[0].get("success_destination", {}).get("receipt_focus_test_id")
        == "int_002__receipt__handle__int_002__decide_journey_handoff__handoff__heading",
        "INT-002 effective response, handoff section or final-parent receipt focus parity drifted",
    )


def validate_journey_ui(documents: DesignDocuments) -> None:
    validate_journey_ui_contracts(
        load_yaml(documents.root / "specs/ui/screen-action-contracts.yaml"),
        load_yaml(documents.root / "specs/ui/effective-screen-contracts.yaml"),
        documents.result,
    )
