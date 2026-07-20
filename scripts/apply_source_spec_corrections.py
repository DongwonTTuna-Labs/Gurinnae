#!/usr/bin/env python3
"""Apply documented source-product corrections without rewriting authority inputs."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    for name in (
        "public-api",
        "submission-api",
        "control-api",
        "identity-provider",
        "identity-service-internal",
    ):
        source = ROOT / f"specs/api/{name}.openapi.json"
        generated = ROOT / f"specs/generated/{name}.openapi.json"
        generated.write_bytes(source.read_bytes())
    path = ROOT / "specs/generated/control-api.openapi.json"
    document = json.loads(path.read_text())
    schemas = document["components"]["schemas"]
    data = schemas.get("estimateBackfillReceipt", {}).get("properties", {}).get("data")
    # The v13 source contract now materializes this finite estimate object
    # directly.  Preserve the legacy correction only for older source JSON
    # that still carries the recursive envelope reference.
    if isinstance(data, dict) and data.get("$ref") == "#/components/schemas/estimateBackfillReceipt":
        schemas["BackfillEstimate"] = {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "sourceId": {"type": "string"},
                "from": {"type": "string", "format": "date"},
                "to": {"type": "string", "format": "date"},
                "estimatedRecords": {"type": "integer", "format": "int64", "minimum": 0},
                "estimatedJobs": {"type": "integer", "format": "int64", "minimum": 0},
                "estimatedCostKrw": {"type": "string", "pattern": "^-?\\d+(\\.\\d+)?$"},
                "estimatedDurationSeconds": {"type": "integer", "format": "int64", "minimum": 0},
                "dedupeStrategy": {"type": "string"},
                "downstreamEffects": {"type": "array", "items": {"type": "string"}},
            },
            "required": [
                "sourceId", "from", "to", "estimatedRecords", "estimatedJobs",
                "estimatedCostKrw", "estimatedDurationSeconds", "dedupeStrategy",
                "downstreamEffects",
            ],
        }
        schemas["estimateBackfillReceipt"]["properties"]["data"] = {
            "$ref": "#/components/schemas/BackfillEstimate"
        }
    path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    print("applied BackfillEstimate finite-schema correction")


if __name__ == "__main__":
    main()
