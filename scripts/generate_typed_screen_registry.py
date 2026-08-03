#!/usr/bin/env python3
"""Generate the closed route/section UI registry from canonical specifications."""
from pathlib import Path
import json
import re
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[1]
SPECS_ROOT = ROOT / "specs/ui"
source_path = SPECS_ROOT / "screen-catalog.yaml"
manifest_path = SPECS_ROOT / "screen-build-manifest.yaml"
data_contracts_path = SPECS_ROOT / "screen-data-contracts.yaml"
projection_overrides_path = SPECS_ROOT / "screen-projection-overrides.yaml"

source = yaml.safe_load(source_path.read_text())
manifest = yaml.safe_load(manifest_path.read_text())
data_contracts = yaml.safe_load(data_contracts_path.read_text())
projection_overrides = yaml.safe_load(projection_overrides_path.read_text())
operations_by_id = {row["operation_id"]: row for row in data_contracts["operations"]}
manifest_by = {row["id"]: row for row in manifest["screens"]}
rows = source["screens"]
rows_by_id = {row["id"]: row for row in rows}
if len(rows) != 94 or sum(len(row.get("sections", [])) for row in rows) != 497:
    raise SystemExit("screen catalog must contain exactly 94 screens and 497 sections")

def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)

SECTION_FIELD_HINTS = {
    section_id: set(field_names)
    for section_id, field_names in projection_overrides["section_field_hints"].items()
}
SCREEN_SECTION_FIELD_OVERRIDES = {
    screen_id: {
        section_id: set(field_names)
        for section_id, field_names in section_overrides.items()
    }
    for screen_id, section_overrides in projection_overrides[
        "screen_section_field_overrides"
    ].items()
}
SCREEN_SECTION_OPERATION_OVERRIDES = projection_overrides[
    "screen_section_operation_overrides"
]
SURFACE_PERSONAS = projection_overrides["surface_personas"]
DEFAULT_PERSONA = projection_overrides["default_persona"]

def data_operation_ids(row: dict) -> list[str]:
    operation_ids = [item["operation_id"] for item in row.get("data_requirements", [])]
    if not operation_ids:
        raise SystemExit(f"screen {row['id']} has no data operation")
    return operation_ids

def section_operation_id(row: dict, section_id: str) -> str:
    operation_ids = data_operation_ids(row)
    return SCREEN_SECTION_OPERATION_OVERRIDES.get(row["id"], {}).get(
        section_id, operation_ids[0]
    )

def validate_projection_overrides() -> None:
    override_screens = set(SCREEN_SECTION_FIELD_OVERRIDES) | set(
        SCREEN_SECTION_OPERATION_OVERRIDES
    )
    for screen_id in sorted(override_screens):
        row = rows_by_id.get(screen_id)
        if row is None:
            raise SystemExit(f"projection override references unknown screen {screen_id}")
        section_ids = {section["id"] for section in row.get("sections", [])}
        operation_ids = set(data_operation_ids(row))
        field_sections = SCREEN_SECTION_FIELD_OVERRIDES.get(screen_id, {})
        operation_sections = SCREEN_SECTION_OPERATION_OVERRIDES.get(screen_id, {})
        for section_id in sorted(set(field_sections) | set(operation_sections)):
            if section_id not in section_ids:
                raise SystemExit(
                    f"projection override references unknown section {screen_id}:{section_id}"
                )
            operation_id = operation_sections.get(
                section_id, data_operation_ids(row)[0]
            )
            if operation_id not in operation_ids:
                raise SystemExit(
                    f"projection override operation {operation_id} is not declared by "
                    f"{screen_id}:{section_id}"
                )
            operation = operations_by_id.get(operation_id)
            if operation is None:
                raise SystemExit(f"missing data contract for {screen_id}:{operation_id}")
            response_fields = {
                item["name"] for item in operation.get("response_fields", [])
            }
            unknown_fields = set(field_sections.get(section_id, [])) - response_fields
            if unknown_fields:
                raise SystemExit(
                    f"projection override fields are not in {operation_id}: "
                    f"{sorted(unknown_fields)}"
                )

validate_projection_overrides()

def semantic_response_fields(section_id: str, response_fields: list[str]) -> list[str]:
    hints = SECTION_FIELD_HINTS.get(section_id, set())
    tokens = set(filter(None, re.split(r"[-_]", section_id.lower())))
    selected = []
    for field in response_fields:
        lowered = field.lower()
        if field in hints or any(token and token in lowered for token in tokens):
            selected.append(field)
    return selected[:12]

def section_fields(screen_id: str, section_id: str, response_fields: list[str]) -> list[str]:
    override = SCREEN_SECTION_FIELD_OVERRIDES.get(screen_id, {}).get(section_id)
    if override is not None:
        # Preserve response contract order in generated output for stable
        # rendering and byte-identical projection/evidence assertions.
        return [field for field in response_fields if field in override]
    return semantic_response_fields(section_id, response_fields)

