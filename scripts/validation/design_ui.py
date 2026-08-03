from __future__ import annotations
from dataclasses import dataclass
from typing import Any
import hashlib
import json
import re
from .design_lifecycle import LifecycleFacts
from .design_operations import OperationFacts
from .design_support import DesignDocuments, contains_forbidden_marker, nonempty
from .design_ui_operations import (
    design_screen_row,
    validate_additive_operation_section_closure,
    validate_journey_ui,
    validate_section_operations,
)
from .design_ui_tail import validate_ui_tail
from .loaders import load_yaml
@dataclass(frozen=True)
class UiFacts:
    rows: list[dict[str, Any]]
    row_by: dict[str, dict[str, Any]]
    catalog_by: dict[str, dict[str, Any]]


def validate_ui(
    documents: DesignDocuments,
    operations: OperationFacts,
    lifecycle: LifecycleFacts,
) -> UiFacts:
    root, result = documents.root, documents.result
    validate_journey_ui(documents)
    closure = documents.closure
    operation_contracts = documents.operation_contracts
    navigation_contracts = documents.navigation_contracts
    component_catalog = documents.component_catalog
    section_surface_overrides = documents.section_surface_overrides
    search = lifecycle.search
    catalog = load_yaml(root / "specs/ui/screen-catalog.yaml")
    archetypes = load_yaml(root / "specs/ui/page-archetypes.yaml")
    manifest = load_yaml(root / "specs/ui/screen-build-manifest.yaml")
    catalog_by = {screen["id"]: screen for screen in catalog["screens"]}
    manifest_by = {screen["id"]: screen for screen in manifest["screens"]}
    component_by_id = {
        component["id"]: component for component in component_catalog["components"]
    }
    surface_mismatches = {
        f"{screen['id']}.{section['id']}"
        for screen in catalog["screens"]
        for section in screen["sections"]
        if screen["surface"]
        not in component_by_id[section["component"]]["surfaces"]
    }
    result.require(
        set(section_surface_overrides["overrides"]) == surface_mismatches
        and len(surface_mismatches) == 26,
        "section surface override set is not exact",
    )
    navigation_action_keys = {
        f"{screen['id']}.{action['id']}"
        for screen in catalog["screens"]
        for action in screen.get("actions", [])
        if action["interaction_kind"] == "NAVIGATION"
    }
    navigation_rows = navigation_contracts["navigation_contracts"]
    result.require(
        len(navigation_action_keys) == len(navigation_rows) == 109
        and set(navigation_rows) == navigation_action_keys
        and not contains_forbidden_marker(navigation_contracts),
        "navigation action contract set is incomplete or unresolved",
    )
    result.require(
        all(row["status"] == "resolved" for row in navigation_rows.values())
        and len({row["oracle"] for row in navigation_rows.values()}) == 109,
        "navigation action status or oracle identity is invalid",
    )
    for key, navigation in navigation_rows.items():
        target = navigation["target"]
        if isinstance(target, dict) and "screen_id" in target:
            result.require(
                target["screen_id"] in catalog_by
                and target["route"] == catalog_by[target["screen_id"]]["route"],
                f"{key}: navigation target does not match a canonical route",
            )
            route_parameters = set(re.findall(r"\{([^}]+)\}", target["route"]))
            result.require(
                route_parameters == set(navigation.get("bindings", {})),
                f"{key}: navigation route parameter binding set mismatch",
            )
        result.require(
            not {"cursor", "token", "proof", "secret", "password"}
            & {
                str(item).lower()
                for item in navigation.get("preserved_query_keys", [])
            },
            f"{key}: unsafe navigation query preservation",
        )
    operation_screen_bindings = operation_contracts["operation_screen_bindings"]
    result.require(
        set(operation_screen_bindings) == set(operations.operation_ids),
        "addendum operation screen binding set mismatch",
    )
    for operation_id, references in operation_screen_bindings.items():
        result.require(
            bool(references),
            f"{operation_id}: operation screen binding is empty",
        )
        for reference in references:
            screen_id, separator, section_id = reference.partition(".")
            result.require(
                bool(separator) and screen_id in catalog_by,
                f"{operation_id}: invalid screen binding {reference}",
            )
            if screen_id in catalog_by:
                section_ids = {
                    section["id"] for section in catalog_by[screen_id]["sections"]
                }
                result.require(
                    section_id in section_ids,
                    f"{operation_id}: invalid screen section binding {reference}",
                )
    additive_operations_by_screen: dict[str, dict[str, set[str]]] = {}
    for operation_id, references in operation_screen_bindings.items():
        for reference in references:
            screen_id, _, section_id = reference.partition(".")
            additive_operations_by_screen.setdefault(screen_id, {}).setdefault(
                operation_id, set()
            ).add(section_id)
    rows = closure["screens"]
    row_by = {row["screen_id"]: row for row in rows}
    result.require(
        closure["screen_count"] == len(rows) == 95,
        "design screen closure count mismatch",
    )
    result.require(
        len(row_by) == 95 and set(row_by) == set(catalog_by),
        "design screen closure is not set-equal to catalog",
    )
    six = {
        "location",
        "state",
        "matters_now",
        "evidence",
        "unknown_or_disputed",
        "next_action",
    }
    for screen_id, screen in catalog_by.items():
        row = design_screen_row(result, row_by, screen_id)
        if row is None:
            continue
        result.require(
            nonempty(row.get("typed_view_model"))
            and nonempty(row.get("runtime_trace_path"))
            and nonempty(row.get("implementation_source_digest"))
            and isinstance(row.get("implementation_source_sha256"), dict)
            and isinstance(row.get("authority_source_sha256"), dict),
            f"{screen_id}: typed VM, runtime trace, and source digest evidence is missing",
        )
        authority_path = row.get("authority_source_path")
        authority_hashes = row.get("authority_source_sha256", {})
        expected_authority_hash = hashlib.sha256(
            json.dumps(
                screen,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
        ).hexdigest()
        result.require(
            isinstance(authority_path, str)
            and authority_hashes == {authority_path: expected_authority_hash},
            f"{screen_id}: authority source digest does not match the catalog row",
        )
        trace_path = root / row.get("runtime_trace_path", "")
        trace: Any = None
        try:
            trace = json.loads(trace_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            pass
        result.require(
            isinstance(trace, dict)
            and trace.get("screenId") == screen_id
            and trace.get("route") == screen["route"]
            and trace.get("ssrStatus") == 200,
            f"{screen_id}: runtime trace is missing or not bound to the route",
        )
        source_hashes = row.get("implementation_source_sha256", {})
        if isinstance(source_hashes, dict):
            for relative, expected in source_hashes.items():
                source_path = root / str(relative)
                actual = (
                    hashlib.sha256(source_path.read_bytes()).hexdigest()
                    if source_path.is_file()
                    else None
                )
                result.require(
                    actual == expected,
                    f"{screen_id}: implementation source digest mismatch: {relative}",
                )
            result.require(
                hashlib.sha256(
                    json.dumps(source_hashes, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
                ).hexdigest()
                == row["implementation_source_digest"],
                f"{screen_id}: implementation source digest aggregate mismatch",
            )
        result.require(
            row["route"] == screen["route"]
            and row["surface"] == screen["surface"],
            f"{screen_id}: design route/surface mismatch",
        )
        result.require(
            row["view_model"] == screen["implementation_files"]["view_model"],
            f"{screen_id}: design view-model mismatch",
        )
        expected_sections = [
            section["id"]
            for section in sorted(screen["sections"], key=lambda value: value["order"])
        ]
        actual_sections = [section["id"] for section in row["section_mapping"]]
        result.require(
            actual_sections == expected_sections,
            f"{screen_id}: design section order mismatch",
        )
        authority_section_by_id = {
            section["id"]: section for section in screen["sections"]
        }
        manifest_section_by_id = {
            section["id"]: section
            for section in manifest_by[screen_id]["section_order"]
        }
        for section in row["section_mapping"]:
            section_id = section["id"]
            qualified = f"{screen_id}.{section_id}"
            authority_component = authority_section_by_id[section_id]["component"]
            surface_override_rows = section_surface_overrides["overrides"]
            semantic_override_rows = section_surface_overrides.get(
                "semantic_overrides", {}
            )
            result.require(
                not (set(surface_override_rows) & set(semantic_override_rows)),
                "surface and semantic component override registries overlap",
            )
            override = {
                **surface_override_rows,
                **semantic_override_rows,
            }.get(qualified)
            expected_component = (
                override["component"] if override else authority_component
            )
            expected_variant = (
                override["variant"] if override else section["component_variant"]
            )
            component = component_by_id[section["component_contract"]]
            result.require(
                section["authority_component_contract"] == authority_component
                and section["component_contract"] == expected_component
                and section["component_variant"] == expected_variant
                and screen["surface"] in component["surfaces"]
                and section["component_variant"] in component["variants"],
                f"{qualified}: component surface or variant closure mismatch",
            )
            result.require(
                section["test_id"]
                == manifest_section_by_id[section_id]["test_id"]
                and nonempty(section["source_fields"])
                and section["source_classification"] == "DISPLAY_SAFE_ALLOWLIST"
                and not any(
                    any(
                        term in source.replace("_", "").lower()
                        for term in (
                            "token",
                            "secret",
                            "password",
                            "assertion",
                            "credential",
                        )
                    )
                    for source in section["source_fields"]
                ),
                f"{qualified}: section source or test closure is incomplete/unsafe",
            )
            result.require(
                section.get("implementation_source_digest")
                == row.get("implementation_source_digest")
                and section.get("source_fields_digest")
                == hashlib.sha256(
                    json.dumps(
                        section["source_fields"],
                        ensure_ascii=False,
                        sort_keys=True,
                        separators=(",", ":"),
                    ).encode()
                ).hexdigest(),
                f"{qualified}: section implementation/source digest evidence mismatch",
            )
        result.require(
            row["authority_manifest_test_ids"]
            == [
                section["test_id"]
                for section in manifest_by[screen_id]["section_order"]
            ],
            f"{screen_id}: authority section test ID set/order mismatch",
        )
        result.require(
            set(row["ten_second_contract"]) == six,
            f"{screen_id}: six-question contract mismatch",
        )
        for question, answer in row["ten_second_contract"].items():
            result.require(
                answer["section"] in expected_sections,
                f"{screen_id}: {question} section is not authoritative",
            )
            result.require(
                nonempty(answer["answer_pattern"])
                and nonempty(answer["sources"]),
                f"{screen_id}: {question} is incomplete",
            )
        profile = screen["state_profile"]
        result.require(
            row["state_profile"]["name"] == profile
            and row["state_profile"]["states"]
            == archetypes["state_profiles"][profile],
            f"{screen_id}: design state profile mismatch",
        )
        expected_operations = {
            requirement["operation_id"]
            for requirement in screen.get("data_requirements", [])
        } | set(additive_operations_by_screen.get(screen_id, {}))
        result.require(
            {operation["operation_id"] for operation in row["operations"]}
            == expected_operations,
            f"{screen_id}: design operation set mismatch",
        )
        row_operations = {
            operation["operation_id"]: operation for operation in row["operations"]
        }
        validate_additive_operation_section_closure(
            result,
            screen_id,
            row_operations,
            additive_operations_by_screen.get(screen_id, {}),
        )
        validate_section_operations(
            result,
            screen_id,
            row,
            additive_operations_by_screen,
            operations.contracted_operations,
        )
        route_parameters = re.findall(r"\{([^}]+)\}", screen["route"])
        bindings = row.get("route_parameter_bindings", [])
        result.require(
            [binding["route_parameter"] for binding in bindings]
            == route_parameters,
            f"{screen_id}: route parameter binding set/order mismatch",
        )
        for binding in bindings:
            result.require(
                nonempty(binding.get("targets")),
                f"{screen_id}: route binding target missing",
            )
        expected_action_ids = {action["id"] for action in screen.get("actions", [])}
        action_contract_by_id = {
            action["action_id"]: action for action in row["action_contracts"]
        }
        result.require(
            set(action_contract_by_id) == expected_action_ids
            and all(
                nonempty(action["consequence"])
                for action in action_contract_by_id.values()
            ),
            f"{screen_id}: action interaction/consequence closure mismatch",
        )
        expected_navigation = {
            action["id"]
            for action in screen.get("actions", [])
            if action["interaction_kind"] == "NAVIGATION"
        }
        navigation_by_action = {
            action["action_id"]: action for action in row["navigation_actions"]
        }
        result.require(
            set(navigation_by_action) == expected_navigation
            and all(
                action["contract"]
                == navigation_rows[f"{screen_id}.{action_id}"]
                for action_id, action in navigation_by_action.items()
            ),
            f"{screen_id}: embedded navigation closure mismatch",
        )
    validate_ui_tail(result, rows, catalog_by, operations, documents.addendum["route_contract"], search)
    return UiFacts(rows=rows, row_by=row_by, catalog_by=catalog_by)
