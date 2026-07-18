#!/usr/bin/env python3
"""Fill deterministic success samples for owner-addendum OpenAPI operations."""

from __future__ import annotations

import json
from pathlib import Path

import yaml

from materialize_application import operation_response_samples

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    path = ROOT / "verification/generated-operation-samples.json"
    samples = json.loads(path.read_text())
    generated = operation_response_samples()
    addendum = yaml.safe_load((ROOT / "specs/product/addendum-operation-contracts.yaml").read_text())
    ids = {row["operation_id"] for row in addendum["operations"]}
    ids.add("estimateBackfill")
    for operation_id in ids:
        if operation_id in generated:
            status, media_type, body = generated[operation_id]
            samples[operation_id] = {
                "api": "control-api" if operation_id == "estimateBackfill" or operation_id in {row["operation_id"] for row in addendum["operations"] if row["api"] == "control-api"} else "submission-api",
                "status": status,
                "mediaType": media_type,
                "body": body,
            }
    path.write_text(json.dumps(samples, ensure_ascii=False, indent=2) + "\n")
    print(f"updated {len(ids)} operation samples")


if __name__ == "__main__":
    main()

