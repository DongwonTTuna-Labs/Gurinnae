BEGIN;

-- R6d/Q5 privacy-object hold authorities.
--
-- Existing correction and subscription heads deliberately remain
-- STAGED_LEGACY with a NULL snapshot tuple.  This migration never invents a
-- historical snapshot.  The first post-0040 authoritative INSERT/UPDATE
-- produces version 1 from the then-current row; later writes append exactly
-- one immutable successor.  Snapshot payloads contain only identifiers,
-- bounded state, and digests of plaintext-bearing fields.

ALTER TABLE editorial.corrections
  ADD COLUMN r6d_privacy_snapshot_state text NOT NULL
    DEFAULT 'STAGED_LEGACY',
  ADD COLUMN r6d_privacy_snapshot_id uuid,
  ADD COLUMN r6d_privacy_snapshot_version bigint,
  ADD COLUMN r6d_privacy_snapshot_digest char(64),
  ADD CONSTRAINT corrections_r6d_privacy_snapshot_shape_ck CHECK (
    (r6d_privacy_snapshot_state='STAGED_LEGACY'
      AND num_nonnulls(
        r6d_privacy_snapshot_id,r6d_privacy_snapshot_version,
        r6d_privacy_snapshot_digest
      )=0)
    OR
    (r6d_privacy_snapshot_state='CURRENT'
      AND num_nonnulls(
        r6d_privacy_snapshot_id,r6d_privacy_snapshot_version,
        r6d_privacy_snapshot_digest
      )=3
      AND r6d_privacy_snapshot_version>0
      AND ops.r6d_lower_sha256(r6d_privacy_snapshot_digest))
  );

ALTER TABLE intake.subscriptions
  ADD COLUMN r6d_privacy_snapshot_state text NOT NULL
    DEFAULT 'STAGED_LEGACY',
  ADD COLUMN r6d_privacy_snapshot_id uuid,
  ADD COLUMN r6d_privacy_snapshot_version bigint,
  ADD COLUMN r6d_privacy_snapshot_digest char(64),
  ADD CONSTRAINT subscriptions_r6d_privacy_snapshot_shape_ck CHECK (
    (r6d_privacy_snapshot_state='STAGED_LEGACY'
      AND num_nonnulls(
        r6d_privacy_snapshot_id,r6d_privacy_snapshot_version,
        r6d_privacy_snapshot_digest
      )=0)
    OR
    (r6d_privacy_snapshot_state='CURRENT'
      AND num_nonnulls(
        r6d_privacy_snapshot_id,r6d_privacy_snapshot_version,
        r6d_privacy_snapshot_digest
      )=3
      AND r6d_privacy_snapshot_version>0
      AND ops.r6d_lower_sha256(r6d_privacy_snapshot_digest))
  );

CREATE TABLE ops.privacy_correction_snapshots_v1 (
  snapshot_id uuid PRIMARY KEY,
  correction_id uuid NOT NULL
    REFERENCES editorial.corrections(id) ON DELETE RESTRICT,
  snapshot_version bigint NOT NULL,
  source_correction_version bigint NOT NULL,
  case_id uuid NOT NULL REFERENCES editorial.cases(id) ON DELETE RESTRICT,
  source_updated_at timestamptz NOT NULL,
  snapshot_payload jsonb NOT NULL,
  snapshot_canonical bytea NOT NULL,
  snapshot_digest char(64) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL,
  classification text NOT NULL DEFAULT 'RESTRICTED_GOVERNANCE',
  CONSTRAINT privacy_correction_snapshots_v1_object_version_uq
    UNIQUE(correction_id,snapshot_version),
  CONSTRAINT privacy_correction_snapshots_v1_exact_uq
    UNIQUE(snapshot_id,correction_id,snapshot_version,snapshot_digest),
  CONSTRAINT privacy_correction_snapshots_v1_shape_ck CHECK (
    snapshot_version>0 AND source_correction_version>0
    AND created_at=source_updated_at
    AND classification='RESTRICTED_GOVERNANCE'
    AND ops.r6d_lower_sha256(snapshot_digest)
    AND jsonb_typeof(snapshot_payload)='object'
    AND snapshot_payload ?& ARRAY[
      'schemaVersion','snapshotId','correctionId','snapshotVersion',
      'sourceCorrectionVersion','caseId','sourceRevision','targetRevision',
      'summaryDigest','reasonDigest','affectedClaimSetDigest',
      'replacementContentDigest','status','assignedUserId','priority',
      'triageDecision','triageReasonDigest','resolution',
      'resolutionReasonDigest','resolvedAt','createdBy','sourceCreatedAt',
      'sourceUpdatedAt'
    ]
    AND snapshot_payload-ARRAY[
      'schemaVersion','snapshotId','correctionId','snapshotVersion',
      'sourceCorrectionVersion','caseId','sourceRevision','targetRevision',
      'summaryDigest','reasonDigest','affectedClaimSetDigest',
      'replacementContentDigest','status','assignedUserId','priority',
      'triageDecision','triageReasonDigest','resolution',
      'resolutionReasonDigest','resolvedAt','createdBy','sourceCreatedAt',
      'sourceUpdatedAt'
    ]='{}'::jsonb
    AND snapshot_payload->>'schemaVersion'=
      'privacy-correction-snapshot.v1'
    AND (snapshot_payload->>'snapshotId')::uuid=snapshot_id
    AND (snapshot_payload->>'correctionId')::uuid=correction_id
    AND (snapshot_payload->>'snapshotVersion')::bigint=snapshot_version
    AND (snapshot_payload->>'sourceCorrectionVersion')::bigint=
      source_correction_version
    AND (snapshot_payload->>'caseId')::uuid=case_id
    AND (snapshot_payload->>'sourceUpdatedAt')::timestamptz=
      source_updated_at
    AND ops.r6d_lower_sha256(snapshot_payload->>'summaryDigest')
    AND ops.r6d_lower_sha256(snapshot_payload->>'reasonDigest')
    AND ops.r6d_lower_sha256(
      snapshot_payload->>'affectedClaimSetDigest'
    )
    AND (
      snapshot_payload->'replacementContentDigest'='null'::jsonb
      OR ops.r6d_lower_sha256(
        snapshot_payload->>'replacementContentDigest'
      )
    )
    AND (
      snapshot_payload->'triageReasonDigest'='null'::jsonb
      OR ops.r6d_lower_sha256(snapshot_payload->>'triageReasonDigest')
    )
    AND (
      snapshot_payload->'resolutionReasonDigest'='null'::jsonb
      OR ops.r6d_lower_sha256(snapshot_payload->>'resolutionReasonDigest')
    )
    AND NOT snapshot_payload ?| ARRAY[
      'summary','reason','replacementContent','triageReason',
      'resolutionReason','email','phone','address','contact','plaintext'
    ]
    AND convert_from(snapshot_canonical,'UTF8')::jsonb=snapshot_payload
    AND snapshot_canonical=ops.canonical_jsonb_v1(snapshot_payload)
    AND snapshot_digest=encode(extensions.digest(
      snapshot_canonical,'sha256'
    ),'hex')
  )
);
ALTER TABLE ops.privacy_correction_snapshots_v1 OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_correction_snapshots_v1 FROM PUBLIC;
REVOKE ALL ON ops.privacy_correction_snapshots_v1
  FROM gurine_control_api,gurine_submission_api,gurine_workflow_worker,
    gurine_notification_worker,gurine_scheduler,gurine_auditor;
GRANT SELECT ON ops.privacy_correction_snapshots_v1
  TO gurine_control_api,gurine_workflow_worker,gurine_auditor;

CREATE TABLE ops.privacy_subscription_snapshots_v1 (
  snapshot_id uuid PRIMARY KEY,
  subscription_id uuid NOT NULL
    REFERENCES intake.subscriptions(id) ON DELETE RESTRICT,
  snapshot_version bigint NOT NULL,
  source_updated_at timestamptz NOT NULL,
  snapshot_payload jsonb NOT NULL,
  snapshot_canonical bytea NOT NULL,
  snapshot_digest char(64) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL,
  classification text NOT NULL DEFAULT 'RESTRICTED_GOVERNANCE',
  CONSTRAINT privacy_subscription_snapshots_v1_object_version_uq
    UNIQUE(subscription_id,snapshot_version),
  CONSTRAINT privacy_subscription_snapshots_v1_exact_uq
    UNIQUE(snapshot_id,subscription_id,snapshot_version,snapshot_digest),
  CONSTRAINT privacy_subscription_snapshots_v1_shape_ck CHECK (
    snapshot_version>0 AND created_at=source_updated_at
    AND classification='RESTRICTED_GOVERNANCE'
    AND ops.r6d_lower_sha256(snapshot_digest)
    AND jsonb_typeof(snapshot_payload)='object'
    AND snapshot_payload ?& ARRAY[
      'schemaVersion','snapshotId','subscriptionId','snapshotVersion',
      'emailHash','emailCiphertextDigest','topicsDigest','frequency','locale',
      'status','verificationTokenHash','managementTokenHash','verifiedAt',
      'managementTokenConsumedAt','sourceCreatedAt','sourceUpdatedAt'
    ]
    AND snapshot_payload-ARRAY[
      'schemaVersion','snapshotId','subscriptionId','snapshotVersion',
      'emailHash','emailCiphertextDigest','topicsDigest','frequency','locale',
      'status','verificationTokenHash','managementTokenHash','verifiedAt',
      'managementTokenConsumedAt','sourceCreatedAt','sourceUpdatedAt'
    ]='{}'::jsonb
    AND snapshot_payload->>'schemaVersion'=
      'privacy-subscription-snapshot.v1'
    AND (snapshot_payload->>'snapshotId')::uuid=snapshot_id
    AND (snapshot_payload->>'subscriptionId')::uuid=subscription_id
    AND (snapshot_payload->>'snapshotVersion')::bigint=snapshot_version
    AND (snapshot_payload->>'sourceUpdatedAt')::timestamptz=
      source_updated_at
    AND ops.r6d_lower_sha256(snapshot_payload->>'emailHash')
    AND ops.r6d_lower_sha256(
      snapshot_payload->>'emailCiphertextDigest'
    )
    AND ops.r6d_lower_sha256(snapshot_payload->>'topicsDigest')
    AND (
      snapshot_payload->'verificationTokenHash'='null'::jsonb
      OR ops.r6d_lower_sha256(
        snapshot_payload->>'verificationTokenHash'
      )
    )
    AND (
      snapshot_payload->'managementTokenHash'='null'::jsonb
      OR ops.r6d_lower_sha256(snapshot_payload->>'managementTokenHash')
    )
    AND NOT snapshot_payload ?| ARRAY[
      'email','emailEncrypted','topics','verificationToken',
      'managementToken','phone','address','contact','plaintext'
    ]
    AND convert_from(snapshot_canonical,'UTF8')::jsonb=snapshot_payload
    AND snapshot_canonical=ops.canonical_jsonb_v1(snapshot_payload)
    AND snapshot_digest=encode(extensions.digest(
      snapshot_canonical,'sha256'
    ),'hex')
  )
);
ALTER TABLE ops.privacy_subscription_snapshots_v1 OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_subscription_snapshots_v1 FROM PUBLIC;
REVOKE ALL ON ops.privacy_subscription_snapshots_v1
  FROM gurine_control_api,gurine_submission_api,gurine_workflow_worker,
    gurine_notification_worker,gurine_scheduler,gurine_auditor;
GRANT SELECT ON ops.privacy_subscription_snapshots_v1
  TO gurine_control_api,gurine_workflow_worker,gurine_auditor;

-- The mutable head and immutable snapshot are written in two steps inside one
-- transaction.  MATCH SIMPLE plus the explicit zero-or-all head checks retain
-- MATCH FULL's partial-NULL protection while allowing the reciprocal tuple to
-- be satisfied at transaction end.
ALTER TABLE editorial.corrections
  ADD CONSTRAINT corrections_r6d_privacy_snapshot_fk FOREIGN KEY(
    r6d_privacy_snapshot_id,id,r6d_privacy_snapshot_version,
    r6d_privacy_snapshot_digest
  ) REFERENCES ops.privacy_correction_snapshots_v1(
    snapshot_id,correction_id,snapshot_version,snapshot_digest
  ) MATCH SIMPLE ON DELETE RESTRICT
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE intake.subscriptions
  ADD CONSTRAINT subscriptions_r6d_privacy_snapshot_fk FOREIGN KEY(
    r6d_privacy_snapshot_id,id,r6d_privacy_snapshot_version,
    r6d_privacy_snapshot_digest
  ) REFERENCES ops.privacy_subscription_snapshots_v1(
    snapshot_id,subscription_id,snapshot_version,snapshot_digest
  ) MATCH SIMPLE ON DELETE RESTRICT
    DEFERRABLE INITIALLY DEFERRED;

CREATE OR REPLACE FUNCTION ops.r6d_privacy_correction_snapshot_payload_v1(
  p_row editorial.corrections,
  p_snapshot_id uuid,
  p_snapshot_version bigint
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6d_correction_snapshot_payload$
BEGIN
  IF p_row.id IS NULL OR p_snapshot_id IS NULL OR p_snapshot_version<1
     OR p_row.version<1 OR p_row.updated_at IS NULL THEN
    RAISE EXCEPTION 'r6d_privacy_correction_snapshot_input_invalid'
      USING ERRCODE='23514';
  END IF;
  RETURN jsonb_build_object(
    'schemaVersion','privacy-correction-snapshot.v1',
    'snapshotId',p_snapshot_id,'correctionId',p_row.id,
    'snapshotVersion',p_snapshot_version,
    'sourceCorrectionVersion',p_row.version,'caseId',p_row.case_id,
    'sourceRevision',p_row.source_revision,
    'targetRevision',p_row.target_revision,
    'summaryDigest',encode(extensions.digest(
      convert_to(p_row.summary,'UTF8'),'sha256'
    ),'hex'),
    'reasonDigest',encode(extensions.digest(
      convert_to(p_row.reason,'UTF8'),'sha256'
    ),'hex'),
    'affectedClaimSetDigest',encode(extensions.digest(
      ops.canonical_jsonb_v1(p_row.affected_claim_ids),'sha256'
    ),'hex'),
    'replacementContentDigest',CASE WHEN p_row.replacement_content IS NULL
      THEN NULL ELSE encode(extensions.digest(
        ops.canonical_jsonb_v1(p_row.replacement_content),'sha256'
      ),'hex') END,
    'status',p_row.status,'assignedUserId',p_row.assigned_user_id,
    'priority',p_row.priority,'triageDecision',p_row.triage_decision,
    'triageReasonDigest',CASE WHEN p_row.triage_reason IS NULL THEN NULL
      ELSE encode(extensions.digest(
        convert_to(p_row.triage_reason,'UTF8'),'sha256'
      ),'hex') END,
    'resolution',p_row.resolution,
    'resolutionReasonDigest',CASE WHEN p_row.resolution_reason IS NULL
      THEN NULL ELSE encode(extensions.digest(
        convert_to(p_row.resolution_reason,'UTF8'),'sha256'
      ),'hex') END,
    'resolvedAt',p_row.resolved_at,'createdBy',p_row.created_by,
    'sourceCreatedAt',p_row.created_at,'sourceUpdatedAt',p_row.updated_at
  );
END
$r6d_correction_snapshot_payload$;
ALTER FUNCTION ops.r6d_privacy_correction_snapshot_payload_v1(
  editorial.corrections,uuid,bigint
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_privacy_correction_snapshot_payload_v1(
  editorial.corrections,uuid,bigint
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.r6d_privacy_subscription_snapshot_payload_v1(
  p_row intake.subscriptions,
  p_snapshot_id uuid,
  p_snapshot_version bigint
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,extensions,pg_temp
AS $r6d_subscription_snapshot_payload$
BEGIN
  IF p_row.id IS NULL OR p_snapshot_id IS NULL OR p_snapshot_version<1
     OR p_row.updated_at IS NULL THEN
    RAISE EXCEPTION 'r6d_privacy_subscription_snapshot_input_invalid'
      USING ERRCODE='23514';
  END IF;
  RETURN jsonb_build_object(
    'schemaVersion','privacy-subscription-snapshot.v1',
    'snapshotId',p_snapshot_id,'subscriptionId',p_row.id,
    'snapshotVersion',p_snapshot_version,
    'emailHash',btrim(p_row.email_hash),
    'emailCiphertextDigest',encode(extensions.digest(
      p_row.email_encrypted,'sha256'
    ),'hex'),
    'topicsDigest',encode(extensions.digest(
      ops.canonical_jsonb_v1(p_row.topics),'sha256'
    ),'hex'),
    'frequency',p_row.frequency,'locale',p_row.locale,'status',p_row.status,
    'verificationTokenHash',CASE WHEN p_row.verification_token_hash IS NULL
      THEN NULL ELSE btrim(p_row.verification_token_hash) END,
    'managementTokenHash',CASE WHEN p_row.management_token_hash IS NULL
      THEN NULL ELSE btrim(p_row.management_token_hash) END,
    'verifiedAt',p_row.verified_at,
    'managementTokenConsumedAt',p_row.management_token_consumed_at,
    'sourceCreatedAt',p_row.created_at,'sourceUpdatedAt',p_row.updated_at
  );
END
$r6d_subscription_snapshot_payload$;
ALTER FUNCTION ops.r6d_privacy_subscription_snapshot_payload_v1(
  intake.subscriptions,uuid,bigint
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_privacy_subscription_snapshot_payload_v1(
  intake.subscriptions,uuid,bigint
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.prepare_r6d_correction_privacy_snapshot_v1()
RETURNS trigger
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6d_prepare_correction_snapshot$
DECLARE
  v_snapshot_id uuid:=gen_random_uuid();
  v_snapshot_version bigint;
  v_payload jsonb;
BEGIN
  IF TG_OP='INSERT' THEN
    IF NEW.r6d_privacy_snapshot_state<>'STAGED_LEGACY'
       OR num_nonnulls(
         NEW.r6d_privacy_snapshot_id,NEW.r6d_privacy_snapshot_version,
         NEW.r6d_privacy_snapshot_digest
       )<>0 THEN
      RAISE EXCEPTION 'r6d_privacy_correction_snapshot_caller_forbidden'
        USING ERRCODE='42501';
    END IF;
    v_snapshot_version:=1;
  ELSE
    IF ROW(
      NEW.r6d_privacy_snapshot_state,NEW.r6d_privacy_snapshot_id,
      NEW.r6d_privacy_snapshot_version,NEW.r6d_privacy_snapshot_digest
    ) IS DISTINCT FROM ROW(
      OLD.r6d_privacy_snapshot_state,OLD.r6d_privacy_snapshot_id,
      OLD.r6d_privacy_snapshot_version,OLD.r6d_privacy_snapshot_digest
    ) THEN
      RAISE EXCEPTION 'r6d_privacy_correction_snapshot_caller_forbidden'
        USING ERRCODE='42501';
    END IF;
    IF OLD.r6d_privacy_snapshot_state='STAGED_LEGACY'
       AND num_nonnulls(
         OLD.r6d_privacy_snapshot_id,OLD.r6d_privacy_snapshot_version,
         OLD.r6d_privacy_snapshot_digest
       )=0 THEN
      v_snapshot_version:=1;
    ELSIF OLD.r6d_privacy_snapshot_state='CURRENT'
       AND OLD.r6d_privacy_snapshot_version>0
       AND OLD.r6d_privacy_snapshot_id IS NOT NULL
       AND ops.r6d_lower_sha256(OLD.r6d_privacy_snapshot_digest) THEN
      v_snapshot_version:=OLD.r6d_privacy_snapshot_version+1;
    ELSE
      RAISE EXCEPTION 'r6d_privacy_correction_snapshot_head_invalid'
        USING ERRCODE='23514';
    END IF;
  END IF;
  NEW.r6d_privacy_snapshot_state:='CURRENT';
  NEW.r6d_privacy_snapshot_id:=v_snapshot_id;
  NEW.r6d_privacy_snapshot_version:=v_snapshot_version;
  v_payload:=ops.r6d_privacy_correction_snapshot_payload_v1(
    NEW,v_snapshot_id,v_snapshot_version
  );
  NEW.r6d_privacy_snapshot_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_payload),'sha256'
  ),'hex');
  SET CONSTRAINTS corrections_r6d_privacy_snapshot_fk DEFERRED;
  RETURN NEW;
END
$r6d_prepare_correction_snapshot$;
ALTER FUNCTION ops.prepare_r6d_correction_privacy_snapshot_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.prepare_r6d_correction_privacy_snapshot_v1()
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.prepare_r6d_subscription_privacy_snapshot_v1()
RETURNS trigger
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,extensions,pg_temp
AS $r6d_prepare_subscription_snapshot$
DECLARE
  v_snapshot_id uuid:=gen_random_uuid();
  v_snapshot_version bigint;
  v_payload jsonb;
BEGIN
  IF TG_OP='INSERT' THEN
    IF NEW.r6d_privacy_snapshot_state<>'STAGED_LEGACY'
       OR num_nonnulls(
         NEW.r6d_privacy_snapshot_id,NEW.r6d_privacy_snapshot_version,
         NEW.r6d_privacy_snapshot_digest
       )<>0 THEN
      RAISE EXCEPTION 'r6d_privacy_subscription_snapshot_caller_forbidden'
        USING ERRCODE='42501';
    END IF;
    v_snapshot_version:=1;
  ELSE
    IF ROW(
      NEW.r6d_privacy_snapshot_state,NEW.r6d_privacy_snapshot_id,
      NEW.r6d_privacy_snapshot_version,NEW.r6d_privacy_snapshot_digest
    ) IS DISTINCT FROM ROW(
      OLD.r6d_privacy_snapshot_state,OLD.r6d_privacy_snapshot_id,
      OLD.r6d_privacy_snapshot_version,OLD.r6d_privacy_snapshot_digest
    ) THEN
      RAISE EXCEPTION 'r6d_privacy_subscription_snapshot_caller_forbidden'
        USING ERRCODE='42501';
    END IF;
    IF OLD.r6d_privacy_snapshot_state='STAGED_LEGACY'
       AND num_nonnulls(
         OLD.r6d_privacy_snapshot_id,OLD.r6d_privacy_snapshot_version,
         OLD.r6d_privacy_snapshot_digest
       )=0 THEN
      v_snapshot_version:=1;
    ELSIF OLD.r6d_privacy_snapshot_state='CURRENT'
       AND OLD.r6d_privacy_snapshot_version>0
       AND OLD.r6d_privacy_snapshot_id IS NOT NULL
       AND ops.r6d_lower_sha256(OLD.r6d_privacy_snapshot_digest) THEN
      v_snapshot_version:=OLD.r6d_privacy_snapshot_version+1;
    ELSE
      RAISE EXCEPTION 'r6d_privacy_subscription_snapshot_head_invalid'
        USING ERRCODE='23514';
    END IF;
  END IF;
  NEW.r6d_privacy_snapshot_state:='CURRENT';
  NEW.r6d_privacy_snapshot_id:=v_snapshot_id;
  NEW.r6d_privacy_snapshot_version:=v_snapshot_version;
  v_payload:=ops.r6d_privacy_subscription_snapshot_payload_v1(
    NEW,v_snapshot_id,v_snapshot_version
  );
  NEW.r6d_privacy_snapshot_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_payload),'sha256'
  ),'hex');
  SET CONSTRAINTS subscriptions_r6d_privacy_snapshot_fk DEFERRED;
  RETURN NEW;
END
$r6d_prepare_subscription_snapshot$;
ALTER FUNCTION ops.prepare_r6d_subscription_privacy_snapshot_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.prepare_r6d_subscription_privacy_snapshot_v1()
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.guard_r6d_privacy_snapshot_append_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $r6d_snapshot_append_guard$
DECLARE
  v_prefix text:=CASE TG_TABLE_NAME
    WHEN 'privacy_correction_snapshots_v1' THEN 'CORRECTION'
    WHEN 'privacy_subscription_snapshots_v1' THEN 'SUBSCRIPTION'
    ELSE NULL END;
  v_expected text;
BEGIN
  v_expected:=v_prefix||':'||(to_jsonb(NEW)->>'snapshot_id')||':'||
    (to_jsonb(NEW)->>'snapshot_version')||':'||
    (to_jsonb(NEW)->>'snapshot_digest');
  IF v_prefix IS NULL
     OR current_setting('gurine.r6d_privacy_snapshot_append',true)
        IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'r6d_privacy_snapshot_append_owner_required'
      USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END
$r6d_snapshot_append_guard$;
ALTER FUNCTION ops.guard_r6d_privacy_snapshot_append_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.guard_r6d_privacy_snapshot_append_v1()
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.append_r6d_correction_privacy_snapshot_v1()
RETURNS trigger
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6d_append_correction_snapshot$
DECLARE
  v_payload jsonb;
  v_canonical bytea;
  v_owner_guc text;
BEGIN
  v_payload:=ops.r6d_privacy_correction_snapshot_payload_v1(
    NEW,NEW.r6d_privacy_snapshot_id,NEW.r6d_privacy_snapshot_version
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  IF encode(extensions.digest(v_canonical,'sha256'),'hex')<>
     btrim(NEW.r6d_privacy_snapshot_digest) THEN
    RAISE EXCEPTION 'r6d_privacy_correction_snapshot_digest_mismatch'
      USING ERRCODE='23514';
  END IF;
  v_owner_guc:='CORRECTION:'||NEW.r6d_privacy_snapshot_id::text||':'||
    NEW.r6d_privacy_snapshot_version::text||':'||
    btrim(NEW.r6d_privacy_snapshot_digest);
  PERFORM set_config('gurine.r6d_privacy_snapshot_append',v_owner_guc,true);
  BEGIN
    INSERT INTO ops.privacy_correction_snapshots_v1(
      snapshot_id,correction_id,snapshot_version,
      source_correction_version,case_id,source_updated_at,snapshot_payload,
      snapshot_canonical,snapshot_digest,created_at
    ) VALUES(
      NEW.r6d_privacy_snapshot_id,NEW.id,NEW.r6d_privacy_snapshot_version,
      NEW.version,NEW.case_id,NEW.updated_at,v_payload,v_canonical,
      NEW.r6d_privacy_snapshot_digest,NEW.updated_at
    );
    PERFORM set_config('gurine.r6d_privacy_snapshot_append','',true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('gurine.r6d_privacy_snapshot_append','',true);
    RAISE;
  END;
  RETURN NEW;
END
$r6d_append_correction_snapshot$;
ALTER FUNCTION ops.append_r6d_correction_privacy_snapshot_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.append_r6d_correction_privacy_snapshot_v1()
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.append_r6d_subscription_privacy_snapshot_v1()
RETURNS trigger
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,extensions,pg_temp
AS $r6d_append_subscription_snapshot$
DECLARE
  v_payload jsonb;
  v_canonical bytea;
  v_owner_guc text;
BEGIN
  v_payload:=ops.r6d_privacy_subscription_snapshot_payload_v1(
    NEW,NEW.r6d_privacy_snapshot_id,NEW.r6d_privacy_snapshot_version
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  IF encode(extensions.digest(v_canonical,'sha256'),'hex')<>
     btrim(NEW.r6d_privacy_snapshot_digest) THEN
    RAISE EXCEPTION 'r6d_privacy_subscription_snapshot_digest_mismatch'
      USING ERRCODE='23514';
  END IF;
  v_owner_guc:='SUBSCRIPTION:'||NEW.r6d_privacy_snapshot_id::text||':'||
    NEW.r6d_privacy_snapshot_version::text||':'||
    btrim(NEW.r6d_privacy_snapshot_digest);
  PERFORM set_config('gurine.r6d_privacy_snapshot_append',v_owner_guc,true);
  BEGIN
    INSERT INTO ops.privacy_subscription_snapshots_v1(
      snapshot_id,subscription_id,snapshot_version,source_updated_at,
      snapshot_payload,snapshot_canonical,snapshot_digest,created_at
    ) VALUES(
      NEW.r6d_privacy_snapshot_id,NEW.id,NEW.r6d_privacy_snapshot_version,
      NEW.updated_at,v_payload,v_canonical,NEW.r6d_privacy_snapshot_digest,
      NEW.updated_at
    );
    PERFORM set_config('gurine.r6d_privacy_snapshot_append','',true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('gurine.r6d_privacy_snapshot_append','',true);
    RAISE;
  END;
  RETURN NEW;
END
$r6d_append_subscription_snapshot$;
ALTER FUNCTION ops.append_r6d_subscription_privacy_snapshot_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.append_r6d_subscription_privacy_snapshot_v1()
  FROM PUBLIC;

CREATE TRIGGER privacy_correction_snapshots_v1_append_guard
  BEFORE INSERT ON ops.privacy_correction_snapshots_v1
  FOR EACH ROW EXECUTE FUNCTION ops.guard_r6d_privacy_snapshot_append_v1();
CREATE TRIGGER privacy_correction_snapshots_v1_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_correction_snapshots_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER privacy_subscription_snapshots_v1_append_guard
  BEFORE INSERT ON ops.privacy_subscription_snapshots_v1
  FOR EACH ROW EXECUTE FUNCTION ops.guard_r6d_privacy_snapshot_append_v1();
CREATE TRIGGER privacy_subscription_snapshots_v1_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_subscription_snapshots_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

-- The `zz_` prefix makes the head materializer observe the repository's
-- existing updated_at/publication guards before sealing the immutable bytes.
CREATE TRIGGER zz_corrections_r6d_privacy_snapshot_prepare
  BEFORE INSERT OR UPDATE ON editorial.corrections
  FOR EACH ROW EXECUTE FUNCTION
    ops.prepare_r6d_correction_privacy_snapshot_v1();
CREATE TRIGGER zz_corrections_r6d_privacy_snapshot_append
  AFTER INSERT OR UPDATE ON editorial.corrections
  FOR EACH ROW EXECUTE FUNCTION
    ops.append_r6d_correction_privacy_snapshot_v1();
CREATE TRIGGER zz_subscriptions_r6d_privacy_snapshot_prepare
  BEFORE INSERT OR UPDATE ON intake.subscriptions
  FOR EACH ROW EXECUTE FUNCTION
    ops.prepare_r6d_subscription_privacy_snapshot_v1();
CREATE TRIGGER zz_subscriptions_r6d_privacy_snapshot_append
  AFTER INSERT OR UPDATE ON intake.subscriptions
  FOR EACH ROW EXECUTE FUNCTION
    ops.append_r6d_subscription_privacy_snapshot_v1();

-- Q1 and the legal-hold placement owner are appended below.  Keep this
-- transaction open so later R6d/Q3-Q4 sections can be inserted before COMMIT.

-- Q5 exact legal-hold anchors.  CORRECTION and SUBSCRIPTION target immutable
-- snapshot IDs.  COMMUNICATION_ENDPOINT intentionally binds the existing
-- `(id,version,endpoint_digest)` tuple; no endpoint snapshot digest is
-- invented.  AUDIT_SUBJECT_RECORD is not admitted by any relation or check.
ALTER TABLE ops.legal_hold_target_anchors
  ADD COLUMN correction_id uuid,
  ADD COLUMN correction_snapshot_id uuid,
  ADD COLUMN correction_snapshot_digest char(64),
  ADD COLUMN subscription_id uuid,
  ADD COLUMN subscription_snapshot_id uuid,
  ADD COLUMN subscription_snapshot_digest char(64),
  ADD COLUMN communication_endpoint_id uuid,
  ADD COLUMN communication_endpoint_version bigint,
  ADD COLUMN communication_endpoint_digest char(64);

ALTER TABLE ops.legal_hold_target_anchors
  DROP CONSTRAINT legal_hold_target_anchors_kind_ck,
  DROP CONSTRAINT legal_hold_target_anchors_shape_ck,
  DROP CONSTRAINT legal_hold_target_anchors_digest_ck;

ALTER TABLE ops.legal_hold_target_anchors
  ADD CONSTRAINT legal_hold_target_anchors_correction_snapshot_fk
    FOREIGN KEY(
      correction_snapshot_id,correction_id,target_version,target_digest
    ) REFERENCES ops.privacy_correction_snapshots_v1(
      snapshot_id,correction_id,snapshot_version,snapshot_digest
    ) MATCH SIMPLE ON DELETE RESTRICT,
  ADD CONSTRAINT legal_hold_target_anchors_subscription_snapshot_fk
    FOREIGN KEY(
      subscription_snapshot_id,subscription_id,target_version,target_digest
    ) REFERENCES ops.privacy_subscription_snapshots_v1(
      snapshot_id,subscription_id,snapshot_version,snapshot_digest
    ) MATCH SIMPLE ON DELETE RESTRICT,
  ADD CONSTRAINT legal_hold_target_anchors_communication_endpoint_fk
    FOREIGN KEY(
      communication_endpoint_id,communication_endpoint_version,
      communication_endpoint_digest
    ) REFERENCES intake.communication_endpoints(
      id,version,endpoint_digest
    ) MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT legal_hold_target_anchors_kind_ck CHECK (
    target_kind IN (
      'CASE','PUBLICATION','EVIDENCE','RESPONSE','SOURCE_ASSET',
      'RESEARCH_ARTIFACT','PRIVACY_REQUEST','COMMUNICATION_SUBJECT',
      'SUPPLIER_RETENTION_SNAPSHOT','AGENCY_RETENTION_SNAPSHOT',
      'CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT'
    )
  ),
  ADD CONSTRAINT legal_hold_target_anchors_shape_ck CHECK (
    (
      target_kind='CASE' AND case_id=target_id
      AND case_review_snapshot_id IS NOT NULL
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest,
        correction_id,correction_snapshot_id,correction_snapshot_digest,
        subscription_id,subscription_snapshot_id,
        subscription_snapshot_digest,communication_endpoint_id,
        communication_endpoint_version,communication_endpoint_digest
      )=2
    ) OR (
      target_kind='PUBLICATION' AND publication_revision_id=target_id
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest,
        correction_id,correction_snapshot_id,correction_snapshot_digest,
        subscription_id,subscription_snapshot_id,
        subscription_snapshot_digest,communication_endpoint_id,
        communication_endpoint_version,communication_endpoint_digest
      )=1
    ) OR (
      target_kind='EVIDENCE' AND evidence_id=target_id
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest,
        correction_id,correction_snapshot_id,correction_snapshot_digest,
        subscription_id,subscription_snapshot_id,
        subscription_snapshot_digest,communication_endpoint_id,
        communication_endpoint_version,communication_endpoint_digest
      )=1
    ) OR (
      target_kind='RESPONSE' AND response_id=target_id
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest,
        correction_id,correction_snapshot_id,correction_snapshot_digest,
        subscription_id,subscription_snapshot_id,
        subscription_snapshot_digest,communication_endpoint_id,
        communication_endpoint_version,communication_endpoint_digest
      )=1
    ) OR (
      target_kind='SOURCE_ASSET' AND source_asset_id=target_id
      AND source_document_id IS NOT NULL
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest,
        correction_id,correction_snapshot_id,correction_snapshot_digest,
        subscription_id,subscription_snapshot_id,
        subscription_snapshot_digest,communication_endpoint_id,
        communication_endpoint_version,communication_endpoint_digest
      )=2
    ) OR (
      target_kind='RESEARCH_ARTIFACT' AND research_asset_id=target_id
      AND research_artifact_id IS NOT NULL
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest,
        correction_id,correction_snapshot_id,correction_snapshot_digest,
        subscription_id,subscription_snapshot_id,
        subscription_snapshot_digest,communication_endpoint_id,
        communication_endpoint_version,communication_endpoint_digest
      )=2
    ) OR (
      target_kind='PRIVACY_REQUEST' AND privacy_request_id=target_id
      AND privacy_request_type IN (
        'ACCESS','CORRECTION','DELETION','RESTRICTION'
      )
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest,
        correction_id,correction_snapshot_id,correction_snapshot_digest,
        subscription_id,subscription_snapshot_id,
        subscription_snapshot_digest,communication_endpoint_id,
        communication_endpoint_version,communication_endpoint_digest
      )=2
    ) OR (
      target_kind='COMMUNICATION_SUBJECT'
      AND communication_subject_id=target_id
      AND communication_subject_origin_digest IS NOT NULL
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest,
        correction_id,correction_snapshot_id,correction_snapshot_digest,
        subscription_id,subscription_snapshot_id,
        subscription_snapshot_digest,communication_endpoint_id,
        communication_endpoint_version,communication_endpoint_digest
      )=2
    ) OR (
      target_kind IN (
        'SUPPLIER_RETENTION_SNAPSHOT','AGENCY_RETENTION_SNAPSHOT'
      )
      AND entity_retention_snapshot_id=target_id
      AND entity_retention_snapshot_digest=target_digest
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest,
        correction_id,correction_snapshot_id,correction_snapshot_digest,
        subscription_id,subscription_snapshot_id,
        subscription_snapshot_digest,communication_endpoint_id,
        communication_endpoint_version,communication_endpoint_digest
      )=2
    ) OR (
      target_kind='CORRECTION'
      AND correction_snapshot_id=target_id
      AND correction_snapshot_digest=target_digest
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest,
        correction_id,correction_snapshot_id,correction_snapshot_digest,
        subscription_id,subscription_snapshot_id,
        subscription_snapshot_digest,communication_endpoint_id,
        communication_endpoint_version,communication_endpoint_digest
      )=3
    ) OR (
      target_kind='SUBSCRIPTION'
      AND subscription_snapshot_id=target_id
      AND subscription_snapshot_digest=target_digest
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest,
        correction_id,correction_snapshot_id,correction_snapshot_digest,
        subscription_id,subscription_snapshot_id,
        subscription_snapshot_digest,communication_endpoint_id,
        communication_endpoint_version,communication_endpoint_digest
      )=3
    ) OR (
      target_kind='COMMUNICATION_ENDPOINT'
      AND communication_endpoint_id=target_id
      AND communication_endpoint_version=target_version
      AND communication_endpoint_digest=target_digest
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest,
        correction_id,correction_snapshot_id,correction_snapshot_digest,
        subscription_id,subscription_snapshot_id,
        subscription_snapshot_digest,communication_endpoint_id,
        communication_endpoint_version,communication_endpoint_digest
      )=3
    )
  ),
  ADD CONSTRAINT legal_hold_target_anchors_digest_ck CHECK (
    ops.r6d_lower_sha256(target_digest)
    AND (
      communication_subject_origin_digest IS NULL
      OR ops.r6d_lower_sha256(communication_subject_origin_digest)
    )
    AND (
      entity_retention_snapshot_digest IS NULL
      OR ops.r6d_lower_sha256(entity_retention_snapshot_digest)
    )
    AND (
      correction_snapshot_digest IS NULL
      OR ops.r6d_lower_sha256(correction_snapshot_digest)
    )
    AND (
      subscription_snapshot_digest IS NULL
      OR ops.r6d_lower_sha256(subscription_snapshot_digest)
    )
    AND (
      communication_endpoint_digest IS NULL
      OR ops.r6d_lower_sha256(communication_endpoint_digest)
    )
    AND ops.r6d_lower_sha256(anchor_digest)
  );

ALTER TABLE editorial.legal_holds
  DROP CONSTRAINT legal_holds_object_type_check,
  DROP CONSTRAINT legal_holds_r6d_case_context_ck;
