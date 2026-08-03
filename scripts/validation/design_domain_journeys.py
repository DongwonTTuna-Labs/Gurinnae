from __future__ import annotations

from typing import Any

from .design_support import DesignDocuments


JOURNEY_MACHINES = {"journey_instance", "journey_handoff", "journey_escalation"}
JOURNEY_EVENTS = {
    "journey.instance_started.v1",
    "journey.handoff_requested.v1",
    "journey.handoff_decided.v1",
    "journey.handoff_escalated.v1",
    "journey.handoff_expired.v1",
    "journey.outcome_recorded.v1",
}
JOURNEY_ROUTINES = {
    "ops.start_journey_instance_v1",
    "ops.request_journey_handoff_v1",
    "ops.decide_journey_handoff_v1",
    "ops.escalate_journey_handoff_v1",
    "ops.expire_journey_handoff_v1",
    "ops.record_journey_outcome_v1",
}
RECEIPT_KINDS = {
    "INSTANCE_STARTED",
    "HANDOFF_REQUESTED",
    "HANDOFF_ACKNOWLEDGED",
    "HANDOFF_DECLINED",
    "HANDOFF_ESCALATED",
    "HANDOFF_EXPIRED",
    "HANDOFF_CANCELLED",
    "HANDOFF_SUPERSEDED",
    "OUTCOME_RECORDED",
}
ESCALATION_STATES = ["NOT_DUE", "DUE", "ESCALATED", "RESOLVED"]
COMPOUND_BRANCHES = {
    "decline_with_replacement",
    "expiry_with_replacement",
    "supersession_with_replacement",
    "terminal_outcome_with_cancellation",
}
ESCALATION_EDGES = [
    {"id": "JE-01", "actor": "journey-coordinator", "from": "NONE", "to": "NOT_DUE", "guard": "exact-new-pending-handoff-generation-and-compiled-due-policy", "event": "journey.handoff_requested.v1", "receipt": "JourneyTransitionReceiptV1", "audit": "JOURNEY_HANDOFF_REQUESTED", "atomic_transition_group": "same-as-owning-handoff-request-step"},
    {"id": "JE-02", "actor": "journey-handoff-scheduler", "from": "NOT_DUE", "to": "DUE", "guard": "locked-current-pending-generation-and-database-clock-at-or-after-first-escalation-threshold-and-before-hard-expiry", "event": "journey.handoff_escalated.v1", "receipt": "JourneyTransitionReceiptV1", "audit": "JOURNEY_HANDOFF_ESCALATED", "atomic_transition_group": "journey-handoff-first-escalation"},
    {"id": "JE-03", "actor": "journey-handoff-scheduler", "from": "DUE", "to": "ESCALATED", "guard": "locked-current-pending-generation-and-database-clock-at-or-after-second-escalation-threshold-and-before-hard-expiry", "event": "journey.handoff_escalated.v1", "receipt": "JourneyTransitionReceiptV1", "audit": "JOURNEY_HANDOFF_ESCALATED", "atomic_transition_group": "journey-handoff-second-escalation"},
    {"id": "JE-04", "operation": "decideJourneyHandoff", "from": "NOT_DUE|DUE|ESCALATED", "to": "RESOLVED", "selector": "ACKNOWLEDGE|DECLINE", "guard": "same-locked-generation-as-the-terminal-decision-receipt", "event": "journey.handoff_decided.v1", "receipt": "JourneyTransitionReceiptV1", "audit": "JOURNEY_HANDOFF_DECIDED", "atomic_transition_group": "journey-handoff-decision"},
    {"id": "JE-05", "actor": "journey-handoff-scheduler", "from": "NOT_DUE|DUE|ESCALATED", "to": "RESOLVED", "guard": "same-locked-generation-as-the-HANDOFF_EXPIRED-receipt", "event": "journey.handoff_expired.v1", "receipt": "JourneyTransitionReceiptV1", "audit": "JOURNEY_HANDOFF_EXPIRED", "atomic_transition_group": "journey-handoff-expiry"},
    {"id": "JE-06", "actor": "journey-coordinator", "from": "NOT_DUE|DUE|ESCALATED", "to": "RESOLVED", "guard": "same-locked-generation-as-the-HANDOFF_CANCELLED-receipt", "event": "NONE", "receipt": "JourneyTransitionReceiptV1", "audit": "JOURNEY_HANDOFF_CANCELLED", "atomic_transition_group": "same-as-terminal-outcome-step"},
    {"id": "JE-07", "actor": "journey-coordinator", "from": "NOT_DUE|DUE|ESCALATED", "to": "RESOLVED", "guard": "same-locked-generation-as-the-HANDOFF_SUPERSEDED-receipt", "event": "NONE", "receipt": "JourneyTransitionReceiptV1", "audit": "JOURNEY_HANDOFF_SUPERSEDED", "atomic_transition_group": "same-as-replacement-request-step"},
]
STEP_ONE_COMMON = {
    "parent_from": "WAITING_ACK",
    "parent_to": "ACTIVE",
    "handoff_from": "PENDING_ACK",
    "escalation_to": "RESOLVED",
    "clear_active_handoff": True,
    "clear_next_owner": True,
    "preserve_current_owner": True,
}


