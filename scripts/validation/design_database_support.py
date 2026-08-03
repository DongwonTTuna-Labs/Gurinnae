from __future__ import annotations

from typing import Any
import hashlib
import json
import re

from pglast import parse_sql
from pglast.visitors import Visitor

from .models import Validation

PHYSICAL_TABLE_PATHS = (
    "specs/database/addendum/0025-evidence-snapshots-search.yaml",
    "specs/database/addendum/0026-agent-action-approval.yaml",
    "specs/database/addendum/0027-communication-consent-delivery.yaml",
    "specs/database/addendum/0028-governance-operations.yaml",
    "specs/database/addendum/0029-outcome-cost.yaml",
    "specs/database/addendum/0029-commercial-core.yaml",
    "specs/database/addendum/0029-invoice-revenue-sku.yaml",
    "specs/database/addendum/0029-funding-disclosure.yaml",
    "specs/database/addendum/0032-relay-model-catalog.yaml",
    "specs/database/addendum/0033-provider-control-execution.yaml",
    "specs/database/addendum/0035-r6b-agent-runtime-activation.yaml",
    "specs/database/addendum/0036-r6b-pipeline-activation.yaml",
    "specs/database/addendum/0037-r6c-conflict-investigation.yaml",
)

R6C_FORWARD_CANDIDATE_KEY_PATH = (
    "specs/database/addendum/0037-r6c-conflict-investigation.yaml"
)

APPROVAL_BINDING_V1_FIELDS = (
    "schemaVersion",
    "proposalId",
    "proposalVersion",
    "actionKind",
    "originDigest",
    "contentDigest",
    "rationaleDigest",
    "targetType",
    "targetId",
    "targetVersion",
    "targetDigest",
    "objectScopeDigest",
    "operationId",
    "requiredCapability",
    "targetRequestDigest",
    "previewId",
    "approvalSubjectDigest",
    "evidenceSetDigest",
    "contraryEvidenceSetDigest",
    "uncertaintySetDigest",
    "riskAssessmentDigest",
    "policySnapshotDigest",
    "conflictSnapshotDigest",
    "expectedEffectDigest",
    "reversible",
    "quorumPlanDigest",
    "effectIdempotencyKeySha256",
    "notBefore",
    "expiresAt",
    "actionDetailKind",
    "actionDetail",
    "actionDetailDigest",
)

APPROVAL_DETAIL_RELATIONS = {
    "HYPOTHESIS": "ops.action_approval_hypothesis_details",
    "CLAIM": "ops.action_approval_claim_details",
    "TASK": "ops.action_approval_task_details",
    "COMPARABLE": "ops.action_approval_comparable_details",
    "COMMUNICATION": "ops.action_approval_communication_details",
    "PUBLICATION": "ops.action_approval_publication_details",
    "RETRACTION": "ops.action_approval_retraction_details",
    "RULE_ACTIVATION": "ops.action_approval_rule_activation_details",
    "ROLE_GRANT": "ops.action_approval_role_grant_details",
    "KILL_SWITCH": "ops.action_approval_kill_switch_details",
    "COMMUNICATION_AUTHORIZATION": "ops.action_approval_communication_authorization_details",
    "ASSET_RIGHTS_DECISION": "ops.action_approval_asset_rights_details",
    "RETENTION_SCHEDULE": "ops.action_approval_retention_schedule_details",
    "FUNDING_DISCLOSURE": "ops.action_approval_funding_disclosure_details",
    "CAPABILITY_ACTIVATION": "ops.action_approval_capability_activation_details",
    "RESPONSE_POLICY_CALENDAR": "ops.action_approval_response_policy_calendar_details",
    "COMMERCIAL_CONTROL": "ops.action_approval_commercial_control_details",
    "PROVIDER_CONTROL": "ops.action_approval_provider_control_details",
}


class _ColumnReferenceCollector(Visitor):
    def __init__(self) -> None:
        super().__init__()
        self.references: set[str] = set()

    def visit_ColumnRef(self, _ancestors: Any, node: Any) -> None:
        self.references.add(
            ".".join(getattr(field, "sval", "*") for field in node.fields)
        )


def _rows(document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    raw = document.get("tables", document.get("table_contracts", {}))
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, list):
        return {row["relation"]: row for row in raw}
    return {}


def _column_names(row: dict[str, Any]) -> list[str]:
    columns = row.get("columns")
    if isinstance(columns, dict):
        return list(columns)
    if isinstance(columns, list):
        return [column["name"] for column in columns]
    return []


