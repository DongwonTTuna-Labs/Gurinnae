#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import copy
import datetime as dt
import hashlib
import json
import re
from pathlib import Path
from typing import Any
from urllib.parse import urljoin

import yaml
from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
PARSER_ADDENDUM = REPO / "specs/parsers/addendum-multimodal.yaml"
ACCEPTANCE = REPO / "tests/acceptance/ai-multimodal-addendum.feature"
DATABASE_ADDENDUM = REPO / "specs/database/addendum/0025-evidence-snapshots-search.yaml"
COMMUNICATION_ADDENDUM = REPO / "specs/database/addendum/0027-communication-consent-delivery.yaml"
HYPOTHESIS_RECURSION = REPO / "specs/agents/hypothesis-recursion-policy.yaml"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
UUID = "00000000-0000-4000-8000-000000000001"
UUID_2 = "00000000-0000-4000-8000-000000000002"
NOW = "2026-07-15T00:00:00Z"


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_yaml(path: Path) -> dict[str, Any]:
    value = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path}: YAML root is not an object")
    return value


def json_pointer(document: Any, pointer: str) -> Any:
    if pointer in ("", "#"):
        return document
    value = pointer[1:] if pointer.startswith("#") else pointer
    if not value.startswith("/"):
        raise ValueError(f"invalid JSON pointer {pointer}")
    current = document
    for raw in value[1:].split("/"):
        token = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(current, list):
            current = current[int(token)]
        elif isinstance(current, dict):
            current = current[token]
        else:
            raise KeyError(pointer)
    return current


