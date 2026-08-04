BEGIN;

DO $f3_disposable_database_guard$
BEGIN
  IF current_database()<>'gurine_control_test' THEN
    RAISE EXCEPTION 'f3_fixture_requires_disposable_control_database';
  END IF;
END
$f3_disposable_database_guard$;

DO $f3_source_official_url_view_contract$
DECLARE
  v_owner text;
  v_options text[];
BEGIN
  SELECT pg_get_userbyid(relation.relowner),relation.reloptions
  INTO STRICT v_owner,v_options
  FROM pg_class AS relation
  JOIN pg_namespace AS namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public'
    AND relation.relname='source_official_urls'
    AND relation.relkind='v';
  IF v_owner<>'gurine_migrator'
     OR NOT COALESCE('security_barrier=true'=ANY(v_options),false)
     OR NOT has_table_privilege(
       'gurine_public_api','public.source_official_urls','SELECT'
     ) THEN
    RAISE EXCEPTION 'f3_source_official_url_view_contract_invalid';
  END IF;
END
$f3_source_official_url_view_contract$;

INSERT INTO ops.source_registry(
  source_id,display_name,connector_type,owner_team,enabled,schedule_cron,
  base_url,legal_status,configuration
) VALUES
  (
    'f3-test-only-approved-active','F3 TEST_ONLY approved active','HTTP','TEST',
    true,'0 * * * *','https://approved.example/f3','APPROVED','{}'::jsonb
  ),
  (
    'f3-test-only-approved-inactive','F3 TEST_ONLY approved inactive','HTTP','TEST',
    false,'0 * * * *','https://inactive.example/f3','APPROVED','{}'::jsonb
  ),
  (
    'f3-test-only-blocked-active','F3 TEST_ONLY blocked active','HTTP','TEST',
    true,'0 * * * *','https://blocked.example/f3','BLOCKED','{}'::jsonb
  );

SET LOCAL ROLE gurine_public_api;
DO $f3_source_official_url_view_role_filter$
DECLARE
  v_visible integer;
  v_hidden_visible integer;
  v_private_denied boolean:=false;
BEGIN
  SELECT count(*) INTO v_visible
  FROM public.source_official_urls
  WHERE source_id='f3-test-only-approved-active'
    AND official_url='https://approved.example/f3';
  SELECT count(*) INTO v_hidden_visible
  FROM public.source_official_urls
  WHERE source_id IN (
    'f3-test-only-approved-inactive','f3-test-only-blocked-active'
  );
  BEGIN
    PERFORM source_id FROM ops.source_registry
    WHERE source_id='f3-test-only-approved-active';
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_private_denied:=true;
  END;
  IF v_visible<>1 OR v_hidden_visible<>0 OR NOT v_private_denied THEN
    RAISE EXCEPTION
      'f3_source_official_url_role_filter_invalid visible=% hidden_visible=% private_denied=%',
      v_visible,v_hidden_visible,v_private_denied;
  END IF;
  RAISE NOTICE
    'F3_SOURCE_OFFICIAL_URL_VIEW_ROLE_FILTER_PASS visible=% hidden=% private_denied=%',
    v_visible,2,v_private_denied;
END
$f3_source_official_url_view_role_filter$;
RESET ROLE;

-- TEST_ONLY: `테스트인` is a deliberately synthetic natural-person name.
DO $f3_archive_source_url_parity$
DECLARE
  v_payload jsonb:=jsonb_build_object(
    'schema_version','1.0.0','slug','test-only-archive',
    'title','계약 검토','summary','가상 자료','non_conclusion','확정 판단 아님',
    'sections',jsonb_build_array(jsonb_build_object(
      'heading','확인 내용','blocks',jsonb_build_array(jsonb_build_object(
        'type','TABLE','text',NULL,'data',jsonb_build_object('담당','테스트인 전 장관')
      ))
    )),'claims',jsonb_build_array(jsonb_build_object('text_ko','계약 사실')),
    'evidence',jsonb_build_array(jsonb_build_object(
      'summary','공식 문서','public_excerpt','테스트인 서명',
      'source',jsonb_build_object(
        'source_url','https://official.example/contracts/:대표이사-테스트인',
        'locator',jsonb_build_object('value','3쪽')
      )
    )),'subjects',jsonb_build_array(jsonb_build_object('display_name','가상 기관')),
    'methodology',jsonb_build_object(
      'limitations',jsonb_build_array('기간 한계'),
      'calculation',jsonb_build_object('설명','자료 비교')
    ),'responses',jsonb_build_array(jsonb_build_object(
      'party','가상 기관','display_text','추가 확인 중'
    )),'corrections',jsonb_build_array(jsonb_build_object('summary','금액 정정')),
    'review_summary',jsonb_build_object('legal_reviewed',false)
  );
  v_present_digest text;
  v_absent_digest text;
