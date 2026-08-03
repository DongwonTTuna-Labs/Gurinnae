#!/usr/bin/env python3
"""Adopt one hash-pinned journey owner decision into canonical product YAML."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
from typing import Any

import yaml

from git_authority import AUTHORITY_ZIP_SHA256

ROOT = Path(__file__).resolve().parents[1]
DECISION_SHA256 = "c0e35f285cba56b6b3e62c0b07eeb1280ba00abbd1f24f055cbbfbd719b063b8"
OUTPUT = ROOT / "specs/product/addendum-journey-contracts.yaml"
SOURCE_PINS = {
    "design_sha256": "DESIGN.md",
    "journey_graph_sha256_before_decision": "specs/ui/journey-graph-contracts.yaml",
    "screen_catalog_sha256": "specs/ui/screen-catalog.yaml",
    "screen_action_contract_sha256": "specs/ui/screen-action-contracts.yaml",
    "effective_screen_contract_sha256": "specs/ui/effective-screen-contracts.yaml",
    "base_operation_contract_sha256": "specs/api/operation-contracts.yaml",
    "additive_operation_contract_sha256": "specs/product/addendum-operation-contracts.yaml",
    "base_state_machine_sha256": "specs/domain/state-machines.yaml",
    "additive_state_machine_sha256": "specs/product/addendum-state-machines.yaml",
    "base_event_catalog_sha256": "specs/events/event-catalog.yaml",
    "additive_event_contract_sha256": "specs/product/addendum-event-contracts.yaml",
    "business_model_contract_sha256": "specs/product/business-model-contract.yaml",
    "base_command_semantics_sha256": "specs/application/command-semantics.yaml",
    "additive_command_semantics_sha256": "specs/product/addendum-command-semantics.yaml",
    "approval_policy_sha256": "specs/product/addendum-approval-policy.yaml",
}
EDGE_COUNTS = {
    "J-01": 4,
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


class UniqueLoader(yaml.SafeLoader):
    """Reject duplicate mapping keys in the adoption input."""


def _mapping(
    loader: UniqueLoader,
    node: yaml.nodes.MappingNode,
    deep: bool = False,
) -> dict[Any, Any]:
    result: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError(f"duplicate YAML key: {key!r}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def load_decision(path: Path) -> dict[str, Any]:
    require(path.is_file() and not path.is_symlink(), "decision must be a regular file")
    require(digest(path) == DECISION_SHA256, "journey owner decision digest drifted")
    value = yaml.load(path.read_text(encoding="utf-8"), Loader=UniqueLoader)
    require(isinstance(value, dict), "journey owner decision must be a mapping")
    return value


def validate_pins(decision: dict[str, Any]) -> list[dict[str, str]]:
    authority = decision.get("authority", {})
    require(
        authority.get("zip_sha256") == AUTHORITY_ZIP_SHA256,
        "authority ZIP pin drifted",
    )
    rows: list[dict[str, str]] = []
    for key, relative in SOURCE_PINS.items():
        path = ROOT / relative
        observed = digest(path)
        require(authority.get(key) == observed, f"source pin drifted: {relative}")
        rows.append({"path": relative, "sha256": observed})
    return rows


def validate_edges(decision: dict[str, Any]) -> tuple[list[str], dict[str, list[list[Any]]]]:
    fields = decision.get("edge_tuple_fields")
    registry = decision.get("edge_registry")
    require(isinstance(fields, list) and len(fields) == 16, "edge tuple field contract drifted")
    require(isinstance(registry, dict) and list(registry) == list(EDGE_COUNTS), "journey registry order drifted")
    identifiers: list[str] = []
    for journey_id, expected in EDGE_COUNTS.items():
        rows = registry.get(journey_id)
        require(isinstance(rows, list) and len(rows) == expected, f"{journey_id} edge count drifted")
        for row in rows:
            require(isinstance(row, list) and len(row) == len(fields), f"{journey_id} edge tuple shape drifted")
            edge_id = row[0]
            require(isinstance(edge_id, str) and edge_id.startswith(f"{journey_id}-E"), f"{journey_id} edge ID drifted")
            identifiers.append(edge_id)
    require(len(identifiers) == len(set(identifiers)) == 129, "edge ID set is not exactly 129 unique rows")
    return fields, registry


def validate_decision(decision: dict[str, Any]) -> tuple[list[str], dict[str, list[list[Any]]]]:
    require(decision.get("artifact_id") == "gurinnae-journey-graph-owner-decisions-v1", "artifact ID drifted")
    require(decision.get("open_decisions") == [], "owner decision still has open decisions")
    require("OPEN_DECISION" not in str(decision), "owner decision contains an open-decision marker")
    contracts = decision.get("journey_contracts")
    require(isinstance(contracts, dict) and list(contracts) == list(EDGE_COUNTS), "journey contract set drifted")
    fields, registry = validate_edges(decision)
    branches = decision.get("branch_contracts")
    branch_edges = {
        row[0]
        for rows in registry.values()
        for row in rows
        if isinstance(row[4], str) and row[4].startswith("@branch:")
    }
    require(isinstance(branches, dict) and set(branches) == branch_edges and len(branches) == 17, "branch registry drifted")
    handoffs = decision.get("handoff_kind_registry", {})
    require(handoffs.get("count") == 20 and len(handoffs.get("rows", [])) == 20, "handoff kind set drifted")
    arcs = decision.get("cross_journey_arc_contracts", {}).get("arcs", [])
    require(isinstance(arcs, list) and len(arcs) == 12, "cross-journey arc set drifted")
    return fields, registry


def canonical_document(
    decision: dict[str, Any],
    pins: list[dict[str, str]],
    fields: list[str],
    registry: dict[str, list[list[Any]]],
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "specification_version": "13.0.0+owner-journey-authority.1",
        "status": "REVIEW_REQUIRED",
        "authority_mode": "ADDITIVE_OWNER_DECISION",
        "authority_zip_sha256": AUTHORITY_ZIP_SHA256,
        "adoption": {
            "decision_artifact_id": decision["artifact_id"],
            "decision_artifact_sha256": DECISION_SHA256,
            "decision": "ADOPT_EXACT_GRAPH_AND_COMPILED_REGISTRIES",
            "adopted_by": "root-product-owner-codex",
            "open_decisions": 0,
        },
        "source_pins_role": "ADOPTION_INPUT_SNAPSHOT_BEFORE_CANONICAL_INTEGRATION",
        "source_pins": pins,
        "rules": decision["owner_decision"]["invariants"],
        "counts": {
            "journeys": 12,
            "edges": 129,
            "branches": 17,
            "handoff_kinds": 20,
            "cross_journey_arcs": 12,
            "routes": 94,
        },
        "edge_count_contract": decision["owner_decision"]["edge_count_decision"],
        "closed_enums": decision["closed_enums"],
        "journey_contracts": decision["journey_contracts"],
        "edge_failure_contract": decision["edge_failure_contract"],
        "edge_tuple_fields": fields,
        "edge_registry": registry,
        "node_group_registry": decision["node_group_registry"],
        "branch_contracts": decision["branch_contracts"],
        "handoff_kind_registry": decision["handoff_kind_registry"],
        "cross_journey_arc_contracts": decision["cross_journey_arc_contracts"],
        "route_lock": decision["route_lock_for_new_journeys"],
        "compiled_registry_decisions": decision["compiled_registry_decisions"],
        "required_functions": decision["new_or_missing_functions"],
        "event_and_consumer_decisions": decision["event_and_consumer_decisions"],
        "terminal_registry": decision["terminal_registry"],
        "acceptance_contract": decision["acceptance_to_add_or_retain_exactly"],
        "negative_canaries": decision["negative_canaries"],
        "rejected_alternatives": decision["rejected_alternatives"],
        "implementation_gate": {
            "status": "OPEN_IMPLEMENTATION",
            "rule": "No edge, handler, handoff, event consumer, operation placement, database resolver, or acceptance receipt may be claimed complete until the same source digest passes real runtime gates.",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--decision", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    decision = load_decision(args.decision.resolve())
    pins = validate_pins(decision)
    fields, registry = validate_decision(decision)
    payload = yaml.safe_dump(
        canonical_document(decision, pins, fields, registry),
        allow_unicode=True,
        sort_keys=False,
        width=120,
    )
    output = args.output.resolve()
    if args.check:
        require(output.is_file() and output.read_text(encoding="utf-8") == payload, "canonical journey graph is stale")
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(payload, encoding="utf-8")
    print(f"JOURNEY_GRAPH_ADOPTION: PASS sha256={hashlib.sha256(payload.encode()).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
