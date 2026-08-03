"""Mutation fixtures for the effective acceptance false-green boundary."""
from __future__ import annotations

from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import textwrap

from jsonschema import Draft202012Validator

from generate_effective_execution_registry import (
    CURRENT_EFFECTIVE_SCENARIO_COUNT,
    CURRENT_SUPPLEMENTAL_SCENARIO_COUNT,
    FROZEN_BASE_SCENARIO_COUNT,
    build_registry,
)
from generate_supplemental_execution_mapping import build_mapping
from .acceptance_gherkin import GherkinContractError, compile_feature
from .effective_acceptance import (
    EXECUTION_SCHEMA,
    EXTRACTION_SCHEMA,
    LAYER_SCHEMA,
    RUN_INDEX_SCHEMA,
    _schema_registry,
    _walk_keys,
)


ROOT = Path(__file__).resolve().parents[2]
SHA = "0" * 64
TIME = "2026-07-18T00:00:00Z"


def _feature(body: str):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "fixture.feature"
        path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
        return compile_feature(path, "tests/acceptance/fixture.feature")


def _base_feature() -> str:
    return """
        @hard-gate @final
        Feature: fixture
          Background:
            Given 공통 전제다
            And 공통 상세다
          # scenario-id: AC-FIXTURE-001
          Scenario Outline: exact
            Given 값은 <value>다
            When 실행한다
            Then 결과는 <result>다
            Examples:
              | value | result |
              | 하나  | 성공   |
              | 둘    | 거부   |
    """


def _layer() -> dict[str, object]:
    artifact = {
        "path": "artifacts/probe.json",
        "sha256": SHA,
        "size": 1,
        "media_type": "application/json",
    }
    stdout_artifact = {
        "path": "artifacts/probe.stdout.json",
        "sha256": SHA,
        "size": 1,
        "media_type": "application/json",
    }
    stderr_artifact = {
        "path": "artifacts/probe.stderr",
        "sha256": SHA,
        "size": 1,
        "media_type": "application/octet-stream",
    }
    return {
        "schema_version": 2,
        "receipt_kind": "ACCEPTANCE_RUNTIME_LAYER_V2",
        "scenario_id": "AC-FIXTURE-001",
        "runtime_profile_id": "FULL_STACK_RUST_V1",
        "runtime_profile_sha256": SHA,
        "layer_id": "rust-1.97.0-domain-application",
        "layer_contract_sha256": SHA,
        "probe_kind": "RUST_TOOLCHAIN_AND_BINARY",
        "status": "PASSED",
        "started_at": TIME,
        "duration_ms": 1,
        "environment_digest": SHA,
        "oracle_contracts": [["OR-GI-AC-FIXTURE-001-NONE-S-001", SHA]],
        "oracle_layer_contracts": [["RLE-OR-GI-AC-FIXTURE-001-NONE-S-001-L01", SHA]],
        "probe_argv": ["rustc", "--version", "--verbose"],
        "probe_argv_sha256": SHA,
        "probe_facts": {
            "kind": "RUST_TOOLCHAIN_AND_BINARY",
            "rustc_version": "rustc 1.97.0 (fixture)",
            "rustc_verbose_sha256": SHA,
            "cargo_metadata_sha256": SHA,
            "test_binary_sha256": SHA,
            "test_target": "fixture",
            "test_identity": "ac_fixture_001",
            "effect_receipt_sha256": SHA,
        },
        "probe_facts_sha256": SHA,
        "probe_exit_code": 0,
        "probe_stdout_sha256": SHA,
        "probe_stderr_sha256": SHA,
        "probe_stdout_artifact": stdout_artifact,
        "probe_stderr_artifact": stderr_artifact,
        "raw_probe_artifact": artifact,
        "artifacts": [artifact, stdout_artifact, stderr_artifact],
    }


