-- Runtime owner boundaries for the three procurement identity commands.
-- This file is emitted inside additive migration 0025 by the migration
-- generator; it is kept separate so the generated migration remains
-- reproducible and the command bodies remain reviewable.

GRANT USAGE ON SCHEMA core, ops TO gurine_migrator;
GRANT SELECT, INSERT, UPDATE ON ops.users, ops.idempotency_keys, ops.audit_events, ops.audit_chain_heads, ops.outbox TO gurine_migrator;
GRANT EXECUTE ON FUNCTION ops.append_audit_event(text,text,text,uuid,text,text,text,text,ops.audit_outcome,text,uuid,jsonb) TO gurine_migrator;

CREATE OR REPLACE FUNCTION core.record_supplier_identity_resolution_v1(p_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, ops, extensions, pg_temp
AS $$
DECLARE
  v_actor uuid;
  v_actor_text text := COALESCE(NULLIF(current_setting('gurine.actor_user_id', true), ''), p_request->>'actorUserId');
  v_now timestamptz := clock_timestamp();
  v_canonical bytea;
  v_request_hash char(64);
  v_key_hash char(64);
  v_existing_hash char(64);
  v_existing_response jsonb;
  v_decision_id uuid := gen_random_uuid();
  v_event_id uuid := gen_random_uuid();
  v_audit_id uuid;
  v_decision_digest char(64);
  v_sequence bigint;
  v_action text := p_request->>'action';
  v_reason_code text := p_request->>'reasonCode';
  v_candidate_set_digest char(64) := p_request->>'expectedCandidateSetDigest';
  v_evidence_set_digest char(64) := p_request->>'expectedEvidenceLocatorSetDigest';
  v_impact_set_digest char(64) := p_request->>'expectedPublicImpactSetDigest';
  v_reason_digest char(64);
  v_prior_id uuid;
  v_prior_digest char(64);
  v_candidate jsonb;
  v_candidate_id uuid;
  v_candidate_revision bigint;
  v_candidate_digest char(64);
  v_member_canonical bytea;
  v_member_digest char(64);
  v_ordinal integer := 0;
  v_receipt jsonb;
  v_receipt_digest char(64);
  v_event_payload jsonb;
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request) <> 'object' THEN
    RAISE EXCEPTION 'invalid_parameter' USING ERRCODE = '22023';
  END IF;
  IF v_actor_text IS NULL OR v_actor_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN
    RAISE EXCEPTION 'actor_user_id_required' USING ERRCODE = '28000';
  END IF;
  v_actor := v_actor_text::uuid;
  IF NOT EXISTS (SELECT 1 FROM ops.users WHERE id = v_actor AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'actor_user_not_active' USING ERRCODE = '28000';
  END IF;
  IF v_action NOT IN ('MERGE','SPLIT','KEEP_SEPARATE','MARK_AMBIGUOUS')
     OR v_reason_code NOT IN ('AUTHORITATIVE_IDENTIFIER_MATCH','AUTHORITATIVE_IDENTIFIER_CONFLICT','SOURCE_CORRECTION','FALSE_MERGE','INSUFFICIENT_EVIDENCE')
     OR jsonb_typeof(p_request->'candidateRefs') <> 'array'
     OR jsonb_array_length(p_request->'candidateRefs') < 1
     OR jsonb_typeof(p_request->'evidenceLocators') <> 'array'
     OR jsonb_array_length(p_request->'evidenceLocators') < 1
     OR v_candidate_set_digest !~ '^[0-9a-f]{64}$'
     OR v_evidence_set_digest !~ '^[0-9a-f]{64}$'
     OR v_impact_set_digest !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_parameter' USING ERRCODE = '22023';
  END IF;
  IF v_action = 'MERGE' AND jsonb_array_length(p_request->'candidateRefs') < 2 THEN
    RAISE EXCEPTION 'invalid_merge_cardinality' USING ERRCODE = '22023';
  END IF;
  IF v_action = 'SPLIT' AND (jsonb_array_length(p_request->'candidateRefs') < 3 OR p_request->>'impactOwnerUserId' IS NULL OR p_request->>'impactDueAt' IS NULL) THEN
    RAISE EXCEPTION 'invalid_split_cardinality' USING ERRCODE = '22023';
  END IF;
  v_canonical := convert_to(p_request::text, 'UTF8');
  v_request_hash := encode(extensions.digest(v_canonical, 'sha256'), 'hex');
  v_key_hash := COALESCE(NULLIF(current_setting('gurine.idempotency_key_hash', true), ''), v_request_hash);
  IF v_key_hash !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid_idempotency_key' USING ERRCODE = '22023'; END IF;
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
    VALUES ('recordSupplierIdentityResolution',v_key_hash,v_request_hash,v_now+interval '24 hours')
    ON CONFLICT (scope,key_hash) DO NOTHING;
  SELECT request_hash,response_body INTO v_existing_hash,v_existing_response
    FROM ops.idempotency_keys WHERE scope='recordSupplierIdentityResolution' AND key_hash=v_key_hash FOR UPDATE;
  IF v_existing_hash IS DISTINCT FROM v_request_hash THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001'; END IF;
  IF v_existing_response IS NOT NULL THEN RETURN v_existing_response; END IF;
  SELECT COALESCE(max(decision_sequence),0)+1 INTO v_sequence FROM core.supplier_identity_resolution_decisions;
  v_decision_digest := encode(extensions.digest(v_canonical,'sha256'),'hex');
  SELECT decision_id,decision_digest INTO v_prior_id,v_prior_digest FROM core.supplier_identity_resolution_decisions WHERE decision_digest=NULLIF(p_request->>'expectedPriorDecisionDigest','') FOR SHARE;
  v_reason_digest := encode(extensions.digest(convert_to(COALESCE(p_request->>'reason',''),'UTF8'),'sha256'),'hex');
  v_event_payload := jsonb_build_object('occurredAt',v_now,'decisionId',v_decision_id,'decisionSequence',v_sequence,'action',v_action,'decisionDigest',v_decision_digest,'candidateSetDigest',v_candidate_set_digest,'evidenceLocatorSetDigest',v_evidence_set_digest);
  v_audit_id := ops.append_audit_event('supplier-identity-resolution','user',v_actor::text,NULL,'SUPPLIER_IDENTITY_RESOLUTION_RECORDED','SupplierIdentityResolutionDecision',v_decision_id::text,'cases.evidence.manage','SUCCESS',NULL,v_event_id,v_event_payload);
  v_receipt := jsonb_build_object('decisionId',v_decision_id,'decisionSequence',v_sequence,'action',v_action,'candidateSetDigest',v_candidate_set_digest,'evidenceLocatorSetDigest',v_evidence_set_digest,'publicImpactSetDigest',v_impact_set_digest,'decisionDigest',v_decision_digest,'actorUserId',v_actor,'auditEventId',v_audit_id,'emittedEventIds',jsonb_build_array(v_event_id),'acceptedAt',v_now);
  v_receipt_digest := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex');
  v_event_payload := v_event_payload || jsonb_build_object('receiptId',v_decision_id,'receiptDigest',v_receipt_digest);
  INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at)
    VALUES(v_event_id,'SupplierIdentityResolutionDecision',v_decision_id::text,v_sequence,'supplier.identity_resolution_recorded.v1',v_event_payload,v_now);
  INSERT INTO core.supplier_identity_resolution_decisions(decision_id,decision_sequence,action,candidate_count,candidate_set_digest,from_supplier_ids_canonical,from_supplier_set_digest,to_supplier_ids_canonical,to_supplier_set_digest,evidence_locator_set_canonical,evidence_locator_set_digest,prior_decision_id,prior_decision_digest,actor_user_id,reason_code,reason_digest,impact_owner_user_id,impact_due_at,affected_public_revision_ids_canonical,affected_public_revision_set_digest,decision_payload,decision_canonical,decision_digest_preimage_canonical,decision_digest,decided_at,audit_event_id,outbox_event_id)
    VALUES(v_decision_id,v_sequence,v_action,jsonb_array_length(p_request->'candidateRefs'),v_candidate_set_digest,convert_to(COALESCE(p_request->'fromCanonicalSupplierIds','[]'::jsonb)::text,'UTF8'),encode(extensions.digest(convert_to(COALESCE(p_request->'fromCanonicalSupplierIds','[]'::jsonb)::text,'UTF8'),'sha256'),'hex'),convert_to(COALESCE(p_request->'toCanonicalSupplierIds','[]'::jsonb)::text,'UTF8'),encode(extensions.digest(convert_to(COALESCE(p_request->'toCanonicalSupplierIds','[]'::jsonb)::text,'UTF8'),'sha256'),'hex'),convert_to((p_request->'evidenceLocators')::text,'UTF8'),v_evidence_set_digest,v_prior_id,v_prior_digest,v_actor,v_reason_code,v_reason_digest,NULLIF(p_request->>'impactOwnerUserId','')::uuid,NULLIF(p_request->>'impactDueAt','')::timestamptz,convert_to(COALESCE(p_request->'affectedPublicRevisionIds','[]'::jsonb)::text,'UTF8'),v_impact_set_digest,p_request,v_canonical,v_canonical,v_decision_digest,v_now,v_audit_id,v_event_id);
  FOR v_candidate IN SELECT value FROM jsonb_array_elements(p_request->'candidateRefs') LOOP
    v_candidate_id := NULLIF(v_candidate->>'candidateId','')::uuid; v_candidate_revision := NULLIF(v_candidate->>'candidateRevision','')::bigint; v_candidate_digest := v_candidate->>'candidateDigest';
    IF v_candidate_id IS NULL OR v_candidate_revision IS NULL OR v_candidate_revision < 1 OR v_candidate_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid_candidate_reference' USING ERRCODE='22023'; END IF;
    PERFORM 1 FROM core.supplier_identity_candidates WHERE candidate_id=v_candidate_id AND candidate_revision=v_candidate_revision AND candidate_digest=v_candidate_digest FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;
    v_member_canonical := convert_to(v_candidate::text,'UTF8'); v_member_digest := encode(extensions.digest(v_member_canonical,'sha256'),'hex');
    INSERT INTO core.supplier_identity_resolution_decision_members(decision_id,decision_digest,member_ordinal,candidate_id,candidate_revision,candidate_digest,member_canonical,member_digest) VALUES(v_decision_id,v_decision_digest,v_ordinal,v_candidate_id,v_candidate_revision,v_candidate_digest,v_member_canonical,v_member_digest);
    v_ordinal := v_ordinal + 1;
  END LOOP;
  UPDATE ops.idempotency_keys SET response_status=201,response_body=v_receipt,resource_type='SupplierIdentityResolutionDecision',resource_id=v_decision_id::text WHERE scope='recordSupplierIdentityResolution' AND key_hash=v_key_hash;
  RETURN v_receipt;
