-- TEST_FIXTURE_ONLY: R6d supervisor-authorized authority-closure proof.
--
-- This file is executed only after migrations 0001..0039 and the repository's
-- TEST_ONLY retention/calendar authority have been installed in a disposable
-- PostgreSQL 18.4 database.  It performs no external I/O, creates no operating
-- policy, and rolls every domain row back.

\set ON_ERROR_STOP on

BEGIN ISOLATION LEVEL SERIALIZABLE;
SET CONSTRAINTS ALL DEFERRED;
SET LOCAL TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.r6d39_assert(
  p_condition boolean,
  p_message text
) RETURNS void
LANGUAGE plpgsql
AS $assert$
BEGIN
  IF p_condition IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'r6d39_runtime_assertion_failed:%',p_message
      USING ERRCODE='55000';
  END IF;
END
$assert$;

CREATE FUNCTION pg_temp.r6d39_function_definition(p_signature text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $definition$
DECLARE
  v_function regprocedure:=to_regprocedure(p_signature);
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'r6d39_owner_function_missing:%',p_signature
      USING ERRCODE='55000';
  END IF;
  RETURN lower(regexp_replace(
    pg_get_functiondef(v_function),'[[:space:]]+',' ','g'
  ));
END
$definition$;

CREATE FUNCTION pg_temp.r6d39_sha256_text(p_value text)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,extensions,pg_temp
AS $digest$
  SELECT encode(
    extensions.digest(convert_to(p_value,'UTF8'),'sha256'),'hex'
  )::char(64)
$digest$;

CREATE FUNCTION pg_temp.r6d39_sha256_json(p_value jsonb)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $digest$
  SELECT encode(
    extensions.digest(ops.canonical_jsonb_v1(p_value),'sha256'),'hex'
  )::char(64)
$digest$;

CREATE FUNCTION pg_temp.r6d39_insert_procurement_revision(
  p_label text,
  p_root_id uuid,
  p_revision_id uuid,
  p_revision bigint,
  p_agency_id uuid,
  p_supplier_id uuid,
  p_ends_at date
) RETURNS void
LANGUAGE plpgsql
AS $procurement$
DECLARE
  v_payload jsonb:=jsonb_build_object(
    'schemaVersion','TEST_ONLY-r6d-procurement-contract.v1',
    'fixtureLabel',p_label,'revision',p_revision
  );
  v_payload_canonical bytea:=ops.canonical_jsonb_v1(v_payload);
  v_digest_preimage bytea:=ops.canonical_jsonb_v1(jsonb_build_object(
    'fixtureLabel',p_label,'revision',p_revision,'rootId',p_root_id
  ));
  v_record_digest char(64):=encode(
    extensions.digest(v_digest_preimage,'sha256'),'hex'
  );
  v_member jsonb:=jsonb_build_object(
    'schemaVersion','TEST_ONLY-r6d-supplier-party-ref.v1',
    'fixtureLabel',p_label,'supplierId',p_supplier_id
  );
  v_member_canonical bytea:=ops.canonical_jsonb_v1(v_member);
  v_member_preimage bytea:=ops.canonical_jsonb_v1(jsonb_build_object(
    'fixtureLabel',p_label,'supplierId',p_supplier_id,
    'revisionId',p_revision_id
  ));
  v_member_digest char(64):=encode(
    extensions.digest(v_member_preimage,'sha256'),'hex'
  );
BEGIN
  PERFORM set_config('session_replication_role','replica',true);
  INSERT INTO core.procurement_contract_revisions(
    revision_id,root_id,revision,record_digest,revision_state,source_id,
    connector_id,operation_id,source_document_id,source_asset_id,
    source_asset_revision,source_content_sha256,source_external_id,
    source_external_revision,parsed_record_id,record_index,
    source_record_digest,retrieved_at,mapping_version,
    mapping_effective_from,normalization_run_id,effective_time_status,
    payload_canonical,digest_preimage_canonical,
    field_provenance_set_digest,coverage_status,limitation_set_digest,
    typed_payload,external_contract_id,title,business_type,agency_id,
    agency_revision,agency_identity_digest,agency_snapshot_canonical,
    supplier_count,supplier_set_digest,contract_status,ends_at,currency
  ) VALUES(
    p_revision_id,p_root_id,p_revision,v_record_digest,'CURRENT',
    'r6d39-procurement-source','r6d39-procurement-connector',
    'TEST_ONLY_NORMALIZE',pg_temp.r6d39_uuid(p_label||':document'),
    pg_temp.r6d39_uuid(p_label||':asset'),1,
    pg_temp.r6d39_sha256_text(p_label||':content'),p_label,
    p_revision::text,pg_temp.r6d39_uuid(p_label||':parsed'),0,
    pg_temp.r6d39_sha256_text(p_label||':source-record'),
    '2000-01-01 00:00:00+00','TEST_ONLY_MAPPING_V1',
    '2000-01-01 00:00:00+00',pg_temp.r6d39_uuid(p_label||':run'),
    'EXACT',v_payload_canonical,v_digest_preimage,
    pg_temp.r6d39_sha256_text(p_label||':provenance'),'COMPLETE',
    pg_temp.r6d39_sha256_text(p_label||':limitations'),v_payload,
    p_root_id::text,'TEST_ONLY normalized procurement contract','CONTRACT',
    p_agency_id,1,pg_temp.r6d39_sha256_text(p_label||':agency'),
    ops.canonical_jsonb_v1(jsonb_build_object('agencyId',p_agency_id)),
    CASE WHEN p_supplier_id IS NULL THEN 0 ELSE 1 END,
    pg_temp.r6d39_sha256_text(COALESCE(p_supplier_id::text,'none')),
    'COMPLETED',p_ends_at,'KRW'
  );
  IF p_supplier_id IS NOT NULL THEN
    INSERT INTO core.procurement_contract_supplier_revisions(
      contract_revision_id,contract_root_id,contract_revision,
      contract_record_digest,supplier_ordinal,candidate_id,
      candidate_revision,candidate_digest,canonical_supplier_id,
      identity_status,member_payload,member_canonical,
      member_digest_preimage_canonical,member_digest
    ) VALUES(
      p_revision_id,p_root_id,p_revision,v_record_digest,0,
      pg_temp.r6d39_uuid(p_label||':candidate'),1,
      pg_temp.r6d39_sha256_text(p_label||':candidate'),p_supplier_id,
      'VERIFIED',v_member,v_member_canonical,v_member_preimage,v_member_digest
    );
  END IF;
  PERFORM set_config('session_replication_role','origin',true);
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('session_replication_role','origin',true);
  RAISE;
END
$procurement$;

CREATE FUNCTION pg_temp.r6d39_insert_publication_revision(
  p_label text,
  p_case_id uuid,
  p_revision_id uuid,
  p_revision integer,
  p_state editorial.publication_state,
  p_agency_ids jsonb,
  p_supplier_ids jsonb,
  p_supersedes_revision integer DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
AS $publication$
DECLARE
  v_payload jsonb:=jsonb_build_object(
    'schemaVersion','TEST_ONLY-r6d-publication-membership.v1',
    'fixtureSource',p_label,'agencyIds',p_agency_ids,
    'supplierIds',p_supplier_ids
  );
BEGIN
  PERFORM set_config('session_replication_role','replica',true);
  INSERT INTO editorial.publication_revisions(
    id,case_id,revision,state,review_snapshot_id,public_payload,
    public_payload_sha256,preview_sha256,published_by,published_at,
    supersedes_revision,reason
  ) VALUES(
    p_revision_id,p_case_id,p_revision,p_state,
    pg_temp.r6d39_uuid(p_label||':review'),v_payload,
    pg_temp.r6d39_sha256_json(v_payload),
    pg_temp.r6d39_sha256_text(p_label||':preview'),
    pg_temp.r6d39_uuid(p_label||':publisher'),
    '2000-01-01 00:00:00+00',p_supersedes_revision,
    'TEST_ONLY immutable membership fixture'
  );
  PERFORM set_config('session_replication_role','origin',true);
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('session_replication_role','origin',true);
  RAISE;
END
$publication$;

CREATE FUNCTION pg_temp.r6d39_expect_invalid_publication_membership(
  p_label text,
  p_entity_id uuid,
  p_payload jsonb,
  p_payload_digest char(64)
) RETURNS void
LANGUAGE plpgsql
AS $invalid_publication$
DECLARE
  v_case_id uuid:=pg_temp.r6d39_uuid(p_label||':case');
  v_rejected boolean:=false;
  v_error_state text;
  v_error_message text;
BEGIN
  BEGIN
    PERFORM set_config('session_replication_role','replica',true);
    INSERT INTO editorial.publication_revisions(
      id,case_id,revision,state,review_snapshot_id,public_payload,
      public_payload_sha256,preview_sha256,published_by,published_at,reason
    ) VALUES(
      pg_temp.r6d39_uuid(p_label||':revision'),v_case_id,1,
      'PUBLISHED_ANOMALY',pg_temp.r6d39_uuid(p_label||':review'),p_payload,
      p_payload_digest,pg_temp.r6d39_sha256_text(p_label||':preview'),
      pg_temp.r6d39_uuid(p_label||':publisher'),
      '2000-01-01 00:00:00+00','TEST_ONLY malformed membership fixture'
    );
    PERFORM set_config('session_replication_role','origin',true);
    PERFORM ops.r6d_entity_material_use_state_v1(
      'AGENCY',p_entity_id,clock_timestamp()
    );
  EXCEPTION WHEN OTHERS THEN
    v_rejected:=true;
    v_error_state:=SQLSTATE;
    v_error_message:=SQLERRM;
    PERFORM set_config('session_replication_role','origin',true);
  END;
  PERFORM pg_temp.r6d39_assert(
    v_rejected AND v_error_state='55000'
    AND v_error_message='r6d_entity_publication_membership_invalid'
    AND NOT EXISTS(
      SELECT 1 FROM editorial.publication_revisions
      WHERE case_id=v_case_id
    ),
    'invalid-publication-membership-zero-write:'||p_label
  );
END
$invalid_publication$;

CREATE FUNCTION pg_temp.r6d39_uuid(p_label text)
RETURNS uuid
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,extensions,pg_temp
AS $uuid$
  WITH hashed(value) AS (
    SELECT encode(extensions.digest(convert_to(
      'r6d-authority-closure-runtime:'||p_label,'UTF8'
    ),'sha256'),'hex')
  )
  SELECT (
    substr(value,1,8)||'-'||substr(value,9,4)||'-4'||substr(value,14,3)
    ||'-a'||substr(value,18,3)||'-'||substr(value,21,12)
  )::uuid
  FROM hashed
$uuid$;

CREATE FUNCTION pg_temp.r6d39_envelope(p_label text)
RETURNS bytea
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,pg_temp
AS $envelope$
  SELECT convert_to(
    'gurine-fe-v1.key-v1.'||p_label||'.cipher','UTF8'
  )
$envelope$;

CREATE FUNCTION pg_temp.r6d39_base64(p_value bytea)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path=pg_catalog,pg_temp
AS $base64$
  SELECT replace(encode(p_value,'base64'),E'\n','')
$base64$;

GRANT EXECUTE ON FUNCTION
  pg_temp.r6d39_sha256_text(text),
  pg_temp.r6d39_sha256_json(jsonb),
  pg_temp.r6d39_insert_procurement_revision(
    text,uuid,uuid,bigint,uuid,uuid,date
  ),
  pg_temp.r6d39_insert_publication_revision(
    text,uuid,uuid,integer,editorial.publication_state,jsonb,jsonb,integer
  ),
  pg_temp.r6d39_expect_invalid_publication_membership(
    text,uuid,jsonb,character
  ),
  pg_temp.r6d39_uuid(text),
  pg_temp.r6d39_envelope(text),
  pg_temp.r6d39_base64(bytea)
TO gurine_submission_api,gurine_control_api;
GRANT EXECUTE ON FUNCTION ops.r6d_nul5_sha256_v1(
  text,text,text,text,text
) TO gurine_submission_api,gurine_control_api;

CREATE FUNCTION pg_temp.r6d39_assert_owner_function(
  p_signature text,
  p_runtime_role text
) RETURNS void
LANGUAGE plpgsql
AS $owner$
DECLARE
  v_function regprocedure:=to_regprocedure(p_signature);
  v_owner name;
  v_security_definer boolean;
  v_public_execute boolean;
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'r6d39_owner_function_missing:%',p_signature
      USING ERRCODE='55000';
  END IF;
  SELECT owner_role.rolname,proc.prosecdef,
    EXISTS(
      SELECT 1
      FROM aclexplode(COALESCE(
        proc.proacl,acldefault('f',proc.proowner)
      )) AS privilege
      WHERE privilege.grantee=0 AND privilege.privilege_type='EXECUTE'
    )
  INTO STRICT v_owner,v_security_definer,v_public_execute
  FROM pg_proc AS proc
  JOIN pg_roles AS owner_role ON owner_role.oid=proc.proowner
  WHERE proc.oid=v_function;

  PERFORM pg_temp.r6d39_assert(
    v_owner='gurine_migrator','owner:'||p_signature
  );
  PERFORM pg_temp.r6d39_assert(
    v_security_definer,'security-definer:'||p_signature
  );
  PERFORM pg_temp.r6d39_assert(
    NOT v_public_execute,'public-execute:'||p_signature
  );
  PERFORM pg_temp.r6d39_assert(
    has_function_privilege(p_runtime_role,p_signature,'EXECUTE'),
    'runtime-execute:'||p_signature||':'||p_runtime_role
  );
END
$owner$;

CREATE FUNCTION pg_temp.r6d39_direct_dml_denied(p_relation regclass)
RETURNS boolean
LANGUAGE plpgsql
AS $dml$
DECLARE
  v_insert_denied boolean:=false;
  v_delete_denied boolean:=false;
BEGIN
  BEGIN
    EXECUTE format('INSERT INTO %s DEFAULT VALUES',p_relation);
  EXCEPTION WHEN insufficient_privilege THEN
    v_insert_denied:=true;
  END;
  BEGIN
    EXECUTE format('DELETE FROM %s WHERE false',p_relation);
  EXCEPTION WHEN insufficient_privilege THEN
    v_delete_denied:=true;
  END;
  RETURN v_insert_denied AND v_delete_denied;
END
$dml$;
GRANT EXECUTE ON FUNCTION pg_temp.r6d39_direct_dml_denied(regclass)
  TO gurine_control_api;

CREATE FUNCTION pg_temp.r6d39_assert_exact_owner_function(
  p_signature text,
  p_runtime_role text
) RETURNS void
LANGUAGE plpgsql
AS $owner$
DECLARE
  v_role name;
BEGIN
  PERFORM pg_temp.r6d39_assert_owner_function(
    p_signature,p_runtime_role
  );
  FOR v_role IN
    SELECT role.rolname
    FROM pg_roles AS role
    WHERE role.rolname LIKE 'gurine\_%' ESCAPE '\'
      AND role.rolname NOT IN ('gurine_migrator',p_runtime_role)
    ORDER BY role.rolname
  LOOP
    PERFORM pg_temp.r6d39_assert(
      NOT has_function_privilege(v_role,p_signature,'EXECUTE'),
      'unexpected-runtime-execute:'||p_signature||':'||v_role
    );
  END LOOP;
END
$owner$;

DO $schema_acl$
DECLARE
  v_relation text;
  v_role text;
BEGIN
  FOREACH v_relation IN ARRAY ARRAY[
    'ops.r6d_entity_personhood_classification_receipts_v1',
    'ops.r6d_entity_material_use_closure_receipts_v1',
    'ops.r6d_entity_retention_execution_receipts_v1',
    'editorial.organization_official_channel_authority_receipts_v1',
    'editorial.organization_official_channel_assertions_v1',
    'editorial.organization_official_channel_revocation_receipts_v1',
    'ops.privacy_identity_proof_authority_receipts_v1',
    'ops.privacy_request_scope_inventories_v1',
    'ops.privacy_request_scope_inventory_items_v1',
    'ops.privacy_identity_proof_consumption_receipts_v1',
    'ops.privacy_correction_plans_v1',
    'ops.privacy_response_party_name_correction_plan_bindings_v1',
    'ops.privacy_response_party_name_correction_approval_bindings_v1',
    'ops.privacy_response_party_name_correction_completion_receipts_v1'
  ] LOOP
    PERFORM pg_temp.r6d39_assert(
      to_regclass(v_relation) IS NOT NULL,'relation-missing:'||v_relation
    );
    FOREACH v_role IN ARRAY ARRAY[
      'gurine_control_api','gurine_submission_api','gurine_identity_api',
      'gurine_analysis_worker','gurine_workflow_worker','gurine_scheduler',
      'gurine_notification_worker','gurine_public_projector','gurine_auditor'
    ] LOOP
      PERFORM pg_temp.r6d39_assert(
        NOT has_table_privilege(v_role,v_relation,'INSERT')
        AND NOT has_table_privilege(v_role,v_relation,'UPDATE')
        AND NOT has_table_privilege(v_role,v_relation,'DELETE'),
        'runtime-dml-leak:'||v_relation||':'||v_role
      );
    END LOOP;
  END LOOP;

  PERFORM pg_temp.r6d39_assert_owner_function(
    'ops.classify_r6d_entity_personhood_v1(jsonb,uuid,uuid,uuid,character,character)',
    'gurine_control_api'
  );
  PERFORM pg_temp.r6d39_assert_owner_function(
    'ops.attest_r6d_entity_material_use_closure_v1(jsonb,uuid,uuid,uuid,character,character)',
    'gurine_control_api'
  );
  PERFORM pg_temp.r6d39_assert_owner_function(
    'ops.enqueue_due_r6d_entity_retention_jobs_v1(integer)',
    'gurine_scheduler'
  );
  PERFORM pg_temp.r6d39_assert_owner_function(
    'ops.execute_due_r6d_entity_retention_job_v1(uuid,uuid,bigint)',
    'gurine_workflow_worker'
  );
  PERFORM pg_temp.r6d39_assert_owner_function(
    'editorial.attest_organization_official_channel_v1(jsonb,uuid,uuid,uuid,character,character)',
    'gurine_control_api'
  );
  PERFORM pg_temp.r6d39_assert_owner_function(
    'editorial.revoke_organization_official_channel_v1(jsonb,uuid,uuid,uuid,character,character)',
    'gurine_control_api'
  );
  PERFORM pg_temp.r6d39_assert_owner_function(
    'ops.create_privacy_request_v2(jsonb,uuid,character,character)',
    'gurine_submission_api'
  );
  PERFORM pg_temp.r6d39_assert_exact_owner_function(
    'ops.create_privacy_correction_plan_v1(jsonb,uuid,uuid,uuid,character,character)',
    'gurine_control_api'
  );
  PERFORM pg_temp.r6d39_assert_exact_owner_function(
    'ops.load_privacy_response_party_name_correction_job_v1(uuid,uuid,bigint)',
    'gurine_workflow_worker'
  );
  PERFORM pg_temp.r6d39_assert_exact_owner_function(
    'ops.execute_privacy_response_party_name_correction_job_v1(uuid,uuid,bigint,text,character)',
    'gurine_workflow_worker'
  );
  PERFORM pg_temp.r6d39_assert_exact_owner_function(
    'ops.ack_privacy_response_party_name_correction_delegation_v1(uuid,uuid,bigint,character,uuid,uuid,bigint)',
    'gurine_workflow_worker'
  );
  PERFORM pg_temp.r6d39_assert_owner_function(
    'ops.apply_control_addendum_command(text,jsonb,uuid,uuid,uuid,character,character)',
    'gurine_control_api'
  );
END
$schema_acl$;

DO $immutable_relations$
DECLARE
  v_relation regclass;
BEGIN
  FOREACH v_relation IN ARRAY ARRAY[
    'ops.r6d_entity_personhood_classification_receipts_v1'::regclass,
    'ops.r6d_entity_material_use_closure_receipts_v1'::regclass,
    'ops.r6d_entity_retention_execution_receipts_v1'::regclass,
    'editorial.organization_official_channel_authority_receipts_v1'::regclass,
    'editorial.organization_official_channel_assertions_v1'::regclass,
    'editorial.organization_official_channel_revocation_receipts_v1'::regclass,
    'ops.privacy_identity_proof_authority_receipts_v1'::regclass,
    'ops.privacy_request_scope_inventories_v1'::regclass,
    'ops.privacy_request_scope_inventory_items_v1'::regclass,
    'ops.privacy_identity_proof_consumption_receipts_v1'::regclass,
    'ops.privacy_correction_plans_v1'::regclass
  ] LOOP
    PERFORM pg_temp.r6d39_assert(
      EXISTS(
        SELECT 1 FROM pg_trigger AS trg
        WHERE trg.tgrelid=v_relation AND NOT trg.tgisinternal
          AND (trg.tgtype & 1)=1 AND (trg.tgtype & 2)=2
          AND (trg.tgtype & 8)=8
      )
      AND EXISTS(
        SELECT 1 FROM pg_trigger AS trg
        WHERE trg.tgrelid=v_relation AND NOT trg.tgisinternal
          AND (trg.tgtype & 1)=1 AND (trg.tgtype & 2)=2
          AND (trg.tgtype & 16)=16
      ),
      'immutable-trigger:'||v_relation::text
    );
  END LOOP;
END
$immutable_relations$;

CREATE TEMP TABLE r6d39_d2_direct_dml_boundary(
  relation_name text PRIMARY KEY,
  denied boolean NOT NULL
) ON COMMIT DROP;
GRANT INSERT,SELECT ON r6d39_d2_direct_dml_boundary TO gurine_control_api;
SET LOCAL ROLE gurine_control_api;
INSERT INTO r6d39_d2_direct_dml_boundary(relation_name,denied)
SELECT relation_name,pg_temp.r6d39_direct_dml_denied(relation_name::regclass)
FROM unnest(ARRAY[
  'editorial.organization_official_channel_authority_receipts_v1',
  'editorial.organization_official_channel_assertions_v1',
  'editorial.organization_official_channel_revocation_receipts_v1'
]) AS relation(relation_name);
RESET ROLE;
SELECT pg_temp.r6d39_assert(
  (SELECT bool_and(denied) FROM r6d39_d2_direct_dml_boundary),
  'official-channel-control-api-direct-dml'
);

DO $d1_definition_closure$
DECLARE
  v_classify text:=pg_temp.r6d39_function_definition(
    'ops.classify_r6d_entity_personhood_v1(jsonb,uuid,uuid,uuid,character,character)'
  );
  v_close text:=pg_temp.r6d39_function_definition(
    'ops.attest_r6d_entity_material_use_closure_v1(jsonb,uuid,uuid,uuid,character,character)'
  );
  v_material text:=pg_temp.r6d39_function_definition(
    'ops.r6d_entity_material_use_state_v1(text,uuid,timestamp with time zone)'
  );
  v_enqueue text:=pg_temp.r6d39_function_definition(
    'ops.enqueue_due_r6d_entity_retention_jobs_v1(integer)'
  );
  v_execute text:=pg_temp.r6d39_function_definition(
    'ops.execute_due_r6d_entity_retention_job_v1(uuid,uuid,bigint)'
  );
BEGIN
  PERFORM pg_temp.r6d39_assert(
    position('users.manage' IN v_classify)>0
    AND position('step_up' IN v_classify)>0
    AND position('evidence' IN v_classify)>0
    AND position('source' IN v_classify)>0
    AND position('locator' IN v_classify)>0,
    'personhood-human-source-authority'
  );
  PERFORM pg_temp.r6d39_assert(
    position('r6d_entity_personhood_classification_receipts_v1' IN v_close)>0
    AND position('natural_person' IN v_close)>0
    AND position('v_personhood.actor_id=p_actor_id' IN v_close)>0
    AND position('r6d_entity_closure_actor_not_independent' IN v_close)>0
    AND position('r6d_entity_material_use_state_v1' IN v_close)>0
    AND position('contract_still_material' IN v_close)>0
    AND position('publication_still_material' IN v_close)>0
    AND position('legal_hold_active' IN v_close)>0
    AND position('core.contracts' IN v_material)>0
    AND position('asia/seoul' IN v_material)>0
    AND position('publication' IN v_material)>0
    AND position('supersed' IN v_material)>0
    AND position('retract' IN v_material)>0
    AND position('legal_hold' IN v_material)>0,
    'material-use-closure-predicates'
  );
  PERFORM pg_temp.r6d39_assert(
    position('r6d_entity_personhood_classification_receipts_v1' IN v_enqueue)>0
    AND position('r6d_entity_material_use_closure_receipts_v1' IN v_enqueue)>0
    AND position('natural_person' IN v_enqueue)>0
    AND position('due_at' IN v_enqueue)>0,
    'entity-enqueue-receipt-and-due-binding'
  );
  PERFORM pg_temp.r6d39_assert(
    position('r6d_entity_personhood_classification_receipts_v1' IN v_execute)>0
    AND position('r6d_entity_material_use_closure_receipts_v1' IN v_execute)>0
    AND position('r6d_entity_retention_execution_receipts_v1' IN v_execute)>0
    AND position('delete from core.' IN v_execute)=0,
    'entity-executor-authority-and-no-row-delete'
  );
END
$d1_definition_closure$;

-- A current PII-bearing entity without either immutable D1 receipt must never
-- be selected even when its created-at timestamp is old enough for any sane
-- test schedule.  This row is test-only and is rolled back below.
INSERT INTO core.agencies(
  id,canonical_name,agency_type,jurisdiction,active,identity_status,
  created_at,updated_at
) VALUES(
  '6d390000-0000-4000-8000-000000000001',
  'TEST_ONLY 영수증 없는 자연인 후보','OTHER','KR',true,'VERIFIED',
  '2000-01-01 00:00:00+00','2000-01-01 00:00:00+00'
),(
  '6d390000-0000-4000-8000-000000000002',
  'TEST_ONLY 역사 자연인 성명','OTHER','KR-11 TEST_ONLY 주소',true,'VERIFIED',
  '2010-01-01 00:00:00+00','2010-01-01 00:00:00+00'
);

INSERT INTO core.agency_identifiers(id,agency_id,scheme,value,created_at) VALUES
  (
    '6d390000-0000-4000-8000-000000000010',
    '6d390000-0000-4000-8000-000000000001','TEST_ONLY_REGISTRATION',
    'TEST-CLASSIFY-0001','2000-01-01 00:00:00+00'
  ),
  (
    '6d390000-0000-4000-8000-000000000011',
    '6d390000-0000-4000-8000-000000000002','TEST_ONLY_REGISTRATION',
    'TEST-ANONYMIZE-0002','2010-01-01 00:00:00+00'
  );

INSERT INTO core.entity_aliases(
  id,entity_type,entity_id,alias,normalized_alias,created_at
) VALUES
  (
    '6d390000-0000-4000-8000-000000000012','AGENCY',
    '6d390000-0000-4000-8000-000000000001',
    'TEST_ONLY 분류 별칭','test only 분류 별칭','2000-01-01 00:00:00+00'
  ),
  (
    '6d390000-0000-4000-8000-000000000013','AGENCY',
    '6d390000-0000-4000-8000-000000000002',
    'TEST_ONLY 삭제 대상 별칭','test only 삭제 대상 별칭',
    '2010-01-01 00:00:00+00'
  );

INSERT INTO core.suppliers(
  id,canonical_name,business_status,identity_status,created_at,updated_at
) VALUES(
  '6d390000-0000-4000-8000-000000000300',
  'TEST_ONLY 역사 자연인 공급자 성명','ACTIVE','VERIFIED',
  '2010-01-01 00:00:00+00','2010-01-01 00:00:00+00'
);
INSERT INTO core.supplier_identifiers(
  id,supplier_id,scheme,value_hash,display_value,verification_status,
  created_at
) VALUES(
  '6d390000-0000-4000-8000-000000000301',
  '6d390000-0000-4000-8000-000000000300','TEST_ONLY_REGISTRATION',
  pg_temp.r6d39_sha256_text('TEST-SUPPLIER-ANONYMIZE-0300'),
  'TEST-SUPPLIER-ANONYMIZE-0300','VERIFIED',
  '2010-01-01 00:00:00+00'
);
INSERT INTO core.entity_aliases(
  id,entity_type,entity_id,alias,normalized_alias,created_at
) VALUES(
  '6d390000-0000-4000-8000-000000000302','SUPPLIER',
  '6d390000-0000-4000-8000-000000000300',
  'TEST_ONLY 공급자 삭제 대상 별칭','test only 공급자 삭제 대상 별칭',
  '2010-01-01 00:00:00+00'
);

-- Isolate immutable publication membership and normalized-procurement
-- boundary tests from the two entities used by the human receipt and terminal
-- execution paths below.  Both rows remain STAGED_LEGACY and are never
-- retention candidates.
INSERT INTO core.agencies(
  id,canonical_name,agency_type,jurisdiction,active,identity_status,
  created_at,updated_at
) VALUES(
  '6d390000-0000-4000-8000-000000000003',
  'TEST_ONLY material-use agency','OTHER','KR',true,'VERIFIED',
  '2000-01-01 00:00:00+00','2000-01-01 00:00:00+00'
);
INSERT INTO core.suppliers(
  id,canonical_name,business_status,identity_status,created_at,updated_at
) VALUES(
  '6d390000-0000-4000-8000-000000000004',
  'TEST_ONLY material-use supplier','ACTIVE','VERIFIED',
  '2000-01-01 00:00:00+00','2000-01-01 00:00:00+00'
);

-- These four immutable payloads are the exact closure authority emitted after
-- direct AGENCY/SUPPLIER and indirect LINE_ITEM/CONTRACT_CHANGE topology
-- resolution.  The material-use owner deliberately consumes only the sorted,
-- unique ID arrays and their payload digest, never the mutable signal graph.
SELECT pg_temp.r6d39_insert_publication_revision(
  'direct-agency',pg_temp.r6d39_uuid('direct-agency:case'),
  pg_temp.r6d39_uuid('direct-agency:r1'),1,'PUBLISHED_ANOMALY',
  jsonb_build_array('6d390000-0000-4000-8000-000000000003'::uuid),
  '[]'::jsonb,NULL
);
SELECT pg_temp.r6d39_insert_publication_revision(
  'direct-supplier',pg_temp.r6d39_uuid('direct-supplier:case'),
  pg_temp.r6d39_uuid('direct-supplier:r1'),1,'PUBLISHED_ANOMALY',
  '[]'::jsonb,
  jsonb_build_array('6d390000-0000-4000-8000-000000000004'::uuid),NULL
);
SELECT pg_temp.r6d39_insert_publication_revision(
  'line-item',pg_temp.r6d39_uuid('line-item:case'),
  pg_temp.r6d39_uuid('line-item:r1'),1,'PUBLISHED_ANOMALY',
  jsonb_build_array('6d390000-0000-4000-8000-000000000003'::uuid),
  jsonb_build_array('6d390000-0000-4000-8000-000000000004'::uuid),NULL
);
SELECT pg_temp.r6d39_insert_publication_revision(
  'contract-change',pg_temp.r6d39_uuid('contract-change:case'),
  pg_temp.r6d39_uuid('contract-change:r1'),1,'PUBLISHED_ANOMALY',
  jsonb_build_array('6d390000-0000-4000-8000-000000000003'::uuid),
  jsonb_build_array('6d390000-0000-4000-8000-000000000004'::uuid),NULL
);

DO $d1_open_publication_membership$
DECLARE
  v_agency jsonb:=ops.r6d_entity_material_use_state_v1(
    'AGENCY','6d390000-0000-4000-8000-000000000003',clock_timestamp()
  );
  v_supplier jsonb:=ops.r6d_entity_material_use_state_v1(
    'SUPPLIER','6d390000-0000-4000-8000-000000000004',clock_timestamp()
  );
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (v_agency->>'publicationRevisionCount')::bigint=3
    AND (v_agency->>'openPublicationRevisionCount')::bigint=3
    AND (v_supplier->>'publicationRevisionCount')::bigint=3
    AND (v_supplier->>'openPublicationRevisionCount')::bigint=3,
    'open-publication-membership-agency-supplier-topologies'
  );
END
$d1_open_publication_membership$;

-- Superseding revisions do not include the entity and close each immutable
-- predecessor for closure evaluation without erasing publication history.
SELECT pg_temp.r6d39_insert_publication_revision(
  'direct-agency-successor',pg_temp.r6d39_uuid('direct-agency:case'),
  pg_temp.r6d39_uuid('direct-agency:r2'),2,'PUBLISHED_ANOMALY',
  '[]'::jsonb,'[]'::jsonb,1
);
SELECT pg_temp.r6d39_insert_publication_revision(
  'direct-supplier-successor',pg_temp.r6d39_uuid('direct-supplier:case'),
  pg_temp.r6d39_uuid('direct-supplier:r2'),2,'PUBLISHED_ANOMALY',
  '[]'::jsonb,'[]'::jsonb,1
);
SELECT pg_temp.r6d39_insert_publication_revision(
  'line-item-successor',pg_temp.r6d39_uuid('line-item:case'),
  pg_temp.r6d39_uuid('line-item:r2'),2,'PUBLISHED_ANOMALY',
  '[]'::jsonb,'[]'::jsonb,1
);
SELECT pg_temp.r6d39_insert_publication_revision(
  'contract-change-successor',pg_temp.r6d39_uuid('contract-change:case'),
  pg_temp.r6d39_uuid('contract-change:r2'),2,'PUBLISHED_ANOMALY',
  '[]'::jsonb,'[]'::jsonb,1
);
SELECT pg_temp.r6d39_insert_publication_revision(
  'retracted-membership',pg_temp.r6d39_uuid('retracted-membership:case'),
  pg_temp.r6d39_uuid('retracted-membership:r1'),1,'RETRACTED',
  jsonb_build_array('6d390000-0000-4000-8000-000000000003'::uuid),
  jsonb_build_array('6d390000-0000-4000-8000-000000000004'::uuid),NULL
);

DO $d1_closed_publication_membership$
DECLARE
  v_agency jsonb:=ops.r6d_entity_material_use_state_v1(
    'AGENCY','6d390000-0000-4000-8000-000000000003',clock_timestamp()
  );
  v_supplier jsonb:=ops.r6d_entity_material_use_state_v1(
    'SUPPLIER','6d390000-0000-4000-8000-000000000004',clock_timestamp()
  );
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (v_agency->>'publicationRevisionCount')::bigint=4
    AND (v_agency->>'openPublicationRevisionCount')::bigint=0
    AND (v_supplier->>'publicationRevisionCount')::bigint=4
    AND (v_supplier->>'openPublicationRevisionCount')::bigint=0,
    'superseded-retracted-publication-membership-closed'
  );
