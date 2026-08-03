#!/usr/bin/env python3
"""Validate every generated primary response against its authoritative OpenAPI response."""

from __future__ import annotations

import json
from pathlib import Path

from jsonschema import Draft202012Validator, RefResolver

from materialize_application import primary_response


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
                if operation_id in checked:
                    errors.append(f"{api}:{operation_id}: duplicate OpenAPI operation id")
                    continue
                checked.add(operation_id)
                if not isinstance(sample, dict):
                    errors.append(f"{api}:{operation_id}: generated sample is not an object")
                    continue
                sample_fields = {"api", "status", "mediaType", "body"}
                if set(sample) != sample_fields:
                    errors.append(
                        f"{api}:{operation_id}: sample fields {sorted(sample)} != {sorted(sample_fields)}"
                    )
                if sample.get("api") != api:
                    errors.append(
                        f"{api}:{operation_id}: sample API {sample.get('api')!r} does not match"
                    )
                try:
                    status, response = primary_response(operation, operation_id=operation_id)
                except ValueError as error:
                    errors.append(f"{api}:{operation_id}: {error}")
                    continue
                if sample.get("status") != status:
                    errors.append(
                        f"{api}:{operation_id}: status {sample.get('status')!r} != declared primary {status}"
                    )

                content = response.get("content", {})
                media_type = sample.get("mediaType")
                if not isinstance(content, dict) or not content:
                    if media_type != "":
                        errors.append(
                            f"{api}:{operation_id}: bodyless response has media type {media_type!r}"
                        )
                    if sample.get("body") is not None:
                        errors.append(f"{api}:{operation_id}: bodyless response has a sample body")
                    continue
                expected_media_type = next(iter(content))
                if media_type != expected_media_type:
                    errors.append(
                        f"{api}:{operation_id}: media type {media_type!r} != declared primary "
                        f"{expected_media_type!r}"
                    )
                    continue
                media = content[expected_media_type]
                if not isinstance(media, dict):
                    errors.append(f"{api}:{operation_id}: response media declaration is not an object")
                    continue
                schema = media.get("schema", {})
                validator = Draft202012Validator(schema, resolver=resolver)
                for error in validator.iter_errors(sample.get("body")):
                    location = "/".join(str(segment) for segment in error.absolute_path) or "<root>"
                    errors.append(f"{api}:{operation_id}:{location}: {error.message}")
                    break
                if expected_media_type == "application/problem+json":
                    body = sample.get("body")
                    if not isinstance(body, dict) or body.get("status") != status:
                        errors.append(
                            f"{api}:{operation_id}: problem body status does not match HTTP {status}"
                        )
                    error_codes = response.get("x-error-codes", [])
                    if (
                        isinstance(error_codes, list)
                        and len(error_codes) == 1
                        and isinstance(body, dict)
                        and body.get("code") != error_codes[0]
                    ):
                        errors.append(
                            f"{api}:{operation_id}: problem code {body.get('code')!r} "
                            f"!= declared {error_codes[0]!r}"
                        )
    extras = sorted(set(samples) - checked)
    errors.extend(f"uncataloged sample: {operation_id}" for operation_id in extras)
    result = {"checked": len(checked), "errors": errors, "result": "PASS" if not errors else "FAIL"}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
