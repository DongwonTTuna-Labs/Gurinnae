-- R6d placeLegalHold target authority for the control-flow runtime.
--
-- This fixture creates no legal hold, placement receipt, target anchor,
-- conflict proof, or STEP_UP authorization.  The HTTP owner must create every
-- outcome.  It only prepares one stable resolver input for each member of the
-- closed ten-kind LegalHoldTarget union.
--
-- Load after 0038, the approved policy authority, and the research,
-- retention, and communication fixtures.  The communication fixture creates
-- the RESPONSE target through the real submission/materialization owners.

BEGIN;
SET LOCAL TIME ZONE 'UTC';

DO $database_guard$
BEGIN
  IF current_database()<>'gurine_control_test' THEN
    RAISE EXCEPTION 'r6d_legal_hold_fixture_database_forbidden'
      USING ERRCODE='55000';
  END IF;
END
$database_guard$;

-- CASE and EVIDENCE use a dedicated case which the generic operation sweep
-- never addresses.  The review snapshot is the CASE target digest authority.
INSERT INTO editorial.cases(
  id,public_slug,title,investigation_state,publication_state,summary,priority,
  version
) VALUES(
  'd61d1000-0000-4000-8000-000000000001',
  'r6d-legal-hold-target','R6d legal-hold target','INVESTIGATING',
  'NEVER_PUBLISHED','Dedicated immutable legal-hold target','LOW',1
)
ON CONFLICT DO NOTHING;

INSERT INTO editorial.review_snapshots(
  id,case_id,case_version,snapshot_sha256,snapshot_payload,
  automated_gate_results,unresolved_blockers,created_by
) VALUES(
  'd61d1000-0000-4000-8000-000000000002',
  'd61d1000-0000-4000-8000-000000000001',1,repeat('c',64),
  '{"fixture":"r6d-legal-hold-target"}'::jsonb,'{}'::jsonb,'[]'::jsonb,
  '11111111-1111-4111-8111-111111111111'
)
ON CONFLICT DO NOTHING;

UPDATE editorial.cases
SET current_review_snapshot_id='d61d1000-0000-4000-8000-000000000002'
WHERE id='d61d1000-0000-4000-8000-000000000001'
  AND current_review_snapshot_id IS DISTINCT FROM
    'd61d1000-0000-4000-8000-000000000002';

INSERT INTO editorial.evidence(
  id,case_id,evidence_type,title,description,source_document_id,source_url,
  source_locator,content_sha256,classification,verification_status,version,
  created_by
) VALUES(
  'd61d1000-0000-4000-8000-000000000003',
  'd61d1000-0000-4000-8000-000000000001','DOCUMENT',
  'R6d legal-hold evidence target','Dedicated immutable evidence target',
  '0ab0b0bc-40db-562a-af3b-cf21cf7a8215',
  'https://example.test/gurinnae/control-promotion-fixture',
  'fixture:legal-hold',repeat('d',64),'INTERNAL','PENDING',1,
  '11111111-1111-4111-8111-111111111111'
)
ON CONFLICT DO NOTHING;

-- This immutable v13 decision is already version 1.  Its legacy mutable
-- request head predates the physical fence, so align only that head.
UPDATE ops.retention_requests
SET decision_version=1
WHERE id='782e0381-42fa-5626-87dd-5405d537c951'
  AND status='REVIEW' AND decision_version=0;

DO $entity_snapshots$
DECLARE
  actor_id constant uuid := '11111111-1111-4111-8111-111111111111';
  supplier_request_id constant uuid :=
    'd61d1000-0000-4000-8000-000000000004';
  agency_request_id constant uuid :=
    'd61d1000-0000-4000-8000-000000000005';
  supplier_key char(64);
  agency_key char(64);
  supplier_request_digest char(64);
  agency_request_digest char(64);
  snapshot_result jsonb;
