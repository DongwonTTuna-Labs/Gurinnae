"""Exact authority profiles that coherent source/mapping drift cannot rewrite."""
from __future__ import annotations

from typing import Any

from .supplemental_acceptance_core import Checks, Scenario


JOURNEY_FEATURE = "tests/acceptance/journey-handoff-addendum.feature"
JOURNEY_IDS = [f"AC-JOURNEY_HANDOFF_ADDENDUM-{index:03d}" for index in range(1, 47)]
JOURNEY_TEST_PATH = "tests/integration/acceptance/journey_handoff_addendum.rs"
JOURNEY_RUNTIME_LAYERS = [
    "rust-1.97.0-domain-application",
    "postgresql-18.4-real-migrations",
    "docker-compose-production-topology",
]


def validate_journey_profile(
    scenarios: list[Scenario],
    mapped: dict[str, dict[str, Any]],
    checks: Checks,
) -> None:
    source_ids = [
        row.scenario_id for row in scenarios if row.feature_file == JOURNEY_FEATURE
    ]
    mapped_ids = [
        scenario_id
        for scenario_id, row in mapped.items()
        if row.get("feature_file") == JOURNEY_FEATURE
    ]
    checks.need(
        source_ids == mapped_ids == JOURNEY_IDS,
        "journey_profile_identity",
        JOURNEY_FEATURE,
        JOURNEY_IDS,
        {"source": source_ids, "mapping": mapped_ids},
    )
    for scenario_id in JOURNEY_IDS:
        row = mapped.get(scenario_id, {})
        checks.need(
            row.get("implementation_test_path") == JOURNEY_TEST_PATH
            and row.get("runtime_layers") == JOURNEY_RUNTIME_LAYERS,
            "journey_runtime_profile",
            scenario_id,
            {
                "implementation_test_path": JOURNEY_TEST_PATH,
                "runtime_layers": JOURNEY_RUNTIME_LAYERS,
            },
            {
                "implementation_test_path": row.get("implementation_test_path"),
                "runtime_layers": row.get("runtime_layers"),
            },
        )
