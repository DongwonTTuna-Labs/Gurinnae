#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path, PurePosixPath
from typing import Any

import yaml

from git_authority import AUTHORITY_ZIP_SHA256, GitAuthorityError, authority_file
from validation.effective_acceptance import validate_static


ROOT = Path(__file__).resolve().parents[1]
ACCEPTANCE = ROOT / "tests/acceptance"
LOCK = ACCEPTANCE / "base-v13.lock.yaml"
SUPPLEMENTAL_MAPPING = ACCEPTANCE / "supplemental-executable-mapping.yaml"

EXPECTED_CATALOG_SHA256 = "13b4be1c9f22850d0220bb2be5e3a9ba8bc26252805c1b7b7eae987bb7e622c6"
EXPECTED_MAPPING_SHA256 = "f85a72768d18c12d3111adcb2895661b64d6cbd2b32112467d2526a52319ae83"
EXPECTED_FEATURE_MANIFEST_SHA256 = "197b105ffcfe13ec0f7671410a2963de87af32d74ebc59ff1ddd2b42442d817f"
EXPECTED_SCENARIO_IDENTITY_SHA256 = "2436ef73893e37d94d7a22e90d4b4a2fdc7bd098b6ea141a3d5650595146156f"
EXPECTED_FEATURE_COUNT = 35
EXPECTED_SCENARIO_COUNT = 271
EXPECTED_RULES = [
    "Base feature, catalog and executable-mapping bytes are immutable.",
    "Scenario conflict resolution is an ID-addressed overlay and never edits a base scenario.",
    "Supplemental and UI registries cannot replace or double-count a base scenario.",
]
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


class UniqueLoader(yaml.SafeLoader):
    """Reject duplicate YAML keys instead of silently accepting the last value."""


def _unique_mapping(
    loader: UniqueLoader,
    node: yaml.nodes.MappingNode,
    deep: bool = False,
) -> dict[Any, Any]:
    result: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in result
        except TypeError as error:
            raise ValueError(f"unhashable YAML key: {key!r}") from error
        if duplicate:
            raise ValueError(f"duplicate YAML key: {key!r}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _unique_mapping,
)


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_sha256(value: Any) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def load_mapping(path: Path, label: str) -> dict[str, Any]:
    if not path.is_file():
        fail(f"missing {label}: {path}")
    try:
        value = yaml.load(path.read_text(encoding="utf-8"), Loader=UniqueLoader)
    except (OSError, UnicodeError, yaml.YAMLError, ValueError) as error:
        fail(f"cannot read {label}: {path}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a YAML mapping: {path}")
    return value