BEGIN
  supplier_key:=encode(extensions.digest(convert_to(
    'control-legal-hold:supplier-retention-snapshot:v1','UTF8'
  ),'sha256'),'hex');
  agency_key:=encode(extensions.digest(convert_to(
    'control-legal-hold:agency-retention-snapshot:v1','UTF8'
  ),'sha256'),'hex');
  supplier_request_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','control-legal-hold-snapshot-request.v1',
      'subjectKind','SUPPLIER',
      'subjectId','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid
    )
  ),'sha256'),'hex');
  agency_request_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','control-legal-hold-snapshot-request.v1',
      'subjectKind','AGENCY',
      'subjectId','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid
    )
  ),'sha256'),'hex');

  snapshot_result:=ops.create_entity_retention_snapshot_v1(
    'SUPPLIER','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',actor_id,
    supplier_request_id,supplier_key,supplier_request_digest
  );
  IF snapshot_result->>'subjectKind'<>'SUPPLIER'
     OR (snapshot_result->>'subjectId')::uuid<>
       'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid THEN
    RAISE EXCEPTION 'r6d_legal_hold_supplier_snapshot_invalid';
  END IF;

  snapshot_result:=ops.create_entity_retention_snapshot_v1(
    'AGENCY','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',actor_id,
    agency_request_id,agency_key,agency_request_digest
  );
  IF snapshot_result->>'subjectKind'<>'AGENCY'
     OR (snapshot_result->>'subjectId')::uuid<>
       'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid THEN
    RAISE EXCEPTION 'r6d_legal_hold_agency_snapshot_invalid';
  END IF;
END
$entity_snapshots$;

-- This CTE is also the authoritative runtime extraction query.  Every branch
-- mirrors the exact payload shape consumed by ops.place_legal_hold_v2.
DO $target_assertion$
DECLARE
  target_count bigint;
  target_kind_count bigint;
  common_shape_valid boolean;