END
$$;
ALTER FUNCTION core.record_supplier_identity_resolution_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.record_supplier_identity_resolution_v1(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.record_supplier_identity_resolution_v1(jsonb) TO gurine_identity_api;

CREATE OR REPLACE FUNCTION core.record_supplier_relationship_assertion_v1(p_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, ops, extensions, pg_temp
AS $$
DECLARE
  v_actor uuid;
  v_actor_text text := COALESCE(NULLIF(current_setting('gurine.actor_user_id', true), ''), p_request->>'actorUserId');
  v_now timestamptz := clock_timestamp();
  v_id uuid := gen_random_uuid(); v_event_id uuid := gen_random_uuid(); v_audit_id uuid;
  v_canonical bytea := convert_to(p_request::text,'UTF8'); v_digest char(64) := encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_key_hash char(64); v_existing_hash char(64); v_existing_response jsonb; v_receipt jsonb; v_receipt_digest char(64); v_event_payload jsonb;
  v_subject jsonb := p_request->'subject'; v_object jsonb := p_request->'object'; v_loc jsonb; v_ordinal integer := 0; v_loc_canonical bytea;
  v_subject_id uuid := NULLIF(v_subject->>'supplierCandidateId','')::uuid; v_subject_rev bigint := NULLIF(v_subject->>'supplierCandidateRevision','')::bigint; v_subject_digest char(64) := v_subject->>'supplierCandidateDigest'; v_subject_key char(64) := v_subject->>'identityKeyDigest';
  v_object_id uuid := NULLIF(v_object->>'supplierCandidateId','')::uuid; v_object_rev bigint := NULLIF(v_object->>'supplierCandidateRevision','')::bigint; v_object_digest char(64) := v_object->>'supplierCandidateDigest'; v_object_key char(64) := v_object->>'identityKeyDigest';
  v_evidence_set_digest char(64) := p_request->>'expectedEvidenceLocatorSetDigest';
  v_evidence_id uuid; v_evidence_version bigint; v_evidence_digest char(64); v_snapshot_id uuid; v_case_id uuid; v_snapshot_version bigint; v_snapshot_digest char(64); v_source_document_id uuid; v_source_asset_id uuid; v_source_asset_revision bigint; v_source_content_sha256 char(64); v_locator_digest char(64);
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request)<>'object' OR p_request->>'relationshipKind' NOT IN ('OWNERSHIP','BENEFICIAL_OWNERSHIP','CONTROL','MANAGEMENT_ROLE','LEGAL_REPRESENTATIVE','CONTRACTUAL_RELATIONSHIP') OR jsonb_typeof(p_request->'evidenceLocators')<>'array' OR jsonb_array_length(p_request->'evidenceLocators')<1 OR v_evidence_set_digest !~ '^[0-9a-f]{64}$' OR v_subject_key !~ '^[0-9a-f]{64}$' OR v_object_key !~ '^[0-9a-f]{64}$' OR v_subject_key=v_object_key THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
  IF v_actor_text IS NULL OR v_actor_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN RAISE EXCEPTION 'actor_user_id_required' USING ERRCODE='28000'; END IF;
  v_actor := v_actor_text::uuid; IF NOT EXISTS (SELECT 1 FROM ops.users WHERE id=v_actor AND status='ACTIVE') THEN RAISE EXCEPTION 'actor_user_not_active' USING ERRCODE='28000'; END IF;
  IF v_subject_id IS NOT NULL THEN PERFORM 1 FROM core.supplier_identity_candidates WHERE candidate_id=v_subject_id AND candidate_revision=v_subject_rev AND candidate_digest=v_subject_digest FOR SHARE; IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF; END IF;
  IF v_object_id IS NOT NULL THEN PERFORM 1 FROM core.supplier_identity_candidates WHERE candidate_id=v_object_id AND candidate_revision=v_object_rev AND candidate_digest=v_object_digest FOR SHARE; IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF; END IF;
  v_key_hash := COALESCE(NULLIF(current_setting('gurine.idempotency_key_hash', true),''),encode(extensions.digest(v_canonical,'sha256'),'hex'));
  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at) VALUES('recordSupplierRelationshipAssertion',v_key_hash,v_digest,v_now+interval '24 hours') ON CONFLICT(scope,key_hash) DO NOTHING;
  SELECT request_hash,response_body INTO v_existing_hash,v_existing_response FROM ops.idempotency_keys WHERE scope='recordSupplierRelationshipAssertion' AND key_hash=v_key_hash FOR UPDATE;
  IF v_existing_hash IS DISTINCT FROM v_digest THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001'; END IF; IF v_existing_response IS NOT NULL THEN RETURN v_existing_response; END IF;
  v_event_payload := jsonb_build_object('occurredAt',v_now,'assertionId',v_id,'assertionRevision',1,'assertionDigest',v_digest,'verificationStatus','PENDING','evidenceLocatorSetDigest',v_evidence_set_digest);
  v_audit_id := ops.append_audit_event('supplier-relationship-assertion','user',v_actor::text,NULL,'SUPPLIER_RELATIONSHIP_ASSERTION_CREATED','SupplierRelationshipAssertion',v_id::text,'cases.evidence.manage','SUCCESS',NULL,v_event_id,v_event_payload);
  v_receipt := jsonb_build_object('assertionId',v_id,'assertionRevision',1,'assertionDigest',v_digest,'verificationStatus','PENDING','evidenceLocatorSetDigest',v_evidence_set_digest,'verifiedBy',NULL,'verifiedAt',NULL,'auditEventId',v_audit_id,'emittedEventIds',jsonb_build_array(v_event_id),'acceptedAt',v_now);
  v_receipt_digest := encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex'); v_event_payload := v_event_payload || jsonb_build_object('receiptId',v_id,'receiptDigest',v_receipt_digest);
  INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at) VALUES(v_event_id,'SupplierRelationshipAssertion',v_id::text,1,'supplier.relationship_assertion_created.v1',v_event_payload,v_now);
  INSERT INTO core.supplier_relationship_assertions(assertion_id,assertion_revision,assertion_digest,relationship_kind,subject_candidate_id,subject_candidate_revision,subject_candidate_digest,subject_identity_key_digest,object_candidate_id,object_candidate_revision,object_candidate_digest,object_identity_key_digest,ownership_percent,management_role,valid_from,valid_to,validity_coverage_status,verification_status,evidence_count,evidence_set_digest,counter_assertion_set_digest,public_use_status,created_by,assertion_payload,assertion_canonical,assertion_digest_preimage_canonical)
    VALUES(v_id,1,v_digest,p_request->>'relationshipKind',v_subject_id,v_subject_rev,v_subject_digest,v_subject_key,v_object_id,v_object_rev,v_object_digest,v_object_key,NULLIF(p_request->>'ownershipPercent','')::numeric,NULLIF(p_request->>'managementRole',''),NULLIF(p_request->>'validFrom','')::date,NULLIF(p_request->>'validTo','')::date,p_request->>'validityCoverageStatus','PENDING',jsonb_array_length(p_request->'evidenceLocators'),v_evidence_set_digest,encode(extensions.digest(convert_to('[]','UTF8'),'sha256'),'hex'),'NOT_REVIEWED',v_actor,p_request,v_canonical,v_canonical);
  FOR v_loc IN SELECT value FROM jsonb_array_elements(p_request->'evidenceLocators') LOOP
    v_evidence_id := NULLIF(v_loc->>'evidenceId','')::uuid; v_evidence_version := NULLIF(v_loc->>'evidenceVersion','')::bigint; v_evidence_digest := v_loc->>'evidenceDigest'; v_snapshot_id := NULLIF(v_loc->>'reviewSnapshotId','')::uuid; v_case_id := NULLIF(v_loc->>'reviewCaseId','')::uuid; v_snapshot_version := NULLIF(v_loc->>'reviewSnapshotVersion','')::bigint; v_snapshot_digest := v_loc->>'reviewSnapshotDigest'; v_source_document_id := NULLIF(v_loc->>'sourceDocumentId','')::uuid; v_source_asset_id := NULLIF(v_loc->>'sourceAssetId','')::uuid; v_source_asset_revision := NULLIF(v_loc->>'sourceAssetRevision','')::bigint; v_source_content_sha256 := v_loc->>'sourceContentSha256'; v_locator_digest := v_loc->>'locatorDigest';
    IF v_evidence_id IS NULL OR v_evidence_version<1 OR v_evidence_digest !~ '^[0-9a-f]{64}$' OR v_snapshot_id IS NULL OR v_case_id IS NULL OR v_snapshot_version<1 OR v_snapshot_digest !~ '^[0-9a-f]{64}$' OR v_source_document_id IS NULL OR v_source_asset_id IS NULL OR v_source_asset_revision<1 OR v_source_content_sha256 !~ '^[0-9a-f]{64}$' OR v_locator_digest !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid_evidence_locator' USING ERRCODE='22023'; END IF;
    v_loc_canonical := convert_to(v_loc::text,'UTF8'); INSERT INTO core.supplier_relationship_assertion_evidence(assertion_id,assertion_revision,assertion_digest,evidence_ordinal,review_snapshot_id,review_case_id,review_snapshot_version,review_snapshot_digest,evidence_id,evidence_version,evidence_digest,source_document_id,source_asset_id,source_asset_revision,source_content_sha256,locator_digest,evidence_binding_canonical,evidence_member_digest) VALUES(v_id,1,v_digest,v_ordinal,v_snapshot_id,v_case_id,v_snapshot_version,v_snapshot_digest,v_evidence_id,v_evidence_version,v_evidence_digest,v_source_document_id,v_source_asset_id,v_source_asset_revision,v_source_content_sha256,v_locator_digest,v_loc_canonical,encode(extensions.digest(v_loc_canonical,'sha256'),'hex')); v_ordinal:=v_ordinal+1;
  END LOOP;
  UPDATE ops.idempotency_keys SET response_status=201,response_body=v_receipt,resource_type='SupplierRelationshipAssertion',resource_id=v_id::text WHERE scope='recordSupplierRelationshipAssertion' AND key_hash=v_key_hash;
  RETURN v_receipt;
