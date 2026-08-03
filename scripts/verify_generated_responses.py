#!/usr/bin/env python3
"""Validate every generated primary response against its authoritative OpenAPI response."""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
from pathlib import Path
from typing import Any

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
PUBLIC_REDISTRIBUTION_NOTICE = "이상 징후 기록이며 위법·부패의 확정이 아님"
PUBLISHED_ANOMALY_NOTICE = (
    "공개자료 비교에서 설명이 필요한 차이가 확인됐습니다. "
    "현재 자료만으로 위법성이나 부패 여부를 판단할 수 없습니다."
)


def validate_reproducibility_download_sample(body: Any) -> list[str]:
    if not isinstance(body, dict):
        return ["downloadCaseReproducibility: sample body is not an object"]
    errors: list[str] = []
    if body.get("notice") != PUBLIC_REDISTRIBUTION_NOTICE:
        errors.append("downloadCaseReproducibility: envelope notice changed")
    if body.get("format") != "JSON":
        errors.append("downloadCaseReproducibility: closed sample format must be JSON")
    encoded = body.get("contentBase64")
    try:
        artifact = base64.b64decode(encoded, validate=True) if isinstance(encoded, str) else b""
    except (binascii.Error, ValueError):
        return [*errors, "downloadCaseReproducibility: contentBase64 is invalid"]
    if body.get("byteLength") != len(artifact):
        errors.append("downloadCaseReproducibility: byteLength does not match artifact")
    if body.get("contentSha256") != hashlib.sha256(artifact).hexdigest():
        errors.append("downloadCaseReproducibility: contentSha256 does not match artifact")
    try:
        payload = json.loads(artifact)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return [*errors, "downloadCaseReproducibility: artifact is not JSON"]
    if not isinstance(payload, dict) or set(payload) != {"notice", "nonConclusion", "data"}:
        errors.append("downloadCaseReproducibility: artifact envelope is not closed")
    elif (
        payload.get("notice") != PUBLIC_REDISTRIBUTION_NOTICE
        or payload.get("nonConclusion") != PUBLISHED_ANOMALY_NOTICE
    ):
        errors.append("downloadCaseReproducibility: in-body legal notices changed")
    return errors


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
                if operation_id == "downloadCaseReproducibility":
                    errors.extend(validate_reproducibility_download_sample(sample.get("body")))
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
