BEGIN;

-- R6d is forward-only.  Rows written before this migration remain readable,
-- but every new privacy-bearing write is bound to an approved, current
-- schedule and every public named-person byte is bound to an immutable guard
-- assessment.  No operating retention schedule or holiday calendar is seeded
-- here.

CREATE OR REPLACE FUNCTION ops.r6d_lower_sha256(p_value text)
RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT p_value ~ '^[0-9a-f]{64}$'
$$;
ALTER FUNCTION ops.r6d_lower_sha256(text) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_lower_sha256(text) FROM PUBLIC;

-- Close the preservation terminal-action family in both the approval detail
-- and the executed schedule.  Preservation actions are indefinite,
-- non-destructive, and do not create restoration suppressions.
ALTER TABLE ops.action_approval_retention_schedule_details
  DROP CONSTRAINT aap_13_scalar_ck;
ALTER TABLE ops.action_approval_retention_schedule_details
  ADD CONSTRAINT aap_13_scalar_ck CHECK (
    expected_schedule_revision >= 0
    AND trigger_kind IN (
      'CREATED_AT','UPDATED_AT','CONSUMED_AT','EXPIRES_AT','CASE_CLOSED_AT',
      'LAST_MATERIAL_USE_AT','SUPERSEDED_AT','DELIVERED_AT','TERMINAL_AT',
      'CONSENT_REVOKED_AT'
    )
    AND (active_duration_seconds IS NULL OR active_duration_seconds BETWEEN 0 AND 3155760000)
    AND (backup_duration_seconds IS NULL OR backup_duration_seconds BETWEEN 0 AND 3155760000)
    AND terminal_action IN (
      'DELETE','ANONYMIZE','CRYPTO_ERASE','PRESERVE_PUBLIC_REVISION',
      'PRESERVE_REFERENCED_REVISION','PRESERVE_IDENTITY_GRAPH',
      'PRESERVE_WITH_PARENT'
    )
    AND hold_behavior IN (
      'BLOCK_ON_RETENTION','BLOCK_ON_RETENTION_OR_DELETION','NOT_DESTRUCTIVE'
    )
    AND restore_suppression_behavior IN (
      'REAPPLY_BEFORE_ACCESS','NOT_APPLICABLE'
    )
    AND (
      (
        terminal_action LIKE 'PRESERVE_%'
        AND active_duration_seconds IS NULL
        AND backup_duration_seconds IS NULL
        AND hold_behavior = 'NOT_DESTRUCTIVE'
        AND restore_suppression_behavior = 'NOT_APPLICABLE'
      )
      OR (
        terminal_action NOT LIKE 'PRESERVE_%'
        AND active_duration_seconds IS NOT NULL
        AND backup_duration_seconds IS NOT NULL
        AND hold_behavior <> 'NOT_DESTRUCTIVE'
        AND restore_suppression_behavior = 'REAPPLY_BEFORE_ACCESS'
      )
    )
  );

ALTER TABLE ops.record_class_schedules
  DROP CONSTRAINT record_class_schedules_terminal_ck,
  DROP CONSTRAINT record_class_schedules_indefinite_ck,
  DROP CONSTRAINT record_class_schedules_hold_ck,
  DROP CONSTRAINT record_class_schedules_restore_ck,
  DROP CONSTRAINT record_class_schedules_trigger_ck;
ALTER TABLE ops.record_class_schedules
  ADD CONSTRAINT record_class_schedules_trigger_ck CHECK (
    trigger_kind IN (
      'CREATED_AT','UPDATED_AT','CONSUMED_AT','EXPIRES_AT','CASE_CLOSED_AT',
      'LAST_MATERIAL_USE_AT','SUPERSEDED_AT','DELIVERED_AT','TERMINAL_AT',
      'CONSENT_REVOKED_AT'
    )
  ),
  ADD CONSTRAINT record_class_schedules_terminal_ck CHECK (
    terminal_action IN (
      'DELETE','ANONYMIZE','CRYPTO_ERASE','PRESERVE_PUBLIC_REVISION',
      'PRESERVE_REFERENCED_REVISION','PRESERVE_IDENTITY_GRAPH',
      'PRESERVE_WITH_PARENT'
    )
  ),
  ADD CONSTRAINT record_class_schedules_indefinite_ck CHECK (
    (
      terminal_action LIKE 'PRESERVE_%'
      AND active_duration_seconds IS NULL
      AND backup_duration_seconds IS NULL
    )
    OR (
      terminal_action NOT LIKE 'PRESERVE_%'
      AND active_duration_seconds IS NOT NULL
      AND backup_duration_seconds IS NOT NULL
    )
  ),
  ADD CONSTRAINT record_class_schedules_hold_ck CHECK (
    hold_behavior IN (
      'BLOCK_ON_RETENTION','BLOCK_ON_RETENTION_OR_DELETION','NOT_DESTRUCTIVE'
    )
    AND (
      (terminal_action LIKE 'PRESERVE_%' AND hold_behavior = 'NOT_DESTRUCTIVE')
      OR (terminal_action NOT LIKE 'PRESERVE_%' AND hold_behavior <> 'NOT_DESTRUCTIVE')
    )
  ),
  ADD CONSTRAINT record_class_schedules_restore_ck CHECK (
    restore_suppression_behavior IN ('REAPPLY_BEFORE_ACCESS','NOT_APPLICABLE')
    AND (
      (terminal_action LIKE 'PRESERVE_%' AND restore_suppression_behavior = 'NOT_APPLICABLE')
      OR (terminal_action NOT LIKE 'PRESERVE_%' AND restore_suppression_behavior = 'REAPPLY_BEFORE_ACCESS')
    )
  );

CREATE TABLE ops.r6d_record_class_catalog (
  record_class text PRIMARY KEY,
  data_category text NOT NULL,
  required_terminal_action text NOT NULL,
  pii_write boolean NOT NULL,
  required_trigger_kind text,
  required_active_duration_seconds bigint,
  required_backup_duration_seconds bigint,
  required_lawful_basis text,
  authority_version text NOT NULL DEFAULT 'supervisor-decision-v1',
  description text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT r6d_record_class_catalog_name_ck CHECK (
    record_class ~ '^[A-Z][A-Z0-9_]{2,99}$'
  ),
  CONSTRAINT r6d_record_class_catalog_category_ck CHECK (
    data_category IN ('ENTITY_IDENTITY','PERSON_IDENTITY','GRAPH_TOPOLOGY','GOVERNANCE','PRIVACY_RIGHTS')
  ),
  CONSTRAINT r6d_record_class_catalog_terminal_ck CHECK (
    required_terminal_action IN (
      'ANONYMIZE','CRYPTO_ERASE','PRESERVE_REFERENCED_REVISION',
      'PRESERVE_IDENTITY_GRAPH','PRESERVE_WITH_PARENT'
    )
  ),
  CONSTRAINT r6d_record_class_catalog_pii_ck CHECK (
    NOT pii_write OR required_terminal_action IN ('ANONYMIZE','CRYPTO_ERASE')
  ),
  CONSTRAINT r6d_record_class_catalog_schedule_expectation_ck CHECK (
    num_nonnulls(
      required_trigger_kind,required_active_duration_seconds,
      required_backup_duration_seconds,required_lawful_basis
    ) IN (0,4)
    AND (required_trigger_kind IS NULL OR required_trigger_kind IN (
      'CREATED_AT','UPDATED_AT','CONSUMED_AT','EXPIRES_AT','CASE_CLOSED_AT',
      'LAST_MATERIAL_USE_AT','SUPERSEDED_AT','DELIVERED_AT','TERMINAL_AT'
    ))
    AND (required_active_duration_seconds IS NULL
      OR required_active_duration_seconds BETWEEN 0 AND 3155760000)
    AND (required_backup_duration_seconds IS NULL
      OR required_backup_duration_seconds BETWEEN 0 AND 3155760000)
    AND (required_lawful_basis IS NULL
      OR length(btrim(required_lawful_basis)) BETWEEN 1 AND 2000)
  )
);
ALTER TABLE ops.r6d_record_class_catalog OWNER TO gurine_migrator;
REVOKE ALL ON ops.r6d_record_class_catalog FROM PUBLIC;
GRANT SELECT ON ops.r6d_record_class_catalog
  TO gurine_control_api, gurine_workflow_worker, gurine_scheduler,
     gurine_auditor, gurine_ingest_worker, gurine_submission_api;
CREATE TRIGGER r6d_record_class_catalog_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.r6d_record_class_catalog
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

INSERT INTO ops.r6d_record_class_catalog(
  record_class,data_category,required_terminal_action,pii_write,description,
  required_trigger_kind,required_active_duration_seconds,
  required_backup_duration_seconds,required_lawful_basis
) VALUES
  ('AGENCY_MASTER','ENTITY_IDENTITY','ANONYMIZE',true,'기관 식별 원장','LAST_MATERIAL_USE_AT',157680000,31536000,'공익 조달 감시(정당한 이익)'),
  ('SUPPLIER_MASTER','ENTITY_IDENTITY','ANONYMIZE',true,'업체 식별 원장','LAST_MATERIAL_USE_AT',157680000,31536000,'공익 조달 감시(정당한 이익)'),
  ('AGENCY_IDENTIFIER','ENTITY_IDENTITY','ANONYMIZE',true,'기관 식별자','LAST_MATERIAL_USE_AT',157680000,31536000,'공익 조달 감시(정당한 이익)'),
  ('SUPPLIER_IDENTIFIER','ENTITY_IDENTITY','ANONYMIZE',true,'업체 식별자','LAST_MATERIAL_USE_AT',157680000,31536000,'공익 조달 감시(정당한 이익)'),
  ('ENTITY_ALIAS','ENTITY_IDENTITY','ANONYMIZE',true,'기관·업체 별칭','LAST_MATERIAL_USE_AT',157680000,31536000,'공익 조달 감시(정당한 이익)'),
  ('RELATIONSHIP_PERSON_CONTEXT','PERSON_IDENTITY','ANONYMIZE',true,'자연인 성명·직책 문맥',NULL,NULL,NULL,NULL),
  ('RELATIONSHIP_PERSON_TOPOLOGY','GRAPH_TOPOLOGY','PRESERVE_IDENTITY_GRAPH',false,'자연인 그래프 위상·digest·출처 locator',NULL,NULL,NULL,NULL),
  ('ENTITY_RETENTION_SNAPSHOT','GOVERNANCE','PRESERVE_REFERENCED_REVISION',false,'기관·업체 보존·legal-hold 기준 스냅샷',NULL,NULL,NULL,NULL),
  ('NAMED_PERSON_PUBLICATION_GOVERNANCE','GOVERNANCE','PRESERVE_WITH_PARENT',false,'자연인 실명 공개 판정·예외 receipt',NULL,NULL,NULL,NULL),
  ('RESPONSE_IDENTITY_GOVERNANCE','GOVERNANCE','PRESERVE_WITH_PARENT',false,'소명 조직 신원 판정 receipt',NULL,NULL,NULL,NULL),
  ('PERSON_ERASURE_GOVERNANCE','GOVERNANCE','PRESERVE_WITH_PARENT',false,'자연인 문맥 암호 삭제 receipt',NULL,NULL,NULL,NULL),
  ('LEGAL_HOLD_GOVERNANCE','GOVERNANCE','PRESERVE_WITH_PARENT',false,'법적 보존 배치 receipt',NULL,NULL,NULL,NULL),
  ('PRIVACY_REQUEST','PRIVACY_RIGHTS','ANONYMIZE',true,'개인정보 권리행사 요청',NULL,NULL,NULL,NULL),
  ('PRIVACY_REQUEST_TOKEN','PRIVACY_RIGHTS','CRYPTO_ERASE',true,'권리행사 일회용 receipt token',NULL,NULL,NULL,NULL),
  ('PRIVACY_REQUEST_SEALED_CONTENT','PRIVACY_RIGHTS','CRYPTO_ERASE',true,'권리행사 암호화 사유 본문',NULL,NULL,NULL,NULL),
  ('PRIVACY_REQUEST_NOTICE','GOVERNANCE','PRESERVE_WITH_PARENT',false,'권리행사 통지 receipt',NULL,NULL,NULL,NULL),
  ('PRIVACY_REQUEST_EXECUTION','GOVERNANCE','PRESERVE_WITH_PARENT',false,'권리행사 결정·실행 receipt',NULL,NULL,NULL,NULL);

-- Staged legacy closure.  Existing rows remain nullable and are not silently
-- reclassified.  New rows and PII-bearing updates must bind one exact current
-- approved schedule through the trigger below.
ALTER TABLE core.agencies
  ADD COLUMN retention_schedule_id uuid,
  ADD COLUMN retention_record_class text,
  ADD COLUMN retention_schedule_digest char(64);
ALTER TABLE core.suppliers
  ADD COLUMN retention_schedule_id uuid,
  ADD COLUMN retention_record_class text,
  ADD COLUMN retention_schedule_digest char(64);
ALTER TABLE core.agency_identifiers
  ADD COLUMN retention_schedule_id uuid,
  ADD COLUMN retention_record_class text,
  ADD COLUMN retention_schedule_digest char(64);
ALTER TABLE core.supplier_identifiers
  ADD COLUMN retention_schedule_id uuid,
  ADD COLUMN retention_record_class text,
  ADD COLUMN retention_schedule_digest char(64);
ALTER TABLE core.entity_aliases
  ADD COLUMN retention_schedule_id uuid,
  ADD COLUMN retention_record_class text,
  ADD COLUMN retention_schedule_digest char(64);

ALTER TABLE core.agencies
  ADD CONSTRAINT agencies_r6d_retention_fk FOREIGN KEY (
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT agencies_r6d_class_fk FOREIGN KEY (retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT agencies_r6d_class_ck CHECK (
    retention_record_class IS NULL OR retention_record_class='AGENCY_MASTER'
  );
ALTER TABLE core.suppliers
  ADD CONSTRAINT suppliers_r6d_retention_fk FOREIGN KEY (
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT suppliers_r6d_class_fk FOREIGN KEY (retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT suppliers_r6d_class_ck CHECK (
    retention_record_class IS NULL OR retention_record_class='SUPPLIER_MASTER'
  );
ALTER TABLE core.agency_identifiers
  ADD CONSTRAINT agency_identifiers_r6d_retention_fk FOREIGN KEY (
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT agency_identifiers_r6d_class_fk FOREIGN KEY (retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT agency_identifiers_r6d_class_ck CHECK (
    retention_record_class IS NULL OR retention_record_class='AGENCY_IDENTIFIER'
  );
ALTER TABLE core.supplier_identifiers
  ADD CONSTRAINT supplier_identifiers_r6d_retention_fk FOREIGN KEY (
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT supplier_identifiers_r6d_class_fk FOREIGN KEY (retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT supplier_identifiers_r6d_class_ck CHECK (
    retention_record_class IS NULL OR retention_record_class='SUPPLIER_IDENTIFIER'
  );
ALTER TABLE core.entity_aliases
  ADD CONSTRAINT entity_aliases_r6d_retention_fk FOREIGN KEY (
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT entity_aliases_r6d_class_fk FOREIGN KEY (retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT entity_aliases_r6d_class_ck CHECK (
    retention_record_class IS NULL OR retention_record_class='ENTITY_ALIAS'
  );

CREATE OR REPLACE FUNCTION ops.bind_r6d_identity_schedule_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, ops, pg_temp
AS $$
DECLARE
  v_class text;
  v_expected_terminal text;
  v_required_trigger text;
  v_required_active bigint;
  v_required_backup bigint;
  v_required_lawful_basis text;
  v_schedule ops.record_class_schedules%ROWTYPE;
  v_count bigint;
  v_at timestamptz := clock_timestamp();
BEGIN
  v_class := CASE TG_TABLE_SCHEMA||'.'||TG_TABLE_NAME
    WHEN 'core.agencies' THEN 'AGENCY_MASTER'
    WHEN 'core.suppliers' THEN 'SUPPLIER_MASTER'
    WHEN 'core.agency_identifiers' THEN 'AGENCY_IDENTIFIER'
    WHEN 'core.supplier_identifiers' THEN 'SUPPLIER_IDENTIFIER'
    WHEN 'core.entity_aliases' THEN 'ENTITY_ALIAS'
    WHEN 'core.relationship_graph_person_nodes_v3' THEN 'RELATIONSHIP_PERSON_TOPOLOGY'
    WHEN 'core.relationship_graph_person_context_v3' THEN 'RELATIONSHIP_PERSON_CONTEXT'
    WHEN 'core.relationship_graph_person_erasure_receipts_v3' THEN 'PERSON_ERASURE_GOVERNANCE'
    WHEN 'ops.entity_retention_snapshots_v1' THEN 'ENTITY_RETENTION_SNAPSHOT'
    WHEN 'ops.legal_hold_placement_receipts_v2' THEN 'LEGAL_HOLD_GOVERNANCE'
    WHEN 'ops.privacy_requests_v2' THEN 'PRIVACY_REQUEST'
    WHEN 'ops.privacy_request_receipt_tokens_v2' THEN 'PRIVACY_REQUEST_TOKEN'
    WHEN 'ops.privacy_request_identity_receipts_v2' THEN 'PRIVACY_REQUEST_EXECUTION'
    WHEN 'ops.privacy_request_extension_receipts_v2' THEN 'PRIVACY_REQUEST_EXECUTION'
    WHEN 'ops.privacy_request_refusal_receipts_v2' THEN 'PRIVACY_REQUEST_EXECUTION'
    WHEN 'ops.privacy_request_notice_receipts_v2' THEN 'PRIVACY_REQUEST_NOTICE'
    WHEN 'ops.privacy_request_transition_receipts_v2' THEN 'PRIVACY_REQUEST_EXECUTION'
    WHEN 'editorial.named_person_publication_assessments' THEN 'NAMED_PERSON_PUBLICATION_GOVERNANCE'
    WHEN 'editorial.named_person_publication_findings' THEN 'NAMED_PERSON_PUBLICATION_GOVERNANCE'
    WHEN 'editorial.named_person_legal_overrides' THEN 'NAMED_PERSON_PUBLICATION_GOVERNANCE'
    WHEN 'editorial.named_person_review_stage_receipts_v1' THEN 'NAMED_PERSON_PUBLICATION_GOVERNANCE'
    WHEN 'editorial.publication_preview_owner_receipts_v2' THEN 'NAMED_PERSON_PUBLICATION_GOVERNANCE'
    WHEN 'editorial.publication_revision_owner_receipts_v2' THEN 'NAMED_PERSON_PUBLICATION_GOVERNANCE'
    WHEN 'editorial.response_submission_origin_receipts_v2' THEN 'RESPONSE_IDENTITY_GOVERNANCE'
    WHEN 'editorial.organization_official_channel_assertions_v1' THEN 'RESPONSE_IDENTITY_GOVERNANCE'
    WHEN 'editorial.organization_official_channel_revocation_receipts_v1' THEN 'RESPONSE_IDENTITY_GOVERNANCE'
    WHEN 'editorial.response_organization_identity_assertions_v1' THEN 'RESPONSE_IDENTITY_GOVERNANCE'
    WHEN 'editorial.response_publication_identity_receipts_v1' THEN 'RESPONSE_IDENTITY_GOVERNANCE'
    WHEN 'intake.response_submission_receipts_v3' THEN 'RESPONSE_IDENTITY_GOVERNANCE'
    WHEN 'editorial.response_excerpt_approval_receipts_v2' THEN 'RESPONSE_IDENTITY_GOVERNANCE'
    ELSE NULL
  END;
  IF v_class IS NULL THEN
    RAISE EXCEPTION 'r6d_retention_relation_not_registered' USING ERRCODE='55000';
  END IF;
  IF TG_OP='INSERT' THEN
    IF NEW.retention_schedule_id IS NOT NULL
       OR NEW.retention_record_class IS NOT NULL
       OR NEW.retention_schedule_digest IS NOT NULL THEN
      RAISE EXCEPTION 'r6d_retention_schedule_caller_override' USING ERRCODE='55000';
    END IF;
  ELSIF ROW(
    NEW.retention_schedule_id,NEW.retention_record_class,
    NEW.retention_schedule_digest
  ) IS DISTINCT FROM ROW(
    OLD.retention_schedule_id,OLD.retention_record_class,
    OLD.retention_schedule_digest
  ) THEN
    RAISE EXCEPTION 'r6d_retention_schedule_caller_override' USING ERRCODE='55000';
  END IF;
  SELECT required_terminal_action,required_trigger_kind,
    required_active_duration_seconds,required_backup_duration_seconds,
    required_lawful_basis
  INTO STRICT v_expected_terminal,v_required_trigger,v_required_active,
    v_required_backup,v_required_lawful_basis
  FROM ops.r6d_record_class_catalog WHERE record_class=v_class;
  LOCK TABLE ops.record_class_schedules IN SHARE MODE;
  SELECT count(*) INTO v_count
  FROM ops.record_class_schedules AS schedule
  WHERE schedule.record_class=v_class
    AND schedule.effective_at<=v_at
    AND schedule.review_expires_at>v_at
    AND schedule.terminal_action=v_expected_terminal
    AND (v_required_trigger IS NULL OR schedule.trigger_kind=v_required_trigger)
    AND (v_required_active IS NULL
      OR schedule.active_duration_seconds=v_required_active)
    AND (v_required_backup IS NULL
      OR schedule.backup_duration_seconds=v_required_backup)
    AND (v_required_lawful_basis IS NULL
      OR schedule.lawful_basis=v_required_lawful_basis);
  IF v_count=0 THEN
    RAISE EXCEPTION 'r6d_retention_schedule_missing:%',v_class USING ERRCODE='55000';
  ELSIF v_count<>1 THEN
    RAISE EXCEPTION 'r6d_retention_schedule_ambiguous:%',v_class USING ERRCODE='55000';
  END IF;
  SELECT * INTO STRICT v_schedule
  FROM ops.record_class_schedules AS schedule
  WHERE schedule.record_class=v_class
    AND schedule.effective_at<=v_at
    AND schedule.review_expires_at>v_at
    AND schedule.terminal_action=v_expected_terminal
    AND (v_required_trigger IS NULL OR schedule.trigger_kind=v_required_trigger)
    AND (v_required_active IS NULL
      OR schedule.active_duration_seconds=v_required_active)
    AND (v_required_backup IS NULL
      OR schedule.backup_duration_seconds=v_required_backup)
    AND (v_required_lawful_basis IS NULL
      OR schedule.lawful_basis=v_required_lawful_basis);
  NEW.retention_schedule_id:=v_schedule.id;
  NEW.retention_record_class:=v_schedule.record_class;
  NEW.retention_schedule_digest:=v_schedule.schedule_digest;
  RETURN NEW;
END
$$;
ALTER FUNCTION ops.bind_r6d_identity_schedule_v1() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.bind_r6d_identity_schedule_v1() FROM PUBLIC;

CREATE TRIGGER agencies_r6d_retention_bind
  BEFORE INSERT OR UPDATE OF canonical_name,jurisdiction,parent_agency_id
  ON core.agencies FOR EACH ROW
  EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();
CREATE TRIGGER suppliers_r6d_retention_bind
  BEFORE INSERT OR UPDATE OF canonical_name,business_status
  ON core.suppliers FOR EACH ROW
  EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();
CREATE TRIGGER agency_identifiers_r6d_retention_bind
  BEFORE INSERT OR UPDATE OF scheme,value
  ON core.agency_identifiers FOR EACH ROW
  EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();
CREATE TRIGGER supplier_identifiers_r6d_retention_bind
  BEFORE INSERT OR UPDATE OF scheme,value_hash,display_value
  ON core.supplier_identifiers FOR EACH ROW
  EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();
CREATE TRIGGER entity_aliases_r6d_retention_bind
  BEFORE INSERT OR UPDATE OF alias,normalized_alias
  ON core.entity_aliases FOR EACH ROW
  EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

CREATE INDEX agencies_r6d_retention_idx
  ON core.agencies(retention_record_class,retention_schedule_id,id);
CREATE INDEX suppliers_r6d_retention_idx
  ON core.suppliers(retention_record_class,retention_schedule_id,id);
CREATE INDEX agency_identifiers_r6d_retention_idx
  ON core.agency_identifiers(retention_record_class,retention_schedule_id,id);
CREATE INDEX supplier_identifiers_r6d_retention_idx
  ON core.supplier_identifiers(retention_record_class,retention_schedule_id,id);
CREATE INDEX entity_aliases_r6d_retention_idx
  ON core.entity_aliases(retention_record_class,retention_schedule_id,id);

-- Existing v2 PERSON rows contain immutable inline plaintext.  They are
-- staged legacy and are not rewritten.  New PERSON writes are closed; the v3
-- topology plus erasable context child is the only forward path.
CREATE OR REPLACE FUNCTION core.reject_new_v2_person_plaintext_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NEW.endpoint_kind='PERSON' THEN
    RAISE EXCEPTION 'r6d_person_v2_plaintext_write_retired' USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION core.reject_new_v2_person_plaintext_v1() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.reject_new_v2_person_plaintext_v1() FROM PUBLIC;
CREATE TRIGGER relationship_graph_endpoints_v2_person_retired_guard
  BEFORE INSERT ON core.relationship_graph_endpoints_v2
  FOR EACH ROW EXECUTE FUNCTION core.reject_new_v2_person_plaintext_v1();

CREATE TABLE core.relationship_graph_person_nodes_v3 (
  person_node_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_locator text NOT NULL,
  source_locator_digest char(64) NOT NULL,
  identifier_digest char(64) NOT NULL,
  topology_payload jsonb NOT NULL,
  topology_canonical bytea NOT NULL,
  topology_digest char(64) NOT NULL UNIQUE,
  created_actor_type text NOT NULL,
  created_actor_id text NOT NULL,
  created_by uuid REFERENCES ops.users(id) ON DELETE RESTRICT,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT relationship_graph_person_nodes_v3_exact_uq
    UNIQUE(person_node_id,topology_digest),
  CONSTRAINT relationship_graph_person_nodes_v3_retention_fk FOREIGN KEY (
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT relationship_graph_person_nodes_v3_class_fk
    FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  CONSTRAINT relationship_graph_person_nodes_v3_shape_ck CHECK (
    retention_record_class='RELATIONSHIP_PERSON_TOPOLOGY'
    AND length(btrim(source_locator)) BETWEEN 1 AND 2048
    AND ops.r6d_lower_sha256(source_locator_digest)
    AND ops.r6d_lower_sha256(identifier_digest)
    AND ops.r6d_lower_sha256(topology_digest)
    AND convert_from(topology_canonical,'UTF8')::jsonb=topology_payload
    AND topology_digest=encode(extensions.digest(topology_canonical,'sha256'),'hex')
    AND NOT topology_payload ?| ARRAY[
      'contextualName','roleTitle','name','residentRegistrationNumber',
      'address','birthDate','familyRelation','kinship','score','rank','probability'
    ]
    AND (
      (created_actor_type='HUMAN' AND created_by IS NOT NULL AND created_actor_id=created_by::text)
      OR (created_actor_type='SERVICE' AND created_by IS NULL AND created_actor_id='ingest-worker')
    )
  )
);
ALTER TABLE core.relationship_graph_person_nodes_v3 OWNER TO gurine_migrator;
REVOKE ALL ON core.relationship_graph_person_nodes_v3 FROM PUBLIC;
GRANT SELECT ON core.relationship_graph_person_nodes_v3
  TO gurine_control_api, gurine_auditor;
CREATE TRIGGER relationship_graph_person_nodes_v3_retention_bind
  BEFORE INSERT ON core.relationship_graph_person_nodes_v3
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();
CREATE TRIGGER relationship_graph_person_nodes_v3_immutable_guard
  BEFORE UPDATE OR DELETE ON core.relationship_graph_person_nodes_v3
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE TABLE core.relationship_graph_person_context_v3 (
  context_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  person_node_id uuid NOT NULL,
  topology_digest char(64) NOT NULL,
  contextual_name_ciphertext bytea,
  contextual_name_sha256 char(64),
  contextual_name_aad_digest char(64),
  role_title_ciphertext bytea,
  role_title_sha256 char(64),
  role_title_aad_digest char(64),
  encryption_key_id text,
  person_name_digest char(64) NOT NULL,
  verification_status text NOT NULL,
  public_use_status text NOT NULL,
  verified_by uuid REFERENCES ops.users(id) ON DELETE RESTRICT,
  verified_at timestamptz,
  erase_state text NOT NULL DEFAULT 'ACTIVE',
  erased_at timestamptz,
  erasure_receipt_digest char(64),
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT relationship_graph_person_context_v3_node_uq UNIQUE(person_node_id),
  CONSTRAINT relationship_graph_person_context_v3_name_uq
    UNIQUE(context_id,person_name_digest),
  CONSTRAINT relationship_graph_person_context_v3_publication_binding_uq
    UNIQUE(context_id,person_node_id,topology_digest,person_name_digest),
  CONSTRAINT relationship_graph_person_context_v3_node_fk FOREIGN KEY (
    person_node_id,topology_digest
  ) REFERENCES core.relationship_graph_person_nodes_v3(
    person_node_id,topology_digest
  ) ON DELETE RESTRICT,
  CONSTRAINT relationship_graph_person_context_v3_retention_fk FOREIGN KEY (
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT relationship_graph_person_context_v3_class_fk
    FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  CONSTRAINT relationship_graph_person_context_v3_shape_ck CHECK (
    retention_record_class='RELATIONSHIP_PERSON_CONTEXT'
    AND ops.r6d_lower_sha256(topology_digest)
    AND ops.r6d_lower_sha256(person_name_digest)
    AND (erasure_receipt_digest IS NULL OR ops.r6d_lower_sha256(erasure_receipt_digest))
    AND verification_status IN ('PENDING_HUMAN','VERIFIED','REJECTED')
    AND public_use_status IN ('NOT_REVIEWED','APPROVED','DENIED')
    AND erase_state IN ('ACTIVE','ANONYMIZED')
    AND (
      (
        erase_state='ACTIVE'
        AND octet_length(contextual_name_ciphertext) BETWEEN 1 AND 16384
        AND octet_length(role_title_ciphertext) BETWEEN 1 AND 16384
        AND ops.r6d_lower_sha256(contextual_name_sha256)
        AND ops.r6d_lower_sha256(role_title_sha256)
        AND contextual_name_aad_digest=encode(extensions.digest(convert_to(
          'core.relationship_graph_person_context_v3/'||context_id::text||
          '/contextual_name/v1','UTF8'
        ),'sha256'),'hex')
        AND role_title_aad_digest=encode(extensions.digest(convert_to(
          'core.relationship_graph_person_context_v3/'||context_id::text||
          '/role_title/v1','UTF8'
        ),'sha256'),'hex')
        AND length(encryption_key_id) BETWEEN 1 AND 200
        AND erased_at IS NULL AND erasure_receipt_digest IS NULL
        AND (
          (verification_status='PENDING_HUMAN' AND public_use_status='NOT_REVIEWED'
            AND verified_by IS NULL AND verified_at IS NULL)
          OR (verification_status='VERIFIED' AND public_use_status='APPROVED'
            AND verified_by IS NOT NULL AND verified_at IS NOT NULL)
          OR (verification_status='REJECTED' AND public_use_status='DENIED'
            AND verified_by IS NOT NULL AND verified_at IS NOT NULL)
        )
      )
      OR (
        erase_state='ANONYMIZED'
        AND contextual_name_ciphertext IS NULL
        AND contextual_name_sha256 IS NULL
        AND contextual_name_aad_digest IS NULL
        AND role_title_ciphertext IS NULL
        AND role_title_sha256 IS NULL
        AND role_title_aad_digest IS NULL
        AND encryption_key_id IS NULL
        AND erased_at IS NOT NULL AND erasure_receipt_digest IS NOT NULL
      )
    )
  )
);
ALTER TABLE core.relationship_graph_person_context_v3 OWNER TO gurine_migrator;
REVOKE ALL ON core.relationship_graph_person_context_v3 FROM PUBLIC;
GRANT SELECT(
  context_id,person_node_id,topology_digest,person_name_digest,
  verification_status,public_use_status,erase_state,retention_schedule_id,
  retention_record_class,retention_schedule_digest,created_at
) ON core.relationship_graph_person_context_v3
  TO gurine_control_api, gurine_auditor;
CREATE TRIGGER relationship_graph_person_context_v3_retention_bind
  BEFORE INSERT ON core.relationship_graph_person_context_v3
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

CREATE TABLE core.relationship_graph_person_erasure_receipts_v3 (
  receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  context_id uuid NOT NULL,
  person_node_id uuid NOT NULL,
  topology_digest char(64) NOT NULL,
  person_name_digest char(64) NOT NULL,
  prior_context_digest char(64) NOT NULL,
  erasure_kind text NOT NULL,
  legal_hold_coverage_digest char(64) NOT NULL,
  actor_type text NOT NULL,
  actor_id text NOT NULL,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  erased_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT relationship_graph_person_erasure_context_fk FOREIGN KEY (
    context_id,person_name_digest
  ) REFERENCES core.relationship_graph_person_context_v3(
    context_id,person_name_digest
  ) ON DELETE RESTRICT,
  CONSTRAINT relationship_graph_person_erasure_shape_ck CHECK (
    erasure_kind='ANONYMIZE'
    AND actor_type IN ('HUMAN','SERVICE')
    AND length(actor_id) BETWEEN 1 AND 512
    AND ops.r6d_lower_sha256(topology_digest)
    AND ops.r6d_lower_sha256(person_name_digest)
    AND ops.r6d_lower_sha256(prior_context_digest)
    AND ops.r6d_lower_sha256(legal_hold_coverage_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(extensions.digest(receipt_canonical,'sha256'),'hex')
  )
);
ALTER TABLE core.relationship_graph_person_erasure_receipts_v3 OWNER TO gurine_migrator;
REVOKE ALL ON core.relationship_graph_person_erasure_receipts_v3 FROM PUBLIC;
GRANT SELECT ON core.relationship_graph_person_erasure_receipts_v3
  TO gurine_control_api, gurine_auditor;
CREATE TRIGGER relationship_graph_person_erasure_receipts_v3_immutable_guard
  BEFORE UPDATE OR DELETE ON core.relationship_graph_person_erasure_receipts_v3
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE OR REPLACE FUNCTION core.guard_person_context_v3_update()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'immutable_person_context' USING ERRCODE='55000';
  END IF;
  IF current_user<>'gurine_migrator'
     OR current_setting('gurine.person_context_erasure',true)<>'1'
     OR OLD.erase_state<>'ACTIVE' OR NEW.erase_state<>'ANONYMIZED'
     OR NEW.contextual_name_ciphertext IS NOT NULL
     OR NEW.contextual_name_sha256 IS NOT NULL
     OR NEW.contextual_name_aad_digest IS NOT NULL
     OR NEW.role_title_ciphertext IS NOT NULL
     OR NEW.role_title_sha256 IS NOT NULL
     OR NEW.role_title_aad_digest IS NOT NULL
     OR NEW.encryption_key_id IS NOT NULL
     OR NEW.erased_at IS NULL OR NEW.erasure_receipt_digest IS NULL
     OR ROW(
       NEW.context_id,NEW.person_node_id,NEW.topology_digest,NEW.person_name_digest,
       NEW.verification_status,NEW.public_use_status,NEW.verified_by,NEW.verified_at,
       NEW.retention_schedule_id,NEW.retention_record_class,
       NEW.retention_schedule_digest,NEW.created_at
     ) IS DISTINCT FROM ROW(
       OLD.context_id,OLD.person_node_id,OLD.topology_digest,OLD.person_name_digest,
       OLD.verification_status,OLD.public_use_status,OLD.verified_by,OLD.verified_at,
       OLD.retention_schedule_id,OLD.retention_record_class,
       OLD.retention_schedule_digest,OLD.created_at
     ) THEN
    RAISE EXCEPTION 'person_context_erasure_transition_invalid' USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION core.guard_person_context_v3_update() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.guard_person_context_v3_update() FROM PUBLIC;
CREATE TRIGGER relationship_graph_person_context_v3_update_guard
  BEFORE UPDATE OR DELETE ON core.relationship_graph_person_context_v3
  FOR EACH ROW EXECUTE FUNCTION core.guard_person_context_v3_update();

CREATE OR REPLACE FUNCTION core.list_publication_person_names_v1()
RETURNS TABLE(
  person_node_id uuid,
  topology_digest char(64),
  context_id uuid,
  contextual_name_ciphertext bytea,
  contextual_name_sha256 char(64),
  contextual_name_aad_digest char(64),
  role_title_ciphertext bytea,
  role_title_sha256 char(64),
  role_title_aad_digest char(64),
  encryption_key_id text,
  person_name_digest char(64)
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, core, ops, pg_temp
AS $$
  SELECT context.person_node_id,context.topology_digest,context.context_id,
    context.contextual_name_ciphertext,context.contextual_name_sha256,
    context.contextual_name_aad_digest,context.role_title_ciphertext,
    context.role_title_sha256,context.role_title_aad_digest,
    context.encryption_key_id,context.person_name_digest
  FROM core.relationship_graph_person_context_v3 AS context
  JOIN ops.record_class_schedules AS schedule
    ON (schedule.id,schedule.record_class,schedule.schedule_digest)=
       (context.retention_schedule_id,context.retention_record_class,context.retention_schedule_digest)
  WHERE context.erase_state='ACTIVE'
    AND context.verification_status='VERIFIED'
    AND context.public_use_status='APPROVED'
    AND schedule.effective_at<=clock_timestamp()
    AND schedule.review_expires_at>clock_timestamp()
    AND schedule.terminal_action='ANONYMIZE'
  ORDER BY context.person_name_digest,context.context_id
$$;
ALTER FUNCTION core.list_publication_person_names_v1() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.list_publication_person_names_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.list_publication_person_names_v1()
  TO gurine_control_api;

-- Named-person hard publication policy.  The policy row is a versioned code
-- authority, not an operating exception.  Every exception remains a separate
-- exact-text, official-source, independent legal-review receipt.
CREATE TABLE editorial.named_person_publication_policies (
  policy_version text PRIMARY KEY,
  detector_kinds text[] NOT NULL,
  override_reason_codes text[] NOT NULL,
  ambiguous_match_disposition text NOT NULL,
  active boolean NOT NULL,
  policy_payload jsonb NOT NULL,
  policy_canonical bytea NOT NULL,
  policy_digest char(64) NOT NULL UNIQUE,
  effective_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT named_person_publication_policies_shape_ck CHECK (
    policy_version='r6d-named-person-publication-v1'
    AND detector_kinds=ARRAY[
      'REGISTERED_PERSON_EXACT','TITLE_ADJACENT_KOREAN_NAME'
    ]::text[]
    AND override_reason_codes=ARRAY[
      'OFFICIAL_DISPOSITION_QUOTE','PUBLIC_FIGURE'
    ]::text[]
    AND ambiguous_match_disposition='BLOCK_HUMAN_REVIEW'
    AND convert_from(policy_canonical,'UTF8')::jsonb=policy_payload
    AND policy_digest=encode(extensions.digest(policy_canonical,'sha256'),'hex')
  )
);
ALTER TABLE editorial.named_person_publication_policies OWNER TO gurine_migrator;
REVOKE ALL ON editorial.named_person_publication_policies FROM PUBLIC;
GRANT SELECT ON editorial.named_person_publication_policies
  TO gurine_control_api, gurine_auditor;
CREATE TRIGGER named_person_publication_policies_immutable_guard
  BEFORE UPDATE OR DELETE ON editorial.named_person_publication_policies
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

WITH policy AS (
  SELECT jsonb_build_object(
    'schemaVersion','named-person-publication-policy.v1',
    'policyVersion','r6d-named-person-publication-v1',
    'scannerRulesetVersion','ko-named-individual-v1',
    'scannerRulesetSha256','12cef82152a675eb9a7263c8cda984faa0da1ff676b0ff614db9437cf49d30fc',
    'detectors',jsonb_build_array(
      'REGISTERED_PERSON_EXACT','TITLE_ADJACENT_KOREAN_NAME'
    ),
    'ambiguousDisposition','BLOCK_HUMAN_REVIEW',
    'overrideReasonCodes',jsonb_build_array(
      'OFFICIAL_DISPOSITION_QUOTE','PUBLIC_FIGURE'
    ),
    'legalReviewedSource','IMMUTABLE_OVERRIDE_RECEIPT_ONLY',
    'identityMergeUse','FORBIDDEN'
  ) AS payload
), canonical AS (
  SELECT payload,ops.canonical_jsonb_v1(payload) AS bytes FROM policy
)
INSERT INTO editorial.named_person_publication_policies(
  policy_version,detector_kinds,override_reason_codes,
  ambiguous_match_disposition,active,policy_payload,policy_canonical,
  policy_digest,effective_at
)
SELECT 'r6d-named-person-publication-v1',
  ARRAY['REGISTERED_PERSON_EXACT','TITLE_ADJACENT_KOREAN_NAME']::text[],
  ARRAY['OFFICIAL_DISPOSITION_QUOTE','PUBLIC_FIGURE']::text[],
  'BLOCK_HUMAN_REVIEW',true,payload,bytes,
  encode(extensions.digest(bytes,'sha256'),'hex'),clock_timestamp()
FROM canonical;

-- The association receipt includes assessmentId; PREVIEW-to-PUBLISH reuse
-- instead compares this assessment-independent identity digest.
CREATE OR REPLACE FUNCTION editorial.named_person_finding_identity_digest_v1(
  p_ordinal integer,
  p_detector_kind text,
  p_json_pointer text,
  p_start_utf16 integer,
  p_end_utf16 integer,
  p_matched_text_sha256 text,
  p_ruleset_version text,
  p_context_id uuid,
  p_person_node_id uuid,
  p_topology_digest text,
  p_person_name_digest text
) RETURNS char(64)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_strip_nulls(jsonb_build_object(
      'schemaVersion','named-person-finding-identity.v1',
      'ordinal',p_ordinal,'detectorKind',p_detector_kind,
      'jsonPointer',p_json_pointer,'startUtf16',p_start_utf16,
      'endUtf16',p_end_utf16,'matchedTextSha256',p_matched_text_sha256,
      'rulesetVersion',p_ruleset_version,
      'personBinding',CASE WHEN p_detector_kind='REGISTERED_PERSON_EXACT'
        THEN jsonb_build_object(
          'contextId',p_context_id,'personNodeId',p_person_node_id,
          'topologyDigest',p_topology_digest,
          'personNameDigest',p_person_name_digest
        ) ELSE NULL END
    ))
  ),'sha256'),'hex')::char(64)
$$;
ALTER FUNCTION editorial.named_person_finding_identity_digest_v1(
  integer,text,text,integer,integer,text,text,uuid,uuid,text,text
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.named_person_finding_identity_digest_v1(
  integer,text,text,integer,integer,text,text,uuid,uuid,text,text
) FROM PUBLIC;

CREATE TABLE editorial.named_person_publication_assessments (
  assessment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  case_id uuid NOT NULL REFERENCES editorial.cases(id) ON DELETE RESTRICT,
  case_version bigint NOT NULL,
  review_snapshot_id uuid NOT NULL REFERENCES editorial.review_snapshots(id) ON DELETE RESTRICT,
  review_snapshot_digest char(64) NOT NULL,
  publication_state editorial.publication_state NOT NULL,
  guard_context text NOT NULL,
  public_payload_sha256 char(64) NOT NULL,
  public_text_sha256 char(64) NOT NULL,
  policy_version text NOT NULL,
  policy_digest char(64) NOT NULL,
  ruleset_version text NOT NULL,
  ruleset_sha256 char(64) NOT NULL,
  registered_name_set_sha256 char(64) NOT NULL,
  finding_count integer NOT NULL,
  finding_set_digest char(64) NOT NULL,
  outcome text NOT NULL,
  evaluated_actor_type text NOT NULL DEFAULT 'SERVICE',
  evaluated_actor_id text NOT NULL DEFAULT 'control-api',
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  assessment_payload jsonb NOT NULL,
  assessment_canonical bytea NOT NULL,
  assessment_digest char(64) NOT NULL UNIQUE,
  receipt_digest char(64) NOT NULL UNIQUE,
  evaluated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT named_person_publication_assessments_policy_fk FOREIGN KEY (
    policy_version
  ) REFERENCES editorial.named_person_publication_policies(policy_version)
    ON DELETE RESTRICT,
  CONSTRAINT named_person_publication_assessments_exact_uq UNIQUE(
    case_id,case_version,review_snapshot_id,publication_state,guard_context,
    public_payload_sha256,public_text_sha256,policy_digest,ruleset_sha256,
    registered_name_set_sha256
  ),
  CONSTRAINT named_person_publication_assessments_shape_ck CHECK (
    case_version>0
    AND guard_context IN ('PREVIEW','PUBLISH','CORRECTION')
    AND publication_state IN (
      'PUBLISHED_ANOMALY','PUBLISHED_EXPLAINED','OFFICIALLY_CONFIRMED',
      'CORRECTED','RETRACTED','TEMPORARILY_RESTRICTED'
    )
    AND ruleset_version='ko-named-individual-v1'
    AND finding_count BETWEEN 0 AND 10000
    AND outcome IN ('PASS','BLOCKED')
    AND evaluated_actor_type='SERVICE' AND evaluated_actor_id='control-api'
    AND ops.r6d_lower_sha256(review_snapshot_digest)
    AND ops.r6d_lower_sha256(public_payload_sha256)
    AND ops.r6d_lower_sha256(public_text_sha256)
    AND ops.r6d_lower_sha256(policy_digest)
    AND ops.r6d_lower_sha256(ruleset_sha256)
    AND ops.r6d_lower_sha256(registered_name_set_sha256)
    AND ops.r6d_lower_sha256(finding_set_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(assessment_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND convert_from(assessment_canonical,'UTF8')::jsonb=assessment_payload
    AND assessment_digest=encode(
      extensions.digest(assessment_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE editorial.named_person_publication_assessments OWNER TO gurine_migrator;
REVOKE ALL ON editorial.named_person_publication_assessments FROM PUBLIC;
GRANT SELECT ON editorial.named_person_publication_assessments
  TO gurine_control_api, gurine_auditor;
CREATE TRIGGER named_person_publication_assessments_immutable_guard
  BEFORE UPDATE OR DELETE ON editorial.named_person_publication_assessments
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE TABLE editorial.named_person_publication_findings (
  assessment_id uuid NOT NULL REFERENCES editorial.named_person_publication_assessments(assessment_id) ON DELETE RESTRICT,
  ordinal integer NOT NULL,
  detector_kind text NOT NULL,
  json_pointer text NOT NULL,
  start_utf16 integer NOT NULL,
  end_utf16 integer NOT NULL,
  matched_text_sha256 char(64) NOT NULL,
  ruleset_version text NOT NULL,
  context_id uuid,
  person_node_id uuid,
  topology_digest char(64),
  person_name_digest char(64),
  finding_payload jsonb NOT NULL,
  finding_canonical bytea NOT NULL,
  finding_digest char(64) NOT NULL,
  finding_identity_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(assessment_id,ordinal),
  CONSTRAINT named_person_publication_findings_digest_uq
    UNIQUE(assessment_id,finding_digest),
  CONSTRAINT named_person_publication_findings_person_fk FOREIGN KEY (
    person_node_id,topology_digest
  ) REFERENCES core.relationship_graph_person_nodes_v3(
    person_node_id,topology_digest
  ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT named_person_publication_findings_context_fk FOREIGN KEY (
    context_id,person_node_id,topology_digest,person_name_digest
  ) REFERENCES core.relationship_graph_person_context_v3(
    context_id,person_node_id,topology_digest,person_name_digest
  ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT named_person_publication_findings_shape_ck CHECK (
    ordinal>=0
    AND start_utf16>=0 AND end_utf16>start_utf16
    AND ruleset_version='ko-named-individual-v1'
    AND detector_kind IN (
      'REGISTERED_PERSON_EXACT','TITLE_ADJACENT_KOREAN_NAME'
    )
    AND length(json_pointer) BETWEEN 1 AND 2048
    AND left(json_pointer,1)='/'
    AND ops.r6d_lower_sha256(matched_text_sha256)
    AND ops.r6d_lower_sha256(finding_digest)
    AND ops.r6d_lower_sha256(finding_identity_digest)
    AND (
      (
        detector_kind='REGISTERED_PERSON_EXACT'
        AND num_nonnulls(
          context_id,person_node_id,topology_digest,person_name_digest
        )=4
        AND ops.r6d_lower_sha256(person_name_digest)
      )
      OR (
        detector_kind='TITLE_ADJACENT_KOREAN_NAME'
        AND num_nonnulls(
          context_id,person_node_id,topology_digest,person_name_digest
        )=0
      )
    )
    AND convert_from(finding_canonical,'UTF8')::jsonb=finding_payload
    AND finding_digest=encode(
      extensions.digest(finding_canonical,'sha256'),'hex'
    )
    AND finding_identity_digest=
      editorial.named_person_finding_identity_digest_v1(
        ordinal,detector_kind,json_pointer,start_utf16,end_utf16,
        btrim(matched_text_sha256),ruleset_version,context_id,person_node_id,
        btrim(topology_digest),btrim(person_name_digest)
      )
  )
);
ALTER TABLE editorial.named_person_publication_findings OWNER TO gurine_migrator;
REVOKE ALL ON editorial.named_person_publication_findings FROM PUBLIC;
GRANT SELECT ON editorial.named_person_publication_findings
  TO gurine_control_api, gurine_auditor;
CREATE TRIGGER named_person_publication_findings_immutable_guard
  BEFORE UPDATE OR DELETE ON editorial.named_person_publication_findings
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE TABLE editorial.named_person_legal_overrides (
  override_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assessment_id uuid NOT NULL REFERENCES editorial.named_person_publication_assessments(assessment_id) ON DELETE RESTRICT,
  public_text_sha256 char(64) NOT NULL,
  reason_code text NOT NULL,
  ruleset_version text NOT NULL,
  official_source_locator text NOT NULL,
  official_source_sha256 char(64) NOT NULL,
  publication_author_user_id uuid NOT NULL
    REFERENCES ops.users(id) ON DELETE RESTRICT,
  editorial_review_decision_id uuid NOT NULL
    REFERENCES editorial.review_decisions(id) ON DELETE RESTRICT,
  editorial_reviewer_user_id uuid NOT NULL
    REFERENCES ops.users(id) ON DELETE RESTRICT,
  legal_reviewer_user_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  editorial_review_decision_digest char(64) NOT NULL,
  editorial_review_stage_receipt_id uuid NOT NULL,
  editorial_review_stage_receipt_digest char(64) NOT NULL,
  editorial_reviewer_authority_digest char(64) NOT NULL,
  legal_reviewer_authority_digest char(64) NOT NULL,
  step_up_authorization_id uuid NOT NULL UNIQUE,
  step_up_receipt_digest char(64) NOT NULL,
  actor_assertion_jti uuid NOT NULL UNIQUE,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  override_payload jsonb NOT NULL,
  override_canonical bytea NOT NULL,
  override_digest char(64) NOT NULL UNIQUE,
  receipt_digest char(64) NOT NULL UNIQUE,
  reviewed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT named_person_legal_overrides_assessment_uq UNIQUE(assessment_id),
  CONSTRAINT named_person_legal_overrides_step_up_fk
    FOREIGN KEY(step_up_authorization_id)
    REFERENCES ops.step_up_authorizations(id) ON DELETE RESTRICT,
  CONSTRAINT named_person_legal_overrides_shape_ck CHECK (
    reason_code IN ('OFFICIAL_DISPOSITION_QUOTE','PUBLIC_FIGURE')
    AND ruleset_version='ko-named-individual-v1'
    AND legal_reviewer_user_id<>publication_author_user_id
    AND legal_reviewer_user_id<>editorial_reviewer_user_id
    AND publication_author_user_id<>editorial_reviewer_user_id
    AND length(btrim(official_source_locator)) BETWEEN 1 AND 2048
    AND ops.r6d_lower_sha256(public_text_sha256)
    AND ops.r6d_lower_sha256(official_source_sha256)
    AND ops.r6d_lower_sha256(step_up_receipt_digest)
    AND ops.r6d_lower_sha256(editorial_review_decision_digest)
    AND ops.r6d_lower_sha256(editorial_review_stage_receipt_digest)
    AND ops.r6d_lower_sha256(editorial_reviewer_authority_digest)
    AND ops.r6d_lower_sha256(legal_reviewer_authority_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(override_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND convert_from(override_canonical,'UTF8')::jsonb=override_payload
    AND override_digest=encode(
      extensions.digest(override_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE editorial.named_person_legal_overrides OWNER TO gurine_migrator;
REVOKE ALL ON editorial.named_person_legal_overrides FROM PUBLIC;
GRANT SELECT ON editorial.named_person_legal_overrides
  TO gurine_control_api, gurine_auditor;
CREATE TRIGGER named_person_legal_overrides_immutable_guard
  BEFORE UPDATE OR DELETE ON editorial.named_person_legal_overrides
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE OR REPLACE FUNCTION editorial.official_confirmation_valid_v1(p_value jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  RETURN p_value IS NOT NULL
    AND jsonb_typeof(p_value)='object'
    AND (SELECT count(*) FROM jsonb_object_keys(p_value))=6
    AND p_value ?& ARRAY[
      'institution','documentType','documentDate','confirmedScope',
      'sourceLocator','sourceDigest'
    ]
    AND NULLIF(btrim(p_value->>'institution'),'') IS NOT NULL
    AND NULLIF(btrim(p_value->>'documentType'),'') IS NOT NULL
    AND COALESCE(p_value->>'documentDate','') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    AND NULLIF(btrim(p_value->>'confirmedScope'),'') IS NOT NULL
    AND NULLIF(btrim(p_value->>'sourceLocator'),'') IS NOT NULL
    AND ops.r6d_lower_sha256(p_value->>'sourceDigest');
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;
ALTER FUNCTION editorial.official_confirmation_valid_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.official_confirmation_valid_v1(jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.correction_notice_valid_v1(p_value jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
BEGIN
  RETURN p_value IS NOT NULL
    AND jsonb_typeof(p_value)='object'
    AND (SELECT count(*) FROM jsonb_object_keys(p_value))=4
    AND p_value ?& ARRAY['appliedAt','reason','impactSummary','revision']
    AND NULLIF(btrim(p_value->>'appliedAt'),'') IS NOT NULL
    AND (p_value->>'appliedAt')::timestamptz IS NOT NULL
    AND NULLIF(btrim(p_value->>'reason'),'') IS NOT NULL
    AND NULLIF(btrim(p_value->>'impactSummary'),'') IS NOT NULL
    AND COALESCE(p_value->>'revision','') ~ '^[1-9][0-9]*$';
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;
ALTER FUNCTION editorial.correction_notice_valid_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.correction_notice_valid_v1(jsonb) FROM PUBLIC;

-- Immutable supplier/agency retention anchors contain only opaque identity and
-- digests.  Mutable entity rows and their plaintext never become legal-hold
-- targets directly.
CREATE TABLE ops.entity_retention_snapshots_v1 (
  snapshot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_kind text NOT NULL,
  subject_id uuid NOT NULL,
  subject_version bigint NOT NULL,
  subject_updated_at timestamptz NOT NULL,
  entity_state_digest char(64) NOT NULL,
  hold_coverage_digest char(64) NOT NULL,
  snapshot_payload jsonb NOT NULL,
  snapshot_canonical bytea NOT NULL,
  snapshot_digest char(64) NOT NULL UNIQUE,
  created_actor_type text NOT NULL,
  created_actor_id text NOT NULL,
  created_by uuid REFERENCES ops.users(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  receipt_digest char(64) NOT NULL UNIQUE,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT entity_retention_snapshots_v1_exact_uq UNIQUE(
    snapshot_id,snapshot_digest
  ),
  CONSTRAINT entity_retention_snapshots_v1_subject_uq UNIQUE(
    subject_kind,subject_id,subject_version,entity_state_digest
  ),
  CONSTRAINT entity_retention_snapshots_v1_retention_fk FOREIGN KEY (
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT entity_retention_snapshots_v1_class_fk
    FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  CONSTRAINT entity_retention_snapshots_v1_shape_ck CHECK (
    subject_kind IN ('AGENCY','SUPPLIER')
    AND subject_version>0
    AND retention_record_class='ENTITY_RETENTION_SNAPSHOT'
    AND created_actor_type='HUMAN'
    AND created_by IS NOT NULL
    AND created_actor_id=created_by::text
    AND ops.r6d_lower_sha256(entity_state_digest)
    AND ops.r6d_lower_sha256(hold_coverage_digest)
    AND ops.r6d_lower_sha256(snapshot_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND convert_from(snapshot_canonical,'UTF8')::jsonb=snapshot_payload
    AND snapshot_digest=encode(extensions.digest(snapshot_canonical,'sha256'),'hex')
    AND snapshot_payload ?& ARRAY[
      'schemaVersion','subjectKind','subjectId','subjectVersion',
      'subjectUpdatedAt','entityStateDigest','holdCoverageDigest'
    ]
    AND NOT snapshot_payload ?| ARRAY[
      'canonicalName','name','email','phone','address','contact','plaintext'
    ]
  )
);
ALTER TABLE ops.entity_retention_snapshots_v1 OWNER TO gurine_migrator;
REVOKE ALL ON ops.entity_retention_snapshots_v1 FROM PUBLIC;
GRANT SELECT ON ops.entity_retention_snapshots_v1
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER entity_retention_snapshots_v1_retention_bind
  BEFORE INSERT ON ops.entity_retention_snapshots_v1
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();
CREATE TRIGGER entity_retention_snapshots_v1_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.entity_retention_snapshots_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

ALTER TABLE ops.legal_hold_target_anchors
  ADD COLUMN entity_retention_snapshot_id uuid,
  ADD COLUMN entity_retention_snapshot_digest char(64);
ALTER TABLE ops.legal_hold_target_anchors
  DROP CONSTRAINT legal_hold_target_anchors_kind_ck,
  DROP CONSTRAINT legal_hold_target_anchors_shape_ck,
  DROP CONSTRAINT legal_hold_target_anchors_digest_ck;
ALTER TABLE ops.legal_hold_target_anchors
  ADD CONSTRAINT legal_hold_target_anchors_entity_snapshot_fk FOREIGN KEY (
    entity_retention_snapshot_id,entity_retention_snapshot_digest
  ) REFERENCES ops.entity_retention_snapshots_v1(snapshot_id,snapshot_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT legal_hold_target_anchors_kind_ck CHECK (
    target_kind IN (
      'CASE','PUBLICATION','EVIDENCE','RESPONSE','SOURCE_ASSET',
      'RESEARCH_ARTIFACT','PRIVACY_REQUEST','COMMUNICATION_SUBJECT',
      'SUPPLIER_RETENTION_SNAPSHOT','AGENCY_RETENTION_SNAPSHOT'
    )
  ),
  ADD CONSTRAINT legal_hold_target_anchors_shape_ck CHECK (
    (target_kind='CASE' AND case_id=target_id
      AND case_review_snapshot_id IS NOT NULL
      AND num_nonnulls(
        publication_revision_id,evidence_id,response_id,source_document_id,
        source_asset_id,research_artifact_id,research_asset_id,
        privacy_request_id,privacy_request_type,communication_subject_id,
        communication_subject_origin_digest,entity_retention_snapshot_id,
        entity_retention_snapshot_digest
      )=0)
    OR (target_kind='PUBLICATION' AND publication_revision_id=target_id
      AND num_nonnulls(
        case_id,case_review_snapshot_id,evidence_id,response_id,
        source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest
      )=0)
    OR (target_kind='EVIDENCE' AND evidence_id=target_id
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,response_id,
        source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest
      )=0)
    OR (target_kind='RESPONSE' AND response_id=target_id
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest,
        entity_retention_snapshot_id,entity_retention_snapshot_digest
      )=0)
    OR (target_kind='SOURCE_ASSET' AND source_asset_id=target_id
      AND source_document_id IS NOT NULL
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,research_artifact_id,research_asset_id,privacy_request_id,
        privacy_request_type,communication_subject_id,
        communication_subject_origin_digest,entity_retention_snapshot_id,
        entity_retention_snapshot_digest
      )=0)
    OR (target_kind='RESEARCH_ARTIFACT' AND research_asset_id=target_id
      AND research_artifact_id IS NOT NULL
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,privacy_request_id,
        privacy_request_type,communication_subject_id,
        communication_subject_origin_digest,entity_retention_snapshot_id,
        entity_retention_snapshot_digest
      )=0)
    OR (target_kind='PRIVACY_REQUEST' AND privacy_request_id=target_id
      AND privacy_request_type IN ('ACCESS','CORRECTION','DELETION','RESTRICTION')
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,communication_subject_id,
        communication_subject_origin_digest,entity_retention_snapshot_id,
        entity_retention_snapshot_digest
      )=0)
    OR (target_kind='COMMUNICATION_SUBJECT'
      AND communication_subject_id=target_id
      AND communication_subject_origin_digest IS NOT NULL
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        entity_retention_snapshot_id,entity_retention_snapshot_digest
      )=0)
    OR (target_kind IN (
          'SUPPLIER_RETENTION_SNAPSHOT','AGENCY_RETENTION_SNAPSHOT'
        )
      AND entity_retention_snapshot_id=target_id
      AND entity_retention_snapshot_digest=target_digest
      AND num_nonnulls(
        case_id,case_review_snapshot_id,publication_revision_id,evidence_id,
        response_id,source_document_id,source_asset_id,research_artifact_id,
        research_asset_id,privacy_request_id,privacy_request_type,
        communication_subject_id,communication_subject_origin_digest
      )=0)
  ),
  ADD CONSTRAINT legal_hold_target_anchors_digest_ck CHECK (
    ops.r6d_lower_sha256(target_digest)
    AND (communication_subject_origin_digest IS NULL
      OR ops.r6d_lower_sha256(communication_subject_origin_digest))
    AND (entity_retention_snapshot_digest IS NULL
      OR ops.r6d_lower_sha256(entity_retention_snapshot_digest))
    AND ops.r6d_lower_sha256(anchor_digest)
  );

ALTER TABLE editorial.legal_holds
  DROP CONSTRAINT legal_holds_object_type_check,
  ALTER COLUMN case_id DROP NOT NULL,
  ALTER COLUMN review_snapshot_id DROP NOT NULL;
ALTER TABLE editorial.legal_holds
  ADD CONSTRAINT legal_holds_object_type_check CHECK (
    object_type IN (
      'CASE','PUBLICATION','EVIDENCE','RESPONSE','SOURCE_ASSET',
      'RESEARCH_ARTIFACT','PRIVACY_REQUEST','COMMUNICATION_SUBJECT',
      'SUPPLIER_RETENTION_SNAPSHOT','AGENCY_RETENTION_SNAPSHOT'
    )
  ),
  ADD CONSTRAINT legal_holds_r6d_case_context_ck CHECK (
    (object_type IN ('CASE','PUBLICATION','EVIDENCE','RESPONSE')
      AND case_id IS NOT NULL AND review_snapshot_id IS NOT NULL)
    OR
    (object_type IN (
      'SOURCE_ASSET','RESEARCH_ARTIFACT','PRIVACY_REQUEST',
      'COMMUNICATION_SUBJECT','SUPPLIER_RETENTION_SNAPSHOT',
      'AGENCY_RETENTION_SNAPSHOT'
    ) AND case_id IS NULL AND review_snapshot_id IS NULL)
  );

CREATE TABLE ops.legal_hold_placement_receipts_v2 (
  receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legal_hold_id uuid NOT NULL UNIQUE REFERENCES editorial.legal_holds(id) ON DELETE RESTRICT,
  anchor_id uuid NOT NULL,
  anchor_digest char(64) NOT NULL,
  target_kind text NOT NULL,
  target_id uuid NOT NULL,
  target_version bigint NOT NULL,
  target_digest char(64) NOT NULL,
  actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL UNIQUE REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  outbox_event_id uuid NOT NULL UNIQUE REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  placed_at timestamptz NOT NULL,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  target_payload jsonb NOT NULL,
  target_canonical bytea NOT NULL,
  scope_atoms text[] NOT NULL,
  scope_atoms_digest char(64) NOT NULL,
  affected_ids uuid[] NOT NULL,
  affected_set_digest char(64) NOT NULL,
  authority_reference_digest char(64) NOT NULL,
  reason_digest char(64) NOT NULL,
  audit_receipt_digest char(64) NOT NULL,
  expires_at timestamptz,
  reason_code text NOT NULL,
  actor_assertion_jti uuid NOT NULL,
  actor_assertion_request_digest char(64) NOT NULL,
  step_up_authorization_id uuid NOT NULL,
  step_up_authorization_receipt_digest char(64) NOT NULL,
  step_up_issued_at timestamptz NOT NULL,
  step_up_expires_at timestamptz NOT NULL,
  action_digest char(64) NOT NULL,
  conflict_snapshot_id uuid NOT NULL,
  conflict_target_id text NOT NULL,
  conflict_snapshot_digest char(64) NOT NULL,
  conflict_receipt_digest char(64) NOT NULL,
  conflict_evaluation_state text NOT NULL,
  conflict_valid_until timestamptz NOT NULL,
  placement_approval_receipt_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT legal_hold_placement_receipts_v2_anchor_fk FOREIGN KEY(
    anchor_id,anchor_digest
  ) REFERENCES ops.legal_hold_target_anchors(id,anchor_digest) ON DELETE RESTRICT,
  CONSTRAINT legal_hold_placement_receipts_v2_target_fk FOREIGN KEY(
    target_kind,target_id,target_version,target_digest
  ) REFERENCES ops.legal_hold_target_anchors(
    target_kind,target_id,target_version,target_digest
  ) ON DELETE RESTRICT,
  CONSTRAINT legal_hold_placement_receipts_v2_id_digest_uq
    UNIQUE(receipt_id,receipt_digest),
  CONSTRAINT legal_hold_v2_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT legal_hold_v2_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  CONSTRAINT legal_hold_v2_class_ck CHECK(
    retention_record_class='LEGAL_HOLD_GOVERNANCE'
  ),
  CONSTRAINT legal_hold_placement_receipts_v2_actor_jti_uq
    UNIQUE(actor_assertion_jti),
  CONSTRAINT legal_hold_placement_receipts_v2_step_up_uq
    UNIQUE(step_up_authorization_id),
  CONSTRAINT legal_hold_placement_receipts_v2_conflict_fk FOREIGN KEY(
    conflict_snapshot_id,actor_id,target_kind,conflict_target_id,
    target_version,target_digest,conflict_snapshot_digest,
    conflict_evaluation_state,conflict_valid_until
  ) REFERENCES editorial.conflict_snapshots(
    id,subject_actor_id,target_type,target_id,target_version,target_digest,
    snapshot_sha256,evaluation_state,valid_until
  ) ON DELETE RESTRICT,
  CONSTRAINT legal_hold_placement_receipts_v2_shape_ck CHECK (
    target_kind IN (
      'CASE','PUBLICATION','EVIDENCE','RESPONSE','SOURCE_ASSET',
      'RESEARCH_ARTIFACT','PRIVACY_REQUEST','COMMUNICATION_SUBJECT',
      'SUPPLIER_RETENTION_SNAPSHOT','AGENCY_RETENTION_SNAPSHOT'
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
    AND jsonb_typeof(target_payload)='object'
    AND target_canonical=ops.canonical_jsonb_v1(target_payload)
    AND target_payload->>'targetKind'=target_kind
    AND (target_payload->>'targetId')::uuid=target_id
    AND (target_payload->>'targetVersion')::bigint=target_version
    AND target_payload->>'targetDigest'=btrim(target_digest)
    AND target_payload->>'targetAnchorDigest'=btrim(anchor_digest)
    AND (
      (target_kind='CASE'
        AND target_payload ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','caseId','reviewSnapshotId',
          'reviewSnapshotDigest'
        ]
        AND target_payload-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','caseId','reviewSnapshotId',
          'reviewSnapshotDigest'
        ]='{}'::jsonb)
      OR (target_kind='PUBLICATION'
        AND target_payload ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','publicationRevisionId'
        ]
        AND target_payload-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','publicationRevisionId'
        ]='{}'::jsonb)
      OR (target_kind='EVIDENCE'
        AND target_payload ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','evidenceId'
        ]
        AND target_payload-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','evidenceId'
        ]='{}'::jsonb)
      OR (target_kind='RESPONSE'
        AND target_payload ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','responseId'
        ]
        AND target_payload-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','responseId'
        ]='{}'::jsonb)
      OR (target_kind='SOURCE_ASSET'
        AND target_payload ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','sourceDocumentId','sourceAssetId'
        ]
        AND target_payload-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','sourceDocumentId','sourceAssetId'
        ]='{}'::jsonb)
      OR (target_kind='RESEARCH_ARTIFACT'
        AND target_payload ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','researchArtifactId','researchAssetId'
        ]
        AND target_payload-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','researchArtifactId','researchAssetId'
        ]='{}'::jsonb)
      OR (target_kind='PRIVACY_REQUEST'
        AND target_payload ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','privacyRequestId','privacyRequestType'
        ]
        AND target_payload-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','privacyRequestId','privacyRequestType'
        ]='{}'::jsonb)
      OR (target_kind='COMMUNICATION_SUBJECT'
        AND target_payload ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','communicationSubjectId',
          'communicationSubjectOriginDigest'
        ]
        AND target_payload-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','communicationSubjectId',
          'communicationSubjectOriginDigest'
        ]='{}'::jsonb)
      OR (target_kind='SUPPLIER_RETENTION_SNAPSHOT'
        AND target_payload->>'entityKind'='SUPPLIER'
        AND target_payload ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','entityKind','entityRetentionSnapshotId',
          'entityRetentionSnapshotDigest'
        ]
        AND target_payload-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','entityKind','entityRetentionSnapshotId',
          'entityRetentionSnapshotDigest'
        ]='{}'::jsonb)
      OR (target_kind='AGENCY_RETENTION_SNAPSHOT'
        AND target_payload->>'entityKind'='AGENCY'
        AND target_payload ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','entityKind','entityRetentionSnapshotId',
          'entityRetentionSnapshotDigest'
        ]
        AND target_payload-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'targetAnchorDigest','entityKind','entityRetentionSnapshotId',
          'entityRetentionSnapshotDigest'
        ]='{}'::jsonb)
    )
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
    AND receipt_payload->>'schemaVersion'='legal-hold-placement-receipt.v2'
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
  )
);
ALTER TABLE ops.legal_hold_placement_receipts_v2 OWNER TO gurine_migrator;
REVOKE ALL ON ops.legal_hold_placement_receipts_v2 FROM PUBLIC;
GRANT SELECT ON ops.legal_hold_placement_receipts_v2
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER legal_hold_placement_receipts_v2_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.legal_hold_placement_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE OR REPLACE FUNCTION ops.lock_research_hold_domain_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,pg_temp
AS $$
DECLARE v_id text;
BEGIN
  IF NEW.object_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(NEW.object_id::text,13));
  END IF;
  IF NEW.case_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(NEW.case_id::text,13));
  END IF;
  FOR v_id IN
    SELECT value FROM jsonb_array_elements_text(COALESCE(NEW.affected_ids,'[]'::jsonb))
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_id,13));
  END LOOP;
  RETURN NEW;
END
$$;
ALTER FUNCTION ops.lock_research_hold_domain_v1() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.lock_research_hold_domain_v1() FROM PUBLIC;

-- Restore the response owned-intake contract declared in the 0027 authority.
-- Legacy rows are backfilled with their own immutable receipt digest; only the
-- v2 materializer can populate the reciprocal ownership tuple.
ALTER TABLE intake.response_submissions
  ADD COLUMN receipt_version bigint NOT NULL DEFAULT 1,
  ADD COLUMN receipt_digest char(64),
  ADD COLUMN receipt_updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  ADD COLUMN owned_intake_event_id uuid,
  ADD COLUMN owned_intake_event_envelope_digest char(64),
  ADD COLUMN owned_intake_receipt_digest char(64),
  ADD COLUMN submission_outbox_event_id uuid,
  ADD COLUMN submission_event_envelope_digest char(64),
  ADD COLUMN submission_idempotency_key_sha256 char(64),
  ADD COLUMN submission_request_digest char(64),
  ADD COLUMN receipt_session_id uuid;
UPDATE intake.response_submissions AS submission
SET receipt_digest=encode(extensions.digest(ops.canonical_jsonb_v1(
  jsonb_build_object(
    'schemaVersion','response-submission-receipt.v1',
    'responseSubmissionId',submission.id,
    'responseRequestId',submission.response_request_id,
    'draftVersion',submission.draft_version,
    'submissionSha256',btrim(submission.submission_sha256),
    'submittedAt',submission.submitted_at,'receiptVersion',1
  )
),'sha256'),'hex');
ALTER TABLE intake.response_submissions
  ALTER COLUMN receipt_digest SET NOT NULL,
  ADD CONSTRAINT response_submissions_receipt_identity_uq UNIQUE(
    id,receipt_version,receipt_digest
  ),
  ADD CONSTRAINT response_submissions_request_receipt_identity_uq UNIQUE(
    id,response_request_id,receipt_version,receipt_digest
  ),
  ADD CONSTRAINT response_submissions_editorial_response_uq UNIQUE(
    editorial_response_id
  ),
  ADD CONSTRAINT response_submissions_owned_intake_binding_uq UNIQUE(
    id,response_request_id,receipt_version,receipt_digest,
    editorial_response_id,owned_intake_event_id,
    owned_intake_event_envelope_digest,owned_intake_receipt_digest
  ),
  ADD CONSTRAINT response_submissions_owned_intake_event_uq UNIQUE(
    owned_intake_event_id
  ),
  ADD CONSTRAINT response_submissions_submission_outbox_uq UNIQUE(
    submission_outbox_event_id
  ),
  ADD CONSTRAINT response_submissions_submission_idempotency_uq UNIQUE(
    submission_idempotency_key_sha256
  ),
  ADD CONSTRAINT response_submissions_receipt_session_uq UNIQUE(
    receipt_session_id
  ),
  ADD CONSTRAINT response_submissions_owned_intake_shape_ck CHECK (
    num_nonnulls(
      editorial_response_id,owned_intake_event_id,
      owned_intake_event_envelope_digest,owned_intake_receipt_digest
    ) IN (0,4)
    AND receipt_version>0
    AND ops.r6d_lower_sha256(receipt_digest)
    AND (owned_intake_event_envelope_digest IS NULL
      OR ops.r6d_lower_sha256(owned_intake_event_envelope_digest))
    AND (owned_intake_receipt_digest IS NULL
      OR ops.r6d_lower_sha256(owned_intake_receipt_digest))
    AND num_nonnulls(
      submission_outbox_event_id,submission_event_envelope_digest,
      submission_idempotency_key_sha256,submission_request_digest,
      receipt_session_id
    ) IN (0,5)
    AND (submission_event_envelope_digest IS NULL
      OR ops.r6d_lower_sha256(submission_event_envelope_digest))
    AND (submission_idempotency_key_sha256 IS NULL
      OR ops.r6d_lower_sha256(submission_idempotency_key_sha256))
    AND (submission_request_digest IS NULL
      OR ops.r6d_lower_sha256(submission_request_digest))
  );

ALTER TABLE editorial.responses
  ADD COLUMN submission_receipt_version bigint,
  ADD COLUMN submission_receipt_digest char(64),
  ADD COLUMN owned_intake_event_id uuid,
  ADD COLUMN owned_intake_event_envelope_digest char(64),
  ADD COLUMN owned_intake_receipt_digest char(64),
  ADD COLUMN party_type text,
  ADD COLUMN party_entity_id uuid,
  ADD COLUMN response_content_sha256 char(64),
  ADD COLUMN publication_consent_sha256 char(64),
  ADD COLUMN organization_identity_status text,
  ADD COLUMN publication_form text,
  ADD COLUMN organization_identity_assertion_id uuid;
ALTER TABLE editorial.responses
  ADD CONSTRAINT editorial_responses_submission_uq UNIQUE(submission_id),
  ADD CONSTRAINT editorial_responses_owned_intake_event_uq UNIQUE(
    owned_intake_event_id
  ),
  ADD CONSTRAINT editorial_responses_owned_intake_binding_uq UNIQUE(
    id,response_request_id,submission_id,submission_receipt_version,
    submission_receipt_digest,owned_intake_event_id,
    owned_intake_event_envelope_digest,owned_intake_receipt_digest
  ),
  ADD CONSTRAINT editorial_responses_owned_intake_shape_ck CHECK (
    num_nonnulls(
      submission_id,submission_receipt_version,submission_receipt_digest,
      owned_intake_event_id,owned_intake_event_envelope_digest,
      owned_intake_receipt_digest,party_type,response_content_sha256,
      publication_consent_sha256,organization_identity_status,
      publication_form
    ) IN (0,11)
    AND (submission_receipt_version IS NULL OR submission_receipt_version>0)
    AND (submission_receipt_digest IS NULL
      OR ops.r6d_lower_sha256(submission_receipt_digest))
    AND (owned_intake_event_envelope_digest IS NULL
      OR ops.r6d_lower_sha256(owned_intake_event_envelope_digest))
    AND (owned_intake_receipt_digest IS NULL
      OR ops.r6d_lower_sha256(owned_intake_receipt_digest))
    AND (response_content_sha256 IS NULL
      OR ops.r6d_lower_sha256(response_content_sha256))
    AND (publication_consent_sha256 IS NULL
      OR ops.r6d_lower_sha256(publication_consent_sha256))
    AND (party_type IS NULL OR party_type IN ('AGENCY','SUPPLIER','OTHER'))
    AND (organization_identity_status IS NULL
      OR organization_identity_status IN ('UNVERIFIED','SECOND_FACTOR_VERIFIED'))
    AND (publication_form IS NULL
      OR publication_form IN ('INTERNAL_ONLY','ANONYMOUS','FULL','REDACTED'))
    AND (organization_identity_status IS DISTINCT FROM 'UNVERIFIED'
      OR publication_form IS DISTINCT FROM 'FULL')
    AND (organization_identity_status IS DISTINCT FROM 'UNVERIFIED'
      OR publication_form IS DISTINCT FROM 'REDACTED')
  );
ALTER TABLE editorial.responses
  -- Existing pre-R6d responses remain staged legacy. NOT VALID skips only the
  -- historical scan; PostgreSQL still enforces this exact tuple on new writes
  -- and whenever the reciprocal columns are materialized.
  ADD CONSTRAINT editorial_responses_submission_reciprocal_fk FOREIGN KEY(
    submission_id,response_request_id,submission_receipt_version,
    submission_receipt_digest,id,owned_intake_event_id,
    owned_intake_event_envelope_digest,owned_intake_receipt_digest
  ) REFERENCES intake.response_submissions(
    id,response_request_id,receipt_version,receipt_digest,
    editorial_response_id,owned_intake_event_id,
    owned_intake_event_envelope_digest,owned_intake_receipt_digest
  ) MATCH FULL ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED NOT VALID;
ALTER TABLE intake.response_submissions
  -- Existing submissions have no invented editorial ownership tuple. New and
  -- updated reciprocal bindings remain checked by the NOT VALID constraint.
  ADD CONSTRAINT response_submissions_editorial_response_reciprocal_fk
  FOREIGN KEY(
    editorial_response_id,response_request_id,id,receipt_version,
    receipt_digest,owned_intake_event_id,owned_intake_event_envelope_digest,
    owned_intake_receipt_digest
  ) REFERENCES editorial.responses(
    id,response_request_id,submission_id,submission_receipt_version,
    submission_receipt_digest,owned_intake_event_id,
    owned_intake_event_envelope_digest,owned_intake_receipt_digest
  ) MATCH FULL ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED NOT VALID;

CREATE TYPE editorial.response_submission_intake_materialize_v1 AS (
  source_event_id uuid,
  source_event_envelope_digest char(64),
  response_submission_id uuid,
  response_request_id uuid,
  response_request_version bigint,
  response_request_binding_digest char(64),
  submission_sha256 char(64),
  receipt_version bigint,
  receipt_digest char(64),
  submitted_at timestamptz
);
CREATE TYPE editorial.response_submission_intake_materialize_receipt_v1 AS (
  disposition text,
  source_event_id uuid,
  response_submission_id uuid,
  response_request_id uuid,
  editorial_response_id uuid,
  submission_receipt_version bigint,
  submission_receipt_digest char(64),
  owned_intake_receipt_digest char(64),
  audit_event_id uuid,
  emitted_event_id uuid,
  result_digest char(64)
);
CREATE TYPE editorial.response_submission_intake_materialize_receipt_v2 AS (
  disposition text,
  source_event_id uuid,
  response_submission_id uuid,
  response_request_id uuid,
  editorial_response_id uuid,
  party_type text,
  party_entity_id uuid,
  response_version bigint,
  response_content_sha256 char(64),
  publication_consent_sha256 char(64),
  identity_status text,
  publication_form text,
  submission_receipt_version bigint,
  submission_receipt_digest char(64),
  owned_intake_receipt_digest char(64),
  audit_event_id uuid,
  emitted_event_id uuid,
  materialized_at timestamptz,
  result_digest char(64)
);

CREATE TABLE editorial.response_submission_origin_receipts_v2 (
  receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_event_id uuid NOT NULL UNIQUE REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  source_event_envelope_digest char(64) NOT NULL,
  response_submission_id uuid NOT NULL UNIQUE,
  response_request_id uuid NOT NULL,
  editorial_response_id uuid NOT NULL UNIQUE,
  party_type text NOT NULL,
  party_entity_id uuid,
  response_version bigint NOT NULL,
  response_content_sha256 char(64) NOT NULL,
  publication_consent_sha256 char(64) NOT NULL,
  identity_status text NOT NULL DEFAULT 'UNVERIFIED',
  publication_form text NOT NULL DEFAULT 'INTERNAL_ONLY',
  submission_receipt_version bigint NOT NULL,
  submission_receipt_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL UNIQUE REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  emitted_event_id uuid NOT NULL UNIQUE REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  owned_intake_receipt_digest char(64) NOT NULL UNIQUE,
  result_digest char(64) NOT NULL UNIQUE,
  materialized_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT response_submission_origin_receipts_v2_submission_fk FOREIGN KEY(
    response_submission_id,response_request_id,submission_receipt_version,
    submission_receipt_digest,editorial_response_id,source_event_id,
    source_event_envelope_digest,owned_intake_receipt_digest
  ) REFERENCES intake.response_submissions(
    id,response_request_id,receipt_version,receipt_digest,
    editorial_response_id,owned_intake_event_id,
    owned_intake_event_envelope_digest,owned_intake_receipt_digest
  ) ON DELETE RESTRICT,
  CONSTRAINT response_submission_origin_receipts_v2_shape_ck CHECK (
    party_type IN ('AGENCY','SUPPLIER','OTHER')
    AND ((party_type IN ('AGENCY','SUPPLIER') AND party_entity_id IS NOT NULL)
      OR (party_type='OTHER' AND party_entity_id IS NULL))
    AND response_version=1 AND identity_status='UNVERIFIED'
    AND publication_form='INTERNAL_ONLY'
    AND submission_receipt_version>0
    AND ops.r6d_lower_sha256(source_event_envelope_digest)
    AND ops.r6d_lower_sha256(response_content_sha256)
    AND ops.r6d_lower_sha256(publication_consent_sha256)
    AND ops.r6d_lower_sha256(submission_receipt_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(owned_intake_receipt_digest)
    AND ops.r6d_lower_sha256(result_digest)
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND owned_intake_receipt_digest=
      encode(extensions.digest(receipt_canonical,'sha256'),'hex')
  )
);
ALTER TABLE editorial.response_submission_origin_receipts_v2 OWNER TO gurine_migrator;
REVOKE ALL ON editorial.response_submission_origin_receipts_v2 FROM PUBLIC;
GRANT SELECT ON editorial.response_submission_origin_receipts_v2
  TO gurine_workflow_worker,gurine_control_api,gurine_auditor;
CREATE TRIGGER response_submission_origin_receipts_v2_immutable_guard
  BEFORE UPDATE OR DELETE ON editorial.response_submission_origin_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

-- R6d Q2 authority closure: immutable organization official-channel registry.
--
-- Merge point: before editorial.response_organization_identity_assertions_v1
-- in 0038_r6d_legal_hardening.sql.  This is a review/merge snippet, not a new
-- migration.  No operating seed and no runtime writer are authorized.
-- Future population must be a separately approved owner routine.  Until then,
-- production activation remains fail-closed; runtime probes use migrator-owned
-- fixtures only.
-- OFFICIAL_DOMAIN_EMAIL is not an OTP-to-organization inference: it binds a
-- consumed VERIFIED SMTP endpoint proof plus a separate organization-owned
-- domain-authority receipt digest.  OFFICIAL_DOCUMENT binds the exact source
-- artifact/locator digest plus a separate organization-representation receipt.
-- Before creating either table, extend ops.bind_r6d_identity_schedule_v1's
-- TG_TABLE_SCHEMA/TG_TABLE_NAME CASE with both relations below, each mapped to
-- RESPONSE_IDENTITY_GOVERNANCE.  The BEFORE INSERT triggers intentionally make
-- every insert fail closed when that exact approved schedule is absent.

CREATE TABLE editorial.organization_official_channel_assertions_v1 (
  assertion_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assertion_version bigint NOT NULL DEFAULT 1,
  organization_kind text NOT NULL,
  organization_id uuid NOT NULL,
  agency_id uuid REFERENCES core.agencies(id) ON DELETE RESTRICT,
  supplier_id uuid REFERENCES core.suppliers(id) ON DELETE RESTRICT,
  verification_method text NOT NULL,
  source_purpose text NOT NULL,

  communication_subject_id uuid,
  communication_subject_origin_digest char(64),
  communication_subject_profile_version bigint,
  communication_subject_profile_digest char(64),
  communication_endpoint_id uuid,
  communication_endpoint_version bigint,
  communication_endpoint_digest char(64),
  communication_verification_id uuid,

  official_document_evidence_id uuid REFERENCES editorial.evidence(id)
    ON DELETE RESTRICT,
  official_document_evidence_version bigint,
  official_document_content_sha256 char(64),
  official_document_source_document_id uuid REFERENCES raw.source_documents(id)
    ON DELETE RESTRICT,
  official_document_source_document_sha256 char(64),
  official_document_locator_sha256 char(64),

  underlying_source_proof_digest char(64) NOT NULL,
  organization_authority_receipt_kind text NOT NULL,
  organization_authority_receipt_digest char(64) NOT NULL,
  organization_source_binding_payload jsonb NOT NULL,
  organization_source_binding_canonical bytea NOT NULL,
  organization_source_binding_digest char(64) NOT NULL UNIQUE,
  independent_verifier_user_id uuid NOT NULL REFERENCES ops.users(id)
    ON DELETE RESTRICT,
  verified_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  assertion_payload jsonb NOT NULL,
  assertion_canonical bytea NOT NULL,
  assertion_digest char(64) NOT NULL UNIQUE,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),

  CONSTRAINT organization_official_channel_assertions_v1_org_shape_ck CHECK (
    (organization_kind='AGENCY' AND agency_id IS NOT NULL
      AND agency_id=organization_id AND supplier_id IS NULL)
    OR
    (organization_kind='SUPPLIER' AND supplier_id IS NOT NULL
      AND supplier_id=organization_id AND agency_id IS NULL)
  ),
  CONSTRAINT organization_official_channel_assertions_v1_source_shape_ck CHECK (
    assertion_version=1 AND verified_at<expires_at AND created_at>=verified_at
    AND verification_method IN ('OFFICIAL_DOMAIN_EMAIL','OFFICIAL_DOCUMENT')
    AND (
      (verification_method='OFFICIAL_DOMAIN_EMAIL'
        AND source_purpose='OFFICIAL_DOMAIN_CONTROL'
        AND organization_authority_receipt_kind=
          'ORGANIZATION_DOMAIN_CONTROL'
        AND num_nonnulls(
          communication_subject_id,communication_subject_origin_digest,
          communication_subject_profile_version,
          communication_subject_profile_digest,communication_endpoint_id,
          communication_endpoint_version,communication_endpoint_digest,
          communication_verification_id
        )=8
        AND num_nonnulls(
          official_document_evidence_id,official_document_evidence_version,
          official_document_content_sha256,
          official_document_source_document_id,
          official_document_source_document_sha256,
          official_document_locator_sha256
        )=0)
      OR
      (verification_method='OFFICIAL_DOCUMENT'
        AND source_purpose='OFFICIAL_REPRESENTATION'
        AND organization_authority_receipt_kind=
          'OFFICIAL_REPRESENTATION_BINDING'
        AND num_nonnulls(
          communication_subject_id,communication_subject_origin_digest,
          communication_subject_profile_version,
          communication_subject_profile_digest,communication_endpoint_id,
          communication_endpoint_version,communication_endpoint_digest,
          communication_verification_id
        )=0
        AND num_nonnulls(
          official_document_evidence_id,official_document_evidence_version,
          official_document_content_sha256,
          official_document_source_document_id,
          official_document_source_document_sha256,
          official_document_locator_sha256
        )=6)
    )
    AND (communication_subject_profile_version IS NULL
      OR communication_subject_profile_version>0)
    AND (communication_endpoint_version IS NULL
      OR communication_endpoint_version>0)
    AND (official_document_evidence_version IS NULL
      OR official_document_evidence_version>0)
    AND (communication_subject_origin_digest IS NULL
      OR ops.r6d_lower_sha256(communication_subject_origin_digest))
    AND (communication_subject_profile_digest IS NULL
      OR ops.r6d_lower_sha256(communication_subject_profile_digest))
    AND (communication_endpoint_digest IS NULL
      OR ops.r6d_lower_sha256(communication_endpoint_digest))
    AND (official_document_content_sha256 IS NULL
      OR ops.r6d_lower_sha256(official_document_content_sha256))
    AND (official_document_source_document_sha256 IS NULL
      OR ops.r6d_lower_sha256(official_document_source_document_sha256))
    AND (official_document_locator_sha256 IS NULL
      OR ops.r6d_lower_sha256(official_document_locator_sha256))
    AND ops.r6d_lower_sha256(underlying_source_proof_digest)
    AND ops.r6d_lower_sha256(organization_authority_receipt_digest)
    AND ops.r6d_lower_sha256(organization_source_binding_digest)
    AND ops.r6d_lower_sha256(assertion_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND convert_from(organization_source_binding_canonical,'UTF8')::jsonb
      =organization_source_binding_payload
    AND organization_source_binding_canonical=
      ops.canonical_jsonb_v1(organization_source_binding_payload)
    AND organization_source_binding_payload=jsonb_strip_nulls(
      jsonb_build_object(
        'schemaVersion','organization-official-channel-source-binding.v1',
        'organizationKind',organization_kind,
        'organizationId',organization_id,
        'verificationMethod',verification_method,
        'sourcePurpose',source_purpose,
        'communicationSubjectId',communication_subject_id,
        'communicationSubjectOriginDigest',
          communication_subject_origin_digest,
        'communicationSubjectProfileVersion',
          communication_subject_profile_version,
        'communicationSubjectProfileDigest',
          communication_subject_profile_digest,
        'communicationEndpointId',communication_endpoint_id,
        'communicationEndpointVersion',communication_endpoint_version,
        'communicationEndpointDigest',communication_endpoint_digest,
        'communicationVerificationId',communication_verification_id,
        'officialDocumentEvidenceId',official_document_evidence_id,
        'officialDocumentEvidenceVersion',official_document_evidence_version,
        'officialDocumentContentSha256',official_document_content_sha256,
        'officialDocumentSourceDocumentId',
          official_document_source_document_id,
        'officialDocumentSourceDocumentSha256',
          official_document_source_document_sha256,
        'officialDocumentLocatorSha256',official_document_locator_sha256,
        'underlyingSourceProofDigest',underlying_source_proof_digest,
        'organizationAuthorityReceiptKind',
          organization_authority_receipt_kind,
        'organizationAuthorityReceiptDigest',
          organization_authority_receipt_digest
      )
    )
    AND organization_source_binding_digest=encode(extensions.digest(
      organization_source_binding_canonical,'sha256'),'hex')
    AND convert_from(assertion_canonical,'UTF8')::jsonb=assertion_payload
    AND assertion_canonical=ops.canonical_jsonb_v1(assertion_payload)
    AND assertion_payload=jsonb_build_object(
      'schemaVersion','organization-official-channel-assertion.v1',
      'assertionId',assertion_id,'assertionVersion',assertion_version,
      'organizationKind',organization_kind,'organizationId',organization_id,
      'verificationMethod',verification_method,'sourcePurpose',source_purpose,
      'organizationSourceBindingDigest',organization_source_binding_digest,
      'independentVerifierUserId',independent_verifier_user_id,
      'verifiedAt',verified_at,'expiresAt',expires_at
    )
    AND assertion_digest=encode(extensions.digest(
      assertion_canonical,'sha256'),'hex')
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_canonical=ops.canonical_jsonb_v1(receipt_payload)
    AND receipt_payload=jsonb_build_object(
      'schemaVersion','organization-official-channel-receipt.v1',
      'assertionId',assertion_id,'assertionDigest',assertion_digest,
      'organizationSourceBindingDigest',organization_source_binding_digest,
      'underlyingSourceProofDigest',underlying_source_proof_digest,
      'organizationAuthorityReceiptKind',
        organization_authority_receipt_kind,
      'organizationAuthorityReceiptDigest',
        organization_authority_receipt_digest,
      'verifiedAt',verified_at,'expiresAt',expires_at
    )
    AND receipt_digest=encode(extensions.digest(
      receipt_canonical,'sha256'),'hex')
  ),
  CONSTRAINT organization_official_channel_assertions_v1_subject_fk
    FOREIGN KEY(communication_subject_id,communication_subject_origin_digest)
    REFERENCES intake.communication_subjects(id,origin_binding_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT organization_official_channel_assertions_v1_endpoint_fk
    FOREIGN KEY(
      communication_endpoint_id,communication_endpoint_version,
      communication_endpoint_digest
    ) REFERENCES intake.communication_endpoints(id,version,endpoint_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT organization_official_channel_assertions_v1_verification_fk
    FOREIGN KEY(communication_verification_id)
    REFERENCES intake.communication_endpoint_verifications(id)
    ON DELETE RESTRICT,
  CONSTRAINT organization_official_channel_assertions_v1_exact_uq UNIQUE(
    assertion_id,assertion_digest,organization_source_binding_digest,
    receipt_digest
  ),
  CONSTRAINT organization_official_channel_assertions_v1_retention_fk
    FOREIGN KEY(
      retention_schedule_id,retention_record_class,
      retention_schedule_digest
    ) REFERENCES ops.record_class_schedules(
      id,record_class,schedule_digest
    ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT organization_official_channel_assertions_v1_class_fk
    FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class)
    ON DELETE RESTRICT,
  CONSTRAINT organization_official_channel_assertions_v1_class_ck CHECK(
    retention_record_class='RESPONSE_IDENTITY_GOVERNANCE'
  )
);
ALTER TABLE editorial.organization_official_channel_assertions_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON editorial.organization_official_channel_assertions_v1 FROM PUBLIC;
REVOKE ALL ON editorial.organization_official_channel_assertions_v1
  FROM gurine_control_api,gurine_submission_api,gurine_workflow_worker,
    gurine_analysis_worker,gurine_public_projector,gurine_notification_worker;
GRANT SELECT ON editorial.organization_official_channel_assertions_v1
  TO gurine_auditor;
CREATE UNIQUE INDEX organization_official_channel_email_source_uq
  ON editorial.organization_official_channel_assertions_v1(
    communication_verification_id
  ) WHERE communication_verification_id IS NOT NULL;
CREATE UNIQUE INDEX organization_official_channel_document_source_uq
  ON editorial.organization_official_channel_assertions_v1(
    official_document_evidence_id
  ) WHERE official_document_evidence_id IS NOT NULL;
CREATE TRIGGER organization_official_channel_assertions_v1_immutable_guard
  BEFORE UPDATE OR DELETE
  ON editorial.organization_official_channel_assertions_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER organization_official_channel_assertions_v1_retention_bind
  BEFORE INSERT
  ON editorial.organization_official_channel_assertions_v1
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

CREATE TABLE editorial.organization_official_channel_revocation_receipts_v1 (
  revocation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assertion_id uuid NOT NULL UNIQUE,
  assertion_digest char(64) NOT NULL,
  organization_source_binding_digest char(64) NOT NULL,
  assertion_receipt_digest char(64) NOT NULL,
  reason_code text NOT NULL,
  reason_digest char(64) NOT NULL,
  revoked_by_user_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  revoked_at timestamptz NOT NULL,
  revocation_payload jsonb NOT NULL,
  revocation_canonical bytea NOT NULL,
  revocation_receipt_digest char(64) NOT NULL UNIQUE,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT organization_official_channel_revocations_assertion_fk
    FOREIGN KEY(
      assertion_id,assertion_digest,organization_source_binding_digest,
      assertion_receipt_digest
    ) REFERENCES editorial.organization_official_channel_assertions_v1(
      assertion_id,assertion_digest,organization_source_binding_digest,
      receipt_digest
    ) ON DELETE RESTRICT,
  CONSTRAINT organization_official_channel_revocations_v1_shape_ck CHECK (
    length(btrim(reason_code)) BETWEEN 1 AND 100
    AND reason_code ~ '^[A-Z][A-Z0-9_]*$'
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
  ),
  CONSTRAINT organization_official_channel_revocations_v1_retention_fk
    FOREIGN KEY(
      retention_schedule_id,retention_record_class,
      retention_schedule_digest
    ) REFERENCES ops.record_class_schedules(
      id,record_class,schedule_digest
    ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT organization_official_channel_revocations_v1_class_fk
    FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class)
    ON DELETE RESTRICT,
  CONSTRAINT organization_official_channel_revocations_v1_class_ck CHECK(
    retention_record_class='RESPONSE_IDENTITY_GOVERNANCE'
  )
);
ALTER TABLE editorial.organization_official_channel_revocation_receipts_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON editorial.organization_official_channel_revocation_receipts_v1
  FROM PUBLIC;
REVOKE ALL ON editorial.organization_official_channel_revocation_receipts_v1
  FROM gurine_control_api,gurine_submission_api,gurine_workflow_worker,
    gurine_analysis_worker,gurine_public_projector,gurine_notification_worker;
GRANT SELECT ON editorial.organization_official_channel_revocation_receipts_v1
  TO gurine_auditor;
CREATE TRIGGER organization_official_channel_revocations_v1_immutable_guard
  BEFORE UPDATE OR DELETE
  ON editorial.organization_official_channel_revocation_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER organization_official_channel_revocations_v1_retention_bind
  BEFORE INSERT
  ON editorial.organization_official_channel_revocation_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

-- This owner-only validator is deliberately VOLATILE: FOR UPDATE serializes an
-- approval/identity check with a future revocation writer's FK key lock.  The
-- future revocation owner must use the same assertion row lock before append.
CREATE TABLE editorial.response_organization_identity_assertions_v1 (
  assertion_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  response_id uuid NOT NULL UNIQUE REFERENCES editorial.responses(id) ON DELETE RESTRICT,
  response_request_id uuid NOT NULL REFERENCES editorial.response_requests(id) ON DELETE RESTRICT,
  response_submission_id uuid NOT NULL REFERENCES intake.response_submissions(id) ON DELETE RESTRICT,
  response_version bigint NOT NULL,
  response_content_sha256 char(64) NOT NULL,
  publication_consent_sha256 char(64) NOT NULL,
  organization_kind text NOT NULL,
  organization_id uuid NOT NULL,
  publication_form text NOT NULL,
  identity_status text NOT NULL DEFAULT 'SECOND_FACTOR_VERIFIED',
  verification_method text NOT NULL,
  official_channel_source_id uuid NOT NULL,
  communication_subject_id uuid,
  communication_endpoint_id uuid,
  communication_verification_id uuid,
  official_document_evidence_id uuid,
  source_verification_receipt_digest char(64) NOT NULL,
  subject_binding_digest char(64) NOT NULL,
  evidence_set_digest char(64) NOT NULL,
  policy_digest char(64) NOT NULL,
  assertion_version bigint NOT NULL DEFAULT 1,
  reason_digest char(64) NOT NULL,
  actor_assertion_jti uuid NOT NULL UNIQUE,
  step_up_authorization_id uuid NOT NULL UNIQUE REFERENCES ops.step_up_authorizations(id) ON DELETE RESTRICT,
  step_up_authorization_receipt_digest char(64) NOT NULL,
  actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL UNIQUE REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  audit_receipt_digest char(64) NOT NULL,
  outbox_event_id uuid NOT NULL UNIQUE REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  assertion_payload jsonb NOT NULL,
  assertion_canonical bytea NOT NULL,
  assertion_digest char(64) NOT NULL UNIQUE,
  receipt_digest char(64) NOT NULL UNIQUE,
  verified_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT response_org_identity_assertions_v1_method_shape_ck CHECK (
    organization_kind IN ('AGENCY','SUPPLIER')
    AND response_version>0 AND assertion_version=1
    AND publication_form IN ('FULL','REDACTED')
    AND identity_status='SECOND_FACTOR_VERIFIED'
    AND verification_method IN ('OFFICIAL_DOMAIN_EMAIL','OFFICIAL_DOCUMENT')
    AND (
      (verification_method='OFFICIAL_DOMAIN_EMAIL'
       AND num_nonnulls(
         communication_subject_id,communication_endpoint_id,
         communication_verification_id
       )=3 AND official_document_evidence_id IS NULL)
      OR
      (verification_method='OFFICIAL_DOCUMENT'
       AND official_document_evidence_id IS NOT NULL
       AND num_nonnulls(
         communication_subject_id,communication_endpoint_id,
         communication_verification_id
       )=0)
    )
    AND ops.r6d_lower_sha256(response_content_sha256)
    AND ops.r6d_lower_sha256(publication_consent_sha256)
    AND ops.r6d_lower_sha256(source_verification_receipt_digest)
    AND ops.r6d_lower_sha256(subject_binding_digest)
    AND ops.r6d_lower_sha256(evidence_set_digest)
    AND ops.r6d_lower_sha256(policy_digest)
    AND ops.r6d_lower_sha256(reason_digest)
    AND ops.r6d_lower_sha256(step_up_authorization_receipt_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(audit_receipt_digest)
    AND ops.r6d_lower_sha256(assertion_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND convert_from(assertion_canonical,'UTF8')::jsonb=assertion_payload
    AND assertion_digest=encode(extensions.digest(assertion_canonical,'sha256'),'hex')
  )
);
ALTER TABLE editorial.response_organization_identity_assertions_v1 OWNER TO gurine_migrator;
REVOKE ALL ON editorial.response_organization_identity_assertions_v1 FROM PUBLIC;
GRANT SELECT ON editorial.response_organization_identity_assertions_v1
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER response_org_identity_assertions_v1_immutable_guard
  BEFORE UPDATE OR DELETE ON editorial.response_organization_identity_assertions_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

ALTER TABLE editorial.response_organization_identity_assertions_v1
  ADD CONSTRAINT response_org_identity_official_channel_fk
  FOREIGN KEY(official_channel_source_id)
  REFERENCES editorial.organization_official_channel_assertions_v1(assertion_id)
  ON DELETE RESTRICT;

CREATE TABLE editorial.response_publication_identity_receipts_v1 (
  receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assertion_id uuid NOT NULL UNIQUE REFERENCES editorial.response_organization_identity_assertions_v1(assertion_id) ON DELETE RESTRICT,
  response_id uuid NOT NULL UNIQUE REFERENCES editorial.responses(id) ON DELETE RESTRICT,
  response_version bigint NOT NULL,
  response_content_sha256 char(64) NOT NULL,
  publication_consent_sha256 char(64) NOT NULL,
  organization_id uuid NOT NULL,
  publication_form text NOT NULL,
  identity_status text NOT NULL,
  assertion_digest char(64) NOT NULL,
  source_verification_receipt_digest char(64) NOT NULL,
  active boolean NOT NULL DEFAULT true,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT response_publication_identity_receipts_v1_shape_ck CHECK (
    response_version>0 AND publication_form IN ('FULL','REDACTED')
    AND identity_status='SECOND_FACTOR_VERIFIED' AND active
    AND ops.r6d_lower_sha256(response_content_sha256)
    AND ops.r6d_lower_sha256(publication_consent_sha256)
    AND ops.r6d_lower_sha256(assertion_digest)
    AND ops.r6d_lower_sha256(source_verification_receipt_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(extensions.digest(receipt_canonical,'sha256'),'hex')
  )
);
ALTER TABLE editorial.response_publication_identity_receipts_v1 OWNER TO gurine_migrator;
REVOKE ALL ON editorial.response_publication_identity_receipts_v1 FROM PUBLIC;
GRANT SELECT ON editorial.response_publication_identity_receipts_v1
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER response_publication_identity_receipts_v1_immutable_guard
  BEFORE UPDATE OR DELETE ON editorial.response_publication_identity_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

ALTER TABLE editorial.responses
  ADD CONSTRAINT editorial_responses_org_assertion_fk FOREIGN KEY(
    organization_identity_assertion_id
  ) REFERENCES editorial.response_organization_identity_assertions_v1(assertion_id)
    ON DELETE RESTRICT;

CREATE OR REPLACE FUNCTION ops.r6d_outbox_envelope_digest_v1(p_event_id uuid)
RETURNS char(64)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(jsonb_build_object(
    'eventId',event.id,'aggregateType',event.aggregate_type,
    'aggregateId',event.aggregate_id,'aggregateVersion',event.aggregate_version,
    'eventType',event.event_type,'payload',event.payload,
    'occurredAt',event.occurred_at
  )),'sha256'),'hex')::char(64)
  FROM ops.outbox AS event WHERE event.id=p_event_id
$$;
ALTER FUNCTION ops.r6d_outbox_envelope_digest_v1(uuid) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_outbox_envelope_digest_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.r6d_outbox_envelope_digest_v1(uuid)
  TO gurine_workflow_worker,gurine_control_api,gurine_auditor;

CREATE OR REPLACE FUNCTION editorial.guard_response_submission_owned_intake_v2()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp
AS $$
BEGIN
  IF current_user<>'gurine_migrator'
     OR current_setting('gurine.response_materialization_v2',true)<>'1'
     OR OLD.editorial_response_id IS NOT NULL
     OR num_nonnulls(
       NEW.editorial_response_id,NEW.owned_intake_event_id,
       NEW.owned_intake_event_envelope_digest,NEW.owned_intake_receipt_digest
     )<>4
     OR ROW(
       NEW.id,NEW.response_request_id,NEW.draft_version,NEW.submission_sha256,
       NEW.answers_encrypted,NEW.publication_consent,NEW.status,NEW.submitted_at,
       NEW.receipt_token_hash,NEW.receipt_version,NEW.receipt_digest,
       NEW.receipt_updated_at,NEW.submission_outbox_event_id,
       NEW.submission_event_envelope_digest,
       NEW.submission_idempotency_key_sha256,NEW.submission_request_digest,
       NEW.receipt_session_id
     ) IS DISTINCT FROM ROW(
       OLD.id,OLD.response_request_id,OLD.draft_version,OLD.submission_sha256,
       OLD.answers_encrypted,OLD.publication_consent,OLD.status,OLD.submitted_at,
       OLD.receipt_token_hash,OLD.receipt_version,OLD.receipt_digest,
       OLD.receipt_updated_at,OLD.submission_outbox_event_id,
       OLD.submission_event_envelope_digest,
       OLD.submission_idempotency_key_sha256,OLD.submission_request_digest,
       OLD.receipt_session_id
     ) THEN
    RAISE EXCEPTION 'response_submission_owned_intake_transition_invalid'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION editorial.guard_response_submission_owned_intake_v2() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.guard_response_submission_owned_intake_v2() FROM PUBLIC;
CREATE TRIGGER response_submissions_owned_intake_v2_guard
  BEFORE UPDATE OF editorial_response_id,owned_intake_event_id,
    owned_intake_event_envelope_digest,owned_intake_receipt_digest
  ON intake.response_submissions FOR EACH ROW
  EXECUTE FUNCTION editorial.guard_response_submission_owned_intake_v2();

CREATE OR REPLACE FUNCTION editorial.guard_response_identity_update_v1()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp
AS $$
BEGIN
  IF current_user<>'gurine_migrator'
     OR current_setting('gurine.response_identity_transition',true)<>'1'
     OR OLD.organization_identity_status IS DISTINCT FROM 'UNVERIFIED'
     OR NEW.organization_identity_status<>'SECOND_FACTOR_VERIFIED'
     OR NEW.publication_form NOT IN ('FULL','REDACTED')
     OR NEW.organization_identity_assertion_id IS NULL
     OR NEW.verified_at IS NULL OR NEW.verified_by IS NULL
     OR ROW(
       NEW.id,NEW.case_id,NEW.response_request_id,NEW.submission_id,
       NEW.party_name,NEW.submitted_at,NEW.full_text_encrypted,
       NEW.publication_consent,NEW.editorial_status,NEW.created_at,
       NEW.submission_receipt_version,NEW.submission_receipt_digest,
       NEW.owned_intake_event_id,NEW.owned_intake_event_envelope_digest,
       NEW.owned_intake_receipt_digest,NEW.party_type,NEW.party_entity_id,
       NEW.response_content_sha256,NEW.publication_consent_sha256
     ) IS DISTINCT FROM ROW(
       OLD.id,OLD.case_id,OLD.response_request_id,OLD.submission_id,
       OLD.party_name,OLD.submitted_at,OLD.full_text_encrypted,
       OLD.publication_consent,OLD.editorial_status,OLD.created_at,
       OLD.submission_receipt_version,OLD.submission_receipt_digest,
       OLD.owned_intake_event_id,OLD.owned_intake_event_envelope_digest,
       OLD.owned_intake_receipt_digest,OLD.party_type,OLD.party_entity_id,
       OLD.response_content_sha256,OLD.publication_consent_sha256
     ) THEN
    RAISE EXCEPTION 'response_identity_transition_invalid' USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION editorial.guard_response_identity_update_v1() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.guard_response_identity_update_v1() FROM PUBLIC;
CREATE TRIGGER editorial_responses_identity_update_guard
  BEFORE UPDATE OF organization_identity_status,publication_form,
    organization_identity_assertion_id
  ON editorial.responses FOR EACH ROW
  EXECUTE FUNCTION editorial.guard_response_identity_update_v1();

CREATE OR REPLACE FUNCTION editorial.materialize_response_submission_v2(
  p_intake_receipt editorial.response_submission_intake_materialize_v1,
  p_actor_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS editorial.response_submission_intake_materialize_receipt_v2
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,extensions,pg_temp
AS $$
DECLARE
  v_submission intake.response_submissions%ROWTYPE;
  v_request editorial.response_requests%ROWTYPE;
  v_existing editorial.response_submission_origin_receipts_v2%ROWTYPE;
  v_response_id uuid:=gen_random_uuid();
  v_receipt_id uuid:=gen_random_uuid();
  v_event ops.outbox%ROWTYPE;
  v_envelope_digest char(64);
  v_content_digest char(64);
  v_consent_digest char(64);
  v_payload jsonb;
  v_canonical bytea;
  v_owned_digest char(64);
  v_result_digest char(64);
  v_audit uuid;
  v_emitted uuid;
  v_now timestamptz:=clock_timestamp();
  v_result editorial.response_submission_intake_materialize_receipt_v2;
BEGIN
  IF p_intake_receipt IS NULL
     OR (p_intake_receipt).source_event_id IS NULL
     OR (p_intake_receipt).response_submission_id IS NULL
     OR (p_intake_receipt).response_request_id IS NULL
     OR (p_intake_receipt).response_request_version<1
     OR (p_intake_receipt).receipt_version<1
     OR NOT ops.r6d_lower_sha256((p_intake_receipt).source_event_envelope_digest)
     OR NOT ops.r6d_lower_sha256((p_intake_receipt).response_request_binding_digest)
     OR NOT ops.r6d_lower_sha256((p_intake_receipt).submission_sha256)
     OR NOT ops.r6d_lower_sha256((p_intake_receipt).receipt_digest)
     OR NOT ops.r6d_lower_sha256(p_idempotency_key)
     OR NOT ops.r6d_lower_sha256(p_request_digest) THEN
    RAISE EXCEPTION 'response_materialization_v2_input_invalid' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing
  FROM editorial.response_submission_origin_receipts_v2
  WHERE idempotency_key_sha256=p_idempotency_key FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest<>p_request_digest THEN
      RAISE EXCEPTION 'response_materialization_v2_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    v_result:=ROW(
      'NO_OP_ALREADY_MATERIALIZED',v_existing.source_event_id,
      v_existing.response_submission_id,v_existing.response_request_id,
      v_existing.editorial_response_id,v_existing.party_type,
      v_existing.party_entity_id,v_existing.response_version,
      v_existing.response_content_sha256,v_existing.publication_consent_sha256,
      v_existing.identity_status,v_existing.publication_form,
      v_existing.submission_receipt_version,
      v_existing.submission_receipt_digest,
      v_existing.owned_intake_receipt_digest,v_existing.audit_event_id,
      v_existing.emitted_event_id,v_existing.materialized_at,
      v_existing.result_digest
    );
    RETURN v_result;
  END IF;
  SELECT * INTO v_event FROM ops.outbox
  WHERE id=(p_intake_receipt).source_event_id
    AND event_type='workflow.response_submitted.v2'
    AND aggregate_type='response_submission'
    AND aggregate_id=(p_intake_receipt).response_submission_id::text
    AND aggregate_version=(p_intake_receipt).receipt_version
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_materialization_source_event_invalid'
      USING ERRCODE='23514';
  END IF;
  v_envelope_digest:=ops.r6d_outbox_envelope_digest_v1(v_event.id);
  IF v_envelope_digest<>(p_intake_receipt).source_event_envelope_digest
     OR v_event.payload<>jsonb_build_object(
       'responseSubmissionId',(p_intake_receipt).response_submission_id,
       'responseRequestId',(p_intake_receipt).response_request_id,
       'responseRequestVersion',(p_intake_receipt).response_request_version,
       'responseRequestBindingDigest',btrim((p_intake_receipt).response_request_binding_digest),
       'submissionSha256',btrim((p_intake_receipt).submission_sha256),
       'receiptVersion',(p_intake_receipt).receipt_version,
       'receiptDigest',btrim((p_intake_receipt).receipt_digest),
       'submittedAt',(p_intake_receipt).submitted_at
     ) THEN
    RAISE EXCEPTION 'response_materialization_event_binding_mismatch'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO v_submission FROM intake.response_submissions
  WHERE id=(p_intake_receipt).response_submission_id
    AND response_request_id=(p_intake_receipt).response_request_id
  FOR UPDATE;
  IF NOT FOUND
     OR v_submission.submission_sha256<>(p_intake_receipt).submission_sha256
     OR v_submission.receipt_version<>(p_intake_receipt).receipt_version
     OR v_submission.receipt_digest<>(p_intake_receipt).receipt_digest
     OR v_submission.submitted_at<>(p_intake_receipt).submitted_at THEN
    RAISE EXCEPTION 'response_materialization_submission_mismatch'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO v_request FROM editorial.response_requests
  WHERE id=v_submission.response_request_id
    AND version=(p_intake_receipt).response_request_version FOR SHARE;
  IF NOT FOUND OR NOT EXISTS(
    SELECT 1 FROM editorial.response_request_sent_receipts AS sent
    WHERE sent.response_request_id=v_request.id
      AND sent.response_request_binding_digest=
        (p_intake_receipt).response_request_binding_digest
  ) THEN
    RAISE EXCEPTION 'response_materialization_request_binding_mismatch'
      USING ERRCODE='23514';
  END IF;
  IF v_submission.editorial_response_id IS NOT NULL THEN
    SELECT * INTO v_existing
    FROM editorial.response_submission_origin_receipts_v2
    WHERE response_submission_id=v_submission.id FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'response_materialization_partial_graph' USING ERRCODE='55000';
    END IF;
    v_result:=ROW(
      'NO_OP_ALREADY_MATERIALIZED',v_existing.source_event_id,
      v_existing.response_submission_id,v_existing.response_request_id,
      v_existing.editorial_response_id,v_existing.party_type,
      v_existing.party_entity_id,v_existing.response_version,
      v_existing.response_content_sha256,v_existing.publication_consent_sha256,
      v_existing.identity_status,v_existing.publication_form,
      v_existing.submission_receipt_version,
      v_existing.submission_receipt_digest,
      v_existing.owned_intake_receipt_digest,v_existing.audit_event_id,
      v_existing.emitted_event_id,v_existing.materialized_at,
      v_existing.result_digest
    );
    RETURN v_result;
  END IF;
  v_content_digest:=encode(extensions.digest(v_submission.answers_encrypted,'sha256'),'hex');
  v_consent_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_submission.publication_consent),'sha256'
  ),'hex');
  v_payload:=jsonb_build_object(
    'schemaVersion','response-submission-origin.v2',
    'receiptId',v_receipt_id,'sourceEventId',v_event.id,
    'sourceEventEnvelopeDigest',v_envelope_digest,
    'responseSubmissionId',v_submission.id,
    'responseRequestId',v_request.id,'editorialResponseId',v_response_id,
    'partyType',v_request.party_type,'partyEntityId',v_request.party_entity_id,
    'responseVersion',1,'responseContentSha256',v_content_digest,
    'publicationConsentSha256',v_consent_digest,'identityStatus','UNVERIFIED',
    'publicationForm','INTERNAL_ONLY',
    'submissionReceiptVersion',v_submission.receipt_version,
    'submissionReceiptDigest',btrim(v_submission.receipt_digest),
    'materializedAt',v_now
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_owned_digest:=encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_result_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    v_payload||jsonb_build_object('ownedIntakeReceiptDigest',v_owned_digest)
  ),'sha256'),'hex');
  v_audit:=ops.append_audit_event(
    'response-materialization:'||v_submission.id::text,
    CASE WHEN p_actor_id IS NULL THEN 'SERVICE' ELSE 'USER' END,
    COALESCE(p_actor_id::text,'workflow-worker'),NULL::uuid,
    'response.materialize','EditorialResponse',v_response_id::text,
    'responses.materialize','SUCCESS',NULL,gen_random_uuid(),
    jsonb_build_object('responseSubmissionId',v_submission.id,
      'ownedIntakeReceiptDigest',v_owned_digest)
  );
  v_emitted:=ops.enqueue_outbox(
    'response_submission',v_submission.id::text,1,
    'editorial.response_materialized.v2',
    jsonb_build_object(
      'responseSubmissionId',v_submission.id,
      'responseRequestId',v_request.id,'editorialResponseId',v_response_id,
      'partyType',v_request.party_type,'partyEntityId',v_request.party_entity_id,
      'responseVersion',1,'responseContentSha256',v_content_digest,
      'publicationConsentSha256',v_consent_digest,
      'identityStatus','UNVERIFIED',
      'submissionReceiptVersion',v_submission.receipt_version,
      'submissionReceiptDigest',v_submission.receipt_digest,
      'ownedIntakeReceiptDigest',v_owned_digest,'materializedAt',v_now,
      'resultDigest',v_result_digest
    ),v_now
  );
  INSERT INTO editorial.responses(
    id,case_id,response_request_id,submission_id,party_name,submitted_at,
    full_text_encrypted,publication_consent,editorial_status,version,
    submission_receipt_version,submission_receipt_digest,
    owned_intake_event_id,owned_intake_event_envelope_digest,
    owned_intake_receipt_digest,party_type,party_entity_id,
    response_content_sha256,publication_consent_sha256,
    organization_identity_status,publication_form,created_at,updated_at
  ) VALUES(
    v_response_id,v_request.case_id,v_request.id,v_submission.id,
    v_request.party_name,v_submission.submitted_at,v_submission.answers_encrypted,
    v_submission.publication_consent,'PENDING',1,v_submission.receipt_version,
    v_submission.receipt_digest,v_event.id,v_envelope_digest,v_owned_digest,
    v_request.party_type,v_request.party_entity_id,v_content_digest,
    v_consent_digest,'UNVERIFIED','INTERNAL_ONLY',v_now,v_now
  );
  PERFORM set_config('gurine.response_materialization_v2','1',true);
  UPDATE intake.response_submissions
  SET editorial_response_id=v_response_id,owned_intake_event_id=v_event.id,
      owned_intake_event_envelope_digest=v_envelope_digest,
      owned_intake_receipt_digest=v_owned_digest
  WHERE id=v_submission.id AND editorial_response_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_materialization_concurrent_conflict'
      USING ERRCODE='40001';
  END IF;
  INSERT INTO editorial.response_submission_origin_receipts_v2(
    receipt_id,source_event_id,source_event_envelope_digest,
    response_submission_id,response_request_id,editorial_response_id,
    party_type,party_entity_id,response_version,response_content_sha256,
    publication_consent_sha256,identity_status,publication_form,
    submission_receipt_version,submission_receipt_digest,audit_event_id,
    emitted_event_id,idempotency_key_sha256,request_digest,receipt_payload,
    receipt_canonical,owned_intake_receipt_digest,result_digest,materialized_at
  ) VALUES(
    v_receipt_id,v_event.id,v_envelope_digest,v_submission.id,v_request.id,
    v_response_id,v_request.party_type,v_request.party_entity_id,1,
    v_content_digest,v_consent_digest,'UNVERIFIED','INTERNAL_ONLY',
    v_submission.receipt_version,v_submission.receipt_digest,v_audit,v_emitted,
    p_idempotency_key,p_request_digest,v_payload,v_canonical,v_owned_digest,
    v_result_digest,v_now
  );
  v_result:=ROW(
    'APPLIED',v_event.id,v_submission.id,v_request.id,v_response_id,
    v_request.party_type,v_request.party_entity_id,1,v_content_digest,
    v_consent_digest,'UNVERIFIED','INTERNAL_ONLY',v_submission.receipt_version,
    v_submission.receipt_digest,v_owned_digest,v_audit,v_emitted,v_now,
    v_result_digest
  );
  RETURN v_result;
END
$$;
ALTER FUNCTION editorial.materialize_response_submission_v2(
  editorial.response_submission_intake_materialize_v1,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.materialize_response_submission_v2(
  editorial.response_submission_intake_materialize_v1,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.materialize_response_submission_v2(
  editorial.response_submission_intake_materialize_v1,uuid,char(64),char(64)
) TO gurine_workflow_worker;

CREATE OR REPLACE FUNCTION editorial.materialize_response_submission_intake_v1(
  p_input editorial.response_submission_intake_materialize_v1
) RETURNS editorial.response_submission_intake_materialize_receipt_v1
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp
AS $$
DECLARE
  v_idempotency char(64);
  v_request char(64);
  v_v2 editorial.response_submission_intake_materialize_receipt_v2;
  v_v1 editorial.response_submission_intake_materialize_receipt_v1;
BEGIN
  v_idempotency:=encode(extensions.digest(convert_to(
    'response-materialize-v1:'||(p_input).source_event_id::text,'UTF8'
  ),'sha256'),'hex');
  v_request:=encode(extensions.digest(ops.canonical_jsonb_v1(to_jsonb(p_input)),'sha256'),'hex');
  v_v2:=editorial.materialize_response_submission_v2(
    p_input,NULL::uuid,v_idempotency,v_request
  );
  v_v1:=ROW(
    (v_v2).disposition,(v_v2).source_event_id,
    (v_v2).response_submission_id,(v_v2).response_request_id,
    (v_v2).editorial_response_id,(v_v2).submission_receipt_version,
    (v_v2).submission_receipt_digest,(v_v2).owned_intake_receipt_digest,
    (v_v2).audit_event_id,(v_v2).emitted_event_id,(v_v2).result_digest
  );
  RETURN v_v1;
END
$$;
ALTER FUNCTION editorial.materialize_response_submission_intake_v1(
  editorial.response_submission_intake_materialize_v1
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.materialize_response_submission_intake_v1(
  editorial.response_submission_intake_materialize_v1
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.materialize_response_submission_intake_v1(
  editorial.response_submission_intake_materialize_v1
) TO gurine_workflow_worker;

CREATE OR REPLACE FUNCTION intake.r6d_publication_consent_valid_v1(p_value jsonb)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
DECLARE v_total bigint; v_distinct bigint;
BEGIN
  IF p_value IS NULL OR jsonb_typeof(p_value)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_value))<>6
     OR NOT p_value ?& ARRAY[
       'bodyConsent','attachmentConsents','identityDisplay',
       'redactionAcknowledged','excerptReviewRequested','consentedAt'
     ]
     OR jsonb_typeof(p_value->'bodyConsent')<>'boolean'
     OR jsonb_typeof(p_value->'redactionAcknowledged')<>'boolean'
     OR jsonb_typeof(p_value->'excerptReviewRequested')<>'boolean'
     OR jsonb_typeof(p_value->'attachmentConsents')<>'array'
     OR p_value->>'identityDisplay' NOT IN (
       'ORGANIZATION_NAME','ROLE_ONLY','ANONYMOUS'
     )
     OR (p_value->>'consentedAt')::timestamptz IS NULL THEN
    RETURN false;
  END IF;
  SELECT count(*),count(DISTINCT item->>'attachmentId')
  INTO v_total,v_distinct
  FROM jsonb_array_elements(p_value->'attachmentConsents') AS entry(item)
  WHERE jsonb_typeof(item)='object'
    AND (SELECT count(*) FROM jsonb_object_keys(item))=3
    AND item ?& ARRAY['attachmentId','mayPublish','redactionAllowed']
    AND (item->>'attachmentId')::uuid IS NOT NULL
    AND jsonb_typeof(item->'mayPublish')='boolean'
    AND jsonb_typeof(item->'redactionAllowed')='boolean';
  RETURN v_total=jsonb_array_length(p_value->'attachmentConsents')
    AND v_total=v_distinct;
EXCEPTION WHEN others THEN
  RETURN false;
END
$$;
ALTER FUNCTION intake.r6d_publication_consent_valid_v1(jsonb) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION intake.r6d_publication_consent_valid_v1(jsonb) FROM PUBLIC;

CREATE TABLE intake.response_submission_receipts_v3 (
  receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  response_submission_id uuid NOT NULL UNIQUE REFERENCES intake.response_submissions(id) ON DELETE RESTRICT,
  response_request_id uuid NOT NULL REFERENCES editorial.response_requests(id) ON DELETE RESTRICT,
  response_request_version bigint NOT NULL,
  response_request_binding_digest char(64) NOT NULL,
  draft_version bigint NOT NULL,
  submission_sha256 char(64) NOT NULL,
  publication_consent_sha256 char(64) NOT NULL,
  receipt_version bigint NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  receipt_session_id uuid NOT NULL UNIQUE REFERENCES intake.submission_sessions(id) ON DELETE RESTRICT,
  receipt_session_expires_at timestamptz NOT NULL,
  domain_event_id uuid NOT NULL UNIQUE REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  notification_event_id uuid NOT NULL UNIQUE REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  workflow_event_id uuid NOT NULL UNIQUE REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  workflow_event_envelope_digest char(64) NOT NULL,
  actor_type text NOT NULL DEFAULT 'SERVICE',
  actor_id text NOT NULL DEFAULT 'submission-api',
  audit_event_id uuid NOT NULL UNIQUE REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  submitted_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT response_submission_receipts_v3_shape_ck CHECK (
    response_request_version>0 AND draft_version>0 AND receipt_version>0
    AND actor_type='SERVICE' AND actor_id='submission-api'
    AND ops.r6d_lower_sha256(response_request_binding_digest)
    AND ops.r6d_lower_sha256(submission_sha256)
    AND ops.r6d_lower_sha256(publication_consent_sha256)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND ops.r6d_lower_sha256(workflow_event_envelope_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND receipt_session_expires_at>submitted_at
  )
);
ALTER TABLE intake.response_submission_receipts_v3 OWNER TO gurine_migrator;
REVOKE ALL ON intake.response_submission_receipts_v3 FROM PUBLIC;
GRANT SELECT ON intake.response_submission_receipts_v3
  TO gurine_submission_api,gurine_workflow_worker,gurine_auditor;
CREATE TRIGGER response_submission_receipts_v3_immutable_guard
  BEFORE UPDATE OR DELETE ON intake.response_submission_receipts_v3
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

-- The submission owner locks the mutable session/draft/request rows, reads the
-- attachment set, and atomically installs the owned submission tuple. Runtime
-- service roles keep zero direct DML on these relations.
GRANT SELECT,INSERT,UPDATE ON intake.submission_sessions
  TO gurine_migrator;
GRANT SELECT,UPDATE ON intake.response_drafts TO gurine_migrator;
GRANT SELECT ON intake.response_attachments TO gurine_migrator;
GRANT SELECT,INSERT,UPDATE ON intake.response_submissions
  TO gurine_migrator;

CREATE OR REPLACE FUNCTION intake.submit_response_session_v3(
  p_session_token_hash char(64),
  p_bff_issuer text,
  p_expected_version bigint,
  p_attestation boolean,
  p_submission_sha256 char(64),
  p_answers_encrypted bytea,
  p_publication_consent jsonb,
  p_submission_id uuid,
  p_receipt_token_hash char(64),
  p_receipt_session_token_hash char(64),
  p_receipt_session_expires_at timestamptz,
  p_idempotency_key_sha256 char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,intake,editorial,ops,extensions,pg_temp
AS $$
DECLARE
  v_existing intake.response_submission_receipts_v3%ROWTYPE;
  v_session intake.submission_sessions%ROWTYPE;
  v_draft intake.response_drafts%ROWTYPE;
  v_request editorial.response_requests%ROWTYPE;
  v_sent editorial.response_request_sent_receipts%ROWTYPE;
  v_receipt_session_id uuid;
  v_receipt_version bigint:=1;
  v_receipt_digest char(64);
  v_consent_digest char(64);
  v_payload jsonb;
  v_expected_attachments uuid[];
  v_consented_attachments uuid[];
  v_domain uuid;
  v_notification uuid;
  v_workflow uuid;
  v_envelope char(64);
  v_audit uuid;
  v_now timestamptz:=clock_timestamp();
BEGIN
  IF NOT ops.r6d_lower_sha256(p_session_token_hash)
     OR p_bff_issuer<>'response-portal' OR p_expected_version<1
     OR p_attestation IS DISTINCT FROM true OR p_submission_id IS NULL
     OR NOT ops.r6d_lower_sha256(p_submission_sha256)
     OR p_answers_encrypted IS NULL OR octet_length(p_answers_encrypted)<1
     OR NOT intake.r6d_publication_consent_valid_v1(p_publication_consent)
     OR NOT ops.r6d_lower_sha256(p_receipt_token_hash)
     OR NOT ops.r6d_lower_sha256(p_receipt_session_token_hash)
     OR p_receipt_session_expires_at<=v_now
     OR p_receipt_session_expires_at>v_now+interval '24 hours'
     OR NOT ops.r6d_lower_sha256(p_idempotency_key_sha256)
     OR NOT ops.r6d_lower_sha256(p_request_digest) THEN
    RAISE EXCEPTION 'response_submission_v3_input_invalid' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing FROM intake.response_submission_receipts_v3
  WHERE idempotency_key_sha256=p_idempotency_key_sha256 FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest<>p_request_digest THEN
      RAISE EXCEPTION 'response_submission_v3_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN jsonb_build_object(
      'submissionId',v_existing.response_submission_id,
      'receiptSessionId',v_existing.receipt_session_id,
      'receiptSessionExpiresAt',v_existing.receipt_session_expires_at,
      'receiptVersion',v_existing.receipt_version,
      'receiptDigest',v_existing.receipt_digest,
      'submissionOutboxEventId',v_existing.workflow_event_id,
      'eventEnvelopeDigest',v_existing.workflow_event_envelope_digest,
      'outboxEventIds',jsonb_build_array(
        v_existing.domain_event_id,v_existing.notification_event_id,
        v_existing.workflow_event_id
      ),'submittedAt',v_existing.submitted_at,'replayed',true
    );
  END IF;
  SELECT * INTO v_session FROM intake.submission_sessions
  WHERE token_hash=p_session_token_hash AND bff_issuer=p_bff_issuer
    AND session_kind='RESPONSE_ACTIVE' AND scope_type='RESPONSE_REQUEST'
    AND status='ACTIVE' AND expires_at>v_now FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_session_invalid' USING ERRCODE='28000';
  END IF;
  SELECT * INTO v_request FROM editorial.response_requests
  WHERE id=v_session.scope_id FOR UPDATE;
  IF NOT FOUND OR v_request.status NOT IN ('SENT','VIEWED')
     OR COALESCE(v_request.effective_due_at,v_request.due_at)<=v_now THEN
    RAISE EXCEPTION 'response_request_closed' USING ERRCODE='55000';
  END IF;
  SELECT * INTO v_draft FROM intake.response_drafts
  WHERE response_request_id=v_request.id AND version=p_expected_version
    AND expires_at>v_now FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_draft_version_conflict' USING ERRCODE='40001';
  END IF;
  SELECT COALESCE(array_agg(attachment.id ORDER BY attachment.id),'{}'::uuid[])
  INTO v_expected_attachments
  FROM intake.response_attachments AS attachment
  WHERE attachment.response_request_id=v_request.id
    AND attachment.upload_status<>'DELETED';
  SELECT COALESCE(array_agg((item->>'attachmentId')::uuid
    ORDER BY (item->>'attachmentId')::uuid),'{}'::uuid[])
  INTO v_consented_attachments
  FROM jsonb_array_elements(
    p_publication_consent->'attachmentConsents'
  ) AS consent(item);
  IF v_expected_attachments<>v_consented_attachments OR EXISTS(
    SELECT 1 FROM intake.response_attachments AS attachment
    WHERE attachment.response_request_id=v_request.id
      AND attachment.upload_status<>'DELETED'
      AND (attachment.upload_status<>'FINALIZED'
        OR attachment.scan_status<>'CLEAN')
  ) THEN
    RAISE EXCEPTION 'response_attachment_set_not_clean_or_unconsented'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_sent FROM editorial.response_request_sent_receipts
  WHERE response_request_id=v_request.id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_request_sent_receipt_missing' USING ERRCODE='55000';
  END IF;
  v_consent_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(p_publication_consent),'sha256'
  ),'hex');
  v_payload:=jsonb_build_object(
    'schemaVersion','response-submission-receipt.v3',
    'responseSubmissionId',p_submission_id,
    'responseRequestId',v_request.id,
    'responseRequestVersion',v_request.version+1,
    'responseRequestBindingDigest',btrim(v_sent.response_request_binding_digest),
    'draftVersion',v_draft.version,
    'submissionSha256',btrim(p_submission_sha256),
    'publicationConsentSha256',v_consent_digest,
    'receiptVersion',v_receipt_version,'submittedAt',v_now
  );
  v_receipt_digest:=encode(
    extensions.digest(ops.canonical_jsonb_v1(v_payload),'sha256'),'hex'
  );
  INSERT INTO intake.response_submissions(
    id,response_request_id,draft_version,submission_sha256,answers_encrypted,
    publication_consent,status,submitted_at,receipt_token_hash,
    receipt_version,receipt_digest,receipt_updated_at
  ) VALUES(
    p_submission_id,v_request.id,v_draft.version,p_submission_sha256,
    p_answers_encrypted,p_publication_consent,'SUBMITTED',v_now,
    p_receipt_token_hash,v_receipt_version,v_receipt_digest,v_now
  );
  UPDATE editorial.response_requests
  SET status='SUBMITTED',version=version+1,updated_at=v_now
  WHERE id=v_request.id AND version=v_request.version
    AND status IN ('SENT','VIEWED');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_request_version_conflict' USING ERRCODE='40001';
  END IF;
  UPDATE intake.submission_sessions
  SET status='CONSUMED',consumed_at=v_now,version=version+1
  WHERE id=v_session.id AND status='ACTIVE';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_session_concurrent_conflict' USING ERRCODE='40001';
  END IF;
  INSERT INTO intake.submission_sessions(
    token_hash,session_kind,scope_type,scope_id,bff_issuer,expires_at
  ) VALUES(
    p_receipt_session_token_hash,'RESPONSE_RECEIPT','RESPONSE_SUBMISSION',
    p_submission_id,p_bff_issuer,p_receipt_session_expires_at
  ) RETURNING id INTO v_receipt_session_id;
  v_payload:=jsonb_build_object(
    'responseSubmissionId',p_submission_id,'responseRequestId',v_request.id,
    'responseRequestVersion',v_request.version+1,
    'responseRequestBindingDigest',v_sent.response_request_binding_digest,
    'submissionSha256',p_submission_sha256,'receiptVersion',v_receipt_version,
    'receiptDigest',v_receipt_digest,'submittedAt',v_now
  );
  v_domain:=ops.enqueue_outbox(
    'response_submission',p_submission_id::text,v_receipt_version,
    'response.submitted.v2',v_payload,v_now
  );
  v_notification:=ops.enqueue_outbox(
    'response_submission',p_submission_id::text,v_receipt_version,
    'notification.response_submitted.v2',v_payload,v_now
  );
  v_workflow:=ops.enqueue_outbox(
    'response_submission',p_submission_id::text,v_receipt_version,
    'workflow.response_submitted.v2',v_payload,v_now
  );
  v_envelope:=ops.r6d_outbox_envelope_digest_v1(v_workflow);
  v_audit:=ops.append_audit_event(
    'response-submission:'||p_submission_id::text,'SERVICE','submission-api',
    v_session.id,'response.submit','ResponseSubmission',p_submission_id::text,
    'responses.submit','SUCCESS',NULL,gen_random_uuid(),jsonb_build_object(
      'receiptDigest',v_receipt_digest,'workflowEventId',v_workflow,
      'workflowEventEnvelopeDigest',v_envelope
    )
  );
  UPDATE intake.response_submissions
  SET submission_outbox_event_id=v_workflow,
      submission_event_envelope_digest=v_envelope,
      submission_idempotency_key_sha256=p_idempotency_key_sha256,
      submission_request_digest=p_request_digest,
      receipt_session_id=v_receipt_session_id
  WHERE id=p_submission_id;
  INSERT INTO intake.response_submission_receipts_v3(
    response_submission_id,response_request_id,response_request_version,
    response_request_binding_digest,draft_version,submission_sha256,
    publication_consent_sha256,receipt_version,receipt_digest,
    receipt_session_id,receipt_session_expires_at,domain_event_id,
    notification_event_id,workflow_event_id,workflow_event_envelope_digest,
    audit_event_id,idempotency_key_sha256,
    request_digest,submitted_at
  ) VALUES(
    p_submission_id,v_request.id,v_request.version+1,
    v_sent.response_request_binding_digest,v_draft.version,p_submission_sha256,
    v_consent_digest,v_receipt_version,v_receipt_digest,v_receipt_session_id,
    p_receipt_session_expires_at,v_domain,v_notification,v_workflow,v_envelope,v_audit,
    p_idempotency_key_sha256,p_request_digest,v_now
  );
  RETURN jsonb_build_object(
    'submissionId',p_submission_id,'receiptSessionId',v_receipt_session_id,
    'receiptSessionExpiresAt',p_receipt_session_expires_at,
    'receiptVersion',v_receipt_version,'receiptDigest',v_receipt_digest,
    'submissionOutboxEventId',v_workflow,'eventEnvelopeDigest',v_envelope,
    'outboxEventIds',jsonb_build_array(v_domain,v_notification,v_workflow),
    'submittedAt',v_now,'replayed',false
  );
END
$$;
ALTER FUNCTION intake.submit_response_session_v3(
  char(64),text,bigint,boolean,char(64),bytea,jsonb,uuid,char(64),char(64),
  timestamptz,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION intake.submit_response_session_v3(
  char(64),text,bigint,boolean,char(64),bytea,jsonb,uuid,char(64),char(64),
  timestamptz,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION intake.submit_response_session_v3(
  char(64),text,bigint,boolean,char(64),bytea,jsonb,uuid,char(64),char(64),
  timestamptz,char(64),char(64)
) TO gurine_submission_api;
REVOKE EXECUTE ON FUNCTION intake.submit_response_session_v2(
  char(64),text,bigint,char(64),bytea,jsonb,uuid,char(64),char(64),timestamptz
) FROM gurine_submission_api;

CREATE TABLE editorial.response_excerpt_approval_receipts_v2 (
  approval_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  response_id uuid NOT NULL UNIQUE REFERENCES editorial.responses(id) ON DELETE RESTRICT,
  prior_response_version bigint NOT NULL,
  response_version bigint NOT NULL,
  response_content_sha256 char(64) NOT NULL,
  publication_consent_sha256 char(64) NOT NULL,
  excerpt_sha256 char(64) NOT NULL,
  publication_form text NOT NULL,
  identity_receipt_id uuid REFERENCES editorial.response_publication_identity_receipts_v1(receipt_id) ON DELETE RESTRICT,
  identity_receipt_digest char(64),
  reason_digest char(64) NOT NULL,
  actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  actor_assertion_jti uuid NOT NULL UNIQUE,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL UNIQUE REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  outbox_event_id uuid NOT NULL UNIQUE REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  approved_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT response_excerpt_approval_receipts_v2_shape_ck CHECK (
    prior_response_version>0 AND response_version=prior_response_version+1
    AND publication_form IN ('ANONYMOUS','FULL','REDACTED')
    AND ((publication_form='ANONYMOUS'
      AND identity_receipt_id IS NULL AND identity_receipt_digest IS NULL)
      OR (publication_form IN ('FULL','REDACTED')
      AND identity_receipt_id IS NOT NULL
      AND ops.r6d_lower_sha256(identity_receipt_digest)))
    AND ops.r6d_lower_sha256(response_content_sha256)
    AND ops.r6d_lower_sha256(publication_consent_sha256)
    AND ops.r6d_lower_sha256(excerpt_sha256)
    AND ops.r6d_lower_sha256(reason_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(extensions.digest(receipt_canonical,'sha256'),'hex')
  )
);
ALTER TABLE editorial.response_excerpt_approval_receipts_v2 OWNER TO gurine_migrator;
REVOKE ALL ON editorial.response_excerpt_approval_receipts_v2 FROM PUBLIC;
GRANT SELECT ON editorial.response_excerpt_approval_receipts_v2
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER response_excerpt_approval_receipts_v2_immutable_guard
  BEFORE UPDATE OR DELETE ON editorial.response_excerpt_approval_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

CREATE OR REPLACE FUNCTION editorial.guard_response_excerpt_approval_v2()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp
AS $$
BEGIN
  IF current_user<>'gurine_migrator'
     OR current_setting('gurine.response_excerpt_approval_v2',true)<>'1'
     OR OLD.public_excerpt IS NULL OR NEW.public_excerpt IS DISTINCT FROM OLD.public_excerpt
     OR NEW.public_excerpt_sha256 IS NULL OR NEW.excerpt_approved_by IS NULL
     OR NEW.excerpt_approved_at IS NULL
     OR NEW.version<>OLD.version+1
     OR NEW.editorial_status<>(CASE WHEN OLD.editorial_status='PENDING'
       THEN 'ACCEPTED' ELSE OLD.editorial_status END)
     OR ROW(
       NEW.id,NEW.case_id,NEW.response_request_id,NEW.submission_id,
       NEW.party_name,NEW.submitted_at,NEW.verified_at,NEW.verified_by,
       NEW.full_text_encrypted,NEW.publication_consent,NEW.created_at,
       NEW.submission_receipt_version,NEW.submission_receipt_digest,
       NEW.owned_intake_event_id,NEW.owned_intake_event_envelope_digest,
       NEW.owned_intake_receipt_digest,NEW.party_type,NEW.party_entity_id,
       NEW.response_content_sha256,NEW.publication_consent_sha256,
       NEW.organization_identity_status,NEW.publication_form,
       NEW.organization_identity_assertion_id
     ) IS DISTINCT FROM ROW(
       OLD.id,OLD.case_id,OLD.response_request_id,OLD.submission_id,
       OLD.party_name,OLD.submitted_at,OLD.verified_at,OLD.verified_by,
       OLD.full_text_encrypted,OLD.publication_consent,OLD.created_at,
       OLD.submission_receipt_version,OLD.submission_receipt_digest,
       OLD.owned_intake_event_id,OLD.owned_intake_event_envelope_digest,
       OLD.owned_intake_receipt_digest,OLD.party_type,OLD.party_entity_id,
       OLD.response_content_sha256,OLD.publication_consent_sha256,
       OLD.organization_identity_status,OLD.publication_form,
       OLD.organization_identity_assertion_id
     ) THEN
    RAISE EXCEPTION 'response_excerpt_approval_transition_invalid'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION editorial.guard_response_excerpt_approval_v2() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.guard_response_excerpt_approval_v2() FROM PUBLIC;
CREATE TRIGGER editorial_responses_excerpt_approval_v2_guard
  BEFORE UPDATE OF public_excerpt,public_excerpt_sha256,excerpt_approved_by,
    excerpt_approved_at,editorial_status
  ON editorial.responses FOR EACH ROW
  EXECUTE FUNCTION editorial.guard_response_excerpt_approval_v2();

CREATE OR REPLACE FUNCTION editorial.approve_response_excerpt_guarded_v2(
  p_request jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp
AS $$
DECLARE
  v_response editorial.responses%ROWTYPE;
  v_existing editorial.response_excerpt_approval_receipts_v2%ROWTYPE;
  v_identity editorial.response_publication_identity_receipts_v1%ROWTYPE;
  v_approval_id uuid:=gen_random_uuid();
  v_response_id uuid:=NULLIF(p_request->>'responseId','')::uuid;
  v_expected_version bigint:=NULLIF(p_request->>'expectedVersion','')::bigint;
  v_form text:=p_request->>'publicationForm';
  v_excerpt_sha char(64):=NULLIF(p_request->>'excerptHash','')::char(64);
  v_actor_id uuid:=NULLIF(p_request->>'_actorId','')::uuid;
  v_actor_jti uuid:=NULLIF(p_request->>'_actorAssertionJti','')::uuid;
  v_request_id uuid:=NULLIF(p_request->>'_requestId','')::uuid;
  v_idempotency char(64):=NULLIF(p_request->>'_idempotencyKeySha256','')::char(64);
  v_request_digest char(64):=NULLIF(p_request->>'_requestSha256','')::char(64);
  v_reason_digest char(64);
  v_payload jsonb;
  v_canonical bytea;
  v_receipt_digest char(64);
  v_audit uuid;
  v_outbox uuid;
  v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_request))<>13
     OR NOT p_request ?& ARRAY[
       'responseId','excerptHash','publicationForm','reason','expectedVersion',
       '_actorId','_actorAssertionJti','_actorAssuranceLevel',
       '_actorEffectiveCapability',
       '_actorRequestKeySha256','_requestId','_idempotencyKeySha256',
       '_requestSha256'
     ]
     OR v_form NOT IN ('ANONYMOUS','FULL','REDACTED')
     OR v_expected_version<1 OR v_actor_id IS NULL OR v_actor_jti IS NULL
     OR v_request_id IS NULL
     OR p_request->>'_actorAssuranceLevel' NOT IN ('ACTIVE_SESSION','STEP_UP')
     OR p_request->>'_actorEffectiveCapability'<>'responses.review'
     OR p_request->>'_actorRequestKeySha256'<>v_idempotency
     OR NOT ops.r6d_lower_sha256(v_excerpt_sha)
     OR NOT ops.r6d_lower_sha256(v_idempotency)
     OR NOT ops.r6d_lower_sha256(v_request_digest)
     OR length(btrim(p_request->>'reason')) NOT BETWEEN 1 AND 4000 THEN
    RAISE EXCEPTION 'response_excerpt_approval_request_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing
  FROM editorial.response_excerpt_approval_receipts_v2
  WHERE idempotency_key_sha256=v_idempotency FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest<>v_request_digest THEN
      RAISE EXCEPTION 'response_excerpt_approval_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN jsonb_build_object(
      'approvalId',v_existing.approval_id,'responseId',v_existing.response_id,
      'responseVersion',v_existing.response_version,
      'receiptDigest',v_existing.receipt_digest,
      'auditEventId',v_existing.audit_event_id,
      'approvedAt',v_existing.approved_at,
      'outboxEventIds',jsonb_build_array(v_existing.outbox_event_id),
      'replayed',true
    );
  END IF;
  SELECT * INTO v_response FROM editorial.responses
  WHERE id=v_response_id AND version=v_expected_version FOR UPDATE;
  IF NOT FOUND OR v_response.public_excerpt IS NULL
     OR encode(extensions.digest(convert_to(v_response.public_excerpt,'UTF8'),'sha256'),'hex')
       <>v_excerpt_sha
     OR v_response.response_content_sha256 IS NULL
     OR v_response.publication_consent_sha256 IS NULL
     OR COALESCE((v_response.publication_consent->>'bodyConsent')::boolean,false)
       IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'response_excerpt_approval_scope_invalid'
      USING ERRCODE='40001';
  END IF;
  IF v_form='ANONYMOUS' THEN
    IF v_response.publication_consent->>'identityDisplay'<>'ANONYMOUS' THEN
      RAISE EXCEPTION 'response_excerpt_anonymous_consent_missing'
        USING ERRCODE='23514';
    END IF;
    v_identity.receipt_id:=NULL;
  ELSE
    SELECT * INTO v_identity
    FROM editorial.response_publication_identity_receipts_v1
    WHERE response_id=v_response.id AND response_version=v_response.version
      AND response_content_sha256=v_response.response_content_sha256
      AND publication_consent_sha256=v_response.publication_consent_sha256
      AND organization_id=v_response.party_entity_id
      AND publication_form=v_form
      AND identity_status='SECOND_FACTOR_VERIFIED' AND active
    FOR SHARE;
    IF NOT FOUND OR v_response.organization_identity_status<>'SECOND_FACTOR_VERIFIED'
       OR v_response.publication_form<>v_form
       OR v_response.organization_identity_assertion_id<>v_identity.assertion_id THEN
      RAISE EXCEPTION 'response_excerpt_identity_gate_failed'
        USING ERRCODE='23514';
    END IF;
  END IF;
  v_reason_digest:=encode(extensions.digest(convert_to(
    p_request->>'reason','UTF8'
  ),'sha256'),'hex');
  v_payload:=jsonb_build_object(
    'schemaVersion','response-excerpt-approval.v2',
    'approvalId',v_approval_id,'responseId',v_response.id,
    'priorResponseVersion',v_response.version,
    'responseVersion',v_response.version+1,
    'responseContentSha256',v_response.response_content_sha256,
    'publicationConsentSha256',v_response.publication_consent_sha256,
    'excerptSha256',v_excerpt_sha,'publicationForm',v_form,
    'identityReceiptId',v_identity.receipt_id,
    'identityReceiptDigest',v_identity.receipt_digest,
    'approvedBy',v_actor_id,'approvedAt',v_now
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_receipt_digest:=encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_audit:=ops.append_audit_event(
    'response-excerpt:'||v_response.id::text,'USER',v_actor_id::text,
    NULL::uuid,'response.excerpt.approve','EditorialResponse',
    v_response.id::text,'responses.review','SUCCESS',NULL,v_request_id,
    jsonb_build_object('excerptSha256',v_excerpt_sha,
      'publicationForm',v_form,'identityReceiptDigest',v_identity.receipt_digest)
  );
  v_outbox:=ops.enqueue_outbox(
    'editorial_response',v_response.id::text,v_response.version+1,
    'response.excerpt_approved.v2',jsonb_build_object(
      'responseId',v_response.id,'responseVersion',v_response.version+1,
      'excerptSha256',v_excerpt_sha,'publicationForm',v_form,
      'identityReceiptDigest',v_identity.receipt_digest,
      'approvalReceiptDigest',v_receipt_digest,'approvedAt',v_now
    ),v_now
  );
  INSERT INTO editorial.response_excerpt_approval_receipts_v2(
    approval_id,response_id,prior_response_version,response_version,
    response_content_sha256,publication_consent_sha256,excerpt_sha256,
    publication_form,identity_receipt_id,identity_receipt_digest,reason_digest,
    actor_id,actor_assertion_jti,request_id,idempotency_key_sha256,
    request_digest,audit_event_id,outbox_event_id,receipt_payload,
    receipt_canonical,receipt_digest,approved_at
  ) VALUES(
    v_approval_id,v_response.id,v_response.version,v_response.version+1,
    v_response.response_content_sha256,v_response.publication_consent_sha256,
    v_excerpt_sha,v_form,v_identity.receipt_id,v_identity.receipt_digest,
    v_reason_digest,v_actor_id,v_actor_jti,v_request_id,v_idempotency,
    v_request_digest,v_audit,v_outbox,v_payload,v_canonical,v_receipt_digest,v_now
  );
  PERFORM set_config('gurine.response_excerpt_approval_v2','1',true);
  UPDATE editorial.responses
  SET public_excerpt_sha256=v_excerpt_sha,excerpt_approved_by=v_actor_id,
      excerpt_approved_at=v_now,
      editorial_status=CASE WHEN editorial_status='PENDING'
        THEN 'ACCEPTED' ELSE editorial_status END,
      version=version+1,updated_at=v_now
  WHERE id=v_response.id AND version=v_response.version;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_excerpt_approval_version_conflict'
      USING ERRCODE='40001';
  END IF;
  RETURN jsonb_build_object(
    'approvalId',v_approval_id,'responseId',v_response.id,
    'responseVersion',v_response.version+1,'receiptDigest',v_receipt_digest,
    'auditEventId',v_audit,'approvedAt',v_now,
    'outboxEventIds',jsonb_build_array(v_outbox),'replayed',false
  );
END
$$;
ALTER FUNCTION editorial.approve_response_excerpt_guarded_v2(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.approve_response_excerpt_guarded_v2(jsonb)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.approve_response_excerpt_guarded_v2(jsonb)
  TO gurine_control_api;
REVOKE UPDATE ON editorial.responses FROM gurine_control_api;

-- The scoped privacy receipt session is additive; it does not widen any
-- existing response/correction receipt session.
ALTER TABLE intake.submission_sessions
  DROP CONSTRAINT submission_sessions_session_kind_check,
  DROP CONSTRAINT submission_sessions_scope_type_check;
ALTER TABLE intake.submission_sessions
  ADD CONSTRAINT submission_sessions_session_kind_check CHECK (
    session_kind IN (
      'RESPONSE_PENDING','RESPONSE_ACTIVE','CORRECTION_DRAFT',
      'SUBSCRIPTION_PENDING','SUBSCRIPTION_MANAGEMENT','RESPONSE_RECEIPT',
      'CORRECTION_RECEIPT','APPEAL_CREATE','APPEAL_STATUS',
      'COMMUNICATION_PROFILE','PRIVACY_REQUEST_RECEIPT'
    )
  ),
  ADD CONSTRAINT submission_sessions_scope_type_check CHECK (
    scope_type IN (
      'RESPONSE_REQUEST','CORRECTION_DRAFT','SUBSCRIPTION',
      'RESPONSE_SUBMISSION','CORRECTION_REQUEST','RESPONSE_APPEAL',
      'COMMUNICATION_SUBJECT','PRIVACY_REQUEST'
    )
  );

ALTER TABLE intake.communication_endpoints
  ADD COLUMN endpoint_aad_digest char(64);
ALTER TABLE intake.communication_endpoints
  ADD CONSTRAINT communication_endpoints_r6d_aad_ck CHECK (
    endpoint_aad_digest IS NULL OR ops.r6d_lower_sha256(endpoint_aad_digest)
  );

-- Privacy-request V2 physical authority.  The declared response policy is
-- present as an immutable, inactive authority row; it cannot drive a clock
-- until a separately inserted APPROVED revision is bound to real proposal,
-- decision and execution receipts.  No business-calendar row is invented.
CREATE TABLE ops.privacy_response_calendar_policies_v1 (
  policy_id uuid NOT NULL,
  revision bigint NOT NULL,
  policy_version text NOT NULL,
  authority_source text NOT NULL,
  state text NOT NULL,
  timezone text NOT NULL,
  access_business_days integer NOT NULL,
  correction_business_days integer NOT NULL,
  deletion_business_days integer NOT NULL,
  restriction_business_days integer NOT NULL,
  maximum_extension_business_days integer NOT NULL,
  maximum_extension_count integer NOT NULL,
  refusal_notice_business_days integer NOT NULL,
  calendar_id uuid,
  action_proposal_id uuid,
  action_proposal_version bigint,
  operational_decision_receipt_id uuid,
  operational_decision_receipt_digest char(64),
  legal_decision_receipt_id uuid,
  legal_decision_receipt_digest char(64),
  action_execution_receipt_id uuid,
  action_execution_receipt_digest char(64),
  policy_payload jsonb NOT NULL,
  policy_canonical bytea NOT NULL,
  policy_digest char(64) NOT NULL,
  binding_digest char(64) NOT NULL UNIQUE,
  effective_at timestamptz,
  review_expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(policy_id,revision),
  CONSTRAINT privacy_response_calendar_policies_version_uq
    UNIQUE(policy_id,revision,policy_digest),
  CONSTRAINT privacy_response_calendar_policies_shape_ck CHECK (
    revision>0
    AND policy_version ~ '^[a-z0-9][a-z0-9._-]{0,99}$'
    AND authority_source ~ '^[A-Z][A-Z0-9_]{2,99}$'
    AND state IN ('DECLARED','APPROVED')
    AND timezone='Asia/Seoul'
    AND access_business_days BETWEEN 1 AND 365
    AND correction_business_days BETWEEN 1 AND 365
    AND deletion_business_days BETWEEN 1 AND 365
    AND restriction_business_days BETWEEN 1 AND 365
    AND refusal_notice_business_days BETWEEN 1 AND 365
    AND (
      maximum_extension_count=0 AND maximum_extension_business_days=0
      OR maximum_extension_count BETWEEN 1 AND 10
        AND maximum_extension_business_days BETWEEN 1 AND 365
    )
    AND policy_payload->>'policyVersion'=policy_version
    AND policy_payload->>'authoritySource'=authority_source
    AND policy_payload->>'timezone'=timezone
    AND policy_payload->>'daySystem'='BUSINESS_DAY'
    AND (policy_payload->>'accessBusinessDays')::integer=access_business_days
    AND (policy_payload->>'correctionBusinessDays')::integer=correction_business_days
    AND (policy_payload->>'deletionBusinessDays')::integer=deletion_business_days
    AND (policy_payload->>'restrictionBusinessDays')::integer=restriction_business_days
    AND (policy_payload->>'maximumExtensionBusinessDays')::integer
      =maximum_extension_business_days
    AND (policy_payload->>'maximumExtensionCount')::integer
      =maximum_extension_count
    AND policy_payload->>'extensionNoticeTiming'='BEFORE_CURRENT_DUE_AT'
    AND (policy_payload->>'refusalNoticeBusinessDays')::integer
      =refusal_notice_business_days
    AND ops.r6d_lower_sha256(policy_digest)
    AND ops.r6d_lower_sha256(binding_digest)
    AND convert_from(policy_canonical,'UTF8')::jsonb=policy_payload
    AND policy_digest=encode(extensions.digest(policy_canonical,'sha256'),'hex')
    AND (
      (
        state='DECLARED'
        AND revision=1
        AND num_nonnulls(
          calendar_id,action_proposal_id,action_proposal_version,
          operational_decision_receipt_id,operational_decision_receipt_digest,
          legal_decision_receipt_id,legal_decision_receipt_digest,
          action_execution_receipt_id,action_execution_receipt_digest,
          effective_at,review_expires_at
        )=0
      )
      OR (
        state='APPROVED'
        AND revision>1
        AND num_nonnulls(
          calendar_id,action_proposal_id,action_proposal_version,
          operational_decision_receipt_id,operational_decision_receipt_digest,
          legal_decision_receipt_id,legal_decision_receipt_digest,
          action_execution_receipt_id,action_execution_receipt_digest,
          effective_at,review_expires_at
        )=11
        AND action_proposal_version>0
        AND operational_decision_receipt_id<>legal_decision_receipt_id
        AND ops.r6d_lower_sha256(operational_decision_receipt_digest)
        AND ops.r6d_lower_sha256(legal_decision_receipt_digest)
        AND ops.r6d_lower_sha256(action_execution_receipt_digest)
        AND review_expires_at>effective_at
      )
    )
  )
);
ALTER TABLE ops.privacy_response_calendar_policies_v1 OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_response_calendar_policies_v1 FROM PUBLIC;
GRANT SELECT ON ops.privacy_response_calendar_policies_v1
  TO gurine_control_api,gurine_auditor,gurine_scheduler;
CREATE TRIGGER privacy_response_calendar_policies_v1_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_response_calendar_policies_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

INSERT INTO ops.privacy_response_calendar_policies_v1(
  policy_id,revision,policy_version,authority_source,state,timezone,
  access_business_days,correction_business_days,deletion_business_days,
  restriction_business_days,maximum_extension_business_days,
  maximum_extension_count,refusal_notice_business_days,policy_payload,
  policy_canonical,policy_digest,binding_digest
)
WITH declared(payload) AS (
  VALUES(jsonb_build_object(
    'policyVersion','supervisor-decision-v1',
    'authoritySource','SUPERVISOR_DECISION_V1','timezone','Asia/Seoul',
    'daySystem','BUSINESS_DAY','accessBusinessDays',10,
    'correctionBusinessDays',10,'deletionBusinessDays',10,
    'restrictionBusinessDays',10,'maximumExtensionBusinessDays',10,
    'maximumExtensionCount',1,'extensionNoticeTiming','BEFORE_CURRENT_DUE_AT',
    'refusalNoticeBusinessDays',10
  ))
), canonicalized AS (
  SELECT payload,ops.canonical_jsonb_v1(payload) AS canonical FROM declared
)
SELECT
  'a6d00000-0000-4000-8000-000000000001'::uuid,1,
  'supervisor-decision-v1','SUPERVISOR_DECISION_V1','DECLARED','Asia/Seoul',
  10,10,10,10,10,1,10,payload,canonical,
  encode(extensions.digest(canonical,'sha256'),'hex'),
  encode(extensions.digest(convert_to(
    'privacy-response-policy-declared-v1:'||
    encode(extensions.digest(canonical,'sha256'),'hex'),'UTF8'
  ),'sha256'),'hex')
FROM canonicalized;

-- The supervisor decision fixes only this declared v1 row.  Later APPROVED
-- revisions remain versioned policy authority and may change the bounded day
-- counts after independent legal review; runtime owners must read their exact
-- bound revision rather than reuse these seed constants.
DO $$
DECLARE
  v_seed ops.privacy_response_calendar_policies_v1%ROWTYPE;
  v_expected jsonb:=jsonb_build_object(
    'policyVersion','supervisor-decision-v1',
    'authoritySource','SUPERVISOR_DECISION_V1','timezone','Asia/Seoul',
    'daySystem','BUSINESS_DAY','accessBusinessDays',10,
    'correctionBusinessDays',10,'deletionBusinessDays',10,
    'restrictionBusinessDays',10,'maximumExtensionBusinessDays',10,
    'maximumExtensionCount',1,'extensionNoticeTiming','BEFORE_CURRENT_DUE_AT',
    'refusalNoticeBusinessDays',10
  );
BEGIN
  SELECT * INTO STRICT v_seed
  FROM ops.privacy_response_calendar_policies_v1
  WHERE policy_id='a6d00000-0000-4000-8000-000000000001'::uuid
    AND revision=1;
  IF v_seed.state<>'DECLARED'
     OR v_seed.policy_payload<>v_expected
     OR v_seed.policy_canonical<>ops.canonical_jsonb_v1(v_expected)
     OR v_seed.policy_digest<>encode(
       extensions.digest(ops.canonical_jsonb_v1(v_expected),'sha256'),'hex'
     ) THEN
    RAISE EXCEPTION 'privacy_response_calendar_supervisor_v1_seed_invalid'
      USING ERRCODE='55000';
  END IF;
END
$$;

CREATE TABLE ops.privacy_requests_v2 (
  id uuid PRIMARY KEY,
  request_type text NOT NULL,
  state text NOT NULL DEFAULT 'RECEIVED',
  identity_state text NOT NULL DEFAULT 'PENDING_VERIFICATION',
  jurisdiction text NOT NULL,
  subject_proof_hash char(64) NOT NULL,
  identity_proof_kind text NOT NULL,
  identity_proof_ref_id uuid NOT NULL,
  identity_proof_binding_digest char(64) NOT NULL,
  subject_scope_digest char(64) NOT NULL,
  scope_ciphertext bytea NOT NULL,
  scope_sha256 char(64) NOT NULL,
  scope_aad_digest char(64) NOT NULL,
  statement_ciphertext bytea NOT NULL,
  statement_sha256 char(64) NOT NULL,
  statement_aad_digest char(64) NOT NULL,
  encryption_key_id text NOT NULL,
  communication_subject_id uuid NOT NULL,
  communication_subject_origin_digest char(64) NOT NULL,
  communication_endpoint_id uuid NOT NULL,
  communication_endpoint_version bigint NOT NULL,
  communication_endpoint_digest char(64) NOT NULL,
  decision_version bigint NOT NULL DEFAULT 0,
  identity_verified_at timestamptz,
  due_at timestamptz,
  response_policy_id uuid,
  response_policy_revision bigint,
  response_policy_digest char(64),
  calendar_version_id uuid,
  calendar_digest char(64),
  current_identity_receipt_id uuid,
  current_identity_receipt_digest char(64),
  current_extension_receipt_id uuid,
  current_extension_receipt_digest char(64),
  current_refusal_receipt_id uuid,
  current_refusal_receipt_digest char(64),
  current_notice_receipt_id uuid,
  current_notice_receipt_digest char(64),
  create_request_id uuid NOT NULL UNIQUE,
  create_idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  create_request_sha256 char(64) NOT NULL,
  create_audit_event_id uuid NOT NULL UNIQUE REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  create_outbox_event_id uuid NOT NULL UNIQUE REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  create_receipt_digest char(64) NOT NULL UNIQUE,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  CONSTRAINT privacy_requests_v2_subject_scope_active_uq
    UNIQUE(subject_proof_hash,subject_scope_digest,id),
  CONSTRAINT privacy_requests_v2_policy_fk FOREIGN KEY(
    response_policy_id,response_policy_revision,response_policy_digest
  ) REFERENCES ops.privacy_response_calendar_policies_v1(
    policy_id,revision,policy_digest
  ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT privacy_requests_v2_calendar_fk FOREIGN KEY(calendar_version_id)
    REFERENCES ops.business_calendar_versions(id) ON DELETE RESTRICT,
  CONSTRAINT privacy_requests_v2_subject_fk FOREIGN KEY(
    communication_subject_id,communication_subject_origin_digest
  ) REFERENCES intake.communication_subjects(id,origin_binding_digest)
    ON DELETE RESTRICT,
  CONSTRAINT privacy_requests_v2_endpoint_fk FOREIGN KEY(
    communication_endpoint_id,communication_endpoint_version,
    communication_endpoint_digest
  ) REFERENCES intake.communication_endpoints(
    id,version,endpoint_digest
  ) ON DELETE RESTRICT,
  CONSTRAINT privacy_requests_v2_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT privacy_requests_v2_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  CONSTRAINT privacy_requests_v2_shape_ck CHECK (
    request_type IN ('ACCESS','CORRECTION','DELETION','RESTRICTION')
    AND state IN ('RECEIVED','REVIEW','APPROVED','REJECTED','COMPLETED')
    AND identity_state IN ('PENDING_VERIFICATION','VERIFIED')
    AND length(jurisdiction) BETWEEN 2 AND 64
    AND identity_proof_kind IN (
      'RESPONSE_RECEIPT','VERIFIED_ENDPOINT','IDENTITY_DOCUMENT_CHALLENGE'
    )
    AND decision_version>=0
    AND communication_endpoint_version>0
    AND octet_length(scope_ciphertext) BETWEEN 1 AND 131072
    AND octet_length(statement_ciphertext) BETWEEN 1 AND 65536
    AND length(encryption_key_id) BETWEEN 1 AND 200
    AND retention_record_class='PRIVACY_REQUEST'
    AND ops.r6d_lower_sha256(subject_proof_hash)
    AND ops.r6d_lower_sha256(identity_proof_binding_digest)
    AND ops.r6d_lower_sha256(subject_scope_digest)
    AND ops.r6d_lower_sha256(scope_sha256)
    AND ops.r6d_lower_sha256(scope_aad_digest)
    AND ops.r6d_lower_sha256(statement_sha256)
    AND ops.r6d_lower_sha256(statement_aad_digest)
    AND ops.r6d_lower_sha256(communication_subject_origin_digest)
    AND ops.r6d_lower_sha256(communication_endpoint_digest)
    AND ops.r6d_lower_sha256(create_idempotency_key_sha256)
    AND ops.r6d_lower_sha256(create_request_sha256)
    AND ops.r6d_lower_sha256(create_receipt_digest)
    AND (
      identity_state='PENDING_VERIFICATION'
      AND identity_verified_at IS NULL AND due_at IS NULL
      AND num_nonnulls(
        response_policy_id,response_policy_revision,response_policy_digest,
        calendar_version_id,calendar_digest,current_identity_receipt_id,
        current_identity_receipt_digest
      )=0
      OR identity_state='VERIFIED'
      AND identity_verified_at IS NOT NULL AND due_at>identity_verified_at
      AND num_nonnulls(
        response_policy_id,response_policy_revision,response_policy_digest,
        calendar_version_id,calendar_digest,current_identity_receipt_id,
        current_identity_receipt_digest
      )=7
    )
    AND ((current_extension_receipt_id IS NULL)=(current_extension_receipt_digest IS NULL))
    AND ((current_refusal_receipt_id IS NULL)=(current_refusal_receipt_digest IS NULL))
    AND ((current_notice_receipt_id IS NULL)=(current_notice_receipt_digest IS NULL))
    AND (response_policy_digest IS NULL OR ops.r6d_lower_sha256(response_policy_digest))
    AND (calendar_digest IS NULL OR ops.r6d_lower_sha256(calendar_digest))
    AND (current_identity_receipt_digest IS NULL OR ops.r6d_lower_sha256(current_identity_receipt_digest))
    AND (current_extension_receipt_digest IS NULL OR ops.r6d_lower_sha256(current_extension_receipt_digest))
    AND (current_refusal_receipt_digest IS NULL OR ops.r6d_lower_sha256(current_refusal_receipt_digest))
    AND (current_notice_receipt_digest IS NULL OR ops.r6d_lower_sha256(current_notice_receipt_digest))
    AND updated_at>=created_at
  )
);
ALTER TABLE ops.privacy_requests_v2 OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_requests_v2 FROM PUBLIC;
GRANT SELECT ON ops.privacy_requests_v2
  TO gurine_control_api,gurine_submission_api,gurine_auditor;
CREATE INDEX privacy_requests_v2_queue_idx
  ON ops.privacy_requests_v2(due_at ASC NULLS LAST,created_at DESC,id);
CREATE INDEX privacy_requests_v2_subject_scope_idx
  ON ops.privacy_requests_v2(subject_proof_hash,subject_scope_digest,created_at DESC,id);
CREATE TRIGGER privacy_requests_v2_retention_bind
  BEFORE INSERT OR UPDATE OF scope_ciphertext,statement_ciphertext,
    communication_endpoint_id
  ON ops.privacy_requests_v2 FOR EACH ROW
  EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

CREATE TABLE ops.privacy_request_receipt_tokens_v2 (
  token_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  privacy_request_id uuid NOT NULL UNIQUE
    REFERENCES ops.privacy_requests_v2(id) ON DELETE RESTRICT,
  operation_id text NOT NULL,
  idempotency_key_sha256 char(64) NOT NULL,
  request_sha256 char(64) NOT NULL,
  token_hmac char(64) NOT NULL UNIQUE,
  token_sha256 char(64) NOT NULL UNIQUE,
  token_key_version text NOT NULL,
  secretless_response_template jsonb NOT NULL,
  secretless_response_digest char(64) NOT NULL,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  session_id uuid UNIQUE REFERENCES intake.submission_sessions(id) ON DELETE RESTRICT,
  session_token_sha256 char(64),
  exchange_receipt_digest char(64),
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL,
  CONSTRAINT privacy_request_receipt_tokens_v2_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT privacy_request_receipt_tokens_v2_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  CONSTRAINT privacy_request_receipt_tokens_v2_shape_ck CHECK (
    operation_id='createPrivacyRequest'
    AND retention_record_class='PRIVACY_REQUEST_TOKEN'
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_sha256)
    AND ops.r6d_lower_sha256(token_hmac)
    AND ops.r6d_lower_sha256(token_sha256)
    AND length(token_key_version) BETWEEN 1 AND 100
    AND ops.r6d_lower_sha256(secretless_response_digest)
    AND secretless_response_digest=encode(extensions.digest(
      ops.canonical_jsonb_v1(secretless_response_template),'sha256'
    ),'hex')
    AND expires_at>created_at
    AND (
      consumed_at IS NULL AND session_id IS NULL
      AND session_token_sha256 IS NULL AND exchange_receipt_digest IS NULL
      OR consumed_at IS NOT NULL AND consumed_at<expires_at
      AND session_id IS NOT NULL
      AND ops.r6d_lower_sha256(session_token_sha256)
      AND ops.r6d_lower_sha256(exchange_receipt_digest)
    )
  )
);
ALTER TABLE ops.privacy_request_receipt_tokens_v2 OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_request_receipt_tokens_v2 FROM PUBLIC;
GRANT SELECT ON ops.privacy_request_receipt_tokens_v2 TO gurine_auditor;
CREATE TRIGGER privacy_request_receipt_tokens_v2_retention_bind
  BEFORE INSERT ON ops.privacy_request_receipt_tokens_v2 FOR EACH ROW
  EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

CREATE TABLE ops.privacy_request_identity_receipts_v2 (
  identity_receipt_id uuid PRIMARY KEY,
  privacy_request_id uuid NOT NULL,
  decision_version bigint NOT NULL,
  identity_proof_receipt_id uuid NOT NULL UNIQUE,
  identity_proof_receipt_digest char(64) NOT NULL,
  prior_identity_state text NOT NULL,
  identity_state text NOT NULL,
  identity_verified_at timestamptz NOT NULL,
  due_at timestamptz NOT NULL,
  response_policy_id uuid NOT NULL,
  response_policy_revision bigint NOT NULL,
  response_policy_version text NOT NULL,
  response_policy_digest char(64) NOT NULL,
  calendar_version_id uuid NOT NULL REFERENCES ops.business_calendar_versions(id) ON DELETE RESTRICT,
  calendar_digest char(64) NOT NULL,
  notice_receipt_id uuid,
  notice_receipt_digest char(64),
  event_receipt_id uuid,
  event_receipt_digest char(64),
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  verified_at timestamptz NOT NULL,
  CONSTRAINT privacy_request_identity_receipts_v2_request_uq
    UNIQUE(privacy_request_id,decision_version),
  CONSTRAINT privacy_request_identity_receipts_v2_policy_fk FOREIGN KEY(
    response_policy_id,response_policy_revision,response_policy_digest
  ) REFERENCES ops.privacy_response_calendar_policies_v1(
    policy_id,revision,policy_digest
  ) ON DELETE RESTRICT,
  CONSTRAINT privacy_request_identity_receipts_v2_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT privacy_request_identity_receipts_v2_shape_ck CHECK (
    decision_version>0 AND prior_identity_state='PENDING_VERIFICATION'
    AND identity_state='VERIFIED' AND due_at>identity_verified_at
    AND length(btrim(response_policy_version)) BETWEEN 1 AND 100
    AND retention_record_class='PRIVACY_REQUEST_EXECUTION'
    AND ops.r6d_lower_sha256(identity_proof_receipt_digest)
    AND ops.r6d_lower_sha256(response_policy_digest)
    AND ops.r6d_lower_sha256(calendar_digest)
    AND ((notice_receipt_id IS NULL)=(notice_receipt_digest IS NULL))
    AND ((event_receipt_id IS NULL)=(event_receipt_digest IS NULL))
    AND (notice_receipt_digest IS NULL OR ops.r6d_lower_sha256(notice_receipt_digest))
    AND (event_receipt_digest IS NULL OR ops.r6d_lower_sha256(event_receipt_digest))
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(extensions.digest(receipt_canonical,'sha256'),'hex')
  )
);

CREATE TABLE ops.privacy_request_extension_receipts_v2 (
  extension_receipt_id uuid PRIMARY KEY,
  privacy_request_id uuid NOT NULL,
  decision_version bigint NOT NULL,
  extension_sequence integer NOT NULL,
  prior_due_at timestamptz NOT NULL,
  due_at timestamptz NOT NULL,
  extension_business_days integer NOT NULL,
  extension_reason_code text NOT NULL,
  extension_reason_sha256 char(64) NOT NULL,
  response_policy_id uuid NOT NULL,
  response_policy_revision bigint NOT NULL,
  response_policy_digest char(64) NOT NULL,
  calendar_version_id uuid NOT NULL REFERENCES ops.business_calendar_versions(id) ON DELETE RESTRICT,
  calendar_digest char(64) NOT NULL,
  notice_receipt_id uuid,
  notice_receipt_digest char(64),
  event_receipt_id uuid,
  event_receipt_digest char(64),
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  extended_at timestamptz NOT NULL,
  UNIQUE(privacy_request_id,extension_sequence),
  UNIQUE(privacy_request_id,decision_version),
  FOREIGN KEY(response_policy_id,response_policy_revision,response_policy_digest)
    REFERENCES ops.privacy_response_calendar_policies_v1(
      policy_id,revision,policy_digest
    ) ON DELETE RESTRICT,
  FOREIGN KEY(retention_schedule_id,retention_record_class,retention_schedule_digest)
    REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT privacy_request_extension_receipts_v2_shape_ck CHECK (
    decision_version>0 AND extension_sequence BETWEEN 1 AND 10
    AND extension_business_days BETWEEN 1 AND 365
    AND extended_at<prior_due_at AND due_at>prior_due_at
    AND length(extension_reason_code) BETWEEN 1 AND 100
    AND retention_record_class='PRIVACY_REQUEST_EXECUTION'
    AND ops.r6d_lower_sha256(extension_reason_sha256)
    AND ops.r6d_lower_sha256(response_policy_digest)
    AND ops.r6d_lower_sha256(calendar_digest)
    AND ((notice_receipt_id IS NULL)=(notice_receipt_digest IS NULL))
    AND ((event_receipt_id IS NULL)=(event_receipt_digest IS NULL))
    AND (notice_receipt_digest IS NULL OR ops.r6d_lower_sha256(notice_receipt_digest))
    AND (event_receipt_digest IS NULL OR ops.r6d_lower_sha256(event_receipt_digest))
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(extensions.digest(receipt_canonical,'sha256'),'hex')
  )
);

CREATE TABLE ops.privacy_request_refusal_receipts_v2 (
  refusal_receipt_id uuid PRIMARY KEY,
  privacy_request_id uuid NOT NULL,
  decision_version bigint NOT NULL,
  rejection_reason_code text NOT NULL,
  rejection_reason_sha256 char(64) NOT NULL,
  appeal_instructions_sha256 char(64) NOT NULL,
  decision_digest char(64) NOT NULL,
  response_policy_id uuid NOT NULL,
  response_policy_revision bigint NOT NULL,
  response_policy_digest char(64) NOT NULL,
  calendar_version_id uuid NOT NULL REFERENCES ops.business_calendar_versions(id) ON DELETE RESTRICT,
  calendar_digest char(64) NOT NULL,
  decision_at timestamptz NOT NULL,
  notice_due_at timestamptz NOT NULL,
  notice_receipt_id uuid,
  notice_receipt_digest char(64),
  event_receipt_id uuid,
  event_receipt_digest char(64),
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  UNIQUE(privacy_request_id,decision_version),
  FOREIGN KEY(response_policy_id,response_policy_revision,response_policy_digest)
    REFERENCES ops.privacy_response_calendar_policies_v1(
      policy_id,revision,policy_digest
    ) ON DELETE RESTRICT,
  FOREIGN KEY(retention_schedule_id,retention_record_class,retention_schedule_digest)
    REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT privacy_request_refusal_receipts_v2_shape_ck CHECK (
    decision_version>0 AND notice_due_at>decision_at
    AND length(rejection_reason_code) BETWEEN 1 AND 100
    AND retention_record_class='PRIVACY_REQUEST_EXECUTION'
    AND ops.r6d_lower_sha256(rejection_reason_sha256)
    AND ops.r6d_lower_sha256(appeal_instructions_sha256)
    AND ops.r6d_lower_sha256(decision_digest)
    AND ops.r6d_lower_sha256(response_policy_digest)
    AND ops.r6d_lower_sha256(calendar_digest)
    AND ((notice_receipt_id IS NULL)=(notice_receipt_digest IS NULL))
    AND ((event_receipt_id IS NULL)=(event_receipt_digest IS NULL))
    AND (notice_receipt_digest IS NULL OR ops.r6d_lower_sha256(notice_receipt_digest))
    AND (event_receipt_digest IS NULL OR ops.r6d_lower_sha256(event_receipt_digest))
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(extensions.digest(receipt_canonical,'sha256'),'hex')
  )
);

CREATE TABLE ops.privacy_request_notice_receipts_v2 (
  notice_receipt_id uuid PRIMARY KEY,
  privacy_request_id uuid NOT NULL,
  notice_sequence bigint NOT NULL,
  notice_kind text NOT NULL,
  transition_receipt_id uuid NOT NULL,
  endpoint_id uuid NOT NULL,
  endpoint_version bigint NOT NULL,
  endpoint_digest char(64) NOT NULL,
  endpoint_aad_digest char(64) NOT NULL,
  encryption_key_id text NOT NULL,
  notice_sha256 char(64) NOT NULL,
  notice_aad_digest char(64) NOT NULL,
  notice_template_payload jsonb NOT NULL,
  notice_template_digest char(64) NOT NULL,
  branch_receipt_id uuid,
  branch_receipt_digest char(64),
  event_receipt_id uuid,
  event_receipt_digest char(64),
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL,
  UNIQUE(privacy_request_id,notice_sequence),
  FOREIGN KEY(endpoint_id,endpoint_version,endpoint_digest)
    REFERENCES intake.communication_endpoints(id,version,endpoint_digest)
    ON DELETE RESTRICT,
  FOREIGN KEY(retention_schedule_id,retention_record_class,retention_schedule_digest)
    REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT privacy_request_notice_receipts_v2_shape_ck CHECK (
    notice_sequence>0
    AND notice_kind IN ('IDENTITY_VERIFIED','EXTENSION','REFUSAL')
    AND endpoint_version>0
    AND length(encryption_key_id) BETWEEN 1 AND 200
    AND retention_record_class='PRIVACY_REQUEST_NOTICE'
    AND ops.r6d_lower_sha256(endpoint_digest)
    AND ops.r6d_lower_sha256(endpoint_aad_digest)
    AND ops.r6d_lower_sha256(notice_sha256)
    AND ops.r6d_lower_sha256(notice_aad_digest)
    AND ops.r6d_lower_sha256(notice_template_digest)
    AND notice_template_digest=encode(extensions.digest(
      ops.canonical_jsonb_v1(notice_template_payload),'sha256'
    ),'hex')
    AND ((branch_receipt_id IS NULL)=(branch_receipt_digest IS NULL))
    AND ((event_receipt_id IS NULL)=(event_receipt_digest IS NULL))
    AND (branch_receipt_digest IS NULL OR ops.r6d_lower_sha256(branch_receipt_digest))
    AND (event_receipt_digest IS NULL OR ops.r6d_lower_sha256(event_receipt_digest))
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(extensions.digest(receipt_canonical,'sha256'),'hex')
  )
);

CREATE TABLE ops.privacy_request_transition_receipts_v2 (
  transition_receipt_id uuid PRIMARY KEY,
  privacy_request_id uuid NOT NULL,
  decision_version bigint NOT NULL,
  transition text NOT NULL,
  prior_state text NOT NULL,
  state text NOT NULL,
  reason_code text NOT NULL,
  reason_sha256 char(64) NOT NULL,
  reason_aad_digest char(64) NOT NULL,
  extension_reason_code text,
  extension_reason_sha256 char(64),
  extension_reason_aad_digest char(64),
  rejection_reason_code text,
  rejection_reason_sha256 char(64),
  rejection_reason_aad_digest char(64),
  appeal_instructions_sha256 char(64),
  appeal_instructions_aad_digest char(64),
  encryption_key_id text NOT NULL,
  actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  actor_assertion_jti uuid NOT NULL UNIQUE,
  actor_action_digest char(64) NOT NULL,
  step_up_authorization_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_sha256 char(64) NOT NULL,
  identity_receipt_id uuid,
  identity_receipt_digest char(64),
  extension_receipt_id uuid,
  extension_receipt_digest char(64),
  refusal_receipt_id uuid,
  refusal_receipt_digest char(64),
  notice_receipt_id uuid,
  notice_receipt_digest char(64),
  event_receipt_id uuid,
  event_receipt_digest char(64),
  audit_event_id uuid NOT NULL UNIQUE REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  outbox_event_ids uuid[] NOT NULL,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  decided_at timestamptz NOT NULL,
  UNIQUE(privacy_request_id,decision_version),
  CONSTRAINT privacy_request_transition_receipts_v2_id_request_uq
    UNIQUE(transition_receipt_id,privacy_request_id),
  FOREIGN KEY(retention_schedule_id,retention_record_class,retention_schedule_digest)
    REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT privacy_request_transition_receipts_v2_shape_ck CHECK (
    decision_version>0
    AND transition IN ('VERIFY_IDENTITY','START_REVIEW','APPROVE','REJECT','EXTEND')
    AND prior_state IN ('RECEIVED','REVIEW','APPROVED')
    AND state IN ('RECEIVED','REVIEW','APPROVED','REJECTED')
    AND length(reason_code) BETWEEN 1 AND 100
    AND length(encryption_key_id) BETWEEN 1 AND 200
    AND retention_record_class='PRIVACY_REQUEST_EXECUTION'
    AND ops.r6d_lower_sha256(reason_sha256)
    AND ops.r6d_lower_sha256(reason_aad_digest)
    AND (extension_reason_aad_digest IS NULL
      OR ops.r6d_lower_sha256(extension_reason_aad_digest))
    AND (rejection_reason_aad_digest IS NULL
      OR ops.r6d_lower_sha256(rejection_reason_aad_digest))
    AND (appeal_instructions_aad_digest IS NULL
      OR ops.r6d_lower_sha256(appeal_instructions_aad_digest))
    AND ops.r6d_lower_sha256(actor_action_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_sha256)
    AND cardinality(outbox_event_ids) BETWEEN 1 AND 2
    AND ops.uuid_array_is_sorted_unique(outbox_event_ids)
    AND ((identity_receipt_id IS NULL)=(identity_receipt_digest IS NULL))
    AND ((extension_receipt_id IS NULL)=(extension_receipt_digest IS NULL))
    AND ((refusal_receipt_id IS NULL)=(refusal_receipt_digest IS NULL))
    AND ((notice_receipt_id IS NULL)=(notice_receipt_digest IS NULL))
    AND ((event_receipt_id IS NULL)=(event_receipt_digest IS NULL))
    AND (identity_receipt_digest IS NULL OR ops.r6d_lower_sha256(identity_receipt_digest))
    AND (extension_receipt_digest IS NULL OR ops.r6d_lower_sha256(extension_receipt_digest))
    AND (refusal_receipt_digest IS NULL OR ops.r6d_lower_sha256(refusal_receipt_digest))
    AND (notice_receipt_digest IS NULL OR ops.r6d_lower_sha256(notice_receipt_digest))
    AND (event_receipt_digest IS NULL OR ops.r6d_lower_sha256(event_receipt_digest))
    AND (
      transition='VERIFY_IDENTITY'
      AND num_nonnulls(identity_receipt_id,identity_receipt_digest,
        notice_receipt_id,notice_receipt_digest)=4
      AND num_nonnulls(extension_receipt_id,extension_receipt_digest,
        refusal_receipt_id,refusal_receipt_digest,
        extension_reason_code,extension_reason_sha256,extension_reason_aad_digest,
        rejection_reason_code,rejection_reason_sha256,rejection_reason_aad_digest,
        appeal_instructions_sha256,appeal_instructions_aad_digest)=0
      OR transition='EXTEND'
      AND num_nonnulls(extension_receipt_id,extension_receipt_digest,
        notice_receipt_id,notice_receipt_digest,
        extension_reason_code,extension_reason_sha256,extension_reason_aad_digest)=7
      AND num_nonnulls(identity_receipt_id,identity_receipt_digest,
        refusal_receipt_id,refusal_receipt_digest,
        rejection_reason_code,rejection_reason_sha256,rejection_reason_aad_digest,
        appeal_instructions_sha256,appeal_instructions_aad_digest)=0
      OR transition='REJECT'
      AND num_nonnulls(refusal_receipt_id,refusal_receipt_digest,
        notice_receipt_id,notice_receipt_digest,
        rejection_reason_code,rejection_reason_sha256,rejection_reason_aad_digest,
        appeal_instructions_sha256,appeal_instructions_aad_digest)=9
      AND num_nonnulls(identity_receipt_id,identity_receipt_digest,
        extension_receipt_id,extension_receipt_digest,
        extension_reason_code,extension_reason_sha256,extension_reason_aad_digest)=0
      OR transition IN ('START_REVIEW','APPROVE')
      AND num_nonnulls(identity_receipt_id,identity_receipt_digest,
        extension_receipt_id,extension_receipt_digest,
        refusal_receipt_id,refusal_receipt_digest,
        notice_receipt_id,notice_receipt_digest,
        extension_reason_code,extension_reason_sha256,extension_reason_aad_digest,
        rejection_reason_code,rejection_reason_sha256,rejection_reason_aad_digest,
        appeal_instructions_sha256,appeal_instructions_aad_digest)=0
    )
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(extensions.digest(receipt_canonical,'sha256'),'hex')
  )
);

ALTER TABLE ops.privacy_request_identity_receipts_v2 OWNER TO gurine_migrator;
ALTER TABLE ops.privacy_request_extension_receipts_v2 OWNER TO gurine_migrator;
ALTER TABLE ops.privacy_request_refusal_receipts_v2 OWNER TO gurine_migrator;
ALTER TABLE ops.privacy_request_notice_receipts_v2 OWNER TO gurine_migrator;
ALTER TABLE ops.privacy_request_transition_receipts_v2 OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_request_identity_receipts_v2 FROM PUBLIC;
REVOKE ALL ON ops.privacy_request_extension_receipts_v2 FROM PUBLIC;
REVOKE ALL ON ops.privacy_request_refusal_receipts_v2 FROM PUBLIC;
REVOKE ALL ON ops.privacy_request_notice_receipts_v2 FROM PUBLIC;
REVOKE ALL ON ops.privacy_request_transition_receipts_v2 FROM PUBLIC;
GRANT SELECT ON ops.privacy_request_identity_receipts_v2,
  ops.privacy_request_extension_receipts_v2,
  ops.privacy_request_refusal_receipts_v2,
  ops.privacy_request_notice_receipts_v2,
  ops.privacy_request_transition_receipts_v2
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER privacy_request_identity_receipts_v2_retention_bind
  BEFORE INSERT ON ops.privacy_request_identity_receipts_v2 FOR EACH ROW
  EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();
CREATE TRIGGER privacy_request_extension_receipts_v2_retention_bind
  BEFORE INSERT ON ops.privacy_request_extension_receipts_v2 FOR EACH ROW
  EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();
CREATE TRIGGER privacy_request_refusal_receipts_v2_retention_bind
  BEFORE INSERT ON ops.privacy_request_refusal_receipts_v2 FOR EACH ROW
  EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();
CREATE TRIGGER privacy_request_notice_receipts_v2_retention_bind
  BEFORE INSERT ON ops.privacy_request_notice_receipts_v2 FOR EACH ROW
  EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();
CREATE TRIGGER privacy_request_transition_receipts_v2_retention_bind
  BEFORE INSERT ON ops.privacy_request_transition_receipts_v2 FOR EACH ROW
  EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();
CREATE TRIGGER privacy_request_identity_receipts_v2_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_request_identity_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER privacy_request_extension_receipts_v2_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_request_extension_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER privacy_request_refusal_receipts_v2_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_request_refusal_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER privacy_request_notice_receipts_v2_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_request_notice_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER privacy_request_transition_receipts_v2_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_request_transition_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

ALTER TABLE ops.privacy_request_identity_receipts_v2
  ADD CONSTRAINT privacy_request_identity_receipts_v2_request_fk
    FOREIGN KEY(privacy_request_id) REFERENCES ops.privacy_requests_v2(id)
    ON DELETE RESTRICT;
ALTER TABLE ops.privacy_request_extension_receipts_v2
  ADD CONSTRAINT privacy_request_extension_receipts_v2_request_fk
    FOREIGN KEY(privacy_request_id) REFERENCES ops.privacy_requests_v2(id)
    ON DELETE RESTRICT;
ALTER TABLE ops.privacy_request_refusal_receipts_v2
  ADD CONSTRAINT privacy_request_refusal_receipts_v2_request_fk
    FOREIGN KEY(privacy_request_id) REFERENCES ops.privacy_requests_v2(id)
    ON DELETE RESTRICT;
ALTER TABLE ops.privacy_request_notice_receipts_v2
  ADD CONSTRAINT privacy_request_notice_receipts_v2_request_fk
    FOREIGN KEY(privacy_request_id) REFERENCES ops.privacy_requests_v2(id)
    ON DELETE RESTRICT;
ALTER TABLE ops.privacy_request_transition_receipts_v2
  ADD CONSTRAINT privacy_request_transition_receipts_v2_request_fk
    FOREIGN KEY(privacy_request_id) REFERENCES ops.privacy_requests_v2(id)
    ON DELETE RESTRICT;

-- Migration-owned static policy catalogs are code authority and are the sole
-- exception to runtime record-class schedules.  They are immutable, cannot be
-- extended by an application role, and contain neither user data nor receipt
-- evidence.  Every runtime assessment, assertion and receipt below is bound to
-- one currently approved finite schedule and therefore fails closed while no
-- such schedule exists.
COMMENT ON TABLE editorial.named_person_publication_policies IS
  'Migration-owned immutable code-authority catalog; runtime policy inserts are closed. Record-class schedules bind assessments and receipts, not this static seed.';
COMMENT ON TABLE ops.privacy_response_calendar_policies_v1 IS
  'Migration-owned immutable declared/approved calendar-policy authority. DECLARED is non-operational; runtime privacy receipts carry finite record-class schedule bindings.';

ALTER TABLE core.relationship_graph_person_erasure_receipts_v3
  ADD COLUMN retention_schedule_id uuid NOT NULL,
  ADD COLUMN retention_record_class text NOT NULL,
  ADD COLUMN retention_schedule_digest char(64) NOT NULL,
  ADD CONSTRAINT person_erasure_v3_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT person_erasure_v3_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT person_erasure_v3_class_ck CHECK(
    retention_record_class='PERSON_ERASURE_GOVERNANCE'
  );
CREATE TRIGGER person_erasure_v3_retention_bind
  BEFORE INSERT ON core.relationship_graph_person_erasure_receipts_v3
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

ALTER TABLE editorial.named_person_publication_assessments
  ADD COLUMN retention_schedule_id uuid NOT NULL,
  ADD COLUMN retention_record_class text NOT NULL,
  ADD COLUMN retention_schedule_digest char(64) NOT NULL,
  ADD CONSTRAINT np_assess_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT np_assess_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT np_assess_class_ck CHECK(
    retention_record_class='NAMED_PERSON_PUBLICATION_GOVERNANCE'
  );
CREATE TRIGGER np_assess_retention_bind
  BEFORE INSERT ON editorial.named_person_publication_assessments
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

ALTER TABLE editorial.named_person_publication_findings
  ADD COLUMN retention_schedule_id uuid NOT NULL,
  ADD COLUMN retention_record_class text NOT NULL,
  ADD COLUMN retention_schedule_digest char(64) NOT NULL,
  ADD CONSTRAINT np_findings_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT np_findings_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT np_findings_class_ck CHECK(
    retention_record_class='NAMED_PERSON_PUBLICATION_GOVERNANCE'
  );
CREATE TRIGGER np_findings_retention_bind
  BEFORE INSERT ON editorial.named_person_publication_findings
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

ALTER TABLE editorial.named_person_legal_overrides
  ADD COLUMN retention_schedule_id uuid NOT NULL,
  ADD COLUMN retention_record_class text NOT NULL,
  ADD COLUMN retention_schedule_digest char(64) NOT NULL,
  ADD CONSTRAINT np_override_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT np_override_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT np_override_class_ck CHECK(
    retention_record_class='NAMED_PERSON_PUBLICATION_GOVERNANCE'
  );
CREATE TRIGGER np_override_retention_bind
  BEFORE INSERT ON editorial.named_person_legal_overrides
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

CREATE TRIGGER legal_hold_v2_retention_bind
  BEFORE INSERT ON ops.legal_hold_placement_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

ALTER TABLE editorial.response_submission_origin_receipts_v2
  ADD COLUMN retention_schedule_id uuid NOT NULL,
  ADD COLUMN retention_record_class text NOT NULL,
  ADD COLUMN retention_schedule_digest char(64) NOT NULL,
  ADD CONSTRAINT response_origin_v2_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT response_origin_v2_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT response_origin_v2_class_ck CHECK(
    retention_record_class='RESPONSE_IDENTITY_GOVERNANCE'
  );
CREATE TRIGGER response_origin_v2_retention_bind
  BEFORE INSERT ON editorial.response_submission_origin_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

ALTER TABLE editorial.response_organization_identity_assertions_v1
  ADD COLUMN retention_schedule_id uuid NOT NULL,
  ADD COLUMN retention_record_class text NOT NULL,
  ADD COLUMN retention_schedule_digest char(64) NOT NULL,
  ADD CONSTRAINT response_assertion_v1_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT response_assertion_v1_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT response_assertion_v1_class_ck CHECK(
    retention_record_class='RESPONSE_IDENTITY_GOVERNANCE'
  );
CREATE TRIGGER response_assertion_v1_retention_bind
  BEFORE INSERT ON editorial.response_organization_identity_assertions_v1
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

ALTER TABLE editorial.response_publication_identity_receipts_v1
  ADD COLUMN retention_schedule_id uuid NOT NULL,
  ADD COLUMN retention_record_class text NOT NULL,
  ADD COLUMN retention_schedule_digest char(64) NOT NULL,
  ADD CONSTRAINT response_identity_v1_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT response_identity_v1_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT response_identity_v1_class_ck CHECK(
    retention_record_class='RESPONSE_IDENTITY_GOVERNANCE'
  );
CREATE TRIGGER response_identity_v1_retention_bind
  BEFORE INSERT ON editorial.response_publication_identity_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

ALTER TABLE intake.response_submission_receipts_v3
  ADD COLUMN retention_schedule_id uuid NOT NULL,
  ADD COLUMN retention_record_class text NOT NULL,
  ADD COLUMN retention_schedule_digest char(64) NOT NULL,
  ADD CONSTRAINT response_submission_v3_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT response_submission_v3_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT response_submission_v3_class_ck CHECK(
    retention_record_class='RESPONSE_IDENTITY_GOVERNANCE'
  );
CREATE TRIGGER response_submission_v3_retention_bind
  BEFORE INSERT ON intake.response_submission_receipts_v3
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

ALTER TABLE editorial.response_excerpt_approval_receipts_v2
  ADD COLUMN retention_schedule_id uuid NOT NULL,
  ADD COLUMN retention_record_class text NOT NULL,
  ADD COLUMN retention_schedule_digest char(64) NOT NULL,
  ADD CONSTRAINT response_excerpt_v2_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(id,record_class,schedule_digest)
    MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT response_excerpt_v2_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT response_excerpt_v2_class_ck CHECK(
    retention_record_class='RESPONSE_IDENTITY_GOVERNANCE'
  );
CREATE TRIGGER response_excerpt_v2_retention_bind
  BEFORE INSERT ON editorial.response_excerpt_approval_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

ALTER TABLE ops.privacy_request_identity_receipts_v2
  ADD CONSTRAINT privacy_identity_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT;
ALTER TABLE ops.privacy_request_extension_receipts_v2
  ADD CONSTRAINT privacy_extension_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT;
ALTER TABLE ops.privacy_request_refusal_receipts_v2
  ADD CONSTRAINT privacy_refusal_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT;
ALTER TABLE ops.privacy_request_notice_receipts_v2
  ADD CONSTRAINT privacy_notice_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT;
ALTER TABLE ops.privacy_request_transition_receipts_v2
  ADD CONSTRAINT privacy_transition_class_fk FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT;

CREATE VIEW public.approved_record_class_schedules
WITH (security_barrier=true)
AS
SELECT
  ranked.record_class,
  ranked.revision,
  ranked.purpose,
  ranked.lawful_basis,
  ranked.trigger_kind,
  ranked.active_duration_seconds,
  ranked.backup_duration_seconds,
  ranked.terminal_action,
  ranked.effective_at,
  ranked.review_expires_at,
  ranked.schedule_digest
FROM (
  SELECT
    schedule.record_class,
    schedule.revision,
    schedule.purpose,
    schedule.lawful_basis,
    schedule.trigger_kind,
    schedule.active_duration_seconds,
    schedule.backup_duration_seconds,
    schedule.terminal_action,
    schedule.effective_at,
    schedule.review_expires_at,
    schedule.schedule_digest,
    row_number() OVER (
      PARTITION BY schedule.record_class
      ORDER BY schedule.effective_at DESC,schedule.revision DESC,schedule.id DESC
    ) AS current_ordinal
  FROM ops.record_class_schedules AS schedule
  JOIN ops.execution_receipts AS execution
    ON execution.id=schedule.action_execution_receipt_id
   AND execution.receipt_digest=schedule.action_execution_receipt_digest
   AND execution.aggregate_state='SUCCEEDED'
  JOIN ops.action_decisions AS operational_decision
    ON operational_decision.id=schedule.operational_action_decision_id
   AND operational_decision.receipt_digest=schedule.operational_action_decision_receipt_digest
   AND operational_decision.decision_kind='APPROVE'
  JOIN ops.action_decisions AS legal_decision
    ON legal_decision.id=schedule.legal_action_decision_id
   AND legal_decision.receipt_digest=schedule.legal_action_decision_receipt_digest
   AND legal_decision.decision_kind='APPROVE'
  WHERE schedule.effective_at<=clock_timestamp()
    AND schedule.review_expires_at>clock_timestamp()
) AS ranked
WHERE ranked.current_ordinal=1;
ALTER VIEW public.approved_record_class_schedules OWNER TO gurine_migrator;
REVOKE ALL ON public.approved_record_class_schedules FROM PUBLIC;
REVOKE ALL ON ops.record_class_schedules FROM gurine_public_api;
GRANT SELECT ON public.approved_record_class_schedules TO gurine_public_api;

CREATE OR REPLACE FUNCTION intake.verify_response_submission_notification_v2(
  p_event_id uuid,p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,intake,ops,extensions,pg_temp
AS $$
DECLARE
  v_event ops.outbox%ROWTYPE;
  v_receipt intake.response_submission_receipts_v3%ROWTYPE;
  v_envelope char(64);
BEGIN
  IF p_event_id IS NULL OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION 'response_submission_notification_input_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO STRICT v_event FROM ops.outbox
  WHERE id=p_event_id AND event_type='notification.response_submitted.v2';
  IF v_event.payload<>p_payload
     OR v_event.aggregate_type<>'response_submission'
     OR v_event.aggregate_id<>p_payload->>'responseSubmissionId'
     OR v_event.aggregate_version<>(p_payload->>'receiptVersion')::bigint
     OR (SELECT count(*) FROM jsonb_object_keys(p_payload))<>8
     OR NOT p_payload ?& ARRAY[
       'responseSubmissionId','responseRequestId','responseRequestVersion',
       'responseRequestBindingDigest','submissionSha256','receiptVersion',
       'receiptDigest','submittedAt'
     ] THEN
    RAISE EXCEPTION 'response_submission_notification_event_mismatch'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO STRICT v_receipt FROM intake.response_submission_receipts_v3
  WHERE notification_event_id=p_event_id
    AND response_submission_id=(p_payload->>'responseSubmissionId')::uuid
    AND response_request_id=(p_payload->>'responseRequestId')::uuid
    AND response_request_version=(p_payload->>'responseRequestVersion')::bigint
    AND response_request_binding_digest=p_payload->>'responseRequestBindingDigest'
    AND submission_sha256=p_payload->>'submissionSha256'
    AND receipt_version=(p_payload->>'receiptVersion')::bigint
    AND receipt_digest=p_payload->>'receiptDigest'
    AND submitted_at=(p_payload->>'submittedAt')::timestamptz;
  v_envelope:=ops.r6d_outbox_envelope_digest_v1(p_event_id);
  RETURN jsonb_build_object(
    'eventId',p_event_id,'eventEnvelopeDigest',v_envelope,
    'responseSubmissionId',v_receipt.response_submission_id,
    'responseRequestId',v_receipt.response_request_id,
    'responseRequestVersion',v_receipt.response_request_version,
    'responseRequestBindingDigest',btrim(v_receipt.response_request_binding_digest),
    'submissionSha256',btrim(v_receipt.submission_sha256),
    'receiptVersion',v_receipt.receipt_version,
    'receiptDigest',btrim(v_receipt.receipt_digest),
    'submittedAt',v_receipt.submitted_at
  );
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'response_submission_notification_authority_missing_or_ambiguous'
    USING ERRCODE='23514';
END
$$;
ALTER FUNCTION intake.verify_response_submission_notification_v2(uuid,jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION intake.verify_response_submission_notification_v2(uuid,jsonb)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION intake.verify_response_submission_notification_v2(uuid,jsonb)
  TO gurine_notification_worker;

-- R6d owner functions enqueue only schemas admitted by the immutable catalog.
INSERT INTO ops.event_types(
  event_type,category,schema_version,active,payload_schema_uri,payload_schema
) VALUES
  ('editorial.response_materialized.v2','DOMAIN',2,true,'payloads/editorial_response_materialized_v2.schema.json',$r6d_event_schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/editorial.response_materialized.v2.schema.json","type":"object","additionalProperties":false,"required":["responseSubmissionId","responseRequestId","editorialResponseId","partyType","partyEntityId","responseVersion","responseContentSha256","publicationConsentSha256","identityStatus","submissionReceiptVersion","submissionReceiptDigest","ownedIntakeReceiptDigest","materializedAt","resultDigest"],"properties":{"responseSubmissionId":{"type":"string","format":"uuid"},"responseRequestId":{"type":"string","format":"uuid"},"editorialResponseId":{"type":"string","format":"uuid"},"partyType":{"type":"string","enum":["AGENCY","SUPPLIER","OTHER"]},"partyEntityId":{"oneOf":[{"type":"string","format":"uuid"},{"type":"null"}]},"responseVersion":{"type":"integer","minimum":1},"responseContentSha256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"publicationConsentSha256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"identityStatus":{"type":"string","const":"UNVERIFIED"},"submissionReceiptVersion":{"type":"integer","minimum":1},"submissionReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"ownedIntakeReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"materializedAt":{"type":"string","format":"date-time"},"resultDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}}$r6d_event_schema$::jsonb),
  ('response.excerpt_approved.v2','DOMAIN',2,true,'payloads/response_excerpt_approved_v2.schema.json',$r6d_event_schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/response.excerpt_approved.v2.schema.json","type":"object","additionalProperties":false,"required":["responseId","responseVersion","excerptSha256","publicationForm","identityReceiptDigest","approvalReceiptDigest","approvedAt"],"properties":{"responseId":{"type":"string","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"},"responseVersion":{"type":"integer","minimum":1},"excerptSha256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"publicationForm":{"type":"string","enum":["ANONYMOUS","FULL","REDACTED"]},"identityReceiptDigest":{"oneOf":[{"type":"string","pattern":"^[0-9a-f]{64}$"},{"type":"null"}]},"approvalReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"approvedAt":{"type":"string","format":"date-time"}},"allOf":[{"if":{"properties":{"publicationForm":{"const":"ANONYMOUS"}},"required":["publicationForm"]},"then":{"properties":{"identityReceiptDigest":{"type":"null"}}},"else":{"properties":{"identityReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}}}]}$r6d_event_schema$::jsonb),
  ('response.organization_identity_verified.v1','DOMAIN',1,true,'payloads/response_organization_identity_verified_v1.schema.json',$r6d_event_schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/response.organization_identity_verified.v1.schema.json","type":"object","additionalProperties":false,"required":["responseId","responseVersion","responseContentSha256","organizationId","publicationForm","identityStatus","verificationMethod","identityAssertionId","identityAssertionVersion","identityAssertionDigest","sourceVerificationReceiptDigest","auditReceiptDigest","verifiedAt"],"properties":{"responseId":{"type":"string","format":"uuid"},"responseVersion":{"type":"integer","minimum":1},"responseContentSha256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"organizationId":{"type":"string","format":"uuid"},"publicationForm":{"type":"string","enum":["FULL","REDACTED"]},"identityStatus":{"type":"string","const":"SECOND_FACTOR_VERIFIED"},"verificationMethod":{"type":"string","enum":["OFFICIAL_DOMAIN_EMAIL","OFFICIAL_DOCUMENT"]},"identityAssertionId":{"type":"string","format":"uuid"},"identityAssertionVersion":{"type":"integer","minimum":1},"identityAssertionDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"sourceVerificationReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"auditReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"verifiedAt":{"type":"string","format":"date-time"}}}$r6d_event_schema$::jsonb),
  ('privacy.request_created.v2','DOMAIN',2,true,'payloads/privacy_request_created_v2.schema.json',$r6d_event_schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/privacy.request_created.v2.schema.json","type":"object","additionalProperties":false,"required":["retentionRequestId","requestType","subjectProofHash","jurisdiction","scopeDigest","identityState","identityVerifiedAt","dueAt","receiptDigest","commandReceiptDigest"],"properties":{"retentionRequestId":{"type":"string","format":"uuid"},"requestType":{"type":"string","enum":["ACCESS","CORRECTION","DELETION","RESTRICTION"]},"subjectProofHash":{"type":"string","pattern":"^[0-9a-f]{64}$"},"jurisdiction":{"type":"string","minLength":1,"maxLength":10000},"scopeDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"identityState":{"type":"string","const":"PENDING_VERIFICATION"},"identityVerifiedAt":{"type":"null"},"dueAt":{"type":"null"},"receiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"commandReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}}$r6d_event_schema$::jsonb),
  ('privacy.request_identity_verified.v1','DOMAIN',1,true,'payloads/privacy_request_identity_verified_v1.schema.json',$r6d_event_schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/privacy.request_identity_verified.v1.schema.json","type":"object","additionalProperties":false,"required":["retentionRequestId","requestType","priorIdentityState","identityState","identityProofReceiptDigest","identityVerifiedAt","responsePolicyVersion","responsePolicyDigest","calendarVersionId","calendarDigest","dueAt","verificationReceiptDigest"],"properties":{"retentionRequestId":{"type":"string","format":"uuid"},"requestType":{"type":"string","enum":["ACCESS","CORRECTION","DELETION","RESTRICTION"]},"priorIdentityState":{"type":"string","const":"PENDING_VERIFICATION"},"identityState":{"type":"string","const":"VERIFIED"},"identityProofReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"identityVerifiedAt":{"type":"string","format":"date-time"},"responsePolicyVersion":{"type":"string","minLength":1,"maxLength":10000},"responsePolicyDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"calendarVersionId":{"type":"string","format":"uuid"},"calendarDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"dueAt":{"type":"string","format":"date-time"},"verificationReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}}$r6d_event_schema$::jsonb),
  ('privacy.request_extension_notified.v1','DOMAIN',1,true,'payloads/privacy_request_extension_notified_v1.schema.json',$r6d_event_schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/privacy.request_extension_notified.v1.schema.json","type":"object","additionalProperties":false,"required":["retentionRequestId","requestType","priorDueAt","dueAt","extensionBusinessDays","extensionSequence","reasonDigest","responsePolicyVersion","responsePolicyDigest","calendarVersionId","calendarDigest","notifiedAt","notificationReceiptDigest"],"properties":{"retentionRequestId":{"type":"string","format":"uuid"},"requestType":{"type":"string","enum":["ACCESS","CORRECTION","DELETION","RESTRICTION"]},"priorDueAt":{"type":"string","format":"date-time"},"dueAt":{"type":"string","format":"date-time"},"extensionBusinessDays":{"type":"integer","minimum":1,"maximum":365},"extensionSequence":{"type":"integer","minimum":1,"maximum":10},"reasonDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"responsePolicyVersion":{"type":"string","minLength":1,"maxLength":10000},"responsePolicyDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"calendarVersionId":{"type":"string","format":"uuid"},"calendarDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"notifiedAt":{"type":"string","format":"date-time"},"notificationReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}}$r6d_event_schema$::jsonb),
  ('privacy.request_refusal_notified.v1','DOMAIN',1,true,'payloads/privacy_request_refusal_notified_v1.schema.json',$r6d_event_schema${"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://gurine.invalid/events/privacy.request_refusal_notified.v1.schema.json","type":"object","additionalProperties":false,"required":["retentionRequestId","requestType","decisionDigest","reasonDigest","appealInstructionsDigest","responsePolicyVersion","responsePolicyDigest","calendarVersionId","calendarDigest","decisionAt","noticeDueAt","notifiedAt","notificationReceiptDigest"],"properties":{"retentionRequestId":{"type":"string","format":"uuid"},"requestType":{"type":"string","enum":["ACCESS","CORRECTION","DELETION","RESTRICTION"]},"decisionDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"reasonDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"appealInstructionsDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"responsePolicyVersion":{"type":"string","minLength":1,"maxLength":10000},"responsePolicyDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"calendarVersionId":{"type":"string","format":"uuid"},"calendarDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"decisionAt":{"type":"string","format":"date-time"},"noticeDueAt":{"type":"string","format":"date-time"},"notifiedAt":{"type":"string","format":"date-time"},"notificationReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}}}$r6d_event_schema$::jsonb)
ON CONFLICT(event_type) DO UPDATE SET
  category=EXCLUDED.category,schema_version=EXCLUDED.schema_version,
  active=EXCLUDED.active,payload_schema_uri=EXCLUDED.payload_schema_uri,
  payload_schema=EXCLUDED.payload_schema;


-- R6d Q2 response organization identity and excerpt approval closure.
--
-- Intended insertion point: after the two organization-official-channel
-- registry tables and require_current_official_channel_v1 have been declared,
-- and after the response receipt retention bind triggers, but before the final
-- event-catalog INSERT / COMMIT in 0038_r6d_legal_hardening.sql.
--
-- This snippet deliberately omits retention columns from owner INSERT lists.
-- The existing BEFORE INSERT schedule bind triggers remain the sole authority
-- and keep missing/unapproved schedules fail-closed.

-- The SECURITY DEFINER owner validates and advances the exact response row and
-- resolves the bound agency. Runtime roles retain no direct access.
GRANT SELECT,INSERT,UPDATE ON editorial.responses TO gurine_migrator;
-- Row-locking the retention snapshot subject requires UPDATE privilege even
-- though the owner path never mutates either master relation.
GRANT SELECT,UPDATE ON core.agencies,core.suppliers TO gurine_migrator;

-- Replaces the registry validator only to close two current-source gaps:
-- the consumed EMAIL_LINK proof itself must still be unexpired at evaluation,
-- and official-document evidence must still point at the current source row.
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
AS $$
DECLARE
  v_assertion editorial.organization_official_channel_assertions_v1%ROWTYPE;
BEGIN
  IF p_assertion_id IS NULL OR p_organization_kind NOT IN ('AGENCY','SUPPLIER')
     OR p_organization_id IS NULL OR p_response_request_id IS NULL
     OR p_case_id IS NULL OR p_identity_actor_id IS NULL
     OR p_evaluated_at IS NULL THEN
    RAISE EXCEPTION 'official_channel_scope_invalid' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_assertion
  FROM editorial.organization_official_channel_assertions_v1
  WHERE assertion_id=p_assertion_id FOR UPDATE;
  IF NOT FOUND
     OR v_assertion.organization_kind<>p_organization_kind
     OR v_assertion.organization_id<>p_organization_id
     OR v_assertion.independent_verifier_user_id=p_identity_actor_id
     OR v_assertion.verified_at>p_evaluated_at
     OR v_assertion.expires_at<=p_evaluated_at
     OR EXISTS(
       SELECT 1
       FROM editorial.organization_official_channel_revocation_receipts_v1
       WHERE assertion_id=v_assertion.assertion_id
     )
     OR NOT EXISTS(
       SELECT 1 FROM ops.users AS verifier
       WHERE verifier.id=v_assertion.independent_verifier_user_id
         AND verifier.status='ACTIVE'
     ) THEN
    RAISE EXCEPTION 'official_channel_unavailable' USING ERRCODE='23514';
  END IF;

  IF v_assertion.verification_method='OFFICIAL_DOMAIN_EMAIL' THEN
    IF NOT EXISTS(
      SELECT 1
      FROM intake.communication_endpoint_verifications AS verification
      JOIN intake.communication_endpoints AS endpoint
        ON endpoint.id=verification.endpoint_id
       AND endpoint.subject_id=verification.subject_id
       AND endpoint.version=verification.endpoint_version
       AND endpoint.endpoint_digest=verification.endpoint_snapshot_digest
      JOIN intake.communication_subjects AS subject
        ON subject.id=verification.subject_id
      JOIN intake.communication_endpoint_link_events AS current_link
        ON current_link.endpoint_id=endpoint.id
       AND current_link.subject_id=subject.id
       AND current_link.endpoint_version=endpoint.version
       AND current_link.endpoint_snapshot_digest=endpoint.endpoint_digest
      JOIN editorial.response_request_sent_receipts AS sent
        ON sent.response_request_id=p_response_request_id
       AND sent.endpoint_id=endpoint.id
       AND sent.endpoint_version=endpoint.version
       AND sent.endpoint_snapshot_digest=endpoint.endpoint_digest
      WHERE verification.id=v_assertion.communication_verification_id
        AND verification.subject_id=v_assertion.communication_subject_id
        AND verification.receipt_digest=
          v_assertion.underlying_source_proof_digest
        AND verification.state='VERIFIED'
        -- OTP-only proof is never an organization-identity qualifier.
        AND verification.challenge_kind='EMAIL_LINK'
        AND verification.verified_at IS NOT NULL
        AND verification.verified_at<=v_assertion.verified_at
        AND verification.consumed_at IS NOT NULL
        AND verification.consumed_at<=v_assertion.verified_at
        AND verification.issued_at<=verification.verified_at
        AND verification.expires_at>p_evaluated_at
        AND verification.proof_digest IS NOT NULL
        AND endpoint.id=v_assertion.communication_endpoint_id
        AND endpoint.version=v_assertion.communication_endpoint_version
        AND endpoint.endpoint_digest=v_assertion.communication_endpoint_digest
        AND endpoint.channel='SMTP_EMAIL' AND endpoint.state='ACTIVE'
        AND endpoint.revoked_at IS NULL AND endpoint.verified_at IS NOT NULL
        AND subject.id=v_assertion.communication_subject_id
        AND subject.origin_binding_digest=
          v_assertion.communication_subject_origin_digest
        AND subject.profile_version=
          v_assertion.communication_subject_profile_version
        AND subject.profile_digest=
          v_assertion.communication_subject_profile_digest
        AND subject.status='ACTIVE' AND subject.revoked_at IS NULL
        AND subject.origin_object_type='RESPONSE_REQUEST'
        AND subject.origin_object_id=p_response_request_id
        AND current_link.state='ACTIVE'
        AND current_link.change_kind IN ('VERIFIED','SUPPRESSION_RELEASED')
        AND NOT EXISTS(
          SELECT 1 FROM intake.communication_endpoint_link_events AS later
          WHERE later.endpoint_id=current_link.endpoint_id
            AND later.endpoint_sequence>current_link.endpoint_sequence
        )
      FOR SHARE OF verification,endpoint,subject,current_link,sent
    ) THEN
      RAISE EXCEPTION 'official_channel_email_not_current'
        USING ERRCODE='23514';
    END IF;
  ELSE
    IF NOT EXISTS(
      SELECT 1
      FROM editorial.evidence AS evidence
      JOIN raw.source_documents AS document
        ON document.id=evidence.source_document_id
      WHERE evidence.id=v_assertion.official_document_evidence_id
        AND evidence.case_id=p_case_id
        AND evidence.version=v_assertion.official_document_evidence_version
        AND evidence.content_sha256=
          v_assertion.official_document_content_sha256
        AND v_assertion.underlying_source_proof_digest=
          v_assertion.official_document_content_sha256
        AND encode(extensions.digest(convert_to(
          evidence.source_locator,'UTF8'
        ),'sha256'),'hex')=v_assertion.official_document_locator_sha256
        AND evidence.verification_status='VERIFIED'
        AND evidence.verified_by IS NOT NULL
        AND evidence.verified_at IS NOT NULL
        AND evidence.verified_at<=v_assertion.verified_at
        AND evidence.classification='PUBLIC'
        AND evidence.source_document_id=
          v_assertion.official_document_source_document_id
        AND NULLIF(btrim(evidence.source_locator),'') IS NOT NULL
        AND document.content_sha256=
          v_assertion.official_document_source_document_sha256
        AND document.status IN ('FETCHED','PARSED')
        AND document.record_status='CURRENT'
      FOR SHARE OF evidence,document
    ) THEN
      RAISE EXCEPTION 'official_channel_document_not_current'
        USING ERRCODE='23514';
    END IF;
  END IF;

  -- No raw address, domain, document bytes, locator or proof leaves this owner.
  RETURN jsonb_build_object(
    'assertionId',v_assertion.assertion_id,
    'assertionDigest',v_assertion.assertion_digest,
    'verificationMethod',v_assertion.verification_method,
    'sourcePurpose',v_assertion.source_purpose,
    'communicationSubjectId',v_assertion.communication_subject_id,
    'communicationEndpointId',v_assertion.communication_endpoint_id,
    'communicationVerificationId',v_assertion.communication_verification_id,
    'officialDocumentEvidenceId',v_assertion.official_document_evidence_id,
    'underlyingSourceProofDigest',v_assertion.underlying_source_proof_digest,
    'organizationAuthorityReceiptKind',
      v_assertion.organization_authority_receipt_kind,
    'organizationAuthorityReceiptDigest',
      v_assertion.organization_authority_receipt_digest,
    'organizationSourceBindingDigest',
      v_assertion.organization_source_binding_digest,
    'registryReceiptDigest',v_assertion.receipt_digest,
    'verifiedAt',v_assertion.verified_at,'expiresAt',v_assertion.expires_at
  );
END
$$;
ALTER FUNCTION editorial.require_current_official_channel_v1(
  uuid,text,uuid,uuid,uuid,uuid,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.require_current_official_channel_v1(
  uuid,text,uuid,uuid,uuid,uuid,timestamptz
) FROM PUBLIC;

-- The public request's officialChannelSourceId is the registry assertion ID,
-- never a communication-verification/evidence ID.  This replacement removes
-- the stale parallel-world lookup and binds the response receipt to the exact
-- current registry receipt returned by the owner-only validator.
CREATE OR REPLACE FUNCTION editorial.verify_response_organization_identity_v1(
  p_payload jsonb,
  p_actor_id uuid,
  p_request_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,intake,core,ops,extensions,pg_temp
AS $$
DECLARE
  v_response editorial.responses%ROWTYPE;
  v_request editorial.response_requests%ROWTYPE;
  v_existing editorial.response_organization_identity_assertions_v1%ROWTYPE;
  v_assertion_id uuid:=gen_random_uuid();
  v_publication_receipt_id uuid:=gen_random_uuid();
  v_method text:=p_payload->>'verificationMethod';
  v_form text:=p_payload->>'publicationForm';
  v_source_id uuid:=NULLIF(p_payload->>'officialChannelSourceId','')::uuid;
  v_organization_id uuid:=NULLIF(p_payload->>'organizationId','')::uuid;
  v_expected_version bigint:=NULLIF(p_payload->>'expectedVersion','')::bigint;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_actor_jti uuid:=NULLIF(p_payload->>'_actorAssertionJti','')::uuid;
  v_step_up_id uuid:=NULLIF(p_payload->>'_actorStepUpAuthorizationId','')::uuid;
  v_actor_action_digest char(64):=
    NULLIF(p_payload->>'_actorActionDigest','')::char(64);
  v_actor_idempotency char(64):=
    NULLIF(p_payload->>'_actorIdempotencyKeySha256','')::char(64);
  v_actor_request_key char(64):=
    NULLIF(p_payload->>'_actorRequestKeySha256','')::char(64);
  v_step_up_receipt_canonical bytea;
  v_step_up_receipt_digest char(64);
  v_registry jsonb;
  v_communication_subject_id uuid;
  v_communication_endpoint_id uuid;
  v_communication_verification_id uuid;
  v_document_evidence_id uuid;
  v_source_receipt_digest char(64);
  v_subject_binding_digest char(64);
  v_evidence_set_digest char(64);
  v_policy_digest char(64):=encode(extensions.digest(convert_to(
    'r6d-response-organization-identity-v1','UTF8'
  ),'sha256'),'hex');
  v_reason_digest char(64);
  v_assertion_payload jsonb;
  v_assertion_canonical bytea;
  v_assertion_digest char(64);
  v_publication_payload jsonb;
  v_publication_canonical bytea;
  v_publication_digest char(64);
  v_audit uuid;
  v_audit_digest char(64);
  v_outbox uuid;
  v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_payload))<>14
     OR NOT p_payload ?& ARRAY[
       'responseId','organizationId','publicationForm','verificationMethod',
       'officialChannelSourceId','reason','expectedVersion',
       '_actorAssertionJti','_actorAssuranceLevel',
       '_actorEffectiveCapability','_actorActionDigest',
       '_actorStepUpAuthorizationId','_actorIdempotencyKeySha256',
       '_actorRequestKeySha256'
     ]
     OR v_method NOT IN ('OFFICIAL_DOMAIN_EMAIL','OFFICIAL_DOCUMENT')
     OR v_form NOT IN ('FULL','REDACTED')
     OR p_payload->>'_actorAssuranceLevel'<>'STEP_UP'
     OR p_payload->>'_actorEffectiveCapability'<>'responses.review'
     OR v_source_id IS NULL OR v_organization_id IS NULL
     OR v_expected_version<1 OR p_actor_id IS NULL OR p_request_id IS NULL
     OR v_actor_jti IS NULL OR v_step_up_id IS NULL
     OR NOT ops.r6d_lower_sha256(v_actor_action_digest)
     OR NOT ops.r6d_lower_sha256(v_actor_idempotency)
     OR v_actor_idempotency<>p_idempotency_key
     OR v_actor_request_key<>p_idempotency_key
     OR NOT ops.r6d_lower_sha256(p_idempotency_key)
     OR NOT ops.r6d_lower_sha256(p_request_digest)
     OR length(btrim(p_payload->>'reason')) NOT BETWEEN 1 AND 4000 THEN
    RAISE EXCEPTION 'response_identity_request_invalid' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_existing
  FROM editorial.response_organization_identity_assertions_v1
  WHERE idempotency_key_sha256=p_idempotency_key FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest<>p_request_digest THEN
      RAISE EXCEPTION 'response_identity_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN jsonb_build_object(
      'assertionId',v_existing.assertion_id,
      'assertionVersion',v_existing.assertion_version,
      'responseVersion',v_existing.response_version,
      'receiptDigest',v_existing.receipt_digest,
      'auditEventId',v_existing.audit_event_id,
      'verifiedAt',v_existing.verified_at,
      'outboxEventIds',jsonb_build_array(v_existing.outbox_event_id),
      'replayed',true
    );
  END IF;

  SELECT * INTO v_response FROM editorial.responses
  WHERE id=(p_payload->>'responseId')::uuid AND version=v_expected_version
  FOR UPDATE;
  IF NOT FOUND OR v_response.organization_identity_status<>'UNVERIFIED'
     OR v_response.publication_form<>'INTERNAL_ONLY'
     OR v_response.response_request_id IS NULL OR v_response.submission_id IS NULL
     OR v_response.party_type NOT IN ('AGENCY','SUPPLIER')
     OR v_response.party_entity_id IS NULL
     OR v_response.party_entity_id<>v_organization_id
     OR v_response.response_content_sha256 IS NULL
     OR v_response.publication_consent_sha256 IS NULL THEN
    RAISE EXCEPTION 'response_identity_scope_or_version_invalid'
      USING ERRCODE='40001';
  END IF;

  SELECT * INTO STRICT v_request FROM editorial.response_requests
  WHERE id=v_response.response_request_id AND party_type=v_response.party_type
    AND party_entity_id=v_organization_id FOR SHARE;
  IF (v_response.party_type='AGENCY' AND NOT EXISTS(
        SELECT 1 FROM core.agencies WHERE id=v_organization_id
      )) OR (v_response.party_type='SUPPLIER' AND NOT EXISTS(
        SELECT 1 FROM core.suppliers WHERE id=v_organization_id
      )) THEN
    RAISE EXCEPTION 'response_identity_organization_missing'
      USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_step_up FROM ops.step_up_authorizations
  WHERE id=v_step_up_id AND closed_at IS NULL FOR SHARE;
  IF NOT FOUND OR v_step_up.expires_at<=v_now
     OR v_step_up.action_digest<>v_actor_action_digest
     OR v_step_up.idempotency_key_sha256<>v_actor_idempotency
     OR v_step_up.assertion_issue_count NOT BETWEEN 1 AND 3
     OR v_step_up.last_issued_at IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM ops.sessions AS session
       WHERE session.id=v_step_up.session_id AND session.user_id=p_actor_id
         AND session.revoked_at IS NULL AND session.expires_at>v_now
     ) THEN
    RAISE EXCEPTION 'response_identity_step_up_invalid' USING ERRCODE='42501';
  END IF;
  v_step_up_receipt_canonical:=ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion','step-up-authorization-receipt.v1',
    'authorizationId',v_step_up.id,'actionDigest',v_step_up.action_digest,
    'sessionId',v_step_up.session_id,
    'issueNumber',v_step_up.assertion_issue_count,
    'issuedAt',v_step_up.last_issued_at,'expiresAt',v_step_up.expires_at
  ));
  v_step_up_receipt_digest:=encode(
    extensions.digest(v_step_up_receipt_canonical,'sha256'),'hex'
  );

  v_registry:=editorial.require_current_official_channel_v1(
    v_source_id,v_request.party_type,v_organization_id,v_request.id,
    v_response.case_id,p_actor_id,v_now
  );
  IF v_registry->>'verificationMethod'<>v_method
     OR NULLIF(v_registry->>'registryReceiptDigest','') IS NULL
     OR NOT ops.r6d_lower_sha256(v_registry->>'registryReceiptDigest') THEN
    RAISE EXCEPTION 'response_identity_official_channel_mismatch'
      USING ERRCODE='23514';
  END IF;
  v_source_receipt_digest:=(v_registry->>'registryReceiptDigest')::char(64);
  IF v_method='OFFICIAL_DOMAIN_EMAIL' THEN
    v_communication_subject_id:=
      NULLIF(v_registry->>'communicationSubjectId','')::uuid;
    v_communication_endpoint_id:=
      NULLIF(v_registry->>'communicationEndpointId','')::uuid;
    v_communication_verification_id:=
      NULLIF(v_registry->>'communicationVerificationId','')::uuid;
    IF num_nonnulls(
      v_communication_subject_id,v_communication_endpoint_id,
      v_communication_verification_id
    )<>3 OR v_registry->>'officialDocumentEvidenceId' IS NOT NULL THEN
      RAISE EXCEPTION 'response_identity_official_email_binding_invalid'
        USING ERRCODE='23514';
    END IF;
  ELSE
    v_document_evidence_id:=
      NULLIF(v_registry->>'officialDocumentEvidenceId','')::uuid;
    IF v_document_evidence_id IS NULL
       OR num_nonnulls(
         NULLIF(v_registry->>'communicationSubjectId',''),
         NULLIF(v_registry->>'communicationEndpointId',''),
         NULLIF(v_registry->>'communicationVerificationId','')
       )<>0 THEN
      RAISE EXCEPTION 'response_identity_official_document_binding_invalid'
        USING ERRCODE='23514';
    END IF;
  END IF;

  v_subject_binding_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'responseId',v_response.id,'responseRequestId',v_request.id,
      'submissionId',v_response.submission_id,
      'organizationKind',v_request.party_type,
      'organizationId',v_organization_id,
      'responseVersion',v_expected_version+1,
      'responseContentSha256',v_response.response_content_sha256,
      'publicationConsentSha256',v_response.publication_consent_sha256,
      'publicationForm',v_form
    )
  ),'sha256'),'hex');
  v_evidence_set_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'verificationMethod',v_method,'officialChannelSourceId',v_source_id,
      'officialChannelAssertionDigest',v_registry->>'assertionDigest',
      'organizationSourceBindingDigest',
        v_registry->>'organizationSourceBindingDigest',
      'underlyingSourceProofDigest',
        v_registry->>'underlyingSourceProofDigest',
      'sourceVerificationReceiptDigest',v_source_receipt_digest,
      'stepUpAuthorizationReceiptDigest',v_step_up_receipt_digest
    )
  ),'sha256'),'hex');
  v_reason_digest:=encode(extensions.digest(convert_to(
    p_payload->>'reason','UTF8'
  ),'sha256'),'hex');

  v_assertion_payload:=jsonb_build_object(
    'schemaVersion','response-organization-identity-assertion.v1',
    'assertionId',v_assertion_id,'responseId',v_response.id,
    'responseRequestId',v_request.id,
    'responseSubmissionId',v_response.submission_id,
    'responseVersion',v_expected_version+1,
    'responseContentSha256',v_response.response_content_sha256,
    'publicationConsentSha256',v_response.publication_consent_sha256,
    'organizationKind',v_request.party_type,'organizationId',v_organization_id,
    'publicationForm',v_form,'identityStatus','SECOND_FACTOR_VERIFIED',
    'verificationMethod',v_method,'officialChannelSourceId',v_source_id,
    'sourceVerificationReceiptDigest',v_source_receipt_digest,
    'subjectBindingDigest',v_subject_binding_digest,
    'evidenceSetDigest',v_evidence_set_digest,'policyDigest',v_policy_digest,
    'assertionVersion',1,'verifiedAt',v_now
  );
  v_assertion_canonical:=ops.canonical_jsonb_v1(v_assertion_payload);
  v_assertion_digest:=encode(
    extensions.digest(v_assertion_canonical,'sha256'),'hex'
  );
  v_audit:=ops.append_audit_event(
    'response-identity:'||v_response.id::text,'USER',p_actor_id::text,
    v_step_up.session_id,'response.organization_identity.verify',
    'EditorialResponse',v_response.id::text,'responses.review','SUCCESS',NULL,
    p_request_id,jsonb_build_object(
      'assertionDigest',v_assertion_digest,
      'officialChannelSourceId',v_source_id,
      'sourceVerificationReceiptDigest',v_source_receipt_digest
    )
  );
  SELECT event_hash INTO STRICT v_audit_digest
  FROM ops.audit_events WHERE id=v_audit;

  v_publication_payload:=jsonb_build_object(
    'schemaVersion','response-publication-identity-receipt.v1',
    'receiptId',v_publication_receipt_id,'assertionId',v_assertion_id,
    'responseId',v_response.id,'responseVersion',v_expected_version+1,
    'responseContentSha256',v_response.response_content_sha256,
    'publicationConsentSha256',v_response.publication_consent_sha256,
    'organizationId',v_organization_id,'publicationForm',v_form,
    'identityStatus','SECOND_FACTOR_VERIFIED',
    'assertionDigest',v_assertion_digest,
    'sourceVerificationReceiptDigest',v_source_receipt_digest,
    'active',true,'createdAt',v_now
  );
  v_publication_canonical:=ops.canonical_jsonb_v1(v_publication_payload);
  v_publication_digest:=encode(
    extensions.digest(v_publication_canonical,'sha256'),'hex'
  );
  v_outbox:=ops.enqueue_outbox(
    'editorial_response',v_response.id::text,v_expected_version+1,
    'response.organization_identity_verified.v1',
    jsonb_build_object(
      'responseId',v_response.id,'responseVersion',v_expected_version+1,
      'responseContentSha256',v_response.response_content_sha256,
      'organizationId',v_organization_id,'publicationForm',v_form,
      'identityStatus','SECOND_FACTOR_VERIFIED','verificationMethod',v_method,
      'identityAssertionId',v_assertion_id,'identityAssertionVersion',1,
      'identityAssertionDigest',v_assertion_digest,
      'sourceVerificationReceiptDigest',v_source_receipt_digest,
      'auditReceiptDigest',v_audit_digest,'verifiedAt',v_now
    ),v_now
  );

  INSERT INTO editorial.response_organization_identity_assertions_v1(
    assertion_id,response_id,response_request_id,response_submission_id,
    response_version,response_content_sha256,publication_consent_sha256,
    organization_kind,organization_id,publication_form,identity_status,
    verification_method,official_channel_source_id,communication_subject_id,
    communication_endpoint_id,communication_verification_id,
    official_document_evidence_id,source_verification_receipt_digest,
    subject_binding_digest,evidence_set_digest,policy_digest,assertion_version,
    reason_digest,actor_assertion_jti,step_up_authorization_id,
    step_up_authorization_receipt_digest,actor_id,request_id,
    idempotency_key_sha256,request_digest,audit_event_id,audit_receipt_digest,
    outbox_event_id,assertion_payload,assertion_canonical,assertion_digest,
    receipt_digest,verified_at
  ) VALUES(
    v_assertion_id,v_response.id,v_request.id,v_response.submission_id,
    v_expected_version+1,v_response.response_content_sha256,
    v_response.publication_consent_sha256,v_request.party_type,v_organization_id,
    v_form,'SECOND_FACTOR_VERIFIED',v_method,v_source_id,
    v_communication_subject_id,v_communication_endpoint_id,
    v_communication_verification_id,v_document_evidence_id,
    v_source_receipt_digest,v_subject_binding_digest,v_evidence_set_digest,
    v_policy_digest,1,v_reason_digest,v_actor_jti,v_step_up.id,
    v_step_up_receipt_digest,p_actor_id,p_request_id,p_idempotency_key,
    p_request_digest,v_audit,v_audit_digest,v_outbox,v_assertion_payload,
    v_assertion_canonical,v_assertion_digest,v_publication_digest,v_now
  );
  INSERT INTO editorial.response_publication_identity_receipts_v1(
    receipt_id,assertion_id,response_id,response_version,
    response_content_sha256,publication_consent_sha256,organization_id,
    publication_form,identity_status,assertion_digest,
    source_verification_receipt_digest,active,receipt_payload,
    receipt_canonical,receipt_digest,created_at
  ) VALUES(
    v_publication_receipt_id,v_assertion_id,v_response.id,v_expected_version+1,
    v_response.response_content_sha256,v_response.publication_consent_sha256,
    v_organization_id,v_form,'SECOND_FACTOR_VERIFIED',v_assertion_digest,
    v_source_receipt_digest,true,v_publication_payload,
    v_publication_canonical,v_publication_digest,v_now
  );
  PERFORM set_config('gurine.response_identity_transition','1',true);
  UPDATE editorial.responses
  SET organization_identity_status='SECOND_FACTOR_VERIFIED',
      publication_form=v_form,organization_identity_assertion_id=v_assertion_id,
      verified_at=v_now,verified_by=p_actor_id,version=version+1,updated_at=v_now
  WHERE id=v_response.id AND version=v_expected_version;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'response_identity_version_conflict' USING ERRCODE='40001';
  END IF;
  RETURN jsonb_build_object(
    'assertionId',v_assertion_id,'assertionVersion',1,
    'responseVersion',v_expected_version+1,'receiptDigest',v_publication_digest,
    'auditEventId',v_audit,'verifiedAt',v_now,
    'outboxEventIds',jsonb_build_array(v_outbox),'replayed',false
  );
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'response_identity_authority_missing_or_ambiguous'
    USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.verify_response_organization_identity_v1(
  jsonb,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.verify_response_organization_identity_v1(
  jsonb,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.verify_response_organization_identity_v1(
  jsonb,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- Receipt-time guard.  It is deliberately a BEFORE INSERT trigger so every
-- owner path, not only the current PL/pgSQL implementation, revalidates the
-- exact response/assertion/registry receipt under the same transaction.
CREATE OR REPLACE FUNCTION editorial.guard_response_excerpt_identity_source_v2()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,editorial,intake,core,raw,ops,extensions,pg_temp
AS $$
DECLARE
  v_response editorial.responses%ROWTYPE;
  v_identity editorial.response_publication_identity_receipts_v1%ROWTYPE;
  v_assertion editorial.response_organization_identity_assertions_v1%ROWTYPE;
  v_registry jsonb;
  v_expected_assertion_payload jsonb;
  v_expected_identity_payload jsonb;
BEGIN
  SELECT * INTO STRICT v_response
  FROM editorial.responses
  WHERE id=NEW.response_id AND version=NEW.prior_response_version
  FOR SHARE;
  IF v_response.public_excerpt IS NULL
     OR encode(extensions.digest(
       convert_to(v_response.public_excerpt,'UTF8'),'sha256'
     ),'hex')<>NEW.excerpt_sha256
     OR v_response.response_content_sha256<>NEW.response_content_sha256
     OR v_response.publication_consent_sha256<>NEW.publication_consent_sha256
     OR COALESCE((v_response.publication_consent->>'bodyConsent')::boolean,false)
       IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'response_excerpt_guard_scope_mismatch'
      USING ERRCODE='23514';
  END IF;

  IF NEW.publication_form='ANONYMOUS' THEN
    IF NEW.identity_receipt_id IS NOT NULL
       OR NEW.identity_receipt_digest IS NOT NULL
       OR v_response.publication_consent->>'identityDisplay'<>'ANONYMOUS' THEN
      RAISE EXCEPTION 'response_excerpt_anonymous_identity_mismatch'
        USING ERRCODE='23514';
    END IF;
    RETURN NEW;
  END IF;

  SELECT * INTO STRICT v_identity
  FROM editorial.response_publication_identity_receipts_v1
  WHERE receipt_id=NEW.identity_receipt_id
    AND receipt_digest=NEW.identity_receipt_digest
    AND response_id=NEW.response_id
    AND response_version=NEW.prior_response_version
    AND response_content_sha256=NEW.response_content_sha256
    AND publication_consent_sha256=NEW.publication_consent_sha256
    AND organization_id=v_response.party_entity_id
    AND publication_form=NEW.publication_form
    AND identity_status='SECOND_FACTOR_VERIFIED'
    AND active
  FOR SHARE;
  SELECT * INTO STRICT v_assertion
  FROM editorial.response_organization_identity_assertions_v1
  WHERE assertion_id=v_identity.assertion_id
    AND response_id=v_identity.response_id
    AND response_version=v_identity.response_version
    AND response_content_sha256=v_identity.response_content_sha256
    AND publication_consent_sha256=v_identity.publication_consent_sha256
    AND organization_id=v_identity.organization_id
    AND publication_form=v_identity.publication_form
    AND identity_status=v_identity.identity_status
    AND assertion_digest=v_identity.assertion_digest
    AND source_verification_receipt_digest=
      v_identity.source_verification_receipt_digest
  FOR SHARE;
  IF v_response.organization_identity_status<>'SECOND_FACTOR_VERIFIED'
     OR v_response.publication_form<>NEW.publication_form
     OR v_response.organization_identity_assertion_id<>v_assertion.assertion_id
     OR v_assertion.receipt_digest<>v_identity.receipt_digest THEN
    RAISE EXCEPTION 'response_excerpt_identity_binding_mismatch'
      USING ERRCODE='23514';
  END IF;

  v_expected_assertion_payload:=jsonb_build_object(
    'schemaVersion','response-organization-identity-assertion.v1',
    'assertionId',v_assertion.assertion_id,
    'responseId',v_assertion.response_id,
    'responseRequestId',v_assertion.response_request_id,
    'responseSubmissionId',v_assertion.response_submission_id,
    'responseVersion',v_assertion.response_version,
    'responseContentSha256',v_assertion.response_content_sha256,
    'publicationConsentSha256',v_assertion.publication_consent_sha256,
    'organizationKind',v_assertion.organization_kind,
    'organizationId',v_assertion.organization_id,
    'publicationForm',v_assertion.publication_form,
    'identityStatus',v_assertion.identity_status,
    'verificationMethod',v_assertion.verification_method,
    'officialChannelSourceId',v_assertion.official_channel_source_id,
    'sourceVerificationReceiptDigest',
      v_assertion.source_verification_receipt_digest,
    'subjectBindingDigest',v_assertion.subject_binding_digest,
    'evidenceSetDigest',v_assertion.evidence_set_digest,
    'policyDigest',v_assertion.policy_digest,
    'assertionVersion',v_assertion.assertion_version,
    'verifiedAt',v_assertion.verified_at
  );
  v_expected_identity_payload:=jsonb_build_object(
    'schemaVersion','response-publication-identity-receipt.v1',
    'receiptId',v_identity.receipt_id,
    'assertionId',v_identity.assertion_id,
    'responseId',v_identity.response_id,
    'responseVersion',v_identity.response_version,
    'responseContentSha256',v_identity.response_content_sha256,
    'publicationConsentSha256',v_identity.publication_consent_sha256,
    'organizationId',v_identity.organization_id,
    'publicationForm',v_identity.publication_form,
    'identityStatus',v_identity.identity_status,
    'assertionDigest',v_identity.assertion_digest,
    'sourceVerificationReceiptDigest',
      v_identity.source_verification_receipt_digest,
    'active',v_identity.active,'createdAt',v_identity.created_at
  );
  IF v_assertion.assertion_payload<>v_expected_assertion_payload
     OR v_assertion.assertion_canonical<>
       ops.canonical_jsonb_v1(v_expected_assertion_payload)
     OR v_identity.receipt_payload<>v_expected_identity_payload
     OR v_identity.receipt_canonical<>
       ops.canonical_jsonb_v1(v_expected_identity_payload) THEN
    RAISE EXCEPTION 'response_excerpt_identity_receipt_mismatch'
      USING ERRCODE='23514';
  END IF;

  v_registry:=editorial.require_current_official_channel_v1(
    v_assertion.official_channel_source_id,v_assertion.organization_kind,
    v_assertion.organization_id,v_assertion.response_request_id,
    v_response.case_id,v_assertion.actor_id,NEW.approved_at
  );
  IF v_registry->>'verificationMethod'<>v_assertion.verification_method
     OR v_registry->>'registryReceiptDigest'<>
       btrim(v_assertion.source_verification_receipt_digest)
     OR (v_assertion.verification_method='OFFICIAL_DOMAIN_EMAIL' AND ROW(
       NULLIF(v_registry->>'communicationSubjectId','')::uuid,
       NULLIF(v_registry->>'communicationEndpointId','')::uuid,
       NULLIF(v_registry->>'communicationVerificationId','')::uuid
     ) IS DISTINCT FROM ROW(
       v_assertion.communication_subject_id,
       v_assertion.communication_endpoint_id,
       v_assertion.communication_verification_id
     ))
     OR (v_assertion.verification_method='OFFICIAL_DOCUMENT'
       AND NULLIF(v_registry->>'officialDocumentEvidenceId','')::uuid
         IS DISTINCT FROM v_assertion.official_document_evidence_id) THEN
    RAISE EXCEPTION 'response_excerpt_official_channel_receipt_mismatch'
      USING ERRCODE='23514';
  END IF;
  RETURN NEW;
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'response_excerpt_identity_authority_missing_or_ambiguous'
    USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.guard_response_excerpt_identity_source_v2()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.guard_response_excerpt_identity_source_v2()
  FROM PUBLIC;
CREATE TRIGGER response_excerpt_identity_source_v2_guard
  BEFORE INSERT ON editorial.response_excerpt_approval_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION editorial.guard_response_excerpt_identity_source_v2();

-- The existing owner does not change public_excerpt; it approves the exact
-- pre-existing bytes.  This assertion prevents a future trigger edit from
-- accidentally leaving a public_excerpt-only UPDATE outside the DB guard.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger AS trigger
    JOIN pg_class AS relation ON relation.oid=trigger.tgrelid
    JOIN pg_namespace AS namespace ON namespace.oid=relation.relnamespace
    WHERE namespace.nspname='editorial'
      AND relation.relname='responses'
      AND trigger.tgname='editorial_responses_excerpt_approval_v2_guard'
      AND NOT trigger.tgisinternal
      AND pg_get_triggerdef(trigger.oid) LIKE '%UPDATE OF public_excerpt%'
  ) THEN
    RAISE EXCEPTION 'response_public_excerpt_update_guard_missing'
      USING ERRCODE='55000';
  END IF;
END
$$;

-- R6d publication owner fragment begins.
-- Mirrors crates/publication-policy's length-prefixed SHA-256 receipt
-- preimage exactly. PostgreSQL int8send is signed, big-endian; all byte
-- lengths here are positive and therefore byte-identical to Rust u64 BE.
CREATE OR REPLACE FUNCTION editorial.named_person_legal_override_digest_v1(
  p_public_text_sha256 text,
  p_ruleset_version text,
  p_reason_code text,
  p_official_source_locator text,
  p_official_source_sha256 text,
  p_legal_reviewer_id text
) RETURNS char(64)
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,extensions,pg_temp
AS $$
  SELECT encode(extensions.digest(
    int8send(octet_length('named-individual-legal-override-v1')::bigint)
      ||convert_to('named-individual-legal-override-v1','UTF8')
      ||int8send(octet_length(p_public_text_sha256)::bigint)
      ||convert_to(p_public_text_sha256,'UTF8')
      ||int8send(octet_length(p_ruleset_version)::bigint)
      ||convert_to(p_ruleset_version,'UTF8')
      ||int8send(octet_length(p_reason_code)::bigint)
      ||convert_to(p_reason_code,'UTF8')
      ||int8send(octet_length(p_official_source_locator)::bigint)
      ||convert_to(p_official_source_locator,'UTF8')
      ||int8send(octet_length(p_official_source_sha256)::bigint)
      ||convert_to(p_official_source_sha256,'UTF8')
      ||int8send(octet_length(p_legal_reviewer_id)::bigint)
      ||convert_to(p_legal_reviewer_id,'UTF8'),
    'sha256'
  ),'hex')::char(64)
$$;
ALTER FUNCTION editorial.named_person_legal_override_digest_v1(
  text,text,text,text,text,text
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.named_person_legal_override_digest_v1(
  text,text,text,text,text,text
) FROM PUBLIC;

-- Bind review authority to the exact current role grants.  Receipt payloads
-- retain only this digest, never a reviewer identity or role-grant row.
CREATE OR REPLACE FUNCTION ops.r6d_user_capability_authority_digest_v1(
  p_user_id uuid,
  p_required_role text,
  p_required_capability text
) RETURNS char(64)
LANGUAGE sql STABLE STRICT SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
  WITH authority AS (
    SELECT jsonb_build_object(
      'grantId',user_role.id,
      'grantedAt',user_role.granted_at,
      'expiresAt',user_role.expires_at,
      'roleId',role.id,
      'roleCode',role.code,
      'roleVersion',role.version,
      'capabilityCode',role_capability.capability_code
    ) AS item
    FROM ops.users AS app_user
    JOIN ops.user_roles AS user_role
      ON user_role.user_id=app_user.id
      AND user_role.revoked_at IS NULL
      AND (
        user_role.expires_at IS NULL
        OR user_role.expires_at>clock_timestamp()
      )
    JOIN ops.roles AS role
      ON role.id=user_role.role_id AND role.code=p_required_role
    JOIN ops.role_capabilities AS role_capability
      ON role_capability.role_id=role.id
      AND role_capability.capability_code=p_required_capability
    WHERE app_user.id=p_user_id AND app_user.status='ACTIVE'
  ), authority_set AS (
    SELECT count(*) AS item_count,
      COALESCE(
        jsonb_agg(item ORDER BY ops.canonical_jsonb_v1(item)),
        '[]'::jsonb
      ) AS items
    FROM authority
  )
  SELECT CASE WHEN item_count=0 THEN NULL ELSE encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','user-role-capability-authority.v1',
      'userId',p_user_id,
      'requiredRole',p_required_role,
      'requiredCapability',p_required_capability,
      'authorities',items
    )),'sha256'
  ),'hex')::char(64) END
  FROM authority_set
$$;
ALTER FUNCTION ops.r6d_user_capability_authority_digest_v1(
  uuid,text,text
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_user_capability_authority_digest_v1(
  uuid,text,text
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.review_decision_digest_v1(
  p_decision_id uuid
) RETURNS char(64)
LANGUAGE sql STABLE STRICT SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp
AS $$
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'decisionId',decision.id,
      'reviewSnapshotId',decision.review_snapshot_id,
      'reviewerId',decision.reviewer_id,
      'decision',decision.decision,
      'reasonSha256',encode(extensions.digest(
        convert_to(decision.reason,'UTF8'),'sha256'
      ),'hex'),
      'criteriaSha256',encode(extensions.digest(
        ops.canonical_jsonb_v1(decision.criteria),'sha256'
      ),'hex'),
      'reviewerIndependenceSha256',encode(extensions.digest(
        ops.canonical_jsonb_v1(decision.reviewer_independence),'sha256'
      ),'hex'),
      'reauthContextHash',btrim(decision.reauth_context_hash),
      'createdAt',decision.created_at
    )
  ),'sha256'),'hex')::char(64)
  FROM editorial.review_decisions AS decision
  WHERE decision.id=p_decision_id
$$;
ALTER FUNCTION editorial.review_decision_digest_v1(uuid)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.review_decision_digest_v1(uuid) FROM PUBLIC;

CREATE TABLE editorial.named_person_review_stage_receipts_v1 (
  receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  decision_id uuid NOT NULL UNIQUE
    REFERENCES editorial.review_decisions(id) ON DELETE RESTRICT,
  review_snapshot_id uuid NOT NULL
    REFERENCES editorial.review_snapshots(id) ON DELETE RESTRICT,
  case_id uuid NOT NULL REFERENCES editorial.cases(id) ON DELETE RESTRICT,
  case_version bigint NOT NULL,
  review_assignment_id uuid NOT NULL
    REFERENCES editorial.review_assignments(id) ON DELETE RESTRICT,
  review_assignment_version_before bigint NOT NULL,
  review_assignment_version_after bigint NOT NULL,
  review_task_id uuid REFERENCES ops.tasks(id) ON DELETE RESTRICT,
  review_task_version_before bigint,
  review_task_version_after bigint,
  review_stage text NOT NULL,
  decision text NOT NULL,
  reviewer_user_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  reviewer_authority_digest char(64) NOT NULL,
  actor_assertion_jti uuid NOT NULL UNIQUE,
  actor_action_digest char(64) NOT NULL,
  assurance_level text NOT NULL,
  effective_capability text NOT NULL,
  step_up_authorization_id uuid
    REFERENCES ops.step_up_authorizations(id) ON DELETE RESTRICT,
  step_up_receipt_digest char(64),
  decision_digest char(64) NOT NULL,
  referenced_editorial_decision_id uuid
    REFERENCES editorial.review_decisions(id) ON DELETE RESTRICT,
  referenced_editorial_stage_receipt_id uuid
    REFERENCES editorial.named_person_review_stage_receipts_v1(receipt_id)
    ON DELETE RESTRICT,
  referenced_editorial_stage_receipt_digest char(64),
  named_person_override_id uuid
    REFERENCES editorial.named_person_legal_overrides(override_id)
    ON DELETE RESTRICT,
  named_person_override_digest char(64),
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  outbox_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  outbox_event_type text NOT NULL,
  outbox_event_digest char(64) NOT NULL,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL,
  CONSTRAINT named_person_review_stage_receipts_v1_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(
    id,record_class,schedule_digest
  ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT named_person_review_stage_receipts_v1_class_fk
    FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  CONSTRAINT named_person_review_stage_receipts_v1_shape_ck CHECK (
    case_version>0
    AND review_assignment_version_before>0
    AND review_assignment_version_after=review_assignment_version_before+1
    AND (
      num_nonnulls(
        review_task_id,review_task_version_before,review_task_version_after
      )=0 OR (
        num_nonnulls(
          review_task_id,review_task_version_before,review_task_version_after
        )=3
        AND review_task_version_before>0
        AND review_task_version_after=review_task_version_before+1
      )
    )
    AND review_stage IN ('EDITORIAL','LEGAL')
    AND decision IN ('APPROVE','REJECT','CHANGES_REQUIRED')
    AND ops.r6d_lower_sha256(reviewer_authority_digest)
    AND ops.r6d_lower_sha256(actor_action_digest)
    AND ops.r6d_lower_sha256(decision_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND outbox_event_type='review.decision_submitted.v1'
    AND ops.r6d_lower_sha256(outbox_event_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND retention_record_class='NAMED_PERSON_PUBLICATION_GOVERNANCE'
    AND (
      (
        review_stage='EDITORIAL'
        AND effective_capability='review.editorial'
        AND num_nonnulls(
          referenced_editorial_decision_id,
          referenced_editorial_stage_receipt_id,
          referenced_editorial_stage_receipt_digest,
          named_person_override_id,named_person_override_digest
        )=0
      ) OR (
        review_stage='LEGAL' AND decision='APPROVE'
        AND assurance_level='STEP_UP'
        AND effective_capability='review.legal'
        AND num_nonnulls(
          step_up_authorization_id,step_up_receipt_digest,
          referenced_editorial_decision_id,
          referenced_editorial_stage_receipt_id,
          referenced_editorial_stage_receipt_digest,
          named_person_override_id,named_person_override_digest
        )=7
        AND ops.r6d_lower_sha256(step_up_receipt_digest)
        AND ops.r6d_lower_sha256(referenced_editorial_stage_receipt_digest)
        AND ops.r6d_lower_sha256(named_person_override_digest)
      )
    )
    AND (
      decision<>'APPROVE'
      OR (
        assurance_level='STEP_UP'
        AND step_up_authorization_id IS NOT NULL
        AND ops.r6d_lower_sha256(step_up_receipt_digest)
      )
    )
    AND (
      decision='APPROVE'
      OR (
        assurance_level='ACTIVE_SESSION'
        AND step_up_authorization_id IS NULL
        AND step_up_receipt_digest IS NULL
      )
    )
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(
      extensions.digest(receipt_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE editorial.named_person_review_stage_receipts_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON editorial.named_person_review_stage_receipts_v1 FROM PUBLIC;
GRANT SELECT ON editorial.named_person_review_stage_receipts_v1
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER named_person_review_stage_receipts_v1_immutable_guard
  BEFORE UPDATE OR DELETE ON editorial.named_person_review_stage_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER named_person_review_stage_receipts_v1_retention_bind
  BEFORE INSERT ON editorial.named_person_review_stage_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

ALTER TABLE editorial.named_person_legal_overrides
  ADD CONSTRAINT named_person_legal_overrides_editorial_stage_receipt_fk
  FOREIGN KEY(editorial_review_stage_receipt_id)
  REFERENCES editorial.named_person_review_stage_receipts_v1(receipt_id)
  ON DELETE RESTRICT;

CREATE OR REPLACE FUNCTION editorial.record_named_person_review_stage_v1(
  p_request jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp
AS $$
DECLARE
  v_existing editorial.named_person_review_stage_receipts_v1%ROWTYPE;
  v_snapshot editorial.review_snapshots%ROWTYPE;
  v_assignment editorial.review_assignments%ROWTYPE;
  v_task ops.tasks%ROWTYPE;
  v_first_receipt editorial.named_person_review_stage_receipts_v1%ROWTYPE;
  v_override editorial.named_person_legal_overrides%ROWTYPE;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_decision_id uuid;
  v_snapshot_id uuid;
  v_actor_id uuid;
  v_actor_jti uuid;
  v_step_up_id uuid;
  v_first_decision_id uuid;
  v_request_id uuid;
  v_stage text;
  v_decision text;
  v_reason text;
  v_criteria jsonb;
  v_independence jsonb;
  v_reauth_hash char(64);
  v_capability text;
  v_assurance text;
  v_required_role text;
  v_idempotency char(64);
  v_request_digest char(64);
  v_authority_digest char(64);
  v_decision_digest char(64);
  v_step_up_receipt char(64);
  v_audit uuid;
  v_audit_digest char(64);
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
  v_now timestamptz:=clock_timestamp();
  v_named_override jsonb;
  v_assignment_version_before bigint;
  v_task_version_before bigint;
  v_task_count bigint;
  v_outbox uuid;
  v_outbox_digest char(64);
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_request))<>20
     OR NOT p_request ?& ARRAY[
       'decisionId','reviewSnapshotId','stage','decision','reason','criteria',
       'reviewerIndependence','reauthContextHash',
       'referencedEditorialDecisionId','_actorId','_actorAssertionJti',
       '_actorAssuranceLevel','_actorEffectiveCapability',
       '_actorActionDigest','_actorStepUpAuthorizationId',
       '_actorIdempotencyKeySha256','_actorRequestKeySha256',
       '_requestId','_idempotencyKeySha256','_requestSha256'
     ] THEN
    RAISE EXCEPTION 'named_person_review_stage_request_invalid'
      USING ERRCODE='22023';
  END IF;
  BEGIN
    v_decision_id:=NULLIF(p_request->>'decisionId','')::uuid;
    v_snapshot_id:=NULLIF(p_request->>'reviewSnapshotId','')::uuid;
    v_actor_id:=NULLIF(p_request->>'_actorId','')::uuid;
    v_actor_jti:=NULLIF(p_request->>'_actorAssertionJti','')::uuid;
    v_step_up_id:=NULLIF(
      p_request->>'_actorStepUpAuthorizationId',''
    )::uuid;
    v_first_decision_id:=NULLIF(
      p_request->>'referencedEditorialDecisionId',''
    )::uuid;
    v_request_id:=NULLIF(p_request->>'_requestId','')::uuid;
    v_idempotency:=NULLIF(
      p_request->>'_idempotencyKeySha256',''
    )::char(64);
    v_request_digest:=NULLIF(
      p_request->>'_requestSha256',''
    )::char(64);
    v_reauth_hash:=NULLIF(p_request->>'reauthContextHash','')::char(64);
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'named_person_review_stage_request_invalid'
      USING ERRCODE='22023';
  END;
  v_stage:=NULLIF(p_request->>'stage','');
  v_decision:=NULLIF(p_request->>'decision','');
  v_reason:=NULLIF(btrim(p_request->>'reason'),'');
  v_criteria:=p_request->'criteria';
  v_independence:=p_request->'reviewerIndependence';
  v_capability:=NULLIF(p_request->>'_actorEffectiveCapability','');
  v_assurance:=NULLIF(p_request->>'_actorAssuranceLevel','');
  IF v_decision_id IS NULL OR v_snapshot_id IS NULL OR v_actor_id IS NULL
     OR v_actor_jti IS NULL OR v_request_id IS NULL
     OR v_stage IS NULL OR v_stage NOT IN ('EDITORIAL','LEGAL')
     OR v_decision IS NULL
     OR v_decision NOT IN ('APPROVE','REJECT','CHANGES_REQUIRED')
     OR v_reason IS NULL OR length(v_reason)>4000
     OR v_criteria IS NULL OR jsonb_typeof(v_criteria)<>'object'
     OR v_independence IS NULL OR jsonb_typeof(v_independence)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_independence))<>3
     OR NOT v_independence ?& ARRAY[
       'snapshotCreatedBy','reviewer','independent'
     ]
     OR v_independence->>'independent' IS DISTINCT FROM 'true'
     OR NOT ops.r6d_lower_sha256(v_reauth_hash)
     OR NOT ops.r6d_lower_sha256(p_request->>'_actorActionDigest')
     OR NOT ops.r6d_lower_sha256(v_idempotency)
     OR NOT ops.r6d_lower_sha256(v_request_digest)
     OR p_request->>'_actorRequestKeySha256' IS DISTINCT FROM v_idempotency
     OR p_request->>'_actorIdempotencyKeySha256'
          IS DISTINCT FROM v_idempotency THEN
    RAISE EXCEPTION 'named_person_review_stage_request_invalid'
      USING ERRCODE='22023';
  END IF;
  IF v_stage='EDITORIAL' THEN
    v_required_role:='EDITOR';
    IF v_capability IS DISTINCT FROM 'review.editorial'
       OR v_first_decision_id IS NOT NULL
       OR v_criteria ? 'namedIndividualOverride'
       OR (
         v_decision='APPROVE'
         AND (v_assurance IS DISTINCT FROM 'STEP_UP' OR v_step_up_id IS NULL)
       )
       OR (
         v_decision<>'APPROVE'
         AND (
           v_assurance IS DISTINCT FROM 'ACTIVE_SESSION'
           OR v_step_up_id IS NOT NULL
         )
       ) THEN
      RAISE EXCEPTION 'named_person_editorial_stage_invalid'
        USING ERRCODE='23514';
    END IF;
  ELSE
    v_required_role:='LEGAL_REVIEWER';
    v_named_override:=v_criteria->'namedIndividualOverride';
    IF v_capability IS DISTINCT FROM 'review.legal'
       OR v_decision IS DISTINCT FROM 'APPROVE'
       OR v_assurance IS DISTINCT FROM 'STEP_UP' OR v_step_up_id IS NULL
       OR v_first_decision_id IS NULL
       OR v_named_override IS NULL OR jsonb_typeof(v_named_override)<>'object'
       OR (SELECT count(*) FROM jsonb_object_keys(v_named_override))<>5
       OR NOT v_named_override ?& ARRAY[
         'publicTextSha256','reasonCode','officialSourceLocator',
         'officialSourceSha256','editorialReviewDecisionId'
       ]
       OR v_named_override->>'editorialReviewDecisionId'
            IS DISTINCT FROM v_first_decision_id::text THEN
      RAISE EXCEPTION 'named_person_legal_stage_invalid'
        USING ERRCODE='23514';
    END IF;
  END IF;
  SELECT * INTO v_existing
  FROM editorial.named_person_review_stage_receipts_v1
  WHERE idempotency_key_sha256=v_idempotency FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest IS DISTINCT FROM v_request_digest
       OR v_existing.decision_id IS DISTINCT FROM v_decision_id
       OR v_existing.review_snapshot_id IS DISTINCT FROM v_snapshot_id
       OR v_existing.review_stage IS DISTINCT FROM v_stage
       OR v_existing.decision IS DISTINCT FROM v_decision
       OR v_existing.reviewer_user_id IS DISTINCT FROM v_actor_id
       OR v_existing.actor_action_digest IS DISTINCT FROM
          (p_request->>'_actorActionDigest')::char(64)
       OR v_existing.assurance_level IS DISTINCT FROM v_assurance
       OR v_existing.effective_capability IS DISTINCT FROM v_capability
       OR v_existing.step_up_authorization_id
          IS DISTINCT FROM v_step_up_id
       OR v_existing.referenced_editorial_decision_id
          IS DISTINCT FROM v_first_decision_id
       OR NOT EXISTS(
         SELECT 1 FROM editorial.review_assignments AS assignment
         WHERE assignment.id=v_existing.review_assignment_id
           AND assignment.case_id=v_existing.case_id
           AND assignment.review_snapshot_id=v_existing.review_snapshot_id
           AND assignment.reviewer_id=v_existing.reviewer_user_id
           AND assignment.status='COMPLETED'
           AND assignment.completed_at IS NOT NULL
           AND assignment.version=v_existing.review_assignment_version_after
           AND v_existing.review_assignment_version_after=
             v_existing.review_assignment_version_before+1
       )
       OR NOT EXISTS(
         SELECT 1 FROM ops.outbox AS outbox
         WHERE outbox.id=v_existing.outbox_event_id
           AND outbox.event_type=v_existing.outbox_event_type
           AND outbox.aggregate_type='ReviewDecision'
           AND outbox.aggregate_id=v_existing.decision_id::text
           AND outbox.aggregate_version=1
           AND ops.r6d_outbox_envelope_digest_v1(outbox.id)=
             v_existing.outbox_event_digest
       ) THEN
      RAISE EXCEPTION 'named_person_review_stage_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN jsonb_build_object(
      'decisionId',v_existing.decision_id,
      'reviewSnapshotId',v_existing.review_snapshot_id,
      'aggregateVersion',v_existing.case_version,
      'reviewStageReceiptId',v_existing.receipt_id,
      'reviewStageReceiptDigest',btrim(v_existing.receipt_digest),
      'auditEventId',v_existing.audit_event_id,
      'acceptedAt',v_existing.created_at,
      'outboxEventIds',jsonb_build_array(v_existing.outbox_event_id),
      'replayed',true
    );
  END IF;
  SELECT * INTO STRICT v_snapshot FROM editorial.review_snapshots
  WHERE id=v_snapshot_id FOR SHARE;
  IF v_snapshot.created_by=v_actor_id
     OR v_independence->>'snapshotCreatedBy'
          IS DISTINCT FROM v_snapshot.created_by::text
     OR v_independence->>'reviewer' IS DISTINCT FROM v_actor_id::text THEN
    RAISE EXCEPTION 'named_person_review_stage_not_independent'
      USING ERRCODE='42501';
  END IF;
  SELECT * INTO STRICT v_assignment
  FROM editorial.review_assignments AS assignment
  WHERE assignment.case_id=v_snapshot.case_id
    AND assignment.review_snapshot_id=v_snapshot.id
    AND assignment.reviewer_id=v_actor_id
    AND assignment.status IN ('ASSIGNED','IN_PROGRESS')
  FOR UPDATE;
  v_assignment_version_before:=v_assignment.version;
  v_authority_digest:=ops.r6d_user_capability_authority_digest_v1(
    v_actor_id,v_required_role,v_capability
  );
  IF v_authority_digest IS NULL THEN
    RAISE EXCEPTION 'named_person_review_stage_authority_missing'
      USING ERRCODE='42501';
  END IF;
  IF v_decision='APPROVE' THEN
    SELECT * INTO v_step_up FROM ops.step_up_authorizations
    WHERE id=v_step_up_id AND closed_at IS NULL FOR SHARE;
    IF NOT FOUND OR v_step_up.expires_at<=v_now
       OR v_step_up.action_digest IS DISTINCT FROM
            (p_request->>'_actorActionDigest')::char(64)
       OR v_step_up.idempotency_key_sha256 IS DISTINCT FROM v_idempotency
       OR v_step_up.assertion_issue_count NOT BETWEEN 1 AND 3
       OR v_step_up.last_issued_at IS NULL OR v_step_up.last_issued_at>v_now
       OR v_step_up.last_issued_at>=v_step_up.expires_at
       OR v_step_up.expires_at>v_step_up.last_issued_at
            +interval '5 minutes 5 seconds'
       OR NOT EXISTS(
         SELECT 1 FROM ops.sessions AS session
         WHERE session.id=v_step_up.session_id
           AND session.user_id=v_actor_id
           AND session.revoked_at IS NULL AND session.expires_at>v_now
       ) THEN
      RAISE EXCEPTION 'named_person_review_stage_step_up_invalid'
        USING ERRCODE='42501';
    END IF;
    v_step_up_receipt:=encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_object(
        'schemaVersion','step-up-authorization-receipt.v1',
        'authorizationId',v_step_up.id,
        'actionDigest',btrim(v_step_up.action_digest),
        'sessionId',v_step_up.session_id,
        'issueNumber',v_step_up.assertion_issue_count,
        'issuedAt',v_step_up.last_issued_at,
        'expiresAt',v_step_up.expires_at
      )),'sha256'
    ),'hex');
  END IF;
  IF v_stage='LEGAL' THEN
    SELECT stage.* INTO STRICT v_first_receipt
    FROM editorial.named_person_review_stage_receipts_v1 AS stage
    WHERE stage.decision_id=v_first_decision_id
      AND stage.review_snapshot_id=v_snapshot.id
      AND stage.case_id=v_snapshot.case_id
      AND stage.review_stage='EDITORIAL'
      AND stage.decision='APPROVE' FOR SHARE;
    IF v_first_receipt.reviewer_user_id=v_actor_id
       OR v_first_receipt.reviewer_user_id=v_snapshot.created_by THEN
      RAISE EXCEPTION 'named_person_legal_stage_first_review_invalid'
        USING ERRCODE='42501';
    END IF;
    SELECT override.* INTO STRICT v_override
    FROM editorial.named_person_legal_overrides AS override
    JOIN editorial.named_person_publication_assessments AS assessment
      ON assessment.assessment_id=override.assessment_id
      AND assessment.review_snapshot_id=v_snapshot.id
    WHERE override.editorial_review_decision_id=v_first_decision_id
      AND override.legal_reviewer_user_id=v_actor_id
      AND override.actor_assertion_jti=v_actor_jti
      AND override.step_up_authorization_id=v_step_up_id
      AND override.idempotency_key_sha256=v_idempotency
      AND override.request_digest=v_request_digest
      AND btrim(override.public_text_sha256)=
        v_named_override->>'publicTextSha256'
      AND override.reason_code=v_named_override->>'reasonCode'
      AND override.official_source_locator=
        v_named_override->>'officialSourceLocator'
      AND btrim(override.official_source_sha256)=
        v_named_override->>'officialSourceSha256'
    FOR SHARE OF override;
  END IF;
  INSERT INTO editorial.review_decisions(
    id,review_snapshot_id,reviewer_id,decision,reason,criteria,
    reviewer_independence,reauth_context_hash
  ) VALUES(
    v_decision_id,v_snapshot.id,v_actor_id,
    v_decision::editorial.review_decision,v_reason,v_criteria,
    v_independence,v_reauth_hash
  );
  v_decision_digest:=editorial.review_decision_digest_v1(v_decision_id);
  UPDATE editorial.review_assignments
  SET status='COMPLETED',completed_at=v_now,version=version+1
  WHERE id=v_assignment.id
    AND version=v_assignment_version_before
    AND status IN ('ASSIGNED','IN_PROGRESS')
  RETURNING * INTO STRICT v_assignment;
  SELECT count(*) INTO v_task_count
  FROM (
    SELECT task.id
    FROM ops.tasks AS task
    WHERE task.task_type='REVIEW'
      AND task.object_id=v_snapshot.id
      AND task.assignee_user_id=v_actor_id
      AND task.status IN ('OPEN','IN_PROGRESS','BLOCKED')
    FOR UPDATE
  ) AS locked_task;
  IF v_task_count>1 THEN
    RAISE EXCEPTION 'named_person_review_stage_task_ambiguous'
      USING ERRCODE='23514';
  ELSIF v_task_count=1 THEN
    SELECT * INTO STRICT v_task
    FROM ops.tasks AS task
    WHERE task.task_type='REVIEW'
      AND task.object_id=v_snapshot.id
      AND task.assignee_user_id=v_actor_id
      AND task.status IN ('OPEN','IN_PROGRESS','BLOCKED')
    FOR UPDATE;
    v_task_version_before:=v_task.version;
    UPDATE ops.tasks
    SET status='DONE',completed_at=v_now,version=version+1
    WHERE id=v_task.id AND version=v_task_version_before
      AND status IN ('OPEN','IN_PROGRESS','BLOCKED')
    RETURNING * INTO STRICT v_task;
  END IF;
  v_audit:=ops.append_audit_event(
    'publication-review:'||v_snapshot.case_id::text,
    'USER',v_actor_id::text,
    CASE WHEN v_step_up.id IS NULL THEN NULL ELSE v_step_up.session_id END,
    'publication.named_person.review_stage','ReviewDecision',
    v_decision_id::text,v_capability,'SUCCESS',NULL,v_request_id,
    jsonb_build_object(
      'reviewStage',v_stage,'decision',v_decision,
      'decisionDigest',btrim(v_decision_digest),
      'reviewerAuthorityDigest',btrim(v_authority_digest),
      'actorActionDigest',p_request->>'_actorActionDigest',
      'stepUpReceiptDigest',btrim(v_step_up_receipt),
      'referencedEditorialStageReceiptDigest',
        btrim(v_first_receipt.receipt_digest),
      'namedPersonOverrideDigest',btrim(v_override.override_digest)
    )
  );
  SELECT event_hash INTO STRICT v_audit_digest
  FROM ops.audit_events WHERE id=v_audit;
  v_outbox:=ops.enqueue_outbox(
    'ReviewDecision',v_decision_id::text,1,
    'review.decision_submitted.v1',jsonb_build_object(
      'actor_id','sha256:'||encode(extensions.digest(
        convert_to(v_actor_id::text,'UTF8'),'sha256'
      ),'hex'),
      'occurred_at',v_now,'operation_id','submitReview',
      'request_id',v_request_id,'reviewSnapshotId',v_snapshot.id
    ),v_now
  );
  v_outbox_digest:=ops.r6d_outbox_envelope_digest_v1(v_outbox);
  v_receipt_payload:=jsonb_strip_nulls(jsonb_build_object(
    'schemaVersion','named-person-review-stage-receipt.v1',
    'receiptId',gen_random_uuid(),
    'decisionId',v_decision_id,'reviewSnapshotId',v_snapshot.id,
    'caseId',v_snapshot.case_id,'caseVersion',v_snapshot.case_version,
    'reviewAssignmentId',v_assignment.id,
    'reviewAssignmentVersionBefore',v_assignment_version_before,
    'reviewAssignmentVersionAfter',v_assignment.version,
    'reviewTaskId',v_task.id,
    'reviewTaskVersionBefore',v_task_version_before,
    'reviewTaskVersionAfter',v_task.version,
    'reviewStage',v_stage,'decision',v_decision,
    'decisionDigest',btrim(v_decision_digest),
    'reviewerAuthorityDigest',btrim(v_authority_digest),
    'actorAssertionJtiSha256',encode(extensions.digest(
      convert_to(v_actor_jti::text,'UTF8'),'sha256'
    ),'hex'),
    'actorActionDigest',p_request->>'_actorActionDigest',
    'assuranceLevel',v_assurance,'effectiveCapability',v_capability,
    'stepUpReceiptDigest',btrim(v_step_up_receipt),
    'referencedEditorialDecisionId',v_first_decision_id,
    'referencedEditorialStageReceiptDigest',
      btrim(v_first_receipt.receipt_digest),
    'namedPersonOverrideDigest',btrim(v_override.override_digest),
    'reasonSha256',encode(extensions.digest(
      convert_to(v_reason,'UTF8'),'sha256'
    ),'hex'),
    'criteriaSha256',encode(extensions.digest(
      ops.canonical_jsonb_v1(v_criteria),'sha256'
    ),'hex'),
    'reviewerIndependenceSha256',encode(extensions.digest(
      ops.canonical_jsonb_v1(v_independence),'sha256'
    ),'hex'),
    'reauthContextHash',btrim(v_reauth_hash),
    'auditEventId',v_audit,'auditEventDigest',btrim(v_audit_digest),
    'outboxEventId',v_outbox,
    'outboxEventType','review.decision_submitted.v1',
    'outboxEventDigest',btrim(v_outbox_digest),
    'requestId',v_request_id,'requestDigest',btrim(v_request_digest),
    'createdAt',v_now
  ));
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_receipt_digest:=encode(
    extensions.digest(v_receipt_canonical,'sha256'),'hex'
  );
  INSERT INTO editorial.named_person_review_stage_receipts_v1(
    receipt_id,decision_id,review_snapshot_id,case_id,case_version,
    review_assignment_id,review_assignment_version_before,
    review_assignment_version_after,
    review_task_id,review_task_version_before,review_task_version_after,
    review_stage,decision,reviewer_user_id,reviewer_authority_digest,
    actor_assertion_jti,actor_action_digest,assurance_level,
    effective_capability,step_up_authorization_id,step_up_receipt_digest,
    decision_digest,referenced_editorial_decision_id,
    referenced_editorial_stage_receipt_id,
    referenced_editorial_stage_receipt_digest,named_person_override_id,
    named_person_override_digest,request_id,idempotency_key_sha256,
    request_digest,audit_event_id,outbox_event_id,outbox_event_type,
    outbox_event_digest,receipt_payload,receipt_canonical,
    receipt_digest,created_at
  ) VALUES(
    (v_receipt_payload->>'receiptId')::uuid,v_decision_id,v_snapshot.id,
    v_snapshot.case_id,v_snapshot.case_version,v_assignment.id,
    v_assignment_version_before,v_assignment.version,
    v_task.id,v_task_version_before,v_task.version,
    v_stage,v_decision,v_actor_id,
    v_authority_digest,v_actor_jti,
    (p_request->>'_actorActionDigest')::char(64),v_assurance,v_capability,
    v_step_up_id,v_step_up_receipt,v_decision_digest,v_first_decision_id,
    v_first_receipt.receipt_id,v_first_receipt.receipt_digest,
    v_override.override_id,v_override.override_digest,v_request_id,
    v_idempotency,v_request_digest,v_audit,v_outbox,
    'review.decision_submitted.v1',v_outbox_digest,v_receipt_payload,
    v_receipt_canonical,v_receipt_digest,v_now
  );
  RETURN jsonb_build_object(
    'decisionId',v_decision_id,
    'reviewSnapshotId',v_snapshot.id,
    'aggregateVersion',v_snapshot.case_version,
    'reviewStageReceiptId',v_receipt_payload->>'receiptId',
    'reviewStageReceiptDigest',btrim(v_receipt_digest),
    'auditEventId',v_audit,'acceptedAt',v_now,
    'outboxEventIds',jsonb_build_array(v_outbox),'replayed',false
  );
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'named_person_review_stage_authority_missing_or_ambiguous'
    USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.record_named_person_review_stage_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.record_named_person_review_stage_v1(jsonb)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.record_named_person_review_stage_v1(jsonb)
  TO gurine_control_api;
REVOKE INSERT,UPDATE,DELETE ON editorial.review_decisions
  FROM gurine_control_api;

CREATE OR REPLACE FUNCTION editorial.record_named_person_legal_override_v1(
  p_request jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp
AS $$
DECLARE
  v_assessment editorial.named_person_publication_assessments%ROWTYPE;
  v_existing editorial.named_person_legal_overrides%ROWTYPE;
  v_snapshot editorial.review_snapshots%ROWTYPE;
  v_decision editorial.review_decisions%ROWTYPE;
  v_editorial_stage_receipt
    editorial.named_person_review_stage_receipts_v1%ROWTYPE;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_override jsonb:=p_request->'legalOverride';
  v_override_id uuid:=gen_random_uuid();
  v_assessment_id uuid;
  v_actor_id uuid;
  v_actor_jti uuid;
  v_decision_id uuid;
  v_request_id uuid;
  v_step_up_id uuid;
  v_idempotency char(64);
  v_request_digest char(64);
  v_public_text_sha char(64);
  v_source_sha char(64);
  v_policy_receipt char(64);
  v_reason_code text;
  v_locator text;
  v_decision_digest char(64);
  v_editorial_authority_digest char(64);
  v_legal_authority_digest char(64);
  v_step_up_receipt_digest char(64);
  v_override_payload jsonb;
  v_override_canonical bytea;
  v_override_digest char(64);
  v_audit uuid;
  v_audit_digest char(64);
  v_receipt_digest char(64);
  v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_request))<>13
     OR NOT p_request ?& ARRAY[
       'assessmentId','legalOverride','_actorId','_actorAssertionJti',
       '_actorEffectiveCapability',
       '_actorAssuranceLevel','_actorActionDigest',
       '_actorStepUpAuthorizationId','_actorIdempotencyKeySha256',
       '_actorRequestKeySha256','_requestId','_idempotencyKeySha256',
       '_requestSha256'
     ] THEN
    RAISE EXCEPTION 'named_person_override_request_invalid'
      USING ERRCODE='22023';
  END IF;
  IF v_override IS NULL OR jsonb_typeof(v_override)='null' THEN
    RETURN jsonb_build_object(
      'overrideId',NULL,'overrideReceiptDigest',NULL,
      'overrideAuditEventId',NULL,'replayed',false
    );
  END IF;
  IF jsonb_typeof(v_override)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_override))<>9
     OR NOT v_override ?& ARRAY[
       'receiptVersion','publicTextSha256','rulesetVersion','reasonCode',
       'officialSourceLocator','officialSourceSha256','legalReviewerId',
       'receiptSha256','editorialReviewDecisionId'
     ] THEN
    RAISE EXCEPTION 'named_person_override_shape_invalid'
      USING ERRCODE='22023';
  END IF;
  BEGIN
    v_assessment_id:=NULLIF(p_request->>'assessmentId','')::uuid;
    v_actor_id:=NULLIF(p_request->>'_actorId','')::uuid;
    v_actor_jti:=NULLIF(p_request->>'_actorAssertionJti','')::uuid;
    v_step_up_id:=NULLIF(
      p_request->>'_actorStepUpAuthorizationId',''
    )::uuid;
    v_request_id:=NULLIF(p_request->>'_requestId','')::uuid;
    v_idempotency:=NULLIF(
      p_request->>'_idempotencyKeySha256',''
    )::char(64);
    v_request_digest:=NULLIF(p_request->>'_requestSha256','')::char(64);
    v_public_text_sha:=NULLIF(
      v_override->>'publicTextSha256',''
    )::char(64);
    v_source_sha:=NULLIF(
      v_override->>'officialSourceSha256',''
    )::char(64);
    v_decision_id:=NULLIF(
      v_override->>'editorialReviewDecisionId',''
    )::uuid;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'named_person_override_request_invalid'
      USING ERRCODE='22023';
  END;
  v_reason_code:=NULLIF(v_override->>'reasonCode','');
  v_locator:=NULLIF(btrim(v_override->>'officialSourceLocator'),'');
  IF v_assessment_id IS NULL OR v_actor_id IS NULL OR v_actor_jti IS NULL
     OR v_step_up_id IS NULL OR v_request_id IS NULL OR v_decision_id IS NULL
     OR p_request->>'_actorAssuranceLevel' IS DISTINCT FROM 'STEP_UP'
     OR p_request->>'_actorEffectiveCapability' IS DISTINCT FROM 'review.legal'
     OR v_override->>'receiptVersion'
          IS DISTINCT FROM 'named-individual-legal-override-v1'
     OR v_override->>'legalReviewerId' IS DISTINCT FROM v_actor_id::text
     OR v_reason_code NOT IN (
       'OFFICIAL_DISPOSITION_QUOTE','PUBLIC_FIGURE'
     )
     OR v_locator IS NULL OR length(v_locator)>2048
     OR NOT ops.r6d_lower_sha256(v_public_text_sha)
     OR NOT ops.r6d_lower_sha256(v_source_sha)
     OR NOT ops.r6d_lower_sha256(v_override->>'receiptSha256')
     OR NOT ops.r6d_lower_sha256(p_request->>'_actorActionDigest')
     OR NOT ops.r6d_lower_sha256(v_idempotency)
     OR NOT ops.r6d_lower_sha256(v_request_digest)
     OR p_request->>'_actorRequestKeySha256' IS DISTINCT FROM v_idempotency
     OR p_request->>'_actorIdempotencyKeySha256'
          IS DISTINCT FROM v_idempotency THEN
    RAISE EXCEPTION 'named_person_override_request_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing
  FROM editorial.named_person_legal_overrides
  WHERE idempotency_key_sha256=v_idempotency FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest IS DISTINCT FROM v_request_digest
       OR v_existing.assessment_id IS DISTINCT FROM v_assessment_id
       OR v_existing.legal_reviewer_user_id IS DISTINCT FROM v_actor_id
       OR v_existing.step_up_authorization_id IS DISTINCT FROM v_step_up_id
       OR v_existing.editorial_review_decision_id IS DISTINCT FROM v_decision_id
       OR v_existing.public_text_sha256 IS DISTINCT FROM v_public_text_sha
       OR v_existing.reason_code IS DISTINCT FROM v_reason_code
       OR v_existing.official_source_locator IS DISTINCT FROM v_locator
       OR v_existing.official_source_sha256 IS DISTINCT FROM v_source_sha THEN
      RAISE EXCEPTION 'named_person_override_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN jsonb_build_object(
      'overrideId',v_existing.override_id,
      'overrideReceiptDigest',btrim(v_existing.receipt_digest),
      'overrideAuditEventId',v_existing.audit_event_id,'replayed',true
    );
  END IF;
  SELECT * INTO STRICT v_assessment
  FROM editorial.named_person_publication_assessments
  WHERE assessment_id=v_assessment_id FOR SHARE;
  SELECT * INTO STRICT v_snapshot FROM editorial.review_snapshots
  WHERE id=v_assessment.review_snapshot_id AND case_id=v_assessment.case_id
  FOR SHARE;
  IF v_assessment.guard_context IS DISTINCT FROM 'PREVIEW'
     OR v_assessment.outcome IS DISTINCT FROM 'BLOCKED'
     OR v_assessment.finding_count<1
     OR v_assessment.public_text_sha256 IS DISTINCT FROM v_public_text_sha
     OR v_assessment.ruleset_version IS DISTINCT FROM
       v_override->>'rulesetVersion' THEN
    RAISE EXCEPTION 'named_person_override_assessment_scope_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO STRICT v_decision FROM editorial.review_decisions
  WHERE id=v_decision_id AND review_snapshot_id=v_snapshot.id
    AND decision='APPROVE' FOR SHARE;
  IF jsonb_typeof(v_decision.criteria)<>'object'
     OR v_decision.criteria ? 'namedIndividualOverride' THEN
    RAISE EXCEPTION 'named_person_override_editorial_decision_not_first_stage'
      USING ERRCODE='23514';
  END IF;
  SELECT stage.* INTO STRICT v_editorial_stage_receipt
  FROM editorial.named_person_review_stage_receipts_v1 AS stage
  WHERE stage.decision_id=v_decision.id
    AND stage.review_snapshot_id=v_snapshot.id
    AND stage.case_id=v_snapshot.case_id
    AND stage.case_version=v_snapshot.case_version
    AND stage.review_stage='EDITORIAL'
    AND stage.decision='APPROVE'
    AND stage.reviewer_user_id=v_decision.reviewer_id
    AND stage.decision_digest=
      editorial.review_decision_digest_v1(v_decision.id)
    AND stage.assurance_level='STEP_UP'
    AND stage.effective_capability='review.editorial'
  FOR SHARE;
  IF v_decision.reviewer_id=v_snapshot.created_by
     OR v_decision.reviewer_id=v_actor_id
     OR v_snapshot.created_by=v_actor_id THEN
    RAISE EXCEPTION 'named_person_override_reviewer_not_independent'
      USING ERRCODE='42501';
  END IF;
  v_editorial_authority_digest:=
    v_editorial_stage_receipt.reviewer_authority_digest;
  v_legal_authority_digest:=
    ops.r6d_user_capability_authority_digest_v1(
      v_actor_id,'LEGAL_REVIEWER','review.legal'
    );
  IF v_editorial_authority_digest IS NULL
     OR v_legal_authority_digest IS NULL
     OR NOT EXISTS(
    SELECT 1 FROM ops.users AS app_user
    JOIN ops.user_roles AS user_role
      ON user_role.user_id=app_user.id
      AND user_role.revoked_at IS NULL
      AND (user_role.expires_at IS NULL OR user_role.expires_at>v_now)
    JOIN ops.roles AS role
      ON role.id=user_role.role_id AND role.code='LEGAL_REVIEWER'
    JOIN ops.role_capabilities AS role_capability
      ON role_capability.role_id=role.id
      AND role_capability.capability_code='review.legal'
    WHERE app_user.id=v_actor_id AND app_user.status='ACTIVE'
  ) THEN
    RAISE EXCEPTION 'named_person_override_legal_reviewer_required'
      USING ERRCODE='42501';
  END IF;
  SELECT * INTO v_step_up FROM ops.step_up_authorizations
  WHERE id=v_step_up_id AND closed_at IS NULL FOR SHARE;
  IF NOT FOUND OR v_step_up.expires_at<=v_now
     OR v_step_up.action_digest IS DISTINCT FROM
       (p_request->>'_actorActionDigest')::char(64)
     OR v_step_up.idempotency_key_sha256 IS DISTINCT FROM v_idempotency
     OR v_step_up.assertion_issue_count NOT BETWEEN 1 AND 3
     OR v_step_up.last_issued_at IS NULL OR v_step_up.last_issued_at>v_now
     OR v_step_up.last_issued_at>=v_step_up.expires_at
     OR v_step_up.expires_at>v_step_up.last_issued_at
          +interval '5 minutes 5 seconds'
     OR NOT EXISTS(
       SELECT 1 FROM ops.sessions AS session
       WHERE session.id=v_step_up.session_id AND session.user_id=v_actor_id
         AND session.revoked_at IS NULL AND session.expires_at>v_now
     ) THEN
    RAISE EXCEPTION 'named_person_override_step_up_invalid'
      USING ERRCODE='42501';
  END IF;
  v_policy_receipt:=editorial.named_person_legal_override_digest_v1(
    btrim(v_public_text_sha),v_assessment.ruleset_version,v_reason_code,
    v_locator,btrim(v_source_sha),v_actor_id::text
  );
  IF v_policy_receipt IS DISTINCT FROM v_override->>'receiptSha256' THEN
    RAISE EXCEPTION 'named_person_override_receipt_digest_mismatch'
      USING ERRCODE='23514';
  END IF;
  v_decision_digest:=editorial.review_decision_digest_v1(v_decision.id);
  v_step_up_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','step-up-authorization-receipt.v1',
      'authorizationId',v_step_up.id,
      'actionDigest',btrim(v_step_up.action_digest),
      'sessionId',v_step_up.session_id,
      'issueNumber',v_step_up.assertion_issue_count,
      'issuedAt',v_step_up.last_issued_at,'expiresAt',v_step_up.expires_at
    )),'sha256'
  ),'hex');
  v_override_payload:=jsonb_build_object(
    'schemaVersion','named-person-legal-override.v1',
    'overrideId',v_override_id,'assessmentId',v_assessment.assessment_id,
    'caseId',v_assessment.case_id,
    'reviewSnapshotId',v_assessment.review_snapshot_id,
    'publicTextSha256',btrim(v_public_text_sha),
    'rulesetVersion',v_assessment.ruleset_version,
    'reasonCode',v_reason_code,'officialSourceLocator',v_locator,
    'officialSourceSha256',btrim(v_source_sha),
    'editorialReviewDecisionId',v_decision.id,
    'editorialReviewDecisionDigest',v_decision_digest,
    'editorialReviewStageReceiptDigest',
      btrim(v_editorial_stage_receipt.receipt_digest),
    'editorialReviewerAuthorityDigest',
      btrim(v_editorial_authority_digest),
    'legalReviewerAuthorityDigest',btrim(v_legal_authority_digest),
    'policyReceiptDigest',btrim(v_policy_receipt),
    'stepUpAuthorizationReceiptDigest',v_step_up_receipt_digest,
    'reviewedAt',v_now
  );
  v_override_canonical:=ops.canonical_jsonb_v1(v_override_payload);
  v_override_digest:=encode(
    extensions.digest(v_override_canonical,'sha256'),'hex'
  );
  v_audit:=ops.append_audit_event(
    'publication-guard:'||v_assessment.case_id::text,'USER',v_actor_id::text,
    v_step_up.session_id,'publication.named_person.override',
    'PublicationAssessment',v_assessment.assessment_id::text,
    'review.legal','SUCCESS',v_reason_code,v_request_id,
    jsonb_build_object(
      'overrideDigest',v_override_digest,
      'policyReceiptDigest',btrim(v_policy_receipt),
      'publicTextSha256',btrim(v_public_text_sha),
      'officialSourceSha256',btrim(v_source_sha),
      'editorialReviewDecisionDigest',v_decision_digest,
      'editorialReviewStageReceiptDigest',
        btrim(v_editorial_stage_receipt.receipt_digest),
      'editorialReviewerAuthorityDigest',
        btrim(v_editorial_authority_digest),
      'legalReviewerAuthorityDigest',btrim(v_legal_authority_digest),
      'stepUpAuthorizationReceiptDigest',v_step_up_receipt_digest
    )
  );
  SELECT event_hash INTO STRICT v_audit_digest
  FROM ops.audit_events WHERE id=v_audit;
  v_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','named-person-legal-override-receipt.v1',
      'overrideId',v_override_id,'overrideDigest',v_override_digest,
      'policyReceiptDigest',btrim(v_policy_receipt),
      'auditEventId',v_audit,'auditEventDigest',btrim(v_audit_digest),
      'requestId',v_request_id,'requestDigest',btrim(v_request_digest)
    )),'sha256'
  ),'hex');
  INSERT INTO editorial.named_person_legal_overrides(
    override_id,assessment_id,public_text_sha256,ruleset_version,
    reason_code,official_source_locator,official_source_sha256,
    publication_author_user_id,editorial_review_decision_id,
    editorial_reviewer_user_id,editorial_review_decision_digest,
    editorial_review_stage_receipt_id,
    editorial_review_stage_receipt_digest,
    editorial_reviewer_authority_digest,legal_reviewer_authority_digest,
    legal_reviewer_user_id,step_up_authorization_id,
    step_up_receipt_digest,actor_assertion_jti,request_id,
    idempotency_key_sha256,request_digest,audit_event_id,override_payload,
    override_canonical,override_digest,receipt_digest,reviewed_at
  ) VALUES(
    v_override_id,v_assessment.assessment_id,v_public_text_sha,
    v_assessment.ruleset_version,v_reason_code,v_locator,v_source_sha,
    v_snapshot.created_by,v_decision.id,v_decision.reviewer_id,
    v_decision_digest,v_editorial_stage_receipt.receipt_id,
    v_editorial_stage_receipt.receipt_digest,
    v_editorial_authority_digest,v_legal_authority_digest,
    v_actor_id,v_step_up.id,v_step_up_receipt_digest,
    v_actor_jti,v_request_id,v_idempotency,v_request_digest,v_audit,
    v_override_payload,v_override_canonical,v_override_digest,
    v_receipt_digest,v_now
  );
  RETURN jsonb_build_object(
    'overrideId',v_override_id,
    'overrideReceiptDigest',btrim(v_receipt_digest),
    'overrideAuditEventId',v_audit,'replayed',false
  );
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'named_person_override_authority_missing_or_ambiguous'
    USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.record_named_person_legal_override_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.record_named_person_legal_override_v1(jsonb)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.record_named_person_legal_override_v1(jsonb)
  TO gurine_control_api;

-- Mirrors `PublicTextNode` and `public_text_sha256` byte-for-byte.  These
-- helpers are migration-owner-only: transient text nodes are never exposed to
-- an application role or copied into a durable receipt.
CREATE OR REPLACE FUNCTION editorial.r6d_public_text_node_preimage_v1(
  p_node jsonb
) RETURNS bytea
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,editorial,pg_temp
AS $$
DECLARE
  v_kind text;
  v_result bytea;
  v_entry jsonb;
  v_name text;
  v_value text;
BEGIN
  IF jsonb_typeof(p_node)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_node))<>2
     OR NOT p_node ?& ARRAY['kind',CASE p_node->>'kind'
       WHEN 'TEXT' THEN 'value' ELSE 'items' END] THEN
    RAISE EXCEPTION 'r6d_public_text_node_invalid' USING ERRCODE='22023';
  END IF;
  v_kind:=p_node->>'kind';
  IF v_kind='TEXT' THEN
    IF jsonb_typeof(p_node->'value')<>'string' THEN
      RAISE EXCEPTION 'r6d_public_text_node_invalid' USING ERRCODE='22023';
    END IF;
    v_value:=p_node->>'value';
    RETURN convert_to('T','UTF8')
      ||int8send(octet_length(convert_to(v_value,'UTF8'))::bigint)
      ||convert_to(v_value,'UTF8');
  ELSIF v_kind='ARRAY' THEN
    IF jsonb_typeof(p_node->'items')<>'array' THEN
      RAISE EXCEPTION 'r6d_public_text_node_invalid' USING ERRCODE='22023';
    END IF;
    v_result:=convert_to('A','UTF8')
      ||int8send(jsonb_array_length(p_node->'items')::bigint);
    FOR v_entry IN SELECT value FROM jsonb_array_elements(p_node->'items')
    LOOP
      v_result:=v_result||editorial.r6d_public_text_node_preimage_v1(v_entry);
    END LOOP;
    RETURN v_result;
  ELSIF v_kind='OBJECT' THEN
    IF jsonb_typeof(p_node->'items')<>'array'
       OR EXISTS(
         SELECT 1 FROM jsonb_array_elements(p_node->'items') AS field(value)
         WHERE jsonb_typeof(value)<>'object'
            OR (SELECT count(*) FROM jsonb_object_keys(value))<>2
            OR NOT value ?& ARRAY['name','node']
            OR jsonb_typeof(value->'name')<>'string'
            OR jsonb_typeof(value->'node')<>'object'
            OR NULLIF(value->>'name','') IS NULL
       )
       OR (
         SELECT count(*)<>count(DISTINCT value->>'name')
         FROM jsonb_array_elements(p_node->'items') AS field(value)
       ) THEN
      RAISE EXCEPTION 'r6d_public_text_node_invalid' USING ERRCODE='22023';
    END IF;
    v_result:=convert_to('O','UTF8');
    FOR v_entry IN
      SELECT value FROM jsonb_array_elements(p_node->'items') AS field(value)
      ORDER BY convert_to(value->>'name','UTF8')
    LOOP
      v_name:=v_entry->>'name';
      v_result:=v_result
        ||int8send(octet_length(convert_to(v_name,'UTF8'))::bigint)
        ||convert_to(v_name,'UTF8')
        ||editorial.r6d_public_text_node_preimage_v1(v_entry->'node');
    END LOOP;
    RETURN v_result;
  END IF;
  RAISE EXCEPTION 'r6d_public_text_node_invalid' USING ERRCODE='22023';
END
$$;
ALTER FUNCTION editorial.r6d_public_text_node_preimage_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_public_text_node_preimage_v1(jsonb)
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.r6d_public_data_node_v1(
  p_value jsonb
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,editorial,pg_temp
AS $$
DECLARE
  v_kind text:=jsonb_typeof(p_value);
  v_items jsonb;
BEGIN
  IF v_kind='string' THEN
    RETURN jsonb_build_object('kind','TEXT','value',p_value#>>'{}');
  ELSIF v_kind='array' THEN
    SELECT COALESCE(jsonb_agg(
      editorial.r6d_public_data_node_v1(value) ORDER BY ordinal
    ),'[]'::jsonb)
    INTO v_items
    FROM jsonb_array_elements(p_value) WITH ORDINALITY AS item(value,ordinal);
    RETURN jsonb_build_object('kind','ARRAY','items',v_items);
  ELSIF v_kind='object' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'name',key,'node',editorial.r6d_public_data_node_v1(value)
    ) ORDER BY convert_to(key,'UTF8')),'[]'::jsonb)
    INTO v_items FROM jsonb_each(p_value);
    RETURN jsonb_build_object('kind','OBJECT','items',v_items);
  ELSIF v_kind IN ('null','boolean','number') THEN
    RETURN jsonb_build_object('kind','OBJECT','items','[]'::jsonb);
  END IF;
  RAISE EXCEPTION 'r6d_public_data_node_invalid' USING ERRCODE='22023';
END
$$;
ALTER FUNCTION editorial.r6d_public_data_node_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_public_data_node_v1(jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.r6d_text_array_node_v1(
  p_values jsonb
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
DECLARE v_items jsonb;
BEGIN
  IF jsonb_typeof(p_values)<>'array'
     OR EXISTS(
       SELECT 1 FROM jsonb_array_elements(p_values) AS item(value)
       WHERE jsonb_typeof(value)<>'string'
     ) THEN
    RAISE EXCEPTION 'r6d_public_text_array_invalid' USING ERRCODE='22023';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'kind','TEXT','value',value#>>'{}'
  ) ORDER BY ordinal),'[]'::jsonb)
  INTO v_items
  FROM jsonb_array_elements(p_values) WITH ORDINALITY AS item(value,ordinal);
  RETURN jsonb_build_object('kind','ARRAY','items',v_items);
END
$$;
ALTER FUNCTION editorial.r6d_text_array_node_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_text_array_node_v1(jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.r6d_current_public_text_tail_v1(
  p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,editorial,pg_temp
AS $$
DECLARE
  v_fields jsonb:='[]'::jsonb;
  v_items jsonb;
  v_children jsonb;
  v_item jsonb;
  v_key text;
BEGIN
  IF p_payload ? 'correctionDetails' THEN
    IF jsonb_typeof(p_payload->'correctionDetails')<>'object'
       OR jsonb_typeof(p_payload->'correctionDetails'->'effectiveReason')
            <>'string'
       OR jsonb_typeof(p_payload->'correctionDetails'->'limitations')
            <>'array' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_children:=jsonb_build_array(jsonb_build_object(
      'name','effectiveReason','node',jsonb_build_object(
        'kind','TEXT','value',p_payload->'correctionDetails'->>'effectiveReason'
      )
    ),jsonb_build_object(
      'name','limitations','node',editorial.r6d_text_array_node_v1(
        p_payload->'correctionDetails'->'limitations'
      )
    ));
    v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
      'name','correctionDetails','node',jsonb_build_object(
        'kind','OBJECT','items',v_children
      )
    ));
  END IF;
  IF jsonb_typeof(p_payload->'claims')<>'array' THEN
    RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
      USING ERRCODE='22023';
  END IF;
  v_items:='[]'::jsonb;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'claims')
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR jsonb_typeof(v_item->'text')<>'string'
       OR jsonb_typeof(v_item->'limitations')<>'array' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'kind','OBJECT','items',jsonb_build_array(
        jsonb_build_object('name','text','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'text'
        )),
        jsonb_build_object('name','limitations','node',
          editorial.r6d_text_array_node_v1(v_item->'limitations'))
      )
    ));
  END LOOP;
  v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
    'name','claims','node',jsonb_build_object('kind','ARRAY','items',v_items)
  ));
  IF jsonb_typeof(p_payload->'evidence')<>'array' THEN
    RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
      USING ERRCODE='22023';
  END IF;
  v_items:='[]'::jsonb;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'evidence')
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR jsonb_typeof(v_item->'title')<>'string' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_children:=jsonb_build_array(jsonb_build_object(
      'name','title','node',jsonb_build_object(
        'kind','TEXT','value',v_item->>'title'
      )
    ));
    FOREACH v_key IN ARRAY ARRAY[
      'documentTitle','publisher','pageAnchor','sourceLocator','publicExcerpt'
    ] LOOP
      IF v_item ? v_key AND jsonb_typeof(v_item->v_key)<>'null' THEN
        IF jsonb_typeof(v_item->v_key)<>'string' THEN
          RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
            USING ERRCODE='22023';
        END IF;
        v_children:=v_children||jsonb_build_array(jsonb_build_object(
          'name',v_key,'node',jsonb_build_object(
            'kind','TEXT','value',v_item->>v_key
          )
        ));
      END IF;
    END LOOP;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'kind','OBJECT','items',v_children
    ));
  END LOOP;
  v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
    'name','evidence','node',jsonb_build_object('kind','ARRAY','items',v_items)
  ));
  IF jsonb_typeof(p_payload->'responses')<>'array' THEN
    RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
      USING ERRCODE='22023';
  END IF;
  v_items:='[]'::jsonb;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'responses')
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR jsonb_typeof(v_item->'partyName')<>'string'
       OR (v_item ? 'excerpt' AND jsonb_typeof(v_item->'excerpt')
           NOT IN ('string','null')) THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_children:=jsonb_build_array(jsonb_build_object(
      'name','partyName','node',jsonb_build_object(
        'kind','TEXT','value',v_item->>'partyName'
      )
    ));
    IF jsonb_typeof(v_item->'excerpt')='string' THEN
      v_children:=v_children||jsonb_build_array(jsonb_build_object(
        'name','excerpt','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'excerpt'
        )
      ));
    END IF;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'kind','OBJECT','items',v_children
    ));
  END LOOP;
  RETURN v_fields||jsonb_build_array(jsonb_build_object(
    'name','responses','node',jsonb_build_object('kind','ARRAY','items',v_items)
  ));
END
$$;
ALTER FUNCTION editorial.r6d_current_public_text_tail_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_current_public_text_tail_v1(jsonb)
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.r6d_archive_public_text_tail_v1(
  p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,editorial,pg_temp
AS $$
DECLARE
  v_fields jsonb:='[]'::jsonb;
  v_items jsonb;
  v_children jsonb;
  v_item jsonb;
  v_value jsonb;
  v_key text;
BEGIN
  v_items:='[]'::jsonb;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'evidence')
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR jsonb_typeof(v_item->'summary')<>'string'
       OR jsonb_typeof(v_item->'source')<>'object'
       OR jsonb_typeof(v_item->'source'->'locator')<>'object'
       OR jsonb_typeof(v_item->'source'->'locator'->'value')<>'string'
       OR (v_item ? 'public_excerpt'
           AND jsonb_typeof(v_item->'public_excerpt') NOT IN ('string','null'))
    THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_children:=jsonb_build_array(jsonb_build_object(
      'name','summary','node',jsonb_build_object(
        'kind','TEXT','value',v_item->>'summary'
      )
    ));
    IF jsonb_typeof(v_item->'public_excerpt')='string' THEN
      v_children:=v_children||jsonb_build_array(jsonb_build_object(
        'name','public_excerpt','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'public_excerpt'
        )
      ));
    END IF;
    v_children:=v_children||jsonb_build_array(jsonb_build_object(
      'name','source_locator','node',jsonb_build_object(
        'kind','OBJECT','items',jsonb_build_array(jsonb_build_object(
          'name','value','node',jsonb_build_object(
            'kind','TEXT','value',v_item->'source'->'locator'->>'value'
          )
        ))
      )
    ));
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'kind','OBJECT','items',v_children
    ));
  END LOOP;
  v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
    'name','evidence','node',jsonb_build_object('kind','ARRAY','items',v_items)
  ));

  v_items:='[]'::jsonb;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'subjects')
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR jsonb_typeof(v_item->'display_name')<>'string' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'kind','OBJECT','items',jsonb_build_array(jsonb_build_object(
        'name','display_name','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'display_name'
        )
      ))
    ));
  END LOOP;
  v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
    'name','subjects','node',jsonb_build_object('kind','ARRAY','items',v_items)
  ));

  IF jsonb_typeof(p_payload->'methodology')<>'object'
     OR NOT (p_payload->'methodology' ? 'calculation')
     OR jsonb_typeof(p_payload->'methodology'->'limitations')<>'array' THEN
    RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
      USING ERRCODE='22023';
  END IF;
  v_children:=jsonb_build_array(
    jsonb_build_object('name','limitations','node',
      editorial.r6d_text_array_node_v1(
        p_payload->'methodology'->'limitations'
      )),
    jsonb_build_object('name','calculation','node',
      editorial.r6d_public_data_node_v1(
        p_payload->'methodology'->'calculation'
      ))
  );
  v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
    'name','methodology','node',jsonb_build_object(
      'kind','OBJECT','items',v_children
    )
  ));

  v_items:='[]'::jsonb;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'responses')
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR jsonb_typeof(v_item->'party')<>'string'
       OR jsonb_typeof(v_item->'display_text')<>'string' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'kind','OBJECT','items',jsonb_build_array(
        jsonb_build_object('name','party','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'party'
        )),
        jsonb_build_object('name','display_text','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'display_text'
        ))
      )
    ));
  END LOOP;
  v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
    'name','responses','node',jsonb_build_object('kind','ARRAY','items',v_items)
  ));

  v_items:='[]'::jsonb;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'corrections')
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR jsonb_typeof(v_item->'summary')<>'string' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_items:=v_items||jsonb_build_array(jsonb_build_object(
      'kind','OBJECT','items',jsonb_build_array(jsonb_build_object(
        'name','summary','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'summary'
        )
      ))
    ));
  END LOOP;
  v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
    'name','corrections','node',jsonb_build_object('kind','ARRAY','items',v_items)
  ));

  IF p_payload ? 'official_confirmation' THEN
    IF jsonb_typeof(p_payload->'official_confirmation')<>'object' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_children:='[]'::jsonb;
    FOREACH v_key IN ARRAY ARRAY[
      'institution','document_type','confirmed_scope','source_locator'
    ] LOOP
      IF jsonb_typeof(p_payload->'official_confirmation'->v_key)<>'string' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
          USING ERRCODE='22023';
      END IF;
      v_children:=v_children||jsonb_build_array(jsonb_build_object(
        'name',v_key,'node',jsonb_build_object(
          'kind','TEXT','value',p_payload->'official_confirmation'->>v_key
        )
      ));
    END LOOP;
    v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
      'name','official_confirmation','node',jsonb_build_object(
        'kind','OBJECT','items',v_children
      )
    ));
  END IF;
  FOREACH v_key IN ARRAY ARRAY['correction_notice','correction_details']
  LOOP
    IF p_payload ? v_key THEN
      IF jsonb_typeof(p_payload->v_key)<>'object' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
          USING ERRCODE='22023';
      END IF;
      v_children:='[]'::jsonb;
      FOR v_value IN SELECT value FROM jsonb_array_elements(
        CASE v_key WHEN 'correction_notice' THEN
          '["reason","impact_summary"]'::jsonb
        ELSE '["effective_reason"]'::jsonb END
      ) LOOP
        IF jsonb_typeof(p_payload->v_key->(v_value#>>'{}'))<>'string' THEN
          RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
            USING ERRCODE='22023';
        END IF;
        v_children:=v_children||jsonb_build_array(jsonb_build_object(
          'name',v_value#>>'{}','node',jsonb_build_object(
            'kind','TEXT','value',p_payload->v_key->>(v_value#>>'{}')
          )
        ));
      END LOOP;
      IF v_key='correction_details' THEN
        v_children:=v_children||jsonb_build_array(jsonb_build_object(
          'name','limitations','node',editorial.r6d_text_array_node_v1(
            p_payload->v_key->'limitations'
          )
        ));
      END IF;
      v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
        'name',v_key,'node',jsonb_build_object(
          'kind','OBJECT','items',v_children
        )
      ));
    END IF;
  END LOOP;
  RETURN v_fields;
END
$$;
ALTER FUNCTION editorial.r6d_archive_public_text_tail_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_archive_public_text_tail_v1(jsonb)
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.r6d_public_text_tree_v1(
  p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,editorial,pg_temp
AS $$
DECLARE
  v_fields jsonb:='[]'::jsonb;
  v_children jsonb;
  v_items jsonb;
  v_item jsonb;
  v_child jsonb;
  v_key text;
  v_value jsonb;
BEGIN
  IF jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
      USING ERRCODE='22023';
  END IF;
  IF p_payload->>'schema_version'='1.0.0' THEN
    FOREACH v_key IN ARRAY ARRAY['title','summary','non_conclusion']
    LOOP
      IF jsonb_typeof(p_payload->v_key)<>'string' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
          USING ERRCODE='22023';
      END IF;
      v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
        'name',v_key,'node',jsonb_build_object(
          'kind','TEXT','value',p_payload->>v_key
        )
      ));
    END LOOP;
    IF jsonb_typeof(p_payload->'sections')<>'array' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_items:='[]'::jsonb;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'sections')
    LOOP
      IF jsonb_typeof(v_item)<>'object'
         OR jsonb_typeof(v_item->'heading')<>'string'
         OR jsonb_typeof(v_item->'blocks')<>'array' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
          USING ERRCODE='22023';
      END IF;
      v_children:=jsonb_build_array(jsonb_build_object(
        'name','heading','node',jsonb_build_object(
          'kind','TEXT','value',v_item->>'heading'
        )
      ));
      v_value:='[]'::jsonb;
      FOR v_child IN SELECT value FROM jsonb_array_elements(v_item->'blocks')
      LOOP
        IF jsonb_typeof(v_child)<>'object'
           OR (v_child ? 'text' AND jsonb_typeof(v_child->'text')
               NOT IN ('string','null')) THEN
          RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
            USING ERRCODE='22023';
        END IF;
        v_items:=CASE WHEN v_child ? 'text'
                           AND jsonb_typeof(v_child->'text')='string'
          THEN jsonb_build_array(jsonb_build_object(
            'name','text','node',jsonb_build_object(
              'kind','TEXT','value',v_child->>'text'
            )
          )) ELSE '[]'::jsonb END;
        IF v_child ? 'data' AND jsonb_typeof(v_child->'data')<>'null' THEN
          v_items:=v_items||jsonb_build_array(jsonb_build_object(
            'name','data','node',
            editorial.r6d_public_data_node_v1(v_child->'data')
          ));
        END IF;
        v_value:=v_value||jsonb_build_array(jsonb_build_object(
          'kind','OBJECT','items',v_items
        ));
      END LOOP;
      v_children:=v_children||jsonb_build_array(jsonb_build_object(
        'name','blocks','node',jsonb_build_object(
          'kind','ARRAY','items',v_value
        )
      ));
      v_items:=COALESCE(v_items,'[]'::jsonb);
      -- Reuse a dedicated accumulator after the block loop.
      v_items:=jsonb_build_array(jsonb_build_object(
        'kind','OBJECT','items',v_children
      ));
      -- The outer sections accumulator is kept in `v_value` only inside this
      -- branch, so append through the existing field node below.
      IF v_fields @> jsonb_build_array(jsonb_build_object('name','sections')) THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
          USING ERRCODE='22023';
      END IF;
      v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
        'name','__section_pending','node',v_items->0
      ));
    END LOOP;
    SELECT COALESCE(jsonb_agg(value->'node' ORDER BY ordinal),'[]'::jsonb)
    INTO v_items
    FROM jsonb_array_elements(v_fields) WITH ORDINALITY AS field(value,ordinal)
    WHERE value->>'name'='__section_pending';
    SELECT COALESCE(jsonb_agg(value ORDER BY ordinal),'[]'::jsonb)
    INTO v_fields
    FROM jsonb_array_elements(v_fields) WITH ORDINALITY AS field(value,ordinal)
    WHERE value->>'name'<>'__section_pending';
    v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
      'name','sections','node',jsonb_build_object(
        'kind','ARRAY','items',v_items
      )
    ));
    -- Remaining archive groups are normalized by the closed generic helper
    -- below; each group still admits only the exact typed prose keys.
    FOREACH v_key IN ARRAY ARRAY[
      'claims','evidence','subjects','responses','corrections'
    ] LOOP
      IF jsonb_typeof(p_payload->v_key)<>'array' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
          USING ERRCODE='22023';
      END IF;
    END LOOP;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'kind','OBJECT','items',jsonb_build_array(jsonb_build_object(
        'name','text_ko','node',jsonb_build_object(
          'kind','TEXT','value',value->>'text_ko'
        )
      ))
    ) ORDER BY ordinal),'[]'::jsonb) INTO v_items
    FROM jsonb_array_elements(p_payload->'claims') WITH ORDINALITY item(value,ordinal)
    WHERE jsonb_typeof(value)='object' AND jsonb_typeof(value->'text_ko')='string';
    IF jsonb_array_length(v_items)<>jsonb_array_length(p_payload->'claims') THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid' USING ERRCODE='22023';
    END IF;
    v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
      'name','claims','node',jsonb_build_object('kind','ARRAY','items',v_items)
    ));
    -- The archive variant is retained for provenance exports.  Delegate the
    -- remaining complex groups to a separate closed function defined below.
    v_fields:=v_fields||editorial.r6d_archive_public_text_tail_v1(p_payload);
    RETURN jsonb_build_object('kind','OBJECT','items',v_fields);
  END IF;

  FOREACH v_key IN ARRAY ARRAY['title','summary','nonConclusion']
  LOOP
    IF jsonb_typeof(p_payload->v_key)<>'string' THEN
      RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
      'name',v_key,'node',jsonb_build_object(
        'kind','TEXT','value',p_payload->>v_key
      )
    ));
  END LOOP;
  FOREACH v_key IN ARRAY ARRAY['agencyName','contractName']
  LOOP
    IF p_payload ? v_key AND jsonb_typeof(p_payload->v_key)<>'null' THEN
      IF jsonb_typeof(p_payload->v_key)<>'string' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
          USING ERRCODE='22023';
      END IF;
      v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
        'name',v_key,'node',jsonb_build_object(
          'kind','TEXT','value',p_payload->>v_key
        )
      ));
    END IF;
  END LOOP;
  FOREACH v_key IN ARRAY ARRAY['officialConfirmation','correctionNotice']
  LOOP
    IF p_payload ? v_key AND jsonb_typeof(p_payload->v_key)<>'null' THEN
      IF jsonb_typeof(p_payload->v_key)<>'object' THEN
        RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
          USING ERRCODE='22023';
      END IF;
      v_children:='[]'::jsonb;
      FOR v_value IN SELECT value FROM jsonb_array_elements(
        CASE v_key WHEN 'officialConfirmation' THEN
          '["institution","documentType","confirmedScope","sourceLocator"]'::jsonb
        ELSE '["reason","impactSummary"]'::jsonb END
      ) LOOP
        IF jsonb_typeof(p_payload->v_key->(v_value#>>'{}'))<>'string' THEN
          RAISE EXCEPTION 'r6d_public_payload_text_shape_invalid'
            USING ERRCODE='22023';
        END IF;
        v_children:=v_children||jsonb_build_array(jsonb_build_object(
          'name',v_value#>>'{}','node',jsonb_build_object(
            'kind','TEXT','value',p_payload->v_key->>(v_value#>>'{}')
          )
        ));
      END LOOP;
      v_fields:=v_fields||jsonb_build_array(jsonb_build_object(
        'name',v_key,'node',jsonb_build_object(
          'kind','OBJECT','items',v_children
        )
      ));
    END IF;
  END LOOP;
  v_fields:=v_fields||editorial.r6d_current_public_text_tail_v1(p_payload);
  RETURN jsonb_build_object('kind','OBJECT','items',v_fields);
END
$$;
ALTER FUNCTION editorial.r6d_public_text_tree_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_public_text_tree_v1(jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.r6d_public_text_sha256_v1(
  p_payload jsonb
) RETURNS char(64)
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,editorial,extensions,pg_temp
AS $$
  SELECT encode(extensions.digest(
    editorial.r6d_public_text_node_preimage_v1(
      editorial.r6d_public_text_tree_v1(p_payload)
    ),'sha256'
  ),'hex')::char(64)
$$;
ALTER FUNCTION editorial.r6d_public_text_sha256_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_public_text_sha256_v1(jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.r6d_json_pointer_text_v1(
  p_document jsonb,
  p_pointer text
) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,editorial,pg_temp
AS $$
DECLARE
  v_current jsonb:=editorial.r6d_public_text_tree_v1(p_document);
  v_raw_segment text;
  v_segment text;
  v_index bigint;
BEGIN
  IF octet_length(convert_to(p_pointer,'UTF8')) NOT BETWEEN 1 AND 2048
     OR p_pointer !~ '^(/([^/~]|~[01])*)+$' THEN
    RAISE EXCEPTION 'r6d_public_text_pointer_invalid' USING ERRCODE='22023';
  END IF;
  FOREACH v_raw_segment IN ARRAY string_to_array(substr(p_pointer,2),'/')
  LOOP
    v_segment:=replace(replace(v_raw_segment,'~1','/'),'~0','~');
    IF jsonb_typeof(v_current)<>'object'
       OR v_current->>'kind' IS NULL THEN
      RAISE EXCEPTION 'r6d_public_text_pointer_missing' USING ERRCODE='23514';
    END IF;
    IF v_current->>'kind'='OBJECT' THEN
      SELECT field.value->'node' INTO STRICT v_current
      FROM jsonb_array_elements(v_current->'items') AS field(value)
      WHERE field.value->>'name'=v_segment;
    ELSIF v_current->>'kind'='ARRAY' THEN
      IF v_segment !~ '^(0|[1-9][0-9]*)$' THEN
        RAISE EXCEPTION 'r6d_public_text_pointer_invalid' USING ERRCODE='22023';
      END IF;
      BEGIN
        v_index:=v_segment::bigint;
      EXCEPTION WHEN numeric_value_out_of_range THEN
        RAISE EXCEPTION 'r6d_public_text_pointer_invalid' USING ERRCODE='22023';
      END;
      IF v_index>=jsonb_array_length(v_current->'items')
         OR v_index>2147483647 THEN
        RAISE EXCEPTION 'r6d_public_text_pointer_missing' USING ERRCODE='23514';
      END IF;
      v_current:=v_current->'items'->(v_index::integer);
    ELSE
      RAISE EXCEPTION 'r6d_public_text_pointer_missing' USING ERRCODE='23514';
    END IF;
  END LOOP;
  IF jsonb_typeof(v_current)<>'object'
     OR v_current->>'kind'<>'TEXT'
     OR jsonb_typeof(v_current->'value')<>'string' THEN
    RAISE EXCEPTION 'r6d_public_text_pointer_not_text' USING ERRCODE='23514';
  END IF;
  RETURN v_current->>'value';
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'r6d_public_text_pointer_missing' USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.r6d_json_pointer_text_v1(jsonb,text)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_json_pointer_text_v1(jsonb,text)
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION editorial.r6d_utf16_slice_v1(
  p_text text,
  p_start_utf16 integer,
  p_end_utf16 integer
) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
DECLARE
  v_position integer:=0;
  v_index integer;
  v_character text;
  v_units integer;
  v_result text:='';
  v_started boolean:=false;
BEGIN
  IF p_start_utf16<0 OR p_end_utf16<=p_start_utf16 THEN
    RAISE EXCEPTION 'r6d_public_text_utf16_range_invalid' USING ERRCODE='22023';
  END IF;
  FOR v_index IN 1..char_length(p_text)
  LOOP
    v_character:=substr(p_text,v_index,1);
    v_units:=CASE WHEN ascii(v_character)>65535 THEN 2 ELSE 1 END;
    IF v_position=p_start_utf16 THEN
      v_started:=true;
    ELSIF NOT v_started AND v_position>p_start_utf16 THEN
      RAISE EXCEPTION 'r6d_public_text_utf16_boundary_invalid'
        USING ERRCODE='22023';
    END IF;
    IF v_started AND v_position<p_end_utf16 THEN
      IF v_position+v_units>p_end_utf16 THEN
        RAISE EXCEPTION 'r6d_public_text_utf16_boundary_invalid'
          USING ERRCODE='22023';
      END IF;
      v_result:=v_result||v_character;
    END IF;
    v_position:=v_position+v_units;
    EXIT WHEN v_position=p_end_utf16;
    IF v_position>p_end_utf16 THEN
      RAISE EXCEPTION 'r6d_public_text_utf16_boundary_invalid'
        USING ERRCODE='22023';
    END IF;
  END LOOP;
  IF NOT v_started OR v_position<>p_end_utf16 THEN
    RAISE EXCEPTION 'r6d_public_text_utf16_range_invalid' USING ERRCODE='22023';
  END IF;
  RETURN v_result;
END
$$;
ALTER FUNCTION editorial.r6d_utf16_slice_v1(text,integer,integer)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.r6d_utf16_slice_v1(text,integer,integer)
  FROM PUBLIC;

-- The writer accepts only an owner-built, closed archive. Public text itself
-- is used only to verify its canonical digest and is never copied into the
-- assessment/finding/audit receipt graph.
CREATE OR REPLACE FUNCTION editorial.record_named_person_publication_assessment_v1(
  p_request jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,core,ops,extensions,pg_temp
AS $$
DECLARE
  v_case editorial.cases%ROWTYPE;
  v_snapshot editorial.review_snapshots%ROWTYPE;
  v_policy editorial.named_person_publication_policies%ROWTYPE;
  v_existing editorial.named_person_publication_assessments%ROWTYPE;
  v_assessment_id uuid:=gen_random_uuid();
  v_case_id uuid;
  v_snapshot_id uuid;
  v_state editorial.publication_state;
  v_context text;
  v_public_payload jsonb;
  v_scan jsonb;
  v_findings jsonb;
  v_override jsonb;
  v_actor_id uuid;
  v_actor_jti uuid;
  v_request_id uuid;
  v_idempotency char(64);
  v_request_digest char(64);
  v_public_payload_sha char(64);
  v_public_text_sha char(64);
  v_ruleset_version text;
  v_ruleset_sha char(64);
  v_registered_set_sha char(64);
  v_actual_registered_set_sha char(64);
  v_finding_rows jsonb:='[]'::jsonb;
  v_finding_set jsonb;
  v_finding_set_digest char(64);
  v_finding_count integer;
  v_assessment_payload jsonb;
  v_assessment_canonical bytea;
  v_assessment_digest char(64);
  v_assessment_receipt char(64);
  v_assessment_audit uuid;
  v_assessment_audit_digest char(64);
  v_override_result jsonb;
  v_now timestamptz:=clock_timestamp();
  v_item jsonb;
  v_finding_payload jsonb;
  v_finding_canonical bytea;
  v_finding_digest char(64);
  v_finding_identity_digest char(64);
  v_ordinal integer;
  v_detector text;
  v_context_id uuid;
  v_person_node_id uuid;
  v_topology_digest char(64);
  v_person_name_digest char(64);
  v_pointer_text text;
  v_matched_text text;
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_request))<>19
     OR NOT p_request ?& ARRAY[
       'caseId','reviewSnapshotId','publicationState','guardContext',
       'publicPayload','publicPayloadSha256','scan','legalOverride',
       '_actorId','_actorAssertionJti','_actorAssuranceLevel',
       '_actorEffectiveCapability',
       '_actorActionDigest','_actorStepUpAuthorizationId',
       '_actorIdempotencyKeySha256','_actorRequestKeySha256',
       '_requestId','_idempotencyKeySha256','_requestSha256'
     ] THEN
    RAISE EXCEPTION 'named_person_assessment_request_invalid'
      USING ERRCODE='22023';
  END IF;
  BEGIN
    v_case_id:=NULLIF(p_request->>'caseId','')::uuid;
    v_snapshot_id:=NULLIF(p_request->>'reviewSnapshotId','')::uuid;
    v_state:=NULLIF(p_request->>'publicationState','')::editorial.publication_state;
    v_context:=NULLIF(p_request->>'guardContext','');
    v_actor_id:=NULLIF(p_request->>'_actorId','')::uuid;
    v_actor_jti:=NULLIF(p_request->>'_actorAssertionJti','')::uuid;
    v_request_id:=NULLIF(p_request->>'_requestId','')::uuid;
    v_idempotency:=NULLIF(
      p_request->>'_idempotencyKeySha256',''
    )::char(64);
    v_request_digest:=NULLIF(p_request->>'_requestSha256','')::char(64);
    v_public_payload_sha:=NULLIF(
      p_request->>'publicPayloadSha256',''
    )::char(64);
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'named_person_assessment_request_invalid'
      USING ERRCODE='22023';
  END;
  v_public_payload:=p_request->'publicPayload';
  v_scan:=p_request->'scan';
  v_override:=p_request->'legalOverride';
  IF v_case_id IS NULL OR v_snapshot_id IS NULL OR v_actor_id IS NULL
     OR v_actor_jti IS NULL OR v_request_id IS NULL
     OR v_context IS NULL
     OR v_context NOT IN ('PREVIEW','PUBLISH','CORRECTION')
     OR v_state IS NULL
     OR (v_context IN ('PREVIEW','PUBLISH') AND v_state NOT IN (
       'PUBLISHED_ANOMALY','PUBLISHED_EXPLAINED','OFFICIALLY_CONFIRMED'
     ))
     OR (v_context='CORRECTION' AND v_state<>'CORRECTED')
     OR v_public_payload IS NULL OR jsonb_typeof(v_public_payload)<>'object'
     OR v_scan IS NULL OR jsonb_typeof(v_scan)<>'object'
     OR (v_override IS NOT NULL AND jsonb_typeof(v_override)<>'null'
         AND jsonb_typeof(v_override)<>'object')
     OR p_request->>'_actorEffectiveCapability' IS DISTINCT FROM (CASE v_context
          WHEN 'PREVIEW' THEN 'publication.preview'
          WHEN 'PUBLISH' THEN 'publication.publish'
          ELSE 'publication.correct' END)
     OR p_request->>'_actorAssuranceLevel'
          NOT IN ('ACTIVE_SESSION','RECENT_SESSION','STEP_UP')
     OR NOT ops.r6d_lower_sha256(v_public_payload_sha)
     OR NOT ops.r6d_lower_sha256(v_idempotency)
     OR NOT ops.r6d_lower_sha256(v_request_digest)
     OR p_request->>'_actorRequestKeySha256' IS DISTINCT FROM v_idempotency
     OR p_request->>'_actorIdempotencyKeySha256'
          IS DISTINCT FROM v_idempotency THEN
    RAISE EXCEPTION 'named_person_assessment_request_invalid'
      USING ERRCODE='22023';
  END IF;
  IF encode(extensions.digest(
       ops.canonical_jsonb_v1(v_public_payload),'sha256'
     ),'hex') IS DISTINCT FROM v_public_payload_sha THEN
    RAISE EXCEPTION 'named_person_public_payload_digest_mismatch'
      USING ERRCODE='23514';
  END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(v_scan))<>5
     OR NOT v_scan ?& ARRAY[
       'rulesetVersion','rulesetSha256','publicTextSha256',
       'registeredNameSetSha256','findings'
     ] THEN
    RAISE EXCEPTION 'named_person_scan_shape_invalid' USING ERRCODE='22023';
  END IF;
  v_ruleset_version:=NULLIF(v_scan->>'rulesetVersion','');
  v_ruleset_sha:=NULLIF(v_scan->>'rulesetSha256','')::char(64);
  v_public_text_sha:=NULLIF(v_scan->>'publicTextSha256','')::char(64);
  v_registered_set_sha:=NULLIF(
    v_scan->>'registeredNameSetSha256',''
  )::char(64);
  v_findings:=v_scan->'findings';
  IF v_ruleset_version IS NULL OR NOT ops.r6d_lower_sha256(v_ruleset_sha)
     OR NOT ops.r6d_lower_sha256(v_public_text_sha)
     OR NOT ops.r6d_lower_sha256(v_registered_set_sha)
     OR v_findings IS NULL OR jsonb_typeof(v_findings)<>'array'
     OR jsonb_array_length(v_findings)>10000 THEN
    RAISE EXCEPTION 'named_person_scan_shape_invalid' USING ERRCODE='22023';
  END IF;
  IF editorial.r6d_public_text_sha256_v1(v_public_payload)
       IS DISTINCT FROM v_public_text_sha THEN
    RAISE EXCEPTION 'named_person_public_text_digest_mismatch'
      USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_existing
  FROM editorial.named_person_publication_assessments
  WHERE idempotency_key_sha256=v_idempotency FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest IS DISTINCT FROM v_request_digest
       OR v_existing.case_id IS DISTINCT FROM v_case_id
       OR v_existing.review_snapshot_id IS DISTINCT FROM v_snapshot_id
       OR v_existing.publication_state IS DISTINCT FROM v_state
       OR v_existing.guard_context IS DISTINCT FROM v_context
       OR v_existing.public_payload_sha256 IS DISTINCT FROM v_public_payload_sha
       OR v_existing.public_text_sha256 IS DISTINCT FROM v_public_text_sha
       OR v_existing.ruleset_version IS DISTINCT FROM v_ruleset_version
       OR v_existing.ruleset_sha256 IS DISTINCT FROM v_ruleset_sha
       OR v_existing.registered_name_set_sha256
            IS DISTINCT FROM v_registered_set_sha THEN
      RAISE EXCEPTION 'named_person_assessment_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    v_override_result:=editorial.record_named_person_legal_override_v1(
      jsonb_build_object(
        'assessmentId',v_existing.assessment_id,
        'legalOverride',v_override,'_actorId',v_actor_id,
        '_actorAssertionJti',v_actor_jti,
        '_actorAssuranceLevel',p_request->'_actorAssuranceLevel',
        '_actorEffectiveCapability',p_request->'_actorEffectiveCapability',
        '_actorActionDigest',p_request->'_actorActionDigest',
        '_actorStepUpAuthorizationId',
          p_request->'_actorStepUpAuthorizationId',
        '_actorIdempotencyKeySha256',
          p_request->'_actorIdempotencyKeySha256',
        '_actorRequestKeySha256',p_request->'_actorRequestKeySha256',
        '_requestId',v_request_id,
        '_idempotencyKeySha256',btrim(v_idempotency),
        '_requestSha256',btrim(v_request_digest)
      )
    );
    RETURN jsonb_build_object(
      'assessmentId',v_existing.assessment_id,
      'assessmentDigest',btrim(v_existing.assessment_digest),
      'assessmentReceiptDigest',btrim(v_existing.receipt_digest),
      'assessmentAuditEventId',v_existing.audit_event_id,
      'assessmentOutcome',v_existing.outcome,
      'legalReviewRequired',v_existing.finding_count>0,
      'overrideId',v_override_result->'overrideId',
      'overrideReceiptDigest',v_override_result->'overrideReceiptDigest',
      'overrideAuditEventId',v_override_result->'overrideAuditEventId',
      'replayed',true
    );
  END IF;

  SELECT * INTO STRICT v_case FROM editorial.cases
  WHERE id=v_case_id FOR SHARE;
  SELECT * INTO STRICT v_snapshot FROM editorial.review_snapshots
  WHERE id=v_snapshot_id AND case_id=v_case_id FOR SHARE;
  IF v_case.current_review_snapshot_id IS DISTINCT FROM v_snapshot_id
     OR v_snapshot.case_version IS DISTINCT FROM v_case.version
     OR v_public_payload->>'caseId' IS DISTINCT FROM v_case_id::text
     OR v_public_payload->>'reviewSnapshotId' IS DISTINCT FROM v_snapshot_id::text
     OR v_public_payload->>'publicationState' IS DISTINCT FROM v_state::text THEN
    RAISE EXCEPTION 'named_person_assessment_scope_stale'
      USING ERRCODE='40001';
  END IF;
  SELECT * INTO STRICT v_policy
  FROM editorial.named_person_publication_policies
  WHERE policy_version='r6d-named-person-publication-v1'
    AND active AND effective_at<=v_now;
  IF v_ruleset_version IS DISTINCT FROM
       v_policy.policy_payload->>'scannerRulesetVersion'
     OR v_ruleset_sha IS DISTINCT FROM
       (v_policy.policy_payload->>'scannerRulesetSha256')::char(64) THEN
    RAISE EXCEPTION 'named_person_ruleset_authority_mismatch'
      USING ERRCODE='23514';
  END IF;

  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
    COALESCE(jsonb_agg(entry ORDER BY canonical),'[]'::jsonb)
  ),'sha256'),'hex')
  INTO v_actual_registered_set_sha
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
  IF v_actual_registered_set_sha IS DISTINCT FROM v_registered_set_sha THEN
    RAISE EXCEPTION 'named_person_registered_set_stale'
      USING ERRCODE='40001';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_findings)
  LOOP
    IF jsonb_typeof(v_item)<>'object'
       OR (SELECT count(*) FROM jsonb_object_keys(v_item))<>10
       OR NOT v_item ?& ARRAY[
         'ordinal','detectorKind','jsonPointer','startUtf16','endUtf16',
         'matchedTextSha256','personNodeId','topologyDigest','contextId',
         'personNameDigest'
       ] THEN
      RAISE EXCEPTION 'named_person_finding_shape_invalid'
        USING ERRCODE='22023';
    END IF;
    BEGIN
      v_ordinal:=NULLIF(v_item->>'ordinal','')::integer;
      v_detector:=NULLIF(v_item->>'detectorKind','');
      v_context_id:=NULLIF(v_item->>'contextId','')::uuid;
      v_person_node_id:=NULLIF(v_item->>'personNodeId','')::uuid;
      v_topology_digest:=NULLIF(v_item->>'topologyDigest','')::char(64);
      v_person_name_digest:=NULLIF(
        v_item->>'personNameDigest',''
      )::char(64);
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'named_person_finding_shape_invalid'
        USING ERRCODE='22023';
    END;
    IF v_ordinal IS DISTINCT FROM jsonb_array_length(v_finding_rows)
       OR v_detector NOT IN (
         'REGISTERED_PERSON_EXACT','TITLE_ADJACENT_KOREAN_NAME'
       )
       OR COALESCE(v_item->>'jsonPointer','')
            !~ '^(/([^/~]|~[01])*)+$'
       OR COALESCE(v_item->>'startUtf16','') !~ '^(0|[1-9][0-9]*)$'
       OR COALESCE(v_item->>'endUtf16','') !~ '^[1-9][0-9]*$'
       OR (v_item->>'endUtf16')::bigint<=(v_item->>'startUtf16')::bigint
       OR NOT ops.r6d_lower_sha256(v_item->>'matchedTextSha256')
       OR (
         v_detector='REGISTERED_PERSON_EXACT' AND (
           num_nonnulls(
             v_context_id,v_person_node_id,v_topology_digest,
             v_person_name_digest
           )<>4
           OR NOT ops.r6d_lower_sha256(v_topology_digest)
           OR NOT ops.r6d_lower_sha256(v_person_name_digest)
           OR NOT EXISTS(
             SELECT 1 FROM core.list_publication_person_names_v1() AS person
             WHERE person.context_id=v_context_id
               AND person.person_node_id=v_person_node_id
               AND person.topology_digest=v_topology_digest
               AND person.person_name_digest=v_person_name_digest
           )
         )
       )
       OR (
         v_detector='TITLE_ADJACENT_KOREAN_NAME'
         AND num_nonnulls(
           v_context_id,v_person_node_id,v_topology_digest,v_person_name_digest
         )<>0
       ) THEN
      RAISE EXCEPTION 'named_person_finding_binding_invalid'
        USING ERRCODE='23514';
    END IF;
    v_pointer_text:=editorial.r6d_json_pointer_text_v1(
      v_public_payload,v_item->>'jsonPointer'
    );
    v_matched_text:=editorial.r6d_utf16_slice_v1(
      v_pointer_text,(v_item->>'startUtf16')::integer,
      (v_item->>'endUtf16')::integer
    );
    IF encode(extensions.digest(
         convert_to(v_matched_text,'UTF8'),'sha256'
       ),'hex') IS DISTINCT FROM v_item->>'matchedTextSha256' THEN
      RAISE EXCEPTION 'named_person_finding_matched_text_digest_invalid'
        USING ERRCODE='23514';
    END IF;
    v_finding_payload:=jsonb_build_object(
      'schemaVersion','named-person-publication-finding.v1',
      'assessmentId',v_assessment_id,'ordinal',v_ordinal,
      'detectorKind',v_detector,'jsonPointer',v_item->>'jsonPointer',
      'startUtf16',(v_item->>'startUtf16')::integer,
      'endUtf16',(v_item->>'endUtf16')::integer,
      'matchedTextSha256',v_item->>'matchedTextSha256',
      'rulesetVersion',v_ruleset_version,
      'personBinding',CASE WHEN v_detector='REGISTERED_PERSON_EXACT'
        THEN jsonb_build_object(
          'contextId',v_context_id,'personNodeId',v_person_node_id,
          'topologyDigest',btrim(v_topology_digest),
          'personNameDigest',btrim(v_person_name_digest)
        ) ELSE NULL END
    );
    v_finding_canonical:=ops.canonical_jsonb_v1(v_finding_payload);
    v_finding_digest:=encode(
      extensions.digest(v_finding_canonical,'sha256'),'hex'
    );
    v_finding_identity_digest:=
      editorial.named_person_finding_identity_digest_v1(
        v_ordinal,v_detector,v_item->>'jsonPointer',
        (v_item->>'startUtf16')::integer,(v_item->>'endUtf16')::integer,
        v_item->>'matchedTextSha256',v_ruleset_version,v_context_id,
        v_person_node_id,btrim(v_topology_digest),btrim(v_person_name_digest)
      );
    v_finding_rows:=v_finding_rows||jsonb_build_array(jsonb_build_object(
      'payload',v_finding_payload,
      'canonical',encode(v_finding_canonical,'base64'),
      'digest',v_finding_digest,
      'identityDigest',btrim(v_finding_identity_digest)
    ));
  END LOOP;
  v_finding_count:=jsonb_array_length(v_finding_rows);
  v_finding_set:=COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'ordinal',(entry->'payload'->>'ordinal')::integer,
      'findingIdentityDigest',entry->>'identityDigest'
    ) ORDER BY (entry->'payload'->>'ordinal')::integer)
    FROM jsonb_array_elements(v_finding_rows) AS rows(entry)
  ),'[]'::jsonb);
  v_finding_set_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_finding_set),'sha256'
  ),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(concat_ws(':',
    v_case.id::text,v_case.version::text,v_snapshot.id::text,v_state::text,
    v_context,btrim(v_public_payload_sha),btrim(v_public_text_sha),
    btrim(v_policy.policy_digest),btrim(v_ruleset_sha),
    btrim(v_registered_set_sha)
  ),0));
  SELECT * INTO v_existing
  FROM editorial.named_person_publication_assessments AS assessment
  WHERE assessment.case_id=v_case.id
    AND assessment.case_version=v_case.version
    AND assessment.review_snapshot_id=v_snapshot.id
    AND assessment.publication_state=v_state
    AND assessment.guard_context=v_context
    AND assessment.public_payload_sha256=v_public_payload_sha
    AND assessment.public_text_sha256=v_public_text_sha
    AND assessment.policy_digest=v_policy.policy_digest
    AND assessment.ruleset_sha256=v_ruleset_sha
    AND assessment.registered_name_set_sha256=v_registered_set_sha
  FOR SHARE;
  IF FOUND THEN
    IF v_existing.review_snapshot_digest
         IS DISTINCT FROM v_snapshot.snapshot_sha256
       OR v_existing.policy_version IS DISTINCT FROM v_policy.policy_version
       OR v_existing.ruleset_version IS DISTINCT FROM v_ruleset_version
       OR v_existing.finding_count IS DISTINCT FROM v_finding_count
       OR v_existing.finding_set_digest IS DISTINCT FROM v_finding_set_digest
       OR v_existing.outcome IS DISTINCT FROM (CASE WHEN v_finding_count=0
            THEN 'PASS' ELSE 'BLOCKED' END) THEN
      RAISE EXCEPTION 'named_person_assessment_exact_binding_conflict'
        USING ERRCODE='40001';
    END IF;
    v_override_result:=editorial.record_named_person_legal_override_v1(
      jsonb_build_object(
        'assessmentId',v_existing.assessment_id,
        'legalOverride',v_override,'_actorId',v_actor_id,
        '_actorAssertionJti',v_actor_jti,
        '_actorAssuranceLevel',p_request->'_actorAssuranceLevel',
        '_actorEffectiveCapability',p_request->'_actorEffectiveCapability',
        '_actorActionDigest',p_request->'_actorActionDigest',
        '_actorStepUpAuthorizationId',
          p_request->'_actorStepUpAuthorizationId',
        '_actorIdempotencyKeySha256',
          p_request->'_actorIdempotencyKeySha256',
        '_actorRequestKeySha256',p_request->'_actorRequestKeySha256',
        '_requestId',v_request_id,
        '_idempotencyKeySha256',btrim(v_idempotency),
        '_requestSha256',btrim(v_request_digest)
      )
    );
    RETURN jsonb_build_object(
      'assessmentId',v_existing.assessment_id,
      'assessmentDigest',btrim(v_existing.assessment_digest),
      'assessmentReceiptDigest',btrim(v_existing.receipt_digest),
      'assessmentAuditEventId',v_existing.audit_event_id,
      'assessmentOutcome',v_existing.outcome,
      'legalReviewRequired',v_existing.finding_count>0,
      'overrideId',v_override_result->'overrideId',
      'overrideReceiptDigest',v_override_result->'overrideReceiptDigest',
      'overrideAuditEventId',v_override_result->'overrideAuditEventId',
      'replayed',true
    );
  END IF;
  v_assessment_payload:=jsonb_build_object(
    'schemaVersion','named-person-publication-assessment.v1',
    'assessmentId',v_assessment_id,'caseId',v_case.id,
    'caseVersion',v_case.version,'reviewSnapshotId',v_snapshot.id,
    'reviewSnapshotDigest',btrim(v_snapshot.snapshot_sha256),
    'publicationState',v_state,'guardContext',v_context,
    'publicPayloadSha256',btrim(v_public_payload_sha),
    'publicTextSha256',btrim(v_public_text_sha),
    'policyVersion',v_policy.policy_version,
    'policyDigest',btrim(v_policy.policy_digest),
    'rulesetVersion',v_ruleset_version,
    'rulesetSha256',btrim(v_ruleset_sha),
    'registeredNameSetSha256',btrim(v_registered_set_sha),
    'findingCount',v_finding_count,
    'findingSetDigest',btrim(v_finding_set_digest),
    'outcome',CASE WHEN v_finding_count=0 THEN 'PASS' ELSE 'BLOCKED' END,
    'requestDigest',btrim(v_request_digest),
    'evaluatedAt',v_now
  );
  v_assessment_canonical:=ops.canonical_jsonb_v1(v_assessment_payload);
  v_assessment_digest:=encode(
    extensions.digest(v_assessment_canonical,'sha256'),'hex'
  );
  v_assessment_audit:=ops.append_audit_event(
    'publication-guard:'||v_case.id::text,'SERVICE','control-api',NULL::uuid,
    'publication.named_person.assess','PublicationAssessment',
    v_assessment_id::text,
    CASE v_context WHEN 'PREVIEW' THEN 'publication.preview'
      WHEN 'PUBLISH' THEN 'publication.publish'
      ELSE 'publication.correct' END,
    'SUCCESS',NULL,v_request_id,jsonb_build_object(
      'assessmentDigest',v_assessment_digest,
      'publicPayloadSha256',btrim(v_public_payload_sha),
      'publicTextSha256',btrim(v_public_text_sha),
      'policyDigest',btrim(v_policy.policy_digest),
      'rulesetSha256',btrim(v_ruleset_sha),
      'registeredNameSetSha256',btrim(v_registered_set_sha),
      'findingCount',v_finding_count,
      'findingSetDigest',btrim(v_finding_set_digest),
      'guardContext',v_context
    )
  );
  SELECT event_hash INTO STRICT v_assessment_audit_digest
  FROM ops.audit_events WHERE id=v_assessment_audit;
  v_assessment_receipt:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','named-person-publication-assessment-receipt.v1',
      'assessmentId',v_assessment_id,
      'assessmentDigest',v_assessment_digest,
      'auditEventId',v_assessment_audit,
      'auditEventDigest',btrim(v_assessment_audit_digest),
      'requestId',v_request_id,'requestDigest',btrim(v_request_digest)
    )),'sha256'
  ),'hex');
  INSERT INTO editorial.named_person_publication_assessments(
    assessment_id,case_id,case_version,review_snapshot_id,
    review_snapshot_digest,publication_state,guard_context,
    public_payload_sha256,public_text_sha256,policy_version,policy_digest,
    ruleset_version,ruleset_sha256,registered_name_set_sha256,
    finding_count,finding_set_digest,outcome,evaluated_actor_type,
    evaluated_actor_id,request_id,idempotency_key_sha256,request_digest,
    audit_event_id,assessment_payload,assessment_canonical,
    assessment_digest,receipt_digest,evaluated_at
  ) VALUES(
    v_assessment_id,v_case.id,v_case.version,v_snapshot.id,
    v_snapshot.snapshot_sha256,v_state,v_context,v_public_payload_sha,
    v_public_text_sha,v_policy.policy_version,v_policy.policy_digest,
    v_ruleset_version,v_ruleset_sha,v_registered_set_sha,v_finding_count,
    v_finding_set_digest,
    CASE WHEN v_finding_count=0 THEN 'PASS' ELSE 'BLOCKED' END,
    'SERVICE','control-api',v_request_id,
    v_idempotency,v_request_digest,v_assessment_audit,v_assessment_payload,
    v_assessment_canonical,v_assessment_digest,v_assessment_receipt,v_now
  );
  INSERT INTO editorial.named_person_publication_findings(
    assessment_id,ordinal,detector_kind,json_pointer,start_utf16,end_utf16,
    matched_text_sha256,ruleset_version,context_id,person_node_id,
    topology_digest,person_name_digest,finding_payload,finding_canonical,
    finding_digest,finding_identity_digest
  )
  SELECT v_assessment_id,
    (entry->'payload'->>'ordinal')::integer,
    entry->'payload'->>'detectorKind',
    entry->'payload'->>'jsonPointer',
    (entry->'payload'->>'startUtf16')::integer,
    (entry->'payload'->>'endUtf16')::integer,
    (entry->'payload'->>'matchedTextSha256')::char(64),
    entry->'payload'->>'rulesetVersion',
    NULLIF(entry->'payload'->'personBinding'->>'contextId','')::uuid,
    NULLIF(entry->'payload'->'personBinding'->>'personNodeId','')::uuid,
    NULLIF(entry->'payload'->'personBinding'->>'topologyDigest','')::char(64),
    NULLIF(entry->'payload'->'personBinding'->>'personNameDigest','')::char(64),
    entry->'payload',decode(entry->>'canonical','base64'),
    (entry->>'digest')::char(64),(entry->>'identityDigest')::char(64)
  FROM jsonb_array_elements(v_finding_rows) AS rows(entry)
  ORDER BY (entry->'payload'->>'ordinal')::integer;
  v_override_result:=editorial.record_named_person_legal_override_v1(
    jsonb_build_object(
      'assessmentId',v_assessment_id,'legalOverride',v_override,
      '_actorId',v_actor_id,'_actorAssertionJti',v_actor_jti,
      '_actorAssuranceLevel',p_request->'_actorAssuranceLevel',
      '_actorEffectiveCapability',p_request->'_actorEffectiveCapability',
      '_actorActionDigest',p_request->'_actorActionDigest',
      '_actorStepUpAuthorizationId',p_request->'_actorStepUpAuthorizationId',
      '_actorIdempotencyKeySha256',
        p_request->'_actorIdempotencyKeySha256',
      '_actorRequestKeySha256',p_request->'_actorRequestKeySha256',
      '_requestId',v_request_id,
      '_idempotencyKeySha256',btrim(v_idempotency),
      '_requestSha256',btrim(v_request_digest)
    )
  );
  RETURN jsonb_build_object(
    'assessmentId',v_assessment_id,
    'assessmentDigest',btrim(v_assessment_digest),
    'assessmentReceiptDigest',btrim(v_assessment_receipt),
    'assessmentAuditEventId',v_assessment_audit,
    'assessmentOutcome',CASE WHEN v_finding_count=0 THEN 'PASS' ELSE 'BLOCKED' END,
    'legalReviewRequired',v_finding_count>0,
    'overrideId',v_override_result->'overrideId',
    'overrideReceiptDigest',v_override_result->'overrideReceiptDigest',
    'overrideAuditEventId',v_override_result->'overrideAuditEventId',
    'replayed',false
  );
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'named_person_assessment_authority_missing_or_ambiguous'
    USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.record_named_person_publication_assessment_v1(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.record_named_person_publication_assessment_v1(jsonb)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.record_named_person_publication_assessment_v1(jsonb)
  TO gurine_control_api;

-- V2 permits only one provenance reuse: a PUBLISH assessment may consume an
-- immutable PREVIEW override when every scanner and payload binding is byte
-- exact. CORRECTION never reuses PREVIEW/PUBLISH authority.
CREATE OR REPLACE FUNCTION editorial.assert_r6d_publication_guard_v2(
  p_case_id uuid,
  p_review_snapshot_id uuid,
  p_publication_state editorial.publication_state,
  p_public_payload jsonb,
  p_public_payload_sha256 char(64),
  p_guard_context text
) RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,core,ops,extensions,pg_temp
AS $$
DECLARE
  v_case editorial.cases%ROWTYPE;
  v_snapshot editorial.review_snapshots%ROWTYPE;
  v_policy editorial.named_person_publication_policies%ROWTYPE;
  v_assessment editorial.named_person_publication_assessments%ROWTYPE;
  v_digest char(64);
  v_finding_count bigint;
  v_finding_set char(64);
  v_registered_name_set_sha256 char(64);
BEGIN
  IF p_case_id IS NULL OR p_review_snapshot_id IS NULL
     OR p_publication_state IS NULL OR p_public_payload IS NULL
     OR jsonb_typeof(p_public_payload)<>'object'
     OR p_guard_context NOT IN ('PREVIEW','PUBLISH','CORRECTION')
     OR (p_guard_context IN ('PREVIEW','PUBLISH')
       AND p_publication_state NOT IN (
         'PUBLISHED_ANOMALY','PUBLISHED_EXPLAINED','OFFICIALLY_CONFIRMED'
       ))
     OR (p_guard_context='CORRECTION'
       AND p_publication_state<>'CORRECTED')
     OR NOT ops.r6d_lower_sha256(p_public_payload_sha256) THEN
    RAISE EXCEPTION 'r6d_publication_guard_input_invalid'
      USING ERRCODE='22023';
  END IF;
  v_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(p_public_payload),'sha256'
  ),'hex');
  IF v_digest IS DISTINCT FROM p_public_payload_sha256 THEN
    RAISE EXCEPTION 'r6d_publication_payload_digest_mismatch'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO STRICT v_case FROM editorial.cases
  WHERE id=p_case_id FOR SHARE;
  SELECT * INTO STRICT v_snapshot FROM editorial.review_snapshots
  WHERE id=p_review_snapshot_id AND case_id=p_case_id FOR SHARE;
  IF v_case.current_review_snapshot_id IS DISTINCT FROM p_review_snapshot_id
     OR v_snapshot.case_version IS DISTINCT FROM v_case.version THEN
    RAISE EXCEPTION 'r6d_publication_snapshot_not_current'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO STRICT v_policy
  FROM editorial.named_person_publication_policies
  WHERE policy_version='r6d-named-person-publication-v1' AND active
    AND effective_at<=clock_timestamp();
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
    COALESCE(jsonb_agg(entry ORDER BY canonical),'[]'::jsonb)
  ),'sha256'),'hex')
  INTO v_registered_name_set_sha256
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
  SELECT * INTO v_assessment
  FROM editorial.named_person_publication_assessments AS assessment
  WHERE assessment.case_id=p_case_id
    AND assessment.case_version=v_case.version
    AND assessment.review_snapshot_id=p_review_snapshot_id
    AND assessment.review_snapshot_digest=v_snapshot.snapshot_sha256
    AND assessment.publication_state=p_publication_state
    AND assessment.guard_context=p_guard_context
    AND assessment.public_payload_sha256=v_digest
    AND assessment.policy_version=v_policy.policy_version
    AND assessment.policy_digest=v_policy.policy_digest
    AND assessment.ruleset_version=
      v_policy.policy_payload->>'scannerRulesetVersion'
    AND assessment.ruleset_sha256=
      (v_policy.policy_payload->>'scannerRulesetSha256')::char(64)
    AND assessment.registered_name_set_sha256=
      v_registered_name_set_sha256
    AND assessment.outcome=CASE WHEN assessment.finding_count=0
      THEN 'PASS' ELSE 'BLOCKED' END
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'r6d_named_person_assessment_missing_or_blocked'
      USING ERRCODE='23514';
  END IF;
  SELECT count(*),encode(extensions.digest(ops.canonical_jsonb_v1(
    COALESCE(jsonb_agg(jsonb_build_object(
      'ordinal',finding.ordinal,
      'findingIdentityDigest',btrim(finding.finding_identity_digest)
    ) ORDER BY finding.ordinal),'[]'::jsonb)
  ),'sha256'),'hex')
  INTO v_finding_count,v_finding_set
  FROM editorial.named_person_publication_findings AS finding
  WHERE finding.assessment_id=v_assessment.assessment_id;
  IF v_finding_count IS DISTINCT FROM v_assessment.finding_count
     OR v_finding_set IS DISTINCT FROM v_assessment.finding_set_digest THEN
    RAISE EXCEPTION 'r6d_named_person_finding_set_mismatch'
      USING ERRCODE='23514';
  END IF;
  IF p_guard_context='PUBLISH' AND NOT EXISTS(
    SELECT 1
    FROM editorial.named_person_publication_assessments AS source
    JOIN editorial.publication_preview_owner_receipts_v2 AS receipt
      ON receipt.assessment_id=source.assessment_id
      AND receipt.case_id=source.case_id
      AND receipt.case_version=source.case_version
      AND receipt.review_snapshot_id=source.review_snapshot_id
      AND receipt.public_payload_sha256=source.public_payload_sha256
      AND receipt.assessment_digest=source.assessment_digest
      AND receipt.assessment_receipt_digest=source.receipt_digest
    JOIN editorial.publication_previews AS preview
      ON preview.id=receipt.preview_id
      AND preview.case_id=source.case_id
      AND preview.review_snapshot_id=source.review_snapshot_id
      AND preview.preview_sha256=source.public_payload_sha256
      AND preview.preview_payload=p_public_payload
      AND preview.expires_at>clock_timestamp()
    WHERE source.case_id=v_assessment.case_id
      AND source.case_version=v_assessment.case_version
      AND source.review_snapshot_id=v_assessment.review_snapshot_id
      AND source.review_snapshot_digest=v_assessment.review_snapshot_digest
      AND source.publication_state=v_assessment.publication_state
      AND source.guard_context='PREVIEW'
      AND source.public_payload_sha256=v_assessment.public_payload_sha256
      AND source.public_text_sha256=v_assessment.public_text_sha256
      AND source.policy_version=v_assessment.policy_version
      AND source.policy_digest=v_assessment.policy_digest
      AND source.ruleset_version=v_assessment.ruleset_version
      AND source.ruleset_sha256=v_assessment.ruleset_sha256
      AND source.registered_name_set_sha256=
        v_assessment.registered_name_set_sha256
      AND source.finding_count=v_assessment.finding_count
      AND source.finding_set_digest=v_assessment.finding_set_digest
      AND source.outcome=v_assessment.outcome
  ) THEN
    RAISE EXCEPTION 'r6d_publish_preview_assessment_not_exact_or_expired'
      USING ERRCODE='23514';
  END IF;
  IF p_guard_context IN ('PUBLISH','CORRECTION') AND NOT EXISTS(
    SELECT 1
    FROM editorial.review_decisions AS decision
    JOIN editorial.named_person_review_stage_receipts_v1 AS stage
      ON stage.decision_id=decision.id
      AND stage.review_snapshot_id=v_assessment.review_snapshot_id
      AND stage.case_id=v_assessment.case_id
      AND stage.case_version=v_assessment.case_version
      AND stage.review_stage='EDITORIAL'
      AND stage.decision='APPROVE'
      AND stage.reviewer_user_id=decision.reviewer_id
      AND stage.decision_digest=
        editorial.review_decision_digest_v1(decision.id)
      AND stage.assurance_level='STEP_UP'
      AND stage.effective_capability='review.editorial'
    JOIN editorial.review_assignments AS assignment
      ON assignment.id=stage.review_assignment_id
      AND assignment.case_id=stage.case_id
      AND assignment.review_snapshot_id=stage.review_snapshot_id
      AND assignment.reviewer_id=stage.reviewer_user_id
      AND assignment.status='COMPLETED'
      AND assignment.completed_at IS NOT NULL
      AND assignment.version=stage.review_assignment_version_after
    JOIN ops.outbox AS outbox ON outbox.id=stage.outbox_event_id
      AND outbox.event_type='review.decision_submitted.v1'
      AND outbox.aggregate_type='ReviewDecision'
      AND outbox.aggregate_id=stage.decision_id::text
      AND outbox.aggregate_version=1
    WHERE decision.review_snapshot_id=v_assessment.review_snapshot_id
      AND decision.decision='APPROVE'
      AND decision.reviewer_id<>v_snapshot.created_by
      AND jsonb_typeof(decision.criteria)='object'
      AND NOT (decision.criteria ? 'namedIndividualOverride')
      AND stage.receipt_payload->>'decisionDigest'=
        btrim(stage.decision_digest)
      AND stage.receipt_payload->>'reviewerAuthorityDigest'=
        btrim(stage.reviewer_authority_digest)
      AND stage.receipt_payload->>'outboxEventDigest'=
        btrim(stage.outbox_event_digest)
      AND stage.outbox_event_digest=
        ops.r6d_outbox_envelope_digest_v1(outbox.id)
  ) THEN
    RAISE EXCEPTION 'r6d_independent_editorial_review_required'
      USING ERRCODE='23514';
  END IF;
  IF v_finding_count>0 AND p_guard_context<>'PREVIEW' AND NOT EXISTS(
    SELECT 1
    FROM editorial.named_person_publication_assessments AS source
    JOIN editorial.named_person_legal_overrides AS override
      ON override.assessment_id=source.assessment_id
      AND override.public_text_sha256=source.public_text_sha256
      AND override.ruleset_version=source.ruleset_version
    JOIN editorial.review_snapshots AS source_snapshot
      ON source_snapshot.id=source.review_snapshot_id
      AND source_snapshot.case_id=source.case_id
    JOIN editorial.review_decisions AS decision
      ON decision.id=override.editorial_review_decision_id
      AND decision.review_snapshot_id=source.review_snapshot_id
      AND decision.decision='APPROVE'
      AND decision.reviewer_id=override.editorial_reviewer_user_id
      AND jsonb_typeof(decision.criteria)='object'
      AND NOT (decision.criteria ? 'namedIndividualOverride')
    JOIN editorial.named_person_review_stage_receipts_v1 AS editorial_stage
      ON editorial_stage.receipt_id=
        override.editorial_review_stage_receipt_id
      AND editorial_stage.decision_id=decision.id
      AND editorial_stage.review_snapshot_id=source.review_snapshot_id
      AND editorial_stage.case_id=source.case_id
      AND editorial_stage.case_version=source.case_version
      AND editorial_stage.review_stage='EDITORIAL'
      AND editorial_stage.decision='APPROVE'
      AND editorial_stage.reviewer_user_id=decision.reviewer_id
      AND editorial_stage.receipt_digest=
        override.editorial_review_stage_receipt_digest
    JOIN editorial.review_decisions AS legal_decision
      ON legal_decision.review_snapshot_id=source.review_snapshot_id
      AND legal_decision.reviewer_id=override.legal_reviewer_user_id
      AND legal_decision.decision='APPROVE'
      AND jsonb_typeof(legal_decision.criteria)='object'
      AND jsonb_typeof(
        legal_decision.criteria->'namedIndividualOverride'
      )='object'
    JOIN editorial.named_person_review_stage_receipts_v1 AS legal_stage
      ON legal_stage.decision_id=legal_decision.id
      AND legal_stage.review_snapshot_id=source.review_snapshot_id
      AND legal_stage.case_id=source.case_id
      AND legal_stage.case_version=source.case_version
      AND legal_stage.review_stage='LEGAL'
      AND legal_stage.decision='APPROVE'
      AND legal_stage.reviewer_user_id=legal_decision.reviewer_id
      AND legal_stage.decision_digest=
        editorial.review_decision_digest_v1(legal_decision.id)
      AND legal_stage.actor_assertion_jti=override.actor_assertion_jti
      AND legal_stage.step_up_authorization_id=
        override.step_up_authorization_id
      AND legal_stage.step_up_receipt_digest=override.step_up_receipt_digest
      AND legal_stage.referenced_editorial_decision_id=decision.id
      AND legal_stage.referenced_editorial_stage_receipt_id=
        editorial_stage.receipt_id
      AND legal_stage.referenced_editorial_stage_receipt_digest=
        editorial_stage.receipt_digest
      AND legal_stage.named_person_override_id=override.override_id
      AND legal_stage.named_person_override_digest=override.override_digest
    WHERE source.outcome=CASE WHEN source.finding_count=0
      THEN 'PASS' ELSE 'BLOCKED' END
      AND source.case_id=v_assessment.case_id
      AND source.case_version=v_assessment.case_version
      AND source.review_snapshot_id=v_assessment.review_snapshot_id
      AND source.review_snapshot_digest=v_assessment.review_snapshot_digest
      AND source.publication_state=v_assessment.publication_state
      AND source.public_payload_sha256=v_assessment.public_payload_sha256
      AND source.public_text_sha256=v_assessment.public_text_sha256
      AND source.policy_version=v_assessment.policy_version
      AND source.policy_digest=v_assessment.policy_digest
      AND source.ruleset_version=v_assessment.ruleset_version
      AND source.ruleset_sha256=v_assessment.ruleset_sha256
      AND source.registered_name_set_sha256=
        v_assessment.registered_name_set_sha256
      AND source.finding_count=v_assessment.finding_count
      AND source.finding_set_digest=v_assessment.finding_set_digest
      AND (
        (
          p_guard_context IN ('PREVIEW','CORRECTION')
          AND source.assessment_id=v_assessment.assessment_id
          AND source.guard_context=p_guard_context
        )
        OR (
          p_guard_context='PUBLISH' AND source.guard_context='PREVIEW'
        )
      )
      AND override.publication_author_user_id=source_snapshot.created_by
      AND override.legal_reviewer_user_id<>source_snapshot.created_by
      AND override.legal_reviewer_user_id<>decision.reviewer_id
      AND decision.reviewer_id<>source_snapshot.created_by
      AND decision.created_at<override.reviewed_at
      AND legal_decision.created_at>=override.reviewed_at
      AND (SELECT count(*) FROM jsonb_object_keys(
        legal_decision.criteria->'namedIndividualOverride'
      ))=5
      AND legal_decision.criteria->'namedIndividualOverride' ?& ARRAY[
        'publicTextSha256','reasonCode','officialSourceLocator',
        'officialSourceSha256','editorialReviewDecisionId'
      ]
      AND legal_decision.criteria->'namedIndividualOverride'
            ->>'publicTextSha256'=btrim(override.public_text_sha256)
      AND legal_decision.criteria->'namedIndividualOverride'
            ->>'reasonCode'=override.reason_code
      AND legal_decision.criteria->'namedIndividualOverride'
            ->>'officialSourceLocator'=override.official_source_locator
      AND legal_decision.criteria->'namedIndividualOverride'
            ->>'officialSourceSha256'=btrim(override.official_source_sha256)
      AND legal_decision.criteria->'namedIndividualOverride'
            ->>'editorialReviewDecisionId'=decision.id::text
      AND override.editorial_review_decision_digest=
        editorial.review_decision_digest_v1(decision.id)
      AND editorial_stage.decision_digest=
        override.editorial_review_decision_digest
      AND editorial_stage.assurance_level='STEP_UP'
      AND editorial_stage.effective_capability='review.editorial'
      AND legal_stage.assurance_level='STEP_UP'
      AND legal_stage.effective_capability='review.legal'
      AND editorial_stage.reviewer_authority_digest=
        override.editorial_reviewer_authority_digest
      AND legal_stage.reviewer_authority_digest=
        override.legal_reviewer_authority_digest
      AND override.override_payload->>'policyReceiptDigest'=
        editorial.named_person_legal_override_digest_v1(
          btrim(override.public_text_sha256),override.ruleset_version,
          override.reason_code,override.official_source_locator,
          btrim(override.official_source_sha256),
          override.legal_reviewer_user_id::text
        )
  ) THEN
    RAISE EXCEPTION 'r6d_named_person_legal_override_required'
      USING ERRCODE='23514';
  END IF;
  IF p_publication_state='OFFICIALLY_CONFIRMED'
     AND NOT editorial.official_confirmation_valid_v1(
       p_public_payload->'officialConfirmation'
     ) THEN
    RAISE EXCEPTION 'r6d_official_confirmation_required'
      USING ERRCODE='23514';
  END IF;
  IF p_publication_state<>'OFFICIALLY_CONFIRMED'
     AND p_public_payload ? 'officialConfirmation' THEN
    RAISE EXCEPTION 'r6d_official_confirmation_forbidden'
      USING ERRCODE='23514';
  END IF;
  IF p_publication_state='CORRECTED'
     AND NOT editorial.correction_notice_valid_v1(
       p_public_payload->'correctionNotice'
     ) THEN
    RAISE EXCEPTION 'r6d_correction_notice_required'
      USING ERRCODE='23514';
  END IF;
  IF p_publication_state<>'CORRECTED'
     AND p_public_payload ? 'correctionNotice' THEN
    RAISE EXCEPTION 'r6d_correction_notice_forbidden'
      USING ERRCODE='23514';
  END IF;
  RETURN v_assessment.assessment_id;
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'r6d_publication_guard_authority_missing_or_ambiguous'
    USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.assert_r6d_publication_guard_v2(
  uuid,uuid,editorial.publication_state,jsonb,char(64),text
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.assert_r6d_publication_guard_v2(
  uuid,uuid,editorial.publication_state,jsonb,char(64),text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.assert_r6d_publication_guard_v2(
  uuid,uuid,editorial.publication_state,jsonb,char(64),text
) TO gurine_control_api;

CREATE OR REPLACE FUNCTION editorial.enforce_r6d_publication_preview_guard_v2()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,pg_temp
AS $$
DECLARE v_state editorial.publication_state;
BEGIN
  IF COALESCE(NEW.preview_payload->>'publicationState','')='' THEN
    RAISE EXCEPTION 'r6d_preview_publication_state_required'
      USING ERRCODE='23514';
  END IF;
  v_state:=(NEW.preview_payload->>'publicationState')::editorial.publication_state;
  PERFORM editorial.assert_r6d_publication_guard_v2(
    NEW.case_id,NEW.review_snapshot_id,v_state,NEW.preview_payload,
    NEW.preview_sha256,'PREVIEW'
  );
  RETURN NEW;
END
$$;
ALTER FUNCTION editorial.enforce_r6d_publication_preview_guard_v2()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.enforce_r6d_publication_preview_guard_v2()
  FROM PUBLIC;
DROP TRIGGER IF EXISTS publication_previews_r6d_guard
  ON editorial.publication_previews;
CREATE TRIGGER publication_previews_r6d_guard
  BEFORE INSERT ON editorial.publication_previews
  FOR EACH ROW EXECUTE FUNCTION
    editorial.enforce_r6d_publication_preview_guard_v2();

CREATE OR REPLACE FUNCTION editorial.enforce_r6d_publication_revision_guard_v2()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,pg_temp
AS $$
DECLARE
  v_assessment_id uuid;
  v_mode text;
  v_guarded_assessment_id uuid;
BEGIN
  SELECT receipt.assessment_id,receipt.mode
  INTO STRICT v_assessment_id,v_mode
  FROM editorial.publication_revision_owner_receipts_v2 AS receipt
  JOIN editorial.named_person_review_stage_receipts_v1 AS stage
    ON stage.receipt_id=receipt.editorial_review_stage_receipt_id
    AND stage.receipt_digest=receipt.editorial_review_stage_receipt_digest
    AND stage.review_snapshot_id=receipt.review_snapshot_id
    AND stage.case_id=receipt.case_id
    AND stage.case_version=receipt.prior_case_version
    AND stage.review_stage='EDITORIAL' AND stage.decision='APPROVE'
  JOIN editorial.review_snapshots AS snapshot
    ON snapshot.id=receipt.review_snapshot_id
    AND snapshot.case_id=receipt.case_id
  WHERE receipt.revision_id=NEW.id
    AND receipt.case_id=NEW.case_id
    AND receipt.revision=NEW.revision
    AND receipt.publication_state=NEW.state
    AND receipt.review_snapshot_id=NEW.review_snapshot_id
    AND receipt.public_payload_sha256=NEW.public_payload_sha256
    AND receipt.actor_id=NEW.published_by
    AND receipt.published_at=NEW.published_at
    AND receipt.revision_reason_sha256=encode(
      extensions.digest(convert_to(COALESCE(NEW.reason,''),'UTF8'),'sha256'),'hex'
    )
    AND stage.reviewer_user_id<>snapshot.created_by
    AND stage.reviewer_user_id<>NEW.published_by
    AND (
      (receipt.mode='PUBLISH'
       AND receipt.preview_sha256=NEW.preview_sha256
       AND NEW.supersedes_revision IS NOT DISTINCT FROM
         NULLIF(receipt.revision-1,0))
      OR
      (receipt.mode='CORRECTION'
       AND NEW.preview_sha256=NEW.public_payload_sha256
       AND receipt.source_review_snapshot_id IS NOT NULL
       AND NEW.supersedes_revision=receipt.revision-1
       AND EXISTS(
         SELECT 1
         FROM editorial.corrections AS correction
         JOIN editorial.publication_revisions AS source_revision
           ON source_revision.case_id=correction.case_id
           AND source_revision.revision=correction.source_revision
         WHERE correction.id=receipt.correction_id
           AND correction.case_id=receipt.case_id
           AND correction.source_revision=NEW.supersedes_revision
           AND source_revision.review_snapshot_id=
             receipt.source_review_snapshot_id
       ))
    )
  FOR SHARE OF receipt,stage,snapshot;
  v_guarded_assessment_id:=editorial.assert_r6d_publication_guard_v2(
    NEW.case_id,NEW.review_snapshot_id,NEW.state,NEW.public_payload,
    NEW.public_payload_sha256,v_mode
  );
  IF v_guarded_assessment_id IS DISTINCT FROM v_assessment_id THEN
    RAISE EXCEPTION 'r6d_publication_revision_assessment_mismatch'
      USING ERRCODE='23514';
  END IF;
  RETURN NEW;
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'r6d_publication_revision_owner_required'
    USING ERRCODE='42501';
END
$$;
ALTER FUNCTION editorial.enforce_r6d_publication_revision_guard_v2()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.enforce_r6d_publication_revision_guard_v2()
  FROM PUBLIC;
DROP TRIGGER IF EXISTS publication_revisions_r6d_guard
  ON editorial.publication_revisions;
CREATE TRIGGER publication_revisions_r6d_guard
  BEFORE INSERT ON editorial.publication_revisions
  FOR EACH ROW EXECUTE FUNCTION
    editorial.enforce_r6d_publication_revision_guard_v2();

-- 0030 folded INSERT validation into the generic immutable trigger and
-- therefore required a live PREVIEW even for corrections.  The closed R6d
-- owner now supplies the exact INSERT guard above (including CORRECTION mode),
-- while the generic trigger remains responsible only for append-only
-- UPDATE/DELETE rejection.
DROP TRIGGER publication_revisions_immutable
  ON editorial.publication_revisions;
CREATE TRIGGER publication_revisions_immutable
  BEFORE UPDATE OR DELETE ON editorial.publication_revisions
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

ALTER TABLE editorial.publication_previews
  DROP CONSTRAINT publication_previews_case_id_review_snapshot_id_locale_prev_key;

CREATE TABLE editorial.publication_preview_owner_receipts_v2 (
  receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  preview_id uuid NOT NULL UNIQUE
    REFERENCES editorial.publication_previews(id) ON DELETE RESTRICT,
  case_id uuid NOT NULL REFERENCES editorial.cases(id) ON DELETE RESTRICT,
  case_version bigint NOT NULL,
  review_snapshot_id uuid NOT NULL
    REFERENCES editorial.review_snapshots(id) ON DELETE RESTRICT,
  assessment_id uuid NOT NULL
    REFERENCES editorial.named_person_publication_assessments(assessment_id)
    ON DELETE RESTRICT,
  assessment_digest char(64) NOT NULL,
  assessment_receipt_digest char(64) NOT NULL,
  public_payload_sha256 char(64) NOT NULL,
  publication_state editorial.publication_state NOT NULL,
  public_text_sha256 char(64) NOT NULL,
  registered_name_set_sha256 char(64) NOT NULL,
  locale text NOT NULL,
  legal_review_required boolean NOT NULL,
  status text NOT NULL,
  actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  actor_assertion_jti uuid NOT NULL UNIQUE,
  actor_action_digest char(64) NOT NULL,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  CONSTRAINT publication_preview_owner_receipts_v2_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(
    id,record_class,schedule_digest
  ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT publication_preview_owner_receipts_v2_class_fk
    FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  CONSTRAINT publication_preview_owner_receipts_v2_shape_ck CHECK (
    case_version>0 AND length(locale) BETWEEN 2 AND 35
    AND publication_state IN (
      'PUBLISHED_ANOMALY','PUBLISHED_EXPLAINED','OFFICIALLY_CONFIRMED'
    )
    AND status IN ('READY','BLOCKED')
    AND (status='BLOCKED')=legal_review_required
    AND expires_at>created_at
    AND ops.r6d_lower_sha256(assessment_digest)
    AND ops.r6d_lower_sha256(assessment_receipt_digest)
    AND ops.r6d_lower_sha256(public_payload_sha256)
    AND ops.r6d_lower_sha256(public_text_sha256)
    AND ops.r6d_lower_sha256(registered_name_set_sha256)
    AND ops.r6d_lower_sha256(actor_action_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND retention_record_class='NAMED_PERSON_PUBLICATION_GOVERNANCE'
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(
      extensions.digest(receipt_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE editorial.publication_preview_owner_receipts_v2
  OWNER TO gurine_migrator;
CREATE INDEX publication_preview_owner_receipts_v2_assessment_idx
  ON editorial.publication_preview_owner_receipts_v2(assessment_id,expires_at);
REVOKE ALL ON editorial.publication_preview_owner_receipts_v2 FROM PUBLIC;
GRANT SELECT ON editorial.publication_preview_owner_receipts_v2
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER publication_preview_owner_receipts_v2_immutable_guard
  BEFORE UPDATE OR DELETE ON editorial.publication_preview_owner_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER publication_preview_owner_receipts_v2_retention_bind
  BEFORE INSERT ON editorial.publication_preview_owner_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

CREATE OR REPLACE FUNCTION editorial.preview_publication_guarded_v2(
  p_request jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp
AS $$
DECLARE
  v_existing editorial.publication_preview_owner_receipts_v2%ROWTYPE;
  v_case editorial.cases%ROWTYPE;
  v_snapshot editorial.review_snapshots%ROWTYPE;
  v_preview_id uuid;
  v_case_id uuid;
  v_snapshot_id uuid;
  v_actor_id uuid;
  v_actor_jti uuid;
  v_request_id uuid;
  v_expected_version bigint;
  v_state editorial.publication_state;
  v_idempotency char(64);
  v_request_digest char(64);
  v_action_digest char(64);
  v_payload_sha char(64);
  v_locale text;
  v_assessment jsonb;
  v_assessment_id uuid;
  v_assessment_digest char(64);
  v_assessment_receipt char(64);
  v_legal_review_required boolean;
  v_status text;
  v_audit uuid;
  v_audit_digest char(64);
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
  v_now timestamptz:=clock_timestamp();
  v_expires timestamptz;
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_request))<>21
     OR NOT p_request ?& ARRAY[
       'previewId','caseId','reviewSnapshotId','expectedVersion',
       'publicationState','locale','publicPayload','publicPayloadSha256',
       'scan','legalOverride','_actorId','_actorAssertionJti',
       '_actorAssuranceLevel','_actorEffectiveCapability','_actorActionDigest',
       '_actorStepUpAuthorizationId','_actorIdempotencyKeySha256',
       '_actorRequestKeySha256','_requestId','_idempotencyKeySha256',
       '_requestSha256'
     ] THEN
    RAISE EXCEPTION 'publication_preview_owner_request_invalid'
      USING ERRCODE='22023';
  END IF;
  BEGIN
    v_preview_id:=NULLIF(p_request->>'previewId','')::uuid;
    v_case_id:=NULLIF(p_request->>'caseId','')::uuid;
    v_snapshot_id:=NULLIF(p_request->>'reviewSnapshotId','')::uuid;
    v_expected_version:=NULLIF(p_request->>'expectedVersion','')::bigint;
    v_state:=NULLIF(
      p_request->>'publicationState',''
    )::editorial.publication_state;
    v_actor_id:=NULLIF(p_request->>'_actorId','')::uuid;
    v_actor_jti:=NULLIF(p_request->>'_actorAssertionJti','')::uuid;
    v_request_id:=NULLIF(p_request->>'_requestId','')::uuid;
    v_idempotency:=NULLIF(
      p_request->>'_idempotencyKeySha256',''
    )::char(64);
    v_request_digest:=NULLIF(p_request->>'_requestSha256','')::char(64);
    v_action_digest:=NULLIF(
      p_request->>'_actorActionDigest',''
    )::char(64);
    v_payload_sha:=NULLIF(
      p_request->>'publicPayloadSha256',''
    )::char(64);
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'publication_preview_owner_request_invalid'
      USING ERRCODE='22023';
  END;
  v_locale:=NULLIF(btrim(p_request->>'locale'),'');
  IF v_preview_id IS NULL OR v_case_id IS NULL OR v_snapshot_id IS NULL
     OR v_actor_id IS NULL OR v_actor_jti IS NULL OR v_request_id IS NULL
     OR v_expected_version IS NULL OR v_expected_version<1
     OR v_locale IS NULL OR length(v_locale) NOT BETWEEN 2 AND 35
     OR v_state IS NULL OR v_state NOT IN (
       'PUBLISHED_ANOMALY','PUBLISHED_EXPLAINED','OFFICIALLY_CONFIRMED'
     )
     OR p_request->>'_actorAssuranceLevel' IS DISTINCT FROM 'ACTIVE_SESSION'
     OR p_request->>'_actorEffectiveCapability'
          IS DISTINCT FROM 'publication.preview'
     OR jsonb_typeof(p_request->'legalOverride') IS DISTINCT FROM 'null'
     OR NOT ops.r6d_lower_sha256(v_payload_sha)
     OR NOT ops.r6d_lower_sha256(v_action_digest)
     OR NOT ops.r6d_lower_sha256(v_idempotency)
     OR NOT ops.r6d_lower_sha256(v_request_digest)
     OR p_request->>'_actorRequestKeySha256' IS DISTINCT FROM v_idempotency
     OR p_request->>'_actorIdempotencyKeySha256'
          IS DISTINCT FROM v_idempotency THEN
    RAISE EXCEPTION 'publication_preview_owner_request_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing
  FROM editorial.publication_preview_owner_receipts_v2
  WHERE idempotency_key_sha256=v_idempotency FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest IS DISTINCT FROM v_request_digest
       OR v_existing.actor_id IS DISTINCT FROM v_actor_id
       OR v_existing.actor_action_digest IS DISTINCT FROM v_action_digest
       OR v_existing.preview_id IS DISTINCT FROM v_preview_id
       OR v_existing.case_id IS DISTINCT FROM v_case_id
       OR v_existing.case_version IS DISTINCT FROM v_expected_version
       OR v_existing.review_snapshot_id IS DISTINCT FROM v_snapshot_id
       OR v_existing.public_payload_sha256 IS DISTINCT FROM v_payload_sha
       OR v_existing.publication_state IS DISTINCT FROM v_state
       OR v_existing.public_text_sha256 IS DISTINCT FROM
          (p_request->'scan'->>'publicTextSha256')::char(64)
       OR v_existing.registered_name_set_sha256 IS DISTINCT FROM
          (p_request->'scan'->>'registeredNameSetSha256')::char(64)
       OR v_existing.locale IS DISTINCT FROM v_locale THEN
      RAISE EXCEPTION 'publication_preview_owner_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN jsonb_build_object(
      'previewId',v_existing.preview_id,'caseId',v_existing.case_id,
      'caseVersion',v_existing.case_version,
      'reviewSnapshotId',v_existing.review_snapshot_id,
      'assessmentId',v_existing.assessment_id,
      'assessmentDigest',btrim(v_existing.assessment_digest),
      'assessmentReceiptDigest',btrim(v_existing.assessment_receipt_digest),
      'previewSha256',btrim(v_existing.public_payload_sha256),
      'publicationState',v_existing.publication_state,
      'publicTextSha256',btrim(v_existing.public_text_sha256),
      'registeredNameSetSha256',
        btrim(v_existing.registered_name_set_sha256),
      'legalReviewRequired',v_existing.legal_review_required,
      'status',v_existing.status,'createdAt',v_existing.created_at,
      'expiresAt',v_existing.expires_at,
      'receiptDigest',btrim(v_existing.receipt_digest),
      'auditEventId',v_existing.audit_event_id,
      'outboxEventIds','[]'::jsonb,'replayed',true
    );
  END IF;
  SELECT * INTO STRICT v_case FROM editorial.cases
  WHERE id=v_case_id AND version=v_expected_version FOR SHARE;
  SELECT * INTO STRICT v_snapshot FROM editorial.review_snapshots
  WHERE id=v_snapshot_id AND case_id=v_case_id FOR SHARE;
  IF v_case.current_review_snapshot_id IS DISTINCT FROM v_snapshot_id
     OR v_snapshot.case_version IS DISTINCT FROM v_case.version THEN
    RAISE EXCEPTION 'publication_preview_owner_version_or_snapshot_stale'
      USING ERRCODE='40001';
  END IF;
  v_assessment:=editorial.record_named_person_publication_assessment_v1(
    jsonb_build_object(
      'caseId',v_case_id,'reviewSnapshotId',v_snapshot_id,
      'publicationState',v_state,'guardContext','PREVIEW',
      'publicPayload',p_request->'publicPayload',
      'publicPayloadSha256',btrim(v_payload_sha),'scan',p_request->'scan',
      'legalOverride',NULL,'_actorId',v_actor_id,
      '_actorAssertionJti',v_actor_jti,
      '_actorAssuranceLevel',p_request->'_actorAssuranceLevel',
      '_actorEffectiveCapability',p_request->'_actorEffectiveCapability',
      '_actorActionDigest',p_request->'_actorActionDigest',
      '_actorStepUpAuthorizationId',p_request->'_actorStepUpAuthorizationId',
      '_actorIdempotencyKeySha256',
        p_request->'_actorIdempotencyKeySha256',
      '_actorRequestKeySha256',p_request->'_actorRequestKeySha256',
      '_requestId',v_request_id,
      '_idempotencyKeySha256',btrim(v_idempotency),
      '_requestSha256',btrim(v_request_digest)
    )
  );
  v_assessment_id:=(v_assessment->>'assessmentId')::uuid;
  v_assessment_digest:=(v_assessment->>'assessmentDigest')::char(64);
  v_assessment_receipt:=
    (v_assessment->>'assessmentReceiptDigest')::char(64);
  v_legal_review_required:=
    (v_assessment->>'legalReviewRequired')::boolean;
  v_status:=CASE WHEN v_legal_review_required THEN 'BLOCKED' ELSE 'READY' END;
  PERFORM editorial.assert_r6d_publication_guard_v2(
    v_case_id,v_snapshot_id,v_state,p_request->'publicPayload',
    v_payload_sha,'PREVIEW'
  );
  v_expires:=v_now+interval '15 minutes';
  INSERT INTO editorial.publication_previews(
    id,case_id,review_snapshot_id,locale,preview_payload,preview_sha256,
    expires_at,created_by
  ) VALUES(
    v_preview_id,v_case_id,v_snapshot_id,v_locale,p_request->'publicPayload',
    v_payload_sha,v_expires,v_actor_id
  );
  v_audit:=ops.append_audit_event(
    'publication-preview:'||v_case_id::text,'USER',v_actor_id::text,NULL::uuid,
    'publication.preview.created','PublicationPreview',v_preview_id::text,
    'publication.preview','SUCCESS',NULL,v_request_id,jsonb_build_object(
      'assessmentDigest',btrim(v_assessment_digest),
      'assessmentReceiptDigest',btrim(v_assessment_receipt),
      'publicPayloadSha256',btrim(v_payload_sha),
      'legalReviewRequired',v_legal_review_required,'status',v_status
    )
  );
  SELECT event_hash INTO STRICT v_audit_digest
  FROM ops.audit_events WHERE id=v_audit;
  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','publication-preview-owner-receipt.v2',
    'previewId',v_preview_id,'caseId',v_case_id,
    'caseVersion',v_case.version,'reviewSnapshotId',v_snapshot_id,
    'assessmentId',v_assessment_id,
    'assessmentDigest',btrim(v_assessment_digest),
    'assessmentReceiptDigest',btrim(v_assessment_receipt),
    'previewSha256',btrim(v_payload_sha),'locale',v_locale,
    'publicationState',v_state,
    'publicTextSha256',p_request->'scan'->>'publicTextSha256',
    'registeredNameSetSha256',
      p_request->'scan'->>'registeredNameSetSha256',
    'legalReviewRequired',v_legal_review_required,'status',v_status,
    'createdAt',v_now,'expiresAt',v_expires
  );
  v_receipt_payload:=v_receipt_payload||jsonb_build_object(
    'auditEventId',v_audit,'auditEventDigest',btrim(v_audit_digest),
    'requestId',v_request_id,'requestDigest',btrim(v_request_digest)
  );
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_receipt_digest:=encode(
    extensions.digest(v_receipt_canonical,'sha256'),'hex'
  );
  INSERT INTO editorial.publication_preview_owner_receipts_v2(
    preview_id,case_id,case_version,review_snapshot_id,assessment_id,
    assessment_digest,assessment_receipt_digest,public_payload_sha256,
    publication_state,public_text_sha256,registered_name_set_sha256,
    locale,legal_review_required,status,actor_id,actor_assertion_jti,
    actor_action_digest,
    request_id,idempotency_key_sha256,request_digest,audit_event_id,
    receipt_payload,receipt_canonical,receipt_digest,created_at,expires_at
  ) VALUES(
    v_preview_id,v_case_id,v_case.version,v_snapshot_id,v_assessment_id,
    v_assessment_digest,v_assessment_receipt,v_payload_sha,v_state,
    (p_request->'scan'->>'publicTextSha256')::char(64),
    (p_request->'scan'->>'registeredNameSetSha256')::char(64),v_locale,
    v_legal_review_required,v_status,v_actor_id,v_actor_jti,v_action_digest,
    v_request_id,
    v_idempotency,v_request_digest,v_audit,v_receipt_payload,
    v_receipt_canonical,v_receipt_digest,v_now,v_expires
  );
  RETURN jsonb_build_object(
    'previewId',v_preview_id,'caseId',v_case_id,
    'caseVersion',v_case.version,'reviewSnapshotId',v_snapshot_id,
    'assessmentId',v_assessment_id,
    'assessmentDigest',btrim(v_assessment_digest),
    'assessmentReceiptDigest',btrim(v_assessment_receipt),
    'previewSha256',btrim(v_payload_sha),'publicationState',v_state,
    'publicTextSha256',p_request->'scan'->>'publicTextSha256',
    'registeredNameSetSha256',
      p_request->'scan'->>'registeredNameSetSha256',
    'legalReviewRequired',v_legal_review_required,'status',v_status,
    'createdAt',v_now,'expiresAt',v_expires,
    'receiptDigest',btrim(v_receipt_digest),'auditEventId',v_audit,
    'outboxEventIds','[]'::jsonb,'replayed',false
  );
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'publication_preview_owner_authority_missing_or_ambiguous'
    USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.preview_publication_guarded_v2(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.preview_publication_guarded_v2(jsonb)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.preview_publication_guarded_v2(jsonb)
  TO gurine_control_api;
REVOKE INSERT,UPDATE,DELETE ON editorial.publication_previews
  FROM gurine_control_api;

-- Both the scanner adapter and the mutating owner call this builder in the same
-- transaction. transaction_timestamp() is fixed for that transaction, so the
-- owner-generated correction notice has one reproducible byte representation.
CREATE OR REPLACE FUNCTION editorial.build_corrected_publication_payload_v2(
  p_correction_id uuid,
  p_expected_version bigint,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp
AS $$
DECLARE
  v_correction editorial.corrections%ROWTYPE;
  v_case editorial.cases%ROWTYPE;
  v_source editorial.publication_revisions%ROWTYPE;
  v_replacement jsonb;
  v_claims jsonb;
  v_revision integer;
  v_applied_at timestamptz:=transaction_timestamp();
  v_date text;
  v_command_reason text:=NULLIF(btrim(p_reason),'');
  v_reason text;
  v_impact text;
  v_non_conclusion text;
BEGIN
  IF p_correction_id IS NULL OR p_expected_version IS NULL
     OR p_expected_version<1 OR v_command_reason IS NULL
     OR p_reason IS DISTINCT FROM v_command_reason
     OR length(v_command_reason)>4000 THEN
    RAISE EXCEPTION 'corrected_publication_builder_request_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_correction FROM editorial.corrections
  WHERE id=p_correction_id AND version=p_expected_version FOR SHARE;
  IF NOT FOUND OR v_correction.status<>'REVIEW'
     OR v_correction.replacement_content IS NULL
     OR jsonb_typeof(v_correction.replacement_content)<>'object'
     OR jsonb_typeof(v_correction.affected_claim_ids)<>'array' THEN
    RAISE EXCEPTION 'corrected_publication_facts_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO STRICT v_case FROM editorial.cases
  WHERE id=v_correction.case_id FOR SHARE;
  IF v_case.current_publication_revision IS NULL
     OR v_case.current_publication_revision IS DISTINCT FROM
        v_correction.source_revision THEN
    RAISE EXCEPTION 'corrected_publication_source_missing'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO STRICT v_source FROM editorial.publication_revisions
  WHERE case_id=v_case.id AND revision=v_correction.source_revision
  FOR SHARE;
  IF v_source.revision IS DISTINCT FROM v_correction.source_revision
     OR jsonb_typeof(v_source.public_payload)<>'object'
     OR jsonb_typeof(v_source.public_payload->'claims')<>'array'
     OR jsonb_typeof(v_source.public_payload->'evidence')<>'array'
     OR v_source.public_payload->>'caseId' IS DISTINCT FROM v_case.id::text
     OR v_source.public_payload->>'reviewSnapshotId' IS DISTINCT FROM
        v_source.review_snapshot_id::text THEN
    RAISE EXCEPTION 'corrected_publication_source_stale_or_invalid'
      USING ERRCODE='23514';
  END IF;
  v_replacement:=v_correction.replacement_content;
  v_reason:=NULLIF(btrim(v_correction.reason),'');
  IF (SELECT count(*) FROM jsonb_object_keys(v_replacement))<>5
     OR NOT v_replacement ?& ARRAY[
       'summary','claimReplacements','limitations','publicEvidenceIds',
       'effectiveReason'
     ]
     OR v_reason IS NULL OR length(v_reason)>4000
     OR NULLIF(btrim(v_replacement->>'summary'),'') IS NULL
     OR NULLIF(btrim(v_replacement->>'effectiveReason'),'') IS NULL
     OR jsonb_typeof(v_replacement->'claimReplacements')<>'array'
     OR jsonb_array_length(v_replacement->'claimReplacements')<1
     OR jsonb_typeof(v_replacement->'limitations')<>'array'
     OR jsonb_typeof(v_replacement->'publicEvidenceIds')<>'array'
     OR EXISTS(
       SELECT 1
       FROM jsonb_array_elements(v_replacement->'claimReplacements') AS item(value)
       WHERE jsonb_typeof(value)<>'object'
          OR (SELECT count(*) FROM jsonb_object_keys(value))<>5
          OR NOT value ?& ARRAY[
            'claimId','replacementText','evidenceIds','responseIds','limitations'
          ]
          OR COALESCE(value->>'claimId','') !~
            '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
          OR NULLIF(btrim(value->>'replacementText'),'') IS NULL
          OR jsonb_typeof(value->'evidenceIds')<>'array'
          OR jsonb_array_length(value->'evidenceIds')<1
          OR jsonb_typeof(value->'responseIds')<>'array'
          OR jsonb_typeof(value->'limitations')<>'array'
     )
     OR (SELECT count(*) FROM jsonb_array_elements(
           v_replacement->'claimReplacements'
         ))<>(SELECT count(DISTINCT value->>'claimId')
              FROM jsonb_array_elements(
                v_replacement->'claimReplacements'
              ) AS replacement(value))
     OR NOT (
       SELECT COALESCE(jsonb_agg(value ORDER BY value),'[]'::jsonb)
       FROM jsonb_array_elements_text(v_correction.affected_claim_ids)
     )=(
       SELECT COALESCE(jsonb_agg(value ORDER BY value),'[]'::jsonb)
       FROM jsonb_array_elements(
         v_replacement->'claimReplacements'
       ) AS replacement(item)
       CROSS JOIN LATERAL (SELECT item->>'claimId' AS value) AS id
     )
     OR EXISTS(
       SELECT 1
       FROM jsonb_array_elements(v_replacement->'claimReplacements') AS replacement(item)
       WHERE NOT EXISTS(
         SELECT 1 FROM jsonb_array_elements(
           v_source.public_payload->'claims'
         ) AS source_claim(value)
         WHERE source_claim.value->>'id'=replacement.item->>'claimId'
       )
     )
     OR EXISTS(
       SELECT 1 FROM jsonb_array_elements_text(
         v_replacement->'publicEvidenceIds'
       ) AS evidence_id(value)
       WHERE NOT EXISTS(
         SELECT 1 FROM jsonb_array_elements(
           v_source.public_payload->'evidence'
         ) AS source_evidence(value)
         WHERE source_evidence.value->>'id'=evidence_id.value
       )
     ) THEN
    RAISE EXCEPTION 'corrected_publication_replacement_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT jsonb_agg(
    CASE WHEN replacement.item IS NULL THEN source_claim.item
      ELSE source_claim.item||jsonb_build_object(
        'text',replacement.item->>'replacementText',
        'evidenceIds',replacement.item->'evidenceIds',
        'responseIds',replacement.item->'responseIds',
        'limitations',replacement.item->'limitations'
      ) END
    ORDER BY source_claim.ordinal
  ) INTO v_claims
  FROM jsonb_array_elements(v_source.public_payload->'claims')
    WITH ORDINALITY AS source_claim(item,ordinal)
  LEFT JOIN LATERAL (
    SELECT item FROM jsonb_array_elements(
      v_replacement->'claimReplacements'
    ) AS replacement_item(item)
    WHERE replacement_item.item->>'claimId'=source_claim.item->>'id'
  ) AS replacement ON true;
  v_revision:=v_source.revision+1;
  v_date:=to_char(v_applied_at AT TIME ZONE 'Asia/Seoul','YYYY-MM-DD');
  v_impact:=btrim(v_replacement->>'summary');
  v_non_conclusion:=format(
    '이 페이지는 %s에 정정됐습니다. %s와 %s을 아래 정정 기록에서 확인할 수 있습니다.',
    v_date,v_reason,v_impact
  );
  RETURN (
    v_source.public_payload
      -'officialConfirmation'-'correctionNotice'-'correctionDetails'
      -'official_confirmation'-'correction_notice'-'correction_details'
  )||jsonb_build_object(
    'reviewSnapshotId',v_case.current_review_snapshot_id,
    'publicationState','CORRECTED','summary',v_impact,
    'claims',COALESCE(v_claims,'[]'::jsonb),
    'nonConclusion',v_non_conclusion,
    'correctionNotice',jsonb_build_object(
      'appliedAt',v_applied_at,'reason',v_reason,
      'impactSummary',v_impact,'revision',v_revision
    ),
    'correctionDetails',v_replacement
  );
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'corrected_publication_authority_missing_or_ambiguous'
    USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.build_corrected_publication_payload_v2(
  uuid,bigint,text
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.build_corrected_publication_payload_v2(
  uuid,bigint,text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.build_corrected_publication_payload_v2(
  uuid,bigint,text
) TO gurine_control_api;

CREATE OR REPLACE FUNCTION ops.r6d_uuid_array_sorted_unique_v1(
  p_values uuid[]
) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path=pg_catalog,pg_temp
AS $$
  SELECT cardinality(p_values)>0
    AND array_position(p_values,NULL) IS NULL
    AND p_values=(
      SELECT array_agg(value ORDER BY value)
      FROM unnest(p_values) AS item(value)
    )
    AND cardinality(p_values)=(
      SELECT count(DISTINCT value) FROM unnest(p_values) AS item(value)
    )
$$;
ALTER FUNCTION ops.r6d_uuid_array_sorted_unique_v1(uuid[])
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_uuid_array_sorted_unique_v1(uuid[]) FROM PUBLIC;

CREATE TABLE editorial.publication_revision_owner_receipts_v2 (
  receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mode text NOT NULL,
  case_id uuid NOT NULL REFERENCES editorial.cases(id) ON DELETE RESTRICT,
  prior_case_version bigint NOT NULL,
  case_version bigint NOT NULL,
  review_snapshot_id uuid NOT NULL
    REFERENCES editorial.review_snapshots(id) ON DELETE RESTRICT,
  source_review_snapshot_id uuid
    REFERENCES editorial.review_snapshots(id) ON DELETE RESTRICT,
  revision_id uuid NOT NULL UNIQUE
    REFERENCES editorial.publication_revisions(id) ON DELETE RESTRICT
    DEFERRABLE INITIALLY DEFERRED,
  revision integer NOT NULL,
  publication_state editorial.publication_state NOT NULL,
  assessment_id uuid NOT NULL UNIQUE
    REFERENCES editorial.named_person_publication_assessments(assessment_id)
    ON DELETE RESTRICT,
  assessment_digest char(64) NOT NULL,
  preview_sha256 char(64),
  public_payload_sha256 char(64) NOT NULL,
  correction_id uuid REFERENCES editorial.corrections(id) ON DELETE RESTRICT,
  prior_correction_version bigint,
  correction_version bigint,
  actor_id uuid NOT NULL REFERENCES ops.users(id) ON DELETE RESTRICT,
  actor_assertion_jti uuid NOT NULL UNIQUE,
  actor_action_digest char(64) NOT NULL,
  step_up_authorization_id uuid
    REFERENCES ops.step_up_authorizations(id) ON DELETE RESTRICT,
  editorial_review_stage_receipt_id uuid NOT NULL
    REFERENCES editorial.named_person_review_stage_receipts_v1(receipt_id)
    ON DELETE RESTRICT,
  editorial_review_stage_receipt_digest char(64) NOT NULL,
  revision_reason_sha256 char(64) NOT NULL,
  command_reason_sha256 char(64) NOT NULL,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  outbox_event_ids uuid[] NOT NULL,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  published_at timestamptz NOT NULL,
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT publication_revision_owner_receipts_v2_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(
    id,record_class,schedule_digest
  ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT publication_revision_owner_receipts_v2_class_fk
    FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  CONSTRAINT publication_revision_owner_receipts_v2_shape_ck CHECK (
    mode IN ('PUBLISH','CORRECTION')
    AND prior_case_version>0 AND case_version=prior_case_version+1
    AND revision>0
    AND publication_state IN (
      'PUBLISHED_ANOMALY','PUBLISHED_EXPLAINED','OFFICIALLY_CONFIRMED',
      'CORRECTED','RETRACTED','TEMPORARILY_RESTRICTED'
    )
    AND (
      (mode='PUBLISH' AND publication_state IN (
         'PUBLISHED_ANOMALY','PUBLISHED_EXPLAINED','OFFICIALLY_CONFIRMED'
       ) AND preview_sha256 IS NOT NULL
       AND source_review_snapshot_id IS NULL
       AND correction_id IS NULL AND prior_correction_version IS NULL
       AND correction_version IS NULL
       AND step_up_authorization_id IS NOT NULL
       AND cardinality(outbox_event_ids)=3)
      OR
      (mode='CORRECTION' AND publication_state='CORRECTED'
       AND preview_sha256 IS NULL AND correction_id IS NOT NULL
       AND source_review_snapshot_id IS NOT NULL
       AND prior_correction_version>0
       AND correction_version=prior_correction_version+1
       AND step_up_authorization_id IS NULL
       AND cardinality(outbox_event_ids)=4)
    )
    AND ops.r6d_lower_sha256(assessment_digest)
    AND ops.r6d_lower_sha256(actor_action_digest)
    AND ops.r6d_lower_sha256(editorial_review_stage_receipt_digest)
    AND ops.r6d_lower_sha256(revision_reason_sha256)
    AND ops.r6d_lower_sha256(command_reason_sha256)
    AND (preview_sha256 IS NULL OR ops.r6d_lower_sha256(preview_sha256))
    AND ops.r6d_lower_sha256(public_payload_sha256)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND retention_record_class='NAMED_PERSON_PUBLICATION_GOVERNANCE'
    AND ops.r6d_uuid_array_sorted_unique_v1(outbox_event_ids)
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(
      extensions.digest(receipt_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE editorial.publication_revision_owner_receipts_v2
  OWNER TO gurine_migrator;
REVOKE ALL ON editorial.publication_revision_owner_receipts_v2 FROM PUBLIC;
REVOKE ALL ON editorial.publication_revision_owner_receipts_v2
  FROM gurine_control_api,gurine_submission_api,gurine_workflow_worker,
    gurine_analysis_worker,gurine_public_projector,gurine_notification_worker;
GRANT SELECT ON editorial.publication_revision_owner_receipts_v2
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER publication_revision_owner_receipts_v2_immutable_guard
  BEFORE UPDATE OR DELETE ON editorial.publication_revision_owner_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();
CREATE TRIGGER publication_revision_owner_receipts_v2_retention_bind
  BEFORE INSERT ON editorial.publication_revision_owner_receipts_v2
  FOR EACH ROW EXECUTE FUNCTION ops.bind_r6d_identity_schedule_v1();

-- A resolved correction may alter only its terminal publication fields after
-- the immutable owner receipt has been inserted in the same transaction.
CREATE OR REPLACE FUNCTION editorial.guard_r6d_correction_publication_v2()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,editorial,extensions,pg_temp
AS $$
DECLARE v_receipt_id uuid;
BEGIN
  IF OLD.status='PUBLISHED' THEN
    RAISE EXCEPTION 'r6d_published_correction_immutable'
      USING ERRCODE='55000';
  END IF;
  IF NEW.status IS DISTINCT FROM 'PUBLISHED' THEN
    RETURN NEW;
  END IF;
  SELECT receipt.receipt_id INTO STRICT v_receipt_id
  FROM editorial.publication_revision_owner_receipts_v2 AS receipt
  WHERE receipt.mode='CORRECTION'
    AND receipt.correction_id=NEW.id
    AND receipt.case_id=NEW.case_id
    AND receipt.prior_correction_version=OLD.version
    AND receipt.correction_version=NEW.version
    AND receipt.revision=NEW.target_revision
    AND receipt.publication_state='CORRECTED'
    AND receipt.command_reason_sha256=encode(extensions.digest(
      convert_to(COALESCE(NEW.resolution_reason,''),'UTF8'),'sha256'
    ),'hex')
    AND receipt.published_at=NEW.resolved_at
    AND OLD.status='REVIEW' AND OLD.resolution IS NULL
    AND NEW.resolution='RESOLVED'
    AND NEW.version=OLD.version+1 AND NEW.target_revision IS NOT NULL
    AND NEW.resolution_reason IS NOT NULL AND NEW.resolved_at IS NOT NULL
    AND ROW(
      NEW.id,NEW.case_id,NEW.source_revision,NEW.summary,NEW.reason,
      NEW.affected_claim_ids,NEW.assigned_user_id,NEW.created_by,
      NEW.created_at,NEW.replacement_content,NEW.priority,
      NEW.triage_decision,NEW.triage_reason
    ) IS NOT DISTINCT FROM ROW(
      OLD.id,OLD.case_id,OLD.source_revision,OLD.summary,OLD.reason,
      OLD.affected_claim_ids,OLD.assigned_user_id,OLD.created_by,
      OLD.created_at,OLD.replacement_content,OLD.priority,
      OLD.triage_decision,OLD.triage_reason
    )
  FOR SHARE OF receipt;
  RETURN NEW;
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'r6d_correction_publication_owner_required'
    USING ERRCODE='42501';
END
$$;
ALTER FUNCTION editorial.guard_r6d_correction_publication_v2()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.guard_r6d_correction_publication_v2()
  FROM PUBLIC;
CREATE TRIGGER corrections_r6d_publication_guard
  BEFORE UPDATE ON editorial.corrections
  FOR EACH ROW EXECUTE FUNCTION
    editorial.guard_r6d_correction_publication_v2();

CREATE OR REPLACE FUNCTION editorial.guard_r6d_case_publication_v2()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,editorial,pg_temp
AS $$
DECLARE v_receipt_id uuid;
BEGIN
  IF NEW.publication_state IS NOT DISTINCT FROM OLD.publication_state
     AND NEW.current_publication_revision IS NOT DISTINCT FROM
       OLD.current_publication_revision THEN
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
    AND ROW(
      NEW.id,NEW.public_slug,NEW.title,NEW.investigation_state,
      NEW.resolution_code,NEW.summary,NEW.priority,NEW.lead_investigator_id,
      NEW.editor_id,NEW.legal_review_required,NEW.current_review_snapshot_id,
      NEW.created_at
    ) IS NOT DISTINCT FROM ROW(
      OLD.id,OLD.public_slug,OLD.title,OLD.investigation_state,
      OLD.resolution_code,OLD.summary,OLD.priority,OLD.lead_investigator_id,
      OLD.editor_id,OLD.legal_review_required,OLD.current_review_snapshot_id,
      OLD.created_at
    )
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
CREATE TRIGGER cases_r6d_publication_guard
  BEFORE UPDATE ON editorial.cases
  FOR EACH ROW EXECUTE FUNCTION editorial.guard_r6d_case_publication_v2();

CREATE OR REPLACE FUNCTION editorial.publish_guarded_revision_v2(
  p_request jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,editorial,ops,extensions,pg_temp
AS $$
DECLARE
  v_existing editorial.publication_revision_owner_receipts_v2%ROWTYPE;
  v_case editorial.cases%ROWTYPE;
  v_snapshot editorial.review_snapshots%ROWTYPE;
  v_preview editorial.publication_previews%ROWTYPE;
  v_preview_receipt editorial.publication_preview_owner_receipts_v2%ROWTYPE;
  v_correction editorial.corrections%ROWTYPE;
  v_source_revision editorial.publication_revisions%ROWTYPE;
  v_editorial_stage editorial.named_person_review_stage_receipts_v1%ROWTYPE;
  v_correction_task ops.tasks%ROWTYPE;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_mode text;
  v_case_id uuid;
  v_snapshot_id uuid;
  v_source_snapshot_id uuid;
  v_correction_id uuid;
  v_actor_id uuid;
  v_actor_jti uuid;
  v_step_up_id uuid;
  v_request_id uuid;
  v_expected_version bigint;
  v_idempotency char(64);
  v_request_digest char(64);
  v_action_digest char(64);
  v_preview_hash char(64);
  v_public_payload_sha char(64);
  v_reason text;
  v_reason_sha char(64);
  v_revision_reason text;
  v_revision_reason_sha char(64);
  v_resolution text;
  v_payload jsonb;
  v_state editorial.publication_state;
  v_assessment jsonb;
  v_assessment_id uuid;
  v_assessment_digest char(64);
  v_revision_id uuid:=gen_random_uuid();
  v_owner_receipt_id uuid:=gen_random_uuid();
  v_revision integer;
  v_prior_revision integer;
  v_prior_case_version bigint;
  v_case_version bigint;
  v_prior_correction_version bigint;
  v_correction_version bigint;
  v_audit uuid;
  v_audit_digest char(64);
  v_event_publication uuid;
  v_event_projection uuid;
  v_event_notification uuid;
  v_event_correction uuid;
  v_event_ids uuid[];
  v_event_types text[];
  v_event_count bigint;
  v_outbox_proofs jsonb;
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
  v_review_count bigint;
  v_task_count bigint;
  v_task_version_before bigint;
  v_now timestamptz:=transaction_timestamp();
BEGIN
  IF p_request IS NULL OR jsonb_typeof(p_request)<>'object'
     OR p_request->>'mode' IS NULL
     OR p_request->>'mode' NOT IN ('PUBLISH','CORRECTION') THEN
    RAISE EXCEPTION 'publication_revision_owner_request_invalid'
      USING ERRCODE='22023';
  END IF;
  v_mode:=p_request->>'mode';
  IF (v_mode='PUBLISH' AND (
       (SELECT count(*) FROM jsonb_object_keys(p_request))<>19
       OR NOT p_request ?& ARRAY[
         'mode','caseId','reviewSnapshotId','expectedVersion','previewHash',
         'reason','publicPayloadSha256','scan','_actorId',
         '_actorAssertionJti','_actorAssuranceLevel',
         '_actorEffectiveCapability','_actorActionDigest',
         '_actorStepUpAuthorizationId','_actorIdempotencyKeySha256',
         '_actorRequestKeySha256','_requestId','_idempotencyKeySha256',
         '_requestSha256'
       ]
     )) OR (v_mode='CORRECTION' AND (
       (SELECT count(*) FROM jsonb_object_keys(p_request))<>18
       OR NOT p_request ?& ARRAY[
         'mode','correctionId','resolution','reason','expectedVersion',
         'publicPayloadSha256','scan','_actorId','_actorAssertionJti',
         '_actorAssuranceLevel','_actorEffectiveCapability',
         '_actorActionDigest','_actorStepUpAuthorizationId',
         '_actorIdempotencyKeySha256','_actorRequestKeySha256','_requestId',
         '_idempotencyKeySha256','_requestSha256'
       ]
     )) THEN
    RAISE EXCEPTION 'publication_revision_owner_request_invalid'
      USING ERRCODE='22023';
  END IF;
  BEGIN
    v_case_id:=NULLIF(p_request->>'caseId','')::uuid;
    v_snapshot_id:=NULLIF(p_request->>'reviewSnapshotId','')::uuid;
    v_correction_id:=NULLIF(p_request->>'correctionId','')::uuid;
    v_actor_id:=NULLIF(p_request->>'_actorId','')::uuid;
    v_actor_jti:=NULLIF(p_request->>'_actorAssertionJti','')::uuid;
    v_step_up_id:=NULLIF(
      p_request->>'_actorStepUpAuthorizationId',''
    )::uuid;
    v_request_id:=NULLIF(p_request->>'_requestId','')::uuid;
    v_expected_version:=NULLIF(p_request->>'expectedVersion','')::bigint;
    v_idempotency:=NULLIF(
      p_request->>'_idempotencyKeySha256',''
    )::char(64);
    v_request_digest:=NULLIF(
      p_request->>'_requestSha256',''
    )::char(64);
    v_action_digest:=NULLIF(
      p_request->>'_actorActionDigest',''
    )::char(64);
    v_preview_hash:=NULLIF(p_request->>'previewHash','')::char(64);
    v_public_payload_sha:=NULLIF(
      p_request->>'publicPayloadSha256',''
    )::char(64);
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'publication_revision_owner_request_invalid'
      USING ERRCODE='22023';
  END;
  v_reason:=NULLIF(btrim(p_request->>'reason'),'');
  v_resolution:=NULLIF(p_request->>'resolution','');
  IF v_actor_id IS NULL OR v_actor_jti IS NULL OR v_request_id IS NULL
     OR v_expected_version IS NULL OR v_expected_version<1
     OR v_reason IS NULL OR length(v_reason)>4000
     OR p_request->>'reason' IS DISTINCT FROM v_reason
     OR jsonb_typeof(p_request->'scan')<>'object'
     OR NOT COALESCE(ops.r6d_lower_sha256(v_public_payload_sha),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(v_action_digest),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(v_idempotency),false)
     OR NOT COALESCE(ops.r6d_lower_sha256(v_request_digest),false)
     OR p_request->>'_actorRequestKeySha256'
          IS DISTINCT FROM btrim(v_idempotency)
     OR p_request->>'_actorIdempotencyKeySha256'
          IS DISTINCT FROM btrim(v_idempotency)
     OR (v_mode='PUBLISH' AND (
       v_case_id IS NULL OR v_snapshot_id IS NULL OR v_step_up_id IS NULL
       OR v_resolution IS NOT NULL
       OR NOT COALESCE(ops.r6d_lower_sha256(v_preview_hash),false)
       OR v_preview_hash IS DISTINCT FROM v_public_payload_sha
       OR p_request->>'_actorAssuranceLevel' IS DISTINCT FROM 'STEP_UP'
       OR p_request->>'_actorEffectiveCapability'
            IS DISTINCT FROM 'publication.publish'
     ))
     OR (v_mode='CORRECTION' AND (
       v_correction_id IS NULL OR v_case_id IS NOT NULL
       OR v_snapshot_id IS NOT NULL OR v_preview_hash IS NOT NULL
       OR v_resolution IS DISTINCT FROM 'RESOLVED'
       OR jsonb_typeof(p_request->'_actorStepUpAuthorizationId')
            IS DISTINCT FROM 'null'
       OR v_step_up_id IS NOT NULL
       OR p_request->>'_actorAssuranceLevel'
            IS DISTINCT FROM 'RECENT_SESSION'
       OR p_request->>'_actorEffectiveCapability'
            IS DISTINCT FROM 'publication.correct'
     )) THEN
    RAISE EXCEPTION 'publication_revision_owner_request_invalid'
      USING ERRCODE='22023';
  END IF;
  v_reason_sha:=encode(extensions.digest(
    convert_to(v_reason,'UTF8'),'sha256'
  ),'hex');

  SELECT * INTO v_existing
  FROM editorial.publication_revision_owner_receipts_v2
  WHERE idempotency_key_sha256=v_idempotency FOR SHARE;
  IF FOUND THEN
    SELECT count(*),array_agg(outbox.event_type ORDER BY outbox.event_type),
      jsonb_agg(jsonb_build_object(
        'eventId',outbox.id,'eventType',outbox.event_type,
        'eventEnvelopeDigest',ops.r6d_outbox_envelope_digest_v1(outbox.id)
      ) ORDER BY outbox.event_type)
    INTO v_event_count,v_event_types,v_outbox_proofs
    FROM ops.outbox AS outbox
    WHERE outbox.id=ANY(v_existing.outbox_event_ids);
    IF v_existing.mode IS DISTINCT FROM v_mode
       OR v_existing.request_digest IS DISTINCT FROM v_request_digest
       OR v_existing.actor_id IS DISTINCT FROM v_actor_id
       OR v_existing.actor_action_digest IS DISTINCT FROM v_action_digest
       OR v_existing.step_up_authorization_id
            IS DISTINCT FROM v_step_up_id
       OR v_existing.command_reason_sha256 IS DISTINCT FROM v_reason_sha
       OR v_existing.public_payload_sha256
            IS DISTINCT FROM v_public_payload_sha
       OR (v_mode='PUBLISH' AND (
         v_existing.case_id IS DISTINCT FROM v_case_id
         OR v_existing.review_snapshot_id IS DISTINCT FROM v_snapshot_id
         OR v_existing.prior_case_version IS DISTINCT FROM v_expected_version
         OR v_existing.preview_sha256 IS DISTINCT FROM v_preview_hash
       ))
       OR (v_mode='CORRECTION' AND (
         v_existing.correction_id IS DISTINCT FROM v_correction_id
         OR v_existing.prior_correction_version
              IS DISTINCT FROM v_expected_version
       ))
       OR NOT ops.r6d_uuid_array_sorted_unique_v1(
            v_existing.outbox_event_ids
          )
       OR v_event_count IS DISTINCT FROM cardinality(
            v_existing.outbox_event_ids
          )
       OR v_outbox_proofs IS DISTINCT FROM
            v_existing.receipt_payload->'outboxEvents'
       OR (v_mode='PUBLISH' AND v_event_types IS DISTINCT FROM ARRAY[
            'notification.publication_created.v1',
            'projection.publication_revision_created.v1',
            'publication.revision_created.v1'
          ]::text[])
       OR (v_mode='CORRECTION' AND v_event_types IS DISTINCT FROM ARRAY[
            'correction.resolved.v1','notification.correction_resolved.v1',
            'projection.publication_revision_created.v1',
            'publication.revision_created.v1'
          ]::text[])
       OR NOT EXISTS(
         SELECT 1 FROM ops.audit_events AS audit
         WHERE audit.id=v_existing.audit_event_id
           AND btrim(audit.event_hash) IS NOT DISTINCT FROM
             v_existing.receipt_payload->>'auditEventDigest'
       ) THEN
      RAISE EXCEPTION 'publication_revision_owner_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    IF v_mode='PUBLISH' THEN
      RETURN jsonb_build_object(
        'caseId',v_existing.case_id,'caseVersion',v_existing.case_version,
        'reviewSnapshotId',v_existing.review_snapshot_id,
        'revisionId',v_existing.revision_id,'revision',v_existing.revision,
        'publicationState',v_existing.publication_state,
        'assessmentId',v_existing.assessment_id,
        'assessmentDigest',btrim(v_existing.assessment_digest),
        'previewSha256',btrim(v_existing.preview_sha256),
        'publicPayloadSha256',btrim(v_existing.public_payload_sha256),
        'publishedAt',v_existing.published_at,
        'receiptDigest',btrim(v_existing.receipt_digest),
        'auditEventId',v_existing.audit_event_id,
        'outboxEventIds',v_existing.outbox_event_ids,'replayed',true
      );
    END IF;
    RETURN jsonb_build_object(
      'correctionId',v_existing.correction_id,
      'correctionVersion',v_existing.correction_version,
      'caseId',v_existing.case_id,'caseVersion',v_existing.case_version,
      'reviewSnapshotId',v_existing.review_snapshot_id,
      'revisionId',v_existing.revision_id,'revision',v_existing.revision,
      'publicationState',v_existing.publication_state,
      'assessmentId',v_existing.assessment_id,
      'assessmentDigest',btrim(v_existing.assessment_digest),
      'publicPayloadSha256',btrim(v_existing.public_payload_sha256),
      'resolvedAt',v_existing.published_at,
      'receiptDigest',btrim(v_existing.receipt_digest),
      'auditEventId',v_existing.audit_event_id,
      'outboxEventIds',v_existing.outbox_event_ids,'replayed',true
    );
  END IF;

  IF v_mode='PUBLISH' THEN
    SELECT * INTO v_step_up FROM ops.step_up_authorizations
    WHERE id=v_step_up_id AND closed_at IS NULL FOR SHARE;
    IF NOT FOUND OR v_step_up.expires_at<=v_now
       OR v_step_up.action_digest IS DISTINCT FROM v_action_digest
       OR v_step_up.idempotency_key_sha256 IS DISTINCT FROM v_idempotency
       OR v_step_up.assertion_issue_count NOT BETWEEN 1 AND 3
       OR v_step_up.last_issued_at IS NULL OR v_step_up.last_issued_at>v_now
       OR v_step_up.last_issued_at>=v_step_up.expires_at
       OR v_step_up.expires_at>v_step_up.last_issued_at
            +interval '5 minutes 5 seconds'
       OR NOT EXISTS(
         SELECT 1 FROM ops.sessions AS session
         WHERE session.id=v_step_up.session_id
           AND session.user_id=v_actor_id AND session.revoked_at IS NULL
           AND session.expires_at>v_now
       ) THEN
      RAISE EXCEPTION 'publication_revision_owner_step_up_invalid'
        USING ERRCODE='42501';
    END IF;
    SELECT * INTO v_case FROM editorial.cases
    WHERE id=v_case_id AND version=v_expected_version FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'publication_revision_owner_version_conflict'
        USING ERRCODE='40001';
    END IF;
    SELECT * INTO STRICT v_snapshot FROM editorial.review_snapshots
    WHERE id=v_snapshot_id AND case_id=v_case_id FOR SHARE;
    IF v_case.current_review_snapshot_id IS DISTINCT FROM v_snapshot_id
       OR v_snapshot.case_version IS DISTINCT FROM v_case.version THEN
      RAISE EXCEPTION 'publication_revision_owner_snapshot_stale'
        USING ERRCODE='40001';
    END IF;
    SELECT preview.* INTO STRICT v_preview
    FROM editorial.publication_previews AS preview
    JOIN editorial.publication_preview_owner_receipts_v2 AS receipt
      ON receipt.preview_id=preview.id
      AND receipt.case_id=preview.case_id
      AND receipt.review_snapshot_id=preview.review_snapshot_id
      AND receipt.public_payload_sha256=preview.preview_sha256
    WHERE preview.case_id=v_case_id
      AND preview.review_snapshot_id=v_snapshot_id
      AND preview.preview_sha256=v_preview_hash
      AND preview.expires_at>v_now AND receipt.expires_at>v_now
      AND receipt.case_version=v_expected_version
      AND receipt.status IN ('READY','BLOCKED')
    FOR SHARE OF preview,receipt;
    SELECT * INTO STRICT v_preview_receipt
    FROM editorial.publication_preview_owner_receipts_v2
    WHERE preview_id=v_preview.id FOR SHARE;
    v_payload:=v_preview.preview_payload;
    v_state:=v_preview_receipt.publication_state;
    IF v_preview.preview_sha256 IS DISTINCT FROM v_public_payload_sha
       OR v_payload->>'publicationState' IS DISTINCT FROM v_state::text
       OR v_preview_receipt.public_text_sha256 IS DISTINCT FROM
          (p_request->'scan'->>'publicTextSha256')::char(64)
       OR v_preview_receipt.registered_name_set_sha256 IS DISTINCT FROM
          (p_request->'scan'->>'registeredNameSetSha256')::char(64) THEN
      RAISE EXCEPTION 'publication_revision_owner_preview_mismatch'
        USING ERRCODE='23514';
    END IF;
    v_assessment:=editorial.record_named_person_publication_assessment_v1(
      jsonb_build_object(
        'caseId',v_case_id,'reviewSnapshotId',v_snapshot_id,
        'publicationState',v_state,'guardContext','PUBLISH',
        'publicPayload',v_payload,
        'publicPayloadSha256',btrim(v_public_payload_sha),
        'scan',p_request->'scan','legalOverride',NULL,
        '_actorId',v_actor_id,'_actorAssertionJti',v_actor_jti,
        '_actorAssuranceLevel',p_request->'_actorAssuranceLevel',
        '_actorEffectiveCapability',p_request->'_actorEffectiveCapability',
        '_actorActionDigest',p_request->'_actorActionDigest',
        '_actorStepUpAuthorizationId',p_request->'_actorStepUpAuthorizationId',
        '_actorIdempotencyKeySha256',
          p_request->'_actorIdempotencyKeySha256',
        '_actorRequestKeySha256',p_request->'_actorRequestKeySha256',
        '_requestId',v_request_id,
        '_idempotencyKeySha256',btrim(v_idempotency),
        '_requestSha256',btrim(v_request_digest)
      )
    );
    v_assessment_id:=(v_assessment->>'assessmentId')::uuid;
    v_assessment_digest:=(v_assessment->>'assessmentDigest')::char(64);
    v_prior_case_version:=v_case.version;
    v_case_version:=v_case.version+1;
    v_prior_revision:=COALESCE(v_case.current_publication_revision,0);
    v_revision:=v_prior_revision+1;
    v_revision_reason:=v_reason;
    v_revision_reason_sha:=v_reason_sha;
    v_audit:=ops.append_audit_event(
      'publication:'||v_case_id::text,'USER',v_actor_id::text,
      v_step_up.session_id,'command.publishCase','PublicationRevision',
      v_revision_id::text,'publication.publish','SUCCESS',NULL,
      v_request_id,jsonb_build_object(
        'caseVersion',v_case_version,'revision',v_revision,
        'reviewSnapshotId',v_snapshot_id,
        'assessmentDigest',btrim(v_assessment_digest),
        'previewSha256',btrim(v_preview_hash),
        'publicPayloadSha256',btrim(v_public_payload_sha),
        'reasonSha256',btrim(v_reason_sha)
      )
    );
    v_event_publication:=ops.enqueue_outbox(
      'publication_revision',v_revision_id::text,v_revision,
      'publication.revision_created.v1',jsonb_build_object(
        'actor_id',v_actor_id,'caseId',v_case_id,'occurred_at',v_now,
        'operation_id','publishCase','request_id',v_request_id,
        'reviewSnapshotId',v_snapshot_id
      ),v_now
    );
    v_event_projection:=ops.enqueue_outbox(
      'publication_revision',v_revision_id::text,v_revision,
      'projection.publication_revision_created.v1',jsonb_build_object(
        'actor_id',v_actor_id,'caseId',v_case_id,'occurred_at',v_now,
        'operation_id','publishCase','request_id',v_request_id,
        'reviewSnapshotId',v_snapshot_id
      ),v_now
    );
    v_event_notification:=ops.enqueue_outbox(
      'publication_revision',v_revision_id::text,v_revision,
      'notification.publication_created.v1',jsonb_build_object(
        'actor_id',v_actor_id,'caseId',v_case_id,'occurred_at',v_now,
        'operation_id','publishCase','request_id',v_request_id,
        'reviewSnapshotId',v_snapshot_id
      ),v_now
    );
    v_event_ids:=ARRAY[
      v_event_publication,v_event_projection,v_event_notification
    ];
  ELSE
    SELECT * INTO v_correction FROM editorial.corrections
    WHERE id=v_correction_id AND version=v_expected_version FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'correction_publication_owner_version_conflict'
        USING ERRCODE='40001';
    END IF;
    IF v_correction.status IS DISTINCT FROM 'REVIEW'
       OR v_correction.resolution IS NOT NULL THEN
      RAISE EXCEPTION 'correction_publication_owner_state_invalid'
        USING ERRCODE='23514';
    END IF;
    SELECT * INTO STRICT v_case FROM editorial.cases
    WHERE id=v_correction.case_id FOR UPDATE;
    v_case_id:=v_case.id;
    v_snapshot_id:=v_case.current_review_snapshot_id;
    IF v_snapshot_id IS NULL OR v_case.current_publication_revision IS NULL THEN
      RAISE EXCEPTION 'correction_publication_owner_source_missing'
        USING ERRCODE='23514';
    END IF;
    SELECT * INTO STRICT v_snapshot FROM editorial.review_snapshots
    WHERE id=v_snapshot_id AND case_id=v_case_id FOR SHARE;
    IF v_snapshot.case_version IS DISTINCT FROM v_case.version THEN
      RAISE EXCEPTION 'correction_publication_owner_snapshot_stale'
        USING ERRCODE='40001';
    END IF;
    SELECT * INTO STRICT v_source_revision
    FROM editorial.publication_revisions
    WHERE case_id=v_case_id
      AND revision=v_correction.source_revision FOR SHARE;
    v_source_snapshot_id:=v_source_revision.review_snapshot_id;
    IF v_case.current_publication_revision IS DISTINCT FROM
         v_correction.source_revision
       OR v_source_revision.case_id IS DISTINCT FROM v_case_id
       OR v_source_revision.revision IS DISTINCT FROM
         v_correction.source_revision THEN
      RAISE EXCEPTION 'correction_publication_owner_source_stale'
        USING ERRCODE='40001';
    END IF;
    v_payload:=editorial.build_corrected_publication_payload_v2(
      v_correction_id,v_expected_version,v_reason
    );
    IF encode(extensions.digest(
         ops.canonical_jsonb_v1(v_payload),'sha256'
       ),'hex') IS DISTINCT FROM v_public_payload_sha THEN
      RAISE EXCEPTION 'correction_publication_owner_payload_digest_mismatch'
        USING ERRCODE='23514';
    END IF;
    v_state:='CORRECTED';
    v_assessment:=editorial.record_named_person_publication_assessment_v1(
      jsonb_build_object(
        'caseId',v_case_id,'reviewSnapshotId',v_snapshot_id,
        'publicationState','CORRECTED','guardContext','CORRECTION',
        'publicPayload',v_payload,
        'publicPayloadSha256',btrim(v_public_payload_sha),
        'scan',p_request->'scan','legalOverride',NULL,
        '_actorId',v_actor_id,'_actorAssertionJti',v_actor_jti,
        '_actorAssuranceLevel',p_request->'_actorAssuranceLevel',
        '_actorEffectiveCapability',p_request->'_actorEffectiveCapability',
        '_actorActionDigest',p_request->'_actorActionDigest',
        '_actorStepUpAuthorizationId',NULL,
        '_actorIdempotencyKeySha256',
          p_request->'_actorIdempotencyKeySha256',
        '_actorRequestKeySha256',p_request->'_actorRequestKeySha256',
        '_requestId',v_request_id,
        '_idempotencyKeySha256',btrim(v_idempotency),
        '_requestSha256',btrim(v_request_digest)
      )
    );
    v_assessment_id:=(v_assessment->>'assessmentId')::uuid;
    v_assessment_digest:=(v_assessment->>'assessmentDigest')::char(64);
    v_prior_case_version:=v_case.version;
    v_case_version:=v_case.version+1;
    v_prior_correction_version:=v_correction.version;
    v_correction_version:=v_correction.version+1;
    v_prior_revision:=v_source_revision.revision;
    v_revision:=v_prior_revision+1;
    v_revision_reason:=NULLIF(btrim(v_correction.reason),'');
    IF v_revision_reason IS NULL THEN
      RAISE EXCEPTION 'correction_publication_revision_reason_missing'
        USING ERRCODE='23514';
    END IF;
    v_revision_reason_sha:=encode(extensions.digest(
      convert_to(v_revision_reason,'UTF8'),'sha256'
    ),'hex');
    SELECT count(*) INTO v_task_count
    FROM (
      SELECT task.id FROM ops.tasks AS task
      WHERE task.object_type='CORRECTION'
        AND task.object_id=v_correction_id
        AND task.status IN ('OPEN','IN_PROGRESS','BLOCKED')
      FOR UPDATE
    ) AS locked_task;
    IF v_task_count>1 THEN
      RAISE EXCEPTION 'correction_publication_task_ambiguous'
        USING ERRCODE='23514';
    ELSIF v_task_count=1 THEN
      SELECT * INTO STRICT v_correction_task
      FROM ops.tasks AS task
      WHERE task.object_type='CORRECTION'
        AND task.object_id=v_correction_id
        AND task.status IN ('OPEN','IN_PROGRESS','BLOCKED')
      FOR UPDATE;
      v_task_version_before:=v_correction_task.version;
    END IF;
    v_audit:=ops.append_audit_event(
      'correction:'||v_correction_id::text,'USER',v_actor_id::text,NULL::uuid,
      'command.resolveCorrectionRequest','Correction',v_correction_id::text,
      'publication.correct','SUCCESS',NULL,v_request_id,
      jsonb_build_object(
        'correctionVersion',v_correction_version,
        'caseId',v_case_id,'caseVersion',v_case_version,
        'revisionId',v_revision_id,'revision',v_revision,
        'reviewSnapshotId',v_snapshot_id,
        'assessmentDigest',btrim(v_assessment_digest),
        'publicPayloadSha256',btrim(v_public_payload_sha),
        'reasonSha256',btrim(v_reason_sha),
        'revisionReasonSha256',btrim(v_revision_reason_sha)
      )
    );
    v_event_correction:=ops.enqueue_outbox(
      'correction',v_correction_id::text,v_correction_version,
      'correction.resolved.v1',jsonb_build_object(
        'actor_id',v_actor_id,'correction_id',v_correction_id,
        'occurred_at',v_now,'operation_id','resolveCorrectionRequest',
        'request_id',v_request_id
      ),v_now
    );
    v_event_notification:=ops.enqueue_outbox(
      'correction',v_correction_id::text,v_correction_version,
      'notification.correction_resolved.v1',jsonb_build_object(
        'actor_id',v_actor_id,'correction_id',v_correction_id,
        'occurred_at',v_now,'operation_id','resolveCorrectionRequest',
        'request_id',v_request_id
      ),v_now
    );
    v_event_publication:=ops.enqueue_outbox(
      'publication_revision',v_revision_id::text,v_revision,
      'publication.revision_created.v1',jsonb_build_object(
        'actor_id',v_actor_id,'caseId',v_case_id,'occurred_at',v_now,
        'operation_id','resolveCorrectionRequest','request_id',v_request_id,
        'reviewSnapshotId',v_snapshot_id
      ),v_now
    );
    v_event_projection:=ops.enqueue_outbox(
      'publication_revision',v_revision_id::text,v_revision,
      'projection.publication_revision_created.v1',jsonb_build_object(
        'actor_id',v_actor_id,'caseId',v_case_id,'occurred_at',v_now,
        'operation_id','resolveCorrectionRequest','request_id',v_request_id,
        'reviewSnapshotId',v_snapshot_id
      ),v_now
    );
    v_event_ids:=ARRAY[
      v_event_correction,v_event_notification,
      v_event_publication,v_event_projection
    ];
  END IF;

  SELECT stage.* INTO STRICT v_editorial_stage
  FROM editorial.named_person_review_stage_receipts_v1 AS stage
  JOIN editorial.review_decisions AS decision
    ON decision.id=stage.decision_id
    AND decision.review_snapshot_id=stage.review_snapshot_id
    AND decision.reviewer_id=stage.reviewer_user_id
    AND decision.decision='APPROVE'
  JOIN editorial.review_assignments AS assignment
    ON assignment.id=stage.review_assignment_id
    AND assignment.case_id=stage.case_id
    AND assignment.review_snapshot_id=stage.review_snapshot_id
    AND assignment.reviewer_id=stage.reviewer_user_id
    AND assignment.status='COMPLETED'
    AND assignment.version=stage.review_assignment_version_after
  JOIN ops.outbox AS stage_outbox
    ON stage_outbox.id=stage.outbox_event_id
    AND stage_outbox.aggregate_type='ReviewDecision'
    AND stage_outbox.aggregate_id=stage.decision_id::text
    AND stage_outbox.aggregate_version=1
    AND stage_outbox.event_type='review.decision_submitted.v1'
  WHERE stage.review_snapshot_id=v_snapshot_id
    AND stage.case_id=v_case_id
    AND stage.case_version=v_prior_case_version
    AND stage.review_stage='EDITORIAL' AND stage.decision='APPROVE'
    AND stage.assurance_level='STEP_UP'
    AND stage.effective_capability='review.editorial'
    AND stage.reviewer_user_id<>v_snapshot.created_by
    AND stage.reviewer_user_id<>v_actor_id
    AND stage.decision_digest=editorial.review_decision_digest_v1(decision.id)
    AND stage.outbox_event_digest=
      ops.r6d_outbox_envelope_digest_v1(stage_outbox.id)
    AND stage.receipt_payload->>'decisionDigest'=btrim(stage.decision_digest)
    AND stage.receipt_payload->>'outboxEventDigest'=
      btrim(stage.outbox_event_digest)
  FOR SHARE OF stage,decision,assignment,stage_outbox;

  SELECT array_agg(value ORDER BY value) INTO STRICT v_event_ids
  FROM unnest(v_event_ids) AS emitted(value);
  SELECT event_hash INTO STRICT v_audit_digest
  FROM ops.audit_events WHERE id=v_audit;
  SELECT count(*),array_agg(outbox.event_type ORDER BY outbox.event_type),
    jsonb_agg(jsonb_build_object(
      'eventId',outbox.id,'eventType',outbox.event_type,
      'eventEnvelopeDigest',ops.r6d_outbox_envelope_digest_v1(outbox.id)
    ) ORDER BY outbox.event_type)
  INTO v_event_count,v_event_types,v_outbox_proofs
  FROM ops.outbox AS outbox WHERE outbox.id=ANY(v_event_ids);
  IF NOT ops.r6d_uuid_array_sorted_unique_v1(v_event_ids)
     OR (v_mode='PUBLISH' AND (
       v_event_count IS DISTINCT FROM 3 OR cardinality(v_event_ids)<>3
       OR v_event_types IS DISTINCT FROM ARRAY[
         'notification.publication_created.v1',
         'projection.publication_revision_created.v1',
         'publication.revision_created.v1'
       ]::text[]
     )) OR (v_mode='CORRECTION' AND (
       v_event_count IS DISTINCT FROM 4 OR cardinality(v_event_ids)<>4
       OR v_event_types IS DISTINCT FROM ARRAY[
         'correction.resolved.v1','notification.correction_resolved.v1',
         'projection.publication_revision_created.v1',
         'publication.revision_created.v1'
       ]::text[]
     )) THEN
    RAISE EXCEPTION 'publication_revision_owner_outbox_set_invalid'
      USING ERRCODE='23514';
  END IF;
  v_receipt_payload:=jsonb_strip_nulls(jsonb_build_object(
    'schemaVersion','publication-revision-owner-receipt.v2','mode',v_mode,
    'caseId',v_case_id,'priorCaseVersion',v_prior_case_version,
    'caseVersion',v_case_version,'reviewSnapshotId',v_snapshot_id,
    'sourceReviewSnapshotId',v_source_snapshot_id,
    'revisionId',v_revision_id,'revision',v_revision,
    'publicationState',v_state,'assessmentId',v_assessment_id,
    'assessmentDigest',btrim(v_assessment_digest),
    'editorialReviewStageReceiptId',v_editorial_stage.receipt_id,
    'editorialReviewStageReceiptDigest',
      btrim(v_editorial_stage.receipt_digest),
    'actorActionDigest',btrim(v_action_digest),
    'stepUpAuthorizationId',v_step_up_id,
    'commandReasonSha256',btrim(v_reason_sha),
    'revisionReasonSha256',btrim(v_revision_reason_sha),
    'previewSha256',CASE WHEN v_mode='PUBLISH'
      THEN btrim(v_preview_hash) ELSE NULL END,
    'publicPayloadSha256',btrim(v_public_payload_sha),
    'correctionId',v_correction_id,
    'priorCorrectionVersion',v_prior_correction_version,
    'correctionVersion',v_correction_version,
    'auditEventId',v_audit,'auditEventDigest',btrim(v_audit_digest),
    'outboxEvents',v_outbox_proofs,'requestId',v_request_id,
    'requestDigest',btrim(v_request_digest),'publishedAt',v_now
  ));
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_receipt_digest:=encode(
    extensions.digest(v_receipt_canonical,'sha256'),'hex'
  );
  INSERT INTO editorial.publication_revision_owner_receipts_v2(
    receipt_id,mode,case_id,prior_case_version,case_version,
    review_snapshot_id,source_review_snapshot_id,revision_id,revision,
    publication_state,assessment_id,
    assessment_digest,preview_sha256,public_payload_sha256,correction_id,
    prior_correction_version,correction_version,actor_id,actor_assertion_jti,
    actor_action_digest,step_up_authorization_id,
    editorial_review_stage_receipt_id,
    editorial_review_stage_receipt_digest,revision_reason_sha256,
    command_reason_sha256,
    request_id,idempotency_key_sha256,request_digest,audit_event_id,
    outbox_event_ids,receipt_payload,receipt_canonical,receipt_digest,
    published_at
  ) VALUES(
    v_owner_receipt_id,v_mode,v_case_id,v_prior_case_version,v_case_version,
    v_snapshot_id,v_source_snapshot_id,v_revision_id,v_revision,v_state,
    v_assessment_id,
    v_assessment_digest,CASE WHEN v_mode='PUBLISH' THEN v_preview_hash END,
    v_public_payload_sha,v_correction_id,v_prior_correction_version,
    v_correction_version,v_actor_id,v_actor_jti,v_action_digest,v_step_up_id,
    v_editorial_stage.receipt_id,v_editorial_stage.receipt_digest,
    v_revision_reason_sha,v_reason_sha,v_request_id,v_idempotency,
    v_request_digest,v_audit,v_event_ids,v_receipt_payload,
    v_receipt_canonical,v_receipt_digest,v_now
  );

  INSERT INTO editorial.publication_revisions(
    id,case_id,revision,state,review_snapshot_id,public_payload,
    public_payload_sha256,preview_sha256,published_by,published_at,
    supersedes_revision,reason
  ) VALUES(
    v_revision_id,v_case_id,v_revision,v_state,v_snapshot_id,v_payload,
    v_public_payload_sha,
    CASE WHEN v_mode='PUBLISH' THEN v_preview_hash
      ELSE v_public_payload_sha END,
    v_actor_id,v_now,NULLIF(v_prior_revision,0),v_revision_reason
  );
  IF v_mode='PUBLISH' THEN
    UPDATE editorial.cases
    SET publication_state=v_state,current_publication_revision=v_revision,
        version=version+1,updated_at=v_now
    WHERE id=v_case_id AND version=v_prior_case_version;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'publication_revision_owner_version_conflict'
        USING ERRCODE='40001';
    END IF;
  ELSE
    UPDATE editorial.corrections
    SET target_revision=v_revision,status='PUBLISHED',resolution='RESOLVED',
        resolution_reason=v_reason,resolved_at=v_now,version=version+1,
        updated_at=v_now
    WHERE id=v_correction_id AND version=v_prior_correction_version
      AND status='REVIEW' AND resolution IS NULL;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'correction_publication_owner_version_conflict'
        USING ERRCODE='40001';
    END IF;
    UPDATE editorial.cases
    SET publication_state='CORRECTED',current_publication_revision=v_revision,
        version=version+1,updated_at=v_now
    WHERE id=v_case_id AND version=v_prior_case_version;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'correction_publication_case_version_conflict'
        USING ERRCODE='40001';
    END IF;
    IF v_task_count=1 THEN
      UPDATE ops.tasks
      SET status='DONE',completed_at=v_now,version=version+1,updated_at=v_now
      WHERE id=v_correction_task.id AND version=v_task_version_before
        AND object_type='CORRECTION' AND object_id=v_correction_id
        AND status IN ('OPEN','IN_PROGRESS','BLOCKED')
      RETURNING * INTO STRICT v_correction_task;
    END IF;
  END IF;
  IF v_mode='PUBLISH' THEN
    RETURN jsonb_build_object(
      'caseId',v_case_id,'caseVersion',v_case_version,
      'reviewSnapshotId',v_snapshot_id,'revisionId',v_revision_id,
      'revision',v_revision,'publicationState',v_state,
      'assessmentId',v_assessment_id,
      'assessmentDigest',btrim(v_assessment_digest),
      'previewSha256',btrim(v_preview_hash),
      'publicPayloadSha256',btrim(v_public_payload_sha),
      'publishedAt',v_now,'receiptDigest',btrim(v_receipt_digest),
      'auditEventId',v_audit,'outboxEventIds',v_event_ids,'replayed',false
    );
  END IF;
  RETURN jsonb_build_object(
    'correctionId',v_correction_id,'correctionVersion',v_correction_version,
    'caseId',v_case_id,'caseVersion',v_case_version,
    'reviewSnapshotId',v_snapshot_id,'revisionId',v_revision_id,
    'revision',v_revision,'publicationState',v_state,
    'assessmentId',v_assessment_id,
    'assessmentDigest',btrim(v_assessment_digest),
    'publicPayloadSha256',btrim(v_public_payload_sha),'resolvedAt',v_now,
    'receiptDigest',btrim(v_receipt_digest),'auditEventId',v_audit,
    'outboxEventIds',v_event_ids,'replayed',false
  );
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'publication_revision_owner_authority_missing_or_ambiguous'
    USING ERRCODE='23514';
END
$$;
ALTER FUNCTION editorial.publish_guarded_revision_v2(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION editorial.publish_guarded_revision_v2(jsonb)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION editorial.publish_guarded_revision_v2(jsonb)
  TO gurine_control_api;

-- Close direct DML on the two public-byte archives. The guarded SECURITY
-- DEFINER owners remain the only control-api mutation surface.
REVOKE INSERT,UPDATE,DELETE ON editorial.publication_previews
  FROM gurine_control_api;
REVOKE INSERT,UPDATE,DELETE ON editorial.publication_revisions
  FROM gurine_control_api;
REVOKE INSERT,UPDATE,DELETE ON
  editorial.named_person_publication_assessments,
  editorial.named_person_publication_findings,
  editorial.named_person_legal_overrides,
  editorial.publication_preview_owner_receipts_v2,
  editorial.publication_revision_owner_receipts_v2
  FROM gurine_control_api;

-- SECURITY DEFINER bodies run as gurine_migrator.  Grant only the exact base
-- relation privileges they need; application roles retain the DML revocations
-- above and reach these rows only through the closed owners.
GRANT SELECT ON
  editorial.review_snapshots,
  editorial.review_assignments,
  editorial.review_decisions,
  editorial.cases,
  editorial.corrections,
  editorial.publication_previews,
  editorial.publication_revisions,
  ops.tasks,
  ops.step_up_authorizations,
  ops.sessions,
  ops.audit_events,
  ops.outbox
TO gurine_migrator;
GRANT INSERT ON editorial.review_decisions,
  editorial.publication_previews,
  editorial.publication_revisions
TO gurine_migrator;
GRANT UPDATE ON editorial.review_assignments,
  editorial.cases,
  editorial.corrections,
  ops.tasks
TO gurine_migrator;

-- Preserve the non-publication legacy operations still reached through the
-- provisional dispatcher, but make its two R6d-owned operations fail before
-- any legacy DML.  Clone the pre-R6d implementation under a private name, then
-- CREATE OR REPLACE the original function.  Keeping the original OID is
-- required: an already compiled SECURITY DEFINER dispatcher may have cached
-- that OID, so ALTER RENAME plus a new function would leave a live side door.
DO $clone_signal_publication_legacy$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
       'ops.apply_signal_publication_command_legacy_v1(text,jsonb,uuid,uuid,uuid,character,character)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'r6d_signal_publication_legacy_clone_already_exists'
      USING ERRCODE='55000';
  END IF;
  SELECT pg_get_functiondef(
    'ops.apply_signal_publication_command_v1(text,jsonb,uuid,uuid,uuid,character,character)'::regprocedure
  ) INTO STRICT v_definition;
  v_definition:=replace(
    v_definition,
    'ops.apply_signal_publication_command_v1',
    'ops.apply_signal_publication_command_legacy_v1'
  );
  EXECUTE v_definition;
END
$clone_signal_publication_legacy$;
REVOKE ALL ON FUNCTION ops.apply_signal_publication_command_legacy_v1(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC,gurine_control_api;

CREATE OR REPLACE FUNCTION ops.apply_signal_publication_command_v1(
  p_operation_id text,
  p_payload jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key_hash char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF p_operation_id IN ('submitReview','publishCase') THEN
    RAISE EXCEPTION 'r6d_publication_owner_required:%',p_operation_id
      USING ERRCODE='42501';
  END IF;
  RETURN ops.apply_signal_publication_command_legacy_v1(
    p_operation_id,p_payload,p_actor_id,p_session_id,p_request_id,
    p_idempotency_key_hash,p_request_digest
  );
END
$$;
ALTER FUNCTION ops.apply_signal_publication_command_v1(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_signal_publication_command_v1(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.apply_signal_publication_command_v1(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- The retired correction owner contains two publication-producing branches.
-- Use the same OID-preserving replacement strategy as the signal/publication
-- adapter so cached dispatcher plans cannot retain a bypass.
DO $clone_correction_publication_legacy$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
       'ops.apply_correction_publication_command_legacy_v1(text,jsonb,uuid,uuid,uuid,character,character)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'r6d_correction_publication_legacy_clone_already_exists'
      USING ERRCODE='55000';
  END IF;
  SELECT pg_get_functiondef(
    'ops.apply_correction_publication_command_v1(text,jsonb,uuid,uuid,uuid,character,character)'::regprocedure
  ) INTO STRICT v_definition;
  v_definition:=replace(
    v_definition,
    'ops.apply_correction_publication_command_v1',
    'ops.apply_correction_publication_command_legacy_v1'
  );
  EXECUTE v_definition;
END
$clone_correction_publication_legacy$;
REVOKE ALL ON FUNCTION ops.apply_correction_publication_command_legacy_v1(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC,gurine_control_api;

CREATE OR REPLACE FUNCTION ops.apply_correction_publication_command_v1(
  p_operation_id text,
  p_payload jsonb,
  p_actor_id uuid,
  p_session_id uuid,
  p_request_id uuid,
  p_idempotency_key_hash char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
BEGIN
  IF p_operation_id IN ('createCorrectionCase','publishCorrection') THEN
    RAISE EXCEPTION 'r6d_correction_publication_owner_required:%',p_operation_id
      USING ERRCODE='42501';
  END IF;
  RETURN ops.apply_correction_publication_command_legacy_v1(
    p_operation_id,p_payload,p_actor_id,p_session_id,p_request_id,
    p_idempotency_key_hash,p_request_digest
  );
END
$$;
ALTER FUNCTION ops.apply_correction_publication_command_v1(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_correction_publication_command_v1(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.apply_correction_publication_command_v1(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;
-- R6d publication owner fragment ends.

-- R6d retention and legal-hold owner integration begins.
-- P0 authority overlay. The HTTP caller supplies no anchor identifier or
-- anchor digest. The owner locks the concrete target, derives/reuses the
-- canonical anchor, and persists the exact actor/STEP_UP/conflict proof tuple.
-- The original 0038 context check only treated entity snapshots as non-case
-- targets, although the closed target union also contains four independently
-- governed non-case objects.  Keep case context on the four editorial kinds
-- and require it to be absent on every non-case kind.
-- The original conflict target catalog omitted four legal-hold branches even
-- though placeLegalHold is defined over the closed ten-kind target union.
-- Expanding only this discriminator lets the independent conflict evaluator
-- issue an exact proof for every legal-hold target; no relationship kind or
-- publication permission is broadened.
ALTER TABLE editorial.conflict_snapshots
  DROP CONSTRAINT conflict_snapshots_target_type_ck;
ALTER TABLE editorial.conflict_snapshots
  ADD CONSTRAINT conflict_snapshots_target_type_ck CHECK (
    target_type IN (
      'CASE','REVIEW_SNAPSHOT','ACTION_PROPOSAL','PUBLICATION',
      'COMMUNICATION_INTENT','RESPONSE_REQUEST','LEGAL_HOLD','CAPABILITY',
      'SOURCE_ASSET','RESEARCH_ARTIFACT','PRIVACY_REQUEST',
      'COMMUNICATION_SUBJECT','EVIDENCE','RESPONSE',
      'SUPPLIER_RETENTION_SNAPSHOT','AGENCY_RETENTION_SNAPSHOT'
    ) AND target_version>0
  );
CREATE OR REPLACE FUNCTION ops.place_legal_hold_v2(
  p_payload jsonb,
  p_actor_id uuid,
  p_request_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
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
       'CASE','PUBLICATION','EVIDENCE','RESPONSE','SOURCE_ASSET',
       'RESEARCH_ARTIFACT','PRIVACY_REQUEST','COMMUNICATION_SUBJECT',
       'SUPPLIER_RETENTION_SNAPSHOT','AGENCY_RETENTION_SNAPSHOT'
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

  IF (v_target_kind='CASE' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest','caseId',
          'reviewSnapshotId','reviewSnapshotDigest'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest','caseId',
          'reviewSnapshotId','reviewSnapshotDigest'
        ]='{}'::jsonb
        AND v_target_input->>'caseId'=v_target_input->>'targetId'
        AND v_target_input->>'caseId' ~*
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND v_target_input->>'reviewSnapshotId' ~*
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND v_target_input->>'reviewSnapshotDigest' ~ '^[0-9a-f]{64}$'))
     OR (v_target_kind='PUBLICATION' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'publicationRevisionId'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'publicationRevisionId'
        ]='{}'::jsonb
        AND v_target_input->>'publicationRevisionId'=
          v_target_input->>'targetId'))
     OR (v_target_kind='EVIDENCE' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest','evidenceId'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest','evidenceId'
        ]='{}'::jsonb
        AND v_target_input->>'evidenceId'=v_target_input->>'targetId'))
     OR (v_target_kind='RESPONSE' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest','responseId'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest','responseId'
        ]='{}'::jsonb
        AND v_target_input->>'responseId'=v_target_input->>'targetId'))
     OR (v_target_kind='SOURCE_ASSET' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'sourceDocumentId','sourceAssetId'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'sourceDocumentId','sourceAssetId'
        ]='{}'::jsonb
        AND v_target_input->>'sourceAssetId'=v_target_input->>'targetId'
        AND v_target_input->>'sourceDocumentId' ~*
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
     OR (v_target_kind='RESEARCH_ARTIFACT' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'researchArtifactId','researchAssetId'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'researchArtifactId','researchAssetId'
        ]='{}'::jsonb
        AND v_target_input->>'researchAssetId'=v_target_input->>'targetId'
        AND v_target_input->>'researchArtifactId' ~*
          '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
     OR (v_target_kind='PRIVACY_REQUEST' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'privacyRequestId','privacyRequestType'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'privacyRequestId','privacyRequestType'
        ]='{}'::jsonb
        AND v_target_input->>'privacyRequestId'=v_target_input->>'targetId'
        AND v_target_input->>'privacyRequestType' IN (
          'ACCESS','CORRECTION','DELETION','RESTRICTION'
        )))
     OR (v_target_kind='COMMUNICATION_SUBJECT' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'communicationSubjectId','communicationSubjectOriginDigest'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest',
          'communicationSubjectId','communicationSubjectOriginDigest'
        ]='{}'::jsonb
        AND v_target_input->>'communicationSubjectId'=
          v_target_input->>'targetId'
        AND v_target_input->>'communicationSubjectOriginDigest' ~
          '^[0-9a-f]{64}$'))
     OR (v_target_kind='SUPPLIER_RETENTION_SNAPSHOT' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest','entityKind',
          'entityRetentionSnapshotId','entityRetentionSnapshotDigest'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest','entityKind',
          'entityRetentionSnapshotId','entityRetentionSnapshotDigest'
        ]='{}'::jsonb
        AND v_target_input->>'entityKind'='SUPPLIER'
        AND v_target_input->>'entityRetentionSnapshotId'=
          v_target_input->>'targetId'
        AND v_target_input->>'entityRetentionSnapshotDigest'=
          v_target_input->>'targetDigest'))
     OR (v_target_kind='AGENCY_RETENTION_SNAPSHOT' AND NOT (
        v_target_input ?& ARRAY[
          'targetKind','targetId','targetVersion','targetDigest','entityKind',
          'entityRetentionSnapshotId','entityRetentionSnapshotDigest'
        ] AND v_target_input-ARRAY[
          'targetKind','targetId','targetVersion','targetDigest','entityKind',
          'entityRetentionSnapshotId','entityRetentionSnapshotDigest'
        ]='{}'::jsonb
        AND v_target_input->>'entityKind'='AGENCY'
        AND v_target_input->>'entityRetentionSnapshotId'=
          v_target_input->>'targetId'
        AND v_target_input->>'entityRetentionSnapshotDigest'=
          v_target_input->>'targetDigest')) THEN
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
    WHEN 'CASE' THEN
      SELECT * INTO v_case FROM editorial.cases
      WHERE id=v_target_id FOR SHARE;
      SELECT * INTO v_review FROM editorial.review_snapshots
      WHERE id=(v_target_input->>'reviewSnapshotId')::uuid FOR SHARE;
      IF v_case.id IS NULL OR v_review.id IS NULL
         OR v_case.version<>v_target_version
         OR v_case.current_review_snapshot_id<>v_review.id
         OR v_review.case_id<>v_case.id
         OR v_review.case_version<>v_case.version
         OR v_review.snapshot_sha256<>v_target_digest
         OR v_review.snapshot_sha256<>
           (v_target_input->>'reviewSnapshotDigest')::char(64) THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      v_case_id:=v_case.id;
      v_snapshot_id:=v_review.id;
      v_case_anchor_id:=v_case.id;
      v_case_anchor_snapshot_id:=v_review.id;
    WHEN 'PUBLICATION' THEN
      SELECT * INTO v_publication FROM editorial.publication_revisions
      WHERE id=v_target_id FOR SHARE;
      IF v_publication.id IS NULL
         OR v_publication.revision<>v_target_version
         OR v_publication.public_payload_sha256<>v_target_digest THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      v_case_id:=v_publication.case_id;
      v_snapshot_id:=v_publication.review_snapshot_id;
      v_publication_id:=v_publication.id;
    WHEN 'EVIDENCE' THEN
      SELECT * INTO v_evidence FROM editorial.evidence
      WHERE id=v_target_id FOR SHARE;
      IF v_evidence.id IS NULL OR v_evidence.version<>v_target_version
         OR v_evidence.content_sha256<>v_target_digest THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      SELECT * INTO v_case FROM editorial.cases
      WHERE id=v_evidence.case_id FOR SHARE;
      IF v_case.id IS NULL OR v_case.current_review_snapshot_id IS NULL THEN
        RAISE EXCEPTION 'legal_hold_v2_case_context_missing'
          USING ERRCODE='23514';
      END IF;
      v_case_id:=v_case.id;
      v_snapshot_id:=v_case.current_review_snapshot_id;
      v_evidence_id:=v_evidence.id;
    WHEN 'RESPONSE' THEN
      SELECT * INTO v_response FROM editorial.responses
      WHERE id=v_target_id FOR SHARE;
      IF v_response.id IS NULL OR v_response.version<>v_target_version
         OR v_response.response_content_sha256 IS NULL
         OR v_response.response_content_sha256<>v_target_digest THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      SELECT * INTO v_case FROM editorial.cases
      WHERE id=v_response.case_id FOR SHARE;
      IF v_case.id IS NULL OR v_case.current_review_snapshot_id IS NULL THEN
        RAISE EXCEPTION 'legal_hold_v2_case_context_missing'
          USING ERRCODE='23514';
      END IF;
      v_case_id:=v_case.id;
      v_snapshot_id:=v_case.current_review_snapshot_id;
      v_response_id:=v_response.id;
    WHEN 'SOURCE_ASSET' THEN
      SELECT * INTO v_source FROM raw.source_documents
      WHERE id=(v_target_input->>'sourceDocumentId')::uuid
        AND asset_id=v_target_id FOR SHARE;
      IF v_source.id IS NULL OR v_source.asset_revision<>v_target_version
         OR v_source.content_sha256<>v_target_digest THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      v_source_document_id:=v_source.id;
      v_source_asset_id:=v_source.asset_id;
    WHEN 'RESEARCH_ARTIFACT' THEN
      SELECT * INTO v_research FROM raw.research_artifacts
      WHERE id=(v_target_input->>'researchArtifactId')::uuid
        AND asset_id=v_target_id FOR SHARE;
      IF v_research.id IS NULL OR v_research.asset_revision<>v_target_version
         OR v_research.content_sha256<>v_target_digest THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      v_research_artifact_id:=v_research.id;
      v_research_asset_id:=v_research.asset_id;
    WHEN 'PRIVACY_REQUEST' THEN
      SELECT * INTO v_privacy FROM ops.retention_requests
      WHERE id=v_target_id FOR SHARE;
      SELECT * INTO v_privacy_decision FROM ops.retention_request_decisions
      WHERE retention_request_id=v_target_id
        AND decision_version=v_target_version FOR SHARE;
      IF v_privacy.id IS NULL OR v_privacy_decision.id IS NULL
         OR v_privacy.request_type<>v_target_input->>'privacyRequestType'
         OR v_privacy.decision_version<>v_target_version
         OR v_privacy_decision.request_type<>v_privacy.request_type
         OR v_privacy_decision.inventory_snapshot_digest<>v_target_digest THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      v_privacy_request_id:=v_privacy.id;
      v_privacy_request_type:=v_privacy.request_type;
    WHEN 'COMMUNICATION_SUBJECT' THEN
      SELECT * INTO v_subject FROM intake.communication_subjects
      WHERE id=v_target_id FOR SHARE;
      IF v_subject.id IS NULL OR v_subject.profile_version<>v_target_version
         OR v_subject.profile_digest<>v_target_digest
         OR v_subject.origin_binding_digest<>
           (v_target_input->>'communicationSubjectOriginDigest')::char(64) THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      v_communication_subject_id:=v_subject.id;
      v_communication_origin_digest:=v_subject.origin_binding_digest;
    WHEN 'SUPPLIER_RETENTION_SNAPSHOT' THEN
      SELECT * INTO v_entity FROM ops.entity_retention_snapshots_v1
      WHERE snapshot_id=v_target_id FOR SHARE;
      IF v_entity.snapshot_id IS NULL OR v_entity.subject_kind<>'SUPPLIER'
         OR v_entity.subject_version<>v_target_version
         OR v_entity.snapshot_digest<>v_target_digest THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      v_entity_snapshot_id:=v_entity.snapshot_id;
      v_entity_snapshot_digest:=v_entity.snapshot_digest;
    WHEN 'AGENCY_RETENTION_SNAPSHOT' THEN
      SELECT * INTO v_entity FROM ops.entity_retention_snapshots_v1
      WHERE snapshot_id=v_target_id FOR SHARE;
      IF v_entity.snapshot_id IS NULL OR v_entity.subject_kind<>'AGENCY'
         OR v_entity.subject_version<>v_target_version
         OR v_entity.snapshot_digest<>v_target_digest THEN
        RAISE EXCEPTION 'legal_hold_v2_target_stale' USING ERRCODE='40001';
      END IF;
      v_entity_snapshot_id:=v_entity.snapshot_id;
      v_entity_snapshot_digest:=v_entity.snapshot_digest;
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
      entity_retention_snapshot_digest,anchor_digest,audit_event_id
    ) VALUES(
      v_anchor_id,v_target_kind,v_target_id,v_target_version,v_target_digest,
      v_case_anchor_id,v_case_anchor_snapshot_id,v_publication_id,v_evidence_id,
      v_response_id,v_source_document_id,v_source_asset_id,
      v_research_artifact_id,v_research_asset_id,v_privacy_request_id,
      v_privacy_request_type,v_communication_subject_id,
      v_communication_origin_digest,v_entity_snapshot_id,
      v_entity_snapshot_digest,v_anchor_digest,v_audit
    ) RETURNING * INTO v_anchor;
  END IF;
  IF v_anchor.anchor_digest<>v_anchor_digest
     OR (v_target_kind='CASE' AND (
       v_anchor.case_id IS DISTINCT FROM v_case_anchor_id
       OR v_anchor.case_review_snapshot_id IS DISTINCT FROM
         v_case_anchor_snapshot_id))
     OR (v_target_kind='PUBLICATION' AND
       v_anchor.publication_revision_id IS DISTINCT FROM v_publication_id)
     OR (v_target_kind='EVIDENCE' AND
       v_anchor.evidence_id IS DISTINCT FROM v_evidence_id)
     OR (v_target_kind='RESPONSE' AND
       v_anchor.response_id IS DISTINCT FROM v_response_id)
     OR (v_target_kind='SOURCE_ASSET' AND (
       v_anchor.source_document_id IS DISTINCT FROM v_source_document_id
       OR v_anchor.source_asset_id IS DISTINCT FROM v_source_asset_id))
     OR (v_target_kind='RESEARCH_ARTIFACT' AND (
       v_anchor.research_artifact_id IS DISTINCT FROM v_research_artifact_id
       OR v_anchor.research_asset_id IS DISTINCT FROM v_research_asset_id))
     OR (v_target_kind='PRIVACY_REQUEST' AND (
       v_anchor.privacy_request_id IS DISTINCT FROM v_privacy_request_id
       OR v_anchor.privacy_request_type IS DISTINCT FROM
         v_privacy_request_type))
     OR (v_target_kind='COMMUNICATION_SUBJECT' AND (
       v_anchor.communication_subject_id IS DISTINCT FROM
         v_communication_subject_id
       OR v_anchor.communication_subject_origin_digest IS DISTINCT FROM
         v_communication_origin_digest))
     OR (v_target_kind IN (
       'SUPPLIER_RETENTION_SNAPSHOT','AGENCY_RETENTION_SNAPSHOT'
     ) AND (
       v_anchor.entity_retention_snapshot_id IS DISTINCT FROM
         v_entity_snapshot_id
       OR v_anchor.entity_retention_snapshot_digest IS DISTINCT FROM
         v_entity_snapshot_digest)) THEN
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
ALTER FUNCTION ops.place_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.place_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.place_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- Legal-hold release v2.
--
-- The 0028 release relation is the append-only authority for coverage cells.
-- Its original columns are preserved for legacy rows, while these nullable
-- extension columns make a v2 row self-verifying.  A v2 placement can only be
-- released by the v2 owner below; the insert guard rejects a legacy row for a
-- v2 hold.  Existing legacy rows remain readable without an invented backfill.
ALTER TABLE editorial.legal_hold_releases
  ADD COLUMN release_contract_version smallint NOT NULL DEFAULT 1,
  ADD COLUMN placement_receipt_id uuid,
  ADD COLUMN placement_receipt_digest char(64),
  ADD COLUMN released_scope_atoms_digest char(64),
  ADD COLUMN request_digest char(64),
  ADD COLUMN actor_assertion_request_digest char(64),
  ADD COLUMN conflict_receipt_digest char(64),
  ADD COLUMN audit_receipt_digest char(64),
  ADD COLUMN outbox_event_id uuid,
  ADD COLUMN release_payload jsonb,
  ADD COLUMN release_canonical bytea,
  ADD COLUMN receipt_payload jsonb,
  ADD COLUMN receipt_canonical bytea,
  ADD COLUMN retention_schedule_id uuid,
  ADD COLUMN retention_record_class text,
  ADD COLUMN retention_schedule_digest char(64),
  ADD CONSTRAINT legal_hold_releases_contract_version_ck CHECK (
    release_contract_version IN (1,2)
  ),
  ADD CONSTRAINT legal_hold_releases_v2_placement_fk FOREIGN KEY(
    placement_receipt_id,placement_receipt_digest
  ) REFERENCES ops.legal_hold_placement_receipts_v2(
    receipt_id,receipt_digest
  ) MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT legal_hold_releases_v2_outbox_fk FOREIGN KEY(outbox_event_id)
    REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  ADD CONSTRAINT legal_hold_releases_v2_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(
    id,record_class,schedule_digest
  ) MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT legal_hold_releases_v2_retention_class_fk FOREIGN KEY(
    retention_record_class
  ) REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  ADD CONSTRAINT legal_hold_releases_v2_extension_ck CHECK (
    (release_contract_version=1
      AND placement_receipt_id IS NULL
      AND placement_receipt_digest IS NULL
      AND released_scope_atoms_digest IS NULL
      AND request_digest IS NULL
      AND actor_assertion_request_digest IS NULL
      AND conflict_receipt_digest IS NULL
      AND audit_receipt_digest IS NULL
      AND outbox_event_id IS NULL
      AND release_payload IS NULL
      AND release_canonical IS NULL
      AND receipt_payload IS NULL
      AND receipt_canonical IS NULL
      AND retention_schedule_id IS NULL
      AND retention_record_class IS NULL
      AND retention_schedule_digest IS NULL)
    OR
    (release_contract_version=2
      AND placement_receipt_id IS NOT NULL
      AND placement_receipt_digest IS NOT NULL
      AND released_scope_atoms_digest IS NOT NULL
      AND request_digest IS NOT NULL
      AND actor_assertion_request_digest IS NOT NULL
      AND conflict_receipt_digest IS NOT NULL
      AND audit_receipt_digest IS NOT NULL
      AND outbox_event_id IS NOT NULL
      AND release_payload IS NOT NULL
      AND release_canonical IS NOT NULL
      AND receipt_payload IS NOT NULL
      AND receipt_canonical IS NOT NULL
      AND retention_schedule_id IS NOT NULL
      AND retention_record_class='LEGAL_HOLD_GOVERNANCE'
      AND retention_schedule_digest IS NOT NULL
      AND ops.r6d_lower_sha256(placement_receipt_digest)
      AND ops.r6d_lower_sha256(released_scope_atoms_digest)
      AND ops.r6d_lower_sha256(request_digest)
      AND ops.r6d_lower_sha256(actor_assertion_request_digest)
      AND ops.r6d_lower_sha256(conflict_receipt_digest)
      AND ops.r6d_lower_sha256(audit_receipt_digest)
      AND release_canonical=ops.canonical_jsonb_v1(release_payload)
      AND release_digest=encode(extensions.digest(
        release_canonical,'sha256'
      ),'hex')
      AND receipt_canonical=ops.canonical_jsonb_v1(receipt_payload)
      AND receipt_digest=encode(extensions.digest(
        receipt_canonical,'sha256'
      ),'hex'))
  );

CREATE OR REPLACE FUNCTION ops.bind_legal_hold_release_schedule_v2()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $$
DECLARE
  v_schedule ops.record_class_schedules%ROWTYPE;
  v_count bigint;
  v_at timestamptz:=clock_timestamp();
BEGIN
  IF NEW.release_contract_version<>2 THEN
    RETURN NEW;
  END IF;
  IF NEW.retention_schedule_id IS NOT NULL
     OR NEW.retention_record_class IS NOT NULL
     OR NEW.retention_schedule_digest IS NOT NULL THEN
    RAISE EXCEPTION 'r6d_retention_schedule_caller_override'
      USING ERRCODE='55000';
  END IF;
  LOCK TABLE ops.record_class_schedules IN SHARE MODE;
  SELECT count(*) INTO v_count
  FROM ops.record_class_schedules AS schedule
  JOIN ops.r6d_record_class_catalog AS catalog
    ON catalog.record_class=schedule.record_class
  WHERE schedule.record_class='LEGAL_HOLD_GOVERNANCE'
    AND schedule.effective_at<=v_at
    AND schedule.review_expires_at>v_at
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
      OR schedule.lawful_basis=catalog.required_lawful_basis);
  IF v_count=0 THEN
    RAISE EXCEPTION 'r6d_retention_schedule_missing:LEGAL_HOLD_GOVERNANCE'
      USING ERRCODE='55000';
  ELSIF v_count<>1 THEN
    RAISE EXCEPTION 'r6d_retention_schedule_ambiguous:LEGAL_HOLD_GOVERNANCE'
      USING ERRCODE='55000';
  END IF;
  SELECT schedule.* INTO STRICT v_schedule
  FROM ops.record_class_schedules AS schedule
  JOIN ops.r6d_record_class_catalog AS catalog
    ON catalog.record_class=schedule.record_class
  WHERE schedule.record_class='LEGAL_HOLD_GOVERNANCE'
    AND schedule.effective_at<=v_at
    AND schedule.review_expires_at>v_at
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
      OR schedule.lawful_basis=catalog.required_lawful_basis);
  NEW.retention_schedule_id:=v_schedule.id;
  NEW.retention_record_class:=v_schedule.record_class;
  NEW.retention_schedule_digest:=v_schedule.schedule_digest;
  RETURN NEW;
END
$$;
ALTER FUNCTION ops.bind_legal_hold_release_schedule_v2()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.bind_legal_hold_release_schedule_v2() FROM PUBLIC;
CREATE TRIGGER legal_hold_release_v2_retention_bind
  BEFORE INSERT ON editorial.legal_hold_releases
  FOR EACH ROW EXECUTE FUNCTION ops.bind_legal_hold_release_schedule_v2();

CREATE OR REPLACE FUNCTION ops.r6d_legal_hold_coverage_digest_v2(
  p_hold_id uuid,
  p_placement_receipt_digest char(64),
  p_release_sequence bigint,
  p_active_cells jsonb
) RETURNS char(64)
LANGUAGE sql IMMUTABLE STRICT
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
  SELECT encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'schemaVersion','legal-hold-coverage.v2',
      'holdId',p_hold_id,
      'placementReceiptDigest',btrim(p_placement_receipt_digest),
      'releaseSequence',p_release_sequence,
      'activeCells',p_active_cells
    )
  ),'sha256'),'hex')::char(64)
$$;
ALTER FUNCTION ops.r6d_legal_hold_coverage_digest_v2(
  uuid,char(64),bigint,jsonb
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_legal_hold_coverage_digest_v2(
  uuid,char(64),bigint,jsonb
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.guard_legal_hold_release_v2_insert()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $$
DECLARE
  v_placement ops.legal_hold_placement_receipts_v2%ROWTYPE;
  v_expected_release jsonb;
  v_expected_receipt jsonb;
  v_state_before jsonb;
  v_expected_cells jsonb;
  v_expected_coverage char(64);
  v_removed_count bigint;
  v_expected_removed bigint;
BEGIN
  SELECT * INTO v_placement
  FROM ops.legal_hold_placement_receipts_v2 AS placement
  WHERE placement.legal_hold_id=NEW.hold_id
  FOR SHARE;

  IF FOUND AND NEW.release_contract_version<>2 THEN
    RAISE EXCEPTION 'legal_hold_v2_release_owner_required'
      USING ERRCODE='55000';
  END IF;
  IF NOT FOUND AND NEW.release_contract_version=2 THEN
    RAISE EXCEPTION 'legal_hold_v2_placement_missing'
      USING ERRCODE='55000';
  END IF;
  IF NEW.release_contract_version=1 THEN
    RETURN NEW;
  END IF;

  IF NEW.placement_receipt_id<>v_placement.receipt_id
     OR NEW.placement_receipt_digest<>v_placement.receipt_digest
     OR NEW.target_anchor_id<>v_placement.anchor_id
     OR NEW.target_anchor_digest<>v_placement.anchor_digest
     OR NEW.hold_version<>1
     OR NEW.original_hold_digest<>v_placement.receipt_digest
     OR NEW.released_scope_atoms_digest<>encode(extensions.digest(
       ops.canonical_jsonb_v1(to_jsonb(NEW.released_scope_atoms)),
       'sha256'
     ),'hex')
     OR NEW.affected_set_digest<>encode(extensions.digest(
       ops.canonical_jsonb_v1(to_jsonb(NEW.affected_ids)),
       'sha256'
     ),'hex')
     OR NEW.authority_reference_digest<>encode(extensions.digest(
       convert_to(NEW.release_authority_reference,'UTF8'),'sha256'
     ),'hex')
     OR NEW.conflict_receipt_digest IS NULL
     OR NEW.audit_receipt_digest IS NULL THEN
    RAISE EXCEPTION 'legal_hold_v2_release_binding_invalid'
      USING ERRCODE='23514';
  END IF;

  v_state_before:=ops.r6d_legal_hold_release_state_v2(
    NEW.hold_id,NEW.released_at
  );
  IF NEW.release_sequence<>
       (v_state_before->>'currentReleaseSequence')::bigint+1
     OR NEW.prior_coverage_digest<>
       (v_state_before->>'coverageDigest')::char(64)
     OR NEW.prior_release_id IS DISTINCT FROM
       NULLIF(v_state_before->>'currentReleaseId','')::uuid
     OR NEW.prior_release_digest IS DISTINCT FROM
       NULLIF(v_state_before->>'currentReleaseDigest','')::char(64) THEN
    RAISE EXCEPTION 'legal_hold_v2_release_prior_chain_invalid'
      USING ERRCODE='23514';
  END IF;
  SELECT COALESCE(jsonb_agg(cell ORDER BY
    cell->>'scopeAtom',(cell->>'affectedId')::uuid
  ),'[]'::jsonb)
  INTO v_expected_cells
  FROM jsonb_array_elements(v_state_before->'activeCells') AS active(cell)
  WHERE NOT (
    cell->>'scopeAtom'=ANY(NEW.released_scope_atoms)
    AND (cell->>'affectedId')::uuid=ANY(NEW.affected_ids)
  );
  v_removed_count:=jsonb_array_length(v_state_before->'activeCells')-
    jsonb_array_length(v_expected_cells);
  v_expected_removed:=cardinality(NEW.released_scope_atoms)::bigint*
    cardinality(NEW.affected_ids)::bigint;
  v_expected_coverage:=ops.r6d_legal_hold_coverage_digest_v2(
    NEW.hold_id,NEW.placement_receipt_digest,NEW.release_sequence,
    v_expected_cells
  );
  IF v_removed_count<>v_expected_removed
     OR NEW.resulting_coverage_digest<>v_expected_coverage
     OR NEW.release_payload->'resultingActiveCells'<>v_expected_cells THEN
    RAISE EXCEPTION 'legal_hold_v2_release_coverage_invalid'
      USING ERRCODE='23514';
  END IF;

  v_expected_release:=jsonb_build_object(
    'schemaVersion','legal-hold-release-transition.v2',
    'releaseId',NEW.id,
    'holdId',NEW.hold_id,
    'placementReceiptId',NEW.placement_receipt_id,
    'placementReceiptDigest',btrim(NEW.placement_receipt_digest),
    'targetAnchorId',NEW.target_anchor_id,
    'targetAnchorDigest',btrim(NEW.target_anchor_digest),
    'releaseSequence',NEW.release_sequence,
    'priorReleaseId',NEW.prior_release_id,
    'priorReleaseDigest',CASE WHEN NEW.prior_release_digest IS NULL
      THEN NULL ELSE btrim(NEW.prior_release_digest) END,
    'releasedScopeAtoms',to_jsonb(NEW.released_scope_atoms),
    'releasedScopeAtomsDigest',btrim(NEW.released_scope_atoms_digest),
    'affectedIds',to_jsonb(NEW.affected_ids),
    'affectedSetDigest',btrim(NEW.affected_set_digest),
    'priorCoverageDigest',btrim(NEW.prior_coverage_digest),
    'resultingCoverageDigest',btrim(NEW.resulting_coverage_digest),
    'resultingActiveCells',NEW.release_payload->'resultingActiveCells',
    'authorityReferenceDigest',btrim(NEW.authority_reference_digest),
    'reasonCode',NEW.reason_code,
    'reasonDigest',encode(extensions.digest(
      convert_to(NEW.reason,'UTF8'),'sha256'
    ),'hex'),
    'releasedByActorId',NEW.released_by_user_id,
    'releasedAt',NEW.released_at
  );
  v_expected_receipt:=jsonb_build_object(
    'schemaVersion','legal-hold-release-receipt.v2',
    'release',v_expected_release,
    'requestId',NEW.request_id,
    'requestDigest',btrim(NEW.request_digest),
    'idempotencyKeySha256',btrim(NEW.idempotency_key_sha256),
    'auditEventId',NEW.audit_event_id,
    'auditReceiptDigest',btrim(NEW.audit_receipt_digest),
    'outboxEventId',NEW.outbox_event_id,
    'proof',jsonb_build_object(
      'actorAssertionJti',NEW.actor_assertion_jti,
      'actorAssertionRequestDigest',
        btrim(NEW.actor_assertion_request_digest),
      'stepUpAuthorizationId',NEW.step_up_authorization_id,
      'stepUpAuthorizationReceiptDigest',
        btrim(NEW.step_up_authorization_receipt_digest),
      'stepUpIssuedAt',NEW.step_up_issued_at,
      'stepUpExpiresAt',NEW.step_up_expires_at,
      'actionDigest',btrim(NEW.action_digest),
      'conflictSnapshotId',NEW.conflict_snapshot_id,
      'conflictSnapshotDigest',btrim(NEW.conflict_snapshot_digest),
      'conflictReceiptDigest',btrim(NEW.conflict_receipt_digest),
      'conflictValidUntil',NEW.conflict_valid_until,
      'releaseApprovalReceiptDigest',btrim(NEW.approval_receipt_digest)
    )
  );
  IF NEW.release_payload<>v_expected_release
     OR NEW.release_canonical<>ops.canonical_jsonb_v1(v_expected_release)
     OR NEW.release_digest<>encode(extensions.digest(
       NEW.release_canonical,'sha256'
     ),'hex')
     OR NEW.receipt_payload<>v_expected_receipt
     OR NEW.receipt_canonical<>ops.canonical_jsonb_v1(v_expected_receipt)
     OR NEW.receipt_digest<>encode(extensions.digest(
       NEW.receipt_canonical,'sha256'
     ),'hex') THEN
    RAISE EXCEPTION 'legal_hold_v2_release_receipt_invalid'
      USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION ops.guard_legal_hold_release_v2_insert()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.guard_legal_hold_release_v2_insert() FROM PUBLIC;
DROP TRIGGER IF EXISTS legal_hold_releases_v2_legacy_block
  ON editorial.legal_hold_releases;
CREATE TRIGGER legal_hold_release_v2_guard
  BEFORE INSERT ON editorial.legal_hold_releases
  FOR EACH ROW EXECUTE FUNCTION ops.guard_legal_hold_release_v2_insert();

-- Reconstruct and verify the complete placement-minus-release cell chain.
-- Consumers must use this helper instead of the legacy scalar hold.scope and
-- JSON affected_ids columns.
CREATE OR REPLACE FUNCTION ops.r6d_legal_hold_release_state_v2(
  p_hold_id uuid,
  p_at_time timestamptz
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $$
DECLARE
  v_placement ops.legal_hold_placement_receipts_v2%ROWTYPE;
  v_release editorial.legal_hold_releases%ROWTYPE;
  v_active_cells jsonb;
  v_next_cells jsonb;
  v_coverage_digest char(64);
  v_expected_digest char(64);
  v_current_sequence bigint:=0;
  v_current_release_id uuid;
  v_current_release_digest char(64);
  v_removed_count bigint;
  v_expected_removed bigint;
  v_state text;
BEGIN
  IF p_hold_id IS NULL OR p_at_time IS NULL THEN
    RAISE EXCEPTION 'legal_hold_v2_resolution_input_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO STRICT v_placement
  FROM ops.legal_hold_placement_receipts_v2 AS placement
  WHERE placement.legal_hold_id=p_hold_id
    AND placement.placed_at<=p_at_time;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'scopeAtom',scope_atom,'affectedId',affected_id
  ) ORDER BY scope_atom,affected_id),'[]'::jsonb)
  INTO v_active_cells
  FROM unnest(v_placement.scope_atoms) AS scope(scope_atom)
  CROSS JOIN unnest(v_placement.affected_ids) AS affected(affected_id);
  v_coverage_digest:=ops.r6d_legal_hold_coverage_digest_v2(
    p_hold_id,v_placement.receipt_digest,0,v_active_cells
  );

  FOR v_release IN
    SELECT release.*
    FROM editorial.legal_hold_releases AS release
    WHERE release.hold_id=p_hold_id AND release.released_at<=p_at_time
    ORDER BY release.release_sequence,release.id
  LOOP
    IF v_release.release_contract_version<>2
       OR v_release.placement_receipt_id<>v_placement.receipt_id
       OR v_release.placement_receipt_digest<>v_placement.receipt_digest
       OR v_release.release_sequence<>v_current_sequence+1
       OR v_release.prior_coverage_digest<>v_coverage_digest
       OR (v_current_sequence=0 AND (
         v_release.prior_release_id IS NOT NULL
         OR v_release.prior_release_digest IS NOT NULL))
       OR (v_current_sequence>0 AND (
         v_release.prior_release_id IS DISTINCT FROM v_current_release_id
         OR v_release.prior_release_digest IS DISTINCT FROM
           v_current_release_digest)) THEN
      RAISE EXCEPTION 'legal_hold_v2_release_chain_invalid'
        USING ERRCODE='55000';
    END IF;

    SELECT COALESCE(jsonb_agg(cell ORDER BY
      cell->>'scopeAtom',(cell->>'affectedId')::uuid
    ),'[]'::jsonb)
    INTO v_next_cells
    FROM jsonb_array_elements(v_active_cells) AS active(cell)
    WHERE NOT (
      cell->>'scopeAtom'=ANY(v_release.released_scope_atoms)
      AND (cell->>'affectedId')::uuid=ANY(v_release.affected_ids)
    );
    v_removed_count:=jsonb_array_length(v_active_cells)-
      jsonb_array_length(v_next_cells);
    v_expected_removed:=cardinality(v_release.released_scope_atoms)::bigint*
      cardinality(v_release.affected_ids)::bigint;
    IF v_removed_count<>v_expected_removed THEN
      RAISE EXCEPTION 'legal_hold_v2_release_cell_repeated_or_outside'
        USING ERRCODE='55000';
    END IF;
    v_expected_digest:=ops.r6d_legal_hold_coverage_digest_v2(
      p_hold_id,v_placement.receipt_digest,v_release.release_sequence,
      v_next_cells
    );
    IF v_release.resulting_coverage_digest<>v_expected_digest THEN
      RAISE EXCEPTION 'legal_hold_v2_release_coverage_digest_invalid'
        USING ERRCODE='55000';
    END IF;
    IF v_release.release_payload->'resultingActiveCells'<>v_next_cells THEN
      RAISE EXCEPTION 'legal_hold_v2_release_active_cells_invalid'
        USING ERRCODE='55000';
    END IF;
    v_active_cells:=v_next_cells;
    v_coverage_digest:=v_expected_digest;
    v_current_sequence:=v_release.release_sequence;
    v_current_release_id:=v_release.id;
    v_current_release_digest:=v_release.release_digest;
  END LOOP;

  v_state:=CASE WHEN jsonb_array_length(v_active_cells)=0
    THEN 'FULLY_RELEASED'
    WHEN v_current_sequence=0 THEN 'ACTIVE'
    ELSE 'PARTIALLY_RELEASED' END;
  RETURN jsonb_build_object(
    'schemaVersion','r6d-legal-hold-release-state.v2',
    'holdId',p_hold_id,
    'placementReceiptId',v_placement.receipt_id,
    'placementReceiptDigest',btrim(v_placement.receipt_digest),
    'targetAnchorId',v_placement.anchor_id,
    'targetAnchorDigest',btrim(v_placement.anchor_digest),
    'currentReleaseSequence',v_current_sequence,
    'currentReleaseId',v_current_release_id,
    'currentReleaseDigest',CASE WHEN v_current_release_digest IS NULL
      THEN NULL ELSE btrim(v_current_release_digest) END,
    'coverageDigest',btrim(v_coverage_digest),
    'activeCells',v_active_cells,
    'state',v_state
  );
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'legal_hold_v2_placement_missing_or_ambiguous'
    USING ERRCODE='55000';
END
$$;
ALTER FUNCTION ops.r6d_legal_hold_release_state_v2(uuid,timestamptz)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_legal_hold_release_state_v2(uuid,timestamptz)
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.release_legal_hold_v2(
  p_payload jsonb,
  p_actor_id uuid,
  p_request_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $$
DECLARE
  v_hold editorial.legal_holds%ROWTYPE;
  v_placement ops.legal_hold_placement_receipts_v2%ROWTYPE;
  v_anchor ops.legal_hold_target_anchors%ROWTYPE;
  v_existing editorial.legal_hold_releases%ROWTYPE;
  v_previous editorial.legal_hold_releases%ROWTYPE;
  v_assertion ops.assertion_replay_guard%ROWTYPE;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_session ops.sessions%ROWTYPE;
  v_actor ops.users%ROWTYPE;
  v_conflict editorial.conflict_snapshots%ROWTYPE;
  v_conflict_ids uuid[];
  v_state_before jsonb;
  v_active_cells jsonb;
  v_remaining_cells jsonb;
  v_release_id uuid:=gen_random_uuid();
  v_hold_id uuid;
  v_target_anchor_id uuid;
  v_expected_sequence bigint;
  v_release_sequence bigint;
  v_scope_atoms text[];
  v_scope_atoms_digest char(64);
  v_affected_ids uuid[];
  v_affected_set_digest char(64);
  v_authority text;
  v_authority_digest char(64);
  v_reason_code text;
  v_reason text;
  v_reason_digest char(64);
  v_actor_assertion_jti uuid;
  v_actor_assertion_request_digest char(64);
  v_action_digest char(64);
  v_step_up_id uuid;
  v_step_up_receipt jsonb;
  v_step_up_digest char(64);
  v_prior_coverage_digest char(64);
  v_resulting_coverage_digest char(64);
  v_prior_release_id uuid;
  v_prior_release_digest char(64);
  v_removed_count bigint;
  v_expected_removed bigint;
  v_approval_payload jsonb;
  v_approval_digest char(64);
  v_release_payload jsonb;
  v_release_canonical bytea;
  v_release_digest char(64);
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
  v_now timestamptz:=clock_timestamp();
  v_audit uuid;
  v_audit_digest char(64);
  v_outbox uuid;
  v_response jsonb;
  v_updated bigint;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR NOT p_payload ?& ARRAY[
       'holdId','targetAnchorId','expectedReleaseSequence',
       'releaseScopeAtoms','affectedIds','releaseAuthorityReference',
       'reasonCode','reason','_actorAssertionJti','_actorAssuranceLevel',
       '_actorEffectiveCapability','_actorAssertionRequestSha256',
       '_actorActionDigest',
       '_actorStepUpAuthorizationId',
       '_actorIdempotencyKeySha256','_actorRequestKeySha256','_requestId',
       '_requestSha256','_idempotencyKeySha256'
     ]
     OR p_payload-ARRAY[
       'holdId','targetAnchorId','expectedReleaseSequence',
       'releaseScopeAtoms','affectedIds','releaseAuthorityReference',
       'reasonCode','reason','_actorAssertionJti','_actorAssuranceLevel',
       '_actorEffectiveCapability','_actorAssertionRequestSha256',
       '_actorActionDigest',
       '_actorStepUpAuthorizationId',
       '_actorIdempotencyKeySha256','_actorRequestKeySha256','_requestId',
       '_requestSha256','_idempotencyKeySha256'
     ]<>'{}'::jsonb
     OR jsonb_typeof(p_payload->'holdId')<>'string'
     OR jsonb_typeof(p_payload->'targetAnchorId')<>'string'
     OR jsonb_typeof(p_payload->'expectedReleaseSequence')<>'number'
     OR jsonb_typeof(p_payload->'releaseScopeAtoms')<>'array'
     OR jsonb_typeof(p_payload->'affectedIds')<>'array'
     OR jsonb_typeof(p_payload->'releaseAuthorityReference')<>'string'
     OR jsonb_typeof(p_payload->'reasonCode')<>'string'
     OR jsonb_typeof(p_payload->'reason')<>'string'
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
    RAISE EXCEPTION 'legal_hold_release_v2_input_invalid'
      USING ERRCODE='22023';
  END IF;

  v_hold_id:=(p_payload->>'holdId')::uuid;
  v_target_anchor_id:=(p_payload->>'targetAnchorId')::uuid;
  v_expected_sequence:=(p_payload->>'expectedReleaseSequence')::bigint;
  v_actor_assertion_jti:=(p_payload->>'_actorAssertionJti')::uuid;
  v_actor_assertion_request_digest:=
    (p_payload->>'_actorAssertionRequestSha256')::char(64);
  v_action_digest:=(p_payload->>'_actorActionDigest')::char(64);
  v_step_up_id:=(p_payload->>'_actorStepUpAuthorizationId')::uuid;
  IF v_expected_sequence<0
     OR p_payload->>'_actorAssuranceLevel'<>'STEP_UP'
     OR p_payload->>'_actorEffectiveCapability'<>'review.legal'
     OR NOT ops.r6d_lower_sha256(v_actor_assertion_request_digest)
     OR NOT ops.r6d_lower_sha256(v_action_digest)
     OR NOT ops.r6d_lower_sha256(
       p_payload->>'_actorIdempotencyKeySha256'
     )
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorRequestKeySha256')
     OR NOT ops.r6d_lower_sha256(p_payload->>'_requestSha256')
     OR NOT ops.r6d_lower_sha256(p_payload->>'_idempotencyKeySha256')
     OR (p_payload->>'_requestId')::uuid<>p_request_id
     OR p_payload->>'_requestSha256'<>btrim(p_request_digest)
     OR p_payload->>'_idempotencyKeySha256'<>btrim(p_idempotency_key)
     OR p_payload->>'_actorIdempotencyKeySha256'<>btrim(p_idempotency_key)
     OR p_payload->>'_actorRequestKeySha256'<>btrim(p_idempotency_key) THEN
    RAISE EXCEPTION 'legal_hold_release_v2_actor_binding_invalid'
      USING ERRCODE='42501';
  END IF;

  SELECT array_agg(value ORDER BY value),count(*),count(DISTINCT value)
  INTO v_scope_atoms,v_removed_count,v_expected_removed
  FROM jsonb_array_elements_text(p_payload->'releaseScopeAtoms') AS atom(value);
  IF v_removed_count NOT BETWEEN 1 AND 3
     OR v_removed_count<>v_expected_removed
     OR NOT v_scope_atoms<@ARRAY[
       'DELETION','DISCLOSURE','RETENTION'
     ]::text[] THEN
    RAISE EXCEPTION 'legal_hold_release_v2_scope_invalid'
      USING ERRCODE='22023';
  END IF;
  v_scope_atoms_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(to_jsonb(v_scope_atoms)),'sha256'
  ),'hex');
  SELECT array_agg(value ORDER BY value),count(*),count(DISTINCT value)
  INTO v_affected_ids,v_removed_count,v_expected_removed
  FROM (
    SELECT (item#>>'{}')::uuid AS value
    FROM jsonb_array_elements(p_payload->'affectedIds') AS element(item)
  ) AS identifiers;
  IF v_removed_count NOT BETWEEN 1 AND 10000
     OR v_removed_count<>v_expected_removed THEN
    RAISE EXCEPTION 'legal_hold_release_v2_affected_set_invalid'
      USING ERRCODE='22023';
  END IF;
  v_affected_set_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(to_jsonb(v_affected_ids)),'sha256'
  ),'hex');
  v_authority:=p_payload->>'releaseAuthorityReference';
  v_reason_code:=p_payload->>'reasonCode';
  v_reason:=p_payload->>'reason';
  IF length(v_authority) NOT BETWEEN 1 AND 500
     OR length(v_reason) NOT BETWEEN 1 AND 4000
     OR v_reason_code NOT IN (
       'AUTHORITY_WITHDRAWN','EXPIRED_REVIEWED','RESOLVED','SUPERSEDED',
       'COURT_ORDER','OTHER'
     )
     OR btrim(v_authority)<>v_authority OR btrim(v_reason)<>v_reason THEN
    RAISE EXCEPTION 'legal_hold_release_v2_input_invalid'
      USING ERRCODE='22023';
  END IF;
  v_authority_digest:=encode(extensions.digest(
    convert_to(v_authority,'UTF8'),'sha256'
  ),'hex');
  v_reason_digest:=encode(extensions.digest(
    convert_to(v_reason,'UTF8'),'sha256'
  ),'hex');

  SELECT * INTO v_existing
  FROM editorial.legal_hold_releases AS release
  WHERE release.idempotency_key_sha256=p_idempotency_key
  FOR SHARE;
  IF FOUND THEN
    IF v_existing.release_contract_version<>2
       OR v_existing.request_digest<>p_request_digest
       OR v_existing.released_by_user_id<>p_actor_id
       OR v_existing.step_up_authorization_id<>v_step_up_id
       OR v_existing.action_digest<>v_action_digest
       OR v_existing.hold_id<>v_hold_id
       OR v_existing.target_anchor_id<>v_target_anchor_id
       OR v_existing.release_sequence<>v_expected_sequence+1
       OR v_existing.released_scope_atoms<>v_scope_atoms
       OR v_existing.affected_ids<>v_affected_ids
       OR v_existing.authority_reference_digest<>v_authority_digest
       OR v_existing.reason_code<>v_reason_code
       OR encode(extensions.digest(
         convert_to(v_existing.reason,'UTF8'),'sha256'
       ),'hex')<>v_reason_digest THEN
      RAISE EXCEPTION 'legal_hold_release_v2_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    SELECT * INTO v_assertion FROM ops.assertion_replay_guard
    WHERE assertion_type='ACTOR' AND jti=v_actor_assertion_jti;
    IF NOT FOUND OR v_assertion.issuer<>'identity-api'
       OR v_assertion.audience<>'control-api'
       OR v_assertion.request_digest<>v_actor_assertion_request_digest
       OR v_assertion.expires_at<=v_now THEN
      RAISE EXCEPTION 'legal_hold_release_v2_actor_assertion_invalid'
        USING ERRCODE='42501';
    END IF;
    v_state_before:=jsonb_build_object(
      'schemaVersion','r6d-legal-hold-release-state.v2',
      'holdId',v_existing.hold_id,
      'placementReceiptId',v_existing.placement_receipt_id,
      'placementReceiptDigest',btrim(v_existing.placement_receipt_digest),
      'targetAnchorId',v_existing.target_anchor_id,
      'targetAnchorDigest',btrim(v_existing.target_anchor_digest),
      'currentReleaseSequence',v_existing.release_sequence,
      'currentReleaseId',v_existing.id,
      'currentReleaseDigest',btrim(v_existing.release_digest),
      'coverageDigest',btrim(v_existing.resulting_coverage_digest),
      'activeCells',v_existing.release_payload->'resultingActiveCells',
      'state',CASE WHEN jsonb_array_length(
        v_existing.release_payload->'resultingActiveCells'
      )=0 THEN 'FULLY_RELEASED' ELSE 'PARTIALLY_RELEASED' END
    );
    RETURN jsonb_build_object(
      'release',jsonb_build_object(
        'id',v_existing.id,'holdId',v_existing.hold_id,
        'targetAnchorId',v_existing.target_anchor_id,
        'releaseSequence',v_existing.release_sequence,
        'receiptDigest',btrim(v_existing.receipt_digest),
        'auditEventId',v_existing.audit_event_id,
        'outboxEventIds',jsonb_build_array(v_existing.outbox_event_id),
        'releasedScopeAtoms',to_jsonb(v_existing.released_scope_atoms),
        'affectedIds',to_jsonb(v_existing.affected_ids),
        'coverage',v_state_before,
        'priorCoverageDigest',btrim(v_existing.prior_coverage_digest),
        'resultingCoverageDigest',
          btrim(v_existing.resulting_coverage_digest),
        'authorityReferenceDigest',
          btrim(v_existing.authority_reference_digest)
      ),
      'receiptDigest',btrim(v_existing.receipt_digest),
      'auditEventId',v_existing.audit_event_id,
      'replayed',true
    );
  END IF;

  SELECT * INTO v_assertion FROM ops.assertion_replay_guard
  WHERE assertion_type='ACTOR' AND jti=v_actor_assertion_jti;
  IF NOT FOUND OR v_assertion.issuer<>'identity-api'
     OR v_assertion.audience<>'control-api'
     OR v_assertion.request_digest<>v_actor_assertion_request_digest
     OR v_assertion.expires_at<=v_now THEN
    RAISE EXCEPTION 'legal_hold_release_v2_actor_assertion_invalid'
      USING ERRCODE='42501';
  END IF;

  SELECT * INTO v_step_up FROM ops.step_up_authorizations
  WHERE id=v_step_up_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'legal_hold_release_v2_step_up_invalid'
      USING ERRCODE='42501';
  END IF;
  SELECT * INTO v_session FROM ops.sessions WHERE id=v_step_up.session_id
    FOR SHARE;
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
    RAISE EXCEPTION 'legal_hold_release_v2_step_up_invalid'
      USING ERRCODE='42501';
  END IF;
  v_step_up_receipt:=jsonb_build_object(
    'schemaVersion','step-up-authorization-receipt.v1',
    'authorizationId',v_step_up.id,
    'actionDigest',btrim(v_step_up.action_digest),
    'sessionId',v_step_up.session_id,
    'issueNumber',v_step_up.assertion_issue_count,
    'issuedAt',v_step_up.last_issued_at,
    'expiresAt',v_step_up.expires_at
  );
  v_step_up_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_step_up_receipt),'sha256'
  ),'hex');

  SELECT * INTO STRICT v_hold FROM editorial.legal_holds
  WHERE id=v_hold_id FOR SHARE;
  SELECT * INTO STRICT v_placement
  FROM ops.legal_hold_placement_receipts_v2
  WHERE legal_hold_id=v_hold.id FOR SHARE;
  SELECT * INTO STRICT v_anchor FROM ops.legal_hold_target_anchors
  WHERE id=v_target_anchor_id AND id=v_placement.anchor_id
    AND anchor_digest=v_placement.anchor_digest FOR SHARE;
  PERFORM release.id FROM editorial.legal_hold_releases AS release
  WHERE release.hold_id=v_hold.id ORDER BY release.release_sequence,release.id
  FOR SHARE;
  IF v_hold.placed_by=p_actor_id THEN
    RAISE EXCEPTION 'legal_hold_release_v2_independence_required'
      USING ERRCODE='42501';
  END IF;

  v_state_before:=ops.r6d_legal_hold_release_state_v2(v_hold.id,v_now);
  IF v_state_before->>'state'='FULLY_RELEASED' THEN
    RAISE EXCEPTION 'legal_hold_release_v2_already_released'
      USING ERRCODE='40001';
  END IF;
  IF (v_state_before->>'currentReleaseSequence')::bigint<>
       v_expected_sequence THEN
    RAISE EXCEPTION 'legal_hold_release_v2_stale'
      USING ERRCODE='40001';
  END IF;
  v_release_sequence:=v_expected_sequence+1;
  v_prior_coverage_digest:=
    (v_state_before->>'coverageDigest')::char(64);
  v_prior_release_id:=NULLIF(v_state_before->>'currentReleaseId','')::uuid;
  v_prior_release_digest:=
    NULLIF(v_state_before->>'currentReleaseDigest','')::char(64);
  v_active_cells:=v_state_before->'activeCells';

  SELECT COALESCE(jsonb_agg(cell ORDER BY
    cell->>'scopeAtom',(cell->>'affectedId')::uuid
  ),'[]'::jsonb)
  INTO v_remaining_cells
  FROM jsonb_array_elements(v_active_cells) AS active(cell)
  WHERE NOT (
    cell->>'scopeAtom'=ANY(v_scope_atoms)
    AND (cell->>'affectedId')::uuid=ANY(v_affected_ids)
  );
  v_removed_count:=jsonb_array_length(v_active_cells)-
    jsonb_array_length(v_remaining_cells);
  v_expected_removed:=cardinality(v_scope_atoms)::bigint*
    cardinality(v_affected_ids)::bigint;
  IF v_removed_count<>v_expected_removed THEN
    RAISE EXCEPTION 'legal_hold_release_v2_cell_repeated_or_outside'
      USING ERRCODE='22023';
  END IF;
  v_resulting_coverage_digest:=ops.r6d_legal_hold_coverage_digest_v2(
    v_hold.id,v_placement.receipt_digest,v_release_sequence,
    v_remaining_cells
  );

  SELECT array_agg(conflict.id ORDER BY conflict.evaluated_at DESC,conflict.id)
  INTO v_conflict_ids
  FROM editorial.conflict_snapshots AS conflict
  WHERE conflict.subject_actor_id=p_actor_id
    AND conflict.target_type='LEGAL_HOLD'
    AND conflict.target_id=v_hold.id::text
    AND conflict.target_version=1
    AND conflict.target_digest=v_placement.receipt_digest
    AND conflict.operation_id='releaseLegalHold'
    AND conflict.candidate_role='LEGAL_REVIEWER'
    AND conflict.evaluation_state='CLEAR'
    AND conflict.valid_until>v_now;
  IF cardinality(v_conflict_ids)<>1 THEN
    RAISE EXCEPTION 'legal_hold_release_v2_conflict_missing_or_ambiguous'
      USING ERRCODE='55000';
  END IF;
  SELECT * INTO STRICT v_conflict FROM editorial.conflict_snapshots
  WHERE id=v_conflict_ids[1] FOR SHARE;

  v_approval_payload:=jsonb_build_object(
    'schemaVersion','legal-hold-release-approval.v2',
    'holdId',v_hold.id,
    'placementReceiptDigest',btrim(v_placement.receipt_digest),
    'targetAnchorId',v_anchor.id,
    'releaseSequence',v_release_sequence,
    'priorCoverageDigest',btrim(v_prior_coverage_digest),
    'releasedScopeAtomsDigest',btrim(v_scope_atoms_digest),
    'affectedSetDigest',btrim(v_affected_set_digest),
    'resultingCoverageDigest',btrim(v_resulting_coverage_digest),
    'authorityReferenceDigest',btrim(v_authority_digest),
    'reasonCode',v_reason_code,'reasonDigest',btrim(v_reason_digest),
    'releasedByActorId',p_actor_id,
    'actorAssertionJti',v_actor_assertion_jti,
    'actorAssertionRequestDigest',btrim(v_actor_assertion_request_digest),
    'stepUpAuthorizationId',v_step_up.id,
    'stepUpAuthorizationReceiptDigest',btrim(v_step_up_digest),
    'actionDigest',btrim(v_action_digest),
    'conflictSnapshotId',v_conflict.id,
    'conflictSnapshotDigest',btrim(v_conflict.snapshot_sha256),
    'conflictReceiptDigest',btrim(v_conflict.receipt_digest),
    'requestId',p_request_id,'requestDigest',btrim(p_request_digest),
    'idempotencyKeySha256',btrim(p_idempotency_key),
    'releasedAt',v_now
  );
  v_approval_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_approval_payload),'sha256'
  ),'hex');

  v_audit:=ops.append_audit_event(
    'legal-hold:'||v_hold.id::text,'USER',p_actor_id::text,NULL::uuid,
    'command.releaseLegalHold','LegalHold',v_hold.id::text,'review.legal',
    'SUCCESS',NULL,p_request_id,jsonb_build_object(
      'placementReceiptDigest',btrim(v_placement.receipt_digest),
      'releaseSequence',v_release_sequence,
      'releasedScopeAtomsDigest',btrim(v_scope_atoms_digest),
      'affectedSetDigest',btrim(v_affected_set_digest),
      'priorCoverageDigest',btrim(v_prior_coverage_digest),
      'resultingCoverageDigest',btrim(v_resulting_coverage_digest),
      'authorityReferenceDigest',btrim(v_authority_digest),
      'reasonCode',v_reason_code,'reasonDigest',btrim(v_reason_digest),
      'actorAssertionJti',v_actor_assertion_jti,
      'actorAssertionRequestDigest',btrim(v_actor_assertion_request_digest),
      'requestDigest',btrim(p_request_digest),
      'stepUpAuthorizationReceiptDigest',btrim(v_step_up_digest),
      'conflictSnapshotDigest',btrim(v_conflict.snapshot_sha256),
      'releaseApprovalReceiptDigest',btrim(v_approval_digest)
    )
  );
  SELECT event_hash INTO STRICT v_audit_digest
  FROM ops.audit_events WHERE id=v_audit;

  v_release_payload:=jsonb_build_object(
    'schemaVersion','legal-hold-release-transition.v2',
    'releaseId',v_release_id,'holdId',v_hold.id,
    'placementReceiptId',v_placement.receipt_id,
    'placementReceiptDigest',btrim(v_placement.receipt_digest),
    'targetAnchorId',v_anchor.id,
    'targetAnchorDigest',btrim(v_anchor.anchor_digest),
    'releaseSequence',v_release_sequence,
    'priorReleaseId',v_prior_release_id,
    'priorReleaseDigest',CASE WHEN v_prior_release_digest IS NULL
      THEN NULL ELSE btrim(v_prior_release_digest) END,
    'releasedScopeAtoms',to_jsonb(v_scope_atoms),
    'releasedScopeAtomsDigest',btrim(v_scope_atoms_digest),
    'affectedIds',to_jsonb(v_affected_ids),
    'affectedSetDigest',btrim(v_affected_set_digest),
    'priorCoverageDigest',btrim(v_prior_coverage_digest),
    'resultingCoverageDigest',btrim(v_resulting_coverage_digest),
    'resultingActiveCells',v_remaining_cells,
    'authorityReferenceDigest',btrim(v_authority_digest),
    'reasonCode',v_reason_code,'reasonDigest',btrim(v_reason_digest),
    'releasedByActorId',p_actor_id,'releasedAt',v_now
  );
  v_release_canonical:=ops.canonical_jsonb_v1(v_release_payload);
  v_release_digest:=encode(extensions.digest(
    v_release_canonical,'sha256'
  ),'hex');

  v_outbox:=ops.enqueue_outbox(
    'legal_hold',v_hold.id::text,v_release_sequence,
    'legal.hold_released.v1',jsonb_build_object(
      'holdId',v_hold.id,'releaseSequence',v_release_sequence,
      'releasedScopeAtoms',to_jsonb(v_scope_atoms),
      'affectedSetDigest',btrim(v_affected_set_digest),
      'priorCoverageDigest',btrim(v_prior_coverage_digest),
      'resultingCoverageDigest',btrim(v_resulting_coverage_digest),
      'authorityReferenceDigest',btrim(v_authority_digest),
      'receiptDigest',btrim(v_release_digest)
    ),v_now
  );
  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','legal-hold-release-receipt.v2',
    'release',v_release_payload,
    'requestId',p_request_id,'requestDigest',btrim(p_request_digest),
    'idempotencyKeySha256',btrim(p_idempotency_key),
    'auditEventId',v_audit,'auditReceiptDigest',btrim(v_audit_digest),
    'outboxEventId',v_outbox,
    'proof',jsonb_build_object(
      'actorAssertionJti',v_actor_assertion_jti,
      'actorAssertionRequestDigest',btrim(v_actor_assertion_request_digest),
      'stepUpAuthorizationId',v_step_up.id,
      'stepUpAuthorizationReceiptDigest',btrim(v_step_up_digest),
      'stepUpIssuedAt',v_step_up.last_issued_at,
      'stepUpExpiresAt',v_step_up.expires_at,
      'actionDigest',btrim(v_action_digest),
      'conflictSnapshotId',v_conflict.id,
      'conflictSnapshotDigest',btrim(v_conflict.snapshot_sha256),
      'conflictReceiptDigest',btrim(v_conflict.receipt_digest),
      'conflictValidUntil',v_conflict.valid_until,
      'releaseApprovalReceiptDigest',btrim(v_approval_digest)
    )
  );
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_receipt_digest:=encode(extensions.digest(
    v_receipt_canonical,'sha256'
  ),'hex');

  -- The event is deliberately a lossy notification; update its receipt digest
  -- to the immutable receipt now that the canonical receipt exists.
  UPDATE ops.outbox SET payload=payload||jsonb_build_object(
    'receiptDigest',btrim(v_receipt_digest)
  ) WHERE id=v_outbox;

  INSERT INTO editorial.legal_hold_releases(
    id,hold_id,hold_version,original_hold_digest,target_anchor_id,
    target_anchor_digest,release_context_kind,release_sequence,
    prior_release_id,prior_release_digest,case_id,review_snapshot_id,
    expected_case_version,released_scope_atoms,affected_ids,
    affected_set_digest,prior_coverage_digest,resulting_coverage_digest,
    release_authority_reference,authority_reference_digest,reason_code,
    reason,released_by_user_id,conflict_snapshot_id,
    conflict_snapshot_digest,conflict_target_type,conflict_target_id,
    conflict_target_version,conflict_target_digest,
    conflict_evaluation_state,conflict_valid_until,approval_receipt_digest,
    step_up_authorization_id,step_up_authorization_receipt_digest,
    step_up_issued_at,step_up_expires_at,action_digest,
    idempotency_key_sha256,actor_assertion_jti,request_id,audit_event_id,
    release_digest,receipt_digest,released_at,release_contract_version,
    placement_receipt_id,placement_receipt_digest,
    released_scope_atoms_digest,request_digest,
    actor_assertion_request_digest,conflict_receipt_digest,
    audit_receipt_digest,outbox_event_id,release_payload,release_canonical,
    receipt_payload,receipt_canonical
  ) VALUES(
    v_release_id,v_hold.id,1,v_placement.receipt_digest,v_anchor.id,
    v_anchor.anchor_digest,
    CASE WHEN v_anchor.case_id IS NULL
      THEN 'NON_CASE_GOVERNED' ELSE 'CASE_GOVERNED' END,
    v_release_sequence,v_prior_release_id,v_prior_release_digest,
    v_anchor.case_id,v_anchor.case_review_snapshot_id,
    CASE WHEN v_anchor.case_id IS NULL THEN NULL
      ELSE v_placement.target_version END,
    v_scope_atoms,v_affected_ids,v_affected_set_digest,
    v_prior_coverage_digest,v_resulting_coverage_digest,
    v_authority,v_authority_digest,v_reason_code,v_reason,p_actor_id,
    v_conflict.id,v_conflict.snapshot_sha256,'LEGAL_HOLD',v_hold.id::text,
    1,v_placement.receipt_digest,'CLEAR',v_conflict.valid_until,
    v_approval_digest,v_step_up.id,v_step_up_digest,
    v_step_up.last_issued_at,v_step_up.expires_at,v_action_digest,
    p_idempotency_key,v_actor_assertion_jti,p_request_id,v_audit,
    v_release_digest,v_receipt_digest,v_now,2,v_placement.receipt_id,
    v_placement.receipt_digest,v_scope_atoms_digest,p_request_digest,
    v_actor_assertion_request_digest,v_conflict.receipt_digest,
    v_audit_digest,v_outbox,
    v_release_payload,v_release_canonical,v_receipt_payload,
    v_receipt_canonical
  );

  IF jsonb_array_length(v_remaining_cells)=0 THEN
    UPDATE editorial.legal_holds
    SET active=false,released_by=p_actor_id,released_at=v_now,
        version=version+1
    WHERE id=v_hold.id AND active AND version=v_hold.version;
    GET DIAGNOSTICS v_updated=ROW_COUNT;
    IF v_updated<>1 THEN
      RAISE EXCEPTION 'legal_hold_release_v2_state_fence_failed'
        USING ERRCODE='40001';
    END IF;
  ELSIF NOT v_hold.active OR v_hold.version<>1 THEN
    RAISE EXCEPTION 'legal_hold_release_v2_state_invalid'
      USING ERRCODE='55000';
  END IF;

  v_response:=ops.r6d_legal_hold_release_state_v2(v_hold.id,v_now);
  RETURN jsonb_build_object(
    'release',jsonb_build_object(
      'id',v_release_id,'holdId',v_hold.id,'targetAnchorId',v_anchor.id,
      'releaseSequence',v_release_sequence,
      'receiptDigest',btrim(v_receipt_digest),'auditEventId',v_audit,
      'outboxEventIds',jsonb_build_array(v_outbox),
      'releasedScopeAtoms',to_jsonb(v_scope_atoms),
      'affectedIds',to_jsonb(v_affected_ids),'coverage',v_response,
      'priorCoverageDigest',btrim(v_prior_coverage_digest),
      'resultingCoverageDigest',btrim(v_resulting_coverage_digest),
      'authorityReferenceDigest',btrim(v_authority_digest)
    ),
    'receiptDigest',btrim(v_receipt_digest),'auditEventId',v_audit,
    'replayed',false
  );
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'legal_hold_release_v2_input_invalid'
      USING ERRCODE='22023';
  WHEN no_data_found OR too_many_rows THEN
    RAISE EXCEPTION 'legal_hold_release_v2_authority_missing_or_ambiguous'
      USING ERRCODE='55000';
END
$$;
ALTER FUNCTION ops.release_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.release_legal_hold_v2(
  jsonb,uuid,uuid,char(64),char(64)
) FROM PUBLIC;

-- Preserve the four-kind compatibility owner, but make the normal operation
-- entry point dispatch every v2 placement to the v2 owner.  Direct execution
-- of the renamed legacy owner is closed to application roles.
ALTER FUNCTION ops.release_legal_hold_v1(
  jsonb,uuid,uuid,char(64),char(64)
) RENAME TO release_legal_hold_legacy_v1;
REVOKE ALL ON FUNCTION ops.release_legal_hold_legacy_v1(
  jsonb,uuid,uuid,char(64),char(64)
) FROM PUBLIC,gurine_control_api;

CREATE OR REPLACE FUNCTION ops.release_legal_hold_v1(
  p_payload jsonb,
  p_actor_id uuid,
  p_request_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,pg_temp
AS $$
DECLARE
  v_hold_id uuid;
BEGIN
  BEGIN
    v_hold_id:=NULLIF(p_payload->>'holdId','')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'legal_hold_release_input_invalid' USING ERRCODE='22023';
  END;
  IF v_hold_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM ops.legal_hold_placement_receipts_v2 AS placement
    WHERE placement.legal_hold_id=v_hold_id
  ) THEN
    RETURN ops.release_legal_hold_v2(
      p_payload,p_actor_id,p_request_id,p_idempotency_key,p_request_digest
    );
  END IF;
  RETURN ops.release_legal_hold_legacy_v1(
    p_payload,p_actor_id,p_request_id,p_idempotency_key,p_request_digest
  );
END
$$;
ALTER FUNCTION ops.release_legal_hold_v1(
  jsonb,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.release_legal_hold_v1(
  jsonb,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.release_legal_hold_v1(
  jsonb,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- Event-registry integration:
-- Replace the legal_hold.placed.v2 tuple in the 0038 registry INSERT with this
-- mechanically dereferenced schema, or place this exact upsert after that
-- INSERT and before COMMIT. The repository's deliberately small JSON-Schema
-- admission function does not resolve local $ref; changing the global
-- validator would expand every event's trust boundary. Keeping this one schema
-- inline preserves the current contract while making its oneOf branches
-- executable.
INSERT INTO ops.event_types(
  event_type,category,schema_version,active,payload_schema_uri,payload_schema
) VALUES (
  'legal_hold.placed.v2','DOMAIN',2,true,
  'payloads/legal_hold_placed_v2.schema.json',
  $r6d_hold_inline${"$id":"https://gurine.invalid/events/legal_hold.placed.v2.schema.json","type":"object","$schema":"https://json-schema.org/draft/2020-12/schema","$comment":"Runtime admission also requires each concrete object ID to equal targetId. Entity variants require targetId=entityRetentionSnapshotId and targetDigest=entityRetentionSnapshotDigest; targetAnchorDigest covers the full selected branch. Draft 2020-12 cannot express cross-property equality, so the DB owner guard enforces it before outbox insertion.","required":["legalHoldId","target","scopeAtoms","affectedSetDigest","authorityReferenceDigest","placedByActorId","placedAt","expiresAt","auditReceiptDigest","holdReceiptDigest"],"properties":{"target":{"oneOf":[{"type":"object","required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","caseId","reviewSnapshotId","reviewSnapshotDigest"],"properties":{"caseId":{"type":"string","format":"uuid"},"targetId":{"type":"string","format":"uuid"},"targetKind":{"type":"string","const":"CASE"},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetVersion":{"type":"integer","minimum":1},"reviewSnapshotId":{"type":"string","format":"uuid"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"reviewSnapshotDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"additionalProperties":false},{"type":"object","required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","publicationRevisionId"],"properties":{"targetId":{"type":"string","format":"uuid"},"targetKind":{"type":"string","const":"PUBLICATION"},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetVersion":{"type":"integer","minimum":1},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"publicationRevisionId":{"type":"string","format":"uuid"}},"additionalProperties":false},{"type":"object","required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","evidenceId"],"properties":{"targetId":{"type":"string","format":"uuid"},"evidenceId":{"type":"string","format":"uuid"},"targetKind":{"type":"string","const":"EVIDENCE"},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetVersion":{"type":"integer","minimum":1},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"additionalProperties":false},{"type":"object","required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","responseId"],"properties":{"targetId":{"type":"string","format":"uuid"},"responseId":{"type":"string","format":"uuid"},"targetKind":{"type":"string","const":"RESPONSE"},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetVersion":{"type":"integer","minimum":1},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"additionalProperties":false},{"type":"object","required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","sourceDocumentId","sourceAssetId"],"properties":{"targetId":{"type":"string","format":"uuid"},"targetKind":{"type":"string","const":"SOURCE_ASSET"},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"sourceAssetId":{"type":"string","format":"uuid"},"targetVersion":{"type":"integer","minimum":1},"sourceDocumentId":{"type":"string","format":"uuid"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"additionalProperties":false},{"type":"object","required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","researchArtifactId","researchAssetId"],"properties":{"targetId":{"type":"string","format":"uuid"},"targetKind":{"type":"string","const":"RESEARCH_ARTIFACT"},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetVersion":{"type":"integer","minimum":1},"researchAssetId":{"type":"string","format":"uuid"},"researchArtifactId":{"type":"string","format":"uuid"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"additionalProperties":false},{"type":"object","required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","privacyRequestId","privacyRequestType"],"properties":{"targetId":{"type":"string","format":"uuid"},"targetKind":{"type":"string","const":"PRIVACY_REQUEST"},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetVersion":{"type":"integer","minimum":1},"privacyRequestId":{"type":"string","format":"uuid"},"privacyRequestType":{"enum":["ACCESS","CORRECTION","DELETION","RESTRICTION"],"type":"string"},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"additionalProperties":false},{"type":"object","required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","communicationSubjectId","communicationSubjectOriginDigest"],"properties":{"targetId":{"type":"string","format":"uuid"},"targetKind":{"type":"string","const":"COMMUNICATION_SUBJECT"},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetVersion":{"type":"integer","minimum":1},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"communicationSubjectId":{"type":"string","format":"uuid"},"communicationSubjectOriginDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"additionalProperties":false},{"type":"object","required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","entityKind","entityRetentionSnapshotId","entityRetentionSnapshotDigest"],"properties":{"targetId":{"type":"string","format":"uuid"},"entityKind":{"type":"string","const":"SUPPLIER"},"targetKind":{"type":"string","const":"SUPPLIER_RETENTION_SNAPSHOT"},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetVersion":{"type":"integer","minimum":1},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"entityRetentionSnapshotId":{"type":"string","format":"uuid"},"entityRetentionSnapshotDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"additionalProperties":false},{"type":"object","required":["targetKind","targetId","targetVersion","targetDigest","targetAnchorDigest","entityKind","entityRetentionSnapshotId","entityRetentionSnapshotDigest"],"properties":{"targetId":{"type":"string","format":"uuid"},"entityKind":{"type":"string","const":"AGENCY"},"targetKind":{"type":"string","const":"AGENCY_RETENTION_SNAPSHOT"},"targetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"targetVersion":{"type":"integer","minimum":1},"targetAnchorDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"entityRetentionSnapshotId":{"type":"string","format":"uuid"},"entityRetentionSnapshotDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"additionalProperties":false}]},"placedAt":{"type":"string","format":"date-time"},"expiresAt":{"oneOf":[{"type":"string","format":"date-time"},{"type":"null"}]},"scopeAtoms":{"type":"array","items":{"enum":["RETENTION","DELETION","DISCLOSURE"],"type":"string"},"maxItems":3,"minItems":1,"uniqueItems":true},"legalHoldId":{"type":"string","format":"uuid"},"placedByActorId":{"type":"string","format":"uuid"},"affectedSetDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"holdReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"auditReceiptDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"authorityReferenceDigest":{"type":"string","pattern":"^[0-9a-f]{64}$"}},"additionalProperties":false}$r6d_hold_inline$::jsonb
)
ON CONFLICT(event_type) DO UPDATE SET
  category=EXCLUDED.category,
  schema_version=EXCLUDED.schema_version,
  active=EXCLUDED.active,
  payload_schema_uri=EXCLUDED.payload_schema_uri,
  payload_schema=EXCLUDED.payload_schema;
-- Draft for integration into 0038_r6d_legal_hardening.sql before COMMIT.
--
-- The five entity record classes remain deliberately non-executable here.
-- Their rows do not yet carry an immutable last-material-use classification
-- receipt or a crypto-erasable typed plaintext child.  Guessing from updated_at
-- or replacing identifiers with synthetic strings would be destructive policy
-- invention.  This owner boundary therefore admits only the typed PERSON v3
-- context whose trigger, ciphertext child, and digest-preserving erasure owner
-- already exist.

CREATE TABLE ops.r6d_person_retention_execution_receipts_v1 (
  receipt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL UNIQUE REFERENCES ops.jobs(id) ON DELETE RESTRICT,
  job_fencing_token bigint NOT NULL,
  job_lease_token_sha256 char(64) NOT NULL,
  job_payload_digest char(64) NOT NULL,
  context_id uuid NOT NULL UNIQUE
    REFERENCES core.relationship_graph_person_context_v3(context_id)
    ON DELETE RESTRICT,
  person_node_id uuid NOT NULL,
  topology_digest char(64) NOT NULL,
  person_name_digest char(64) NOT NULL,
  context_state_digest char(64) NOT NULL,
  schedule_id uuid NOT NULL,
  record_class text NOT NULL,
  schedule_revision bigint NOT NULL,
  schedule_digest char(64) NOT NULL,
  trigger_kind text NOT NULL,
  trigger_at timestamptz NOT NULL,
  due_at timestamptz NOT NULL,
  erasure_receipt_id uuid NOT NULL UNIQUE
    REFERENCES core.relationship_graph_person_erasure_receipts_v3(receipt_id)
    ON DELETE RESTRICT,
  erasure_receipt_digest char(64) NOT NULL UNIQUE,
  erasure_audit_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  governance_retention_schedule_id uuid NOT NULL,
  governance_retention_record_class text NOT NULL,
  governance_retention_schedule_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  completed_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT r6d_person_retention_execution_schedule_fk FOREIGN KEY (
    schedule_id,record_class,schedule_digest
  ) REFERENCES ops.record_class_schedules(
    id,record_class,schedule_digest
  ) ON DELETE RESTRICT,
  CONSTRAINT r6d_person_retention_execution_governance_retention_fk
    FOREIGN KEY (
      governance_retention_schedule_id,governance_retention_record_class,
      governance_retention_schedule_digest
    ) REFERENCES ops.record_class_schedules(
      id,record_class,schedule_digest
    ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT r6d_person_retention_execution_shape_ck CHECK (
    job_fencing_token>0
    AND record_class='RELATIONSHIP_PERSON_CONTEXT'
    AND governance_retention_record_class='PERSON_ERASURE_GOVERNANCE'
    AND schedule_revision>0
    AND trigger_kind='CREATED_AT'
    AND due_at>=trigger_at
    AND completed_at>=due_at
    AND ops.r6d_lower_sha256(job_lease_token_sha256)
    AND ops.r6d_lower_sha256(job_payload_digest)
    AND ops.r6d_lower_sha256(topology_digest)
    AND ops.r6d_lower_sha256(person_name_digest)
    AND ops.r6d_lower_sha256(context_state_digest)
    AND ops.r6d_lower_sha256(schedule_digest)
    AND ops.r6d_lower_sha256(erasure_receipt_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(governance_retention_schedule_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(
      extensions.digest(receipt_canonical,'sha256'),'hex'
    )
  )
);
ALTER TABLE ops.r6d_person_retention_execution_receipts_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON ops.r6d_person_retention_execution_receipts_v1 FROM PUBLIC;
GRANT SELECT ON ops.r6d_person_retention_execution_receipts_v1
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER r6d_person_retention_execution_receipts_immutable_guard
  BEFORE UPDATE OR DELETE
  ON ops.r6d_person_retention_execution_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

-- One canonical resolver owns the legal-hold decision used by the scheduler,
-- worker, and erasure owner.  `legal_holds.active` and `expires_at` are not
-- release authority: coverage is the immutable placement cells minus the
-- append-only, digest-linked release cells.
-- Shared one-hold validator for every R6d coverage consumer.  It verifies the
-- typed placement/anchor binding and the complete append-only release chain,
-- then returns the remaining cells without consulting a mutable status flag.
CREATE OR REPLACE FUNCTION ops.r6d_legal_hold_cell_resolution_v1(
  p_hold_id uuid,
  p_at_time timestamptz
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $$
DECLARE
  v_release_state jsonb;
  v_active_cells jsonb;
  v_proof_digest char(64);
  v_release_sequence bigint;
BEGIN
  IF p_hold_id IS NULL OR p_at_time IS NULL THEN
    RAISE EXCEPTION 'r6d_legal_hold_resolution_input_invalid'
      USING ERRCODE='22023';
  END IF;

  -- The v2 owner is the sole authority for placement validation, canonical
  -- initial cells, and the append-only release digest recurrence. Retention
  -- consumers must not reconstruct any of those values from legal_holds.
  v_release_state:=ops.r6d_legal_hold_release_state_v2(
    p_hold_id,p_at_time
  );
  IF jsonb_typeof(v_release_state)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_release_state))<>12
     OR NOT v_release_state ?& ARRAY[
       'schemaVersion','holdId','placementReceiptId',
       'placementReceiptDigest','targetAnchorId','targetAnchorDigest',
       'currentReleaseSequence','currentReleaseId','currentReleaseDigest',
       'coverageDigest','activeCells','state'
     ]
     OR v_release_state->>'schemaVersion' IS DISTINCT FROM
        'r6d-legal-hold-release-state.v2'
     OR (v_release_state->>'holdId')::uuid IS DISTINCT FROM p_hold_id
     OR (v_release_state->>'placementReceiptId')::uuid IS NULL
     OR NOT COALESCE(ops.r6d_lower_sha256(
       v_release_state->>'placementReceiptDigest'
     ),false)
     OR (v_release_state->>'targetAnchorId')::uuid IS NULL
     OR NOT COALESCE(ops.r6d_lower_sha256(
       v_release_state->>'targetAnchorDigest'
     ),false)
     OR jsonb_typeof(v_release_state->'currentReleaseSequence')<>'number'
     OR (v_release_state->>'currentReleaseSequence')::bigint<0
     OR NOT COALESCE(ops.r6d_lower_sha256(
       v_release_state->>'coverageDigest'
     ),false)
     OR jsonb_typeof(v_release_state->'activeCells')<>'array'
     OR v_release_state->>'state' IS NULL
     OR v_release_state->>'state' NOT IN (
       'ACTIVE','PARTIALLY_RELEASED','FULLY_RELEASED'
     ) THEN
    RAISE EXCEPTION 'r6d_legal_hold_release_state_invalid'
      USING ERRCODE='55000';
  END IF;

  v_release_sequence:=(v_release_state->>'currentReleaseSequence')::bigint;
  v_active_cells:=v_release_state->'activeCells';
  IF (v_release_sequence=0 AND (
        v_release_state->>'currentReleaseId' IS NOT NULL
        OR v_release_state->>'currentReleaseDigest' IS NOT NULL
      ))
     OR (v_release_sequence>0 AND (
        (v_release_state->>'currentReleaseId')::uuid IS NULL
        OR NOT COALESCE(ops.r6d_lower_sha256(
          v_release_state->>'currentReleaseDigest'
        ),false)
      ))
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(
         v_release_state->'activeCells'
       ) AS cell(value)
       WHERE jsonb_typeof(cell.value)<>'object'
          OR NOT cell.value ?& ARRAY['scopeAtom','affectedId']
          OR cell.value-ARRAY['scopeAtom','affectedId']<>'{}'::jsonb
          OR cell.value->>'scopeAtom' NOT IN (
            'DELETION','DISCLOSURE','RETENTION'
          )
          OR (cell.value->>'affectedId')::uuid IS NULL
     )
     OR v_active_cells IS DISTINCT FROM COALESCE((
       SELECT jsonb_agg(cell.value ORDER BY
         cell.value->>'scopeAtom',(cell.value->>'affectedId')::uuid
       )
       FROM jsonb_array_elements(v_active_cells) AS cell(value)
     ),'[]'::jsonb)
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(v_active_cells) AS cell(value)
       GROUP BY cell.value->>'scopeAtom',cell.value->>'affectedId'
       HAVING count(*)>1
     )
     OR (v_release_state->>'state'='ACTIVE' AND (
       v_release_sequence<>0 OR jsonb_array_length(v_active_cells)=0
     ))
     OR (v_release_state->>'state'='PARTIALLY_RELEASED' AND (
       v_release_sequence=0 OR jsonb_array_length(v_active_cells)=0
     ))
     OR (v_release_state->>'state'='FULLY_RELEASED' AND (
       v_release_sequence=0 OR jsonb_array_length(v_active_cells)<>0
     )) THEN
    RAISE EXCEPTION 'r6d_legal_hold_release_state_invalid'
      USING ERRCODE='55000';
  END IF;

  v_proof_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_release_state),'sha256'
  ),'hex');
  RETURN jsonb_build_object(
    'holdId',p_hold_id,'proof',v_release_state,
    'proofDigest',btrim(v_proof_digest),'activeCells',v_active_cells
  );
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'r6d_legal_hold_release_state_invalid'
      USING ERRCODE='55000';
END
$$;
ALTER FUNCTION ops.r6d_legal_hold_cell_resolution_v1(uuid,timestamptz)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_legal_hold_cell_resolution_v1(
  uuid,timestamptz
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.r6d_person_legal_hold_coverage_v1(
  p_record_class text,
  p_relation_name regclass,
  p_row_id uuid,
  p_at_time timestamptz
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,core,editorial,extensions,pg_temp
AS $$
DECLARE
  v_context core.relationship_graph_person_context_v3%ROWTYPE;
  v_schedule ops.record_class_schedules%ROWTYPE;
  v_hold_id uuid;
  v_hold_resolution jsonb;
  v_cell jsonb;
  v_hold_proofs jsonb:='[]'::jsonb;
  v_active_cells jsonb:='[]'::jsonb;
  v_coverage_payload jsonb;
  v_coverage_digest char(64);
  v_lock_id text;
BEGIN
  IF p_record_class IS DISTINCT FROM 'RELATIONSHIP_PERSON_CONTEXT'
     OR p_relation_name IS DISTINCT FROM
        'core.relationship_graph_person_context_v3'::regclass
     OR p_row_id IS NULL OR p_at_time IS NULL THEN
    RAISE EXCEPTION 'r6d_legal_hold_relation_or_class_unsupported'
      USING ERRCODE='55000';
  END IF;
  SELECT * INTO v_context FROM core.relationship_graph_person_context_v3
  WHERE context_id=p_row_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'r6d_legal_hold_target_row_missing'
      USING ERRCODE='55000';
  END IF;
  FOR v_lock_id IN
    SELECT lock_id FROM (
      VALUES(v_context.context_id::text),(v_context.person_node_id::text)
    ) AS locks(lock_id) ORDER BY lock_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_lock_id,13));
  END LOOP;
  SELECT * INTO v_context FROM core.relationship_graph_person_context_v3
  WHERE context_id=p_row_id FOR SHARE;
  IF NOT FOUND OR v_context.retention_record_class IS DISTINCT FROM
     p_record_class THEN
    RAISE EXCEPTION 'r6d_legal_hold_target_binding_invalid'
      USING ERRCODE='55000';
  END IF;
  SELECT * INTO v_schedule FROM ops.record_class_schedules
  WHERE (id,record_class,schedule_digest)=(
    v_context.retention_schedule_id,v_context.retention_record_class,
    v_context.retention_schedule_digest
  );
  IF NOT FOUND OR v_schedule.effective_at>p_at_time
     OR v_schedule.review_expires_at<=p_at_time
     OR v_schedule.terminal_action<>'ANONYMIZE'
     OR v_schedule.hold_behavior NOT IN (
       'BLOCK_ON_RETENTION','BLOCK_ON_RETENTION_OR_DELETION'
     ) THEN
    RAISE EXCEPTION 'r6d_legal_hold_schedule_stale_or_invalid'
      USING ERRCODE='55000';
  END IF;
  FOR v_hold_id IN
    SELECT placement.legal_hold_id
    FROM ops.legal_hold_placement_receipts_v2 AS placement
    WHERE placement.placed_at<=p_at_time
      AND (
        placement.affected_ids @> ARRAY[v_context.context_id]::uuid[]
        OR placement.affected_ids @> ARRAY[v_context.person_node_id]::uuid[]
      )
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
         AND (v_cell->>'affectedId')::uuid IN (
           v_context.context_id,v_context.person_node_id
         ) THEN
        v_active_cells:=v_active_cells||jsonb_build_array(
          jsonb_build_object(
            'holdId',v_hold_id,'scopeAtom',v_cell->>'scopeAtom',
            'affectedId',(v_cell->>'affectedId')::uuid
          )
        );
      END IF;
    END LOOP;
  END LOOP;
  v_coverage_payload:=jsonb_build_object(
    'schemaVersion','r6d-person-legal-hold-coverage.v1',
    'recordClass',p_record_class,'relationName',p_relation_name::text,
    'rowId',p_row_id,'personNodeId',v_context.person_node_id,
    'scheduleId',v_schedule.id,
    'scheduleDigest',btrim(v_schedule.schedule_digest),
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
$$;
ALTER FUNCTION ops.r6d_person_legal_hold_coverage_v1(
  text,regclass,uuid,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_person_legal_hold_coverage_v1(
  text,regclass,uuid,timestamptz
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.record_has_active_legal_hold(
  retention_record_class text,
  relation_name regclass,
  row_id uuid,
  at_time timestamptz
) RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,core,editorial,extensions,pg_temp
AS $$
DECLARE v_resolution jsonb;
BEGIN
  v_resolution:=ops.r6d_person_legal_hold_coverage_v1(
    retention_record_class,relation_name,row_id,at_time
  );
  RETURN (v_resolution->>'active')::boolean;
END
$$;
ALTER FUNCTION ops.record_has_active_legal_hold(
  text,regclass,uuid,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.record_has_active_legal_hold(
  text,regclass,uuid,timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.record_has_active_legal_hold(
  text,regclass,uuid,timestamptz
) TO gurine_workflow_worker;

CREATE OR REPLACE FUNCTION ops.r6d_entity_legal_hold_coverage_v1(
  p_subject_kind text,
  p_subject_id uuid,
  p_at_time timestamptz
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $$
DECLARE
  v_target_kind text;
  v_hold_id uuid;
  v_hold_resolution jsonb;
  v_cell jsonb;
  v_hold_proofs jsonb:='[]'::jsonb;
  v_active_cells jsonb:='[]'::jsonb;
  v_coverage_payload jsonb;
  v_coverage_digest char(64);
BEGIN
  IF p_subject_kind NOT IN ('SUPPLIER','AGENCY')
     OR p_subject_id IS NULL OR p_at_time IS NULL THEN
    RAISE EXCEPTION 'r6d_entity_legal_hold_resolution_input_invalid'
      USING ERRCODE='22023';
  END IF;
  v_target_kind:=p_subject_kind||'_RETENTION_SNAPSHOT';
  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_subject_id::text,13)
  );
  FOR v_hold_id IN
    SELECT placement.legal_hold_id
    FROM ops.legal_hold_placement_receipts_v2 AS placement
    JOIN ops.legal_hold_target_anchors AS anchor
      ON anchor.id=placement.anchor_id
     AND anchor.anchor_digest=placement.anchor_digest
    JOIN ops.entity_retention_snapshots_v1 AS prior
      ON prior.snapshot_id=anchor.entity_retention_snapshot_id
     AND prior.snapshot_digest=anchor.entity_retention_snapshot_digest
    WHERE placement.placed_at<=p_at_time
      AND anchor.target_kind=v_target_kind
      AND prior.subject_kind=p_subject_kind
      AND prior.subject_id=p_subject_id
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
      v_active_cells:=v_active_cells||jsonb_build_array(
        jsonb_build_object(
          'holdId',v_hold_id,'scopeAtom',v_cell->>'scopeAtom',
          'affectedId',(v_cell->>'affectedId')::uuid
        )
      );
    END LOOP;
  END LOOP;
  v_coverage_payload:=jsonb_build_object(
    'schemaVersion','r6d-entity-legal-hold-coverage.v1',
    'subjectKind',p_subject_kind,'subjectId',p_subject_id,
    'targetKind',v_target_kind,'holdProofs',v_hold_proofs,
    'activeCells',v_active_cells
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
$$;
ALTER FUNCTION ops.r6d_entity_legal_hold_coverage_v1(
  text,uuid,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_entity_legal_hold_coverage_v1(
  text,uuid,timestamptz
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.r6d_privacy_request_legal_hold_coverage_v1(
  p_privacy_request_id uuid,
  p_at_time timestamptz
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $$
DECLARE
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
  FOR v_hold_id IN
    SELECT placement.legal_hold_id
    FROM ops.legal_hold_placement_receipts_v2 AS placement
    WHERE placement.placed_at<=p_at_time
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
$$;
ALTER FUNCTION ops.r6d_privacy_request_legal_hold_coverage_v1(
  uuid,timestamptz
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_privacy_request_legal_hold_coverage_v1(
  uuid,timestamptz
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.r6d_privacy_request_legal_hold_coverage_v1(
  uuid,timestamptz
) TO gurine_control_api,gurine_workflow_worker;

CREATE OR REPLACE FUNCTION ops.create_entity_retention_snapshot_v1(
  p_subject_kind text,
  p_subject_id uuid,
  p_actor_id uuid,
  p_request_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,core,extensions,pg_temp
AS $$
DECLARE
  v_existing ops.entity_retention_snapshots_v1%ROWTYPE;
  v_schedule ops.record_class_schedules%ROWTYPE;
  v_snapshot_id uuid:=gen_random_uuid();
  v_updated_at timestamptz;
  v_subject_version bigint;
  v_state jsonb;
  v_state_digest char(64);
  v_hold_resolution jsonb;
  v_hold_digest char(64);
  v_payload jsonb;
  v_canonical bytea;
  v_snapshot_digest char(64);
  v_receipt_digest char(64);
  v_audit uuid;
  v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_subject_kind NOT IN ('AGENCY','SUPPLIER') OR p_subject_id IS NULL
     OR p_actor_id IS NULL OR p_request_id IS NULL
     OR NOT ops.r6d_lower_sha256(p_idempotency_key)
     OR NOT ops.r6d_lower_sha256(p_request_digest) THEN
    RAISE EXCEPTION 'entity_retention_snapshot_input_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing FROM ops.entity_retention_snapshots_v1
  WHERE idempotency_key_sha256=p_idempotency_key FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest<>p_request_digest THEN
      RAISE EXCEPTION 'entity_retention_snapshot_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN jsonb_build_object(
      'snapshotId',v_existing.snapshot_id,
      'subjectKind',v_existing.subject_kind,
      'subjectId',v_existing.subject_id,
      'subjectVersion',v_existing.subject_version,
      'snapshotDigest',v_existing.snapshot_digest,
      'holdCoverageDigest',v_existing.hold_coverage_digest,
      'scheduleId',v_existing.retention_schedule_id,
      'scheduleDigest',v_existing.retention_schedule_digest,
      'receiptDigest',v_existing.receipt_digest,
      'createdAt',v_existing.created_at
    );
  END IF;
  IF p_subject_kind='AGENCY' THEN
    SELECT agency.updated_at,jsonb_build_object(
      'id',agency.id,'canonicalName',agency.canonical_name,
      'agencyType',agency.agency_type,'jurisdiction',agency.jurisdiction,
      'parentAgencyId',agency.parent_agency_id,'active',agency.active,
      'identityStatus',agency.identity_status,'updatedAt',agency.updated_at
    ) INTO v_updated_at,v_state
    FROM core.agencies AS agency WHERE agency.id=p_subject_id FOR SHARE;
  ELSE
    SELECT supplier.updated_at,jsonb_build_object(
      'id',supplier.id,'canonicalName',supplier.canonical_name,
      'businessStatus',supplier.business_status,
      'incorporationDate',supplier.incorporation_date,
      'identityStatus',supplier.identity_status,
      'updatedAt',supplier.updated_at
    ) INTO v_updated_at,v_state
    FROM core.suppliers AS supplier WHERE supplier.id=p_subject_id FOR SHARE;
  END IF;
  IF v_updated_at IS NULL THEN
    RAISE EXCEPTION 'entity_retention_subject_not_found'
      USING ERRCODE='22023';
  END IF;
  v_subject_version:=floor(extract(epoch FROM v_updated_at)*1000000)::bigint;
  v_state_digest:=encode(
    extensions.digest(ops.canonical_jsonb_v1(v_state),'sha256'),'hex'
  );
  v_hold_resolution:=ops.r6d_entity_legal_hold_coverage_v1(
    p_subject_kind,p_subject_id,v_now
  );
  v_hold_digest:=(v_hold_resolution->>'coverageDigest')::char(64);
  SELECT schedule.* INTO STRICT v_schedule
  FROM ops.record_class_schedules AS schedule
  JOIN ops.execution_receipts AS execution
    ON execution.id=schedule.action_execution_receipt_id
   AND execution.receipt_digest=
       schedule.action_execution_receipt_digest
   AND execution.aggregate_state='SUCCEEDED'
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
  WHERE schedule.record_class='ENTITY_RETENTION_SNAPSHOT'
    AND schedule.effective_at<=v_now AND schedule.review_expires_at>v_now
    AND schedule.terminal_action='PRESERVE_REFERENCED_REVISION';
  v_payload:=jsonb_build_object(
    'schemaVersion','entity-retention-snapshot.v1',
    'subjectKind',p_subject_kind,'subjectId',p_subject_id,
    'subjectVersion',v_subject_version,'subjectUpdatedAt',v_updated_at,
    'entityStateDigest',v_state_digest,
    'holdCoverageDigest',btrim(v_hold_digest),
    'scheduleId',v_schedule.id,
    'scheduleDigest',btrim(v_schedule.schedule_digest)
  );
  v_canonical:=ops.canonical_jsonb_v1(v_payload);
  v_snapshot_digest:=encode(extensions.digest(v_canonical,'sha256'),'hex');
  v_receipt_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'snapshotId',v_snapshot_id,'snapshotDigest',v_snapshot_digest,
      'requestId',p_request_id,'requestDigest',btrim(p_request_digest)
    )
  ),'sha256'),'hex');
  v_audit:=ops.append_audit_event(
    'retention:entity-snapshot:'||v_snapshot_id::text,
    'USER',p_actor_id::text,NULL::uuid,'retention.entity_snapshot.create',
    'EntityRetentionSnapshot',v_snapshot_id::text,
    'privacy.retention.manage','SUCCESS',NULL,p_request_id,
    jsonb_build_object(
      'subjectKind',p_subject_kind,'subjectId',p_subject_id,
      'snapshotDigest',v_snapshot_digest,
      'holdCoverageDigest',btrim(v_hold_digest)
    )
  );
  INSERT INTO ops.entity_retention_snapshots_v1(
    snapshot_id,subject_kind,subject_id,subject_version,subject_updated_at,
    entity_state_digest,hold_coverage_digest,snapshot_payload,
    snapshot_canonical,snapshot_digest,created_actor_type,created_actor_id,
    created_by,request_id,idempotency_key_sha256,request_digest,audit_event_id,
    receipt_digest,created_at
  ) VALUES(
    v_snapshot_id,p_subject_kind,p_subject_id,v_subject_version,v_updated_at,
    v_state_digest,v_hold_digest,v_payload,v_canonical,v_snapshot_digest,
    'HUMAN',p_actor_id::text,p_actor_id,p_request_id,p_idempotency_key,
    p_request_digest,v_audit,v_receipt_digest,v_now
  );
  RETURN jsonb_build_object(
    'snapshotId',v_snapshot_id,'subjectKind',p_subject_kind,
    'subjectId',p_subject_id,'subjectVersion',v_subject_version,
    'snapshotDigest',v_snapshot_digest,
    'holdCoverageDigest',btrim(v_hold_digest),
    'scheduleId',v_schedule.id,
    'scheduleDigest',btrim(v_schedule.schedule_digest),
    'receiptDigest',v_receipt_digest,'createdAt',v_now
  );
EXCEPTION WHEN no_data_found OR too_many_rows THEN
  RAISE EXCEPTION 'entity_retention_schedule_missing_or_ambiguous'
    USING ERRCODE='55000';
END
$$;
ALTER FUNCTION ops.create_entity_retention_snapshot_v1(
  text,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.create_entity_retention_snapshot_v1(
  text,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.create_entity_retention_snapshot_v1(
  text,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

CREATE OR REPLACE FUNCTION core.anonymize_relationship_graph_person_context_v3(
  p_context_id uuid,
  p_actor_type text,
  p_actor_id text,
  p_request_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,core,editorial,ops,extensions,pg_temp
AS $$
DECLARE
  v_context core.relationship_graph_person_context_v3%ROWTYPE;
  v_existing core.relationship_graph_person_erasure_receipts_v3%ROWTYPE;
  v_hold_resolution jsonb;
  v_hold_digest char(64);
  v_prior_digest char(64);
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
  v_audit uuid;
  v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_context_id IS NULL OR p_actor_type<>'SERVICE'
     OR p_actor_id<>'retention-worker' OR p_request_id IS NULL
     OR NOT ops.r6d_lower_sha256(p_idempotency_key)
     OR NOT ops.r6d_lower_sha256(p_request_digest) THEN
    RAISE EXCEPTION 'person_context_anonymize_input_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_existing
  FROM core.relationship_graph_person_erasure_receipts_v3
  WHERE idempotency_key_sha256=p_idempotency_key FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest<>p_request_digest
       OR v_existing.context_id<>p_context_id THEN
      RAISE EXCEPTION 'person_context_anonymize_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN v_existing.receipt_payload||jsonb_build_object(
      'receiptDigest',v_existing.receipt_digest,
      'auditEventId',v_existing.audit_event_id,'replayed',true
    );
  END IF;
  SELECT * INTO v_context
  FROM core.relationship_graph_person_context_v3
  WHERE context_id=p_context_id FOR UPDATE;
  IF NOT FOUND OR v_context.erase_state<>'ACTIVE' THEN
    RAISE EXCEPTION 'person_context_not_active' USING ERRCODE='55000';
  END IF;
  v_hold_resolution:=ops.r6d_person_legal_hold_coverage_v1(
    'RELATIONSHIP_PERSON_CONTEXT',
    'core.relationship_graph_person_context_v3'::regclass,
    v_context.context_id,v_now
  );
  v_hold_digest:=(v_hold_resolution->>'coverageDigest')::char(64);
  IF (v_hold_resolution->>'active')::boolean THEN
    RAISE EXCEPTION 'person_context_legal_hold_active'
      USING ERRCODE='55000';
  END IF;
  v_prior_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
    jsonb_build_object(
      'contextId',v_context.context_id,'personNodeId',v_context.person_node_id,
      'topologyDigest',btrim(v_context.topology_digest),
      'personNameDigest',btrim(v_context.person_name_digest),
      'contextualNameSha256',btrim(v_context.contextual_name_sha256),
      'contextualNameAadDigest',btrim(v_context.contextual_name_aad_digest),
      'roleTitleSha256',btrim(v_context.role_title_sha256),
      'roleTitleAadDigest',btrim(v_context.role_title_aad_digest),
      'encryptionKeyId',v_context.encryption_key_id
    )
  ),'sha256'),'hex');
  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','relationship-person-context-erasure.v3',
    'contextId',v_context.context_id,'personNodeId',v_context.person_node_id,
    'topologyDigest',btrim(v_context.topology_digest),
    'personNameDigest',btrim(v_context.person_name_digest),
    'priorContextDigest',v_prior_digest,'erasureKind','ANONYMIZE',
    'legalHoldCoverageDigest',btrim(v_hold_digest),'actorType',p_actor_type,
    'actorId',p_actor_id,'requestId',p_request_id,'erasedAt',v_now
  );
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_receipt_digest:=encode(
    extensions.digest(v_receipt_canonical,'sha256'),'hex'
  );
  v_audit:=ops.append_audit_event(
    'person-context-erasure:'||v_context.context_id::text,p_actor_type,
    p_actor_id,NULL::uuid,'person_context.anonymize','PersonContext',
    v_context.context_id::text,'privacy.retention.execute','SUCCESS',NULL,
    p_request_id,jsonb_build_object(
      'priorContextDigest',v_prior_digest,
      'legalHoldCoverageDigest',btrim(v_hold_digest)
    )
  );
  INSERT INTO core.relationship_graph_person_erasure_receipts_v3(
    context_id,person_node_id,topology_digest,person_name_digest,
    prior_context_digest,erasure_kind,legal_hold_coverage_digest,actor_type,
    actor_id,request_id,idempotency_key_sha256,request_digest,audit_event_id,
    receipt_payload,receipt_canonical,receipt_digest,erased_at
  ) VALUES(
    v_context.context_id,v_context.person_node_id,v_context.topology_digest,
    v_context.person_name_digest,v_prior_digest,'ANONYMIZE',v_hold_digest,
    p_actor_type,p_actor_id,p_request_id,p_idempotency_key,p_request_digest,
    v_audit,v_receipt_payload,v_receipt_canonical,v_receipt_digest,v_now
  );
  PERFORM set_config('gurine.person_context_erasure','1',true);
  UPDATE core.relationship_graph_person_context_v3
  SET contextual_name_ciphertext=NULL,contextual_name_sha256=NULL,
      contextual_name_aad_digest=NULL,role_title_ciphertext=NULL,
      role_title_sha256=NULL,role_title_aad_digest=NULL,encryption_key_id=NULL,
      erase_state='ANONYMIZED',erased_at=v_now,
      erasure_receipt_digest=v_receipt_digest
  WHERE context_id=v_context.context_id AND erase_state='ACTIVE';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'person_context_anonymize_concurrent_conflict'
      USING ERRCODE='40001';
  END IF;
  RETURN v_receipt_payload||jsonb_build_object(
    'receiptDigest',v_receipt_digest,'auditEventId',v_audit,'replayed',false
  );
END
$$;
ALTER FUNCTION core.anonymize_relationship_graph_person_context_v3(
  uuid,text,text,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION core.anonymize_relationship_graph_person_context_v3(
  uuid,text,text,uuid,char(64),char(64)
) FROM PUBLIC,gurine_control_api;
GRANT EXECUTE ON FUNCTION core.anonymize_relationship_graph_person_context_v3(
  uuid,text,text,uuid,char(64),char(64)
) TO gurine_workflow_worker;

CREATE OR REPLACE FUNCTION ops.enqueue_due_r6d_person_retention_jobs_v1(
  p_limit integer
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,core,editorial,extensions,pg_temp
AS $$
DECLARE
  v_candidate record;
  v_now timestamptz:=clock_timestamp();
  v_request_id uuid;
  v_context_state_digest char(64);
  v_idempotency_key char(64);
  v_request_digest char(64);
  v_payload_base jsonb;
  v_payload jsonb;
  v_dedupe_key text;
  v_job_id uuid;
  v_job_ids jsonb:='[]'::jsonb;
  v_enqueued integer:=0;
BEGIN
  IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
    RAISE EXCEPTION 'r6d_person_retention_enqueue_limit_invalid'
      USING ERRCODE='22023';
  END IF;

  FOR v_candidate IN
    SELECT
      context.context_id,context.person_node_id,context.topology_digest,
      context.person_name_digest,context.contextual_name_sha256,
      context.contextual_name_aad_digest,context.role_title_sha256,
      context.role_title_aad_digest,context.encryption_key_id,
      context.created_at AS trigger_at,
      schedule.id AS schedule_id,schedule.revision AS schedule_revision,
      schedule.schedule_digest,schedule.trigger_kind,
      schedule.terminal_action,schedule.hold_behavior,
      schedule.active_duration_seconds,schedule.backup_duration_seconds,
      context.created_at+make_interval(
        secs=>schedule.active_duration_seconds::double precision
      ) AS due_at
    FROM core.relationship_graph_person_context_v3 AS context
    JOIN ops.record_class_schedules AS schedule
      ON (schedule.id,schedule.record_class,schedule.schedule_digest)=
         (context.retention_schedule_id,context.retention_record_class,
          context.retention_schedule_digest)
    JOIN ops.r6d_record_class_catalog AS catalog
      ON catalog.record_class=schedule.record_class
    JOIN ops.execution_receipts AS execution
      ON execution.id=schedule.action_execution_receipt_id
     AND execution.receipt_digest=schedule.action_execution_receipt_digest
     AND execution.aggregate_state='SUCCEEDED'
    JOIN ops.action_decisions AS operational_decision
      ON operational_decision.id=schedule.operational_action_decision_id
     AND operational_decision.receipt_digest=
         schedule.operational_action_decision_receipt_digest
     AND operational_decision.decision_kind='APPROVE'
    JOIN ops.action_decisions AS legal_decision
      ON legal_decision.id=schedule.legal_action_decision_id
     AND legal_decision.receipt_digest=
         schedule.legal_action_decision_receipt_digest
     AND legal_decision.decision_kind='APPROVE'
    WHERE context.erase_state='ACTIVE'
      AND context.retention_record_class='RELATIONSHIP_PERSON_CONTEXT'
      AND catalog.data_category='PERSON_IDENTITY'
      AND catalog.pii_write
      AND catalog.required_terminal_action='ANONYMIZE'
      AND schedule.terminal_action=catalog.required_terminal_action
      AND schedule.trigger_kind='CREATED_AT'
      AND schedule.active_duration_seconds IS NOT NULL
      AND schedule.backup_duration_seconds IS NOT NULL
      AND schedule.hold_behavior IN (
        'BLOCK_ON_RETENTION','BLOCK_ON_RETENTION_OR_DELETION'
      )
      AND schedule.restore_suppression_behavior='REAPPLY_BEFORE_ACCESS'
      AND (
        catalog.required_trigger_kind IS NULL
        OR catalog.required_trigger_kind=schedule.trigger_kind
      )
      AND (
        catalog.required_active_duration_seconds IS NULL
        OR catalog.required_active_duration_seconds=
           schedule.active_duration_seconds
      )
      AND (
        catalog.required_backup_duration_seconds IS NULL
        OR catalog.required_backup_duration_seconds=
           schedule.backup_duration_seconds
      )
      AND (
        catalog.required_lawful_basis IS NULL
        OR catalog.required_lawful_basis=schedule.lawful_basis
      )
      AND schedule.effective_at<=v_now
      AND schedule.review_expires_at>v_now
      AND context.created_at+make_interval(
        secs=>schedule.active_duration_seconds::double precision
      )<=v_now
      AND NOT ops.record_has_active_legal_hold(
        'RELATIONSHIP_PERSON_CONTEXT',
        'core.relationship_graph_person_context_v3'::regclass,
        context.context_id,v_now
      )
      AND NOT EXISTS (
        SELECT 1
        FROM ops.r6d_person_retention_execution_receipts_v1 AS receipt
        WHERE receipt.context_id=context.context_id
      )
    ORDER BY due_at,context.context_id
    LIMIT p_limit
  LOOP
    v_request_id:=gen_random_uuid();
    v_context_state_digest:=encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'contextId',v_candidate.context_id,
        'personNodeId',v_candidate.person_node_id,
        'topologyDigest',btrim(v_candidate.topology_digest),
        'personNameDigest',btrim(v_candidate.person_name_digest),
        'contextualNameSha256',btrim(v_candidate.contextual_name_sha256),
        'contextualNameAadDigest',
          btrim(v_candidate.contextual_name_aad_digest),
        'roleTitleSha256',btrim(v_candidate.role_title_sha256),
        'roleTitleAadDigest',btrim(v_candidate.role_title_aad_digest),
        'encryptionKeyId',v_candidate.encryption_key_id
      )
    ),'sha256'),'hex');
    v_idempotency_key:=encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'schemaVersion','r6d-person-retention-idempotency.v1',
        'contextId',v_candidate.context_id,
        'personNodeId',v_candidate.person_node_id,
        'contextStateDigest',btrim(v_context_state_digest),
        'scheduleId',v_candidate.schedule_id,
        'scheduleDigest',btrim(v_candidate.schedule_digest),
        'dueAt',v_candidate.due_at
      )
    ),'sha256'),'hex');
    v_payload_base:=jsonb_build_object(
      'schemaVersion','r6d-person-retention-job.v1',
      'contextId',v_candidate.context_id,
      'personNodeId',v_candidate.person_node_id,
      'topologyDigest',btrim(v_candidate.topology_digest),
      'recordClass','RELATIONSHIP_PERSON_CONTEXT',
      'scheduleId',v_candidate.schedule_id,
      'scheduleRevision',v_candidate.schedule_revision,
      'scheduleDigest',btrim(v_candidate.schedule_digest),
      'triggerKind',v_candidate.trigger_kind,
      'terminalAction',v_candidate.terminal_action,
      'holdBehavior',v_candidate.hold_behavior,
      'activeDurationSeconds',v_candidate.active_duration_seconds,
      'backupDurationSeconds',v_candidate.backup_duration_seconds,
      'triggerAt',v_candidate.trigger_at,
      'dueAt',v_candidate.due_at,
      'contextStateDigest',btrim(v_context_state_digest),
      'requestId',v_request_id,
      'idempotencyKeySha256',btrim(v_idempotency_key)
    );
    v_request_digest:=encode(
      extensions.digest(ops.canonical_jsonb_v1(v_payload_base),'sha256'),'hex'
    );
    v_payload:=v_payload_base||jsonb_build_object(
      'requestDigest',btrim(v_request_digest)
    );
    v_dedupe_key:='r6d-person-retention:'||
      v_candidate.context_id::text||':'||btrim(v_candidate.schedule_digest);
    v_job_id:=NULL;
    INSERT INTO ops.jobs(
      job_type,queue,priority,payload,dedupe_key,run_after,max_attempts
    ) VALUES(
      'R6D_PERSON_RETENTION','workflow-worker',80,v_payload,v_dedupe_key,
      v_now,8
    ) ON CONFLICT DO NOTHING
    RETURNING id INTO v_job_id;
    IF v_job_id IS NOT NULL THEN
      v_job_ids:=v_job_ids||jsonb_build_array(v_job_id);
      v_enqueued:=v_enqueued+1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'evaluatedAt',v_now,'enqueuedCount',v_enqueued,'jobIds',v_job_ids
  );
END
$$;
ALTER FUNCTION ops.enqueue_due_r6d_person_retention_jobs_v1(integer)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.enqueue_due_r6d_person_retention_jobs_v1(integer)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.enqueue_due_r6d_person_retention_jobs_v1(integer)
  TO gurine_scheduler;

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
     OR v_job.lease_owner IS DISTINCT FROM 'retention-worker'
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
    v_context.context_id,'SERVICE','retention-worker',v_request_id,
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
     OR v_erasure_receipt.actor_id<>'retention-worker'
     OR btrim(v_erasure_receipt.legal_hold_coverage_digest)<>
        v_hold_resolution->>'coverageDigest' THEN
    RAISE EXCEPTION 'r6d_person_retention_erasure_receipt_invalid'
      USING ERRCODE='55000';
  END IF;

  v_audit:=ops.append_audit_event(
    'r6d-person-retention:'||v_context.context_id::text,
    'SERVICE','retention-worker',NULL::uuid,
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
-- R6d retention and legal-hold owner integration ends.

-- R6d privacy create/read/sealed/notification integration begins.
-- R6d privacy V2 owner routines draft.
-- Intended insertion point: after the privacy V2 relations/event registry and
-- before the terminal COMMIT in 0038_r6d_legal_hardening.sql.
--
-- Exact create payload ABI (25 keys, camelCase; unknown/missing keys fail 22023):
-- privacyRequestId, requestType, jurisdiction, identityProof,
-- scope, scopeCiphertextBase64, scopeAadDigest,
-- statementCiphertextBase64, statementSha256, statementAadDigest,
-- encryptionKeyId, communicationSubjectId, communicationSubjectHmacKeyVersion,
-- communicationSubjectLocale, communicationEndpointId,
-- communicationEndpointChannel, communicationEndpointHmac,
-- communicationEndpointHmacKeyVersion, communicationEndpointCiphertextBase64,
-- communicationEndpointEncryptionKeyId, communicationEndpointAadDigest,
-- explicitVoiceConsentReceiptId, receiptTokenHmac, receiptTokenSha256,
-- receiptTokenKeyVersion.
--
-- Raw scope is accepted transiently for exact closed-object validation and
-- canonical hashing only.  No raw proof, endpoint, scope, statement, token or
-- session credential is persisted or emitted. Ciphertext is canonical base64.
-- explicitVoiceConsentReceiptId is the only nullable create key.  VOICE remains
-- fail-closed until an exact non-circular consent-receipt FK authority exists.

-- No row is seeded and no runtime role receives DML.  The production writer
-- and approval authority are intentionally unresolved, so production remains
-- fail-closed.  A future approved migration may supply a non-TEST_ONLY
-- authority row. Disposable verification uses an explicitly marked TEST_ONLY
-- fixture, which production preflight must reject.
CREATE TABLE ops.privacy_request_access_policies_v1 (
  policy_id uuid NOT NULL,
  revision bigint NOT NULL,
  state text NOT NULL,
  authority text NOT NULL,
  policy_version text NOT NULL,
  allowed_operation text NOT NULL,
  bff_issuer text NOT NULL,
  cookie_profile_id text NOT NULL,
  cookie_name text NOT NULL,
  cookie_path text NOT NULL,
  same_site text NOT NULL,
  secure boolean NOT NULL,
  http_only boolean NOT NULL,
  token_ttl_seconds bigint NOT NULL,
  read_only_session_ttl_seconds bigint NOT NULL,
  policy_payload jsonb NOT NULL,
  policy_canonical bytea NOT NULL,
  policy_digest char(64) NOT NULL,
  binding_digest char(64) NOT NULL UNIQUE,
  effective_at timestamptz NOT NULL,
  review_expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(policy_id,revision),
  UNIQUE(policy_id,revision,policy_digest),
  UNIQUE(policy_id,revision,policy_digest,binding_digest),
  UNIQUE(policy_id,effective_at),
  CONSTRAINT privacy_request_access_policies_v1_shape_ck CHECK (
    revision>0 AND state~'^[A-Z][A-Z0-9_]{2,63}$'
    AND authority~'^[A-Z][A-Z0-9_]{2,63}$'
    AND policy_version~'^[a-z0-9][a-z0-9._-]{0,99}$'
    AND allowed_operation='getPrivacyRequest'
    AND bff_issuer='public-web'
    AND cookie_profile_id='privacy_request_receipt'
    AND cookie_name='gurine_privacy_request_receipt_session'
    AND cookie_path='/privacy'
    AND same_site IN ('LAX','STRICT')
    AND secure AND http_only
    AND token_ttl_seconds>0 AND read_only_session_ttl_seconds>0
    AND ops.r6d_lower_sha256(policy_digest)
    AND ops.r6d_lower_sha256(binding_digest)
    AND isfinite(effective_at) AND isfinite(review_expires_at)
    AND review_expires_at>effective_at
    AND convert_from(policy_canonical,'UTF8')::jsonb=policy_payload
    AND policy_digest=encode(extensions.digest(policy_canonical,'sha256'),'hex')
    AND policy_payload=jsonb_build_object(
      'schemaVersion','privacy-request-receipt-access-policy-v1',
      'tokenTtlSeconds',token_ttl_seconds,
      'readOnlySessionTtlSeconds',read_only_session_ttl_seconds,
      'cookieProfileId',cookie_profile_id,'cookieName',cookie_name,
      'cookiePath',cookie_path,
      'allowedOperations',jsonb_build_array(allowed_operation)
    )
    AND binding_digest=encode(extensions.digest(ops.canonical_jsonb_v1(
      jsonb_build_object(
        'schemaVersion','privacy-access-policy-binding.v1',
        'policyId',policy_id,'revision',revision,
        'state',state,'authority',authority,'policyVersion',policy_version,
        'policyDigest',btrim(policy_digest),
        'bffIssuer',bff_issuer,'sameSite',same_site,
        'secure',secure,'httpOnly',http_only,
        'effectiveAt',effective_at,'reviewExpiresAt',review_expires_at
      )
    ),'sha256'),'hex')
  )
);
ALTER TABLE ops.privacy_request_access_policies_v1 OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_request_access_policies_v1 FROM PUBLIC;
REVOKE ALL ON ops.privacy_request_access_policies_v1
  FROM gurine_submission_api,gurine_control_api,gurine_workflow_worker,
       gurine_notification_worker,gurine_scheduler,gurine_public_api;
GRANT SELECT ON ops.privacy_request_access_policies_v1 TO gurine_auditor;
CREATE TRIGGER privacy_request_access_policies_v1_immutable_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_request_access_policies_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

ALTER TABLE ops.privacy_request_receipt_tokens_v2
  ADD COLUMN access_policy_id uuid NOT NULL,
  ADD COLUMN access_policy_revision bigint NOT NULL,
  ADD COLUMN access_policy_digest char(64) NOT NULL,
  ADD COLUMN access_policy_binding_digest char(64) NOT NULL,
  ADD COLUMN exchange_audit_event_id uuid UNIQUE
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  ADD COLUMN exchange_outbox_event_id uuid UNIQUE
    REFERENCES ops.outbox(id) ON DELETE RESTRICT,
  ADD CONSTRAINT privacy_request_receipt_tokens_v2_access_policy_fk
    FOREIGN KEY(
      access_policy_id,access_policy_revision,access_policy_digest,
      access_policy_binding_digest
    )
    REFERENCES ops.privacy_request_access_policies_v1(
      policy_id,revision,policy_digest,binding_digest
    ) ON DELETE RESTRICT,
  ADD CONSTRAINT privacy_request_receipt_tokens_v2_access_policy_digest_ck
    CHECK(
      access_policy_revision>0
      AND ops.r6d_lower_sha256(access_policy_digest)
      AND ops.r6d_lower_sha256(access_policy_binding_digest)
    ),
  ADD CONSTRAINT privacy_request_receipt_tokens_v2_exchange_closure_ck CHECK(
    consumed_at IS NULL
      AND num_nonnulls(exchange_audit_event_id,exchange_outbox_event_id)=0
    OR consumed_at IS NOT NULL
      AND num_nonnulls(exchange_audit_event_id,exchange_outbox_event_id)=2
  );

ALTER TABLE intake.submission_sessions
  ADD COLUMN privacy_access_policy_id uuid,
  ADD COLUMN privacy_access_policy_revision bigint,
  ADD COLUMN privacy_access_policy_digest char(64),
  ADD COLUMN privacy_access_policy_binding_digest char(64),
  ADD CONSTRAINT submission_sessions_privacy_access_policy_fk FOREIGN KEY(
    privacy_access_policy_id,privacy_access_policy_revision,
    privacy_access_policy_digest,privacy_access_policy_binding_digest
  ) REFERENCES ops.privacy_request_access_policies_v1(
    policy_id,revision,policy_digest,binding_digest
  ) MATCH FULL ON DELETE RESTRICT,
  ADD CONSTRAINT submission_sessions_privacy_access_policy_shape_ck CHECK(
    (session_kind='PRIVACY_REQUEST_RECEIPT'
      AND num_nonnulls(
        privacy_access_policy_id,privacy_access_policy_revision,
        privacy_access_policy_digest,privacy_access_policy_binding_digest
      )=4
      AND privacy_access_policy_revision>0
      AND ops.r6d_lower_sha256(privacy_access_policy_digest)
      AND ops.r6d_lower_sha256(privacy_access_policy_binding_digest))
    OR (session_kind<>'PRIVACY_REQUEST_RECEIPT'
      AND num_nonnulls(
        privacy_access_policy_id,privacy_access_policy_revision,
        privacy_access_policy_digest,privacy_access_policy_binding_digest
      )=0)
  );
-- SECURITY DEFINER privacy owners reuse the migrator-owned session boundary
-- established for response submission. Service roles retain zero base-table
-- DML and reach it only through the owner routines.

CREATE OR REPLACE FUNCTION ops.current_privacy_request_access_policy_v1(
  p_now timestamptz
) RETURNS ops.privacy_request_access_policies_v1
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $policy$
DECLARE
  v_policies ops.privacy_request_access_policies_v1[];
  v_policy_count integer;
BEGIN
  IF p_now IS NULL OR NOT isfinite(p_now) THEN
    RAISE EXCEPTION 'privacy_access_policy_time_invalid' USING ERRCODE='22023';
  END IF;

  -- Commands invoke this under their required SERIALIZABLE transaction. A
  -- query sees one statement snapshot; the append-only relation never mutates.
  SELECT array_agg(policy ORDER BY policy.effective_at,policy.policy_id,
      policy.revision)
  INTO v_policies
  FROM ops.privacy_request_access_policies_v1 AS policy
  WHERE policy.state='APPROVED'
    AND (
      policy.authority<>'TEST_ONLY'
      OR pg_has_role(session_user,'gurine_migrator','MEMBER')
    )
    AND policy.allowed_operation='getPrivacyRequest'
    AND policy.bff_issuer='public-web'
    AND policy.cookie_profile_id='privacy_request_receipt'
    AND policy.cookie_name='gurine_privacy_request_receipt_session'
    AND policy.cookie_path='/privacy'
    AND policy.secure AND policy.http_only
    AND policy.effective_at<=p_now AND p_now<policy.review_expires_at;

  v_policy_count:=COALESCE(cardinality(v_policies),0);
  IF v_policy_count=0 THEN
    RAISE EXCEPTION 'privacy_access_policy_missing' USING ERRCODE='23514';
  ELSIF v_policy_count<>1 THEN
    RAISE EXCEPTION 'privacy_access_policy_ambiguous' USING ERRCODE='23514';
  END IF;
  RETURN v_policies[1];
END
$policy$;
ALTER FUNCTION ops.current_privacy_request_access_policy_v1(timestamptz)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.current_privacy_request_access_policy_v1(timestamptz)
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.preflight_privacy_request_access_policy_v1(
  p_at timestamptz
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $preflight$
DECLARE
  v_policy ops.privacy_request_access_policies_v1%ROWTYPE;
BEGIN
  v_policy:=ops.current_privacy_request_access_policy_v1(p_at);
  IF v_policy.authority='TEST_ONLY' THEN
    RAISE EXCEPTION 'privacy_access_policy_test_only_forbidden'
      USING ERRCODE='55000';
  END IF;
  RETURN jsonb_build_object(
    'policyId',v_policy.policy_id,'revision',v_policy.revision,
    'authority',v_policy.authority,
    'policyVersion',v_policy.policy_version,
    'policyDigest',btrim(v_policy.policy_digest),
    'bindingDigest',btrim(v_policy.binding_digest),
    'effectiveAt',v_policy.effective_at,
    'reviewExpiresAt',v_policy.review_expires_at
  );
END
$preflight$;
ALTER FUNCTION ops.preflight_privacy_request_access_policy_v1(timestamptz)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.preflight_privacy_request_access_policy_v1(timestamptz)
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.r6d_field_envelope_v1_is_valid(
  p_ciphertext bytea,p_encryption_key_id text
) RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path=pg_catalog,pg_temp
AS $envelope$
DECLARE
  v_envelope text;
BEGIN
  IF octet_length(p_ciphertext)<1
     OR length(p_encryption_key_id) NOT BETWEEN 1 AND 200
     OR btrim(p_encryption_key_id)<>p_encryption_key_id THEN
    RETURN false;
  END IF;
  v_envelope:=convert_from(p_ciphertext,'UTF8');
  RETURN v_envelope~
    '^gurine-fe-v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'
    AND split_part(v_envelope,'.',2)=p_encryption_key_id;
EXCEPTION WHEN character_not_in_repertoire OR untranslatable_character THEN
  RETURN false;
END
$envelope$;
ALTER FUNCTION ops.r6d_field_envelope_v1_is_valid(bytea,text)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_field_envelope_v1_is_valid(bytea,text)
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.r6d_nul5_sha256_v1(
  p_one text,p_two text,p_three text,p_four text,p_five text
) RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path=pg_catalog,extensions,pg_temp
AS $digest$
  SELECT encode(extensions.digest(
    convert_to(p_one,'UTF8')||decode('00','hex')||
    convert_to(p_two,'UTF8')||decode('00','hex')||
    convert_to(p_three,'UTF8')||decode('00','hex')||
    convert_to(p_four,'UTF8')||decode('00','hex')||
    convert_to(p_five,'UTF8'),'sha256'
  ),'hex')::char(64)
$digest$;
ALTER FUNCTION ops.r6d_nul5_sha256_v1(text,text,text,text,text)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.r6d_nul5_sha256_v1(text,text,text,text,text)
  FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.guard_privacy_requests_v2_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $guard$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'privacy_request_delete_forbidden' USING ERRCODE='55000';
  END IF;
  IF current_user<>'gurine_migrator'
     OR current_setting('gurine.privacy_request_transition_v2',true)<>'1'
     OR ROW(
       NEW.id,NEW.request_type,NEW.jurisdiction,NEW.subject_proof_hash,
       NEW.identity_proof_kind,NEW.identity_proof_ref_id,
       NEW.identity_proof_binding_digest,NEW.subject_scope_digest,
       NEW.scope_ciphertext,NEW.scope_sha256,NEW.scope_aad_digest,
       NEW.statement_ciphertext,NEW.statement_sha256,NEW.statement_aad_digest,
       NEW.encryption_key_id,NEW.communication_subject_id,
       NEW.communication_subject_origin_digest,NEW.communication_endpoint_id,
       NEW.communication_endpoint_version,NEW.communication_endpoint_digest,
       NEW.create_request_id,NEW.create_idempotency_key_sha256,
       NEW.create_request_sha256,NEW.create_audit_event_id,
       NEW.create_outbox_event_id,NEW.create_receipt_digest,
       NEW.retention_schedule_id,NEW.retention_record_class,
       NEW.retention_schedule_digest,NEW.created_at
     ) IS DISTINCT FROM ROW(
       OLD.id,OLD.request_type,OLD.jurisdiction,OLD.subject_proof_hash,
       OLD.identity_proof_kind,OLD.identity_proof_ref_id,
       OLD.identity_proof_binding_digest,OLD.subject_scope_digest,
       OLD.scope_ciphertext,OLD.scope_sha256,OLD.scope_aad_digest,
       OLD.statement_ciphertext,OLD.statement_sha256,OLD.statement_aad_digest,
       OLD.encryption_key_id,OLD.communication_subject_id,
       OLD.communication_subject_origin_digest,OLD.communication_endpoint_id,
       OLD.communication_endpoint_version,OLD.communication_endpoint_digest,
       OLD.create_request_id,OLD.create_idempotency_key_sha256,
       OLD.create_request_sha256,OLD.create_audit_event_id,
       OLD.create_outbox_event_id,OLD.create_receipt_digest,
       OLD.retention_schedule_id,OLD.retention_record_class,
       OLD.retention_schedule_digest,OLD.created_at
     )
     OR NEW.decision_version<>OLD.decision_version+1
     OR NEW.updated_at<OLD.updated_at THEN
    RAISE EXCEPTION 'privacy_request_direct_mutation_forbidden'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$guard$;
ALTER FUNCTION ops.guard_privacy_requests_v2_mutation() OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.guard_privacy_requests_v2_mutation() FROM PUBLIC;
CREATE TRIGGER privacy_requests_v2_owner_mutation_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_requests_v2
  FOR EACH ROW EXECUTE FUNCTION ops.guard_privacy_requests_v2_mutation();

CREATE OR REPLACE FUNCTION ops.guard_privacy_receipt_token_v2_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $guard$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'privacy_receipt_token_delete_forbidden' USING ERRCODE='55000';
  END IF;
  IF current_user<>'gurine_migrator'
     OR current_setting('gurine.privacy_receipt_token_consume_v2',true)<>'1'
     OR OLD.consumed_at IS NOT NULL
     OR OLD.session_id IS NOT NULL
     OR OLD.session_token_sha256 IS NOT NULL
     OR OLD.exchange_receipt_digest IS NOT NULL
     OR OLD.exchange_audit_event_id IS NOT NULL
     OR OLD.exchange_outbox_event_id IS NOT NULL
     OR NEW.consumed_at IS NULL
     OR NEW.session_id IS NULL
     OR NEW.session_token_sha256 IS NULL
     OR NEW.exchange_receipt_digest IS NULL
     OR NEW.exchange_audit_event_id IS NULL
     OR NEW.exchange_outbox_event_id IS NULL
     OR ROW(
       NEW.token_id,NEW.privacy_request_id,NEW.operation_id,
       NEW.idempotency_key_sha256,NEW.request_sha256,NEW.token_hmac,
       NEW.token_sha256,NEW.token_key_version,NEW.secretless_response_template,
       NEW.secretless_response_digest,NEW.expires_at,
       NEW.access_policy_id,NEW.access_policy_revision,
       NEW.access_policy_digest,NEW.access_policy_binding_digest,
       NEW.retention_schedule_id,NEW.retention_record_class,
       NEW.retention_schedule_digest,NEW.created_at
     ) IS DISTINCT FROM ROW(
       OLD.token_id,OLD.privacy_request_id,OLD.operation_id,
       OLD.idempotency_key_sha256,OLD.request_sha256,OLD.token_hmac,
       OLD.token_sha256,OLD.token_key_version,OLD.secretless_response_template,
       OLD.secretless_response_digest,OLD.expires_at,
       OLD.access_policy_id,OLD.access_policy_revision,
       OLD.access_policy_digest,OLD.access_policy_binding_digest,
       OLD.retention_schedule_id,OLD.retention_record_class,
       OLD.retention_schedule_digest,OLD.created_at
     ) THEN
    RAISE EXCEPTION 'privacy_receipt_token_direct_mutation_forbidden'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$guard$;
ALTER FUNCTION ops.guard_privacy_receipt_token_v2_mutation()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.guard_privacy_receipt_token_v2_mutation()
  FROM PUBLIC;
CREATE TRIGGER privacy_request_receipt_tokens_v2_owner_mutation_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_request_receipt_tokens_v2
  FOR EACH ROW EXECUTE FUNCTION ops.guard_privacy_receipt_token_v2_mutation();

CREATE OR REPLACE FUNCTION ops.create_privacy_request_v2(
  p_payload jsonb,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_sha256 char(64)
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,extensions,pg_temp
AS $create$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_key_count integer;
  v_claimed integer;
  v_existing ops.idempotency_keys%ROWTYPE;
  v_privacy_request_id uuid;
  v_request_type text;
  v_jurisdiction text;
  v_identity_proof jsonb;
  v_subject_proof_hash char(64);
  v_identity_proof_kind text;
  v_identity_proof_ref_id uuid;
  v_identity_proof_binding_digest char(64);
  v_scope jsonb;
  v_scope_kind text;
  v_scope_object_refs jsonb;
  v_scope_object_ref_count integer;
  v_scope_date_from date;
  v_scope_date_to date;
  v_scope_canonical bytea;
  v_subject_scope_canonical bytea;
  v_subject_scope_digest char(64);
  v_scope_ciphertext bytea;
  v_scope_sha256 char(64);
  v_scope_aad_digest char(64);
  v_statement_ciphertext bytea;
  v_statement_sha256 char(64);
  v_statement_aad_digest char(64);
  v_encryption_key_id text;
  v_subject_id uuid;
  v_subject_hmac_key_version text;
  v_locale text;
  v_endpoint_id uuid;
  v_endpoint_channel text;
  v_endpoint_hmac char(64);
  v_endpoint_hmac_key_version text;
  v_endpoint_ciphertext bytea;
  v_endpoint_encryption_key_id text;
  v_endpoint_aad_digest char(64);
  v_voice_consent_receipt_id uuid;
  v_token_hmac char(64);
  v_token_sha256 char(64);
  v_token_key_version text;
  v_token_expires_at timestamptz;
  v_access_policy ops.privacy_request_access_policies_v1%ROWTYPE;
  v_origin_payload jsonb;
  v_origin_digest char(64);
  v_profile_payload jsonb;
  v_profile_digest char(64);
  v_endpoint_payload jsonb;
  v_endpoint_digest char(64);
  v_request_receipt_payload jsonb;
  v_request_receipt_digest char(64);
  v_command_receipt_payload jsonb;
  v_command_receipt_digest char(64);
  v_event_payload jsonb;
  v_audit_id uuid;
  v_outbox_id uuid;
  v_result jsonb;
BEGIN
  IF p_request_id IS NULL
     OR p_request_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_idempotency_key_sha256 IS NULL
     OR NOT ops.r6d_lower_sha256(p_idempotency_key_sha256)
     OR p_request_sha256 IS NULL
     OR NOT ops.r6d_lower_sha256(p_request_sha256) THEN
    RAISE EXCEPTION 'privacy_request_create_input_invalid' USING ERRCODE='22023';
  END IF;

  -- The dependency gate precedes every idempotency claim. Missing, ambiguous,
  -- expired or malformed authority must leave no durable write behind.
  v_access_policy:=ops.current_privacy_request_access_policy_v1(v_now);
  BEGIN
    v_token_expires_at:=LEAST(
      v_access_policy.review_expires_at,
      v_now+make_interval(secs=>v_access_policy.token_ttl_seconds::double precision)
    );
  EXCEPTION WHEN datetime_field_overflow OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'privacy_access_policy_ttl_invalid' USING ERRCODE='23514';
  END;
  IF NOT isfinite(v_token_expires_at) OR v_token_expires_at<=v_now THEN
    RAISE EXCEPTION 'privacy_access_policy_ttl_invalid' USING ERRCODE='23514';
  END IF;

  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
  VALUES(
    'PRIVACY_REQUEST_CREATE_V2',p_idempotency_key_sha256,
    p_request_sha256,v_now+interval '24 hours'
  ) ON CONFLICT(scope,key_hash) DO NOTHING;
  GET DIAGNOSTICS v_claimed=ROW_COUNT;
  SELECT * INTO STRICT v_existing FROM ops.idempotency_keys
  WHERE scope='PRIVACY_REQUEST_CREATE_V2'
    AND key_hash=p_idempotency_key_sha256 FOR UPDATE;
  IF v_existing.request_hash IS DISTINCT FROM p_request_sha256 THEN
    RAISE EXCEPTION 'privacy_request_create_idempotency_conflict'
      USING ERRCODE='PVT05';
  END IF;
  IF v_existing.response_body IS NOT NULL THEN
    IF v_existing.response_status<>201
       OR v_existing.resource_type<>'PrivacyRequest'
       OR NOT EXISTS(
         SELECT 1 FROM ops.privacy_requests_v2 AS request
         JOIN ops.privacy_request_receipt_tokens_v2 AS token
           ON token.privacy_request_id=request.id
         WHERE request.id=v_existing.resource_id::uuid
           AND request.create_idempotency_key_sha256=p_idempotency_key_sha256
           AND request.create_request_sha256=p_request_sha256
           AND token.idempotency_key_sha256=p_idempotency_key_sha256
           AND token.request_sha256=p_request_sha256
           AND token.secretless_response_template=v_existing.response_body
           AND ROW(
             token.access_policy_id,token.access_policy_revision,
             token.access_policy_digest,token.access_policy_binding_digest
           )=ROW(
             v_access_policy.policy_id,v_access_policy.revision,
             v_access_policy.policy_digest,v_access_policy.binding_digest
           )
       ) THEN
      RAISE EXCEPTION 'privacy_request_create_replay_closure_invalid'
        USING ERRCODE='23514';
    END IF;
    RETURN v_existing.response_body||jsonb_build_object('replayed',true);
  ELSIF v_claimed=0 THEN
    RAISE EXCEPTION 'privacy_request_create_claim_incomplete'
      USING ERRCODE='55000';
  END IF;

  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
    RAISE EXCEPTION 'privacy_request_create_input_invalid' USING ERRCODE='22023';
  END IF;
  SELECT count(*) INTO v_key_count FROM jsonb_object_keys(p_payload);
  IF v_key_count<>25
     OR NOT p_payload ?& ARRAY[
       'privacyRequestId','requestType','jurisdiction','identityProof','scope',
       'scopeCiphertextBase64','scopeAadDigest',
       'statementCiphertextBase64','statementSha256',
       'statementAadDigest','encryptionKeyId','communicationSubjectId',
       'communicationSubjectHmacKeyVersion','communicationSubjectLocale',
       'communicationEndpointId','communicationEndpointChannel',
       'communicationEndpointHmac','communicationEndpointHmacKeyVersion',
       'communicationEndpointCiphertextBase64',
       'communicationEndpointEncryptionKeyId','communicationEndpointAadDigest',
       'explicitVoiceConsentReceiptId','receiptTokenHmac','receiptTokenSha256',
       'receiptTokenKeyVersion'
     ]
     OR jsonb_typeof(p_payload->'identityProof')<>'object'
     OR jsonb_typeof(p_payload->'scope')<>'object'
     OR EXISTS(
       SELECT 1 FROM jsonb_each(p_payload) AS field(key,value)
       WHERE field.key=ANY(ARRAY[
         'privacyRequestId','requestType','jurisdiction',
         'scopeCiphertextBase64','scopeAadDigest',
         'statementCiphertextBase64','statementSha256','statementAadDigest',
         'encryptionKeyId','communicationSubjectId',
         'communicationSubjectHmacKeyVersion','communicationSubjectLocale',
         'communicationEndpointId','communicationEndpointChannel',
         'communicationEndpointHmac','communicationEndpointHmacKeyVersion',
         'communicationEndpointCiphertextBase64',
         'communicationEndpointEncryptionKeyId','communicationEndpointAadDigest',
         'receiptTokenHmac','receiptTokenSha256','receiptTokenKeyVersion'
       ]) AND jsonb_typeof(field.value)<>'string'
     )
     OR NOT (
       p_payload->'explicitVoiceConsentReceiptId'='null'::jsonb
       OR jsonb_typeof(p_payload->'explicitVoiceConsentReceiptId')='string'
     )
     OR EXISTS(
       SELECT 1 FROM jsonb_each(p_payload) AS field(key,value)
       WHERE field.value='null'::jsonb
         AND field.key<>'explicitVoiceConsentReceiptId'
     )
     THEN
    RAISE EXCEPTION 'privacy_request_create_input_invalid' USING ERRCODE='22023';
  END IF;

  BEGIN
    v_privacy_request_id:=(p_payload->>'privacyRequestId')::uuid;
    v_request_type:=p_payload->>'requestType';
    v_jurisdiction:=p_payload->>'jurisdiction';
    v_identity_proof:=p_payload->'identityProof';
    v_scope:=p_payload->'scope';
    v_scope_ciphertext:=decode(p_payload->>'scopeCiphertextBase64','base64');
    v_scope_aad_digest:=(p_payload->>'scopeAadDigest')::char(64);
    v_statement_ciphertext:=decode(
      p_payload->>'statementCiphertextBase64','base64'
    );
    v_statement_sha256:=(p_payload->>'statementSha256')::char(64);
    v_statement_aad_digest:=(p_payload->>'statementAadDigest')::char(64);
    v_encryption_key_id:=p_payload->>'encryptionKeyId';
    v_subject_id:=(p_payload->>'communicationSubjectId')::uuid;
    v_subject_hmac_key_version:=p_payload->>'communicationSubjectHmacKeyVersion';
    v_locale:=p_payload->>'communicationSubjectLocale';
    v_endpoint_id:=(p_payload->>'communicationEndpointId')::uuid;
    v_endpoint_channel:=p_payload->>'communicationEndpointChannel';
    v_endpoint_hmac:=(p_payload->>'communicationEndpointHmac')::char(64);
    v_endpoint_hmac_key_version:=p_payload->>'communicationEndpointHmacKeyVersion';
    v_endpoint_ciphertext:=decode(
      p_payload->>'communicationEndpointCiphertextBase64','base64'
    );
    v_endpoint_encryption_key_id:=
      p_payload->>'communicationEndpointEncryptionKeyId';
    v_endpoint_aad_digest:=
      (p_payload->>'communicationEndpointAadDigest')::char(64);
    IF p_payload->'explicitVoiceConsentReceiptId'<>'null'::jsonb THEN
      IF jsonb_typeof(p_payload->'explicitVoiceConsentReceiptId')<>'string' THEN
        RAISE EXCEPTION 'privacy_request_create_input_invalid'
          USING ERRCODE='22023';
      END IF;
      v_voice_consent_receipt_id:=
        (p_payload->>'explicitVoiceConsentReceiptId')::uuid;
    END IF;
    v_token_hmac:=(p_payload->>'receiptTokenHmac')::char(64);
    v_token_sha256:=(p_payload->>'receiptTokenSha256')::char(64);
    v_token_key_version:=p_payload->>'receiptTokenKeyVersion';
  EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value
    OR datetime_field_overflow OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'privacy_request_create_input_invalid' USING ERRCODE='22023';
  END;

  IF jsonb_typeof(v_identity_proof)<>'object'
     OR jsonb_typeof(v_identity_proof->'kind')<>'string' THEN
    RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
      USING ERRCODE='PVT06';
  END IF;
  v_identity_proof_kind:=v_identity_proof->>'kind';
  BEGIN
    CASE v_identity_proof_kind
      WHEN 'RESPONSE_RECEIPT' THEN
        IF (SELECT count(*) FROM jsonb_object_keys(v_identity_proof))<>3
           OR NOT v_identity_proof ?& ARRAY[
             'kind','receiptId','possessionTokenHmac'
           ]
           OR EXISTS(
             SELECT 1 FROM jsonb_each(v_identity_proof) AS field(key,value)
             WHERE field.value='null'::jsonb
           )
           OR NOT ops.r6d_lower_sha256(
             v_identity_proof->>'possessionTokenHmac'
           ) THEN
          RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
            USING ERRCODE='PVT06';
        END IF;
        v_identity_proof_ref_id:=(v_identity_proof->>'receiptId')::uuid;
      WHEN 'VERIFIED_ENDPOINT' THEN
        IF (SELECT count(*) FROM jsonb_object_keys(v_identity_proof))<>5
           OR NOT v_identity_proof ?& ARRAY[
             'kind','challengeId','proofKind','proofVerifierHmac','provider'
           ]
           OR EXISTS(
             SELECT 1 FROM jsonb_each(v_identity_proof) AS field(key,value)
             WHERE field.value='null'::jsonb AND field.key<>'provider'
           )
           OR NOT ops.r6d_lower_sha256(
             v_identity_proof->>'proofVerifierHmac'
           )
           OR NOT (
             v_identity_proof->>'proofKind' IN ('EMAIL_LINK','SMS_OTP')
             AND v_identity_proof->'provider'='null'::jsonb
             OR v_identity_proof->>'proofKind'='PROVIDER_SIGNED_BINDING'
             AND v_identity_proof->>'provider' IN (
               'TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD',
               'LINE_MESSAGING_API','SOLAPI_KAKAO_BIZMESSAGE','TWILIO_VOICE'
             )
           ) THEN
          RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
            USING ERRCODE='PVT06';
        END IF;
        v_identity_proof_ref_id:=(v_identity_proof->>'challengeId')::uuid;
      WHEN 'IDENTITY_DOCUMENT_CHALLENGE' THEN
        IF (SELECT count(*) FROM jsonb_object_keys(v_identity_proof))<>4
           OR NOT v_identity_proof ?& ARRAY[
             'kind','challengeId','verificationReceiptId',
             'verificationReceiptDigest'
           ]
           OR EXISTS(
             SELECT 1 FROM jsonb_each(v_identity_proof) AS field(key,value)
             WHERE field.value='null'::jsonb
           )
           OR NOT ops.r6d_lower_sha256(
             v_identity_proof->>'verificationReceiptDigest'
           )
           OR (v_identity_proof->>'verificationReceiptId')::uuid=
             '00000000-0000-0000-0000-000000000000'::uuid THEN
          RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
            USING ERRCODE='PVT06';
        END IF;
        v_identity_proof_ref_id:=(v_identity_proof->>'challengeId')::uuid;
      ELSE
        RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
          USING ERRCODE='PVT06';
    END CASE;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
      USING ERRCODE='PVT06';
  END;
  IF v_identity_proof_ref_id='00000000-0000-0000-0000-000000000000'::uuid THEN
    RAISE EXCEPTION 'privacy_request_identity_proof_invalid'
      USING ERRCODE='PVT06';
  END IF;
  v_identity_proof_binding_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_identity_proof),'sha256'
  ),'hex');
  v_subject_proof_hash:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','privacy-subject-proof.v1',
      'identityProofKind',v_identity_proof_kind,
      'identityProofRefId',v_identity_proof_ref_id,
      'identityProofBindingDigest',btrim(v_identity_proof_binding_digest)
    )),'sha256'
  ),'hex');

  -- The request scope is validation-only plaintext. Rebuild the exact closed
  -- value (including sorted object refs), then derive both stored digests.
  IF jsonb_typeof(v_scope)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(v_scope))<>6
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
            'RESPONSE','CORRECTION','SUBSCRIPTION','COMMUNICATION_ENDPOINT',
            'PUBLICATION','EVIDENCE','AUDIT_SUBJECT_RECORD'
          )
     ) THEN
    RAISE EXCEPTION 'privacy_request_scope_invalid' USING ERRCODE='PVT07';
  END IF;
  v_scope_kind:=v_scope->>'scopeKind';
  BEGIN
    IF v_scope->'dateFrom'<>'null'::jsonb THEN
      IF jsonb_typeof(v_scope->'dateFrom')<>'string'
         OR v_scope->>'dateFrom' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        RAISE EXCEPTION 'privacy_request_scope_invalid' USING ERRCODE='PVT07';
      END IF;
      v_scope_date_from:=(v_scope->>'dateFrom')::date;
      IF to_char(v_scope_date_from,'YYYY-MM-DD')<>v_scope->>'dateFrom' THEN
        RAISE EXCEPTION 'privacy_request_scope_invalid' USING ERRCODE='PVT07';
      END IF;
    END IF;
    IF v_scope->'dateTo'<>'null'::jsonb THEN
      IF jsonb_typeof(v_scope->'dateTo')<>'string'
         OR v_scope->>'dateTo' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        RAISE EXCEPTION 'privacy_request_scope_invalid' USING ERRCODE='PVT07';
      END IF;
      v_scope_date_to:=(v_scope->>'dateTo')::date;
      IF to_char(v_scope_date_to,'YYYY-MM-DD')<>v_scope->>'dateTo' THEN
        RAISE EXCEPTION 'privacy_request_scope_invalid' USING ERRCODE='PVT07';
      END IF;
    END IF;
    SELECT count(*)::integer,
      COALESCE(jsonb_agg(jsonb_build_object(
        'objectType',parsed.object_type,'objectId',parsed.object_id
      ) ORDER BY parsed.object_type,parsed.object_id),'[]'::jsonb)
    INTO v_scope_object_ref_count,v_scope_object_refs
    FROM (
      SELECT ref.value->>'objectType' AS object_type,
        (ref.value->>'objectId')::uuid AS object_id
      FROM jsonb_array_elements(v_scope->'objectRefs') AS ref(value)
    ) AS parsed;
  EXCEPTION WHEN invalid_text_representation OR datetime_field_overflow THEN
    RAISE EXCEPTION 'privacy_request_scope_invalid' USING ERRCODE='PVT07';
  END;
  IF EXISTS(
       SELECT 1 FROM jsonb_array_elements(v_scope_object_refs) AS ref(value)
       WHERE (ref.value->>'objectId')::uuid=
         '00000000-0000-0000-0000-000000000000'::uuid
     )
     OR (SELECT count(*) FROM (
       SELECT ref.value->>'objectType',ref.value->>'objectId'
       FROM jsonb_array_elements(v_scope_object_refs) AS ref(value)
       GROUP BY ref.value->>'objectType',ref.value->>'objectId'
     ) AS unique_ref)<>v_scope_object_ref_count
     OR NOT (
       v_scope_kind='ALL_VERIFIED_SUBJECT_DATA'
       AND v_scope_object_ref_count=0
       AND v_scope_date_from IS NULL AND v_scope_date_to IS NULL
       OR v_scope_kind='OBJECT_SET'
       AND v_scope_object_ref_count BETWEEN 1 AND 1000
       AND v_scope_date_from IS NULL AND v_scope_date_to IS NULL
       OR v_scope_kind='DATE_RANGE'
       AND v_scope_object_ref_count=0
       AND v_scope_date_from IS NOT NULL AND v_scope_date_to IS NOT NULL
       AND v_scope_date_from<=v_scope_date_to
     ) THEN
    RAISE EXCEPTION 'privacy_request_scope_invalid' USING ERRCODE='PVT07';
  END IF;
  v_scope_canonical:=ops.canonical_jsonb_v1(jsonb_build_object(
    'scopeKind',v_scope_kind,'objectRefs',v_scope_object_refs,
    'dateFrom',CASE WHEN v_scope_date_from IS NULL THEN 'null'::jsonb
      ELSE to_jsonb(to_char(v_scope_date_from,'YYYY-MM-DD')) END,
    'dateTo',CASE WHEN v_scope_date_to IS NULL THEN 'null'::jsonb
      ELSE to_jsonb(to_char(v_scope_date_to,'YYYY-MM-DD')) END,
    'includeDerivatives',v_scope->'includeDerivatives',
    'includeBackups',v_scope->'includeBackups'
  ));
  v_scope_sha256:=encode(extensions.digest(v_scope_canonical,'sha256'),'hex');
  v_subject_scope_canonical:=ops.canonical_jsonb_v1(jsonb_build_object(
    'schemaVersion','privacy-subject-scope-v1',
    'subjectProofHash',btrim(v_subject_proof_hash),
    'scopeSha256',btrim(v_scope_sha256)
  ));
  v_subject_scope_digest:=encode(
    extensions.digest(v_subject_scope_canonical,'sha256'),'hex'
  );

  IF v_privacy_request_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_subject_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_endpoint_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_voice_consent_receipt_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_request_type NOT IN ('ACCESS','CORRECTION','DELETION','RESTRICTION')
     OR length(v_jurisdiction) NOT BETWEEN 2 AND 64
     OR btrim(v_jurisdiction)<>v_jurisdiction
     OR length(v_locale) NOT BETWEEN 2 AND 35 OR btrim(v_locale)<>v_locale
     OR length(v_encryption_key_id) NOT BETWEEN 1 AND 200
     OR btrim(v_encryption_key_id)<>v_encryption_key_id
     OR length(v_subject_hmac_key_version) NOT BETWEEN 1 AND 100
     OR length(v_endpoint_hmac_key_version) NOT BETWEEN 1 AND 100
     OR length(v_endpoint_encryption_key_id) NOT BETWEEN 1 AND 200
     OR length(v_token_key_version) NOT BETWEEN 1 AND 100
     OR v_endpoint_channel NOT IN (
       'SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD',
       'LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE','TWILIO_VOICE'
     )
     OR octet_length(v_scope_ciphertext) NOT BETWEEN 1 AND 131072
     OR octet_length(v_statement_ciphertext) NOT BETWEEN 1 AND 65536
     OR octet_length(v_endpoint_ciphertext) NOT BETWEEN 1 AND 16384
     OR p_payload->>'scopeCiphertextBase64' !~ '^[A-Za-z0-9+/]+={0,2}$'
     OR length(p_payload->>'scopeCiphertextBase64')%4<>0
     OR replace(encode(v_scope_ciphertext,'base64'),E'\n','')
          IS DISTINCT FROM p_payload->>'scopeCiphertextBase64'
     OR p_payload->>'statementCiphertextBase64' !~ '^[A-Za-z0-9+/]+={0,2}$'
     OR length(p_payload->>'statementCiphertextBase64')%4<>0
     OR replace(encode(v_statement_ciphertext,'base64'),E'\n','')
          IS DISTINCT FROM p_payload->>'statementCiphertextBase64'
     OR p_payload->>'communicationEndpointCiphertextBase64'
          !~ '^[A-Za-z0-9+/]+={0,2}$'
     OR length(p_payload->>'communicationEndpointCiphertextBase64')%4<>0
     OR replace(encode(v_endpoint_ciphertext,'base64'),E'\n','')
          IS DISTINCT FROM p_payload->>'communicationEndpointCiphertextBase64'
     OR NOT ops.r6d_field_envelope_v1_is_valid(
       v_scope_ciphertext,v_encryption_key_id
     )
     OR NOT ops.r6d_field_envelope_v1_is_valid(
       v_statement_ciphertext,v_encryption_key_id
     )
     OR NOT ops.r6d_field_envelope_v1_is_valid(
       v_endpoint_ciphertext,v_endpoint_encryption_key_id
     )
     OR NOT ops.r6d_lower_sha256(v_subject_proof_hash)
     OR NOT ops.r6d_lower_sha256(v_identity_proof_binding_digest)
     OR NOT ops.r6d_lower_sha256(v_subject_scope_digest)
     OR NOT ops.r6d_lower_sha256(v_scope_sha256)
     OR NOT ops.r6d_lower_sha256(v_scope_aad_digest)
     OR NOT ops.r6d_lower_sha256(v_statement_sha256)
     OR NOT ops.r6d_lower_sha256(v_statement_aad_digest)
     OR NOT ops.r6d_lower_sha256(v_endpoint_hmac)
     OR NOT ops.r6d_lower_sha256(v_endpoint_aad_digest)
     OR NOT ops.r6d_lower_sha256(v_token_hmac)
     OR NOT ops.r6d_lower_sha256(v_token_sha256)
     OR v_scope_aad_digest<>ops.r6d_nul5_sha256_v1(
       'ops.privacy_requests_v2','scope_ciphertext',v_privacy_request_id::text,
       'privacy-request-scope','1')
     OR v_statement_aad_digest<>ops.r6d_nul5_sha256_v1(
       'ops.privacy_requests_v2','statement_ciphertext',
       v_privacy_request_id::text,'privacy-request-statement','1')
     OR v_endpoint_aad_digest<>ops.r6d_nul5_sha256_v1(
       'intake.communication_endpoints','endpoint_ciphertext',
       v_endpoint_id::text,CASE v_endpoint_channel
         WHEN 'SMTP_EMAIL' THEN 'email-address'
         WHEN 'TELEGRAM_BOT_API' THEN 'provider-identifier'
         WHEN 'LINE_MESSAGING_API' THEN 'provider-identifier'
         ELSE 'phone-number' END,'1')
     OR (v_endpoint_channel='TWILIO_VOICE')
        IS DISTINCT FROM (v_voice_consent_receipt_id IS NOT NULL) THEN
    RAISE EXCEPTION 'privacy_request_create_input_invalid' USING ERRCODE='22023';
  END IF;
  IF v_endpoint_channel='TWILIO_VOICE' THEN
    RAISE EXCEPTION 'privacy_voice_consent_authority_missing'
      USING ERRCODE='23514';
  END IF;

  IF EXISTS(SELECT 1 FROM ops.privacy_requests_v2 WHERE id=v_privacy_request_id)
     OR EXISTS(SELECT 1 FROM intake.communication_subjects WHERE id=v_subject_id)
     OR EXISTS(SELECT 1 FROM intake.communication_endpoints WHERE id=v_endpoint_id) THEN
    RAISE EXCEPTION 'privacy_request_create_identity_conflict'
      USING ERRCODE='PVT05';
  END IF;
  PERFORM 1 FROM ops.privacy_requests_v2
  WHERE subject_proof_hash=v_subject_proof_hash
    AND subject_scope_digest=v_subject_scope_digest
    AND state IN ('RECEIVED','REVIEW','APPROVED')
  ORDER BY created_at,id FOR UPDATE;

  v_origin_payload:=jsonb_build_object(
    'schemaVersion','privacy-communication-origin.v1',
    'subjectKind','PRIVACY_REQUESTER','originObjectType','PRIVACY_REQUEST',
    'originObjectId',v_privacy_request_id,'originObjectVersion',1,
    'subjectProofHash',btrim(v_subject_proof_hash)
  );
  v_origin_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_origin_payload),'sha256'
  ),'hex');
  v_profile_payload:=jsonb_build_object(
    'schemaVersion','privacy-communication-profile.v1','subjectId',v_subject_id,
    'originBindingDigest',btrim(v_origin_digest),
    'subjectPseudonymHmac',btrim(v_subject_proof_hash),
    'hmacKeyVersion',v_subject_hmac_key_version,
    'jurisdiction',v_jurisdiction,'locale',v_locale,
    'status','ACTIVE','profileVersion',1
  );
  v_profile_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_profile_payload),'sha256'
  ),'hex');
  v_endpoint_payload:=jsonb_build_object(
    'schemaVersion','privacy-communication-endpoint.v1','endpointId',v_endpoint_id,
    'subjectId',v_subject_id,'channel',v_endpoint_channel,
    'endpointHmac',btrim(v_endpoint_hmac),
    'hmacKeyVersion',v_endpoint_hmac_key_version,
    'endpointCiphertextSha256',encode(
      extensions.digest(v_endpoint_ciphertext,'sha256'),'hex'
    ),
    'encryptionKeyId',v_endpoint_encryption_key_id,
    'endpointAadDigest',btrim(v_endpoint_aad_digest),
    'state','PENDING_VERIFICATION','version',1
  );
  v_endpoint_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_endpoint_payload),'sha256'
  ),'hex');

  INSERT INTO intake.communication_subjects(
    id,subject_kind,origin_object_type,origin_object_id,origin_object_version,
    origin_binding_digest,subject_pseudonym_hmac,hmac_key_version,
    jurisdiction,locale,status,profile_version,profile_digest,
    created_at,updated_at
  ) VALUES(
    v_subject_id,'PRIVACY_REQUESTER','PRIVACY_REQUEST',v_privacy_request_id,1,
    v_origin_digest,v_subject_proof_hash,v_subject_hmac_key_version,
    v_jurisdiction,v_locale,'ACTIVE',1,v_profile_digest,v_now,v_now
  );
  INSERT INTO intake.communication_endpoints(
    id,subject_id,channel,endpoint_hmac,hmac_key_version,endpoint_ciphertext,
    encryption_key_id,state,version,endpoint_digest,endpoint_aad_digest,
    created_at,updated_at
  ) VALUES(
    v_endpoint_id,v_subject_id,v_endpoint_channel,v_endpoint_hmac,
    v_endpoint_hmac_key_version,v_endpoint_ciphertext,
    v_endpoint_encryption_key_id,'PENDING_VERIFICATION',1,
    v_endpoint_digest,v_endpoint_aad_digest,v_now,v_now
  );

  v_request_receipt_payload:=jsonb_build_object(
    'schemaVersion','privacy-request-create-receipt.v1',
    'privacyRequestId',v_privacy_request_id,'requestType',v_request_type,
    'subjectProofHash',btrim(v_subject_proof_hash),
    'jurisdiction',v_jurisdiction,'scopeDigest',btrim(v_scope_sha256),
    'identityState','PENDING_VERIFICATION','identityVerifiedAt',NULL,
    'dueAt',NULL,'createdAt',v_now,
    'accessPolicy',jsonb_build_object(
      'policyId',v_access_policy.policy_id,
      'revision',v_access_policy.revision,
      'policyVersion',v_access_policy.policy_version,
      'policyDigest',btrim(v_access_policy.policy_digest),
      'bindingDigest',btrim(v_access_policy.binding_digest),
      'tokenExpiresAt',v_token_expires_at
    )
  );
  v_request_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_request_receipt_payload),'sha256'
  ),'hex');
  v_command_receipt_payload:=jsonb_build_object(
    'schemaVersion','privacy-command-receipt.v1',
    'operationId','createPrivacyRequest','requestId',p_request_id,
    'aggregateId',v_privacy_request_id,'aggregateVersion',1,
    'acceptedAt',v_now,'requestReceiptDigest',btrim(v_request_receipt_digest),
    'accessPolicyId',v_access_policy.policy_id,
    'accessPolicyRevision',v_access_policy.revision,
    'accessPolicyDigest',btrim(v_access_policy.policy_digest),
    'accessPolicyBindingDigest',btrim(v_access_policy.binding_digest)
  );
  v_command_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_command_receipt_payload),'sha256'
  ),'hex');
  v_audit_id:=ops.append_audit_event(
    'privacy-request:'||v_privacy_request_id::text,'ANONYMOUS',NULL,NULL,
    'command.createPrivacyRequest','PRIVACY_REQUEST',v_privacy_request_id::text,
    NULL,'SUCCESS',NULL,p_request_id,jsonb_build_object(
      'requestType',v_request_type,'subjectProofHash',btrim(v_subject_proof_hash),
      'scopeDigest',btrim(v_scope_sha256),
      'receiptDigest',btrim(v_request_receipt_digest),
      'commandReceiptDigest',btrim(v_command_receipt_digest),
      'accessPolicyId',v_access_policy.policy_id,
      'accessPolicyRevision',v_access_policy.revision,
      'accessPolicyDigest',btrim(v_access_policy.policy_digest),
      'accessPolicyBindingDigest',btrim(v_access_policy.binding_digest)
    )
  );
  v_event_payload:=jsonb_build_object(
    'retentionRequestId',v_privacy_request_id,'requestType',v_request_type,
    'subjectProofHash',btrim(v_subject_proof_hash),'jurisdiction',v_jurisdiction,
    'scopeDigest',btrim(v_scope_sha256),
    'identityState','PENDING_VERIFICATION','identityVerifiedAt',NULL,
    'dueAt',NULL,'receiptDigest',btrim(v_request_receipt_digest),
    'commandReceiptDigest',btrim(v_command_receipt_digest)
  );
  v_outbox_id:=ops.enqueue_outbox(
    'privacy_request',v_privacy_request_id::text,1,
    'privacy.request_created.v2',v_event_payload,v_now
  );

  INSERT INTO ops.privacy_requests_v2(
    id,request_type,state,identity_state,jurisdiction,subject_proof_hash,
    identity_proof_kind,identity_proof_ref_id,identity_proof_binding_digest,
    subject_scope_digest,scope_ciphertext,scope_sha256,scope_aad_digest,
    statement_ciphertext,statement_sha256,statement_aad_digest,encryption_key_id,
    communication_subject_id,communication_subject_origin_digest,
    communication_endpoint_id,communication_endpoint_version,
    communication_endpoint_digest,decision_version,identity_verified_at,due_at,
    create_request_id,create_idempotency_key_sha256,create_request_sha256,
    create_audit_event_id,create_outbox_event_id,create_receipt_digest,
    created_at,updated_at
  ) VALUES(
    v_privacy_request_id,v_request_type,'RECEIVED','PENDING_VERIFICATION',
    v_jurisdiction,v_subject_proof_hash,v_identity_proof_kind,
    v_identity_proof_ref_id,v_identity_proof_binding_digest,
    v_subject_scope_digest,v_scope_ciphertext,v_scope_sha256,v_scope_aad_digest,
    v_statement_ciphertext,v_statement_sha256,v_statement_aad_digest,
    v_encryption_key_id,v_subject_id,v_origin_digest,v_endpoint_id,1,
    v_endpoint_digest,0,NULL,NULL,p_request_id,p_idempotency_key_sha256,
    p_request_sha256,v_audit_id,v_outbox_id,v_request_receipt_digest,v_now,v_now
  );

  v_result:=jsonb_build_object(
    'command',jsonb_build_object(
      'transportRequestId',p_request_id,'aggregateId',v_privacy_request_id,
      'aggregateVersion',1,'auditEventId',v_audit_id,'acceptedAt',v_now,
      'receiptDigest',btrim(v_command_receipt_digest),
      'emittedEventIds',jsonb_build_array(v_outbox_id)
    ),
    'request',jsonb_build_object(
      'privacyRequestId',v_privacy_request_id,'requestType',v_request_type,
      'state','RECEIVED','jurisdiction',v_jurisdiction,
      'scopeDigest',btrim(v_scope_sha256),
      'identityState','PENDING_VERIFICATION','identityVerifiedAt',NULL,
      'dueAt',NULL,'createdAt',v_now,'updatedAt',v_now
    )
  );
  INSERT INTO ops.privacy_request_receipt_tokens_v2(
    privacy_request_id,operation_id,idempotency_key_sha256,request_sha256,
    token_hmac,token_sha256,token_key_version,secretless_response_template,
    secretless_response_digest,expires_at,access_policy_id,
    access_policy_revision,access_policy_digest,access_policy_binding_digest,
    created_at
  ) VALUES(
    v_privacy_request_id,'createPrivacyRequest',p_idempotency_key_sha256,
    p_request_sha256,v_token_hmac,v_token_sha256,v_token_key_version,v_result,
    encode(extensions.digest(ops.canonical_jsonb_v1(v_result),'sha256'),'hex'),
    v_token_expires_at,v_access_policy.policy_id,v_access_policy.revision,
    v_access_policy.policy_digest,v_access_policy.binding_digest,v_now
  );
  UPDATE ops.idempotency_keys SET
    response_status=201,response_body=v_result,resource_type='PrivacyRequest',
    resource_id=v_privacy_request_id::text
  WHERE scope='PRIVACY_REQUEST_CREATE_V2'
    AND key_hash=p_idempotency_key_sha256
    AND request_hash=p_request_sha256 AND response_status IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_request_create_finalize_conflict'
      USING ERRCODE='PVT05';
  END IF;
  RETURN v_result||jsonb_build_object('replayed',false);
END
$create$;
ALTER FUNCTION ops.create_privacy_request_v2(jsonb,uuid,char(64),char(64))
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.create_privacy_request_v2(
  jsonb,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.create_privacy_request_v2(
  jsonb,uuid,char(64),char(64)
) TO gurine_submission_api;

-- Base-table reads are not a submission-api authority.  All reads pass through
-- get_privacy_request_v2; writes pass through SECURITY DEFINER owner routines.
REVOKE SELECT ON ops.privacy_requests_v2 FROM gurine_submission_api;

CREATE OR REPLACE FUNCTION ops.exchange_privacy_request_receipt_token_v2(
  p_token_hmac char(64),
  p_next_session_sha256 char(64),
  p_bff_issuer text,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_sha256 char(64)
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,extensions,pg_temp
AS $exchange$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_claimed integer;
  v_existing ops.idempotency_keys%ROWTYPE;
  v_token ops.privacy_request_receipt_tokens_v2%ROWTYPE;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_access_policy ops.privacy_request_access_policies_v1%ROWTYPE;
  v_session_id uuid:=gen_random_uuid();
  v_session_expires_at timestamptz;
  v_receipt_payload jsonb;
  v_receipt_digest char(64);
  v_audit_id uuid;
  v_outbox_id uuid;
  v_result jsonb;
  v_prior_token_guard text:=current_setting(
    'gurine.privacy_receipt_token_consume_v2',true
  );
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

  -- Resolve and validate the DB-clocked authority before the idempotency
  -- claim, so dependency failure is provably zero-write.
  v_access_policy:=ops.current_privacy_request_access_policy_v1(v_now);
  BEGIN
    v_session_expires_at:=LEAST(
      v_access_policy.review_expires_at,
      v_now+make_interval(
        secs=>v_access_policy.read_only_session_ttl_seconds::double precision
      )
    );
  EXCEPTION WHEN datetime_field_overflow OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'privacy_access_policy_ttl_invalid' USING ERRCODE='23514';
  END;
  IF NOT isfinite(v_session_expires_at) OR v_session_expires_at<=v_now THEN
    RAISE EXCEPTION 'privacy_access_policy_ttl_invalid' USING ERRCODE='23514';
  END IF;

  INSERT INTO ops.idempotency_keys(scope,key_hash,request_hash,expires_at)
  VALUES(
    'PRIVACY_RECEIPT_EXCHANGE_V2',p_idempotency_key_sha256,
    p_request_sha256,v_now+interval '24 hours'
  ) ON CONFLICT(scope,key_hash) DO NOTHING;
  GET DIAGNOSTICS v_claimed=ROW_COUNT;
  SELECT * INTO STRICT v_existing FROM ops.idempotency_keys
  WHERE scope='PRIVACY_RECEIPT_EXCHANGE_V2'
    AND key_hash=p_idempotency_key_sha256 FOR UPDATE;
  IF v_existing.request_hash IS DISTINCT FROM p_request_sha256 THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_idempotency_conflict'
      USING ERRCODE='PVT05';
  END IF;
  IF v_existing.response_body IS NOT NULL THEN
    IF v_existing.response_status<>200
       OR v_existing.resource_type<>'PrivacyRequestSession'
       OR NOT EXISTS(
         SELECT 1
         FROM ops.privacy_request_receipt_tokens_v2 AS token
         JOIN intake.submission_sessions AS session
           ON session.id=token.session_id
          AND session.token_hash=token.session_token_sha256
         JOIN ops.privacy_request_access_policies_v1 AS policy
           ON policy.policy_id=session.privacy_access_policy_id
          AND policy.revision=session.privacy_access_policy_revision
          AND policy.policy_digest=session.privacy_access_policy_digest
          AND policy.binding_digest=session.privacy_access_policy_binding_digest
          AND policy.policy_id=token.access_policy_id
          AND policy.revision=token.access_policy_revision
          AND policy.policy_digest=token.access_policy_digest
          AND policy.binding_digest=token.access_policy_binding_digest
          AND ROW(
            policy.policy_id,policy.revision,policy.policy_digest,
            policy.binding_digest
          )=ROW(
            v_access_policy.policy_id,v_access_policy.revision,
            v_access_policy.policy_digest,v_access_policy.binding_digest
          )
         JOIN ops.audit_events AS audit
           ON audit.id=token.exchange_audit_event_id
         JOIN ops.outbox AS event
           ON event.id=token.exchange_outbox_event_id
         WHERE token.token_hmac=p_token_hmac
           AND token.consumed_at IS NOT NULL
           AND session.id=v_existing.resource_id::uuid
           AND session.session_kind='PRIVACY_REQUEST_RECEIPT'
           AND session.scope_type='PRIVACY_REQUEST'
           AND session.scope_id=token.privacy_request_id
           AND session.bff_issuer=p_bff_issuer
           AND session.expires_at=(v_existing.response_body->>'expiresAt')::timestamptz
           AND token.consumed_at=
             (v_existing.response_body->>'tokenConsumedAt')::timestamptz
           AND v_existing.response_body=jsonb_build_object(
             'requestId',token.privacy_request_id,'sessionId',session.id,
             'expiresAt',session.expires_at,
             'cookieName',policy.cookie_name,'tokenConsumedAt',token.consumed_at,
             'auditEventId',token.exchange_audit_event_id,
             'emittedEventIds',jsonb_build_array(token.exchange_outbox_event_id),
             'receiptDigest',btrim(token.exchange_receipt_digest)
           )
           AND token.exchange_receipt_digest=encode(extensions.digest(
             ops.canonical_jsonb_v1(jsonb_build_object(
               'schemaVersion','privacy-request-session-receipt.v1',
               'requestId',token.privacy_request_id,'sessionId',session.id,
               'state','ACTIVE','expiresAt',session.expires_at,
               'cookieName',policy.cookie_name,
               'tokenConsumedAt',token.consumed_at,
               'accessPolicy',jsonb_build_object(
                 'policyId',policy.policy_id,'revision',policy.revision,
                 'policyVersion',policy.policy_version,
                 'policyDigest',btrim(policy.policy_digest),
                 'bindingDigest',btrim(policy.binding_digest),
                 'cookiePath',policy.cookie_path,'sameSite',policy.same_site,
                 'secure',policy.secure,'httpOnly',policy.http_only
               )
             )),'sha256'),'hex')
           AND event.aggregate_type='submission_session'
           AND event.aggregate_id=session.id::text
           AND event.aggregate_version=1
           AND event.event_type='identity.session_created.v1'
       ) THEN
      RAISE EXCEPTION 'privacy_receipt_exchange_replay_closure_invalid'
        USING ERRCODE='23514';
    END IF;
    RETURN v_existing.response_body||jsonb_build_object('replayed',true);
  ELSIF v_claimed=0 THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_claim_incomplete'
      USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_token FROM ops.privacy_request_receipt_tokens_v2
  WHERE token_hmac=p_token_hmac FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_receipt_token_invalid' USING ERRCODE='PVT01';
  END IF;
  IF v_token.consumed_at IS NOT NULL THEN
    RAISE EXCEPTION 'privacy_receipt_token_replayed' USING ERRCODE='PVT03';
  END IF;
  IF v_token.expires_at<=v_now THEN
    RAISE EXCEPTION 'privacy_receipt_token_expired' USING ERRCODE='PVT02';
  END IF;
  IF ROW(
       v_token.access_policy_id,v_token.access_policy_revision,
       v_token.access_policy_digest,v_token.access_policy_binding_digest
     ) IS DISTINCT FROM ROW(
       v_access_policy.policy_id,v_access_policy.revision,
       v_access_policy.policy_digest,v_access_policy.binding_digest
     ) THEN
    RAISE EXCEPTION 'privacy_receipt_access_policy_changed'
      USING ERRCODE='23514';
  END IF;
  SELECT * INTO v_request FROM ops.privacy_requests_v2
  WHERE id=v_token.privacy_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_receipt_request_authority_missing'
      USING ERRCODE='23514';
  END IF;
  IF EXISTS(
    SELECT 1 FROM intake.submission_sessions
    WHERE token_hash=p_next_session_sha256
  ) THEN
    RAISE EXCEPTION 'privacy_receipt_session_identity_conflict'
      USING ERRCODE='PVT05';
  END IF;

  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','privacy-request-session-receipt.v1',
    'requestId',v_request.id,'sessionId',v_session_id,'state','ACTIVE',
    'expiresAt',v_session_expires_at,
    'cookieName',v_access_policy.cookie_name,'tokenConsumedAt',v_now,
    'accessPolicy',jsonb_build_object(
      'policyId',v_access_policy.policy_id,
      'revision',v_access_policy.revision,
      'policyVersion',v_access_policy.policy_version,
      'policyDigest',btrim(v_access_policy.policy_digest),
      'bindingDigest',btrim(v_access_policy.binding_digest),
      'cookiePath',v_access_policy.cookie_path,
      'sameSite',v_access_policy.same_site,
      'secure',v_access_policy.secure,'httpOnly',v_access_policy.http_only
    )
  );
  v_receipt_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(v_receipt_payload),'sha256'
  ),'hex');

  INSERT INTO intake.submission_sessions(
    id,token_hash,session_kind,scope_type,scope_id,bff_issuer,status,version,
    issued_at,expires_at,privacy_access_policy_id,
    privacy_access_policy_revision,privacy_access_policy_digest,
    privacy_access_policy_binding_digest
  ) VALUES(
    v_session_id,p_next_session_sha256,'PRIVACY_REQUEST_RECEIPT',
    'PRIVACY_REQUEST',v_request.id,p_bff_issuer,'ACTIVE',1,v_now,
    v_session_expires_at,v_access_policy.policy_id,v_access_policy.revision,
    v_access_policy.policy_digest,v_access_policy.binding_digest
  );
  v_audit_id:=ops.append_audit_event(
    'privacy-request:'||v_request.id::text,'SERVICE',p_bff_issuer,NULL,
    'command.exchangePrivacyRequestReceiptToken','PRIVACY_REQUEST',
    v_request.id::text,NULL,'SUCCESS',NULL,p_request_id,jsonb_build_object(
      'sessionId',v_session_id,'receiptDigest',btrim(v_receipt_digest),
      'sessionKind','PRIVACY_REQUEST_RECEIPT',
      'accessPolicyId',v_access_policy.policy_id,
      'accessPolicyRevision',v_access_policy.revision,
      'accessPolicyDigest',btrim(v_access_policy.policy_digest),
      'accessPolicyBindingDigest',btrim(v_access_policy.binding_digest)
    )
  );
  v_outbox_id:=ops.enqueue_outbox(
    'submission_session',v_session_id::text,1,'identity.session_created.v1',
    jsonb_build_object(
      'actor_id',p_bff_issuer,'occurred_at',v_now,
      'operation_id','exchangePrivacyRequestReceiptToken',
      'request_id',p_request_id
    ),v_now
  );
  PERFORM set_config('gurine.privacy_receipt_token_consume_v2','1',true);
  UPDATE ops.privacy_request_receipt_tokens_v2 SET
    consumed_at=v_now,session_id=v_session_id,
    session_token_sha256=p_next_session_sha256,
    exchange_receipt_digest=v_receipt_digest,
    exchange_audit_event_id=v_audit_id,exchange_outbox_event_id=v_outbox_id
  WHERE token_id=v_token.token_id AND consumed_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_receipt_token_replayed' USING ERRCODE='PVT03';
  END IF;
  PERFORM set_config(
    'gurine.privacy_receipt_token_consume_v2',
    COALESCE(v_prior_token_guard,''),true
  );
  v_result:=(v_receipt_payload-'schemaVersion'-'accessPolicy'-'state')||
    jsonb_build_object(
    'auditEventId',v_audit_id,'emittedEventIds',jsonb_build_array(v_outbox_id),
    'receiptDigest',btrim(v_receipt_digest)
  );
  UPDATE ops.idempotency_keys SET
    response_status=200,response_body=v_result,
    resource_type='PrivacyRequestSession',resource_id=v_session_id::text
  WHERE scope='PRIVACY_RECEIPT_EXCHANGE_V2'
    AND key_hash=p_idempotency_key_sha256
    AND request_hash=p_request_sha256 AND response_status IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_receipt_exchange_finalize_conflict'
      USING ERRCODE='PVT05';
  END IF;
  RETURN v_result||jsonb_build_object('replayed',false);
END
$exchange$;
ALTER FUNCTION ops.exchange_privacy_request_receipt_token_v2(
  char(64),char(64),text,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.exchange_privacy_request_receipt_token_v2(
  char(64),char(64),text,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.exchange_privacy_request_receipt_token_v2(
  char(64),char(64),text,uuid,char(64),char(64)
) TO gurine_submission_api;

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
         AND v_request.identity_state='VERIFIED' THEN
      RAISE EXCEPTION 'privacy_request_completion_authority_missing'
        USING ERRCODE='55000';
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
-- R6d privacy sealed-content closure draft.
--
-- Integration order inside 0038_r6d_legal_hardening.sql:
--   1. add the static record-class row beside the other catalog rows;
--   2. apply the parent receipt DDL edits documented below;
--   3. create the sealed-content table after the transition receipt table;
--   4. create the binder, erasure receipt, guard, and sole-owner routine.
--
-- This fragment intentionally seeds no ops.record_class_schedules row.  A
-- provenance-bearing schedule must be approved and executed through the
-- existing retention-governance path before any sealed content can be stored.
--
-- OPEN_QUESTION / fail-closed boundary: current 0038 has no authoritative
-- PRIVACY_REQUEST legal-hold placement+release resolver.  The erasure owner
-- routine below therefore stops with SQLSTATE 55000 before success evidence or
-- mutation.  Do not remove that gate until such a resolver and immutable
-- zero-active-hold receipt are part of the current schema contract.

CREATE TABLE ops.privacy_request_sealed_content_v2 (
  privacy_request_id uuid NOT NULL,
  transition_receipt_id uuid NOT NULL,
  field_kind text NOT NULL,
  schema_version smallint NOT NULL DEFAULT 1,
  sealed_ciphertext bytea,
  sealed_sha256 char(64) NOT NULL,
  sealed_aad_digest char(64) NOT NULL,
  encryption_key_id text NOT NULL,
  content_state text NOT NULL DEFAULT 'ACTIVE',
  expires_at timestamptz NOT NULL,
  erasure_receipt_id uuid,
  erasure_receipt_digest char(64),
  retention_schedule_id uuid NOT NULL,
  retention_record_class text NOT NULL,
  retention_schedule_digest char(64) NOT NULL,
  created_at timestamptz NOT NULL,
  erased_at timestamptz,
  CONSTRAINT privacy_request_sealed_content_v2_pk
    PRIMARY KEY(transition_receipt_id,field_kind),
  CONSTRAINT privacy_request_sealed_content_v2_request_key_uq
    UNIQUE(transition_receipt_id,field_kind,privacy_request_id),
  CONSTRAINT privacy_request_sealed_content_v2_metadata_uq UNIQUE(
    transition_receipt_id,field_kind,privacy_request_id,schema_version,sealed_sha256,
    sealed_aad_digest,encryption_key_id,retention_schedule_id,
    retention_record_class,retention_schedule_digest,created_at,expires_at
  ),
  CONSTRAINT privacy_request_sealed_content_v2_transition_fk FOREIGN KEY(
    transition_receipt_id,privacy_request_id
  ) REFERENCES ops.privacy_request_transition_receipts_v2(
    transition_receipt_id,privacy_request_id
  ) ON DELETE RESTRICT,
  CONSTRAINT privacy_request_sealed_content_v2_retention_fk FOREIGN KEY(
    retention_schedule_id,retention_record_class,retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(
    id,record_class,schedule_digest
  ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT privacy_request_sealed_content_v2_class_fk
    FOREIGN KEY(retention_record_class)
    REFERENCES ops.r6d_record_class_catalog(record_class) ON DELETE RESTRICT,
  CONSTRAINT privacy_request_sealed_content_v2_shape_ck CHECK (
    field_kind IN (
      'REASON','EXTENSION_REASON','REJECTION_REASON','APPEAL_INSTRUCTIONS'
    )
    AND schema_version=1
    AND retention_record_class='PRIVACY_REQUEST_SEALED_CONTENT'
    AND ops.r6d_lower_sha256(sealed_sha256)
    AND ops.r6d_lower_sha256(sealed_aad_digest)
    AND length(encryption_key_id) BETWEEN 1 AND 200
    AND expires_at>created_at
    AND ((erasure_receipt_id IS NULL)=(erasure_receipt_digest IS NULL))
    AND (erasure_receipt_digest IS NULL
      OR ops.r6d_lower_sha256(erasure_receipt_digest))
    AND sealed_aad_digest=encode(extensions.digest(
      convert_to('ops.privacy_request_sealed_content_v2','UTF8')
      ||decode('00','hex')
      ||convert_to('sealed_ciphertext','UTF8')
      ||decode('00','hex')
      ||convert_to(transition_receipt_id::text,'UTF8')
      ||decode('00','hex')
      ||convert_to(field_kind,'UTF8')
      ||decode('00','hex')
      ||convert_to(schema_version::text,'UTF8'),
      'sha256'
    ),'hex')
    AND (
      content_state='ACTIVE'
      AND sealed_ciphertext IS NOT NULL
      AND octet_length(sealed_ciphertext) BETWEEN 1 AND 65536
      AND ops.r6d_field_envelope_v1_is_valid(
        sealed_ciphertext,encryption_key_id
      )
      AND erased_at IS NULL
      AND erasure_receipt_id IS NULL
      AND erasure_receipt_digest IS NULL
      OR content_state='ERASED'
      AND sealed_ciphertext IS NULL
      AND erased_at IS NOT NULL
      AND erasure_receipt_id IS NOT NULL
      AND erasure_receipt_digest IS NOT NULL
    )
  )
);
-- sealed_sha256 is the digest of the bounded plaintext supplied by the trusted
-- encryption boundary, not a digest of sealed_ciphertext.  The DB never
-- receives plaintext; the insert guard binds this digest to immutable parent
-- metadata and the decrypting worker verifies it after authenticated decrypt.
ALTER TABLE ops.privacy_request_sealed_content_v2 OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_request_sealed_content_v2 FROM PUBLIC;
REVOKE ALL ON ops.privacy_request_sealed_content_v2
  FROM gurine_control_api,gurine_submission_api,gurine_workflow_worker,
       gurine_notification_worker,gurine_scheduler,gurine_auditor;

-- No direct SELECT is granted: ACTIVE rows contain replayable ciphertext.
-- The notification safe-reader is a SECURITY DEFINER function and must return
-- a row only for content_state='ACTIVE' AND clock_timestamp()<expires_at.
-- Missing, expired, or ERASED content is represented by zero rows, never by
-- ciphertext-null metadata rows or a fallback to immutable receipt payloads.

CREATE OR REPLACE FUNCTION ops.bind_privacy_request_sealed_content_v2()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $$
DECLARE
  v_transition ops.privacy_request_transition_receipts_v2%ROWTYPE;
  v_schedule ops.record_class_schedules%ROWTYPE;
  v_expected_sha256 char(64);
  v_expected_aad_digest char(64);
  v_count bigint;
  v_anchor_at timestamptz;
BEGIN
  IF NEW.privacy_request_id IS NULL OR NEW.transition_receipt_id IS NULL
     OR NEW.field_kind IS NULL OR NEW.field_kind NOT IN (
       'REASON','EXTENSION_REASON','REJECTION_REASON','APPEAL_INSTRUCTIONS'
     )
     OR NEW.schema_version IS DISTINCT FROM 1
     OR NEW.sealed_ciphertext IS NULL
     OR NOT ops.r6d_field_envelope_v1_is_valid(
       NEW.sealed_ciphertext,NEW.encryption_key_id
     )
     OR NOT ops.r6d_lower_sha256(NEW.sealed_sha256)
     OR NOT ops.r6d_lower_sha256(NEW.sealed_aad_digest)
     OR length(NEW.encryption_key_id) NOT BETWEEN 1 AND 200
     OR NEW.content_state IS DISTINCT FROM 'ACTIVE'
     OR NEW.erasure_receipt_id IS NOT NULL
     OR NEW.erasure_receipt_digest IS NOT NULL
     OR NEW.erased_at IS NOT NULL
     OR NEW.expires_at IS NOT NULL
     OR NEW.created_at IS NOT NULL
     OR num_nonnulls(
       NEW.retention_schedule_id,NEW.retention_record_class,
       NEW.retention_schedule_digest
     )<>0 THEN
    RAISE EXCEPTION 'privacy_sealed_content_insert_invalid'
      USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_transition
  FROM ops.privacy_request_transition_receipts_v2 AS transition
  WHERE transition.transition_receipt_id=NEW.transition_receipt_id
    AND transition.privacy_request_id=NEW.privacy_request_id
  FOR KEY SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_sealed_content_transition_not_found'
      USING ERRCODE='P0002';
  END IF;
  v_anchor_at:=v_transition.decided_at;
  IF v_anchor_at IS NULL OR NOT isfinite(v_anchor_at)
     OR v_anchor_at<transaction_timestamp()
     OR v_anchor_at>clock_timestamp() THEN
    RAISE EXCEPTION 'privacy_sealed_content_transition_time_invalid'
      USING ERRCODE='23514';
  END IF;

  CASE NEW.field_kind
    WHEN 'REASON' THEN
      v_expected_sha256:=v_transition.reason_sha256;
      v_expected_aad_digest:=v_transition.reason_aad_digest;
    WHEN 'EXTENSION_REASON' THEN
      IF v_transition.transition<>'EXTEND' THEN
        RAISE EXCEPTION 'privacy_sealed_content_field_not_applicable'
          USING ERRCODE='23514';
      END IF;
      v_expected_sha256:=v_transition.extension_reason_sha256;
      v_expected_aad_digest:=v_transition.extension_reason_aad_digest;
    WHEN 'REJECTION_REASON' THEN
      IF v_transition.transition<>'REJECT' THEN
        RAISE EXCEPTION 'privacy_sealed_content_field_not_applicable'
          USING ERRCODE='23514';
      END IF;
      v_expected_sha256:=v_transition.rejection_reason_sha256;
      v_expected_aad_digest:=v_transition.rejection_reason_aad_digest;
    WHEN 'APPEAL_INSTRUCTIONS' THEN
      IF v_transition.transition<>'REJECT' THEN
        RAISE EXCEPTION 'privacy_sealed_content_field_not_applicable'
          USING ERRCODE='23514';
      END IF;
      v_expected_sha256:=v_transition.appeal_instructions_sha256;
      v_expected_aad_digest:=v_transition.appeal_instructions_aad_digest;
  END CASE;

  IF v_expected_sha256 IS NULL OR v_expected_aad_digest IS NULL
     OR NEW.sealed_sha256<>v_expected_sha256
     OR NEW.sealed_aad_digest<>v_expected_aad_digest
     OR NEW.encryption_key_id<>v_transition.encryption_key_id THEN
    RAISE EXCEPTION 'privacy_sealed_content_parent_binding_invalid'
      USING ERRCODE='23514';
  END IF;

  LOCK TABLE ops.record_class_schedules IN SHARE MODE;
  SELECT count(*) INTO v_count
  FROM ops.record_class_schedules AS schedule
  WHERE schedule.record_class='PRIVACY_REQUEST_SEALED_CONTENT'
    AND schedule.trigger_kind='CREATED_AT'
    AND schedule.terminal_action='CRYPTO_ERASE'
    AND schedule.active_duration_seconds>0
    AND schedule.backup_duration_seconds IS NOT NULL
    AND schedule.effective_at<=v_anchor_at
    AND schedule.review_expires_at>v_anchor_at;
  IF v_count=0 THEN
    RAISE EXCEPTION 'privacy_sealed_content_schedule_missing'
      USING ERRCODE='55000';
  ELSIF v_count<>1 THEN
    RAISE EXCEPTION 'privacy_sealed_content_schedule_ambiguous'
      USING ERRCODE='55000';
  END IF;

  SELECT * INTO STRICT v_schedule
  FROM ops.record_class_schedules AS schedule
  WHERE schedule.record_class='PRIVACY_REQUEST_SEALED_CONTENT'
    AND schedule.trigger_kind='CREATED_AT'
    AND schedule.terminal_action='CRYPTO_ERASE'
    AND schedule.active_duration_seconds>0
    AND schedule.backup_duration_seconds IS NOT NULL
    AND schedule.effective_at<=v_anchor_at
    AND schedule.review_expires_at>v_anchor_at
  FOR SHARE;

  NEW.created_at:=v_anchor_at;
  NEW.expires_at:=v_anchor_at
    +(v_schedule.active_duration_seconds*interval '1 second');
  NEW.retention_schedule_id:=v_schedule.id;
  NEW.retention_record_class:=v_schedule.record_class;
  NEW.retention_schedule_digest:=v_schedule.schedule_digest;
  RETURN NEW;
END
$$;
ALTER FUNCTION ops.bind_privacy_request_sealed_content_v2()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.bind_privacy_request_sealed_content_v2()
  FROM PUBLIC;
CREATE TRIGGER privacy_request_sealed_content_v2_insert_guard
  BEFORE INSERT ON ops.privacy_request_sealed_content_v2
  FOR EACH ROW EXECUTE FUNCTION ops.bind_privacy_request_sealed_content_v2();
CREATE INDEX privacy_request_sealed_content_v2_expiry_idx
  ON ops.privacy_request_sealed_content_v2(
    expires_at,transition_receipt_id,field_kind
  ) WHERE content_state='ACTIVE';

CREATE TABLE ops.privacy_request_sealed_content_erasure_receipts_v1 (
  erasure_receipt_id uuid PRIMARY KEY,
  privacy_request_id uuid NOT NULL,
  transition_receipt_id uuid NOT NULL,
  field_kind text NOT NULL,
  prior_content_state text NOT NULL,
  content_schema_version smallint NOT NULL,
  prior_sealed_sha256 char(64) NOT NULL,
  prior_sealed_aad_digest char(64) NOT NULL,
  prior_encryption_key_id text NOT NULL,
  prior_content_binding_digest char(64) NOT NULL,
  content_retention_schedule_id uuid NOT NULL,
  content_retention_record_class text NOT NULL,
  content_retention_schedule_digest char(64) NOT NULL,
  content_created_at timestamptz NOT NULL,
  content_expires_at timestamptz NOT NULL,
  authorization_evidence_digest char(64) NOT NULL,
  active_legal_hold_count bigint NOT NULL,
  legal_hold_coverage_digest char(64) NOT NULL,
  actor_type text NOT NULL,
  actor_id text NOT NULL,
  request_id uuid NOT NULL UNIQUE,
  idempotency_key_sha256 char(64) NOT NULL UNIQUE,
  request_digest char(64) NOT NULL,
  audit_event_id uuid NOT NULL UNIQUE
    REFERENCES ops.audit_events(id) ON DELETE RESTRICT,
  receipt_payload jsonb NOT NULL,
  receipt_canonical bytea NOT NULL,
  receipt_digest char(64) NOT NULL UNIQUE,
  erased_at timestamptz NOT NULL,
  CONSTRAINT privacy_sealed_erasure_receipts_v1_child_uq
    UNIQUE(transition_receipt_id,field_kind),
  CONSTRAINT privacy_sealed_erasure_receipts_v1_pointer_uq
    UNIQUE(erasure_receipt_id,receipt_digest),
  CONSTRAINT privacy_sealed_erasure_receipts_v1_child_fk FOREIGN KEY(
    transition_receipt_id,field_kind,privacy_request_id,content_schema_version,
    prior_sealed_sha256,prior_sealed_aad_digest,prior_encryption_key_id,
    content_retention_schedule_id,content_retention_record_class,
    content_retention_schedule_digest,content_created_at,content_expires_at
  ) REFERENCES ops.privacy_request_sealed_content_v2(
    transition_receipt_id,field_kind,privacy_request_id,schema_version,sealed_sha256,
    sealed_aad_digest,encryption_key_id,retention_schedule_id,
    retention_record_class,retention_schedule_digest,created_at,expires_at
  ) ON DELETE RESTRICT,
  CONSTRAINT privacy_sealed_erasure_receipts_v1_schedule_fk FOREIGN KEY(
    content_retention_schedule_id,content_retention_record_class,
    content_retention_schedule_digest
  ) REFERENCES ops.record_class_schedules(
    id,record_class,schedule_digest
  ) MATCH FULL ON DELETE RESTRICT,
  CONSTRAINT privacy_sealed_erasure_receipts_v1_shape_ck CHECK (
    field_kind IN (
      'REASON','EXTENSION_REASON','REJECTION_REASON','APPEAL_INSTRUCTIONS'
    )
    AND prior_content_state='ACTIVE'
    AND content_schema_version=1
    AND content_retention_record_class='PRIVACY_REQUEST_SEALED_CONTENT'
    AND content_expires_at>=content_created_at
    AND erased_at>=content_expires_at
    AND active_legal_hold_count=0
    AND actor_type='SERVICE'
    AND actor_id='retention-worker'
    AND length(prior_encryption_key_id) BETWEEN 1 AND 200
    AND ops.r6d_lower_sha256(prior_sealed_sha256)
    AND ops.r6d_lower_sha256(prior_sealed_aad_digest)
    AND ops.r6d_lower_sha256(prior_content_binding_digest)
    AND ops.r6d_lower_sha256(authorization_evidence_digest)
    AND ops.r6d_lower_sha256(legal_hold_coverage_digest)
    AND ops.r6d_lower_sha256(idempotency_key_sha256)
    AND ops.r6d_lower_sha256(request_digest)
    AND ops.r6d_lower_sha256(receipt_digest)
    AND prior_content_binding_digest=encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_object(
        'privacyRequestId',privacy_request_id,
        'transitionReceiptId',transition_receipt_id,
        'fieldKind',field_kind,'schemaVersion',content_schema_version,
        'contentState',prior_content_state,
        'sealedSha256',btrim(prior_sealed_sha256),
        'sealedAadDigest',btrim(prior_sealed_aad_digest),
        'encryptionKeyId',prior_encryption_key_id,
        'scheduleId',content_retention_schedule_id,
        'scheduleDigest',btrim(content_retention_schedule_digest),
        'createdAt',content_created_at,'expiresAt',content_expires_at
      )),'sha256'
    ),'hex')
    AND convert_from(receipt_canonical,'UTF8')::jsonb=receipt_payload
    AND receipt_digest=encode(
      extensions.digest(receipt_canonical,'sha256'),'hex'
    )
    AND NOT receipt_payload ?| ARRAY[
      'plaintext','ciphertext','sealedCiphertext','reason',
      'extensionReason','rejectionReason','appealInstructions'
    ]
  )
);
ALTER TABLE ops.privacy_request_sealed_content_erasure_receipts_v1
  OWNER TO gurine_migrator;
REVOKE ALL ON ops.privacy_request_sealed_content_erasure_receipts_v1
  FROM PUBLIC;
GRANT SELECT ON ops.privacy_request_sealed_content_erasure_receipts_v1
  TO gurine_control_api,gurine_auditor;
CREATE TRIGGER privacy_sealed_erasure_receipts_v1_immutable_guard
  BEFORE UPDATE OR DELETE
  ON ops.privacy_request_sealed_content_erasure_receipts_v1
  FOR EACH ROW EXECUTE FUNCTION ops.reject_mutation();

ALTER TABLE ops.privacy_request_sealed_content_v2
  ADD CONSTRAINT privacy_request_sealed_content_v2_erasure_fk FOREIGN KEY(
    erasure_receipt_id,erasure_receipt_digest
  ) REFERENCES ops.privacy_request_sealed_content_erasure_receipts_v1(
    erasure_receipt_id,receipt_digest
  ) MATCH FULL ON DELETE RESTRICT;

CREATE OR REPLACE FUNCTION ops.guard_privacy_request_sealed_content_v2_update()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,pg_temp
AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'privacy_sealed_content_immutable'
      USING ERRCODE='55000';
  END IF;
  IF current_user<>'gurine_migrator'
     OR current_setting(
       'gurine.privacy_sealed_content_erasure',true
     ) IS DISTINCT FROM '1'
     OR OLD.content_state IS DISTINCT FROM 'ACTIVE'
     OR NEW.content_state IS DISTINCT FROM 'ERASED'
     OR OLD.sealed_ciphertext IS NULL OR NEW.sealed_ciphertext IS NOT NULL
     OR NEW.erased_at IS NULL OR NEW.erased_at<OLD.expires_at
     OR NEW.erasure_receipt_id IS NULL
     OR NEW.erasure_receipt_digest IS NULL
     OR NOT EXISTS(
       SELECT 1
       FROM ops.privacy_request_sealed_content_erasure_receipts_v1 AS receipt
       WHERE receipt.erasure_receipt_id=NEW.erasure_receipt_id
         AND receipt.receipt_digest=NEW.erasure_receipt_digest
         AND receipt.privacy_request_id=OLD.privacy_request_id
         AND receipt.transition_receipt_id=OLD.transition_receipt_id
         AND receipt.field_kind=OLD.field_kind
     )
     OR ROW(
       NEW.privacy_request_id,NEW.transition_receipt_id,NEW.field_kind,
       NEW.schema_version,NEW.sealed_sha256,NEW.sealed_aad_digest,
       NEW.encryption_key_id,NEW.expires_at,NEW.retention_schedule_id,
       NEW.retention_record_class,NEW.retention_schedule_digest,NEW.created_at
     ) IS DISTINCT FROM ROW(
       OLD.privacy_request_id,OLD.transition_receipt_id,OLD.field_kind,
       OLD.schema_version,OLD.sealed_sha256,OLD.sealed_aad_digest,
       OLD.encryption_key_id,OLD.expires_at,OLD.retention_schedule_id,
       OLD.retention_record_class,OLD.retention_schedule_digest,OLD.created_at
     ) THEN
    RAISE EXCEPTION 'privacy_sealed_content_erasure_transition_invalid'
      USING ERRCODE='55000';
  END IF;
  RETURN NEW;
END
$$;
ALTER FUNCTION ops.guard_privacy_request_sealed_content_v2_update()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.guard_privacy_request_sealed_content_v2_update()
  FROM PUBLIC;
CREATE TRIGGER privacy_request_sealed_content_v2_update_guard
  BEFORE UPDATE OR DELETE ON ops.privacy_request_sealed_content_v2
  FOR EACH ROW
  EXECUTE FUNCTION ops.guard_privacy_request_sealed_content_v2_update();

CREATE OR REPLACE FUNCTION ops.erase_privacy_request_sealed_content_v1(
  p_privacy_request_id uuid,
  p_transition_receipt_id uuid,
  p_field_kind text,
  p_actor_service_id text,
  p_request_id uuid,
  p_idempotency_key_sha256 char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,ops,editorial,extensions,pg_temp
AS $$
DECLARE
  v_content ops.privacy_request_sealed_content_v2%ROWTYPE;
  v_existing ops.privacy_request_sealed_content_erasure_receipts_v1%ROWTYPE;
  v_schedule ops.record_class_schedules%ROWTYPE;
  v_hold_set jsonb;
  v_hold_count bigint;
  v_hold_digest char(64);
  v_prior_binding_digest char(64);
  v_authorization_digest char(64);
  v_receipt_id uuid:=gen_random_uuid();
  v_receipt_payload jsonb;
  v_receipt_canonical bytea;
  v_receipt_digest char(64);
  v_audit_event_id uuid;
  v_prior_erasure_guard text:=current_setting(
    'gurine.privacy_sealed_content_erasure',true
  );
  v_now timestamptz;
BEGIN
  IF NOT pg_has_role(session_user,'gurine_workflow_worker','MEMBER')
     OR p_actor_service_id IS DISTINCT FROM 'retention-worker'
     OR p_privacy_request_id IS NULL
     OR p_transition_receipt_id IS NULL
     OR p_field_kind IS NULL OR p_field_kind NOT IN (
       'REASON','EXTENSION_REASON','REJECTION_REASON','APPEAL_INSTRUCTIONS'
     )
     OR p_request_id IS NULL
     OR p_idempotency_key_sha256 IS NULL
     OR p_request_digest IS NULL
     OR NOT ops.r6d_lower_sha256(p_idempotency_key_sha256)
     OR NOT ops.r6d_lower_sha256(p_request_digest) THEN
    RAISE EXCEPTION 'privacy_sealed_content_erasure_input_invalid'
      USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_existing
  FROM ops.privacy_request_sealed_content_erasure_receipts_v1 AS receipt
  WHERE receipt.idempotency_key_sha256=p_idempotency_key_sha256
  FOR SHARE;
  IF FOUND THEN
    IF v_existing.request_digest<>p_request_digest
       OR v_existing.request_id<>p_request_id
       OR v_existing.privacy_request_id<>p_privacy_request_id
       OR v_existing.transition_receipt_id<>p_transition_receipt_id
       OR v_existing.field_kind<>p_field_kind
       OR v_existing.actor_id<>p_actor_service_id THEN
      RAISE EXCEPTION 'privacy_sealed_content_erasure_idempotency_conflict'
        USING ERRCODE='40001';
    END IF;
    RETURN v_existing.receipt_payload||jsonb_build_object(
      'receiptDigest',btrim(v_existing.receipt_digest),
      'auditEventId',v_existing.audit_event_id,'replayed',true
    );
  END IF;

  -- Same lock domain as legal-hold placement prevents a hold from racing the
  -- zero-active-hold decision below.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_privacy_request_id::text,13)
  );
  SELECT * INTO v_content
  FROM ops.privacy_request_sealed_content_v2 AS content
  WHERE content.privacy_request_id=p_privacy_request_id
    AND content.transition_receipt_id=p_transition_receipt_id
    AND content.field_kind=p_field_kind
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_sealed_content_not_found'
      USING ERRCODE='P0002';
  END IF;
  v_now:=clock_timestamp();
  IF v_content.content_state<>'ACTIVE'
     OR v_content.sealed_ciphertext IS NULL THEN
    RAISE EXCEPTION 'privacy_sealed_content_not_active'
      USING ERRCODE='55000';
  END IF;
  IF v_now<v_content.expires_at THEN
    RAISE EXCEPTION 'privacy_sealed_content_erasure_not_due'
      USING ERRCODE='55000';
  END IF;

  SELECT * INTO v_schedule
  FROM ops.record_class_schedules AS schedule
  WHERE (schedule.id,schedule.record_class,schedule.schedule_digest)=(
    v_content.retention_schedule_id,v_content.retention_record_class,
    v_content.retention_schedule_digest
  )
  FOR SHARE;
  IF NOT FOUND
     OR v_schedule.record_class<>'PRIVACY_REQUEST_SEALED_CONTENT'
     OR v_schedule.trigger_kind<>'CREATED_AT'
     OR v_schedule.terminal_action<>'CRYPTO_ERASE'
     OR v_schedule.active_duration_seconds<=0
     OR v_schedule.backup_duration_seconds IS NULL
     OR v_schedule.hold_behavior NOT IN (
       'BLOCK_ON_RETENTION','BLOCK_ON_RETENTION_OR_DELETION'
     )
     OR v_schedule.restore_suppression_behavior<>'REAPPLY_BEFORE_ACCESS'
     OR v_schedule.effective_at>v_content.created_at
     OR v_schedule.review_expires_at<=v_content.created_at
     OR v_content.expires_at<>v_content.created_at
       +(v_schedule.active_duration_seconds*interval '1 second') THEN
    RAISE EXCEPTION 'privacy_sealed_content_erasure_authority_invalid'
      USING ERRCODE='55000';
  END IF;

  -- Fail closed: current 0038 has no authoritative privacy-request hold-state
  -- resolver.  ops.place_legal_hold_v2 and its receipt constraint do not admit
  -- PRIVACY_REQUEST, while legacy release_legal_hold_v1 can synthesize anchor
  -- and conflict rows.  editorial.legal_holds.active alone therefore cannot
  -- prove the exact V2 placement/release union or absence of blocking scope.
  -- Replace this gate only with a DB-authoritative resolver that locks the same
  -- request domain and returns a provenance-complete zero-active-hold receipt.
  -- Until then no erasure receipt, audit success, or ciphertext mutation is
  -- reachable; fabricating an empty hold set is forbidden.
  RAISE EXCEPTION 'privacy_sealed_content_hold_authority_unavailable'
    USING ERRCODE='55000';

  -- Unreachable integration skeleton for the future authoritative resolver:
  -- it must assign v_hold_set, v_hold_count=0, and v_hold_digest from the
  -- resolver's immutable receipt before the code below may be enabled.

  v_prior_binding_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'privacyRequestId',v_content.privacy_request_id,
      'transitionReceiptId',v_content.transition_receipt_id,
      'fieldKind',v_content.field_kind,
      'schemaVersion',v_content.schema_version,
      'contentState',v_content.content_state,
      'sealedSha256',btrim(v_content.sealed_sha256),
      'sealedAadDigest',btrim(v_content.sealed_aad_digest),
      'encryptionKeyId',v_content.encryption_key_id,
      'scheduleId',v_content.retention_schedule_id,
      'scheduleDigest',btrim(v_content.retention_schedule_digest),
      'createdAt',v_content.created_at,'expiresAt',v_content.expires_at
    )),'sha256'
  ),'hex');
  v_authorization_digest:=encode(extensions.digest(
    ops.canonical_jsonb_v1(jsonb_build_object(
      'schemaVersion','privacy-request-sealed-content-erasure-authority.v1',
      'scheduleId',v_schedule.id,'scheduleRevision',v_schedule.revision,
      'scheduleDigest',btrim(v_schedule.schedule_digest),
      'triggerKind',v_schedule.trigger_kind,
      'terminalAction',v_schedule.terminal_action,
      'activeDurationSeconds',v_schedule.active_duration_seconds,
      'backupDurationSeconds',v_schedule.backup_duration_seconds,
      'contentExpiresAt',v_content.expires_at,
      'evaluatedAt',v_now,'activeLegalHoldCount',v_hold_count,
      'legalHoldCoverageDigest',btrim(v_hold_digest),
      'actorType','SERVICE','actorId',p_actor_service_id
    )),'sha256'
  ),'hex');
  v_receipt_payload:=jsonb_build_object(
    'schemaVersion','privacy-request-sealed-content-erasure.v1',
    'erasureReceiptId',v_receipt_id,
    'privacyRequestId',v_content.privacy_request_id,
    'transitionReceiptId',v_content.transition_receipt_id,
    'fieldKind',v_content.field_kind,
    'priorContentState',v_content.content_state,
    'contentSchemaVersion',v_content.schema_version,
    'priorSealedSha256',btrim(v_content.sealed_sha256),
    'priorSealedAadDigest',btrim(v_content.sealed_aad_digest),
    'priorEncryptionKeyId',v_content.encryption_key_id,
    'priorContentBindingDigest',v_prior_binding_digest,
    'contentRetentionScheduleId',v_content.retention_schedule_id,
    'contentRetentionRecordClass',v_content.retention_record_class,
    'contentRetentionScheduleDigest',btrim(
      v_content.retention_schedule_digest
    ),
    'contentCreatedAt',v_content.created_at,
    'contentExpiresAt',v_content.expires_at,
    'authorizationEvidenceDigest',v_authorization_digest,
    'activeLegalHoldCount',v_hold_count,
    'legalHoldCoverageDigest',btrim(v_hold_digest),
    'actorType','SERVICE','actorId',p_actor_service_id,
    'requestId',p_request_id,
    'requestDigest',btrim(p_request_digest),
    'erasedAt',v_now
  );
  v_receipt_canonical:=ops.canonical_jsonb_v1(v_receipt_payload);
  v_receipt_digest:=encode(
    extensions.digest(v_receipt_canonical,'sha256'),'hex'
  );
  v_audit_event_id:=ops.append_audit_event(
    'privacy-sealed-erasure:'||v_content.transition_receipt_id::text
      ||':'||v_content.field_kind,
    'SERVICE',p_actor_service_id,NULL::uuid,
    'privacy.sealed_content.crypto_erase','PrivacyRequestSealedContent',
    v_content.transition_receipt_id::text||':'||v_content.field_kind,
    'privacy.retention.execute','SUCCESS',NULL,p_request_id,
    jsonb_build_object(
      'privacyRequestId',v_content.privacy_request_id,
      'transitionReceiptId',v_content.transition_receipt_id,
      'fieldKind',v_content.field_kind,
      'priorContentBindingDigest',v_prior_binding_digest,
      'authorizationEvidenceDigest',v_authorization_digest,
      'legalHoldCoverageDigest',btrim(v_hold_digest)
    )
  );

  INSERT INTO ops.privacy_request_sealed_content_erasure_receipts_v1(
    erasure_receipt_id,privacy_request_id,transition_receipt_id,field_kind,
    prior_content_state,content_schema_version,prior_sealed_sha256,
    prior_sealed_aad_digest,
    prior_encryption_key_id,prior_content_binding_digest,
    content_retention_schedule_id,content_retention_record_class,
    content_retention_schedule_digest,content_created_at,content_expires_at,
    authorization_evidence_digest,active_legal_hold_count,
    legal_hold_coverage_digest,actor_type,actor_id,request_id,
    idempotency_key_sha256,request_digest,audit_event_id,receipt_payload,
    receipt_canonical,receipt_digest,erased_at
  ) VALUES(
    v_receipt_id,v_content.privacy_request_id,
    v_content.transition_receipt_id,v_content.field_kind,
    v_content.content_state,v_content.schema_version,v_content.sealed_sha256,
    v_content.sealed_aad_digest,v_content.encryption_key_id,
    v_prior_binding_digest,v_content.retention_schedule_id,
    v_content.retention_record_class,v_content.retention_schedule_digest,
    v_content.created_at,v_content.expires_at,v_authorization_digest,
    v_hold_count,v_hold_digest,'SERVICE',p_actor_service_id,p_request_id,
    p_idempotency_key_sha256,p_request_digest,v_audit_event_id,
    v_receipt_payload,v_receipt_canonical,v_receipt_digest,v_now
  );

  PERFORM set_config('gurine.privacy_sealed_content_erasure','1',true);
  UPDATE ops.privacy_request_sealed_content_v2
  SET sealed_ciphertext=NULL,content_state='ERASED',erased_at=v_now,
      erasure_receipt_id=v_receipt_id,
      erasure_receipt_digest=v_receipt_digest
  WHERE privacy_request_id=v_content.privacy_request_id
    AND transition_receipt_id=v_content.transition_receipt_id
    AND field_kind=v_content.field_kind
    AND content_state='ACTIVE';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_sealed_content_erasure_concurrent_conflict'
      USING ERRCODE='40001';
  END IF;
  PERFORM set_config(
    'gurine.privacy_sealed_content_erasure',
    COALESCE(v_prior_erasure_guard,''),true
  );

  RETURN v_receipt_payload||jsonb_build_object(
    'receiptDigest',v_receipt_digest,
    'auditEventId',v_audit_event_id,'replayed',false
  );
END
$$;
ALTER FUNCTION ops.erase_privacy_request_sealed_content_v1(
  uuid,uuid,text,text,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.erase_privacy_request_sealed_content_v1(
  uuid,uuid,text,text,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.erase_privacy_request_sealed_content_v1(
  uuid,uuid,text,text,uuid,char(64),char(64)
) TO gurine_workflow_worker;

-- Safe-reader integration contract:
--   * join the exact request + transition + field_kind child key;
--   * require content_state='ACTIVE' and clock_timestamp()<expires_at;
--   * require child SHA/AAD/key-id to equal the parent metadata selected for
--     that field kind; the insertion trigger already enforces this, and the
--     update guard makes it immutable;
--   * return the ciphertext only through a narrowly granted SECURITY DEFINER
--     routine; do not grant notification-worker direct table SELECT;
--   * expired, ERASED, missing, duplicate, or parent-mismatched content returns
--     zero rows/fail-closed and never falls back to a receipt JSON field.
-- R6d privacy transition authority and business-day helpers begin.
-- Until apply_control_addendum_command is replaced to pass p_session_id to
-- transition_privacy_request_v2, retire the reachable legacy delegate rather
-- than allowing its plaintext/non-authoritative transition path to remain.
CREATE OR REPLACE FUNCTION ops.transition_retention_request_v1(
  p_payload jsonb,
  p_actor_id uuid,
  p_request_id uuid,
  p_idempotency_key char(64),
  p_request_digest char(64)
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $retired$
BEGIN
  RAISE EXCEPTION 'privacy_transition_v1_retired'
    USING ERRCODE='55000';
END
$retired$;
ALTER FUNCTION ops.transition_retention_request_v1(
  jsonb,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.transition_retention_request_v1(
  jsonb,uuid,uuid,char(64),char(64)
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION ops.add_privacy_business_days_v1(
  p_start_at timestamptz,
  p_business_days integer,
  p_calendar_version_id uuid,
  p_calendar_digest char(64)
) RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $business_days$
DECLARE
  v_calendar ops.business_calendar_versions%ROWTYPE;
  v_local_start timestamp without time zone;
  v_local_time time without time zone;
  v_candidate_date date;
  v_counted integer:=0;
  v_iterations bigint:=0;
  v_horizon bigint;
  v_result timestamptz;
BEGIN
  IF p_start_at IS NULL OR NOT isfinite(p_start_at)
     OR p_business_days IS NULL OR p_business_days<=0
     OR p_calendar_version_id IS NULL
     OR p_calendar_version_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_calendar_digest IS NULL
     OR NOT ops.r6d_lower_sha256(p_calendar_digest) THEN
    RAISE EXCEPTION 'privacy_business_day_input_invalid'
      USING ERRCODE='22023';
  END IF;

  SELECT calendar.* INTO v_calendar
  FROM ops.business_calendar_versions AS calendar
  WHERE calendar.id=p_calendar_version_id
    AND calendar.calendar_digest=p_calendar_digest;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_business_calendar_binding_missing'
      USING ERRCODE='23514';
  END IF;
  IF v_calendar.timezone<>'Asia/Seoul'
     OR cardinality(v_calendar.weekend_days) NOT BETWEEN 1 AND 6
     OR NOT v_calendar.weekend_days
       <@ ARRAY[0,1,2,3,4,5,6]::smallint[]
     OR cardinality(v_calendar.holiday_dates)>5000
     OR NOT ops.r6d_lower_sha256(v_calendar.holiday_set_digest)
     OR NOT ops.r6d_lower_sha256(v_calendar.policy_digest)
     OR NOT isfinite(v_calendar.effective_at)
     OR NOT isfinite(v_calendar.review_expires_at)
     OR v_calendar.review_expires_at<=v_calendar.effective_at THEN
    RAISE EXCEPTION 'privacy_business_calendar_binding_invalid'
      USING ERRCODE='23514';
  END IF;

  v_local_start:=p_start_at AT TIME ZONE 'Asia/Seoul';
  v_local_time:=v_local_start::time without time zone;
  v_candidate_date:=v_local_start::date;
  -- At most six of seven weekdays are excluded.  Each unique holiday can
  -- suppress at most one otherwise-countable day, so this is a mechanical
  -- termination bound rather than a policy-day constant.
  v_horizon:=8*(p_business_days::bigint+
    COALESCE(cardinality(v_calendar.holiday_dates),0)::bigint+1);

  BEGIN
    WHILE v_counted<p_business_days LOOP
      v_iterations:=v_iterations+1;
      IF v_iterations>v_horizon THEN
        RAISE EXCEPTION 'privacy_business_calendar_horizon_exceeded'
          USING ERRCODE='23514';
      END IF;
      v_candidate_date:=v_candidate_date+1;
      IF NOT extract(dow FROM v_candidate_date)::smallint
             =ANY(v_calendar.weekend_days)
         AND NOT v_candidate_date=ANY(v_calendar.holiday_dates) THEN
        v_counted:=v_counted+1;
      END IF;
    END LOOP;
    v_result:=(v_candidate_date+v_local_time)
      AT TIME ZONE 'Asia/Seoul';
  EXCEPTION WHEN datetime_field_overflow OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'privacy_business_calendar_horizon_exceeded'
      USING ERRCODE='23514';
  END;

  IF v_result IS NULL OR NOT isfinite(v_result) OR v_result<=p_start_at THEN
    RAISE EXCEPTION 'privacy_business_calendar_result_invalid'
      USING ERRCODE='23514';
  END IF;
  RETURN v_result;
END
$business_days$;
ALTER FUNCTION ops.add_privacy_business_days_v1(
  timestamptz,integer,uuid,char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.add_privacy_business_days_v1(
  timestamptz,integer,uuid,char(64)
) FROM PUBLIC;

-- R6d privacy transition owner and typed dispatcher integration begins.
-- Keep the runtime event catalog byte-for-byte traceable to the external
-- authority before admitting the decision event used by successful review
-- and refusal transitions.  The byte digest includes the file's final LF.
DO $decision_event_registry$
DECLARE
  v_schema_text text:=$decision_schema${
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://gurine.invalid/events/privacy.request_decision_recorded.v1.schema.json",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "retentionRequestId",
    "decisionVersion",
    "transition",
    "priorState",
    "state",
    "inventorySnapshotDigest",
    "holdCoverageDigest",
    "decisionDigest",
    "receiptDigest"
  ],
  "properties": {
    "retentionRequestId": { "type": "string", "format": "uuid" },
    "decisionVersion": { "type": "integer", "minimum": 0 },
    "transition": {
      "type": "string",
      "enum": ["START_REVIEW", "APPROVE", "REJECT"]
    },
    "priorState": {
      "type": "string",
      "enum": ["RECEIVED", "REVIEW"]
    },
    "state": {
      "type": "string",
      "enum": ["REVIEW", "APPROVED", "REJECTED"]
    },
    "inventorySnapshotDigest": {
      "type": ["string", "null"],
      "pattern": "^[0-9a-f]{64}$"
    },
    "holdCoverageDigest": {
      "type": ["string", "null"],
      "pattern": "^[0-9a-f]{64}$"
    },
    "decisionDigest": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
    "receiptDigest": { "type": "string", "pattern": "^[0-9a-f]{64}$" }
  },
  "oneOf": [
    {
      "properties": {
        "transition": { "const": "START_REVIEW" },
        "priorState": { "const": "RECEIVED" },
        "state": { "const": "REVIEW" },
        "inventorySnapshotDigest": { "type": "null" },
        "holdCoverageDigest": { "type": "null" }
      }
    },
    {
      "properties": {
        "transition": { "const": "APPROVE" },
        "priorState": { "const": "REVIEW" },
        "state": { "const": "APPROVED" },
        "inventorySnapshotDigest": {
          "type": "string",
          "pattern": "^[0-9a-f]{64}$"
        },
        "holdCoverageDigest": {
          "type": "string",
          "pattern": "^[0-9a-f]{64}$"
        }
      }
    },
    {
      "properties": {
        "transition": { "const": "REJECT" },
        "priorState": { "const": "REVIEW" },
        "state": { "const": "REJECTED" },
        "inventorySnapshotDigest": { "type": "null" },
        "holdCoverageDigest": { "type": "null" }
      }
    }
  ]
}
$decision_schema$;
  v_schema jsonb;
  v_schema_sha256 char(64);
BEGIN
  v_schema_sha256:=encode(extensions.digest(
    convert_to(v_schema_text,'UTF8'),'sha256'
  ),'hex');
  IF v_schema_sha256<>
     'ea318383c422604d9d15bdbb8add62f960b405dc801d2a1ce11f4ba0fd1311fe'
     THEN
    RAISE EXCEPTION 'privacy_decision_event_schema_bytes_invalid'
      USING ERRCODE='55000';
  END IF;
  v_schema:=v_schema_text::jsonb;
  INSERT INTO ops.event_types(
    event_type,category,schema_version,active,
    payload_schema_uri,payload_schema
  ) VALUES(
    'privacy.request_decision_recorded.v1','DOMAIN',1,true,
    'payloads/privacy_request_decision_recorded_v1.schema.json',v_schema
  )
  ON CONFLICT(event_type) DO UPDATE SET
    category=EXCLUDED.category,
    schema_version=EXCLUDED.schema_version,
    active=EXCLUDED.active,
    payload_schema_uri=EXCLUDED.payload_schema_uri,
    payload_schema=EXCLUDED.payload_schema;
  IF NOT EXISTS(
    SELECT 1 FROM ops.event_types AS event_type
    WHERE event_type.event_type='privacy.request_decision_recorded.v1'
      AND event_type.category='DOMAIN'
      AND event_type.schema_version=1
      AND event_type.active
      AND event_type.payload_schema_uri=
        'payloads/privacy_request_decision_recorded_v1.schema.json'
      AND event_type.payload_schema=v_schema
  ) THEN
    RAISE EXCEPTION 'privacy_decision_event_catalog_invalid'
      USING ERRCODE='55000';
  END IF;
END
$decision_event_registry$;

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
SET search_path=pg_catalog,ops,intake,extensions,pg_temp
AS $transition$
DECLARE
  v_now timestamptz:=clock_timestamp();
  v_key_count integer;
  v_transition text;
  v_expected_decision_version bigint;
  v_privacy_request_id uuid;
  v_transition_receipt_id uuid;
  v_identity_proof_receipt_id uuid;
  v_extension_business_days integer;
  v_reason_code text;
  v_reason_ciphertext bytea;
  v_reason_sha256 char(64);
  v_reason_aad_digest char(64);
  v_extension_reason_code text;
  v_extension_reason_ciphertext bytea;
  v_extension_reason_sha256 char(64);
  v_extension_reason_aad_digest char(64);
  v_rejection_reason_code text;
  v_rejection_reason_ciphertext bytea;
  v_rejection_reason_sha256 char(64);
  v_rejection_reason_aad_digest char(64);
  v_appeal_instructions_ciphertext bytea;
  v_appeal_instructions_sha256 char(64);
  v_appeal_instructions_aad_digest char(64);
  v_encryption_key_id text;
  v_actor_assertion_jti uuid;
  v_actor_effective_capability text;
  v_actor_action_digest char(64);
  v_step_up_authorization_id uuid;
  v_actor_idempotency_key_sha256 char(64);
  v_actor_request_key_sha256 char(64);
  v_scope text;
  v_idempotency ops.idempotency_keys%ROWTYPE;
  v_step_up ops.step_up_authorizations%ROWTYPE;
  v_request ops.privacy_requests_v2%ROWTYPE;
  v_identity ops.privacy_request_identity_receipts_v2%ROWTYPE;
  v_policy_reference jsonb;
  v_policy ops.privacy_response_calendar_policies_v1%ROWTYPE;
  v_calendar ops.business_calendar_versions%ROWTYPE;
  v_endpoint intake.communication_endpoints%ROWTYPE;
  v_decision_version bigint;
  v_prior_state text;
  v_state text;
  v_prior_due_at timestamptz;
  v_due_at timestamptz;
  v_notice_due_at timestamptz;
  v_extension_sequence integer;
  v_extension_count bigint;
  v_extension_max_sequence integer;
  v_notice_sequence bigint;
  v_notice_count bigint;
  v_notice_max_sequence bigint;
  v_extension_receipt_id uuid;
  v_refusal_receipt_id uuid;
  v_notice_receipt_id uuid;
  v_audit_event_id uuid;
  v_decision_event_id uuid;
  v_notification_event_id uuid;
  v_primary_event_id uuid;
  v_primary_event_digest char(64);
  v_outbox_event_ids uuid[];
  v_decision_payload jsonb;
  v_decision_digest char(64);
  v_branch_payload jsonb;
  v_branch_canonical bytea;
  v_branch_digest char(64);
  v_notice_template_payload jsonb;
  v_notice_template_digest char(64);
  v_notice_sha256 char(64);
  v_notice_aad_digest char(64);
  v_notice_payload jsonb;
  v_notice_canonical bytea;
  v_notice_digest char(64);
  v_transition_payload jsonb;
  v_transition_canonical bytea;
  v_transition_digest char(64);
  v_event_payload jsonb;
  v_transition_response jsonb;
  v_result jsonb;
  v_affected integer;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
     OR p_actor_id IS NULL
     OR p_actor_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_session_id IS NULL
     OR p_session_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_request_id IS NULL
     OR p_request_id='00000000-0000-0000-0000-000000000000'::uuid
     OR p_idempotency_key_sha256 IS NULL
     OR NOT ops.r6d_lower_sha256(p_idempotency_key_sha256)
     OR p_request_sha256 IS NULL
     OR NOT ops.r6d_lower_sha256(p_request_sha256) THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid' USING ERRCODE='22023';
  END IF;
  IF current_setting('transaction_isolation')<>'serializable' THEN
    RAISE EXCEPTION 'privacy_transition_requires_serializable'
      USING ERRCODE='25001';
  END IF;

  v_transition:=p_payload->>'transition';
  SELECT count(*) INTO v_key_count FROM jsonb_object_keys(p_payload);
  IF v_transition NOT IN (
       'VERIFY_IDENTITY','START_REVIEW','APPROVE','REJECT','EXTEND'
     )
     OR v_key_count<>(CASE v_transition
       WHEN 'VERIFY_IDENTITY' THEN 15
       WHEN 'START_REVIEW' THEN 14
       WHEN 'APPROVE' THEN 14
       WHEN 'EXTEND' THEN 18
       WHEN 'REJECT' THEN 19
       ELSE -1 END)
     OR NOT p_payload ?& ARRAY[
       'retentionRequestId','expectedDecisionVersion','transition',
       'reasonCode','reasonCiphertextBase64','reasonSha256',
       'transitionReceiptId',
       '_actorAssertionJti','_actorAssuranceLevel','_actorEffectiveCapability',
       '_actorActionDigest',
       '_actorStepUpAuthorizationId','_actorIdempotencyKeySha256',
       '_actorRequestKeySha256'
     ]
     OR jsonb_typeof(p_payload->'retentionRequestId')<>'string'
     OR jsonb_typeof(p_payload->'expectedDecisionVersion')<>'number'
     OR p_payload->>'expectedDecisionVersion' !~ '^(0|[1-9][0-9]{0,18})$'
     OR jsonb_typeof(p_payload->'transition')<>'string'
     OR jsonb_typeof(p_payload->'reasonCode')<>'string'
     OR jsonb_typeof(p_payload->'reasonCiphertextBase64')<>'string'
     OR p_payload->>'reasonCiphertextBase64' !~ '^[A-Za-z0-9+/]+={0,2}$'
     OR length(p_payload->>'reasonCiphertextBase64')%4<>0
     OR jsonb_typeof(p_payload->'reasonSha256')<>'string'
     OR jsonb_typeof(p_payload->'transitionReceiptId')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssertionJti')<>'string'
     OR jsonb_typeof(p_payload->'_actorAssuranceLevel')<>'string'
     OR jsonb_typeof(p_payload->'_actorEffectiveCapability')<>'string'
     OR jsonb_typeof(p_payload->'_actorActionDigest')<>'string'
     OR jsonb_typeof(p_payload->'_actorStepUpAuthorizationId')<>'string'
     OR jsonb_typeof(p_payload->'_actorIdempotencyKeySha256')<>'string'
     OR jsonb_typeof(p_payload->'_actorRequestKeySha256')<>'string'
     OR NOT ops.r6d_lower_sha256(p_payload->>'reasonSha256')
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorActionDigest')
     OR NOT ops.r6d_lower_sha256(
       p_payload->>'_actorIdempotencyKeySha256'
     )
     OR NOT ops.r6d_lower_sha256(p_payload->>'_actorRequestKeySha256')
     OR p_payload->>'_actorAssuranceLevel'<>'STEP_UP'
     OR p_payload->>'_actorEffectiveCapability'<>'privacy.requests.manage' THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid' USING ERRCODE='22023';
  END IF;

  IF (v_transition='VERIFY_IDENTITY' AND (
        NOT p_payload ? 'identityProofReceiptId'
        OR jsonb_typeof(p_payload->'identityProofReceiptId')<>'string'
      ))
     OR (v_transition='EXTEND' AND (
        NOT p_payload ?& ARRAY[
          'extensionReasonCode','extensionReasonCiphertextBase64',
          'extensionReasonSha256','extensionBusinessDays'
        ]
        OR jsonb_typeof(p_payload->'extensionReasonCode')<>'string'
        OR jsonb_typeof(
          p_payload->'extensionReasonCiphertextBase64'
        )<>'string'
        OR p_payload->>'extensionReasonCiphertextBase64'
          !~ '^[A-Za-z0-9+/]+={0,2}$'
        OR length(p_payload->>'extensionReasonCiphertextBase64')%4<>0
        OR jsonb_typeof(p_payload->'extensionReasonSha256')<>'string'
        OR NOT ops.r6d_lower_sha256(
          p_payload->>'extensionReasonSha256'
        )
        OR jsonb_typeof(p_payload->'extensionBusinessDays')<>'number'
        OR p_payload->>'extensionBusinessDays' !~ '^[1-9][0-9]{0,9}$'
      ))
     OR (v_transition='REJECT' AND (
        NOT p_payload ?& ARRAY[
          'rejectionReasonCode','rejectionReasonCiphertextBase64',
          'rejectionReasonSha256','appealInstructionsCiphertextBase64',
          'appealInstructionsSha256'
        ]
        OR jsonb_typeof(p_payload->'rejectionReasonCode')<>'string'
        OR jsonb_typeof(
          p_payload->'rejectionReasonCiphertextBase64'
        )<>'string'
        OR p_payload->>'rejectionReasonCiphertextBase64'
          !~ '^[A-Za-z0-9+/]+={0,2}$'
        OR length(p_payload->>'rejectionReasonCiphertextBase64')%4<>0
        OR jsonb_typeof(p_payload->'rejectionReasonSha256')<>'string'
        OR NOT ops.r6d_lower_sha256(
          p_payload->>'rejectionReasonSha256'
        )
        OR jsonb_typeof(
          p_payload->'appealInstructionsCiphertextBase64'
        )<>'string'
        OR p_payload->>'appealInstructionsCiphertextBase64'
          !~ '^[A-Za-z0-9+/]+={0,2}$'
        OR length(p_payload->>'appealInstructionsCiphertextBase64')%4<>0
        OR jsonb_typeof(p_payload->'appealInstructionsSha256')<>'string'
        OR NOT ops.r6d_lower_sha256(
          p_payload->>'appealInstructionsSha256'
        )
      )) THEN
    RAISE EXCEPTION 'privacy_transition_variant_invalid' USING ERRCODE='22023';
  END IF;

  BEGIN
    v_privacy_request_id:=(p_payload->>'retentionRequestId')::uuid;
    v_expected_decision_version:=
      (p_payload->>'expectedDecisionVersion')::bigint;
    v_transition_receipt_id:=(p_payload->>'transitionReceiptId')::uuid;
    v_actor_assertion_jti:=(p_payload->>'_actorAssertionJti')::uuid;
    v_step_up_authorization_id:=
      (p_payload->>'_actorStepUpAuthorizationId')::uuid;
    IF v_transition='VERIFY_IDENTITY' THEN
      v_identity_proof_receipt_id:=
        (p_payload->>'identityProofReceiptId')::uuid;
    ELSIF v_transition='EXTEND' THEN
      v_extension_business_days:=
        (p_payload->>'extensionBusinessDays')::integer;
    END IF;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid' USING ERRCODE='22023';
  END;

  v_reason_code:=p_payload->>'reasonCode';
  v_actor_effective_capability:=p_payload->>'_actorEffectiveCapability';
  BEGIN
    v_reason_ciphertext:=decode(
      p_payload->>'reasonCiphertextBase64','base64'
    );
    v_encryption_key_id:=split_part(
      convert_from(v_reason_ciphertext,'UTF8'),'.',2
    );
  EXCEPTION
    WHEN invalid_parameter_value OR character_not_in_repertoire
      OR untranslatable_character THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid' USING ERRCODE='22023';
  END;
  v_reason_sha256:=(p_payload->>'reasonSha256')::char(64);
  v_actor_action_digest:=
    (p_payload->>'_actorActionDigest')::char(64);
  v_actor_idempotency_key_sha256:=
    (p_payload->>'_actorIdempotencyKeySha256')::char(64);
  v_actor_request_key_sha256:=
    (p_payload->>'_actorRequestKeySha256')::char(64);
  v_reason_aad_digest:=ops.r6d_nul5_sha256_v1(
    'ops.privacy_request_sealed_content_v2','sealed_ciphertext',
    v_transition_receipt_id::text,'REASON','1'
  );

  IF v_privacy_request_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_transition_receipt_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_actor_assertion_jti=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_step_up_authorization_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR v_actor_effective_capability<>'privacy.requests.manage'
     OR char_length(v_reason_code) NOT BETWEEN 1 AND 100
     OR btrim(v_reason_code)<>v_reason_code
     OR octet_length(v_reason_ciphertext) NOT BETWEEN 1 AND 65536
     OR replace(encode(v_reason_ciphertext,'base64'),E'\n','')
          IS DISTINCT FROM p_payload->>'reasonCiphertextBase64'
     OR length(v_encryption_key_id) NOT BETWEEN 1 AND 200
     OR btrim(v_encryption_key_id)<>v_encryption_key_id
     OR NOT ops.r6d_lower_sha256(v_reason_sha256)
     OR NOT ops.r6d_lower_sha256(v_actor_action_digest)
     OR NOT ops.r6d_lower_sha256(v_actor_idempotency_key_sha256)
     OR NOT ops.r6d_lower_sha256(v_actor_request_key_sha256)
     OR v_actor_idempotency_key_sha256<>p_idempotency_key_sha256
     OR v_actor_request_key_sha256<>p_idempotency_key_sha256
     OR NOT ops.r6d_field_envelope_v1_is_valid(
       v_reason_ciphertext,v_encryption_key_id
     ) THEN
    RAISE EXCEPTION 'privacy_transition_input_invalid' USING ERRCODE='22023';
  END IF;

  IF v_transition='VERIFY_IDENTITY' AND
     v_identity_proof_receipt_id=
       '00000000-0000-0000-0000-000000000000'::uuid THEN
    RAISE EXCEPTION 'privacy_transition_variant_invalid' USING ERRCODE='22023';
  ELSIF v_transition='EXTEND' THEN
    v_extension_reason_code:=p_payload->>'extensionReasonCode';
    BEGIN
      v_extension_reason_ciphertext:=decode(
        p_payload->>'extensionReasonCiphertextBase64','base64'
      );
    EXCEPTION WHEN invalid_parameter_value THEN
      RAISE EXCEPTION 'privacy_transition_variant_invalid'
        USING ERRCODE='22023';
    END;
    v_extension_reason_sha256:=
      (p_payload->>'extensionReasonSha256')::char(64);
    v_extension_reason_aad_digest:=ops.r6d_nul5_sha256_v1(
      'ops.privacy_request_sealed_content_v2','sealed_ciphertext',
      v_transition_receipt_id::text,'EXTENSION_REASON','1'
    );
    IF char_length(v_extension_reason_code) NOT BETWEEN 1 AND 100
       OR btrim(v_extension_reason_code)<>v_extension_reason_code
       OR v_extension_business_days<=0
       OR octet_length(v_extension_reason_ciphertext) NOT BETWEEN 1 AND 65536
       OR replace(encode(v_extension_reason_ciphertext,'base64'),E'\n','')
            IS DISTINCT FROM p_payload->>'extensionReasonCiphertextBase64'
       OR NOT ops.r6d_lower_sha256(v_extension_reason_sha256)
       OR NOT ops.r6d_field_envelope_v1_is_valid(
         v_extension_reason_ciphertext,v_encryption_key_id
       ) THEN
      RAISE EXCEPTION 'privacy_transition_variant_invalid' USING ERRCODE='22023';
    END IF;
  ELSIF v_transition='REJECT' THEN
    v_rejection_reason_code:=p_payload->>'rejectionReasonCode';
    BEGIN
      v_rejection_reason_ciphertext:=decode(
        p_payload->>'rejectionReasonCiphertextBase64','base64'
      );
      v_appeal_instructions_ciphertext:=decode(
        p_payload->>'appealInstructionsCiphertextBase64','base64'
      );
    EXCEPTION WHEN invalid_parameter_value THEN
      RAISE EXCEPTION 'privacy_transition_variant_invalid'
        USING ERRCODE='22023';
    END;
    v_rejection_reason_sha256:=
      (p_payload->>'rejectionReasonSha256')::char(64);
    v_appeal_instructions_sha256:=
      (p_payload->>'appealInstructionsSha256')::char(64);
    v_rejection_reason_aad_digest:=ops.r6d_nul5_sha256_v1(
      'ops.privacy_request_sealed_content_v2','sealed_ciphertext',
      v_transition_receipt_id::text,'REJECTION_REASON','1'
    );
    v_appeal_instructions_aad_digest:=ops.r6d_nul5_sha256_v1(
      'ops.privacy_request_sealed_content_v2','sealed_ciphertext',
      v_transition_receipt_id::text,'APPEAL_INSTRUCTIONS','1'
    );
    IF char_length(v_rejection_reason_code) NOT BETWEEN 1 AND 100
       OR btrim(v_rejection_reason_code)<>v_rejection_reason_code
       OR octet_length(v_rejection_reason_ciphertext) NOT BETWEEN 1 AND 65536
       OR octet_length(v_appeal_instructions_ciphertext)
         NOT BETWEEN 1 AND 65536
       OR replace(encode(v_rejection_reason_ciphertext,'base64'),E'\n','')
            IS DISTINCT FROM p_payload->>'rejectionReasonCiphertextBase64'
       OR replace(encode(v_appeal_instructions_ciphertext,'base64'),E'\n','')
            IS DISTINCT FROM p_payload->>'appealInstructionsCiphertextBase64'
       OR NOT ops.r6d_lower_sha256(v_rejection_reason_sha256)
       OR NOT ops.r6d_lower_sha256(v_appeal_instructions_sha256)
       OR NOT ops.r6d_field_envelope_v1_is_valid(
         v_rejection_reason_ciphertext,v_encryption_key_id
       )
       OR NOT ops.r6d_field_envelope_v1_is_valid(
         v_appeal_instructions_ciphertext,v_encryption_key_id
       ) THEN
      RAISE EXCEPTION 'privacy_transition_variant_invalid' USING ERRCODE='22023';
    END IF;
  END IF;

  -- The Control API has already claimed this exact row in the surrounding
  -- SERIALIZABLE transaction.  This owner never creates, renews, or rewrites
  -- the claim and never treats a partial stored response as a replay.
  v_scope:='control:'||p_actor_id::text||':transitionRetentionRequest';
  SELECT key_row.* INTO v_idempotency
  FROM ops.idempotency_keys AS key_row
  WHERE key_row.scope=v_scope
    AND key_row.key_hash=p_idempotency_key_sha256
  FOR UPDATE;
  IF NOT FOUND
     OR v_idempotency.expires_at<=v_now
     OR v_idempotency.request_hash<>p_request_sha256
     OR num_nonnulls(
       v_idempotency.response_status,v_idempotency.response_body,
       v_idempotency.resource_type,v_idempotency.resource_id
     )<>0 THEN
    RAISE EXCEPTION 'privacy_transition_idempotency_conflict'
      USING ERRCODE='40001';
  END IF;

  -- Revalidate the signed STEP_UP authorization instead of trusting injected
  -- fields merely because the HTTP boundary produced them.
  SELECT step_up_authorization.* INTO v_step_up
  FROM ops.step_up_authorizations AS step_up_authorization
  WHERE step_up_authorization.id=v_step_up_authorization_id
  FOR SHARE;
  IF NOT FOUND OR v_step_up.closed_at IS NOT NULL
     OR v_step_up.session_id<>p_session_id
     OR v_step_up.expires_at<=v_now
     OR v_step_up.action_digest<>v_actor_action_digest
     OR v_step_up.idempotency_key_sha256<>
       v_actor_idempotency_key_sha256
     OR v_step_up.assertion_issue_count NOT BETWEEN 1 AND 3
     OR v_step_up.last_issued_at IS NULL
     OR v_step_up.last_issued_at>v_now
     OR v_step_up.last_issued_at>=v_step_up.expires_at
     OR v_step_up.expires_at>
       v_step_up.last_issued_at+interval '5 minutes 5 seconds'
     OR NOT EXISTS(
       SELECT 1 FROM ops.sessions AS session
       WHERE session.id=p_session_id
         AND session.user_id=p_actor_id
         AND session.revoked_at IS NULL
         AND session.expires_at>v_now
     ) THEN
    RAISE EXCEPTION 'privacy_transition_step_up_invalid'
      USING ERRCODE='42501';
  END IF;

  SELECT request.* INTO v_request
  FROM ops.privacy_requests_v2 AS request
  WHERE request.id=v_privacy_request_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'privacy_transition_request_not_found'
      USING ERRCODE='P0002';
  END IF;
  IF v_request.decision_version<>v_expected_decision_version THEN
    RAISE EXCEPTION 'privacy_transition_version_conflict'
      USING ERRCODE='PVT08';
  END IF;
  PERFORM receipt.transition_receipt_id
  FROM ops.privacy_request_transition_receipts_v2 AS receipt
  WHERE receipt.privacy_request_id=v_privacy_request_id
  ORDER BY receipt.decision_version
  FOR UPDATE;
  IF EXISTS(
       SELECT 1 FROM ops.privacy_request_transition_receipts_v2 AS receipt
       WHERE receipt.transition_receipt_id=v_transition_receipt_id
          OR receipt.actor_assertion_jti=v_actor_assertion_jti
          OR receipt.step_up_authorization_id=v_step_up_authorization_id
          OR receipt.idempotency_key_sha256=p_idempotency_key_sha256
     ) THEN
    RAISE EXCEPTION 'privacy_transition_receipt_identity_conflict'
      USING ERRCODE='40001';
  END IF;

  CASE v_transition
    WHEN 'VERIFY_IDENTITY' THEN
      IF v_request.state<>'RECEIVED'
         OR v_request.identity_state<>'PENDING_VERIFICATION'
         OR v_request.identity_verified_at IS NOT NULL
         OR v_request.due_at IS NOT NULL THEN
        RAISE EXCEPTION 'privacy_transition_state_invalid'
          USING ERRCODE='23514';
      END IF;
      -- A UUID's existence is not proof that it verifies this subject/scope.
      RAISE EXCEPTION 'privacy_identity_proof_authority_missing'
        USING ERRCODE='55000';
    WHEN 'START_REVIEW' THEN
      IF v_request.state<>'RECEIVED'
         OR v_request.identity_state<>'VERIFIED'
         OR v_request.identity_verified_at IS NULL
         OR v_request.due_at IS NULL
         OR num_nonnulls(
           v_request.response_policy_id,v_request.response_policy_revision,
           v_request.response_policy_digest,v_request.calendar_version_id,
           v_request.calendar_digest,v_request.current_identity_receipt_id,
           v_request.current_identity_receipt_digest
         )<>7 THEN
        RAISE EXCEPTION 'privacy_transition_state_invalid'
          USING ERRCODE='23514';
      END IF;
    WHEN 'APPROVE' THEN
      IF v_request.state<>'REVIEW'
         OR v_request.identity_state<>'VERIFIED'
         OR v_request.identity_verified_at IS NULL
         OR v_request.due_at IS NULL THEN
        RAISE EXCEPTION 'privacy_transition_state_invalid'
          USING ERRCODE='23514';
      END IF;
      -- Inventory precedes hold evaluation.  The current /tmp legal-hold
      -- helper is not an authoritative privacy-request coverage producer and
      -- must not be called or promoted.  After inventory authority exists, a
      -- separate coverage authority is still required before this edge opens.
      RAISE EXCEPTION 'privacy_inventory_snapshot_authority_missing'
        USING ERRCODE='55000';
    WHEN 'REJECT' THEN
      IF v_request.state<>'REVIEW'
         OR v_request.identity_state<>'VERIFIED'
         OR v_request.identity_verified_at IS NULL
         OR v_request.due_at IS NULL THEN
        RAISE EXCEPTION 'privacy_transition_state_invalid'
          USING ERRCODE='23514';
      END IF;
    WHEN 'EXTEND' THEN
      IF v_request.state NOT IN ('RECEIVED','REVIEW','APPROVED')
         OR v_request.identity_state<>'VERIFIED'
         OR v_request.identity_verified_at IS NULL
         OR v_request.due_at IS NULL THEN
        RAISE EXCEPTION 'privacy_transition_state_invalid'
          USING ERRCODE='23514';
      END IF;
      IF v_request.due_at<=v_now THEN
        RAISE EXCEPTION 'privacy_extension_notice_expired'
          USING ERRCODE='23514';
      END IF;
  END CASE;

  v_decision_version:=v_request.decision_version+1;
  v_prior_state:=v_request.state;
  v_state:=CASE v_transition
    WHEN 'START_REVIEW' THEN 'REVIEW'
    WHEN 'REJECT' THEN 'REJECTED'
    ELSE v_request.state
  END;
  v_prior_due_at:=v_request.due_at;
  v_due_at:=v_request.due_at;

  SELECT identity.* INTO v_identity
  FROM ops.privacy_request_identity_receipts_v2 AS identity
  WHERE identity.identity_receipt_id=v_request.current_identity_receipt_id
    AND identity.privacy_request_id=v_request.id
    AND identity.receipt_digest=v_request.current_identity_receipt_digest
  FOR SHARE;
  IF NOT FOUND
     OR v_identity.decision_version NOT BETWEEN 1 AND v_request.decision_version
     OR v_identity.identity_state<>'VERIFIED'
     OR v_identity.identity_verified_at<>v_request.identity_verified_at
     OR v_identity.response_policy_id IS NULL
     OR v_identity.response_policy_revision IS NULL
     OR v_identity.response_policy_digest IS NULL
     OR v_identity.calendar_version_id IS NULL
     OR v_identity.calendar_digest IS NULL THEN
    RAISE EXCEPTION 'privacy_identity_receipt_chain_invalid'
      USING ERRCODE='23514';
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
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'privacy_response_policy_calendar_binding_invalid'
        USING ERRCODE='55000';
    END IF;
    SELECT calendar.* INTO v_calendar
    FROM ops.business_calendar_versions AS calendar
    WHERE calendar.id=(v_policy_reference->>'calendarVersionId')::uuid
      AND calendar.calendar_digest=v_policy_reference->>'calendarDigest'
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'privacy_response_policy_calendar_binding_invalid'
        USING ERRCODE='55000';
    END IF;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range
    OR datetime_field_overflow THEN
    RAISE EXCEPTION 'privacy_response_policy_calendar_binding_invalid'
      USING ERRCODE='55000';
  END;
  IF v_policy.state<>'APPROVED'
     OR v_policy.timezone<>'Asia/Seoul'
     OR v_policy.effective_at>v_now
     OR v_policy.review_expires_at<=v_now
     OR v_policy.calendar_id<>v_calendar.id
     OR v_policy.policy_version<>v_policy_reference->>'policyVersion'
     OR btrim(v_policy.policy_digest)<>
       v_policy_reference->>'policyDigest'
     OR btrim(v_policy.binding_digest)<>
       v_policy_reference->>'policyBindingDigest'
     OR v_policy.access_business_days<>
       (v_policy_reference->>'accessBusinessDays')::integer
     OR v_policy.correction_business_days<>
       (v_policy_reference->>'correctionBusinessDays')::integer
     OR v_policy.deletion_business_days<>
       (v_policy_reference->>'deletionBusinessDays')::integer
     OR v_policy.restriction_business_days<>
       (v_policy_reference->>'restrictionBusinessDays')::integer
     OR v_policy.maximum_extension_business_days<>
       (v_policy_reference->>'maximumExtensionBusinessDays')::integer
     OR v_policy.maximum_extension_count<>
       (v_policy_reference->>'maximumExtensionCount')::integer
     OR v_policy.refusal_notice_business_days<>
       (v_policy_reference->>'refusalNoticeBusinessDays')::integer
     OR v_calendar.calendar_id<>
       (v_policy_reference->>'calendarId')::uuid
     OR v_calendar.version<>
       (v_policy_reference->>'calendarVersion')::bigint
     OR v_calendar.timezone<>'Asia/Seoul'
     OR v_calendar.effective_at>v_now
     OR v_calendar.review_expires_at<=v_now
     OR v_calendar.policy_digest<>v_policy.policy_digest
     OR v_policy.policy_payload->>'calendarVersionId'<>v_calendar.id::text
     OR v_policy.policy_payload->>'calendarDigest'<>
       btrim(v_calendar.calendar_digest)
     OR NOT ops.privacy_response_policy_calendar_authority_v1_is_valid(
       v_policy.policy_id,v_policy.revision
     ) THEN
    RAISE EXCEPTION 'privacy_response_policy_calendar_binding_invalid'
      USING ERRCODE='55000';
  END IF;

  -- Every successful transition remains on the policy/calendar authority
  -- sealed by its current identity receipt.  Silently rebinding the root to a
  -- newer pair would leave current_identity_receipt_* pointing at stale proof.
  IF ROW(
       v_request.response_policy_id,v_request.response_policy_revision,
       v_request.response_policy_digest,v_request.calendar_version_id,
       v_request.calendar_digest
     ) IS DISTINCT FROM ROW(
       v_policy.policy_id,v_policy.revision,v_policy.policy_digest,
       v_calendar.id,v_calendar.calendar_digest
     )
     OR ROW(
       v_identity.response_policy_id,v_identity.response_policy_revision,
       v_identity.response_policy_digest,v_identity.calendar_version_id,
       v_identity.calendar_digest
     ) IS DISTINCT FROM ROW(
       v_policy.policy_id,v_policy.revision,v_policy.policy_digest,
       v_calendar.id,v_calendar.calendar_digest
     ) THEN
    RAISE EXCEPTION 'BUSINESS_CALENDAR_STALE'
      USING ERRCODE='23514';
  END IF;

  IF v_transition IN ('EXTEND','REJECT') THEN
    SELECT endpoint.* INTO v_endpoint
    FROM intake.communication_endpoints AS endpoint
    WHERE endpoint.id=v_request.communication_endpoint_id
      AND endpoint.subject_id=v_request.communication_subject_id
      AND endpoint.version=v_request.communication_endpoint_version
      AND endpoint.endpoint_digest=v_request.communication_endpoint_digest
    FOR SHARE;
    IF NOT FOUND
       OR v_endpoint.state<>'ACTIVE'
       OR v_endpoint.revoked_at IS NOT NULL
       OR v_endpoint.updated_at>v_now
       OR v_endpoint.channel NOT IN (
         'SMTP_EMAIL','TELEGRAM_BOT_API',
         'META_WHATSAPP_BUSINESS_CLOUD','LINE_MESSAGING_API',
         'SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE'
       )
       OR NOT ops.r6d_field_envelope_v1_is_valid(
         v_endpoint.endpoint_ciphertext,v_endpoint.encryption_key_id
       )
       OR v_endpoint.endpoint_aad_digest IS NULL
       OR v_endpoint.endpoint_aad_digest IS DISTINCT FROM
         ops.r6d_nul5_sha256_v1(
           'intake.communication_endpoints','endpoint_ciphertext',
           v_endpoint.id::text,CASE v_endpoint.channel
             WHEN 'SMTP_EMAIL' THEN 'email-address'
             WHEN 'TELEGRAM_BOT_API' THEN 'provider-identifier'
             WHEN 'LINE_MESSAGING_API' THEN 'provider-identifier'
             ELSE 'phone-number'
           END,'1'
         ) THEN
      RAISE EXCEPTION 'privacy_transition_notice_endpoint_invalid'
        USING ERRCODE='23514';
    END IF;

    PERFORM notice.notice_receipt_id
    FROM ops.privacy_request_notice_receipts_v2 AS notice
    WHERE notice.privacy_request_id=v_request.id
    ORDER BY notice.notice_sequence
    FOR UPDATE;
    SELECT count(*),COALESCE(max(notice.notice_sequence),0)
    INTO v_notice_count,v_notice_max_sequence
    FROM ops.privacy_request_notice_receipts_v2 AS notice
    WHERE notice.privacy_request_id=v_request.id;
    IF v_notice_count<>v_notice_max_sequence THEN
      RAISE EXCEPTION 'privacy_notice_receipt_chain_invalid'
        USING ERRCODE='23514';
    END IF;
    v_notice_sequence:=v_notice_max_sequence+1;
    v_notice_receipt_id:=gen_random_uuid();
  END IF;

  IF v_transition='EXTEND' THEN
    PERFORM extension.extension_receipt_id
    FROM ops.privacy_request_extension_receipts_v2 AS extension
    WHERE extension.privacy_request_id=v_request.id
    ORDER BY extension.extension_sequence
    FOR UPDATE;
    SELECT count(*),COALESCE(max(extension.extension_sequence),0)
    INTO v_extension_count,v_extension_max_sequence
    FROM ops.privacy_request_extension_receipts_v2 AS extension
    WHERE extension.privacy_request_id=v_request.id;
    IF v_extension_count<>v_extension_max_sequence THEN
      RAISE EXCEPTION 'privacy_extension_receipt_chain_invalid'
        USING ERRCODE='23514';
    END IF;
    IF v_extension_business_days>
       v_policy.maximum_extension_business_days THEN
      RAISE EXCEPTION 'privacy_extension_business_days_exceeded'
        USING ERRCODE='23514';
    END IF;
    IF v_extension_count>=v_policy.maximum_extension_count THEN
      RAISE EXCEPTION 'privacy_extension_count_exceeded'
        USING ERRCODE='23514';
    END IF;
    v_extension_sequence:=v_extension_max_sequence+1;
    v_extension_receipt_id:=gen_random_uuid();
    v_due_at:=ops.add_privacy_business_days_v1(
      v_prior_due_at,v_extension_business_days,
      v_calendar.id,v_calendar.calendar_digest
    );
  ELSIF v_transition='REJECT' THEN
    v_refusal_receipt_id:=gen_random_uuid();
    v_notice_due_at:=ops.add_privacy_business_days_v1(
      v_now,v_policy.refusal_notice_business_days,
      v_calendar.id,v_calendar.calendar_digest
    );
  END IF;

  IF v_transition IN ('START_REVIEW','REJECT') THEN
    v_decision_payload:=jsonb_build_object(
      'schemaVersion','privacy-request-decision.v1',
      'retentionRequestId',v_request.id,
      'decisionVersion',v_decision_version,
      'transition',v_transition,
      'priorState',v_prior_state,
      'state',v_state,
      'inventorySnapshotDigest',NULL,
      'holdCoverageDigest',NULL,
      'reasonCode',v_reason_code,
      'reasonDigest',btrim(v_reason_sha256),
      'decidedAt',v_now
    );
    v_decision_digest:=encode(extensions.digest(
      ops.canonical_jsonb_v1(v_decision_payload),'sha256'
    ),'hex');
  END IF;

  IF v_transition='EXTEND' THEN
    v_branch_payload:=jsonb_build_object(
      'schemaVersion','privacy-request-extension-receipt.v2',
      'extensionReceiptId',v_extension_receipt_id,
      'retentionRequestId',v_request.id,
      'decisionVersion',v_decision_version,
      'extensionSequence',v_extension_sequence,
      'priorDueAt',v_prior_due_at,
      'dueAt',v_due_at,
      'extensionBusinessDays',v_extension_business_days,
      'extensionReasonCode',v_extension_reason_code,
      'extensionReasonDigest',btrim(v_extension_reason_sha256),
      'responsePolicyId',v_policy.policy_id,
      'responsePolicyRevision',v_policy.revision,
      'responsePolicyVersion',v_policy.policy_version,
      'responsePolicyDigest',btrim(v_policy.policy_digest),
      'calendarVersionId',v_calendar.id,
      'calendarDigest',btrim(v_calendar.calendar_digest),
      'noticeReceiptId',v_notice_receipt_id,
      'extendedAt',v_now
    );
  ELSIF v_transition='REJECT' THEN
    v_branch_payload:=jsonb_build_object(
      'schemaVersion','privacy-request-refusal-receipt.v2',
      'refusalReceiptId',v_refusal_receipt_id,
      'retentionRequestId',v_request.id,
      'decisionVersion',v_decision_version,
      'rejectionReasonCode',v_rejection_reason_code,
      'rejectionReasonDigest',btrim(v_rejection_reason_sha256),
      'appealInstructionsDigest',btrim(v_appeal_instructions_sha256),
      'decisionDigest',btrim(v_decision_digest),
      'responsePolicyId',v_policy.policy_id,
      'responsePolicyRevision',v_policy.revision,
      'responsePolicyVersion',v_policy.policy_version,
      'responsePolicyDigest',btrim(v_policy.policy_digest),
      'calendarVersionId',v_calendar.id,
      'calendarDigest',btrim(v_calendar.calendar_digest),
      'decisionAt',v_now,
      'noticeDueAt',v_notice_due_at,
      'noticeReceiptId',v_notice_receipt_id
    );
  END IF;
  IF v_branch_payload IS NOT NULL THEN
    v_branch_canonical:=ops.canonical_jsonb_v1(v_branch_payload);
    v_branch_digest:=encode(
      extensions.digest(v_branch_canonical,'sha256'),'hex'
    );
  END IF;

  IF v_transition IN ('EXTEND','REJECT') THEN
    v_notice_template_payload:=CASE v_transition
      WHEN 'EXTEND' THEN jsonb_build_object(
        'schemaVersion','privacy-request-notice-template.v1',
        'kind','EXTENSION','retentionRequestId',v_request.id,
        'requestType',v_request.request_type,
        'decisionVersion',v_decision_version,
        'branchReceiptId',v_extension_receipt_id,
        'branchReceiptDigest',btrim(v_branch_digest),
        'priorDueAt',v_prior_due_at,'dueAt',v_due_at,
        'extensionBusinessDays',v_extension_business_days,
        'reasonCode',v_extension_reason_code,
        'reasonDigest',btrim(v_extension_reason_sha256)
      )
      ELSE jsonb_build_object(
        'schemaVersion','privacy-request-notice-template.v1',
        'kind','REFUSAL','retentionRequestId',v_request.id,
        'requestType',v_request.request_type,
        'decisionVersion',v_decision_version,
        'branchReceiptId',v_refusal_receipt_id,
        'branchReceiptDigest',btrim(v_branch_digest),
        'decisionDigest',btrim(v_decision_digest),
        'decisionAt',v_now,'noticeDueAt',v_notice_due_at,
        'reasonCode',v_rejection_reason_code,
        'reasonDigest',btrim(v_rejection_reason_sha256),
        'appealInstructionsDigest',
          btrim(v_appeal_instructions_sha256)
      )
    END;
    v_notice_template_digest:=encode(extensions.digest(
      ops.canonical_jsonb_v1(v_notice_template_payload),'sha256'
    ),'hex');
    v_notice_sha256:=v_notice_template_digest;
    v_notice_aad_digest:=ops.r6d_nul5_sha256_v1(
      'ops.privacy_request_notice_receipts_v2',
      'notice_template_payload',v_notice_receipt_id::text,
      CASE v_transition WHEN 'EXTEND' THEN 'EXTENSION' ELSE 'REFUSAL' END,
      '1'
    );
    v_notice_payload:=jsonb_build_object(
      'schemaVersion','privacy-request-notice-receipt.v2',
      'noticeReceiptId',v_notice_receipt_id,
      'retentionRequestId',v_request.id,
      'noticeSequence',v_notice_sequence,
      'noticeKind',CASE v_transition
        WHEN 'EXTEND' THEN 'EXTENSION' ELSE 'REFUSAL' END,
      'transitionReceiptId',v_transition_receipt_id,
      'endpointId',v_endpoint.id,
      'endpointVersion',v_endpoint.version,
      'endpointDigest',btrim(v_endpoint.endpoint_digest),
      'endpointAadDigest',btrim(v_endpoint.endpoint_aad_digest),
      'encryptionKeyId',v_endpoint.encryption_key_id,
      'noticeSha256',btrim(v_notice_sha256),
      'noticeAadDigest',btrim(v_notice_aad_digest),
      'noticeTemplate',v_notice_template_payload,
      'noticeTemplateDigest',btrim(v_notice_template_digest),
      'branchReceiptId',CASE v_transition
        WHEN 'EXTEND' THEN v_extension_receipt_id
        ELSE v_refusal_receipt_id END,
      'branchReceiptDigest',btrim(v_branch_digest),
      'createdAt',v_now
    );
    v_notice_canonical:=ops.canonical_jsonb_v1(v_notice_payload);
    v_notice_digest:=encode(
      extensions.digest(v_notice_canonical,'sha256'),'hex'
    );
  END IF;

  v_transition_payload:=jsonb_build_object(
    'schemaVersion','privacy-request-transition-receipt.v2',
    'transitionReceiptId',v_transition_receipt_id,
    'retentionRequestId',v_request.id,
    'decisionVersion',v_decision_version,
    'transition',v_transition,
    'priorState',v_prior_state,
    'state',v_state,
    'reasonCode',v_reason_code,
    'reasonDigest',btrim(v_reason_sha256),
    'reasonAadDigest',btrim(v_reason_aad_digest),
    'extensionReasonCode',v_extension_reason_code,
    'extensionReasonDigest',btrim(v_extension_reason_sha256),
    'extensionReasonAadDigest',btrim(v_extension_reason_aad_digest),
    'rejectionReasonCode',v_rejection_reason_code,
    'rejectionReasonDigest',btrim(v_rejection_reason_sha256),
    'rejectionReasonAadDigest',btrim(v_rejection_reason_aad_digest),
    'appealInstructionsDigest',btrim(v_appeal_instructions_sha256),
    'appealInstructionsAadDigest',
      btrim(v_appeal_instructions_aad_digest),
    'encryptionKeyId',v_encryption_key_id,
    'actorId',p_actor_id,
    'actorAssertionJti',v_actor_assertion_jti,
    'actorActionDigest',btrim(v_actor_action_digest),
    'stepUpAuthorizationId',v_step_up_authorization_id,
    'idempotencyKeySha256',btrim(p_idempotency_key_sha256),
    'requestSha256',btrim(p_request_sha256),
    'identityReceiptId',NULL,
    'identityReceiptDigest',NULL,
    'extensionReceiptId',v_extension_receipt_id,
    'extensionReceiptDigest',CASE WHEN v_transition='EXTEND'
      THEN btrim(v_branch_digest) ELSE NULL END,
    'refusalReceiptId',v_refusal_receipt_id,
    'refusalReceiptDigest',CASE WHEN v_transition='REJECT'
      THEN btrim(v_branch_digest) ELSE NULL END,
    'noticeReceiptId',v_notice_receipt_id,
    'noticeReceiptDigest',btrim(v_notice_digest),
    'decisionDigest',btrim(v_decision_digest),
    'decidedAt',v_now
  );
  v_transition_canonical:=ops.canonical_jsonb_v1(v_transition_payload);
  v_transition_digest:=encode(
    extensions.digest(v_transition_canonical,'sha256'),'hex'
  );

  -- The root mutation guard admits only this SECURITY DEFINER owner.  Set the
  -- transaction-local capability only after every success precondition and
  -- canonical receipt digest has been fixed, but before the first success DML.
  PERFORM set_config('gurine.privacy_request_transition_v2','1',true);

  v_audit_event_id:=ops.append_audit_event(
    'privacy-request:'||v_request.id::text,
    'USER',p_actor_id::text,p_session_id,
    'command.transitionRetentionRequest','PRIVACY_REQUEST',
    v_request.id::text,'privacy.requests.manage','SUCCESS',
    v_reason_code,p_request_id,jsonb_build_object(
      'decisionVersion',v_decision_version,
      'transition',v_transition,'priorState',v_prior_state,
      'state',v_state,'reasonDigest',btrim(v_reason_sha256),
      'decisionDigest',btrim(v_decision_digest),
      'transitionReceiptId',v_transition_receipt_id,
      'transitionReceiptDigest',btrim(v_transition_digest),
      'extensionReceiptId',v_extension_receipt_id,
      'extensionReceiptDigest',CASE WHEN v_transition='EXTEND'
        THEN btrim(v_branch_digest) ELSE NULL END,
      'refusalReceiptId',v_refusal_receipt_id,
      'refusalReceiptDigest',CASE WHEN v_transition='REJECT'
        THEN btrim(v_branch_digest) ELSE NULL END,
      'noticeReceiptId',v_notice_receipt_id,
      'noticeReceiptDigest',btrim(v_notice_digest),
      'responsePolicyId',v_policy.policy_id,
      'responsePolicyRevision',v_policy.revision,
      'responsePolicyDigest',btrim(v_policy.policy_digest),
      'calendarVersionId',v_calendar.id,
      'calendarDigest',btrim(v_calendar.calendar_digest)
    )
  );

  IF v_transition IN ('START_REVIEW','REJECT') THEN
    v_event_payload:=jsonb_build_object(
      'retentionRequestId',v_request.id,
      'decisionVersion',v_decision_version,
      'transition',v_transition,
      'priorState',v_prior_state,
      'state',v_state,
      'inventorySnapshotDigest',NULL,
      'holdCoverageDigest',NULL,
      'decisionDigest',btrim(v_decision_digest),
      'receiptDigest',btrim(v_transition_digest)
    );
    v_decision_event_id:=ops.enqueue_outbox(
      'privacy_request',v_request.id::text,v_decision_version,
      'privacy.request_decision_recorded.v1',v_event_payload,v_now
    );
  END IF;
  IF v_transition='EXTEND' THEN
    v_event_payload:=jsonb_build_object(
      'retentionRequestId',v_request.id,
      'requestType',v_request.request_type,
      'priorDueAt',v_prior_due_at,
      'dueAt',v_due_at,
      'extensionBusinessDays',v_extension_business_days,
      'extensionSequence',v_extension_sequence,
      'reasonDigest',btrim(v_extension_reason_sha256),
      'responsePolicyVersion',v_policy.policy_version,
      'responsePolicyDigest',btrim(v_policy.policy_digest),
      'calendarVersionId',v_calendar.id,
      'calendarDigest',btrim(v_calendar.calendar_digest),
      'notifiedAt',v_now,
      'notificationReceiptDigest',btrim(v_notice_digest)
    );
    v_notification_event_id:=ops.enqueue_outbox(
      'privacy_request',v_request.id::text,v_decision_version,
      'privacy.request_extension_notified.v1',v_event_payload,v_now
    );
  ELSIF v_transition='REJECT' THEN
    v_event_payload:=jsonb_build_object(
      'retentionRequestId',v_request.id,
      'requestType',v_request.request_type,
      'decisionDigest',btrim(v_decision_digest),
      'reasonDigest',btrim(v_rejection_reason_sha256),
      'appealInstructionsDigest',
        btrim(v_appeal_instructions_sha256),
      'responsePolicyVersion',v_policy.policy_version,
      'responsePolicyDigest',btrim(v_policy.policy_digest),
      'calendarVersionId',v_calendar.id,
      'calendarDigest',btrim(v_calendar.calendar_digest),
      'decisionAt',v_now,
      'noticeDueAt',v_notice_due_at,
      'notifiedAt',v_now,
      'notificationReceiptDigest',btrim(v_notice_digest)
    );
    v_notification_event_id:=ops.enqueue_outbox(
      'privacy_request',v_request.id::text,v_decision_version,
      'privacy.request_refusal_notified.v1',v_event_payload,v_now
    );
  END IF;
  SELECT array_agg(event_id ORDER BY event_id)
  INTO v_outbox_event_ids
  FROM unnest(ARRAY[
    v_decision_event_id,v_notification_event_id
  ]::uuid[]) AS event_ids(event_id)
  WHERE event_id IS NOT NULL;
  IF cardinality(v_outbox_event_ids)<>(CASE
       WHEN v_transition='REJECT' THEN 2 ELSE 1 END)
     OR NOT ops.uuid_array_is_sorted_unique(v_outbox_event_ids) THEN
    RAISE EXCEPTION 'privacy_transition_outbox_cardinality_invalid'
      USING ERRCODE='23514';
  END IF;
  v_primary_event_id:=CASE v_transition
    WHEN 'START_REVIEW' THEN v_decision_event_id
    ELSE v_notification_event_id
  END;
  v_primary_event_digest:=
    ops.r6d_outbox_envelope_digest_v1(v_primary_event_id);
  IF v_primary_event_digest IS NULL
     OR NOT ops.r6d_lower_sha256(v_primary_event_digest) THEN
    RAISE EXCEPTION 'privacy_transition_outbox_binding_invalid'
      USING ERRCODE='23514';
  END IF;

  IF v_transition='EXTEND' THEN
    INSERT INTO ops.privacy_request_extension_receipts_v2(
      extension_receipt_id,privacy_request_id,decision_version,
      extension_sequence,prior_due_at,due_at,extension_business_days,
      extension_reason_code,extension_reason_sha256,response_policy_id,
      response_policy_revision,response_policy_digest,calendar_version_id,
      calendar_digest,notice_receipt_id,notice_receipt_digest,
      event_receipt_id,event_receipt_digest,receipt_payload,
      receipt_canonical,receipt_digest,extended_at
    ) VALUES(
      v_extension_receipt_id,v_request.id,v_decision_version,
      v_extension_sequence,v_prior_due_at,v_due_at,
      v_extension_business_days,v_extension_reason_code,
      v_extension_reason_sha256,v_policy.policy_id,v_policy.revision,
      v_policy.policy_digest,v_calendar.id,v_calendar.calendar_digest,
      v_notice_receipt_id,v_notice_digest,v_primary_event_id,
      v_primary_event_digest,v_branch_payload,v_branch_canonical,
      v_branch_digest,v_now
    );
  ELSIF v_transition='REJECT' THEN
    INSERT INTO ops.privacy_request_refusal_receipts_v2(
      refusal_receipt_id,privacy_request_id,decision_version,
      rejection_reason_code,rejection_reason_sha256,
      appeal_instructions_sha256,decision_digest,response_policy_id,
      response_policy_revision,response_policy_digest,calendar_version_id,
      calendar_digest,decision_at,notice_due_at,notice_receipt_id,
      notice_receipt_digest,event_receipt_id,event_receipt_digest,
      receipt_payload,receipt_canonical,receipt_digest
    ) VALUES(
      v_refusal_receipt_id,v_request.id,v_decision_version,
      v_rejection_reason_code,v_rejection_reason_sha256,
      v_appeal_instructions_sha256,v_decision_digest,v_policy.policy_id,
      v_policy.revision,v_policy.policy_digest,v_calendar.id,
      v_calendar.calendar_digest,v_now,v_notice_due_at,
      v_notice_receipt_id,v_notice_digest,v_primary_event_id,
      v_primary_event_digest,v_branch_payload,v_branch_canonical,
      v_branch_digest
    );
  END IF;

  IF v_transition IN ('EXTEND','REJECT') THEN
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
      CASE v_transition WHEN 'EXTEND' THEN 'EXTENSION' ELSE 'REFUSAL' END,
      v_transition_receipt_id,v_endpoint.id,v_endpoint.version,
      v_endpoint.endpoint_digest,v_endpoint.endpoint_aad_digest,
      v_endpoint.encryption_key_id,v_notice_sha256,v_notice_aad_digest,
      v_notice_template_payload,v_notice_template_digest,
      CASE v_transition WHEN 'EXTEND' THEN v_extension_receipt_id
        ELSE v_refusal_receipt_id END,
      v_branch_digest,v_primary_event_id,v_primary_event_digest,
      v_notice_payload,v_notice_canonical,v_notice_digest,v_now
    );
  END IF;

  INSERT INTO ops.privacy_request_transition_receipts_v2(
    transition_receipt_id,privacy_request_id,decision_version,transition,
    prior_state,state,reason_code,reason_sha256,reason_aad_digest,
    extension_reason_code,extension_reason_sha256,
    extension_reason_aad_digest,rejection_reason_code,
    rejection_reason_sha256,rejection_reason_aad_digest,
    appeal_instructions_sha256,appeal_instructions_aad_digest,
    encryption_key_id,actor_id,actor_assertion_jti,actor_action_digest,
    step_up_authorization_id,idempotency_key_sha256,request_sha256,
    identity_receipt_id,identity_receipt_digest,extension_receipt_id,
    extension_receipt_digest,refusal_receipt_id,refusal_receipt_digest,
    notice_receipt_id,notice_receipt_digest,event_receipt_id,
    event_receipt_digest,audit_event_id,outbox_event_ids,receipt_payload,
    receipt_canonical,receipt_digest,decided_at
  ) VALUES(
    v_transition_receipt_id,v_request.id,v_decision_version,v_transition,
    v_prior_state,v_state,v_reason_code,v_reason_sha256,v_reason_aad_digest,
    v_extension_reason_code,v_extension_reason_sha256,
    v_extension_reason_aad_digest,v_rejection_reason_code,
    v_rejection_reason_sha256,v_rejection_reason_aad_digest,
    v_appeal_instructions_sha256,v_appeal_instructions_aad_digest,
    v_encryption_key_id,p_actor_id,v_actor_assertion_jti,
    v_actor_action_digest,v_step_up_authorization_id,
    p_idempotency_key_sha256,p_request_sha256,NULL,NULL,
    v_extension_receipt_id,CASE WHEN v_transition='EXTEND'
      THEN v_branch_digest ELSE NULL END,
    v_refusal_receipt_id,CASE WHEN v_transition='REJECT'
      THEN v_branch_digest ELSE NULL END,
    v_notice_receipt_id,v_notice_digest,v_primary_event_id,
    v_primary_event_digest,v_audit_event_id,v_outbox_event_ids,
    v_transition_payload,v_transition_canonical,v_transition_digest,v_now
  );

  INSERT INTO ops.privacy_request_sealed_content_v2(
    privacy_request_id,transition_receipt_id,field_kind,sealed_ciphertext,
    sealed_sha256,sealed_aad_digest,encryption_key_id
  ) VALUES(
    v_request.id,v_transition_receipt_id,'REASON',v_reason_ciphertext,
    v_reason_sha256,v_reason_aad_digest,v_encryption_key_id
  );
  IF v_transition='EXTEND' THEN
    INSERT INTO ops.privacy_request_sealed_content_v2(
      privacy_request_id,transition_receipt_id,field_kind,sealed_ciphertext,
      sealed_sha256,sealed_aad_digest,encryption_key_id
    ) VALUES(
      v_request.id,v_transition_receipt_id,'EXTENSION_REASON',
      v_extension_reason_ciphertext,v_extension_reason_sha256,
      v_extension_reason_aad_digest,v_encryption_key_id
    );
  ELSIF v_transition='REJECT' THEN
    INSERT INTO ops.privacy_request_sealed_content_v2(
      privacy_request_id,transition_receipt_id,field_kind,sealed_ciphertext,
      sealed_sha256,sealed_aad_digest,encryption_key_id
    ) VALUES
      (v_request.id,v_transition_receipt_id,'REJECTION_REASON',
       v_rejection_reason_ciphertext,v_rejection_reason_sha256,
       v_rejection_reason_aad_digest,v_encryption_key_id),
      (v_request.id,v_transition_receipt_id,'APPEAL_INSTRUCTIONS',
       v_appeal_instructions_ciphertext,v_appeal_instructions_sha256,
       v_appeal_instructions_aad_digest,v_encryption_key_id);
  END IF;

  UPDATE ops.privacy_requests_v2
  SET decision_version=v_decision_version,
      state=v_state,
      due_at=CASE WHEN v_transition='EXTEND' THEN v_due_at ELSE due_at END,
      response_policy_id=v_policy.policy_id,
      response_policy_revision=v_policy.revision,
      response_policy_digest=v_policy.policy_digest,
      calendar_version_id=v_calendar.id,
      calendar_digest=v_calendar.calendar_digest,
      current_extension_receipt_id=CASE WHEN v_transition='EXTEND'
        THEN v_extension_receipt_id ELSE current_extension_receipt_id END,
      current_extension_receipt_digest=CASE WHEN v_transition='EXTEND'
        THEN v_branch_digest ELSE current_extension_receipt_digest END,
      current_refusal_receipt_id=CASE WHEN v_transition='REJECT'
        THEN v_refusal_receipt_id ELSE current_refusal_receipt_id END,
      current_refusal_receipt_digest=CASE WHEN v_transition='REJECT'
        THEN v_branch_digest ELSE current_refusal_receipt_digest END,
      current_notice_receipt_id=CASE
        WHEN v_transition IN ('EXTEND','REJECT')
        THEN v_notice_receipt_id ELSE current_notice_receipt_id END,
      current_notice_receipt_digest=CASE
        WHEN v_transition IN ('EXTEND','REJECT')
        THEN v_notice_digest ELSE current_notice_receipt_digest END,
      updated_at=v_now
  WHERE id=v_request.id AND decision_version=v_request.decision_version;
  GET DIAGNOSTICS v_affected=ROW_COUNT;
  IF v_affected<>1 THEN
    RAISE EXCEPTION 'privacy_transition_version_conflict'
      USING ERRCODE='PVT08';
  END IF;

  v_transition_response:=jsonb_build_object(
    'retentionRequestId',v_request.id,
    'decisionVersion',v_decision_version,
    'requestType',v_request.request_type,
    'state',v_state,
    'transition',v_transition,
    'transitionReceiptId',v_transition_receipt_id,
    'transitionReceiptDigest',btrim(v_transition_digest),
    'identityVerifiedAt',v_request.identity_verified_at,
    'dueAt',CASE WHEN v_transition='EXTEND'
      THEN v_due_at ELSE v_request.due_at END,
    'policyVersion',v_policy.policy_version,
    'policyDigest',btrim(v_policy.policy_digest),
    'calendarVersionId',v_calendar.id,
    'calendarDigest',btrim(v_calendar.calendar_digest),
    'identityReceiptId',NULL,
    'identityReceiptDigest',NULL,
    'extensionReceiptId',v_extension_receipt_id,
    'extensionReceiptDigest',CASE WHEN v_transition='EXTEND'
      THEN btrim(v_branch_digest) ELSE NULL END,
    'refusalReceiptId',v_refusal_receipt_id,
    'refusalReceiptDigest',CASE WHEN v_transition='REJECT'
      THEN btrim(v_branch_digest) ELSE NULL END,
    'noticeReceiptId',v_notice_receipt_id,
    'noticeReceiptDigest',btrim(v_notice_digest),
    'appealInstructionsDigest',CASE WHEN v_transition='REJECT'
      THEN btrim(v_appeal_instructions_sha256) ELSE NULL END,
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
$transition$;
ALTER FUNCTION ops.transition_privacy_request_v2(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.transition_privacy_request_v2(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.transition_privacy_request_v2(
  jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;

-- Route the generic Control API owner boundary to the V2 privacy owner without
-- duplicating the other addendum implementations. The prior dispatcher remains
-- callable only by its owner; its legacy privacy delegate is retired above.
ALTER FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) RENAME TO apply_control_addendum_command_pre_r6d;
REVOKE ALL ON FUNCTION ops.apply_control_addendum_command_pre_r6d(
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
AS $dispatcher$
DECLARE
  v_result jsonb;
  v_transition jsonb;
  v_transition_receipt ops.privacy_request_transition_receipts_v2%ROWTYPE;
  v_aggregate_id uuid;
  v_aggregate_version bigint;
  v_accepted_at timestamptz;
  v_receipt_digest char(64);
  v_audit_event_id uuid;
  v_transition_receipt_id uuid;
  v_outbox_event_ids uuid[];
BEGIN
  IF p_operation_id<>'transitionRetentionRequest' THEN
    RETURN QUERY
    SELECT prior.aggregate_id,prior.aggregate_version,prior.status,
      prior.accepted_at,prior.response_body,prior.receipt_digest,
      prior.audit_event_id,prior.outbox_event_id
    FROM ops.apply_control_addendum_command_pre_r6d(
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
     OR jsonb_typeof(v_transition->'transition')<>'string'
     OR v_transition->>'transition' NOT IN ('START_REVIEW','EXTEND','REJECT')
     OR (v_transition->>'transition'='START_REVIEW'
       AND v_transition->>'state'<>'REVIEW')
     OR (v_transition->>'transition'='EXTEND'
       AND v_transition->>'state' NOT IN ('RECEIVED','REVIEW','APPROVED'))
     OR (v_transition->>'transition'='REJECT'
       AND v_transition->>'state'<>'REJECTED')
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
     OR jsonb_typeof(v_transition->'updatedAt')<>'string'
     OR jsonb_typeof(v_transition->'replayed')<>'boolean'
     OR (v_transition->>'replayed')::boolean THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;
  IF jsonb_array_length(v_result->'outboxEventIds')<>
       (CASE v_transition->>'transition' WHEN 'REJECT' THEN 2 ELSE 1 END)
     OR EXISTS(
       SELECT 1
       FROM jsonb_array_elements(v_result->'outboxEventIds') AS event_id(value)
       WHERE jsonb_typeof(event_id.value)<>'string'
     )
     OR num_nonnulls(
       v_transition->>'identityReceiptId',
       v_transition->>'identityReceiptDigest',
       v_transition->>'extensionReceiptId',
       v_transition->>'extensionReceiptDigest',
       v_transition->>'refusalReceiptId',
       v_transition->>'refusalReceiptDigest',
       v_transition->>'noticeReceiptId',
       v_transition->>'noticeReceiptDigest',
       v_transition->>'appealInstructionsDigest'
     )<>(CASE v_transition->>'transition'
       WHEN 'EXTEND' THEN 4 WHEN 'REJECT' THEN 5 ELSE 0 END) THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;
  IF jsonb_typeof(v_transition->'identityReceiptId')<>'null'
     OR jsonb_typeof(v_transition->'identityReceiptDigest')<>'null'
     OR (v_transition->>'transition'='START_REVIEW' AND (
       jsonb_typeof(v_transition->'extensionReceiptId')<>'null'
       OR jsonb_typeof(v_transition->'extensionReceiptDigest')<>'null'
       OR jsonb_typeof(v_transition->'refusalReceiptId')<>'null'
       OR jsonb_typeof(v_transition->'refusalReceiptDigest')<>'null'
       OR jsonb_typeof(v_transition->'noticeReceiptId')<>'null'
       OR jsonb_typeof(v_transition->'noticeReceiptDigest')<>'null'
       OR jsonb_typeof(v_transition->'appealInstructionsDigest')<>'null'
     ))
     OR (v_transition->>'transition'='EXTEND' AND (
       jsonb_typeof(v_transition->'extensionReceiptId')<>'string'
       OR jsonb_typeof(v_transition->'extensionReceiptDigest')<>'string'
       OR NOT ops.r6d_lower_sha256(
         v_transition->>'extensionReceiptDigest'
       )
       OR jsonb_typeof(v_transition->'refusalReceiptId')<>'null'
       OR jsonb_typeof(v_transition->'refusalReceiptDigest')<>'null'
       OR jsonb_typeof(v_transition->'noticeReceiptId')<>'string'
       OR jsonb_typeof(v_transition->'noticeReceiptDigest')<>'string'
       OR NOT ops.r6d_lower_sha256(v_transition->>'noticeReceiptDigest')
       OR jsonb_typeof(v_transition->'appealInstructionsDigest')<>'null'
     ))
     OR (v_transition->>'transition'='REJECT' AND (
       jsonb_typeof(v_transition->'extensionReceiptId')<>'null'
       OR jsonb_typeof(v_transition->'extensionReceiptDigest')<>'null'
       OR jsonb_typeof(v_transition->'refusalReceiptId')<>'string'
       OR jsonb_typeof(v_transition->'refusalReceiptDigest')<>'string'
       OR NOT ops.r6d_lower_sha256(v_transition->>'refusalReceiptDigest')
       OR jsonb_typeof(v_transition->'noticeReceiptId')<>'string'
       OR jsonb_typeof(v_transition->'noticeReceiptDigest')<>'string'
       OR NOT ops.r6d_lower_sha256(v_transition->>'noticeReceiptDigest')
       OR jsonb_typeof(v_transition->'appealInstructionsDigest')<>'string'
       OR NOT ops.r6d_lower_sha256(
         v_transition->>'appealInstructionsDigest'
       )
     )) THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  BEGIN
    v_aggregate_id:=(v_result->>'aggregateId')::uuid;
    v_aggregate_version:=(v_result->>'aggregateVersion')::bigint;
    v_accepted_at:=(v_result->>'acceptedAt')::timestamptz;
    v_receipt_digest:=(v_result->>'receiptDigest')::char(64);
    v_audit_event_id:=(v_result->>'auditEventId')::uuid;
    v_transition_receipt_id:=
      (v_transition->>'transitionReceiptId')::uuid;
    PERFORM (v_result->>'requestId')::uuid,
      (v_transition->>'retentionRequestId')::uuid,
      (v_transition->>'decisionVersion')::bigint,
      (v_transition->>'identityVerifiedAt')::timestamptz,
      (v_transition->>'dueAt')::timestamptz,
      (v_transition->>'calendarVersionId')::uuid,
      (v_transition->>'updatedAt')::timestamptz,
      (v_transition->>'identityReceiptId')::uuid,
      (v_transition->>'extensionReceiptId')::uuid,
      (v_transition->>'refusalReceiptId')::uuid,
      (v_transition->>'noticeReceiptId')::uuid;
    SELECT array_agg(event_id.value::uuid ORDER BY event_id.ordinality)
    INTO v_outbox_event_ids
    FROM jsonb_array_elements_text(
      v_result->'outboxEventIds'
    ) WITH ORDINALITY AS event_id(value,ordinality);
  EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range
      OR datetime_field_overflow THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END;
  IF v_aggregate_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_audit_event_id='00000000-0000-0000-0000-000000000000'::uuid
     OR v_transition_receipt_id=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR (v_transition->>'calendarVersionId')::uuid=
       '00000000-0000-0000-0000-000000000000'::uuid
     OR (v_result->>'requestId')::uuid<>p_request_id
     OR v_aggregate_id<>(v_transition->>'retentionRequestId')::uuid
     OR v_aggregate_version<>(v_transition->>'decisionVersion')::bigint
     OR v_receipt_digest<>
       (v_transition->>'transitionReceiptDigest')::char(64)
     OR v_accepted_at<>(v_transition->>'updatedAt')::timestamptz
     OR NOT isfinite(v_accepted_at)
     OR NOT isfinite((v_transition->>'identityVerifiedAt')::timestamptz)
     OR NOT isfinite((v_transition->>'dueAt')::timestamptz)
     OR (v_transition->>'dueAt')::timestamptz<=
       (v_transition->>'identityVerifiedAt')::timestamptz
     OR NOT ops.uuid_array_is_sorted_unique(v_outbox_event_ids)
     OR array_position(
       v_outbox_event_ids,
       '00000000-0000-0000-0000-000000000000'::uuid
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;
  SELECT receipt.* INTO v_transition_receipt
  FROM ops.privacy_request_transition_receipts_v2 AS receipt
  WHERE receipt.transition_receipt_id=v_transition_receipt_id
  FOR SHARE;
  IF NOT FOUND
     OR v_transition_receipt.privacy_request_id<>v_aggregate_id
     OR v_transition_receipt.decision_version<>v_aggregate_version
     OR v_transition_receipt.transition<>v_transition->>'transition'
     OR v_transition_receipt.state<>v_transition->>'state'
     OR v_transition_receipt.receipt_digest<>v_receipt_digest
     OR v_transition_receipt.decided_at<>v_accepted_at
     OR v_transition_receipt.audit_event_id<>v_audit_event_id
     OR v_transition_receipt.outbox_event_ids<>v_outbox_event_ids
     OR v_transition_receipt.event_receipt_id IS NULL
     OR NOT v_transition_receipt.event_receipt_id=
       ANY(v_outbox_event_ids)
     OR v_transition_receipt.identity_receipt_id IS DISTINCT FROM
       (v_transition->>'identityReceiptId')::uuid
     OR v_transition_receipt.identity_receipt_digest IS DISTINCT FROM
       (v_transition->>'identityReceiptDigest')::char(64)
     OR v_transition_receipt.extension_receipt_id IS DISTINCT FROM
       (v_transition->>'extensionReceiptId')::uuid
     OR v_transition_receipt.extension_receipt_digest IS DISTINCT FROM
       (v_transition->>'extensionReceiptDigest')::char(64)
     OR v_transition_receipt.refusal_receipt_id IS DISTINCT FROM
       (v_transition->>'refusalReceiptId')::uuid
     OR v_transition_receipt.refusal_receipt_digest IS DISTINCT FROM
       (v_transition->>'refusalReceiptDigest')::char(64)
     OR v_transition_receipt.notice_receipt_id IS DISTINCT FROM
       (v_transition->>'noticeReceiptId')::uuid
     OR v_transition_receipt.notice_receipt_digest IS DISTINCT FROM
       (v_transition->>'noticeReceiptDigest')::char(64)
     OR v_transition_receipt.appeal_instructions_sha256 IS DISTINCT FROM
       (v_transition->>'appealInstructionsDigest')::char(64)
     OR v_transition_receipt.event_receipt_digest IS NULL
     OR v_transition_receipt.event_receipt_digest<>
       ops.r6d_outbox_envelope_digest_v1(
         v_transition_receipt.event_receipt_id
       )
     OR NOT EXISTS(
       SELECT 1 FROM ops.outbox AS event
       WHERE event.id=v_transition_receipt.event_receipt_id
         AND event.aggregate_type='privacy_request'
         AND event.aggregate_id=v_aggregate_id::text
         AND event.aggregate_version=v_aggregate_version
         AND event.event_type=CASE v_transition->>'transition'
           WHEN 'START_REVIEW' THEN
             'privacy.request_decision_recorded.v1'
           WHEN 'EXTEND' THEN
             'privacy.request_extension_notified.v1'
           ELSE 'privacy.request_refusal_notified.v1'
         END
     ) THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;
  IF (SELECT count(*) FROM ops.outbox AS event
      WHERE event.id=ANY(v_outbox_event_ids)
        AND event.aggregate_type='privacy_request'
        AND event.aggregate_id=v_aggregate_id::text
        AND event.aggregate_version=v_aggregate_version)
       <>cardinality(v_outbox_event_ids)
     OR (v_transition->>'transition' IN ('START_REVIEW','REJECT')
       AND (SELECT count(*) FROM ops.outbox AS event
            WHERE event.id=ANY(v_outbox_event_ids)
              AND event.event_type=
                'privacy.request_decision_recorded.v1')<>1)
     OR (v_transition->>'transition'='EXTEND'
       AND (SELECT count(*) FROM ops.outbox AS event
            WHERE event.id=ANY(v_outbox_event_ids)
              AND event.event_type=
                'privacy.request_extension_notified.v1')<>1)
     OR (v_transition->>'transition'='REJECT'
       AND (SELECT count(*) FROM ops.outbox AS event
            WHERE event.id=ANY(v_outbox_event_ids)
              AND event.event_type=
                'privacy.request_refusal_notified.v1')<>1) THEN
    RAISE EXCEPTION 'privacy_transition_result_adapter_invalid'
      USING ERRCODE='55000';
  END IF;

  RETURN QUERY SELECT
    v_aggregate_id,v_aggregate_version,v_result->>'status',v_accepted_at,
    v_result,v_receipt_digest,v_audit_event_id,
    v_transition_receipt.event_receipt_id;
END
$dispatcher$;
ALTER FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.apply_control_addendum_command(
  text,jsonb,uuid,uuid,uuid,char(64),char(64)
) TO gurine_control_api;
-- R6d privacy transition owner and typed dispatcher integration ends.

-- R6d TEST_ONLY privacy response-calendar selector begins.
-- R6d TEST_ONLY privacy response-calendar authority overlay.
--
-- This overlay admits exactly one explicitly marked test contract shape.  It
-- does not weaken the non-test RESPONSE_POLICY_CALENDAR action graph below.
-- The marker branch is usable only when the original login role is
-- gurine_migrator or a member of it; SECURITY DEFINER current_user is not an
-- authorization signal here.
--
-- Exact TEST_ONLY policy payload (14 keys):
--   policyVersion, authoritySource, timezone, daySystem,
--   accessBusinessDays, correctionBusinessDays, deletionBusinessDays,
--   restrictionBusinessDays, maximumExtensionBusinessDays,
--   maximumExtensionCount, extensionNoticeTiming,
--   refusalNoticeBusinessDays, calendarVersionId, calendarDigest.
--
-- Exact Q3 test calendar:
--   Asia/Seoul; version 1; weekend [0,6]; holiday [2026-08-10];
--   effective 2026-01-01T00:00:00Z; review expiry 2099-01-01T00:00:00Z.
-- The calendar digest deliberately excludes policyDigest: policyDigest hashes
-- a payload containing calendarDigest, so including policyDigest in the
-- calendar preimage would create an unsatisfiable digest cycle.

CREATE OR REPLACE FUNCTION ops.privacy_response_policy_calendar_authority_v1_is_valid(
  p_policy_id uuid,
  p_revision bigint
) RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,extensions,pg_temp
AS $authority$
DECLARE
  v_count bigint;
  v_is_test_marker boolean;
BEGIN
  IF p_policy_id IS NULL OR p_revision IS NULL OR p_revision<=0 THEN
    RETURN false;
  END IF;

  -- A partial marker is invalid and must never fall through to the production
  -- action graph.  The PK makes this lookup zero-or-one.
  SELECT policy.authority_source='TEST_ONLY'
      OR policy.policy_version='test-only-r6d-v1'
  INTO v_is_test_marker
  FROM ops.privacy_response_calendar_policies_v1 AS policy
  WHERE policy.policy_id=p_policy_id AND policy.revision=p_revision;

  IF COALESCE(v_is_test_marker,false) THEN
    IF NOT pg_has_role(session_user,'gurine_migrator','MEMBER') THEN
      RETURN false;
    END IF;

    SELECT count(*) INTO v_count
    FROM ops.privacy_response_calendar_policies_v1 AS policy
    JOIN ops.business_calendar_versions AS calendar
      ON calendar.id=policy.calendar_id
     AND calendar.calendar_id<>'00000000-0000-0000-0000-000000000000'::uuid
     AND calendar.version=1
     AND calendar.timezone='Asia/Seoul'
     AND calendar.weekend_days=ARRAY[0,6]::smallint[]
     AND calendar.holiday_dates=ARRAY[date '2026-08-10']
     AND calendar.effective_at=
         timestamptz '2026-01-01 00:00:00+00'
     AND calendar.review_expires_at=
         timestamptz '2099-01-01 00:00:00+00'
     AND btrim(calendar.holiday_set_digest)=encode(
       extensions.digest(ops.canonical_jsonb_v1(jsonb_build_object(
         'schemaVersion','test-only-privacy-holiday-set.v1',
         'holidayDates',jsonb_build_array('2026-08-10')
       )),'sha256'),'hex'
     )
     AND btrim(calendar.calendar_digest)=encode(
       extensions.digest(ops.canonical_jsonb_v1(jsonb_build_object(
         'schemaVersion','test-only-privacy-business-calendar.v1',
         'calendarVersionId',calendar.id,
         'calendarId',calendar.calendar_id,
         'version',calendar.version,
         'timezone',calendar.timezone,
         'weekendDays',to_jsonb(calendar.weekend_days),
         'holidayDates',to_jsonb(calendar.holiday_dates),
         'holidayDateSetDigest',btrim(calendar.holiday_set_digest),
         'effectiveAt','2026-01-01T00:00:00Z',
         'reviewExpiresAt','2099-01-01T00:00:00Z'
       )),'sha256'),'hex'
     )
     AND calendar.policy_digest=policy.policy_digest
     AND calendar.approval_proposal_id=policy.action_proposal_id
     AND calendar.approval_proposal_version=
         policy.action_proposal_version
     AND calendar.execution_receipt_id=
         policy.action_execution_receipt_id
     AND calendar.execution_receipt_digest=
         policy.action_execution_receipt_digest
    WHERE policy.policy_id=p_policy_id AND policy.revision=p_revision
      AND policy.policy_id<>'00000000-0000-0000-0000-000000000000'::uuid
      AND policy.state='APPROVED'
      AND policy.authority_source='TEST_ONLY'
      AND policy.policy_version='test-only-r6d-v1'
      AND policy.timezone='Asia/Seoul'
      AND policy.access_business_days=10
      AND policy.correction_business_days=10
      AND policy.deletion_business_days=10
      AND policy.restriction_business_days=10
      AND policy.maximum_extension_business_days=10
      AND policy.maximum_extension_count=1
      AND policy.refusal_notice_business_days=10
      AND policy.effective_at=calendar.effective_at
      AND policy.review_expires_at=calendar.review_expires_at
      AND policy.policy_payload=jsonb_build_object(
        'policyVersion','test-only-r6d-v1',
        'authoritySource','TEST_ONLY',
        'timezone','Asia/Seoul',
        'daySystem','BUSINESS_DAY',
        'accessBusinessDays',10,
        'correctionBusinessDays',10,
        'deletionBusinessDays',10,
        'restrictionBusinessDays',10,
        'maximumExtensionBusinessDays',10,
        'maximumExtensionCount',1,
        'extensionNoticeTiming','BEFORE_CURRENT_DUE_AT',
        'refusalNoticeBusinessDays',10,
        'calendarVersionId',calendar.id,
        'calendarDigest',btrim(calendar.calendar_digest)
      )
      AND policy.policy_canonical=ops.canonical_jsonb_v1(
        policy.policy_payload
      )
      AND btrim(policy.policy_digest)=encode(
        extensions.digest(policy.policy_canonical,'sha256'),'hex'
      )
      AND btrim(policy.binding_digest)=encode(
        extensions.digest(ops.canonical_jsonb_v1(jsonb_build_object(
          'schemaVersion',
            'test-only-privacy-response-calendar-policy-binding.v1',
          'policyId',policy.policy_id,
          'revision',policy.revision,
          'state',policy.state,
          'authoritySource',policy.authority_source,
          'policyVersion',policy.policy_version,
          'policyDigest',btrim(policy.policy_digest),
          'calendarVersionId',calendar.id,
          'calendarId',calendar.calendar_id,
          'calendarVersion',calendar.version,
          'calendarDigest',btrim(calendar.calendar_digest),
          'actionProposalId',policy.action_proposal_id,
          'actionProposalVersion',policy.action_proposal_version,
          'approvalDigest',btrim(calendar.approval_digest),
          'operationalDecisionReceiptId',
            policy.operational_decision_receipt_id,
          'operationalDecisionReceiptDigest',
            btrim(policy.operational_decision_receipt_digest),
          'legalDecisionReceiptId',policy.legal_decision_receipt_id,
          'legalDecisionReceiptDigest',
            btrim(policy.legal_decision_receipt_digest),
          'actionExecutionReceiptId',
            policy.action_execution_receipt_id,
          'actionExecutionReceiptDigest',
            btrim(policy.action_execution_receipt_digest),
          'effectiveAt','2026-01-01T00:00:00Z',
          'reviewExpiresAt','2099-01-01T00:00:00Z'
        )),'sha256'),'hex'
      );
    RETURN v_count=1;
  END IF;

  -- Non-test policies retain the complete production action graph unchanged.
  SELECT count(*) INTO v_count
  FROM ops.privacy_response_calendar_policies_v1 AS policy
  JOIN ops.business_calendar_versions AS calendar
    ON calendar.id=policy.calendar_id
   AND calendar.timezone='Asia/Seoul'
   AND calendar.policy_digest=policy.policy_digest
   AND calendar.effective_at=policy.effective_at
   AND calendar.review_expires_at=policy.review_expires_at
  JOIN ops.action_proposals AS proposal
    ON proposal.id=policy.action_proposal_id
   AND proposal.current_version=policy.action_proposal_version
   AND proposal.action_kind='RESPONSE_POLICY_CALENDAR'
   AND proposal.target_type='BUSINESS_CALENDAR'
   AND proposal.target_id=calendar.calendar_id::text
  JOIN ops.action_proposal_versions AS proposal_version
    ON proposal_version.proposal_id=proposal.id
   AND proposal_version.version=policy.action_proposal_version
   AND proposal_version.state='APPROVED'
   AND proposal_version.terminal_at IS NOT NULL
   AND proposal_version.action_detail_kind='RESPONSE_POLICY_CALENDAR'
   AND jsonb_typeof(proposal_version.action_detail)='object'
   AND (SELECT count(*) FROM jsonb_object_keys(
         proposal_version.action_detail
       ))=11
   AND proposal_version.action_detail ?& ARRAY[
     'kind','calendarId','expectedCalendarVersion','currentCalendarDigest',
     'timezone','weekendDays','holidayDateSetDigest','policyDigest',
     'responseClockImpactDigest','effectiveAt','reviewExpiresAt'
   ]
   AND proposal_version.action_detail->>'kind'='RESPONSE_POLICY_CALENDAR'
  JOIN ops.action_approval_response_policy_calendar_details AS detail
    ON detail.proposal_id=proposal_version.proposal_id
   AND detail.proposal_version=proposal_version.version
   AND detail.detail_kind=proposal_version.action_detail_kind
   AND detail.action_detail_digest=proposal_version.action_detail_digest
   AND detail.detail_binding_canonical=
       proposal_version.action_detail_canonical
   AND detail.calendar_id=calendar.calendar_id
   AND detail.expected_calendar_version=calendar.version-1
   AND detail.current_calendar_digest=
       proposal_version.action_detail->>'currentCalendarDigest'
   AND detail.timezone=calendar.timezone
   AND to_jsonb(detail.weekend_days)=
       proposal_version.action_detail->'weekendDays'
   AND detail.holiday_date_set_digest=calendar.holiday_set_digest
   AND detail.policy_digest=policy.policy_digest
   AND detail.response_clock_impact_digest=
       proposal_version.action_detail->>'responseClockImpactDigest'
   AND detail.effective_at=calendar.effective_at
   AND detail.review_expires_at=calendar.review_expires_at
  JOIN ops.action_decisions AS first_decision
    ON first_decision.id=policy.operational_decision_receipt_id
   AND first_decision.proposal_id=proposal.id
   AND first_decision.proposal_version=proposal_version.version
   AND first_decision.approval_digest=proposal_version.approval_digest
   AND first_decision.receipt_digest=
       policy.operational_decision_receipt_digest
   AND first_decision.record_kind='DECISION'
   AND first_decision.decision_kind='APPROVE'
   AND first_decision.counts_toward_quorum
  JOIN ops.action_review_assignments AS first_assignment
    ON first_assignment.id=first_decision.assignment_id
   AND first_assignment.proposal_id=proposal.id
   AND first_assignment.proposal_version=proposal_version.version
   AND first_assignment.approval_digest=proposal_version.approval_digest
   AND first_assignment.version=first_decision.assignment_version
   AND first_assignment.assignment_generation=
       first_decision.assignment_generation
   AND first_assignment.reviewer_id=first_decision.actor_id
   AND first_assignment.state='COMPLETED'
   AND first_assignment.required_capability='responses.policy.manage'
  JOIN ops.action_decisions AS second_decision
    ON second_decision.id=policy.legal_decision_receipt_id
   AND second_decision.proposal_id=proposal.id
   AND second_decision.proposal_version=proposal_version.version
   AND second_decision.approval_digest=proposal_version.approval_digest
   AND second_decision.receipt_digest=policy.legal_decision_receipt_digest
   AND second_decision.record_kind='DECISION'
   AND second_decision.decision_kind='APPROVE'
   AND second_decision.counts_toward_quorum
   AND second_decision.actor_id<>first_decision.actor_id
  JOIN ops.action_review_assignments AS second_assignment
    ON second_assignment.id=second_decision.assignment_id
   AND second_assignment.proposal_id=proposal.id
   AND second_assignment.proposal_version=proposal_version.version
   AND second_assignment.approval_digest=proposal_version.approval_digest
   AND second_assignment.version=second_decision.assignment_version
   AND second_assignment.assignment_generation=
       second_decision.assignment_generation
   AND second_assignment.reviewer_id=second_decision.actor_id
   AND second_assignment.state='COMPLETED'
   AND second_assignment.required_capability='responses.policy.manage'
  JOIN ops.execution_receipts AS execution_receipt
    ON execution_receipt.id=policy.action_execution_receipt_id
   AND execution_receipt.receipt_digest=
       policy.action_execution_receipt_digest
   AND execution_receipt.id=calendar.execution_receipt_id
   AND execution_receipt.receipt_digest=calendar.execution_receipt_digest
   AND execution_receipt.receipt_kind='EFFECT_SUCCEEDED'
   AND execution_receipt.aggregate_state='SUCCEEDED'
   AND execution_receipt.mutates_aggregate_state
  JOIN ops.in_flight_effects AS execution
    ON execution.id=execution_receipt.execution_id
   AND execution.current_generation=execution_receipt.generation
   AND execution.action_kind='RESPONSE_POLICY_CALENDAR'
   AND execution.action_proposal_id=proposal.id
   AND execution.action_proposal_version=proposal_version.version
   AND execution.approval_digest=proposal_version.approval_digest
   AND execution.state='SUCCEEDED'
   AND execution.last_receipt_sequence=execution_receipt.receipt_sequence
   AND execution.last_receipt_digest=execution_receipt.receipt_digest
  JOIN ops.execution_authorizations AS execution_authorization
    ON execution_authorization.execution_id=execution.id
   AND execution_authorization.generation=execution.current_generation
   AND execution_authorization.proposal_id=proposal.id
   AND execution_authorization.proposal_version=proposal_version.version
   AND execution_authorization.action_kind='RESPONSE_POLICY_CALENDAR'
   AND execution_authorization.approval_digest=proposal_version.approval_digest
   AND execution_authorization.executor_id=
       'private.CreateBusinessCalendarVersion'
   AND execution_authorization.transport='PRIVATE_APPLICATION_COMMAND'
   AND execution_authorization.required_capability='responses.policy.manage'
   AND execution_authorization.target_request_sha256=
       proposal_version.content_digest
  WHERE policy.policy_id=p_policy_id AND policy.revision=p_revision
    AND policy.state='APPROVED' AND policy.timezone='Asia/Seoul'
    AND calendar.approval_proposal_id=proposal.id
    AND calendar.approval_proposal_version=proposal_version.version
    AND calendar.approval_digest=proposal_version.approval_digest
    AND proposal_version.action_detail->>'calendarId'=
        calendar.calendar_id::text
    AND (proposal_version.action_detail->>'expectedCalendarVersion')::bigint=
        detail.expected_calendar_version
    AND proposal_version.action_detail->>'timezone'=detail.timezone
    AND proposal_version.action_detail->>'holidayDateSetDigest'=
        detail.holiday_date_set_digest
    AND proposal_version.action_detail->>'policyDigest'=detail.policy_digest
    AND (proposal_version.action_detail->>'effectiveAt')::timestamptz=
        detail.effective_at
    AND (proposal_version.action_detail->>'reviewExpiresAt')::timestamptz=
        detail.review_expires_at
    AND policy.policy_payload->>'calendarVersionId'=calendar.id::text
    AND policy.policy_payload->>'calendarDigest'=calendar.calendar_digest
    AND ARRAY[first_decision.slot_kind,second_decision.slot_kind]
      @> ARRAY['response_policy_owner','calendar_operator']::text[]
    AND ARRAY[first_decision.slot_kind,second_decision.slot_kind]
      <@ ARRAY['response_policy_owner','calendar_operator']::text[]
    AND CASE first_decision.slot_kind
      WHEN 'response_policy_owner' THEN
        first_assignment.allowed_role_codes=ARRAY['EDITOR']::text[]
      WHEN 'calendar_operator' THEN
        first_assignment.allowed_role_codes=ARRAY['OPERATIONS']::text[]
      ELSE false END
    AND CASE second_decision.slot_kind
      WHEN 'response_policy_owner' THEN
        second_assignment.allowed_role_codes=ARRAY['EDITOR']::text[]
      WHEN 'calendar_operator' THEN
        second_assignment.allowed_role_codes=ARRAY['OPERATIONS']::text[]
      ELSE false END
    AND execution_authorization.counted_decision_ids
      @> ARRAY[first_decision.id,second_decision.id]
    AND cardinality(execution_authorization.counted_decision_ids)=2
    AND btrim(first_decision.receipt_digest)=ANY(
      execution_authorization.counted_decision_receipt_digests
    )
    AND btrim(second_decision.receipt_digest)=ANY(
      execution_authorization.counted_decision_receipt_digests
    )
    AND execution_authorization.terminal_decision_id IN (
      first_decision.id,second_decision.id
    )
    AND execution_authorization.terminal_decision_receipt_digest IN (
      first_decision.receipt_digest,second_decision.receipt_digest
    )
    AND (
      first_decision.quorum_satisfied_after
      AND first_decision.execution_id=execution.id
      AND NOT second_decision.quorum_satisfied_after
      AND second_decision.execution_id IS NULL
      OR second_decision.quorum_satisfied_after
      AND second_decision.execution_id=execution.id
      AND NOT first_decision.quorum_satisfied_after
      AND first_decision.execution_id IS NULL
    )
    AND NOT EXISTS(
      SELECT 1 FROM ops.action_decisions AS withdrawal
      WHERE withdrawal.record_kind='APPROVAL_WITHDRAWAL'
        AND withdrawal.withdrawn_decision_id IN (
          first_decision.id,second_decision.id
        )
    );
  RETURN v_count=1;
EXCEPTION WHEN invalid_text_representation OR datetime_field_overflow
  OR numeric_value_out_of_range THEN
  RETURN false;
END
$authority$;

CREATE OR REPLACE FUNCTION ops.current_privacy_response_policy_calendar_v1(
  p_at timestamptz
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $current$
DECLARE
  v_rows jsonb;
  v_count integer;
BEGIN
  IF p_at IS NULL OR NOT isfinite(p_at) THEN
    RAISE EXCEPTION 'privacy_response_policy_calendar_time_invalid'
      USING ERRCODE='22023';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'policyId',policy.policy_id,'revision',policy.revision,
    'policyVersion',policy.policy_version,
    'policyDigest',btrim(policy.policy_digest),
    'policyBindingDigest',btrim(policy.binding_digest),
    'accessBusinessDays',policy.access_business_days,
    'correctionBusinessDays',policy.correction_business_days,
    'deletionBusinessDays',policy.deletion_business_days,
    'restrictionBusinessDays',policy.restriction_business_days,
    'maximumExtensionBusinessDays',policy.maximum_extension_business_days,
    'maximumExtensionCount',policy.maximum_extension_count,
    'refusalNoticeBusinessDays',policy.refusal_notice_business_days,
    'calendarVersionId',calendar.id,'calendarId',calendar.calendar_id,
    'calendarVersion',calendar.version,
    'calendarDigest',btrim(calendar.calendar_digest),
    'effectiveAt',policy.effective_at,
    'reviewExpiresAt',policy.review_expires_at
  ) ORDER BY policy.effective_at,policy.policy_id,policy.revision),'[]'::jsonb)
  INTO v_rows
  FROM ops.privacy_response_calendar_policies_v1 AS policy
  JOIN ops.business_calendar_versions AS calendar
    ON calendar.id=policy.calendar_id
   AND calendar.calendar_digest=policy.policy_payload->>'calendarDigest'
  WHERE policy.state='APPROVED'
    AND policy.timezone='Asia/Seoul' AND calendar.timezone='Asia/Seoul'
    AND policy.effective_at<=p_at AND p_at<policy.review_expires_at
    AND calendar.effective_at<=p_at AND p_at<calendar.review_expires_at
    AND (
      (
        policy.authority_source<>'TEST_ONLY'
        AND policy.policy_version<>'test-only-r6d-v1'
      )
      OR (
        policy.authority_source='TEST_ONLY'
        AND policy.policy_version='test-only-r6d-v1'
        AND pg_has_role(session_user,'gurine_migrator','MEMBER')
      )
    )
    AND ops.privacy_response_policy_calendar_authority_v1_is_valid(
      policy.policy_id,policy.revision
    );
  v_count:=jsonb_array_length(v_rows);
  IF v_count=0 THEN
    RAISE EXCEPTION 'privacy_response_policy_calendar_current_missing'
      USING ERRCODE='55000';
  ELSIF v_count<>1 THEN
    RAISE EXCEPTION 'privacy_response_policy_calendar_current_ambiguous'
      USING ERRCODE='55000';
  END IF;
  RETURN v_rows->0;
END
$current$;
-- R6d TEST_ONLY privacy response-calendar selector ends.

ALTER FUNCTION ops.privacy_response_policy_calendar_authority_v1_is_valid(
  uuid,bigint
) OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.privacy_response_policy_calendar_authority_v1_is_valid(uuid,bigint)
  FROM PUBLIC;
ALTER FUNCTION ops.current_privacy_response_policy_calendar_v1(timestamptz)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.current_privacy_response_policy_calendar_v1(timestamptz) FROM PUBLIC;

-- R6d privacy response-calendar authority guard begins.
CREATE OR REPLACE FUNCTION ops.guard_privacy_response_policy_calendar_authority_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
AS $guard$
BEGIN
  IF NEW.state='APPROVED' AND NOT
     ops.privacy_response_policy_calendar_authority_v1_is_valid(
       NEW.policy_id,NEW.revision
     ) THEN
    RAISE EXCEPTION 'privacy_response_policy_calendar_authority_invalid'
      USING ERRCODE='55000';
  END IF;
  RETURN NULL;
END
$guard$;
ALTER FUNCTION ops.guard_privacy_response_policy_calendar_authority_v1()
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.guard_privacy_response_policy_calendar_authority_v1() FROM PUBLIC;
CREATE CONSTRAINT TRIGGER privacy_response_policy_calendar_authority_guard
  AFTER INSERT ON ops.privacy_response_calendar_policies_v1
  DEFERRABLE INITIALLY IMMEDIATE
  FOR EACH ROW
  EXECUTE FUNCTION ops.guard_privacy_response_policy_calendar_authority_v1();
-- R6d privacy response-calendar authority guard ends.
-- R6d privacy transition authority and business-day helpers end.

-- R6d privacy notification authority boundary.
--
-- This function intentionally returns SQL NULL when the requested outbox row,
-- its immutable receipt graph, its endpoint snapshot, or every required ACTIVE
-- sealed-content row cannot be proven exactly.  It never projects plaintext.

CREATE OR REPLACE FUNCTION ops.read_privacy_request_notification_delivery_v1(
  p_event_id uuid
) RETURNS jsonb
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,intake,extensions,pg_temp
AS $reader$
WITH event_authority AS MATERIALIZED (
  SELECT
    event.id,
    event.aggregate_type,
    event.aggregate_id,
    event.aggregate_version,
    event.event_type,
    event.payload,
    event.occurred_at,
    ops.r6d_outbox_envelope_digest_v1(event.id) AS envelope_digest
  FROM ops.outbox AS event
  WHERE p_event_id IS NOT NULL
    AND event.id=p_event_id
    AND event.aggregate_type='privacy_request'
    AND event.aggregate_version>0
    AND event.event_type IN (
      'privacy.request_created.v2',
      'privacy.request_identity_verified.v1',
      'privacy.request_extension_notified.v1',
      'privacy.request_refusal_notified.v1'
    )
    AND jsonb_typeof(event.payload)='object'
), active_sealed_content AS MATERIALIZED (
  SELECT content.*
  FROM ops.privacy_request_sealed_content_v2 AS content
  JOIN ops.record_class_schedules AS schedule
    ON schedule.id=content.retention_schedule_id
   AND schedule.record_class=content.retention_record_class
   AND schedule.schedule_digest=content.retention_schedule_digest
  WHERE content.schema_version=1
    AND content.content_state='ACTIVE'
    AND content.sealed_ciphertext IS NOT NULL
    AND content.erased_at IS NULL
    AND content.retention_record_class='PRIVACY_REQUEST_SEALED_CONTENT'
    AND content.field_kind IN (
      'REASON','EXTENSION_REASON','REJECTION_REASON','APPEAL_INSTRUCTIONS'
    )
    AND ops.r6d_lower_sha256(content.sealed_sha256)
    AND ops.r6d_lower_sha256(content.sealed_aad_digest)
    AND ops.r6d_field_envelope_v1_is_valid(
      content.sealed_ciphertext,content.encryption_key_id
    )
    AND content.sealed_aad_digest=ops.r6d_nul5_sha256_v1(
      'ops.privacy_request_sealed_content_v2',
      'sealed_ciphertext',
      content.transition_receipt_id::text,
      content.field_kind,
      '1'
    )
    AND schedule.trigger_kind='CREATED_AT'
    AND schedule.terminal_action='CRYPTO_ERASE'
    AND schedule.active_duration_seconds>0
    AND schedule.backup_duration_seconds IS NOT NULL
    AND schedule.effective_at<=content.created_at
    AND content.created_at<schedule.review_expires_at
    AND schedule.review_expires_at>clock_timestamp()
    AND content.expires_at=content.created_at+
      make_interval(secs=>schedule.active_duration_seconds::double precision)
    AND content.expires_at>clock_timestamp()
), created_binding AS (
  SELECT jsonb_build_object(
    'schemaVersion','privacy-request-notification-delivery.v1',
    'noticeType','IDENTITY_VERIFICATION_REQUIRED',
    'event',jsonb_build_object(
      'eventId',event.id,
      'eventType',event.event_type,
      'aggregateId',request.id,
      'aggregateVersion',event.aggregate_version,
      'eventEnvelopeDigest',btrim(event.envelope_digest),
      'occurredAt',event.occurred_at,
      'payload',event.payload
    ),
    'request',jsonb_build_object(
      'retentionRequestId',request.id,
      'decisionVersion',0,
      'requestType',request.request_type,
      'state','RECEIVED',
      'identityState','PENDING_VERIFICATION',
      'identityVerifiedAt',NULL,
      'dueAt',NULL
    ),
    'endpoint',jsonb_build_object(
      'endpointId',endpoint.id,
      'channel',endpoint.channel,
      'state','PENDING_VERIFICATION',
      'version',endpoint.version,
      'endpointDigest',btrim(endpoint.endpoint_digest),
      'endpointCiphertextBase64',replace(
        encode(endpoint.endpoint_ciphertext,'base64'),E'\n',''
      ),
      'encryptionKeyId',endpoint.encryption_key_id,
      'endpointAadDigest',btrim(endpoint.endpoint_aad_digest),
      'updatedAt',endpoint.created_at
    ),
    'template',jsonb_build_object(
      'kind','IDENTITY_VERIFICATION_REQUIRED'
    )
  ) AS binding
  FROM event_authority AS event
  JOIN ops.privacy_requests_v2 AS request
    ON request.id::text=event.aggregate_id
   AND request.create_outbox_event_id=event.id
   AND request.create_receipt_digest=event.payload->>'receiptDigest'
  JOIN ops.audit_events AS audit
    ON audit.id=request.create_audit_event_id
   AND audit.request_id=request.create_request_id
   AND audit.actor_type='ANONYMOUS'
   AND audit.action='command.createPrivacyRequest'
   AND audit.object_type='PRIVACY_REQUEST'
   AND audit.object_id=request.id::text
   AND audit.outcome='SUCCESS'
  JOIN intake.communication_subjects AS subject
    ON subject.id=request.communication_subject_id
   AND subject.origin_binding_digest=request.communication_subject_origin_digest
   AND subject.subject_kind='PRIVACY_REQUESTER'
   AND subject.origin_object_type='PRIVACY_REQUEST'
   AND subject.origin_object_id=request.id
   AND subject.origin_object_version=1
   AND subject.status='ACTIVE'
  JOIN intake.communication_endpoints AS endpoint
    ON endpoint.id=request.communication_endpoint_id
   AND endpoint.subject_id=subject.id
   AND endpoint.version=request.communication_endpoint_version
   AND endpoint.endpoint_digest=request.communication_endpoint_digest
  WHERE event.event_type='privacy.request_created.v2'
    AND event.aggregate_version=1
    AND ops.r6d_lower_sha256(event.envelope_digest)
    AND event.occurred_at=request.created_at
    -- append_audit_event owns its timestamp and is called after v_now is
    -- captured for the request/outbox envelope. Bind order plus exact stored
    -- IDs/digests; equality would make every valid create graph unreadable.
    AND audit.occurred_at>=event.occurred_at
    AND jsonb_typeof(audit.details)='object'
    AND audit.details->'receiptDigest'=event.payload->'receiptDigest'
    AND audit.details->'commandReceiptDigest'=
      event.payload->'commandReceiptDigest'
    AND endpoint.version=1
    AND endpoint.created_at=event.occurred_at
    AND endpoint.revoked_at IS NULL
    AND endpoint.bounced_at IS NULL
    AND endpoint.suppressed_at IS NULL
    AND (
      endpoint.state='PENDING_VERIFICATION'
      AND endpoint.verified_at IS NULL
      OR endpoint.state='ACTIVE'
      AND endpoint.verified_at IS NOT NULL
      AND EXISTS(
        SELECT 1
        FROM intake.communication_endpoint_link_events AS link
        JOIN intake.communication_endpoint_verifications AS verification
          ON verification.id=link.verification_id
         AND verification.subject_id=link.subject_id
         AND verification.endpoint_id=link.endpoint_id
         AND verification.endpoint_version=link.endpoint_version
         AND verification.endpoint_snapshot_digest=
           link.endpoint_snapshot_digest
         AND verification.state='VERIFIED'
         AND verification.proof_digest=link.proof_digest
         AND verification.receipt_digest=link.receipt_digest
         AND verification.issued_at>=event.occurred_at
         AND verification.verified_at=link.occurred_at
         AND verification.consumed_at=verification.verified_at
        WHERE link.subject_id=subject.id
          AND link.subject_origin_binding_digest=
            subject.origin_binding_digest
          AND link.endpoint_id=endpoint.id
          AND link.endpoint_version=endpoint.version
          AND link.endpoint_snapshot_digest=endpoint.endpoint_digest
          AND link.channel=endpoint.channel
          AND link.state='ACTIVE'
          AND link.change_kind='VERIFIED'
          AND link.occurred_at=endpoint.verified_at
          AND NOT EXISTS(
            SELECT 1
            FROM intake.communication_endpoint_link_events AS later
            WHERE later.endpoint_id=link.endpoint_id
              AND later.endpoint_sequence>link.endpoint_sequence
          )
      )
    )
    AND endpoint.channel IN (
      'SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD',
      'LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE'
    )
    AND endpoint.endpoint_aad_digest=ops.r6d_nul5_sha256_v1(
      'intake.communication_endpoints',
      'endpoint_ciphertext',
      endpoint.id::text,
      CASE endpoint.channel
        WHEN 'SMTP_EMAIL' THEN 'email-address'
        WHEN 'TELEGRAM_BOT_API' THEN 'provider-identifier'
        WHEN 'LINE_MESSAGING_API' THEN 'provider-identifier'
        ELSE 'phone-number'
      END,
      '1'
    )
    AND ops.r6d_field_envelope_v1_is_valid(
      endpoint.endpoint_ciphertext,endpoint.encryption_key_id
    )
    AND endpoint.endpoint_digest=encode(extensions.digest(
      ops.canonical_jsonb_v1(jsonb_build_object(
        'schemaVersion','privacy-communication-endpoint.v1',
        'endpointId',endpoint.id,'subjectId',endpoint.subject_id,
        'channel',endpoint.channel,
        'endpointHmac',btrim(endpoint.endpoint_hmac),
        'hmacKeyVersion',endpoint.hmac_key_version,
        'endpointCiphertextSha256',encode(extensions.digest(
          endpoint.endpoint_ciphertext,'sha256'
        ),'hex'),
        'encryptionKeyId',endpoint.encryption_key_id,
        'endpointAadDigest',btrim(endpoint.endpoint_aad_digest),
        'state','PENDING_VERIFICATION','version',endpoint.version
      )),'sha256'
    ),'hex')
    AND (SELECT count(*) FROM jsonb_object_keys(event.payload))=10
    AND event.payload ?& ARRAY[
      'retentionRequestId','requestType','subjectProofHash','jurisdiction',
      'scopeDigest','identityState','identityVerifiedAt','dueAt',
      'receiptDigest','commandReceiptDigest'
    ]
    AND event.payload->'retentionRequestId'=to_jsonb(request.id)
    AND event.payload->'requestType'=to_jsonb(request.request_type)
    AND event.payload->'subjectProofHash'=to_jsonb(btrim(request.subject_proof_hash))
    AND event.payload->'jurisdiction'=to_jsonb(request.jurisdiction)
    AND event.payload->'scopeDigest'=to_jsonb(btrim(request.scope_sha256))
    AND event.payload->'identityState'='"PENDING_VERIFICATION"'::jsonb
    AND event.payload->'identityVerifiedAt'='null'::jsonb
    AND event.payload->'dueAt'='null'::jsonb
    AND event.payload->'receiptDigest'=to_jsonb(btrim(request.create_receipt_digest))
    AND ops.r6d_lower_sha256(event.payload->>'commandReceiptDigest')
), identity_binding AS (
  SELECT jsonb_build_object(
    'schemaVersion','privacy-request-notification-delivery.v1',
    'noticeType','IDENTITY_VERIFIED',
    'event',jsonb_build_object(
      'eventId',event.id,
      'eventType',event.event_type,
      'aggregateId',request.id,
      'aggregateVersion',event.aggregate_version,
      'eventEnvelopeDigest',btrim(event.envelope_digest),
      'occurredAt',event.occurred_at,
      'payload',event.payload
    ),
    'request',jsonb_build_object(
      'retentionRequestId',request.id,
      'decisionVersion',transition.decision_version,
      'requestType',request.request_type,
      'state',transition.state,
      'identityState',identity.identity_state,
      'identityVerifiedAt',identity.identity_verified_at,
      'dueAt',identity.due_at
    ),
    'transition',jsonb_build_object(
      'transitionReceiptId',transition.transition_receipt_id,
      'transitionReceiptDigest',btrim(transition.receipt_digest),
      'eventReceiptId',transition.event_receipt_id,
      'eventReceiptDigest',btrim(transition.event_receipt_digest),
      'branchReceiptDigest',btrim(identity.receipt_digest),
      'noticeReceiptId',notice.notice_receipt_id,
      'noticeReceiptDigest',btrim(notice.receipt_digest)
    ),
    'endpoint',jsonb_build_object(
      'endpointId',endpoint.id,
      'channel',endpoint.channel,
      'state',endpoint.state,
      'version',endpoint.version,
      'endpointDigest',btrim(endpoint.endpoint_digest),
      'endpointCiphertextBase64',replace(
        encode(endpoint.endpoint_ciphertext,'base64'),E'\n',''
      ),
      'encryptionKeyId',endpoint.encryption_key_id,
      'endpointAadDigest',btrim(endpoint.endpoint_aad_digest),
      'updatedAt',endpoint.updated_at
    ),
    'template',jsonb_build_object(
      'kind','IDENTITY_VERIFIED',
      'dueAt',identity.due_at,
      'reasonCiphertextBase64',replace(
        encode(reason.sealed_ciphertext,'base64'),E'\n',''
      ),
      'reasonSha256',btrim(reason.sealed_sha256),
      'reasonEncryptionKeyId',reason.encryption_key_id,
      'reasonAadDigest',btrim(reason.sealed_aad_digest)
    )
  ) AS binding
  FROM event_authority AS event
  JOIN ops.privacy_requests_v2 AS request
    ON request.id::text=event.aggregate_id
  JOIN ops.privacy_request_transition_receipts_v2 AS transition
    ON transition.privacy_request_id=request.id
   AND transition.decision_version=event.aggregate_version
   AND transition.transition='VERIFY_IDENTITY'
   AND transition.prior_state='RECEIVED'
   AND transition.state='RECEIVED'
   AND transition.event_receipt_id=event.id
  JOIN ops.privacy_request_identity_receipts_v2 AS identity
    ON identity.identity_receipt_id=transition.identity_receipt_id
   AND identity.privacy_request_id=transition.privacy_request_id
   AND identity.decision_version=transition.decision_version
   AND identity.receipt_digest=transition.identity_receipt_digest
   AND identity.event_receipt_id=transition.event_receipt_id
   AND identity.event_receipt_digest=transition.event_receipt_digest
  JOIN ops.privacy_request_notice_receipts_v2 AS notice
    ON notice.notice_receipt_id=transition.notice_receipt_id
   AND notice.privacy_request_id=transition.privacy_request_id
   AND notice.transition_receipt_id=transition.transition_receipt_id
   AND notice.receipt_digest=transition.notice_receipt_digest
   AND notice.notice_kind='IDENTITY_VERIFIED'
   AND notice.branch_receipt_id=identity.identity_receipt_id
   AND notice.branch_receipt_digest=identity.receipt_digest
   AND notice.event_receipt_id=transition.event_receipt_id
   AND notice.event_receipt_digest=transition.event_receipt_digest
  JOIN intake.communication_endpoints AS endpoint
    ON endpoint.id=request.communication_endpoint_id
   AND endpoint.subject_id=request.communication_subject_id
   AND endpoint.version=request.communication_endpoint_version
   AND endpoint.endpoint_digest=request.communication_endpoint_digest
   AND endpoint.id=notice.endpoint_id
   AND endpoint.version=notice.endpoint_version
   AND endpoint.endpoint_digest=notice.endpoint_digest
   AND endpoint.endpoint_aad_digest=notice.endpoint_aad_digest
  JOIN active_sealed_content AS reason
    ON reason.transition_receipt_id=transition.transition_receipt_id
   AND reason.privacy_request_id=transition.privacy_request_id
   AND reason.field_kind='REASON'
   AND reason.sealed_sha256=transition.reason_sha256
   AND reason.sealed_aad_digest=transition.reason_aad_digest
   AND reason.encryption_key_id=transition.encryption_key_id
  WHERE event.event_type='privacy.request_identity_verified.v1'
    AND ops.r6d_lower_sha256(event.envelope_digest)
    AND event.id=ANY(transition.outbox_event_ids)
    AND transition.event_receipt_digest=event.envelope_digest
    AND identity.notice_receipt_id=notice.notice_receipt_id
    AND identity.notice_receipt_digest=notice.receipt_digest
    AND request.current_identity_receipt_id=identity.identity_receipt_id
    AND request.current_identity_receipt_digest=identity.receipt_digest
    AND endpoint.state='ACTIVE'
    AND endpoint.channel IN (
      'SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD',
      'LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE'
    )
    AND endpoint.updated_at<=event.occurred_at
    AND ops.r6d_field_envelope_v1_is_valid(
      endpoint.endpoint_ciphertext,endpoint.encryption_key_id
    )
    AND endpoint.endpoint_aad_digest=ops.r6d_nul5_sha256_v1(
      'intake.communication_endpoints','endpoint_ciphertext',endpoint.id::text,
      CASE endpoint.channel
        WHEN 'SMTP_EMAIL' THEN 'email-address'
        WHEN 'TELEGRAM_BOT_API' THEN 'provider-identifier'
        WHEN 'LINE_MESSAGING_API' THEN 'provider-identifier'
        ELSE 'phone-number'
      END,'1'
    )
    AND reason.created_at<=event.occurred_at
    AND (SELECT count(*)
         FROM ops.privacy_request_sealed_content_v2 AS content
         WHERE content.transition_receipt_id=transition.transition_receipt_id)=1
    AND (SELECT count(*) FROM jsonb_object_keys(event.payload))=12
    AND event.payload ?& ARRAY[
      'retentionRequestId','requestType','priorIdentityState','identityState',
      'identityProofReceiptDigest','identityVerifiedAt','responsePolicyVersion',
      'responsePolicyDigest','calendarVersionId','calendarDigest','dueAt',
      'verificationReceiptDigest'
    ]
    AND event.payload->'retentionRequestId'=to_jsonb(request.id)
    AND event.payload->'requestType'=to_jsonb(request.request_type)
    AND event.payload->'priorIdentityState'=to_jsonb(identity.prior_identity_state)
    AND event.payload->'identityState'=to_jsonb(identity.identity_state)
    AND event.payload->'identityProofReceiptDigest'=
      to_jsonb(btrim(identity.identity_proof_receipt_digest))
    AND event.payload->'identityVerifiedAt'=to_jsonb(identity.identity_verified_at)
    AND event.payload->'responsePolicyVersion'=to_jsonb(identity.response_policy_version)
    AND event.payload->'responsePolicyDigest'=to_jsonb(btrim(identity.response_policy_digest))
    AND event.payload->'calendarVersionId'=to_jsonb(identity.calendar_version_id)
    AND event.payload->'calendarDigest'=to_jsonb(btrim(identity.calendar_digest))
    AND event.payload->'dueAt'=to_jsonb(identity.due_at)
    AND event.payload->'verificationReceiptDigest'=to_jsonb(btrim(identity.receipt_digest))
), extension_binding AS (
  SELECT jsonb_build_object(
    'schemaVersion','privacy-request-notification-delivery.v1',
    'noticeType','EXTENSION',
    'event',jsonb_build_object(
      'eventId',event.id,'eventType',event.event_type,
      'aggregateId',request.id,'aggregateVersion',event.aggregate_version,
      'eventEnvelopeDigest',btrim(event.envelope_digest),
      'occurredAt',event.occurred_at,'payload',event.payload
    ),
    'request',jsonb_build_object(
      'retentionRequestId',request.id,
      'decisionVersion',transition.decision_version,
      'requestType',request.request_type,
      'state',transition.state,
      'identityState','VERIFIED',
      'identityVerifiedAt',identity.identity_verified_at,
      'dueAt',extension.due_at
    ),
    'transition',jsonb_build_object(
      'transitionReceiptId',transition.transition_receipt_id,
      'transitionReceiptDigest',btrim(transition.receipt_digest),
      'eventReceiptId',transition.event_receipt_id,
      'eventReceiptDigest',btrim(transition.event_receipt_digest),
      'branchReceiptDigest',btrim(extension.receipt_digest),
      'noticeReceiptId',notice.notice_receipt_id,
      'noticeReceiptDigest',btrim(notice.receipt_digest)
    ),
    'endpoint',jsonb_build_object(
      'endpointId',endpoint.id,'channel',endpoint.channel,
      'state',endpoint.state,'version',endpoint.version,
      'endpointDigest',btrim(endpoint.endpoint_digest),
      'endpointCiphertextBase64',replace(
        encode(endpoint.endpoint_ciphertext,'base64'),E'\n',''
      ),
      'encryptionKeyId',endpoint.encryption_key_id,
      'endpointAadDigest',btrim(endpoint.endpoint_aad_digest),
      'updatedAt',endpoint.updated_at
    ),
    'template',jsonb_build_object(
      'kind','EXTENSION',
      'priorDueAt',extension.prior_due_at,
      'dueAt',extension.due_at,
      'extensionBusinessDays',extension.extension_business_days,
      'reasonCode',extension.extension_reason_code,
      'reasonCiphertextBase64',replace(
        encode(reason.sealed_ciphertext,'base64'),E'\n',''
      ),
      'reasonSha256',btrim(reason.sealed_sha256),
      'reasonEncryptionKeyId',reason.encryption_key_id,
      'reasonAadDigest',btrim(reason.sealed_aad_digest),
      'extensionReasonCiphertextBase64',replace(
        encode(extension_reason.sealed_ciphertext,'base64'),E'\n',''
      ),
      'extensionReasonSha256',btrim(extension_reason.sealed_sha256),
      'extensionReasonEncryptionKeyId',extension_reason.encryption_key_id,
      'extensionReasonAadDigest',btrim(extension_reason.sealed_aad_digest)
    )
  ) AS binding
  FROM event_authority AS event
  JOIN ops.privacy_requests_v2 AS request
    ON request.id::text=event.aggregate_id
  JOIN ops.privacy_request_transition_receipts_v2 AS transition
    ON transition.privacy_request_id=request.id
   AND transition.decision_version=event.aggregate_version
   AND transition.transition='EXTEND'
   AND transition.state IN ('RECEIVED','REVIEW','APPROVED')
   AND transition.event_receipt_id=event.id
  JOIN ops.privacy_request_extension_receipts_v2 AS extension
    ON extension.extension_receipt_id=transition.extension_receipt_id
   AND extension.privacy_request_id=transition.privacy_request_id
   AND extension.decision_version=transition.decision_version
   AND extension.receipt_digest=transition.extension_receipt_digest
   AND extension.event_receipt_id=transition.event_receipt_id
   AND extension.event_receipt_digest=transition.event_receipt_digest
  JOIN ops.privacy_request_notice_receipts_v2 AS notice
    ON notice.notice_receipt_id=transition.notice_receipt_id
   AND notice.privacy_request_id=transition.privacy_request_id
   AND notice.transition_receipt_id=transition.transition_receipt_id
   AND notice.receipt_digest=transition.notice_receipt_digest
   AND notice.notice_kind='EXTENSION'
   AND notice.branch_receipt_id=extension.extension_receipt_id
   AND notice.branch_receipt_digest=extension.receipt_digest
   AND notice.event_receipt_id=transition.event_receipt_id
   AND notice.event_receipt_digest=transition.event_receipt_digest
  JOIN ops.privacy_request_identity_receipts_v2 AS identity
    ON identity.identity_receipt_id=request.current_identity_receipt_id
   AND identity.privacy_request_id=request.id
   AND identity.receipt_digest=request.current_identity_receipt_digest
  JOIN ops.privacy_response_calendar_policies_v1 AS policy
    ON policy.policy_id=extension.response_policy_id
   AND policy.revision=extension.response_policy_revision
   AND policy.policy_digest=extension.response_policy_digest
  JOIN intake.communication_endpoints AS endpoint
    ON endpoint.id=request.communication_endpoint_id
   AND endpoint.subject_id=request.communication_subject_id
   AND endpoint.version=request.communication_endpoint_version
   AND endpoint.endpoint_digest=request.communication_endpoint_digest
   AND endpoint.id=notice.endpoint_id
   AND endpoint.version=notice.endpoint_version
   AND endpoint.endpoint_digest=notice.endpoint_digest
   AND endpoint.endpoint_aad_digest=notice.endpoint_aad_digest
  JOIN active_sealed_content AS reason
    ON reason.transition_receipt_id=transition.transition_receipt_id
   AND reason.privacy_request_id=transition.privacy_request_id
   AND reason.field_kind='REASON'
   AND reason.sealed_sha256=transition.reason_sha256
   AND reason.sealed_aad_digest=transition.reason_aad_digest
   AND reason.encryption_key_id=transition.encryption_key_id
  JOIN active_sealed_content AS extension_reason
    ON extension_reason.transition_receipt_id=transition.transition_receipt_id
   AND extension_reason.privacy_request_id=transition.privacy_request_id
   AND extension_reason.field_kind='EXTENSION_REASON'
   AND extension_reason.sealed_sha256=transition.extension_reason_sha256
   AND extension_reason.sealed_aad_digest=transition.extension_reason_aad_digest
   AND extension_reason.sealed_sha256=extension.extension_reason_sha256
   AND extension_reason.encryption_key_id=transition.encryption_key_id
  WHERE event.event_type='privacy.request_extension_notified.v1'
    AND ops.r6d_lower_sha256(event.envelope_digest)
    AND event.id=ANY(transition.outbox_event_ids)
    AND transition.event_receipt_digest=event.envelope_digest
    AND extension.notice_receipt_id=notice.notice_receipt_id
    AND extension.notice_receipt_digest=notice.receipt_digest
    AND request.current_extension_receipt_id=extension.extension_receipt_id
    AND request.current_extension_receipt_digest=extension.receipt_digest
    AND request.identity_state='VERIFIED'
    AND request.due_at=extension.due_at
    AND request.response_policy_id=extension.response_policy_id
    AND request.response_policy_revision=extension.response_policy_revision
    AND request.response_policy_digest=extension.response_policy_digest
    AND request.calendar_version_id=extension.calendar_version_id
    AND request.calendar_digest=extension.calendar_digest
    AND transition.extension_reason_code=extension.extension_reason_code
    AND endpoint.state='ACTIVE'
    AND endpoint.channel IN (
      'SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD',
      'LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE'
    )
    AND endpoint.updated_at<=event.occurred_at
    AND ops.r6d_field_envelope_v1_is_valid(
      endpoint.endpoint_ciphertext,endpoint.encryption_key_id
    )
    AND endpoint.endpoint_aad_digest=ops.r6d_nul5_sha256_v1(
      'intake.communication_endpoints','endpoint_ciphertext',endpoint.id::text,
      CASE endpoint.channel
        WHEN 'SMTP_EMAIL' THEN 'email-address'
        WHEN 'TELEGRAM_BOT_API' THEN 'provider-identifier'
        WHEN 'LINE_MESSAGING_API' THEN 'provider-identifier'
        ELSE 'phone-number'
      END,'1'
    )
    AND reason.created_at<=event.occurred_at
    AND extension_reason.created_at<=event.occurred_at
    AND (SELECT count(*)
         FROM ops.privacy_request_sealed_content_v2 AS content
         WHERE content.transition_receipt_id=transition.transition_receipt_id)=2
    AND (SELECT count(*) FROM jsonb_object_keys(event.payload))=13
    AND event.payload ?& ARRAY[
      'retentionRequestId','requestType','priorDueAt','dueAt',
      'extensionBusinessDays','extensionSequence','reasonDigest',
      'responsePolicyVersion','responsePolicyDigest','calendarVersionId',
      'calendarDigest','notifiedAt','notificationReceiptDigest'
    ]
    AND event.payload->'retentionRequestId'=to_jsonb(request.id)
    AND event.payload->'requestType'=to_jsonb(request.request_type)
    AND event.payload->'priorDueAt'=to_jsonb(extension.prior_due_at)
    AND event.payload->'dueAt'=to_jsonb(extension.due_at)
    AND event.payload->'extensionBusinessDays'=to_jsonb(extension.extension_business_days)
    AND event.payload->'extensionSequence'=to_jsonb(extension.extension_sequence)
    AND event.payload->'reasonDigest'=to_jsonb(btrim(extension.extension_reason_sha256))
    AND event.payload->'responsePolicyVersion'=to_jsonb(policy.policy_version)
    AND event.payload->'responsePolicyDigest'=to_jsonb(btrim(extension.response_policy_digest))
    AND event.payload->'calendarVersionId'=to_jsonb(extension.calendar_version_id)
    AND event.payload->'calendarDigest'=to_jsonb(btrim(extension.calendar_digest))
    AND event.payload->'notifiedAt'=to_jsonb(notice.created_at)
    AND event.payload->'notificationReceiptDigest'=to_jsonb(btrim(notice.receipt_digest))
), refusal_binding AS (
  SELECT jsonb_build_object(
    'schemaVersion','privacy-request-notification-delivery.v1',
    'noticeType','REFUSAL',
    'event',jsonb_build_object(
      'eventId',event.id,'eventType',event.event_type,
      'aggregateId',request.id,'aggregateVersion',event.aggregate_version,
      'eventEnvelopeDigest',btrim(event.envelope_digest),
      'occurredAt',event.occurred_at,'payload',event.payload
    ),
    'request',jsonb_build_object(
      'retentionRequestId',request.id,
      'decisionVersion',transition.decision_version,
      'requestType',request.request_type,
      'state',transition.state,
      'identityState','VERIFIED',
      'identityVerifiedAt',identity.identity_verified_at,
      'dueAt',request.due_at
    ),
    'transition',jsonb_build_object(
      'transitionReceiptId',transition.transition_receipt_id,
      'transitionReceiptDigest',btrim(transition.receipt_digest),
      'eventReceiptId',transition.event_receipt_id,
      'eventReceiptDigest',btrim(transition.event_receipt_digest),
      'branchReceiptDigest',btrim(refusal.receipt_digest),
      'noticeReceiptId',notice.notice_receipt_id,
      'noticeReceiptDigest',btrim(notice.receipt_digest)
    ),
    'endpoint',jsonb_build_object(
      'endpointId',endpoint.id,'channel',endpoint.channel,
      'state',endpoint.state,'version',endpoint.version,
      'endpointDigest',btrim(endpoint.endpoint_digest),
      'endpointCiphertextBase64',replace(
        encode(endpoint.endpoint_ciphertext,'base64'),E'\n',''
      ),
      'encryptionKeyId',endpoint.encryption_key_id,
      'endpointAadDigest',btrim(endpoint.endpoint_aad_digest),
      'updatedAt',endpoint.updated_at
    ),
    'template',jsonb_build_object(
      'kind','REFUSAL',
      'decisionAt',refusal.decision_at,
      'noticeDueAt',refusal.notice_due_at,
      'reasonCode',refusal.rejection_reason_code,
      'reasonCiphertextBase64',replace(
        encode(reason.sealed_ciphertext,'base64'),E'\n',''
      ),
      'reasonSha256',btrim(reason.sealed_sha256),
      'reasonEncryptionKeyId',reason.encryption_key_id,
      'reasonAadDigest',btrim(reason.sealed_aad_digest),
      'rejectionReasonCiphertextBase64',replace(
        encode(rejection_reason.sealed_ciphertext,'base64'),E'\n',''
      ),
      'rejectionReasonSha256',btrim(rejection_reason.sealed_sha256),
      'rejectionReasonEncryptionKeyId',rejection_reason.encryption_key_id,
      'rejectionReasonAadDigest',btrim(rejection_reason.sealed_aad_digest),
      'appealInstructionsCiphertextBase64',replace(
        encode(appeal_instructions.sealed_ciphertext,'base64'),E'\n',''
      ),
      'appealInstructionsSha256',btrim(appeal_instructions.sealed_sha256),
      'appealInstructionsEncryptionKeyId',appeal_instructions.encryption_key_id,
      'appealInstructionsAadDigest',btrim(appeal_instructions.sealed_aad_digest)
    )
  ) AS binding
  FROM event_authority AS event
  JOIN ops.privacy_requests_v2 AS request
    ON request.id::text=event.aggregate_id
  JOIN ops.privacy_request_transition_receipts_v2 AS transition
    ON transition.privacy_request_id=request.id
   AND transition.decision_version=event.aggregate_version
   AND transition.transition='REJECT'
   AND transition.state='REJECTED'
   AND transition.event_receipt_id=event.id
  JOIN ops.privacy_request_refusal_receipts_v2 AS refusal
    ON refusal.refusal_receipt_id=transition.refusal_receipt_id
   AND refusal.privacy_request_id=transition.privacy_request_id
   AND refusal.decision_version=transition.decision_version
   AND refusal.receipt_digest=transition.refusal_receipt_digest
   AND refusal.event_receipt_id=transition.event_receipt_id
   AND refusal.event_receipt_digest=transition.event_receipt_digest
  JOIN ops.privacy_request_notice_receipts_v2 AS notice
    ON notice.notice_receipt_id=transition.notice_receipt_id
   AND notice.privacy_request_id=transition.privacy_request_id
   AND notice.transition_receipt_id=transition.transition_receipt_id
   AND notice.receipt_digest=transition.notice_receipt_digest
   AND notice.notice_kind='REFUSAL'
   AND notice.branch_receipt_id=refusal.refusal_receipt_id
   AND notice.branch_receipt_digest=refusal.receipt_digest
   AND notice.event_receipt_id=transition.event_receipt_id
   AND notice.event_receipt_digest=transition.event_receipt_digest
  JOIN ops.privacy_request_identity_receipts_v2 AS identity
    ON identity.identity_receipt_id=request.current_identity_receipt_id
   AND identity.privacy_request_id=request.id
   AND identity.receipt_digest=request.current_identity_receipt_digest
  JOIN ops.privacy_response_calendar_policies_v1 AS policy
    ON policy.policy_id=refusal.response_policy_id
   AND policy.revision=refusal.response_policy_revision
   AND policy.policy_digest=refusal.response_policy_digest
  JOIN intake.communication_endpoints AS endpoint
    ON endpoint.id=request.communication_endpoint_id
   AND endpoint.subject_id=request.communication_subject_id
   AND endpoint.version=request.communication_endpoint_version
   AND endpoint.endpoint_digest=request.communication_endpoint_digest
   AND endpoint.id=notice.endpoint_id
   AND endpoint.version=notice.endpoint_version
   AND endpoint.endpoint_digest=notice.endpoint_digest
   AND endpoint.endpoint_aad_digest=notice.endpoint_aad_digest
  JOIN active_sealed_content AS reason
    ON reason.transition_receipt_id=transition.transition_receipt_id
   AND reason.privacy_request_id=transition.privacy_request_id
   AND reason.field_kind='REASON'
   AND reason.sealed_sha256=transition.reason_sha256
   AND reason.sealed_aad_digest=transition.reason_aad_digest
   AND reason.encryption_key_id=transition.encryption_key_id
  JOIN active_sealed_content AS rejection_reason
    ON rejection_reason.transition_receipt_id=transition.transition_receipt_id
   AND rejection_reason.privacy_request_id=transition.privacy_request_id
   AND rejection_reason.field_kind='REJECTION_REASON'
   AND rejection_reason.sealed_sha256=transition.rejection_reason_sha256
   AND rejection_reason.sealed_aad_digest=transition.rejection_reason_aad_digest
   AND rejection_reason.sealed_sha256=refusal.rejection_reason_sha256
   AND rejection_reason.encryption_key_id=transition.encryption_key_id
  JOIN active_sealed_content AS appeal_instructions
    ON appeal_instructions.transition_receipt_id=transition.transition_receipt_id
   AND appeal_instructions.privacy_request_id=transition.privacy_request_id
   AND appeal_instructions.field_kind='APPEAL_INSTRUCTIONS'
   AND appeal_instructions.sealed_sha256=transition.appeal_instructions_sha256
   AND appeal_instructions.sealed_aad_digest=
     transition.appeal_instructions_aad_digest
   AND appeal_instructions.sealed_sha256=refusal.appeal_instructions_sha256
   AND appeal_instructions.encryption_key_id=transition.encryption_key_id
  WHERE event.event_type='privacy.request_refusal_notified.v1'
    AND ops.r6d_lower_sha256(event.envelope_digest)
    AND event.id=ANY(transition.outbox_event_ids)
    AND transition.event_receipt_digest=event.envelope_digest
    AND refusal.notice_receipt_id=notice.notice_receipt_id
    AND refusal.notice_receipt_digest=notice.receipt_digest
    AND request.current_refusal_receipt_id=refusal.refusal_receipt_id
    AND request.current_refusal_receipt_digest=refusal.receipt_digest
    AND request.current_notice_receipt_id=notice.notice_receipt_id
    AND request.current_notice_receipt_digest=notice.receipt_digest
    AND request.state='REJECTED'
    AND request.identity_state='VERIFIED'
    AND request.response_policy_id=refusal.response_policy_id
    AND request.response_policy_revision=refusal.response_policy_revision
    AND request.response_policy_digest=refusal.response_policy_digest
    AND request.calendar_version_id=refusal.calendar_version_id
    AND request.calendar_digest=refusal.calendar_digest
    AND transition.rejection_reason_code=refusal.rejection_reason_code
    AND endpoint.state='ACTIVE'
    AND endpoint.channel IN (
      'SMTP_EMAIL','TELEGRAM_BOT_API','META_WHATSAPP_BUSINESS_CLOUD',
      'LINE_MESSAGING_API','SOLAPI_SMS','SOLAPI_KAKAO_BIZMESSAGE'
    )
    AND endpoint.updated_at<=event.occurred_at
    AND ops.r6d_field_envelope_v1_is_valid(
      endpoint.endpoint_ciphertext,endpoint.encryption_key_id
    )
    AND endpoint.endpoint_aad_digest=ops.r6d_nul5_sha256_v1(
      'intake.communication_endpoints','endpoint_ciphertext',endpoint.id::text,
      CASE endpoint.channel
        WHEN 'SMTP_EMAIL' THEN 'email-address'
        WHEN 'TELEGRAM_BOT_API' THEN 'provider-identifier'
        WHEN 'LINE_MESSAGING_API' THEN 'provider-identifier'
        ELSE 'phone-number'
      END,'1'
    )
    AND reason.created_at<=event.occurred_at
    AND rejection_reason.created_at<=event.occurred_at
    AND appeal_instructions.created_at<=event.occurred_at
    AND (SELECT count(*)
         FROM ops.privacy_request_sealed_content_v2 AS content
         WHERE content.transition_receipt_id=transition.transition_receipt_id)=3
    AND (SELECT count(*) FROM jsonb_object_keys(event.payload))=13
    AND event.payload ?& ARRAY[
      'retentionRequestId','requestType','decisionDigest','reasonDigest',
      'appealInstructionsDigest','responsePolicyVersion','responsePolicyDigest',
      'calendarVersionId','calendarDigest','decisionAt','noticeDueAt',
      'notifiedAt','notificationReceiptDigest'
    ]
    AND event.payload->'retentionRequestId'=to_jsonb(request.id)
    AND event.payload->'requestType'=to_jsonb(request.request_type)
    AND event.payload->'decisionDigest'=to_jsonb(btrim(refusal.decision_digest))
    AND event.payload->'reasonDigest'=to_jsonb(btrim(refusal.rejection_reason_sha256))
    AND event.payload->'appealInstructionsDigest'=
      to_jsonb(btrim(refusal.appeal_instructions_sha256))
    AND event.payload->'responsePolicyVersion'=to_jsonb(policy.policy_version)
    AND event.payload->'responsePolicyDigest'=to_jsonb(btrim(refusal.response_policy_digest))
    AND event.payload->'calendarVersionId'=to_jsonb(refusal.calendar_version_id)
    AND event.payload->'calendarDigest'=to_jsonb(btrim(refusal.calendar_digest))
    AND event.payload->'decisionAt'=to_jsonb(refusal.decision_at)
    AND event.payload->'noticeDueAt'=to_jsonb(refusal.notice_due_at)
    AND event.payload->'notifiedAt'=to_jsonb(notice.created_at)
    AND event.payload->'notificationReceiptDigest'=to_jsonb(btrim(notice.receipt_digest))
), candidate AS (
  SELECT binding FROM created_binding
  UNION ALL
  SELECT binding FROM identity_binding
  UNION ALL
  SELECT binding FROM extension_binding
  UNION ALL
  SELECT binding FROM refusal_binding
)
SELECT (jsonb_agg(candidate.binding)->0)
FROM candidate
HAVING count(*)=1
$reader$;

ALTER FUNCTION ops.read_privacy_request_notification_delivery_v1(uuid)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION ops.read_privacy_request_notification_delivery_v1(uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.read_privacy_request_notification_delivery_v1(uuid)
  TO gurine_notification_worker;

-- R6d privacy-request Control API safe-reader integration begins.
-- R6d privacy-request Control API safe readers.
--
-- Required integration order inside 0038_r6d_legal_hardening.sql:
--   1. ops.privacy_response_policy_calendar_authority_v1_is_valid(uuid,bigint)
--      from /tmp/r6d-privacy-transition-draft.sql;
--   2. ops.r6d_privacy_request_legal_hold_coverage_v1(uuid,timestamptz)
--      from /tmp/r6d-retention-executor.sql;
--   3. the two readers below;
--   4. the terminal 0038 COMMIT.
--
-- There is no authenticated cursor codec/HMAC authority in the active source.
-- A non-null cursor, or a result that would require another page, therefore
-- fails closed with SQLSTATE 55000.  Never replace that gate with an offset,
-- a bare digest, or any other unauthenticated cursor.

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
    'completionReceiptId',NULL,
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

CREATE OR REPLACE FUNCTION ops.read_privacy_retention_request_queue_v2(
  p_filters jsonb
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path=pg_catalog,ops,pg_temp
SET timezone='UTC'
AS $queue$
DECLARE
  v_as_of timestamptz:=statement_timestamp();
  v_request_types text[];
  v_states text[];
  v_due_before timestamptz;
  v_legal_hold_blocked boolean;
  v_sort text;
  v_limit integer;
  v_request_id uuid;
  v_workspace jsonb;
  v_items jsonb:='[]'::jsonb;
  v_match_count bigint:=0;
BEGIN
  IF jsonb_typeof(p_filters)<>'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_filters))<>7
     OR NOT p_filters ?& ARRAY[
       'requestType','state','dueBefore','legalHoldBlocked',
       'sort','limit','cursor'
     ]
     OR jsonb_typeof(p_filters->'requestType')<>'array'
     OR jsonb_typeof(p_filters->'state')<>'array'
     OR jsonb_array_length(p_filters->'requestType')>4
     OR jsonb_array_length(p_filters->'state')>5
     OR EXISTS(
       SELECT 1 FROM jsonb_array_elements(p_filters->'requestType') AS item(value)
       WHERE jsonb_typeof(item.value)<>'string'
          OR item.value#>>'{}' NOT IN (
            'ACCESS','CORRECTION','DELETION','RESTRICTION'
          )
     )
     OR EXISTS(
       SELECT 1 FROM jsonb_array_elements(p_filters->'state') AS item(value)
       WHERE jsonb_typeof(item.value)<>'string'
          OR item.value#>>'{}' NOT IN (
            'RECEIVED','REVIEW','APPROVED','REJECTED','COMPLETED'
          )
     )
     OR (SELECT count(*) FROM jsonb_array_elements(p_filters->'requestType'))<>
        (SELECT count(DISTINCT item.value)
         FROM jsonb_array_elements(p_filters->'requestType') AS item(value))
     OR (SELECT count(*) FROM jsonb_array_elements(p_filters->'state'))<>
        (SELECT count(DISTINCT item.value)
         FROM jsonb_array_elements(p_filters->'state') AS item(value))
     OR jsonb_typeof(p_filters->'dueBefore') NOT IN ('null','string')
     OR jsonb_typeof(p_filters->'legalHoldBlocked') NOT IN ('null','boolean')
     OR jsonb_typeof(p_filters->'sort')<>'string'
     OR p_filters->>'sort' NOT IN ('DUE_ASC','CREATED_DESC')
     OR jsonb_typeof(p_filters->'limit')<>'number'
     OR p_filters->>'limit' !~ '^[1-9][0-9]{0,2}$'
     OR (p_filters->>'limit')::integer NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'privacy_retention_queue_filters_invalid'
      USING ERRCODE='22023';
  END IF;

  -- The input is valid but cannot be authenticated with current authority.
  IF jsonb_typeof(p_filters->'cursor')<>'null' THEN
    RAISE EXCEPTION 'privacy_retention_queue_cursor_authority_missing'
      USING ERRCODE='55000';
  END IF;

  SELECT COALESCE(array_agg(item.value#>>'{}' ORDER BY item.ordinality),
                  '{}'::text[])
  INTO v_request_types
  FROM jsonb_array_elements(p_filters->'requestType')
    WITH ORDINALITY AS item(value,ordinality);
  SELECT COALESCE(array_agg(item.value#>>'{}' ORDER BY item.ordinality),
                  '{}'::text[])
  INTO v_states
  FROM jsonb_array_elements(p_filters->'state')
    WITH ORDINALITY AS item(value,ordinality);
  IF jsonb_typeof(p_filters->'dueBefore')='string' THEN
    v_due_before:=(p_filters->>'dueBefore')::timestamptz;
  END IF;
  IF jsonb_typeof(p_filters->'legalHoldBlocked')='boolean' THEN
    v_legal_hold_blocked:=(p_filters->>'legalHoldBlocked')::boolean;
  END IF;
  v_sort:=p_filters->>'sort';
  v_limit:=(p_filters->>'limit')::integer;

  FOR v_request_id IN
    SELECT request.id
    FROM ops.privacy_requests_v2 AS request
    WHERE (cardinality(v_request_types)=0
           OR request.request_type=ANY(v_request_types))
      AND (cardinality(v_states)=0 OR request.state=ANY(v_states))
      AND (v_due_before IS NULL OR request.due_at<=v_due_before)
    ORDER BY
      CASE WHEN v_sort='DUE_ASC' THEN request.due_at END ASC NULLS LAST,
      CASE WHEN v_sort='DUE_ASC' THEN request.id END ASC,
      CASE WHEN v_sort='CREATED_DESC' THEN request.created_at END DESC,
      CASE WHEN v_sort='CREATED_DESC' THEN request.id END DESC
  LOOP
    v_workspace:=ops.read_privacy_retention_request_workspace_v2(v_request_id);
    IF v_workspace IS NULL
       OR jsonb_typeof(v_workspace->'request')<>'object' THEN
      RAISE EXCEPTION 'privacy_retention_queue_workspace_invalid'
        USING ERRCODE='55000';
    END IF;
    IF v_legal_hold_blocked IS NOT NULL
       AND (v_workspace->'request'->>'legalHoldBlocked')::boolean
           IS DISTINCT FROM v_legal_hold_blocked THEN
      CONTINUE;
    END IF;
    v_match_count:=v_match_count+1;
    IF v_match_count>v_limit THEN
      RAISE EXCEPTION 'privacy_retention_queue_cursor_authority_missing'
        USING ERRCODE='55000';
    END IF;
    v_items:=v_items||jsonb_build_array(v_workspace->'request');
  END LOOP;

  RETURN jsonb_build_object(
    'items',v_items,
    'appliedFilters',jsonb_build_object(
      'requestType',p_filters->'requestType',
      'state',p_filters->'state',
      'dueBefore',p_filters->'dueBefore',
      'legalHoldBlocked',p_filters->'legalHoldBlocked',
      'sort',v_sort
    ),
    'asOf',v_as_of,
    'nextCursor',NULL,
    'totalApproximate',v_match_count,
    'links','[]'::jsonb
  );
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range
    OR datetime_field_overflow THEN
    RAISE EXCEPTION 'privacy_retention_queue_filters_invalid'
      USING ERRCODE='22023';
END;
$queue$;

ALTER FUNCTION ops.read_privacy_retention_request_queue_v2(jsonb)
  OWNER TO gurine_migrator;
REVOKE ALL ON FUNCTION
  ops.read_privacy_retention_request_queue_v2(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  ops.read_privacy_retention_request_queue_v2(jsonb)
  TO gurine_control_api;
-- R6d privacy-request Control API safe-reader integration ends.
-- R6d privacy create/read/sealed/notification integration ends.

COMMIT;
