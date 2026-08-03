from __future__ import annotations

from collections import Counter
import json

from .design_lifecycle import LifecycleFacts
from .design_domain_journeys import validate_journey_domain
from .design_domain_private_operations import (
    PrivateOperationClosureValidator,
    validate_payment_runtime_closure,
)
from .design_operations import OperationFacts
from .design_persistence import PersistenceFacts
from .design_support import (
    DesignDocuments,
    keyed_registry,
    markdown_table_first_column,
    nonempty,
    state_tokens,
)
from .design_ui import UiFacts


def validate_domain(
    documents: DesignDocuments,
    operations: OperationFacts,
    persistence: PersistenceFacts,
    lifecycle: LifecycleFacts,
    ui: UiFacts,
) -> None:
    result = documents.result
    domain = documents.domain
    event_contracts = documents.event_contracts
    state_machines = documents.state_machines
    addendum = documents.addendum
    validate_journey_domain(documents)

    bindings = domain["bindings"]
    binding_by = {binding["noun"]: binding for binding in bindings}
    result.require(
        len(bindings) == len(binding_by)
        and domain["binding_count"] == "derived as len(bindings)",
        "design domain binding count rule or noun uniqueness mismatch",
    )
    aggregate_aliases = domain["aggregate_aliases"]
    alias_by_aggregate = {
        alias["aggregate"]: alias for alias in aggregate_aliases
    }
    event_aggregates = {
        contract["aggregate"] for contract in event_contracts["events"].values()
    }
    result.require(
        len(aggregate_aliases)
        == len(alias_by_aggregate)
        == domain["aggregate_alias_count"],
        "design aggregate alias count or uniqueness mismatch",
    )
    result.require(
        set(alias_by_aggregate) == event_aggregates - set(binding_by),
        "event aggregate aliases are not set-equal to noncanonical event aggregates",
    )
    validate_payment_runtime_closure(documents, binding_by, alias_by_aggregate)
    for alias in aggregate_aliases:
        result.require(
            alias["canonical_noun"] in binding_by
            and all(
                nonempty(alias.get(key))
                for key in (
                    "aggregate",
                    "canonical_noun",
                    "rust_type",
                    "repository",
                    "identity",
                    "concurrency",
                )
            ),
            f"{alias.get('aggregate', 'unknown')}: aggregate alias is incomplete",
        )
    for event_type, contract in event_contracts["events"].items():
        aggregate = contract["aggregate"]
        canonical_noun = (
            alias_by_aggregate[aggregate]["canonical_noun"]
            if aggregate in alias_by_aggregate
            else aggregate
        )
        result.require(
            canonical_noun in binding_by
            and event_type in binding_by[canonical_noun]["events"],
            f"{event_type}: event is not owned by its canonical aggregate binding {canonical_noun}",
        )
    operation_domain_coverage = Counter(
        operation for binding in bindings for operation in binding["operations"]
    )
    event_domain_coverage = Counter(
        event for binding in bindings for event in binding["events"]
    )
    relation_domain_coverage = Counter(
        relation for binding in bindings for relation in binding["relations"]
    )
    covered_operations = set(operation_domain_coverage)
    covered_events = set(event_domain_coverage)
    covered_relations = set(relation_domain_coverage)
    known_operation_ids = (
        operations.base_operation_ids
        | operations.owner_operation_ids
        | operations.private_billing_ids
        | operations.private_control_ids
        | operations.private_application_ids
    )
    known_event_types = lifecycle.base_event_types | lifecycle.event_type_set
    missing_domain_operations = (
        operations.owner_operation_ids | operations.private_billing_ids
    ) - covered_operations
    missing_domain_events = lifecycle.event_type_set - covered_events
    missing_domain_relations = persistence.table_set - covered_relations
    result.require(
        not missing_domain_operations,
        "additive operations lack domain bindings: "
        + ", ".join(sorted(missing_domain_operations)),
    )
    result.require(
        not missing_domain_events,
        "additive events lack domain bindings: "
        + ", ".join(sorted(missing_domain_events)),
    )
    result.require(
        not missing_domain_relations,
        "additive tables lack domain bindings: "
        + ", ".join(sorted(missing_domain_relations)),
    )
    result.require(
        all(
            relation_domain_coverage[relation] == 1
            for relation in persistence.table_set
        ),
        "additive table domain ownership must occur exactly once per relation",
    )
    known_relations = persistence.base_relations | persistence.table_set | {
        rename["to"] for rename in persistence.database["renamed_tables"]
    }
    result.require(
        covered_operations <= known_operation_ids,
        "design domain binding references an unknown operation",
    )
    result.require(
        covered_events <= known_event_types,
        "design domain binding references an unknown event",
    )
    result.require(
        covered_relations <= known_relations,
        "design domain binding references an unknown relation",
    )
    machine_catalog = state_machines["machines"]
    state_edge_count = sum(
        len(machine.get("edges", [])) for machine in machine_catalog.values()
    )
    private_operation_closure = PrivateOperationClosureValidator(
        documents, operations
    )
    registry_contract = state_machines["registry_contract"]
    owner_machine_inventory = addendum["state_machine_inventory"]
    declared_machine_count = registry_contract["machine_count"]
    declared_edge_count = registry_contract["edge_count"]
    result.require(
        declared_machine_count == "derived as len(machines)"
        and declared_edge_count == "derived as sum(len(machine.edges))"
        and owner_machine_inventory["machine_count"]
        == "derived as len(addendum-state-machines.machines)"
        and owner_machine_inventory["edge_count"]
        == "derived as sum(len(addendum-state-machines.machines[*].edges))",
        "addendum state-machine inventories must use the canonical source-derived count rules",
    )
    result.require(
        bool(machine_catalog) and state_edge_count > 0,
        "addendum state-machine registry must contain source-derived machines and edges",
    )
    for machine_name, machine in machine_catalog.items():
        result.require(
            nonempty(machine.get("states"))
            or nonempty(machine.get("legal_states")),
            f"{machine_name}: state inventory missing",
        )
        terminal_states = set(machine.get("terminal", []))
        edge_signatures: set[str] = set()
        for edge in machine.get("edges", []):
            edge_signature = json.dumps(
                edge,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            result.require(
                edge_signature not in edge_signatures,
                f"{machine_name}: duplicate closed state edge",
            )
            edge_signatures.add(edge_signature)
            result.require(
                nonempty(edge.get("from"))
                and nonempty(edge.get("to"))
                and nonempty(edge.get("guard")),
                f"{machine_name}: incomplete state edge",
            )
            operation_id = edge.get("operation")
            private_operation_id = edge.get("private_operation")
            actor = edge.get("actor")
            edge_owner_count = sum(
                value is not None
                for value in (operation_id, private_operation_id, actor)
            )
            result.require(
                edge_owner_count == 1,
                f"{machine_name}: edge must declare exactly one operation, private_operation or actor",
            )
            if operation_id is not None:
                result.require(
                    operation_id in known_operation_ids,
                    f"{machine_name}: edge references unknown operation {operation_id}",
                )
            elif private_operation_id is None:
                result.require(
                    nonempty(actor),
                    f"{machine_name}: edge actor is empty",
                )
            private_operation_closure.observe_edge(machine_name, edge)
            event_type = edge.get("event")
            result.require(
                event_type == "NONE" or event_type in known_event_types,
                f"{machine_name}: edge references unknown event {event_type}",
            )
            result.require(
                not (state_tokens(edge.get("from")) & terminal_states),
                f"{machine_name}: terminal state has an outgoing edge",
            )
            if event_type == "NONE":
                result.require(
                    nonempty(edge.get("receipt")) and nonempty(edge.get("audit")),
                    f"{machine_name}: eventless mutation lacks a typed receipt or audit kind",
                )
    private_operation_closure.validate_lifecycles()
    for binding in bindings:
        for key in (
            "noun",
            "rust_type",
            "owner",
            "application",
            "repository",
            "relations",
            "identity",
            "concurrency",
            "errors",
        ):
            result.require(
                nonempty(binding.get(key)),
                f"{binding.get('noun', 'unknown')}: domain binding missing {key}",
            )

    _validate_review_roles(documents)
    for number in range(1, 11):
        result.require(
            f"SPEC-CONFLICT-{number:03d}" in documents.conflicts,
            f"missing SPEC-CONFLICT-{number:03d}",
        )
    result.require(
        "USER-ADDENDUM-001" in documents.conflicts,
        "missing owner addendum conflict record",
    )
    for marker in (
        "DESIGN_GATE",
        "IMPLEMENTATION_GATE",
        "DESIGN_BUNDLE_SHA256",
        "DESIGN_VERDICT",
    ):
        result.require(
            marker in documents.prompt,
            f"expert review prompt missing {marker}",
        )
    for marker in (
        "owner-addendum-2026-07-14.yaml",
        "design-domain-closure.yaml",
        "design-screen-closure.yaml",
        "make verify-acceptance",
    ):
        result.require(
            marker in documents.design,
            f"DESIGN.md missing {marker}",
        )

    result.stats.update(
        {
            "design_screens": len(ui.rows),
            "design_domain_bindings": len(bindings),
            "design_aggregate_aliases": len(aggregate_aliases),
            "owner_additive_operations": len(operations.owner_operation_ids),
            "owner_additive_operation_queries": operations.owner_operation_kind_counts[
                "QUERY"
            ],
            "owner_additive_operation_commands": operations.owner_operation_kind_counts[
                "COMMAND"
            ],
            "owner_private_callback_operations": len(
                operations.private_callback_ids
            ),
            "owner_private_billing_gateway_operations": len(
                operations.private_billing_ids
            ),
            "owner_private_application_commands": len(
                operations.private_application_ids
            ),
            "owner_additive_tables": len(persistence.table_set),
            "persistence_additive_tables": len(persistence.migration_tables),
            "global_additive_tables": len(set(persistence.global_relation_rows)),
            "physical_additive_tables": len(persistence.physical_table_rows),
            "owner_additive_events": len(lifecycle.event_type_set),
            "product_additive_events": len(lifecycle.contracted_event_types),
            "owner_state_machines": len(machine_catalog),
            "owner_state_edges": state_edge_count,
        }
    )
    for api, count in sorted(operations.owner_operation_api_counts.items()):
        result.stats[
            "owner_additive_operations_" + str(api).replace("-", "_")
        ] = count


def _validate_review_roles(documents: DesignDocuments) -> None:
    result = documents.result
    role_rows, role_by_id = keyed_registry(
        documents.expert_roles.get("roles"),
        "role",
        result,
        "expert review canonical role registry",
    )
    canonical_roles = set(role_by_id)
    result.require(
        bool(canonical_roles)
        and documents.expert_roles.get("canonical_role_count")
        == len(role_rows)
        == len(canonical_roles),
        "expert review canonical role count or uniqueness mismatch",
    )
    implementation_roles = markdown_table_first_column(documents.status, "Gate")
    design_roles = markdown_table_first_column(documents.status, "Design gate")
    result.require(
        len(implementation_roles)
        == len(set(implementation_roles))
        == len(canonical_roles)
        and set(implementation_roles) == canonical_roles,
        "expert review implementation status role set is not exactly canonical",
    )
    result.require(
        len(design_roles) == len(set(design_roles)) == len(canonical_roles)
        and set(design_roles) == canonical_roles,
        "expert review design status role set is not exactly canonical",
    )
