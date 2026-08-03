#!/usr/bin/env python3
"""Generate the exact 44-operation Rust connector catalog."""

from __future__ import annotations

import json
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
DIRECTORIES = {
    "alio": "alio",
    "audit-results": "audit_results",
    "koneps-contracts": "koneps",
    "koneps-notices": "koneps",
    "local-finance": "local_finance",
    "open-dart": "open_dart",
}


def main() -> None:
    grouped: dict[str, list[dict]] = {}
    all_operations = []
    for path in sorted((ROOT / "specs/connectors").glob("*/operations.yaml")):
        document = yaml.safe_load(path.read_text())
        connector = document["connector_id"]
        module = DIRECTORIES[connector]
        for operation in document["operations"]:
            record = {
                "connector_id": connector,
                "id": operation["id"],
                "method": operation["method"],
                "kind": operation["kind"],
                "remote_path": operation.get("path", ""),
                "pagination": operation["pagination"]["strategy"],
            }
            grouped.setdefault(module, []).append(record)
            all_operations.append(record)
    for module, operations in grouped.items():
        entries = "\n".join(
            "    ConnectorOperation { "
            + ", ".join(f"{key}: {json.dumps(value)}" for key, value in operation.items())
            + " },"
            for operation in operations
        )
        (ROOT / f"crates/source-connectors/src/{module}.rs").write_text(
            "use crate::ConnectorOperation;\n\npub const OPERATIONS: &[ConnectorOperation] = &[\n"
            + entries + "\n];\n"
        )
    lib = '''#![forbid(unsafe_code)]

pub mod alio;
pub mod audit_results;
pub mod data_go_kr;
pub mod koneps;
pub mod local_finance;
pub mod open_dart;
pub mod request;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ConnectorOperation {
    pub connector_id: &'static str,
    pub id: &'static str,
    pub method: &'static str,
    pub kind: &'static str,
    pub remote_path: &'static str,
    pub pagination: &'static str,
}

pub fn operations() -> impl Iterator<Item = &'static ConnectorOperation> {
    alio::OPERATIONS.iter()
        .chain(audit_results::OPERATIONS)
        .chain(koneps::OPERATIONS)
        .chain(local_finance::OPERATIONS)
        .chain(open_dart::OPERATIONS)
}
'''
    (ROOT / "crates/source-connectors/src/lib.rs").write_text(lib)
    (ROOT / "verification/generated-connector-catalog.json").write_text(
        json.dumps(all_operations, ensure_ascii=False, indent=2) + "\n"
    )
    print(f"generated {len(all_operations)} connector operations")


if __name__ == "__main__":
    main()