BEGIN
  WITH targets(ordinal,target) AS (
    SELECT 1,jsonb_build_object(
      'targetKind','CASE','targetId',target_case.id,
      'targetVersion',target_case.version,
      'targetDigest',btrim(review.snapshot_sha256),
      'caseId',target_case.id,'reviewSnapshotId',review.id,
      'reviewSnapshotDigest',btrim(review.snapshot_sha256)
    )
    FROM editorial.cases AS target_case
    JOIN editorial.review_snapshots AS review
      ON review.id=target_case.current_review_snapshot_id
     AND review.case_id=target_case.id
     AND review.case_version=target_case.version
    WHERE target_case.id='d61d1000-0000-4000-8000-000000000001'
      AND target_case.version=1 AND review.snapshot_sha256=repeat('c',64)
    UNION ALL
    SELECT 2,jsonb_build_object(
      'targetKind','PUBLICATION','targetId',publication.id,
      'targetVersion',publication.revision,
      'targetDigest',btrim(publication.public_payload_sha256),
      'publicationRevisionId',publication.id
    ) FROM editorial.publication_revisions AS publication
    WHERE publication.id='02568a6a-27f5-5ede-b5d0-21107e22a755'
      AND publication.revision=1
      AND publication.public_payload_sha256=
        '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a'
    UNION ALL
    SELECT 3,jsonb_build_object(
      'targetKind','EVIDENCE','targetId',evidence.id,
      'targetVersion',evidence.version,
      'targetDigest',btrim(evidence.content_sha256),'evidenceId',evidence.id
    ) FROM editorial.evidence AS evidence
    WHERE evidence.id='d61d1000-0000-4000-8000-000000000003'
      AND evidence.version=1 AND evidence.content_sha256=repeat('d',64)
    UNION ALL
    SELECT 4,jsonb_build_object(
      'targetKind','RESPONSE','targetId',response.id,
      'targetVersion',response.version,
      'targetDigest',btrim(response.response_content_sha256),
      'responseId',response.id
    ) FROM editorial.responses AS response
    WHERE response.submission_id='d61d0000-0000-4000-8000-00000000000a'
      AND response.version=1
      AND response.organization_identity_status='UNVERIFIED'
      AND response.publication_form='INTERNAL_ONLY'
      AND response.response_content_sha256 IS NOT NULL
      AND response.submission_receipt_digest IS NOT NULL
      AND response.owned_intake_event_id IS NOT NULL
      AND response.owned_intake_event_envelope_digest IS NOT NULL
      AND response.owned_intake_receipt_digest IS NOT NULL
    UNION ALL
    SELECT 5,jsonb_build_object(
      'targetKind','SOURCE_ASSET','targetId',document.asset_id,
      'targetVersion',document.asset_revision,
      'targetDigest',btrim(document.content_sha256),
      'sourceDocumentId',document.id,'sourceAssetId',document.asset_id
    ) FROM raw.source_documents AS document
    WHERE document.id='0ab0b0bc-40db-562a-af3b-cf21cf7a8215'
      AND document.asset_id='a9bdbc4c-076b-5d00-93da-c8074941d1c0'
      AND document.asset_revision=1
      AND document.content_sha256=
        '4951601014f8f3dfce1477715f11e812d5c8a29f00bd88803405fd32d4af07c6'
    UNION ALL
    SELECT 6,jsonb_build_object(
      'targetKind','RESEARCH_ARTIFACT','targetId',artifact.asset_id,
      'targetVersion',artifact.asset_revision,
      'targetDigest',btrim(artifact.content_sha256),
      'researchArtifactId',artifact.id,'researchAssetId',artifact.asset_id
    ) FROM raw.research_artifacts AS artifact
    WHERE artifact.id='facc134e-f4d3-551d-bb42-55d4495373ae'
      AND artifact.asset_id='d3f33b34-05e9-5d0f-bdf0-95742b10d590'
      AND artifact.asset_revision=1
      AND artifact.content_sha256=
        '4951601014f8f3dfce1477715f11e812d5c8a29f00bd88803405fd32d4af07c6'
    UNION ALL
    SELECT 7,jsonb_build_object(
      'targetKind','PRIVACY_REQUEST','targetId',request.id,
      'targetVersion',decision.decision_version,
      'targetDigest',btrim(decision.inventory_snapshot_digest),
      'privacyRequestId',request.id,'privacyRequestType',request.request_type
    ) FROM ops.retention_requests AS request
    JOIN ops.retention_request_decisions AS decision
      ON decision.retention_request_id=request.id
     AND decision.decision_version=request.decision_version
    WHERE request.id='782e0381-42fa-5626-87dd-5405d537c951'
      AND request.request_type='ACCESS' AND request.decision_version=1
      AND decision.inventory_snapshot_digest=repeat('1',64)
    UNION ALL
    SELECT 8,jsonb_build_object(
      'targetKind','COMMUNICATION_SUBJECT','targetId',subject.id,
      'targetVersion',subject.profile_version,
      'targetDigest',btrim(subject.profile_digest),
      'communicationSubjectId',subject.id,
      'communicationSubjectOriginDigest',btrim(subject.origin_binding_digest)
    ) FROM intake.communication_subjects AS subject
    WHERE subject.id='11111111-1111-4111-8111-111111111111'
      AND subject.profile_version=1 AND subject.profile_digest=repeat('b',64)
      AND subject.origin_binding_digest=repeat('b',64)
    UNION ALL
    SELECT CASE snapshot.subject_kind WHEN 'SUPPLIER' THEN 9 ELSE 10 END,
      jsonb_build_object(
        'targetKind',snapshot.subject_kind||'_RETENTION_SNAPSHOT',
        'targetId',snapshot.snapshot_id,
        'targetVersion',snapshot.subject_version,
        'targetDigest',btrim(snapshot.snapshot_digest),
        'entityKind',snapshot.subject_kind,
        'entityRetentionSnapshotId',snapshot.snapshot_id,
        'entityRetentionSnapshotDigest',btrim(snapshot.snapshot_digest)
      )
    FROM ops.entity_retention_snapshots_v1 AS snapshot
    WHERE (snapshot.subject_kind,snapshot.subject_id,snapshot.request_id) IN (
      ('SUPPLIER','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,
        'd61d1000-0000-4000-8000-000000000004'::uuid),
      ('AGENCY','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
        'd61d1000-0000-4000-8000-000000000005'::uuid)
    )
      AND snapshot.subject_version>0
      AND ops.r6d_lower_sha256(snapshot.snapshot_digest)
      AND snapshot.retention_record_class='ENTITY_RETENTION_SNAPSHOT'
  )
  SELECT count(*),count(DISTINCT target->>'targetKind'),
    bool_and(
      target ?& ARRAY[
        'targetKind','targetId','targetVersion','targetDigest'
      ]
      AND target->>'targetVersion' ~ '^[1-9][0-9]*$'
      AND ops.r6d_lower_sha256(target->>'targetDigest')
    )
  INTO target_count,target_kind_count,common_shape_valid
  FROM targets;

  IF target_count<>10 OR target_kind_count<>10
     OR common_shape_valid IS DISTINCT FROM true THEN
    RAISE EXCEPTION
      'r6d_legal_hold_target_set_invalid:count=% kinds=% shape=%',
      target_count,target_kind_count,common_shape_valid;
  END IF;
END
$target_assertion$;

COMMIT;
