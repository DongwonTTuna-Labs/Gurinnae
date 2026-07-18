#!/usr/bin/env python3
"""Generate the closed route/section UI registry from the current design closure."""
from pathlib import Path
import json
import hashlib
import yaml

ROOT = Path(__file__).resolve().parents[1]
source_path = ROOT / "specs/ui/effective-screen-contracts.yaml"
source = yaml.safe_load(source_path.read_text())
rows = source["screens"]
if len(rows) != 94 or sum(len(row.get("sections", row.get("section_mapping", []))) for row in rows) != 496:
    raise SystemExit("effective screen contracts must contain exactly 94 screens and 496 sections")

def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)

lines = [
    "// Generated from specs/ui/effective-screen-contracts.yaml; do not hand-edit.",
    "export const ROUTE_SCREEN_CONTRACTS = {",
]
for row in rows:
    sections = []
    semantic_by_section = {}
    for role, semantic in row.get("semantic_contract", {}).items():
        semantic_by_section.setdefault(semantic.get("section_id"), []).append(role)
    for section in sorted(row.get("sections", row.get("section_mapping", [])), key=lambda item: item["order"]):
        typed = section.get("typed_slice", {})
        field_names = [field["name"] for field in typed.get("fields", [])] if isinstance(typed, dict) else [typed] if isinstance(typed, str) else []
        roles = semantic_by_section.get(section.get("section_id", section.get("id")), ["state"])
        resolved_component = section.get("component")
        if isinstance(resolved_component, dict):
            resolved_component = resolved_component.get("component")
        sections.append(
            "{ id: %s, region: %s, testId: %s, component: %s, fields: %s }"
            % (
                quote(section.get("section_id", section.get("id"))),
                quote(roles[0]),
                quote(section["test_id"]),
                quote(str(resolved_component)) if resolved_component else "null",
                json.dumps(field_names, ensure_ascii=False),
            )
        )
    lines.extend(
        [
            f"  {quote(row['screen_id'])}: {{",
            f"    route: {quote(row['route'])},",
            f"    objectLabel: {quote(row.get('title', row['screen_id']))},",
            f"    persona: {quote({'public': '공개 독자·연구자', 'response': '소명 대상자', 'internal': '조사 담당자', 'auth': '내부 사용자'}.get(row.get('surface', 'internal'), '조사 담당자'))},",
            f"    primaryActionId: {quote(row['primary_action']['action_id']) if row.get('primary_action') and row['primary_action'].get('action_id') else 'null'},",
            f"    primaryActionLabel: {quote(row['primary_action']['label']) if row.get('primary_action') and row['primary_action'].get('label') else 'null'},",
            f"    sections: [{', '.join(sections)}],",
            "  },",
        ]
    )
lines.append("} as const;")
target = ROOT / "packages/ui/src/generated-screen-contracts.ts"
target.write_text("\n".join(lines) + "\n")
print(f"wrote {target} ({len(rows)} screens, {sum(len(row.get('sections', row.get('section_mapping', []))) for row in rows)} sections, source_sha256={hashlib.sha256(source_path.read_bytes()).hexdigest()})")