ALTER TABLE editorial.legal_holds
  ADD CONSTRAINT legal_holds_object_type_check CHECK (
    object_type IN (
      'CASE','PUBLICATION','EVIDENCE','RESPONSE','SOURCE_ASSET',
      'RESEARCH_ARTIFACT','PRIVACY_REQUEST','COMMUNICATION_SUBJECT',
      'SUPPLIER_RETENTION_SNAPSHOT','AGENCY_RETENTION_SNAPSHOT',
      'CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT'
    )
  ),
  ADD CONSTRAINT legal_holds_r6d_case_context_ck CHECK (
    (object_type IN (
      'CASE','PUBLICATION','EVIDENCE','RESPONSE','CORRECTION'
    ) AND case_id IS NOT NULL AND review_snapshot_id IS NOT NULL)
    OR
    (object_type IN (
      'SOURCE_ASSET','RESEARCH_ARTIFACT','PRIVACY_REQUEST',
      'COMMUNICATION_SUBJECT','SUPPLIER_RETENTION_SNAPSHOT',
      'AGENCY_RETENTION_SNAPSHOT','SUBSCRIPTION','COMMUNICATION_ENDPOINT'
    ) AND case_id IS NULL AND review_snapshot_id IS NULL)
  );

ALTER TABLE editorial.conflict_snapshots
  DROP CONSTRAINT conflict_snapshots_target_type_ck;
ALTER TABLE editorial.conflict_snapshots
  ADD CONSTRAINT conflict_snapshots_target_type_ck CHECK (
    target_type IN (
      'CASE','REVIEW_SNAPSHOT','ACTION_PROPOSAL','PUBLICATION',
      'COMMUNICATION_INTENT','RESPONSE_REQUEST','LEGAL_HOLD','CAPABILITY',
      'SOURCE_ASSET','RESEARCH_ARTIFACT','PRIVACY_REQUEST',
      'COMMUNICATION_SUBJECT','EVIDENCE','RESPONSE',
      'SUPPLIER_RETENTION_SNAPSHOT','AGENCY_RETENTION_SNAPSHOT',
      'CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT'
    ) AND target_version>0
  );

CREATE OR REPLACE FUNCTION ops.r6d_legal_hold_target_payload_valid_v3(
  p_kind text,
  p_target_id uuid,
  p_target_version bigint,
  p_target_digest char(64),
  p_anchor_digest char(64),
  p_payload jsonb
) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path=pg_catalog,ops,pg_temp
AS $r6d_hold_target_payload$
DECLARE
  v_expected_keys text[];
BEGIN
  IF p_kind IS NULL OR p_target_id IS NULL OR p_target_version<1
     OR NOT COALESCE(ops.r6d_lower_sha256(p_target_digest),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(p_anchor_digest),false)
     OR jsonb_typeof(p_payload)<>'object'
     OR p_payload->>'targetKind'<>p_kind
     OR (p_payload->>'targetId')::uuid<>p_target_id
     OR (p_payload->>'targetVersion')::bigint<>p_target_version
     OR p_payload->>'targetDigest'<>btrim(p_target_digest)
     OR p_payload->>'targetAnchorDigest'<>btrim(p_anchor_digest) THEN
    RETURN false;
  END IF;
  v_expected_keys:=CASE p_kind
    WHEN 'CASE' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','caseId','reviewSnapshotId','reviewSnapshotDigest'
    ]
    WHEN 'PUBLICATION' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','publicationRevisionId'
    ]
    WHEN 'EVIDENCE' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','evidenceId'
    ]
    WHEN 'RESPONSE' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','responseId'
    ]
    WHEN 'SOURCE_ASSET' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','sourceDocumentId','sourceAssetId'
    ]
    WHEN 'RESEARCH_ARTIFACT' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','researchArtifactId','researchAssetId'
    ]
    WHEN 'PRIVACY_REQUEST' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','privacyRequestId','privacyRequestType'
    ]
    WHEN 'COMMUNICATION_SUBJECT' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','communicationSubjectId',
      'communicationSubjectOriginDigest'
    ]
    WHEN 'SUPPLIER_RETENTION_SNAPSHOT' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','entityKind','entityRetentionSnapshotId',
      'entityRetentionSnapshotDigest'
    ]
    WHEN 'AGENCY_RETENTION_SNAPSHOT' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','entityKind','entityRetentionSnapshotId',
      'entityRetentionSnapshotDigest'
    ]
    WHEN 'CORRECTION' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','correctionId','correctionSnapshotId',
      'correctionSnapshotDigest'
    ]
    WHEN 'SUBSCRIPTION' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','subscriptionId','subscriptionSnapshotId',
      'subscriptionSnapshotDigest'
    ]
    WHEN 'COMMUNICATION_ENDPOINT' THEN ARRAY[
      'targetKind','targetId','targetVersion','targetDigest',
      'targetAnchorDigest','communicationEndpointId'
    ]
    ELSE NULL END;
  IF v_expected_keys IS NULL
     OR (SELECT count(*) FROM jsonb_object_keys(p_payload))<>
        cardinality(v_expected_keys)
     OR NOT p_payload ?& v_expected_keys THEN
    RETURN false;
  END IF;
  RETURN CASE p_kind
    WHEN 'CASE' THEN
      (p_payload->>'caseId')::uuid=p_target_id
      AND ops.r6d_lower_sha256(p_payload->>'reviewSnapshotDigest')
    WHEN 'PUBLICATION' THEN
      (p_payload->>'publicationRevisionId')::uuid=p_target_id
    WHEN 'EVIDENCE' THEN (p_payload->>'evidenceId')::uuid=p_target_id
    WHEN 'RESPONSE' THEN (p_payload->>'responseId')::uuid=p_target_id
    WHEN 'SOURCE_ASSET' THEN
      (p_payload->>'sourceAssetId')::uuid=p_target_id
    WHEN 'RESEARCH_ARTIFACT' THEN
      (p_payload->>'researchAssetId')::uuid=p_target_id
    WHEN 'PRIVACY_REQUEST' THEN
      (p_payload->>'privacyRequestId')::uuid=p_target_id
      AND p_payload->>'privacyRequestType' IN (
        'ACCESS','CORRECTION','DELETION','RESTRICTION'
      )
    WHEN 'COMMUNICATION_SUBJECT' THEN
      (p_payload->>'communicationSubjectId')::uuid=p_target_id
      AND ops.r6d_lower_sha256(
        p_payload->>'communicationSubjectOriginDigest'
      )
    WHEN 'SUPPLIER_RETENTION_SNAPSHOT' THEN
      p_payload->>'entityKind'='SUPPLIER'
      AND (p_payload->>'entityRetentionSnapshotId')::uuid=p_target_id
      AND p_payload->>'entityRetentionSnapshotDigest'=
        btrim(p_target_digest)
    WHEN 'AGENCY_RETENTION_SNAPSHOT' THEN
      p_payload->>'entityKind'='AGENCY'
      AND (p_payload->>'entityRetentionSnapshotId')::uuid=p_target_id
      AND p_payload->>'entityRetentionSnapshotDigest'=
        btrim(p_target_digest)
    WHEN 'CORRECTION' THEN
      (p_payload->>'correctionSnapshotId')::uuid=p_target_id
      AND p_payload->>'correctionSnapshotDigest'=btrim(p_target_digest)
    WHEN 'SUBSCRIPTION' THEN
      (p_payload->>'subscriptionSnapshotId')::uuid=p_target_id
      AND p_payload->>'subscriptionSnapshotDigest'=btrim(p_target_digest)
    WHEN 'COMMUNICATION_ENDPOINT' THEN
      (p_payload->>'communicationEndpointId')::uuid=p_target_id
    ELSE false END;
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RETURN false;
END
$r6d_hold_target_payload$;
ALTER FUNCTION ops.r6d_legal_hold_target_payload_valid_v3(
  text,uuid,bigint,char(64),char(64),jsonb
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_legal_hold_target_payload_valid_v3(
  text,uuid,bigint,char(64),char(64),jsonb
) FROM PUBLIC;

ALTER TABLE ops.legal_hold_placement_receipts_v2
  DROP CONSTRAINT legal_hold_placement_receipts_v2_shape_ck;
ALTER TABLE ops.legal_hold_placement_receipts_v2
  ADD CONSTRAINT legal_hold_placement_receipts_v2_shape_ck CHECK (
    target_kind IN (
      'CASE','PUBLICATION','EVIDENCE','RESPONSE','SOURCE_ASSET',
      'RESEARCH_ARTIFACT','PRIVACY_REQUEST','COMMUNICATION_SUBJECT',
      'SUPPLIER_RETENTION_SNAPSHOT','AGENCY_RETENTION_SNAPSHOT',
      'CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT'
    )
    AND target_version>0
    AND ops.r6d_lower_sha256(anchor_digest)
    AND ops.r6d_lower_sha256(target_digest)
    AND ops.r6d_lower_sha256(scope_atoms_digest)
    AND ops.r6d_lower_sha256(affected_set_digest)
    AND ops.r6d_lower_sha256(authority_reference_digest)
    AND ops.r6d_lower_sha256(reason_digest)
    AND ops.r6d_lower_sha256(audit_receipt_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(actor_assertion_request_digest)
    AND ops.r6d_lower_sha256(step_up_authorization_receipt_digest)
    AND ops.r6d_lower_sha256(action_digest)
    AND ops.r6d_lower_sha256(conflict_snapshot_digest)
    AND ops.r6d_lower_sha256(conflict_receipt_digest)
    AND ops.r6d_lower_sha256(placement_approval_receipt_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND length(reason_code) BETWEEN 1 AND 100
    AND btrim(reason_code)=reason_code
    AND conflict_target_id=target_id::text
    AND conflict_evaluation_state='CLEAR'
    AND conflict_valid_until>placed_at
    AND step_up_issued_at<=placed_at
    AND step_up_expires_at>placed_at
    AND step_up_expires_at<=step_up_issued_at+interval '5 minutes 5 seconds'
    AND ops.r6d_legal_hold_target_payload_valid_v3(
      target_kind,target_id,target_version,target_digest,anchor_digest,
      target_payload
    )
    AND target_canonical=ops.canonical_jsonb_v1(target_payload)
    AND cardinality(scope_atoms) BETWEEN 1 AND 3
    AND ops.text_array_is_sorted_unique(scope_atoms)
    AND scope_atoms<@ARRAY['DELETION','DISCLOSURE','RETENTION']::text[]
    AND scope_atoms_digest=encode(extensions.digest(
      ops.canonical_jsonb_v1(to_jsonb(scope_atoms)),'sha256'
    ),'hex')
    AND cardinality(affected_ids) BETWEEN 1 AND 10000
    AND ops.uuid_array_is_sorted_unique(affected_ids)
    AND affected_set_digest=encode(extensions.digest(
      ops.canonical_jsonb_v1(to_jsonb(affected_ids)),'sha256'
    ),'hex')
    AND receipt_payload ?& ARRAY[
      'schemaVersion','receiptId','legalHoldId','target','scopeAtoms',
      'scopeAtomsDigest','affectedIds','affectedSetDigest',
      'authorityReferenceDigest','reasonDigest','placedByActorId','placedAt',
      'expiresAt','requestId','requestDigest','idempotencyKeySha256',
      'auditEventId','auditReceiptDigest','proof'
    ]
    AND receipt_payload-ARRAY[
      'schemaVersion','receiptId','legalHoldId','target','scopeAtoms',
      'scopeAtomsDigest','affectedIds','affectedSetDigest',
      'authorityReferenceDigest','reasonDigest','placedByActorId','placedAt',
      'expiresAt','requestId','requestDigest','idempotencyKeySha256',
      'auditEventId','auditReceiptDigest','proof'
    ]='{}'::jsonb
    AND receipt_payload->>'schemaVersion'=
      'legal-hold-placement-receipt.v2'
    AND (receipt_payload->>'receiptId')::uuid=receipt_id
    AND (receipt_payload->>'legalHoldId')::uuid=legal_hold_id
    AND receipt_payload->'target'=target_payload
    AND receipt_payload->'scopeAtoms'=to_jsonb(scope_atoms)
    AND receipt_payload->>'scopeAtomsDigest'=btrim(scope_atoms_digest)
    AND receipt_payload->'affectedIds'=to_jsonb(affected_ids)
    AND receipt_payload->>'affectedSetDigest'=btrim(affected_set_digest)
    AND receipt_payload->>'authorityReferenceDigest'=
      btrim(authority_reference_digest)
    AND receipt_payload->>'reasonDigest'=btrim(reason_digest)
    AND (receipt_payload->>'placedByActorId')::uuid=actor_id
    AND (receipt_payload->>'placedAt')::timestamptz=placed_at
    AND (
      (jsonb_typeof(receipt_payload->'expiresAt')='null'
        AND expires_at IS NULL)
      OR (jsonb_typeof(receipt_payload->'expiresAt')='string'
        AND (receipt_payload->>'expiresAt')::timestamptz=expires_at)
    )
    AND (receipt_payload->>'requestId')::uuid=request_id
    AND receipt_payload->>'requestDigest'=btrim(request_digest)
    AND receipt_payload->>'idempotencyKeySha256'=
      btrim(idempotency_key_sha256)
    AND (receipt_payload->>'auditEventId')::uuid=audit_event_id
    AND receipt_payload->>'auditReceiptDigest'=btrim(audit_receipt_digest)
    AND jsonb_typeof(receipt_payload->'proof')='object'
    AND receipt_payload->'proof' ?& ARRAY[
      'reasonCode','actorAssertionJti','actorAssertionRequestDigest',
      'stepUpAuthorizationId','stepUpAuthorizationReceiptDigest',
      'stepUpIssuedAt','stepUpExpiresAt','actionDigest',
      'conflictSnapshotId','conflictSnapshotDigest','conflictReceiptDigest',
      'conflictValidUntil','placementApprovalReceiptDigest'
    ]
    AND (receipt_payload->'proof')-ARRAY[
      'reasonCode','actorAssertionJti','actorAssertionRequestDigest',
      'stepUpAuthorizationId','stepUpAuthorizationReceiptDigest',
      'stepUpIssuedAt','stepUpExpiresAt','actionDigest',
      'conflictSnapshotId','conflictSnapshotDigest','conflictReceiptDigest',
      'conflictValidUntil','placementApprovalReceiptDigest'
    ]='{}'::jsonb
    AND receipt_payload->'proof'->>'reasonCode'=reason_code
    AND (receipt_payload->'proof'->>'actorAssertionJti')::uuid=
      actor_assertion_jti
    AND receipt_payload->'proof'->>'actorAssertionRequestDigest'=
      btrim(actor_assertion_request_digest)
    AND (receipt_payload->'proof'->>'stepUpAuthorizationId')::uuid=
      step_up_authorization_id
    AND receipt_payload->'proof'->>'stepUpAuthorizationReceiptDigest'=
      btrim(step_up_authorization_receipt_digest)
    AND (receipt_payload->'proof'->>'stepUpIssuedAt')::timestamptz=
      step_up_issued_at
    AND (receipt_payload->'proof'->>'stepUpExpiresAt')::timestamptz=
      step_up_expires_at
    AND receipt_payload->'proof'->>'actionDigest'=btrim(action_digest)
    AND (receipt_payload->'proof'->>'conflictSnapshotId')::uuid=
      conflict_snapshot_id
    AND receipt_payload->'proof'->>'conflictSnapshotDigest'=
      btrim(conflict_snapshot_digest)
    AND receipt_payload->'proof'->>'conflictReceiptDigest'=
      btrim(conflict_receipt_digest)
    AND (receipt_payload->'proof'->>'conflictValidUntil')::timestamptz=
      conflict_valid_until
    AND receipt_payload->'proof'->>'placementApprovalReceiptDigest'=
      btrim(placement_approval_receipt_digest)
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_canonical=ops.canonical_jsonb_v1(receipt_payload)
    AND receipt_digest=encode(extensions.digest(
      receipt_canonical,'sha256'
    ),'hex')
  );

-- Q5 dedicated privacy-object placement owner.
CREATE OR REPLACE FUNCTION ops.place_r6d_privacy_object_legal_hold_v1(
  p_payload jsonb,
  p_actor_id uuid,
  p_request_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,intake,extensions,pg_temp
AS $$
DECLARE
  v_anchor ops.legal_hold_target_anchors%ROWTYPE;
  v_existing ops.legal_hold_placement_receipts_v2%ROWTYPE;
  v_case editorial.cases%ROWTYPE;
  v_review editorial.review_snapshots%ROWTYPE;
  v_publication editorial.publication_revisions%ROWTYPE;
  v_evidence editorial.evidence%ROWTYPE;
  v_response editorial.responses%ROWTYPE;
  v_source raw.source_documents%ROWTYPE;
  v_research raw.research_artifacts%ROWTYPE;
  v_privacy ops.retention_requests%ROWTYPE;
  v_privacy_decision ops.retention_request_decisions%ROWTYPE;
  v_subject intake.communication_subjects%ROWTYPE;
  v_entity ops.entity_retention_snapshots_v1%ROWTYPE;
  v_correction ops.privacy_correction_snapshots_v1%ROWTYPE;
  v_subscription ops.privacy_subscription_snapshots_v1%ROWTYPE;
  v_endpoint intake.communication_endpoints%ROWTYPE;
  v_assertion ops.assertion_replay_guard%ROWTYPE;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_session ops.sessions%ROWTYPE;
  v_actor ops.users%ROWTYPE;
  v_conflict editorial.conflict_snapshots%ROWTYPE;
  v_conflict_ids uuid[];
  v_hold_id uuid:=gen_random_uuid();
  v_receipt_id uuid:=gen_random_uuid();
  v_anchor_id uuid:=gen_random_uuid();
  v_target_input jsonb;
  v_target_payload jsonb;
  v_target_canonical bytea;
  v_target_kind text;
  v_target_id uuid;
  v_target_version bigint;
  v_target_digest char(64);
  v_anchor_digest char(64);
  v_case_id uuid;
  v_snapshot_id uuid;
  v_case_anchor_id uuid;
  v_case_anchor_snapshot_id uuid;
  v_publication_id uuid;
  v_evidence_id uuid;
  v_response_id uuid;
  v_source_document_id uuid;
  v_source_asset_id uuid;
  v_research_artifact_id uuid;
  v_research_asset_id uuid;
  v_privacy_request_id uuid;
  v_privacy_request_type text;
  v_communication_subject_id uuid;
  v_communication_origin_digest char(64);
  v_entity_snapshot_id uuid;
  v_entity_snapshot_digest char(64);
  v_correction_id uuid;
  v_correction_snapshot_id uuid;
  v_correction_snapshot_digest char(64);
  v_subscription_id uuid;
  v_subscription_snapshot_id uuid;
  v_subscription_snapshot_digest char(64);
  v_communication_endpoint_id uuid;
  v_communication_endpoint_version bigint;
  v_communication_endpoint_digest char(64);
  v_scope_input jsonb;
  v_scope_atoms text[];
  v_scope_atoms_digest char(64);
  v_legacy_scope text;
  v_affected_input jsonb;
  v_affected_ids uuid[];
  v_affected_payload jsonb;
  v_affected_set_digest char(64);
  v_reason_code text;
  v_reason text;
  v_reason_digest char(64);
  v_authority text;
  v_authority_reference_digest char(64);
  v_expires timestamptz;
  v_actor_assertion_jti uuid;
  v_actor_assertion_request_digest char(64);
  v_action_digest char(64);
  v_step_up_authorization_id uuid;
  v_step_up_receipt_payload jsonb;
  v_step_up_receipt_digest char(64);
  v_approval_payload jsonb;
  v_approval_digest char(64);
  v_now timestamptz:=clock_timestamp();
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
  v_audit uuid;
  v_audit_receipt_digest char(64);
  v_event_payload jsonb;
  v_outbox uuid;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR NOT p_payload ?& ARRAY[
       'target','scopeAtoms','affectedIds','authorityReference','reasonCode',
       'reason','expiresAt','_actorAssertionJti','_actorAssuranceLevel',
       '_actorEffectiveCapability','_actorAssertionRequestSha256',
       '_actorActionDigest',
       '_actorStepUpAuthorizationId',
       '_actorIdempotencyKeySha256','_actorRequestKeySha256','_requestId',
       '_requestSha256','_idempotencyKeySha256'
     ]
     OR p_payload-ARRAY[
       'target','scopeAtoms','affectedIds','authorityReference','reasonCode',
       'reason','expiresAt','_actorAssertionJti','_actorAssuranceLevel',
       '_actorEffectiveCapability','_actorAssertionRequestSha256',
       '_actorActionDigest',
       '_actorStepUpAuthorizationId',
       '_actorIdempotencyKeySha256','_actorRequestKeySha256','_requestId',
       '_requestSha256','_idempotencyKeySha256'
     ]<>'{}'::jsonb
     OR jsonb_typeof(p_payload->'target')<>'object'
     OR jsonb_typeof(p_payload->'scopeAtoms')<>'array'
     OR jsonb_typeof(p_payload->'affectedIds')<>'array'
     OR jsonb_typeof(p_payload->'authorityReference')<>'string'
     OR jsonb_typeof(p_payload->'reasonCode')<>'string'
     OR jsonb_typeof(p_payload->'reason')<>'string'
     OR jsonb_typeof(p_payload->'expiresAt') NOT IN ('string','null')
     OR jsonb_typeof(p_payload->'_actorAssertionJti')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssuranceLevel')<>'string'
     OR jsonb_typeof(p_payload->'_actorEffectiveCapability')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssertionRequestSha256')<>'string'
     OR jsonb_typeof(p_payload->'_actorActionDigest')<>'string'
     OR jsonb_typeof(p_payload->'_actorStepUpAuthorizationId')<>'string'
     OR jsonb_typeof(p_payload->'_actorIdempotencyKeySha256')<>'string'
     OR jsonb_typeof(p_payload->'_actorRequestKeySha256')<>'string'
     OR jsonb_typeof(p_payload->'_requestId')<>'string'
     OR jsonb_typeof(p_payload->'_requestSha256')<>'string'
     OR jsonb_typeof(p_payload->'_idempotencyKeySha256')<>'string'
     OR p_actor_id IS NULL OR p_request_id IS NULL
     OR NOT ops.r6d_lower_sha256(p_idempotency_key)
     OR NOT ops.r6d_lower_sha256(p_request_digest) THEN
    RAISE EXCEPTION 'legal_hold_v2_input_invalid' USING ERRCODE='22023';
  END IF;

  v_target_input:=p_payload->'target';
  v_target_kind:=v_target_input->>'targetKind';
  IF jsonb_typeof(v_target_input->'targetKind')<>'string'
     OR jsonb_typeof(v_target_input->'targetId')<>'string'
     OR jsonb_typeof(v_target_input->'targetVersion')<>'number'
     OR jsonb_typeof(v_target_input->'targetDigest')<>'string'
     OR v_target_kind NOT IN (
       'CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT'
     )
     OR v_target_input->>'targetId' !~*
       '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     OR v_target_input->>'targetVersion' !~ '^[1-9][0-9]*$'
     OR v_target_input->>'targetDigest' !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'legal_hold_v2_target_invalid' USING ERRCODE='22023';
  END IF;
  v_target_id:=(v_target_input->>'targetId')::uuid;
  v_target_version:=(v_target_input->>'targetVersion')::bigint;
  v_target_digest:=(v_target_input->>'targetDigest')::char(64);

  IF (v_target_kind='CORRECTION' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'correctionId','correctionSnapshotId','correctionSnapshotDigest'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'correctionId','correctionSnapshotId','correctionSnapshotDigest'
        ]='{}'::jsonb
        AND v_target_input->>'correctionId' ~*
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND v_target_input->>'correctionSnapshotId'=
          v_target_input->>'targetId'
        AND v_target_input->>'correctionSnapshotDigest'=
          v_target_input->>'targetDigest'))
     OR (v_target_kind='SUBSCRIPTION' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'subscriptionId','subscriptionSnapshotId',
          'subscriptionSnapshotDigest'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'subscriptionId','subscriptionSnapshotId',
          'subscriptionSnapshotDigest'
        ]='{}'::jsonb
        AND v_target_input->>'subscriptionId' ~*
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND v_target_input->>'subscriptionSnapshotId'=
          v_target_input->>'targetId'
        AND v_target_input->>'subscriptionSnapshotDigest'=
          v_target_input->>'targetDigest'))
     OR (v_target_kind='COMMUNICATION_ENDPOINT' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'communicationEndpointId'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'communicationEndpointId'
        ]='{}'::jsonb
        AND v_target_input->>'communicationEndpointId'=
          v_target_input->>'targetId')) THEN
    RAISE EXCEPTION 'legal_hold_v2_target_invalid' USING ERRCODE='22023';
  END IF;

  v_scope_input:=p_payload->'scopeAtoms';
  IF jsonb_array_length(v_scope_input) NOT BETWEEN 1 AND 3
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_scope_input) AS atom(value)
       WHERE jsonb_typeof(atom.value)<>'string'
          OR atom.value#>>'{}' NOT IN ('RETENTION','DELETION','DISCLOSURE')
     ) THEN
    RAISE EXCEPTION 'legal_hold_v2_scope_invalid' USING ERRCODE='22023';
  END IF;
  SELECT array_agg(atom ORDER BY atom COLLATE "C") INTO v_scope_atoms
  FROM (
    SELECT DISTINCT value#>>'{}' AS atom
    FROM jsonb_array_elements(v_scope_input) AS element(value)
  ) AS atoms;
  IF cardinality(v_scope_atoms)<>jsonb_array_length(v_scope_input) THEN
    RAISE EXCEPTION 'legal_hold_v2_scope_invalid' USING ERRCODE='22023';
  END IF;
  v_scope_atoms_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(to_jsonb(v_scope_atoms)),'sha256'
  ),'hex');
  v_legacy_scope:=CASE WHEN cardinality(v_scope_atoms)=1
    THEN v_scope_atoms[1] ELSE 'ALL' END;

  v_affected_input:=p_payload->'affectedIds';
  IF jsonb_array_length(v_affected_input) NOT BETWEEN 1 AND 10000
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_affected_input) AS item(value)
       WHERE jsonb_typeof(item.value)<>'string'
          OR item.value#>>'{}' !~*
            '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     ) THEN
    RAISE EXCEPTION 'legal_hold_v2_affected_set_invalid' USING ERRCODE='22023';
  END IF;
  SELECT array_agg(affected_id ORDER BY affected_id) INTO v_affected_ids
  FROM (
    SELECT DISTINCT (value#>>'{}')::uuid AS affected_id
    FROM jsonb_array_elements(v_affected_input) AS element(value)
  ) AS affected;
  IF cardinality(v_affected_ids)<>jsonb_array_length(v_affected_input) THEN
    RAISE EXCEPTION 'legal_hold_v2_affected_set_invalid' USING ERRCODE='22023';
  END IF;
  v_affected_payload:=to_jsonb(v_affected_ids);
  v_affected_set_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_affected_payload),'sha256'
  ),'hex');

  v_reason_code:=p_payload->>'reasonCode';
  v_reason:=p_payload->>'reason';
  v_authority:=p_payload->>'authorityReference';
  IF length(v_reason_code) NOT BETWEEN 1 AND 100
     OR length(v_reason) NOT BETWEEN 1 AND 4000
     OR length(v_authority) NOT BETWEEN 1 AND 500
     OR btrim(v_reason_code)<>v_reason_code
     OR btrim(v_reason)<>v_reason
     OR btrim(v_authority)<>v_authority THEN
    RAISE EXCEPTION 'legal_hold_v2_input_invalid' USING ERRCODE='22023';
  END IF;
  v_reason_digest:=encode(extensions.digest(
    convert_to(v_reason,'UTF8'),'sha256'
  ),'hex');
  v_authority_reference_digest:=encode(extensions.digest(
    convert_to(v_authority,'UTF8'),'sha256'
  ),'hex');
  BEGIN
    v_expires:=CASE WHEN jsonb_typeof(p_payload->'expiresAt')='null'
      THEN NULL ELSE (p_payload->>'expiresAt')::timestamptz END;
  EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
    RAISE EXCEPTION 'legal_hold_v2_input_invalid' USING ERRCODE='22023';
  END;
  IF v_expires IS NOT NULL AND v_expires<=v_now THEN
    RAISE EXCEPTION 'legal_hold_v2_input_invalid' USING ERRCODE='22023';
  END IF;

  v_actor_assertion_jti:=(p_payload->>'_actorAssertionJti')::uuid;
  v_actor_assertion_request_digest:=
    (p_payload->>'_actorAssertionRequestSha256')::char(64);
  v_action_digest:=(p_payload->>'_actorActionDigest')::char(64);
  v_step_up_authorization_id:=
    (p_payload->>'_actorStepUpAuthorizationId')::uuid;
  IF p_payload->>'_actorAssuranceLevel'<>'STEP_UP'
     OR p_payload->>'_actorEffectiveCapability'<>'review.legal'
     OR NOT ops.r6d_lower_sha256(v_actor_assertion_request_digest)
     OR NOT ops.r6d_lower_sha256(v_action_digest)
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorIdempotencyKeySha256')
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorRequestKeySha256')
     OR NOT ops.r6d_lower_sha256(p_payload->>'_requestSha256')
     OR NOT ops.r6d_lower_sha256(p_payload->>'_idempotencyKeySha256')
     OR (p_payload->>'_requestId')::uuid<>p_request_id
     OR p_payload->>'_requestSha256'<>btrim(p_request_digest)
     OR p_payload->>'_idempotencyKeySha256'<>btrim(p_idempotency_key)
     OR p_payload->>'_actorIdempotencyKeySha256'<>btrim(p_idempotency_key)
     OR p_payload->>'_actorRequestKeySha256'<>btrim(p_idempotency_key) THEN
    RAISE EXCEPTION 'legal_hold_v2_actor_binding_invalid'
      USING ERRCODE='42501';
  END IF;

  SELECT * INTO v_assertion FROM ops.assertion_replay_guard
  WHERE assertion_type='ACTOR' AND jti=v_actor_assertion_jti;
  IF NOT FOUND OR v_assertion.issuer<>'identity-api'
     OR v_assertion.audience<>'control-api'
     OR v_assertion.request_digest<>v_actor_assertion_request_digest
     OR v_assertion.expires_at<=v_now THEN
    RAISE EXCEPTION 'legal_hold_v2_actor_assertion_invalid'
      USING ERRCODE='42501';
  END IF;

  -- A transport retry carries a fresh one-shot Actor Assertion JTI while the
  -- business request, STEP_UP authorization and semantic action stay exact.
  -- Resolve immutable business idempotency before requiring the original
  -- authorization to remain open; an exact replay performs zero writes.
  SELECT * INTO v_existing
  FROM ops.legal_hold_placement_receipts_v2
  WHERE idempotency_key_sha256=p_idempotency_key FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest<>p_request_digest
       OR v_existing.actor_id<>p_actor_id
       OR v_existing.step_up_authorization_id<>
         v_step_up_authorization_id
       OR v_existing.action_digest<>v_action_digest
       OR v_existing.reason_code<>v_reason_code
       OR v_existing.reason_digest<>v_reason_digest
       OR v_existing.authority_reference_digest<>
         v_authority_reference_digest
       OR v_existing.scope_atoms<>v_scope_atoms
       OR v_existing.affected_ids<>v_affected_ids
       OR (v_existing.target_payload-'targetAnchorDigest')<>v_target_input
       OR v_existing.expires_at IS DISTINCT FROM v_expires THEN
      RAISE EXCEPTION 'legal_hold_v2_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN (v_existing.receipt_payload-'proof')||jsonb_build_object(
      'receiptDigest',btrim(v_existing.receipt_digest),
      'holdReceiptDigest',btrim(v_existing.receipt_digest),
      'outboxEventIds',jsonb_build_array(v_existing.outbox_event_id),
      'replayed',true
    );
  END IF;

  SELECT * INTO v_step_up FROM ops.step_up_authorizations
  WHERE id=v_step_up_authorization_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'legal_hold_v2_step_up_invalid' USING ERRCODE='42501';
  END IF;
  SELECT * INTO v_session FROM ops.sessions
  WHERE id=v_step_up.session_id FOR SHARE;
  SELECT * INTO v_actor FROM ops.users WHERE id=p_actor_id FOR SHARE;
  IF v_session.id IS NULL OR v_actor.id IS NULL OR v_actor.status<>'ACTIVE'
     OR v_session.user_id<>p_actor_id OR v_session.revoked_at IS NOT NULL
     OR v_session.expires_at<=v_now OR v_step_up.closed_at IS NOT NULL
     OR v_step_up.expires_at<=v_now
     OR v_step_up.action_digest<>v_action_digest
     OR v_step_up.idempotency_key_sha256<>p_idempotency_key
     OR v_step_up.assertion_issue_count NOT BETWEEN 1 AND 3
     OR v_step_up.assertion_issue_count>v_step_up.max_assertion_issues
     OR v_step_up.last_issued_at IS NULL OR v_step_up.last_issued_at>v_now
     OR v_step_up.last_issued_at>=v_step_up.expires_at
     OR v_step_up.expires_at>
       v_step_up.last_issued_at+interval '5 minutes 5 seconds'
     OR NOT EXISTS (
       SELECT 1 FROM ops.user_roles AS user_role
       JOIN ops.role_capabilities AS role_capability
         ON role_capability.role_id=user_role.role_id
        AND role_capability.capability_code='review.legal'
       WHERE user_role.user_id=p_actor_id
         AND user_role.revoked_at IS NULL
         AND (user_role.expires_at IS NULL OR user_role.expires_at>v_now)
     ) THEN
    RAISE EXCEPTION 'legal_hold_v2_step_up_invalid' USING ERRCODE='42501';
  END IF;
  v_step_up_receipt_payload:=jsonb_build_object(
    'schemaVersion','step-up-authorization-receipt.v1',
    'authorizationId',v_step_up.id,'actionDigest',btrim(v_step_up.action_digest),
    'sessionId',v_step_up.session_id,
    'issueNumber',v_step_up.assertion_issue_count,
    'issuedAt',v_step_up.last_issued_at,'expiresAt',v_step_up.expires_at
  );
  v_step_up_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_step_up_receipt_payload),'sha256'
  ),'hex');

  CASE v_target_kind
    WHEN 'CORRECTION' THEN
      SELECT snapshot.* INTO v_correction
      FROM ops.privacy_correction_snapshots_v1 AS snapshot
      WHERE snapshot.snapshot_id=v_target_id
      FOR SHARE;
      IF v_correction.snapshot_id IS NULL
         OR v_correction.correction_id<>
           (v_target_input->>'correctionId')::uuid
         OR v_correction.snapshot_version<>v_target_version
         OR v_correction.snapshot_digest<>v_target_digest THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      SELECT case_row.* INTO v_case
      FROM editorial.cases AS case_row
      WHERE case_row.id=v_correction.case_id
      FOR SHARE;
      SELECT review.* INTO v_review
      FROM editorial.review_snapshots AS review
      WHERE review.id=v_case.current_review_snapshot_id
      FOR SHARE;
      IF v_case.id IS NULL OR v_review.id IS NULL
         OR v_review.case_id<>v_case.id
         OR v_review.case_version<>v_case.version THEN
        RAISE EXCEPTION 'legal_hold_v2_case_context_missing'
          USING ERRCODE='23514';
      END IF;
      v_case_id:=v_case.id;
      v_snapshot_id:=v_review.id;
      v_correction_id:=v_correction.correction_id;
      v_correction_snapshot_id:=v_correction.snapshot_id;
      v_correction_snapshot_digest:=v_correction.snapshot_digest;
    WHEN 'SUBSCRIPTION' THEN
      SELECT snapshot.* INTO v_subscription
      FROM ops.privacy_subscription_snapshots_v1 AS snapshot
      WHERE snapshot.snapshot_id=v_target_id
      FOR SHARE;
      IF v_subscription.snapshot_id IS NULL
         OR v_subscription.subscription_id<>
           (v_target_input->>'subscriptionId')::uuid
         OR v_subscription.snapshot_version<>v_target_version
         OR v_subscription.snapshot_digest<>v_target_digest THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      v_subscription_id:=v_subscription.subscription_id;
      v_subscription_snapshot_id:=v_subscription.snapshot_id;
      v_subscription_snapshot_digest:=v_subscription.snapshot_digest;
    WHEN 'COMMUNICATION_ENDPOINT' THEN
      SELECT endpoint.* INTO v_endpoint
      FROM intake.communication_endpoints AS endpoint
      WHERE endpoint.id=v_target_id
      FOR SHARE;
      IF v_endpoint.id IS NULL OR v_endpoint.version<>v_target_version
         OR v_endpoint.endpoint_digest<>v_target_digest THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      v_communication_endpoint_id:=v_endpoint.id;
      v_communication_endpoint_version:=v_endpoint.version;
      v_communication_endpoint_digest:=v_endpoint.endpoint_digest;
  END CASE;

  SELECT ARRAY(
    SELECT conflict.id FROM editorial.conflict_snapshots AS conflict
    WHERE conflict.subject_actor_id=p_actor_id
      AND conflict.target_type=v_target_kind
      AND conflict.target_id=v_target_id::text
      AND conflict.target_version=v_target_version
      AND conflict.target_digest=v_target_digest
      AND conflict.operation_id='placeLegalHold'
      AND conflict.action_kind IS NULL
      AND conflict.candidate_role='LEGAL_REVIEWER'
      AND conflict.evaluation_state='CLEAR'
      AND conflict.valid_until>v_now
    ORDER BY conflict.evaluated_at DESC,conflict.id
    FOR SHARE
  ) INTO v_conflict_ids;
  IF cardinality(v_conflict_ids)<>1 THEN
    RAISE EXCEPTION 'legal_hold_v2_conflict_proof_missing_or_ambiguous'
      USING ERRCODE='55000';
  END IF;
  SELECT * INTO STRICT v_conflict FROM editorial.conflict_snapshots
  WHERE id=v_conflict_ids[1] FOR SHARE;

  v_anchor_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','legal-hold-target-anchor.v2','target',v_target_input
    )
  ),'sha256'),'hex');
  v_target_payload:=v_target_input||jsonb_build_object(
    'targetAnchorDigest',btrim(v_anchor_digest)
  );
  v_target_canonical:=ops.canonical_jsonb_v1(v_target_payload);
  v_approval_payload:=jsonb_build_object(
    'schemaVersion','legal-hold-placement-approval.v2',
    'actorId',p_actor_id,'actorAssertionJti',v_actor_assertion_jti,
    'actorAssertionRequestDigest',btrim(v_actor_assertion_request_digest),
    'target',v_target_payload,'scopeAtomsDigest',btrim(v_scope_atoms_digest),
    'affectedSetDigest',btrim(v_affected_set_digest),
    'authorityReferenceDigest',btrim(v_authority_reference_digest),
    'reasonCode',v_reason_code,'reasonDigest',btrim(v_reason_digest),
    'stepUpAuthorizationId',v_step_up.id,
    'stepUpAuthorizationReceiptDigest',btrim(v_step_up_receipt_digest),
    'actionDigest',btrim(v_action_digest),
    'conflictSnapshotId',v_conflict.id,
    'conflictSnapshotDigest',btrim(v_conflict.snapshot_sha256),
    'conflictReceiptDigest',btrim(v_conflict.receipt_digest),
    'conflictValidUntil',v_conflict.valid_until,
    'requestId',p_request_id,'requestDigest',btrim(p_request_digest),
    'idempotencyKeySha256',btrim(p_idempotency_key),
    'placedAt',v_now
  );
  v_approval_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_approval_payload),'sha256'
  ),'hex');

  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_target_kind||':'||v_target_id::text||':'||v_target_version::text||':'||
      btrim(v_target_digest),38
  ));
  SELECT * INTO v_anchor FROM ops.legal_hold_target_anchors
  WHERE target_kind=v_target_kind AND target_id=v_target_id
    AND target_version=v_target_version AND target_digest=v_target_digest
  FOR SHARE;

  v_audit:=ops.append_audit_event(
    'legal-hold:'||v_hold_id::text,'USER',p_actor_id::text,NULL::uuid,
    'command.placeLegalHold','LegalHold',v_hold_id::text,'review.legal',
    'SUCCESS',NULL,p_request_id,
    jsonb_build_object(
      'targetAnchorDigest',btrim(v_anchor_digest),
      'scopeAtomsDigest',btrim(v_scope_atoms_digest),
      'affectedSetDigest',btrim(v_affected_set_digest),
      'authorityReferenceDigest',btrim(v_authority_reference_digest),
      'reasonCode',v_reason_code,'reasonDigest',btrim(v_reason_digest),
      'actorAssertionJti',v_actor_assertion_jti,
      'actorAssertionRequestDigest',btrim(v_actor_assertion_request_digest),
      'requestDigest',btrim(p_request_digest),
      'stepUpAuthorizationReceiptDigest',btrim(v_step_up_receipt_digest),
      'conflictSnapshotDigest',btrim(v_conflict.snapshot_sha256),
      'placementApprovalReceiptDigest',btrim(v_approval_digest)
    )
  );
  SELECT event_hash INTO STRICT v_audit_receipt_digest
  FROM ops.audit_events WHERE id=v_audit;

  IF v_anchor.id IS NULL THEN
    INSERT INTO ops.legal_hold_target_anchors(
      id,target_kind,target_id,target_version,target_digest,case_id,
      case_review_snapshot_id,publication_revision_id,evidence_id,response_id,
      source_document_id,source_asset_id,research_artifact_id,research_asset_id,
      privacy_request_id,privacy_request_type,communication_subject_id,
      communication_subject_origin_digest,entity_retention_snapshot_id,
      entity_retention_snapshot_digest,correction_id,correction_snapshot_id,
      correction_snapshot_digest,subscription_id,subscription_snapshot_id,
      subscription_snapshot_digest,communication_endpoint_id,
      communication_endpoint_version,communication_endpoint_digest,
      anchor_digest,audit_event_id
    ) VALUES(
      v_anchor_id,v_target_kind,v_target_id,v_target_version,v_target_digest,
      v_case_anchor_id,v_case_anchor_snapshot_id,v_publication_id,v_evidence_id,
      v_response_id,v_source_document_id,v_source_asset_id,
      v_research_artifact_id,v_research_asset_id,v_privacy_request_id,
      v_privacy_request_type,v_communication_subject_id,
      v_communication_origin_digest,v_entity_snapshot_id,
      v_entity_snapshot_digest,v_correction_id,v_correction_snapshot_id,
      v_correction_snapshot_digest,v_subscription_id,
      v_subscription_snapshot_id,v_subscription_snapshot_digest,
      v_communication_endpoint_id,v_communication_endpoint_version,
      v_communication_endpoint_digest,v_anchor_digest,v_audit
    ) RETURNING * INTO v_anchor;
  END IF;
  IF v_anchor.anchor_digest<>v_anchor_digest
     OR (v_target_kind='CORRECTION' AND (
       v_anchor.correction_id IS DISTINCT FROM v_correction_id
       OR v_anchor.correction_snapshot_id IS DISTINCT FROM
         v_correction_snapshot_id
       OR v_anchor.correction_snapshot_digest IS DISTINCT FROM
         v_correction_snapshot_digest))
     OR (v_target_kind='SUBSCRIPTION' AND (
       v_anchor.subscription_id IS DISTINCT FROM v_subscription_id
       OR v_anchor.subscription_snapshot_id IS DISTINCT FROM
         v_subscription_snapshot_id
       OR v_anchor.subscription_snapshot_digest IS DISTINCT FROM
         v_subscription_snapshot_digest))
     OR (v_target_kind='COMMUNICATION_ENDPOINT' AND (
       v_anchor.communication_endpoint_id IS DISTINCT FROM
         v_communication_endpoint_id
       OR v_anchor.communication_endpoint_version IS DISTINCT FROM
         v_communication_endpoint_version
       OR v_anchor.communication_endpoint_digest IS DISTINCT FROM
         v_communication_endpoint_digest)) THEN
    RAISE EXCEPTION 'legal_hold_v2_anchor_conflict' USING ERRCODE='23514';
  END IF;

  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','legal-hold-placement-receipt.v2',
    'receiptId',v_receipt_id,'legalHoldId',v_hold_id,
    'target',v_target_payload,'scopeAtoms',to_jsonb(v_scope_atoms),
    'scopeAtomsDigest',btrim(v_scope_atoms_digest),
    'affectedIds',v_affected_payload,
    'affectedSetDigest',btrim(v_affected_set_digest),
    'authorityReferenceDigest',btrim(v_authority_reference_digest),
    'reasonDigest',btrim(v_reason_digest),
    'placedByActorId',p_actor_id,'placedAt',v_now,'expiresAt',v_expires,
    'requestId',p_request_id,'requestDigest',btrim(p_request_digest),
    'idempotencyKeySha256',btrim(p_idempotency_key),
    'auditEventId',v_audit,'auditReceiptDigest',btrim(v_audit_receipt_digest),
    'proof',jsonb_build_object(
      'reasonCode',v_reason_code,'actorAssertionJti',v_actor_assertion_jti,
      'actorAssertionRequestDigest',btrim(v_actor_assertion_request_digest),
      'stepUpAuthorizationId',v_step_up.id,
      'stepUpAuthorizationReceiptDigest',btrim(v_step_up_receipt_digest),
      'stepUpIssuedAt',v_step_up.last_issued_at,
      'stepUpExpiresAt',v_step_up.expires_at,
      'actionDigest',btrim(v_action_digest),
      'conflictSnapshotId',v_conflict.id,
      'conflictSnapshotDigest',btrim(v_conflict.snapshot_sha256),
      'conflictReceiptDigest',btrim(v_conflict.receipt_digest),
      'conflictValidUntil',v_conflict.valid_until,
      'placementApprovalReceiptDigest',btrim(v_approval_digest)
    )
  );
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_receipt_digest:=encode(extensions.digest(
    v_receipt_canonical,'sha256'
  ),'hex');
  v_event_payload:=jsonb_build_object(
    'legalHoldId',v_hold_id,'target',v_target_payload,
    'scopeAtoms',to_jsonb(v_scope_atoms),
    'affectedSetDigest',btrim(v_affected_set_digest),
    'authorityReferenceDigest',btrim(v_authority_reference_digest),
    'placedByActorId',p_actor_id,'placedAt',v_now,'expiresAt',v_expires,
    'auditReceiptDigest',btrim(v_audit_receipt_digest),
    'holdReceiptDigest',btrim(v_receipt_digest)
  );
  v_outbox:=ops.enqueue_outbox(
    'legal_hold',v_hold_id::text,1,'legal_hold.placed.v2',v_event_payload,v_now
  );

  INSERT INTO editorial.legal_holds(
    id,case_id,review_snapshot_id,object_type,object_id,scope,affected_ids,
    reason,authority_reference,expires_at,active,version,placed_by,placed_at
  ) VALUES(
    v_hold_id,v_case_id,v_snapshot_id,v_target_kind,v_target_id,
    v_legacy_scope,v_affected_payload,v_reason,v_authority,v_expires,true,1,
    p_actor_id,v_now
  );
  INSERT INTO ops.legal_hold_placement_receipts_v2(
    receipt_id,legal_hold_id,anchor_id,anchor_digest,target_kind,target_id,
    target_version,target_digest,target_payload,target_canonical,scope_atoms,
    scope_atoms_digest,affected_ids,affected_set_digest,
    authority_reference_digest,reason_code,reason_digest,actor_id,request_id,
    idempotency_key_sha256,request_digest,actor_assertion_jti,
    actor_assertion_request_digest,step_up_authorization_id,
    step_up_authorization_receipt_digest,step_up_issued_at,step_up_expires_at,
    action_digest,conflict_snapshot_id,conflict_target_id,
    conflict_snapshot_digest,conflict_receipt_digest,
    conflict_evaluation_state,conflict_valid_until,
    placement_approval_receipt_digest,audit_event_id,audit_receipt_digest,
    outbox_event_id,receipt_payload,receipt_canonical,receipt_digest,placed_at,
    expires_at
  ) VALUES(
    v_receipt_id,v_hold_id,v_anchor.id,v_anchor.anchor_digest,v_target_kind,
    v_target_id,v_target_version,v_target_digest,v_target_payload,
    v_target_canonical,v_scope_atoms,v_scope_atoms_digest,v_affected_ids,
    v_affected_set_digest,v_authority_reference_digest,v_reason_code,
    v_reason_digest,p_actor_id,p_request_id,p_idempotency_key,p_request_digest,
    v_actor_assertion_jti,v_actor_assertion_request_digest,v_step_up.id,
    v_step_up_receipt_digest,v_step_up.last_issued_at,v_step_up.expires_at,
    v_action_digest,v_conflict.id,v_target_id::text,v_conflict.snapshot_sha256,
    v_conflict.receipt_digest,v_conflict.evaluation_state,
    v_conflict.valid_until,v_approval_digest,v_audit,v_audit_receipt_digest,
    v_outbox,v_receipt_payload,v_receipt_canonical,v_receipt_digest,v_now,
    v_expires
  );
  RETURN (v_receipt_payload-'proof')||jsonb_build_object(
    'receiptDigest',btrim(v_receipt_digest),
    'holdReceiptDigest',btrim(v_receipt_digest),
    'outboxEventIds',jsonb_build_array(v_outbox),'replayed',false
  );
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'legal_hold_v2_input_invalid' USING ERRCODE='22023';
END
$$;
ALTER FUNCTION ops.place_r6d_privacy_object_legal_hold_v1(
  jsonb,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.place_r6d_privacy_object_legal_hold_v1(
  jsonb,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.place_r6d_privacy_object_legal_hold_v1(
  jsonb,uuid,uuid,char(64),char(64)
) FROM gurine_control_api;


-- Q5 public dispatcher preserves the 0039 entity advisory fence for every
-- pre-0040 target and routes only the three authorized privacy-object tuples.
ALTER FUNCTION ops.place_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) RENAME TO place_legal_hold_v2_pre_r6d_q5_privacy_kinds;
REVOKE ALL ON FUNCTION ops.place_legal_hold_v2_pre_r6d_q5_privacy_kinds(
  jsonb,uuid,uuid,char(64),char(64)
) FROM PUBLIC,gurine_control_api;

CREATE OR REPLACE FUNCTION ops.place_legal_hold_v2(
  p_payload jsonb,
  p_actor_id uuid,
  p_request_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $r6d_q5_hold_dispatcher$
DECLARE
  v_target_kind text:=p_payload->'target'->>'targetKind';
BEGIN
  IF v_target_kind='AUDIT_SUBJECT_RECORD' THEN
    RAISE EXCEPTION 'LEGAL_HOLD_TARGET_UNSUPPORTED'
      USING ERRCODE='0A000';
  END IF;
  IF v_target_kind IN (
    'CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT'
  ) THEN
    RETURN ops.place_r6d_privacy_object_legal_hold_v1(
      p_payload,p_actor_id,p_request_id,p_idempotency_key,p_request_digest
    );
  END IF;
  RETURN ops.place_legal_hold_v2_pre_r6d_q5_privacy_kinds(
    p_payload,p_actor_id,p_request_id,p_idempotency_key,p_request_digest
  );
END
$r6d_q5_hold_dispatcher$;
ALTER FUNCTION ops.place_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.place_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.place_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) TO gurine_control_api;


-- Q5 privacy-request coverage is an explicit six-kind mapping.  Aggregate
-- PRIVACY_REQUEST/COMMUNICATION_SUBJECT anchors are not substitutes for the
-- concrete inventory member.  AUDIT_SUBJECT_RECORD remains a loud unsupported
-- branch until it has a versioned immutable source relation.
CREATE OR REPLACE FUNCTION ops.r6d_privacy_request_legal_hold_coverage_v1(
  p_privacy_request_id uuid,
  p_at_time timestamptz
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6d_q5_privacy_hold_coverage$
DECLARE
  v_inventory_count bigint;
  v_inventory ops.privacy_request_scope_inventories_v1%ROWTYPE;
  v_item_count bigint;
  v_materialized_refs jsonb;
  v_hold_id uuid;
  v_hold_resolution jsonb;
  v_cell jsonb;
  v_hold_proofs jsonb:='[]'::jsonb;
  v_active_cells jsonb:='[]'::jsonb;
  v_coverage_payload jsonb;
  v_coverage_digest char(64);
BEGIN
  IF p_privacy_request_id IS NULL OR p_at_time IS NULL THEN
    RAISE EXCEPTION 'r6d_privacy_hold_resolution_input_invalid'
      USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_privacy_request_id::text,13)
  );
  SELECT count(*) INTO v_inventory_count
  FROM ops.privacy_request_scope_inventories_v1 AS inventory
  WHERE inventory.privacy_request_id=p_privacy_request_id;
  IF v_inventory_count<>1 THEN
    RAISE EXCEPTION 'r6d_privacy_hold_inventory_missing_or_ambiguous'
      USING ERRCODE='55000';
  END IF;
  SELECT inventory.* INTO STRICT v_inventory
  FROM ops.privacy_request_scope_inventories_v1 AS inventory
  WHERE inventory.privacy_request_id=p_privacy_request_id
  FOR SHARE;
  IF v_inventory.scope_kind<>'OBJECT_SET'
     OR v_inventory.include_derivatives
     OR v_inventory.include_backups THEN
    RAISE EXCEPTION
      'r6d_privacy_hold_inventory_unmaterialized_or_inconsistent'
      USING ERRCODE='55000';
  END IF;
  SELECT count(*),COALESCE(jsonb_agg(jsonb_build_object(
    'objectType',item.object_kind,'objectId',item.object_id
  ) ORDER BY item.object_kind,item.object_id),'[]'::jsonb)
  INTO v_item_count,v_materialized_refs
  FROM ops.privacy_request_scope_inventory_items_v1 AS item
  WHERE item.scope_inventory_id=v_inventory.scope_inventory_id
    AND item.privacy_request_id=p_privacy_request_id;
  IF v_item_count<1
     OR v_item_count<>v_inventory.object_item_count
     OR EXISTS(
       SELECT 1
       FROM ops.privacy_request_scope_inventory_items_v1 AS item
       WHERE item.scope_inventory_id=v_inventory.scope_inventory_id
         AND item.privacy_request_id<>p_privacy_request_id
     )
     OR EXISTS(
       SELECT 1
       FROM ops.privacy_request_scope_inventory_items_v1 AS item
       WHERE item.privacy_request_id=p_privacy_request_id
         AND item.scope_inventory_id<>v_inventory.scope_inventory_id
     )
     OR EXISTS(
       SELECT 1
       FROM (
         SELECT item.item_ordinal,row_number() OVER (
           ORDER BY item.item_ordinal
         ) AS expected_ordinal
         FROM ops.privacy_request_scope_inventory_items_v1 AS item
         WHERE item.scope_inventory_id=v_inventory.scope_inventory_id
           AND item.privacy_request_id=p_privacy_request_id
       ) AS materialized
       WHERE materialized.item_ordinal<>materialized.expected_ordinal
     )
     OR EXISTS(
       SELECT 1
       FROM ops.privacy_request_scope_inventory_items_v1 AS item
       WHERE item.scope_inventory_id=v_inventory.scope_inventory_id
         AND item.privacy_request_id=p_privacy_request_id
         AND item.item_digest<>encode(extensions.digest(
           ops.canonical_jsonb_v1(jsonb_build_object(
             'objectType',item.object_kind,'objectId',item.object_id
           )),'sha256'
         ),'hex')
     )
     OR v_inventory.object_item_set_digest<>encode(extensions.digest(
       ops.canonical_jsonb_v1(v_materialized_refs),'sha256'
     ),'hex') THEN
    RAISE EXCEPTION
      'r6d_privacy_hold_inventory_unmaterialized_or_inconsistent'
      USING ERRCODE='55000';
  END IF;
  IF EXISTS(
    SELECT 1
    FROM ops.privacy_request_scope_inventory_items_v1 AS item
    WHERE item.scope_inventory_id=v_inventory.scope_inventory_id
      AND item.privacy_request_id=p_privacy_request_id
      AND item.object_kind='AUDIT_SUBJECT_RECORD'
  ) THEN
    RAISE EXCEPTION 'LEGAL_HOLD_TARGET_UNSUPPORTED'
      USING ERRCODE='0A000';
  END IF;
  IF EXISTS(
    SELECT 1
    FROM ops.privacy_request_scope_inventory_items_v1 AS item
    WHERE item.scope_inventory_id=v_inventory.scope_inventory_id
      AND item.privacy_request_id=p_privacy_request_id
      AND item.object_kind NOT IN (
        'RESPONSE','CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT',
        'PUBLICATION','EVIDENCE'
      )
  ) THEN
    RAISE EXCEPTION 'r6d_privacy_hold_target_mapping_invalid'
      USING ERRCODE='55000';
  END IF;
  FOR v_hold_id IN
    SELECT DISTINCT placement.legal_hold_id
    FROM ops.privacy_request_scope_inventory_items_v1 AS item
    JOIN ops.legal_hold_target_anchors AS anchor ON (
      item.object_kind='RESPONSE'
        AND anchor.target_kind='RESPONSE'
        AND anchor.response_id=item.object_id
      OR item.object_kind='CORRECTION'
        AND anchor.target_kind='CORRECTION'
        AND anchor.correction_id=item.object_id
      OR item.object_kind='SUBSCRIPTION'
        AND anchor.target_kind='SUBSCRIPTION'
        AND anchor.subscription_id=item.object_id
      OR item.object_kind='COMMUNICATION_ENDPOINT'
        AND anchor.target_kind='COMMUNICATION_ENDPOINT'
        AND anchor.communication_endpoint_id=item.object_id
      OR item.object_kind='PUBLICATION'
        AND anchor.target_kind='PUBLICATION'
        AND anchor.publication_revision_id=item.object_id
      OR item.object_kind='EVIDENCE'
        AND anchor.target_kind='EVIDENCE'
        AND anchor.evidence_id=item.object_id
    )
    JOIN ops.legal_hold_placement_receipts_v2 AS placement
      ON placement.anchor_id=anchor.id
     AND placement.anchor_digest=anchor.anchor_digest
    WHERE item.scope_inventory_id=v_inventory.scope_inventory_id
      AND item.privacy_request_id=p_privacy_request_id
      AND placement.placed_at<=p_at_time
      AND placement.affected_ids @>
        ARRAY[p_privacy_request_id]::uuid[]
    ORDER BY placement.legal_hold_id
  LOOP
    v_hold_resolution:=ops.r6d_legal_hold_cell_resolution_v1(
      v_hold_id,p_at_time
    );
    v_hold_proofs:=v_hold_proofs||jsonb_build_array(
      v_hold_resolution->'proof'
    );
    FOR v_cell IN
      SELECT value FROM jsonb_array_elements(
        v_hold_resolution->'activeCells'
      ) AS cells(value)
    LOOP
      IF v_cell->>'scopeAtom' IN ('RETENTION','DELETION')
         AND (v_cell->>'affectedId')::uuid=p_privacy_request_id THEN
        v_active_cells:=v_active_cells||jsonb_build_array(
          jsonb_build_object(
            'holdId',v_hold_id,'scopeAtom',v_cell->>'scopeAtom',
            'affectedId',p_privacy_request_id
          )
        );
      END IF;
    END LOOP;
  END LOOP;
  v_coverage_payload:=jsonb_build_object(
    'schemaVersion','r6d-privacy-request-legal-hold-coverage.v1',
    'privacyRequestId',p_privacy_request_id,
    'holdProofs',v_hold_proofs,'activeCells',v_active_cells
  );
  v_coverage_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_coverage_payload),'sha256'
  ),'hex');
  RETURN jsonb_build_object(
    'active',jsonb_array_length(v_active_cells)>0,
    'activeCellCount',jsonb_array_length(v_active_cells),
    'coverageDigest',btrim(v_coverage_digest),
    'evaluatedAt',p_at_time,'coverage',v_coverage_payload
  );