def locked_feature_name(value: Any) -> str:
    if not isinstance(value, str) or not value:
        fail(f"base feature path must be a non-empty string: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or len(path.parts) != 1 or path.suffix != ".feature":
        fail(f"base feature path must be a direct tests/acceptance/*.feature name: {value!r}")
    return value


def validate_lock(lock: dict[str, Any]) -> list[dict[str, Any]]:
    expected_keys = {
        "schema_version",
        "specification_version",
        "status",
        "authority_zip_sha256",
        "catalog",
        "executable_mapping",
        "feature_count",
        "scenario_count",
        "feature_manifest_sha256",
        "ordered_scenario_identity_sha256",
        "features",
        "rules",
    }
    missing_keys = sorted(expected_keys - set(lock))
    extra_keys = sorted(set(lock) - expected_keys)
    if missing_keys or extra_keys:
        fail(f"base lock keys changed: missing={missing_keys}, extra={extra_keys}")

    expected_values = {
        "schema_version": 1,
        "specification_version": "13.0.0",
        "status": "BYTE_IMMUTABLE",
        "authority_zip_sha256": AUTHORITY_ZIP_SHA256,
        "feature_count": EXPECTED_FEATURE_COUNT,
        "scenario_count": EXPECTED_SCENARIO_COUNT,
        "feature_manifest_sha256": EXPECTED_FEATURE_MANIFEST_SHA256,
        "ordered_scenario_identity_sha256": EXPECTED_SCENARIO_IDENTITY_SHA256,
        "rules": EXPECTED_RULES,
    }
    for key, expected in expected_values.items():
        if lock.get(key) != expected:
            fail(f"base lock {key} changed: {lock.get(key)!r} != {expected!r}")

    expected_catalog = {
        "path": "acceptance-catalog.yaml",
        "sha256": EXPECTED_CATALOG_SHA256,
    }
    expected_mapping = {
        "path": "executable-mapping.yaml",
        "sha256": EXPECTED_MAPPING_SHA256,
    }
    if lock.get("catalog") != expected_catalog:
        fail(f"base lock catalog entry changed: {lock.get('catalog')!r}")
    if lock.get("executable_mapping") != expected_mapping:
        fail(f"base lock executable_mapping entry changed: {lock.get('executable_mapping')!r}")

    features = lock.get("features")
    if not isinstance(features, list):
        fail("base lock features must be a list")
    if len(features) != EXPECTED_FEATURE_COUNT:
        fail(
            "base lock feature entries changed: "
            f"{len(features)} != {EXPECTED_FEATURE_COUNT}"
        )

    paths: list[str] = []
    for index, entry in enumerate(features):
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256", "size"}:
            fail(f"invalid base feature lock entry at index {index}: {entry!r}")
        paths.append(locked_feature_name(entry["path"]))
        digest = entry["sha256"]
        size = entry["size"]
        if not isinstance(digest, str) or SHA256_PATTERN.fullmatch(digest) is None:
            fail(f"invalid base feature sha256 at index {index}: {digest!r}")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            fail(f"invalid base feature size at index {index}: {size!r}")

    duplicate_paths = sorted(path for path, count in Counter(paths).items() if count > 1)
    if duplicate_paths:
        fail(f"duplicate base feature paths in lock: {duplicate_paths}")
    manifest_digest = canonical_sha256(features)
    if manifest_digest != EXPECTED_FEATURE_MANIFEST_SHA256:
        fail(
            "base feature lock manifest drifted: "
            f"{manifest_digest} != {EXPECTED_FEATURE_MANIFEST_SHA256}"
        )
    return features


def verify_tagged_base_feature_lock(features: list[dict[str, Any]]) -> list[str]:
    locked_paths = [entry["path"] for entry in features]
    missing_paths = [
        name
        for name in locked_paths
        if (ACCEPTANCE / name).is_symlink() or not (ACCEPTANCE / name).is_file()
    ]
    if missing_paths:
        fail(f"missing current base feature files: {missing_paths}")

    observed_entries: list[dict[str, Any]] = []
    for expected in features:
        relative = f"tests/acceptance/{expected['path']}"
        try:
            content = authority_file(relative, ROOT)
        except GitAuthorityError as error:
            fail(f"cannot read tagged base feature: {relative}: {error}")
        observed = {
            "path": expected["path"],
            "sha256": hashlib.sha256(content).hexdigest(),
            "size": len(content),
        }
        if observed != expected:
            fail(
                f"tagged base feature lock drifted: {expected['path']}: "
                f"observed={observed}, expected={expected}"
            )
        observed_entries.append(observed)

    observed_digest = canonical_sha256(observed_entries)
    if observed_digest != EXPECTED_FEATURE_MANIFEST_SHA256:
        fail(
            "tagged base feature manifest drifted: "
            f"{observed_digest} != {EXPECTED_FEATURE_MANIFEST_SHA256}"
        )
    return locked_paths


def verify_catalog(locked_paths: list[str]) -> None:
    catalog_path = ACCEPTANCE / "acceptance-catalog.yaml"
    catalog = load_mapping(catalog_path, "base acceptance catalog")
    features = catalog.get("features")
    if not isinstance(features, list):
        fail("base acceptance catalog features must be a list")
    catalog_paths = [entry.get("file") if isinstance(entry, dict) else None for entry in features]
    if catalog_paths != locked_paths:
        fail(
            "base acceptance catalog paths differ from the lock: "
            f"catalog={catalog_paths}, lock={locked_paths}"
        )
    try:
        frozen_catalog = authority_file(
            "tests/acceptance/acceptance-catalog.yaml", ROOT
        )
    except GitAuthorityError as error:
        fail(f"cannot read tagged base acceptance catalog: {error}")
    observed_digest = hashlib.sha256(frozen_catalog).hexdigest()
    if observed_digest != EXPECTED_CATALOG_SHA256:
        fail(
            "base acceptance catalog bytes drifted: "
            f"{observed_digest} != {EXPECTED_CATALOG_SHA256}"
        )


def mapping_feature_name(value: Any) -> str:
    if not isinstance(value, str):
        fail(f"base scenario feature_file must be a string: {value!r}")
    path = PurePosixPath(value)
    if path.parts[:2] != ("tests", "acceptance") or len(path.parts) != 3:
        fail(f"base scenario feature_file must be tests/acceptance/<name>.feature: {value!r}")
    return locked_feature_name(path.name)


def verify_mapping(locked_paths: list[str]) -> None:
    mapping_path = ACCEPTANCE / "executable-mapping.yaml"
    mapping = load_mapping(mapping_path, "base executable mapping")
    scenarios = mapping.get("scenarios")
    if not isinstance(scenarios, list):
        fail("base executable mapping scenarios must be a list")
    if mapping.get("scenario_count") != EXPECTED_SCENARIO_COUNT:
        fail(
            "base executable mapping scenario_count changed: "
            f"{mapping.get('scenario_count')!r} != {EXPECTED_SCENARIO_COUNT}"
        )
    if len(scenarios) != EXPECTED_SCENARIO_COUNT:
        fail(
            "base executable mapping scenario entries changed: "
            f"{len(scenarios)} != {EXPECTED_SCENARIO_COUNT}"
        )

    scenario_ids: list[str] = []
    mapped_paths: list[str] = []
    for index, scenario in enumerate(scenarios):
        if not isinstance(scenario, dict):
            fail(f"invalid base scenario entry at index {index}: {scenario!r}")
        scenario_id = scenario.get("scenario_id")
        if not isinstance(scenario_id, str) or not scenario_id:
            fail(f"invalid base scenario ID at index {index}: {scenario_id!r}")
        scenario_ids.append(scenario_id)
        mapped_paths.append(mapping_feature_name(scenario.get("feature_file")))

    duplicate_ids = sorted(
        scenario_id for scenario_id, count in Counter(scenario_ids).items() if count > 1
    )
    if duplicate_ids:
        fail(f"duplicate base scenario IDs: {duplicate_ids}")
    identity_digest = canonical_sha256(scenario_ids)
    if identity_digest != EXPECTED_SCENARIO_IDENTITY_SHA256:
        fail(
            "base ordered scenario identities drifted: "
            f"{identity_digest} != {EXPECTED_SCENARIO_IDENTITY_SHA256}"
        )

    mapped_path_set = set(mapped_paths)
    locked_path_set = set(locked_paths)
    missing_paths = sorted(locked_path_set - mapped_path_set)
    extra_paths = sorted(mapped_path_set - locked_path_set)
    if missing_paths or extra_paths:
        fail(
            "base executable mapping paths differ from the lock: "
            f"missing={missing_paths}, extra={extra_paths}"
        )

    try:
        frozen_mapping = authority_file(
            "tests/acceptance/executable-mapping.yaml", ROOT
        )
    except GitAuthorityError as error:
        fail(f"cannot read tagged base executable mapping: {error}")
    observed_digest = hashlib.sha256(frozen_mapping).hexdigest()
    if observed_digest != EXPECTED_MAPPING_SHA256:
        fail(
            "base executable mapping bytes drifted: "
            f"{observed_digest} != {EXPECTED_MAPPING_SHA256}"
        )


def supplemental_feature_name(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    path = PurePosixPath(value)
    if len(path.parts) == 1:
        return path.name
    if path.parts[:2] == ("tests", "acceptance") and len(path.parts) == 3:
        return path.name
    return None


def verify_supplemental_contract(locked_paths: list[str]) -> dict[str, int]:
    observed_paths = {
        path.relative_to(ACCEPTANCE).as_posix()
        for path in ACCEPTANCE.glob("**/*.feature")
        if path.is_file() and not path.is_symlink()
    }
    locked_path_set = set(locked_paths)
    supplemental_paths = observed_paths - locked_path_set

    # Supplemental files remain outside the byte-immutable base inventory.  Their
    # own source-derived mapping must nevertheless cover every additive scenario.
    if SUPPLEMENTAL_MAPPING.is_file():
        supplemental = load_mapping(SUPPLEMENTAL_MAPPING, "supplemental executable mapping")
        entries = supplemental.get("features")
        if not isinstance(entries, list):
            fail("supplemental executable mapping features must be a list")
        declared = [
            supplemental_feature_name(entry.get("path")) if isinstance(entry, dict) else None
            for entry in entries
        ]
        overlap = sorted(locked_path_set & {name for name in declared if name is not None})
        if overlap:
            fail(f"supplemental mapping overlaps locked base feature paths: {overlap}")

    structural, registry = validate_static(ROOT)
    if structural.problems:
        fail(
            "effective acceptance contract failed: "
            + json.dumps(
                [
                    {
                        "phase": problem.phase,
                        "code": problem.code,
                        "source": problem.source,
                        "expected": problem.expected,
                        "actual": problem.actual,
                    }
                    for problem in structural.problems
                ],
                ensure_ascii=False,
                sort_keys=True,
                default=str,
            )
        )
    raw_counts = registry.get("counts")
    counts = (
        {
            "base_features_locked": raw_counts.get("base_features"),
            "base_scenarios_locked": raw_counts.get("base_scenarios"),
            "supplemental_features_discovered": raw_counts.get("supplemental_features"),
            "supplemental_scenarios_discovered": raw_counts.get("supplemental_scenarios"),
            "supplemental_scenarios_mapped": raw_counts.get("supplemental_scenarios"),
            "effective_features": raw_counts.get("effective_features"),
            "effective_scenarios": raw_counts.get("effective_scenarios"),
        }
        if isinstance(raw_counts, dict)
        else None
    )
    if not isinstance(counts, dict):
        fail("supplemental acceptance validator returned no source-derived counts")
    expected = {
        "base_features_locked": EXPECTED_FEATURE_COUNT,
        "base_scenarios_locked": EXPECTED_SCENARIO_COUNT,
        "supplemental_features_discovered": len(supplemental_paths),
        "effective_features": EXPECTED_FEATURE_COUNT + len(supplemental_paths),
    }
    for key, value in expected.items():
        if counts.get(key) != value:
            fail(
                f"supplemental acceptance {key} mismatch: "
                f"{counts.get(key)!r} != {value!r}"
            )
    supplemental_scenarios = counts.get("supplemental_scenarios_discovered")
    mapped_scenarios = counts.get("supplemental_scenarios_mapped")
    effective_scenarios = counts.get("effective_scenarios")
    if (
        not isinstance(supplemental_scenarios, int)
        or isinstance(supplemental_scenarios, bool)
        or supplemental_scenarios < 1
        or mapped_scenarios != supplemental_scenarios
        or effective_scenarios != EXPECTED_SCENARIO_COUNT + supplemental_scenarios
    ):
        fail(
            "supplemental scenario mapping is not exact/source-derived: "
            f"discovered={supplemental_scenarios!r}, "
            f"mapped={mapped_scenarios!r}, effective={effective_scenarios!r}"
        )
    return {
        key: value
        for key, value in counts.items()
        if isinstance(value, int) and not isinstance(value, bool)
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--write",
        action="store_true",
        help="deprecated; byte-immutable base lock rewrites are forbidden",
    )
    parser.add_argument("--json-output", type=Path)
    args = parser.parse_args()
    if args.write:
        fail("base-v13.lock.yaml is byte-immutable; --write is forbidden")

    lock = load_mapping(LOCK, "base acceptance lock")
    features = validate_lock(lock)
    locked_paths = verify_tagged_base_feature_lock(features)
    verify_catalog(locked_paths)
    verify_mapping(locked_paths)
    counts = verify_supplemental_contract(locked_paths)

    rendered = yaml.safe_dump(
        lock,
        sort_keys=False,
        allow_unicode=True,
        width=110,
    )
    if LOCK.read_text(encoding="utf-8") != rendered:
        fail("base acceptance lock is noncanonical")
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(
            json.dumps(
                {
                    "status": "PASS",
                    "authority_zip_sha256": AUTHORITY_ZIP_SHA256,
                    "counts": counts,
                },
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
    print(
        "base v13 acceptance lock: PASS "
        f"(base {counts['base_features_locked']}/"
        f"{counts['base_scenarios_locked']}, supplemental "
        f"{counts['supplemental_features_discovered']}/"
        f"{counts['supplemental_scenarios_discovered']}, effective "
        f"{counts['effective_features']}/{counts['effective_scenarios']})"
    )


if __name__ == "__main__":
    main()
