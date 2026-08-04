BEGIN;

-- B1 repairs the 0041 public-slug guard only by moving forward. Migrations are
-- append-only and globally ordered, so a defect introduced by 0041 cannot be
-- repaired in an earlier slice or by rewriting historical migration bytes.
CREATE TABLE editorial.public_slug_rename_receipts_v1 (
  receipt_id uuid PRIMARY KEY,
  case_id uuid NOT NULL
    REFERENCES editorial.cases(id) ON DELETE RESTRICT,
  prior_case_version bigint NOT NULL,
  case_version bigint NOT NULL,
  old_slug text,
  new_slug text NOT NULL,
  actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  reason text NOT NULL,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL,
  CONSTRAINT public_slug_rename_receipts_v1_case_version_uq
    UNIQUE(case_id,prior_case_version,case_version),
  CONSTRAINT public_slug_rename_receipts_v1_shape_ck CHECK (
    prior_case_version>0
    AND case_version=prior_case_version+1
    AND old_slug IS DISTINCT FROM new_slug
    AND editorial.r6d_public_slug_valid_v1(new_slug)
    AND btrim(reason)<>''
    AND ops.r6d_lower_sha256(receipt_digest)
    AND receipt_payload=jsonb_build_object(
      'schemaVersion','public-slug-rename-receipt.v1',
      'receiptId',receipt_id,
      'caseId',case_id,
      'priorCaseVersion',prior_case_version,
      'caseVersion',case_version,
      'oldSlug',old_slug,
      'newSlug',new_slug,
      'actorId',actor_id,
      'reason',reason,
      'createdAt',created_at
    )
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(
      extensions.digest(receipt_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE editorial.public_slug_rename_receipts_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON editorial.public_slug_rename_receipts_v1 FROM PUBLIC;
REVOKE ALL ON editorial.public_slug_rename_receipts_v1
  FROM gurine_control_api,gurine_submission_api,gurine_workflow_worker,
    gurine_analysis_worker,gurine_public_projector,
    gurine_notification_worker,gurine_auditor;
GRANT SELECT ON editorial.public_slug_rename_receipts_v1
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER public_slug_rename_receipts_v1_immutable_guard
  BEFORE UPDATE OR DELETE ON editorial.public_slug_rename_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
COMMENT ON TABLE editorial.public_slug_rename_receipts_v1 IS
  'Append-only authority receipts for version-fenced public slug renames.';

CREATE OR REPLACE FUNCTION editorial.rename_public_slug_v1(
  p_case_id uuid,
  p_expected_version bigint,
  p_new_slug text,
  p_actor_id uuid,
  p_reason text
) RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp
AS $$
DECLARE
  v_case editorial.cases%ROWTYPE;
  v_receipt_id uuid:=gen_random_uuid();
  v_case_version bigint;
  v_reason text;
  v_created_at timestamptz:=transaction_timestamp();
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
BEGIN
  v_reason:=btrim(p_reason);
  IF p_case_id IS NULL OR p_expected_version IS NULL
     OR p_expected_version<1 OR p_new_slug IS NULL OR p_actor_id IS NULL
     OR v_reason IS NULL OR v_reason='' THEN
    RAISE EXCEPTION 'public_slug_rename_request_invalid'
      USING ERRCODE='22023';
  END IF;
  IF editorial.r6d_public_slug_valid_v1(p_new_slug) IS NOT TRUE THEN
    RAISE EXCEPTION 'r6d_public_slug_invalid' USING ERRCODE='23514';
  END IF;

  SELECT * INTO STRICT v_case
  FROM editorial.cases
  WHERE id=p_case_id AND version=p_expected_version
  FOR UPDATE;
  IF v_case.public_slug IS NOT DISTINCT FROM p_new_slug THEN
    RAISE EXCEPTION 'public_slug_rename_request_invalid'
      USING ERRCODE='22023';
  END IF;
  v_case_version:=v_case.version+1;
  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','public-slug-rename-receipt.v1',
    'receiptId',v_receipt_id,
    'caseId',v_case.id,
    'priorCaseVersion',v_case.version,
    'caseVersion',v_case_version,
    'oldSlug',v_case.public_slug,
    'newSlug',p_new_slug,
    'actorId',p_actor_id,
    'reason',v_reason,
    'createdAt',v_created_at
  );
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_receipt_digest:=encode(
    extensions.digest(v_receipt_canonical,'sha256'),'hex'
  );

  INSERT INTO editorial.public_slug_rename_receipts_v1(
    receipt_id,case_id,prior_case_version,case_version,old_slug,new_slug,
    actor_id,reason,receipt_payload,receipt_canonical,receipt_digest,created_at
  ) VALUES(
    v_receipt_id,v_case.id,v_case.version,v_case_version,
    v_case.public_slug,p_new_slug,p_actor_id,v_reason,v_receipt_payload,
    v_receipt_canonical,v_receipt_digest,v_created_at
  );
  UPDATE editorial.cases
  SET public_slug=p_new_slug,version=version+1,updated_at=v_created_at
  WHERE id=v_case.id AND version=v_case.version;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'public_slug_rename_version_conflict'
      USING ERRCODE='40001';
  END IF;
  RETURN v_receipt_id;
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'public_slug_rename_version_conflict'
    USING ERRCODE='40001';
END
$$;
ALTER FUNCTION editorial.rename_public_slug_v1(uuid,bigint,text,uuid,text)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  editorial.rename_public_slug_v1(uuid,bigint,text,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  editorial.rename_public_slug_v1(uuid,bigint,text,uuid,text)
  TO gurine_control_api;
COMMENT ON FUNCTION
  editorial.rename_public_slug_v1(uuid,bigint,text,uuid,text) IS
  'Renames only public_slug with an immutable receipt and version fence; a slug rename and publication transition must use separate statements.';

CREATE OR REPLACE FUNCTION editorial.guard_r6d_case_publication_v2()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,editorial,pg_temp
AS $$
DECLARE v_receipt_id uuid;
BEGIN
  IF (NEW.publication_state IS DISTINCT FROM OLD.publication_state
    OR NEW.current_publication_revision IS DISTINCT FROM
      OLD.current_publication_revision
    OR NEW.public_slug IS DISTINCT FROM OLD.public_slug
  ) AND NEW.public_slug IS NOT NULL
    AND editorial.r6d_public_slug_valid_v1(NEW.public_slug) IS NOT TRUE THEN
    RAISE EXCEPTION 'r6d_public_slug_invalid' USING ERRCODE='23514';
  END IF;
  IF NEW.publication_state IS NOT DISTINCT FROM OLD.publication_state
     AND NEW.current_publication_revision IS NOT DISTINCT FROM
       OLD.current_publication_revision
     AND NEW.public_slug IS NOT DISTINCT FROM OLD.public_slug THEN
    RETURN NEW;
  END IF;
  IF NEW.publication_state IS NOT DISTINCT FROM OLD.publication_state
     AND NEW.current_publication_revision IS NOT DISTINCT FROM
       OLD.current_publication_revision
     AND NEW.public_slug IS DISTINCT FROM OLD.public_slug THEN
    SELECT receipt.receipt_id INTO STRICT v_receipt_id
    FROM editorial.public_slug_rename_receipts_v1 AS receipt
    WHERE receipt.case_id=NEW.id
      AND receipt.prior_case_version=OLD.version
      AND receipt.case_version=NEW.version
      AND receipt.old_slug IS NOT DISTINCT FROM OLD.public_slug
      AND receipt.new_slug=NEW.public_slug
      AND NEW.version=OLD.version+1
      AND ROW(
        NEW.id,NEW.title,NEW.investigation_state,NEW.resolution_code,
        NEW.summary,NEW.priority,NEW.lead_investigator_id,NEW.editor_id,
        NEW.legal_review_required,NEW.current_review_snapshot_id,
        NEW.created_at
      ) IS NOT DISTINCT FROM ROW(
        OLD.id,OLD.title,OLD.investigation_state,OLD.resolution_code,
        OLD.summary,OLD.priority,OLD.lead_investigator_id,OLD.editor_id,
        OLD.legal_review_required,OLD.current_review_snapshot_id,
        OLD.created_at
      )
    FOR SHARE OF receipt;
    RETURN NEW;
  END IF;
  SELECT receipt.receipt_id INTO STRICT v_receipt_id
  FROM editorial.publication_revision_owner_receipts_v2 AS receipt
  WHERE receipt.case_id=NEW.id
    AND receipt.prior_case_version=OLD.version
    AND receipt.case_version=NEW.version
    AND receipt.publication_state=NEW.publication_state
    AND receipt.revision=NEW.current_publication_revision
    AND receipt.review_snapshot_id=NEW.current_review_snapshot_id
    AND NEW.version=OLD.version+1
    AND ROW(NEW.id,NEW.public_slug,NEW.title,NEW.investigation_state,
      NEW.resolution_code,NEW.summary,NEW.priority,NEW.lead_investigator_id,
      NEW.editor_id,NEW.legal_review_required,NEW.current_review_snapshot_id,
      NEW.created_at) IS NOT DISTINCT FROM ROW(
      OLD.id,OLD.public_slug,OLD.title,OLD.investigation_state,
      OLD.resolution_code,OLD.summary,OLD.priority,OLD.lead_investigator_id,
      OLD.editor_id,OLD.legal_review_required,OLD.current_review_snapshot_id,
      OLD.created_at)
  FOR SHARE OF receipt;
  RETURN NEW;
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'r6d_case_publication_owner_required'
    USING ERRCODE='42501';
END
$$;
ALTER FUNCTION editorial.guard_r6d_case_publication_v2()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.guard_r6d_case_publication_v2()
  FROM PUBLIC;
COMMENT ON FUNCTION editorial.guard_r6d_case_publication_v2() IS
  'Accepts only exact receipt-backed slug-only renames or existing receipt-backed publication transitions; combining a slug rename and publication transition in one UPDATE is forbidden.';

COMMIT;