END
$d1_closed_publication_membership$;

-- Root A proves that an old null ends_at is ignored after a later immutable
-- revision supplies the final boundary.  Supplier membership is taken only
-- from the exact latest revision tuple in the normalized supplier relation.
SELECT pg_temp.r6d39_insert_procurement_revision(
  'procurement-a-r1',pg_temp.r6d39_uuid('procurement-a:root'),
  pg_temp.r6d39_uuid('procurement-a:r1'),1,
  '6d390000-0000-4000-8000-000000000003',
  '6d390000-0000-4000-8000-000000000004',NULL
);
SELECT pg_temp.r6d39_insert_procurement_revision(
  'procurement-a-r2',pg_temp.r6d39_uuid('procurement-a:root'),
  pg_temp.r6d39_uuid('procurement-a:r2'),2,
  '6d390000-0000-4000-8000-000000000003',
  '6d390000-0000-4000-8000-000000000004','2001-12-31'
);

DO $d1_latest_procurement_positive_a$
DECLARE
  v_agency jsonb:=ops.r6d_entity_material_use_state_v1(
    'AGENCY','6d390000-0000-4000-8000-000000000003',clock_timestamp()
  );
  v_supplier jsonb:=ops.r6d_entity_material_use_state_v1(
    'SUPPLIER','6d390000-0000-4000-8000-000000000004',clock_timestamp()
  );
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (v_agency->>'contractCount')::bigint=1
    AND (v_supplier->>'contractCount')::bigint=1
    AND (v_agency->>'finalContractEndAt')::date='2001-12-31'
    AND (v_supplier->>'finalContractEndAt')::date='2001-12-31'
    AND (v_agency->>'finalContractBoundaryAt')::timestamptz=
      ('2002-01-01 00:00:00'::timestamp AT TIME ZONE 'Asia/Seoul')
    AND (v_supplier->>'finalContractBoundaryAt')::timestamptz=
      ('2002-01-01 00:00:00'::timestamp AT TIME ZONE 'Asia/Seoul'),
    'latest-procurement-old-null-ignored-agency-supplier'
  );
END
$d1_latest_procurement_positive_a$;

-- Root B first leaves the newest ends_at unknown.  Both entity kinds must fail
-- closed until a later immutable revision supplies a boundary.
SELECT pg_temp.r6d39_insert_procurement_revision(
  'procurement-b-r1',pg_temp.r6d39_uuid('procurement-b:root'),
  pg_temp.r6d39_uuid('procurement-b:r1'),1,
  '6d390000-0000-4000-8000-000000000003',
  '6d390000-0000-4000-8000-000000000004','2002-06-30'
);
SELECT pg_temp.r6d39_insert_procurement_revision(
  'procurement-b-r2',pg_temp.r6d39_uuid('procurement-b:root'),
  pg_temp.r6d39_uuid('procurement-b:r2'),2,
  '6d390000-0000-4000-8000-000000000003',
  '6d390000-0000-4000-8000-000000000004',NULL
);

DO $d1_latest_procurement_null_fails_closed$
DECLARE
  v_agency_rejected boolean:=false;
  v_supplier_rejected boolean:=false;
BEGIN
  BEGIN
    PERFORM ops.r6d_entity_material_use_state_v1(
      'AGENCY','6d390000-0000-4000-8000-000000000003',clock_timestamp()
    );
  EXCEPTION WHEN OTHERS THEN
    v_agency_rejected:=SQLSTATE='55000'
      AND SQLERRM='r6d_entity_material_use_contract_end_unknown';
  END;
  BEGIN
    PERFORM ops.r6d_entity_material_use_state_v1(
      'SUPPLIER','6d390000-0000-4000-8000-000000000004',clock_timestamp()
    );
  EXCEPTION WHEN OTHERS THEN
    v_supplier_rejected:=SQLSTATE='55000'
      AND SQLERRM='r6d_entity_material_use_contract_end_unknown';
  END;
  PERFORM pg_temp.r6d39_assert(
    v_agency_rejected AND v_supplier_rejected,
    'latest-procurement-null-did-not-fail-closed'
  );
END
$d1_latest_procurement_null_fails_closed$;

SELECT pg_temp.r6d39_insert_procurement_revision(
  'procurement-b-r3',pg_temp.r6d39_uuid('procurement-b:root'),
  pg_temp.r6d39_uuid('procurement-b:r3'),3,
  '6d390000-0000-4000-8000-000000000003',
  '6d390000-0000-4000-8000-000000000004','2002-12-31'
);

DO $d1_latest_procurement_positive_b$
DECLARE
  v_agency jsonb:=ops.r6d_entity_material_use_state_v1(
    'AGENCY','6d390000-0000-4000-8000-000000000003',clock_timestamp()
  );
  v_supplier jsonb:=ops.r6d_entity_material_use_state_v1(
    'SUPPLIER','6d390000-0000-4000-8000-000000000004',clock_timestamp()
  );
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (v_agency->>'contractCount')::bigint=2
    AND (v_supplier->>'contractCount')::bigint=2
    AND (v_agency->>'finalContractEndAt')::date='2002-12-31'
    AND (v_supplier->>'finalContractEndAt')::date='2002-12-31',
    'latest-procurement-final-boundary-agency-supplier'
  );
END
$d1_latest_procurement_positive_b$;

-- Malformed, digest-mismatched, unsorted, and duplicate immutable payloads
-- each execute inside their own exception subtransaction.  The failing row is
-- rolled back before the next case, proving fail-closed behavior and zero
-- durable writes independently.
SELECT pg_temp.r6d39_expect_invalid_publication_membership(
  'publication-missing-array',
  '6d390000-0000-4000-8000-000000000003',
  jsonb_build_object(
    'agencyIds',jsonb_build_array(
      '6d390000-0000-4000-8000-000000000003'::uuid
    )
  ),
  pg_temp.r6d39_sha256_json(jsonb_build_object(
    'agencyIds',jsonb_build_array(
      '6d390000-0000-4000-8000-000000000003'::uuid
    )
  ))
);
SELECT pg_temp.r6d39_expect_invalid_publication_membership(
  'publication-digest-mismatch',
  '6d390000-0000-4000-8000-000000000003',
  jsonb_build_object(
    'agencyIds',jsonb_build_array(
      '6d390000-0000-4000-8000-000000000003'::uuid
    ),'supplierIds','[]'::jsonb
  ),repeat('f',64)
);
SELECT pg_temp.r6d39_expect_invalid_publication_membership(
  'publication-unsorted',
  '6d390000-0000-4000-8000-000000000003',
  jsonb_build_object(
    'agencyIds',jsonb_build_array(
      '6d390000-0000-4000-8000-000000000003'::uuid,
      '6d390000-0000-4000-8000-000000000001'::uuid
    ),'supplierIds','[]'::jsonb
  ),pg_temp.r6d39_sha256_json(jsonb_build_object(
    'agencyIds',jsonb_build_array(
      '6d390000-0000-4000-8000-000000000003'::uuid,
      '6d390000-0000-4000-8000-000000000001'::uuid
    ),'supplierIds','[]'::jsonb
  ))
);
SELECT pg_temp.r6d39_expect_invalid_publication_membership(
  'publication-duplicate',
  '6d390000-0000-4000-8000-000000000003',
  jsonb_build_object(
    'agencyIds',jsonb_build_array(
      '6d390000-0000-4000-8000-000000000003'::uuid,
      '6d390000-0000-4000-8000-000000000003'::uuid
    ),'supplierIds','[]'::jsonb
  ),pg_temp.r6d39_sha256_json(jsonb_build_object(
    'agencyIds',jsonb_build_array(
      '6d390000-0000-4000-8000-000000000003'::uuid,
      '6d390000-0000-4000-8000-000000000003'::uuid
    ),'supplierIds','[]'::jsonb
  ))
);

CREATE TEMP TABLE r6d39_entity_enqueue_result(payload jsonb) ON COMMIT DROP;
GRANT INSERT,SELECT ON r6d39_entity_enqueue_result TO gurine_scheduler;
SET LOCAL ROLE gurine_scheduler;
INSERT INTO r6d39_entity_enqueue_result(payload)
SELECT ops.enqueue_due_r6d_entity_retention_jobs_v1(100);
RESET ROLE;

DO $legacy_receipt_absence$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*)=0
     FROM ops.r6d_entity_personhood_classification_receipts_v1
     WHERE entity_id='6d390000-0000-4000-8000-000000000001'),
    'legacy-personhood-receipt-unexpected'
  );
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*)=0
     FROM ops.r6d_entity_material_use_closure_receipts_v1
     WHERE entity_id='6d390000-0000-4000-8000-000000000001'),
    'legacy-closure-receipt-unexpected'
  );
  PERFORM pg_temp.r6d39_assert(
    (SELECT payload->>'enqueuedCount' FROM r6d39_entity_enqueue_result)='0'
    AND NOT EXISTS(
      SELECT 1 FROM ops.jobs
      WHERE job_type='R6D_ENTITY_RETENTION'
        AND payload->>'entityId'='6d390000-0000-4000-8000-000000000001'
    ),
    'receiptless-entity-was-enqueued'
  );
END
$legacy_receipt_absence$;

DO $d2_definition_closure$
DECLARE
  v_attest text:=pg_temp.r6d39_function_definition(
    'editorial.attest_organization_official_channel_v1(jsonb,uuid,uuid,uuid,character,character)'
  );
  v_revoke text:=pg_temp.r6d39_function_definition(
    'editorial.revoke_organization_official_channel_v1(jsonb,uuid,uuid,uuid,character,character)'
  );
  v_source text:=pg_temp.r6d39_function_definition(
    'editorial.resolve_official_channel_source_v1(text,uuid,text,uuid,uuid,timestamp with time zone,timestamp with time zone)'
  );
  v_assertion text:=pg_temp.r6d39_function_definition(
    'editorial.require_control_actor_assertion_v1(uuid,character,timestamp with time zone)'
  );
BEGIN
  PERFORM pg_temp.r6d39_assert(EXISTS(
    SELECT 1 FROM pg_constraint AS con
    WHERE con.conrelid=
      'editorial.organization_official_channel_assertions_v1'::regclass
      AND con.contype='f'
      AND con.confrelid=
        'editorial.organization_official_channel_authority_receipts_v1'::regclass
      AND lower(pg_get_constraintdef(con.oid)) LIKE
        '%authority_receipt_id%organization_authority_receipt_digest%assertion_id%organization_kind%organization_id%verification_method%authority_source_id%expires_at%'
  ),'official-channel-authority-composite-fk');

  PERFORM pg_temp.r6d39_assert(
    position('responses.review' IN v_attest)>0
    AND position('step_up' IN v_attest)>0
    AND position('independent' IN v_attest)>0
    AND position('resolve_official_channel_source_v1' IN v_attest)>0
    AND position('jsonb_object_keys(p_payload))<>15' IN v_attest)>0
    AND position('_actorassertionrequestsha256' IN v_attest)>0
    AND position('require_control_actor_assertion_v1' IN v_attest)>0,
    'official-channel-owner-source-and-independence'
  );
  PERFORM pg_temp.r6d39_assert(
    position('communication_endpoint_verifications' IN v_source)>0
    AND position('email_link' IN v_source)>0
    AND position('communication_endpoint_link_events' IN v_source)>0
    AND position('editorial.evidence' IN v_source)>0
    AND position('raw.source_documents' IN v_source)>0
    AND position('record_status' IN v_source)>0
    AND position('current' IN v_source)>0,
    'official-channel-current-method-specific-source-resolver'
  );
  PERFORM pg_temp.r6d39_assert(
    position('organization_official_channel_revocation_receipts_v1' IN v_revoke)>0
    AND position('for update' IN v_revoke)>0
    AND position('responses.review' IN v_revoke)>0
    AND position('step_up' IN v_revoke)>0
    AND position('jsonb_object_keys(p_payload))<>11' IN v_revoke)>0
    AND position('_actorassertionrequestsha256' IN v_revoke)>0
    AND position('require_control_actor_assertion_v1' IN v_revoke)>0,
    'official-channel-revocation-owner'
  );
  PERFORM pg_temp.r6d39_assert(
    position('assertion_replay_guard' IN v_assertion)>0
    AND position('identity-api' IN v_assertion)>0
    AND position('control-api' IN v_assertion)>0
    AND position('request_digest<>p_actor_assertion_request_digest'
      IN v_assertion)>0
    AND position('expires_at<=p_evaluated_at' IN v_assertion)>0
    AND position('consumed_at>p_evaluated_at' IN v_assertion)>0,
    'official-channel-request-bound-actor-assertion'
  );
END
$d2_definition_closure$;

-- Exercise the producer through its only runtime role.  The official-document
-- source is a current VERIFIED/PUBLIC evidence row whose verifier is distinct
-- from the STEP_UP attestation actor.
INSERT INTO ops.users(id,oidc_subject,email,display_name,status) VALUES
  (
    '6d390000-0000-4000-8000-000000000020',
    'r6d39-official-channel-actor','r6d39-actor@example.test',
    'TEST_ONLY official channel actor','ACTIVE'
  ),
  (
    '6d390000-0000-4000-8000-000000000021',
    'r6d39-official-document-verifier','r6d39-verifier@example.test',
    'TEST_ONLY official document verifier','ACTIVE'
  ),
  (
    '6d390000-0000-4000-8000-000000000051',
    'r6d39-entity-closure-reviewer','r6d39-closure@example.test',
    'TEST_ONLY distinct entity closure reviewer','ACTIVE'
  );

INSERT INTO ops.user_roles(
  id,user_id,role_id,granted_by,reason,granted_at
)
SELECT
  '6d390000-0000-4000-8000-000000000022',
  '6d390000-0000-4000-8000-000000000020',role.id,
  '6d390000-0000-4000-8000-000000000020',
  'TEST_ONLY independent official-channel attestation',clock_timestamp()
FROM ops.roles AS role WHERE role.code='LEGAL_REVIEWER';

INSERT INTO ops.user_roles(
  id,user_id,role_id,granted_by,reason,granted_at
)
SELECT
  '6d390000-0000-4000-8000-000000000028',
  '6d390000-0000-4000-8000-000000000020',role.id,
  '6d390000-0000-4000-8000-000000000020',
  'TEST_ONLY human entity data review',clock_timestamp()
FROM ops.roles AS role WHERE role.code='ACCESS_ADMIN';

INSERT INTO ops.user_roles(
  id,user_id,role_id,granted_by,reason,granted_at
)
SELECT
  '6d390000-0000-4000-8000-000000000052',
  '6d390000-0000-4000-8000-000000000051',role.id,
  '6d390000-0000-4000-8000-000000000020',
  'TEST_ONLY independent material-use closure review',clock_timestamp()
FROM ops.roles AS role WHERE role.code='ACCESS_ADMIN';

INSERT INTO ops.sessions(
  id,user_id,session_token_hash,csrf_token_hash,auth_time,step_up_at,expires_at
) VALUES
  (
    '6d390000-0000-4000-8000-000000000023',
    '6d390000-0000-4000-8000-000000000020',repeat('1',64),repeat('2',64),
    clock_timestamp()-interval '10 minutes',
    clock_timestamp()-interval '2 minutes',clock_timestamp()+interval '1 hour'
  ),
  (
    '6d390000-0000-4000-8000-000000000053',
    '6d390000-0000-4000-8000-000000000051',repeat('6',64),repeat('7',64),
    clock_timestamp()-interval '10 minutes',
    clock_timestamp()-interval '2 minutes',clock_timestamp()+interval '1 hour'
  );

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
) VALUES
  (
    '6d390000-0000-4000-8000-000000000024',
    '6d390000-0000-4000-8000-000000000023',repeat('3',64),repeat('4',64),
    repeat('5',64),clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  ),
  (
    '6d390000-0000-4000-8000-000000000025',
    '6d390000-0000-4000-8000-000000000023',repeat('6',64),repeat('7',64),
    repeat('8',64),clock_timestamp()+interval '4 minutes 30 seconds',1,3,
    clock_timestamp()-interval '30 seconds'
  ),
  (
    '6d390000-0000-4000-8000-000000000026',
    '6d390000-0000-4000-8000-000000000023',repeat('a',64),repeat('0',64),
    repeat('c',64),clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  ),
  (
    '6d390000-0000-4000-8000-000000000027',
    '6d390000-0000-4000-8000-000000000023',repeat('b',64),repeat('9',64),
    repeat('d',64),clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  ),
  (
    '6d390000-0000-4000-8000-000000000029',
    '6d390000-0000-4000-8000-000000000023',repeat('2',64),repeat('3',64),
    repeat('e',64),clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  ),
  (
    '6d390000-0000-4000-8000-00000000002a',
    '6d390000-0000-4000-8000-000000000023',repeat('4',64),repeat('5',64),
    repeat('f',64),clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  ),
  (
    '6d390000-0000-4000-8000-000000000054',
    '6d390000-0000-4000-8000-000000000053',repeat('b',64),repeat('9',64),
    repeat('0',64),clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  );

INSERT INTO ops.assertion_replay_guard(
  assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
) VALUES
  (
    'ACTOR','6d390000-0000-4000-8000-000000000040',
    'identity-api','control-api',repeat('c',64),
    clock_timestamp()+interval '10 minutes',
    clock_timestamp()-interval '1 minute'
  ),
  (
    'ACTOR','6d390000-0000-4000-8000-000000000042',
    'identity-api','control-api',repeat('d',64),
    clock_timestamp()+interval '10 minutes',
    clock_timestamp()-interval '1 minute'
  ),
  (
    'ACTOR','6d390000-0000-4000-8000-000000000044',
    'identity-api','control-api',repeat('e',64),
    clock_timestamp()+interval '10 minutes',
    clock_timestamp()-interval '1 minute'
  ),
  (
    'ACTOR','6d390000-0000-4000-8000-000000000046',
    'identity-api','control-api',repeat('f',64),
    clock_timestamp()+interval '10 minutes',
    clock_timestamp()-interval '1 minute'
  ),
  (
    'ACTOR','6d390000-0000-4000-8000-000000000055',
    'identity-api','control-api',repeat('f',64),
    clock_timestamp()+interval '10 minutes',
    clock_timestamp()-interval '1 minute'
  );

INSERT INTO ops.idempotency_keys(
  scope,key_hash,request_hash,expires_at
) VALUES
  (
    'control:6d390000-0000-4000-8000-000000000020:attestOrganizationOfficialChannel',
    repeat('4',64),repeat('a',64),clock_timestamp()+interval '1 hour'
  ),
  (
    'control:6d390000-0000-4000-8000-000000000020:revokeOrganizationOfficialChannel',
    repeat('7',64),repeat('b',64),clock_timestamp()+interval '1 hour'
  ),
  (
    'control:6d390000-0000-4000-8000-000000000020:classifyEntityPersonhood',
    repeat('0',64),repeat('1',64),clock_timestamp()+interval '1 hour'
  ),
  (
    'control:6d390000-0000-4000-8000-000000000020:attestEntityMaterialUseClosure',
    repeat('9',64),repeat('8',64),clock_timestamp()+interval '1 hour'
  ),
  (
    'control:6d390000-0000-4000-8000-000000000051:attestEntityMaterialUseClosure',
    repeat('9',64),repeat('8',64),clock_timestamp()+interval '1 hour'
  );

INSERT INTO editorial.cases(
  id,public_slug,title,investigation_state,publication_state,summary,
  priority,version
) VALUES(
  '6d390000-0000-4000-8000-000000000030',
  'r6d39-official-channel','TEST_ONLY 공식 채널 출처 검토',
  'INVESTIGATING','NEVER_PUBLISHED','TEST_ONLY rollback-only evidence',
  'HIGH',1
);

INSERT INTO ops.source_registry(
  source_id,display_name,connector_type,owner_team,enabled,schedule_cron,
  legal_status,configuration,version
) VALUES(
  'r6d39-official-document','TEST_ONLY official document source','HTTP',
  'TEST_ONLY',false,'0 0 * * *','APPROVED','{}'::jsonb,1
);

INSERT INTO raw.source_documents(
  id,source_id,external_id,retrieved_at,content_type,content_sha256,
  content_size_bytes,object_key,status,prompt_injection_flags,metadata,
  record_status,asset_id,asset_revision
) VALUES(
  '6d390000-0000-4000-8000-000000000031',
  'r6d39-official-document','TEST_ONLY-OFFICIAL-DOCUMENT',
  clock_timestamp()-interval '1 day','application/pdf',repeat('9',64),128,
  'test-only/r6d39-official-document.pdf','PARSED','[]'::jsonb,'{}'::jsonb,
  'CURRENT','6d390000-0000-4000-8000-000000000031',1
);

INSERT INTO editorial.evidence(
  id,case_id,evidence_type,title,source_document_id,source_locator,
  content_sha256,classification,verification_status,verified_by,verified_at,
  version,created_by
) VALUES(
  '6d390000-0000-4000-8000-000000000032',
  '6d390000-0000-4000-8000-000000000030','DOCUMENT',
  'TEST_ONLY 기관 공식 공문',
  '6d390000-0000-4000-8000-000000000031',
  'test-only/r6d39-official-document.pdf#page=1',repeat('9',64),
  'PUBLIC','VERIFIED','6d390000-0000-4000-8000-000000000021',
  clock_timestamp()-interval '5 minutes',1,
  '6d390000-0000-4000-8000-000000000021'
);

-- Exercise both D1 human authority owners on the staged legacy entity.  The
-- current receipt is intentionally not due for terminal retention; the
-- historical due-chain fixture below is separate because the production clock
-- and the approved five-year schedule must not be weakened for a test.
CREATE TEMP TABLE r6d39_entity_authority_results(
  operation text PRIMARY KEY,
  payload jsonb NOT NULL
) ON COMMIT DROP;
GRANT INSERT,SELECT ON r6d39_entity_authority_results TO gurine_control_api;

SET LOCAL ROLE gurine_control_api;
INSERT INTO r6d39_entity_authority_results(operation,payload)
SELECT 'CLASSIFY',ops.classify_r6d_entity_personhood_v1(
  jsonb_build_object(
    'entityKind','AGENCY',
    'entityId','6d390000-0000-4000-8000-000000000001',
    'classification','NATURAL_PERSON',
    'evidenceSourceLocator',
      'test-only/r6d39-official-document.pdf#business-registration-form',
    'reason','TEST_ONLY human review of public registration form',
    'expectedEntityUpdatedAt','2000-01-01 00:00:00+00',
    '_actorAssertionJti','6d390000-0000-4000-8000-000000000044',
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','users.manage',
    '_actorActionDigest',repeat('a',64),
    '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000026',
    '_actorIdempotencyKeySha256',repeat('0',64),
    '_actorRequestKeySha256',repeat('0',64),
    '_actorAssertionRequestSha256',repeat('e',64)
  ),
  '6d390000-0000-4000-8000-000000000020',
  '6d390000-0000-4000-8000-000000000023',
  '6d390000-0000-4000-8000-000000000045',repeat('0',64),repeat('1',64)
);
RESET ROLE;

-- Classification independence is human-versus-automation.  Closure has the
-- additional two-stage DB invariant: its human actor must differ from the
-- actor recorded on the referenced personhood classification receipt.
CREATE TEMP TABLE r6d39_entity_closure_independence(
  rejected boolean NOT NULL DEFAULT false,
  error_state text,
  error_message text
) ON COMMIT DROP;
INSERT INTO r6d39_entity_closure_independence DEFAULT VALUES;
GRANT SELECT,UPDATE ON r6d39_entity_closure_independence
  TO gurine_control_api;

SET LOCAL ROLE gurine_control_api;
DO $same_actor_closure_rejected$
DECLARE
  v_personhood_id uuid;
BEGIN
  SELECT (payload->>'receiptId')::uuid INTO STRICT v_personhood_id
  FROM r6d39_entity_authority_results WHERE operation='CLASSIFY';
  PERFORM ops.attest_r6d_entity_material_use_closure_v1(
    jsonb_build_object(
      'entityKind','AGENCY',
      'entityId','6d390000-0000-4000-8000-000000000001',
      'personhoodReceiptId',v_personhood_id,
      'reason','TEST_ONLY same classifier cannot attest closure',
      'expectedEntityUpdatedAt',(
        SELECT updated_at
        FROM core.agencies
        WHERE id='6d390000-0000-4000-8000-000000000001'
      ),
      '_actorAssertionJti','6d390000-0000-4000-8000-000000000046',
      '_actorAssuranceLevel','STEP_UP',
      '_actorEffectiveCapability','users.manage',
      '_actorActionDigest',repeat('b',64),
      '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000027',
      '_actorIdempotencyKeySha256',repeat('9',64),
      '_actorRequestKeySha256',repeat('9',64),
      '_actorAssertionRequestSha256',repeat('f',64)
    ),
    '6d390000-0000-4000-8000-000000000020',
    '6d390000-0000-4000-8000-000000000023',
    '6d390000-0000-4000-8000-000000000047',repeat('9',64),repeat('8',64)
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_entity_closure_independence
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM;
END
$same_actor_closure_rejected$;
RESET ROLE;

DO $same_actor_closure_zero_write$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (SELECT rejected AND error_state='55000'
       AND error_message='r6d_entity_closure_actor_not_independent'
     FROM r6d39_entity_closure_independence)
    AND NOT EXISTS(
      SELECT 1 FROM ops.r6d_entity_material_use_closure_receipts_v1
      WHERE entity_kind='AGENCY'
        AND entity_id='6d390000-0000-4000-8000-000000000001'
    )
    AND NOT EXISTS(
      SELECT 1 FROM ops.audit_events
      WHERE request_id='6d390000-0000-4000-8000-000000000047'
    )
    AND NOT EXISTS(
      SELECT 1 FROM ops.outbox
      WHERE event_type='entity.material_use_closed.v1'
    )
    AND (SELECT r6d_closure_receipt_id IS NULL
         FROM core.agencies
         WHERE id='6d390000-0000-4000-8000-000000000001'),
    'same-classifier-closure-exact-error-zero-write'
  );
