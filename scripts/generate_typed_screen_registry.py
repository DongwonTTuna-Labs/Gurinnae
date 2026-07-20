#!/usr/bin/env python3
"""Generate the closed route/section UI registry from pinned v13 authority."""
from pathlib import Path
import json
import hashlib
import re
import yaml

ROOT = Path(__file__).resolve().parents[1]
AUTHORITY_ROOT = ROOT / "authority-v13"
source_path = AUTHORITY_ROOT / "specs/ui/screen-catalog.yaml"
manifest_path = AUTHORITY_ROOT / "specs/ui/screen-build-manifest.yaml"
data_contracts_path = AUTHORITY_ROOT / "specs/ui/screen-data-contracts.yaml"
CANONICAL_SCREEN_CATALOG_SHA256 = "e2dc57a4b6092105b088b84723456037bf2892f168afd542056c23284e6bff2b"
CANONICAL_SCREEN_BUILD_MANIFEST_SHA256 = "4862de1453b12a09ac775edef0414d057476dfc56b5dced9c17824b980fa7624"
CANONICAL_SCREEN_DATA_CONTRACTS_SHA256 = "665495729bd5a6ecfb8828583689a5ffc3ed18642b8d4aa7690da1834c1d987a"

def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

if _sha256(source_path) != CANONICAL_SCREEN_CATALOG_SHA256:
    raise SystemExit("screen catalog is not the pinned v13.0.0 authority")
if _sha256(manifest_path) != CANONICAL_SCREEN_BUILD_MANIFEST_SHA256:
    raise SystemExit("screen build manifest is not the pinned v13.0.0 authority")
if _sha256(data_contracts_path) != CANONICAL_SCREEN_DATA_CONTRACTS_SHA256:
    raise SystemExit("screen data contracts are not the pinned v13.0.0 authority")
source = yaml.safe_load(source_path.read_text())
manifest = yaml.safe_load(manifest_path.read_text())
data_contracts = yaml.safe_load(data_contracts_path.read_text())
operations_by_id = {row["operation_id"]: row for row in data_contracts["operations"]}
manifest_by = {row["id"]: row for row in manifest["screens"]}
rows = source["screens"]
if len(rows) != 94 or sum(len(row.get("sections", [])) for row in rows) != 496:
    raise SystemExit("authority screen catalog must contain exactly 94 screens and 496 sections")

def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)

SECTION_FIELD_HINTS = {
    "progress": {"requestId", "version", "savedAt", "expiresAt", "status"},
    "questions": {"answers", "questionId", "questionLabel", "text"},
    "statement": {"answers", "attachments", "status"},
    "consent": {"publicationConsent", "bodyConsent", "redactionAcknowledged"},
    "receipt": {"receiptId", "receiptStatus", "submittedAt", "submissionDigest"},
    "download": {"receiptId", "submissionDigest", "status"},
    "authority": {"authority", "authorityStatus", "status"},
}

# A section id is a presentation role, not an operation response key.  The
# pinned authority catalog gives PUB-004 its user questions and section
# purposes, while getPublicCase gives the exact response field names.  Keep
# this mapping explicit so the generated browser projection cannot invent
# synthetic keys such as `known` or `response` and silently render UNKNOWN.
SCREEN_SECTION_FIELD_OVERRIDES = {
    "PUB-004": {
        "status": {"slug", "title", "publicState", "revision", "publishedAt", "updatedAt", "freshness"},
        "known": {"summary", "confirmedFacts"},
        "unknown": {"criticalUnknowns", "limitations"},
        "response": {"partyResponses"},
        "comparison": {"comparison", "signals"},
        "counter": {"counterEvidence"},
        "evidence": {"claims", "evidence"},
        "timeline": {"timeline"},
        "revision": {"revision", "corrections"},
    },
}

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
    if screen_id in SCREEN_SECTION_FIELD_OVERRIDES:
        return section_fields(screen_id, section_id, response_fields)
    return list(dict.fromkeys([section_id, "status", *section_fields(screen_id, section_id, response_fields)]))

lines = [
    "// Generated from authority-v13/specs/ui/screen-catalog.yaml and screen-build-manifest.yaml; do not hand-edit.",
    "export const ROUTE_SCREEN_CONTRACTS = {",
]
for row in rows:
    sections = []
    semantic_by_section = {}
    manifest_row = manifest_by[row["id"]]
    manifest_sections = {item["id"]: item for item in manifest_row["section_order"]}
    operation_ids = [item["operation_id"] for item in row.get("data_requirements", [])]
    operation = operations_by_id.get(operation_ids[0])
    if operation is None:
        raise SystemExit(f"missing data contract for {row['id']}:{operation_ids[0]}")
    response_fields = [item["name"] for item in operation.get("response_fields", [])]
    for section in sorted(row.get("sections", []), key=lambda item: item["order"]):
        section_id = section["id"]
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
            f"    persona: {quote({'public': '공개 독자·연구자', 'response': '소명 대상자', 'internal': '조사 담당자', 'auth': '내부 사용자'}.get(row.get('surface', 'internal'), '조사 담당자'))},",
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
    "// Generated from authority-v13/specs/ui/screen-catalog.yaml and screen-build-manifest.yaml; do not hand-edit.",
    "export type ScreenProjectionBinding = { operationId: string; path: string; sectionId: string; fieldName: string };",
    "export const SCREEN_PROJECTION_BINDINGS = {",
]
for row in rows:
    operations = row.get("data_requirements", [])
    if not operations:
        raise SystemExit(f"authority screen {row['id']} has no data operation")
    operation_id = operations[0]["operation_id"]
    operation = operations_by_id[operation_id]
    response_fields = [item["name"] for item in operation.get("response_fields", [])]
    bindings = []
    projection_lines.append(f"  {quote(row['id'])}: {{")
    for section in sorted(row.get("sections", []), key=lambda item: item["order"]):
        section_id = section["id"]
        for field_name in generated_field_names(row["id"], section_id, response_fields):
            bindings.append(
                f"    {quote(f'{section_id}.{field_name}')}: {{ operationId: {quote(operation_id)}, path: {quote(f'$.{field_name}')}, sectionId: {quote(section_id)}, fieldName: {quote(field_name)} }},"
            )
    projection_lines.extend(bindings)
    projection_lines.append("  },")
projection_lines.append("} as const;")
projection_target = ROOT / "packages/ui/src/generated-screen-projections.ts"
projection_target.write_text("\n".join(projection_lines) + "\n")
print(f"wrote {target} ({len(rows)} screens, {sum(len(row.get('sections', row.get('section_mapping', []))) for row in rows)} sections, source_sha256={hashlib.sha256(source_path.read_bytes()).hexdigest()})")