def _validate_escalation(machine: dict[str, Any], result: Any) -> None:
    edges = machine.get("edges", [])
    edge_by_id = {edge.get("id"): edge for edge in edges}
    result.require(
        machine.get("states") == ESCALATION_STATES
        and machine.get("terminal") == ["RESOLVED"]
        and machine.get("identity") == "journey_instance_id+handoff_generation"
        and list(edge_by_id) == [f"JE-{index:02d}" for index in range(1, 8)]
        and len(edges) == len(edge_by_id) == 7,
        "journey_escalation state, identity or JE-01-through-JE-07 registry drifted",
    )
    result.require(
        edges == ESCALATION_EDGES,
        "journey_escalation full normalized edge rows drifted",
    )


def _validate_compound(machine: dict[str, Any], result: Any) -> None:
    branches = machine.get("compound_branches", {})
    rows = {key: value for key, value in branches.items() if key != "shared_invariants"}
    result.require(
        set(rows) == COMPOUND_BRANCHES
        and len(branches.get("shared_invariants", [])) == 3,
        "journey compound branch registry is not the exact four-branch contract",
    )
    for name, row in rows.items():
        first = row.get("step_1", {})
        second = row.get("step_2", {})
        expected_first = {
            **STEP_ONE_COMMON,
            "handoff_to": {
                "decline_with_replacement": "DECLINED",
                "expiry_with_replacement": "EXPIRED",
                "supersession_with_replacement": "SUPERSEDED",
                "terminal_outcome_with_cancellation": "CANCELLED",
            }[name],
            "receipt": {
                "decline_with_replacement": "HANDOFF_DECLINED",
                "expiry_with_replacement": "HANDOFF_EXPIRED",
                "supersession_with_replacement": "HANDOFF_SUPERSEDED",
                "terminal_outcome_with_cancellation": "HANDOFF_CANCELLED",
            }[name],
            "due_at": "compiled destination-node or terminal-policy SLA" if name == "terminal_outcome_with_cancellation" else "compiled replacement-origin node SLA checkpoint",
        }
        result.require(
            first == expected_first
            and second.get("parent_from") == "ACTIVE"
            and bool(second.get("due_at")),
            f"journey compound branch {name} does not expose the exact executable intermediate parent and due state",
        )
        if name != "terminal_outcome_with_cancellation":
            result.require(
                second == {"parent_from": "ACTIVE", "parent_to": "WAITING_ACK", "handoff_from": "NONE", "handoff_to": "PENDING_ACK", "receipt": "HANDOFF_REQUESTED", "escalation_to": "NOT_DUE", "generation_delta": 1, "set_active_handoff": True, "set_next_owner": True, "due_at": "first escalation threshold or immutable hard expiry"},
                f"journey compound branch {name} replacement step drifted",
            )
        else:
            result.require(
                second == {"parent_from": "ACTIVE", "parent_to": "exact compiled outcome state", "receipt": "OUTCOME_RECORDED", "active_handoff": None, "next_owner": None, "due_at": "same as step-1 resulting_due_at"},
                "journey terminal outcome compound second step drifted",
            )


def _validate_domain_binding(documents: DesignDocuments) -> None:
    result = documents.result
    binding = next(
        (row for row in documents.domain.get("bindings", []) if row.get("noun") == "JourneyCoordination"),
        {},
    )
    result.require(
        set(binding.get("relations", []))
        == {"ops.journey_instances", "ops.journey_handoffs", "ops.journey_transition_receipts"}
        and set(binding.get("machines", [])) == JOURNEY_MACHINES
        and set(binding.get("routines", [])) == JOURNEY_ROUTINES
        and set(binding.get("receipt_kinds", [])) == RECEIPT_KINDS
        and binding.get("escalation_states") == ESCALATION_STATES
        and set(binding.get("compound_branches", [])) == COMPOUND_BRANCHES
        and set(binding.get("events", [])) == JOURNEY_EVENTS,
        "JourneyCoordination domain closure is not exact across relations, machines, routines, receipts, escalation, compounds and events",
    )


def validate_journey_domain(documents: DesignDocuments) -> None:
    result = documents.result
    machines = documents.state_machines.get("machines", {})
    result.require(
        JOURNEY_MACHINES <= set(machines),
        "journey machine set is incomplete",
    )
    if not JOURNEY_MACHINES <= set(machines):
        return
    _validate_escalation(machines["journey_escalation"], result)
    _validate_compound(machines["journey_instance"], result)
    database_compounds = documents.physical_table_documents[
        "specs/database/addendum/0028-governance-operations.yaml"
    ].get("journey_compound_transition_contracts", {})
    superseded = [
        edge
        for edge in machines["journey_handoff"].get("edges", [])
        if edge.get("to") == "SUPERSEDED"
    ]
    result.require(
        COMPOUND_BRANCHES <= set(database_compounds)
        and len(COMPOUND_BRANCHES & set(database_compounds)) == 4
        and len(superseded) == 1
        and superseded[0].get("guard")
        == "generation-plus-one-replacement-created-only-by-the-exact-compiled-supersession-policy",
        "journey state/database compound IDs or supersession guard drifted",
    )
    machine_events = {
        edge.get("event")
        for name in JOURNEY_MACHINES
        for edge in machines[name].get("edges", [])
        if edge.get("event") != "NONE"
    }
    result.require(
        machine_events == JOURNEY_EVENTS
        and set(documents.state_machines.get("operation_dispositions", {}).get("decideJourneyHandoff", []))
        == JOURNEY_MACHINES,
        "journey machine event union or decideJourneyHandoff disposition set drifted",
    )
    _validate_domain_binding(documents)
