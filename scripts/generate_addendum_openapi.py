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
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ADDENDUM = ROOT / "specs/product/addendum-operation-contracts.yaml"
RESOURCES = ROOT / "specs/product/addendum-resource-error-contracts.yaml"
PROVIDER_CONTROL_OPERATION_IDS = (
    "disableProviderRouting",
    "testProviderConnection",
    "upgradeProviderModel",
    "setModelAutoUpgrade",
)


def primitive(expression: str) -> dict:
    raw_expression = expression
    expression = expression.lower()
    # Contract shorthand uses bare pipe-separated values for enums in the
    # operation catalog (for example `START_REVIEW|RESOLVE`).  Preserve that
    # closed set in OpenAPI instead of falling through to an empty object.
    if "|" in raw_expression and not raw_expression.startswith(("array<", "unique-array<", "enum<", "optional<", "nullable<")):
        values = raw_expression.split("=", 1)[0].split("|")
        return {"type": "string", "enum": values}
    if expression.startswith("const<") and expression.endswith(">"):
        value = raw_expression[len("const<") : raw_expression.rfind(">")].strip()
        if value.lower() in {"true", "false"}:
            return {"type": "boolean", "const": value.lower() == "true"}
        return {"type": "string", "const": value}
    # The product operation catalog also uses the compact `const value`
    # spelling.  Keep it a literal in OpenAPI; falling through to an empty
    # object makes generic contract fixtures emit `{}` and the owner routine
    # correctly rejects the request as invalid.
    if expression.startswith("const "):
        value = raw_expression[len("const ") :].strip()
        if value.lower() in {"true", "false"}:
            return {"type": "boolean", "const": value.lower() == "true"}
        return {"type": "string", "const": value}
    if expression.strip() == "enum action_payloads.kinds":
        return {"type": "string", "enum": [
            "HYPOTHESIS", "CLAIM", "TASK", "COMPARABLE", "COMMUNICATION", "PUBLICATION",
            "RETRACTION", "RULE_ACTIVATION", "ROLE_GRANT", "KILL_SWITCH",
            "COMMUNICATION_AUTHORIZATION", "ASSET_RIGHTS_DECISION", "RETENTION_SCHEDULE",
            "FUNDING_DISCLOSURE", "CAPABILITY_ACTIVATION", "RESPONSE_POLICY_CALENDAR",
            "COMMERCIAL_CONTROL", "PROVIDER_CONTROL",
        ]}
    if raw_expression.startswith("optional<") and raw_expression.endswith(">"):
        inner = raw_expression[len("optional<"):-1]
        return primitive(inner)
    if raw_expression.startswith("nullable<") and raw_expression.endswith(">"):
        inner = raw_expression[len("nullable<"):-1]
        return {"anyOf": [primitive(inner), {"type": "null"}]}
    if "array" in expression:
        return {"type": "array", "items": {"type": "string"}}
    if expression.startswith("enum<"):
        values = raw_expression[len("enum<") : raw_expression.rfind(">")]
        return {"type": "string", "enum": values.split("|")}
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
    if expression.startswith("uri-reference") or expression.startswith("uri"):
        return {"type": "string", "format": "uri-reference"}
    if "sha256" in expression or "digest" in expression:
        return {"type": "string", "pattern": "^[0-9a-f]{64}$"}
    if expression.startswith("string") or "secret" in expression:
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
    known = set(resource_doc.get("schemas", {}))
    if contract.get("kind") == "enum":
        schemas[name] = {"type": "string", "enum": list(contract.get("values", []))}
        return
    if contract.get("kind") == "discriminated_union":
        discriminator = contract.get("discriminator", "kind")
        common = contract.get("common_fields", {})
        if not contract.get("variants") and contract.get("fields"):
            fields = contract.get("fields", {})
            schemas[name] = {
                "type": "object", "additionalProperties": False,
                "properties": {field: contract_property(str(value), resource_doc, schemas) for field, value in fields.items()},
                "required": list(contract.get("required", fields.keys())),
            }
            return
        branches = []
        for variant, definition in contract.get("variants", {}).items():
            variant_fields = definition.get("fields", {})
            fields = dict(common)
            fields.update(variant_fields)
            properties = {
                field: contract_property(str(value), resource_doc, schemas)
                for field, value in fields.items()
            }
            properties[discriminator] = {"type": "string", "const": variant}
            selected_required = definition.get("required")
            if selected_required is None:
                selected_required = list(variant_fields)
            required = list(dict.fromkeys([*common, *selected_required]))
            if discriminator in fields and discriminator not in required:
                required.append(discriminator)
            branches.append({
                "type": "object",
                "additionalProperties": bool(definition.get("additional_properties", False)),
                "properties": properties,
                "required": required,
            })
        schemas[name] = {"oneOf": branches}
        for value in common.values():
            for child in referenced_names(str(value), known):
                add_contract_schema(child, resource_doc, schemas, seen)
        for definition in contract.get("variants", {}).values():
            for value in definition.get("fields", {}).values():
                for child in referenced_names(str(value), known):
                    add_contract_schema(child, resource_doc, schemas, seen)
        return
    fields = contract.get("fields", {})
    schemas[name] = {
        "type": "object", "additionalProperties": False,
        "properties": {
            field: contract_property(str(value), resource_doc, schemas)
            for field, value in fields.items()
        },
        "required": list(fields),
    }
    for value in fields.values():
        for child in referenced_names(str(value), known):
            add_contract_schema(child, resource_doc, schemas, seen)


