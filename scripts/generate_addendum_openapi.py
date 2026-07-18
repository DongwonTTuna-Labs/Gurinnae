#!/usr/bin/env python3
"""Merge the owner-addendum HTTP operations into the generated API specs.

The addendum operation/resource contracts are the only input; this generator
does not invent routes.  Every generated operation has a closed request
schema, an explicit operation-specific response schema name, the service
assertion security binding and the exact error-code list from the resource
contract.
"""

from __future__ import annotations

import copy
import json
import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ADDENDUM = ROOT / "specs/product/addendum-operation-contracts.yaml"
RESOURCES = ROOT / "specs/product/addendum-resource-error-contracts.yaml"


def primitive(expression: str) -> dict:
    expression = expression.lower()
    if "array" in expression:
        return {"type": "array", "items": {"type": "string"}}
    if "boolean" in expression:
        return {"type": "boolean"}
    if "int" in expression or "decimal" in expression:
        return {"type": "integer", "format": "int64"}
    if "datetime" in expression:
        return {"type": "string", "format": "date-time"}
    if "date" in expression:
        return {"type": "string", "format": "date"}
    if "uuid" in expression:
        return {"type": "string", "format": "uuid"}
    if "sha256" in expression or "digest" in expression:
        return {"type": "string", "pattern": "^[0-9a-f]{64}$"}
    if expression.startswith("nullable"):
        return {"type": ["string", "null"]}
    if expression.startswith("string") or "enum" in expression or "secret" in expression:
        return {"type": "string"}
    # Nested schemas are named in the contract.  A closed object reference is
    # emitted here and replaced by a component with no open properties.
    return {"type": "object", "additionalProperties": False}


def referenced_names(expression: str, known: set[str]) -> set[str]:
    return {name for name in known if name in expression}


def add_contract_schema(name: str, resource_doc: dict, schemas: dict, seen: set[str]) -> None:
    if name in seen or name not in resource_doc.get("schemas", {}):
        return
    seen.add(name)
    contract = resource_doc["schemas"][name]
    fields = contract.get("fields", {})
    known = set(resource_doc.get("schemas", {}))
    schemas[name] = {
        "type": "object", "additionalProperties": False,
        "properties": {
            field: (
                {"$ref": f"#/components/schemas/{str(value).strip()}"}
                if str(value).strip() in known
                else (
                    {"type": "array", "items": {"$ref": f"#/components/schemas/{re.fullmatch(r'(?:unique-)?array<([^>]+)>', str(value).strip()).group(1)}"}}
                    if re.fullmatch(r"(?:unique-)?array<([^>]+)>", str(value).strip())
                    and re.fullmatch(r"(?:unique-)?array<([^>]+)>", str(value).strip()).group(1) in known
                    else primitive(str(value))
                )
            )
            for field, value in fields.items()
        },
        "required": list(fields),
    }
    for value in fields.values():
        for child in referenced_names(str(value), known):
            add_contract_schema(child, resource_doc, schemas, seen)


def contract_property(expression: str, resource_doc: dict, schemas: dict) -> dict:
    known = set(resource_doc.get("schemas", {}))
    direct = expression.strip()
    if direct in known:
        add_contract_schema(direct, resource_doc, schemas, set())
        return {"$ref": f"#/components/schemas/{direct}"}
    match = re.fullmatch(r"(?:unique-)?array<([^>]+)>", direct)
    if match and match.group(1) in known:
        child = match.group(1)
        add_contract_schema(child, resource_doc, schemas, set())
        return {"type": "array", "items": {"$ref": f"#/components/schemas/{child}"}}
    return primitive(expression)


