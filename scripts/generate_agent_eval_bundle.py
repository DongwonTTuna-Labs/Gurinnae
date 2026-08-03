#!/usr/bin/env python3
"""Bundle all 50 authority agent evaluations for Rust's offline hard gate."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
AGENTS = ROOT / "specs/agents"


def main() -> None:
    manifest = yaml.safe_load((AGENTS / "eval-manifest.yaml").read_text())
    prompts = {
        agent: (AGENTS / agent / "prompt.md").read_text()
        for agent in {case["agent_id"] for case in manifest["cases"]}
    }
    cases = []
    for record in manifest["cases"]:
        directory = AGENTS / record["directory"]
        cases.append({
            **record,
            "prompt": prompts[record["agent_id"]],
            "scenario": yaml.safe_load((directory / "scenario.yaml").read_text()),
            "input": json.loads((directory / "input.json").read_text()),
            "provider": json.loads((directory / "provider-response.json").read_text()),
            "transcript": json.loads((directory / "tool-transcript.json").read_text()),
            "expected": json.loads((directory / "expected-output.json").read_text()),
        })
    output = ROOT / "verification/agent-eval-bundle.json"
    output.write_text(json.dumps(cases, ensure_ascii=False, indent=2) + "\n")
    subprocess.run(
        ["bunx", "biome", "format", "--write", str(output)],
        cwd=ROOT,
        check=True,
    )
    print(f"bundled {len(cases)} agent evaluations")


if __name__ == "__main__":
    main()
