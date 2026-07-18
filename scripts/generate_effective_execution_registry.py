#!/usr/bin/env python3
"""Generate the static 439-scenario executable acceptance registry.

Runtime status and receipts are intentionally absent.  They belong to an
external, append-only evidence root and bind this file's SHA-256 as an input.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
from typing import Any

import yaml

from validation.acceptance_gherkin import (
    canonical_sha256,
    compile_features,
    ordered_pair_set_sha256,
)


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = "tests/acceptance/effective-execution-registry.yaml"
BASE_LOCK = "tests/acceptance/base-v13.lock.yaml"
BASE_MAPPING = "tests/acceptance/executable-mapping.yaml"
SUPPLEMENTAL_MAPPING = "tests/acceptance/supplemental-executable-mapping.yaml"
AUTHORITY_ZIP_SHA256 = (
    "960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5"
)
PROFILE_DOMAIN = b"GURINNAE-ACCEPTANCE-RUNTIME-PROFILE-V1\0"
SELECTOR_DOMAIN = b"GURINNAE-ACCEPTANCE-SELECTOR-V1\0"
OBSERVATION_LAYER_DOMAIN = b"GURINNAE-ACCEPTANCE-OBSERVATION-LAYER-EDGE-V1\0"
ORACLE_LAYER_DOMAIN = b"GURINNAE-ACCEPTANCE-ORACLE-LAYER-EDGE-V1\0"

RUNTIME_LAYERS: dict[str, dict[str, object]] = {
    "rust-1.97.0-domain-application": {
        "probe_kind": "RUST_TOOLCHAIN_AND_BINARY",
        "required_tool": "rustc 1.97.0",
        "probe_argv_template": [
            "python3", "-B", "scripts/acceptance_layer_probe.py",
            "--layer-id", "rust-1.97.0-domain-application",
            "--scenario-id", "{scenario_id}",
            "--test-path", "{implementation_test_path}",
            "--test-id", "{implementation_test_id}",
        ],
    },
    "postgresql-18.4-real-migrations": {
        "probe_kind": "POSTGRESQL_CATALOG",
        "required_version": "18.4",
        "probe_argv_template": [
            "python3", "-B", "scripts/acceptance_layer_probe.py",
            "--layer-id", "postgresql-18.4-real-migrations",
            "--scenario-id", "{scenario_id}",
        ],
    },
    "docker-compose-production-topology": {
        "probe_kind": "COMPOSE_TOPOLOGY",
        "required_compose_service_count": 20,
        "probe_argv_template": [
            "python3", "-B", "scripts/acceptance_layer_probe.py",
            "--layer-id", "docker-compose-production-topology",
            "--scenario-id", "{scenario_id}",
        ],
    },
    "sveltekit-ssr-browser": {
        "probe_kind": "PLAYWRIGHT_BROWSER_TRACE",
        "required_project": "chromium",
        "probe_argv_template": [
            "python3", "-B", "scripts/acceptance_layer_probe.py",
            "--layer-id", "sveltekit-ssr-browser",
            "--scenario-id", "{scenario_id}",
        ],
    },
    "provider-double-at-external-boundary": {
        "probe_kind": "PROVIDER_BOUNDARY_LOG",
        "effect_writer_forbidden": True,
        "probe_argv_template": [
            "python3", "-B", "scripts/acceptance_layer_probe.py",
            "--layer-id", "provider-double-at-external-boundary",
            "--scenario-id", "{scenario_id}",
        ],
    },
    "parser-golden-bytes": {
        "probe_kind": "PARSER_GOLDEN",
        "authority_fixture_count": 15,
        "probe_argv_template": [
            "python3", "-B", "scripts/acceptance_layer_probe.py",
            "--layer-id", "parser-golden-bytes",
            "--scenario-id", "{scenario_id}",
        ],
    },
    "production-ledger-projection": {
        "probe_kind": "PROJECTION_DIGEST",
        "fixture_effect_write_forbidden": True,
        "probe_argv_template": [
            "python3", "-B", "scripts/acceptance_layer_probe.py",
            "--layer-id", "production-ledger-projection",
            "--scenario-id", "{scenario_id}",
        ],
    },
    "koneps-synthetic-source-boundary": {
        "probe_kind": "SOURCE_BOUNDARY_LOG",
        "effect_writer_forbidden": True,
        "probe_argv_template": [
            "python3", "-B", "scripts/acceptance_layer_probe.py",
            "--layer-id", "koneps-synthetic-source-boundary",
            "--scenario-id", "{scenario_id}",
        ],
    },
}

PROFILE_LAYERS: dict[str, tuple[str, ...]] = {
    "FULL_STACK_RUST_V1": (
        "rust-1.97.0-domain-application",
        "postgresql-18.4-real-migrations",
        "docker-compose-production-topology",
    ),
    "FULL_STACK_BROWSER_V1": (
        "rust-1.97.0-domain-application",
        "postgresql-18.4-real-migrations",
        "docker-compose-production-topology",
        "sveltekit-ssr-browser",
    ),
    "AI_MULTIMODAL_V1": (
        "rust-1.97.0-domain-application",
        "postgresql-18.4-real-migrations",
        "docker-compose-production-topology",
        "provider-double-at-external-boundary",
        "parser-golden-bytes",
        "sveltekit-ssr-browser",
    ),
    "BUSINESS_LEDGER_V1": (
        "rust-1.97.0-domain-application",
        "postgresql-18.4-real-migrations",
        "docker-compose-production-topology",
        "production-ledger-projection",
        "sveltekit-ssr-browser",
    ),
    "PROCUREMENT_SOURCE_V1": (
        "rust-1.97.0-domain-application",
        "postgresql-18.4-real-migrations",
        "docker-compose-production-topology",
        "koneps-synthetic-source-boundary",
        "sveltekit-ssr-browser",
    ),
}

PROFILE_BY_LAYERS = {layers: profile for profile, layers in PROFILE_LAYERS.items()}


class RegistryError(RuntimeError):
    """The effective execution registry cannot be derived without guessing."""


class UniqueLoader(yaml.SafeLoader):
    pass


def _unique_mapping(
    loader: UniqueLoader,
    node: yaml.nodes.MappingNode,
    deep: bool = False,
) -> dict[Any, Any]:
    result: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise RegistryError(f"duplicate YAML key: {key!r}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _unique_mapping,
)


def _load(root: Path, relative: str) -> dict[str, Any]:
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise RegistryError(f"required regular file is missing: {relative}")
    try:
        value = yaml.load(path.read_text(encoding="utf-8"), Loader=UniqueLoader)
    except (OSError, UnicodeError, yaml.YAMLError) as error:
        raise RegistryError(f"cannot read {relative}: {error}") from error
    if not isinstance(value, dict):
        raise RegistryError(f"top-level mapping required: {relative}")
    return value


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _safe_path(value: object) -> bool:
    if not isinstance(value, str) or not value or "\\" in value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and ".." not in path.parts and value == path.as_posix()


def _rows(document: dict[str, Any], source: str) -> dict[str, dict[str, Any]]:
    raw = document.get("scenarios")
    if not isinstance(raw, list):
        raise RegistryError(f"{source} scenarios must be a list")
    rows: dict[str, dict[str, Any]] = {}
    for index, row in enumerate(raw):
        if not isinstance(row, dict) or not isinstance(row.get("scenario_id"), str):
            raise RegistryError(f"invalid scenario row: {source}[{index}]")
        scenario_id = row["scenario_id"]
        if scenario_id in rows:
            raise RegistryError(f"duplicate scenario ID in {source}: {scenario_id}")
        rows[scenario_id] = row
    return rows


def _runtime_profiles() -> dict[str, dict[str, object]]:
    layers: dict[str, dict[str, object]] = {}
    for layer_id, body in RUNTIME_LAYERS.items():
        contract = {"layer_id": layer_id, **body}
        layers[layer_id] = {
            **body,
            "layer_contract_sha256": canonical_sha256(PROFILE_DOMAIN, contract),
        }
    profiles: dict[str, dict[str, object]] = {}
    for profile_id, layer_ids in PROFILE_LAYERS.items():
        body = {
            "profile_id": profile_id,
            "layer_ids": list(layer_ids),
            "layer_contracts": [
                [layer_id, layers[layer_id]["layer_contract_sha256"]]
                for layer_id in layer_ids
            ],
        }
        profiles[profile_id] = {
            "layer_ids": list(layer_ids),
            "profile_sha256": canonical_sha256(PROFILE_DOMAIN, body),
        }
    return {"layers": layers, "profiles": profiles}


def _profile_id(row: dict[str, Any], runner_kind: str) -> str:
    declared = row.get("runtime_profile_id")
    if isinstance(declared, str):
        if declared not in PROFILE_LAYERS:
            raise RegistryError(f"unknown runtime profile: {declared}")
        return declared
    layers = row.get("runtime_layers")
    if isinstance(layers, list) and all(isinstance(value, str) for value in layers):
        profile = PROFILE_BY_LAYERS.get(tuple(layers))
        if profile is None:
            raise RegistryError(f"unregistered runtime layer sequence: {layers!r}")
        return profile
    return "FULL_STACK_BROWSER_V1" if runner_kind == "PLAYWRIGHT" else "FULL_STACK_RUST_V1"


def _rust_selector(scenario_id: str, path: str) -> dict[str, object]:
    target = Path(path).stem
    test_id = scenario_id.lower().replace("-", "_")
    expression = f"test(={test_id})"
    discovery_argv = [
        "cargo",
        "nextest",
        "list",
        "--locked",
        "--package",
        "gurine-acceptance-tests",
        "--test",
        target,
        "--message-format",
        "json",
        "--filter-expr",
        expression,
    ]
    run_argv = [
        "cargo",
        "nextest",
        "run",
        "--locked",
        "--package",
        "gurine-acceptance-tests",
        "--test",
        target,
        "--profile",
        "acceptance",
        "--filter-expr",
        expression,
        "--retries",
        "0",
        "--no-tests=fail",
        "--status-level",
        "all",
        "--final-status-level",
        "all",
    ]
    body: dict[str, object] = {
        "runner_kind": "RUST_NEXTEST",
        "package": "gurine-acceptance-tests",
        "test_target": target,
        "implementation_test_id": test_id,
        "exact_filter_expression": expression,
        "discovery_argv": discovery_argv,
        "run_argv": run_argv,
    }
    return {**body, "selector_sha256": canonical_sha256(SELECTOR_DOMAIN, body)}


def _playwright_selector(scenario_id: str, title: str, path: str) -> dict[str, object]:
    exact_title = f"[{scenario_id}] {title}"
    pattern = "^" + re.escape(exact_title) + "$"
    common = [
        "bunx",
        "playwright",
        "test",
        path,
        "--project=chromium",
        "--grep",
        pattern,
        "--retries=0",
        "--repeat-each=1",
        "--workers=1",
        "--reporter=json",
        "--forbid-only",
    ]
    body: dict[str, object] = {
        "runner_kind": "PLAYWRIGHT",
        "project": "chromium",
        "implementation_test_id": exact_title,
        "exact_title_pattern": pattern,
        "discovery_argv": [*common, "--list"],
        "run_argv": common,
    }
    return {**body, "selector_sha256": canonical_sha256(SELECTOR_DOMAIN, body)}


def _execution_contract(
    row: dict[str, Any],
    scenario_id: str,
    title: str,
) -> tuple[dict[str, object], str]:
    path = row.get("implementation_test_path")
    if not _safe_path(path) or not str(path).startswith("tests/"):
        raise RegistryError(f"unsafe implementation test path for {scenario_id}: {path!r}")
    if row.get("skip_policy") != "FORBIDDEN":
        raise RegistryError(f"skip policy is not FORBIDDEN: {scenario_id}")
    if str(path).endswith(".rs"):
        selector = _rust_selector(scenario_id, str(path))
        runner_kind = "RUST_NEXTEST"
        declared_test_id = row.get("implementation_test_id")
        if declared_test_id is not None and declared_test_id != selector["implementation_test_id"]:
            raise RegistryError(
                f"unstable implementation test ID for {scenario_id}: {declared_test_id!r}"
            )
    elif str(path).endswith(".spec.ts"):
        selector = _playwright_selector(scenario_id, title, str(path))
        runner_kind = "PLAYWRIGHT"
    else:
        raise RegistryError(f"unsupported acceptance runner path: {path}")
    profile_id = _profile_id(row, "PLAYWRIGHT" if runner_kind == "PLAYWRIGHT" else "RUST")
    return (
        {
            "implementation_test_path": path,
            "selector": selector,
            "runtime_profile_id": profile_id,
        },
        profile_id,
    )


def build_registry(root: Path = ROOT) -> dict[str, object]:
    root = root.resolve()
    lock = _load(root, BASE_LOCK)
    if lock.get("authority_zip_sha256") != AUTHORITY_ZIP_SHA256:
        raise RegistryError("base lock authority digest mismatch")
    feature_rows = lock.get("features")
    if not isinstance(feature_rows, list):
        raise RegistryError("base lock features must be a list")
    base_paths = []
    for row in feature_rows:
        if not isinstance(row, dict) or not isinstance(row.get("path"), str):
            raise RegistryError("invalid base feature lock row")
        relative = f"tests/acceptance/{row['path']}"
        path = root / relative
        if (
            path.is_symlink()
            or not path.is_file()
            or _sha256(path) != row.get("sha256")
            or path.stat().st_size != row.get("size")
        ):
            raise RegistryError(f"base feature lock mismatch: {relative}")
        base_paths.append(relative)
    all_paths = [
        path.relative_to(root).as_posix()
        for path in sorted((root / "tests/acceptance").glob("*.feature"))
    ]
    supplemental_paths = sorted(set(all_paths) - set(base_paths))
    if set(base_paths) - set(all_paths):
        raise RegistryError("a base feature is missing")

    contracts = compile_features(root, all_paths)
    contract_by_id = {row.scenario_id: row for row in contracts}
    if len(contract_by_id) != len(contracts):
        raise RegistryError("duplicate effective scenario ID")
    base_ids = {
        row.scenario_id for row in contracts if row.feature_file in set(base_paths)
    }
    supplemental_ids = set(contract_by_id) - base_ids

    base_document = _load(root, BASE_MAPPING)
    supplemental_document = _load(root, SUPPLEMENTAL_MAPPING)
    base_mapping = _rows(base_document, BASE_MAPPING)
    supplemental_mapping = _rows(supplemental_document, SUPPLEMENTAL_MAPPING)
    if set(base_mapping) != base_ids:
        raise RegistryError("base feature/mapping scenario set mismatch")
    if set(supplemental_mapping) != supplemental_ids:
        raise RegistryError("supplemental feature/mapping scenario set mismatch")
    if base_ids & supplemental_ids:
        raise RegistryError("base/supplemental scenario collision")
    if len(base_ids) != 271 or len(supplemental_ids) != 168:
        raise RegistryError(
            f"unexpected scenario counts: base={len(base_ids)}, supplemental={len(supplemental_ids)}"
        )

    runtime_contracts = _runtime_profiles()
    unique_source_steps = {
        (
            contract.feature_file,
            clause.source_line,
            clause.lexical_keyword,
            clause.text,
        )
        for contract in contracts
        for clause in contract.clauses
    }
    scenario_rows: list[dict[str, object]] = []
    for contract in contracts:
        origin = "BASE_V13" if contract.scenario_id in base_ids else "SUPPLEMENTAL_V1"
        mapping = (
            base_mapping[contract.scenario_id]
            if origin == "BASE_V13"
            else supplemental_mapping[contract.scenario_id]
        )
        if (
            mapping.get("feature_file") != contract.feature_file
            or mapping.get("scenario_title") != contract.scenario_title
        ):
            raise RegistryError(f"scenario identity mismatch: {contract.scenario_id}")
        execution, profile_id = _execution_contract(
            mapping,
            contract.scenario_id,
            contract.scenario_title,
        )
        profile = runtime_contracts["profiles"][profile_id]
        contract_row = contract.registry_row()
        observation_edges: list[dict[str, object]] = []
        oracle_edges: list[dict[str, object]] = []
        for layer_ordinal, layer_id in enumerate(profile["layer_ids"], start=1):
            layer_sha256 = runtime_contracts["layers"][layer_id][
                "layer_contract_sha256"
            ]
            for observation in contract_row["observation_contracts"]:
                edge_id = (
                    f"OLE-{observation['instance_id']}-L{layer_ordinal:02d}"
                )
                body = {
                    "edge_id": edge_id,
                    "scenario_id": contract.scenario_id,
                    "instance_id": observation["instance_id"],
                    "instance_sha256": observation["instance_sha256"],
                    "layer_id": layer_id,
                    "layer_contract_sha256": layer_sha256,
                }
                observation_edges.append(
                    {
                        **body,
                        "edge_sha256": canonical_sha256(
                            OBSERVATION_LAYER_DOMAIN, body
                        ),
                    }
                )
            for oracle_id, oracle_sha256 in contract_row["oracle_contracts"]:
                edge_id = f"RLE-{oracle_id}-L{layer_ordinal:02d}"
                body = {
                    "edge_id": edge_id,
                    "scenario_id": contract.scenario_id,
                    "oracle_id": oracle_id,
                    "oracle_sha256": oracle_sha256,
                    "layer_id": layer_id,
                    "layer_contract_sha256": layer_sha256,
                }
                oracle_edges.append(
                    {
                        **body,
                        "edge_sha256": canonical_sha256(
                            ORACLE_LAYER_DOMAIN, body
                        ),
                    }
                )
        scenario_rows.append(
            {
                "origin": origin,
                **contract_row,
                "feature_sha256": _sha256(root / contract.feature_file),
                "execution": execution,
                "runtime_profile_sha256": profile["profile_sha256"],
                "observation_layer_contracts": observation_edges,
                "oracle_layer_contracts": oracle_edges,
            }
        )

    feature_manifest = [
        {
            "path": relative,
            "origin": "BASE_V13" if relative in set(base_paths) else "SUPPLEMENTAL_V1",
            "size": (root / relative).stat().st_size,
            "sha256": _sha256(root / relative),
            "scenario_count": sum(row.feature_file == relative for row in contracts),
            "scenario_set_sha256": ordered_pair_set_sha256(
                (row.scenario_id, row.scenario_contract_sha256)
                for row in contracts
                if row.feature_file == relative
            ),
        }
        for relative in all_paths
    ]
    return {
        "schema_version": 3,
        "specification_version": "13.0.0",
        "status": "FINAL",
        "registry_kind": "EFFECTIVE_EXECUTABLE_ACCEPTANCE_CONTRACT",
        "source_derived": True,
        "runtime_state_embedded": False,
        "authority_zip_sha256": AUTHORITY_ZIP_SHA256,
        "generator": "scripts/generate_effective_execution_registry.py",
        "inputs": {
            "base_lock": {"path": BASE_LOCK, "sha256": _sha256(root / BASE_LOCK)},
            "base_mapping": {"path": BASE_MAPPING, "sha256": _sha256(root / BASE_MAPPING)},
            "supplemental_mapping": {
                "path": SUPPLEMENTAL_MAPPING,
                "sha256": _sha256(root / SUPPLEMENTAL_MAPPING),
            },
        },
        "counts": {
            "base_features": len(base_paths),
            "base_scenarios": len(base_ids),
            "supplemental_features": len(supplemental_paths),
            "supplemental_scenarios": len(supplemental_ids),
            "effective_features": len(all_paths),
            "effective_scenarios": len(contracts),
            "gherkin_source_steps": len(unique_source_steps),
            "gherkin_scenario_bound_clauses": sum(
                len(row.clauses) for row in contracts
            ),
            "gherkin_outlines": sum(row.scenario_kind == "OUTLINE" for row in contracts),
            "gherkin_examples": sum(len(row.examples) for row in contracts),
            "gherkin_clause_instances": sum(len(row.instances) for row in contracts),
            "gherkin_oracles": sum(
                len(row.registry_row()["oracle_contracts"]) for row in contracts
            ),
            "observation_layer_edges": sum(
                len(row["observation_layer_contracts"]) for row in scenario_rows
            ),
            "oracle_layer_edges": sum(
                len(row["oracle_layer_contracts"]) for row in scenario_rows
            ),
        },
        "scenario_sets": {
            "base_sha256": ordered_pair_set_sha256(
                (scenario_id, contract_by_id[scenario_id].scenario_contract_sha256)
                for scenario_id in base_ids
            ),
            "supplemental_sha256": ordered_pair_set_sha256(
                (scenario_id, contract_by_id[scenario_id].scenario_contract_sha256)
                for scenario_id in supplemental_ids
            ),
            "effective_sha256": ordered_pair_set_sha256(
                (row.scenario_id, row.scenario_contract_sha256) for row in contracts
            ),
        },
        "runtime_contracts": runtime_contracts,
        "features": feature_manifest,
        "scenarios": scenario_rows,
        "forbidden_runtime_keys": [
            "current_status",
            "execution_receipts",
            "implementation_status",
            "implementation_status_counts",
            "missing_execution_receipt_count",
            "missing_implementation_count",
            "release_gate",
        ],
    }


def render_registry(root: Path = ROOT) -> bytes:
    # JSON is valid YAML and gives one deterministic, duplicate-key-free encoding.
    return (
        json.dumps(
            build_registry(root),
            ensure_ascii=False,
            sort_keys=True,
            indent=2,
        )
        + "\n"
    ).encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--output", default=OUTPUT)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        rendered = render_registry(root)
    except (RegistryError, OSError, UnicodeError, ValueError) as error:
        print(f"EFFECTIVE_EXECUTION_REGISTRY: FAIL: {error}")
        return 1
    output = root / args.output
    if args.write:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(rendered)
        print(
            "EFFECTIVE_EXECUTION_REGISTRY: WROTE "
            f"{args.output} sha256={hashlib.sha256(rendered).hexdigest()}"
        )
        return 0
    if output.is_symlink() or not output.is_file():
        print(f"EFFECTIVE_EXECUTION_REGISTRY: FAIL: missing {args.output}")
        return 1
    current = output.read_bytes()
    if current != rendered:
        print(
            "EFFECTIVE_EXECUTION_REGISTRY: FAIL: generated bytes differ; "
            "run with --write"
        )
        return 1
    print(
        "EFFECTIVE_EXECUTION_REGISTRY: PASS "
        f"sha256={hashlib.sha256(current).hexdigest()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
