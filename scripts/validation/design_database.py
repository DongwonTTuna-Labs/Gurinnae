from __future__ import annotations

from pathlib import Path
from typing import Any
import hashlib
import re

from .design_database_approval import _validate_approval_option_b
from .design_database_journeys import validate_journey_database
from .design_database_support import (
    PHYSICAL_TABLE_PATHS,
    _candidate_keys,
    _check_expressions,
    _column_names,
    _constraint_contracts,
    _foreign_keys,
    _generated_constraint_name,
    _key_columns,
    _parse_reference,
    _predicate_expressions,
    _rows,
    _validate_sql_expression,
)
from .design_support import physical_migration_name
from .loaders import load_yaml
from .models import Validation

def validate_derivation_hashes(
    root: Path,
    global_contract: dict[str, Any],
    result: Validation,
) -> None:
    snapshot = global_contract.get("relation_inventory", {}).get(
        "stable_derivation_snapshot", {}
    )
    pinned = snapshot.get("input_sha256")
    result.require(
        isinstance(pinned, dict),
        "database stable derivation snapshot input_sha256 must be a mapping",
    )
    if not isinstance(pinned, dict):
        return
    result.require(
        set(pinned) == set(PHYSICAL_TABLE_PATHS),
        "database stable derivation snapshot paths are not set-equal to physical fragments",
    )
    for relative in sorted(set(pinned) | set(PHYSICAL_TABLE_PATHS)):
        path = root / relative
        digest = pinned.get(relative)
        result.require(
            isinstance(digest, str)
            and re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
            f"{relative}: stable derivation digest is not lowercase SHA-256",
        )
        result.require(
            path.is_file(),
            f"{relative}: stable derivation input is missing",
        )
        if path.is_file() and isinstance(digest, str):
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            result.require(
                digest == actual,
                f"{relative}: stable derivation digest differs from exact current bytes",
            )


