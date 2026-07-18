"""Release receipt and executable-test validation."""
from __future__ import annotations

from dataclasses import asdict
from datetime import datetime
from pathlib import Path
from typing import Any

from .supplemental_acceptance_core import (
    ASSERTION,
    ISO_TIME,
    RECEIPT_KEYS,
    SHA256,
    SOURCE_FOCUS,
    SOURCE_SKIP,
    TRIVIAL_ASSERTION,
    Checks,
    Problem,
    digest_bytes,
    digest_file,
    safe_path,
)
from .supplemental_acceptance_registry import _source_segments, structure
from .supplemental_acceptance_assertions import validate_assertion_mutations
from .supplemental_acceptance_source import (
    executable_source,
    rust_assertion_facts,
    source_without_comments,
)


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def release(
    root: Path,
    mapped: dict[str, dict[str, Any]],
    receipts: dict[str, dict[str, Any]],
) -> Checks:
    checks = Checks("release")
    implemented = {
        scenario_id: row
        for scenario_id, row in mapped.items()
        if row.get("implementation_status") == "IMPLEMENTED"
    }
    for scenario_id, row in mapped.items():
        checks.need(
            row.get("implementation_status") == "IMPLEMENTED",
            "implementation_missing",
            scenario_id,
            "IMPLEMENTED",
            row.get("implementation_status"),
        )

    grouped: dict[str, list[dict[str, Any]]] = {}
    source_digests: dict[str, str] = {}
    assertion_counts: dict[str, int] = {}
    assertion_ordinals: dict[str, tuple[int, ...]] = {}
    for row in implemented.values():
        relative = row.get("implementation_test_path")
        if isinstance(relative, str):
            grouped.setdefault(relative, []).append(row)

    for relative, rows in grouped.items():
        path = root / relative
        if path.is_symlink() or not path.is_file():
            checks.need(
                False,
                "missing_test",
                relative,
                "regular implementation test",
                "missing",
            )
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            checks.need(
                False,
                "test_unreadable",
                relative,
                "UTF-8",
                str(error),
            )
            continue
        source_digests[relative] = digest_file(path)
        executable_text = executable_source(path, text)
        checks.need(
            SOURCE_SKIP.search(executable_text) is None,
            "skipped_test",
            relative,
            "absent",
            "skip/fixme/ignore marker",
        )
        checks.need(
            SOURCE_FOCUS.search(executable_text) is None,
            "focused_test",
            relative,
            "absent",
            "only/focus marker",
        )
        segments, _ = _source_segments(path, text, rows, checks)
        for row in rows:
            scenario_id = str(row.get("scenario_id"))
            test_id = str(row.get("implementation_test_id"))
            segment = segments.get(scenario_id, "")
            executable_segment = executable_source(path, segment)
            uncommented_segment = source_without_comments(path, segment)
            checks.need(
                scenario_id in uncommented_segment and test_id in executable_segment,
                "scenario_not_executable",
                scenario_id,
                {"scenario_id": scenario_id, "test_id": test_id},
                "missing literal in executable test body",
            )
            rust_facts = rust_assertion_facts(path, segment, scenario_id)
            assertion_count = (
                rust_facts.count
                if rust_facts is not None
                else len(ASSERTION.findall(executable_segment))
            )
            assertion_counts[scenario_id] = assertion_count
            if rust_facts is not None:
                assertion_ordinals[scenario_id] = rust_facts.ordinals
                checks.need(
                    rust_facts.binding_valid
                    and rust_facts.ordinals
                    == tuple(range(1, rust_facts.count + 1)),
                    "assertion_binding",
                    scenario_id,
                    list(range(1, rust_facts.count + 1)),
                    {
                        "ordinals": list(rust_facts.ordinals),
                        "binding_valid": rust_facts.binding_valid,
                    },
                )
            checks.need(
                assertion_count > 0,
                "zero_assertion",
                scenario_id,
                ">=1",
                assertion_count,
            )
            checks.need(
                not rust_facts.trivial
                if rust_facts is not None
                else TRIVIAL_ASSERTION.search(executable_segment) is None,
                "trivial_assertion",
                scenario_id,
                "nontrivial assertion",
                "assert true",
            )

    checks.same(
        set(mapped),
        set(receipts),
        "supplemental mapped/executed receipt identity",
        ("mapped", "receipts"),
    )
    for scenario_id, row in mapped.items():
        receipt = receipts.get(scenario_id)
        if receipt is None:
            continue
        checks.need(
            set(receipt) == RECEIPT_KEYS,
            "execution_receipt_schema",
            scenario_id,
            sorted(RECEIPT_KEYS),
            sorted(str(key) for key in receipt),
        )
        command = row.get("command")
        command_digest = (
            digest_bytes(command.encode("utf-8"))
            if isinstance(command, str)
            else None
        )
        test_path = row.get("implementation_test_path")
        expected_source_digest = (
            source_digests.get(test_path)
            if isinstance(test_path, str)
            else None
        )
        expected = {
            "receipt_id": row.get("execution_receipt_id"),
            "scenario_id": scenario_id,
            "discovery_receipt_id": row.get("discovery_receipt_id"),
            "assertion_contract_id": row.get("assertion_contract_id"),
            "status": "PASSED",
            "implementation_test_path": test_path,
            "implementation_test_id": row.get("implementation_test_id"),
            "test_source_sha256": expected_source_digest,
            "command": command,
            "command_sha256": command_digest,
            "runtime_layers": row.get("runtime_layers"),
            "exit_code": 0,
            "selected_test_count": 1,
            "pass_count": 1,
            "failed_test_count": 0,
            "skipped_test_count": 0,
        }
        for key, value in expected.items():
            checks.need(
                receipt.get(key) == value,
                "execution_receipt",
                f"{scenario_id}.{key}",
                value,
                receipt.get(key),
            )
        for key in (
            "exit_code",
            "selected_test_count",
            "pass_count",
            "failed_test_count",
            "skipped_test_count",
        ):
            checks.need(
                _is_int(receipt.get(key)),
                "execution_receipt",
                f"{scenario_id}.{key}",
                "integer (boolean forbidden)",
                receipt.get(key),
            )

        assertion_count = receipt.get("assertion_count")
        observed_minimum = max(1, assertion_counts.get(scenario_id, 0))
        checks.need(
            _is_int(assertion_count) and assertion_count == observed_minimum,
            "execution_receipt",
            f"{scenario_id}.assertion_count",
            observed_minimum,
            assertion_count,
        )
        command_value = row.get("command")
        if isinstance(command_value, str):
            validate_assertion_mutations(
                root,
                scenario_id,
                command_value,
                assertion_ordinals.get(
                    scenario_id,
                    tuple(range(1, observed_minimum + 1)),
                ),
                receipt.get("assertion_mutations"),
                checks,
            )
        timestamp = receipt.get("executed_at")
        valid_time = (
            isinstance(timestamp, datetime) and timestamp.tzinfo is not None
        ) or (
            isinstance(timestamp, str)
            and ISO_TIME.fullmatch(timestamp) is not None
        )
        checks.need(
            valid_time,
            "execution_receipt_time",
            scenario_id,
            "timezone-aware ISO-8601",
            timestamp,
        )
        artifacts = receipt.get("artifacts")
        checks.need(
            isinstance(artifacts, list) and bool(artifacts),
            "execution_artifacts",
            scenario_id,
            ">=1",
            artifacts,
        )
        for artifact in artifacts if isinstance(artifacts, list) else []:
            valid = (
                isinstance(artifact, dict)
                and set(artifact) == {"path", "sha256"}
                and safe_path(artifact.get("path"))
            )
            artifact_path = (
                root / str(artifact.get("path"))
                if valid
                else root / "__invalid__"
            )
            actual = (
                digest_file(artifact_path)
                if artifact_path.is_file() and not artifact_path.is_symlink()
                else "missing"
            )
            checks.need(
                valid
                and SHA256.fullmatch(str(artifact.get("sha256"))) is not None
                and artifact.get("sha256") == actual,
                "execution_artifact",
                scenario_id,
                {"regular_file_sha256": actual},
                artifact,
            )
    return checks