def error_responses(codes: list[str]) -> dict:
    grouped: dict[str, list[str]] = {}
    status_by_code = {
        "INVALID_PARAMETER": "400", "INVALID_CURSOR": "400", "INVALID_REQUEST": "400",
        "ACTOR_ASSERTION_REQUIRED": "401", "ACTOR_ASSERTION_INVALID": "401", "SERVICE_ASSERTION_REQUIRED": "401",
        "CAPABILITY_DENIED": "403", "BFF_CALLER_DENIED": "403", "SUBMISSION_SESSION_REQUIRED": "401",
        "IDEMPOTENCY_CONFLICT": "409", "ACTION_PROPOSAL_STALE": "409", "VERSION_CONFLICT": "409",
        "RESOURCE_NOT_FOUND": "404", "TARGET_NOT_FOUND": "404", "INTERNAL_ERROR": "500",
    }
    for code in codes:
        grouped.setdefault(status_by_code.get(code, "422"), []).append(code)
    return {
        status: {
            "description": "Problem response: " + ", ".join(values),
            "content": {"application/problem+json": {"schema": {"$ref": "#/components/schemas/AddendumProblemDetailsV1"}}},
            "x-error-codes": values,
        }
        for status, values in grouped.items()
    }


def operation_node(operation: dict, binding: dict, schemas: dict, resource_doc: dict, control: bool) -> dict:
    request = operation.get("request", {})
    fields = request.get("fields", {})
    required = list(request.get("required", []))
    request_name = binding["request_schema"]
    response_name = binding["success_schema"]
    schemas[request_name] = {"type": "object", "additionalProperties": False,
                             "properties": {name: contract_property(str(value), resource_doc, schemas) for name, value in fields.items()},
                             "required": required}
    add_contract_schema(request_name, resource_doc, schemas, set())
    contract_schema = resource_doc.get("schemas", {}).get(response_name, {})
    response_fields = contract_schema.get("fields", {})
    schemas[response_name] = {
        "type": "object", "additionalProperties": False,
        "properties": {name: contract_property(str(value), resource_doc, schemas) for name, value in response_fields.items()},
        "required": list(response_fields),
    }
    add_contract_schema(response_name, resource_doc, schemas, set())
    node = {
        "operationId": operation["operation_id"],
        "summary": operation["operation_id"],
        "tags": ["addendum"],
        "x-operation-kind": operation["kind"],
        "x-error-codes": list(operation.get("errors", [])),
        "security": ([{"ActorAssertion": []}] if control else ([{"BffServiceAssertion": [], "ScopedSubmissionSession": []}] if "scoped" in binding["transport_profile"].lower() else [{"BffServiceAssertion": []}])),
        "responses": {
            str(binding["success_status"]): {
                "description": "Successful response",
                "content": {binding["success_media_type"]: {"schema": {"$ref": f"#/components/schemas/{response_name}"}}},
            },
        },
    }
    path_parameters = re.findall(r"\{([^}]+)\}", operation["path"])
    if path_parameters:
        node["parameters"] = [{"name": name, "in": "path", "required": True, "schema": {"type": "string", "format": "uuid"}} for name in path_parameters]
    node["responses"].update(error_responses(list(operation.get("errors", []))))
    if operation["method"] != "GET":
        node.setdefault("parameters", []).append({"name": "Idempotency-Key", "in": "header", "required": True, "schema": {"type": "string", "minLength": 8, "maxLength": 200}})
        node["requestBody"] = {"required": True, "content": {"application/json": {"schema": {"$ref": f"#/components/schemas/{request_name}"}}}}
    return node


