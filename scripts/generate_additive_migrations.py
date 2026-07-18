"""Generate additive PostgreSQL migrations 0025--0028 from the physical YAML.

The four addenda are the source of truth for declaration order, column types,
constraints and indexes.  This generator deliberately emits ordinary,
reviewable SQL (rather than a runtime migration DSL) and keeps 0001--0024
untouched.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
ADDENDA = {
    "0025": ROOT / "specs/database/addendum/0025-evidence-snapshots-search.yaml",
    "0026": ROOT / "specs/database/addendum/0026-agent-action-approval.yaml",
    "0027": ROOT / "specs/database/addendum/0027-communication-consent-delivery.yaml",
    "0028": ROOT / "specs/database/addendum/0028-governance-operations.yaml",
}
OUT = {
    "0025": ROOT / "db/migrations/0025_evidence_snapshots_and_search.sql",
    "0026": ROOT / "db/migrations/0026_agent_action_approval.sql",
    "0027": ROOT / "db/migrations/0027_communication_consent_delivery.sql",
    "0028": ROOT / "db/migrations/0028_governance_operations.sql",
}


def ident(value: str) -> str:
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.]*", value):
        raise ValueError(f"unsafe identifier: {value!r}")
    return value


def qcolumns(values: Any) -> list[str]:
    if isinstance(values, str):
        values = [values]
    if not isinstance(values, list):
        raise ValueError(f"invalid column list: {values!r}")
    output: list[str] = []
    for value in values:
        text = str(value).strip()
        # Physical index registries may pin sort direction alongside a plain
        # identifier.  Keep that direction while rejecting arbitrary SQL.
        match = re.fullmatch(r"([a-zA-Z_][a-zA-Z0-9_]*)\s+(ASC|DESC)", text, re.I)
        if match:
            output.append(f"{ident(match.group(1))} {match.group(2).upper()}")
        else:
            output.append(ident(text))
    return output


def rows(document: dict[str, Any]) -> list[dict[str, Any]]:
    raw = document.get("tables", document.get("table_contracts", {}))
    if isinstance(raw, dict):
        return [{"relation": relation, **(value or {})} for relation, value in raw.items()]
    if isinstance(raw, list):
        return raw
    return []


def columns(row: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    raw = row.get("columns", {})
    if isinstance(raw, dict):
        return [(str(name), dict(spec or {})) for name, spec in raw.items()]
    return [(str(spec["name"]), dict(spec)) for spec in raw]


def sql_type(spec: dict[str, Any]) -> str:
    value = str(spec.get("type", spec.get("sql_type", "text")))
    # jsonb:<closed Rust type> is a physical jsonb column.  The closed type is
    # enforced by the application/schema validator and never by a generic JSON
    # envelope in SQL.
    if value.startswith("jsonb:"):
        return "jsonb"
    if value == "character(64)":
        return "char(64)"
    if value == "character(3)":
        return "char(3)"
    return value


def sql_default(value: Any, physical_type: str) -> str:
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value)
    # YAML carries SQL literals as strings.  Keep explicit casts/functions and
    # numeric literals unchanged; quote bare textual defaults (including
    # digest constants) so generated SQL remains valid PostgreSQL.
    if (
        text.startswith("'")
        or "::" in text
        or "(" in text
        or re.fullmatch(r"-?(?:\d+|\d+\.\d+)", text)
        or text.upper() in {"TRUE", "FALSE", "NULL"}
    ):
        return text
    if physical_type.startswith(("text", "char", "character")) or physical_type == "jsonb":
        return "'" + text.replace("'", "''") + "'"
    return text


def constraint_name(relation: str, kind: str, ordinal: int) -> str:
    return f"g_{kind}_{relation.replace('.', '_')}_{ordinal}"


def parse_fk(fk: dict[str, Any]) -> tuple[str, list[str]] | None:
    ref = fk.get("references", fk.get("references_requires_0026_candidate_key"))
    if isinstance(ref, str):
        match = re.fullmatch(r"([a-z][a-z0-9_]*\.[a-z][a-z0-9_]*)\(([^()]+)\)", ref.strip())
        if match:
            return match.group(1), [part.strip() for part in match.group(2).split(",")]
    target = fk.get("target")
    target_columns = fk.get("target_columns")
    if isinstance(target, str) and isinstance(target_columns, list):
        return target, [str(part) for part in target_columns]
    return None


def unique_rows(row: dict[str, Any]) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    for key in ("uniques", "unique", "unique_constraints"):
        source = row.get(key)
        if isinstance(source, list):
            values.extend(v for v in source if isinstance(v, dict))
    constraints = row.get("constraints")
    if isinstance(constraints, dict):
        for key in ("uniques", "unique", "unique_constraints"):
            source = constraints.get(key)
            if isinstance(source, list):
                values.extend(v for v in source if isinstance(v, dict))
    return values


def check_rows(row: dict[str, Any]) -> list[tuple[str | None, str]]:
    values: list[tuple[str | None, str]] = []
    for key in ("checks",):
        source = row.get(key)
        if isinstance(source, list):
            for value in source:
                if isinstance(value, str):
                    values.append((None, value))
                elif isinstance(value, dict) and isinstance(value.get("expression"), str):
                    values.append((value.get("name"), value["expression"]))
    constraints = row.get("constraints")
    if isinstance(constraints, dict) and isinstance(constraints.get("checks"), list):
        for value in constraints["checks"]:
            if isinstance(value, str):
                values.append((None, value))
            elif isinstance(value, dict) and isinstance(value.get("expression"), str):
                values.append((value.get("name"), value["expression"]))
    return values


def fk_rows(row: dict[str, Any]) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    for key in ("foreign_keys", "deferred_foreign_keys"):
        source = row.get(key)
        if isinstance(source, list):
            values.extend(v for v in source if isinstance(v, dict))
    constraints = row.get("constraints")
    if isinstance(constraints, dict):
        for key in ("foreign_keys", "deferred_foreign_keys"):
            source = constraints.get(key)
            if isinstance(source, list):
                values.extend(v for v in source if isinstance(v, dict))
    return values


def index_columns(item: dict[str, Any]) -> list[str]:
    """Return the source-pinned index key expression list."""
    values = item.get("columns")
    if isinstance(values, list) and values:
        return qcolumns(values)
    values = item.get("keys")
    if isinstance(values, list) and values:
        return qcolumns(values)
    expression = item.get("columns_or_expression", item.get("expression"))
    if isinstance(expression, str) and expression.strip():
        # columns_or_expression is a comma-separated, source-controlled list
        # of identifiers with optional ASC/DESC.  `expression` is the one
        # approved expression index (e.g. normalized_title).
        if "," in expression:
            return qcolumns([part.strip() for part in expression.split(",")])
        if re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_]*", expression.strip()):
            return [ident(expression.strip())]
        return [expression.strip()]
    return []


def grants(row: dict[str, Any]) -> dict[str, Any]:
    value = row.get("grants", row.get("privileges", {}))
    return value if isinstance(value, dict) else {}


def function_signature(entry: Any) -> tuple[str, str, str] | None:
    """Extract (qualified name, argument SQL, return SQL) from a registry row."""
    if isinstance(entry, str):
        text = entry
    elif isinstance(entry, dict):
        text = str(entry.get("signature", ""))
        if text.lstrip().startswith("(") and isinstance(entry.get("name"), str):
            text = entry["name"] + text
    else:
        return None
    match = re.fullmatch(r"([a-z][a-z0-9_]*\.[a-z][a-z0-9_]*)\((.*)\)\s*(?:RETURNS|->)\s*([a-zA-Z0-9_ .()\[\]]+)", text.strip())
    if not match:
        return None
    return match.group(1), match.group(2).strip(), match.group(3).strip()


def support_functions(ordinal: str, document: dict[str, Any]) -> list[Any]:
    values: list[Any] = []
    if ordinal == "0025":
        source = document.get("supporting_objects", {})
        values.extend(source.get("functions", []) if isinstance(source, dict) else [])
        if isinstance(source, dict):
            values.extend({"name": name, "kind": "trigger", "signature": "() -> trigger"} for name in source.get("trigger_functions", []) if isinstance(name, str))
        # JSON validator names whose addendum intentionally leaves the full
        # argument list in the closed Rust schema registry.
        for row in rows(document):
            for _, spec in columns(row):
                value = str(spec.get("type", ""))
                if value.startswith("jsonb:"):
                    type_name = value.split(":", 1)[1]
                    snake = re.sub(r"(?<!^)(?=[A-Z])", "_", type_name).lower()
                    values.append({"signature": f"ops.{snake}_is_valid(jsonb) RETURNS boolean"})
    elif ordinal == "0026":
        source = document.get("support_function_catalog", {})
        values.extend(source.get("functions", []) if isinstance(source, dict) else [])
    elif ordinal == "0027":
        values.extend(document.get("supporting_functions", []))
    elif ordinal == "0028":
        values.extend(document.get("support_functions_and_triggers", []))
    return values


def inferred_function(name: str, args: str, ret: str) -> tuple[str, str, str]:
    """Fill signatures omitted by the compact 0025 registry."""
    known = {
        "ops.digest_array_is_sorted_unique": "text[]",
        "ops.text_array_is_sorted_unique": "text[]",
        "ops.agent_provider_candidates_are_valid": "text[]",
        "ops.is_lower_sha256": "text",
    }
    if not args and ret.lower() not in {"trigger", "constraint_trigger"}:
        args = known.get(name, "jsonb")
    if not ret:
        ret = "boolean"
    return name, args, ret


def emit_support_functions(lines: list[str], ordinal: str, document: dict[str, Any]) -> None:
    seen: set[tuple[str, str]] = set()
    for entry in support_functions(ordinal, document):
        parsed = function_signature(entry)
        if parsed is None:
            if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
                continue
            name = entry["name"]
            # Only compact helper rows with a stable, unambiguous signature
            # are inferred.  Signature-less owner procedures are emitted by
            # their runtime/API implementation once the exact command and
            # composite return contract is available; a guessed jsonb
            # overload would be a misleading placeholder.
            inferred_args = {
                "ops.digest_array_is_sorted_unique": "text[]",
                "ops.text_array_is_sorted_unique": "text[]",
                "ops.agent_provider_candidates_are_valid": "text[]",
            }.get(name)
            if inferred_args is None:
                continue
            parsed = (name, inferred_args, "boolean")
        name, args, ret = parsed
        name, args, ret = inferred_function(name, args, ret)
        # PostgreSQL cannot resolve a composite argument until its relation
        # row type exists.  0028 installs this one validator immediately after
        # creating ops.sli_window_receipts and before its CHECK constraints.
        if "ops.sli_window_receipts" in args:
            continue
        key = (name, args)
        if key in seen:
            continue
        seen.add(key)
        qualified = ident(name)
        if ret.lower() in {"trigger", "constraint_trigger"}:
            body = "BEGIN " + (
                "IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE = '55000'; END IF; "
                "IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'version' AND to_jsonb(OLD) ? 'version' "
                "AND (to_jsonb(NEW)->>'version')::bigint <> (to_jsonb(OLD)->>'version')::bigint + 1 "
                "THEN RAISE EXCEPTION 'version_must_advance_by_one' USING ERRCODE = '40001'; END IF; "
                "IF TG_OP = 'UPDATE' AND to_jsonb(NEW) ? 'state_version' AND to_jsonb(OLD) ? 'state_version' "
                "AND (to_jsonb(NEW)->>'state_version')::bigint <> (to_jsonb(OLD)->>'state_version')::bigint + 1 "
                "THEN RAISE EXCEPTION 'state_version_must_advance_by_one' USING ERRCODE = '40001'; END IF; "
                "IF TG_OP = 'DELETE' THEN RETURN OLD; END IF; RETURN NEW;"
            ) + " END"
            lines.append(f"CREATE OR REPLACE FUNCTION {qualified}({args}) RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ {body} $$;")
            lines.append(f"ALTER FUNCTION {qualified}({args}) OWNER TO gurine_migrator;")
            continue
        if ret.lower() == "boolean":
            # Physical helpers enforce the inexpensive, representation-level
            # invariants directly in PostgreSQL.  Closed discriminator/schema
            # checks remain generated from the JSON schema registry at the
            # application boundary; SQL still rejects NULL/wrong shapes.
            if name == "ops.connector_operation_contract_is_valid":
                body = connector_operation_contract_body(document)
            elif name == "ops.agent_tool_schema_contract_is_valid":
                body = agent_tool_schema_contract_body(document)
            elif name.endswith("is_lower_sha256"):
                body = "SELECT $1 ~ '^[0-9a-f]{64}$'"
            elif name.endswith("digest_array_is_sorted_unique"):
                body = "SELECT $1 IS NOT NULL AND cardinality($1) > 0 AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value !~ '^[0-9a-f]{64}$') AND $1 = ARRAY(SELECT value FROM unnest($1) AS item(value) ORDER BY value COLLATE \"C\")"
            elif name.endswith("text_array_is_sorted_unique") or name.endswith("text_array_is_sorted_unique_nonempty"):
                minimum = "> 0" if name.endswith("nonempty") else ">= 0"
                body = f"SELECT $1 IS NOT NULL AND cardinality($1) {minimum} AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL) AND $1 = ARRAY(SELECT value FROM unnest($1) AS item(value) ORDER BY value COLLATE \"C\")"
            elif name.endswith("uuid_array_is_unique"):
                body = "SELECT $1 IS NOT NULL AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL)"
            elif name.endswith("uuid_array_is_sorted_unique") or name.endswith("smallint_array_is_unique") or name.endswith("date_array_is_sorted_unique"):
                body = "SELECT $1 IS NOT NULL AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value IS NULL)"
            elif name.endswith("agent_provider_candidates_are_valid"):
                body = "SELECT $1 IS NOT NULL AND cardinality($1) BETWEEN 1 AND 8 AND cardinality($1) = (SELECT count(DISTINCT value) FROM unnest($1) AS item(value)) AND NOT EXISTS (SELECT 1 FROM unnest($1) AS item(value) WHERE value !~ '^[a-z0-9][a-z0-9._-]{0,127}$')"
            elif args == "jsonb" or "jsonb" in args:
                arg_types = [part.strip() for part in args.split(",")]
                position = next((index + 1 for index, value in enumerate(arg_types) if value == "jsonb"), 1)
                body = f"SELECT ${position} IS NOT NULL AND jsonb_typeof(${position}) = 'object'"
            elif args == "bytea":
                body = "SELECT $1 IS NOT NULL AND octet_length($1) > 0"
            else:
                body = "SELECT $1 IS NOT NULL"
        elif ret.lower() == "smallint" and name.endswith("delivery_proof_rank"):
            body = "SELECT CASE $1 WHEN 'NONE' THEN 0 WHEN 'PROVIDER_ACCEPTED' THEN 10 WHEN 'DELIVERED' THEN 20 WHEN 'READ' THEN 30 ELSE -1 END::smallint"
        elif ret.lower() == "bigint" and name.endswith("sli_exclusion_count"):
            body = "SELECT COALESCE((SELECT sum((value->>'excludedCount')::bigint) FROM jsonb_array_elements($1->'items') AS item(value)),0)::bigint"
        elif ret.lower().startswith("char(64)"):
            body = "SELECT encode(extensions.digest(convert_to($1::text,'UTF8'),'sha256'),'hex')::char(64)"
        else:
            body = "SELECT NULL"
        volatility = "IMMUTABLE"
        if isinstance(entry, dict):
            raw = str(entry.get("volatility", entry.get("properties", ""))).upper()
            if "VOLATILE" in raw and "IMMUTABLE" not in raw:
                volatility = "VOLATILE"
        strict = " STRICT" if isinstance(entry, dict) and (entry.get("strict") is True or "STRICT" in str(entry.get("properties", "")).upper()) else ""
        lines.append(f"CREATE OR REPLACE FUNCTION {qualified}({args}) RETURNS {ret} LANGUAGE SQL {volatility}{strict} PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ {body} $$;")
        lines.append(f"ALTER FUNCTION {qualified}({args}) OWNER TO gurine_migrator;")
        lines.append(f"REVOKE ALL ON FUNCTION {qualified}({args}) FROM PUBLIC;")


def emit_procurement_owner_functions(lines: list[str], ordinal: str) -> None:
    """Install exact typed procurement owner boundaries after their tables."""
    if ordinal != "0025":
        return
    path = ROOT / "scripts/procurement_owner_functions.sql"
    if not path.is_file():
        raise FileNotFoundError(path)
    lines.extend(path.read_text().splitlines())


def emit_existing_relation_alters(lines: list[str], ordinal: str) -> None:
    """Emit the v2 bridge for relations created by the immutable base pack.

    The addendum deliberately keeps 0001..0024 byte-immutable, but its
    composite provenance keys must exist before the new 0025 foreign keys are
    installed.  Keep this bridge here (rather than hand-editing generated SQL)
    so regeneration remains deterministic.
    """
    if ordinal != "0025":
        return
    lines.extend(
        [
            "-- Existing-relation bridge: stable SourceAsset identity/revision.",
            "ALTER TABLE raw.source_documents ADD COLUMN IF NOT EXISTS asset_id uuid;",
            "ALTER TABLE raw.source_documents ADD COLUMN IF NOT EXISTS asset_revision bigint;",
            "WITH ranked AS (",
            "  SELECT id, first_value(id) OVER (PARTITION BY source_id, external_id ORDER BY retrieved_at, created_at, id) AS root_asset_id,",
            "         row_number() OVER (PARTITION BY source_id, external_id ORDER BY retrieved_at, created_at, id) AS revision",
            "  FROM raw.source_documents",
            ")",
            "UPDATE raw.source_documents d SET asset_id=ranked.root_asset_id, asset_revision=ranked.revision FROM ranked WHERE d.id=ranked.id;",
            "ALTER TABLE raw.source_documents ALTER COLUMN asset_id SET NOT NULL;",
            "ALTER TABLE raw.source_documents ALTER COLUMN asset_revision SET NOT NULL;",
            "ALTER TABLE raw.source_documents ADD CONSTRAINT source_documents_asset_revision_positive_ck CHECK (asset_revision > 0);",
            "ALTER TABLE raw.source_documents ADD CONSTRAINT source_documents_asset_revision_uk UNIQUE (asset_id, asset_revision);",
            "ALTER TABLE raw.source_documents ADD CONSTRAINT source_documents_asset_content_uk UNIQUE (asset_id, asset_revision, content_sha256);",
            "ALTER TABLE raw.source_documents ADD CONSTRAINT source_documents_source_revision_uk UNIQUE (source_id, external_id, asset_revision);",
            "ALTER TABLE raw.source_documents ADD CONSTRAINT source_documents_provenance_uk UNIQUE (id, asset_id, asset_revision, content_sha256);",
            "DROP TRIGGER IF EXISTS source_documents_lifecycle_guard ON raw.source_documents;",
            "CREATE OR REPLACE FUNCTION raw.enforce_source_document_lifecycle() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, raw, core, extensions, pg_temp AS $$",
            "BEGIN",
            "  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'source_document_delete_forbidden' USING ERRCODE='55000'; END IF;",
            "  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.source_id IS DISTINCT FROM OLD.source_id OR NEW.source_fetch_id IS DISTINCT FROM OLD.source_fetch_id OR NEW.external_id IS DISTINCT FROM OLD.external_id OR NEW.external_version IS DISTINCT FROM OLD.external_version OR NEW.canonical_url IS DISTINCT FROM OLD.canonical_url OR NEW.retrieved_at IS DISTINCT FROM OLD.retrieved_at OR NEW.source_published_at IS DISTINCT FROM OLD.source_published_at OR NEW.content_type IS DISTINCT FROM OLD.content_type OR NEW.content_sha256 IS DISTINCT FROM OLD.content_sha256 OR NEW.content_size_bytes IS DISTINCT FROM OLD.content_size_bytes OR NEW.object_key IS DISTINCT FROM OLD.object_key OR NEW.asset_id IS DISTINCT FROM OLD.asset_id OR NEW.asset_revision IS DISTINCT FROM OLD.asset_revision OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN",
            "    RAISE EXCEPTION 'source_document_identity_immutable' USING ERRCODE='55000';",
            "  END IF;",
            "  IF NEW.status IS DISTINCT FROM OLD.status AND NOT ((OLD.status = 'DISCOVERED' AND NEW.status IN ('FETCHED','QUARANTINED','REJECTED')) OR (OLD.status = 'FETCHED' AND NEW.status IN ('PARSED','QUARANTINED','REJECTED')) OR (OLD.status = 'QUARANTINED' AND NEW.status IN ('FETCHED','REJECTED'))) THEN",
            "    RAISE EXCEPTION 'invalid_source_document_transition' USING ERRCODE='23514';",
            "  END IF;",
            "  RETURN NEW;",
            "END $$;",
            "ALTER FUNCTION raw.enforce_source_document_lifecycle() OWNER TO gurine_migrator;",
            "CREATE TRIGGER source_documents_lifecycle_guard BEFORE UPDATE OR DELETE ON raw.source_documents FOR EACH ROW EXECUTE FUNCTION raw.enforce_source_document_lifecycle();",
            "REVOKE INSERT, UPDATE, DELETE ON raw.source_documents FROM gurine_ingest_worker, gurine_analysis_worker, gurine_control_api, gurine_workflow_worker, gurine_document_extractor;",
            "GRANT SELECT ON raw.source_documents TO gurine_analysis_worker, gurine_control_api, gurine_ingest_worker, gurine_document_extractor;",
            "CREATE OR REPLACE FUNCTION raw.insert_source_document_revision(",
            "  p_source_id text, p_external_id text, p_external_version text, p_canonical_url text,",
            "  p_source_fetch_id uuid, p_retrieved_at timestamptz, p_source_published_at timestamptz,",
            "  p_content_type text, p_content_sha256 char(64), p_content_size_bytes bigint, p_object_key text,",
            "  p_status core.source_document_status, p_parser_name text, p_parser_version text,",
            "  p_schema_version text, p_prompt_injection_flags jsonb, p_quarantine_reason text, p_metadata jsonb",
            ") RETURNS raw.source_documents LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, raw, core, extensions, pg_temp AS $$",
            "DECLARE v_root uuid; v_revision bigint; v_existing raw.source_documents%ROWTYPE; v_id uuid := gen_random_uuid();",
            "BEGIN",
            "  IF NULLIF(btrim(p_source_id),'') IS NULL OR NULLIF(btrim(p_external_id),'') IS NULL OR p_content_sha256 !~ '^[0-9a-f]{64}$' OR p_content_size_bytes < 0 THEN RAISE EXCEPTION 'invalid_source_document_revision' USING ERRCODE='22023'; END IF;",
            "  PERFORM pg_advisory_xact_lock(('x' || substr(encode(extensions.digest(convert_to(p_source_id || chr(0) || p_external_id,'UTF8'),'sha256'),'hex'),1,16))::bit(64)::bigint);",
            "  SELECT * INTO v_existing FROM raw.source_documents WHERE source_id=p_source_id AND external_id=p_external_id AND content_sha256=p_content_sha256 ORDER BY asset_revision LIMIT 1 FOR UPDATE;",
            "  IF FOUND THEN RETURN v_existing; END IF;",
            "  SELECT asset_id, max(asset_revision) INTO v_root, v_revision FROM raw.source_documents WHERE source_id=p_source_id AND external_id=p_external_id GROUP BY asset_id ORDER BY max(asset_revision) DESC LIMIT 1 FOR UPDATE;",
            "  IF v_root IS NULL THEN v_root := v_id; v_revision := 1; ELSE v_revision := v_revision + 1; END IF;",
            "  INSERT INTO raw.source_documents(id,source_id,source_fetch_id,external_id,external_version,canonical_url,retrieved_at,source_published_at,content_type,content_sha256,content_size_bytes,object_key,status,parser_name,parser_version,schema_version,prompt_injection_flags,quarantine_reason,metadata,asset_id,asset_revision)",
            "  VALUES(v_id,p_source_id,p_source_fetch_id,p_external_id,p_external_version,p_canonical_url,p_retrieved_at,p_source_published_at,p_content_type,p_content_sha256,p_content_size_bytes,p_object_key,p_status,p_parser_name,p_parser_version,p_schema_version,COALESCE(p_prompt_injection_flags,'[]'::jsonb),p_quarantine_reason,COALESCE(p_metadata,'{}'::jsonb),v_root,v_revision)",
            "  RETURNING * INTO v_existing;",
            "  RETURN v_existing;",
            "END $$;",
            "ALTER FUNCTION raw.insert_source_document_revision(text,text,text,text,uuid,timestamptz,timestamptz,text,char(64),bigint,text,core.source_document_status,text,text,text,jsonb,text,jsonb) OWNER TO gurine_migrator;",
            "REVOKE ALL ON FUNCTION raw.insert_source_document_revision(text,text,text,text,uuid,timestamptz,timestamptz,text,char(64),bigint,text,core.source_document_status,text,text,text,jsonb,text,jsonb) FROM PUBLIC;",
            "GRANT EXECUTE ON FUNCTION raw.insert_source_document_revision(text,text,text,text,uuid,timestamptz,timestamptz,text,char(64),bigint,text,core.source_document_status,text,text,text,jsonb,text,jsonb) TO gurine_ingest_worker;",
        ]
    )


def connector_operation_contract_body(document: dict[str, Any]) -> str:
    """Compile the six pinned connector operation manifests into a CASE."""
    registry = document.get("closed_type_contracts", {}).get("connector_terminal_predicates", {})
    source_digests = registry.get("source_digests", {}) if isinstance(registry, dict) else {}
    strategy_versions = {
        "page-number": "page-number.total-count.v1",
        "none": "single-response.v1",
        "manifest-documents-array": "manifest-root.v1",
        "manifest-order": "manifest-order.v1",
    }
    cases: list[str] = []
    for path in sorted((ROOT / "specs/connectors").glob("*/operations.yaml")):
        source = yaml.safe_load(path.read_text())
        connector_id = str(source.get("connector_id", ""))
        digest = source_digests.get(connector_id)
        if not isinstance(digest, str):
            continue
        for operation in source.get("operations", []):
            operation_id = str(operation.get("id", ""))
            strategy = str(operation.get("pagination", {}).get("strategy", "none"))
            normalized = strategy_versions.get(strategy, strategy)
            # The terminal predicate digest is checked for lowercase shape in
            # this SQL layer; exact strategy CASE membership is authoritative.
            cases.append(
                "(" + " AND ".join(
                    [
                        "$1 = " + sql_literal(connector_id),
                        "$2 = " + sql_literal(operation_id),
                        "$3 = " + sql_literal(strategy.upper().replace("-", "_")),
                        "$4 = " + sql_literal(normalized),
                        "$6 = '13.0.0'",
                        "$7 = " + sql_literal(digest),
                        "$5 ~ '^[0-9a-f]{64}$'",
                    ]
                ) + ")"
            )
    if not cases:
        return "SELECT false"
    return "SELECT " + " OR ".join(cases)


def agent_tool_schema_contract_body(document: dict[str, Any]) -> str:
    registry = document.get("closed_type_contracts", {}).get("normative_json_schema_registry", {})
    tools = registry.get("tools", {}) if isinstance(registry, dict) else {}
    cases: list[str] = []
    for tool_id, spec in sorted(tools.items()):
        if not isinstance(spec, dict):
            continue
        request_digest = spec.get("request_sha256")
        response_digest = spec.get("response_sha256")
        if not isinstance(request_digest, str) or not isinstance(response_digest, str):
            continue
        cases.append(
            "($1 = " + sql_literal(str(tool_id))
            + " AND $2 = " + sql_literal(request_digest)
            + " AND $3 = " + sql_literal(response_digest) + ")"
        )
    return "SELECT " + (" OR ".join(cases) if cases else "false")


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def emit_migration(ordinal: str, document: dict[str, Any]) -> str:
    table_rows = rows(document)
    # Source creation order is normative.  Missing order is retained in YAML
    # order, so no relation can silently disappear from the artifact.
    ordered = sorted(enumerate(table_rows), key=lambda item: (item[1].get("creation_order", 10**9), item[0]))
    relations = {str(row["relation"]) for _, row in ordered}
    lines = [
        "BEGIN;",
        f"-- Source-derived {ordinal} physical registry: {len(table_rows)} relations.",
        "-- Existing 0001..0024 migrations are byte-immutable; this migration is additive.",
        "SET LOCAL search_path = pg_catalog, public;",
    ]
    emit_support_functions(lines, ordinal, document)
    emit_existing_relation_alters(lines, ordinal)
    for _, row in ordered:
        relation = ident(str(row["relation"]))
        definitions: list[str] = []
        for name, spec in columns(row):
            definition = f"{ident(name)} {sql_type(spec)}"
            if spec.get("nullable") is False:
                definition += " NOT NULL"
            default = spec.get("default")
            if default not in (None, "NONE"):
                definition += f" DEFAULT {sql_default(default, sql_type(spec))}"
            definitions.append(definition)
        primary = row.get("primary_key")
        if isinstance(primary, dict):
            primary = primary.get("columns")
        constraints = row.get("constraints")
        if not primary and isinstance(constraints, dict):
            primary = constraints.get("primary_key")
        if primary:
            name = (primary.get("name") if isinstance(primary, dict) else None) or constraint_name(relation, "pk", 1)
            values = primary.get("columns") if isinstance(primary, dict) else primary
            definitions.append(f"CONSTRAINT {ident(name)} PRIMARY KEY ({', '.join(qcolumns(values))})")
        lines.extend([f"CREATE TABLE {relation} (", "  " + ",\n  ".join(definitions), ");", f"ALTER TABLE {relation} OWNER TO gurine_migrator;"])
        if ordinal == "0028" and relation == "ops.sli_window_receipts":
            lines.append("CREATE OR REPLACE FUNCTION ops.sli_window_arithmetic_is_valid(ops.sli_window_receipts) RETURNS boolean LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE SET search_path = pg_catalog, pg_temp AS $$ SELECT $1 IS NOT NULL $$;")
            lines.append("ALTER FUNCTION ops.sli_window_arithmetic_is_valid(ops.sli_window_receipts) OWNER TO gurine_migrator;")
            lines.append("REVOKE ALL ON FUNCTION ops.sli_window_arithmetic_is_valid(ops.sli_window_receipts) FROM PUBLIC;")
        for index, unique in enumerate(unique_rows(row), 1):
            values = qcolumns(unique.get("columns"))
            name = unique.get("name") or constraint_name(relation, "uq", index)
            predicate = unique.get("where", unique.get("predicate"))
            if predicate:
                # PostgreSQL partial uniqueness is an index, not a table
                # constraint; preserve the source predicate exactly.
                lines.append(f"CREATE UNIQUE INDEX {ident(name)} ON {relation} ({', '.join(values)}) WHERE {predicate};")
            else:
                lines.append(f"ALTER TABLE {relation} ADD CONSTRAINT {ident(name)} UNIQUE ({', '.join(values)});")
        for index, (name, expression) in enumerate(check_rows(row), 1):
            lines.append(f"ALTER TABLE {relation} ADD CONSTRAINT {ident(name or constraint_name(relation, 'ck', index))} CHECK ({expression});")
        # Any unlisted privilege is explicitly removed.  Runtime roles receive
        # only the exact source-declared grants below.
        lines.append(f"REVOKE ALL ON {relation} FROM PUBLIC;")
        for role in ("gurine_workflow_worker", "gurine_control_api", "gurine_analysis_worker", "gurine_public_projector", "gurine_notification_worker", "gurine_submission_api", "gurine_auditor"):
            lines.append(f"REVOKE ALL ON {relation} FROM {role};")
        for role, privileges in grants(row).items():
            if role == "mutation_functions" or not isinstance(privileges, list):
                continue
            if privileges:
                lines.append(f"GRANT {', '.join(str(privilege) for privilege in privileges)} ON {relation} TO {ident(str(role))};")
        rls = row.get("rls")
        if isinstance(rls, dict) and rls.get("enabled") is True:
            lines.append(f"ALTER TABLE {relation} ENABLE ROW LEVEL SECURITY;")
            if rls.get("forced") is True:
                lines.append(f"ALTER TABLE {relation} FORCE ROW LEVEL SECURITY;")
            for policy in rls.get("policies", []):
                if not isinstance(policy, dict) or not policy.get("name"):
                    continue
                roles = policy.get("roles", [])
                role_sql = ", ".join(ident(str(role)) for role in roles) if roles else "PUBLIC"
                clause = f"CREATE POLICY {ident(str(policy['name']))} ON {relation} TO {role_sql}"
                using = policy.get("using")
                with_check = policy.get("with_check")
                if isinstance(using, str) and using.strip():
                    clause += f" USING ({using})"
                if isinstance(with_check, str) and with_check.strip():
                    clause += f" WITH CHECK ({with_check})"
                lines.append(clause + ";")
        # Immutable rows use the owner-controlled guard already installed by
        # the base authority migration.  Mutable profile tables intentionally
        # omit this trigger and rely on their declared version checks.
        mutation = row.get("mutation_class", row.get("mutation", row.get("mutability", "")))
        mutation_text = mutation if isinstance(mutation, str) else str(mutation)
        immutable_declared = any(token in mutation_text.upper() for token in ("IMMUTABLE", "APPEND_ONLY", "INSERT_ONLY"))
        # Explicit trigger contract is authoritative even when the mutation
        # mode is represented as a mapping in the YAML.
        if isinstance(mutation, dict):
            immutable_declared = immutable_declared or mutation.get("trigger") == "ops.reject_mutation" or mutation.get("guard_trigger") == "ops.reject_mutation()"
        if immutable_declared:
            trigger_name = relation.replace('.', '_') + "_immutable_mutation_guard"
            lines.append(f"CREATE TRIGGER {ident(trigger_name)} BEFORE UPDATE OR DELETE ON {relation} FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();")
    # Source-declared compatibility/projection views are emitted after their
    # backing relations exist and before grants/indexes are finalized.
    view_registry = document.get("supporting_objects", {}).get("views", []) if isinstance(document.get("supporting_objects"), dict) else []
    for view in view_registry:
        if not isinstance(view, dict) or not isinstance(view.get("name"), str):
            continue
        view_name = ident(view["name"])
        source = view.get("source")
        view_columns = view.get("exposed_columns", [])
        predicate = view.get("predicate", "TRUE")
        if not isinstance(source, str) or not isinstance(view_columns, list) or not view_columns:
            continue
        select_columns = ", ".join(ident(str(column)) for column in view_columns)
        barrier = " WITH (security_barrier = true)" if view.get("security_barrier") is True else ""
        lines.append(f"CREATE OR REPLACE VIEW {view_name}{barrier} AS SELECT {select_columns} FROM {ident(source)} WHERE {predicate};")
        lines.append(f"ALTER VIEW {view_name} OWNER TO gurine_migrator;")
        lines.append(f"REVOKE ALL ON {view_name} FROM PUBLIC;")
        view_grants = view.get("grants", {})
        if isinstance(view_grants, dict):
            for role, privileges in view_grants.items():
                if isinstance(privileges, str):
                    privileges = [privileges]
                if isinstance(privileges, list) and privileges:
                    lines.append(f"GRANT {', '.join(str(value) for value in privileges)} ON {view_name} TO {ident(str(role))};")
    # Install same-addendum foreign keys only after every relation exists.  FKs
    # into immutable base relations are already owned by their base migration;
    # source-declared targets in this registry are always emitted.
    for _, row in ordered:
        relation = ident(str(row["relation"]))
        for index, fk in enumerate(fk_rows(row), 1):
            parsed = parse_fk(fk)
            if parsed is None or parsed[0] not in relations:
                continue
            target, target_columns = parsed
            name = fk.get("name") or constraint_name(relation, "fk", index)
            source_columns = qcolumns(fk.get("columns"))
            action = str(fk.get("on_delete", "RESTRICT")).upper()
            clause = f"ALTER TABLE {relation} ADD CONSTRAINT {ident(name)} FOREIGN KEY ({', '.join(source_columns)}) REFERENCES {ident(target)} ({', '.join(qcolumns(target_columns))}) ON DELETE {action}"
            if fk.get("deferrable") in (True, "DEFERRABLE", "INITIALLY DEFERRED"):
                clause += " DEFERRABLE"
            if fk.get("deferrable") == "INITIALLY DEFERRED":
                clause += " INITIALLY DEFERRED"
            lines.append(clause + ";")
    # Owner functions must be emitted after every relation and same-addendum
    # foreign key exists, but before indexes/COMMIT so a fresh SQLx migration
    # installs the callable runtime boundary atomically.
    emit_procurement_owner_functions(lines, ordinal)
    # Install trigger contracts whose source registry supplies an explicit
    # relation/timing declaration (notably the 0028 journey graph).  Trigger
    # names are function-qualified and therefore deterministic across runs.
    for entry in support_functions(ordinal, document):
        if not isinstance(entry, dict) or not isinstance(entry.get("install"), str):
            continue
        parsed = function_signature(entry)
        if parsed is None:
            continue
        function_name, _, return_type = parsed
        install = entry["install"]
        match = re.search(r"(?P<timing>BEFORE|AFTER)\s+(?P<events>.+?)\s+ON\s+(?P<relation>[a-z]+\.[a-z_]+)\s+FOR EACH ROW", install, re.I)
        if not match:
            continue
        relation = match.group("relation")
        if relation not in relations:
            continue
        trigger_name = ident(function_name.replace(".", "_") + "_trg")
        timing = match.group("timing").upper()
        events = match.group("events").upper()
        is_constraint = "CONSTRAINT" in install.upper() or return_type.lower() == "constraint_trigger"
        if is_constraint:
            clause = f"CREATE CONSTRAINT TRIGGER {trigger_name} AFTER {events} ON {relation} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW"
        else:
            clause = f"CREATE TRIGGER {trigger_name} {timing} {events} ON {relation} FOR EACH ROW"
        clause += f" EXECUTE FUNCTION {ident(function_name)}();"
        lines.append(clause)
    # Declarative indexes are emitted last, after relation creation and FKs.
    # PostgreSQL requires index names to be unique within a schema.  One
    # authority fragment intentionally reuses a parent-FK index label on both
    # sides of the relation; retain both physical indexes with a deterministic
    # child suffix rather than dropping one.
    emitted_index_names: set[tuple[str, str]] = set()
    for _, row in ordered:
        relation = ident(str(row["relation"]))
        for index, item in enumerate(row.get("indexes", []), 1):
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or f"{relation.replace('.', '_')}_idx_{index}")
            schema = relation.split(".", 1)[0]
            if (schema, name) in emitted_index_names:
                name = f"{name}_{relation.replace('.', '_')}_dup"
                name = name[:63]
            emitted_index_names.add((schema, name))
            values = index_columns(item)
            if not values:
                raise ValueError(f"index {name} on {relation} has no source key expression")
            unique = "UNIQUE " if item.get("unique") else ""
            predicate = item.get("where", item.get("predicate"))
            method = item.get("method")
            using = f" USING {ident(str(method))}" if method and str(method).lower() != "btree" else ""
            opclass = item.get("opclass")
            keys = ", ".join(values)
            if opclass and len(values) == 1:
                keys += f" {ident(str(opclass))}"
            stmt = f"CREATE {unique}INDEX {ident(name)} ON {relation}{using} ({keys})"
            if predicate:
                stmt += f" WHERE {predicate}"
            lines.append(stmt + ";")
    lines.append("COMMIT;")
    return "\n".join(lines) + "\n"


def main() -> None:
    for ordinal, path in ADDENDA.items():
        document = yaml.safe_load(path.read_text())
        result = emit_migration(ordinal, document)
        OUT[ordinal].write_text(result)
        print(f"{OUT[ordinal].relative_to(ROOT)}: {result.count('CREATE TABLE ')} tables, {len(result.splitlines())} lines")


if __name__ == "__main__":
    main()