def _fatal_payload(mode: str, error: Exception) -> dict[str, object]:
    problem = Problem(
        phase="structure",
        code="validator_internal_error",
        source="scripts/validation/supplemental_acceptance.py",
        expected="deterministic fail-closed result",
        actual=f"{type(error).__name__}: {error}",
    )
    return {
        "schema_version": 1,
        "mode": mode,
        "structure_mapping": "FAIL",
        "release_gate": "NOT_RUN" if mode == "structure" else "FAIL",
        "counts": {
            "base_features_locked": 0,
            "base_scenarios_locked": 0,
            "supplemental_features_discovered": 0,
            "supplemental_scenarios_discovered": 0,
            "supplemental_scenarios_mapped": 0,
            "effective_features": 0,
            "effective_scenarios": 0,
            "acceptance_overlays": 0,
            "implementation_missing": 0,
            "execution_receipts": 0,
        },
        "discovery_receipt": {},
        "structure_problem_count": 1,
        "release_problem_count": 0,
        "structure_problems": [asdict(problem)],
        "release_problems": [],
    }


def validate(root: Path, mode: str) -> dict[str, object]:
    try:
        (
            structural,
            base,
            paths,
            scenarios,
            mapped,
            receipts,
            discovery,
            overlay_count,
        ) = structure(root)
        runtime = (
            release(root, mapped, receipts)
            if mode == "release"
            else Checks("release")
        )
    except Exception as error:
        return _fatal_payload(mode, error)

    structure_status = "PASS" if not structural.problems else "FAIL"
    release_status = (
        "NOT_RUN"
        if mode == "structure"
        else (
            "PASS"
            if structure_status == "PASS" and not runtime.problems
            else "FAIL"
        )
    )
    base_feature_count = len(base.feature_names)
    base_scenario_count = len(base.scenarios)
    return {
        "schema_version": 1,
        "mode": mode,
        "structure_mapping": structure_status,
        "release_gate": release_status,
        "counts": {
            "base_features_locked": base_feature_count,
            "base_scenarios_locked": base_scenario_count,
            "supplemental_features_discovered": len(paths),
            "supplemental_scenarios_discovered": len(scenarios),
            "supplemental_scenarios_mapped": len(mapped),
            "effective_features": base_feature_count + len(paths),
            "effective_scenarios": base_scenario_count + len(scenarios),
            "acceptance_overlays": overlay_count,
            "implementation_missing": sum(
                row.get("implementation_status") != "IMPLEMENTED"
                for row in mapped.values()
            ),
            "execution_receipts": len(receipts),
        },
        "discovery_receipt": discovery,
        "structure_problem_count": len(structural.problems),
        "release_problem_count": len(runtime.problems),
        "structure_problems": [
            asdict(problem) for problem in structural.problems
        ],
        "release_problems": [asdict(problem) for problem in runtime.problems],
    }
