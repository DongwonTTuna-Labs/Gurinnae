-- Disposable PostgreSQL smoke for the three procurement owner functions.
-- The caller is intentionally a superuser in this fixture; the functions run
-- as gurine_migrator and therefore exercise their real SECURITY DEFINER grants.
DO $$
DECLARE
  v_candidate_id uuid := 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  v_candidate_digest char(64) := encode(extensions.digest(convert_to('{}','UTF8'),'sha256'),'hex');
  v_actor uuid := '11111111-1111-4111-8111-111111111111';
  v_reviewer uuid := '22222222-2222-4222-8222-222222222222';
  v_receipt jsonb;
  v_replay jsonb;
  v_relationship_request jsonb;
  v_relationship_receipt jsonb;
  v_decision_receipt jsonb;
  v_assertion_id uuid;
  v_assertion_digest char(64);
BEGIN
  INSERT INTO ops.users(id,oidc_subject,email,display_name,status)
    VALUES(v_actor,'procurement-fixture','procurement-fixture@example.test','Procurement Fixture','ACTIVE'),
          (v_reviewer,'procurement-reviewer','procurement-reviewer@example.test','Procurement Reviewer','ACTIVE')
    ON CONFLICT DO NOTHING;
  INSERT INTO core.supplier_identity_candidates(
    candidate_id,candidate_revision,candidate_digest,source_document_id,source_asset_id,
    source_asset_revision,source_content_sha256,parsed_record_id,source_record_digest,
    record_index,mapping_version,normalized_name,name_source_locator_digest,
    identifier_count,identifier_set_digest,identity_status,candidate_payload,
    candidate_canonical,candidate_digest_preimage_canonical)
  VALUES(v_candidate_id,1,v_candidate_digest,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    'cccccccc-cccc-4ccc-8ccc-cccccccccccc',1,repeat('1',64),
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd',repeat('2',64),0,'v1','fixture',
    repeat('3',64),0,repeat('4',64),'CANDIDATE','{}','{}','{}')
  ON CONFLICT DO NOTHING;

  PERFORM set_config('gurine.actor_user_id',v_actor::text,true);
  v_receipt := core.record_supplier_identity_resolution_v1(jsonb_build_object(
    'action','KEEP_SEPARATE',
    'candidateRefs',jsonb_build_array(jsonb_build_object(
      'candidateId',v_candidate_id,'candidateRevision',1,'candidateDigest',v_candidate_digest,
      'identityStatus','CANDIDATE','valueHmac',NULL)),
    'expectedCandidateSetDigest',repeat('5',64),
    'expectedPriorDecisionDigest',NULL,
    'fromCanonicalSupplierIds','[]'::jsonb,'toCanonicalSupplierIds','[]'::jsonb,
    'evidenceLocators',jsonb_build_array(jsonb_build_object(
      'evidenceId','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','evidenceVersion',1,
      'evidenceDigest',repeat('6',64),'sourceDocumentId','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      'sourceAssetId','cccccccc-cccc-4ccc-8ccc-cccccccccccc','sourceAssetRevision',1,
      'locatorDigest',repeat('7',64))),
    'expectedEvidenceLocatorSetDigest',repeat('7',64),
    'expectedPublicImpactSetDigest',repeat('8',64),
    'impactOwnerUserId',NULL,'impactDueAt',NULL,
    'reasonCode','INSUFFICIENT_EVIDENCE','reason','fixture'));
  v_replay := core.record_supplier_identity_resolution_v1(jsonb_build_object(
    'action','KEEP_SEPARATE','candidateRefs',jsonb_build_array(jsonb_build_object(
      'candidateId',v_candidate_id,'candidateRevision',1,'candidateDigest',v_candidate_digest,
      'identityStatus','CANDIDATE','valueHmac',NULL)),
    'expectedCandidateSetDigest',repeat('5',64),'expectedPriorDecisionDigest',NULL,
    'fromCanonicalSupplierIds','[]'::jsonb,'toCanonicalSupplierIds','[]'::jsonb,
    'evidenceLocators',jsonb_build_array(jsonb_build_object(
      'evidenceId','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','evidenceVersion',1,
      'evidenceDigest',repeat('6',64),'sourceDocumentId','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      'sourceAssetId','cccccccc-cccc-4ccc-8ccc-cccccccccccc','sourceAssetRevision',1,
      'locatorDigest',repeat('7',64))),
    'expectedEvidenceLocatorSetDigest',repeat('7',64),'expectedPublicImpactSetDigest',repeat('8',64),
    'impactOwnerUserId',NULL,'impactDueAt',NULL,'reasonCode','INSUFFICIENT_EVIDENCE','reason','fixture'));
  IF v_replay IS DISTINCT FROM v_receipt OR (SELECT count(*) FROM core.supplier_identity_resolution_decisions) <> 1 THEN
    RAISE EXCEPTION 'identity idempotent replay failed';
  END IF;

  v_relationship_request := jsonb_build_object(
    'relationshipKind','OWNERSHIP',
    'subject',jsonb_build_object('partyKind','SUPPLIER','supplierCandidateId',v_candidate_id,
      'supplierCandidateRevision',1,'supplierCandidateDigest',v_candidate_digest,'canonicalSupplierId',NULL,
      'identityKeyDigest',repeat('9',64),'identityStatus','CANDIDATE'),
    'object',jsonb_build_object('partyKind','ORGANIZATION','supplierCandidateId',NULL,
      'supplierCandidateRevision',NULL,'supplierCandidateDigest',NULL,'canonicalSupplierId',NULL,
      'identityKeyDigest',repeat('a',64),'identityStatus','VERIFIED'),
    'ownershipPercent','25.0000','managementRole',NULL,'validFrom','2026-01-01','validTo',NULL,
    'validityCoverageStatus','COMPLETE',
    'evidenceLocators',jsonb_build_array(jsonb_build_object(
      'evidenceId','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','evidenceVersion',1,'evidenceDigest',repeat('6',64),
      'reviewSnapshotId','ffffffff-ffff-4fff-8fff-ffffffffffff','reviewCaseId','99999999-9999-4999-8999-999999999999',
      'reviewSnapshotVersion',1,'reviewSnapshotDigest',repeat('1',64),
      'sourceDocumentId','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','sourceAssetId','cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      'sourceAssetRevision',1,'sourceContentSha256',repeat('2',64),'locatorDigest',repeat('7',64))),
    'expectedEvidenceLocatorSetDigest',repeat('7',64),'reason','fixture');
  v_relationship_receipt := core.record_supplier_relationship_assertion_v1(v_relationship_request);
  v_assertion_id := (v_relationship_receipt->>'assertionId')::uuid;
  v_assertion_digest := v_relationship_receipt->>'assertionDigest';
  PERFORM set_config('gurine.actor_user_id',v_reviewer::text,true);
  v_decision_receipt := core.decide_supplier_relationship_assertion_v1(v_assertion_id,jsonb_build_object(
    'assertionId',v_assertion_id,'expectedAssertionRevision',1,'expectedAssertionDigest',v_assertion_digest,
    'expectedEvidenceLocatorSetDigest',repeat('7',64),'decision','VERIFY','counterAssertionIds','[]'::jsonb,
    'reasonCode','EVIDENCE_CONFIRMED','reason','independent fixture'));
  IF v_decision_receipt->>'verificationStatus' <> 'VERIFIED'
     OR (SELECT count(*) FROM core.supplier_relationship_assertions WHERE assertion_id=v_assertion_id) <> 2
     OR (SELECT count(*) FROM ops.outbox WHERE aggregate_id=v_assertion_id::text) <> 2 THEN
    RAISE EXCEPTION 'relationship decision runtime closure failed';
  END IF;
END
$$;
