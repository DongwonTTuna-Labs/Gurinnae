"""Canonical coordinator for Gurinnae's additive design validators.

The domain validators intentionally live in focused modules.  This entrypoint
is the only authority-validator call graph: a contract cannot be implemented in
an uncalled shadow validator and still appear closed.
"""

from __future__ import annotations

from pathlib import Path

from .design_domain import validate_domain
from .design_database_self_test import self_test_database_candidate_key_merges
from .design_journey_self_test import self_test_journey_validators
from .design_lifecycle import validate_lifecycle
from .design_journey_graph import validate_journey_graph
from .design_operations import validate_operations
from .design_persistence import validate_persistence
from .design_support import load_design_documents
from .design_ui import validate_ui
from .models import Validation


def validate(root: Path, result: Validation) -> None:
    """Validate the complete design graph in dependency order."""

    documents = load_design_documents(root, result)
    validate_journey_graph(documents)
    operations = validate_operations(documents)
    lifecycle = validate_lifecycle(documents, operations)
    persistence = validate_persistence(documents, operations)
    ui = validate_ui(documents, operations, lifecycle)
    validate_domain(
        documents,
        operations,
        persistence,
        lifecycle,
        ui,
    )
    self_test_journey_validators(documents)
    self_test_database_candidate_key_merges(documents)