def _execution() -> dict[str, object]:
    bindings = {
        "authority_zip_sha256": SHA,
        "design_bundle_sha256": SHA,
        "member_manifest_sha256": SHA,
        "effective_registry_sha256": SHA,
        "base_mapping_sha256": SHA,
        "supplemental_mapping_sha256": SHA,
        "feature_sha256": SHA,
        "scenario_contract_sha256": SHA,
        "source_commit": "0" * 40,
        "source_tree_sha256": SHA,
        "test_source_sha256": SHA,
        "selector_sha256": SHA,
        "archive_sha256": SHA,
        "extraction_receipt_sha256": SHA,
    }
    artifact = {
        "path": "artifacts/result.json",
        "sha256": SHA,
        "size": 1,
        "media_type": "application/json",
    }
    return {
        "schema_version": 3,
        "receipt_kind": "ACCEPTANCE_SCENARIO_EXECUTION",
        "receipt_id": "ACR-run-0001-AC-FIXTURE-001",
        "run_id": "run-0001",
        "attempt": 1,
        "status": "PASSED",
        "origin": "BASE_V13",
        "scenario_id": "AC-FIXTURE-001",
        "feature_file": "tests/acceptance/fixture.feature",
        "scenario_title": "fixture",
        "bindings": bindings,
        "invocation": {
            "runner_kind": "RUST_NEXTEST",
            "implementation_test_path": "tests/integration/acceptance/fixture.rs",
            "implementation_test_id": "ac_fixture_001",
            "discovery_argv": ["cargo", "nextest", "list"],
            "run_argv": ["cargo", "nextest", "run"],
            "run_argv_sha256": SHA,
        },
        "runtime_profile_id": "FULL_STACK_RUST_V1",
        "runtime_profile_sha256": SHA,
        "layer_receipts": [_layer()],
        "started_at": TIME,
        "duration_ms": 1,
        "exit_code": 0,
        "counts": {
            "discovered": 1,
            "started": 1,
            "terminal": 1,
            "passed": 1,
            "failed": 0,
            "skipped": 0,
            "retried": 0,
            "assertions": 1,
        },
        "observations": {
            "clause_contracts": [],
            "example_contracts": [],
            "instance_contracts": [["GI-AC-FIXTURE-001-NONE-S-001", SHA]],
            "oracle_contracts": [["OR-GI-AC-FIXTURE-001-NONE-S-001", SHA]],
            "observation_contracts": [
                {
                    "instance_id": "GI-AC-FIXTURE-001-NONE-S-001",
                    "instance_sha256": SHA,
                    "clause_id": "GH-AC-FIXTURE-001-S-001",
                    "clause_sha256": SHA,
                    "example_id": "NONE",
                    "example_sha256": None,
                    "phase": "THEN",
                    "oracle_contract": ["OR-GI-AC-FIXTURE-001-NONE-S-001", SHA],
                }
            ],
            "assertion_event_artifact": artifact,
        },
        "artifacts": [artifact],
    }


def _extraction() -> dict[str, object]:
    return {
        "schema_version": 1,
        "receipt_kind": "CLEAN_SOURCE_ARCHIVE_EXTRACTION",
        "status": "PASSED",
        "verified_at": TIME,
        "archive_sha256": SHA,
        "source_tree_sha256": SHA,
        "design_bundle_sha256": SHA,
        "member_manifest_sha256": SHA,
        "manifest_sha256": SHA,
        "archive_member_count": 1,
        "extracted_member_count": 1,
        "residue_paths": [],
        "verification_argv": ["python", "verify_source_archive.py"],
        "artifacts": [
            {
                "path": "logs/verify.json",
                "sha256": SHA,
                "size": 1,
                "media_type": "application/json",
            }
        ],
    }


