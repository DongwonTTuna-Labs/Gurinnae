"""Negative canaries for exact supplemental authority profiles."""
from __future__ import annotations

from .supplemental_acceptance_core import Checks, Scenario
from .supplemental_acceptance_profiles import (
    JOURNEY_FEATURE,
    JOURNEY_IDS,
    JOURNEY_RUNTIME_LAYERS,
    JOURNEY_TEST_PATH,
    validate_journey_profile,
)


def _probe(drift: str) -> Checks:
    checks = Checks("self-test")
    scenarios = [Scenario(value, JOURNEY_FEATURE, value) for value in JOURNEY_IDS]
    mapped = {
        value: {
            "feature_file": JOURNEY_FEATURE,
            "implementation_test_path": JOURNEY_TEST_PATH,
            "runtime_layers": list(JOURNEY_RUNTIME_LAYERS),
        }
        for value in JOURNEY_IDS
    }
    if drift == "identity":
        scenarios.pop()
    else:
        mapped[JOURNEY_IDS[0]]["runtime_layers"] = ["fixture-only"]
    validate_journey_profile(scenarios, mapped, checks)
    return checks


def profile_fixtures() -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for fixture, code, drift in (
        ("journey-profile-identity-drift", "journey_profile_identity", "identity"),
        ("journey-runtime-layer-drift", "journey_runtime_profile", "runtime"),
    ):
        checks = _probe(drift)
        rows.append(
            {
                "fixture": fixture,
                "expected_problem": code,
                "corruption_rejected": any(
                    problem.code == code for problem in checks.problems
                ),
            }
        )
    return rows