END
$same_actor_closure_zero_write$;

SET LOCAL ROLE gurine_control_api;
INSERT INTO r6d39_entity_authority_results(operation,payload)
SELECT 'CLOSE',ops.attest_r6d_entity_material_use_closure_v1(
  jsonb_build_object(
    'entityKind','AGENCY',
    'entityId','6d390000-0000-4000-8000-000000000001',
    'personhoodReceiptId',classification.payload->>'receiptId',
    'reason','TEST_ONLY no contract or open publication reference remains',
    'expectedEntityUpdatedAt',(
      SELECT updated_at
      FROM core.agencies
      WHERE id='6d390000-0000-4000-8000-000000000001'
    ),
    '_actorAssertionJti','6d390000-0000-4000-8000-000000000055',
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','users.manage',
    '_actorActionDigest',repeat('b',64),
    '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000054',
    '_actorIdempotencyKeySha256',repeat('9',64),
    '_actorRequestKeySha256',repeat('9',64),
    '_actorAssertionRequestSha256',repeat('f',64)
  ),
  '6d390000-0000-4000-8000-000000000051',
  '6d390000-0000-4000-8000-000000000053',
  '6d390000-0000-4000-8000-000000000047',repeat('9',64),repeat('8',64)
)
FROM r6d39_entity_authority_results AS classification
WHERE classification.operation='CLASSIFY';
RESET ROLE;

DO $d1_human_owner_success$
DECLARE
  v_classification jsonb;
  v_closure jsonb;
BEGIN
  SELECT payload INTO STRICT v_classification
  FROM r6d39_entity_authority_results WHERE operation='CLASSIFY';
  SELECT payload INTO STRICT v_closure
  FROM r6d39_entity_authority_results WHERE operation='CLOSE';
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*) FROM jsonb_object_keys(v_classification))=9
    AND (v_classification->>'replayed')::boolean=false
    AND v_classification->>'classification'='NATURAL_PERSON'
    AND (SELECT count(*) FROM jsonb_object_keys(v_closure))=12
    AND (v_closure->>'replayed')::boolean=false
    AND (v_closure->>'linkedPublicationRevisionCount')::bigint=0
    AND v_closure->'lastContractEndAt'='null'::jsonb,
    'entity-human-owner-result-shape'
  );
  PERFORM pg_temp.r6d39_assert(
    EXISTS(
      SELECT 1
      FROM ops.r6d_entity_personhood_classification_receipts_v1 AS receipt
      WHERE receipt.receipt_id=(v_classification->>'receiptId')::uuid
        AND receipt.receipt_digest=v_classification->>'receiptDigest'
        AND receipt.receipt_canonical=ops.canonical_jsonb_v1(
          receipt.receipt_payload
        )
    ) AND EXISTS(
      SELECT 1
      FROM ops.r6d_entity_material_use_closure_receipts_v1 AS receipt
      WHERE receipt.receipt_id=(v_closure->>'closureReceiptId')::uuid
        AND receipt.receipt_digest=v_closure->>'receiptDigest'
        AND receipt.personhood_receipt_id=
          (v_classification->>'receiptId')::uuid
        AND receipt.actor_id='6d390000-0000-4000-8000-000000000051'
        AND receipt.receipt_canonical=ops.canonical_jsonb_v1(
          receipt.receipt_payload
        )
    ),
    'entity-human-owner-immutable-receipt-binding'
  );
  PERFORM pg_temp.r6d39_assert(
    EXISTS(
      SELECT 1 FROM core.agencies AS agency
      WHERE agency.id='6d390000-0000-4000-8000-000000000001'
        AND agency.r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
        AND agency.r6d_personhood_receipt_id=
          (v_classification->>'receiptId')::uuid
        AND agency.r6d_closure_receipt_id=
          (v_closure->>'closureReceiptId')::uuid
        AND agency.canonical_name='TEST_ONLY 영수증 없는 자연인 후보'
        AND agency.retention_record_class='AGENCY_MASTER'
        AND num_nonnulls(
          agency.retention_schedule_id,agency.retention_schedule_digest
        )=2
    ),
    'entity-human-owner-subject-pointer'
  );
END
$d1_human_owner_success$;

-- A caller-controlled custom GUC is not authority.  The ingest role lacks the
-- R6d authority columns entirely, and even a privileged direct statement is
-- rejected when the immutable receipt belongs to another entity.
CREATE TEMP TABLE r6d39_entity_direct_spoof_boundary(
  operation text PRIMARY KEY,
  rejected boolean NOT NULL DEFAULT false,
  error_state text,
  error_message text,
  before_row jsonb NOT NULL,
  after_row jsonb
) ON COMMIT DROP;
INSERT INTO r6d39_entity_direct_spoof_boundary(operation,before_row)
SELECT operation,to_jsonb(agency)
FROM core.agencies AS agency
CROSS JOIN unnest(ARRAY[
  'INGEST_GUC_CLASSIFICATION','WRONG_ENTITY_CLASSIFICATION'
]) AS attempted(operation)
WHERE agency.id='6d390000-0000-4000-8000-000000000002';
GRANT SELECT,UPDATE ON r6d39_entity_direct_spoof_boundary
  TO gurine_ingest_worker;

SET LOCAL ROLE gurine_ingest_worker;
SELECT set_config('gurine.r6d_entity_classification','1',true);
DO $d1_ingest_guc_classification_spoof$
BEGIN
  UPDATE core.agencies
  SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
      r6d_personhood_receipt_id=
        '00000000-0000-0000-0000-000000000001',
      r6d_personhood_receipt_digest=repeat('a',64)
  WHERE id='6d390000-0000-4000-8000-000000000002';
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_entity_direct_spoof_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='INGEST_GUC_CLASSIFICATION';
END
$d1_ingest_guc_classification_spoof$;
SELECT set_config('gurine.r6d_entity_classification','',true);
RESET ROLE;

SELECT set_config('gurine.r6d_entity_classification','1',true);
DO $d1_wrong_entity_classification_receipt$
DECLARE
  v_receipt_id uuid;
  v_receipt_digest char(64);
BEGIN
  SELECT (payload->>'receiptId')::uuid,
    (payload->>'receiptDigest')::char(64)
  INTO STRICT v_receipt_id,v_receipt_digest
  FROM r6d39_entity_authority_results
  WHERE operation='CLASSIFY';
  UPDATE core.agencies
  SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
      r6d_canonical_name_digest=
        pg_temp.r6d39_sha256_text(canonical_name),
      r6d_jurisdiction_digest=pg_temp.r6d39_sha256_text(jurisdiction),
      r6d_personhood_receipt_id=v_receipt_id,
      r6d_personhood_receipt_digest=v_receipt_digest
  WHERE id='6d390000-0000-4000-8000-000000000002';
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_entity_direct_spoof_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='WRONG_ENTITY_CLASSIFICATION';
END
$d1_wrong_entity_classification_receipt$;
SELECT set_config('gurine.r6d_entity_classification','',true);

UPDATE r6d39_entity_direct_spoof_boundary AS boundary
SET after_row=to_jsonb(agency)
FROM core.agencies AS agency
WHERE agency.id='6d390000-0000-4000-8000-000000000002';

DO $d1_direct_classification_spoof_zero_write$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (SELECT rejected AND error_state='42501'
       AND error_message='permission denied for table agencies'
     FROM r6d39_entity_direct_spoof_boundary
     WHERE operation='INGEST_GUC_CLASSIFICATION')
    AND (SELECT rejected AND error_state='55000'
           AND error_message='r6d_entity_classification_transition_invalid'
         FROM r6d39_entity_direct_spoof_boundary
         WHERE operation='WRONG_ENTITY_CLASSIFICATION')
    AND (SELECT bool_and(before_row=after_row)
         FROM r6d39_entity_direct_spoof_boundary),
    'entity-direct-classification-spoof-wrote-state'
  );
END
$d1_direct_classification_spoof_zero_write$;

CREATE TEMP TABLE r6d39_entity_owner_reentry(
  operation text PRIMARY KEY,
  rejected boolean NOT NULL DEFAULT false,
  error_state text,
  error_message text
) ON COMMIT DROP;
INSERT INTO r6d39_entity_owner_reentry(operation) VALUES
  ('CLASSIFY_EXACT'),('CLOSE_CHANGED');
GRANT SELECT,UPDATE ON r6d39_entity_owner_reentry TO gurine_control_api;

SET LOCAL ROLE gurine_control_api;
DO $classification_owner_reentry$
BEGIN
  PERFORM ops.classify_r6d_entity_personhood_v1(
    jsonb_build_object(
      'entityKind','AGENCY',
      'entityId','6d390000-0000-4000-8000-000000000001',
      'classification','NATURAL_PERSON',
      'evidenceSourceLocator',
        'test-only/r6d39-official-document.pdf#business-registration-form',
      'reason','TEST_ONLY human review of public registration form',
      'expectedEntityUpdatedAt','2000-01-01 00:00:00+00',
      '_actorAssertionJti','6d390000-0000-4000-8000-000000000044',
      '_actorAssuranceLevel','STEP_UP',
      '_actorEffectiveCapability','users.manage',
      '_actorActionDigest',repeat('a',64),
      '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000026',
      '_actorIdempotencyKeySha256',repeat('0',64),
      '_actorRequestKeySha256',repeat('0',64),
      '_actorAssertionRequestSha256',repeat('e',64)
    ),
    '6d390000-0000-4000-8000-000000000020',
    '6d390000-0000-4000-8000-000000000023',
    '6d390000-0000-4000-8000-000000000045',repeat('0',64),repeat('1',64)
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_entity_owner_reentry
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='CLASSIFY_EXACT';
END
$classification_owner_reentry$;

DO $closure_owner_changed_reentry$
DECLARE
  v_personhood_id uuid;
BEGIN
  SELECT (payload->>'receiptId')::uuid INTO STRICT v_personhood_id
  FROM r6d39_entity_authority_results WHERE operation='CLASSIFY';
  PERFORM ops.attest_r6d_entity_material_use_closure_v1(
    jsonb_build_object(
      'entityKind','AGENCY',
      'entityId','6d390000-0000-4000-8000-000000000001',
      'personhoodReceiptId',v_personhood_id,
      'reason','TEST_ONLY changed replay reason must not append',
      'expectedEntityUpdatedAt',(
        SELECT updated_at
        FROM core.agencies
        WHERE id='6d390000-0000-4000-8000-000000000001'
      ),
      '_actorAssertionJti','6d390000-0000-4000-8000-000000000055',
      '_actorAssuranceLevel','STEP_UP',
      '_actorEffectiveCapability','users.manage',
      '_actorActionDigest',repeat('b',64),
      '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000054',
      '_actorIdempotencyKeySha256',repeat('9',64),
      '_actorRequestKeySha256',repeat('9',64),
      '_actorAssertionRequestSha256',repeat('f',64)
    ),
    '6d390000-0000-4000-8000-000000000051',
    '6d390000-0000-4000-8000-000000000053',
    '6d390000-0000-4000-8000-000000000047',repeat('9',64),repeat('7',64)
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_entity_owner_reentry
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='CLOSE_CHANGED';
END
$closure_owner_changed_reentry$;
RESET ROLE;

DO $d1_owner_reentry_zero_write$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (SELECT rejected AND error_state='40001'
       AND error_message='r6d_entity_personhood_owner_reentry'
     FROM r6d39_entity_owner_reentry WHERE operation='CLASSIFY_EXACT')
    AND (SELECT rejected AND error_state='40001'
           AND error_message='r6d_entity_closure_owner_reentry'
         FROM r6d39_entity_owner_reentry WHERE operation='CLOSE_CHANGED')
    AND (SELECT count(*)=1
         FROM ops.r6d_entity_personhood_classification_receipts_v1
         WHERE entity_id='6d390000-0000-4000-8000-000000000001')
    AND (SELECT count(*)=1
         FROM ops.r6d_entity_material_use_closure_receipts_v1
         WHERE entity_id='6d390000-0000-4000-8000-000000000001')
    AND (SELECT count(*)=1 FROM ops.audit_events
         WHERE request_id='6d390000-0000-4000-8000-000000000045')
    AND (SELECT count(*)=1 FROM ops.audit_events
         WHERE request_id='6d390000-0000-4000-8000-000000000047'),
    'entity-owner-reentry-appended-state'
  );
END
$d1_owner_reentry_zero_write$;

-- A five-year production schedule cannot become due during a current-time
-- owner call.  Build a fully constrained historical authority graph instead;
-- every row is TEST_FIXTURE_ONLY and the surrounding transaction rolls it
-- back unless the disposable concurrency phase explicitly asks to commit.
INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
) VALUES
  (
    '6d390000-0000-4000-8000-000000000204',
    '6d390000-0000-4000-8000-000000000023',
    pg_temp.r6d39_sha256_text('historical-personhood-action'),
    pg_temp.r6d39_sha256_text('historical-personhood-idempotency'),
    pg_temp.r6d39_sha256_text('historical-personhood-token'),
    clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  ),
  (
    '6d390000-0000-4000-8000-000000000205',
    '6d390000-0000-4000-8000-000000000023',
    pg_temp.r6d39_sha256_text('historical-closure-action'),
    pg_temp.r6d39_sha256_text('historical-closure-idempotency'),
    pg_temp.r6d39_sha256_text('historical-closure-token'),
    clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  );

DO $d1_historical_authority_graph$
DECLARE
  v_entity_id constant uuid:='6d390000-0000-4000-8000-000000000002';
  v_actor_id constant uuid:='6d390000-0000-4000-8000-000000000020';
  v_session_id constant uuid:='6d390000-0000-4000-8000-000000000023';
  v_personhood_id constant uuid:='6d390000-0000-4000-8000-000000000200';
  v_closure_id constant uuid:='6d390000-0000-4000-8000-000000000201';
  v_personhood_request_id constant uuid:=
    '6d390000-0000-4000-8000-000000000206';
  v_closure_request_id constant uuid:=
    '6d390000-0000-4000-8000-000000000207';
  v_personhood_assertion constant uuid:=
    '6d390000-0000-4000-8000-000000000202';
  v_closure_assertion constant uuid:=
    '6d390000-0000-4000-8000-000000000203';
  v_entity_updated_at timestamptz;
  v_classified_at timestamptz:=
    clock_timestamp()-make_interval(secs=>157680000)-interval '3 days';
  v_closure_at timestamptz:=
    clock_timestamp()-make_interval(secs=>157680000)-interval '2 days';
  v_material jsonb;
  v_payload jsonb;
  v_canonical bytea;
  v_digest char(64);
  v_personhood_digest char(64);
  v_audit uuid;
  v_outbox uuid;
BEGIN
  SELECT updated_at INTO STRICT v_entity_updated_at
  FROM core.agencies WHERE id=v_entity_id;

  v_audit:=ops.append_audit_event(
    'r6d-entity-personhood:agency:'||v_entity_id::text,
    'USER',v_actor_id::text,v_session_id,
    'r6d.entity_personhood.classify','Entity',v_entity_id::text,
    'users.manage','SUCCESS','TEST_ONLY_HISTORICAL_AUTHORITY',
    v_personhood_request_id,jsonb_build_object(
      'fixture','r6d-authority-closure-runtime',
      'classification','NATURAL_PERSON'
    )
  );
  v_payload:=jsonb_build_object(
    'schemaVersion','r6d-entity-personhood-classification-receipt.v1',
    'receiptId',v_personhood_id,'entityKind','AGENCY',
    'entityId',v_entity_id,'classification','NATURAL_PERSON',
    'classificationVersion',1,'entityUpdatedAt',v_entity_updated_at,
    'evidenceSourceLocatorDigest',pg_temp.r6d39_sha256_text(
      'test-only/r6d39-historical-registration#public-form'
    ),
    'reasonDigest',pg_temp.r6d39_sha256_text(
      'TEST_ONLY historical human classification'
    ),
    'capabilityAuthorityDigest',pg_temp.r6d39_sha256_text(
      'TEST_ONLY users.manage authority'
    ),
    'actorId',v_actor_id,'sessionId',v_session_id,
    'actorAssertionJti',v_personhood_assertion,
    'actorAssertionRequestDigest',pg_temp.r6d39_sha256_text(
      'historical-personhood-assertion-request'
    ),
    'stepUpAuthorizationId','6d390000-0000-4000-8000-000000000204'::uuid,
    'stepUpReceiptDigest',pg_temp.r6d39_sha256_text(
      'historical-personhood-step-up-receipt'
    ),
    'requestId',v_personhood_request_id,
    'idempotencyKeySha256',pg_temp.r6d39_sha256_text(
      'historical-personhood-idempotency'
    ),
    'requestDigest',pg_temp.r6d39_sha256_text(
      'historical-personhood-request'
    ),
    'auditEventId',v_audit,'classifiedAt',v_classified_at
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_digest:=encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_personhood_digest:=v_digest;
  v_outbox:=ops.enqueue_outbox(
    'r6d_entity_personhood',v_personhood_id::text,1,
    'entity.personhood_classified.v1',jsonb_build_object(
      'entityKind','AGENCY','entityId',v_entity_id,
      'classification','NATURAL_PERSON',
      'evidenceSourceLocatorDigest',
        v_payload->>'evidenceSourceLocatorDigest',
      'receiptDigest',btrim(v_digest),'classifiedAt',v_classified_at
    ),v_classified_at
  );
  INSERT INTO ops.r6d_entity_personhood_classification_receipts_v1(
    receipt_id,entity_kind,entity_id,classification,
    classification_version,entity_updated_at,
    evidence_source_locator_digest,reason_digest,
    capability_authority_digest,actor_id,session_id,actor_assertion_jti,
    actor_assertion_request_digest,step_up_authorization_id,
    step_up_receipt_digest,request_id,idempotency_key_sha256,
    request_digest,audit_event_id,outbox_event_id,receipt_payload,
    receipt_canonical,receipt_digest,classified_at
  ) VALUES(
    v_personhood_id,'AGENCY',v_entity_id,'NATURAL_PERSON',1,
    v_entity_updated_at,
    (v_payload->>'evidenceSourceLocatorDigest')::char(64),
    (v_payload->>'reasonDigest')::char(64),
    (v_payload->>'capabilityAuthorityDigest')::char(64),
    v_actor_id,v_session_id,v_personhood_assertion,
    (v_payload->>'actorAssertionRequestDigest')::char(64),
    '6d390000-0000-4000-8000-000000000204',
    (v_payload->>'stepUpReceiptDigest')::char(64),v_personhood_request_id,
    (v_payload->>'idempotencyKeySha256')::char(64),
    (v_payload->>'requestDigest')::char(64),v_audit,v_outbox,v_payload,
    v_canonical,v_digest,v_classified_at
  );

  PERFORM set_config('gurine.r6d_entity_classification','1',true);
  UPDATE core.agencies
  SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
      r6d_canonical_name_digest=pg_temp.r6d39_sha256_text(canonical_name),
      r6d_jurisdiction_digest=pg_temp.r6d39_sha256_text(jurisdiction),
      r6d_personhood_receipt_id=v_personhood_id,
      r6d_personhood_receipt_digest=v_personhood_digest
  WHERE id=v_entity_id;
  UPDATE core.agency_identifiers
  SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
      r6d_value_digest=pg_temp.r6d39_sha256_text(value)
  WHERE agency_id=v_entity_id;
  UPDATE core.entity_aliases
  SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
      r6d_alias_digest=pg_temp.r6d39_sha256_text(alias),
      r6d_normalized_alias_digest=pg_temp.r6d39_sha256_text(normalized_alias)
  WHERE entity_type='AGENCY' AND entity_id=v_entity_id;
  PERFORM set_config('gurine.r6d_entity_classification','',true);

  SELECT updated_at INTO STRICT v_entity_updated_at
  FROM core.agencies WHERE id=v_entity_id;
  v_material:=ops.r6d_entity_material_use_state_v1(
    'AGENCY',v_entity_id,clock_timestamp()
  );
  PERFORM pg_temp.r6d39_assert(
    (v_material->>'contractCount')::bigint=0
    AND (v_material->>'publicationRevisionCount')::bigint=0
    AND (v_material->>'openPublicationRevisionCount')::bigint=0
    AND NOT (v_material->>'legalHoldActive')::boolean,
    'historical-material-use-not-closed'
  );
  v_audit:=ops.append_audit_event(
    'r6d-entity-closure:agency:'||v_entity_id::text,
    'USER',v_actor_id::text,v_session_id,
    'r6d.entity_material_use.close','Entity',v_entity_id::text,
    'users.manage','SUCCESS','TEST_ONLY_HISTORICAL_AUTHORITY',
    v_closure_request_id,jsonb_build_object(
      'fixture','r6d-authority-closure-runtime',
      'personhoodReceiptId',v_personhood_id
    )
  );
  v_payload:=jsonb_build_object(
    'schemaVersion','r6d-entity-material-use-closure-receipt.v1',
    'receiptId',v_closure_id,'entityKind','AGENCY','entityId',v_entity_id,
    'closureVersion',1,'entityUpdatedAt',v_entity_updated_at,
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
    'reasonDigest',pg_temp.r6d39_sha256_text(
      'TEST_ONLY historical material-use closure'
    ),
    'capabilityAuthorityDigest',pg_temp.r6d39_sha256_text(
      'TEST_ONLY users.manage authority'
    ),
    'actorId',v_actor_id,'sessionId',v_session_id,
    'actorAssertionJti',v_closure_assertion,
    'actorAssertionRequestDigest',pg_temp.r6d39_sha256_text(
      'historical-closure-assertion-request'
    ),
    'stepUpAuthorizationId','6d390000-0000-4000-8000-000000000205'::uuid,
    'stepUpReceiptDigest',pg_temp.r6d39_sha256_text(
      'historical-closure-step-up-receipt'
    ),
    'requestId',v_closure_request_id,
    'idempotencyKeySha256',pg_temp.r6d39_sha256_text(
      'historical-closure-idempotency'
    ),
    'requestDigest',pg_temp.r6d39_sha256_text(
      'historical-closure-request'
    ),
    'auditEventId',v_audit,'closureAt',v_closure_at,
    'attestedAt',v_closure_at
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_digest:=encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_outbox:=ops.enqueue_outbox(
    'r6d_entity_material_use',v_closure_id::text,1,
    'entity.material_use_closed.v1',jsonb_build_object(
      'entityKind','AGENCY','entityId',v_entity_id,
      'personhoodReceiptDigest',btrim(v_personhood_digest),
      'closureAt',v_closure_at,'lastContractEndAt',NULL,
      'linkedPublicationRevisionCount',0,
      'receiptDigest',btrim(v_digest)
    ),v_closure_at
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
    v_closure_id,'AGENCY',v_entity_id,1,v_entity_updated_at,
    v_personhood_id,v_personhood_digest,
    (v_material->>'contractCount')::bigint,
    (v_material->>'contractSetDigest')::char(64),NULL,NULL,
    (v_material->>'publicationRevisionCount')::bigint,
    (v_material->>'publicationRevisionSetDigest')::char(64),
    (v_material->>'openPublicationRevisionCount')::bigint,
    (v_material->>'legalHoldCoverageDigest')::char(64),
    (v_payload->>'reasonDigest')::char(64),
    (v_payload->>'capabilityAuthorityDigest')::char(64),
    v_actor_id,v_session_id,v_closure_assertion,
    (v_payload->>'actorAssertionRequestDigest')::char(64),
    '6d390000-0000-4000-8000-000000000205',
    (v_payload->>'stepUpReceiptDigest')::char(64),v_closure_request_id,
    (v_payload->>'idempotencyKeySha256')::char(64),
    (v_payload->>'requestDigest')::char(64),v_audit,v_outbox,v_payload,
    v_canonical,v_digest,v_closure_at,v_closure_at
  );

  PERFORM set_config('gurine.r6d_entity_closure','1',true);
  UPDATE core.agencies
  SET r6d_closure_receipt_id=v_closure_id,
      r6d_closure_receipt_digest=v_digest
  WHERE id=v_entity_id;
  PERFORM set_config('gurine.r6d_entity_closure','',true);
END
$d1_historical_authority_graph$;

-- The terminal owner must scrub an already materialized public projection in
-- the same transaction as the core entity.  This row is intentionally present
-- before execution so a missing projection update cannot pass vacuously.
INSERT INTO public.agencies(
  id,name,agency_type,jurisdiction,coverage,descriptive_metrics,case_counts,
  updated_at
) VALUES(
  '6d390000-0000-4000-8000-000000000002',
  'TEST_ONLY 공개 역사 자연인 성명','OTHER','KR-11 TEST_ONLY 공개 주소',
  '{}'::jsonb,'{}'::jsonb,'{}'::jsonb,'2010-01-01 00:00:00+00'
);

INSERT INTO r6d39_entity_direct_spoof_boundary(operation,before_row)
SELECT operation,to_jsonb(agency)
FROM core.agencies AS agency
CROSS JOIN unnest(ARRAY[
  'INGEST_GUC_CLOSURE','WRONG_ENTITY_CLOSURE'
]) AS attempted(operation)
WHERE agency.id='6d390000-0000-4000-8000-000000000002';

SET LOCAL ROLE gurine_ingest_worker;
SELECT set_config('gurine.r6d_entity_closure','1',true);
DO $d1_ingest_guc_closure_spoof$
BEGIN
  UPDATE core.agencies
  SET r6d_closure_receipt_id='00000000-0000-0000-0000-000000000001',
      r6d_closure_receipt_digest=repeat('a',64)
  WHERE id='6d390000-0000-4000-8000-000000000002';
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_entity_direct_spoof_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='INGEST_GUC_CLOSURE';
END
$d1_ingest_guc_closure_spoof$;
SELECT set_config('gurine.r6d_entity_closure','',true);
RESET ROLE;

SELECT set_config('gurine.r6d_entity_closure','1',true);
DO $d1_wrong_entity_closure_receipt$
DECLARE
  v_receipt_id uuid;
  v_receipt_digest char(64);
BEGIN
  SELECT (payload->>'closureReceiptId')::uuid,
    (payload->>'receiptDigest')::char(64)
  INTO STRICT v_receipt_id,v_receipt_digest
  FROM r6d39_entity_authority_results
  WHERE operation='CLOSE';
  UPDATE core.agencies
  SET r6d_closure_receipt_id=v_receipt_id,
      r6d_closure_receipt_digest=v_receipt_digest
  WHERE id='6d390000-0000-4000-8000-000000000002';
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_entity_direct_spoof_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='WRONG_ENTITY_CLOSURE';
END
$d1_wrong_entity_closure_receipt$;
SELECT set_config('gurine.r6d_entity_closure','',true);

UPDATE r6d39_entity_direct_spoof_boundary AS boundary
SET after_row=to_jsonb(agency)
FROM core.agencies AS agency
WHERE agency.id='6d390000-0000-4000-8000-000000000002'
  AND boundary.operation IN (
    'INGEST_GUC_CLOSURE','WRONG_ENTITY_CLOSURE'
  );

DO $d1_direct_closure_spoof_zero_write$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (SELECT rejected AND error_state='42501'
       AND error_message='permission denied for table agencies'
     FROM r6d39_entity_direct_spoof_boundary
     WHERE operation='INGEST_GUC_CLOSURE')
    AND (SELECT rejected AND error_state='55000'
           AND error_message='r6d_entity_closure_transition_invalid'
         FROM r6d39_entity_direct_spoof_boundary
         WHERE operation='WRONG_ENTITY_CLOSURE')
    AND (SELECT bool_and(before_row=after_row)
         FROM r6d39_entity_direct_spoof_boundary
         WHERE operation IN (
           'INGEST_GUC_CLOSURE','WRONG_ENTITY_CLOSURE'
         )),
    'entity-direct-closure-spoof-wrote-state'
  );
END
$d1_direct_closure_spoof_zero_write$;

CREATE TEMP TABLE r6d39_historical_enqueue(payload jsonb) ON COMMIT DROP;
GRANT INSERT,SELECT ON r6d39_historical_enqueue TO gurine_scheduler;
SET LOCAL ROLE gurine_scheduler;
INSERT INTO r6d39_historical_enqueue(payload)
SELECT ops.enqueue_due_r6d_entity_retention_jobs_v1(100);
RESET ROLE;

DO $d1_historical_enqueue_result$
DECLARE
  v_job ops.jobs%ROWTYPE;
  v_closure ops.r6d_entity_material_use_closure_receipts_v1%ROWTYPE;
  v_schedule ops.record_class_schedules%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_job FROM ops.jobs
  WHERE job_type='R6D_ENTITY_RETENTION'
    AND payload->>'entityId'='6d390000-0000-4000-8000-000000000002';
  SELECT * INTO STRICT v_closure
  FROM ops.r6d_entity_material_use_closure_receipts_v1
  WHERE entity_id='6d390000-0000-4000-8000-000000000002';
  SELECT * INTO STRICT v_schedule FROM ops.record_class_schedules
  WHERE id=(v_job.payload->>'scheduleId')::uuid;
  PERFORM pg_temp.r6d39_assert(
    (SELECT payload->>'enqueuedCount'='1'
     FROM r6d39_historical_enqueue)
    AND (SELECT jsonb_array_length(payload->'jobIds')=1
         FROM r6d39_historical_enqueue)
    AND (SELECT count(*) FROM jsonb_object_keys(v_job.payload))=15
    AND v_job.payload->>'schemaVersion'='r6d-entity-retention-job.v1'
    AND (v_job.payload->>'dueAt')::timestamptz=
      v_closure.closure_at+make_interval(secs=>157680000)
    AND v_schedule.active_duration_seconds=157680000
    AND v_schedule.backup_duration_seconds=31536000,
    'historical-entity-enqueue-binding'
  );
END
$d1_historical_enqueue_result$;

CREATE TEMP TABLE r6d39_entity_worker_boundary(
  operation text PRIMARY KEY,
  rejected boolean NOT NULL DEFAULT false,
  error_state text,
  error_message text
) ON COMMIT DROP;
INSERT INTO r6d39_entity_worker_boundary(operation) VALUES
  ('STALE_LEASE'),('STALE_FENCE');
GRANT SELECT,UPDATE ON r6d39_entity_worker_boundary
  TO gurine_workflow_worker;

UPDATE ops.jobs
SET status='RUNNING',lease_owner='r6d-runtime-worker',
    lease_token='6d390000-0000-4000-8000-000000000208',
    lease_expires_at=clock_timestamp()+interval '1 hour',
    fencing_token=7,attempt_count=1
WHERE job_type='R6D_ENTITY_RETENTION'
  AND payload->>'entityId'='6d390000-0000-4000-8000-000000000002';

SET LOCAL ROLE gurine_workflow_worker;
DO $d1_stale_lease$
DECLARE
  v_job_id uuid;
BEGIN
  SELECT id INTO STRICT v_job_id FROM ops.jobs
  WHERE job_type='R6D_ENTITY_RETENTION'
    AND payload->>'entityId'='6d390000-0000-4000-8000-000000000002';
  PERFORM ops.execute_due_r6d_entity_retention_job_v1(
    v_job_id,'6d390000-0000-4000-8000-000000000209',7
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_entity_worker_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='STALE_LEASE';
END
$d1_stale_lease$;

DO $d1_stale_fence$
DECLARE
  v_job_id uuid;
BEGIN
  SELECT id INTO STRICT v_job_id FROM ops.jobs
  WHERE job_type='R6D_ENTITY_RETENTION'
    AND payload->>'entityId'='6d390000-0000-4000-8000-000000000002';
  PERFORM ops.execute_due_r6d_entity_retention_job_v1(
    v_job_id,'6d390000-0000-4000-8000-000000000208',8
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_entity_worker_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='STALE_FENCE';
END
$d1_stale_fence$;
RESET ROLE;

DO $d1_stale_worker_zero_write$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (SELECT rejected AND error_state='40001'
       AND error_message='r6d_entity_retention_job_lease_stale'
     FROM r6d39_entity_worker_boundary WHERE operation='STALE_LEASE')
    AND (SELECT rejected AND error_state='40001'
           AND error_message='r6d_entity_retention_job_lease_stale'
         FROM r6d39_entity_worker_boundary WHERE operation='STALE_FENCE')
    AND NOT EXISTS(
      SELECT 1 FROM ops.r6d_entity_retention_execution_receipts_v1
      WHERE entity_id='6d390000-0000-4000-8000-000000000002'
    )
    AND EXISTS(
      SELECT 1 FROM core.agencies
      WHERE id='6d390000-0000-4000-8000-000000000002'
        AND canonical_name='TEST_ONLY 역사 자연인 성명'
        AND jurisdiction='KR-11 TEST_ONLY 주소'
        AND r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
    ),
    'stale-entity-worker-wrote-state'
  );
END
$d1_stale_worker_zero_write$;

CREATE TEMP TABLE r6d39_entity_worker_results(
  operation text PRIMARY KEY,
  payload jsonb NOT NULL
) ON COMMIT DROP;
GRANT INSERT,SELECT ON r6d39_entity_worker_results
  TO gurine_workflow_worker;

SET LOCAL ROLE gurine_workflow_worker;
INSERT INTO r6d39_entity_worker_results(operation,payload)
SELECT 'EXECUTE',ops.execute_due_r6d_entity_retention_job_v1(
  job.id,'6d390000-0000-4000-8000-000000000208',7
)
FROM ops.jobs AS job
WHERE job.job_type='R6D_ENTITY_RETENTION'
  AND job.payload->>'entityId'='6d390000-0000-4000-8000-000000000002';

INSERT INTO r6d39_entity_worker_results(operation,payload)
SELECT 'REPLAY',ops.execute_due_r6d_entity_retention_job_v1(
  job.id,'6d390000-0000-4000-8000-000000000208',7
)
FROM ops.jobs AS job
WHERE job.job_type='R6D_ENTITY_RETENTION'
  AND job.payload->>'entityId'='6d390000-0000-4000-8000-000000000002';
RESET ROLE;

DO $d1_entity_worker_result$
DECLARE
  v_execute jsonb;
  v_replay jsonb;
  v_receipt ops.r6d_entity_retention_execution_receipts_v1%ROWTYPE;
BEGIN
  SELECT payload INTO STRICT v_execute
  FROM r6d39_entity_worker_results WHERE operation='EXECUTE';
  SELECT payload INTO STRICT v_replay
  FROM r6d39_entity_worker_results WHERE operation='REPLAY';
  SELECT * INTO STRICT v_receipt
  FROM ops.r6d_entity_retention_execution_receipts_v1
  WHERE entity_id='6d390000-0000-4000-8000-000000000002';

  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*) FROM jsonb_object_keys(v_execute))=15
    AND (SELECT count(*) FROM jsonb_object_keys(v_replay))=15
    AND NOT (v_execute->>'replayed')::boolean
    AND (v_replay->>'replayed')::boolean
    AND v_execute-'replayed'=v_replay-'replayed'
    AND (v_execute->>'executionReceiptId')::uuid=
      v_receipt.execution_receipt_id
    AND v_execute->>'executionReceiptDigest'=
      btrim(v_receipt.execution_receipt_digest)
    AND v_receipt.receipt_canonical=ops.canonical_jsonb_v1(
      v_receipt.receipt_payload
    )
    AND v_receipt.execution_receipt_digest=encode(extensions.digest(
      v_receipt.receipt_canonical,'sha256'
    ),'hex')
    AND v_receipt.due_at=v_receipt.closure_at+
      make_interval(secs=>157680000)
    AND v_receipt.backup_disposal_due_at=
      v_receipt.anonymized_at+make_interval(secs=>31536000),
    'entity-worker-result-or-replay-binding'
  );
  PERFORM pg_temp.r6d39_assert(
    EXISTS(
      SELECT 1 FROM core.agencies AS agency
      WHERE agency.id='6d390000-0000-4000-8000-000000000002'
        AND agency.canonical_name IS NULL AND agency.jurisdiction IS NULL
        AND agency.r6d_anonymization_state='ANONYMIZED'
        AND btrim(agency.r6d_canonical_name_digest)=
          btrim(pg_temp.r6d39_sha256_text('TEST_ONLY 역사 자연인 성명'))
        AND btrim(agency.r6d_jurisdiction_digest)=
          btrim(pg_temp.r6d39_sha256_text('KR-11 TEST_ONLY 주소'))
        AND agency.r6d_anonymization_receipt_digest=
          v_receipt.execution_receipt_digest
    )
    AND EXISTS(
      SELECT 1 FROM core.agency_identifiers AS identifier
      WHERE identifier.id='6d390000-0000-4000-8000-000000000011'
        AND identifier.value IS NULL
        AND identifier.r6d_anonymization_state='ANONYMIZED'
        AND btrim(identifier.r6d_value_digest)=btrim(
          pg_temp.r6d39_sha256_text('TEST-ANONYMIZE-0002')
        )
        AND identifier.r6d_anonymization_receipt_digest=
          v_receipt.execution_receipt_digest
    )
    AND EXISTS(
      SELECT 1 FROM core.entity_aliases AS alias
      WHERE alias.id='6d390000-0000-4000-8000-000000000013'
        AND alias.alias IS NULL AND alias.normalized_alias IS NULL
        AND alias.r6d_anonymization_state='ANONYMIZED'
        AND btrim(alias.r6d_alias_digest)=btrim(
          pg_temp.r6d39_sha256_text('TEST_ONLY 삭제 대상 별칭')
        )
        AND btrim(alias.r6d_normalized_alias_digest)=btrim(
          pg_temp.r6d39_sha256_text('test only 삭제 대상 별칭')
        )
        AND alias.r6d_anonymization_receipt_digest=
          v_receipt.execution_receipt_digest
    )
    AND EXISTS(
      SELECT 1 FROM public.agencies AS agency
      WHERE agency.id='6d390000-0000-4000-8000-000000000002'
        AND agency.name IS NULL AND agency.jurisdiction IS NULL
    ),
    'entity-worker-plaintext-digest-and-public-projection-contract'
  );
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*)=1
     FROM ops.r6d_entity_retention_execution_receipts_v1
     WHERE entity_id='6d390000-0000-4000-8000-000000000002')
    AND (SELECT count(*)=1 FROM ops.audit_events
         WHERE id=v_receipt.audit_event_id)
    AND (SELECT count(*)=1 FROM ops.outbox
         WHERE id=v_receipt.outbox_event_id
           AND event_type='entity.retention_anonymized.v1'),
    'entity-worker-replay-appended-duplicate'
  );
