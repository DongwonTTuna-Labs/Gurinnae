from __future__ import annotations

from copy import deepcopy
from typing import Any, Callable

from .design_database_support import _added_candidate_keys
from .design_support import DesignDocuments
from .models import Validation


def _fixture() -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    document = {
        "existing_relation_changes": [
            {
                "relation": "core.subjects",
                "added_candidate_keys": [
                    {
                        "name": "subjects_id_version_uq",
                        "columns": ["id", "version"],
                    }
                ],
            }
        ]
    }
    rows = {
        "core.subjects": {
            "columns": {
                "id": {"type": "uuid", "nullable": False},
                "version": {"type": "bigint", "nullable": False},
            },
            "primary_key": {"name": "subjects_pk", "columns": ["id"]},
        }
    }
    return document, rows


def _negative_canary(
    mutate: Callable[[dict[str, Any]], None],
) -> bool:
    document, rows = _fixture()
    mutated = deepcopy(document)
    mutate(mutated)
    probe = Validation()
    _added_candidate_keys(mutated, rows, probe)
    return bool(probe.errors)


def self_test_database_candidate_key_merges(documents: DesignDocuments) -> None:
    result = documents.result
    document, rows = _fixture()
    valid_probe = Validation()
    valid = _added_candidate_keys(document, rows, valid_probe)
    canaries = {
        "valid_additive_merge": not valid_probe.errors
        and valid
        == {
            "core.subjects": (
                ("subjects_id_version_uq", ("id", "version")),
            )
        },
        "unknown_relation": _negative_canary(
            lambda value: value["existing_relation_changes"][0].__setitem__(
                "relation", "core.unknown"
            )
        ),
        "unknown_column": _negative_canary(
            lambda value: value["existing_relation_changes"][0][
                "added_candidate_keys"
            ][0].__setitem__("columns", ["id", "unknown"])
        ),
        "duplicate_key": _negative_canary(
            lambda value: value["existing_relation_changes"][0][
                "added_candidate_keys"
            ].append(
                {
                    "name": "subjects_id_version_duplicate_uq",
                    "columns": ["id", "version"],
                }
            )
        ),
    }
    result.require(
        all(canaries.values()),
        "database forward candidate-key validator self-test failed: "
        f"{[name for name, passed in canaries.items() if not passed]}",
    )
    result.stats["database_candidate_key_merge_self_tests"] = len(canaries)