def generated_field_names(screen_id: str, section_id: str, response_fields: list[str]) -> list[str]:
    if section_id in SCREEN_SECTION_FIELD_OVERRIDES.get(screen_id, {}):
        return section_fields(screen_id, section_id, response_fields)
    return list(dict.fromkeys([section_id, "status", *section_fields(screen_id, section_id, response_fields)]))

lines = [
    "// Generated from specs/ui/screen-catalog.yaml and screen-build-manifest.yaml; do not hand-edit.",
    "export const ROUTE_SCREEN_CONTRACTS = {",
]
for row in rows:
    sections = []
    semantic_by_section = {}
    manifest_row = manifest_by[row["id"]]
    manifest_sections = {item["id"]: item for item in manifest_row["section_order"]}
    operation_ids = data_operation_ids(row)
    operation = operations_by_id.get(operation_ids[0])
    if operation is None:
        raise SystemExit(f"missing data contract for {row['id']}:{operation_ids[0]}")
    response_fields = [item["name"] for item in operation.get("response_fields", [])]
    for section in sorted(row.get("sections", []), key=lambda item: item["order"]):
        section_id = section["id"]
        operation_id = section_operation_id(row, section_id)
        operation = operations_by_id[operation_id]
        response_fields = [
            item["name"] for item in operation.get("response_fields", [])
        ]
        manifest_section = manifest_sections[section_id]
        field_names = generated_field_names(row["id"], section_id, response_fields)
        roles = [section_id]
        resolved_component = section.get("component")
        sections.append(
            "{ id: %s, region: %s, testId: %s, component: %s, fields: %s }"
            % (
                quote(section_id),
                quote(roles[0]),
                quote(manifest_section["test_id"]),
                quote(str(resolved_component)) if resolved_component else "null",
                json.dumps(field_names, ensure_ascii=False),
            )
        )
    lines.extend(
        [
            f"  {quote(row['id'])}: {{",
            f"    route: {quote(row['route'])},",
            f"    objectLabel: {quote(row.get('title', row['id']))},",
            f"    persona: {quote(SURFACE_PERSONAS.get(row.get('surface', 'internal'), DEFAULT_PERSONA))},",
            f"    primaryActionId: {quote(row.get('primary_action_id')) if row.get('primary_action_id') else 'null'},",
            f"    primaryActionLabel: {quote(next((a['label'] for a in row.get('actions', []) if a.get('id') == row.get('primary_action_id')), '')) if row.get('primary_action_id') else 'null'},",
            f"    sections: [{', '.join(sections)}],",
            "  },",
        ]
    )
lines.append("} as const;")
target = ROOT / "packages/ui/src/generated-screen-contracts.ts"
target.write_text("\n".join(lines) + "\n")

# The browser projection is a separate generated allowlist.  Every semantic
# field is bound to the exact closed operation field declared by the authority
# overlay; runtime code is not allowed to guess camel/snake case keys.
projection_lines = [
    "// Generated from specs/ui/screen-catalog.yaml and screen-build-manifest.yaml; do not hand-edit.",
    "export type ScreenProjectionBinding = { operationId: string; path: string; sectionId: string; fieldName: string };",
    "export const SCREEN_PROJECTION_BINDINGS = {",
]
for row in rows:
    operations = row.get("data_requirements", [])
    if not operations:
        raise SystemExit(f"authority screen {row['id']} has no data operation")
    bindings = []
    projection_lines.append(f"  {quote(row['id'])}: {{")
    for section in sorted(row.get("sections", []), key=lambda item: item["order"]):
        section_id = section["id"]
        operation_id = section_operation_id(row, section_id)
        operation = operations_by_id[operation_id]
        response_fields = [
            item["name"] for item in operation.get("response_fields", [])
        ]
        for field_name in generated_field_names(row["id"], section_id, response_fields):
            bindings.append(
                f"    {quote(f'{section_id}.{field_name}')}: {{ operationId: {quote(operation_id)}, path: {quote(f'$.{field_name}')}, sectionId: {quote(section_id)}, fieldName: {quote(field_name)} }},"
            )
    projection_lines.extend(bindings)
    projection_lines.append("  },")
projection_lines.append("} as const;")
projection_target = ROOT / "packages/ui/src/generated-screen-projections.ts"
projection_target.write_text("\n".join(projection_lines) + "\n")
subprocess.run(
    ["bunx", "biome", "format", "--write", str(target), str(projection_target)],
    cwd=ROOT,
    check=True,
)
print(
    f"wrote {target} "
    f"({len(rows)} screens, "
    f"{sum(len(row.get('sections', row.get('section_mapping', []))) for row in rows)} sections)"
)