END
$d1_entity_worker_result$;

CREATE TEMP TABLE r6d39_public_entity_guard_boundary(
  operation text PRIMARY KEY,
  rejected boolean NOT NULL DEFAULT false,
  error_state text,
  error_message text
) ON COMMIT DROP;
INSERT INTO r6d39_public_entity_guard_boundary(operation) VALUES
  ('RESTORE'),('DELETE'),('PRIMARY_KEY'),('WRONG_AUTHORITY');

DO $d1_public_agency_restore_guard$
BEGIN
  UPDATE public.agencies
  SET name='TEST_ONLY 복원 금지 성명'
  WHERE id='6d390000-0000-4000-8000-000000000002';
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_public_entity_guard_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='RESTORE';
END
$d1_public_agency_restore_guard$;

DO $d1_public_agency_delete_guard$
BEGIN
  DELETE FROM public.agencies
  WHERE id='6d390000-0000-4000-8000-000000000002';
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_public_entity_guard_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='DELETE';
END
$d1_public_agency_delete_guard$;

DO $d1_public_agency_primary_key_guard$
BEGIN
  UPDATE public.agencies
  SET id='6d390000-0000-4000-8000-0000000002ff'
  WHERE id='6d390000-0000-4000-8000-000000000002';
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_public_entity_guard_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='PRIMARY_KEY';
END
$d1_public_agency_primary_key_guard$;

-- A synthetic ANONYMIZED master with no matching immutable execution receipt
-- is valid only as a negative fixture root.  Replica mode bypasses the receipt
-- FKs and authority trigger for this one rolled-back INSERT; the public guard
-- itself remains enabled and must reject the projection write.
SET LOCAL session_replication_role='replica';
INSERT INTO core.agencies(
  id,canonical_name,agency_type,jurisdiction,active,identity_status,
  created_at,updated_at,r6d_canonical_name_digest,
  r6d_jurisdiction_digest,r6d_anonymization_state,
  r6d_personhood_receipt_id,r6d_personhood_receipt_digest,
  r6d_closure_receipt_id,r6d_closure_receipt_digest,r6d_anonymized_at,
  r6d_anonymization_receipt_digest
) VALUES(
  '6d390000-0000-4000-8000-0000000002fe',NULL,'OTHER',NULL,true,
  'VERIFIED','2000-01-01 00:00:00+00','2000-01-01 00:00:00+00',
  repeat('1',64),repeat('2',64),'ANONYMIZED',
  '6d390000-0000-4000-8000-0000000002f1',repeat('3',64),
  '6d390000-0000-4000-8000-0000000002f2',repeat('4',64),
  '2000-01-02 00:00:00+00',repeat('5',64)
);
SET LOCAL session_replication_role='origin';

DO $d1_public_agency_wrong_authority_guard$
BEGIN
  INSERT INTO public.agencies(
    id,name,agency_type,jurisdiction,coverage,descriptive_metrics,case_counts,
    updated_at
  ) VALUES(
    '6d390000-0000-4000-8000-0000000002fe','TEST_ONLY 권위 없는 공개 성명',
    'OTHER','KR-11 TEST_ONLY 권위 없는 주소','{}'::jsonb,'{}'::jsonb,
    '{}'::jsonb,clock_timestamp()
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_public_entity_guard_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='WRONG_AUTHORITY';
END
$d1_public_agency_wrong_authority_guard$;

DO $d1_public_entity_guard_result$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (SELECT rejected AND error_state='42501'
       AND error_message='r6d_public_entity_plaintext_restore_forbidden'
     FROM r6d39_public_entity_guard_boundary WHERE operation='RESTORE')
    AND (SELECT rejected AND error_state='42501'
           AND error_message='r6d_public_entity_delete_forbidden'
         FROM r6d39_public_entity_guard_boundary WHERE operation='DELETE')
    AND (SELECT rejected AND error_state='42501'
           AND error_message='r6d_public_entity_identity_mutation_forbidden'
         FROM r6d39_public_entity_guard_boundary
         WHERE operation='PRIMARY_KEY')
    AND (SELECT rejected AND error_state='55000'
           AND error_message=
             'r6d_public_entity_anonymization_authority_invalid'
         FROM r6d39_public_entity_guard_boundary
         WHERE operation='WRONG_AUTHORITY')
    AND EXISTS(
      SELECT 1 FROM public.agencies
      WHERE id='6d390000-0000-4000-8000-000000000002'
        AND name IS NULL AND jurisdiction IS NULL
    )
    AND NOT EXISTS(
      SELECT 1 FROM public.agencies
      WHERE id='6d390000-0000-4000-8000-0000000002fe'
    ),
    'public-entity-projection-guard-boundary'
  );
END
$d1_public_entity_guard_result$;

-- Build a second, fully constrained historical authority chain for SUPPLIER.
-- It is separate from the AGENCY chain so both entity-kind branches of the
-- terminal owner and the public plaintext guard execute with real receipts.
INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
) VALUES
  (
    '6d390000-0000-4000-8000-000000000314',
    '6d390000-0000-4000-8000-000000000023',
    pg_temp.r6d39_sha256_text('historical-supplier-personhood-action'),
    pg_temp.r6d39_sha256_text('historical-supplier-personhood-idempotency'),
    pg_temp.r6d39_sha256_text('historical-supplier-personhood-token'),
    clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  ),
  (
    '6d390000-0000-4000-8000-000000000315',
    '6d390000-0000-4000-8000-000000000023',
    pg_temp.r6d39_sha256_text('historical-supplier-closure-action'),
    pg_temp.r6d39_sha256_text('historical-supplier-closure-idempotency'),
    pg_temp.r6d39_sha256_text('historical-supplier-closure-token'),
    clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  );

DO $d1_supplier_historical_authority_graph$
DECLARE
  v_entity_id constant uuid:='6d390000-0000-4000-8000-000000000300';
  v_actor_id constant uuid:='6d390000-0000-4000-8000-000000000020';
  v_session_id constant uuid:='6d390000-0000-4000-8000-000000000023';
  v_personhood_id constant uuid:='6d390000-0000-4000-8000-000000000310';
  v_closure_id constant uuid:='6d390000-0000-4000-8000-000000000311';
  v_personhood_request_id constant uuid:=
    '6d390000-0000-4000-8000-000000000316';
  v_closure_request_id constant uuid:=
    '6d390000-0000-4000-8000-000000000317';
  v_personhood_assertion constant uuid:=
    '6d390000-0000-4000-8000-000000000312';
  v_closure_assertion constant uuid:=
    '6d390000-0000-4000-8000-000000000313';
  v_entity_updated_at timestamptz;
  v_classified_at timestamptz:=
    clock_timestamp()-make_interval(secs=>157680000)-interval '3 days';
  v_closure_at timestamptz:=
    clock_timestamp()-make_interval(secs=>157680000)-interval '2 days';
  v_material jsonb;
  v_payload jsonb;
  v_canonical bytea;
  v_digest char(64);
  v_personhood_digest char(64);
  v_audit uuid;
  v_outbox uuid;
BEGIN
  SELECT updated_at INTO STRICT v_entity_updated_at
  FROM core.suppliers WHERE id=v_entity_id;

  v_audit:=ops.append_audit_event(
    'r6d-entity-personhood:supplier:'||v_entity_id::text,
    'USER',v_actor_id::text,v_session_id,
    'r6d.entity_personhood.classify','Entity',v_entity_id::text,
    'users.manage','SUCCESS','TEST_ONLY_HISTORICAL_AUTHORITY',
    v_personhood_request_id,jsonb_build_object(
      'fixture','r6d-authority-closure-runtime',
      'classification','NATURAL_PERSON','entityKind','SUPPLIER'
    )
  );
  v_payload:=jsonb_build_object(
    'schemaVersion','r6d-entity-personhood-classification-receipt.v1',
    'receiptId',v_personhood_id,'entityKind','SUPPLIER',
    'entityId',v_entity_id,'classification','NATURAL_PERSON',
    'classificationVersion',1,'entityUpdatedAt',v_entity_updated_at,
    'evidenceSourceLocatorDigest',pg_temp.r6d39_sha256_text(
      'test-only/r6d39-historical-supplier-registration#public-form'
    ),
    'reasonDigest',pg_temp.r6d39_sha256_text(
      'TEST_ONLY historical supplier human classification'
    ),
    'capabilityAuthorityDigest',pg_temp.r6d39_sha256_text(
      'TEST_ONLY users.manage authority'
    ),
    'actorId',v_actor_id,'sessionId',v_session_id,
    'actorAssertionJti',v_personhood_assertion,
    'actorAssertionRequestDigest',pg_temp.r6d39_sha256_text(
      'historical-supplier-personhood-assertion-request'
    ),
    'stepUpAuthorizationId','6d390000-0000-4000-8000-000000000314'::uuid,
    'stepUpReceiptDigest',pg_temp.r6d39_sha256_text(
      'historical-supplier-personhood-step-up-receipt'
    ),
    'requestId',v_personhood_request_id,
    'idempotencyKeySha256',pg_temp.r6d39_sha256_text(
      'historical-supplier-personhood-idempotency'
    ),
    'requestDigest',pg_temp.r6d39_sha256_text(
      'historical-supplier-personhood-request'
    ),
    'auditEventId',v_audit,'classifiedAt',v_classified_at
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_digest:=encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_personhood_digest:=v_digest;
  v_outbox:=ops.enqueue_outbox(
    'r6d_entity_personhood',v_personhood_id::text,1,
    'entity.personhood_classified.v1',jsonb_build_object(
      'entityKind','SUPPLIER','entityId',v_entity_id,
      'classification','NATURAL_PERSON',
      'evidenceSourceLocatorDigest',
        v_payload->>'evidenceSourceLocatorDigest',
      'receiptDigest',btrim(v_digest),'classifiedAt',v_classified_at
    ),v_classified_at
  );
  INSERT INTO ops.r6d_entity_personhood_classification_receipts_v1(
    receipt_id,entity_kind,entity_id,classification,
    classification_version,entity_updated_at,
    evidence_source_locator_digest,reason_digest,
    capability_authority_digest,actor_id,session_id,actor_assertion_jti,
    actor_assertion_request_digest,step_up_authorization_id,
    step_up_receipt_digest,request_id,idempotency_key_sha256,
    request_digest,audit_event_id,outbox_event_id,receipt_payload,
    receipt_canonical,receipt_digest,classified_at
  ) VALUES(
    v_personhood_id,'SUPPLIER',v_entity_id,'NATURAL_PERSON',1,
    v_entity_updated_at,
    (v_payload->>'evidenceSourceLocatorDigest')::char(64),
    (v_payload->>'reasonDigest')::char(64),
    (v_payload->>'capabilityAuthorityDigest')::char(64),
    v_actor_id,v_session_id,v_personhood_assertion,
    (v_payload->>'actorAssertionRequestDigest')::char(64),
    '6d390000-0000-4000-8000-000000000314',
    (v_payload->>'stepUpReceiptDigest')::char(64),v_personhood_request_id,
    (v_payload->>'idempotencyKeySha256')::char(64),
    (v_payload->>'requestDigest')::char(64),v_audit,v_outbox,v_payload,
    v_canonical,v_digest,v_classified_at
  );

  PERFORM set_config('gurine.r6d_entity_classification','1',true);
  UPDATE core.suppliers
  SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
      r6d_canonical_name_digest=pg_temp.r6d39_sha256_text(canonical_name),
      r6d_personhood_receipt_id=v_personhood_id,
      r6d_personhood_receipt_digest=v_personhood_digest
  WHERE id=v_entity_id;
  UPDATE core.supplier_identifiers
  SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
      r6d_display_value_digest=CASE WHEN display_value IS NULL THEN NULL
        ELSE pg_temp.r6d39_sha256_text(display_value) END
  WHERE supplier_id=v_entity_id;
  UPDATE core.entity_aliases
  SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
      r6d_alias_digest=pg_temp.r6d39_sha256_text(alias),
      r6d_normalized_alias_digest=pg_temp.r6d39_sha256_text(normalized_alias)
  WHERE entity_type='SUPPLIER' AND entity_id=v_entity_id;
  PERFORM set_config('gurine.r6d_entity_classification','',true);

  SELECT updated_at INTO STRICT v_entity_updated_at
  FROM core.suppliers WHERE id=v_entity_id;
  v_material:=ops.r6d_entity_material_use_state_v1(
    'SUPPLIER',v_entity_id,clock_timestamp()
  );
  PERFORM pg_temp.r6d39_assert(
    (v_material->>'contractCount')::bigint=0
    AND (v_material->>'publicationRevisionCount')::bigint=0
    AND (v_material->>'openPublicationRevisionCount')::bigint=0
    AND NOT (v_material->>'legalHoldActive')::boolean,
    'historical-supplier-material-use-not-closed'
  );
  v_audit:=ops.append_audit_event(
    'r6d-entity-closure:supplier:'||v_entity_id::text,
    'USER',v_actor_id::text,v_session_id,
    'r6d.entity_material_use.close','Entity',v_entity_id::text,
    'users.manage','SUCCESS','TEST_ONLY_HISTORICAL_AUTHORITY',
    v_closure_request_id,jsonb_build_object(
      'fixture','r6d-authority-closure-runtime',
      'personhoodReceiptId',v_personhood_id,'entityKind','SUPPLIER'
    )
  );
  v_payload:=jsonb_build_object(
    'schemaVersion','r6d-entity-material-use-closure-receipt.v1',
    'receiptId',v_closure_id,'entityKind','SUPPLIER','entityId',v_entity_id,
    'closureVersion',1,'entityUpdatedAt',v_entity_updated_at,
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
    'reasonDigest',pg_temp.r6d39_sha256_text(
      'TEST_ONLY historical supplier material-use closure'
    ),
    'capabilityAuthorityDigest',pg_temp.r6d39_sha256_text(
      'TEST_ONLY users.manage authority'
    ),
    'actorId',v_actor_id,'sessionId',v_session_id,
    'actorAssertionJti',v_closure_assertion,
    'actorAssertionRequestDigest',pg_temp.r6d39_sha256_text(
      'historical-supplier-closure-assertion-request'
    ),
    'stepUpAuthorizationId','6d390000-0000-4000-8000-000000000315'::uuid,
    'stepUpReceiptDigest',pg_temp.r6d39_sha256_text(
      'historical-supplier-closure-step-up-receipt'
    ),
    'requestId',v_closure_request_id,
    'idempotencyKeySha256',pg_temp.r6d39_sha256_text(
      'historical-supplier-closure-idempotency'
    ),
    'requestDigest',pg_temp.r6d39_sha256_text(
      'historical-supplier-closure-request'
    ),
    'auditEventId',v_audit,'closureAt',v_closure_at,
    'attestedAt',v_closure_at
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_digest:=encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_outbox:=ops.enqueue_outbox(
    'r6d_entity_material_use',v_closure_id::text,1,
    'entity.material_use_closed.v1',jsonb_build_object(
      'entityKind','SUPPLIER','entityId',v_entity_id,
      'personhoodReceiptDigest',btrim(v_personhood_digest),
      'closureAt',v_closure_at,'lastContractEndAt',NULL,
      'linkedPublicationRevisionCount',0,
      'receiptDigest',btrim(v_digest)
    ),v_closure_at
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
    v_closure_id,'SUPPLIER',v_entity_id,1,v_entity_updated_at,
    v_personhood_id,v_personhood_digest,
    (v_material->>'contractCount')::bigint,
    (v_material->>'contractSetDigest')::char(64),NULL,NULL,
    (v_material->>'publicationRevisionCount')::bigint,
    (v_material->>'publicationRevisionSetDigest')::char(64),
    (v_material->>'openPublicationRevisionCount')::bigint,
    (v_material->>'legalHoldCoverageDigest')::char(64),
    (v_payload->>'reasonDigest')::char(64),
    (v_payload->>'capabilityAuthorityDigest')::char(64),
    v_actor_id,v_session_id,v_closure_assertion,
    (v_payload->>'actorAssertionRequestDigest')::char(64),
    '6d390000-0000-4000-8000-000000000315',
    (v_payload->>'stepUpReceiptDigest')::char(64),v_closure_request_id,
    (v_payload->>'idempotencyKeySha256')::char(64),
    (v_payload->>'requestDigest')::char(64),v_audit,v_outbox,v_payload,
    v_canonical,v_digest,v_closure_at,v_closure_at
  );

  PERFORM set_config('gurine.r6d_entity_closure','1',true);
  UPDATE core.suppliers
  SET r6d_closure_receipt_id=v_closure_id,
      r6d_closure_receipt_digest=v_digest
  WHERE id=v_entity_id;
  PERFORM set_config('gurine.r6d_entity_closure','',true);
END
$d1_supplier_historical_authority_graph$;

INSERT INTO public.suppliers(
  id,name,business_status,coverage,descriptive_metrics,case_counts,
  identity_warnings,updated_at
) VALUES(
  '6d390000-0000-4000-8000-000000000300',
  'TEST_ONLY 공개 역사 자연인 공급자 성명','ACTIVE','{}'::jsonb,
  '{}'::jsonb,'{}'::jsonb,'[]'::jsonb,'2010-01-01 00:00:00+00'
);

CREATE TEMP TABLE r6d39_supplier_enqueue(payload jsonb) ON COMMIT DROP;
GRANT INSERT,SELECT ON r6d39_supplier_enqueue TO gurine_scheduler;
SET LOCAL ROLE gurine_scheduler;
INSERT INTO r6d39_supplier_enqueue(payload)
SELECT ops.enqueue_due_r6d_entity_retention_jobs_v1(100);
RESET ROLE;

DO $d1_supplier_enqueue_result$
DECLARE
  v_job ops.jobs%ROWTYPE;
  v_closure ops.r6d_entity_material_use_closure_receipts_v1%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_job FROM ops.jobs
  WHERE job_type='R6D_ENTITY_RETENTION'
    AND payload->>'entityId'='6d390000-0000-4000-8000-000000000300';
  SELECT * INTO STRICT v_closure
  FROM ops.r6d_entity_material_use_closure_receipts_v1
  WHERE entity_kind='SUPPLIER'
    AND entity_id='6d390000-0000-4000-8000-000000000300';
  PERFORM pg_temp.r6d39_assert(
    (SELECT payload->>'enqueuedCount'='1' FROM r6d39_supplier_enqueue)
    AND (SELECT jsonb_array_length(payload->'jobIds')=1
         FROM r6d39_supplier_enqueue)
    AND v_job.payload->>'entityKind'='SUPPLIER'
    AND (v_job.payload->>'dueAt')::timestamptz=
      v_closure.closure_at+make_interval(secs=>157680000),
    'historical-supplier-enqueue-binding'
  );
END
$d1_supplier_enqueue_result$;

UPDATE ops.jobs
SET status='RUNNING',lease_owner='r6d-runtime-supplier-worker',
    lease_token='6d390000-0000-4000-8000-000000000318',
    lease_expires_at=clock_timestamp()+interval '1 hour',
    fencing_token=9,attempt_count=1
WHERE job_type='R6D_ENTITY_RETENTION'
  AND payload->>'entityId'='6d390000-0000-4000-8000-000000000300';

CREATE TEMP TABLE r6d39_supplier_worker_results(
  operation text PRIMARY KEY,
  payload jsonb NOT NULL
) ON COMMIT DROP;
GRANT INSERT,SELECT ON r6d39_supplier_worker_results
  TO gurine_workflow_worker;
SET LOCAL ROLE gurine_workflow_worker;
INSERT INTO r6d39_supplier_worker_results(operation,payload)
SELECT 'EXECUTE',ops.execute_due_r6d_entity_retention_job_v1(
  job.id,'6d390000-0000-4000-8000-000000000318',9
)
FROM ops.jobs AS job
WHERE job.job_type='R6D_ENTITY_RETENTION'
  AND job.payload->>'entityId'='6d390000-0000-4000-8000-000000000300';
INSERT INTO r6d39_supplier_worker_results(operation,payload)
SELECT 'REPLAY',ops.execute_due_r6d_entity_retention_job_v1(
  job.id,'6d390000-0000-4000-8000-000000000318',9
)
FROM ops.jobs AS job
WHERE job.job_type='R6D_ENTITY_RETENTION'
  AND job.payload->>'entityId'='6d390000-0000-4000-8000-000000000300';
RESET ROLE;

DO $d1_supplier_worker_result$
DECLARE
  v_execute jsonb;
  v_replay jsonb;
  v_receipt ops.r6d_entity_retention_execution_receipts_v1%ROWTYPE;
BEGIN
  SELECT payload INTO STRICT v_execute
  FROM r6d39_supplier_worker_results WHERE operation='EXECUTE';
  SELECT payload INTO STRICT v_replay
  FROM r6d39_supplier_worker_results WHERE operation='REPLAY';
  SELECT * INTO STRICT v_receipt
  FROM ops.r6d_entity_retention_execution_receipts_v1
  WHERE entity_kind='SUPPLIER'
    AND entity_id='6d390000-0000-4000-8000-000000000300';
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*) FROM jsonb_object_keys(v_execute))=15
    AND (SELECT count(*) FROM jsonb_object_keys(v_replay))=15
    AND NOT (v_execute->>'replayed')::boolean
    AND (v_replay->>'replayed')::boolean
    AND v_execute-'replayed'=v_replay-'replayed'
    AND EXISTS(
      SELECT 1 FROM core.suppliers AS supplier
      WHERE supplier.id='6d390000-0000-4000-8000-000000000300'
        AND supplier.canonical_name IS NULL
        AND supplier.r6d_anonymization_state='ANONYMIZED'
        AND btrim(supplier.r6d_canonical_name_digest)=btrim(
          pg_temp.r6d39_sha256_text(
            'TEST_ONLY 역사 자연인 공급자 성명'
          )
        )
        AND supplier.r6d_anonymization_receipt_digest=
          v_receipt.execution_receipt_digest
    )
    AND EXISTS(
      SELECT 1 FROM core.supplier_identifiers AS identifier
      WHERE identifier.id='6d390000-0000-4000-8000-000000000301'
        AND identifier.display_value IS NULL
        AND btrim(identifier.value_hash)=btrim(
          pg_temp.r6d39_sha256_text('TEST-SUPPLIER-ANONYMIZE-0300')
        )
        AND btrim(identifier.r6d_display_value_digest)=btrim(
          pg_temp.r6d39_sha256_text('TEST-SUPPLIER-ANONYMIZE-0300')
        )
        AND identifier.r6d_anonymization_state='ANONYMIZED'
        AND identifier.r6d_anonymization_receipt_digest=
          v_receipt.execution_receipt_digest
    )
    AND EXISTS(
      SELECT 1 FROM core.entity_aliases AS alias
      WHERE alias.id='6d390000-0000-4000-8000-000000000302'
        AND alias.alias IS NULL AND alias.normalized_alias IS NULL
        AND btrim(alias.r6d_alias_digest)=btrim(
          pg_temp.r6d39_sha256_text('TEST_ONLY 공급자 삭제 대상 별칭')
        )
        AND btrim(alias.r6d_normalized_alias_digest)=btrim(
          pg_temp.r6d39_sha256_text('test only 공급자 삭제 대상 별칭')
        )
        AND alias.r6d_anonymization_state='ANONYMIZED'
        AND alias.r6d_anonymization_receipt_digest=
          v_receipt.execution_receipt_digest
    )
    AND EXISTS(
      SELECT 1 FROM public.suppliers AS supplier
      WHERE supplier.id='6d390000-0000-4000-8000-000000000300'
        AND supplier.name IS NULL
    ),
    'supplier-terminal-plaintext-digest-public-and-replay-contract'
  );
