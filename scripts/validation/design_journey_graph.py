"""Validate the explicit 12-journey graph across product, UI, actions, and tests."""
from __future__ import annotations

from collections import Counter
from typing import Any

from .design_support import DesignDocuments
from .loaders import load_yaml


EDGE_FIELDS = [
    "edge_id",
    "edge_name",
    "from_node",
    "from_node_kind",
    "to_node",
    "to_node_kind",
    "edge_kind",
    "resolver_kind",
    "authority_key",
    "handler_id",
    "source_screen",
    "destination_screen",
    "cross_journey_return",
    "terminal_class",
    "authority_status",
    "handler_status",
]
JOURNEY_IDS = [f"J-{ordinal:02d}" for ordinal in range(1, 13)]
EDGE_COUNTS = [7, 5, 7, 5, 4, 9, 5, 4, 4, 17, 29, 36]
EDGE_TOTAL = sum(EDGE_COUNTS)


def _product_edges(document: dict[str, Any], result: Any) -> dict[str, dict[str, Any]]:
    fields = document.get("edge_tuple_fields")
    registry = document.get("edge_registry")
    result.require(fields == EDGE_FIELDS, "journey product edge tuple fields drifted")
    result.require(
        isinstance(registry, dict) and list(registry) == JOURNEY_IDS,
        "journey product registry is not exactly J-01 through J-12",
    )
    if fields != EDGE_FIELDS or not isinstance(registry, dict):
        return {}
    rows: list[dict[str, Any]] = []
    observed_counts: list[int] = []
    for journey_id in JOURNEY_IDS:
        raw_rows = registry.get(journey_id, [])
        observed_counts.append(len(raw_rows) if isinstance(raw_rows, list) else -1)
        if not isinstance(raw_rows, list):
            continue
        for raw in raw_rows:
            if not isinstance(raw, list) or len(raw) != len(EDGE_FIELDS):
                result.error(f"{journey_id}: malformed explicit edge tuple")
                continue
            rows.append(dict(zip(EDGE_FIELDS, raw, strict=True)))
    edge_by_id = {
        str(row["edge_id"]): row
        for row in rows
        if isinstance(row.get("edge_id"), str)
    }
    result.require(observed_counts == EDGE_COUNTS, "journey per-journey edge counts drifted")
    result.require(
        len(rows) == len(edge_by_id) == EDGE_TOTAL,
        f"journey product edge IDs are not a unique {EDGE_TOTAL}-row set",
    )
    result.require(
        document.get("counts", {}).get("journeys") == 12
        and document.get("counts", {}).get("edges") == EDGE_TOTAL,
        "journey product declared counts drifted",
    )
    return edge_by_id


def _ui_edges(document: dict[str, Any], result: Any) -> dict[str, dict[str, Any]]:
    journeys = document.get("journeys")
    result.require(
        isinstance(journeys, list)
        and [row.get("journey_id") for row in journeys] == JOURNEY_IDS,
        "journey UI graph is not exactly J-01 through J-12",
    )
    if not isinstance(journeys, list):
        return {}
    rows = [
        edge
        for journey in journeys
        if isinstance(journey, dict)
        for edge in journey.get("edges", [])
        if isinstance(edge, dict)
    ]
    edge_by_id = {
        str(row["edge_id"]): row
        for row in rows
        if isinstance(row.get("edge_id"), str)
    }
    result.require(
        len(rows) == len(edge_by_id) == EDGE_TOTAL,
        f"journey UI edge IDs are not a unique {EDGE_TOTAL}-row set",
    )
    counts = document.get("counts", {})
    result.require(
        counts
        == {
            "journeys": 12,
            "edges": EDGE_TOTAL,
            "branches": 17,
            "cross_journey_arcs": 12,
            "reachable_outcomes": 12,
            "via_resolved": EDGE_TOTAL,
        },
        "journey UI source-derived counts drifted",
    )
    return edge_by_id


