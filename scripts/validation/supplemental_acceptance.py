#!/usr/bin/env python3
"""Validate the byte-locked base and complete effective acceptance hard gate."""
from __future__ import annotations

import sys
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "validation"

import argparse
import json

from .effective_acceptance import validate
from .effective_acceptance_self_test import ROOT, self_test

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument(
        "--mode",
        choices=("structure", "release"),
        default="release",
    )
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--max-problems", type=int, default=100)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        passed, fixtures = self_test()
        payload = {
            "self_test": "PASS" if passed else "FAIL",
            "fixtures": fixtures,
        }
        print(json.dumps(payload, indent=2, sort_keys=True, default=str))
        print(f"SELF_TEST: {'PASS' if passed else 'FAIL'}")
        return 0 if passed else 1

    payload = validate(args.root.resolve(), args.mode)
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(
            json.dumps(
                payload,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
                default=str,
            )
            + "\n",
            encoding="utf-8",
        )
    display = dict(payload)
    maximum = max(args.max_problems, 0)
    display["structure_problems"] = display["structure_problems"][:maximum]
    display["release_problems"] = display["release_problems"][:maximum]
    print(
        json.dumps(
            display,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
            default=str,
        )
    )
    print(f"STRUCTURE_MAPPING: {payload['structure_mapping']}")
    print(f"RELEASE_GATE: {payload['release_gate']}")
    return (
        0
        if payload["structure_mapping"] == "PASS"
        and payload["release_gate"] in {"PASS", "NOT_RUN"}
        else 1
    )


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    raise SystemExit(main())