END
$d1_supplier_worker_result$;

INSERT INTO r6d39_public_entity_guard_boundary(operation) VALUES
  ('SUPPLIER_RESTORE'),('SUPPLIER_DELETE'),('SUPPLIER_PRIMARY_KEY'),
  ('SUPPLIER_WRONG_AUTHORITY');

DO $d1_public_supplier_restore_guard$
BEGIN
  UPDATE public.suppliers SET name='TEST_ONLY 복원 금지 공급자 성명'
  WHERE id='6d390000-0000-4000-8000-000000000300';
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_public_entity_guard_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='SUPPLIER_RESTORE';
END
$d1_public_supplier_restore_guard$;
DO $d1_public_supplier_delete_guard$
BEGIN
  DELETE FROM public.suppliers
  WHERE id='6d390000-0000-4000-8000-000000000300';
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_public_entity_guard_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='SUPPLIER_DELETE';
END
$d1_public_supplier_delete_guard$;
DO $d1_public_supplier_primary_key_guard$
BEGIN
  UPDATE public.suppliers
  SET id='6d390000-0000-4000-8000-0000000003ff'
  WHERE id='6d390000-0000-4000-8000-000000000300';
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_public_entity_guard_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='SUPPLIER_PRIMARY_KEY';
END
$d1_public_supplier_primary_key_guard$;

SET LOCAL session_replication_role='replica';
INSERT INTO core.suppliers(
  id,canonical_name,business_status,identity_status,created_at,updated_at,
  r6d_canonical_name_digest,r6d_anonymization_state,
  r6d_personhood_receipt_id,r6d_personhood_receipt_digest,
  r6d_closure_receipt_id,r6d_closure_receipt_digest,r6d_anonymized_at,
  r6d_anonymization_receipt_digest
) VALUES(
  '6d390000-0000-4000-8000-0000000003fe',NULL,'ACTIVE','VERIFIED',
  '2000-01-01 00:00:00+00','2000-01-01 00:00:00+00',repeat('1',64),
  'ANONYMIZED','6d390000-0000-4000-8000-0000000003f1',repeat('2',64),
  '6d390000-0000-4000-8000-0000000003f2',repeat('3',64),
  '2000-01-02 00:00:00+00',repeat('4',64)
);
SET LOCAL session_replication_role='origin';
DO $d1_public_supplier_wrong_authority_guard$
BEGIN
  INSERT INTO public.suppliers(
    id,name,business_status,coverage,descriptive_metrics,case_counts,
    identity_warnings,updated_at
  ) VALUES(
    '6d390000-0000-4000-8000-0000000003fe',
    'TEST_ONLY 권위 없는 공개 공급자 성명','ACTIVE','{}'::jsonb,
    '{}'::jsonb,'{}'::jsonb,'[]'::jsonb,clock_timestamp()
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_public_entity_guard_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='SUPPLIER_WRONG_AUTHORITY';
END
$d1_public_supplier_wrong_authority_guard$;

DO $d1_public_supplier_guard_result$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (SELECT rejected AND error_state='42501'
       AND error_message='r6d_public_entity_plaintext_restore_forbidden'
     FROM r6d39_public_entity_guard_boundary
     WHERE operation='SUPPLIER_RESTORE')
    AND (SELECT rejected AND error_state='42501'
           AND error_message='r6d_public_entity_delete_forbidden'
         FROM r6d39_public_entity_guard_boundary
         WHERE operation='SUPPLIER_DELETE')
    AND (SELECT rejected AND error_state='42501'
           AND error_message='r6d_public_entity_identity_mutation_forbidden'
         FROM r6d39_public_entity_guard_boundary
         WHERE operation='SUPPLIER_PRIMARY_KEY')
    AND (SELECT rejected AND error_state='55000'
           AND error_message=
             'r6d_public_entity_anonymization_authority_invalid'
         FROM r6d39_public_entity_guard_boundary
         WHERE operation='SUPPLIER_WRONG_AUTHORITY')
    AND EXISTS(
      SELECT 1 FROM public.suppliers
      WHERE id='6d390000-0000-4000-8000-000000000300' AND name IS NULL
    )
    AND NOT EXISTS(
      SELECT 1 FROM public.suppliers
      WHERE id='6d390000-0000-4000-8000-0000000003fe'
    ),
    'public-supplier-projection-guard-boundary'
  );
END
$d1_public_supplier_guard_result$;

CREATE TEMP TABLE r6d39_backup_due_result(payload jsonb) ON COMMIT DROP;
GRANT INSERT,SELECT ON r6d39_backup_due_result TO gurine_auditor;
SET LOCAL ROLE gurine_auditor;
INSERT INTO r6d39_backup_due_result(payload)
SELECT ops.list_due_r6d_backup_disposals_v1(100);
RESET ROLE;

DO $d1_backup_due_result$
DECLARE
  v_payload jsonb;
  v_definition text:=pg_temp.r6d39_function_definition(
    'ops.list_due_r6d_backup_disposals_v1(integer)'
  );
BEGIN
  SELECT payload INTO STRICT v_payload FROM r6d39_backup_due_result;
  PERFORM pg_temp.r6d39_assert(
    jsonb_typeof(v_payload)='object'
    AND jsonb_typeof(v_payload->'evaluatedAt')='string'
    AND jsonb_typeof(v_payload->'dueCount')='number'
    AND jsonb_typeof(v_payload->'items')='array'
    AND (v_payload->>'dueCount')::bigint=jsonb_array_length(
      v_payload->'items'
    )
    AND position('backup_disposal_due_at,execution_receipt_id' IN
      v_definition)>0
    AND position('executionreceiptid' IN v_definition)>0
    AND position('executionreceiptdigest' IN v_definition)>0
    AND position('scheduleid' IN v_definition)>0
    AND position('scheduledigest' IN v_definition)>0,
    'backup-disposal-due-list-abi'
  );
END
$d1_backup_due_result$;

CREATE TEMP TABLE r6d39_official_channel_assertion_boundary(
  operation text PRIMARY KEY,
  rejected boolean NOT NULL DEFAULT false,
  error_state text,
  error_message text
) ON COMMIT DROP;
INSERT INTO r6d39_official_channel_assertion_boundary(operation) VALUES
  ('ATTEST'),('REVOKE');
GRANT SELECT,UPDATE ON r6d39_official_channel_assertion_boundary
  TO gurine_control_api;

SET LOCAL ROLE gurine_control_api;
DO $attest_assertion_mismatch$
BEGIN
  PERFORM editorial.attest_organization_official_channel_v1(
    jsonb_build_object(
      'organizationKind','AGENCY',
      'organizationId','6d390000-0000-4000-8000-000000000001',
      'verificationMethod','OFFICIAL_DOCUMENT',
      'sourceId','6d390000-0000-4000-8000-000000000032',
      'expiresAt',clock_timestamp()+interval '1 day',
      'reason','TEST_ONLY mismatched request-bound assertion',
      'expectedAuthorityVersion',1,
      '_actorAssertionJti','6d390000-0000-4000-8000-000000000040',
      '_actorAssertionRequestSha256',repeat('e',64),
      '_actorAssuranceLevel','STEP_UP',
      '_actorEffectiveCapability','responses.review',
      '_actorActionDigest',repeat('3',64),
      '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000024',
      '_actorIdempotencyKeySha256',repeat('4',64),
      '_actorRequestKeySha256',repeat('4',64)
    ),
    '6d390000-0000-4000-8000-000000000020',
    '6d390000-0000-4000-8000-000000000023',
    '6d390000-0000-4000-8000-000000000041',repeat('4',64),repeat('a',64)
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_official_channel_assertion_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='ATTEST';
END
$attest_assertion_mismatch$;
RESET ROLE;

DO $attest_assertion_mismatch_zero_write$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (SELECT rejected AND error_state='23514'
       AND error_message='official_channel_actor_assertion_invalid'
     FROM r6d39_official_channel_assertion_boundary
     WHERE operation='ATTEST'),
    'official-channel-attest-assertion-mismatch-error'
  );
  PERFORM pg_temp.r6d39_assert(
    NOT EXISTS(
      SELECT 1
      FROM editorial.organization_official_channel_authority_receipts_v1
      WHERE actor_assertion_jti=
        '6d390000-0000-4000-8000-000000000040'
    )
    AND NOT EXISTS(
      SELECT 1 FROM editorial.organization_official_channel_assertions_v1
      WHERE organization_kind='AGENCY'
        AND organization_id='6d390000-0000-4000-8000-000000000001'
    )
    AND NOT EXISTS(
      SELECT 1 FROM ops.audit_events
      WHERE request_id='6d390000-0000-4000-8000-000000000041'
    )
    AND (SELECT response_body IS NULL
         FROM ops.idempotency_keys
         WHERE scope=
           'control:6d390000-0000-4000-8000-000000000020:attestOrganizationOfficialChannel'
           AND key_hash=repeat('4',64)),
    'official-channel-attest-assertion-mismatch-wrote-state'
  );
END
$attest_assertion_mismatch_zero_write$;

CREATE TEMP TABLE r6d39_official_channel_results(
  operation text PRIMARY KEY,
  payload jsonb NOT NULL
) ON COMMIT DROP;
GRANT INSERT,SELECT ON r6d39_official_channel_results TO gurine_control_api;

SET LOCAL ROLE gurine_control_api;
INSERT INTO r6d39_official_channel_results(operation,payload)
SELECT 'ATTEST',editorial.attest_organization_official_channel_v1(
  jsonb_build_object(
    'organizationKind','AGENCY',
    'organizationId','6d390000-0000-4000-8000-000000000001',
    'verificationMethod','OFFICIAL_DOCUMENT',
    'sourceId','6d390000-0000-4000-8000-000000000032',
    'expiresAt',clock_timestamp()+interval '1 day',
    'reason','TEST_ONLY 현재 공문과 독립 검토자 확인',
    'expectedAuthorityVersion',1,
    '_actorAssertionJti','6d390000-0000-4000-8000-000000000040',
    '_actorAssertionRequestSha256',repeat('c',64),
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','responses.review',
    '_actorActionDigest',repeat('3',64),
    '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000024',
    '_actorIdempotencyKeySha256',repeat('4',64),
    '_actorRequestKeySha256',repeat('4',64)
  ),
  '6d390000-0000-4000-8000-000000000020',
  '6d390000-0000-4000-8000-000000000023',
  '6d390000-0000-4000-8000-000000000041',repeat('4',64),repeat('a',64)
);

RESET ROLE;

SET LOCAL ROLE gurine_control_api;
INSERT INTO r6d39_official_channel_results(operation,payload)
SELECT 'ATTEST_REPLAY',editorial.attest_organization_official_channel_v1(
  jsonb_build_object(
    'organizationKind','AGENCY',
    'organizationId','6d390000-0000-4000-8000-000000000001',
    'verificationMethod','OFFICIAL_DOCUMENT',
    'sourceId','6d390000-0000-4000-8000-000000000032',
    'expiresAt',(result.payload->>'expiresAt')::timestamptz,
    'reason','TEST_ONLY 현재 공문과 독립 검토자 확인',
    'expectedAuthorityVersion',1,
    '_actorAssertionJti','6d390000-0000-4000-8000-000000000040',
    '_actorAssertionRequestSha256',repeat('c',64),
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','responses.review',
    '_actorActionDigest',repeat('3',64),
    '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000024',
    '_actorIdempotencyKeySha256',repeat('4',64),
    '_actorRequestKeySha256',repeat('4',64)
  ),
  '6d390000-0000-4000-8000-000000000020',
  '6d390000-0000-4000-8000-000000000023',
  '6d390000-0000-4000-8000-000000000041',repeat('4',64),repeat('a',64)
)
FROM r6d39_official_channel_results AS result
WHERE result.operation='ATTEST';
RESET ROLE;

SET LOCAL ROLE gurine_control_api;
DO $revoke_assertion_mismatch$
DECLARE
  v_assertion_id uuid;
BEGIN
  SELECT (payload->>'assertionId')::uuid INTO STRICT v_assertion_id
  FROM r6d39_official_channel_results WHERE operation='ATTEST';
  PERFORM editorial.revoke_organization_official_channel_v1(
    jsonb_build_object(
      'assertionId',v_assertion_id,
      'reasonCode','SOURCE_AUTHORITY_REVOKED',
      'reason','TEST_ONLY mismatched revocation assertion',
      '_actorAssertionJti','6d390000-0000-4000-8000-000000000042',
      '_actorAssertionRequestSha256',repeat('e',64),
      '_actorAssuranceLevel','STEP_UP',
      '_actorEffectiveCapability','responses.review',
      '_actorActionDigest',repeat('6',64),
      '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000025',
      '_actorIdempotencyKeySha256',repeat('7',64),
      '_actorRequestKeySha256',repeat('7',64)
    ),
    '6d390000-0000-4000-8000-000000000020',
    '6d390000-0000-4000-8000-000000000023',
    '6d390000-0000-4000-8000-000000000043',repeat('7',64),repeat('b',64)
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_official_channel_assertion_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
  WHERE operation='REVOKE';
END
$revoke_assertion_mismatch$;
RESET ROLE;

DO $revoke_assertion_mismatch_zero_write$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (SELECT rejected AND error_state='23514'
       AND error_message='official_channel_actor_assertion_invalid'
     FROM r6d39_official_channel_assertion_boundary
     WHERE operation='REVOKE'),
    'official-channel-revoke-assertion-mismatch-error'
  );
  PERFORM pg_temp.r6d39_assert(
    NOT EXISTS(
      SELECT 1
      FROM editorial.organization_official_channel_revocation_receipts_v1
      WHERE actor_assertion_jti=
        '6d390000-0000-4000-8000-000000000042'
    )
    AND NOT EXISTS(
      SELECT 1 FROM ops.audit_events
      WHERE request_id='6d390000-0000-4000-8000-000000000043'
    )
    AND (SELECT response_body IS NULL
         FROM ops.idempotency_keys
         WHERE scope=
           'control:6d390000-0000-4000-8000-000000000020:revokeOrganizationOfficialChannel'
           AND key_hash=repeat('7',64)),
    'official-channel-revoke-assertion-mismatch-wrote-state'
  );
END
$revoke_assertion_mismatch_zero_write$;

SET LOCAL ROLE gurine_control_api;
INSERT INTO r6d39_official_channel_results(operation,payload)
SELECT 'REVOKE',editorial.revoke_organization_official_channel_v1(
  jsonb_build_object(
    'assertionId',attestation.payload->>'assertionId',
    'reasonCode','SOURCE_AUTHORITY_REVOKED',
    'reason','TEST_ONLY 공식 문서 권위 철회',
    '_actorAssertionJti','6d390000-0000-4000-8000-000000000042',
    '_actorAssertionRequestSha256',repeat('d',64),
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','responses.review',
    '_actorActionDigest',repeat('6',64),
    '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000025',
    '_actorIdempotencyKeySha256',repeat('7',64),
    '_actorRequestKeySha256',repeat('7',64)
  ),
  '6d390000-0000-4000-8000-000000000020',
  '6d390000-0000-4000-8000-000000000023',
  '6d390000-0000-4000-8000-000000000043',repeat('7',64),repeat('b',64)
)
FROM r6d39_official_channel_results AS attestation
WHERE attestation.operation='ATTEST';
RESET ROLE;

SET LOCAL ROLE gurine_control_api;
INSERT INTO r6d39_official_channel_results(operation,payload)
SELECT 'REVOKE_REPLAY',editorial.revoke_organization_official_channel_v1(
  jsonb_build_object(
    'assertionId',attestation.payload->>'assertionId',
    'reasonCode','SOURCE_AUTHORITY_REVOKED',
    'reason','TEST_ONLY 공식 문서 권위 철회',
    '_actorAssertionJti','6d390000-0000-4000-8000-000000000042',
    '_actorAssertionRequestSha256',repeat('d',64),
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','responses.review',
    '_actorActionDigest',repeat('6',64),
    '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000025',
    '_actorIdempotencyKeySha256',repeat('7',64),
    '_actorRequestKeySha256',repeat('7',64)
  ),
  '6d390000-0000-4000-8000-000000000020',
  '6d390000-0000-4000-8000-000000000023',
  '6d390000-0000-4000-8000-000000000043',repeat('7',64),repeat('b',64)
)
FROM r6d39_official_channel_results AS attestation
WHERE attestation.operation='ATTEST';
RESET ROLE;

DO $d2_owner_result$
DECLARE
  v_attestation jsonb;
  v_attestation_replay jsonb;
  v_revocation jsonb;
  v_revocation_replay jsonb;
  v_assertion editorial.organization_official_channel_assertions_v1%ROWTYPE;
  v_rejected boolean:=false;
BEGIN
  SELECT payload INTO STRICT v_attestation
  FROM r6d39_official_channel_results WHERE operation='ATTEST';
  SELECT payload INTO STRICT v_attestation_replay
  FROM r6d39_official_channel_results WHERE operation='ATTEST_REPLAY';
  SELECT payload INTO STRICT v_revocation
  FROM r6d39_official_channel_results WHERE operation='REVOKE';
  SELECT payload INTO STRICT v_revocation_replay
  FROM r6d39_official_channel_results WHERE operation='REVOKE_REPLAY';
  SELECT * INTO STRICT v_assertion
  FROM editorial.organization_official_channel_assertions_v1
  WHERE assertion_id=(v_attestation->>'assertionId')::uuid;

  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*) FROM jsonb_object_keys(v_attestation))=10
    AND (SELECT count(*) FROM jsonb_object_keys(v_attestation_replay))=10
    AND (v_attestation->>'replayed')::boolean=false
    AND (v_attestation_replay->>'replayed')::boolean=true
    AND v_attestation_replay-'replayed'=v_attestation-'replayed'
    AND (v_attestation->>'assertionVersion')::bigint=1
    AND (v_attestation->>'authorityReceiptId')::uuid<>
      '00000000-0000-0000-0000-000000000000'
    AND v_attestation->>'authorityReceiptDigest'=
      btrim(v_assertion.organization_authority_receipt_digest)
    AND v_attestation->>'registryReceiptDigest'=btrim(v_assertion.receipt_digest)
    AND v_assertion.independent_verifier_user_id=
      '6d390000-0000-4000-8000-000000000020'
    AND v_assertion.official_document_evidence_id=
      '6d390000-0000-4000-8000-000000000032'
    AND EXISTS(
      SELECT 1
      FROM editorial.organization_official_channel_authority_receipts_v1 AS receipt
      WHERE receipt.authority_receipt_id=
          (v_attestation->>'authorityReceiptId')::uuid
        AND btrim(receipt.authority_receipt_digest)=
          v_attestation->>'authorityReceiptDigest'
    ),
    'official-channel-owner-result-and-source-binding'
  );
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*) FROM jsonb_object_keys(v_revocation))=7
    AND (SELECT count(*) FROM jsonb_object_keys(v_revocation_replay))=7
    AND (v_revocation->>'replayed')::boolean=false
    AND (v_revocation_replay->>'replayed')::boolean=true
    AND v_revocation_replay-'replayed'=v_revocation-'replayed'
    AND (v_revocation->>'assertionId')::uuid=v_assertion.assertion_id
    AND EXISTS(
      SELECT 1
      FROM editorial.organization_official_channel_revocation_receipts_v1 AS receipt
      WHERE receipt.revocation_id=(v_revocation->>'revocationId')::uuid
        AND receipt.assertion_id=v_assertion.assertion_id
        AND btrim(receipt.revocation_receipt_digest)=
          v_revocation->>'revocationReceiptDigest'
    ),
    'official-channel-revocation-result'
  );
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*)=1
     FROM editorial.organization_official_channel_authority_receipts_v1
     WHERE request_id='6d390000-0000-4000-8000-000000000041')
    AND (SELECT count(*)=1
         FROM editorial.organization_official_channel_assertions_v1
         WHERE assertion_id=v_assertion.assertion_id)
    AND (SELECT count(*)=1
         FROM editorial.organization_official_channel_revocation_receipts_v1
         WHERE request_id='6d390000-0000-4000-8000-000000000043')
    AND (SELECT count(*)=1 FROM ops.audit_events
         WHERE request_id='6d390000-0000-4000-8000-000000000041')
    AND (SELECT count(*)=1 FROM ops.audit_events
         WHERE request_id='6d390000-0000-4000-8000-000000000043'),
    'official-channel-replay-appended-duplicate'
  );

  BEGIN
    PERFORM editorial.require_current_official_channel_v1(
      v_assertion.assertion_id,'AGENCY',
      '6d390000-0000-4000-8000-000000000001',
      '6d390000-0000-4000-8000-000000000050',
      '6d390000-0000-4000-8000-000000000030',
      '6d390000-0000-4000-8000-000000000021',clock_timestamp()
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected:=SQLERRM='official_channel_unavailable';
  END;
  PERFORM pg_temp.r6d39_assert(
    v_rejected,'revoked-official-channel-remained-current'
  );
END
$d2_owner_result$;

-- EMAIL authority is a separate production branch from the DOCUMENT path
-- above.  Install only the immutable TEST_ONLY source graphs it consumes,
-- then exercise the real STEP_UP owner.  Raw endpoint ciphertext is never an
-- assertion input or result; the owner binds the exact consumed EMAIL_LINK,
-- current endpoint/link tuple, response dispatch, organization, and an
-- independent response-request producer into its domain-control receipt.
CREATE TEMP TABLE r6d39_official_email_cases(
  case_label text PRIMARY KEY,
  response_request_id uuid NOT NULL UNIQUE,
  endpoint_id uuid NOT NULL UNIQUE,
  verification_id uuid NOT NULL UNIQUE,
  producer_user_id uuid NOT NULL,
  actor_assertion_jti uuid NOT NULL UNIQUE,
  actor_assertion_request_digest char(64) NOT NULL,
  actor_action_digest char(64) NOT NULL,
  step_up_authorization_id uuid NOT NULL UNIQUE,
  attestation_request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  authority_expires_at timestamptz NOT NULL,
  expected_error text
) ON COMMIT DROP;
GRANT SELECT ON r6d39_official_email_cases TO gurine_control_api;

DO $d2_email_source_graphs$
DECLARE
  v_case record;
  v_at timestamptz;
  v_request_id uuid;
  v_subject_id uuid;
  v_endpoint_id uuid;
  v_verification_id uuid;
  v_link_id uuid;
  v_sent_id uuid;
  v_profile_session_id uuid;
  v_request_binding char(64);
  v_subject_profile char(64);
  v_subject_hmac char(64);
  v_endpoint_hmac char(64);
  v_endpoint_digest char(64);
  v_verification_binding char(64);
  v_proof_digest char(64);
  v_verification_receipt char(64);
  v_link_proof char(64);
  v_verification_expires_at timestamptz;
  v_link_state text;
  v_link_change text;
BEGIN
  FOR v_case IN
    SELECT * FROM (VALUES
      (
        'SUCCESS','EMAIL_LINK',
        '6d390000-0000-4000-8000-000000000001'::uuid,
        '6d390000-0000-4000-8000-000000000021'::uuid,
        false,false,NULL::text
      ),
      (
        'WRONG_PROOF','SMS_OTP',
        '6d390000-0000-4000-8000-000000000001'::uuid,
        '6d390000-0000-4000-8000-000000000021'::uuid,
        false,false,'official_channel_email_source_not_current'
      ),
      (
        'WRONG_BINDING','EMAIL_LINK',
        '6d390000-0000-4000-8000-000000000003'::uuid,
        '6d390000-0000-4000-8000-000000000021'::uuid,
        false,false,'official_channel_email_source_not_current'
      ),
      (
        'EXPIRED','EMAIL_LINK',
        '6d390000-0000-4000-8000-000000000001'::uuid,
        '6d390000-0000-4000-8000-000000000021'::uuid,
        true,false,'official_channel_email_source_not_current'
      ),
      (
        'STALE','EMAIL_LINK',
        '6d390000-0000-4000-8000-000000000001'::uuid,
        '6d390000-0000-4000-8000-000000000021'::uuid,
        false,true,'official_channel_email_source_not_current'
      ),
      (
        'SOURCE_PRODUCER','EMAIL_LINK',
        '6d390000-0000-4000-8000-000000000001'::uuid,
        '6d390000-0000-4000-8000-000000000020'::uuid,
        false,false,'official_channel_email_source_not_current'
      )
    ) AS fixture(
      case_label,challenge_kind,request_organization_id,producer_user_id,
      verification_expired,stale_link,expected_error
    )
  LOOP
    v_at:=clock_timestamp()-interval '5 minutes';
    v_request_id:=pg_temp.r6d39_uuid(
      'd2-email:'||v_case.case_label||':response-request'
    );
    v_subject_id:=pg_temp.r6d39_uuid(
      'd2-email:'||v_case.case_label||':subject'
    );
    v_endpoint_id:=pg_temp.r6d39_uuid(
      'd2-email:'||v_case.case_label||':endpoint'
    );
    v_verification_id:=pg_temp.r6d39_uuid(
      'd2-email:'||v_case.case_label||':verification'
    );
    v_link_id:=pg_temp.r6d39_uuid(
      'd2-email:'||v_case.case_label||':link'
    );
    v_sent_id:=pg_temp.r6d39_uuid(
      'd2-email:'||v_case.case_label||':sent-receipt'
    );
    v_profile_session_id:=pg_temp.r6d39_uuid(
      'd2-email:'||v_case.case_label||':profile-session'
    );
    v_subject_hmac:=pg_temp.r6d39_sha256_text(
      'd2-email:'||v_case.case_label||':subject-hmac'
    );
    v_endpoint_hmac:=pg_temp.r6d39_sha256_text(
      'd2-email:'||v_case.case_label||':endpoint-hmac'
    );
    v_endpoint_digest:=pg_temp.r6d39_sha256_json(jsonb_build_object(
      'subjectId',v_subject_id,'channel','SMTP_EMAIL',
      'endpointHmac',v_endpoint_hmac,'version',1
    ));
    v_request_binding:=pg_temp.r6d39_sha256_json(jsonb_build_object(
      'responseRequestId',v_request_id,
      'caseId','6d390000-0000-4000-8000-000000000030'::uuid,
      'partyType','AGENCY',
      'partyEntityId',v_case.request_organization_id,
      'requestVersion',2,'endpointId',v_endpoint_id,
      'endpointVersion',1,'endpointSnapshotDigest',v_endpoint_digest
    ));
    v_subject_profile:=pg_temp.r6d39_sha256_json(jsonb_build_object(
      'subjectId',v_subject_id,'originType','RESPONSE_REQUEST',
      'originId',v_request_id,'originVersion',2,
      'partyType','AGENCY','partyEntityId',v_case.request_organization_id
    ));
    v_verification_binding:=pg_temp.r6d39_sha256_json(jsonb_build_object(
      'subjectId',v_subject_id,'endpointId',v_endpoint_id,
      'endpointVersion',1,'challengeKind',v_case.challenge_kind
    ));
    v_proof_digest:=pg_temp.r6d39_sha256_json(jsonb_build_object(
      'verificationId',v_verification_id,
      'verificationBindingDigest',v_verification_binding,
      'verifiedAt',v_at,'consumedAt',v_at
    ));
    v_verification_receipt:=pg_temp.r6d39_sha256_json(jsonb_build_object(
      'verificationId',v_verification_id,'proofDigest',v_proof_digest,
      'state','VERIFIED','endpointSnapshotDigest',v_endpoint_digest
    ));
    v_link_proof:=pg_temp.r6d39_sha256_text(
      'd2-email:'||v_case.case_label||':link-proof'
    );
    v_verification_expires_at:=CASE
      WHEN v_case.verification_expired THEN v_at+interval '1 minute'
      ELSE clock_timestamp()+interval '2 days'
    END;
    v_link_state:=CASE WHEN v_case.stale_link THEN 'REVOKED' ELSE 'ACTIVE' END;
    v_link_change:=CASE WHEN v_case.stale_link THEN 'UNLINKED' ELSE 'VERIFIED' END;

    -- The communication graph has reciprocal historical FKs.  As in the
    -- existing D3 and control-flow fixtures, only these disposable source
    -- roots are installed under replica mode; the authority owner and every
    -- assertion below run with all production triggers restored.
    PERFORM set_config('session_replication_role','replica',true);
    INSERT INTO editorial.response_requests(
      id,case_id,party_type,party_entity_id,party_name,
      recipient_email_hash,recipient_email_encrypted,questions,
      requested_publication_scope,due_at,effective_due_at,sent_at,status,
      version,created_by,created_at,updated_at
    ) VALUES(
      v_request_id,'6d390000-0000-4000-8000-000000000030','AGENCY',
      v_case.request_organization_id,
      'TEST_ONLY official domain '||v_case.case_label,
      pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':recipient'
      ),pg_temp.r6d39_envelope('d2_email_'||lower(v_case.case_label)),
      jsonb_build_array('TEST_ONLY 공식 채널 확인'),
      jsonb_build_object('body',true),clock_timestamp()+interval '7 days',
      clock_timestamp()+interval '7 days',v_at,'SENT',2,
      v_case.producer_user_id,v_at,v_at
    );
    INSERT INTO intake.communication_subjects(
      id,subject_kind,origin_object_type,origin_object_id,
      origin_object_version,origin_binding_digest,subject_pseudonym_hmac,
      hmac_key_version,jurisdiction,locale,status,profile_version,
      profile_digest,created_at,updated_at
    ) VALUES(
      v_subject_id,'RESPONSE_PARTY','RESPONSE_REQUEST',v_request_id,2,
      v_request_binding,v_subject_hmac,'TEST_ONLY','KR','ko-KR','ACTIVE',1,
      v_subject_profile,v_at,v_at
    );
    INSERT INTO intake.communication_endpoints(
      id,subject_id,channel,endpoint_hmac,hmac_key_version,
      endpoint_ciphertext,encryption_key_id,state,version,endpoint_digest,
      endpoint_aad_digest,verified_at,created_at,updated_at
    ) VALUES(
      v_endpoint_id,v_subject_id,'SMTP_EMAIL',v_endpoint_hmac,'TEST_ONLY',
      pg_temp.r6d39_envelope('d2_email_endpoint_'||lower(v_case.case_label)),
      'key-v1','ACTIVE',1,v_endpoint_digest,
      ops.r6d_nul5_sha256_v1(
        'intake.communication_endpoints','endpoint_ciphertext',
        v_endpoint_id::text,'email-address','1'
      ),v_at,v_at,v_at
    );
    INSERT INTO intake.communication_endpoint_verifications(
      id,subject_id,subject_origin_binding_digest,endpoint_id,
      endpoint_version,endpoint_snapshot_digest,profile_session_id,
      challenge_kind,challenge_hash,nonce_hash,verification_binding_digest,
      state,attempt_count,max_attempts,version,proof_digest,receipt_digest,
      issued_at,expires_at,verified_at,consumed_at
    ) VALUES(
      v_verification_id,v_subject_id,v_request_binding,v_endpoint_id,1,
      v_endpoint_digest,v_profile_session_id,v_case.challenge_kind,
      pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':challenge'
      ),pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':nonce'
      ),v_verification_binding,'VERIFIED',1,3,1,v_proof_digest,
      v_verification_receipt,v_at-interval '5 minutes',
      v_verification_expires_at,v_at,v_at
    );
    INSERT INTO intake.communication_endpoint_link_events(
      id,subject_id,subject_origin_binding_digest,endpoint_id,
      endpoint_sequence,profile_version,endpoint_version,endpoint_hmac,
      endpoint_digest,channel,state,change_kind,profile_session_id,
      verification_id,proof_digest,reason_code,endpoint_snapshot_digest,
      event_digest,audit_event_id,receipt_digest,occurred_at
    ) VALUES(
      v_link_id,v_subject_id,v_request_binding,v_endpoint_id,1,1,1,
      v_endpoint_hmac,v_endpoint_digest,'SMTP_EMAIL',v_link_state,
      v_link_change,v_profile_session_id,v_verification_id,v_link_proof,
      'TEST_ONLY_OFFICIAL_DOMAIN_'||v_case.case_label,v_endpoint_digest,
      pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':link-event'
      ),pg_temp.r6d39_uuid(
        'd2-email:'||v_case.case_label||':link-audit'
      ),pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':link-receipt'
      ),v_at
    );
    INSERT INTO editorial.response_request_sent_receipts(
      id,source_event_id,source_event_envelope_digest,response_request_id,
      prior_request_version,request_version,response_request_binding_digest,
      scope_digest,prior_state,state,communication_intent_id,
      communication_intent_digest,rendering_id,rendering_digest,
      rendered_sha256,response_access_token_id,
      access_artifact_binding_digest,endpoint_id,endpoint_version,
      endpoint_snapshot_digest,channel,provider_config_id,
      provider_config_version,provider_configuration_digest,
      provider_preflight_receipt_id,provider_preflight_receipt_digest,
      delivery_id,delivery_object_type,delivery_version,delivery_receipt_id,
      delivery_receipt_sequence,delivery_receipt_digest,
      delivery_resulting_state,delivery_receipt_applied,
      acceptance_evidence_kind,provider_evidence_digest,
      provider_accepted_at,audit_event_id,outbox_event_id,receipt_digest,
      created_at
    ) VALUES(
      v_sent_id,pg_temp.r6d39_uuid(
        'd2-email:'||v_case.case_label||':sent-source-event'
      ),pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':sent-source-envelope'
      ),v_request_id,1,2,v_request_binding,
      pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':scope'
      ),'DRAFT','SENT',pg_temp.r6d39_uuid(
        'd2-email:'||v_case.case_label||':intent'
      ),pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':intent'
      ),pg_temp.r6d39_uuid(
        'd2-email:'||v_case.case_label||':rendering'
      ),pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':rendering'
      ),pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':rendered'
      ),pg_temp.r6d39_uuid(
        'd2-email:'||v_case.case_label||':access-token'
      ),pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':access-binding'
      ),v_endpoint_id,1,v_endpoint_digest,'SMTP_EMAIL',
      pg_temp.r6d39_uuid('d2-email:'||v_case.case_label||':provider'),1,
      pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':provider-config'
      ),pg_temp.r6d39_uuid(
        'd2-email:'||v_case.case_label||':provider-preflight'
      ),pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':provider-preflight'
      ),pg_temp.r6d39_uuid(
        'd2-email:'||v_case.case_label||':delivery'
      ),'RESPONSE_REQUEST',2,pg_temp.r6d39_uuid(
        'd2-email:'||v_case.case_label||':delivery-receipt'
      ),1,pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':delivery-receipt'
      ),'DELIVERED',true,'PROVIDER_RESPONSE',
      pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':provider-evidence'
      ),v_at,pg_temp.r6d39_uuid(
        'd2-email:'||v_case.case_label||':sent-audit'
      ),pg_temp.r6d39_uuid(
        'd2-email:'||v_case.case_label||':sent-outbox'
      ),pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':sent-receipt'
      ),v_at
    );
    PERFORM set_config('session_replication_role','origin',true);

    INSERT INTO r6d39_official_email_cases(
      case_label,response_request_id,endpoint_id,verification_id,
      producer_user_id,actor_assertion_jti,
      actor_assertion_request_digest,actor_action_digest,
      step_up_authorization_id,attestation_request_id,
      idempotency_key_sha256,request_digest,authority_expires_at,
      expected_error
    ) VALUES(
      v_case.case_label,v_request_id,v_endpoint_id,v_verification_id,
      v_case.producer_user_id,
      pg_temp.r6d39_uuid('d2-email:'||v_case.case_label||':actor-jti'),
      pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':wire-request'
      ),pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':action'
      ),pg_temp.r6d39_uuid(
        'd2-email:'||v_case.case_label||':step-up'
      ),pg_temp.r6d39_uuid(
        'd2-email:'||v_case.case_label||':attestation-request'
      ),pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':idempotency'
      ),pg_temp.r6d39_sha256_text(
        'd2-email:'||v_case.case_label||':semantic-request'
      ),clock_timestamp()+interval '1 day',v_case.expected_error
    );
  END LOOP;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('session_replication_role','origin',true);
  RAISE;
