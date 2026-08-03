from __future__ import annotations

from pathlib import Path
from typing import Any

from generate_legal_content import (
    comparable_retention_contract,
    generated_outputs,
    legal_content_envelopes,
    source_license_matrix,
)

from .legal_documents import (
    DECISION,
    OPERATOR_INPUT_RULES,
    OPERATOR_INPUTS,
    OPERATOR_PUBLICATION_REQUIREMENTS,
    PRIVACY_SECTIONS,
    PROCEDURE_STEPS,
    REDISTRIBUTION_DUTIES,
    RIGHT_DIMENSIONS,
    SHARED_RETENTION_PUBLIC_COLUMNS,
    SHARED_RETENTION_SELECTION,
    TERMS_SECTIONS,
    VERSION,
    require_policy_provenance,
    validate_operator_inputs,
    validate_privacy,
    validate_procedure,
    validate_terms,
)
from .loaders import load_yaml
from .models import Validation


def validate_matrix(root: Path, result: Validation) -> None:
    path = root / "specs/legal/source-license-matrix.yaml"
    actual = load_yaml(path)
    expected = source_license_matrix()
    result.require(actual == expected, "source license matrix is stale or not catalog-derived")
    rows = actual.get("connectors", [])
    result.require(
        all(
            set(row.get("rights_dimensions", {})) == RIGHT_DIMENSIONS
            and set(row["rights_dimensions"].values()) == {"UNKNOWN"}
            and row.get("publication_authorized") is False
            for row in rows
        ),
        "source license matrix must not invent a right or publication approval",
    )
    status_by_id = {row["connector_id"]: row["rights_status"] for row in rows}
    result.require(status_by_id.get("pps-sanctions") == "BLOCKED", "PPS sanctions blocker lost")
    result.require(
        all(status == "REVIEW_REQUIRED" for key, status in status_by_id.items() if key != "pps-sanctions"),
        "unblocked connectors must still require terms review",
    )


def validate_generated(root: Path, result: Validation) -> None:
    for path, expected in generated_outputs().items():
        result.require(path.is_file(), f"missing generated legal artifact: {path.relative_to(root)}")
        if path.is_file():
            result.require(
                path.read_text(encoding="utf-8") == expected,
                f"stale generated legal artifact: {path.relative_to(root)}",
            )


def validate_content_envelopes(result: Validation) -> None:
    envelopes = legal_content_envelopes()
    result.require(set(envelopes) == {"privacy", "terms"}, "legal envelope set mismatch")
    expected_sections = {"privacy": PRIVACY_SECTIONS, "terms": TERMS_SECTIONS}
    for name, expected_ids in expected_sections.items():
        envelope = envelopes[name]
        result.require(
            set(envelope) == {"status", "sections"},
            f"{name}: legal content envelope is not closed",
        )
        sections = envelope.get("sections", [])
        ids = [section.get("id") for section in sections]
        result.require(ids == expected_ids, f"{name}: canonical section order mismatch")
        result.require(len(ids) == len(set(ids)), f"{name}: duplicate section id")
        result.require(
            all(
                set(section) == {"id", "heading", "body"}
                and bool(section["heading"])
                and bool(section["body"])
                for section in sections
            ),
            f"{name}: section must have only nonempty id, heading, and body",
        )
    terms_body = " ".join(section["body"] for section in envelopes["terms"]["sections"])
    for code, exact_text in REDISTRIBUTION_DUTIES.items():
        result.require(exact_text in terms_body, f"terms body missing exact {code} duty")


def validate(root: Path, result: Validation) -> None:
    validate_operator_inputs(root, result)
    validate_privacy(root, result)
    validate_terms(root, result)
    validate_procedure(root, result)
    validate_matrix(root, result)
    validate_content_envelopes(result)
    validate_generated(root, result)
    result.stats.update(
        {
            "legal_content_sources": 4,
            "legal_generated_artifacts": len(generated_outputs()),
            "source_license_rows": len(source_license_matrix()["connectors"]),
        }
    )