END
$r6d_q5_privacy_hold_coverage$;
ALTER FUNCTION ops.r6d_privacy_request_legal_hold_coverage_v1(
  uuid,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_privacy_request_legal_hold_coverage_v1(
  uuid,timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.r6d_privacy_request_legal_hold_coverage_v1(
  uuid,timestamptz
) TO gurine_control_api,gurine_workflow_worker;

-- Runtime event admission does not dereference local JSON-Schema references.
-- Store the same 13-branch legal-hold target union as a fully inlined schema.
INSERT INTO ops.event_types(
  event_type,category,schema_version,active,payload_schema_uri,payload_schema
) VALUES(
  'legal_hold.placed.v2','DOMAIN',2,true,
  'payloads/legal_hold_placed_v2.schema.json',
  $r6d_hold_0040${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/legal_hold.placed.v2.schema.json","$comment":"Runtime admission also requires each concrete object ID to equal targetId. Entity variants require targetId=entityRetentionSnapshotId and targetDigest=entityRetentionSnapshotDigest. CORRECTION and SUBSCRIPTION require targetId to equal their immutable snapshot ID and targetDigest to equal their snapshot digest while preserving the explicit object ID. COMMUNICATION_ENDPOINT requires targetId=communicationEndpointId and binds targetVersion/targetDigest to intake.communication_endpoints(version,endpoint_digest). targetAnchorDigest covers the full selected branch. Draft 2020-12 cannot express cross-property equality, so the DB owner guard enforces it before outbox insertion. AUDIT_SUBJECT_RECORD has no event branch because placement is explicitly unsupported.","type":"object","additionalProperties":false,"required":["legalHoldId","target","scopeAtoms","affectedSetDigest","authorityReferenceDigest","placedByActorId","placedAt","expiresAt","auditReceiptDigest","holdReceiptDigest"],"properties":{"legalHoldId":{"type":"string","format":"uuid"},"target":{"oneOf":[{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","caseId","reviewSnapshotId","reviewSnapshotDigest"],"properties":{"targetKind":{"type":"string","const":"CASE"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"caseId":{"type":"string","format":"uuid"},"reviewSnapshotId":{"type":"string","format":"uuid"},"reviewSnapshotDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}},{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","publicationRevisionId"],"properties":{"targetKind":{"type":"string","const":"PUBLICATION"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"publicationRevisionId":{"type":"string","format":"uuid"}}},{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","evidenceId"],"properties":{"targetKind":{"type":"string","const":"EVIDENCE"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"evidenceId":{"type":"string","format":"uuid"}}},{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","responseId"],"properties":{"targetKind":{"type":"string","const":"RESPONSE"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"responseId":{"type":"string","format":"uuid"}}},{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","sourceDocumentId","sourceAssetId"],"properties":{"targetKind":{"type":"string","const":"SOURCE_ASSET"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"sourceDocumentId":{"type":"string","format":"uuid"},"sourceAssetId":{"type":"string","format":"uuid"}}},{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","researchArtifactId","researchAssetId"],"properties":{"targetKind":{"type":"string","const":"RESEARCH_ARTIFACT"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"researchArtifactId":{"type":"string","format":"uuid"},"researchAssetId":{"type":"string","format":"uuid"}}},{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","privacyRequestId","privacyRequestType"],"properties":{"targetKind":{"type":"string","const":"PRIVACY_REQUEST"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"privacyRequestId":{"type":"string","format":"uuid"},"privacyRequestType":{"type":"string","enum":["ACCESS","CORRECTION","DELETION","RESTRICTION"]}}},{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","communicationSubjectId","communicationSubjectOriginDigest"],"properties":{"targetKind":{"type":"string","const":"COMMUNICATION_SUBJECT"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"communicationSubjectId":{"type":"string","format":"uuid"},"communicationSubjectOriginDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}},{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","entityKind","entityRetentionSnapshotId","entityRetentionSnapshotDigest"],"properties":{"targetKind":{"type":"string","const":"SUPPLIER_RETENTION_SNAPSHOT"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"entityKind":{"type":"string","const":"SUPPLIER"},"entityRetentionSnapshotId":{"type":"string","format":"uuid"},"entityRetentionSnapshotDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}},{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","entityKind","entityRetentionSnapshotId","entityRetentionSnapshotDigest"],"properties":{"targetKind":{"type":"string","const":"AGENCY_RETENTION_SNAPSHOT"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"entityKind":{"type":"string","const":"AGENCY"},"entityRetentionSnapshotId":{"type":"string","format":"uuid"},"entityRetentionSnapshotDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}},{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","correctionId","correctionSnapshotId","correctionSnapshotDigest"],"properties":{"targetKind":{"type":"string","const":"CORRECTION"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"correctionId":{"type":"string","format":"uuid"},"correctionSnapshotId":{"type":"string","format":"uuid"},"correctionSnapshotDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}},{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","subscriptionId","subscriptionSnapshotId","subscriptionSnapshotDigest"],"properties":{"targetKind":{"type":"string","const":"SUBSCRIPTION"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"subscriptionId":{"type":"string","format":"uuid"},"subscriptionSnapshotId":{"type":"string","format":"uuid"},"subscriptionSnapshotDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}},{"type":"object","additionalProperties":false,"required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","communicationEndpointId"],"properties":{"targetKind":{"type":"string","const":"COMMUNICATION_ENDPOINT"},"targetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"communicationEndpointId":{"type":"string","format":"uuid"}}}]},"scopeAtoms":{"type":"array","minItems":1,"maxItems":3,"uniqueItems":true,"items":{"type":"string","enum":["RETENTION","DELETION","DISCLOSURE"]}},"affectedSetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"authorityReferenceDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"placedByActorId":{"type":"string","format":"uuid"},"placedAt":{"type":"string","format":"date-time"},"expiresAt":{"oneOf":[{"type":"string","format":"date-time"},{"type":"null"}]},"auditReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"holdReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}}$r6d_hold_0040$::jsonb
)
ON CONFLICT(event_type) DO UPDATE SET
  category=EXCLUDED.category,
  schema_version=EXCLUDED.schema_version,
  active=EXCLUDED.active,
  payload_schema_uri=EXCLUDED.payload_schema_uri,
  payload_schema=EXCLUDED.payload_schema;

-- Q4 fail-closed correction boundary.  The supervisor-approved exact catalog
-- of target object/field-path pairs is empty until an ACCESS read-model source
-- and a domain COMPLETE owner are bound to the same physical value.  Preserve
-- 0039 for provenance only; neither direct SQL nor the command dispatcher may
-- create a speculative plan.
ALTER FUNCTION ops.create_privacy_correction_plan_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) RENAME TO create_privacy_correction_plan_v1_pre_r6d_q4_unsupported;
REVOKE ALL ON FUNCTION
  ops.create_privacy_correction_plan_v1_pre_r6d_q4_unsupported(
    jsonb,uuid,uuid,uuid,char(64),char(64)
  ) FROM PUBLIC,gurine_control_api;

CREATE OR REPLACE FUNCTION ops.create_privacy_correction_plan_v1(
  p_payload jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_sha256 char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $r6d_q4_unsupported_owner$
BEGIN
  RAISE EXCEPTION 'PRIVACY_CORRECTION_TARGET_UNSUPPORTED'
    USING ERRCODE='0A000';
END
$r6d_q4_unsupported_owner$;
ALTER FUNCTION ops.create_privacy_correction_plan_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.create_privacy_correction_plan_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC,gurine_control_api;

ALTER FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) RENAME TO apply_control_addendum_command_pre_r6d_q4_unsupported;
REVOKE ALL ON FUNCTION
  ops.apply_control_addendum_command_pre_r6d_q4_unsupported(
    text,jsonb,uuid,uuid,uuid,char(64),char(64)
  ) FROM PUBLIC,gurine_control_api;

CREATE OR REPLACE FUNCTION ops.apply_control_addendum_command(
  p_operation_id text,
  p_payload jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key_hash char(64),
  p_request_digest char(64)
) RETURNS TABLE(
  aggregate_id uuid,
  aggregate_version bigint,
  status text,
  accepted_at timestamptz,
  response_body jsonb,
  receipt_digest char(64),
  audit_event_id uuid,
  outbox_event_id uuid
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $r6d_q4_unsupported_dispatcher$
BEGIN
  IF p_operation_id='createPrivacyCorrectionPlan' THEN
    RAISE EXCEPTION 'PRIVACY_CORRECTION_TARGET_UNSUPPORTED'
      USING ERRCODE='0A000';
  END IF;
  RETURN QUERY
  SELECT * FROM ops.apply_control_addendum_command_pre_r6d_q4_unsupported(
    p_operation_id,p_payload,p_actor_id,p_session_id,p_request_id,
    p_idempotency_key_hash,p_request_digest
  );
END
$r6d_q4_unsupported_dispatcher$;
ALTER FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- Q1 forward correction: entity personhood and material-use closure are
-- privacy-governance decisions.  Their unchanged STEP_UP, request binding,
-- human authority and immutable-receipt flows therefore require users.manage,
-- never the unrelated source-operations capability.
CREATE OR REPLACE FUNCTION ops.r6d_entity_human_step_up_authority_v1(
  p_request jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64),
  p_at_time timestamptz
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_scope text;
  v_idempotency ops.idempotency_keys%ROWTYPE;
  v_actor ops.users%ROWTYPE;
  v_session ops.sessions%ROWTYPE;
  v_assertion ops.assertion_replay_guard%ROWTYPE;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_actor_assertion_jti uuid;
  v_actor_assertion_request_digest char(64);
  v_action_digest char(64);
  v_step_up_id uuid;
  v_step_up_payload jsonb;
  v_step_up_digest char(64);
  v_authority_count bigint;
  v_authorities jsonb;
  v_authority_digest char(64);
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request)<>'object'
     OR p_actor_id IS NULL OR p_session_id IS NULL OR p_request_id IS NULL
     OR p_at_time IS NULL
     OR p_request->>'_actorAssuranceLevel'<>'STEP_UP'
     OR p_request->>'_actorEffectiveCapability'<>'users.manage'
     OR NOT COALESCE(ops.r6d_lower_sha256(
       p_request->>'_actorActionDigest'
     ),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(
       p_request->>'_actorIdempotencyKeySha256'
     ),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(
       p_request->>'_actorRequestKeySha256'
     ),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(
       p_request->>'_actorAssertionRequestSha256'
     ),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(p_idempotency_key),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(p_request_digest),false)
     OR p_request->>'_actorIdempotencyKeySha256'<>
        btrim(p_idempotency_key)
     OR p_request->>'_actorRequestKeySha256'<>
        btrim(p_idempotency_key) THEN
    RAISE EXCEPTION 'r6d_entity_actor_binding_invalid'
      USING ERRCODE='23514';
  END IF;
  v_actor_assertion_jti:=(p_request->>'_actorAssertionJti')::uuid;
  v_action_digest:=(p_request->>'_actorActionDigest')::char(64);
  v_step_up_id:=(p_request->>'_actorStepUpAuthorizationId')::uuid;
  IF v_actor_assertion_jti IS NULL OR v_step_up_id IS NULL THEN
    RAISE EXCEPTION 'r6d_entity_actor_binding_invalid'
      USING ERRCODE='23514';
  END IF;

  v_scope:='control:'||p_actor_id::text||':'||CASE
    WHEN p_request ? 'classification' THEN 'classifyEntityPersonhood'
    ELSE 'attestEntityMaterialUseClosure'
  END;
  SELECT * INTO v_idempotency
  FROM ops.idempotency_keys
  WHERE scope=v_scope AND key_hash=p_idempotency_key
  FOR UPDATE;
  IF NOT FOUND OR v_idempotency.expires_at<=p_at_time
     OR v_idempotency.request_hash<>p_request_digest
     OR num_nonnulls(
       v_idempotency.response_status,v_idempotency.response_body,
       v_idempotency.resource_type,v_idempotency.resource_id
     )<>0 THEN
    RAISE EXCEPTION 'r6d_entity_idempotency_preclaim_invalid'
      USING ERRCODE='40001';
  END IF;

  SELECT * INTO v_assertion FROM ops.assertion_replay_guard
  WHERE assertion_type='ACTOR' AND jti=v_actor_assertion_jti;
  IF NOT FOUND OR v_assertion.issuer<>'identity-api'
     OR v_assertion.audience<>'control-api'
     OR v_assertion.expires_at<=p_at_time
     OR v_assertion.consumed_at>p_at_time
     OR btrim(v_assertion.request_digest)<>
        p_request->>'_actorAssertionRequestSha256'
     OR NOT COALESCE(ops.r6d_lower_sha256(
       v_assertion.request_digest
     ),false) THEN
    RAISE EXCEPTION 'r6d_entity_actor_assertion_invalid'
      USING ERRCODE='23514';
  END IF;
  v_actor_assertion_request_digest:=v_assertion.request_digest;

  SELECT * INTO v_actor FROM ops.users WHERE id=p_actor_id FOR SHARE;
  SELECT * INTO v_session FROM ops.sessions WHERE id=p_session_id FOR SHARE;
  SELECT * INTO v_step_up FROM ops.step_up_authorizations
  WHERE id=v_step_up_id FOR SHARE;
  IF v_actor.id IS NULL OR v_actor.status<>'ACTIVE'
     OR v_session.id IS NULL OR v_session.user_id<>p_actor_id
     OR v_session.revoked_at IS NOT NULL OR v_session.expires_at<=p_at_time
     OR v_step_up.id IS NULL OR v_step_up.session_id<>p_session_id
     OR v_step_up.closed_at IS NOT NULL OR v_step_up.expires_at<=p_at_time
     OR v_step_up.action_digest<>v_action_digest
     OR v_step_up.idempotency_key_sha256<>p_idempotency_key
     OR v_step_up.assertion_issue_count NOT BETWEEN 1 AND 3
     OR v_step_up.assertion_issue_count>v_step_up.max_assertion_issues
     OR v_step_up.last_issued_at IS NULL
     OR v_step_up.last_issued_at>p_at_time
     OR v_step_up.last_issued_at>=v_step_up.expires_at
     OR v_step_up.expires_at>
        v_step_up.last_issued_at+interval '5 minutes 5 seconds' THEN
    RAISE EXCEPTION 'r6d_entity_step_up_invalid' USING ERRCODE='23514';
  END IF;

  SELECT count(*),COALESCE(jsonb_agg(jsonb_build_object(
      'grantId',user_role.id,
      'grantVersion',user_role.version,
      'grantedAt',user_role.granted_at,
      'expiresAt',user_role.expires_at,
      'roleId',role.id,'roleCode',role.code,'roleVersion',role.version,
      'capabilityCode',role_capability.capability_code
    ) ORDER BY user_role.id),'[]'::jsonb)
  INTO v_authority_count,v_authorities
  FROM ops.user_roles AS user_role
  JOIN ops.roles AS role ON role.id=user_role.role_id
  JOIN ops.role_capabilities AS role_capability
    ON role_capability.role_id=role.id
   AND role_capability.capability_code='users.manage'
  WHERE user_role.user_id=p_actor_id
    AND user_role.revoked_at IS NULL
    AND (user_role.expires_at IS NULL OR user_role.expires_at>p_at_time);
  IF v_authority_count<1 THEN
    RAISE EXCEPTION 'r6d_entity_capability_invalid' USING ERRCODE='23514';
  END IF;
  v_authority_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6d-entity-data-review-authority.v1',
      'actorId',p_actor_id,'capability','users.manage',
      'authorities',v_authorities
    )
  ),'sha256'),'hex');
  v_step_up_payload:=jsonb_build_object(
    'schemaVersion','step-up-authorization-receipt.v1',
    'authorizationId',v_step_up.id,
    'actionDigest',btrim(v_step_up.action_digest),
    'sessionId',v_step_up.session_id,
    'issueNumber',v_step_up.assertion_issue_count,
    'issuedAt',v_step_up.last_issued_at,
    'expiresAt',v_step_up.expires_at
  );
  v_step_up_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_step_up_payload),'sha256'
  ),'hex');
  RETURN jsonb_build_object(
    'actorAssertionJti',v_actor_assertion_jti,
    'actorAssertionRequestDigest',btrim(v_actor_assertion_request_digest),
    'actionDigest',btrim(v_action_digest),
    'stepUpAuthorizationId',v_step_up.id,
    'stepUpReceiptDigest',btrim(v_step_up_digest),
    'capabilityAuthorityDigest',btrim(v_authority_digest)
  );
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'r6d_entity_actor_binding_invalid'
      USING ERRCODE='23514';
