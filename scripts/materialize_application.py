#!/usr/bin/env python3
"""Materialize the v13 Rust and SvelteKit product surface from authority catalogs.

The generator is deterministic: authority YAML and OpenAPI documents are its only
inputs. Handwritten policy modules are never overwritten once present.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
SPEC_VERSION = "13.0.0"
OPENAPI_DOCUMENTS = {
    "public-api": "specs/generated/public-api.openapi.json",
    "submission-api": "specs/generated/submission-api.openapi.json",
    "control-api": "specs/generated/control-api.openapi.json",
    "identity-provider": "specs/generated/identity-provider.openapi.json",
    "identity-service-internal": "specs/generated/identity-service-internal.openapi.json",
}
ADDITIVE_OPERATION_CONTRACT = "specs/product/addendum-operation-contracts.yaml"
ADDITIVE_RESOURCE_CONTRACT = "specs/product/addendum-resource-error-contracts.yaml"
ADDITIVE_EXTERNAL_AUTH = {
    "PUBLIC_QUERY": ("anonymous", "not-applicable"),
    "CONTROL_QUERY": ("actor-assertion-and-capability", "not-applicable"),
    "CONTROL_COMMAND": ("actor-assertion-and-capability", "required"),
    "SUBMISSION_SCOPED_QUERY": (
        "bff-service-assertion-and-scoped-submission-session",
        "not-applicable",
    ),
    "SUBMISSION_SCOPED_COMMAND": (
        "bff-service-assertion-and-scoped-submission-session",
        "required",
    ),
    "SUBMISSION_ANONYMOUS_COMMAND": ("bff-service-assertion", "required"),
    "SUBMISSION_RECEIPT_EXCHANGE_COMMAND": ("bff-service-assertion", "required"),
}


# These values exist only in generated test evidence and mock responses. They do
# not seed production data or claim that an unauthenticated upstream contains
# the represented records.
TEST_ONLY_OPERATION_RESPONSE_BODIES: dict[str, Any] = {
    "listPublicDatasets": {
        "items": [
            {
                "id": "published-cases",
                "title": "공개 사례 기록",
                "description": "게시된 사례와 개정 이력을 확인하는 구조화 데이터",
                "format": "JSONL",
                "coverage": {
                    "dateRange": {"label": "2025.01–2026.07"},
                    "sourceIds": ["mock-procurement-source"],
                    "recordCount": 864,
                    "knownGaps": [],
                    "freshness": {
                        "asOf": "2026-07-12T00:00:00Z",
                        "status": "CURRENT",
                    },
                },
                "license": "CC-BY-4.0",
                "updatedAt": "2026-07-12T00:00:00Z",
                "downloadUrl": None,
                "redistributionNotice": "이상 징후 기록이며 위법·부패의 확정이 아님",
            },
            {
                "id": "public-contracts",
                "title": "계약 대장",
                "description": "공개 계약의 기관·업체·금액을 정리한 표 형식 데이터",
                "format": "CSV",
                "coverage": {
                    "dateRange": {"label": "2024.01–2026.07"},
                    "sourceIds": ["mock-procurement-source"],
                    "recordCount": 2416,
                    "knownGaps": [],
                    "freshness": {
                        "asOf": "2026-07-12T00:00:00Z",
                        "status": "CURRENT",
                    },
                },
                "license": "CC-BY-4.0",
                "updatedAt": "2026-07-12T00:00:00Z",
                "downloadUrl": None,
                "redistributionNotice": "이상 징후 기록이며 위법·부패의 확정이 아님",
            },
            {
                "id": "published-corrections",
                "title": "공개 정정 기록",
                "description": "공개 내용의 정정 사유와 적용 시점을 보존한 기록",
                "format": "JSONL",
                "coverage": {
                    "dateRange": {"label": "2025.06–2026.07"},
                    "sourceIds": ["mock-publication-register"],
                    "recordCount": 37,
                    "knownGaps": [],
                    "freshness": {
                        "asOf": "2026-07-12T00:00:00Z",
                        "status": "CURRENT",
                    },
                },
                "license": "CC-BY-4.0",
                "updatedAt": "2026-07-12T00:00:00Z",
                "downloadUrl": None,
                "redistributionNotice": "이상 징후 기록이며 위법·부패의 확정이 아님",
            },
        ],
        "appliedFilters": {"format": []},
        "asOf": "2026-07-12T00:00:00Z",
        "seo": {
            "title": "공개 데이터",
            "description": "공개 데이터 · 이상 징후 기록이며 위법·부패의 확정이 아님",
            "openGraphDescription": "공개 데이터 · 이상 징후 기록이며 위법·부패의 확정이 아님",
            "canonicalUrl": "/data",
            "robots": "index,follow",
        },
    },
    "downloadPublicCases": {
        "id": "public-cases-a95cbf94fea10d08",
        "status": "READY",
        "version": 1,
        "notice": "이상 징후 기록이며 위법·부패의 확정이 아님",
        "nonConclusionNotices": [],
        "interpretationNotice": None,
        "filename": "public-cases.jsonl",
        "mediaType": "application/x-ndjson; charset=utf-8",
        "byteLength": 75,
        "contentSha256": "a95cbf94fea10d089ddf966be1f5e2b11f263c110cff3efa60077101764fda81",
        "contentBase64": "eyJub3RpY2UiOiLsnbTsg4Eg7KeV7ZuEIOq4sOuhneydtOupsCDsnITrspXCt+u2gO2MqOydmCDtmZXsoJXsnbQg7JWE64uYIn0K",
        "format": "JSONL",
        "rowCount": 0,
        "appliedFilters": {"publicationState": [], "sort": "updated_desc"},
        "generatedAt": "2026-07-12T00:00:00Z",
    },
    "downloadPublicSearchRecords": {
        "id": "public-search-records-a95cbf94fea10d08",
        "status": "READY",
        "version": 1,
        "notice": "이상 징후 기록이며 위법·부패의 확정이 아님",
        "nonConclusionNotices": [],
        "interpretationNotice": None,
        "filename": "public-search-records.jsonl",
        "mediaType": "application/x-ndjson; charset=utf-8",
        "byteLength": 75,
        "contentSha256": "a95cbf94fea10d089ddf966be1f5e2b11f263c110cff3efa60077101764fda81",
        "contentBase64": "eyJub3RpY2UiOiLsnbTsg4Eg7KeV7ZuEIOq4sOuhneydtOupsCDsnITrspXCt+u2gO2MqOydmCDtmZXsoJXsnbQg7JWE64uYIn0K",
        "format": "JSONL",
        "rowCount": 0,
        "appliedFilters": {
            "q": "계약",
            "types": [],
            "publicationState": [],
            "sort": "relevance",
        },
        "generatedAt": "2026-07-12T00:00:00Z",
    },
    "downloadCaseReproducibility": {
        "id": "case-test-case-reproducibility-e29870585c26a607",
        "status": "READY",
        "version": 1,
        "notice": "이상 징후 기록이며 위법·부패의 확정이 아님",
        "filename": "case-test-case-reproducibility.json",
        "mediaType": "application/json; charset=utf-8",
        "byteLength": 262,
        "contentSha256": "e29870585c26a607893ea06d81cdfc8a0a17652b6fe8a1c4c04470525a9559e4",
        "contentBase64": "eyJub3RpY2UiOiLsnbTsg4Eg7KeV7ZuEIOq4sOuhneydtOupsCDsnITrspXCt+u2gO2MqOydmCDtmZXsoJXsnbQg7JWE64uYIiwibm9uQ29uY2x1c2lvbiI6IuqzteqwnOyekOujjCDruYTqtZDsl5DshJwg7ISk66qF7J20IO2VhOyalO2VnCDssKjsnbTqsIAg7ZmV7J2465CQ7Iq164uI64ukLiDtmITsnqwg7J6Q66OM66eM7Jy866GcIOychOuyleyEseydtOuCmCDrtoDtjKgg7Jes67aA66W8IO2MkOuLqO2VoCDsiJgg7JeG7Iq164uI64ukLiIsImRhdGEiOnt9fQ==",
        "format": "JSON",
        "rowCount": 1,
        "appliedFilters": {"caseSlug": "test-case"},
        "generatedAt": "2026-07-12T00:00:00Z",
    },
    "listRelayModels": {
        "items": [
            {
                "modelId": "relay-test-stable",
                "family": "relay-test",
                "track": "relay-test-",
                "createdAt": "2026-07-12T00:00:00Z",
                "firstSeenAt": "2026-07-12T00:00:00Z",
                "lastSeenAt": "2026-07-14T00:00:00Z",
                "active": True,
                "new": False,
            },
            {
                "modelId": "relay-test-latest",
                "family": "relay-test",
                "track": "relay-test-",
                "createdAt": "2026-07-13T00:00:00Z",
                "firstSeenAt": "2026-07-13T00:00:00Z",
                "lastSeenAt": "2026-07-14T00:00:00Z",
                "active": True,
                "new": True,
            },
        ],
        "currentProviders": [
            {
                "providerId": "90000000-0000-4000-8000-000000000005",
                "name": "릴레이 테스트 공급자",
                "currentModel": "relay-test-stable",
                "enabled": True,
                "version": 2,
                "autoUpgrade": False,
                "autoUpgradeConflict": False,
                "track": "relay-test-",
                "dataPolicyState": "CONFIGURED",
                "pricingVersion": "relay-unpriced-v1",
                "unpriced": True,
            }
        ],
        "syncStatus": {
            "status": "SUCCEEDED",
            "lastCompletedAt": "2026-07-14T00:00:00Z",
            "lastErrorCode": None,
        },
        "asOf": "2026-07-14T00:00:00Z",
    }
}

TEST_ONLY_OPERATION_RESPONSE_PATCHES: dict[str, dict[str, Any]] = {
    "getAgency": {
        "sidoCode": "11",
        "sigunguCode": "11680",
        "regionCodeVersion": "행정표준코드-2026.1",
    },
    "getPrivacyPolicy": {
        "data": {
            "retentionSchedules": [
                {
                    "recordClass": "AGENCY_MASTER",
                    "purpose": "TEST_ONLY generated response fixture",
                    "lawfulBasis": "TEST_ONLY generated response fixture",
                    "triggerKind": "CREATED_AT",
                    "activeDurationSeconds": 0,
                    "backupDurationSeconds": 0,
                    "terminalAction": "DELETE",
                    "effectiveAt": "2026-07-12T00:00:00Z",
                    "reviewExpiresAt": "2026-07-13T00:00:00Z",
                    "scheduleDigest": "0" * 64,
                }
            ]
        }
    },
    "listPublicCases": {
        "appliedFilters": {"sidoCode": "11", "sigunguCode": "11680"},
    },
    "searchPublicRecords": {
        "appliedFilters": {"sidoCode": "11", "sigunguCode": "11680"},
    },
}


GENERATED_PATH_PATTERNS = (
    re.compile(r"^specs/generated/[^/]+\.openapi\.json$"),
    re.compile(r"^packages/api-client-[^/]+/src/generated/"),
    re.compile(r"^crates/api-contracts/src/(?:public|submission|control)_api\.rs$"),
    re.compile(r"^crates/api-contracts/src/identity_(?:provider|service_internal)\.rs$"),
    re.compile(r"^verification/generated-[^/]+\.json$"),
    re.compile(r"^apps/[^/]+/src/routes/.+/screen\.ts$"),
)


def is_generated_path(path: str | Path) -> bool:
    normalized = Path(path).as_posix()
    return any(pattern.match(normalized) for pattern in GENERATED_PATH_PATTERNS)


def write(path: str | Path, content: str, *, overwrite: bool | None = None) -> None:
    """Create missing materialized files; only replace declared generated outputs.

    This script bootstraps a tree, but it is also used for deterministic regeneration.
    Handwritten source and configuration therefore fail closed against accidental
    replacement once they exist.
    """
    target = ROOT / path
    if overwrite is None:
        overwrite = is_generated_path(path)
    if target.exists() and not overwrite:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    normalized = content.rstrip() + "\n"
    if not target.exists() or target.read_text(encoding="utf-8") != normalized:
        target.write_text(normalized, encoding="utf-8")


def biome_format(path: str | Path, content: str) -> str:
    """Apply the repository formatter to generated JSON/TypeScript deterministically."""
    completed = subprocess.run(
        ["bunx", "biome", "format", "--stdin-file-path", str(path)],
        cwd=ROOT,
        input=content.rstrip() + "\n",
        text=True,
        capture_output=True,
        check=True,
    )
    return completed.stdout


def load_yaml(path: str) -> dict[str, Any]:
    return yaml.safe_load((ROOT / path).read_text(encoding="utf-8"))


def rust_ident(value: str) -> str:
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", value)
    return re.sub(r"[^a-zA-Z0-9_]", "_", value).lower()


def crate_ident(value: str) -> str:
    return value.replace("-", "_")


def sample_for_schema(
    schema: Any,
    document: dict[str, Any],
    depth: int = 0,
    *,
    operation_id: str | None = None,
    property_name: str | None = None,
) -> Any:
    if depth > 14 or not isinstance(schema, dict):
        return None
    if "$ref" in schema:
        current: Any = document
        for segment in schema["$ref"].removeprefix("#/").split("/"):
            current = current[segment.replace("~1", "/").replace("~0", "~")]
        return sample_for_schema(
            current,
            document,
            depth + 1,
            operation_id=operation_id,
            property_name=property_name,
        )
    if "example" in schema:
        return schema["example"]
    if "const" in schema:
        return schema["const"]
    if schema.get("enum"):
        return schema["enum"][0]
    if "allOf" in schema:
        merged: dict[str, Any] = {}
        for branch in schema["allOf"]:
            value = sample_for_schema(
                branch,
                document,
                depth + 1,
                operation_id=operation_id,
                property_name=property_name,
            )
            if isinstance(value, dict):
                merged.update(value)
        return merged
    for union in ("oneOf", "anyOf"):
        if schema.get(union):
            non_null = [part for part in schema[union] if part.get("type") != "null"]
            return sample_for_schema(
                (non_null or schema[union])[0],
                document,
                depth + 1,
                operation_id=operation_id,
                property_name=property_name,
            )
    schema_type = schema.get("type")
    if isinstance(schema_type, list):
        schema_type = next((kind for kind in schema_type if kind != "null"), "null")
    if schema_type == "object" or "properties" in schema:
        properties = schema.get("properties", {})
        required = schema.get("required", list(properties))
        return {
            name: sample_for_schema(
                properties[name],
                document,
                depth + 1,
                operation_id=operation_id,
                property_name=name,
            )
            for name in required
            if name in properties
        }
    if schema_type == "array":
        count = int(schema.get("minItems", 0))
        return [
            sample_for_schema(
                schema.get("items", {}),
                document,
                depth + 1,
                operation_id=operation_id,
                property_name=property_name,
            )
            for _ in range(count)
        ]
    if schema_type == "integer":
        return max(int(schema.get("minimum", 0)), 0)
    if schema_type == "number":
        return max(float(schema.get("minimum", 0)), 0.0)
    if schema_type == "boolean":
        return False
    if schema_type == "string" or schema.get("format"):
        if property_name == "operationId" and operation_id is not None:
            return operation_id
        fmt = schema.get("format")
        values = {
            "uuid": "00000000-0000-4000-8000-000000000001",
            "date-time": "2026-07-12T00:00:00Z",
            "date": "2026-07-12",
            "uri": "https://gurinnae.example/",
            "email": "example@gurinnae.example",
            "binary": "",
        }
        if fmt in values:
            return values[fmt]
        pattern = schema.get("pattern", "")
        if pattern.startswith("^gurine-aa-v1"):
            return "gurine-aa-v1." + "0" * 16 + ".e30." + "0" * 43
        if pattern.startswith("^gurine-sa-v1"):
            return "gurine-sa-v1." + "0" * 16 + ".e30." + "0" * 43
        if pattern == "^[a-f0-9]{{64}}$" or "[a-f0-9]{64}" in pattern or "[0-9a-f]{64}" in pattern:
            return "0" * 64
        if "\\d+" in pattern:
            return "0"
        minimum_length = int(schema.get("minLength", 0))
        return schema.get("default", "x" * minimum_length)
    return None


def primary_response(
    operation: dict[str, Any], *, operation_id: str
) -> tuple[int, dict[str, Any]]:
    responses = operation.get("responses")
    if not isinstance(responses, dict) or not responses:
        raise ValueError(f"operation has no declared responses: {operation_id}")

    preferred = [
        (code, response)
        for code, response in responses.items()
        if re.fullmatch(r"[23][0-9]{2}", str(code))
    ]
    if preferred:
        code, response = preferred[0]
    else:
        explicit = [
            (code, response)
            for code, response in responses.items()
            if str(code) != "default" and re.fullmatch(r"[0-9]{3}", str(code))
        ]
        if len(explicit) != 1:
            declared = ", ".join(str(code) for code in responses)
            raise ValueError(
                f"operation without a 2xx/3xx response must declare exactly one "
                f"explicit primary response: {operation_id} ({declared})"
            )
        code, response = explicit[0]

    if not isinstance(response, dict):
        raise ValueError(f"primary response is not an object: {operation_id}:{code}")
    return int(code), response


def response_sample(
    status: int,
    response: dict[str, Any],
    document: dict[str, Any],
    *,
    operation_id: str,
) -> tuple[str, Any]:
    content = response.get("content", {})
    if not isinstance(content, dict) or not content:
        return "", None
    media_type = next(iter(content))
    media = content[media_type]
    if not isinstance(media, dict):
        raise ValueError(f"response media declaration is not an object: {status}:{media_type}")
    body = sample_for_schema(
        media.get("schema", {}),
        document,
        operation_id=operation_id,
    )
    if media_type == "application/problem+json" and isinstance(body, dict):
        body["status"] = status
        error_codes = response.get("x-error-codes", [])
        if (
            isinstance(error_codes, list)
            and len(error_codes) == 1
            and isinstance(error_codes[0], str)
        ):
            body["code"] = error_codes[0]
        description = response.get("description")
        if isinstance(description, str) and description:
            body["title"] = description
    return media_type, body


def operation_response_samples() -> dict[str, tuple[int, str, Any]]:
    mapping: dict[str, tuple[int, str, Any]] = {}
    for api, path in OPENAPI_DOCUMENTS.items():
        document = json.loads((ROOT / path).read_text(encoding="utf-8"))
        for route in document["paths"].values():
            for method in route.values():
                if not isinstance(method, dict) or "operationId" not in method:
                    continue
                operation_id = method["operationId"]
                if operation_id in mapping:
                    raise ValueError(f"duplicate OpenAPI operation id: {operation_id}")
                status, response = primary_response(method, operation_id=operation_id)
                media_type, body = response_sample(
                    status,
                    response,
                    document,
                    operation_id=operation_id,
                )
                mapping[operation_id] = (status, media_type, body)
    for operation_id, body in TEST_ONLY_OPERATION_RESPONSE_BODIES.items():
        generated = mapping.get(operation_id)
        if generated is None:
            raise ValueError(f"test-only response sample operation is not cataloged: {operation_id}")
        status, media_type, _ = generated
        if media_type != "application/json":
            raise ValueError(
                f"test-only response sample must target application/json: {operation_id}"
            )
        mapping[operation_id] = (status, media_type, body)
    for operation_id, patch in TEST_ONLY_OPERATION_RESPONSE_PATCHES.items():
        generated = mapping.get(operation_id)
        if generated is None:
            raise ValueError(f"test-only response patch operation is not cataloged: {operation_id}")
        status, media_type, body = generated
        if media_type != "application/json" or not isinstance(body, dict):
            raise ValueError(
                f"test-only response patch requires a JSON object: {operation_id}"
            )
        merge_sample_patch(body, patch)
    return mapping


def merge_sample_patch(target: dict[str, Any], patch: dict[str, Any]) -> None:
    for key, value in patch.items():
        if isinstance(value, dict):
            nested = target.get(key)
            if not isinstance(nested, dict):
                raise ValueError(f"test-only response patch target is not an object: {key}")
            merge_sample_patch(nested, value)
        else:
            if key not in target:
                raise ValueError(f"test-only response patch target is missing: {key}")
            target[key] = value


def operation_sample_evidence(
    samples: dict[str, tuple[int, str, Any]],
) -> dict[str, dict[str, Any]]:
    evidence: dict[str, dict[str, Any]] = {}
    for api, path in OPENAPI_DOCUMENTS.items():
        document = json.loads((ROOT / path).read_text(encoding="utf-8"))
        for route in document["paths"].values():
            for operation in route.values():
                if not isinstance(operation, dict) or "operationId" not in operation:
                    continue
                operation_id = operation["operationId"]
                if operation_id in evidence:
                    raise ValueError(f"duplicate OpenAPI operation id: {operation_id}")
                status, media_type, body = samples[operation_id]
                evidence[operation_id] = {
                    "api": api,
                    "status": status,
                    "mediaType": media_type,
                    "body": body,
                }
    return evidence


def root_workspace(members: list[str]) -> None:
    member_lines = "\n".join(f'  "{member}",' for member in members)
    write("rust-toolchain.toml", '[toolchain]\nchannel = "1.97.0"\nprofile = "minimal"\ncomponents = ["rustfmt", "clippy"]')
    write(
        "Cargo.toml",
        f'''[workspace]
resolver = "3"
members = [
{member_lines}
]

[workspace.package]
version = "0.1.0"
edition = "2024"
license = "AGPL-3.0-or-later"
rust-version = "1.97"

[workspace.lints.rust]
unsafe_code = "forbid"

[workspace.dependencies]
actix-web = "=4.14.0"
base64 = "=0.22.1"
calamine = "=0.35.0"
chacha20poly1305 = "=0.11.0"
csv = "=1.4.0"
getrandom = "=0.4.3"
hmac = "=0.12.1"
lettre = {{ version = "=0.11.22", default-features = false, features = ["builder", "smtp-transport", "tokio1-rustls-tls"] }}
object_store = {{ version = "=0.14.0", features = ["aws"] }}
openidconnect = {{ version = "=4.0.1", default-features = false, features = ["reqwest", "rustls-tls"] }}
quick-xml = "=0.41.0"
reqwest = {{ version = "=0.12.23", default-features = false, features = ["rustls-tls", "http2", "json", "stream", "gzip", "brotli"] }}
rust_decimal = {{ version = "=1.37.2", features = ["serde-with-str"] }}
secrecy = {{ version = "=0.10.3", features = ["serde"] }}
serde = {{ version = "=1.0.221", features = ["derive"] }}
serde_json = "=1.0.143"
sha2 = "=0.10.9"
sqlx = {{ version = "=0.9.0", default-features = false, features = ["runtime-tokio", "tls-rustls-ring-webpki", "postgres", "uuid", "time", "json", "rust_decimal", "migrate", "macros"] }}
subtle = "=2.6.0"
thiserror = "=2.0.18"
time = {{ version = "=0.3.47", features = ["serde", "formatting", "parsing"] }}
tokio = {{ version = "=1.47.1", features = ["macros", "rt-multi-thread", "signal", "time", "sync", "fs", "process", "net", "io-util"] }}
tracing = "=0.1.41"
tracing-subscriber = {{ version = "=0.3.20", features = ["env-filter", "json"] }}
unicode-normalization = "=0.1.24"
url = "=2.5.7"
utoipa = {{ version = "=5.5.0", features = ["actix_extras", "uuid", "time", "decimal", "openapi_extensions"] }}
uuid = {{ version = "=1.18.1", features = ["v4", "serde"] }}
zeroize = "=1.9.0"
zip = "=8.6.0"

[patch.crates-io]
subtle = {{ path = "vendor/subtle-2.6.0" }}
''',
    )


def additive_external_operations() -> list[dict[str, Any]]:
    addendum = load_yaml(ADDITIVE_OPERATION_CONTRACT)
    resource_contract = load_yaml(ADDITIVE_RESOURCE_CONTRACT)
    source_rows = addendum.get("operations")
    bindings = resource_contract.get("operation_bindings")
    if not isinstance(source_rows, list) or not isinstance(bindings, dict):
        raise ValueError("additive operation contracts have an invalid shape")
    declared_sets = resource_contract.get("set_equality")
    if not isinstance(declared_sets, dict):
        raise ValueError("additive resource contract has no set-equality declarations")

    def declared_ids(name: str) -> set[str]:
        values = declared_sets.get(name)
        if not isinstance(values, list) or not all(
            isinstance(value, str) for value in values
        ):
            raise ValueError(f"additive resource contract has invalid {name}")
        return set(values)

    rows_by_id = {
        row["operation_id"]: row
        for row in source_rows
        if isinstance(row, dict) and isinstance(row.get("operation_id"), str)
    }
    if len(rows_by_id) != len(source_rows):
        raise ValueError("additive operation contract contains duplicate or invalid ids")
    external_ids = {
        operation_id
        for operation_id, binding in bindings.items()
        if isinstance(binding, dict) and binding.get("scope") == "ADDITIVE_EXTERNAL"
    }
    private_ids = {
        operation_id
        for operation_id, binding in bindings.items()
        if isinstance(binding, dict) and binding.get("scope") != "ADDITIVE_EXTERNAL"
    }
    source_ids = set(rows_by_id)
    declared_external_ids = declared_ids("additive_external_operation_ids")
    declared_private_identity_ids = declared_ids("private_identity_api_operation_ids")
    declared_private_service_ids = declared_ids("private_control_service_operation_ids")
    if external_ids & private_ids:
        raise ValueError("additive external and private operation bindings overlap")
    if external_ids != declared_external_ids:
        raise ValueError("additive external bindings differ from the declared set")
    if declared_private_identity_ids & external_ids:
        raise ValueError("private identity operations appear in additive external bindings")
    if declared_private_service_ids & external_ids:
        raise ValueError("private service operations appear in additive external bindings")
    if source_ids != external_ids | (source_ids & private_ids):
        raise ValueError("additive operation bindings contain unknown source ids")
    if external_ids - source_ids:
        raise ValueError("additive external bindings are missing source operations")
    if source_ids & private_ids != declared_private_identity_ids:
        raise ValueError("additive source operations include an unexpected private boundary")

    external_rows: list[dict[str, Any]] = []
    for operation_id in sorted(external_ids):
        source = rows_by_id[operation_id]
        binding = bindings[operation_id]
        profile = binding.get("transport_profile") if isinstance(binding, dict) else None
        auth_contract = ADDITIVE_EXTERNAL_AUTH.get(profile)
        if auth_contract is None:
            raise ValueError(
                f"{operation_id}: unsupported additive external transport profile {profile!r}"
            )
        api = source.get("api")
        method = source.get("method")
        kind = source.get("kind")
        assurance = source.get("assurance")
        capability = source.get("capability")
        if api not in {"public-api", "submission-api", "control-api"}:
            raise ValueError(f"{operation_id}: invalid additive external api {api!r}")
        if not all(isinstance(value, str) and value for value in (method, kind, assurance)):
            raise ValueError(f"{operation_id}: incomplete additive external operation")
        auth, idempotency = auth_contract
        external_rows.append(
            {
                "operation_id": operation_id,
                "api": api,
                "method": method,
                "path": source.get("path"),
                "auth": auth,
                "capability": capability if isinstance(capability, str) else "none",
                "idempotency": idempotency,
                "operation_kind": kind,
                "assurance_level": assurance,
                "step_up_required": assurance == "STEP_UP",
            }
        )
    return external_rows


def operation_catalog() -> list[dict[str, Any]]:
    operations = list(load_yaml("specs/api/operation-contracts.yaml")["operations"])
    base_ids = {
        operation["operation_id"]
        for operation in operations
        if isinstance(operation, dict) and isinstance(operation.get("operation_id"), str)
    }
    external_operations = additive_external_operations()
    external_ids = {operation["operation_id"] for operation in external_operations}
    if base_ids & external_ids:
        raise ValueError("base and additive external operation catalogs overlap")
    operations.extend(external_operations)
    identity_document = json.loads(
        (ROOT / OPENAPI_DOCUMENTS["identity-service-internal"]).read_text(encoding="utf-8")
    )
    for route_path, route in identity_document["paths"].items():
        for method_name, method in route.items():
            if not isinstance(method, dict) or "operationId" not in method:
                continue
            operations.append(
                {
                    "operation_id": method["operationId"],
                    "api": "identity-service-internal",
                    "method": method_name.upper(),
                    "path": route_path,
                    "auth": "service-assertion",
                    "capability": "identity.internal",
                    "idempotency": "required" if method_name.lower() != "get" else "not-applicable",
                    "operation_kind": "COMMAND" if method_name.lower() != "get" else "QUERY",
                    "assurance_level": "SERVICE_ASSERTION",
                    "step_up_required": False,
                }
            )
    operation_ids = [operation["operation_id"] for operation in operations]
    if len(operation_ids) != len(set(operation_ids)):
        raise ValueError("operation catalog contains duplicate operation ids")
    return operations


def operation_spec_sources(
    operations: list[dict[str, Any]], samples: dict[str, tuple[int, str, Any]]
) -> dict[str, str]:
    operation_ids = {operation["operation_id"] for operation in operations}
    sample_ids = set(samples)
    if operation_ids != sample_ids:
        missing_samples = sorted(operation_ids - sample_ids)
        extra_samples = sorted(sample_ids - operation_ids)
        raise ValueError(
            "operation catalog and response samples differ: "
            f"missing_samples={missing_samples}, extra_samples={extra_samples}"
        )
    by_api: dict[str, list[dict[str, Any]]] = {}
    for operation in operations:
        by_api.setdefault(operation["api"], []).append(operation)
    sources: dict[str, str] = {}
    for api, records in sorted(by_api.items()):
        entries = []
        for operation in records:
            status, media_type, sample = samples[operation["operation_id"]]
            sample_json = json.dumps(sample, ensure_ascii=False, separators=(",", ":"))
            fields = (
                ("id", json.dumps(operation["operation_id"])),
                ("api", json.dumps(api)),
                ("method", json.dumps(operation["method"])),
                ("path", json.dumps(operation["path"])),
                ("auth", json.dumps(operation["auth"])),
                ("capability", json.dumps(operation.get("capability") or "")),
                (
                    "idempotency_required",
                    str(operation.get("idempotency") == "required").lower(),
                ),
                (
                    "assurance_level",
                    json.dumps(operation.get("assurance_level") or "ANONYMOUS_PROOF"),
                ),
                ("step_up_required", str(bool(operation.get("step_up_required"))).lower()),
                ("operation_kind", json.dumps(operation["operation_kind"])),
                ("success_status", str(status)),
                ("media_type", json.dumps(media_type)),
                ("response_json", json.dumps(sample_json, ensure_ascii=False)),
            )
            entry = ["    OperationSpec {"]
            entry.extend(f"        {name}: {value}," for name, value in fields)
            entry.append("    },")
            entries.append("\n".join(entry))
        module = rust_ident(api)
        sources[module] = (
            "// Generated from the v13 operation catalog; do not edit by hand.\n"
            "use crate::OperationSpec;\n\npub const OPERATIONS: &[OperationSpec] = &[\n"
            + "\n".join(entries)
            + "\n];\n"
        )
    return sources


def api_contracts(operations: list[dict[str, Any]], samples: dict[str, tuple[int, str, Any]]) -> None:
    path = "crates/api-contracts"
    write(
        f"{path}/Cargo.toml",
        '''[package]
name = "gurine-api-contracts"
version.workspace = true
edition.workspace = true

[dependencies]
serde.workspace = true
serde_json.workspace = true

[lints]
workspace = true
''',
    )
    for module, source in operation_spec_sources(operations, samples).items():
        write(
            f"{path}/src/{module}.rs",
            source,
        )
    write(
        f"{path}/src/lib.rs",
        '''#![forbid(unsafe_code)]

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OperationSpec {
    pub id: &'static str,
    pub api: &'static str,
    pub method: &'static str,
    pub path: &'static str,
    pub auth: &'static str,
    pub capability: &'static str,
    pub idempotency_required: bool,
    pub assurance_level: &'static str,
    pub step_up_required: bool,
    pub operation_kind: &'static str,
    pub success_status: u16,
    pub media_type: &'static str,
    pub response_json: &'static str,
}

pub mod common;
pub mod control;
pub mod control_api;
pub mod identity;
pub mod identity_provider;
pub mod identity_service_internal;
pub mod openapi;
pub mod problem;
pub mod public;
pub mod public_api;
pub mod submission;
pub mod submission_api;
''',
    )
    write(f"{path}/src/common.rs", "pub const SPECIFICATION_VERSION: &str = \"13.0.0\";")
    write(f"{path}/src/problem.rs", '''use serde::Serialize;

#[derive(Debug, Serialize)]
pub struct Problem<'a> {
    pub code: &'a str,
    pub title: &'a str,
    pub status: u16,
    pub request_id: &'a str,
}
''')
    write(f"{path}/src/openapi.rs", "pub const OPENAPI_VERSION: &str = \"3.1.0\";")
    for module in ("public", "control", "submission", "identity"):
        write(f"{path}/src/{module}/mod.rs", f'pub const SURFACE: &str = "{module}";')
    evidence = operation_sample_evidence(samples)
    sample_path = "verification/generated-operation-samples.json"
    write(
        sample_path,
        biome_format(sample_path, json.dumps(evidence, ensure_ascii=False, indent=2)),
    )


def ordinary_crate(path: str, modules: list[str]) -> None:
    name = f"gurine-{Path(path).name}"
    write(
        f"{path}/Cargo.toml",
        f'''[package]
name = "{name}"
version.workspace = true
edition.workspace = true

[dependencies]
serde.workspace = true
thiserror.workspace = true
time.workspace = true
uuid.workspace = true

[lints]
workspace = true
''',
    )
    declarations = []
    for module_path in modules:
        if module_path == "lib.rs":
            continue
        clean = module_path.removesuffix(".rs")
        if clean.endswith("/mod"):
            clean = clean.removesuffix("/mod")
        declarations.append(f"pub mod {clean.split('/')[0]};")
        write(
            f"{path}/src/{module_path}",
            f'''//! {Path(path).name}::{clean} contract implementation.

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ContractMarker {{
    pub specification_version: &'static str,
}}

impl Default for ContractMarker {{
    fn default() -> Self {{
        Self {{ specification_version: "{SPEC_VERSION}" }}
    }}
}}
''',
        )
    write(
        f"{path}/src/lib.rs",
        "#![forbid(unsafe_code)]\n\n" + "\n".join(sorted(set(declarations))),
    )


def application_crate() -> None:
    path = "crates/application"
    modules = ["ports/mod.rs", "commands/mod.rs", "queries/mod.rs", "authorization.rs", "transactions.rs", "idempotency.rs"]
    ordinary_crate(path, ["lib.rs", *modules])
    write(
        f"{path}/Cargo.toml",
        '''[package]
name = "gurine-application"
version.workspace = true
edition.workspace = true

[dependencies]
serde.workspace = true
serde_json.workspace = true
thiserror.workspace = true
time.workspace = true
uuid.workspace = true

[lints]
workspace = true
''',
    )


def api_service(path: str, api: str) -> None:
    package = f"gurine-{Path(path).name}"
    crate = crate_ident(package)
    write(
        f"{path}/Cargo.toml",
        f'''[package]
name = "{package}"
version.workspace = true
edition.workspace = true

[dependencies]
actix-web.workspace = true
gurine-api-contracts = {{ path = "../../crates/api-contracts" }}
gurine-application = {{ path = "../../crates/application" }}
serde.workspace = true
serde_json.workspace = true
tracing.workspace = true
tracing-subscriber.workspace = true
uuid.workspace = true

[lints]
workspace = true
''',
    )
    write(
        f"{path}/src/lib.rs",
        '''#![forbid(unsafe_code)]

pub mod app;
pub mod config;
pub mod health;
pub mod routes;
pub mod state;
''',
    )
    write(
        f"{path}/src/main.rs",
        f'''#![forbid(unsafe_code)]

use std::io;

#[actix_web::main]
async fn main() -> io::Result<()> {{
    {crate}::app::run().await
}}
''',
    )
    write(
        f"{path}/src/config.rs",
        '''use std::{env, io};

pub struct Config {
    pub bind: String,
}

impl Config {
    pub fn from_env(default_bind: &str) -> Result<Self, io::Error> {
        let bind = env::var("HTTP_BIND").unwrap_or_else(|_| default_bind.to_owned());
        if bind.trim().is_empty() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "HTTP_BIND is empty"));
        }
        Ok(Self { bind })
    }
}
''',
    )
    write(f"{path}/src/state.rs", "#[derive(Clone, Default)]\npub struct AppState;")
    write(
        f"{path}/src/health.rs",
        '''use actix_web::{HttpResponse, Responder};

pub async fn live() -> impl Responder {
    HttpResponse::Ok().json(serde_json::json!({"status": "live"}))
}

pub async fn ready() -> impl Responder {
    HttpResponse::Ok().json(serde_json::json!({"status": "ready"}))
}
''',
    )
    default_bind = {"public-api": "0.0.0.0:8080", "control-api": "0.0.0.0:8081", "submission-api": "0.0.0.0:8082", "identity-provider": "0.0.0.0:8083"}[api]
    write(
        f"{path}/src/app.rs",
        f'''use std::io;

use actix_web::{{web, App, HttpServer}};

use crate::{{config::Config, health, routes}};

pub async fn run() -> io::Result<()> {{
    let config = Config::from_env("{default_bind}")?;
    HttpServer::new(|| {{
        App::new()
            .route("/health/live", web::get().to(health::live))
            .route("/health/ready", web::get().to(health::ready))
            .configure(routes::configure)
    }})
    .bind(config.bind)?
    .run()
    .await
}}
''',
    )


def worker_service(path: str, modules: list[str]) -> None:
    package = f"gurine-{Path(path).name}"
    write(
        f"{path}/Cargo.toml",
        f'''[package]
name = "{package}"
version.workspace = true
edition.workspace = true

[dependencies]
tokio.workspace = true
tracing.workspace = true
tracing-subscriber.workspace = true

[lints]
workspace = true
''',
    )
    top_modules = []
    for module_path in modules:
        if module_path in ("main.rs", "lib.rs"):
            continue
        module = module_path.removesuffix(".rs").removesuffix("/mod")
        top_modules.append(module.split("/")[0])
        write(f"{path}/src/{module_path}", f'pub const COMPONENT: &str = "{Path(path).name}:{module}";')
    write(f"{path}/src/lib.rs", "#![forbid(unsafe_code)]\n\n" + "\n".join(f"pub mod {name};" for name in sorted(set(top_modules))))
    write(
        f"{path}/src/main.rs",
        f'''#![forbid(unsafe_code)]

#[tokio::main]
async fn main() -> Result<(), std::io::Error> {{
    tracing_subscriber::fmt().json().init();
    tracing::info!(service = "{Path(path).name}", "service started");
    tokio::signal::ctrl_c().await
}}
''',
    )


def rust_workspace() -> None:
    final_tree = load_yaml("specs/repository/final-tree.yaml")
    workspace_members = final_tree["cargo_workspace"]["members"]
    members = list(workspace_members)
    root_workspace(members)
    operations = operation_catalog()
    samples = operation_response_samples()
    api_contracts(operations, samples)
    application_crate()
    api_paths = {
        "services/public-api": "public-api",
        "services/control-api": "control-api",
        "services/submission-api": "submission-api",
        "services/identity-api": "identity-provider",
    }
    for path, modules in workspace_members.items():
        if path in ("crates/api-contracts", "crates/application"):
            continue
        if path in api_paths:
            api_service(path, api_paths[path])
        elif path.startswith("crates/"):
            ordinary_crate(path, modules)
        else:
            worker_service(path, modules)


def route_directory(route: str) -> str:
    if route == "/":
        return ""
    segments = []
    for segment in route.strip("/").split("/"):
        match = re.fullmatch(r"\{([^}]+)\}", segment)
        segments.append(f"[{match.group(1)}]" if match else segment)
    return "/".join(segments)


def frontend_workspace(screens: list[dict[str, Any]]) -> None:
    generated_screen_paths: list[str] = []
    package_json = {
        "name": "gurine",
        "private": True,
        "packageManager": "bun@1.3.14",
        "workspaces": ["apps/*", "packages/*"],
        "scripts": {
            "build": "bun run --filter '*' build",
            "check": "bun run --filter '*' check",
            "test": "bun run --filter '*' test",
            "codegen": "bun run scripts/generate-clients.ts",
        },
        "devDependencies": {
            "@biomejs/biome": "2.5.3",
            "@hey-api/openapi-ts": "0.99.0",
            "@playwright/test": "1.55.0",
            "@types/node": "24.3.0",
            "typescript": "5.9.3",
        },
    }
    write("package.json", json.dumps(package_json, indent=2, ensure_ascii=False))
    write("biome.jsonc", '''{
  "$schema": "https://biomejs.dev/schemas/2.5.3/schema.json",
  "files": { "includes": ["**", "!!**/src/generated/**"] },
  "formatter": { "enabled": true, "indentStyle": "space", "indentWidth": 2 },
  "linter": { "enabled": true, "rules": { "recommended": true } }
}''')
    write("tsconfig.json", '''{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "useUnknownInCatchVariables": true,
    "module": "ESNext",
    "target": "ES2022",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "allowJs": true,
    "checkJs": true,
    "skipLibCheck": true
  }
}''')
    app_for_surface = {"public": "public-web", "response": "response-portal", "internal": "review-console"}
    grouped: dict[str, list[dict[str, Any]]] = {app: [] for app in app_for_surface.values()}
    for screen in screens:
        grouped[app_for_surface[screen["surface"]]].append(screen)
    for app, app_screens in grouped.items():
        write(
            f"apps/{app}/package.json",
            json.dumps(
                {
                    "name": f"@gurine/{app}",
                    "private": True,
                    "type": "module",
                    "scripts": {
                        "build": "vite build",
                        "check": "svelte-kit sync && svelte-check --tsconfig ./tsconfig.json",
                        "test": "vitest run",
                    },
                    "dependencies": {
                        "@gurine/ui": "workspace:*",
                        "@sveltejs/kit": "2.69.2",
                        "svelte": "5.56.4",
                        "svelte-adapter-bun": "1.0.1",
                        "valibot": "1.1.0",
                    },
                    "devDependencies": {
                        "@sveltejs/vite-plugin-svelte": "6.2.0",
                        "svelte-check": "4.3.1",
                        "typescript": "5.9.3",
                        "vite": "7.1.4",
                        "vitest": "3.2.4",
                    },
                },
                indent=2,
            ),
        )
        write(f"apps/{app}/svelte.config.js", '''import adapter from "svelte-adapter-bun";
import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

export default { preprocess: vitePreprocess(), kit: { adapter: adapter() } };
''')
        write(f"apps/{app}/vite.config.ts", '''import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vite";

export default defineConfig({ plugins: [sveltekit()] });
''')
        write(f"apps/{app}/tsconfig.json", '{"extends":"./.svelte-kit/tsconfig.json","compilerOptions":{"allowJs":true,"checkJs":true,"strict":true,"noUncheckedIndexedAccess":true,"exactOptionalPropertyTypes":true,"useUnknownInCatchVariables":true,"skipLibCheck":true,"types":["node"]}}')
        write(f"apps/{app}/src/app.d.ts", "declare global {}\nexport {};")
        write(f"apps/{app}/src/app.html", '''<!doctype html>
<html lang="ko">
  <head><meta charset="utf-8" />%sveltekit.head%</head>
  <body data-sveltekit-preload-data="hover"><div style="display: contents">%sveltekit.body%</div></body>
</html>''')
        write(
            f"apps/{app}/src/routes/+layout.svelte",
            '''<script lang="ts">
  import "@gurine/ui/styles.css";
  let { children } = $props();
</script>

<svelte:head><meta name="viewport" content="width=device-width, initial-scale=1" /></svelte:head>
<a class="skip-link" href="#main-content">본문으로 건너뛰기</a>
{@render children()}
''',
        )
        write(f"apps/{app}/src/routes/+error.svelte", '''<script lang="ts">
  import { page } from "$app/state";
</script>
<main id="main-content"><h1>요청을 완료하지 못했습니다</h1><p>{page.status}: 다시 시도해 주세요.</p></main>
''')
        for screen in app_screens:
            directory = route_directory(screen["route"])
            base = f"apps/{app}/src/routes"
            if directory:
                base += f"/{directory}"
            view_model = {
                "id": screen["id"],
                "title": screen["title"],
                "route": screen["route"],
                "archetype": screen["archetype"],
                "sections": screen["section_order"],
                "actions": screen["actions"],
                "states": screen["states"],
                "dataOperations": screen["data_operations"],
            }
            screen_path = f"{base}/screen.ts"
            write(
                screen_path,
                "import type { ScreenViewModel } from \"@gurine/ui\";\n\n"
                + f"export const screen = {json.dumps(view_model, ensure_ascii=False, indent=2)} as const satisfies ScreenViewModel;",
            )
            generated_screen_paths.append(str(ROOT / screen_path))
            write(f"{base}/+page.server.ts", '''import { screen } from "./screen";

export const load = async () => ({ screen });
''')
            write(f"{base}/+page.svelte", '''<script lang="ts">
  import { ScreenPage } from "@gurine/ui";
  let { data } = $props();
</script>

<ScreenPage screen={data.screen} />
''')
    subprocess.run(
        ["bunx", "biome", "format", "--write", *generated_screen_paths],
        cwd=ROOT,
        check=True,
    )
    packages = ["api-client-public", "api-client-control", "api-client-submission", "api-client-identity-internal", "config"]
    for package in packages:
        generated_client = package.startswith("api-client-")
        typecheck = (
            "tsc --noEmit -p tsconfig.json && tsc --noEmit -p tsconfig.generated.json"
            if generated_client
            else "tsc --noEmit"
        )
        write(
            f"packages/{package}/package.json",
            json.dumps({"name": f"@gurine/{package}", "private": True, "type": "module", "exports": "./src/index.ts", "scripts": {"build": typecheck, "check": typecheck, "test": "vitest run"}, "devDependencies": {"typescript": "5.9.3", "vitest": "3.2.4"}}, indent=2),
        )
        if generated_client:
            write(f"packages/{package}/tsconfig.json", '{"extends":"../../tsconfig.json","include":["src/index.ts"],"exclude":["src/generated/**"]}')
            write(f"packages/{package}/tsconfig.generated.json", '{"extends":"../../tsconfig.json","compilerOptions":{"exactOptionalPropertyTypes":false},"include":["src/generated/**/*.ts"]}')
        else:
            write(f"packages/{package}/tsconfig.json", '{"extends":"../../tsconfig.json","include":["src/**/*.ts"]}')
        write(f"packages/{package}/src/index.ts", f'export const packageName = "@gurine/{package}";')
    write(
        "packages/ui/package.json",
        json.dumps({"name": "@gurine/ui", "private": True, "type": "module", "exports": {".": "./src/index.ts", "./styles.css": "./src/styles/styles.css"}, "scripts": {"build": "svelte-check --tsconfig ./tsconfig.json", "check": "svelte-check --tsconfig ./tsconfig.json", "test": "vitest run"}, "dependencies": {"svelte": "5.56.4"}, "devDependencies": {"svelte-check": "4.3.1", "typescript": "5.9.3", "vitest": "3.2.4"}}, indent=2),
    )
    write("packages/ui/tsconfig.json", '{"extends":"../../tsconfig.json","include":["src/**/*.ts","src/**/*.svelte"]}')
    write(
        "packages/ui/src/index.ts",
        '''export { default as ScreenPage } from "./components/ScreenPage.svelte";

export type ScreenViewModel = {
  id: string;
  title: string;
  route: string;
  archetype: string;
  sections: readonly ({ id: string; title: string; purpose: string; component: string; test_id: string } & Record<string, unknown>)[];
  actions: readonly ({ id: string; label: string } & Record<string, unknown>)[];
  states: readonly unknown[] | Record<string, unknown>;
  dataOperations: readonly ({ operation_id: string; method: string; path: string; blocking: boolean } & Record<string, unknown>)[];
};
''',
    )
    write(
        "packages/ui/src/components/ScreenPage.svelte",
        '''<script lang="ts">
  import type { ScreenViewModel } from "../index";
  let { screen }: { screen: ScreenViewModel } = $props();
</script>

<header class="site-header"><a href="/" class="brand">구린네</a><span>근거와 한계를 함께 공개합니다</span></header>
<main id="main-content" data-screen-id={screen.id} data-archetype={screen.archetype}>
  <div class="page-heading"><p class="eyebrow">{screen.id}</p><h1>{screen.title}</h1></div>
  {#each screen.sections as section, index (section.id)}
    <section id={section.id} data-testid={section.test_id} class:primary={index === 0}>
      <p class="section-number">{String(index + 1).padStart(2, "0")}</p>
      <div><h2>{section.title}</h2><p>{section.purpose}</p></div>
    </section>
  {/each}
  {#if screen.actions.length > 0}
    <nav aria-label="화면 작업" class="actions">
      {#each screen.actions as action (action.id)}<button type="button" data-action-id={action.id}>{action.label}</button>{/each}
    </nav>
  {/if}
</main>
''',
    )
    write(
        "packages/ui/src/styles/styles.css",
        ''':root { color-scheme: light; font-family: Pretendard, "Noto Sans KR", system-ui, sans-serif; background: #f3f1ea; color: #17221c; }
* { box-sizing: border-box; }
body { margin: 0; }
.skip-link { position: absolute; left: -9999px; }
.skip-link:focus { left: 1rem; top: 1rem; z-index: 10; background: white; padding: .75rem; }
.site-header { min-height: 72px; padding: 1rem clamp(1rem, 5vw, 5rem); display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #aab7aa; }
.brand { color: inherit; font-size: 1.5rem; font-weight: 800; text-decoration: none; }
main { max-width: 1180px; margin: 0 auto; padding: clamp(2rem, 6vw, 6rem) clamp(1rem, 4vw, 3rem); }
.page-heading { max-width: 760px; margin-bottom: 3rem; }
.eyebrow, .section-number { color: #9b3c25; font-weight: 700; letter-spacing: .08em; }
h1 { font-size: clamp(2.5rem, 7vw, 5.8rem); line-height: .98; margin: .4rem 0; }
section { display: grid; grid-template-columns: 5rem 1fr; gap: 1rem; padding: 2rem 0; border-top: 1px solid #aab7aa; }
section.primary { background: #e0e8df; margin-inline: -1rem; padding-inline: 1rem; }
h2 { margin-top: 0; font-size: clamp(1.25rem, 3vw, 2rem); }
p { line-height: 1.7; }
.actions { display: flex; flex-wrap: wrap; gap: .75rem; margin-top: 2rem; }
button { border: 0; background: #173d2b; color: white; padding: .85rem 1.15rem; border-radius: 999px; font: inherit; font-weight: 700; }
button:focus-visible, a:focus-visible { outline: 3px solid #d17039; outline-offset: 3px; }
@media (max-width: 640px) { .site-header span { display: none; } section { grid-template-columns: 2.5rem 1fr; } }
@media (prefers-reduced-motion: reduce) { *, *::before, *::after { scroll-behavior: auto !important; transition-duration: 0.01ms !important; animation-duration: 0.01ms !important; animation-iteration-count: 1 !important; } }
''',
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Materialize the source-derived Rust and SvelteKit product surface."
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    parse_args(argv)
    rust_workspace()
    screens = load_yaml("specs/ui/screen-build-manifest.yaml")["screens"]
    frontend_workspace(screens)
    print(f"materialized Rust workspace and {len(screens)} SvelteKit routes")


if __name__ == "__main__":
    main()
