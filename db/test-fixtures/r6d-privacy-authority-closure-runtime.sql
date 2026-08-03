-- TEST_FIXTURE_ONLY: R6d 0040 privacy-authority closure proof.
--
-- The runner first invokes this file after migrations 0001..0039 with
-- r6d40_seed_legacy defined.  That pass commits only two legacy heads in a
-- disposable database.  After migration 0040, the ordinary pass proves the
-- forward-only staged state, immutable snapshots, exact hold anchors, and
-- fail-closed authority gaps, then rolls every post-migration test row back.

\set ON_ERROR_STOP on

\if :{?r6d40_seed_legacy}
DO $legacy_database_guard$
BEGIN
  IF current_database()<>'gurine_event_consumers' THEN
    RAISE EXCEPTION 'r6d40_fixture_requires_disposable_database'
      USING ERRCODE='55000';
  END IF;
END
$legacy_database_guard$;

BEGIN;
INSERT INTO editorial.cases(
  id,public_slug,title,investigation_state,publication_state,summary,
  priority,version,created_at,updated_at
) VALUES(
  '6d400000-0000-4000-8000-000000000001',
  'r6d40-privacy-authority',
  'TEST_ONLY R6d privacy authority closure',
  'INVESTIGATING','NEVER_PUBLISHED','TEST_ONLY disposable fixture',
  'NORMAL',1,'2000-01-01 00:00:00+00','2000-01-01 00:00:00+00'
);

INSERT INTO editorial.corrections(
  id,case_id,source_revision,summary,reason,affected_claim_ids,status,
  version,created_by,created_at,updated_at,priority
) VALUES(
  '6d400000-0000-4000-8000-000000000002',
  '6d400000-0000-4000-8000-000000000001',1,
  'TEST_ONLY legacy correction summary',
  'TEST_ONLY legacy correction reason','[]'::jsonb,'DRAFT',1,
  '6d400000-0000-4000-8000-000000000010',
  '2000-01-01 00:00:00+00','2000-01-01 00:00:00+00','NORMAL'
);

INSERT INTO intake.subscriptions(
  id,email_hash,email_encrypted,topics,frequency,locale,status,
  verification_token_hash,management_token_hash,created_at,updated_at
) VALUES(
  '6d400000-0000-4000-8000-000000000003',repeat('1',64),
  convert_to('TEST_ONLY legacy encrypted email','UTF8'),
  '["CASE_UPDATES"]'::jsonb,'DAILY','ko-KR','PENDING',repeat('2',64),
  repeat('3',64),'2000-01-01 00:00:00+00','2000-01-01 00:00:00+00'
);
COMMIT;
\quit
\endif

BEGIN ISOLATION LEVEL SERIALIZABLE;
SET CONSTRAINTS ALL DEFERRED;
SET LOCAL TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.r6d40_assert(
  p_condition boolean,
  p_message text
) RETURNS void
LANGUAGE plpgsql
AS $assert$
BEGIN
  IF p_condition IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'r6d40_runtime_assertion_failed:%',p_message
      USING ERRCODE='55000';
  END IF;
END
$assert$;

CREATE FUNCTION pg_temp.r6d40_sha256_text(p_value text)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE STRICT
SECURITY DEFINER
SET search_path=pg_catalog,extensions,pg_temp
AS $digest$
  SELECT encode(
    extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex'
  )::char(64)
$digest$;

