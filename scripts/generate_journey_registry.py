#!/usr/bin/env python3
"""Generate the closed Rust journey edge and handoff registries."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import subprocess
import sys
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "specs/product/addendum-journey-contracts.yaml"
TARGET = ROOT / "crates/persistence-postgres/src/journey_registry.rs"
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


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def rust_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def edge_rows(document: dict[str, Any]) -> list[dict[str, Any]]:
    require(document.get("edge_tuple_fields") == EDGE_FIELDS, "edge tuple fields drifted")
    registry = document.get("edge_registry")
    require(isinstance(registry, dict), "edge registry must be a mapping")
    rows: list[dict[str, Any]] = []
    for journey_id, raw_rows in registry.items():
        require(isinstance(raw_rows, list), f"{journey_id}: edge rows must be a list")
        for raw in raw_rows:
            require(
                isinstance(raw, list) and len(raw) == len(EDGE_FIELDS),
                f"{journey_id}: malformed edge tuple",
            )
            row = dict(zip(EDGE_FIELDS, raw, strict=True))
            require(
                isinstance(row["edge_id"], str)
                and row["edge_id"].startswith(f"{journey_id}-E"),
                f"{journey_id}: edge identity drifted",
            )
            for field in (
                "resolver_kind",
                "authority_key",
                "handler_id",
                "source_screen",
                "destination_screen",
            ):
                require(isinstance(row[field], str) and row[field], f"{row['edge_id']}: {field} missing")
            row["_raw"] = raw
            rows.append(row)
    edge_ids = [str(row["edge_id"]) for row in rows]
    declared = document.get("counts", {}).get("edges")
    resolver_count = (
        document.get("compiled_registry_decisions", {})
        .get("resolver_registry", {})
        .get("row_count")
    )
    require(
        len(rows) == len(set(edge_ids)) == declared == resolver_count,
        "edge registry cardinality or uniqueness drifted",
    )
    require(edge_ids == sorted(edge_ids), "edge registry order drifted")
    return rows


def handoff_rows(document: dict[str, Any]) -> list[dict[str, str]]:
    registry = document.get("handoff_kind_registry")
    require(isinstance(registry, dict), "handoff registry must be a mapping")
    raw_rows = registry.get("rows")
    require(isinstance(raw_rows, list), "handoff rows must be a list")
    rows: list[dict[str, str]] = []
    for raw in raw_rows:
        require(isinstance(raw, dict), "malformed handoff row")
        kind = raw.get("handoff_kind")
        name = raw.get("name")
        require(isinstance(kind, str) and isinstance(name, str), "handoff identity missing")
        rows.append({"handoff_kind": kind, "name": name})
    identifiers = [row["handoff_kind"] for row in rows]
    require(
        len(rows) == len(set(identifiers)) == registry.get("count"),
        "handoff registry cardinality or uniqueness drifted",
    )
    require(identifiers == sorted(identifiers), "handoff registry order drifted")
    return rows


def render_edge(row: dict[str, Any]) -> str:
    raw = row["_raw"]
    return_binding = "|".join(str(value) for value in raw[:10])
    cross_return = row["cross_journey_return"]
    require(
        cross_return is None or isinstance(cross_return, str),
        f"{row['edge_id']}: cross-journey return must be text or null",
    )
    values = {
        "edge_id": row["edge_id"],
        "resolver_kind": row["resolver_kind"],
        "authority_key": row["authority_key"],
        "handler_id": row["handler_id"],
        # These four digest fields retain the v13 compiled-registry wire names.
        # Their deterministic preimages are the explicit edge tuple fields below.
        "selector_contract_digest": sha256(row["source_screen"]),
        "source_screen_set_digest": sha256(row["destination_screen"]),
        "destination_screen_set_digest": sha256(cross_return or "NULL"),
        "return_contract_digest": sha256(return_binding),
    }
    fields = "\n".join(
        f"        {name}: {rust_string(value)}," for name, value in values.items()
    )
    return f"    JourneyEdgeResolver {{\n{fields}\n    }},"


def render_handoff(row: dict[str, str]) -> str:
    return (
        "    JourneyHandoffKind {\n"
        f"        handoff_kind: {rust_string(row['handoff_kind'])},\n"
        f"        name: {rust_string(row['name'])},\n"
        "    },"
    )


def render(document: dict[str, Any]) -> str:
    edges = edge_rows(document)
    handoffs = handoff_rows(document)
    rendered_edges = "\n".join(render_edge(row) for row in edges)
    rendered_handoffs = "\n".join(render_handoff(row) for row in handoffs)
    return f'''//! Generated by `scripts/generate_journey_registry.py`; do not edit by hand.
//!
//! The registry is compiled from the canonical product `edge_registry` and is
//! deliberately closed: callers may look up an edge but cannot invent a
//! resolver, authority key, handler, or return binding at runtime.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct JourneyEdgeResolver {{
    pub edge_id: &'static str,
    pub resolver_kind: &'static str,
    pub authority_key: &'static str,
    pub handler_id: &'static str,
    pub selector_contract_digest: &'static str,
    pub source_screen_set_digest: &'static str,
    pub destination_screen_set_digest: &'static str,
    pub return_contract_digest: &'static str,
}}

pub const JOURNEY_EDGE_RESOLVER_COUNT: usize = {len(edges)};

pub static JOURNEY_EDGE_RESOLVERS: &[JourneyEdgeResolver; JOURNEY_EDGE_RESOLVER_COUNT] = &[
{rendered_edges}
];

pub fn resolve_journey_edge(edge_id: &str) -> Option<&'static JourneyEdgeResolver> {{
    JOURNEY_EDGE_RESOLVERS
        .iter()
        .find(|row| row.edge_id == edge_id)
}}

pub fn resolver_registry_is_closed() -> bool {{
    JOURNEY_EDGE_RESOLVERS.len() == JOURNEY_EDGE_RESOLVER_COUNT
        && JOURNEY_EDGE_RESOLVERS
            .windows(2)
            .all(|rows| rows[0].edge_id < rows[1].edge_id)
}}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct JourneyHandoffKind {{
    pub handoff_kind: &'static str,
    pub name: &'static str,
}}

pub const JOURNEY_HANDOFF_KIND_COUNT: usize = {len(handoffs)};

pub static JOURNEY_HANDOFF_KINDS: &[JourneyHandoffKind; JOURNEY_HANDOFF_KIND_COUNT] = &[
{rendered_handoffs}
];

pub fn resolve_handoff_kind(kind: &str) -> Option<&'static JourneyHandoffKind> {{
    JOURNEY_HANDOFF_KINDS
        .iter()
        .find(|row| row.handoff_kind == kind)
}}

#[cfg(test)]
mod tests {{
    use super::*;

    #[test]
    fn registry_has_exact_authority_cardinality_and_unique_ids() {{
        assert!(resolver_registry_is_closed());
        assert!(JOURNEY_EDGE_RESOLVERS.iter().all(|row| {{
            row.edge_id.starts_with("J-")
                && row.selector_contract_digest.len() == 64
                && row.source_screen_set_digest.len() == 64
                && row.destination_screen_set_digest.len() == 64
                && row.return_contract_digest.len() == 64
        }}));
    }}

    #[test]
    fn j01_optional_subscription_branch_is_compiled() {{
        let edge_ids = JOURNEY_EDGE_RESOLVERS
            .iter()
            .filter(|row| row.edge_id.starts_with("J-01-"))
            .map(|row| row.edge_id)
            .collect::<Vec<_>>();
        assert_eq!(
            edge_ids,
            [
                "J-01-E01",
                "J-01-E02",
                "J-01-E03",
                "J-01-E04",
                "J-01-E05",
                "J-01-E06",
                "J-01-E07",
            ]
        );
        assert_eq!(
            resolve_journey_edge("J-01-E06").map(|row| row.handler_id),
            Some("handle__j01__create_subscription_verification_receipt_v1")
        );
        assert_eq!(
            resolve_journey_edge("J-01-E07").map(|row| row.handler_id),
            Some("route__j01__return_after_subscription_v1")
        );
    }}

    #[test]
    fn unknown_edges_fail_closed() {{
        assert!(resolve_journey_edge("J-99-E99").is_none());
    }}

    #[test]
    fn handoff_registry_is_exact_and_closed() {{
        assert_eq!(JOURNEY_HANDOFF_KINDS.len(), JOURNEY_HANDOFF_KIND_COUNT);
        assert!(
            JOURNEY_HANDOFF_KINDS
                .windows(2)
                .all(|rows| {{ rows[0].handoff_kind < rows[1].handoff_kind }})
        );
        assert!(resolve_handoff_kind("HS-21").is_none());
    }}
}}
'''


def format_rust(source: str) -> str:
    completed = subprocess.run(
        ["rustfmt", "--edition", "2024", "--emit", "stdout"],
        input=source,
        text=True,
        capture_output=True,
        check=True,
    )
    return completed.stdout


def load_source() -> dict[str, Any]:
    document = yaml.safe_load(SOURCE.read_text(encoding="utf-8"))
    require(isinstance(document, dict), "journey contract root must be a mapping")
    return document


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output = format_rust(render(load_source()))
    if args.check:
        if not TARGET.exists() or TARGET.read_text(encoding="utf-8") != output:
            print(f"generated journey registry differs: {TARGET.relative_to(ROOT)}", file=sys.stderr)
            return 1
        print(f"JOURNEY_REGISTRY: PASS edges={output.count('    JourneyEdgeResolver {')}")
        return 0
    TARGET.write_text(output, encoding="utf-8")
    print(f"JOURNEY_REGISTRY: GENERATED {TARGET.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