def _index() -> dict[str, object]:
    receipts = [
        {
            "scenario_id": f"AC-FIXTURE-{index:03d}",
            "origin": (
                "BASE_V13"
                if index <= FROZEN_BASE_SCENARIO_COUNT
                else "SUPPLEMENTAL_V1"
            ),
            "path": f"receipts/AC-FIXTURE-{index:03d}.json",
            "sha256": hashlib.sha256(str(index).encode()).hexdigest(),
            "size": 1,
        }
        for index in range(1, CURRENT_EFFECTIVE_SCENARIO_COUNT + 1)
    ]
    return {
        "schema_version": 1,
        "index_kind": "ACCEPTANCE_RUN_INDEX",
        "run_id": "run-0001",
        "status": "PASSED",
        "started_at": TIME,
        "completed_at": TIME,
        "bindings": {
            "authority_zip_sha256": SHA,
            "design_bundle_sha256": SHA,
            "member_manifest_sha256": SHA,
            "effective_registry_sha256": SHA,
            "source_commit": "0" * 40,
            "source_tree_sha256": SHA,
            "archive_sha256": SHA,
            "extraction_receipt_sha256": SHA,
        },
        "counts": {
            "base_scenarios": FROZEN_BASE_SCENARIO_COUNT,
            "supplemental_scenarios": CURRENT_SUPPLEMENTAL_SCENARIO_COUNT,
            "effective_scenarios": CURRENT_EFFECTIVE_SCENARIO_COUNT,
            "passed": CURRENT_EFFECTIVE_SCENARIO_COUNT,
            "failed": 0,
            "skipped": 0,
            "retried": 0,
        },
        "scenario_sets": {
            "base_sha256": SHA,
            "supplemental_sha256": SHA,
            "effective_sha256": SHA,
        },
        "receipts": receipts,
        "aggregate_sha256": SHA,
    }