CREATE FUNCTION pg_temp.r6d40_uuid(p_label text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE STRICT
SECURITY DEFINER
SET search_path=pg_catalog,extensions,pg_temp
AS $uuid$
  WITH hashed(value) AS (
    SELECT encode(extensions.digest(convert_to(
      'r6d-privacy-authority-runtime:'||p_label,'UTF8'
    ),'sha256'),'hex')
  )
  SELECT (
    substr(value,1,8)||'-'||substr(value,9,4)||'-4'||substr(value,14,3)
    ||'-a'||substr(value,18,3)||'-'||substr(value,21,12)
  )::uuid
  FROM hashed
$uuid$;

SELECT pg_temp.r6d40_assert(
  current_database()='gurine_event_consumers',
  'disposable-database-name'
);

-- Existing rows receive no invented history during migration 0040.
SELECT pg_temp.r6d40_assert(
  (
    SELECT r6d_privacy_snapshot_state='STAGED_LEGACY'
      AND num_nonnulls(
        r6d_privacy_snapshot_id,r6d_privacy_snapshot_version,
        r6d_privacy_snapshot_digest
      )=0
    FROM editorial.corrections
    WHERE id='6d400000-0000-4000-8000-000000000002'
  ),
  'legacy-correction-staged-without-snapshot'
);
SELECT pg_temp.r6d40_assert(
  (
    SELECT r6d_privacy_snapshot_state='STAGED_LEGACY'
      AND num_nonnulls(
        r6d_privacy_snapshot_id,r6d_privacy_snapshot_version,
        r6d_privacy_snapshot_digest
      )=0
    FROM intake.subscriptions
    WHERE id='6d400000-0000-4000-8000-000000000003'
  ),
  'legacy-subscription-staged-without-snapshot'
);
SELECT pg_temp.r6d40_assert(
  NOT EXISTS(
    SELECT 1 FROM ops.privacy_correction_snapshots_v1
    WHERE correction_id='6d400000-0000-4000-8000-000000000002'
  ) AND NOT EXISTS(
    SELECT 1 FROM ops.privacy_subscription_snapshots_v1
    WHERE subscription_id='6d400000-0000-4000-8000-000000000003'
  ),
  'legacy-snapshot-backfill-forbidden'
);

-- The first authoritative write promotes a legacy head and every later write
-- appends exactly one new immutable snapshot.
UPDATE editorial.corrections
SET summary='TEST_ONLY promoted correction summary',version=2
WHERE id='6d400000-0000-4000-8000-000000000002';
UPDATE editorial.corrections
SET reason='TEST_ONLY successor correction reason',version=3
WHERE id='6d400000-0000-4000-8000-000000000002';

UPDATE intake.subscriptions
SET frequency='WEEKLY'
WHERE id='6d400000-0000-4000-8000-000000000003';
UPDATE intake.subscriptions
SET status='PAUSED'
WHERE id='6d400000-0000-4000-8000-000000000003';

INSERT INTO editorial.corrections(
  id,case_id,source_revision,summary,reason,affected_claim_ids,status,
  version,created_by,priority
) VALUES(
  '6d400000-0000-4000-8000-000000000004',
  '6d400000-0000-4000-8000-000000000001',1,
  'TEST_ONLY new correction summary','TEST_ONLY new correction reason',
  '[]'::jsonb,'DRAFT',1,'6d400000-0000-4000-8000-000000000010','NORMAL'
);
INSERT INTO intake.subscriptions(
  id,email_hash,email_encrypted,topics,frequency,locale,status,
  verification_token_hash,management_token_hash
) VALUES(
  '6d400000-0000-4000-8000-000000000005',repeat('4',64),
  convert_to('TEST_ONLY new encrypted email','UTF8'),
  '["CORRECTIONS"]'::jsonb,'IMMEDIATE','ko-KR','PENDING',repeat('5',64),
  repeat('6',64)
);

SELECT pg_temp.r6d40_assert(
  (
    SELECT r6d_privacy_snapshot_state='CURRENT'
      AND r6d_privacy_snapshot_version=2
      AND r6d_privacy_snapshot_id IS NOT NULL
      AND ops.r6d_lower_sha256(r6d_privacy_snapshot_digest)
    FROM editorial.corrections
    WHERE id='6d400000-0000-4000-8000-000000000002'
  ) AND (
    SELECT count(*)=2 AND min(snapshot_version)=1 AND max(snapshot_version)=2
    FROM ops.privacy_correction_snapshots_v1
    WHERE correction_id='6d400000-0000-4000-8000-000000000002'
  ) AND (
    SELECT count(*)=1 AND min(snapshot_version)=1
    FROM ops.privacy_correction_snapshots_v1
    WHERE correction_id='6d400000-0000-4000-8000-000000000004'
  ),
  'correction-snapshot-append-cardinality'
);
SELECT pg_temp.r6d40_assert(
  (
    SELECT r6d_privacy_snapshot_state='CURRENT'
      AND r6d_privacy_snapshot_version=2
      AND r6d_privacy_snapshot_id IS NOT NULL
      AND ops.r6d_lower_sha256(r6d_privacy_snapshot_digest)
    FROM intake.subscriptions
    WHERE id='6d400000-0000-4000-8000-000000000003'
  ) AND (
    SELECT count(*)=2 AND min(snapshot_version)=1 AND max(snapshot_version)=2
    FROM ops.privacy_subscription_snapshots_v1
    WHERE subscription_id='6d400000-0000-4000-8000-000000000003'
  ) AND (
    SELECT count(*)=1 AND min(snapshot_version)=1
    FROM ops.privacy_subscription_snapshots_v1
    WHERE subscription_id='6d400000-0000-4000-8000-000000000005'
  ),
  'subscription-snapshot-append-cardinality'
);

SELECT pg_temp.r6d40_assert(
  NOT EXISTS(
    SELECT 1 FROM ops.privacy_correction_snapshots_v1
    WHERE snapshot_payload ?| ARRAY[
      'summary','reason','replacementContent','triageReason',
      'resolutionReason','email','phone','address','contact','plaintext'
    ]
  ) AND NOT EXISTS(
    SELECT 1 FROM ops.privacy_subscription_snapshots_v1
    WHERE snapshot_payload ?| ARRAY[
      'email','emailEncrypted','topics','verificationToken',
      'managementToken','phone','address','contact','plaintext'
    ]
  ),
  'snapshot-plaintext-exclusion'
);

DO $snapshot_immutability$
DECLARE
  v_update_rejected boolean:=false;
  v_delete_rejected boolean:=false;
  v_insert_rejected boolean:=false;
  v_head_rejected boolean:=false;
BEGIN
  BEGIN
    UPDATE ops.privacy_correction_snapshots_v1
    SET classification='RESTRICTED_GOVERNANCE'
    WHERE correction_id='6d400000-0000-4000-8000-000000000002';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_update_rejected:=true;
  END;
  BEGIN
    DELETE FROM ops.privacy_subscription_snapshots_v1
    WHERE subscription_id='6d400000-0000-4000-8000-000000000003';
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_delete_rejected:=true;
  END;
  BEGIN
    INSERT INTO ops.privacy_correction_snapshots_v1
    SELECT gen_random_uuid(),correction_id,snapshot_version+100,
      source_correction_version,case_id,source_updated_at,snapshot_payload,
      snapshot_canonical,pg_temp.r6d40_sha256_text('direct snapshot'),
      created_at,classification
    FROM ops.privacy_correction_snapshots_v1
    WHERE correction_id='6d400000-0000-4000-8000-000000000002'
    ORDER BY snapshot_version DESC LIMIT 1;
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_insert_rejected:=true;
  END;
  BEGIN
    UPDATE editorial.corrections
    SET r6d_privacy_snapshot_digest=repeat('f',64)
    WHERE id='6d400000-0000-4000-8000-000000000002';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_head_rejected:=true;
  END;
  PERFORM pg_temp.r6d40_assert(
    v_update_rejected AND v_delete_rejected AND v_insert_rejected
      AND v_head_rejected,
    'snapshot-owner-and-head-immutability'
  );
END
$snapshot_immutability$;

-- Q1: users.manage is the sole privacy-governance capability.  A caller with
-- only sources.operate cannot pass even while claiming the correct capability,
-- and an explicit sources.operate transport claim is rejected earlier.
INSERT INTO ops.users(
  id,oidc_subject,email,display_name,status
) VALUES
  (
    '6d400000-0000-4000-8000-000000000010','r6d40-users-manager',
    'r6d40-users-manager@example.test','TEST_ONLY users manager','ACTIVE'
  ),
  (
    '6d400000-0000-4000-8000-000000000011','r6d40-source-operator',
    'r6d40-source-operator@example.test','TEST_ONLY source operator','ACTIVE'
  );
INSERT INTO ops.roles(id,code,name,description,risk_level,system_role) VALUES
  (
    '6d400000-0000-4000-8000-000000000012','TEST_R6D40_PRIVACY_GOVERNOR',
    'TEST_ONLY privacy governor','TEST_ONLY runtime authority','CRITICAL',false
  ),
  (
    '6d400000-0000-4000-8000-000000000013','TEST_R6D40_SOURCE_OPERATOR',
    'TEST_ONLY source operator','TEST_ONLY runtime authority','HIGH',false
  );
INSERT INTO ops.role_capabilities(role_id,capability_code) VALUES
  ('6d400000-0000-4000-8000-000000000012','users.manage'),
  ('6d400000-0000-4000-8000-000000000012','review.legal'),
  ('6d400000-0000-4000-8000-000000000013','sources.operate'),
  ('6d400000-0000-4000-8000-000000000013','review.legal');
INSERT INTO ops.user_roles(
  id,user_id,role_id,granted_by,reason,granted_at
) VALUES
  (
    '6d400000-0000-4000-8000-000000000014',
    '6d400000-0000-4000-8000-000000000010',
    '6d400000-0000-4000-8000-000000000012',
    '6d400000-0000-4000-8000-000000000010',
    'TEST_ONLY users.manage proof',clock_timestamp()
  ),
  (
    '6d400000-0000-4000-8000-000000000015',
    '6d400000-0000-4000-8000-000000000011',
    '6d400000-0000-4000-8000-000000000013',
    '6d400000-0000-4000-8000-000000000011',
    'TEST_ONLY sources.operate negative proof',clock_timestamp()
  );
INSERT INTO ops.sessions(
  id,user_id,session_token_hash,csrf_token_hash,auth_time,step_up_at,expires_at
) VALUES
  (
    '6d400000-0000-4000-8000-000000000016',
    '6d400000-0000-4000-8000-000000000010',repeat('7',64),repeat('8',64),
    clock_timestamp()-interval '10 minutes',
    clock_timestamp()-interval '2 minutes',clock_timestamp()+interval '1 hour'
  ),
  (
    '6d400000-0000-4000-8000-000000000017',
    '6d400000-0000-4000-8000-000000000011',repeat('9',64),repeat('a',64),
    clock_timestamp()-interval '10 minutes',
    clock_timestamp()-interval '2 minutes',clock_timestamp()+interval '1 hour'
  );

CREATE FUNCTION pg_temp.r6d40_seed_entity_authority(
  p_actor_id uuid,
  p_session_id uuid,
  p_label text
) RETURNS jsonb
LANGUAGE plpgsql
AS $authority$
DECLARE
  v_action char(64):=pg_temp.r6d40_sha256_text('action:'||p_label);
  v_idempotency char(64):=pg_temp.r6d40_sha256_text('idempotency:'||p_label);
  v_request char(64):=pg_temp.r6d40_sha256_text('request:'||p_label);
  v_assertion_digest char(64):=
    pg_temp.r6d40_sha256_text('assertion:'||p_label);
  v_step_up_id uuid:=pg_temp.r6d40_uuid('step-up:'||p_label);
  v_assertion_id uuid:=pg_temp.r6d40_uuid('assertion:'||p_label);
BEGIN
  INSERT INTO ops.step_up_authorizations(
    id,session_id,action_digest,idempotency_key_sha256,
    authorization_token_hash,expires_at,assertion_issue_count,
    max_assertion_issues,last_issued_at
  ) VALUES(
    v_step_up_id,p_session_id,v_action,v_idempotency,
    pg_temp.r6d40_sha256_text('token:'||p_label),
    clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  );
  INSERT INTO ops.assertion_replay_guard(
    assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
  ) VALUES(
    'ACTOR',v_assertion_id,'identity-api','control-api',v_assertion_digest,
    clock_timestamp()+interval '10 minutes',
    clock_timestamp()-interval '1 minute'
  );
  INSERT INTO ops.idempotency_keys(
    scope,key_hash,request_hash,expires_at
  ) VALUES(
    'control:'||p_actor_id::text||':classifyEntityPersonhood',
    v_idempotency,v_request,clock_timestamp()+interval '1 hour'
  );
  RETURN jsonb_build_object(
    'classification','NOT_NATURAL_PERSON',
    '_actorAssertionJti',v_assertion_id,
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','users.manage',
    '_actorActionDigest',btrim(v_action),
    '_actorStepUpAuthorizationId',v_step_up_id,
    '_actorIdempotencyKeySha256',btrim(v_idempotency),
    '_actorRequestKeySha256',btrim(v_idempotency),
    '_actorAssertionRequestSha256',btrim(v_assertion_digest),
    '_testRequestDigest',btrim(v_request)
  );
END
$authority$;

INSERT INTO core.agencies(
  id,canonical_name,agency_type,jurisdiction,active,identity_status,
  created_at,updated_at
) VALUES
  (
    '6d400000-0000-4000-8000-000000000030',
    'TEST_ONLY users.manage positive entity','OTHER','KR',true,'VERIFIED',
    '2000-01-01 00:00:00+00','2000-01-01 00:00:00+00'
  ),
  (
    '6d400000-0000-4000-8000-000000000031',
    'TEST_ONLY sources.operate negative entity','OTHER','KR',true,'VERIFIED',
    '2000-01-01 00:00:00+00','2000-01-01 00:00:00+00'
  );

DO $q1_capability$
DECLARE
  v_positive jsonb:=pg_temp.r6d40_seed_entity_authority(
    '6d400000-0000-4000-8000-000000000010',
    '6d400000-0000-4000-8000-000000000016','positive'
  );
  v_negative jsonb:=pg_temp.r6d40_seed_entity_authority(
    '6d400000-0000-4000-8000-000000000011',
    '6d400000-0000-4000-8000-000000000017','negative'
  );
  v_claim_rejected boolean:=false;
  v_capability_rejected boolean:=false;
  v_owner_rejected boolean:=false;
  v_result jsonb;
  v_owner_request jsonb;
BEGIN
  v_result:=ops.r6d_entity_human_step_up_authority_v1(
    v_positive-'_testRequestDigest',
    '6d400000-0000-4000-8000-000000000010',
    '6d400000-0000-4000-8000-000000000016',
    pg_temp.r6d40_uuid('q1-positive-request'),
    (v_positive->>'_actorIdempotencyKeySha256')::char(64),
    (v_positive->>'_testRequestDigest')::char(64),clock_timestamp()
  );
  BEGIN
    PERFORM ops.r6d_entity_human_step_up_authority_v1(
      (v_positive-'_testRequestDigest')||jsonb_build_object(
        '_actorEffectiveCapability','sources.operate'
      ),
      '6d400000-0000-4000-8000-000000000010',
      '6d400000-0000-4000-8000-000000000016',
      pg_temp.r6d40_uuid('q1-wrong-claim-request'),
      (v_positive->>'_actorIdempotencyKeySha256')::char(64),
      (v_positive->>'_testRequestDigest')::char(64),clock_timestamp()
    );
  EXCEPTION WHEN SQLSTATE '23514' THEN
    v_claim_rejected:=SQLERRM='r6d_entity_actor_binding_invalid';
  END;
  BEGIN
    PERFORM ops.r6d_entity_human_step_up_authority_v1(
      v_negative-'_testRequestDigest',
      '6d400000-0000-4000-8000-000000000011',
      '6d400000-0000-4000-8000-000000000017',
      pg_temp.r6d40_uuid('q1-negative-request'),
      (v_negative->>'_actorIdempotencyKeySha256')::char(64),
      (v_negative->>'_testRequestDigest')::char(64),clock_timestamp()
    );
  EXCEPTION WHEN SQLSTATE '23514' THEN
    v_capability_rejected:=SQLERRM='r6d_entity_capability_invalid';
  END;

  v_owner_request:=(v_positive-'classification'-'_testRequestDigest')||
    jsonb_build_object(
      'entityKind','AGENCY',
      'entityId','6d400000-0000-4000-8000-000000000030',
      'classification','NOT_NATURAL_PERSON',
      'evidenceSourceLocator','test-only/r6d40#public-registration-form',
      'reason','TEST_ONLY human privacy-governance classification',
      'expectedEntityUpdatedAt',(
        SELECT updated_at FROM core.agencies
        WHERE id='6d400000-0000-4000-8000-000000000030'
      )
    );
  v_result:=ops.classify_r6d_entity_personhood_v1(
    v_owner_request,'6d400000-0000-4000-8000-000000000010',
    '6d400000-0000-4000-8000-000000000016',
    pg_temp.r6d40_uuid('q1-positive-request'),
    (v_positive->>'_actorIdempotencyKeySha256')::char(64),
    (v_positive->>'_testRequestDigest')::char(64)
  );
  v_owner_request:=(v_negative-'classification'-'_testRequestDigest')||
    jsonb_build_object(
      'entityKind','AGENCY',
      'entityId','6d400000-0000-4000-8000-000000000031',
      'classification','NOT_NATURAL_PERSON',
      'evidenceSourceLocator','test-only/r6d40#public-registration-form',
      'reason','TEST_ONLY source capability must not classify personhood',
      'expectedEntityUpdatedAt',(
        SELECT updated_at FROM core.agencies
        WHERE id='6d400000-0000-4000-8000-000000000031'
      )
    );
  BEGIN
    PERFORM ops.classify_r6d_entity_personhood_v1(
      v_owner_request,'6d400000-0000-4000-8000-000000000011',
      '6d400000-0000-4000-8000-000000000017',
      pg_temp.r6d40_uuid('q1-negative-request'),
      (v_negative->>'_actorIdempotencyKeySha256')::char(64),
      (v_negative->>'_testRequestDigest')::char(64)
    );
  EXCEPTION WHEN SQLSTATE '23514' THEN
    v_owner_rejected:=SQLERRM='r6d_entity_capability_invalid';
  END;
  PERFORM pg_temp.r6d40_assert(
    ops.r6d_lower_sha256(v_result->>'receiptDigest')
      AND v_claim_rejected AND v_capability_rejected AND v_owner_rejected
      AND EXISTS(
        SELECT 1
        FROM ops.r6d_entity_personhood_classification_receipts_v1
        WHERE entity_kind='AGENCY'
          AND entity_id='6d400000-0000-4000-8000-000000000030'
          AND classification='NOT_NATURAL_PERSON'
      )
      AND NOT EXISTS(
        SELECT 1
        FROM ops.r6d_entity_personhood_classification_receipts_v1
        WHERE entity_id='6d400000-0000-4000-8000-000000000031'
      )
      AND (
        SELECT r6d_anonymization_state='STAGED_LEGACY'
          AND r6d_personhood_receipt_id IS NULL
        FROM core.agencies
        WHERE id='6d400000-0000-4000-8000-000000000031'
      ),
    'q1-users-manage-positive-sources-operate-negative'
  );
END
$q1_capability$;

-- Establish the minimal immutable case context and communication endpoint used
-- by the three Q5 target owners.  These are TEST_ONLY fixture records.
INSERT INTO editorial.review_snapshots(
  id,case_id,case_version,snapshot_sha256,snapshot_payload,
  automated_gate_results,unresolved_blockers,created_by
) VALUES(
  '6d400000-0000-4000-8000-000000000020',
  '6d400000-0000-4000-8000-000000000001',1,repeat('b',64),
  '{"schemaVersion":"TEST_ONLY-r6d40-review.v1"}'::jsonb,
  '{}'::jsonb,'[]'::jsonb,'6d400000-0000-4000-8000-000000000010'
);
UPDATE editorial.cases
SET current_review_snapshot_id='6d400000-0000-4000-8000-000000000020'
WHERE id='6d400000-0000-4000-8000-000000000001';

INSERT INTO intake.communication_subjects(
  id,subject_kind,origin_object_type,origin_object_id,origin_object_version,
  origin_binding_digest,subject_pseudonym_hmac,hmac_key_version,jurisdiction,
  locale,status,profile_version,profile_digest
) VALUES(
  '6d400000-0000-4000-8000-000000000021','INTERNAL_USER','INTERNAL_USER',
  '6d400000-0000-4000-8000-000000000010',1,repeat('c',64),repeat('d',64),
  'test-key-v1','KR','ko-KR','ACTIVE',1,repeat('e',64)
);
INSERT INTO intake.communication_endpoints(
  id,subject_id,channel,endpoint_hmac,hmac_key_version,endpoint_ciphertext,
  encryption_key_id,state,version,endpoint_digest,verified_at
) VALUES(
  '6d400000-0000-4000-8000-000000000022',
  '6d400000-0000-4000-8000-000000000021','SMTP_EMAIL',repeat('f',64),
  'test-key-v1',convert_to('TEST_ONLY endpoint ciphertext','UTF8'),
  'test-envelope-key@v1','ACTIVE',1,repeat('0',64),clock_timestamp()
);
INSERT INTO editorial.evidence(
  id,case_id,evidence_type,title,description,source_locator,content_sha256,
  classification,verification_status,verified_by,verified_at,version,
  created_by
) VALUES(
  '6d400000-0000-4000-8000-000000000023',
  '6d400000-0000-4000-8000-000000000001','DOCUMENT',
  'TEST_ONLY pre-0040 hold target','TEST_ONLY legacy target regression',
  'test-only/r6d40#legacy-evidence',repeat('a',64),'PUBLIC','VERIFIED',
  '6d400000-0000-4000-8000-000000000010',clock_timestamp(),1,
  '6d400000-0000-4000-8000-000000000010'
);
INSERT INTO editorial.evidence(
  id,case_id,evidence_type,title,description,source_locator,content_sha256,
  classification,verification_status,verified_by,verified_at,version,
  created_by
) VALUES(
  '6d400000-0000-4000-8000-000000000024',
  '6d400000-0000-4000-8000-000000000001','DOCUMENT',
  'TEST_ONLY privacy coverage hold target',
  'TEST_ONLY exact materialized coverage target',
  'test-only/r6d40#privacy-coverage-evidence',repeat('9',64),
  'PUBLIC','VERIFIED','6d400000-0000-4000-8000-000000000010',
  clock_timestamp(),1,'6d400000-0000-4000-8000-000000000010'
);

CREATE FUNCTION pg_temp.r6d40_seed_hold_authority(
  p_target jsonb,
  p_label text
) RETURNS jsonb
LANGUAGE plpgsql
AS $hold$
DECLARE
  v_actor_id constant uuid:='6d400000-0000-4000-8000-000000000010';
  v_session_id constant uuid:='6d400000-0000-4000-8000-000000000016';
  v_target_kind text:=p_target->>'targetKind';
  v_target_id uuid:=(p_target->>'targetId')::uuid;
  v_target_version bigint:=(p_target->>'targetVersion')::bigint;
  v_target_digest char(64):=(p_target->>'targetDigest')::char(64);
  v_action char(64):=pg_temp.r6d40_sha256_text('hold-action:'||p_label);
  v_idempotency char(64):=
    pg_temp.r6d40_sha256_text('hold-idempotency:'||p_label);
  v_request char(64):=pg_temp.r6d40_sha256_text('hold-request:'||p_label);
  v_assertion_digest char(64):=
    pg_temp.r6d40_sha256_text('hold-assertion:'||p_label);
  v_step_up_id uuid:=pg_temp.r6d40_uuid('hold-step-up:'||p_label);
  v_assertion_id uuid:=pg_temp.r6d40_uuid('hold-assertion:'||p_label);
  v_request_id uuid:=pg_temp.r6d40_uuid('hold-request:'||p_label);
  v_conflict_id uuid:=pg_temp.r6d40_uuid('hold-conflict:'||p_label);
  v_binding text:=v_target_kind||':'||v_target_id::text||':'||
    v_target_version::text||':'||btrim(v_target_digest)||':placeLegalHold';
BEGIN
  INSERT INTO ops.step_up_authorizations(
    id,session_id,action_digest,idempotency_key_sha256,
    authorization_token_hash,expires_at,assertion_issue_count,
    max_assertion_issues,last_issued_at
  ) VALUES(
    v_step_up_id,v_session_id,v_action,v_idempotency,
    pg_temp.r6d40_sha256_text('hold-token:'||p_label),
    clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  );
  INSERT INTO ops.assertion_replay_guard(
    assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
  ) VALUES(
    'ACTOR',v_assertion_id,'identity-api','control-api',v_assertion_digest,
    clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
  );
  INSERT INTO editorial.conflict_snapshots(
    id,subject_actor_id,target_type,target_id,target_version,target_digest,
    operation_id,action_kind,candidate_role,declaration_ids,
    declaration_set_digest,finding_set,finding_set_digest,
    authorship_digest,party_recipient_digest,role_digest,
    relationship_digest,funding_customer_digest,policy_digest,
    evaluation_state,blocker_codes,nonwaivable_blocker_count,
    evaluated_at,valid_until,evaluated_by_type,evaluated_by_id,
    snapshot_sha256,receipt_digest
  ) VALUES(
    v_conflict_id,v_actor_id,v_target_kind,v_target_id::text,
    v_target_version,v_target_digest,'placeLegalHold',NULL,'LEGAL_REVIEWER',
    '{}'::uuid[],pg_temp.r6d40_sha256_text('declarations:'||v_binding),
    '{}'::jsonb,pg_temp.r6d40_sha256_text('findings:'||v_binding),
    pg_temp.r6d40_sha256_text('authorship:'||v_binding),
    pg_temp.r6d40_sha256_text('party:'||v_binding),
    pg_temp.r6d40_sha256_text('role:'||v_binding),
    pg_temp.r6d40_sha256_text('relationship:'||v_binding),
    pg_temp.r6d40_sha256_text('funding:'||v_binding),
    pg_temp.r6d40_sha256_text('policy:'||v_binding),'CLEAR','{}'::text[],0,
    clock_timestamp()-interval '1 second',clock_timestamp()+interval '10 minutes',
    'SERVICE','r6d40-privacy-authority',
    pg_temp.r6d40_sha256_text('snapshot:'||v_binding),
    pg_temp.r6d40_sha256_text('receipt:'||v_binding)
  );
  RETURN jsonb_build_object(
    'payload',jsonb_build_object(
      'target',p_target,'scopeAtoms',jsonb_build_array('RETENTION'),
      'affectedIds',jsonb_build_array(v_target_id),
      'authorityReference','TEST_ONLY R6d privacy hold authority',
      'reasonCode','LEGAL_PRESERVATION_REQUIRED',
      'reason','TEST_ONLY preserve exact privacy object revision',
      'expiresAt',NULL,'_actorAssertionJti',v_assertion_id,
      '_actorAssuranceLevel','STEP_UP',
      '_actorEffectiveCapability','review.legal',
      '_actorAssertionRequestSha256',btrim(v_assertion_digest),
      '_actorActionDigest',btrim(v_action),
      '_actorStepUpAuthorizationId',v_step_up_id,
      '_actorIdempotencyKeySha256',btrim(v_idempotency),
      '_actorRequestKeySha256',btrim(v_idempotency),
      '_requestId',v_request_id,'_requestSha256',btrim(v_request),
      '_idempotencyKeySha256',btrim(v_idempotency)
    ),
    'requestId',v_request_id,'idempotencyKey',btrim(v_idempotency),
    'requestDigest',btrim(v_request)
  );
END
$hold$;

CREATE FUNCTION pg_temp.r6d40_place_hold(
  p_target jsonb,
  p_label text
) RETURNS jsonb
LANGUAGE plpgsql
AS $place$
DECLARE
  v_authority jsonb:=pg_temp.r6d40_seed_hold_authority(p_target,p_label);
BEGIN
  RETURN ops.place_legal_hold_v2(
    v_authority->'payload',
    '6d400000-0000-4000-8000-000000000010',
    (v_authority->>'requestId')::uuid,
    (v_authority->>'idempotencyKey')::char(64),
    (v_authority->>'requestDigest')::char(64)
  );
END
$place$;

DO $q5_holds$
DECLARE
  v_correction editorial.corrections%ROWTYPE;
  v_subscription intake.subscriptions%ROWTYPE;
  v_endpoint intake.communication_endpoints%ROWTYPE;
  v_target jsonb;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_correction FROM editorial.corrections
  WHERE id='6d400000-0000-4000-8000-000000000002';
  SELECT * INTO STRICT v_subscription FROM intake.subscriptions
  WHERE id='6d400000-0000-4000-8000-000000000003';
  SELECT * INTO STRICT v_endpoint FROM intake.communication_endpoints
  WHERE id='6d400000-0000-4000-8000-000000000022';

  v_target:=jsonb_build_object(
    'targetKind','CORRECTION','targetId',v_correction.r6d_privacy_snapshot_id,
    'targetVersion',v_correction.r6d_privacy_snapshot_version,
    'targetDigest',btrim(v_correction.r6d_privacy_snapshot_digest),
    'correctionId',v_correction.id,
    'correctionSnapshotId',v_correction.r6d_privacy_snapshot_id,
    'correctionSnapshotDigest',btrim(v_correction.r6d_privacy_snapshot_digest)
  );
  v_result:=pg_temp.r6d40_place_hold(v_target,'correction');
  PERFORM pg_temp.r6d40_assert(
    COALESCE((v_result->>'replayed')::boolean,true)=false,
    'correction-hold-placement-result'
  );

  v_target:=jsonb_build_object(
    'targetKind','SUBSCRIPTION',
    'targetId',v_subscription.r6d_privacy_snapshot_id,
    'targetVersion',v_subscription.r6d_privacy_snapshot_version,
    'targetDigest',btrim(v_subscription.r6d_privacy_snapshot_digest),
    'subscriptionId',v_subscription.id,
    'subscriptionSnapshotId',v_subscription.r6d_privacy_snapshot_id,
    'subscriptionSnapshotDigest',
      btrim(v_subscription.r6d_privacy_snapshot_digest)
  );
  v_result:=pg_temp.r6d40_place_hold(v_target,'subscription');
  PERFORM pg_temp.r6d40_assert(
    COALESCE((v_result->>'replayed')::boolean,true)=false,
    'subscription-hold-placement-result'
  );

  v_target:=jsonb_build_object(
    'targetKind','COMMUNICATION_ENDPOINT','targetId',v_endpoint.id,
    'targetVersion',v_endpoint.version,
    'targetDigest',btrim(v_endpoint.endpoint_digest),
    'communicationEndpointId',v_endpoint.id
  );
  v_result:=pg_temp.r6d40_place_hold(v_target,'endpoint');
  PERFORM pg_temp.r6d40_assert(
    COALESCE((v_result->>'replayed')::boolean,true)=false,
    'communication-endpoint-hold-placement-result'
  );

  -- The Q5 dispatcher must preserve a real pre-0040 target path as well as
  -- its entity advisory wrapper.  This insert exercises the legacy anchor
  -- branch after the reciprocal anchor FK changed to MATCH SIMPLE.
  v_target:=jsonb_build_object(
    'targetKind','EVIDENCE',
    'targetId','6d400000-0000-4000-8000-000000000023',
    'targetVersion',1,'targetDigest',repeat('a',64),
    'evidenceId','6d400000-0000-4000-8000-000000000023'
  );
  v_result:=pg_temp.r6d40_place_hold(v_target,'legacy-evidence');
  PERFORM pg_temp.r6d40_assert(
    COALESCE((v_result->>'replayed')::boolean,true)=false,
    'pre-0040-evidence-hold-placement-regression'
  );
END
$q5_holds$;

SELECT pg_temp.r6d40_assert(
  (
    SELECT count(*)=3 FROM editorial.legal_holds
    WHERE object_type IN ('CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT')
      AND active
  ) AND (
    SELECT count(*)=3 FROM ops.legal_hold_placement_receipts_v2
    WHERE target_kind IN ('CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT')
  ) AND EXISTS(
    SELECT 1 FROM ops.legal_hold_target_anchors AS anchor
    JOIN editorial.corrections AS correction
      ON correction.r6d_privacy_snapshot_id=anchor.target_id
     AND correction.r6d_privacy_snapshot_version=anchor.target_version
     AND correction.r6d_privacy_snapshot_digest=anchor.target_digest
    WHERE anchor.target_kind='CORRECTION'
      AND anchor.correction_id=correction.id
      AND anchor.correction_snapshot_id=correction.r6d_privacy_snapshot_id
      AND anchor.correction_snapshot_digest=correction.r6d_privacy_snapshot_digest
  ) AND EXISTS(
    SELECT 1 FROM ops.legal_hold_target_anchors AS anchor
    JOIN intake.subscriptions AS subscription
      ON subscription.r6d_privacy_snapshot_id=anchor.target_id
     AND subscription.r6d_privacy_snapshot_version=anchor.target_version
     AND subscription.r6d_privacy_snapshot_digest=anchor.target_digest
    WHERE anchor.target_kind='SUBSCRIPTION'
      AND anchor.subscription_id=subscription.id
      AND anchor.subscription_snapshot_id=subscription.r6d_privacy_snapshot_id
      AND anchor.subscription_snapshot_digest=
        subscription.r6d_privacy_snapshot_digest
  ) AND EXISTS(
    SELECT 1 FROM ops.legal_hold_target_anchors AS anchor
    JOIN intake.communication_endpoints AS endpoint
      ON endpoint.id=anchor.target_id
     AND endpoint.version=anchor.target_version
     AND endpoint.endpoint_digest=anchor.target_digest
    WHERE anchor.target_kind='COMMUNICATION_ENDPOINT'
      AND anchor.communication_endpoint_id=endpoint.id
      AND anchor.communication_endpoint_version=endpoint.version
      AND anchor.communication_endpoint_digest=endpoint.endpoint_digest
  ) AND EXISTS(
    SELECT 1 FROM ops.legal_hold_target_anchors AS anchor
    WHERE anchor.target_kind='EVIDENCE'
      AND anchor.target_id='6d400000-0000-4000-8000-000000000023'
      AND anchor.target_version=1 AND anchor.target_digest=repeat('a',64)
      AND anchor.evidence_id=anchor.target_id
  ),
  'q5-three-exact-hold-anchors-and-legacy-regression'
);

DO $q5_changed_digest_zero_write$
DECLARE
  v_before_holds bigint;
  v_before_anchors bigint;
  v_before_receipts bigint;
  v_before_audit bigint;
  v_before_outbox bigint;
  v_rejected boolean:=false;
  v_target jsonb;
BEGIN
  SELECT count(*) INTO v_before_holds FROM editorial.legal_holds;
  SELECT count(*) INTO v_before_anchors FROM ops.legal_hold_target_anchors;
  SELECT count(*) INTO v_before_receipts
  FROM ops.legal_hold_placement_receipts_v2;
  SELECT count(*) INTO v_before_audit FROM ops.audit_events;
  SELECT count(*) INTO v_before_outbox FROM ops.outbox;
  SELECT jsonb_build_object(
    'targetKind','CORRECTION','targetId',r6d_privacy_snapshot_id,
    'targetVersion',r6d_privacy_snapshot_version,
    'targetDigest',repeat('f',64),'correctionId',id,
    'correctionSnapshotId',r6d_privacy_snapshot_id,
    'correctionSnapshotDigest',repeat('f',64)
  ) INTO STRICT v_target
  FROM editorial.corrections
  WHERE id='6d400000-0000-4000-8000-000000000002';
  BEGIN
    PERFORM pg_temp.r6d40_place_hold(v_target,'correction-changed-digest');
  EXCEPTION WHEN SQLSTATE '40001' THEN
    v_rejected:=SQLERRM='legal_hold_v2_target_stale';
  END;
  PERFORM pg_temp.r6d40_assert(
    v_rejected
      AND (SELECT count(*) FROM editorial.legal_holds)=v_before_holds
      AND (SELECT count(*) FROM ops.legal_hold_target_anchors)=v_before_anchors
      AND (SELECT count(*) FROM ops.legal_hold_placement_receipts_v2)=
        v_before_receipts
      AND (SELECT count(*) FROM ops.audit_events)=v_before_audit
      AND (SELECT count(*) FROM ops.outbox)=v_before_outbox
      AND EXISTS(
        SELECT 1 FROM editorial.legal_holds
        WHERE object_type='CORRECTION' AND active
      ),
    'changed-digest-zero-write-and-no-release'
  );
END
$q5_changed_digest_zero_write$;

-- Release is governed by the immutable placement/anchor chain, not by a later
-- mutable correction/subscription head.  Exercise all three new kinds, then
-- advance both mutable heads and prove a fresh-assertion exact retry returns
-- the stored release without another release/audit/outbox write.
CREATE FUNCTION pg_temp.r6d40_seed_release_authority(
  p_target_kind text,
  p_label text
) RETURNS jsonb
LANGUAGE plpgsql
AS $release$
DECLARE
  v_actor_id constant uuid:='6d400000-0000-4000-8000-000000000011';
  v_session_id constant uuid:='6d400000-0000-4000-8000-000000000017';
  v_placement ops.legal_hold_placement_receipts_v2%ROWTYPE;
  v_action char(64):=pg_temp.r6d40_sha256_text('release-action:'||p_label);
  v_idempotency char(64):=
    pg_temp.r6d40_sha256_text('release-idempotency:'||p_label);
  v_request char(64):=pg_temp.r6d40_sha256_text('release-request:'||p_label);
  v_assertion_digest char(64):=
    pg_temp.r6d40_sha256_text('release-assertion:'||p_label);
  v_step_up_id uuid:=pg_temp.r6d40_uuid('release-step-up:'||p_label);
  v_assertion_id uuid:=pg_temp.r6d40_uuid('release-assertion:'||p_label);
  v_request_id uuid:=pg_temp.r6d40_uuid('release-request:'||p_label);
  v_conflict_id uuid:=pg_temp.r6d40_uuid('release-conflict:'||p_label);
  v_binding text;
BEGIN
  SELECT * INTO STRICT v_placement
  FROM ops.legal_hold_placement_receipts_v2
  WHERE target_kind=p_target_kind;
  v_binding:='LEGAL_HOLD:'||v_placement.legal_hold_id::text||':1:'||
    btrim(v_placement.receipt_digest)||':releaseLegalHold';
  INSERT INTO ops.step_up_authorizations(
    id,session_id,action_digest,idempotency_key_sha256,
    authorization_token_hash,expires_at,assertion_issue_count,
    max_assertion_issues,last_issued_at
  ) VALUES(
    v_step_up_id,v_session_id,v_action,v_idempotency,
    pg_temp.r6d40_sha256_text('release-token:'||p_label),
    clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  );
  INSERT INTO ops.assertion_replay_guard(
    assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
  ) VALUES(
    'ACTOR',v_assertion_id,'identity-api','control-api',v_assertion_digest,
    clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
  );
  INSERT INTO editorial.conflict_snapshots(
    id,subject_actor_id,target_type,target_id,target_version,target_digest,
    operation_id,action_kind,candidate_role,declaration_ids,
    declaration_set_digest,finding_set,finding_set_digest,
    authorship_digest,party_recipient_digest,role_digest,
    relationship_digest,funding_customer_digest,policy_digest,
    evaluation_state,blocker_codes,nonwaivable_blocker_count,
    evaluated_at,valid_until,evaluated_by_type,evaluated_by_id,
    snapshot_sha256,receipt_digest
  ) VALUES(
    v_conflict_id,v_actor_id,'LEGAL_HOLD',v_placement.legal_hold_id::text,1,
    v_placement.receipt_digest,'releaseLegalHold',NULL,'LEGAL_REVIEWER',
    '{}'::uuid[],pg_temp.r6d40_sha256_text('declarations:'||v_binding),
    '{}'::jsonb,pg_temp.r6d40_sha256_text('findings:'||v_binding),
    pg_temp.r6d40_sha256_text('authorship:'||v_binding),
    pg_temp.r6d40_sha256_text('party:'||v_binding),
    pg_temp.r6d40_sha256_text('role:'||v_binding),
    pg_temp.r6d40_sha256_text('relationship:'||v_binding),
    pg_temp.r6d40_sha256_text('funding:'||v_binding),
    pg_temp.r6d40_sha256_text('policy:'||v_binding),'CLEAR','{}'::text[],0,
    clock_timestamp()-interval '1 second',clock_timestamp()+interval '10 minutes',
    'SERVICE','r6d40-privacy-release',
    pg_temp.r6d40_sha256_text('snapshot:'||v_binding),
    pg_temp.r6d40_sha256_text('receipt:'||v_binding)
  );
  RETURN jsonb_build_object(
    'payload',jsonb_build_object(
      'holdId',v_placement.legal_hold_id,
      'targetAnchorId',v_placement.anchor_id,
      'expectedReleaseSequence',0,
      'releaseScopeAtoms',jsonb_build_array('RETENTION'),
      'affectedIds',to_jsonb(v_placement.affected_ids),
      'releaseAuthorityReference','TEST_ONLY R6d privacy release authority',
      'reasonCode','RESOLVED','reason','TEST_ONLY exact privacy hold release',
      '_actorAssertionJti',v_assertion_id,
      '_actorAssuranceLevel','STEP_UP',
      '_actorEffectiveCapability','review.legal',
      '_actorAssertionRequestSha256',btrim(v_assertion_digest),
      '_actorActionDigest',btrim(v_action),
      '_actorStepUpAuthorizationId',v_step_up_id,
      '_actorIdempotencyKeySha256',btrim(v_idempotency),
      '_actorRequestKeySha256',btrim(v_idempotency),
      '_requestId',v_request_id,'_requestSha256',btrim(v_request),
      '_idempotencyKeySha256',btrim(v_idempotency)
    ),
    'requestId',v_request_id,'idempotencyKey',btrim(v_idempotency),
    'requestDigest',btrim(v_request),
    'assertionDigest',btrim(v_assertion_digest)
  );
END
$release$;

DO $q5_release_and_replay$
DECLARE
  v_kind text;
  v_authority jsonb;
  v_first jsonb;
  v_replay jsonb;
  v_replay_jti uuid;
  v_before_release bigint;
  v_before_audit bigint;
  v_before_outbox bigint;
BEGIN
  FOREACH v_kind IN ARRAY ARRAY[
    'CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT'
  ] LOOP
    v_authority:=pg_temp.r6d40_seed_release_authority(
      v_kind,lower(v_kind)
    );
    v_first:=ops.release_legal_hold_v2(
      v_authority->'payload',
      '6d400000-0000-4000-8000-000000000011',
      (v_authority->>'requestId')::uuid,
      (v_authority->>'idempotencyKey')::char(64),
      (v_authority->>'requestDigest')::char(64)
    );
    PERFORM pg_temp.r6d40_assert(
      COALESCE((v_first->>'replayed')::boolean,true)=false
        AND (v_first->'release'->>'releaseSequence')::bigint=1,
      'privacy-hold-release-first:'||v_kind
    );

    IF v_kind='CORRECTION' THEN
      UPDATE editorial.corrections
      SET summary='TEST_ONLY post-release successor',version=version+1
      WHERE id='6d400000-0000-4000-8000-000000000002';
    ELSIF v_kind='SUBSCRIPTION' THEN
      UPDATE intake.subscriptions
      SET frequency='DAILY'
      WHERE id='6d400000-0000-4000-8000-000000000003';
    END IF;

    v_replay_jti:=pg_temp.r6d40_uuid('release-replay:'||lower(v_kind));
    INSERT INTO ops.assertion_replay_guard(
      assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
    ) VALUES(
      'ACTOR',v_replay_jti,'identity-api','control-api',
      (v_authority->>'assertionDigest')::char(64),
      clock_timestamp()+interval '10 minutes',
      clock_timestamp()-interval '1 minute'
    );
    SELECT count(*) INTO v_before_release
    FROM editorial.legal_hold_releases;
    SELECT count(*) INTO v_before_audit FROM ops.audit_events;
    SELECT count(*) INTO v_before_outbox FROM ops.outbox;
    v_replay:=ops.release_legal_hold_v2(
      (v_authority->'payload')||jsonb_build_object(
        '_actorAssertionJti',v_replay_jti
      ),
      '6d400000-0000-4000-8000-000000000011',
      (v_authority->>'requestId')::uuid,
      (v_authority->>'idempotencyKey')::char(64),
      (v_authority->>'requestDigest')::char(64)
    );
    PERFORM pg_temp.r6d40_assert(
      COALESCE((v_replay->>'replayed')::boolean,false)
        AND v_replay->>'receiptDigest'=v_first->>'receiptDigest'
        AND (SELECT count(*) FROM editorial.legal_hold_releases)=
          v_before_release
        AND (SELECT count(*) FROM ops.audit_events)=v_before_audit
        AND (SELECT count(*) FROM ops.outbox)=v_before_outbox,
      'privacy-hold-release-exact-replay-zero-write:'||v_kind
    );
  END LOOP;
  PERFORM pg_temp.r6d40_assert(
    (
      SELECT count(*)=3 FROM editorial.legal_hold_releases AS release
      JOIN ops.legal_hold_placement_receipts_v2 AS placement
        ON placement.legal_hold_id=release.hold_id
      WHERE placement.target_kind IN (
        'CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT'
      )
    ) AND NOT EXISTS(
      SELECT 1 FROM editorial.legal_holds
      WHERE object_type IN (
        'CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT'
      ) AND active
    ),
    'three-privacy-holds-fully-released'
  );
END
$q5_release_and_replay$;

DO $unsupported_targets$
DECLARE
  v_before_plans bigint;
  v_before_holds bigint;
  v_before_anchors bigint;
  v_before_receipts bigint;
  v_before_audit bigint;
  v_before_outbox bigint;
  v_correction_rejected boolean:=false;
  v_audit_rejected boolean:=false;
BEGIN
  SELECT count(*) INTO v_before_plans FROM ops.privacy_correction_plans_v1;
  SELECT count(*) INTO v_before_holds FROM editorial.legal_holds;
  SELECT count(*) INTO v_before_anchors FROM ops.legal_hold_target_anchors;
  SELECT count(*) INTO v_before_receipts
  FROM ops.legal_hold_placement_receipts_v2;
  SELECT count(*) INTO v_before_audit FROM ops.audit_events;
  SELECT count(*) INTO v_before_outbox FROM ops.outbox;
  BEGIN
    PERFORM ops.create_privacy_correction_plan_v1(
      '{}'::jsonb,NULL,NULL,NULL,NULL,NULL
    );
  EXCEPTION WHEN SQLSTATE '0A000' THEN
    v_correction_rejected:=SQLERRM='PRIVACY_CORRECTION_TARGET_UNSUPPORTED';
  END;
  BEGIN
    PERFORM ops.place_legal_hold_v2(
      jsonb_build_object(
        'target',jsonb_build_object(
          'targetKind','AUDIT_SUBJECT_RECORD',
          'targetId','6d400000-0000-4000-8000-000000000099',
          'targetVersion',1,'targetDigest',repeat('a',64)
        )
      ),NULL,NULL,NULL,NULL
    );
  EXCEPTION WHEN SQLSTATE '0A000' THEN
    v_audit_rejected:=SQLERRM='LEGAL_HOLD_TARGET_UNSUPPORTED';
  END;
  PERFORM pg_temp.r6d40_assert(
    v_correction_rejected AND v_audit_rejected
      AND (SELECT count(*) FROM ops.privacy_correction_plans_v1)=v_before_plans
      AND (SELECT count(*) FROM editorial.legal_holds)=v_before_holds
      AND (SELECT count(*) FROM ops.legal_hold_target_anchors)=v_before_anchors
      AND (SELECT count(*) FROM ops.legal_hold_placement_receipts_v2)=
        v_before_receipts
      AND (SELECT count(*) FROM ops.audit_events)=v_before_audit
      AND (SELECT count(*) FROM ops.outbox)=v_before_outbox,
    'q4-q5-unsupported-targets-zero-write'
  );
END
$unsupported_targets$;

-- Coverage can only resolve an exact, nonempty OBJECT_SET whose concrete item
-- rows are fully materialized.  These TEST_ONLY helpers build the same
-- canonical inventory shape as the request owner; every rejected variant is
-- rolled back by its exception block and never becomes fixture authority.
CREATE FUNCTION pg_temp.r6d40_seed_privacy_request(p_label text)
RETURNS uuid
LANGUAGE plpgsql
AS $privacy_request$
DECLARE
  v_privacy_request_id uuid:=pg_temp.r6d40_uuid(
    'privacy-request:'||p_label
  );
  v_create_request_id uuid:=pg_temp.r6d40_uuid(
    'privacy-create-request:'||p_label
  );
  v_at timestamptz:=clock_timestamp();
  v_subject_proof char(64):=pg_temp.r6d40_sha256_text(
    'privacy-subject:'||p_label
  );
  v_scope_digest char(64):=pg_temp.r6d40_sha256_text(
    'privacy-scope:'||p_label
  );
  v_receipt_digest char(64):=pg_temp.r6d40_sha256_text(
    'privacy-receipt:'||p_label
  );
  v_command_digest char(64):=pg_temp.r6d40_sha256_text(
    'privacy-command:'||p_label
  );
  v_audit_id uuid;
  v_outbox_id uuid;
BEGIN
  v_audit_id:=ops.append_audit_event(
    'privacy-request:'||v_privacy_request_id::text,'SERVICE',
    'r6d40-privacy-authority-fixture',NULL,
    'command.createPrivacyRequest','PRIVACY_REQUEST',
    v_privacy_request_id::text,NULL,'SUCCESS',NULL,v_create_request_id,
    jsonb_build_object('testOnly',true,'scopeDigest',btrim(v_scope_digest))
  );
  v_outbox_id:=ops.enqueue_outbox(
    'privacy_request',v_privacy_request_id::text,1,
    'privacy.request_created.v2',jsonb_build_object(
      'retentionRequestId',v_privacy_request_id,'requestType','ACCESS',
      'subjectProofHash',btrim(v_subject_proof),'jurisdiction','KR',
      'scopeDigest',btrim(v_scope_digest),
      'identityState','PENDING_VERIFICATION','identityVerifiedAt',NULL,
      'dueAt',NULL,'receiptDigest',btrim(v_receipt_digest),
      'commandReceiptDigest',btrim(v_command_digest)
    ),v_at
  );
  INSERT INTO ops.privacy_requests_v2(
    id,request_type,state,identity_state,jurisdiction,subject_proof_hash,
    identity_proof_kind,identity_proof_ref_id,
    identity_proof_binding_digest,subject_scope_digest,scope_ciphertext,
    scope_sha256,scope_aad_digest,statement_ciphertext,statement_sha256,
    statement_aad_digest,encryption_key_id,communication_subject_id,
    communication_subject_origin_digest,communication_endpoint_id,
    communication_endpoint_version,communication_endpoint_digest,
    decision_version,create_request_id,create_idempotency_key_sha256,
    create_request_sha256,create_audit_event_id,create_outbox_event_id,
    create_receipt_digest,created_at,updated_at
  ) VALUES(
    v_privacy_request_id,'ACCESS','RECEIVED','PENDING_VERIFICATION','KR',
    v_subject_proof,'RESPONSE_RECEIPT',
    pg_temp.r6d40_uuid('privacy-proof:'||p_label),
    pg_temp.r6d40_sha256_text('privacy-proof-binding:'||p_label),
    pg_temp.r6d40_sha256_text('privacy-subject-scope:'||p_label),
    convert_to('TEST_ONLY scope:'||p_label,'UTF8'),v_scope_digest,
    pg_temp.r6d40_sha256_text('privacy-scope-aad:'||p_label),
    convert_to('TEST_ONLY statement:'||p_label,'UTF8'),
    pg_temp.r6d40_sha256_text('privacy-statement:'||p_label),
    pg_temp.r6d40_sha256_text('privacy-statement-aad:'||p_label),
    'test-envelope-key@v1','6d400000-0000-4000-8000-000000000021',
    repeat('c',64),'6d400000-0000-4000-8000-000000000022',1,
    repeat('0',64),0,v_create_request_id,
    pg_temp.r6d40_sha256_text('privacy-idempotency:'||p_label),
    pg_temp.r6d40_sha256_text('privacy-request-digest:'||p_label),
    v_audit_id,v_outbox_id,v_receipt_digest,v_at,v_at
  );
  RETURN v_privacy_request_id;
END
$privacy_request$;

CREATE FUNCTION pg_temp.r6d40_seed_scope_inventory(
  p_privacy_request_id uuid,
  p_label text,
  p_spec jsonb
) RETURNS uuid
LANGUAGE plpgsql
AS $scope_inventory$
DECLARE
  v_inventory_id uuid:=pg_temp.r6d40_uuid('scope-inventory:'||p_label);
  v_scope_kind text:=p_spec->>'scopeKind';
  v_date_from date:=CASE WHEN p_spec->'dateFrom' IS NULL
    OR p_spec->'dateFrom'='null'::jsonb THEN NULL
    ELSE (p_spec->>'dateFrom')::date END;
  v_date_to date:=CASE WHEN p_spec->'dateTo' IS NULL
    OR p_spec->'dateTo'='null'::jsonb THEN NULL
    ELSE (p_spec->>'dateTo')::date END;
  v_include_derivatives boolean:=COALESCE(
    (p_spec->>'includeDerivatives')::boolean,false
  );
  v_include_backups boolean:=COALESCE(
    (p_spec->>'includeBackups')::boolean,false
  );
  v_item_count integer:=(p_spec->>'objectItemCount')::integer;
  v_object_kind text:=p_spec->>'objectKind';
  v_object_id uuid:=CASE WHEN p_spec->>'objectId' IS NULL THEN NULL
    ELSE (p_spec->>'objectId')::uuid END;
  v_materialize boolean:=COALESCE(
    (p_spec->>'materialize')::boolean,false
  );
  v_refs jsonb:=CASE WHEN v_object_kind IS NULL THEN '[]'::jsonb
    ELSE jsonb_build_array(jsonb_build_object(
      'objectType',v_object_kind,'objectId',v_object_id
    )) END;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_at timestamptz:=clock_timestamp();
  v_payload jsonb;
  v_canonical bytea;
  v_digest char(64);
  v_item_set_digest char(64);
BEGIN
  SELECT request.* INTO STRICT v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=p_privacy_request_id FOR SHARE;
  v_item_set_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_refs),'sha256'
  ),'hex');
  v_payload:=jsonb_build_object(
    'schemaVersion','privacy-request-scope-inventory.v1',
    'scopeInventoryId',v_inventory_id,
    'privacyRequestId',p_privacy_request_id,'scopeKind',v_scope_kind,
    'dateFrom',v_date_from,'dateTo',v_date_to,
    'includeDerivatives',v_include_derivatives,
    'includeBackups',v_include_backups,'objectItemCount',v_item_count,
    'objectItemSetDigest',btrim(v_item_set_digest),
    'scopeDigest',btrim(v_request.scope_sha256),
    'subjectScopeDigest',btrim(v_request.subject_scope_digest),
    'createdAt',v_at
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_digest:=encode(extensions.digest(v_canonical,'sha256'),'hex');
  INSERT INTO ops.privacy_request_scope_inventories_v1(
    scope_inventory_id,privacy_request_id,scope_kind,date_from,date_to,
    include_derivatives,include_backups,object_item_count,
    object_item_set_digest,scope_digest,subject_scope_digest,
    receipt_payload,receipt_canonical,receipt_digest,created_at
  ) VALUES(
    v_inventory_id,p_privacy_request_id,v_scope_kind,v_date_from,v_date_to,
    v_include_derivatives,v_include_backups,v_item_count,v_item_set_digest,
    v_request.scope_sha256,v_request.subject_scope_digest,
    v_payload,v_canonical,v_digest,v_at
  );
  IF v_materialize THEN
    INSERT INTO ops.privacy_request_scope_inventory_items_v1(
      scope_inventory_id,item_ordinal,privacy_request_id,object_kind,
      object_id,item_digest,created_at
    ) VALUES(
      v_inventory_id,1,p_privacy_request_id,v_object_kind,v_object_id,
      encode(extensions.digest(ops.canonical_jsonb_v1(v_refs->0),'sha256'),
        'hex'),v_at
    );
  END IF;
  RETURN v_inventory_id;
END
$scope_inventory$;

DO $privacy_hold_inventory_coverage$
DECLARE
  v_request_id uuid:=pg_temp.r6d40_seed_privacy_request('coverage');
  v_active_request_id uuid:=pg_temp.r6d40_seed_privacy_request(
    'coverage-active'
  );
  v_result jsonb;
  v_active_result jsonb;
  v_authority jsonb;
  v_target jsonb;
  v_placement jsonb;
  v_missing boolean:=false;
  v_all_zero boolean:=false;
  v_date_zero boolean:=false;
  v_count_mismatch boolean:=false;
  v_derivatives boolean:=false;
  v_backups boolean:=false;
  v_audit boolean:=false;
BEGIN
  BEGIN
    PERFORM ops.r6d_privacy_request_legal_hold_coverage_v1(
      v_request_id,clock_timestamp()
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_missing:=SQLERRM=
      'r6d_privacy_hold_inventory_missing_or_ambiguous';
  END;
  BEGIN
    PERFORM pg_temp.r6d40_seed_scope_inventory(
      v_request_id,'all-zero',jsonb_build_object(
        'scopeKind','ALL_VERIFIED_SUBJECT_DATA','dateFrom',NULL,
        'dateTo',NULL,'includeDerivatives',false,'includeBackups',false,
        'objectItemCount',0,'materialize',false
      )
    );
    PERFORM ops.r6d_privacy_request_legal_hold_coverage_v1(
      v_request_id,clock_timestamp()
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_all_zero=SQLERRM=
      'r6d_privacy_hold_inventory_unmaterialized_or_inconsistent';
  END;
  BEGIN
    PERFORM pg_temp.r6d40_seed_scope_inventory(
      v_request_id,'date-zero',jsonb_build_object(
        'scopeKind','DATE_RANGE','dateFrom','2000-01-01',
        'dateTo','2000-01-31','includeDerivatives',false,
        'includeBackups',false,'objectItemCount',0,'materialize',false
      )
    );
    PERFORM ops.r6d_privacy_request_legal_hold_coverage_v1(
      v_request_id,clock_timestamp()
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_date_zero=SQLERRM=
      'r6d_privacy_hold_inventory_unmaterialized_or_inconsistent';
  END;
  BEGIN
    PERFORM pg_temp.r6d40_seed_scope_inventory(
      v_request_id,'count-mismatch',jsonb_build_object(
        'scopeKind','OBJECT_SET','dateFrom',NULL,'dateTo',NULL,
        'includeDerivatives',false,'includeBackups',false,
        'objectItemCount',1,'objectKind','EVIDENCE',
        'objectId','6d400000-0000-4000-8000-000000000023',
        'materialize',false
      )
    );
    PERFORM ops.r6d_privacy_request_legal_hold_coverage_v1(
      v_request_id,clock_timestamp()
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_count_mismatch=SQLERRM=
      'r6d_privacy_hold_inventory_unmaterialized_or_inconsistent';
  END;
  BEGIN
    PERFORM pg_temp.r6d40_seed_scope_inventory(
      v_request_id,'derivatives',jsonb_build_object(
        'scopeKind','OBJECT_SET','dateFrom',NULL,'dateTo',NULL,
        'includeDerivatives',true,'includeBackups',false,
        'objectItemCount',1,'objectKind','EVIDENCE',
        'objectId','6d400000-0000-4000-8000-000000000023',
        'materialize',true
      )
    );
    PERFORM ops.r6d_privacy_request_legal_hold_coverage_v1(
      v_request_id,clock_timestamp()
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_derivatives=SQLERRM=
      'r6d_privacy_hold_inventory_unmaterialized_or_inconsistent';
  END;
  BEGIN
    PERFORM pg_temp.r6d40_seed_scope_inventory(
      v_request_id,'backups',jsonb_build_object(
        'scopeKind','OBJECT_SET','dateFrom',NULL,'dateTo',NULL,
        'includeDerivatives',false,'includeBackups',true,
        'objectItemCount',1,'objectKind','EVIDENCE',
        'objectId','6d400000-0000-4000-8000-000000000023',
        'materialize',true
      )
    );
    PERFORM ops.r6d_privacy_request_legal_hold_coverage_v1(
      v_request_id,clock_timestamp()
    );
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_backups=SQLERRM=
      'r6d_privacy_hold_inventory_unmaterialized_or_inconsistent';
  END;
  BEGIN
    PERFORM pg_temp.r6d40_seed_scope_inventory(
      v_request_id,'audit',jsonb_build_object(
        'scopeKind','OBJECT_SET','dateFrom',NULL,'dateTo',NULL,
        'includeDerivatives',false,'includeBackups',false,
        'objectItemCount',1,'objectKind','AUDIT_SUBJECT_RECORD',
        'objectId','6d400000-0000-4000-8000-000000000099',
        'materialize',true
      )
    );
    PERFORM ops.r6d_privacy_request_legal_hold_coverage_v1(
      v_request_id,clock_timestamp()
    );
  EXCEPTION WHEN SQLSTATE '0A000' THEN
    v_audit=SQLERRM='LEGAL_HOLD_TARGET_UNSUPPORTED';
  END;
  PERFORM pg_temp.r6d40_seed_scope_inventory(
    v_request_id,'supported',jsonb_build_object(
      'scopeKind','OBJECT_SET','dateFrom',NULL,'dateTo',NULL,
      'includeDerivatives',false,'includeBackups',false,
      'objectItemCount',1,'objectKind','EVIDENCE',
      'objectId','6d400000-0000-4000-8000-000000000023',
      'materialize',true
    )
  );
  v_result:=ops.r6d_privacy_request_legal_hold_coverage_v1(
    v_request_id,clock_timestamp()
  );
  PERFORM pg_temp.r6d40_seed_scope_inventory(
    v_active_request_id,'supported-active',jsonb_build_object(
      'scopeKind','OBJECT_SET','dateFrom',NULL,'dateTo',NULL,
      'includeDerivatives',false,'includeBackups',false,
      'objectItemCount',1,'objectKind','EVIDENCE',
      'objectId','6d400000-0000-4000-8000-000000000024',
      'materialize',true
    )
  );
  v_target:=jsonb_build_object(
    'targetKind','EVIDENCE',
    'targetId','6d400000-0000-4000-8000-000000000024',
    'targetVersion',1,'targetDigest',repeat('9',64),
    'evidenceId','6d400000-0000-4000-8000-000000000024'
  );
  v_authority:=pg_temp.r6d40_seed_hold_authority(
    v_target,'privacy-coverage-active'
  );
  v_placement:=ops.place_legal_hold_v2(
    (v_authority->'payload')||jsonb_build_object(
      'affectedIds',jsonb_build_array(
        '6d400000-0000-4000-8000-000000000024'::uuid,
        v_active_request_id
      )
    ),'6d400000-0000-4000-8000-000000000010',
    (v_authority->>'requestId')::uuid,
    (v_authority->>'idempotencyKey')::char(64),
    (v_authority->>'requestDigest')::char(64)
  );
  v_active_result:=ops.r6d_privacy_request_legal_hold_coverage_v1(
    v_active_request_id,clock_timestamp()
  );
  PERFORM pg_temp.r6d40_assert(
    v_missing AND v_all_zero AND v_date_zero AND v_count_mismatch
      AND v_derivatives AND v_backups AND v_audit
      AND COALESCE((v_result->>'active')::boolean,true)=false
      AND (v_result->>'activeCellCount')::integer=0
      AND ops.r6d_lower_sha256(v_result->>'coverageDigest')
      AND COALESCE((v_placement->>'replayed')::boolean,true)=false
      AND COALESCE((v_active_result->>'active')::boolean,false)
      AND (v_active_result->>'activeCellCount')::integer=1
      AND ops.r6d_lower_sha256(v_active_result->>'coverageDigest'),
    'privacy-hold-exact-materialized-object-set-only'
  );
END
$privacy_hold_inventory_coverage$;

-- The Q5 dispatcher must preserve, not bypass, the 0039 entity advisory fence.
DO $entity_fence_definition$
DECLARE
  v_dispatch text:=lower(regexp_replace(pg_get_functiondef(
    'ops.place_legal_hold_v2(jsonb,uuid,uuid,character,character)'::regprocedure
  ),'[[:space:]]+',' ','g'));
  v_prior text:=lower(regexp_replace(pg_get_functiondef(
    'ops.place_legal_hold_v2_pre_r6d_q5_privacy_kinds(jsonb,uuid,uuid,character,character)'::regprocedure
  ),'[[:space:]]+',' ','g'));
BEGIN
  PERFORM pg_temp.r6d40_assert(
    position('place_legal_hold_v2_pre_r6d_q5_privacy_kinds' IN v_dispatch)>0
      AND position('place_legal_hold_v2_pre_r6d_entity_fence' IN v_prior)>0
      AND position('pg_advisory_xact_lock' IN v_prior)>0,
    'entity-advisory-fence-preserved-through-q5-dispatcher'
  );
END
$entity_fence_definition$;

SELECT 'R6D40_PRIVACY_AUTHORITY_RUNTIME' AS gate,
  (SELECT count(*) FROM ops.privacy_correction_snapshots_v1) AS correction_snapshots,
  (SELECT count(*) FROM ops.privacy_subscription_snapshots_v1) AS subscription_snapshots,
  (SELECT count(*) FROM ops.legal_hold_placement_receipts_v2
    WHERE target_kind IN (
      'CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT'
    )) AS privacy_hold_receipts,
  'PASS' AS result;

ROLLBACK;