END
$$;
ALTER FUNCTION ops.r6d_entity_human_step_up_authority_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64),timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_entity_human_step_up_authority_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64),timestamptz
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.classify_r6d_entity_personhood_v1(
  p_request jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,core,extensions,pg_temp
AS $$
DECLARE
  v_existing ops.r6d_entity_personhood_classification_receipts_v1%ROWTYPE;
  v_receipt_id uuid:=gen_random_uuid();
  v_entity_kind text;
  v_entity_id uuid;
  v_classification text;
  v_evidence_locator text;
  v_evidence_digest char(64);
  v_expected_updated_at timestamptz;
  v_reason text;
  v_reason_digest char(64);
  v_actor_assertion_jti uuid;
  v_step_up_id uuid;
  v_authority jsonb;
  v_audit uuid;
  v_outbox uuid;
  v_payload jsonb;
  v_canonical bytea;
  v_receipt_digest char(64);
  v_state text;
  v_rows bigint;
  v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_request))<>14
     OR NOT p_request ?& ARRAY[
       'entityKind','entityId','classification','evidenceSourceLocator',
       'reason','expectedEntityUpdatedAt','_actorAssertionJti',
       '_actorAssuranceLevel','_actorEffectiveCapability',
       '_actorActionDigest','_actorStepUpAuthorizationId',
       '_actorIdempotencyKeySha256','_actorRequestKeySha256',
       '_actorAssertionRequestSha256'
     ] THEN
    RAISE EXCEPTION 'r6d_entity_personhood_request_invalid'
      USING ERRCODE='22023';
  END IF;
  v_entity_kind:=p_request->>'entityKind';
  v_entity_id:=(p_request->>'entityId')::uuid;
  v_classification:=p_request->>'classification';
  v_evidence_locator:=p_request->>'evidenceSourceLocator';
  v_expected_updated_at:=(p_request->>'expectedEntityUpdatedAt')::timestamptz;
  v_reason:=p_request->>'reason';
  v_evidence_digest:=encode(extensions.digest(
    convert_to(v_evidence_locator,'UTF8'),'sha256'
  ),'hex');
  v_reason_digest:=encode(extensions.digest(
    convert_to(v_reason,'UTF8'),'sha256'
  ),'hex');
  v_actor_assertion_jti:=(p_request->>'_actorAssertionJti')::uuid;
  v_step_up_id:=(p_request->>'_actorStepUpAuthorizationId')::uuid;
  IF v_entity_kind NOT IN ('AGENCY','SUPPLIER')
     OR v_entity_id IS NULL
     OR v_classification NOT IN ('NATURAL_PERSON','NOT_NATURAL_PERSON')
     OR length(btrim(v_evidence_locator)) NOT BETWEEN 1 AND 2000
     OR btrim(v_evidence_locator)<>v_evidence_locator
     OR v_expected_updated_at IS NULL
     OR length(btrim(v_reason)) NOT BETWEEN 1 AND 4000
     OR btrim(v_reason)<>v_reason
     OR p_actor_id IS NULL OR p_session_id IS NULL OR p_request_id IS NULL
     OR p_request->>'_actorAssuranceLevel'<>'STEP_UP'
     OR p_request->>'_actorEffectiveCapability'<>'users.manage'
     OR NOT COALESCE(ops.r6d_lower_sha256(
       p_request->>'_actorActionDigest'
     ),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(
       p_request->>'_actorAssertionRequestSha256'
     ),false)
     OR p_request->>'_actorIdempotencyKeySha256'<>
        btrim(p_idempotency_key)
     OR p_request->>'_actorRequestKeySha256'<>
        btrim(p_idempotency_key)
     OR NOT COALESCE(ops.r6d_lower_sha256(p_idempotency_key),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(p_request_digest),false) THEN
    RAISE EXCEPTION 'r6d_entity_personhood_request_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing
  FROM ops.r6d_entity_personhood_classification_receipts_v1
  WHERE idempotency_key_sha256=p_idempotency_key FOR SHARE;
  IF FOUND THEN
    -- HTTP replay is resolved from the preclaimed ops.idempotency_keys row
    -- before this owner is invoked.  A receipt visible here is therefore a
    -- direct-SQL or transaction-order conflict, never replay authority.
    RAISE EXCEPTION 'r6d_entity_personhood_owner_reentry'
      USING ERRCODE='40001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_entity_id::text,13));
  IF v_entity_kind='AGENCY' THEN
    PERFORM id FROM core.agencies
    WHERE id=v_entity_id AND r6d_anonymization_state='STAGED_LEGACY'
      AND r6d_personhood_receipt_id IS NULL
      AND updated_at=v_expected_updated_at FOR UPDATE;
  ELSE
    PERFORM id FROM core.suppliers
    WHERE id=v_entity_id AND r6d_anonymization_state='STAGED_LEGACY'
      AND r6d_personhood_receipt_id IS NULL
      AND updated_at=v_expected_updated_at FOR UPDATE;
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'r6d_entity_personhood_subject_not_staged'
      USING ERRCODE='40001';
  END IF;
  IF EXISTS(
    SELECT 1
    FROM ops.r6d_entity_personhood_classification_receipts_v1 AS receipt
    WHERE receipt.entity_kind=v_entity_kind AND receipt.entity_id=v_entity_id
  ) THEN
    RAISE EXCEPTION 'r6d_entity_personhood_already_classified'
      USING ERRCODE='40001';
  END IF;

  v_authority:=ops.r6d_entity_human_step_up_authority_v1(
    p_request,p_actor_id,p_session_id,p_request_id,p_idempotency_key,
    p_request_digest,v_now
  );
  v_audit:=ops.append_audit_event(
    'r6d-entity-personhood:'||lower(v_entity_kind)||':'||v_entity_id::text,
    'USER',p_actor_id::text,p_session_id,
    'r6d.entity_personhood.classify','Entity',v_entity_id::text,
    'users.manage','SUCCESS',NULL,p_request_id,
    jsonb_build_object(
      'entityKind',v_entity_kind,'classification',v_classification,
      'evidenceSourceLocatorDigest',btrim(v_evidence_digest),
      'reasonDigest',btrim(v_reason_digest),
      'capabilityAuthorityDigest',
        v_authority->>'capabilityAuthorityDigest'
    )
  );
  v_payload:=jsonb_build_object(
    'schemaVersion','r6d-entity-personhood-classification-receipt.v1',
    'receiptId',v_receipt_id,'entityKind',v_entity_kind,
    'entityId',v_entity_id,'classification',v_classification,
    'classificationVersion',1,
    'entityUpdatedAt',v_expected_updated_at,
    'evidenceSourceLocatorDigest',btrim(v_evidence_digest),
    'reasonDigest',btrim(v_reason_digest),
    'capabilityAuthorityDigest',v_authority->>'capabilityAuthorityDigest',
    'actorId',p_actor_id,'sessionId',p_session_id,
    'actorAssertionJti',(v_authority->>'actorAssertionJti')::uuid,
    'actorAssertionRequestDigest',
      v_authority->>'actorAssertionRequestDigest',
    'stepUpAuthorizationId',
      (v_authority->>'stepUpAuthorizationId')::uuid,
    'stepUpReceiptDigest',v_authority->>'stepUpReceiptDigest',
    'requestId',p_request_id,
    'idempotencyKeySha256',btrim(p_idempotency_key),
    'requestDigest',btrim(p_request_digest),
    'auditEventId',v_audit,'classifiedAt',v_now
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_receipt_digest:=encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_outbox:=ops.enqueue_outbox(
    'entity_personhood_classification',v_receipt_id::text,1,
    'entity.personhood_classified.v1',jsonb_build_object(
      'entityKind',v_entity_kind,'entityId',v_entity_id,
      'classification',v_classification,
      'evidenceSourceLocatorDigest',btrim(v_evidence_digest),
      'receiptDigest',btrim(v_receipt_digest),'classifiedAt',v_now
    ),v_now
  );
  INSERT INTO ops.r6d_entity_personhood_classification_receipts_v1(
    receipt_id,entity_kind,entity_id,classification,classification_version,
    entity_updated_at,evidence_source_locator_digest,reason_digest,
    capability_authority_digest,actor_id,session_id,actor_assertion_jti,
    actor_assertion_request_digest,step_up_authorization_id,
    step_up_receipt_digest,request_id,idempotency_key_sha256,request_digest,
    audit_event_id,outbox_event_id,receipt_payload,receipt_canonical,receipt_digest,
    classified_at
  ) VALUES(
    v_receipt_id,v_entity_kind,v_entity_id,v_classification,1,
    v_expected_updated_at,v_evidence_digest,v_reason_digest,
    (v_authority->>'capabilityAuthorityDigest')::char(64),
    p_actor_id,p_session_id,(v_authority->>'actorAssertionJti')::uuid,
    (v_authority->>'actorAssertionRequestDigest')::char(64),
    (v_authority->>'stepUpAuthorizationId')::uuid,
    (v_authority->>'stepUpReceiptDigest')::char(64),p_request_id,
    p_idempotency_key,p_request_digest,v_audit,v_outbox,v_payload,v_canonical,
    v_receipt_digest,v_now
  );

  v_state:=CASE v_classification
    WHEN 'NATURAL_PERSON' THEN 'NATURAL_PERSON_ACTIVE'
    ELSE 'NOT_NATURAL_PERSON' END;
  PERFORM set_config('gurine.r6d_entity_classification','1',true);
  IF v_entity_kind='AGENCY' THEN
    UPDATE core.agencies
    SET r6d_canonical_name_digest=encode(extensions.digest(
          convert_to(canonical_name,'UTF8'),'sha256'),'hex'),
        r6d_jurisdiction_digest=CASE WHEN jurisdiction IS NULL THEN NULL
          ELSE encode(extensions.digest(
            convert_to(jurisdiction,'UTF8'),'sha256'),'hex') END,
        r6d_anonymization_state=v_state,
        r6d_personhood_receipt_id=v_receipt_id,
        r6d_personhood_receipt_digest=v_receipt_digest
    WHERE id=v_entity_id AND r6d_anonymization_state='STAGED_LEGACY';
    GET DIAGNOSTICS v_rows=ROW_COUNT;
    UPDATE core.agency_identifiers
    SET r6d_value_digest=encode(extensions.digest(
          convert_to(value,'UTF8'),'sha256'),'hex'),
        r6d_anonymization_state=v_state
    WHERE agency_id=v_entity_id
      AND r6d_anonymization_state='STAGED_LEGACY';
  ELSE
    UPDATE core.suppliers
    SET r6d_canonical_name_digest=encode(extensions.digest(
          convert_to(canonical_name,'UTF8'),'sha256'),'hex'),
        r6d_anonymization_state=v_state,
        r6d_personhood_receipt_id=v_receipt_id,
        r6d_personhood_receipt_digest=v_receipt_digest
    WHERE id=v_entity_id AND r6d_anonymization_state='STAGED_LEGACY';
    GET DIAGNOSTICS v_rows=ROW_COUNT;
    UPDATE core.supplier_identifiers
    SET r6d_display_value_digest=CASE WHEN display_value IS NULL THEN NULL
          ELSE encode(extensions.digest(
            convert_to(display_value,'UTF8'),'sha256'),'hex') END,
        r6d_anonymization_state=v_state
    WHERE supplier_id=v_entity_id
      AND r6d_anonymization_state='STAGED_LEGACY';
  END IF;
  IF v_rows<>1 THEN
    RAISE EXCEPTION 'r6d_entity_personhood_subject_fence_failed'
      USING ERRCODE='40001';
  END IF;
  UPDATE core.entity_aliases
  SET r6d_alias_digest=encode(extensions.digest(
        convert_to(alias,'UTF8'),'sha256'),'hex'),
      r6d_normalized_alias_digest=encode(extensions.digest(
        convert_to(normalized_alias,'UTF8'),'sha256'),'hex'),
      r6d_anonymization_state=v_state
  WHERE entity_type=v_entity_kind AND entity_id=v_entity_id
    AND r6d_anonymization_state='STAGED_LEGACY';

  RETURN jsonb_build_object(
    'receiptId',v_receipt_id,'entityKind',v_entity_kind,
    'entityId',v_entity_id,'classification',v_classification,
    'receiptDigest',btrim(v_receipt_digest),
    'auditEventId',v_audit,'classifiedAt',v_now,
    'outboxEventIds',jsonb_build_array(v_outbox),'replayed',false
  );
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'r6d_entity_personhood_request_invalid'
      USING ERRCODE='22023';
END
$$;
ALTER FUNCTION ops.classify_r6d_entity_personhood_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.classify_r6d_entity_personhood_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.classify_r6d_entity_personhood_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;
CREATE OR REPLACE FUNCTION ops.attest_r6d_entity_material_use_closure_v1(
  p_request jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,core,editorial,extensions,pg_temp
AS $r6d_entity_closure$
DECLARE
  v_existing ops.r6d_entity_material_use_closure_receipts_v1%ROWTYPE;
  v_personhood ops.r6d_entity_personhood_classification_receipts_v1%ROWTYPE;
  v_receipt_id uuid:=gen_random_uuid();
  v_entity_kind text;
  v_entity_id uuid;
  v_personhood_id uuid;
  v_personhood_digest char(64);
  v_expected_updated_at timestamptz;
  v_reason text;
  v_reason_digest char(64);
  v_actor_assertion_jti uuid;
  v_step_up_id uuid;
  v_authority jsonb;
  v_material jsonb;
  v_audit uuid;
  v_outbox uuid;
  v_payload jsonb;
  v_canonical bytea;
  v_receipt_digest char(64);
  v_rows bigint;
  v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_request))<>13
     OR NOT p_request ?& ARRAY[
       'entityKind','entityId','personhoodReceiptId','reason',
       'expectedEntityUpdatedAt','_actorAssertionJti',
       '_actorAssuranceLevel','_actorEffectiveCapability',
       '_actorActionDigest','_actorStepUpAuthorizationId',
       '_actorIdempotencyKeySha256','_actorRequestKeySha256',
       '_actorAssertionRequestSha256'
     ] THEN
    RAISE EXCEPTION 'r6d_entity_closure_request_invalid'
      USING ERRCODE='22023';
  END IF;
  v_entity_kind:=p_request->>'entityKind';
  v_entity_id:=(p_request->>'entityId')::uuid;
  v_personhood_id:=(p_request->>'personhoodReceiptId')::uuid;
  v_expected_updated_at:=(p_request->>'expectedEntityUpdatedAt')::timestamptz;
  v_reason:=p_request->>'reason';
  v_actor_assertion_jti:=(p_request->>'_actorAssertionJti')::uuid;
  v_step_up_id:=(p_request->>'_actorStepUpAuthorizationId')::uuid;
  IF v_entity_kind NOT IN ('AGENCY','SUPPLIER')
     OR v_entity_id IS NULL OR v_personhood_id IS NULL
     OR v_expected_updated_at IS NULL
     OR length(btrim(v_reason)) NOT BETWEEN 1 AND 4000
     OR btrim(v_reason)<>v_reason
     OR p_actor_id IS NULL OR p_session_id IS NULL OR p_request_id IS NULL
     OR p_request->>'_actorAssuranceLevel'<>'STEP_UP'
     OR p_request->>'_actorEffectiveCapability'<>'users.manage'
     OR NOT COALESCE(ops.r6d_lower_sha256(
       p_request->>'_actorActionDigest'
     ),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(
       p_request->>'_actorAssertionRequestSha256'
     ),false)
     OR p_request->>'_actorIdempotencyKeySha256'<>
        btrim(p_idempotency_key)
     OR p_request->>'_actorRequestKeySha256'<>
        btrim(p_idempotency_key)
     OR NOT COALESCE(ops.r6d_lower_sha256(p_idempotency_key),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(p_request_digest),false) THEN
    RAISE EXCEPTION 'r6d_entity_closure_request_invalid'
      USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_existing
  FROM ops.r6d_entity_material_use_closure_receipts_v1
  WHERE idempotency_key_sha256=p_idempotency_key FOR SHARE;
  IF FOUND THEN
    RAISE EXCEPTION 'r6d_entity_closure_owner_reentry'
      USING ERRCODE='40001';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_entity_id::text,13));
  IF v_entity_kind='AGENCY' THEN
    PERFORM id FROM core.agencies
    WHERE id=v_entity_id
      AND updated_at=v_expected_updated_at
      AND r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
      AND r6d_personhood_receipt_id=v_personhood_id
      AND r6d_closure_receipt_id IS NULL
    FOR UPDATE;
  ELSE
    PERFORM id FROM core.suppliers
    WHERE id=v_entity_id
      AND updated_at=v_expected_updated_at
      AND r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
      AND r6d_personhood_receipt_id=v_personhood_id
      AND r6d_closure_receipt_id IS NULL
    FOR UPDATE;
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'r6d_entity_closure_subject_not_active'
      USING ERRCODE='40001';
  END IF;

  SELECT * INTO v_personhood
  FROM ops.r6d_entity_personhood_classification_receipts_v1
  WHERE receipt_id=v_personhood_id FOR SHARE;
  IF NOT FOUND OR v_personhood.entity_kind<>v_entity_kind
     OR v_personhood.entity_id<>v_entity_id
     OR v_personhood.classification<>'NATURAL_PERSON' THEN
    RAISE EXCEPTION 'r6d_entity_closure_personhood_invalid'
      USING ERRCODE='55000';
  END IF;
  IF v_personhood.actor_id=p_actor_id THEN
    RAISE EXCEPTION 'r6d_entity_closure_actor_not_independent'
      USING ERRCODE='55000';
  END IF;
  v_personhood_digest:=v_personhood.receipt_digest;
  IF v_entity_kind='AGENCY' THEN
    PERFORM id FROM core.agencies
    WHERE id=v_entity_id
      AND r6d_personhood_receipt_digest=v_personhood_digest;
  ELSE
    PERFORM id FROM core.suppliers
    WHERE id=v_entity_id
      AND r6d_personhood_receipt_digest=v_personhood_digest;
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'r6d_entity_closure_personhood_pointer_invalid'
      USING ERRCODE='55000';
  END IF;
  IF EXISTS(
    SELECT 1 FROM ops.r6d_entity_material_use_closure_receipts_v1 AS prior
    WHERE prior.entity_kind=v_entity_kind AND prior.entity_id=v_entity_id
  ) THEN
    RAISE EXCEPTION 'r6d_entity_closure_already_attested'
      USING ERRCODE='40001';
  END IF;

  v_material:=ops.r6d_entity_material_use_state_v1(
    v_entity_kind,v_entity_id,v_now
  );
  IF (v_material->>'finalContractBoundaryAt') IS NOT NULL
     AND (v_material->>'finalContractBoundaryAt')::timestamptz>v_now THEN
    RAISE EXCEPTION 'r6d_entity_closure_contract_still_material'
      USING ERRCODE='55000';
  END IF;
  IF (v_material->>'openPublicationRevisionCount')::bigint<>0 THEN
    RAISE EXCEPTION 'r6d_entity_closure_publication_still_material'
      USING ERRCODE='55000';
  END IF;
  IF (v_material->>'legalHoldActive')::boolean
     OR (v_material->>'legalHoldActiveCellCount')::bigint<>0 THEN
    RAISE EXCEPTION 'r6d_entity_closure_legal_hold_active'
      USING ERRCODE='55000';
  END IF;

  v_authority:=ops.r6d_entity_human_step_up_authority_v1(
    p_request,p_actor_id,p_session_id,p_request_id,p_idempotency_key,
    p_request_digest,v_now
  );
  v_reason_digest:=encode(extensions.digest(
    convert_to(v_reason,'UTF8'),'sha256'
  ),'hex');
  v_audit:=ops.append_audit_event(
    'r6d-entity-material-closure:'||lower(v_entity_kind)||':'||v_entity_id::text,
    'USER',p_actor_id::text,p_session_id,
    'r6d.entity_material_use.attest_closure','Entity',v_entity_id::text,
    'users.manage','SUCCESS',NULL,p_request_id,
    jsonb_build_object(
      'entityKind',v_entity_kind,
      'personhoodReceiptDigest',btrim(v_personhood_digest),
      'contractSetDigest',v_material->>'contractSetDigest',
      'publicationRevisionSetDigest',
        v_material->>'publicationRevisionSetDigest',
      'legalHoldCoverageDigest',v_material->>'legalHoldCoverageDigest',
      'reasonDigest',btrim(v_reason_digest),
      'capabilityAuthorityDigest',
        v_authority->>'capabilityAuthorityDigest'
    )
  );
  v_payload:=jsonb_build_object(
    'schemaVersion','r6d-entity-material-use-closure-receipt.v1',
    'receiptId',v_receipt_id,'entityKind',v_entity_kind,
    'entityId',v_entity_id,'closureVersion',1,
    'entityUpdatedAt',v_expected_updated_at,
    'personhoodReceiptId',v_personhood_id,
    'personhoodReceiptDigest',btrim(v_personhood_digest),
    'contractCount',(v_material->>'contractCount')::bigint,
    'contractSetDigest',v_material->>'contractSetDigest',
    'finalContractEndAt',v_material->'finalContractEndAt',
    'finalContractBoundaryAt',v_material->'finalContractBoundaryAt',
    'publicationRevisionCount',
      (v_material->>'publicationRevisionCount')::bigint,
    'publicationRevisionSetDigest',
      v_material->>'publicationRevisionSetDigest',
    'openPublicationRevisionCount',
      (v_material->>'openPublicationRevisionCount')::bigint,
    'legalHoldCoverageDigest',v_material->>'legalHoldCoverageDigest',
    'reasonDigest',btrim(v_reason_digest),
    'capabilityAuthorityDigest',v_authority->>'capabilityAuthorityDigest',
    'actorId',p_actor_id,'sessionId',p_session_id,
    'actorAssertionJti',(v_authority->>'actorAssertionJti')::uuid,
    'actorAssertionRequestDigest',
      v_authority->>'actorAssertionRequestDigest',
    'stepUpAuthorizationId',
      (v_authority->>'stepUpAuthorizationId')::uuid,
    'stepUpReceiptDigest',v_authority->>'stepUpReceiptDigest',
    'requestId',p_request_id,
    'idempotencyKeySha256',btrim(p_idempotency_key),
    'requestDigest',btrim(p_request_digest),
    'auditEventId',v_audit,'closureAt',v_now,'attestedAt',v_now
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_receipt_digest:=encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_outbox:=ops.enqueue_outbox(
    'entity_material_use_closure',v_receipt_id::text,1,
    'entity.material_use_closed.v1',jsonb_build_object(
      'entityKind',v_entity_kind,'entityId',v_entity_id,
      'personhoodReceiptDigest',btrim(v_personhood_digest),
      'closureAt',v_now,
      'lastContractEndAt',v_material->'finalContractBoundaryAt',
      'linkedPublicationRevisionCount',
        (v_material->>'publicationRevisionCount')::bigint,
      'receiptDigest',btrim(v_receipt_digest)
    ),v_now
  );
  INSERT INTO ops.r6d_entity_material_use_closure_receipts_v1(
    receipt_id,entity_kind,entity_id,closure_version,entity_updated_at,
    personhood_receipt_id,personhood_receipt_digest,contract_count,
    contract_set_digest,final_contract_end_at,final_contract_boundary_at,
    publication_revision_count,publication_revision_set_digest,
    open_publication_revision_count,legal_hold_coverage_digest,
    reason_digest,capability_authority_digest,actor_id,session_id,
    actor_assertion_jti,actor_assertion_request_digest,
    step_up_authorization_id,step_up_receipt_digest,request_id,
    idempotency_key_sha256,request_digest,audit_event_id,outbox_event_id,
    receipt_payload,receipt_canonical,receipt_digest,closure_at,attested_at
  ) VALUES(
    v_receipt_id,v_entity_kind,v_entity_id,1,v_expected_updated_at,
    v_personhood_id,v_personhood_digest,
    (v_material->>'contractCount')::bigint,
    (v_material->>'contractSetDigest')::char(64),
    (v_material->>'finalContractEndAt')::date,
    (v_material->>'finalContractBoundaryAt')::timestamptz,
    (v_material->>'publicationRevisionCount')::bigint,
    (v_material->>'publicationRevisionSetDigest')::char(64),
    (v_material->>'openPublicationRevisionCount')::bigint,
    (v_material->>'legalHoldCoverageDigest')::char(64),v_reason_digest,
    (v_authority->>'capabilityAuthorityDigest')::char(64),
    p_actor_id,p_session_id,(v_authority->>'actorAssertionJti')::uuid,
    (v_authority->>'actorAssertionRequestDigest')::char(64),
    (v_authority->>'stepUpAuthorizationId')::uuid,
    (v_authority->>'stepUpReceiptDigest')::char(64),p_request_id,
    p_idempotency_key,p_request_digest,v_audit,v_outbox,v_payload,v_canonical,
    v_receipt_digest,v_now,v_now
  );

  PERFORM set_config('gurine.r6d_entity_closure','1',true);
  IF v_entity_kind='AGENCY' THEN
    UPDATE core.agencies
    SET r6d_closure_receipt_id=v_receipt_id,
        r6d_closure_receipt_digest=v_receipt_digest
    WHERE id=v_entity_id
      AND updated_at=v_expected_updated_at
      AND r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
      AND r6d_personhood_receipt_id=v_personhood_id
      AND r6d_personhood_receipt_digest=v_personhood_digest
      AND r6d_closure_receipt_id IS NULL;
  ELSE
    UPDATE core.suppliers
    SET r6d_closure_receipt_id=v_receipt_id,
        r6d_closure_receipt_digest=v_receipt_digest
    WHERE id=v_entity_id
      AND updated_at=v_expected_updated_at
      AND r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
      AND r6d_personhood_receipt_id=v_personhood_id
      AND r6d_personhood_receipt_digest=v_personhood_digest
      AND r6d_closure_receipt_id IS NULL;
  END IF;
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN
    RAISE EXCEPTION 'r6d_entity_closure_subject_fence_failed'
      USING ERRCODE='40001';
  END IF;
  RETURN jsonb_build_object(
    'closureReceiptId',v_receipt_id,'entityKind',v_entity_kind,
    'entityId',v_entity_id,'personhoodReceiptId',v_personhood_id,
    'receiptDigest',btrim(v_receipt_digest),'closureAt',v_now,
    'lastContractEndAt',v_material->'finalContractBoundaryAt',
    'linkedPublicationRevisionCount',
      (v_material->>'publicationRevisionCount')::bigint,
    'auditEventId',v_audit,'attestedAt',v_now,
    'outboxEventIds',jsonb_build_array(v_outbox),'replayed',false
  );
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range
    OR datetime_field_overflow THEN
    RAISE EXCEPTION 'r6d_entity_closure_request_invalid'
      USING ERRCODE='22023';
END
$r6d_entity_closure$;
ALTER FUNCTION ops.attest_r6d_entity_material_use_closure_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.attest_r6d_entity_material_use_closure_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.attest_r6d_entity_material_use_closure_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- Q4 final authority: RESPONSE /partyName is the sole executable privacy
-- correction cell. ACCESS and correction planning consume this same owner.
-- Plaintext exists only in this internal result; durable bindings persist
-- digests and immutable source identifiers only.
CREATE OR REPLACE FUNCTION ops.read_privacy_response_party_name_access_v1(
  p_privacy_request_id uuid,
  p_response_id uuid
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,editorial,extensions,pg_temp
AS $r6d_q4_party_name_access$
DECLARE
  v_as_of timestamptz:=statement_timestamp();
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_inventory ops.privacy_request_scope_inventories_v1%ROWTYPE;
  v_item ops.privacy_request_scope_inventory_items_v1%ROWTYPE;
  v_identity ops.privacy_request_identity_receipts_v2%ROWTYPE;
  v_authority ops.privacy_identity_proof_authority_receipts_v1%ROWTYPE;
  v_submission_receipt intake.response_submission_receipts_v3%ROWTYPE;
  v_submission intake.response_submissions%ROWTYPE;
  v_prior_response_request_scope text;
  v_sent editorial.response_request_sent_receipts%ROWTYPE;
  v_endpoint intake.communication_endpoints%ROWTYPE;
  v_link intake.communication_endpoint_link_events%ROWTYPE;
  v_subject intake.communication_subjects%ROWTYPE;
  v_origin editorial.response_submission_origin_receipts_v2%ROWTYPE;
  v_response editorial.responses%ROWTYPE;
  v_party_name_digest char(64);
  v_projection_preimage jsonb;
  v_projection_digest char(64);
BEGIN
  IF p_privacy_request_id IS NULL OR p_response_id IS NULL
     OR p_privacy_request_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR p_response_id='00000000-0000-0000-0000-000000000000'::uuid THEN
    RAISE EXCEPTION 'privacy_response_party_name_access_input_invalid'
      USING ERRCODE='22023';
  END IF;

  SELECT request.* INTO v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=p_privacy_request_id FOR SHARE;
  IF NOT FOUND OR v_request.request_type NOT IN ('ACCESS','CORRECTION')
     OR v_request.identity_state<>'VERIFIED'
     OR v_request.current_identity_receipt_id IS NULL
     OR v_request.current_identity_receipt_digest IS NULL THEN
    RAISE EXCEPTION 'privacy_response_party_name_access_authority_missing'
      USING ERRCODE='55000';
  END IF;

  SELECT inventory.* INTO v_inventory
  FROM ops.privacy_request_scope_inventories_v1 AS inventory
  WHERE inventory.privacy_request_id=v_request.id;
  SELECT item.* INTO v_item
  FROM ops.privacy_request_scope_inventory_items_v1 AS item
  WHERE item.scope_inventory_id=v_inventory.scope_inventory_id
    AND item.privacy_request_id=v_request.id
    AND item.object_kind='RESPONSE' AND item.object_id=p_response_id;
  IF v_inventory.scope_inventory_id IS NULL OR v_item.object_id IS NULL
     OR v_inventory.scope_kind<>'OBJECT_SET'
     OR v_inventory.include_derivatives OR v_inventory.include_backups
     OR v_inventory.scope_digest<>v_request.scope_sha256
     OR v_inventory.subject_scope_digest<>v_request.subject_scope_digest THEN
    RAISE EXCEPTION 'privacy_response_party_name_access_scope_invalid'
      USING ERRCODE='55000';
  END IF;

  SELECT identity.* INTO v_identity
  FROM ops.privacy_request_identity_receipts_v2 AS identity
  WHERE identity.identity_receipt_id=v_request.current_identity_receipt_id
    AND identity.privacy_request_id=v_request.id
    AND identity.receipt_digest=v_request.current_identity_receipt_digest;
  SELECT authority.* INTO v_authority
  FROM ops.privacy_identity_proof_authority_receipts_v1 AS authority
  WHERE authority.identity_proof_receipt_id=
      v_identity.identity_proof_receipt_id
    AND authority.privacy_request_id=v_request.id
    AND authority.receipt_digest=v_identity.identity_proof_receipt_digest;
  IF v_identity.identity_receipt_id IS NULL
     OR v_authority.identity_proof_receipt_id IS NULL
     OR v_authority.proof_kind<>'RESPONSE_RECEIPT'
     OR v_authority.subject_proof_hash<>v_request.subject_proof_hash
     OR v_authority.exact_scope_digest<>v_request.scope_sha256
     OR v_authority.source_response_receipt_id IS NULL THEN
    RAISE EXCEPTION 'privacy_response_party_name_access_authority_missing'
      USING ERRCODE='55000';
  END IF;

  SELECT receipt.* INTO v_submission_receipt
  FROM intake.response_submission_receipts_v3 AS receipt
  WHERE receipt.receipt_id=v_authority.source_response_receipt_id;
  IF v_submission_receipt.receipt_id IS NULL THEN
    RAISE EXCEPTION 'privacy_response_party_name_access_chain_invalid'
      USING ERRCODE='55000';
  END IF;
  -- response_submissions is RLS-scoped. Resolve its scope only from the
  -- immutable submission receipt, never from a caller-provided GUC, and
  -- restore the prior session value even when the locked read fails.
  v_prior_response_request_scope:=
    current_setting('gurine.response_request_id',true);
  PERFORM set_config(
    'gurine.response_request_id',
    v_submission_receipt.response_request_id::text,true
  );
  BEGIN
    SELECT submission.* INTO v_submission
    FROM intake.response_submissions AS submission
    WHERE submission.id=v_submission_receipt.response_submission_id
      AND submission.response_request_id=
        v_submission_receipt.response_request_id
      AND submission.receipt_version=v_submission_receipt.receipt_version
      AND submission.receipt_digest=v_submission_receipt.receipt_digest
    FOR SHARE;
    PERFORM set_config(
      'gurine.response_request_id',
      COALESCE(v_prior_response_request_scope,''),true
    );
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config(
      'gurine.response_request_id',
      COALESCE(v_prior_response_request_scope,''),true
    );
    RAISE;
  END;
  SELECT sent.* INTO v_sent
  FROM editorial.response_request_sent_receipts AS sent
  WHERE sent.response_request_id=v_submission_receipt.response_request_id;
  SELECT endpoint.* INTO v_endpoint
  FROM intake.communication_endpoints AS endpoint
  WHERE endpoint.id=v_sent.endpoint_id
    AND endpoint.version=v_sent.endpoint_version
    AND endpoint.endpoint_digest=v_sent.endpoint_snapshot_digest
  FOR SHARE;
  SELECT link.* INTO v_link
  FROM intake.communication_endpoint_link_events AS link
  WHERE link.endpoint_id=v_sent.endpoint_id
    AND link.endpoint_version=v_sent.endpoint_version
    AND link.endpoint_snapshot_digest=v_sent.endpoint_snapshot_digest
    AND link.channel=v_sent.channel
    AND link.state='ACTIVE'
    AND NOT EXISTS(
      SELECT 1
      FROM intake.communication_endpoint_link_events AS later
      WHERE later.endpoint_id=link.endpoint_id
        AND later.endpoint_sequence>link.endpoint_sequence
    );
  SELECT subject.* INTO v_subject
  FROM intake.communication_subjects AS subject
  WHERE subject.id=v_link.subject_id
    AND subject.origin_binding_digest=v_link.subject_origin_binding_digest
  FOR SHARE;
  SELECT origin.* INTO v_origin
  FROM editorial.response_submission_origin_receipts_v2 AS origin
  WHERE origin.response_submission_id=
      v_submission_receipt.response_submission_id
    AND origin.response_request_id=v_submission_receipt.response_request_id
    AND origin.submission_receipt_version=
      v_submission_receipt.receipt_version
    AND origin.submission_receipt_digest=v_submission_receipt.receipt_digest
    AND origin.editorial_response_id=p_response_id;
  SELECT response.* INTO v_response
  FROM editorial.responses AS response
  WHERE response.id=p_response_id FOR SHARE;
  IF v_submission_receipt.receipt_id IS NULL OR v_submission.id IS NULL
     OR v_sent.id IS NULL OR v_endpoint.id IS NULL OR v_link.id IS NULL
     OR v_subject.id IS NULL OR v_origin.receipt_id IS NULL
     OR v_response.id IS NULL
     OR v_submission_receipt.response_request_version<>
        v_sent.request_version
     OR v_submission_receipt.response_request_binding_digest<>
        v_sent.response_request_binding_digest
     OR v_endpoint.subject_id<>v_subject.id
     OR v_endpoint.channel<>v_sent.channel
     OR v_endpoint.state<>'ACTIVE' OR v_endpoint.revoked_at IS NOT NULL
     OR v_subject.status<>'ACTIVE' OR v_subject.revoked_at IS NOT NULL
     OR v_authority.source_subject_id<>v_subject.id
     OR v_authority.source_subject_origin_digest<>
        v_subject.origin_binding_digest
     OR v_authority.source_endpoint_id<>v_endpoint.id
     OR v_authority.source_endpoint_version<>v_endpoint.version
     OR v_authority.source_endpoint_digest<>v_endpoint.endpoint_digest
     OR v_submission.editorial_response_id<>v_origin.editorial_response_id
     OR v_submission.owned_intake_event_id<>v_origin.source_event_id
     OR v_submission.owned_intake_event_envelope_digest<>
        v_origin.source_event_envelope_digest
     OR v_submission.owned_intake_receipt_digest<>
        v_origin.owned_intake_receipt_digest
     OR v_response.response_request_id<>v_origin.response_request_id
     OR v_response.submission_id<>v_origin.response_submission_id
     OR v_response.submission_receipt_version<>
        v_origin.submission_receipt_version
     OR v_response.submission_receipt_digest<>
        v_origin.submission_receipt_digest
     OR v_response.owned_intake_receipt_digest<>
        v_origin.owned_intake_receipt_digest
     OR v_response.party_type<>v_origin.party_type
     OR v_response.party_entity_id IS DISTINCT FROM v_origin.party_entity_id
     OR v_response.version<1 OR NULLIF(v_response.party_name,'') IS NULL THEN
    RAISE EXCEPTION 'privacy_response_party_name_access_chain_invalid'
      USING ERRCODE='55000';
  END IF;

  v_party_name_digest:=encode(extensions.digest(
    convert_to(v_response.party_name,'UTF8'),'sha256'
  ),'hex');
  v_projection_preimage:=jsonb_build_object(
    'schemaVersion','privacy-response-party-name-access-preimage.v1',
    'retentionRequestId',v_request.id,
    'targetObjectType','RESPONSE','targetObjectId',v_response.id,
    'fieldPath','/partyName','partyName',v_response.party_name,
    'currentValueDigest',btrim(v_party_name_digest),
    'responseVersion',v_response.version,
    'privacyIdentityProofReceiptId',v_authority.identity_proof_receipt_id,
    'privacyIdentityProofReceiptDigest',btrim(v_authority.receipt_digest),
    'responseSubmissionReceiptId',v_submission_receipt.receipt_id,
    'responseSubmissionReceiptDigest',btrim(v_submission_receipt.receipt_digest),
    'responseOriginReceiptId',v_origin.receipt_id,
    'responseOriginReceiptDigest',btrim(v_origin.owned_intake_receipt_digest),
    'sourceResponseRequestId',v_origin.response_request_id
  );
  v_projection_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_projection_preimage),'sha256'
  ),'hex');
  RETURN jsonb_build_object(
    'schemaVersion','privacy-response-party-name-access.v1',
    'retentionRequestId',v_request.id,
    'targetObjectType','RESPONSE','targetObjectId',v_response.id,
    'fieldPath','/partyName','partyName',v_response.party_name,
    'currentValueDigest',btrim(v_party_name_digest),
    'projectionDigest',btrim(v_projection_digest),
    'responseVersion',v_response.version,
    'privacyIdentityProofReceiptId',v_authority.identity_proof_receipt_id,
    'privacyIdentityProofReceiptDigest',btrim(v_authority.receipt_digest),
    'responseSubmissionReceiptId',v_submission_receipt.receipt_id,
    'responseSubmissionReceiptDigest',btrim(v_submission_receipt.receipt_digest),
    'responseOriginReceiptId',v_origin.receipt_id,
    'responseOriginReceiptDigest',btrim(v_origin.owned_intake_receipt_digest),
    'sourceResponseRequestId',v_origin.response_request_id,'asOf',v_as_of
  );