def merge(api: str, operations: list[dict], resource_doc: dict) -> None:
    yaml_path = ROOT / f"specs/api/{api}.openapi.yaml"
    json_path = ROOT / f"specs/api/{api}.openapi.json"
    generated_path = ROOT / f"specs/generated/{api}.openapi.json"
    document = yaml.safe_load(yaml_path.read_text())
    document.setdefault("tags", []).append({"name": "addendum"})
    schemas = document.setdefault("components", {}).setdefault("schemas", {})
    schemas.setdefault("AddendumProblemDetailsV1", {
        "type": "object", "additionalProperties": False,
        "properties": {
            "code": {"type": "string"}, "title": {"type": "string"},
            "status": {"type": "integer"}, "requestId": {"type": "string", "format": "uuid"},
            "detail": {"type": ["string", "null"]},
        },
        "required": ["code", "title", "status", "requestId"],
    })
    # Repair the legacy self-reference in the estimate query schema while
    # materialising the merged document.  Its data payload is a concrete
    # estimate, not another envelope.
    estimate = schemas.get("estimateBackfillReceipt")
    if isinstance(estimate, dict) and isinstance(estimate.get("properties"), dict):
        data = estimate["properties"].get("data")
        if isinstance(data, dict) and data.get("$ref") == "#/components/schemas/estimateBackfillReceipt":
            data.clear()
            data.update({
                "type": "object", "additionalProperties": False,
                "properties": {
                    "sourceId": {"type": "string"}, "from": {"type": "string", "format": "date"},
                    "to": {"type": "string", "format": "date"}, "estimatedRecords": {"type": "integer"},
                    "estimatedJobs": {"type": "integer"}, "estimatedCostKrw": {"type": "string"},
                    "estimatedDurationSeconds": {"type": "integer"}, "dedupeStrategy": {"type": "string"},
                    "downstreamEffects": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["sourceId", "from", "to", "estimatedRecords", "estimatedJobs", "estimatedCostKrw", "estimatedDurationSeconds", "dedupeStrategy", "downstreamEffects"],
            })
    for operation in operations:
        binding = resource_doc["operation_bindings"][operation["operation_id"]]
        path = document.setdefault("paths", {}).setdefault(operation["path"], {})
        path[operation["method"].lower()] = operation_node(operation, binding, schemas, resource_doc, api == "control-api")
    # JSON is the generated source consumed by Rust and BFF imports. YAML and
    # JSON are written from the same object so semantic equality is guaranteed.
    json_bytes = json.dumps(document, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    yaml_path.write_text(yaml.safe_dump(document, allow_unicode=True, sort_keys=False))
    json_path.write_text(json_bytes)
    generated_path.write_text(json_bytes)


def write_identity(operations: list[dict], resource_doc: dict) -> None:
    """Emit the small procurement identity-api document separately from the
    nine-operation identity-service-internal document."""
    document = {
        "openapi": "3.1.0",
        "info": {"title": "Gurine Identity API", "version": "13.0.0"},
        "servers": [{"url": "http://identity-api:8085"}],
        "tags": [{"name": "procurement"}],
        "paths": {},
        "components": {
            "securitySchemes": {"ServiceAssertion": {"type": "apiKey", "in": "header", "name": "X-Gurine-Service-Assertion"}},
            "schemas": {"AddendumProblemDetailsV1": {"type": "object", "additionalProperties": False, "properties": {"code": {"type": "string"}, "title": {"type": "string"}, "status": {"type": "integer"}, "requestId": {"type": "string", "format": "uuid"}}, "required": ["code", "title", "status", "requestId"]}},
        },
    }
    schemas = document["components"]["schemas"]
    for operation in operations:
        binding = resource_doc["operation_bindings"].get(operation["operation_id"], {})
        node = operation_node(operation, binding, schemas, resource_doc, False)
        node["security"] = [{"ServiceAssertion": []}]
        document["paths"].setdefault(operation["path"], {})[operation["method"].lower()] = node
    for suffix in ("api", "generated"):
        path = ROOT / f"specs/{suffix}/identity-api.openapi.{'yaml' if suffix == 'api' else 'json'}"
        payload = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
        if suffix == "api":
            path.write_text(yaml.safe_dump(document, allow_unicode=True, sort_keys=False))
        else:
            path.write_text(payload)


def main() -> None:
    operations = yaml.safe_load(ADDENDUM.read_text())["operations"]
    resource_doc = yaml.safe_load(RESOURCES.read_text())
    grouped = {"control-api": [row for row in operations if row["api"] == "control-api"],
               "submission-api": [row for row in operations if row["api"] == "submission-api"]}
    for api, rows in grouped.items():
        merge(api, rows, resource_doc)
    write_identity([row for row in operations if row.get("api") == "identity-api"], resource_doc)
    print(f"merged {sum(map(len, grouped.values()))} additive operations")


if __name__ == "__main__":
    main()
