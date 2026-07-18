from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any
import re

from .loaders import load_yaml
from .models import Validation


def nonempty(value: Any) -> bool:
    if isinstance(value, str):
        return bool(value.strip()) and value.strip().upper() not in {"TBD", "TODO"}
    if isinstance(value, list):
        return bool(value) and all(nonempty(item) for item in value)
    if isinstance(value, dict):
        return bool(value) and all(
            nonempty(key) and nonempty(item) for key, item in value.items()
        )
    return value is not None


def contains_forbidden_marker(value: Any) -> bool:
    if isinstance(value, str):
        upper = value.strip().upper()
        return bool(
            re.fullmatch(
                r"(?:\[)?(?:UNRESOLVED|TBD|TODO)(?:\])?(?::.*)?",
                upper,
            )
        )
    if isinstance(value, list):
        return any(contains_forbidden_marker(item) for item in value)
    if isinstance(value, dict):
        return any(
            contains_forbidden_marker(key) or contains_forbidden_marker(item)
            for key, item in value.items()
        )
    return False


def valid_physical_grants(value: Any) -> bool:
    if isinstance(value, list):
        return bool(value) and all(nonempty(item) for item in value)
    if not isinstance(value, dict) or not value:
        return False
    if not all(
        isinstance(key, str) and key.strip() and item is not None
        for key, item in value.items()
    ):
        return False
    # An empty role privilege list is an explicit deny. At least one positive
    # grant, mutation-function contract, or explanatory rule must still exist.
    return any(
        (isinstance(item, str) and bool(item.strip()))
        or (isinstance(item, list) and bool(item))
        or (isinstance(item, dict) and bool(item))
        for item in value.values()
    )


def valid_physical_rls(value: Any) -> bool:
    if not isinstance(value, dict) or not isinstance(value.get("enabled"), bool):
        return False
    if "forced" in value and not isinstance(value["forced"], bool):
        return False
    policies = value.get("policies", [])
    if not isinstance(policies, list):
        return False
    if value["enabled"]:
        return bool(policies) and all(
            isinstance(policy, dict)
            and nonempty(policy.get("name"))
            and nonempty(policy.get("roles"))
            and nonempty(policy.get("using"))
            for policy in policies
        )
    return nonempty(value.get("reason", value.get("rationale")))


def state_tokens(value: Any) -> set[str]:
    if isinstance(value, str):
        return {token for token in value.split("|") if token}
    if isinstance(value, list):
        return {str(token) for token in value}
    return set()


def collect_versioned_refs(value: Any) -> set[str]:
    if isinstance(value, str):
        return {
            token
            for token in re.findall(r"[A-Z][A-Za-z0-9]*V[1-9][0-9]*", value)
            if not re.fullmatch(r"SEV[0-3]", token)
        }
    if isinstance(value, list):
        return set().union(*(collect_versioned_refs(item) for item in value), set())
    if isinstance(value, dict):
        return set().union(
            *(
                collect_versioned_refs(key) | collect_versioned_refs(item)
                for key, item in value.items()
            ),
            set(),
        )
    return set()


def all_derived_markers(value: Any) -> bool:
    if isinstance(value, str):
        return value.startswith("derived ")
    if isinstance(value, dict):
        return bool(value) and all(all_derived_markers(item) for item in value.values())
    return False


def physical_table_rows(document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    raw = document.get("tables", document.get("table_contracts", {}))
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, list):
        return {row["relation"]: row for row in raw}
    return {}


def unique_string_registry(
    value: Any,
    result: Validation,
    label: str,
) -> list[str]:
    if not isinstance(value, list):
        result.error(f"{label} must be an enumerated list")
        return []
    rows = [item for item in value if isinstance(item, str) and item.strip()]
    result.require(
        len(rows) == len(value),
        f"{label} contains a non-string or empty identifier",
    )
    result.require(
        len(rows) == len(set(rows)),
        f"{label} contains duplicate identifiers",
    )
    return rows


def keyed_registry(
    value: Any,
    key: str,
    result: Validation,
    label: str,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    if not isinstance(value, list):
        result.error(f"{label} must be an enumerated row list")
        return [], {}
    rows: list[dict[str, Any]] = []
    registry: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            result.error(f"{label}[{index}] is not a mapping")
            continue
        identifier = item.get(key)
        if not isinstance(identifier, str) or not identifier.strip():
            result.error(f"{label}[{index}] has no nonempty {key}")
            continue
        rows.append(item)
        if identifier in registry:
            result.error(f"{label} contains duplicate {key} {identifier}")
            continue
        registry[identifier] = item
    result.require(
        len(rows) == len(value) == len(registry),
        f"{label} is not a unique keyed registry",
    )
    return rows, registry


def physical_migration_name(document: dict[str, Any]) -> str | None:
    candidates = [
        document.get("migration"),
        document.get("scope", {}).get("migration")
        if isinstance(document.get("scope"), dict)
        else None,
    ]
    for candidate in candidates:
        if isinstance(candidate, str) and candidate.strip():
            return candidate
        if isinstance(candidate, dict):
            identifier = candidate.get("id")
            if isinstance(identifier, str) and identifier.strip():
                return identifier
    return None


def declared_fragment_relations(document: dict[str, Any]) -> list[str] | None:
    scope = document.get("scope")
    migration = document.get("migration")
    candidates = [
        document.get("exact_relations"),
        scope.get("exact_relations") if isinstance(scope, dict) else None,
        scope.get("relations") if isinstance(scope, dict) else None,
        migration.get("additive_tables") if isinstance(migration, dict) else None,
    ]
    for candidate in candidates:
        if isinstance(candidate, list):
            return candidate
    return None


def markdown_table_first_column(text: str, header: str) -> list[str]:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        cells = _markdown_cells(line)
        if not cells or cells[0] != header:
            continue
        if index + 1 >= len(lines) or not _markdown_separator(lines[index + 1]):
            return []
        values: list[str] = []
        for row_line in lines[index + 2 :]:
            row_cells = _markdown_cells(row_line)
            if not row_cells:
                break
            values.append(row_cells[0].strip("`"))
        return values
    return []


def _markdown_cells(line: str) -> list[str]:
    if not line.lstrip().startswith("|") or not line.rstrip().endswith("|"):
        return []
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def _markdown_separator(line: str) -> bool:
    cells = _markdown_cells(line)
    return bool(cells) and all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells)


