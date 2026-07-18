from __future__ import annotations

import hashlib
import json
from typing import Any

from .design_support import DesignDocuments


EVENT_FIELDS = {
    "journey.instance_started.v1": ["occurredAt", "journeyInstanceId", "journeyInstanceVersion", "journeyCode", "rootObjectKind", "rootObjectId", "rootObjectVersion", "rootObjectDigest", "currentNodeId", "currentOwnerBindingDigest", "nextDueAt", "receiptId", "receiptDigest"],
    "journey.handoff_requested.v1": ["occurredAt", "journeyInstanceId", "journeyInstanceVersion", "journeyCode", "edgeId", "handoffId", "handoffVersion", "handoffKind", "generation", "fromOwnerBindingDigest", "receiverBindingDigest", "subjectKind", "subjectId", "subjectVersion", "subjectDigest", "ackAuthorityKind", "ackAuthorityId", "hardExpiryAt", "nextSchedulerAt", "resultingEscalationState", "bindingDigest", "receiptId", "receiptDigest"],
    "journey.handoff_decided.v1": ["occurredAt", "journeyInstanceId", "journeyInstanceVersion", "journeyCode", "edgeId", "handoffId", "handoffVersion", "handoffKind", "generation", "decision", "resultingHandoffState", "resultingJourneyState", "priorEscalationState", "resultingEscalationState", "resultingNextDueAt", "currentOwnerBindingDigest", "nextOwnerBindingDigest", "effectDigest", "replacementHandoffId", "replacementRequestReceiptId", "replacementRequestReceiptDigest", "receiptId", "receiptDigest"],
    "journey.handoff_escalated.v1": ["occurredAt", "journeyInstanceId", "journeyInstanceVersion", "handoffId", "handoffVersion", "handoffKind", "generation", "priorEscalationState", "resultingEscalationState", "hardExpiryAt", "priorSchedulerAt", "nextSchedulerAt", "escalationOwnerBindingDigest", "receiptId", "receiptDigest"],
    "journey.handoff_expired.v1": ["occurredAt", "journeyInstanceId", "journeyInstanceVersion", "handoffId", "handoffVersion", "handoffKind", "generation", "hardExpiryAt", "priorEscalationState", "resultingEscalationState", "resultingNextDueAt", "resultingJourneyState", "replacementHandoffId", "replacementRequestReceiptId", "replacementRequestReceiptDigest", "receiptId", "receiptDigest"],
    "journey.outcome_recorded.v1": ["occurredAt", "journeyInstanceId", "journeyInstanceVersion", "journeyCode", "edgeId", "outcomeCode", "outcomeClass", "subjectKind", "subjectId", "subjectVersion", "subjectDigest", "effectDigest", "resultingJourneyState", "resultingNextDueAt", "receiptId", "receiptDigest"],
}
EVENT_PROPERTY_DIGESTS = {
    "journey.instance_started.v1": "af64e3b0a40df5ef6e06e7e63bc6ec261b19d9c9764576dd96682e76c7f70cba",
    "journey.handoff_requested.v1": "aca76715e23254fba882637046e564e7964a74670530bfde8dcdc035a0efc0d2",
    "journey.handoff_decided.v1": "11737ec369f30dcae55c9030950ec731f90a65c3f4060137ce8de745136029a8",
    "journey.handoff_escalated.v1": "9c19e845a248839018ae1848aa2ddc873b37c7028f1a09e58779b734059fc6c1",
    "journey.handoff_expired.v1": "c3959155476298be7b228bcedd8130f58613f972523a9254dbddd2d41032de6c",
    "journey.outcome_recorded.v1": "17fafa25b99afe8bd8a986fb2b2c584f5389410a141964ccb0a0f688c920f808",
}
PRODUCER_ROUTINES = {
    "journey.instance_started.v1": ["ops.start_journey_instance_v1"],
    "journey.handoff_requested.v1": ["ops.request_journey_handoff_v1", "ops.decide_journey_handoff_v1", "ops.expire_journey_handoff_v1"],
    "journey.handoff_decided.v1": ["ops.decide_journey_handoff_v1"],
    "journey.handoff_escalated.v1": ["ops.escalate_journey_handoff_v1"],
    "journey.handoff_expired.v1": ["ops.expire_journey_handoff_v1"],
    "journey.outcome_recorded.v1": ["ops.record_journey_outcome_v1"],
}
CONSUMERS = {"journey-projector", "operations-projector", "audit-indexer"}
PRODUCER_META = {
    "journey.instance_started.v1": ("journey-coordinator", []),
    "journey.handoff_requested.v1": ("journey-coordinator", []),
    "journey.handoff_decided.v1": ("journey-coordinator", ["decideJourneyHandoff"]),
    "journey.handoff_escalated.v1": ("journey-handoff-scheduler", []),
    "journey.handoff_expired.v1": ("journey-handoff-scheduler", []),
    "journey.outcome_recorded.v1": ("journey-coordinator", []),
}
DUE_BINDINGS = {
    "journey.instance_started.v1": "nextDueAt equals the persisted ops.journey_instances.due_at at this receipt version",
    "journey.handoff_requested.v1": "hardExpiryAt equals immutable ops.journey_handoffs.due_at; nextSchedulerAt equals the receipt resulting_due_at and persisted parent instance due_at; resultingEscalationState is NOT_DUE",
    "journey.handoff_decided.v1": "resultingNextDueAt equals the terminal decision receipt resulting_due_at and the persisted step-one parent due_at; when replacement exists, its later journey.handoff_requested.v1 nextSchedulerAt is the distinct step-two parent scheduler value",
    "journey.handoff_escalated.v1": "hardExpiryAt is immutable; priorSchedulerAt and nextSchedulerAt equal receipt prior_due_at and resulting_due_at and nextSchedulerAt equals persisted parent instance due_at",
    "journey.handoff_expired.v1": "hardExpiryAt equals immutable old handoff.due_at and resultingNextDueAt equals the expiry receipt resulting_due_at and persisted step-one parent due_at; a replacement requested event carries the distinct step-two nextSchedulerAt",
    "journey.outcome_recorded.v1": "resultingNextDueAt equals the persisted parent due_at at the OUTCOME_RECORDED receipt version",
}


