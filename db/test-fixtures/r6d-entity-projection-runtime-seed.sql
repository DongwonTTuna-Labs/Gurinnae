\set ON_ERROR_STOP on

-- TEST_FIXTURE_ONLY: commit two already-reviewed historical authority graphs
-- so the real scheduler, workflow worker, and public projection worker can be
-- exercised in one disposable PostgreSQL database.  This fixture creates no
-- operating retention policy and requires the action-approved schedules from
-- r6d-approved-policy-authority.sql.
BEGIN;
SET LOCAL TIME ZONE 'UTC';

CREATE FUNCTION pg_temp.r6d_projection_sha256(p_value text)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT encode(
    extensions.digest(convert_to(p_value,'UTF8'),'sha256'
  ),'hex')::char(64)
$$;

DO $prerequisites$
DECLARE
  v_schedule_count bigint;
BEGIN
  SELECT count(*) INTO v_schedule_count
  FROM ops.record_class_schedules AS schedule
  WHERE schedule.record_class IN (
      'AGENCY_MASTER','AGENCY_IDENTIFIER','SUPPLIER_MASTER',
      'SUPPLIER_IDENTIFIER','ENTITY_ALIAS'
    )
    AND schedule.effective_at<=clock_timestamp()
    AND schedule.review_expires_at>clock_timestamp();
  IF v_schedule_count<>5
     OR NOT EXISTS(
       SELECT 1 FROM ops.users
       WHERE id='31400000-0000-4000-8000-000000000002'
         AND status='ACTIVE'
     )
     OR NOT EXISTS(
       SELECT 1 FROM ops.sessions
       WHERE id='31400000-0000-4000-8000-000000000021'
         AND user_id='31400000-0000-4000-8000-000000000002'
         AND revoked_at IS NULL AND expires_at>clock_timestamp()
     ) THEN
    RAISE EXCEPTION 'r6d_projection_fixture_authority_missing';
  END IF;
END
$prerequisites$;

INSERT INTO core.agencies(
  id,canonical_name,agency_type,jurisdiction,active,identity_status,
  created_at,updated_at
) VALUES(
  '31600000-0000-4000-8000-000000000001',
  'TEST_ONLY 공개 투영 자연인 기관','OTHER','KR-11 TEST_ONLY 주소',true,
  'VERIFIED','2010-01-01 00:00:00+00','2010-01-01 00:00:00+00'
);
INSERT INTO core.suppliers(
  id,canonical_name,business_status,identity_status,created_at,updated_at
) VALUES(
  '31600000-0000-4000-8000-000000000002',
  'TEST_ONLY 공개 투영 자연인 공급자','ACTIVE','VERIFIED',
  '2010-01-01 00:00:00+00','2010-01-01 00:00:00+00'
);
INSERT INTO core.agency_identifiers(
  id,agency_id,scheme,value,created_at
) VALUES(
  '31600000-0000-4000-8000-000000000011',
  '31600000-0000-4000-8000-000000000001','TEST_ONLY_REGISTRATION',
  'TEST-AGENCY-REGISTRATION-0001','2010-01-01 00:00:00+00'
);
INSERT INTO core.supplier_identifiers(
  id,supplier_id,scheme,value_hash,display_value,verification_status,created_at
) VALUES(
  '31600000-0000-4000-8000-000000000012',
  '31600000-0000-4000-8000-000000000002','TEST_ONLY_REGISTRATION',
  pg_temp.r6d_projection_sha256('TEST-SUPPLIER-REGISTRATION-0002'),
  'TEST-SUPPLIER-REGISTRATION-0002','VERIFIED',
  '2010-01-01 00:00:00+00'
);
INSERT INTO core.entity_aliases(
  id,entity_type,entity_id,alias,normalized_alias,created_at
) VALUES
  (
    '31600000-0000-4000-8000-000000000021','AGENCY',
    '31600000-0000-4000-8000-000000000001',
    'TEST_ONLY 기관 별칭','test only 기관 별칭','2010-01-01 00:00:00+00'
  ),
  (
    '31600000-0000-4000-8000-000000000022','SUPPLIER',
    '31600000-0000-4000-8000-000000000002',
    'TEST_ONLY 공급자 별칭','test only 공급자 별칭','2010-01-01 00:00:00+00'
  );

