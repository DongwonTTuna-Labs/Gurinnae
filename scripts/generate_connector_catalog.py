#!/usr/bin/env python3
"""Generate the exact 56-operation Rust connector catalog."""

from __future__ import annotations

import json
import argparse
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
DIRECTORIES = {
    "alio": "alio",
    "audit-results": "audit_results",
    "koneps-bid-results": "koneps_bid_results",
    "koneps-contracts": "koneps",
    "koneps-notices": "koneps",
    "local-finance": "local_finance",
    "open-dart": "open_dart",
    "pps-sanctions": "pps_sanctions",
}


def write_or_check(path: Path, content: str, check: bool) -> None:
    if check:
        if not path.is_file() or path.read_text() != content:
            raise SystemExit(f"generated connector artifact is stale: {path.relative_to(ROOT)}")
        return
    path.write_text(content)


def module_content(path: Path, entries: str) -> str:
    generated = (
        "use crate::ConnectorOperation;\n\n"
        "pub const OPERATIONS: &[ConnectorOperation] = &[\n"
        + entries
        + "\n];\n"
    )
    if not path.is_file():
        return generated
    current = path.read_text()
    marker = "];\n"
    _, separator, handwritten = current.partition(marker)
    if not separator:
        raise SystemExit(f"connector module has no generated operation boundary: {path.relative_to(ROOT)}")
    return generated + handwritten


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
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
            "    ConnectorOperation {\n"
            + "\n".join(
                f"        {key}: {json.dumps(value)}," for key, value in operation.items()
            )
            + "\n    },"
            for operation in operations
        )
        path = ROOT / f"crates/source-connectors/src/{module}.rs"
        write_or_check(path, module_content(path, entries), args.check)
    lib = '''#![forbid(unsafe_code)]

pub mod alio;
pub mod audit_results;
pub mod data_go_kr;
pub mod koneps;
pub mod koneps_bid_results;
pub mod local_finance;
pub mod open_dart;
pub mod pps_sanctions;
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
    alio::OPERATIONS
        .iter()
        .chain(audit_results::OPERATIONS)
        .chain(koneps_bid_results::OPERATIONS)
        .chain(koneps::OPERATIONS)
        .chain(local_finance::OPERATIONS)
        .chain(open_dart::OPERATIONS)
        .chain(pps_sanctions::OPERATIONS)
}
'''
    if len(all_operations) != 56:
        raise SystemExit(f"expected 56 connector operations, found {len(all_operations)}")
    write_or_check(ROOT / "crates/source-connectors/src/lib.rs", lib, args.check)
    write_or_check(
        ROOT / "verification/generated-connector-catalog.json",
        json.dumps(all_operations, ensure_ascii=False, indent=2) + "\n",
        args.check,
    )
    verb = "verified" if args.check else "generated"
    print(f"{verb} {len(all_operations)} connector operations")


if __name__ == "__main__":
    main()
