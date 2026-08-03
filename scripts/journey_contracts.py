"""Compile the explicit product journey registry into the UI contract."""
from __future__ import annotations

from collections import Counter, defaultdict, deque
from copy import deepcopy
import re
from typing import Any


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
EDGE_COUNTS = {
    "J-01": 7,
    "J-02": 5,
    "J-03": 7,
    "J-04": 5,
    "J-05": 4,
    "J-06": 9,
    "J-07": 5,
    "J-08": 4,
    "J-09": 4,
    "J-10": 17,
    "J-11": 29,
    "J-12": 36,
}
EDGE_TOTAL = sum(EDGE_COUNTS.values())
ROUTE_PARAMETER_TYPES = {
    "agencySlug": "public-slug",
    "caseId": "uuid",
    "caseSlug": "public-slug",
    "contractId": "uuid",
    "correctionId": "uuid",
    "evidenceId": "uuid",
    "jobId": "uuid",
    "revision": "int64>=1",
    "ruleId": "uuid-or-slug",
    "runId": "uuid",
    "signalId": "uuid",
    "snapshotId": "uuid",
    "sourceId": "uuid-or-slug",
    "supplierSlug": "public-slug",
    "systemPath": "closed-system-path",
    "userId": "uuid",
    "version": "int64>=1",
}


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _screen_token(screen_id: str) -> str:
    return screen_id.lower().replace("-", "_")


def _split_nodes(value: str) -> list[str]:
    return [part for part in value.split("|") if part]


def _expand_screens(
    value: str,
    authority: dict[str, Any],
    screen_ids: set[str],
) -> list[str]:
    origins = authority.get("compiled_registry_decisions", {}).get(
        "J11_ACTION_ORIGIN_PLACEMENT_SET_V1", {}
    ).get("origin_screens", [])
    result: list[str] = []
    for token in _split_nodes(value):
        if token == "J11_ACTION_ORIGIN_SCREEN_SET_V1":
            result.extend(str(screen) for screen in origins)
        elif token.startswith("@branch:"):
            edge_id = token.removeprefix("@branch:")
            branch = authority.get("branch_contracts", {}).get(edge_id, {})
            result.extend(
                str(outcome["destination_screen"])
                for outcome in branch.get("exact", {}).values()
            )
        else:
            result.append(token)
    expanded = sorted(set(result))
    _require(bool(expanded) and set(expanded) <= screen_ids, f"unknown screen expression: {value}")
    return expanded