END
$d2_email_source_graphs$;

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
)
SELECT
  step_up_authorization_id,'6d390000-0000-4000-8000-000000000023',
  actor_action_digest,idempotency_key_sha256,
  pg_temp.r6d39_sha256_text('d2-email:'||case_label||':step-up-token'),
  clock_timestamp()+interval '4 minutes',1,3,
  clock_timestamp()-interval '1 minute'
FROM r6d39_official_email_cases;

INSERT INTO ops.assertion_replay_guard(
  assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
)
SELECT
  'ACTOR',actor_assertion_jti,'identity-api','control-api',
  actor_assertion_request_digest,clock_timestamp()+interval '10 minutes',
  clock_timestamp()-interval '1 minute'
FROM r6d39_official_email_cases;

INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
SELECT
  'control:6d390000-0000-4000-8000-000000000020:attestOrganizationOfficialChannel',
  idempotency_key_sha256,request_digest,clock_timestamp()+interval '1 hour'
FROM r6d39_official_email_cases;

CREATE TEMP TABLE r6d39_official_email_results(
  operation text PRIMARY KEY,
  payload jsonb NOT NULL
) ON COMMIT DROP;
GRANT INSERT,SELECT ON r6d39_official_email_results TO gurine_control_api;

SET LOCAL ROLE gurine_control_api;
INSERT INTO r6d39_official_email_results(operation,payload)
SELECT 'ATTEST',editorial.attest_organization_official_channel_v1(
  jsonb_build_object(
    'organizationKind','AGENCY',
    'organizationId','6d390000-0000-4000-8000-000000000001',
    'verificationMethod','OFFICIAL_DOMAIN_EMAIL',
    'sourceId',verification_id,'expiresAt',authority_expires_at,
    'reason','TEST_ONLY exact official-domain EMAIL_LINK attestation',
    'expectedAuthorityVersion',1,
    '_actorAssertionJti',actor_assertion_jti,
    '_actorAssertionRequestSha256',actor_assertion_request_digest,
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','responses.review',
    '_actorActionDigest',actor_action_digest,
    '_actorStepUpAuthorizationId',step_up_authorization_id,
    '_actorIdempotencyKeySha256',idempotency_key_sha256,
    '_actorRequestKeySha256',idempotency_key_sha256
  ),'6d390000-0000-4000-8000-000000000020',
  '6d390000-0000-4000-8000-000000000023',attestation_request_id,
  idempotency_key_sha256,request_digest
)
FROM r6d39_official_email_cases WHERE case_label='SUCCESS';
RESET ROLE;

DO $d2_email_success_and_current_consumer$
DECLARE
  v_result jsonb;
  v_case r6d39_official_email_cases%ROWTYPE;
  v_assertion editorial.organization_official_channel_assertions_v1%ROWTYPE;
  v_authority
    editorial.organization_official_channel_authority_receipts_v1%ROWTYPE;
  v_audit ops.audit_events%ROWTYPE;
  v_current jsonb;
BEGIN
  SELECT * INTO STRICT v_case
  FROM r6d39_official_email_cases WHERE case_label='SUCCESS';
  SELECT payload INTO STRICT v_result
  FROM r6d39_official_email_results WHERE operation='ATTEST';
  SELECT * INTO STRICT v_assertion
  FROM editorial.organization_official_channel_assertions_v1
  WHERE assertion_id=(v_result->>'assertionId')::uuid;
  SELECT * INTO STRICT v_authority
  FROM editorial.organization_official_channel_authority_receipts_v1
  WHERE authority_receipt_id=(v_result->>'authorityReceiptId')::uuid;
  SELECT * INTO STRICT v_audit FROM ops.audit_events
  WHERE id=v_authority.audit_event_id;

  PERFORM pg_temp.r6d39_assert(
    (v_result->>'replayed')::boolean=false
    AND v_assertion.verification_method='OFFICIAL_DOMAIN_EMAIL'
    AND v_assertion.source_purpose='OFFICIAL_DOMAIN_CONTROL'
    AND v_assertion.organization_authority_receipt_kind=
      'ORGANIZATION_DOMAIN_CONTROL'
    AND v_assertion.organization_kind='AGENCY'
    AND v_assertion.organization_id=
      '6d390000-0000-4000-8000-000000000001'
    AND v_assertion.communication_verification_id=v_case.verification_id
    AND v_assertion.communication_endpoint_id=v_case.endpoint_id
    AND v_assertion.official_document_evidence_id IS NULL
    AND v_assertion.independent_verifier_user_id=
      '6d390000-0000-4000-8000-000000000020'
    AND v_authority.attested_by_user_id=
      '6d390000-0000-4000-8000-000000000020'
    AND v_authority.source_id=v_case.verification_id
    AND v_authority.communication_verification_id=v_case.verification_id
    AND v_authority.official_document_evidence_id IS NULL
    AND v_authority.source_snapshot_payload->>'schemaVersion'=
      'organization-authority-email-source.v1'
    AND (v_authority.source_snapshot_payload->>'responseRequestId')::uuid=
      v_case.response_request_id
    AND (v_authority.source_snapshot_payload->>
      'responseRequestProducerUserId')::uuid=v_case.producer_user_id
    AND (v_authority.source_snapshot_payload->>
      'communicationVerificationId')::uuid=v_case.verification_id
    AND v_case.producer_user_id<>v_authority.attested_by_user_id
    AND v_audit.capability='responses.review'
    AND v_audit.action='organization.official_channel.attest'
    AND v_audit.outcome='SUCCESS',
    'official-email-owner-domain-binding-and-independence'
  );

  v_current:=editorial.require_current_official_channel_v1(
    v_assertion.assertion_id,'AGENCY',
    '6d390000-0000-4000-8000-000000000001',v_case.response_request_id,
    '6d390000-0000-4000-8000-000000000030',
    '6d390000-0000-4000-8000-000000000021',clock_timestamp()
  );
  PERFORM pg_temp.r6d39_assert(
    v_current->>'verificationMethod'='OFFICIAL_DOMAIN_EMAIL'
    AND (v_current->>'communicationVerificationId')::uuid=
      v_case.verification_id
    AND (v_current->>'communicationEndpointId')::uuid=v_case.endpoint_id
    AND v_current->>'registryReceiptDigest'=btrim(v_assertion.receipt_digest)
    AND v_current->>'organizationAuthorityReceiptDigest'=
      btrim(v_authority.authority_receipt_digest),
    'official-email-current-consumer-result'
  );
END
$d2_email_success_and_current_consumer$;

CREATE TEMP TABLE r6d39_official_email_write_baseline(
  authority_count bigint NOT NULL,
  assertion_count bigint NOT NULL,
  audit_count bigint NOT NULL,
  outbox_count bigint NOT NULL
) ON COMMIT DROP;
INSERT INTO r6d39_official_email_write_baseline
SELECT
  (SELECT count(*)
   FROM editorial.organization_official_channel_authority_receipts_v1),
  (SELECT count(*)
   FROM editorial.organization_official_channel_assertions_v1),
  (SELECT count(*) FROM ops.audit_events),
  (SELECT count(*) FROM ops.outbox);

CREATE TEMP TABLE r6d39_official_email_failures(
  case_label text PRIMARY KEY,
  rejected boolean NOT NULL DEFAULT false,
  error_state text,
  error_message text
) ON COMMIT DROP;
INSERT INTO r6d39_official_email_failures(case_label)
SELECT case_label FROM r6d39_official_email_cases
WHERE expected_error IS NOT NULL;
GRANT SELECT,UPDATE ON r6d39_official_email_failures TO gurine_control_api;

SET LOCAL ROLE gurine_control_api;
DO $d2_email_negative_owner_calls$
DECLARE
  v_case r6d39_official_email_cases%ROWTYPE;
BEGIN
  FOR v_case IN
    SELECT * FROM r6d39_official_email_cases
    WHERE expected_error IS NOT NULL ORDER BY case_label
  LOOP
    BEGIN
      PERFORM editorial.attest_organization_official_channel_v1(
        jsonb_build_object(
          'organizationKind','AGENCY',
          'organizationId','6d390000-0000-4000-8000-000000000001',
          'verificationMethod','OFFICIAL_DOMAIN_EMAIL',
          'sourceId',v_case.verification_id,
          'expiresAt',v_case.authority_expires_at,
          'reason','TEST_ONLY rejected EMAIL authority '||v_case.case_label,
          'expectedAuthorityVersion',1,
          '_actorAssertionJti',v_case.actor_assertion_jti,
          '_actorAssertionRequestSha256',
            v_case.actor_assertion_request_digest,
          '_actorAssuranceLevel','STEP_UP',
          '_actorEffectiveCapability','responses.review',
          '_actorActionDigest',v_case.actor_action_digest,
          '_actorStepUpAuthorizationId',v_case.step_up_authorization_id,
          '_actorIdempotencyKeySha256',v_case.idempotency_key_sha256,
          '_actorRequestKeySha256',v_case.idempotency_key_sha256
        ),'6d390000-0000-4000-8000-000000000020',
        '6d390000-0000-4000-8000-000000000023',
        v_case.attestation_request_id,v_case.idempotency_key_sha256,
        v_case.request_digest
      );
    EXCEPTION WHEN OTHERS THEN
      UPDATE r6d39_official_email_failures
      SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM
      WHERE case_label=v_case.case_label;
    END;
  END LOOP;
END
$d2_email_negative_owner_calls$;
RESET ROLE;

DO $d2_email_negative_zero_write$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    NOT EXISTS(
      SELECT 1
      FROM r6d39_official_email_cases AS test_case
      JOIN r6d39_official_email_failures AS failure USING(case_label)
      WHERE test_case.expected_error IS NOT NULL
        AND NOT (
          failure.rejected
          AND failure.error_state='23514'
          AND failure.error_message=test_case.expected_error
        )
    ),'official-email-negative-error-contract'
  );
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*)
     FROM editorial.organization_official_channel_authority_receipts_v1)=
      (SELECT authority_count
       FROM r6d39_official_email_write_baseline)
    AND (SELECT count(*)
         FROM editorial.organization_official_channel_assertions_v1)=
      (SELECT assertion_count
       FROM r6d39_official_email_write_baseline)
    AND (SELECT count(*) FROM ops.audit_events)=
      (SELECT audit_count FROM r6d39_official_email_write_baseline)
    AND (SELECT count(*) FROM ops.outbox)=
      (SELECT outbox_count FROM r6d39_official_email_write_baseline),
    'official-email-negative-owner-wrote-state'
  );
  PERFORM pg_temp.r6d39_assert(
    NOT EXISTS(
      SELECT 1
      FROM r6d39_official_email_cases AS test_case
      JOIN editorial.organization_official_channel_authority_receipts_v1
        AS authority ON authority.source_id=test_case.verification_id
      WHERE test_case.expected_error IS NOT NULL
    )
    AND NOT EXISTS(
      SELECT 1
      FROM r6d39_official_email_cases AS test_case
      JOIN editorial.organization_official_channel_assertions_v1 AS assertion
        ON assertion.communication_verification_id=test_case.verification_id
      WHERE test_case.expected_error IS NOT NULL
    )
    AND NOT EXISTS(
      SELECT 1
      FROM r6d39_official_email_cases AS test_case
      JOIN ops.audit_events AS audit
        ON audit.request_id=test_case.attestation_request_id
      WHERE test_case.expected_error IS NOT NULL
    )
    AND NOT EXISTS(
      SELECT 1
      FROM r6d39_official_email_cases AS test_case
      JOIN ops.idempotency_keys AS idempotency
        ON idempotency.key_hash=test_case.idempotency_key_sha256
      WHERE test_case.expected_error IS NOT NULL
        AND num_nonnulls(
          idempotency.response_status,idempotency.response_body,
          idempotency.resource_type,idempotency.resource_id
        )<>0
    ),'official-email-negative-source-specific-zero-write'
  );
END
$d2_email_negative_zero_write$;

-- The successful assertion is current above.  Append a later immutable link
-- revision and prove the existing response consumer re-evaluates source
-- currentness instead of trusting its earlier receipt.
DO $d2_email_consumer_stale_link$
DECLARE
  v_case r6d39_official_email_cases%ROWTYPE;
  v_result jsonb;
  v_assertion_id uuid;
  v_subject_id uuid;
  v_subject_origin char(64);
  v_endpoint_hmac char(64);
  v_stale_digest char(64);
  v_rejected boolean:=false;
  v_authority_count bigint;
  v_assertion_count bigint;
  v_audit_count bigint;
  v_outbox_count bigint;
BEGIN
  SELECT * INTO STRICT v_case
  FROM r6d39_official_email_cases WHERE case_label='SUCCESS';
  SELECT payload INTO STRICT v_result
  FROM r6d39_official_email_results WHERE operation='ATTEST';
  v_assertion_id:=(v_result->>'assertionId')::uuid;
  SELECT subject_id,endpoint_hmac INTO STRICT v_subject_id,v_endpoint_hmac
  FROM intake.communication_endpoints WHERE id=v_case.endpoint_id;
  SELECT origin_binding_digest INTO STRICT v_subject_origin
  FROM intake.communication_subjects WHERE id=v_subject_id;
  v_stale_digest:=pg_temp.r6d39_sha256_text(
    'd2-email:SUCCESS:stale-endpoint-revision'
  );
  SELECT
    (SELECT count(*)
     FROM editorial.organization_official_channel_authority_receipts_v1),
    (SELECT count(*)
     FROM editorial.organization_official_channel_assertions_v1),
    (SELECT count(*) FROM ops.audit_events),
    (SELECT count(*) FROM ops.outbox)
  INTO v_authority_count,v_assertion_count,v_audit_count,v_outbox_count;

  PERFORM set_config('session_replication_role','replica',true);
  INSERT INTO intake.communication_endpoint_link_events(
    id,subject_id,subject_origin_binding_digest,endpoint_id,
    endpoint_sequence,profile_version,prior_endpoint_version,
    endpoint_version,endpoint_hmac,endpoint_digest,channel,prior_state,state,
    change_kind,proof_digest,reason_code,endpoint_snapshot_digest,
    event_digest,audit_event_id,receipt_digest,occurred_at
  ) VALUES(
    pg_temp.r6d39_uuid('d2-email:SUCCESS:stale-link'),v_subject_id,
    v_subject_origin,v_case.endpoint_id,2,2,1,2,v_endpoint_hmac,
    v_stale_digest,'SMTP_EMAIL','ACTIVE','REVOKED','UNLINKED',
    pg_temp.r6d39_sha256_text('d2-email:SUCCESS:stale-proof'),
    'TEST_ONLY_SOURCE_BECAME_STALE',v_stale_digest,
    pg_temp.r6d39_sha256_text('d2-email:SUCCESS:stale-event'),
    pg_temp.r6d39_uuid('d2-email:SUCCESS:stale-audit'),
    pg_temp.r6d39_sha256_text('d2-email:SUCCESS:stale-receipt'),
    clock_timestamp()
  );
  PERFORM set_config('session_replication_role','origin',true);

  BEGIN
    PERFORM editorial.require_current_official_channel_v1(
      v_assertion_id,'AGENCY',
      '6d390000-0000-4000-8000-000000000001',v_case.response_request_id,
      '6d390000-0000-4000-8000-000000000030',
      '6d390000-0000-4000-8000-000000000021',clock_timestamp()
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected:=SQLERRM='official_channel_email_not_current';
  END;
  PERFORM pg_temp.r6d39_assert(
    v_rejected,'official-email-stale-consumer-remained-current'
  );
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*)
     FROM editorial.organization_official_channel_authority_receipts_v1)=
      v_authority_count
    AND (SELECT count(*)
         FROM editorial.organization_official_channel_assertions_v1)=
      v_assertion_count
    AND (SELECT count(*) FROM ops.audit_events)=v_audit_count
    AND (SELECT count(*) FROM ops.outbox)=v_outbox_count,
    'official-email-stale-consumer-wrote-state'
  );
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('session_replication_role','origin',true);
  RAISE;
END
$d2_email_consumer_stale_link$;

-- D3 success uses an explicit TEST_ONLY response-receipt authority graph.  The
-- source rows model an already completed response submission and an ACTIVE
-- endpoint; they are fixture inputs, not an operating seed or a replacement
-- for the production response producer.  Foreign-key parents outside the D3
-- consumer's read set are intentionally bypassed only while these disposable
-- roots are installed.
DO $d3_response_receipt_source_fixture$
DECLARE
  v_at timestamptz:=clock_timestamp()-interval '1 hour';
  v_submission_digest char(64):=
    pg_temp.r6d39_sha256_text('d3-source-submission');
  v_receipt_digest char(64):=
    pg_temp.r6d39_sha256_text('d3-source-response-receipt');
  v_possession_hmac char(64):=
    pg_temp.r6d39_sha256_text('d3-source-possession');
  v_subject_origin char(64):=
    pg_temp.r6d39_sha256_text('d3-source-subject-origin');
  v_subject_profile char(64):=
    pg_temp.r6d39_sha256_text('d3-source-subject-profile');
  v_endpoint_hmac char(64):=
    pg_temp.r6d39_sha256_text('d3-source-endpoint-hmac');
  v_endpoint_digest char(64):=
    pg_temp.r6d39_sha256_text('d3-source-endpoint');
  v_link_proof char(64):=
    pg_temp.r6d39_sha256_text('d3-source-link-proof');
  v_link_event char(64):=
    pg_temp.r6d39_sha256_text('d3-source-link-event');
  v_link_receipt char(64):=
    pg_temp.r6d39_sha256_text('d3-source-link-receipt');