def contract_property(expression: str, resource_doc: dict, schemas: dict) -> dict:
    known = set(resource_doc.get("schemas", {})) | set(schemas)
    direct = expression.strip().split("@", 1)[0]
    if direct in known:
        add_contract_schema(direct, resource_doc, schemas, set())
        return {"$ref": f"#/components/schemas/{direct}"}
    wrapper = re.fullmatch(r"(optional|nullable)<([^>]+)>", direct)
    if wrapper and wrapper.group(2) in known:
        child = wrapper.group(2)
        add_contract_schema(child, resource_doc, schemas, set())
        reference = {"$ref": f"#/components/schemas/{child}"}
        if wrapper.group(1) == "optional":
            return reference
        return {"anyOf": [reference, {"type": "null"}]}
    shorthand = re.fullmatch(r"nullable-(.+)", direct)
    if shorthand:
        inner = shorthand.group(1)
        return {"anyOf": [primitive(inner), {"type": "null"}]}
    match = re.fullmatch(r"(?:unique-)?array<([^>]+)>(?:\[[^\]]+\])?", direct)
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
        "IDEMPOTENCY_CONFLICT": "409", "ACTION_PROPOSAL_REQUIRED": "409",
        "ACTION_PROPOSAL_STALE": "409", "VERSION_CONFLICT": "409",
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
    # The journey handoff request has a discriminator-sensitive nullable enum
    # branch.  Keep this exact wire shape in the generated OpenAPI even when a
    # legacy operation fixture uses the older shorthand expressions.
    if operation["operation_id"] == "decideJourneyHandoff":
        schemas[request_name]["properties"].update({
            "schemaVersion": {
                "type": "string",
                "const": "decide-journey-handoff.request.v1",
            },
            "decision": {
                "type": "string",
                "enum": ["ACKNOWLEDGE", "DECLINE"],
            },
            "reasonCode": {
                "anyOf": [
                    {
                        "type": "string",
                        "enum": [
                            "CAPABILITY_UNAVAILABLE",
                            "OBJECT_SCOPE_MISMATCH",
                            "CONFLICT_OF_INTEREST",
                            "WORKLOAD_CAPACITY",
                            "DEPENDENCY_BLOCKED",
                            "SUBJECT_INVALID",
                            "OWNER_UNAVAILABLE",
                            "POLICY_BLOCKED",
                            "RECEIVER_DECLINED",
                        ],
                    },
                    {"type": "null"},
                ]
            },
        })
    add_contract_schema(request_name, resource_doc, schemas, set())
    contract_schema = resource_doc.get("schemas", {}).get(response_name, {})
    response_fields = contract_schema.get("fields", {})
    schemas[response_name] = {
        "type": "object", "additionalProperties": False,
        "properties": {name: contract_property(str(value), resource_doc, schemas) for name, value in response_fields.items()},
        "required": list(response_fields),
    }
    # The registered query boundary adds the operation identifier to every
    # query envelope so receipts and readbacks remain self-describing. Keep that field in the
    # additive response contract instead of returning a schema-invalid extra.
    if operation["kind"] == "QUERY":
        schemas[response_name]["properties"]["operationId"] = {"type": "string"}
        schemas[response_name]["required"].append("operationId")
        # Query adapters use the same navigable link envelope as the legacy
        # Control API.  Preserve links in the additive contract so the
        # response validator cannot discard destination affordances.
        schemas[response_name]["properties"].setdefault(
            "links", {"type": "array", "items": {"$ref": "#/components/schemas/Link"}}
        )
        if "links" not in schemas[response_name]["required"]:
            schemas[response_name]["required"].append("links")
    add_contract_schema(response_name, resource_doc, schemas, set())
    # add_contract_schema materialises nested references and may replace the
    # top-level response object; reapply the transport envelope fields after
    # that expansion so query adapters remain schema-closed.
    if operation["kind"] == "QUERY":
        schemas[response_name]["properties"]["operationId"] = {"type": "string"}
        schemas[response_name]["properties"].setdefault(
            "links", {"type": "array", "items": {"$ref": "#/components/schemas/Link"}}
        )
        for field in ("operationId", "links"):
            if field not in schemas[response_name]["required"]:
                schemas[response_name]["required"].append(field)
    node = {
        "operationId": operation["operation_id"],
        "summary": operation["operation_id"],
        "tags": ["addendum"],
        "x-operation-kind": operation["kind"],
        "x-capability": operation.get("capability", "none"),
        "x-assurance-level": operation.get("assurance", "ACTIVE_SESSION"),
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
    # GET contracts carry their request shape in the query string.  The
    # previous generator only emitted path parameters, which silently made
    # required detail identifiers (for example appealId) unavailable to the
    # generated clients and caused the runtime to reject an otherwise valid
    # request as INVALID_REQUEST.  Emit both required `fields` and optional
    # filter entries as real OpenAPI query parameters so the wire contract,
    # clients and control-flow witness share one source of truth.
    if operation["method"] == "GET":
        query_parameters = []
        for name in required:
            if name in fields:
                query_parameters.append({
                    "name": name,
                    "in": "query",
                    "required": True,
                    "schema": contract_property(str(fields[name]), resource_doc, schemas),
                })
        for name, expression in request.get("optional", {}).items():
            query_parameters.append({
                "name": name,
                "in": "query",
                "required": False,
                "schema": contract_property(str(expression), resource_doc, schemas),
            })
        if query_parameters:
            node.setdefault("parameters", []).extend(query_parameters)
    node["responses"].update(error_responses(list(operation.get("errors", []))))
    if operation["method"] != "GET":
        node.setdefault("parameters", []).append({"name": "Idempotency-Key", "in": "header", "required": True, "schema": {"type": "string", "minLength": 8, "maxLength": 200}})
        node["requestBody"] = {"required": True, "content": {"application/json": {"schema": {"$ref": f"#/components/schemas/{request_name}"}}}}
    return node


def close_provider_control_side_doors(document: dict) -> None:
    """Keep provider command schemas as form anchors without exposing effects.

    Provider state can change only after a PROVIDER_CONTROL proposal becomes a
    current ExecutionAuthorization.  The historical HTTP operations remain in
    the document solely as closed request/discriminator types and therefore
    have one possible authenticated application response: the no-effect 409.
    """
    expected = set(PROVIDER_CONTROL_OPERATION_IDS)
    found: set[str] = set()
    for path_item in document.get("paths", {}).values():
        if not isinstance(path_item, dict):
            continue
        for node in path_item.values():
            if not isinstance(node, dict):
                continue
            operation_id = node.get("operationId")
            if operation_id not in expected:
                continue
            found.add(operation_id)
            node["x-error-codes"] = ["ACTION_PROPOSAL_REQUIRED"]
            node["x-provider-control-entrypoint"] = "ACTION_PROPOSAL"
            node["x-state-effect"] = "UNCHANGED"
            node["responses"] = {
                "409": {
                    "description": "Provider control requires an approved action proposal",
                    "content": {
                        "application/problem+json": {
                            "schema": {
                                "$ref": "#/components/schemas/AddendumProblemDetailsV1"
                            }
                        }
                    },
                    "x-error-codes": ["ACTION_PROPOSAL_REQUIRED"],
                }
            }
    if found != expected:
        missing = ", ".join(sorted(expected - found))
        extra = ", ".join(sorted(found - expected))
        raise ValueError(
            f"provider control HTTP side-door catalog drifted; missing={missing}; extra={extra}"
        )

    schemas = document.setdefault("components", {}).setdefault("schemas", {})
    connection_request = schemas.get("testProviderConnectionRequest")
    if not isinstance(connection_request, dict):
        raise ValueError("testProviderConnectionRequest schema is missing")
    properties = connection_request.setdefault("properties", {})
    properties["expectedVersion"] = {"type": "integer", "format": "int64", "minimum": 1}
    required = connection_request.setdefault("required", [])
    if "expectedVersion" not in required:
        required.append("expectedVersion")


def merge(api: str, operations: list[dict], resource_doc: dict) -> None:
    yaml_path = ROOT / f"specs/api/{api}.openapi.yaml"
    json_path = ROOT / f"specs/api/{api}.openapi.json"
    generated_path = ROOT / f"specs/generated/{api}.openapi.json"
    document = yaml.safe_load(yaml_path.read_text())
    # Re-running the generator must be idempotent; older runs appended the
    # same tag repeatedly and inflated the source diff on every regeneration.
    document["tags"] = [
        tag for tag in document.get("tags", []) if tag.get("name") != "addendum"
    ] + [{"name": "addendum"}]
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
    # OPS-004 reuses the historical getBudgetOverview operation and returns
    # the closed BudgetOverviewResponse envelope. The registered query boundary
    # stamps operationId on that envelope, so the merged schema must permit the
    # discriminator field as well.
    budget_response = schemas.get("BudgetOverviewResponse")
    if isinstance(budget_response, dict) and isinstance(budget_response.get("properties"), dict):
        budget_response["properties"]["operationId"] = {"type": "string"}
        required = budget_response.setdefault("required", [])
        if "operationId" not in required:
            required.append("operationId")
    business_response = schemas.get("BusinessHealthResponse")
    if isinstance(business_response, dict) and isinstance(business_response.get("properties"), dict):
        business_response["properties"]["operationId"] = {"type": "string"}
        required = business_response.setdefault("required", [])
        if "operationId" not in required:
            required.append("operationId")
    for operation in operations:
        binding = resource_doc["operation_bindings"][operation["operation_id"]]
        path = document.setdefault("paths", {}).setdefault(operation["path"], {})
        node = operation_node(operation, binding, schemas, resource_doc, api == "control-api")
        if operation["operation_id"] == "getBudgetOverview":
            node["responses"][str(binding["success_status"])]["content"][binding["success_media_type"]]["schema"] = {
                "$ref": "#/components/schemas/BudgetOverviewResponse"
            }
        path[operation["method"].lower()] = node
    if api == "control-api":
        legacy_budget = document.get("paths", {}).get("/v1/internal/queries/get-budget-overview", {}).get("get")
        if isinstance(legacy_budget, dict) and "200" in legacy_budget.get("responses", {}):
            legacy_budget["responses"]["200"]["content"]["application/json"]["schema"] = {
                "$ref": "#/components/schemas/BudgetOverviewResponse"
            }
        close_provider_control_side_doors(document)
    # JSON is the generated source consumed by Rust and BFF imports. YAML and
    # JSON are written from the same object so semantic equality is guaranteed.
    json_bytes = json.dumps(document, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    yaml_path.write_text(yaml.safe_dump(document, allow_unicode=True, sort_keys=False))
    json_path.write_text(json_bytes)
    subprocess.run(
        [
            "bunx",
            "biome",
            "format",
            "--write",
            "--no-errors-on-unmatched",
            str(json_path),
        ],
        cwd=ROOT,
        check=True,
    )
    generated_path.write_bytes(json_path.read_bytes())


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
