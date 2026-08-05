BEGIN;

-- MODEL_INPUT is the audit boundary for bytes selected for provider egress.
-- Before dispatch it carries a turn-bound sentinel; no completed receipt may
-- be inserted as a second MODEL_INPUT row.
CREATE OR REPLACE FUNCTION ops.enforce_agent_source_use_provider_receipt_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_placeholder_sha char(64);
  v_payload jsonb;
  v_unsigned jsonb;
  v_source_use_sha char(64);
BEGIN
  IF NEW.use_kind = 'MODEL_INPUT' THEN
    SELECT turn.input_snapshot_sha256 INTO v_placeholder_sha
      FROM ops.agent_provider_turns turn
     WHERE turn.agent_run_id=NEW.agent_run_id
       AND turn.provider_turn_id=NEW.provider_turn_id
       AND turn.status='DISPATCHED';
    IF NOT FOUND OR NEW.provider_turn_id IS NULL
       OR NEW.provider_receipt_id IS DISTINCT FROM NEW.provider_turn_id
       OR NEW.provider_receipt_sha256 IS DISTINCT FROM v_placeholder_sha
    THEN
      RAISE EXCEPTION 'SOURCE_USE_PRE_DISPATCH_RECEIPT_MISMATCH'
        USING ERRCODE='23503';
    END IF;
    v_payload := convert_from(NEW.source_use_canonical,'UTF8')::jsonb;
    v_unsigned := v_payload - 'sourceUseSha256';
    v_source_use_sha := encode(extensions.digest(
      ops.canonical_jsonb_v1(v_unsigned),'sha256'),'hex');
    IF jsonb_typeof(v_payload) <> 'object'
       OR v_payload->>'sourceUseId' IS DISTINCT FROM NEW.source_use_id::text
       OR v_payload->>'agentRunId' IS DISTINCT FROM NEW.agent_run_id::text
       OR v_payload->>'providerTurnId' IS DISTINCT FROM NEW.provider_turn_id::text
       OR v_payload->>'providerReceiptId' IS DISTINCT FROM NEW.provider_turn_id::text
       OR v_payload->>'providerReceiptSha256' IS DISTINCT FROM btrim(v_placeholder_sha::text)
       OR (v_payload->>'occurredAt')::timestamptz IS DISTINCT FROM NEW.occurred_at
       OR v_payload->>'sourceUseSha256' IS DISTINCT FROM btrim(v_source_use_sha::text)
       OR NEW.source_use_sha256 IS DISTINCT FROM v_source_use_sha
       OR NEW.source_use_canonical IS DISTINCT FROM ops.canonical_jsonb_v1(v_payload) THEN
      RAISE EXCEPTION 'SOURCE_USE_PRE_DISPATCH_CANONICAL_MISMATCH'
        USING ERRCODE='23514';
    END IF;
  ELSIF NEW.use_kind = 'MODEL_OUTPUT_DERIVATION' THEN
    IF NOT EXISTS (
      SELECT 1 FROM ops.agent_provider_turns turn
       WHERE turn.agent_run_id=NEW.agent_run_id
         AND turn.provider_turn_id=NEW.provider_turn_id
         AND turn.status='COMPLETED'
         AND turn.provider_receipt_id=NEW.provider_receipt_id
         AND turn.provider_receipt_sha256=NEW.provider_receipt_sha256
    ) THEN
      RAISE EXCEPTION 'SOURCE_USE_PROVIDER_RECEIPT_MISMATCH'
        USING ERRCODE='23503';
    END IF;
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION ops.enforce_agent_source_use_provider_receipt_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.enforce_agent_source_use_provider_receipt_v1()
  FROM PUBLIC;

