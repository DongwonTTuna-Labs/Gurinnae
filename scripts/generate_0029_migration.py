"""Generate the 0029 product-economics DDL from the pinned addendum registry.

This is intentionally source-derived: table/column/order changes belong in the
YAML fragments and a regenerated migration is the reviewable artifact.
"""
from __future__ import annotations

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME_ROLES = [
    "gurine_workflow_worker", "gurine_control_api", "gurine_auditor",
    "gurine_public_projector", "gurine_public_api", "gurine_submission_api",
    "gurine_ingest_worker", "gurine_analysis_worker", "gurine_notification_worker",
    "gurine_scheduler", "gurine_document_extractor", "gurine_identity_api",
]
ADDENDA = [
    ROOT / "specs/database/addendum/0029-outcome-cost.yaml",
    ROOT / "specs/database/addendum/0029-commercial-core.yaml",
    ROOT / "specs/database/addendum/0029-invoice-revenue-sku.yaml",
    ROOT / "specs/database/addendum/0029-funding-disclosure.yaml",
]


def ident(value: str) -> str:
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.]*", value):
        raise ValueError(f"unsafe identifier {value!r}")
    return value


def lit(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def cols(row: dict) -> dict:
    value = row.get("columns", {})
    if isinstance(value, dict):
        return value
    return {entry["name"]: entry for entry in value}


def qcolumns(value) -> list[str]:
    if isinstance(value, list):
        return [ident(str(v)) for v in value]
    if isinstance(value, str):
        return [ident(value)]
    raise ValueError(f"invalid column list {value!r}")


def index_key(value: str) -> str:
    value = str(value)
    match = re.fullmatch(r"([a-zA-Z_][a-zA-Z0-9_]*)(?:\s+(ASC|DESC))?", value)
    if match:
        return match.group(1) + (f" {match.group(2)}" if match.group(2) else "")
    # YAML index contracts may carry a closed SQL expression (for example a
    # date_trunc or a functional digest index). Keep it parenthesized while
    # rejecting statement separators and comments.
    if any(token in value for token in (";", "--", "/*", "*/")):
        raise ValueError(f"unsafe index expression {value!r}")
    return f"({value})"


def target_fk(value):
    if isinstance(value, str):
        match = re.fullmatch(r"([a-z_]+\.[a-z_]+)\(([^)]+)\)", value)
        if match:
            return match.group(1), qcolumns([part.strip() for part in match.group(2).split(",")])
    return None


def main() -> None:
    docs = [yaml.safe_load(path.read_text()) for path in ADDENDA]
    rows: dict[str, dict] = {}
    enums: dict[str, list[str]] = {}
    composites: dict[str, list[dict]] = {}
    composite_order: list[str] = []
    for doc in docs:
        rows.update(doc.get("tables", {}))
        for name, values in doc.get("closed_types", {}).items():
            if isinstance(values, list):
                enums[name] = [str(value) for value in values]
        registry = doc.get("physical_type_registry", {})
        for name, value in registry.get("composite_types", {}).items():
            fields = value.get("fields") if isinstance(value, dict) else None
            if isinstance(fields, list):
                composites[name] = fields
        explicit = registry.get("composite_creation_order", [])
        if isinstance(explicit, list):
            composite_order.extend(str(name) for name in explicit)

    # Four commercial input composites point at schema fragments whose field
    # contract is declared by reference.  Materialize their scalar fields from
    # the corresponding immutable relation instead of emitting an empty
    # placeholder type; generated identity/timestamp columns stay server-owned.
    input_sources = {
        "ops.usage_window_receipt_input_v1": "ops.usage_window_receipts",
        "ops.acquisition_source_receipt_input_v1": "ops.acquisition_source_receipts",
        "ops.invoice_usage_membership_input_v1": "ops.invoice_usage_memberships",
        "ops.commercial_qualification_receipt_input_v1": "ops.commercial_qualification_receipts",
    }
    generated_fields = {"id", "created_at", "recorded_at", "imported_at"}
    for composite, relation in input_sources.items():
        if composite not in composites and relation in rows:
            composites[composite] = [
                {"name": name, "type": spec["type"]}
                for name, spec in cols(rows[relation]).items()
                if name not in generated_fields
            ]

    print("BEGIN;")
    print("-- Source-derived 0029 physical registry: 24 relations in canonical creation order.")
    print("-- Existing 0001..0024 migrations are immutable; this migration is additive.")

    # The invoice fragment uses local aliases for these closed enum families.
    aliases = {
        "sku": "ops.commercial_sku",
        "invoice_line_kind": "text",
        "usage_meter_kind": "ops.usage_meter_kind",
        "readiness_stage": "text",
        "readiness_state": "text",
        "readiness_item_state": "text",
        "readiness_requirement_class": "text",
        "readiness_evidence_tier": "text",
        "readiness_measurement_unit": "text",
        "readiness_comparator": "text",
        "readiness_blocker_code": "text",
        "readiness_remediation_code": "text",
        "optional_capability_id": "text",
        "readiness_item_code": "text",
    }
    for name, values in sorted(enums.items()):
        if "." not in name:
            # Invoice/readiness aliases are deliberately represented as text
            # columns in the physical contract; only qualified PostgreSQL
            # enum names belong in this migration.
            continue
        qualified = ident(name)
        out = [f"DO $$ BEGIN CREATE TYPE {qualified} AS ENUM ("]
        out.append(", ".join(lit(value) for value in values))
        out.append("); EXCEPTION WHEN duplicate_object THEN NULL; END $$;")
        print(" ".join(out))
        print(f"REVOKE ALL ON TYPE {qualified} FROM PUBLIC;")
        print(f"GRANT USAGE ON TYPE {qualified} TO gurine_workflow_worker, gurine_control_api, gurine_auditor;")
    ordered_composites = [name for name in composite_order if name in composites]
    ordered_composites.extend(name for name in composites if name not in ordered_composites)
    # Respect composite -> composite[] dependencies even when an addendum's
    # registry lists the parent first for API readability.
    dependency_names = set(composites)
    sorted_composites: list[str] = []
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(name: str) -> None:
        if name in visited:
            return
        if name in visiting:
            raise ValueError(f"composite type cycle at {name}")
        visiting.add(name)
        for field in composites[name]:
            field_type = str(field["type"]).removesuffix("[]")
            if field_type in dependency_names:
                visit(field_type)
        visiting.remove(name)
        visited.add(name)
        sorted_composites.append(name)

    for name in ordered_composites:
        visit(name)
    for name in sorted_composites:
        fields = composites[name]
        # Composite input fields are closed in the source registry; use the
        # declared PostgreSQL scalar types and nullable fields as-is.
        qualified = ident(name)
        definitions = []
        for field in fields:
            ftype = aliases.get(field["type"], field["type"])
            definitions.append(f"{ident(field['name'])} {ftype}")
        print(f"CREATE TYPE {qualified} AS ({', '.join(definitions)});")
        print(f"REVOKE ALL ON TYPE {qualified} FROM PUBLIC;")
        acl = next((doc.get("physical_type_registry", {}).get("composite_types", {}).get(name, {}).get("acl", {}) for doc in docs if name in doc.get("physical_type_registry", {}).get("composite_types", {})), {})
        for role, grants in acl.items():
            if role in RUNTIME_ROLES and grants:
                print(f"GRANT {', '.join(ident(str(grant)) for grant in grants)} ON TYPE {qualified} TO {ident(role)};")

    # Numeric checks in the source fragments call this function while tables
    # are being created, so install it before any CHECK constraint is added.
    print("""CREATE OR REPLACE FUNCTION ops.round_half_even_numeric_v1(value numeric, scale integer)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
DECLARE factor numeric; magnitude numeric; whole numeric; fraction numeric; rounded numeric;
BEGIN
  IF scale < 0 OR scale > 12 THEN RAISE EXCEPTION 'round_half_even scale out of range' USING ERRCODE='22023'; END IF;
  factor := power(10::numeric, scale); magnitude := abs(value) * factor;
  whole := trunc(magnitude); fraction := magnitude - whole;
  rounded := CASE WHEN fraction < 0.5::numeric THEN whole
                  WHEN fraction > 0.5::numeric THEN whole + 1
                  WHEN mod(whole, 2) = 0 THEN whole ELSE whole + 1 END;
  RETURN sign(value) * rounded / factor;
END $$;
REVOKE ALL ON FUNCTION ops.round_half_even_numeric_v1(numeric, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.round_half_even_numeric_v1(numeric, integer) TO gurine_workflow_worker;
""")
    print("""CREATE OR REPLACE FUNCTION ops.offer_capability_v1_is_valid(value jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_typeof(value) = 'object'
    AND value ?& ARRAY['ordinal','capabilityCode','offerState','quotaKind','overagePolicy','entryDigest']
    AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(value) key
                    WHERE key NOT IN ('ordinal','capabilityCode','offerState','quotaKind','includedQuantity','overagePolicy','overageUnitPrice','activationPolicyDigest','consentPolicyDigest','costPolicyDigest','entryDigest'))
    AND value->>'entryDigest' ~ '^[0-9a-f]{64}$';
$$;
CREATE OR REPLACE FUNCTION ops.paid_evidence_packet_member_input_v1_is_valid(value jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_typeof(value) = 'object' AND value ?& ARRAY['ordinal','category','memberSetDigest']
    AND value->>'memberSetDigest' ~ '^[0-9a-f]{64}$';
$$;
CREATE OR REPLACE FUNCTION ops.paid_evidence_packet_subject_binding_v1_is_valid(value jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_typeof(value) = 'object' AND value ?& ARRAY['schemaVersion','packetId','organizationId','subjectKind','orderedMemberBindings']
    AND jsonb_typeof(value->'orderedMemberBindings') = 'array';
$$;
CREATE OR REPLACE FUNCTION ops.paid_evidence_packet_storage_record_v1_is_valid(value jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_typeof(value) = 'object' AND value ?& ARRAY['schemaVersion','packetId','packetVersion','state','packetDigest','packetRecordDigest']
    AND value->>'packetRecordDigest' ~ '^[0-9a-f]{64}$';
$$;
CREATE OR REPLACE FUNCTION ops.paid_evidence_packet_v1_is_valid(value jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT jsonb_typeof(value) = 'object' AND value ?& ARRAY['schemaVersion','packetId','packetVersion','subjectKind','terminalReceipt']
    AND jsonb_typeof(value->'terminalReceipt') = 'object';
$$;
REVOKE ALL ON FUNCTION ops.offer_capability_v1_is_valid(jsonb), ops.paid_evidence_packet_member_input_v1_is_valid(jsonb), ops.paid_evidence_packet_subject_binding_v1_is_valid(jsonb), ops.paid_evidence_packet_storage_record_v1_is_valid(jsonb), ops.paid_evidence_packet_v1_is_valid(jsonb) FROM PUBLIC;
""")

    relation_names = set(rows)
    for relation, row in sorted(rows.items(), key=lambda item: item[1].get("creation_order", 999)):
        relation = ident(relation)
        definitions = []
        for name, spec in cols(row).items():
            ftype = aliases.get(str(spec["type"]), str(spec["type"]))
            definition = f"{ident(name)} {ftype}"
            if not spec.get("nullable", True):
                definition += " NOT NULL"
            default = spec.get("default")
            if default not in (None, "NONE"):
                definition += f" DEFAULT {default}"
            definitions.append(definition)
        primary = row.get("primary_key")
        if isinstance(primary, dict):
            primary = primary.get("columns")
        if primary:
            definitions.append(f"CONSTRAINT {ident(relation.replace('.', '_') + '_pkey')} PRIMARY KEY ({', '.join(qcolumns(primary))})")
        print(f"CREATE TABLE {relation} (\n  {',\n  '.join(definitions)}\n);")
        print(f"ALTER TABLE {relation} OWNER TO gurine_migrator;")
        for unique in row.get("unique_constraints", []):
            name = unique.get("name") or relation.replace('.', '_') + "_" + "_".join(unique["columns"]) + "_uq"
            cols_sql = ", ".join(qcolumns(unique["columns"]))
            print(f"ALTER TABLE {relation} ADD CONSTRAINT {ident(name)} UNIQUE ({cols_sql});")
        for check in row.get("checks", []):
            if isinstance(check, str):
                name, expression = relation.replace('.', '_') + "_check", check
            else:
                name, expression = check.get("name"), check.get("expression")
            if name and expression:
                print(f"ALTER TABLE {relation} ADD CONSTRAINT {ident(name)} CHECK ({expression});")
        for index in row.get("indexes", []):
            if not isinstance(index, dict):
                continue
            index_name = index.get("name")
            keys = index.get("columns", index.get("keys", []))
            if not index_name or not keys:
                continue
            method = str(index.get("method", "btree")).lower()
            if method not in {"btree", "hash", "gin", "gist", "spgist", "brin"}:
                raise ValueError(f"unsupported index method {method!r}")
            unique = "UNIQUE " if index.get("unique") else ""
            include = index.get("include", [])
            include_sql = f" INCLUDE ({', '.join(index_key(item) for item in include)})" if include else ""
            predicate = index.get("where", index.get("predicate"))
            predicate_sql = f" WHERE {predicate}" if predicate and predicate not in ("null", "None") else ""
            print(f"CREATE {unique}INDEX {ident(str(index_name))} ON {relation} USING {method} ({', '.join(index_key(item) for item in keys)}){include_sql}{predicate_sql};")
        print(f"REVOKE ALL ON {relation} FROM PUBLIC, {', '.join(RUNTIME_ROLES)};")
        privileges = row.get("privileges", row.get("grants", {}))
        if isinstance(privileges, dict):
            for role in RUNTIME_ROLES:
                grants = privileges.get(role, [])
                if grants:
                    grant_sql = ", ".join(ident(str(privilege)) for privilege in grants)
                    print(f"GRANT {grant_sql} ON {relation} TO {ident(role)};")

    # Add only FKs whose target is in the same source-derived registry.  FKs
    # into the base authority are installed by its immutable migrations; this
    # avoids silently inventing composite candidate keys here.
    for relation, row in sorted(rows.items(), key=lambda item: item[1].get("creation_order", 999)):
        for fk in row.get("foreign_keys", []):
            target = target_fk(fk.get("references"))
            if not target or target[0] not in relation_names:
                continue
            source_columns = qcolumns(fk.get("columns"))
            target_relation, target_columns = target
            name = fk.get("name")
            if name:
                print(f"ALTER TABLE {ident(relation)} ADD CONSTRAINT {ident(name)} FOREIGN KEY ({', '.join(source_columns)}) REFERENCES {ident(target_relation)} ({', '.join(target_columns)}) ON DELETE RESTRICT;")

    print("""CREATE OR REPLACE FUNCTION ops.read_invoice_membership_v1(
  p_contract_period_id uuid, p_expected_contract_record_digest char(64),
  p_period_start date, p_period_end date, p_billing_cutoff_at timestamptz)
RETURNS SETOF ops.invoice_membership_read_row_v1
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp AS $$
  SELECT u.root_usage_fact_id, u.id, u.record_digest, u.meter_kind,
         u.period_start, u.period_end, u.measurement_state,
         m.membership_kind, m.invoice_id, m.membership_digest,
         CASE
           WHEN m.id IS NULL THEN 'MISSING_MEMBERSHIP'
           WHEN u.measurement_state <> 'COMPLETE' THEN 'USAGE_NOT_COMPLETE'
           WHEN m.measurement_state <> u.measurement_state THEN 'MEASUREMENT_STATE_MISMATCH'
           ELSE NULL
         END
  FROM ops.usage_facts u
  LEFT JOIN LATERAL (
    SELECT im.* FROM ops.invoice_usage_memberships im
    WHERE im.usage_fact_id = u.id
      AND im.recorded_at <= p_billing_cutoff_at
    ORDER BY im.revision DESC, im.id DESC LIMIT 1
  ) m ON TRUE
  WHERE u.contract_period_id = p_contract_period_id
    AND p_expected_contract_record_digest IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM ops.commercial_contract_periods c
       WHERE c.id = p_contract_period_id
         AND c.record_digest = p_expected_contract_record_digest
         AND c.state_effective_at <= p_billing_cutoff_at
    )
    AND u.period_start < p_period_end AND u.period_end > p_period_start
    AND u.record_digest IS NOT NULL
    AND u.created_at <= p_billing_cutoff_at;
$$;
REVOKE ALL ON FUNCTION ops.read_invoice_membership_v1(uuid, char(64), date, date, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_invoice_membership_v1(uuid, char(64), date, date, timestamptz) TO gurine_workflow_worker, gurine_control_api, gurine_auditor;

CREATE OR REPLACE FUNCTION ops.read_cac_metric_inputs_v1(
  p_period_start date, p_period_end date, p_reporting_currency char(3),
  p_expected_accounting_policy_digest char(64))
RETURNS TABLE(
  organization_id uuid, acquisition_amount numeric(24,6), attribution_state text,
  acquisition_source_receipt_digest char(64), input_set_digest char(64),
  metric_status text, reason_code text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp AS $$
  WITH lines AS (
    SELECT ca.organization_id, ca.allocated_amount, ca.acquisition_attribution_state::text AS attribution_state,
           ca.acquisition_source_receipt_digest, ca.record_digest
    FROM ops.cost_allocations ca
    WHERE ca.row_kind = 'LINE' AND ca.cost_category = 'SALES_CUSTOMER_ACQUISITION'
      AND ca.period_start < p_period_end AND ca.period_end > p_period_start
      AND ca.currency = p_reporting_currency
      AND ca.accounting_policy_digest = p_expected_accounting_policy_digest
  ), aggregate AS (
    SELECT COALESCE(bool_and(attribution_state = 'ATTRIBUTED' AND organization_id IS NOT NULL
                              AND acquisition_source_receipt_digest IS NOT NULL), false) AS complete,
           COALESCE(sum(allocated_amount), 0)::numeric(24,6) AS total_amount,
           encode(extensions.digest(convert_to(COALESCE(string_agg(record_digest, ',' ORDER BY record_digest), ''), 'UTF8'),'sha256'),'hex')::char(64) AS input_digest
    FROM lines
  )
  SELECT l.organization_id, l.allocated_amount::numeric(24,6), l.attribution_state,
         l.acquisition_source_receipt_digest, a.input_digest,
         CASE WHEN a.complete THEN 'KNOWN' ELSE 'UNKNOWN' END,
         CASE WHEN a.complete THEN 'NONE' ELSE 'ATTRIBUTION_UNKNOWN' END
  FROM lines l CROSS JOIN aggregate a;
$$;
REVOKE ALL ON FUNCTION ops.read_cac_metric_inputs_v1(date, date, char(3), char(64)) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_cac_metric_inputs_v1(date, date, char(3), char(64)) TO gurine_workflow_worker, gurine_control_api, gurine_auditor;
""")

    print("COMMIT;")


if __name__ == "__main__":
    main()
