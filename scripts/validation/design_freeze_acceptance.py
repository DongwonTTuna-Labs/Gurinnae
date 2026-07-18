"""Bridge the external acceptance evidence gate into the design freeze."""
from __future__ import annotations

import os
from pathlib import Path

from generate_effective_registry import Checks

from .effective_acceptance import (
    validate_external_evidence,
    validate_sources,
    validate_static,
)


def _merge(source: object, destination: Checks) -> None:
    for problem in getattr(source, "problems", []):
        destination.require(
            False,
            problem.code,
            problem.source,
            problem.expected,
            problem.actual,
        )


def validate_mapped_test_sources(root: Path, checks: Checks) -> None:
    """Require the generated registry and exact source-level test bijection."""
    structural, registry = validate_static(root)
    _merge(structural, checks)
    _merge(validate_sources(root, registry), checks)


def validate_supplemental_acceptance_release(root: Path, checks: Checks) -> None:
    """Require one external set-equal receipt index for all 439 scenarios."""
    structural, registry = validate_static(root)
    _merge(structural, checks)
    if not structural.problems:
        evidence_root = os.environ.get("GURINNAE_EVIDENCE_ROOT")
        run_index = os.environ.get("GURINNAE_ACCEPTANCE_RUN_INDEX")
        if not evidence_root or not run_index:
            checks.require(
                False,
                "missing_evidence_arguments",
                "GURINNAE_EVIDENCE_ROOT/GURINNAE_ACCEPTANCE_RUN_INDEX",
                "external evidence root and relative run index",
                {"evidence_root": evidence_root, "run_index": run_index},
            )
            return
        _merge(
            validate_external_evidence(
                root,
                registry,
                Path(evidence_root),
                run_index,
            ),
            checks,
        )
