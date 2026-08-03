from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .design_database import validate_physical_contracts
from .design_operations import OperationFacts
from .design_support import (
    DesignDocuments,
    contains_forbidden_marker,
    declared_fragment_relations,
    nonempty,
    physical_migration_name,
    physical_table_rows,
    unique_string_registry,
    valid_physical_grants,
    valid_physical_rls,
)


@dataclass(frozen=True)
class PersistenceFacts:
    database: dict[str, Any]
    table_set: set[str]
    migration_tables: set[str]
    global_relation_rows: list[str]
    physical_table_rows: dict[str, dict[str, Any]]
    base_relations: set[str]


def validate_persistence(
    documents: DesignDocuments,
    operations: OperationFacts,
) -> PersistenceFacts:
    root = documents.root
    result = documents.result
    addendum = documents.addendum
    persistence_contracts = documents.persistence_contracts
    base_schema_catalog = documents.base_schema_catalog
    persistence_global = documents.persistence_global
    physical_table_documents = documents.physical_table_documents

    database = addendum["database_delta"]
    tables = unique_string_registry(
        database["additive_tables"],
        result,
        "owner additive table registry",
    )
    table_set = set(tables)
    owner_migration_names = unique_string_registry(
        database["migrations"],
        result,
        "owner additive migration registry",
    )
    owner_migration_set = set(owner_migration_names)
    base_migration_names = sorted(
        path.name for path in (root / "specs/database/migrations").glob("*.sql")
    )
    base_relation_rows = [
        f"{table['schema']}.{table['table']}"
        for table in base_schema_catalog["tables"]
    ]
    base_relations = set(base_relation_rows)
    result.require(
        len(base_migration_names) == len(set(base_migration_names))
        and database["base_migrations"] == len(base_migration_names)
        and database["additive_migrations"] == len(owner_migration_names)
        and database["final_migrations"]
        == len(base_migration_names) + len(owner_migration_names),
        "owner addendum migration inventory does not reproduce its source-derived counts",
    )
    result.require(
        len(base_relation_rows) == len(base_relations)
        and database["base_active_tables"] == len(base_relations)
        and database["additive_table_count"] == len(table_set)
        and database["final_active_tables"] == len(base_relations) + len(table_set)
        and table_set.isdisjoint(base_relations),
        "owner addendum table inventory does not reproduce its source-derived counts",
    )
    migration_ownership = persistence_contracts["migration_ownership"]
    migration_names = list(migration_ownership)
    result.require(
        set(migration_names) == owner_migration_set
        and all(migration.endswith(".sql") for migration in migration_names),
        "persistence migration ownership keys are not set-equal to owner additive migrations",
    )
    migration_table_rows = [
        relation
        for migration in migration_names
        for relation in unique_string_registry(
            migration_ownership[migration],
            result,
            f"persistence relation registry {migration}",
        )
    ]
    migration_tables = set(migration_table_rows)
    result.require(
        len(migration_table_rows) == len(migration_tables)
        and migration_tables == table_set,
        "addendum persistence migration ownership is not set-equal to owner additive tables",
    )
    result.require(
        persistence_contracts["counts"]
        == {
            "base_tables": len(base_relations),
            "additive_tables": len(table_set),
            "final_active_tables": len(base_relations) + len(table_set),
            "migrations": len(base_migration_names) + len(owner_migration_names),
        },
        "addendum persistence counts do not match the enumerated table registries",
    )
    global_relation_inventory = persistence_global["relation_inventory"][
        "by_migration"
    ]
    global_relation_sets: dict[str, set[str]] = {}
    global_relation_rows: list[str] = []
    for migration, relations in global_relation_inventory.items():
        rows_for_migration = unique_string_registry(
            relations,
            result,
            f"global relation registry {migration}",
        )
        global_relation_sets[migration] = set(rows_for_migration)
        global_relation_rows.extend(rows_for_migration)
    result.require(
        owner_migration_set <= set(global_relation_sets)
        and all(
            not relations
            for migration, relations in global_relation_sets.items()
            if migration not in owner_migration_set
        )
        and len(global_relation_rows) == len(set(global_relation_rows))
        and set(global_relation_rows) == table_set,
        "global relation inventory is not a unique set-equal expansion of owner additive tables",
    )
    for migration in sorted(owner_migration_set & set(global_relation_sets)):
        result.require(
            global_relation_sets[migration]
            == set(migration_ownership.get(migration, [])),
            f"{migration}: global and persistence relation ownership drifted",
        )

    inventory_lock = persistence_global["inventory_lock"]
    global_migration_names = list(global_relation_inventory)
    expected_migration_sequence = base_migration_names + global_migration_names
    relation_delta_by_migration = inventory_lock["relation_delta_by_migration"]
    result.require(
        inventory_lock["migration_sequence"] == expected_migration_sequence
        and len(expected_migration_sequence) == len(set(expected_migration_sequence))
        and owner_migration_names
        == [
            migration
            for migration in global_migration_names
            if migration in owner_migration_set
        ],
        "global migration sequence is not the exact base plus enumerated post-base registry",
    )
    result.require(
        inventory_lock["base_migrations"] == len(base_migration_names)
        and inventory_lock["additive_migrations"] == len(global_migration_names)
        and inventory_lock["hardening_migrations"]
        == len(global_migration_names) - len(owner_migration_names)
        and inventory_lock["post_base_migrations"] == len(global_migration_names)
        and inventory_lock["final_migrations"] == len(expected_migration_sequence)
        and inventory_lock["base_active_tables"] == len(base_relations)
        and inventory_lock["additive_tables"] == len(table_set)
        and inventory_lock["final_active_tables"]
        == len(base_relations) + len(table_set)
        and relation_delta_by_migration
        == {
            migration: len(relations)
            for migration, relations in global_relation_sets.items()
        },
        "global inventory lock does not reproduce the enumerated migrations and relations",
    )

    physical_rows: dict[str, dict[str, Any]] = {}
    # A post-base migration may intentionally add no relation (0030 is a
    # submission-session hardening migration).  Seed the complete owner set so
    # an explicit zero-relation migration is distinguishable from a missing
    # physical fragment while preserving exact migration set equality.
    physical_relations_by_migration: dict[str, set[str]] = {
        migration: set() for migration in owner_migration_set
    }
    for path, document in physical_table_documents.items():
        raw_rows = document.get("tables", document.get("table_contracts", {}))
        rows_for_file = physical_table_rows(document)
        raw_row_count = len(raw_rows) if isinstance(raw_rows, (dict, list)) else 0
        migration_name = physical_migration_name(document)
        declared_relations = declared_fragment_relations(document)
        if declared_relations is not None:
            declared_relation_rows = unique_string_registry(
                declared_relations,
                result,
                f"{path} declared relation registry",
            )
            result.require(
                set(declared_relation_rows) == set(rows_for_file),
                f"{path}: declared relation registry is not set-equal to physical rows",
            )
        result.require(
            document["status"] in {"REVIEW_REQUIRED", "FINAL"}
            and raw_row_count == len(rows_for_file)
            and migration_name in owner_migration_set
            and not (set(rows_for_file) & set(physical_rows)),
            f"{path}: physical status, migration ownership or relation uniqueness is invalid",
        )
        if migration_name in owner_migration_set:
            physical_relations_by_migration.setdefault(migration_name, set()).update(
                rows_for_file
            )
        physical_rows.update(rows_for_file)
    result.require(
        set(physical_relations_by_migration) == owner_migration_set
        and set(physical_rows) == table_set
        and persistence_global["status"] in {"REVIEW_REQUIRED", "FINAL"},
        "physical additive table contracts are not an exact owner relation union",
    )
    for migration in sorted(
        owner_migration_set & set(physical_relations_by_migration)
    ):
        result.require(
            physical_relations_by_migration[migration]
            == set(migration_ownership.get(migration, []))
            == global_relation_sets.get(migration, set()),
            f"{migration}: physical, persistence and global relation registries drifted",
        )

    economics_migrations = [
        migration
        for migration in owner_migration_names
        if migration.startswith("0029_")
    ]
    result.require(
        len(economics_migrations) == 1,
        "owner migration registry must identify one 0029 product-economics migration",
    )
    if len(economics_migrations) == 1:
        economics_migration = economics_migrations[0]
        global_creation_order = unique_string_registry(
            persistence_global["migration_plan"][economics_migration][
                "creation_order"
            ],
            result,
            f"global creation order {economics_migration}",
        )
        result.require(
            set(global_creation_order)
            == global_relation_sets.get(economics_migration, set())
            == physical_relations_by_migration.get(economics_migration, set()),
            f"{economics_migration}: global creation order is not set-equal to the physical registry",
        )
        global_order_index = {
            relation: index for index, relation in enumerate(global_creation_order)
        }
        for path, document in physical_table_documents.items():
            if physical_migration_name(document) != economics_migration:
                continue
            fragment_order = document.get("fragment_creation_order_assertion")
            if isinstance(fragment_order, list):
                fragment_rows = unique_string_registry(
                    fragment_order,
                    result,
                    f"{path} fragment creation order",
                )
                result.require(
                    set(fragment_rows) == set(physical_table_rows(document))
                    and all(row in global_order_index for row in fragment_rows)
                    and [global_order_index[row] for row in fragment_rows]
                    == sorted(global_order_index[row] for row in fragment_rows),
                    f"{path}: fragment creation order is not its exact global-order subsequence",
                )
            physical_registry = document.get("physical_relation_registry")
            if isinstance(physical_registry, dict) and isinstance(
                physical_registry.get("creation_order"), list
            ):
                physical_registry_order = unique_string_registry(
                    physical_registry["creation_order"],
                    result,
                    f"{path} physical relation creation order",
                )
                result.require(
                    physical_registry_order == global_creation_order
                    and physical_registry.get("exact_count")
                    == len(physical_registry_order),
                    f"{path}: physical relation registry drifted from global creation order",
                )
    validate_physical_contracts(root, result)
    for relation, row in physical_rows.items():
        columns = row.get("columns")
        if isinstance(columns, dict):
            column_names = list(columns)
        elif isinstance(columns, list):
            column_names = [column["name"] for column in columns]
        else:
            column_names = []
        constraints = row.get("constraints", {})
        primary_key = row.get("primary_key", constraints.get("primary_key"))
        grants = row.get("grants", row.get("privileges"))
        repository_contract = row.get(
            "repository_roundtrip",
            row.get(
                "repository_round_trip",
                row.get("roundtrip", row.get("repository")),
            ),
        )
        result.require(
            bool(column_names)
            and len(column_names) == len(set(column_names))
            and nonempty(primary_key)
            and valid_physical_grants(grants)
            and valid_physical_rls(row.get("rls"))
            and nonempty(row.get("retention"))
            and nonempty(repository_contract)
            and not contains_forbidden_marker(row),
            f"{relation}: physical columns, keys, grants, RLS, retention or repository contract is incomplete",
        )
    result.require(
        set(persistence_contracts["operation_transactions"])
        == operations.owner_operation_ids,
        "addendum persistence operation transaction set mismatch",
    )
    transaction_templates = set(persistence_contracts["transaction_templates"])
    for operation_id, transaction in persistence_contracts[
        "operation_transactions"
    ].items():
        template = transaction.split(" ", 1)[0]
        result.require(
            template in transaction_templates
            or transaction == "custom legal_hold_release",
            f"{operation_id}: unknown persistence transaction template {transaction}",
        )
    return PersistenceFacts(
        database=database,
        table_set=table_set,
        migration_tables=migration_tables,
        global_relation_rows=global_relation_rows,
        physical_table_rows=physical_rows,
        base_relations=base_relations,
    )