-- Source uses remain immutable except for the four fields that promote one
-- MODEL_INPUT sentinel to the exact receipt already committed on its turn.
CREATE OR REPLACE FUNCTION ops.enforce_agent_model_input_receipt_promotion_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_placeholder_sha char(64);
  v_old_payload jsonb;
  v_old_unsigned jsonb;
  v_old_sha char(64);
  v_new_unsigned jsonb;
  v_new_sha char(64);
  v_new_canonical bytea;
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'immutable_or_terminal_record' USING ERRCODE='55000';
  END IF;
  IF current_user <> 'gurine_migrator' THEN
    RAISE EXCEPTION 'SOURCE_USE_PROMOTION_OWNER_REQUIRED' USING ERRCODE='42501';
  END IF;
  SELECT turn.input_snapshot_sha256 INTO v_placeholder_sha
    FROM ops.agent_provider_turns turn
   WHERE turn.agent_run_id=OLD.agent_run_id
     AND turn.provider_turn_id=OLD.provider_turn_id;
  IF NOT FOUND OR OLD.use_kind <> 'MODEL_INPUT'
     OR OLD.provider_receipt_id IS DISTINCT FROM OLD.provider_turn_id
     OR OLD.provider_receipt_sha256 IS DISTINCT FROM v_placeholder_sha
     OR NEW.provider_receipt_id IS NULL OR NEW.provider_receipt_sha256 IS NULL
     OR (NEW.provider_receipt_id=NEW.provider_turn_id
         AND NEW.provider_receipt_sha256=v_placeholder_sha)
     OR to_jsonb(NEW) - ARRAY[
       'provider_receipt_id','provider_receipt_sha256',
       'source_use_canonical','source_use_sha256'
     ] IS DISTINCT FROM to_jsonb(OLD) - ARRAY[
       'provider_receipt_id','provider_receipt_sha256',
       'source_use_canonical','source_use_sha256'
     ]
     OR NOT EXISTS (
       SELECT 1 FROM ops.agent_provider_turns turn
        WHERE turn.agent_run_id=NEW.agent_run_id
          AND turn.provider_turn_id=NEW.provider_turn_id
          AND turn.status IN (
            'COMPLETED','PROVIDER_FAILED','RATE_LIMITED',
            'TIMED_OUT','CANCELLED','OUTCOME_UNKNOWN'
          )
          AND turn.provider_receipt_id=NEW.provider_receipt_id
          AND turn.provider_receipt_sha256=NEW.provider_receipt_sha256
     ) THEN
    RAISE EXCEPTION 'SOURCE_USE_RECEIPT_PROMOTION_INVALID' USING ERRCODE='55000';
  END IF;

  v_old_payload := convert_from(OLD.source_use_canonical,'UTF8')::jsonb;
  v_old_unsigned := v_old_payload - 'sourceUseSha256';
  v_old_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_old_unsigned),'sha256'),'hex');
  IF jsonb_typeof(v_old_payload) <> 'object'
     OR v_old_payload->>'sourceUseId' IS DISTINCT FROM OLD.source_use_id::text
     OR v_old_payload->>'agentRunId' IS DISTINCT FROM OLD.agent_run_id::text
     OR v_old_payload->>'providerTurnId' IS DISTINCT FROM OLD.provider_turn_id::text
     OR v_old_payload->>'providerReceiptId' IS DISTINCT FROM OLD.provider_turn_id::text
     OR v_old_payload->>'providerReceiptSha256' IS DISTINCT FROM btrim(v_placeholder_sha::text)
     OR (v_old_payload->>'occurredAt')::timestamptz IS DISTINCT FROM OLD.occurred_at
     OR v_old_payload->>'sourceUseSha256' IS DISTINCT FROM btrim(v_old_sha::text)
     OR OLD.source_use_sha256 IS DISTINCT FROM v_old_sha
     OR OLD.source_use_canonical IS DISTINCT FROM ops.canonical_jsonb_v1(v_old_payload) THEN
    RAISE EXCEPTION 'SOURCE_USE_PRE_DISPATCH_CANONICAL_MISMATCH'
      USING ERRCODE='23514';
  END IF;

  v_new_unsigned := v_old_unsigned || jsonb_build_object(
    'providerReceiptId',NEW.provider_receipt_id,
    'providerReceiptSha256',btrim(NEW.provider_receipt_sha256::text));
  v_new_sha := encode(extensions.digest(
    ops.canonical_jsonb_v1(v_new_unsigned),'sha256'),'hex');
  v_new_canonical := ops.canonical_jsonb_v1(v_new_unsigned ||
    jsonb_build_object('sourceUseSha256',v_new_sha));
  IF NEW.source_use_sha256 IS DISTINCT FROM v_new_sha
     OR NEW.source_use_canonical IS DISTINCT FROM v_new_canonical THEN
    RAISE EXCEPTION 'SOURCE_USE_PROMOTED_CANONICAL_MISMATCH'
      USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION ops.enforce_agent_model_input_receipt_promotion_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.enforce_agent_model_input_receipt_promotion_v1()
  FROM PUBLIC;

DROP TRIGGER IF EXISTS ops_agent_source_uses_immutable_mutation_guard
  ON ops.agent_source_uses;
CREATE TRIGGER ops_agent_source_uses_immutable_mutation_guard
  BEFORE UPDATE OR DELETE ON ops.agent_source_uses
  FOR EACH ROW EXECUTE FUNCTION ops.enforce_agent_model_input_receipt_promotion_v1();

-- Completing a provider turn already crosses the existing migrator-owned
-- SECURITY DEFINER boundary. Promote its MODEL_INPUT rows in that same owner
-- statement, without granting the worker any new function or table privilege.
CREATE OR REPLACE FUNCTION ops.promote_agent_model_input_receipt_on_turn_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_source ops.agent_source_uses%ROWTYPE;
  v_placeholder_sha char(64);
  v_placeholder_count integer;
  v_actual_count integer;
  v_total_count integer;
  v_qualified_count integer;
  v_unsigned jsonb;
  v_new_sha char(64);
  v_updated integer;