END
$$;
ALTER FUNCTION core.record_supplier_relationship_assertion_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.record_supplier_relationship_assertion_v1(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.record_supplier_relationship_assertion_v1(jsonb) TO gurine_identity_api;

CREATE OR REPLACE FUNCTION core.decide_supplier_relationship_assertion_v1(p_assertion_id uuid,p_request jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, core, ops, extensions, pg_temp
AS $$
DECLARE
  v_actor uuid; v_actor_text text:=COALESCE(NULLIF(current_setting('gurine.actor_user_id',true),''),p_request->>'actorUserId'); v_current core.supplier_relationship_assertions%ROWTYPE; v_now timestamptz:=clock_timestamp(); v_status text; v_revision bigint; v_preimage bytea; v_digest char(64); v_event_id uuid:=gen_random_uuid(); v_audit_id uuid; v_receipt jsonb; v_receipt_digest char(64); v_event_payload jsonb; v_key_hash char(64); v_existing_hash char(64); v_existing_response jsonb; v_request_hash char(64):=encode(extensions.digest(convert_to(p_request::text,'UTF8'),'sha256'),'hex'); v_loc record;
BEGIN
  IF p_assertion_id IS NULL OR p_request IS NULL OR p_request->>'decision' NOT IN ('VERIFY','REJECT','MARK_CONFLICT','SUPERSEDE') OR p_request->>'expectedAssertionDigest' !~ '^[0-9a-f]{64}$' OR p_request->>'expectedEvidenceLocatorSetDigest' !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'invalid_parameter' USING ERRCODE='22023'; END IF;
  IF v_actor_text IS NULL OR v_actor_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' THEN RAISE EXCEPTION 'actor_user_id_required' USING ERRCODE='28000'; END IF; v_actor:=v_actor_text::uuid;
  SELECT * INTO v_current FROM core.supplier_relationship_assertions WHERE assertion_id=p_assertion_id ORDER BY assertion_revision DESC LIMIT 1 FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'resource_not_found' USING ERRCODE='P0002'; END IF;
  IF v_current.assertion_revision<>(p_request->>'expectedAssertionRevision')::bigint OR v_current.assertion_digest<>p_request->>'expectedAssertionDigest' THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF; IF v_current.verification_status<>'PENDING' OR v_current.created_by=v_actor THEN RAISE EXCEPTION 'independent_decision_required' USING ERRCODE='42501'; END IF;
  v_key_hash:=COALESCE(NULLIF(current_setting('gurine.idempotency_key_hash',true),''),encode(extensions.digest(convert_to(p_assertion_id::text||':'||v_request_hash,'UTF8'),'sha256'),'hex')); INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at) VALUES('decideSupplierRelationshipAssertion',v_key_hash,v_request_hash,v_now+interval '24 hours') ON CONFLICT(scope,key_hash) DO NOTHING; SELECT request_hash,response_body INTO v_existing_hash,v_existing_response FROM ops.idempotency_keys WHERE scope='decideSupplierRelationshipAssertion' AND key_hash=v_key_hash FOR UPDATE; IF v_existing_hash IS DISTINCT FROM v_request_hash THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='40001'; END IF; IF v_existing_response IS NOT NULL THEN RETURN v_existing_response; END IF;
  v_status:=CASE p_request->>'decision' WHEN 'VERIFY' THEN 'VERIFIED' WHEN 'REJECT' THEN 'REJECTED' WHEN 'MARK_CONFLICT' THEN 'CONFLICTED' ELSE 'SUPERSEDED' END; v_revision:=v_current.assertion_revision+1; v_preimage:=convert_to(jsonb_build_object('priorAssertionDigest',v_current.assertion_digest,'decision',p_request->>'decision','reasonCode',p_request->>'reasonCode','reason',p_request->>'reason','counterAssertionIds',COALESCE(p_request->'counterAssertionIds','[]'::jsonb))::text,'UTF8'); v_digest:=encode(extensions.digest(v_preimage,'sha256'),'hex');
  v_event_payload:=jsonb_build_object('occurredAt',v_now,'assertionId',p_assertion_id,'assertionRevision',v_revision,'assertionDigest',v_digest,'verificationStatus',v_status,'evidenceLocatorSetDigest',v_current.evidence_set_digest,'decisionDigest',v_digest); v_audit_id:=ops.append_audit_event('supplier-relationship-assertion','user',v_actor::text,NULL,'SUPPLIER_RELATIONSHIP_ASSERTION_DECIDED','SupplierRelationshipAssertion',p_assertion_id::text,'cases.evidence.manage','SUCCESS',NULL,v_event_id,v_event_payload);
  v_receipt:=jsonb_build_object('assertionId',p_assertion_id,'assertionRevision',v_revision,'assertionDigest',v_digest,'verificationStatus',v_status,'evidenceLocatorSetDigest',v_current.evidence_set_digest,'verifiedBy',v_actor,'verifiedAt',v_now,'auditEventId',v_audit_id,'emittedEventIds',jsonb_build_array(v_event_id),'acceptedAt',v_now); v_receipt_digest:=encode(extensions.digest(convert_to(v_receipt::text,'UTF8'),'sha256'),'hex'); v_event_payload:=v_event_payload||jsonb_build_object('receiptId',p_assertion_id,'receiptDigest',v_receipt_digest); INSERT INTO ops.outbox(id,aggregate_type,aggregate_id,aggregate_version,event_type,payload,occurred_at) VALUES(v_event_id,'SupplierRelationshipAssertion',p_assertion_id::text,v_revision,'supplier.relationship_assertion_decided.v1',v_event_payload,v_now);
  INSERT INTO core.supplier_relationship_assertions(assertion_id,assertion_revision,assertion_digest,predecessor_assertion_revision,predecessor_assertion_digest,relationship_kind,subject_candidate_id,subject_candidate_revision,subject_candidate_digest,subject_identity_key_digest,object_candidate_id,object_candidate_revision,object_candidate_digest,object_identity_key_digest,ownership_percent,management_role,valid_from,valid_to,validity_coverage_status,verification_status,evidence_count,evidence_set_digest,counter_assertion_set_digest,verified_by,verified_at,verification_reason_digest,public_use_status,created_by,assertion_payload,assertion_canonical,assertion_digest_preimage_canonical) VALUES(p_assertion_id,v_revision,v_digest,v_current.assertion_revision,v_current.assertion_digest,v_current.relationship_kind,v_current.subject_candidate_id,v_current.subject_candidate_revision,v_current.subject_candidate_digest,v_current.subject_identity_key_digest,v_current.object_candidate_id,v_current.object_candidate_revision,v_current.object_candidate_digest,v_current.object_identity_key_digest,v_current.ownership_percent,v_current.management_role,v_current.valid_from,v_current.valid_to,v_current.validity_coverage_status,v_status,v_current.evidence_count,v_current.evidence_set_digest,encode(extensions.digest(convert_to(COALESCE(p_request->'counterAssertionIds','[]'::jsonb)::text,'UTF8'),'sha256'),'hex'),v_actor,v_now,encode(extensions.digest(convert_to(COALESCE(p_request->>'reason',''),'UTF8'),'sha256'),'hex'),CASE WHEN v_status='VERIFIED' AND v_current.validity_coverage_status='COMPLETE' THEN 'APPROVED' ELSE 'NOT_REVIEWED' END,v_current.created_by,jsonb_build_object('priorAssertionDigest',v_current.assertion_digest,'decision',p_request->>'decision','reasonCode',p_request->>'reasonCode','reason',p_request->>'reason','counterAssertionIds',COALESCE(p_request->'counterAssertionIds','[]'::jsonb)),v_preimage,v_preimage);
  FOR v_loc IN SELECT * FROM core.supplier_relationship_assertion_evidence WHERE assertion_id=p_assertion_id AND assertion_revision=v_current.assertion_revision ORDER BY evidence_ordinal LOOP INSERT INTO core.supplier_relationship_assertion_evidence(assertion_id,assertion_revision,assertion_digest,evidence_ordinal,review_snapshot_id,review_case_id,review_snapshot_version,review_snapshot_digest,evidence_id,evidence_version,evidence_digest,source_document_id,source_asset_id,source_asset_revision,source_content_sha256,locator_digest,evidence_binding_canonical,evidence_member_digest) VALUES(p_assertion_id,v_revision,v_digest,v_loc.evidence_ordinal,v_loc.review_snapshot_id,v_loc.review_case_id,v_loc.review_snapshot_version,v_loc.review_snapshot_digest,v_loc.evidence_id,v_loc.evidence_version,v_loc.evidence_digest,v_loc.source_document_id,v_loc.source_asset_id,v_loc.source_asset_revision,v_loc.source_content_sha256,v_loc.locator_digest,v_loc.evidence_binding_canonical,encode(extensions.digest(v_loc.evidence_binding_canonical,'sha256'),'hex')); END LOOP;
  UPDATE ops.idempotency_keys SET response_status=200,response_body=v_receipt,resource_type='SupplierRelationshipAssertion',resource_id=p_assertion_id::text WHERE scope='decideSupplierRelationshipAssertion' AND key_hash=v_key_hash; RETURN v_receipt;
END
$$;
ALTER FUNCTION core.decide_supplier_relationship_assertion_v1(uuid,jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.decide_supplier_relationship_assertion_v1(uuid,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.decide_supplier_relationship_assertion_v1(uuid,jsonb) TO gurine_identity_api;