@dataclass(frozen=True)
class DesignDocuments:
    root: Path
    result: Validation
    design: str
    addendum: dict[str, Any]
    operation_contracts: dict[str, Any]
    command_semantics: dict[str, Any]
    state_machines: dict[str, Any]
    event_contracts: dict[str, Any]
    persistence_contracts: dict[str, Any]
    base_operation_catalog: dict[str, Any]
    base_event_catalog: dict[str, Any]
    role_contract: dict[str, Any]
    production_topology: dict[str, Any]
    base_schema_catalog: dict[str, Any]
    navigation_contracts: dict[str, Any]
    component_catalog: dict[str, Any]
    section_surface_overrides: dict[str, Any]
    approval_policy: dict[str, Any]
    business_model: dict[str, Any]
    journey_contracts: dict[str, Any]
    journey_ui_contracts: dict[str, Any]
    screen_action_contracts: dict[str, Any]
    screen_catalog: dict[str, Any]
    resource_error_contracts: dict[str, Any]
    base_error_catalog: dict[str, Any]
    closure: dict[str, Any]
    domain: dict[str, Any]
    conflicts: str
    prompt: str
    status: str
    expert_roles: dict[str, Any]
    persistence_global: dict[str, Any]
    physical_table_documents: dict[str, dict[str, Any]]


def load_design_documents(root: Path, result: Validation) -> DesignDocuments:
    persistence_global = load_yaml(root / "specs/database/addendum/global.yaml")
    physical_table_paths = tuple(
        persistence_global["relation_inventory"]["derivation_sources"][
            "physical_fragments"
        ]
    )
    result.require(
        bool(physical_table_paths)
        and len(physical_table_paths) == len(set(physical_table_paths))
        and all(
            isinstance(path, str)
            and path.startswith("specs/database/addendum/")
            and path.endswith(".yaml")
            for path in physical_table_paths
        ),
        "global physical fragment registry is empty, duplicated or outside the database addendum",
    )
    return DesignDocuments(
        root=root,
        result=result,
        design=(root / "DESIGN.md").read_text(encoding="utf-8"),
        addendum=load_yaml(root / "specs/product/owner-addendum-2026-07-14.yaml"),
        operation_contracts=load_yaml(
            root / "specs/product/addendum-operation-contracts.yaml"
        ),
        command_semantics=load_yaml(
            root / "specs/product/addendum-command-semantics.yaml"
        ),
        state_machines=load_yaml(root / "specs/product/addendum-state-machines.yaml"),
        event_contracts=load_yaml(root / "specs/product/addendum-event-contracts.yaml"),
        persistence_contracts=load_yaml(
            root / "specs/product/addendum-persistence-contracts.yaml"
        ),
        base_operation_catalog=load_yaml(root / "specs/api/operation-contracts.yaml"),
        base_event_catalog=load_yaml(root / "specs/events/event-catalog.yaml"),
        role_contract=load_yaml(root / "specs/ui/roles-and-permissions.yaml"),
        production_topology=load_yaml(root / "specs/deployment/production-topology.yaml"),
        base_schema_catalog=load_yaml(root / "specs/database/schema-catalog.yaml"),
        navigation_contracts=load_yaml(
            root / "specs/ui/navigation-action-contracts.yaml"
        ),
        component_catalog=load_yaml(root / "specs/ui/component-catalog.yaml"),
        section_surface_overrides=load_yaml(
            root / "specs/ui/section-surface-overrides.yaml"
        ),
        approval_policy=load_yaml(root / "specs/product/addendum-approval-policy.yaml"),
        business_model=load_yaml(root / "specs/product/business-model-contract.yaml"),
        journey_contracts=load_yaml(
            root / "specs/product/addendum-journey-contracts.yaml"
        ),
        journey_ui_contracts=load_yaml(
            root / "specs/ui/journey-graph-contracts.yaml"
        ),
        screen_action_contracts=load_yaml(
            root / "specs/ui/screen-action-contracts.yaml"
        ),
        screen_catalog=load_yaml(root / "specs/ui/screen-catalog.yaml"),
        resource_error_contracts=load_yaml(
            root / "specs/product/addendum-resource-error-contracts.yaml"
        ),
        base_error_catalog=load_yaml(root / "specs/api/error-code-catalog.yaml"),
        closure=load_yaml(root / "implementation-evidence/design-screen-closure.yaml"),
        domain=load_yaml(root / "implementation-evidence/design-domain-closure.yaml"),
        conflicts=(root / "implementation-evidence/spec-conflicts.md").read_text(
            encoding="utf-8"
        ),
        prompt=(root / "implementation-evidence/expert-review-prompt.md").read_text(
            encoding="utf-8"
        ),
        status=(root / "implementation-evidence/expert-review-status.md").read_text(
            encoding="utf-8"
        ),
        expert_roles=load_yaml(
            root / "implementation-evidence/expert-review-roles.yaml"
        ),
        persistence_global=persistence_global,
        physical_table_documents={
            path: load_yaml(root / path) for path in physical_table_paths
        },
    )
