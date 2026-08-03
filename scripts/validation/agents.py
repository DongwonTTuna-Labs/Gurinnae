from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

from .loaders import load_json, load_yaml
from .models import Validation


def validate(root: Path, result: Validation) -> None:
    catalog = load_yaml(root / "specs/agents/agent-catalog.yaml")
    tools = load_yaml(root / "specs/agents/tool-catalog.yaml")
    manifest = load_yaml(root / "specs/agents/eval-manifest.yaml")
    result.require(
        len(catalog["agents"]) == 5,
        f"expected 5 agents, found {len(catalog['agents'])}",
    )
    result.require(
        len(tools["tools"]) == 9,
        f"expected 9 tools, found {len(tools['tools'])}",
    )
    cases = manifest["cases"]
    result.require(len(cases) == 50, f"expected 50 agent cases, found {len(cases)}")
    allowed = {tool["id"] for tool in tools["tools"]}
    for agent in catalog["agents"]:
        directory = root / "specs/agents" / agent["id"]
        for name in ("prompt.md", "input.schema.json", "output.schema.json", "evals.yaml"):
            result.require((directory / name).is_file(), f"{agent['id']}: missing {name}")
        result.require(set(agent["tools"]) <= allowed, f"{agent['id']}: unknown tool")
        prompt = (directory / "prompt.md").read_text(encoding="utf-8").lower()
        for word in ("evidence", "abstain", "publish", "state"):
            result.require(word in prompt, f"{agent['id']}: prompt missing {word}")
        result.require(
            len(load_yaml(directory / "evals.yaml")["cases"]) == 10,
            f"{agent['id']}: expected 10 eval cases",
        )
    for case in cases:
        directory = root / "specs/agents" / case["directory"]
        for name in (
            "input.json",
            "provider-response.json",
            "tool-transcript.json",
            "expected-output.json",
            "scenario.yaml",
        ):
            result.require(
                (directory / name).is_file(),
                f"agent case {case['case_id']}: missing {name}",
            )

    environment = dict(os.environ)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    output = root / "verification/agent-reference.json"
    reference = subprocess.run(
        [
            sys.executable,
            "-B",
            str(root / "specs/agents/reference_harness.py"),
            "--json-output",
            str(output),
        ],
        cwd=root,
        env=environment,
        text=True,
        capture_output=True,
        timeout=300,
    )
    result.require(
        reference.returncode == 0,
        f"agent reference harness failed: {reference.stdout}{reference.stderr}",
    )
    if output.is_file():
        evidence = load_json(output)
        result.require(
            evidence.get("result") == "PASS" and evidence.get("total") == 50,
            "agent reference evidence is not PASS/50",
        )

    addendum = subprocess.run(
        [
            sys.executable,
            "-B",
            str(root / "specs/agents/addendum-v2/validate_contracts.py"),
        ],
        cwd=root,
        env=environment,
        text=True,
        capture_output=True,
        timeout=300,
    )
    addendum_payload: dict[str, object] = {}
    if addendum.stdout.strip():
        try:
            loaded = json.loads(addendum.stdout)
            if isinstance(loaded, dict):
                addendum_payload = loaded
        except json.JSONDecodeError as error:
            result.error(f"agent addendum validator emitted invalid JSON: {error}")
    result.require(
        addendum.returncode == 0
        and addendum_payload.get("result") == "PASS"
        and addendum_payload.get("errors") == [],
        "agent addendum-v2 validator failed: "
        f"{addendum_payload or addendum.stdout}{addendum.stderr}",
    )
    result.stats.update(
        {
            "agents": 5,
            "agent_tools": 9,
            "agent_eval_cases": 50,
            "agent_reference": "PASS" if reference.returncode == 0 else "FAIL",
            "agent_v2_schemas": addendum_payload.get("schemas", 0),
            "agent_v2_positive_examples": addendum_payload.get("positive_examples", 0),
            "agent_v2_negative_examples": addendum_payload.get("negative_examples", 0),
            "agent_v2_contracts": "PASS" if addendum.returncode == 0 else "FAIL",
        }
    )
