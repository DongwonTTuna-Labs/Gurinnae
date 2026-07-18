#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from typing import Any
import re

import yaml

ROOT = Path(__file__).resolve().parents[1]


class NoAliasDumper(yaml.SafeDumper):
    def ignore_aliases(self, data: Any) -> bool:
        return True


def load(relative: str) -> dict[str, Any]:
    value = yaml.safe_load((ROOT / relative).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{relative} must contain an object")
    return value


def field_paths(
    schema_name: str,
    schemas: dict[str, dict[str, Any]],
    depth: int = 0,
    prefix: str | None = None,
) -> list[str]:
    if depth > 2 or schema_name not in schemas:
        return [prefix or schema_name]
    schema = schemas[schema_name]
    ref = schema.get("$ref")
    if isinstance(ref, str):
        return field_paths(ref.rsplit("/", 1)[-1], schemas, depth + 1, prefix)
    paths: list[str] = []
    properties = schema.get("properties", {})
    if not isinstance(properties, dict):
        return [prefix or schema_name]
    for name, node in properties.items():
        path = f"{prefix or schema_name}.{name}"
        if not isinstance(node, dict):
            paths.append(path)
            continue
        node_ref = node.get("$ref")
        if isinstance(node_ref, str):
            paths.extend(
                field_paths(node_ref.rsplit("/", 1)[-1], schemas, depth + 1, path)
            )
            continue
        item = node.get("items")
        if isinstance(item, dict) and isinstance(item.get("$ref"), str):
            paths.extend(
                field_paths(
                    item["$ref"].rsplit("/", 1)[-1],
                    schemas,
                    depth + 1,
                    f"{path}[]",
                )
            )
            continue
        paths.append(path)
    return sorted(set(paths)) or [prefix or schema_name]


def selected_fields(paths: list[str], terms: tuple[str, ...]) -> list[str]:
    selected = [path for path in paths if any(term in path.lower() for term in terms)]
    return selected[:12] if selected else paths[:6]


def section_for(screen: dict[str, Any], terms: tuple[str, ...]) -> str:
    sections = screen.get("sections", [])
    for section in sections:
        text = " ".join(
            str(section.get(key, "")) for key in ("id", "title", "purpose", "component")
        ).lower()
        if any(term in text for term in terms):
            return str(section["id"])
    if not sections:
        raise ValueError(f"{screen['id']} has no sections")
    return str(sections[0]["id"])


def operation_sources(screen: dict[str, Any], schemas: dict[str, dict[str, Any]]) -> list[str]:
    sources: list[str] = []
    for requirement in screen.get("data_requirements", []):
        response = requirement.get("response_schema")
        if isinstance(response, str):
            sources.extend(field_paths(response, schemas))
    return sorted(set(sources))


def critical_tasks(screen_id: str) -> list[str]:
    mapping = {
        "public-case": {"PUB-004", "PUB-006"},
        "search": {"PUB-002", "INT-003"},
        "investigation": {"SIG-002", "CAS-002", "CAS-004", "CAS-011"},
        "approval": {"REV-002", "REV-003", "OPS-006"},
        "response": {"RSP-002", "RSP-003", "RSP-004", "RSP-005", "RSP-006"},
        "return-visit": {"PUB-004", "INT-001", "CAS-002"},
    }
    return [task for task, ids in mapping.items() if screen_id in ids]


def route_object(route: str, title: str) -> str:
    parameters = [segment[1:-1] for segment in route.split("/") if segment.startswith("{")]
    if parameters:
        return f"{title} ({', '.join(parameters)})"
    return title


SENSITIVE_SOURCE_TERMS = (
    "token",
    "secret",
    "password",
    "assertion",
    "proof",
    "credential",
    "rawbody",
    "raw_body",
)


COMPONENT_SOURCE_TERMS: dict[str, tuple[str, ...]] = {
    "StatusAndRevisionHeader": ("status", "state", "revision", "version", "updated", "fresh"),
    "KnownUnknownResponse": ("known", "unknown", "response", "limitation", "blocker"),
    "EvidenceLedger": ("evidence", "source", "locator", "citation", "digest"),
    "RevisionTimeline": ("revision", "timeline", "event", "updated", "created"),
    "DataCollection": ("item", "count", "title", "status", "id"),
    "UnifiedSearch": ("item", "match", "filter", "query", "title", "count"),
    "DecisionReviewPanel": ("decision", "review", "reason", "blocker", "receipt"),
    "DecisionReceipt": ("receipt", "status", "accepted", "decision", "id"),
    "CheckAnswers": ("answer", "attachment", "consent", "summary", "response"),
    "FileUploadQueue": ("attachment", "file", "scan", "status", "id"),
    "SaveStatus": ("saved", "version", "updated", "status"),
    "StepIndicator": ("step", "status", "completed"),
    "SensitiveDataNotice": ("classification", "consent", "privacy", "scope", "status"),
    "OperationsStatusPanel": ("health", "status", "incident", "queue", "fresh"),
}


def section_source_fields(
    screen: dict[str, Any],
    section: dict[str, Any],
    all_fields: list[str],
    resolved_component: str,
) -> list[str]:
    safe_fields = [
        field
        for field in all_fields
        if not any(term in field.replace("_", "").lower() for term in SENSITIVE_SOURCE_TERMS)
    ]
    terms = COMPONENT_SOURCE_TERMS.get(resolved_component, ()) + (
        str(section["id"]).replace("-", "").lower(),
    )
    matches = [
        field
        for field in safe_fields
        if any(term and term in field.replace("_", "").lower() for term in terms)
    ]
    if matches:
        return sorted(set(matches))[:12]
    if safe_fields:
        offset = (int(section["order"]) - 1) % len(safe_fields)
        rotated = safe_fields[offset:] + safe_fields[:offset]
        return sorted(set(rotated[: min(6, len(rotated))]))
    screen_key = str(screen["id"]).lower().replace("-", "_")
    section_key = str(section["id"]).replace("-", "_")
    return [
        f"VersionedContent.{screen_key}.{section_key}.heading",
        f"VersionedContent.{screen_key}.{section_key}.body",
        f"VersionedContent.{screen_key}.{section_key}.effectiveAt",
    ]


def choose_variant(component: dict[str, Any], surface: str) -> str:
    variants = component["variants"]
    preferences = {
        "public": ("public", "public-record", "policy", "cards", "full", "default"),
        "response": ("response", "form", "linear", "autosave", "privacy", "default"),
        "internal": ("internal", "workspace", "audit-linked", "full", "dense", "default"),
    }[surface]
    return next((variant for variant in preferences if variant in variants), variants[0])


def human_consequence(
    screen: dict[str, Any],
    action: dict[str, Any],
    operation_by_id: dict[str, dict[str, Any]],
    navigation_by_key: dict[str, dict[str, Any]],
    catalog_by: dict[str, dict[str, Any]],
) -> str:
    interaction = action["interaction_kind"]
    operation_id = action.get("operation_id")
    navigation = navigation_by_key.get(f"{screen['id']}.{action['id']}")
    if interaction == "NAVIGATION" and navigation:
        target = navigation["target"]
        if isinstance(target, dict) and target.get("screen_id") in catalog_by:
            destination = catalog_by[target["screen_id"]]
            return f"{destination['title']}로 이동해 {destination['primary_job']}"
        return "선택한 항목의 권한 있는 작업 화면으로 이동하며 현재 목록과 돌아올 위치를 보존한다."
    if operation_id:
        operation = operation_by_id[operation_id]
        purpose = operation.get("purpose")
        if isinstance(purpose, list) and purpose:
            purpose_text = str(purpose[0])
        elif isinstance(purpose, str):
            purpose_text = purpose
        else:
            purpose_text = action["label"]
        return f"{purpose_text} 요청을 제출하고 저장된 결과 상태와 영수증을 확인한다."
    if interaction == "DOWNLOAD":
        return "현재 revision에 고정된 파일을 생성해 파일명, 형식, 크기와 checksum을 확인한 뒤 다운로드한다."
    if interaction == "EXTERNAL_LINK":
        return "허용된 공식 출처를 새 창에서 열고 현재 화면과 출처 경고를 유지한다."
    if interaction == "FORM_SUBMIT":
        return "입력 검증을 통과한 내용을 제출하고 접수 영수증 또는 연결된 오류로 이동한다."
    if "검색" in action["label"] or "필터" in action["label"]:
        return "현재 조건을 URL에 반영하고 첫 결과 페이지를 다시 불러오며 결과 제목으로 초점을 옮긴다."
    if "파일" in action["label"]:
        return "로컬 파일 선택기를 열되 별도 업로드 요청 전에는 서버로 전송하지 않는다."
    if "시도" in action["label"]:
        return "실패한 읽기 요청만 안전하게 다시 시도하고 기존 내용과 초점을 보존한다."
    return "현재 화면의 선택 상태를 갱신하고 변경된 영역을 한 번 알린다."


def main() -> None:
    catalog = load("specs/ui/screen-catalog.yaml")
    manifest = load("specs/ui/screen-build-manifest.yaml")
    archetypes = load("specs/ui/page-archetypes.yaml")
    resources = load("specs/api/resource-schemas.yaml")
    operation_catalog = load("specs/api/operation-contracts.yaml")
    addendum = load("specs/product/owner-addendum-2026-07-14.yaml")
    addendum_operations = load("specs/product/addendum-operation-contracts.yaml")
    navigation_contracts = load("specs/ui/navigation-action-contracts.yaml")
    component_catalog = load("specs/ui/component-catalog.yaml")
    surface_overrides = load("specs/ui/section-surface-overrides.yaml")
    search_contract = addendum.get("search_and_provenance_contract", {})
    typed_slices = search_contract.get("screen_typed_slices", {})
    ten_second_sections = search_contract.get("screen_ten_second_sections", {})
    route_contract = addendum.get("route_contract", {})
    route_aliases = route_contract.get("parameter_aliases", {})
    operation_by_id = {
        operation["operation_id"]: operation
        for operation in operation_catalog.get("operations", [])
    }
    additive_operation_by_id = {
        operation["operation_id"]: operation
        for operation in addendum_operations.get("operations", [])
    }
    operation_by_id.update(additive_operation_by_id)
    additive_bindings_by_screen: dict[str, dict[str, list[str]]] = {}
    for operation_id, references in addendum_operations.get(
        "operation_screen_bindings", {}
    ).items():
        for reference in references:
            screen_id, separator, section_id = reference.partition(".")
            if not separator:
                raise ValueError(f"invalid additive operation screen binding: {reference}")
            additive_bindings_by_screen.setdefault(screen_id, {}).setdefault(
                operation_id, []
            ).append(section_id)
    resource_entries = resources.get("resources", {})
    if not isinstance(resource_entries, dict):
        raise ValueError("resource-schemas.yaml resources must be an object")
    schema_map = {
        name: entry["schema"]
        for name, entry in resource_entries.items()
        if isinstance(entry, dict) and isinstance(entry.get("schema"), dict)
    }
    manifest_by = {screen["id"]: screen for screen in manifest["screens"]}
    catalog_by = {screen["id"]: screen for screen in catalog["screens"]}
    component_by_id = {
        component["id"]: component for component in component_catalog["components"]
    }
    navigation_by_key = navigation_contracts["navigation_contracts"]
    surface_override_by_key = surface_overrides["overrides"]
    semantic_override_by_key = surface_overrides.get("semantic_overrides", {})
    if set(surface_override_by_key) & set(semantic_override_by_key):
        raise ValueError("surface and semantic component override registries overlap")
    surface_override_by_key = {
        **surface_override_by_key,
        **semantic_override_by_key,
    }
    profiles = archetypes["state_profiles"]
    rows: list[dict[str, Any]] = []

    for screen in catalog["screens"]:
        screen_id = screen["id"]
        built = manifest_by[screen_id]
        screen_additive_bindings = additive_bindings_by_screen.get(screen_id, {})
        fields = operation_sources(screen, schema_map)
        actions = screen.get("actions", [])
        primary_id = screen.get("primary_action_id")
        primary = next((action for action in actions if action["id"] == primary_id), None)
        if primary is None and actions:
            primary = actions[0]
        primary_contract: dict[str, Any]
        if primary is None:
            primary_contract = {
                "id": "NONE",
                "reason": "읽기 전용·정책·영수증 또는 system 상태 화면이므로 상태 변경 행동을 만들지 않는다.",
                "information_owner": "화면에 표시된 담당 기능",
                "refresh_slo": "해당 화면의 freshness 또는 effective date 계약",
            }
        else:
            operation = primary.get("operation_id")
            primary_contract = {
                "id": primary["id"],
                "label": primary["label"],
                "operation_id": operation,
                "interaction_kind": primary["interaction_kind"],
                "capability": primary.get("capability", "none"),
                "assurance_level": primary["assurance_level"],
                "consequence": human_consequence(
                    screen,
                    primary,
                    operation_by_id,
                    navigation_by_key,
                    catalog_by,
                ),
            }

        route_parameters = re.findall(r"\{([^}]+)\}", screen["route"])
        screen_operation_ids = {
            requirement["operation_id"]
            for requirement in screen.get("data_requirements", [])
        } | {
            action["operation_id"]
            for action in actions
            if isinstance(action.get("operation_id"), str)
        } | set(screen_additive_bindings)
        route_bindings: list[dict[str, Any]] = []
        for route_parameter in route_parameters:
            alias = route_aliases.get(screen_id, {}).get(route_parameter)
            request_parameter = (
                alias["operation_parameter"] if isinstance(alias, dict) else route_parameter
            )
            targets: list[dict[str, Any]] = []
            for operation_id in sorted(screen_operation_ids):
                operation = operation_by_id.get(operation_id)
                if not operation:
                    continue
                request_fields = {
                    field["name"]
                    for field in operation.get("request_fields", [])
                    if isinstance(field, dict) and isinstance(field.get("name"), str)
                }
                additive_request = operation.get("request", {})
                if isinstance(additive_request, dict):
                    request_fields.update(additive_request.get("required", []))
                    additive_fields = additive_request.get("fields", {})
                    if isinstance(additive_fields, dict):
                        request_fields.update(additive_fields)
                if request_parameter in request_fields:
                    targets.append(
                        {
                            "operation_id": operation_id,
                            "request_field": request_parameter,
                            "binding": "verified-alias-resolution" if alias else "direct",
                        }
                    )
            if not targets and not alias:
                for requirement in screen.get("data_requirements", []):
                    response_schema = requirement.get("response_schema")
                    if not isinstance(response_schema, str):
                        continue
                    matching_paths = [
                        path
                        for path in field_paths(response_schema, schema_map)
                        if path.rsplit(".", 1)[-1].replace("[]", "").lower()
                        == route_parameter.lower()
                    ]
                    for path in matching_paths:
                        targets.append(
                            {
                                "operation_id": requirement["operation_id"],
                                "response_field": path,
                                "binding": "loaded-object-identity-assertion",
                            }
                        )
            if route_parameter == "systemPath" and not targets:
                targets.append(
                    {
                        "operation_id": "LOCAL_SYSTEM_ROUTE_RESOLVER",
                        "request_field": "systemPath",
                        "binding": "direct-local",
                    }
                )
            if not targets:
                raise ValueError(
                    f"{screen_id}: route parameter {route_parameter} has no typed operation target"
                )
            route_bindings.append(
                {
                    "route_parameter": route_parameter,
                    "source": f"params.{route_parameter}",
                    "type": alias.get("type", "authority-request-field") if alias else "authority-request-field",
                    "resolver": alias.get("resolver") if alias else None,
                    "targets": targets,
                }
            )

        state_section = section_for(screen, ("status", "state", "header", "current", "identity"))
        evidence_section = section_for(
            screen,
            ("evidence", "source", "reference", "citation", "comparison", "record", "body"),
        )
        unknown_section = section_for(
            screen,
            ("unknown", "block", "gap", "limitation", "response", "risk", "coverage", "impact"),
        )
        matters_section = str(screen["sections"][0]["id"])
        state_fields = selected_fields(
            fields,
            ("status", "state", "fresh", "updated", "version", "asof", "owner", "due"),
        )
        matter_fields = selected_fields(
            fields,
            ("title", "summary", "description", "reason", "impact", "count", "metric"),
        )
        evidence_fields = selected_fields(
            fields,
            ("evidence", "source", "locator", "citation", "claim", "provenance", "record"),
        )
        unknown_fields = selected_fields(
            fields,
            ("unknown", "block", "gap", "limit", "response", "conflict", "error", "risk"),
        )
        base_operation_entries = [
            {
                "source": "v13-authority",
                "operation_id": requirement["operation_id"],
                "api": requirement["api"],
                "method": requirement["method"],
                "path": requirement["path"],
                "kind": "QUERY" if requirement["method"] == "GET" else "COMMAND",
                "blocking": requirement["blocking"],
                "request_schema": requirement["request_schema"],
                "response_schema": requirement["response_schema"],
                "section_bindings": [],
            }
            for requirement in screen.get("data_requirements", [])
        ]
        additive_operation_entries = [
            {
                "source": "owner-addendum",
                "operation_id": operation_id,
                "api": additive_operation_by_id[operation_id]["api"],
                "method": additive_operation_by_id[operation_id]["method"],
                "path": additive_operation_by_id[operation_id]["path"],
                "kind": additive_operation_by_id[operation_id]["kind"],
                "blocking": additive_operation_by_id[operation_id]["kind"] == "QUERY",
                "request_contract": additive_operation_by_id[operation_id]["request"],
                "response_schema": additive_operation_by_id[operation_id]["response"],
                "section_bindings": sorted(set(section_ids)),
            }
            for operation_id, section_ids in sorted(screen_additive_bindings.items())
        ]
        built_section_by_id = {
            section["id"]: section for section in built["section_order"]
        }
        section_mappings: list[dict[str, Any]] = []
        for section in screen["sections"]:
            qualified_section = f"{screen_id}.{section['id']}"
            override = surface_override_by_key.get(qualified_section)
            resolved_component = (
                override["component"] if override else section["component"]
            )
            component_contract = component_by_id[resolved_component]
            resolved_variant = (
                override["variant"]
                if override
                else choose_variant(component_contract, screen["surface"])
            )
            section_mappings.append(
                {
                    "order": section["order"],
                    "id": section["id"],
                    "surface": screen["surface"],
                    "semantic_region": section["id"],
                    "authority_component_contract": section["component"],
                    "component_contract": resolved_component,
                    "component_variant": resolved_variant,
                    "surface_resolution": (
                        {
                            "kind": "OWNER_ADDENDUM_OVERRIDE",
                            "reason": override["reason"],
                        }
                        if override
                        else {"kind": "AUTHORITY_COMPATIBLE"}
                    ),
                    "typed_slice": f"{screen_id.lower().replace('-', '_')}.{section['id'].replace('-', '_')}",
                    "source_fields": section_source_fields(
                        screen, section, fields, resolved_component
                    ),
                    "source_classification": "DISPLAY_SAFE_ALLOWLIST",
                    "heading_level": 2,
                    "landmark": "region" if section["priority"] == "primary" else "group",
                    "test_id": built_section_by_id[section["id"]]["test_id"],
                    "additive_query_operations": sorted(
                        operation_id
                        for operation_id, section_ids in screen_additive_bindings.items()
                        if section["id"] in section_ids
                        and additive_operation_by_id[operation_id]["kind"] == "QUERY"
                    ),
                    "additive_command_operations": sorted(
                        operation_id
                        for operation_id, section_ids in screen_additive_bindings.items()
                        if section["id"] in section_ids
                        and additive_operation_by_id[operation_id]["kind"] == "COMMAND"
                    ),
                }
            )
        action_contracts = [
            {
                "action_id": action["id"],
                "label": action["label"],
                "interaction_kind": action["interaction_kind"],
                "operation_id": action.get("operation_id"),
                "capability": action.get("capability", "none"),
                "assurance_level": action["assurance_level"],
                "step_up_required": action["step_up_required"],
                "confirmation_required": action["confirmation_required"],
                "consequence": human_consequence(
                    screen,
                    action,
                    operation_by_id,
                    navigation_by_key,
                    catalog_by,
                ),
                "test_id": f"{screen['test_id_prefix']}__action__{action['id'].replace('-', '_')}",
            }
            for action in actions
        ]
        navigation_actions = [
            {
                "action_id": action["id"],
                "label": action["label"],
                "contract": navigation_by_key[f"{screen_id}.{action['id']}"],
            }
            for action in actions
            if action["interaction_kind"] == "NAVIGATION"
        ]
        section_by_id = {section["id"]: section for section in screen["sections"]}

        row = {
            "screen_id": screen_id,
            "surface": screen["surface"],
            "route": screen["route"],
            "persona": screen["primary_users"],
            "job": screen["primary_job"],
            "canonical_object": route_object(screen["route"], screen["title"]),
            "route_parameter_bindings": route_bindings,
            "ten_second_contract": {
                "location": {
                    "section": matters_section,
                    "answer_pattern": f"{screen['title']} — {screen['primary_job']}",
                    "sources": ["route.params", "screen title", "authorized object identity"],
                },
                "state": {
                    "section": state_section,
                    "answer_pattern": (
                        f"{screen['title']}의 {section_by_id[state_section]['title']}에서 "
                        f"{section_by_id[state_section]['purpose']} 현재 상태, 기준 시각과 마지막 중요 변경을 함께 보여준다."
                    ),
                    "sources": state_fields,
                },
                "matters_now": {
                    "section": matters_section,
                    "answer_pattern": (
                        f"먼저 답할 질문은 ‘{screen['user_questions'][0]}’이며, "
                        f"{section_by_id[matters_section]['title']}에서 {section_by_id[matters_section]['purpose']}"
                    ),
                    "sources": matter_fields,
                },
                "evidence": {
                    "section": evidence_section,
                    "answer_pattern": (
                        f"{section_by_id[evidence_section]['title']}의 {section_by_id[evidence_section]['purpose']}가 "
                        "판단 근거이며 각 항목은 출처, revision, exact locator와 검증 상태를 함께 연다."
                    ),
                    "sources": evidence_fields,
                },
                "unknown_or_disputed": {
                    "section": unknown_section,
                    "answer_pattern": (
                        f"{section_by_id[unknown_section]['title']}에서 {section_by_id[unknown_section]['purpose']} 중 "
                        "미확인, 반대 근거, 소명과 제한을 확인된 사실과 분리한다."
                    ),
                    "sources": unknown_fields,
                },
                "next_action": {
                    "section": matters_section,
                    "answer_pattern": (
                        f"{primary_contract.get('label')}: {primary_contract.get('consequence')}"
                        if primary_contract["id"] != "NONE"
                        else "현재 화면은 읽기/영수증/정책 화면이며 상태 변경 행동이 없다."
                    ),
                    "sources": [
                        path
                        for path in fields
                        if any(term in path.lower() for term in ("next", "action", "task", "due", "receipt"))
                    ][:12]
                    or fields[:6],
                },
            },
            "section_mapping": section_mappings,
            "view_model": screen["implementation_files"]["view_model"],
            "state_profile": {
                "name": screen["state_profile"],
                "states": profiles[screen["state_profile"]],
                "special_states": screen.get("special_states", []),
            },
            "primary_action": primary_contract,
            "action_contracts": action_contracts,
            "navigation_actions": navigation_actions,
            "other_actions": [action["id"] for action in actions if primary is None or action["id"] != primary["id"]],
            "responsive": {
                "compact": screen["layout_contract"]["compact"],
                "medium": screen["layout_contract"]["medium"],
                "wide": screen["layout_contract"]["wide"],
                "extra_wide": f"{screen['layout_contract']['wide']}; retain max-width container and reading measure",
                "semantic_order": [section["id"] for section in sorted(screen["sections"], key=lambda value: value["responsive_order"])],
            },
            "focus_contract": {
                "entry": f"skip-link -> {screen['test_id_prefix']}__heading -> {screen['test_id_prefix']}__section__{matters_section.replace('-', '_')}",
                "validation_failure": f"{screen['test_id_prefix']}__error_summary; preserve all valid input and link each field error",
                "dialog": f"contain focus; Escape only when safe; restore {screen['test_id_prefix']}__action__{(primary['id'] if primary else 'none').replace('-', '_')}",
                "success": f"focus {screen['test_id_prefix']}__receipt_or_status_heading only after persisted outcome; background refresh retains active element",
            },
            "analytics_allowlist": screen.get("analytics_events", []),
            "operations": base_operation_entries + additive_operation_entries,
            "critical_task_ids": critical_tasks(screen_id),
            "authority_manifest_test_ids": [
                section["test_id"] for section in built["section_order"]
            ],
        }

        screen_slices = typed_slices.get(screen_id, {})
        screen_sections = ten_second_sections.get(screen_id, {})
        if screen_slices:
            expected_section_ids = {section["id"] for section in screen["sections"]}
            if set(screen_slices) != expected_section_ids:
                raise ValueError(
                    f"{screen_id}: typed source slice keys must equal authoritative sections"
                )
            for section in row["section_mapping"]:
                source_fields = screen_slices[section["id"]]
                if not isinstance(source_fields, list) or not source_fields:
                    raise ValueError(f"{screen_id}.{section['id']}: empty typed source slice")
                section["source_fields"] = source_fields
            for question, section_id in screen_sections.items():
                if question not in row["ten_second_contract"]:
                    raise ValueError(f"{screen_id}: unknown ten-second question {question}")
                if section_id not in screen_slices:
                    raise ValueError(f"{screen_id}: unknown typed source section {section_id}")
                answer = row["ten_second_contract"][question]
                answer["section"] = section_id
                if question != "location":
                    answer["sources"] = screen_slices[section_id]
            row["typed_source_contract"] = "owner-addendum.search_and_provenance_contract"
        rows.append(row)

    if len(rows) != 94 or {row["screen_id"] for row in rows} != set(manifest_by):
        raise ValueError("screen closure is not set-equal to the 94-screen authority")

    output = {
        "schema_version": 1,
        "specification_version": "13.1.0-owner-addendum",
        "status": "REVIEW_REQUIRED",
        "generated_from": [
            "specs/ui/screen-catalog.yaml",
            "specs/ui/screen-build-manifest.yaml",
            "specs/ui/page-archetypes.yaml",
            "specs/api/resource-schemas.yaml",
            "specs/product/owner-addendum-2026-07-14.yaml",
            "specs/product/addendum-operation-contracts.yaml",
            "specs/ui/navigation-action-contracts.yaml",
            "specs/ui/component-catalog.yaml",
            "specs/ui/section-surface-overrides.yaml",
        ],
        "screen_count": 94,
        "rules": [
            "Every row is normative and required.",
            "Section IDs and semantic order remain authority ordered.",
            "A typed slice never receives a whole operation response.",
            "Source paths are validated inputs to the screen view-model, not direct DTO rendering.",
            "A blank, TBD, inherited or generic field is invalid.",
        ],
        "screens": rows,
    }
    target = ROOT / "implementation-evidence/design-screen-closure.yaml"
    target.write_text(
        yaml.dump(
            output,
            Dumper=NoAliasDumper,
            sort_keys=False,
            allow_unicode=True,
            width=110,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
