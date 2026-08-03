"""Mutation fixtures for effective-registry set and reference validation."""

from __future__ import annotations

from typing import Callable

from generate_effective_registry import Checks, collect_event_tokens


def _duplicate_fixture() -> bool:
    checks = Checks()
    checks.unique(["A", "A"], "bad-fixture")
    return any(problem.code == "duplicate_id" for problem in checks.problems)


def _set_fixture() -> bool:
    checks = Checks()
    checks.equal({"A"}, {"B"}, "bad-fixture", "left", "right")
    return any(problem.code == "set_equality" for problem in checks.problems)


def _count_fixture() -> bool:
    checks = Checks()
    checks.count(77, {str(index) for index in range(80)}, "bad-fixture")
    return any(problem.code == "declared_count" for problem in checks.problems)


def _event_reference_context_fixture() -> bool:
    known_event = "known.event.v1"
    dangling_event = "dangling.event.v1"
    non_event_schema_versions = {
        "privacy-response-party-name-correction-delegation.v1",
        "privacy-response-party-name-correction-job-load.v1",
    }
    references = collect_event_tokens(
        {
            "schema_version": (
                "privacy-response-party-name-correction-delegation.v1"
            ),
            "loader": {
                "result_schema_version": (
                    "privacy-response-party-name-correction-job-load.v1"
                )
            },
            "outbox": {"events": [known_event, dangling_event]},
        }
    )
    checks = Checks()
    checks.subset(references, {known_event}, "event references")
    unknown = [
        problem
        for problem in checks.problems
        if problem.code == "unknown_reference" and problem.source == "event references"
    ]
    return (
        references == {known_event, dangling_event}
        and references.isdisjoint(non_event_schema_versions)
        and len(unknown) == 1
        and unknown[0].actual == [dangling_event]
    )


def registry_fixtures() -> tuple[tuple[str, Callable[[], bool]], ...]:
    return (
        ("duplicate-id.yaml", _duplicate_fixture),
        ("set-drift.yaml", _set_fixture),
        ("magic-count.yaml", _count_fixture),
        ("event-reference-context.yaml", _event_reference_context_fixture),
    )
