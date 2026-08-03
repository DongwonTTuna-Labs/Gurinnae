#!/usr/bin/env python3
"""Fail-closed Gurinnae structure lint and final design/release freeze gate."""

from __future__ import annotations

import sys

# This entry point must not contaminate the authority tree even when invoked
# without ``python -B``. Set the interpreter flag before local module imports.
sys.dont_write_bytecode = True

import argparse
import json
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from design_bundle_digest import (  # noqa: E402
    ROOT,
    BundleError,
    build_manifest,
)
from generate_effective_registry import (  # noqa: E402
    Checks,
    build_registry,
    problem_payload,
)
from validation.design_freeze_acceptance import (  # noqa: E402, F401
    validate_mapped_test_sources,
    validate_supplemental_acceptance_release,
)
from validation.design_freeze_authority import (  # noqa: E402, F401
    validate_authority_gate,
    validate_authority_payload,
)
from validation.design_freeze_contract import (  # noqa: E402, F401
    BLOCKER_KEYS,
    CLOSED,
    CONFLICT_STATUS_RE,
    DESIGN_STATUS_RE,
    EXPECTED_ADDITIVE_MIGRATIONS,
    EXPECTED_ADDITIVE_ORDINALS,
    FINAL_STATUS,
    FINDING_HEADING_RE,
    FOCUS_SOURCE_RE,
    ISO_TIME_RE,
    NORMATIVE_CATEGORIES,
    REVIEW_ROLE_REGISTRY,
    SKIP_SOURCE_RE,
    ZERO_COMMAND_RE,
    load_mapping as _load_mapping,
    safe_relative as _safe_relative,
)
from validation.design_freeze_reviews import (  # noqa: E402, F401
    _blocker_container_closed,
    _closed_blocker_value,
    _is_blocker_key,
    _iter_blocker_containers,
    _normative_category,
    _prior_finding_ids,
    load_required_review_roles,
    validate_normative_statuses,
    validate_reviews,
)
from validation.design_freeze_self_test import self_test  # noqa: E402


def run_validation(
    root: Path,
    mode: str,
) -> dict[str, object]:
    registry, structure_problems = build_registry(root)
    release_checks = Checks()
    manifest: dict[str, object] = {}
    if mode == "freeze":
        try:
            manifest = build_manifest(root)
        except BundleError as error:
            release_checks.require(
                False,
                "design_bundle",
                "design_bundle_digest.py",
                "canonical manifest",
                str(error),
            )
        if manifest:
            validate_normative_statuses(root, manifest, release_checks)
            validate_reviews(root, manifest, release_checks)
        validate_mapped_test_sources(root, release_checks)
        validate_supplemental_acceptance_release(root, release_checks)
        validate_authority_gate(root, release_checks)
        if manifest:
            _validate_manifest_stability(
                root,
                manifest,
                release_checks,
            )
    structure_result = "PASS" if not structure_problems else "FAIL"
    release_result = (
        "NOT_RUN"
        if mode == "lint"
        else (
            "PASS"
            if not structure_problems and not release_checks.problems
            else "FAIL"
        )
    )
    return {
        "schema_version": 1,
        "mode": mode,
        "structure_lint": structure_result,
        "release_freeze": release_result,
        "design_bundle": {
            key: manifest.get(key)
            for key in (
                "bundle_sha256",
                "member_manifest_sha256",
                "member_count",
                "category_counts",
            )
            if key in manifest
        },
        "effective_counts": registry.get("counts", {}),
        "structure_problem_count": len(structure_problems),
        "release_problem_count": len(release_checks.problems),
        "structure_problems": [
            problem_payload(problem) for problem in structure_problems
        ],
        "release_problems": [
            problem_payload(problem) for problem in release_checks.problems
        ],
    }


def _validate_manifest_stability(
    root: Path,
    manifest: dict[str, object],
    checks: Checks,
) -> None:
    try:
        final_manifest = build_manifest(root)
    except BundleError as error:
        checks.require(
            False,
            "design_bundle_stability",
            "design_bundle_digest.py",
            "stable canonical manifest",
            str(error),
        )
        return
    checksums = ("bundle_sha256", "member_manifest_sha256", "member_count")
    checks.require(
        all(final_manifest.get(key) == manifest.get(key) for key in checksums),
        "design_bundle_stability",
        "release freeze interval",
        {key: manifest.get(key) for key in checksums},
        {key: final_manifest.get(key) for key in checksums},
    )


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--mode", choices=("lint", "freeze"), default="freeze")
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--max-problems", type=int, default=100)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if args.self_test:
        passed, results = self_test()
        print(
            json.dumps(
                {
                    "self_test": "PASS" if passed else "FAIL",
                    "fixtures": results,
                },
                indent=2,
                sort_keys=True,
            )
        )
        print(f"SELF_TEST: {'PASS' if passed else 'FAIL'}")
        return 0 if passed else 1

    payload = run_validation(
        args.root.resolve(),
        args.mode,
    )
    if args.json_output is not None:
        args.json_output.write_text(
            json.dumps(payload, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )
    display = dict(payload)
    display["structure_problems"] = display["structure_problems"][
        : max(0, args.max_problems)
    ]
    display["release_problems"] = display["release_problems"][
        : max(0, args.max_problems)
    ]
    print(json.dumps(display, ensure_ascii=False, sort_keys=True, indent=2))
    print(f"STRUCTURE_LINT: {payload['structure_lint']}")
    print(f"RELEASE_FREEZE: {payload['release_freeze']}")
    return (
        0
        if payload["structure_lint"] == "PASS"
        and payload["release_freeze"] in {"PASS", "NOT_RUN"}
        else 1
    )


if __name__ == "__main__":
    raise SystemExit(main())