END
$r6d_q4_party_name_access$;
ALTER FUNCTION ops.read_privacy_response_party_name_access_v1(uuid,uuid)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.read_privacy_response_party_name_access_v1(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  ops.read_privacy_response_party_name_access_v1(uuid,uuid)
  TO gurine_control_api;

CREATE TABLE ops.privacy_response_party_name_correction_plan_bindings_v1 (
  correction_plan_id uuid PRIMARY KEY
    REFERENCES ops.privacy_correction_plans_v1(correction_plan_id)
    ON DELETE RESTRICT,
  privacy_request_id uuid NOT NULL
    REFERENCES ops.privacy_requests_v2(id) ON DELETE RESTRICT,
  plan_version bigint NOT NULL,
  plan_digest char(64) NOT NULL UNIQUE,
  scope_inventory_id uuid NOT NULL
    REFERENCES ops.privacy_request_scope_inventories_v1(scope_inventory_id)
    ON DELETE RESTRICT,
  scope_item_digest char(64) NOT NULL,
  response_id uuid NOT NULL REFERENCES editorial.responses(id)
    ON DELETE RESTRICT,
  expected_response_version bigint NOT NULL,
  expected_current_value_digest char(64) NOT NULL,
  access_projection_digest char(64) NOT NULL,
  privacy_identity_proof_receipt_id uuid NOT NULL,
  privacy_identity_proof_receipt_digest char(64) NOT NULL,
  response_submission_receipt_id uuid NOT NULL
    REFERENCES intake.response_submission_receipts_v3(receipt_id)
    ON DELETE RESTRICT,
  response_submission_receipt_digest char(64) NOT NULL,
  response_origin_receipt_id uuid NOT NULL
    REFERENCES editorial.response_submission_origin_receipts_v2(receipt_id)
    ON DELETE RESTRICT,
  response_origin_receipt_digest char(64) NOT NULL,
  source_response_request_id uuid NOT NULL
    REFERENCES editorial.response_requests(id) ON DELETE RESTRICT,
  binding_payload jsonb NOT NULL,
  binding_canonical bytea NOT NULL,
  binding_digest char(64) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL,
  UNIQUE(privacy_request_id,plan_version),
  UNIQUE(correction_plan_id,binding_digest),
  CONSTRAINT privacy_response_party_name_plan_binding_shape_ck CHECK(
    plan_version>0 AND expected_response_version>0
    AND ops.r6d_lower_sha256(plan_digest)
    AND ops.r6d_lower_sha256(scope_item_digest)
    AND ops.r6d_lower_sha256(expected_current_value_digest)
    AND ops.r6d_lower_sha256(access_projection_digest)
    AND ops.r6d_lower_sha256(privacy_identity_proof_receipt_digest)
    AND ops.r6d_lower_sha256(response_submission_receipt_digest)
    AND ops.r6d_lower_sha256(response_origin_receipt_digest)
    AND convert_from(binding_canonical,'UTF8')::jsonb=binding_payload
    AND binding_canonical=ops.canonical_jsonb_v1(binding_payload)
    AND binding_digest=encode(extensions.digest(binding_canonical,'sha256'),'hex')
    AND binding_payload->>'schemaVersion'=
      'privacy-response-party-name-correction-plan-binding.v1'
    AND binding_payload->>'targetObjectType'='RESPONSE'
    AND binding_payload->>'fieldPath'='/partyName'
    AND NOT binding_payload ?| ARRAY[
      'partyName','requestedValue','plaintext','requestedValueCiphertextBase64'
    ]
  )
);
ALTER TABLE ops.privacy_response_party_name_correction_plan_bindings_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_response_party_name_correction_plan_bindings_v1
  FROM PUBLIC,gurine_control_api,gurine_submission_api,
    gurine_workflow_worker,gurine_notification_worker,gurine_scheduler;
GRANT SELECT ON ops.privacy_response_party_name_correction_plan_bindings_v1
  TO gurine_auditor;
CREATE TRIGGER privacy_response_party_name_plan_bindings_v1_immutable
  BEFORE UPDATE OR DELETE
  ON ops.privacy_response_party_name_correction_plan_bindings_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

-- Replace the temporary deny-all owner with the exact final cell. Every other
-- object/path discriminator is rejected before any owner write. The sealed
-- envelope remains in the established 0039 plan relation; this wrapper adds
-- the immutable source-owned current-value binding.
CREATE OR REPLACE FUNCTION ops.create_privacy_correction_plan_v1(
  p_payload jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_sha256 char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $r6d_q4_create_party_name_plan$
DECLARE
  v_privacy_request_id uuid;
  v_response_id uuid;
  v_projection jsonb;
  v_result jsonb;
  v_plan ops.privacy_correction_plans_v1%ROWTYPE;
  v_binding_payload jsonb;
  v_binding_canonical bytea;
  v_binding_digest char(64);
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR p_payload->>'targetObjectType' IS DISTINCT FROM 'RESPONSE'
     OR p_payload->>'fieldPath' IS DISTINCT FROM '/partyName' THEN
    RAISE EXCEPTION 'PRIVACY_CORRECTION_TARGET_UNSUPPORTED'
      USING ERRCODE='0A000';
  END IF;
  BEGIN
    v_privacy_request_id:=(p_payload->>'retentionRequestId')::uuid;
    v_response_id:=(p_payload->>'targetObjectId')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'privacy_correction_plan_input_invalid'
      USING ERRCODE='22023';
  END;

  v_projection:=ops.read_privacy_response_party_name_access_v1(
    v_privacy_request_id,v_response_id
  );
  IF p_payload->>'currentValueDigest' IS DISTINCT FROM
       v_projection->>'currentValueDigest' THEN
    RAISE EXCEPTION 'PRIVACY_CORRECTION_CURRENT_VALUE_STALE'
      USING ERRCODE='PVT08';
  END IF;

  v_result:=ops.create_privacy_correction_plan_v1_pre_r6d_q4_unsupported(
    p_payload,p_actor_id,p_session_id,p_request_id,
    p_idempotency_key_sha256,p_request_sha256
  );
  SELECT plan.* INTO STRICT v_plan
  FROM ops.privacy_correction_plans_v1 AS plan
  WHERE plan.correction_plan_id=(v_result->>'correctionPlanId')::uuid
    AND plan.privacy_request_id=v_privacy_request_id
    AND plan.target_object_type='RESPONSE'
    AND plan.target_object_id=v_response_id
    AND plan.field_path='/partyName'
    AND plan.current_value_digest=
      (v_projection->>'currentValueDigest')::char(64)
    AND plan.plan_digest=(v_result->>'planDigest')::char(64)
  FOR SHARE;

  v_binding_payload:=jsonb_build_object(
    'schemaVersion',
      'privacy-response-party-name-correction-plan-binding.v1',
    'correctionPlanId',v_plan.correction_plan_id,
    'retentionRequestId',v_plan.privacy_request_id,
    'planVersion',v_plan.plan_version,
    'planDigest',btrim(v_plan.plan_digest),
    'scopeInventoryId',v_plan.scope_inventory_id,
    'scopeItemDigest',btrim(v_plan.scope_item_digest),
    'targetObjectType','RESPONSE','targetObjectId',v_response_id,
    'fieldPath','/partyName',
    'currentValueAuthority',
      'RESPONSE_PARTY_NAME_ACCESS_PROJECTION_V1',
    'expectedResponseVersion',(v_projection->>'responseVersion')::bigint,
    'expectedCurrentValueDigest',v_projection->>'currentValueDigest',
    'accessProjectionDigest',v_projection->>'projectionDigest',
    'privacyIdentityProofReceiptId',
      (v_projection->>'privacyIdentityProofReceiptId')::uuid,
    'privacyIdentityProofReceiptDigest',
      v_projection->>'privacyIdentityProofReceiptDigest',
    'responseSubmissionReceiptId',
      (v_projection->>'responseSubmissionReceiptId')::uuid,
    'responseSubmissionReceiptDigest',
      v_projection->>'responseSubmissionReceiptDigest',
    'responseOriginReceiptId',
      (v_projection->>'responseOriginReceiptId')::uuid,
    'responseOriginReceiptDigest',
      v_projection->>'responseOriginReceiptDigest',
    'sourceResponseRequestId',
      (v_projection->>'sourceResponseRequestId')::uuid,
    'createdAt',v_plan.created_at
  );
  v_binding_canonical:=ops.canonical_jsonb_v1(v_binding_payload);
  v_binding_digest:=encode(extensions.digest(
    v_binding_canonical,'sha256'
  ),'hex');
  INSERT INTO ops.privacy_response_party_name_correction_plan_bindings_v1(
    correction_plan_id,privacy_request_id,plan_version,plan_digest,
    scope_inventory_id,scope_item_digest,response_id,
    expected_response_version,expected_current_value_digest,
    access_projection_digest,privacy_identity_proof_receipt_id,
    privacy_identity_proof_receipt_digest,response_submission_receipt_id,
    response_submission_receipt_digest,response_origin_receipt_id,
    response_origin_receipt_digest,source_response_request_id,
    binding_payload,binding_canonical,binding_digest,created_at
  ) VALUES(
    v_plan.correction_plan_id,v_plan.privacy_request_id,v_plan.plan_version,
    v_plan.plan_digest,v_plan.scope_inventory_id,v_plan.scope_item_digest,
    v_response_id,(v_projection->>'responseVersion')::bigint,
    (v_projection->>'currentValueDigest')::char(64),
    (v_projection->>'projectionDigest')::char(64),
    (v_projection->>'privacyIdentityProofReceiptId')::uuid,
    (v_projection->>'privacyIdentityProofReceiptDigest')::char(64),
    (v_projection->>'responseSubmissionReceiptId')::uuid,
    (v_projection->>'responseSubmissionReceiptDigest')::char(64),
    (v_projection->>'responseOriginReceiptId')::uuid,
    (v_projection->>'responseOriginReceiptDigest')::char(64),
    (v_projection->>'sourceResponseRequestId')::uuid,
    v_binding_payload,v_binding_canonical,v_binding_digest,v_plan.created_at
  );
  RETURN v_result;
EXCEPTION
  WHEN no_data_found THEN
    RAISE EXCEPTION 'privacy_correction_plan_binding_invalid'
      USING ERRCODE='55000';
END
$r6d_q4_create_party_name_plan$;
ALTER FUNCTION ops.create_privacy_correction_plan_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.create_privacy_correction_plan_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.create_privacy_correction_plan_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

CREATE TABLE ops.privacy_response_party_name_correction_approval_bindings_v1 (
  approval_binding_id uuid PRIMARY KEY,
  privacy_request_id uuid NOT NULL
    REFERENCES ops.privacy_requests_v2(id) ON DELETE RESTRICT,
  request_decision_version bigint NOT NULL,
  correction_plan_id uuid NOT NULL UNIQUE,
  plan_version bigint NOT NULL,
  plan_digest char(64) NOT NULL,
  plan_binding_digest char(64) NOT NULL,
  response_id uuid NOT NULL REFERENCES editorial.responses(id)
    ON DELETE RESTRICT,
  expected_response_version bigint NOT NULL,
  expected_current_value_digest char(64) NOT NULL,
  access_projection_digest char(64) NOT NULL,
  privacy_identity_proof_receipt_id uuid NOT NULL,
  privacy_identity_proof_receipt_digest char(64) NOT NULL,
  response_submission_receipt_id uuid NOT NULL,
  response_submission_receipt_digest char(64) NOT NULL,
  response_origin_receipt_id uuid NOT NULL,
  response_origin_receipt_digest char(64) NOT NULL,
  hold_coverage_digest char(64) NOT NULL,
  transition_receipt_id uuid NOT NULL UNIQUE,
  transition_receipt_digest char(64) NOT NULL UNIQUE,
  job_id uuid NOT NULL UNIQUE REFERENCES ops.jobs(id) ON DELETE RESTRICT,
  job_payload_digest char(64) NOT NULL UNIQUE,
  binding_payload jsonb NOT NULL,
  binding_canonical bytea NOT NULL,
  binding_digest char(64) NOT NULL UNIQUE,
  approved_at timestamptz NOT NULL,
  UNIQUE(privacy_request_id,request_decision_version),
  CONSTRAINT privacy_response_party_name_approval_plan_fk FOREIGN KEY(
    correction_plan_id,plan_binding_digest
  ) REFERENCES ops.privacy_response_party_name_correction_plan_bindings_v1(
    correction_plan_id,binding_digest
  ) ON DELETE RESTRICT,
  CONSTRAINT privacy_response_party_name_approval_transition_fk FOREIGN KEY(
    transition_receipt_id,privacy_request_id
  ) REFERENCES ops.privacy_request_transition_receipts_v2(
    transition_receipt_id,privacy_request_id
  ) ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT privacy_response_party_name_approval_shape_ck CHECK(
    request_decision_version>0 AND plan_version>0
    AND expected_response_version>0
    AND ops.r6d_lower_sha256(plan_digest)
    AND ops.r6d_lower_sha256(plan_binding_digest)
    AND ops.r6d_lower_sha256(expected_current_value_digest)
    AND ops.r6d_lower_sha256(access_projection_digest)
    AND ops.r6d_lower_sha256(privacy_identity_proof_receipt_digest)
    AND ops.r6d_lower_sha256(response_submission_receipt_digest)
    AND ops.r6d_lower_sha256(response_origin_receipt_digest)
    AND ops.r6d_lower_sha256(hold_coverage_digest)
    AND ops.r6d_lower_sha256(transition_receipt_digest)
    AND ops.r6d_lower_sha256(job_payload_digest)
    AND convert_from(binding_canonical,'UTF8')::jsonb=binding_payload
    AND binding_canonical=ops.canonical_jsonb_v1(binding_payload)
    AND binding_digest=encode(extensions.digest(binding_canonical,'sha256'),'hex')
    AND binding_payload->>'schemaVersion'=
      'privacy-response-party-name-correction-approval-binding.v1'
    AND binding_payload->>'targetObjectType'='RESPONSE'
    AND binding_payload->>'fieldPath'='/partyName'
    AND NOT binding_payload ?| ARRAY[
      'partyName','requestedValue','plaintext','requestedValueCiphertextBase64'
    ]
  )
);
ALTER TABLE ops.privacy_response_party_name_correction_approval_bindings_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_response_party_name_correction_approval_bindings_v1
  FROM PUBLIC,gurine_control_api,gurine_submission_api,
    gurine_workflow_worker,gurine_notification_worker,gurine_scheduler;
GRANT SELECT ON ops.privacy_response_party_name_correction_approval_bindings_v1
  TO gurine_auditor;
CREATE TRIGGER privacy_response_party_name_approval_bindings_v1_immutable
  BEFORE UPDATE OR DELETE
  ON ops.privacy_response_party_name_correction_approval_bindings_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

ALTER FUNCTION ops.read_privacy_retention_request_workspace_v2(uuid)
  RENAME TO read_privacy_retention_request_workspace_v2_pre_r6d_q4;
REVOKE ALL ON FUNCTION
  ops.read_privacy_retention_request_workspace_v2_pre_r6d_q4(uuid)
  FROM PUBLIC,gurine_control_api;

CREATE OR REPLACE FUNCTION ops.approve_privacy_response_party_name_correction_v1(
  p_payload jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_sha256 char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $r6d_q4_approve_party_name$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_privacy_request_id uuid;
  v_expected_decision_version bigint;
  v_transition_receipt_id uuid;
  v_actor_assertion_jti uuid;
  v_actor_assertion_request_digest char(64);
  v_actor_action_digest char(64);
  v_step_up_authorization_id uuid;
  v_step_up_receipt_digest char(64);
  v_reason_code text;
  v_reason_ciphertext bytea;
  v_reason_sha256 char(64);
  v_reason_aad_digest char(64);
  v_encryption_key_id text;
  v_idempotency ops.idempotency_keys%ROWTYPE;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_plan ops.privacy_correction_plans_v1%ROWTYPE;
  v_plan_binding
    ops.privacy_response_party_name_correction_plan_bindings_v1%ROWTYPE;
  v_plan_count bigint;
  v_inventory ops.privacy_request_scope_inventories_v1%ROWTYPE;
  v_projection jsonb;
  v_workspace jsonb;
  v_hold jsonb;
  v_policy_version text;
  v_decision_version bigint;
  v_decision_preimage jsonb;
  v_decision_digest char(64);
  v_transition_payload jsonb;
  v_transition_canonical bytea;
  v_transition_digest char(64);
  v_job_id uuid:=gen_random_uuid();
  v_job_payload jsonb;
  v_job_payload_digest char(64);
  v_approval_binding_id uuid:=gen_random_uuid();
  v_approval_payload jsonb;
  v_approval_canonical bytea;
  v_approval_digest char(64);
  v_audit_id uuid;
  v_outbox_id uuid;
  v_outbox_digest char(64);
  v_affected integer;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_payload))<>15
     OR NOT p_payload ?& ARRAY[
       'retentionRequestId','expectedDecisionVersion','transition',
       'reasonCode','reasonCiphertextBase64','reasonSha256',
       'transitionReceiptId','_actorAssertionJti',
       '_actorAssuranceLevel','_actorEffectiveCapability',
       '_actorAssertionRequestSha256','_actorActionDigest',
       '_actorStepUpAuthorizationId','_actorIdempotencyKeySha256',
       '_actorRequestKeySha256'
     ]
     OR p_payload->>'transition'<>'APPROVE'
     OR p_payload->>'_actorAssuranceLevel'<>'STEP_UP'
     OR p_payload->>'_actorEffectiveCapability'<>
        'privacy.requests.manage'
     OR jsonb_typeof(p_payload->'retentionRequestId')<>'string'
     OR jsonb_typeof(p_payload->'expectedDecisionVersion')<>'number'
     OR p_payload->>'expectedDecisionVersion' !~ '^[1-9][0-9]{0,18}$'
     OR jsonb_typeof(p_payload->'reasonCode')<>'string'
     OR jsonb_typeof(p_payload->'reasonCiphertextBase64')<>'string'
     OR jsonb_typeof(p_payload->'reasonSha256')<>'string'
     OR jsonb_typeof(p_payload->'transitionReceiptId')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssertionJti')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssertionRequestSha256')<>'string'
     OR jsonb_typeof(p_payload->'_actorActionDigest')<>'string'
     OR jsonb_typeof(p_payload->'_actorStepUpAuthorizationId')<>'string'
     OR jsonb_typeof(p_payload->'_actorIdempotencyKeySha256')<>'string'
     OR jsonb_typeof(p_payload->'_actorRequestKeySha256')<>'string'
     OR p_payload ? 'reason' OR p_payload ? 'partyName'
     OR NOT COALESCE(ops.r6d_lower_sha256(p_idempotency_key_sha256),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(p_request_sha256),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(p_payload->>'reasonSha256'),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(
       p_payload->>'_actorAssertionRequestSha256'
     ),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(
       p_payload->>'_actorActionDigest'
     ),false)
     OR p_payload->>'_actorIdempotencyKeySha256'<>
        btrim(p_idempotency_key_sha256)
     OR p_payload->>'_actorRequestKeySha256'<>
        btrim(p_idempotency_key_sha256)
     OR current_setting('transaction_isolation')<>'serializable' THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid'
      USING ERRCODE='22023';
  END IF;
  BEGIN
    v_privacy_request_id:=(p_payload->>'retentionRequestId')::uuid;
    v_expected_decision_version:=
      (p_payload->>'expectedDecisionVersion')::bigint;
    v_transition_receipt_id:=
      (p_payload->>'transitionReceiptId')::uuid;
    v_actor_assertion_jti:=(p_payload->>'_actorAssertionJti')::uuid;
    v_step_up_authorization_id:=
      (p_payload->>'_actorStepUpAuthorizationId')::uuid;
    v_reason_ciphertext:=decode(
      p_payload->>'reasonCiphertextBase64','base64'
    );
    v_encryption_key_id:=split_part(
      convert_from(v_reason_ciphertext,'UTF8'),'.',2
    );
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range
      OR invalid_parameter_value OR character_not_in_repertoire
      OR untranslatable_character THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid'
      USING ERRCODE='22023';
  END;
  v_reason_code:=p_payload->>'reasonCode';
  v_reason_sha256:=(p_payload->>'reasonSha256')::char(64);
  v_actor_assertion_request_digest:=
    (p_payload->>'_actorAssertionRequestSha256')::char(64);
  v_actor_action_digest:=(p_payload->>'_actorActionDigest')::char(64);
  v_reason_aad_digest:=ops.r6d_nul5_sha256_v1(
    'ops.privacy_request_sealed_content_v2','sealed_ciphertext',
    v_transition_receipt_id::text,'REASON','1'
  );
  IF v_privacy_request_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_transition_receipt_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_actor_assertion_jti=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_step_up_authorization_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR length(v_reason_code) NOT BETWEEN 1 AND 100
     OR btrim(v_reason_code)<>v_reason_code
     OR octet_length(v_reason_ciphertext) NOT BETWEEN 1 AND 65536
     OR replace(encode(v_reason_ciphertext,'base64'),E'\n','')<>
        p_payload->>'reasonCiphertextBase64'
     OR length(v_encryption_key_id) NOT BETWEEN 1 AND 200
     OR btrim(v_encryption_key_id)<>v_encryption_key_id
     OR NOT ops.r6d_field_envelope_v1_is_valid(
       v_reason_ciphertext,v_encryption_key_id
     ) THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid'
      USING ERRCODE='22023';
  END IF;

  SELECT claim.* INTO v_idempotency
  FROM ops.idempotency_keys AS claim
  WHERE claim.scope=
      'control:'||p_actor_id::text||':transitionRetentionRequest'
    AND claim.key_hash=p_idempotency_key_sha256
  FOR UPDATE;
  IF NOT FOUND OR v_idempotency.expires_at<=v_now
     OR v_idempotency.request_hash<>p_request_sha256
     OR num_nonnulls(
       v_idempotency.response_status,v_idempotency.resource_type,
       v_idempotency.resource_id,v_idempotency.response_body
     )<>0 THEN
    RAISE EXCEPTION 'privacy_transition_idempotency_conflict'
      USING ERRCODE='PVT08';
  END IF;

  SELECT request.* INTO v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=v_privacy_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_transition_request_not_found'
      USING ERRCODE='P0002';
  END IF;
  IF v_request.decision_version<>v_expected_decision_version THEN
    RAISE EXCEPTION 'RETENTION_VERSION_CONFLICT'
      USING ERRCODE='PVT08';
  END IF;
  IF v_request.request_type<>'CORRECTION' OR v_request.state<>'REVIEW'
     OR v_request.identity_state<>'VERIFIED'
     OR v_request.identity_verified_at IS NULL OR v_request.due_at IS NULL THEN
    RAISE EXCEPTION 'RETENTION_STATE_INVALID'
      USING ERRCODE='PVT09';
  END IF;

  SELECT count(*) INTO v_plan_count
  FROM ops.privacy_correction_plans_v1 AS plan
  JOIN ops.privacy_response_party_name_correction_plan_bindings_v1 AS binding
    ON binding.correction_plan_id=plan.correction_plan_id
   AND binding.plan_digest=plan.plan_digest
  WHERE plan.privacy_request_id=v_request.id;
  IF v_plan_count<>1 THEN
    RAISE EXCEPTION 'RETENTION_STATE_INVALID'
      USING ERRCODE='PVT09';
  END IF;
  SELECT plan.* INTO STRICT v_plan
  FROM ops.privacy_correction_plans_v1 AS plan
  WHERE plan.privacy_request_id=v_request.id
  FOR SHARE;
  SELECT binding.* INTO STRICT v_plan_binding
  FROM ops.privacy_response_party_name_correction_plan_bindings_v1 AS binding
  WHERE binding.correction_plan_id=v_plan.correction_plan_id
    AND binding.plan_digest=v_plan.plan_digest
  FOR SHARE;
  IF v_plan.request_decision_version<>v_request.decision_version
     OR v_plan.target_object_type<>'RESPONSE'
     OR v_plan.field_path<>'/partyName'
     OR v_plan.current_value_digest<>
        v_plan_binding.expected_current_value_digest THEN
    RAISE EXCEPTION 'RETENTION_VERSION_CONFLICT'
      USING ERRCODE='PVT08';
  END IF;

  v_workspace:=
    ops.read_privacy_retention_request_workspace_v2_pre_r6d_q4(
      v_request.id
    );
  IF v_workspace->'request'->>'state'<>'REVIEW'
     OR (v_workspace->'request'->>'decisionVersion')::bigint<>
        v_request.decision_version THEN
    RAISE EXCEPTION 'privacy_correction_workspace_authority_invalid'
      USING ERRCODE='55000';
  END IF;
  SELECT inventory.* INTO STRICT v_inventory
  FROM ops.privacy_request_scope_inventories_v1 AS inventory
  WHERE inventory.privacy_request_id=v_request.id;
  v_projection:=ops.read_privacy_response_party_name_access_v1(
    v_request.id,v_plan.target_object_id
  );
  IF (v_projection->>'responseVersion')::bigint<>
       v_plan_binding.expected_response_version
     OR v_projection->>'currentValueDigest'<>
        btrim(v_plan_binding.expected_current_value_digest)
     OR v_projection->>'projectionDigest'<>
        btrim(v_plan_binding.access_projection_digest)
     OR (v_projection->>'privacyIdentityProofReceiptId')::uuid<>
        v_plan_binding.privacy_identity_proof_receipt_id
     OR v_projection->>'privacyIdentityProofReceiptDigest'<>
        btrim(v_plan_binding.privacy_identity_proof_receipt_digest)
     OR (v_projection->>'responseSubmissionReceiptId')::uuid<>
        v_plan_binding.response_submission_receipt_id
     OR v_projection->>'responseSubmissionReceiptDigest'<>
        btrim(v_plan_binding.response_submission_receipt_digest)
     OR (v_projection->>'responseOriginReceiptId')::uuid<>
        v_plan_binding.response_origin_receipt_id
     OR v_projection->>'responseOriginReceiptDigest'<>
        btrim(v_plan_binding.response_origin_receipt_digest) THEN
    RAISE EXCEPTION 'RETENTION_VERSION_CONFLICT'
      USING ERRCODE='PVT08';
  END IF;
  v_hold:=ops.r6d_privacy_request_legal_hold_coverage_v1(
    v_request.id,v_now
  );
  IF COALESCE((v_hold->>'active')::boolean,true) THEN
    RAISE EXCEPTION 'privacy_correction_legal_hold_active'
      USING ERRCODE='55000';
  END IF;

  v_step_up_receipt_digest:=ops.require_privacy_step_up_v3(
    p_actor_id,p_session_id,v_actor_assertion_jti,
    v_actor_assertion_request_digest,v_actor_action_digest,
    v_step_up_authorization_id,p_idempotency_key_sha256,
    'privacy.requests.manage',v_now
  );
  SELECT policy.policy_version INTO STRICT v_policy_version
  FROM ops.privacy_response_calendar_policies_v1 AS policy
  WHERE policy.policy_id=v_request.response_policy_id
    AND policy.revision=v_request.response_policy_revision
    AND policy.policy_digest=v_request.response_policy_digest;
  v_decision_version:=v_request.decision_version+1;
  v_decision_preimage:=jsonb_build_object(
    'schemaVersion',
      'privacy-response-party-name-correction-approval-decision.v1',
    'retentionRequestId',v_request.id,
    'decisionVersion',v_decision_version,
    'correctionPlanId',v_plan.correction_plan_id,
    'planVersion',v_plan.plan_version,'planDigest',btrim(v_plan.plan_digest),
    'planBindingDigest',btrim(v_plan_binding.binding_digest),
    'responseId',v_plan.target_object_id,
    'expectedResponseVersion',v_plan_binding.expected_response_version,
    'expectedCurrentValueDigest',
      btrim(v_plan_binding.expected_current_value_digest),
    'accessProjectionDigest',
      btrim(v_plan_binding.access_projection_digest),
    'inventorySnapshotDigest',btrim(v_inventory.receipt_digest),
    'holdCoverageDigest',v_hold->>'coverageDigest',
    'reasonDigest',btrim(v_reason_sha256),'approvedAt',v_now
  );
  v_decision_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_decision_preimage),'sha256'
  ),'hex');
  v_transition_payload:=jsonb_build_object(
    'schemaVersion','privacy-request-transition-receipt.v2',
    'transitionReceiptId',v_transition_receipt_id,
    'retentionRequestId',v_request.id,
    'decisionVersion',v_decision_version,'transition','APPROVE',
    'priorState','REVIEW','state','APPROVED',
    'reasonCode',v_reason_code,'reasonDigest',btrim(v_reason_sha256),
    'reasonAadDigest',btrim(v_reason_aad_digest),
    'extensionReasonCode',NULL,'extensionReasonDigest',NULL,
    'extensionReasonAadDigest',NULL,'rejectionReasonCode',NULL,
    'rejectionReasonDigest',NULL,'rejectionReasonAadDigest',NULL,
    'appealInstructionsDigest',NULL,
    'appealInstructionsAadDigest',NULL,
    'encryptionKeyId',v_encryption_key_id,'actorId',p_actor_id,
    'actorAssertionJti',v_actor_assertion_jti,
    'actorActionDigest',btrim(v_actor_action_digest),
    'stepUpAuthorizationId',v_step_up_authorization_id,
    'stepUpReceiptDigest',btrim(v_step_up_receipt_digest),
    'idempotencyKeySha256',btrim(p_idempotency_key_sha256),
    'requestSha256',btrim(p_request_sha256),
    'identityReceiptId',NULL,'identityReceiptDigest',NULL,
    'extensionReceiptId',NULL,'extensionReceiptDigest',NULL,
    'refusalReceiptId',NULL,'refusalReceiptDigest',NULL,
    'noticeReceiptId',NULL,'noticeReceiptDigest',NULL,
    'decisionDigest',btrim(v_decision_digest),'decidedAt',v_now
  );
  v_transition_canonical:=ops.canonical_jsonb_v1(v_transition_payload);
  v_transition_digest:=encode(extensions.digest(
    v_transition_canonical,'sha256'
  ),'hex');
  v_job_payload:=jsonb_build_object(
    'schemaVersion','privacy-response-party-name-correction-job.v1',
    'privacyRequestId',v_request.id,
    'requestDecisionVersion',v_decision_version,
    'correctionPlanId',v_plan.correction_plan_id,
    'planVersion',v_plan.plan_version,'planDigest',btrim(v_plan.plan_digest),
    'responseId',v_plan.target_object_id,
    'expectedResponseVersion',v_plan_binding.expected_response_version,
    'expectedCurrentValueDigest',
      btrim(v_plan_binding.expected_current_value_digest),
    'accessProjectionDigest',btrim(v_plan_binding.access_projection_digest),
    'privacyIdentityProofReceiptId',
      v_plan_binding.privacy_identity_proof_receipt_id,
    'privacyIdentityProofReceiptDigest',
      btrim(v_plan_binding.privacy_identity_proof_receipt_digest),
    'responseSubmissionReceiptId',
      v_plan_binding.response_submission_receipt_id,
    'responseSubmissionReceiptDigest',
      btrim(v_plan_binding.response_submission_receipt_digest),
    'responseOriginReceiptId',v_plan_binding.response_origin_receipt_id,
    'responseOriginReceiptDigest',
      btrim(v_plan_binding.response_origin_receipt_digest),
    'approvalTransitionReceiptId',v_transition_receipt_id,
    'approvalTransitionReceiptDigest',btrim(v_transition_digest),
    'requestedValueSha256',btrim(v_plan.requested_value_sha256),
    'requestedValueAadDigest',btrim(v_plan.requested_value_aad_digest),
    'requestedValueCiphertextDigest',
      btrim(v_plan.requested_value_ciphertext_digest),
    'encryptionKeyId',v_plan.encryption_key_id,
    'holdCoverageDigest',v_hold->>'coverageDigest','queuedAt',v_now
  );
  v_job_payload_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_job_payload),'sha256'
  ),'hex');
  v_approval_payload:=jsonb_build_object(
    'schemaVersion',
      'privacy-response-party-name-correction-approval-binding.v1',
    'approvalBindingId',v_approval_binding_id,
    'retentionRequestId',v_request.id,
    'requestDecisionVersion',v_decision_version,
    'correctionPlanId',v_plan.correction_plan_id,
    'planVersion',v_plan.plan_version,'planDigest',btrim(v_plan.plan_digest),
    'planBindingDigest',btrim(v_plan_binding.binding_digest),
    'targetObjectType','RESPONSE','targetObjectId',v_plan.target_object_id,
    'fieldPath','/partyName',
    'expectedResponseVersion',v_plan_binding.expected_response_version,
    'expectedCurrentValueDigest',
      btrim(v_plan_binding.expected_current_value_digest),
    'accessProjectionDigest',btrim(v_plan_binding.access_projection_digest),
    'privacyIdentityProofReceiptId',
      v_plan_binding.privacy_identity_proof_receipt_id,
    'privacyIdentityProofReceiptDigest',
      btrim(v_plan_binding.privacy_identity_proof_receipt_digest),
    'responseSubmissionReceiptId',
      v_plan_binding.response_submission_receipt_id,
    'responseSubmissionReceiptDigest',
      btrim(v_plan_binding.response_submission_receipt_digest),
    'responseOriginReceiptId',v_plan_binding.response_origin_receipt_id,
    'responseOriginReceiptDigest',
      btrim(v_plan_binding.response_origin_receipt_digest),
    'holdCoverageDigest',v_hold->>'coverageDigest',
    'transitionReceiptId',v_transition_receipt_id,
    'transitionReceiptDigest',btrim(v_transition_digest),
    'jobId',v_job_id,'jobPayloadDigest',btrim(v_job_payload_digest),
    'approvedAt',v_now
  );
  v_approval_canonical:=ops.canonical_jsonb_v1(v_approval_payload);
  v_approval_digest:=encode(extensions.digest(
    v_approval_canonical,'sha256'
  ),'hex');

  v_audit_id:=ops.append_audit_event(
    'privacy-request:'||v_request.id::text,'USER',p_actor_id::text,
    p_session_id,'command.transitionRetentionRequest','PRIVACY_REQUEST',
    v_request.id::text,'privacy.requests.manage','SUCCESS',v_reason_code,
    p_request_id,jsonb_build_object(
      'decisionVersion',v_decision_version,'transition','APPROVE',
      'correctionPlanId',v_plan.correction_plan_id,
      'planDigest',btrim(v_plan.plan_digest),
      'responseId',v_plan.target_object_id,
      'expectedResponseVersion',v_plan_binding.expected_response_version,
      'expectedCurrentValueDigest',
        btrim(v_plan_binding.expected_current_value_digest),
      'accessProjectionDigest',
        btrim(v_plan_binding.access_projection_digest),
      'inventorySnapshotDigest',btrim(v_inventory.receipt_digest),
      'holdCoverageDigest',v_hold->>'coverageDigest',
      'transitionReceiptId',v_transition_receipt_id,
      'transitionReceiptDigest',btrim(v_transition_digest),
      'jobId',v_job_id,'jobPayloadDigest',btrim(v_job_payload_digest),
      'approvalBindingDigest',btrim(v_approval_digest),
      'targetMutationCount',0
    )
  );
  v_outbox_id:=ops.enqueue_outbox(
    'privacy_request',v_request.id::text,v_decision_version,
    'privacy.request_decision_recorded.v1',jsonb_build_object(
      'retentionRequestId',v_request.id,
      'decisionVersion',v_decision_version,'transition','APPROVE',
      'priorState','REVIEW','state','APPROVED',
      'inventorySnapshotDigest',btrim(v_inventory.receipt_digest),
      'holdCoverageDigest',v_hold->>'coverageDigest',
      'decisionDigest',btrim(v_decision_digest),
      'receiptDigest',btrim(v_transition_digest)
    ),v_now
  );
  v_outbox_digest:=ops.r6d_outbox_envelope_digest_v1(v_outbox_id);
  IF v_outbox_digest IS NULL THEN
    RAISE EXCEPTION 'privacy_correction_approval_outbox_invalid'
      USING ERRCODE='55000';
  END IF;

  INSERT INTO ops.jobs(
    id,job_type,queue,payload,dedupe_key,max_attempts
  ) VALUES(
    v_job_id,'PRIVACY_RESPONSE_PARTY_NAME_CORRECTION','workflow-worker',
    v_job_payload,
    'privacy-response-party-name-correction:'||v_plan.correction_plan_id::text,
    8
  );
  INSERT INTO ops.privacy_request_transition_receipts_v2(
    transition_receipt_id,privacy_request_id,decision_version,transition,
    prior_state,state,reason_code,reason_sha256,reason_aad_digest,
    encryption_key_id,actor_id,actor_assertion_jti,actor_action_digest,
    step_up_authorization_id,idempotency_key_sha256,request_sha256,
    event_receipt_id,event_receipt_digest,audit_event_id,outbox_event_ids,
    receipt_payload,receipt_canonical,receipt_digest,decided_at
  ) VALUES(
    v_transition_receipt_id,v_request.id,v_decision_version,'APPROVE',
    'REVIEW','APPROVED',v_reason_code,v_reason_sha256,v_reason_aad_digest,
    v_encryption_key_id,p_actor_id,v_actor_assertion_jti,
    v_actor_action_digest,v_step_up_authorization_id,
    p_idempotency_key_sha256,p_request_sha256,v_outbox_id,v_outbox_digest,
    v_audit_id,ARRAY[v_outbox_id]::uuid[],v_transition_payload,
    v_transition_canonical,v_transition_digest,v_now
  );
  INSERT INTO ops.privacy_request_sealed_content_v2(
    privacy_request_id,transition_receipt_id,field_kind,sealed_ciphertext,
    sealed_sha256,sealed_aad_digest,encryption_key_id
  ) VALUES(
    v_request.id,v_transition_receipt_id,'REASON',v_reason_ciphertext,
    v_reason_sha256,v_reason_aad_digest,v_encryption_key_id
  );
  INSERT INTO ops.privacy_response_party_name_correction_approval_bindings_v1(
    approval_binding_id,privacy_request_id,request_decision_version,
    correction_plan_id,plan_version,plan_digest,plan_binding_digest,
    response_id,expected_response_version,expected_current_value_digest,
    access_projection_digest,privacy_identity_proof_receipt_id,
    privacy_identity_proof_receipt_digest,response_submission_receipt_id,
    response_submission_receipt_digest,response_origin_receipt_id,
    response_origin_receipt_digest,hold_coverage_digest,
    transition_receipt_id,transition_receipt_digest,job_id,
    job_payload_digest,binding_payload,binding_canonical,binding_digest,
    approved_at
  ) VALUES(
    v_approval_binding_id,v_request.id,v_decision_version,
    v_plan.correction_plan_id,v_plan.plan_version,v_plan.plan_digest,
    v_plan_binding.binding_digest,v_plan.target_object_id,
    v_plan_binding.expected_response_version,
    v_plan_binding.expected_current_value_digest,
    v_plan_binding.access_projection_digest,
    v_plan_binding.privacy_identity_proof_receipt_id,
    v_plan_binding.privacy_identity_proof_receipt_digest,
    v_plan_binding.response_submission_receipt_id,
    v_plan_binding.response_submission_receipt_digest,
    v_plan_binding.response_origin_receipt_id,
    v_plan_binding.response_origin_receipt_digest,
    (v_hold->>'coverageDigest')::char(64),v_transition_receipt_id,
    v_transition_digest,v_job_id,v_job_payload_digest,v_approval_payload,
    v_approval_canonical,v_approval_digest,v_now
  );
  PERFORM set_config('gurine.privacy_request_transition_v2','1',true);
  UPDATE ops.privacy_requests_v2
  SET decision_version=v_decision_version,state='APPROVED',updated_at=v_now
  WHERE id=v_request.id AND decision_version=v_request.decision_version
    AND state='REVIEW';
  GET DIAGNOSTICS v_affected=ROW_COUNT;
  IF v_affected<>1 THEN
    RAISE EXCEPTION 'RETENTION_VERSION_CONFLICT'
      USING ERRCODE='PVT08';
  END IF;

  RETURN jsonb_build_object(
    'requestId',p_request_id,'aggregateId',v_request.id,
    'aggregateVersion',v_decision_version,'status','COMPLETED',
    'acceptedAt',v_now,'receiptDigest',btrim(v_transition_digest),
    'auditEventId',v_audit_id,
    'outboxEventIds',jsonb_build_array(v_outbox_id),
    'emittedEventIds',jsonb_build_array(v_outbox_id),'links','[]'::jsonb,
    'transition',jsonb_build_object(
      'retentionRequestId',v_request.id,
      'decisionVersion',v_decision_version,
      'requestType',v_request.request_type,'state','APPROVED',
      'transition','APPROVE','transitionReceiptId',v_transition_receipt_id,
      'transitionReceiptDigest',btrim(v_transition_digest),
      'identityVerifiedAt',v_request.identity_verified_at,
      'dueAt',v_request.due_at,'policyVersion',v_policy_version,
      'policyDigest',btrim(v_request.response_policy_digest),
      'calendarVersionId',v_request.calendar_version_id,
      'calendarDigest',btrim(v_request.calendar_digest),
      'identityReceiptId',NULL,'identityReceiptDigest',NULL,
      'extensionReceiptId',NULL,'extensionReceiptDigest',NULL,
      'refusalReceiptId',NULL,'refusalReceiptDigest',NULL,
      'noticeReceiptId',NULL,'noticeReceiptDigest',NULL,
      'appealInstructionsDigest',NULL,'updatedAt',v_now,'replayed',false
    )
  );
