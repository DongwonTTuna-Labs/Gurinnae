from __future__ import annotations

from pathlib import Path
from typing import Any

from generate_legal_content import comparable_retention_contract

from .loaders import load_yaml
from .models import Validation


VERSION = "13.0.0-r6d"
DECISION = "supervisor-decision-v1"
OPERATOR_INPUTS = {
    "OPERATING_LEGAL_ENTITY",
    "PRIVACY_CONTROLLER",
    "PRIVACY_OFFICER_OR_CPO",
    "PUBLIC_LEGAL_AND_PRIVACY_CONTACT",
    "LIABILITY_AND_CYBER_INSURANCE",
    "EXTERNAL_KOREAN_COUNSEL_REVIEW",
    "BACKUP_PHYSICAL_DISPOSAL_RECEIPT_AUTHORITY",
}
OPERATOR_PUBLICATION_REQUIREMENTS = {
    "OPERATING_LEGAL_ENTITY": True,
    "PRIVACY_CONTROLLER": True,
    "PRIVACY_OFFICER_OR_CPO": True,
    "PUBLIC_LEGAL_AND_PRIVACY_CONTACT": True,
    "LIABILITY_AND_CYBER_INSURANCE": False,
    "EXTERNAL_KOREAN_COUNSEL_REVIEW": True,
    "BACKUP_PHYSICAL_DISPOSAL_RECEIPT_AUTHORITY": False,
}
OPERATOR_INPUT_RULES = [
    "null values must never be replaced with invented names, addresses, contacts, coverage, or approvals",
    "a USER_INPUT_REQUIRED value must never be rendered as configured or approved",
    "external counsel review becomes complete only through a separately supplied review artifact",
]
PRIVACY_SECTIONS = [
    "controller",
    "categories",
    "purposes",
    "retention",
    "processors",
    "rights",
    "security",
    "history",
]
TERMS_SECTIONS = ["service", "content", "data", "prohibited", "liability", "changes"]
REDISTRIBUTION_DUTIES = {
    "RETAIN_STATUS": "재배포물에 원 자료의 공개·검토·정정 상태를 유지해야 합니다.",
    "RETAIN_NON_CONCLUSION_NOTICE": (
        '재배포물에 "이상 징후 기록이며 위법·부패의 확정이 아님" 고지를 유지해야 합니다.'
    ),
    "FOLLOW_CORRECTIONS": (
        "정정·철회가 게시되면 재배포물에도 해당 표시를 반영하거나 최신 revision으로 연결해야 합니다."
    ),
}
PROCEDURE_STEPS = [
    "INTAKE_AND_RECEIPT",
    "AUTHORITY_VERIFICATION",
    "SCOPE_AND_CONFLICT_REVIEW",
    "INDEPENDENT_LEGAL_DECISION",
    "SUBJECT_NOTICE_DECISION",
    "BOUNDED_DISCLOSURE",
    "CLOSE_AND_REPORT",
]
RIGHT_DIMENSIONS = {
    "attribution",
    "commercial_use",
    "modification",
    "redistribution",
    "raw_mirroring",
}
SHARED_RETENTION_SELECTION = [
    "select the latest revision for each record_class at the request clock",
    "require effective_at at or before the request clock",
    "require review_expires_at after the request clock",
    "require bound operational, legal, and execution approval receipts",
]
SHARED_RETENTION_PUBLIC_COLUMNS = [
    "record_class",
    "purpose",
    "lawful_basis",
    "trigger_kind",
    "active_duration_seconds",
    "backup_duration_seconds",
    "terminal_action",
    "effective_at",
    "review_expires_at",
    "schedule_digest",
]


def require_policy_provenance(document: dict[str, Any], result: Validation, name: str) -> None:
    provenance = document.get("policy_provenance", {})
    result.require(
        provenance.get("decision_id") == DECISION,
        f"{name}: supervisor decision provenance missing",
    )
    result.require(
        provenance.get("external_counsel_approved") is False,
        f"{name}: must not claim external counsel approval",
    )