INSERT INTO public.agencies(
  id,name,agency_type,jurisdiction,coverage,descriptive_metrics,case_counts,
  updated_at
) VALUES(
  '31600000-0000-4000-8000-000000000001',
  'TEST_ONLY 공개 투영 자연인 기관','OTHER','KR-11 TEST_ONLY 공개 주소',
  '{}'::jsonb,'{}'::jsonb,'{}'::jsonb,'2010-01-01 00:00:00+00'
);
INSERT INTO public.suppliers(
  id,name,business_status,coverage,descriptive_metrics,case_counts,
  identity_warnings,updated_at
) VALUES(
  '31600000-0000-4000-8000-000000000002',
  'TEST_ONLY 공개 투영 자연인 공급자','ACTIVE','{}'::jsonb,'{}'::jsonb,
  '{}'::jsonb,'[]'::jsonb,'2010-01-01 00:00:00+00'
);

INSERT INTO ops.step_up_authorizations(
  id,session_id,action_digest,idempotency_key_sha256,
  authorization_token_hash,expires_at,assertion_issue_count,
  max_assertion_issues,last_issued_at
)
SELECT fixture.id,'31400000-0000-4000-8000-000000000021',
  pg_temp.r6d_projection_sha256(fixture.label||':action'),
  pg_temp.r6d_projection_sha256(fixture.label||':idempotency'),
  pg_temp.r6d_projection_sha256(fixture.label||':token'),
  '2099-01-01 00:00:00+00',1,3,clock_timestamp()
FROM (VALUES
  ('31600000-0000-4000-8000-000000000121'::uuid,'agency-personhood'),
  ('31600000-0000-4000-8000-000000000122'::uuid,'agency-closure'),
  ('31600000-0000-4000-8000-000000000123'::uuid,'supplier-personhood'),
  ('31600000-0000-4000-8000-000000000124'::uuid,'supplier-closure')
) AS fixture(id,label);

CREATE FUNCTION pg_temp.seed_r6d_projection_entity_authority(
  p_entity_kind text,
  p_entity_id uuid,
  p_personhood_receipt_id uuid,
  p_closure_receipt_id uuid,
  p_personhood_step_up_id uuid,
  p_closure_step_up_id uuid,
  p_personhood_assertion_jti uuid,
  p_closure_assertion_jti uuid,
  p_personhood_request_id uuid,
  p_closure_request_id uuid
) RETURNS void
LANGUAGE plpgsql
AS $fixture$
DECLARE
  v_actor_id constant uuid:='31400000-0000-4000-8000-000000000002';
  v_session_id constant uuid:='31400000-0000-4000-8000-000000000021';
  v_entity_updated_at timestamptz;
  v_active_duration_seconds bigint;
  v_classified_at timestamptz;
  v_closure_at timestamptz;
  v_material jsonb;
  v_payload jsonb;
  v_canonical bytea;
  v_personhood_digest char(64);
  v_closure_digest char(64);
  v_audit_id uuid;
  v_outbox_id uuid;
  v_label text:=lower(p_entity_kind)||':'||p_entity_id::text;
