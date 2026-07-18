"""Base-lock inventory and supplemental feature discovery."""
from __future__ import annotations

from pathlib import Path, PurePosixPath

from .supplemental_acceptance_core import (
    AUTHORITY_BASE_FEATURE_COUNT,
    AUTHORITY_BASE_SCENARIO_COUNT,
    AUTHORITY_SHA256,
    BASE_CATALOG,
    BASE_LOCK,
    BASE_MAPPING,
    BaseInventory,
    Checks,
    Scenario,
    canonical,
    digest_file,
    load,
    row_map,
)
from .supplemental_acceptance_features import parse_feature

def _regular_digest(root: Path, relative: str) -> str:
    path = root / relative
    if path.is_symlink() or not path.is_file():
        return "missing"
    return digest_file(path)


def base_inventory(root: Path, checks: Checks) -> BaseInventory:
    lock = load(root, BASE_LOCK, checks)
    checks.need(
        lock.get("authority_zip_sha256") == AUTHORITY_SHA256,
        "base_lock_authority",
        BASE_LOCK,
        AUTHORITY_SHA256,
        lock.get("authority_zip_sha256"),
    )
    checks.need(
        lock.get("feature_count") == AUTHORITY_BASE_FEATURE_COUNT,
        "base_feature_count",
        BASE_LOCK,
        AUTHORITY_BASE_FEATURE_COUNT,
        lock.get("feature_count"),
    )
    checks.need(
        lock.get("scenario_count") == AUTHORITY_BASE_SCENARIO_COUNT,
        "base_scenario_count",
        BASE_LOCK,
        AUTHORITY_BASE_SCENARIO_COUNT,
        lock.get("scenario_count"),
    )

    raw_features = lock.get("features")
    features = raw_features if isinstance(raw_features, list) else []
    feature_names = [
        row.get("path")
        for row in features
        if isinstance(row, dict) and isinstance(row.get("path"), str)
    ]
    locked_name_set = checks.unique(feature_names, f"{BASE_LOCK}#features")
    observed_descriptors: list[dict[str, object]] = []
    source_scenarios: list[Scenario] = []
    for row in features:
        if not isinstance(row, dict) or not isinstance(row.get("path"), str):
            continue
        name = row["path"]
        relative = f"tests/acceptance/{name}"
        path = root / relative
        checks.need(
            PurePosixPath(name).name == name,
            "base_feature_path",
            name,
            "direct feature filename",
            name,
        )
        if path.is_symlink() or not path.is_file():
            checks.need(
                False,
                "base_feature_missing",
                name,
                "regular file",
                "missing",
            )
            continue
        actual = {
            "path": name,
            "sha256": digest_file(path),
            "size": path.stat().st_size,
        }
        observed_descriptors.append(actual)
        checks.need(
            row == actual,
            "base_feature_drift",
            name,
            row,
            actual,
        )
        source_scenarios.extend(
            parse_feature(path, relative, checks, supplemental=False)
        )

    checks.need(
        len(locked_name_set)
        == len(observed_descriptors)
        == AUTHORITY_BASE_FEATURE_COUNT,
        "base_feature_count",
        BASE_LOCK,
        AUTHORITY_BASE_FEATURE_COUNT,
        len(observed_descriptors),
    )
    checks.need(
        lock.get("feature_manifest_sha256") == canonical(observed_descriptors),
        "base_feature_manifest_drift",
        BASE_LOCK,
        lock.get("feature_manifest_sha256"),
        canonical(observed_descriptors),
    )

    for section, relative, filename in (
        ("catalog", BASE_CATALOG, "acceptance-catalog.yaml"),
        ("executable_mapping", BASE_MAPPING, "executable-mapping.yaml"),
    ):
        descriptor = lock.get(section)
        actual = {"path": filename, "sha256": _regular_digest(root, relative)}
        checks.need(
            descriptor == actual,
            "base_byte_drift",
            relative,
            descriptor,
            actual,
        )

    catalog = load(root, BASE_CATALOG, checks)
    catalog_rows = (
        catalog.get("features")
        if isinstance(catalog.get("features"), list)
        else []
    )
    catalog_names = [
        row.get("file")
        for row in catalog_rows
        if isinstance(row, dict) and isinstance(row.get("file"), str)
    ]
    catalog_name_set = checks.unique(catalog_names, f"{BASE_CATALOG}#features")
    checks.same(
        locked_name_set,
        catalog_name_set,
        "base feature catalog",
        ("lock", "catalog"),
    )
    checks.need(
        catalog_names == feature_names,
        "base_catalog_order",
        BASE_CATALOG,
        feature_names,
        catalog_names,
    )

    source_ids = [row.scenario_id for row in source_scenarios]
    source_id_set = checks.unique(source_ids, "base feature scenario IDs")
    mapping = load(root, BASE_MAPPING, checks)
    raw_mapping_rows = (
        mapping.get("scenarios")
        if isinstance(mapping.get("scenarios"), list)
        else []
    )
    mapped = row_map(
        raw_mapping_rows,
        "scenario_id",
        f"{BASE_MAPPING}#scenarios",
        checks,
    )
    mapped_ids = [
        row.get("scenario_id")
        for row in raw_mapping_rows
        if isinstance(row, dict) and isinstance(row.get("scenario_id"), str)
    ]
    checks.same(
        source_id_set,
        set(mapped),
        "base feature/mapping identity",
        ("features", "mapping"),
    )
    checks.need(
        source_ids == mapped_ids,
        "base_scenario_order",
        BASE_MAPPING,
        source_ids,
        mapped_ids,
    )
    checks.need(
        len(source_scenarios)
        == catalog.get("scenario_count")
        == mapping.get("scenario_count")
        == AUTHORITY_BASE_SCENARIO_COUNT,
        "base_scenario_count",
        "base catalog/mapping/source",
        AUTHORITY_BASE_SCENARIO_COUNT,
        {
            "source": len(source_scenarios),
            "catalog": catalog.get("scenario_count"),
            "mapping": mapping.get("scenario_count"),
        },
    )
    checks.need(
        lock.get("ordered_scenario_identity_sha256") == canonical(mapped_ids),
        "base_scenario_identity_drift",
        BASE_LOCK,
        lock.get("ordered_scenario_identity_sha256"),
        canonical(mapped_ids),
    )

    source_by_id = {row.scenario_id: row for row in source_scenarios}
    for scenario_id, expected in source_by_id.items():
        row = mapped.get(scenario_id)
        if row is None:
            continue
        actual_identity = (
            row.get("feature_file"),
            row.get("scenario_title"),
        )
        expected_identity = (expected.feature_file, expected.scenario_title)
        checks.need(
            actual_identity == expected_identity,
            "base_mapping_identity",
            scenario_id,
            expected_identity,
            actual_identity,
        )
        checks.need(
            row.get("skip_policy") == "FORBIDDEN",
            "skip_policy",
            scenario_id,
            "FORBIDDEN",
            row.get("skip_policy"),
        )

    return BaseInventory(
        feature_names=tuple(feature_names),
        scenarios=tuple(source_scenarios),
    )


def discover_supplemental(
    root: Path,
    base: BaseInventory,
    checks: Checks,
) -> tuple[list[str], list[Scenario]]:
    directory = root / "tests/acceptance"
    base_names = set(base.feature_names)
    paths: list[str] = []
    scenarios: list[Scenario] = []
    for path in sorted(directory.glob("**/*.feature")):
        name = path.relative_to(directory).as_posix()
        if name in base_names:
            continue
        relative = path.relative_to(root).as_posix()
        paths.append(relative)
        scenarios.extend(
            parse_feature(path, relative, checks, supplemental=True)
        )
    supplemental_ids = checks.unique(
        (row.scenario_id for row in scenarios),
        "supplemental scenario IDs",
    )
    base_ids = {row.scenario_id for row in base.scenarios}
    checks.need(
        not (base_ids & supplemental_ids),
        "scenario_collision",
        "base/supplemental scenarios",
        [],
        sorted(base_ids & supplemental_ids),
    )
    checks.need(
        bool(paths),
        "missing_supplemental_features",
        "tests/acceptance",
        ">=1",
        0,
    )
    return paths, scenarios