BEGIN
  v_present_digest:=btrim(editorial.r6d_public_text_sha256_v1(v_payload));
  v_absent_digest:=btrim(editorial.r6d_public_text_sha256_v1(
    v_payload#-'{evidence,0,source,source_url}'
  ));
  IF v_present_digest<>
       '568451e18206560b96ad3bd078ea2eb80c9f653f1ee7eec23b3dd4562034e4df'
     OR v_absent_digest<>
       'cc27a6ec726d867c3fff7b026cd821bcda6fe9aacd8a64e93af6f8d7e15e7ef9'
     OR editorial.r6d_json_pointer_text_v1(
       v_payload,'/evidence/0/source/source_url'
     )<>'https://official.example/contracts/:대표이사-테스트인'
     OR btrim(editorial.r6d_public_text_sha256_v1(jsonb_set(
       v_payload,'{evidence,0,source,source_url}',
       to_jsonb('https://official.example/contracts/revised'::text)
     )))=v_present_digest THEN
    RAISE EXCEPTION 'f3_archive_source_url_rust_db_parity_invalid';
  END IF;
  RAISE NOTICE
    'F3_ARCHIVE_SOURCE_URL_RUST_DB_PARITY_PASS present_digest=% absent_digest=%',
    v_present_digest,v_absent_digest;
END
$f3_archive_source_url_parity$;

DO $f3_archive_source_url_natural_person_blocked$
DECLARE
  v_payload jsonb:=jsonb_build_object(
    'caseId','148b09d5-aa28-5351-b471-9ef333a3e410',
    'reviewSnapshotId','04935ea9-f702-552c-aedc-425382a2d2b3',
    'publicationState','PUBLISHED_ANOMALY',
    'schema_version','1.0.0','slug','test-only-archive',
    'title','계약 검토','summary','가상 자료','non_conclusion','확정 판단 아님',
    'sections',jsonb_build_array(jsonb_build_object(
      'heading','확인 내용','blocks',jsonb_build_array(jsonb_build_object(
        'type','TABLE','text',NULL,'data',jsonb_build_object('설명','자료 비교')
      ))
    )),'claims',jsonb_build_array(jsonb_build_object('text_ko','계약 사실')),
    'evidence',jsonb_build_array(jsonb_build_object(
      'summary','공식 문서','public_excerpt','서명 확인',
      'source',jsonb_build_object(
        'source_url','https://official.example/contracts/:대표이사-테스트인',
        'locator',jsonb_build_object('value','3쪽')
      )
    )),'subjects',jsonb_build_array(jsonb_build_object('display_name','가상 기관')),
    'methodology',jsonb_build_object(
      'limitations',jsonb_build_array('기간 한계'),
      'calculation',jsonb_build_object('설명','자료 비교')
    ),'responses',jsonb_build_array(jsonb_build_object(
      'party','가상 기관','display_text','추가 확인 중'
    )),'corrections',jsonb_build_array(jsonb_build_object('summary','금액 정정')),
    'review_summary',jsonb_build_object('legal_reviewed',false)
  );
  v_registered_set_sha text;
  v_scan jsonb;
  v_request jsonb;
  v_result jsonb;
  v_action_sha text;
  v_idempotency_sha text;