BEGIN
  PERFORM set_config('session_replication_role','replica',true);
  INSERT INTO intake.communication_subjects(
    id,subject_kind,origin_object_type,origin_object_id,
    origin_object_version,origin_binding_digest,subject_pseudonym_hmac,
    hmac_key_version,jurisdiction,locale,status,profile_version,
    profile_digest,created_at,updated_at
  ) VALUES(
    '6d390000-0000-4000-8000-000000000201','RESPONSE_PARTY',
    'RESPONSE_REQUEST','6d390000-0000-4000-8000-000000000200',1,
    v_subject_origin,pg_temp.r6d39_sha256_text('d3-source-subject-hmac'),
    'TEST_ONLY','KR','ko-KR','ACTIVE',1,v_subject_profile,v_at,v_at
  );
  INSERT INTO intake.communication_endpoints(
    id,subject_id,channel,endpoint_hmac,hmac_key_version,
    endpoint_ciphertext,encryption_key_id,state,version,endpoint_digest,
    endpoint_aad_digest,verified_at,created_at,updated_at
  ) VALUES(
    '6d390000-0000-4000-8000-000000000202',
    '6d390000-0000-4000-8000-000000000201','SMTP_EMAIL',
    v_endpoint_hmac,'TEST_ONLY',
    pg_temp.r6d39_envelope('d3_source_endpoint'),'key-v1','ACTIVE',1,
    v_endpoint_digest,ops.r6d_nul5_sha256_v1(
      'intake.communication_endpoints','endpoint_ciphertext',
      '6d390000-0000-4000-8000-000000000202','email-address','1'
    ),v_at,v_at,v_at
  );
  INSERT INTO intake.communication_endpoint_link_events(
    id,subject_id,subject_origin_binding_digest,endpoint_id,
    endpoint_sequence,profile_version,endpoint_version,endpoint_hmac,
    endpoint_digest,channel,state,change_kind,proof_digest,reason_code,
    endpoint_snapshot_digest,event_digest,audit_event_id,receipt_digest,
    occurred_at
  ) VALUES(
    '6d390000-0000-4000-8000-000000000203',
    '6d390000-0000-4000-8000-000000000201',v_subject_origin,
    '6d390000-0000-4000-8000-000000000202',1,1,1,v_endpoint_hmac,
    v_endpoint_digest,'SMTP_EMAIL','ACTIVE','VERIFIED',v_link_proof,
    'TEST_ONLY_RESPONSE_RECEIPT_SOURCE',v_endpoint_digest,v_link_event,
    '6d390000-0000-4000-8000-000000000207',v_link_receipt,v_at
  );
  INSERT INTO intake.response_submissions(
    id,response_request_id,draft_version,submission_sha256,
    answers_encrypted,publication_consent,status,submitted_at,
    receipt_token_hash,receipt_version,receipt_digest,receipt_updated_at
  ) VALUES(
    '6d390000-0000-4000-8000-000000000204',
    '6d390000-0000-4000-8000-000000000200',1,v_submission_digest,
    pg_temp.r6d39_envelope('d3_source_response'),'{}'::jsonb,'SUBMITTED',
    v_at,v_possession_hmac,1,v_receipt_digest,v_at
  );
  INSERT INTO intake.response_submission_receipts_v3(
    receipt_id,response_submission_id,response_request_id,
    response_request_version,response_request_binding_digest,draft_version,
    submission_sha256,publication_consent_sha256,receipt_version,
    receipt_digest,receipt_session_id,receipt_session_expires_at,
    domain_event_id,notification_event_id,workflow_event_id,
    workflow_event_envelope_digest,actor_type,actor_id,audit_event_id,
    idempotency_key_sha256,request_digest,submitted_at,created_at,
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) VALUES(
    '6d390000-0000-4000-8000-000000000205',
    '6d390000-0000-4000-8000-000000000204',
    '6d390000-0000-4000-8000-000000000200',2,
    pg_temp.r6d39_sha256_text('d3-source-request-binding'),1,
    v_submission_digest,pg_temp.r6d39_sha256_text('d3-source-consent'),1,
    v_receipt_digest,'6d390000-0000-4000-8000-000000000208',
    v_at+interval '1 day','6d390000-0000-4000-8000-000000000209',
    '6d390000-0000-4000-8000-00000000020a',
    '6d390000-0000-4000-8000-00000000020b',
    pg_temp.r6d39_sha256_text('d3-source-workflow-event'),'SERVICE',
    'submission-api','6d390000-0000-4000-8000-00000000020c',
    pg_temp.r6d39_sha256_text('d3-source-submit-idempotency'),
    pg_temp.r6d39_sha256_text('d3-source-submit-request'),v_at,v_at,
    '6d390000-0000-4000-8000-00000000020d',
    'RESPONSE_IDENTITY_GOVERNANCE',
    pg_temp.r6d39_sha256_text('d3-source-retention-schedule')
  );
  INSERT INTO editorial.response_request_sent_receipts(
    id,source_event_id,source_event_envelope_digest,response_request_id,
    prior_request_version,request_version,response_request_binding_digest,
    scope_digest,prior_state,state,communication_intent_id,
    communication_intent_digest,rendering_id,rendering_digest,
    rendered_sha256,response_access_token_id,access_artifact_binding_digest,
    endpoint_id,endpoint_version,endpoint_snapshot_digest,channel,
    provider_config_id,provider_config_version,provider_configuration_digest,
    provider_preflight_receipt_id,provider_preflight_receipt_digest,
    delivery_id,delivery_object_type,delivery_version,delivery_receipt_id,
    delivery_receipt_sequence,delivery_receipt_digest,
    delivery_resulting_state,delivery_receipt_applied,
    acceptance_evidence_kind,provider_evidence_digest,provider_accepted_at,
    audit_event_id,outbox_event_id,receipt_digest,created_at
  ) VALUES(
    '6d390000-0000-4000-8000-000000000206',
    '6d390000-0000-4000-8000-00000000020e',
    pg_temp.r6d39_sha256_text('d3-source-sent-event'),
    '6d390000-0000-4000-8000-000000000200',1,2,
    pg_temp.r6d39_sha256_text('d3-source-request-binding'),
    pg_temp.r6d39_sha256_text('d3-source-request-scope'),'DRAFT','SENT',
    '6d390000-0000-4000-8000-00000000020f',
    pg_temp.r6d39_sha256_text('d3-source-intent'),
    '6d390000-0000-4000-8000-000000000210',
    pg_temp.r6d39_sha256_text('d3-source-rendering'),
    pg_temp.r6d39_sha256_text('d3-source-rendered'),
    '6d390000-0000-4000-8000-000000000211',
    pg_temp.r6d39_sha256_text('d3-source-access'),
    '6d390000-0000-4000-8000-000000000202',1,v_endpoint_digest,
    'SMTP_EMAIL','6d390000-0000-4000-8000-000000000212',1,
    pg_temp.r6d39_sha256_text('d3-source-provider-config'),
    '6d390000-0000-4000-8000-000000000213',
    pg_temp.r6d39_sha256_text('d3-source-preflight'),
    '6d390000-0000-4000-8000-000000000214','RESPONSE_REQUEST',2,
    '6d390000-0000-4000-8000-000000000215',1,
    pg_temp.r6d39_sha256_text('d3-source-delivery'),'DELIVERED',true,
    'PROVIDER_RESPONSE',pg_temp.r6d39_sha256_text('d3-source-provider'),
    v_at,'6d390000-0000-4000-8000-000000000216',
    '6d390000-0000-4000-8000-000000000217',
    pg_temp.r6d39_sha256_text('d3-source-sent-receipt'),v_at
  );
  PERFORM set_config('session_replication_role','origin',true);
END
$d3_response_receipt_source_fixture$;

DO $d3_response_receipt_source_preflight$
DECLARE
  v_receipt intake.response_submission_receipts_v3%ROWTYPE;
  v_submission intake.response_submissions%ROWTYPE;
  v_sent editorial.response_request_sent_receipts%ROWTYPE;
  v_endpoint intake.communication_endpoints%ROWTYPE;
  v_subject intake.communication_subjects%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_receipt
  FROM intake.response_submission_receipts_v3
  WHERE receipt_id='6d390000-0000-4000-8000-000000000205';
  SELECT * INTO STRICT v_submission
  FROM intake.response_submissions WHERE id=v_receipt.response_submission_id;
  SELECT * INTO STRICT v_sent
  FROM editorial.response_request_sent_receipts
  WHERE response_request_id=v_receipt.response_request_id;
  SELECT * INTO STRICT v_endpoint
  FROM intake.communication_endpoints
  WHERE id=v_sent.endpoint_id AND version=v_sent.endpoint_version
    AND endpoint_digest=v_sent.endpoint_snapshot_digest;
  SELECT subject.* INTO STRICT v_subject
  FROM intake.communication_endpoint_link_events AS link
  JOIN intake.communication_subjects AS subject
    ON subject.id=link.subject_id
   AND subject.origin_binding_digest=link.subject_origin_binding_digest
  WHERE link.endpoint_id=v_sent.endpoint_id
    AND link.endpoint_version=v_sent.endpoint_version
    AND link.endpoint_snapshot_digest=v_sent.endpoint_snapshot_digest
    AND link.channel=v_sent.channel AND link.state='ACTIVE';
  PERFORM pg_temp.r6d39_assert(
    v_submission.response_request_id=v_receipt.response_request_id,
    'd3-source-response-request'
  );
  PERFORM pg_temp.r6d39_assert(
    v_submission.receipt_version=v_receipt.receipt_version,
    'd3-source-receipt-version'
  );
  PERFORM pg_temp.r6d39_assert(
    v_submission.receipt_digest=v_receipt.receipt_digest,
    'd3-source-receipt-digest'
  );
  PERFORM pg_temp.r6d39_assert(
    v_submission.submission_sha256=v_receipt.submission_sha256,
    'd3-source-submission-digest'
  );
  PERFORM pg_temp.r6d39_assert(
    v_submission.receipt_token_hash=
      pg_temp.r6d39_sha256_text('d3-source-possession'),
    'd3-source-possession-hmac'
  );
  PERFORM pg_temp.r6d39_assert(
    v_submission.status='SUBMITTED' AND v_endpoint.state='ACTIVE'
    AND v_endpoint.subject_id=v_subject.id,
    'd3-source-current-graph'
  );
END
$d3_response_receipt_source_preflight$;

CREATE TEMP TABLE r6d39_privacy_results(
  operation text PRIMARY KEY,
  payload jsonb NOT NULL
) ON COMMIT DROP;
GRANT INSERT,SELECT ON r6d39_privacy_results
  TO gurine_submission_api,gurine_control_api;

SET LOCAL ROLE gurine_submission_api;
INSERT INTO r6d39_privacy_results(operation,payload)
SELECT 'CREATE',ops.create_privacy_request_v2(
  jsonb_build_object(
    'privacyRequestId','6d390000-0000-4000-8000-000000000220',
    'requestType','CORRECTION','jurisdiction','KR',
    'identityProof',jsonb_build_object(
      'kind','RESPONSE_RECEIPT',
      'receiptId','6d390000-0000-4000-8000-000000000205',
      'possessionTokenHmac',
        pg_temp.r6d39_sha256_text('d3-source-possession')
    ),
    'scope',jsonb_build_object(
      'scopeKind','OBJECT_SET','objectRefs',jsonb_build_array(
        jsonb_build_object(
          'objectType','EVIDENCE',
          'objectId','6d390000-0000-4000-8000-000000000032'
        )
      ),'dateFrom',NULL,'dateTo',NULL,
      'includeDerivatives',true,'includeBackups',false
    ),
    'scopeCiphertextBase64',
      pg_temp.r6d39_base64(pg_temp.r6d39_envelope('d3_scope')),
    'scopeAadDigest',ops.r6d_nul5_sha256_v1(
      'ops.privacy_requests_v2','scope_ciphertext',
      '6d390000-0000-4000-8000-000000000220',
      'privacy-request-scope','1'
    ),
    'statementCiphertextBase64',
      pg_temp.r6d39_base64(pg_temp.r6d39_envelope('d3_statement')),
    'statementSha256',pg_temp.r6d39_sha256_text('d3 statement'),
    'statementAadDigest',ops.r6d_nul5_sha256_v1(
      'ops.privacy_requests_v2','statement_ciphertext',
      '6d390000-0000-4000-8000-000000000220',
      'privacy-request-statement','1'
    ),'encryptionKeyId','key-v1',
    'communicationSubjectId','6d390000-0000-4000-8000-000000000221',
    'communicationSubjectHmacKeyVersion','TEST_ONLY',
    'communicationSubjectLocale','ko-KR',
    'communicationEndpointId','6d390000-0000-4000-8000-000000000222',
    'communicationEndpointChannel','SMTP_EMAIL',
    'communicationEndpointHmac',
      pg_temp.r6d39_sha256_text('d3-source-endpoint-hmac'),
    'communicationEndpointHmacKeyVersion','TEST_ONLY',
    'communicationEndpointCiphertextBase64',
      pg_temp.r6d39_base64(pg_temp.r6d39_envelope('d3_contact')),
    'communicationEndpointEncryptionKeyId','key-v1',
    'communicationEndpointAadDigest',ops.r6d_nul5_sha256_v1(
      'intake.communication_endpoints','endpoint_ciphertext',
      '6d390000-0000-4000-8000-000000000222','email-address','1'
    ),'explicitVoiceConsentReceiptId',NULL,
    'receiptTokenHmac',pg_temp.r6d39_sha256_text('d3-token-hmac'),
    'receiptTokenSha256',pg_temp.r6d39_sha256_text('d3-token-sha'),
    'receiptTokenKeyVersion','TEST_ONLY'
  ),'6d390000-0000-4000-8000-000000000223',
  pg_temp.r6d39_sha256_text('d3-create-idempotency'),
  pg_temp.r6d39_sha256_text('d3-create-request')
);
RESET ROLE;

SELECT pg_temp.r6d39_assert(
  NULLIF(current_setting('gurine.response_request_id',true),'') IS NULL,
  'privacy-create-leaked-response-request-rls-scope'
);

DO $d3_create_authority_result$
DECLARE
  v_create jsonb;
BEGIN
  SELECT payload INTO STRICT v_create
  FROM r6d39_privacy_results WHERE operation='CREATE';
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*) FROM jsonb_object_keys(v_create))=3
    AND (v_create->>'replayed')::boolean=false
    AND (v_create#>>'{request,privacyRequestId}')::uuid=
      '6d390000-0000-4000-8000-000000000220'
    AND v_create#>>'{request,identityState}'='PENDING_VERIFICATION'
    AND EXISTS(
      SELECT 1
      FROM ops.privacy_identity_proof_authority_receipts_v1 AS authority
      WHERE authority.privacy_request_id=
          '6d390000-0000-4000-8000-000000000220'
        AND authority.proof_kind='RESPONSE_RECEIPT'
        AND authority.source_response_receipt_id=
          '6d390000-0000-4000-8000-000000000205'
        AND authority.source_endpoint_verification_id IS NULL
    ) AND EXISTS(
      SELECT 1
      FROM ops.privacy_request_scope_inventories_v1 AS inventory
      JOIN ops.privacy_request_scope_inventory_items_v1 AS item
        USING(scope_inventory_id)
      WHERE inventory.privacy_request_id=
          '6d390000-0000-4000-8000-000000000220'
        AND inventory.scope_kind='OBJECT_SET'
        AND inventory.object_item_count=1
        AND item.object_kind='EVIDENCE'
        AND item.object_id='6d390000-0000-4000-8000-000000000032'
    ),'privacy-create-response-receipt-authority'
  );
END
$d3_create_authority_result$;

-- The endpoint-link proof producer has an unresolved raw-proof ABI and is not
-- invented here.  For this consumer test only, install the exact immutable
-- ACTIVE endpoint/verification pre-state that such a future producer must
-- leave, then return immediately to normal trigger enforcement.
DO $d3_contact_verified_fixture$
DECLARE
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_proof_digest char(64):=
    pg_temp.r6d39_sha256_text('d3-contact-proof');
  v_receipt_digest char(64):=
    pg_temp.r6d39_sha256_text('d3-contact-verification-receipt');
  v_at timestamptz:=clock_timestamp()-interval '1 minute';
BEGIN
  SELECT * INTO STRICT v_request
  FROM ops.privacy_requests_v2
  WHERE id='6d390000-0000-4000-8000-000000000220';
  PERFORM set_config('session_replication_role','replica',true);
  UPDATE intake.communication_endpoints
  SET state='ACTIVE',verified_at=v_at,updated_at=v_at
  WHERE id=v_request.communication_endpoint_id;
  INSERT INTO intake.communication_endpoint_verifications(
    id,subject_id,subject_origin_binding_digest,endpoint_id,
    endpoint_version,endpoint_snapshot_digest,profile_session_id,
    challenge_kind,challenge_hash,nonce_hash,verification_binding_digest,
    state,attempt_count,max_attempts,version,proof_digest,receipt_digest,
    issued_at,expires_at,verified_at,consumed_at
  ) VALUES(
    '6d390000-0000-4000-8000-000000000224',
    v_request.communication_subject_id,
    v_request.communication_subject_origin_digest,
    v_request.communication_endpoint_id,v_request.communication_endpoint_version,
    v_request.communication_endpoint_digest,
    '6d390000-0000-4000-8000-000000000225','EMAIL_LINK',
    pg_temp.r6d39_sha256_text('d3-contact-challenge'),
    pg_temp.r6d39_sha256_text('d3-contact-nonce'),
    pg_temp.r6d39_sha256_text('d3-contact-binding'),'VERIFIED',1,3,1,
    v_proof_digest,v_receipt_digest,v_at-interval '5 minutes',
    v_at+interval '1 day',v_at,v_at
  );
  INSERT INTO intake.communication_endpoint_link_events(
    id,subject_id,subject_origin_binding_digest,endpoint_id,
    endpoint_sequence,profile_version,endpoint_version,endpoint_hmac,
    endpoint_digest,channel,state,change_kind,profile_session_id,
    verification_id,proof_digest,reason_code,endpoint_snapshot_digest,
    event_digest,audit_event_id,receipt_digest,occurred_at
  ) SELECT
    '6d390000-0000-4000-8000-000000000226',subject.id,
    subject.origin_binding_digest,endpoint.id,1,subject.profile_version,
    endpoint.version,endpoint.endpoint_hmac,endpoint.endpoint_digest,
    endpoint.channel,'ACTIVE','VERIFIED',
    '6d390000-0000-4000-8000-000000000225',
    '6d390000-0000-4000-8000-000000000224',v_proof_digest,
    'TEST_ONLY_PRIVACY_CONTACT_VERIFIED',endpoint.endpoint_digest,
    pg_temp.r6d39_sha256_text('d3-contact-link-event'),
    '6d390000-0000-4000-8000-000000000227',v_receipt_digest,v_at
  FROM intake.communication_subjects AS subject
  JOIN intake.communication_endpoints AS endpoint
    ON endpoint.subject_id=subject.id
  WHERE subject.id=v_request.communication_subject_id
    AND endpoint.id=v_request.communication_endpoint_id;
  PERFORM set_config('session_replication_role','origin',true);
END
$d3_contact_verified_fixture$;

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
) VALUES(
  '6d390000-0000-4000-8000-000000000228',
  '6d390000-0000-4000-8000-000000000023',
  pg_temp.r6d39_sha256_text('d3-verify-action'),
  pg_temp.r6d39_sha256_text('d3-verify-idempotency'),
  pg_temp.r6d39_sha256_text('d3-verify-step-up-token'),
  clock_timestamp()+interval '4 minutes',1,3,
  clock_timestamp()-interval '1 minute'
);
INSERT INTO ops.assertion_replay_guard(
  assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
) VALUES(
  'ACTOR','6d390000-0000-4000-8000-000000000229',
  'identity-api','control-api',
  pg_temp.r6d39_sha256_text('d3-verify-wire-request'),
  clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
);
INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
VALUES(
  'control:6d390000-0000-4000-8000-000000000020:transitionRetentionRequest',
  pg_temp.r6d39_sha256_text('d3-verify-idempotency'),
  pg_temp.r6d39_sha256_text('d3-verify-semantic-request'),
  clock_timestamp()+interval '1 hour'
);

SELECT set_config(
  'gurine.response_request_id',
  '6d390000-0000-4000-8000-0000000002ff',true
);
SET LOCAL ROLE gurine_control_api;
INSERT INTO r6d39_privacy_results(operation,payload)
SELECT 'VERIFY_IDENTITY',result.response_body
FROM ops.apply_control_addendum_command(
  'transitionRetentionRequest',jsonb_build_object(
    'transition','VERIFY_IDENTITY',
    'retentionRequestId','6d390000-0000-4000-8000-000000000220',
    'expectedDecisionVersion',0,
    'identityProofReceiptId',(
      SELECT identity_proof_receipt_id
      FROM ops.privacy_identity_proof_authority_receipts_v1
      WHERE privacy_request_id='6d390000-0000-4000-8000-000000000220'
    ),'reasonCode','TEST_ONLY_IDENTITY_VERIFIED',
    'reasonCiphertextBase64',
      pg_temp.r6d39_base64(pg_temp.r6d39_envelope('d3_verify_reason')),
    'reasonSha256',pg_temp.r6d39_sha256_text('d3 verify reason'),
    'transitionReceiptId','6d390000-0000-4000-8000-00000000022a',
    '_actorAssertionJti','6d390000-0000-4000-8000-000000000229',
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','privacy.requests.manage',
    '_actorAssertionRequestSha256',
      pg_temp.r6d39_sha256_text('d3-verify-wire-request'),
    '_actorActionDigest',pg_temp.r6d39_sha256_text('d3-verify-action'),
    '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000228',
    '_actorIdempotencyKeySha256',
      pg_temp.r6d39_sha256_text('d3-verify-idempotency'),
    '_actorRequestKeySha256',
      pg_temp.r6d39_sha256_text('d3-verify-idempotency')
  ),'6d390000-0000-4000-8000-000000000020',
  '6d390000-0000-4000-8000-000000000023',
  '6d390000-0000-4000-8000-00000000022b',
  pg_temp.r6d39_sha256_text('d3-verify-idempotency'),
  pg_temp.r6d39_sha256_text('d3-verify-semantic-request')
) AS result;
RESET ROLE;

SELECT pg_temp.r6d39_assert(
  current_setting('gurine.response_request_id',true)=
    '6d390000-0000-4000-8000-0000000002ff',
  'privacy-verify-did-not-restore-prior-rls-scope'
);
SELECT set_config('gurine.response_request_id','',true);

DO $d3_verify_identity_result$
DECLARE
  v_result jsonb;
  v_transition jsonb;
BEGIN
  SELECT payload INTO STRICT v_result
  FROM r6d39_privacy_results WHERE operation='VERIFY_IDENTITY';
  v_transition:=v_result->'transition';
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*) FROM jsonb_object_keys(v_result))=11
    AND (SELECT count(*) FROM jsonb_object_keys(v_transition))=24
    AND v_result->>'status'='COMPLETED'
    AND v_transition->>'transition'='VERIFY_IDENTITY'
    AND v_transition->>'state'='RECEIVED'
    AND (v_transition->>'decisionVersion')::bigint=1
    AND (v_transition->>'replayed')::boolean=false,
    'privacy-verify-result-shape'
  );
  PERFORM pg_temp.r6d39_assert(
    EXISTS(
      SELECT 1
      FROM ops.privacy_request_transition_receipts_v2 AS transition
      JOIN ops.privacy_request_identity_receipts_v2 AS identity
        ON identity.identity_receipt_id=transition.identity_receipt_id
       AND identity.receipt_digest=transition.identity_receipt_digest
      JOIN ops.privacy_request_notice_receipts_v2 AS notice
        ON notice.notice_receipt_id=transition.notice_receipt_id
       AND notice.receipt_digest=transition.notice_receipt_digest
      JOIN ops.privacy_identity_proof_consumption_receipts_v1 AS consumption
        ON consumption.transition_receipt_id=transition.transition_receipt_id
      WHERE transition.transition_receipt_id=
          '6d390000-0000-4000-8000-00000000022a'
        AND transition.receipt_payload->>'actorAssertionRequestDigest'=
          pg_temp.r6d39_sha256_text('d3-verify-wire-request')
        AND transition.event_receipt_digest=
          ops.r6d_outbox_envelope_digest_v1(transition.event_receipt_id)
        AND identity.event_receipt_digest=
          ops.r6d_outbox_envelope_digest_v1(identity.event_receipt_id)
        AND notice.event_receipt_digest=
          ops.r6d_outbox_envelope_digest_v1(notice.event_receipt_id)
        AND consumption.receipt_payload->>'transitionReceiptDigest'=
          btrim(transition.receipt_digest)
    ) AND EXISTS(
      SELECT 1 FROM ops.privacy_requests_v2
      WHERE id='6d390000-0000-4000-8000-000000000220'
        AND identity_state='VERIFIED' AND state='RECEIVED'
        AND identity_verified_at IS NOT NULL AND due_at>identity_verified_at
    ) AND (
      SELECT num_nonnulls(
        response_status,response_body,resource_type,resource_id
      )=0
      FROM ops.idempotency_keys
      WHERE scope=
        'control:6d390000-0000-4000-8000-000000000020:transitionRetentionRequest'
        AND key_hash=pg_temp.r6d39_sha256_text('d3-verify-idempotency')
    ),'privacy-verify-persisted-receipt-graph'
  );
END
$d3_verify_identity_result$;

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
) VALUES(
  '6d390000-0000-4000-8000-00000000022c',
  '6d390000-0000-4000-8000-000000000023',
  pg_temp.r6d39_sha256_text('d3-start-review-action'),
  pg_temp.r6d39_sha256_text('d3-start-review-idempotency'),
  pg_temp.r6d39_sha256_text('d3-start-review-step-up-token'),
  clock_timestamp()+interval '4 minutes',1,3,
  clock_timestamp()-interval '1 minute'
);
INSERT INTO ops.assertion_replay_guard(
  assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
) VALUES(
  'ACTOR','6d390000-0000-4000-8000-00000000022d',
  'identity-api','control-api',
  pg_temp.r6d39_sha256_text('d3-start-review-wire-request'),
  clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
);
INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
VALUES(
  'control:6d390000-0000-4000-8000-000000000020:transitionRetentionRequest',
  pg_temp.r6d39_sha256_text('d3-start-review-idempotency'),
  pg_temp.r6d39_sha256_text('d3-start-review-semantic-request'),
  clock_timestamp()+interval '1 hour'
);

SET LOCAL ROLE gurine_control_api;
INSERT INTO r6d39_privacy_results(operation,payload)
SELECT 'START_REVIEW',result.response_body
FROM ops.apply_control_addendum_command(
  'transitionRetentionRequest',jsonb_build_object(
    'transition','START_REVIEW',
    'retentionRequestId','6d390000-0000-4000-8000-000000000220',
    'expectedDecisionVersion',1,
    'reasonCode','TEST_ONLY_REVIEW_STARTED',
    'reasonCiphertextBase64',
      pg_temp.r6d39_base64(pg_temp.r6d39_envelope('d3_review_reason')),
    'reasonSha256',pg_temp.r6d39_sha256_text('d3 review reason'),
    'transitionReceiptId','6d390000-0000-4000-8000-00000000022e',
    '_actorAssertionJti','6d390000-0000-4000-8000-00000000022d',
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','privacy.requests.manage',
    '_actorAssertionRequestSha256',
      pg_temp.r6d39_sha256_text('d3-start-review-wire-request'),
    '_actorActionDigest',
      pg_temp.r6d39_sha256_text('d3-start-review-action'),
    '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-00000000022c',
    '_actorIdempotencyKeySha256',
      pg_temp.r6d39_sha256_text('d3-start-review-idempotency'),
    '_actorRequestKeySha256',
      pg_temp.r6d39_sha256_text('d3-start-review-idempotency')
  ),'6d390000-0000-4000-8000-000000000020',
  '6d390000-0000-4000-8000-000000000023',
  '6d390000-0000-4000-8000-00000000022f',
  pg_temp.r6d39_sha256_text('d3-start-review-idempotency'),
  pg_temp.r6d39_sha256_text('d3-start-review-semantic-request')
) AS result;
RESET ROLE;

DO $d3_start_review_result$
DECLARE
  v_result jsonb;
  v_transition jsonb;
BEGIN
  SELECT payload INTO STRICT v_result
  FROM r6d39_privacy_results WHERE operation='START_REVIEW';
  v_transition:=v_result->'transition';
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*) FROM jsonb_object_keys(v_result))=11
    AND (SELECT count(*) FROM jsonb_object_keys(v_transition))=24
    AND v_result->>'status'='COMPLETED'
    AND v_transition->>'transition'='START_REVIEW'
    AND v_transition->>'state'='REVIEW'
    AND (v_transition->>'decisionVersion')::bigint=2
    AND (v_transition->>'replayed')::boolean=false,
    'privacy-start-review-result-shape'
  );
  PERFORM pg_temp.r6d39_assert(
    EXISTS(
      SELECT 1 FROM ops.privacy_requests_v2
      WHERE id='6d390000-0000-4000-8000-000000000220'
        AND request_type='CORRECTION' AND state='REVIEW'
        AND identity_state='VERIFIED' AND decision_version=2
    ) AND (
      SELECT num_nonnulls(
        response_status,response_body,resource_type,resource_id
      )=0
      FROM ops.idempotency_keys
      WHERE scope=
        'control:6d390000-0000-4000-8000-000000000020:transitionRetentionRequest'
        AND key_hash=
          pg_temp.r6d39_sha256_text('d3-start-review-idempotency')
    ),'privacy-start-review-persisted-state'
  );
END
$d3_start_review_result$;

CREATE TEMP TABLE r6d39_correction_target_before(
  evidence_id uuid PRIMARY KEY,
  row_data jsonb NOT NULL
) ON COMMIT DROP;
INSERT INTO r6d39_correction_target_before(evidence_id,row_data)
SELECT id,to_jsonb(evidence)
FROM editorial.evidence AS evidence
WHERE id='6d390000-0000-4000-8000-000000000032';

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
) VALUES(
  '6d390000-0000-4000-8000-000000000230',
  '6d390000-0000-4000-8000-000000000023',
  pg_temp.r6d39_sha256_text('d3-correction-action'),
  pg_temp.r6d39_sha256_text('d3-correction-idempotency'),
  pg_temp.r6d39_sha256_text('d3-correction-step-up-token'),
  clock_timestamp()+interval '4 minutes',1,3,
  clock_timestamp()-interval '1 minute'
);
INSERT INTO ops.assertion_replay_guard(
  assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
) VALUES(
  'ACTOR','6d390000-0000-4000-8000-000000000231',
  'identity-api','control-api',
  pg_temp.r6d39_sha256_text('d3-correction-wire-request'),
  clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
);
INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
VALUES(
  'control:6d390000-0000-4000-8000-000000000020:createPrivacyCorrectionPlan',
  pg_temp.r6d39_sha256_text('d3-correction-idempotency'),
  pg_temp.r6d39_sha256_text('d3-correction-semantic-request'),
  clock_timestamp()+interval '1 hour'
);

CREATE TEMP TABLE r6d39_correction_unsupported_result(
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
  error_state text,
  error_message text,
  plan_count bigint NOT NULL,
  audit_count bigint NOT NULL,
  outbox_count bigint NOT NULL
) ON COMMIT DROP;
INSERT INTO r6d39_correction_unsupported_result(
  plan_count,audit_count,outbox_count
) SELECT
  (SELECT count(*) FROM ops.privacy_correction_plans_v1),
  (SELECT count(*) FROM ops.audit_events),
  (SELECT count(*) FROM ops.outbox);
GRANT SELECT,UPDATE ON r6d39_correction_unsupported_result
  TO gurine_control_api;

SET LOCAL ROLE gurine_control_api;
DO $d3_correction_plan_unsupported$
DECLARE
  v_state text;
  v_message text;
