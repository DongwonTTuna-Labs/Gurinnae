#!/usr/bin/env python3
"""Merge the owner-addendum HTTP operations into the generated API specs.

The addendum operation/resource contracts are the only input; this generator
does not invent routes.  Every generated operation has a closed request
schema, an explicit operation-specific response schema name, the service
assertion security binding and the exact error-code list from the resource
contract.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ADDENDUM = ROOT / "specs/product/addendum-operation-contracts.yaml"
RESOURCES = ROOT / "specs/product/addendum-resource-error-contracts.yaml"
HANDWRITTEN_RESOURCES = ROOT / "specs/api/resource-schemas.yaml"
BASE_ERROR_CATALOG = ROOT / "specs/api/error-code-catalog.yaml"
PROVIDER_CONTROL_OPERATION_IDS = (
    "disableProviderRouting",
    "testProviderConnection",
    "upgradeProviderModel",
    "setModelAutoUpgrade",
)
CONTROL_BASE_SCHEMA_IMPORTS = (
    "LegalHoldTargetBinding",
    "placeLegalHoldRequest",
    "placeLegalHoldReceipt",
)
PUBLIC_BASE_SCHEMA_IMPORTS = (
    "CaseReproducibilityDownloadAppliedFilters",
    "CaseReproducibilityDownload",
)


def direct_contract_expression(expression: str) -> str:
    return expression.split("@", 1)[0].strip()


def generic_argument(expression: str, name: str) -> str | None:
    prefix = f"{name}<"
    if expression.lower().startswith(prefix) and expression.endswith(">"):
        return expression[len(prefix) : -1]
    return None


def required_contract_fields(fields: dict) -> list[str]:
    return [
        name
        for name, expression in fields.items()
        if generic_argument(
            direct_contract_expression(str(expression)), "optional"
        )
        is None
    ]


def const_schema(value: str) -> dict:
    normalized = value.strip()
    if normalized.lower() in {"true", "false"}:
        return {"type": "boolean", "const": normalized.lower() == "true"}
    if re.fullmatch(r"-?(?:0|[1-9]\d*)", normalized):
        return {"type": "integer", "const": int(normalized)}
    return {"type": "string", "const": normalized}


def bounded_string_schema(expression: str) -> dict | None:
    match = re.fullmatch(
        r"(?:secret-)?string\[(\d+)\.\.(\d+|max)\]",
        expression,
        re.IGNORECASE,
    )
    if match is None:
        return None
    schema = {"type": "string", "minLength": int(match.group(1))}
    if match.group(2).lower() != "max":
        schema["maxLength"] = int(match.group(2))
    return schema


def patterned_string_schema(expression: str) -> dict | None:
    match = re.fullmatch(
        r"string-pattern<(.+)>(?:\[(\d+)\.\.(\d+|max)\])?",
        expression,
        re.IGNORECASE,
    )
    if match is None:
        return None
    schema = {"type": "string", "pattern": match.group(1)}
    if match.group(2) is not None:
        schema["minLength"] = int(match.group(2))
    if match.group(3) is not None and match.group(3).lower() != "max":
        schema["maxLength"] = int(match.group(3))
    return schema


def integer_schema(expression: str) -> dict | None:
    match = re.fullmatch(
        r"(int32|int64)(?:\[(-?\d+)\.\.(-?\d+|max)\]|>=(-?\d+))?(?:=(-?\d+))?",
        expression,
        re.IGNORECASE,
    )
    if match is None:
        return None
    schema = {"type": "integer", "format": match.group(1).lower()}
    bracket_minimum = match.group(2)
    minimum = bracket_minimum if bracket_minimum is not None else match.group(4)
    if minimum is not None:
        schema["minimum"] = int(minimum)
    maximum = match.group(3)
    if maximum is not None and maximum.lower() != "max":
        schema["maximum"] = int(maximum)
    default = match.group(5)
    if default is not None:
        schema["default"] = int(default)
    return schema


def enum_schema(expression: str) -> dict | None:
    generic = re.fullmatch(
        r"enum<(.+)>(?:=([^=]+))?",
        expression,
        re.IGNORECASE,
    )
    if generic is not None:
        values = generic.group(1).split("|")
        default = generic.group(2)
    else:
        normalized = expression.lower()
        if "|" not in expression or normalized.startswith(
            ("array<", "unique-array<", "optional<", "nullable<", "const<")
        ):
            return None
        raw_values, separator, raw_default = expression.partition("=")
        values = raw_values.split("|")
        default = raw_default if separator else None
    schema = {"type": "string", "enum": values}
    if default is not None:
        if default not in values:
            raise ValueError(f"enum default is outside the closed set: {expression}")
        schema["default"] = default
    return schema


def array_expression(
    expression: str,
) -> tuple[bool, str, int | None, int | None] | None:
    match = re.fullmatch(
        r"(unique-array|array)<(.+)>(?:\[(\d+)\.\.(\d+|max)\])?",
        expression,
        re.IGNORECASE,
    )
    if match is None:
        return None
    minimum = int(match.group(3)) if match.group(3) is not None else None
    raw_maximum = match.group(4)
    maximum = (
        int(raw_maximum)
        if raw_maximum is not None and raw_maximum.lower() != "max"
        else None
    )
    return match.group(1).lower() == "unique-array", match.group(2), minimum, maximum


def array_schema(
    item_schema: dict,
    *,
    unique: bool,
    minimum: int | None,
    maximum: int | None,
) -> dict:
    schema = {"type": "array", "items": item_schema}
    if minimum is not None:
        schema["minItems"] = minimum
    if maximum is not None:
        schema["maxItems"] = maximum
    if unique:
        schema["uniqueItems"] = True
    return schema


def primitive(expression: str) -> dict:
    direct_expression = direct_contract_expression(expression)
    normalized_expression = direct_expression.lower()
    bounded_uri_reference = re.fullmatch(
        r"uri-reference\[(\d+)\.\.(\d+)\]", direct_expression, re.IGNORECASE
    )
    if bounded_uri_reference:
        return {
            "type": "string",
            "format": "uri-reference",
            "minLength": int(bounded_uri_reference.group(1)),
            "maxLength": int(bounded_uri_reference.group(2)),
        }
    bounded_json_pointer = re.fullmatch(
        r"json-pointer\[(\d+)\.\.(\d+)\]", direct_expression, re.IGNORECASE
    )
    if bounded_json_pointer:
        return {
            "type": "string",
            "format": "json-pointer",
            "minLength": int(bounded_json_pointer.group(1)),
            "maxLength": int(bounded_json_pointer.group(2)),
        }
    bounded_string = bounded_string_schema(direct_expression)
    if bounded_string is not None:
        return bounded_string
    patterned_string = patterned_string_schema(direct_expression)
    if patterned_string is not None:
        return patterned_string
    integer = integer_schema(direct_expression)
    if integer is not None:
        return integer
    enum = enum_schema(direct_expression)
    if enum is not None:
        return enum
    const_value = generic_argument(direct_expression, "const")
    if const_value is not None:
        return const_schema(const_value)
    # The product operation catalog also uses the compact `const value`
    # spelling.  Keep it a literal in OpenAPI; falling through to an empty
    # object makes generic contract fixtures emit `{}` and the owner routine
    # correctly rejects the request as invalid.
    if normalized_expression.startswith("const "):
        return const_schema(direct_expression[len("const ") :])
    if normalized_expression == "enum action_payloads.kinds":
        return {"type": "string", "enum": [
            "HYPOTHESIS", "CLAIM", "TASK", "COMPARABLE", "COMMUNICATION", "PUBLICATION",
            "RETRACTION", "RULE_ACTIVATION", "ROLE_GRANT", "KILL_SWITCH",
            "COMMUNICATION_AUTHORIZATION", "ASSET_RIGHTS_DECISION", "RETENTION_SCHEDULE",
            "FUNDING_DISCLOSURE", "CAPABILITY_ACTIVATION", "RESPONSE_POLICY_CALENDAR",
            "COMMERCIAL_CONTROL", "PROVIDER_CONTROL",
        ]}
    optional_value = generic_argument(direct_expression, "optional")
    if optional_value is not None:
        return primitive(optional_value)
    nullable_value = generic_argument(direct_expression, "nullable")
    if nullable_value is not None:
        return {"anyOf": [primitive(nullable_value), {"type": "null"}]}
    collection = array_expression(direct_expression)
    if collection is not None:
        unique, item_expression, minimum, maximum = collection
        return array_schema(
            primitive(item_expression),
            unique=unique,
            minimum=minimum,
            maximum=maximum,
        )
    if "boolean" in normalized_expression:
        return {"type": "boolean"}
    if "int" in normalized_expression or "decimal" in normalized_expression:
        return {"type": "integer", "format": "int64"}
    if "datetime" in normalized_expression:
        return {"type": "string", "format": "date-time"}
    if "date" in normalized_expression:
        return {"type": "string", "format": "date"}
    if "uuid" in normalized_expression:
        return {"type": "string", "format": "uuid"}
    if normalized_expression.startswith(
        "uri-reference"
    ) or normalized_expression.startswith("uri"):
        return {"type": "string", "format": "uri-reference"}
    if "sha256" in normalized_expression or "digest" in normalized_expression:
        return {"type": "string", "pattern": "^[0-9a-f]{64}$"}
    if normalized_expression in {"nonempty_string", "secret-nonempty-string"}:
        return {"type": "string", "minLength": 1}
    if normalized_expression == "cursor":
        return {"type": "string"}
    if normalized_expression.startswith("string") or "secret" in normalized_expression:
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
                "required": list(
                    contract.get("required", required_contract_fields(fields))
                ),
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
                selected_required = required_contract_fields(variant_fields)
            required = list(
                dict.fromkeys(
                    [*required_contract_fields(common), *selected_required]
                )
            )
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
        "required": required_contract_fields(fields),
    }
    for value in fields.values():
        for child in referenced_names(str(value), known):
            add_contract_schema(child, resource_doc, schemas, seen)


def contract_property(expression: str, resource_doc: dict, schemas: dict) -> dict:
    known = set(resource_doc.get("schemas", {})) | set(schemas)
    direct = direct_contract_expression(expression)
    if direct in known:
        add_contract_schema(direct, resource_doc, schemas, set())
        return {"$ref": f"#/components/schemas/{direct}"}
    optional_value = generic_argument(direct, "optional")
    if optional_value is not None:
        return contract_property(optional_value, resource_doc, schemas)
    nullable_value = generic_argument(direct, "nullable")
    if nullable_value is not None:
        return {
            "anyOf": [
                contract_property(nullable_value, resource_doc, schemas),
                {"type": "null"},
            ]
        }
    shorthand = re.fullmatch(r"nullable-(.+)", direct)
    if shorthand:
        inner = shorthand.group(1)
        return {"anyOf": [primitive(inner), {"type": "null"}]}
    collection = array_expression(direct)
    if collection is not None and collection[1] in known:
        unique, child, minimum, maximum = collection
        add_contract_schema(child, resource_doc, schemas, set())
        return array_schema(
            {"$ref": f"#/components/schemas/{child}"},
            unique=unique,
            minimum=minimum,
            maximum=maximum,
        )
    return primitive(expression)


def error_responses(codes: list[str], resource_doc: dict) -> dict:
    grouped: dict[str, list[str]] = {}
    base_catalog = yaml.safe_load(BASE_ERROR_CATALOG.read_text()).get("errors", [])
    status_by_code = {
        row["code"]: str(row["http_status"])
        for row in base_catalog
        if isinstance(row, dict) and isinstance(row.get("code"), str)
    }
    status_by_code.update({
        code: str(contract["http_status"])
        for code, contract in resource_doc.get("error_catalog_additions", {}).items()
    })
    for code in codes:
        status = status_by_code.get(code)
        if status is None:
            raise ValueError(f"uncataloged additive error code: {code}")
        grouped.setdefault(status, []).append(code)
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
    schemas[request_name] = {
        "type": "object",
        "additionalProperties": False,
        **(
            {"description": request["description"]}
            if request.get("description")
            else {}
        ),
        "properties": {
            name: contract_property(str(value), resource_doc, schemas)
            for name, value in fields.items()
        },
        "required": required,
    }
    field_descriptions = request.get("field_descriptions", {})
    unknown_descriptions = set(field_descriptions) - set(fields)
    if unknown_descriptions:
        raise ValueError(
            f"{operation['operation_id']} describes unknown request fields: "
            + ", ".join(sorted(unknown_descriptions))
        )
    for field_name, description in field_descriptions.items():
        schemas[request_name]["properties"][field_name]["description"] = description
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
        "required": required_contract_fields(response_fields),
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
        **(
            {"description": operation["description"]}
            if operation.get("description")
            else {}
        ),
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
    node["responses"].update(error_responses(list(operation.get("errors", [])), resource_doc))
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


def import_control_base_operation_extensions(document: dict) -> None:
    """Project the authoritative handwritten schema for extended base operations.

    Additive operations are rebuilt from the owner addendum below.  A base
    operation remains in the original OpenAPI path table, so its replacement
    request union must be copied explicitly instead of leaving the historical
    case-shaped component in generated clients.
    """

    resource_document = yaml.safe_load(HANDWRITTEN_RESOURCES.read_text())
    resource_schemas = resource_document.get("resources", {})
    schemas = document.setdefault("components", {}).setdefault("schemas", {})
    for name in CONTROL_BASE_SCHEMA_IMPORTS:
        entry = resource_schemas.get(name)
        if not isinstance(entry, dict) or not isinstance(entry.get("schema"), dict):
            raise ValueError(f"handwritten resource schema is missing: {name}")
        if "control-api" not in entry.get("apis", []):
            raise ValueError(f"handwritten resource schema is not control-api bound: {name}")
        schemas[name] = copy.deepcopy(entry["schema"])

    operation = (
        document.get("paths", {})
        .get("/v1/internal/commands/place-legal-hold", {})
        .get("post")
    )
    if not isinstance(operation, dict) or operation.get("operationId") != "placeLegalHold":
        raise ValueError("base placeLegalHold OpenAPI operation is missing")
    operation["description"] = (
        "Places a retention, deletion or disclosure hold on one exact "
        "versioned target from the closed thirteen-kind legal-hold union."
    )


def import_public_base_operation_extensions(document: dict) -> None:
    """Project the closed reproducibility download contract into Public OpenAPI."""

    resource_document = yaml.safe_load(HANDWRITTEN_RESOURCES.read_text())
    resource_schemas = resource_document.get("resources", {})
    schemas = document.setdefault("components", {}).setdefault("schemas", {})
    for name in PUBLIC_BASE_SCHEMA_IMPORTS:
        entry = resource_schemas.get(name)
        if not isinstance(entry, dict) or not isinstance(entry.get("schema"), dict):
            raise ValueError(f"handwritten resource schema is missing: {name}")
        if "public-api" not in entry.get("apis", []):
            raise ValueError(f"handwritten resource schema is not public-api bound: {name}")
        schemas[name] = copy.deepcopy(entry["schema"])

    operation = (
        document.get("paths", {})
        .get("/v1/cases/{caseSlug}/reproducibility/download", {})
        .get("get")
    )
    if not isinstance(operation, dict) or operation.get("operationId") != "downloadCaseReproducibility":
        raise ValueError("base downloadCaseReproducibility OpenAPI operation is missing")
    operation["description"] = (
        "공개 재배포 산출물입니다. JSON 파일 본문은 재배포 고지와 상태별 비확정 문구를 "
        "최상위에 포함하고, CSV 파일 본문은 재배포 고지 한 셀 행과 비확정 문구 열을 보존합니다."
    )
    operation["responses"]["200"]["content"]["application/json"]["schema"] = {
        "$ref": "#/components/schemas/CaseReproducibilityDownload"
    }


def merge(
    api: str, operations: list[dict], resource_doc: dict, *, check: bool
) -> list[Path]:
    yaml_path = ROOT / f"specs/api/{api}.openapi.yaml"
    json_path = ROOT / f"specs/api/{api}.openapi.json"
    generated_path = ROOT / f"specs/generated/{api}.openapi.json"
    document = yaml.safe_load(yaml_path.read_text())
    if api == "control-api":
        import_control_base_operation_extensions(document)
    elif api == "public-api":
        import_public_base_operation_extensions(document)
    # Re-running the generator must be idempotent; older runs appended the
    # same tag repeatedly and inflated the source diff on every regeneration.
    document["tags"] = [
        tag for tag in document.get("tags", []) if tag.get("name") != "addendum"
    ] + ([{"name": "addendum"}] if operations else [])
    schemas = document.setdefault("components", {}).setdefault("schemas", {})
    if operations:
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
    if check:
        failures: list[Path] = []
        if yaml.safe_load(yaml_path.read_text()) != document:
            failures.append(yaml_path)
        for path in (json_path, generated_path):
            if not path.is_file() or json.loads(path.read_text()) != document:
                failures.append(path)
        return failures
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
    return []


def write_identity(
    operations: list[dict], resource_doc: dict, *, check: bool
) -> list[Path]:
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
    failures: list[Path] = []
    for suffix in ("api", "generated"):
        path = ROOT / f"specs/{suffix}/identity-api.openapi.{'yaml' if suffix == 'api' else 'json'}"
        payload = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
        if check:
            current = yaml.safe_load(path.read_text()) if path.is_file() else None
            if current != document:
                failures.append(path)
        elif suffix == "api":
            path.write_text(yaml.safe_dump(document, allow_unicode=True, sort_keys=False))
        else:
            path.write_text(payload)
    return failures


def sync_internal_identity(*, check: bool = False) -> list[Path]:
    """Materialise the authoritative private Identity YAML as JSON.

    The addendum does not own the nine private operations, but R6d extends
    their request-bound capability contract. Keeping this projection in the
    same source generator prevents the handwritten YAML and both JSON
    consumers from drifting after an additive contract change.
    """

    yaml_path = ROOT / "specs/api/identity-service-internal.openapi.yaml"
    json_path = ROOT / "specs/api/identity-service-internal.openapi.json"
    generated_path = ROOT / "specs/generated/identity-service-internal.openapi.json"
    document = yaml.safe_load(yaml_path.read_text())
    if check:
        failures: list[Path] = []
        for path in (json_path, generated_path):
            if not path.is_file() or json.loads(path.read_text()) != document:
                failures.append(path)
        return failures
    json_path.write_text(
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    )
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
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check", action="store_true", help="fail without writing when projections differ"
    )
    args = parser.parse_args()
    operations = yaml.safe_load(ADDENDUM.read_text())["operations"]
    resource_doc = yaml.safe_load(RESOURCES.read_text())
    grouped = {
        "public-api": [],
        "control-api": [row for row in operations if row["api"] == "control-api"],
        "submission-api": [row for row in operations if row["api"] == "submission-api"],
    }
    failures: list[Path] = []
    for api, rows in grouped.items():
        failures.extend(merge(api, rows, resource_doc, check=args.check))
    failures.extend(
        write_identity(
            [row for row in operations if row.get("api") == "identity-api"],
            resource_doc,
            check=args.check,
        )
    )
    failures.extend(sync_internal_identity(check=args.check))
    if failures:
        print("generated OpenAPI projections differ:")
        for path in failures:
            print(f"- {path.relative_to(ROOT)}")
        return 1
    if args.check:
        print(
            "generated OpenAPI projections: PASS "
            f"additive_operations={sum(map(len, grouped.values()))}"
        )
    else:
        print(f"merged {sum(map(len, grouped.values()))} additive operations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
