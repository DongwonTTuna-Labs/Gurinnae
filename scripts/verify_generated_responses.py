#!/usr/bin/env python3
"""Validate every generated success body against its authoritative OpenAPI schema."""

from __future__ import annotations

import json
from pathlib import Path

from jsonschema import Draft202012Validator, RefResolver


ROOT = Path(__file__).resolve().parents[1]
SPECS = {
    "public-api": "specs/generated/public-api.openapi.json",
    "submission-api": "specs/generated/submission-api.openapi.json",
    "control-api": "specs/generated/control-api.openapi.json",
    "identity-provider": "specs/generated/identity-provider.openapi.json",
    "identity-service-internal": "specs/generated/identity-service-internal.openapi.json",
}


def main() -> int:
    samples = json.loads((ROOT / "verification/generated-operation-samples.json").read_text())
    errors: list[str] = []
    checked: set[str] = set()
    for api, relative_path in SPECS.items():
        document = json.loads((ROOT / relative_path).read_text())
        resolver = RefResolver.from_schema(document)
        for route in document["paths"].values():
            for operation in route.values():
                if not isinstance(operation, dict) or "operationId" not in operation:
                    continue
                operation_id = operation["operationId"]
                sample = samples.get(operation_id)
                if sample is None:
                    errors.append(f"{api}:{operation_id}: missing generated sample")
                    continue
                checked.add(operation_id)
                success = next(
                    (response for code, response in operation.get("responses", {}).items() if str(code)[0] in "23"),
                    None,
                )
                if success is None:
                    errors.append(f"{api}:{operation_id}: no success response")
                    continue
                content = success.get("content", {})
                media_type = sample["mediaType"]
                if not content and media_type == "":
                    continue
                if media_type not in content:
                    errors.append(f"{api}:{operation_id}: media type {media_type} is not declared")
                    continue
                if media_type != "application/json":
                    continue
                schema = content[media_type].get("schema", {})
                validator = Draft202012Validator(schema, resolver=resolver)
                for error in validator.iter_errors(sample["body"]):
                    errors.append(f"{api}:{operation_id}: {error.message}")
                    break
    extras = sorted(set(samples) - checked)
    errors.extend(f"uncataloged sample: {operation_id}" for operation_id in extras)
    result = {"checked": len(checked), "errors": errors, "result": "PASS" if not errors else "FAIL"}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