def _normalized_edges(authority: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    _require(authority.get("edge_tuple_fields") == EDGE_FIELDS, "journey edge tuple fields drifted")
    registry = authority.get("edge_registry")
    _require(isinstance(registry, dict), "journey edge registry must be a mapping")
    _require(list(registry) == JOURNEY_IDS, "journey edge registry order or set drifted")
    result: dict[str, list[dict[str, Any]]] = {}
    for journey_id in JOURNEY_IDS:
        raw_rows = registry.get(journey_id)
        _require(isinstance(raw_rows, list), f"{journey_id}: edge rows must be a list")
        rows: list[dict[str, Any]] = []
        for raw in raw_rows:
            _require(
                isinstance(raw, list) and len(raw) == len(EDGE_FIELDS),
                f"{journey_id}: malformed explicit edge tuple",
            )
            rows.append(dict(zip(EDGE_FIELDS, raw, strict=True)))
        result[journey_id] = rows
    return result


def _validate_identity(
    authority: dict[str, Any],
    edges_by_journey: dict[str, list[dict[str, Any]]],
    screen_ids: set[str],
) -> dict[str, dict[str, Any]]:
    journeys = authority.get("journey_contracts")
    _require(isinstance(journeys, dict) and list(journeys) == JOURNEY_IDS, "journey contract set drifted")
    counts = authority.get("counts", {})
    _require(
        counts.get("journeys") == 12 and counts.get("edges") == EDGE_TOTAL,
        "journey declared counts drifted",
    )
    _require({key: len(value) for key, value in edges_by_journey.items()} == EDGE_COUNTS, "journey edge counts drifted")
    rows = [row for values in edges_by_journey.values() for row in values]
    edge_ids = [str(row.get("edge_id")) for row in rows]
    handlers = [str(row.get("handler_id")) for row in rows]
    _require(
        len(rows) == len(set(edge_ids)) == EDGE_TOTAL,
        "journey edge IDs are not unique",
    )
    observed_reuse = {
        handler: sorted(row["edge_id"] for row in rows if row["handler_id"] == handler)
        for handler, count in Counter(handlers).items()
        if count > 1
    }
    declared_reuse = authority.get("compiled_registry_decisions", {}).get(
        "resolver_registry", {}
    ).get("handler_reuse_exact", {})
    _require(observed_reuse == declared_reuse, "journey handler reuse registry drifted")
    for journey_id, journey_rows in edges_by_journey.items():
        for row in journey_rows:
            edge_id = str(row["edge_id"])
            _require(edge_id.startswith(f"{journey_id}-E"), f"{edge_id}: wrong journey prefix")
            _require(
                bool(re.fullmatch(r"J-(?:0[1-9]|1[0-2])-E(?:0[1-9]|[12][0-9]|30)[A-F]?", edge_id)),
                f"{edge_id}: invalid explicit edge identity",
            )
            _expand_screens(str(row["source_screen"]), authority, screen_ids)
            _expand_screens(str(row["destination_screen"]), authority, screen_ids)
            _require(
                bool(re.fullmatch(r"[a-z][a-z0-9_]*", str(row["handler_id"]))),
                f"{edge_id}: handler is not a concrete symbol",
            )
    return journeys


def _validate_branches(
    authority: dict[str, Any],
    edge_by_id: dict[str, dict[str, Any]],
    screen_ids: set[str],
) -> None:
    branches = authority.get("branch_contracts")
    _require(isinstance(branches, dict), "branch contracts must be a mapping")
    expected = {
        edge_id
        for edge_id, row in edge_by_id.items()
        if row.get("terminal_class") == "BY_SELECTOR"
    }
    _require(set(branches) == expected and len(branches) == 17, "branch contracts are not edge-set-equal")
    for edge_id, branch in branches.items():
        exact = branch.get("exact") if isinstance(branch, dict) else None
        _require(isinstance(exact, dict) and exact, f"{edge_id}: branch selector map is empty")
        _require(edge_by_id[edge_id]["to_node"] == f"@branch:{edge_id}", f"{edge_id}: branch node identity drifted")
        for selector, outcome in exact.items():
            _require(isinstance(selector, str) and selector, f"{edge_id}: empty selector")
            _require(isinstance(outcome, dict), f"{edge_id}.{selector}: branch outcome must be a mapping")
            _expand_screens(
                str(outcome.get("destination_screen", "")), authority, screen_ids
            )
            _require(bool(outcome.get("to")), f"{edge_id}.{selector}: target is missing")


def _expanded_graph(
    authority: dict[str, Any],
    edges: list[dict[str, Any]],
) -> dict[str, set[str]]:
    graph: dict[str, set[str]] = defaultdict(set)
    edge_by_id = {str(row["edge_id"]): row for row in edges}
    journeys = authority["journey_contracts"]
    for row in edges:
        for source in _split_nodes(str(row["from_node"])):
            graph[source].add(str(row["to_node"]))
    for edge_id, branch in authority["branch_contracts"].items():
        for outcome in branch["exact"].values():
            graph[f"@branch:{edge_id}"].add(str(outcome["to"]))
    arcs = authority.get("cross_journey_arc_contracts", {}).get("arcs", [])
    _require(isinstance(arcs, list) and len(arcs) == 12, "cross-journey arc set drifted")
    for arc in arcs:
        caller = edge_by_id[str(arc["caller_edge"])]
        entry = str(arc["callee_entry"])
        generic_entry = str(journeys[str(arc["callee"])]["entry"])
        for source in _split_nodes(str(caller["from_node"])):
            graph[source].add(entry)
        graph[entry].add(generic_entry)
        for target in _split_nodes(str(arc["success_return"])):
            graph[str(journeys[str(arc["callee"])]["success"])].add(target)
    returns = authority.get("compiled_registry_decisions", {}).get(
        "J12_TERMINAL_RECONCILIATION_RETURN_V1", {}
    ).get("exact", {})
    _require(set(returns) == {"ACTION", "OUTBOUND_DELIVERY"}, "J-12 terminal return registry drifted")
    graph["J-11::DURABLE_EFFECT_RECEIPT"].add(str(returns["ACTION"]["success_destination"]))
    graph["J-11::DELIVERED_OR_READ_RECEIPT"].add(
        str(returns["OUTBOUND_DELIVERY"]["success_destination"])
    )
    return graph


def _reachability(
    journeys: dict[str, dict[str, Any]],
    graph: dict[str, set[str]],
) -> dict[str, dict[str, Any]]:
    receipts: dict[str, dict[str, Any]] = {}
    for journey_id, contract in journeys.items():
        entry = str(contract["entry"])
        success = str(contract["success"])
        queue = deque([entry])
        visited = {entry}
        while queue:
            source = queue.popleft()
            for target in graph.get(source, set()):
                for node in _split_nodes(target):
                    if node not in visited:
                        visited.add(node)
                        queue.append(node)
        _require(success in visited, f"{journey_id}: success is unreachable from entry")
        receipts[journey_id] = {
            "entry": entry,
            "success": success,
            "reachable": True,
            "reachable_node_count": len(visited),
        }
    return receipts


def _operation_actions(
    catalog: dict[str, Any],
    overrides: dict[tuple[str, str], list[str]],
) -> dict[tuple[str, str], list[str]]:
    rows: dict[tuple[str, str], list[str]] = {}
    for screen in catalog["screens"]:
        for action in screen.get("actions", []):
            operation_id = action.get("operation_id")
            if operation_id:
                rows.setdefault((screen["id"], operation_id), []).append(
                    f"{screen['id']}.{action['id']}"
                )
    for key, values in overrides.items():
        rows.setdefault(key, []).extend(values)
    return rows


def _known_operations(value: str, operation_ids: set[str]) -> list[str]:
    return [
        operation_id
        for operation_id in sorted(operation_ids)
        if re.search(
            rf"(?<![A-Za-z0-9_]){re.escape(operation_id)}(?![A-Za-z0-9_])",
            value,
        )
    ]


def _source_actions(
    row: dict[str, Any],
    source_screens: list[str],
    visible_actions: set[str],
    operation_ids: set[str],
    operation_actions: dict[tuple[str, str], list[str]],
) -> list[str]:
    resolver = str(row["resolver_kind"])
    authority_key = str(row["authority_key"])
    if resolver in {"VISIBLE_ACTION", "VISIBLE_ACTION_ROUTER"}:
        actions = authority_key.split("|")
        _require(bool(actions) and set(actions) <= visible_actions, f"{row['edge_id']}: visible action is undeclared")
        _require(
            all(any(action.startswith(f"{screen}.") for screen in source_screens) for action in actions),
            f"{row['edge_id']}: visible action is owned by another screen",
        )
        return actions
    operations = _known_operations(authority_key, operation_ids)
    return sorted(
        {
            action
            for operation_id in operations
            for screen in source_screens
            for action in operation_actions.get((screen, operation_id), [])
        }
    )


def _destination(
    row: dict[str, Any],
    screen_id: str,
    screen_by: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    route = str(screen_by[screen_id]["route"])
    parameters = re.findall(r"\{([^}]+)\}", route)
    _require(set(parameters) <= set(ROUTE_PARAMETER_TYPES), f"{row['edge_id']}: route type is missing")
    terminal = row["to_node_kind"] != "SCREEN"
    focus = (
        f"{_screen_token(screen_id)}__journey_outcome__{str(row['edge_id']).lower().replace('-', '_')}__heading"
        if terminal
        else f"{_screen_token(screen_id)}__heading"
    )
    return {
        "screen_id": screen_id,
        "route": route,
        "required_object_bindings": {
            parameter: {
                "source": f"journey_context.{parameter}",
                "type": ROUTE_PARAMETER_TYPES[parameter],
            }
            for parameter in parameters
        },
        "safe_query_keys": [],
        "focus_test_id": focus,
    }


def build_journey_contracts(
    authority: dict[str, Any],
    catalog: dict[str, Any],
    data_contracts: dict[str, Any],
    addendum_operations: dict[str, Any],
    action_contracts: dict[str, Any],
    navigation: dict[str, Any],
    operation_action_overrides: dict[tuple[str, str], list[str]],
) -> dict[str, Any]:
    screen_by = {screen["id"]: screen for screen in catalog["screens"]}
    screen_ids = set(screen_by)
    edges_by_journey = _normalized_edges(authority)
    journeys = _validate_identity(authority, edges_by_journey, screen_ids)
    edges = [row for rows in edges_by_journey.values() for row in rows]
    edge_by_id = {str(row["edge_id"]): row for row in edges}
    _validate_branches(authority, edge_by_id, screen_ids)
    graph = _expanded_graph(authority, edges)
    reachability = _reachability(journeys, graph)
    visible_actions = {
        f"{screen['id']}.{action['id']}"
        for screen in catalog["screens"]
        for action in screen.get("actions", [])
    } | {row["action_key"] for row in action_contracts["journey_visible_actions"]} | {
        row["action_key"] for row in action_contracts["additive_action_entries"]
    }
    operation_ids = {
        row["operation_id"] for row in data_contracts["operations"]
    } | {row["operation_id"] for row in addendum_operations["operations"]}
    operation_actions = _operation_actions(catalog, operation_action_overrides)
    output_journeys: list[dict[str, Any]] = []
    for journey_id in JOURNEY_IDS:
        contract = journeys[journey_id]
        output_edges: list[dict[str, Any]] = []
        for row in edges_by_journey[journey_id]:
            source_screens = _expand_screens(
                str(row["source_screen"]), authority, screen_ids
            )
            destination_screens = _expand_screens(
                str(row["destination_screen"]), authority, screen_ids
            )
            output_edges.append(
                {
                    "edge_id": row["edge_id"],
                    "edge_name": row["edge_name"],
                    "from": row["from_node"],
                    "from_node_kind": row["from_node_kind"],
                    "to": row["to_node"],
                    "to_node_kind": row["to_node_kind"],
                    "kind": row["edge_kind"],
                    "source_screen_expression": row["source_screen"],
                    "source_screens": source_screens,
                    "destination_screen_expression": row["destination_screen"],
                    "destination_screens": destination_screens,
                    "terminal_class": row["terminal_class"],
                    "cross_journey_return": row["cross_journey_return"],
                    "via_binding": {
                        "resolver_kind": row["resolver_kind"],
                        "authority_key": row["authority_key"],
                        "handler_id": row["handler_id"],
                        "source_action_keys": _source_actions(
                            row,
                            source_screens,
                            visible_actions,
                            operation_ids,
                            operation_actions,
                        ),
                        "authority_status": row["authority_status"],
                        "implementation_status": row["handler_status"],
                    },
                    "destinations": [
                        _destination(row, screen_id, screen_by)
                        for screen_id in destination_screens
                    ],
                    "failure_outcome": "typed recovery, nonvalue, or terminal receipt from the closed branch contract",
                }
            )
        output_journeys.append(
            {
                "journey_id": journey_id,
                "entry_node": contract["entry"],
                "durable_outcome_node": contract["success"],
                "accountable_owner": contract["accountable_owner"],
                "instance_field_set": [
                    "journeyInstanceId",
                    "objectIdentity",
                    "currentOwner",
                    "nextOwner",
                    "dueAtOrSlo",
                    "handoffState",
                    "escalationState",
                    "lastReceiptId",
                ],
                "edges": output_edges,
                "reachability_oracle": reachability[journey_id],
            }
        )
    return {
        "schema_version": 2,
        "specification_version": "13.0.0+owner-ui-journeys.4",
        "status": "OPEN_IMPLEMENTATION",
        "authority_mode": "DERIVED_FROM_EXPLICIT_PRODUCT_REGISTRY",
        "sources": [
            "specs/product/addendum-journey-contracts.yaml#edge_registry",
            "specs/ui/screen-catalog.yaml",
            "specs/ui/screen-action-contracts.yaml",
            "specs/ui/navigation-action-contracts.yaml",
        ],
        "rules": deepcopy(authority.get("rules", [])),
        "counts": {
            "journeys": len(output_journeys),
            "edges": len(edges),
            "branches": len(authority["branch_contracts"]),
            "cross_journey_arcs": len(authority["cross_journey_arc_contracts"]["arcs"]),
            "reachable_outcomes": len(reachability),
            "via_resolved": len(edge_by_id),
        },
        "edge_tuple_fields": EDGE_FIELDS,
        "via_set_equality": {
            "edge_ids": len(edge_by_id),
            "resolved_edge_ids": len(edge_by_id),
            "missing": 0,
            "extra": 0,
            "identity_rule": "product edge IDs are copied, never positionally synthesized",
            "runtime_status": "OPEN_IMPLEMENTATION",
        },
        "reachability_receipt": reachability,
        "journeys": output_journeys,
        "branch_contracts": deepcopy(authority["branch_contracts"]),
        "handoff_kind_registry": deepcopy(authority["handoff_kind_registry"]),
        "cross_journey_arc_contracts": deepcopy(authority["cross_journey_arc_contracts"]),
        "compiled_registry_decisions": deepcopy(authority["compiled_registry_decisions"]),
        "implementation_requirements": [
            "Implement every explicit handler and preserve edge, branch, handoff, operation-placement, and acceptance set equality.",
            "Persist the eight journey instance fields and require receiver acknowledgement before handoff completion.",
            "Exercise every success, recovery, nonvalue, reconciliation, and terminal selector against real PostgreSQL, services, and browser routes.",
        ],
        "navigation_contract_count": len(navigation.get("navigation_contracts", {})),
    }