def validate_physical_contracts(root: Path, result: Validation) -> None:
    documents = {path: load_yaml(root / path) for path in PHYSICAL_TABLE_PATHS}
    global_contract = load_yaml(root / "specs/database/addendum/global.yaml")
    validate_derivation_hashes(root, global_contract, result)
    naming = global_contract["physical_conventions"]["constraint_naming"]
    result.require(
        naming["explicit_names_preserved"] is True
        and naming["max_bytes"] == 63
        and naming["kinds"]
        == {"primary_key": "pk", "foreign_key": "fk", "unique": "uq", "check": "ck"},
        "additive deterministic constraint naming contract is incomplete",
    )
    rows = {
        relation: row
        for document in documents.values()
        for relation, row in _rows(document).items()
    }
    _validate_approval_option_b(
        root,
        documents["specs/database/addendum/0026-agent-action-approval.yaml"],
        rows,
        result,
    )
    validate_journey_database(
        documents["specs/database/addendum/0028-governance-operations.yaml"],
        documents["specs/database/addendum/0027-communication-consent-delivery.yaml"],
        rows,
        result,
    )
    projector_firewall = global_contract["privilege_closure"][
        "public_projector_firewall"
    ]
    result.require(
        projector_firewall.get("role") == "gurine_public_projector"
        and set(projector_firewall.get("scanned_physical_fragments", []))
        == set(PHYSICAL_TABLE_PATHS),
        "public projector firewall does not scan the complete physical fragment registry",
    )
    forbidden_projector_schemas = set(
        projector_firewall.get("forbidden_direct_relation_schemas", [])
    )
    result.require(
        forbidden_projector_schemas == {"raw", "core", "intake", "editorial", "ops"},
        "public projector forbidden direct-relation schema set drifted",
    )
    expected_projector_grants = {
        relation: tuple(privileges)
        for relation, privileges in projector_firewall.get(
            "allowed_direct_public_relation_privileges", {}
        ).items()
    }
    actual_projector_grants: dict[str, tuple[str, ...]] = {}
    for relation, row in rows.items():
        grants = row.get("grants", row.get("privileges", {}))
        direct = grants.get("gurine_public_projector") if isinstance(grants, dict) else None
        if isinstance(direct, str):
            direct_values = (direct,)
        elif isinstance(direct, list):
            direct_values = tuple(str(value) for value in direct)
        else:
            direct_values = ()
        if direct_values:
            actual_projector_grants[relation] = direct_values
        schema = relation.split(".", 1)[0]
        result.require(
            schema not in forbidden_projector_schemas or not direct_values,
            f"{relation}: gurine_public_projector has forbidden direct raw/internal relation privileges {list(direct_values)}",
        )
    result.require(
        actual_projector_grants == expected_projector_grants,
        "gurine_public_projector direct relation privileges are not exact-set equal to the public projection allowlist",
    )
    economics_order = global_contract["migration_plan"][
        "0029_product_economics.sql"
    ]["creation_order"]
    economics_relations = {
        relation
        for document in documents.values()
        if physical_migration_name(document) == "0029_product_economics.sql"
        for relation in _rows(document)
    }
    result.require(
        bool(economics_order)
        and len(economics_order) == len(set(economics_order)) == len(economics_relations)
        and set(economics_order) == economics_relations
        and all(
            rows[relation].get("creation_order") == ordinal
            for ordinal, relation in enumerate(economics_order, 1)
        ),
        "0029 economics relations do not reproduce the canonical source-derived creation order",
    )
    base_catalog = load_yaml(root / "specs/database/schema-catalog.yaml")
    known_relations = {
        f"{table['schema']}.{table['table']}" for table in base_catalog["tables"]
    } | set(rows)
    for document in documents.values():
        known_relations.update(
            relation
            for relation in document.get("existing_relation_contracts", {})
            if isinstance(relation, str) and "." in relation
        )
        existing_changes = document.get("existing_relation_changes", [])
        if isinstance(document.get("migration"), dict):
            existing_changes = [
                *existing_changes,
                *document["migration"].get("existing_relation_changes", []),
            ]
        for change in existing_changes:
            if isinstance(change, dict):
                known_relations.update(
                    value
                    for key in ("relation", "target")
                    if isinstance((value := change.get(key)), str)
                    and "." in value
                )

    foreign_key_names: set[str] = set()
    constraint_names: set[str] = set()
    generated_constraint_count = 0
    parsed_expression_count = 0
    for relation, row in rows.items():
        columns = set(_column_names(row))
        candidates = _candidate_keys(row)
        result.require(
            all(set(candidate) <= columns for candidate in candidates),
            f"{relation}: primary or unique candidate references a missing source column",
        )
        for kind, contract, explicit_name in _constraint_contracts(row):
            name = explicit_name or _generated_constraint_name(relation, kind, contract)
            generated_constraint_count += int(explicit_name is None)
            result.require(
                len(name.encode()) <= naming["max_bytes"]
                and re.fullmatch(r"[a-z][a-z0-9_]*", name) is not None,
                f"{relation}: invalid physical constraint name {name}",
            )
            result.require(
                name not in constraint_names,
                f"{relation}: additive constraint name collision {name}",
            )
            constraint_names.add(name)
        for foreign_key in _foreign_keys(row):
            name = foreign_key.get("name")
            if isinstance(name, str):
                result.require(
                    name not in foreign_key_names,
                    f"{relation}: duplicate additive foreign-key name {name}",
                )
                foreign_key_names.add(name)
            source_columns = _key_columns(foreign_key.get("columns"))
            result.require(
                bool(source_columns) and set(source_columns) <= columns,
                f"{relation}: foreign key {name or source_columns} references a missing source column",
            )
            target = _parse_reference(foreign_key)
            result.require(
                target is not None,
                f"{relation}: foreign key {name or source_columns} has a malformed target reference",
            )
            if target is None:
                continue
            target_relation, target_columns = target
            result.require(
                len(source_columns) == len(target_columns),
                f"{relation}: foreign key {name or source_columns} source/target arity differs",
            )
            result.require(
                target_relation in known_relations,
                f"{relation}: foreign key {name or source_columns} targets unknown relation {target_relation}",
            )
            target_row = rows.get(target_relation)
            if target_row is None:
                continue
            result.require(
                set(target_columns) <= set(_column_names(target_row)),
                f"{relation}: foreign key {name or source_columns} targets missing columns on {target_relation}",
            )
            result.require(
                target_columns in _candidate_keys(target_row),
                f"{relation}: foreign key {name or source_columns} target is not an exact nonpartial candidate key on {target_relation}",
            )

        expressions = [
            *(('CHECK', expression) for expression in _check_expressions(row)),
            *(('predicate', expression) for expression in _predicate_expressions(row)),
        ]
        for kind, expression in expressions:
            _validate_sql_expression(relation, columns, expression, kind, result)
        parsed_expression_count += len(expressions)

    for path, document in documents.items():
        result.require(
            "/tmp/" not in (root / path).read_text(encoding="utf-8"),
            f"{path}: normative physical contract contains a temporary path",
        )

    result.stats["additive_foreign_keys_validated"] = sum(
        len(_foreign_keys(row)) for row in rows.values()
    )
    result.stats["additive_sql_expressions_parsed"] = parsed_expression_count
    result.stats["generated_constraint_names"] = generated_constraint_count
    result.stats["public_projector_direct_relation_grants"] = len(
        actual_projector_grants
    )