def self_test() -> tuple[bool, list[dict[str, object]]]:
    schemas, schema_registry = _schema_registry(ROOT)
    results: list[dict[str, object]] = []

    def record(name: str, passed: bool) -> None:
        results.append({"fixture": name, "status": "PASS" if passed else "FAIL"})

    compiled = _feature(_base_feature())[0]
    record("positive-gherkin", len(compiled.clauses) == 5 and len(compiled.instances) == 10)
    registry = build_registry(ROOT)
    mapping = build_mapping(ROOT)
    record(
        "effective-counts",
        registry["counts"]["effective_scenarios"]
        == CURRENT_EFFECTIVE_SCENARIO_COUNT,
    )
    record("mapping-status-free", "implementation_status" not in json.dumps(mapping))
    record("registry-runtime-state-free", "execution_receipts" not in set(_walk_keys(registry)))
    record(
        "then-only-oracle-parity",
        all(
            len(row["oracle_contracts"])
            == sum(
                observation.get("phase") == "THEN"
                for observation in row["observation_contracts"]
            )
            and all(
                (observation.get("oracle_contract") is not None)
                == (observation.get("phase") == "THEN")
                for observation in row["observation_contracts"]
            )
            for row in registry["scenarios"]
        ),
    )

    feature_mutations = {
        "missing-scenario-id": _base_feature().replace("# scenario-id: AC-FIXTURE-001\n", ""),
        "duplicate-scenario-id": _base_feature() + "\n  # scenario-id: AC-FIXTURE-001\n  Scenario: duplicate\n    Given x\n",
        "outline-without-examples": _base_feature().split("            Examples:")[0],
        "unknown-placeholder": _base_feature().replace("<value>", "<missing>", 1),
        "duplicate-example-header": _base_feature().replace("| value | result |", "| value | value |"),
        "examples-width": _base_feature().replace("| 하나  | 성공   |", "| 하나 |"),
        "orphan-and": _base_feature().replace("Given 공통 전제다", "And 공통 전제다"),
    }
    for name, text in feature_mutations.items():
        try:
            _feature(text)
            rejected = False
        except GherkinContractError:
            rejected = True
        record(name, rejected)
    digest_mutations = {
        "step-text": _base_feature().replace("결과는 <result>다", "결과는 <result>가 아니다"),
        "step-order": _base_feature().replace("When 실행한다\n            Then 결과는 <result>다", "Then 결과는 <result>다\n            When 실행한다"),
        "background-loss": _base_feature().replace("            And 공통 상세다\n", ""),
        "example-value": _base_feature().replace("| 하나  | 성공   |", "| 하나  | 실패   |"),
        "example-row-order": _base_feature().replace("| 하나  | 성공   |\n              | 둘    | 거부   |", "| 둘    | 거부   |\n              | 하나  | 성공   |"),
        "example-row-drop": _base_feature().replace("              | 둘    | 거부   |\n", ""),
    }
    for name, text in digest_mutations.items():
        try:
            changed = _feature(text)[0].scenario_contract_sha256 != compiled.scenario_contract_sha256
        except GherkinContractError:
            changed = True
        record(name, changed)

    schema_cases = [
        ("layer-positive", LAYER_SCHEMA, _layer(), True),
        ("layer-extra-key", LAYER_SCHEMA, {**_layer(), "echo": True}, False),
        ("layer-empty-artifact", LAYER_SCHEMA, {**_layer(), "artifacts": []}, False),
        ("layer-bad-contract-digest", LAYER_SCHEMA, {**_layer(), "layer_contract_sha256": "x"}, False),
        ("layer-missing-raw-probe", LAYER_SCHEMA, {key: value for key, value in _layer().items() if key != "raw_probe_artifact"}, False),
        ("layer-negative-duration", LAYER_SCHEMA, {**_layer(), "duration_ms": -1}, False),
        ("execution-positive", EXECUTION_SCHEMA, _execution(), True),
        ("execution-retry", EXECUTION_SCHEMA, {**_execution(), "attempt": 2}, False),
        ("execution-skip", EXECUTION_SCHEMA, {**_execution(), "counts": {**_execution()["counts"], "skipped": 1}}, False),
        ("execution-zero-assertion", EXECUTION_SCHEMA, {**_execution(), "counts": {**_execution()["counts"], "assertions": 0}}, False),
        ("execution-missing-layer", EXECUTION_SCHEMA, {**_execution(), "layer_receipts": []}, False),
        ("execution-extra-key", EXECUTION_SCHEMA, {**_execution(), "release_gate": "PASS"}, False),
        ("extraction-positive", EXTRACTION_SCHEMA, _extraction(), True),
        ("extraction-residue", EXTRACTION_SCHEMA, {**_extraction(), "residue_paths": ["target"]}, False),
        ("extraction-bad-archive", EXTRACTION_SCHEMA, {**_extraction(), "archive_sha256": "x"}, False),
        ("index-positive", RUN_INDEX_SCHEMA, _index(), True),
        ("index-omission", RUN_INDEX_SCHEMA, {**_index(), "receipts": _index()["receipts"][:-1]}, False),
        (
            "index-legacy-total",
            RUN_INDEX_SCHEMA,
            {
                **_index(),
                "counts": {
                    **_index()["counts"],
                    "supplemental_scenarios": (
                        CURRENT_SUPPLEMENTAL_SCENARIO_COUNT - 7
                    ),
                    "effective_scenarios": CURRENT_EFFECTIVE_SCENARIO_COUNT - 7,
                    "passed": CURRENT_EFFECTIVE_SCENARIO_COUNT - 7,
                },
            },
            False,
        ),
        ("index-retry", RUN_INDEX_SCHEMA, {**_index(), "counts": {**_index()["counts"], "retried": 1}}, False),
    ]
    for name, schema_name, value, expected_valid in schema_cases:
        valid = not list(Draft202012Validator(schemas[schema_name], registry=schema_registry).iter_errors(value))
        record(name, valid == expected_valid)

    return all(row["status"] == "PASS" for row in results), results


if __name__ == "__main__":
    passed, fixture_rows = self_test()
    print(json.dumps(fixture_rows, ensure_ascii=False, sort_keys=True, indent=2))
    raise SystemExit(0 if passed else 1)