def _validate_edge_parity(
    product: dict[str, dict[str, Any]],
    ui: dict[str, dict[str, Any]],
    result: Any,
) -> None:
    result.require(set(product) == set(ui), "product and UI journey edge ID sets differ")
    comparisons = {
        "edge_name": "edge_name",
        "from_node": "from",
        "from_node_kind": "from_node_kind",
        "to_node": "to",
        "to_node_kind": "to_node_kind",
        "edge_kind": "kind",
        "source_screen": "source_screen_expression",
        "destination_screen": "destination_screen_expression",
        "cross_journey_return": "cross_journey_return",
        "terminal_class": "terminal_class",
    }
    for edge_id in sorted(set(product) & set(ui)):
        left = product[edge_id]
        right = ui[edge_id]
        result.require(
            all(left[source] == right[target] for source, target in comparisons.items()),
            f"{edge_id}: product/UI edge tuple drifted",
        )
        binding = right.get("via_binding", {})
        result.require(
            binding.get("resolver_kind") == left["resolver_kind"]
            and binding.get("authority_key") == left["authority_key"]
            and binding.get("handler_id") == left["handler_id"]
            and binding.get("authority_status") == left["authority_status"]
            and binding.get("implementation_status") == left["handler_status"],
            f"{edge_id}: product/UI resolver binding drifted",
        )


def _validate_branches_and_returns(documents: DesignDocuments) -> None:
    result = documents.result
    product = documents.journey_contracts
    ui = documents.journey_ui_contracts
    branches = product.get("branch_contracts", {})
    result.require(
        isinstance(branches, dict)
        and len(branches) == 17
        and ui.get("branch_contracts") == branches,
        "journey branch contracts are not exact across product and UI",
    )
    handoffs = product.get("handoff_kind_registry", {})
    handoff_rows = handoffs.get("rows", []) if isinstance(handoffs, dict) else []
    result.require(
        len(handoff_rows) == 20
        and len({row.get("handoff_kind") for row in handoff_rows}) == 20
        and ui.get("handoff_kind_registry") == handoffs,
        "journey handoff kind registry is not an exact 20-row product/UI set",
    )
    arcs = product.get("cross_journey_arc_contracts", {})
    result.require(
        len(arcs.get("arcs", [])) == 12
        and ui.get("cross_journey_arc_contracts") == arcs,
        "journey cross-return registry is not an exact 12-row product/UI set",
    )
    receipts = ui.get("reachability_receipt", {})
    result.require(
        set(receipts) == set(JOURNEY_IDS)
        and all(row.get("reachable") is True for row in receipts.values()),
        "journey entry-to-success reachability receipt is incomplete",
    )


def _validate_handler_reuse(document: dict[str, Any], edges: dict[str, dict[str, Any]], result: Any) -> None:
    counts = Counter(str(row.get("handler_id")) for row in edges.values())
    observed = {
        handler: sorted(edge_id for edge_id, row in edges.items() if row.get("handler_id") == handler)
        for handler, count in counts.items()
        if count > 1
    }
    declared = document.get("compiled_registry_decisions", {}).get(
        "resolver_registry", {}
    ).get("handler_reuse_exact", {})
    result.require(observed == declared, "journey handler reuse registry drifted")