def walk(value: Any, path: str = ""):
    yield path, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk(child, f"{path}/{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(child, f"{path}/{index}")


def indexed_schema_paths(index: dict[str, Any]) -> list[Path]:
    relative: list[str] = []
    relative.extend(item["path"] for item in index["runtime_schemas"])
    relative.extend(item["path"] for item in index["view_model_schemas"])
    for tool in index["tool_schemas"]:
        relative.extend([tool["request"], tool["response"]])
    return [ROOT / item for item in relative]


def database_schema_pin_errors(
    index: dict[str, Any],
    database_contract: dict[str, Any],
    content_overrides: dict[str, bytes] | None = None,
) -> list[str]:
    errors: list[str] = []
    overrides = content_overrides or {}
    try:
        registry = database_contract["closed_type_contracts"][
            "normative_json_schema_registry"
        ]
        runtime_registry = registry["runtime"]
        tool_registry = registry["tools"]
    except (KeyError, TypeError) as error:
        return [f"database schema pin registry is missing: {error}"]
    if not isinstance(runtime_registry, dict) or not isinstance(tool_registry, dict):
        return ["database schema pin registry runtime/tools must be mappings"]

    runtime_index = {
        item["type"]: f"specs/agents/addendum-v2/{item['path']}"
        for item in index.get("runtime_schemas", [])
    }
    tool_index = {
        item["id"]: {
            "request_path": f"specs/agents/addendum-v2/{item['request']}",
            "response_path": f"specs/agents/addendum-v2/{item['response']}",
        }
        for item in index.get("tool_schemas", [])
    }
    if set(runtime_registry) != set(runtime_index):
        errors.append(
            "database runtime schema pins are not set-equal to schema-index runtime schemas"
        )
    if set(tool_registry) != set(tool_index):
        errors.append(
            "database tool schema pins are not set-equal to schema-index tool schemas"
        )

    def actual_sha256(relative: str) -> str:
        content = overrides.get(relative)
        if content is None:
            content = (REPO / relative).read_bytes()
        return hashlib.sha256(content).hexdigest()

    for type_name in sorted(set(runtime_registry) & set(runtime_index)):
        row = runtime_registry[type_name]
        if not isinstance(row, dict):
            errors.append(f"{type_name}: database runtime schema pin is not a mapping")
            continue
        expected_path = runtime_index[type_name]
        if set(row) != {"path", "sha256"}:
            errors.append(f"{type_name}: database runtime schema pin fields are not exact")
        if row.get("path") != expected_path:
            errors.append(f"{type_name}: database runtime schema path differs from schema-index")
            continue
        digest = row.get("sha256")
        if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
            errors.append(f"{type_name}: database runtime schema digest is not lowercase SHA-256")
        elif digest != actual_sha256(expected_path):
            errors.append(f"{type_name}: database runtime schema digest differs from exact bytes")

    for tool_id in sorted(set(tool_registry) & set(tool_index)):
        row = tool_registry[tool_id]
        if not isinstance(row, dict):
            errors.append(f"{tool_id}: database tool schema pin is not a mapping")
            continue
        expected = tool_index[tool_id]
        exact_keys = {
            "request_path",
            "request_sha256",
            "response_path",
            "response_sha256",
        }
        if set(row) != exact_keys:
            errors.append(f"{tool_id}: database tool schema pin fields are not exact")
        for direction in ("request", "response"):
            path_key = f"{direction}_path"
            digest_key = f"{direction}_sha256"
            expected_path = expected[path_key]
            if row.get(path_key) != expected_path:
                errors.append(
                    f"{tool_id}: database {direction} schema path differs from schema-index"
                )
                continue
            digest = row.get(digest_key)
            if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
                errors.append(
                    f"{tool_id}: database {direction} schema digest is not lowercase SHA-256"
                )
            elif digest != actual_sha256(expected_path):
                errors.append(
                    f"{tool_id}: database {direction} schema digest differs from exact bytes"
                )
    return errors


def runtime_reference_errors(
    authority: dict[str, Any],
    runtime: dict[str, Any],
    index: dict[str, Any],
    database_contract: dict[str, Any],
    schemas: dict[Path, dict[str, Any]],
) -> list[str]:
    """Validate every cross-document runtime pointer and closed field mapping."""

    errors: list[str] = []
    expected_agent_ids = authority.get("scope", {}).get("agents", {}).get("exact_ids", [])
    rows = runtime.get("effective_agent_dispatch_registry", {}).get("rows", [])
    row_by_id = {
        row.get("agent_id"): row
        for row in rows
        if isinstance(row, dict) and isinstance(row.get("agent_id"), str)
    }
    if (
        not isinstance(expected_agent_ids, list)
        or len(row_by_id) != len(rows)
        or list(row_by_id) != expected_agent_ids
    ):
        errors.append("runtime agent rows are not order/set-equal to authority exact agents")

    base_catalog = load_yaml(REPO / "specs/agents/agent-catalog.yaml")
    base_by_id = {row["id"]: row for row in base_catalog.get("agents", [])}
    runtime_schema_index = {
        row["type"]: (ROOT / row["path"]).resolve()
        for row in index.get("runtime_schemas", [])
        if isinstance(row, dict) and isinstance(row.get("type"), str)
    }
    expected_proposal_kinds = {
        "market-researcher": ["COMPARABLE"],
        "investigator": ["HYPOTHESIS", "TASK"],
        "skeptic": [],
        "claim-drafter": ["CLAIM", "COMMUNICATION"],
        "citation-verifier": [],
    }
    for agent_id in expected_agent_ids if isinstance(expected_agent_ids, list) else []:
        row = row_by_id.get(agent_id)
        base = base_by_id.get(agent_id)
        if not isinstance(row, dict) or not isinstance(base, dict):
            errors.append(f"{agent_id}: missing runtime or base catalog row")
            continue
        prompt = row.get("prompt")
        output = row.get("output")
        bounds = row.get("bounds")
        if not isinstance(prompt, dict) or not isinstance(output, dict) or not isinstance(bounds, dict):
            errors.append(f"{agent_id}: prompt/output/bounds must be closed mappings")
            continue
        prompt_path_value = prompt.get("path")
        prompt_path = REPO / str(prompt_path_value)
        if not prompt_path.is_file():
            errors.append(f"{agent_id}: prompt path is missing: {prompt_path_value}")
        elif prompt.get("sha256") != hashlib.sha256(prompt_path.read_bytes()).hexdigest():
            errors.append(f"{agent_id}: prompt SHA-256 differs from exact bytes")
        output_type = output.get("type")
        output_path_value = output.get("path")
        output_path = REPO / str(output_path_value)
        if runtime_schema_index.get(output_type) != output_path.resolve():
            errors.append(f"{agent_id}: output type/path is not indexed as one runtime schema")
        schema = schemas.get(output_path.resolve())
        if schema is None:
            errors.append(f"{agent_id}: output schema is missing or invalid")
        else:
            version = schema.get("properties", {}).get("schemaVersion", {}).get("const")
            if schema.get("title") != output_type or version != output.get("schema_version"):
                errors.append(f"{agent_id}: output type/title/schemaVersion differ")
        if row.get("allowed_tools") != base.get("tools"):
            errors.append(f"{agent_id}: runtime allowed tools differ from base catalog")
        if agent_id in {"market-researcher", "investigator"} and isinstance(schema, dict):
            output_tool_ids = (
                schema.get("$defs", {})
                .get("investigation", {})
                .get("properties", {})
                .get("toolId", {})
                .get("enum")
            )
            if output_tool_ids != row.get("allowed_tools"):
                errors.append(f"{agent_id}: output tool allowlist differs from dispatch registry")
        if row.get("allowed_proposal_kinds") != expected_proposal_kinds.get(agent_id):
            errors.append(f"{agent_id}: allowed proposal kinds differ from the closed agent policy")
        if (
            bounds.get("max_provider_turns") != base.get("max_iterations")
            or bounds.get("max_tool_calls") != base.get("max_iterations") - 1
            or bounds.get("max_micros_krw") != base.get("max_cost_krw") * 1_000_000
        ):
            errors.append(f"{agent_id}: runtime bounds differ from the base catalog")
    proposal_union = {
        kind
        for row in rows
        if isinstance(row, dict)
        for kind in row.get("allowed_proposal_kinds", [])
    }
    if proposal_union != {"HYPOTHESIS", "CLAIM", "TASK", "COMPARABLE", "COMMUNICATION"}:
        errors.append("agent allowed proposal-kind union is not exact")

    expected_tool_ids = authority.get("scope", {}).get("tools", {}).get("exact_ids", [])
    expected_tool_count = authority.get("scope", {}).get("tools", {}).get("count")
    indexed_tool_ids = [row.get("id") for row in index.get("tool_schemas", [])]
    base_tool_catalog = load_yaml(REPO / "specs/agents/tool-catalog.yaml")
    catalog_rows = base_tool_catalog.get("tools", [])
    catalog_tool_ids = [row.get("id") for row in catalog_rows if isinstance(row, dict)]
    adapter_rows = runtime.get("effective_tool_adapter_registry", {}).get("rows", [])
    adapter_tool_ids = [row.get("tool_id") for row in adapter_rows if isinstance(row, dict)]
    tool_call_schema = schemas.get((ROOT / "schemas/tool-call.schema.json").resolve(), {})
    tool_call_ids = tool_call_schema.get("properties", {}).get("toolId", {}).get("enum", [])
    tool_branch_ids = [
        branch.get("if", {}).get("properties", {}).get("toolId", {}).get("const")
        for branch in tool_call_schema.get("allOf", [])
        if isinstance(branch, dict)
        and isinstance(
            branch.get("if", {}).get("properties", {}).get("toolId", {}).get("const"),
            str,
        )
        and "request" in branch.get("then", {}).get("properties", {})
    ]
    provider_schema = schemas.get((ROOT / "schemas/provider-turn.schema.json").resolve(), {})
    provider_tool_call = next(
        (
            branch
            for branch in provider_schema.get("properties", {})
            .get("envelope", {})
            .get("oneOf", [])
            if isinstance(branch, dict)
            and branch.get("properties", {}).get("kind", {}).get("const") == "TOOL_CALL"
        ),
        {},
    )
    provider_tool_ids = (
        provider_tool_call.get("properties", {}).get("toolId", {}).get("enum", [])
    )
    language_contract = runtime.get("effective_tool_adapter_registry", {}).get(
        "language_policy_contract", {}
    )
    expected_language_version = "ko-public-claims-v1"
    expected_language_sha256 = (
        "6766a275b7d9a3ef0157bbd42d57245f8309f3ec15f2ee6cd515d6397ee4bc4e"
    )
    expected_language_families = [
        "UNSUPPORTED_CERTAINTY",
        "CRIME_OR_CORRUPTION_ASSERTION",
        "NO_RESPONSE_AS_ADMISSION",
        "CORRUPTION_RANKING",
    ]
    claim_request_schema = schemas.get(
        (ROOT / "tools/claim-language-check.request.schema.json").resolve(), {}
    )
    claim_request_properties = claim_request_schema.get("properties", {})
    if (
        language_contract.get("version") != expected_language_version
        or language_contract.get("sha256") != expected_language_sha256
        or language_contract.get("required_pattern_families")
        != expected_language_families
        or claim_request_properties.get("languagePolicyVersion", {}).get("const")
        != expected_language_version
        or claim_request_properties.get("languagePolicySha256", {}).get("const")
        != expected_language_sha256
    ):
        errors.append("claim.language_check versioned policy binding is not exact")
    registries = {
        "schema index": indexed_tool_ids,
        "base catalog": catalog_tool_ids,
        "runtime adapter": adapter_tool_ids,
        "ToolCallV2 enum": tool_call_ids,
        "ToolCallV2 schema branches": tool_branch_ids,
        "ProviderTurnV2 enum": provider_tool_ids,
    }
    if (
        not isinstance(expected_tool_ids, list)
        or expected_tool_count != 13
        or len(expected_tool_ids) != 13
        or len(set(expected_tool_ids)) != 13
    ):
        errors.append("authority tool registry is not exactly 13 unique tools")
    else:
        expected_tool_set = set(expected_tool_ids)
        for label, tool_ids in registries.items():
            if (
                len(tool_ids) != 13
                or len(set(tool_ids)) != 13
                or set(tool_ids) != expected_tool_set
            ):
                errors.append(f"{label} is not set-equal to the 13-tool authority")
        for row in catalog_rows if isinstance(catalog_rows, list) else []:
            if not isinstance(row, dict):
                continue
            for field in ("request_schema", "response_schema"):
                relative = row.get(field)
                if not isinstance(relative, str) or not (
                    REPO / "specs/agents" / relative
                ).is_file():
                    errors.append(f"{row.get('id')}: {field} does not resolve to a schema")
    expected_target_mapping = dict.fromkeys(
        ("HYPOTHESIS", "CLAIM", "TASK", "COMPARABLE", "COMMUNICATION"),
        "ACTION_PROPOSAL_DRAFT",
    )
    output_materialization = runtime.get("output_materialization", {})
    if output_materialization.get("target_mapping") != expected_target_mapping:
        errors.append("all five agent proposal kinds must map only to ACTION_PROPOSAL_DRAFT")

    communication_schema_id = (
        "https://gurinnae.invalid/schemas/agents/v2/communication-proposal-payload.json"
    )
    communication_path = (ROOT / "schemas/communication-proposal-payload.schema.json").resolve()
    claim_path = (ROOT / "schemas/claim-draft-output.schema.json").resolve()
    proposal_path = (ROOT / "schemas/agent-proposal.schema.json").resolve()
    communication_schema = schemas.get(communication_path, {})
    claim_schema = schemas.get(claim_path, {})
    proposal_schema = schemas.get(proposal_path, {})
    claim_ref = (
        claim_schema.get("$defs", {})
        .get("communicationDraft", {})
        .get("properties", {})
        .get("payload", {})
        .get("$ref")
    )
    proposal_ref = (
        proposal_schema.get("$defs", {}).get("communication", {}).get("$ref")
    )
    if (
        communication_schema.get("$id") != communication_schema_id
        or claim_ref != communication_schema_id
        or proposal_ref != communication_schema_id
    ):
        errors.append("claim output and AgentProposal do not share one communication payload schema")
    communication_contract = load_yaml(COMMUNICATION_ADDENDUM)
    closed_types = communication_contract.get("closed_types", {})
    properties = communication_schema.get("properties", {})
    if properties.get("channel", {}).get("enum") != closed_types.get(
        "ops.communication_channel"
    ):
        errors.append("communication proposal channels differ from the 0027 closed type")
    if properties.get("purpose", {}).get("enum") != closed_types.get(
        "ops.communication_purpose"
    ):
        errors.append("communication proposal purposes differ from the 0027 closed type")
    recipient = properties.get("recipientBinding", {})
    if recipient.get("required") != [
        "subjectId",
        "endpointId",
        "endpointVersion",
        "endpointDigest",
    ]:
        errors.append("communication proposal recipient revision binding is not exact")

    network_contract = load_yaml(ROOT / "network-provider.yaml")
    discovery_registry = network_contract.get(
        "search_discovery_provider_registry", {}
    )
    providers = discovery_registry.get("providers", [])
    if (
        discovery_registry.get("exact_count") != 1
        or discovery_registry.get("default_provider_id")
        != "BRAVE_SEARCH_WEB_V1"
        or discovery_registry.get("no_generic_fallback") is not True
        or not isinstance(providers, list)
        or len(providers) != 1
    ):
        errors.append("search discovery registry is not the exact concrete provider set")
    else:
        provider = providers[0]
        protocol = provider.get("protocol", {})
        activation = provider.get("activation", {})
        if (
            provider.get("provider_id") != "BRAVE_SEARCH_WEB_V1"
            or provider.get("adapter_id") != "BraveSearchWebAdapterV1"
            or provider.get("adapter_version") != 1
            or protocol.get("method") != "GET"
            or protocol.get("origin") != "https://api.search.brave.com"
            or protocol.get("path") != "/res/v1/web/search"
            or activation.get("initial_state") != "UNCONFIGURED"
        ):
            errors.append("concrete search provider protocol or activation drifted")
    source_fetch_response_path = (
        ROOT / "tools/source-fetch.response.schema.json"
    ).resolve()
    source_fetch_response = schemas.get(source_fetch_response_path, {})
    discovery_receipt = (
        source_fetch_response.get("properties", {})
        .get("discoveryReceipt", {})
        .get("oneOf", [])
    )
    receipt_object = next(
        (
            branch
            for branch in discovery_receipt
            if isinstance(branch, dict) and branch.get("type") == "object"
        ),
        {},
    )
    receipt_properties = receipt_object.get("properties", {})
    if (
        receipt_properties.get("providerId", {}).get("const")
        != "BRAVE_SEARCH_WEB_V1"
        or receipt_properties.get("adapterVersion", {}).get("const") != 1
        or receipt_properties.get("usageRequests", {}).get("const") != 1
        or "receiptSha256" not in receipt_object.get("required", [])
    ):
        errors.append("source.fetch discovery receipt does not bind the concrete provider")

    authority_operations = authority.get("effective_registry_contract", {}).get("operations", [])
    expected_operations = {
        "promoteResearchArtifactToEvidence",
        "cancelAgentRun",
        "reconcileAgentRun",
    }
    actual_operations = {
        row.get("operation_id") for row in authority_operations if isinstance(row, dict)
    }
    if actual_operations != expected_operations or len(authority_operations) != 3:
        errors.append("agent authority operation registry is not the exact three-operation set")
    request_types = runtime.get("cancellation_and_reconciliation", {}).get("request_types", {})
    for row in authority_operations if isinstance(authority_operations, list) else []:
        if not isinstance(row, dict):
            continue
        response = row.get("response_schema")
        if isinstance(response, str) and not (ROOT / response).is_file():
            errors.append(f"{row.get('operation_id')}: response schema path is missing")
        request = row.get("request_schema")
        if isinstance(request, str) and request.startswith("schemas/"):
            if not (ROOT / request).is_file():
                errors.append(f"{row.get('operation_id')}: request schema path is missing")
        elif isinstance(request, str):
            type_name = next(
                (name for name in request_types if isinstance(name, str) and name in request),
                None,
            )
            if type_name is None:
                errors.append(f"{row.get('operation_id')}: inline request type does not resolve")

    expected_projections = {
        "ProviderReceiptV2": "receiptSha256",
        "ResearchArtifactV2": "artifactSha256",
        "SourceUseV2": "sourceUseSha256",
        "CitationV2": "citationSha256",
        "OutputValidationV2": "validationSha256",
        "PromoteResearchArtifactReceiptV1": "receiptSha256",
        "AgentRunControlReceiptV2": "receiptSha256",
        "AgentReconciliationEvidenceV1": "evidenceSha256",
        "ProvenanceGraphV2": "graphSha256",
    }
    projections = index.get("identity_digest_projections", {}).get("projections", {})
    if projections != expected_projections:
        errors.append("identity digest projection registry is not exact")
    indexed_types = {
        row["type"]: (ROOT / row["path"]).resolve()
        for section in ("runtime_schemas", "view_model_schemas")
        for row in index.get(section, [])
        if isinstance(row, dict) and isinstance(row.get("type"), str)
    }
    for type_name, identity_field in expected_projections.items():
        path = indexed_types.get(type_name)
        schema = schemas.get(path) if path is not None else None
        projection = schema.get("x-gurinnae-digest-projection") if isinstance(schema, dict) else None
        if (
            not isinstance(schema, dict)
            or identity_field not in schema.get("properties", {})
            or not isinstance(projection, dict)
            or projection.get("excludedRootFields") != [identity_field]
        ):
            errors.append(f"{type_name}: self-digest projection is missing or inconsistent")

    tables = database_contract.get("tables", [])
    table_by_relation = {
        row.get("relation"): row
        for row in tables
        if isinstance(row, dict) and isinstance(row.get("relation"), str)
    }
    control_columns = set(table_by_relation.get("ops.agent_run_control_receipts", {}).get("columns", {}))
    expected_control_columns = {
        "receipt_id",
        "receipt_contract_version",
        "agent_run_id",
        "aggregate_version",
        "prior_status",
        "prior_control_state",
        "next_status",
        "next_control_state",
        "affected_provider_turn_id",
        "affected_tool_call_id",
        "reconciliation_evidence_id",
        "reconciliation_evidence_sha256",
        "proof_kind",
        "proof_sha256",
        "budget_disposition",
        "budget_resolution_set_sha256",
        "actor_kind",
        "actor_id",
        "reason_code",
        "reason_sha256",
        "prior_receipt_id",
        "prior_receipt_sha256",
        "command_operation_id",
        "command_expected_run_version",
        "command_idempotency_key_sha256",
        "command_request_sha256",
        "audit_event_id",
        "occurred_at",
        "receipt_canonical",
        "receipt_sha256",
        "created_at",
    }
    if control_columns != expected_control_columns:
        errors.append("AgentRunControlReceiptV2 physical column mapping is not exact")
    reconciliation_columns = set(
        table_by_relation.get("ops.agent_reconciliation_evidence", {}).get("columns", {})
    )
    expected_reconciliation_columns = {
        "evidence_id",
        "evidence_contract_version",
        "agent_run_id",
        "provider_turn_id",
        "tool_call_id",
        "evidence_kind",
        "source_proof_kind",
        "adapter_id",
        "adapter_version",
        "adapter_configuration_sha256",
        "lookup_request_sha256",
        "lookup_idempotency_key_sha256",
        "caller_assertion_sha256",
        "provider_receipt_id",
        "provider_receipt_sha256",
        "tool_terminal_sha256",
        "resolution",
        "budget_disposition",
        "observed_at",
        "evidence_canonical",
        "evidence_sha256",
        "created_at",
    }
    if reconciliation_columns != expected_reconciliation_columns:
        errors.append("AgentReconciliationEvidenceV1 physical column mapping is not exact")
    return errors


def schema_pin_self_test() -> tuple[bool, list[dict[str, object]]]:
    index = load_yaml(ROOT / "schema-index.yaml")
    database_contract = load_yaml(DATABASE_ADDENDUM)
    registry = database_contract["closed_type_contracts"][
        "normative_json_schema_registry"
    ]
    fixtures: list[dict[str, object]] = []

    def record(name: str, candidate: dict[str, Any], overrides: dict[str, bytes] | None = None) -> None:
        detected = bool(database_schema_pin_errors(index, candidate, overrides))
        fixtures.append({"fixture": name, "corruption_rejected": detected})

    baseline_errors = database_schema_pin_errors(index, database_contract)
    fixtures.append(
        {"fixture": "current-exact-registry", "corruption_rejected": not baseline_errors}
    )

    bad_digest = copy.deepcopy(database_contract)
    bad_digest["closed_type_contracts"]["normative_json_schema_registry"]["runtime"]["AgentRunV2"]["sha256"] = "0" * 64
    record("changed-pin", bad_digest)

    missing_schema = copy.deepcopy(database_contract)
    missing_schema["closed_type_contracts"]["normative_json_schema_registry"]["runtime"].pop("AgentRunV2")
    record("missing-schema", missing_schema)

    extra_schema = copy.deepcopy(database_contract)
    extra_schema["closed_type_contracts"]["normative_json_schema_registry"]["tools"]["unexpected.tool"] = copy.deepcopy(registry["tools"]["source.fetch"])
    record("additional-schema", extra_schema)

    schema_path = registry["runtime"]["AgentRunV2"]["path"]
    mutated_bytes = (REPO / schema_path).read_bytes() + b"\n"
    record("one-byte-schema-drift", database_contract, {schema_path: mutated_bytes})

    malformed_digest = copy.deepcopy(database_contract)
    malformed_digest["closed_type_contracts"]["normative_json_schema_registry"]["tools"]["source.locator_verify"]["request_sha256"] = "f" * 63
    record("non-sha256-pin", malformed_digest)

    authority = load_yaml(ROOT / "authority.yaml")
    runtime = load_yaml(ROOT / "runtime-contracts.yaml")
    schemas = {
        path.resolve(): load_json(path)
        for path in ROOT.rglob("*.json")
    }

    def record_runtime(
        name: str,
        *,
        candidate_runtime: dict[str, Any] | None = None,
        candidate_index: dict[str, Any] | None = None,
        candidate_database: dict[str, Any] | None = None,
        candidate_schemas: dict[Path, dict[str, Any]] | None = None,
    ) -> None:
        detected = bool(
            runtime_reference_errors(
                authority,
                candidate_runtime or runtime,
                candidate_index or index,
                candidate_database or database_contract,
                candidate_schemas or schemas,
            )
        )
        fixtures.append({"fixture": name, "corruption_rejected": detected})

    baseline_runtime_errors = runtime_reference_errors(
        authority,
        runtime,
        index,
        database_contract,
        schemas,
    )
    fixtures.append(
        {
            "fixture": "current-runtime-reference-graph",
            "corruption_rejected": not baseline_runtime_errors,
        }
    )

    missing_output = dict(schemas)
    missing_output.pop((ROOT / "schemas/claim-draft-output.schema.json").resolve())
    record_runtime("referenced-output-file-missing", candidate_schemas=missing_output)

    prompt_drift = copy.deepcopy(runtime)
    prompt_drift["effective_agent_dispatch_registry"]["rows"][0]["prompt"]["sha256"] = "0" * 64
    record_runtime("one-byte-prompt-drift", candidate_runtime=prompt_drift)

    proposal_kind_drift = copy.deepcopy(runtime)
    proposal_kind_drift["effective_agent_dispatch_registry"]["rows"][1][
        "allowed_proposal_kinds"
    ] = ["HYPOTHESIS"]
    record_runtime("agent-proposal-kind-drift", candidate_runtime=proposal_kind_drift)

    physical_drift = copy.deepcopy(database_contract)
    for table in physical_drift["tables"]:
        if table.get("relation") == "ops.agent_run_control_receipts":
            table["columns"].pop("reconciliation_evidence_sha256")
            break
    record_runtime("control-receipt-column-drift", candidate_database=physical_drift)

    projection_drift = copy.deepcopy(schemas)
    projection_path = (ROOT / "schemas/provider-receipt.schema.json").resolve()
    projection_drift[projection_path]["x-gurinnae-digest-projection"][
        "excludedRootFields"
    ] = []
    record_runtime("self-digest-in-own-projection", candidate_schemas=projection_drift)

    evidence_citations = [
        {"citation_ordinal": 2, "source_kind": "EVIDENCE_SEGMENT", "evidence_segment_id": UUID_2},
        {"citation_ordinal": 0, "source_kind": "EVIDENCE_SEGMENT", "evidence_segment_id": UUID},
        {"citation_ordinal": 1, "source_kind": "EVIDENCE_SEGMENT", "evidence_segment_id": UUID},
        {"citation_ordinal": 3, "source_kind": "RUN_TOOL_ARTIFACT", "evidence_segment_id": None},
    ]
    evidence_set = ordered_unique_evidence_segment_ids(evidence_citations)
    fixtures.append(
        {
            "fixture": "hypothesis-detail-evidence-set-dedupe-first",
            "corruption_rejected": evidence_set == [UUID, UUID_2],
        }
    )
    row_wise_projection = [
        row["evidence_segment_id"]
        for row in sorted(evidence_citations, key=lambda row: row["citation_ordinal"])
        if row["source_kind"] == "EVIDENCE_SEGMENT"
    ]
    fixtures.append(
        {
            "fixture": "hypothesis-detail-row-wise-duplicate-rejected",
            "corruption_rejected": row_wise_projection != evidence_set,
        }
    )

    return all(bool(row["corruption_rejected"]) for row in fixtures), fixtures


def ordered_unique_evidence_segment_ids(citations: list[dict[str, Any]]) -> list[str]:
    first_ordinal_by_segment: dict[str, int] = {}
    for citation in citations:
        if citation.get("source_kind") != "EVIDENCE_SEGMENT":
            continue
        segment_id = citation.get("evidence_segment_id")
        ordinal = citation.get("citation_ordinal")
        if not isinstance(segment_id, str) or not isinstance(ordinal, int):
            raise ValueError("evidence citation binding is malformed")
        first_ordinal_by_segment[segment_id] = min(
            ordinal, first_ordinal_by_segment.get(segment_id, ordinal)
        )
    return [
        segment_id
        for segment_id, _ in sorted(
            first_ordinal_by_segment.items(), key=lambda item: (item[1], item[0])
        )
    ]


def collect_refs(document: Any) -> list[str]:
    return [value["$ref"] for _, value in walk(document) if isinstance(value, dict) and isinstance(value.get("$ref"), str)]


def resolve_ref(source: Path, document: dict[str, Any], ref: str, schemas: dict[Path, dict[str, Any]], ids: dict[str, Path]) -> tuple[Path, Any]:
    file_part, marker, fragment = ref.partition("#")
    if not file_part:
        target_path = source
    elif "://" in file_part:
        target_path = ids[file_part]
    else:
        target_path = (source.parent / file_part).resolve()
    target_document = schemas[target_path]
    return target_path, json_pointer(target_document, f"#{fragment}" if marker else "")


def build_registry(schemas: dict[Path, dict[str, Any]]) -> Registry:
    registry = Registry()
    for path, schema in schemas.items():
        resource = Resource.from_contents(schema)
        registry = registry.with_resource(path.as_uri(), resource)
        registry = registry.with_resource(schema["$id"], resource)
    for path, schema in schemas.items():
        for ref in collect_refs(schema):
            file_part = ref.partition("#")[0]
            if not file_part or "://" in file_part:
                continue
            target = (path.parent / file_part).resolve()
            registry = registry.with_resource(urljoin(schema["$id"], file_part), Resource.from_contents(schemas[target]))
    return registry


def string_for(schema: dict[str, Any]) -> str:
    if schema.get("format") == "uuid":
        return UUID
    if schema.get("format") == "date-time":
        return NOW
    if schema.get("format") == "date":
        return NOW[:10]
    if schema.get("format") == "uri":
        return "https://example.invalid/x"
    pattern = schema.get("pattern", "")
    if pattern == "^[0-9a-f]{64}$":
        return "0" * 64
    if pattern == "^[A-Z]{3}$":
        return "KRW"
    if pattern == "^[A-Z]{2}$":
        return "KR"
    if pattern == "^[A-Z]{2}(?:-[A-Z0-9]{1,12})?$":
        return "KR"
    if pattern == "^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$":
        return "application/octet-stream"
    if pattern.startswith("^https://"):
        return "https://example.invalid/x"
    if pattern.startswith("^/internal/"):
        return "/internal/x"
    if pattern.startswith("^/"):
        return "/x"
    if "utf16:" in pattern:
        return "utf16:0-1"
    if pattern.startswith("^[a-z"):
        return "a"
    if pattern.startswith("^[A-Z"):
        return "A"
    minimum = int(schema.get("minLength", 1))
    return "x" * max(1, minimum)


def merge_schema(base: Any, overlay: Any) -> Any:
    if not isinstance(base, dict) or not isinstance(overlay, dict):
        return copy.deepcopy(overlay)
    if "$ref" in overlay:
        return copy.deepcopy(overlay)
    merged = copy.deepcopy(base)
    for key, value in overlay.items():
        if key == "properties" and isinstance(value, dict):
            properties = merged.setdefault("properties", {})
            for property_name, property_schema in value.items():
                properties[property_name] = merge_schema(properties.get(property_name, {}), property_schema)
        elif key == "required" and isinstance(value, list):
            merged[key] = list(dict.fromkeys([*merged.get(key, []), *value]))
        else:
            merged[key] = copy.deepcopy(value)
    return merged


def condition_matches(value: Any, condition: Any, source: Path, root: dict[str, Any], schemas: dict[Path, dict[str, Any]], ids: dict[str, Path]) -> bool:
    if not isinstance(condition, dict):
        return True
    if "$ref" in condition:
        target_path, target = resolve_ref(source, root, condition["$ref"], schemas, ids)
        return condition_matches(value, target, target_path, schemas[target_path], schemas, ids)
    if "const" in condition and value != condition["const"]:
        return False
    if "enum" in condition and value not in condition["enum"]:
        return False
    expected_type = condition.get("type")
    if expected_type == "null" and value is not None:
        return False
    if expected_type == "string" and not isinstance(value, str):
        return False
    if expected_type == "object" and not isinstance(value, dict):
        return False
    if expected_type == "array" and not isinstance(value, list):
        return False
    if expected_type == "integer" and (not isinstance(value, int) or isinstance(value, bool)):
        return False
    if isinstance(condition.get("required"), list):
        if not isinstance(value, dict) or any(key not in value for key in condition["required"]):
            return False
    for key, property_condition in condition.get("properties", {}).items():
        if isinstance(value, dict) and key in value:
            if not condition_matches(value[key], property_condition, source, root, schemas, ids):
                return False
    return True


def synthesize(schema: Any, source: Path, root: dict[str, Any], schemas: dict[Path, dict[str, Any]], ids: dict[str, Path]) -> Any:
    if not isinstance(schema, dict):
        return None
    if "$ref" in schema:
        target_path, target = resolve_ref(source, root, schema["$ref"], schemas, ids)
        siblings = {key: value for key, value in schema.items() if key != "$ref"}
        return synthesize(merge_schema(target, siblings), target_path, schemas[target_path], schemas, ids)
    if "const" in schema:
        return copy.deepcopy(schema["const"])
    if "enum" in schema:
        return copy.deepcopy(schema["enum"][0])
    if "oneOf" in schema or "anyOf" in schema:
        keyword = "oneOf" if "oneOf" in schema else "anyOf"
        branches = schema[keyword]
        explicit_type = schema.get("type")
        if isinstance(explicit_type, list):
            allowed_types = set(explicit_type)
        elif explicit_type is None:
            allowed_types = set()
        else:
            allowed_types = {explicit_type}

        def declared_types(item: Any) -> set[str]:
            if not isinstance(item, dict):
                return set()
            if "$ref" in item:
                target_path, target = resolve_ref(source, root, item["$ref"], schemas, ids)
                return declared_types(merge_schema(target, {key: value for key, value in item.items() if key != "$ref"}))
            branch_type = item.get("type")
            if isinstance(branch_type, list):
                return set(branch_type)
            if isinstance(branch_type, str):
                return {branch_type}
            if "properties" in item:
                return {"object"}
            return set()

        def branch_rank(item: Any) -> tuple[int, int]:
            item_types = declared_types(item)
            incompatible = int(bool(allowed_types and item_types and allowed_types.isdisjoint(item_types)))
            null_last = int(item_types == {"null"} and "null" not in allowed_types)
            return incompatible, null_last

        common = {key: value for key, value in schema.items() if key != keyword}
        for branch in sorted(branches, key=branch_rank):
            candidate_schema = merge_schema(common, branch)
            candidate = synthesize(candidate_schema, source, root, schemas, ids)
            # A local candidate check catches mutually exclusive type/const branches.
            if condition_matches(candidate, candidate_schema, source, root, schemas, ids) and condition_matches(candidate, common, source, root, schemas, ids):
                return candidate
        return synthesize(merge_schema(common, branches[0]), source, root, schemas, ids)
    value_type = schema.get("type")
    if isinstance(value_type, list):
        value_type = next((item for item in value_type if item != "null"), "null")
    if value_type == "object" or (value_type is None and "properties" in schema):
        properties = schema.get("properties", {})
        effective_properties = copy.deepcopy(properties)
        value = {key: synthesize(properties[key], source, root, schemas, ids) for key in schema.get("required", [])}
        for conditional in schema.get("allOf", []):
            branch = conditional.get("then") if condition_matches(value, conditional.get("if", {}), source, root, schemas, ids) else conditional.get("else")
            if not isinstance(branch, dict):
                continue
            for key, property_overlay in branch.get("properties", {}).items():
                if key in properties:
                    effective_properties[key] = merge_schema(effective_properties[key], property_overlay)
                    value[key] = synthesize(effective_properties[key], source, root, schemas, ids)
        return value
    if value_type == "array":
        return [synthesize(schema.get("items", {}), source, root, schemas, ids) for _ in range(int(schema.get("minItems", 0)))]
    if value_type == "integer" or value_type == "number":
        return schema.get("minimum", 0)
    if value_type == "boolean":
        return False
    if value_type == "null":
        return None
    return string_for(schema)


def validate_instance(path: Path, instance: Any, schemas: dict[Path, dict[str, Any]], registry: Registry) -> list[str]:
    validator = Draft202012Validator(schemas[path], registry=registry, format_checker=FormatChecker())
    return [error.message for error in validator.iter_errors(instance)]


def claim_examples() -> list[tuple[str, dict[str, Any], bool]]:
    digest = "0" * 64
    finding = {
        "findingId": UUID,
        "code": "MISSING_LIMITATION",
        "severity": "WARNING",
        "startUtf16": 0,
        "endUtf16": 1,
        "lengthUtf16": 1,
        "message": "한계를 명시하세요.",
        "suggestedReplacement": None,
        "citationIds": [],
    }
    blocking = {**finding, "findingId": UUID_2, "code": "UNSUPPORTED_CERTAINTY", "severity": "BLOCKING"}
    base = {
        "schemaVersion": "claim.language_check.response.v2",
        "checkedTextSha256": digest,
        "checkedTextUtf16Length": 1,
        "findingLimit": 50,
        "languageDecisionSha256": digest,
    }
    return [
        ("claim-pass", {**base, "decision": "PASS", "findings": [], "totalFindings": 0, "truncated": False}, True),
        ("claim-revise", {**base, "decision": "REVISE", "findings": [finding], "totalFindings": 1, "truncated": False}, True),
        ("claim-block", {**base, "decision": "BLOCK", "findings": [blocking], "totalFindings": 1, "truncated": False}, True),
        ("claim-block-truncated", {**base, "decision": "BLOCK", "findings": [finding], "totalFindings": 2, "truncated": True}, True),
        ("claim-pass-with-finding", {**base, "decision": "PASS", "findings": [finding], "totalFindings": 1, "truncated": False}, False),
        ("claim-revise-blocking", {**base, "decision": "REVISE", "findings": [blocking], "totalFindings": 1, "truncated": False}, False),
        ("claim-revise-truncated", {**base, "decision": "REVISE", "findings": [finding], "totalFindings": 2, "truncated": True}, False),
        ("claim-block-empty", {**base, "decision": "BLOCK", "findings": [], "totalFindings": 0, "truncated": False}, False),
        ("claim-zero-length", {**base, "decision": "REVISE", "findings": [{**finding, "endUtf16": 0, "lengthUtf16": 0}], "totalFindings": 1, "truncated": False}, False),
        ("claim-inconsistent-span", {**base, "decision": "REVISE", "findings": [{**finding, "endUtf16": 2}], "totalFindings": 1, "truncated": False}, False),
        ("claim-span-out-of-bounds", {**base, "decision": "REVISE", "findings": [{**finding, "startUtf16": 1, "endUtf16": 2}], "totalFindings": 1, "truncated": False}, False),
    ]


def utf16_length(value: str) -> int:
    return len(value.encode("utf-16-le")) // 2


def claim_exchange_examples() -> list[tuple[str, dict[str, Any], dict[str, Any], bool]]:
    draft = "가😀나"
    draft_sha256 = hashlib.sha256(draft.encode("utf-8")).hexdigest()
    request = {
        "schemaVersion": "claim.language_check.request.v2",
        "runId": UUID,
        "inputSnapshotId": UUID,
        "inputSnapshotSha256": "0" * 64,
        "draftText": draft,
        "draftTextSha256": draft_sha256,
        "claimType": "FACT",
        "locale": "ko-KR",
        "allowedCitationIds": [UUID_2],
        "languagePolicyVersion": "ko-public-claims-v1",
        "languagePolicySha256": "6766a275b7d9a3ef0157bbd42d57245f8309f3ec15f2ee6cd515d6397ee4bc4e",
        "maxFindings": 2,
    }
    finding = {
        "findingId": UUID,
        "code": "MISSING_LIMITATION",
        "severity": "WARNING",
        "startUtf16": 1,
        "endUtf16": 3,
        "lengthUtf16": 2,
        "message": "한계를 명시하세요.",
        "suggestedReplacement": None,
        "citationIds": [UUID_2],
    }
    response = {
        "schemaVersion": "claim.language_check.response.v2",
        "checkedTextSha256": draft_sha256,
        "checkedTextUtf16Length": 4,
        "decision": "REVISE",
        "findings": [finding],
        "findingLimit": 2,
        "totalFindings": 1,
        "truncated": False,
        "languageDecisionSha256": "2" * 64,
    }
    return [
        ("claim-exchange-valid-surrogate-pair", request, response, True),
        ("claim-exchange-draft-digest", {**request, "draftTextSha256": "3" * 64}, response, False),
        ("claim-exchange-checked-digest", request, {**response, "checkedTextSha256": "3" * 64}, False),
        ("claim-exchange-utf16-length", request, {**response, "checkedTextUtf16Length": 3}, False),
        ("claim-exchange-span-bound", request, {**response, "findings": [{**finding, "endUtf16": 5, "lengthUtf16": 4}]}, False),
        ("claim-exchange-citation-subset", request, {**response, "findings": [{**finding, "citationIds": [UUID]}]}, False),
        ("claim-exchange-limit-binding", request, {**response, "findingLimit": 1}, False),
        ("claim-exchange-policy-version", {**request, "languagePolicyVersion": "unknown"}, response, False),
        ("claim-exchange-policy-digest", {**request, "languagePolicySha256": "3" * 64}, response, False),
    ]


def proposal_examples() -> list[tuple[str, dict[str, Any], bool]]:
    digest = "0" * 64
    citation = {"citationId": UUID_2, "citationSha256": digest}
    payload = {"kind": "HYPOTHESIS", "statement": "검토할 가설", "supportingCitationIds": [UUID_2], "contradictingCitationIds": [], "unknowns": [], "limitations": []}
    base = {
        "schemaVersion": "agent-proposal.v2", "proposalId": UUID, "proposalContractVersion": 2,
        "agentRunId": UUID, "caseId": UUID, "proposalType": "HYPOTHESIS", "targetSchemaVersion": "1",
        "payload": payload, "payloadSha256": digest, "inputSnapshotSha256": digest,
        "citationValidationId": UUID, "citationBindings": [citation], "version": 1,
        "expiresAt": "2026-07-16T00:00:00Z", "createdAt": NOW,
    }
    decision = {"decisionKind": "ACCEPT", "reason": "근거 검토 완료", "decidedBy": UUID, "decidedAt": NOW, "auditEventId": UUID, "decisionSha256": digest}
    target = {"targetType": "ACTION_PROPOSAL_DRAFT", "targetId": UUID, "targetVersion": 1, "targetDigest": digest}
    accepted = {**base, "status": "ACCEPTED", "decision": decision, "materializedTarget": target, "materializationReceiptSha256": digest}
    examples = [
        ("proposal-pending", {**base, "status": "PENDING", "decision": None, "materializedTarget": None, "materializationReceiptSha256": None}, True),
        ("proposal-accepted", accepted, True),
        ("proposal-rejected", {**base, "status": "REJECTED", "decision": {**decision, "decisionKind": "REJECT"}, "materializedTarget": None, "materializationReceiptSha256": None}, True),
        ("proposal-superseded", {**base, "status": "SUPERSEDED", "decision": {**decision, "decisionKind": "SUPERSEDE"}, "materializedTarget": None, "materializationReceiptSha256": None}, True),
        ("proposal-expired", {**base, "status": "EXPIRED", "decision": {**decision, "decisionKind": "EXPIRE"}, "materializedTarget": None, "materializationReceiptSha256": None}, True),
        ("proposal-wrong-target", {**accepted, "materializedTarget": {**target, "targetType": "TASK"}}, False),
        ("proposal-pending-with-decision", {**base, "status": "PENDING", "decision": decision, "materializedTarget": None, "materializationReceiptSha256": None}, False),
        ("proposal-rejected-with-accept", {**base, "status": "REJECTED", "decision": decision, "materializedTarget": None, "materializationReceiptSha256": None}, False),
        ("proposal-superseded-with-reject", {**base, "status": "SUPERSEDED", "decision": {**decision, "decisionKind": "REJECT"}, "materializedTarget": None, "materializationReceiptSha256": None}, False),
        ("proposal-expired-without-decision", {**base, "status": "EXPIRED", "decision": None, "materializedTarget": None, "materializationReceiptSha256": None}, False),
        ("proposal-empty-citations", {**base, "citationBindings": [], "status": "PENDING", "decision": None, "materializedTarget": None, "materializationReceiptSha256": None}, False),
        ("proposal-citation-mismatch", {**base, "citationBindings": [{"citationId": UUID, "citationSha256": digest}], "status": "PENDING", "decision": None, "materializedTarget": None, "materializationReceiptSha256": None}, False),
    ]
    type_cases = [
        ("CLAIM", {"kind": "CLAIM", "claimType": "FACT", "text": "검증된 사실", "citationIds": [UUID_2], "limitations": [], "responseContext": "NO_REQUEST"}, "ACTION_PROPOSAL_DRAFT"),
        ("TASK", {"kind": "TASK", "title": "근거 검토", "description": "정확한 출처를 검토한다", "priority": "NORMAL", "duePolicy": "WITHIN_3_DAYS", "citationIds": [UUID_2]}, "ACTION_PROPOSAL_DRAFT"),
        ("COMPARABLE", {"kind": "COMPARABLE", "subjectContractId": UUID, "candidateContractId": UUID_2, "comparisonBasis": "동일 분류", "materialDifferences": ["규모 차이"], "citationIds": [UUID_2], "verificationState": "UNVERIFIED_CANDIDATE"}, "ACTION_PROPOSAL_DRAFT"),
        ("COMMUNICATION", {"schemaVersion": "communication-proposal-payload.v1", "kind": "COMMUNICATION", "recipientBinding": {"subjectId": UUID, "endpointId": UUID_2, "endpointVersion": 1, "endpointDigest": digest}, "channel": "SMTP_EMAIL", "purpose": "RIGHT_OF_REPLY_REQUEST", "draftText": "근거 확인을 요청합니다.", "rationale": "정확한 반론권 보장을 위해 확인이 필요합니다.", "citationIds": [UUID_2], "requiresApproval": True}, "ACTION_PROPOSAL_DRAFT"),
    ]
    for proposal_type, typed_payload, target_type in type_cases:
        typed_base = {**base, "proposalType": proposal_type, "payload": typed_payload}
        typed_accepted = {
            **typed_base,
            "status": "ACCEPTED",
            "decision": decision,
            "materializedTarget": {**target, "targetType": target_type},
            "materializationReceiptSha256": digest,
        }
        examples.append((f"proposal-{proposal_type.lower()}-accepted", typed_accepted, True))
        examples.append((f"proposal-{proposal_type.lower()}-wrong-target", {**typed_accepted, "materializedTarget": {**target, "targetType": "TASK"}}, False))
    return examples


def claim_semantic_errors(value: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    findings = value.get("findings", [])
    keys: list[tuple[Any, ...]] = []
    for finding in findings:
        if finding.get("endUtf16") != finding.get("startUtf16", 0) + finding.get("lengthUtf16", 0):
            errors.append("finding span is inconsistent")
        if isinstance(finding.get("endUtf16"), int) and finding["endUtf16"] > value.get("checkedTextUtf16Length", -1):
            errors.append("finding span exceeds checked text UTF-16 length")
        keys.append((finding.get("startUtf16"), finding.get("endUtf16"), finding.get("code"), finding.get("findingId")))
    if keys != sorted(keys) or len(keys) != len(set(keys)):
        errors.append("findings are not sorted unique")
    total = value.get("totalFindings")
    if isinstance(total, int) and value.get("truncated") != (total > len(findings)):
        errors.append("truncated does not match total versus returned finding count")
    if isinstance(total, int) and total < len(findings):
        errors.append("totalFindings is smaller than returned findings")
    if len(findings) > value.get("findingLimit", -1):
        errors.append("returned findings exceed findingLimit")
    return errors


def claim_exchange_semantic_errors(request: dict[str, Any], response: dict[str, Any]) -> list[str]:
    errors = claim_semantic_errors(response)
    expected_digest = hashlib.sha256(request.get("draftText", "").encode("utf-8")).hexdigest()
    if request.get("draftTextSha256") != expected_digest:
        errors.append("request draft digest does not match exact UTF-8 bytes")
    if response.get("checkedTextSha256") != request.get("draftTextSha256"):
        errors.append("response checked digest does not bind request draft digest")
    if response.get("checkedTextUtf16Length") != utf16_length(request.get("draftText", "")):
        errors.append("response UTF-16 length does not bind exact draft")
    if response.get("findingLimit") != request.get("maxFindings"):
        errors.append("response finding limit does not bind request maximum")
    allowed = set(request.get("allowedCitationIds", []))
    cited = {citation_id for finding in response.get("findings", []) for citation_id in finding.get("citationIds", [])}
    if not cited.issubset(allowed):
        errors.append("finding citation is outside the request allowlist")
    return errors


def proposal_semantic_errors(value: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    payload = value.get("payload", {})
    citation_ids: list[str] = []
    for key in ("supportingCitationIds", "contradictingCitationIds", "citationIds"):
        citation_ids.extend(payload.get(key, []))
    binding_ids = [item.get("citationId") for item in value.get("citationBindings", [])]
    if sorted(citation_ids) != sorted(binding_ids) or len(binding_ids) != len(set(binding_ids)):
        errors.append("payload citations and citationBindings are not set-equal unique")
    if value.get("expiresAt", "") <= value.get("createdAt", ""):
        errors.append("proposal expiry is not later than creation")
    status_to_decision = {"ACCEPTED": "ACCEPT", "REJECTED": "REJECT", "SUPERSEDED": "SUPERSEDE", "EXPIRED": "EXPIRE"}
    status = value.get("status")
    decision = value.get("decision")
    if status == "PENDING" and decision is not None:
        errors.append("pending proposal has a terminal decision")
    if status in status_to_decision and (not isinstance(decision, dict) or decision.get("decisionKind") != status_to_decision[status]):
        errors.append("terminal proposal status and decision kind differ")
    target_types = dict.fromkeys(
        ("HYPOTHESIS", "CLAIM", "TASK", "COMPARABLE", "COMMUNICATION"),
        "ACTION_PROPOSAL_DRAFT",
    )
    target = value.get("materializedTarget")
    if status == "ACCEPTED" and (not isinstance(target, dict) or target.get("targetType") != target_types.get(value.get("proposalType"))):
        errors.append("accepted proposal materializes the wrong target type")
    if status != "ACCEPTED" and target is not None:
        errors.append("non-accepted proposal materializes a target")
    return errors


def output_validation_examples(valid: dict[str, Any]) -> list[tuple[str, dict[str, Any], bool]]:
    invalid = copy.deepcopy(valid)
    invalid.update(
        {
            "validationStatus": "INVALID",
            "schemaStatus": "FAIL",
            "citationStatus": "NOT_RUN",
            "policyStatus": "NOT_RUN",
            "runTerminalStatus": "FAILED",
            "outputStatus": "INVALID",
            "failureCode": "OUTPUT_SCHEMA_INVALID",
            "failureDetails": [{"stage": "JSON_SCHEMA", "code": "REQUIRED", "jsonPointer": "/result", "detailSha256": "4" * 64}],
            "validatedOutcome": None,
            "validatedOutcomeSha256": None,
            "citationCount": 0,
            "proposalCount": 0,
        }
    )
    wrong_outcome = copy.deepcopy(valid)
    wrong_outcome["validatedOutcome"]["status"] = "ABSTAINED"
    wrong_count = copy.deepcopy(valid)
    wrong_count["citationCount"] = len(valid["validatedOutcome"]["citationBindings"]) + 1
    invalid_with_outcome = copy.deepcopy(invalid)
    invalid_with_outcome["validatedOutcome"] = copy.deepcopy(valid["validatedOutcome"])
    invalid_with_outcome["validatedOutcomeSha256"] = "5" * 64
    invalid_without_failure = copy.deepcopy(invalid)
    invalid_without_failure.update({"schemaStatus": "PASS", "citationStatus": "NOT_RUN", "policyStatus": "NOT_RUN"})
    return [
        ("output-validation-valid", valid, True),
        ("output-validation-invalid", invalid, True),
        ("output-validation-status-mismatch", wrong_outcome, False),
        ("output-validation-count-mismatch", wrong_count, False),
        ("output-validation-invalid-with-outcome", invalid_with_outcome, False),
        ("output-validation-invalid-without-failed-stage", invalid_without_failure, False),
    ]


def output_validation_semantic_errors(value: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    outcome = value.get("validatedOutcome")
    if value.get("validationStatus") == "VALID":
        if not isinstance(outcome, dict) or outcome.get("status") != value.get("outputStatus"):
            errors.append("valid output status and validated outcome status differ")
        else:
            if value.get("citationCount") != len(outcome.get("citationBindings", [])):
                errors.append("citation count does not match validated bindings")
            if value.get("proposalCount") != len(outcome.get("proposalBindings", [])):
                errors.append("proposal count does not match validated bindings")
    elif outcome is not None or value.get("validatedOutcomeSha256") is not None:
        errors.append("invalid output retains a validated outcome")
    if value.get("validationStatus") == "INVALID" and "FAIL" not in {
        value.get("schemaStatus"), value.get("citationStatus"), value.get("policyStatus")
    }:
        errors.append("invalid output has no failed validation stage")
    return errors


def agent_output_semantic_errors(value: dict[str, Any]) -> list[str]:
    """Validate provider-local citation references against the enclosing output."""

    errors: list[str] = []
    citations = value.get("citations")
    citation_count = len(citations) if isinstance(citations, list) else 0
    citation_ids = {
        item.get("citationId")
        for item in (citations if isinstance(citations, list) else []) if isinstance(item, dict)
        if isinstance(item.get("citationId"), str)
    }
    for pointer, candidate in walk(value):
        if not pointer.lower().endswith("citationindexes"):
            continue
        if not isinstance(candidate, list):
            errors.append(f"{pointer}: citation indexes are not an array")
            continue
        if len(candidate) != len(set(candidate)):
            errors.append(f"{pointer}: citation indexes are duplicated")
        if any(
            not isinstance(index, int)
            or isinstance(index, bool)
            or index < 0
            or index >= citation_count
            for index in candidate
        ):
            errors.append(f"{pointer}: citation index is outside the enclosing citations")
    for pointer, candidate in walk(value):
        if not pointer.lower().endswith("citationids"):
            continue
        if not isinstance(candidate, list):
            errors.append(f"{pointer}: citation IDs are not an array")
            continue
        if len(candidate) != len(set(candidate)):
            errors.append(f"{pointer}: citation IDs are duplicated")
        if any(citation_id not in citation_ids for citation_id in candidate):
            errors.append(f"{pointer}: citation ID is outside the enclosing citations")
    return errors


def r6c_recursion_and_review_tier_errors(
    authority: dict[str, Any],
    provenance: dict[str, Any],
    runtime: dict[str, Any],
    recursion: dict[str, Any],
    review_tier: dict[str, Any],
) -> list[str]:
    errors: list[str] = []
    normative = authority.get("normative_documents", {})
    if normative.get("artifact_review_tier") != "artifact-review-tier.yaml":
        errors.append("R6c artifact review-tier authority is not wired")
    if normative.get("hypothesis_recursion") != "../hypothesis-recursion-policy.yaml":
        errors.append("R6c hypothesis-recursion authority is not wired")

    root = recursion.get("trigger_contract", {}).get("root", {})
    stage = recursion.get("trigger_contract", {}).get("stage", {})
    if root.get("event_type") != "action.execution_completed.v1" or root.get("root_depth") != 0:
        errors.append("R6c recursion root is not successful action execution at depth zero")
    if root.get("accepted_hypothesis_detail") != {
        "case_binding": "caseId and expectedCaseVersion equal the accepted suggestion case and the action-proposal target identity and version.",
        "statement_digest": "SHA-256 over the raw statement UTF-8 bytes.",
        "evidence_segment_set_digest": "SHA-256 over the canonical JSON array of unique evidence_segment_id UUIDs ordered by each segment's first/minimum citation_ordinal; repeated citations to the same segment remain in the all-citation binding but contribute one set member.",
        "unknown_set_digest": "SHA-256 over the canonical JSON bytes of the accepted payload unknowns array in its declared order.",
        "research_artifact_boundary": "RUN_TOOL_ARTIFACT citations are excluded from evidenceSegmentSetDigest and remain bound by the immutable citation all-and-only verifier and OFFICIAL_UNREVIEWED review-tier gate.",
    }:
        errors.append("R6c accepted HYPOTHESIS detail digest preimages drifted")
    if stage.get("event_type") != "agent.run_completed.v1":
        errors.append("R6c recursion stage trigger is not agent.run_completed.v1")
    state_machine = recursion.get("state_machine", {})
    if state_machine.get("stages") != ["MARKET_RESEARCHER", "SKEPTIC"]:
        errors.append("R6c recursion stages are not closed to market-researcher then skeptic")
    if state_machine.get("dedupe_preimage_order") != [
        "caseId",
        "hypothesisExecutionDigest",
        "snapshotDigest",
        "stage",
        "depth",
    ]:
        errors.append("R6c recursion dedupe preimage order drifted")
    if state_machine.get("claim_drafter", {}).get("automatic_execution") != "forbidden":
        errors.append("R6c recursion does not forbid automatic claim drafting")
    dispositions = recursion.get("closed_dispositions", {})
    if dispositions.get("started") != "STARTED" or dispositions.get(
        "durable_no_op_or_block"
    ) != [
        "POLICY_ABSENT",
        "POLICY_DISABLED",
        "MAX_DEPTH_REACHED",
        "CASE_BUDGET_BLOCKED",
        "NOT_HYPOTHESIS",
        "NOT_SUCCEEDED",
        "NODE_NOT_RECURSIVE",
        "STAGE_NOT_MARKET_RESEARCHER",
        "RUN_NOT_SUCCEEDED",
        "PLAN_TERMINAL",
    ]:
        errors.append("R6c recursion disposition registry drifted")
    policy = recursion.get("immutable_policy", {})
    if policy.get("production_seed") != "forbidden" or policy.get("defaults") != "forbidden":
        errors.append("R6c recursion policy gained a production seed or default")
    fixture = recursion.get("test_fixture_only_policy", {})
    if fixture.get("production_seed") is not False or fixture.get("maxDepth") != 2:
        errors.append("R6c recursion fixture-only policy boundary drifted")
    if [
        fixture.get("caseBudgetMicrosKrw"),
        fixture.get("marketResearcherStageBudgetMicrosKrw"),
        fixture.get("skepticStageBudgetMicrosKrw"),
    ] != [3_000_000, 2_000_000, 1_000_000]:
        errors.append("R6c recursion fixture-only budget values drifted")

    tiers = review_tier.get("closed_review_tiers", {})
    if set(tiers) != {"OFFICIAL_UNREVIEWED", "HUMAN_PROMOTED"}:
        errors.append("R6c artifact review-tier registry is not closed")
    unreviewed = tiers.get("OFFICIAL_UNREVIEWED", {})
    promoted = tiers.get("HUMAN_PROMOTED", {})
    if unreviewed.get("initial_classification") != "RESTRICTED":
        errors.append("R6c unreviewed artifact is not initially RESTRICTED")
    if "MODEL_INPUT" not in unreviewed.get("forbidden_use", []):
        errors.append("R6c unreviewed artifact is not blocked from model input")
    if promoted.get("default_classification") != "forbidden":
        errors.append("R6c promoted artifact classification gained a default")
    if promoted.get("reviewed_classification_required") != [
        "PUBLIC",
        "INTERNAL",
        "RESTRICTED",
        "PERSONAL_DATA",
        "LEGAL_HOLD",
    ]:
        errors.append("R6c reviewed classification registry drifted")
    research = provenance.get("research_artifact", {})
    if research.get("initial_state") != {
        "reviewTier": "OFFICIAL_UNREVIEWED",
        "reviewedClassification": "RESTRICTED",
    }:
        errors.append("R6c provenance does not bind the initial artifact review state")
    if "MODEL_INPUT" not in research.get("prohibited_before_promotion", []):
        errors.append("R6c provenance permits unpromoted artifact model input")
    investigator_fetch = (
        runtime.get("per_agent_tool_request_constraints", {})
        .get("investigator", {})
        .get("source.fetch", {})
    )
    if investigator_fetch.get("allowed_request_kinds") != ["FETCH_URL"]:
        errors.append("R6c investigator source.fetch is not FETCH_URL-only")
    if investigator_fetch.get("denied_request_kinds") != ["SEARCH_PUBLIC_WEB"]:
        errors.append("R6c investigator web search is not explicitly denied")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        passed, fixtures = schema_pin_self_test()
        payload = {
            "self_test": "PASS" if passed else "FAIL",
            "fixtures": fixtures,
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        print(f"SELF_TEST: {'PASS' if passed else 'FAIL'}")
        return 0 if passed else 1
    errors: list[str] = []
    yaml_paths = [
        ROOT / "authority.yaml",
        ROOT / "artifact-review-tier.yaml",
        ROOT / "network-provider.yaml",
        ROOT / "provenance-promotion.yaml",
        ROOT / "runtime-contracts.yaml",
        ROOT / "schema-index.yaml",
        HYPOTHESIS_RECURSION,
        PARSER_ADDENDUM,
    ]
    yaml_documents: dict[Path, dict[str, Any]] = {}
    for yaml_path in yaml_paths:
        try:
            document = load_yaml(yaml_path)
            yaml_documents[yaml_path] = document
            if document.get("schema_version") != 1:
                errors.append(f"{yaml_path}: schema_version must be 1")
            if document.get("status") not in {"REVIEW_REQUIRED", "FINAL"}:
                errors.append(f"{yaml_path}: status must be REVIEW_REQUIRED or FINAL")
            if document.get("decision_state") is not None:
                expected_decision_state = "FINAL" if document.get("status") == "FINAL" else "DECISION_COMPLETE_AWAITING_INDEPENDENT_REVIEW"
                if document.get("decision_state") != expected_decision_state:
                    errors.append(f"{yaml_path}: decision_state does not match status")
        except Exception as exc:
            errors.append(f"{yaml_path}: YAML parse: {exc}")
    statuses = {document.get("status") for document in yaml_documents.values()}
    if len(statuses) != 1:
        errors.append(f"agent/parser addendum status is not atomically aligned: {sorted(str(item) for item in statuses)}")
    errors.extend(
        r6c_recursion_and_review_tier_errors(
            yaml_documents.get(ROOT / "authority.yaml", {}),
            yaml_documents.get(ROOT / "provenance-promotion.yaml", {}),
            yaml_documents.get(ROOT / "runtime-contracts.yaml", {}),
            yaml_documents.get(HYPOTHESIS_RECURSION, {}),
            yaml_documents.get(ROOT / "artifact-review-tier.yaml", {}),
        )
    )
    index = yaml_documents.get(ROOT / "schema-index.yaml", {})
    try:
        database_contract = load_yaml(DATABASE_ADDENDUM)
        errors.extend(database_schema_pin_errors(index, database_contract))
    except Exception as exc:
        errors.append(f"{DATABASE_ADDENDUM}: schema pin validation: {exc}")
    paths = [path.resolve() for path in indexed_schema_paths(index)]
    discovered = sorted(path.resolve() for path in ROOT.rglob("*.json"))
    if sorted(paths) != discovered:
        errors.append("schema-index paths are not set-equal to discovered JSON schemas")
    schemas: dict[Path, dict[str, Any]] = {}
    ids: dict[str, Path] = {}
    for path in discovered:
        try:
            schema = load_json(path)
            Draft202012Validator.check_schema(schema)
            schemas[path] = schema
            schema_id = schema.get("$id")
            if not isinstance(schema_id, str):
                errors.append(f"{path}: missing $id")
            elif schema_id in ids:
                errors.append(f"{path}: duplicate $id {schema_id}")
            else:
                ids[schema_id] = path
        except Exception as exc:
            errors.append(f"{path}: parse/metaschema: {exc}")
    for path, schema in schemas.items():
        for pointer, value in walk(schema):
            if isinstance(value, dict) and isinstance(value.get("required"), list):
                properties = value.get("properties")
                if not isinstance(properties, dict):
                    errors.append(f"{path}{pointer}: required without properties")
                else:
                    missing = sorted(set(value["required"]) - set(properties))
                    if missing:
                        errors.append(f"{path}{pointer}: required not in properties: {missing}")
            if isinstance(value, dict) and value.get("type") == "object":
                if value.get("additionalProperties") is not False:
                    errors.append(f"{path}{pointer}: closed object lacks additionalProperties false")
            if isinstance(value, dict) and "$ref" in value:
                try:
                    resolve_ref(path, schema, value["$ref"], schemas, ids)
                except Exception as exc:
                    errors.append(f"{path}{pointer}: unresolved ref {value['$ref']}: {exc}")
    try:
        errors.extend(
            runtime_reference_errors(
                yaml_documents.get(ROOT / "authority.yaml", {}),
                yaml_documents.get(ROOT / "runtime-contracts.yaml", {}),
                index,
                database_contract,
                schemas,
            )
        )
    except Exception as exc:
        errors.append(f"runtime reference validation crashed: {type(exc).__name__}: {exc}")
    if errors:
        registry = Registry()
    else:
        registry = build_registry(schemas)

    positive_count = 0
    negative_count = 0
    schema_instance_count = 0
    for path in discovered:
        if errors:
            break
        schema = schemas[path]
        example = synthesize(schema, path, schema, schemas, ids)
        validation_errors = validate_instance(path, example, schemas, registry)
        if validation_errors:
            errors.append(f"{path}: synthesized schema fixture rejected: {validation_errors[:3]}")
            continue
        positive_count += 1
        schema_instance_count += 1
        if isinstance(example, dict):
            unexpected = copy.deepcopy(example)
            unexpected["__unexpected"] = True
            if not validate_instance(path, unexpected, schemas, registry):
                errors.append(f"{path}: root additional-property negative was accepted")
            else:
                negative_count += 1
            if "schemaVersion" in example:
                wrong_version = copy.deepcopy(example)
                wrong_version["schemaVersion"] = "wrong.schema.version"
                if not validate_instance(path, wrong_version, schemas, registry):
                    errors.append(f"{path}: wrong schemaVersion negative was accepted")
                else:
                    negative_count += 1

    if not errors:
        runtime = yaml_documents.get(ROOT / "runtime-contracts.yaml", {})
        agent_output_examples: list[tuple[str, Path, Any]] = []
        for row in runtime.get("effective_agent_dispatch_registry", {}).get("rows", []):
            if not isinstance(row, dict):
                continue
            output = row.get("output", {})
            path = (REPO / str(output.get("path"))).resolve()
            schema = schemas.get(path)
            if schema is None:
                continue
            example = synthesize(schema, path, schema, schemas, ids)
            if isinstance(example, dict) and agent_output_semantic_errors(example):
                errors.append(f"{row.get('agent_id')}: synthesized output failed citation semantics")
            agent_output_examples.append((str(row.get("agent_id")), path, example))
        if len(agent_output_examples) != 5:
            errors.append("runtime agent output example set is not exactly five")
        else:
            for source_agent, _, example in agent_output_examples:
                for target_agent, target_path, _ in agent_output_examples:
                    if source_agent == target_agent:
                        continue
                    if not validate_instance(target_path, example, schemas, registry):
                        errors.append(
                            f"output for {source_agent} was accepted by {target_agent}"
                        )
                    else:
                        negative_count += 1
            market_agent, market_path, market_example = agent_output_examples[0]
            market_schema = schemas[market_path]
            citation_negative = copy.deepcopy(market_example)
            if isinstance(citation_negative, dict):
                comparable = synthesize(
                        market_schema["$defs"]["comparableDraft"],
                        market_path,
                        market_schema,
                        schemas,
                        ids,
                    )
                comparable["observedAt"] = "2026-07-15"
                comparable["unitPriceDecimal"] = "1"
                citation_negative["comparables"] = [comparable]
                schema_errors = validate_instance(
                    market_path,
                    citation_negative,
                    schemas,
                    registry,
                )
                semantic_errors = agent_output_semantic_errors(citation_negative)
                if schema_errors or not semantic_errors:
                    errors.append(
                        f"{market_agent}: out-of-range citation semantic negative was not isolated"
                    )
                else:
                    negative_count += 1

            control_path = (ROOT / "schemas/agent-run-control-receipt.schema.json").resolve()
            control_schema = schemas[control_path]
            unsafe_retry = synthesize(
                control_schema,
                control_path,
                control_schema,
                schemas,
                ids,
            )
            unsafe_retry.update(
                {
                    "aggregateVersion": 2,
                    "priorStatus": "RUNNING",
                    "priorControlState": "CANCEL_REQUESTED",
                    "nextStatus": "RUNNING",
                    "nextControlState": "ACTIVE",
                    "actorKind": "RECONCILIATION_WORKER",
                    "actorId": UUID,
                    "reasonCode": "SAFE_RETRY_AUTHORIZED",
                    "priorReceiptId": UUID_2,
                    "priorReceiptSha256": "1" * 64,
                    "commandBinding": None,
                }
            )
            if not validate_instance(
                control_path,
                unsafe_retry,
                schemas,
                registry,
            ):
                errors.append(
                    "AgentRunControlReceiptV2 accepted safe retry from CANCEL_REQUESTED"
                )
            else:
                negative_count += 1

    tool_pairs = index["tool_schemas"]
    if len(tool_pairs) != 13 or len({item["id"] for item in tool_pairs}) != 13:
        errors.append("tool schema index is not exactly 13 unique tools")
    request_fingerprints: set[str] = set()
    response_fingerprints: set[str] = set()
    tool_examples: dict[str, list[tuple[str, Path, Any]]] = {"request": [], "response": []}
    for item in tool_pairs:
        for direction, fingerprints in (("request", request_fingerprints), ("response", response_fingerprints)):
            path = (ROOT / item[direction]).resolve()
            schema = schemas.get(path)
            if schema is None:
                continue
            properties = schema.get("properties")
            if properties is None and "oneOf" in schema:
                properties = schema["$defs"]["searchPublicWeb"]["properties"]
            unique_field = item[f"unique_{direction}_field"]
            if unique_field not in properties:
                errors.append(f"{path}: missing declared unique field {unique_field}")
            fingerprints.add(hashlib.sha256(json.dumps(schema, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
            example = synthesize(schema, path, schema, schemas, ids)
            validation_errors = validate_instance(path, example, schemas, registry) if not errors else ["prior error"]
            if validation_errors:
                errors.append(f"{path}: synthesized positive rejected: {validation_errors[:3]}")
            else:
                positive_count += 1
                tool_examples[direction].append((item["id"], path, example))
                negative = copy.deepcopy(example)
                if isinstance(negative, dict):
                    negative["__unexpected"] = True
                    if not validate_instance(path, negative, schemas, registry):
                        errors.append(f"{path}: additional property negative was accepted")
                    else:
                        negative_count += 1
    if len(request_fingerprints) != 13 or len(response_fingerprints) != 13:
        errors.append("tool schemas are not structurally distinct in both directions")
    if not errors:
        for direction, examples in tool_examples.items():
            for source_id, _, example in examples:
                for target_id, target_path, _ in examples:
                    if source_id == target_id:
                        continue
                    if not validate_instance(target_path, example, schemas, registry):
                        errors.append(f"{direction} for {source_id} was accepted by {target_id}")
                    else:
                        negative_count += 1

        relationship_request_path = (
            ROOT / "tools/relationship-neighbors.request.schema.json"
        ).resolve()
        relationship_response_path = (
            ROOT / "tools/relationship-neighbors.response.schema.json"
        ).resolve()
        relationship_cross_version_negatives = [
            (
                relationship_request_path,
                {
                    "schemaVersion": "relationship.neighbors.request.v2",
                    "runId": UUID,
                    "inputSnapshotId": UUID_2,
                    "inputSnapshotSha256": "0" * 64,
                    "supplierId": UUID,
                    "selector": 1,
                    "relationshipKinds": [],
                    "asOf": None,
                    "limit": 1,
                },
            ),
            (
                relationship_request_path,
                {
                    "schemaVersion": "relationship.neighbors.request.v3",
                    "runId": UUID,
                    "inputSnapshotId": UUID_2,
                    "inputSnapshotSha256": "0" * 64,
                    "selector": {"kind": "PERSON", "personNodeRef": "1" * 64},
                    "supplierId": 1,
                    "relationshipKinds": [],
                    "asOf": None,
                    "limit": 1,
                },
            ),
            (
                relationship_response_path,
                {
                    "schemaVersion": "relationship.neighbors.response.v2",
                    "supplierId": UUID,
                    "queryDigest": 1,
                    "neighbors": [],
                },
            ),
            (
                relationship_response_path,
                {
                    "schemaVersion": "relationship.neighbors.response.v3",
                    "queryDigest": "0" * 64,
                    "supplierId": 1,
                    "neighbors": [],
                },
            ),
        ]
        for target_path, malformed in relationship_cross_version_negatives:
            if not validate_instance(target_path, malformed, schemas, registry):
                errors.append(
                    f"{target_path}: malformed opposite-version field was accepted"
                )
            else:
                negative_count += 1

    claim_path = (ROOT / "tools/claim-language-check.response.schema.json").resolve()
    claim_request_path = (ROOT / "tools/claim-language-check.request.schema.json").resolve()
    proposal_path = (ROOT / "schemas/agent-proposal.schema.json").resolve()
    output_validation_path = (ROOT / "schemas/output-validation.schema.json").resolve()
    if not errors:
        for label, example, should_pass in claim_examples() + proposal_examples():
            target = claim_path if label.startswith("claim-") else proposal_path
            semantic_errors = claim_semantic_errors(example) if label.startswith("claim-") else proposal_semantic_errors(example)
            actual_pass = not validate_instance(target, example, schemas, registry) and not semantic_errors
            if actual_pass != should_pass:
                errors.append(f"{label}: expected pass={should_pass}, actual pass={actual_pass}")
            elif should_pass:
                positive_count += 1
            else:
                negative_count += 1
        for label, request, response, should_pass in claim_exchange_examples():
            actual_pass = (
                not validate_instance(claim_request_path, request, schemas, registry)
                and not validate_instance(claim_path, response, schemas, registry)
                and not claim_exchange_semantic_errors(request, response)
            )
            if actual_pass != should_pass:
                errors.append(f"{label}: expected pass={should_pass}, actual pass={actual_pass}")
            elif should_pass:
                positive_count += 1
            else:
                negative_count += 1
        valid_output = synthesize(schemas[output_validation_path], output_validation_path, schemas[output_validation_path], schemas, ids)
        for label, example, should_pass in output_validation_examples(valid_output):
            actual_pass = not validate_instance(output_validation_path, example, schemas, registry) and not output_validation_semantic_errors(example)
            if actual_pass != should_pass:
                errors.append(f"{label}: expected pass={should_pass}, actual pass={actual_pass}")
            elif should_pass:
                positive_count += 1
            else:
                negative_count += 1

    parser_contract = yaml_documents.get(PARSER_ADDENDUM, {})
    expected_media = ["html", "png", "jpeg", "webp", "tiff", "wav", "webm"]
    if parser_contract["scope"]["additive_format_ids"] != expected_media:
        errors.append("parser additive media differs from DESIGN.md section 8.4 exact order")
    if parser_contract["scope"].get("additive_format_count") != 7 or parser_contract["scope"].get("effective_format_count") != 15:
        errors.append("parser additive/effective media counts are not 7/15")
    if [item.get("id") for item in parser_contract["formats"]] != expected_media:
        errors.append("parser format definitions differ from the DESIGN.md media order")
    if len(parser_contract["formats"]) != 7 or len(parser_contract["fixtures"]) != 7:
        errors.append("parser formats/fixtures are not exactly seven")
    expected_crate_pins = {
        "html5ever": ("0.39.0", "46a1761807faccc9a19e86944bbf40610014066306f96edcdedc2fb714bcb7b8"),
        "image": ("0.25.10", "85ab80394333c02fe689eaf900ab500fbd0c2213da414687ebf995a65d5a6104"),
    }
    actual_crate_pins = {
        item["name"]: (str(item["version"]), item["package_sha256"])
        for item in parser_contract.get("runtime_bom_additive", {}).get("rust_crates", [])
    }
    if actual_crate_pins != expected_crate_pins:
        errors.append("parser Rust crate versions/package checksums differ from the reviewed exact pins")
    authority_media = yaml_documents.get(ROOT / "authority.yaml", {}).get("scope", {}).get("media", {}).get("additive_exact_ids")
    if authority_media != expected_media:
        errors.append("agent authority media differs from DESIGN.md section 8.4 exact order")
    positive_fixture_ids = {fixture.get("fixture_id") for fixture in parser_contract.get("fixtures", [])}
    matrix = parser_contract.get("capability_fixture_matrix", [])
    if [item.get("format_id") for item in matrix] != expected_media:
        errors.append("parser capability/fixture matrix is not set/order-equal to the media authority")
    for item in matrix:
        if not item.get("parser_capabilities") or not item.get("locator_kinds") or not item.get("runtime_requirement"):
            errors.append(f"{item.get('format_id')}: incomplete parser capability/locator/runtime requirement")
        if not set(item.get("positive_fixture_ids", [])).issubset(positive_fixture_ids):
            errors.append(f"{item.get('format_id')}: capability matrix names an unknown positive fixture")
    negative_fixtures = parser_contract.get("negative_fixture_manifest", {}).get("fixtures", [])
    negative_fixture_ids = {item.get("fixture_id") for item in negative_fixtures}
    if len(negative_fixtures) != 14 or len(negative_fixture_ids) != 14:
        errors.append("parser negative fixture manifest is not exactly fourteen unique cases")
    if any(item.get("source_fixture_id") not in positive_fixture_ids for item in negative_fixtures):
        errors.append("parser negative fixture references an unknown positive source")
    for item in matrix:
        if not set(item.get("negative_fixture_ids", [])).issubset(negative_fixture_ids):
            errors.append(f"{item.get('format_id')}: capability matrix names an unknown negative fixture")
    media_activation = parser_contract.get("runtime_bom_additive", {}).get("media_runtime_activation", {})
    if media_activation.get("state") not in {
        "OPEN_DECISION_BLOCKS_RUNTIME_READY_NOT_CONTRACT_REVIEW",
        "DESIGN_COMPLETE_OPEN_IMPLEMENTATION",
        "FINAL",
    }:
        errors.append(
            "WAV/WebM runtime activation state is neither an explicit blocked design state nor FINAL"
        )
    if parser_contract.get("status") == "FINAL" and media_activation.get("state") != "FINAL":
        errors.append("FINAL parser contract cannot retain an open WAV/WebM runtime activation")
    for fixture in parser_contract["fixtures"]:
        source = fixture["source"]
        try:
            payload = base64.b64decode("".join(source["payload_base64"].split()), validate=True)
        except Exception as exc:
            errors.append(f"{fixture['fixture_id']}: invalid base64: {exc}")
            continue
        if len(payload) != source["byte_length"]:
            errors.append(f"{fixture['fixture_id']}: byte length mismatch")
        if hashlib.sha256(payload).hexdigest() != source["sha256"]:
            errors.append(f"{fixture['fixture_id']}: SHA-256 mismatch")
        if fixture.get("format_id") == "wav":
            if not (payload.startswith(b"RIFF") and payload[8:12] == b"WAVE" and b"fmt " in payload[:64] and b"data" in payload[:64]):
                errors.append(f"{fixture['fixture_id']}: invalid deterministic RIFF/WAVE structure")
            data_offset = payload.find(b"data")
            if data_offset < 0 or any(payload[data_offset + 8 :]):
                errors.append(f"{fixture['fixture_id']}: WAV silence payload contains nonzero sample bytes")
        if fixture.get("format_id") == "webm":
            if not payload.startswith(bytes.fromhex("1a45dfa3")) or b"webm" not in payload or b"V_VP8" not in payload:
                errors.append(f"{fixture['fixture_id']}: invalid deterministic WebM/VP8 structure")
            if b"A_OPUS" in payload or b"A_VORBIS" in payload:
                errors.append(f"{fixture['fixture_id']}: no-audio WebM fixture unexpectedly declares audio")
    feature = ACCEPTANCE.read_text(encoding="utf-8")
    scenario_ids = re.findall(r"scenario-id:\s*([A-Z0-9_-]+)", feature)
    if len(scenario_ids) != 26 or len(set(scenario_ids)) != 26:
        errors.append("acceptance feature does not contain exactly 26 unique scenario IDs")

    result = {
        "schemas": len(schemas),
        "schema_instance_fixtures": schema_instance_count,
        "yaml_documents": len(yaml_documents),
        "tool_pairs": len(tool_pairs),
        "positive_examples": positive_count,
        "negative_examples": negative_count,
        "parser_formats": len(parser_contract["formats"]),
        "embedded_fixtures": len(parser_contract["fixtures"]),
        "negative_media_fixtures": len(negative_fixtures),
        "acceptance_scenarios": len(scenario_ids),
        "errors": errors,
        "result": "PASS" if not errors else "FAIL",
    }
    rendered = json.dumps(result, ensure_ascii=False, indent=2)
    print(rendered)
    if args.json_output:
        args.json_output.write_text(rendered + "\n", encoding="utf-8")
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