BEGIN
  BEGIN
    PERFORM *
    FROM ops.apply_control_addendum_command(
      'createPrivacyCorrectionPlan',jsonb_build_object(
        'retentionRequestId','6d390000-0000-4000-8000-000000000220',
        'expectedDecisionVersion',2,'targetObjectType','EVIDENCE',
        'targetObjectId','6d390000-0000-4000-8000-000000000032',
        'fieldPath','/title',
        'currentValueDigest',pg_temp.r6d39_sha256_text('d3-current-title'),
        'evidenceIds',jsonb_build_array(
          '6d390000-0000-4000-8000-000000000032'
        ),'reason','TEST_ONLY verified correction evidence',
        '_correctionPlanId','6d390000-0000-4000-8000-000000000232',
        'requestedValueCiphertextBase64',pg_temp.r6d39_base64(
          pg_temp.r6d39_envelope('d3_requested_value')
        ),'requestedValueSha256',
          pg_temp.r6d39_sha256_text('TEST_ONLY corrected title'),
        '_actorAssertionJti','6d390000-0000-4000-8000-000000000231',
        '_actorAssuranceLevel','STEP_UP',
        '_actorEffectiveCapability','privacy.requests.manage',
        '_actorAssertionRequestSha256',
          pg_temp.r6d39_sha256_text('d3-correction-wire-request'),
        '_actorActionDigest',pg_temp.r6d39_sha256_text('d3-correction-action'),
        '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000230',
        '_actorIdempotencyKeySha256',
          pg_temp.r6d39_sha256_text('d3-correction-idempotency'),
        '_actorRequestKeySha256',
          pg_temp.r6d39_sha256_text('d3-correction-idempotency')
      ),'6d390000-0000-4000-8000-000000000020',
      '6d390000-0000-4000-8000-000000000023',
      '6d390000-0000-4000-8000-000000000233',
      pg_temp.r6d39_sha256_text('d3-correction-idempotency'),
      pg_temp.r6d39_sha256_text('d3-correction-semantic-request')
    );
    RAISE EXCEPTION 'privacy correction unsupported call unexpectedly passed';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state=RETURNED_SQLSTATE,
      v_message=MESSAGE_TEXT;
  END;
  UPDATE r6d39_correction_unsupported_result
  SET error_state=v_state,error_message=v_message;
END
$d3_correction_plan_unsupported$;
RESET ROLE;

DO $d3_correction_plan_unsupported_result$
DECLARE
  v_result r6d39_correction_unsupported_result%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_result
  FROM r6d39_correction_unsupported_result;
  PERFORM pg_temp.r6d39_assert(
    v_result.error_state='0A000'
    AND v_result.error_message='PRIVACY_CORRECTION_TARGET_UNSUPPORTED'
    AND (SELECT count(*) FROM ops.privacy_correction_plans_v1)=
      v_result.plan_count
    AND (SELECT count(*) FROM ops.audit_events)=v_result.audit_count
    AND (SELECT count(*) FROM ops.outbox)=v_result.outbox_count
    AND (SELECT row_data=to_jsonb(evidence)
         FROM r6d39_correction_target_before AS before
         JOIN editorial.evidence AS evidence
           ON evidence.id=before.evidence_id)
    AND (
      SELECT num_nonnulls(
        response_status,response_body,resource_type,resource_id
      )=0
      FROM ops.idempotency_keys
      WHERE scope=
        'control:6d390000-0000-4000-8000-000000000020:createPrivacyCorrectionPlan'
        AND key_hash=pg_temp.r6d39_sha256_text('d3-correction-idempotency')
    ),
    'privacy-correction-unsupported-zero-write:'||to_jsonb(v_result)::text
  );
END
$d3_correction_plan_unsupported_result$;

CREATE FUNCTION pg_temp.r6d39_privacy_exchange_fingerprint()
RETURNS char(64)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,pg_temp
AS $fingerprint$
  SELECT pg_temp.r6d39_sha256_json(jsonb_build_object(
    'tokens',(SELECT COALESCE(jsonb_agg(to_jsonb(token)
      ORDER BY token.token_id),'[]'::jsonb)
      FROM ops.privacy_request_receipt_tokens_v2 AS token),
    'sessions',(SELECT COALESCE(jsonb_agg(to_jsonb(session)
      ORDER BY session.id),'[]'::jsonb)
      FROM intake.submission_sessions AS session),
    'idempotency',(SELECT COALESCE(jsonb_agg(to_jsonb(claim)
      ORDER BY claim.scope,claim.key_hash),'[]'::jsonb)
      FROM ops.idempotency_keys AS claim),
    'audit',(SELECT COALESCE(jsonb_agg(to_jsonb(audit)
      ORDER BY audit.id),'[]'::jsonb)
      FROM ops.audit_events AS audit),
    'outbox',(SELECT COALESCE(jsonb_agg(to_jsonb(event)
      ORDER BY event.id),'[]'::jsonb)
      FROM ops.outbox AS event)
  ))
$fingerprint$;
GRANT EXECUTE ON FUNCTION pg_temp.r6d39_privacy_exchange_fingerprint()
TO gurine_submission_api;

SET LOCAL ROLE gurine_submission_api;
INSERT INTO r6d39_privacy_results(operation,payload)
SELECT 'EXCHANGE',ops.exchange_privacy_request_receipt_token_v2(
  pg_temp.r6d39_sha256_text('d3-token-hmac'),
  pg_temp.r6d39_sha256_text('d3-exchange-session'),
  'public-web','6d390000-0000-4000-8000-000000000234',
  pg_temp.r6d39_sha256_text('d3-exchange-idempotency'),
  pg_temp.r6d39_sha256_text('d3-exchange-request')
);
INSERT INTO r6d39_privacy_results(operation,payload)
SELECT 'EXCHANGE_REPLAY',ops.exchange_privacy_request_receipt_token_v2(
  pg_temp.r6d39_sha256_text('d3-token-hmac'),
  pg_temp.r6d39_sha256_text('d3-exchange-session'),
  'public-web','6d390000-0000-4000-8000-000000000234',
  pg_temp.r6d39_sha256_text('d3-exchange-idempotency'),
  pg_temp.r6d39_sha256_text('d3-exchange-request')
);
RESET ROLE;

DO $d3_exchange_result$
DECLARE
  v_first jsonb;
  v_replay jsonb;
BEGIN
  SELECT payload INTO STRICT v_first
  FROM r6d39_privacy_results WHERE operation='EXCHANGE';
  SELECT payload INTO STRICT v_replay
  FROM r6d39_privacy_results WHERE operation='EXCHANGE_REPLAY';
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*) FROM jsonb_object_keys(v_first))=12
    AND (SELECT count(*) FROM jsonb_object_keys(v_replay))=12
    AND (v_first->>'replayed')::boolean=false
    AND (v_replay->>'replayed')::boolean=true
    AND v_replay-'replayed'=v_first-'replayed'
    AND v_first->>'sessionKind'='PRIVACY_REQUEST_RECEIPT'
    AND v_first->>'scopeType'='PRIVACY_REQUEST'
    AND (v_first->>'scopeId')::uuid=
      '6d390000-0000-4000-8000-000000000220'
    AND v_first->>'bffIssuer'='public-web'
    AND jsonb_array_length(v_first->'emittedEventIds')=1,
    'privacy-exchange-result-and-replay-shape'
  );
  PERFORM pg_temp.r6d39_assert(
    (SELECT count(*)=1 FROM intake.submission_sessions
     WHERE id=(v_first->>'sessionId')::uuid
       AND token_hash=pg_temp.r6d39_sha256_text('d3-exchange-session'))
    AND (SELECT count(*)=1 FROM ops.audit_events
         WHERE id=(v_first->>'auditEventId')::uuid)
    AND (SELECT count(*)=1 FROM ops.outbox
         WHERE id=(v_first->'emittedEventIds'->>0)::uuid)
    AND (SELECT count(*)=1 FROM ops.idempotency_keys
         WHERE scope='PRIVACY_RECEIPT_EXCHANGE_V2'
           AND key_hash=pg_temp.r6d39_sha256_text('d3-exchange-idempotency')
           AND response_status=200),
    'privacy-exchange-single-effect'
  );
END
$d3_exchange_result$;

CREATE TEMP TABLE r6d39_exchange_negative_boundaries(
  operation text PRIMARY KEY,
  rejected boolean NOT NULL DEFAULT false,
  error_state text,
  error_message text,
  before_fingerprint char(64) NOT NULL,
  after_fingerprint char(64)
) ON COMMIT DROP;
GRANT SELECT,UPDATE ON r6d39_exchange_negative_boundaries
TO gurine_submission_api;
INSERT INTO r6d39_exchange_negative_boundaries(operation,before_fingerprint)
VALUES
  ('CONSUMED_NEW_KEY',pg_temp.r6d39_privacy_exchange_fingerprint()),
  ('SAME_KEY_CHANGED_REQUEST',pg_temp.r6d39_privacy_exchange_fingerprint());

SET LOCAL ROLE gurine_submission_api;
DO $d3_exchange_consumed_new_key$
BEGIN
  PERFORM ops.exchange_privacy_request_receipt_token_v2(
    pg_temp.r6d39_sha256_text('d3-token-hmac'),
    pg_temp.r6d39_sha256_text('d3-exchange-new-session'),
    'public-web','6d390000-0000-4000-8000-000000000235',
    pg_temp.r6d39_sha256_text('d3-exchange-consumed-key'),
    pg_temp.r6d39_sha256_text('d3-exchange-consumed-request')
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_exchange_negative_boundaries
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM,
      after_fingerprint=pg_temp.r6d39_privacy_exchange_fingerprint()
  WHERE operation='CONSUMED_NEW_KEY';
END
$d3_exchange_consumed_new_key$;
DO $d3_exchange_same_key_changed_request$
BEGIN
  PERFORM ops.exchange_privacy_request_receipt_token_v2(
    pg_temp.r6d39_sha256_text('d3-token-hmac'),
    pg_temp.r6d39_sha256_text('d3-exchange-session'),
    'public-web','6d390000-0000-4000-8000-000000000234',
    pg_temp.r6d39_sha256_text('d3-exchange-idempotency'),
    pg_temp.r6d39_sha256_text('d3-exchange-changed-request')
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_exchange_negative_boundaries
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM,
      after_fingerprint=pg_temp.r6d39_privacy_exchange_fingerprint()
  WHERE operation='SAME_KEY_CHANGED_REQUEST';
END
$d3_exchange_same_key_changed_request$;
RESET ROLE;

DO $d3_exchange_negative_zero_write$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    (SELECT rejected AND error_state='PVT03'
       AND error_message='privacy_receipt_token_replayed'
       AND before_fingerprint=after_fingerprint
     FROM r6d39_exchange_negative_boundaries
     WHERE operation='CONSUMED_NEW_KEY')
    AND (SELECT rejected AND error_state='PVT05'
           AND error_message='privacy_receipt_exchange_idempotency_conflict'
           AND before_fingerprint=after_fingerprint
         FROM r6d39_exchange_negative_boundaries
         WHERE operation='SAME_KEY_CHANGED_REQUEST'),
    'privacy-exchange-negative-zero-write'
  );
END
$d3_exchange_negative_zero_write$;

-- The removed document-challenge branch must fail at the public create owner,
-- before any subject, endpoint, idempotency, audit, outbox, or request row can
-- survive the statement subtransaction.
CREATE TEMP TABLE r6d39_document_challenge_boundary(
  rejected boolean NOT NULL DEFAULT false,
  error_state text,
  error_message text
) ON COMMIT DROP;
GRANT SELECT,UPDATE ON r6d39_document_challenge_boundary
  TO gurine_submission_api;
INSERT INTO r6d39_document_challenge_boundary DEFAULT VALUES;

SET LOCAL ROLE gurine_submission_api;
DO $document_challenge_rejected$
DECLARE
  v_payload jsonb:=jsonb_build_object(
    'privacyRequestId','6d390000-0000-4000-8000-000000000101',
    'requestType','ACCESS','jurisdiction','KR',
    'identityProof',jsonb_build_object(
      'kind','IDENTITY_DOCUMENT_CHALLENGE',
      'challengeId','6d390000-0000-4000-8000-000000000102',
      'verificationReceiptId','6d390000-0000-4000-8000-000000000103',
      'verificationReceiptDigest',repeat('a',64)
    ),
    'scope',jsonb_build_object(
      'scopeKind','ALL_VERIFIED_SUBJECT_DATA','objectRefs','[]'::jsonb,
      'dateFrom',NULL,'dateTo',NULL,
      'includeDerivatives',true,'includeBackups',false
    ),
    'scopeCiphertextBase64','AQ==','scopeAadDigest',repeat('b',64),
    'statementCiphertextBase64','Ag==','statementSha256',repeat('c',64),
    'statementAadDigest',repeat('d',64),'encryptionKeyId','TEST_ONLY',
    'communicationSubjectId','6d390000-0000-4000-8000-000000000104',
    'communicationSubjectHmacKeyVersion','TEST_ONLY',
    'communicationSubjectLocale','ko-KR',
    'communicationEndpointId','6d390000-0000-4000-8000-000000000105',
    'communicationEndpointChannel','SMTP_EMAIL',
    'communicationEndpointHmac',repeat('e',64),
    'communicationEndpointHmacKeyVersion','TEST_ONLY',
    'communicationEndpointCiphertextBase64','Aw==',
    'communicationEndpointEncryptionKeyId','TEST_ONLY',
    'communicationEndpointAadDigest',repeat('f',64),
    'explicitVoiceConsentReceiptId',NULL,
    'receiptTokenHmac',repeat('1',64),
    'receiptTokenSha256',repeat('2',64),
    'receiptTokenKeyVersion','TEST_ONLY'
  );
BEGIN
  PERFORM ops.create_privacy_request_v2(
    v_payload,'6d390000-0000-4000-8000-000000000106',
    repeat('3',64),repeat('4',64)
  );
EXCEPTION WHEN OTHERS THEN
  UPDATE r6d39_document_challenge_boundary
  SET rejected=true,error_state=SQLSTATE,error_message=SQLERRM;
END
$document_challenge_rejected$;
RESET ROLE;

DO $document_challenge_zero_write$
BEGIN
  PERFORM pg_temp.r6d39_assert(
    EXISTS(
      SELECT 1
      FROM pg_constraint AS con
      WHERE con.conrelid='ops.privacy_requests_v2'::regclass
        AND con.contype='c'
        AND lower(pg_get_constraintdef(con.oid)) LIKE
          '%response_receipt%verified_endpoint%'
        AND lower(pg_get_constraintdef(con.oid)) NOT LIKE
          '%identity_document_challenge%'
    ),
    'privacy-identity-proof-accepted-set'
  );
  PERFORM pg_temp.r6d39_assert(
    (SELECT rejected AND error_state='PVT06'
       AND error_message='privacy_request_identity_proof_invalid'
     FROM r6d39_document_challenge_boundary),
    'document-challenge-create-error'
  );
  PERFORM pg_temp.r6d39_assert(
    NOT EXISTS(
      SELECT 1 FROM ops.idempotency_keys
      WHERE scope='PRIVACY_REQUEST_CREATE_V2' AND key_hash=repeat('3',64)
    )
    AND NOT EXISTS(
      SELECT 1 FROM ops.privacy_requests_v2
      WHERE id='6d390000-0000-4000-8000-000000000101'
    )
    AND NOT EXISTS(
      SELECT 1 FROM intake.communication_subjects
      WHERE id='6d390000-0000-4000-8000-000000000104'
    )
    AND NOT EXISTS(
      SELECT 1 FROM intake.communication_endpoints
      WHERE id='6d390000-0000-4000-8000-000000000105'
    ),
    'document-challenge-create-zero-write'
  );
END
$document_challenge_zero_write$;

DO $lease_owner_closure$
DECLARE
  v_person text:=pg_temp.r6d39_function_definition(
    'ops.execute_due_r6d_person_retention_job_v1(uuid,uuid,bigint)'
  );
  v_entity text:=pg_temp.r6d39_function_definition(
    'ops.execute_due_r6d_entity_retention_job_v1(uuid,uuid,bigint)'
  );
BEGIN
  PERFORM pg_temp.r6d39_assert(
    position('lease_owner is distinct from ''retention-worker''' IN v_person)=0
    AND position('lease_token is distinct from p_lease_token' IN v_person)>0
    AND position('fencing_token is distinct from p_fencing_token' IN v_person)>0
    AND position('lease_expires_at' IN v_person)>0
    AND position('jobleasetokensha256' IN v_person)>0
    AND position('''jobleasetoken'',' IN v_person)=0,
    'person-live-lease-owner-and-secretless-receipt'
  );
  PERFORM pg_temp.r6d39_assert(
    position('lease_owner is distinct from ''retention-worker''' IN v_entity)=0
    AND position('lease_token is distinct from p_lease_token' IN v_entity)>0
    AND position('fencing_token is distinct from p_fencing_token' IN v_entity)>0
    AND position('lease_expires_at' IN v_entity)>0
    AND position('jobleasetokensha256' IN v_entity)>0
    AND position('''jobleasetoken'',' IN v_entity)=0,
    'entity-live-lease-owner-and-secretless-receipt'
  );
END
$lease_owner_closure$;

DO $backup_no_automatic_deletion$
BEGIN
  PERFORM pg_temp.r6d39_assert(NOT EXISTS(
    SELECT 1
    FROM pg_proc AS proc
    JOIN pg_namespace AS namespace ON namespace.oid=proc.pronamespace
    WHERE namespace.nspname IN ('ops','core')
      AND proc.proname LIKE 'r6d%backup%'
      AND lower(pg_get_functiondef(proc.oid)) LIKE '%delete from core.%'
  ),'automatic-backup-physical-delete-owner-present');
  PERFORM pg_temp.r6d39_assert(NOT EXISTS(
    SELECT 1 FROM ops.jobs
    WHERE job_type IN ('R6D_BACKUP_DISPOSAL','R6D_BACKUP_PHYSICAL_DELETE')
  ),'automatic-backup-disposal-job-present');
END
$backup_no_automatic_deletion$;

-- Runner-only two-session seed.  Ordinary fixture execution never defines
-- this psql variable and still reaches the ROLLBACK below.  The dedicated
-- disposable-container runner may define it once, commit this TEST_ONLY graph,
-- execute the actual hold-vs-closure race, and immediately destroy the whole
-- container.  This is not a reusable projection or operating-policy seed.
\if :{?r6d39_commit_hold_race_seed}

CREATE TABLE public.r6d39_hold_race_inputs(
  operation text PRIMARY KEY,
  payload jsonb NOT NULL,
  actor_id uuid,
  session_id uuid,
  request_id uuid,
  idempotency_key char(64),
  request_digest char(64)
);
GRANT INSERT,SELECT ON public.r6d39_hold_race_inputs TO gurine_control_api;

INSERT INTO raw.source_documents(
  id,source_id,external_id,retrieved_at,content_type,content_sha256,
  content_size_bytes,object_key,status,prompt_injection_flags,metadata,
  record_status,asset_id,asset_revision
) VALUES(
  '6d390000-0000-4000-8000-000000000920',
  'r6d39-official-document','TEST_ONLY-OFFICIAL-DOCUMENT-D2-RACE',
  clock_timestamp()-interval '1 hour','application/pdf',repeat('6',64),256,
  'test-only/r6d39-official-document-d2-race.pdf','PARSED','[]'::jsonb,
  '{}'::jsonb,'CURRENT','6d390000-0000-4000-8000-000000000920',1
);
INSERT INTO editorial.evidence(
  id,case_id,evidence_type,title,source_document_id,source_locator,
  content_sha256,classification,verification_status,verified_by,verified_at,
  version,created_by
) VALUES(
  '6d390000-0000-4000-8000-000000000921',
  '6d390000-0000-4000-8000-000000000030','DOCUMENT',
  'TEST_ONLY D2 source-lock official document',
  '6d390000-0000-4000-8000-000000000920',
  'test-only/r6d39-official-document-d2-race.pdf#page=1',repeat('6',64),
  'PUBLIC','VERIFIED','6d390000-0000-4000-8000-000000000021',
  clock_timestamp()-interval '5 minutes',1,
  '6d390000-0000-4000-8000-000000000021'
);

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
) VALUES
  (
    '6d390000-0000-4000-8000-000000000900',
    '6d390000-0000-4000-8000-000000000023',repeat('1',64),repeat('2',64),
    pg_temp.r6d39_sha256_text('hold-race-classification-token'),
    clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  ),
  (
    '6d390000-0000-4000-8000-000000000901',
    '6d390000-0000-4000-8000-000000000053',repeat('5',64),repeat('6',64),
    pg_temp.r6d39_sha256_text('hold-race-closure-token'),
    clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  ),
  (
    '6d390000-0000-4000-8000-000000000902',
    '6d390000-0000-4000-8000-000000000023',repeat('9',64),repeat('a',64),
    pg_temp.r6d39_sha256_text('hold-race-placement-token'),
    clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  ),
  (
    '6d390000-0000-4000-8000-000000000922',
    '6d390000-0000-4000-8000-000000000023',repeat('d',64),repeat('e',64),
    pg_temp.r6d39_sha256_text('d2-source-race-attestation-token'),
    clock_timestamp()+interval '4 minutes',1,3,
    clock_timestamp()-interval '1 minute'
  );

INSERT INTO ops.assertion_replay_guard(
  assertion_type,jti,issuer,audience,request_digest,expires_at,consumed_at
) VALUES
  (
    'ACTOR','6d390000-0000-4000-8000-000000000903',
    'identity-api','control-api',repeat('4',64),
    clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
  ),
  (
    'ACTOR','6d390000-0000-4000-8000-000000000904',
    'identity-api','control-api',repeat('8',64),
    clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
  ),
  (
    'ACTOR','6d390000-0000-4000-8000-000000000905',
    'identity-api','control-api',repeat('c',64),
    clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
  ),
  (
    'ACTOR','6d390000-0000-4000-8000-000000000923',
    'identity-api','control-api',repeat('f',64),
    clock_timestamp()+interval '10 minutes',clock_timestamp()-interval '1 minute'
  );

INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at) VALUES
  (
    'control:6d390000-0000-4000-8000-000000000020:classifyEntityPersonhood',
    repeat('2',64),repeat('3',64),clock_timestamp()+interval '1 hour'
  ),
  (
    'control:6d390000-0000-4000-8000-000000000051:attestEntityMaterialUseClosure',
    repeat('6',64),repeat('7',64),clock_timestamp()+interval '1 hour'
  ),
  (
    'control:6d390000-0000-4000-8000-000000000020:attestOrganizationOfficialChannel',
    repeat('e',64),repeat('0',64),clock_timestamp()+interval '1 hour'
  );

INSERT INTO public.r6d39_hold_race_inputs(
  operation,payload,actor_id,session_id,request_id,idempotency_key,
  request_digest
)
SELECT 'CLASSIFICATION',ops.classify_r6d_entity_personhood_v1(
  jsonb_build_object(
    'entityKind','AGENCY',
    'entityId','6d390000-0000-4000-8000-000000000003',
    'classification','NATURAL_PERSON',
    'evidenceSourceLocator',
      'test-only/r6d39-hold-race#public-registration-form',
    'reason','TEST_ONLY human classification for hold race',
    'expectedEntityUpdatedAt',(
      SELECT updated_at FROM core.agencies
      WHERE id='6d390000-0000-4000-8000-000000000003'
    ),
    '_actorAssertionJti','6d390000-0000-4000-8000-000000000903',
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','users.manage',
    '_actorActionDigest',repeat('1',64),
    '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000900',
    '_actorIdempotencyKeySha256',repeat('2',64),
    '_actorRequestKeySha256',repeat('2',64),
    '_actorAssertionRequestSha256',repeat('4',64)
  ),
  '6d390000-0000-4000-8000-000000000020',
  '6d390000-0000-4000-8000-000000000023',
  '6d390000-0000-4000-8000-000000000906',repeat('2',64),repeat('3',64)
),
  '6d390000-0000-4000-8000-000000000020',
  '6d390000-0000-4000-8000-000000000023',
  '6d390000-0000-4000-8000-000000000906',repeat('2',64),repeat('3',64);

DO $d1_hold_race_authority_seed$
DECLARE
  v_entity_id constant uuid:='6d390000-0000-4000-8000-000000000003';
  v_actor_id constant uuid:='6d390000-0000-4000-8000-000000000020';
  v_session_id constant uuid:='6d390000-0000-4000-8000-000000000023';
  v_closure_actor_id constant uuid:='6d390000-0000-4000-8000-000000000051';
  v_closure_session_id constant uuid:='6d390000-0000-4000-8000-000000000053';
  v_snapshot jsonb;
  v_target jsonb;
  v_personhood_id uuid;
  v_conflict_id constant uuid:='6d390000-0000-4000-8000-00000000090a';
  v_binding text;
BEGIN
  SELECT (payload->>'receiptId')::uuid INTO STRICT v_personhood_id
  FROM public.r6d39_hold_race_inputs WHERE operation='CLASSIFICATION';
  v_snapshot:=ops.create_entity_retention_snapshot_v1(
    'AGENCY',v_entity_id,v_actor_id,
    '6d390000-0000-4000-8000-000000000907',repeat('d',64),repeat('e',64)
  );
  v_target:=jsonb_build_object(
    'targetKind','AGENCY_RETENTION_SNAPSHOT',
    'targetId',v_snapshot->>'snapshotId',
    'targetVersion',(v_snapshot->>'subjectVersion')::bigint,
    'targetDigest',v_snapshot->>'snapshotDigest','entityKind','AGENCY',
    'entityRetentionSnapshotId',v_snapshot->>'snapshotId',
    'entityRetentionSnapshotDigest',v_snapshot->>'snapshotDigest'
  );
  v_binding:='AGENCY_RETENTION_SNAPSHOT:'||(v_snapshot->>'snapshotId')||':'||
    (v_snapshot->>'subjectVersion')||':'||(v_snapshot->>'snapshotDigest')||
    ':placeLegalHold';
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
    v_conflict_id,v_actor_id,'AGENCY_RETENTION_SNAPSHOT',
    v_snapshot->>'snapshotId',(v_snapshot->>'subjectVersion')::bigint,
    (v_snapshot->>'snapshotDigest')::char(64),'placeLegalHold',NULL,
    'LEGAL_REVIEWER','{}'::uuid[],pg_temp.r6d39_sha256_text(
      'declarations:'||v_binding
    ),'{}'::jsonb,pg_temp.r6d39_sha256_text('findings:'||v_binding),
    pg_temp.r6d39_sha256_text('authorship:'||v_binding),
    pg_temp.r6d39_sha256_text('party:'||v_binding),
    pg_temp.r6d39_sha256_text('role:'||v_binding),
    pg_temp.r6d39_sha256_text('relationship:'||v_binding),
    pg_temp.r6d39_sha256_text('funding:'||v_binding),
    pg_temp.r6d39_sha256_text('policy:'||v_binding),'CLEAR','{}'::text[],0,
    clock_timestamp()-interval '1 second',clock_timestamp()+interval '10 minutes',
    'SERVICE','r6d39-hold-race',pg_temp.r6d39_sha256_text(
      'snapshot:'||v_binding
    ),pg_temp.r6d39_sha256_text('receipt:'||v_binding)
  );
  INSERT INTO public.r6d39_hold_race_inputs(
    operation,payload,actor_id,session_id,request_id,idempotency_key,
    request_digest
  ) VALUES(
    'HOLD',jsonb_build_object(
      'target',v_target,'scopeAtoms',jsonb_build_array('RETENTION'),
      'affectedIds',jsonb_build_array(v_entity_id),
      'authorityReference','TEST_ONLY R6d hold-race authority',
      'reasonCode','LEGAL_PRESERVATION_REQUIRED',
      'reason','TEST_ONLY preserve entity while closure races',
      'expiresAt',NULL,
      '_actorAssertionJti','6d390000-0000-4000-8000-000000000905',
      '_actorAssuranceLevel','STEP_UP',
      '_actorEffectiveCapability','review.legal',
      '_actorAssertionRequestSha256',repeat('c',64),
      '_actorActionDigest',repeat('9',64),
      '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000902',
      '_actorIdempotencyKeySha256',repeat('a',64),
      '_actorRequestKeySha256',repeat('a',64),
      '_requestId','6d390000-0000-4000-8000-000000000908',
      '_requestSha256',repeat('b',64),
      '_idempotencyKeySha256',repeat('a',64)
    ),v_actor_id,NULL,'6d390000-0000-4000-8000-000000000908',
    repeat('a',64),repeat('b',64)
  ),(
    'CLOSURE',jsonb_build_object(
      'entityKind','AGENCY','entityId',v_entity_id,
      'personhoodReceiptId',v_personhood_id,
      'reason','TEST_ONLY closure loses to active legal hold',
      'expectedEntityUpdatedAt',(
        SELECT updated_at FROM core.agencies WHERE id=v_entity_id
      ),
      '_actorAssertionJti','6d390000-0000-4000-8000-000000000904',
      '_actorAssuranceLevel','STEP_UP',
      '_actorEffectiveCapability','users.manage',
      '_actorActionDigest',repeat('5',64),
      '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000901',
      '_actorIdempotencyKeySha256',repeat('6',64),
      '_actorRequestKeySha256',repeat('6',64),
      '_actorAssertionRequestSha256',repeat('8',64)
    ),v_closure_actor_id,v_closure_session_id,
    '6d390000-0000-4000-8000-000000000909',repeat('6',64),repeat('7',64)
  );
END
$d1_hold_race_authority_seed$;

INSERT INTO public.r6d39_hold_race_inputs(
  operation,payload,actor_id,session_id,request_id,idempotency_key,
  request_digest
) VALUES(
  'D2_ATTEST',jsonb_build_object(
    'organizationKind','AGENCY',
    'organizationId','6d390000-0000-4000-8000-000000000001',
    'verificationMethod','OFFICIAL_DOCUMENT',
    'sourceId','6d390000-0000-4000-8000-000000000921',
    'expiresAt',clock_timestamp()+interval '1 day',
    'reason','TEST_ONLY D2 source-lock currentness revalidation',
    'expectedAuthorityVersion',1,
    '_actorAssertionJti','6d390000-0000-4000-8000-000000000923',
    '_actorAssertionRequestSha256',repeat('f',64),
    '_actorAssuranceLevel','STEP_UP',
    '_actorEffectiveCapability','responses.review',
    '_actorActionDigest',repeat('d',64),
    '_actorStepUpAuthorizationId','6d390000-0000-4000-8000-000000000922',
    '_actorIdempotencyKeySha256',repeat('e',64),
    '_actorRequestKeySha256',repeat('e',64)
  ),'6d390000-0000-4000-8000-000000000020',
  '6d390000-0000-4000-8000-000000000023',
  '6d390000-0000-4000-8000-000000000924',repeat('e',64),repeat('0',64)
);

COMMIT;
\quit
\endif

ROLLBACK;
