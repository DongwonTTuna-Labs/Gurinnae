from __future__ import annotations

from typing import Any
import hashlib
import json
import re

from pglast import parse_sql
from pglast.visitors import Visitor

from .design_database_relations import (
    _added_candidate_keys,
    _candidate_keys,
    _column_names,
    _foreign_keys,
    _key_columns,
    _rows,
)
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
    "specs/database/addendum/0038-r6d-legal-hardening.yaml",
    "specs/database/addendum/0039-r6d-authority-closure.yaml",
    "specs/database/addendum/0040-r6d-privacy-authority-closure.yaml",
    "specs/database/addendum/0041-f9-natural-person-name-guard-closure.yaml",
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