def validate_operator_inputs(root: Path, result: Validation) -> None:
    document = load_yaml(root / "specs/legal/operator-owned-launch-inputs.yaml")
    result.require(document.get("specification_version") == VERSION, "legal input version mismatch")
    result.require(document.get("status") == "USER_INPUT_REQUIRED", "legal inputs must remain unset")
    require_policy_provenance(document, result, "operator inputs")
    inputs = document.get("inputs", [])
    result.require({item.get("id") for item in inputs} == OPERATOR_INPUTS, "operator input set mismatch")
    result.require(
        all(
            item.get("owner") == "USER"
            and item.get("state") == "USER_INPUT_REQUIRED"
            and item.get("value") is None
            for item in inputs
        ),
        "operator-owned legal placeholders must stay explicit, unset, and user-owned",
    )
    result.require(document.get("rules") == OPERATOR_INPUT_RULES, "operator input rules changed")
    result.require(
        {item.get("id"): item.get("required_for_publication") for item in inputs}
        == OPERATOR_PUBLICATION_REQUIREMENTS,
        "operator input publication requirements changed",
    )


def validate_privacy(root: Path, result: Validation) -> None:
    document = load_yaml(root / "specs/legal/privacy-notice.yaml")
    result.require(document.get("specification_version") == VERSION, "privacy notice version mismatch")
    result.require(
        document.get("status") == "DRAFT_UNPUBLISHED_LAUNCH_BLOCKED",
        "privacy notice must remain unpublished while launch inputs are absent",
    )
    require_policy_provenance(document, result, "privacy notice")
    gate = document.get("publication_gate", {})
    result.require(
        document.get("operator_input_contract")
        == "specs/legal/operator-owned-launch-inputs.yaml"
        and gate
        == {
            "mode": "FAIL_CLOSED",
            "required_operator_inputs": [
                "OPERATING_LEGAL_ENTITY",
                "PRIVACY_CONTROLLER",
                "PRIVACY_OFFICER_OR_CPO",
                "PUBLIC_LEGAL_AND_PRIVACY_CONTACT",
                "EXTERNAL_KOREAN_COUNSEL_REVIEW",
            ],
            "required_runtime_evidence": [
                "ACTIVE_APPROVED_RETENTION_SCHEDULES",
                "APPROVED_PROCESSING_INVENTORY",
            ],
            "blocked_state": "UNPUBLISHED",
            "no_partial_publication": True,
        },
        "privacy publication gate must fail closed",
    )
    result.require(
        [section.get("id") for section in document.get("sections", [])] == PRIVACY_SECTIONS,
        "privacy notice section closure mismatch",
    )
    rights = next(section for section in document["sections"] if section["id"] == "rights")
    result.require(
        rights["content_contract"].get("due_policy_id") == "PRIVACY_RESPONSE_CALENDAR"
        and rights["content_contract"].get("due_policy_value_source")
        == "RUNTIME_VERSIONED_POLICY",
        "privacy deadlines must bind the logical versioned runtime policy",
    )
    retention = document.get("retention_table", {})
    result.require(
        retention.get("materialization") == "RUNTIME_ONLY"
        and retention.get("source_relation") == "ops.record_class_schedules"
        and retention.get("static_rows_forbidden") is True
        and "rows" not in retention,
        "privacy retention table must be runtime-only without invented rows",
    )
    result.require(
        retention.get("selection_contract") == SHARED_RETENTION_SELECTION
        and retention.get("public_columns") == SHARED_RETENTION_PUBLIC_COLUMNS
        and retention.get("stale_or_unapproved_rows") == "EXCLUDE_AND_FAIL_CLOSED_IF_EMPTY",
        "privacy retention selection or public projection contract changed",
    )
    empty = retention.get("empty_result", {})
    result.require(
        empty.get("launch_blocking") is True
        and empty.get("table_state") == "UNAVAILABLE"
        and empty.get("document_state") == "UNPUBLISHED"
        and empty.get("response_behavior") == "FAIL_CLOSED",
        "empty approved retention schedule set must be unavailable and block publication",
    )