def _constraint_rows(row: dict[str, Any], *keys: str) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    constraints = row.get("constraints", {})
    for key in keys:
        for source in (row.get(key), constraints.get(key)):
            if isinstance(source, list):
                values.extend(item for item in source if isinstance(item, dict))
    return values


def _key_columns(value: Any) -> tuple[str, ...]:
    if isinstance(value, list):
        return tuple(str(column) for column in value)
    if isinstance(value, dict) and isinstance(value.get("columns"), list):
        return tuple(str(column) for column in value["columns"])
    return ()


def _candidate_keys(row: dict[str, Any]) -> set[tuple[str, ...]]:
    constraints = row.get("constraints", {})
    candidates = {
        key
        for key in (
            _key_columns(row.get("primary_key", constraints.get("primary_key"))),
        )
        if key
    }
    for unique in _constraint_rows(row, "uniques", "unique", "unique_constraints"):
        columns = _key_columns(unique.get("columns"))
        if columns and not unique.get("where") and not unique.get("predicate"):
            candidates.add(columns)
    return candidates


def _added_candidate_keys(
    document: dict[str, Any],
    rows: dict[str, dict[str, Any]],
    result: Validation,
) -> dict[str, tuple[tuple[str, tuple[str, ...]], ...]]:
    """Parse only explicit forward candidate keys from the R6c addendum."""

    changes = document.get("existing_relation_changes")
    result.require(
        isinstance(changes, list),
        "R6c existing_relation_changes must be a list",
    )
    if not isinstance(changes, list):
        return {}

    additions: dict[str, list[tuple[str, tuple[str, ...]]]] = {}
    seen_relations: set[str] = set()
    seen_names: set[str] = set()
    seen_keys: set[tuple[str, tuple[str, ...]]] = set()

    for change_index, change in enumerate(changes, 1):
        if not isinstance(change, dict):
            result.require(
                False,
                f"R6c existing relation change {change_index} must be a mapping",
            )
            continue
        raw_keys = change.get("added_candidate_keys")
        if raw_keys is None:
            continue
        relation = change.get("relation")
        relation_valid = (
            isinstance(relation, str)
            and re.fullmatch(r"[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*", relation)
            is not None
            and relation in rows
        )
        result.require(
            relation_valid,
            f"R6c existing relation change {change_index} targets an unknown relation {relation!r}",
        )
        keys_valid = isinstance(raw_keys, list) and bool(raw_keys)
        result.require(
            keys_valid,
            f"R6c added_candidate_keys for {relation!r} must be a nonempty list",
        )
        if not relation_valid or not keys_valid or not isinstance(relation, str):
            continue
        result.require(
            relation not in seen_relations,
            f"R6c added candidate-key relation is declared more than once: {relation}",
        )
        seen_relations.add(relation)
        existing_candidates = _candidate_keys(rows[relation])
        relation_columns = set(_column_names(rows[relation]))

        for key_index, raw_key in enumerate(raw_keys, 1):
            exact_shape = isinstance(raw_key, dict) and set(raw_key) == {
                "name",
                "columns",
            }
            result.require(
                exact_shape,
                f"{relation}: added candidate key {key_index} must contain exactly name and columns",
            )
            if not exact_shape or not isinstance(raw_key, dict):
                continue
            name = raw_key.get("name")
            raw_columns = raw_key.get("columns")
            name_valid = (
                isinstance(name, str)
                and len(name.encode()) <= 63
                and re.fullmatch(r"[a-z][a-z0-9_]*", name) is not None
            )
            columns_valid = (
                isinstance(raw_columns, list)
                and bool(raw_columns)
                and all(
                    isinstance(column, str)
                    and re.fullmatch(r"[a-z][a-z0-9_]*", column) is not None
                    for column in raw_columns
                )
                and len(raw_columns) == len(set(raw_columns))
            )
            result.require(
                name_valid,
                f"{relation}: added candidate key {key_index} has an invalid name",
            )
            result.require(
                columns_valid,
                f"{relation}: added candidate key {key_index} has invalid or duplicate columns",
            )
            if not name_valid or not columns_valid or not isinstance(name, str):
                continue
            columns = tuple(str(column) for column in raw_columns)
            columns_exist = set(columns) <= relation_columns
            result.require(
                columns_exist,
                f"{relation}: added candidate key {name} references unknown columns",
            )
            key_identity = (relation, columns)
            key_is_new = columns not in existing_candidates and key_identity not in seen_keys
            result.require(
                key_is_new,
                f"{relation}: added candidate key {name} duplicates an existing or forward key",
            )
            name_is_new = name not in seen_names
            result.require(
                name_is_new,
                f"R6c added candidate-key name is duplicated: {name}",
            )
            if not columns_exist or not key_is_new or not name_is_new:
                continue
            seen_names.add(name)
            seen_keys.add(key_identity)
            additions.setdefault(relation, []).append((name, columns))

    return {
        relation: tuple(keys)
        for relation, keys in additions.items()
    }