BEGIN
  IF p_entity_kind='AGENCY' THEN
    SELECT agency.updated_at,schedule.active_duration_seconds
    INTO STRICT v_entity_updated_at,v_active_duration_seconds
    FROM core.agencies AS agency
    JOIN ops.record_class_schedules AS schedule
      ON schedule.id=agency.retention_schedule_id
     AND schedule.record_class=agency.retention_record_class
     AND schedule.schedule_digest=agency.retention_schedule_digest
    WHERE agency.id=p_entity_id;
  ELSIF p_entity_kind='SUPPLIER' THEN
    SELECT supplier.updated_at,schedule.active_duration_seconds
    INTO STRICT v_entity_updated_at,v_active_duration_seconds
    FROM core.suppliers AS supplier
    JOIN ops.record_class_schedules AS schedule
      ON schedule.id=supplier.retention_schedule_id
     AND schedule.record_class=supplier.retention_record_class
     AND schedule.schedule_digest=supplier.retention_schedule_digest
    WHERE supplier.id=p_entity_id;
  ELSE
    RAISE EXCEPTION 'r6d_projection_fixture_entity_kind_invalid';
  END IF;
  v_closure_at:=clock_timestamp()-make_interval(
    secs=>v_active_duration_seconds::double precision
  )-interval '2 days';
  v_classified_at:=v_closure_at-interval '1 day';

  v_audit_id:=ops.append_audit_event(
    'r6d-projection-fixture-personhood:'||v_label,
    'USER',v_actor_id::text,v_session_id,
    'r6d.entity_personhood.classify','Entity',p_entity_id::text,
    'sources.operate','SUCCESS','TEST_FIXTURE_ONLY',p_personhood_request_id,
    jsonb_build_object('fixture','r6d-entity-projection-runtime-seed')
  );
  v_payload:=jsonb_build_object(
    'schemaVersion','r6d-entity-personhood-classification-receipt.v1',
    'receiptId',p_personhood_receipt_id,'entityKind',p_entity_kind,
    'entityId',p_entity_id,'classification','NATURAL_PERSON',
    'classificationVersion',1,'entityUpdatedAt',v_entity_updated_at,
    'evidenceSourceLocatorDigest',pg_temp.r6d_projection_sha256(
      'test-only/r6d-projection/'||v_label||'#public-registration'
    ),
    'reasonDigest',pg_temp.r6d_projection_sha256(
      'TEST_FIXTURE_ONLY historical human classification:'||v_label
    ),
    'capabilityAuthorityDigest',pg_temp.r6d_projection_sha256(
      'TEST_FIXTURE_ONLY sources.operate authority:'||v_label
    ),
    'actorId',v_actor_id,'sessionId',v_session_id,
    'actorAssertionJti',p_personhood_assertion_jti,
    'actorAssertionRequestDigest',pg_temp.r6d_projection_sha256(
      'personhood-assertion-request:'||v_label
    ),
    'stepUpAuthorizationId',p_personhood_step_up_id,
    'stepUpReceiptDigest',pg_temp.r6d_projection_sha256(
      'personhood-step-up-receipt:'||v_label
    ),
    'requestId',p_personhood_request_id,
    'idempotencyKeySha256',pg_temp.r6d_projection_sha256(
      'personhood-idempotency:'||v_label
    ),
    'requestDigest',pg_temp.r6d_projection_sha256(
      'personhood-request:'||v_label
    ),
    'auditEventId',v_audit_id,'classifiedAt',v_classified_at
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_personhood_digest:=encode(
    extensions.digest(v_canonical,'sha256'),'hex'
  );
  v_outbox_id:=ops.enqueue_outbox(
    'r6d_entity_personhood',p_personhood_receipt_id::text,1,
    'entity.personhood_classified.v1',jsonb_build_object(
      'entityKind',p_entity_kind,'entityId',p_entity_id,
      'classification','NATURAL_PERSON',
      'evidenceSourceLocatorDigest',
        v_payload->>'evidenceSourceLocatorDigest',
      'receiptDigest',btrim(v_personhood_digest),
      'classifiedAt',v_classified_at
    ),v_classified_at
  );
  INSERT INTO ops.r6d_entity_personhood_classification_receipts_v1(
    receipt_id,entity_kind,entity_id,classification,classification_version,
    entity_updated_at,evidence_source_locator_digest,reason_digest,
    capability_authority_digest,actor_id,session_id,actor_assertion_jti,
    actor_assertion_request_digest,step_up_authorization_id,
    step_up_receipt_digest,request_id,idempotency_key_sha256,request_digest,
    audit_event_id,outbox_event_id,receipt_payload,receipt_canonical,
    receipt_digest,classified_at
  ) VALUES(
    p_personhood_receipt_id,p_entity_kind,p_entity_id,'NATURAL_PERSON',1,
    v_entity_updated_at,
    (v_payload->>'evidenceSourceLocatorDigest')::char(64),
    (v_payload->>'reasonDigest')::char(64),
    (v_payload->>'capabilityAuthorityDigest')::char(64),
    v_actor_id,v_session_id,p_personhood_assertion_jti,
    (v_payload->>'actorAssertionRequestDigest')::char(64),
    p_personhood_step_up_id,
    (v_payload->>'stepUpReceiptDigest')::char(64),p_personhood_request_id,
    (v_payload->>'idempotencyKeySha256')::char(64),
    (v_payload->>'requestDigest')::char(64),v_audit_id,v_outbox_id,v_payload,
    v_canonical,v_personhood_digest,v_classified_at
  );

  PERFORM set_config('gurine.r6d_entity_classification','1',true);
  IF p_entity_kind='AGENCY' THEN
    UPDATE core.agencies
    SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
        r6d_canonical_name_digest=pg_temp.r6d_projection_sha256(canonical_name),
        r6d_jurisdiction_digest=CASE WHEN jurisdiction IS NULL THEN NULL ELSE
          pg_temp.r6d_projection_sha256(jurisdiction) END,
        r6d_personhood_receipt_id=p_personhood_receipt_id,
        r6d_personhood_receipt_digest=v_personhood_digest
    WHERE id=p_entity_id;
    UPDATE core.agency_identifiers
    SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
        r6d_value_digest=pg_temp.r6d_projection_sha256(value)
    WHERE agency_id=p_entity_id;
  ELSE
    UPDATE core.suppliers
    SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
        r6d_canonical_name_digest=pg_temp.r6d_projection_sha256(canonical_name),
        r6d_personhood_receipt_id=p_personhood_receipt_id,
        r6d_personhood_receipt_digest=v_personhood_digest
    WHERE id=p_entity_id;
    UPDATE core.supplier_identifiers
    SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
        r6d_display_value_digest=CASE WHEN display_value IS NULL THEN NULL ELSE
          pg_temp.r6d_projection_sha256(display_value) END
    WHERE supplier_id=p_entity_id;
  END IF;
  UPDATE core.entity_aliases
  SET r6d_anonymization_state='NATURAL_PERSON_ACTIVE',
      r6d_alias_digest=pg_temp.r6d_projection_sha256(alias),
      r6d_normalized_alias_digest=
        pg_temp.r6d_projection_sha256(normalized_alias)
  WHERE entity_type=p_entity_kind AND entity_id=p_entity_id;
  PERFORM set_config('gurine.r6d_entity_classification','',true);

  IF p_entity_kind='AGENCY' THEN
    SELECT updated_at INTO STRICT v_entity_updated_at
    FROM core.agencies WHERE id=p_entity_id;
  ELSE
    SELECT updated_at INTO STRICT v_entity_updated_at
    FROM core.suppliers WHERE id=p_entity_id;
  END IF;
  v_material:=ops.r6d_entity_material_use_state_v1(
    p_entity_kind,p_entity_id,clock_timestamp()
  );
  IF (v_material->>'contractCount')::bigint<>0
     OR (v_material->>'publicationRevisionCount')::bigint<>0
     OR (v_material->>'openPublicationRevisionCount')::bigint<>0
     OR (v_material->>'legalHoldActive')::boolean THEN
    RAISE EXCEPTION 'r6d_projection_fixture_material_use_open';
  END IF;

  v_audit_id:=ops.append_audit_event(
    'r6d-projection-fixture-closure:'||v_label,
    'USER',v_actor_id::text,v_session_id,
    'r6d.entity_material_use.close','Entity',p_entity_id::text,
    'sources.operate','SUCCESS','TEST_FIXTURE_ONLY',p_closure_request_id,
    jsonb_build_object(
      'fixture','r6d-entity-projection-runtime-seed',
      'personhoodReceiptId',p_personhood_receipt_id
    )
  );
  v_payload:=jsonb_build_object(
    'schemaVersion','r6d-entity-material-use-closure-receipt.v1',
    'receiptId',p_closure_receipt_id,'entityKind',p_entity_kind,
    'entityId',p_entity_id,'closureVersion',1,
    'entityUpdatedAt',v_entity_updated_at,
    'personhoodReceiptId',p_personhood_receipt_id,
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
    'reasonDigest',pg_temp.r6d_projection_sha256(
      'TEST_FIXTURE_ONLY historical closure:'||v_label
    ),
    'capabilityAuthorityDigest',pg_temp.r6d_projection_sha256(
      'TEST_FIXTURE_ONLY sources.operate authority:'||v_label
    ),
    'actorId',v_actor_id,'sessionId',v_session_id,
    'actorAssertionJti',p_closure_assertion_jti,
    'actorAssertionRequestDigest',pg_temp.r6d_projection_sha256(
      'closure-assertion-request:'||v_label
    ),
    'stepUpAuthorizationId',p_closure_step_up_id,
    'stepUpReceiptDigest',pg_temp.r6d_projection_sha256(
      'closure-step-up-receipt:'||v_label
    ),
    'requestId',p_closure_request_id,
    'idempotencyKeySha256',pg_temp.r6d_projection_sha256(
      'closure-idempotency:'||v_label
    ),
    'requestDigest',pg_temp.r6d_projection_sha256(
      'closure-request:'||v_label
    ),
    'auditEventId',v_audit_id,'closureAt',v_closure_at,
    'attestedAt',v_closure_at
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_closure_digest:=encode(
    extensions.digest(v_canonical,'sha256'),'hex'
  );
  v_outbox_id:=ops.enqueue_outbox(
    'r6d_entity_material_use',p_closure_receipt_id::text,1,
    'entity.material_use_closed.v1',jsonb_build_object(
      'entityKind',p_entity_kind,'entityId',p_entity_id,
      'personhoodReceiptDigest',btrim(v_personhood_digest),
      'closureAt',v_closure_at,'lastContractEndAt',NULL,
      'linkedPublicationRevisionCount',0,
      'receiptDigest',btrim(v_closure_digest)
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
    p_closure_receipt_id,p_entity_kind,p_entity_id,1,v_entity_updated_at,
    p_personhood_receipt_id,v_personhood_digest,
    (v_material->>'contractCount')::bigint,
    (v_material->>'contractSetDigest')::char(64),NULL,NULL,
    (v_material->>'publicationRevisionCount')::bigint,
    (v_material->>'publicationRevisionSetDigest')::char(64),
    (v_material->>'openPublicationRevisionCount')::bigint,
    (v_material->>'legalHoldCoverageDigest')::char(64),
    (v_payload->>'reasonDigest')::char(64),
    (v_payload->>'capabilityAuthorityDigest')::char(64),
    v_actor_id,v_session_id,p_closure_assertion_jti,
    (v_payload->>'actorAssertionRequestDigest')::char(64),
    p_closure_step_up_id,(v_payload->>'stepUpReceiptDigest')::char(64),
    p_closure_request_id,(v_payload->>'idempotencyKeySha256')::char(64),
    (v_payload->>'requestDigest')::char(64),v_audit_id,v_outbox_id,v_payload,
    v_canonical,v_closure_digest,v_closure_at,v_closure_at
  );

  PERFORM set_config('gurine.r6d_entity_closure','1',true);
  IF p_entity_kind='AGENCY' THEN
    UPDATE core.agencies
    SET r6d_closure_receipt_id=p_closure_receipt_id,
        r6d_closure_receipt_digest=v_closure_digest
    WHERE id=p_entity_id;
  ELSE
    UPDATE core.suppliers
    SET r6d_closure_receipt_id=p_closure_receipt_id,
        r6d_closure_receipt_digest=v_closure_digest
    WHERE id=p_entity_id;
  END IF;
  PERFORM set_config('gurine.r6d_entity_closure','',true);
END
$fixture$;

SELECT pg_temp.seed_r6d_projection_entity_authority(
  'AGENCY','31600000-0000-4000-8000-000000000001',
  '31600000-0000-4000-8000-000000000101',
  '31600000-0000-4000-8000-000000000111',
  '31600000-0000-4000-8000-000000000121',
  '31600000-0000-4000-8000-000000000122',
  '31600000-0000-4000-8000-000000000131',
  '31600000-0000-4000-8000-000000000132',
  '31600000-0000-4000-8000-000000000141',
  '31600000-0000-4000-8000-000000000142'
);
SELECT pg_temp.seed_r6d_projection_entity_authority(
  'SUPPLIER','31600000-0000-4000-8000-000000000002',
  '31600000-0000-4000-8000-000000000102',
  '31600000-0000-4000-8000-000000000112',
  '31600000-0000-4000-8000-000000000123',
  '31600000-0000-4000-8000-000000000124',
  '31600000-0000-4000-8000-000000000133',
  '31600000-0000-4000-8000-000000000134',
  '31600000-0000-4000-8000-000000000143',
  '31600000-0000-4000-8000-000000000144'
);

DO $seed_result$
BEGIN
  IF (SELECT count(*) FROM ops.r6d_entity_personhood_classification_receipts_v1
      WHERE entity_id IN (
        '31600000-0000-4000-8000-000000000001',
        '31600000-0000-4000-8000-000000000002'
      ))<>2
     OR (SELECT count(*) FROM ops.r6d_entity_material_use_closure_receipts_v1
         WHERE entity_id IN (
           '31600000-0000-4000-8000-000000000001',
           '31600000-0000-4000-8000-000000000002'
         ))<>2
     OR NOT EXISTS(
       SELECT 1 FROM core.agencies
       WHERE id='31600000-0000-4000-8000-000000000001'
         AND r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
         AND canonical_name IS NOT NULL AND jurisdiction IS NOT NULL
     )
     OR NOT EXISTS(
       SELECT 1 FROM core.suppliers
       WHERE id='31600000-0000-4000-8000-000000000002'
         AND r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
         AND canonical_name IS NOT NULL
     ) THEN
    RAISE EXCEPTION 'r6d_projection_fixture_seed_invalid';
  END IF;
END
$seed_result$;

COMMIT;