END
$r6d_q4_approve_party_name$;
ALTER FUNCTION ops.approve_privacy_response_party_name_correction_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.approve_privacy_response_party_name_correction_v1(
    jsonb,uuid,uuid,uuid,char(64),char(64)
  ) FROM PUBLIC,gurine_control_api;

-- Route the sole executable correction approval edge to the dedicated owner.
-- Every other transition remains byte-for-byte owned by the final 0039
-- wrapper, including its D3 identity-proof branch and signed request binding.
ALTER FUNCTION ops.transition_privacy_request_v2(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) RENAME TO transition_privacy_request_v2_pre_r6d_q4_party_name;
REVOKE ALL ON FUNCTION
  ops.transition_privacy_request_v2_pre_r6d_q4_party_name(
    jsonb,uuid,uuid,uuid,char(64),char(64)
  ) FROM PUBLIC,gurine_control_api;

CREATE OR REPLACE FUNCTION ops.transition_privacy_request_v2(
  p_payload jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_sha256 char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $r6d_q4_party_name_transition$
DECLARE
  v_privacy_request_id uuid;
  v_request_type text;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR jsonb_typeof(p_payload->'transition')<>'string' THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid'
      USING ERRCODE='22023';
  END IF;
  IF p_payload->>'transition'='APPROVE'
     AND jsonb_typeof(p_payload->'retentionRequestId')='string' THEN
    BEGIN
      v_privacy_request_id:=(p_payload->>'retentionRequestId')::uuid;
      SELECT request.request_type INTO v_request_type
      FROM ops.privacy_requests_v2 AS request
      WHERE request.id=v_privacy_request_id;
    EXCEPTION WHEN invalid_text_representation THEN
      v_request_type:=NULL;
    END;
    IF v_request_type='CORRECTION' THEN
      RETURN ops.approve_privacy_response_party_name_correction_v1(
        p_payload,p_actor_id,p_session_id,p_request_id,
        p_idempotency_key_sha256,p_request_sha256
      );
    END IF;
  END IF;
  RETURN ops.transition_privacy_request_v2_pre_r6d_q4_party_name(
    p_payload,p_actor_id,p_session_id,p_request_id,
    p_idempotency_key_sha256,p_request_sha256
  );
END
$r6d_q4_party_name_transition$;
ALTER FUNCTION ops.transition_privacy_request_v2(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.transition_privacy_request_v2(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.transition_privacy_request_v2(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- The temporary Q4 dispatcher rejected every correction-plan command before
-- reaching the now-closed owner.  Reopen only the two exact final branches:
-- the existing 0039 adapter continues to validate plan results, while this
-- adapter validates the dedicated APPROVE receipt/job graph.  All unrelated
-- operations keep the prior final dispatch chain unchanged.
CREATE OR REPLACE FUNCTION ops.apply_control_addendum_command(
  p_operation_id text,
  p_payload jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key_hash char(64),
  p_request_digest char(64)
) RETURNS TABLE(
  aggregate_id uuid,
  aggregate_version bigint,
  status text,
  accepted_at timestamptz,
  response_body jsonb,
  receipt_digest char(64),
  audit_event_id uuid,
  outbox_event_id uuid
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,intake,extensions,pg_temp
AS $r6d_q4_final_dispatcher$
DECLARE
  v_result jsonb;
  v_transition jsonb;
  v_aggregate_id uuid;
  v_aggregate_version bigint;
  v_accepted_at timestamptz;
  v_receipt_digest char(64);
  v_audit_event_id uuid;
  v_outbox_event_id uuid;
  v_transition_receipt_id uuid;
  v_transition_receipt ops.privacy_request_transition_receipts_v2%ROWTYPE;
  v_approval
    ops.privacy_response_party_name_correction_approval_bindings_v1%ROWTYPE;
  v_job ops.jobs%ROWTYPE;
  v_event ops.outbox%ROWTYPE;
  v_job_digest char(64);
  v_route_privacy_request_id uuid;
  v_route_request_type text;
BEGIN
  IF p_operation_id='createPrivacyCorrectionPlan' THEN
    RETURN QUERY
    SELECT prior.aggregate_id,prior.aggregate_version,prior.status,
      prior.accepted_at,prior.response_body,prior.receipt_digest,
      prior.audit_event_id,prior.outbox_event_id
    FROM ops.apply_control_addendum_command_pre_r6d_q4_unsupported(
      p_operation_id,p_payload,p_actor_id,p_session_id,p_request_id,
      p_idempotency_key_hash,p_request_digest
    ) AS prior;
    RETURN;
  END IF;

  IF p_operation_id='transitionRetentionRequest'
     AND p_payload IS NOT NULL AND jsonb_typeof(p_payload)='object'
     AND jsonb_typeof(p_payload->'transition')='string'
     AND p_payload->>'transition'='APPROVE'
     AND jsonb_typeof(p_payload->'retentionRequestId')='string' THEN
    BEGIN
      v_route_privacy_request_id:=
        (p_payload->>'retentionRequestId')::uuid;
      SELECT request.request_type INTO v_route_request_type
      FROM ops.privacy_requests_v2 AS request
      WHERE request.id=v_route_privacy_request_id;
    EXCEPTION WHEN invalid_text_representation THEN
      v_route_request_type:=NULL;
    END;
  END IF;
  IF v_route_request_type IS DISTINCT FROM 'CORRECTION' THEN
    RETURN QUERY
    SELECT prior.aggregate_id,prior.aggregate_version,prior.status,
      prior.accepted_at,prior.response_body,prior.receipt_digest,
      prior.audit_event_id,prior.outbox_event_id
    FROM ops.apply_control_addendum_command_pre_r6d_q4_unsupported(
      p_operation_id,p_payload,p_actor_id,p_session_id,p_request_id,
      p_idempotency_key_hash,p_request_digest
    ) AS prior;
    RETURN;
  END IF;

  v_result:=ops.transition_privacy_request_v2(
    p_payload,p_actor_id,p_session_id,p_request_id,
    p_idempotency_key_hash,p_request_digest
  );
  IF v_result IS NULL OR jsonb_typeof(v_result)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_result))<>11
     OR NOT v_result ?& ARRAY[
       'requestId','aggregateId','aggregateVersion','status','acceptedAt',
       'receiptDigest','auditEventId','outboxEventIds','emittedEventIds',
       'links','transition'
     ]
     OR v_result->>'status'<>'COMPLETED'
     OR jsonb_typeof(v_result->'outboxEventIds')<>'array'
     OR v_result->'outboxEventIds'<>v_result->'emittedEventIds'
     OR jsonb_array_length(v_result->'outboxEventIds')<>1
     OR v_result->'links'<>'[]'::jsonb
     OR jsonb_typeof(v_result->'transition')<>'object' THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;
  v_transition:=v_result->'transition';
  IF (SELECT count(*) FROM jsonb_object_keys(v_transition))<>24
     OR NOT v_transition ?& ARRAY[
       'retentionRequestId','decisionVersion','requestType','state',
       'transition','transitionReceiptId','transitionReceiptDigest',
       'identityVerifiedAt','dueAt','policyVersion','policyDigest',
       'calendarVersionId','calendarDigest','identityReceiptId',
       'identityReceiptDigest','extensionReceiptId',
       'extensionReceiptDigest','refusalReceiptId',
       'refusalReceiptDigest','noticeReceiptId','noticeReceiptDigest',
       'appealInstructionsDigest','updatedAt','replayed'
     ]
     OR v_transition->>'requestType'<>'CORRECTION'
     OR v_transition->>'state'<>'APPROVED'
     OR v_transition->>'transition'<>'APPROVE'
     OR jsonb_typeof(v_transition->'replayed')<>'boolean'
     OR (v_transition->>'replayed')::boolean
     OR jsonb_typeof(v_transition->'identityReceiptId')<>'null'
     OR jsonb_typeof(v_transition->'identityReceiptDigest')<>'null'
     OR jsonb_typeof(v_transition->'extensionReceiptId')<>'null'
     OR jsonb_typeof(v_transition->'extensionReceiptDigest')<>'null'
     OR jsonb_typeof(v_transition->'refusalReceiptId')<>'null'
     OR jsonb_typeof(v_transition->'refusalReceiptDigest')<>'null'
     OR jsonb_typeof(v_transition->'noticeReceiptId')<>'null'
     OR jsonb_typeof(v_transition->'noticeReceiptDigest')<>'null'
     OR jsonb_typeof(v_transition->'appealInstructionsDigest')<>'null'
     OR NOT ops.r6d_lower_sha256(
       v_transition->>'transitionReceiptDigest'
     ) THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;
  BEGIN
    v_aggregate_id:=(v_result->>'aggregateId')::uuid;
    v_aggregate_version:=(v_result->>'aggregateVersion')::bigint;
    v_accepted_at:=(v_result->>'acceptedAt')::timestamptz;
    v_receipt_digest:=(v_result->>'receiptDigest')::char(64);
    v_audit_event_id:=(v_result->>'auditEventId')::uuid;
    v_outbox_event_id:=(v_result->'outboxEventIds'->>0)::uuid;
    v_transition_receipt_id:=
      (v_transition->>'transitionReceiptId')::uuid;
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range
      OR datetime_field_overflow THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END;
  SELECT receipt.* INTO v_transition_receipt
  FROM ops.privacy_request_transition_receipts_v2 AS receipt
  WHERE receipt.transition_receipt_id=v_transition_receipt_id FOR SHARE;
  SELECT binding.* INTO v_approval
  FROM ops.privacy_response_party_name_correction_approval_bindings_v1
    AS binding
  WHERE binding.transition_receipt_id=v_transition_receipt_id FOR SHARE;
  SELECT job.* INTO v_job FROM ops.jobs AS job
  WHERE job.id=v_approval.job_id FOR SHARE;
  SELECT event.* INTO v_event FROM ops.outbox AS event
  WHERE event.id=v_outbox_event_id FOR SHARE;
  v_job_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_job.payload),'sha256'
  ),'hex');
  IF v_transition_receipt.transition_receipt_id IS NULL
     OR v_approval.approval_binding_id IS NULL OR v_job.id IS NULL
     OR v_event.id IS NULL
     OR (v_result->>'requestId')::uuid<>p_request_id
     OR v_aggregate_id<>(v_transition->>'retentionRequestId')::uuid
     OR v_aggregate_version<>(v_transition->>'decisionVersion')::bigint
     OR v_receipt_digest<>v_transition_receipt.receipt_digest
     OR v_receipt_digest<>
        (v_transition->>'transitionReceiptDigest')::char(64)
     OR v_accepted_at<>v_transition_receipt.decided_at
     OR v_accepted_at<>(v_transition->>'updatedAt')::timestamptz
     OR v_audit_event_id<>v_transition_receipt.audit_event_id
     OR v_transition_receipt.privacy_request_id<>v_aggregate_id
     OR v_transition_receipt.decision_version<>v_aggregate_version
     OR v_transition_receipt.transition<>'APPROVE'
     OR v_transition_receipt.prior_state<>'REVIEW'
     OR v_transition_receipt.state<>'APPROVED'
     OR v_transition_receipt.event_receipt_id<>v_outbox_event_id
     OR v_transition_receipt.event_receipt_digest<>
        ops.r6d_outbox_envelope_digest_v1(v_outbox_event_id)
     OR v_transition_receipt.outbox_event_ids<>
        ARRAY[v_outbox_event_id]::uuid[]
     OR v_approval.privacy_request_id<>v_aggregate_id
     OR v_approval.request_decision_version<>v_aggregate_version
     OR v_approval.transition_receipt_digest<>v_receipt_digest
     OR v_approval.job_payload_digest<>v_job_digest
     OR v_job.job_type<>'PRIVACY_RESPONSE_PARTY_NAME_CORRECTION'
     OR v_job.queue<>'workflow-worker'
     OR v_event.aggregate_type<>'privacy_request'
     OR v_event.aggregate_id<>v_aggregate_id::text
     OR v_event.aggregate_version<>v_aggregate_version
     OR v_event.event_type<>'privacy.request_decision_recorded.v1'
     OR v_event.payload->>'transition'<>'APPROVE'
     OR v_event.payload->>'receiptDigest'<>btrim(v_receipt_digest)
     OR v_event.occurred_at<>v_accepted_at THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;
  RETURN QUERY SELECT
    v_aggregate_id,v_aggregate_version,v_result->>'status',v_accepted_at,
    v_result,v_receipt_digest,v_audit_event_id,v_outbox_event_id;
END
$r6d_q4_final_dispatcher$;
ALTER FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- Event delivery ACK is deliberately read-only.  It proves the active
-- retention-worker EVENT_DELIVERY lease/fence and immutable approval graph,
-- then returns the already-created child correction job.  The caller marks
-- the inbox only after this owner returns successfully.
CREATE OR REPLACE FUNCTION
  ops.ack_privacy_response_party_name_correction_delegation_v1(
    p_source_event_id uuid,
    p_privacy_request_id uuid,
    p_decision_version bigint,
    p_transition_receipt_digest char(64),
    p_delivery_job_id uuid,
    p_lease_token uuid,
    p_fencing_token bigint
  ) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $r6d_q4_party_name_delegation$
DECLARE
  v_delivery ops.jobs%ROWTYPE;
  v_inbox ops.inbox%ROWTYPE;
  v_event ops.outbox%ROWTYPE;
  v_transition ops.privacy_request_transition_receipts_v2%ROWTYPE;
  v_approval
    ops.privacy_response_party_name_correction_approval_bindings_v1%ROWTYPE;
  v_child ops.jobs%ROWTYPE;
  v_event_digest char(64);
  v_child_digest char(64);
  v_expected_delivery_payload jsonb;
BEGIN
  IF p_source_event_id IS NULL OR p_privacy_request_id IS NULL
     OR p_delivery_job_id IS NULL OR p_lease_token IS NULL
     OR p_decision_version IS NULL OR p_decision_version<1
     OR p_fencing_token IS NULL OR p_fencing_token<1
     OR p_source_event_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR p_privacy_request_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR p_delivery_job_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR p_lease_token='00000000-0000-0000-0000-000000000000'::uuid
     OR NOT COALESCE(
       ops.r6d_lower_sha256(p_transition_receipt_digest),false
     ) THEN
    RAISE EXCEPTION
      'privacy_response_party_name_correction_delegation_input_invalid'
      USING ERRCODE='22023';
  END IF;
  IF NOT pg_has_role(session_user,'gurine_workflow_worker','MEMBER') THEN
    RAISE EXCEPTION 'privacy_response_party_name_correction_worker_required'
      USING ERRCODE='42501';
  END IF;

  SELECT job.* INTO v_delivery FROM ops.jobs AS job
  WHERE job.id=p_delivery_job_id
    AND job.job_type='EVENT_DELIVERY'
    AND job.queue='workflow-worker'
    AND job.status='RUNNING'
    AND job.lease_token=p_lease_token
    AND job.fencing_token=p_fencing_token
    AND job.lease_expires_at>clock_timestamp()
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'privacy_response_party_name_correction_delivery_fence_stale'
      USING ERRCODE='40001';
  END IF;
  SELECT inbox.* INTO v_inbox FROM ops.inbox AS inbox
  WHERE inbox.consumer='retention-worker'
    AND inbox.event_id=p_source_event_id
    AND inbox.processed_at IS NULL
    AND inbox.result='DISPATCHED:'||p_delivery_job_id::text
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'privacy_response_party_name_correction_delivery_fence_stale'
      USING ERRCODE='40001';
  END IF;

  SELECT event.* INTO v_event FROM ops.outbox AS event
  WHERE event.id=p_source_event_id
    AND event.aggregate_type='privacy_request'
    AND event.aggregate_id=p_privacy_request_id::text
    AND event.aggregate_version=p_decision_version
    AND event.event_type='privacy.request_decision_recorded.v1'
  FOR SHARE;
  IF NOT FOUND OR jsonb_typeof(v_event.payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_event.payload))<>9
     OR NOT v_event.payload ?& ARRAY[
       'retentionRequestId','decisionVersion','transition','priorState',
       'state','inventorySnapshotDigest','holdCoverageDigest',
       'decisionDigest','receiptDigest'
     ]
     OR v_event.payload->>'retentionRequestId'<>
        p_privacy_request_id::text
     OR v_event.payload->>'decisionVersion'<>p_decision_version::text
     OR v_event.payload->>'transition'<>'APPROVE'
     OR v_event.payload->>'priorState'<>'REVIEW'
     OR v_event.payload->>'state'<>'APPROVED'
     OR v_event.payload->>'receiptDigest'<>
        btrim(p_transition_receipt_digest) THEN
    RAISE EXCEPTION
      'privacy_response_party_name_correction_delegation_unrelated'
      USING ERRCODE='22023';
  END IF;
  v_expected_delivery_payload:=jsonb_build_object(
    'consumerId','retention-worker','eventId',v_event.id,
    'eventType',v_event.event_type,'aggregateType',v_event.aggregate_type,
    'aggregateId',v_event.aggregate_id,
    'aggregateVersion',v_event.aggregate_version,
    'occurredAt',
      to_char(
        v_event.occurred_at AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS'
      )||CASE
        WHEN to_char(
          v_event.occurred_at AT TIME ZONE 'UTC','US'
        )='000000' THEN 'Z'
        ELSE '.'||rtrim(to_char(
          v_event.occurred_at AT TIME ZONE 'UTC','US'
        ),'0')||'Z'
      END,
    'payload',v_event.payload
  );
  IF jsonb_typeof(v_delivery.payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_delivery.payload))<>8
     OR v_delivery.payload IS DISTINCT FROM v_expected_delivery_payload THEN
    RAISE EXCEPTION
      'privacy_response_party_name_correction_delegation_unrelated'
      USING ERRCODE='22023';
  END IF;

  SELECT receipt.* INTO v_transition
  FROM ops.privacy_request_transition_receipts_v2 AS receipt
  WHERE receipt.privacy_request_id=p_privacy_request_id
    AND receipt.decision_version=p_decision_version
    AND receipt.transition='APPROVE'
    AND receipt.receipt_digest=p_transition_receipt_digest
  FOR SHARE;
  v_event_digest:=ops.r6d_outbox_envelope_digest_v1(v_event.id);
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'privacy_response_party_name_correction_delegation_integrity_invalid'
      USING ERRCODE='23514';
  END IF;
  IF v_transition.event_receipt_id<>v_event.id
     OR v_transition.event_receipt_digest<>v_event_digest
     OR v_transition.outbox_event_ids<>ARRAY[v_event.id]::uuid[] THEN
    RAISE EXCEPTION
      'privacy_response_party_name_correction_delegation_integrity_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT binding.* INTO v_approval
  FROM ops.privacy_response_party_name_correction_approval_bindings_v1
    AS binding
  WHERE binding.privacy_request_id=p_privacy_request_id
    AND binding.request_decision_version=p_decision_version
    AND binding.transition_receipt_id=v_transition.transition_receipt_id
    AND binding.transition_receipt_digest=p_transition_receipt_digest
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'privacy_response_party_name_correction_delegation_owner_unavailable'
      USING ERRCODE='55000';
  END IF;
  IF v_approval.binding_canonical<>
        ops.canonical_jsonb_v1(v_approval.binding_payload)
     OR v_approval.binding_digest<>encode(extensions.digest(
          v_approval.binding_canonical,'sha256'
        ),'hex') THEN
    RAISE EXCEPTION
      'privacy_response_party_name_correction_delegation_integrity_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT job.* INTO v_child FROM ops.jobs AS job
  WHERE job.id=v_approval.job_id
    AND job.job_type='PRIVACY_RESPONSE_PARTY_NAME_CORRECTION'
    AND job.queue='workflow-worker'
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'privacy_response_party_name_correction_delegation_integrity_invalid'
      USING ERRCODE='23514';
  END IF;
  v_child_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_child.payload),'sha256'
  ),'hex');
  IF jsonb_typeof(v_child.payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_child.payload))<>24
     OR NOT v_child.payload ?& ARRAY[
       'schemaVersion','privacyRequestId','requestDecisionVersion',
       'correctionPlanId','planVersion','planDigest','responseId',
       'expectedResponseVersion','expectedCurrentValueDigest',
       'accessProjectionDigest','privacyIdentityProofReceiptId',
       'privacyIdentityProofReceiptDigest','responseSubmissionReceiptId',
       'responseSubmissionReceiptDigest','responseOriginReceiptId',
       'responseOriginReceiptDigest','approvalTransitionReceiptId',
       'approvalTransitionReceiptDigest','requestedValueSha256',
       'requestedValueAadDigest','requestedValueCiphertextDigest',
       'encryptionKeyId','holdCoverageDigest','queuedAt'
     ]
     OR v_child.payload->>'schemaVersion'<>
        'privacy-response-party-name-correction-job.v1'
     OR v_child.payload->>'privacyRequestId'<>
        p_privacy_request_id::text
     OR v_child.payload->>'requestDecisionVersion'<>
        p_decision_version::text
     OR v_child.payload->>'correctionPlanId'<>
        v_approval.correction_plan_id::text
     OR v_child.payload->>'planDigest'<>btrim(v_approval.plan_digest)
     OR v_child.payload->>'responseId'<>v_approval.response_id::text
     OR v_child.payload->>'expectedResponseVersion'<>
        v_approval.expected_response_version::text
     OR v_child.payload->>'expectedCurrentValueDigest'<>
        btrim(v_approval.expected_current_value_digest)
     OR v_child.payload->>'accessProjectionDigest'<>
        btrim(v_approval.access_projection_digest)
     OR v_child.payload->>'approvalTransitionReceiptId'<>
        v_transition.transition_receipt_id::text
     OR v_child.payload->>'approvalTransitionReceiptDigest'<>
        btrim(p_transition_receipt_digest)
     OR v_child.payload->>'holdCoverageDigest'<>
        btrim(v_approval.hold_coverage_digest)
     OR v_child_digest<>v_approval.job_payload_digest THEN
    RAISE EXCEPTION
      'privacy_response_party_name_correction_delegation_integrity_invalid'
      USING ERRCODE='23514';
  END IF;

  RETURN jsonb_build_object(
    'schemaVersion',
      'privacy-response-party-name-correction-delegation.v1',
    'eventId',v_event.id,'privacyRequestId',p_privacy_request_id,
    'decisionVersion',p_decision_version,
    'transitionReceiptDigest',btrim(p_transition_receipt_digest),
    'jobId',v_child.id,'jobPayloadDigest',btrim(v_child_digest),
    'delegated',true
  );
END
$r6d_q4_party_name_delegation$;
ALTER FUNCTION
  ops.ack_privacy_response_party_name_correction_delegation_v1(
    uuid,uuid,bigint,char(64),uuid,uuid,bigint
  ) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.ack_privacy_response_party_name_correction_delegation_v1(
    uuid,uuid,bigint,char(64),uuid,uuid,bigint
  ) FROM PUBLIC,gurine_control_api,gurine_submission_api,
    gurine_notification_worker,gurine_scheduler;
GRANT EXECUTE ON FUNCTION
  ops.ack_privacy_response_party_name_correction_delegation_v1(
    uuid,uuid,bigint,char(64),uuid,uuid,bigint
  ) TO gurine_workflow_worker;

-- The workflow role keeps read access to response rows but has no direct
-- mutation authority.  Only the completion owner may change party_name, under
-- an exact transaction-local guard, with a one-step response version bump and
-- every other response field preserved (updated_at remains trigger-owned).
REVOKE INSERT,UPDATE ON editorial.responses FROM gurine_workflow_worker;
GRANT SELECT ON editorial.responses TO gurine_workflow_worker;

CREATE OR REPLACE FUNCTION
  editorial.guard_response_party_name_correction_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp
AS $r6d_q4_party_name_guard$
BEGIN
  IF current_user<>'gurine_migrator'
     OR current_setting(
       'gurine.privacy_response_party_name_correction',true
     )<>'1'
     OR NEW.version<>OLD.version+1
     OR NULLIF(btrim(NEW.party_name),'') IS NULL
     OR (to_jsonb(NEW)-ARRAY['party_name','version','updated_at'])
        IS DISTINCT FROM
        (to_jsonb(OLD)-ARRAY['party_name','version','updated_at'])
     OR NEW.updated_at<OLD.updated_at THEN
    RAISE EXCEPTION 'privacy_response_party_name_correction_forbidden'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$r6d_q4_party_name_guard$;
ALTER FUNCTION editorial.guard_response_party_name_correction_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  editorial.guard_response_party_name_correction_v1() FROM PUBLIC;
CREATE TRIGGER editorial_responses_party_name_correction_v1_guard
  BEFORE UPDATE OF party_name ON editorial.responses
  FOR EACH ROW
  EXECUTE FUNCTION editorial.guard_response_party_name_correction_v1();

-- Completion emits a redacted response-scoped domain event.  The event never
-- carries the old/new plaintext, ciphertext, key identifier or job payload.
INSERT INTO ops.event_types(
  event_type,category,schema_version,active,payload_schema_uri,payload_schema
) VALUES(
  'privacy.response_party_name_corrected.v1','DOMAIN',1,true,
  'payloads/privacy_response_party_name_corrected_v1.schema.json',
  $r6d_q4_party_name_event${
    "$schema":"https://json-schema.org/draft/2020-12/schema",
    "$id":"https://gurine.invalid/events/privacy.response_party_name_corrected.v1.schema.json",
    "type":"object",
    "additionalProperties":false,
    "required":[
      "privacyRequestId","correctionPlanId","responseId",
      "responseVersion","partyNameDigest","completionReceiptId",
      "completionReceiptDigest","auditEventId","completedAt"
    ],
    "properties":{
      "privacyRequestId":{"type":"string","format":"uuid"},
      "correctionPlanId":{"type":"string","format":"uuid"},
      "responseId":{"type":"string","format":"uuid"},
      "responseVersion":{"type":"integer","minimum":1},
      "partyNameDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "completionReceiptId":{"type":"string","format":"uuid"},
      "completionReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},
      "auditEventId":{"type":"string","format":"uuid"},
      "completedAt":{"type":"string","format":"date-time"}
    }
  }$r6d_q4_party_name_event$::jsonb
)
ON CONFLICT(event_type) DO UPDATE SET
  category=EXCLUDED.category,
  schema_version=EXCLUDED.schema_version,
  active=EXCLUDED.active,
  payload_schema_uri=EXCLUDED.payload_schema_uri,
  payload_schema=EXCLUDED.payload_schema;

CREATE TABLE
  ops.privacy_response_party_name_correction_completion_receipts_v1 (
  completion_receipt_id uuid PRIMARY KEY,
  job_id uuid NOT NULL UNIQUE REFERENCES ops.jobs(id) ON DELETE RESTRICT,
  job_payload_digest char(64) NOT NULL,
  approval_binding_id uuid NOT NULL UNIQUE
    REFERENCES
      ops.privacy_response_party_name_correction_approval_bindings_v1(
        approval_binding_id
      ) ON DELETE RESTRICT,
  approval_binding_digest char(64) NOT NULL,
  privacy_request_id uuid NOT NULL UNIQUE
    REFERENCES ops.privacy_requests_v2(id) ON DELETE RESTRICT,
  approval_decision_version bigint NOT NULL,
  completion_decision_version bigint NOT NULL,
  correction_plan_id uuid NOT NULL UNIQUE
    REFERENCES ops.privacy_correction_plans_v1(correction_plan_id)
    ON DELETE RESTRICT,
  plan_version bigint NOT NULL,
  plan_digest char(64) NOT NULL,
  response_id uuid NOT NULL
    REFERENCES editorial.responses(id) ON DELETE RESTRICT,
  prior_response_version bigint NOT NULL,
  response_version bigint NOT NULL,
  prior_party_name_digest char(64) NOT NULL,
  party_name_digest char(64) NOT NULL,
  hold_coverage_digest char(64) NOT NULL,
  approval_transition_receipt_id uuid NOT NULL UNIQUE,
  approval_transition_receipt_digest char(64) NOT NULL UNIQUE,
  audit_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  outbox_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  outbox_event_digest char(64) NOT NULL UNIQUE,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  completed_at timestamptz NOT NULL,
  CONSTRAINT privacy_response_party_name_completion_transition_fk
    FOREIGN KEY(
      approval_transition_receipt_id,privacy_request_id
    ) REFERENCES ops.privacy_request_transition_receipts_v2(
      transition_receipt_id,privacy_request_id
    ) ON DELETE RESTRICT,
  CONSTRAINT privacy_response_party_name_completion_shape_ck CHECK(
    approval_decision_version>0
    AND completion_decision_version=approval_decision_version+1
    AND plan_version>0 AND prior_response_version>0
    AND response_version=prior_response_version+1
    AND ops.r6d_lower_sha256(job_payload_digest)
    AND ops.r6d_lower_sha256(approval_binding_digest)
    AND ops.r6d_lower_sha256(plan_digest)
    AND ops.r6d_lower_sha256(prior_party_name_digest)
    AND ops.r6d_lower_sha256(party_name_digest)
    AND ops.r6d_lower_sha256(hold_coverage_digest)
    AND ops.r6d_lower_sha256(approval_transition_receipt_digest)
    AND ops.r6d_lower_sha256(outbox_event_digest)
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_canonical=ops.canonical_jsonb_v1(receipt_payload)
    AND receipt_digest=encode(
      extensions.digest(receipt_canonical,'sha256'),'hex'
    )
    AND receipt_payload->>'schemaVersion'=
      'privacy-response-party-name-correction-completion-receipt.v1'
    AND receipt_payload=jsonb_build_object(
      'schemaVersion',
        'privacy-response-party-name-correction-completion-receipt.v1',
      'completionReceiptId',completion_receipt_id,
      'jobId',job_id,'jobPayloadDigest',btrim(job_payload_digest),
      'privacyRequestId',privacy_request_id,
      'approvalDecisionVersion',approval_decision_version,
      'completionDecisionVersion',completion_decision_version,
      'correctionPlanId',correction_plan_id,
      'planVersion',plan_version,'planDigest',btrim(plan_digest),
      'approvalBindingId',approval_binding_id,
      'approvalBindingDigest',btrim(approval_binding_digest),
      'responseId',response_id,
      'priorResponseVersion',prior_response_version,
      'responseVersion',response_version,
      'priorPartyNameDigest',btrim(prior_party_name_digest),
      'partyNameDigest',btrim(party_name_digest),
      'holdCoverageDigest',btrim(hold_coverage_digest),
      'approvalTransitionReceiptId',approval_transition_receipt_id,
      'approvalTransitionReceiptDigest',
        btrim(approval_transition_receipt_digest),
      'auditEventId',audit_event_id,'completedAt',completed_at
    )
    AND NOT receipt_payload ?| ARRAY[
      'partyName','priorPartyName','requestedValue','plaintext',
      'requestedValueCiphertextBase64','encryptionKeyId'
    ]
  )
);
ALTER TABLE
  ops.privacy_response_party_name_correction_completion_receipts_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON
  ops.privacy_response_party_name_correction_completion_receipts_v1
  FROM PUBLIC,gurine_control_api,gurine_submission_api,
    gurine_workflow_worker,gurine_notification_worker,gurine_scheduler;
GRANT SELECT ON
  ops.privacy_response_party_name_correction_completion_receipts_v1
  TO gurine_auditor;
CREATE TRIGGER privacy_response_party_name_completion_receipts_v1_immutable
  BEFORE UPDATE OR DELETE ON
    ops.privacy_response_party_name_correction_completion_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE OR REPLACE FUNCTION
  ops.load_privacy_response_party_name_correction_job_v1(
    p_job_id uuid,
    p_lease_token uuid,
    p_fencing_token bigint
  ) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,intake,extensions,pg_temp
AS $r6d_q4_load_party_name_job$
DECLARE
  v_job ops.jobs%ROWTYPE;
  v_approval
    ops.privacy_response_party_name_correction_approval_bindings_v1%ROWTYPE;
  v_plan ops.privacy_correction_plans_v1%ROWTYPE;
  v_plan_binding
    ops.privacy_response_party_name_correction_plan_bindings_v1%ROWTYPE;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_response editorial.responses%ROWTYPE;
  v_completion
    ops.privacy_response_party_name_correction_completion_receipts_v1%ROWTYPE;
  v_job_digest char(64);
  v_ciphertext_digest char(64);
  v_current_digest char(64);
  v_projection jsonb;
  v_hold jsonb;
BEGIN
  IF p_job_id IS NULL OR p_lease_token IS NULL
     OR p_fencing_token IS NULL OR p_fencing_token<1
     OR p_job_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_lease_token='00000000-0000-0000-0000-000000000000'::uuid THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_input_invalid'
      USING ERRCODE='22023';
  END IF;
  IF NOT pg_has_role(session_user,'gurine_workflow_worker','MEMBER') THEN
    RAISE EXCEPTION 'privacy_response_party_name_worker_required'
      USING ERRCODE='42501';
  END IF;
  SELECT job.* INTO v_job FROM ops.jobs AS job
  WHERE job.id=p_job_id
    AND job.job_type='PRIVACY_RESPONSE_PARTY_NAME_CORRECTION'
    AND job.queue='workflow-worker' AND job.status='RUNNING'
    AND job.lease_token=p_lease_token
    AND job.fencing_token=p_fencing_token
    AND job.lease_expires_at>clock_timestamp()
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_fence_stale'
      USING ERRCODE='40001';
  END IF;
  IF jsonb_typeof(v_job.payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_job.payload))<>24
     OR NOT v_job.payload ?& ARRAY[
       'schemaVersion','privacyRequestId','requestDecisionVersion',
       'correctionPlanId','planVersion','planDigest','responseId',
       'expectedResponseVersion','expectedCurrentValueDigest',
       'accessProjectionDigest','privacyIdentityProofReceiptId',
       'privacyIdentityProofReceiptDigest','responseSubmissionReceiptId',
       'responseSubmissionReceiptDigest','responseOriginReceiptId',
       'responseOriginReceiptDigest','approvalTransitionReceiptId',
       'approvalTransitionReceiptDigest','requestedValueSha256',
       'requestedValueAadDigest','requestedValueCiphertextDigest',
       'encryptionKeyId','holdCoverageDigest','queuedAt'
     ]
     OR v_job.payload->>'schemaVersion'<>
        'privacy-response-party-name-correction-job.v1' THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_payload_invalid'
      USING ERRCODE='55000';
  END IF;
  v_job_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_job.payload),'sha256'
  ),'hex');
  SELECT binding.* INTO v_approval
  FROM ops.privacy_response_party_name_correction_approval_bindings_v1
    AS binding
  WHERE binding.job_id=v_job.id
    AND binding.job_payload_digest=v_job_digest
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_authority_missing'
      USING ERRCODE='55000';
  END IF;
  SELECT plan.* INTO v_plan
  FROM ops.privacy_correction_plans_v1 AS plan
  WHERE plan.correction_plan_id=v_approval.correction_plan_id
    AND plan.plan_version=v_approval.plan_version
    AND plan.plan_digest=v_approval.plan_digest
  FOR SHARE;
  SELECT binding.* INTO v_plan_binding
  FROM ops.privacy_response_party_name_correction_plan_bindings_v1
    AS binding
  WHERE binding.correction_plan_id=v_approval.correction_plan_id
    AND binding.binding_digest=v_approval.plan_binding_digest
  FOR SHARE;
  SELECT request.* INTO v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=v_approval.privacy_request_id FOR SHARE;
  SELECT response.* INTO v_response
  FROM editorial.responses AS response
  WHERE response.id=v_approval.response_id FOR SHARE;
  SELECT receipt.* INTO v_completion
  FROM ops.privacy_response_party_name_correction_completion_receipts_v1
    AS receipt
  WHERE receipt.job_id=v_job.id FOR SHARE;
  IF v_plan.correction_plan_id IS NULL
     OR v_plan_binding.correction_plan_id IS NULL
     OR v_request.id IS NULL OR v_response.id IS NULL
     OR v_plan.privacy_request_id<>v_approval.privacy_request_id
     OR v_plan.request_decision_version+1<>
        v_approval.request_decision_version
     OR v_plan.target_object_type<>'RESPONSE'
     OR v_plan.target_object_id<>v_approval.response_id
     OR v_plan.field_path<>'/partyName'
     OR v_plan.current_value_digest<>
        v_approval.expected_current_value_digest
     OR v_plan_binding.privacy_request_id<>v_approval.privacy_request_id
     OR v_plan_binding.response_id<>v_approval.response_id
     OR v_plan_binding.expected_response_version<>
        v_approval.expected_response_version
     OR v_plan_binding.expected_current_value_digest<>
        v_approval.expected_current_value_digest
     OR v_plan_binding.access_projection_digest<>
        v_approval.access_projection_digest
     OR v_plan_binding.privacy_identity_proof_receipt_id<>
        v_approval.privacy_identity_proof_receipt_id
     OR v_plan_binding.privacy_identity_proof_receipt_digest<>
        v_approval.privacy_identity_proof_receipt_digest
     OR v_plan_binding.response_submission_receipt_id<>
        v_approval.response_submission_receipt_id
     OR v_plan_binding.response_submission_receipt_digest<>
        v_approval.response_submission_receipt_digest
     OR v_plan_binding.response_origin_receipt_id<>
        v_approval.response_origin_receipt_id
     OR v_plan_binding.response_origin_receipt_digest<>
        v_approval.response_origin_receipt_digest
     OR v_request.request_type<>'CORRECTION'
     OR v_request.identity_state<>'VERIFIED' THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_authority_invalid'
      USING ERRCODE='55000';
  END IF;
  IF v_job.payload->>'privacyRequestId'<>
       v_approval.privacy_request_id::text
     OR v_job.payload->>'requestDecisionVersion'<>
        v_approval.request_decision_version::text
     OR v_job.payload->>'correctionPlanId'<>
        v_approval.correction_plan_id::text
     OR v_job.payload->>'planVersion'<>v_approval.plan_version::text
     OR v_job.payload->>'planDigest'<>btrim(v_approval.plan_digest)
     OR v_job.payload->>'responseId'<>v_approval.response_id::text
     OR v_job.payload->>'expectedResponseVersion'<>
        v_approval.expected_response_version::text
     OR v_job.payload->>'expectedCurrentValueDigest'<>
        btrim(v_approval.expected_current_value_digest)
     OR v_job.payload->>'accessProjectionDigest'<>
        btrim(v_approval.access_projection_digest)
     OR v_job.payload->>'privacyIdentityProofReceiptId'<>
        v_approval.privacy_identity_proof_receipt_id::text
     OR v_job.payload->>'privacyIdentityProofReceiptDigest'<>
        btrim(v_approval.privacy_identity_proof_receipt_digest)
     OR v_job.payload->>'responseSubmissionReceiptId'<>
        v_approval.response_submission_receipt_id::text
     OR v_job.payload->>'responseSubmissionReceiptDigest'<>
        btrim(v_approval.response_submission_receipt_digest)
     OR v_job.payload->>'responseOriginReceiptId'<>
        v_approval.response_origin_receipt_id::text
     OR v_job.payload->>'responseOriginReceiptDigest'<>
        btrim(v_approval.response_origin_receipt_digest)
     OR v_job.payload->>'approvalTransitionReceiptId'<>
        v_approval.transition_receipt_id::text
     OR v_job.payload->>'approvalTransitionReceiptDigest'<>
        btrim(v_approval.transition_receipt_digest)
     OR v_job.payload->>'requestedValueSha256'<>
        btrim(v_plan.requested_value_sha256)
     OR v_job.payload->>'requestedValueAadDigest'<>
        btrim(v_plan.requested_value_aad_digest)
     OR v_job.payload->>'requestedValueCiphertextDigest'<>
        btrim(v_plan.requested_value_ciphertext_digest)
     OR v_job.payload->>'encryptionKeyId'<>v_plan.encryption_key_id
     OR v_job.payload->>'holdCoverageDigest'<>
        btrim(v_approval.hold_coverage_digest)
     OR (v_job.payload->>'queuedAt')::timestamptz<>
        v_approval.approved_at THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_payload_invalid'
      USING ERRCODE='55000';
  END IF;
  v_ciphertext_digest:=encode(extensions.digest(
    v_plan.requested_value_ciphertext,'sha256'
  ),'hex');
  IF v_ciphertext_digest<>v_plan.requested_value_ciphertext_digest
     OR v_plan.requested_value_aad_digest<>
        ops.r6d_nul5_sha256_v1(
          'ops.privacy_correction_plans_v1','requested_value_ciphertext',
          v_plan.correction_plan_id::text,
          'privacy-correction-requested-value','1'
        )
     OR NOT ops.r6d_field_envelope_v1_is_valid(
       v_plan.requested_value_ciphertext,v_plan.encryption_key_id
     ) THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_ciphertext_invalid'
      USING ERRCODE='55000';
  END IF;

  v_current_digest:=encode(extensions.digest(
    convert_to(v_response.party_name,'UTF8'),'sha256'
  ),'hex');
  IF v_completion.completion_receipt_id IS NULL THEN
    IF v_request.state<>'APPROVED'
       OR v_request.decision_version<>
          v_approval.request_decision_version
       OR v_response.version<>v_approval.expected_response_version
       OR v_current_digest<>v_approval.expected_current_value_digest THEN
      RAISE EXCEPTION 'privacy_response_party_name_job_state_stale'
        USING ERRCODE='40001';
    END IF;
    v_projection:=ops.read_privacy_response_party_name_access_v1(
      v_request.id,v_response.id
    );
    IF (v_projection->>'responseVersion')::bigint<>
         v_approval.expected_response_version
       OR v_projection->>'currentValueDigest'<>
          btrim(v_approval.expected_current_value_digest)
       OR v_projection->>'projectionDigest'<>
          btrim(v_approval.access_projection_digest) THEN
      RAISE EXCEPTION 'privacy_response_party_name_job_state_stale'
        USING ERRCODE='40001';
    END IF;
    v_hold:=ops.r6d_privacy_request_legal_hold_coverage_v1(
      v_request.id,clock_timestamp()
    );
    IF COALESCE((v_hold->>'active')::boolean,true) THEN
      RAISE EXCEPTION 'privacy_correction_legal_hold_active'
        USING ERRCODE='55000';
    END IF;
  ELSE
    IF v_completion.approval_binding_id<>v_approval.approval_binding_id
       OR v_completion.approval_binding_digest<>v_approval.binding_digest
       OR v_completion.privacy_request_id<>v_request.id
       OR v_completion.approval_decision_version<>
          v_approval.request_decision_version
       OR v_completion.correction_plan_id<>v_plan.correction_plan_id
       OR v_completion.response_id<>v_response.id
       OR v_completion.response_version<>
          v_approval.expected_response_version+1
       OR v_completion.party_name_digest<>
          v_plan.requested_value_sha256
       OR v_request.state<>'COMPLETED'
       OR v_request.decision_version<>
          v_approval.request_decision_version+1
       OR v_response.version<>v_completion.response_version
       OR v_current_digest<>v_completion.party_name_digest THEN
      RAISE EXCEPTION 'privacy_response_party_name_replay_invalid'
        USING ERRCODE='55000';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'schemaVersion','privacy-response-party-name-correction-job-load.v1',
    'jobId',v_job.id,'correctionPlanId',v_plan.correction_plan_id,
    'privacyRequestId',v_request.id,'responseId',v_response.id,
    'expectedResponseVersion',v_approval.expected_response_version,
    'expectedCurrentValueDigest',
      btrim(v_approval.expected_current_value_digest),
    'requestedValueCiphertextBase64',
      replace(encode(v_plan.requested_value_ciphertext,'base64'),E'\n',''),
    'requestedValueSha256',btrim(v_plan.requested_value_sha256),
    'requestedValueAadDigest',btrim(v_plan.requested_value_aad_digest),
    'requestedValueCiphertextDigest',
      btrim(v_plan.requested_value_ciphertext_digest),
    'encryptionKeyId',v_plan.encryption_key_id,
    'planDigest',btrim(v_plan.plan_digest),
    'approvalTransitionReceiptId',v_approval.transition_receipt_id,
    'approvalTransitionReceiptDigest',
      btrim(v_approval.transition_receipt_digest),
    'jobPayloadDigest',btrim(v_job_digest)
  );
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range
    OR datetime_field_overflow THEN
  RAISE EXCEPTION 'privacy_response_party_name_job_payload_invalid'
    USING ERRCODE='55000';