BEGIN
  IF OLD.status <> 'DISPATCHED'
     OR NEW.status NOT IN (
       'COMPLETED','PROVIDER_FAILED','RATE_LIMITED',
       'TIMED_OUT','CANCELLED','OUTCOME_UNKNOWN'
     )
     OR NEW.provider_receipt_id IS NULL OR NEW.provider_receipt_sha256 IS NULL THEN
    RAISE EXCEPTION 'MODEL_INPUT_PROVIDER_TURN_TRANSITION_INVALID' USING ERRCODE='23514';
  END IF;
  v_placeholder_sha := NEW.input_snapshot_sha256;
  IF NEW.provider_receipt_id=NEW.provider_turn_id
     AND NEW.provider_receipt_sha256=v_placeholder_sha THEN
    RAISE EXCEPTION 'MODEL_INPUT_PROVIDER_RECEIPT_MISMATCH' USING ERRCODE='23503';
  END IF;

  PERFORM 1 FROM ops.agent_source_uses source_use
   WHERE source_use.agent_run_id=NEW.agent_run_id
     AND source_use.provider_turn_id=NEW.provider_turn_id
     AND source_use.use_kind='MODEL_INPUT'
   FOR UPDATE;
  IF EXISTS (
    SELECT 1 FROM ops.agent_source_uses source_use
     WHERE source_use.agent_run_id=NEW.agent_run_id
       AND source_use.provider_turn_id=NEW.provider_turn_id
       AND source_use.use_kind='MODEL_INPUT'
       AND NOT (
         (source_use.provider_receipt_id=NEW.provider_turn_id
          AND source_use.provider_receipt_sha256=v_placeholder_sha)
         OR
         (source_use.provider_receipt_id=NEW.provider_receipt_id
          AND source_use.provider_receipt_sha256=NEW.provider_receipt_sha256)
       )
  ) THEN
    RAISE EXCEPTION 'MODEL_INPUT_LINEAGE_RECEIPT_STATE_INVALID' USING ERRCODE='23514';
  END IF;
  IF EXISTS (
    SELECT source_use.parent_source_use_id
      FROM ops.agent_source_uses source_use
     WHERE source_use.agent_run_id=NEW.agent_run_id
       AND source_use.provider_turn_id=NEW.provider_turn_id
       AND source_use.use_kind='MODEL_INPUT'
     GROUP BY source_use.parent_source_use_id HAVING count(*) <> 1
  ) THEN
    RAISE EXCEPTION 'MODEL_INPUT_LINEAGE_DUPLICATE' USING ERRCODE='23514';
  END IF;
  SELECT
    count(*) FILTER (WHERE source_use.provider_receipt_id=NEW.provider_turn_id
      AND source_use.provider_receipt_sha256=v_placeholder_sha),
    count(*) FILTER (WHERE source_use.provider_receipt_id=NEW.provider_receipt_id
      AND source_use.provider_receipt_sha256=NEW.provider_receipt_sha256),
    count(*)
    INTO v_placeholder_count,v_actual_count,v_total_count
    FROM ops.agent_source_uses source_use
   WHERE source_use.agent_run_id=NEW.agent_run_id
     AND source_use.provider_turn_id=NEW.provider_turn_id
     AND source_use.use_kind='MODEL_INPUT';
  SELECT count(DISTINCT root.source_use_id) INTO v_qualified_count
    FROM ops.agent_source_uses root
    JOIN core.dataset_snapshot_members member
      ON member.dataset_snapshot_id=root.dataset_snapshot_id
     AND member.snapshot_kind='AGENT_CASE'
     AND member.object_type='EVIDENCE_SEGMENT'
     AND member.object_version=1
    JOIN raw.evidence_segments segment
      ON segment.id=member.evidence_segment_id
     AND segment.source_document_id=root.source_document_id
     AND segment.locator_value=root.locator_value
     AND segment.selected_content_sha256=root.selected_content_sha256
    JOIN core.dataset_snapshot_member_sources member_source
      ON member_source.dataset_snapshot_id=member.dataset_snapshot_id
     AND member_source.snapshot_member_id=member.id
     AND member_source.snapshot_member_digest=member.member_digest
     AND member_source.evidence_segment_id=segment.id
    JOIN raw.asset_rights_decisions rights
      ON rights.id=root.asset_rights_decision_id
     AND rights.asset_id=segment.source_asset_id
     AND rights.asset_revision=segment.source_asset_revision
     AND rights.asset_sha256=segment.source_content_sha256
     AND rights.decision_version=root.asset_rights_decision_version
     AND rights.decision_sha256=root.asset_rights_decision_sha256
   WHERE root.agent_run_id=NEW.agent_run_id
     AND root.use_kind='TOOL_QUERY'
     AND root.source_kind='DATASET_MEMBER';
  IF v_total_count=0 OR v_total_count <> v_qualified_count THEN
    RAISE EXCEPTION 'MODEL_INPUT_LINEAGE_MISSING' USING ERRCODE='23514';
  END IF;
  IF v_placeholder_count > 0 AND v_actual_count > 0 THEN
    RAISE EXCEPTION 'MODEL_INPUT_LINEAGE_PARTIAL_PROMOTION' USING ERRCODE='40001';
  END IF;
  IF v_placeholder_count=0 THEN
    IF v_actual_count=v_total_count THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'MODEL_INPUT_LINEAGE_RECEIPT_STATE_INVALID' USING ERRCODE='23514';
  END IF;
  IF v_placeholder_count <> v_total_count THEN
    RAISE EXCEPTION 'MODEL_INPUT_LINEAGE_RECEIPT_STATE_INVALID' USING ERRCODE='23514';
  END IF;
  IF EXISTS (
    SELECT 1 FROM ops.agent_source_uses parent
     WHERE parent.agent_run_id=NEW.agent_run_id
       AND parent.provider_turn_id=NEW.provider_turn_id
       AND parent.use_kind='MODEL_INPUT'
       AND parent.provider_receipt_id=NEW.provider_turn_id
       AND parent.provider_receipt_sha256=v_placeholder_sha
       AND (
         EXISTS (SELECT 1 FROM ops.agent_source_uses child
          WHERE child.agent_run_id=parent.agent_run_id
            AND child.parent_source_use_id=parent.source_use_id
            AND child.parent_source_use_sha256=parent.source_use_sha256)
         OR EXISTS (SELECT 1 FROM ops.agent_proposal_citations citation
          WHERE citation.agent_run_id=parent.agent_run_id
            AND citation.source_use_id=parent.source_use_id
            AND citation.source_use_sha256=parent.source_use_sha256)
         OR EXISTS (SELECT 1 FROM raw.research_artifact_promotions promotion
          WHERE promotion.agent_run_id=parent.agent_run_id
            AND promotion.root_source_use_id=parent.source_use_id
            AND promotion.root_source_use_sha256=parent.source_use_sha256)
       )
  ) THEN
    RAISE EXCEPTION 'MODEL_INPUT_LINEAGE_ALREADY_REFERENCED' USING ERRCODE='55000';
  END IF;

  FOR v_source IN
    SELECT * FROM ops.agent_source_uses source_use
     WHERE source_use.agent_run_id=NEW.agent_run_id
       AND source_use.provider_turn_id=NEW.provider_turn_id
       AND source_use.use_kind='MODEL_INPUT'
       AND source_use.provider_receipt_id=NEW.provider_turn_id
       AND source_use.provider_receipt_sha256=v_placeholder_sha
     ORDER BY source_use.source_use_id
  LOOP
    v_unsigned := (convert_from(v_source.source_use_canonical,'UTF8')::jsonb
      - 'sourceUseSha256') || jsonb_build_object(
        'providerReceiptId',NEW.provider_receipt_id,
        'providerReceiptSha256',btrim(NEW.provider_receipt_sha256::text));
    v_new_sha := encode(extensions.digest(
      ops.canonical_jsonb_v1(v_unsigned),'sha256'),'hex');
    UPDATE ops.agent_source_uses
       SET provider_receipt_id=NEW.provider_receipt_id,
           provider_receipt_sha256=NEW.provider_receipt_sha256,
           source_use_sha256=v_new_sha,
           source_use_canonical=ops.canonical_jsonb_v1(v_unsigned ||
             jsonb_build_object('sourceUseSha256',v_new_sha))
     WHERE source_use_id=v_source.source_use_id
       AND source_use_sha256=v_source.source_use_sha256;
    GET DIAGNOSTICS v_updated=ROW_COUNT;
    IF v_updated <> 1 THEN
      RAISE EXCEPTION 'MODEL_INPUT_LINEAGE_PROMOTION_CONFLICT' USING ERRCODE='40001';
    END IF;
  END LOOP;
  RETURN NEW;
END
$$;
ALTER FUNCTION ops.promote_agent_model_input_receipt_on_turn_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.promote_agent_model_input_receipt_on_turn_v1()
  FROM PUBLIC;

DROP TRIGGER IF EXISTS agent_provider_turn_model_input_receipt_promotion
  ON ops.agent_provider_turns;
CREATE TRIGGER agent_provider_turn_model_input_receipt_promotion
  AFTER UPDATE OF status,provider_receipt_id,provider_receipt_sha256
  ON ops.agent_provider_turns
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION ops.promote_agent_model_input_receipt_on_turn_v1();

COMMIT;
