from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .design_operations import OperationFacts
from .design_lifecycle_journeys import validate_journey_events
from .design_support import DesignDocuments, nonempty, unique_string_registry


@dataclass(frozen=True)
class LifecycleFacts:
    event_type_set: set[str]
    contracted_event_types: set[str]
    base_event_types: set[str]
    search: dict[str, Any]


def validate_lifecycle(
    documents: DesignDocuments,
    operations: OperationFacts,
) -> LifecycleFacts:
    result = documents.result
    addendum = documents.addendum
    event_contracts = documents.event_contracts
    base_event_catalog = documents.base_event_catalog
    role_contract = documents.role_contract
    production_topology = documents.production_topology
    operation_contracts = documents.operation_contracts
    approval_policy = documents.approval_policy
    base_operation_catalog = documents.base_operation_catalog
    validate_journey_events(documents)

    events = addendum["event_delta"]
    event_types = unique_string_registry(
        events["event_types"],
        result,
        "owner additive event registry",
    )
    event_type_set = set(event_types)
    base_event_rows = [
        event["event_type"] for event in base_event_catalog["events"]
    ]
    base_event_types = set(base_event_rows)
    result.require(
        events.get("base_events")
        == "derived len(specs/events/event-catalog.yaml events)"
        and events.get("additive_events") == "derived len(event_types)"
        and events.get("final_events") == "derived base_events + additive_events"
        and len(base_event_rows) == len(base_event_types)
        and event_type_set.isdisjoint(base_event_types),
        "owner event inventory is not source-derived, unique or disjoint from base",
    )
    contracted_event_types = set(event_contracts["events"])
    result.require(
        event_contracts["event_count"]
        in {len(contracted_event_types), "derived len(events)"}
        and event_contracts.get("base_event_count")
        in {
            len(base_event_types),
            "derived len(specs/events/event-catalog.yaml events)",
        }
        and event_contracts.get("final_event_count")
        in {
            len(base_event_types) + len(contracted_event_types),
            "derived base_event_count + event_count",
        }
        and contracted_event_types == event_type_set,
        "addendum event contracts are not set-equal to owner additive events",
    )
    result.require(
        event_contracts["envelope_schema"]
        == "specs/schemas/event-envelope.schema.json"
        and event_contracts["envelope_required"]
        == [
            "event_id",
            "event_type",
            "event_version",
            "occurred_at",
            "recorded_at",
            "aggregate_type",
            "aggregate_id",
            "aggregate_version",
            "producer",
            "correlation_id",
            "causation_id",
            "idempotency_key",
            "actor",
            "trace_id",
            "classification",
            "payload",
        ],
        "addendum event envelope diverges from the v13 snake_case envelope",
    )
    referenced_components = {
        component
        for contract in event_contracts["events"].values()
        for component in contract["producer"].split("|") + contract["consumers"]
    }
    component_bindings = event_contracts["logical_component_bindings"]
    physical_services = {
        service if isinstance(service, str) else service["id"]
        for service in production_topology["services"]
    }
    result.require(
        set(component_bindings) == referenced_components,
        "event logical component bindings are not set-equal to producers and consumers",
    )
    for component, binding in component_bindings.items():
        result.require(
            binding["physical_service"] in physical_services
            and nonempty(binding.get("module")),
            f"{component}: event component is not bound to the fixed physical topology",
        )
    for event_type, contract in event_contracts["events"].items():
        payload_schema = contract["payload_schema"]
        payload_required = contract["payload_required"]
        payload_properties = payload_schema.get("properties", {})
        consumer_bindings = contract.get("consumer_bindings", [])
        result.require(
            contract["category"] in {"DOMAIN", "INTEGRATION"}
            and len(payload_required) == len(set(payload_required))
            and nonempty(payload_required)
            and payload_schema.get("type") == "object"
            and payload_schema.get("additionalProperties") is False
            and payload_schema.get("required") == payload_required
            and set(payload_properties) == set(payload_required)
            and "eventId" not in payload_required
            and "eventId" not in payload_properties,
            f"{event_type}: event category or payload field set is invalid",
        )
        result.require(
            {binding.get("consumer") for binding in consumer_bindings}
            == set(contract["consumers"])
            and len(consumer_bindings) == len(contract["consumers"]),
            f"{event_type}: consumer bindings are not set-equal to consumers",
        )
        if "fact_semantics" in contract:
            result.require(
                contract["fact_semantics"]
                in {"IMMUTABLE_FACT", "IMMUTABLE_FACT_IMPORT"},
                f"{event_type}: invalid immutable fact semantics",
            )
    journey_events = {
        "journey.instance_started.v1",
        "journey.handoff_requested.v1",
        "journey.handoff_decided.v1",
        "journey.handoff_escalated.v1",
        "journey.handoff_expired.v1",
        "journey.outcome_recorded.v1",
    }
    result.require(
        journey_events <= contracted_event_types
        and all(
            set(event_contracts["events"][event_type]["consumers"])
            == {"journey-projector", "operations-projector", "audit-indexer"}
            for event_type in journey_events
        ),
        "journey events do not share the closed projection and audit consumer set",
    )
    auth_delta = addendum["authorization_delta"]
    additive_capability_ids = [
        capability["id"] for capability in auth_delta["capabilities"]
    ]
    base_capability_rows = [
        capability["id"] for capability in role_contract["capabilities"]
    ]
    base_capability_ids = set(base_capability_rows)
    role_ids = {role["id"] for role in role_contract["roles"]}
    result.require(
        len(base_capability_rows) == len(base_capability_ids)
        and auth_delta["base_capabilities"]
        == "derived len(specs/ui/roles-and-permissions.yaml capabilities)"
        and auth_delta["additive_capabilities"] == "derived len(capabilities)"
        and auth_delta["final_capabilities"]
        == "derived base_capabilities + additive_capabilities"
        and len(additive_capability_ids) == len(set(additive_capability_ids))
        and not (set(additive_capability_ids) & base_capability_ids),
        "owner capability counts or unique base/additive registries drifted",
    )
    for capability in auth_delta["capabilities"]:
        result.require(
            bool(capability["roles"]) and set(capability["roles"]) <= role_ids,
            f"{capability['id']}: capability role set is empty or references a non-role persona",
        )
    action_role_sets = {
        capability["id"]: set(capability["roles"])
        for capability in auth_delta["capabilities"]
        if capability["id"].startswith("actions.")
    }
    result.require(
        set.union(
            action_role_sets["actions.propose"],
            action_role_sets["actions.review"],
            action_role_sets["actions.operate"],
        )
        <= action_role_sets["actions.read"],
        "actions.read must include every role that proposes, reviews or operates an action",
    )
    action_kind_rows = operation_contracts["action_payloads"]["kinds"]
    action_kinds = set(action_kind_rows)
    action_variants = operation_contracts["action_payloads"]["variants"]
    quorum_kinds = approval_policy["quorum_policies"]["action_kinds"]
    executor_catalog = approval_policy["executor_catalog"]
    result.require(
        len(action_kind_rows) == len(action_kinds)
        and set(action_variants) == action_kinds
        and set(quorum_kinds) == action_kinds
        and set(executor_catalog) == action_kinds,
        "action payload/quorum/executor registries are duplicated or not set-equal",
    )
    known_capability_ids = base_capability_ids | set(additive_capability_ids)
    capability_role_map: dict[str, set[str]] = {}
    for role in role_contract["roles"]:
        for capability_id in role["capabilities"]:
            capability_role_map.setdefault(capability_id, set()).add(role["id"])
    for capability in auth_delta["capabilities"]:
        capability_role_map[capability["id"]] = set(capability["roles"])
    policy_used_capabilities: set[str] = set()
    for action_kind in sorted(action_kinds):
        variant = action_variants[action_kind]
        quorum = quorum_kinds[action_kind]
        executor = executor_catalog[action_kind]
        result.require(
            variant["executor"] == executor["executor_id"]
            and variant["proposer_capability"] == quorum["proposer_capability"]
            and executor["capability"] in known_capability_ids,
            f"{action_kind}: action variant/quorum/executor binding mismatch",
        )
        policy_used_capabilities.update(
            {quorum["proposer_capability"], executor["capability"]}
        )
        result.require(
            bool(
                action_role_sets["actions.propose"]
                & capability_role_map[quorum["proposer_capability"]]
            ),
            f"{action_kind}: no role can satisfy actions.propose and the variant proposer capability",
        )
        quorum_classes = quorum.get(
            "classes", {"DEFAULT": {"slots": quorum.get("slots", [])}}
        )
        for quorum_class in quorum_classes.values():
            result.require(
                bool(quorum_class["slots"]),
                f"{action_kind}: empty quorum class",
            )
            for slot in quorum_class["slots"]:
                capability_id = slot["capability"]
                policy_used_capabilities.add(capability_id)
                result.require(
                    capability_id in known_capability_ids
                    and set(slot["allowed_roles"])
                    <= capability_role_map[capability_id]
                    and set(slot["allowed_roles"])
                    <= action_role_sets["actions.review"],
                    f"{action_kind}.{slot['slot_id']}: quorum role lacks its capability",
                )
    operation_capabilities = {
        capability
        for operation in operations.contracted_operations
        for capability in (
            ([operation["capability"]] if "capability" in operation else [])
            + operation.get("alternate_capabilities", [])
        )
    }
    result.require(
        all("+" not in capability for capability in operation_capabilities)
        and operation_capabilities <= known_capability_ids,
        "addendum operation asserted capability must be one canonical capability",
    )
    result.require(
        set(additive_capability_ids)
        <= operation_capabilities | policy_used_capabilities,
        "additive capability is not used by an operation, quorum or executor policy",
    )
    base_guard_operations = set(approval_policy["base_operation_guards"])
    result.require(
        {
            "activateKillSwitch",
            "deactivateKillSwitch",
            "extendKillSwitch",
            "publishCase",
        }
        <= base_guard_operations
        <= {
            operation["operation_id"]
            for operation in base_operation_catalog["operations"]
        }
        and all(
            isinstance(
                approval_policy["base_operation_guards"][operation_id], dict
            )
            and approval_policy["base_operation_guards"][operation_id]
            for operation_id in base_guard_operations
        )
        and approval_policy["safe_retry_proof"]["schema"] == "SafeRetryProofV1"
        and len(approval_policy["safe_retry_proof"]["one_of"]) == 3,
        "approval interception or safe retry proof contract is incomplete",
    )

    search = addendum["search_and_provenance_contract"]
    public_filters = search["filter_contracts"]["searchPublicRecords"]
    internal_filters = search["filter_contracts"]["searchInternalRecords"]
    result.require(
        public_filters["only_fields"]
        == [
            "q",
            "types",
            "publicationState",
            "dateFrom",
            "dateTo",
            "cursor",
            "limit",
            "sort",
        ],
        "public search filter surface mismatch",
    )
    result.require(
        internal_filters["only_fields"]
        == ["q", "types", "status", "cursor", "limit", "sort"],
        "internal search filter surface mismatch",
    )
    result.require(
        public_filters["types"]
        == ["CASE", "CONTRACT", "AGENCY", "SUPPLIER", "METHODOLOGY", "CORRECTION"],
        "public search type order mismatch",
    )
    result.require(
        internal_filters["types"]
        == ["CASE", "SIGNAL", "EVIDENCE", "AGENT_RUN", "AUDIT_EVENT"],
        "internal search type order mismatch",
    )
    ranking = search["ranking_policy"]
    result.require(
        ranking["version"] == "search-rank-v1"
        and ranking["ts_rank_cd_normalization"] == 32
        and ranking["non_statistical_tier_score"] == "1.000000",
        "search ranking policy is not closed",
    )
    schema_deltas = search["schema_deltas"]
    result.require(
        {
            "SearchMatchRangeV1",
            "SearchMatchV1",
            "PublicSearchStateOverlayV1",
            "PublicRecordsSearchResultItem",
            "InternalRecordsSearchResultItem",
            "PublicRecordsSearchResultPage",
            "InternalRecordsSearchResultPage",
            "EvidenceProvenanceV1",
            "PublicEvidence",
            "EvidenceDetail",
        }
        <= set(schema_deltas),
        "search/provenance schema delta set is incomplete",
    )
    return LifecycleFacts(
        event_type_set=event_type_set,
        contracted_event_types=contracted_event_types,
        base_event_types=base_event_types,
        search=search,
    )
