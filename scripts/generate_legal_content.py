#!/usr/bin/env python3
"""Generate deterministic, non-runtime R6d legal review artifacts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
LEGAL = ROOT / "specs/legal"
DOCS = ROOT / "docs/legal"
UNKNOWN_RIGHTS = {
    "attribution": "UNKNOWN",
    "commercial_use": "UNKNOWN",
    "modification": "UNKNOWN",
    "redistribution": "UNKNOWN",
    "raw_mirroring": "UNKNOWN",
}


def load_yaml(path: Path) -> dict[str, Any]:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise ValueError(f"expected YAML object: {path.relative_to(ROOT)}")
    return document


def source_license_matrix() -> dict[str, Any]:
    catalog = load_yaml(ROOT / "specs/connectors/connector-catalog.yaml")
    rows: list[dict[str, Any]] = []
    for catalog_entry in catalog["connectors"]:
        contract = load_yaml(ROOT / catalog_entry["directory"] / "connector.yaml")
        references = catalog_entry.get("official_references")
        if references is None:
            singular = contract.get("official_reference")
            references = [singular] if singular else contract.get("official_references", [])
        blocker = catalog_entry.get("legal_blocker")
        if blocker is None and isinstance(contract.get("blocker"), dict):
            blocker = contract["blocker"].get("code")
        rows.append(
            {
                "connector_id": catalog_entry["id"],
                "display_name": contract["display_name"],
                "source_kind": catalog_entry["source_kind"],
                "official_references": references,
                "operation_count": catalog_entry["operation_count"],
                "activation_mode": catalog_entry["activation_mode"],
                "terms_review_required": contract["activation"].get(
                    "requires_terms_review", False
                ),
                "rights_status": "BLOCKED" if blocker else "REVIEW_REQUIRED",
                "legal_blocker": blocker,
                "rights_dimensions": dict(UNKNOWN_RIGHTS),
                "publication_authorized": False,
                "required_evidence": "SOURCE_LICENSE/PRODUCTION_LEGAL/SATISFIED",
                "operator_action_required": catalog_entry["operator_responsibility"],
            }
        )
    return {
        "schema_version": 1,
        "specification_version": "13.0.0-r6d",
        "document_version": "supervisor-decision-v1",
        "status": "GENERATED_NON_RUNTIME_REVIEW_MATRIX",
        "generated_from": {
            "connector_catalog": "specs/connectors/connector-catalog.yaml",
            "connector_contract_pattern": "specs/connectors/*/connector.yaml",
            "derivation_rule": "source-license-matrix.v1",
        },
        "policy_provenance": {
            "decision_id": "supervisor-decision-v1",
            "external_counsel_approved": False,
        },
        "rules": [
            "UNKNOWN never grants a use right",
            "a catalog entry or connector blocker yields BLOCKED",
            "otherwise requires_terms_review yields REVIEW_REQUIRED",
            "production publication needs a separate current SOURCE_LICENSE evidence receipt",
            "this generated matrix is review inventory, not a license decision",
        ],
        "runtime_evidence_contract": {
            "relation": "ops.capability_activation_evidence",
            "evidence_kind": "SOURCE_LICENSE",
            "required_state": "SATISFIED",
            "required_proof_tier": "PRODUCTION_LEGAL",
            "expiry_behavior": "FAIL_CLOSED",
        },
        "connectors": rows,
        "connector_count": len(rows),
        "operation_count": sum(row["operation_count"] for row in rows),
    }


def markdown_header(title: str, status: str) -> list[str]:
    return [
        f"# {title}",
        "",
        "> `scripts/generate_legal_content.py`가 생성한 비런타임 검토 문서입니다.",
        "> 외부 법률 자문 또는 운영 승인을 뜻하지 않습니다.",
        "",
        f"상태: `{status}`  ",
        "정책 근거: `supervisor-decision-v1` (제품 정책 결정, 외부 법률 승인 아님)",
        "",
    ]


def render_operator_inputs(document: dict[str, Any]) -> str:
    lines = markdown_header("사용자 소유 출시 입력", document["status"])
    lines.extend(["| 항목 | 공개 전 필수 | 상태 | 설명 |", "|---|---:|---|---|"])
    for item in document["inputs"]:
        required = "예" if item["required_for_publication"] else "아니오"
        lines.append(
            f"| `{item['id']}` | {required} | `{item['state']}` | {item['description_ko']} |"
        )
    lines.extend(
        [
            "",
            "값이 없는 항목은 이름·연락처·보험·검토 완료로 추정하거나 공개하지 않습니다.",
            "",
        ]
    )
    return "\n".join(lines)


def comparable_retention_contract(document: dict[str, Any]) -> dict[str, Any]:
    retention = dict(document["retention_table"])
    empty_result = dict(retention["empty_result"])
    empty_result.pop("message_ko", None)
    retention["empty_result"] = empty_result
    return retention


def require_shared_retention_contract(
    privacy: dict[str, Any], terms: dict[str, Any]
) -> None:
    if comparable_retention_contract(privacy) != comparable_retention_contract(terms):
        raise ValueError(
            "privacy notice and terms must share one approved retention-table contract"
        )


def render_retention_contract(retention: dict[str, Any], title: str) -> list[str]:
    return [
        f"## {title}",
        "",
        f"- 원천: `{retention['source_relation']}`의 유효하고 승인된 최신 revision",
        "- 정적 기간·정적 행: 금지",
        f"- 승인 일정 0행의 표 상태: `{retention['empty_result']['table_state']}`",
        f"- 0행 처리: `{retention['empty_result']['document_state']}` / "
        f"`{retention['empty_result']['response_behavior']}`",
        f"- 사용자 메시지: {retention['empty_result']['message_ko']}",
        "",
        "보존 기간 표는 요청 시점의 승인 receipt에 묶인 행으로만 서버에서 생성합니다.",
        "이 문서에는 기간 값을 복제하지 않습니다.",
        "",
    ]


def render_privacy(document: dict[str, Any]) -> str:
    lines = markdown_header("개인정보 처리방침 구조 초안", document["status"])
    lines.extend([document["policy_provenance"]["statement_ko"], "", "## 섹션과 근거", ""])
    lines.extend(["| 섹션 | 근거 종류 | 근거 부재 처리 |", "|---|---|---|"])
    for section in document["sections"]:
        evidence = section.get("evidence", {})
        kind = evidence.get("kind", "VERSIONED_POLICY")
        missing = section.get("missing_evidence_behavior", "정책에 따름")
        lines.append(f"| {section['title_ko']} | `{kind}` | `{missing}` |")
    lines.append("")
    lines.extend(
        render_retention_contract(document["retention_table"], "보존 표 런타임 계약")
    )
    return "\n".join(lines)


def render_terms(document: dict[str, Any]) -> str:
    lines = markdown_header("이용약관 구조 초안", document["status"])
    lines.extend([document["policy_provenance"]["statement_ko"], ""])
    for section in document["sections"]:
        lines.extend([f"## {section['title_ko']}", ""])
        lines.extend(f"- {clause}" for clause in section["clauses"])
        lines.append("")
    lines.extend(
        render_retention_contract(
            document["retention_table"], "기록 유형별 보존 표 런타임 계약"
        )
    )
    lines.extend(["## 재배포 시 유지 의무", ""])
    for duty in document["redistribution_duties"]["mandatory"]:
        lines.append(f"- `{duty['code']}` — {duty['text_ko']}")
    lines.extend(
        [
            "",
            document["redistribution_duties"]["source_rights_precedence"],
            "",
        ]
    )
    return "\n".join(lines)


def render_law_enforcement(document: dict[str, Any]) -> str:
    lines = markdown_header("수사기관 요청 대응 절차 스텁", document["status"])
    lines.extend([document["policy_provenance"]["statement_ko"], ""])
    for step in document["workflow"]:
        lines.extend([f"## {step['order']}. `{step['id']}`", "", step["action_ko"], ""])
    lines.extend(
        [
            "실제 대응 전 운영 법인·연락처·독립 법률 검토가 필요합니다. 이 스텁만으로",
            "자료 제공 권한이 생기지 않으며, 입력이 없으면 제공하지 않습니다.",
            "",
        ]
    )
    return "\n".join(lines)


def render_license_matrix(document: dict[str, Any]) -> str:
    lines = markdown_header("출처별 이용권 검토표", document["status"])
    lines.extend(
        [
            "모든 이용권 차원은 별도 승인 receipt 전까지 `UNKNOWN`이며 허용을 뜻하지 않습니다.",
            "",
            "| 커넥터 | 출처 | 권리 상태 | 차단 사유 | 공개 승인 |",
            "|---|---|---|---|---:|",
        ]
    )
    for row in document["connectors"]:
        blocker = row["legal_blocker"] or "—"
        references = "<br>".join(row["official_references"])
        publication = "예" if row["publication_authorized"] else "아니오"
        lines.append(
            f"| `{row['connector_id']}` | {references} | `{row['rights_status']}` | "
            f"`{blocker}` | {publication} |"
        )
    lines.extend(
        [
            "",
            f"커넥터 {document['connector_count']}개, operation {document['operation_count']}개.",
            "이 표는 커넥터 인벤토리이며 라이선스 허가서가 아닙니다.",
            "",
        ]
    )
    return "\n".join(lines)


def legal_content_envelopes() -> dict[str, Any]:
    privacy = load_yaml(LEGAL / "privacy-notice.yaml")
    terms = load_yaml(LEGAL / "terms-of-use.yaml")
    require_shared_retention_contract(privacy, terms)
    privacy_sections = [
        {
            "id": section["id"],
            "heading": section["title_ko"],
            "body": section["body_ko"],
        }
        for section in privacy["sections"]
    ]
    terms_sections = []
    duties = [item["text_ko"] for item in terms["redistribution_duties"]["mandatory"]]
    for section in terms["sections"]:
        body_parts = list(section["clauses"])
        if section["id"] == "data":
            body_parts.extend(duties)
        terms_sections.append(
            {
                "id": section["id"],
                "heading": section["title_ko"],
                "body": " ".join(body_parts),
            }
        )
    return {
        "privacy": {"status": privacy["status"], "sections": privacy_sections},
        "terms": {"status": terms["status"], "sections": terms_sections},
    }


def generated_outputs() -> dict[Path, str]:
    matrix = source_license_matrix()
    privacy = load_yaml(LEGAL / "privacy-notice.yaml")
    terms = load_yaml(LEGAL / "terms-of-use.yaml")
    require_shared_retention_contract(privacy, terms)
    procedure = load_yaml(LEGAL / "law-enforcement-request-procedure.yaml")
    operator_inputs = load_yaml(LEGAL / "operator-owned-launch-inputs.yaml")
    matrix_yaml = yaml.safe_dump(
        matrix, allow_unicode=True, sort_keys=False, width=110
    )
    return {
        LEGAL / "source-license-matrix.yaml": matrix_yaml,
        ROOT / "verification/generated-legal-content.json": (
            json.dumps(legal_content_envelopes(), ensure_ascii=False, indent=2) + "\n"
        ),
        DOCS / "operator-owned-launch-inputs.md": render_operator_inputs(operator_inputs),
        DOCS / "privacy-notice-draft.md": render_privacy(privacy),
        DOCS / "terms-of-use-draft.md": render_terms(terms),
        DOCS / "law-enforcement-request-procedure.md": render_law_enforcement(procedure),
        DOCS / "source-license-matrix.md": render_license_matrix(matrix),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    outputs = generated_outputs()
    stale = [
        path
        for path, expected in outputs.items()
        if not path.is_file() or path.read_text(encoding="utf-8") != expected
    ]
    if args.check:
        for path in stale:
            print(f"stale generated legal artifact: {path.relative_to(ROOT)}")
        if stale:
            return 1
        print(f"generated legal artifacts: PASS files={len(outputs)}")
        return 0
    for path in stale:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(outputs[path], encoding="utf-8")
    print(f"generated legal artifacts: updated={len(stale)} files={len(outputs)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