BEGIN
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
    COALESCE(jsonb_agg(entry ORDER BY canonical),'[]'::jsonb)
  ),'sha256'),'hex')
  INTO v_registered_set_sha
  FROM (
    SELECT jsonb_build_object(
      'contextId',person.context_id,
      'personNameDigest',btrim(person.person_name_digest),
      'personNodeId',person.person_node_id,
      'topologyDigest',btrim(person.topology_digest)
    ) AS entry,
    ops.canonical_jsonb_v1(jsonb_build_object(
      'contextId',person.context_id,
      'personNameDigest',btrim(person.person_name_digest),
      'personNodeId',person.person_node_id,
      'topologyDigest',btrim(person.topology_digest)
    )) AS canonical
    FROM core.list_publication_person_names_v1() AS person
  ) AS registered;
  SELECT jsonb_build_object(
    'rulesetVersion',policy_payload->>'scannerRulesetVersion',
    'rulesetSha256',policy_payload->>'scannerRulesetSha256',
    'publicTextSha256',btrim(editorial.r6d_public_text_sha256_v1(v_payload)),
    'registeredNameSetSha256',v_registered_set_sha,
    'findings','[]'::jsonb
  ) INTO STRICT v_scan
  FROM editorial.named_person_publication_policies
  WHERE policy_version='r6d-named-person-publication-v3' AND active;
  v_action_sha:=encode(extensions.digest(
    convert_to('f3-archive-source-url-action','UTF8'),'sha256'
  ),'hex');
  v_idempotency_sha:=encode(extensions.digest(
    convert_to('f3-archive-source-url-idempotency','UTF8'),'sha256'
  ),'hex');
  v_request:=jsonb_build_object(
    'caseId','148b09d5-aa28-5351-b471-9ef333a3e410',
    'reviewSnapshotId','04935ea9-f702-552c-aedc-425382a2d2b3',
    'publicationState','PUBLISHED_ANOMALY','guardContext','PREVIEW',
    'publicPayload',v_payload,
    'publicPayloadSha256',encode(extensions.digest(
      ops.canonical_jsonb_v1(v_payload),'sha256'),'hex'),
    'scan',v_scan,'legalOverride',NULL,
    '_actorId','11111111-1111-4111-8111-111111111111',
    '_actorAssertionJti','f3000000-0000-4000-8000-000000000031',
    '_actorAssuranceLevel','ACTIVE_SESSION',
    '_actorEffectiveCapability','publication.preview',
    '_actorActionDigest',v_action_sha,
    '_actorStepUpAuthorizationId',NULL,
    '_actorIdempotencyKeySha256',v_idempotency_sha,
    '_actorRequestKeySha256',v_idempotency_sha,
    '_requestId','f3000000-0000-4000-8000-000000000032',
    '_idempotencyKeySha256',v_idempotency_sha,
    '_requestSha256',repeat('0',64)
  );
  v_request:=jsonb_set(v_request,'{_requestSha256}',to_jsonb(
    encode(extensions.digest(ops.canonical_jsonb_v1(
      v_request-'_requestSha256'
    ),'sha256'),'hex')
  ));
  v_result:=editorial.record_named_person_publication_assessment_v1(v_request);
  IF v_scan->'findings'<>'[]'::jsonb
     OR v_result->>'assessmentOutcome'<>'BLOCKED'
     OR v_result->>'legalReviewRequired'<>'true'
     OR NOT EXISTS(
       SELECT 1 FROM editorial.named_person_publication_findings AS finding
       WHERE finding.assessment_id=(v_result->>'assessmentId')::uuid
         AND finding.detector_kind='TITLE_ADJACENT_KOREAN_NAME'
         AND finding.json_pointer='/evidence/0/source/source_url'
         AND finding.matched_text_sha256=encode(extensions.digest(convert_to(
           editorial.r6d_utf16_slice_v1(
             editorial.r6d_json_pointer_text_v1(
               v_payload,'/evidence/0/source/source_url'
             ),finding.start_utf16,finding.end_utf16
           ),'UTF8'
         ),'sha256'),'hex')
     ) THEN
    RAISE EXCEPTION 'f3_archive_source_url_natural_person_not_blocked';
  END IF;
  RAISE NOTICE
    'F3_ARCHIVE_SOURCE_URL_NATURAL_PERSON_BLOCKED_PASS outcome=% pointer=%',
    v_result->>'assessmentOutcome','/evidence/0/source/source_url';
END
$f3_archive_source_url_natural_person_blocked$;

ROLLBACK;