END
$r6d_q4_load_party_name_job$;
ALTER FUNCTION ops.load_privacy_response_party_name_correction_job_v1(
  uuid,uuid,bigint
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.load_privacy_response_party_name_correction_job_v1(uuid,uuid,bigint)
  FROM PUBLIC,gurine_control_api,gurine_submission_api,
    gurine_notification_worker,gurine_scheduler;
GRANT EXECUTE ON FUNCTION
  ops.load_privacy_response_party_name_correction_job_v1(uuid,uuid,bigint)
  TO gurine_workflow_worker;

CREATE OR REPLACE FUNCTION
  ops.execute_privacy_response_party_name_correction_job_v1(
    p_job_id uuid,
    p_lease_token uuid,
    p_fencing_token bigint,
    p_party_name text,
    p_party_name_digest char(64)
  ) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,intake,extensions,pg_temp
AS $r6d_q4_execute_party_name_job$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_job ops.jobs%ROWTYPE;
  v_approval
    ops.privacy_response_party_name_correction_approval_bindings_v1%ROWTYPE;
  v_plan ops.privacy_correction_plans_v1%ROWTYPE;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_response editorial.responses%ROWTYPE;
  v_completion
    ops.privacy_response_party_name_correction_completion_receipts_v1%ROWTYPE;
  v_projection jsonb;
  v_hold jsonb;
  v_prior_digest char(64);
  v_job_digest char(64);
  v_completion_id uuid:=gen_random_uuid();
  v_completion_decision_version bigint;
  v_response_version bigint;
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
  v_audit_id uuid;
  v_event_payload jsonb;
  v_outbox_id uuid;
  v_outbox_digest char(64);
  v_affected integer;
BEGIN
  IF p_job_id IS NULL OR p_lease_token IS NULL
     OR p_fencing_token IS NULL OR p_fencing_token<1
     OR p_party_name IS NULL OR NULLIF(btrim(p_party_name),'') IS NULL
     OR octet_length(p_party_name) NOT BETWEEN 1 AND 65536
     OR NOT COALESCE(ops.r6d_lower_sha256(p_party_name_digest),false)
     OR encode(extensions.digest(
       convert_to(p_party_name,'UTF8'),'sha256'
     ),'hex')<>p_party_name_digest THEN
    RAISE EXCEPTION 'privacy_response_party_name_plaintext_invalid'
      USING ERRCODE='22023';
  END IF;
  IF NOT pg_has_role(session_user,'gurine_workflow_worker','MEMBER') THEN
    RAISE EXCEPTION 'privacy_response_party_name_worker_required'
      USING ERRCODE='42501';
  END IF;
  SELECT job.* INTO v_job FROM ops.jobs AS job
  WHERE job.id=p_job_id
    AND job.job_type='PRIVACY_RESPONSE_PARTY_NAME_CORRECTION'
    AND job.queue='workflow-worker' AND job.status='RUNNING'
    AND job.lease_token=p_lease_token
    AND job.fencing_token=p_fencing_token
    AND job.lease_expires_at>clock_timestamp()
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_fence_stale'
      USING ERRCODE='40001';
  END IF;
  -- Reuse the loader's closed authority proof after serializing on the job.
  PERFORM ops.load_privacy_response_party_name_correction_job_v1(
    p_job_id,p_lease_token,p_fencing_token
  );
  v_job_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_job.payload),'sha256'
  ),'hex');
  SELECT binding.* INTO STRICT v_approval
  FROM ops.privacy_response_party_name_correction_approval_bindings_v1
    AS binding
  WHERE binding.job_id=v_job.id
    AND binding.job_payload_digest=v_job_digest
  FOR SHARE;
  SELECT plan.* INTO STRICT v_plan
  FROM ops.privacy_correction_plans_v1 AS plan
  WHERE plan.correction_plan_id=v_approval.correction_plan_id
    AND plan.plan_digest=v_approval.plan_digest
  FOR SHARE;
  SELECT request.* INTO STRICT v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=v_approval.privacy_request_id FOR UPDATE;
  SELECT response.* INTO STRICT v_response
  FROM editorial.responses AS response
  WHERE response.id=v_approval.response_id FOR UPDATE;
  SELECT receipt.* INTO v_completion
  FROM ops.privacy_response_party_name_correction_completion_receipts_v1
    AS receipt
  WHERE receipt.job_id=v_job.id FOR SHARE;
  IF p_party_name_digest<>v_plan.requested_value_sha256 THEN
    RAISE EXCEPTION 'privacy_response_party_name_plaintext_invalid'
      USING ERRCODE='22023';
  END IF;
  IF v_completion.completion_receipt_id IS NOT NULL THEN
    IF v_completion.job_payload_digest<>v_job_digest
       OR v_completion.approval_binding_id<>v_approval.approval_binding_id
       OR v_completion.approval_binding_digest<>v_approval.binding_digest
       OR v_completion.privacy_request_id<>v_request.id
       OR v_completion.correction_plan_id<>v_plan.correction_plan_id
       OR v_completion.response_id<>v_response.id
       OR v_completion.response_version<>v_response.version
       OR v_completion.party_name_digest<>p_party_name_digest
       OR v_request.state<>'COMPLETED'
       OR v_request.decision_version<>
          v_completion.completion_decision_version
       OR encode(extensions.digest(
            convert_to(v_response.party_name,'UTF8'),'sha256'
          ),'hex')<>v_completion.party_name_digest THEN
      RAISE EXCEPTION 'privacy_response_party_name_replay_invalid'
        USING ERRCODE='55000';
    END IF;
    RETURN jsonb_build_object(
      'schemaVersion',
        'privacy-response-party-name-correction-completion.v1',
      'status','COMPLETED','jobId',v_job.id,
      'privacyRequestId',v_completion.privacy_request_id,
      'correctionPlanId',v_completion.correction_plan_id,
      'responseId',v_completion.response_id,
      'responseVersion',v_completion.response_version,
      'partyNameDigest',btrim(v_completion.party_name_digest),
      'completionReceiptId',v_completion.completion_receipt_id,
      'completionReceiptDigest',btrim(v_completion.receipt_digest),
      'auditEventId',v_completion.audit_event_id,
      'outboxEventIds',jsonb_build_array(v_completion.outbox_event_id),
      'completedAt',v_completion.completed_at,'replayed',true
    );
  END IF;

  IF v_request.state<>'APPROVED'
     OR v_request.decision_version<>v_approval.request_decision_version
     OR v_response.version<>v_approval.expected_response_version THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_state_stale'
      USING ERRCODE='40001';
  END IF;
  v_prior_digest:=encode(extensions.digest(
    convert_to(v_response.party_name,'UTF8'),'sha256'
  ),'hex');
  IF v_prior_digest<>v_approval.expected_current_value_digest THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_state_stale'
      USING ERRCODE='40001';
  END IF;

  -- SHARE locks prevent a new hold anchor/placement from crossing the final
  -- hold proof and target mutation. Hold releases may only make this gate more
  -- conservative, never allow a blocked correction.
  LOCK TABLE ops.legal_hold_target_anchors,
    ops.legal_hold_placement_receipts_v2 IN SHARE MODE;
  v_projection:=ops.read_privacy_response_party_name_access_v1(
    v_request.id,v_response.id
  );
  IF (v_projection->>'responseVersion')::bigint<>
       v_approval.expected_response_version
     OR v_projection->>'currentValueDigest'<>
        btrim(v_approval.expected_current_value_digest)
     OR v_projection->>'projectionDigest'<>
        btrim(v_approval.access_projection_digest) THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_state_stale'
      USING ERRCODE='40001';
  END IF;
  v_hold:=ops.r6d_privacy_request_legal_hold_coverage_v1(
    v_request.id,clock_timestamp()
  );
  IF COALESCE((v_hold->>'active')::boolean,true) THEN
    RAISE EXCEPTION 'privacy_correction_legal_hold_active'
      USING ERRCODE='55000';
  END IF;
  IF v_job.lease_expires_at<=clock_timestamp() THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_fence_stale'
      USING ERRCODE='40001';
  END IF;

  v_completion_decision_version:=v_approval.request_decision_version+1;
  v_response_version:=v_approval.expected_response_version+1;
  v_audit_id:=ops.append_audit_event(
    'privacy-response-party-name-correction:'||
      v_plan.correction_plan_id::text,
    'SERVICE','workflow-worker',NULL::uuid,
    'privacy.response_party_name.correction.complete','RESPONSE',
    v_response.id::text,NULL,'SUCCESS',NULL,p_job_id,
    jsonb_build_object(
      'jobId',v_job.id,'jobPayloadDigest',btrim(v_job_digest),
      'completionReceiptId',v_completion_id,
      'privacyRequestId',v_request.id,
      'approvalDecisionVersion',v_approval.request_decision_version,
      'completionDecisionVersion',v_completion_decision_version,
      'correctionPlanId',v_plan.correction_plan_id,
      'planDigest',btrim(v_plan.plan_digest),
      'approvalBindingDigest',btrim(v_approval.binding_digest),
      'priorResponseVersion',v_response.version,
      'responseVersion',v_response_version,
      'priorPartyNameDigest',btrim(v_prior_digest),
      'partyNameDigest',btrim(p_party_name_digest),
      'holdCoverageDigest',v_hold->>'coverageDigest',
      'approvalTransitionReceiptDigest',
        btrim(v_approval.transition_receipt_digest)
    )
  );
  v_receipt_payload:=jsonb_build_object(
    'schemaVersion',
      'privacy-response-party-name-correction-completion-receipt.v1',
    'completionReceiptId',v_completion_id,'jobId',v_job.id,
    'jobPayloadDigest',btrim(v_job_digest),
    'privacyRequestId',v_request.id,
    'approvalDecisionVersion',v_approval.request_decision_version,
    'completionDecisionVersion',v_completion_decision_version,
    'correctionPlanId',v_plan.correction_plan_id,
    'planVersion',v_plan.plan_version,'planDigest',btrim(v_plan.plan_digest),
    'approvalBindingId',v_approval.approval_binding_id,
    'approvalBindingDigest',btrim(v_approval.binding_digest),
    'responseId',v_response.id,
    'priorResponseVersion',v_response.version,
    'responseVersion',v_response_version,
    'priorPartyNameDigest',btrim(v_prior_digest),
    'partyNameDigest',btrim(p_party_name_digest),
    'holdCoverageDigest',v_hold->>'coverageDigest',
    'approvalTransitionReceiptId',v_approval.transition_receipt_id,
    'approvalTransitionReceiptDigest',
      btrim(v_approval.transition_receipt_digest),
    'auditEventId',v_audit_id,'completedAt',v_now
  );
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_receipt_digest:=encode(extensions.digest(
    v_receipt_canonical,'sha256'
  ),'hex');
  v_event_payload:=jsonb_build_object(
    'privacyRequestId',v_request.id,
    'correctionPlanId',v_plan.correction_plan_id,
    'responseId',v_response.id,'responseVersion',v_response_version,
    'partyNameDigest',btrim(p_party_name_digest),
    'completionReceiptId',v_completion_id,
    'completionReceiptDigest',btrim(v_receipt_digest),
    'auditEventId',v_audit_id,'completedAt',v_now
  );
  v_outbox_id:=ops.enqueue_outbox(
    'editorial_response',v_response.id::text,v_response_version,
    'privacy.response_party_name_corrected.v1',v_event_payload,v_now
  );
  v_outbox_digest:=ops.r6d_outbox_envelope_digest_v1(v_outbox_id);
  IF v_outbox_digest IS NULL THEN
    RAISE EXCEPTION 'privacy_response_party_name_completion_event_invalid'
      USING ERRCODE='55000';
  END IF;

  PERFORM set_config(
    'gurine.privacy_response_party_name_correction','1',true
  );
  UPDATE editorial.responses
  SET party_name=p_party_name,version=v_response_version
  WHERE id=v_response.id AND version=v_response.version
    AND encode(extensions.digest(
      convert_to(party_name,'UTF8'),'sha256'
    ),'hex')=v_prior_digest;
  GET DIAGNOSTICS v_affected=ROW_COUNT;
  IF v_affected<>1 THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_state_stale'
      USING ERRCODE='40001';
  END IF;
  PERFORM set_config('gurine.privacy_request_transition_v2','1',true);
  UPDATE ops.privacy_requests_v2
  SET state='COMPLETED',decision_version=v_completion_decision_version,
      updated_at=v_now
  WHERE id=v_request.id AND state='APPROVED'
    AND decision_version=v_approval.request_decision_version;
  GET DIAGNOSTICS v_affected=ROW_COUNT;
  IF v_affected<>1 THEN
    RAISE EXCEPTION 'privacy_response_party_name_job_state_stale'
      USING ERRCODE='40001';
  END IF;
  INSERT INTO
    ops.privacy_response_party_name_correction_completion_receipts_v1(
      completion_receipt_id,job_id,job_payload_digest,
      approval_binding_id,approval_binding_digest,privacy_request_id,
      approval_decision_version,completion_decision_version,
      correction_plan_id,plan_version,plan_digest,response_id,
      prior_response_version,response_version,prior_party_name_digest,
      party_name_digest,hold_coverage_digest,
      approval_transition_receipt_id,
      approval_transition_receipt_digest,audit_event_id,outbox_event_id,
      outbox_event_digest,receipt_payload,receipt_canonical,
      receipt_digest,completed_at
    ) VALUES(
      v_completion_id,v_job.id,v_job_digest,
      v_approval.approval_binding_id,v_approval.binding_digest,v_request.id,
      v_approval.request_decision_version,v_completion_decision_version,
      v_plan.correction_plan_id,v_plan.plan_version,v_plan.plan_digest,
      v_response.id,v_response.version,v_response_version,v_prior_digest,
      p_party_name_digest,(v_hold->>'coverageDigest')::char(64),
      v_approval.transition_receipt_id,v_approval.transition_receipt_digest,
      v_audit_id,v_outbox_id,v_outbox_digest,v_receipt_payload,
      v_receipt_canonical,v_receipt_digest,v_now
    );

  RETURN jsonb_build_object(
    'schemaVersion',
      'privacy-response-party-name-correction-completion.v1',
    'status','COMPLETED','jobId',v_job.id,
    'privacyRequestId',v_request.id,
    'correctionPlanId',v_plan.correction_plan_id,
    'responseId',v_response.id,'responseVersion',v_response_version,
    'partyNameDigest',btrim(p_party_name_digest),
    'completionReceiptId',v_completion_id,
    'completionReceiptDigest',btrim(v_receipt_digest),
    'auditEventId',v_audit_id,
    'outboxEventIds',jsonb_build_array(v_outbox_id),
    'completedAt',v_now,'replayed',false
  );
EXCEPTION
  WHEN no_data_found THEN
  RAISE EXCEPTION 'privacy_response_party_name_job_authority_missing'
    USING ERRCODE='55000';