def _validate_action_union(documents: DesignDocuments, ui_edges: dict[str, dict[str, Any]]) -> None:
    result = documents.result
    catalog = documents.screen_catalog
    actions = documents.screen_action_contracts
    base = {
        f"{screen['id']}.{action['id']}"
        for screen in catalog.get("screens", [])
        for action in screen.get("actions", [])
    }
    command = {
        row.get("action_key")
        for row in actions.get("additive_action_entries", [])
        if isinstance(row, dict)
    }
    journey = {
        row.get("action_key")
        for row in actions.get("journey_visible_actions", [])
        if isinstance(row, dict)
    }
    result.require(
        not (base & command or base & journey or command & journey)
        # The owner addendum adds three supplier placements and the INT-002
        # decision/detail placements to the command overlay.  Keep this
        # assertion source-derived while retaining the exact cardinality
        # receipt for the current canonical registry.
        and (len(base), len(command), len(journey)) == (259, 82, 17),
        "base, command, and journey action registries are not an exact disjoint union",
    )
    counts = actions.get("counts", {})
    result.require(
        counts.get("base_actions") == len(base)
        and counts.get("visible_placements") == len(command)
        and counts.get("journey_visible_actions") == len(journey)
        and counts.get("effective_actions") == len(base | command | journey) == 358,
        "effective action count is not source-derived from all three registries",
    )
    visible = base | command | journey
    referenced = {
        action
        for edge in ui_edges.values()
        for action in edge.get("via_binding", {}).get("source_action_keys", [])
    }
    result.require(referenced <= visible, "journey edge references an undeclared visible action")


def _validate_acceptance_binding(documents: DesignDocuments) -> None:
    result = documents.result
    contract = documents.journey_contracts.get("acceptance_contract", {})
    required = {
        oracle
        for values in contract.values()
        if isinstance(values, list)
        for oracle in values
    }
    mapping = load_yaml(
        documents.root / "tests/acceptance/supplemental-executable-mapping.yaml"
    )
    mapped = {
        row.get("scenario_id"): row
        for row in mapping.get("scenarios", [])
        if isinstance(row, dict)
    }
    binding = load_yaml(
        documents.root / "tests/acceptance/journey-graph-oracle-bindings.yaml"
    )
    rows = binding.get("bindings", [])
    observed = {
        row.get("oracle_id")
        for row in rows
        if isinstance(row, dict)
    }
    result.require(
        set(binding)
        == {
            "schema_version",
            "specification_version",
            "status",
            "registry_kind",
            "product_source",
            "feature_source",
            "binding_count",
            "rules",
            "bindings",
        }
        and binding.get("status") == "FINAL"
        and binding.get("binding_count") == len(rows) == 28
        and len(required) == 28
        and observed == required,
        "journey acceptance oracle IDs are not set-equal to executable scenario bindings",
    )
    for row in rows:
        scenario_id = row.get("scenario_id") if isinstance(row, dict) else None
        scenario = mapped.get(scenario_id, {})
        result.require(
            isinstance(row, dict)
            and set(row) == {"oracle_id", "scenario_id", "implementation_test_id"}
            and scenario.get("feature_file")
            == "tests/acceptance/journey-graph-addendum.feature"
            and scenario.get("implementation_test_id")
            == row.get("implementation_test_id"),
            f"{scenario_id}: journey oracle executable scenario binding drifted",
        )


def _validate_no_legacy_builder(documents: DesignDocuments) -> None:
    source = (documents.root / "scripts/generate_effective_ui_contracts.py").read_text(
        encoding="utf-8"
    )
    forbidden = (
        "JOURNEYS: list",
        "JOURNEY_VIA_ROWS",
        "enumerate(journey[\"steps\"]",
        "f\"{journey['journey_id']}-E",
    )
    documents.result.require(
        all(token not in source for token in forbidden),
        "legacy positional journey builder remains reachable",
    )


def validate_journey_graph(documents: DesignDocuments) -> None:
    product = _product_edges(documents.journey_contracts, documents.result)
    ui = _ui_edges(documents.journey_ui_contracts, documents.result)
    _validate_edge_parity(product, ui, documents.result)
    _validate_branches_and_returns(documents)
    _validate_handler_reuse(documents.journey_contracts, product, documents.result)
    _validate_action_union(documents, ui)
    _validate_acceptance_binding(documents)
    _validate_no_legacy_builder(documents)
    documents.result.stats.update(
        {
            "journey_graph_edges": len(product),
            "journey_graph_journeys": len(JOURNEY_IDS),
            "journey_graph_branches": len(
                documents.journey_contracts.get("branch_contracts", {})
            ),
        }
    )
