BEGIN;

-- R6d authority closure is forward-only. Legacy rows without the immutable
-- authority receipts introduced here remain readable but cannot enter a new
-- classification, attestation, retention, or privacy execution path.
-- This migration seeds no operating retention schedule, response calendar,
-- organization assertion, identity proof, or privacy request.

-- Common R6d authority-closure events. Privacy execution reuses the existing
-- privacy/request and retention completion event contracts.
INSERT INTO ops.event_types(
  event_type,category,schema_version,active,payload_schema_uri,payload_schema
) VALUES
  (
    'entity.personhood_classified.v1','DOMAIN',1,true,
    'payloads/entity_personhood_classified_v1.schema.json',
    $r6d39_schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/entity.personhood_classified.v1.schema.json","type":"object","additionalProperties":false,"required":["entityKind","entityId","classification","evidenceSourceLocatorDigest","receiptDigest","classifiedAt"],"properties":{"entityKind":{"type":"string","enum":["AGENCY","SUPPLIER"]},"entityId":{"type":"string","format":"uuid"},"classification":{"type":"string","enum":["NATURAL_PERSON","NOT_NATURAL_PERSON"]},"evidenceSourceLocatorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"receiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"classifiedAt":{"type":"string","format":"date-time"}}}$r6d39_schema$::jsonb
  ),
  (
    'entity.material_use_closed.v1','DOMAIN',1,true,
    'payloads/entity_material_use_closed_v1.schema.json',
    $r6d39_schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/entity.material_use_closed.v1.schema.json","type":"object","additionalProperties":false,"required":["entityKind","entityId","personhoodReceiptDigest","closureAt","lastContractEndAt","linkedPublicationRevisionCount","receiptDigest"],"properties":{"entityKind":{"type":"string","enum":["AGENCY","SUPPLIER"]},"entityId":{"type":"string","format":"uuid"},"personhoodReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"closureAt":{"type":"string","format":"date-time"},"lastContractEndAt":{"oneOf":[{"type":"string","format":"date-time"},{"type":"null"}]},"linkedPublicationRevisionCount":{"type":"integer","minimum":0},"receiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}}$r6d39_schema$::jsonb
  ),
  (
    'entity.retention_anonymized.v1','DOMAIN',1,true,
    'payloads/entity_retention_anonymized_v1.schema.json',
    $r6d39_schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/entity.retention_anonymized.v1.schema.json","type":"object","additionalProperties":false,"required":["entityKind","entityId","executionReceiptId","executionReceiptDigest","masterRowCount","identifierRowCount","aliasRowCount","anonymizedAt"],"properties":{"entityKind":{"type":"string","enum":["AGENCY","SUPPLIER"]},"entityId":{"type":"string","format":"uuid"},"executionReceiptId":{"type":"string","format":"uuid"},"executionReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"masterRowCount":{"type":"integer","minimum":1},"identifierRowCount":{"type":"integer","minimum":0},"aliasRowCount":{"type":"integer","minimum":0},"anonymizedAt":{"type":"string","format":"date-time"}}}$r6d39_schema$::jsonb
  ),
  (
    'organization.official_channel_attested.v1','DOMAIN',1,true,
    'payloads/organization_official_channel_attested_v1.schema.json',
    $r6d39_schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/organization.official_channel_attested.v1.schema.json","type":"object","additionalProperties":false,"required":["assertionId","organizationKind","organizationId","verificationMethod","authorityReceiptDigest","registryReceiptDigest","attestedAt","expiresAt"],"properties":{"assertionId":{"type":"string","format":"uuid"},"organizationKind":{"type":"string","enum":["AGENCY","SUPPLIER"]},"organizationId":{"type":"string","format":"uuid"},"verificationMethod":{"type":"string","enum":["OFFICIAL_DOMAIN_EMAIL","OFFICIAL_DOCUMENT"]},"authorityReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"registryReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"attestedAt":{"type":"string","format":"date-time"},"expiresAt":{"type":"string","format":"date-time"}}}$r6d39_schema$::jsonb
  ),
  (
    'organization.official_channel_revoked.v1','DOMAIN',1,true,
    'payloads/organization_official_channel_revoked_v1.schema.json',
    $r6d39_schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/organization.official_channel_revoked.v1.schema.json","type":"object","additionalProperties":false,"required":["revocationId","assertionId","revocationReceiptDigest","revokedAt"],"properties":{"revocationId":{"type":"string","format":"uuid"},"assertionId":{"type":"string","format":"uuid"},"revocationReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"revokedAt":{"type":"string","format":"date-time"}}}$r6d39_schema$::jsonb
  )
ON CONFLICT(event_type) DO UPDATE SET
  category=EXCLUDED.category,
  schema_version=EXCLUDED.schema_version,
  active=EXCLUDED.active,
  payload_schema_uri=EXCLUDED.payload_schema_uri,
  payload_schema=EXCLUDED.payload_schema;

-- SPEC-CONFLICT-030 forward repair.  Response submission and editorial
-- materialization are separate commits, so the reciprocal foreign keys must
-- skip an entirely absent ownership tuple while retaining exact bidirectional
-- enforcement once every ownership field is present.  Explicit CHECKs retain
-- the zero-or-all protection that MATCH FULL previously supplied too early.
ALTER TABLE intake.response_submissions
  DROP CONSTRAINT response_submissions_editorial_response_reciprocal_fk,
  ADD CONSTRAINT response_submissions_editorial_response_reciprocal_fk
  FOREIGN KEY(
    editorial_response_id,response_request_id,id,receipt_version,
    receipt_digest,owned_intake_event_id,owned_intake_event_envelope_digest,
    owned_intake_receipt_digest
  ) REFERENCES editorial.responses(
    id,response_request_id,submission_id,submission_receipt_version,
    submission_receipt_digest,owned_intake_event_id,
    owned_intake_event_envelope_digest,owned_intake_receipt_digest
  ) MATCH SIMPLE ON DELETE RESTRICT
    DEFERRABLE INITIALLY DEFERRED NOT VALID,
  ADD CONSTRAINT response_submissions_reciprocal_nullness_ck CHECK (
    (
      editorial_response_id IS NULL
      AND owned_intake_event_id IS NULL
      AND owned_intake_event_envelope_digest IS NULL
      AND owned_intake_receipt_digest IS NULL
    ) OR (
      editorial_response_id IS NOT NULL
      AND owned_intake_event_id IS NOT NULL
      AND owned_intake_event_envelope_digest IS NOT NULL
      AND owned_intake_receipt_digest IS NOT NULL
    )
  );

ALTER TABLE editorial.responses
  DROP CONSTRAINT editorial_responses_submission_reciprocal_fk,
  ADD CONSTRAINT editorial_responses_submission_reciprocal_fk FOREIGN KEY(
    submission_id,response_request_id,submission_receipt_version,
    submission_receipt_digest,id,owned_intake_event_id,
    owned_intake_event_envelope_digest,owned_intake_receipt_digest
  ) REFERENCES intake.response_submissions(
    id,response_request_id,receipt_version,receipt_digest,
    editorial_response_id,owned_intake_event_id,
    owned_intake_event_envelope_digest,owned_intake_receipt_digest
  ) MATCH SIMPLE ON DELETE RESTRICT
    DEFERRABLE INITIALLY DEFERRED NOT VALID,
  ADD CONSTRAINT editorial_responses_reciprocal_nullness_ck CHECK (
    (
      submission_id IS NULL
      AND submission_receipt_version IS NULL
      AND submission_receipt_digest IS NULL
      AND owned_intake_event_id IS NULL
      AND owned_intake_event_envelope_digest IS NULL
      AND owned_intake_receipt_digest IS NULL
    ) OR (
      submission_id IS NOT NULL
      AND response_request_id IS NOT NULL
      AND submission_receipt_version IS NOT NULL
      AND submission_receipt_digest IS NOT NULL
      AND owned_intake_event_id IS NOT NULL
      AND owned_intake_event_envelope_digest IS NOT NULL
      AND owned_intake_receipt_digest IS NOT NULL
    )
  );

ALTER FUNCTION editorial.materialize_response_submission_v2(
  editorial.response_submission_intake_materialize_v1,uuid,char(64),char(64)
) RENAME TO materialize_response_submission_v2_pre_r6d_reciprocal_fix;
REVOKE ALL ON FUNCTION
  editorial.materialize_response_submission_v2_pre_r6d_reciprocal_fix(
    editorial.response_submission_intake_materialize_v1,uuid,char(64),char(64)
  ) FROM PUBLIC,gurine_workflow_worker;

CREATE OR REPLACE FUNCTION editorial.materialize_response_submission_v2(
  p_intake_receipt editorial.response_submission_intake_materialize_v1,
  p_actor_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS editorial.response_submission_intake_materialize_receipt_v2
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,pg_temp
AS $response_reciprocal_forward_fix$
BEGIN
  -- The existing response-submission RLS policy is request-bound.  The
  -- SECURITY DEFINER owner is not a workflow-worker role member, so carry the
  -- event-bound request identity into the private owner before its first read.
  PERFORM set_config(
    'gurine.response_request_id',
    (p_intake_receipt).response_request_id::text,
    true
  );
  SET CONSTRAINTS
    editorial.editorial_responses_submission_reciprocal_fk,
    intake.response_submissions_editorial_response_reciprocal_fk
    DEFERRED;
  RETURN editorial.materialize_response_submission_v2_pre_r6d_reciprocal_fix(
    p_intake_receipt,p_actor_id,p_idempotency_key,p_request_digest
  );
END
$response_reciprocal_forward_fix$;
ALTER FUNCTION editorial.materialize_response_submission_v2(
  editorial.response_submission_intake_materialize_v1,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.materialize_response_submission_v2(
  editorial.response_submission_intake_materialize_v1,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.materialize_response_submission_v2(
  editorial.response_submission_intake_materialize_v1,uuid,char(64),char(64)
) TO gurine_workflow_worker;

-- R6d D1 entity-personhood and material-use closure.
-- This fragment is embedded inside migration 0039's transaction.  It must not
-- contain BEGIN/COMMIT and it deliberately seeds no operating policy row.

-- Entity legal-hold placement and entity closure must serialize on the same
-- immutable subject identity.  The 0038 owner locks only the snapshot target
-- tuple, so retain it as a private implementation and put the entity fence in
-- front of its unchanged behavior and result ABI.
ALTER FUNCTION ops.place_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) RENAME TO place_legal_hold_v2_pre_r6d_entity_fence;
REVOKE ALL ON FUNCTION ops.place_legal_hold_v2_pre_r6d_entity_fence(
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
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $r6d_entity_hold_fence$
DECLARE
  v_target jsonb:=p_payload->'target';
  v_target_kind text:=v_target->>'targetKind';
  v_expected_subject_kind text;
  v_snapshot_id uuid;
  v_snapshot_version bigint;
  v_snapshot_digest char(64);
  v_subject_id uuid;
BEGIN
  IF jsonb_typeof(v_target)='object'
     AND (SELECT count(*) FROM jsonb_object_keys(v_target))=7
     AND v_target ?& ARRAY[
       'targetKind','targetId','targetVersion','targetDigest','entityKind',
       'entityRetentionSnapshotId','entityRetentionSnapshotDigest'
     ]
     AND v_target_kind IN (
       'AGENCY_RETENTION_SNAPSHOT','SUPPLIER_RETENTION_SNAPSHOT'
     )
     AND v_target->>'targetId' ~
       '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     AND v_target->>'targetVersion' ~ '^[1-9][0-9]*$'
     AND pg_input_is_valid(v_target->>'targetVersion','bigint')
     AND v_target->>'targetDigest' ~ '^[0-9a-f]{64}$'
     AND v_target->>'entityRetentionSnapshotId'=v_target->>'targetId'
     AND v_target->>'entityRetentionSnapshotDigest'=
       v_target->>'targetDigest' THEN
    v_expected_subject_kind:=CASE v_target_kind
      WHEN 'AGENCY_RETENTION_SNAPSHOT' THEN 'AGENCY' ELSE 'SUPPLIER' END;
    IF v_target->>'entityKind'=v_expected_subject_kind THEN
      v_snapshot_id:=(v_target->>'targetId')::uuid;
      v_snapshot_version:=(v_target->>'targetVersion')::bigint;
      v_snapshot_digest:=(v_target->>'targetDigest')::char(64);
      SELECT snapshot.subject_id INTO v_subject_id
      FROM ops.entity_retention_snapshots_v1 AS snapshot
      WHERE snapshot.snapshot_id=v_snapshot_id
        AND snapshot.subject_kind=v_expected_subject_kind
        AND snapshot.subject_version=v_snapshot_version
        AND snapshot.snapshot_digest=v_snapshot_digest
      FOR SHARE;
      IF FOUND THEN
        PERFORM pg_advisory_xact_lock(
          hashtextextended(v_subject_id::text,13)
        );
      END IF;
    END IF;
  END IF;
  RETURN ops.place_legal_hold_v2_pre_r6d_entity_fence(
    p_payload,p_actor_id,p_request_id,p_idempotency_key,p_request_digest
  );
END
$r6d_entity_hold_fence$;
ALTER FUNCTION ops.place_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.place_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.place_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

ALTER TABLE core.agencies
  ALTER COLUMN canonical_name DROP NOT NULL,
  ADD COLUMN r6d_canonical_name_digest char(64),
  ADD COLUMN r6d_jurisdiction_digest char(64),
  ADD COLUMN r6d_anonymization_state text NOT NULL DEFAULT 'STAGED_LEGACY',
  ADD COLUMN r6d_personhood_receipt_id uuid,
  ADD COLUMN r6d_personhood_receipt_digest char(64),
  ADD COLUMN r6d_closure_receipt_id uuid,
  ADD COLUMN r6d_closure_receipt_digest char(64),
  ADD COLUMN r6d_anonymized_at timestamptz,
  ADD COLUMN r6d_anonymization_receipt_digest char(64);
ALTER TABLE core.suppliers
  ALTER COLUMN canonical_name DROP NOT NULL,
  ADD COLUMN r6d_canonical_name_digest char(64),
  ADD COLUMN r6d_anonymization_state text NOT NULL DEFAULT 'STAGED_LEGACY',
  ADD COLUMN r6d_personhood_receipt_id uuid,
  ADD COLUMN r6d_personhood_receipt_digest char(64),
  ADD COLUMN r6d_closure_receipt_id uuid,
  ADD COLUMN r6d_closure_receipt_digest char(64),
  ADD COLUMN r6d_anonymized_at timestamptz,
  ADD COLUMN r6d_anonymization_receipt_digest char(64);
ALTER TABLE core.agency_identifiers
  ALTER COLUMN value DROP NOT NULL,
  ADD COLUMN r6d_value_digest char(64),
  ADD COLUMN r6d_anonymization_state text NOT NULL DEFAULT 'STAGED_LEGACY',
  ADD COLUMN r6d_anonymized_at timestamptz,
  ADD COLUMN r6d_anonymization_receipt_digest char(64);
ALTER TABLE core.supplier_identifiers
  ADD COLUMN r6d_display_value_digest char(64),
  ADD COLUMN r6d_anonymization_state text NOT NULL DEFAULT 'STAGED_LEGACY',
  ADD COLUMN r6d_anonymized_at timestamptz,
  ADD COLUMN r6d_anonymization_receipt_digest char(64);
ALTER TABLE core.entity_aliases
  ALTER COLUMN alias DROP NOT NULL,
  ALTER COLUMN normalized_alias DROP NOT NULL,
  ADD COLUMN r6d_alias_digest char(64),
  ADD COLUMN r6d_normalized_alias_digest char(64),
  ADD COLUMN r6d_anonymization_state text NOT NULL DEFAULT 'STAGED_LEGACY',
  ADD COLUMN r6d_anonymized_at timestamptz,
  ADD COLUMN r6d_anonymization_receipt_digest char(64);

-- Public entity rows are live projections, not immutable publication
-- revisions.  Preserve their stable IDs and contract foreign keys while
-- allowing the natural-person plaintext projection to be removed.
ALTER TABLE public.agencies ALTER COLUMN name DROP NOT NULL;
ALTER TABLE public.suppliers ALTER COLUMN name DROP NOT NULL;

CREATE TABLE ops.r6d_entity_personhood_classification_receipts_v1 (
  receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_kind text NOT NULL,
  entity_id uuid NOT NULL,
  classification text NOT NULL,
  classification_version bigint NOT NULL,
  entity_updated_at timestamptz NOT NULL,
  evidence_source_locator_digest char(64) NOT NULL,
  reason_digest char(64) NOT NULL,
  capability_authority_digest char(64) NOT NULL,
  actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  session_id uuid NOT NULL REFERENCES ops.sessions(id) ON DELETE RESTRICT,
  actor_assertion_jti uuid NOT NULL UNIQUE,
  actor_assertion_request_digest char(64) NOT NULL,
  step_up_authorization_id uuid NOT NULL UNIQUE
    REFERENCES ops.step_up_authorizations(id) ON DELETE RESTRICT,
  step_up_receipt_digest char(64) NOT NULL,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  outbox_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  classified_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT r6d_entity_personhood_id_digest_uq
    UNIQUE(receipt_id,receipt_digest),
  CONSTRAINT r6d_entity_personhood_subject_uq
    UNIQUE(entity_kind,entity_id),
  CONSTRAINT r6d_entity_personhood_shape_ck CHECK (
    entity_kind IN ('AGENCY','SUPPLIER')
    AND classification IN ('NATURAL_PERSON','NOT_NATURAL_PERSON')
    AND classification_version=1
    AND ops.r6d_lower_sha256(evidence_source_locator_digest)
    AND ops.r6d_lower_sha256(reason_digest)
    AND ops.r6d_lower_sha256(capability_authority_digest)
    AND ops.r6d_lower_sha256(actor_assertion_request_digest)
    AND ops.r6d_lower_sha256(step_up_receipt_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND receipt_payload ?& ARRAY[
      'schemaVersion','receiptId','entityKind','entityId','classification',
      'classificationVersion','entityUpdatedAt',
      'evidenceSourceLocatorDigest','reasonDigest',
      'capabilityAuthorityDigest','actorId','sessionId',
      'actorAssertionJti','actorAssertionRequestDigest',
      'stepUpAuthorizationId','stepUpReceiptDigest','requestId',
      'idempotencyKeySha256','requestDigest','auditEventId','classifiedAt'
    ]
    AND receipt_payload-ARRAY[
      'schemaVersion','receiptId','entityKind','entityId','classification',
      'classificationVersion','entityUpdatedAt',
      'evidenceSourceLocatorDigest','reasonDigest',
      'capabilityAuthorityDigest','actorId','sessionId',
      'actorAssertionJti','actorAssertionRequestDigest',
      'stepUpAuthorizationId','stepUpReceiptDigest','requestId',
      'idempotencyKeySha256','requestDigest','auditEventId','classifiedAt'
    ]='{}'::jsonb
    AND receipt_payload->>'schemaVersion'=
      'r6d-entity-personhood-classification-receipt.v1'
    AND (receipt_payload->>'receiptId')::uuid=receipt_id
    AND receipt_payload->>'entityKind'=entity_kind
    AND (receipt_payload->>'entityId')::uuid=entity_id
    AND receipt_payload->>'classification'=classification
    AND (receipt_payload->>'classificationVersion')::bigint=
      classification_version
    AND (receipt_payload->>'entityUpdatedAt')::timestamptz=entity_updated_at
    AND receipt_payload->>'evidenceSourceLocatorDigest'=
      btrim(evidence_source_locator_digest)
    AND receipt_payload->>'reasonDigest'=btrim(reason_digest)
    AND receipt_payload->>'capabilityAuthorityDigest'=
      btrim(capability_authority_digest)
    AND (receipt_payload->>'actorId')::uuid=actor_id
    AND (receipt_payload->>'sessionId')::uuid=session_id
    AND (receipt_payload->>'actorAssertionJti')::uuid=actor_assertion_jti
    AND receipt_payload->>'actorAssertionRequestDigest'=
      btrim(actor_assertion_request_digest)
    AND (receipt_payload->>'stepUpAuthorizationId')::uuid=
      step_up_authorization_id
    AND receipt_payload->>'stepUpReceiptDigest'=btrim(step_up_receipt_digest)
    AND (receipt_payload->>'requestId')::uuid=request_id
    AND receipt_payload->>'idempotencyKeySha256'=
      btrim(idempotency_key_sha256)
    AND receipt_payload->>'requestDigest'=btrim(request_digest)
    AND (receipt_payload->>'auditEventId')::uuid=audit_event_id
    AND (receipt_payload->>'classifiedAt')::timestamptz=classified_at
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_canonical=ops.canonical_jsonb_v1(receipt_payload)
    AND receipt_digest=encode(
      extensions.digest(receipt_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE ops.r6d_entity_personhood_classification_receipts_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON ops.r6d_entity_personhood_classification_receipts_v1
  FROM PUBLIC;
GRANT SELECT ON ops.r6d_entity_personhood_classification_receipts_v1
  TO gurine_control_api,gurine_workflow_worker,gurine_scheduler,gurine_auditor;
CREATE TRIGGER r6d_entity_personhood_receipts_immutable_guard
  BEFORE UPDATE OR DELETE
  ON ops.r6d_entity_personhood_classification_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE TABLE ops.r6d_entity_material_use_closure_receipts_v1 (
  receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_kind text NOT NULL,
  entity_id uuid NOT NULL,
  closure_version bigint NOT NULL,
  entity_updated_at timestamptz NOT NULL,
  personhood_receipt_id uuid NOT NULL,
  personhood_receipt_digest char(64) NOT NULL,
  contract_count bigint NOT NULL,
  contract_set_digest char(64) NOT NULL,
  final_contract_end_at date,
  final_contract_boundary_at timestamptz,
  publication_revision_count bigint NOT NULL,
  publication_revision_set_digest char(64) NOT NULL,
  open_publication_revision_count bigint NOT NULL,
  legal_hold_coverage_digest char(64) NOT NULL,
  reason_digest char(64) NOT NULL,
  capability_authority_digest char(64) NOT NULL,
  actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  session_id uuid NOT NULL REFERENCES ops.sessions(id) ON DELETE RESTRICT,
  actor_assertion_jti uuid NOT NULL UNIQUE,
  actor_assertion_request_digest char(64) NOT NULL,
  step_up_authorization_id uuid NOT NULL UNIQUE
    REFERENCES ops.step_up_authorizations(id) ON DELETE RESTRICT,
  step_up_receipt_digest char(64) NOT NULL,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  outbox_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  closure_at timestamptz NOT NULL,
  attested_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT r6d_entity_material_closure_id_digest_uq
    UNIQUE(receipt_id,receipt_digest),
  CONSTRAINT r6d_entity_material_closure_subject_uq
    UNIQUE(entity_kind,entity_id),
  CONSTRAINT r6d_entity_material_closure_personhood_fk FOREIGN KEY(
    personhood_receipt_id,personhood_receipt_digest
  ) REFERENCES ops.r6d_entity_personhood_classification_receipts_v1(
    receipt_id,receipt_digest
  ) ON DELETE RESTRICT,
  CONSTRAINT r6d_entity_material_closure_shape_ck CHECK (
    entity_kind IN ('AGENCY','SUPPLIER')
    AND closure_version=1
    AND contract_count>=0
    AND publication_revision_count>=0
    AND open_publication_revision_count=0
    AND (
      (contract_count=0 AND final_contract_end_at IS NULL
        AND final_contract_boundary_at IS NULL)
      OR (contract_count>0 AND final_contract_end_at IS NOT NULL
        AND final_contract_boundary_at=
          ((final_contract_end_at+1)::timestamp AT TIME ZONE 'Asia/Seoul'))
    )
    AND closure_at=attested_at
    AND (final_contract_boundary_at IS NULL
      OR closure_at>=final_contract_boundary_at)
    AND ops.r6d_lower_sha256(personhood_receipt_digest)
    AND ops.r6d_lower_sha256(contract_set_digest)
    AND ops.r6d_lower_sha256(publication_revision_set_digest)
    AND ops.r6d_lower_sha256(legal_hold_coverage_digest)
    AND ops.r6d_lower_sha256(reason_digest)
    AND ops.r6d_lower_sha256(capability_authority_digest)
    AND ops.r6d_lower_sha256(actor_assertion_request_digest)
    AND ops.r6d_lower_sha256(step_up_receipt_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND receipt_payload ?& ARRAY[
      'schemaVersion','receiptId','entityKind','entityId','closureVersion',
      'entityUpdatedAt',
      'personhoodReceiptId','personhoodReceiptDigest','contractCount',
      'contractSetDigest','finalContractEndAt','finalContractBoundaryAt',
      'publicationRevisionCount','publicationRevisionSetDigest',
      'openPublicationRevisionCount','legalHoldCoverageDigest','reasonDigest',
      'capabilityAuthorityDigest','actorId','sessionId',
      'actorAssertionJti','actorAssertionRequestDigest',
      'stepUpAuthorizationId','stepUpReceiptDigest','requestId',
      'idempotencyKeySha256','requestDigest','auditEventId','closureAt',
      'attestedAt'
    ]
    AND receipt_payload-ARRAY[
      'schemaVersion','receiptId','entityKind','entityId','closureVersion',
      'entityUpdatedAt',
      'personhoodReceiptId','personhoodReceiptDigest','contractCount',
      'contractSetDigest','finalContractEndAt','finalContractBoundaryAt',
      'publicationRevisionCount','publicationRevisionSetDigest',
      'openPublicationRevisionCount','legalHoldCoverageDigest','reasonDigest',
      'capabilityAuthorityDigest','actorId','sessionId',
      'actorAssertionJti','actorAssertionRequestDigest',
      'stepUpAuthorizationId','stepUpReceiptDigest','requestId',
      'idempotencyKeySha256','requestDigest','auditEventId','closureAt',
      'attestedAt'
    ]='{}'::jsonb
    AND receipt_payload->>'schemaVersion'=
      'r6d-entity-material-use-closure-receipt.v1'
    AND (receipt_payload->>'receiptId')::uuid=receipt_id
    AND receipt_payload->>'entityKind'=entity_kind
    AND (receipt_payload->>'entityId')::uuid=entity_id
    AND (receipt_payload->>'closureVersion')::bigint=closure_version
    AND (receipt_payload->>'entityUpdatedAt')::timestamptz=entity_updated_at
    AND (receipt_payload->>'personhoodReceiptId')::uuid=
      personhood_receipt_id
    AND receipt_payload->>'personhoodReceiptDigest'=
      btrim(personhood_receipt_digest)
    AND (receipt_payload->>'contractCount')::bigint=contract_count
    AND receipt_payload->>'contractSetDigest'=btrim(contract_set_digest)
    AND CASE WHEN final_contract_end_at IS NULL
      THEN receipt_payload->'finalContractEndAt'='null'::jsonb
      ELSE (receipt_payload->>'finalContractEndAt')::date=final_contract_end_at
    END
    AND CASE WHEN final_contract_boundary_at IS NULL
      THEN receipt_payload->'finalContractBoundaryAt'='null'::jsonb
      ELSE (receipt_payload->>'finalContractBoundaryAt')::timestamptz=
        final_contract_boundary_at
    END
    AND (receipt_payload->>'publicationRevisionCount')::bigint=
      publication_revision_count
    AND receipt_payload->>'publicationRevisionSetDigest'=
      btrim(publication_revision_set_digest)
    AND (receipt_payload->>'openPublicationRevisionCount')::bigint=
      open_publication_revision_count
    AND receipt_payload->>'legalHoldCoverageDigest'=
      btrim(legal_hold_coverage_digest)
    AND receipt_payload->>'reasonDigest'=btrim(reason_digest)
    AND receipt_payload->>'capabilityAuthorityDigest'=
      btrim(capability_authority_digest)
    AND (receipt_payload->>'actorId')::uuid=actor_id
    AND (receipt_payload->>'sessionId')::uuid=session_id
    AND (receipt_payload->>'actorAssertionJti')::uuid=actor_assertion_jti
    AND receipt_payload->>'actorAssertionRequestDigest'=
      btrim(actor_assertion_request_digest)
    AND (receipt_payload->>'stepUpAuthorizationId')::uuid=
      step_up_authorization_id
    AND receipt_payload->>'stepUpReceiptDigest'=btrim(step_up_receipt_digest)
    AND (receipt_payload->>'requestId')::uuid=request_id
    AND receipt_payload->>'idempotencyKeySha256'=
      btrim(idempotency_key_sha256)
    AND receipt_payload->>'requestDigest'=btrim(request_digest)
    AND (receipt_payload->>'auditEventId')::uuid=audit_event_id
    AND (receipt_payload->>'closureAt')::timestamptz=closure_at
    AND (receipt_payload->>'attestedAt')::timestamptz=attested_at
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_canonical=ops.canonical_jsonb_v1(receipt_payload)
    AND receipt_digest=encode(
      extensions.digest(receipt_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE ops.r6d_entity_material_use_closure_receipts_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON ops.r6d_entity_material_use_closure_receipts_v1 FROM PUBLIC;
GRANT SELECT ON ops.r6d_entity_material_use_closure_receipts_v1
  TO gurine_control_api,gurine_workflow_worker,gurine_scheduler,gurine_auditor;
CREATE TRIGGER r6d_entity_material_closure_receipts_immutable_guard
  BEFORE UPDATE OR DELETE
  ON ops.r6d_entity_material_use_closure_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

ALTER TABLE core.agencies
  ADD CONSTRAINT agencies_r6d_personhood_receipt_fk FOREIGN KEY(
    r6d_personhood_receipt_id,r6d_personhood_receipt_digest
  ) REFERENCES ops.r6d_entity_personhood_classification_receipts_v1(
    receipt_id,receipt_digest
  ) MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT agencies_r6d_closure_receipt_fk FOREIGN KEY(
    r6d_closure_receipt_id,r6d_closure_receipt_digest
  ) REFERENCES ops.r6d_entity_material_use_closure_receipts_v1(
    receipt_id,receipt_digest
  ) MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT agencies_r6d_anonymization_shape_ck CHECK (
    r6d_anonymization_state IN (
      'STAGED_LEGACY','NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON','ANONYMIZED'
    )
    AND (r6d_canonical_name_digest IS NULL
      OR ops.r6d_lower_sha256(r6d_canonical_name_digest))
    AND (r6d_jurisdiction_digest IS NULL
      OR ops.r6d_lower_sha256(r6d_jurisdiction_digest))
    AND (r6d_anonymization_receipt_digest IS NULL
      OR ops.r6d_lower_sha256(r6d_anonymization_receipt_digest))
    AND (
      (r6d_anonymization_state='STAGED_LEGACY'
        AND canonical_name IS NOT NULL
        AND num_nonnulls(
          r6d_personhood_receipt_id,r6d_personhood_receipt_digest,
          r6d_closure_receipt_id,r6d_closure_receipt_digest,
          r6d_anonymized_at,r6d_anonymization_receipt_digest
        )=0)
      OR (r6d_anonymization_state IN (
          'NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON'
        ) AND canonical_name IS NOT NULL
        AND r6d_canonical_name_digest IS NOT NULL
        AND num_nonnulls(
          r6d_personhood_receipt_id,r6d_personhood_receipt_digest
        )=2
        AND r6d_anonymized_at IS NULL
        AND r6d_anonymization_receipt_digest IS NULL)
      OR (r6d_anonymization_state='ANONYMIZED'
        AND canonical_name IS NULL AND jurisdiction IS NULL
        AND r6d_canonical_name_digest IS NOT NULL
        AND num_nonnulls(
          r6d_personhood_receipt_id,r6d_personhood_receipt_digest,
          r6d_closure_receipt_id,r6d_closure_receipt_digest,
          r6d_anonymized_at,r6d_anonymization_receipt_digest
        )=6)
    )
  );
ALTER TABLE core.suppliers
  ADD CONSTRAINT suppliers_r6d_personhood_receipt_fk FOREIGN KEY(
    r6d_personhood_receipt_id,r6d_personhood_receipt_digest
  ) REFERENCES ops.r6d_entity_personhood_classification_receipts_v1(
    receipt_id,receipt_digest
  ) MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT suppliers_r6d_closure_receipt_fk FOREIGN KEY(
    r6d_closure_receipt_id,r6d_closure_receipt_digest
  ) REFERENCES ops.r6d_entity_material_use_closure_receipts_v1(
    receipt_id,receipt_digest
  ) MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT suppliers_r6d_anonymization_shape_ck CHECK (
    r6d_anonymization_state IN (
      'STAGED_LEGACY','NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON','ANONYMIZED'
    )
    AND (r6d_canonical_name_digest IS NULL
      OR ops.r6d_lower_sha256(r6d_canonical_name_digest))
    AND (r6d_anonymization_receipt_digest IS NULL
      OR ops.r6d_lower_sha256(r6d_anonymization_receipt_digest))
    AND (
      (r6d_anonymization_state='STAGED_LEGACY'
        AND canonical_name IS NOT NULL
        AND num_nonnulls(
          r6d_personhood_receipt_id,r6d_personhood_receipt_digest,
          r6d_closure_receipt_id,r6d_closure_receipt_digest,
          r6d_anonymized_at,r6d_anonymization_receipt_digest
        )=0)
      OR (r6d_anonymization_state IN (
          'NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON'
        ) AND canonical_name IS NOT NULL
        AND r6d_canonical_name_digest IS NOT NULL
        AND num_nonnulls(
          r6d_personhood_receipt_id,r6d_personhood_receipt_digest
        )=2
        AND r6d_anonymized_at IS NULL
        AND r6d_anonymization_receipt_digest IS NULL)
      OR (r6d_anonymization_state='ANONYMIZED'
        AND canonical_name IS NULL
        AND r6d_canonical_name_digest IS NOT NULL
        AND num_nonnulls(
          r6d_personhood_receipt_id,r6d_personhood_receipt_digest,
          r6d_closure_receipt_id,r6d_closure_receipt_digest,
          r6d_anonymized_at,r6d_anonymization_receipt_digest
        )=6)
    )
  );

ALTER TABLE core.agency_identifiers
  ADD CONSTRAINT agency_identifiers_r6d_anonymization_ck CHECK (
    r6d_anonymization_state IN (
      'STAGED_LEGACY','NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON','ANONYMIZED'
    )
    AND (r6d_value_digest IS NULL OR ops.r6d_lower_sha256(r6d_value_digest))
    AND (r6d_anonymization_receipt_digest IS NULL
      OR ops.r6d_lower_sha256(r6d_anonymization_receipt_digest))
    AND ((r6d_anonymization_state='STAGED_LEGACY'
          AND value IS NOT NULL AND r6d_value_digest IS NULL
          AND r6d_anonymized_at IS NULL
          AND r6d_anonymization_receipt_digest IS NULL)
      OR (r6d_anonymization_state IN (
            'NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON'
          ) AND value IS NOT NULL AND r6d_value_digest IS NOT NULL
          AND r6d_anonymized_at IS NULL
          AND r6d_anonymization_receipt_digest IS NULL)
      OR (r6d_anonymization_state='ANONYMIZED'
          AND value IS NULL AND r6d_value_digest IS NOT NULL
          AND r6d_anonymized_at IS NOT NULL
          AND r6d_anonymization_receipt_digest IS NOT NULL))
  );
ALTER TABLE core.supplier_identifiers
  ADD CONSTRAINT supplier_identifiers_r6d_anonymization_ck CHECK (
    r6d_anonymization_state IN (
      'STAGED_LEGACY','NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON','ANONYMIZED'
    )
    AND ops.r6d_lower_sha256(value_hash)
    AND (r6d_display_value_digest IS NULL
      OR ops.r6d_lower_sha256(r6d_display_value_digest))
    AND (r6d_anonymization_receipt_digest IS NULL
      OR ops.r6d_lower_sha256(r6d_anonymization_receipt_digest))
    AND ((r6d_anonymization_state='STAGED_LEGACY'
          AND r6d_display_value_digest IS NULL
          AND r6d_anonymized_at IS NULL
          AND r6d_anonymization_receipt_digest IS NULL)
      OR (r6d_anonymization_state IN (
            'NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON'
          ) AND ((display_value IS NULL)=(r6d_display_value_digest IS NULL))
          AND r6d_anonymized_at IS NULL
          AND r6d_anonymization_receipt_digest IS NULL)
      OR (r6d_anonymization_state='ANONYMIZED'
          AND display_value IS NULL
          AND r6d_anonymized_at IS NOT NULL
          AND r6d_anonymization_receipt_digest IS NOT NULL))
  );
ALTER TABLE core.entity_aliases
  ADD CONSTRAINT entity_aliases_r6d_anonymization_ck CHECK (
    r6d_anonymization_state IN (
      'STAGED_LEGACY','NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON','ANONYMIZED'
    )
    AND (r6d_alias_digest IS NULL OR ops.r6d_lower_sha256(r6d_alias_digest))
    AND (r6d_normalized_alias_digest IS NULL
      OR ops.r6d_lower_sha256(r6d_normalized_alias_digest))
    AND (r6d_anonymization_receipt_digest IS NULL
      OR ops.r6d_lower_sha256(r6d_anonymization_receipt_digest))
    AND ((r6d_anonymization_state='STAGED_LEGACY'
          AND alias IS NOT NULL AND normalized_alias IS NOT NULL
          AND r6d_alias_digest IS NULL
          AND r6d_normalized_alias_digest IS NULL
          AND r6d_anonymized_at IS NULL
          AND r6d_anonymization_receipt_digest IS NULL)
      OR (r6d_anonymization_state IN (
            'NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON'
          ) AND alias IS NOT NULL AND normalized_alias IS NOT NULL
          AND r6d_alias_digest IS NOT NULL
          AND r6d_normalized_alias_digest IS NOT NULL
          AND r6d_anonymized_at IS NULL
          AND r6d_anonymization_receipt_digest IS NULL)
      OR (r6d_anonymization_state='ANONYMIZED'
          AND alias IS NULL AND normalized_alias IS NULL
          AND r6d_alias_digest IS NOT NULL
          AND r6d_normalized_alias_digest IS NOT NULL
          AND r6d_anonymized_at IS NOT NULL
          AND r6d_anonymization_receipt_digest IS NOT NULL))
  );

CREATE INDEX agencies_r6d_personhood_idx
  ON core.agencies(r6d_anonymization_state,r6d_personhood_receipt_id,id);
CREATE INDEX suppliers_r6d_personhood_idx
  ON core.suppliers(r6d_anonymization_state,r6d_personhood_receipt_id,id);
CREATE INDEX agency_identifiers_r6d_anonymization_idx
  ON core.agency_identifiers(agency_id,r6d_anonymization_state,id);
CREATE INDEX supplier_identifiers_r6d_anonymization_idx
  ON core.supplier_identifiers(supplier_id,r6d_anonymization_state,id);
CREATE INDEX entity_aliases_r6d_anonymization_idx
  ON core.entity_aliases(entity_type,entity_id,r6d_anonymization_state,id);

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
     OR p_request->>'_actorEffectiveCapability'<>'sources.operate'
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
   AND role_capability.capability_code='sources.operate'
  WHERE user_role.user_id=p_actor_id
    AND user_role.revoked_at IS NULL
    AND (user_role.expires_at IS NULL OR user_role.expires_at>p_at_time);
  IF v_authority_count<1 THEN
    RAISE EXCEPTION 'r6d_entity_capability_invalid' USING ERRCODE='23514';
  END IF;
  v_authority_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6d-entity-data-review-authority.v1',
      'actorId',p_actor_id,'capability','sources.operate',
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
     OR p_request->>'_actorEffectiveCapability'<>'sources.operate'
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
    'sources.operate','SUCCESS',NULL,p_request_id,
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

CREATE OR REPLACE FUNCTION ops.r6d_entity_material_use_state_v1(
  p_entity_kind text,
  p_entity_id uuid,
  p_at_time timestamptz
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,core,editorial,extensions,pg_temp
AS $$
DECLARE
  v_contract_count bigint;
  v_null_end_count bigint;
  v_final_end_at date;
  v_final_boundary_at timestamptz;
  v_contract_set jsonb;
  v_contract_set_digest char(64);
  v_publication_count bigint;
  v_open_publication_count bigint;
  v_publication_set jsonb;
  v_publication_set_digest char(64);
  v_hold jsonb;
BEGIN
  IF p_entity_kind NOT IN ('AGENCY','SUPPLIER')
     OR p_entity_id IS NULL OR p_at_time IS NULL THEN
    RAISE EXCEPTION 'r6d_entity_material_use_state_input_invalid'
      USING ERRCODE='22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_entity_id::text,13));
  -- A closure receipt is a statement over complete sets.  SHARE table locks
  -- exclude concurrent inserts/updates while those sets and their digests are
  -- derived.  No caller-supplied count, boundary, or revision state is trusted.
  LOCK TABLE core.contracts,core.procurement_contract_revisions,
    core.procurement_contract_supplier_revisions,
    editorial.publication_revisions IN SHARE MODE;

  WITH latest_procurement AS (
    SELECT DISTINCT ON (contract.root_id)
      contract.root_id,contract.revision_id,contract.revision,
      contract.record_digest,contract.agency_id,contract.ends_at,
      contract.created_at
    FROM core.procurement_contract_revisions AS contract
    ORDER BY contract.root_id,contract.revision DESC,contract.revision_id DESC
  ), material_contracts AS (
    SELECT 'CORE_CONTRACT'::text AS authority_kind,contract.id AS contract_id,
      contract.end_at,contract.version::bigint AS version,
      NULL::char(64) AS record_digest,contract.updated_at AS recorded_at
    FROM core.contracts AS contract
    WHERE CASE p_entity_kind
      WHEN 'AGENCY' THEN contract.agency_id=p_entity_id
      ELSE contract.supplier_id=p_entity_id END
    UNION ALL
    SELECT 'PROCUREMENT_CONTRACT_REVISION',contract.root_id,contract.ends_at,
      contract.revision,contract.record_digest,contract.created_at
    FROM latest_procurement AS contract
    WHERE CASE p_entity_kind
      WHEN 'AGENCY' THEN contract.agency_id=p_entity_id
      ELSE EXISTS(
        SELECT 1
        FROM core.procurement_contract_supplier_revisions AS supplier
        WHERE supplier.contract_revision_id=contract.revision_id
          AND supplier.contract_root_id=contract.root_id
          AND supplier.contract_revision=contract.revision
          AND supplier.contract_record_digest=contract.record_digest
          AND supplier.canonical_supplier_id=p_entity_id
      ) END
  )
  SELECT count(*),count(*) FILTER(WHERE contract.end_at IS NULL),
    max(contract.end_at),
    COALESCE(jsonb_agg(jsonb_build_object(
      'authorityKind',contract.authority_kind,
      'contractId',contract.contract_id,'endAt',contract.end_at,
      'version',contract.version,
      'recordDigest',CASE WHEN contract.record_digest IS NULL THEN NULL
        ELSE btrim(contract.record_digest) END,
      'recordedAt',contract.recorded_at
    ) ORDER BY contract.authority_kind,contract.contract_id),'[]'::jsonb)
  INTO v_contract_count,v_null_end_count,v_final_end_at,v_contract_set
  FROM material_contracts AS contract;
  v_contract_set_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_contract_set),'sha256'
  ),'hex');
  IF v_null_end_count<>0
     OR (v_contract_count>0 AND v_final_end_at IS NULL) THEN
    RAISE EXCEPTION 'r6d_entity_material_use_contract_end_unknown'
      USING ERRCODE='55000';
  END IF;
  IF v_contract_count>0 THEN
    v_final_boundary_at:=
      ((v_final_end_at+1)::timestamp AT TIME ZONE 'Asia/Seoul');
  END IF;

  -- Published membership is bound to each immutable revision payload.  The
  -- mutable case-signal graph is only an input to payload construction and is
  -- not closure authority.  A malformed legacy revision could hide a subject,
  -- so fail closed before attempting entity-specific membership selection.
  IF EXISTS(
    SELECT 1
    FROM editorial.publication_revisions AS revision
    WHERE jsonb_typeof(revision.public_payload) IS DISTINCT FROM 'object'
      OR NOT revision.public_payload ?& ARRAY['agencyIds','supplierIds']
      OR jsonb_typeof(revision.public_payload->'agencyIds')
          IS DISTINCT FROM 'array'
      OR jsonb_typeof(revision.public_payload->'supplierIds')
          IS DISTINCT FROM 'array'
      OR revision.public_payload_sha256<>encode(extensions.digest(
        ops.canonical_jsonb_v1(revision.public_payload),'sha256'
      ),'hex')
      OR EXISTS(
        SELECT 1
        FROM jsonb_array_elements(CASE
          WHEN jsonb_typeof(revision.public_payload->'agencyIds')='array'
            THEN revision.public_payload->'agencyIds'
          ELSE '[]'::jsonb END
        ) AS member(value)
        WHERE jsonb_typeof(member.value)<>'string'
          OR member.value#>>'{}' !~
            '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
      OR EXISTS(
        SELECT 1
        FROM jsonb_array_elements(CASE
          WHEN jsonb_typeof(revision.public_payload->'supplierIds')='array'
            THEN revision.public_payload->'supplierIds'
          ELSE '[]'::jsonb END
        ) AS member(value)
        WHERE jsonb_typeof(member.value)<>'string'
          OR member.value#>>'{}' !~
            '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      )
      OR jsonb_array_length(CASE
          WHEN jsonb_typeof(revision.public_payload->'agencyIds')='array'
            THEN revision.public_payload->'agencyIds'
          ELSE '[]'::jsonb END
        )<>(SELECT count(DISTINCT member.value)
            FROM jsonb_array_elements(CASE
              WHEN jsonb_typeof(revision.public_payload->'agencyIds')='array'
                THEN revision.public_payload->'agencyIds'
              ELSE '[]'::jsonb END
            ) AS member(value))
      OR jsonb_array_length(CASE
          WHEN jsonb_typeof(revision.public_payload->'supplierIds')='array'
            THEN revision.public_payload->'supplierIds'
          ELSE '[]'::jsonb END
        )<>(SELECT count(DISTINCT member.value)
            FROM jsonb_array_elements(CASE
              WHEN jsonb_typeof(revision.public_payload->'supplierIds')='array'
                THEN revision.public_payload->'supplierIds'
              ELSE '[]'::jsonb END
            ) AS member(value))
      OR revision.public_payload->'agencyIds' IS DISTINCT FROM (
        SELECT COALESCE(jsonb_agg(
          member.value ORDER BY member.value#>>'{}'
        ),'[]'::jsonb)
        FROM jsonb_array_elements(CASE
          WHEN jsonb_typeof(revision.public_payload->'agencyIds')='array'
            THEN revision.public_payload->'agencyIds'
          ELSE '[]'::jsonb END
        ) AS member(value)
      )
      OR revision.public_payload->'supplierIds' IS DISTINCT FROM (
        SELECT COALESCE(jsonb_agg(
          member.value ORDER BY member.value#>>'{}'
        ),'[]'::jsonb)
        FROM jsonb_array_elements(CASE
          WHEN jsonb_typeof(revision.public_payload->'supplierIds')='array'
            THEN revision.public_payload->'supplierIds'
          ELSE '[]'::jsonb END
        ) AS member(value)
      )
  ) THEN
    RAISE EXCEPTION 'r6d_entity_publication_membership_invalid'
      USING ERRCODE='55000';
  END IF;

  WITH relevant AS (
    SELECT DISTINCT revision.id,revision.case_id,revision.revision,
      revision.state,revision.public_payload_sha256,revision.published_at,
      EXISTS(
        SELECT 1
        FROM editorial.publication_revisions AS successor
        WHERE successor.case_id=revision.case_id
          AND successor.supersedes_revision=revision.revision
      ) AS is_superseded
    FROM editorial.publication_revisions AS revision
    WHERE CASE p_entity_kind
      WHEN 'AGENCY' THEN revision.public_payload->'agencyIds' @>
        jsonb_build_array(p_entity_id)
      ELSE revision.public_payload->'supplierIds' @>
        jsonb_build_array(p_entity_id) END
  ), decorated AS (
    SELECT relevant.*,
      (relevant.state='RETRACTED' OR relevant.is_superseded) AS is_closed
    FROM relevant
  )
  SELECT count(*),count(*) FILTER(WHERE NOT is_closed),
    COALESCE(jsonb_agg(jsonb_build_object(
      'publicationRevisionId',id,'caseId',case_id,'revision',revision,
      'state',state,'publicPayloadSha256',btrim(public_payload_sha256),
      'publishedAt',published_at,'superseded',is_superseded,
      'closed',is_closed
    ) ORDER BY case_id,revision,id),'[]'::jsonb)
  INTO v_publication_count,v_open_publication_count,v_publication_set
  FROM decorated;
  v_publication_set_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_publication_set),'sha256'
  ),'hex');
  v_hold:=ops.r6d_entity_legal_hold_coverage_v1(
    p_entity_kind,p_entity_id,p_at_time
  );
  IF jsonb_typeof(v_hold)<>'object'
     OR NOT v_hold ?& ARRAY[
       'active','activeCellCount','coverageDigest','evaluatedAt','coverage'
     ]
     OR NOT COALESCE(ops.r6d_lower_sha256(
       v_hold->>'coverageDigest'
     ),false) THEN
    RAISE EXCEPTION 'r6d_entity_material_use_hold_proof_invalid'
      USING ERRCODE='55000';
  END IF;
  RETURN jsonb_build_object(
    'schemaVersion','r6d-entity-material-use-state.v1',
    'entityKind',p_entity_kind,'entityId',p_entity_id,
    'contractCount',v_contract_count,
    'contractSetDigest',btrim(v_contract_set_digest),
    'finalContractEndAt',v_final_end_at,
    'finalContractBoundaryAt',v_final_boundary_at,
    'publicationRevisionCount',v_publication_count,
    'publicationRevisionSetDigest',btrim(v_publication_set_digest),
    'openPublicationRevisionCount',v_open_publication_count,
    'legalHoldActive',(v_hold->>'active')::boolean,
    'legalHoldActiveCellCount',(v_hold->>'activeCellCount')::bigint,
    'legalHoldCoverageDigest',v_hold->>'coverageDigest',
    'evaluatedAt',p_at_time
  );
END
$$;
ALTER FUNCTION ops.r6d_entity_material_use_state_v1(
  text,uuid,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_entity_material_use_state_v1(
  text,uuid,timestamptz
) FROM PUBLIC;

CREATE TABLE ops.r6d_entity_retention_execution_receipts_v1 (
  execution_receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL UNIQUE REFERENCES ops.jobs(id) ON DELETE RESTRICT,
  job_fencing_token bigint NOT NULL,
  job_lease_owner_digest char(64) NOT NULL,
  job_lease_token_sha256 char(64) NOT NULL,
  job_payload_digest char(64) NOT NULL,
  entity_kind text NOT NULL,
  entity_id uuid NOT NULL,
  personhood_receipt_id uuid NOT NULL,
  personhood_receipt_digest char(64) NOT NULL,
  closure_receipt_id uuid NOT NULL,
  closure_receipt_digest char(64) NOT NULL,
  closure_at timestamptz NOT NULL,
  schedule_id uuid NOT NULL,
  schedule_record_class text NOT NULL,
  schedule_revision bigint NOT NULL,
  schedule_digest char(64) NOT NULL,
  due_at timestamptz NOT NULL,
  request_digest char(64) NOT NULL,
  idempotency_digest char(64) NOT NULL UNIQUE,
  legal_hold_coverage_digest char(64) NOT NULL,
  master_row_count bigint NOT NULL,
  identifier_row_count bigint NOT NULL,
  alias_row_count bigint NOT NULL,
  anonymized_at timestamptz NOT NULL,
  backup_disposal_due_at timestamptz NOT NULL,
  audit_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  outbox_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  execution_receipt_digest char(64) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT r6d_entity_retention_execution_id_digest_uq UNIQUE(
    execution_receipt_id,execution_receipt_digest
  ),
  CONSTRAINT r6d_entity_retention_execution_entity_uq UNIQUE(
    entity_kind,entity_id
  ),
  CONSTRAINT r6d_entity_retention_execution_personhood_fk FOREIGN KEY(
    personhood_receipt_id,personhood_receipt_digest
  ) REFERENCES ops.r6d_entity_personhood_classification_receipts_v1(
    receipt_id,receipt_digest
  ) ON DELETE RESTRICT,
  CONSTRAINT r6d_entity_retention_execution_closure_fk FOREIGN KEY(
    closure_receipt_id,closure_receipt_digest
  ) REFERENCES ops.r6d_entity_material_use_closure_receipts_v1(
    receipt_id,receipt_digest
  ) ON DELETE RESTRICT,
  CONSTRAINT r6d_entity_retention_execution_schedule_fk FOREIGN KEY(
    schedule_id,schedule_record_class,schedule_digest
  ) REFERENCES ops.record_class_schedules(
    id,record_class,schedule_digest
  ) ON DELETE RESTRICT,
  CONSTRAINT r6d_entity_retention_execution_shape_ck CHECK (
    entity_kind IN ('AGENCY','SUPPLIER')
    AND schedule_record_class=CASE entity_kind
      WHEN 'AGENCY' THEN 'AGENCY_MASTER' ELSE 'SUPPLIER_MASTER' END
    AND job_fencing_token>0 AND schedule_revision>0
    AND due_at>=closure_at AND anonymized_at>=due_at
    AND backup_disposal_due_at>anonymized_at
    AND master_row_count=1
    AND identifier_row_count>=0 AND alias_row_count>=0
    AND ops.r6d_lower_sha256(job_lease_owner_digest)
    AND ops.r6d_lower_sha256(job_lease_token_sha256)
    AND ops.r6d_lower_sha256(job_payload_digest)
    AND ops.r6d_lower_sha256(personhood_receipt_digest)
    AND ops.r6d_lower_sha256(closure_receipt_digest)
    AND ops.r6d_lower_sha256(schedule_digest)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(idempotency_digest)
    AND ops.r6d_lower_sha256(legal_hold_coverage_digest)
    AND ops.r6d_lower_sha256(execution_receipt_digest)
    AND receipt_payload ?& ARRAY[
      'schemaVersion','executionReceiptId','jobId','jobFencingToken',
      'jobLeaseOwnerDigest','jobLeaseTokenSha256','jobPayloadDigest',
      'entityKind','entityId','personhoodReceiptId',
      'personhoodReceiptDigest','closureReceiptId','closureReceiptDigest',
      'closureAt','scheduleId','scheduleRecordClass','scheduleRevision',
      'scheduleDigest','dueAt','requestDigest','idempotencyDigest',
      'legalHoldCoverageDigest','masterRowCount','identifierRowCount',
      'aliasRowCount','anonymizedAt','backupDisposalDueAt','auditEventId',
      'receiptContractVersion'
    ]
    AND receipt_payload-ARRAY[
      'schemaVersion','executionReceiptId','jobId','jobFencingToken',
      'jobLeaseOwnerDigest','jobLeaseTokenSha256','jobPayloadDigest',
      'entityKind','entityId','personhoodReceiptId',
      'personhoodReceiptDigest','closureReceiptId','closureReceiptDigest',
      'closureAt','scheduleId','scheduleRecordClass','scheduleRevision',
      'scheduleDigest','dueAt','requestDigest','idempotencyDigest',
      'legalHoldCoverageDigest','masterRowCount','identifierRowCount',
      'aliasRowCount','anonymizedAt','backupDisposalDueAt','auditEventId',
      'receiptContractVersion'
    ]='{}'::jsonb
    AND receipt_payload->>'schemaVersion'=
      'r6d-entity-retention-execution.v1'
    AND (receipt_payload->>'receiptContractVersion')::bigint=1
    AND (receipt_payload->>'executionReceiptId')::uuid=
      execution_receipt_id
    AND (receipt_payload->>'jobId')::uuid=job_id
    AND (receipt_payload->>'jobFencingToken')::bigint=job_fencing_token
    AND receipt_payload->>'jobLeaseOwnerDigest'=
      btrim(job_lease_owner_digest)
    AND receipt_payload->>'jobLeaseTokenSha256'=
      btrim(job_lease_token_sha256)
    AND receipt_payload->>'jobPayloadDigest'=btrim(job_payload_digest)
    AND receipt_payload->>'entityKind'=entity_kind
    AND (receipt_payload->>'entityId')::uuid=entity_id
    AND (receipt_payload->>'personhoodReceiptId')::uuid=
      personhood_receipt_id
    AND receipt_payload->>'personhoodReceiptDigest'=
      btrim(personhood_receipt_digest)
    AND (receipt_payload->>'closureReceiptId')::uuid=closure_receipt_id
    AND receipt_payload->>'closureReceiptDigest'=
      btrim(closure_receipt_digest)
    AND (receipt_payload->>'closureAt')::timestamptz=closure_at
    AND (receipt_payload->>'scheduleId')::uuid=schedule_id
    AND receipt_payload->>'scheduleRecordClass'=schedule_record_class
    AND (receipt_payload->>'scheduleRevision')::bigint=schedule_revision
    AND receipt_payload->>'scheduleDigest'=btrim(schedule_digest)
    AND (receipt_payload->>'dueAt')::timestamptz=due_at
    AND receipt_payload->>'requestDigest'=btrim(request_digest)
    AND receipt_payload->>'idempotencyDigest'=btrim(idempotency_digest)
    AND receipt_payload->>'legalHoldCoverageDigest'=
      btrim(legal_hold_coverage_digest)
    AND (receipt_payload->>'masterRowCount')::bigint=master_row_count
    AND (receipt_payload->>'identifierRowCount')::bigint=
      identifier_row_count
    AND (receipt_payload->>'aliasRowCount')::bigint=alias_row_count
    AND (receipt_payload->>'anonymizedAt')::timestamptz=anonymized_at
    AND (receipt_payload->>'backupDisposalDueAt')::timestamptz=
      backup_disposal_due_at
    AND (receipt_payload->>'auditEventId')::uuid=audit_event_id
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_canonical=ops.canonical_jsonb_v1(receipt_payload)
    AND execution_receipt_digest=encode(extensions.digest(
      receipt_canonical,'sha256'
    ),'hex')
  )
);
ALTER TABLE ops.r6d_entity_retention_execution_receipts_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON ops.r6d_entity_retention_execution_receipts_v1 FROM PUBLIC;
GRANT SELECT ON ops.r6d_entity_retention_execution_receipts_v1
  TO gurine_control_api,gurine_workflow_worker,gurine_scheduler,gurine_auditor;
GRANT SELECT(
  execution_receipt_id,execution_receipt_digest,entity_kind,entity_id,
  master_row_count,identifier_row_count,alias_row_count,anonymized_at,
  outbox_event_id
) ON ops.r6d_entity_retention_execution_receipts_v1
  TO gurine_public_projector;
CREATE TRIGGER r6d_entity_retention_execution_receipts_immutable_guard
  BEFORE UPDATE OR DELETE
  ON ops.r6d_entity_retention_execution_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE VIEW ops.r6d_backup_disposal_due_inventory_v1
WITH (security_barrier=true) AS
SELECT execution.execution_receipt_id,execution.execution_receipt_digest,
  execution.entity_kind,execution.entity_id,execution.schedule_id,
  execution.schedule_digest,execution.anonymized_at,
  execution.backup_disposal_due_at
FROM ops.r6d_entity_retention_execution_receipts_v1 AS execution
WHERE execution.backup_disposal_due_at<=clock_timestamp();
ALTER VIEW ops.r6d_backup_disposal_due_inventory_v1 OWNER TO gurine_migrator;
REVOKE ALL ON ops.r6d_backup_disposal_due_inventory_v1 FROM PUBLIC;
GRANT SELECT ON ops.r6d_backup_disposal_due_inventory_v1 TO gurine_auditor;

CREATE OR REPLACE FUNCTION ops.list_due_r6d_backup_disposals_v1(
  p_limit integer
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $r6d_backup_due_list$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_items jsonb;
BEGIN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'r6d_backup_disposal_list_limit_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'executionReceiptId',due.execution_receipt_id,
    'executionReceiptDigest',btrim(due.execution_receipt_digest),
    'entityKind',due.entity_kind,'entityId',due.entity_id,
    'anonymizedAt',due.anonymized_at,
    'backupDisposalDueAt',due.backup_disposal_due_at,
    'scheduleId',due.schedule_id,
    'scheduleDigest',btrim(due.schedule_digest)
  ) ORDER BY due.backup_disposal_due_at,due.execution_receipt_id),'[]'::jsonb)
  INTO v_items
  FROM (
    SELECT execution_receipt_id,execution_receipt_digest,entity_kind,
      entity_id,anonymized_at,backup_disposal_due_at,schedule_id,
      schedule_digest
    FROM ops.r6d_entity_retention_execution_receipts_v1
    WHERE backup_disposal_due_at<=v_now
    ORDER BY backup_disposal_due_at,execution_receipt_id
    LIMIT p_limit
  ) AS due;
  RETURN jsonb_build_object(
    'evaluatedAt',v_now,'dueCount',jsonb_array_length(v_items),'items',v_items
  );
END
$r6d_backup_due_list$;
ALTER FUNCTION ops.list_due_r6d_backup_disposals_v1(integer)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.list_due_r6d_backup_disposals_v1(integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.list_due_r6d_backup_disposals_v1(integer)
  TO gurine_auditor;

-- R6d authority columns are database-owned state.  Existing ingest grants are
-- narrowed to the pre-R6d columns; the SECURITY DEFINER owners above and below
-- are the only runtime writers of receipt pointers and terminal state.
REVOKE UPDATE ON core.agencies,core.suppliers,core.agency_identifiers,
  core.supplier_identifiers,core.entity_aliases FROM gurine_ingest_worker;
GRANT UPDATE(
  id,canonical_name,agency_type,jurisdiction,parent_agency_id,active,
  identity_confidence,identity_status,created_at,updated_at
) ON core.agencies TO gurine_ingest_worker;
GRANT UPDATE(
  id,canonical_name,business_status,incorporation_date,identity_confidence,
  identity_status,created_at,updated_at
) ON core.suppliers TO gurine_ingest_worker;
GRANT UPDATE(
  id,agency_id,scheme,value,source_document_id,valid_from,valid_to,created_at
) ON core.agency_identifiers TO gurine_ingest_worker;
GRANT UPDATE(
  id,supplier_id,scheme,value_hash,display_value,source_document_id,
  verification_status,created_at
) ON core.supplier_identifiers TO gurine_ingest_worker;
GRANT UPDATE(
  id,entity_type,entity_id,alias,normalized_alias,source_document_id,created_at
) ON core.entity_aliases TO gurine_ingest_worker;

-- The D1 SECURITY DEFINER owners run as gurine_migrator.  The legacy child
-- relations remain owned by the bootstrap role, so give the owner only the
-- read surface and columns needed to bind classification digests and perform
-- the terminal plaintext anonymization.
GRANT SELECT ON core.agency_identifiers,core.supplier_identifiers,
  core.entity_aliases TO gurine_migrator;
-- SHARE lock authority is required to derive a phantom-free complete contract
-- set.  PostgreSQL does not authorize that stronger lock from SELECT alone;
-- gurine_migrator is NOLOGIN and the D1 owner never mutates this relation.
GRANT UPDATE ON core.contracts TO gurine_migrator;
GRANT UPDATE(
  value,r6d_value_digest,r6d_anonymization_state,r6d_anonymized_at,
  r6d_anonymization_receipt_digest
) ON core.agency_identifiers TO gurine_migrator;
GRANT UPDATE(
  display_value,r6d_display_value_digest,r6d_anonymization_state,
  r6d_anonymized_at,r6d_anonymization_receipt_digest
) ON core.supplier_identifiers TO gurine_migrator;
GRANT UPDATE(
  alias,normalized_alias,r6d_alias_digest,r6d_normalized_alias_digest,
  r6d_anonymization_state,r6d_anonymized_at,
  r6d_anonymization_receipt_digest
) ON core.entity_aliases TO gurine_migrator;
GRANT SELECT ON public.agencies,public.suppliers TO gurine_migrator;
GRANT UPDATE(name,jurisdiction,updated_at)
  ON public.agencies TO gurine_migrator;
GRANT UPDATE(name,updated_at) ON public.suppliers TO gurine_migrator;

-- A live public projection may be refreshed long after the immutable
-- anonymization receipt was committed.  Serialize every public entity write
-- with the D1 entity fence and reject plaintext restoration from either the
-- projector role or direct DML.  The custom execution GUC is deliberately not
-- authority here: terminal state must be backed by the immutable receipt row.
CREATE OR REPLACE FUNCTION ops.guard_r6d_public_entity_plaintext_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,core,extensions,pg_temp
AS $r6d_public_entity_guard$
DECLARE
  v_entity_kind text:=CASE TG_TABLE_NAME
    WHEN 'agencies' THEN 'AGENCY' ELSE 'SUPPLIER' END;
  v_state text;
  v_personhood_id uuid;
  v_personhood_digest char(64);
  v_closure_id uuid;
  v_closure_digest char(64);
  v_anonymized_at timestamptz;
  v_execution_digest char(64);
  v_entity_id uuid;
BEGIN
  IF TG_OP='DELETE' THEN
    v_entity_id:=OLD.id;
  ELSE
    v_entity_id:=NEW.id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_entity_id::text,13));
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'r6d_public_entity_delete_forbidden'
      USING ERRCODE='42501';
  END IF;
  IF TG_OP='UPDATE' THEN
    IF NEW.id IS DISTINCT FROM OLD.id THEN
      RAISE EXCEPTION 'r6d_public_entity_identity_mutation_forbidden'
        USING ERRCODE='42501';
    END IF;
  END IF;
  IF v_entity_kind='AGENCY' THEN
    SELECT agency.r6d_anonymization_state,
      agency.r6d_personhood_receipt_id,
      agency.r6d_personhood_receipt_digest,
      agency.r6d_closure_receipt_id,agency.r6d_closure_receipt_digest,
      agency.r6d_anonymized_at,agency.r6d_anonymization_receipt_digest
    INTO v_state,v_personhood_id,v_personhood_digest,
      v_closure_id,v_closure_digest,v_anonymized_at,v_execution_digest
    FROM core.agencies AS agency WHERE agency.id=v_entity_id FOR SHARE;
  ELSE
    SELECT supplier.r6d_anonymization_state,
      supplier.r6d_personhood_receipt_id,
      supplier.r6d_personhood_receipt_digest,
      supplier.r6d_closure_receipt_id,supplier.r6d_closure_receipt_digest,
      supplier.r6d_anonymized_at,
      supplier.r6d_anonymization_receipt_digest
    INTO v_state,v_personhood_id,v_personhood_digest,
      v_closure_id,v_closure_digest,v_anonymized_at,v_execution_digest
    FROM core.suppliers AS supplier WHERE supplier.id=v_entity_id FOR SHARE;
  END IF;
  IF v_state='ANONYMIZED' THEN
    IF NOT EXISTS(
      SELECT 1
      FROM ops.r6d_entity_retention_execution_receipts_v1 AS execution
      WHERE execution.execution_receipt_digest=v_execution_digest
        AND execution.entity_kind=v_entity_kind
        AND execution.entity_id=v_entity_id
        AND execution.personhood_receipt_id=v_personhood_id
        AND execution.personhood_receipt_digest=v_personhood_digest
        AND execution.closure_receipt_id=v_closure_id
        AND execution.closure_receipt_digest=v_closure_digest
        AND execution.anonymized_at=v_anonymized_at
    ) THEN
      RAISE EXCEPTION 'r6d_public_entity_anonymization_authority_invalid'
        USING ERRCODE='55000';
    END IF;
    IF NEW.name IS NOT NULL THEN
      RAISE EXCEPTION 'r6d_public_entity_plaintext_restore_forbidden'
        USING ERRCODE='42501';
    END IF;
    IF v_entity_kind='AGENCY' THEN
      IF to_jsonb(NEW)->'jurisdiction' IS DISTINCT FROM 'null'::jsonb THEN
        RAISE EXCEPTION 'r6d_public_entity_plaintext_restore_forbidden'
          USING ERRCODE='42501';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END
$r6d_public_entity_guard$;
ALTER FUNCTION ops.guard_r6d_public_entity_plaintext_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.guard_r6d_public_entity_plaintext_v1()
  FROM PUBLIC;
CREATE TRIGGER agencies_r6d_plaintext_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.agencies
  FOR EACH ROW EXECUTE FUNCTION ops.guard_r6d_public_entity_plaintext_v1();
CREATE TRIGGER suppliers_r6d_plaintext_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.suppliers
  FOR EACH ROW EXECUTE FUNCTION ops.guard_r6d_public_entity_plaintext_v1();

CREATE OR REPLACE FUNCTION ops.guard_r6d_entity_authority_fields_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,core,extensions,pg_temp
AS $r6d_entity_guard$
DECLARE
  v_is_agency boolean:=TG_TABLE_NAME='agencies';
  v_entity_kind text:=CASE WHEN TG_TABLE_NAME='agencies'
    THEN 'AGENCY' ELSE 'SUPPLIER' END;
  v_entity_id uuid:=NEW.id;
  v_classification boolean:=
    current_setting('gurine.r6d_entity_classification',true)='1';
  v_closure boolean:=current_setting('gurine.r6d_entity_closure',true)='1';
  v_anonymization boolean:=
    current_setting('gurine.r6d_entity_anonymization',true)='1';
  v_expected_name_digest char(64);
  v_expected_jurisdiction_digest char(64);
  v_agency_invalid boolean:=false;
  v_personhood ops.r6d_entity_personhood_classification_receipts_v1%ROWTYPE;
  v_closure_receipt
    ops.r6d_entity_material_use_closure_receipts_v1%ROWTYPE;
  v_execution ops.r6d_entity_retention_execution_receipts_v1%ROWTYPE;
BEGIN
  IF TG_OP='INSERT' THEN
    IF v_is_agency THEN
      v_agency_invalid:=NEW.r6d_jurisdiction_digest IS NOT NULL;
    END IF;
    IF NEW.r6d_anonymization_state<>'STAGED_LEGACY'
       OR num_nonnulls(
         NEW.r6d_canonical_name_digest,NEW.r6d_personhood_receipt_id,
         NEW.r6d_personhood_receipt_digest,NEW.r6d_closure_receipt_id,
         NEW.r6d_closure_receipt_digest,NEW.r6d_anonymized_at,
         NEW.r6d_anonymization_receipt_digest
       )<>0 OR v_agency_invalid THEN
      RAISE EXCEPTION 'r6d_entity_authority_caller_override'
        USING ERRCODE='42501';
    END IF;
    RETURN NEW;
  END IF;

  IF v_classification
     AND OLD.r6d_anonymization_state='STAGED_LEGACY'
     AND NEW.r6d_anonymization_state IN (
       'NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON'
     ) THEN
    SELECT * INTO v_personhood
    FROM ops.r6d_entity_personhood_classification_receipts_v1
    WHERE receipt_id=NEW.r6d_personhood_receipt_id
      AND receipt_digest=NEW.r6d_personhood_receipt_digest
    FOR SHARE;
    v_expected_name_digest:=encode(extensions.digest(
      convert_to(NEW.canonical_name,'UTF8'),'sha256'
    ),'hex');
    IF v_is_agency THEN
      IF NEW.jurisdiction IS NOT NULL THEN
        v_expected_jurisdiction_digest:=encode(extensions.digest(
          convert_to(NEW.jurisdiction,'UTF8'),'sha256'
        ),'hex');
      END IF;
    END IF;
    IF v_is_agency THEN
      v_agency_invalid:=NEW.r6d_jurisdiction_digest IS DISTINCT FROM
        v_expected_jurisdiction_digest;
    END IF;
    IF NEW.canonical_name IS NULL
       OR v_personhood.receipt_id IS NULL
       OR v_personhood.entity_kind<>v_entity_kind
       OR v_personhood.entity_id<>v_entity_id
       OR v_personhood.entity_updated_at<>OLD.updated_at
       OR v_personhood.classification<>(CASE NEW.r6d_anonymization_state
          WHEN 'NATURAL_PERSON_ACTIVE' THEN 'NATURAL_PERSON'
          ELSE 'NOT_NATURAL_PERSON' END)
       OR btrim(NEW.r6d_canonical_name_digest)<>
          btrim(v_expected_name_digest)
       OR num_nonnulls(
         NEW.r6d_personhood_receipt_id,
         NEW.r6d_personhood_receipt_digest
       )<>2
       OR num_nonnulls(
         NEW.r6d_closure_receipt_id,NEW.r6d_closure_receipt_digest,
         NEW.r6d_anonymized_at,NEW.r6d_anonymization_receipt_digest
       )<>0 OR v_agency_invalid THEN
      RAISE EXCEPTION 'r6d_entity_classification_transition_invalid'
        USING ERRCODE='55000';
    END IF;
    RETURN NEW;
  END IF;

  IF v_closure
     AND OLD.r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
     AND NEW.r6d_anonymization_state='NATURAL_PERSON_ACTIVE' THEN
    SELECT * INTO v_closure_receipt
    FROM ops.r6d_entity_material_use_closure_receipts_v1
    WHERE receipt_id=NEW.r6d_closure_receipt_id
      AND receipt_digest=NEW.r6d_closure_receipt_digest
    FOR SHARE;
    IF v_is_agency THEN
      v_agency_invalid:=NEW.r6d_jurisdiction_digest IS DISTINCT FROM
        OLD.r6d_jurisdiction_digest;
    END IF;
    IF ROW(
         NEW.r6d_canonical_name_digest,NEW.r6d_personhood_receipt_id,
         NEW.r6d_personhood_receipt_digest,NEW.r6d_anonymized_at,
         NEW.r6d_anonymization_receipt_digest
       ) IS DISTINCT FROM ROW(
         OLD.r6d_canonical_name_digest,OLD.r6d_personhood_receipt_id,
         OLD.r6d_personhood_receipt_digest,OLD.r6d_anonymized_at,
         OLD.r6d_anonymization_receipt_digest
       )
       OR v_closure_receipt.receipt_id IS NULL
       OR v_closure_receipt.entity_kind<>v_entity_kind
       OR v_closure_receipt.entity_id<>v_entity_id
       OR v_closure_receipt.entity_updated_at<>OLD.updated_at
       OR (v_closure_receipt.personhood_receipt_id,
           v_closure_receipt.personhood_receipt_digest) IS DISTINCT FROM
          (OLD.r6d_personhood_receipt_id,
           OLD.r6d_personhood_receipt_digest)
       OR num_nonnulls(
         OLD.r6d_closure_receipt_id,OLD.r6d_closure_receipt_digest
       )<>0
       OR num_nonnulls(
         NEW.r6d_closure_receipt_id,NEW.r6d_closure_receipt_digest
       )<>2 OR v_agency_invalid THEN
      RAISE EXCEPTION 'r6d_entity_closure_transition_invalid'
        USING ERRCODE='55000';
    END IF;
    RETURN NEW;
  END IF;

  IF v_anonymization
     AND OLD.r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
     AND NEW.r6d_anonymization_state='ANONYMIZED' THEN
    SELECT * INTO v_execution
    FROM ops.r6d_entity_retention_execution_receipts_v1
    WHERE execution_receipt_digest=NEW.r6d_anonymization_receipt_digest
    FOR SHARE;
    IF v_is_agency THEN
      v_agency_invalid:=NEW.jurisdiction IS NOT NULL
        OR NEW.r6d_jurisdiction_digest IS DISTINCT FROM
          OLD.r6d_jurisdiction_digest;
    END IF;
    IF NEW.canonical_name IS NOT NULL
       OR v_agency_invalid
       OR NEW.r6d_canonical_name_digest IS DISTINCT FROM
          OLD.r6d_canonical_name_digest
       OR v_execution.execution_receipt_id IS NULL
       OR v_execution.entity_kind<>v_entity_kind
       OR v_execution.entity_id<>v_entity_id
       OR v_execution.personhood_receipt_id<>
          OLD.r6d_personhood_receipt_id
       OR v_execution.personhood_receipt_digest<>
          OLD.r6d_personhood_receipt_digest
       OR v_execution.closure_receipt_id<>OLD.r6d_closure_receipt_id
       OR v_execution.closure_receipt_digest<>
          OLD.r6d_closure_receipt_digest
       OR v_execution.anonymized_at<>NEW.r6d_anonymized_at
       OR v_execution.master_row_count<>1
       OR ROW(
         NEW.r6d_personhood_receipt_id,NEW.r6d_personhood_receipt_digest,
         NEW.r6d_closure_receipt_id,NEW.r6d_closure_receipt_digest
       ) IS DISTINCT FROM ROW(
         OLD.r6d_personhood_receipt_id,OLD.r6d_personhood_receipt_digest,
         OLD.r6d_closure_receipt_id,OLD.r6d_closure_receipt_digest
       )
       OR num_nonnulls(
         NEW.r6d_anonymized_at,NEW.r6d_anonymization_receipt_digest
       )<>2 THEN
      RAISE EXCEPTION 'r6d_entity_anonymization_transition_invalid'
        USING ERRCODE='55000';
    END IF;
    RETURN NEW;
  END IF;

  IF v_is_agency THEN
    v_agency_invalid:=NEW.r6d_jurisdiction_digest IS DISTINCT FROM
      OLD.r6d_jurisdiction_digest;
  END IF;
  IF ROW(
       NEW.r6d_anonymization_state,NEW.r6d_canonical_name_digest,
       NEW.r6d_personhood_receipt_id,NEW.r6d_personhood_receipt_digest,
       NEW.r6d_closure_receipt_id,NEW.r6d_closure_receipt_digest,
       NEW.r6d_anonymized_at,NEW.r6d_anonymization_receipt_digest
     ) IS DISTINCT FROM ROW(
       OLD.r6d_anonymization_state,OLD.r6d_canonical_name_digest,
       OLD.r6d_personhood_receipt_id,OLD.r6d_personhood_receipt_digest,
       OLD.r6d_closure_receipt_id,OLD.r6d_closure_receipt_digest,
       OLD.r6d_anonymized_at,OLD.r6d_anonymization_receipt_digest
     ) OR v_agency_invalid THEN
    RAISE EXCEPTION 'r6d_entity_authority_caller_override'
      USING ERRCODE='42501';
  END IF;
  IF OLD.r6d_anonymization_state='ANONYMIZED' THEN
    IF v_is_agency THEN
      v_agency_invalid:=NEW.jurisdiction IS NOT NULL;
    END IF;
    IF NEW.canonical_name IS NOT NULL OR v_agency_invalid THEN
      RAISE EXCEPTION 'r6d_entity_plaintext_restore_forbidden'
        USING ERRCODE='42501';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.r6d_anonymization_state IN (
       'NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON'
     ) AND NEW.canonical_name IS DISTINCT FROM OLD.canonical_name THEN
    NEW.r6d_canonical_name_digest:=encode(extensions.digest(
      convert_to(NEW.canonical_name,'UTF8'),'sha256'
    ),'hex');
  END IF;
  IF v_is_agency THEN
    IF OLD.r6d_anonymization_state IN (
         'NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON'
       ) AND NEW.jurisdiction IS DISTINCT FROM OLD.jurisdiction THEN
      NEW.r6d_jurisdiction_digest:=CASE WHEN NEW.jurisdiction IS NULL
        THEN NULL ELSE encode(extensions.digest(
          convert_to(NEW.jurisdiction,'UTF8'),'sha256'
        ),'hex') END;
    END IF;
  END IF;
  RETURN NEW;
END
$r6d_entity_guard$;
ALTER FUNCTION ops.guard_r6d_entity_authority_fields_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.guard_r6d_entity_authority_fields_v1()
  FROM PUBLIC;

CREATE TRIGGER agencies_r6d_authority_guard
  BEFORE INSERT OR UPDATE ON core.agencies
  FOR EACH ROW EXECUTE FUNCTION ops.guard_r6d_entity_authority_fields_v1();
CREATE TRIGGER suppliers_r6d_authority_guard
  BEFORE INSERT OR UPDATE ON core.suppliers
  FOR EACH ROW EXECUTE FUNCTION ops.guard_r6d_entity_authority_fields_v1();

CREATE OR REPLACE FUNCTION ops.guard_r6d_entity_child_authority_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,core,extensions,pg_temp
AS $r6d_entity_child_guard$
DECLARE
  v_parent_state text;
  v_parent_entity_kind text;
  v_parent_entity_id uuid;
  v_parent_personhood_id uuid;
  v_parent_personhood_digest char(64);
  v_parent_closure_id uuid;
  v_parent_closure_digest char(64);
  v_parent_anonymized_at timestamptz;
  v_parent_anonymization_digest char(64);
  v_expected_child_digest char(64);
  v_invalid boolean;
  v_classification boolean:=
    current_setting('gurine.r6d_entity_classification',true)='1';
  v_anonymization boolean:=
    current_setting('gurine.r6d_entity_anonymization',true)='1';
BEGIN
  IF TG_TABLE_NAME='agency_identifiers' THEN
    v_parent_entity_kind:='AGENCY';
    v_parent_entity_id:=NEW.agency_id;
    SELECT r6d_anonymization_state,r6d_personhood_receipt_id,
      r6d_personhood_receipt_digest,r6d_closure_receipt_id,
      r6d_closure_receipt_digest,r6d_anonymized_at,
      r6d_anonymization_receipt_digest
    INTO v_parent_state,v_parent_personhood_id,v_parent_personhood_digest,
      v_parent_closure_id,v_parent_closure_digest,v_parent_anonymized_at,
      v_parent_anonymization_digest
    FROM core.agencies WHERE id=v_parent_entity_id FOR SHARE;
  ELSIF TG_TABLE_NAME='supplier_identifiers' THEN
    v_parent_entity_kind:='SUPPLIER';
    v_parent_entity_id:=NEW.supplier_id;
    SELECT r6d_anonymization_state,r6d_personhood_receipt_id,
      r6d_personhood_receipt_digest,r6d_closure_receipt_id,
      r6d_closure_receipt_digest,r6d_anonymized_at,
      r6d_anonymization_receipt_digest
    INTO v_parent_state,v_parent_personhood_id,v_parent_personhood_digest,
      v_parent_closure_id,v_parent_closure_digest,v_parent_anonymized_at,
      v_parent_anonymization_digest
    FROM core.suppliers WHERE id=v_parent_entity_id FOR SHARE;
  ELSIF NEW.entity_type='AGENCY' THEN
    v_parent_entity_kind:='AGENCY';
    v_parent_entity_id:=NEW.entity_id;
    SELECT r6d_anonymization_state,r6d_personhood_receipt_id,
      r6d_personhood_receipt_digest,r6d_closure_receipt_id,
      r6d_closure_receipt_digest,r6d_anonymized_at,
      r6d_anonymization_receipt_digest
    INTO v_parent_state,v_parent_personhood_id,v_parent_personhood_digest,
      v_parent_closure_id,v_parent_closure_digest,v_parent_anonymized_at,
      v_parent_anonymization_digest
    FROM core.agencies WHERE id=v_parent_entity_id FOR SHARE;
  ELSE
    v_parent_entity_kind:='SUPPLIER';
    v_parent_entity_id:=NEW.entity_id;
    SELECT r6d_anonymization_state,r6d_personhood_receipt_id,
      r6d_personhood_receipt_digest,r6d_closure_receipt_id,
      r6d_closure_receipt_digest,r6d_anonymized_at,
      r6d_anonymization_receipt_digest
    INTO v_parent_state,v_parent_personhood_id,v_parent_personhood_digest,
      v_parent_closure_id,v_parent_closure_digest,v_parent_anonymized_at,
      v_parent_anonymization_digest
    FROM core.suppliers WHERE id=v_parent_entity_id FOR SHARE;
  END IF;
  IF v_parent_state IS NULL THEN
    RAISE EXCEPTION 'r6d_entity_child_parent_missing'
      USING ERRCODE='23503';
  END IF;
  IF TG_TABLE_NAME='supplier_identifiers' THEN
    v_expected_child_digest:=CASE WHEN NEW.display_value IS NULL THEN NULL
      ELSE encode(extensions.digest(
        convert_to(NEW.display_value,'UTF8'),'sha256'
      ),'hex') END;
  END IF;

  IF v_classification AND TG_OP='UPDATE'
     AND OLD.r6d_anonymization_state='STAGED_LEGACY'
     AND NEW.r6d_anonymization_state=v_parent_state
     AND v_parent_state IN (
       'NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON'
     ) THEN
    v_invalid:=NEW.r6d_anonymized_at IS NOT NULL
      OR NEW.r6d_anonymization_receipt_digest IS NOT NULL
      OR NOT EXISTS(
        SELECT 1
        FROM ops.r6d_entity_personhood_classification_receipts_v1 AS receipt
        WHERE receipt.receipt_id=v_parent_personhood_id
          AND receipt.receipt_digest=v_parent_personhood_digest
          AND receipt.entity_kind=v_parent_entity_kind
          AND receipt.entity_id=v_parent_entity_id
          AND receipt.classification=CASE v_parent_state
            WHEN 'NATURAL_PERSON_ACTIVE' THEN 'NATURAL_PERSON'
            ELSE 'NOT_NATURAL_PERSON' END
      );
    IF TG_TABLE_NAME='agency_identifiers' THEN
      v_invalid:=v_invalid OR NEW.value IS NULL
        OR NEW.r6d_value_digest<>encode(extensions.digest(
          convert_to(NEW.value,'UTF8'),'sha256'
        ),'hex');
    ELSIF TG_TABLE_NAME='supplier_identifiers' THEN
      v_invalid:=v_invalid OR NEW.r6d_display_value_digest IS DISTINCT FROM
        v_expected_child_digest;
    ELSE
      v_invalid:=v_invalid OR NEW.alias IS NULL
        OR NEW.normalized_alias IS NULL
        OR NEW.r6d_alias_digest<>encode(extensions.digest(
          convert_to(NEW.alias,'UTF8'),'sha256'
        ),'hex')
        OR NEW.r6d_normalized_alias_digest<>encode(extensions.digest(
          convert_to(NEW.normalized_alias,'UTF8'),'sha256'
        ),'hex');
    END IF;
    IF v_invalid THEN
      RAISE EXCEPTION 'r6d_entity_child_classification_invalid'
        USING ERRCODE='55000';
    END IF;
    RETURN NEW;
  END IF;

  IF v_anonymization AND TG_OP='UPDATE'
     AND OLD.r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
     AND NEW.r6d_anonymization_state='ANONYMIZED'
     AND v_parent_state='ANONYMIZED' THEN
    v_invalid:=num_nonnulls(
      NEW.r6d_anonymized_at,NEW.r6d_anonymization_receipt_digest
    )<>2
      OR NEW.r6d_anonymized_at IS DISTINCT FROM v_parent_anonymized_at
      OR NEW.r6d_anonymization_receipt_digest IS DISTINCT FROM
        v_parent_anonymization_digest
      OR NOT EXISTS(
        SELECT 1
        FROM ops.r6d_entity_retention_execution_receipts_v1 AS execution
        WHERE execution.execution_receipt_digest=
            v_parent_anonymization_digest
          AND execution.entity_kind=v_parent_entity_kind
          AND execution.entity_id=v_parent_entity_id
          AND execution.personhood_receipt_id=v_parent_personhood_id
          AND execution.personhood_receipt_digest=
            v_parent_personhood_digest
          AND execution.closure_receipt_id=v_parent_closure_id
          AND execution.closure_receipt_digest=v_parent_closure_digest
          AND execution.anonymized_at=v_parent_anonymized_at
      );
    IF TG_TABLE_NAME='agency_identifiers' THEN
      v_invalid:=v_invalid OR NEW.value IS NOT NULL
        OR NEW.r6d_value_digest IS DISTINCT FROM OLD.r6d_value_digest;
    ELSIF TG_TABLE_NAME='supplier_identifiers' THEN
      v_invalid:=v_invalid OR NEW.display_value IS NOT NULL
        OR NEW.value_hash IS DISTINCT FROM OLD.value_hash
        OR NEW.r6d_display_value_digest IS DISTINCT FROM
          OLD.r6d_display_value_digest;
    ELSE
      v_invalid:=v_invalid OR NEW.alias IS NOT NULL
        OR NEW.normalized_alias IS NOT NULL
        OR NEW.r6d_alias_digest IS DISTINCT FROM OLD.r6d_alias_digest
        OR NEW.r6d_normalized_alias_digest IS DISTINCT FROM
          OLD.r6d_normalized_alias_digest;
    END IF;
    IF v_invalid THEN
      RAISE EXCEPTION 'r6d_entity_child_anonymization_invalid'
        USING ERRCODE='55000';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP='INSERT' THEN
    v_invalid:=NEW.r6d_anonymization_state<>'STAGED_LEGACY'
      OR NEW.r6d_anonymized_at IS NOT NULL
      OR NEW.r6d_anonymization_receipt_digest IS NOT NULL;
    IF TG_TABLE_NAME='agency_identifiers' THEN
      v_invalid:=v_invalid OR NEW.r6d_value_digest IS NOT NULL;
    ELSIF TG_TABLE_NAME='supplier_identifiers' THEN
      v_invalid:=v_invalid OR NEW.r6d_display_value_digest IS NOT NULL;
    ELSE
      v_invalid:=v_invalid OR NEW.r6d_alias_digest IS NOT NULL
        OR NEW.r6d_normalized_alias_digest IS NOT NULL;
    END IF;
    IF v_invalid THEN
      RAISE EXCEPTION 'r6d_entity_child_authority_caller_override'
        USING ERRCODE='42501';
    END IF;
  ELSE
    v_invalid:=ROW(
         NEW.r6d_anonymization_state,NEW.r6d_anonymized_at,
         NEW.r6d_anonymization_receipt_digest
       ) IS DISTINCT FROM ROW(
         OLD.r6d_anonymization_state,OLD.r6d_anonymized_at,
         OLD.r6d_anonymization_receipt_digest
       );
    IF TG_TABLE_NAME='agency_identifiers' THEN
      v_invalid:=v_invalid OR NEW.r6d_value_digest IS DISTINCT FROM
        OLD.r6d_value_digest;
    ELSIF TG_TABLE_NAME='supplier_identifiers' THEN
      v_invalid:=v_invalid OR NEW.r6d_display_value_digest IS DISTINCT FROM
        OLD.r6d_display_value_digest;
    ELSE
      v_invalid:=v_invalid OR NEW.r6d_alias_digest IS DISTINCT FROM
        OLD.r6d_alias_digest
        OR NEW.r6d_normalized_alias_digest IS DISTINCT FROM
          OLD.r6d_normalized_alias_digest;
    END IF;
    IF v_invalid THEN
      RAISE EXCEPTION 'r6d_entity_child_authority_caller_override'
        USING ERRCODE='42501';
    END IF;
  END IF;

  IF v_parent_state='ANONYMIZED' THEN
    RAISE EXCEPTION 'r6d_entity_child_plaintext_restore_forbidden'
      USING ERRCODE='42501';
  ELSIF v_parent_state IN (
      'NATURAL_PERSON_ACTIVE','NOT_NATURAL_PERSON'
    ) THEN
    IF NOT EXISTS(
      SELECT 1
      FROM ops.r6d_entity_personhood_classification_receipts_v1 AS receipt
      WHERE receipt.receipt_id=v_parent_personhood_id
        AND receipt.receipt_digest=v_parent_personhood_digest
        AND receipt.entity_kind=v_parent_entity_kind
        AND receipt.entity_id=v_parent_entity_id
        AND receipt.classification=CASE v_parent_state
          WHEN 'NATURAL_PERSON_ACTIVE' THEN 'NATURAL_PERSON'
          ELSE 'NOT_NATURAL_PERSON' END
    ) THEN
      RAISE EXCEPTION 'r6d_entity_child_parent_authority_invalid'
        USING ERRCODE='55000';
    END IF;
    NEW.r6d_anonymization_state:=v_parent_state;
    IF TG_TABLE_NAME='agency_identifiers' THEN
      NEW.r6d_value_digest:=encode(extensions.digest(
        convert_to(NEW.value,'UTF8'),'sha256'
      ),'hex');
    ELSIF TG_TABLE_NAME='supplier_identifiers' THEN
      NEW.r6d_display_value_digest:=v_expected_child_digest;
    ELSE
      NEW.r6d_alias_digest:=encode(extensions.digest(
        convert_to(NEW.alias,'UTF8'),'sha256'
      ),'hex');
      NEW.r6d_normalized_alias_digest:=encode(extensions.digest(
        convert_to(NEW.normalized_alias,'UTF8'),'sha256'
      ),'hex');
    END IF;
  END IF;
  RETURN NEW;
END
$r6d_entity_child_guard$;
ALTER FUNCTION ops.guard_r6d_entity_child_authority_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.guard_r6d_entity_child_authority_v1()
  FROM PUBLIC;

CREATE TRIGGER agency_identifiers_r6d_authority_guard
  BEFORE INSERT OR UPDATE ON core.agency_identifiers
  FOR EACH ROW EXECUTE FUNCTION ops.guard_r6d_entity_child_authority_v1();
CREATE TRIGGER supplier_identifiers_r6d_authority_guard
  BEFORE INSERT OR UPDATE ON core.supplier_identifiers
  FOR EACH ROW EXECUTE FUNCTION ops.guard_r6d_entity_child_authority_v1();
CREATE TRIGGER entity_aliases_r6d_authority_guard
  BEFORE INSERT OR UPDATE ON core.entity_aliases
  FOR EACH ROW EXECUTE FUNCTION ops.guard_r6d_entity_child_authority_v1();

-- Final D1 closure owner ABI.  The earlier declaration in this migration is
-- replaced in-place so upgrades that were prepared from an intermediate R6d
-- draft cannot retain caller-derived closure authority.
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
     OR p_request->>'_actorEffectiveCapability'<>'sources.operate'
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
    'sources.operate','SUCCESS',NULL,p_request_id,
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

CREATE OR REPLACE FUNCTION ops.enqueue_due_r6d_entity_retention_jobs_v1(
  p_limit integer
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,core,extensions,pg_temp
AS $r6d_entity_enqueue$
DECLARE
  v_candidate record;
  v_idempotency_digest char(64);
  v_request_digest char(64);
  v_payload jsonb;
  v_job_id uuid;
  v_job_ids jsonb:='[]'::jsonb;
  v_enqueued bigint:=0;
  v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'r6d_entity_retention_enqueue_limit_invalid'
      USING ERRCODE='22023';
  END IF;
  FOR v_candidate IN
    WITH entity AS (
      SELECT 'AGENCY'::text AS entity_kind,agency.id AS entity_id,
        agency.r6d_personhood_receipt_id AS personhood_receipt_id,
        agency.r6d_personhood_receipt_digest AS personhood_receipt_digest,
        agency.r6d_closure_receipt_id AS closure_receipt_id,
        agency.r6d_closure_receipt_digest AS closure_receipt_digest,
        agency.retention_schedule_id AS schedule_id,
        agency.retention_record_class AS schedule_record_class,
        agency.retention_schedule_digest AS schedule_digest
      FROM core.agencies AS agency
      WHERE agency.r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
      UNION ALL
      SELECT 'SUPPLIER'::text,supplier.id,
        supplier.r6d_personhood_receipt_id,
        supplier.r6d_personhood_receipt_digest,
        supplier.r6d_closure_receipt_id,
        supplier.r6d_closure_receipt_digest,
        supplier.retention_schedule_id,supplier.retention_record_class,
        supplier.retention_schedule_digest
      FROM core.suppliers AS supplier
      WHERE supplier.r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
    )
    SELECT entity.*,personhood.classification,
      closure.closure_at,schedule.revision AS schedule_revision,
      schedule.active_duration_seconds,schedule.backup_duration_seconds,
      closure.closure_at+make_interval(
        secs=>schedule.active_duration_seconds::double precision
      ) AS due_at
    FROM entity
    JOIN ops.r6d_entity_personhood_classification_receipts_v1 AS personhood
      ON (personhood.receipt_id,personhood.receipt_digest)=
         (entity.personhood_receipt_id,entity.personhood_receipt_digest)
     AND personhood.entity_kind=entity.entity_kind
     AND personhood.entity_id=entity.entity_id
     AND personhood.classification='NATURAL_PERSON'
    JOIN ops.r6d_entity_material_use_closure_receipts_v1 AS closure
      ON (closure.receipt_id,closure.receipt_digest)=
         (entity.closure_receipt_id,entity.closure_receipt_digest)
     AND closure.entity_kind=entity.entity_kind
     AND closure.entity_id=entity.entity_id
     AND closure.personhood_receipt_id=personhood.receipt_id
     AND closure.personhood_receipt_digest=personhood.receipt_digest
    JOIN ops.record_class_schedules AS schedule
      ON (schedule.id,schedule.record_class,schedule.schedule_digest)=
         (entity.schedule_id,entity.schedule_record_class,
          entity.schedule_digest)
    JOIN ops.r6d_record_class_catalog AS catalog
      ON catalog.record_class=schedule.record_class
    WHERE schedule.record_class=CASE entity.entity_kind
        WHEN 'AGENCY' THEN 'AGENCY_MASTER' ELSE 'SUPPLIER_MASTER' END
      AND schedule.trigger_kind='LAST_MATERIAL_USE_AT'
      AND schedule.terminal_action='ANONYMIZE'
      AND schedule.hold_behavior IN (
        'BLOCK_ON_RETENTION','BLOCK_ON_RETENTION_OR_DELETION'
      )
      AND schedule.restore_suppression_behavior='REAPPLY_BEFORE_ACCESS'
      AND schedule.active_duration_seconds IS NOT NULL
      AND schedule.backup_duration_seconds IS NOT NULL
      AND schedule.effective_at<=v_now AND schedule.review_expires_at>v_now
      AND catalog.data_category='ENTITY_IDENTITY' AND catalog.pii_write
      AND catalog.required_terminal_action=schedule.terminal_action
      AND catalog.required_trigger_kind=schedule.trigger_kind
      AND catalog.required_active_duration_seconds=
          schedule.active_duration_seconds
      AND catalog.required_backup_duration_seconds=
          schedule.backup_duration_seconds
      AND catalog.required_lawful_basis=schedule.lawful_basis
      AND closure.closure_at+make_interval(
        secs=>schedule.active_duration_seconds::double precision
      )<=v_now
      AND NOT EXISTS(
        SELECT 1
        FROM ops.r6d_entity_retention_execution_receipts_v1 AS executed
        WHERE executed.entity_kind=entity.entity_kind
          AND executed.entity_id=entity.entity_id
      )
      AND NOT (ops.r6d_entity_legal_hold_coverage_v1(
        entity.entity_kind,entity.entity_id,v_now
      )->>'active')::boolean
      AND EXISTS(
        SELECT 1 FROM ops.execution_receipts AS execution
        JOIN ops.action_decisions AS operational_decision
          ON operational_decision.id=
              schedule.operational_action_decision_id
         AND operational_decision.receipt_digest=
              schedule.operational_action_decision_receipt_digest
         AND operational_decision.decision_kind='APPROVE'
        JOIN ops.action_decisions AS legal_decision
          ON legal_decision.id=schedule.legal_action_decision_id
         AND legal_decision.receipt_digest=
              schedule.legal_action_decision_receipt_digest
         AND legal_decision.decision_kind='APPROVE'
        WHERE execution.id=schedule.action_execution_receipt_id
          AND execution.receipt_digest=
              schedule.action_execution_receipt_digest
          AND execution.aggregate_state='SUCCEEDED'
      )
    ORDER BY due_at,entity.entity_kind,entity.entity_id
    LIMIT p_limit
  LOOP
    v_idempotency_digest:=encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_object(
        'schemaVersion','r6d-entity-retention-idempotency.v1',
        'entityKind',v_candidate.entity_kind,
        'entityId',v_candidate.entity_id,
        'closureReceiptId',v_candidate.closure_receipt_id,
        'closureReceiptDigest',btrim(v_candidate.closure_receipt_digest),
        'scheduleId',v_candidate.schedule_id,
        'scheduleDigest',btrim(v_candidate.schedule_digest),
        'dueAt',v_candidate.due_at
      )),'sha256'
    ),'hex');
    v_payload:=jsonb_build_object(
      'schemaVersion','r6d-entity-retention-job.v1',
      'entityKind',v_candidate.entity_kind,
      'entityId',v_candidate.entity_id,
      'personhoodReceiptId',v_candidate.personhood_receipt_id,
      'personhoodReceiptDigest',btrim(v_candidate.personhood_receipt_digest),
      'closureReceiptId',v_candidate.closure_receipt_id,
      'closureReceiptDigest',btrim(v_candidate.closure_receipt_digest),
      'closureAt',v_candidate.closure_at,
      'scheduleId',v_candidate.schedule_id,
      'scheduleRevision',v_candidate.schedule_revision,
      'scheduleDigest',btrim(v_candidate.schedule_digest),
      'dueAt',v_candidate.due_at,
      'idempotencyDigest',btrim(v_idempotency_digest),
      'queuedAt',v_now
    );
    v_request_digest:=encode(extensions.digest(
      ops.canonical_jsonb_v1(v_payload),'sha256'
    ),'hex');
    v_payload:=v_payload||jsonb_build_object(
      'requestDigest',btrim(v_request_digest)
    );
    v_job_id:=NULL;
    INSERT INTO ops.jobs(
      job_type,queue,priority,payload,dedupe_key,run_after,max_attempts
    ) VALUES(
      'R6D_ENTITY_RETENTION','workflow-worker',80,v_payload,
      'r6d-entity-retention:'||v_candidate.entity_kind||':'||
        v_candidate.entity_id::text||':'||
        btrim(v_candidate.closure_receipt_digest)||':'||
        btrim(v_candidate.schedule_digest),
      v_now,8
    ) ON CONFLICT DO NOTHING RETURNING id INTO v_job_id;
    IF v_job_id IS NOT NULL THEN
      v_job_ids:=v_job_ids||jsonb_build_array(v_job_id);
      v_enqueued:=v_enqueued+1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object(
    'evaluatedAt',v_now,'enqueuedCount',v_enqueued,'jobIds',v_job_ids
  );
END
$r6d_entity_enqueue$;
ALTER FUNCTION ops.enqueue_due_r6d_entity_retention_jobs_v1(integer)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.enqueue_due_r6d_entity_retention_jobs_v1(integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.enqueue_due_r6d_entity_retention_jobs_v1(integer)
  TO gurine_scheduler;

CREATE OR REPLACE FUNCTION ops.execute_due_r6d_entity_retention_job_v1(
  p_job_id uuid,
  p_lease_token uuid,
  p_fencing_token bigint
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,core,editorial,extensions,pg_temp
AS $r6d_entity_execute$
DECLARE
  v_job ops.jobs%ROWTYPE;
  v_existing ops.r6d_entity_retention_execution_receipts_v1%ROWTYPE;
  v_personhood ops.r6d_entity_personhood_classification_receipts_v1%ROWTYPE;
  v_closure ops.r6d_entity_material_use_closure_receipts_v1%ROWTYPE;
  v_schedule ops.record_class_schedules%ROWTYPE;
  v_catalog ops.r6d_record_class_catalog%ROWTYPE;
  v_payload jsonb;
  v_entity_kind text;
  v_entity_id uuid;
  v_personhood_id uuid;
  v_closure_id uuid;
  v_schedule_id uuid;
  v_schedule_revision bigint;
  v_closure_at timestamptz;
  v_due_at timestamptz;
  v_entity_state text;
  v_entity_personhood_id uuid;
  v_entity_personhood_digest char(64);
  v_entity_closure_id uuid;
  v_entity_closure_digest char(64);
  v_entity_schedule_id uuid;
  v_entity_schedule_class text;
  v_entity_schedule_digest char(64);
  v_expected_schedule_class text;
  v_master_name text;
  v_master_name_digest char(64);
  v_master_jurisdiction text;
  v_master_jurisdiction_digest char(64);
  v_expected_master_jurisdiction_digest char(64);
  v_expected_idempotency char(64);
  v_expected_request char(64);
  v_job_payload_digest char(64);
  v_lease_owner_digest char(64);
  v_lease_token_digest char(64);
  v_material jsonb;
  v_master_count bigint:=1;
  v_identifier_count bigint;
  v_alias_count bigint;
  v_changed_identifiers bigint;
  v_changed_aliases bigint;
  v_changed_master bigint;
  v_execution_id uuid:=gen_random_uuid();
  v_audit uuid;
  v_outbox uuid;
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_execution_digest char(64);
  v_backup_due_at timestamptz;
  v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_job_id IS NULL OR p_lease_token IS NULL
     OR p_fencing_token IS NULL OR p_fencing_token<1 THEN
    RAISE EXCEPTION 'r6d_entity_retention_job_fence_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_job FROM ops.jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.job_type<>'R6D_ENTITY_RETENTION'
     OR v_job.queue<>'workflow-worker' THEN
    RAISE EXCEPTION 'r6d_entity_retention_job_lease_stale'
      USING ERRCODE='40001';
  END IF;
  v_payload:=v_job.payload;
  IF v_payload IS NULL OR jsonb_typeof(v_payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_payload))<>15
     OR NOT v_payload ?& ARRAY[
       'schemaVersion','entityKind','entityId','personhoodReceiptId',
       'personhoodReceiptDigest','closureReceiptId','closureReceiptDigest',
       'closureAt','scheduleId','scheduleRevision','scheduleDigest','dueAt',
       'requestDigest','idempotencyDigest','queuedAt'
     ]
     OR v_payload->>'schemaVersion'<>'r6d-entity-retention-job.v1'
     OR v_payload->>'entityKind' NOT IN ('AGENCY','SUPPLIER')
     OR NOT COALESCE(ops.r6d_lower_sha256(
       v_payload->>'personhoodReceiptDigest'
     ),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(
       v_payload->>'closureReceiptDigest'
     ),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(
       v_payload->>'scheduleDigest'
     ),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(
       v_payload->>'requestDigest'
     ),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(
       v_payload->>'idempotencyDigest'
     ),false) THEN
    RAISE EXCEPTION 'r6d_entity_retention_job_payload_invalid'
      USING ERRCODE='22023';
  END IF;
  BEGIN
    v_entity_kind:=v_payload->>'entityKind';
    v_expected_schedule_class:=CASE v_entity_kind
      WHEN 'AGENCY' THEN 'AGENCY_MASTER' ELSE 'SUPPLIER_MASTER' END;
    v_entity_id:=(v_payload->>'entityId')::uuid;
    v_personhood_id:=(v_payload->>'personhoodReceiptId')::uuid;
    v_closure_id:=(v_payload->>'closureReceiptId')::uuid;
    v_closure_at:=(v_payload->>'closureAt')::timestamptz;
    v_schedule_id:=(v_payload->>'scheduleId')::uuid;
    v_schedule_revision:=(v_payload->>'scheduleRevision')::bigint;
    v_due_at:=(v_payload->>'dueAt')::timestamptz;
    IF (v_payload->>'queuedAt')::timestamptz<v_due_at
       OR v_due_at<v_closure_at OR v_schedule_revision<1 THEN
      RAISE EXCEPTION 'r6d_entity_retention_job_payload_invalid'
        USING ERRCODE='22023';
    END IF;
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range
      OR datetime_field_overflow THEN
      RAISE EXCEPTION 'r6d_entity_retention_job_payload_invalid'
        USING ERRCODE='22023';
  END;

  v_expected_idempotency:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','r6d-entity-retention-idempotency.v1',
      'entityKind',v_entity_kind,'entityId',v_entity_id,
      'closureReceiptId',v_closure_id,
      'closureReceiptDigest',v_payload->>'closureReceiptDigest',
      'scheduleId',v_schedule_id,
      'scheduleDigest',v_payload->>'scheduleDigest','dueAt',v_due_at
    )),'sha256'
  ),'hex');
  v_expected_request:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_payload-'requestDigest'),'sha256'
  ),'hex');
  IF v_payload->>'idempotencyDigest'<>btrim(v_expected_idempotency)
     OR v_payload->>'requestDigest'<>btrim(v_expected_request)
     OR v_job.dedupe_key IS DISTINCT FROM
       'r6d-entity-retention:'||v_entity_kind||':'||v_entity_id::text||':'||
       (v_payload->>'closureReceiptDigest')||':'||
       (v_payload->>'scheduleDigest') THEN
    RAISE EXCEPTION 'r6d_entity_retention_job_binding_invalid'
      USING ERRCODE='22023';
  END IF;
  IF v_job.status<>'RUNNING'
     OR v_job.lease_owner IS NULL
     OR length(btrim(v_job.lease_owner)) NOT BETWEEN 1 AND 200
     OR v_job.lease_token IS DISTINCT FROM p_lease_token
     OR v_job.fencing_token IS DISTINCT FROM p_fencing_token
     OR v_job.lease_expires_at IS NULL OR v_job.lease_expires_at<=v_now THEN
    RAISE EXCEPTION 'r6d_entity_retention_job_lease_stale'
      USING ERRCODE='40001';
  END IF;
  v_job_payload_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_payload),'sha256'
  ),'hex');
  v_lease_owner_digest:=encode(extensions.digest(
    convert_to(v_job.lease_owner,'UTF8'),'sha256'
  ),'hex');
  v_lease_token_digest:=encode(extensions.digest(
    convert_to(p_lease_token::text,'UTF8'),'sha256'
  ),'hex');

  SELECT * INTO v_existing
  FROM ops.r6d_entity_retention_execution_receipts_v1
  WHERE job_id=p_job_id FOR SHARE;
  IF FOUND THEN
    IF v_existing.entity_kind<>v_entity_kind
       OR v_existing.entity_id<>v_entity_id
       OR v_existing.personhood_receipt_id<>v_personhood_id
       OR btrim(v_existing.personhood_receipt_digest)<>
          v_payload->>'personhoodReceiptDigest'
       OR v_existing.closure_receipt_id<>v_closure_id
       OR btrim(v_existing.closure_receipt_digest)<>
          v_payload->>'closureReceiptDigest'
       OR v_existing.schedule_id<>v_schedule_id
       OR v_existing.schedule_revision<>v_schedule_revision
       OR btrim(v_existing.schedule_digest)<>v_payload->>'scheduleDigest'
       OR btrim(v_existing.request_digest)<>v_payload->>'requestDigest'
       OR btrim(v_existing.idempotency_digest)<>
          v_payload->>'idempotencyDigest'
       OR btrim(v_existing.job_payload_digest)<>
          btrim(v_job_payload_digest) THEN
      RAISE EXCEPTION 'r6d_entity_retention_execution_replay_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN jsonb_build_object(
      'status','COMPLETED','jobId',p_job_id,
      'entityKind',v_existing.entity_kind,'entityId',v_existing.entity_id,
      'executionReceiptId',v_existing.execution_receipt_id,
      'executionReceiptDigest',btrim(v_existing.execution_receipt_digest),
      'closureReceiptId',v_existing.closure_receipt_id,
      'closureReceiptDigest',btrim(v_existing.closure_receipt_digest),
      'anonymizedAt',v_existing.anonymized_at,
      'masterRowCount',v_existing.master_row_count,
      'identifierRowCount',v_existing.identifier_row_count,
      'aliasRowCount',v_existing.alias_row_count,
      'backupDisposalDueAt',v_existing.backup_disposal_due_at,
      'auditEventId',v_existing.audit_event_id,'replayed',true
    );
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(v_entity_id::text,13));
  IF v_entity_kind='AGENCY' THEN
    SELECT agency.r6d_anonymization_state,
      agency.r6d_personhood_receipt_id,
      agency.r6d_personhood_receipt_digest,
      agency.r6d_closure_receipt_id,agency.r6d_closure_receipt_digest,
      agency.retention_schedule_id,agency.retention_record_class,
      agency.retention_schedule_digest,agency.canonical_name,
      agency.r6d_canonical_name_digest,agency.jurisdiction,
      agency.r6d_jurisdiction_digest
    INTO v_entity_state,v_entity_personhood_id,
      v_entity_personhood_digest,v_entity_closure_id,
      v_entity_closure_digest,v_entity_schedule_id,v_entity_schedule_class,
      v_entity_schedule_digest,v_master_name,v_master_name_digest,
      v_master_jurisdiction,v_master_jurisdiction_digest
    FROM core.agencies AS agency WHERE agency.id=v_entity_id FOR UPDATE;
  ELSE
    SELECT supplier.r6d_anonymization_state,
      supplier.r6d_personhood_receipt_id,
      supplier.r6d_personhood_receipt_digest,
      supplier.r6d_closure_receipt_id,supplier.r6d_closure_receipt_digest,
      supplier.retention_schedule_id,supplier.retention_record_class,
      supplier.retention_schedule_digest,supplier.canonical_name,
      supplier.r6d_canonical_name_digest,NULL::text,NULL::char(64)
    INTO v_entity_state,v_entity_personhood_id,
      v_entity_personhood_digest,v_entity_closure_id,
      v_entity_closure_digest,v_entity_schedule_id,v_entity_schedule_class,
      v_entity_schedule_digest,v_master_name,v_master_name_digest,
      v_master_jurisdiction,v_master_jurisdiction_digest
    FROM core.suppliers AS supplier WHERE supplier.id=v_entity_id FOR UPDATE;
  END IF;
  IF v_entity_kind='AGENCY' AND v_master_jurisdiction IS NOT NULL THEN
    v_expected_master_jurisdiction_digest:=encode(extensions.digest(
      convert_to(v_master_jurisdiction,'UTF8'),'sha256'
    ),'hex');
  END IF;
  IF NOT FOUND OR v_entity_state<>'NATURAL_PERSON_ACTIVE'
     OR v_entity_personhood_id<>v_personhood_id
     OR btrim(v_entity_personhood_digest)<>
        v_payload->>'personhoodReceiptDigest'
     OR v_entity_closure_id<>v_closure_id
     OR btrim(v_entity_closure_digest)<>v_payload->>'closureReceiptDigest'
     OR v_entity_schedule_id<>v_schedule_id
     OR v_entity_schedule_class<>v_expected_schedule_class
     OR btrim(v_entity_schedule_digest)<>v_payload->>'scheduleDigest'
     OR v_master_name IS NULL
     OR btrim(v_master_name_digest)<>encode(extensions.digest(
       convert_to(v_master_name,'UTF8'),'sha256'
     ),'hex')
     OR (v_entity_kind='AGENCY' AND
       v_master_jurisdiction_digest IS DISTINCT FROM
       v_expected_master_jurisdiction_digest) THEN
    RAISE EXCEPTION 'r6d_entity_retention_subject_not_current'
      USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_personhood
  FROM ops.r6d_entity_personhood_classification_receipts_v1
  WHERE receipt_id=v_personhood_id FOR SHARE;
  SELECT * INTO v_closure
  FROM ops.r6d_entity_material_use_closure_receipts_v1
  WHERE receipt_id=v_closure_id FOR SHARE;
  IF v_personhood.receipt_id IS NULL
     OR v_personhood.entity_kind<>v_entity_kind
     OR v_personhood.entity_id<>v_entity_id
     OR v_personhood.classification<>'NATURAL_PERSON'
     OR btrim(v_personhood.receipt_digest)<>
        v_payload->>'personhoodReceiptDigest'
     OR v_closure.receipt_id IS NULL
     OR v_closure.entity_kind<>v_entity_kind
     OR v_closure.entity_id<>v_entity_id
     OR v_closure.personhood_receipt_id<>v_personhood.receipt_id
     OR v_closure.personhood_receipt_digest<>v_personhood.receipt_digest
     OR btrim(v_closure.receipt_digest)<>v_payload->>'closureReceiptDigest'
     OR v_closure.closure_at<>v_closure_at THEN
    RAISE EXCEPTION 'r6d_entity_retention_authority_receipt_invalid'
      USING ERRCODE='55000';
  END IF;

  v_material:=ops.r6d_entity_material_use_state_v1(
    v_entity_kind,v_entity_id,v_now
  );
  IF (v_material->>'legalHoldActive')::boolean
     OR (v_material->>'legalHoldActiveCellCount')::bigint<>0 THEN
    RAISE EXCEPTION 'r6d_entity_retention_legal_hold_active'
      USING ERRCODE='55000';
  END IF;
  IF (v_material->>'openPublicationRevisionCount')::bigint<>0
     OR (v_material->>'finalContractBoundaryAt') IS NOT NULL
       AND (v_material->>'finalContractBoundaryAt')::timestamptz>v_now
     OR (v_material->>'contractCount')::bigint<>v_closure.contract_count
     OR v_material->>'contractSetDigest'<>
        btrim(v_closure.contract_set_digest)
     OR (v_material->>'publicationRevisionCount')::bigint<>
        v_closure.publication_revision_count
     OR v_material->>'publicationRevisionSetDigest'<>
        btrim(v_closure.publication_revision_set_digest) THEN
    RAISE EXCEPTION 'r6d_entity_retention_material_use_reopened'
      USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_schedule FROM ops.record_class_schedules
  WHERE id=v_schedule_id AND revision=v_schedule_revision
    AND schedule_digest=v_payload->>'scheduleDigest' FOR SHARE;
  SELECT * INTO v_catalog FROM ops.r6d_record_class_catalog
  WHERE record_class=v_entity_schedule_class FOR SHARE;
  IF v_schedule.id IS NULL OR v_catalog.record_class IS NULL
     OR v_schedule.record_class<>v_entity_schedule_class
     OR v_schedule.trigger_kind<>'LAST_MATERIAL_USE_AT'
     OR v_schedule.terminal_action<>'ANONYMIZE'
     OR v_schedule.hold_behavior NOT IN (
       'BLOCK_ON_RETENTION','BLOCK_ON_RETENTION_OR_DELETION'
     )
     OR v_schedule.restore_suppression_behavior<>'REAPPLY_BEFORE_ACCESS'
     OR v_schedule.active_duration_seconds IS NULL
     OR v_schedule.backup_duration_seconds IS NULL
     OR v_schedule.effective_at>v_now OR v_schedule.review_expires_at<=v_now
     OR v_catalog.data_category<>'ENTITY_IDENTITY' OR NOT v_catalog.pii_write
     OR v_catalog.required_terminal_action<>v_schedule.terminal_action
     OR v_catalog.required_trigger_kind<>v_schedule.trigger_kind
     OR v_catalog.required_active_duration_seconds<>
        v_schedule.active_duration_seconds
     OR v_catalog.required_backup_duration_seconds<>
        v_schedule.backup_duration_seconds
     OR v_catalog.required_lawful_basis<>v_schedule.lawful_basis
     OR NOT EXISTS(
       SELECT 1 FROM ops.execution_receipts AS execution
       JOIN ops.action_decisions AS operational_decision
         ON operational_decision.id=v_schedule.operational_action_decision_id
        AND operational_decision.receipt_digest=
            v_schedule.operational_action_decision_receipt_digest
        AND operational_decision.decision_kind='APPROVE'
       JOIN ops.action_decisions AS legal_decision
         ON legal_decision.id=v_schedule.legal_action_decision_id
        AND legal_decision.receipt_digest=
            v_schedule.legal_action_decision_receipt_digest
        AND legal_decision.decision_kind='APPROVE'
       WHERE execution.id=v_schedule.action_execution_receipt_id
         AND execution.receipt_digest=v_schedule.action_execution_receipt_digest
         AND execution.aggregate_state='SUCCEEDED'
     ) THEN
    RAISE EXCEPTION 'r6d_entity_retention_schedule_not_approved'
      USING ERRCODE='55000';
  END IF;
  IF v_due_at<>v_closure.closure_at+make_interval(
       secs=>v_schedule.active_duration_seconds::double precision
     ) OR v_due_at>v_now THEN
    RAISE EXCEPTION 'r6d_entity_retention_due_binding_invalid'
      USING ERRCODE='55000';
  END IF;

  IF v_entity_kind='AGENCY' THEN
    SELECT count(*) INTO v_identifier_count
    FROM core.agency_identifiers WHERE agency_id=v_entity_id;
    IF EXISTS(
      SELECT 1 FROM core.agency_identifiers AS identifier
      WHERE identifier.agency_id=v_entity_id
        AND (identifier.r6d_anonymization_state<>'NATURAL_PERSON_ACTIVE'
          OR identifier.value IS NULL
          OR identifier.r6d_value_digest IS NULL
          OR btrim(identifier.r6d_value_digest)<>encode(extensions.digest(
            convert_to(identifier.value,'UTF8'),'sha256'
          ),'hex')
          OR num_nonnulls(
            identifier.retention_schedule_id,
            identifier.retention_record_class,
            identifier.retention_schedule_digest
          )<>3)
    ) THEN
      RAISE EXCEPTION 'r6d_entity_retention_identifier_state_invalid'
        USING ERRCODE='55000';
    END IF;
  ELSE
    SELECT count(*) INTO v_identifier_count
    FROM core.supplier_identifiers WHERE supplier_id=v_entity_id;
    IF EXISTS(
      SELECT 1 FROM core.supplier_identifiers AS identifier
      WHERE identifier.supplier_id=v_entity_id
        AND (identifier.r6d_anonymization_state<>'NATURAL_PERSON_ACTIVE'
          OR NOT ops.r6d_lower_sha256(identifier.value_hash)
          OR identifier.r6d_display_value_digest IS DISTINCT FROM
            CASE WHEN identifier.display_value IS NULL THEN NULL ELSE
              encode(extensions.digest(
                convert_to(identifier.display_value,'UTF8'),'sha256'
              ),'hex')::char(64) END
          OR num_nonnulls(
            identifier.retention_schedule_id,
            identifier.retention_record_class,
            identifier.retention_schedule_digest
          )<>3)
    ) THEN
      RAISE EXCEPTION 'r6d_entity_retention_identifier_state_invalid'
        USING ERRCODE='55000';
    END IF;
  END IF;
  SELECT count(*) INTO v_alias_count FROM core.entity_aliases
  WHERE entity_type=v_entity_kind AND entity_id=v_entity_id;
  IF EXISTS(
    SELECT 1 FROM core.entity_aliases AS alias
    WHERE alias.entity_type=v_entity_kind AND alias.entity_id=v_entity_id
      AND (alias.r6d_anonymization_state<>'NATURAL_PERSON_ACTIVE'
        OR alias.alias IS NULL OR alias.normalized_alias IS NULL
        OR btrim(alias.r6d_alias_digest)<>encode(extensions.digest(
          convert_to(alias.alias,'UTF8'),'sha256'
        ),'hex')
        OR btrim(alias.r6d_normalized_alias_digest)<>
          encode(extensions.digest(
            convert_to(alias.normalized_alias,'UTF8'),'sha256'
          ),'hex')
        OR num_nonnulls(
          alias.retention_schedule_id,alias.retention_record_class,
          alias.retention_schedule_digest
        )<>3)
  ) THEN
    RAISE EXCEPTION 'r6d_entity_retention_alias_state_invalid'
      USING ERRCODE='55000';
  END IF;

  v_backup_due_at:=v_now+make_interval(
    secs=>v_schedule.backup_duration_seconds::double precision
  );
  v_audit:=ops.append_audit_event(
    'r6d-entity-retention:'||lower(v_entity_kind)||':'||v_entity_id::text,
    'SERVICE',v_job.lease_owner,NULL::uuid,
    'r6d.entity_retention.anonymize','Entity',v_entity_id::text,
    'privacy.retention.execute','SUCCESS',NULL,p_job_id,
    jsonb_build_object(
      'jobId',p_job_id,'jobFencingToken',p_fencing_token,
      'jobPayloadDigest',btrim(v_job_payload_digest),
      'personhoodReceiptDigest',v_payload->>'personhoodReceiptDigest',
      'closureReceiptDigest',v_payload->>'closureReceiptDigest',
      'scheduleDigest',v_payload->>'scheduleDigest','dueAt',v_due_at,
      'legalHoldCoverageDigest',v_material->>'legalHoldCoverageDigest',
      'masterRowCount',v_master_count,
      'identifierRowCount',v_identifier_count,'aliasRowCount',v_alias_count
    )
  );
  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','r6d-entity-retention-execution.v1',
    'receiptContractVersion',1,
    'executionReceiptId',v_execution_id,'jobId',p_job_id,
    'jobFencingToken',p_fencing_token,
    'jobLeaseOwnerDigest',btrim(v_lease_owner_digest),
    'jobLeaseTokenSha256',btrim(v_lease_token_digest),
    'jobPayloadDigest',btrim(v_job_payload_digest),
    'entityKind',v_entity_kind,'entityId',v_entity_id,
    'personhoodReceiptId',v_personhood_id,
    'personhoodReceiptDigest',v_payload->>'personhoodReceiptDigest',
    'closureReceiptId',v_closure_id,
    'closureReceiptDigest',v_payload->>'closureReceiptDigest',
    'closureAt',v_closure_at,'scheduleId',v_schedule.id,
    'scheduleRecordClass',v_schedule.record_class,
    'scheduleRevision',v_schedule.revision,
    'scheduleDigest',btrim(v_schedule.schedule_digest),'dueAt',v_due_at,
    'requestDigest',v_payload->>'requestDigest',
    'idempotencyDigest',v_payload->>'idempotencyDigest',
    'legalHoldCoverageDigest',v_material->>'legalHoldCoverageDigest',
    'masterRowCount',v_master_count,
    'identifierRowCount',v_identifier_count,'aliasRowCount',v_alias_count,
    'anonymizedAt',v_now,'backupDisposalDueAt',v_backup_due_at,
    'auditEventId',v_audit
  );
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_execution_digest:=encode(extensions.digest(
    v_receipt_canonical,'sha256'
  ),'hex');
  v_outbox:=ops.enqueue_outbox(
    'r6d_entity_retention_execution',v_execution_id::text,1,
    'entity.retention_anonymized.v1',jsonb_build_object(
      'entityKind',v_entity_kind,'entityId',v_entity_id,
      'executionReceiptId',v_execution_id,
      'executionReceiptDigest',btrim(v_execution_digest),
      'masterRowCount',v_master_count,
      'identifierRowCount',v_identifier_count,'aliasRowCount',v_alias_count,
      'anonymizedAt',v_now
    ),v_now
  );
  INSERT INTO ops.r6d_entity_retention_execution_receipts_v1(
    execution_receipt_id,job_id,job_fencing_token,job_lease_owner_digest,
    job_lease_token_sha256,job_payload_digest,entity_kind,entity_id,
    personhood_receipt_id,personhood_receipt_digest,closure_receipt_id,
    closure_receipt_digest,closure_at,schedule_id,schedule_record_class,
    schedule_revision,schedule_digest,due_at,request_digest,
    idempotency_digest,legal_hold_coverage_digest,master_row_count,
    identifier_row_count,alias_row_count,anonymized_at,
    backup_disposal_due_at,audit_event_id,outbox_event_id,receipt_payload,
    receipt_canonical,execution_receipt_digest
  ) VALUES(
    v_execution_id,p_job_id,p_fencing_token,v_lease_owner_digest,
    v_lease_token_digest,v_job_payload_digest,v_entity_kind,v_entity_id,
    v_personhood_id,(v_payload->>'personhoodReceiptDigest')::char(64),
    v_closure_id,(v_payload->>'closureReceiptDigest')::char(64),v_closure_at,
    v_schedule.id,v_schedule.record_class,v_schedule.revision,
    v_schedule.schedule_digest,v_due_at,
    (v_payload->>'requestDigest')::char(64),
    (v_payload->>'idempotencyDigest')::char(64),
    (v_material->>'legalHoldCoverageDigest')::char(64),v_master_count,
    v_identifier_count,v_alias_count,v_now,v_backup_due_at,v_audit,v_outbox,
    v_receipt_payload,v_receipt_canonical,v_execution_digest
  );

  PERFORM set_config('gurine.r6d_entity_anonymization','1',true);
  IF v_entity_kind='AGENCY' THEN
    UPDATE core.agencies
    SET canonical_name=NULL,jurisdiction=NULL,
        r6d_anonymization_state='ANONYMIZED',r6d_anonymized_at=v_now,
        r6d_anonymization_receipt_digest=v_execution_digest
    WHERE id=v_entity_id
      AND r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
      AND r6d_personhood_receipt_id=v_personhood_id
      AND r6d_personhood_receipt_digest=
          (v_payload->>'personhoodReceiptDigest')::char(64)
      AND r6d_closure_receipt_id=v_closure_id
      AND r6d_closure_receipt_digest=
          (v_payload->>'closureReceiptDigest')::char(64);
    GET DIAGNOSTICS v_changed_master=ROW_COUNT;
    UPDATE public.agencies
    SET name=NULL,jurisdiction=NULL,updated_at=GREATEST(updated_at,v_now)
    WHERE id=v_entity_id AND (name IS NOT NULL OR jurisdiction IS NOT NULL);
    IF EXISTS(
      SELECT 1 FROM public.agencies
      WHERE id=v_entity_id AND (name IS NOT NULL OR jurisdiction IS NOT NULL)
    ) THEN
      RAISE EXCEPTION 'r6d_public_entity_anonymization_incomplete'
        USING ERRCODE='55000';
    END IF;
    UPDATE core.agency_identifiers
    SET value=NULL,r6d_anonymization_state='ANONYMIZED',
        r6d_anonymized_at=v_now,
        r6d_anonymization_receipt_digest=v_execution_digest
    WHERE agency_id=v_entity_id
      AND r6d_anonymization_state='NATURAL_PERSON_ACTIVE';
    GET DIAGNOSTICS v_changed_identifiers=ROW_COUNT;
  ELSE
    UPDATE core.suppliers
    SET canonical_name=NULL,r6d_anonymization_state='ANONYMIZED',
        r6d_anonymized_at=v_now,
        r6d_anonymization_receipt_digest=v_execution_digest
    WHERE id=v_entity_id
      AND r6d_anonymization_state='NATURAL_PERSON_ACTIVE'
      AND r6d_personhood_receipt_id=v_personhood_id
      AND r6d_personhood_receipt_digest=
          (v_payload->>'personhoodReceiptDigest')::char(64)
      AND r6d_closure_receipt_id=v_closure_id
      AND r6d_closure_receipt_digest=
          (v_payload->>'closureReceiptDigest')::char(64);
    GET DIAGNOSTICS v_changed_master=ROW_COUNT;
    UPDATE public.suppliers
    SET name=NULL,updated_at=GREATEST(updated_at,v_now)
    WHERE id=v_entity_id AND name IS NOT NULL;
    IF EXISTS(
      SELECT 1 FROM public.suppliers
      WHERE id=v_entity_id AND name IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'r6d_public_entity_anonymization_incomplete'
        USING ERRCODE='55000';
    END IF;
    UPDATE core.supplier_identifiers
    SET display_value=NULL,r6d_anonymization_state='ANONYMIZED',
        r6d_anonymized_at=v_now,
        r6d_anonymization_receipt_digest=v_execution_digest
    WHERE supplier_id=v_entity_id
      AND r6d_anonymization_state='NATURAL_PERSON_ACTIVE';
    GET DIAGNOSTICS v_changed_identifiers=ROW_COUNT;
  END IF;
  UPDATE core.entity_aliases
  SET alias=NULL,normalized_alias=NULL,
      r6d_anonymization_state='ANONYMIZED',r6d_anonymized_at=v_now,
      r6d_anonymization_receipt_digest=v_execution_digest
  WHERE entity_type=v_entity_kind AND entity_id=v_entity_id
    AND r6d_anonymization_state='NATURAL_PERSON_ACTIVE';
  GET DIAGNOSTICS v_changed_aliases=ROW_COUNT;
  IF v_changed_master<>v_master_count
     OR v_changed_identifiers<>v_identifier_count
     OR v_changed_aliases<>v_alias_count THEN
    RAISE EXCEPTION 'r6d_entity_retention_atomic_row_count_mismatch'
      USING ERRCODE='40001';
  END IF;

  RETURN jsonb_build_object(
    'status','COMPLETED','jobId',p_job_id,'entityKind',v_entity_kind,
    'entityId',v_entity_id,'executionReceiptId',v_execution_id,
    'executionReceiptDigest',btrim(v_execution_digest),
    'closureReceiptId',v_closure_id,
    'closureReceiptDigest',v_payload->>'closureReceiptDigest',
    'anonymizedAt',v_now,'masterRowCount',v_master_count,
    'identifierRowCount',v_identifier_count,'aliasRowCount',v_alias_count,
    'backupDisposalDueAt',v_backup_due_at,'auditEventId',v_audit,
    'replayed',false
  );
END
$r6d_entity_execute$;
ALTER FUNCTION ops.execute_due_r6d_entity_retention_job_v1(
  uuid,uuid,bigint
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.execute_due_r6d_entity_retention_job_v1(
  uuid,uuid,bigint
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.execute_due_r6d_entity_retention_job_v1(
  uuid,uuid,bigint
) TO gurine_workflow_worker;
CREATE OR REPLACE FUNCTION ops.execute_due_r6d_person_retention_job_v1(
  p_job_id uuid,
  p_lease_token uuid,
  p_fencing_token bigint
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,core,editorial,extensions,pg_temp
AS $$
DECLARE
  v_job ops.jobs%ROWTYPE;
  v_existing ops.r6d_person_retention_execution_receipts_v1%ROWTYPE;
  v_context core.relationship_graph_person_context_v3%ROWTYPE;
  v_schedule ops.record_class_schedules%ROWTYPE;
  v_catalog ops.r6d_record_class_catalog%ROWTYPE;
  v_payload jsonb;
  v_context_id uuid;
  v_person_node_id uuid;
  v_schedule_id uuid;
  v_schedule_revision bigint;
  v_request_id uuid;
  v_trigger_at timestamptz;
  v_due_at timestamptz;
  v_context_state_digest char(64);
  v_expected_context_state_digest char(64);
  v_expected_idempotency_key char(64);
  v_expected_request_digest char(64);
  v_job_payload_digest char(64);
  v_lease_token_sha256 char(64);
  v_hold_resolution jsonb;
  v_erasure jsonb;
  v_erasure_receipt core.relationship_graph_person_erasure_receipts_v3%ROWTYPE;
  v_receipt_id uuid:=gen_random_uuid();
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
  v_audit uuid;
  v_now timestamptz:=clock_timestamp();
  v_lock_id text;
BEGIN
  IF p_job_id IS NULL OR p_lease_token IS NULL
     OR p_fencing_token IS NULL OR p_fencing_token<1 THEN
    RAISE EXCEPTION 'r6d_person_retention_job_fence_invalid'
      USING ERRCODE='22023';
  END IF;
  v_lease_token_sha256:=encode(extensions.digest(
    convert_to(p_lease_token::text,'UTF8'),'sha256'
  ),'hex');
  SELECT * INTO v_job FROM ops.jobs WHERE id=p_job_id FOR UPDATE;
  IF NOT FOUND OR v_job.job_type<>'R6D_PERSON_RETENTION'
     OR v_job.queue<>'workflow-worker' THEN
    RAISE EXCEPTION 'r6d_person_retention_job_lease_stale'
      USING ERRCODE='40001';
  END IF;
  v_payload:=v_job.payload;
  IF v_payload IS NULL OR jsonb_typeof(v_payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_payload))<>19
     OR NOT v_payload ?& ARRAY[
       'schemaVersion','contextId','personNodeId','topologyDigest',
       'recordClass','scheduleId','scheduleRevision','scheduleDigest',
       'triggerKind','terminalAction','holdBehavior','activeDurationSeconds',
       'backupDurationSeconds','triggerAt','dueAt','contextStateDigest',
       'requestId','idempotencyKeySha256','requestDigest'
     ]
     OR v_payload->>'schemaVersion'<>'r6d-person-retention-job.v1'
     OR v_payload->>'recordClass'<>'RELATIONSHIP_PERSON_CONTEXT'
     OR v_payload->>'triggerKind'<>'CREATED_AT'
     OR v_payload->>'terminalAction'<>'ANONYMIZE'
     OR v_payload->>'holdBehavior' NOT IN (
       'BLOCK_ON_RETENTION','BLOCK_ON_RETENTION_OR_DELETION'
     )
     OR NOT ops.r6d_lower_sha256(v_payload->>'topologyDigest')
     OR NOT ops.r6d_lower_sha256(v_payload->>'scheduleDigest')
     OR NOT ops.r6d_lower_sha256(v_payload->>'contextStateDigest')
     OR NOT ops.r6d_lower_sha256(v_payload->>'idempotencyKeySha256')
     OR NOT ops.r6d_lower_sha256(v_payload->>'requestDigest') THEN
    RAISE EXCEPTION 'r6d_person_retention_job_payload_invalid'
      USING ERRCODE='22023';
  END IF;

  BEGIN
    v_context_id:=(v_payload->>'contextId')::uuid;
    v_person_node_id:=(v_payload->>'personNodeId')::uuid;
    v_schedule_id:=(v_payload->>'scheduleId')::uuid;
    v_schedule_revision:=(v_payload->>'scheduleRevision')::bigint;
    v_trigger_at:=(v_payload->>'triggerAt')::timestamptz;
    v_due_at:=(v_payload->>'dueAt')::timestamptz;
    v_request_id:=(v_payload->>'requestId')::uuid;
  EXCEPTION WHEN invalid_text_representation OR datetime_field_overflow
    OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'r6d_person_retention_job_payload_invalid'
      USING ERRCODE='22023';
  END;
  IF v_schedule_revision<1
     OR jsonb_typeof(v_payload->'activeDurationSeconds')<>'number'
     OR jsonb_typeof(v_payload->'backupDurationSeconds')<>'number'
     OR (v_payload->>'activeDurationSeconds')::bigint<0
     OR (v_payload->>'backupDurationSeconds')::bigint<0 THEN
    RAISE EXCEPTION 'r6d_person_retention_job_payload_invalid'
      USING ERRCODE='22023';
  END IF;
  v_context_state_digest:=(v_payload->>'contextStateDigest')::char(64);
  v_job_payload_digest:=encode(
    extensions.digest(ops.canonical_jsonb_v1(v_payload),'sha256'),'hex'
  );
  v_expected_request_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_payload-'requestDigest'),'sha256'
  ),'hex');
  IF v_payload->>'requestDigest'<>btrim(v_expected_request_digest) THEN
    RAISE EXCEPTION 'r6d_person_retention_request_digest_mismatch'
      USING ERRCODE='22023';
  END IF;
  v_expected_idempotency_key:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','r6d-person-retention-idempotency.v1',
      'contextId',v_context_id,'personNodeId',v_person_node_id,
      'contextStateDigest',btrim(v_context_state_digest),
      'scheduleId',v_schedule_id,
      'scheduleDigest',v_payload->>'scheduleDigest','dueAt',v_due_at
    )
  ),'sha256'),'hex');
  IF v_payload->>'idempotencyKeySha256'<>
     btrim(v_expected_idempotency_key)
     OR v_job.dedupe_key IS DISTINCT FROM (
       'r6d-person-retention:'||v_context_id::text||':'||
       (v_payload->>'scheduleDigest')
     ) THEN
    RAISE EXCEPTION 'r6d_person_retention_idempotency_binding_invalid'
      USING ERRCODE='22023';
  END IF;

  -- The common workflow Worker owns job terminalization and attempt closure.
  -- This effect owner validates only the live claim, so a crash after its
  -- immutable receipt commit can be reclaimed and completed under a new fence.
  IF v_job.status<>'RUNNING'
     OR v_job.lease_token IS DISTINCT FROM p_lease_token
     OR v_job.fencing_token IS DISTINCT FROM p_fencing_token
     OR v_job.lease_owner IS NULL
     OR length(btrim(v_job.lease_owner)) NOT BETWEEN 1 AND 200
     OR v_job.lease_expires_at IS NULL OR v_job.lease_expires_at<=v_now THEN
    RAISE EXCEPTION 'r6d_person_retention_job_lease_stale'
      USING ERRCODE='40001';
  END IF;

  SELECT * INTO v_existing
  FROM ops.r6d_person_retention_execution_receipts_v1
  WHERE job_id=p_job_id FOR SHARE;
  IF FOUND THEN
    IF v_existing.context_id<>v_context_id
       OR v_existing.schedule_id<>v_schedule_id
       OR btrim(v_existing.schedule_digest)<>v_payload->>'scheduleDigest'
       OR btrim(v_existing.context_state_digest)<>
          btrim(v_context_state_digest)
       OR btrim(v_existing.job_payload_digest)<>
          btrim(v_job_payload_digest)
       OR v_existing.request_id<>v_request_id
       OR btrim(v_existing.idempotency_key_sha256)<>
          (v_payload->>'idempotencyKeySha256')
       OR btrim(v_existing.request_digest)<>
          (v_payload->>'requestDigest') THEN
      RAISE EXCEPTION 'r6d_person_retention_execution_replay_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN v_existing.receipt_payload||jsonb_build_object(
      'receiptDigest',btrim(v_existing.receipt_digest),
      'auditEventId',v_existing.audit_event_id,'replayed',true
    );
  END IF;

  SELECT * INTO v_context
  FROM core.relationship_graph_person_context_v3
  WHERE context_id=v_context_id;
  IF NOT FOUND OR v_context.erase_state<>'ACTIVE'
     OR v_context.person_node_id<>v_person_node_id
     OR btrim(v_context.topology_digest)<>v_payload->>'topologyDigest' THEN
    RAISE EXCEPTION 'r6d_person_retention_context_not_active'
      USING ERRCODE='55000';
  END IF;
  FOR v_lock_id IN
    SELECT lock_id FROM (
      VALUES(v_context.context_id::text),(v_context.person_node_id::text)
    ) AS locks(lock_id) ORDER BY lock_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_lock_id,13));
  END LOOP;
  SELECT * INTO v_context
  FROM core.relationship_graph_person_context_v3
  WHERE context_id=v_context_id FOR UPDATE;
  IF NOT FOUND OR v_context.erase_state<>'ACTIVE'
     OR v_context.person_node_id<>v_person_node_id
     OR btrim(v_context.topology_digest)<>v_payload->>'topologyDigest' THEN
    RAISE EXCEPTION 'r6d_person_retention_context_not_active'
      USING ERRCODE='55000';
  END IF;
  v_expected_context_state_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'contextId',v_context.context_id,
      'personNodeId',v_context.person_node_id,
      'topologyDigest',btrim(v_context.topology_digest),
      'personNameDigest',btrim(v_context.person_name_digest),
      'contextualNameSha256',btrim(v_context.contextual_name_sha256),
      'contextualNameAadDigest',btrim(v_context.contextual_name_aad_digest),
      'roleTitleSha256',btrim(v_context.role_title_sha256),
      'roleTitleAadDigest',btrim(v_context.role_title_aad_digest),
      'encryptionKeyId',v_context.encryption_key_id
    )),'sha256'
  ),'hex');
  IF btrim(v_expected_context_state_digest)<>btrim(v_context_state_digest) THEN
    RAISE EXCEPTION 'r6d_person_retention_context_digest_mismatch'
      USING ERRCODE='40001';
  END IF;

  SELECT * INTO v_schedule FROM ops.record_class_schedules
  WHERE id=v_schedule_id AND revision=v_schedule_revision
    AND record_class='RELATIONSHIP_PERSON_CONTEXT'
    AND schedule_digest=v_payload->>'scheduleDigest'
  FOR SHARE;
  SELECT * INTO v_catalog FROM ops.r6d_record_class_catalog
  WHERE record_class='RELATIONSHIP_PERSON_CONTEXT' FOR SHARE;
  IF v_schedule.id IS NULL OR v_catalog.record_class IS NULL
     OR (v_context.retention_schedule_id,
         v_context.retention_record_class,
         btrim(v_context.retention_schedule_digest)) IS DISTINCT FROM
        (v_schedule.id,v_schedule.record_class,btrim(v_schedule.schedule_digest))
     OR v_catalog.data_category<>'PERSON_IDENTITY' OR NOT v_catalog.pii_write
     OR v_catalog.required_terminal_action<>'ANONYMIZE'
     OR v_schedule.terminal_action<>v_catalog.required_terminal_action
     OR v_schedule.trigger_kind<>'CREATED_AT'
     OR v_schedule.hold_behavior NOT IN (
       'BLOCK_ON_RETENTION','BLOCK_ON_RETENTION_OR_DELETION'
     )
     OR v_schedule.restore_suppression_behavior<>'REAPPLY_BEFORE_ACCESS'
     OR v_schedule.active_duration_seconds IS NULL
     OR v_schedule.backup_duration_seconds IS NULL
     OR (v_catalog.required_trigger_kind IS NOT NULL
       AND v_catalog.required_trigger_kind<>v_schedule.trigger_kind)
     OR (v_catalog.required_active_duration_seconds IS NOT NULL
       AND v_catalog.required_active_duration_seconds<>
           v_schedule.active_duration_seconds)
     OR (v_catalog.required_backup_duration_seconds IS NOT NULL
       AND v_catalog.required_backup_duration_seconds<>
           v_schedule.backup_duration_seconds)
     OR (v_catalog.required_lawful_basis IS NOT NULL
       AND v_catalog.required_lawful_basis<>v_schedule.lawful_basis)
     OR v_schedule.effective_at>v_now
     OR v_schedule.review_expires_at<=v_now
     OR NOT EXISTS (
       SELECT 1 FROM ops.execution_receipts AS execution
       JOIN ops.action_decisions AS operational_decision
         ON operational_decision.id=v_schedule.operational_action_decision_id
        AND operational_decision.receipt_digest=
            v_schedule.operational_action_decision_receipt_digest
        AND operational_decision.decision_kind='APPROVE'
       JOIN ops.action_decisions AS legal_decision
         ON legal_decision.id=v_schedule.legal_action_decision_id
        AND legal_decision.receipt_digest=
            v_schedule.legal_action_decision_receipt_digest
        AND legal_decision.decision_kind='APPROVE'
       WHERE execution.id=v_schedule.action_execution_receipt_id
         AND execution.receipt_digest=
             v_schedule.action_execution_receipt_digest
         AND execution.aggregate_state='SUCCEEDED'
     ) THEN
    RAISE EXCEPTION 'r6d_person_retention_schedule_not_approved'
      USING ERRCODE='55000';
  END IF;
  v_trigger_at:=v_context.created_at;
  v_due_at:=v_trigger_at+make_interval(
    secs=>v_schedule.active_duration_seconds::double precision
  );
  IF v_payload->>'triggerKind'<>v_schedule.trigger_kind
     OR (v_payload->>'activeDurationSeconds')::bigint<>
        v_schedule.active_duration_seconds
     OR (v_payload->>'backupDurationSeconds')::bigint<>
        v_schedule.backup_duration_seconds
     OR (v_payload->>'holdBehavior')<>v_schedule.hold_behavior
     OR (v_payload->>'terminalAction')<>v_schedule.terminal_action
     OR (v_payload->>'triggerAt')::timestamptz IS DISTINCT FROM v_trigger_at
     OR (v_payload->>'dueAt')::timestamptz IS DISTINCT FROM v_due_at
     OR v_due_at>v_now THEN
    RAISE EXCEPTION 'r6d_person_retention_due_binding_invalid'
      USING ERRCODE='55000';
  END IF;

  v_hold_resolution:=ops.r6d_person_legal_hold_coverage_v1(
    'RELATIONSHIP_PERSON_CONTEXT',
    'core.relationship_graph_person_context_v3'::regclass,
    v_context.context_id,v_now
  );
  IF (v_hold_resolution->>'active')::boolean THEN
    RAISE EXCEPTION 'r6d_person_retention_legal_hold_active'
      USING ERRCODE='55000';
  END IF;

  v_erasure:=core.anonymize_relationship_graph_person_context_v3(
    v_context.context_id,'SERVICE',v_job.lease_owner,v_request_id,
    (v_payload->>'idempotencyKeySha256')::char(64),
    (v_payload->>'requestDigest')::char(64)
  );
  SELECT * INTO v_erasure_receipt
  FROM core.relationship_graph_person_erasure_receipts_v3
  WHERE request_id=v_request_id
    AND idempotency_key_sha256=v_payload->>'idempotencyKeySha256'
    AND request_digest=v_payload->>'requestDigest'
    AND context_id=v_context.context_id
  FOR SHARE;
  IF NOT FOUND OR btrim(v_erasure_receipt.receipt_digest)<>
     v_erasure->>'receiptDigest'
     OR btrim(v_erasure_receipt.prior_context_digest)<>
        btrim(v_context_state_digest)
     OR v_erasure_receipt.erasure_kind<>'ANONYMIZE'
     OR v_erasure_receipt.actor_type<>'SERVICE'
     OR v_erasure_receipt.actor_id<>v_job.lease_owner
     OR btrim(v_erasure_receipt.legal_hold_coverage_digest)<>
        v_hold_resolution->>'coverageDigest' THEN
    RAISE EXCEPTION 'r6d_person_retention_erasure_receipt_invalid'
      USING ERRCODE='55000';
  END IF;

  v_audit:=ops.append_audit_event(
    'r6d-person-retention:'||v_context.context_id::text,
    'SERVICE',v_job.lease_owner,NULL::uuid,
    'r6d.person_retention.execute','PersonContext',
    v_context.context_id::text,'privacy.retention.execute','SUCCESS',NULL,
    v_request_id,jsonb_build_object(
      'jobId',p_job_id,'jobFencingToken',p_fencing_token,
      'jobPayloadDigest',btrim(v_job_payload_digest),
      'contextStateDigest',btrim(v_context_state_digest),
      'scheduleId',v_schedule.id,
      'scheduleDigest',btrim(v_schedule.schedule_digest),
      'dueAt',v_due_at,
      'erasureReceiptDigest',btrim(v_erasure_receipt.receipt_digest)
    )
  );
  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','r6d-person-retention-execution.v1',
    'receiptId',v_receipt_id,'jobId',p_job_id,
    'jobFencingToken',p_fencing_token,
    'jobLeaseTokenSha256',btrim(v_lease_token_sha256),
    'jobPayloadDigest',btrim(v_job_payload_digest),
    'contextId',v_context.context_id,
    'personNodeId',v_context.person_node_id,
    'topologyDigest',btrim(v_context.topology_digest),
    'personNameDigest',btrim(v_context.person_name_digest),
    'contextStateDigest',btrim(v_context_state_digest),
    'scheduleId',v_schedule.id,'scheduleRevision',v_schedule.revision,
    'scheduleDigest',btrim(v_schedule.schedule_digest),
    'triggerKind',v_schedule.trigger_kind,
    'triggerAt',v_trigger_at,'dueAt',v_due_at,
    'erasureReceiptId',v_erasure_receipt.receipt_id,
    'erasureReceiptDigest',btrim(v_erasure_receipt.receipt_digest),
    'erasureAuditEventId',v_erasure_receipt.audit_event_id,
    'erasureActorType',v_erasure_receipt.actor_type,
    'erasureActorId',v_erasure_receipt.actor_id,
    'requestId',v_request_id,
    'idempotencyKeySha256',v_payload->>'idempotencyKeySha256',
    'requestDigest',v_payload->>'requestDigest',
    'governanceRetentionScheduleId',
      v_erasure_receipt.retention_schedule_id,
    'governanceRetentionRecordClass',
      v_erasure_receipt.retention_record_class,
    'governanceRetentionScheduleDigest',
      btrim(v_erasure_receipt.retention_schedule_digest),
    'auditEventId',v_audit,'completedAt',v_now
  );
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_receipt_digest:=encode(
    extensions.digest(v_receipt_canonical,'sha256'),'hex'
  );
  INSERT INTO ops.r6d_person_retention_execution_receipts_v1(
    receipt_id,job_id,job_fencing_token,job_lease_token_sha256,
    job_payload_digest,context_id,person_node_id,topology_digest,
    person_name_digest,context_state_digest,schedule_id,record_class,
    schedule_revision,schedule_digest,trigger_kind,trigger_at,due_at,
    erasure_receipt_id,
    erasure_receipt_digest,erasure_audit_event_id,request_id,
    idempotency_key_sha256,request_digest,
    governance_retention_schedule_id,governance_retention_record_class,
    governance_retention_schedule_digest,audit_event_id,receipt_payload,
    receipt_canonical,receipt_digest,completed_at
  ) VALUES(
    v_receipt_id,p_job_id,p_fencing_token,v_lease_token_sha256,
    v_job_payload_digest,v_context.context_id,v_context.person_node_id,
    v_context.topology_digest,v_context.person_name_digest,
    v_context_state_digest,v_schedule.id,v_schedule.record_class,
    v_schedule.revision,v_schedule.schedule_digest,v_schedule.trigger_kind,
    v_trigger_at,v_due_at,
    v_erasure_receipt.receipt_id,v_erasure_receipt.receipt_digest,
    v_erasure_receipt.audit_event_id,v_request_id,
    (v_payload->>'idempotencyKeySha256')::char(64),
    (v_payload->>'requestDigest')::char(64),
    v_erasure_receipt.retention_schedule_id,
    v_erasure_receipt.retention_record_class,
    v_erasure_receipt.retention_schedule_digest,v_audit,v_receipt_payload,
    v_receipt_canonical,v_receipt_digest,v_now
  );
  RETURN v_receipt_payload||jsonb_build_object(
    'receiptDigest',btrim(v_receipt_digest),'replayed',false
  );
END
$$;
ALTER FUNCTION ops.execute_due_r6d_person_retention_job_v1(
  uuid,uuid,bigint
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.execute_due_r6d_person_retention_job_v1(
  uuid,uuid,bigint
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.execute_due_r6d_person_retention_job_v1(
  uuid,uuid,bigint
) TO gurine_workflow_worker;

-- R6d D2: organization official-channel authority closure.
-- This merge snippet intentionally has no BEGIN/COMMIT and no operating seed.

CREATE TABLE editorial.organization_official_channel_authority_receipts_v1 (
  authority_receipt_id uuid PRIMARY KEY,
  authority_version bigint NOT NULL,
  assertion_id uuid NOT NULL UNIQUE,
  organization_kind text NOT NULL,
  organization_id uuid NOT NULL,
  agency_id uuid REFERENCES core.agencies(id) ON DELETE RESTRICT,
  supplier_id uuid REFERENCES core.suppliers(id) ON DELETE RESTRICT,
  verification_method text NOT NULL,
  source_id uuid NOT NULL,
  communication_verification_id uuid
    REFERENCES intake.communication_endpoint_verifications(id)
    ON DELETE RESTRICT,
  official_document_evidence_id uuid REFERENCES editorial.evidence(id)
    ON DELETE RESTRICT,
  source_purpose text NOT NULL,
  authority_receipt_kind text NOT NULL,
  underlying_source_proof_digest char(64) NOT NULL,
  source_snapshot_payload jsonb NOT NULL,
  source_snapshot_canonical bytea NOT NULL,
  source_snapshot_digest char(64) NOT NULL UNIQUE,
  attested_by_user_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  actor_assertion_jti uuid NOT NULL UNIQUE,
  actor_action_digest char(64) NOT NULL,
  step_up_authorization_id uuid NOT NULL UNIQUE
    REFERENCES ops.step_up_authorizations(id) ON DELETE RESTRICT,
  step_up_receipt_digest char(64) NOT NULL,
  session_id uuid NOT NULL REFERENCES ops.sessions(id) ON DELETE RESTRICT,
  reason_digest char(64) NOT NULL,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  attested_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  authority_payload jsonb NOT NULL,
  authority_canonical bytea NOT NULL,
  authority_receipt_digest char(64) NOT NULL UNIQUE,
  audit_event_id uuid NOT NULL UNIQUE REFERENCES ops.audit_events(id)
    ON DELETE RESTRICT,
  audit_receipt_digest char(64) NOT NULL UNIQUE,
  outbox_event_id uuid NOT NULL UNIQUE REFERENCES ops.outbox(id)
    ON DELETE RESTRICT,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT organization_official_channel_authority_receipts_v1_org_ck CHECK (
    (organization_kind='AGENCY' AND agency_id=organization_id
      AND supplier_id IS NULL)
    OR
    (organization_kind='SUPPLIER' AND supplier_id=organization_id
      AND agency_id IS NULL)
  ),
  CONSTRAINT organization_official_channel_authority_receipts_v1_source_ck CHECK (
    authority_version=1
    AND (
      verification_method='OFFICIAL_DOMAIN_EMAIL'
      AND source_purpose='OFFICIAL_DOMAIN_CONTROL'
      AND authority_receipt_kind='ORGANIZATION_DOMAIN_CONTROL'
      AND communication_verification_id=source_id
      AND official_document_evidence_id IS NULL
      OR
      verification_method='OFFICIAL_DOCUMENT'
      AND source_purpose='OFFICIAL_REPRESENTATION'
      AND authority_receipt_kind='OFFICIAL_REPRESENTATION_BINDING'
      AND official_document_evidence_id=source_id
      AND communication_verification_id IS NULL
    )
    AND attested_at<expires_at
    AND created_at>=attested_at
    AND convert_from(source_snapshot_canonical,'UTF8')::jsonb
      =source_snapshot_payload
    AND source_snapshot_canonical=
      ops.canonical_jsonb_v1(source_snapshot_payload)
    AND source_snapshot_digest=encode(extensions.digest(
      source_snapshot_canonical,'sha256'),'hex')
    AND convert_from(authority_canonical,'UTF8')::jsonb=authority_payload
    AND authority_canonical=ops.canonical_jsonb_v1(authority_payload)
    AND authority_payload=jsonb_build_object(
      'schemaVersion','organization-authority-receipt.v1',
      'authorityReceiptId',authority_receipt_id,
      'authorityVersion',authority_version,
      'assertionId',assertion_id,
      'organizationKind',organization_kind,
      'organizationId',organization_id,
      'verificationMethod',verification_method,
      'sourceId',source_id,
      'sourcePurpose',source_purpose,
      'authorityReceiptKind',authority_receipt_kind,
      'underlyingSourceProofDigest',underlying_source_proof_digest,
      'sourceSnapshotDigest',source_snapshot_digest,
      'attestedByUserId',attested_by_user_id,
      'actorAssertionJti',actor_assertion_jti,
      'actorActionDigest',actor_action_digest,
      'stepUpAuthorizationId',step_up_authorization_id,
      'stepUpReceiptDigest',step_up_receipt_digest,
      'sessionId',session_id,
      'reasonDigest',reason_digest,
      'requestId',request_id,
      'idempotencyKeySha256',idempotency_key_sha256,
      'requestDigest',request_digest,
      'attestedAt',attested_at,
      'expiresAt',expires_at
    )
    AND authority_receipt_digest=encode(extensions.digest(
      authority_canonical,'sha256'),'hex')
    AND ops.r6d_lower_sha256(underlying_source_proof_digest)
    AND ops.r6d_lower_sha256(source_snapshot_digest)
    AND ops.r6d_lower_sha256(actor_action_digest)
    AND ops.r6d_lower_sha256(step_up_receipt_digest)
    AND ops.r6d_lower_sha256(reason_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(authority_receipt_digest)
    AND ops.r6d_lower_sha256(audit_receipt_digest)
  ),
  CONSTRAINT organization_official_channel_authority_receipts_v1_exact_uq UNIQUE(
    authority_receipt_id,authority_receipt_digest
  ),
  CONSTRAINT organization_official_channel_authority_receipts_v1_binding_uq UNIQUE(
    authority_receipt_id,authority_receipt_digest,assertion_id,
    organization_kind,organization_id,verification_method,source_id,expires_at
  ),
  CONSTRAINT organization_official_channel_authority_receipts_v1_retention_fk
    FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(
    id,record_class,schedule_digest
  ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT organization_official_channel_authority_receipts_v1_class_fk
    FOREIGN KEY(
    retention_record_class
  ) REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  CONSTRAINT organization_official_channel_authority_receipts_v1_class_ck CHECK(
    retention_record_class='RESPONSE_IDENTITY_GOVERNANCE'
  )
);
ALTER TABLE editorial.organization_official_channel_authority_receipts_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON editorial.organization_official_channel_authority_receipts_v1
  FROM PUBLIC;
REVOKE ALL ON editorial.organization_official_channel_authority_receipts_v1
  FROM gurine_control_api,gurine_submission_api,gurine_workflow_worker,
    gurine_analysis_worker,gurine_public_projector,gurine_notification_worker;
GRANT SELECT ON editorial.organization_official_channel_authority_receipts_v1
  TO gurine_auditor;
CREATE TRIGGER organization_official_channel_authority_receipts_v1_immutable_guard
  BEFORE UPDATE OR DELETE
  ON editorial.organization_official_channel_authority_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE OR REPLACE FUNCTION editorial.bind_organization_authority_schedule_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,pg_temp
AS $authority_schedule$
DECLARE
  v_catalog ops.r6d_record_class_catalog%ROWTYPE;
  v_schedule ops.record_class_schedules%ROWTYPE;
  v_count bigint;
  v_at timestamptz:=clock_timestamp();
BEGIN
  IF NEW.retention_schedule_id IS NOT NULL
     OR NEW.retention_record_class IS NOT NULL
     OR NEW.retention_schedule_digest IS NOT NULL THEN
    RAISE EXCEPTION 'organization_authority_schedule_caller_override'
      USING ERRCODE='55000';
  END IF;
  SELECT * INTO v_catalog FROM ops.r6d_record_class_catalog
  WHERE record_class='RESPONSE_IDENTITY_GOVERNANCE' FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'organization_authority_record_class_missing'
      USING ERRCODE='55000';
  END IF;
  LOCK TABLE ops.record_class_schedules IN SHARE MODE;
  SELECT count(*) INTO v_count
  FROM ops.record_class_schedules AS schedule
  WHERE schedule.record_class=v_catalog.record_class
    AND schedule.effective_at<=v_at
    AND schedule.review_expires_at>v_at
    AND schedule.terminal_action=v_catalog.required_terminal_action
    AND (v_catalog.required_trigger_kind IS NULL
      OR schedule.trigger_kind=v_catalog.required_trigger_kind)
    AND (v_catalog.required_active_duration_seconds IS NULL
      OR schedule.active_duration_seconds=
        v_catalog.required_active_duration_seconds)
    AND (v_catalog.required_backup_duration_seconds IS NULL
      OR schedule.backup_duration_seconds=
        v_catalog.required_backup_duration_seconds)
    AND (v_catalog.required_lawful_basis IS NULL
      OR schedule.lawful_basis=v_catalog.required_lawful_basis);
  IF v_count=0 THEN
    RAISE EXCEPTION 'organization_authority_schedule_missing'
      USING ERRCODE='55000';
  ELSIF v_count<>1 THEN
    RAISE EXCEPTION 'organization_authority_schedule_ambiguous'
      USING ERRCODE='55000';
  END IF;
  SELECT * INTO STRICT v_schedule
  FROM ops.record_class_schedules AS schedule
  WHERE schedule.record_class=v_catalog.record_class
    AND schedule.effective_at<=v_at
    AND schedule.review_expires_at>v_at
    AND schedule.terminal_action=v_catalog.required_terminal_action
    AND (v_catalog.required_trigger_kind IS NULL
      OR schedule.trigger_kind=v_catalog.required_trigger_kind)
    AND (v_catalog.required_active_duration_seconds IS NULL
      OR schedule.active_duration_seconds=
        v_catalog.required_active_duration_seconds)
    AND (v_catalog.required_backup_duration_seconds IS NULL
      OR schedule.backup_duration_seconds=
        v_catalog.required_backup_duration_seconds)
    AND (v_catalog.required_lawful_basis IS NULL
      OR schedule.lawful_basis=v_catalog.required_lawful_basis);
  NEW.retention_schedule_id:=v_schedule.id;
  NEW.retention_record_class:=v_schedule.record_class;
  NEW.retention_schedule_digest:=v_schedule.schedule_digest;
  RETURN NEW;
END
$authority_schedule$;
ALTER FUNCTION editorial.bind_organization_authority_schedule_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.bind_organization_authority_schedule_v1()
  FROM PUBLIC;
CREATE TRIGGER organization_official_channel_authority_receipts_v1_retention_bind
  BEFORE INSERT ON editorial.organization_official_channel_authority_receipts_v1
  FOR EACH ROW
  EXECUTE FUNCTION editorial.bind_organization_authority_schedule_v1();

ALTER TABLE editorial.organization_official_channel_assertions_v1
  ADD COLUMN authority_receipt_id uuid,
  ADD COLUMN authority_source_id uuid,
  ADD CONSTRAINT organization_official_channel_authority_receipt_fk
    FOREIGN KEY(
      authority_receipt_id,organization_authority_receipt_digest,
      assertion_id,organization_kind,organization_id,verification_method,
      authority_source_id,expires_at
    )
    REFERENCES editorial.organization_official_channel_authority_receipts_v1(
      authority_receipt_id,authority_receipt_digest,assertion_id,
      organization_kind,organization_id,verification_method,source_id,expires_at
    ) ON DELETE RESTRICT;
CREATE UNIQUE INDEX organization_official_channel_authority_receipt_uq
  ON editorial.organization_official_channel_assertions_v1(
    authority_receipt_id
  ) WHERE authority_receipt_id IS NOT NULL;

CREATE OR REPLACE FUNCTION editorial.guard_official_channel_authority_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,editorial,pg_temp
AS $assertion_authority_guard$
BEGIN
  IF NEW.authority_receipt_id IS NULL OR NEW.authority_source_id IS NULL
     OR NEW.authority_source_id IS DISTINCT FROM COALESCE(
       NEW.communication_verification_id,
       NEW.official_document_evidence_id
     ) THEN
    RAISE EXCEPTION 'official_channel_authority_receipt_required'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$assertion_authority_guard$;

-- Existing 0038 rows have none of these fields and remain staged legacy.
ALTER TABLE editorial.organization_official_channel_revocation_receipts_v1
  ADD COLUMN actor_assertion_jti uuid,
  ADD COLUMN actor_action_digest char(64),
  ADD COLUMN step_up_authorization_id uuid
    REFERENCES ops.step_up_authorizations(id) ON DELETE RESTRICT,
  ADD COLUMN step_up_receipt_digest char(64),
  ADD COLUMN session_id uuid REFERENCES ops.sessions(id) ON DELETE RESTRICT,
  ADD COLUMN request_id uuid,
  ADD COLUMN idempotency_key_sha256 char(64),
  ADD COLUMN request_digest char(64),
  ADD COLUMN audit_event_id uuid REFERENCES ops.audit_events(id)
    ON DELETE RESTRICT,
  ADD COLUMN audit_receipt_digest char(64),
  ADD COLUMN outbox_event_id uuid REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  ADD CONSTRAINT organization_official_channel_revocation_owner_ck CHECK (
    num_nonnulls(
      actor_assertion_jti,actor_action_digest,step_up_authorization_id,
      step_up_receipt_digest,session_id,request_id,idempotency_key_sha256,
      request_digest,audit_event_id,audit_receipt_digest,outbox_event_id
    ) IN (0,11)
    AND (actor_action_digest IS NULL
      OR ops.r6d_lower_sha256(actor_action_digest))
    AND (step_up_receipt_digest IS NULL
      OR ops.r6d_lower_sha256(step_up_receipt_digest))
    AND (idempotency_key_sha256 IS NULL
      OR ops.r6d_lower_sha256(idempotency_key_sha256))
    AND (request_digest IS NULL OR ops.r6d_lower_sha256(request_digest))
    AND (audit_receipt_digest IS NULL
      OR ops.r6d_lower_sha256(audit_receipt_digest))
  );
ALTER TABLE editorial.organization_official_channel_revocation_receipts_v1
  DROP CONSTRAINT organization_official_channel_revocations_v1_shape_ck;
ALTER TABLE editorial.organization_official_channel_revocation_receipts_v1
  ADD CONSTRAINT organization_official_channel_revocations_v1_shape_ck CHECK (
    char_length(reason_code) BETWEEN 1 AND 100
    AND btrim(reason_code)=reason_code
    AND reason_code !~ '[[:cntrl:]]'
    AND ops.r6d_lower_sha256(assertion_digest)
    AND ops.r6d_lower_sha256(organization_source_binding_digest)
    AND ops.r6d_lower_sha256(assertion_receipt_digest)
    AND ops.r6d_lower_sha256(reason_digest)
    AND ops.r6d_lower_sha256(revocation_receipt_digest)
    AND created_at>=revoked_at
    AND convert_from(revocation_canonical,'UTF8')::jsonb=revocation_payload
    AND revocation_canonical=ops.canonical_jsonb_v1(revocation_payload)
    AND revocation_payload=jsonb_build_object(
      'schemaVersion','organization-official-channel-revocation.v1',
      'revocationId',revocation_id,'assertionId',assertion_id,
      'assertionDigest',assertion_digest,
      'organizationSourceBindingDigest',organization_source_binding_digest,
      'assertionReceiptDigest',assertion_receipt_digest,
      'reasonCode',reason_code,'reasonDigest',reason_digest,
      'revokedByUserId',revoked_by_user_id,'revokedAt',revoked_at
    )
    AND revocation_receipt_digest=encode(extensions.digest(
      revocation_canonical,'sha256'),'hex')
  );
CREATE UNIQUE INDEX organization_official_channel_revocation_actor_jti_uq
  ON editorial.organization_official_channel_revocation_receipts_v1(
    actor_assertion_jti
  ) WHERE actor_assertion_jti IS NOT NULL;
CREATE UNIQUE INDEX organization_official_channel_revocation_step_up_uq
  ON editorial.organization_official_channel_revocation_receipts_v1(
    step_up_authorization_id
  ) WHERE step_up_authorization_id IS NOT NULL;
CREATE UNIQUE INDEX organization_official_channel_revocation_request_uq
  ON editorial.organization_official_channel_revocation_receipts_v1(request_id)
  WHERE request_id IS NOT NULL;
CREATE UNIQUE INDEX organization_official_channel_revocation_idempotency_uq
  ON editorial.organization_official_channel_revocation_receipts_v1(
    idempotency_key_sha256
  ) WHERE idempotency_key_sha256 IS NOT NULL;
CREATE UNIQUE INDEX organization_official_channel_revocation_audit_uq
  ON editorial.organization_official_channel_revocation_receipts_v1(
    audit_event_id
  ) WHERE audit_event_id IS NOT NULL;
CREATE UNIQUE INDEX organization_official_channel_revocation_outbox_uq
  ON editorial.organization_official_channel_revocation_receipts_v1(
    outbox_event_id
  ) WHERE outbox_event_id IS NOT NULL;

-- Forward declaration keeps owner definitions independently compilable. It is
-- replaced by the exact method-specific resolver later in this same snippet.
CREATE OR REPLACE FUNCTION editorial.resolve_official_channel_source_v1(
  text,uuid,text,uuid,uuid,timestamptz,timestamptz
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,pg_temp
AS $resolve_source_forward$
BEGIN
  RAISE EXCEPTION 'official_channel_source_resolver_not_installed'
    USING ERRCODE='55000';
END
$resolve_source_forward$;
ALTER FUNCTION editorial.resolve_official_channel_source_v1(
  text,uuid,text,uuid,uuid,timestamptz,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.resolve_official_channel_source_v1(
  text,uuid,text,uuid,uuid,timestamptz,timestamptz
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.require_control_actor_assertion_v1(
  p_actor_assertion_jti uuid,
  p_actor_assertion_request_digest char(64),
  p_evaluated_at timestamptz
) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,pg_temp
AS $actor_assertion$
DECLARE
  v_assertion ops.assertion_replay_guard%ROWTYPE;
BEGIN
  IF p_actor_assertion_jti IS NULL
     OR p_actor_assertion_jti=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR NOT ops.r6d_lower_sha256(p_actor_assertion_request_digest)
     OR p_evaluated_at IS NULL OR NOT isfinite(p_evaluated_at) THEN
    RAISE EXCEPTION 'official_channel_actor_assertion_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO v_assertion
  FROM ops.assertion_replay_guard
  WHERE assertion_type='ACTOR' AND jti=p_actor_assertion_jti;
  IF NOT FOUND OR v_assertion.issuer<>'identity-api'
     OR v_assertion.audience<>'control-api'
     OR v_assertion.request_digest<>p_actor_assertion_request_digest
     OR v_assertion.expires_at<=p_evaluated_at
     OR v_assertion.consumed_at>p_evaluated_at THEN
    RAISE EXCEPTION 'official_channel_actor_assertion_invalid'
      USING ERRCODE='23514';
  END IF;
END
$actor_assertion$;
ALTER FUNCTION editorial.require_control_actor_assertion_v1(
  uuid,char(64),timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.require_control_actor_assertion_v1(
  uuid,char(64),timestamptz
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.attest_organization_official_channel_v1(
  p_payload jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_sha256 char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,intake,core,raw,ops,extensions,pg_temp
AS $attest$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_scope text;
  v_idempotency ops.idempotency_keys%ROWTYPE;
  v_existing
    editorial.organization_official_channel_authority_receipts_v1%ROWTYPE;
  v_existing_assertion
    editorial.organization_official_channel_assertions_v1%ROWTYPE;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_organization_kind text;
  v_organization_id uuid;
  v_method text;
  v_source_id uuid;
  v_expires_at timestamptz;
  v_actor_assertion_jti uuid;
  v_actor_assertion_request_digest char(64);
  v_actor_action_digest char(64);
  v_step_up_id uuid;
  v_reason_digest char(64);
  v_source jsonb;
  v_authority_id uuid:=gen_random_uuid();
  v_assertion_id uuid:=gen_random_uuid();
  v_step_up_payload jsonb;
  v_step_up_digest char(64);
  v_source_snapshot jsonb;
  v_source_snapshot_canonical bytea;
  v_source_snapshot_digest char(64);
  v_underlying_digest char(64);
  v_source_purpose text;
  v_authority_kind text;
  v_authority_payload jsonb;
  v_authority_canonical bytea;
  v_authority_digest char(64);
  v_binding_payload jsonb;
  v_binding_canonical bytea;
  v_binding_digest char(64);
  v_assertion_payload jsonb;
  v_assertion_canonical bytea;
  v_assertion_digest char(64);
  v_registry_payload jsonb;
  v_registry_canonical bytea;
  v_registry_digest char(64);
  v_audit_id uuid;
  v_audit_digest char(64);
  v_outbox_id uuid;
  v_communication_subject_id uuid;
  v_communication_subject_origin_digest char(64);
  v_communication_subject_profile_version bigint;
  v_communication_subject_profile_digest char(64);
  v_communication_endpoint_id uuid;
  v_communication_endpoint_version bigint;
  v_communication_endpoint_digest char(64);
  v_communication_verification_id uuid;
  v_document_evidence_id uuid;
  v_document_evidence_version bigint;
  v_document_content_sha256 char(64);
  v_document_source_id uuid;
  v_document_source_sha256 char(64);
  v_document_locator_sha256 char(64);
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_payload))<>15
     OR NOT p_payload ?& ARRAY[
       'organizationKind','organizationId','verificationMethod','sourceId',
       'expiresAt','reason','expectedAuthorityVersion',
       '_actorAssertionJti','_actorAssertionRequestSha256',
       '_actorAssuranceLevel',
       '_actorEffectiveCapability','_actorActionDigest',
       '_actorStepUpAuthorizationId','_actorIdempotencyKeySha256',
       '_actorRequestKeySha256'
     ]
     OR jsonb_typeof(p_payload->'organizationKind')<>'string'
     OR jsonb_typeof(p_payload->'organizationId')<>'string'
     OR jsonb_typeof(p_payload->'verificationMethod')<>'string'
     OR jsonb_typeof(p_payload->'sourceId')<>'string'
     OR jsonb_typeof(p_payload->'expiresAt')<>'string'
     OR jsonb_typeof(p_payload->'reason')<>'string'
     OR jsonb_typeof(p_payload->'expectedAuthorityVersion')<>'number'
     OR p_payload->>'expectedAuthorityVersion'<>'1'
     OR jsonb_typeof(p_payload->'_actorAssertionJti')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssertionRequestSha256')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssuranceLevel')<>'string'
     OR jsonb_typeof(p_payload->'_actorEffectiveCapability')<>'string'
     OR jsonb_typeof(p_payload->'_actorActionDigest')<>'string'
     OR jsonb_typeof(p_payload->'_actorStepUpAuthorizationId')<>'string'
     OR jsonb_typeof(p_payload->'_actorIdempotencyKeySha256')<>'string'
     OR jsonb_typeof(p_payload->'_actorRequestKeySha256')<>'string'
     OR p_payload->>'_actorAssuranceLevel'<>'STEP_UP'
     OR p_payload->>'_actorEffectiveCapability'<>'responses.review'
     OR p_actor_id IS NULL
     OR p_actor_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_session_id IS NULL
     OR p_session_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_request_id IS NULL
     OR p_request_id='00000000-0000-0000-0000-000000000000'::uuid
     OR NOT ops.r6d_lower_sha256(p_idempotency_key_sha256)
     OR NOT ops.r6d_lower_sha256(p_request_sha256)
     OR NOT ops.r6d_lower_sha256(
       p_payload->>'_actorAssertionRequestSha256'
     )
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorActionDigest')
     OR NOT ops.r6d_lower_sha256(
       p_payload->>'_actorIdempotencyKeySha256'
     )
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorRequestKeySha256')
     OR p_payload->>'_actorIdempotencyKeySha256'<>
       btrim(p_idempotency_key_sha256)
     OR p_payload->>'_actorRequestKeySha256'<>
       btrim(p_idempotency_key_sha256)
     OR char_length(p_payload->>'reason') NOT BETWEEN 1 AND 4000
     OR btrim(p_payload->>'reason')<>p_payload->>'reason'
     OR p_payload->>'reason' ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION 'official_channel_attest_input_invalid'
      USING ERRCODE='22023';
  END IF;
  BEGIN
    v_organization_kind:=p_payload->>'organizationKind';
    v_organization_id:=(p_payload->>'organizationId')::uuid;
    v_method:=p_payload->>'verificationMethod';
    v_source_id:=(p_payload->>'sourceId')::uuid;
    v_expires_at:=(p_payload->>'expiresAt')::timestamptz;
    v_actor_assertion_jti:=(p_payload->>'_actorAssertionJti')::uuid;
    v_actor_assertion_request_digest:=
      (p_payload->>'_actorAssertionRequestSha256')::char(64);
    v_actor_action_digest:=(p_payload->>'_actorActionDigest')::char(64);
    v_step_up_id:=(p_payload->>'_actorStepUpAuthorizationId')::uuid;
  EXCEPTION WHEN invalid_text_representation OR invalid_datetime_format
      OR datetime_field_overflow THEN
    RAISE EXCEPTION 'official_channel_attest_input_invalid'
      USING ERRCODE='22023';
  END;
  IF v_organization_kind NOT IN ('AGENCY','SUPPLIER')
     OR v_method NOT IN ('OFFICIAL_DOMAIN_EMAIL','OFFICIAL_DOCUMENT')
     OR v_organization_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_source_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_actor_assertion_jti=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_step_up_id='00000000-0000-0000-0000-000000000000'::uuid
     OR NOT isfinite(v_expires_at) OR v_expires_at<=v_now THEN
    RAISE EXCEPTION 'official_channel_attest_input_invalid'
      USING ERRCODE='22023';
  END IF;

  v_scope:='control:'||p_actor_id::text||
    ':attestOrganizationOfficialChannel';
  SELECT * INTO v_idempotency FROM ops.idempotency_keys
  WHERE scope=v_scope AND key_hash=p_idempotency_key_sha256 FOR UPDATE;
  IF NOT FOUND OR v_idempotency.expires_at<=v_now
     OR v_idempotency.request_hash<>p_request_sha256 THEN
    RAISE EXCEPTION 'official_channel_attest_idempotency_conflict'
      USING ERRCODE='40001';
  END IF;
  PERFORM editorial.require_control_actor_assertion_v1(
    v_actor_assertion_jti,v_actor_assertion_request_digest,v_now
  );
  SELECT * INTO v_existing
  FROM editorial.organization_official_channel_authority_receipts_v1
  WHERE idempotency_key_sha256=p_idempotency_key_sha256 FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest<>p_request_sha256
       OR num_nonnulls(
         v_idempotency.response_status,v_idempotency.response_body,
         v_idempotency.resource_type,v_idempotency.resource_id
       ) NOT IN (0,4)
       OR (v_idempotency.resource_id IS NOT NULL AND (
         v_idempotency.response_status<>201
         OR v_idempotency.resource_type<>'organization_official_channel'
         OR v_idempotency.resource_id<>v_existing.assertion_id::text
       )) THEN
      RAISE EXCEPTION 'official_channel_attest_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    SELECT * INTO v_existing_assertion
    FROM editorial.organization_official_channel_assertions_v1
    WHERE authority_receipt_id=v_existing.authority_receipt_id
      AND organization_authority_receipt_digest=
        v_existing.authority_receipt_digest
    FOR SHARE;
    IF NOT FOUND OR v_existing_assertion.assertion_id<>
       v_existing.assertion_id THEN
      RAISE EXCEPTION 'official_channel_attest_replay_receipt_missing'
        USING ERRCODE='55000';
    END IF;
    RETURN jsonb_build_object(
      'assertionId',v_existing.assertion_id,
      'assertionVersion',1,
      'authorityReceiptId',v_existing.authority_receipt_id,
      'authorityReceiptDigest',v_existing.authority_receipt_digest,
      'registryReceiptDigest',v_existing_assertion.receipt_digest,
      'auditEventId',v_existing.audit_event_id,
      'attestedAt',v_existing.attested_at,
      'expiresAt',v_existing.expires_at,
      'outboxEventIds',jsonb_build_array(v_existing.outbox_event_id),
      'replayed',true
    );
  END IF;
  IF num_nonnulls(
       v_idempotency.response_status,v_idempotency.response_body,
       v_idempotency.resource_type,v_idempotency.resource_id
     )<>0 THEN
    RAISE EXCEPTION 'official_channel_attest_idempotency_conflict'
      USING ERRCODE='40001';
  END IF;

  SELECT * INTO v_step_up FROM ops.step_up_authorizations
  WHERE id=v_step_up_id FOR UPDATE;
  IF NOT FOUND OR v_step_up.closed_at IS NOT NULL
     OR v_step_up.session_id<>p_session_id
     OR v_step_up.expires_at<=v_now
     OR v_step_up.action_digest<>v_actor_action_digest
     OR v_step_up.idempotency_key_sha256<>p_idempotency_key_sha256
     OR v_step_up.assertion_issue_count NOT BETWEEN 1 AND 3
     OR v_step_up.last_issued_at IS NULL OR v_step_up.last_issued_at>v_now
     OR v_step_up.last_issued_at>=v_step_up.expires_at
     OR v_step_up.expires_at>
       v_step_up.last_issued_at+interval '5 minutes 5 seconds'
     OR NOT EXISTS(
       SELECT 1 FROM ops.sessions AS session
       JOIN ops.users AS actor ON actor.id=session.user_id
       WHERE session.id=p_session_id AND session.user_id=p_actor_id
         AND session.revoked_at IS NULL AND session.expires_at>v_now
         AND actor.status='ACTIVE'
     ) THEN
    RAISE EXCEPTION 'official_channel_attest_step_up_invalid'
      USING ERRCODE='23514';
  END IF;
  IF EXISTS(
       SELECT 1
       FROM editorial.organization_official_channel_authority_receipts_v1
       WHERE actor_assertion_jti=v_actor_assertion_jti
          OR step_up_authorization_id=v_step_up_id
     ) OR EXISTS(
       SELECT 1
       FROM editorial.organization_official_channel_revocation_receipts_v1
       WHERE actor_assertion_jti=v_actor_assertion_jti
          OR step_up_authorization_id=v_step_up_id
     ) THEN
    RAISE EXCEPTION 'official_channel_attest_actor_authority_reused'
      USING ERRCODE='55000';
  END IF;

  PERFORM assertion_id
  FROM editorial.organization_official_channel_assertions_v1
  WHERE communication_verification_id=v_source_id
     OR official_document_evidence_id=v_source_id
  ORDER BY assertion_id
  FOR SHARE;
  IF FOUND THEN
    RAISE EXCEPTION 'official_channel_attest_source_already_used'
      USING ERRCODE='55000';
  END IF;
  v_source:=editorial.resolve_official_channel_source_v1(
    v_method,v_source_id,v_organization_kind,v_organization_id,
    p_actor_id,v_expires_at,v_now
  );

  v_reason_digest:=encode(extensions.digest(
    convert_to(p_payload->>'reason','UTF8'),'sha256'),'hex');
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
    ops.canonical_jsonb_v1(v_step_up_payload),'sha256'),'hex');
  v_source_snapshot:=v_source->'sourceSnapshotPayload';
  v_source_snapshot_canonical:=ops.canonical_jsonb_v1(v_source_snapshot);
  v_source_snapshot_digest:=
    (v_source->>'sourceSnapshotDigest')::char(64);
  v_underlying_digest:=
    (v_source->>'underlyingSourceProofDigest')::char(64);
  v_source_purpose:=v_source->>'sourcePurpose';
  v_authority_kind:=v_source->>'authorityReceiptKind';
  v_communication_subject_id:=
    (v_source->>'communicationSubjectId')::uuid;
  v_communication_subject_origin_digest:=
    (v_source->>'communicationSubjectOriginDigest')::char(64);
  v_communication_subject_profile_version:=
    (v_source->>'communicationSubjectProfileVersion')::bigint;
  v_communication_subject_profile_digest:=
    (v_source->>'communicationSubjectProfileDigest')::char(64);
  v_communication_endpoint_id:=
    (v_source->>'communicationEndpointId')::uuid;
  v_communication_endpoint_version:=
    (v_source->>'communicationEndpointVersion')::bigint;
  v_communication_endpoint_digest:=
    (v_source->>'communicationEndpointDigest')::char(64);
  v_communication_verification_id:=
    (v_source->>'communicationVerificationId')::uuid;
  v_document_evidence_id:=
    (v_source->>'officialDocumentEvidenceId')::uuid;
  v_document_evidence_version:=
    (v_source->>'officialDocumentEvidenceVersion')::bigint;
  v_document_content_sha256:=
    (v_source->>'officialDocumentContentSha256')::char(64);
  v_document_source_id:=
    (v_source->>'officialDocumentSourceDocumentId')::uuid;
  v_document_source_sha256:=
    (v_source->>'officialDocumentSourceDocumentSha256')::char(64);
  v_document_locator_sha256:=
    (v_source->>'officialDocumentLocatorSha256')::char(64);

  v_authority_payload:=jsonb_build_object(
    'schemaVersion','organization-authority-receipt.v1',
    'authorityReceiptId',v_authority_id,'authorityVersion',1,
    'assertionId',v_assertion_id,
    'organizationKind',v_organization_kind,
    'organizationId',v_organization_id,
    'verificationMethod',v_method,'sourceId',v_source_id,
    'sourcePurpose',v_source_purpose,
    'authorityReceiptKind',v_authority_kind,
    'underlyingSourceProofDigest',v_underlying_digest,
    'sourceSnapshotDigest',v_source_snapshot_digest,
    'attestedByUserId',p_actor_id,
    'actorAssertionJti',v_actor_assertion_jti,
    'actorActionDigest',v_actor_action_digest,
    'stepUpAuthorizationId',v_step_up.id,
    'stepUpReceiptDigest',v_step_up_digest,
    'sessionId',p_session_id,'reasonDigest',v_reason_digest,
    'requestId',p_request_id,
    'idempotencyKeySha256',p_idempotency_key_sha256,
    'requestDigest',p_request_sha256,
    'attestedAt',v_now,'expiresAt',v_expires_at
  );
  v_authority_canonical:=ops.canonical_jsonb_v1(v_authority_payload);
  v_authority_digest:=encode(extensions.digest(
    v_authority_canonical,'sha256'),'hex');
  v_binding_payload:=jsonb_strip_nulls(jsonb_build_object(
    'schemaVersion','organization-official-channel-source-binding.v1',
    'organizationKind',v_organization_kind,
    'organizationId',v_organization_id,
    'verificationMethod',v_method,'sourcePurpose',v_source_purpose,
    'communicationSubjectId',v_communication_subject_id,
    'communicationSubjectOriginDigest',v_communication_subject_origin_digest,
    'communicationSubjectProfileVersion',
      v_communication_subject_profile_version,
    'communicationSubjectProfileDigest',
      v_communication_subject_profile_digest,
    'communicationEndpointId',v_communication_endpoint_id,
    'communicationEndpointVersion',v_communication_endpoint_version,
    'communicationEndpointDigest',v_communication_endpoint_digest,
    'communicationVerificationId',v_communication_verification_id,
    'officialDocumentEvidenceId',v_document_evidence_id,
    'officialDocumentEvidenceVersion',v_document_evidence_version,
    'officialDocumentContentSha256',v_document_content_sha256,
    'officialDocumentSourceDocumentId',v_document_source_id,
    'officialDocumentSourceDocumentSha256',v_document_source_sha256,
    'officialDocumentLocatorSha256',v_document_locator_sha256,
    'underlyingSourceProofDigest',v_underlying_digest,
    'organizationAuthorityReceiptKind',v_authority_kind,
    'organizationAuthorityReceiptDigest',v_authority_digest
  ));
  v_binding_canonical:=ops.canonical_jsonb_v1(v_binding_payload);
  v_binding_digest:=encode(extensions.digest(
    v_binding_canonical,'sha256'),'hex');
  v_assertion_payload:=jsonb_build_object(
    'schemaVersion','organization-official-channel-assertion.v1',
    'assertionId',v_assertion_id,'assertionVersion',1,
    'organizationKind',v_organization_kind,
    'organizationId',v_organization_id,
    'verificationMethod',v_method,'sourcePurpose',v_source_purpose,
    'organizationSourceBindingDigest',v_binding_digest,
    'independentVerifierUserId',p_actor_id,
    'verifiedAt',v_now,'expiresAt',v_expires_at
  );
  v_assertion_canonical:=ops.canonical_jsonb_v1(v_assertion_payload);
  v_assertion_digest:=encode(extensions.digest(
    v_assertion_canonical,'sha256'),'hex');
  v_registry_payload:=jsonb_build_object(
    'schemaVersion','organization-official-channel-receipt.v1',
    'assertionId',v_assertion_id,'assertionDigest',v_assertion_digest,
    'organizationSourceBindingDigest',v_binding_digest,
    'underlyingSourceProofDigest',v_underlying_digest,
    'organizationAuthorityReceiptKind',v_authority_kind,
    'organizationAuthorityReceiptDigest',v_authority_digest,
    'verifiedAt',v_now,'expiresAt',v_expires_at
  );
  v_registry_canonical:=ops.canonical_jsonb_v1(v_registry_payload);
  v_registry_digest:=encode(extensions.digest(
    v_registry_canonical,'sha256'),'hex');

  v_audit_id:=ops.append_audit_event(
    'organization-channel:'||v_assertion_id::text,
    'USER',p_actor_id::text,p_session_id,
    'organization.official_channel.attest',
    'OrganizationOfficialChannel',v_assertion_id::text,
    'responses.review','SUCCESS',NULL,p_request_id,
    jsonb_build_object(
      'organizationKind',v_organization_kind,
      'organizationId',v_organization_id,
      'verificationMethod',v_method,
      'sourceSnapshotDigest',v_source_snapshot_digest,
      'authorityReceiptDigest',v_authority_digest,
      'registryReceiptDigest',v_registry_digest,
      'reasonDigest',v_reason_digest
    )
  );
  SELECT event_hash INTO STRICT v_audit_digest
  FROM ops.audit_events WHERE id=v_audit_id;
  v_outbox_id:=ops.enqueue_outbox(
    'organization_official_channel',v_assertion_id::text,1,
    'organization.official_channel_attested.v1',
    jsonb_build_object(
      'assertionId',v_assertion_id,
      'organizationKind',v_organization_kind,
      'organizationId',v_organization_id,
      'verificationMethod',v_method,
      'authorityReceiptDigest',v_authority_digest,
      'registryReceiptDigest',v_registry_digest,
      'attestedAt',v_now,'expiresAt',v_expires_at
    ),v_now
  );

  INSERT INTO editorial.organization_official_channel_authority_receipts_v1(
    authority_receipt_id,authority_version,assertion_id,
    organization_kind,organization_id,agency_id,supplier_id,
    verification_method,source_id,communication_verification_id,
    official_document_evidence_id,source_purpose,authority_receipt_kind,
    underlying_source_proof_digest,source_snapshot_payload,
    source_snapshot_canonical,source_snapshot_digest,attested_by_user_id,
    actor_assertion_jti,actor_action_digest,step_up_authorization_id,
    step_up_receipt_digest,session_id,reason_digest,request_id,
    idempotency_key_sha256,request_digest,attested_at,expires_at,
    authority_payload,authority_canonical,authority_receipt_digest,
    audit_event_id,audit_receipt_digest,outbox_event_id
  ) VALUES(
    v_authority_id,1,v_assertion_id,v_organization_kind,v_organization_id,
    CASE WHEN v_organization_kind='AGENCY' THEN v_organization_id END,
    CASE WHEN v_organization_kind='SUPPLIER' THEN v_organization_id END,
    v_method,v_source_id,v_communication_verification_id,
    v_document_evidence_id,v_source_purpose,v_authority_kind,
    v_underlying_digest,v_source_snapshot,v_source_snapshot_canonical,
    v_source_snapshot_digest,p_actor_id,v_actor_assertion_jti,
    v_actor_action_digest,v_step_up.id,v_step_up_digest,p_session_id,
    v_reason_digest,p_request_id,p_idempotency_key_sha256,p_request_sha256,
    v_now,v_expires_at,v_authority_payload,v_authority_canonical,
    v_authority_digest,v_audit_id,v_audit_digest,v_outbox_id
  );
  INSERT INTO editorial.organization_official_channel_assertions_v1(
    assertion_id,assertion_version,organization_kind,organization_id,
    agency_id,supplier_id,verification_method,source_purpose,
    communication_subject_id,communication_subject_origin_digest,
    communication_subject_profile_version,communication_subject_profile_digest,
    communication_endpoint_id,communication_endpoint_version,
    communication_endpoint_digest,communication_verification_id,
    official_document_evidence_id,official_document_evidence_version,
    official_document_content_sha256,official_document_source_document_id,
    official_document_source_document_sha256,
    official_document_locator_sha256,underlying_source_proof_digest,
    organization_authority_receipt_kind,
    organization_authority_receipt_digest,authority_receipt_id,
    authority_source_id,organization_source_binding_payload,
    organization_source_binding_canonical,organization_source_binding_digest,
    independent_verifier_user_id,verified_at,expires_at,assertion_payload,
    assertion_canonical,assertion_digest,receipt_payload,receipt_canonical,
    receipt_digest
  ) VALUES(
    v_assertion_id,1,v_organization_kind,v_organization_id,
    CASE WHEN v_organization_kind='AGENCY' THEN v_organization_id END,
    CASE WHEN v_organization_kind='SUPPLIER' THEN v_organization_id END,
    v_method,v_source_purpose,v_communication_subject_id,
    v_communication_subject_origin_digest,
    v_communication_subject_profile_version,
    v_communication_subject_profile_digest,v_communication_endpoint_id,
    v_communication_endpoint_version,v_communication_endpoint_digest,
    v_communication_verification_id,v_document_evidence_id,
    v_document_evidence_version,v_document_content_sha256,
    v_document_source_id,v_document_source_sha256,v_document_locator_sha256,
    v_underlying_digest,v_authority_kind,v_authority_digest,v_authority_id,
    v_source_id,v_binding_payload,v_binding_canonical,v_binding_digest,
    p_actor_id,v_now,v_expires_at,v_assertion_payload,v_assertion_canonical,
    v_assertion_digest,v_registry_payload,v_registry_canonical,v_registry_digest
  );
  RETURN jsonb_build_object(
    'assertionId',v_assertion_id,'assertionVersion',1,
    'authorityReceiptId',v_authority_id,
    'authorityReceiptDigest',v_authority_digest,
    'registryReceiptDigest',v_registry_digest,
    'auditEventId',v_audit_id,'attestedAt',v_now,
    'expiresAt',v_expires_at,
    'outboxEventIds',jsonb_build_array(v_outbox_id),'replayed',false
  );
END
$attest$;
ALTER FUNCTION editorial.attest_organization_official_channel_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.attest_organization_official_channel_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.attest_organization_official_channel_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

CREATE OR REPLACE FUNCTION editorial.guard_official_channel_revocation_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp
AS $revocation_guard$
DECLARE
  v_assertion editorial.organization_official_channel_assertions_v1%ROWTYPE;
  v_authority
    editorial.organization_official_channel_authority_receipts_v1%ROWTYPE;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_step_up_payload jsonb;
  v_step_up_digest char(64);
  v_audit ops.audit_events%ROWTYPE;
  v_outbox ops.outbox%ROWTYPE;
BEGIN
  IF num_nonnulls(
       NEW.actor_assertion_jti,NEW.actor_action_digest,
       NEW.step_up_authorization_id,NEW.step_up_receipt_digest,
       NEW.session_id,NEW.request_id,NEW.idempotency_key_sha256,
       NEW.request_digest,NEW.audit_event_id,NEW.audit_receipt_digest,
       NEW.outbox_event_id
     )<>11 THEN
    RAISE EXCEPTION 'official_channel_revocation_owner_receipt_required'
      USING ERRCODE='55000';
  END IF;
  SELECT * INTO v_assertion
  FROM editorial.organization_official_channel_assertions_v1
  WHERE assertion_id=NEW.assertion_id
    AND assertion_digest=NEW.assertion_digest
    AND organization_source_binding_digest=
      NEW.organization_source_binding_digest
    AND receipt_digest=NEW.assertion_receipt_digest
  FOR SHARE;
  IF NOT FOUND OR v_assertion.authority_receipt_id IS NULL THEN
    RAISE EXCEPTION 'official_channel_revocation_assertion_unowned'
      USING ERRCODE='P0002';
  END IF;
  SELECT * INTO v_authority
  FROM editorial.organization_official_channel_authority_receipts_v1
  WHERE authority_receipt_id=v_assertion.authority_receipt_id
    AND authority_receipt_digest=
      v_assertion.organization_authority_receipt_digest
    AND assertion_id=v_assertion.assertion_id
    AND organization_kind=v_assertion.organization_kind
    AND organization_id=v_assertion.organization_id
    AND verification_method=v_assertion.verification_method
    AND source_id=v_assertion.authority_source_id
    AND expires_at=v_assertion.expires_at
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'official_channel_revocation_authority_missing'
      USING ERRCODE='P0002';
  END IF;
  SELECT * INTO v_step_up FROM ops.step_up_authorizations
  WHERE id=NEW.step_up_authorization_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'official_channel_revocation_step_up_missing'
      USING ERRCODE='P0002';
  END IF;
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
    ops.canonical_jsonb_v1(v_step_up_payload),'sha256'),'hex');
  SELECT * INTO v_audit FROM ops.audit_events
  WHERE id=NEW.audit_event_id FOR SHARE;
  SELECT * INTO v_outbox FROM ops.outbox
  WHERE id=NEW.outbox_event_id FOR SHARE;
  IF v_step_up.closed_at IS NOT NULL
     OR v_step_up.session_id<>NEW.session_id
     OR v_step_up.action_digest<>NEW.actor_action_digest
     OR v_step_up.idempotency_key_sha256<>NEW.idempotency_key_sha256
     OR v_step_up.expires_at<=NEW.revoked_at
     OR v_step_up.assertion_issue_count NOT BETWEEN 1 AND 3
     OR v_step_up.last_issued_at IS NULL
     OR v_step_up.last_issued_at>NEW.revoked_at
     OR NEW.step_up_receipt_digest<>v_step_up_digest
     OR v_audit.id IS NULL OR v_outbox.id IS NULL
     OR v_audit.event_hash<>NEW.audit_receipt_digest
     OR v_audit.actor_type<>'USER'
     OR v_audit.actor_id<>NEW.revoked_by_user_id::text
     OR v_audit.session_id<>NEW.session_id
     OR v_audit.action<>'organization.official_channel.revoke'
     OR v_audit.object_type<>'OrganizationOfficialChannel'
     OR v_audit.object_id<>NEW.assertion_id::text
     OR v_audit.capability<>'responses.review'
     OR v_audit.outcome<>'SUCCESS'
     OR v_audit.request_id<>NEW.request_id
     OR v_audit.details<>jsonb_build_object(
       'assertionId',NEW.assertion_id,
       'authorityReceiptDigest',v_authority.authority_receipt_digest,
       'revocationReceiptDigest',NEW.revocation_receipt_digest,
       'reasonCode',NEW.reason_code,
       'reasonDigest',NEW.reason_digest
     )
     OR v_outbox.aggregate_type<>'organization_official_channel'
     OR v_outbox.aggregate_id<>NEW.assertion_id::text
     OR v_outbox.aggregate_version<>2
     OR v_outbox.event_type<>'organization.official_channel_revoked.v1'
     OR v_outbox.occurred_at<>NEW.revoked_at
     OR v_outbox.payload<>jsonb_build_object(
       'revocationId',NEW.revocation_id,
       'assertionId',NEW.assertion_id,
       'revocationReceiptDigest',NEW.revocation_receipt_digest,
       'revokedAt',NEW.revoked_at
     )
     OR NOT EXISTS(
       SELECT 1 FROM ops.sessions AS session
       JOIN ops.users AS actor ON actor.id=session.user_id
       WHERE session.id=NEW.session_id
         AND session.user_id=NEW.revoked_by_user_id
         AND session.revoked_at IS NULL
         AND session.expires_at>NEW.revoked_at
         AND actor.status='ACTIVE'
     ) THEN
    RAISE EXCEPTION 'official_channel_revocation_binding_invalid'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$revocation_guard$;
ALTER FUNCTION editorial.guard_official_channel_revocation_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.guard_official_channel_revocation_v1()
  FROM PUBLIC;
CREATE TRIGGER organization_official_channel_revocation_authority_guard
  BEFORE INSERT
  ON editorial.organization_official_channel_revocation_receipts_v1
  FOR EACH ROW
  EXECUTE FUNCTION editorial.guard_official_channel_revocation_v1();

CREATE OR REPLACE FUNCTION editorial.revoke_organization_official_channel_v1(
  p_payload jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_sha256 char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp
AS $revoke$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_scope text;
  v_idempotency ops.idempotency_keys%ROWTYPE;
  v_existing
    editorial.organization_official_channel_revocation_receipts_v1%ROWTYPE;
  v_assertion editorial.organization_official_channel_assertions_v1%ROWTYPE;
  v_authority
    editorial.organization_official_channel_authority_receipts_v1%ROWTYPE;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_assertion_id uuid;
  v_actor_assertion_jti uuid;
  v_actor_assertion_request_digest char(64);
  v_actor_action_digest char(64);
  v_step_up_id uuid;
  v_reason_code text;
  v_reason_digest char(64);
  v_step_up_payload jsonb;
  v_step_up_digest char(64);
  v_revocation_id uuid:=gen_random_uuid();
  v_revocation_payload jsonb;
  v_revocation_canonical bytea;
  v_revocation_digest char(64);
  v_audit_id uuid;
  v_audit_digest char(64);
  v_outbox_id uuid;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_payload))<>11
     OR NOT p_payload ?& ARRAY[
       'assertionId','reasonCode','reason','_actorAssertionJti',
       '_actorAssertionRequestSha256',
       '_actorAssuranceLevel','_actorEffectiveCapability',
       '_actorActionDigest','_actorStepUpAuthorizationId',
       '_actorIdempotencyKeySha256','_actorRequestKeySha256'
     ]
     OR jsonb_typeof(p_payload->'assertionId')<>'string'
     OR jsonb_typeof(p_payload->'reasonCode')<>'string'
     OR jsonb_typeof(p_payload->'reason')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssertionJti')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssertionRequestSha256')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssuranceLevel')<>'string'
     OR jsonb_typeof(p_payload->'_actorEffectiveCapability')<>'string'
     OR jsonb_typeof(p_payload->'_actorActionDigest')<>'string'
     OR jsonb_typeof(p_payload->'_actorStepUpAuthorizationId')<>'string'
     OR jsonb_typeof(p_payload->'_actorIdempotencyKeySha256')<>'string'
     OR jsonb_typeof(p_payload->'_actorRequestKeySha256')<>'string'
     OR p_payload->>'_actorAssuranceLevel'<>'STEP_UP'
     OR p_payload->>'_actorEffectiveCapability'<>'responses.review'
     OR p_actor_id IS NULL
     OR p_actor_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_session_id IS NULL
     OR p_session_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_request_id IS NULL
     OR p_request_id='00000000-0000-0000-0000-000000000000'::uuid
     OR NOT ops.r6d_lower_sha256(p_idempotency_key_sha256)
     OR NOT ops.r6d_lower_sha256(p_request_sha256)
     OR NOT ops.r6d_lower_sha256(
       p_payload->>'_actorAssertionRequestSha256'
     )
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorActionDigest')
     OR NOT ops.r6d_lower_sha256(
       p_payload->>'_actorIdempotencyKeySha256'
     )
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorRequestKeySha256')
     OR p_payload->>'_actorIdempotencyKeySha256'<>
       btrim(p_idempotency_key_sha256)
     OR p_payload->>'_actorRequestKeySha256'<>
       btrim(p_idempotency_key_sha256)
     OR char_length(p_payload->>'reasonCode') NOT BETWEEN 1 AND 100
     OR btrim(p_payload->>'reasonCode')<>p_payload->>'reasonCode'
     OR p_payload->>'reasonCode' ~ '[[:cntrl:]]'
     OR char_length(p_payload->>'reason') NOT BETWEEN 1 AND 4000
     OR btrim(p_payload->>'reason')<>p_payload->>'reason'
     OR p_payload->>'reason' ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION 'official_channel_revoke_input_invalid'
      USING ERRCODE='22023';
  END IF;
  BEGIN
    v_assertion_id:=(p_payload->>'assertionId')::uuid;
    v_actor_assertion_jti:=(p_payload->>'_actorAssertionJti')::uuid;
    v_actor_assertion_request_digest:=
      (p_payload->>'_actorAssertionRequestSha256')::char(64);
    v_actor_action_digest:=(p_payload->>'_actorActionDigest')::char(64);
    v_step_up_id:=(p_payload->>'_actorStepUpAuthorizationId')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'official_channel_revoke_input_invalid'
      USING ERRCODE='22023';
  END;
  IF v_assertion_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_actor_assertion_jti=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_step_up_id='00000000-0000-0000-0000-000000000000'::uuid THEN
    RAISE EXCEPTION 'official_channel_revoke_input_invalid'
      USING ERRCODE='22023';
  END IF;

  v_scope:='control:'||p_actor_id::text||
    ':revokeOrganizationOfficialChannel';
  SELECT * INTO v_idempotency FROM ops.idempotency_keys
  WHERE scope=v_scope AND key_hash=p_idempotency_key_sha256 FOR UPDATE;
  IF NOT FOUND OR v_idempotency.expires_at<=v_now
     OR v_idempotency.request_hash<>p_request_sha256 THEN
    RAISE EXCEPTION 'official_channel_revoke_idempotency_conflict'
      USING ERRCODE='40001';
  END IF;
  PERFORM editorial.require_control_actor_assertion_v1(
    v_actor_assertion_jti,v_actor_assertion_request_digest,v_now
  );
  SELECT * INTO v_existing
  FROM editorial.organization_official_channel_revocation_receipts_v1
  WHERE idempotency_key_sha256=p_idempotency_key_sha256 FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest<>p_request_sha256
       OR num_nonnulls(
         v_idempotency.response_status,v_idempotency.response_body,
         v_idempotency.resource_type,v_idempotency.resource_id
       ) NOT IN (0,4)
       OR (v_idempotency.resource_id IS NOT NULL AND (
         v_idempotency.response_status<>200
         OR v_idempotency.resource_type<>'organization_official_channel'
         OR v_idempotency.resource_id<>v_existing.assertion_id::text
       )) THEN
      RAISE EXCEPTION 'official_channel_revoke_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN jsonb_build_object(
      'revocationId',v_existing.revocation_id,
      'assertionId',v_existing.assertion_id,
      'revocationReceiptDigest',v_existing.revocation_receipt_digest,
      'auditEventId',v_existing.audit_event_id,
      'revokedAt',v_existing.revoked_at,
      'outboxEventIds',jsonb_build_array(v_existing.outbox_event_id),
      'replayed',true
    );
  END IF;
  IF num_nonnulls(
       v_idempotency.response_status,v_idempotency.response_body,
       v_idempotency.resource_type,v_idempotency.resource_id
     )<>0 THEN
    RAISE EXCEPTION 'official_channel_revoke_idempotency_conflict'
      USING ERRCODE='40001';
  END IF;

  SELECT * INTO v_step_up FROM ops.step_up_authorizations
  WHERE id=v_step_up_id FOR UPDATE;
  IF NOT FOUND OR v_step_up.closed_at IS NOT NULL
     OR v_step_up.session_id<>p_session_id
     OR v_step_up.expires_at<=v_now
     OR v_step_up.action_digest<>v_actor_action_digest
     OR v_step_up.idempotency_key_sha256<>p_idempotency_key_sha256
     OR v_step_up.assertion_issue_count NOT BETWEEN 1 AND 3
     OR v_step_up.last_issued_at IS NULL OR v_step_up.last_issued_at>v_now
     OR v_step_up.last_issued_at>=v_step_up.expires_at
     OR v_step_up.expires_at>
       v_step_up.last_issued_at+interval '5 minutes 5 seconds'
     OR NOT EXISTS(
       SELECT 1 FROM ops.sessions AS session
       JOIN ops.users AS actor ON actor.id=session.user_id
       WHERE session.id=p_session_id AND session.user_id=p_actor_id
         AND session.revoked_at IS NULL AND session.expires_at>v_now
         AND actor.status='ACTIVE'
     ) THEN
    RAISE EXCEPTION 'official_channel_revoke_step_up_invalid'
      USING ERRCODE='23514';
  END IF;
  IF EXISTS(
       SELECT 1
       FROM editorial.organization_official_channel_authority_receipts_v1
       WHERE actor_assertion_jti=v_actor_assertion_jti
          OR step_up_authorization_id=v_step_up_id
     ) OR EXISTS(
       SELECT 1
       FROM editorial.organization_official_channel_revocation_receipts_v1
       WHERE actor_assertion_jti=v_actor_assertion_jti
          OR step_up_authorization_id=v_step_up_id
     ) THEN
    RAISE EXCEPTION 'official_channel_revoke_actor_authority_reused'
      USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_assertion
  FROM editorial.organization_official_channel_assertions_v1
  WHERE assertion_id=v_assertion_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'official_channel_revoke_assertion_missing'
      USING ERRCODE='P0002';
  END IF;
  IF v_assertion.authority_receipt_id IS NULL
     OR v_assertion.authority_source_id IS NULL
     OR v_assertion.expires_at<=v_now
     OR EXISTS(
       SELECT 1
       FROM editorial.organization_official_channel_revocation_receipts_v1
       WHERE assertion_id=v_assertion.assertion_id
     ) THEN
    RAISE EXCEPTION 'official_channel_revoke_assertion_unavailable'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO v_authority
  FROM editorial.organization_official_channel_authority_receipts_v1
  WHERE authority_receipt_id=v_assertion.authority_receipt_id
    AND authority_receipt_digest=
      v_assertion.organization_authority_receipt_digest
    AND assertion_id=v_assertion.assertion_id
    AND organization_kind=v_assertion.organization_kind
    AND organization_id=v_assertion.organization_id
    AND verification_method=v_assertion.verification_method
    AND source_id=v_assertion.authority_source_id
    AND expires_at=v_assertion.expires_at
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'official_channel_revoke_authority_missing'
      USING ERRCODE='P0002';
  END IF;

  v_reason_code:=p_payload->>'reasonCode';
  v_reason_digest:=encode(extensions.digest(
    convert_to(p_payload->>'reason','UTF8'),'sha256'),'hex');
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
    ops.canonical_jsonb_v1(v_step_up_payload),'sha256'),'hex');
  v_revocation_payload:=jsonb_build_object(
    'schemaVersion','organization-official-channel-revocation.v1',
    'revocationId',v_revocation_id,'assertionId',v_assertion.assertion_id,
    'assertionDigest',v_assertion.assertion_digest,
    'organizationSourceBindingDigest',
      v_assertion.organization_source_binding_digest,
    'assertionReceiptDigest',v_assertion.receipt_digest,
    'reasonCode',v_reason_code,'reasonDigest',v_reason_digest,
    'revokedByUserId',p_actor_id,'revokedAt',v_now
  );
  v_revocation_canonical:=ops.canonical_jsonb_v1(v_revocation_payload);
  v_revocation_digest:=encode(extensions.digest(
    v_revocation_canonical,'sha256'),'hex');
  v_audit_id:=ops.append_audit_event(
    'organization-channel:'||v_assertion.assertion_id::text,
    'USER',p_actor_id::text,p_session_id,
    'organization.official_channel.revoke',
    'OrganizationOfficialChannel',v_assertion.assertion_id::text,
    'responses.review','SUCCESS',NULL,p_request_id,
    jsonb_build_object(
      'assertionId',v_assertion.assertion_id,
      'authorityReceiptDigest',v_authority.authority_receipt_digest,
      'revocationReceiptDigest',v_revocation_digest,
      'reasonCode',v_reason_code,'reasonDigest',v_reason_digest
    )
  );
  SELECT event_hash INTO STRICT v_audit_digest
  FROM ops.audit_events WHERE id=v_audit_id;
  v_outbox_id:=ops.enqueue_outbox(
    'organization_official_channel',v_assertion.assertion_id::text,2,
    'organization.official_channel_revoked.v1',
    jsonb_build_object(
      'revocationId',v_revocation_id,
      'assertionId',v_assertion.assertion_id,
      'revocationReceiptDigest',v_revocation_digest,
      'revokedAt',v_now
    ),v_now
  );
  INSERT INTO editorial.organization_official_channel_revocation_receipts_v1(
    revocation_id,assertion_id,assertion_digest,
    organization_source_binding_digest,assertion_receipt_digest,
    reason_code,reason_digest,revoked_by_user_id,revoked_at,
    revocation_payload,revocation_canonical,revocation_receipt_digest,
    actor_assertion_jti,actor_action_digest,step_up_authorization_id,
    step_up_receipt_digest,session_id,request_id,idempotency_key_sha256,
    request_digest,audit_event_id,audit_receipt_digest,outbox_event_id
  ) VALUES(
    v_revocation_id,v_assertion.assertion_id,v_assertion.assertion_digest,
    v_assertion.organization_source_binding_digest,v_assertion.receipt_digest,
    v_reason_code,v_reason_digest,p_actor_id,v_now,v_revocation_payload,
    v_revocation_canonical,v_revocation_digest,v_actor_assertion_jti,
    v_actor_action_digest,v_step_up.id,v_step_up_digest,p_session_id,
    p_request_id,p_idempotency_key_sha256,p_request_sha256,
    v_audit_id,v_audit_digest,v_outbox_id
  );
  RETURN jsonb_build_object(
    'revocationId',v_revocation_id,
    'assertionId',v_assertion.assertion_id,
    'revocationReceiptDigest',v_revocation_digest,
    'auditEventId',v_audit_id,'revokedAt',v_now,
    'outboxEventIds',jsonb_build_array(v_outbox_id),'replayed',false
  );
END
$revoke$;
ALTER FUNCTION editorial.revoke_organization_official_channel_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.revoke_organization_official_channel_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.revoke_organization_official_channel_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- Preserve every 0038 response/case-specific current-source condition and add
-- the D2 authority receipt/snapshot gate around it. The inner validator keeps
-- the assertion row lock also used by the revocation owner.
ALTER FUNCTION editorial.require_current_official_channel_v1(
  uuid,text,uuid,uuid,uuid,uuid,timestamptz
) RENAME TO require_current_official_channel_pre_r6d39;
REVOKE ALL ON FUNCTION editorial.require_current_official_channel_pre_r6d39(
  uuid,text,uuid,uuid,uuid,uuid,timestamptz
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.require_current_official_channel_v1(
  p_assertion_id uuid,
  p_organization_kind text,
  p_organization_id uuid,
  p_response_request_id uuid,
  p_case_id uuid,
  p_identity_actor_id uuid,
  p_evaluated_at timestamptz
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,intake,core,raw,ops,extensions,pg_temp
AS $current_channel$
DECLARE
  v_registry jsonb;
  v_assertion editorial.organization_official_channel_assertions_v1%ROWTYPE;
  v_authority
    editorial.organization_official_channel_authority_receipts_v1%ROWTYPE;
  v_source jsonb;
  v_audit ops.audit_events%ROWTYPE;
  v_outbox ops.outbox%ROWTYPE;
BEGIN
  v_registry:=editorial.require_current_official_channel_pre_r6d39(
    p_assertion_id,p_organization_kind,p_organization_id,
    p_response_request_id,p_case_id,p_identity_actor_id,p_evaluated_at
  );
  SELECT * INTO v_assertion
  FROM editorial.organization_official_channel_assertions_v1
  WHERE assertion_id=p_assertion_id FOR SHARE;
  IF NOT FOUND OR v_assertion.authority_receipt_id IS NULL
     OR v_assertion.authority_source_id IS NULL THEN
    RAISE EXCEPTION 'official_channel_authority_unavailable'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO v_authority
  FROM editorial.organization_official_channel_authority_receipts_v1
  WHERE authority_receipt_id=v_assertion.authority_receipt_id
    AND authority_receipt_digest=
      v_assertion.organization_authority_receipt_digest
    AND assertion_id=v_assertion.assertion_id
    AND organization_kind=v_assertion.organization_kind
    AND organization_id=v_assertion.organization_id
    AND verification_method=v_assertion.verification_method
    AND source_id=v_assertion.authority_source_id
    AND expires_at=v_assertion.expires_at
  FOR SHARE;
  IF NOT FOUND OR v_authority.attested_by_user_id<>
       v_assertion.independent_verifier_user_id
     OR v_authority.attested_by_user_id=p_identity_actor_id
     OR v_authority.attested_at<>v_assertion.verified_at
     OR v_authority.authority_receipt_kind<>
       v_assertion.organization_authority_receipt_kind
     OR v_authority.underlying_source_proof_digest<>
       v_assertion.underlying_source_proof_digest THEN
    RAISE EXCEPTION 'official_channel_authority_unavailable'
      USING ERRCODE='23514';
  END IF;
  v_source:=editorial.resolve_official_channel_source_v1(
    v_assertion.verification_method,v_assertion.authority_source_id,
    v_assertion.organization_kind,v_assertion.organization_id,
    v_authority.attested_by_user_id,v_assertion.expires_at,p_evaluated_at
  );
  SELECT * INTO v_audit FROM ops.audit_events
  WHERE id=v_authority.audit_event_id FOR SHARE;
  SELECT * INTO v_outbox FROM ops.outbox
  WHERE id=v_authority.outbox_event_id FOR SHARE;
  IF v_source->'sourceSnapshotPayload'<>v_authority.source_snapshot_payload
     OR v_source->>'sourceSnapshotDigest'<>
       btrim(v_authority.source_snapshot_digest)
     OR v_source->>'underlyingSourceProofDigest'<>
       btrim(v_authority.underlying_source_proof_digest)
     OR v_assertion.communication_subject_id IS DISTINCT FROM
       (v_source->>'communicationSubjectId')::uuid
     OR v_assertion.communication_subject_origin_digest IS DISTINCT FROM
       (v_source->>'communicationSubjectOriginDigest')::char(64)
     OR v_assertion.communication_subject_profile_version IS DISTINCT FROM
       (v_source->>'communicationSubjectProfileVersion')::bigint
     OR v_assertion.communication_subject_profile_digest IS DISTINCT FROM
       (v_source->>'communicationSubjectProfileDigest')::char(64)
     OR v_assertion.communication_endpoint_id IS DISTINCT FROM
       (v_source->>'communicationEndpointId')::uuid
     OR v_assertion.communication_endpoint_version IS DISTINCT FROM
       (v_source->>'communicationEndpointVersion')::bigint
     OR v_assertion.communication_endpoint_digest IS DISTINCT FROM
       (v_source->>'communicationEndpointDigest')::char(64)
     OR v_assertion.communication_verification_id IS DISTINCT FROM
       (v_source->>'communicationVerificationId')::uuid
     OR v_assertion.official_document_evidence_id IS DISTINCT FROM
       (v_source->>'officialDocumentEvidenceId')::uuid
     OR v_assertion.official_document_evidence_version IS DISTINCT FROM
       (v_source->>'officialDocumentEvidenceVersion')::bigint
     OR v_assertion.official_document_content_sha256 IS DISTINCT FROM
       (v_source->>'officialDocumentContentSha256')::char(64)
     OR v_assertion.official_document_source_document_id IS DISTINCT FROM
       (v_source->>'officialDocumentSourceDocumentId')::uuid
     OR v_assertion.official_document_source_document_sha256 IS DISTINCT FROM
       (v_source->>'officialDocumentSourceDocumentSha256')::char(64)
     OR v_assertion.official_document_locator_sha256 IS DISTINCT FROM
       (v_source->>'officialDocumentLocatorSha256')::char(64)
     OR v_audit.id IS NULL OR v_outbox.id IS NULL
     OR v_audit.event_hash<>v_authority.audit_receipt_digest
     OR v_audit.action<>'organization.official_channel.attest'
     OR v_audit.object_id<>v_assertion.assertion_id::text
     OR v_audit.capability<>'responses.review'
     OR v_audit.outcome<>'SUCCESS'
     OR v_outbox.aggregate_type<>'organization_official_channel'
     OR v_outbox.aggregate_id<>v_assertion.assertion_id::text
     OR v_outbox.aggregate_version<>1
     OR v_outbox.event_type<>'organization.official_channel_attested.v1'
     OR v_outbox.payload<>jsonb_build_object(
       'assertionId',v_assertion.assertion_id,
       'organizationKind',v_assertion.organization_kind,
       'organizationId',v_assertion.organization_id,
       'verificationMethod',v_assertion.verification_method,
       'authorityReceiptDigest',v_authority.authority_receipt_digest,
       'registryReceiptDigest',v_assertion.receipt_digest,
       'attestedAt',v_assertion.verified_at,
       'expiresAt',v_assertion.expires_at
     ) THEN
    RAISE EXCEPTION 'official_channel_authority_not_current'
      USING ERRCODE='23514';
  END IF;
  RETURN v_registry;
END
$current_channel$;
ALTER FUNCTION editorial.require_current_official_channel_v1(
  uuid,text,uuid,uuid,uuid,uuid,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.require_current_official_channel_v1(
  uuid,text,uuid,uuid,uuid,uuid,timestamptz
) FROM PUBLIC;

-- Runtime roles own no table DML. SECURITY DEFINER owners above are the only
-- mutation surface; only the auditor can inspect immutable authority receipts.
REVOKE ALL ON editorial.organization_official_channel_authority_receipts_v1
  FROM gurine_control_api,gurine_submission_api,gurine_workflow_worker,
    gurine_analysis_worker,gurine_public_projector,gurine_notification_worker;
REVOKE ALL ON editorial.organization_official_channel_assertions_v1
  FROM gurine_control_api,gurine_submission_api,gurine_workflow_worker,
    gurine_analysis_worker,gurine_public_projector,gurine_notification_worker;
REVOKE ALL ON editorial.organization_official_channel_revocation_receipts_v1
  FROM gurine_control_api,gurine_submission_api,gurine_workflow_worker,
    gurine_analysis_worker,gurine_public_projector,gurine_notification_worker;
ALTER FUNCTION editorial.guard_official_channel_authority_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.guard_official_channel_authority_v1()
  FROM PUBLIC;
CREATE TRIGGER organization_official_channel_assertion_authority_guard
  BEFORE INSERT ON editorial.organization_official_channel_assertions_v1
  FOR EACH ROW EXECUTE FUNCTION editorial.guard_official_channel_authority_v1();

-- Existing 0038 rows have none of these fields and remain staged legacy.
-- Resolves a method-specific source into one server-canonical, payload-free
-- authority snapshot. The same resolver is reused at insert and consumption.
CREATE OR REPLACE FUNCTION editorial.resolve_official_channel_source_v1(
  p_verification_method text,
  p_source_id uuid,
  p_organization_kind text,
  p_organization_id uuid,
  p_authority_actor_id uuid,
  p_authority_expires_at timestamptz,
  p_evaluated_at timestamptz
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,intake,core,raw,ops,extensions,pg_temp
AS $resolve_source$
DECLARE
  v_verification intake.communication_endpoint_verifications%ROWTYPE;
  v_subject intake.communication_subjects%ROWTYPE;
  v_endpoint intake.communication_endpoints%ROWTYPE;
  v_link intake.communication_endpoint_link_events%ROWTYPE;
  v_response_request editorial.response_requests%ROWTYPE;
  v_sent editorial.response_request_sent_receipts%ROWTYPE;
  v_evidence editorial.evidence%ROWTYPE;
  v_document raw.source_documents%ROWTYPE;
  v_source_purpose text;
  v_authority_kind text;
  v_underlying_digest char(64);
  v_snapshot jsonb;
  v_snapshot_canonical bytea;
  v_snapshot_digest char(64);
BEGIN
  IF p_verification_method
       NOT IN ('OFFICIAL_DOMAIN_EMAIL','OFFICIAL_DOCUMENT')
     OR p_source_id IS NULL
     OR p_source_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_organization_kind NOT IN ('AGENCY','SUPPLIER')
     OR p_organization_id IS NULL
     OR p_organization_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_authority_actor_id IS NULL
     OR p_authority_actor_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR p_authority_expires_at IS NULL
     OR NOT isfinite(p_authority_expires_at)
     OR p_evaluated_at IS NULL OR NOT isfinite(p_evaluated_at)
     OR p_authority_expires_at<=p_evaluated_at THEN
    RAISE EXCEPTION 'official_channel_source_scope_invalid'
      USING ERRCODE='22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'official-channel-source:'||p_verification_method||':'||p_source_id::text,0
  ));
  IF p_organization_kind='AGENCY' THEN
    PERFORM 1 FROM core.agencies
    WHERE id=p_organization_id AND active FOR SHARE;
  ELSE
    PERFORM 1 FROM core.suppliers WHERE id=p_organization_id FOR SHARE;
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'official_channel_source_organization_missing'
      USING ERRCODE='P0002';
  END IF;

  IF p_verification_method='OFFICIAL_DOMAIN_EMAIL' THEN
    SELECT * INTO v_verification
    FROM intake.communication_endpoint_verifications
    WHERE id=p_source_id FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'official_channel_email_verification_missing'
        USING ERRCODE='P0002';
    END IF;
    SELECT * INTO v_subject FROM intake.communication_subjects
    WHERE id=v_verification.subject_id
      AND origin_binding_digest=v_verification.subject_origin_binding_digest
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'official_channel_email_subject_missing'
        USING ERRCODE='P0002';
    END IF;
    SELECT * INTO v_endpoint FROM intake.communication_endpoints
    WHERE id=v_verification.endpoint_id
      AND subject_id=v_verification.subject_id
      AND version=v_verification.endpoint_version
      AND endpoint_digest=v_verification.endpoint_snapshot_digest
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'official_channel_email_endpoint_missing'
        USING ERRCODE='P0002';
    END IF;
    SELECT * INTO v_link
    FROM intake.communication_endpoint_link_events AS link
    WHERE link.endpoint_id=v_endpoint.id
    ORDER BY link.endpoint_sequence DESC LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'official_channel_email_link_missing'
        USING ERRCODE='P0002';
    END IF;
    SELECT * INTO v_response_request FROM editorial.response_requests
    WHERE id=v_subject.origin_object_id FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'official_channel_email_response_request_missing'
        USING ERRCODE='P0002';
    END IF;
    SELECT * INTO v_sent FROM editorial.response_request_sent_receipts
    WHERE response_request_id=v_response_request.id FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'official_channel_email_dispatch_missing'
        USING ERRCODE='P0002';
    END IF;

    IF v_verification.state<>'VERIFIED'
       OR v_verification.challenge_kind<>'EMAIL_LINK'
       OR v_verification.verified_at IS NULL
       OR v_verification.verified_at>p_evaluated_at
       OR v_verification.consumed_at IS NULL
       OR v_verification.consumed_at>p_evaluated_at
       OR v_verification.issued_at>v_verification.verified_at
       OR v_verification.expires_at<=p_evaluated_at
       OR p_authority_expires_at>v_verification.expires_at
       OR NOT ops.r6d_lower_sha256(v_verification.proof_digest)
       OR NOT ops.r6d_lower_sha256(v_verification.receipt_digest)
       OR v_subject.status<>'ACTIVE' OR v_subject.revoked_at IS NOT NULL
       OR v_subject.origin_object_type<>'RESPONSE_REQUEST'
       OR v_subject.origin_object_version<>v_sent.request_version
       OR v_subject.origin_binding_digest<>
         v_sent.response_request_binding_digest
       OR v_endpoint.channel<>'SMTP_EMAIL' OR v_endpoint.state<>'ACTIVE'
       OR v_endpoint.revoked_at IS NOT NULL
       OR v_endpoint.verified_at IS NULL
       OR v_endpoint.verified_at>p_evaluated_at
       OR v_link.subject_id<>v_subject.id
       OR v_link.subject_origin_binding_digest<>
         v_subject.origin_binding_digest
       OR v_link.profile_version<>v_subject.profile_version
       OR v_link.endpoint_version<>v_endpoint.version
       OR v_link.endpoint_snapshot_digest<>v_endpoint.endpoint_digest
       OR v_link.channel<>'SMTP_EMAIL' OR v_link.state<>'ACTIVE'
       OR v_link.change_kind NOT IN ('VERIFIED','SUPPRESSION_RELEASED')
       OR v_link.verification_id IS DISTINCT FROM v_verification.id
       OR v_response_request.party_type<>p_organization_kind
       OR v_response_request.party_entity_id<>p_organization_id
       OR v_response_request.created_by=p_authority_actor_id
       OR NOT EXISTS(
         SELECT 1 FROM ops.users AS producer
         WHERE producer.id=v_response_request.created_by
           AND producer.status='ACTIVE'
       )
       OR v_sent.endpoint_id<>v_endpoint.id
       OR v_sent.endpoint_version<>v_endpoint.version
       OR v_sent.endpoint_snapshot_digest<>v_endpoint.endpoint_digest
       OR v_sent.channel<>'SMTP_EMAIL' OR v_sent.state<>'SENT' THEN
      RAISE EXCEPTION 'official_channel_email_source_not_current'
        USING ERRCODE='23514';
    END IF;
    v_source_purpose:='OFFICIAL_DOMAIN_CONTROL';
    v_authority_kind:='ORGANIZATION_DOMAIN_CONTROL';
    v_underlying_digest:=v_verification.receipt_digest;
    v_snapshot:=jsonb_build_object(
      'schemaVersion','organization-authority-email-source.v1',
      'organizationKind',p_organization_kind,
      'organizationId',p_organization_id,
      'responseRequestId',v_response_request.id,
      'responseRequestProducerUserId',v_response_request.created_by,
      'responseRequestBindingDigest',v_sent.response_request_binding_digest,
      'responseRequestSentReceiptId',v_sent.id,
      'responseRequestSentReceiptDigest',v_sent.receipt_digest,
      'communicationSubjectId',v_subject.id,
      'communicationSubjectOriginDigest',v_subject.origin_binding_digest,
      'communicationSubjectProfileVersion',v_subject.profile_version,
      'communicationSubjectProfileDigest',v_subject.profile_digest,
      'communicationEndpointId',v_endpoint.id,
      'communicationEndpointVersion',v_endpoint.version,
      'communicationEndpointDigest',v_endpoint.endpoint_digest,
      'communicationLinkEventId',v_link.id,
      'communicationLinkEventDigest',v_link.event_digest,
      'communicationVerificationId',v_verification.id,
      'communicationVerificationVersion',v_verification.version,
      'communicationVerificationProofDigest',v_verification.proof_digest,
      'communicationVerificationReceiptDigest',v_verification.receipt_digest,
      'communicationVerificationExpiresAt',v_verification.expires_at
    );
  ELSE
    SELECT * INTO v_evidence FROM editorial.evidence
    WHERE id=p_source_id FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'official_channel_document_evidence_missing'
        USING ERRCODE='P0002';
    END IF;
    SELECT * INTO v_document FROM raw.source_documents
    WHERE id=v_evidence.source_document_id FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'official_channel_document_source_missing'
        USING ERRCODE='P0002';
    END IF;
    IF v_evidence.verification_status<>'VERIFIED'
       OR v_evidence.classification<>'PUBLIC'
       OR v_evidence.verified_by IS NULL
       OR v_evidence.verified_by=p_authority_actor_id
       OR v_evidence.verified_at IS NULL
       OR v_evidence.verified_at>p_evaluated_at
       OR NULLIF(btrim(v_evidence.source_locator),'') IS NULL
       OR NOT ops.r6d_lower_sha256(v_evidence.content_sha256)
       OR v_document.status NOT IN ('FETCHED','PARSED')
       OR v_document.record_status<>'CURRENT'
       OR NOT ops.r6d_lower_sha256(v_document.content_sha256)
       OR NOT EXISTS(
         SELECT 1 FROM ops.users AS verifier
         WHERE verifier.id=v_evidence.verified_by
           AND verifier.status='ACTIVE'
       ) THEN
      RAISE EXCEPTION 'official_channel_document_source_not_current'
        USING ERRCODE='23514';
    END IF;
    v_source_purpose:='OFFICIAL_REPRESENTATION';
    v_authority_kind:='OFFICIAL_REPRESENTATION_BINDING';
    v_underlying_digest:=v_evidence.content_sha256;
    v_snapshot:=jsonb_build_object(
      'schemaVersion','organization-authority-document-source.v1',
      'organizationKind',p_organization_kind,
      'organizationId',p_organization_id,
      'officialDocumentEvidenceId',v_evidence.id,
      'officialDocumentEvidenceVersion',v_evidence.version,
      'officialDocumentCaseId',v_evidence.case_id,
      'officialDocumentContentSha256',v_evidence.content_sha256,
      'officialDocumentVerifierUserId',v_evidence.verified_by,
      'officialDocumentVerifiedAt',v_evidence.verified_at,
      'officialDocumentSourceDocumentId',v_document.id,
      'officialDocumentSourceDocumentSha256',v_document.content_sha256,
      'officialDocumentLocatorSha256',encode(extensions.digest(
        convert_to(v_evidence.source_locator,'UTF8'),'sha256'),'hex')
    );
  END IF;

  v_snapshot_canonical:=ops.canonical_jsonb_v1(v_snapshot);
  v_snapshot_digest:=encode(extensions.digest(
    v_snapshot_canonical,'sha256'),'hex');
  RETURN jsonb_build_object(
    'sourcePurpose',v_source_purpose,
    'authorityReceiptKind',v_authority_kind,
    'underlyingSourceProofDigest',v_underlying_digest,
    'sourceSnapshotPayload',v_snapshot,
    'sourceSnapshotDigest',v_snapshot_digest,
    'communicationSubjectId',v_subject.id,
    'communicationSubjectOriginDigest',v_subject.origin_binding_digest,
    'communicationSubjectProfileVersion',v_subject.profile_version,
    'communicationSubjectProfileDigest',v_subject.profile_digest,
    'communicationEndpointId',v_endpoint.id,
    'communicationEndpointVersion',v_endpoint.version,
    'communicationEndpointDigest',v_endpoint.endpoint_digest,
    'communicationVerificationId',v_verification.id,
    'officialDocumentEvidenceId',v_evidence.id,
    'officialDocumentEvidenceVersion',v_evidence.version,
    'officialDocumentContentSha256',v_evidence.content_sha256,
    'officialDocumentSourceDocumentId',v_document.id,
    'officialDocumentSourceDocumentSha256',v_document.content_sha256,
    'officialDocumentLocatorSha256',CASE
      WHEN p_verification_method='OFFICIAL_DOCUMENT' THEN
        encode(extensions.digest(
          convert_to(v_evidence.source_locator,'UTF8'),'sha256'),'hex')
      ELSE NULL END
  );
END
$resolve_source$;
ALTER FUNCTION editorial.resolve_official_channel_source_v1(
  text,uuid,text,uuid,uuid,timestamptz,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.resolve_official_channel_source_v1(
  text,uuid,text,uuid,uuid,timestamptz,timestamptz
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION
  editorial.guard_organization_official_channel_authority_receipt_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,editorial,intake,core,raw,ops,extensions,pg_temp
AS $authority_guard$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_source jsonb;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_step_up_payload jsonb;
  v_step_up_digest char(64);
  v_audit ops.audit_events%ROWTYPE;
  v_outbox ops.outbox%ROWTYPE;
  v_registry_digest text;
BEGIN
  v_source:=editorial.resolve_official_channel_source_v1(
    NEW.verification_method,NEW.source_id,NEW.organization_kind,
    NEW.organization_id,NEW.attested_by_user_id,NEW.expires_at,v_now
  );
  SELECT * INTO v_step_up FROM ops.step_up_authorizations
  WHERE id=NEW.step_up_authorization_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'organization_authority_step_up_missing'
      USING ERRCODE='P0002';
  END IF;
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
    ops.canonical_jsonb_v1(v_step_up_payload),'sha256'),'hex');
  SELECT * INTO v_audit FROM ops.audit_events
  WHERE id=NEW.audit_event_id FOR SHARE;
  SELECT * INTO v_outbox FROM ops.outbox
  WHERE id=NEW.outbox_event_id FOR SHARE;
  IF v_audit.id IS NULL OR v_outbox.id IS NULL THEN
    RAISE EXCEPTION 'organization_authority_audit_or_outbox_missing'
      USING ERRCODE='P0002';
  END IF;
  v_registry_digest:=v_outbox.payload->>'registryReceiptDigest';
  IF v_source->'sourceSnapshotPayload'<>NEW.source_snapshot_payload
     OR v_source->>'sourceSnapshotDigest'<>btrim(NEW.source_snapshot_digest)
     OR v_source->>'underlyingSourceProofDigest'<>
       btrim(NEW.underlying_source_proof_digest)
     OR v_source->>'sourcePurpose'<>NEW.source_purpose
     OR v_source->>'authorityReceiptKind'<>NEW.authority_receipt_kind
     OR NEW.communication_verification_id IS DISTINCT FROM
       (v_source->>'communicationVerificationId')::uuid
     OR NEW.official_document_evidence_id IS DISTINCT FROM
       (v_source->>'officialDocumentEvidenceId')::uuid
     OR v_step_up.closed_at IS NOT NULL
     OR v_step_up.session_id<>NEW.session_id
     OR v_step_up.action_digest<>NEW.actor_action_digest
     OR v_step_up.idempotency_key_sha256<>NEW.idempotency_key_sha256
     OR v_step_up.expires_at<=NEW.attested_at
     OR v_step_up.assertion_issue_count NOT BETWEEN 1 AND 3
     OR v_step_up.last_issued_at IS NULL
     OR v_step_up.last_issued_at>NEW.attested_at
     OR NEW.step_up_receipt_digest IS DISTINCT FROM v_step_up_digest
     OR NOT EXISTS(
       SELECT 1 FROM ops.sessions AS session
       JOIN ops.users AS actor ON actor.id=session.user_id
       WHERE session.id=NEW.session_id
         AND session.user_id=NEW.attested_by_user_id
         AND session.revoked_at IS NULL
         AND session.expires_at>NEW.attested_at
         AND actor.status='ACTIVE'
     )
     OR v_audit.event_hash<>NEW.audit_receipt_digest
     OR v_audit.actor_type<>'USER'
     OR v_audit.actor_id<>NEW.attested_by_user_id::text
     OR v_audit.session_id<>NEW.session_id
     OR v_audit.action<>'organization.official_channel.attest'
     OR v_audit.object_type<>'OrganizationOfficialChannel'
     OR v_audit.object_id<>NEW.assertion_id::text
     OR v_audit.capability<>'responses.review'
     OR v_audit.outcome<>'SUCCESS'
     OR v_audit.request_id<>NEW.request_id
     OR v_outbox.aggregate_type<>'organization_official_channel'
     OR v_outbox.aggregate_id<>NEW.assertion_id::text
     OR v_outbox.aggregate_version<>1
     OR v_outbox.event_type<>'organization.official_channel_attested.v1'
     OR v_outbox.occurred_at<>NEW.attested_at
     OR NOT ops.r6d_lower_sha256(v_registry_digest)
     OR v_outbox.payload<>jsonb_build_object(
       'assertionId',NEW.assertion_id,
       'organizationKind',NEW.organization_kind,
       'organizationId',NEW.organization_id,
       'verificationMethod',NEW.verification_method,
       'authorityReceiptDigest',NEW.authority_receipt_digest,
       'registryReceiptDigest',v_registry_digest,
       'attestedAt',NEW.attested_at,
       'expiresAt',NEW.expires_at
     )
     OR v_audit.details<>jsonb_build_object(
       'organizationKind',NEW.organization_kind,
       'organizationId',NEW.organization_id,
       'verificationMethod',NEW.verification_method,
       'sourceSnapshotDigest',NEW.source_snapshot_digest,
       'authorityReceiptDigest',NEW.authority_receipt_digest,
       'registryReceiptDigest',v_registry_digest,
       'reasonDigest',NEW.reason_digest
     ) THEN
    RAISE EXCEPTION 'organization_authority_receipt_binding_invalid'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$authority_guard$;
ALTER FUNCTION
  editorial.guard_organization_official_channel_authority_receipt_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  editorial.guard_organization_official_channel_authority_receipt_v1()
  FROM PUBLIC;
CREATE TRIGGER organization_official_channel_authority_receipts_v1_binding_guard
  BEFORE INSERT ON editorial.organization_official_channel_authority_receipts_v1
  FOR EACH ROW
  EXECUTE FUNCTION
    editorial.guard_organization_official_channel_authority_receipt_v1();

CREATE OR REPLACE FUNCTION editorial.guard_official_channel_authority_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,editorial,intake,core,raw,ops,extensions,pg_temp
AS $assertion_authority_guard$
DECLARE
  v_authority
    editorial.organization_official_channel_authority_receipts_v1%ROWTYPE;
  v_source jsonb;
  v_audit ops.audit_events%ROWTYPE;
  v_outbox ops.outbox%ROWTYPE;
BEGIN
  IF NEW.authority_receipt_id IS NULL OR NEW.authority_source_id IS NULL
     OR NEW.authority_source_id IS DISTINCT FROM COALESCE(
       NEW.communication_verification_id,
       NEW.official_document_evidence_id
     ) THEN
    RAISE EXCEPTION 'official_channel_authority_receipt_required'
      USING ERRCODE='55000';
  END IF;
  SELECT * INTO v_authority
  FROM editorial.organization_official_channel_authority_receipts_v1 AS authority
  WHERE authority.authority_receipt_id=NEW.authority_receipt_id
    AND authority.authority_receipt_digest=
      NEW.organization_authority_receipt_digest
    AND authority.assertion_id=NEW.assertion_id
    AND authority.organization_kind=NEW.organization_kind
    AND authority.organization_id=NEW.organization_id
    AND authority.verification_method=NEW.verification_method
    AND authority.source_id=NEW.authority_source_id
    AND authority.expires_at=NEW.expires_at
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'official_channel_authority_receipt_missing'
      USING ERRCODE='P0002';
  END IF;
  v_source:=editorial.resolve_official_channel_source_v1(
    NEW.verification_method,NEW.authority_source_id,NEW.organization_kind,
    NEW.organization_id,v_authority.attested_by_user_id,
    NEW.expires_at,clock_timestamp()
  );
  SELECT * INTO v_audit FROM ops.audit_events
  WHERE id=v_authority.audit_event_id FOR SHARE;
  SELECT * INTO v_outbox FROM ops.outbox
  WHERE id=v_authority.outbox_event_id FOR SHARE;
  IF NEW.independent_verifier_user_id<>v_authority.attested_by_user_id
     OR NEW.verified_at<>v_authority.attested_at
     OR NEW.organization_authority_receipt_kind<>
       v_authority.authority_receipt_kind
     OR NEW.underlying_source_proof_digest<>
       v_authority.underlying_source_proof_digest
     OR NEW.communication_subject_id IS DISTINCT FROM
       (v_source->>'communicationSubjectId')::uuid
     OR NEW.communication_subject_origin_digest IS DISTINCT FROM
       (v_source->>'communicationSubjectOriginDigest')::char(64)
     OR NEW.communication_subject_profile_version IS DISTINCT FROM
       (v_source->>'communicationSubjectProfileVersion')::bigint
     OR NEW.communication_subject_profile_digest IS DISTINCT FROM
       (v_source->>'communicationSubjectProfileDigest')::char(64)
     OR NEW.communication_endpoint_id IS DISTINCT FROM
       (v_source->>'communicationEndpointId')::uuid
     OR NEW.communication_endpoint_version IS DISTINCT FROM
       (v_source->>'communicationEndpointVersion')::bigint
     OR NEW.communication_endpoint_digest IS DISTINCT FROM
       (v_source->>'communicationEndpointDigest')::char(64)
     OR NEW.communication_verification_id IS DISTINCT FROM
       (v_source->>'communicationVerificationId')::uuid
     OR NEW.official_document_evidence_id IS DISTINCT FROM
       (v_source->>'officialDocumentEvidenceId')::uuid
     OR NEW.official_document_evidence_version IS DISTINCT FROM
       (v_source->>'officialDocumentEvidenceVersion')::bigint
     OR NEW.official_document_content_sha256 IS DISTINCT FROM
       (v_source->>'officialDocumentContentSha256')::char(64)
     OR NEW.official_document_source_document_id IS DISTINCT FROM
       (v_source->>'officialDocumentSourceDocumentId')::uuid
     OR NEW.official_document_source_document_sha256 IS DISTINCT FROM
       (v_source->>'officialDocumentSourceDocumentSha256')::char(64)
     OR NEW.official_document_locator_sha256 IS DISTINCT FROM
       (v_source->>'officialDocumentLocatorSha256')::char(64)
     OR v_audit.id IS NULL OR v_outbox.id IS NULL
     OR v_outbox.payload<>jsonb_build_object(
       'assertionId',NEW.assertion_id,
       'organizationKind',NEW.organization_kind,
       'organizationId',NEW.organization_id,
       'verificationMethod',NEW.verification_method,
       'authorityReceiptDigest',NEW.organization_authority_receipt_digest,
       'registryReceiptDigest',NEW.receipt_digest,
       'attestedAt',NEW.verified_at,
       'expiresAt',NEW.expires_at
     )
     OR v_audit.details<>jsonb_build_object(
       'organizationKind',NEW.organization_kind,
       'organizationId',NEW.organization_id,
       'verificationMethod',NEW.verification_method,
       'sourceSnapshotDigest',v_authority.source_snapshot_digest,
       'authorityReceiptDigest',NEW.organization_authority_receipt_digest,
       'registryReceiptDigest',NEW.receipt_digest,
       'reasonDigest',v_authority.reason_digest
     ) THEN
    RAISE EXCEPTION 'official_channel_authority_binding_invalid'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$assertion_authority_guard$;

-- R6d D3 privacy authority and execution closure.
--
-- Integration contract: append this forward-only snippet to migration 0039.
-- BEGIN/COMMIT are owned by the migration file.  No runtime policy row is
-- seeded here.  Every owner below is fail-closed when its approved calendar,
-- record-class schedule, source proof, scope inventory, or legal-hold
-- authority is absent or stale.

-- The producer-less document challenge is not an accepted value.  The staged
-- NOT VALID constraint preserves unverifiable legacy rows while rejecting the
-- value for every new or changed row.  A future document-proof operation needs
-- its own producer and immutable same-subject/exact-scope receipt before this
-- set can be widened and the legacy constraint can be validated.
ALTER TABLE ops.privacy_requests_v2
  ADD CONSTRAINT privacy_requests_v2_identity_proof_kind_v3_ck
  CHECK(identity_proof_kind IN ('RESPONSE_RECEIPT','VERIFIED_ENDPOINT'))
  NOT VALID;
-- Deliberately do not VALIDATE here.  PostgreSQL still enforces the constraint
-- for every new/changed row, while an old document-kind row remains staged and
-- cannot acquire the new proof authority receipt.  Upgrade must not erase or
-- reinterpret historical intake merely to close the success path.

CREATE TABLE ops.privacy_identity_proof_authority_receipts_v1 (
  identity_proof_receipt_id uuid PRIMARY KEY,
  privacy_request_id uuid NOT NULL UNIQUE
    REFERENCES ops.privacy_requests_v2(id) ON DELETE RESTRICT,
  proof_kind text NOT NULL,
  source_proof_id uuid NOT NULL,
  source_subject_id uuid,
  source_subject_origin_digest char(64),
  source_endpoint_id uuid,
  source_endpoint_version bigint,
  source_endpoint_digest char(64),
  source_response_receipt_id uuid
    REFERENCES intake.response_submission_receipts_v3(receipt_id)
    ON DELETE RESTRICT,
  source_endpoint_verification_id uuid
    REFERENCES intake.communication_endpoint_verifications(id)
    ON DELETE RESTRICT,
  source_proof_digest char(64) NOT NULL,
  source_current_binding_digest char(64) NOT NULL,
  subject_proof_hash char(64) NOT NULL,
  subject_binding_digest char(64) NOT NULL,
  exact_scope_digest char(64) NOT NULL,
  request_create_receipt_digest char(64) NOT NULL,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL,
  CONSTRAINT privacy_identity_proof_authority_receipt_binding_uq
    UNIQUE(identity_proof_receipt_id,receipt_digest),
  CONSTRAINT privacy_identity_proof_authority_consumption_binding_uq
    UNIQUE(identity_proof_receipt_id,receipt_digest,privacy_request_id),
  CONSTRAINT privacy_identity_proof_authority_source_uq
    UNIQUE(proof_kind,source_proof_id,privacy_request_id),
  CONSTRAINT privacy_identity_proof_authority_shape_ck CHECK(
    proof_kind IN ('RESPONSE_RECEIPT','VERIFIED_ENDPOINT')
    AND source_proof_id<>'00000000-0000-0000-0000-000000000000'::uuid
    AND (
      proof_kind='RESPONSE_RECEIPT'
      AND source_response_receipt_id=source_proof_id
      AND source_endpoint_verification_id IS NULL
      OR proof_kind='VERIFIED_ENDPOINT'
      AND source_endpoint_verification_id=source_proof_id
      AND source_response_receipt_id IS NULL
    )
    AND num_nonnulls(
      source_subject_id,source_subject_origin_digest,
      source_endpoint_id,source_endpoint_version,source_endpoint_digest
    )=5
    AND source_endpoint_version>0
    AND ops.r6d_lower_sha256(source_proof_digest)
    AND ops.r6d_lower_sha256(source_current_binding_digest)
    AND ops.r6d_lower_sha256(subject_proof_hash)
    AND ops.r6d_lower_sha256(subject_binding_digest)
    AND ops.r6d_lower_sha256(exact_scope_digest)
    AND ops.r6d_lower_sha256(request_create_receipt_digest)
    AND (
      source_subject_origin_digest IS NULL
      OR ops.r6d_lower_sha256(source_subject_origin_digest)
    )
    AND (
      source_endpoint_digest IS NULL
      OR ops.r6d_lower_sha256(source_endpoint_digest)
    )
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(
      extensions.digest(receipt_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE ops.privacy_identity_proof_authority_receipts_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_identity_proof_authority_receipts_v1 FROM PUBLIC;
GRANT SELECT ON ops.privacy_identity_proof_authority_receipts_v1
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER privacy_identity_proof_authority_receipts_v1_immutable
  BEFORE UPDATE OR DELETE
  ON ops.privacy_identity_proof_authority_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE TABLE ops.privacy_request_scope_inventories_v1 (
  scope_inventory_id uuid PRIMARY KEY,
  privacy_request_id uuid NOT NULL UNIQUE
    REFERENCES ops.privacy_requests_v2(id) ON DELETE RESTRICT,
  scope_kind text NOT NULL,
  date_from date,
  date_to date,
  include_derivatives boolean NOT NULL,
  include_backups boolean NOT NULL,
  object_item_count integer NOT NULL,
  object_item_set_digest char(64) NOT NULL,
  scope_digest char(64) NOT NULL,
  subject_scope_digest char(64) NOT NULL,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL,
  CONSTRAINT privacy_request_scope_inventories_v1_shape_ck CHECK(
    scope_kind IN (
      'ALL_VERIFIED_SUBJECT_DATA','OBJECT_SET','DATE_RANGE'
    )
    AND object_item_count BETWEEN 0 AND 1000
    AND (
      scope_kind='ALL_VERIFIED_SUBJECT_DATA'
      AND object_item_count=0 AND date_from IS NULL AND date_to IS NULL
      OR scope_kind='OBJECT_SET'
      AND object_item_count BETWEEN 1 AND 1000
      AND date_from IS NULL AND date_to IS NULL
      OR scope_kind='DATE_RANGE'
      AND object_item_count=0 AND date_from IS NOT NULL
      AND date_to IS NOT NULL AND date_from<=date_to
    )
    AND ops.r6d_lower_sha256(object_item_set_digest)
    AND ops.r6d_lower_sha256(scope_digest)
    AND ops.r6d_lower_sha256(subject_scope_digest)
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(
      extensions.digest(receipt_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE ops.privacy_request_scope_inventories_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_request_scope_inventories_v1 FROM PUBLIC;
GRANT SELECT ON ops.privacy_request_scope_inventories_v1
  TO gurine_control_api,gurine_workflow_worker,gurine_auditor;
CREATE TRIGGER privacy_request_scope_inventories_v1_immutable
  BEFORE UPDATE OR DELETE ON ops.privacy_request_scope_inventories_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE TABLE ops.privacy_request_scope_inventory_items_v1 (
  scope_inventory_id uuid NOT NULL
    REFERENCES ops.privacy_request_scope_inventories_v1(scope_inventory_id)
    ON DELETE RESTRICT,
  item_ordinal integer NOT NULL,
  privacy_request_id uuid NOT NULL
    REFERENCES ops.privacy_requests_v2(id) ON DELETE RESTRICT,
  object_kind text NOT NULL,
  object_id uuid NOT NULL,
  item_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL,
  PRIMARY KEY(scope_inventory_id,item_ordinal),
  UNIQUE(scope_inventory_id,object_kind,object_id),
  UNIQUE(privacy_request_id,object_kind,object_id),
  CONSTRAINT privacy_request_scope_inventory_items_v1_shape_ck CHECK(
    item_ordinal BETWEEN 1 AND 1000
    AND object_kind IN (
      'RESPONSE','CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT',
      'PUBLICATION','EVIDENCE','AUDIT_SUBJECT_RECORD'
    )
    AND object_id<>'00000000-0000-0000-0000-000000000000'::uuid
    AND ops.r6d_lower_sha256(item_digest)
  )
);
ALTER TABLE ops.privacy_request_scope_inventory_items_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_request_scope_inventory_items_v1 FROM PUBLIC;
GRANT SELECT ON ops.privacy_request_scope_inventory_items_v1
  TO gurine_control_api,gurine_workflow_worker,gurine_auditor;
CREATE TRIGGER privacy_request_scope_inventory_items_v1_immutable
  BEFORE UPDATE OR DELETE ON ops.privacy_request_scope_inventory_items_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE TABLE ops.privacy_identity_proof_consumption_receipts_v1 (
  consumption_receipt_id uuid PRIMARY KEY,
  identity_proof_receipt_id uuid NOT NULL UNIQUE,
  identity_proof_receipt_digest char(64) NOT NULL,
  privacy_request_id uuid NOT NULL UNIQUE
    REFERENCES ops.privacy_requests_v2(id) ON DELETE RESTRICT,
  subject_proof_hash char(64) NOT NULL,
  exact_scope_digest char(64) NOT NULL,
  transition_receipt_id uuid NOT NULL UNIQUE,
  actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  consumed_at timestamptz NOT NULL,
  CONSTRAINT privacy_identity_proof_consumption_authority_fk FOREIGN KEY(
    identity_proof_receipt_id,identity_proof_receipt_digest,
    privacy_request_id
  ) REFERENCES ops.privacy_identity_proof_authority_receipts_v1(
    identity_proof_receipt_id,receipt_digest,privacy_request_id
  ) ON DELETE RESTRICT,
  CONSTRAINT privacy_identity_proof_consumption_shape_ck CHECK(
    ops.r6d_lower_sha256(identity_proof_receipt_digest)
    AND
    ops.r6d_lower_sha256(subject_proof_hash)
    AND ops.r6d_lower_sha256(exact_scope_digest)
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(
      extensions.digest(receipt_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE ops.privacy_identity_proof_consumption_receipts_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_identity_proof_consumption_receipts_v1 FROM PUBLIC;
GRANT SELECT ON ops.privacy_identity_proof_consumption_receipts_v1
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER privacy_identity_proof_consumption_receipts_v1_immutable
  BEFORE UPDATE OR DELETE
  ON ops.privacy_identity_proof_consumption_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

ALTER TABLE ops.privacy_request_identity_receipts_v2
  ADD CONSTRAINT privacy_identity_receipt_authority_v3_fk FOREIGN KEY(
    identity_proof_receipt_id,identity_proof_receipt_digest
  ) REFERENCES ops.privacy_identity_proof_authority_receipts_v1(
    identity_proof_receipt_id,receipt_digest
  ) ON DELETE RESTRICT;
ALTER TABLE ops.privacy_request_identity_receipts_v2
  ADD CONSTRAINT privacy_identity_receipt_digest_binding_v3_uq UNIQUE(
    identity_receipt_id,receipt_digest
  );
ALTER TABLE ops.privacy_request_transition_receipts_v2
  ADD CONSTRAINT privacy_transition_identity_receipt_v3_fk FOREIGN KEY(
    identity_receipt_id,identity_receipt_digest
  ) REFERENCES ops.privacy_request_identity_receipts_v2(
    identity_receipt_id,receipt_digest
  ) ON DELETE RESTRICT;
ALTER TABLE ops.privacy_identity_proof_consumption_receipts_v1
  ADD CONSTRAINT privacy_identity_consumption_transition_v3_fk FOREIGN KEY(
    transition_receipt_id,privacy_request_id
  ) REFERENCES ops.privacy_request_transition_receipts_v2(
    transition_receipt_id,privacy_request_id
  ) DEFERRABLE INITIALLY DEFERRED;

-- Preserve the public ABI but make the 0038 owner private.  The wrapper below
-- authenticates an existing producer before the first write, then requires the
-- request, proof receipt, and normalized scope inventory to commit together.
ALTER FUNCTION ops.create_privacy_request_v2(
  jsonb,uuid,char(64),char(64)
) RENAME TO create_privacy_request_v2_pre_r6d_d3;
REVOKE ALL ON FUNCTION ops.create_privacy_request_v2_pre_r6d_d3(
  jsonb,uuid,char(64),char(64)
) FROM PUBLIC,gurine_submission_api;

CREATE OR REPLACE FUNCTION ops.create_privacy_request_v2(
  p_payload jsonb,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_sha256 char(64)
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,editorial,extensions,pg_temp
AS $create_d3$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_identity jsonb;
  v_scope jsonb;
  v_proof_kind text;
  v_proof_id uuid;
  v_response_receipt intake.response_submission_receipts_v3%ROWTYPE;
  v_response_submission intake.response_submissions%ROWTYPE;
  v_prior_response_request_scope text;
  v_response_sent editorial.response_request_sent_receipts%ROWTYPE;
  v_verification intake.communication_endpoint_verifications%ROWTYPE;
  v_endpoint intake.communication_endpoints%ROWTYPE;
  v_subject intake.communication_subjects%ROWTYPE;
  v_expected_challenge_kind text;
  v_source_proof_digest char(64);
  v_source_binding_payload jsonb;
  v_source_binding_digest char(64);
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_authority_id uuid;
  v_authority_payload jsonb;
  v_authority_canonical bytea;
  v_authority_digest char(64);
  v_inventory_id uuid;
  v_scope_kind text;
  v_date_from date;
  v_date_to date;
  v_normalized_refs jsonb;
  v_item_count integer;
  v_item_set_digest char(64);
  v_inventory_payload jsonb;
  v_inventory_canonical bytea;
  v_inventory_digest char(64);
  v_existing_authority ops.privacy_identity_proof_authority_receipts_v1%ROWTYPE;
  v_existing_inventory ops.privacy_request_scope_inventories_v1%ROWTYPE;
  v_create_claim ops.idempotency_keys%ROWTYPE;
  v_claim_privacy_request_id uuid;
  v_completed_replay boolean:=false;
  v_result jsonb;
  v_replayed boolean;
BEGIN
  -- Duplicate the closed transient checks here on purpose.  The private 0038
  -- owner remains defense in depth, but source authority is resolved before
  -- it can claim idempotency or write a subject/request row.
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_payload))<>25
     OR NOT p_payload ?& ARRAY['privacyRequestId','identityProof','scope']
     OR jsonb_typeof(p_payload->'identityProof')<>'object'
     OR jsonb_typeof(p_payload->'scope')<>'object' THEN
    RAISE EXCEPTION 'privacy_request_create_input_invalid'
      USING ERRCODE='22023';
  END IF;
  v_identity:=p_payload->'identityProof';
  v_scope:=p_payload->'scope';
  v_proof_kind:=v_identity->>'kind';
  IF v_proof_kind NOT IN ('RESPONSE_RECEIPT','VERIFIED_ENDPOINT') THEN
    RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
      USING ERRCODE='PVT06';
  END IF;

  -- A completed retry is closed exclusively by the immutable owner response,
  -- proof-authority receipt, and scope inventory below.  It must not turn into
  -- a later failure merely because the live source proof subsequently expired
  -- or changed state.  Fresh and incomplete claims still pass every live gate.
  SELECT claim.* INTO v_create_claim
  FROM ops.idempotency_keys AS claim
  WHERE claim.scope='PRIVACY_REQUEST_CREATE_V2'
    AND claim.key_hash=p_idempotency_key_sha256
  FOR SHARE;
  IF FOUND THEN
    IF v_create_claim.request_hash<>p_request_sha256 THEN
      RAISE EXCEPTION 'privacy_request_create_idempotency_conflict'
        USING ERRCODE='PVT05';
    END IF;
    IF v_create_claim.response_body IS NOT NULL THEN
      IF v_create_claim.response_status<>201
         OR v_create_claim.resource_type<>'PrivacyRequest'
         OR v_create_claim.resource_id IS NULL
         OR jsonb_typeof(v_create_claim.response_body)<>'object'
         OR (SELECT count(*) FROM jsonb_object_keys(
              v_create_claim.response_body
            ))<>2
         OR NOT v_create_claim.response_body ?& ARRAY[
           'command','request'
         ]
         OR jsonb_typeof(
           v_create_claim.response_body->'command'
         )<>'object'
         OR jsonb_typeof(
           v_create_claim.response_body->'request'
         )<>'object'
         OR (SELECT count(*) FROM jsonb_object_keys(
              v_create_claim.response_body->'command'
            ))<>7
         OR NOT (v_create_claim.response_body->'command') ?& ARRAY[
           'transportRequestId','aggregateId','aggregateVersion',
           'auditEventId','acceptedAt','receiptDigest','emittedEventIds'
         ]
         OR EXISTS(
           SELECT 1
           FROM jsonb_each(
             v_create_claim.response_body->'command'
           ) AS field(key,value)
           WHERE field.value='null'::jsonb
         )
         OR (SELECT count(*) FROM jsonb_object_keys(
              v_create_claim.response_body->'request'
            ))<>10
         OR NOT (v_create_claim.response_body->'request') ?& ARRAY[
           'privacyRequestId','requestType','state','jurisdiction',
           'scopeDigest','identityState','identityVerifiedAt','dueAt',
           'createdAt','updatedAt'
         ]
         OR EXISTS(
           SELECT 1
           FROM jsonb_each(
             v_create_claim.response_body->'request'
           ) AS field(key,value)
           WHERE field.value='null'::jsonb
             AND field.key NOT IN ('identityVerifiedAt','dueAt')
         )
         OR v_create_claim.response_body->'request'->
              'identityVerifiedAt'<>'null'::jsonb
         OR v_create_claim.response_body->'request'->
              'dueAt'<>'null'::jsonb
         OR v_create_claim.response_body->'request'->>'state'<>'RECEIVED'
         OR v_create_claim.response_body->'request'->>'identityState'<>
              'PENDING_VERIFICATION' THEN
        RAISE EXCEPTION 'privacy_request_create_replay_closure_invalid'
          USING ERRCODE='23514';
      END IF;
      BEGIN
        v_claim_privacy_request_id:=v_create_claim.resource_id::uuid;
        IF v_claim_privacy_request_id=
             '00000000-0000-0000-0000-000000000000'::uuid
           OR (v_create_claim.response_body->'command'->>
                'aggregateId')::uuid<>v_claim_privacy_request_id
           OR (v_create_claim.response_body->'request'->>
                'privacyRequestId')::uuid<>v_claim_privacy_request_id
           OR (v_create_claim.response_body->'command'->>
                'aggregateVersion')::bigint<>1 THEN
          RAISE EXCEPTION 'privacy_request_create_replay_closure_invalid'
            USING ERRCODE='23514';
        END IF;
      EXCEPTION
        WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'privacy_request_create_replay_closure_invalid'
          USING ERRCODE='23514';
      END;
      v_completed_replay:=true;
    END IF;
  END IF;

  BEGIN
    IF v_proof_kind='RESPONSE_RECEIPT' THEN
      IF (SELECT count(*) FROM jsonb_object_keys(v_identity))<>3
         OR NOT v_identity ?& ARRAY[
           'kind','receiptId','possessionTokenHmac'
         ]
         OR EXISTS(
           SELECT 1 FROM jsonb_each(v_identity) AS field(key,value)
           WHERE field.value='null'::jsonb
         )
         OR NOT ops.r6d_lower_sha256(
           v_identity->>'possessionTokenHmac'
         ) THEN
        RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
          USING ERRCODE='PVT06';
      END IF;
      v_proof_id:=(v_identity->>'receiptId')::uuid;
      IF NOT v_completed_replay THEN
      SELECT receipt.* INTO v_response_receipt
      FROM intake.response_submission_receipts_v3 AS receipt
      WHERE receipt.receipt_id=v_proof_id FOR SHARE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'privacy_identity_proof_source_invalid'
          USING ERRCODE='PVT06';
      END IF;
      -- response_submissions is RLS-scoped.  Override any caller GUC with the
      -- request ID from the already locked immutable receipt, then restore it
      -- on both success and failure; caller scope is never source authority.
      v_prior_response_request_scope:=
        current_setting('gurine.response_request_id',true);
      PERFORM set_config(
        'gurine.response_request_id',
        v_response_receipt.response_request_id::text,true
      );
      BEGIN
        SELECT submission.* INTO v_response_submission
        FROM intake.response_submissions AS submission
        WHERE submission.id=v_response_receipt.response_submission_id
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
      IF v_response_submission.id IS NULL
         OR v_response_submission.response_request_id<>
           v_response_receipt.response_request_id
         OR v_response_submission.receipt_version<>
           v_response_receipt.receipt_version
         OR v_response_submission.receipt_digest<>
           v_response_receipt.receipt_digest
         OR v_response_submission.submission_sha256<>
           v_response_receipt.submission_sha256
         OR v_response_submission.receipt_token_hash<>
           (v_identity->>'possessionTokenHmac')::char(64)
         OR v_response_submission.status<>'SUBMITTED' THEN
        RAISE EXCEPTION 'privacy_identity_proof_source_invalid'
          USING ERRCODE='PVT06';
      END IF;
      SELECT sent.* INTO v_response_sent
      FROM editorial.response_request_sent_receipts AS sent
      WHERE sent.response_request_id=v_response_receipt.response_request_id
      FOR SHARE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'privacy_identity_proof_source_invalid'
          USING ERRCODE='PVT06';
      END IF;
      SELECT endpoint.* INTO v_endpoint
      FROM intake.communication_endpoints AS endpoint
      WHERE endpoint.id=v_response_sent.endpoint_id
        AND endpoint.version=v_response_sent.endpoint_version
        AND endpoint.endpoint_digest=v_response_sent.endpoint_snapshot_digest
      FOR SHARE;
      SELECT subject.* INTO v_subject
      FROM intake.communication_endpoint_link_events AS link
      JOIN intake.communication_subjects AS subject
        ON subject.id=link.subject_id
       AND subject.origin_binding_digest=link.subject_origin_binding_digest
      WHERE link.endpoint_id=v_response_sent.endpoint_id
        AND link.endpoint_version=v_response_sent.endpoint_version
        AND link.endpoint_snapshot_digest=
          v_response_sent.endpoint_snapshot_digest
        AND link.channel=v_response_sent.channel
        AND link.state='ACTIVE'
        AND NOT EXISTS(
          SELECT 1
          FROM intake.communication_endpoint_link_events AS later
          WHERE later.endpoint_id=link.endpoint_id
            AND later.endpoint_sequence>link.endpoint_sequence
        )
      FOR SHARE OF subject;
      IF v_endpoint.id IS NULL OR v_subject.id IS NULL
         OR v_endpoint.subject_id<>v_subject.id
         OR v_endpoint.channel<>v_response_sent.channel
         OR v_endpoint.state<>'ACTIVE'
         OR v_endpoint.revoked_at IS NOT NULL
         OR v_endpoint.verified_at IS NULL
         OR v_subject.status<>'ACTIVE'
         OR v_subject.revoked_at IS NOT NULL THEN
        RAISE EXCEPTION 'privacy_identity_proof_source_invalid'
          USING ERRCODE='PVT06';
      END IF;
      v_source_proof_digest:=v_response_receipt.receipt_digest;
      v_source_binding_payload:=jsonb_build_object(
        'schemaVersion','privacy-response-receipt-source-binding.v1',
        'receiptId',v_response_receipt.receipt_id,
        'responseSubmissionId',v_response_receipt.response_submission_id,
        'responseRequestId',v_response_receipt.response_request_id,
        'responseRequestVersion',
          v_response_receipt.response_request_version,
        'responseRequestBindingDigest',btrim(
          v_response_receipt.response_request_binding_digest
        ),
        'submissionSha256',btrim(v_response_receipt.submission_sha256),
        'receiptVersion',v_response_receipt.receipt_version,
        'receiptDigest',btrim(v_response_receipt.receipt_digest),
        'possessionTokenHmac',btrim(
          v_response_submission.receipt_token_hash
        ),
        'subjectId',v_subject.id,
        'subjectOriginDigest',btrim(v_subject.origin_binding_digest),
        'subjectProfileVersion',v_subject.profile_version,
        'subjectProfileDigest',btrim(v_subject.profile_digest),
        'endpointId',v_endpoint.id,
        'endpointVersion',v_endpoint.version,
        'endpointDigest',btrim(v_endpoint.endpoint_digest),
        'channel',v_endpoint.channel
      );
      END IF;
    ELSE
      IF (SELECT count(*) FROM jsonb_object_keys(v_identity))<>5
         OR NOT v_identity ?& ARRAY[
           'kind','challengeId','proofKind','proofVerifierHmac','provider'
         ]
         OR EXISTS(
           SELECT 1 FROM jsonb_each(v_identity) AS field(key,value)
           WHERE field.value='null'::jsonb AND field.key<>'provider'
         )
         OR NOT ops.r6d_lower_sha256(
           v_identity->>'proofVerifierHmac'
         ) THEN
        RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
          USING ERRCODE='PVT06';
      END IF;
      v_expected_challenge_kind:=CASE v_identity->>'proofKind'
        WHEN 'EMAIL_LINK' THEN 'EMAIL_LINK'
        WHEN 'SMS_OTP' THEN 'SMS_OTP'
        WHEN 'PROVIDER_SIGNED_BINDING' THEN CASE v_identity->>'provider'
          WHEN 'TELEGRAM_BOT_API' THEN 'TELEGRAM_SIGNED_BINDING'
          WHEN 'META_WHATSAPP_BUSINESS_CLOUD'
            THEN 'WHATSAPP_SIGNED_BINDING'
          WHEN 'LINE_MESSAGING_API' THEN 'LINE_SIGNED_BINDING'
          WHEN 'SOLAPI_KAKAO_BIZMESSAGE' THEN 'KAKAO_SIGNED_BINDING'
          WHEN 'TWILIO_VOICE' THEN 'VOICE_PHONE_OTP'
          ELSE NULL END
        ELSE NULL END;
      IF v_expected_challenge_kind IS NULL
         OR (v_identity->>'proofKind' IN ('EMAIL_LINK','SMS_OTP')
           AND v_identity->'provider'<>'null'::jsonb)
         OR (v_identity->>'proofKind'='PROVIDER_SIGNED_BINDING'
           AND jsonb_typeof(v_identity->'provider')<>'string') THEN
        RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
          USING ERRCODE='PVT06';
      END IF;
      v_proof_id:=(v_identity->>'challengeId')::uuid;
      IF NOT v_completed_replay THEN
      SELECT verification.* INTO v_verification
      FROM intake.communication_endpoint_verifications AS verification
      WHERE verification.id=v_proof_id FOR SHARE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'privacy_identity_proof_source_invalid'
          USING ERRCODE='PVT06';
      END IF;
      SELECT endpoint.* INTO v_endpoint
      FROM intake.communication_endpoints AS endpoint
      WHERE endpoint.id=v_verification.endpoint_id
        AND endpoint.subject_id=v_verification.subject_id
        AND endpoint.version=v_verification.endpoint_version
        AND endpoint.endpoint_digest=v_verification.endpoint_snapshot_digest
      FOR SHARE;
      SELECT subject.* INTO v_subject
      FROM intake.communication_subjects AS subject
      WHERE subject.id=v_verification.subject_id
        AND subject.origin_binding_digest=
          v_verification.subject_origin_binding_digest
      FOR SHARE;
      IF v_endpoint.id IS NULL OR v_subject.id IS NULL
         OR v_verification.challenge_kind<>v_expected_challenge_kind
         OR v_verification.challenge_hash<>
           (v_identity->>'proofVerifierHmac')::char(64)
         OR v_verification.state<>'VERIFIED'
         OR v_verification.proof_digest IS NULL
         OR v_verification.receipt_digest IS NULL
         OR v_verification.verified_at IS NULL
         OR v_verification.consumed_at IS NULL
         OR v_verification.verified_at>v_now
         OR v_verification.consumed_at>v_now
         OR v_verification.expires_at<=v_now
         OR v_endpoint.state<>'ACTIVE'
         OR v_endpoint.revoked_at IS NOT NULL
         OR v_endpoint.verified_at IS NULL
         OR v_endpoint.updated_at>v_now
         OR v_subject.status<>'ACTIVE'
         OR v_subject.revoked_at IS NOT NULL
         OR NOT EXISTS(
           SELECT 1
           FROM intake.communication_endpoint_link_events AS link
           WHERE link.endpoint_id=v_endpoint.id
             AND link.subject_id=v_subject.id
             AND link.endpoint_version=v_endpoint.version
             AND link.endpoint_snapshot_digest=v_endpoint.endpoint_digest
             AND link.state='ACTIVE'
             AND NOT EXISTS(
               SELECT 1
               FROM intake.communication_endpoint_link_events AS later
               WHERE later.endpoint_id=link.endpoint_id
                 AND later.endpoint_sequence>link.endpoint_sequence
             )
         ) THEN
        RAISE EXCEPTION 'privacy_identity_proof_source_invalid'
          USING ERRCODE='PVT06';
      END IF;
      v_source_proof_digest:=v_verification.receipt_digest;
      v_source_binding_payload:=jsonb_build_object(
        'schemaVersion','privacy-verified-endpoint-source-binding.v1',
        'verificationId',v_verification.id,
        'verificationVersion',v_verification.version,
        'verificationBindingDigest',btrim(
          v_verification.verification_binding_digest
        ),
        'proofDigest',btrim(v_verification.proof_digest),
        'verificationReceiptDigest',btrim(v_verification.receipt_digest),
        'subjectId',v_subject.id,
        'subjectOriginDigest',btrim(v_subject.origin_binding_digest),
        'subjectProfileVersion',v_subject.profile_version,
        'subjectProfileDigest',btrim(v_subject.profile_digest),
        'endpointId',v_endpoint.id,
        'endpointVersion',v_endpoint.version,
        'endpointDigest',btrim(v_endpoint.endpoint_digest),
        'challengeKind',v_verification.challenge_kind,
        'proofVerifierHmac',btrim(v_verification.challenge_hash),
        'verifiedAt',v_verification.verified_at,
        'expiresAt',v_verification.expires_at
      );
      END IF;
    END IF;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
      USING ERRCODE='PVT06';
  END;
  IF v_proof_id IS NULL OR v_proof_id=
     '00000000-0000-0000-0000-000000000000'::uuid THEN
    RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
      USING ERRCODE='PVT06';
  END IF;
  IF NOT v_completed_replay THEN
    IF p_payload->>'communicationEndpointChannel'<>v_endpoint.channel
       OR p_payload->>'communicationEndpointHmac'<>
         btrim(v_endpoint.endpoint_hmac)
       OR p_payload->>'communicationEndpointHmacKeyVersion'<>
         v_endpoint.hmac_key_version THEN
      RAISE EXCEPTION 'privacy_identity_contact_source_mismatch'
        USING ERRCODE='PVT06';
    END IF;
    v_source_binding_digest:=encode(extensions.digest(
      ops.canonical_jsonb_v1(v_source_binding_payload),'sha256'
    ),'hex');
  END IF;

  -- Normalize the exact seven-kind object union before calling the private
  -- owner.  This mirrors its scope digest algorithm and makes item ordering
  -- and duplicates explicit rather than persisting caller order.
  IF (SELECT count(*) FROM jsonb_object_keys(v_scope))<>6
     OR NOT v_scope ?& ARRAY[
       'scopeKind','objectRefs','dateFrom','dateTo',
       'includeDerivatives','includeBackups'
     ]
     OR jsonb_typeof(v_scope->'scopeKind')<>'string'
     OR jsonb_typeof(v_scope->'objectRefs')<>'array'
     OR jsonb_typeof(v_scope->'includeDerivatives')<>'boolean'
     OR jsonb_typeof(v_scope->'includeBackups')<>'boolean'
     OR jsonb_array_length(v_scope->'objectRefs')>1000
     OR EXISTS(
       SELECT 1 FROM jsonb_array_elements(v_scope->'objectRefs') AS ref(value)
       WHERE jsonb_typeof(ref.value)<>'object'
          OR (SELECT count(*) FROM jsonb_object_keys(ref.value))<>2
          OR NOT ref.value ?& ARRAY['objectType','objectId']
          OR jsonb_typeof(ref.value->'objectType')<>'string'
          OR jsonb_typeof(ref.value->'objectId')<>'string'
          OR ref.value->>'objectType' NOT IN (
            'RESPONSE','CORRECTION','SUBSCRIPTION',
            'COMMUNICATION_ENDPOINT','PUBLICATION','EVIDENCE',
            'AUDIT_SUBJECT_RECORD'
          )
     ) THEN
    RAISE EXCEPTION 'privacy_request_scope_invalid' USING ERRCODE='PVT07';
  END IF;
  v_scope_kind:=v_scope->>'scopeKind';
  BEGIN
    IF v_scope->'dateFrom'<>'null'::jsonb THEN
      v_date_from:=(v_scope->>'dateFrom')::date;
      IF jsonb_typeof(v_scope->'dateFrom')<>'string'
         OR to_char(v_date_from,'YYYY-MM-DD')<>v_scope->>'dateFrom' THEN
        RAISE EXCEPTION 'privacy_request_scope_invalid'
          USING ERRCODE='PVT07';
      END IF;
    END IF;
    IF v_scope->'dateTo'<>'null'::jsonb THEN
      v_date_to:=(v_scope->>'dateTo')::date;
      IF jsonb_typeof(v_scope->'dateTo')<>'string'
         OR to_char(v_date_to,'YYYY-MM-DD')<>v_scope->>'dateTo' THEN
        RAISE EXCEPTION 'privacy_request_scope_invalid'
          USING ERRCODE='PVT07';
      END IF;
    END IF;
    SELECT count(*)::integer,COALESCE(jsonb_agg(jsonb_build_object(
      'objectType',parsed.object_kind,'objectId',parsed.object_id
    ) ORDER BY parsed.object_kind,parsed.object_id),'[]'::jsonb)
    INTO v_item_count,v_normalized_refs
    FROM (
      SELECT ref.value->>'objectType' AS object_kind,
        (ref.value->>'objectId')::uuid AS object_id
      FROM jsonb_array_elements(v_scope->'objectRefs') AS ref(value)
    ) AS parsed;
  EXCEPTION WHEN invalid_text_representation OR datetime_field_overflow THEN
    RAISE EXCEPTION 'privacy_request_scope_invalid' USING ERRCODE='PVT07';
  END;
  IF EXISTS(
       SELECT 1 FROM jsonb_array_elements(v_normalized_refs) AS ref(value)
       WHERE (ref.value->>'objectId')::uuid=
         '00000000-0000-0000-0000-000000000000'::uuid
     )
     OR (SELECT count(*) FROM (
       SELECT ref.value->>'objectType',ref.value->>'objectId'
       FROM jsonb_array_elements(v_normalized_refs) AS ref(value)
       GROUP BY ref.value->>'objectType',ref.value->>'objectId'
     ) AS unique_ref)<>v_item_count
     OR NOT (
       v_scope_kind='ALL_VERIFIED_SUBJECT_DATA'
       AND v_item_count=0 AND v_date_from IS NULL AND v_date_to IS NULL
       OR v_scope_kind='OBJECT_SET'
       AND v_item_count BETWEEN 1 AND 1000
       AND v_date_from IS NULL AND v_date_to IS NULL
       OR v_scope_kind='DATE_RANGE'
       AND v_item_count=0 AND v_date_from IS NOT NULL
       AND v_date_to IS NOT NULL AND v_date_from<=v_date_to
     ) THEN
    RAISE EXCEPTION 'privacy_request_scope_invalid' USING ERRCODE='PVT07';
  END IF;
  v_item_set_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_normalized_refs),'sha256'
  ),'hex');

  IF v_completed_replay THEN
    v_result:=v_create_claim.response_body||jsonb_build_object(
      'replayed',true
    );
    v_replayed:=true;
  ELSE
    v_result:=ops.create_privacy_request_v2_pre_r6d_d3(
      p_payload,p_request_id,p_idempotency_key_sha256,p_request_sha256
    );
    v_replayed:=COALESCE((v_result->>'replayed')::boolean,false);
  END IF;
  IF v_completed_replay THEN
    SELECT request.* INTO v_request
    FROM ops.privacy_requests_v2 AS request
    WHERE request.id=v_claim_privacy_request_id
      AND request.create_idempotency_key_sha256=p_idempotency_key_sha256
      AND request.create_request_sha256=p_request_sha256
    FOR SHARE;
    IF NOT FOUND
       OR v_create_claim.resource_id<>v_request.id::text
       OR v_create_claim.response_body->'command'->>
            'transportRequestId'<>v_request.create_request_id::text
       OR v_create_claim.response_body->'command'->>
            'aggregateId'<>v_request.id::text
       OR v_create_claim.response_body->'command'->>
            'auditEventId'<>v_request.create_audit_event_id::text
       OR v_create_claim.response_body->'command'->'acceptedAt'<>
            to_jsonb(v_request.created_at)
       OR v_create_claim.response_body->'command'->
            'emittedEventIds'<>jsonb_build_array(
              v_request.create_outbox_event_id
            )
       OR v_create_claim.response_body->'request'->>
            'privacyRequestId'<>v_request.id::text
       OR v_create_claim.response_body->'request'->>
            'requestType'<>v_request.request_type
       OR v_create_claim.response_body->'request'->>
            'jurisdiction'<>v_request.jurisdiction
       OR v_create_claim.response_body->'request'->>
            'scopeDigest'<>btrim(v_request.scope_sha256)
       OR v_create_claim.response_body->'request'->'createdAt'<>
            to_jsonb(v_request.created_at)
       OR v_create_claim.response_body->'request'->'updatedAt'<>
            to_jsonb(v_request.created_at)
       OR NOT EXISTS(
         SELECT 1
         FROM ops.privacy_request_receipt_tokens_v2 AS token
         WHERE token.privacy_request_id=v_request.id
           AND token.operation_id='createPrivacyRequest'
           AND token.idempotency_key_sha256=p_idempotency_key_sha256
           AND token.request_sha256=p_request_sha256
           AND token.secretless_response_template=
             v_create_claim.response_body
           AND token.secretless_response_digest=encode(extensions.digest(
             ops.canonical_jsonb_v1(v_create_claim.response_body),'sha256'
           ),'hex')
       ) THEN
      RAISE EXCEPTION 'privacy_request_create_replay_closure_invalid'
        USING ERRCODE='23514';
    END IF;
  ELSE
    SELECT request.* INTO STRICT v_request
    FROM ops.privacy_requests_v2 AS request
    WHERE request.id=(p_payload->>'privacyRequestId')::uuid
      AND request.create_request_id=p_request_id
      AND request.create_idempotency_key_sha256=p_idempotency_key_sha256
      AND request.create_request_sha256=p_request_sha256
    FOR SHARE;
  END IF;

  IF v_request.identity_proof_kind<>v_proof_kind
     OR v_request.identity_proof_ref_id<>v_proof_id
     OR v_request.identity_proof_binding_digest<>encode(extensions.digest(
       ops.canonical_jsonb_v1(v_identity),'sha256'
     ),'hex') THEN
    RAISE EXCEPTION 'privacy_identity_proof_request_binding_invalid'
      USING ERRCODE='23514';
  END IF;

  IF v_replayed THEN
    SELECT authority.* INTO v_existing_authority
    FROM ops.privacy_identity_proof_authority_receipts_v1 AS authority
    WHERE authority.privacy_request_id=v_request.id FOR SHARE;
    SELECT inventory.* INTO v_existing_inventory
    FROM ops.privacy_request_scope_inventories_v1 AS inventory
    WHERE inventory.privacy_request_id=v_request.id FOR SHARE;
    IF v_existing_authority.identity_proof_receipt_id IS NULL
       OR v_existing_inventory.scope_inventory_id IS NULL
       OR v_existing_authority.proof_kind<>v_proof_kind
       OR v_existing_authority.source_proof_id<>v_proof_id
       OR v_existing_authority.subject_proof_hash<>
         v_request.subject_proof_hash
       OR v_existing_authority.subject_binding_digest<>
         v_request.identity_proof_binding_digest
       OR v_existing_authority.exact_scope_digest<>v_request.scope_sha256
       OR v_existing_inventory.scope_kind<>v_scope_kind
       OR v_existing_inventory.date_from IS DISTINCT FROM v_date_from
       OR v_existing_inventory.date_to IS DISTINCT FROM v_date_to
       OR v_existing_inventory.include_derivatives<>
         (v_scope->>'includeDerivatives')::boolean
       OR v_existing_inventory.include_backups<>
         (v_scope->>'includeBackups')::boolean
       OR v_existing_inventory.object_item_count<>v_item_count
       OR v_existing_inventory.object_item_set_digest<>v_item_set_digest
       OR v_existing_inventory.scope_digest<>v_request.scope_sha256
       OR (SELECT count(*)
           FROM ops.privacy_request_scope_inventory_items_v1 AS item
           WHERE item.scope_inventory_id=v_existing_inventory.scope_inventory_id
          )<>v_item_count THEN
      RAISE EXCEPTION 'privacy_request_create_replay_authority_invalid'
        USING ERRCODE='23514';
    END IF;
    RETURN v_result;
  END IF;

  IF EXISTS(
       SELECT 1 FROM ops.privacy_identity_proof_authority_receipts_v1
       WHERE privacy_request_id=v_request.id
     ) OR EXISTS(
       SELECT 1 FROM ops.privacy_request_scope_inventories_v1
       WHERE privacy_request_id=v_request.id
     ) THEN
    RAISE EXCEPTION 'privacy_request_create_authority_conflict'
      USING ERRCODE='40001';
  END IF;

  v_authority_id:=gen_random_uuid();
  v_authority_payload:=jsonb_build_object(
    'schemaVersion','privacy-identity-proof-authority-receipt.v1',
    'identityProofReceiptId',v_authority_id,
    'privacyRequestId',v_request.id,
    'proofKind',v_proof_kind,
    'sourceProofId',v_proof_id,
    'sourceProofDigest',btrim(v_source_proof_digest),
    'sourceCurrentBindingDigest',btrim(v_source_binding_digest),
    'subjectProofHash',btrim(v_request.subject_proof_hash),
    'subjectBindingDigest',btrim(
      v_request.identity_proof_binding_digest
    ),
    'exactScopeDigest',btrim(v_request.scope_sha256),
    'requestCreateReceiptDigest',btrim(v_request.create_receipt_digest),
    'createdAt',v_request.created_at
  );
  v_authority_canonical:=ops.canonical_jsonb_v1(v_authority_payload);
  v_authority_digest:=encode(extensions.digest(
    v_authority_canonical,'sha256'
  ),'hex');
  INSERT INTO ops.privacy_identity_proof_authority_receipts_v1(
    identity_proof_receipt_id,privacy_request_id,proof_kind,
    source_proof_id,source_subject_id,source_subject_origin_digest,
    source_endpoint_id,source_endpoint_version,source_endpoint_digest,
    source_response_receipt_id,source_endpoint_verification_id,
    source_proof_digest,source_current_binding_digest,subject_proof_hash,
    subject_binding_digest,exact_scope_digest,request_create_receipt_digest,
    receipt_payload,receipt_canonical,receipt_digest,created_at
  ) VALUES(
    v_authority_id,v_request.id,v_proof_kind,v_proof_id,
    v_subject.id,v_subject.origin_binding_digest,
    v_endpoint.id,v_endpoint.version,v_endpoint.endpoint_digest,
    CASE WHEN v_proof_kind='RESPONSE_RECEIPT'
      THEN v_response_receipt.receipt_id END,
    CASE WHEN v_proof_kind='VERIFIED_ENDPOINT'
      THEN v_verification.id END,
    v_source_proof_digest,v_source_binding_digest,
    v_request.subject_proof_hash,v_request.identity_proof_binding_digest,
    v_request.scope_sha256,v_request.create_receipt_digest,
    v_authority_payload,v_authority_canonical,v_authority_digest,
    v_request.created_at
  );

  v_inventory_id:=gen_random_uuid();
  v_inventory_payload:=jsonb_build_object(
    'schemaVersion','privacy-request-scope-inventory.v1',
    'scopeInventoryId',v_inventory_id,
    'privacyRequestId',v_request.id,
    'scopeKind',v_scope_kind,
    'dateFrom',v_date_from,
    'dateTo',v_date_to,
    'includeDerivatives',(v_scope->>'includeDerivatives')::boolean,
    'includeBackups',(v_scope->>'includeBackups')::boolean,
    'objectItemCount',v_item_count,
    'objectItemSetDigest',btrim(v_item_set_digest),
    'scopeDigest',btrim(v_request.scope_sha256),
    'subjectScopeDigest',btrim(v_request.subject_scope_digest),
    'createdAt',v_request.created_at
  );
  v_inventory_canonical:=ops.canonical_jsonb_v1(v_inventory_payload);
  v_inventory_digest:=encode(extensions.digest(
    v_inventory_canonical,'sha256'
  ),'hex');
  INSERT INTO ops.privacy_request_scope_inventories_v1(
    scope_inventory_id,privacy_request_id,scope_kind,date_from,date_to,
    include_derivatives,include_backups,object_item_count,
    object_item_set_digest,scope_digest,subject_scope_digest,
    receipt_payload,receipt_canonical,receipt_digest,created_at
  ) VALUES(
    v_inventory_id,v_request.id,v_scope_kind,v_date_from,v_date_to,
    (v_scope->>'includeDerivatives')::boolean,
    (v_scope->>'includeBackups')::boolean,v_item_count,v_item_set_digest,
    v_request.scope_sha256,v_request.subject_scope_digest,
    v_inventory_payload,v_inventory_canonical,v_inventory_digest,
    v_request.created_at
  );
  INSERT INTO ops.privacy_request_scope_inventory_items_v1(
    scope_inventory_id,item_ordinal,privacy_request_id,object_kind,
    object_id,item_digest,created_at
  )
  SELECT v_inventory_id,ref.ordinality::integer,v_request.id,
    ref.value->>'objectType',(ref.value->>'objectId')::uuid,
    encode(extensions.digest(
      ops.canonical_jsonb_v1(ref.value),'sha256'
    ),'hex'),v_request.created_at
  FROM jsonb_array_elements(v_normalized_refs)
    WITH ORDINALITY AS ref(value,ordinality);
  IF (SELECT count(*)
      FROM ops.privacy_request_scope_inventory_items_v1 AS item
      WHERE item.scope_inventory_id=v_inventory_id)<>v_item_count THEN
    RAISE EXCEPTION 'privacy_request_scope_inventory_incomplete'
      USING ERRCODE='23514';
  END IF;
  -- Public create response remains the established exact
  -- {command,request,replayed} ABI.  Authority and inventory identifiers are
  -- server-owned receipts and are resolved by later internal review, not
  -- disclosed as caller-controlled transition material.
  RETURN v_result;
END
$create_d3$;
ALTER FUNCTION ops.create_privacy_request_v2(
  jsonb,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.create_privacy_request_v2(
  jsonb,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.create_privacy_request_v2(
  jsonb,uuid,char(64),char(64)
) TO gurine_submission_api;

-- VERIFY_IDENTITY consumes only a receipt whose frozen source binding is still
-- the live graph at the verification instant.  The helper reconstructs the
-- exact create-time binding; it never treats the authority receipt's own digest
-- as evidence that a revoked subject, endpoint, or expiring challenge is current.
CREATE OR REPLACE FUNCTION ops.privacy_identity_proof_authority_current_v1(
  p_identity_proof_receipt_id uuid,
  p_at timestamptz
) RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,editorial,extensions,pg_temp
AS $proof_current$
DECLARE
  v_authority ops.privacy_identity_proof_authority_receipts_v1%ROWTYPE;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_response_receipt intake.response_submission_receipts_v3%ROWTYPE;
  v_response_submission intake.response_submissions%ROWTYPE;
  v_prior_response_request_scope text;
  v_response_sent editorial.response_request_sent_receipts%ROWTYPE;
  v_verification intake.communication_endpoint_verifications%ROWTYPE;
  v_endpoint intake.communication_endpoints%ROWTYPE;
  v_subject intake.communication_subjects%ROWTYPE;
  v_binding_payload jsonb;
  v_binding_digest char(64);
  v_authority_payload jsonb;
BEGIN
  IF p_identity_proof_receipt_id IS NULL
     OR p_identity_proof_receipt_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR p_at IS NULL OR NOT isfinite(p_at) THEN
    RETURN false;
  END IF;
  SELECT authority.* INTO v_authority
  FROM ops.privacy_identity_proof_authority_receipts_v1 AS authority
  WHERE authority.identity_proof_receipt_id=p_identity_proof_receipt_id
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  SELECT request.* INTO v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=v_authority.privacy_request_id
  FOR SHARE;
  IF NOT FOUND
     OR v_authority.proof_kind<>v_request.identity_proof_kind
     OR v_authority.source_proof_id<>v_request.identity_proof_ref_id
     OR v_authority.subject_proof_hash<>v_request.subject_proof_hash
     OR v_authority.subject_binding_digest<>
       v_request.identity_proof_binding_digest
     OR v_authority.exact_scope_digest<>v_request.scope_sha256
     OR v_authority.request_create_receipt_digest<>
       v_request.create_receipt_digest
     OR v_authority.created_at<>v_request.created_at THEN
    RETURN false;
  END IF;

  IF v_authority.proof_kind='RESPONSE_RECEIPT' THEN
    SELECT receipt.* INTO v_response_receipt
    FROM intake.response_submission_receipts_v3 AS receipt
    WHERE receipt.receipt_id=v_authority.source_proof_id
      AND receipt.receipt_id=v_authority.source_response_receipt_id
    FOR SHARE;
    IF NOT FOUND OR v_authority.source_endpoint_verification_id IS NOT NULL THEN
      RETURN false;
    END IF;
    v_prior_response_request_scope:=
      current_setting('gurine.response_request_id',true);
    PERFORM set_config(
      'gurine.response_request_id',
      v_response_receipt.response_request_id::text,true
    );
    BEGIN
      SELECT submission.* INTO v_response_submission
      FROM intake.response_submissions AS submission
      WHERE submission.id=v_response_receipt.response_submission_id
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
    SELECT sent.* INTO v_response_sent
    FROM editorial.response_request_sent_receipts AS sent
    WHERE sent.response_request_id=v_response_receipt.response_request_id
      AND sent.endpoint_id=v_authority.source_endpoint_id
      AND sent.endpoint_version=v_authority.source_endpoint_version
      AND sent.endpoint_snapshot_digest=v_authority.source_endpoint_digest
    FOR SHARE;
    SELECT endpoint.* INTO v_endpoint
    FROM intake.communication_endpoints AS endpoint
    WHERE endpoint.id=v_authority.source_endpoint_id
      AND endpoint.version=v_authority.source_endpoint_version
      AND endpoint.endpoint_digest=v_authority.source_endpoint_digest
    FOR SHARE;
    SELECT subject.* INTO v_subject
    FROM intake.communication_endpoint_link_events AS link
    JOIN intake.communication_subjects AS subject
      ON subject.id=link.subject_id
     AND subject.origin_binding_digest=link.subject_origin_binding_digest
    WHERE link.endpoint_id=v_authority.source_endpoint_id
      AND link.subject_id=v_authority.source_subject_id
      AND link.endpoint_version=v_authority.source_endpoint_version
      AND link.endpoint_snapshot_digest=v_authority.source_endpoint_digest
      AND link.channel=v_response_sent.channel
      AND link.state='ACTIVE'
      AND NOT EXISTS(
        SELECT 1
        FROM intake.communication_endpoint_link_events AS later
        WHERE later.endpoint_id=link.endpoint_id
          AND later.endpoint_sequence>link.endpoint_sequence
      )
    FOR SHARE OF subject;
    IF v_response_submission.id IS NULL OR v_response_sent.id IS NULL
       OR v_endpoint.id IS NULL OR v_subject.id IS NULL
       OR v_response_submission.response_request_id<>
         v_response_receipt.response_request_id
       OR v_response_submission.receipt_version<>
         v_response_receipt.receipt_version
       OR v_response_submission.receipt_digest<>
         v_response_receipt.receipt_digest
       OR v_response_submission.submission_sha256<>
         v_response_receipt.submission_sha256
       OR v_response_submission.status<>'SUBMITTED'
       OR v_endpoint.subject_id<>v_subject.id
       OR v_endpoint.channel<>v_response_sent.channel
       OR v_endpoint.state<>'ACTIVE' OR v_endpoint.revoked_at IS NOT NULL
       OR v_endpoint.verified_at IS NULL OR v_endpoint.updated_at>p_at
       OR v_subject.status<>'ACTIVE' OR v_subject.revoked_at IS NOT NULL
       OR v_subject.origin_binding_digest<>
         v_authority.source_subject_origin_digest THEN
      RETURN false;
    END IF;
    v_binding_payload:=jsonb_build_object(
      'schemaVersion','privacy-response-receipt-source-binding.v1',
      'receiptId',v_response_receipt.receipt_id,
      'responseSubmissionId',v_response_receipt.response_submission_id,
      'responseRequestId',v_response_receipt.response_request_id,
      'responseRequestVersion',v_response_receipt.response_request_version,
      'responseRequestBindingDigest',btrim(
        v_response_receipt.response_request_binding_digest
      ),
      'submissionSha256',btrim(v_response_receipt.submission_sha256),
      'receiptVersion',v_response_receipt.receipt_version,
      'receiptDigest',btrim(v_response_receipt.receipt_digest),
      'possessionTokenHmac',btrim(v_response_submission.receipt_token_hash),
      'subjectId',v_subject.id,
      'subjectOriginDigest',btrim(v_subject.origin_binding_digest),
      'subjectProfileVersion',v_subject.profile_version,
      'subjectProfileDigest',btrim(v_subject.profile_digest),
      'endpointId',v_endpoint.id,
      'endpointVersion',v_endpoint.version,
      'endpointDigest',btrim(v_endpoint.endpoint_digest),
      'channel',v_endpoint.channel
    );
    IF v_authority.source_proof_digest<>
         v_response_receipt.receipt_digest THEN
      RETURN false;
    END IF;
  ELSIF v_authority.proof_kind='VERIFIED_ENDPOINT' THEN
    SELECT verification.* INTO v_verification
    FROM intake.communication_endpoint_verifications AS verification
    WHERE verification.id=v_authority.source_proof_id
      AND verification.id=v_authority.source_endpoint_verification_id
      AND verification.subject_id=v_authority.source_subject_id
      AND verification.subject_origin_binding_digest=
        v_authority.source_subject_origin_digest
      AND verification.endpoint_id=v_authority.source_endpoint_id
      AND verification.endpoint_version=v_authority.source_endpoint_version
      AND verification.endpoint_snapshot_digest=
        v_authority.source_endpoint_digest
    FOR SHARE;
    IF NOT FOUND OR v_authority.source_response_receipt_id IS NOT NULL THEN
      RETURN false;
    END IF;
    SELECT endpoint.* INTO v_endpoint
    FROM intake.communication_endpoints AS endpoint
    WHERE endpoint.id=v_verification.endpoint_id
      AND endpoint.subject_id=v_verification.subject_id
      AND endpoint.version=v_verification.endpoint_version
      AND endpoint.endpoint_digest=v_verification.endpoint_snapshot_digest
    FOR SHARE;
    SELECT subject.* INTO v_subject
    FROM intake.communication_subjects AS subject
    WHERE subject.id=v_verification.subject_id
      AND subject.origin_binding_digest=
        v_verification.subject_origin_binding_digest
    FOR SHARE;
    IF v_endpoint.id IS NULL OR v_subject.id IS NULL
       OR v_verification.state<>'VERIFIED'
       OR v_verification.proof_digest IS NULL
       OR v_verification.receipt_digest IS NULL
       OR v_verification.verified_at IS NULL
       OR v_verification.consumed_at IS NULL
       OR v_verification.verified_at>p_at
       OR v_verification.consumed_at>p_at
       OR v_verification.expires_at<=p_at
       OR v_endpoint.state<>'ACTIVE' OR v_endpoint.revoked_at IS NOT NULL
       OR v_endpoint.verified_at IS NULL OR v_endpoint.updated_at>p_at
       OR v_subject.status<>'ACTIVE' OR v_subject.revoked_at IS NOT NULL
       OR NOT EXISTS(
         SELECT 1
         FROM intake.communication_endpoint_link_events AS link
         WHERE link.endpoint_id=v_endpoint.id
           AND link.subject_id=v_subject.id
           AND link.endpoint_version=v_endpoint.version
           AND link.endpoint_snapshot_digest=v_endpoint.endpoint_digest
           AND link.state='ACTIVE'
           AND NOT EXISTS(
             SELECT 1
             FROM intake.communication_endpoint_link_events AS later
             WHERE later.endpoint_id=link.endpoint_id
               AND later.endpoint_sequence>link.endpoint_sequence
           )
       ) THEN
      RETURN false;
    END IF;
    v_binding_payload:=jsonb_build_object(
      'schemaVersion','privacy-verified-endpoint-source-binding.v1',
      'verificationId',v_verification.id,
      'verificationVersion',v_verification.version,
      'verificationBindingDigest',btrim(
        v_verification.verification_binding_digest
      ),
      'proofDigest',btrim(v_verification.proof_digest),
      'verificationReceiptDigest',btrim(v_verification.receipt_digest),
      'subjectId',v_subject.id,
      'subjectOriginDigest',btrim(v_subject.origin_binding_digest),
      'subjectProfileVersion',v_subject.profile_version,
      'subjectProfileDigest',btrim(v_subject.profile_digest),
      'endpointId',v_endpoint.id,
      'endpointVersion',v_endpoint.version,
      'endpointDigest',btrim(v_endpoint.endpoint_digest),
      'challengeKind',v_verification.challenge_kind,
      'proofVerifierHmac',btrim(v_verification.challenge_hash),
      'verifiedAt',v_verification.verified_at,
      'expiresAt',v_verification.expires_at
    );
    IF v_authority.source_proof_digest<>v_verification.receipt_digest THEN
      RETURN false;
    END IF;
  ELSE
    RETURN false;
  END IF;

  v_binding_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_binding_payload),'sha256'
  ),'hex');
  v_authority_payload:=jsonb_build_object(
    'schemaVersion','privacy-identity-proof-authority-receipt.v1',
    'identityProofReceiptId',v_authority.identity_proof_receipt_id,
    'privacyRequestId',v_authority.privacy_request_id,
    'proofKind',v_authority.proof_kind,
    'sourceProofId',v_authority.source_proof_id,
    'sourceProofDigest',btrim(v_authority.source_proof_digest),
    'sourceCurrentBindingDigest',btrim(v_binding_digest),
    'subjectProofHash',btrim(v_authority.subject_proof_hash),
    'subjectBindingDigest',btrim(v_authority.subject_binding_digest),
    'exactScopeDigest',btrim(v_authority.exact_scope_digest),
    'requestCreateReceiptDigest',btrim(
      v_authority.request_create_receipt_digest
    ),
    'createdAt',v_authority.created_at
  );
  RETURN v_binding_digest=v_authority.source_current_binding_digest
    AND v_authority.receipt_payload=v_authority_payload
    AND v_authority.receipt_canonical=
      ops.canonical_jsonb_v1(v_authority_payload)
    AND v_authority.receipt_digest=encode(extensions.digest(
      v_authority.receipt_canonical,'sha256'
    ),'hex');
EXCEPTION
  WHEN data_exception OR integrity_constraint_violation THEN
    RETURN false;
END
$proof_current$;
ALTER FUNCTION ops.privacy_identity_proof_authority_current_v1(
  uuid,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.privacy_identity_proof_authority_current_v1(
  uuid,timestamptz
) FROM PUBLIC;

-- Static authorization catalog closure (not an operational policy seed).
-- owner-addendum-2026-07-14 assigns privacy request review exclusively to the
-- existing LEGAL_REVIEWER system role.
INSERT INTO ops.capabilities(code,description,risk_level) VALUES(
  'privacy.requests.manage',
  '신원 확인·범위 검토·권리행사 결정 및 정정 계획 기록',
  'CRITICAL'
)
ON CONFLICT(code) DO UPDATE SET
  description=EXCLUDED.description,
  risk_level=EXCLUDED.risk_level;
INSERT INTO ops.role_capabilities(role_id,capability_code)
SELECT role.id,'privacy.requests.manage'
FROM ops.roles AS role
WHERE role.code='LEGAL_REVIEWER' AND role.system_role
ON CONFLICT DO NOTHING;

-- Both D3 human owners revalidate the consumed Actor Assertion, active user
-- session, exact STEP_UP action/idempotency binding, and the live capability
-- assignment in the same SERIALIZABLE transaction.  The assertion replay row
-- is the database evidence that the HTTP boundary verified the request-bound
-- signature; its request digest is intentionally not confused with the
-- command's semantic idempotency digest.
CREATE OR REPLACE FUNCTION ops.require_privacy_step_up_v3(
  p_actor_id uuid,
  p_session_id uuid,
  p_actor_assertion_jti uuid,
  p_actor_assertion_request_sha256 char(64),
  p_actor_action_digest char(64),
  p_step_up_authorization_id uuid,
  p_idempotency_key_sha256 char(64),
  p_capability text,
  p_at timestamptz
) RETURNS char(64)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $privacy_step_up$
DECLARE
  v_assertion ops.assertion_replay_guard%ROWTYPE;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_session ops.sessions%ROWTYPE;
  v_actor ops.users%ROWTYPE;
  v_receipt_payload jsonb;
BEGIN
  IF p_actor_id IS NULL
     OR p_actor_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_session_id IS NULL
     OR p_session_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_actor_assertion_jti IS NULL
     OR p_actor_assertion_jti=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR p_step_up_authorization_id IS NULL
     OR p_step_up_authorization_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR p_capability<>'privacy.requests.manage'
     OR NOT ops.r6d_lower_sha256(p_actor_assertion_request_sha256)
     OR NOT ops.r6d_lower_sha256(p_actor_action_digest)
     OR NOT ops.r6d_lower_sha256(p_idempotency_key_sha256)
     OR p_at IS NULL OR NOT isfinite(p_at) THEN
    RAISE EXCEPTION 'privacy_step_up_input_invalid' USING ERRCODE='22023';
  END IF;

  SELECT assertion.* INTO v_assertion
  FROM ops.assertion_replay_guard AS assertion
  WHERE assertion.assertion_type='ACTOR'
    AND assertion.jti=p_actor_assertion_jti;
  SELECT step_up_authorization.* INTO v_step_up
  FROM ops.step_up_authorizations AS step_up_authorization
  WHERE step_up_authorization.id=p_step_up_authorization_id
  FOR SHARE;
  IF v_step_up.id IS NOT NULL THEN
    SELECT session.* INTO v_session
    FROM ops.sessions AS session
    WHERE session.id=v_step_up.session_id
    FOR SHARE;
  END IF;
  SELECT actor.* INTO v_actor
  FROM ops.users AS actor
  WHERE actor.id=p_actor_id
  FOR SHARE;

  IF v_assertion.jti IS NULL
     OR v_assertion.issuer<>'identity-api'
     OR v_assertion.audience<>'control-api'
     OR v_assertion.request_digest<>p_actor_assertion_request_sha256
     OR v_assertion.consumed_at>p_at
     OR v_assertion.expires_at<=p_at
     OR v_step_up.id IS NULL
     OR v_step_up.session_id<>p_session_id
     OR v_step_up.closed_at IS NOT NULL
     OR v_step_up.expires_at<=p_at
     OR v_step_up.action_digest<>p_actor_action_digest
     OR v_step_up.idempotency_key_sha256<>p_idempotency_key_sha256
     OR v_step_up.assertion_issue_count NOT BETWEEN 1 AND 3
     OR v_step_up.assertion_issue_count>v_step_up.max_assertion_issues
     OR v_step_up.last_issued_at IS NULL
     OR v_step_up.last_issued_at>p_at
     OR v_step_up.last_issued_at>=v_step_up.expires_at
     OR v_step_up.expires_at>
       v_step_up.last_issued_at+interval '5 minutes 5 seconds'
     OR v_session.id IS NULL
     OR v_session.user_id<>p_actor_id
     OR v_session.revoked_at IS NOT NULL
     OR v_session.expires_at<=p_at
     OR v_actor.id IS NULL OR v_actor.status<>'ACTIVE'
     OR NOT EXISTS(
       SELECT 1
       FROM ops.user_roles AS user_role
       JOIN ops.role_capabilities AS role_capability
         ON role_capability.role_id=user_role.role_id
        AND role_capability.capability_code=p_capability
       WHERE user_role.user_id=p_actor_id
         AND user_role.revoked_at IS NULL
         AND (user_role.expires_at IS NULL OR user_role.expires_at>p_at)
     ) THEN
    RAISE EXCEPTION 'privacy_step_up_authority_invalid'
      USING ERRCODE='42501';
  END IF;

  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','privacy-step-up-authority.v1',
    'actorId',p_actor_id,
    'sessionId',p_session_id,
    'actorAssertionJti',p_actor_assertion_jti,
    'actorAssertionRequestDigest',btrim(p_actor_assertion_request_sha256),
    'actorAssertionExpiresAt',v_assertion.expires_at,
    'stepUpAuthorizationId',v_step_up.id,
    'stepUpActionDigest',btrim(v_step_up.action_digest),
    'stepUpIdempotencyKeySha256',btrim(v_step_up.idempotency_key_sha256),
    'stepUpIssueNumber',v_step_up.assertion_issue_count,
    'stepUpIssuedAt',v_step_up.last_issued_at,
    'stepUpExpiresAt',v_step_up.expires_at,
    'effectiveCapability',p_capability,
    'validatedAt',p_at
  );
  RETURN encode(extensions.digest(
    ops.canonical_jsonb_v1(v_receipt_payload),'sha256'
  ),'hex');
END
$privacy_step_up$;
ALTER FUNCTION ops.require_privacy_step_up_v3(
  uuid,uuid,uuid,char(64),char(64),uuid,char(64),text,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.require_privacy_step_up_v3(
  uuid,uuid,uuid,char(64),char(64),uuid,char(64),text,timestamptz
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.verify_privacy_request_identity_v3(
  p_payload jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_sha256 char(64)
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,extensions,pg_temp
AS $verify_privacy_identity$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_privacy_request_id uuid;
  v_expected_decision_version bigint;
  v_identity_proof_receipt_id uuid;
  v_transition_receipt_id uuid;
  v_reason_code text;
  v_reason_ciphertext bytea;
  v_reason_sha256 char(64);
  v_reason_aad_digest char(64);
  v_encryption_key_id text;
  v_actor_assertion_jti uuid;
  v_actor_assertion_request_digest char(64);
  v_actor_action_digest char(64);
  v_step_up_authorization_id uuid;
  v_step_up_receipt_digest char(64);
  v_idempotency ops.idempotency_keys%ROWTYPE;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_authority ops.privacy_identity_proof_authority_receipts_v1%ROWTYPE;
  v_inventory ops.privacy_request_scope_inventories_v1%ROWTYPE;
  v_inventory_items jsonb;
  v_inventory_item_count bigint;
  v_inventory_payload jsonb;
  v_subject intake.communication_subjects%ROWTYPE;
  v_endpoint intake.communication_endpoints%ROWTYPE;
  v_contact_link intake.communication_endpoint_link_events%ROWTYPE;
  v_contact_verification intake.communication_endpoint_verifications%ROWTYPE;
  v_policy_reference jsonb;
  v_policy ops.privacy_response_calendar_policies_v1%ROWTYPE;
  v_calendar ops.business_calendar_versions%ROWTYPE;
  v_business_days integer;
  v_due_at timestamptz;
  v_decision_version bigint;
  v_notice_count bigint;
  v_notice_max_sequence bigint;
  v_notice_sequence bigint;
  v_identity_receipt_id uuid;
  v_notice_receipt_id uuid;
  v_consumption_receipt_id uuid;
  v_identity_payload jsonb;
  v_identity_canonical bytea;
  v_identity_digest char(64);
  v_notice_template jsonb;
  v_notice_template_digest char(64);
  v_notice_aad_digest char(64);
  v_notice_payload jsonb;
  v_notice_canonical bytea;
  v_notice_digest char(64);
  v_event_payload jsonb;
  v_event_id uuid;
  v_event_digest char(64);
  v_transition_payload jsonb;
  v_transition_canonical bytea;
  v_transition_digest char(64);
  v_consumption_payload jsonb;
  v_consumption_canonical bytea;
  v_consumption_digest char(64);
  v_audit_event_id uuid;
  v_outbox_event_ids uuid[];
  v_transition_response jsonb;
  v_result jsonb;
  v_affected integer;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_payload))<>15
     OR NOT p_payload ?& ARRAY[
       'retentionRequestId','expectedDecisionVersion',
       'identityProofReceiptId','reasonCode','reasonCiphertextBase64',
       'reasonSha256','transitionReceiptId','_actorAssertionJti',
       '_actorAssuranceLevel','_actorEffectiveCapability',
       '_actorAssertionRequestSha256','_actorActionDigest',
       '_actorStepUpAuthorizationId','_actorIdempotencyKeySha256',
       '_actorRequestKeySha256'
     ]
     OR jsonb_typeof(p_payload->'retentionRequestId')<>'string'
     OR jsonb_typeof(p_payload->'expectedDecisionVersion')<>'number'
     OR p_payload->>'expectedDecisionVersion' !~ '^(0|[1-9][0-9]{0,18})$'
     OR jsonb_typeof(p_payload->'identityProofReceiptId')<>'string'
     OR jsonb_typeof(p_payload->'reasonCode')<>'string'
     OR jsonb_typeof(p_payload->'reasonCiphertextBase64')<>'string'
     OR p_payload->>'reasonCiphertextBase64' !~ '^[A-Za-z0-9+/]+={0,2}$'
     OR length(p_payload->>'reasonCiphertextBase64')%4<>0
     OR jsonb_typeof(p_payload->'reasonSha256')<>'string'
     OR jsonb_typeof(p_payload->'transitionReceiptId')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssertionJti')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssuranceLevel')<>'string'
     OR jsonb_typeof(p_payload->'_actorEffectiveCapability')<>'string'
     OR jsonb_typeof(
       p_payload->'_actorAssertionRequestSha256'
     )<>'string'
     OR jsonb_typeof(p_payload->'_actorActionDigest')<>'string'
     OR jsonb_typeof(p_payload->'_actorStepUpAuthorizationId')<>'string'
     OR jsonb_typeof(p_payload->'_actorIdempotencyKeySha256')<>'string'
     OR jsonb_typeof(p_payload->'_actorRequestKeySha256')<>'string'
     OR p_actor_id IS NULL OR p_session_id IS NULL OR p_request_id IS NULL
     OR NOT ops.r6d_lower_sha256(p_idempotency_key_sha256)
     OR NOT ops.r6d_lower_sha256(p_request_sha256)
     OR NOT ops.r6d_lower_sha256(p_payload->>'reasonSha256')
     OR NOT ops.r6d_lower_sha256(
       p_payload->>'_actorAssertionRequestSha256'
     )
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorActionDigest')
     OR NOT ops.r6d_lower_sha256(
       p_payload->>'_actorIdempotencyKeySha256'
     )
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorRequestKeySha256')
     OR p_payload->>'_actorAssuranceLevel'<>'STEP_UP'
     OR p_payload->>'_actorEffectiveCapability'<>
       'privacy.requests.manage'
     OR p_payload->>'_actorIdempotencyKeySha256'<>
       btrim(p_idempotency_key_sha256)
     OR p_payload->>'_actorRequestKeySha256'<>
       btrim(p_idempotency_key_sha256)
     OR current_setting('transaction_isolation')<>'serializable' THEN
    RAISE EXCEPTION 'privacy_identity_verification_input_invalid'
      USING ERRCODE='22023';
  END IF;

  BEGIN
    v_privacy_request_id:=(p_payload->>'retentionRequestId')::uuid;
    v_expected_decision_version:=
      (p_payload->>'expectedDecisionVersion')::bigint;
    v_identity_proof_receipt_id:=
      (p_payload->>'identityProofReceiptId')::uuid;
    v_transition_receipt_id:=(p_payload->>'transitionReceiptId')::uuid;
    v_actor_assertion_jti:=(p_payload->>'_actorAssertionJti')::uuid;
    v_actor_assertion_request_digest:=
      (p_payload->>'_actorAssertionRequestSha256')::char(64);
    v_actor_action_digest:=
      (p_payload->>'_actorActionDigest')::char(64);
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
    RAISE EXCEPTION 'privacy_identity_verification_input_invalid'
      USING ERRCODE='22023';
  END;
  v_reason_code:=p_payload->>'reasonCode';
  v_reason_sha256:=(p_payload->>'reasonSha256')::char(64);
  v_reason_aad_digest:=ops.r6d_nul5_sha256_v1(
    'ops.privacy_request_sealed_content_v2','sealed_ciphertext',
    v_transition_receipt_id::text,'REASON','1'
  );
  IF v_privacy_request_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_identity_proof_receipt_id=
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
    RAISE EXCEPTION 'privacy_identity_verification_input_invalid'
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
       v_idempotency.response_status,v_idempotency.response_body,
       v_idempotency.resource_type,v_idempotency.resource_id
     )<>0 THEN
    RAISE EXCEPTION 'privacy_identity_verification_idempotency_conflict'
      USING ERRCODE='40001';
  END IF;

  SELECT request.* INTO v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=v_privacy_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_identity_verification_request_not_found'
      USING ERRCODE='P0002';
  END IF;
  IF v_request.decision_version<>v_expected_decision_version THEN
    RAISE EXCEPTION 'privacy_identity_verification_version_conflict'
      USING ERRCODE='PVT08';
  END IF;
  IF v_request.state<>'RECEIVED'
     OR v_request.identity_state<>'PENDING_VERIFICATION'
     OR v_request.identity_verified_at IS NOT NULL
     OR v_request.due_at IS NOT NULL
     OR num_nonnulls(
       v_request.response_policy_id,v_request.response_policy_revision,
       v_request.response_policy_digest,v_request.calendar_version_id,
       v_request.calendar_digest,v_request.current_identity_receipt_id,
       v_request.current_identity_receipt_digest
     )<>0 THEN
    RAISE EXCEPTION 'privacy_identity_verification_state_invalid'
      USING ERRCODE='PVT09';
  END IF;

  SELECT authority.* INTO v_authority
  FROM ops.privacy_identity_proof_authority_receipts_v1 AS authority
  WHERE authority.identity_proof_receipt_id=
      v_identity_proof_receipt_id
    AND authority.privacy_request_id=v_request.id
  FOR SHARE;
  IF NOT FOUND
     OR v_authority.proof_kind<>v_request.identity_proof_kind
     OR v_authority.source_proof_id<>v_request.identity_proof_ref_id
     OR v_authority.subject_proof_hash<>v_request.subject_proof_hash
     OR v_authority.subject_binding_digest<>
       v_request.identity_proof_binding_digest
     OR v_authority.exact_scope_digest<>v_request.scope_sha256
     OR v_authority.request_create_receipt_digest<>
       v_request.create_receipt_digest
     OR NOT ops.privacy_identity_proof_authority_current_v1(
       v_authority.identity_proof_receipt_id,v_now
     )
     OR EXISTS(
       SELECT 1
       FROM ops.privacy_identity_proof_consumption_receipts_v1 AS consumed
       WHERE consumed.identity_proof_receipt_id=
         v_authority.identity_proof_receipt_id
     ) THEN
    RAISE EXCEPTION 'privacy_identity_verification_proof_invalid'
      USING ERRCODE='PVT06';
  END IF;

  SELECT inventory.* INTO v_inventory
  FROM ops.privacy_request_scope_inventories_v1 AS inventory
  WHERE inventory.privacy_request_id=v_request.id
  FOR SHARE;
  SELECT count(*),COALESCE(jsonb_agg(jsonb_build_object(
    'objectType',item.object_kind,'objectId',item.object_id
  ) ORDER BY item.object_kind,item.object_id),'[]'::jsonb)
  INTO v_inventory_item_count,v_inventory_items
  FROM ops.privacy_request_scope_inventory_items_v1 AS item
  WHERE item.scope_inventory_id=v_inventory.scope_inventory_id
    AND item.privacy_request_id=v_request.id;
  v_inventory_payload:=jsonb_build_object(
    'schemaVersion','privacy-request-scope-inventory.v1',
    'scopeInventoryId',v_inventory.scope_inventory_id,
    'privacyRequestId',v_inventory.privacy_request_id,
    'scopeKind',v_inventory.scope_kind,
    'dateFrom',v_inventory.date_from,
    'dateTo',v_inventory.date_to,
    'includeDerivatives',v_inventory.include_derivatives,
    'includeBackups',v_inventory.include_backups,
    'objectItemCount',v_inventory.object_item_count,
    'objectItemSetDigest',btrim(v_inventory.object_item_set_digest),
    'scopeDigest',btrim(v_inventory.scope_digest),
    'subjectScopeDigest',btrim(v_inventory.subject_scope_digest),
    'createdAt',v_inventory.created_at
  );
  IF v_inventory.scope_inventory_id IS NULL
     OR v_inventory.scope_digest<>v_request.scope_sha256
     OR v_inventory.subject_scope_digest<>v_request.subject_scope_digest
     OR v_inventory.object_item_count<>v_inventory_item_count
     OR v_inventory.object_item_set_digest<>encode(extensions.digest(
       ops.canonical_jsonb_v1(v_inventory_items),'sha256'
     ),'hex')
     OR v_inventory.receipt_payload<>v_inventory_payload
     OR v_inventory.receipt_canonical<>
       ops.canonical_jsonb_v1(v_inventory_payload)
     OR v_inventory.receipt_digest<>encode(extensions.digest(
       v_inventory.receipt_canonical,'sha256'
     ),'hex') THEN
    RAISE EXCEPTION 'privacy_identity_verification_scope_invalid'
      USING ERRCODE='PVT07';
  END IF;

  SELECT subject.* INTO v_subject
  FROM intake.communication_subjects AS subject
  WHERE subject.id=v_request.communication_subject_id
    AND subject.origin_binding_digest=
      v_request.communication_subject_origin_digest
  FOR SHARE;
  SELECT endpoint.* INTO v_endpoint
  FROM intake.communication_endpoints AS endpoint
  WHERE endpoint.id=v_request.communication_endpoint_id
    AND endpoint.subject_id=v_request.communication_subject_id
    AND endpoint.version=v_request.communication_endpoint_version
    AND endpoint.endpoint_digest=v_request.communication_endpoint_digest
  FOR SHARE;
  SELECT link.* INTO v_contact_link
  FROM intake.communication_endpoint_link_events AS link
  WHERE link.endpoint_id=v_request.communication_endpoint_id
    AND link.subject_id=v_request.communication_subject_id
    AND link.subject_origin_binding_digest=
      v_request.communication_subject_origin_digest
    AND link.endpoint_version=v_request.communication_endpoint_version
    AND link.endpoint_snapshot_digest=
      v_request.communication_endpoint_digest
    AND link.state='ACTIVE'
    AND NOT EXISTS(
      SELECT 1
      FROM intake.communication_endpoint_link_events AS later
      WHERE later.endpoint_id=link.endpoint_id
        AND later.endpoint_sequence>link.endpoint_sequence
    )
  FOR SHARE;
  IF v_contact_link.verification_id IS NOT NULL THEN
    SELECT verification.* INTO v_contact_verification
    FROM intake.communication_endpoint_verifications AS verification
    WHERE verification.id=v_contact_link.verification_id
      AND verification.subject_id=v_request.communication_subject_id
      AND verification.subject_origin_binding_digest=
        v_request.communication_subject_origin_digest
      AND verification.endpoint_id=v_request.communication_endpoint_id
      AND verification.endpoint_version=
        v_request.communication_endpoint_version
      AND verification.endpoint_snapshot_digest=
        v_request.communication_endpoint_digest
    FOR SHARE;
  END IF;
  IF v_subject.id IS NULL OR v_endpoint.id IS NULL
     OR v_contact_link.id IS NULL OR v_contact_verification.id IS NULL
     OR v_subject.subject_kind<>'PRIVACY_REQUESTER'
     OR v_subject.origin_object_type<>'PRIVACY_REQUEST'
     OR v_subject.origin_object_id<>v_request.id
     OR v_subject.status<>'ACTIVE' OR v_subject.revoked_at IS NOT NULL
     OR v_endpoint.state<>'ACTIVE' OR v_endpoint.revoked_at IS NOT NULL
     OR v_endpoint.verified_at IS NULL OR v_endpoint.updated_at>v_now
     OR v_contact_link.change_kind<>'VERIFIED'
     OR v_contact_link.verification_id IS NULL
     OR v_contact_link.channel<>v_endpoint.channel
     OR v_contact_link.endpoint_digest<>v_endpoint.endpoint_digest
     OR v_contact_link.proof_digest<>v_contact_verification.proof_digest
     OR v_contact_link.receipt_digest<>
       v_contact_verification.receipt_digest
     OR v_contact_verification.state<>'VERIFIED'
     OR v_contact_verification.proof_digest IS NULL
     OR v_contact_verification.receipt_digest IS NULL
     OR v_contact_verification.verified_at IS NULL
     OR v_contact_verification.consumed_at IS NULL
     OR v_contact_verification.verified_at>v_now
     OR v_contact_verification.consumed_at>v_now
     OR v_endpoint.id=v_authority.source_endpoint_id
     OR v_contact_verification.id=v_authority.source_proof_id
     OR v_contact_verification.id IS NOT DISTINCT FROM
       v_authority.source_endpoint_verification_id
     OR NOT ops.r6d_field_envelope_v1_is_valid(
       v_endpoint.endpoint_ciphertext,v_endpoint.encryption_key_id
     )
     OR v_endpoint.endpoint_aad_digest<>ops.r6d_nul5_sha256_v1(
       'intake.communication_endpoints','endpoint_ciphertext',
       v_endpoint.id::text,CASE v_endpoint.channel
         WHEN 'SMTP_EMAIL' THEN 'email-address'
         WHEN 'TELEGRAM_BOT_API' THEN 'provider-identifier'
         WHEN 'LINE_MESSAGING_API' THEN 'provider-identifier'
         ELSE 'phone-number'
       END,'1'
     ) THEN
    RAISE EXCEPTION 'privacy_identity_verification_contact_invalid'
      USING ERRCODE='PVT06';
  END IF;

  v_policy_reference:=
    ops.current_privacy_response_policy_calendar_v1(v_now);
  BEGIN
    IF jsonb_typeof(v_policy_reference)<>'object'
       OR (SELECT count(*) FROM jsonb_object_keys(v_policy_reference))<>18
       OR NOT v_policy_reference ?& ARRAY[
         'policyId','revision','policyVersion','policyDigest',
         'policyBindingDigest','accessBusinessDays',
         'correctionBusinessDays','deletionBusinessDays',
         'restrictionBusinessDays','maximumExtensionBusinessDays',
         'maximumExtensionCount','refusalNoticeBusinessDays',
         'calendarVersionId','calendarId','calendarVersion',
         'calendarDigest','effectiveAt','reviewExpiresAt'
       ] THEN
      RAISE EXCEPTION 'privacy_response_policy_calendar_binding_invalid'
        USING ERRCODE='55000';
    END IF;
    SELECT policy.* INTO v_policy
    FROM ops.privacy_response_calendar_policies_v1 AS policy
    WHERE policy.policy_id=(v_policy_reference->>'policyId')::uuid
      AND policy.revision=(v_policy_reference->>'revision')::bigint
      AND policy.policy_digest=v_policy_reference->>'policyDigest'
    FOR SHARE;
    SELECT calendar.* INTO v_calendar
    FROM ops.business_calendar_versions AS calendar
    WHERE calendar.id=(v_policy_reference->>'calendarVersionId')::uuid
      AND calendar.calendar_digest=v_policy_reference->>'calendarDigest'
    FOR SHARE;
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range
      OR datetime_field_overflow THEN
    RAISE EXCEPTION 'privacy_response_policy_calendar_binding_invalid'
      USING ERRCODE='55000';
  END;
  IF v_policy.policy_id IS NULL OR v_calendar.id IS NULL
     OR v_policy.state<>'APPROVED' OR v_policy.timezone<>'Asia/Seoul'
     OR v_policy.effective_at>v_now OR v_policy.review_expires_at<=v_now
     OR v_policy.calendar_id<>v_calendar.id
     OR v_policy.policy_version<>v_policy_reference->>'policyVersion'
     OR btrim(v_policy.policy_digest)<>
       v_policy_reference->>'policyDigest'
     OR btrim(v_policy.binding_digest)<>
       v_policy_reference->>'policyBindingDigest'
     OR v_calendar.timezone<>'Asia/Seoul'
     OR v_calendar.effective_at>v_now
     OR v_calendar.review_expires_at<=v_now
     OR v_calendar.policy_digest<>v_policy.policy_digest
     OR NOT ops.privacy_response_policy_calendar_authority_v1_is_valid(
       v_policy.policy_id,v_policy.revision
     ) THEN
    RAISE EXCEPTION 'privacy_response_policy_calendar_binding_invalid'
      USING ERRCODE='55000';
  END IF;
  v_business_days:=CASE v_request.request_type
    WHEN 'ACCESS' THEN v_policy.access_business_days
    WHEN 'CORRECTION' THEN v_policy.correction_business_days
    WHEN 'DELETION' THEN v_policy.deletion_business_days
    WHEN 'RESTRICTION' THEN v_policy.restriction_business_days
  END;
  IF v_business_days IS NULL OR v_business_days NOT BETWEEN 1 AND 365 THEN
    RAISE EXCEPTION 'privacy_response_policy_calendar_binding_invalid'
      USING ERRCODE='55000';
  END IF;
  v_due_at:=ops.add_privacy_business_days_v1(
    v_now,v_business_days,v_calendar.id,v_calendar.calendar_digest
  );
  IF v_due_at<=v_now THEN
    RAISE EXCEPTION 'privacy_response_policy_calendar_binding_invalid'
      USING ERRCODE='55000';
  END IF;

  PERFORM receipt.transition_receipt_id
  FROM ops.privacy_request_transition_receipts_v2 AS receipt
  WHERE receipt.privacy_request_id=v_request.id
  ORDER BY receipt.decision_version
  FOR UPDATE;
  PERFORM notice.notice_receipt_id
  FROM ops.privacy_request_notice_receipts_v2 AS notice
  WHERE notice.privacy_request_id=v_request.id
  ORDER BY notice.notice_sequence
  FOR UPDATE;
  SELECT count(*),COALESCE(max(notice.notice_sequence),0)
  INTO v_notice_count,v_notice_max_sequence
  FROM ops.privacy_request_notice_receipts_v2 AS notice
  WHERE notice.privacy_request_id=v_request.id;
  IF v_notice_count<>v_notice_max_sequence
     OR EXISTS(
       SELECT 1
       FROM ops.privacy_request_transition_receipts_v2 AS receipt
       WHERE receipt.transition_receipt_id=v_transition_receipt_id
          OR receipt.actor_assertion_jti=v_actor_assertion_jti
          OR receipt.step_up_authorization_id=
            v_step_up_authorization_id
          OR receipt.idempotency_key_sha256=
            p_idempotency_key_sha256
     ) THEN
    RAISE EXCEPTION 'privacy_identity_verification_receipt_conflict'
      USING ERRCODE='40001';
  END IF;
  v_decision_version:=v_request.decision_version+1;
  v_notice_sequence:=v_notice_max_sequence+1;
  v_identity_receipt_id:=gen_random_uuid();
  v_notice_receipt_id:=gen_random_uuid();
  v_consumption_receipt_id:=gen_random_uuid();

  v_step_up_receipt_digest:=ops.require_privacy_step_up_v3(
    p_actor_id,p_session_id,v_actor_assertion_jti,
    v_actor_assertion_request_digest,v_actor_action_digest,
    v_step_up_authorization_id,p_idempotency_key_sha256,
    'privacy.requests.manage',v_now
  );
  v_identity_payload:=jsonb_build_object(
    'schemaVersion','privacy-request-identity-receipt.v2',
    'identityReceiptId',v_identity_receipt_id,
    'retentionRequestId',v_request.id,
    'decisionVersion',v_decision_version,
    'identityProofReceiptId',v_authority.identity_proof_receipt_id,
    'identityProofReceiptDigest',btrim(v_authority.receipt_digest),
    'priorIdentityState','PENDING_VERIFICATION',
    'identityState','VERIFIED',
    'identityVerifiedAt',v_now,
    'dueAt',v_due_at,
    'responsePolicyId',v_policy.policy_id,
    'responsePolicyRevision',v_policy.revision,
    'responsePolicyVersion',v_policy.policy_version,
    'responsePolicyDigest',btrim(v_policy.policy_digest),
    'calendarVersionId',v_calendar.id,
    'calendarDigest',btrim(v_calendar.calendar_digest)
  );
  v_identity_canonical:=ops.canonical_jsonb_v1(v_identity_payload);
  v_identity_digest:=encode(extensions.digest(
    v_identity_canonical,'sha256'
  ),'hex');
  v_notice_template:=jsonb_build_object(
    'schemaVersion','privacy-request-notice-template.v1',
    'kind','IDENTITY_VERIFIED',
    'retentionRequestId',v_request.id,
    'requestType',v_request.request_type,
    'decisionVersion',v_decision_version,
    'branchReceiptId',v_identity_receipt_id,
    'branchReceiptDigest',btrim(v_identity_digest),
    'dueAt',v_due_at,
    'reasonCode',v_reason_code,
    'reasonDigest',btrim(v_reason_sha256)
  );
  v_notice_template_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_notice_template),'sha256'
  ),'hex');
  v_notice_aad_digest:=ops.r6d_nul5_sha256_v1(
    'ops.privacy_request_notice_receipts_v2',
    'notice_template_payload',v_notice_receipt_id::text,
    'IDENTITY_VERIFIED','1'
  );
  v_notice_payload:=jsonb_build_object(
    'schemaVersion','privacy-request-notice-receipt.v2',
    'noticeReceiptId',v_notice_receipt_id,
    'retentionRequestId',v_request.id,
    'noticeSequence',v_notice_sequence,
    'noticeKind','IDENTITY_VERIFIED',
    'transitionReceiptId',v_transition_receipt_id,
    'endpointId',v_endpoint.id,
    'endpointVersion',v_endpoint.version,
    'endpointDigest',btrim(v_endpoint.endpoint_digest),
    'endpointAadDigest',btrim(v_endpoint.endpoint_aad_digest),
    'encryptionKeyId',v_endpoint.encryption_key_id,
    'noticeSha256',btrim(v_notice_template_digest),
    'noticeAadDigest',btrim(v_notice_aad_digest),
    'noticeTemplate',v_notice_template,
    'noticeTemplateDigest',btrim(v_notice_template_digest),
    'branchReceiptId',v_identity_receipt_id,
    'branchReceiptDigest',btrim(v_identity_digest),
    'createdAt',v_now
  );
  v_notice_canonical:=ops.canonical_jsonb_v1(v_notice_payload);
  v_notice_digest:=encode(extensions.digest(
    v_notice_canonical,'sha256'
  ),'hex');
  v_event_payload:=jsonb_build_object(
    'retentionRequestId',v_request.id,
    'requestType',v_request.request_type,
    'priorIdentityState','PENDING_VERIFICATION',
    'identityState','VERIFIED',
    'identityProofReceiptDigest',btrim(v_authority.receipt_digest),
    'identityVerifiedAt',v_now,
    'responsePolicyVersion',v_policy.policy_version,
    'responsePolicyDigest',btrim(v_policy.policy_digest),
    'calendarVersionId',v_calendar.id,
    'calendarDigest',btrim(v_calendar.calendar_digest),
    'dueAt',v_due_at,
    'verificationReceiptDigest',btrim(v_identity_digest)
  );

  -- Every success precondition is now fixed.  The first write is the event;
  -- all following receipt/root writes are in this same SERIALIZABLE transaction.
  PERFORM set_config('gurine.privacy_request_transition_v2','1',true);
  v_event_id:=ops.enqueue_outbox(
    'privacy_request',v_request.id::text,v_decision_version,
    'privacy.request_identity_verified.v1',v_event_payload,v_now
  );
  v_event_digest:=ops.r6d_outbox_envelope_digest_v1(v_event_id);
  IF v_event_digest IS NULL OR NOT ops.r6d_lower_sha256(v_event_digest) THEN
    RAISE EXCEPTION 'privacy_identity_verification_event_invalid'
      USING ERRCODE='23514';
  END IF;
  v_outbox_event_ids:=ARRAY[v_event_id]::uuid[];
  v_transition_payload:=jsonb_build_object(
    'schemaVersion','privacy-request-transition-receipt.v2',
    'transitionReceiptId',v_transition_receipt_id,
    'retentionRequestId',v_request.id,
    'decisionVersion',v_decision_version,
    'transition','VERIFY_IDENTITY',
    'priorState','RECEIVED',
    'state','RECEIVED',
    'reasonCode',v_reason_code,
    'reasonDigest',btrim(v_reason_sha256),
    'reasonAadDigest',btrim(v_reason_aad_digest),
    'extensionReasonCode',NULL,
    'extensionReasonDigest',NULL,
    'extensionReasonAadDigest',NULL,
    'rejectionReasonCode',NULL,
    'rejectionReasonDigest',NULL,
    'rejectionReasonAadDigest',NULL,
    'appealInstructionsDigest',NULL,
    'appealInstructionsAadDigest',NULL,
    'encryptionKeyId',v_encryption_key_id,
    'actorId',p_actor_id,
    'actorAssertionJti',v_actor_assertion_jti,
    'actorAssertionRequestDigest',btrim(
      v_actor_assertion_request_digest
    ),
    'actorActionDigest',btrim(v_actor_action_digest),
    'stepUpAuthorizationId',v_step_up_authorization_id,
    'stepUpReceiptDigest',btrim(v_step_up_receipt_digest),
    'idempotencyKeySha256',btrim(p_idempotency_key_sha256),
    'requestSha256',btrim(p_request_sha256),
    'identityReceiptId',v_identity_receipt_id,
    'identityReceiptDigest',btrim(v_identity_digest),
    'extensionReceiptId',NULL,
    'extensionReceiptDigest',NULL,
    'refusalReceiptId',NULL,
    'refusalReceiptDigest',NULL,
    'noticeReceiptId',v_notice_receipt_id,
    'noticeReceiptDigest',btrim(v_notice_digest),
    'decisionDigest',NULL,
    'decidedAt',v_now
  );
  v_transition_canonical:=ops.canonical_jsonb_v1(v_transition_payload);
  v_transition_digest:=encode(extensions.digest(
    v_transition_canonical,'sha256'
  ),'hex');
  v_consumption_payload:=jsonb_build_object(
    'schemaVersion','privacy-identity-proof-consumption-receipt.v1',
    'consumptionReceiptId',v_consumption_receipt_id,
    'identityProofReceiptId',v_authority.identity_proof_receipt_id,
    'identityProofReceiptDigest',btrim(v_authority.receipt_digest),
    'privacyRequestId',v_request.id,
    'subjectProofHash',btrim(v_request.subject_proof_hash),
    'exactScopeDigest',btrim(v_request.scope_sha256),
    'identityReceiptId',v_identity_receipt_id,
    'identityReceiptDigest',btrim(v_identity_digest),
    'transitionReceiptId',v_transition_receipt_id,
    'transitionReceiptDigest',btrim(v_transition_digest),
    'actorId',p_actor_id,
    'consumedAt',v_now
  );
  v_consumption_canonical:=ops.canonical_jsonb_v1(v_consumption_payload);
  v_consumption_digest:=encode(extensions.digest(
    v_consumption_canonical,'sha256'
  ),'hex');
  v_audit_event_id:=ops.append_audit_event(
    'privacy-request:'||v_request.id::text,
    'USER',p_actor_id::text,p_session_id,
    'command.transitionRetentionRequest','PRIVACY_REQUEST',
    v_request.id::text,'privacy.requests.manage','SUCCESS',
    v_reason_code,p_request_id,jsonb_build_object(
      'decisionVersion',v_decision_version,
      'transition','VERIFY_IDENTITY',
      'identityProofReceiptId',v_authority.identity_proof_receipt_id,
      'identityProofReceiptDigest',btrim(v_authority.receipt_digest),
      'scopeInventoryId',v_inventory.scope_inventory_id,
      'scopeInventoryDigest',btrim(v_inventory.receipt_digest),
      'contactEndpointId',v_endpoint.id,
      'contactVerificationId',v_contact_verification.id,
      'identityReceiptId',v_identity_receipt_id,
      'identityReceiptDigest',btrim(v_identity_digest),
      'noticeReceiptId',v_notice_receipt_id,
      'noticeReceiptDigest',btrim(v_notice_digest),
      'transitionReceiptId',v_transition_receipt_id,
      'transitionReceiptDigest',btrim(v_transition_digest),
      'consumptionReceiptId',v_consumption_receipt_id,
      'consumptionReceiptDigest',btrim(v_consumption_digest),
      'eventId',v_event_id,
      'eventDigest',btrim(v_event_digest),
      'stepUpReceiptDigest',btrim(v_step_up_receipt_digest),
      'responsePolicyId',v_policy.policy_id,
      'responsePolicyRevision',v_policy.revision,
      'responsePolicyDigest',btrim(v_policy.policy_digest),
      'calendarVersionId',v_calendar.id,
      'calendarDigest',btrim(v_calendar.calendar_digest),
      'dueAt',v_due_at
    )
  );

  INSERT INTO ops.privacy_request_identity_receipts_v2(
    identity_receipt_id,privacy_request_id,decision_version,
    identity_proof_receipt_id,identity_proof_receipt_digest,
    prior_identity_state,identity_state,identity_verified_at,due_at,
    response_policy_id,response_policy_revision,response_policy_version,
    response_policy_digest,calendar_version_id,calendar_digest,
    notice_receipt_id,notice_receipt_digest,event_receipt_id,
    event_receipt_digest,receipt_payload,receipt_canonical,
    receipt_digest,verified_at
  ) VALUES(
    v_identity_receipt_id,v_request.id,v_decision_version,
    v_authority.identity_proof_receipt_id,v_authority.receipt_digest,
    'PENDING_VERIFICATION','VERIFIED',v_now,v_due_at,
    v_policy.policy_id,v_policy.revision,v_policy.policy_version,
    v_policy.policy_digest,v_calendar.id,v_calendar.calendar_digest,
    v_notice_receipt_id,v_notice_digest,v_event_id,v_event_digest,
    v_identity_payload,v_identity_canonical,v_identity_digest,v_now
  );
  INSERT INTO ops.privacy_request_notice_receipts_v2(
    notice_receipt_id,privacy_request_id,notice_sequence,notice_kind,
    transition_receipt_id,endpoint_id,endpoint_version,endpoint_digest,
    endpoint_aad_digest,encryption_key_id,notice_sha256,
    notice_aad_digest,notice_template_payload,notice_template_digest,
    branch_receipt_id,branch_receipt_digest,event_receipt_id,
    event_receipt_digest,receipt_payload,receipt_canonical,
    receipt_digest,created_at
  ) VALUES(
    v_notice_receipt_id,v_request.id,v_notice_sequence,
    'IDENTITY_VERIFIED',v_transition_receipt_id,v_endpoint.id,
    v_endpoint.version,v_endpoint.endpoint_digest,
    v_endpoint.endpoint_aad_digest,v_endpoint.encryption_key_id,
    v_notice_template_digest,v_notice_aad_digest,v_notice_template,
    v_notice_template_digest,v_identity_receipt_id,v_identity_digest,
    v_event_id,v_event_digest,v_notice_payload,v_notice_canonical,
    v_notice_digest,v_now
  );
  INSERT INTO ops.privacy_request_transition_receipts_v2(
    transition_receipt_id,privacy_request_id,decision_version,
    transition,prior_state,state,reason_code,reason_sha256,
    reason_aad_digest,encryption_key_id,actor_id,actor_assertion_jti,
    actor_action_digest,step_up_authorization_id,
    idempotency_key_sha256,request_sha256,identity_receipt_id,
    identity_receipt_digest,notice_receipt_id,notice_receipt_digest,
    event_receipt_id,event_receipt_digest,audit_event_id,
    outbox_event_ids,receipt_payload,receipt_canonical,receipt_digest,
    decided_at
  ) VALUES(
    v_transition_receipt_id,v_request.id,v_decision_version,
    'VERIFY_IDENTITY','RECEIVED','RECEIVED',v_reason_code,
    v_reason_sha256,v_reason_aad_digest,v_encryption_key_id,p_actor_id,
    v_actor_assertion_jti,v_actor_action_digest,
    v_step_up_authorization_id,p_idempotency_key_sha256,p_request_sha256,
    v_identity_receipt_id,v_identity_digest,v_notice_receipt_id,
    v_notice_digest,v_event_id,v_event_digest,v_audit_event_id,
    v_outbox_event_ids,v_transition_payload,v_transition_canonical,
    v_transition_digest,v_now
  );
  INSERT INTO ops.privacy_request_sealed_content_v2(
    privacy_request_id,transition_receipt_id,field_kind,
    sealed_ciphertext,sealed_sha256,sealed_aad_digest,encryption_key_id
  ) VALUES(
    v_request.id,v_transition_receipt_id,'REASON',v_reason_ciphertext,
    v_reason_sha256,v_reason_aad_digest,v_encryption_key_id
  );
  INSERT INTO ops.privacy_identity_proof_consumption_receipts_v1(
    consumption_receipt_id,identity_proof_receipt_id,
    identity_proof_receipt_digest,privacy_request_id,subject_proof_hash,
    exact_scope_digest,transition_receipt_id,actor_id,receipt_payload,
    receipt_canonical,receipt_digest,consumed_at
  ) VALUES(
    v_consumption_receipt_id,v_authority.identity_proof_receipt_id,
    v_authority.receipt_digest,v_request.id,v_request.subject_proof_hash,
    v_request.scope_sha256,v_transition_receipt_id,p_actor_id,
    v_consumption_payload,v_consumption_canonical,v_consumption_digest,v_now
  );
  UPDATE ops.privacy_requests_v2
  SET decision_version=v_decision_version,
      identity_state='VERIFIED',identity_verified_at=v_now,due_at=v_due_at,
      response_policy_id=v_policy.policy_id,
      response_policy_revision=v_policy.revision,
      response_policy_digest=v_policy.policy_digest,
      calendar_version_id=v_calendar.id,
      calendar_digest=v_calendar.calendar_digest,
      current_identity_receipt_id=v_identity_receipt_id,
      current_identity_receipt_digest=v_identity_digest,
      current_notice_receipt_id=v_notice_receipt_id,
      current_notice_receipt_digest=v_notice_digest,
      updated_at=v_now
  WHERE id=v_request.id AND decision_version=v_request.decision_version;
  GET DIAGNOSTICS v_affected=ROW_COUNT;
  IF v_affected<>1 THEN
    RAISE EXCEPTION 'privacy_identity_verification_version_conflict'
      USING ERRCODE='PVT08';
  END IF;

  v_transition_response:=jsonb_build_object(
    'retentionRequestId',v_request.id,
    'decisionVersion',v_decision_version,
    'requestType',v_request.request_type,
    'state','RECEIVED',
    'transition','VERIFY_IDENTITY',
    'transitionReceiptId',v_transition_receipt_id,
    'transitionReceiptDigest',btrim(v_transition_digest),
    'identityVerifiedAt',v_now,
    'dueAt',v_due_at,
    'policyVersion',v_policy.policy_version,
    'policyDigest',btrim(v_policy.policy_digest),
    'calendarVersionId',v_calendar.id,
    'calendarDigest',btrim(v_calendar.calendar_digest),
    'identityReceiptId',v_identity_receipt_id,
    'identityReceiptDigest',btrim(v_identity_digest),
    'extensionReceiptId',NULL,
    'extensionReceiptDigest',NULL,
    'refusalReceiptId',NULL,
    'refusalReceiptDigest',NULL,
    'noticeReceiptId',v_notice_receipt_id,
    'noticeReceiptDigest',btrim(v_notice_digest),
    'appealInstructionsDigest',NULL,
    'updatedAt',v_now,
    'replayed',false
  );
  v_result:=jsonb_build_object(
    'requestId',p_request_id,
    'aggregateId',v_request.id,
    'aggregateVersion',v_decision_version,
    'status','COMPLETED',
    'acceptedAt',v_now,
    'receiptDigest',btrim(v_transition_digest),
    'auditEventId',v_audit_event_id,
    'outboxEventIds',to_jsonb(v_outbox_event_ids),
    'emittedEventIds',to_jsonb(v_outbox_event_ids),
    'links','[]'::jsonb,
    'transition',v_transition_response
  );
  RETURN v_result;
END
$verify_privacy_identity$;
ALTER FUNCTION ops.verify_privacy_request_identity_v3(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.verify_privacy_request_identity_v3(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.verify_privacy_request_identity_v3(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- A correction request's free-form statement remains explanatory.  The plan
-- below is the immutable, typed human assertion that names one normalized
-- scope member, one syntactically bounded JSON Pointer, the reviewer's asserted
-- current-value digest, and the evidence set.  It deliberately does not claim
-- a per-object mutable-field catalog, read the target value, or mutate a target.
CREATE TABLE ops.privacy_correction_plans_v1 (
  correction_plan_id uuid PRIMARY KEY,
  privacy_request_id uuid NOT NULL
    REFERENCES ops.privacy_requests_v2(id) ON DELETE RESTRICT,
  plan_version bigint NOT NULL,
  request_decision_version bigint NOT NULL,
  scope_inventory_id uuid NOT NULL
    REFERENCES ops.privacy_request_scope_inventories_v1(scope_inventory_id)
    ON DELETE RESTRICT,
  target_object_type text NOT NULL,
  target_object_id uuid NOT NULL,
  scope_item_digest char(64) NOT NULL,
  field_path text NOT NULL,
  field_path_syntax text NOT NULL,
  field_path_digest char(64) NOT NULL,
  current_value_digest char(64) NOT NULL,
  current_value_authority text NOT NULL,
  requested_value_ciphertext bytea NOT NULL,
  requested_value_sha256 char(64) NOT NULL,
  requested_value_aad_digest char(64) NOT NULL,
  requested_value_ciphertext_digest char(64) NOT NULL,
  encryption_key_id text NOT NULL,
  evidence_ids uuid[] NOT NULL,
  evidence_snapshot_payload jsonb NOT NULL,
  evidence_set_digest char(64) NOT NULL,
  reason_digest char(64) NOT NULL,
  actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  session_id uuid NOT NULL REFERENCES ops.sessions(id) ON DELETE RESTRICT,
  actor_assertion_jti uuid NOT NULL UNIQUE,
  actor_action_digest char(64) NOT NULL,
  step_up_authorization_id uuid NOT NULL UNIQUE
    REFERENCES ops.step_up_authorizations(id) ON DELETE RESTRICT,
  step_up_receipt_digest char(64) NOT NULL,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  plan_payload jsonb NOT NULL,
  plan_canonical bytea NOT NULL,
  plan_digest char(64) NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL,
  UNIQUE(privacy_request_id,plan_version),
  UNIQUE(correction_plan_id,requested_value_sha256),
  CONSTRAINT privacy_correction_plans_v1_scope_item_fk FOREIGN KEY(
    scope_inventory_id,target_object_type,target_object_id
  ) REFERENCES ops.privacy_request_scope_inventory_items_v1(
    scope_inventory_id,object_kind,object_id
  ) ON DELETE RESTRICT,
  CONSTRAINT privacy_correction_plans_v1_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(
    id,record_class,schedule_digest
  ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT privacy_correction_plans_v1_class_fk FOREIGN KEY(
    retention_record_class
  ) REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  CONSTRAINT privacy_correction_plans_v1_shape_ck CHECK(
    plan_version>0 AND request_decision_version>0
    AND target_object_type IN (
      'RESPONSE','CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT',
      'PUBLICATION','EVIDENCE','AUDIT_SUBJECT_RECORD'
    )
    AND target_object_id<>'00000000-0000-0000-0000-000000000000'::uuid
    AND length(field_path) BETWEEN 1 AND 1000
    AND field_path_syntax='RFC6901_ABSOLUTE_POINTER_V1'
    -- RFC 6901 permits the root member name `/`, empty tokens (`/a//b`), and
    -- escaped `~0`/`~1`; it forbids only invalid tilde escapes and controls.
    AND field_path ~ '^/([^~[:cntrl:]]|~[01])*$'
    AND current_value_authority='HUMAN_REVIEWER_ASSERTION'
    AND octet_length(requested_value_ciphertext) BETWEEN 1 AND 65536
    AND length(encryption_key_id) BETWEEN 1 AND 200
    AND btrim(encryption_key_id)=encryption_key_id
    AND ops.r6d_field_envelope_v1_is_valid(
      requested_value_ciphertext,encryption_key_id
    )
    AND cardinality(evidence_ids) BETWEEN 1 AND 100
    AND ops.uuid_array_is_sorted_unique(evidence_ids)
    AND jsonb_typeof(evidence_snapshot_payload)='array'
    AND jsonb_array_length(evidence_snapshot_payload)=cardinality(evidence_ids)
    AND retention_record_class='PRIVACY_REQUEST_SEALED_CONTENT'
    AND expires_at>created_at
    AND ops.r6d_lower_sha256(scope_item_digest)
    AND ops.r6d_lower_sha256(field_path_digest)
    AND ops.r6d_lower_sha256(current_value_digest)
    AND ops.r6d_lower_sha256(requested_value_sha256)
    AND ops.r6d_lower_sha256(requested_value_aad_digest)
    AND ops.r6d_lower_sha256(requested_value_ciphertext_digest)
    AND requested_value_ciphertext_digest=encode(extensions.digest(
      requested_value_ciphertext,'sha256'
    ),'hex')
    AND requested_value_aad_digest=ops.r6d_nul5_sha256_v1(
      'ops.privacy_correction_plans_v1','requested_value_ciphertext',
      correction_plan_id::text,'privacy-correction-requested-value','1'
    )
    AND ops.r6d_lower_sha256(evidence_set_digest)
    AND ops.r6d_lower_sha256(reason_digest)
    AND ops.r6d_lower_sha256(actor_action_digest)
    AND ops.r6d_lower_sha256(step_up_receipt_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND convert_from(plan_canonical,'UTF8')::jsonb=plan_payload
    AND plan_canonical=ops.canonical_jsonb_v1(plan_payload)
    AND plan_digest=encode(
      extensions.digest(plan_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE ops.privacy_correction_plans_v1 OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_correction_plans_v1 FROM PUBLIC;
REVOKE ALL ON ops.privacy_correction_plans_v1
  FROM gurine_submission_api,gurine_workflow_worker,
    gurine_notification_worker,gurine_scheduler,gurine_control_api,
    gurine_auditor;
CREATE TRIGGER privacy_correction_plans_v1_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_correction_plans_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE OR REPLACE FUNCTION ops.bind_privacy_correction_plan_schedule_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $plan_schedule$
DECLARE
  v_schedule ops.record_class_schedules%ROWTYPE;
  v_count bigint;
BEGIN
  IF num_nonnulls(
       NEW.retention_schedule_id,NEW.retention_record_class,
       NEW.retention_schedule_digest,NEW.expires_at
     )<>0 OR NEW.created_at IS NULL OR NOT isfinite(NEW.created_at) THEN
    RAISE EXCEPTION 'privacy_correction_plan_schedule_input_invalid'
      USING ERRCODE='55000';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM ops.r6d_record_class_catalog AS catalog
    WHERE catalog.record_class='PRIVACY_REQUEST_SEALED_CONTENT'
      AND catalog.required_terminal_action='CRYPTO_ERASE'
      AND catalog.pii_write
  ) THEN
    RAISE EXCEPTION 'privacy_correction_plan_record_class_missing'
      USING ERRCODE='55000';
  END IF;
  LOCK TABLE ops.record_class_schedules IN SHARE MODE;
  SELECT count(*)
  INTO v_count
  FROM ops.record_class_schedules AS schedule
  WHERE schedule.record_class='PRIVACY_REQUEST_SEALED_CONTENT'
    AND schedule.trigger_kind='CREATED_AT'
    AND schedule.terminal_action='CRYPTO_ERASE'
    AND schedule.active_duration_seconds>0
    AND schedule.backup_duration_seconds IS NOT NULL
    AND schedule.effective_at<=NEW.created_at
    AND schedule.review_expires_at>NEW.created_at;
  IF v_count=0 THEN
    RAISE EXCEPTION 'privacy_correction_plan_schedule_missing'
      USING ERRCODE='55000';
  ELSIF v_count<>1 THEN
    RAISE EXCEPTION 'privacy_correction_plan_schedule_ambiguous'
      USING ERRCODE='55000';
  END IF;
  SELECT schedule.* INTO STRICT v_schedule
  FROM ops.record_class_schedules AS schedule
  WHERE schedule.record_class='PRIVACY_REQUEST_SEALED_CONTENT'
    AND schedule.trigger_kind='CREATED_AT'
    AND schedule.terminal_action='CRYPTO_ERASE'
    AND schedule.active_duration_seconds>0
    AND schedule.backup_duration_seconds IS NOT NULL
    AND schedule.effective_at<=NEW.created_at
    AND schedule.review_expires_at>NEW.created_at
  FOR SHARE;
  NEW.expires_at:=NEW.created_at+
    (v_schedule.active_duration_seconds*interval '1 second');
  NEW.retention_schedule_id:=v_schedule.id;
  NEW.retention_record_class:=v_schedule.record_class;
  NEW.retention_schedule_digest:=v_schedule.schedule_digest;
  RETURN NEW;
END
$plan_schedule$;
ALTER FUNCTION ops.bind_privacy_correction_plan_schedule_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.bind_privacy_correction_plan_schedule_v1()
  FROM PUBLIC;
CREATE TRIGGER privacy_correction_plans_v1_retention_bind
  BEFORE INSERT ON ops.privacy_correction_plans_v1
  FOR EACH ROW
  EXECUTE FUNCTION ops.bind_privacy_correction_plan_schedule_v1();

CREATE OR REPLACE FUNCTION ops.create_privacy_correction_plan_v1(
  p_payload jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_sha256 char(64)
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $create_correction_plan$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_privacy_request_id uuid;
  v_expected_decision_version bigint;
  v_plan_id uuid;
  v_target_kind text;
  v_target_id uuid;
  v_field_path text;
  v_field_path_digest char(64);
  v_current_value_digest char(64);
  v_requested_value_ciphertext bytea;
  v_requested_value_sha256 char(64);
  v_requested_value_aad_digest char(64);
  v_requested_value_ciphertext_digest char(64);
  v_encryption_key_id text;
  v_evidence_ids uuid[];
  v_evidence_input_count bigint;
  v_evidence_distinct_count bigint;
  v_evidence_row_count bigint;
  v_evidence_snapshot jsonb;
  v_evidence_set_digest char(64);
  v_reason text;
  v_reason_digest char(64);
  v_actor_assertion_jti uuid;
  v_actor_assertion_request_digest char(64);
  v_actor_action_digest char(64);
  v_step_up_authorization_id uuid;
  v_step_up_receipt_digest char(64);
  v_idempotency ops.idempotency_keys%ROWTYPE;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_inventory ops.privacy_request_scope_inventories_v1%ROWTYPE;
  v_scope_item ops.privacy_request_scope_inventory_items_v1%ROWTYPE;
  v_plan_count bigint;
  v_plan_max_version bigint;
  v_plan_version bigint;
  v_plan_payload jsonb;
  v_plan_canonical bytea;
  v_plan_digest char(64);
  v_audit_event_id uuid;
  v_inserted ops.privacy_correction_plans_v1%ROWTYPE;
  v_result jsonb;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_payload))<>19
     OR NOT p_payload ?& ARRAY[
       'retentionRequestId','expectedDecisionVersion','targetObjectType',
       'targetObjectId','fieldPath','currentValueDigest','evidenceIds','reason',
       '_correctionPlanId','requestedValueCiphertextBase64',
       'requestedValueSha256','_actorAssertionJti','_actorAssuranceLevel',
       '_actorEffectiveCapability','_actorAssertionRequestSha256',
       '_actorActionDigest',
       '_actorStepUpAuthorizationId','_actorIdempotencyKeySha256',
       '_actorRequestKeySha256'
     ]
     OR jsonb_typeof(p_payload->'retentionRequestId')<>'string'
     OR jsonb_typeof(p_payload->'expectedDecisionVersion')<>'number'
     OR p_payload->>'expectedDecisionVersion' !~ '^(0|[1-9][0-9]{0,18})$'
     OR jsonb_typeof(p_payload->'targetObjectType')<>'string'
     OR jsonb_typeof(p_payload->'targetObjectId')<>'string'
     OR jsonb_typeof(p_payload->'fieldPath')<>'string'
     OR jsonb_typeof(p_payload->'currentValueDigest')<>'string'
     OR jsonb_typeof(p_payload->'evidenceIds')<>'array'
     OR jsonb_typeof(p_payload->'reason')<>'string'
     OR jsonb_typeof(p_payload->'_correctionPlanId')<>'string'
     OR jsonb_typeof(p_payload->'requestedValueCiphertextBase64')<>'string'
     OR jsonb_typeof(p_payload->'requestedValueSha256')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssertionJti')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssuranceLevel')<>'string'
     OR jsonb_typeof(p_payload->'_actorEffectiveCapability')<>'string'
     OR jsonb_typeof(
       p_payload->'_actorAssertionRequestSha256'
     )<>'string'
     OR jsonb_typeof(p_payload->'_actorActionDigest')<>'string'
     OR jsonb_typeof(p_payload->'_actorStepUpAuthorizationId')<>'string'
     OR jsonb_typeof(p_payload->'_actorIdempotencyKeySha256')<>'string'
     OR jsonb_typeof(p_payload->'_actorRequestKeySha256')<>'string'
     OR p_payload ? 'requestedValue'
     OR p_payload ? '_requestedValueAadDigest'
     OR p_actor_id IS NULL OR p_session_id IS NULL OR p_request_id IS NULL
     OR NOT ops.r6d_lower_sha256(p_idempotency_key_sha256)
     OR NOT ops.r6d_lower_sha256(p_request_sha256)
     OR NOT ops.r6d_lower_sha256(p_payload->>'currentValueDigest')
     OR NOT ops.r6d_lower_sha256(p_payload->>'requestedValueSha256')
     OR NOT ops.r6d_lower_sha256(
       p_payload->>'_actorAssertionRequestSha256'
     )
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorActionDigest')
     OR NOT ops.r6d_lower_sha256(
       p_payload->>'_actorIdempotencyKeySha256'
     )
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorRequestKeySha256')
     OR p_payload->>'_actorAssuranceLevel'<>'STEP_UP'
     OR p_payload->>'_actorEffectiveCapability'<>
       'privacy.requests.manage'
     OR p_payload->>'_actorIdempotencyKeySha256'<>
       btrim(p_idempotency_key_sha256)
     OR p_payload->>'_actorRequestKeySha256'<>
       btrim(p_idempotency_key_sha256)
     OR current_setting('transaction_isolation')<>'serializable' THEN
    RAISE EXCEPTION 'privacy_correction_plan_input_invalid'
      USING ERRCODE='22023';
  END IF;

  BEGIN
    v_privacy_request_id:=(p_payload->>'retentionRequestId')::uuid;
    v_expected_decision_version:=
      (p_payload->>'expectedDecisionVersion')::bigint;
    v_plan_id:=(p_payload->>'_correctionPlanId')::uuid;
    v_target_id:=(p_payload->>'targetObjectId')::uuid;
    v_actor_assertion_jti:=(p_payload->>'_actorAssertionJti')::uuid;
    v_step_up_authorization_id:=
      (p_payload->>'_actorStepUpAuthorizationId')::uuid;
    v_requested_value_ciphertext:=decode(
      p_payload->>'requestedValueCiphertextBase64','base64'
    );
    v_encryption_key_id:=split_part(
      convert_from(v_requested_value_ciphertext,'UTF8'),'.',2
    );
    SELECT array_agg(parsed.evidence_id ORDER BY parsed.evidence_id),
      count(*),count(DISTINCT parsed.evidence_id)
    INTO v_evidence_ids,v_evidence_input_count,v_evidence_distinct_count
    FROM (
      SELECT (element.value#>>'{}')::uuid AS evidence_id
      FROM jsonb_array_elements(p_payload->'evidenceIds') AS element(value)
      WHERE jsonb_typeof(element.value)='string'
    ) AS parsed;
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range
      OR invalid_parameter_value OR character_not_in_repertoire
      OR untranslatable_character THEN
    RAISE EXCEPTION 'privacy_correction_plan_input_invalid'
      USING ERRCODE='22023';
  END;

  v_target_kind:=p_payload->>'targetObjectType';
  v_field_path:=p_payload->>'fieldPath';
  v_current_value_digest:=
    (p_payload->>'currentValueDigest')::char(64);
  v_actor_assertion_request_digest:=
    (p_payload->>'_actorAssertionRequestSha256')::char(64);
  v_requested_value_sha256:=
    (p_payload->>'requestedValueSha256')::char(64);
  v_actor_action_digest:=
    (p_payload->>'_actorActionDigest')::char(64);
  v_reason:=p_payload->>'reason';
  IF v_privacy_request_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_plan_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_target_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_actor_assertion_jti=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_step_up_authorization_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_target_kind NOT IN (
       'RESPONSE','CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT',
       'PUBLICATION','EVIDENCE','AUDIT_SUBJECT_RECORD'
     )
     OR length(v_field_path) NOT BETWEEN 1 AND 1000
     OR v_field_path !~ '^/([^~[:cntrl:]]|~[01])*$'
     OR length(v_reason) NOT BETWEEN 1 AND 4000
     OR btrim(v_reason)<>v_reason
     OR v_evidence_input_count NOT BETWEEN 1 AND 100
     OR v_evidence_input_count<>v_evidence_distinct_count
     OR cardinality(v_evidence_ids)<>v_evidence_input_count
     OR NOT ops.uuid_array_is_sorted_unique(v_evidence_ids)
     OR to_jsonb(v_evidence_ids)<>p_payload->'evidenceIds'
     OR EXISTS(
       SELECT 1 FROM unnest(v_evidence_ids) AS evidence_id
       WHERE evidence_id='00000000-0000-0000-0000-000000000000'::uuid
     )
     OR octet_length(v_requested_value_ciphertext) NOT BETWEEN 1 AND 65536
     OR replace(encode(v_requested_value_ciphertext,'base64'),E'\n','')<>
       p_payload->>'requestedValueCiphertextBase64'
     OR length(v_encryption_key_id) NOT BETWEEN 1 AND 200
     OR btrim(v_encryption_key_id)<>v_encryption_key_id
     OR NOT ops.r6d_field_envelope_v1_is_valid(
       v_requested_value_ciphertext,v_encryption_key_id
     ) THEN
    RAISE EXCEPTION 'privacy_correction_plan_input_invalid'
      USING ERRCODE='22023';
  END IF;
  v_field_path_digest:=encode(extensions.digest(
    convert_to(v_field_path,'UTF8'),'sha256'
  ),'hex');
  v_reason_digest:=encode(extensions.digest(
    convert_to(v_reason,'UTF8'),'sha256'
  ),'hex');
  v_requested_value_aad_digest:=ops.r6d_nul5_sha256_v1(
    'ops.privacy_correction_plans_v1','requested_value_ciphertext',
    v_plan_id::text,'privacy-correction-requested-value','1'
  );
  v_requested_value_ciphertext_digest:=encode(extensions.digest(
    v_requested_value_ciphertext,'sha256'
  ),'hex');

  -- Control owns replay and final response persistence.  This private owner
  -- accepts only the live, completely open preclaim held by that transaction.
  SELECT claim.* INTO v_idempotency
  FROM ops.idempotency_keys AS claim
  WHERE claim.scope=
      'control:'||p_actor_id::text||':createPrivacyCorrectionPlan'
    AND claim.key_hash=p_idempotency_key_sha256
  FOR UPDATE;
  IF NOT FOUND OR v_idempotency.expires_at<=v_now
     OR v_idempotency.request_hash<>p_request_sha256
     OR num_nonnulls(
       v_idempotency.response_status,v_idempotency.resource_type,
       v_idempotency.resource_id,v_idempotency.response_body
     )<>0 THEN
    RAISE EXCEPTION 'privacy_correction_plan_idempotency_conflict'
      USING ERRCODE='40001';
  END IF;

  SELECT request.* INTO v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=v_privacy_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_correction_plan_request_not_found'
      USING ERRCODE='P0002';
  END IF;
  IF v_request.decision_version<>v_expected_decision_version THEN
    RAISE EXCEPTION 'privacy_correction_plan_version_conflict'
      USING ERRCODE='PVT08';
  END IF;
  IF v_request.request_type<>'CORRECTION' OR v_request.state<>'REVIEW'
     OR v_request.identity_state<>'VERIFIED'
     OR v_request.identity_verified_at IS NULL OR v_request.due_at IS NULL
     OR num_nonnulls(
       v_request.response_policy_id,v_request.response_policy_revision,
       v_request.response_policy_digest,v_request.calendar_version_id,
       v_request.calendar_digest,v_request.current_identity_receipt_id,
       v_request.current_identity_receipt_digest
     )<>7 THEN
    RAISE EXCEPTION 'privacy_correction_plan_request_state_invalid'
      USING ERRCODE='PVT09';
  END IF;

  SELECT inventory.* INTO v_inventory
  FROM ops.privacy_request_scope_inventories_v1 AS inventory
  WHERE inventory.privacy_request_id=v_request.id
  FOR SHARE;
  SELECT item.* INTO v_scope_item
  FROM ops.privacy_request_scope_inventory_items_v1 AS item
  WHERE item.scope_inventory_id=v_inventory.scope_inventory_id
    AND item.privacy_request_id=v_request.id
    AND item.object_kind=v_target_kind
    AND item.object_id=v_target_id
  FOR SHARE;
  IF v_inventory.scope_inventory_id IS NULL OR v_scope_item.object_id IS NULL
     OR v_inventory.scope_digest<>v_request.scope_sha256
     OR v_inventory.subject_scope_digest<>v_request.subject_scope_digest
     OR NOT EXISTS(
       SELECT 1
       FROM ops.privacy_request_identity_receipts_v2 AS identity
       JOIN ops.privacy_identity_proof_authority_receipts_v1 AS authority
         ON authority.identity_proof_receipt_id=
           identity.identity_proof_receipt_id
        AND authority.receipt_digest=identity.identity_proof_receipt_digest
        AND authority.privacy_request_id=identity.privacy_request_id
       JOIN ops.privacy_identity_proof_consumption_receipts_v1 AS consumption
         ON consumption.identity_proof_receipt_id=
           authority.identity_proof_receipt_id
        AND consumption.privacy_request_id=authority.privacy_request_id
       JOIN ops.privacy_request_transition_receipts_v2 AS transition
         ON transition.transition_receipt_id=
           consumption.transition_receipt_id
        AND transition.privacy_request_id=identity.privacy_request_id
        AND transition.identity_receipt_id=identity.identity_receipt_id
        AND transition.identity_receipt_digest=identity.receipt_digest
       WHERE identity.identity_receipt_id=
           v_request.current_identity_receipt_id
         AND identity.receipt_digest=
           v_request.current_identity_receipt_digest
         AND authority.subject_proof_hash=v_request.subject_proof_hash
         AND authority.exact_scope_digest=v_request.scope_sha256
         AND consumption.subject_proof_hash=v_request.subject_proof_hash
         AND consumption.exact_scope_digest=v_request.scope_sha256
     ) THEN
    RAISE EXCEPTION 'privacy_correction_plan_scope_invalid'
      USING ERRCODE='PVT07';
  END IF;

  PERFORM evidence.id
  FROM editorial.evidence AS evidence
  WHERE evidence.id=ANY(v_evidence_ids)
  ORDER BY evidence.id
  FOR SHARE;
  SELECT count(*),COALESCE(jsonb_agg(jsonb_build_object(
    'evidenceId',evidence.id,
    'caseId',evidence.case_id,
    'version',evidence.version,
    'contentSha256',btrim(evidence.content_sha256),
    'classification',evidence.classification::text,
    'verificationStatus',evidence.verification_status,
    'verifiedBy',evidence.verified_by,
    'verifiedAt',evidence.verified_at,
    'sourceLocatorDigest',encode(extensions.digest(
      convert_to(evidence.source_locator,'UTF8'),'sha256'
    ),'hex')
  ) ORDER BY evidence.id),'[]'::jsonb)
  INTO v_evidence_row_count,v_evidence_snapshot
  FROM editorial.evidence AS evidence
  WHERE evidence.id=ANY(v_evidence_ids)
    AND evidence.verification_status='VERIFIED'
    AND evidence.verified_by IS NOT NULL
    AND evidence.verified_at IS NOT NULL
    AND evidence.verified_at<=v_now
    AND evidence.version>0
    AND ops.r6d_lower_sha256(evidence.content_sha256)
    AND NULLIF(btrim(evidence.source_locator),'') IS NOT NULL;
  IF v_evidence_row_count<>v_evidence_input_count THEN
    RAISE EXCEPTION 'privacy_correction_plan_evidence_invalid'
      USING ERRCODE='23514';
  END IF;
  v_evidence_set_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_evidence_snapshot),'sha256'
  ),'hex');

  PERFORM plan.correction_plan_id
  FROM ops.privacy_correction_plans_v1 AS plan
  WHERE plan.privacy_request_id=v_request.id
  ORDER BY plan.plan_version
  FOR UPDATE;
  SELECT count(*),COALESCE(max(plan.plan_version),0)
  INTO v_plan_count,v_plan_max_version
  FROM ops.privacy_correction_plans_v1 AS plan
  WHERE plan.privacy_request_id=v_request.id;
  IF v_plan_count<>v_plan_max_version THEN
    RAISE EXCEPTION 'privacy_correction_plan_chain_invalid'
      USING ERRCODE='23514';
  END IF;
  v_plan_version:=v_plan_max_version+1;

  v_step_up_receipt_digest:=ops.require_privacy_step_up_v3(
    p_actor_id,p_session_id,v_actor_assertion_jti,
    v_actor_assertion_request_digest,v_actor_action_digest,
    v_step_up_authorization_id,
    p_idempotency_key_sha256,'privacy.requests.manage',v_now
  );

  v_plan_payload:=jsonb_build_object(
    'schemaVersion','privacy-correction-plan.v1',
    'correctionPlanId',v_plan_id,
    'retentionRequestId',v_request.id,
    'planVersion',v_plan_version,
    'requestDecisionVersion',v_request.decision_version,
    'scopeInventoryId',v_inventory.scope_inventory_id,
    'scopeInventoryDigest',btrim(v_inventory.receipt_digest),
    'targetObjectType',v_target_kind,
    'targetObjectId',v_target_id,
    'scopeItemDigest',btrim(v_scope_item.item_digest),
    'fieldPath',v_field_path,
    'fieldPathSyntax','RFC6901_ABSOLUTE_POINTER_V1',
    'fieldPathDigest',btrim(v_field_path_digest),
    'currentValueDigest',btrim(v_current_value_digest),
    'currentValueAuthority','HUMAN_REVIEWER_ASSERTION',
    'requestedValueSha256',btrim(v_requested_value_sha256),
    'requestedValueAadDigest',btrim(v_requested_value_aad_digest),
    'requestedValueCiphertextDigest',
      btrim(v_requested_value_ciphertext_digest),
    'evidenceIds',to_jsonb(v_evidence_ids),
    'evidenceSnapshot',v_evidence_snapshot,
    'evidenceSetDigest',btrim(v_evidence_set_digest),
    'reasonDigest',btrim(v_reason_digest),
    'actorId',p_actor_id,
    'sessionId',p_session_id,
    'actorAssertionJti',v_actor_assertion_jti,
    'actorAssertionRequestDigest',btrim(
      v_actor_assertion_request_digest
    ),
    'actorActionDigest',btrim(v_actor_action_digest),
    'stepUpAuthorizationId',v_step_up_authorization_id,
    'stepUpReceiptDigest',btrim(v_step_up_receipt_digest),
    'requestId',p_request_id,
    'idempotencyKeySha256',btrim(p_idempotency_key_sha256),
    'requestDigest',btrim(p_request_sha256),
    'createdAt',v_now
  );
  v_plan_canonical:=ops.canonical_jsonb_v1(v_plan_payload);
  v_plan_digest:=encode(extensions.digest(
    v_plan_canonical,'sha256'
  ),'hex');
  v_audit_event_id:=ops.append_audit_event(
    'privacy-request:'||v_request.id::text,
    'USER',p_actor_id::text,p_session_id,
    'privacy.correction_plan.create','PRIVACY_CORRECTION_PLAN',
    v_plan_id::text,'privacy.requests.manage','SUCCESS',
    btrim(v_reason_digest),p_request_id,jsonb_build_object(
      'retentionRequestId',v_request.id,
      'requestDecisionVersion',v_request.decision_version,
      'correctionPlanId',v_plan_id,
      'planVersion',v_plan_version,
      'scopeInventoryDigest',btrim(v_inventory.receipt_digest),
      'targetObjectType',v_target_kind,
      'targetObjectId',v_target_id,
      'scopeItemDigest',btrim(v_scope_item.item_digest),
      'fieldPathDigest',btrim(v_field_path_digest),
      'currentValueDigest',btrim(v_current_value_digest),
      'requestedValueDigest',btrim(v_requested_value_sha256),
      'evidenceSetDigest',btrim(v_evidence_set_digest),
      'reasonDigest',btrim(v_reason_digest),
      'planDigest',btrim(v_plan_digest),
      'targetMutationCount',0
    )
  );

  INSERT INTO ops.privacy_correction_plans_v1(
    correction_plan_id,privacy_request_id,plan_version,
    request_decision_version,scope_inventory_id,target_object_type,
    target_object_id,scope_item_digest,field_path,field_path_syntax,
    field_path_digest,current_value_digest,current_value_authority,
    requested_value_ciphertext,requested_value_sha256,
    requested_value_aad_digest,requested_value_ciphertext_digest,
    encryption_key_id,evidence_ids,evidence_snapshot_payload,
    evidence_set_digest,reason_digest,actor_id,session_id,
    actor_assertion_jti,actor_action_digest,step_up_authorization_id,
    step_up_receipt_digest,request_id,idempotency_key_sha256,
    request_digest,audit_event_id,plan_payload,plan_canonical,plan_digest,
    created_at
  ) VALUES(
    v_plan_id,v_request.id,v_plan_version,v_request.decision_version,
    v_inventory.scope_inventory_id,v_target_kind,v_target_id,
    v_scope_item.item_digest,v_field_path,'RFC6901_ABSOLUTE_POINTER_V1',
    v_field_path_digest,v_current_value_digest,
    'HUMAN_REVIEWER_ASSERTION',v_requested_value_ciphertext,
    v_requested_value_sha256,v_requested_value_aad_digest,
    v_requested_value_ciphertext_digest,v_encryption_key_id,
    v_evidence_ids,v_evidence_snapshot,v_evidence_set_digest,
    v_reason_digest,p_actor_id,p_session_id,v_actor_assertion_jti,
    v_actor_action_digest,v_step_up_authorization_id,
    v_step_up_receipt_digest,p_request_id,p_idempotency_key_sha256,
    p_request_sha256,v_audit_event_id,v_plan_payload,v_plan_canonical,
    v_plan_digest,v_now
  ) RETURNING * INTO v_inserted;
  IF v_inserted.retention_record_class<>
       'PRIVACY_REQUEST_SEALED_CONTENT'
     OR v_inserted.expires_at<=v_inserted.created_at THEN
    RAISE EXCEPTION 'privacy_correction_plan_retention_binding_invalid'
      USING ERRCODE='23514';
  END IF;

  v_result:=jsonb_build_object(
    'correctionPlanId',v_plan_id,
    'privacyRequestId',v_request.id,
    'planVersion',v_plan_version,
    'planDigest',btrim(v_plan_digest),
    'auditEventId',v_audit_event_id,
    'createdAt',v_now,
    'replayed',false
  );
  RETURN v_result;
END
$create_correction_plan$;
ALTER FUNCTION ops.create_privacy_correction_plan_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.create_privacy_correction_plan_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.create_privacy_correction_plan_v1(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- R6d 0039 D3 privacy receipt exchange result adapter.
-- Apply after 0038; it is also compatible after the current D3 fragment.

ALTER FUNCTION ops.exchange_privacy_request_receipt_token_v2(
  char(64),char(64),text,uuid,char(64),char(64)
) RENAME TO exchange_privacy_request_receipt_token_v2_pre_r6d_0039_d3;
REVOKE ALL ON FUNCTION
  ops.exchange_privacy_request_receipt_token_v2_pre_r6d_0039_d3(
    char(64),char(64),text,uuid,char(64),char(64)
  ) FROM PUBLIC,gurine_submission_api;

CREATE OR REPLACE FUNCTION ops.exchange_privacy_request_receipt_token_v2(
  p_token_hmac char(64),
  p_next_session_sha256 char(64),
  p_bff_issuer text,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_sha256 char(64)
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,extensions,pg_temp
AS $exchange_adapter$
DECLARE
  v_old_result jsonb;
  v_old_base jsonb;
  v_expected_old_base jsonb;
  v_result jsonb;
  v_token ops.privacy_request_receipt_tokens_v2%ROWTYPE;
  v_session intake.submission_sessions%ROWTYPE;
  v_policy ops.privacy_request_access_policies_v1%ROWTYPE;
  v_idempotency ops.idempotency_keys%ROWTYPE;
  v_audit ops.audit_events%ROWTYPE;
  v_event ops.outbox%ROWTYPE;
  v_privacy_request_id uuid;
  v_session_id uuid;
  v_audit_event_id uuid;
  v_outbox_event_id uuid;
  v_issued_at timestamptz;
  v_expires_at timestamptz;
  v_expected_session_expires_at timestamptz;
  v_expected_token_expires_at timestamptz;
  v_receipt_digest char(64);
  v_expected_receipt_digest char(64);
  v_replayed boolean;
BEGIN
  IF p_token_hmac IS NULL OR NOT ops.r6d_lower_sha256(p_token_hmac)
     OR p_next_session_sha256 IS NULL
     OR NOT ops.r6d_lower_sha256(p_next_session_sha256)
     OR p_bff_issuer IS DISTINCT FROM 'public-web'
     OR p_request_id IS NULL
     OR p_request_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_idempotency_key_sha256 IS NULL
     OR NOT ops.r6d_lower_sha256(p_idempotency_key_sha256)
     OR p_request_sha256 IS NULL
     OR NOT ops.r6d_lower_sha256(p_request_sha256) THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_input_invalid'
      USING ERRCODE='22023';
  END IF;

  -- Preserve the 0038 owner's policy, idempotency and token lock ordering.
  -- Its exact replay returns before DML; a new key against a consumed token
  -- raises PVT03 and rolls its provisional idempotency claim back atomically.
  v_old_result:=
    ops.exchange_privacy_request_receipt_token_v2_pre_r6d_0039_d3(
      p_token_hmac,p_next_session_sha256,p_bff_issuer,p_request_id,
      p_idempotency_key_sha256,p_request_sha256
    );

  IF v_old_result IS NULL OR jsonb_typeof(v_old_result)<>'object' THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_result_adapter_invalid'
      USING ERRCODE='23514';
  END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(v_old_result))<>9
     OR NOT v_old_result ?& ARRAY[
       'requestId','sessionId','expiresAt','cookieName','tokenConsumedAt',
       'auditEventId','emittedEventIds','receiptDigest','replayed'
     ] THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_result_adapter_invalid'
      USING ERRCODE='23514';
  END IF;
  IF jsonb_typeof(v_old_result->'requestId')<>'string'
     OR jsonb_typeof(v_old_result->'sessionId')<>'string'
     OR jsonb_typeof(v_old_result->'expiresAt')<>'string'
     OR jsonb_typeof(v_old_result->'cookieName')<>'string'
     OR v_old_result->>'cookieName'<>
       'gurine_privacy_request_receipt_session'
     OR jsonb_typeof(v_old_result->'tokenConsumedAt')<>'string'
     OR jsonb_typeof(v_old_result->'auditEventId')<>'string'
     OR jsonb_typeof(v_old_result->'emittedEventIds')<>'array'
     OR jsonb_typeof(v_old_result->'receiptDigest')<>'string'
     OR NOT ops.r6d_lower_sha256(v_old_result->>'receiptDigest')
     OR jsonb_typeof(v_old_result->'replayed')<>'boolean' THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_result_adapter_invalid'
      USING ERRCODE='23514';
  END IF;
  IF jsonb_array_length(v_old_result->'emittedEventIds')<>1
     OR jsonb_typeof(v_old_result->'emittedEventIds'->0)<>'string' THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_result_adapter_invalid'
      USING ERRCODE='23514';
  END IF;

  BEGIN
    v_privacy_request_id:=(v_old_result->>'requestId')::uuid;
    v_session_id:=(v_old_result->>'sessionId')::uuid;
    v_expires_at:=(v_old_result->>'expiresAt')::timestamptz;
    v_issued_at:=(v_old_result->>'tokenConsumedAt')::timestamptz;
    v_audit_event_id:=(v_old_result->>'auditEventId')::uuid;
    v_outbox_event_id:=
      (v_old_result->'emittedEventIds'->>0)::uuid;
    v_receipt_digest:=(v_old_result->>'receiptDigest')::char(64);
    v_replayed:=(v_old_result->>'replayed')::boolean;
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range
      OR datetime_field_overflow THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_result_adapter_invalid'
      USING ERRCODE='23514';
  END;
  IF v_privacy_request_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_session_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_audit_event_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_outbox_event_id='00000000-0000-0000-0000-000000000000'::uuid
     OR NOT isfinite(v_issued_at) OR NOT isfinite(v_expires_at)
     OR v_expires_at<=v_issued_at THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_result_adapter_invalid'
      USING ERRCODE='23514';
  END IF;

  v_old_base:=v_old_result-'replayed';
  SELECT token.* INTO v_token
  FROM ops.privacy_request_receipt_tokens_v2 AS token
  WHERE token.token_hmac=p_token_hmac;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_closure_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT session.* INTO v_session
  FROM intake.submission_sessions AS session
  WHERE session.id=v_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_closure_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT policy.* INTO v_policy
  FROM ops.privacy_request_access_policies_v1 AS policy
  WHERE policy.policy_id=v_token.access_policy_id
    AND policy.revision=v_token.access_policy_revision;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_closure_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT claim.* INTO v_idempotency
  FROM ops.idempotency_keys AS claim
  WHERE claim.scope='PRIVACY_RECEIPT_EXCHANGE_V2'
    AND claim.key_hash=p_idempotency_key_sha256;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_closure_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT audit.* INTO v_audit
  FROM ops.audit_events AS audit
  WHERE audit.id=v_audit_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_closure_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT event.* INTO v_event
  FROM ops.outbox AS event
  WHERE event.id=v_outbox_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_closure_invalid'
      USING ERRCODE='23514';
  END IF;

  BEGIN
    v_expected_session_expires_at:=LEAST(
      v_policy.review_expires_at,
      v_issued_at+make_interval(
        secs=>v_policy.read_only_session_ttl_seconds::double precision
      )
    );
    v_expected_token_expires_at:=LEAST(
      v_policy.review_expires_at,
      v_token.created_at+make_interval(
        secs=>v_policy.token_ttl_seconds::double precision
      )
    );
  EXCEPTION
    WHEN datetime_field_overflow OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_closure_invalid'
      USING ERRCODE='23514';
  END;

  IF v_token.privacy_request_id IS DISTINCT FROM v_privacy_request_id
     OR v_token.operation_id IS DISTINCT FROM 'createPrivacyRequest'
     OR v_token.consumed_at IS DISTINCT FROM v_issued_at
     OR v_token.session_id IS DISTINCT FROM v_session_id
     OR v_token.session_token_sha256 IS DISTINCT FROM
       p_next_session_sha256
     OR v_token.exchange_receipt_digest IS DISTINCT FROM v_receipt_digest
     OR v_token.exchange_audit_event_id IS DISTINCT FROM v_audit_event_id
     OR v_token.exchange_outbox_event_id IS DISTINCT FROM v_outbox_event_id
     OR NOT isfinite(v_token.created_at)
     OR NOT isfinite(v_token.expires_at)
     OR v_token.created_at>v_issued_at
     OR v_token.expires_at IS DISTINCT FROM v_expected_token_expires_at
     OR v_token.consumed_at>=v_token.expires_at THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_closure_invalid'
      USING ERRCODE='23514';
  END IF;

  IF v_session.id IS DISTINCT FROM v_session_id
     OR v_session.token_hash IS DISTINCT FROM p_next_session_sha256
     OR v_session.session_kind IS DISTINCT FROM
       'PRIVACY_REQUEST_RECEIPT'
     OR v_session.scope_type IS DISTINCT FROM 'PRIVACY_REQUEST'
     OR v_session.scope_id IS DISTINCT FROM v_privacy_request_id
     OR v_session.bff_issuer IS DISTINCT FROM p_bff_issuer
     OR v_session.status IS DISTINCT FROM 'ACTIVE'
     OR v_session.version IS DISTINCT FROM 1
     OR v_session.issued_at IS DISTINCT FROM v_issued_at
     OR v_session.expires_at IS DISTINCT FROM v_expires_at
     OR v_session.expires_at IS DISTINCT FROM
       v_expected_session_expires_at
     OR num_nonnulls(
       v_session.last_used_at,v_session.consumed_at,v_session.revoked_at
     )<>0 THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_closure_invalid'
      USING ERRCODE='23514';
  END IF;

  IF v_policy.state IS DISTINCT FROM 'APPROVED'
     OR v_policy.allowed_operation IS DISTINCT FROM 'getPrivacyRequest'
     OR v_policy.bff_issuer IS DISTINCT FROM p_bff_issuer
     OR v_policy.cookie_profile_id IS DISTINCT FROM
       'privacy_request_receipt'
     OR v_policy.cookie_name IS DISTINCT FROM
       'gurine_privacy_request_receipt_session'
     OR v_policy.cookie_path IS DISTINCT FROM '/privacy'
     OR v_policy.same_site NOT IN ('LAX','STRICT')
     OR NOT v_policy.secure OR NOT v_policy.http_only
     OR v_policy.effective_at>v_token.created_at
     OR v_policy.review_expires_at<=v_issued_at
     OR v_expires_at>v_policy.review_expires_at
     OR ROW(
       v_token.access_policy_id,v_token.access_policy_revision,
       v_token.access_policy_digest,v_token.access_policy_binding_digest
     ) IS DISTINCT FROM ROW(
       v_policy.policy_id,v_policy.revision,v_policy.policy_digest,
       v_policy.binding_digest
     )
     OR ROW(
       v_session.privacy_access_policy_id,
       v_session.privacy_access_policy_revision,
       v_session.privacy_access_policy_digest,
       v_session.privacy_access_policy_binding_digest
     ) IS DISTINCT FROM ROW(
       v_policy.policy_id,v_policy.revision,v_policy.policy_digest,
       v_policy.binding_digest
     ) THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_closure_invalid'
      USING ERRCODE='23514';
  END IF;

  v_expected_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','privacy-request-session-receipt.v1',
      'requestId',v_privacy_request_id,
      'sessionId',v_session_id,
      'state','ACTIVE',
      'expiresAt',v_expires_at,
      'cookieName',v_policy.cookie_name,
      'tokenConsumedAt',v_issued_at,
      'accessPolicy',jsonb_build_object(
        'policyId',v_policy.policy_id,
        'revision',v_policy.revision,
        'policyVersion',v_policy.policy_version,
        'policyDigest',btrim(v_policy.policy_digest),
        'bindingDigest',btrim(v_policy.binding_digest),
        'cookiePath',v_policy.cookie_path,
        'sameSite',v_policy.same_site,
        'secure',v_policy.secure,
        'httpOnly',v_policy.http_only
      )
    )),'sha256'
  ),'hex');
  IF v_receipt_digest IS DISTINCT FROM v_expected_receipt_digest THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_digest_invalid'
      USING ERRCODE='23514';
  END IF;

  v_expected_old_base:=jsonb_build_object(
    'requestId',v_privacy_request_id,
    'sessionId',v_session_id,
    'expiresAt',v_expires_at,
    'cookieName',v_policy.cookie_name,
    'tokenConsumedAt',v_issued_at,
    'auditEventId',v_audit_event_id,
    'emittedEventIds',jsonb_build_array(v_outbox_event_id),
    'receiptDigest',btrim(v_receipt_digest)
  );
  IF v_old_base<>v_expected_old_base
     OR v_idempotency.request_hash IS DISTINCT FROM p_request_sha256
     OR v_idempotency.response_status IS DISTINCT FROM 200
     OR v_idempotency.response_body IS DISTINCT FROM v_expected_old_base
     OR v_idempotency.resource_type IS DISTINCT FROM
       'PrivacyRequestSession'
     OR v_idempotency.resource_id IS DISTINCT FROM v_session_id::text
     OR NOT isfinite(v_idempotency.created_at)
     OR NOT isfinite(v_idempotency.expires_at)
     OR v_idempotency.expires_at<=v_idempotency.created_at THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_idempotency_closure_invalid'
      USING ERRCODE='23514';
  END IF;

  IF v_audit.actor_type IS DISTINCT FROM 'SERVICE'
     OR v_audit.actor_id IS DISTINCT FROM p_bff_issuer
     OR v_audit.session_id IS NOT NULL
     OR v_audit.action IS DISTINCT FROM
       'command.exchangePrivacyRequestReceiptToken'
     OR v_audit.object_type IS DISTINCT FROM 'PRIVACY_REQUEST'
     OR v_audit.object_id IS DISTINCT FROM v_privacy_request_id::text
     OR v_audit.capability IS NOT NULL
     OR v_audit.outcome::text IS DISTINCT FROM 'SUCCESS'
     OR v_audit.reason IS NOT NULL
     OR v_audit.request_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR NOT isfinite(v_audit.occurred_at)
     OR v_audit.occurred_at<v_issued_at
     OR v_audit.details<>jsonb_build_object(
       'sessionId',v_session_id,
       'receiptDigest',btrim(v_receipt_digest),
       'sessionKind','PRIVACY_REQUEST_RECEIPT',
       'accessPolicyId',v_policy.policy_id,
       'accessPolicyRevision',v_policy.revision,
       'accessPolicyDigest',btrim(v_policy.policy_digest),
       'accessPolicyBindingDigest',btrim(v_policy.binding_digest)
     ) THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_audit_closure_invalid'
      USING ERRCODE='23514';
  END IF;

  IF v_event.aggregate_type IS DISTINCT FROM 'submission_session'
     OR v_event.aggregate_id IS DISTINCT FROM v_session_id::text
     OR v_event.aggregate_version IS DISTINCT FROM 1
     OR v_event.event_type IS DISTINCT FROM 'identity.session_created.v1'
     OR v_event.occurred_at IS DISTINCT FROM v_issued_at
     OR NOT isfinite(v_event.occurred_at)
     OR v_event.payload<>jsonb_build_object(
       'actor_id',p_bff_issuer,
       'occurred_at',v_issued_at,
       'operation_id','exchangePrivacyRequestReceiptToken',
       'request_id',v_audit.request_id
     ) THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_outbox_closure_invalid'
      USING ERRCODE='23514';
  END IF;

  v_result:=jsonb_build_object(
    'sessionId',v_session_id,
    'privacyRequestId',v_privacy_request_id,
    'sessionKind','PRIVACY_REQUEST_RECEIPT',
    'scopeType','PRIVACY_REQUEST',
    'scopeId',v_privacy_request_id,
    'bffIssuer',p_bff_issuer,
    'issuedAt',v_issued_at,
    'expiresAt',v_expires_at,
    'auditEventId',v_audit_event_id,
    'emittedEventIds',jsonb_build_array(v_outbox_event_id),
    'receiptDigest',btrim(v_receipt_digest),
    'replayed',v_replayed
  );
  RETURN v_result;
END
$exchange_adapter$;
ALTER FUNCTION ops.exchange_privacy_request_receipt_token_v2(
  char(64),char(64),text,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.exchange_privacy_request_receipt_token_v2(
  char(64),char(64),text,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.exchange_privacy_request_receipt_token_v2(
  char(64),char(64),text,uuid,char(64),char(64)
) TO gurine_submission_api;

-- R6d D3 transitionRetentionRequest VERIFY_IDENTITY public-owner closure.
--
-- Apply after 0038 and the D3 identity proof authority/inventory fragment.  The
-- 0038 owner remains the unchanged implementation for every non-VERIFY edge.
-- The public wrapper admits the current exact owner ABI, proves the signed wire
-- request digest before any delegate can write, and routes only VERIFY_IDENTITY
-- to the D3 authority consumer.

ALTER FUNCTION ops.transition_privacy_request_v2(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) RENAME TO transition_privacy_request_v2_pre_r6d_d3;
REVOKE ALL ON FUNCTION ops.transition_privacy_request_v2_pre_r6d_d3(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC,gurine_control_api;

-- The dedicated owner is an implementation detail.  Keeping the runtime role
-- at the six-argument public wrapper prevents bypassing the literal transition
-- discriminator and exact-16 VERIFY_IDENTITY shape.
REVOKE ALL ON FUNCTION ops.verify_privacy_request_identity_v3(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC,gurine_control_api;
REVOKE ALL ON FUNCTION ops.create_privacy_correction_plan_v1(
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
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $transition_privacy_d3$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_transition text;
  v_actor_assertion_jti uuid;
  v_actor_assertion_request_digest char(64);
  v_assertion ops.assertion_replay_guard%ROWTYPE;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR NOT p_payload ?& ARRAY[
       'transition','_actorAssertionJti',
       '_actorAssertionRequestSha256'
     ]
     OR jsonb_typeof(p_payload->'transition')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssertionJti')<>'string'
     OR jsonb_typeof(
       p_payload->'_actorAssertionRequestSha256'
     )<>'string' THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid'
      USING ERRCODE='22023';
  END IF;
  IF NOT ops.r6d_lower_sha256(
       p_payload->>'_actorAssertionRequestSha256'
     ) THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid'
      USING ERRCODE='22023';
  END IF;

  BEGIN
    v_actor_assertion_jti:=(p_payload->>'_actorAssertionJti')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid'
      USING ERRCODE='22023';
  END;
  IF v_actor_assertion_jti=
       '00000000-0000-0000-0000-000000000000'::uuid THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid'
      USING ERRCODE='22023';
  END IF;
  v_transition:=p_payload->>'transition';
  v_actor_assertion_request_digest:=
    (p_payload->>'_actorAssertionRequestSha256')::char(64);

  -- This is the separately committed authorization-attempt proof.  It is
  -- deliberately compared with the signed wire-request digest, never with the
  -- semantic p_request_sha256 used by the business idempotency claim.
  SELECT assertion.* INTO v_assertion
  FROM ops.assertion_replay_guard AS assertion
  WHERE assertion.assertion_type='ACTOR'
    AND assertion.jti=v_actor_assertion_jti;
  IF NOT FOUND OR v_assertion.issuer<>'identity-api'
     OR v_assertion.audience<>'control-api'
     OR v_assertion.request_digest<>
       v_actor_assertion_request_digest
     OR v_assertion.consumed_at>v_now
     OR v_assertion.expires_at<=v_now THEN
    RAISE EXCEPTION 'privacy_transition_actor_assertion_invalid'
      USING ERRCODE='42501';
  END IF;

  IF v_transition='VERIFY_IDENTITY' THEN
    -- The D3 owner requires exactly the remaining 15 keys.  Consequently this
    -- branch accepts exactly the real Control API 16-key sealed owner payload,
    -- including the literal transition discriminator and no speculative input.
    RETURN ops.verify_privacy_request_identity_v3(
      p_payload-'transition',p_actor_id,p_session_id,p_request_id,
      p_idempotency_key_sha256,p_request_sha256
    );
  END IF;

  -- 0038 predates only the signed-request-digest field.  Remove that one field
  -- and preserve all of its exact variant validation, fail-closed APPROVE edge,
  -- state/version rules, receipts, events, and response shape byte-for-byte.
  RETURN ops.transition_privacy_request_v2_pre_r6d_d3(
    p_payload-'_actorAssertionRequestSha256',
    p_actor_id,p_session_id,p_request_id,
    p_idempotency_key_sha256,p_request_sha256
  );
END
$transition_privacy_d3$;
ALTER FUNCTION ops.transition_privacy_request_v2(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.transition_privacy_request_v2(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.transition_privacy_request_v2(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- The exchange fragment does not replace the 0038 dispatcher.  Keep that
-- complete chain private and expose one final adapter that adds only the two
-- newly closed D3 command branches.
ALTER FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) RENAME TO apply_control_addendum_command_pre_r6d_0039_d3_verify;
REVOKE ALL ON FUNCTION
  ops.apply_control_addendum_command_pre_r6d_0039_d3_verify(
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
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,intake,raw,extensions,pg_temp
AS $d3_dispatcher$
DECLARE
  v_result jsonb;
  v_expected_result jsonb;
  v_dispatch_response jsonb;
  v_transition jsonb;
  v_plan ops.privacy_correction_plans_v1%ROWTYPE;
  v_transition_receipt ops.privacy_request_transition_receipts_v2%ROWTYPE;
  v_identity_receipt ops.privacy_request_identity_receipts_v2%ROWTYPE;
  v_notice_receipt ops.privacy_request_notice_receipts_v2%ROWTYPE;
  v_consumption ops.privacy_identity_proof_consumption_receipts_v1%ROWTYPE;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_audit ops.audit_events%ROWTYPE;
  v_idempotency ops.idempotency_keys%ROWTYPE;
  v_event ops.outbox%ROWTYPE;
  v_aggregate_id uuid;
  v_privacy_request_id uuid;
  v_result_request_id uuid;
  v_audit_event_id uuid;
  v_transition_receipt_id uuid;
  v_identity_receipt_id uuid;
  v_notice_receipt_id uuid;
  v_calendar_version_id uuid;
  v_aggregate_version bigint;
  v_plan_version bigint;
  v_accepted_at timestamptz;
  v_identity_verified_at timestamptz;
  v_due_at timestamptz;
  v_receipt_digest char(64);
  v_identity_receipt_digest char(64);
  v_notice_receipt_digest char(64);
  v_calendar_digest char(64);
  v_policy_digest char(64);
  v_event_digest char(64);
  v_outbox_event_ids uuid[];
BEGIN
  IF p_operation_id='createPrivacyCorrectionPlan' THEN
    v_result:=ops.create_privacy_correction_plan_v1(
      p_payload,p_actor_id,p_session_id,p_request_id,
      p_idempotency_key_hash,p_request_digest
    );
    IF v_result IS NULL OR jsonb_typeof(v_result)<>'object'
       OR (SELECT count(*) FROM jsonb_object_keys(v_result))<>7
       OR NOT v_result ?& ARRAY[
         'correctionPlanId','privacyRequestId','planVersion','planDigest',
         'auditEventId','createdAt','replayed'
       ]
       OR jsonb_typeof(v_result->'correctionPlanId')<>'string'
       OR jsonb_typeof(v_result->'privacyRequestId')<>'string'
       OR jsonb_typeof(v_result->'planVersion')<>'number'
       OR v_result->>'planVersion' !~ '^[1-9][0-9]{0,18}$'
       OR jsonb_typeof(v_result->'planDigest')<>'string'
       OR NOT ops.r6d_lower_sha256(v_result->>'planDigest')
       OR jsonb_typeof(v_result->'auditEventId')<>'string'
       OR jsonb_typeof(v_result->'createdAt')<>'string'
       OR jsonb_typeof(v_result->'replayed')<>'boolean'
       OR (v_result->>'replayed')::boolean THEN
      RAISE EXCEPTION 'privacy_correction_plan_result_adapter_invalid'
        USING ERRCODE='55000';
    END IF;

    BEGIN
      v_aggregate_id:=(v_result->>'correctionPlanId')::uuid;
      v_privacy_request_id:=(v_result->>'privacyRequestId')::uuid;
      v_audit_event_id:=(v_result->>'auditEventId')::uuid;
      v_plan_version:=(v_result->>'planVersion')::bigint;
      v_accepted_at:=(v_result->>'createdAt')::timestamptz;
      v_receipt_digest:=(v_result->>'planDigest')::char(64);
    EXCEPTION
      WHEN invalid_text_representation OR numeric_value_out_of_range
        OR datetime_field_overflow THEN
      RAISE EXCEPTION 'privacy_correction_plan_result_adapter_invalid'
        USING ERRCODE='55000';
    END;
    IF v_aggregate_id=
         '00000000-0000-0000-0000-000000000000'::uuid
       OR v_privacy_request_id=
         '00000000-0000-0000-0000-000000000000'::uuid
       OR v_audit_event_id=
         '00000000-0000-0000-0000-000000000000'::uuid
       OR NOT isfinite(v_accepted_at) THEN
      RAISE EXCEPTION 'privacy_correction_plan_result_adapter_invalid'
        USING ERRCODE='55000';
    END IF;

    SELECT plan.* INTO v_plan
    FROM ops.privacy_correction_plans_v1 AS plan
    WHERE plan.correction_plan_id=v_aggregate_id
    FOR SHARE;
    SELECT audit.* INTO v_audit
    FROM ops.audit_events AS audit
    WHERE audit.id=v_audit_event_id
    FOR SHARE;
    SELECT claim.* INTO v_idempotency
    FROM ops.idempotency_keys AS claim
    WHERE claim.scope=
        'control:'||p_actor_id::text||':createPrivacyCorrectionPlan'
      AND claim.key_hash=p_idempotency_key_hash
    FOR SHARE;
    IF v_plan.correction_plan_id IS NULL OR v_audit.id IS NULL
       OR v_idempotency.scope IS NULL THEN
      RAISE EXCEPTION 'privacy_correction_plan_result_adapter_invalid'
        USING ERRCODE='55000';
    END IF;

    v_expected_result:=jsonb_build_object(
      'correctionPlanId',v_plan.correction_plan_id,
      'privacyRequestId',v_plan.privacy_request_id,
      'planVersion',v_plan.plan_version,
      'planDigest',btrim(v_plan.plan_digest),
      'auditEventId',v_plan.audit_event_id,
      'createdAt',v_plan.created_at,
      'replayed',false
    );
    IF v_result IS DISTINCT FROM v_expected_result
       OR v_plan.privacy_request_id<>v_privacy_request_id
       OR v_plan.plan_version<>v_plan_version
       OR v_plan.actor_id<>p_actor_id
       OR v_plan.session_id<>p_session_id
       OR v_plan.request_id<>p_request_id
       OR v_plan.idempotency_key_sha256<>p_idempotency_key_hash
       OR v_plan.request_digest<>p_request_digest
       OR v_plan.audit_event_id<>v_audit_event_id
       OR v_plan.plan_digest<>v_receipt_digest
       OR v_plan.created_at<>v_accepted_at
       OR NOT isfinite(v_plan.created_at)
       OR v_idempotency.request_hash IS DISTINCT FROM p_request_digest
       OR v_idempotency.expires_at<=v_accepted_at
       OR num_nonnulls(
         v_idempotency.response_status,v_idempotency.response_body,
         v_idempotency.resource_type,v_idempotency.resource_id
       )<>0 THEN
      RAISE EXCEPTION 'privacy_correction_plan_result_adapter_invalid'
        USING ERRCODE='55000';
    END IF;
    IF v_audit.actor_type IS DISTINCT FROM 'USER'
       OR v_audit.actor_id IS DISTINCT FROM p_actor_id::text
       OR v_audit.session_id IS DISTINCT FROM p_session_id
       OR v_audit.action IS DISTINCT FROM
         'privacy.correction_plan.create'
       OR v_audit.object_type IS DISTINCT FROM
         'PRIVACY_CORRECTION_PLAN'
       OR v_audit.object_id IS DISTINCT FROM v_aggregate_id::text
       OR v_audit.capability IS DISTINCT FROM
         'privacy.requests.manage'
       OR v_audit.outcome::text IS DISTINCT FROM 'SUCCESS'
       OR v_audit.reason IS DISTINCT FROM btrim(v_plan.reason_digest)
       OR v_audit.request_id IS DISTINCT FROM v_plan.request_id
       OR v_audit.details IS DISTINCT FROM jsonb_build_object(
         'retentionRequestId',v_plan.privacy_request_id,
         'requestDecisionVersion',v_plan.request_decision_version,
         'correctionPlanId',v_plan.correction_plan_id,
         'planVersion',v_plan.plan_version,
         'scopeInventoryDigest',
           v_plan.plan_payload->>'scopeInventoryDigest',
         'targetObjectType',v_plan.target_object_type,
         'targetObjectId',v_plan.target_object_id,
         'scopeItemDigest',btrim(v_plan.scope_item_digest),
         'fieldPathDigest',btrim(v_plan.field_path_digest),
         'currentValueDigest',btrim(v_plan.current_value_digest),
         'requestedValueDigest',btrim(v_plan.requested_value_sha256),
         'evidenceSetDigest',btrim(v_plan.evidence_set_digest),
         'reasonDigest',btrim(v_plan.reason_digest),
         'planDigest',btrim(v_plan.plan_digest),
         'targetMutationCount',0
       ) THEN
      RAISE EXCEPTION 'privacy_correction_plan_result_adapter_invalid'
        USING ERRCODE='55000';
    END IF;

    -- The database owner returns its seven-key private receipt, while Rust's
    -- direct-receipt projector consumes this exact 13-key internal union and
    -- persists the resulting public response only after this adapter returns.
    v_dispatch_response:=jsonb_build_object(
      'requestId',v_plan.request_id,
      'status','completed',
      'aggregateId',v_plan.correction_plan_id,
      'aggregateVersion',v_plan.plan_version,
      'auditEventId',v_plan.audit_event_id,
      'acceptedAt',v_plan.created_at,
      'receiptDigest',btrim(v_plan.plan_digest),
      'emittedEventIds','[]'::jsonb,
      'links','[]'::jsonb,
      'receiptToken',btrim(v_plan.plan_digest),
      'correctionPlanId',v_plan.correction_plan_id,
      'retentionRequestId',v_plan.privacy_request_id,
      'planVersion',v_plan.plan_version
    );
    RETURN QUERY SELECT
      v_aggregate_id,v_plan_version,'completed'::text,v_accepted_at,
      v_dispatch_response,v_receipt_digest,v_audit_event_id,NULL::uuid;
    RETURN;
  END IF;

  IF p_operation_id<>'transitionRetentionRequest'
     OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR jsonb_typeof(p_payload->'transition')<>'string'
     OR p_payload->>'transition'<>'VERIFY_IDENTITY' THEN
    RETURN QUERY
    SELECT prior.aggregate_id,prior.aggregate_version,prior.status,
      prior.accepted_at,prior.response_body,prior.receipt_digest,
      prior.audit_event_id,prior.outbox_event_id
    FROM ops.apply_control_addendum_command_pre_r6d_0039_d3_verify(
      p_operation_id,p_payload,p_actor_id,p_session_id,p_request_id,
      p_idempotency_key_hash,p_request_digest
    ) AS prior;
    RETURN;
  END IF;

  -- The public transition owner validates the exact 16-key payload and signed
  -- request digest before it removes only the discriminator for the D3 owner.
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
     OR jsonb_typeof(v_result->'requestId')<>'string'
     OR jsonb_typeof(v_result->'aggregateId')<>'string'
     OR jsonb_typeof(v_result->'aggregateVersion')<>'number'
     OR v_result->>'aggregateVersion' !~ '^[1-9][0-9]{0,18}$'
     OR jsonb_typeof(v_result->'status')<>'string'
     OR v_result->>'status'<>'COMPLETED'
     OR jsonb_typeof(v_result->'acceptedAt')<>'string'
     OR jsonb_typeof(v_result->'receiptDigest')<>'string'
     OR NOT ops.r6d_lower_sha256(v_result->>'receiptDigest')
     OR jsonb_typeof(v_result->'auditEventId')<>'string'
     OR jsonb_typeof(v_result->'outboxEventIds')<>'array'
     OR jsonb_typeof(v_result->'emittedEventIds')<>'array'
     OR v_result->'outboxEventIds'<>v_result->'emittedEventIds'
     OR jsonb_array_length(v_result->'outboxEventIds')<>1
     OR jsonb_typeof(v_result->'outboxEventIds'->0)<>'string'
     OR jsonb_typeof(v_result->'links')<>'array'
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
     OR jsonb_typeof(v_transition->'retentionRequestId')<>'string'
     OR jsonb_typeof(v_transition->'decisionVersion')<>'number'
     OR v_transition->>'decisionVersion' !~ '^[1-9][0-9]{0,18}$'
     OR jsonb_typeof(v_transition->'requestType')<>'string'
     OR v_transition->>'requestType' NOT IN (
       'ACCESS','CORRECTION','DELETION','RESTRICTION'
     )
     OR jsonb_typeof(v_transition->'state')<>'string'
     OR v_transition->>'state'<>'RECEIVED'
     OR jsonb_typeof(v_transition->'transition')<>'string'
     OR v_transition->>'transition'<>'VERIFY_IDENTITY'
     OR jsonb_typeof(v_transition->'transitionReceiptId')<>'string'
     OR jsonb_typeof(v_transition->'transitionReceiptDigest')<>'string'
     OR NOT ops.r6d_lower_sha256(
       v_transition->>'transitionReceiptDigest'
     )
     OR jsonb_typeof(v_transition->'identityVerifiedAt')<>'string'
     OR jsonb_typeof(v_transition->'dueAt')<>'string'
     OR jsonb_typeof(v_transition->'policyVersion')<>'string'
     OR NULLIF(btrim(v_transition->>'policyVersion'),'') IS NULL
     OR char_length(v_transition->>'policyVersion')>100
     OR jsonb_typeof(v_transition->'policyDigest')<>'string'
     OR NOT ops.r6d_lower_sha256(v_transition->>'policyDigest')
     OR jsonb_typeof(v_transition->'calendarVersionId')<>'string'
     OR jsonb_typeof(v_transition->'calendarDigest')<>'string'
     OR NOT ops.r6d_lower_sha256(v_transition->>'calendarDigest')
     OR jsonb_typeof(v_transition->'identityReceiptId')<>'string'
     OR jsonb_typeof(v_transition->'identityReceiptDigest')<>'string'
     OR NOT ops.r6d_lower_sha256(
       v_transition->>'identityReceiptDigest'
     )
     OR jsonb_typeof(v_transition->'extensionReceiptId')<>'null'
     OR jsonb_typeof(v_transition->'extensionReceiptDigest')<>'null'
     OR jsonb_typeof(v_transition->'refusalReceiptId')<>'null'
     OR jsonb_typeof(v_transition->'refusalReceiptDigest')<>'null'
     OR jsonb_typeof(v_transition->'noticeReceiptId')<>'string'
     OR jsonb_typeof(v_transition->'noticeReceiptDigest')<>'string'
     OR NOT ops.r6d_lower_sha256(
       v_transition->>'noticeReceiptDigest'
     )
     OR jsonb_typeof(v_transition->'appealInstructionsDigest')<>'null'
     OR jsonb_typeof(v_transition->'updatedAt')<>'string'
     OR jsonb_typeof(v_transition->'replayed')<>'boolean'
     OR (v_transition->>'replayed')::boolean THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  BEGIN
    v_result_request_id:=(v_result->>'requestId')::uuid;
    v_aggregate_id:=(v_result->>'aggregateId')::uuid;
    v_aggregate_version:=(v_result->>'aggregateVersion')::bigint;
    v_accepted_at:=(v_result->>'acceptedAt')::timestamptz;
    v_receipt_digest:=(v_result->>'receiptDigest')::char(64);
    v_audit_event_id:=(v_result->>'auditEventId')::uuid;
    v_transition_receipt_id:=
      (v_transition->>'transitionReceiptId')::uuid;
    v_identity_receipt_id:=(v_transition->>'identityReceiptId')::uuid;
    v_identity_receipt_digest:=
      (v_transition->>'identityReceiptDigest')::char(64);
    v_notice_receipt_id:=(v_transition->>'noticeReceiptId')::uuid;
    v_notice_receipt_digest:=
      (v_transition->>'noticeReceiptDigest')::char(64);
    v_calendar_version_id:=
      (v_transition->>'calendarVersionId')::uuid;
    v_calendar_digest:=(v_transition->>'calendarDigest')::char(64);
    v_policy_digest:=(v_transition->>'policyDigest')::char(64);
    v_identity_verified_at:=
      (v_transition->>'identityVerifiedAt')::timestamptz;
    v_due_at:=(v_transition->>'dueAt')::timestamptz;
    v_outbox_event_ids:=ARRAY[
      (v_result->'outboxEventIds'->>0)::uuid
    ]::uuid[];
    PERFORM (v_transition->>'retentionRequestId')::uuid,
      (v_transition->>'decisionVersion')::bigint,
      (v_transition->>'updatedAt')::timestamptz;
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range
      OR datetime_field_overflow THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END;
  IF v_result_request_id<>p_request_id
     OR v_aggregate_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_aggregate_id<>(v_transition->>'retentionRequestId')::uuid
     OR v_aggregate_version<>
       (v_transition->>'decisionVersion')::bigint
     OR v_receipt_digest<>
       (v_transition->>'transitionReceiptDigest')::char(64)
     OR v_accepted_at<>(v_transition->>'updatedAt')::timestamptz
     OR v_accepted_at<>v_identity_verified_at
     OR NOT isfinite(v_accepted_at)
     OR NOT isfinite(v_due_at)
     OR v_due_at<=v_identity_verified_at
     OR v_audit_event_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_transition_receipt_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_identity_receipt_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_notice_receipt_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_calendar_version_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_outbox_event_ids[1]=
       '00000000-0000-0000-0000-000000000000'::uuid THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  SELECT receipt.* INTO v_transition_receipt
  FROM ops.privacy_request_transition_receipts_v2 AS receipt
  WHERE receipt.transition_receipt_id=v_transition_receipt_id
  FOR SHARE;
  SELECT identity.* INTO v_identity_receipt
  FROM ops.privacy_request_identity_receipts_v2 AS identity
  WHERE identity.identity_receipt_id=v_identity_receipt_id
  FOR SHARE;
  SELECT notice.* INTO v_notice_receipt
  FROM ops.privacy_request_notice_receipts_v2 AS notice
  WHERE notice.notice_receipt_id=v_notice_receipt_id
  FOR SHARE;
  SELECT consumed.* INTO v_consumption
  FROM ops.privacy_identity_proof_consumption_receipts_v1 AS consumed
  WHERE consumed.transition_receipt_id=v_transition_receipt_id
    AND consumed.privacy_request_id=v_aggregate_id
  FOR SHARE;
  SELECT request.* INTO v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=v_aggregate_id
  FOR SHARE;
  SELECT audit.* INTO v_audit
  FROM ops.audit_events AS audit
  WHERE audit.id=v_audit_event_id
  FOR SHARE;
  SELECT event.* INTO v_event
  FROM ops.outbox AS event
  WHERE event.id=v_outbox_event_ids[1]
  FOR SHARE;
  SELECT claim.* INTO v_idempotency
  FROM ops.idempotency_keys AS claim
  WHERE claim.scope=
      'control:'||p_actor_id::text||':transitionRetentionRequest'
    AND claim.key_hash=p_idempotency_key_hash
  FOR SHARE;
  IF v_transition_receipt.transition_receipt_id IS NULL
     OR v_identity_receipt.identity_receipt_id IS NULL
     OR v_notice_receipt.notice_receipt_id IS NULL
     OR v_consumption.consumption_receipt_id IS NULL
     OR v_request.id IS NULL OR v_audit.id IS NULL OR v_event.id IS NULL
     OR v_idempotency.scope IS NULL THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;
  v_event_digest:=ops.r6d_outbox_envelope_digest_v1(v_event.id);
  IF v_event_digest IS NULL OR NOT ops.r6d_lower_sha256(v_event_digest) THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  IF v_transition_receipt.privacy_request_id<>v_aggregate_id
     OR v_transition_receipt.decision_version<>v_aggregate_version
     OR v_transition_receipt.transition<>'VERIFY_IDENTITY'
     OR v_transition_receipt.prior_state<>'RECEIVED'
     OR v_transition_receipt.state<>'RECEIVED'
     OR v_transition_receipt.actor_id<>p_actor_id
     OR v_transition_receipt.actor_assertion_jti<>
       (p_payload->>'_actorAssertionJti')::uuid
     OR v_transition_receipt.receipt_payload->>
       'actorAssertionRequestDigest' IS DISTINCT FROM
       p_payload->>'_actorAssertionRequestSha256'
     OR v_transition_receipt.actor_action_digest<>
       (p_payload->>'_actorActionDigest')::char(64)
     OR v_transition_receipt.step_up_authorization_id<>
       (p_payload->>'_actorStepUpAuthorizationId')::uuid
     OR v_transition_receipt.idempotency_key_sha256<>
       p_idempotency_key_hash
     OR v_transition_receipt.request_sha256<>p_request_digest
     OR v_transition_receipt.receipt_digest<>v_receipt_digest
     OR v_transition_receipt.decided_at<>v_accepted_at
     OR v_transition_receipt.audit_event_id<>v_audit_event_id
     OR v_transition_receipt.outbox_event_ids<>v_outbox_event_ids
     OR v_transition_receipt.identity_receipt_id<>
       v_identity_receipt_id
     OR v_transition_receipt.identity_receipt_digest<>
       v_identity_receipt_digest
     OR num_nonnulls(
       v_transition_receipt.extension_receipt_id,
       v_transition_receipt.extension_receipt_digest,
       v_transition_receipt.refusal_receipt_id,
       v_transition_receipt.refusal_receipt_digest,
       v_transition_receipt.appeal_instructions_sha256,
       v_transition_receipt.appeal_instructions_aad_digest
     )<>0
     OR v_transition_receipt.notice_receipt_id<>v_notice_receipt_id
     OR v_transition_receipt.notice_receipt_digest<>
       v_notice_receipt_digest
     OR v_transition_receipt.event_receipt_id<>v_event.id
     OR v_transition_receipt.event_receipt_digest<>
       v_event_digest THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  IF v_identity_receipt.privacy_request_id<>v_aggregate_id
     OR v_identity_receipt.decision_version<>v_aggregate_version
     OR v_identity_receipt.prior_identity_state<>'PENDING_VERIFICATION'
     OR v_identity_receipt.identity_state<>'VERIFIED'
     OR v_identity_receipt.identity_verified_at<>
       v_identity_verified_at
     OR v_identity_receipt.verified_at<>v_identity_verified_at
     OR v_identity_receipt.due_at<>v_due_at
     OR v_identity_receipt.response_policy_version<>
       v_transition->>'policyVersion'
     OR v_identity_receipt.response_policy_digest<>v_policy_digest
     OR v_identity_receipt.calendar_version_id<>
       v_calendar_version_id
     OR v_identity_receipt.calendar_digest<>v_calendar_digest
     OR v_identity_receipt.notice_receipt_id<>v_notice_receipt_id
     OR v_identity_receipt.notice_receipt_digest<>
       v_notice_receipt_digest
     OR v_identity_receipt.event_receipt_id<>v_event.id
     OR v_identity_receipt.event_receipt_digest<>v_event_digest
     OR v_identity_receipt.receipt_digest<>v_identity_receipt_digest THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  IF v_notice_receipt.privacy_request_id<>v_aggregate_id
     OR v_notice_receipt.notice_kind<>'IDENTITY_VERIFIED'
     OR v_notice_receipt.transition_receipt_id<>
       v_transition_receipt_id
     OR v_notice_receipt.branch_receipt_id<>v_identity_receipt_id
     OR v_notice_receipt.branch_receipt_digest<>
       v_identity_receipt_digest
     OR v_notice_receipt.event_receipt_id<>v_event.id
     OR v_notice_receipt.event_receipt_digest<>v_event_digest
     OR v_notice_receipt.receipt_digest<>v_notice_receipt_digest
     OR v_notice_receipt.created_at<>v_accepted_at THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  v_expected_result:=jsonb_build_object(
    'schemaVersion','privacy-identity-proof-consumption-receipt.v1',
    'consumptionReceiptId',v_consumption.consumption_receipt_id,
    'identityProofReceiptId',v_consumption.identity_proof_receipt_id,
    'identityProofReceiptDigest',btrim(
      v_consumption.identity_proof_receipt_digest
    ),
    'privacyRequestId',v_aggregate_id,
    'subjectProofHash',btrim(v_consumption.subject_proof_hash),
    'exactScopeDigest',btrim(v_consumption.exact_scope_digest),
    'identityReceiptId',v_identity_receipt_id,
    'identityReceiptDigest',btrim(v_identity_receipt_digest),
    'transitionReceiptId',v_transition_receipt_id,
    'transitionReceiptDigest',btrim(v_receipt_digest),
    'actorId',p_actor_id,
    'consumedAt',v_consumption.consumed_at
  );
  IF v_consumption.identity_proof_receipt_id<>
       v_identity_receipt.identity_proof_receipt_id
     OR v_consumption.identity_proof_receipt_digest<>
       v_identity_receipt.identity_proof_receipt_digest
     OR v_consumption.actor_id<>p_actor_id
     OR v_consumption.consumed_at<>v_accepted_at
     OR v_consumption.receipt_payload<>v_expected_result THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  IF v_request.decision_version<>v_aggregate_version
     OR v_request.state<>'RECEIVED'
     OR v_request.identity_state<>'VERIFIED'
     OR v_request.identity_verified_at<>v_identity_verified_at
     OR v_request.due_at<>v_due_at
     OR v_request.response_policy_id<>
       v_identity_receipt.response_policy_id
     OR v_request.response_policy_revision<>
       v_identity_receipt.response_policy_revision
     OR v_request.response_policy_digest<>v_policy_digest
     OR v_request.calendar_version_id<>v_calendar_version_id
     OR v_request.calendar_digest<>v_calendar_digest
     OR v_request.current_identity_receipt_id<>v_identity_receipt_id
     OR v_request.current_identity_receipt_digest<>
       v_identity_receipt_digest
     OR v_request.current_notice_receipt_id<>v_notice_receipt_id
     OR v_request.current_notice_receipt_digest<>
       v_notice_receipt_digest
     OR v_request.updated_at<>v_accepted_at THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  IF v_idempotency.request_hash IS DISTINCT FROM p_request_digest
     OR v_idempotency.expires_at<=v_accepted_at
     OR num_nonnulls(
       v_idempotency.response_status,v_idempotency.response_body,
       v_idempotency.resource_type,v_idempotency.resource_id
     )<>0 THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  IF v_audit.actor_type IS DISTINCT FROM 'USER'
     OR v_audit.actor_id IS DISTINCT FROM p_actor_id::text
     OR v_audit.session_id IS DISTINCT FROM p_session_id
     OR v_audit.action IS DISTINCT FROM
       'command.transitionRetentionRequest'
     OR v_audit.object_type IS DISTINCT FROM 'PRIVACY_REQUEST'
     OR v_audit.object_id IS DISTINCT FROM v_aggregate_id::text
     OR v_audit.capability IS DISTINCT FROM
       'privacy.requests.manage'
     OR v_audit.outcome::text IS DISTINCT FROM 'SUCCESS'
     OR v_audit.reason IS DISTINCT FROM p_payload->>'reasonCode'
     OR v_audit.request_id IS DISTINCT FROM p_request_id
     OR v_audit.details->>'transition' IS DISTINCT FROM
       'VERIFY_IDENTITY'
     OR v_audit.details->>'transitionReceiptId' IS DISTINCT FROM
       v_transition_receipt_id::text
     OR v_audit.details->>'identityReceiptId' IS DISTINCT FROM
       v_identity_receipt_id::text
     OR v_audit.details->>'noticeReceiptId' IS DISTINCT FROM
       v_notice_receipt_id::text
     OR v_audit.details->>'consumptionReceiptId' IS DISTINCT FROM
       v_consumption.consumption_receipt_id::text
     OR v_audit.details->>'eventId' IS DISTINCT FROM v_event.id::text
     OR v_audit.details->>'eventDigest' IS DISTINCT FROM
       btrim(v_event_digest) THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  IF v_event.aggregate_type<>'privacy_request'
     OR v_event.aggregate_id<>v_aggregate_id::text
     OR v_event.aggregate_version<>v_aggregate_version
     OR v_event.event_type<>'privacy.request_identity_verified.v1'
     OR v_event.occurred_at<>v_accepted_at
     OR v_event.payload IS DISTINCT FROM jsonb_build_object(
       'retentionRequestId',v_request.id,
       'requestType',v_request.request_type,
       'priorIdentityState','PENDING_VERIFICATION',
       'identityState','VERIFIED',
       'identityProofReceiptDigest',btrim(
         v_identity_receipt.identity_proof_receipt_digest
       ),
       'identityVerifiedAt',v_identity_verified_at,
       'responsePolicyVersion',
         v_identity_receipt.response_policy_version,
       'responsePolicyDigest',btrim(v_policy_digest),
       'calendarVersionId',v_calendar_version_id,
       'calendarDigest',btrim(v_calendar_digest),
       'dueAt',v_due_at,
       'verificationReceiptDigest',btrim(v_identity_receipt_digest)
     )
     OR v_event_digest IS DISTINCT FROM
       ops.r6d_outbox_envelope_digest_v1(v_event.id) THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  RETURN QUERY SELECT
    v_aggregate_id,v_aggregate_version,v_result->>'status',v_accepted_at,
    v_result,v_receipt_digest,v_audit_event_id,v_event.id;
END
$d3_dispatcher$;
ALTER FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

COMMIT;