END
$r6d_q4_execute_party_name_job$;
ALTER FUNCTION ops.execute_privacy_response_party_name_correction_job_v1(
  uuid,uuid,bigint,text,char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.execute_privacy_response_party_name_correction_job_v1(
    uuid,uuid,bigint,text,char(64)
  ) FROM PUBLIC,gurine_control_api,gurine_submission_api,
    gurine_notification_worker,gurine_scheduler;
GRANT EXECUTE ON FUNCTION
  ops.execute_privacy_response_party_name_correction_job_v1(
    uuid,uuid,bigint,text,char(64)
  ) TO gurine_workflow_worker;


-- Restore the canonical workspace owner with Q4 completion authority. The
-- pre-Q4 reader remains private for approval-time proof before completion.
CREATE OR REPLACE FUNCTION ops.read_privacy_retention_request_workspace_v2(
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
SET timezone='UTC'
AS $workspace$
DECLARE
  v_nil_uuid constant uuid:='00000000-0000-0000-0000-000000000000'::uuid;
  v_as_of timestamptz:=statement_timestamp();
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_transition ops.privacy_request_transition_receipts_v2%ROWTYPE;
  v_identity ops.privacy_request_identity_receipts_v2%ROWTYPE;
  v_extension ops.privacy_request_extension_receipts_v2%ROWTYPE;
  v_refusal ops.privacy_request_refusal_receipts_v2%ROWTYPE;
  v_notice ops.privacy_request_notice_receipts_v2%ROWTYPE;
  v_policy ops.privacy_response_calendar_policies_v1%ROWTYPE;
  v_calendar ops.business_calendar_versions%ROWTYPE;
  v_hold_coverage jsonb;
  v_hold_payload jsonb;
  v_active_cells jsonb;
  v_active_hold_ids jsonb:='[]'::jsonb;
  v_decisions jsonb:='[]'::jsonb;
  v_expected_version bigint:=0;
  v_expected_state text:='RECEIVED';
  v_identity_seen boolean:=false;
  v_extension_sequence integer:=0;
  v_notice_sequence bigint:=0;
  v_due_cursor timestamptz;
  v_current_extension_id uuid;
  v_current_extension_digest char(64);
  v_current_refusal_id uuid;
  v_current_refusal_digest char(64);
  v_current_notice_id uuid;
  v_current_notice_digest char(64);
  v_receipt_count bigint;
  v_completion
    ops.privacy_response_party_name_correction_completion_receipts_v1%ROWTYPE;
  v_completion_approval
    ops.privacy_response_party_name_correction_approval_bindings_v1%ROWTYPE;
  v_completion_plan ops.privacy_correction_plans_v1%ROWTYPE;
  v_completion_plan_binding
    ops.privacy_response_party_name_correction_plan_bindings_v1%ROWTYPE;
  v_completion_job ops.jobs%ROWTYPE;
  v_completion_transition
    ops.privacy_request_transition_receipts_v2%ROWTYPE;
  v_completion_response editorial.responses%ROWTYPE;
  v_completion_audit ops.audit_events%ROWTYPE;
  v_completion_event ops.outbox%ROWTYPE;
  v_access_projection jsonb;
  v_access_response_ids uuid[];
  v_access_response_count bigint:=0;
  v_current_party_name_digest char(64);
  v_expected_completion_audit jsonb;
  v_expected_completion_event jsonb;
BEGIN
  IF p_request_id IS NULL OR p_request_id=v_nil_uuid THEN
    RAISE EXCEPTION 'privacy_retention_request_id_invalid'
      USING ERRCODE='22023';
  END IF;

  SELECT request.* INTO v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=p_request_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- A row is readable only through its exact immutable, creation-time schedule
  -- binding.  The reader does not silently rebind it to a newer schedule.
  IF NOT EXISTS(
    SELECT 1
    FROM ops.record_class_schedules AS schedule
    JOIN ops.r6d_record_class_catalog AS catalog
      ON catalog.record_class=schedule.record_class
    WHERE (schedule.id,schedule.record_class,schedule.schedule_digest)=(
      v_request.retention_schedule_id,v_request.retention_record_class,
      v_request.retention_schedule_digest
    )
      AND schedule.record_class='PRIVACY_REQUEST'
      AND schedule.effective_at<=v_request.created_at
      AND schedule.review_expires_at>v_request.created_at
      AND schedule.terminal_action=catalog.required_terminal_action
      AND (catalog.required_trigger_kind IS NULL
        OR schedule.trigger_kind=catalog.required_trigger_kind)
      AND (catalog.required_active_duration_seconds IS NULL
        OR schedule.active_duration_seconds=
           catalog.required_active_duration_seconds)
      AND (catalog.required_backup_duration_seconds IS NULL
        OR schedule.backup_duration_seconds=
           catalog.required_backup_duration_seconds)
      AND (catalog.required_lawful_basis IS NULL
        OR schedule.lawful_basis=catalog.required_lawful_basis)
  ) THEN
    RAISE EXCEPTION 'privacy_retention_request_schedule_binding_invalid'
      USING ERRCODE='55000';
  END IF;

  IF v_request.decision_version>100
     OR v_request.updated_at<v_request.created_at
     OR char_length(v_request.jurisdiction) NOT BETWEEN 2 AND 64
     OR btrim(v_request.jurisdiction)<>v_request.jurisdiction
     OR NOT ops.r6d_lower_sha256(v_request.scope_sha256) THEN
    RAISE EXCEPTION 'privacy_retention_request_root_invalid'
      USING ERRCODE='55000';
  END IF;

  IF v_request.identity_state='PENDING_VERIFICATION' THEN
    IF v_request.state<>'RECEIVED'
       OR v_request.decision_version<>0
       OR v_request.identity_verified_at IS NOT NULL
       OR v_request.due_at IS NOT NULL
       OR num_nonnulls(
         v_request.response_policy_id,v_request.response_policy_revision,
         v_request.response_policy_digest,v_request.calendar_version_id,
         v_request.calendar_digest,v_request.current_identity_receipt_id,
         v_request.current_identity_receipt_digest,
         v_request.current_extension_receipt_id,
         v_request.current_extension_receipt_digest,
         v_request.current_refusal_receipt_id,
         v_request.current_refusal_receipt_digest,
         v_request.current_notice_receipt_id,
         v_request.current_notice_receipt_digest
       )<>0 THEN
      RAISE EXCEPTION 'privacy_retention_request_pending_closure_invalid'
        USING ERRCODE='55000';
    END IF;
  ELSIF v_request.identity_state='VERIFIED' THEN
    IF v_request.decision_version<1
       OR v_request.identity_verified_at IS NULL
       OR v_request.due_at IS NULL
       OR v_request.due_at<=v_request.identity_verified_at
       OR num_nonnulls(
         v_request.response_policy_id,v_request.response_policy_revision,
         v_request.response_policy_digest,v_request.calendar_version_id,
         v_request.calendar_digest,v_request.current_identity_receipt_id,
         v_request.current_identity_receipt_digest
       )<>7 THEN
      RAISE EXCEPTION 'privacy_retention_request_verified_closure_invalid'
        USING ERRCODE='55000';
    END IF;
  ELSE
    RAISE EXCEPTION 'privacy_retention_request_identity_state_invalid'
      USING ERRCODE='55000';
  END IF;

  FOR v_transition IN
    SELECT receipt.*
    FROM ops.privacy_request_transition_receipts_v2 AS receipt
    WHERE receipt.privacy_request_id=v_request.id
    ORDER BY receipt.decision_version
  LOOP
    v_expected_version:=v_expected_version+1;
    IF v_transition.transition_receipt_id=v_nil_uuid
       OR v_transition.decision_version<>v_expected_version
       OR v_transition.decision_version>v_request.decision_version
       OR v_transition.prior_state<>v_expected_state
       OR btrim(v_transition.reason_code)<>v_transition.reason_code
       OR NOT EXISTS(
         SELECT 1
         FROM ops.record_class_schedules AS schedule
         JOIN ops.r6d_record_class_catalog AS catalog
           ON catalog.record_class=schedule.record_class
         WHERE (schedule.id,schedule.record_class,schedule.schedule_digest)=(
           v_transition.retention_schedule_id,
           v_transition.retention_record_class,
           v_transition.retention_schedule_digest
         )
           AND schedule.record_class='PRIVACY_REQUEST_EXECUTION'
           AND schedule.effective_at<=v_transition.decided_at
           AND schedule.review_expires_at>v_transition.decided_at
           AND schedule.terminal_action=catalog.required_terminal_action
           AND (catalog.required_trigger_kind IS NULL
             OR schedule.trigger_kind=catalog.required_trigger_kind)
           AND (catalog.required_active_duration_seconds IS NULL
             OR schedule.active_duration_seconds=
                catalog.required_active_duration_seconds)
           AND (catalog.required_backup_duration_seconds IS NULL
             OR schedule.backup_duration_seconds=
                catalog.required_backup_duration_seconds)
           AND (catalog.required_lawful_basis IS NULL
             OR schedule.lawful_basis=catalog.required_lawful_basis)
       ) THEN
      RAISE EXCEPTION 'privacy_retention_decision_chain_invalid'
        USING ERRCODE='55000';
    END IF;

    CASE v_transition.transition
      WHEN 'VERIFY_IDENTITY' THEN
        IF v_identity_seen OR v_expected_version<>1
           OR v_transition.prior_state<>'RECEIVED'
           OR v_transition.state<>'RECEIVED'
           OR v_transition.identity_receipt_id IS NULL
           OR v_transition.notice_receipt_id IS NULL
           OR num_nonnulls(
             v_transition.extension_receipt_id,
             v_transition.extension_receipt_digest,
             v_transition.refusal_receipt_id,
             v_transition.refusal_receipt_digest
           )<>0 THEN
          RAISE EXCEPTION 'privacy_retention_identity_branch_invalid'
            USING ERRCODE='55000';
        END IF;

        SELECT identity.* INTO v_identity
        FROM ops.privacy_request_identity_receipts_v2 AS identity
        WHERE identity.identity_receipt_id=
              v_transition.identity_receipt_id
          AND identity.privacy_request_id=v_request.id
          AND identity.decision_version=v_transition.decision_version
          AND identity.receipt_digest=v_transition.identity_receipt_digest;
        IF NOT FOUND
           OR v_identity.identity_receipt_id=v_nil_uuid
           OR v_identity.prior_identity_state<>'PENDING_VERIFICATION'
           OR v_identity.identity_state<>'VERIFIED'
           OR v_identity.identity_verified_at IS DISTINCT FROM
              v_request.identity_verified_at
           OR v_identity.response_policy_id IS DISTINCT FROM
              v_request.response_policy_id
           OR v_identity.response_policy_revision IS DISTINCT FROM
              v_request.response_policy_revision
           OR v_identity.response_policy_digest IS DISTINCT FROM
              v_request.response_policy_digest
           OR v_identity.calendar_version_id IS DISTINCT FROM
              v_request.calendar_version_id
           OR v_identity.calendar_digest IS DISTINCT FROM
              v_request.calendar_digest
           OR v_identity.notice_receipt_id IS DISTINCT FROM
              v_transition.notice_receipt_id
           OR v_identity.notice_receipt_digest IS DISTINCT FROM
              v_transition.notice_receipt_digest
           OR NOT EXISTS(
             SELECT 1
             FROM ops.record_class_schedules AS schedule
             WHERE (schedule.id,schedule.record_class,
                    schedule.schedule_digest)=(
               v_identity.retention_schedule_id,
               v_identity.retention_record_class,
               v_identity.retention_schedule_digest
             )
               AND schedule.record_class='PRIVACY_REQUEST_EXECUTION'
               AND schedule.effective_at<=v_identity.verified_at
               AND schedule.review_expires_at>v_identity.verified_at
           ) THEN
          RAISE EXCEPTION 'privacy_retention_identity_receipt_invalid'
            USING ERRCODE='55000';
        END IF;

        IF ops.privacy_response_policy_calendar_authority_v1_is_valid(
          v_identity.response_policy_id,v_identity.response_policy_revision
        ) IS DISTINCT FROM true THEN
          RAISE EXCEPTION 'privacy_retention_policy_calendar_authority_invalid'
            USING ERRCODE='55000';
        END IF;
        SELECT policy.* INTO v_policy
        FROM ops.privacy_response_calendar_policies_v1 AS policy
        WHERE (policy.policy_id,policy.revision,policy.policy_digest)=(
          v_identity.response_policy_id,v_identity.response_policy_revision,
          v_identity.response_policy_digest
        )
          AND policy.state='APPROVED'
          AND policy.policy_version=v_identity.response_policy_version
          AND policy.calendar_id=v_identity.calendar_version_id
          AND policy.effective_at<=v_identity.identity_verified_at
          AND policy.review_expires_at>v_identity.identity_verified_at;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'privacy_retention_policy_binding_invalid'
            USING ERRCODE='55000';
        END IF;
        SELECT calendar.* INTO v_calendar
        FROM ops.business_calendar_versions AS calendar
        WHERE calendar.id=v_identity.calendar_version_id
          AND calendar.calendar_digest=v_identity.calendar_digest
          AND calendar.policy_digest=v_identity.response_policy_digest
          AND calendar.timezone=v_policy.timezone
          AND calendar.effective_at=v_policy.effective_at
          AND calendar.review_expires_at=v_policy.review_expires_at;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'privacy_retention_calendar_binding_invalid'
            USING ERRCODE='55000';
        END IF;

        v_notice_sequence:=v_notice_sequence+1;
        SELECT notice.* INTO v_notice
        FROM ops.privacy_request_notice_receipts_v2 AS notice
        WHERE notice.notice_receipt_id=v_transition.notice_receipt_id
          AND notice.privacy_request_id=v_request.id
          AND notice.notice_sequence=v_notice_sequence
          AND notice.notice_kind='IDENTITY_VERIFIED'
          AND notice.transition_receipt_id=
              v_transition.transition_receipt_id
          AND notice.receipt_digest=v_transition.notice_receipt_digest
          AND notice.branch_receipt_id=v_identity.identity_receipt_id
          AND notice.branch_receipt_digest=v_identity.receipt_digest
          AND (notice.endpoint_id,notice.endpoint_version,
               notice.endpoint_digest)=(
            v_request.communication_endpoint_id,
            v_request.communication_endpoint_version,
            v_request.communication_endpoint_digest
          );
        IF NOT FOUND
           OR v_identity.notice_receipt_id IS DISTINCT FROM
              v_notice.notice_receipt_id
           OR v_identity.notice_receipt_digest IS DISTINCT FROM
              v_notice.receipt_digest
           OR NOT EXISTS(
             SELECT 1 FROM ops.record_class_schedules AS schedule
             WHERE (schedule.id,schedule.record_class,
                    schedule.schedule_digest)=(
               v_notice.retention_schedule_id,
               v_notice.retention_record_class,
               v_notice.retention_schedule_digest
             )
               AND schedule.record_class='PRIVACY_REQUEST_NOTICE'
               AND schedule.effective_at<=v_notice.created_at
               AND schedule.review_expires_at>v_notice.created_at
           ) THEN
          RAISE EXCEPTION 'privacy_retention_identity_notice_invalid'
            USING ERRCODE='55000';
        END IF;
        v_identity_seen:=true;
        v_due_cursor:=v_identity.due_at;
        v_current_notice_id:=v_notice.notice_receipt_id;
        v_current_notice_digest:=v_notice.receipt_digest;

      WHEN 'START_REVIEW' THEN
        IF NOT v_identity_seen
           OR v_transition.prior_state<>'RECEIVED'
           OR v_transition.state<>'REVIEW'
           OR num_nonnulls(
             v_transition.identity_receipt_id,
             v_transition.identity_receipt_digest,
             v_transition.extension_receipt_id,
             v_transition.extension_receipt_digest,
             v_transition.refusal_receipt_id,
             v_transition.refusal_receipt_digest,
             v_transition.notice_receipt_id,
             v_transition.notice_receipt_digest
           )<>0 THEN
          RAISE EXCEPTION 'privacy_retention_start_review_branch_invalid'
            USING ERRCODE='55000';
        END IF;
        v_expected_state:='REVIEW';

      WHEN 'APPROVE' THEN
        IF NOT v_identity_seen
           OR v_transition.prior_state<>'REVIEW'
           OR v_transition.state<>'APPROVED'
           OR num_nonnulls(
             v_transition.identity_receipt_id,
             v_transition.identity_receipt_digest,
             v_transition.extension_receipt_id,
             v_transition.extension_receipt_digest,
             v_transition.refusal_receipt_id,
             v_transition.refusal_receipt_digest,
             v_transition.notice_receipt_id,
             v_transition.notice_receipt_digest
           )<>0 THEN
          RAISE EXCEPTION 'privacy_retention_approve_branch_invalid'
            USING ERRCODE='55000';
        END IF;
        v_expected_state:='APPROVED';

      WHEN 'EXTEND' THEN
        IF NOT v_identity_seen
           OR v_transition.prior_state NOT IN (
             'RECEIVED','REVIEW','APPROVED'
           )
           OR v_transition.state<>v_transition.prior_state
           OR v_transition.extension_receipt_id IS NULL
           OR v_transition.notice_receipt_id IS NULL
           OR num_nonnulls(
             v_transition.identity_receipt_id,
             v_transition.identity_receipt_digest,
             v_transition.refusal_receipt_id,
             v_transition.refusal_receipt_digest
           )<>0 THEN
          RAISE EXCEPTION 'privacy_retention_extension_branch_invalid'
            USING ERRCODE='55000';
        END IF;
        v_extension_sequence:=v_extension_sequence+1;
        SELECT extension.* INTO v_extension
        FROM ops.privacy_request_extension_receipts_v2 AS extension
        WHERE extension.extension_receipt_id=
              v_transition.extension_receipt_id
          AND extension.privacy_request_id=v_request.id
          AND extension.decision_version=v_transition.decision_version
          AND extension.extension_sequence=v_extension_sequence
          AND extension.receipt_digest=v_transition.extension_receipt_digest;
        IF NOT FOUND
           OR v_extension.extension_receipt_id=v_nil_uuid
           OR v_extension.prior_due_at IS DISTINCT FROM v_due_cursor
           OR v_extension.due_at<=v_extension.prior_due_at
           OR v_extension.extended_at IS DISTINCT FROM
              v_transition.decided_at
           OR v_extension.extension_reason_code IS DISTINCT FROM
              v_transition.extension_reason_code
           OR v_extension.extension_reason_sha256 IS DISTINCT FROM
              v_transition.extension_reason_sha256
           OR v_extension.response_policy_id IS DISTINCT FROM
              v_request.response_policy_id
           OR v_extension.response_policy_revision IS DISTINCT FROM
              v_request.response_policy_revision
           OR v_extension.response_policy_digest IS DISTINCT FROM
              v_request.response_policy_digest
           OR v_extension.calendar_version_id IS DISTINCT FROM
              v_request.calendar_version_id
           OR v_extension.calendar_digest IS DISTINCT FROM
              v_request.calendar_digest
           OR v_extension.extension_sequence>v_policy.maximum_extension_count
           OR v_extension.extension_business_days>
              v_policy.maximum_extension_business_days
           OR v_extension.notice_receipt_id IS DISTINCT FROM
              v_transition.notice_receipt_id
           OR v_extension.notice_receipt_digest IS DISTINCT FROM
              v_transition.notice_receipt_digest THEN
          RAISE EXCEPTION 'privacy_retention_extension_receipt_invalid'
            USING ERRCODE='55000';
        END IF;
        v_notice_sequence:=v_notice_sequence+1;
        SELECT notice.* INTO v_notice
        FROM ops.privacy_request_notice_receipts_v2 AS notice
        WHERE notice.notice_receipt_id=v_transition.notice_receipt_id
          AND notice.privacy_request_id=v_request.id
          AND notice.notice_sequence=v_notice_sequence
          AND notice.notice_kind='EXTENSION'
          AND notice.transition_receipt_id=
              v_transition.transition_receipt_id
          AND notice.receipt_digest=v_transition.notice_receipt_digest
          AND notice.branch_receipt_id=v_extension.extension_receipt_id
          AND notice.branch_receipt_digest=v_extension.receipt_digest
          AND (notice.endpoint_id,notice.endpoint_version,
               notice.endpoint_digest)=(
            v_request.communication_endpoint_id,
            v_request.communication_endpoint_version,
            v_request.communication_endpoint_digest
          );
        IF NOT FOUND THEN
          RAISE EXCEPTION 'privacy_retention_extension_notice_invalid'
            USING ERRCODE='55000';
        END IF;
        v_due_cursor:=v_extension.due_at;
        v_current_extension_id:=v_extension.extension_receipt_id;
        v_current_extension_digest:=v_extension.receipt_digest;
        v_current_notice_id:=v_notice.notice_receipt_id;
        v_current_notice_digest:=v_notice.receipt_digest;

      WHEN 'REJECT' THEN
        IF NOT v_identity_seen
           OR v_transition.prior_state<>'REVIEW'
           OR v_transition.state<>'REJECTED'
           OR v_transition.refusal_receipt_id IS NULL
           OR v_transition.notice_receipt_id IS NULL
           OR num_nonnulls(
             v_transition.identity_receipt_id,
             v_transition.identity_receipt_digest,
             v_transition.extension_receipt_id,
             v_transition.extension_receipt_digest
           )<>0 THEN
          RAISE EXCEPTION 'privacy_retention_refusal_branch_invalid'
            USING ERRCODE='55000';
        END IF;
        SELECT refusal.* INTO v_refusal
        FROM ops.privacy_request_refusal_receipts_v2 AS refusal
        WHERE refusal.refusal_receipt_id=v_transition.refusal_receipt_id
          AND refusal.privacy_request_id=v_request.id
          AND refusal.decision_version=v_transition.decision_version
          AND refusal.receipt_digest=v_transition.refusal_receipt_digest;
        IF NOT FOUND
           OR v_refusal.refusal_receipt_id=v_nil_uuid
           OR v_refusal.rejection_reason_code IS DISTINCT FROM
              v_transition.rejection_reason_code
           OR v_refusal.rejection_reason_sha256 IS DISTINCT FROM
              v_transition.rejection_reason_sha256
           OR v_refusal.appeal_instructions_sha256 IS DISTINCT FROM
              v_transition.appeal_instructions_sha256
           OR v_refusal.decision_at IS DISTINCT FROM
              v_transition.decided_at
           OR v_refusal.response_policy_id IS DISTINCT FROM
              v_request.response_policy_id
           OR v_refusal.response_policy_revision IS DISTINCT FROM
              v_request.response_policy_revision
           OR v_refusal.response_policy_digest IS DISTINCT FROM
              v_request.response_policy_digest
           OR v_refusal.calendar_version_id IS DISTINCT FROM
              v_request.calendar_version_id
           OR v_refusal.calendar_digest IS DISTINCT FROM
              v_request.calendar_digest
           OR v_refusal.notice_receipt_id IS DISTINCT FROM
              v_transition.notice_receipt_id
           OR v_refusal.notice_receipt_digest IS DISTINCT FROM
              v_transition.notice_receipt_digest THEN
          RAISE EXCEPTION 'privacy_retention_refusal_receipt_invalid'
            USING ERRCODE='55000';
        END IF;
        v_notice_sequence:=v_notice_sequence+1;
        SELECT notice.* INTO v_notice
        FROM ops.privacy_request_notice_receipts_v2 AS notice
        WHERE notice.notice_receipt_id=v_transition.notice_receipt_id
          AND notice.privacy_request_id=v_request.id
          AND notice.notice_sequence=v_notice_sequence
          AND notice.notice_kind='REFUSAL'
          AND notice.transition_receipt_id=
              v_transition.transition_receipt_id
          AND notice.receipt_digest=v_transition.notice_receipt_digest
          AND notice.branch_receipt_id=v_refusal.refusal_receipt_id
          AND notice.branch_receipt_digest=v_refusal.receipt_digest
          AND (notice.endpoint_id,notice.endpoint_version,
               notice.endpoint_digest)=(
            v_request.communication_endpoint_id,
            v_request.communication_endpoint_version,
            v_request.communication_endpoint_digest
          );
        IF NOT FOUND THEN
          RAISE EXCEPTION 'privacy_retention_refusal_notice_invalid'
            USING ERRCODE='55000';
        END IF;
        v_current_refusal_id:=v_refusal.refusal_receipt_id;
        v_current_refusal_digest:=v_refusal.receipt_digest;
        v_current_notice_id:=v_notice.notice_receipt_id;
        v_current_notice_digest:=v_notice.receipt_digest;
        v_expected_state:='REJECTED';

      ELSE
        RAISE EXCEPTION 'privacy_retention_transition_invalid'
          USING ERRCODE='55000';
    END CASE;

    v_decisions:=v_decisions||jsonb_build_array(jsonb_build_object(
      'transitionReceiptId',v_transition.transition_receipt_id,
      'decisionVersion',v_transition.decision_version,
      'transition',v_transition.transition,
      'priorState',v_transition.prior_state,
      'state',v_transition.state,
      'reasonCode',v_transition.reason_code,
      'reasonDigest',btrim(v_transition.reason_sha256),
      'identityReceiptId',v_transition.identity_receipt_id,
      'extensionReceiptId',v_transition.extension_receipt_id,
      'refusalReceiptId',v_transition.refusal_receipt_id,
      'noticeReceiptId',v_transition.notice_receipt_id,
      'decidedAt',v_transition.decided_at,
      'transitionReceiptDigest',btrim(v_transition.receipt_digest)
    ));
  END LOOP;

  -- Completion is not a synthetic transition receipt. The immutable Q4
  -- completion receipt is the sole authority for the one version after the
  -- final APPROVE receipt, while the root keeps its actual persisted version.
  IF v_request.state='COMPLETED'
     AND v_request.request_type='CORRECTION' THEN
    SELECT receipt.* INTO v_completion
    FROM
      ops.privacy_response_party_name_correction_completion_receipts_v1
        AS receipt
    WHERE receipt.privacy_request_id=v_request.id;
    IF NOT FOUND
       OR v_expected_state<>'APPROVED'
       OR v_completion.privacy_request_id<>v_request.id
       OR v_completion.approval_decision_version<>v_expected_version
       OR v_completion.completion_decision_version<>
          v_request.decision_version
       OR v_completion.completion_decision_version<>
          v_completion.approval_decision_version+1
       OR v_completion.completed_at IS DISTINCT FROM v_request.updated_at THEN
      RAISE EXCEPTION 'privacy_retention_completion_receipt_invalid'
        USING ERRCODE='55000';
    END IF;
    v_expected_version:=v_expected_version+1;
    v_expected_state:='COMPLETED';
  END IF;

  IF v_expected_version<>v_request.decision_version
     OR v_expected_state<>v_request.state
     OR (v_request.identity_state='VERIFIED' AND NOT v_identity_seen)
     OR (v_request.identity_state='PENDING_VERIFICATION' AND v_identity_seen)
     OR (v_identity_seen AND v_due_cursor IS DISTINCT FROM v_request.due_at)
     OR (v_identity_seen AND ROW(
       v_request.current_identity_receipt_id,
       v_request.current_identity_receipt_digest
     ) IS DISTINCT FROM ROW(
       v_identity.identity_receipt_id,v_identity.receipt_digest
     ))
     OR ROW(
       v_request.current_extension_receipt_id,
       v_request.current_extension_receipt_digest
     ) IS DISTINCT FROM ROW(
       v_current_extension_id,v_current_extension_digest
     )
     OR ROW(
       v_request.current_refusal_receipt_id,
       v_request.current_refusal_receipt_digest
     ) IS DISTINCT FROM ROW(
       v_current_refusal_id,v_current_refusal_digest
     )
     OR ROW(
       v_request.current_notice_receipt_id,
       v_request.current_notice_receipt_digest
     ) IS DISTINCT FROM ROW(
       v_current_notice_id,v_current_notice_digest
     ) THEN
    RAISE EXCEPTION 'privacy_retention_request_receipt_heads_invalid'
      USING ERRCODE='55000';
  END IF;

  SELECT count(*) INTO v_receipt_count
  FROM ops.privacy_request_notice_receipts_v2
  WHERE privacy_request_id=v_request.id;
  IF v_receipt_count<>v_notice_sequence
     OR (SELECT count(*)
         FROM ops.privacy_request_identity_receipts_v2
         WHERE privacy_request_id=v_request.id)<>
        (CASE WHEN v_identity_seen THEN 1 ELSE 0 END)
     OR (SELECT count(*)
         FROM ops.privacy_request_extension_receipts_v2
         WHERE privacy_request_id=v_request.id)<>v_extension_sequence
     OR (SELECT count(*)
         FROM ops.privacy_request_refusal_receipts_v2
         WHERE privacy_request_id=v_request.id)<>
        (CASE WHEN v_current_refusal_id IS NULL THEN 0 ELSE 1 END) THEN
    RAISE EXCEPTION 'privacy_retention_request_receipt_cardinality_invalid'
      USING ERRCODE='55000';
  END IF;

  -- Use only the canonical legal-hold resolver.  Mutable legal_holds flags and
  -- release timestamps are deliberately not reconstructed here.
  v_hold_coverage:=ops.r6d_privacy_request_legal_hold_coverage_v1(
    v_request.id,v_as_of
  );
  IF jsonb_typeof(v_hold_coverage)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_hold_coverage))<>5
     OR NOT v_hold_coverage ?& ARRAY[
       'active','activeCellCount','coverageDigest','evaluatedAt','coverage'
     ]
     OR jsonb_typeof(v_hold_coverage->'active')<>'boolean'
     OR jsonb_typeof(v_hold_coverage->'activeCellCount')<>'number'
     OR (v_hold_coverage->>'activeCellCount') !~ '^(0|[1-9][0-9]*)$'
     OR NOT COALESCE(ops.r6d_lower_sha256(
       v_hold_coverage->>'coverageDigest'
     ),false)
     OR (v_hold_coverage->>'evaluatedAt')::timestamptz
        IS DISTINCT FROM v_as_of
     OR jsonb_typeof(v_hold_coverage->'coverage')<>'object' THEN
    RAISE EXCEPTION 'privacy_retention_hold_coverage_invalid'
      USING ERRCODE='55000';
  END IF;
  v_hold_payload:=v_hold_coverage->'coverage';
  IF (SELECT count(*) FROM jsonb_object_keys(v_hold_payload))<>4
     OR NOT v_hold_payload ?& ARRAY[
       'schemaVersion','privacyRequestId','holdProofs','activeCells'
     ]
     OR v_hold_payload->>'schemaVersion' IS DISTINCT FROM
        'r6d-privacy-request-legal-hold-coverage.v1'
     OR (v_hold_payload->>'privacyRequestId')::uuid IS DISTINCT FROM
        v_request.id
     OR jsonb_typeof(v_hold_payload->'holdProofs')<>'array'
     OR jsonb_typeof(v_hold_payload->'activeCells')<>'array'
     OR v_hold_coverage->>'coverageDigest' IS DISTINCT FROM
        encode(extensions.digest(
          ops.canonical_jsonb_v1(v_hold_payload),'sha256'
        ),'hex') THEN
    RAISE EXCEPTION 'privacy_retention_hold_coverage_invalid'
      USING ERRCODE='55000';
  END IF;
  v_active_cells:=v_hold_payload->'activeCells';
  IF EXISTS(
       SELECT 1
       FROM jsonb_array_elements(v_active_cells) AS cell(value)
       WHERE jsonb_typeof(cell.value)<>'object'
          OR (SELECT count(*) FROM jsonb_object_keys(cell.value))<>3
          OR NOT cell.value ?& ARRAY['holdId','scopeAtom','affectedId']
          OR (cell.value->>'holdId')::uuid=v_nil_uuid
          OR cell.value->>'scopeAtom' NOT IN ('RETENTION','DELETION')
          OR (cell.value->>'affectedId')::uuid IS DISTINCT FROM v_request.id
     )
     OR v_active_cells IS DISTINCT FROM COALESCE((
       SELECT jsonb_agg(cell.value ORDER BY
         (cell.value->>'holdId')::uuid,cell.value->>'scopeAtom',
         (cell.value->>'affectedId')::uuid
       )
       FROM jsonb_array_elements(v_active_cells) AS cell(value)
     ),'[]'::jsonb)
     OR EXISTS(
       SELECT 1
       FROM jsonb_array_elements(v_active_cells) AS cell(value)
       GROUP BY cell.value->>'holdId',cell.value->>'scopeAtom',
                cell.value->>'affectedId'
       HAVING count(*)>1
     )
     OR (v_hold_coverage->>'activeCellCount')::bigint<>
        jsonb_array_length(v_active_cells)
     OR (v_hold_coverage->>'active')::boolean IS DISTINCT FROM
        (jsonb_array_length(v_active_cells)>0) THEN
    RAISE EXCEPTION 'privacy_retention_hold_cells_invalid'
      USING ERRCODE='55000';
  END IF;
  SELECT COALESCE(jsonb_agg(hold.hold_id ORDER BY hold.hold_id),'[]'::jsonb)
  INTO v_active_hold_ids
  FROM (
    SELECT DISTINCT (cell.value->>'holdId')::uuid AS hold_id
    FROM jsonb_array_elements(v_active_cells) AS cell(value)
  ) AS hold;
  IF jsonb_array_length(v_active_hold_ids)>1000 THEN
    RAISE EXCEPTION 'privacy_retention_active_hold_limit_exceeded'
      USING ERRCODE='55000';
  END IF;

  -- A capability-gated workspace may expose the one current RESPONSE
  -- /partyName projection. Multiple RESPONSE scope items are not collapsed
  -- into an arbitrary target.
  IF v_request.request_type IN ('ACCESS','CORRECTION') THEN
    IF v_request.state='COMPLETED' THEN
      v_access_response_ids:=ARRAY[v_completion.response_id]::uuid[];
      v_access_response_count:=1;
    ELSE
      SELECT count(*),array_agg(item.object_id ORDER BY item.object_id)
      INTO v_access_response_count,v_access_response_ids
      FROM ops.privacy_request_scope_inventories_v1 AS inventory
      JOIN ops.privacy_request_scope_inventory_items_v1 AS item
        ON item.scope_inventory_id=inventory.scope_inventory_id
       AND item.privacy_request_id=inventory.privacy_request_id
      WHERE inventory.privacy_request_id=v_request.id
        AND inventory.scope_kind='OBJECT_SET'
        AND NOT inventory.include_derivatives
        AND NOT inventory.include_backups
        AND item.object_kind='RESPONSE';
    END IF;
    IF v_access_response_count=1 THEN
      v_access_projection:=
        ops.read_privacy_response_party_name_access_v1(
          v_request.id,v_access_response_ids[1]
        );
    END IF;
  END IF;

  IF v_request.state='COMPLETED'
     AND v_request.request_type='CORRECTION' THEN
    SELECT binding.* INTO v_completion_approval
    FROM ops.privacy_response_party_name_correction_approval_bindings_v1
      AS binding
    WHERE binding.approval_binding_id=v_completion.approval_binding_id;
    SELECT plan.* INTO v_completion_plan
    FROM ops.privacy_correction_plans_v1 AS plan
    WHERE plan.correction_plan_id=v_completion.correction_plan_id;
    SELECT binding.* INTO v_completion_plan_binding
    FROM ops.privacy_response_party_name_correction_plan_bindings_v1
      AS binding
    WHERE binding.correction_plan_id=v_completion.correction_plan_id;
    SELECT job.* INTO v_completion_job
    FROM ops.jobs AS job WHERE job.id=v_completion.job_id;
    SELECT receipt.* INTO v_completion_transition
    FROM ops.privacy_request_transition_receipts_v2 AS receipt
    WHERE receipt.transition_receipt_id=
      v_completion.approval_transition_receipt_id;
    SELECT response.* INTO v_completion_response
    FROM editorial.responses AS response
    WHERE response.id=v_completion.response_id;
    SELECT audit.* INTO v_completion_audit
    FROM ops.audit_events AS audit
    WHERE audit.id=v_completion.audit_event_id;
    SELECT event.* INTO v_completion_event
    FROM ops.outbox AS event
    WHERE event.id=v_completion.outbox_event_id;

    v_current_party_name_digest:=encode(extensions.digest(
      convert_to(v_completion_response.party_name,'UTF8'),'sha256'
    ),'hex');
    v_expected_completion_audit:=jsonb_build_object(
      'jobId',v_completion.job_id,
      'jobPayloadDigest',btrim(v_completion.job_payload_digest),
      'completionReceiptId',v_completion.completion_receipt_id,
      'privacyRequestId',v_completion.privacy_request_id,
      'approvalDecisionVersion',v_completion.approval_decision_version,
      'completionDecisionVersion',v_completion.completion_decision_version,
      'correctionPlanId',v_completion.correction_plan_id,
      'planDigest',btrim(v_completion.plan_digest),
      'approvalBindingDigest',
        btrim(v_completion.approval_binding_digest),
      'priorResponseVersion',v_completion.prior_response_version,
      'responseVersion',v_completion.response_version,
      'priorPartyNameDigest',btrim(v_completion.prior_party_name_digest),
      'partyNameDigest',btrim(v_completion.party_name_digest),
      'holdCoverageDigest',btrim(v_completion.hold_coverage_digest),
      'approvalTransitionReceiptDigest',
        btrim(v_completion.approval_transition_receipt_digest)
    );
    v_expected_completion_event:=jsonb_build_object(
      'privacyRequestId',v_completion.privacy_request_id,
      'correctionPlanId',v_completion.correction_plan_id,
      'responseId',v_completion.response_id,
      'responseVersion',v_completion.response_version,
      'partyNameDigest',btrim(v_completion.party_name_digest),
      'completionReceiptId',v_completion.completion_receipt_id,
      'completionReceiptDigest',btrim(v_completion.receipt_digest),
      'auditEventId',v_completion.audit_event_id,
      'completedAt',v_completion.completed_at
    );

    IF v_access_projection IS NULL
       OR v_completion_approval.approval_binding_id IS NULL
       OR v_completion_plan.correction_plan_id IS NULL
       OR v_completion_plan_binding.correction_plan_id IS NULL
       OR v_completion_job.id IS NULL
       OR v_completion_transition.transition_receipt_id IS NULL
       OR v_completion_response.id IS NULL
       OR v_completion_audit.id IS NULL
       OR v_completion_event.id IS NULL
       OR (SELECT count(*)
           FROM
             ops.privacy_response_party_name_correction_completion_receipts_v1
           WHERE privacy_request_id=v_request.id)<>1
       OR (SELECT count(*)
           FROM
             ops.privacy_response_party_name_correction_approval_bindings_v1
           WHERE privacy_request_id=v_request.id)<>1
       OR v_completion.approval_binding_digest<>
          v_completion_approval.binding_digest
       OR v_completion.job_id<>v_completion_approval.job_id
       OR v_completion.job_payload_digest<>
          v_completion_approval.job_payload_digest
       OR v_completion.approval_decision_version<>
          v_completion_approval.request_decision_version
       OR v_completion.correction_plan_id<>
          v_completion_approval.correction_plan_id
       OR v_completion.plan_version<>v_completion_approval.plan_version
       OR v_completion.plan_digest<>v_completion_approval.plan_digest
       OR v_completion.response_id<>v_completion_approval.response_id
       OR v_completion.prior_response_version<>
          v_completion_approval.expected_response_version
       OR v_completion.prior_party_name_digest<>
          v_completion_approval.expected_current_value_digest
       OR v_completion.approval_transition_receipt_id<>
          v_completion_approval.transition_receipt_id
       OR v_completion.approval_transition_receipt_digest<>
          v_completion_approval.transition_receipt_digest
       OR v_completion_plan.privacy_request_id<>v_request.id
       OR v_completion_plan.plan_version<>v_completion.plan_version
       OR v_completion_plan.plan_digest<>v_completion.plan_digest
       OR v_completion_plan.target_object_type<>'RESPONSE'
       OR v_completion_plan.target_object_id<>v_completion.response_id
       OR v_completion_plan.field_path<>'/partyName'
       OR v_completion_plan.current_value_digest<>
          v_completion.prior_party_name_digest
       OR v_completion_plan.requested_value_sha256<>
          v_completion.party_name_digest
       OR v_completion_plan_binding.privacy_request_id<>v_request.id
       OR v_completion_plan_binding.binding_digest<>
          v_completion_approval.plan_binding_digest
       OR v_completion_plan_binding.response_id<>v_completion.response_id
       OR v_completion_plan_binding.expected_response_version<>
          v_completion.prior_response_version
       OR v_completion_plan_binding.expected_current_value_digest<>
          v_completion.prior_party_name_digest
       OR v_completion_plan_binding.access_projection_digest<>
          v_completion_approval.access_projection_digest
       OR v_completion_job.job_type<>
          'PRIVACY_RESPONSE_PARTY_NAME_CORRECTION'
       OR v_completion_job.queue<>'workflow-worker'
       OR encode(extensions.digest(
            ops.canonical_jsonb_v1(v_completion_job.payload),'sha256'
          ),'hex')<>v_completion.job_payload_digest
       OR v_completion_transition.privacy_request_id<>v_request.id
       OR v_completion_transition.decision_version<>
          v_completion.approval_decision_version
       OR v_completion_transition.transition<>'APPROVE'
       OR v_completion_transition.prior_state<>'REVIEW'
       OR v_completion_transition.state<>'APPROVED'
       OR v_completion_transition.receipt_digest<>
          v_completion.approval_transition_receipt_digest
       OR v_completion_response.version<>v_completion.response_version
       OR v_current_party_name_digest<>v_completion.party_name_digest
       OR v_completion_audit.actor_type<>'SERVICE'
       OR v_completion_audit.actor_id<>'workflow-worker'
       OR v_completion_audit.action<>
          'privacy.response_party_name.correction.complete'
       OR v_completion_audit.object_type<>'RESPONSE'
       OR v_completion_audit.object_id<>v_completion.response_id::text
       OR v_completion_audit.outcome<>'SUCCESS'
       OR v_completion_audit.details IS DISTINCT FROM
          v_expected_completion_audit
       OR v_completion_event.aggregate_type<>'editorial_response'
       OR v_completion_event.aggregate_id<>v_completion.response_id::text
       OR v_completion_event.aggregate_version<>
          v_completion.response_version
       OR v_completion_event.event_type<>
          'privacy.response_party_name_corrected.v1'
       OR v_completion_event.payload IS DISTINCT FROM
          v_expected_completion_event
       OR v_completion_event.occurred_at IS DISTINCT FROM
          v_completion.completed_at
       OR ops.r6d_outbox_envelope_digest_v1(v_completion_event.id)<>
          v_completion.outbox_event_digest
       OR v_access_projection->>'targetObjectId'<>
          v_completion.response_id::text
       OR (v_access_projection->>'responseVersion')::bigint<>
          v_completion.response_version
       OR v_access_projection->>'currentValueDigest'<>
          btrim(v_completion.party_name_digest)
       OR (v_access_projection->>'privacyIdentityProofReceiptId')::uuid<>
          v_completion_approval.privacy_identity_proof_receipt_id
       OR v_access_projection->>'privacyIdentityProofReceiptDigest'<>
          btrim(v_completion_approval.privacy_identity_proof_receipt_digest)
       OR (v_access_projection->>'responseSubmissionReceiptId')::uuid<>
          v_completion_approval.response_submission_receipt_id
       OR v_access_projection->>'responseSubmissionReceiptDigest'<>
          btrim(v_completion_approval.response_submission_receipt_digest)
       OR (v_access_projection->>'responseOriginReceiptId')::uuid<>
          v_completion_approval.response_origin_receipt_id
       OR v_access_projection->>'responseOriginReceiptDigest'<>
          btrim(v_completion_approval.response_origin_receipt_digest)
       OR v_access_projection->>'asOf'<>to_jsonb(v_as_of)#>>'{}' THEN
      RAISE EXCEPTION 'privacy_retention_completion_authority_invalid'
        USING ERRCODE='55000';
    END IF;
  ELSIF EXISTS(
    SELECT 1
    FROM
      ops.privacy_response_party_name_correction_completion_receipts_v1
    WHERE privacy_request_id=v_request.id
  ) THEN
    RAISE EXCEPTION 'privacy_retention_completion_state_invalid'
      USING ERRCODE='55000';
  END IF;

  RETURN jsonb_build_object(
    'request',jsonb_build_object(
      'retentionRequestId',v_request.id,
      'requestType',v_request.request_type,
      'decisionVersion',v_request.decision_version,
      'state',v_request.state,
      'jurisdiction',v_request.jurisdiction,
      'scopeDigest',btrim(v_request.scope_sha256),
      'identityState',v_request.identity_state,
      'identityVerifiedAt',v_request.identity_verified_at,
      'dueAt',v_request.due_at,
      'legalHoldBlocked',(v_hold_coverage->>'active')::boolean,
      'createdAt',v_request.created_at,
      'updatedAt',v_request.updated_at
    ),
    'identityVerificationReceiptId',
      CASE WHEN v_identity_seen THEN v_identity.identity_receipt_id ELSE NULL END,
    'identityVerificationReceiptDigest',
      CASE WHEN v_identity_seen THEN btrim(v_identity.receipt_digest) ELSE NULL END,
    'policyVersion',
      CASE WHEN v_identity_seen THEN v_policy.policy_version ELSE NULL END,
    'policyDigest',
      CASE WHEN v_identity_seen THEN btrim(v_policy.policy_digest) ELSE NULL END,
    'calendarVersionId',
      CASE WHEN v_identity_seen THEN v_calendar.id ELSE NULL END,
    'calendarDigest',
      CASE WHEN v_identity_seen THEN btrim(v_calendar.calendar_digest) ELSE NULL END,
    -- No explicit V1<->V2 bridge exists for the following legacy values.
    'inventorySnapshotDigest',NULL,
    'holdCoverageDigest',NULL,
    'activeHoldIds',v_active_hold_ids,
    'affectedRecordClasses','[]'::jsonb,
    'locationReceipts','[]'::jsonb,
    'decisionReceipts',v_decisions,
    'completionReceiptId',
      CASE WHEN v_completion.completion_receipt_id IS NULL THEN NULL
           ELSE v_completion.completion_receipt_id END,
    'completionReceiptDigest',
      CASE WHEN v_completion.completion_receipt_id IS NULL THEN NULL
           ELSE btrim(v_completion.receipt_digest) END,
    'completedResponseVersion',
      CASE WHEN v_completion.completion_receipt_id IS NULL THEN NULL
           ELSE v_completion.response_version END,
    'completedValueDigest',
      CASE WHEN v_completion.completion_receipt_id IS NULL THEN NULL
           ELSE btrim(v_completion.party_name_digest) END,
    'accessProjection',v_access_projection,
    'asOf',v_as_of,
    'links','[]'::jsonb
  );
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range
    OR datetime_field_overflow THEN
    RAISE EXCEPTION 'privacy_retention_reader_authority_invalid'
      USING ERRCODE='55000';
END;
$workspace$;

ALTER FUNCTION ops.read_privacy_retention_request_workspace_v2(uuid)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.read_privacy_retention_request_workspace_v2(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  ops.read_privacy_retention_request_workspace_v2(uuid)
  TO gurine_control_api;


-- Public receipt status closes Q4 completion through digest-only authority.
-- It never invokes or returns the plaintext access projection.
CREATE OR REPLACE FUNCTION ops.get_privacy_request_v2(
  p_session_sha256 char(64),p_bff_issuer text
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,extensions,pg_temp
AS $get$
DECLARE
  v_as_of timestamptz:=statement_timestamp();
  v_session intake.submission_sessions%ROWTYPE;
  v_access_policy ops.privacy_request_access_policies_v1%ROWTYPE;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_decision ops.privacy_request_transition_receipts_v2%ROWTYPE;
  v_refusal ops.privacy_request_refusal_receipts_v2%ROWTYPE;
  v_refusal_notice ops.privacy_request_notice_receipts_v2%ROWTYPE;
  v_notice_ids jsonb;
  v_notice_digests jsonb;
  v_notice_count bigint;
  v_bound_notice_count bigint;
  v_next_action text;
  v_decision_reason_code text;
  v_decision_receipt_id uuid;
  v_decision_receipt_digest char(64);
  v_refusal_notice_id uuid;
  v_refusal_notice_digest char(64);
  v_completion
    ops.privacy_response_party_name_correction_completion_receipts_v1%ROWTYPE;
  v_completion_approval
    ops.privacy_response_party_name_correction_approval_bindings_v1%ROWTYPE;
BEGIN
  IF p_session_sha256 IS NULL
     OR NOT ops.r6d_lower_sha256(p_session_sha256)
     OR p_bff_issuer IS DISTINCT FROM 'public-web' THEN
    RAISE EXCEPTION 'privacy_request_scoped_session_required'
      USING ERRCODE='PVT04';
  END IF;
  SELECT * INTO v_session FROM intake.submission_sessions
  WHERE token_hash=p_session_sha256
    AND bff_issuer=p_bff_issuer
    AND session_kind='PRIVACY_REQUEST_RECEIPT'
    AND scope_type='PRIVACY_REQUEST'
    AND status='ACTIVE' AND expires_at>v_as_of;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_request_scoped_session_required'
      USING ERRCODE='PVT04';
  END IF;
  v_access_policy:=ops.current_privacy_request_access_policy_v1(v_as_of);
  IF ROW(
       v_session.privacy_access_policy_id,
       v_session.privacy_access_policy_revision,
       v_session.privacy_access_policy_digest,
       v_session.privacy_access_policy_binding_digest
     ) IS DISTINCT FROM ROW(
       v_access_policy.policy_id,v_access_policy.revision,
       v_access_policy.policy_digest,v_access_policy.binding_digest
     ) THEN
    RAISE EXCEPTION 'privacy_request_access_policy_closure_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO v_request FROM ops.privacy_requests_v2
  WHERE id=v_session.scope_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_request_not_found' USING ERRCODE='P0002';
  END IF;
  IF v_request.state<>'COMPLETED' AND EXISTS(
    SELECT 1
    FROM
      ops.privacy_response_party_name_correction_completion_receipts_v1
    WHERE privacy_request_id=v_request.id
  ) THEN
    RAISE EXCEPTION 'privacy_request_completion_state_invalid'
      USING ERRCODE='23514';
  END IF;

  SELECT
    COALESCE(jsonb_agg(notice.notice_receipt_id ORDER BY notice.notice_sequence),
      '[]'::jsonb),
    COALESCE(jsonb_agg(btrim(notice.receipt_digest) ORDER BY notice.notice_sequence),
      '[]'::jsonb),
    count(*)
  INTO v_notice_ids,v_notice_digests,v_notice_count
  FROM ops.privacy_request_notice_receipts_v2 AS notice
  WHERE notice.privacy_request_id=v_request.id;
  SELECT count(*) INTO v_bound_notice_count
  FROM ops.privacy_request_notice_receipts_v2 AS notice
  JOIN ops.privacy_request_transition_receipts_v2 AS transition
    ON transition.privacy_request_id=notice.privacy_request_id
   AND transition.notice_receipt_id=notice.notice_receipt_id
   AND transition.notice_receipt_digest=notice.receipt_digest
  WHERE notice.privacy_request_id=v_request.id;
  IF v_notice_count>100 OR v_bound_notice_count<>v_notice_count THEN
    RAISE EXCEPTION 'privacy_request_notice_receipt_closure_invalid'
      USING ERRCODE='23514';
  END IF;

  CASE
    WHEN v_request.state='RECEIVED'
         AND v_request.identity_state='PENDING_VERIFICATION' THEN
      v_next_action:='VERIFY_IDENTITY';
    WHEN v_request.state='RECEIVED'
         AND v_request.identity_state='VERIFIED' THEN
      v_next_action:='AWAIT_REVIEW';
    WHEN v_request.state='REVIEW'
         AND v_request.identity_state='VERIFIED' THEN
      v_next_action:='AWAIT_DECISION';
    WHEN v_request.state='APPROVED'
         AND v_request.identity_state='VERIFIED' THEN
      v_next_action:='AWAIT_EXECUTION';
      SELECT * INTO v_decision
      FROM ops.privacy_request_transition_receipts_v2
      WHERE privacy_request_id=v_request.id
        AND decision_version=v_request.decision_version
        AND transition='APPROVE' AND state='APPROVED';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'privacy_request_decision_receipt_closure_invalid'
          USING ERRCODE='23514';
      END IF;
      v_decision_reason_code:=v_decision.reason_code;
      v_decision_receipt_id:=v_decision.transition_receipt_id;
      v_decision_receipt_digest:=v_decision.receipt_digest;
    WHEN v_request.state='REJECTED'
         AND v_request.identity_state='VERIFIED' THEN
      v_next_action:='REVIEW_REFUSAL_NOTICE';
      SELECT * INTO v_decision
      FROM ops.privacy_request_transition_receipts_v2
      WHERE privacy_request_id=v_request.id
        AND decision_version=v_request.decision_version
        AND transition='REJECT' AND state='REJECTED';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'privacy_request_decision_receipt_closure_invalid'
          USING ERRCODE='23514';
      END IF;
      SELECT * INTO v_refusal
      FROM ops.privacy_request_refusal_receipts_v2
      WHERE refusal_receipt_id=v_request.current_refusal_receipt_id
        AND privacy_request_id=v_request.id
        AND receipt_digest=v_request.current_refusal_receipt_digest
        AND refusal_receipt_id=v_decision.refusal_receipt_id
        AND receipt_digest=v_decision.refusal_receipt_digest;
      SELECT * INTO v_refusal_notice
      FROM ops.privacy_request_notice_receipts_v2
      WHERE notice_receipt_id=v_request.current_notice_receipt_id
        AND privacy_request_id=v_request.id
        AND receipt_digest=v_request.current_notice_receipt_digest
        AND notice_receipt_id=v_decision.notice_receipt_id
        AND receipt_digest=v_decision.notice_receipt_digest
        AND notice_kind='REFUSAL';
      IF v_refusal.refusal_receipt_id IS NULL
         OR v_refusal_notice.notice_receipt_id IS NULL THEN
        RAISE EXCEPTION 'privacy_request_refusal_receipt_closure_invalid'
          USING ERRCODE='23514';
      END IF;
      v_decision_reason_code:=v_refusal.rejection_reason_code;
      v_decision_receipt_id:=v_decision.transition_receipt_id;
      v_decision_receipt_digest:=v_decision.receipt_digest;
      v_refusal_notice_id:=v_refusal_notice.notice_receipt_id;
      v_refusal_notice_digest:=v_refusal_notice.receipt_digest;
    WHEN v_request.state='COMPLETED'
         AND v_request.identity_state='VERIFIED'
         AND v_request.request_type='CORRECTION' THEN
      SELECT receipt.* INTO v_completion
      FROM
        ops.privacy_response_party_name_correction_completion_receipts_v1
          AS receipt
      WHERE receipt.privacy_request_id=v_request.id;
      SELECT binding.* INTO v_completion_approval
      FROM ops.privacy_response_party_name_correction_approval_bindings_v1
        AS binding
      WHERE binding.approval_binding_id=v_completion.approval_binding_id;
      SELECT transition.* INTO v_decision
      FROM ops.privacy_request_transition_receipts_v2 AS transition
      WHERE transition.transition_receipt_id=
            v_completion.approval_transition_receipt_id
        AND transition.privacy_request_id=v_request.id
        AND transition.decision_version=
            v_completion.approval_decision_version
        AND transition.transition='APPROVE'
        AND transition.state='APPROVED'
        AND transition.receipt_digest=
            v_completion.approval_transition_receipt_digest;
      IF v_completion.completion_receipt_id IS NULL
         OR v_completion_approval.approval_binding_id IS NULL
         OR v_decision.transition_receipt_id IS NULL
         OR v_completion.completion_decision_version<>
            v_request.decision_version
         OR v_completion.approval_decision_version+1<>
            v_request.decision_version
         OR v_completion.completed_at IS DISTINCT FROM v_request.updated_at
         OR v_completion.approval_binding_digest<>
            v_completion_approval.binding_digest
         OR v_completion.approval_decision_version<>
            v_completion_approval.request_decision_version
         OR v_completion.job_id<>v_completion_approval.job_id
         OR v_completion.job_payload_digest<>
            v_completion_approval.job_payload_digest
         OR v_completion.correction_plan_id<>
            v_completion_approval.correction_plan_id
         OR v_completion.response_id<>v_completion_approval.response_id
         OR v_completion.prior_response_version<>
            v_completion_approval.expected_response_version
         OR v_completion.prior_party_name_digest<>
            v_completion_approval.expected_current_value_digest
         OR v_completion.approval_transition_receipt_id<>
            v_completion_approval.transition_receipt_id
         OR v_completion.approval_transition_receipt_digest<>
            v_completion_approval.transition_receipt_digest THEN
        RAISE EXCEPTION 'privacy_request_completion_authority_missing'
          USING ERRCODE='55000';
      END IF;
      v_next_action:='COMPLETE';
      v_decision_reason_code:=v_decision.reason_code;
      v_decision_receipt_id:=v_decision.transition_receipt_id;
      v_decision_receipt_digest:=v_decision.receipt_digest;
    ELSE
      RAISE EXCEPTION 'privacy_request_state_closure_invalid'
        USING ERRCODE='23514';
  END CASE;

  RETURN jsonb_build_object(
    'request',jsonb_build_object(
      'privacyRequestId',v_request.id,'requestType',v_request.request_type,
      'state',v_request.state,'jurisdiction',v_request.jurisdiction,
      'scopeDigest',btrim(v_request.scope_sha256),
      'identityState',v_request.identity_state,
      'identityVerifiedAt',v_request.identity_verified_at,
      'dueAt',v_request.due_at,'createdAt',v_request.created_at,
      'updatedAt',v_request.updated_at
    ),
    'decisionReasonCode',v_decision_reason_code,
    'decisionReceiptId',v_decision_receipt_id,
    'decisionReceiptSha256',
      CASE WHEN v_decision_receipt_digest IS NULL THEN NULL
           ELSE btrim(v_decision_receipt_digest) END,
    'refusalNoticeReceiptId',v_refusal_notice_id,
    'refusalNoticeReceiptSha256',
      CASE WHEN v_refusal_notice_digest IS NULL THEN NULL
           ELSE btrim(v_refusal_notice_digest) END,
    'noticeReceiptIds',v_notice_ids,
    'noticeReceiptSha256s',v_notice_digests,
    'nextActionCodes',jsonb_build_array(v_next_action),
    'asOf',v_as_of,'links','[]'::jsonb,
    'operationId','getPrivacyRequest'
  );
END
$get$;
ALTER FUNCTION ops.get_privacy_request_v2(char(64),text)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.get_privacy_request_v2(char(64),text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.get_privacy_request_v2(char(64),text)
  TO gurine_submission_api;


COMMIT;