def _foreign_keys(row: dict[str, Any]) -> list[dict[str, Any]]:
    return _constraint_rows(row, "foreign_keys", "deferred_foreign_keys")


def _check_expressions(row: dict[str, Any]) -> list[str]:
    expressions: list[str] = []
    constraints = row.get("constraints", {})
    for source in (row.get("checks"), constraints.get("checks")):
        if not isinstance(source, list):
            continue
        for check in source:
            expression = check.get("expression") if isinstance(check, dict) else check
            if isinstance(expression, str):
                expressions.append(expression)
    return expressions


def _predicate_expressions(row: dict[str, Any]) -> list[str]:
    expressions: list[str] = []
    constraints = row.get("constraints", {})
    sources = [
        row.get("indexes"),
        constraints.get("partial_unique"),
        row.get("uniques"),
        row.get("unique_constraints"),
    ]
    for source in sources:
        if not isinstance(source, list):
            continue
        for item in source:
            if not isinstance(item, dict):
                continue
            predicate = item.get("where", item.get("predicate"))
            if isinstance(predicate, str):
                expressions.append(predicate)
    return expressions


def _constraint_contracts(row: dict[str, Any]) -> list[tuple[str, Any, str | None]]:
    constraints = row.get("constraints", {})
    contracts: list[tuple[str, Any, str | None]] = []
    primary = row.get("primary_key", constraints.get("primary_key"))
    if primary:
        contracts.append(
            (
                "pk",
                {"ordinal": 1, "value": primary},
                primary.get("name") if isinstance(primary, dict) else None,
            )
        )
    for kind, keys in (
        ("fk", ("foreign_keys", "deferred_foreign_keys")),
        ("uq", ("uniques", "unique", "unique_constraints")),
        ("ck", ("checks",)),
    ):
        ordinal = 0
        for key in keys:
            for source in (row.get(key), constraints.get(key)):
                if not isinstance(source, list):
                    continue
                for contract in source:
                    ordinal += 1
                    explicit = contract.get("name") if isinstance(contract, dict) else None
                    contracts.append(
                        (kind, {"ordinal": ordinal, "value": contract}, explicit)
                    )
    return contracts


def _generated_constraint_name(relation: str, kind: str, contract: Any) -> str:
    canonical = json.dumps(
        contract,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    material = f"{relation}\0{kind}\0{contract['ordinal']}\0{canonical}".encode()
    return f"g_{kind}_{hashlib.sha256(material).hexdigest()[:20]}"


def _validate_sql_expression(
    relation: str,
    columns: set[str],
    expression: str,
    kind: str,
    result: Validation,
) -> None:
    try:
        tree = parse_sql(f"SELECT 1 WHERE ({expression})")
    except Exception:
        result.require(False, f"{relation}: {kind} is not valid PostgreSQL: {expression}")
        return
    collector = _ColumnReferenceCollector()
    collector(tree)
    missing = {
        reference
        for reference in collector.references
        if reference.split(".", 1)[0] not in columns and reference != relation
    }
    result.require(
        not missing,
        f"{relation}: {kind} references non-column identifiers {sorted(missing)}",
    )


def _parse_reference(foreign_key: dict[str, Any]) -> tuple[str, tuple[str, ...]] | None:
    reference = foreign_key.get(
        "references",
        foreign_key.get("references_requires_0026_candidate_key"),
    )
    if isinstance(reference, str):
        match = re.fullmatch(
            r"([a-z][a-z0-9_]*\.[a-z][a-z0-9_]*)\(([^()]+)\)",
            reference.strip(),
        )
        if not match:
            return None
        return match.group(1), tuple(
            column.strip() for column in match.group(2).split(",")
        )
    target = foreign_key.get("target")
    target_columns = foreign_key.get("target_columns")
    if isinstance(target, str) and isinstance(target_columns, list):
        return target, tuple(str(column) for column in target_columns)
    return None