def validate_terms(root: Path, result: Validation) -> None:
    document = load_yaml(root / "specs/legal/terms-of-use.yaml")
    result.require(document.get("specification_version") == VERSION, "terms version mismatch")
    result.require(
        document.get("status") == "DRAFT_UNPUBLISHED_LAUNCH_BLOCKED",
        "terms must remain unpublished while launch inputs are absent",
    )
    require_policy_provenance(document, result, "terms")
    result.require(
        document.get("operator_input_contract")
        == "specs/legal/operator-owned-launch-inputs.yaml"
        and document.get("publication_gate")
        == {
            "mode": "FAIL_CLOSED",
            "required_operator_inputs": [
                "OPERATING_LEGAL_ENTITY",
                "PUBLIC_LEGAL_AND_PRIVACY_CONTACT",
                "EXTERNAL_KOREAN_COUNSEL_REVIEW",
            ],
            "required_runtime_evidence": ["ACTIVE_APPROVED_RETENTION_SCHEDULES"],
            "source_license_matrix": "specs/legal/source-license-matrix.yaml",
            "blocked_state": "UNPUBLISHED",
            "no_partial_publication": True,
        },
        "terms publication gate or legal input binding changed",
    )
    result.require(
        [section.get("id") for section in document.get("sections", [])] == TERMS_SECTIONS,
        "terms section closure mismatch",
    )
    duties = {
        item.get("code"): item.get("text_ko")
        for item in document.get("redistribution_duties", {}).get("mandatory", [])
    }
    result.require(duties == REDISTRIBUTION_DUTIES, "redistribution duty set or wording changed")
    result.require(
        document["redistribution_duties"].get("removal_or_weakening_forbidden") is True,
        "redistribution duties must not be removable or weakenable",
    )
    result.require(
        document["redistribution_duties"].get("source_rights_precedence")
        == "출처별 이용허락이 더 좁으면 그 제한을 우선 적용합니다.",
        "source-specific rights precedence changed",
    )
    privacy = load_yaml(root / "specs/legal/privacy-notice.yaml")
    retention = document.get("retention_table", {})
    result.require(
        comparable_retention_contract(document)
        == comparable_retention_contract(privacy),
        "terms and privacy notice must share one approved retention-table contract",
    )
    result.require(
        retention.get("materialization") == "RUNTIME_ONLY"
        and retention.get("source_relation") == "ops.record_class_schedules"
        and retention.get("static_rows_forbidden") is True
        and "rows" not in retention,
        "terms retention table must be runtime-only without invented rows",
    )
    result.require(
        retention.get("selection_contract") == SHARED_RETENTION_SELECTION
        and retention.get("public_columns") == SHARED_RETENTION_PUBLIC_COLUMNS
        and retention.get("stale_or_unapproved_rows")
        == "EXCLUDE_AND_FAIL_CLOSED_IF_EMPTY",
        "terms retention selection or public projection contract changed",
    )
    empty = retention.get("empty_result", {})
    result.require(
        empty.get("launch_blocking") is True
        and empty.get("table_state") == "UNAVAILABLE"
        and empty.get("document_state") == "UNPUBLISHED"
        and empty.get("response_behavior") == "FAIL_CLOSED",
        "empty approved retention schedule set must block terms publication",
    )


def validate_procedure(root: Path, result: Validation) -> None:
    document = load_yaml(root / "specs/legal/law-enforcement-request-procedure.yaml")
    result.require(document.get("specification_version") == VERSION, "request procedure version mismatch")
    result.require(document.get("status") == "DRAFT_PROCEDURE_STUB", "request procedure must be a stub")
    require_policy_provenance(document, result, "request procedure")
    result.require(
        document.get("operator_input_contract")
        == "specs/legal/operator-owned-launch-inputs.yaml"
        and document.get("activation_gate")
        == {
            "required_operator_inputs": [
                "OPERATING_LEGAL_ENTITY",
                "PUBLIC_LEGAL_AND_PRIVACY_CONTACT",
                "EXTERNAL_KOREAN_COUNSEL_REVIEW",
            ],
            "missing_input_behavior": "DO_NOT_DISCLOSE",
        },
        "request procedure activation gate changed",
    )
    rules = document.get("hard_rules", {})
    result.require(
        rules
        == {
            "automatic_disclosure": "forbidden",
            "broad_or_unbounded_collection": "forbidden",
            "credential_or_access_control_bypass": "forbidden",
            "whistleblower_identity_disclosure_without_exact_authority": "forbidden",
            "legal_hold_does_not_equal_disclosure_authority": True,
        },
        "request procedure hard rules are incomplete",
    )
    workflow = document.get("workflow", [])
    result.require([step.get("order") for step in workflow] == list(range(1, 8)), "procedure order mismatch")
    result.require([step.get("id") for step in workflow] == PROCEDURE_STEPS, "procedure step set mismatch")
    boundary = document.get("implementation_boundary", {})
    result.require(
        document.get("retention_and_hold")
        == {
            "classification": "LEGAL_OPERATIONAL_AUDIT",
            "schedule_source": "ops.record_class_schedules",
            "schedule_values_in_document": "forbidden",
            "hold_anchor_required_before_destructive_action": True,
        }
        and boundary
        == {
            "document_only_stub": True,
            "no_runtime_producer_claim": True,
            "launch_readiness_requires_executable_workflow_and_external_review": True,
        },
        "procedure stub must not claim runtime implementation",
    )
