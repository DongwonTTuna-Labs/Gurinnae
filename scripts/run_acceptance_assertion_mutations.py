#!/usr/bin/env python3
"""Run registry-derived observation sentinels for one acceptance scenario."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

from run_acceptance import (
    AcceptanceRunError,
    ExclusiveRunDirectory,
    ensure_external_directory,
    mutation_runs,
    seal_payload,
    sha256_file,
)
from validation.acceptance_machine import MachineReportError
from validation.effective_acceptance import validate_sources, validate_static


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--scenario-id", required=True)
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    args = parser.parse_args()
    root = args.root.resolve()
    if args.timeout_seconds < 1:
        raise AcceptanceRunError("timeout must be positive")
    structural, registry = validate_static(root)
    if structural.problems:
        raise AcceptanceRunError(f"acceptance contract is invalid: {structural.problems[:3]}")
    source = validate_sources(root, registry)
    if source.problems:
        raise AcceptanceRunError(f"acceptance source is invalid: {source.problems[:3]}")
    matches = [
        row for row in registry["scenarios"] if row.get("scenario_id") == args.scenario_id
    ]
    if len(matches) != 1:
        raise AcceptanceRunError(
            f"scenario must resolve exactly once in the static registry: {args.scenario_id}"
        )
    row = matches[0]
    profile_id = row["execution"]["runtime_profile_id"]
    layer_ids = list(
        registry["runtime_contracts"]["profiles"][profile_id]["layer_ids"]
    )
    evidence_root = ensure_external_directory(args.evidence_root, root)
    run = ExclusiveRunDirectory(evidence_root, args.run_id)
    summary, _ = mutation_runs(
        run,
        root,
        row,
        dict(os.environ),
        layer_ids,
        args.timeout_seconds,
    )
    index = run.write_json(
        "mutation-index.json",
        {
            "schema_version": 1,
            "index_kind": "ACCEPTANCE_OBSERVATION_MUTATION_INDEX",
            "run_id": args.run_id,
            "scenario_id": args.scenario_id,
            "scenario_contract_sha256": row["scenario_contract_sha256"],
            "selector_sha256": row["execution"]["selector"]["selector_sha256"],
            "summary_path": summary.relative_to(run.path).as_posix(),
            "summary_sha256": sha256_file(summary),
        },
    )
    seal = seal_payload(run, index)
    seal_path = run.write_json("seal.json", seal)
    run.fsync_directories()
    print(
        json.dumps(
            {
                "result": "PASS",
                "scenario_id": args.scenario_id,
                "summary": str(summary),
                "seal": str(seal_path),
            },
            ensure_ascii=False,
            sort_keys=True,
        )
    )
    print("ACCEPTANCE_OBSERVATION_MUTATIONS: PASS")
    return 0


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    try:
        raise SystemExit(main())
    except (AcceptanceRunError, MachineReportError, OSError, ValueError) as error:
        print(f"ACCEPTANCE_OBSERVATION_MUTATIONS: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