def _enum(contract: dict[str, Any], field: str) -> list[str]:
    value = contract["payload_schema"]["properties"][field]
    return list(value.get("enum", [])) if isinstance(value, dict) else []


def _property_digest(contract: dict[str, Any]) -> str:
    properties = contract.get("payload_schema", {}).get("properties", {})
    encoded = json.dumps(
        properties,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _validate_runtime_registry(documents: DesignDocuments) -> None:
    result = documents.result
    runtime = documents.event_contracts.get("journey_event_runtime_contract", {})
    result.require(
        set(runtime.get("events", [])) == set(EVENT_FIELDS)
        and set(runtime.get("producers", []))
        == {routine for rows in PRODUCER_ROUTINES.values() for routine in rows}
        and set(runtime.get("consumers", [])) == CONSUMERS
        and runtime.get("envelope_rule") == "eventId exists only in the canonical event envelope and is forbidden from every payload required or properties set"
        and runtime.get("reconstruction_rule") == "immutable receipt IDs and digests plus explicit nullable replacement receipt identities reconstruct every applied instance version without reading a mutable parent or handoff head"
        and runtime.get("ordering_rule") == "aggregate version equals receipt journey_instance_version and receipt sequence; a compound branch emits two consecutive versions and consumers park gaps rather than collapsing the steps",
        "journey event runtime registry is incomplete or not exact",
    )


def _validate_escalation_values(events: dict[str, Any], result: Any) -> None:
    requested = events["journey.handoff_requested.v1"]
    decided = events["journey.handoff_decided.v1"]
    escalated = events["journey.handoff_escalated.v1"]
    expired = events["journey.handoff_expired.v1"]
    result.require(
        _enum(requested, "resultingEscalationState") == ["NOT_DUE"]
        and _enum(decided, "priorEscalationState") == ["NOT_DUE", "DUE", "ESCALATED"]
        and _enum(decided, "resultingEscalationState") == ["RESOLVED"]
        and _enum(escalated, "priorEscalationState") == ["NOT_DUE", "DUE"]
        and _enum(escalated, "resultingEscalationState") == ["DUE", "ESCALATED"]
        and _enum(expired, "priorEscalationState") == ["NOT_DUE", "DUE", "ESCALATED"]
        and _enum(expired, "resultingEscalationState") == ["RESOLVED"]
        and "NONE" not in json.dumps(
            [events[name]["payload_schema"] for name in EVENT_FIELDS],
            sort_keys=True,
        ),
        "journey event escalation vocabulary is not exactly NOT_DUE/DUE/ESCALATED/RESOLVED",
    )


def _validate_replacement_shapes(events: dict[str, Any], result: Any) -> None:
    for name in ("journey.handoff_decided.v1", "journey.handoff_expired.v1"):
        contract = events[name]
        properties = contract["payload_schema"]["properties"]
        nullable = {
            field
            for field in ("replacementHandoffId", "replacementRequestReceiptId", "replacementRequestReceiptDigest")
            if isinstance(properties.get(field), dict)
            and any(branch.get("type") == "null" for branch in properties[field].get("oneOf", []) if isinstance(branch, dict))
        }
        result.require(
            len(nullable) == 3
            and "all null or all nonnull" in str(contract.get("replacement_shape", "")),
            f"{name}: replacement receipt identity is not one closed nullable group",
        )


def _validate_due_types(events: dict[str, Any], result: Any) -> None:
    refs = {
        "journey.instance_started.v1": ["nextDueAt"],
        "journey.handoff_requested.v1": ["hardExpiryAt", "nextSchedulerAt"],
        "journey.handoff_decided.v1": ["resultingNextDueAt"],
        "journey.handoff_escalated.v1": ["hardExpiryAt", "priorSchedulerAt", "nextSchedulerAt"],
        "journey.handoff_expired.v1": ["hardExpiryAt", "resultingNextDueAt"],
        "journey.outcome_recorded.v1": ["resultingNextDueAt"],
    }
    for name, fields in refs.items():
        properties = events[name]["payload_schema"]["properties"]
        result.require(
            all(properties.get(field) == {"$ref": "#/$defs/datetime"} for field in fields),
            f"{name}: journey due/scheduler fields are not exact required datetimes",
        )
        if DUE_BINDINGS[name] is not None:
            result.require(
                events[name].get("due_binding") == DUE_BINDINGS[name],
                f"{name}: journey due-time receipt/parent binding drifted",
            )


def _validate_decision_idempotency_event(events: dict[str, Any], result: Any) -> None:
    decided = events["journey.handoff_decided.v1"]
    binding = decided.get("business_idempotency_binding", {})
    forbidden = ["requestId", "actorAssertionJti", "serviceAssertionJti", "assertionTokenBytes", "wireRequestDigest", "reasonEncrypted", "plaintextReason"]
    fields = set(decided.get("payload_schema", {}).get("properties", {}))
    result.require(
        binding.get("forbidden_payload_fields") == forbidden
        and not fields.intersection(forbidden)
        and "NEW prepared business claim only" in str(binding.get("emission", ""))
        and "FINAL_REPLAY" in str(binding.get("emission", ""))
        and "JOURNEY_HANDOFF_DECISION_BUSINESS_V1" in str(binding.get("effect_digest", ""))
        and "randomized ciphertext" in str(binding.get("effect_digest", "")),
        "journey.handoff_decided.v1 leaks attempt identity or is not NEW-only business-bound",
    )


def validate_journey_events(documents: DesignDocuments) -> None:
    result = documents.result
    events = documents.event_contracts.get("events", {})
    result.require(set(EVENT_FIELDS) <= set(events), "journey event set is incomplete")
    if not set(EVENT_FIELDS) <= set(events):
        return
    for name, fields in EVENT_FIELDS.items():
        contract = events[name]
        result.require(
            contract.get("payload_required") == fields
            and contract.get("payload_schema", {}).get("required") == fields
            and list(contract.get("payload_schema", {}).get("properties", {})) == fields
            and contract.get("producer_routines") == PRODUCER_ROUTINES[name]
            and (contract.get("producer"), contract.get("producer_operations"))
            == PRODUCER_META[name]
            and set(contract.get("consumers", [])) == CONSUMERS
            and {row.get("consumer") for row in contract.get("consumer_bindings", [])} == CONSUMERS
            and _property_digest(contract) == EVENT_PROPERTY_DIGESTS[name],
            f"{name}: payload order, producer routines or consumers drifted",
        )
    _validate_runtime_registry(documents)
    _validate_escalation_values(events, result)
    _validate_replacement_shapes(events, result)
    _validate_due_types(events, result)
    _validate_decision_idempotency_event(events, result)
