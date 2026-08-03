from __future__ import annotations

from typing import Any

from pglast import parse_sql
from pglast.parser import ParseError
from pglast.stream import RawStream

from .models import Validation


_RELATION = "ops.action_approval_economics_import_details"
_CHECK_NAME = "action_approval_economics_import_details_evidence_ck"
_EXPECTED_CHECK = " ".join(
    """
cardinality(source_evidence_segment_ids) = cardinality(source_evidence_digests)
AND cardinality(source_evidence_segment_ids) BETWEEN 1 AND 1000
AND ops.economics_uuid_array_is_sorted_unique_v1(source_evidence_segment_ids)
AND ops.sha256_text_array_is_valid_v1(source_evidence_digests::text[])
""".split()
)


def _normalized(value: Any) -> str:
    return " ".join(value.split()) if isinstance(value, str) else ""


def _canonical_expression(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        statement = parse_sql(f"SELECT ({value})")[0].stmt
    except (IndexError, ParseError):
        return None
    return RawStream()(statement.targetList[0].val)


def validate_economics_evidence_pair_contract(
    contract: dict[str, Any],
    result: Validation,
) -> None:
    relation = contract.get("tables", {}).get(_RELATION, {})
    columns = relation.get("columns", {})
    column_order = relation.get("column_order")
    result.require(
        columns.get("source_evidence_segment_ids")
        == {"type": "uuid[]", "nullable": False}
        and columns.get("source_evidence_digests")
        == {"type": "char(64)[]", "nullable": False}
        and isinstance(column_order, list)
        and any(
            column_order[index:index + 2]
            == ["source_evidence_segment_ids", "source_evidence_digests"]
            for index in range(max(0, len(column_order) - 1))
        ),
        "0041 evidence ID/digest pair columns are not exact and adjacent",
    )
    checks = relation.get("checks")
    evidence_checks = [
        row
        for row in checks or []
        if isinstance(row, dict) and row.get("name") == _CHECK_NAME
    ] if isinstance(checks, list) else []
    result.require(
        len(evidence_checks) == 1
        and set(evidence_checks[0]) == {"name", "expression"}
        and _canonical_expression(evidence_checks[0].get("expression"))
        == _canonical_expression(_EXPECTED_CHECK),
        "0041 evidence pair check must sort unique IDs while preserving parallel digest order",
    )
    source_binding = _normalized(relation.get("source_binding_contract")).lower()
    immutable = _normalized(relation.get("immutable_binding")).lower()
    result.require(
        "parallel id-sorted locked pairs" in source_binding
        and "ids are unique" in source_binding
        and "repeated valid digests are allowed" in source_binding
        and "parallel digest" in immutable
        and "may repeat" in immutable
        and "cardinality-equal id and digest pairs exactly match" in immutable,
        "0041 evidence pair-order and repeated-digest semantics are incomplete",
    )
